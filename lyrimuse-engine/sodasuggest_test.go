package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"testing"
)

func TestSodaDecodeSearchRecognizesShapes(t *testing.T) {
	for name, tc := range map[string]struct {
		raw string
		ok  bool
	}{
		"空应答体":             {"", false},
		"不是 JSON":          {"<html>", false},
		"没有 result_groups": {`{"status_info":{},"extra":{"empty_search":1}}`, false},
		"result_groups 为空": {`{"result_groups":null}`, false},
		"没搜到":              {`{"result_groups":[]}`, true},
		"有结果":              {`{"result_groups":[{"id":"tracks","data":[{"entity":{"track":{"id":"1","name":"a"}}}]}]}`, true},
	} {
		if _, ok := sodaDecodeSearch([]byte(tc.raw)); ok != tc.ok {
			t.Errorf("%s: ok=%v, want %v", name, ok, tc.ok)
		}
	}
}

func TestSodaParseSuggest(t *testing.T) {
	raw := `{"status_info":{"log_id":"x"},"sugs":[
		{"suggestion":"十年(陈奕迅)","content_type":"track","entity":{"track":{"id":"11"}}},
		{"suggestion":"陈奕迅","content_type":"artist","entity":{"artist":{"id":"12"}}},
		{"suggestion":"没有 id","content_type":"track","entity":{"track":{"id":" "}}},
		{"suggestion":"不是曲目","content_type":"album","entity":{"track":{"id":"14"}}},
		{"suggestion":"陈奕迅 十年 - Live","content_type":"track","entity":{"track":{"id":"13"}}}]}`
	got, ok := sodaParseSuggest([]byte(raw))
	want := []sodaSuggestion{{"11", "十年(陈奕迅)"}, {"13", "陈奕迅 十年 - Live"}}
	if !ok || !slices.Equal(got, want) {
		t.Errorf("got %v ok=%v, want %v", got, ok, want)
	}
	// 没有联想时只带 status_info:答了、没有。
	if got, ok := sodaParseSuggest([]byte(`{"status_info":{"log_id":"x"}}`)); !ok || len(got) != 0 {
		t.Errorf("只有 status_info 该算答了没有, got %v ok=%v", got, ok)
	}
	for _, bad := range []string{"", "<html>", `{}`, `{"status_info":null}`} {
		if _, ok := sodaParseSuggest([]byte(bad)); ok {
			t.Errorf("%q 不该认得", bad)
		}
	}
}

func TestSodaSuggestQueries(t *testing.T) {
	for _, tc := range []struct {
		artist, title string
		want          []string
	}{
		{"陈奕迅", "十年", []string{"十年 陈奕迅", "十年"}},
		{"陈奕迅", "十年 - Live", []string{"十年 (Live) 陈奕迅", "十年 陈奕迅", "十年"}},
		{"方大同, 徐佳莹", "自以为 (feat. 徐佳莹)", []string{"自以为 (feat. 徐佳莹) 方大同", "自以为 方大同", "自以为"}},
		{"", "Lemon", []string{"Lemon"}},
		{"Michael Jackson", "Buttercup ft. The Notorious B.I.G. (Remix)", []string{"Buttercup ft. The Notorious B.I.G. (Remix) Michael Jackson", "Buttercup ft. The Notorious B.I.G. Michael Jackson", "Buttercup ft. The Notorious B.I.G."}},
	} {
		if got := sodaSuggestQueries(tc.artist, tc.title); !slices.Equal(got, tc.want) {
			t.Errorf("%q - %q: got %q, want %q", tc.artist, tc.title, got, tc.want)
		}
	}
}

func TestSodaSuggestCandidates(t *testing.T) {
	sugs := []sodaSuggestion{
		{"1", "Love Story Indila"},
		{"2", "Love Story - Taylor Swift"},
		{"3", "Dress Taylor Swift"},
		{"4", "Love Story(伴奏)"},
		{"5", "Love Story (Taylor Swift)"},
		{"2", "Love Story - Taylor Swift"},
	}
	got := sodaSuggestCandidates(sugs, "Taylor Swift", "Love Story (Taylor's Version)", map[string]bool{"5": true}, 3)
	// 提示里没有歌名的不问;含歌手的排前面;问过的跳过;重复的只算一次;最多 limit 条。
	if want := []string{"2", "1", "4"}; !slices.Equal(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
	if got := sodaSuggestCandidates(sugs, "Taylor Swift", "Love Story", nil, 1); !slices.Equal(got, []string{"2"}) {
		t.Errorf("limit 1: got %v", got)
	}
}

func TestSodaSuggestFound(t *testing.T) {
	items := []sodaSearchItem{{Name: "十年 (Live)", Artist: "陈奕迅"}}
	if sodaSuggestFound(items, "陈奕迅", "十年") {
		t.Error("要的是录音室版,只问到现场版不算找到")
	}
	if !sodaSuggestFound(append(items, sodaSearchItem{Name: "十年", Artist: "陈奕迅"}), "陈奕迅", "十年") {
		t.Error("歌名、歌手、版本都对得上算找到")
	}
	if sodaSuggestFound([]sodaSearchItem{{Name: "十年", Artist: "别人"}}, "陈奕迅", "十年") {
		t.Error("歌手对不上不算找到")
	}
}

func TestSodaSearchItemFromSeo(t *testing.T) {
	body := sodaTestResponse(sodaTestLyricContent)
	body.SeoTrack.Track.Name = "Sorry - Live"
	body.SeoTrack.Track.Preview.Start, body.SeoTrack.Track.Preview.Duration = 113088, 30000
	it, ok := sodaSearchItemFromSeo(body, "6705555863068739585")
	want := sodaSearchItem{ID: "6705555863068739585", Name: "Sorry (Live)", Artist: "方大同", Album: "未来", Duration: 222.653,
		PreviewStartMs: 113088, PreviewDurationMs: 30000}
	if !ok || it != want {
		t.Errorf("got %+v ok=%v", it, ok)
	}
	if _, ok := sodaSearchItemFromSeo(body, "other"); ok {
		t.Error("不是这个 id 的应答不认")
	}
}

// sodaSuggestFake:整页搜索按 searchBody 答,联想按 sugBody 答,seo_track 按 id 给 seoByID 里的应答。
func sodaSuggestFake(t *testing.T, searchStatus int, searchBody, sugBody string, seoByID map[string]sodaSeoTrackResponse) *kgFake {
	t.Helper()
	savedSearch, savedLyrics, savedMeta := sodaSearchCache, sodaCache, sodaSuggestMeta
	sodaSearchCache, sodaCache, sodaSuggestMeta = map[string]sodaSearchCacheEntry{}, map[string]sodaResult{}, map[string]sodaSearchItem{}
	savedDrift := parserDrift
	parserDrift = map[string]*parserDriftEntry{}
	t.Cleanup(func() {
		sodaSearchCache, sodaCache, sodaSuggestMeta = savedSearch, savedLyrics, savedMeta
		parserDrift = savedDrift
	})
	return withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
		switch {
		case strings.HasSuffix(target, sodaSearchPath):
			return searchStatus, searchBody
		case strings.HasSuffix(target, sodaSuggestPath):
			return http.StatusOK, sugBody
		case strings.HasSuffix(target, sodaSeoTrackPath):
			resp, ok := seoByID[r.URL.Query().Get("track_id")]
			if !ok {
				return http.StatusBadGateway, ""
			}
			b, _ := json.Marshal(resp)
			return http.StatusOK, string(b)
		}
		return http.StatusNotFound, ""
	})
}

func sodaTestSeoFor(id, name, artist string, durationMs int64, content string) sodaSeoTrackResponse {
	r := sodaTestResponse(content)
	r.SeoTrack.Track.ID, r.SeoTrack.Track.Name, r.SeoTrack.Track.Duration = id, name, durationMs
	r.SeoTrack.Track.Artists[0].Name = artist
	return r
}

const sodaTestSugSorry = `{"status_info":{},"sugs":[
	{"suggestion":"Sorry Justin Bieber","content_type":"track","entity":{"track":{"id":"81"}}},
	{"suggestion":"Sorry 方大同","content_type":"track","entity":{"track":{"id":"82"}}},
	{"suggestion":"方大同","content_type":"artist","entity":{"artist":{"id":"83"}}}]}`

// 整页搜索回 200 + 空应答体:改问联想,问到的那条取得到词;取词不再问一遍 seo_track;整页搜索记一次认不出。
func TestSodaSearchFallsBackToSuggestWhenSearchRefused(t *testing.T) {
	f := sodaSuggestFake(t, http.StatusOK, "", sodaTestSugSorry, map[string]sodaSeoTrackResponse{
		"81": sodaTestSeoFor("81", "Sorry", "Justin Bieber", 200000, sodaTestLyricContent),
		"82": sodaTestSeoFor("82", "Sorry", "方大同", 222653, sodaTestLyricContent),
	})
	r, _ := sodaLyricBySearch(qqRoundCtx(), "方大同", "Sorry", "未来", 222.6)
	if r.empty() || r.artist != "方大同" {
		t.Fatalf("该从联想找到方大同那条并取到词, got %+v", r)
	}
	seo := "https://" + sodaSeoTrackHost + sodaSeoTrackPath
	if n := f.count(seo); n != 2 {
		t.Errorf("两条候选各问一次 seo_track、取词不再问, 实际 %d 次", n)
	}
	if n := f.count("https://" + sodaSearchHost + sodaSuggestPath); n != 1 {
		t.Errorf("第一个联想词就找到了,不该再换词, 实际问了 %d 次", n)
	}
	if e := parserDrift[sodaSearchParserName]; e == nil || e.Detail != "200 with an empty body" {
		t.Errorf("整页搜索的空应答该记进解析漂移, got %+v", e)
	}
	if e := parserDrift[sodaSuggestParserName]; e != nil {
		t.Errorf("联想认得出,不该记, got %+v", e)
	}
	sodaSearchMu.Lock()
	cached := len(sodaSearchCache)
	sodaSearchMu.Unlock()
	if cached != 1 {
		t.Errorf("完整的联想结果照常缓存, 缓存了 %d 条", cached)
	}
}

// 整页搜索给了曲目就不问联想。
func TestSodaSearchSkipsSuggestWhenSearchAnswers(t *testing.T) {
	f := sodaSuggestFake(t, http.StatusOK,
		`{"result_groups":[{"id":"tracks","data":[{"entity":{"track":{"id":"82","name":"Sorry","artists":[{"name":"方大同"}],"duration":222653}}}]}]}`,
		sodaTestSugSorry, nil)
	items, err := sodaSearch(qqRoundCtx(), "方大同", "Sorry")
	if err != nil || len(items) != 1 {
		t.Fatalf("got %v err=%v", items, err)
	}
	if n := f.count("https://" + sodaSearchHost + sodaSuggestPath); n != 0 {
		t.Errorf("整页搜索答了就不问联想, 实际 %d 次", n)
	}
}

// 整页搜索连着被拒,接口熔断跳闸:之后的搜索不再发到这个端点,直接走联想。
func TestSodaSearchRefusalTripsEndpointBreaker(t *testing.T) {
	f := sodaSuggestFake(t, http.StatusOK, "", `{"status_info":{}}`, nil)
	full := "https://" + sodaSearchHost + sodaSearchPath
	for i := range endpointTripAfter + 2 {
		_, err := sodaSearchAt(qqRoundCtx(), sodaSearchHost, "x")
		if i < endpointTripAfter && !errors.Is(err, errSodaSearchRefused) {
			t.Fatalf("第 %d 次该是被拒, got %v", i+1, err)
		}
		if i >= endpointTripAfter && !errors.Is(err, errHostGuarded) {
			t.Fatalf("跳闸后第 %d 次该被本地拦下, got %v", i+1, err)
		}
	}
	if n := f.count(full); n != endpointTripAfter {
		t.Errorf("跳闸后不该再发出去, 实际发了 %d 次", n)
	}
}

// 联想连着回认不出的应答,同样跳闸。
func TestSodaSuggestRefusalTripsEndpointBreaker(t *testing.T) {
	f := sodaSuggestFake(t, http.StatusOK, "", "", nil)
	for i := range endpointTripAfter + 1 {
		_, err := sodaSuggestAt(qqRoundCtx(), sodaSearchHost, "x")
		if i < endpointTripAfter && !errors.Is(err, errSodaSearchRefused) {
			t.Fatalf("第 %d 次该是被拒, got %v", i+1, err)
		}
		if i >= endpointTripAfter && !errors.Is(err, errHostGuarded) {
			t.Fatalf("跳闸后该被本地拦下, got %v", err)
		}
	}
	if n := f.count("https://" + sodaSearchHost + sodaSuggestPath); n != endpointTripAfter {
		t.Errorf("跳闸后不该再发出去, 实际发了 %d 次", n)
	}
}

// 联想的候选有一条 seo_track 没问成:手上的照用,搜索结果不缓存。
func TestSodaSuggestPartialLookupNotCached(t *testing.T) {
	sodaSuggestFake(t, http.StatusOK, "", sodaTestSugSorry, map[string]sodaSeoTrackResponse{
		"82": sodaTestSeoFor("82", "Sorry", "方大同", 222653, sodaTestLyricContent),
	})
	items, _, err := sodaSearchVia(qqRoundCtx(), sodaSearchHosts, "方大同", "Sorry")
	if err == nil || len(items) != 1 || items[0].ID != "82" {
		t.Fatalf("该交回问到的那条并带错误, got %v err=%v", items, err)
	}
	ctx, sub := withLyricSubFetch(qqRoundCtx())
	if r, _, _ := sodaLyricFromHosts(ctx, sodaSearchHosts, "方大同", "Sorry", "未来", 222.6); r.empty() {
		t.Error("部分结果里那条对得上,照样取到词")
	}
	sodaSearchMu.Lock()
	cached := len(sodaSearchCache)
	sodaSearchMu.Unlock()
	if cached != 0 || sub.complete(ctx) {
		t.Errorf("部分结果不缓存、这一轮记成不完整, 缓存 %d 条, complete=%v", cached, sub.complete(ctx))
	}
}

// 整页搜索和联想都认不出:搜索失败、什么都不缓存,两条都记进解析漂移。
func TestSodaSearchBothLegsRefused(t *testing.T) {
	sodaSuggestFake(t, http.StatusOK, "", "", nil)
	if items, _, err := sodaSearchVia(qqRoundCtx(), sodaSearchHosts, "方大同", "Sorry"); err == nil || len(items) != 0 {
		t.Fatalf("两条腿都被拒该报错, got %v err=%v", items, err)
	}
	if parserDrift[sodaSearchParserName] == nil || parserDrift[sodaSuggestParserName] == nil {
		t.Error("两条都该记进解析漂移")
	}
}

func TestSodaSearchHealthItem(t *testing.T) {
	bad := parserDriftEntry{Streak: 7, FirstAt: 1794800000, Detail: "200 with an empty body"}
	if _, ok := sodaSearchHealthItem(map[string]parserDriftEntry{sodaSearchParserName: bad}, false); ok {
		t.Error("汽水没启用不出这一行")
	}
	for name, tc := range map[string]struct {
		drift  map[string]parserDriftEntry
		status healthStatus
		has    string
	}{
		"都好":     {nil, healthOK, "没有连续认不出"},
		"整页搜索被拒": {map[string]parserDriftEntry{sodaSearchParserName: bad}, healthOK, "已改用联想"},
		"联想被拒":   {map[string]parserDriftEntry{sodaSuggestParserName: bad}, healthWarn, "整页搜索还在用"},
		"两条都被拒":  {map[string]parserDriftEntry{sodaSearchParserName: bad, sodaSuggestParserName: bad}, healthWarn, "不可用"},
	} {
		it, ok := sodaSearchHealthItem(tc.drift, true)
		if !ok || it.Status != tc.status || !strings.Contains(it.Detail, tc.has) {
			t.Errorf("%s: got %+v", name, it)
		}
	}
}

// 换联想词也守着总上限:每个词给一批新的、都对不上的候选,问满 sodaSuggestMaxLookupsTotal 条就不再换词。
func TestSodaSuggestLookupBudget(t *testing.T) {
	sodaSuggestFake(t, http.StatusOK, "", "", nil)
	f := withKugouFakeReq(t, func(r *http.Request, target string) (int, string) {
		switch {
		case strings.HasSuffix(target, sodaSearchPath):
			return http.StatusOK, ""
		case strings.HasSuffix(target, sodaSuggestPath):
			q := r.URL.Query().Get("q")
			var sugs []string
			for i := range 6 {
				sugs = append(sugs, fmt.Sprintf(`{"suggestion":"十年 %d","content_type":"track","entity":{"track":{"id":"%d%d"}}}`, i, len(q), i))
			}
			return http.StatusOK, `{"status_info":{},"sugs":[` + strings.Join(sugs, ",") + `]}`
		case strings.HasSuffix(target, sodaSeoTrackPath):
			id := r.URL.Query().Get("track_id")
			b, _ := json.Marshal(sodaTestSeoFor(id, "十年", "别人", 200000, sodaTestLyricContent))
			return http.StatusOK, string(b)
		}
		return http.StatusNotFound, ""
	})
	if len(sodaSuggestQueries("陈奕迅", "十年 - Live")) != 3 {
		t.Fatal("这首要有三个联想词,用例才测得到上限")
	}
	items, _, err := sodaSearchVia(qqRoundCtx(), sodaSearchHosts, "陈奕迅", "十年 - Live")
	if err != nil {
		t.Fatal(err)
	}
	seo := f.count("https://"+sodaSeoTrackHost+sodaSeoTrackPath) + f.count("https://"+sodaSearchHost+sodaSeoTrackPath)
	if len(items) != sodaSuggestMaxLookupsTotal || seo != sodaSuggestMaxLookupsTotal {
		t.Errorf("问满 %d 条就停, 实际 %d 条候选、%d 次 seo_track", sodaSuggestMaxLookupsTotal, len(items), seo)
	}
	if n := f.count("https://" + sodaSearchHost + sodaSuggestPath); n != 2 {
		t.Errorf("额度用完不再发第三个联想词, 实际 %d 次", n)
	}
}
