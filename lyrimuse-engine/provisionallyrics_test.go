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
	e, picked := lyricsEntryFromScored(lyricsDecisionPathFirstResolve, "x", "y", "A", 200, ne, scored, []string{"lrclib"}, q, false, "", nil)
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

	e, picked = lyricsEntryFromScored(lyricsDecisionPathFirstResolve, "x", "y", "A", 200, ne, scored[1:], nil, nil, false, "", nil)
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
		"e, picked := lyricsEntryFromScored(decisionPath, artist, title, searchAlbum, durationSecs, ne, scored,",
		"round.skippedSources(), queries.queries(), false, provisionalSource, lastShown)",
		"shown := *picked\n\t\t\t\tonScreen = &shown\n",
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

// 上屏后看不看得出差别:元信息标签、时间写法、[offset:0] 不算;正文、时间、译文任何一处不同都算。
func TestSameShownLyrics(t *testing.T) {
	kugou := scoredLyricCandidateResult{Source: "kugou",
		Lyrics:    "[ti:自由的你]\n[ar:G.E.M.]\n[00:12.5]当眼泪模糊了生活\n[00:16.30]当自我磨平了轮廓\n",
		LyricsYRC: "[id:$00000000]\n[12500,3000](12500,400,0)当(12900,400,0)眼"}
	qq := scoredLyricCandidateResult{Source: "qq",
		Lyrics:    "[ti:自由的你]\n[offset:0]\n[00:12.500] 当眼泪模糊了生活 \n\n[00:16.300]当自我磨平了轮廓",
		LyricsYRC: "[offset:0]\n[12500,3000](12500,400,0)当(12900,400,0)眼\n"}
	if !sameShownLyrics(kugou, qq) {
		t.Fatalf("只差元信息标签、时间写法和空白,该算一样: %q vs %q", shownLyricsForm(kugou.Lyrics), shownLyricsForm(qq.Lyrics))
	}
	for name, mutate := range map[string]func(*scoredLyricCandidateResult){
		"时间差 1 毫秒": func(c *scoredLyricCandidateResult) {
			c.Lyrics = strings.Replace(c.Lyrics, "[00:16.300]", "[00:16.301]", 1)
		},
		"正文一个字": func(c *scoredLyricCandidateResult) { c.Lyrics = strings.Replace(c.Lyrics, "轮廓", "轮阔", 1) },
		"逐字时间": func(c *scoredLyricCandidateResult) {
			c.LyricsYRC = strings.Replace(c.LyricsYRC, "(12900,400,0)", "(12950,350,0)", 1)
		},
		"多一份译文": func(c *scoredLyricCandidateResult) { c.LyricsTr = "[00:12.50]When tears blur life" },
		"整体偏移": func(c *scoredLyricCandidateResult) {
			c.Lyrics = strings.Replace(c.Lyrics, "[offset:0]", "[offset:300]", 1)
		},
		"背景人声": func(c *scoredLyricCandidateResult) { c.LyricsBG = "[13000,500](13000,500,0)啊" },
	} {
		changed := qq
		mutate(&changed)
		if sameShownLyrics(kugou, changed) {
			t.Errorf("%s: 该算不同", name)
		}
	}
}

// 最终定案:挑出来的是别的源、跟屏上那份看不出差别时留在屏上那个源;看得出差别、或屏上那个源这一轮没有一样的那条,照旧换。
func TestKeepShownLyrics(t *testing.T) {
	setFeatureForTest(t, func(f *featureFlags) { f.LyricsSources = map[string]bool{"qq": true, "kugou": true} })
	onScreen := scoredLyricCandidateResult{Source: "kugou", Score: 1184, Lyrics: "[00:01.00]a\n[00:02.00]b"}
	qqSame := scoredLyricCandidateResult{Source: "qq", Score: 1185, Lyrics: "[offset:0]\n[00:01.000]a\n[00:02.000]b"}
	scored := []scoredLyricCandidateResult{qqSame, onScreen}

	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(prev)
	e, picked := lyricsEntryFromScored(lyricsDecisionPathFirstResolve, "a", "t", "", 0, neteaseInfo{}, scored, nil, nil, false, "kugou", &onScreen)
	if picked == nil || picked.Source != "kugou" || e.LyricsSource != "kugou" || e.LyricsDecision.Winner != "kugou" {
		t.Fatalf("看不出差别该留在屏上那个源: picked=%+v source=%q", picked, e.LyricsSource)
	}
	if !strings.Contains(buf.String(), "kept_on_screen_over=qq") || strings.Contains(buf.String(), "provisional_winner") {
		t.Errorf("决策日志该带 kept_on_screen_over、不带 provisional_winner: %q", buf.String())
	}

	if got := keepShownLyrics(scored, &scored[0], nil); got != &scored[0] {
		t.Errorf("没有上屏过的,照旧用挑出来的")
	}
	qqDiff := scoredLyricCandidateResult{Source: "qq", Score: 1185, Lyrics: "[00:01.00]a\n[00:02.10]b"}
	diff := []scoredLyricCandidateResult{qqDiff, onScreen}
	if got := keepShownLyrics(diff, &diff[0], &onScreen); got != &diff[0] {
		t.Errorf("时间不同,该换成挑出来的那份")
	}
	gone := []scoredLyricCandidateResult{qqSame}
	if got := keepShownLyrics(gone, &gone[0], &onScreen); got != &gone[0] {
		t.Errorf("屏上那个源这一轮没有候选,照旧用挑出来的")
	}
	changed := []scoredLyricCandidateResult{qqSame, {Source: "kugou", Score: 1100, Lyrics: "[00:01.00]a\n[00:02.00]c"}}
	if got := keepShownLyrics(changed, &changed[0], &onScreen); got != &changed[0] {
		t.Errorf("屏上那个源这一轮给的跟屏上不一样了,照旧用挑出来的")
	}
}
