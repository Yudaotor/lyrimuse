package main

import (
	"bytes"
	"log"
	"strings"
	"testing"
)

func resetSecretsForTest(t *testing.T) {
	t.Helper()
	secretsMu.Lock()
	knownSecrets = nil
	secretsMu.Unlock()
	secretReplace.Store(nil)
}

// 这一行是真实泄露形态(2026-08-17 在 ~/Library/Logs/lyrimuse.log 里逮到的),
// key 换成了假的。它同时覆盖两件事:api_key 必须消失,而失败原因和其余 query
// 参数必须留下 —— 脱敏不能把日志脱成看不出问题在哪。
const lastfmErrLine = `2026/08/17 01:50:05 lastfmRecent: request failed: Get ` +
	`"https://ws.audioscrobbler.com/2.0/?method=user.getrecenttracks&user=someone` +
	`&api_key=0123456789abcdef0123456789abcdef&format=json&limit=50": context canceled`

func TestScrubSecretsRedactsAPIKeyByParamName(t *testing.T) {
	resetSecretsForTest(t)
	// 一个字都没登记过,也要靠第二道防线(按参数名)把它打掉
	got := scrubSecrets(lastfmErrLine)
	if strings.Contains(got, "0123456789abcdef0123456789abcdef") {
		t.Fatalf("api_key 仍是明文: %s", got)
	}
	for _, keep := range []string{
		"user.getrecenttracks", "user=someone", "format=json", "limit=50", "context canceled",
	} {
		if !strings.Contains(got, keep) {
			t.Errorf("脱敏把有用信息也删了,缺 %q: %s", keep, got)
		}
	}
	if !strings.Contains(got, "api_key="+redactedMark) {
		t.Errorf("参数名该保留、只打值: %s", got)
	}
}

func TestScrubSecretsRedactsRegisteredValueAnywhere(t *testing.T) {
	resetSecretsForTest(t)
	const secret = "wsrCZ35QuZxaC9zJj3MJVe"
	registerSecrets(secret)
	// 按值这一道不挑位置:path、正文、任意一句话里都算
	cases := []string{
		`bark: notify failed: Post "https://api.day.app/` + secret + `/hi": timeout`,
		`loaded token ` + secret + ` from config`,
		`{"token":"` + secret + `"}`,
	}
	for _, in := range cases {
		got := scrubSecrets(in)
		if strings.Contains(got, secret) {
			t.Errorf("登记过的凭据没被替换: %s", got)
		}
		if !strings.Contains(got, redactedMark) {
			t.Errorf("应该留下打码标记: %s", got)
		}
	}
	// host 要留着 —— 日志里还得看得出这条推送是往哪个平台发的
	if got := scrubSecrets(`Post "https://api.day.app/` + secret + `"`); !strings.Contains(got, "api.day.app") {
		t.Errorf("host 不该被打掉: %s", got)
	}
}

func TestRegisterSecretsIgnoresShortValues(t *testing.T) {
	resetSecretsForTest(t)
	registerSecrets("ok", "", "   ", "abc")
	got := scrubSecrets("everything is ok, abc")
	if got != "everything is ok, abc" {
		t.Fatalf("短值被当成凭据,日志被打成筛子: %s", got)
	}
}

func TestRegisterSecretsLongestFirst(t *testing.T) {
	resetSecretsForTest(t)
	// 短值是长值的前缀:先替短的会在长值中间留下半截明文
	registerSecrets("abcdefgh", "abcdefghijklmnop")
	got := scrubSecrets("key=abcdefghijklmnop")
	if got != "key="+redactedMark {
		t.Fatalf("前缀顺序不对,留下了半截明文: %s", got)
	}
}

func TestRememberConfigSecretsCoversBarkPathToken(t *testing.T) {
	resetSecretsForTest(t)
	cfg := &config{
		LastfmScrobbleAPIKey:   "0123456789abcdef0123456789abcdef",
		NotificationWebhookURL: "https://api.day.app/wsrCZ35QuZxaC9zJj3MJVe",
	}
	rememberConfigSecrets(cfg)
	got := scrubSecrets(`Post "https://api.day.app/wsrCZ35QuZxaC9zJj3MJVe": timeout`)
	if strings.Contains(got, "wsrCZ35QuZxaC9zJj3MJVe") {
		t.Errorf("Bark 的 path token 没被打掉: %s", got)
	}
	if !strings.Contains(got, "api.day.app") {
		t.Errorf("host 不该被打掉: %s", got)
	}
	// 普通 path 段(短于 minPathSecretLen)不该被当凭据
	resetSecretsForTest(t)
	rememberConfigSecrets(&config{NotificationWebhookURL: "https://hooks.example.com/services/send"})
	if got := scrubSecrets("services send done"); got != "services send done" {
		t.Errorf("普通 path 段被误当成凭据: %s", got)
	}
}

// log 包把"写出字节数 < 传入长度"当短写错误。脱敏后长度必变,Writer 必须报原始长度。
func TestSecretScrubberReportsOriginalLength(t *testing.T) {
	resetSecretsForTest(t)
	registerSecrets("0123456789abcdef0123456789abcdef")
	var buf bytes.Buffer
	w := secretScrubber{w: &buf}
	p := []byte("token=0123456789abcdef0123456789abcdef\n")
	n, err := w.Write(p)
	if err != nil {
		t.Fatalf("写失败: %v", err)
	}
	if n != len(p) {
		t.Fatalf("应报原始长度 %d,实报 %d(log 包会当成短写报错)", len(p), n)
	}
	if strings.Contains(buf.String(), "0123456789abcdef0123456789abcdef") {
		t.Fatalf("凭据没被打掉: %s", buf.String())
	}
}

// 端到端:走真正的 log.Printf,确认接管出口这条路是通的。
func TestInstalledScrubberFiltersLogPrintf(t *testing.T) {
	resetSecretsForTest(t)
	registerSecrets("0123456789abcdef0123456789abcdef")
	var buf bytes.Buffer
	old := log.Writer()
	log.SetOutput(secretScrubber{w: &buf})
	defer log.SetOutput(old)

	log.Printf("lastfmRecent: request failed: Get %q: context canceled",
		"https://ws.audioscrobbler.com/2.0/?method=user.getrecenttracks&api_key=0123456789abcdef0123456789abcdef")
	out := buf.String()
	if strings.Contains(out, "0123456789abcdef0123456789abcdef") {
		t.Fatalf("log.Printf 仍然写出了明文凭据: %s", out)
	}
	if !strings.Contains(out, "context canceled") {
		t.Fatalf("失败原因被吞了: %s", out)
	}
}
