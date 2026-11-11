package main

import (
	"fmt"
	"os"
	"strings"
	"testing"
)

// 粤语口语写的独白:每一行都带口语字。
var cantoneseSpoken = []string{
	"做咩有心事嘅你", "你个心事样嚟个", "最近钟意咗个女仔", "但系唔知佢钟唔钟意我",
	"佢唔会钟意你", "唔会啰", "我又唔系男朋友材料", "唔紧要啦实有人丑样过你",
}

// 书面语写的国语歌词,一个口语字都没有。
var mandarinWritten = []string{
	"你不要爱我", "不要我们有如果", "我怕如果分手", "到时连朋友都没得做",
	"就轮不到你伤害我", "就不会丢失你的线索", "我没法那样活", "只怪我太软弱",
}

func TestLyricsLookCantonese(t *testing.T) {
	half := append(append([]string{}, mandarinWritten[:4]...), cantoneseSpoken[:4]...)
	underHalf := append(append([]string{}, mandarinWritten[:5]...), cantoneseSpoken[:4]...)
	for _, c := range []struct {
		name   string
		lyrics string
		want   bool
	}{
		{"整段粤语口语", lrcOf(cantoneseSpoken...), true},
		{"一半行带口语字", lrcOf(half...), true},
		{"国语歌加几句粤语对白,不到一半", lrcOf(underHalf...), false},
		{"书面语", lrcOf(mandarinWritten...), false},
		{"太短不判", lrcOf(cantoneseSpoken[:7]...), false},
		{"日文歌不判", lrcOf(append(append([]string{}, cantoneseSpoken...), "あいうえお")...), false},
		{"署名行不算", lrcOf(append(append([]string{}, mandarinWritten...), "唔:佢", "嘅:咗", "啲:嚟", "喺:睇",
			"冇:咁", "嘢:唔", "佢:嘅", "咗:啲", "嚟:喺")...), false},
	} {
		if got := lyricsLookCantonese(c.lyrics); got != c.want {
			t.Errorf("%s: got %v want %v", c.name, got, c.want)
		}
	}
}

func TestEntrySongLanguageCantoneseLyrics(t *testing.T) {
	yue := lrcOf(cantoneseSpoken...)
	withLang := func(l string) []scoredLyricCandidateResult {
		return []scoredLyricCandidateResult{{Source: "qq", Score: 900, Language: l}}
	}
	for _, c := range []struct {
		name, lyrics string
		scored       []scoredLyricCandidateResult
		want         string
	}{
		{"源说普通话、歌词是粤语口语", yue, withLang(songLanguageMandarin), songLanguageCantonese},
		{"源没报、歌词是粤语口语", yue, nil, songLanguageCantonese},
		{"源说普通话、书面语", lrcOf(mandarinWritten...), withLang(songLanguageMandarin), songLanguageMandarin},
		{"源没报、书面语", lrcOf(mandarinWritten...), nil, ""},
	} {
		if got := entrySongLanguage(c.lyrics, "", c.scored); got != c.want {
			t.Errorf("%s: got %q want %q", c.name, got, c.want)
		}
	}
}

func TestMigrateCantoneseSongLanguage(t *testing.T) {
	yue := lrcOf(cantoneseSpoken...)
	pinyin := "[00:01.00]zuò miē yǒu xīn shì gě nǐ\n[00:01.00]dàn xì wú zhī tā zhōng wú zhōng yì wǒ"
	withEnrichCache(t, map[string]enrichEntry{
		"a|拼音|":  {Lyrics: bt(yue), LyricsRoma: bt(pinyin), SongLanguage: songLanguageMandarin},
		"b|没读音|": {Lyrics: bt(yue)},
		"c|手改|":  {Lyrics: bt(yue), LyricsRoma: bt(pinyin), SongLanguage: songLanguageMandarin, ManualLyrics: true},
		"d|书面语|": {Lyrics: bt(lrcOf(mandarinWritten...)), LyricsRoma: bt(pinyin), SongLanguage: songLanguageMandarin},
	})
	migrateCantoneseSongLanguage()
	enrichMu.Lock()
	defer enrichMu.Unlock()
	jyut := jyutpingLRC(yue)
	if e := enrichCache["a|拼音|"]; e.SongLanguage != songLanguageCantonese || !e.LyricsRoma.EqualString(jyut) {
		t.Errorf("普通话拼音换成粤拼: %+v", e)
	}
	if e := enrichCache["b|没读音|"]; e.SongLanguage != songLanguageCantonese || !e.LyricsRoma.EqualString(jyut) {
		t.Errorf("没读音的补上粤拼: %+v", e)
	}
	if e := enrichCache["c|手改|"]; e.SongLanguage != songLanguageCantonese || !e.LyricsRoma.EqualString(pinyin) {
		t.Errorf("手改过的只补语种、不换读音: %+v", e)
	}
	if e := enrichCache["d|书面语|"]; e.SongLanguage != songLanguageMandarin || !e.LyricsRoma.EqualString(pinyin) {
		t.Errorf("书面语的不动: %+v", e)
	}
}

func TestCantoneseSongLanguageIsWired(t *testing.T) {
	data, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `startupStep("migrateCantoneseSongLanguage", migrateCantoneseSongLanguage)`) {
		t.Error("main.go 没接存量迁移")
	}
}

// timedLRC:每行一个时间标签,第 i 行在第 i 秒。
func timedLRC(lines ...string) string {
	var b strings.Builder
	for i, l := range lines {
		fmt.Fprintf(&b, "[00:%02d.00]%s\n", i+1, l)
	}
	return b.String()
}

// 英文夹粤语书面语的歌(The Weeknd《Hong Kong》那种),Apple Music 给的是不带声调的粤拼。
var (
	mixedLyrics = timedLRC("v1：There was something in the air", "v1：I would burn the world to keep you warm",
		"v2：這次季候風 吹得格外兇", "v2：彷彿世上一切 已經消失所蹤", "v2：你似季候風 抵擋計劃全也無用", "v1：I'm posted in Hong Kong")
	mixedJyutping = timedLRC("There was something in the air", "I would burn the world to keep you warm",
		"ze ci gwai hau fung ceoi dak gaak ngoi hung", "fong fat sai soeng jat cai ji ging siu sat so zung",
		"nei ci gwai hau fung dai dong gai waak cyun jaa mou jung", "I'm posted in Hong Kong")
	mixedPinyin = timedLRC("There was something in the air", "I would burn the world to keep you warm",
		"zhè cì jì hòu fēng chuī de gé wài xiōng", "fǎng fú shì shàng yí qiè yǐ jīng xiāo shī suǒ zōng",
		"nǐ sì jì hòu fēng dǐ dǎng jì huà quán yě wú yòng", "I'm posted in Hong Kong")
)

func TestRomaLooksJyutping(t *testing.T) {
	written := timedLRC(mandarinWritten...)
	for _, c := range []struct {
		name, lyrics, roma string
		want               bool
	}{
		{"英文夹粤语、读音是粤拼", mixedLyrics, mixedJyutping, true},
		{"带声调的粤拼也算", timedLRC("這次季候風 吹得格外兇", "彷彿世上一切 已經消失所蹤"),
			timedLRC("ze2 ci3 gwai3 hau6 fung1 ceoi1 dak1 gaak3 ngoi6 hung1", "fong2 fat1 sai3 soeng6 jat1 cai3 ji5 ging1 siu1 sat1 so2 zung1"), true},
		{"普通话拼音", mixedLyrics, mixedPinyin, false},
		{"不带声调的普通话拼音", written, timedLRC("ni bu yao ai wo", "bu yao wo men you ru guo", "wo pa ru guo fen shou",
			"dao shi lian peng you dou mei de zuo", "jiu lun bu dao ni shang hai wo", "jiu bu hui diu shi ni de xian suo"), false},
		{"英文行的读音不算", timedLRC("v1：back that stop what", "v1：black cat sat kit", "這次季候風"),
			timedLRC("back that stop what", "black cat sat kit", "zhe ci ji hou feng"), false},
		{"有对唱署名的韩文行不算", timedLRC("合：뒤져봐도 우린 유일무이", "合：뱉어 뱉어", "合：Backtalk"),
			timedLRC("dwijyeobwado urin yuilmui", "baeteo baeteo", "Backtalk"), false},
		{"太短不判", timedLRC("這次季候風"), timedLRC("ze ci gwai hau fung"), false},
		{"日文歌不判", timedLRC("這次季候風 吹得格外兇", "彷彿世上一切 已經消失所蹤", "あいうえお かきくけこ"),
			timedLRC("ze ci gwai hau fung ceoi dak gaak ngoi hung", "fong fat sai soeng jat cai ji ging siu sat so zung", "aiueo kakikukeko"), false},
		{"读音时间对不上不判", mixedLyrics, strings.ReplaceAll(mixedJyutping, "[00:0", "[01:0"), false},
		{"没读音", mixedLyrics, "", false},
		{"汉字夹英文的行不算", timedLRC("我愛 back that stop what black cat", "我愛 sat kit up"),
			timedLRC("ngo oi back that stop what black cat", "ngo oi sat kit up"), false},
		{"拼音里夹着英文词", timedLRC("這種事", "這種事"),
			timedLRC("zhe zhong shi back that stop", "zhe zhong shi what cat kit"), false},
		{"粤拼拼法太少", timedLRC("你好嗎我很好你呢", "你好嗎我很好你呢"),
			timedLRC("ni hao ma wo hen hao ni ne dak", "ni hao ma wo hen hao ni ne"), false},
		{"带声调、只靠入声韵尾认的粤拼", timedLRC("得不失色學習物", "力的"),
			timedLRC("dak1 bat1 sat1 sik1 hok6 zaap6 mat6", "lik6 dik1"), true},
	} {
		if got := romaLooksJyutping(c.lyrics, c.roma); got != c.want {
			t.Errorf("%s: got %v want %v", c.name, got, c.want)
		}
	}
}

func TestEntrySongLanguageJyutpingRoma(t *testing.T) {
	mandarin := []scoredLyricCandidateResult{{Source: "qq", Score: 900, Language: songLanguageMandarin}}
	if got := entrySongLanguage(mixedLyrics, mixedJyutping, nil); got != songLanguageCantonese {
		t.Errorf("源没报、读音是粤拼: got %q", got)
	}
	if got := entrySongLanguage(mixedLyrics, mixedJyutping, mandarin); got != songLanguageCantonese {
		t.Errorf("源说普通话、读音是粤拼: got %q", got)
	}
	if got := entrySongLanguage(mixedLyrics, mixedPinyin, nil); got != "" {
		t.Errorf("源没报、读音是拼音: got %q", got)
	}
}

func TestMigrateCantoneseSongLanguageJyutpingRoma(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"a|粤拼|": {Lyrics: bt(mixedLyrics), LyricsRoma: bt(mixedJyutping)},
		"b|拼音|": {Lyrics: bt(mixedLyrics), LyricsRoma: bt(mixedPinyin)},
		"c|手改|": {Lyrics: bt(mixedLyrics), LyricsRoma: bt(mixedJyutping), ManualLyrics: true},
	})
	migrateCantoneseSongLanguage()
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if e := enrichCache["a|粤拼|"]; e.SongLanguage != songLanguageCantonese || !e.LyricsRoma.EqualString(jyutpingLRC(mixedLyrics)) {
		t.Errorf("没声调的粤拼换成带声调的: %+v", e)
	}
	if e := enrichCache["b|拼音|"]; e.SongLanguage != "" || !e.LyricsRoma.EqualString(mixedPinyin) {
		t.Errorf("拼音的不动: %+v", e)
	}
	if e := enrichCache["c|手改|"]; e.SongLanguage != songLanguageCantonese || !e.LyricsRoma.EqualString(mixedJyutping) {
		t.Errorf("手改过的只补语种、不换读音: %+v", e)
	}
}
