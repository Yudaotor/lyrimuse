// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"bytes"
	"context"
	_ "image/jpeg" // 注册 JPEG 解码器
	_ "image/png"  // 网易云取色缩略图有时是 PNG(content-type 却谎报 jpg)
	"log"
	"net/http"
	"time"
)

// alerter 推送一条通知。platform 决定 push() 怎么拼 body/URL——见 notify.go 的
// buildNotifyPayload/dingtalkSignedURL/feishuSign。
//
// 2026-07-20:去掉了 ok()/fail() 这套"故障告警"(连续失败 N 次才推、恢复时再推一次)——
// 用户反馈"压根不需要告警故障了",这是彻底删掉这个能力,不是简化成默认开启(跟同一天
// 删掉的其它几个开关不一样)。weeklyDigestPush 还在用这个类型的 push(),那部分保留。
type alerter struct {
	platform       string
	url            string
	dingtalkSecret string
	feishuSecret   string
}

func newAlerter(platform, url, dingtalkSecret, feishuSecret string) *alerter {
	return &alerter{
		platform: platform, url: url,
		dingtalkSecret: dingtalkSecret, feishuSecret: feishuSecret,
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
