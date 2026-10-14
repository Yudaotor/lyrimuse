package main

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
)

const (
	originSimplifiedLRC  = "[00:10.51]青丝已白发 徒留下那段牵挂\n[00:15.53]情深或缘浅 往往都在一刹那\n[00:20.21]在爱与不爱间 徘徊留恋与挣扎"
	originTraditionalLRC = "[00:10.51]青絲已白髮 徒留下那段牽掛\n[00:15.53]情深或緣淺 往往都在一剎那\n[00:20.21]在愛與不愛間 徘徊留戀與掙扎"
	originKanjiHeavyLRC  = "[00:05.00]東京都心夜景\n[00:10.00]永遠約束\n[00:15.00]花火大会夏祭"
	originHangulLRC      = "[00:05.00]너를 처음 만난 그날 밤\n[00:10.00]우리 함께 걷던 그 길"
)

// 原产地商店的顺序:ISRC 登记国在前,再是按文字系统挑的,最后是三个中文区(简体 cn、tw、hk,繁体 tw、hk、cn);
// 本地曲名带中日韩文字时不接中文区。
func TestOriginStorefronts(t *testing.T) {
	for _, c := range []struct {
		name, isrc, title string
		samples           []string
		want              []string
	}{
		{"简体正文、拉丁曲名", "", "The Agreement Under the Cherry Blossom Tree", []string{originSimplifiedLRC}, []string{"cn", "tw", "hk"}},
		{"繁体正文", "", "Black Hole", []string{originTraditionalLRC}, []string{"tw", "hk", "cn"}},
		{"假名在、汉字为主的正文也在:jp 排在中文区前面(日文汉字按繁体算)", "", "Tabiji", []string{originJapaneseLRC, originKanjiHeavyLRC}, []string{"jp", "tw", "hk", "cn"}},
		{"ISRC 登记在台湾:tw 排最前", "TWA471234567", "Black Hole", []string{originSimplifiedLRC}, []string{"tw", "cn", "hk"}},
		{"只有 ISRC 是原产地线索", "JPPO02100112", "Tabiji", []string{"[00:01.00]plain english words"}, []string{"jp"}},
		{"美国登记的 ISRC 不是原产地线索", "USA2P2647290", "You, You", []string{"[00:01.00]plain english words"}, nil},
		{"谚文正文", "", "Spring Day", []string{originHangulLRC}, []string{"kr"}},
		{"本地曲名是汉字:不接中文区", "", "樱花树下的约定", []string{originSimplifiedLRC}, nil},
		{"本地曲名只有括号里是汉字:照接", "", "Black Hole (黑洞)", []string{originSimplifiedLRC}, []string{"cn", "tw", "hk"}},
	} {
		samples := append([]string{"Artist", c.title, "Album"}, c.samples...)
		if got := originStorefronts(c.isrc, c.title, samples...); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

// 按 ISRC 依次问:没有这条录音的商店跳过,第一个上架了它的商店说了算 —— 那边也写拉丁字母(本地写法就是原名)时不再往下问。
func TestOriginRecordingByISRCFirstCarrierDecides(t *testing.T) {
	withTestDevToken(t)
	resetOriginTitleState(t)
	reqs := withISRCCatalogFake(t, map[string][]applemusicSong{
		"tw|TWX000000001": {isrcSong("黑洞裡", "方大同", 213000)},
		"hk|TWX000000001": {isrcSong("黑洞裏", "方大同", 213000)},
		"cn|CNX000000002": {isrcSong("Love Song", "方大同", 240000)},
		"tw|CNX000000002": {isrcSong("愛的歌", "方大同", 240000)},
	})
	origins := []string{"cn", "tw", "hk"}
	if got := originRecordingByISRC(qqRoundCtx(), "Black Hole", "TWX000000001", origins, 213); got != (originRecording{"黑洞裡", "方大同"}) {
		t.Errorf("大陆没上架,台区那条换了文字: got %+v", got)
	}
	if got := originRecordingByISRC(qqRoundCtx(), "Love Song", "CNX000000002", origins, 240); got != (originRecording{}) {
		t.Errorf("大陆上架了、也写英文:本地写法就是原名,got %+v", got)
	}
	if rs := strings.Join(reqs(), ","); rs != "cn|TWX000000001,tw|TWX000000001,cn|CNX000000002" {
		t.Errorf("请求不对(找到第一个上架的商店就停): %q", rs)
	}
}

// issue 49 那首:美区报英文译名与英文艺名,正文是简体中文,ISRC 登记在中国;按 ISRC 在大陆商店查到原名与原署名。
func TestLyricOriginRecordingChineseSongWithEnglishTitle(t *testing.T) {
	withTestDevToken(t)
	resetOriginTitleState(t)
	withISRCCatalogFake(t, map[string][]applemusicSong{
		"cn|CNZ781903632": {isrcSong("樱花树下的约定", "柯柯柯啊", 189460)},
	})
	got := lyricOriginRecording(qqRoundCtx(), "Kekekea", "The Agreement Under the Cherry Blossom Tree",
		"The Agreement Under the Cherry Blossom Tree - Single", 189.5, []string{originSimplifiedLRC}, "CNZ781903632")
	if got != (originRecording{"樱花树下的约定", "柯柯柯啊"}) {
		t.Fatalf("got %+v", got)
	}
}

// 区服遍历:简体样本只在 CN 定位不到这张专辑时才接着问 TW / HK;TW 定位到了就不问 HK。CN 定位到了 TW / HK 都不问。
func TestAppleStorefrontScanAsksOtherChineseStorefrontsOnlyWhenCNLacksTheAlbum(t *testing.T) {
	const artist, title, album = "Khalil Fong", "Song", "Some Album"
	twTracks := `{"results":[{"wrapperType":"collection","collectionName":"Some Album"},` +
		`{"wrapperType":"track","trackName":"黑洞裡","collectionName":"Some Album","artistName":"方大同","trackTimeMillis":200000}]}`
	for _, tc := range []struct {
		name          string
		search        map[string]string
		lookup        map[string]string
		wantCanonical string
		wantAsked     []string
	}{
		{
			name:          "CN 没有这张专辑:问 TW,TW 有就不问 HK",
			search:        map[string]string{"CN": storefrontNoResult, "US": storefrontAlbumHit, "TW": storefrontAlbumHit, "HK": storefrontAlbumHit},
			lookup:        map[string]string{"US": storefrontTracks(artist), "TW": twTracks, "HK": twTracks},
			wantCanonical: "黑洞裡",
			wantAsked:     []string{"CN", "US", "TW"},
		},
		{
			name:      "CN 有这张专辑:TW / HK 都不问",
			search:    map[string]string{"CN": storefrontAlbumHit, "US": storefrontAlbumHit, "TW": storefrontAlbumHit, "HK": storefrontAlbumHit},
			lookup:    map[string]string{"CN": storefrontTracks(artist), "US": storefrontTracks(artist), "TW": twTracks, "HK": twTracks},
			wantAsked: []string{"CN", "US"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var mu sync.Mutex
			var asked []string
			withStorefrontFake(t, func(country string) (int, string) {
				mu.Lock()
				asked = append(asked, country)
				mu.Unlock()
				if body, ok := tc.search[country]; ok {
					return http.StatusOK, body
				}
				return http.StatusInternalServerError, ""
			}, func(country string) (int, string) {
				if body, ok := tc.lookup[country]; ok {
					return http.StatusOK, body
				}
				return http.StatusInternalServerError, ""
			})
			_, canonical, complete := appleStorefrontIdentitiesAndTitle(context.Background(), artist, title, album, 200, []string{originSimplifiedLRC})
			if canonical != tc.wantCanonical || !complete {
				t.Errorf("规范曲名 %q complete=%v, want %q true", canonical, complete, tc.wantCanonical)
			}
			mu.Lock()
			defer mu.Unlock()
			var searched []string
			for _, c := range asked {
				if len(searched) == 0 || searched[len(searched)-1] != c {
					searched = append(searched, c)
				}
			}
			if !reflect.DeepEqual(searched, tc.wantAsked) {
				t.Errorf("问过的商店 %v, want %v", searched, tc.wantAsked)
			}
		})
	}
}

// 标题缓存版本 1 的空结论(在更少的商店里得出的)读入时丢掉、查到的曲名留着,下次存盘写成当前版本。
func TestAppleStorefrontTitleCacheMigratesV1(t *testing.T) {
	path := filepath.Join(t.TempDir(), "title-cache.json")
	data, _ := json.Marshal(appleStorefrontTitleFile{Version: 1, Entries: map[string]string{
		"khalil fong|some album|black hole":           "",
		"mrs green apple|kusushiki  single|kusushiki": "クスシキ",
	}})
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	savedCache, savedPath, savedDirty := appleStorefrontTitleCache, appleStorefrontTitlePath, appleStorefrontTitleDirty
	t.Cleanup(func() {
		appleStorefrontTitleCache, appleStorefrontTitlePath, appleStorefrontTitleDirty = savedCache, savedPath, savedDirty
	})
	loadAppleStorefrontTitleCache(path)
	if _, ok := appleStorefrontTitleCache["khalil fong|some album|black hole"]; ok {
		t.Error("版本 1 的空结论该丢掉")
	}
	if got := appleStorefrontTitleCache["mrs green apple|kusushiki  single|kusushiki"]; got != "クスシキ" {
		t.Errorf("查到的曲名该留着, got %q", got)
	}
	saveAppleStorefrontTitleCache()
	var f appleStorefrontTitleFile
	raw, _ := os.ReadFile(path)
	if json.Unmarshal(raw, &f) != nil || f.Version != appleStorefrontTitleCacheVersion || len(f.Entries) != 1 {
		t.Errorf("存盘该写成当前版本、只剩查到的那条: %+v", f)
	}
}
