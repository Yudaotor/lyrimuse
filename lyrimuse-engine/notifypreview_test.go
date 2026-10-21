package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
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
		Albums         []notifyPreviewTally `json:"albums"`
		Tracks         []notifyPreviewTally `json:"tracks"`
		PrevPlays      int                  `json:"prev_plays"`
		PrevLabel      string               `json:"prev_label"`
		NewArtists     int                  `json:"new_artists"`
		NewArtistNames []string             `json:"new_artist_names"`
	} `json:"samples"`
	Bodies []struct {
		Kind string `json:"kind"`
		TopN int    `json:"top_n"`
		Body string `json:"body"`
	} `json:"bodies"`
	// Rich:按平台排版时的第一行、每类各行、新听的歌手那句(App 预览画排过版的样子用)。
	Rich []struct {
		Kind     string `json:"kind"`
		TopN     int    `json:"top_n"`
		Summary  string `json:"summary"`
		Sections []struct {
			Heading string   `json:"heading"`
			Lines   []string `json:"lines"`
		} `json:"sections"`
		NewLine string `json:"new_line"`
	} `json:"rich"`
	// WebhookWeekly:周报样例推到通用 Webhook 的那一行 JSON(含 data)。
	WebhookWeekly struct {
		From   string `json:"from"`
		To     string `json:"to"`
		SentAt string `json:"sent_at"`
		TopN   int    `json:"top_n"`
		JSON   string `json:"json"`
	} `json:"webhook_weekly"`
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
		TopArtists: clip(artists), TopAlbums: clip(albums), TopTracks: clip(tracks),
		PrevPlays: in.PrevPlays, PrevLabel: in.PrevLabel, NewArtists: in.NewArtists, NewArtistNames: in.NewArtistNames}
}

func TestNotifyPreviewSampleMatchesDigest(t *testing.T) {
	s := loadNotifyPreviewSample(t)
	now := time.Date(s.Now.Year, time.Month(s.Now.Month), s.Now.Day, s.Now.Hour, s.Now.Minute, 0, 0, time.Local)
	if _, _, _, title := dailyDigestTarget(now, defaultDigestPushMinutes); title != s.DailyTitle {
		t.Errorf("daily title = %q, want %q", title, s.DailyTitle)
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
	if len(s.Rich) == 0 {
		t.Fatal("样例里没有排版")
	}
	for _, r := range s.Rich {
		useDigestFeatures(t, featureFlags{DigestTopN: r.TopN})
		st := s.statsFor(r.Kind, r.TopN)
		if got := digestSummaryLine(st); got != r.Summary {
			t.Errorf("%s summary = %q, want %q", r.Kind, got, r.Summary)
		}
		if got := digestNewArtistsLine(st); got != r.NewLine {
			t.Errorf("%s new line = %q, want %q", r.Kind, got, r.NewLine)
		}
		secs := richSections(&st, func(v string) string { return v })
		if len(secs) != len(r.Sections) {
			t.Fatalf("%s sections = %d, want %d", r.Kind, len(secs), len(r.Sections))
		}
		for i, sec := range secs {
			if sec.heading != r.Sections[i].Heading || strings.Join(sec.lines, "\n") != strings.Join(r.Sections[i].Lines, "\n") {
				t.Errorf("%s section %d = %s %v, want %s %v", r.Kind, i, sec.heading, sec.lines, r.Sections[i].Heading, r.Sections[i].Lines)
			}
		}
	}
	w := s.WebhookWeekly
	useDigestFeatures(t, featureFlags{DigestTopN: w.TopN})
	st := s.statsFor("weekly", w.TopN)
	st.Source, st.From, st.To = digestSourceLastfm, w.From, w.To
	b, err := json.Marshal(webhookPayload{App: "lyrimuse", Event: notifyEventWeekly, Title: s.WeeklyTitle, Body: digestBody(st),
		SentAt: w.SentAt, Data: webhookDigest(&st)})
	if err != nil || string(b) != w.JSON {
		t.Errorf("webhook =\n%s\nwant\n%s", b, w.JSON)
	}
}
