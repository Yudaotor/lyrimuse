package main

import (
	"bytes"
	"context"
	"errors"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"io"
	"log"
	"net/http"
	neturl "net/url"
	"time"
)

// alerter 把一条消息推到这个事件该去的那些渠道(notifychannel.go)。每个平台怎么拼请求见 notify.go,
// 怎么判断平台收没收下见 notifyresult.go,每一次推送记进推送记录(notifylog.go)。这里不再有故障告警
// (连续失败 N 次才推、恢复时再推一次)的 ok()/fail() 逻辑,该能力已整体下线。
type alerter struct {
	channels []notifyChannel
	routes   map[string][]string
}

func alerterFromConfig(c *config) *alerter {
	return &alerter{channels: configNotifyChannels(c), routes: c.NotificationRoutes}
}

// newAlerter 拼一个只有一个渠道的 alerter(单测用,跟旧的单渠道字段同一套参数)。
func newAlerter(platform, url, dingtalkSecret, feishuSecret, telegramChatID string) *alerter {
	return alerterFromConfig(&config{NotificationPlatform: platform, NotificationWebhookURL: url,
		DingtalkSignSecret: dingtalkSecret, FeishuSignSecret: feishuSecret, TelegramChatID: telegramChatID})
}

// configured:这个事件有没有能推的渠道。
func (a *alerter) configured(event string) bool {
	return a != nil && len(routedNotifyChannels(a.channels, a.routes, event)) > 0
}

// errNoNotifyChannel:这个事件没有能推的渠道。
var errNoNotifyChannel = errors.New("notify: no enabled channel for this event")

// send 把一条消息推到 event 该去的每个渠道,每个渠道的结果记进推送记录。至少一个渠道收下就返回 nil,调用方据此
// 记「已推送」:再推一遍的话收下的那几个会收到两份。一个都没收下才返回错误,下次检查整条重推。
func (a *alerter) send(event, title, body string) error {
	if a == nil {
		return errNoNotifyChannel
	}
	targets := routedNotifyChannels(a.channels, a.routes, event)
	if len(targets) == 0 {
		return errNoNotifyChannel
	}
	var firstErr error
	delivered := false
	for _, ch := range targets {
		msg := notifyMessage{Event: event, Title: title, Body: body}
		r := pushToChannel(ch, msg)
		recordNotifyDelivery(ch, msg, r)
		if r.OK {
			delivered = true
		} else if firstErr == nil {
			firstErr = r.err()
		}
	}
	if delivered {
		return nil
	}
	return firstErr
}

// push 推一条不属于任何事件的消息(推到全部启用的渠道)。单测用。
func (a *alerter) push(title, body string) error { return a.send("", title, body) }

// notifyMessage 是要推的一条消息。
type notifyMessage struct {
	Event, Title, Body string
}

// alerterPushTimeout:一次推送的总预算。Telegram 要够「直连探路 + 走系统代理」两次尝试
// (proxyFallbackDirectBudget + proxyFallbackProxyBudget)。
const (
	alerterPushTimeout         = 8 * time.Second
	alerterTelegramPushTimeout = proxyFallbackDirectBudget + proxyFallbackProxyBudget + 2*time.Second
	// notifyResponseMaxBytes:读多少响应体来判断平台收没收下(业务错误码都在开头那点 JSON 里)。
	notifyResponseMaxBytes = 64 << 10
)

// telegramHTTPClient:api.telegram.org 在一部分网络里直连不通,先直连、不通再走 macOS
// 系统代理(proxyfallback.go)。其余平台照旧 http.DefaultClient。不设 Client.Timeout,
// 理由同 dohHTTPClient:预算落在每次尝试上。
var telegramHTTPClient = &http.Client{
	Transport: &proxyFallbackTransport{
		direct: &http.Transport{
			TLSHandshakeTimeout: 10 * time.Second,
			ForceAttemptHTTP2:   true,
		},
		viaProxy: &http.Transport{
			Proxy:               func(*http.Request) (*neturl.URL, error) { return systemProxyURL(), nil },
			TLSHandshakeTimeout: 10 * time.Second,
			ForceAttemptHTTP2:   true,
		},
	},
}

// pushToChannel 往一个渠道发一条消息,返回平台收没收下、没收下的话是哪一类原因。不记推送记录(调用方记)。
func pushToChannel(ch notifyChannel, msg notifyMessage) notifyResult {
	start := time.Now()
	if !ch.complete() {
		return notifyResult{Kind: notifyKindConfig, Detail: "channel is missing its address or chat id"}
	}
	nr, err := buildNotifyRequest(ch, msg)
	if err != nil {
		return notifyResult{Kind: notifyKindConfig, Detail: err.Error()}
	}
	client, timeout := http.DefaultClient, alerterPushTimeout
	if ch.Platform == platformTelegram {
		client, timeout = telegramHTTPClient, alerterTelegramPushTimeout
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, nr.target, bytes.NewReader(nr.body))
	if err != nil {
		return notifyResult{Kind: notifyKindConfig, Detail: "bad address"}
	}
	req.Header.Set("Content-Type", nr.contentType)
	for k, v := range nr.headers {
		req.Header.Set(k, v)
	}
	resp, err := doHTTPTracked(client, req)
	if err != nil {
		warnf("notify push failed (platform=%s): %v", ch.Platform, err)
		return notifyResult{Kind: notifyKindNetwork, Detail: scrubSecrets(networkErrorDetail(err)), Elapsed: time.Since(start)}
	}
	body, _ := io.ReadAll(io.LimitReader(resp.Body, notifyResponseMaxBytes))
	resp.Body.Close()
	r := classifyNotifyResponse(ch.Platform, resp.StatusCode, body)
	r.Elapsed = time.Since(start)
	if !r.OK {
		// 只记平台、类别、状态码和错误码,不记响应体(里面可能回显了消息正文)。
		log.Printf("notify push rejected (platform=%s): status %d kind=%s code=%s", ch.Platform, resp.StatusCode, r.Kind, r.Code)
	}
	return r
}

// networkErrorDetail:传输层错误的简短说法,不带请求地址(地址里有令牌)。
func networkErrorDetail(err error) string {
	var ue *neturl.Error
	if errors.As(err, &ue) {
		return ue.Err.Error()
	}
	return err.Error()
}
