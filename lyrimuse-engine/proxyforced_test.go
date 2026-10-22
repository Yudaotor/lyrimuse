package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"testing"
	"time"
)

// 强制走代理的主机:代理失败不退回直连、不清粘性,下一次照旧走代理;新起的 transport(别的进程)读磁盘提示照样认。
func TestProxyFallbackForcedHostStaysOnProxy(t *testing.T) {
	newFallbackTestEnv(t)
	host := "apic-appmobile.musixmatch.com"
	direct := &stubRoundTripper{body: "direct"}
	viaProxy := &stubRoundTripper{err: errors.New("EOF")}
	tr := &proxyFallbackTransport{direct: direct, viaProxy: viaProxy}
	forceProxyFor(&http.Client{Transport: tr}, host, time.Hour)
	if _, err := tr.RoundTrip(newTestRequest(t)); err == nil {
		t.Fatal("代理失败应把错误交回去")
	}
	if direct.calls != 0 {
		t.Fatalf("强制期里不该退回直连,直连试了 %d 次", direct.calls)
	}
	if !tr.preferProxy(host) {
		t.Fatal("代理失败一次之后仍该走代理")
	}
	fresh := &proxyFallbackTransport{direct: direct, viaProxy: viaProxy}
	if _, err := fresh.RoundTrip(newTestRequest(t)); err == nil || direct.calls != 0 {
		t.Fatalf("别的进程读磁盘提示也该认强制期: err=%v direct=%d", err, direct.calls)
	}
}

// 强制期过了:代理失败照旧退回直连(普通的「代理自己坏了」)。
func TestProxyFallbackExpiredForceFallsBackDirect(t *testing.T) {
	newFallbackTestEnv(t)
	host := "apic-appmobile.musixmatch.com"
	saveProxyFallbackHint(host, true)
	f := readProxyFallbackHint()
	f.Forced = map[string]int64{host: time.Now().Add(-time.Minute).Unix()}
	raw, _ := json.Marshal(f)
	if err := os.WriteFile(proxyFallbackHintPath(), raw, 0o600); err != nil {
		t.Fatal(err)
	}
	direct := &stubRoundTripper{body: "direct"}
	tr := &proxyFallbackTransport{direct: direct, viaProxy: &stubRoundTripper{err: errors.New("EOF")}}
	resp, err := tr.RoundTrip(newTestRequest(t))
	if err != nil || direct.calls != 1 {
		t.Fatalf("强制期过了应退回直连: err=%v direct=%d", err, direct.calls)
	}
	resp.Body.Close()
}

// 两台主机都走代理才算走代理:只有备用主机还在代理上时,主用主机走的是直连。
func TestProxyFallbackPreferProxyAll(t *testing.T) {
	newFallbackTestEnv(t)
	tr := &proxyFallbackTransport{direct: &stubRoundTripper{}, viaProxy: &stubRoundTripper{}}
	hosts := []string{"apic-appmobile.musixmatch.com", "apic.musixmatch.com"}
	saveProxyFallbackHint(hosts[1], true)
	if tr.preferProxyAll(hosts) {
		t.Fatal("只有一台走代理不算")
	}
	saveProxyFallbackHint(hosts[0], true)
	if !tr.preferProxyAll(hosts) {
		t.Fatal("两台都走代理才算")
	}
	if tr.preferProxyAll(nil) {
		t.Fatal("空名单不算")
	}
}
