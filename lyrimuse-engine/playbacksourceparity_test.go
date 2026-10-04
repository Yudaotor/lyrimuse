package main

import "testing"

// App 侧播放源加固里跟引擎同一套判据的那一处:最近记录只有一条时的对象形状。

// Last.fm 的 recenttracks.track 只有一条时是对象不是数组:照样解出这一条,不整份解失败(feed 永远写不出来)。
func TestParseLastfmRecentSingleTrackObject(t *testing.T) {
	body := `{"recenttracks":{"@attr":{"total":"1"},"track":{"name":"唯一一条","artist":{"#text":"A"},"album":{"#text":""},"date":{"uts":"1790000000"}}}}`
	page, err := parseLastfmRecent([]byte(body))
	if err != nil {
		t.Fatalf("单条对象不该解失败: %v", err)
	}
	if len(page.Done) != 1 || page.Done[0].Title != "唯一一条" || page.Total != 1 {
		t.Fatalf("应解出这一条: %+v", page)
	}
	if _, err := parseLastfmRecent([]byte(`{"recenttracks":{"@attr":{"total":"0"},"track":[]}}`)); err != nil {
		t.Fatalf("空数组照常: %v", err)
	}
}
