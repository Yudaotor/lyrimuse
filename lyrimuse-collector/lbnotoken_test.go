package main

import (
	"context"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// 没配 listenbrainz_token 时,提交这条路整条不存在:不发请求,也不做任何为它服务的准备。
// 绝大多数只用本机悬浮歌词的用户属于这一档,对他们必须完全无感。
func TestSubmitInertWithoutToken(t *testing.T) {
	var mu sync.Mutex
	hits := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		hits++
		mu.Unlock()
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	c := &lbClient{root: srv.URL, token: "", hc: &http.Client{}}
	info := map[string]any{"lyrics": "第一句\n第二句", "media_player": "Music"}
	meta := lbTrackMeta{ArtistName: "A", TrackName: "T", AdditionalInfo: info}

	for _, kind := range []string{"playing_now", "single"} {
		if err := c.submit(context.Background(), kind, 1, meta); err != nil {
			t.Errorf("%s: 没 token 应该静默跳过而不是回错, got %v", kind, err)
		}
	}

	mu.Lock()
	defer mu.Unlock()
	if hits != 0 {
		t.Errorf("没 token 时不该发任何请求, 实发 %d 次", hits)
	}
	// 连"剥歌词字段"这步准备工作都不该做 —— 它是 marshal 前的活,门开在它之后就等于
	// 每一拍都白干一遍(这正是 2026-09-17 把门前移要消掉的东西)。meta 原样没动即为证据。
	if _, ok := info["lyrics"]; !ok {
		t.Error("没 token 时连准备工作都不该做,AdditionalInfo 不该被改动")
	}
}

// dry-run 是那道门的唯一例外:`-dry-run` 的全部用途就是"让我看看会发出去什么",
// 没 token 也得把 body 印出来,否则这个排查手段在未配置的机器上直接失效。
func TestSubmitDryRunStillWorksWithoutToken(t *testing.T) {
	var mu sync.Mutex
	hits := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		hits++
		mu.Unlock()
	}))
	defer srv.Close()

	var buf strings.Builder
	old := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(old)

	c := &lbClient{root: srv.URL, token: "", hc: &http.Client{}, dryRun: true}
	meta := lbTrackMeta{ArtistName: "A", TrackName: "T"}
	if err := c.submit(context.Background(), "playing_now", 0, meta); err != nil {
		t.Fatalf("dry-run 不该回错: %v", err)
	}
	if !strings.Contains(buf.String(), "[dry-run] would POST playing_now") {
		t.Errorf("dry-run 没 token 时也该印出 body, 日志是 %q", buf.String())
	}
	mu.Lock()
	defer mu.Unlock()
	if hits != 0 {
		t.Errorf("dry-run 不该真发请求, 实发 %d 次", hits)
	}
}
