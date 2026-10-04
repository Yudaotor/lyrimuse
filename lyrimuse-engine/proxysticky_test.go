package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestProxyStickyWindow(t *testing.T) {
	for streak, want := range map[int]time.Duration{
		0: 10 * time.Minute, 1: 10 * time.Minute, 2: 20 * time.Minute, 3: 40 * time.Minute,
		6: 320 * time.Minute, 7: 6 * time.Hour, 100: 6 * time.Hour,
	} {
		if got := proxyStickyWindow(streak); got != want {
			t.Errorf("proxyStickyWindow(%d) = %s, want %s", streak, got, want)
		}
	}
}

// 让提示文件与内存里的窗口都到期,模拟「过了窗口、下一次请求重新探直连」。
func expireProxySticky(t *testing.T, tr *proxyFallbackTransport, host string) {
	t.Helper()
	f := readProxyFallbackHint()
	f.Until[host] = time.Now().Add(-time.Second).Unix()
	raw, _ := json.Marshal(f)
	if err := writeFileAtomic(proxyFallbackHintPath(), raw); err != nil {
		t.Fatal(err)
	}
	tr.mu.Lock()
	tr.stickyUntil = time.Now().Add(-time.Second)
	tr.mu.Unlock()
}

func proxyHintWindowLeft(host string) time.Duration {
	return time.Until(time.Unix(readProxyFallbackHint().Until[host], 0))
}

func TestProxyFallbackStickyWindowGrowsAndResets(t *testing.T) {
	newFallbackTestEnv(t)
	const host = "apic-appmobile.musixmatch.com"
	direct := &stubRoundTripper{err: errors.New("i/o timeout")}
	viaProxy := &stubRoundTripper{body: `{"ok":1}`}
	tr := &proxyFallbackTransport{direct: direct, viaProxy: viaProxy}
	roundTrip := func() {
		t.Helper()
		resp, err := tr.RoundTrip(newTestRequest(t))
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
	}

	roundTrip()
	if left := proxyHintWindowLeft(host); left < 9*time.Minute || left > 10*time.Minute {
		t.Fatalf("第一次:窗口应是 10 分钟,剩 %s", left)
	}
	expireProxySticky(t, tr, host)
	roundTrip() // 到期后重新探直连,又失败
	if left := proxyHintWindowLeft(host); left < 19*time.Minute || left > 20*time.Minute {
		t.Fatalf("连续第二次:窗口应翻倍到 20 分钟,剩 %s", left)
	}
	if got := readProxyFallbackHint().Streak[host]; got != 2 {
		t.Fatalf("连续次数 = %d, want 2", got)
	}

	// 到期后直连通了:清零。
	expireProxySticky(t, tr, host)
	direct.err = nil
	roundTrip()
	if f := readProxyFallbackHint(); f.Streak[host] != 0 || f.Until[host] != 0 || loadProxyFallbackHint(host) {
		t.Fatalf("直连恢复后应清零: %+v", f)
	}
	// 之后再被打掉,从 10 分钟重新算。
	direct.err = errors.New("i/o timeout")
	roundTrip()
	if left := proxyHintWindowLeft(host); left < 9*time.Minute || left > 10*time.Minute {
		t.Fatalf("清零后再失败:窗口应回到 10 分钟,剩 %s", left)
	}
}

// 老版本写的提示文件只有 hosts(没有 until):照旧按 proxyFallbackSticky 算到期。
func TestProxyFallbackHintLegacyFormat(t *testing.T) {
	newFallbackTestEnv(t)
	const host = "apic-appmobile.musixmatch.com"
	write := func(at time.Time) {
		t.Helper()
		raw, _ := json.Marshal(map[string]any{"hosts": map[string]int64{host: at.Unix()}})
		if err := os.MkdirAll(filepath.Dir(proxyFallbackHintPath()), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := writeFileAtomic(proxyFallbackHintPath(), raw); err != nil {
			t.Fatal(err)
		}
	}
	write(time.Now())
	if !loadProxyFallbackHint(host) {
		t.Fatal("刚写的老格式提示应当有效")
	}
	write(time.Now().Add(-proxyFallbackSticky - time.Minute))
	if loadProxyFallbackHint(host) {
		t.Fatal("过了 proxyFallbackSticky 的老格式提示应当失效")
	}
}
