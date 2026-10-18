package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func storefrontTrackList(secs ...float64) []itunesResult {
	out := make([]itunesResult, len(secs))
	for i, s := range secs {
		out[i] = itunesResult{TrackTimeMillis: s * 1000}
	}
	return out
}

// 本地同一张专辑的歌大多在店面这张专辑里找不到相近时长的曲目才算对不上;按两边较少的那一边数,本地少于 3 首不判。
func TestAppleStorefrontAlbumMismatch(t *testing.T) {
	local := []float64{194, 240.5, 143, 178.9, 243.9, 249, 255, 256, 214, 214.5}
	for _, c := range []struct {
		name   string
		local  []float64
		tracks []itunesResult
		want   bool
	}{
		{"别人的同名专辑", local, storefrontTrackList(251, 253, 301, 330, 280, 196, 365, 412, 268), true},
		{"同一张专辑换了曲名", local, storefrontTrackList(194.2, 240, 143.5, 179, 244, 249.3, 255.4, 256.2, 214, 214.7), false},
		{"店面是标准版、本地多了几首", local, storefrontTrackList(194, 143, 178.9), false},
		{"店面是加长版", local[:3], storefrontTrackList(194, 240.5, 143, 300, 310, 320, 330), false},
		{"本地只有两首", local[:2], storefrontTrackList(400, 500), false},
		{"刚好一半对得上", local[:4], storefrontTrackList(194, 240.5, 600, 700), false},
		{"不到一半", local[:5], storefrontTrackList(194, 143, 600, 700, 800), true},
	} {
		if got := appleStorefrontAlbumMismatch(c.local, c.tracks); got != c.want {
			t.Errorf("%s: %v,期望 %v", c.name, got, c.want)
		}
	}
}

func TestAppleStorefrontPickContradiction(t *testing.T) {
	sameAlbum := storefrontTrackList(208, 295, 212)
	for _, c := range []struct {
		name         string
		title, album string
		hit          itunesResult
		tracks       []itunesResult
		local        []float64
		want         string
	}{
		{"专辑对不上", "一场误会", "My Love", itunesResult{TrackName: "My Love", CollectionName: "My Love"}, storefrontTrackList(204, 190, 250, 300), []float64{202, 231, 236, 270}, "album"},
		{"同一张专辑换了写法", "一坪半", "What a Folk", itunesResult{TrackName: "4.95m² Dream", CollectionName: "What a Folk (Spring Groove Edition)"}, sameAlbum, []float64{208, 207, 295}, ""},
		{"本地是现场版、店面是录音室版", "叮叮车 (Live)", "Filicious Fiona In Concert 2012", itunesResult{TrackName: "9:55 PM (feat. Chapman To)", CollectionName: "Filicious - EP"}, storefrontTrackList(189), nil, "version"},
		{"本地没写版本、店面是现场版:不判", "13", "十指紧扣", itunesResult{TrackName: "十指緊扣 (903狂熱份子音樂會現場版)", CollectionName: "十指緊扣"}, storefrontTrackList(255), nil, ""},
		{"两边都是现场版", "Hero (Live)", "Jay Chou The Invincible Concert Tour", itunesResult{TrackName: "英雄 (Live)", CollectionName: "周杰倫 嘉年華 世界巡迴演唱會"}, storefrontTrackList(300), nil, ""},
		{"本地同专辑的歌太少:不判专辑", "唯一", "T.I.M.E.", itunesResult{TrackName: "Only One", CollectionName: "T.I.M.E. - EP"}, storefrontTrackList(253, 400), []float64{253}, ""},
	} {
		if got := appleStorefrontPickContradiction(c.title, c.album, c.hit, c.tracks, c.local); got != c.want {
			t.Errorf("%s: %q,期望 %q", c.name, got, c.want)
		}
	}
}

// 别的商店按本地歌名找到的那首时长不同、那张专辑里另有一首跟按时长挑的一样长:挑中的是那一首。时长一样的(另一个版本的同一首)不算。
func TestAppleStorefrontPickShadowed(t *testing.T) {
	tw := []itunesResult{{TrackName: "一坪半", TrackTimeMillis: 208000}, {TrackName: "一定要相信自己", TrackTimeMillis: 212000}, {TrackName: "今天睡在這裡", TrackTimeMillis: 295000}}
	us := storefrontHit{country: "US", hit: itunesResult{TrackName: "4.95m² Dream", TrackTimeMillis: 208000}, cross: true, titleOK: true}
	exact := func(i int) storefrontHit { return storefrontHit{country: "TW", hit: tw[i], tracks: tw} }
	if !appleStorefrontPickShadowed("一定要相信自己", us, []storefrontHit{us, exact(1)}) {
		t.Error("《一定要相信自己》在台区是 212 秒,美区 208 秒那首是《一坪半》,该挡")
	}
	if appleStorefrontPickShadowed("一坪半", us, []storefrontHit{us, exact(0)}) {
		t.Error("《一坪半》在台区也是 208 秒,美区那首就是它,不该挡")
	}
	if appleStorefrontPickShadowed("一定要相信自己", us, []storefrontHit{us}) {
		t.Error("没有别的商店按名字找到时不该挡")
	}
	twin := []itunesResult{{TrackName: "一坪半", TrackTimeMillis: 208000}, {TrackName: "另一首", TrackTimeMillis: 208300}}
	if appleStorefrontPickShadowed("一坪半", us, []storefrontHit{us, {country: "TW", hit: twin[0], tracks: twin}}) {
		t.Error("按名字找到的那首跟挑中的一样长,同专辑另一首碰巧也一样长时不该挡")
	}
	lone := []itunesResult{{TrackName: "一定要相信自己", TrackTimeMillis: 212000}}
	if appleStorefrontPickShadowed("一定要相信自己", us, []storefrontHit{us, {country: "TW", hit: lone[0], tracks: lone}}) {
		t.Error("那张专辑里没有跟挑中的一样长的另一首时不该挡")
	}
}

// storefrontAlbumFake:区服遍历用的假 iTunes,按商店给一张专辑,没列的商店查空。
type storefrontAlbumFake struct {
	collection, artist string
	tracks             []itunesResult
}

func withStorefrontAlbums(t *testing.T, albums map[string]storefrontAlbumFake, local map[string]float64) map[string]int {
	t.Helper()
	withStorefrontFake(t, func(string) (int, string) { return 200, storefrontNoResult }, func(string) (int, string) { return 200, storefrontNoResult })
	asked := map[string]int{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		country := strings.ToUpper(r.URL.Query().Get("country"))
		a, ok := albums[country]
		switch {
		case r.URL.Path == "/lookup":
			res := []map[string]any{{"wrapperType": "collection", "collectionName": a.collection}}
			for _, tr := range a.tracks {
				res = append(res, map[string]any{"wrapperType": "track", "trackName": tr.TrackName, "collectionName": a.collection,
					"artistName": tr.ArtistName, "trackTimeMillis": tr.TrackTimeMillis})
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"results": res})
		case ok:
			asked[country]++
			_ = json.NewEncoder(w).Encode(map[string]any{"results": []map[string]any{{"collectionName": a.collection, "collectionId": 7,
				"artistName": a.artist, "trackName": a.tracks[0].TrackName}}})
		default:
			asked[country]++
			_, _ = io.WriteString(w, storefrontNoResult)
		}
	}))
	t.Cleanup(srv.Close)
	itunesSearchBaseURL, itunesLookupTracksURL = srv.URL, srv.URL+"/lookup"
	enrichMu.Lock()
	saved := enrichCache
	enrichCache = map[string]enrichEntry{}
	for k, d := range local {
		enrichCache[k] = enrichEntry{DurationSecs: d}
	}
	enrichMu.Unlock()
	t.Cleanup(func() {
		enrichMu.Lock()
		enrichCache = saved
		enrichMu.Unlock()
	})
	return asked
}

func TestAppleStorefrontTraversalSkipsContradictedPicks(t *testing.T) {
	t.Run("别人的同名专辑:不用曲名、不收署名、接着问港区", func(t *testing.T) {
		asked := withStorefrontAlbums(t, map[string]storefrontAlbumFake{
			"TW": {"My Love", "李承哲", []itunesResult{
				{TrackName: "My Love", ArtistName: "李承哲", TrackTimeMillis: 204000},
				{TrackName: "Rain", ArtistName: "李承哲", TrackTimeMillis: 190000},
				{TrackName: "Never", ArtistName: "李承哲", TrackTimeMillis: 250000}}},
			"HK": {"My Love", "衛蘭", []itunesResult{
				{TrackName: "一場誤會", ArtistName: "衛蘭", TrackTimeMillis: 204000},
				{TrackName: "十個他不如你一個", ArtistName: "衛蘭", TrackTimeMillis: 231000},
				{TrackName: "大哥", ArtistName: "衛蘭", TrackTimeMillis: 236000}}},
		}, map[string]float64{"卫兰|一场误会|My Love": 202, "卫兰|十个他不如你一个|My Love": 231, "卫兰|大哥|My Love": 236})
		names, title, _ := appleStorefrontIdentitiesAndTitle(context.Background(), "卫兰", "一场误会", "My Love", 202, nil)
		if title != "" {
			t.Errorf("曲名 %q,期望空", title)
		}
		for _, n := range names {
			if n == "李承哲" {
				t.Errorf("署名收了另一个人: %v", names)
			}
		}
		if asked["HK"] == 0 {
			t.Error("台区那张是别人的专辑,港区该接着问")
		}
	})
	t.Run("同一张专辑换了写法:曲名照用;同专辑另一首被挡", func(t *testing.T) {
		withStorefrontAlbums(t, map[string]storefrontAlbumFake{
			"US": {"What a Folk (Spring Groove Edition)", "Crowd Lu", []itunesResult{
				{TrackName: "4.95m² Dream", ArtistName: "Crowd Lu", TrackTimeMillis: 208000},
				{TrackName: "Sleep Here Tonight", ArtistName: "Crowd Lu", TrackTimeMillis: 295000}}},
			"TW": {"What a Folk", "盧廣仲", []itunesResult{
				{TrackName: "一坪半", ArtistName: "盧廣仲", TrackTimeMillis: 208000},
				{TrackName: "一定要相信自己", ArtistName: "盧廣仲", TrackTimeMillis: 212000},
				{TrackName: "今天睡在這裡", ArtistName: "盧廣仲", TrackTimeMillis: 295000}}},
		}, map[string]float64{"卢广仲|一坪半|What a Folk": 208, "卢广仲|一定要相信自己|What a Folk": 207, "卢广仲|今天睡在这里|What a Folk": 295})
		if _, title, _ := appleStorefrontIdentitiesAndTitle(context.Background(), "卢广仲", "一坪半", "What a Folk", 208, nil); title != "4.95m² Dream" {
			t.Errorf("《一坪半》曲名 %q,期望 4.95m² Dream", title)
		}
		if _, title, _ := appleStorefrontIdentitiesAndTitle(context.Background(), "卢广仲", "一定要相信自己", "What a Folk", 207, nil); title != "" {
			t.Errorf("《一定要相信自己》曲名 %q,期望空", title)
		}
	})
	t.Run("本地是现场版、店面挑中的是录音室版:不用曲名,署名照收", func(t *testing.T) {
		withStorefrontAlbums(t, map[string]storefrontAlbumFake{
			"US": {"Filicious - EP", "Fiona Sit", []itunesResult{{TrackName: "9:55 PM (feat. Chapman To)", ArtistName: "Fiona Sit & Chapman To", TrackTimeMillis: 189000}}},
		}, nil)
		names, title, _ := appleStorefrontIdentitiesAndTitle(context.Background(), "薛凯琪", "叮叮车 (Live)", "Filicious Fiona In Concert 2012", 189, nil)
		if title != "" {
			t.Errorf("曲名 %q,期望空", title)
		}
		if len(names) != 1 || names[0] != "Fiona Sit & Chapman To" {
			t.Errorf("署名 %v,期望照收", names)
		}
	})
}

// withStorefrontLegacy:Legacy 里放一条旧结论、署名缓存放旧署名,测完还原。
func withStorefrontLegacy(t *testing.T, artist, album, title, legacy string, names []string) string {
	t.Helper()
	key := normLoose(artist) + "|" + normLoose(album)
	appleStorefrontTitleMu.Lock()
	saved := appleStorefrontTitleLegacy
	appleStorefrontTitleLegacy = map[string]string{key + "|" + normLoose(title): legacy}
	appleStorefrontTitleMu.Unlock()
	appleStorefrontArtistMu.Lock()
	appleStorefrontArtistCache[key] = names
	appleStorefrontArtistMu.Unlock()
	t.Cleanup(func() {
		appleStorefrontTitleMu.Lock()
		appleStorefrontTitleLegacy = saved
		appleStorefrontTitleMu.Unlock()
	})
	return key + "|" + normLoose(title)
}

// 旧结论复核:这一轮又挑到它、被反证挡下才换掉(署名去掉被挡专辑的艺人);这一轮没挑到它(查空、挑到别的)原样转正。
func TestAppleStorefrontLegacyTitleRecheck(t *testing.T) {
	lee := storefrontAlbumFake{"My Love", "李承哲", []itunesResult{
		{TrackName: "My Love", ArtistName: "李承哲", TrackTimeMillis: 204000},
		{TrackName: "Rain", ArtistName: "李承哲", TrackTimeMillis: 190000},
		{TrackName: "Never", ArtistName: "李承哲", TrackTimeMillis: 250000}}}
	local := map[string]float64{"卫兰|一场误会|My Love": 202, "卫兰|十个他不如你一个|My Love": 231, "卫兰|大哥|My Love": 236}
	settled := func(key string) (string, bool, bool) {
		appleStorefrontTitleMu.Lock()
		defer appleStorefrontTitleMu.Unlock()
		v, ok := appleStorefrontTitleCache[key]
		_, still := appleStorefrontTitleLegacy[key]
		return v, ok, still
	}
	t.Run("旧曲名被反证:换掉,署名去掉那位", func(t *testing.T) {
		withStorefrontAlbums(t, map[string]storefrontAlbumFake{"TW": lee}, local)
		key := withStorefrontLegacy(t, "卫兰", "My Love", "一场误会", "My Love", []string{"李承哲", "Janice Vidal"})
		names, title, _ := appleStorefrontIdentitiesAndTitle(context.Background(), "卫兰", "一场误会", "My Love", 202, nil)
		if title != "" {
			t.Errorf("曲名 %q,期望空", title)
		}
		if len(names) != 1 || names[0] != "Janice Vidal" {
			t.Errorf("署名 %v,期望只剩 Janice Vidal", names)
		}
		if v, ok, still := settled(key); !ok || v != "" || still {
			t.Errorf("该落定成空结论、移出 Legacy: %q %v %v", v, ok, still)
		}
	})
	t.Run("这一轮查空:旧曲名原样转正", func(t *testing.T) {
		withStorefrontAlbums(t, map[string]storefrontAlbumFake{}, nil)
		key := withStorefrontLegacy(t, "Mrs. GREEN APPLE", "Lilac - Single", "Lilac", "ライラック", []string{"ミセスグリーンアップル"})
		names, title, _ := appleStorefrontIdentitiesAndTitle(context.Background(), "Mrs. GREEN APPLE", "Lilac", "Lilac - Single", 220, nil)
		if title != "ライラック" {
			t.Errorf("曲名 %q,期望 ライラック", title)
		}
		if len(names) != 1 {
			t.Errorf("署名 %v,期望照旧", names)
		}
		if v, ok, still := settled(key); !ok || v != "ライラック" || still {
			t.Errorf("该转正: %q %v %v", v, ok, still)
		}
	})
	t.Run("这一轮挑到别的、没被反证:旧曲名照旧", func(t *testing.T) {
		withStorefrontAlbums(t, map[string]storefrontAlbumFake{
			"US": {"Disappear", "Sandy Lam", []itunesResult{{TrackName: "失蹤", ArtistName: "Sandy Lam", TrackTimeMillis: 250000}}},
		}, nil)
		withStorefrontLegacy(t, "Sandy Lam", "Disappear", "Disappear", "影子情人", nil)
		if _, title, _ := appleStorefrontIdentitiesAndTitle(context.Background(), "Sandy Lam", "Disappear", "Disappear", 250, nil); title != "影子情人" {
			t.Errorf("曲名 %q,期望照旧", title)
		}
	})
}
