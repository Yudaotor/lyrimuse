// Command collector watches the macOS system now-playing state via
// media-control and submits playing_now / listen events to ListenBrainz.
package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// 推送提醒目前支持的平台——绝大多数都是"群机器人 webhook"这个模子:一个 URL,POST
// 一份 JSON 就能收到消息(Server酱是个例外,见下)。新增平台照这个模子接,只需要在
// buildNotifyPayload 里加一个 case;不是这个模子的(比如 Telegram Bot API 那种"URL
// 本身就带 token、query string 传参"的),接入方式不同,这里先不管。
const (
	platformBark       = "bark"
	platformDingtalk   = "dingtalk"
	platformWecom      = "wecom"
	platformDiscord    = "discord"
	platformFeishu     = "feishu"
	platformServerChan = "serverchan"
)

// buildNotifyPayload 按平台拼出 POST body + 对应的 Content-Type。绝大多数平台都是
// application/json,只有 Server酱是表单编码(它的 Turbo 接口 sctapi.ftqq.com 不接受
// JSON body,字段名也不是 title/body 那套通用命名,是它自己的 title/desp)。空/未识别
// 的 platform 一律按 Bark 处理——这是这个字段加平台选择之前唯一支持过的形态,保留这个
// 默认对已有配置最安全。
func buildNotifyPayload(platform, title, body, feishuSecret string) (payload []byte, contentType string, err error) {
	switch platform {
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
