package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptrace"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"
)

// ---- 直连优先、直连被打掉就改走系统代理 ----
//
// 加,配套 systemproxy.go(那边记着完整的实测数据和"为什么不全局走代理")。
// 一句话:代理在这台机器上是**更差**的通道(Last.fm 实测 p50 0.4s→1.2s、失败率 1%→16%,
// 见 docs/features/12 章),所以它只能是兜底 —— 直连正常时一个包都不该经过它。
//
// 生效范围:doh.go 的 dohHTTPClient(dohHostSuffixes,当前只有 .musixmatch.com)、alerter.go 的 telegramHTTPClient
// (推送到 api.telegram.org)、relay.go 的 relayHTTPClient / relaySeedClient(状态中继的推送与封面托管、启动补
// 「上次播放」那一次 ListenBrainz 查询),以及 lb.go 的 lbHTTPClient(ListenBrainz 提交)。其它歌词源(netease/qq/kugou/lrclib/kuwo/migu/amll/
// lyricfind)走 lyricsourcedial.go 的 lyricSourceTransport(系统 DNS 优先、不答才
// DoH,**没有**代理兜底),Last.fm / iTunes 等仍是 http.DefaultTransport。
const (
	// proxyFallbackDirectBudget:直连探路预算。黑洞的特征是 SYN 石沉大海 —— 量
	// 到的三次侥幸成功都落在 1.3s / 3.4s(SYN 重传之后),而路通的时候 TCP+TLS 全程 <1s。
	// 3 秒足够分辨这两种,又不至于在慢网络上把"只是有点慢"误判成"被打掉了"。调用方有时限时只算到拿到连接为止,
	// 服务器处理得慢不算(见 attemptDirect)。
	proxyFallbackDirectBudget = 3 * time.Second
	// proxyFallbackProxyBudget:走代理的预算。实测经本机 Clash 打 token.get 是 6.5s
	// (代理要先把自己那条出境链路建起来),给 10s 留足余量。
	proxyFallbackProxyBudget = 10 * time.Second
	// proxyFallbackSticky:代理救回来之后,接下来多久直接走代理、不再重新探直连。
	//
	// 粘性不是优化,是必需项。AGENTS.md 里 Musixmatch DNS 事故的原话是
	// 「每首歌都要把 DNS/TLS 超时白等一遍」,healthcheck 探两首歌从 7s 涨到 29s。没有粘性
	// 的话这里会原样重演:每个请求先白等 3s 直连再走代理。10 分钟之后重新探一次直连,
	// 网络恢复了就自动回到直连,不需要重启。
	//
	// 这是第一次的窗口;到期重新探直连又失败,窗口翻倍(proxyStickyWindow)。
	proxyFallbackSticky = 10 * time.Minute
	// proxyFallbackStickyMax:窗口翻倍的上限。直连在这台机器上是长期被打掉的(Musixmatch 一周 86 次
	// 「直连失败、代理救回」,每次都先白等 proxyFallbackDirectBudget),固定 10 分钟就是每隔一阵再白等一次;
	// 一直失败就越等越久,上限之后仍会定期探一次,直连恢复了照样回得来。
	proxyFallbackStickyMax = 6 * time.Hour
)

// proxyStickyWindow:第 streak 次连续「直连失败、代理救回」之后走代理多久(10 分钟起,逐次翻倍,封顶
// proxyFallbackStickyMax)。
func proxyStickyWindow(streak int) time.Duration {
	w := proxyFallbackSticky
	for i := 1; i < streak && w < proxyFallbackStickyMax; i++ {
		w *= 2
	}
	return min(w, proxyFallbackStickyMax)
}

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

	// directBudget:直连探路的预算,零值 = proxyFallbackDirectBudget。只有单测改短。
	directBudget time.Duration

	mu          sync.Mutex
	stickyUntil time.Time
	// hintChecked:这个进程里已经看过磁盘提示里有没有这台主机的连续失败计数(见 RoundTrip 直连成功那一支)。
	hintChecked map[string]bool
}

func (t *proxyFallbackTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	// 带 body 且**不能重放**的请求不做 fallback:重试要 req.Clone,而 Clone 不复制 body,
	// 第二次拨过去会是一个空 body 的请求 —— 那种失败比不重试更难查。能重放的(有 GetBody,
	// http.NewRequest 拿 bytes.Reader / strings.Reader 建的都有)每次尝试取一份新 body,见 proxyFallbackSend。
	if req.Body != nil && req.Body != http.NoBody && req.GetBody == nil {
		return t.attemptDirect(req, false)
	}

	host := req.URL.Hostname()

	if t.preferProxy(host) {
		resp, err := t.attempt(t.viaProxy, req, proxyFallbackProxyBudget)
		if err == nil {
			return resp, nil
		}
		// 调用方自己取消 / 到期了(切歌、救急支线被叫停、调用方的时限比代理预算短):那不是代理坏了。
		// 照「代理坏了」处理会把粘性、磁盘提示、连续次数全清掉,之后每个请求又回到先白等 3 秒直连,
		// 还要拿已经失效的 ctx 再去试一次直连、报一次「直连不通」。
		if req.Context().Err() != nil {
			return nil, err
		}
		// 代理自己坏了(用户关掉了 / 换了端口 / 节点挂了):清掉粘性,当场回直连再试一次。
		// 不清的话会一直往一个死代理上撞,而直连说不定早就恢复了。
		t.clearSticky(host)
		log.Printf("proxy: %s failed via proxy (%v), clearing sticky proxy and retrying direct", host, err)
		resp, err = t.attemptDirect(req, false)
		if err != nil {
			t.reportBlocked()
		}
		return resp, err
	}

	directStart := time.Now()
	resp, directErr := t.attemptDirect(req, !systemProxyKnownAbsent())
	directElapsed := time.Since(directStart)
	if directErr == nil {
		// 窗口到期、重新探直连通了:连续失败次数清零,下次再被打掉从 10 分钟重新算。粘性要是上一个进程
		// 设的(只在磁盘提示里),这个进程的 hadSticky 看不到它 —— 每台主机头一回直连成功时去提示里看一眼,
		// 不然留在那里的连续次数不清,下一次被打掉窗口直接从一个很大的倍数起跳。
		if t.hadSticky() || t.hintStreakPending(host) {
			t.clearSticky(host)
		}
		return resp, nil
	}
	// 直连失败但失败的原因是调用方自己取消 / 到期:不是「直连不通」,不试代理、也不报 blocked
	// (那个原因常驻进程里从不清除,一次就会让 Musixmatch 这一路一直不进别名重查)。
	if req.Context().Err() != nil {
		return nil, directErr
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
		// 这一行不能省。返回值里只会带**直连**那次的错(上层真正关心的是我们本来想走
		// 的那条路怎么了),代理那次的错在返回值里是拿不到的 —— 不在这里记一行,"兜底为什么
		// 也没兜住"就彻底不可观测。装机验证时正是缺了它,才没法一眼看出第一首
		// 探测曲的代理那半边是超时还是被代理拒了。
		warnf("proxy: %s direct failed (%v, %s), then failed via system proxy %s too (%v, %s)",
			host, directErr, directElapsed.Round(time.Millisecond),
			proxy.Host, proxyErr, time.Since(proxyStart).Round(time.Millisecond))
		return nil, directErr
	}
	window := t.markSticky(host)
	log.Printf("proxy: %s direct failed (%v, %s), succeeded via system proxy %s (%s), using the proxy for the next %s",
		host, directErr, directElapsed.Round(time.Millisecond), proxy.Host,
		time.Since(proxyStart).Round(time.Millisecond), window)
	return resp, nil
}

// attempt 跑一次 RoundTrip,并给它单独一份预算(整段请求,含读响应体)。
//
// 预算必须落在**每次尝试**上,不能靠 http.Client.Timeout —— 那是把直连和代理两次尝试
// 算进同一个预算里,直连一超时就没钱给代理重试了,fallback 等于没加。dohHTTPClient 因此
// 刻意不设 Client.Timeout,头注里也写着别加回去。
func (t *proxyFallbackTransport) attempt(rt http.RoundTripper, req *http.Request, budget time.Duration) (*http.Response, error) {
	ctx, cancel := context.WithTimeout(req.Context(), budget)
	return proxyFallbackSend(ctx, rt, req, cancel)
}

// attemptDirect 跑一次直连。fallback:直连不通时后面还有代理可退。
//
// 直连的预算只为判「直连通不通」,而不通的样子是连接建不起来(SYN 石沉大海、TLS 握手卡住):
//   - 调用方 ctx 上有时限、后面有代理可退:预算只管到拿到连接为止,拿到就停表。之后服务器自己处理得慢(ListenBrainz
//     慢的时候三五秒才回)交给调用方的时限 —— 那不是直连被打掉,按整段请求掐表的话会把同一个请求经代理再发一遍,
//     还把这台主机钉到代理上(最长 6 小时)。
//   - 有时限、没有代理可退(没有可用的系统代理、代理失败后回直连那一次、body 不能重放):不另设预算,早掐只会更差。
//   - 调用方没设时限:照旧整段请求限一个预算,不让连上了却一直不回话的服务器把调用方挂着。
func (t *proxyFallbackTransport) attemptDirect(req *http.Request, fallback bool) (*http.Response, error) {
	budget := t.directBudget
	if budget <= 0 {
		budget = proxyFallbackDirectBudget
	}
	if _, ok := req.Context().Deadline(); !ok {
		return t.attempt(t.direct, req, budget)
	}
	if !fallback {
		return proxyFallbackSend(req.Context(), t.direct, req, func() {})
	}
	ctx, cancel := context.WithCancel(req.Context())
	var expired atomic.Bool
	timer := time.AfterFunc(budget, func() {
		expired.Store(true)
		cancel()
	})
	ctx = httptrace.WithClientTrace(ctx, &httptrace.ClientTrace{GotConn: func(httptrace.GotConnInfo) { timer.Stop() }})
	resp, err := proxyFallbackSend(ctx, t.direct, req, func() {
		timer.Stop()
		cancel()
	})
	if err != nil && expired.Load() && req.Context().Err() == nil {
		// 预算是拿 cancel 掐的,原样往上报就成了「调用方自己取消」,doHTTPTracked 会把它当成不算数的取消。
		return nil, fmt.Errorf("no connection within %s: %w", budget, context.DeadlineExceeded)
	}
	return resp, err
}

// proxyFallbackSend 拿 ctx 发一份 req 的副本,能重放的 body 每次取新的一份。release 在出错时、或调用方关掉响应体时调一次。
func proxyFallbackSend(ctx context.Context, rt http.RoundTripper, req *http.Request, release func()) (*http.Response, error) {
	clone := req.Clone(ctx)
	if req.GetBody != nil {
		body, err := req.GetBody()
		if err != nil {
			release()
			return nil, err
		}
		clone.Body = body
	}
	resp, err := rt.RoundTrip(clone)
	if err != nil {
		release()
		return nil, err
	}
	// release 不能在这里调:ctx 一取消,还没读的 resp.Body 立刻断流(表现是调用方
	// io.ReadAll 拿到 "context canceled",看起来像服务器提前关了连接)。挂到 Body 上,
	// 等调用方 Close 了再释放 —— 这是 net/http 自己对付 Client.Timeout 的办法
	// (cancelTimerBody),不是这里发明的写法。
	resp.Body = &proxyFallbackBody{ReadCloser: resp.Body, cancel: release}
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

// markSticky 记下「接下来走代理」,返回这次的窗口(按连续失败次数翻倍,见 proxyStickyWindow)。
func (t *proxyFallbackTransport) markSticky(host string) time.Duration {
	window := saveProxyFallbackHint(host, true)
	t.mu.Lock()
	t.stickyUntil = time.Now().Add(window)
	t.mu.Unlock()
	return window
}

// hintStreakPending:这台主机在磁盘提示里还记着连续失败次数,而且这个进程还没看过它。每台主机只读一次文件。
func (t *proxyFallbackTransport) hintStreakPending(host string) bool {
	t.mu.Lock()
	if t.hintChecked[host] {
		t.mu.Unlock()
		return false
	}
	if t.hintChecked == nil {
		t.hintChecked = map[string]bool{}
	}
	t.hintChecked[host] = true
	t.mu.Unlock()
	f := readProxyFallbackHint()
	_, hasHost := f.Hosts[host]
	return f.Streak[host] > 0 || hasHost
}

// hadSticky:这个进程里走代理的窗口设过、而且已经到期(这一次是到期后重新探直连)。
func (t *proxyFallbackTransport) hadSticky() bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	return !t.stickyUntil.IsZero() && !time.Now().Before(t.stickyUntil)
}

func (t *proxyFallbackTransport) clearSticky(host string) {
	t.mu.Lock()
	t.stickyUntil = time.Time{}
	t.mu.Unlock()
	saveProxyFallbackHint(host, false)
}

// ---- 跨进程的"这个域名现在得走代理"提示 ----
//
// 为什么要落盘:引擎有常驻进程,也有一堆一次性 CLI 子命令(search-lyrics /
// test-lyric-sources / healthcheck),后者每次都是全新进程、内存里的粘性一律归零,于是每跑
// 一次都要重新白等一遍直连探路。而「联网搜索候选歌词」和设置页那颗「测试」按钮都在这条路上,
// 用户是当场盯着等的 —— 3 秒 × 每个请求,一轮下来就是十几秒的空等。
//
// 这只是一份**提示**,不是权威状态:读到了也仍然要确认代理连得上(preferProxy),读不到最多
// 多探一次直连。所以两个进程同时写导致丢一条更新是可以接受的,不值得为它上文件锁。
type proxyFallbackHintFile struct {
	// Hosts: host -> 最近一次"代理把它救回来了"的 unix 秒。老版本只认这一项(按 proxyFallbackSticky 算到期)。
	Hosts map[string]int64 `json:"hosts"`
	// Until: host -> 走代理到什么时候(unix 秒);有它就按它,没有退回 Hosts + proxyFallbackSticky。
	Until map[string]int64 `json:"until,omitempty"`
	// Streak: host -> 连续几次「直连失败、代理救回」,算下一次的窗口(proxyStickyWindow)。
	Streak map[string]int `json:"streak,omitempty"`
}

func proxyFallbackHintPath() string {
	if configDir() == "" {
		return ""
	}
	return filepath.Join(configDir(), clientName+"-proxy-hint.json")
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
	f := readProxyFallbackHint()
	if until, ok := f.Until[host]; ok {
		return time.Now().Before(time.Unix(until, 0))
	}
	at, ok := f.Hosts[host]
	if !ok {
		return false
	}
	return time.Since(time.Unix(at, 0)) < proxyFallbackSticky
}

// saveProxyFallbackHint 记下 / 清掉「这个域名走代理」。useProxy 时连续失败次数 +1、按它算窗口并返回;
// 清掉时连续次数一并清零。提示文件写不了(没有配置目录)时窗口就是 proxyFallbackSticky。
func saveProxyFallbackHint(host string, useProxy bool) time.Duration {
	window := proxyFallbackSticky
	path := proxyFallbackHintPath()
	if path == "" {
		return window
	}
	f := readProxyFallbackHint()
	if f.Until == nil {
		f.Until = map[string]int64{}
	}
	if f.Streak == nil {
		f.Streak = map[string]int{}
	}
	if useProxy {
		now := time.Now()
		f.Streak[host]++
		window = proxyStickyWindow(f.Streak[host])
		f.Hosts[host] = now.Unix()
		f.Until[host] = now.Add(window).Unix()
	} else {
		delete(f.Hosts, host)
		delete(f.Until, host)
		delete(f.Streak, host)
	}
	raw, err := json.Marshal(f)
	if err != nil {
		return window
	}
	// 目录一般早就有了(config.json 就在里面),但不能假定 —— 全新机器上第一次跑到这里
	// 时它还不存在,os.WriteFile 不会自己建,于是提示**静默**写不下去、跨进程粘性形同虚设
	// (由 TestProxyFallbackUsesProxyWhenDirectFails 当场抓到)。
	if os.MkdirAll(filepath.Dir(path), 0o700) != nil {
		return window
	}
	// tmp + rename,临时文件名带进程号 —— 跟 musixmatchSaveTokenFile 同一个理由:并发的
	// 两个写入方不能互相覆盖同一个 tmp,否则 rename 出去的可能是半份别人的内容。
	_ = writeFileAtomic(path, raw)
	return window
}
