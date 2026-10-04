package main

import (
	"context"
	"testing"
	"time"
)

// inflightSnapshot 取 enrichInflight 的一份拷贝,用来断言"没起任何解析"。
func inflightSnapshot() map[string]bool {
	enrichMu.Lock()
	defer enrichMu.Unlock()
	out := make(map[string]bool, len(enrichInflight))
	for k, v := range enrichInflight {
		out[k] = v
	}
	return out
}

func assertNoNewResolution(t *testing.T, before map[string]bool, cacheSize int) {
	t.Helper()
	after := inflightSnapshot()
	for k := range after {
		if !before[k] {
			t.Errorf("不该起解析,却多了在途的 %q", k)
		}
	}
	enrichMu.Lock()
	n := len(enrichCache)
	enrichMu.Unlock()
	if n != cacheSize {
		t.Errorf("不该新建条目:缓存从 %d 条变成 %d 条", cacheSize, n)
	}
}

// 只查缓存:精确 key 与宽松等价(大小写 / 空格 / 繁简)都能命中,没命中返回 nil 且什么都不起。
func TestCachedTrackEnrichmentLooksUpOnly(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"PRINCE|P. Control|The Gold Experience": {CoverURL: "https://example.com/p.jpg", Lyrics: "[00:01.00]x"},
		"盧廣仲|100種生活|100種生活":                     {CoverURL: "https://example.com/c.jpg"},
	})
	if got := cachedTrackEnrichment("PRINCE", "P. Control", "The Gold Experience"); got["cover_url"] != "https://example.com/p.jpg" {
		t.Errorf("精确 key 该命中: %v", got)
	}
	if got := cachedTrackEnrichment("Prince", "P. Control", "The Gold Experience"); got["cover_url"] != "https://example.com/p.jpg" {
		t.Errorf("大小写不同也该命中已有条目: %v", got)
	}
	if got := cachedTrackEnrichment("盧廣仲", "100种生活", "100種生活"); got["cover_url"] != "https://example.com/c.jpg" {
		t.Errorf("繁简不同也该命中已有条目: %v", got)
	}
	before := inflightSnapshot()
	if got := cachedTrackEnrichment("Crowd Lu", "100种生活", "100種生活"); got != nil {
		t.Errorf("Mac 上没放过的写法该返回 nil: %v", got)
	}
	assertNoNewResolution(t, before, 2)
}

// 桥接来的歌组装 ListenBrainz / 中继负载时,缓存没有就不起解析、不建条目;有就照样带上封面。
func TestBridgedSnapshotNeverStartsResolution(t *testing.T) {
	withEnrichCache(t, map[string]enrichEntry{
		"PRINCE|P. Control|The Gold Experience": {CoverURL: "https://example.com/p.jpg"},
	})
	before := inflightSnapshot()
	miss := snapshot{Title: "100种生活", Artist: "Crowd Lu", Album: "100種生活", Remote: true}
	lbMeta(miss)
	relayState(miss, true, "iphone", 0, true)
	assertNoNewResolution(t, before, 1)

	hit := snapshot{Title: "P. Control", Artist: "Prince", Album: "The Gold Experience", Remote: true}
	if got := lbMeta(hit).AdditionalInfo["cover_url"]; got != "https://example.com/p.jpg" {
		t.Errorf("Mac 上放过的歌该照样带上封面: %v", got)
	}
}

// 没配 ListenBrainz(上送目标)时,桥接结果只落 App 的 feed,转发 / 同步正在播放那两步连缓存都不查。
func TestApplyBridgeResultWithoutUploadTargetSkipsEnrichment(t *testing.T) {
	withEnrichCache(t, nil)
	before := inflightSnapshot()
	p := &poller{ctx: context.Background(), cfg: &config{LastfmUser: "someone", LastfmAPIKey: "key"}}
	now := time.Now()
	p.applyBridgeResult(bridgeFetchResult{now: now, ok: true, page: lastfmRecentPage{
		NowPlaying: &lastfmTrack{Artist: "Crowd Lu", Title: "PAZ", Album: "100種生活"},
		Done:       []lastfmTrack{{Artist: "Crowd Lu", Title: "Boring", Album: "100種生活", UTS: now.Unix() - 60}},
	}})
	if !p.remoteAt.IsZero() || p.remoteTrack.Title != "" {
		t.Errorf("没配上送目标不该记 iPhone 正在播放: %+v", p.remoteTrack)
	}
	assertNoNewResolution(t, before, 0)
}

// 配了 ListenBrainz:转发 iPhone 收听、同步 iPhone 正在播放都照常走,但 Mac 上没放过的歌不起解析。
func TestApplyBridgeResultForwardsWithoutResolving(t *testing.T) {
	withEnrichCache(t, nil)
	before := inflightSnapshot()
	dir := t.TempDir()
	now := time.Now()
	p := &poller{
		ctx:                 context.Background(),
		cfg:                 &config{LastfmUser: "someone", LastfmAPIKey: "key", User: "lb-user", Token: "lb-token"},
		lb:                  &lbClient{dryRun: true},
		fwdSeeded:           true,
		forwarded:           map[int64]bool{},
		lfmMirrored:         map[int64]bool{},
		forwardedSet:        persistedTTLSet{path: dir + "/forwarded.json", ttl: forwardedTTL},
		lfmMirroredSet:      persistedTTLSet{path: dir + "/mirrored.json", ttl: lfmMirroredTTL},
		bridgeForwardDoneCh: make(chan []bridgeForwardResult, 1),
	}
	uts := now.Unix() - 60
	p.applyBridgeResult(bridgeFetchResult{now: now, ok: true, page: lastfmRecentPage{
		NowPlaying: &lastfmTrack{Artist: "Crowd Lu", Title: "PAZ", Album: "100種生活"},
		Done:       []lastfmTrack{{Artist: "Crowd Lu", Title: "Boring", Album: "100種生活", UTS: uts}},
	}})
	// 转发在后台跑,结果回来再记账。
	select {
	case r := <-p.bridgeForwardDoneCh:
		p.applyBridgeForwardResults(r)
	case <-time.After(3 * time.Second):
		t.Fatal("后台转发没有回结果")
	}
	if !p.forwarded[uts] {
		t.Error("iPhone 的完成收听该照常转发")
	}
	if p.lastListen.Title != "Boring" || !p.lastListen.Remote {
		t.Errorf("转发时记下的上一首(网页中继会推它)也要标成桥接来的: %+v", p.lastListen)
	}
	if p.remoteTrack.Title != "PAZ" || !p.remoteTrack.Remote {
		t.Errorf("iPhone 正在播放该照常记下、并标成桥接来的: %+v", p.remoteTrack)
	}
	assertNoNewResolution(t, before, 0)
}
