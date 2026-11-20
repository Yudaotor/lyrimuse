package main

import (
	"errors"
	neturl "net/url"
	"testing"
	"time"
)

// 后台请求吃到的 429 只记「这个主机的主人答过了」:记在实际请求的主机的主人头上,别的源不受影响。
func TestBackgroundRateLimitCountsAsAnswerFromHostOwner(t *testing.T) {
	c := &guardClock{t: time.Unix(1_000_000, 0)}
	b := newLyricSourceBreaker(c.now)
	boom := errors.New("connection refused")
	b.observe("api.deezer.com", boom, 0, "")
	b.observe("lrclib.net", boom, 0, "")
	if codes := b.transportFailureCodes(); codes["deezer"] == "" || codes["lrclib"] == "" {
		t.Fatalf("前提:两个源都只失败过、没答过: %v", codes)
	}
	b.observeBackgroundRateLimited("www.deezer.com:443")
	codes := b.transportFailureCodes()
	if codes["deezer"] != "" {
		t.Errorf("deezer 的主机回了 429,算它答过,不该再报连不上: %v", codes)
	}
	if codes["lrclib"] == "" {
		t.Errorf("别的源没答过,照旧报连不上: %v", codes)
	}
	if _, cooling := b.coolingDown("deezer"); cooling {
		t.Error("后台 429 不让源进冷却")
	}
	b.observeBackgroundRateLimited("api.example.org")
	if len(b.transport) != 2 {
		t.Errorf("不是歌词源的主机不记: %v", b.transport)
	}
}

// 响应体里认出的限流只给不是歌词源的主机记端点窗口;歌词源的主机不记(它的限流归熔断器和后台暂停管)。
func TestReportEndpointRateLimitedSkipsLyricSourceHosts(t *testing.T) {
	saved := sharedHostGuard()
	g, _ := newTestGuard(hostRate{perSec: 1000, burst: 1000})
	setSharedHostGuard(g)
	t.Cleanup(func() { setSharedHostGuard(saved) })
	for raw, want := range map[string]bool{
		"https://ws.audioscrobbler.com/2.0/?method=track.getInfo": true,
		"https://lrclib.net/api/get":                              false,
		"https://c.y.qq.com/soso/fcgi-bin/client_search_cp":       false,
		"https://API.Megalobiz.com:443/api/public/v1/search":      false,
	} {
		u, err := neturl.Parse(raw)
		if err != nil {
			t.Fatal(err)
		}
		reportEndpointRateLimited(u, "")
		if _, blocked := g.endpointBlockedUntil(guardEndpointKey(u)); blocked != want {
			t.Errorf("%s:进没进端点限流窗口 = %v,期望 %v", raw, blocked, want)
		}
	}
	reportEndpointRateLimited(nil, "")
}
