package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// notifyPreviewSample 是 shared/testdata/notify/preview.json:App 渠道编辑弹窗「预览」用的那份假数据和它该拼出来的标题、正文。
// App 那边(Core NotificationPreview)照同一份样例拼,这里确认引擎真推出去的也是这几个字。
type notifyPreviewSample struct {
	Now struct {
		Year, Month, Day, Hour, Minute int
	} `json:"now"`
	DailyTitle  string `json:"daily_title"`
	WeeklyTitle string `json:"weekly_title"`
	Samples     map[string]struct {
		TotalPlays      int   `json:"total_plays"`
		TotalDurationMs int64 `json:"total_duration_ms"`
		Artists         []struct {
			Name  string `json:"name"`
			Count int    `json:"count"`
		} `json:"artists"`
		Albums []notifyPreviewTally `json:"albums"`
		Tracks []notifyPreviewTally `json:"tracks"`
	} `json:"samples"`
	Bodies []struct {
		Kind string `json:"kind"`
		TopN int    `json:"top_n"`
		Body string `json:"body"`
	} `json:"bodies"`
}

type notifyPreviewTally struct {
	Name  string `json:"name"`
	Sub   string `json:"sub"`
	Count int    `json:"count"`
}

func loadNotifyPreviewSample(t *testing.T) notifyPreviewSample {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "shared", "testdata", "notify", "preview.json"))
	if err != nil {
		t.Fatal(err)
	}
	var s notifyPreviewSample
	if err := json.Unmarshal(raw, &s); err != nil {
		t.Fatal(err)
	}
	return s
}

// statsFor 把样例的一种(daily / weekly)换成 digestStats,每类截到前 topN 条(同 topTallies)。
func (s notifyPreviewSample) statsFor(kind string, topN int) digestStats {
	in := s.Samples[kind]
	clip := func(ts []digestTally) []digestTally {
		if len(ts) > topN {
			return ts[:topN]
		}
		return ts
	}
	var artists, albums, tracks []digestTally
	for _, a := range in.Artists {
		artists = append(artists, digestTally{Name: a.Name, Count: a.Count})
	}
	for _, a := range in.Albums {
		albums = append(albums, digestTally{Name: a.Name, Sub: a.Sub, Count: a.Count})
	}
	for _, a := range in.Tracks {
		tracks = append(tracks, digestTally{Name: a.Name, Sub: a.Sub, Count: a.Count})
	}
	return digestStats{TotalPlays: in.TotalPlays, TotalDurationMs: in.TotalDurationMs,
		TopArtists: clip(artists), TopAlbums: clip(albums), TopTracks: clip(tracks)}
}

func TestNotifyPreviewSampleMatchesDigest(t *testing.T) {
	s := loadNotifyPreviewSample(t)
	now := time.Date(s.Now.Year, time.Month(s.Now.Month), s.Now.Day, s.Now.Hour, s.Now.Minute, 0, 0, time.Local)
	if _, _, _, title, ok := dailyDigestTarget(now, notifyQuietHours{}); !ok || title != s.DailyTitle {
		t.Errorf("daily title = %q, ok=%v, want %q", title, ok, s.DailyTitle)
	}
	// 样例的 now 是周二;上周 = 前一个周一 00:00 到本周一 00:00(ListenBrainz 源的开区间)。
	monday := time.Date(now.Year(), now.Month(), now.Day()-int((now.Weekday()+6)%7), 0, 0, 0, 0, time.Local)
	if got := weeklyDigestTitle(digestSourceListenBrainz, monday.AddDate(0, 0, -7).Unix(), monday.Unix()); got != s.WeeklyTitle {
		t.Errorf("weekly title = %q, want %q", got, s.WeeklyTitle)
	}
	if len(s.Bodies) == 0 {
		t.Fatal("样例里没有正文")
	}
	for _, b := range s.Bodies {
		useDigestFeatures(t, featureFlags{DigestTopN: b.TopN})
		if got := digestBody(s.statsFor(b.Kind, b.TopN)); got != b.Body {
			t.Errorf("%s top %d body =\n%s\nwant\n%s", b.Kind, b.TopN, got, b.Body)
		}
	}
}
