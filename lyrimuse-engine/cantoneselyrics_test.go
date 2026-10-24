package main

import (
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
		if got := entrySongLanguage(c.lyrics, c.scored); got != c.want {
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
