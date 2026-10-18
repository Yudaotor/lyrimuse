package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// withParserDrift:换一份空的漂移计数(不落盘),测试结束还原。
func withParserDrift(t *testing.T) {
	t.Helper()
	parserDriftMu.Lock()
	oldPath, oldMap := parserDriftPath, parserDrift
	parserDriftPath, parserDrift = "", map[string]*parserDriftEntry{}
	parserDriftMu.Unlock()
	t.Cleanup(func() {
		parserDriftMu.Lock()
		parserDriftPath, parserDrift = oldPath, oldMap
		parserDriftMu.Unlock()
	})
}

func driftStreak(name string) int {
	parserDriftMu.Lock()
	defer parserDriftMu.Unlock()
	if e := parserDrift[name]; e != nil {
		return e.Streak
	}
	return 0
}

// Google 翻译:200 却不是认得的嵌套数组记一次认不出,认得出就清零。
func TestGoogleTranslateShapeDrift(t *testing.T) {
	withParserDrift(t)
	shape := `{"oops":1}`
	useFakeGoogle(t, func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(shape)) })
	if _, err := googleTranslateLines(context.Background(), http.DefaultClient, []string{"こんにちは"}, "zh"); err == nil {
		t.Fatal("形状不对应当报错")
	}
	if driftStreak(googleTranslateParserName) != 1 {
		t.Fatalf("记一次认不出,got %d", driftStreak(googleTranslateParserName))
	}
	shape = `[[["你好","こんにちは",null,null,10]],null,"ja"]`
	googleTranslateMu.Lock()
	googleTranslateCoolUntil = time.Time{} // 上一次报错进了冷却
	googleTranslateMu.Unlock()
	if got, err := googleTranslateLines(context.Background(), http.DefaultClient, []string{"こんにちは"}, "zh"); err != nil || len(got) != 1 || got[0] != "你好" {
		t.Fatalf("认得出的照常翻: %v %v", got, err)
	}
	if driftStreak(googleTranslateParserName) != 0 {
		t.Error("认得出一次就清零")
	}
}

// iTunes Search:200 却没有 results 记一次认不出(不是「Apple 没有」);形状对、零条结果照常。
func TestITunesSearchShapeDrift(t *testing.T) {
	withParserDrift(t)
	body := `{"resultCount":0}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(body)) }))
	t.Cleanup(srv.Close)
	saved := itunesSearchBaseURL
	itunesSearchBaseURL = srv.URL
	t.Cleanup(func() { itunesSearchBaseURL = saved })

	if _, ok := itunesSearch(context.Background(), "x", "us"); ok {
		t.Error("形状不对不算问成")
	}
	if driftStreak(itunesSearchParserName) != 1 {
		t.Fatalf("记一次认不出,got %d", driftStreak(itunesSearchParserName))
	}
	body = `{"resultCount":0,"results":[]}`
	if res, ok := itunesSearch(context.Background(), "x", "us"); !ok || len(res) != 0 {
		t.Errorf("零条结果照常问成: %v %v", res, ok)
	}
	if driftStreak(itunesSearchParserName) != 0 {
		t.Error("认得出一次就清零")
	}
}

// MusicBrainz:搜索应答必有 artists、详情必有 id;缺了说缺什么。
func TestMBResponseShapeProblem(t *testing.T) {
	search := "https://musicbrainz.org/ws/2/artist/?query=x&fmt=json&limit=5"
	detail := "https://musicbrainz.org/ws/2/artist/abc?inc=aliases&fmt=json"
	for _, c := range []struct {
		url, body, want string
	}{
		{search, `{"count":0,"artists":[]}`, ""},
		{search, `{"count":0,"artist-list":[]}`, "response has no artists"},
		{detail, `{"id":"abc","name":"x"}`, ""},
		{detail, `{"mbid":"abc"}`, "response has no id"},
		{detail, `[1]`, "response is not a JSON object"},
	} {
		if got := mbResponseShapeProblem(c.url, []byte(c.body)); got != c.want {
			t.Errorf("%s %s: got %q want %q", c.url, c.body, got, c.want)
		}
	}
}

// amll:索引里登记了的 ID 取回来 404、或取回的 TTML 解不开记认不出;不在索引里的 404、没问成都不算;取成解开就清零。
func TestAMLLFetchShapeDrift(t *testing.T) {
	withParserDrift(t)
	noteAMLLFetchShape("qq-lyrics", "1", false, false, true, false) // 不在索引里的 404
	noteAMLLFetchShape("qq-lyrics", "2", true, false, false, false) // 没问成
	if driftStreak(amllLayoutParserName) != 0 {
		t.Fatal("这两种不说明上游变了")
	}
	noteAMLLFetchShape("qq-lyrics", "3", true, false, true, false) // 索引里有、答 404
	noteAMLLFetchShape("qq-lyrics", "4", true, true, true, false)  // 取回来解不开
	if driftStreak(amllLayoutParserName) != 2 {
		t.Fatalf("记两次认不出,got %d", driftStreak(amllLayoutParserName))
	}
	noteAMLLFetchShape("qq-lyrics", "5", true, true, true, true)
	if driftStreak(amllLayoutParserName) != 0 {
		t.Error("取成解开就清零")
	}
}
