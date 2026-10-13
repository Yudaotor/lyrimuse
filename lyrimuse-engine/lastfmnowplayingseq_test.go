package main

import (
	"context"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

// 先开始的那次正在播放匹配完时已经作废(下一首取了新号):不发、不记 lastSentNP;最新的那次照发。
func TestNowPlayingSupersededNotSent(t *testing.T) {
	var mu sync.Mutex
	var tracks []string
	s := newLastfmScrobbler("key", "secret", "sk")
	s.hc = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body, _ := io.ReadAll(r.Body)
		form, _ := url.ParseQuery(string(body))
		mu.Lock()
		tracks = append(tracks, form.Get("track"))
		mu.Unlock()
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{}`)), Header: http.Header{}}, nil
	})}
	setMatch(t, lastfmMatchRaw, false, false, false)
	ctx := context.Background()

	seqA := s.nextNowPlaying()
	seqB := s.nextNowPlaying()
	if err := s.updateNowPlaying(withNowPlayingSeq(ctx, seqB), "B", "Song B", "", 200); err != nil {
		t.Fatalf("最新的那次要发: %v", err)
	}
	if err := s.updateNowPlaying(withNowPlayingSeq(ctx, seqA), "A", "Song A", "", 200); err != errNowPlayingSuperseded {
		t.Fatalf("作废的那次不该发: err=%v", err)
	}
	if len(tracks) != 1 || tracks[0] != "Song B" {
		t.Fatalf("只该发出最新的那次: %v", tracks)
	}
	if _, track := s.sentNowPlayingAt(time.Now()); track != "Song B" {
		t.Fatalf("lastSentNP 要留在实际发出去的那次: %q", track)
	}
	// 不带代次的调用方照发。
	if err := s.updateNowPlaying(ctx, "C", "Song C", "", 200); err != nil || len(tracks) != 2 {
		t.Fatalf("不带代次的照发: err=%v tracks=%v", err, tracks)
	}
}

// 作废没发出去不算一次成功:error 4 的嫌疑不洗清;也不算失败,不交给 onFail。
func TestMirrorAsyncIgnoresSupersededNowPlaying(t *testing.T) {
	s := newLastfmScrobbler("key", "secret", "sk")
	s.suspect4.Store(time.Now().UnixNano())
	failed := false
	mirrorAsync(s, "now-playing", func(context.Context) error { return errNowPlayingSuperseded }, func(error) { failed = true })
	if n := waitMirrorsInflight(context.Background()); n != 0 {
		t.Fatalf("还有 %d 条没结束", n)
	}
	if s.suspect4.Load() == 0 {
		t.Error("作废的那次不该洗清 error 4 的嫌疑")
	}
	if failed {
		t.Error("作废的那次不该当失败留痕")
	}
}

// 换了会话就作废上一首还在匹配的正在播放,这一首是不发正在播放的广告也一样;同一个会话再来一次不作废。
func TestAnnounceSupersedesOnSessionChange(t *testing.T) {
	s := newLastfmScrobbler("key", "secret", "sk")
	p := &poller{lfm: s}
	stale := s.nextNowPlaying()

	p.sess = &playSession{isAd: true}
	p.announce(time.Now(), "track change")
	after := s.npSeq.Load()
	if after == stale {
		t.Fatal("换了会话要作废上一首的代次")
	}
	p.announce(time.Now(), "refresh")
	if s.npSeq.Load() != after {
		t.Fatal("同一个会话、没发正在播放时不该再作废")
	}
}
