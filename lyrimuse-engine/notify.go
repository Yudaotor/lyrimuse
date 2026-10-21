package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// 推送提醒支持的平台——绝大多数都是"群机器人 webhook"这个模子:一个 URL,POST
// 一份 JSON 就能收到消息(Server酱是个例外,见下)。新增平台照这个模子接,只需要在
// buildNotifyPayload 里加一个 case。Telegram 多要一个 Chat ID,地址也可以只填机器人
// Token,见 telegramSendURL。ntfy 和通用 Webhook 还要带请求头,见 buildNotifyRequest。
const (
	platformBark       = "bark"
	platformDingtalk   = "dingtalk"
	platformWecom      = "wecom"
	platformDiscord    = "discord"
	platformFeishu     = "feishu"
	platformServerChan = "serverchan"
	platformTelegram   = "telegram"
	platformSlack      = "slack"
	platformNtfy       = "ntfy"
	platformWebhook    = "webhook"
)

// notifyRequest 是往一个渠道发的那一个 POST。
type notifyRequest struct {
	target      string
	body        []byte
	contentType string
	headers     map[string]string
	rich        bool // 按平台排过版(notifyrich.go);被平台说格式不对时 pushToChannel 改推纯文本
}

// buildNotifyRequest 按渠道的平台拼出请求:地址(钉钉加签、Telegram 只填 Token 时在这里换)、正文、请求头。按平台排版
// (notifyrich.go),这个平台、这条消息不排时用纯文本。
func buildNotifyRequest(ch notifyChannel, msg notifyMessage) (notifyRequest, error) {
	return buildNotifyRequestAs(ch, msg, true)
}

// buildNotifyRequestAs:formatted=false 拼纯文本那份 —— 排过版的被平台判成格式不对时改推它(pushToChannel)。
func buildNotifyRequestAs(ch notifyChannel, msg notifyMessage, formatted bool) (notifyRequest, error) {
	switch ch.Platform {
	case platformNtfy:
		return buildNtfyRequest(ch, msg, formatted)
	case platformWebhook:
		return buildWebhookRequest(ch, msg)
	}
	payload, contentType, rich, err := []byte(nil), "", false, error(nil)
	if formatted {
		payload, contentType, rich, err = buildRichPayload(ch, msg)
	}
	if err != nil {
		return notifyRequest{}, err
	}
	if !rich {
		feishuSecret := ""
		if ch.Platform == platformFeishu {
			feishuSecret = ch.Secret
		}
		if payload, contentType, err = buildNotifyPayload(ch.Platform, msg.Title, msg.Body, feishuSecret, ch.ChatID); err != nil {
			return notifyRequest{}, err
		}
	}
	target := ch.URL
	switch ch.Platform {
	case platformDingtalk:
		target = dingtalkSignedURL(ch.URL, ch.Secret)
	case platformTelegram:
		target = telegramSendURL(ch.URL)
	}
	return notifyRequest{target: target, body: payload, contentType: contentType, rich: rich}, nil
}

// buildNtfyRequest:ntfy 用 JSON 发布 —— 往服务器根地址 POST {"topic","title","message"}。标题放请求头的话
// 中文和 emoji 得另外编码,JSON 没这个麻烦。用户填的是订阅时的那个地址(https://ntfy.sh/<主题>),最后一段是主题,
// 前面是服务器(自建的可以挂在子路径下)。Secret 是访问令牌(tk_ 开头)或「用户名:密码」,开了访问控制的主题才要。
func buildNtfyRequest(ch notifyChannel, msg notifyMessage, formatted bool) (notifyRequest, error) {
	u, err := url.Parse(ch.URL)
	if err != nil || u.Host == "" {
		return notifyRequest{}, errors.New("ntfy address is not a URL")
	}
	path := strings.TrimRight(u.Path, "/")
	cut := strings.LastIndex(path, "/")
	topic := path[cut+1:]
	if topic == "" {
		return notifyRequest{}, errors.New("ntfy address has no topic")
	}
	u.Path, u.RawPath, u.RawQuery, u.Fragment = path[:cut+1], "", "", ""
	if u.Path == "" {
		u.Path = "/"
	}
	m := map[string]any{"topic": topic, "title": msg.Title, "message": msg.Body, "tags": []string{"headphones"}}
	// 按平台排版:正文仍是纯文本(ntfy 的 markdown 只有安卓和网页认,iPhone 上会显示一堆星号),只加封面(attach,
	// 客户端拉下来显示成图)和点击跳转(click)。
	rich := false
	if d := msg.Digest; d != nil && formatted {
		if d.CoverURL != "" {
			m["attach"], rich = d.CoverURL, true
		}
		if d.Link != "" {
			m["click"], rich = d.Link, true
		}
	}
	b, err := json.Marshal(m)
	if err != nil {
		return notifyRequest{}, err
	}
	nr := notifyRequest{target: u.String(), body: b, contentType: "application/json", rich: rich}
	switch {
	case ch.Secret == "":
	case strings.Contains(ch.Secret, ":"):
		nr.headers = map[string]string{"Authorization": "Basic " + base64.StdEncoding.EncodeToString([]byte(ch.Secret))}
	default:
		nr.headers = map[string]string{"Authorization": "Bearer " + ch.Secret}
	}
	return nr, nil
}

// webhookPayload 是通用 Webhook 收到的 JSON,给自己写接收端(Home Assistant、n8n、自建服务)的人看的,字段只增不改。
type webhookPayload struct {
	App    string `json:"app"`
	Event  string `json:"event"`
	Title  string `json:"title"`
	Body   string `json:"body"`
	SentAt string `json:"sent_at"` // RFC 3339
	// Data:听歌报告的结构化数(notifyrich.go 的 webhookDigestData),报告都带(退回纯文本时也带);其余消息没有。
	Data *webhookDigestData `json:"data,omitempty"`
}

// buildWebhookRequest:通用 Webhook 原样 POST webhookPayload。填了 Secret 就用它对整个请求体算 HMAC-SHA256,
// 放进 X-Lyrimuse-Signature: sha256=<十六进制>(跟 GitHub webhook 同一个写法),接收端据此确认是这台机器发的。
func buildWebhookRequest(ch notifyChannel, msg notifyMessage) (notifyRequest, error) {
	event := msg.Event
	if event == "" {
		event = "message"
	}
	b, err := json.Marshal(webhookPayload{App: "lyrimuse", Event: event, Title: msg.Title, Body: msg.Body,
		SentAt: time.Now().UTC().Format(time.RFC3339), Data: webhookDigest(msg.Digest)})
	if err != nil {
		return notifyRequest{}, err
	}
	nr := notifyRequest{target: ch.URL, body: b, contentType: "application/json",
		headers: map[string]string{"X-Lyrimuse-Event": event}}
	if ch.Secret != "" {
		nr.headers["X-Lyrimuse-Signature"] = "sha256=" + webhookSignature(ch.Secret, b)
	}
	return nr, nil
}

func webhookSignature(secret string, body []byte) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write(body)
	return hex.EncodeToString(mac.Sum(nil))
}

// buildNotifyPayload 按平台拼出 POST body + 对应的 Content-Type。绝大多数平台都是
// application/json,只有 Server酱是表单编码(它的 Turbo 接口 sctapi.ftqq.com 不接受
// JSON body,字段名也不是 title/body 那套通用命名,是它自己的 title/desp)。空/未识别
// 的 platform 一律按 Bark 处理——这是这个字段加平台选择之前唯一支持过的形态,保留这个
// 默认对已有配置最安全。
func buildNotifyPayload(platform, title, body, feishuSecret, telegramChatID string) (payload []byte, contentType string, err error) {
	switch platform {
	case platformTelegram:
		// Bot API sendMessage:纯文本,不设 parse_mode —— 设了 Markdown / HTML 就得转义正文里的
		// 特殊字符,歌名里的 * _ [ ] < > 一个没转义整条就发不出去。
		b, err := json.Marshal(map[string]any{
			"chat_id":                  strings.TrimSpace(telegramChatID),
			"text":                     title + "\n" + body,
			"disable_web_page_preview": true,
		})
		return b, "application/json", err
	case platformDingtalk, platformWecom:
		// 钉钉、企业微信群机器人的纯文本消息是同一个形状:{"msgtype":"text",
		// "text":{"content":"..."}}。标题和正文没有分开的字段,拼进同一段文本里,
		// 用换行分隔,跟 Bark 通知在锁屏上"标题+正文"的观感保持一致。
		b, err := json.Marshal(map[string]any{
			"msgtype": "text",
			"text":    map[string]string{"content": title + "\n" + body},
		})
		return b, "application/json", err
	case platformFeishu:
		content := map[string]any{
			"msg_type": "text",
			"content":  map[string]string{"text": title + "\n" + body},
		}
		if feishuSecret != "" {
			content["timestamp"] = feishuTimestamp()
			content["sign"] = feishuSign(content["timestamp"].(string), feishuSecret)
		}
		b, err := json.Marshal(content)
		return b, "application/json", err
	case platformDiscord:
		// Discord webhook 最简单的形态就是一个 content 字符串,加粗标题模拟"标题+
		// 正文"的层次(Discord 的 Markdown 支持 ** 加粗)。
		b, err := json.Marshal(map[string]any{
			"content": "**" + title + "**\n" + body,
		})
		return b, "application/json", err
	case platformSlack:
		// Slack Incoming Webhook:text 按 mrkdwn 渲染,单个星号加粗。& < > 必须先转成实体,
		// 否则歌名里的 < > 会被当成链接 / 提及语法吞掉。
		b, err := json.Marshal(map[string]any{
			"text": "*" + slackEscape(title) + "*\n" + slackEscape(body),
		})
		return b, "application/json", err
	case platformServerChan:
		// Server酱 Turbo(sctapi.ftqq.com)只认 application/x-www-form-urlencoded,
		// 字段叫 title/desp(desp 支持 Markdown)——跟其它平台的 JSON body 完全是
		// 两回事,照抄 json.Marshal 那一套会直接推送失败。
		form := url.Values{"title": {title}, "desp": {body}}
		return []byte(form.Encode()), "application/x-www-form-urlencoded", nil
	default: // platformBark 及任何未识别的值
		b, err := json.Marshal(map[string]any{
			"title": title, "body": body, "group": "nowplaying", "level": "active",
		})
		return b, "application/json", err
	}
}

// slackEscape 只转 Slack 要求转的三个字符,其余原样(整段 HTML 转义的话别的实体 Slack 不认、会原样显示)。
var slackEscaper = strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;")

func slackEscape(s string) string { return slackEscaper.Replace(s) }

// telegramSendURL 把用户填的值换成 sendMessage 地址:填的是完整地址(http 开头)时,路径是 `/bot<Token>/<方法>` 而方法
// 不是 sendMessage 的(设置说明里查 Chat ID 用的 getUpdates)换成 sendMessage、去掉查询串,其余原样用;不是地址就当成
// @BotFather 给的机器人 Token 拼出来。getUpdates 收到 chat_id、text 也回 ok:true,不换的话推送会被判成送达、实际没发。
func telegramSendURL(raw string) string {
	raw = strings.TrimSpace(raw)
	if !strings.HasPrefix(raw, "http://") && !strings.HasPrefix(raw, "https://") {
		return "https://api.telegram.org/bot" + raw + "/sendMessage"
	}
	u, err := url.Parse(raw)
	if err != nil {
		return raw
	}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	if len(parts) < 1 || len(parts) > 2 || !strings.HasPrefix(parts[0], "bot") || len(parts[0]) <= len("bot") {
		return raw
	}
	if len(parts) == 2 && parts[1] == "sendMessage" {
		return raw
	}
	u.Path = "/" + parts[0] + "/sendMessage"
	u.RawPath, u.RawQuery, u.Fragment = "", "", ""
	return u.String()
}

// dingtalkSignedURL 给钉钉机器人开了"加签"安全设置时用——把 timestamp/sign 追加成
// query string。算法是钉钉文档规定的:secret 本身做 HMAC key,对 timestamp(毫秒)+
// "\n"+secret 这段字符串取 HMAC-SHA256,结果再 base64。secret 留空(机器人安全设置
// 选的是"自定义关键词"或者没做校验)时原样返回 rawURL,不做任何改动。
//
// 这个算法跟下面飞书的签名算法长得像、其实关键字反过来了——分别验证过两边文档,别
// 照抄错了:钉钉是"拿 secret 当 key,对 ts+secret 这段字符串取 HMAC"(密钥固定、消息
// 变化);飞书是"拿 ts+secret 这段拼接字符串本身当 key,对空消息取 HMAC"(key 本身
// 就包含了消息,官方 Python 示例调用 hmac.new(key, digestmod=...) 时压根没传 msg
// 参数,取的是空消息的 HMAC)。
func dingtalkSignedURL(rawURL, secret string) string {
	if secret == "" {
		return rawURL
	}
	ts := strconv.FormatInt(time.Now().UnixMilli(), 10)
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(ts + "\n" + secret))
	sign := base64.StdEncoding.EncodeToString(mac.Sum(nil))
	sep := "?"
	if strings.Contains(rawURL, "?") {
		sep = "&"
	}
	return rawURL + sep + "timestamp=" + ts + "&sign=" + url.QueryEscape(sign)
}

// feishuTimestamp 用秒(不是钉钉那种毫秒)——飞书文档明确要求秒级时间戳,且服务端会
// 校验跟当前时间的偏差在 1 小时以内,单位错了会导致签名永远校验不过。
func feishuTimestamp() string {
	return strconv.FormatInt(time.Now().Unix(), 10)
}

// feishuSign 是飞书机器人加签的签名算法——键和消息跟钉钉是反过来的(见 dingtalkSignedURL
// 顶上的注释):拿 timestamp+"\n"+secret 这段拼接字符串本身当 HMAC key,对空消息取
// HMAC-SHA256 再 base64。飞书把结果放进 JSON body 的 sign/timestamp 字段,不是像
// 钉钉那样拼进 URL query string。
func feishuSign(timestamp, secret string) string {
	mac := hmac.New(sha256.New, []byte(timestamp+"\n"+secret))
	return base64.StdEncoding.EncodeToString(mac.Sum(nil))
}
