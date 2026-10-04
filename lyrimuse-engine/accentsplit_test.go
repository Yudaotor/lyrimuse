package main

import (
	"fmt"
	"os"
	"strings"
	"testing"
)

func accentEvidence(texts ...string) func(string) bool {
	s := accentWordSet{}
	for _, t := range texts {
		s.addText(t)
	}
	return s.has
}

// 第二级证据词表换成这几份文本里的词,用完恢复。
func withAccentCacheWords(t *testing.T, texts ...string) {
	t.Helper()
	set := accentWordSet{}
	for _, s := range texts {
		set.addText(s)
	}
	accentCacheWordsMu.Lock()
	saved := accentCacheWords
	accentCacheWords = set
	accentCacheWordsMu.Unlock()
	t.Cleanup(func() {
		accentCacheWordsMu.Lock()
		accentCacheWords = saved
		accentCacheWordsMu.Unlock()
	})
}

// yrcLine:按空格切的词一个词条一个,每个 200ms,除最后一个外词条文字带尾空格。
func yrcLine(startMs int, text string) string {
	words := strings.Split(text, " ")
	var b strings.Builder
	fmt.Fprintf(&b, "[%d,%d]", startMs, 200*len(words))
	for i, w := range words {
		if i < len(words)-1 {
			w += " "
		}
		fmt.Fprintf(&b, "(%d,200,0)%s", startMs+200*i, w)
	}
	return b.String()
}

const accentReference = "Aus der großen Traumfabrik.\nUnd ein Märchen voll Musik\nOder über's Kuckucksnest\n" +
	"Düsenjäger\nC'est la dernière danse\nl'espérance\nYa llevo un rato mirándote"

func TestRepairAccentSplitLRC(t *testing.T) {
	attested := accentEvidence(accentReference)
	for _, c := range []struct{ name, in, want string }{
		{"切在重音字母后面", "[00:16.27]Aus der groß en traumfabrik", "[00:16.27]Aus der großen traumfabrik"},
		{"真词界留着", "[00:58.21]Oder ü ber's kuckucksnest", "[00:58.21]Oder über's kuckucksnest"},
		{"大写", "[00:16.27]AUS DER GROß EN TRAUMFABRIK", "[00:16.27]AUS DER GROßEN TRAUMFABRIK"},
		{"一串", "Dü senjä ger", "Düsenjäger"},
		{"切在重音字母前面", "C'est la derni ère danse", "C'est la dernière danse"},
		{"撇号处断开比对", "de l’esp érance", "de l’espérance"},
		{"只删证实过的", "Sí sabes que ya llevo un rato mirá ndote", "Sí sabes que ya llevo un rato mirándote"},
		{"多行", "[00:07.26]Und ein mä rchen voll musik\n[00:16.27]Aus der groß en traumfabrik",
			"[00:07.26]Und ein märchen voll musik\n[00:16.27]Aus der großen traumfabrik"},
	} {
		got, changed := repairAccentSplitLRC(c.in, attested)
		if got != c.want || !changed {
			t.Errorf("%s: got %q (changed=%v), want %q", c.name, got, changed, c.want)
		}
		if again, changed2 := repairAccentSplitLRC(got, attested); changed2 || again != got {
			t.Errorf("%s: 不幂等: %q", c.name, again)
		}
	}
	for _, in := range []string{
		"[00:34.93]Da verblaß t das sternenmeer", // 证据里没有 verblaßt
		"[00:16.27]Aus der groß  en traumfabrik", // 两个空格不算
		"[ti:groß en]", // 元数据行
		"我 爱 你",
		"[00:01.00]qué tú",
		"",
	} {
		if got, changed := repairAccentSplitLRC(in, attested); changed || got != in {
			t.Errorf("不该动: %q → %q", in, got)
		}
	}
}

func TestRepairAccentSplitYRC(t *testing.T) {
	attested := accentEvidence(accentReference)
	for _, c := range []struct{ name, in, want string }{
		{"词条带尾空格",
			"[16270,4240](16270,230,0)Aus (16500,300,0)der (16800,970,0)groß (17770,400,0)en (18170,2340,0)traumfabrik",
			"[16270,4240](16270,230,0)Aus (16500,300,0)der (16800,970,0)groß(17770,400,0)en (18170,2340,0)traumfabrik"},
		{"空格在下一个词条开头", "[0,1000](0,500,0)groß(500,500,0) en", "[0,1000](0,500,0)groß(500,500,0)en"},
		{"头部行原样", "[ti:Cinema]\n[0,1000](0,500,0)mä (500,500,0)rchen", "[ti:Cinema]\n[0,1000](0,500,0)mä(500,500,0)rchen"},
	} {
		got, changed := repairAccentSplitYRC(c.in, attested)
		if got != c.want || !changed {
			t.Errorf("%s: got %q (changed=%v), want %q", c.name, got, changed, c.want)
		}
		if again, changed2 := repairAccentSplitYRC(got, attested); changed2 || again != got {
			t.Errorf("%s: 不幂等: %q", c.name, again)
		}
	}
	for _, in := range []string{
		"[0,1000](0,400,0)groß(400,100,0) (500,500,0)en", // 纯空白词条不删
		"[0,1000](0,500,0)verblaß (500,500,0)t",
		"[0,1000](0,500,0)qué (500,500,0)tú",
	} {
		if got, changed := repairAccentSplitYRC(in, attested); changed || got != in {
			t.Errorf("不该动: %q → %q", in, got)
		}
	}
}

func TestAccentInsideWord(t *testing.T) {
	for in, want := range map[string]bool{
		"für dich":             true,
		"la dernière":          true,
		"Aus der groß en":      false,
		"läß t":                false,
		"qué tú":               false,
		"hello world":          false,
		"[00:01.00]Mä rchen":   false,
		"[00:01.00]Märchen":    true,
		"Oder ü ber's nest":    false,
		"Oder ü ber's nest ße": true,
	} {
		if got := accentInsideWord(in); got != want {
			t.Errorf("accentInsideWord(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestRepairCandidateAccentSplits(t *testing.T) {
	damaged := "[00:16.27]Aus der groß en traumfabrik"
	damagedYRC := yrcLine(16270, "Aus der groß en traumfabrik")
	t.Run("同一轮别的候选当证据", func(t *testing.T) {
		withAccentCacheWords(t)
		cands := []lyricCandidate{
			{source: "kugou", lyrics: damaged, wordTimingYRC: damagedYRC, hasWordTiming: true},
			{source: "lrclib", lyrics: "Aus der großen Traumfabrik.", plainTextOnly: true},
		}
		repairCandidateAccentSplits(cands)
		if cands[0].lyrics != "[00:16.27]Aus der großen traumfabrik" || !strings.Contains(cands[0].wordTimingYRC, "groß(16870,200,0)en ") {
			t.Errorf("没修好: %q / %q", cands[0].lyrics, cands[0].wordTimingYRC)
		}
		if cands[1].lyrics != "Aus der großen Traumfabrik." {
			t.Errorf("参照被改了: %q", cands[1].lyrics)
		}
	})
	t.Run("缓存里的词当证据", func(t *testing.T) {
		withAccentCacheWords(t, "Die großen Träume")
		cands := []lyricCandidate{{source: "kugou", lyrics: damaged, wordTimingYRC: damagedYRC}}
		repairCandidateAccentSplits(cands)
		if cands[0].lyrics != "[00:16.27]Aus der großen traumfabrik" || strings.Contains(cands[0].wordTimingYRC, "groß ") {
			t.Errorf("没修好: %q / %q", cands[0].lyrics, cands[0].wordTimingYRC)
		}
	})
	t.Run("有词中重音字母的文本不用缓存证据", func(t *testing.T) {
		withAccentCacheWords(t, "Die großen Träume")
		in := "[00:01.00]Für dich\n" + damaged
		cands := []lyricCandidate{{source: "kugou", lyrics: in}}
		repairCandidateAccentSplits(cands)
		if cands[0].lyrics != in {
			t.Errorf("不该动: %q", cands[0].lyrics)
		}
	})
	t.Run("没有重音字母", func(t *testing.T) {
		withAccentCacheWords(t, "Die großen Träume")
		cands := []lyricCandidate{{source: "qq", lyrics: "[00:01.00]晴天 我 爱 你"}, {source: "lrclib", lyrics: "Hello world"}}
		repairCandidateAccentSplits(cands)
		if cands[0].lyrics != "[00:01.00]晴天 我 爱 你" || cands[1].lyrics != "Hello world" {
			t.Errorf("不该动: %+v", cands)
		}
	})
}

// 两条流水线的结果里都是修好的文字。
func TestAccentSplitsRepairedInBothPipelines(t *testing.T) {
	withAccentCacheWords(t)
	lines := []string{"Wie ein stern", "Der erwacht", "Und ein mä rchen voll musik", "Bist auch du nur ein kind",
		"Aus der groß en traumfabrik", "Seit die bilder laufen lernten", "Lä uft die welt dir hinterher", "Und im glanz deiner stars"}
	var lrc, yrc []string
	for i, l := range lines {
		ms := 2000 + 4000*i
		lrc = append(lrc, lrcTimestamp(ms)+l)
		yrc = append(yrc, yrcLine(ms, l))
	}
	plain := "Wie ein Stern\nDer erwacht\nUnd ein Märchen voll Musik\nBist auch du nur ein Kind\n" +
		"Aus der großen Traumfabrik\nSeit die Bilder laufen lernten\nLäuft die Welt dir hinterher\nUnd im Glanz deiner Stars"
	check := func(t *testing.T, scored []scoredLyricCandidateResult) {
		t.Helper()
		for _, r := range scored {
			if r.Source != "kugou" {
				continue
			}
			for _, bad := range []string{"mä rchen", "groß en", "Lä uft"} {
				if strings.Contains(r.Lyrics, bad) || strings.Contains(r.LyricsYRC, strings.Replace(bad, " ", " (", 1)) {
					t.Errorf("%q 没修: %q / %q", bad, r.Lyrics, r.LyricsYRC)
				}
			}
			if !strings.Contains(r.Lyrics, "großen traumfabrik") {
				t.Errorf("整行没修: %q", r.Lyrics)
			}
			return
		}
		t.Fatalf("结果里没有酷狗: %+v", scored)
	}
	t.Run("rankLyricSourceResults", func(t *testing.T) {
		raw := map[string]lyricSourceResult{
			"kugou":  {source: "kugou", lyr: strings.Join(lrc, "\n"), yrc: strings.Join(yrc, "\n")},
			"lrclib": {source: "lrclib", lyr: plain, plainOnly: true},
		}
		check(t, rankLyricSourceResults("Paola", "Cinema", "", 185, raw))
	})
	t.Run("mergeLyricCandidateRounds", func(t *testing.T) {
		base := []scoredLyricCandidateResult{{Source: "kugou", Lyrics: strings.Join(lrc, "\n"), LyricsYRC: strings.Join(yrc, "\n"), HasWordTiming: true, Score: 900}}
		extra := []scoredLyricCandidateResult{{Source: "lrclib", Lyrics: plain, PlainTextOnly: true, Score: -1}}
		check(t, mergeLyricCandidateRounds("Paola", "Cinema", "", 185, base, extra))
	})
}

func TestMigrateAccentSplits(t *testing.T) {
	damaged := "[00:16.27]Aus der groß en traumfabrik"
	damagedYRC := yrcLine(16270, "Aus der groß en traumfabrik")
	healthy := "[00:01.00]Für dich\n" + damaged
	withAccentCacheWords(t)
	withEnrichCache(t, map[string]enrichEntry{
		"a|damaged|": {Lyrics: damaged, LyricsYRC: damagedYRC},
		"b|clean|":   {Lyrics: "[00:01.00]Die großen Träume"},
		"c|manual|":  {Lyrics: damaged, LyricsYRC: damagedYRC, ManualLyrics: true},
		"d|healthy|": {Lyrics: healthy},
	})
	enrichMu.Lock()
	savedPath, savedDirty := enrichPath, enrichDirty
	enrichPath = "" // 不落盘
	enrichMu.Unlock()
	t.Cleanup(func() {
		enrichMu.Lock()
		enrichPath, enrichDirty = savedPath, savedDirty
		enrichMu.Unlock()
	})
	migrateAccentSplits()
	if e := enrichCache["a|damaged|"]; e.Lyrics != "[00:16.27]Aus der großen traumfabrik" || strings.Contains(e.LyricsYRC, "groß ") {
		t.Errorf("存量没修: %+v", e)
	}
	if e := enrichCache["c|manual|"]; e.Lyrics != damaged || e.LyricsYRC != damagedYRC {
		t.Errorf("手改过的不碰: %+v", e)
	}
	if e := enrichCache["d|healthy|"]; e.Lyrics != healthy {
		t.Errorf("有词中重音字母的不用缓存证据: %+v", e)
	}
	if e := enrichCache["b|clean|"]; e.Lyrics != "[00:01.00]Die großen Träume" {
		t.Errorf("干净的不动: %+v", e)
	}
	if !currentAccentCacheWords().has("großen") {
		t.Error("迁移之后第二级词表该建好")
	}
}

// 接线:迁移夹在 import 与 export 之间、空白词条归并之后、migrateManualPickMarks 之前;手动搜索加载缓存之后建词表。
func TestAccentSplitsAreWired(t *testing.T) {
	mainSrc, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(mainSrc)
	at := func(s string) int { return strings.Index(src, s) }
	imp := at(`startupStep("importLyricsFromFiles"`)
	ws := at(`startupStep("migrateYRCWhitespaceTokens", migrateYRCWhitespaceTokens)`)
	mig := at(`startupStep("migrateAccentSplits", migrateAccentSplits)`)
	pick := at(`startupStep("migrateManualPickMarks", migrateManualPickMarks)`)
	exp := at(`startupStep("exportLyricsFiles", exportLyricsFiles)`)
	if imp < 0 || ws < 0 || mig < 0 || pick < 0 || exp < 0 || !(imp < ws && ws < mig && mig < pick && pick < exp) {
		t.Fatalf("迁移位置不对: import=%d whitespace=%d accent=%d manualPick=%d export=%d", imp, ws, mig, pick, exp)
	}
	cliSrc, err := os.ReadFile("searchcli.go")
	if err != nil {
		t.Fatal(err)
	}
	cli := string(cliSrc)
	load := strings.Index(cli, "loadEnrichCacheReadOnly(")
	words := strings.Index(cli, "refreshAccentCacheWords()")
	if load < 0 || words < load {
		t.Fatalf("search-lyrics 要在加载缓存之后建词表: load=%d words=%d", load, words)
	}
}

// 粗筛只许多报、不许漏报。
func TestMayContainAccentLetter(t *testing.T) {
	for r := rune(0); r <= 0x2FFFF; r++ {
		if isAccentLetter(r) && !mayContainAccentLetter("ab"+string(r)) {
			t.Fatalf("漏报 U+%04X", r)
		}
	}
	for _, s := range []string{"hello world", "我爱你", "©®", "ラブ", "привет", ""} {
		if mayContainAccentLetter(s) {
			t.Errorf("%q 不该命中", s)
		}
	}
}
