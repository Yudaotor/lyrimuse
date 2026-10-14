package main

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
)

// withHanTitleReading 把汉字读音换成查表(表里没有就是读不出),返回调用次数的读数。
func withHanTitleReading(t *testing.T, readings map[string]string) func() int {
	t.Helper()
	saved := hanTitleReading
	t.Cleanup(func() { hanTitleReading = saved })
	calls := 0
	hanTitleReading = func(han string) []string {
		calls++
		return strings.Fields(readings[han])
	}
	return func() int { return calls }
}

func TestPinyinSegmentations(t *testing.T) {
	for _, c := range []struct {
		word string
		want [][]string
	}{
		{"nanyin", [][]string{{"nan", "yin"}}},
		{"tianmimi", [][]string{{"tian", "mi", "mi"}}},
		{"fangan", [][]string{{"fan", "gan"}}}, // fang-an 的 an 在词中间以元音开头,不算
		{"xian", [][]string{{"xian"}}},         // 同上,xi-an 要写隔音符号
		{"ting", [][]string{{"ting"}}},
		{"realize", nil}, // re-a-li-ze 的 a 在词中间
		{"sakura", nil},  // ra 不是普通话音节
		{"remix", nil},
		{"", [][]string{nil}},
	} {
		got := pinyinSegmentations(c.word)
		if c.word == "" {
			if len(got) != 1 || len(got[0]) != 0 {
				t.Errorf("pinyinSegmentations(\"\") = %v", got)
			}
			continue
		}
		if !reflect.DeepEqual(got, c.want) {
			t.Errorf("pinyinSegmentations(%q) = %v, want %v", c.word, got, c.want)
		}
	}
}

func TestPinyinTitleReadings(t *testing.T) {
	for _, c := range []struct {
		title  string
		want   [][]string
		spaced bool
	}{
		{"Wo De Qing Ge", [][]string{{"wo", "de", "qing", "ge"}}, true},
		{"Gong Zhuan Zi Zhuan (Live)", [][]string{{"gong", "zhuan", "zi", "zhuan"}}, true},
		{"Wo De Qing Ge - Remastered", [][]string{{"wo", "de", "qing", "ge"}}, true},
		{"Qi-Li-Xiang", [][]string{{"qi", "li", "xiang"}}, true},
		{"Wǒ De Nǚ Hai", [][]string{{"wo", "de", "nu", "hai"}}, true},
		{"Nanyin", [][]string{{"nan", "yin"}}, false},                         // 连写
		{"Ting", [][]string{{"ting"}}, false},                                 // 只有一个音节
		{"Run", [][]string{{"run"}}, false},                                   // 英文词恰好是一个音节
		{"Michi Teyu Ku", [][]string{{"mi", "chi", "te", "yu", "ku"}}, false}, // 日文罗马字也切得出来
		{"Realize", nil, false},
		{"Love Story", nil, false},
		{"Wo De Qing Ge Remix", nil, false},
		{"2000 Nian", nil, false},
		{"", nil, false},
	} {
		got, spaced := pinyinTitleReadings(c.title)
		if !reflect.DeepEqual(got, c.want) || spaced != c.spaced {
			t.Errorf("pinyinTitleReadings(%q) = %v %v, want %v %v", c.title, got, spaced, c.want, c.spaced)
		}
	}
}

func TestPinyinTitleContradicts(t *testing.T) {
	calls := withHanTitleReading(t, map[string]string{
		"你伤了我的心":  "ni shang le wo de xin",
		"我的情歌":    "wo de qing ge",
		"我的情歌现场版": "wo de qing ge xian chang ban",
		"手拖手":     "shou tuo shou",
		"拖男带女":    "tuo nan dai nu",
		"很好":      "hen hao",
		"银行":      "yin xing",
		"情歌":      "qing ge yi", // 读音跟字数对不上:不判
		"南音":      "nan yin",
		"月亮代表我的心": "yue liang dai biao wo de xin",
		"听":       "ting",
		"爱":       "ai",
	})
	for _, c := range []struct {
		title, album, found string
		chinese             bool
		want                bool
		reads               bool // 要不要起 helper 读音
	}{
		{"Wo De Qing Ge", "Revolution", "你伤了我的心", false, true, true}, // 字数跟音节数不同
		{"Ai Ni", "", "很好", false, true, true},                       // 首字母一个都不同
		{"Wo De Qing Ge", "Revolution", "我的情歌", false, false, true},
		{"Wo De Qing Ge", "", "我的情歌 - 现场版", false, false, true},
		{"Sou Tuo Sou", "This Love", "手拖手", false, false, true}, // s 对 sh
		{"Tou Nan Dai Nu", "This Love", "拖男带女", false, false, true},
		{"Yin Hang", "", "银行", false, false, true},                 // 多音字读错一个,还有一半对得上
		{"Qing Ge", "", "情歌", false, false, true},                  // 读音跟字数对不上
		{"Wo De Qing Ge", "你伤了我的心", "你伤了我的心", false, false, false}, // 本地专辑名就是这首
		{"Wo De Qing Ge", "", "我的情歌 Live", false, false, false},
		{"Wo De Qing Ge", "", "わたしの情歌", false, false, false},
		{"Wo De Qing Ge", "", "2000年", false, false, false},
		{"Realize", "", "开始懂了", true, false, false},
		{"Wu Kong", "", "Wukong", false, false, false},
		{"Wo De Qing Ge", "", "没有读音", false, false, true}, // helper 读不出:不判
		// 连写的、只有一个音节的:有中文歌线索才判。
		{"Nanyin", "", "南音", true, false, true},
		{"Nanyin", "", "南音", false, false, false},
		{"Tianmimi", "", "月亮代表我的心", true, true, true},
		{"Tianmimi", "", "月亮代表我的心", false, false, false},
		{"Ting", "", "听", true, false, true},
		{"Ting", "", "爱", true, true, true},
		{"Ting", "", "爱", false, false, false},
		{"Michi Teyu Ku", "", "満ちてゆく", true, false, false}, // 带假名的不判
	} {
		before := calls()
		if got := pinyinTitleContradicts(c.title, c.album, c.found, c.chinese); got != c.want {
			t.Errorf("pinyinTitleContradicts(%q, %q, %q, %v) = %v, want %v", c.title, c.album, c.found, c.chinese, got, c.want)
		}
		if read := calls() > before; read != c.reads {
			t.Errorf("pinyinTitleContradicts(%q, %q, %q, %v):起没起 helper = %v, want %v", c.title, c.album, c.found, c.chinese, read, c.reads)
		}
	}
}

// 「这首是中文歌」的线索:认下的候选正文以汉字为主、没有假名,或者 ISRC 登记在中国大陆、台湾、香港;被判负分的候选不算。
func TestTitleReverseSungInChinese(t *testing.T) {
	zh := "[00:01.00]我的情歌\n[00:05.00]唱给你听\n"
	ja := "[00:01.00]満ちてゆく\n[00:05.00]きみのこと\n"
	for _, c := range []struct {
		name    string
		results []scoredLyricCandidateResult
		isrc    string
		want    bool
	}{
		{"认下的中文正文", []scoredLyricCandidateResult{{Score: 700, Lyrics: zh}}, "", true},
		{"只有判了负分的中文正文", []scoredLyricCandidateResult{{Score: -1, Lyrics: zh}}, "", false},
		{"认下的日文正文", []scoredLyricCandidateResult{{Score: 700, Lyrics: ja}, {Score: 600, Lyrics: zh}}, "", false},
		{"台湾登记的 ISRC", nil, "TWA479820005", true},
		{"香港登记的 ISRC", nil, "hk-a35-15-01001", true},
		{"日本登记的 ISRC、没有正文", nil, "JPPO02100112", false},
		{"什么都没有", nil, "", false},
	} {
		if got := titleReverseSungInChinese(c.results, c.isrc); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

// 歌手泛搜、专辑曲目表凭时长挑出的汉字曲名读音跟本地拼音曲名对不上时,标题反查不用它;对得上的照旧用;专辑那一路有近似标题佐证的
// 不判。ctx 已取消,别的几路联网反查都拿不到东西。
func TestTitleReverseLookupDropsPicksThatReadDifferently(t *testing.T) {
	savedSearch, savedAlbum, savedAliases := titleReverseArtistSearch, titleReverseAlbumSearch, titleReverseAliases
	t.Cleanup(func() {
		titleReverseArtistSearch, titleReverseAlbumSearch, titleReverseAliases = savedSearch, savedAlbum, savedAliases
	})
	titleReverseAliases = func(context.Context, string) []string { return nil }
	withHanTitleReading(t, map[string]string{"你伤了我的心": "ni shang le wo de xin", "我的情歌": "wo de qing ge"})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	none := func(context.Context, string, string, float64) (string, float64, bool) { return "", 0, false }
	noAlbum := func(context.Context, string, string, string, float64) (string, float64, bool, bool) {
		return "", 0, false, false
	}
	for _, c := range []struct {
		name, search, album string
		backed              bool
		want, method        string
	}{
		{"泛搜挑错", "你伤了我的心", "", false, "", ""},
		{"泛搜挑对", "我的情歌", "", false, "我的情歌", lyricQueryReasonTitleSearch},
		{"专辑凭时长挑错", "", "你伤了我的心", false, "", ""},
		{"专辑凭时长挑对", "", "我的情歌", false, "我的情歌", "title-from-album"},
		{"专辑有近似标题佐证", "", "你伤了我的心", true, "你伤了我的心", "title-from-album"},
	} {
		titleReverseArtistSearch, titleReverseAlbumSearch = none, noAlbum
		if c.search != "" {
			found := c.search
			titleReverseArtistSearch = func(context.Context, string, string, float64) (string, float64, bool) { return found, 1, true }
		}
		if c.album != "" {
			found, backed := c.album, c.backed
			titleReverseAlbumSearch = func(context.Context, string, string, string, float64) (string, float64, bool, bool) {
				return found, 1, backed, true
			}
		}
		got, method, _ := titleReverseLookup(ctx, "Leehom Wang", "Wo De Qing Ge", "Revolution", 243, nil, "", false)
		if got != c.want || (c.want != "" && method != c.method) {
			t.Errorf("%s: corrected = %q (%s),want %q (%s)", c.name, got, method, c.want, c.method)
		}
	}
}

// romanizedHanReading 真的起 helper:送一行带时间戳的歌词、回包里的读音拆成音节(去声调);helper 读不出、不在都是 nil。
func TestRomanizedHanReadingRunsHelper(t *testing.T) {
	dir := t.TempDir()
	helper := filepath.Join(dir, "lyrics-romanize")
	script := `#!/bin/sh
in=$(cat)
case "$in" in
  *'"lyrics":"[00:00.00]你伤了我的心"'*) printf '%s' '{"ok":true,"roma":"[00:00.00]nǐ shāng le wǒ de xīn"}' ;;
  *) printf '%s' '{"ok":false,"reason":"no-romanization"}'; exit 1 ;;
esac
`
	if err := os.WriteFile(helper, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	saved := lyricsRomanizeBin
	t.Cleanup(func() { lyricsRomanizeBin = saved })
	lyricsRomanizeBin = func() (string, error) { return helper, nil }
	if got := romanizedHanReading("你伤了我的心"); !slices.Equal(got, []string{"ni", "shang", "le", "wo", "de", "xin"}) {
		t.Errorf("读音 = %v", got)
	}
	if got := romanizedHanReading("没有读音"); got != nil {
		t.Errorf("helper 读不出时要 nil: %v", got)
	}
	lyricsRomanizeBin = func() (string, error) { return filepath.Join(dir, "missing"), nil }
	if got := romanizedHanReading("你伤了我的心"); got != nil {
		t.Errorf("helper 不在时要 nil: %v", got)
	}
}

// 本地拼音切得出几种读法时,每一种都对不上才算矛盾;有一种对得上就不算。
func TestPinyinReadingsContradict(t *testing.T) {
	reading := []string{"xi", "an"}
	for _, c := range []struct {
		readings [][]string
		want     bool
	}{
		{[][]string{{"xian"}, {"xi", "an"}}, false},
		{[][]string{{"xi", "an"}, {"xian"}}, false},
		{[][]string{{"xian"}}, true},
		{[][]string{{"hen"}, {"hao", "de"}}, true},
		{nil, false},
	} {
		if got := pinyinReadingsContradict(c.readings, reading); got != c.want {
			t.Errorf("pinyinReadingsContradict(%v) = %v, want %v", c.readings, got, c.want)
		}
	}
}
