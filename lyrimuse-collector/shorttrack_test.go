package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

// 「短于 30 秒的曲目」开关**只管 Last.fm**(2026-09-03 用户原话:"这个配置项是 lastfm 的,和
// listenbrainz 没有一点关系")。这里钉的是活路径的分流:开关开着、短曲目走进提交漏斗之后,
//   - ListenBrainz **一个请求都不发**;
//   - 会话照常收尾(listenSent=true,免得每轮 poll 重判)、本地收听日志照常记(它是给 Last.fm
//     回填兜底的);
//   - 同一条件下的普通曲目仍然正常发 LB —— 分流只认"短",不是把 LB 整个关掉。
func TestSubmitSingleShortTrackSkipsListenBrainz(t *testing.T) {
	savedFlag, savedPath := features.ScrobbleShortTracks, listenLogPath
	defer func() { features.ScrobbleShortTracks = savedFlag; listenLogPath = savedPath }()
	features.ScrobbleShortTracks = true
	listenLogPath = filepath.Join(t.TempDir(), "listens.jsonl")

	var lbPosts int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&lbPosts, 1)
		w.Write([]byte(`{"status":"ok"}`))
	}))
	t.Cleanup(srv.Close)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	p := &poller{
		ctx:          ctx,
		cfg:          &config{},
		lb:           &lbClient{root: srv.URL, token: "t", hc: srv.Client()},
		submitDoneCh: make(chan submitOutcome, 8),
	}

	// 短曲目:20 秒,听满一半。
	short := &playSession{meta: snapshot{Title: "过场", Artist: "A", Duration: 20}, startedAt: time.Now().Add(-time.Minute), submitting: true}
	p.submitSingleAsync(short, short.meta, short.startedAt.Unix())
	if !short.listenSent || short.submitting {
		t.Fatalf("短曲目应同步收尾:listenSent=%v submitting=%v", short.listenSent, short.submitting)
	}
	select {
	case r := <-p.submitDoneCh:
		t.Fatalf("短曲目不该经 channel 送结果(不该有 LB goroutine),却收到 %+v", r)
	case <-time.After(150 * time.Millisecond):
	}
	if n := atomic.LoadInt32(&lbPosts); n != 0 {
		t.Fatalf("短曲目不该打 ListenBrainz,却打了 %d 次", n)
	}
	logged := readListenLog()
	if len(logged) != 1 || logged[0].TI != "过场" || logged[0].DUR != 20 {
		t.Fatalf("短曲目应记进本地收听日志(给 Last.fm 回填),got %+v", logged)
	}

	// 对照:普通曲目照常发 LB。
	long := &playSession{meta: snapshot{Title: "正常歌", Artist: "A", Duration: 240}, startedAt: time.Now().Add(-5 * time.Minute), submitting: true}
	p.submitSingleAsync(long, long.meta, long.startedAt.Unix())
	select {
	case r := <-p.submitDoneCh:
		if r.err != nil || r.lastfmOnly {
			t.Fatalf("普通曲目应正常发 LB:err=%v lastfmOnly=%v", r.err, r.lastfmOnly)
		}
		p.applySubmitOutcome(r)
	case <-time.After(5 * time.Second):
		t.Fatal("普通曲目的 LB 提交没有回结果")
	}
	if n := atomic.LoadInt32(&lbPosts); n != 1 {
		t.Fatalf("普通曲目应打 ListenBrainz 1 次,实际 %d", n)
	}
	if !long.listenSent {
		t.Fatal("普通曲目应收尾 listenSent=true")
	}
}

// shortTrackLastfmOnly 只在开关开着、且曲长在 (0, 30) 时为真——开关关着时短曲目根本进不了
// 漏斗,这个判据为假只是"不额外分流"。
func TestShortTrackLastfmOnly(t *testing.T) {
	saved := features.ScrobbleShortTracks
	defer func() { features.ScrobbleShortTracks = saved }()
	features.ScrobbleShortTracks = true
	for dur, want := range map[float64]bool{20: true, 29.9: true, 30: false, 240: false, 0: false, -1: false} {
		if got := shortTrackLastfmOnly(dur); got != want {
			t.Errorf("开:shortTrackLastfmOnly(%v) = %v, want %v", dur, got, want)
		}
	}
	features.ScrobbleShortTracks = false
	if shortTrackLastfmOnly(20) {
		t.Error("关:不该分流")
	}
}
