package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// ---- 直连优先、直连被打掉就改走系统代理 ----
//
// 2026-09-03 加,配套 systemproxy.go(那边记着完整的实测数据和"为什么不全局走代理")。
// 一句话:代理在这台机器上是**更差**的通道(Last.fm 实测 p50 0.4s→1.2s、失败率 1%→16%,
// 见 docs/features/12 章),所以它只能是兜底 —— 直连正常时一个包都不该经过它。
//
// 生效范围严格等于 doh.go 的 dohHostSuffixes(当前只有 .musixmatch.com):dohHTTPClient
// 是全仓唯一用这套 Transport 的地方,其余 26 处 http.Client 走 http.DefaultTransport,
// 行为逐位不变。
const (
	// proxyFallbackDirectBudget:直连探路预算。黑洞的特征是 SYN 石沉大海 —— 2026-09-03 量
	// 到的三次侥幸成功都落在 1.3s / 3.4s(SYN 重传之后),而路通的时候 TCP+TLS 全程 <1s。
	// 3 秒足够分辨这两种,又不至于在慢网络上把"只是有点慢"误判成"被打掉了"。
	proxyFallbackDirectBudget = 3 * time.Second
	// proxyFallbackProxyBudget:走代理的预算。实测经本机 Clash 打 token.get 是 6.5s
	// (代理要先把自己那条出境链路建起来),给 10s 留足余量。
	proxyFallbackProxyBudget = 10 * time.Second
	// proxyFallbackSticky:代理救回来之后,接下来多久直接走代理、不再重新探直连。
	//
	// ⚠️ 粘性不是优化,是必需项。AGENTS.md 里 2026-08-15 Musixmatch DNS 事故的原话是
	// 「每首歌都要把 DNS/TLS 超时白等一遍」,healthcheck 探两首歌从 7s 涨到 29s。没有粘性
	// 的话这里会原样重演:每个请求先白等 3s 直连再走代理。10 分钟之后重新探一次直连,
	// 网络恢复了就自动回到直连,不需要重启。
	proxyFallbackSticky = 10 * time.Minute
)

// proxyFallbackTransport 把上面那条策略包成一个 http.RoundTripper。
//
// 为什么做在 RoundTripper 这一层而不是拨号层(dohDialContext):HTTP 代理是靠 CONNECT 建
// 隧道的,在 net.Conn 那一层做等于手写一遍 CONNECT 握手;而 http.Transport 本来就实现了
// 它,只要给它一个 Proxy 函数。两个 Transport 各自完整、互不干扰,选哪个是这一层的事。
type proxyFallbackTransport struct {
	direct   http.RoundTripper
	viaProxy http.RoundTripper
	// onBlocked 在"直连不通,而且代理也救不回来(或压根没有可用代理)"时回调一次,给调用方
	// 记一个具体的失败原因 —— 设置页那颗「测试」按钮会把它翻成人话显示出来。可以为 nil。
	onBlocked func()

	mu          sync.Mutex
	stickyUntil time.Time
}

func (t *proxyFallbackTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	// 带 body 的请求不做 fallback:重试要 req.Clone,而 Clone **不复制 body**(只有
	// GetBody 才能重放),第二次拨过去会是一个空 body 的请求 —— 那种失败比不重试更难查。
	// 这条通路当前全是 GET(musixmatch 的五个端点都是),这里只是把不变量写死。
	if req.Body != nil {
		return t.attempt(t.direct, req, proxyFallbackDirectBudget)
	}

	host := req.URL.Hostname()

	if t.preferProxy(host) {
		resp, err := t.attempt(t.viaProxy, req, proxyFallbackProxyBudget)
		if err == nil {
			return resp, nil
		}
		// 代理自己坏了(用户关掉了 / 换了端口 / 节点挂了):清掉粘性,当场回直连再试一次。
		// 不清的话会一直往一个死代理上撞,而直连说不定早就恢复了。
		t.clearSticky(host)
		log.Printf("proxy: %s 经代理失败(%v),清掉粘性、改回直连重试", host, err)
		resp, err = t.attempt(t.direct, req, proxyFallbackDirectBudget)
		if err != nil {
			t.reportBlocked()
		}
		return resp, err
	}

	directStart := time.Now()
	resp, directErr := t.attempt(t.direct, req, proxyFallbackDirectBudget)
	directElapsed := time.Since(directStart)
	if directErr == nil {
		return resp, nil
	}
	proxy := systemProxyURL()
	if proxy == nil {
		t.reportBlocked()
		return nil, directErr
	}
	proxyStart := time.Now()
	resp, proxyErr := t.attempt(t.viaProxy, req, proxyFallbackProxyBudget)
	if proxyErr != nil {
		t.reportBlocked()
		// ⚠️ 这一行不能省。返回值里只会带**直连**那次的错(上层真正关心的是我们本来想走
		// 的那条路怎么了),代理那次的错在返回值里是拿不到的 —— 不在这里记一行,"兜底为什么
		// 也没兜住"就彻底不可观测。2026-09-03 装机验证时正是缺了它,才没法一眼看出第一首
		// 探测曲的代理那半边是超时还是被代理拒了。
		log.Printf("proxy: %s 直连失败(%v, %s)后经系统代理 %s 也失败(%v, %s)",
			host, directErr, directElapsed.Round(time.Millisecond),
			proxy.Host, proxyErr, time.Since(proxyStart).Round(time.Millisecond))
		return nil, directErr
	}
	t.markSticky(host)
	log.Printf("proxy: %s 直连失败(%v, %s),经系统代理 %s 成功(%s),接下来 %s 内直接走代理",
		host, directErr, directElapsed.Round(time.Millisecond), proxy.Host,
		time.Since(proxyStart).Round(time.Millisecond), proxyFallbackSticky)
	return resp, nil
}

// attempt 跑一次 RoundTrip,并给它单独一份预算。
//
// ⚠️ 预算必须落在**每次尝试**上,不能靠 http.Client.Timeout —— 那是把直连和代理两次尝试
// 算进同一个预算里,直连一超时就没钱给代理重试了,fallback 等于没加。dohHTTPClient 因此
// 刻意不设 Client.Timeout,头注里也写着别加回去。
func (t *proxyFallbackTransport) attempt(rt http.RoundTripper, req *http.Request, budget time.Duration) (*http.Response, error) {
	ctx, cancel := context.WithTimeout(req.Context(), budget)
	resp, err := rt.RoundTrip(req.Clone(ctx))
	if err != nil {
		cancel()
		return nil, err
	}
	// ⚠️ cancel 不能在这里调:ctx 一取消,还没读的 resp.Body 立刻断流(表现是调用方
	// io.ReadAll 拿到 "context canceled",看起来像服务器提前关了连接)。挂到 Body 上,
	// 等调用方 Close 了再释放 —— 这是 net/http 自己对付 Client.Timeout 的办法
	// (cancelTimerBody),不是这里发明的写法。
	resp.Body = &proxyFallbackBody{ReadCloser: resp.Body, cancel: cancel}
	return resp, nil
}

type proxyFallbackBody struct {
	io.ReadCloser
	cancel context.CancelFunc
	once   sync.Once
}

func (b *proxyFallbackBody) Close() error {
	err := b.ReadCloser.Close()
	b.once.Do(b.cancel)
	return err
}

func (t *proxyFallbackTransport) reportBlocked() {
	if t.onBlocked != nil {
		t.onBlocked()
	}
}

// preferProxy:这一次要不要直接走代理(跳过直连探路)。
// 内存粘性和磁盘提示任一命中即可,但都得先确认现在真有一个连得上的代理。
func (t *proxyFallbackTransport) preferProxy(host string) bool {
	t.mu.Lock()
	sticky := time.Now().Before(t.stickyUntil)
	t.mu.Unlock()
	if !sticky && !loadProxyFallbackHint(host) {
		return false
	}
	return systemProxyURL() != nil
}

func (t *proxyFallbackTransport) markSticky(host string) {
	t.mu.Lock()
	t.stickyUntil = time.Now().Add(proxyFallbackSticky)
	t.mu.Unlock()
	saveProxyFallbackHint(host, true)
}

func (t *proxyFallbackTransport) clearSticky(host string) {
	t.mu.Lock()
	t.stickyUntil = time.Time{}
	t.mu.Unlock()
	saveProxyFallbackHint(host, false)
}

// ---- 跨进程的"这个域名现在得走代理"提示 ----
//
// 为什么要落盘:collector 有常驻进程,也有一堆一次性 CLI 子命令(search-lyrics /
// test-lyric-sources / healthcheck),后者每次都是全新进程、内存里的粘性一律归零,于是每跑
// 一次都要重新白等一遍直连探路。而「联网搜索候选歌词」和设置页那颗「测试」按钮都在这条路上,
// 用户是当场盯着等的 —— 3 秒 × 每个请求,一轮下来就是十几秒的空等。
//
// 这只是一份**提示**,不是权威状态:读到了也仍然要确认代理连得上(preferProxy),读不到最多
// 多探一次直连。所以两个进程同时写导致丢一条更新是可以接受的,不值得为它上文件锁。
type proxyFallbackHintFile struct {
	// Hosts: host -> 最近一次"代理把它救回来了"的 unix 秒。
	Hosts map[string]int64 `json:"hosts"`
}

func proxyFallbackHintPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", clientName, clientName+"-proxy-hint.json")
}

func readProxyFallbackHint() proxyFallbackHintFile {
	f := proxyFallbackHintFile{Hosts: map[string]int64{}}
	path := proxyFallbackHintPath()
	if path == "" {
		return f
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return f
	}
	var parsed proxyFallbackHintFile
	if json.Unmarshal(raw, &parsed) != nil || parsed.Hosts == nil {
		return f
	}
	return parsed
}

func loadProxyFallbackHint(host string) bool {
	at, ok := readProxyFallbackHint().Hosts[host]
	if !ok {
		return false
	}
	return time.Since(time.Unix(at, 0)) < proxyFallbackSticky
}

func saveProxyFallbackHint(host string, useProxy bool) {
	path := proxyFallbackHintPath()
	if path == "" {
		return
	}
	f := readProxyFallbackHint()
	if useProxy {
		f.Hosts[host] = time.Now().Unix()
	} else {
		delete(f.Hosts, host)
	}
	raw, err := json.Marshal(f)
	if err != nil {
		return
	}
	// 目录一般早就有了(config.json 就在里面),但不能假定 —— 全新机器上第一次跑到这里
	// 时它还不存在,os.WriteFile 不会自己建,于是提示**静默**写不下去、跨进程粘性形同虚设
	// (2026-09-03 由 TestProxyFallbackUsesProxyWhenDirectFails 当场抓到)。
	if os.MkdirAll(filepath.Dir(path), 0o700) != nil {
		return
	}
	// tmp + rename,临时文件名带进程号 —— 跟 musixmatchSaveTokenFile 同一个理由:并发的
	// 两个写入方不能互相覆盖同一个 tmp,否则 rename 出去的可能是半份别人的内容。
	tmp := fmt.Sprintf("%s.tmp.%d", path, os.Getpid())
	if os.WriteFile(tmp, raw, 0o600) != nil {
		return
	}
	if os.Rename(tmp, path) != nil {
		os.Remove(tmp)
	}
}
