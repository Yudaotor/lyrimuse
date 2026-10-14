package main

import (
	"context"
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

func TestPinyinTitleSyllables(t *testing.T) {
	for _, c := range []struct {
		title string
		want  []string
	}{
		{"Wo De Qing Ge", []string{"wo", "de", "qing", "ge"}},
		{"Gong Zhuan Zi Zhuan (Live)", []string{"gong", "zhuan", "zi", "zhuan"}},
		{"Wo De Qing Ge - Remastered", []string{"wo", "de", "qing", "ge"}},
		{"Qi-Li-Xiang", []string{"qi", "li", "xiang"}},
		{"Wǒ De Nǚ Hai", []string{"wo", "de", "nu", "hai"}},
		{"Nanyin", nil},        // 连写成一个词
		{"Realize", nil},       // 英文词切得成 re-a-li-ze,但不是一字一词
		{"Michi Teyu Ku", nil}, // 日文罗马字
		{"Love Story", nil},
		{"Run", nil},                 // 一个英文词恰好是一个音节
		{"Wo De Qing Ge Remix", nil}, // 混进一个不是音节的词
		{"2000 Nian", nil},
		{"Ai 2 Ni", nil},
		{"", nil},
	} {
		if got := pinyinTitleSyllables(c.title); !slices.Equal(got, c.want) {
			t.Errorf("pinyinTitleSyllables(%q) = %v, want %v", c.title, got, c.want)
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
	})
	for _, c := range []struct {
		title, album, found string
		want                bool
		reads               bool // 要不要起 helper 读音
	}{
		{"Wo De Qing Ge", "Revolution", "你伤了我的心", true, true}, // 字数跟音节数不同
		{"Ai Ni", "", "很好", true, true},                       // 首字母一个都不同
		{"Wo De Qing Ge", "Revolution", "我的情歌", false, true},
		{"Wo De Qing Ge", "", "我的情歌 - 现场版", false, true},
		{"Sou Tuo Sou", "This Love", "手拖手", false, true}, // s 对 sh
		{"Tou Nan Dai Nu", "This Love", "拖男带女", false, true},
		{"Yin Hang", "", "银行", false, true},                 // 多音字读错一个,还有一半对得上
		{"Qing Ge", "", "情歌", false, true},                  // 读音跟字数对不上
		{"Wo De Qing Ge", "你伤了我的心", "你伤了我的心", false, false}, // 本地专辑名就是这首
		{"Wo De Qing Ge", "", "我的情歌 Live", false, false},
		{"Wo De Qing Ge", "", "わたしの情歌", false, false},
		{"Wo De Qing Ge", "", "2000年", false, false},
		{"Realize", "", "开始懂了", false, false},
		{"Nanyin", "", "南音", false, false},
		{"Wu Kong", "", "Wukong", false, false},
		{"Wo De Qing Ge", "", "没有读音", false, true}, // helper 读不出:不判
	} {
		before := calls()
		if got := pinyinTitleContradicts(c.title, c.album, c.found); got != c.want {
			t.Errorf("pinyinTitleContradicts(%q, %q, %q) = %v, want %v", c.title, c.album, c.found, got, c.want)
		}
		if read := calls() > before; read != c.reads {
			t.Errorf("pinyinTitleContradicts(%q, %q, %q):起没起 helper = %v, want %v", c.title, c.album, c.found, read, c.reads)
		}
	}
}

// 泛搜挑出的汉字曲名读音跟本地拼音曲名对不上时,标题反查不用它;对得上的照旧用。ctx 已取消,别的几路联网反查都拿不到东西。
func TestTitleReverseLookupDropsArtistSearchThatReadsDifferently(t *testing.T) {
	savedSearch, savedAliases := titleReverseArtistSearch, titleReverseAliases
	t.Cleanup(func() { titleReverseArtistSearch, titleReverseAliases = savedSearch, savedAliases })
	titleReverseAliases = func(context.Context, string) []string { return nil }
	withHanTitleReading(t, map[string]string{"你伤了我的心": "ni shang le wo de xin", "我的情歌": "wo de qing ge"})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	for _, c := range []struct{ found, want string }{
		{"你伤了我的心", ""},
		{"我的情歌", "我的情歌"},
	} {
		found := c.found
		titleReverseArtistSearch = func(context.Context, string, string, float64) (string, float64, bool) { return found, 1, true }
		got, method, _ := titleReverseLookup(ctx, "Leehom Wang", "Wo De Qing Ge", "Revolution", 243, nil, "")
		if got != c.want {
			t.Errorf("泛搜挑出 %q:corrected = %q (%s),want %q", c.found, got, method, c.want)
		}
		if c.want != "" && method != lyricQueryReasonTitleSearch {
			t.Errorf("%q:method = %q,want %q", c.found, method, lyricQueryReasonTitleSearch)
		}
	}
}
