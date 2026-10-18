package main

import (
	"encoding/json"
	"strings"
)

// 推送渠道(config.json 的 notification_channels):想推到几个地方就配几个,各自启用 / 停用,一个可以设为默认。
// 原来只有一个渠道,字段散在顶层(notification_platform、bark_url、dingtalk_sign_secret、feishu_sign_secret、
// telegram_chat_id);那套旧字段在还没有渠道列表时照读,当成一个渠道(configNotifyChannels),旧配置不用迁移也照常推。
// App 读到旧配置时把它写成渠道列表,旧字段留在文件里不删(装回旧版还能用)。所以「有没有渠道列表」看的是
// notification_channels 这个键在不在,不是列表空不空:用户把渠道删光了是 [],不能退回去读旧字段、把删掉的那个推送复活。
// 整体设计见 15 章决策 60。

// notifyChannel 是一个推送渠道。Secret 按平台是不同的东西:钉钉加签密钥、飞书签名密钥、ntfy 访问令牌、
// 通用 Webhook 的签名密钥;其余平台不用。ChatID 只有 Telegram 用。
type notifyChannel struct {
	ID       string `json:"id"`
	Name     string `json:"name,omitempty"`
	Platform string `json:"platform"`
	URL      string `json:"url"`
	Secret   string `json:"secret,omitempty"`
	ChatID   string `json:"chat_id,omitempty"`
	Enabled  bool   `json:"enabled"`
	Default  bool   `json:"default,omitempty"`
}

// legacyNotifyChannelID:从旧的单渠道字段拼出来的那个渠道的 id。
const legacyNotifyChannelID = "legacy"

// 推送的事件。config.json 的 notification_routes 按它选渠道。
const (
	notifyEventDaily     = "daily_digest"
	notifyEventWeekly    = "weekly_digest"
	notifyEventMonthly   = "monthly_digest"
	notifyEventYearly    = "yearly_digest"
	notifyEventMilestone = "milestone"
	notifyEventTest      = "test"
)

// trimmed:地址、密钥、Chat ID 去掉首尾空白(粘贴进来的常带换行),同 config.trimCredentials。
func (ch notifyChannel) trimmed() notifyChannel {
	ch.URL, ch.Secret, ch.ChatID = strings.TrimSpace(ch.URL), strings.TrimSpace(ch.Secret), strings.TrimSpace(ch.ChatID)
	if ch.Platform == "" {
		ch.Platform = platformBark
	}
	return ch
}

// complete:填齐了能发(启用与否另算)。Telegram 还要 Chat ID。
func (ch notifyChannel) complete() bool {
	return ch.URL != "" && (ch.Platform != platformTelegram || ch.ChatID != "")
}

// configNotifyChannels:这份配置里的推送渠道。有渠道列表就用它;没有时把旧的单渠道字段当成一个渠道。
func configNotifyChannels(c *config) []notifyChannel {
	if c == nil {
		return nil
	}
	if c.NotificationChannels != nil {
		out := make([]notifyChannel, 0, len(c.NotificationChannels))
		for _, ch := range c.NotificationChannels {
			out = append(out, ch.trimmed())
		}
		return out
	}
	if c.NotificationWebhookURL == "" {
		return nil
	}
	ch := notifyChannel{ID: legacyNotifyChannelID, Platform: c.NotificationPlatform, URL: c.NotificationWebhookURL,
		ChatID: c.TelegramChatID, Enabled: true, Default: true}
	switch c.NotificationPlatform {
	case platformDingtalk:
		ch.Secret = c.DingtalkSignSecret
	case platformFeishu:
		ch.Secret = c.FeishuSignSecret
	}
	return []notifyChannel{ch.trimmed()}
}

// notifyConfigKey:推送用到的全部配置拼成的一个键,热重读时据此判断要不要重建 alerter。
func notifyConfigKey(c *config) string {
	b, _ := json.Marshal(struct {
		Channels []notifyChannel
		Routes   map[string][]string
	}{configNotifyChannels(c), c.NotificationRoutes})
	return string(b)
}

// routedNotifyChannels:一个事件推到哪些渠道。notification_routes 里有这个事件就推到列出的那几个(还得启用、填齐);
// 没有就推到全部启用、填齐的渠道 —— 还没按事件选过渠道的配置,行为跟只有一个渠道时一样。
func routedNotifyChannels(channels []notifyChannel, routes map[string][]string, event string) []notifyChannel {
	ids, routed := routes[event]
	var want map[string]bool
	if routed {
		want = make(map[string]bool, len(ids))
		for _, id := range ids {
			want[id] = true
		}
	}
	var out []notifyChannel
	for _, ch := range channels {
		if !ch.Enabled || !ch.complete() || (routed && !want[ch.ID]) {
			continue
		}
		out = append(out, ch)
	}
	return out
}
