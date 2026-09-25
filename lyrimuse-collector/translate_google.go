package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	neturl "net/url"
	"strings"
	"sync"
	"time"
)

// Google 网页翻译的无 key 端点,网络翻译的第一家(链路顺序见 translate.go 头注)。
//
// client 参数必须是 dict-chrome-ex,别换成 gtx:gtx 实测被 429 拒。这是未公开端点,
// 随时可能失效 —— 失效时只冷却这一家、退回 MyMemory,译文功能本身不受影响。
//
// 空串 = 跳过这一家。单测在 TestMain 里置空,要测它的用例自己指向假服务器。
var googleTranslateEndpoint = "https://translate.googleapis.com/translate_a/single"

const (
	// 走 POST 表单,不受 URL 长度限制;实测单次约 8000 字符仍正常返回、行数对齐。
	// 取 6000 字节,常规一首歌一次请求就够。
	googleTranslateMaxChunkBytes = 6000
	googleTranslateMaxChunks     = 4
	// 服务层失败(传输错误 / 非 200 / 返回形状不对)后这一家停用多久。某批内容没翻出来
	// 不算失败、不冷却 —— 那不是服务挂了,冷却它只会让后面能翻的歌也白白绕去 MyMemory。
	googleTranslateCooldown = 30 * time.Minute
	// 实测目前不带 UA 也通;带浏览器 UA 是少一个被当成脚本拦截的理由。
	googleTranslateUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
)

// errGoogleTranslateSkipped:这次没去请求(端点置空 / 冷却中 / 没东西可翻)。调用方安静
// 地走下一家,不记日志。
var errGoogleTranslateSkipped = errors.New("google translate skipped")

var (
	googleTranslateMu        sync.Mutex
	googleTranslateCoolUntil time.Time
)

func googleTranslateCooling(now time.Time) bool {
	googleTranslateMu.Lock()
	defer googleTranslateMu.Unlock()
	return now.Before(googleTranslateCoolUntil)
}

func tripGoogleTranslateCooldown(now time.Time) {
	googleTranslateMu.Lock()
	googleTranslateCoolUntil = now.Add(googleTranslateCooldown)
	googleTranslateMu.Unlock()
}

// googleTranslateLines 把 lines 翻成 target,返回与 lines 等长的结果。target 用
// myMemoryLangCode 的写法(zh-CN / zh-TW / 两位代码),Google 认同一套。
//
// 某块行数对不上时那一块原样返回原文 —— 跟 MyMemory 那条同一个规矩:错位的译文比没有
// 译文更糟。原文行会被 assembleTranslationLRC 当作"没翻动"跳过。
func googleTranslateLines(ctx context.Context, hc *http.Client, lines []string, target string) ([]string, error) {
	if googleTranslateEndpoint == "" || target == "" || len(lines) == 0 {
		return nil, errGoogleTranslateSkipped
	}
	if googleTranslateCooling(time.Now()) {
		return nil, errGoogleTranslateSkipped
	}
	chunks := chunkLinesByBytes(lines, googleTranslateMaxChunkBytes)
	if len(chunks) > googleTranslateMaxChunks {
		return nil, fmt.Errorf("lyrics too long: %d chunks", len(chunks))
	}
	out := make([]string, 0, len(lines))
	for _, chunk := range chunks {
		got, err := googleTranslateChunk(ctx, hc, chunk, target)
		if err != nil {
			// 上层超时 / 取消不是这家服务的问题。
			if ctx.Err() == nil {
				tripGoogleTranslateCooldown(time.Now())
			}
			return nil, err
		}
		if len(got) != len(chunk) {
			got = chunk
		}
		out = append(out, got...)
	}
	return out, nil
}

// googleTranslateChunk 发一次请求。返回 error 只代表服务层失败;服务正常但没给出译文时
// 原样返回 lines(内容问题,不该触发冷却)。
func googleTranslateChunk(ctx context.Context, hc *http.Client, lines []string, target string) ([]string, error) {
	q := neturl.Values{}
	q.Set("client", "dict-chrome-ex")
	q.Set("sl", "auto")
	q.Set("tl", target)
	q.Set("dt", "t")
	form := neturl.Values{}
	form.Set("q", strings.Join(lines, "\n"))
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		googleTranslateEndpoint+"?"+q.Encode(), strings.NewReader(form.Encode()))
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded;charset=utf-8")
	req.Header.Set("User-Agent", googleTranslateUserAgent)
	resp, err := doHTTPTracked(hc, req)
	if err != nil {
		return nil, fmt.Errorf("google translate: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("google translate status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, fmt.Errorf("read google translate response: %w", err)
	}
	text, err := parseGoogleTranslateResponse(body)
	if err != nil {
		return nil, err
	}
	if text == "" {
		return lines, nil
	}
	return strings.Split(text, "\n"), nil
}

// parseGoogleTranslateResponse 取出拼好的译文。返回形状是嵌套数组:
//
//	[[["译文段","原文段",...], ["译文段","原文段",...]], null, "ja", ...]
//
// 长文本会被切成多段,每段译文在该段下标 0,按顺序拼起来才是整份译文(换行在段内保留)。
// 只拿第一段会丢掉后面所有行、让行数校验把整块判废。
// 形状不对返回 error;形状对但没有译文(第一个元素是 null)返回空串。
func parseGoogleTranslateResponse(body []byte) (string, error) {
	var top []json.RawMessage
	if err := json.Unmarshal(body, &top); err != nil || len(top) == 0 {
		return "", fmt.Errorf("decode google translate response: unexpected shape")
	}
	var segs [][]json.RawMessage
	if err := json.Unmarshal(top[0], &segs); err != nil {
		return "", fmt.Errorf("decode google translate segments: %w", err)
	}
	var b strings.Builder
	for _, seg := range segs {
		if len(seg) == 0 {
			continue
		}
		var s string
		if json.Unmarshal(seg[0], &s) == nil {
			b.WriteString(s)
		}
	}
	return b.String(), nil
}
