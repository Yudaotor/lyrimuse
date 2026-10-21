package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// useRangeLastfm:Last.fm 只读接口按区间回不同的榜单 —— charts(from) 给出 [from, …) 这一期的三份榜单,nil 表示这一期没听。
func useRangeLastfm(t *testing.T, charts func(from int64) []string, extra map[string]string) *[]string {
	t.Helper()
	useUnthrottledGuard(t)
	var mu sync.Mutex
	var methods []string
	saved := lastfmReadClient
	t.Cleanup(func() { lastfmReadClient = saved })
	lastfmReadClient = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		q := r.URL.Query()
		mu.Lock()
		methods = append(methods, q.Get("method"))
		mu.Unlock()
		body, status := extra[q.Get("method")], 200
		from, _ := strconv.ParseInt(q.Get("from"), 10, 64)
		if c := charts(from); c != nil {
			switch q.Get("method") {
			case "user.getWeeklyTrackChart":
				body = c[0]
			case "user.getWeeklyArtistChart":
				body = c[1]
			case "user.getWeeklyAlbumChart":
				body = c[2]
			}
		} else if strings.HasPrefix(q.Get("method"), "user.getWeekly") && q.Get("method") != "user.getWeeklyChartList" {
			body = map[string]string{"user.getWeeklyTrackChart": emptyTrackChart, "user.getWeeklyArtistChart": emptyArtistChart,
				"user.getWeeklyAlbumChart": emptyAlbumChart}[q.Get("method")]
		}
		if body == "" {
			status, body = 500, `{"error":8,"message":"backend"}`
		}
		return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body)), Header: http.Header{}}, nil
	})}
	return &methods
}

func clearDigestPreviewCache(t *testing.T) {
	t.Helper()
	digestPreviewMu.Lock()
	digestPreviewCache = map[string]digestPreviewResult{}
	digestPreviewMu.Unlock()
	t.Cleanup(func() {
		digestPreviewMu.Lock()
		digestPreviewCache = map[string]digestPreviewResult{}
		digestPreviewMu.Unlock()
	})
}

var previewCfg = &config{LastfmUser: "someone", LastfmAPIKey: "read-key"}

// 日报预览:今天还没听就取昨天一整天,标题跟着写「昨日」;同一期十分钟内不重取。
func TestDigestPreviewDailyFallsBackToYesterday(t *testing.T) {
	useDigestFeatures(t, featureFlags{DigestTopN: 3})
	clearDigestPreviewCache(t)
	now := time.Date(2026, 10, 21, 9, 30, 0, 0, time.Local)
	midnight := time.Date(2026, 10, 21, 0, 0, 0, 0, time.Local)
	sample := []string{sampleTrackChart, sampleArtistChart, sampleAlbumChart}
	methods := useRangeLastfm(t, func(from int64) []string {
		if from == midnight.AddDate(0, 0, -1).Unix() {
			return sample
		}
		return nil
	}, nil)
	res := computeDigestPreview(context.Background(), previewCfg, "daily", now)
	if !res.OK || res.Title != "🎧 昨日听歌报告（10-20）" || res.Digest == nil || res.Digest.TotalPlays != 8 || res.Digest.From != "2026-10-20" {
		t.Fatalf("%+v", res)
	}
	n := len(*methods)
	again := computeDigestPreview(context.Background(), previewCfg, "daily", now.Add(time.Minute))
	if len(*methods) != n+3 || again.Title != res.Title {
		// 今天那期没缓存(没听),重新问一遍 3 份榜单;昨天那期命中缓存,不再补「多三样」。
		t.Errorf("第二次应只重查今天那三份榜单: %d → %d", n, len(*methods))
	}
}

func TestDigestPreviewDailyToday(t *testing.T) {
	useDigestFeatures(t, featureFlags{DigestTopN: 3})
	clearDigestPreviewCache(t)
	now := time.Date(2026, 10, 21, 23, 5, 0, 0, time.Local)
	useRangeLastfm(t, func(int64) []string { return []string{sampleTrackChart, sampleArtistChart, sampleAlbumChart} }, nil)
	if res := computeDigestPreview(context.Background(), previewCfg, "daily", now); !res.OK || res.Title != "🎧 今日听歌报告（10-21）" {
		t.Fatalf("%+v", res)
	}
}

// 推送时间在中午以前(推前一天一整天):今天、昨天都听了,预览也先取昨天,跟真推送那一期一样。
func TestDigestPreviewDailyMorningPushShowsYesterday(t *testing.T) {
	useDigestFeatures(t, featureFlags{DigestTopN: 3, DigestPushTime: digestClock{minutes: 8 * 60, set: true}})
	clearDigestPreviewCache(t)
	now := time.Date(2026, 10, 21, 23, 5, 0, 0, time.Local)
	useRangeLastfm(t, func(int64) []string { return []string{sampleTrackChart, sampleArtistChart, sampleAlbumChart} }, nil)
	if res := computeDigestPreview(context.Background(), previewCfg, "daily", now); !res.OK || res.Title != "🎧 昨日听歌报告（10-20）" {
		t.Fatalf("%+v", res)
	}
}

// 周报预览:Last.fm 图表周列表里最后一个已经收官的那周。
func TestDigestPreviewWeeklyLastFinishedChartWeek(t *testing.T) {
	useDigestFeatures(t, featureFlags{DigestTopN: 3})
	clearDigestPreviewCache(t)
	sun := time.Date(2026, 10, 18, 20, 0, 0, 0, time.Local)
	now := sun.Add(3 * 24 * time.Hour)
	list := `{"weeklychartlist":{"chart":[{"from":"` + strconv.FormatInt(sun.AddDate(0, 0, -7).Unix(), 10) + `","to":"` + strconv.FormatInt(sun.Unix(), 10) +
		`"},{"from":"` + strconv.FormatInt(sun.Unix(), 10) + `","to":"` + strconv.FormatInt(sun.AddDate(0, 0, 7).Unix(), 10) + `"}]}}`
	useRangeLastfm(t, func(from int64) []string {
		if from == sun.AddDate(0, 0, -7).Unix() {
			return []string{sampleTrackChart, sampleArtistChart, sampleAlbumChart}
		}
		return nil
	}, map[string]string{"user.getWeeklyChartList": list})
	res := computeDigestPreview(context.Background(), previewCfg, "weekly", now)
	if !res.OK || res.Title != "🎵 上周听歌小结（10-11~10-18）" || res.Digest.Source != digestSourceLastfm {
		t.Fatalf("%+v", res)
	}
}

func TestDigestPreviewReasons(t *testing.T) {
	useDigestFeatures(t, featureFlags{DigestTopN: 3})
	clearDigestPreviewCache(t)
	now := time.Date(2026, 10, 21, 23, 5, 0, 0, time.Local)
	if res := computeDigestPreview(context.Background(), &config{}, "daily", now); res.OK || res.Reason != digestPreviewNoAccount {
		t.Errorf("没连账号: %+v", res)
	}
	useRangeLastfm(t, func(int64) []string { return nil }, nil)
	if res := computeDigestPreview(context.Background(), previewCfg, "daily", now); res.OK || res.Reason != digestPreviewEmpty {
		t.Errorf("今天昨天都没听: %+v", res)
	}
	useFakeLastfmRead(t, map[string]string{})
	if res := computeDigestPreview(context.Background(), previewCfg, "weekly", now); res.OK || res.Reason != digestPreviewFetch {
		t.Errorf("取数失败: %+v", res)
	}
}

func TestNotifyTestRequestCarriesPreview(t *testing.T) {
	req, ok := parseNotifyTestRequest([]byte(`{"id":"p1","preview":"weekly"}`))
	if !ok || req.Preview != "weekly" || req.ID != "p1" {
		t.Errorf("%+v %v", req, ok)
	}
}

// 结果文件的形状:共用样例 shared/testdata/notify/preview-result.json,App(Core NotificationPreview)读同一份。
func TestDigestPreviewResultSample(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "shared", "testdata", "notify", "preview-result.json"))
	if err != nil {
		t.Fatal(err)
	}
	var f digestPreviewResultFile
	if err := json.Unmarshal(raw, &f); err != nil || len(f.Results) == 0 {
		t.Fatalf("results=%d err=%v", len(f.Results), err)
	}
	back, _ := json.Marshal(f)
	var want, got any
	_ = json.Unmarshal(raw, &want)
	_ = json.Unmarshal(back, &got)
	if !reflect.DeepEqual(want, got) {
		t.Errorf("样例里有引擎不认或写不出来的字段:\n%s\nvs\n%s", raw, back)
	}
	d := f.Results[len(f.Results)-1].Digest // 最后一条是取到了的,前面那条是取不到时的样子
	if d == nil || d.CoverURL == "" || d.Link == "" || d.NewArtists == 0 || d.PrevPlays == 0 || len(d.TopAlbums) == 0 {
		t.Errorf("样例要把排版用到的字段都带上: %+v", d)
	}
	writeTo := filepath.Join(t.TempDir(), "preview-result.json")
	saved := notifyPreviewResultPath
	notifyPreviewResultPath = writeTo
	t.Cleanup(func() { notifyPreviewResultPath = saved })
	for i := 0; i < digestPreviewResultMax+2; i++ {
		writeDigestPreviewResult(digestPreviewResult{ID: strconv.Itoa(i), Kind: "daily"})
	}
	b, _ := os.ReadFile(writeTo)
	var kept digestPreviewResultFile
	_ = json.Unmarshal(b, &kept)
	if len(kept.Results) != digestPreviewResultMax || kept.Results[len(kept.Results)-1].ID != strconv.Itoa(digestPreviewResultMax+1) {
		t.Errorf("只留最近 %d 次: %+v", digestPreviewResultMax, kept.Results)
	}
}
