package main

import (
	"context"
	"strings"
	"testing"
)

// 09 章决策 209:伴奏版按纯音乐处理;重评不再护着只有署名的当前歌词。样本里的人名、歌词全是虚构占位。

const instrumentalTestLyrics = "[00:05.00]占位歌词行一二三四五六\n[00:15.00]占位歌词行七八九十十一\n" +
	"[00:25.00]占位歌词行十二十三十四\n[02:50.00]占位歌词行最后一句"

const creditOnlyTestLyrics = "[00:00.00]作曲：甲\n[00:01.00]作词：乙\n[00:02.00]编曲：丙\n[00:03.00]混音：丁"

func TestLocalIsInstrumentalVersion(t *testing.T) {
	for _, c := range []struct {
		title, album string
		want         bool
	}{
		{"占位曲 (伴奏)", "", true},
		{"占位曲（伴奏）", "", true},
		{"占位曲 (DJ阿卓版伴奏)", "", true},
		{"Song (Instrumental)", "", true},
		{"Song - Instrumental", "", true},
		{"占位曲", "占位专辑 (纯音乐)", true},
		{"占位曲", "", false},
		{"Song (Live)", "", false},
		{"Song (Karaoke Version)", "", false},
		{"Instrumental Love", "", false},
	} {
		if got := localIsInstrumentalVersion(c.title, c.album); got != c.want {
			t.Errorf("localIsInstrumentalVersion(%q, %q) = %v, want %v", c.title, c.album, got, c.want)
		}
	}
}

func TestScoreRejectsLyricsForInstrumentalTrack(t *testing.T) {
	c := lyricCandidate{source: "qq", lyrics: instrumentalTestLyrics, title: "占位曲", album: "占位专辑"}
	score, terms := scoreLyricCandidateDetailed("甲", "占位曲 (伴奏)", "占位专辑", 180, c, false, 0)
	if score != -1 || len(terms) == 0 || terms[0].Kind != scoreRejectInstrumentalTrack {
		t.Errorf("伴奏版遇上带正文的候选应判 %s,得到 %d %+v", scoreRejectInstrumentalTrack, score, terms)
	}
	if score, _ := scoreLyricCandidateDetailed("甲", "占位曲", "占位专辑", 180, c, false, 0); score <= 0 {
		t.Errorf("不是伴奏版照常打分,得到 %d", score)
	}
	credit := lyricCandidate{source: "qq", lyrics: creditOnlyTestLyrics, title: "占位曲 (伴奏)", album: "占位专辑"}
	if _, terms := scoreLyricCandidateDetailed("甲", "占位曲 (伴奏)", "占位专辑", 180, credit, false, 0); len(terms) == 0 ||
		terms[0].Kind != scoreRejectCreditOnly {
		t.Errorf("只有署名的照旧报只有署名,得到 %+v", terms)
	}
}

func TestInstrumentalFromScoredLocalVersion(t *testing.T) {
	if ok, src := instrumentalFromScored(nil, "甲", "占位曲 (伴奏)", "", 0); !ok || src != "instrumental version" {
		t.Errorf("本地标着伴奏就算纯音乐的依据,得到 %v %q", ok, src)
	}
	if ok, _ := instrumentalFromScored(nil, "甲", "占位曲", "", 0); ok {
		t.Error("没有标记、也不是伴奏版,不该判纯音乐")
	}
}

// rescoreInstrumentalEntry 放一条条目、跑一次重评(manual 时走手动重新匹配那一套),返回跑完的条目和结论。
func rescoreInstrumentalEntry(t *testing.T, title string, e enrichEntry, manual bool) (enrichEntry, lyricsRematchResult) {
	t.Helper()
	key := enrichKey(rescoreTestArtist, title, "")
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{key: e}
	enrichMu.Unlock()
	var r lyricsRematchResult
	rescoreLyricsWith(context.Background(), key, rescoreTestArtist, title, "", 180, lyricsRescoreOpts{manual: manual, result: &r})
	enrichMu.Lock()
	defer enrichMu.Unlock()
	return enrichCache[key], r
}

func TestRescoreReplacesCreditOnlyLyricsDespiteWordTiming(t *testing.T) {
	setupRescoreTest(t, []string{"musixmatch"}, nil)
	e, r := rescoreInstrumentalEntry(t, "Credit Song", enrichEntry{
		Lyrics: creditOnlyTestLyrics, LyricsYRC: "[0,500](0,500,0)作曲：甲", LyricsSource: "musixmatch",
		LyricsScoringVersion: lyricsScoringVersion - 1,
	}, false)
	if !strings.HasPrefix(e.Lyrics, "[00:05.00]Brand new first line") || r.Outcome != lyricsRematchChanged {
		t.Errorf("只有署名的当前这份不受逐字保护,该换成冠军:%q outcome=%s", e.Lyrics, r.Outcome)
	}
}

func TestRescoreMarksInstrumentalVersion(t *testing.T) {
	setupRescoreTest(t, []string{"musixmatch"}, nil)
	const old = "[00:05.00]Old line one\n[00:15.00]Old line two\n[00:25.00]Old line three\n[02:50.00]Old last line"
	entry := enrichEntry{Lyrics: old, LyricsSource: "musixmatch", LyricsScoringVersion: lyricsScoringVersion - 1}

	e, _ := rescoreInstrumentalEntry(t, "Inst Song (Instrumental)", entry, false)
	if !e.Instrumental || e.Lyrics != old {
		t.Errorf("伴奏版、候选全被拒:标纯音乐、歌词留着,得到 instrumental=%v lyrics=%q", e.Instrumental, e.Lyrics)
	}
	if e, r := rescoreInstrumentalEntry(t, "Inst Song (Instrumental)", entry, true); !e.Instrumental ||
		r.Outcome != lyricsRematchInstrumental {
		t.Errorf("手动重新匹配同样标纯音乐、结论报 instrumental,得到 %v %s", e.Instrumental, r.Outcome)
	}
	cleared := entry
	cleared.InstrumentalCleared = true
	if e, _ := rescoreInstrumentalEntry(t, "Inst Song (Instrumental)", cleared, false); e.Instrumental {
		t.Error("用户撤过纯音乐标记的不再自动标")
	}
}

func TestRescoreMarksCreditOnlyLyricsInstrumental(t *testing.T) {
	setupRescoreTest(t, []string{"musixmatch"}, nil)
	musixmatchResolve = func(ctx context.Context, artist, title string, durationSecs float64, trLang, isrc string) musixmatchResult {
		return musixmatchResult{instrumental: true, title: title, artist: artist}
	}
	e, _ := rescoreInstrumentalEntry(t, "Credit Song", enrichEntry{
		Lyrics: creditOnlyTestLyrics, LyricsSource: "musixmatch", LyricsScoringVersion: lyricsScoringVersion - 1,
	}, false)
	if !e.Instrumental {
		t.Error("当前这份只有署名、这一轮有源说是纯音乐:标纯音乐")
	}
}

func TestLyricsAreCreditsOnly(t *testing.T) {
	for _, c := range []struct {
		name, lrc string
		want      bool
	}{
		{"整份署名", creditOnlyTestLyrics, true},
		{"开头标签 + 抬头 + 署名", "[ti:占位曲 (伴奏)]\n[offset:0]\n[00:00.77]占位曲 (伴奏) - 甲\n" + creditOnlyTestLyrics, true},
		{"署名 + 纯音乐占位", "[00:00.00] 作曲 : 甲\n[00:05.00]纯音乐，请欣赏\n[02:08.88] 吉他 : 乙", true},
		{"两行真歌词、没有署名", "[00:05.00]占位歌词行一\n[00:15.00]占位歌词行二", false},
		{"一行作词 + 两行真歌词", "[00:00.00]作词：甲\n[00:05.00]占位歌词行一\n[00:15.00]占位歌词行二", false},
		{"整首真歌词", instrumentalTestLyrics, false},
	} {
		if got := lyricsAreCreditsOnly(c.lrc); got != c.want {
			t.Errorf("%s: lyricsAreCreditsOnly = %v, want %v", c.name, got, c.want)
		}
	}
}
