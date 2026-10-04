package main

import (
	"os"
	"strings"
	"testing"
)

// 造一份逐行 LRC:每行一句,前面垫几行署名(带冒号,应被忽略)。
func lrcOf(lines ...string) string {
	var b strings.Builder
	b.WriteString("[00:00.10]作词:某人\n[00:00.20]编曲:某人\n")
	for _, l := range lines {
		b.WriteString("[00:01.00]" + l + "\n")
	}
	return b.String()
}

// 70 个汉字左右,够 hokkienMinHan 的样本量。
const mandarinFill = "我在城市的夜里慢慢走着想起你说过的每一句话风吹过街角的灯光照亮我们曾经的约定时间一点一点带走了夏天也带走了那些没说出口的心事"

func TestLyricsLookHokkien(t *testing.T) {
	for _, c := range []struct {
		name   string
		lyrics string
		want   bool
	}{
		{"两种特征字", lrcOf(mandarinFill, "你袂记得阮", "阮毋是你的人"), true},
		{"单个出现三次", lrcOf(mandarinFill, "阮的心", "阮的梦", "阮的人"), true},
		{"按怎三次", lrcOf(mandarinFill, "按怎讲", "按怎走", "按怎放"), true},
		{"简体拢三次", lrcOf(mandarinFill, "拢是你", "拢是梦", "拢是风"), true},
		{"普通话:阁、拢各一次", lrcOf(mandarinFill, "楼阁上的月光", "拢住你的手"), false},
		{"两种里有一种普通话也用", lrcOf(mandarinFill, "阮的楼阁", "月光"), true},
		{"只有普通话也用的几种", lrcOf(mandarinFill, "楼阁", "靠拢", "厝边", "遐想"), false},
		{"普通话:只有一种、不到三次", lrcOf(mandarinFill, "阮玲玉的故事"), false},
		{"普通话:常见虚字不算", lrcOf(mandarinFill, "你干嘛欲言又止", "遮住眼睛", "比较好"), false},
		{"日文歌:假名多", lrcOf(mandarinFill, "欲しいものは阮", "袂を握って", "毋れないで", "あいうえお"), false},
		{"粤语歌:粤语特有字多", lrcOf(mandarinFill, "我唔知佢喺边", "阮袂毋", "冇嘢"), false},
		{"汉字太少", lrcOf("阮袂毋", "按怎"), false},
		// 署名行里的冒号行不算正文:特征字只出现在署名里时不判。
		{"特征字只在署名行", "[00:00.10]作词:阮袂毋按怎\n[00:01.00]" + mandarinFill + "\n", false},
	} {
		if got := lyricsLookHokkien(c.lyrics); got != c.want {
			t.Errorf("%s: lyricsLookHokkien = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestEntrySongLanguage(t *testing.T) {
	hok := lrcOf(mandarinFill, "你袂记得阮", "阮毋是你的人")
	cmn := lrcOf(mandarinFill)
	withLang := func(l string) []scoredLyricCandidateResult {
		return []scoredLyricCandidateResult{{Source: "qq", Score: 900, Language: l}}
	}
	for _, c := range []struct {
		name, lyrics string
		scored       []scoredLyricCandidateResult
		want         string
	}{
		{"源说普通话、歌词是台语", hok, withLang(songLanguageMandarin), songLanguageHokkien},
		{"源没报、歌词是台语", hok, nil, songLanguageHokkien},
		{"源说粤语:照粤语", hok, withLang(songLanguageCantonese), songLanguageCantonese},
		{"普通话歌", cmn, withLang(songLanguageMandarin), songLanguageMandarin},
	} {
		if got := entrySongLanguage(c.lyrics, c.scored); got != c.want {
			t.Errorf("%s: got %q want %q", c.name, got, c.want)
		}
	}
}

func TestDropHokkienRomaAndHelperGate(t *testing.T) {
	e := enrichEntry{Lyrics: "[00:01.00]阮", LyricsRoma: "[00:01.00]ruan", SongLanguage: songLanguageHokkien}
	e.dropHokkienRoma()
	if e.LyricsRoma != "" {
		t.Fatal("台语歌不留罗马音")
	}
	if e.shouldGenerateHelperRoma() {
		t.Fatal("台语歌不该生成拼音")
	}
	manual := enrichEntry{Lyrics: "[00:01.00]阮", LyricsRoma: "[00:01.00]guan", SongLanguage: songLanguageHokkien, ManualLyrics: true}
	manual.dropHokkienRoma()
	if manual.LyricsRoma == "" {
		t.Fatal("手改过的不动")
	}
	cmn := enrichEntry{Lyrics: "[00:01.00]我", LyricsRoma: "[00:01.00]wo", SongLanguage: songLanguageMandarin}
	cmn.dropHokkienRoma()
	if cmn.LyricsRoma == "" {
		t.Fatal("普通话歌不动")
	}
}

func TestMigrateHokkienSongLanguage(t *testing.T) {
	hok := lrcOf(mandarinFill, "你袂记得阮", "阮毋是你的人")
	withEnrichCache(t, map[string]enrichEntry{
		"a|台语|":   {Lyrics: hok, LyricsRoma: "[00:01.00]pinyin"},
		"b|手改台语|": {Lyrics: hok, LyricsRoma: "[00:01.00]mine", ManualLyrics: true},
		"c|粤语|":   {Lyrics: hok, LyricsRoma: "[00:01.00]jyut6", SongLanguage: songLanguageCantonese},
		"d|普通话|":  {Lyrics: lrcOf(mandarinFill), LyricsRoma: "[00:01.00]wo", SongLanguage: songLanguageMandarin},
	})
	migrateHokkienSongLanguage()
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if e := enrichCache["a|台语|"]; e.SongLanguage != songLanguageHokkien || e.LyricsRoma != "" {
		t.Errorf("台语条目: %+v", e)
	}
	if e := enrichCache["b|手改台语|"]; e.SongLanguage != songLanguageHokkien || e.LyricsRoma == "" {
		t.Errorf("手改过的只补语种、不清罗马音: %+v", e)
	}
	if e := enrichCache["c|粤语|"]; e.SongLanguage != songLanguageCantonese || e.LyricsRoma == "" {
		t.Errorf("粤语条目不动: %+v", e)
	}
	if e := enrichCache["d|普通话|"]; e.SongLanguage != songLanguageMandarin || e.LyricsRoma == "" {
		t.Errorf("普通话条目不动: %+v", e)
	}
}

// Go 与 Swift 两边的台语取值、以及各写入点的接线。
func TestHokkienIsWired(t *testing.T) {
	for file, needles := range map[string][]string{
		"../lyrimuse/Sources/LyrimuseCore/Local/EnrichCacheReader.swift": {`private let songLanguageHokkien = "` + songLanguageHokkien + `"`},
		"enrich.go":            {"preparedRoma = generatedRomaFor(picked.Lyrics, \"\", entrySongLanguage(picked.Lyrics, scored))"},
		"provisionallyrics.go": {"e.SongLanguage = entrySongLanguage(picked.Lyrics, scored)\n\te.dropHokkienRoma()"},
		"main.go":              {`startupStep("migrateHokkienSongLanguage", migrateHokkienSongLanguage)`},
		"../lyrimuse/Sources/LyrimuseCore/Lyrics/LyricsSyncEngine.swift": {"if songIsHokkien, script == .chinese { return false }"},
	} {
		data, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		for _, n := range needles {
			if !strings.Contains(string(data), n) {
				t.Errorf("%s 缺 %q", file, n)
			}
		}
	}
	data, _ := os.ReadFile("enrich.go")
	if n := strings.Count(string(data), "e.SongLanguage = entrySongLanguage(picked.Lyrics, scored)"); n != 2 {
		t.Errorf("enrich.go 里写 SongLanguage 的两处(升级重试 / 重评分)都要走 entrySongLanguage,找到 %d 处", n)
	}
	if strings.Contains(string(data), "e.SongLanguage = songLanguageFromScored(scored)") {
		t.Error("enrich.go 还有直接用 songLanguageFromScored 写 SongLanguage 的地方")
	}
}
