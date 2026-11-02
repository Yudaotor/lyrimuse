package main

import (
	"fmt"
	"os"
	"strings"
	"testing"
)

// testPlayerLRC 拼一份 12 行、每行文字不同的 LRC,第 i 行在 startMs + i*5000(+shiftMs)。
func testPlayerLRC(shiftMs int) string {
	var b strings.Builder
	for i := 0; i < 12; i++ {
		ms := 20000 + i*5000 + shiftMs
		fmt.Fprintf(&b, "[%02d:%02d.%02d]line number %d of the song\n", ms/60000, ms/1000%60, ms%1000/10, i)
	}
	return b.String()
}

func TestNeedsPlayerLyricsCheck(t *testing.T) {
	soda := playerBundleIDs[playerSoda]
	base := enrichEntry{Lyrics: bt(testPlayerLRC(0)), LyricsSource: "applemusic"}
	checked := base
	checked.PlayerLyrics = map[string]playerLyricsAlt{soda: {MainFP: mainLyricsFingerprint(base)}}
	stale := base
	stale.PlayerLyrics = map[string]playerLyricsAlt{soda: {MainFP: "000000000000"}}
	sameSource := base
	sameSource.LyricsSource = "soda"
	instrumental := base
	instrumental.Instrumental = true
	handEdited := base
	handEdited.ManualLyrics, handEdited.ManualPickSHA = true, "edited"
	picked := base
	picked.ManualLyrics, picked.ManualPickSHA = true, manualPickFingerprint(base.Lyrics.String())
	pickedUnlocked := base
	pickedUnlocked.ManualPickSHA = manualPickFingerprint(base.Lyrics.String())
	resolved := base
	resolved.ResolvedDurationSecs = 232.25

	cases := []struct {
		name     string
		e        enrichEntry
		bundle   string
		duration float64
		want     bool
	}{
		{"放的跟选主歌词时同一个长度:不比", resolved, soda, 232.0, false},
		{"放的比选主歌词时长 4.7 秒:要比", resolved, soda, 236.95, true},
		{"播放器没报曲长:照比", resolved, soda, 0, true},
		{"主歌词不是这个播放器自家源:要比", base, soda, 0, true},
		{"比过、主歌词没变:不再比", checked, soda, 0, false},
		{"比过、主歌词换了:重比", stale, soda, 0, true},
		{"主歌词就是它自家源:不比", sameSource, soda, 0, false},
		{"纯音乐不比", instrumental, soda, 0, false},
		{"正文手改过不比", handEdited, soda, 0, false},
		{"原样采纳的候选不比(锁定着)", picked, soda, 0, false},
		{"原样采纳的候选不比(没锁定)", pickedUnlocked, soda, 0, false},
		{"认不出的播放器不比", base, "com.example.unknown", 0, false},
		{"没有歌词不比", enrichEntry{LyricsSource: "applemusic"}, soda, 0, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := needsPlayerLyricsCheck(c.e, c.bundle, c.duration); got != c.want {
				t.Fatalf("needsPlayerLyricsCheck = %v, 期望 %v", got, c.want)
			}
		})
	}

	withFeaturesFile(t, `{"lyrics_sources":["applemusic","qq"]}`)
	if needsPlayerLyricsCheck(base, soda, 0) {
		t.Fatal("这个播放器的自家源在设置里关着:不比")
	}
}

func TestDropUnusablePlayerLyrics(t *testing.T) {
	soda := playerBundleIDs[playerSoda]
	music := playerBundleIDs[playerAppleMusic]
	base := enrichEntry{Lyrics: bt(testPlayerLRC(0)), LyricsSource: "applemusic", ResolvedDurationSecs: 232.25}
	base.PlayerLyrics = map[string]playerLyricsAlt{
		soda:  {MainFP: mainLyricsFingerprint(base), Source: "soda", Lyrics: testPlayerLRC(2500), ShiftMs: 2500},
		music: {MainFP: mainLyricsFingerprint(base)},
	}

	e := base
	if dropUnusablePlayerLyricsLocked("k", &e, soda, 240) || len(e.PlayerLyrics) != 2 {
		t.Fatalf("曲长不同、主歌词不是用户给的:留着, %+v", e.PlayerLyrics)
	}
	e = base
	if !dropUnusablePlayerLyricsLocked("k", &e, soda, 232.0) {
		t.Fatal("放的跟选主歌词时同一个长度:该删")
	}
	if _, ok := e.PlayerLyrics[soda]; ok || len(e.PlayerLyrics) != 1 || len(base.PlayerLyrics) != 2 {
		t.Fatalf("只删这个播放器那一项、不改原 map, 得到 %+v / 原 %+v", e.PlayerLyrics, base.PlayerLyrics)
	}
	e = base
	e.ManualPickSHA = manualPickFingerprint(e.Lyrics.String())
	if !dropUnusablePlayerLyricsLocked("k", &e, soda, 240) {
		t.Fatal("主歌词是用户采纳的:该删")
	}
	e = base
	if dropUnusablePlayerLyricsLocked("k", &e, music, 232.0) {
		t.Fatal("只记了「比过」的那一项没有正文,不动")
	}
}

// 播放时记着的那份按现在的规则不该用就删掉:接在命中缓存那一支顺手修条目的地方,跟着一起落盘。
func TestDropUnusablePlayerLyricsWiredOnPlay(t *testing.T) {
	src, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	if !containsCode(string(src), "if dropUnusablePlayerLyricsLocked(key, &e, bundleID, durationSecs) {\n\t\t\tspotifyHintDirty = true\n\t\t}\n\t\tif spotifyHintDirty {") {
		t.Fatal("enrich.go 命中缓存那一支没在落盘判断之前删掉不该用的播放器那份")
	}
}

func TestPlayerLyricsAltFrom(t *testing.T) {
	main := testPlayerLRC(0)
	cand := func(shiftMs int, local bool, score int) scoredLyricCandidateResult {
		return scoredLyricCandidateResult{Source: "soda", Lyrics: testPlayerLRC(shiftMs), LyricsTr: "[00:20.00]译文", LyricsTrLang: "zh",
			Score: score, IdentityFromLocalClient: local}
	}
	fp := lyricSpeakersFingerprint(main, "")

	alt, ok := playerLyricsAltFrom(main, "", cand(2200, true, 1300), 42)
	if !ok || alt.Lyrics == "" || alt.Source != "soda" || alt.ShiftMs != 2200 || alt.MainFP != fp || alt.Tr == "" || alt.TrLang != "zh" || alt.At != 42 {
		t.Fatalf("整体晚 2.2 秒:该记下这一份和偏移,得到 ok=%v %+v", ok, alt)
	}
	if alt, ok = playerLyricsAltFrom(main, "", cand(-1500, true, 1300), 42); !ok || alt.Lyrics == "" || alt.ShiftMs != -1500 {
		t.Fatalf("整体早 1.5 秒:同样记下,得到 ok=%v %+v", ok, alt)
	}
	if alt, ok = playerLyricsAltFrom(main, "", cand(300, true, 1300), 42); !ok || alt.Lyrics != "" || alt.MainFP != fp || alt.ShiftMs != 0 {
		t.Fatalf("差 0.3 秒算对齐:只记比对过,得到 ok=%v %+v", ok, alt)
	}
	if _, ok = playerLyricsAltFrom(main, "", cand(2200, false, 1300), 42); ok {
		t.Fatal("不是按本机认出的这一首取的(搜出来的):不算数")
	}
	if _, ok = playerLyricsAltFrom(main, "", cand(2200, true, -1), 42); ok {
		t.Fatal("被判了负分:不算数")
	}
}
