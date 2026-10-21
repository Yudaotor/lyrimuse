package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 没有渠道列表时旧的单渠道字段当成一个渠道,密钥按平台取对应的那一个。
func TestConfigNotifyChannelsLegacy(t *testing.T) {
	if got := configNotifyChannels(&config{NotificationPlatform: platformBark}); got != nil {
		t.Errorf("没填地址就没有渠道, got %+v", got)
	}
	got := configNotifyChannels(&config{NotificationPlatform: platformDingtalk, NotificationWebhookURL: " https://oapi.dingtalk.com/robot/send?access_token=x \n",
		DingtalkSignSecret: "SECdt", FeishuSignSecret: "fs"})
	want := notifyChannel{ID: legacyNotifyChannelID, Platform: platformDingtalk, URL: "https://oapi.dingtalk.com/robot/send?access_token=x",
		Secret: "SECdt", Enabled: true}
	if len(got) != 1 || got[0] != want {
		t.Errorf("got %+v, want %+v", got, want)
	}
	got = configNotifyChannels(&config{NotificationPlatform: platformFeishu, NotificationWebhookURL: "https://f", DingtalkSignSecret: "dt", FeishuSignSecret: "fs"})
	if got[0].Secret != "fs" {
		t.Errorf("飞书取飞书的签名密钥, got %q", got[0].Secret)
	}
	got = configNotifyChannels(&config{NotificationWebhookURL: "https://legacy",
		NotificationChannels: []notifyChannel{{ID: "a", URL: "https://a", Enabled: true}}})
	if len(got) != 1 || got[0].ID != "a" || got[0].Platform != platformBark {
		t.Errorf("有渠道列表就不看旧字段;没写平台按 Bark, got %+v", got)
	}
	cfg := configFromBytes([]byte(`{"bark_url":"https://api.day.app/k","notification_channels":[]}`))
	if got := configNotifyChannels(cfg); len(got) != 0 {
		t.Errorf("渠道删光了([])不能退回去读旧字段, got %+v", got)
	}
}

// 没按事件选过渠道 = 推到全部启用、填齐的渠道;选过就只推列出的那几个(还得启用、填齐)。
func TestRoutedNotifyChannels(t *testing.T) {
	channels := []notifyChannel{
		{ID: "a", Platform: platformBark, URL: "https://a", Enabled: true},
		{ID: "b", Platform: platformBark, URL: "https://b", Enabled: false},
		{ID: "c", Platform: platformTelegram, URL: "123:abc", Enabled: true}, // 缺 Chat ID
		{ID: "d", Platform: platformSlack, URL: "https://d", Enabled: true},
	}
	ids := func(chs []notifyChannel) string {
		var out []string
		for _, ch := range chs {
			out = append(out, ch.ID)
		}
		return strings.Join(out, ",")
	}
	if got := ids(routedNotifyChannels(channels, nil, notifyEventWeekly)); got != "a,d" {
		t.Errorf("没选过 = 全部启用、填齐的, got %q", got)
	}
	routes := map[string][]string{notifyEventWeekly: {"d", "b", "zz"}, notifyEventDaily: {}}
	if got := ids(routedNotifyChannels(channels, routes, notifyEventWeekly)); got != "d" {
		t.Errorf("选过 = 只推列出的、启用的, got %q", got)
	}
	if got := routedNotifyChannels(channels, routes, notifyEventDaily); got != nil {
		t.Errorf("选了空列表 = 不推, got %+v", got)
	}
	var nilAlerter *alerter
	if nilAlerter.configured(notifyEventDaily) {
		t.Error("nil alerter 不算配好")
	}
}

func withNotifyLogForTest(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "notify-log.json")
	setNotifyLogPath(path)
	t.Cleanup(func() { setNotifyLogPath("") })
	return path
}

// 多个渠道:有一个收下就算推送成功(调用方记「已推送」);每个渠道的结果都进推送记录。全没收下才报错。
func TestAlerterSendMultiChannel(t *testing.T) {
	logPath := withNotifyLogForTest(t)
	ok := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{"code":200,"message":"success"}`)
	}))
	defer ok.Close()
	// 飞书拒收时状态码照样 200,原因在 code 里。
	rejected := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{"code":19024,"msg":"Key Words Not Found","data":{}}`)
	}))
	defer rejected.Close()

	a := alerterFromConfig(&config{NotificationChannels: []notifyChannel{
		{ID: "fs", Name: "飞书群", Platform: platformFeishu, URL: rejected.URL, Enabled: true},
		{ID: "bk", Platform: platformBark, URL: ok.URL + "/key", Enabled: true},
	}})
	if err := a.send(notifyEventWeekly, "周报", "正文"); err != nil {
		t.Fatalf("有一个渠道收下就不该报错: %v", err)
	}
	f := readNotifyLog(logPath)
	if len(f.Entries) != 2 {
		t.Fatalf("两个渠道各记一条, got %+v", f.Entries)
	}
	e := f.Entries[0]
	if e.Channel != "fs" || e.ChannelName != "飞书群" || e.OK || e.Kind != notifyKindAuth || e.Code != "19024" ||
		e.Detail != "Key Words Not Found" || e.Event != notifyEventWeekly || e.Title != "周报" {
		t.Errorf("飞书那条 = %+v", e)
	}
	if !f.Entries[1].OK || f.Entries[1].Kind != notifyKindOK || f.Entries[1].Body != "正文" {
		t.Errorf("Bark 那条 = %+v(收下的也记正文,推送页点开要看)", f.Entries[1])
	}
	if e.Body != "正文" || e.ID == "" || e.ID == f.Entries[1].ID {
		t.Errorf("没推成的记正文、每条有自己的 id: %+v", e)
	}

	a = alerterFromConfig(&config{NotificationChannels: []notifyChannel{{ID: "fs", Platform: platformFeishu, URL: rejected.URL, Enabled: true}}})
	if err := a.send(notifyEventWeekly, "周报", "正文"); err == nil || !strings.Contains(err.Error(), "code 19024") {
		t.Errorf("全没收下要报错且带错误码, got %v", err)
	}
	if err := a.send(notifyEventMilestone, "t", "b"); err == errNoNotifyChannel {
		t.Error("没按事件选过渠道,里程碑也推到这个渠道")
	}
	a.routes = map[string][]string{notifyEventMilestone: {}}
	if err := a.send(notifyEventMilestone, "t", "b"); err != errNoNotifyChannel {
		t.Errorf("这个事件没选渠道, got %v", err)
	}
}

// 推送记录只留最近 notifyLogMax 条。
func TestNotifyLogCapped(t *testing.T) {
	logPath := withNotifyLogForTest(t)
	for i := 0; i < notifyLogMax+5; i++ {
		recordNotifyDelivery(notifyChannel{ID: "x"}, notifyMessage{Event: notifyEventDaily, Title: string(rune('a' + i%26))}, notifyResult{OK: true, Kind: notifyKindOK})
	}
	f := readNotifyLog(logPath)
	if len(f.Entries) != notifyLogMax || f.Schema != notifyLogSchema {
		t.Errorf("len=%d schema=%d", len(f.Entries), f.Schema)
	}
	if f.Entries[notifyLogMax-1].Title != string(rune('a'+(notifyLogMax+4)%26)) {
		t.Errorf("最后一条应是最新的, got %q", f.Entries[notifyLogMax-1].Title)
	}
}

// 各平台的业务错误码按类归好;状态码 2xx 但业务码不对的不算收下。
func TestClassifyNotifyResponse(t *testing.T) {
	cases := []struct {
		name, platform string
		status         int
		body           string
		ok             bool
		kind, code     string
	}{
		{"飞书成功", platformFeishu, 200, `{"code":0,"msg":"success"}`, true, notifyKindOK, ""},
		{"飞书旧版成功", platformFeishu, 200, `{"StatusCode":0,"StatusMessage":"success"}`, true, notifyKindOK, ""},
		{"飞书签名", platformFeishu, 200, `{"code":19021,"msg":"sign match fail or timestamp is not within one hour from current time"}`, false, notifyKindAuth, "19021"},
		{"飞书限流", platformFeishu, 200, `{"code":11232,"msg":"frequency limited"}`, false, notifyKindRateLimited, "11232"},
		{"飞书机器人没了", platformFeishu, 200, `{"code":19001,"msg":"param invalid: incoming webhook access token invalid"}`, false, notifyKindNotFound, "19001"},
		{"企业微信成功", platformWecom, 200, `{"errcode":0,"errmsg":"ok"}`, true, notifyKindOK, ""},
		{"企业微信地址失效", platformWecom, 200, `{"errcode":93000,"errmsg":"invalid webhook url"}`, false, notifyKindNotFound, "93000"},
		{"企业微信限流", platformWecom, 200, `{"errcode":45009,"errmsg":"api freq out of limit"}`, false, notifyKindRateLimited, "45009"},
		{"钉钉安全设置", platformDingtalk, 200, `{"errcode":310000,"errmsg":"keywords not in content"}`, false, notifyKindAuth, "310000"},
		{"钉钉限流", platformDingtalk, 200, `{"errcode":130101,"errmsg":"send too fast"}`, false, notifyKindRateLimited, "130101"},
		{"钉钉 token 不对", platformDingtalk, 200, `{"errcode":300001,"errmsg":"token is not exist"}`, false, notifyKindNotFound, "300001"},
		{"Server酱成功", platformServerChan, 200, `{"code":0,"message":"","data":{}}`, true, notifyKindOK, ""},
		{"Server酱 key 不对", platformServerChan, 200, `{"code":40001,"message":"bad pushtoken"}`, false, notifyKindAuth, "40001"},
		{"Bark 成功", platformBark, 200, `{"code":200,"message":"success"}`, true, notifyKindOK, ""},
		{"Bark 设备 key 不对", platformBark, 400, `{"code":400,"message":"failed to get device token"}`, false, notifyKindRejected, ""},
		{"Telegram 成功", platformTelegram, 200, `{"ok":true,"result":{}}`, true, notifyKindOK, ""},
		{"Telegram 会话不存在", platformTelegram, 400, `{"ok":false,"error_code":400,"description":"Bad Request: chat not found"}`, false, notifyKindNotFound, "400"},
		{"Telegram token 不对", platformTelegram, 401, `{"ok":false,"error_code":401,"description":"Unauthorized"}`, false, notifyKindAuth, "401"},
		{"Discord 204", platformDiscord, 204, ``, true, notifyKindOK, ""},
		{"Slack 成功纯文本", platformSlack, 200, `ok`, true, notifyKindOK, ""},
		{"Slack 地址失效", platformSlack, 404, `no_service`, false, notifyKindNotFound, ""},
		{"ntfy 限流", platformNtfy, 429, `{"code":42901,"http":429,"error":"limit reached: too many requests"}`, false, notifyKindRateLimited, "42901"},
		{"ntfy 要令牌", platformNtfy, 403, `{"code":40301,"http":403,"error":"forbidden"}`, false, notifyKindAuth, "40301"},
		{"Webhook 500", platformWebhook, 502, `<html>Bad Gateway</html>`, false, notifyKindServer, ""},
	}
	for _, c := range cases {
		r := classifyNotifyResponse(c.platform, c.status, []byte(c.body))
		if r.OK != c.ok || r.Kind != c.kind || r.Code != c.code || r.Status != c.status {
			t.Errorf("%s: got ok=%v kind=%s code=%q status=%d", c.name, r.OK, r.Kind, r.Code, r.Status)
		}
		if r.OK && r.Detail != "" {
			t.Errorf("%s: 收下时不记平台原话, got %q", c.name, r.Detail)
		}
	}
	if r := classifyNotifyResponse(platformSlack, 404, []byte("no_service")); r.Detail != "no_service" {
		t.Errorf("短的纯文本出错响应留作原话, got %q", r.Detail)
	}
	if r := classifyNotifyResponse(platformWebhook, 502, []byte("<html>Bad Gateway</html>")); r.Detail != "" {
		t.Errorf("HTML 出错页不留, got %q", r.Detail)
	}
	long := `{"code":19024,"msg":"` + strings.Repeat("长", 300) + `"}`
	if r := classifyNotifyResponse(platformFeishu, 200, []byte(long)); len([]rune(r.Detail)) != notifyDetailMaxRunes+1 {
		t.Errorf("原话截到 %d 字加省略号, got %d", notifyDetailMaxRunes, len([]rune(r.Detail)))
	}
}

// ntfy:订阅地址的最后一段是主题,往前面的服务器根地址 POST JSON;自建在子路径下也行。令牌走 Bearer,「用户名:密码」走 Basic。
func TestBuildNtfyRequest(t *testing.T) {
	msg := notifyMessage{Event: notifyEventWeekly, Title: "🎧 周报", Body: "正文"}
	nr, err := buildNotifyRequest(notifyChannel{Platform: platformNtfy, URL: "https://ntfy.sh/lyrimuse-abc"}, msg)
	if err != nil {
		t.Fatal(err)
	}
	var body map[string]any
	json.Unmarshal(nr.body, &body)
	if nr.target != "https://ntfy.sh/" || body["topic"] != "lyrimuse-abc" || body["title"] != "🎧 周报" || body["message"] != "正文" || nr.headers != nil {
		t.Errorf("target=%q body=%v headers=%v", nr.target, body, nr.headers)
	}
	nr, _ = buildNotifyRequest(notifyChannel{Platform: platformNtfy, URL: "https://me.example/ntfy/topic/?x=1", Secret: "tk_abc"}, msg)
	json.Unmarshal(nr.body, &body)
	if nr.target != "https://me.example/ntfy/" || body["topic"] != "topic" || nr.headers["Authorization"] != "Bearer tk_abc" {
		t.Errorf("子路径: target=%q topic=%v headers=%v", nr.target, body["topic"], nr.headers)
	}
	nr, _ = buildNotifyRequest(notifyChannel{Platform: platformNtfy, URL: "https://ntfy.sh/t", Secret: "me:pw"}, msg)
	if nr.headers["Authorization"] != "Basic "+base64.StdEncoding.EncodeToString([]byte("me:pw")) {
		t.Errorf("Basic headers=%v", nr.headers)
	}
	for _, bad := range []string{"https://ntfy.sh/", "https://ntfy.sh", "ntfy.sh/topic"} {
		if _, err := buildNotifyRequest(notifyChannel{Platform: platformNtfy, URL: bad}, msg); err == nil {
			t.Errorf("%q 没有主题 / 不是网址,应报错", bad)
		}
	}
}

// 通用 Webhook:固定字段的 JSON;填了密钥就带 HMAC-SHA256 签名,接收端用同一个密钥对请求体算出来要一致。
func TestBuildWebhookRequest(t *testing.T) {
	nr, err := buildNotifyRequest(notifyChannel{Platform: platformWebhook, URL: "https://hook.example/x", Secret: "s3cret"},
		notifyMessage{Event: notifyEventMonthly, Title: "月报", Body: "正文"})
	if err != nil {
		t.Fatal(err)
	}
	var p webhookPayload
	if err := json.Unmarshal(nr.body, &p); err != nil {
		t.Fatal(err)
	}
	if p.App != "lyrimuse" || p.Event != notifyEventMonthly || p.Title != "月报" || p.Body != "正文" || p.SentAt == "" {
		t.Errorf("payload = %+v", p)
	}
	mac := hmac.New(sha256.New, []byte("s3cret"))
	mac.Write(nr.body)
	if want := "sha256=" + hex.EncodeToString(mac.Sum(nil)); nr.headers["X-Lyrimuse-Signature"] != want {
		t.Errorf("signature = %q, want %q", nr.headers["X-Lyrimuse-Signature"], want)
	}
	if nr.headers["X-Lyrimuse-Event"] != notifyEventMonthly || nr.target != "https://hook.example/x" {
		t.Errorf("headers=%v target=%q", nr.headers, nr.target)
	}
	nr, _ = buildNotifyRequest(notifyChannel{Platform: platformWebhook, URL: "https://hook.example/x"}, notifyMessage{Title: "t"})
	if _, signed := nr.headers["X-Lyrimuse-Signature"]; signed {
		t.Error("没填密钥不签名")
	}
}

// 端到端:钉钉加签拼进地址、ntfy 的令牌进请求头,真的发到了。
func TestPushToChannelHeadersAndSignedURL(t *testing.T) {
	var gotAuth, gotQuery string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth, gotQuery = r.Header.Get("Authorization"), r.URL.RawQuery
		io.WriteString(w, `{"errcode":0}`)
	}))
	defer srv.Close()
	if r := pushToChannel(notifyChannel{Platform: platformNtfy, URL: srv.URL + "/topic", Secret: "tk_x"}, notifyMessage{Title: "t"}); !r.OK || gotAuth != "Bearer tk_x" {
		t.Errorf("ntfy r=%+v auth=%q", r, gotAuth)
	}
	if r := pushToChannel(notifyChannel{Platform: platformDingtalk, URL: srv.URL + "/robot/send?access_token=a", Secret: "SEC1"}, notifyMessage{Title: "t"}); !r.OK ||
		!strings.Contains(gotQuery, "access_token=a&timestamp=") || !strings.Contains(gotQuery, "&sign=") {
		t.Errorf("钉钉 r=%+v query=%q", r, gotQuery)
	}
	if r := pushToChannel(notifyChannel{Platform: platformTelegram, URL: "123:abc"}, notifyMessage{Title: "t"}); r.OK || r.Kind != notifyKindConfig {
		t.Errorf("缺 Chat ID 不发, got %+v", r)
	}
	if r := pushToChannel(notifyChannel{Platform: platformBark, URL: "http://127.0.0.1:1/x"}, notifyMessage{Title: "t"}); r.OK || r.Kind != notifyKindNetwork || strings.Contains(r.Detail, "127.0.0.1:1/x") {
		t.Errorf("连不上归 network、原话不带地址, got %+v", r)
	}
}

// 渠道地址 path 段、query 里的 key、密钥都按值登记进脱敏表;测试请求里还没保存的渠道也一样。
func TestRememberNotifyChannelSecrets(t *testing.T) {
	const wecomKey = "693a91f6-7xxx-4bc4-97a0-0ec2sifa5aaa"
	const ntfyToken = "tk_FakeNtfyTokenForScrubTest"
	rememberConfigSecrets(&config{NotificationChannels: []notifyChannel{
		{ID: "w", Platform: platformWecom, URL: "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=" + wecomKey, Enabled: true},
	}})
	rememberNotifyChannelSecrets(notifyChannel{Platform: platformNtfy, URL: "https://ntfy.sh/t", Secret: ntfyToken})
	got := scrubSecrets("wecom said " + wecomKey + " / auth " + ntfyToken)
	if strings.Contains(got, wecomKey) || strings.Contains(got, ntfyToken) {
		t.Errorf("没抹掉: %s", got)
	}
}

// 「测一下」:读请求、推一条示例、结果按 id 写进结果文件(留最近几次),也进推送记录。
func TestNotifyTestRequestRoundTrip(t *testing.T) {
	logPath := withNotifyLogForTest(t)
	dir := t.TempDir()
	prevResult := notifyTestResultPath
	notifyTestResultPath = filepath.Join(dir, "result.json")
	t.Cleanup(func() { notifyTestResultPath = prevResult })

	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		json.Unmarshal(b, &gotBody)
		io.WriteString(w, `{"code":200}`)
	}))
	defer srv.Close()

	if _, ok := parseNotifyTestRequest([]byte(`{"channel":{}}`)); ok {
		t.Error("没有 id 的请求不收")
	}
	for i, id := range []string{"t1", "t2"} {
		raw, _ := json.Marshal(notifyTestRequest{ID: id, Channel: notifyChannel{ID: "c", Platform: platformBark, URL: " " + srv.URL + "/key ", Enabled: i == 0}})
		req, ok := parseNotifyTestRequest(raw)
		if !ok {
			t.Fatal("合法请求没收下")
		}
		runNotifyTest(req)
	}
	if gotBody["title"] != notifyTestTitle {
		t.Errorf("推的是示例消息, got %v", gotBody)
	}
	b, err := os.ReadFile(notifyTestResultPath)
	if err != nil {
		t.Fatal(err)
	}
	var f notifyTestResultFile
	json.Unmarshal(b, &f)
	if len(f.Results) != 2 || f.Results[0].ID != "t1" || f.Results[1].ID != "t2" || !f.Results[1].OK || f.Results[1].Kind != notifyKindOK {
		t.Errorf("results = %+v", f.Results)
	}
	if e := readNotifyLog(logPath).Entries; len(e) != 2 || e[0].Event != notifyEventTest {
		t.Errorf("测试也进推送记录(停用的渠道照测), got %+v", e)
	}
}

// 「重发」:按推送记录 id 找到那条没推成的,用此刻配置里同 id 的渠道把原标题、正文再推一次。
func TestNotifyResendFailedEntry(t *testing.T) {
	logPath := withNotifyLogForTest(t)
	prevResult := notifyTestResultPath
	notifyTestResultPath = filepath.Join(t.TempDir(), "result.json")
	t.Cleanup(func() { notifyTestResultPath = prevResult })

	var gotBody map[string]any
	status := http.StatusInternalServerError
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		json.Unmarshal(b, &gotBody)
		w.WriteHeader(status)
	}))
	defer srv.Close()
	cfgJSON := `{"notification_channels":[{"id":"c1","platform":"bark","url":"` + srv.URL + `/k","enabled":true}]}`
	startLiveConfigForTest(t, cfgJSON)

	a := alerterFromConfig(liveConfig())
	if err := a.send(notifyEventWeekly, "周报", "Top 3"); err == nil {
		t.Fatal("500 应算没推成")
	}
	failed := readNotifyLog(logPath).Entries[0]

	status = http.StatusOK
	gotBody = nil
	runNotifyTest(notifyTestRequest{ID: "r1", Resend: failed.ID})
	if gotBody["title"] != "周报" || gotBody["body"] != "Top 3" {
		t.Errorf("重发原样推标题、正文, got %v", gotBody)
	}
	entries := readNotifyLog(logPath).Entries
	if len(entries) != 2 || !entries[1].OK || entries[1].Event != notifyEventWeekly || entries[1].Channel != "c1" {
		t.Errorf("重发也进推送记录, got %+v", entries)
	}

	runNotifyTest(notifyTestRequest{ID: "r2", Resend: "nope"})
	runNotifyTest(notifyTestRequest{ID: "r3", Resend: entries[1].ID}) // 推成的不重发
	gotBody = nil
	runNotifyTest(notifyTestRequest{ID: "r4", Resend: failed.ID}) // 之后已经推成过,不再推
	if gotBody != nil {
		t.Errorf("已经重发成功的那条再点重发不该再推, got %v", gotBody)
	}
	b, _ := os.ReadFile(notifyTestResultPath)
	var f notifyTestResultFile
	json.Unmarshal(b, &f)
	if len(f.Results) != 4 || !f.Results[0].OK || f.Results[1].OK || f.Results[1].Kind != notifyKindConfig || f.Results[2].OK ||
		!f.Results[3].OK || f.Results[3].Kind != notifyKindOK {
		t.Errorf("results = %+v", f.Results)
	}
	if n := len(readNotifyLog(logPath).Entries); n != 2 {
		t.Errorf("找不到记录、已经推成过时不推、不记, got %d 条", n)
	}

	// 引擎下一轮自动重推同一份周报:重发推成的那个渠道跳过、算收下(不再推第二份);另一期的报告照推。
	gotBody = nil
	if err := alerterFromConfig(liveConfig()).send(notifyEventWeekly, "周报", "Top 3"); err != nil || gotBody != nil {
		t.Errorf("已收到这份周报的渠道应跳过并算收下, err=%v body=%v", err, gotBody)
	}
	if err := alerterFromConfig(liveConfig()).send(notifyEventWeekly, "下一期周报", "Top 3"); err != nil || gotBody == nil {
		t.Errorf("另一期报告照推, err=%v body=%v", err, gotBody)
	}
}

// 共用样例(shared/testdata/notify/)两边各读一遍:App 写的渠道列表引擎读得懂,引擎写的推送记录、测试结果
// 字段名跟 App 解的对得上(多一个、少一个都会在这里报出来)。
func TestNotifySharedSamples(t *testing.T) {
	dir := filepath.Join("..", "shared", "testdata", "notify")
	raw, err := os.ReadFile(filepath.Join(dir, "channels.json"))
	if err != nil {
		t.Fatal(err)
	}
	chs := configNotifyChannels(configFromBytes(raw))
	if len(chs) != 2 || chs[0].ID != "c1" || chs[0].ChatID != "42" || chs[1].Secret != "tk_faketoken" || chs[1].Enabled {
		t.Errorf("channels = %+v", chs)
	}
	if routes := configFromBytes(raw).NotificationRoutes; len(routes) != 2 || len(routes[notifyEventWeekly]) != 1 || routes[notifyEventDaily][1] != "c2" {
		t.Errorf("routes = %+v", routes)
	}
	strict := func(name string, v any) {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Fatal(err)
		}
		dec := json.NewDecoder(strings.NewReader(string(b)))
		dec.DisallowUnknownFields()
		if err := dec.Decode(v); err != nil {
			t.Errorf("%s: %v", name, err)
		}
	}
	var lf notifyLogFile
	strict("log.json", &lf)
	if lf.Schema != notifyLogSchema || len(lf.Entries) != 3 || lf.Entries[1].Code != "19021" || lf.Entries[1].Body == "" {
		t.Errorf("log = %+v", lf)
	}
	var rf notifyTestResultFile
	strict("test-result.json", &rf)
	if len(rf.Results) != 2 || rf.Results[1].Kind != notifyKindNotFound {
		t.Errorf("results = %+v", rf.Results)
	}
}
