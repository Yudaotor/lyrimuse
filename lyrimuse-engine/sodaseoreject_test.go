package main

import (
	"net/http"
	neturl "net/url"
	"testing"
)

// seo_track 回 200 却不是 JSON(风控页之类):按接口被拒记一次、报错;回了 JSON 就清掉。
func TestSodaSeoTrackNonJSONCountsAsRejected(t *testing.T) {
	body := "<html>verify</html>"
	withLRCLIBFake(t, func(r *http.Request) (int, http.Header, string) { return http.StatusOK, nil, body })
	key := guardEndpointKey(&neturl.URL{Host: sodaSeoTrackHost, Path: sodaSeoTrackPath})
	rejects := func() int {
		g := sharedHostGuard()
		g.mu.Lock()
		defer g.mu.Unlock()
		if h := g.health[key]; h != nil {
			return h.rejects
		}
		return 0
	}
	if _, err := sodaGetSeoTrackAt(qqRoundCtx(), sodaSeoTrackHost, "1"); err == nil {
		t.Fatal("不是 JSON 应当报错")
	}
	if n := rejects(); n != 1 {
		t.Fatalf("应记一次被拒,记了 %d", n)
	}
	body = `{"seo_track":{}}`
	if _, err := sodaGetSeoTrackAt(qqRoundCtx(), sodaSeoTrackHost, "1"); err != nil {
		t.Fatal(err)
	}
	if n := rejects(); n != 0 {
		t.Fatalf("回了 JSON 应清掉被拒计数,还是 %d", n)
	}
}
