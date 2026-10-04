package main

import (
	"context"
	"net/http"
	"testing"
	"time"
)

// 照真实 next 应答的形状造(只留用得到的那几层):英文界面下署名是原名,第一段之后是播放量这类统计。
const ytmCreditNext = `{"contents":{"singleColumnMusicWatchNextResultsRenderer":{"tabbedRenderer":{"watchNextTabbedResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"musicQueueRenderer":{"content":{"playlistPanelRenderer":{"contents":[` +
	`{"playlistPanelVideoRenderer":{"videoId":"Qt2mbGP6vFI","title":{"runs":[{"text":"Another Day In Paradise (Live)"}]},"lengthText":{"runs":[{"text":"5:42"}]},` +
	`"navigationEndpoint":{"watchEndpoint":{"videoId":"Qt2mbGP6vFI","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_OMV"}}}},` +
	`"longBylineText":{"runs":[{"text":"Phil Collins","navigationEndpoint":{"browseEndpoint":{"browseId":"UC1"}}},{"text":" • "},{"text":"716M views"},{"text":" • "},{"text":"3.5M likes"}]}}},` +
	`{"playlistPanelVideoRenderer":{"videoId":"qeMFqkcPYcg","title":{"runs":[{"text":"Sweet Dreams (Are Made Of This)"}]},` +
	`"longBylineText":{"runs":[{"text":"Eurythmics","navigationEndpoint":{}},{"text":", "},{"text":"Annie Lennox","navigationEndpoint":{}},{"text":" & "},{"text":"Dave Stewart","navigationEndpoint":{}},{"text":" • "},{"text":"Sweet Dreams"}]}}},` +
	`{"playlistPanelVideoRenderer":{"videoId":"ot0WzesOp6I","title":{"runs":[{"text":"Break"}]},"lengthText":{"runs":[{"text":"3:16"}]},` +
	`"navigationEndpoint":{"watchEndpoint":{"videoId":"ot0WzesOp6I","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_ATV"}}}},` +
	`"longBylineText":{"runs":[{"text":"Jhené Aiko","navigationEndpoint":{"browseEndpoint":{"browseId":"UCZONOh3FvcD","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ARTIST"}}}}},` +
	`{"text":" • "},{"text":"Westside Whimsy","navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_OUh6Wf","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}}}},{"text":" • "},{"text":"2026"}]}}}` +
	`]}}}}}}]}}}}}`

func withYTMusicCredits(t *testing.T, entries map[string]ytmusicCredit) {
	t.Helper()
	ytmusicCreditMu.Lock()
	saved, savedPending, savedFailed := ytmusicCreditCache, ytmusicCreditPending, ytmusicCreditFailedAt
	ytmusicCreditCache, ytmusicCreditPending, ytmusicCreditFailedAt = map[string]ytmusicCredit{}, map[string]bool{}, map[string]time.Time{}
	for k, v := range entries {
		ytmusicCreditCache[k] = v
	}
	ytmusicCreditMu.Unlock()
	t.Cleanup(func() {
		ytmusicCreditMu.Lock()
		ytmusicCreditCache, ytmusicCreditPending, ytmusicCreditFailedAt = saved, savedPending, savedFailed
		ytmusicCreditMu.Unlock()
	})
}

func TestYTMusicCreditFromNext(t *testing.T) {
	if c := ytmusicCreditFromNext([]byte(ytmCreditNext), "Qt2mbGP6vFI"); c.artist != "Phil Collins" || c.title != "Another Day In Paradise (Live)" {
		t.Errorf("署名取第一段、歌名原样: %+v", c)
	}
	if c := ytmusicCreditFromNext([]byte(ytmCreditNext), "qeMFqkcPYcg"); c.artist != "Eurythmics, Annie Lennox & Dave Stewart" {
		t.Errorf("多位歌手连同连接词原样拼: %+v", c)
	}
	if c := ytmusicCreditFromNext([]byte(ytmCreditNext), "ot0WzesOp6I"); c.album != "Westside Whimsy" || c.artist != "Jhené Aiko" ||
		c.videoType != "MUSIC_VIDEO_TYPE_ATV" || c.durationSecs != 196 {
		t.Errorf("音轨版本的署名行里链到专辑页的那一段是专辑,另带类型与时长: %+v", c)
	}
	if c := ytmusicCreditFromNext([]byte(ytmCreditNext), "Qt2mbGP6vFI"); c.videoType != ytmusicVideoTypeOMV || c.durationSecs != 342 {
		t.Errorf("官方 MV 的类型与时长: %+v", c)
	}
	for _, id := range []string{"Qt2mbGP6vFI", "qeMFqkcPYcg"} {
		if c := ytmusicCreditFromNext([]byte(ytmCreditNext), id); c.album != "" {
			t.Errorf("%s: 没链到专辑页的那几段(播放量、没有页面类型)不当专辑: %+v", id, c)
		}
	}
	if c := ytmusicCreditFromNext([]byte(ytmCreditNext), "AAAAAAAAAAA"); c != (ytmusicCredit{}) {
		t.Errorf("应答里没有这一首就是空: %+v", c)
	}
	if c := ytmusicCreditFromNext([]byte("not json"), "Qt2mbGP6vFI"); c != (ytmusicCredit{}) {
		t.Errorf("解析不出就是空: %+v", c)
	}
}

func TestYTMusicEnglishCreditAsksOnceInEnglish(t *testing.T) {
	withYTMusicCredits(t, nil)
	reqs := withYtmusicFake(t, func(w http.ResponseWriter, req ytmusicFakeReq) {
		if req.target == ytmNextURL {
			_, _ = w.Write([]byte(ytmCreditNext))
			return
		}
		w.WriteHeader(http.StatusNotFound)
	})
	for i := 0; i < 2; i++ {
		if c := ytmusicEnglishCredit(context.Background(), "Qt2mbGP6vFI"); c.artist != "Phil Collins" {
			t.Fatalf("第 %d 次应拿到原名: %+v", i+1, c)
		}
	}
	got := reqs()
	if len(got) != 1 {
		t.Fatalf("同一个 videoId 只问一次,实际 %d 次", len(got))
	}
	client, _ := got[0].body["context"].(map[string]any)["client"].(map[string]any)
	if client["hl"] != "en" || got[0].body["videoId"] != "Qt2mbGP6vFI" {
		t.Errorf("要按英文界面问这一首: %+v", got[0].body)
	}
	if c := ytmusicEnglishCredit(context.Background(), "bad id"); c != (ytmusicCredit{}) || len(reqs()) != 1 {
		t.Error("不是 videoId 的形状不问")
	}
}

func TestRetryArtistIdentitiesUsesYouTubeMusicCredit(t *testing.T) {
	withEnrichCache(t, nil)
	withYTMusicCredits(t, map[string]ytmusicCredit{ytmusicCreditKey("en", "Qt2mbGP6vFI"): {artist: "Phil Collins", title: "Another Day In Paradise (Live)"}})
	withCachedAliases(t, map[string]string{"菲尔·科林斯": "", "Phil Collins": ""})
	withCachedMBAliases(t, map[string][]string{"菲尔·科林斯": nil, "Phil Collins": nil})
	withCachedQQArtistNames(t, map[string]string{"菲尔·科林斯": "", "Phil Collins": ""})
	ctx := withYouTubeMusicVideoID(context.Background(), "Qt2mbGP6vFI")
	if got := retryArtistIdentities(ctx, "菲尔·科林斯"); len(got) != 1 || got[0] != "Phil Collins" {
		t.Fatalf("本地化署名应拿 YouTube Music 登记的原名重搜, got %v", got)
	}
	if got := retryArtistIdentities(context.Background(), "菲尔·科林斯"); len(got) != 0 {
		t.Errorf("没有 videoId 时不问, got %v", got)
	}
	withYTMusicCredits(t, map[string]ytmusicCredit{ytmusicCreditKey("en", "Qt2mbGP6vFI"): {artist: "Someone Else"}})
	if got := retryArtistIdentities(ctx, "Phil Collins"); len(got) != 0 {
		t.Errorf("署名本来就是拉丁字母的不问, got %v", got)
	}
}
