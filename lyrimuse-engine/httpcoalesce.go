package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"sort"
	"strings"
	"sync"
)

// 同一时刻完全相同的歌词源请求只发一次。救急别名并发(rescuefanout.go)几支同时跑时,不同别名常常搜到同一首,
// 接下来按同一个曲目 id 取词、按同一个平台 id 取 amll 的请求就是一模一样的;各发一次既白占令牌与在途名额,
// 又会叠出服务端限流。
//
// 只合并**同时在途**的(不是缓存):第一个真的发出去,响应体整个读下来,同时在等的几个拿同一份的副本 ——
// 它们不经过出站闸、不占名额、不进审计汇总(本来就没发出去)。范围:发往歌词源主机的 GET,URL 与请求头
// 逐字相同才算同一个请求。发出去的那个请求因为自己的 ctx 被取消而失败时(它所在的支线被停掉了),等它的
// 那几个 ctx 还活着就各自重发,不跟着失败。响应体超过 httpCoalesceMaxBody 不共享,等的那几个各自重发。
// 见 09 章决策 102 第七批。
const httpCoalesceMaxBody = 8 << 20

type coalescedCall struct {
	done   chan struct{}
	resp   *http.Response // 只取状态行与头,Body 用 body
	body   []byte
	shared bool // false:没有可共享的结果(出错 / 太大),等的人自己发
	err    error
	// leaderCanceled:发出去的那个是被**它自己的** ctx 取消 / 到期的(它所在的支线被叫停了)。只有这种失败
	// 等的人才各自重发;源自己的超时(http.Client.Timeout,错误同样是 DeadlineExceeded)、连接失败这些
	// 是这个源此刻的真实状态,共享给等的人 —— 各自重发只会同时再打出 N 个一模一样的请求、各等一整个超时。
	leaderCanceled bool
}

var (
	httpCoalesceMu       sync.Mutex
	httpCoalesceInflight = map[string]*coalescedCall{}
	// httpCoalesceHostOK 只为单测可换(httptest 服务器在回环地址上,不是歌词源主机)。
	httpCoalesceHostOK = func(host string) bool { return lyricSourceForHost(host) != "" }
)

func httpCoalesceKey(req *http.Request) (string, bool) {
	if req.Method != http.MethodGet || req.Body != nil && req.Body != http.NoBody {
		return "", false
	}
	if !httpCoalesceHostOK(guardHost(req.URL)) {
		return "", false
	}
	var b strings.Builder
	b.WriteString(req.URL.String())
	names := make([]string, 0, len(req.Header))
	for k := range req.Header {
		names = append(names, k)
	}
	sort.Strings(names)
	for _, k := range names {
		b.WriteString("\x00" + k + "=" + strings.Join(req.Header[k], "\x01"))
	}
	return b.String(), true
}

// doHTTPTracked:所有对外请求的统一出口(审计、出站闸、在途名额都在 doHTTPTrackedOnce 里),外加同 URL 合并。
func doHTTPTracked(cli *http.Client, req *http.Request) (*http.Response, error) {
	key, ok := httpCoalesceKey(req)
	if !ok {
		return doHTTPTrackedOnce(cli, req)
	}
	httpCoalesceMu.Lock()
	if c, running := httpCoalesceInflight[key]; running {
		httpCoalesceMu.Unlock()
		select {
		case <-c.done:
		case <-req.Context().Done():
			return nil, req.Context().Err()
		}
		if c.shared {
			noteCoalescedReached(req, c.resp.StatusCode)
			return coalescedResponse(c, req), nil
		}
		// 发出去的那个被它自己的 ctx 取消了、或者响应不能共享(太大):自己的 ctx 还活着就重来一遍 ——
		// 仍走合并,几个一起重发的只发一次。
		if c.err != nil && !c.leaderCanceled {
			return nil, c.err
		}
		return doHTTPTracked(cli, req)
	}
	c := &coalescedCall{done: make(chan struct{})}
	httpCoalesceInflight[key] = c
	httpCoalesceMu.Unlock()

	resp, err := doHTTPTrackedOnce(cli, req)
	finish := func() {
		httpCoalesceMu.Lock()
		delete(httpCoalesceInflight, key)
		httpCoalesceMu.Unlock()
		close(c.done)
	}
	if err != nil {
		c.err, c.leaderCanceled = err, leaderCtxEnded(req, err)
		finish()
		return nil, err
	}
	body, readErr := io.ReadAll(io.LimitReader(resp.Body, httpCoalesceMaxBody+1))
	if readErr != nil || len(body) > httpCoalesceMaxBody {
		// 读不完整 / 太大:不共享;自己这份把读到的与剩下的接起来原样交回。
		rest := resp.Body
		resp.Body = struct {
			io.Reader
			io.Closer
		}{io.MultiReader(bytes.NewReader(body), rest), rest}
		c.err = readErr
		c.leaderCanceled = readErr != nil && leaderCtxEnded(req, readErr)
		finish()
		return resp, nil
	}
	resp.Body.Close()
	c.resp, c.body, c.shared = resp, body, true
	finish()
	return coalescedResponse(c, req), nil
}

// leaderCtxEnded:这次失败是不是发出去的那个自己的 ctx 结束造成的。只看错误类型不够 ——
// http.Client.Timeout 到点报的也是 DeadlineExceeded,那是源慢,不是调用方不要了。
func leaderCtxEnded(req *http.Request, err error) bool {
	if req.Context().Err() == nil {
		return false
	}
	return errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded)
}

// noteCoalescedReached:等到共享结果的那个也算这一轮「连上过这个源」。它没真发请求,doHTTPTrackedOnce 里那处
// markReached 管不到它 —— 一轮里连上的恰好都是等别人结果的那几个时,这一轮会被误判成一个源都没连上。
func noteCoalescedReached(req *http.Request, status int) {
	if status >= 500 || status == http.StatusTooManyRequests {
		return
	}
	if src := lyricSourceForHost(req.URL.Host); src != "" {
		lyricSourceRoundFrom(req.Context()).markReached(src)
	}
}

// coalescedResponse:共享结果的一份独立副本(头复制一份、正文各读各的)。
func coalescedResponse(c *coalescedCall, req *http.Request) *http.Response {
	r := *c.resp
	r.Header = c.resp.Header.Clone()
	r.Body = io.NopCloser(bytes.NewReader(c.body))
	r.ContentLength = int64(len(c.body))
	r.Request = req
	return &r
}
