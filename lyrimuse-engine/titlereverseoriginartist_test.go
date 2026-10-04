package main

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"
)

// Deezer 的 GraphQL 搜索带上 isrc:挑中那条的 ISRC 进结果,排序时进候选。
func TestDeezerCarriesISRC(t *testing.T) {
	withDeezerFake(t, func(c dzCall) (int, string) {
		switch c.op {
		case "SearchTracks":
			if !strings.Contains(deezerSearchQuery, "\n            isrc\n") {
				t.Error("搜索请求要带 isrc 字段")
			}
			var root map[string]any
			_ = json.Unmarshal([]byte(dzSearchResponse(dzHit{"2", "Hello", "Adele", "25", 295, true})), &root)
			edges := root["data"].(map[string]any)["search"].(map[string]any)["results"].(map[string]any)["tracks"].(map[string]any)["edges"].([]any)
			edges[0].(map[string]any)["node"].(map[string]any)["isrc"] = "GBBKS1500214"
			b, _ := json.Marshal(root)
			return http.StatusOK, string(b)
		case "SynchronizedTrackLyrics":
			return http.StatusOK, dzLyricsResponse(dzSixLines...)
		}
		return 0, ""
	})
	r := resolveDeezerLyric(context.Background(), "Adele", "Hello", "25", 295, "")
	if r.lyrics == "" || r.isrc != "GBBKS1500214" {
		t.Fatalf("结果该带上 ISRC: lyrics=%v isrc=%q", r.lyrics != "", r.isrc)
	}
	raw := map[string]lyricSourceResult{"deezer": {source: "deezer", lyr: dzSongwriterLRC(dzSixLines...), isrc: "GBBKS1500214"}}
	if scored := rankLyricSourceResults("Adele", "Hello", "", 60, raw); len(scored) == 0 || scored[0].ISRC != "GBBKS1500214" {
		t.Fatalf("候选该带上 ISRC: %+v", scored)
	}
}

// 走完整的收集通道:deezer 候选带着 ISRC。
func TestFetchCarriesDeezerISRC(t *testing.T) {
	withDeezerFake(t, func(c dzCall) (int, string) {
		switch c.op {
		case "SearchTracks":
			var root map[string]any
			_ = json.Unmarshal([]byte(dzSearchResponse(dzHit{"2", "Hello", "Adele", "25", 295, true})), &root)
			edges := root["data"].(map[string]any)["search"].(map[string]any)["results"].(map[string]any)["tracks"].(map[string]any)["edges"].([]any)
			edges[0].(map[string]any)["node"].(map[string]any)["isrc"] = "GBBKS1500214"
			b, _ := json.Marshal(root)
			return http.StatusOK, string(b)
		case "SynchronizedTrackLyrics":
			return http.StatusOK, dzLyricsResponse(dzSixLines...)
		}
		return 0, ""
	})
	setFeatureForTest(t, func(f *featureFlags) { f.LyricsSources = map[string]bool{"deezer": true} })
	_, scored := fetchScoredLyricCandidatesStreaming(qqRoundCtx(), "Adele", "Hello", "25", 295, nil)
	for _, r := range scored {
		if r.Source == "deezer" {
			if r.ISRC != "GBBKS1500214" {
				t.Fatalf("deezer 候选的 ISRC = %q", r.ISRC)
			}
			return
		}
	}
	t.Fatalf("没有 deezer 候选: %+v", scored)
}

// 录音的 ISRC:Apple Music 的优先;Apple Music 没给出可用候选时用已被认可、时长对得上的 Deezer 候选报的。
func TestTrustedRecordingISRCFallsBackToDeezer(t *testing.T) {
	dz := scoredLyricCandidateResult{Source: "deezer", Score: 700, ISRC: "D1", SourceReportedDurationSecs: 324}
	am := scoredLyricCandidateResult{Source: "applemusic", Score: 900, ISRC: "A1", SourceReportedDurationSecs: 324}
	rejected := dz
	rejected.Score = -1
	far := dz
	far.SourceReportedDurationSecs = 500
	for _, c := range []struct {
		name    string
		results []scoredLyricCandidateResult
		want    string
	}{
		{"只有 Deezer", []scoredLyricCandidateResult{dz}, "D1"},
		{"Apple 优先", []scoredLyricCandidateResult{dz, am}, "A1"},
		{"Deezer 被判掉", []scoredLyricCandidateResult{rejected}, ""},
		{"Deezer 时长对不上", []scoredLyricCandidateResult{far}, ""},
	} {
		if got := trustedRecordingISRC("Official胡子男dism", "115 Million Kilometer Film", "Escaparade", 324.7, c.results); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

// 标题反查拿原产地曲名用本地署名问完,原产地商店那边的署名跟本地写法不同时,还缺着的源再拿原产地署名问一轮;
// 曲名不是这条录音的原名、或署名归一相同时不问。
func TestTitleReverseOriginArtistRound(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	featuresRef().LyricsSources = map[string]bool{"musixmatch": true, "lrclib": true}
	resetMusixmatchCacheForTest(t)
	var mu sync.Mutex
	var mxArtists []string
	musixmatchResolve = func(_ context.Context, artist, title string, _ float64, _, _ string) musixmatchResult {
		mu.Lock()
		mxArtists = append(mxArtists, artist+"/"+title)
		mu.Unlock()
		return musixmatchResult{}
	}
	withTestDevToken(t)
	resetOriginTitleState(t)
	resetSourceCachesForTest(t)
	var catalogReqs, lrclibGets []string
	catalog := isrcCatalogHandler(map[string][]applemusicSong{
		"jp|JPC841800601": {isrcSong("115万キロのフィルム", "Official髭男dism", 324000)},
		"jp|JPC841800602": {isrcSong("115万キロのフィルム", "Official胡子男dism", 324000)},
	}, &mu, &catalogReqs)
	withAMLLFake(t, func(w http.ResponseWriter, r *http.Request, target string) {
		if catalog(w, r, target) {
			return
		}
		q := r.URL.Query()
		switch target {
		case "https://lrclib.net/api/get":
			mu.Lock()
			lrclibGets = append(lrclibGets, q.Get("artist_name")+"/"+q.Get("track_name"))
			mu.Unlock()
			if q.Get("track_name") == "115万キロのフィルム" && q.Get("artist_name") == "Official髭男dism" {
				b, _ := json.Marshal(lrclibSearchItem{TrackName: "115万キロのフィルム", ArtistName: "Official髭男dism", AlbumName: "Escaparade", Duration: 324, SyncedLyrics: originJapaneseLRC})
				_, _ = w.Write(b)
				return
			}
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"code":404}`))
		case "https://lrclib.net/api/search":
			_, _ = w.Write([]byte("[]"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	useUnthrottledGuard(t)
	base := func(isrc string) []scoredLyricCandidateResult {
		return []scoredLyricCandidateResult{{Source: "deezer", Score: 699, Lyrics: originJapaneseLRC, Title: "115 million kilometer film", SourceReportedDurationSecs: 324, ISRC: isrc}}
	}
	samples := []string{originJapaneseLRC}
	_, got := titleReverseOriginArtistRound(qqRoundCtx(), "Official胡子男dism", "115 Million Kilometer Film", "Escaparade", 324.7, samples,
		"115万キロのフィルム", neteaseInfo{}, base("JPC841800601"), nil)
	var lr *scoredLyricCandidateResult
	for i := range got {
		if got[i].Source == "lrclib" {
			lr = &got[i]
		}
	}
	if lr == nil || lr.Score < 0 || lr.RetryMethod != lyricQueryReasonTitleStorefront || lr.RetriedTitle != "115万キロのフィルム" {
		t.Fatalf("lrclib 该拿原产地署名补上一条带改写记号的候选: %+v", got)
	}
	mu.Lock()
	gets, mx := append([]string(nil), lrclibGets...), append([]string(nil), mxArtists...)
	mu.Unlock()
	for _, g := range append(gets, mx...) {
		if g != "Official髭男dism/115万キロのフィルム" {
			t.Errorf("这一轮只拿原产地署名 + 原产地曲名问(本地署名那一遍反查已经问过): %q", g)
		}
	}

	n := len(gets)
	if _, again := titleReverseOriginArtistRound(qqRoundCtx(), "Official胡子男dism", "115 Million Kilometer Film", "Escaparade", 324.7, samples,
		"某个别的曲名", neteaseInfo{}, base("JPC841800601"), nil); len(again) != 1 {
		t.Errorf("反查用的曲名不是这条录音的原名时不问: %+v", again)
	}
	if _, same := titleReverseOriginArtistRound(qqRoundCtx(), "Official胡子男dism", "115 Million Kilometer Film", "Escaparade", 324.7, samples,
		"115万キロのフィルム", neteaseInfo{}, base("JPC841800602"), nil); len(same) != 1 {
		t.Errorf("原产地署名跟本地归一相同时不问: %+v", same)
	}
	mu.Lock()
	extra := len(lrclibGets) - n
	mu.Unlock()
	if extra != 0 {
		t.Errorf("两种不问的情形不该发请求,多了 %d 次", extra)
	}

	full := append(base("JPC841800603"),
		scoredLyricCandidateResult{Source: "musixmatch", Score: 800, Lyrics: originJapaneseLRC},
		scoredLyricCandidateResult{Source: "lrclib", Score: 800, Lyrics: originJapaneseLRC})
	if _, kept := titleReverseOriginArtistRound(qqRoundCtx(), "Official胡子男dism", "115 Million Kilometer Film", "Escaparade", 324.7, samples,
		"115万キロのフィルム", neteaseInfo{}, full, nil); len(kept) != len(full) {
		t.Errorf("没有缺着的源时原样返回: %+v", kept)
	}
	mu.Lock()
	for _, k := range catalogReqs {
		if k == "jp|JPC841800603" {
			t.Errorf("没有缺着的源时不该查曲库: %v", catalogReqs)
		}
	}
	mu.Unlock()
}

// 接线:标题反查走原产地曲名那条路之后补原产地署名那一轮。
func TestTitleReverseOriginArtistRoundIsWired(t *testing.T) {
	b, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "\t\t\tif retryMethod == lyricQueryReasonTitleStorefront {\n") ||
		!strings.Contains(string(b), "ne, results = titleReverseOriginArtistRound(ctx, artist, title, album, durationSecs, samples, correctedTitle, ne, results, onUpdate)\n") {
		t.Error("enrich.go 的标题反查块缺补原产地署名那一轮")
	}
}
