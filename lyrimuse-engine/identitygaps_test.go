package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// withStorefrontFake 把 iTunes Search 和专辑 lookup 都指到一个本地服务器,按 country 分发;区服署名 / 曲名 /
// 标题搜索身份三份缓存清空、不落盘。
func withStorefrontFake(t *testing.T, search, lookup func(country string) (int, string)) {
	t.Helper()
	resetITunesSearchBackoff(t)
	savedGuard := sharedHostGuard()
	setSharedHostGuard(newHostGuard(time.Now))
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		country := r.URL.Query().Get("country")
		status, body := search(country)
		if r.URL.Path == "/lookup" {
			status, body = lookup(country)
		}
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	}))
	oldSearch, oldLookup := itunesSearchBaseURL, itunesLookupTracksURL
	itunesSearchBaseURL, itunesLookupTracksURL = srv.URL, srv.URL+"/lookup"

	appleStorefrontArtistMu.Lock()
	oldNames, oldNamesPath, oldNamesDirty := appleStorefrontArtistCache, appleStorefrontArtistPath, appleStorefrontArtistDirty
	appleStorefrontArtistCache, appleStorefrontArtistPath, appleStorefrontArtistDirty = map[string][]string{}, "", false
	appleStorefrontArtistMu.Unlock()
	appleStorefrontTitleMu.Lock()
	oldTitles, oldTitlesPath, oldTitlesDirty := appleStorefrontTitleCache, appleStorefrontTitlePath, appleStorefrontTitleDirty
	appleStorefrontTitleCache, appleStorefrontTitlePath, appleStorefrontTitleDirty = map[string]string{}, "", false
	appleStorefrontTitleMu.Unlock()
	appleTitleSearchIdentityMu.Lock()
	oldIdentities := appleTitleSearchIdentityCache
	appleTitleSearchIdentityCache = map[string][]string{}
	appleTitleSearchIdentityMu.Unlock()

	t.Cleanup(func() {
		srv.Close()
		itunesSearchBaseURL, itunesLookupTracksURL = oldSearch, oldLookup
		setSharedHostGuard(savedGuard)
		appleStorefrontArtistMu.Lock()
		appleStorefrontArtistCache, appleStorefrontArtistPath, appleStorefrontArtistDirty = oldNames, oldNamesPath, oldNamesDirty
		appleStorefrontArtistMu.Unlock()
		appleStorefrontTitleMu.Lock()
		appleStorefrontTitleCache, appleStorefrontTitlePath, appleStorefrontTitleDirty = oldTitles, oldTitlesPath, oldTitlesDirty
		appleStorefrontTitleMu.Unlock()
		appleTitleSearchIdentityMu.Lock()
		appleTitleSearchIdentityCache = oldIdentities
		appleTitleSearchIdentityMu.Unlock()
	})
}

const (
	storefrontAlbumHit = `{"results":[{"collectionName":"Some Album","collectionId":7,"artistName":"Some Band","trackName":"Song"}]}`
	storefrontNoResult = `{"results":[]}`
)

// storefrontTracks:专辑 7 的曲目表,唯一一首署名写作 artist。
func storefrontTracks(artist string) string {
	return `{"results":[{"wrapperType":"collection","collectionName":"Some Album"},` +
		`{"wrapperType":"track","trackName":"Song","collectionName":"Some Album","artistName":"` + artist + `","trackTimeMillis":200000}]}`
}

// 区服遍历里有一个商店没问成(限流 / 5xx)、或定位到的专辑没取到曲目表时,这一轮不是完整结论:
// 查空的署名不记、「本地写法就是规范的」曲名结论不记;每个商店都问成了才两样都记。
func TestAppleStorefrontCachesOnlyCompleteConclusions(t *testing.T) {
	const artist, title, album = "Some Band", "Song", "Some Album"
	key := normLoose(artist) + "|" + normLoose(album)
	titleKey := key + "|" + normLoose(title)
	cached := func() (names []string, namesOK bool, canonical string, titleOK bool) {
		appleStorefrontArtistMu.Lock()
		names, namesOK = appleStorefrontArtistCache[key]
		appleStorefrontArtistMu.Unlock()
		appleStorefrontTitleMu.Lock()
		canonical, titleOK = appleStorefrontTitleCache[titleKey]
		appleStorefrontTitleMu.Unlock()
		return
	}
	cases := []struct {
		name            string
		search, lookup  map[string]string // country → 响应体;没列的国家回 500
		wantNames       []string
		wantNamesCached bool
		wantTitleCached bool
		wantComplete    bool
	}{
		{
			name:            "美区没问成:查到的署名照记,曲名结论不记",
			search:          map[string]string{"CN": storefrontAlbumHit},
			lookup:          map[string]string{"CN": storefrontTracks("Some Band Alias")},
			wantNames:       []string{"Some Band Alias"},
			wantNamesCached: true,
		},
		{
			name:   "美区没问成、中区没这张专辑:空署名不记",
			search: map[string]string{"CN": storefrontNoResult},
		},
		{
			name:   "中区定位到专辑却没取到曲目表:两样都不记",
			search: map[string]string{"CN": storefrontAlbumHit, "US": storefrontNoResult},
		},
		{
			name:            "每个商店都问成了:空署名和空曲名都记",
			search:          map[string]string{"CN": storefrontAlbumHit, "US": storefrontNoResult},
			lookup:          map[string]string{"CN": storefrontTracks("Some Band")},
			wantNamesCached: true,
			wantTitleCached: true,
			wantComplete:    true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			reply := func(m map[string]string) func(string) (int, string) {
				return func(country string) (int, string) {
					if body, ok := m[country]; ok {
						return http.StatusOK, body
					}
					return http.StatusInternalServerError, ""
				}
			}
			withStorefrontFake(t, reply(tc.search), reply(tc.lookup))
			gotNames, gotTitle, gotComplete := appleStorefrontIdentitiesAndTitle(context.Background(), artist, title, album, 200, nil)
			// complete 跟缓存写没写是两回事:美区没问成、中区查到了署名时署名照记,这一轮却不完整。
			if gotComplete != tc.wantComplete {
				t.Errorf("这一轮问全了吗 = %v, want %v", gotComplete, tc.wantComplete)
			}
			if !reflect.DeepEqual(gotNames, tc.wantNames) || gotTitle != "" {
				t.Fatalf("返回 %v %q, want %v \"\"", gotNames, gotTitle, tc.wantNames)
			}
			names, namesOK, canonical, titleOK := cached()
			if namesOK != tc.wantNamesCached {
				t.Errorf("署名缓存写入 = %v, want %v (%v)", namesOK, tc.wantNamesCached, names)
			}
			if namesOK && len(names) != len(tc.wantNames) {
				t.Errorf("署名缓存 = %v, want %v", names, tc.wantNames)
			}
			if titleOK != tc.wantTitleCached {
				t.Errorf("曲名缓存写入 = %v, want %v (%q)", titleOK, tc.wantTitleCached, canonical)
			}
		})
	}
}

// 标题搜索身份:有一个商店没问成时查空不缓存,下一次还会再问;都问成了才把查空记下。
func TestAppleTitleSearchIdentitiesSkipsCacheWhenAStorefrontFailed(t *testing.T) {
	var usOK atomic.Bool
	var usHits atomic.Int32
	withStorefrontFake(t, func(country string) (int, string) {
		if country == "US" {
			usHits.Add(1)
			if !usOK.Load() {
				return http.StatusInternalServerError, ""
			}
		}
		return http.StatusOK, storefrontNoResult
	}, func(string) (int, string) { return http.StatusOK, storefrontNoResult })
	key := normLoose("Some Band") + "|" + normLoose("Song") + "||200"
	isCached := func() bool {
		appleTitleSearchIdentityMu.Lock()
		defer appleTitleSearchIdentityMu.Unlock()
		_, ok := appleTitleSearchIdentityCache[key]
		return ok
	}

	if got := appleTitleSearchIdentities(context.Background(), "Some Band", "Song", "", 200); len(got) != 0 {
		t.Fatalf("查空应返回空, got %v", got)
	}
	if isCached() {
		t.Fatal("美区没问成,查空不能记进缓存")
	}
	usOK.Store(true)
	before := usHits.Load()
	appleTitleSearchIdentities(context.Background(), "Some Band", "Song", "", 200)
	if usHits.Load() == before {
		t.Fatal("上一轮没记缓存,这一轮应该重新问")
	}
	if !isCached() {
		t.Fatal("每个商店都问成了,查空应该记下")
	}
}

// 两次查询分开挑:同一条同名结果,「艺人 + 曲名」那次就查到时照旧采(没时长、没专辑名时信第一条);只有裸曲名
// 那次查到时,没有专辑名、也没有时长作证,不采。
func TestAppleTitleSearchIdentitiesTitleOnlyQueryNeedsEvidence(t *testing.T) {
	withStorefrontFake(t, func(string) (int, string) { return http.StatusOK, storefrontNoResult },
		func(string) (int, string) { return http.StatusOK, storefrontNoResult })
	var bareOnly atomic.Bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if bareOnly.Load() && r.URL.Query().Get("term") != "Wild Flower" {
			_, _ = io.WriteString(w, storefrontNoResult)
			return
		}
		_, _ = io.WriteString(w, `{"results":[{"trackName":"WILDFLOWER","artistName":"Billie Eilish","collectionName":"HIT ME HARD AND SOFT"}]}`)
	}))
	saved := itunesSearchBaseURL
	itunesSearchBaseURL = srv.URL
	t.Cleanup(func() {
		srv.Close()
		itunesSearchBaseURL = saved
	})
	resetCache := func() {
		appleTitleSearchIdentityMu.Lock()
		appleTitleSearchIdentityCache = map[string][]string{}
		appleTitleSearchIdentityMu.Unlock()
	}

	if got := appleTitleSearchIdentities(context.Background(), "RM和조유진", "Wild Flower", "", 0); !reflect.DeepEqual(got, []string{"Billie Eilish"}) {
		t.Fatalf("「艺人 + 曲名」那次查到时照旧信第一条, got %v", got)
	}
	bareOnly.Store(true)
	resetCache()
	if got := appleTitleSearchIdentities(context.Background(), "RM和조유진", "Wild Flower", "", 0); len(got) != 0 {
		t.Fatalf("只有裸曲名那次查到、没有专辑名也没有时长时不该采, got %v", got)
	}
	resetCache()
	if got := appleTitleSearchIdentities(context.Background(), "RM和조유진", "Wild Flower", "HIT ME HARD AND SOFT", 0); !reflect.DeepEqual(got, []string{"Billie Eilish"}) {
		t.Fatalf("只有裸曲名那次查到、专辑对得上时该采, got %v", got)
	}
}

// MusicBrainz 明确说没有这个 mbid(404)是结论:记成「查过、没登记国家」,一个月内不再问;503 只是没问成,不记。
func TestWarmArtistRegionsRecordsDefinitiveMiss(t *testing.T) {
	resetArtistRegionsCache()
	defer resetArtistRegionsCache()
	chart := []lastfmChartEntry{{Name: "A", PlayCount: 5, Mbid: "gone"}, {Name: "B", PlayCount: 4, Mbid: "flaky"}}
	var asked []string
	src := fakeRegionsSource(chart, nil, &asked)
	src.country = func(ctx context.Context, mbid string) (string, int, error) {
		asked = append(asked, mbid)
		if mbid == "gone" {
			return "", 1, &mbStatusError{url: "u", status: http.StatusNotFound}
		}
		return "", 1, &mbStatusError{url: "u", status: http.StatusServiceUnavailable}
	}
	now := time.Unix(1_800_000_000, 0)
	warmArtistRegions(context.Background(), now, "u", 60, src)
	e, ok := artistRegionsCache.Artists["gone"]
	if !ok || e.Country != "" || e.Checked != now.Unix() {
		t.Fatalf("404 应记成查过、没国家: ok=%v %+v", ok, e)
	}
	if _, ok := artistRegionsCache.Artists["flaky"]; ok {
		t.Fatal("503 是没问成,不能记成结论")
	}

	asked = nil
	warmArtistRegions(context.Background(), now.Add(artistRegionsPartialRetry+time.Minute), "u", 60, src)
	if !reflect.DeepEqual(asked, []string{"flaky"}) {
		t.Fatalf("下一轮只该重问没问成的那位, asked %v", asked)
	}
}

// QQ 歌手建议的第一条常常是别人:头像只取名字对得上的那条,都对不上就当这边没有。
func TestQQSingerAvatarPicksTheMatchingName(t *testing.T) {
	var items string
	withQQFake(t, func(target string) (int, string) {
		if strings.HasSuffix(target, "/splcloud/fcgi-bin/smartbox_new.fcg") {
			return http.StatusOK, `{"code":0,"data":{"singer":{"itemlist":[` + items + `]}}}`
		}
		return http.StatusNotFound, ""
	})
	items = `{"name":"婉婷","pic":"http://y.gtimg.cn/music/photo_new/T001R150x150M000other.jpg"},` +
		`{"name":"曲婉婷","pic":"http://y.gtimg.cn/music/photo_new/T001R150x150M000right.jpg"}`
	pic, ok := qqSingerAvatar("曲婉婷")
	if !ok || !strings.Contains(pic, "M000right") {
		t.Fatalf("应取名字对得上的第二条, got %q ok=%v", pic, ok)
	}
	items = `{"name":"婉婷","pic":"http://y.gtimg.cn/music/photo_new/T001R150x150M000other.jpg"}`
	pic, ok = qqSingerAvatar("Wanting")
	if !ok || pic != "" {
		t.Fatalf("都对不上应当成这边没有(不是故障), got %q ok=%v", pic, ok)
	}
}

// 身份缓存存盘前先并盘上的:别的进程(手动跑的 top-artists)写进去的条目不能被整份写回盖掉;同名键以内存为准。
func TestSaveArtistIdentityCacheMergesDiskEntries(t *testing.T) {
	path := filepath.Join(t.TempDir(), "artist-identity.json")
	artistIdentityMu.Lock()
	oldCache, oldPath, oldDirty := artistIdentityCache, artistIdentityPath, artistIdentityDirty
	artistIdentityMu.Unlock()
	t.Cleanup(func() {
		artistIdentityMu.Lock()
		artistIdentityCache, artistIdentityPath, artistIdentityDirty = oldCache, oldPath, oldDirty
		artistIdentityMu.Unlock()
	})
	if err := os.WriteFile(path, []byte(`{"Other":{"mbid":"m-other","zh":"别人"},"Mine":{"mbid":"m-stale"}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	artistIdentityMu.Lock()
	artistIdentityPath = path
	artistIdentityCache = map[string]mbArtistIdentity{"Mine": {Mbid: "m-mine"}}
	artistIdentityDirty = true
	artistIdentityMu.Unlock()

	saveArtistIdentityCache()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]mbArtistIdentity
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	want := map[string]mbArtistIdentity{"Other": {Mbid: "m-other", Zh: "别人"}, "Mine": {Mbid: "m-mine"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("盘上 = %+v, want %+v", got, want)
	}
}

// 动态封面三条入口都拿这条记录自己的署名去对锚点:别人专辑里的同名歌(Bing Crosby《Christmas》里的
// White Christmas)不能把它的专辑 ID 给 Bublé 那条用。
func TestMotionCoverAnchorChecksTheEntryArtist(t *testing.T) {
	const title, album = "White Christmas", "Christmas"
	withAppleCatalogState(t)
	appleCatalogMu.Lock()
	appleCatalogCache = map[string]appleCatalogTrack{
		"1": {TrackName: title, AlbumName: album, ArtistName: "Bing Crosby", AlbumID: 22},
	}
	appleCatalogMu.Unlock()
	motionCoverMu.Lock()
	oldMotion := motionCoverCache
	motionCoverCache = map[string]motionCover{}
	motionCoverMu.Unlock()
	t.Cleanup(func() {
		motionCoverMu.Lock()
		motionCoverCache = oldMotion
		motionCoverMu.Unlock()
	})

	if motionCoverWorthBackfill(enrichEntry{}, "Michael Bublé", title, album) {
		t.Error("backfill:别人的锚点不该让 Bublé 那条进门")
	}
	if !motionCoverWorthBackfill(enrichEntry{}, "Bing Crosby", title, album) {
		t.Error("backfill:署名对得上、专辑还没查过,应该进门")
	}

	// 专辑 22 已查过、没有动态封面:能用上这个锚点的条目会被记成 checked,用不上的不动。
	motionCoverMu.Lock()
	motionCoverCache["22"] = motionCover{}
	motionCoverMu.Unlock()
	for artist, want := range map[string]bool{"Michael Bublé": false, "Bing Crosby": true} {
		var e enrichEntry
		e.fillMotionCover(context.Background(), artist, title, album)
		if e.MotionCoverChecked != want {
			t.Errorf("fillMotionCover(%s): checked = %v, want %v", artist, e.MotionCoverChecked, want)
		}

		isolateEnrichCache(t)
		key := enrichKey(artist, title, album)
		enrichMu.Lock()
		enrichCache[key] = enrichEntry{}
		enrichMu.Unlock()
		recheckMotionCoverAgainstCurrentCover(context.Background(), key, title, album)
		enrichMu.Lock()
		got := enrichCache[key].MotionCoverChecked
		enrichMu.Unlock()
		if got != want {
			t.Errorf("recheck(%s):署名要从键里取出来核锚点, checked = %v, want %v", artist, got, want)
		}
	}
}
