// Command collector watches the macOS system now-playing state via
// media-control and submits playing_now / listen events to ListenBrainz.
package main

import (
	"bytes"
	"context"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"log"
	"net/http"
	"sync"
	"time"
)

// alerter pushes a push-notification when a component (media-control /
// relay) fails alertThreshold times in a row, and once more when it
// recovers. No-op when url is empty. platform 决定 push() 怎么拼 body/URL——
// 见 notify.go 的 buildNotifyPayload/dingtalkSignedURL/feishuSign。
type alerter struct {
	platform       string
	url            string
	dingtalkSecret string
	feishuSecret   string
	mu             sync.Mutex
	fails          map[string]int
	firing         map[string]bool
}

const alertThreshold = 4

func newAlerter(platform, url, dingtalkSecret, feishuSecret string) *alerter {
	return &alerter{
		platform: platform, url: url,
		dingtalkSecret: dingtalkSecret, feishuSecret: feishuSecret,
		fails: map[string]int{}, firing: map[string]bool{},
	}
}

func (a *alerter) ok(component string) {
	if a == nil || a.url == "" {
		return
	}
	a.mu.Lock()
	recovered := a.firing[component]
	a.firing[component] = false
	a.fails[component] = 0
	a.mu.Unlock()
	if recovered {
		a.push("采集器已恢复", component+" 恢复正常，显示已回到实时")
	}
}

func (a *alerter) fail(component, detail string) {
	if a == nil || a.url == "" {
		return
	}
	a.mu.Lock()
	a.fails[component]++
	fire := a.fails[component] == alertThreshold && !a.firing[component]
	if fire {
		a.firing[component] = true
	}
	a.mu.Unlock()
	if fire {
		a.push("采集器异常", detail)
	}
}

func (a *alerter) push(title, body string) {
	payload, contentType, err := buildNotifyPayload(a.platform, title, body, a.feishuSecret)
	if err != nil {
		return
	}
	target := a.url
	if a.platform == platformDingtalk {
		target = dingtalkSignedURL(a.url, a.dingtalkSecret)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, target, bytes.NewReader(payload))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", contentType)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		log.Printf("notify push failed (platform=%s): %v", a.platform, err)
		return
	}
	resp.Body.Close()
}
