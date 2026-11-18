package main

import (
	"context"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

const megalobizTestSearch = `{"query":{"title":"Mode de vie","artist":"Tiakola","duration":190},"count":3,"results":[
{"id":323234,"title":"Mode de vie","artist":"Tiakola","duration":190.7,"duration_diff":0.7,"sync":"manual","score":1,"url":"https://megalobiz.com/lrc/323234/mode-de-vie"},
{"id":196464,"title":"Mode AV (feat. Niska & Gazo)","artist":"Tiakola","duration":192.97,"sync":"manual","score":0.68,"url":"https://megalobiz.com/lrc/196464/mode-av"},
{"id":165641,"title":"C'est La Vie (Cinematic Mix)","artist":"","duration":188.22,"sync":"manual","score":0.39,"url":"https://megalobiz.com/lrc/165641/c-est-la-vie"}]}`

const megalobizTestLRC = `{"id":323234,"title":"Mode de vie","artist":"Tiakola","duration":190.69,"sync":"manual","url":"https://megalobiz.com/lrc/323234/mode-de-vie",
"lines":[{"time_ms":5077,"text":"Eh, eh, eh"},{"time_ms":6928,"text":"Tu trahis la honda"},{"time_ms":9319,"text":"La maison"},{"time_ms":11978,"text":""},{"time_ms":14117,"text":"La maison (brhhha)"}],
"lrc":"[ar:Tiakola]\n[ti:Mode de vie]\n[re:Megalobiz]\n[00:05.07]Eh, eh, eh"}`

func megalobizItem(title, artist string, dur float64) megalobizSearchItem {
	return megalobizSearchItem{ID: 1, Title: title, Artist: artist, Duration: dur}
}

func resetMegalobizCacheForTest(t *testing.T) {
	t.Helper()
	megalobizMu.Lock()
	saved := megalobizCache
	megalobizCache = map[string]megalobizResult{}
	megalobizMu.Unlock()
	t.Cleanup(func() {
		megalobizMu.Lock()
		megalobizCache = saved
		megalobizMu.Unlock()
	})
}

func TestMegalobizSongTitle(t *testing.T) {
	for _, c := range []struct{ raw, artist, local, wantTitle, wantArtist string }{
		{"Mode de vie", "Tiakola", "Mode de vie", "Mode de vie", "Tiakola"},
		{"[SPOTDOWNLOADER.COM] Обійми", "", "Обійми", "Обійми", ""},
		{"Dorofeeva - Кохаю, але не зовсім (-)", "", "Кохаю, але не зовсім", "Кохаю, але не зовсім (-)", "Dorofeeva"},
		{"INSTASAMKA - ЗА ДЕНЬГИ ДА", "", "ЗА ДЕНЬГИ ДА", "ЗА ДЕНЬГИ ДА", "INSTASAMKA"},
		// 歌名自己带「 - 」、原样对得上的不拆。
		{"月を見ていた - Moongazing", "", "月を見ていた - Moongazing", "月を見ていた - Moongazing", ""},
		// 歌手栏有字的不拆。
		{"Dorofeeva - Кохаю", "Someone", "Кохаю", "Dorofeeva - Кохаю", "Someone"},
		// 拆出来的歌名对不上本地歌名,不拆。
		{"Alpha - Beta", "", "Gamma", "Alpha - Beta", ""},
		// 方括号里没有点号的不是下载站标记。
		{"[Live] Song", "X", "[Live] Song", "[Live] Song", "X"},
	} {
		title, artist := megalobizSongTitle(c.raw, c.artist, c.local)
		if title != c.wantTitle || artist != c.wantArtist {
			t.Errorf("megalobizSongTitle(%q,%q,%q) = %q,%q 期望 %q,%q", c.raw, c.artist, c.local, title, artist, c.wantTitle, c.wantArtist)
		}
	}
}

func TestMegalobizCandidateScoreGates(t *testing.T) {
	ok := megalobizCandidateScore(megalobizItem("Mode de vie", "Tiakola", 190.7), "Tiakola", "Mode de vie", "", 190)
	if ok < 0 {
		t.Fatalf("歌名、歌手、时长都对得上的应收: %d", ok)
	}
	for name, s := range map[string]int{
		"歌名对不上":       megalobizCandidateScore(megalobizItem("Les Misérables", "Tiakola", 190), "Tiakola", "Mode de vie", "", 190),
		"歌手对不上":       megalobizCandidateScore(megalobizItem("Mode de vie", "Gazo", 190), "Tiakola", "Mode de vie", "", 190),
		"版本对不上":       megalobizCandidateScore(megalobizItem("Mode de vie (Live)", "Tiakola", 190), "Tiakola", "Mode de vie", "", 190),
		"时长差超过 8 秒":   megalobizCandidateScore(megalobizItem("Mode de vie", "Tiakola", 199), "Tiakola", "Mode de vie", "", 190),
		"时长差超过 25%":   megalobizCandidateScore(megalobizItem("Mode de vie", "Tiakola", 30), "Tiakola", "Mode de vie", "", 22),
		"没歌手、时长差 3 秒": megalobizCandidateScore(megalobizItem("Gut genug", "", 191.9), "Kerstin Ott", "Gut genug", "", 188.9),
		"没歌手、本地没时长":   megalobizCandidateScore(megalobizItem("Gut genug", "", 188.9), "Kerstin Ott", "Gut genug", "", 0),
		"没歌手、歌名不完全相同": megalobizCandidateScore(megalobizItem("Gut genug Remastered", "", 188.9), "Kerstin Ott", "Gut genug", "", 188.9),
		// 歌名闸认「去掉本地歌名里的合作署名后相同」,只凭歌名认人时不认。
		"没歌手、去掉合作署名才相同": megalobizCandidateScore(megalobizItem("Gut genug", "", 188.9), "Kerstin Ott", "Gut genug feat. Someone", "", 188.9),
		"没歌手、两边都没时长":    megalobizCandidateScore(megalobizItem("Gut genug", "", 0), "Kerstin Ott", "Gut genug", "", 0),
		// 德文儿歌翻唱对上英文原声带:歌名去掉括号相同、时长只差一秒,候选多出的括号段说明是另一版。
		"没歌手、候选多出括号段": megalobizCandidateScore(megalobizItem("Hakuna Matata (From The Lion King Soundtrack)", "", 213.62), "voXXclub & Giraffenaffen", "Hakuna Matata", "", 214.5),
	} {
		if s >= 0 {
			t.Errorf("%s 应淘汰,得分 %d", name, s)
		}
	}
	if s := megalobizCandidateScore(megalobizItem("Gut genug", "", 188.86), "KITSCHKRIEG", "Gut Genug (mit Blumengarten & Shirin David)", "", 189); s < 0 {
		t.Errorf("没歌手:本地歌名带括号段、候选没有的照收: %d", s)
	}
	if s := megalobizCandidateScore(megalobizItem("Hakuna Matata (Live)", "", 214), "X", "Hakuna Matata (Live)", "", 214); s < 0 {
		t.Errorf("没歌手:两边括号段一样的照收: %d", s)
	}
	noArtist := megalobizCandidateScore(megalobizItem("Gut genug", "", 188.86), "Kerstin Ott", "Gut genug", "", 188)
	if noArtist < 0 || noArtist >= ok {
		t.Errorf("没歌手、歌名相同、时长差 1 秒内的应收、但排在对得上歌手的后面: noArtist=%d withArtist=%d", noArtist, ok)
	}
	if s := megalobizCandidateScore(megalobizItem("Yesterday", "The Beatles", 125.7), "The Beatles", "Yesterday", "Help!", 0); s < 0 {
		t.Errorf("本地不知道时长、歌手对得上的照收: %d", s)
	}
}

func TestMegalobizBuildLRC(t *testing.T) {
	got := megalobizBuildLRC(megalobizLRCBody{Lines: []megalobizLine{
		{TimeMs: 1000, Text: " a "}, {TimeMs: 2500, Text: ""}, {TimeMs: 2000, Text: "倒退的丢掉"}, {TimeMs: 3000, Text: "b"},
	}})
	if got != "[00:01.00]a\n[00:02.50]\n[00:03.00]b\n" {
		t.Errorf("lines 拼 LRC: %q", got)
	}
	got = megalobizBuildLRC(megalobizLRCBody{LRC: "[ar:X]\r\n[ti:Y]\r\n[length:03:10.69]\r\n[re:Megalobiz]\r\n[00:05.07]Eh\r\n[00:06.92]Tu\r\n"})
	if got != "[00:05.07]Eh\n[00:06.92]Tu\n" {
		t.Errorf("lines 空时退回 lrc 全文、去掉标签行: %q", got)
	}
}

func TestMegalobizMarkupHeavy(t *testing.T) {
	bad := "[00:02.65]{00:02.65,A]( I {00:04.40,E]n\n[00:07.38]{00:07.38,A]( I n\n[00:12.11]Snow is {00:12.11,A]fallin'\n[00:15.00]All around me\n"
	if !megalobizMarkupHeavy(bad) {
		t.Errorf("一大半句子带编辑器标记的整份不用")
	}
	third := "[00:01.00]{00:01.00,A]a\n[00:02.00]{00:02.00,A]b\n[00:03.00]c\n[00:04.00]d\n[00:05.00]e\n[00:06.00]f\n"
	if !megalobizMarkupHeavy(third) {
		t.Errorf("三分之一的句子带标记(超过五分之一)整份不用")
	}
	ok := "[00:01.00]Snow is fallin'\n[00:02.00]All around me\n[00:03.00]Children playin'\n[00:04.00]Having fun\n[00:05.00]{00:05.00,A]one stray\n[00:06.00]It's the season\n"
	if megalobizMarkupHeavy(ok) {
		t.Errorf("个别句子带标记的照用")
	}
}

func TestMegalobizPageURL(t *testing.T) {
	for in, want := range map[string]string{
		"https://megalobiz.com/lrc/323234/mode-de-vie":        "https://megalobiz.com/lrc/323234/mode-de-vie",
		" https://www.megalobiz.com/lrc/1/x ":                 "https://www.megalobiz.com/lrc/1/x",
		"http://megalobiz.com/lrc/1/x":                        "",
		"https://megalobiz.com.evil.example/lrc/1":            "",
		"https://user@megalobiz.com/lrc/1":                    "",
		"javascript:alert(1)":                                 "",
		"":                                                    "",
		"https://api.megalobiz.com/api/public/v1/lrc/1":       "",
		"https://megalobiz.com/lrc/104636/%E5%B0%91%E5%B9%B4": "https://megalobiz.com/lrc/104636/%E5%B0%91%E5%B9%B4",
	} {
		if got := megalobizPageURL(in); got != want {
			t.Errorf("megalobizPageURL(%q) = %q 期望 %q", in, got, want)
		}
	}
}

func TestMegalobizQueriesAndSearchURL(t *testing.T) {
	got := megalobizQueries("Tiakola, Gazo", "Mode de vie")
	want := []megalobizQuery{{"Mode de vie", "Tiakola"}, {"Mode de vie", ""}}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Errorf("没被清理的歌名只有两条检索: %+v", got)
	}
	if u := megalobizSearchURL("Mode de vie", "Tiakola", 190.4); u != megalobizAPIBase+"/search?artist=Tiakola&duration=190&limit=10&title=Mode+de+vie" {
		t.Errorf("搜索地址: %s", u)
	}
	if u := megalobizSearchURL("Обійми", "", 0); strings.Contains(u, "artist=") || strings.Contains(u, "duration=") {
		t.Errorf("没有歌手、时长时不带这两个参数: %s", u)
	}
}

func TestResolveMegalobizLyricEndToEnd(t *testing.T) {
	resetMegalobizCacheForTest(t)
	var mu sync.Mutex
	var searches []string
	var uas []string
	withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
		mu.Lock()
		uas = append(uas, r.Header.Get("User-Agent"))
		mu.Unlock()
		switch {
		case target == "https://api.megalobiz.com/api/public/v1/search":
			mu.Lock()
			searches = append(searches, r.URL.Query().Get("title")+"|"+r.URL.Query().Get("artist")+"|"+r.URL.Query().Get("duration"))
			mu.Unlock()
			if r.URL.Query().Get("artist") != "" {
				return http.StatusOK, `{"count":0,"results":[]}`
			}
			return http.StatusOK, megalobizTestSearch
		case target == "https://api.megalobiz.com/api/public/v1/lrc/323234":
			return http.StatusOK, megalobizTestLRC
		}
		return http.StatusNotFound, `{"error":"not_found"}`
	})
	ctx, sub := withLyricSubFetch(qqRoundCtx())
	r := megalobizLyric(ctx, "Tiakola", "Mode de vie", "", 190)
	if len(searches) != 2 || searches[0] != "Mode de vie|Tiakola|190" || searches[1] != "Mode de vie||190" {
		t.Fatalf("「歌名 + 歌手」一条都没有时只按歌名再搜一次: %v", searches)
	}
	if !strings.HasPrefix(r.lyrics, "[00:05.07]Eh, eh, eh\n[00:06.92]Tu trahis la honda\n") || !isTimedLRC(r.lyrics) {
		t.Fatalf("正文: %q", r.lyrics)
	}
	if r.title != "Mode de vie" || r.artist != "Tiakola" || r.url != "https://megalobiz.com/lrc/323234/mode-de-vie" || r.durationSecs != 190.69 {
		t.Errorf("元数据: %+v", r)
	}
	if !sub.complete(ctx) {
		t.Errorf("都问成了应算完整")
	}
	for _, ua := range uas {
		if !strings.HasPrefix(ua, clientName+"/") || !strings.Contains(ua, "https://github.com/Yudaotor/lyrimuse") {
			t.Errorf("条款要求 User-Agent 写明 App 名和联系网址: %q", ua)
		}
	}
}

// 第一名取词 404(答了没有)退到第二名;第一名没问成(5xx)不往下取、记没问成、不进进程内缓存。
func TestResolveMegalobizLyricFetchFallback(t *testing.T) {
	search := `{"results":[{"id":11,"title":"Song","artist":"Artist","duration":200,"url":"https://megalobiz.com/lrc/11/song"},
{"id":12,"title":"Song","artist":"Artist","duration":203,"url":"https://megalobiz.com/lrc/12/song"},
{"id":13,"title":"Song","artist":"Artist","duration":204,"url":"https://megalobiz.com/lrc/13/song"}]}`
	lrc := func(id string) string {
		return `{"id":` + id + `,"url":"https://megalobiz.com/lrc/` + id + `/song","lines":[{"time_ms":1000,"text":"a"},{"time_ms":2000,"text":"b"},{"time_ms":3000,"text":"c"}]}`
	}
	for _, c := range []struct {
		name         string
		first        int
		wantURL      string
		wantComplete bool
		wantFetches  int
	}{
		{"第一名 404,退到第二名", http.StatusNotFound, "https://megalobiz.com/lrc/12/song", true, 2},
		{"第一名 502,不往下取", http.StatusBadGateway, "", false, 1},
		{"前两名都 404,第三名不取", -404, "", true, 2},
	} {
		resetMegalobizCacheForTest(t)
		var mu sync.Mutex
		fetches := 0
		withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
			switch {
			case strings.HasSuffix(target, "/search"):
				return http.StatusOK, search
			case strings.HasSuffix(target, "/lrc/11"):
				mu.Lock()
				fetches++
				mu.Unlock()
				if c.first < 0 {
					return -c.first, ""
				}
				return c.first, ""
			case c.first < 0 && strings.HasSuffix(target, "/lrc/12"):
				mu.Lock()
				fetches++
				mu.Unlock()
				return http.StatusNotFound, ""
			case strings.Contains(target, "/lrc/"):
				mu.Lock()
				fetches++
				mu.Unlock()
				return http.StatusOK, lrc(target[strings.LastIndex(target, "/")+1:])
			}
			return http.StatusNotFound, ""
		})
		ctx, sub := withLyricSubFetch(qqRoundCtx())
		r := resolveMegalobizLyric(ctx, "Artist", "Song", "", 200)
		if r.url != c.wantURL || (c.wantURL != "") != (r.lyrics != "") {
			t.Errorf("%s: %+v", c.name, r)
		}
		if got := sub.complete(ctx); got != c.wantComplete {
			t.Errorf("%s: complete = %v,期望 %v", c.name, got, c.wantComplete)
		}
		if fetches != c.wantFetches {
			t.Errorf("%s: 取词 %d 次,期望 %d(最多取 %d 份,第三名不取)", c.name, fetches, c.wantFetches, megalobizMaxCandidatesToFetch)
		}
	}
}

// 前台吃到 429:不进进程内缓存,这个源按 Retry-After 冷却(现有的歌词源熔断);待播队列的预解析(后台档)吃到 429 时
// 后台请求暂停(出站闸的后台暂停)。
func TestMegalobizRateLimitedUsesBreakerAndBackgroundPause(t *testing.T) {
	resetMegalobizCacheForTest(t)
	withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
		return http.StatusTooManyRequests, `{"error":"rate_limited"}`
	})
	ctx, sub := withLyricSubFetch(qqRoundCtx())
	if r := megalobizLyric(ctx, "Tiakola", "Mode de vie", "", 190); r.lyrics != "" {
		t.Fatalf("429 不该有结果: %+v", r)
	}
	if _, cooling := sharedLyricSourceBreaker().coolingDown(lyricSourceMegalobiz); !cooling {
		t.Errorf("前台 429 后这个源应进冷却")
	}
	_ = sub
	megalobizMu.Lock()
	n := len(megalobizCache)
	megalobizMu.Unlock()
	if n != 0 {
		t.Errorf("没问成的不进进程内缓存")
	}

	resetMegalobizCacheForTest(t)
	withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
		return http.StatusTooManyRequests, ""
	})
	bg, _ := withLyricSourceRound(withBackgroundOutbound(withPlayerQueueTrack(context.Background())))
	megalobizLyric(bg, "Tiakola", "Mode de vie", "", 190)
	if _, paused := sharedHostGuard().backgroundPausedUntil("api.megalobiz.com"); !paused {
		t.Errorf("后台档 429 后后台请求应暂停")
	}
}

// 条款:每个 IP 每分钟 30 次、每天 1000 次。令牌桶任意一分钟最多放 burst + 60*perSec 个;后台小时额度摊满一天不超过每天的上限。
func TestMegalobizRateAndBudgetWithinTerms(t *testing.T) {
	r := hostRateFor("api.megalobiz.com")
	if perMinute := r.burst + 60*r.perSec; perMinute > 30 {
		t.Errorf("令牌桶一分钟最多放 %.1f 个,超过每分钟 30 次", perMinute)
	}
	if b := lyricSourceHourlyBudget(lyricSourceMegalobiz); b <= 0 || b*24 > 1000 {
		t.Errorf("小时额度 %d 摊满一天超过每天 1000 次,或没配", b)
	}
	for _, s := range lyricSourceNames {
		if s != lyricSourceMegalobiz && lyricSourceHourlyBudget(s) != 0 {
			t.Errorf("别的源不该有小时额度: %s", s)
		}
	}
	if lyricSourceForHost("api.megalobiz.com") != lyricSourceMegalobiz {
		t.Errorf("接口主机要归到这个源,429 才走歌词源熔断")
	}
}

// 条款不许整库批量下载:批量轮次(ctx 带 withBackgroundOutbound,全量扫库、补空扫描、按组重搜、专辑预取、导入清单)一律不问
// Megalobiz,也不记跳过;正在放的那首、待播队列、手动搜索照问。别的源不受影响。
func TestMegalobizSkippedInBulkRounds(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	resetMegalobizCacheForTest(t)
	featuresRef().LyricsSources = map[string]bool{"megalobiz": true, "vibe": true}
	var mu sync.Mutex
	hits := map[string]int{}
	withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
		mu.Lock()
		hits[r.Host]++
		mu.Unlock()
		return http.StatusOK, `{"count":0,"results":[]}`
	})
	count := func(host string) int {
		mu.Lock()
		defer mu.Unlock()
		n := 0
		for h, c := range hits {
			if strings.HasPrefix(h, host) {
				n += c
			}
		}
		return n
	}
	for _, c := range []struct {
		name string
		ctx  context.Context
		want bool
	}{
		{"正在放的那首", context.Background(), true},
		{"手动搜索", withManualLyricSearch(context.Background()), true},
		{"待播队列的预解析", withBackgroundOutbound(withPlayerQueueTrack(context.Background())), true},
		{"补空扫描 / 全量扫库", withBackgroundOutbound(withOtherTrackRound(context.Background())), false},
		{"专辑预取 / 导入清单", withBackgroundOutbound(context.Background()), false},
	} {
		mu.Lock()
		hits = map[string]int{}
		mu.Unlock()
		resetMegalobizCacheForTest(t)
		ctx, round := withLyricSourceRound(c.ctx)
		fetchScoredLyricCandidatesStreaming(ctx, "Unknown Artist "+c.name, "Unknown Song "+c.name, "", 200, nil)
		if got := count("api.megalobiz.com") > 0; got != c.want {
			t.Errorf("%s: 问了 Megalobiz = %v,期望 %v", c.name, got, c.want)
		}
		if count("apis.naver.com") == 0 {
			t.Errorf("%s: 别的源照问", c.name)
		}
		if got := round.skippedSources(); len(got) != 0 {
			t.Errorf("%s: 批量轮次不问它是规矩、不是跳过,不记: %v", c.name, got)
		}
		if got := strings.Contains(strings.Join(round.enabledSources(), ","), "megalobiz"); got != c.want {
			t.Errorf("%s: 这一轮开着的源名单里有没有它 = %v,期望 %v", c.name, got, c.want)
		}
	}
}

// 补空扫描不因为只在播放那一侧问的源「新开」就重搜(扫描本来就不问它);播到时照常补问一次。
func TestMegalobizNewSourceFillOnlyOnPlayback(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	featuresRef().LyricsSources = map[string]bool{"vibe": true, "megalobiz": true}
	e := enrichEntry{LyricsSourcesEnabled: []string{"vibe"}, LyricsFillTS: time.Now().Add(-time.Hour).Unix(), TS: time.Now().Unix()}
	if !needsLyricsFirstFillFor(e, false) {
		t.Errorf("播到时 Megalobiz 算新开的源,补问一次")
	}
	if needsLyricsFirstFillFor(e, true) {
		t.Errorf("补空扫描不因 Megalobiz 重搜")
	}
	featuresRef().LyricsSources = map[string]bool{"vibe": true, "megalobiz": true, "genie": true}
	if !needsLyricsFirstFillFor(e, true) {
		t.Errorf("别的源新开时补空扫描照常补")
	}
}

// 批量入口都带 withBackgroundOutbound(lyricSourceAllowedForRound 认的就是它);待播队列那一处另带 withPlayerQueueTrack,
// 专辑预取、导入清单不带。
func TestMegalobizBulkEntryPointsMarkedBackground(t *testing.T) {
	for file, needle := range map[string]string{
		"lyricsfullscan.go":  "rescoreLyrics(withBackgroundOutbound(",
		"lyricsfillsweep.go": "retryLyricsUpgrade(withBackgroundOutbound(",
		"bgbackfill.go":      "withBackgroundOutbound(context.Background())",
		"prefetchimport.go":  "resolveEnrichAsync(withBackgroundOutbound(withLyricSearchTitle(",
		"albumprefetch.go":   "resolveEnrichAsync(withBackgroundOutbound(withLyricSearchTitle(",
		"songentityshare.go": "searchShareRound(withBackgroundOutbound(ctx)",
		"upcoming.go":        "resolveEnrichAsync(withBackgroundOutbound(withPlayerQueueTrack(",
	} {
		src, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		if !containsCode(string(src), needle) {
			t.Errorf("%s 里找不到 %q", file, needle)
		}
	}
}

// 写 LyricsSource 的函数都同时写 LyricsSourceURL:漏了的话换成别的源之后还留着上一份 Megalobiz 的歌词页,或者从别的条目
// 抄过来的 Megalobiz 歌词没有链接。
func TestLyricsSourceURLWrittenWithSource(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	assign := regexp.MustCompile(`^\s*([\w.]+(?:\s*,\s*[\w.]+)*)\s*=[^=]`)
	// 只读不写回的:songOwnLyricsEntry 给实体证据换出同步之前那份正文和来源,返回的副本不落盘。
	exempt := map[string]bool{"func songOwnLyricsEntry(": true}
	checked := 0
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		lines := strings.Split(string(raw), "\n")
		for i, l := range lines {
			m := assign.FindStringSubmatch(l)
			if m == nil {
				continue
			}
			target := false
			for _, part := range strings.Split(m[1], ",") {
				if strings.HasSuffix(strings.TrimSpace(part), ".LyricsSource") {
					target = true
				}
			}
			if !target {
				continue
			}
			checked++
			start := i
			for start > 0 && !strings.HasPrefix(lines[start], "func ") {
				start--
			}
			if exempt[lines[start][:strings.Index(lines[start], "(")+1]] {
				continue
			}
			end := i
			for end < len(lines)-1 && lines[end] != "}" {
				end++
			}
			if !strings.Contains(strings.Join(lines[start:end+1], "\n"), "LyricsSourceURL") {
				t.Errorf("%s:%d 写了 LyricsSource,同一个函数里没写 LyricsSourceURL", f, i+1)
			}
		}
	}
	if checked < 10 {
		t.Errorf("只认出 %d 处写 LyricsSource 的地方,扫描的写法跟不上了", checked)
	}
}

// 组装候选:页地址透传到结果的 SourceURL,不参与打分。
func TestRankLyricSourceResultsMegalobiz(t *testing.T) {
	var lrc strings.Builder
	for i := 0; i < 20; i++ {
		lrc.WriteString(formatLRCStamp((10+i*10)*1000) + "Line " + string(rune('A'+i)) + "\n")
	}
	raw := map[string]lyricSourceResult{"megalobiz": {source: "megalobiz", lyr: lrc.String(), srcDur: 220, matchTitle: "Song", matchArtist: "Artist",
		sourceURL: "https://megalobiz.com/lrc/1/song"}}
	var got *scoredLyricCandidateResult
	for _, c := range rankLyricSourceResults("Artist", "Song", "", 220, raw) {
		if c.Source == "megalobiz" {
			got = &c
		}
	}
	if got == nil || got.SourceURL != "https://megalobiz.com/lrc/1/song" || got.Score < 0 || got.HasWordTiming {
		t.Fatalf("megalobiz 候选: %+v", got)
	}
	raw["megalobiz"] = lyricSourceResult{source: "megalobiz", lyr: lrc.String(), srcDur: 220, matchTitle: "Song", matchArtist: "Artist"}
	for _, c := range rankLyricSourceResults("Artist", "Song", "", 220, raw) {
		if c.Source == "megalobiz" && c.Score != got.Score {
			t.Errorf("页地址不参与打分: %d vs %d", c.Score, got.Score)
		}
	}
}

// 采纳候选:带页地址的写进去;来源没变、没给页地址时留着原来的;换了来源清掉。
func TestSaveEditSourceURL(t *testing.T) {
	lrc := "[00:01.00]a\n[00:02.00]b\n[00:03.00]c\n"
	apply := func(req enrichEditRequest) string {
		e := enrichEntry{Lyrics: bt(lrc), LyricsSource: "megalobiz", LyricsSourceURL: "https://megalobiz.com/lrc/1/a"}
		req.Lyrics = lrc
		if err := applySaveEdit(&e, req); err != nil {
			t.Fatal(err)
		}
		return e.LyricsSourceURL
	}
	if got := apply(enrichEditRequest{Source: "megalobiz"}); got != "https://megalobiz.com/lrc/1/a" {
		t.Errorf("来源没变、没给页地址时留着原来的: %q", got)
	}
	if got := apply(enrichEditRequest{Source: "megalobiz", SourceURL: "https://megalobiz.com/lrc/2/b", FromManualPick: true}); got != "https://megalobiz.com/lrc/2/b" {
		t.Errorf("采纳另一份 Megalobiz 词时换成它的页地址: %q", got)
	}
	if got := apply(enrichEditRequest{Source: "lrclib", FromManualPick: true}); got != "" {
		t.Errorf("换了来源清掉: %q", got)
	}
}

// 第一份正文满是编辑器标记:跳过、取第二份。
func TestResolveMegalobizSkipsMarkupHeavySheet(t *testing.T) {
	resetMegalobizCacheForTest(t)
	withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/search"):
			return http.StatusOK, `{"results":[{"id":21,"title":"Song","artist":"Artist","duration":200},{"id":22,"title":"Song","artist":"Artist","duration":203}]}`
		case strings.HasSuffix(target, "/lrc/21"):
			return http.StatusOK, `{"url":"https://megalobiz.com/lrc/21/song","lines":[{"time_ms":1000,"text":"{00:01.00,A]a"},{"time_ms":2000,"text":"{00:02.00,A]b"},{"time_ms":3000,"text":"{00:03.00,E]c"}]}`
		case strings.HasSuffix(target, "/lrc/22"):
			return http.StatusOK, `{"url":"https://megalobiz.com/lrc/22/song","lines":[{"time_ms":1000,"text":"a"},{"time_ms":2000,"text":"b"},{"time_ms":3000,"text":"c"}]}`
		}
		return http.StatusNotFound, ""
	})
	if r := resolveMegalobizLyric(qqRoundCtx(), "Artist", "Song", "", 200); r.url != "https://megalobiz.com/lrc/22/song" {
		t.Errorf("应跳过带标记的第一份: %+v", r)
	}
}
