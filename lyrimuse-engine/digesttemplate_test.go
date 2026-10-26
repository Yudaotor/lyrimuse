package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

type digestTemplateSample struct {
	Cases []struct {
		Name      string `json:"name"`
		Kind      string `json:"kind"`
		TopN      int    `json:"top_n"`
		Title     string `json:"title"`
		Body      string `json:"body"`
		WantTitle string `json:"want_title"`
		WantBody  string `json:"want_body"`
	} `json:"cases"`
}

// 共用样例 shared/testdata/notify/template.json:App(Core DigestTemplate)照同一份渲染,两边必须逐字一样。
func TestDigestTemplateMatchesSharedSample(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "shared", "testdata", "notify", "template.json"))
	if err != nil {
		t.Fatal(err)
	}
	var s digestTemplateSample
	if err := json.Unmarshal(raw, &s); err != nil {
		t.Fatal(err)
	}
	if len(s.Cases) == 0 {
		t.Fatal("样例里没有用例")
	}
	preview := loadNotifyPreviewSample(t)
	for _, c := range s.Cases {
		useDigestFeatures(t, featureFlags{DigestTopN: c.TopN})
		stats := preview.statsFor(c.Kind, c.TopN)
		defTitle := preview.DailyTitle
		if c.Kind == "weekly" {
			defTitle = preview.WeeklyTitle
		}
		tpl := resolveDigestTemplate(&digestTemplate{Title: c.Title, Body: c.Body})
		title, body := renderDigestTemplate(tpl, defTitle, digestBody(stats), stats, c.TopN)
		if title != c.WantTitle {
			t.Errorf("%s: title = %q, want %q", c.Name, title, c.WantTitle)
		}
		if body != c.WantBody {
			t.Errorf("%s: body =\n%s\nwant\n%s", c.Name, body, c.WantBody)
		}
	}
}

// 跟默认一字不差、或者只有空白的模板不算自定义(照旧按平台排版);超长的截断。
func TestResolveDigestTemplate(t *testing.T) {
	if resolveDigestTemplate(nil).custom() {
		t.Error("缺失不算自定义")
	}
	if got := resolveDigestTemplate(&digestTemplate{Title: " {title} ", Body: "{body}\r\n"}); got.custom() {
		t.Errorf("跟默认一样不算自定义, got %+v", got)
	}
	if got := resolveDigestTemplate(&digestTemplate{Title: "{title}", Body: "嗨\n{body}"}); !got.custom() || got.Title != "" {
		t.Errorf("只改正文: 标题存空、算自定义, got %+v", got)
	}
	long := strings.Repeat("字", digestTemplateMaxRunes+5)
	if got := resolveDigestTemplate(&digestTemplate{Body: long}); len([]rune(got.Body)) != digestTemplateMaxRunes {
		t.Errorf("超长截到 %d 字, got %d", digestTemplateMaxRunes, len([]rune(got.Body)))
	}
}

// 自定义了内容:推出去的标题正文按模板,按纯文本推(Telegram 不带 parse_mode);推送记录记下默认标题当判重键;
// 标题每期都一样时,下一期照推、同一期不推第二份。
func TestDigestPushWithCustomTemplate(t *testing.T) {
	withNotifyLogForTest(t)
	var mu sync.Mutex
	var bodies []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		bodies = append(bodies, string(b))
		mu.Unlock()
		io.WriteString(w, `{"ok":true,"result":{}}`)
	}))
	defer srv.Close()
	useDigestFeatures(t, featureFlags{DigestTopN: 3, DigestTemplate: digestTemplate{Title: "我的报告", Body: "听了 {plays} 次"}})
	a := alerterFromConfig(&config{NotificationChannels: []notifyChannel{
		{ID: "tg", Platform: platformTelegram, URL: srv.URL + "/bot123:abc", ChatID: "42", Enabled: true},
	}})
	stats := digestStats{TotalPlays: 7, TopArtists: []digestTally{{Name: "A", Count: 4}, {Name: "B", Count: 3}}}
	if err := digestPush(a, notifyEventDaily, "🎧 今日听歌报告（10-22）", stats); err != nil {
		t.Fatal(err)
	}
	if len(bodies) != 1 {
		t.Fatalf("推了 %d 次, want 1", len(bodies))
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(bodies[0]), &m); err != nil {
		t.Fatal(err)
	}
	if m["text"] != "我的报告\n听了 7 次" || m["parse_mode"] != nil {
		t.Errorf("自定义内容按纯文本推, got %+v", m)
	}
	e, ok := lastNotifyLogEntry(t)
	if !ok || e.Title != "我的报告" || e.Key != "🎧 今日听歌报告（10-22）" || !e.Custom {
		t.Errorf("推送记录: 标题是推出去的、Key 是默认标题、Custom, got %+v", e)
	}
	// 同一期(过了零点写成「昨日」)不推第二份;下一期标题一样也照推。
	if err := digestPush(a, notifyEventDaily, "🎧 昨日听歌报告（10-22）", stats); err != nil || len(bodies) != 1 {
		t.Errorf("同一期不推第二份, err=%v pushes=%d", err, len(bodies))
	}
	if err := digestPush(a, notifyEventDaily, "🎧 今日听歌报告（10-23）", stats); err != nil || len(bodies) != 2 {
		t.Errorf("下一期照推, err=%v pushes=%d", err, len(bodies))
	}
}

// 自定义内容不套卡片排版;Bark 照旧带封面和点击跳转,重发也一样。
func TestCustomDigestSkipsRichPayload(t *testing.T) {
	d := &digestStats{TotalPlays: 3, CoverURL: "https://img.example/cover.jpg", Link: "https://www.last.fm/user/x"}
	msg := notifyMessage{Event: notifyEventWeekly, Title: "自定义", Body: "正文", Digest: d, Custom: true}
	for _, p := range []string{platformTelegram, platformDiscord, platformSlack, platformFeishu, platformDingtalk, platformWecom, platformServerChan} {
		if _, _, ok, _ := buildRichPayload(notifyChannel{Platform: p, ChatID: "1"}, msg); ok {
			t.Errorf("%s: 自定义内容不该排版", p)
		}
	}
	payload, _, ok, err := buildRichPayload(notifyChannel{Platform: platformBark}, msg)
	if err != nil || !ok || !strings.Contains(string(payload), `"image":"https://img.example/cover.jpg"`) ||
		!strings.Contains(string(payload), `"body":"正文"`) {
		t.Errorf("Bark 照旧带图、正文用自定义的, ok=%v payload=%s", ok, payload)
	}
	msg.Custom = false
	if _, _, ok, _ := buildRichPayload(notifyChannel{Platform: platformTelegram, ChatID: "1"}, msg); !ok {
		t.Error("没自定义的照旧排版")
	}
}

func TestResendKeepsCustomAndKey(t *testing.T) {
	withNotifyLogForTest(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer srv.Close()
	ch := notifyChannel{ID: "bk", Platform: platformBark, URL: srv.URL + "/key", Enabled: true}
	cfgPath := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(cfgPath, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	setLiveConfig(cfgPath, &config{NotificationChannels: []notifyChannel{ch}})
	t.Cleanup(func() { setLiveConfig("", nil) })
	recordNotifyDelivery(ch, notifyMessage{Event: notifyEventDaily, Title: "我的报告", Body: "x", Key: "🎧 今日听歌报告（10-22）", Custom: true},
		notifyResult{Kind: notifyKindNetwork})
	e, _ := lastNotifyLogEntry(t)
	_, msg, _, ok := resendTarget(e.ID)
	if !ok || !msg.Custom || msg.Key != "🎧 今日听歌报告（10-22）" || msg.Title != "我的报告" {
		t.Errorf("重发带上 Custom 和 Key, ok=%v msg=%+v", ok, msg)
	}
}

func lastNotifyLogEntry(t *testing.T) (notifyLogEntry, bool) {
	t.Helper()
	notifyLogMu.Lock()
	defer notifyLogMu.Unlock()
	entries := readNotifyLog(notifyLogPath).Entries
	if len(entries) == 0 {
		return notifyLogEntry{}, false
	}
	return entries[len(entries)-1], true
}
