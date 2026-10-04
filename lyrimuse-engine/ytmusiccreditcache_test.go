package main

import (
	"context"
	"os"
	"strings"
	"testing"
)

// 不在 Kaset 播放现场的重搜从缓存里存过的歌曲页取 videoId;播放现场带来的优先,形状不对的不认。
func TestCachedYouTubeMusicVideoID(t *testing.T) {
	const key = "菲尔·科林斯|Another Day In Paradise (Live)|"
	withEnrichCache(t, map[string]enrichEntry{
		key:           {YouTubeMusicURL: "https://music.youtube.com/watch?v=Qt2mbGP6vFI"},
		"bad|shape|":  {YouTubeMusicURL: "https://music.youtube.com/watch?v=short"},
		"other|host|": {YouTubeMusicURL: "https://www.youtube.com/watch?v=Qt2mbGP6vFI"},
	})
	enrichMu.Lock()
	defer enrichMu.Unlock()
	cases := []struct {
		name string
		ctx  context.Context
		key  string
		want string
	}{
		{"缓存里存过歌曲页", context.Background(), key, "Qt2mbGP6vFI"},
		{"播放现场带来的优先", withYouTubeMusicVideoID(context.Background(), "mQLzR5V2Z9c"), key, "mQLzR5V2Z9c"},
		{"videoId 形状不对", context.Background(), "bad|shape|", ""},
		{"不是 YouTube Music 歌曲页", context.Background(), "other|host|", ""},
		{"缓存里没有这首", context.Background(), "missing|key|", ""},
	}
	for _, c := range cases {
		if got := youTubeMusicVideoIDFrom(withCachedYouTubeMusicVideoIDLocked(c.ctx, c.key)); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

// 两条重搜入口都要在开查之前挂上:videoId 要赶在 withLyricSourceRound 派生这一轮的 ctx 之前。
func TestLyricsRetriesAttachCachedYouTubeMusicVideoID(t *testing.T) {
	data, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(data)
	for _, fn := range []string{"func retryLyricsUpgrade(", "func rescoreLyrics("} {
		i := strings.Index(src, fn)
		if i < 0 {
			t.Fatalf("找不到 %s —— 改名了就同步改这个守卫", fn)
		}
		body := src[i:]
		attach := strings.Index(body, "ctx = withCachedYouTubeMusicVideoIDLocked(ctx, key)")
		round := strings.Index(body, "withLyricSourceRound(ctx)")
		if attach < 0 || round < 0 || attach > round {
			t.Errorf("%s 没在开查之前从缓存补上 videoId", fn)
		}
	}
}
