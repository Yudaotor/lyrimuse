package main

import (
	"encoding/json"
	"testing"
)

// 单曲详情里的专辑封面:优先 600 那档,没有退 300,都没有是空串。
func TestKKBOXTrackAlbumCover(t *testing.T) {
	for _, c := range []struct {
		body, want string
	}{
		{`{"album":{"name":"A","images":{"large":{"url":"https://i.kfs.io/a/600x600.jpg"},"medium":{"url":"https://i.kfs.io/a/300x300.jpg"}}}}`, "https://i.kfs.io/a/600x600.jpg"},
		{`{"album":{"name":"A","images":{"medium":{"url":"https://i.kfs.io/a/300x300.jpg"}}}}`, "https://i.kfs.io/a/300x300.jpg"},
		{`{"album":{"name":"A"}}`, ""},
		{`{}`, ""},
	} {
		var tr kkboxTrack
		if err := json.Unmarshal([]byte(c.body), &tr); err != nil {
			t.Fatal(err)
		}
		if got := tr.albumCover(); got != c.want {
			t.Errorf("%s: got %q want %q", c.body, got, c.want)
		}
	}
}
