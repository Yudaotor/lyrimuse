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
		"123456789:AAHfake-token_x":                   "https://api.telegram.org/bot123456789:AAHfake-token_x/sendMessage",
		"  123456789:AAHfake-token_x ":                "https://api.telegram.org/bot123456789:AAHfake-token_x/sendMessage",
		"https://api.telegram.org/bot1:x/sendMessage": "https://api.telegram.org/bot1:x/sendMessage",
		"http://127.0.0.1:9/bot1:x/sendMessage":       "http://127.0.0.1:9/bot1:x/sendMessage",
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
	if gotPath != "/botTEST/sendMessage" || gotBody["chat_id"] != "42" || gotBody["text"] != "t\nb" {
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
