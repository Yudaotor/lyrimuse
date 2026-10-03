package main

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"
)

func resetArtistRegionsCache() {
	artistRegionsMu.Lock()
	artistRegionsPath = ""
	artistRegionsCache = artistRegionsFile{Artists: map[string]artistRegionEntry{}, Periods: map[string]artistRegionsPeriod{}}
	artistRegionsMu.Unlock()
}

// fakeRegionsSource:每个时段返回同一份榜单,归并一条一行、mbid 取条目自带的;国家按表查,记下查了谁。
func fakeRegionsSource(chart []lastfmChartEntry, countries map[string]string, asked *[]string) artistRegionsSource {
	return artistRegionsSource{
		topArtists: func(ctx context.Context, period string) ([]lastfmChartEntry, error) { return chart, nil },
		merge: func(entries []lastfmChartEntry) ([]mergedArtist, []mbArtistIdentity) {
			out := make([]mergedArtist, len(entries))
			ids := make([]mbArtistIdentity, len(entries))
			for i, e := range entries {
				out[i] = mergedArtist{lastfmChartEntry: e, members: []int{i}}
			}
			return out, ids
		},
		country: func(ctx context.Context, mbid string) (string, int, error) {
			*asked = append(*asked, mbid)
			return countries[mbid], 1, nil
		},
	}
}

func TestSummarizeArtistRegions(t *testing.T) {
	merged := []mergedArtist{
		{lastfmChartEntry: lastfmChartEntry{Name: "Prince", PlayCount: 50}},
		{lastfmChartEntry: lastfmChartEntry{Name: "陶喆", PlayCount: 40}},
		{lastfmChartEntry: lastfmChartEntry{Name: "Michael Jackson", PlayCount: 30}},
		{lastfmChartEntry: lastfmChartEntry{Name: "VALORANT", PlayCount: 20}},
		{lastfmChartEntry: lastfmChartEntry{Name: "Musiq", PlayCount: 10}},
		{lastfmChartEntry: lastfmChartEntry{Name: "Nobody", PlayCount: 5}},
		{lastfmChartEntry: lastfmChartEntry{Name: "Stevie", PlayCount: 4}},
	}
	merged = append(merged, mergedArtist{lastfmChartEntry: lastfmChartEntry{Name: "林宥嘉", PlayCount: 3}})
	mbids := []string{"p", "t", "m", "v", "q", "", "s", "y"}
	known := map[string]artistRegionEntry{"p": {Country: "US"}, "t": {Country: "TW"}, "m": {Country: "US"}, "v": {}, "q": {Country: "US"}, "s": {Country: "US"}}
	got := summarizeArtistRegions(merged, mbids, known)
	if got.TopArtists != artistRegionsTopArtists {
		t.Fatalf("top artists = %d: 统计了前多少位要写进汇总,App 照它写说明", got.TopArtists)
	}
	if got.Covered != 162 || got.Unresolved != 25 || got.Pending != 3 {
		t.Fatalf("covered/unresolved/pending = %d/%d/%d, want 162/25/3", got.Covered, got.Unresolved, got.Pending)
	}
	if !reflect.DeepEqual(got.UnresolvedArtists, []string{"VALORANT", "Nobody"}) {
		t.Fatalf("unresolved artists = %v: 没有 mbid 和查过没登记的算「未查到」", got.UnresolvedArtists)
	}
	if !reflect.DeepEqual(got.PendingArtists, []string{"林宥嘉"}) {
		t.Fatalf("pending artists = %v: 有 mbid 还没查的算「还在查」", got.PendingArtists)
	}
	want := []artistRegionsBucket{
		{Code: "US", Plays: 94, Artists: []string{"Prince", "Michael Jackson", "Musiq"}},
		{Code: "TW", Plays: 40, Artists: []string{"陶喆"}},
	}
	if !reflect.DeepEqual(got.Regions, want) {
		t.Fatalf("regions = %+v, want %+v (每个地区只列前 %d 位)", got.Regions, want, artistRegionsNamesPerRegion)
	}
}

func TestWarmArtistRegionsBudgetAndResume(t *testing.T) {
	resetArtistRegionsCache()
	defer resetArtistRegionsCache()
	chart := []lastfmChartEntry{
		{Name: "A", PlayCount: 30, Mbid: "a"},
		{Name: "B", PlayCount: 20, Mbid: "b"},
		{Name: "C", PlayCount: 10, Mbid: "c"},
	}
	var asked []string
	src := fakeRegionsSource(chart, map[string]string{"a": "US", "b": "TW", "c": "HK"}, &asked)
	now := time.Unix(1_800_000_000, 0)

	if !warmArtistRegions(context.Background(), now, "u", 2, src) {
		t.Fatal("first run should run")
	}
	if !reflect.DeepEqual(asked, []string{"a", "b"}) {
		t.Fatalf("asked = %v, want the two most played first", asked)
	}
	if got := artistRegionsCache.NextAt; got != now.Add(artistRegionsQuickRetry).Unix() {
		t.Fatalf("budget ran out without errors: next_at = %d, want the quick retry", got)
	}
	if p := artistRegionsCache.Periods["1month"]; p.Pending != 10 || p.Unresolved != 0 || len(p.Regions) != 2 {
		t.Fatalf("partial summary = %+v, want C still pending", p)
	}

	if warmArtistRegions(context.Background(), now.Add(2*time.Minute), "u", 60, src) {
		t.Fatal("should wait until next_at")
	}

	asked = nil
	later := now.Add(artistRegionsQuickRetry + time.Minute)
	if !warmArtistRegions(context.Background(), later, "u", 60, src) {
		t.Fatal("second run should run")
	}
	if !reflect.DeepEqual(asked, []string{"c"}) {
		t.Fatalf("asked = %v, want only the one not looked up yet", asked)
	}
	if got := artistRegionsCache.NextAt; got != later.Add(artistRegionsCheckInterval).Unix() {
		t.Fatalf("all looked up: next_at = %d, want the full interval", got)
	}
	if p := artistRegionsCache.Periods["overall"]; p.Unresolved != 0 || len(p.Regions) != 3 {
		t.Fatalf("summary = %+v, want every artist resolved", p)
	}
}

func TestWarmArtistRegionsRetriesEmptyCountryAfterAMonth(t *testing.T) {
	resetArtistRegionsCache()
	defer resetArtistRegionsCache()
	chart := []lastfmChartEntry{{Name: "VALORANT", PlayCount: 5, Mbid: "v"}}
	var asked []string
	src := fakeRegionsSource(chart, map[string]string{}, &asked)
	now := time.Unix(1_800_000_000, 0)
	warmArtistRegions(context.Background(), now, "u", 60, src)
	artistRegionsCache.NextAt = 0
	warmArtistRegions(context.Background(), now.Add(24*time.Hour), "u", 60, src)
	if len(asked) != 1 {
		t.Fatalf("asked %v: an empty answer should not be asked again within %v", asked, artistRegionsRetryAfter)
	}
	artistRegionsCache.NextAt = 0
	warmArtistRegions(context.Background(), now.Add(artistRegionsRetryAfter+time.Hour), "u", 60, src)
	if len(asked) != 2 {
		t.Fatalf("asked %v: should ask again after %v", asked, artistRegionsRetryAfter)
	}
}

func TestWarmArtistRegionsKeepsOldResultWhenAPeriodFails(t *testing.T) {
	resetArtistRegionsCache()
	defer resetArtistRegionsCache()
	old := artistRegionsPeriod{Covered: 7, Regions: []artistRegionsBucket{{Code: "JP", Plays: 7}}}
	artistRegionsCache.User = "u"
	artistRegionsCache.Periods["1month"] = old
	var asked []string
	src := fakeRegionsSource(nil, nil, &asked)
	src.topArtists = func(ctx context.Context, period string) ([]lastfmChartEntry, error) {
		if period == "12month" {
			return nil, errors.New("timeout")
		}
		return []lastfmChartEntry{{Name: "A", PlayCount: 1, Mbid: "a"}}, nil
	}
	if warmArtistRegions(context.Background(), time.Unix(1_800_000_000, 0), "u", 60, src) {
		t.Fatal("a failed period should abort the run")
	}
	if !reflect.DeepEqual(artistRegionsCache.Periods["1month"], old) {
		t.Fatalf("summary changed after a failed run: %+v", artistRegionsCache.Periods)
	}
	if got, want := artistRegionsCache.NextAt, time.Unix(1_800_000_000, 0).Add(artistRegionsPartialRetry).Unix(); got != want {
		t.Fatalf("next_at = %d, want %d: a failed fetch must back off, not retry on every 5 s tick", got, want)
	}
}

func TestWarmArtistRegionsStopsAfterConsecutiveFailures(t *testing.T) {
	resetArtistRegionsCache()
	defer resetArtistRegionsCache()
	chart := []lastfmChartEntry{{Name: "A", PlayCount: 5, Mbid: "a"}, {Name: "B", PlayCount: 4, Mbid: "b"},
		{Name: "C", PlayCount: 3, Mbid: "c"}, {Name: "D", PlayCount: 2, Mbid: "d"}, {Name: "E", PlayCount: 1, Mbid: "e"}}
	var asked []string
	src := fakeRegionsSource(chart, nil, &asked)
	src.country = func(ctx context.Context, mbid string) (string, int, error) {
		asked = append(asked, mbid)
		return "", 1, errors.New("timeout")
	}
	now := time.Unix(1_800_000_000, 0)
	if !warmArtistRegions(context.Background(), now, "u", 60, src) {
		t.Fatal("the summary should still be written")
	}
	if len(asked) != artistRegionsMaxConsecutiveFailures {
		t.Fatalf("asked %v: should stop after %d failures in a row", asked, artistRegionsMaxConsecutiveFailures)
	}
	if got := artistRegionsCache.NextAt; got != now.Add(artistRegionsPartialRetry).Unix() {
		t.Fatalf("next_at = %d, want a partial retry", got)
	}
	if len(artistRegionsCache.Artists) != 0 {
		t.Fatalf("a failed lookup must not be recorded as a conclusion: %+v", artistRegionsCache.Artists)
	}
}

func TestMergedArtistMbid(t *testing.T) {
	entries := []lastfmChartEntry{
		{Name: "Prince & The Revolution", Mbid: "joint"},
		{Name: "Prince", Mbid: "prince"},
	}
	m := mergedArtist{members: []int{0, 1}}
	if got := mergedArtistMbid(m, entries, make([]mbArtistIdentity, 2)); got != "prince" {
		t.Fatalf("got %q: a joint credit's own mbid must not stand for the artist", got)
	}
	ids := []mbArtistIdentity{{Mbid: "resolved"}, {}}
	if got := mergedArtistMbid(m, entries, ids); got != "resolved" {
		t.Fatalf("got %q: the resolved identity comes first", got)
	}
	if got := mergedArtistMbid(mergedArtist{members: []int{0}}, entries, make([]mbArtistIdentity, 2)); got != "" {
		t.Fatalf("got %q: only a joint credit → no mbid", got)
	}
}

func TestWarmArtistRegionsDropsAnotherAccountsSummary(t *testing.T) {
	resetArtistRegionsCache()
	defer resetArtistRegionsCache()
	now := time.Unix(1_800_000_000, 0)
	artistRegionsCache.User = "old"
	artistRegionsCache.NextAt = now.Add(time.Hour).Unix()
	artistRegionsCache.Periods["1month"] = artistRegionsPeriod{Covered: 9, Regions: []artistRegionsBucket{{Code: "JP", Plays: 9}}}
	artistRegionsCache.Artists["a"] = artistRegionEntry{Country: "US", Checked: now.Unix()}
	var asked []string
	src := fakeRegionsSource([]lastfmChartEntry{{Name: "A", PlayCount: 3, Mbid: "a"}}, nil, &asked)
	if !warmArtistRegions(context.Background(), now, "new", 60, src) {
		t.Fatal("a new account must not wait for the old next_at")
	}
	if len(asked) != 0 {
		t.Fatalf("asked %v: mbid → country is account independent and stays cached", asked)
	}
	got := artistRegionsCache.Periods["1month"]
	if artistRegionsCache.User != "new" || got.Covered != 3 || len(got.Regions) != 1 || got.Regions[0].Code != "US" {
		t.Fatalf("summary not rebuilt for the new account: %+v", artistRegionsCache)
	}
}
