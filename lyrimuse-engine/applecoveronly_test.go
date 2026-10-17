package main

import (
	"context"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
)

// 按专辑定位到了专辑、曲目表里没认出这一首:只给封面的结果问成了也进缓存,再问不重跑那一轮搜索、封面照给;
// appleMusicMatchAnsweredLocally 报得出它只读本地。
func TestAppleCoverOnlyMatchIsCached(t *testing.T) {
	resetAppleMatchCaches(t)
	resetITunesSearchBackoff(t)
	const artist, title, album = "方大同", "Three Tour", "橙月"
	hits := withFakeITunes(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if strings.Contains(r.URL.Path, "lookup") {
			_, _ = w.Write([]byte(`{"results":[]}`))
			return
		}
		_, _ = w.Write([]byte(`{"results":[{"trackName":"别的歌","collectionName":"橙月","collectionId":7,` +
			`"artworkUrl100":"https://i/100x100bb.jpg","artistName":"方大同","trackTimeMillis":1000}]}`))
	})
	srvURL := itunesSearchBaseURL
	old := itunesLookupTracksURL
	itunesLookupTracksURL = srvURL + "/lookup"
	t.Cleanup(func() { itunesLookupTracksURL = old })

	if appleMusicMatchAnsweredLocally(artist, title, album) {
		t.Fatal("还没问过,不该说只读本地")
	}
	m, reached := appleMusicMatchCachedReached(context.Background(), artist, title, album, 0)
	if !reached || m.url != "" || m.cover == "" {
		t.Fatalf("用例前提:只给封面、问成了: %+v reached=%v", m, reached)
	}
	first := atomic.LoadInt32(hits)
	if !appleMusicMatchAnsweredLocally(artist, title, album) {
		t.Error("只给封面的结果进了缓存,再问只读本地")
	}
	if again, _ := appleMusicMatchCachedReached(context.Background(), artist, title, album, 0); again.cover != m.cover {
		t.Errorf("再问封面照给: %+v", again)
	}
	if n := atomic.LoadInt32(hits); n != first {
		t.Errorf("命中缓存不该再发请求: %d → %d", first, n)
	}
	if !appleMusicMatchAnsweredLocally("某人", "", "") {
		t.Error("没歌名的不发请求")
	}
}
