package main

import (
	"bytes"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestTelegramSendURL(t *testing.T) {
	cases := map[string]string{
		"123456789:AAHfake-token_x":                              "https://api.telegram.org/bot123456789:AAHfake-token_x/sendMessage",
		"  123456789:AAHfake-token_x ":                           "https://api.telegram.org/bot123456789:AAHfake-token_x/sendMessage",
		"https://api.telegram.org/bot1:x/sendMessage":            "https://api.telegram.org/bot1:x/sendMessage",
		"http://127.0.0.1:9/bot1:x/sendMessage":                  "http://127.0.0.1:9/bot1:x/sendMessage",
		"https://api.telegram.org/bot1:x/sendMessage?chat_id=42": "https://api.telegram.org/bot1:x/sendMessage?chat_id=42",
		"https://api.telegram.org/bot1:x/getUpdates":             "https://api.telegram.org/bot1:x/sendMessage",
		"https://api.telegram.org/bot1:x/getUpdates?offset=3":    "https://api.telegram.org/bot1:x/sendMessage",
		"https://api.telegram.org/bot1:x":                        "https://api.telegram.org/bot1:x/sendMessage",
		"https://example.com/hooks/telegram":                     "https://example.com/hooks/telegram",
	}
	for in, want := range cases {
		if got := telegramSendURL(in); got != want {
			t.Errorf("telegramSendURL(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestBuildNotifyPayloadTelegram(t *testing.T) {
	b, ct, err := buildNotifyPayload(platformTelegram, "标题", "正文 *不转义* <b>", "", " 123456789 ")
	if err != nil || ct != "application/json" {
		t.Fatalf("err=%v ct=%q", err, ct)
	}
	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	if got["chat_id"] != "123456789" {
		t.Errorf("chat_id = %v（应去掉首尾空格）", got["chat_id"])
	}
	if got["text"] != "标题\n正文 *不转义* <b>" {
		t.Errorf("text = %v", got["text"])
	}
	if _, ok := got["parse_mode"]; ok {
		t.Error("不能设 parse_mode：设了就得转义歌名里的 * _ [ ] < >")
	}
}

// 端到端：地址栏填完整地址时原样用；带上 Chat ID；平台拒收时记一行 rejected。
func TestAlerterPushTelegram(t *testing.T) {
	var gotPath string
	var gotBody map[string]any
	status := http.StatusOK
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		b, _ := io.ReadAll(r.Body)
		json.Unmarshal(b, &gotBody)
		w.WriteHeader(status)
	}))
	defer srv.Close()

	a := newAlerter(platformTelegram, srv.URL+"/botTEST/sendMessage", "", "", "42")
	a.push("t", "b")
	// 按平台排版:Telegram 走 HTML,标题加粗(纯文本那份见 TestPlainFallbackPayload)。
	if gotPath != "/botTEST/sendMessage" || gotBody["chat_id"] != "42" || gotBody["text"] != "<b>t</b>\nb" || gotBody["parse_mode"] != "HTML" {
		t.Errorf("path=%q body=%v", gotPath, gotBody)
	}

	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(prev) })
	status = http.StatusBadRequest
	a.push("t", "b")
	if !strings.Contains(buf.String(), "notify push rejected (platform=telegram): status 400") {
		t.Errorf("拒收时应记一行 rejected，实际日志: %q", buf.String())
	}
}

// 地址栏只填 Telegram 机器人 Token(不是 URL)时，整段都要当凭据从日志里抹掉。
func TestRememberConfigSecretsBareTelegramToken(t *testing.T) {
	const token = "987654321:AAHzzFakeTokenForScrubTest_123"
	rememberConfigSecrets(&config{NotificationPlatform: platformTelegram, NotificationWebhookURL: token})
	got := scrubSecrets(`Post "https://api.telegram.org/bot` + token + `/sendMessage": timeout`)
	if strings.Contains(got, token) || strings.Contains(got, "AAHzzFakeToken") {
		t.Errorf("token 没被抹掉: %s", got)
	}
	if !strings.Contains(got, "api.telegram.org") {
		t.Errorf("host 应保留: %s", got)
	}
}

// Slack:标题加粗,& < > 转成实体(歌名里的 < > 不转会被当成链接语法),别的字符原样。
func TestBuildNotifyPayloadSlack(t *testing.T) {
	b, ct, err := buildNotifyPayload(platformSlack, "周报 <1>", "A & B - <Song> *x*", "", "")
	if err != nil || ct != "application/json" {
		t.Fatalf("err=%v ct=%q", err, ct)
	}
	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	if want := "*周报 &lt;1&gt;*\nA &amp; B - &lt;Song&gt; *x*"; got["text"] != want {
		t.Errorf("text = %q, want %q", got["text"], want)
	}
	if len(got) != 1 {
		t.Errorf("只该有 text 一个字段: %v", got)
	}
}

// Slack webhook 地址里只有最后一段是凭据,写进日志前要抹掉;工作区、频道 ID 留着好排查。
func TestRememberConfigSecretsSlackWebhook(t *testing.T) {
	const secret = "FakeSlackHookSecret0123456"
	rememberConfigSecrets(&config{NotificationPlatform: platformSlack,
		NotificationWebhookURL: "https://hooks.slack.com/services/T0FAKE1/B0FAKE2/" + secret})
	got := scrubSecrets(`Post "https://hooks.slack.com/services/T0FAKE1/B0FAKE2/` + secret + `": 404`)
	if strings.Contains(got, secret) {
		t.Errorf("webhook 凭据没被抹掉: %s", got)
	}
	if !strings.Contains(got, "hooks.slack.com/services/T0FAKE1/B0FAKE2/") {
		t.Errorf("host 与工作区、频道 ID 应保留: %s", got)
	}
}

// 端到端:从配置建出的推送器把 Slack 消息原样 POST 到地址栏的地址;Slack 拒收(地址失效回 404)时返回错误,不记「已推送」。
func TestAlerterPushSlack(t *testing.T) {
	var gotPath, gotCT string
	var gotBody map[string]any
	status := http.StatusOK
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotCT = r.URL.Path, r.Header.Get("Content-Type")
		b, _ := io.ReadAll(r.Body)
		json.Unmarshal(b, &gotBody)
		w.WriteHeader(status)
	}))
	defer srv.Close()

	a := alerterFromConfig(&config{NotificationPlatform: platformSlack,
		NotificationWebhookURL: srv.URL + "/services/T0FAKE1/B0FAKE2/secret"})
	if err := a.push("标题", "A <B>"); err != nil {
		t.Fatalf("收下时不该报错: %v", err)
	}
	if gotPath != "/services/T0FAKE1/B0FAKE2/secret" || gotCT != "application/json" || gotBody["text"] != "标题\nA &lt;B&gt;" || gotBody["blocks"] == nil {
		t.Errorf("path=%q ct=%q body=%v", gotPath, gotCT, gotBody)
	}

	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(prev) })
	status = http.StatusNotFound
	if err := a.push("t", "b"); err == nil {
		t.Error("Slack 拒收时要返回错误,否则会记成已推送")
	}
	if !strings.Contains(buf.String(), "notify push rejected (platform=slack): status 404") {
		t.Errorf("拒收时应记一行 rejected，实际日志: %q", buf.String())
	}
}
