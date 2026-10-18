package main

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// 一次推送的结论。各平台拒收时 HTTP 状态码多半照样是 200,真正的原因在响应体的业务错误码里(飞书 code、
// 企业微信 / 钉钉 errcode、Server酱 code、Telegram ok、Bark code),只看状态码会把「签名不对」「关键词不对」
// 「发太快被限流」全当成发出去了。classifyNotifyResponse 按平台读出来,归成下面几类,App 按类别给出该怎么改。
const (
	notifyKindOK          = "ok"
	notifyKindAuth        = "auth"         // 密钥、签名、令牌不对,或机器人的安全设置(关键词 / IP)没过
	notifyKindRateLimited = "rate_limited" // 平台限流,过一会儿再发
	notifyKindRejected    = "rejected"     // 平台收到了但不接受这条消息(参数、格式、关键词)
	notifyKindNotFound    = "not_found"    // 地址对应的机器人 / 主题 / 会话不存在(删了、填错了)
	notifyKindServer      = "server"       // 平台自己出错(5xx)
	notifyKindNetwork     = "network"      // 没连上、超时
	notifyKindConfig      = "config"       // 渠道没填齐、地址不是网址,请求根本没发出去
)

// notifyDetailMaxRunes:记进推送记录的平台原话最多留多少字。
const notifyDetailMaxRunes = 160

type notifyResult struct {
	OK      bool
	Kind    string
	Status  int    // HTTP 状态码,没拿到响应时为 0
	Code    string // 平台的业务错误码
	Detail  string // 平台的原话(已截短、去掉密钥)
	Elapsed time.Duration
}

func (r notifyResult) err() error {
	if r.OK {
		return nil
	}
	msg := "notify push " + r.Kind
	if r.Status != 0 {
		msg += fmt.Sprintf(": status %d", r.Status)
	}
	if r.Code != "" {
		msg += " code " + r.Code
	}
	return fmt.Errorf("%s", msg)
}

// notifyBusinessFields 是各平台响应体里可能出现的业务字段,一个结构体全兜住。
type notifyBusinessFields struct {
	Code        json.RawMessage `json:"code"`       // 飞书 / Server酱 / Bark / ntfy
	StatusCode  json.RawMessage `json:"StatusCode"` // 飞书旧版机器人
	ErrCode     json.RawMessage `json:"errcode"`    // 企业微信 / 钉钉
	OK          *bool           `json:"ok"`         // Telegram
	ErrorCode   int             `json:"error_code"` // Telegram
	Msg         string          `json:"msg"`
	ErrMsg      string          `json:"errmsg"`
	Message     string          `json:"message"`
	Description string          `json:"description"`
	Error       string          `json:"error"`
}

// rawCode 把数字或字符串形式的错误码统一成字符串;字段不在时返回空串。
func rawCode(raw json.RawMessage) string {
	s := strings.Trim(strings.TrimSpace(string(raw)), `"`)
	if s == "null" {
		return ""
	}
	return s
}

// classifyNotifyResponse 按平台判断一次推送收没收下。
func classifyNotifyResponse(platform string, status int, body []byte) notifyResult {
	r := notifyResult{Status: status}
	var f notifyBusinessFields
	parsed := json.Unmarshal(body, &f) == nil
	r.Detail = notifyDetail(firstNonEmpty(f.Msg, f.ErrMsg, f.Description, f.Message, f.Error))
	if !parsed && (status < 200 || status >= 300) {
		// 非 JSON 的出错响应(Slack 回纯文本 invalid_token 之类):短的才留,长的多半是一整页 HTML。
		if t := strings.TrimSpace(string(body)); t != "" && utf8.RuneCountInString(t) <= 80 && !strings.HasPrefix(t, "<") {
			r.Detail = notifyDetail(t)
		}
	}
	if status < 200 || status >= 300 {
		r.Kind = notifyKindForStatus(status)
		if platform == platformTelegram && f.ErrorCode != 0 {
			r.Code = strconv.Itoa(f.ErrorCode)
			if f.ErrorCode == 400 && strings.Contains(strings.ToLower(f.Description), "chat not found") {
				r.Kind = notifyKindNotFound
			}
		}
		if c := rawCode(f.Code); platform == platformNtfy && c != "" {
			r.Code = c
		}
		return r
	}
	if !parsed {
		r.OK, r.Kind, r.Detail = true, notifyKindOK, ""
		return r
	}
	switch platform {
	case platformFeishu:
		code := firstNonEmpty(rawCode(f.Code), rawCode(f.StatusCode))
		if code != "" && code != "0" {
			r.Code, r.Kind = code, feishuErrorKind(code)
			return r
		}
	case platformWecom, platformDingtalk:
		if code := rawCode(f.ErrCode); code != "" && code != "0" {
			r.Code, r.Kind = code, robotErrorKind(platform, code)
			return r
		}
	case platformServerChan:
		if code := rawCode(f.Code); code != "" && code != "0" {
			r.Code, r.Kind = code, notifyKindRejected
			if code == "40001" || code == "401" {
				r.Kind = notifyKindAuth
			}
			return r
		}
	case platformBark:
		if code := rawCode(f.Code); code != "" && code != "200" {
			r.Code, r.Kind = code, notifyKindRejected
			return r
		}
	case platformTelegram:
		if f.OK != nil && !*f.OK {
			r.Code, r.Kind = strconv.Itoa(f.ErrorCode), notifyKindRejected
			return r
		}
	}
	r.OK, r.Kind, r.Detail = true, notifyKindOK, ""
	return r
}

func notifyKindForStatus(status int) string {
	switch {
	case status == 401 || status == 403:
		return notifyKindAuth
	case status == 404 || status == 410:
		return notifyKindNotFound
	case status == 429:
		return notifyKindRateLimited
	case status >= 500:
		return notifyKindServer
	default:
		return notifyKindRejected
	}
}

// feishuErrorKind:飞书自定义机器人的错误码。19021 签名不对、19022 IP 不在白名单、19024 关键词没过,
// 11232 / 9499 里的限流(发太快),19001 机器人不存在(被删了、地址填错)。
func feishuErrorKind(code string) string {
	switch code {
	case "19021", "19022", "19024":
		return notifyKindAuth
	case "11232":
		return notifyKindRateLimited
	case "19001":
		return notifyKindNotFound
	}
	return notifyKindRejected
}

// robotErrorKind:企业微信 93000 地址失效、45009 限流;钉钉 310000 安全设置没过(关键词 / 加签 / IP)、
// 300001 / 400013 机器人不存在、130101 限流(每分钟 20 条)。
func robotErrorKind(platform, code string) string {
	switch {
	case platform == platformWecom && code == "93000",
		platform == platformDingtalk && (code == "300001" || code == "400013"):
		return notifyKindNotFound
	case platform == platformWecom && code == "45009",
		platform == platformDingtalk && code == "130101":
		return notifyKindRateLimited
	case platform == platformDingtalk && code == "310000":
		return notifyKindAuth
	}
	return notifyKindRejected
}

// notifyDetail:平台原话截短、去掉已登记的密钥后再记。
func notifyDetail(s string) string {
	s = strings.TrimSpace(strings.ReplaceAll(s, "\n", " "))
	if utf8.RuneCountInString(s) > notifyDetailMaxRunes {
		s = string([]rune(s)[:notifyDetailMaxRunes]) + "…"
	}
	return scrubSecrets(s)
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}
