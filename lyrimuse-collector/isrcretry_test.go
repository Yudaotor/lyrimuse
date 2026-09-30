package main

import (
	"context"
	"os"
	"strings"
	"testing"
)

// 补取计划:只拿已被认可、带 ISRC、时长对得上的 applemusic 候选;deezer / musixmatch 都已有可用候选时不补。
func TestISRCRetryPlan(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	featuresRef().LyricsSources = map[string]bool{"applemusic": true, "deezer": true, "musixmatch": true, "kugou": true}

	apple := scoredLyricCandidateResult{Source: "applemusic", Score: 1169, ISRC: "JPU902104759", SourceReportedDurationSecs: 257, Lyrics: "[00:01.00]a"}
	kugou := scoredLyricCandidateResult{Source: "kugou", Score: 1087, Lyrics: "[00:01.00]a"}
	isrc, sources := isrcRetryPlan(context.Background(), []scoredLyricCandidateResult{kugou, apple}, 258)
	if isrc != "JPU902104759" || strings.Join(sources, ",") != "deezer,musixmatch" {
		t.Fatalf("got %q %v", isrc, sources)
	}
	// 两家都已经有可用候选:不补。
	dz := scoredLyricCandidateResult{Source: "deezer", Score: 900, Lyrics: "[00:01.00]a"}
	mx := scoredLyricCandidateResult{Source: "musixmatch", Score: 900, Lyrics: "[00:01.00]a"}
	if isrc, _ := isrcRetryPlan(context.Background(), []scoredLyricCandidateResult{apple, dz, mx}, 258); isrc != "" {
		t.Errorf("两家都有候选时不该补取,got %q", isrc)
	}
	// 只缺一家:只问那一家。
	if _, s := isrcRetryPlan(context.Background(), []scoredLyricCandidateResult{apple, dz}, 258); strings.Join(s, ",") != "musixmatch" {
		t.Errorf("只该问还缺着的 musixmatch,got %v", s)
	}
	// applemusic 被判废、没报 ISRC、时长对不上(Live 版):都不拿来用。
	for _, bad := range []scoredLyricCandidateResult{
		{Source: "applemusic", Score: -1, ISRC: "JPU902104759", SourceReportedDurationSecs: 257},
		{Source: "applemusic", Score: 1169, SourceReportedDurationSecs: 257},
		{Source: "applemusic", Score: 1169, ISRC: "JPU902403905", SourceReportedDurationSecs: 330},
	} {
		if isrc, _ := isrcRetryPlan(context.Background(), []scoredLyricCandidateResult{kugou, bad}, 258); isrc != "" {
			t.Errorf("%+v 不该拿来补取,got %q", bad, isrc)
		}
	}
}

// ctx 上挂的 ISRC 在播放器没给时生效;deezer / musixmatch 两路都读 lyricSourceISRC。
func TestLyricSourceISRCFromContext(t *testing.T) {
	if got := lyricSourceISRC(context.Background(), "nobody", "nothing", ""); got != "" {
		t.Fatalf("没挂也没有播放器 ISRC 时应为空,got %q", got)
	}
	if got := lyricSourceISRC(withRecordingISRC(context.Background(), "JPU902104759"), "nobody", "nothing", ""); got != "JPU902104759" {
		t.Fatalf("got %q", got)
	}
}

// 按 ISRC 补取那一轮真的能把名字搜不到的源补出来:musixmatch 换成「按名字搜空、按 ISRC 直取才有」的假实现。
func TestISRCRetryFetchesSourceMissedByName(t *testing.T) {
	saved := features()
	savedResolve := musixmatchResolve
	t.Cleanup(func() { setFeatures(saved); musixmatchResolve = savedResolve })
	resetMusixmatchCacheForTest(t)
	featuresRef().LyricsSources = map[string]bool{"musixmatch": true}
	var sawISRC []string
	musixmatchResolve = func(ctx context.Context, artist, title string, durationSecs float64, trLang, isrc string) musixmatchResult {
		sawISRC = append(sawISRC, isrc)
		if isrc != "JPU902104759" {
			return musixmatchResult{}
		}
		return musixmatchResult{lrc: "[00:05.00]一行目\n[00:15.00]二行目\n[00:25.00]三行目\n[00:35.00]四行目\n[00:45.00]五行目\n[02:50.00]最後",
			title: "Kimini Muchuu", artist: "Hikaru Utada", durationSecs: 258}
	}
	_, plain := fetchScoredLyricCandidatesStreaming(context.Background(), "宇多田ヒカル", "君に夢中", "BADモード", 258, nil)
	if hasUsableLyricCandidate(plain) {
		t.Fatalf("按名字搜本来就该是空的: %+v", plain)
	}
	ctx := withLyricQueryReason(withLyricSourceOnly(withRecordingISRC(context.Background(), "JPU902104759"), []string{"musixmatch"}), lyricQueryReasonISRC)
	_, got := fetchScoredLyricCandidatesStreaming(ctx, "宇多田ヒカル", "君に夢中", "BADモード", 258, nil)
	if !hasUsableLyricCandidate(got) || got[0].Source != "musixmatch" {
		t.Fatalf("挂上 ISRC 之后 musixmatch 该给出可用候选: %+v", got)
	}
	if len(sawISRC) != 2 || sawISRC[0] != "" || sawISRC[1] != "JPU902104759" {
		t.Errorf("两次调用该分别带空 ISRC 与补取的 ISRC,got %q", sawISRC)
	}
}

// 接线守卫:applemusic 结果把 ISRC 带进候选;补取轮排在所有轮次之后;deezer / musixmatch 两路读 lyricSourceISRC。
func TestISRCRetryIsWired(t *testing.T) {
	b, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	for _, n := range []string{
		"srcDur: r.durationSecs, isrc: r.isrc,",
		"isrc:                       am.isrc,",
		"ISRC:                       c.isrc,",
		"isrc:                       r.ISRC,",
		"lyricSourceISRC(ctx, artist, title, album))\n\t\tresultsCh <- lyricSourceResult{source: \"musixmatch\"",
		"lyricSourceISRC(ctx, artist, title, album))\n\t\tresultsCh <- lyricSourceResult{source: \"deezer\"",
		"if isrc, sources := isrcRetryPlan(ctx, results, durationSecs); isrc != \"\" {",
	} {
		if !strings.Contains(src, n) {
			t.Errorf("enrich.go 缺 %q", n)
		}
	}
	i := strings.Index(src, "func scoredLyricCandidatesStreaming(")
	body := src[i:]
	body = body[:strings.Index(body, "\n}\n")]
	if !strings.HasSuffix(strings.TrimSpace(body), "results = merged\n\t}\n\treturn ne, results") {
		t.Error("按 ISRC 补取要排在 scoredLyricCandidatesStreaming 所有轮次之后、紧挨着 return")
	}
	a, err := os.ReadFile("applemusic.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(a), "`json:\"isrc\"`") || !strings.Contains(string(a), "isrc: s.Attributes.Isrc,") {
		t.Error("applemusic 没解析 / 没透传 song attributes 里的 isrc")
	}
}
