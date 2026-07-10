// Command collector watches the macOS system now-playing state via
// media-control and submits playing_now / listen events to ListenBrainz.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"log"
	"net/http"
	"sync"
	"time"
)

// alerter pushes a Bark notification when a component (media-control /
// relay) fails alertThreshold times in a row, and once more when it
// recovers. No-op when url is empty.
type alerter struct {
	url    string
	mu     sync.Mutex
	fails  map[string]int
	firing map[string]bool
}

const alertThreshold = 4

func newAlerter(url string) *alerter {
	return &alerter{url: url, fails: map[string]int{}, firing: map[string]bool{}}
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
	payload, err := json.Marshal(map[string]any{
		"title": title, "body": body, "group": "nowplaying", "level": "active",
	})
	if err != nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.url, bytes.NewReader(payload))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		log.Printf("bark push failed: %v", err)
		return
	}
	resp.Body.Close()
}
