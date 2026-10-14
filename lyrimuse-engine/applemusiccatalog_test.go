package main

import (
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
	"testing"
)

const amTestCatalogID = "312507028"

func amTestIsCatalogLookup(r *http.Request) bool {
	return r.URL.Path == "/v1/catalog/cn/songs/"+amTestCatalogID
}

func amTestSongBody(songs ...applemusicSong) string {
	b, _ := json.Marshal(map[string][]applemusicSong{"data": songs})
	return string(b)
}

func withEmptyApplemusicCache(t *testing.T) {
	applemusicMu.Lock()
	saved := applemusicCache
	applemusicCache = map[string]applemusicResult{}
	applemusicMu.Unlock()
	t.Cleanup(func() {
		applemusicMu.Lock()
		applemusicCache = saved
		applemusicMu.Unlock()
	})
}

// 播放侧给了目录 id:先按 id 直取那一条,取到带时间轴的就不再按名字搜,这份算播放器给定身份。
func TestApplemusicCatalogIDFetchedFirst(t *testing.T) {
	withApplemusicCreds(t, "cn")
	withEmptyApplemusicCache(t)
	var searches int32
	withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/syllable-lyrics"):
			return http.StatusOK, nil, amTestLyricsBody(amTestWordTTML)
		case amTestIsCatalogLookup(r):
			return http.StatusOK, nil, amTestSongBody(amTestSong(amTestCatalogID, "公转自转", "王力宏", "公转.自转", 256227, true))
		case strings.HasSuffix(r.URL.Path, "/v1/catalog/cn/search"):
			atomic.AddInt32(&searches, 1)
			return http.StatusOK, nil, amTestSearchBody(amTestSong("other", "公转自转", "王力宏", "公转.自转", 256227, true))
		}
		return http.StatusNotFound, nil, ""
	})
	r := applemusicLyric(qqRoundCtx(), "王力宏", "公转自转", "公转.自转", 256, amTestCatalogID, "")
	if r.songID != amTestCatalogID || !r.fromPlayerCatalogID || r.yrc == "" {
		t.Fatalf("该按目录 id 取到那一条并标上: songID=%q fromPlayerCatalogID=%v yrc=%d字", r.songID, r.fromPlayerCatalogID, len(r.yrc))
	}
	if searches != 0 {
		t.Errorf("按目录 id 取到了就不该再按名字搜: searches=%d", searches)
	}
}

// 按目录 id 取不到(这个区没上架、没有歌词)时照常按名字搜;搜到的正是这个 id 也算,搜到别的不算;没有目录 id 一律不算。
func TestApplemusicCatalogIDFallsBackToNameSearch(t *testing.T) {
	for _, c := range []struct {
		name      string
		catalogID string
		lookup    string // 按 id 直取的应答:"404" 没上架,"nolyrics" 没有歌词
		searchID  string
		want      bool
	}{
		{"没上架,搜到的就是这一条", amTestCatalogID, "404", amTestCatalogID, true},
		{"没上架,搜到的是另一条", amTestCatalogID, "404", "other", false},
		{"没有歌词,搜到的是另一条", amTestCatalogID, "nolyrics", "other", false},
		{"没有目录 id", "", "404", amTestCatalogID, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			withApplemusicCreds(t, "cn")
			withEmptyApplemusicCache(t)
			withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) {
				switch {
				case strings.HasSuffix(r.URL.Path, "/syllable-lyrics"):
					return http.StatusOK, nil, amTestLyricsBody(amTestWordTTML)
				case amTestIsCatalogLookup(r):
					if c.lookup == "404" {
						return http.StatusNotFound, nil, ""
					}
					s := amTestSong(amTestCatalogID, "公转自转", "王力宏", "公转.自转", 256227, true)
					s.Attributes.HasLyrics = false
					return http.StatusOK, nil, amTestSongBody(s)
				case strings.HasSuffix(r.URL.Path, "/v1/catalog/cn/search"):
					return http.StatusOK, nil, amTestSearchBody(amTestSong(c.searchID, "公转自转", "王力宏", "公转.自转", 256227, true))
				}
				return http.StatusNotFound, nil, ""
			})
			r := applemusicLyric(qqRoundCtx(), "王力宏", "公转自转", "公转.自转", 256, c.catalogID, "")
			if r.songID != c.searchID || r.fromPlayerCatalogID != c.want {
				t.Fatalf("songID=%q fromPlayerCatalogID=%v, want songID=%q %v", r.songID, r.fromPlayerCatalogID, c.searchID, c.want)
			}
		})
	}
}

// 按目录 id 取到的那份要跟本地缓存那份一样带上同源加权的准入。
func TestApplemusicPlayerCatalogIdentityIsWired(t *testing.T) {
	b, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "identityFromLocalClient: r.fromLocalClient || r.fromPlayerCatalogID || appleNoVocals}") {
		t.Error("applemusic 那一路的 identityFromLocalClient 要带上 fromPlayerCatalogID")
	}
}
