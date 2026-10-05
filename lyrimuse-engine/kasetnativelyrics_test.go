package main

import (
	"context"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
)

func TestKasetLyricsWorthRecheck(t *testing.T) {
	base := enrichEntry{Lyrics: "[00:01.00]hi", LyricsSource: "migu"}
	with := func(f func(e *enrichEntry)) enrichEntry { e := base; f(&e); return e }
	mv := func(e *enrichEntry) { e.YouTubeMusicMV = true }
	cases := []struct {
		name                   string
		e                      enrichEntry
		bundle, video, target  string
		pinned, auto, nativeOn bool
		want                   bool
	}{
		{"没按 videoId 问过自家源", base, kasetBundleID, "Song0000001", "Song0000001", false, true, true, true},
		{"重试次数用完也给这一次", with(func(e *enrichEntry) { e.LyricsRetryCount = lyricsRetryMaxAttempts }),
			kasetBundleID, "Song0000001", "Song0000001", false, true, true, true},
		{"已经按这个 videoId 问过", with(func(e *enrichEntry) { e.LyricsNativeVideoID = "Song0000001" }),
			kasetBundleID, "Song0000001", "Song0000001", false, true, true, false},
		{"MV 配上了音轨版本", with(mv), kasetBundleID, "Mv000000001", "Audio000001", false, true, true, true},
		{"MV 问过的是 MV 自己,配上音轨版本之后再来",
			with(func(e *enrichEntry) { mv(e); e.LyricsNativeVideoID = "Mv000000001" }),
			kasetBundleID, "Mv000000001", "Audio000001", false, true, true, true},
		{"MV 还没配上音轨版本先不来", with(mv), kasetBundleID, "Mv000000001", "Mv000000001", false, true, true, false},
		{"词已经是自家源的", with(func(e *enrichEntry) { e.LyricsSource = "lyricfind" }),
			kasetBundleID, "Song0000001", "Song0000001", false, true, true, false},
		{"不是 Kaset 放的", base, "com.apple.Music", "Song0000001", "Song0000001", false, true, true, false},
		{"没有 videoId", base, kasetBundleID, "", "", false, true, true, false},
		{"没词交给补空那条", with(func(e *enrichEntry) { e.Lyrics = "" }),
			kasetBundleID, "Song0000001", "Song0000001", false, true, true, false},
		{"手改过", with(func(e *enrichEntry) { e.ManualLyrics = true }),
			kasetBundleID, "Song0000001", "Song0000001", false, true, true, false},
		{"校准过", base, kasetBundleID, "Song0000001", "Song0000001", true, true, true, false},
		{"关了自动升级", base, kasetBundleID, "Song0000001", "Song0000001", false, false, true, false},
		{"lyricfind 关着", base, kasetBundleID, "Song0000001", "Song0000001", false, true, false, false},
	}
	for _, c := range cases {
		if got := kasetLyricsWorthRecheck(c.e, c.bundle, c.video, c.target, c.pinned, c.auto, c.nativeOn); got != c.want {
			t.Errorf("%s: got %v want %v", c.name, got, c.want)
		}
	}
}

// 同一个条目这次进程里只为自家源重搜一次:那一轮没记下 LyricsNativeVideoID 时,下一拍不再来。
func TestKasetLyricsRecheckOnce(t *testing.T) {
	saved := kasetLyricsRechecked
	kasetLyricsRechecked = map[string]bool{}
	t.Cleanup(func() { kasetLyricsRechecked = saved })
	if !kasetLyricsRecheckOnce("a") || kasetLyricsRecheckOnce("a") {
		t.Error("第一次放行,第二次不放")
	}
	if !kasetLyricsRecheckOnce("b") {
		t.Error("别的条目照常放行")
	}
}

// 记下的是按哪个 videoId 问了自家源:MV 记配对的音轨版本,没配的记它自己;ctx 上没有 videoId、lyricfind 关着、
// 这一轮跳过了它、或既没连上它也没拿到它的候选都记空。
func TestKasetNativeLyricsVideoID(t *testing.T) {
	withKasetAudioVideoIDs(t)
	noteKasetAudioVideoIDs(map[string]string{"Mv000000001": "Audio000001"})
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	featuresRef().LyricsSources = map[string]bool{"lyricfind": true}
	_, round := withLyricSourceRound(context.Background())
	round.markReached("lyricfind")
	_, unreached := withLyricSourceRound(context.Background())
	unreached.markReached("qq")
	_, skipped := withLyricSourceRound(context.Background())
	skipped.markReached("lyricfind")
	skipped.markSkipped("lyricfind")
	mv := withYouTubeMusicVideoID(context.Background(), "Mv000000001")
	song := withYouTubeMusicVideoID(context.Background(), "Song0000001")
	if got := kasetNativeLyricsVideoID(mv, round, nil); got != "Audio000001" {
		t.Errorf("MV 记配对的音轨版本: %q", got)
	}
	if got := kasetNativeLyricsVideoID(song, round, nil); got != "Song0000001" {
		t.Errorf("没配的记它自己: %q", got)
	}
	if got := kasetNativeLyricsVideoID(context.Background(), round, nil); got != "" {
		t.Errorf("没有 videoId 就没问自家源: %q", got)
	}
	if got := kasetNativeLyricsVideoID(song, unreached, nil); got != "" {
		t.Errorf("这一轮没连上自家源: %q", got)
	}
	cached := []scoredLyricCandidateResult{{Source: "qq"}, {Source: "lyricfind", Score: -1}}
	if got := kasetNativeLyricsVideoID(song, unreached, cached); got != "Song0000001" {
		t.Errorf("没发请求、但给出了候选(读的进程内缓存),也算问成了: %q", got)
	}
	if got := kasetNativeLyricsVideoID(song, skipped, cached); got != "" {
		t.Errorf("这一轮跳过了自家源: %q", got)
	}
	featuresRef().LyricsSources = map[string]bool{"musixmatch": true}
	if got := kasetNativeLyricsVideoID(song, round, cached); got != "" {
		t.Errorf("lyricfind 关着: %q", got)
	}
}

// 升级重试 / 重打分按条目存的 YouTube Music 歌曲页问自家源,把按哪个 videoId 问的记下(MV 记配对的音轨版本);
// 同一进程里再评估一次,那一版的词读缓存、不发请求,照样记着。
func TestLyricsEvaluationRecordsNativeVideoID(t *testing.T) {
	// 假 musixmatch 照真实应答那样记一笔连上了:不然只读缓存的那一轮一个源都没连上、整轮不记账,测不出标记被冲掉。
	setupRescoreTest(t, []string{"musixmatch", "lyricfind"}, func(ctx context.Context) {
		lyricSourceRoundFrom(ctx).markReached("musixmatch")
	})
	resetYtmusicRegionState(t)
	withKasetAudioVideoIDs(t)
	noteKasetAudioVideoIDs(map[string]string{"Mv000000001": "Audio000001"})
	const artist = rescoreTestArtist
	hl := ytmusicSearchHL(artist, "", "")
	forgetYtmusicCache(t, ytmusicVideoCacheKey(hl, "Audio000001"), ytmusicVideoCacheKey(hl, "Song0000001"))
	// 自家源按 videoId 答出这一版(登记的歌名、歌手、时长跟这首对得上)和 LyricFind 的逐行词:两个源都答上,不进补查轮。
	// MV 自己那一页照实答成 MV:答不上的话第二轮会换主机重问,404 也算连上了自家源,测不出第二轮读的是缓存。
	titles := map[string]string{"Mv000000001": "Mv Song", "Audio000001": "Mv Song", "Song0000001": "Rescored Song"}
	reqs := withYtmusicFake(t, func(w http.ResponseWriter, req ytmusicFakeReq) {
		id, _ := req.body["videoId"].(string)
		switch {
		case req.target == ytmNextURL && titles[id] != "":
			credit := strings.NewReplacer("Levitating", titles[id], "Dua Lipa", artist, "3:23", "3:00")
			kind := ytmusicVideoTypeATV
			if id == "Mv000000001" {
				kind = ytmusicVideoTypeOMV
			}
			_, _ = io.WriteString(w, credit.Replace(ytmFakeVideoNext(id, kind)))
		case req.target == ytmBrowseURL && req.clientName == ytmusicMobileClientName:
			_, _ = io.WriteString(w, ytmFakeTimed("Source: LyricFind"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	mvKey, songKey := enrichKey(artist, "Mv Song", ""), enrichKey(artist, "Rescored Song", "")
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{
		mvKey: {YouTubeMusicURL: "https://music.youtube.com/watch?v=Mv000000001", YouTubeMusicMV: true},
		songKey: {Lyrics: "[00:05.00]Old line one\n[00:15.00]Old line two", LyricsSource: "musixmatch",
			LyricsScoringVersion: lyricsScoringVersion - 1, YouTubeMusicURL: "https://music.youtube.com/watch?v=Song0000001"},
	}
	enrichMu.Unlock()
	retryLyricsUpgrade(context.Background(), mvKey, artist, "Mv Song", "", 180, true)
	// 第二轮别的源照常联网应答(清掉 musixmatch 的进程内缓存,假 musixmatch 再答一次),自家源那一版读缓存。
	resetMusixmatchCacheForTest(t)
	retryLyricsUpgrade(context.Background(), mvKey, artist, "Mv Song", "", 180, false)
	rescoreLyrics(context.Background(), songKey, artist, "Rescored Song", "", 180)

	enrichMu.Lock()
	mv, song := enrichCache[mvKey], enrichCache[songKey]
	enrichMu.Unlock()
	if mv.LyricsNativeVideoID != "Audio000001" {
		t.Errorf("MV 按配对的音轨版本问自家源,要记下它: %q", mv.LyricsNativeVideoID)
	}
	if song.LyricsNativeVideoID != "Song0000001" {
		t.Errorf("重打分同样记下: %q", song.LyricsNativeVideoID)
	}
	audioNext := 0
	for _, r := range reqs() {
		if r.target == ytmSearchURL {
			t.Errorf("有 videoId 就按它问,不按名字搜: %+v", r)
		}
		if r.target == ytmNextURL && r.body["videoId"] == "Audio000001" {
			audioNext++
		}
	}
	if audioNext != 1 {
		t.Errorf("第二次评估该读缓存,next 只问一次: %d", audioNext)
	}
}

// 按 videoId 问过自家源之后,它落选不再触发「同源落选」的连着重搜(同 KKBOX,见 needsLyricsRetry 里 nativeMissedOut 的注释)。
func TestKasetNativeMissNotRetriedAfterVideoIDCheck(t *testing.T) {
	saved := nativeLyricSources
	t.Cleanup(func() { nativeLyricSources = saved })
	setNativeLyricSourcesForPlayer(kasetBundleID)
	e := enrichEntry{Lyrics: "[00:01.00]x", LyricsYRC: "yrc", LyricsSource: "qq", LyricsSourcesSeen: []string{"qq", "lyricfind"}}
	if !needsLyricsRetry(e, false, false, true) {
		t.Error("还没按 videoId 问过自家源:照旧重来一次")
	}
	e.LyricsNativeVideoID = "Song0000001"
	if needsLyricsRetry(e, false, false, true) {
		t.Error("按 videoId 问过、带着同源加权输给逐字的 QQ:不该连着重搜")
	}
}

func TestAdoptBackfilledLyricsKeepsNativeVideoID(t *testing.T) {
	var e enrichEntry
	fresh := enrichEntry{Lyrics: "[00:01.00]hi", LyricsSource: "qq", LyricsNativeVideoID: "Song0000001"}
	if !adoptBackfilledLyrics(&e, fresh) || e.LyricsNativeVideoID != "Song0000001" {
		t.Errorf("收下的词是按哪个 videoId 问过自家源的要一起收: %q", e.LyricsNativeVideoID)
	}
}

// 接线:轮询路径给 Kaset 放的这首按配对的音轨版本判要不要重搜;首次解析先出的那份记下,最终那份跟升级重试、重打分
// 一共三处记下。
func TestKasetNativeLyricsRecheckWiring(t *testing.T) {
	src, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	for _, want := range []string{
		"bundleID: bundleID, kasetVideoID: kasetVideoID,",
		"p.LyricsNativeVideoID = kasetNativeLyricsVideoID(ctx, round, scored)",
	} {
		if !strings.Contains(s, want) {
			t.Errorf("enrich.go 里要有: %s", want)
		}
	}
	recheck, err := os.ReadFile("lyricsrecheck.go")
	if err != nil {
		t.Fatal(err)
	}
	if want := "kasetLyricsWorthRecheck(e, s.bundleID, s.kasetVideoID, kasetAudioVideoIDFor(s.kasetVideoID), s.pinned, auto,"; !strings.Contains(string(recheck), want) {
		t.Errorf("lyricsrecheck.go 里要有: %s", want)
	}
	if n := strings.Count(s, "e.LyricsNativeVideoID = kasetNativeLyricsVideoID(ctx, round, scored)"); n != 3 {
		t.Errorf("首次解析最终那份、升级重试、重打分三处都要记,现在 %d 处", n)
	}
}
