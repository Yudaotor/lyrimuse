package main

import (
	"bytes"
	"context"
	"log"
	"os"
	"strings"
	"testing"
)

func TestNotifyProvisionalLyrics(t *testing.T) {
	usable := []scoredLyricCandidateResult{{Source: "kugou", Score: 900, Lyrics: "[00:01.00]hi"}}
	unusable := []scoredLyricCandidateResult{{Source: "qq", Score: -1}}

	notifyProvisionalLyrics(context.Background(), neteaseInfo{}, usable) // 没挂回调:什么都不做

	var calls []int
	ctx := withProvisionalLyrics(context.Background(), func(_ neteaseInfo, r []scoredLyricCandidateResult) {
		calls = append(calls, r[0].Score)
	})
	notifyProvisionalLyrics(ctx, neteaseInfo{}, unusable)
	notifyProvisionalLyrics(ctx, neteaseInfo{}, nil)
	if len(calls) != 0 {
		t.Fatalf("没有可用候选不该回调: %v", calls)
	}
	notifyProvisionalLyrics(ctx, neteaseInfo{}, usable)
	notifyProvisionalLyrics(ctx, neteaseInfo{}, []scoredLyricCandidateResult{{Source: "qq", Score: 950}})
	if len(calls) != 1 || calls[0] != 900 {
		t.Fatalf("同一个 ctx 至多回调一次、用第一次的结果: %v", calls)
	}

	cancelled, cancel := context.WithCancel(withProvisionalLyrics(context.Background(), func(neteaseInfo, []scoredLyricCandidateResult) {
		t.Fatal("已取消不该回调")
	}))
	cancel()
	notifyProvisionalLyrics(cancelled, neteaseInfo{}, usable)
}

func TestLyricsEntryFromScored(t *testing.T) {
	scored := []scoredLyricCandidateResult{
		{Source: "kugou", Score: 900, Lyrics: "[00:01.00]hi", LyricsYRC: "[1000,500](1000,500,0)hi"},
		{Source: "qq", Score: -1},
	}
	ne := neteaseInfo{Cover: "https://example.invalid/c.jpg", Album: "A", SongURL: "https://example.invalid/s"}
	q := []lyricQueryRecord{{Artist: "x", Title: "y"}}
	e, picked := lyricsEntryFromScored(lyricsDecisionPathFirstResolve, "x", "y", "A", 200, ne, scored, []string{"lrclib"}, q, false, "")
	if picked == nil || picked.Source != "kugou" {
		t.Fatalf("picked=%+v", picked)
	}
	if e.Lyrics != "[00:01.00]hi" || e.LyricsSource != "kugou" || e.LyricsScore != 900 || e.LyricsYRC == "" ||
		e.LyricsScoringVersion != lyricsScoringVersion || e.ResolvedDurationSecs != 200 || e.DurationSecs != 200 {
		t.Fatalf("歌词字段: %+v", e)
	}
	if e.CoverURL != ne.Cover || e.CoverSource != "netease" || e.CoverAlbum != "A" || e.NeteaseURL != ne.SongURL {
		t.Fatalf("网易云封面与链接: %+v", e)
	}
	if e.LyricsDecision == nil || e.LyricsDecisionApplied != e.LyricsDecision || len(e.LyricsDecision.QueriesTried) != 1 ||
		len(e.LyricsDecision.SourcesSkipped) != 1 || len(e.LyricsSourcesSkipped) != 1 {
		t.Fatalf("决策存档: %+v", e.LyricsDecision)
	}

	e, picked = lyricsEntryFromScored(lyricsDecisionPathFirstResolve, "x", "y", "A", 200, ne, scored[1:], nil, nil, false, "")
	if picked != nil || e.Lyrics != "" || e.LyricsDecisionApplied != nil || e.LyricsDecision == nil {
		t.Fatalf("选不出歌词:只留决策存档,不写出处 %+v", e)
	}
}

// 接线守卫:首次解析挂上首轮先上屏的回调;三个补查轮(别名 / 主唱变体 / 标题反查)入口各通知一次。
// 整条检索要联网,单测跑不了,只能钉源码。
func TestProvisionalLyricsIsWired(t *testing.T) {
	data, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(data)
	for _, needle := range []string{
		"roundCtx = withProvisionalLyrics(roundCtx, func(ne neteaseInfo, scored []scoredLyricCandidateResult) {",
		"e, picked := lyricsEntryFromScored(decisionPath, artist, title, album, durationSecs, ne, scored,",
		"\tif rescue || romaRetry || len(missing) > 0 {\n\t\tnotifyProvisionalLyrics(ctx, ne, results)\n",
		"primary != \"\" && usableLyricSourceCount(results) < targetSources {\n\t\tnotifyProvisionalLyrics(ctx, ne, results)\n",
		"\n\tif usableLyricSourceCount(results) < targetSources {\n\t\tnotifyProvisionalLyrics(ctx, ne, results)\n",
	} {
		if !strings.Contains(src, needle) {
			t.Errorf("enrich.go 缺 %q", needle)
		}
	}
}

// 「歌词先上屏」一首只记一行 Info:第一次记;同一来源的第二次落 Debug;来源换了照样记,带上首轮那份的来源。
func TestEarlyCommitLogOneInfoLinePerSource(t *testing.T) {
	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(prev)

	var l earlyCommitLog
	l.note("A|T|Al", "qq")
	l.note("A|T|Al", "qq")
	if n := strings.Count(buf.String(), "committed early"); n != 1 {
		t.Fatalf("同一来源两次只该落一行 Info,got %d: %q", n, buf.String())
	}
	l.note("A|T|Al", "kugou")
	if !strings.Contains(buf.String(), "(source=kugou, replacing the first-round qq)") {
		t.Fatalf("来源换了要记下来、带上首轮那份的来源: %q", buf.String())
	}
}
