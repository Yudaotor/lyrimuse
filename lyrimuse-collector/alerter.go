// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"bytes"
	"context"
	"fmt"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"log"
	"net/http"
	neturl "net/url"
	"time"
)

// alerter 推送一条通知。platform 决定 push() 怎么拼 body/URL——见 notify.go 的
// buildNotifyPayload/dingtalkSignedURL/feishuSign。这里不再有故障告警(连续失败 N
// 次才推、恢复时再推一次)的 ok()/fail() 逻辑,该能力已整体下线;weeklyDigestPush
// 仍复用这个类型的 push()。
type alerter struct {
	platform       string
	url            string
	dingtalkSecret string
	feishuSecret   string
	telegramChatID string
}

func newAlerter(platform, url, dingtalkSecret, feishuSecret, telegramChatID string) *alerter {
	return &alerter{
		platform: platform, url: url,
		dingtalkSecret: dingtalkSecret, feishuSecret: feishuSecret,
		telegramChatID: telegramChatID,
	}
}

// alerterPushTimeout：一次推送的总预算。Telegram 要够「直连探路 + 走系统代理」两次尝试
// (proxyFallbackDirectBudget + proxyFallbackProxyBudget)。
const (
	alerterPushTimeout         = 8 * time.Second
	alerterTelegramPushTimeout = proxyFallbackDirectBudget + proxyFallbackProxyBudget + 2*time.Second
)

// telegramHTTPClient：api.telegram.org 在一部分网络里直连不通，先直连、不通再走 macOS
// 系统代理(proxyfallback.go)。其余平台照旧 http.DefaultClient。不设 Client.Timeout，
// 理由同 dohHTTPClient：预算落在每次尝试上。
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

// push 发一条推送。返回 nil 才算平台收下了;调用方据此决定要不要记「已推送」。
func (a *alerter) push(title, body string) error {
	payload, contentType, err := buildNotifyPayload(a.platform, title, body, a.feishuSecret, a.telegramChatID)
	if err != nil {
		return err
	}
	target, client, timeout := a.url, http.DefaultClient, alerterPushTimeout
	switch a.platform {
	case platformDingtalk:
		target = dingtalkSignedURL(a.url, a.dingtalkSecret)
	case platformTelegram:
		target, client, timeout = telegramSendURL(a.url), telegramHTTPClient, alerterTelegramPushTimeout
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, target, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", contentType)
	resp, err := doHTTPTracked(client, req)
	if err != nil {
		log.Printf("notify push failed (platform=%s): %v", a.platform, err)
		return err
	}
	resp.Body.Close()
	// 平台拒收(地址 / Token / Chat ID 填错)只看得见状态码，不记响应体。
	if resp.StatusCode >= 300 {
		log.Printf("notify push rejected (platform=%s): status %d", a.platform, resp.StatusCode)
		return fmt.Errorf("notify push rejected: status %d", resp.StatusCode)
	}
	return nil
}
