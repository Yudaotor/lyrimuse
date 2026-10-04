package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// 歌手榜展开行:歌曲按署名归到榜上的歌手名下。归错的后果是展开的歌单混进别人的歌、或者
// 「周杰伦」那几首被漏掉,跟榜上的次数对不上。

func testArtistTracksNameKey(s string) string {
	return strings.ToLower(toSimplified(firstCreditedArtist(s)))
}

func TestGroupTracksByArtists(t *testing.T) {
	resolve := func(name, _ string) mbArtistIdentity {
		if name == "Leah Dou" || name == "窦靖童" {
			return mbArtistIdentity{Mbid: "dou"}
		}
		return mbArtistIdentity{}
	}
	tracks := []artistTrack{
		{Name: "晴天", Artist: "周杰伦", PlayCount: 30},
		{Name: "Purple Rain", Artist: "Prince & The Revolution", PlayCount: 25},
		{Name: "Kiss", Artist: "Prince", PlayCount: 20},
		{Name: "早上好", Artist: "Leah Dou", PlayCount: 15},
		{Name: "稻香", Artist: "周杰倫", PlayCount: 10},
		{Name: "Other", Artist: "Someone", PlayCount: 8},
		{Name: "Monday", Artist: "窦靖童", PlayCount: 5},
		{Name: "七里香", Artist: "周杰伦", PlayCount: 3},
	}
	got := groupTracksByArtists([]string{"周杰倫", "Prince", "窦靖童", "NoTracks"}, tracks, resolve, testArtistTracksNameKey, 2)

	check := func(name string, wantTracks []string, wantCount, wantPlays int) {
		t.Helper()
		row, ok := got[name]
		if !ok {
			t.Fatalf("%s 应有归到的歌: %+v", name, got)
		}
		var names []string
		for _, tr := range row.Tracks {
			names = append(names, tr.Name)
		}
		if strings.Join(names, "|") != strings.Join(wantTracks, "|") || row.TrackCount != wantCount || row.PlayCount != wantPlays {
			t.Errorf("%s: got %v / %d 首 / %d 次, want %v / %d / %d", name, names, row.TrackCount, row.PlayCount, wantTracks, wantCount, wantPlays)
		}
	}
	check("周杰倫", []string{"晴天", "稻香"}, 3, 43)               // 繁简两种署名都归进来,只列前 2 首、总数按全部算
	check("Prince", []string{"Purple Rain", "Kiss"}, 2, 45) // 合唱署名按第一位歌手归
	check("窦靖童", []string{"早上好", "Monday"}, 2, 20)          // 名字键连不上,靠同一个 mbid 并进来
	if _, ok := got["NoTracks"]; ok {
		t.Errorf("一首都没归到的名字不该出现: %+v", got["NoTracks"])
	}
	if len(got) != 3 {
		t.Errorf("榜外的署名(Someone)不该单独出现: %+v", got)
	}

	dup := groupTracksByArtists([]string{"周杰倫", "周杰伦"}, tracks, resolve, testArtistTracksNameKey, 10)
	if dup["周杰倫"].TrackCount != 3 || len(dup) != 1 {
		t.Errorf("两个名字落进同一桶时归先出现的那个: %+v", dup)
	}
}

// 假的 user.getTopTracks:pages 页,第 p 页两首,次数随页递减;failPage 那一页回 500。
func fakeTopTracksClient(t *testing.T, pages, failPage int, requested *[]int) *http.Client {
	t.Helper()
	var mu sync.Mutex
	return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		q := r.URL.Query()
		if q.Get("method") != "user.getTopTracks" || q.Get("limit") != "1000" {
			t.Errorf("unexpected request: %s", r.URL.RawQuery)
		}
		page, _ := strconv.Atoi(q.Get("page"))
		mu.Lock()
		*requested = append(*requested, page)
		mu.Unlock()
		if page == failPage {
			return &http.Response{StatusCode: 500, Body: io.NopCloser(strings.NewReader(`{}`)), Header: http.Header{}}, nil
		}
		base := 100 - page*10
		body := fmt.Sprintf(`{"toptracks":{"track":[{"name":"p%d-a","playcount":"%d","artist":{"name":"Alpha","mbid":""}},{"name":"p%d-b","playcount":"%d","artist":{"name":"Alpha & Beta","mbid":""}}],"@attr":{"totalPages":"%d"}}}`,
			page, base, page, base-1, pages)
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: http.Header{}}, nil
	})}
}

func TestLastfmTopTracksAll(t *testing.T) {
	useUnthrottledGuard(t)
	saved := lastfmReadClient
	t.Cleanup(func() { lastfmReadClient = saved })

	var requested []int
	lastfmReadClient = fakeTopTracksClient(t, 3, 0, &requested)
	var firstCalls int
	var firstLen int
	all, complete, err := lastfmTopTracksAll(t.Context(), "u", "k", "12month", 20, func(first []artistTrack) {
		firstCalls++
		firstLen = len(first)
	})
	if err != nil || !complete || len(all) != 6 {
		t.Fatalf("三页应全部取完: %d 首 complete=%v err=%v", len(all), complete, err)
	}
	for i := 1; i < len(all); i++ {
		if all[i].PlayCount > all[i-1].PlayCount {
			t.Errorf("分页要按页序拼回去、保持次数降序: %+v", all)
		}
	}
	if firstCalls != 1 || firstLen != 2 {
		t.Errorf("第 1 页到手后应回调一次、只带第 1 页: calls=%d len=%d", firstCalls, firstLen)
	}

	requested = nil
	all, complete, err = lastfmTopTracksAll(t.Context(), "u", "k", "12month", 2, nil)
	if err != nil || complete || len(all) != 4 || len(requested) != 2 {
		t.Errorf("超过页数上限只取前 2 页并标 complete=false: %d 首 complete=%v 请求 %v err=%v", len(all), complete, requested, err)
	}

	requested = nil
	lastfmReadClient = fakeTopTracksClient(t, 1, 0, &requested)
	firstCalls = 0
	all, complete, err = lastfmTopTracksAll(t.Context(), "u", "k", "7day", 20, func([]artistTrack) { firstCalls++ })
	if err != nil || !complete || len(all) != 2 || firstCalls != 0 {
		t.Errorf("只有一页时直接返回、不回调: %d 首 complete=%v calls=%d err=%v", len(all), complete, firstCalls, err)
	}

	requested = nil
	lastfmReadClient = fakeTopTracksClient(t, 3, 2, &requested)
	if _, _, err := lastfmTopTracksAll(t.Context(), "u", "k", "12month", 20, nil); err == nil {
		t.Error("任何一页失败都要整体失败,少一页会让次数静默变少")
	}
}

func TestLastfmTopTracksPageTimeout(t *testing.T) {
	useUnthrottledGuard(t)
	saved := lastfmReadClient
	t.Cleanup(func() { lastfmReadClient = saved })
	var left time.Duration
	lastfmReadClient = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if d, ok := r.Context().Deadline(); ok {
			left = time.Until(d)
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"toptracks":{"track":[],"@attr":{"totalPages":"1"}}}`)), Header: http.Header{}}, nil
	})}
	if _, _, err := lastfmTopTracksPage(t.Context(), "u", "k", "overall", 1); err != nil {
		t.Fatal(err)
	}
	if left < 15*time.Second {
		t.Errorf("一页的超时要比通用的 8 秒宽(排队也占超时),实际剩 %v", left)
	}
}

func TestArtistTracksCLIProgress(t *testing.T) {
	useCLIConfigDir(t, map[string]string{"lastfm_user": "someone", "lastfm_api_key": "read-key"})
	savedCacheOnly, savedIdentity, savedAlias, savedQQ := artistCanonicalCacheOnly, artistIdentityPath, artistAliasPath, qqArtistNamePath
	t.Cleanup(func() {
		artistCanonicalCacheOnly, artistIdentityPath, artistAliasPath, qqArtistNamePath = savedCacheOnly, savedIdentity, savedAlias, savedQQ
	})
	useUnthrottledGuard(t)
	saved := lastfmReadClient
	t.Cleanup(func() { lastfmReadClient = saved })
	var requested []int
	lastfmReadClient = fakeTopTracksClient(t, 2, 0, &requested)

	out := captureStdout(t, func() {
		runArtistTracksCLI([]string{"-progress", "-period", "12month", "-tracks", "3", "Alpha"})
	})
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 2 {
		t.Fatalf("-progress 且不止一页时应先后输出两行: %q", out)
	}
	var partial, final artistTracksOutput
	if err := json.Unmarshal([]byte(lines[0]), &partial); err != nil || !partial.Partial || partial.Complete {
		t.Fatalf("第一行应是第 1 页的 partial 结果: %v %q", err, lines[0])
	}
	if err := json.Unmarshal([]byte(lines[1]), &final); err != nil || final.Partial || !final.Complete {
		t.Fatalf("第二行应是最终结果: %v %q", err, lines[1])
	}
	p, f := partial.Rows["Alpha"], final.Rows["Alpha"]
	if len(p.Tracks) != 2 || f.TrackCount != 4 || len(f.Tracks) != 3 || f.PlayCount != 90+89+80+79 {
		t.Errorf("partial 只含第 1 页,最终含两页(合唱署名归第一位): partial=%+v final=%+v", p, f)
	}
	for i, tr := range p.Tracks {
		if f.Tracks[i].Name != tr.Name {
			t.Errorf("partial 的歌应是最终结果的前几首: partial=%+v final=%+v", p.Tracks, f.Tracks)
		}
	}
}
