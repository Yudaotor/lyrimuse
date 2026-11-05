package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
)

// richSample 是排版测试用的一份周报:名字里故意带各平台会当成语法的字符。
func richSample() *digestStats {
	return &digestStats{
		TotalPlays: 601, PrevPlays: 883, PrevLabel: "前一周", TotalDurationMs: 2523 * 60000, DurationEstimated: true,
		TopArtists: []digestTally{{Name: "方大同", Count: 129}, {Name: "Guns N' <Roses> & *Co*", Count: 12}},
		TopAlbums:  []digestTally{{Name: "Xscape (Deluxe)", Sub: "Michael Jackson", Count: 30}, {Name: "15", Sub: "方大同", Count: 23}},
		TopTracks:  []digestTally{{Name: "a_b|c", Sub: "D~E", Count: 5}, {Name: "昙花", Sub: "方大同", Count: 4}},
		NewArtists: 44, NewArtistNames: []string{"Patti LaBelle", "The Crane", "99 God"},
		Source: digestSourceLastfm, From: "2026-10-12", To: "2026-10-18",
		CoverURL: "https://lastfm.example/i/u/300x300/c.png", Link: "https://www.last.fm/user/u/library/artists?from=2026-10-12&to=2026-10-18",
	}
}

func richMessage() notifyMessage {
	d := richSample()
	return notifyMessage{Event: notifyEventWeekly, Title: "🎵 上周听歌小结（10-12~10-18）", Body: digestBody(*d), Digest: d}
}

func decodeJSON(t *testing.T, b []byte) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("not JSON: %v\n%s", err, b)
	}
	return m
}

func buildFor(t *testing.T, ch notifyChannel, msg notifyMessage) notifyRequest {
	t.Helper()
	nr, err := buildNotifyRequest(ch, msg)
	if err != nil {
		t.Fatal(err)
	}
	return nr
}

func TestRichTelegram(t *testing.T) {
	useDigestFeatures(t, featureFlags{DigestTopN: 2})
	nr := buildFor(t, notifyChannel{Platform: platformTelegram, URL: "TOKEN", ChatID: "42"}, richMessage())
	m := decodeJSON(t, nr.body)
	text, _ := m["text"].(string)
	if !nr.rich || m["parse_mode"] != "HTML" || !strings.HasPrefix(text, "<b>🎵 上周听歌小结（10-12~10-18）</b>\n共播放 601 次（前一周 883，↓32%） · 约 42 小时 3 分") {
		t.Fatalf("rich=%v %v", nr.rich, m)
	}
	for _, want := range []string{"<b>Top 歌手</b>\n1. 方大同 · 129\n2. Guns N&#39; &lt;Roses&gt; &amp; *Co* · 12",
		"<b>Top 专辑</b>\n1. Xscape (Deluxe) — Michael Jackson · 30", "🆕 新听了 44 位歌手：Patti LaBelle、The Crane、99 God 等"} {
		if !strings.Contains(text, want) {
			t.Errorf("text 缺 %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "<a ") {
		t.Errorf("链接放按钮里,正文不再写: %s", text)
	}
	kb, _ := m["reply_markup"].(map[string]any)["inline_keyboard"].([]any)
	if len(kb) != 1 || kb[0].([]any)[0].(map[string]any)["url"] != "https://www.last.fm/user/u/library/artists?from=2026-10-12&to=2026-10-18" ||
		kb[0].([]any)[0].(map[string]any)["text"] != "在 Last.fm 上看完整榜单" {
		t.Errorf("去完整榜单是一颗 URL 按钮: %v", m["reply_markup"])
	}
	preview, _ := m["link_preview_options"].(map[string]any)
	if preview["url"] != "https://lastfm.example/i/u/300x300/c.png" || preview["show_above_text"] != true {
		t.Errorf("封面放链接预览、显示在上方: %v", preview)
	}
	// 没封面:关掉链接预览(不然会把 Last.fm 页面的预览挂上来)。
	msg := richMessage()
	msg.Digest.CoverURL = ""
	m = decodeJSON(t, buildFor(t, notifyChannel{Platform: platformTelegram, URL: "TOKEN", ChatID: "42"}, msg).body)
	if p, _ := m["link_preview_options"].(map[string]any); p["is_disabled"] != true {
		t.Errorf("%v", m["link_preview_options"])
	}
	// 没链接:不带按钮。
	msg = richMessage()
	msg.Digest.Link = ""
	if m = decodeJSON(t, buildFor(t, notifyChannel{Platform: platformTelegram, URL: "TOKEN", ChatID: "42"}, msg).body); m["reply_markup"] != nil {
		t.Errorf("%v", m["reply_markup"])
	}
	// 超过 4096 字:不排,推纯文本那份。
	msg = richMessage()
	msg.Digest.NewArtistNames = []string{strings.Repeat("长", 5000)}
	if nr := buildFor(t, notifyChannel{Platform: platformTelegram, URL: "TOKEN", ChatID: "42"}, msg); nr.rich || decodeJSON(t, nr.body)["parse_mode"] != nil {
		t.Error("超长应退回纯文本")
	}
}

func TestRichDiscord(t *testing.T) {
	useDigestFeatures(t, featureFlags{DigestTopN: 2})
	m := decodeJSON(t, buildFor(t, notifyChannel{Platform: platformDiscord, URL: "https://discord.example/api/webhooks/1/x"}, richMessage()).body)
	embeds, _ := m["embeds"].([]any)
	if len(embeds) != 1 || m["content"] != nil {
		t.Fatalf("%v", m)
	}
	e := embeds[0].(map[string]any)
	fields, _ := e["fields"].([]any)
	if e["url"] == nil || e["thumbnail"].(map[string]any)["url"] != "https://lastfm.example/i/u/300x300/c.png" || len(fields) != 3 {
		t.Fatalf("%v", e)
	}
	artists := fields[0].(map[string]any)
	if artists["name"] != "歌手" || artists["inline"] != true || !strings.Contains(artists["value"].(string), `Guns N' <Roses\> & \*Co\*`) {
		t.Errorf("歌手栏: %v", artists)
	}
	if v := fields[2].(map[string]any)["value"].(string); !strings.Contains(v, `a\_b\|c — D\~E`) {
		t.Errorf("歌曲栏要转义 markdown: %q", v)
	}
	if !strings.Contains(e["description"].(string), "🆕 新听了 44 位歌手") || e["footer"].(map[string]any)["text"] != "Lyrimuse · 数据来自 Last.fm" {
		t.Errorf("%v", e)
	}
	// 一栏超过 1024 字:截掉后面的名次。
	msg := richMessage()
	msg.Digest.TopArtists = nil
	for i := 0; i < 10; i++ {
		msg.Digest.TopArtists = append(msg.Digest.TopArtists, digestTally{Name: strings.Repeat("名", 200), Count: 10 - i})
	}
	useDigestFeatures(t, featureFlags{DigestTopN: 10})
	m = decodeJSON(t, buildFor(t, notifyChannel{Platform: platformDiscord, URL: "https://discord.example/x"}, msg).body)
	v := m["embeds"].([]any)[0].(map[string]any)["fields"].([]any)[0].(map[string]any)["value"].(string)
	if n := len([]rune(v)); n > discordFieldMax || !strings.HasPrefix(v, "1. ") {
		t.Errorf("栏长 %d", n)
	}
}

func TestRichSlack(t *testing.T) {
	useDigestFeatures(t, featureFlags{DigestTopN: 2})
	m := decodeJSON(t, buildFor(t, notifyChannel{Platform: platformSlack, URL: "https://hooks.slack.com/services/a"}, richMessage()).body)
	blocks, _ := m["blocks"].([]any)
	if m["text"] != "🎵 上周听歌小结（10-12~10-18）\n共播放 601 次（前一周 883，↓32%） · 约 42 小时 3 分" || len(blocks) != 6 {
		t.Fatalf("text=%q blocks=%d", m["text"], len(blocks))
	}
	first := blocks[1].(map[string]any)
	if first["accessory"].(map[string]any)["image_url"] != "https://lastfm.example/i/u/300x300/c.png" ||
		!strings.Contains(first["text"].(map[string]any)["text"].(string), "*Top 歌手*\n1. 方大同 · 129\n2. Guns N' &lt;Roses&gt; &amp; *Co* · 12") {
		t.Errorf("%v", first)
	}
	ctx := blocks[5].(map[string]any)["elements"].([]any)[0].(map[string]any)["text"].(string)
	if !strings.Contains(ctx, "<https://www.last.fm/user/u/library/artists?from=2026-10-12&to=2026-10-18|在 Last.fm 上看完整榜单>") {
		t.Errorf("context: %q", ctx)
	}
}

func TestRichFeishuCard(t *testing.T) {
	useDigestFeatures(t, featureFlags{DigestTopN: 2})
	m := decodeJSON(t, buildFor(t, notifyChannel{Platform: platformFeishu, URL: "https://open.feishu.cn/x", Secret: "s"}, richMessage()).body)
	if m["msg_type"] != "interactive" || m["sign"] == nil || m["timestamp"] == nil {
		t.Fatalf("要是卡片且照旧带签名: %v", m)
	}
	card := m["card"].(map[string]any)
	header := card["header"].(map[string]any)
	if header["title"].(map[string]any)["content"] != "🎵 上周听歌小结（10-12~10-18）" ||
		header["subtitle"].(map[string]any)["content"] != "共播放 601 次（前一周 883，↓32%） · 约 42 小时 3 分" {
		t.Errorf("第一行是标题栏的副标题: %v", header)
	}
	if first, _ := json.Marshal(card["elements"].([]any)[0]); strings.Contains(string(first), "共播放") {
		t.Errorf("正文不再重复第一行: %s", first)
	}
	raw, _ := json.Marshal(card)
	s := string(raw)
	for _, want := range []string{`"tag":"column_set"`, `"content":"**歌手**"`, `1. 方大同 · 129`, `"url":"https://www.last.fm/user/u/library/artists?from=2026-10-12\u0026to=2026-10-18"`,
		`Lyrimuse · 数据来自 Last.fm`} {
		if !strings.Contains(s, want) {
			t.Errorf("卡片缺 %s:\n%s", want, s)
		}
	}
	if strings.Contains(s, "lastfm.example") {
		t.Error("飞书卡片不带封面(群机器人换不了 image_key)")
	}
}

func TestRichMarkdownPlatforms(t *testing.T) {
	useDigestFeatures(t, featureFlags{DigestTopN: 2})
	dd := decodeJSON(t, buildFor(t, notifyChannel{Platform: platformDingtalk, URL: "https://oapi.dingtalk.com/robot/send?access_token=x"}, richMessage()).body)
	ac := dd["actionCard"].(map[string]any)
	text := ac["text"].(string)
	if dd["msgtype"] != "actionCard" || ac["title"] != "🎵 上周听歌小结（10-12~10-18）" || !strings.Contains(text, "![封面](https://lastfm.example/i/u/300x300/c.png)") ||
		!strings.Contains(text, "1. 方大同 · 129  \n2. ") || !strings.HasSuffix(text, "###### Lyrimuse · 数据来自 Last.fm") || strings.Contains(text, "](https://www.last.fm") ||
		ac["singleTitle"] != "在 Last.fm 上看完整榜单" || ac["singleURL"] != "https://www.last.fm/user/u/library/artists?from=2026-10-12&to=2026-10-18" {
		t.Errorf("钉钉有链接时发 actionCard、链接是按钮:\n%v", dd)
	}
	// 没链接:照旧 markdown。
	noLink := richMessage()
	noLink.Digest.Link = ""
	dd = decodeJSON(t, buildFor(t, notifyChannel{Platform: platformDingtalk, URL: "https://oapi.dingtalk.com/robot/send?access_token=x"}, noLink).body)
	if dd["msgtype"] != "markdown" || !strings.HasSuffix(dd["markdown"].(map[string]any)["text"].(string), "###### Lyrimuse · 数据来自 Last.fm") {
		t.Errorf("钉钉没链接: %v", dd)
	}
	wc := decodeJSON(t, buildFor(t, notifyChannel{Platform: platformWecom, URL: "https://qyapi.weixin.qq.com/x"}, richMessage()).body)
	content := wc["markdown_v2"].(map[string]any)["content"].(string)
	if wc["msgtype"] != "markdown_v2" || !strings.HasPrefix(content, "# 🎵 上周听歌小结") || !strings.Contains(content, `a\_b\|c — D\~E`) ||
		!strings.HasSuffix(content, "\n\nLyrimuse · 数据来自 Last.fm") || strings.Contains(content, "\n> ") {
		t.Errorf("企业微信:\n%s", content)
	}
	// 企业微信超过 4096 字节:退回纯文本。
	msg := richMessage()
	msg.Digest.NewArtistNames = []string{strings.Repeat("长", 1500)}
	if nr := buildFor(t, notifyChannel{Platform: platformWecom, URL: "https://qyapi.weixin.qq.com/x"}, msg); nr.rich || decodeJSON(t, nr.body)["msgtype"] != "text" {
		t.Error("超长应退回纯文本")
	}
	nr := buildFor(t, notifyChannel{Platform: platformServerChan, URL: "https://sctapi.ftqq.com/x.send"}, richMessage())
	form, _ := url.ParseQuery(string(nr.body))
	if desp := form.Get("desp"); !nr.rich || !strings.Contains(desp, "#### Top 歌手\n\n1. 方大同 · 129\n2. Guns N' \\<Roses\\> & \\*Co\\* · 12") ||
		!strings.HasPrefix(desp, "![封面](") || form.Get("title") != "🎵 上周听歌小结（10-12~10-18）" ||
		form.Get("short") != "共播放 601 次（前一周 883，↓32%） · 约 42 小时 3 分" {
		t.Errorf("Server酱: %q short=%q", desp, form.Get("short"))
	}
}

func TestRichBarkAndNtfyKeepPlainBody(t *testing.T) {
	useDigestFeatures(t, featureFlags{DigestTopN: 2})
	msg := richMessage()
	summary := "共播放 601 次（前一周 883，↓32%） · 约 42 小时 3 分"
	bk := decodeJSON(t, buildFor(t, notifyChannel{Platform: platformBark, URL: "https://api.day.app/k"}, msg).body)
	if bk["subtitle"] != summary || bk["body"] != strings.TrimPrefix(msg.Body, summary+"\n\n") || bk["icon"] != richAppIcon ||
		bk["image"] != msg.Digest.CoverURL || bk["url"] != msg.Digest.Link || bk["markdown"] != nil {
		t.Errorf("Bark: 第一行进副标题、正文是其余几行、带图标: %v", bk)
	}
	// 没封面也没链接:照样带副标题和图标。
	bare := richMessage()
	bare.Digest.CoverURL, bare.Digest.Link = "", ""
	if bk = decodeJSON(t, buildFor(t, notifyChannel{Platform: platformBark, URL: "https://api.day.app/k"}, bare).body); bk["subtitle"] != summary || bk["image"] != nil {
		t.Errorf("Bark 无封面: %v", bk)
	}
	// 正文只有第一行(概况、没有新歌手):不挪,正文不能空。
	only := richMessage()
	only.Body = summary
	if bk = decodeJSON(t, buildFor(t, notifyChannel{Platform: platformBark, URL: "https://api.day.app/k"}, only).body); bk["subtitle"] != nil || bk["body"] != summary {
		t.Errorf("Bark 只有一行: %v", bk)
	}
	// 自定义内容:标题正文原样,不拆。
	custom := richMessage()
	custom.Custom, custom.Body = true, summary+"\n我的模板"
	if bk = decodeJSON(t, buildFor(t, notifyChannel{Platform: platformBark, URL: "https://api.day.app/k"}, custom).body); bk["subtitle"] != nil || bk["body"] != custom.Body {
		t.Errorf("Bark 自定义: %v", bk)
	}
	nt := decodeJSON(t, buildFor(t, notifyChannel{Platform: platformNtfy, URL: "https://ntfy.sh/topic"}, msg).body)
	if nt["message"] != msg.Body || nt["attach"] != msg.Digest.CoverURL || nt["click"] != msg.Digest.Link || nt["icon"] != richAppIcon || nt["markdown"] != nil {
		t.Errorf("ntfy: %v", nt)
	}
}

// 退回纯文本的那份(排过版的被平台拒收时改推它):跟以前一样的纯文本,不带封面、跳转;通用 Webhook 的 data 照带(那是数据,不是排版)。
func TestPlainFallbackPayload(t *testing.T) {
	useDigestFeatures(t, featureFlags{DigestTopN: 2})
	msg := richMessage()
	for _, p := range []string{platformTelegram, platformDiscord, platformSlack, platformFeishu, platformDingtalk, platformWecom, platformServerChan, platformBark, platformNtfy} {
		ch := notifyChannel{Platform: p, URL: "https://example.com/hook/topic", ChatID: "42"}
		nr, err := buildNotifyRequestAs(ch, msg, false)
		if err != nil || nr.rich {
			t.Errorf("%s: 纯文本那份还在排 err=%v", p, err)
		}
		s := string(nr.body)
		if strings.Contains(s, "lastfm.example") || strings.Contains(s, "parse_mode") || strings.Contains(s, "embeds") || strings.Contains(s, "interactive") {
			t.Errorf("%s: %s", p, s)
		}
	}
	whReq, _ := buildNotifyRequestAs(notifyChannel{Platform: platformWebhook, URL: "https://example.com/h"}, msg, false)
	wh := decodeJSON(t, whReq.body)
	data, _ := wh["data"].(map[string]any)
	if data["total_plays"] != 601.0 || data["previous_plays"] != 883.0 || data["duration_minutes"] != 2523.0 || data["duration_estimated"] != true ||
		data["new_artists"].(map[string]any)["count"] != 44.0 || data["from"] != "2026-10-12" || data["cover_url"] == nil {
		t.Errorf("webhook data: %v", data)
	}
	tracks := data["top_tracks"].([]any)
	if tr := tracks[0].(map[string]any); tr["name"] != "a_b|c" || tr["artist"] != "D~E" || tr["count"] != 5.0 {
		t.Errorf("%v", tr)
	}
	test := decodeJSON(t, buildFor(t, notifyChannel{Platform: platformWebhook, URL: "https://example.com/h"}, sampleTestMessage()).body)
	if d, _ := test["data"].(map[string]any); test["event"] != notifyEventTest || d["total_plays"] != 42.0 {
		t.Errorf("测一下那条带着报告的 data、事件是 test: %v", test)
	}
}

func sampleTestMessage() notifyMessage {
	s := digestSampleStats()
	return notifyMessage{Event: notifyEventTest, Title: dw()["title_sample"], Body: digestBody(s), Digest: &s}
}

// 「测一下」那份报告跟真推一样按平台排版,测得出这个渠道收不收排过版的消息。
func TestRichTestMessage(t *testing.T) {
	useDigestFeatures(t, featureFlags{DigestTopN: 3})
	msg := sampleTestMessage()
	tg := decodeJSON(t, buildFor(t, notifyChannel{Platform: platformTelegram, URL: "TOKEN", ChatID: "42"}, msg).body)
	if text, _ := tg["text"].(string); !strings.HasPrefix(text, "<b>"+dw()["title_sample"]+"</b>") || !strings.Contains(text, "周杰伦") || tg["parse_mode"] != "HTML" {
		t.Errorf("%v", tg)
	}
	fs := decodeJSON(t, buildFor(t, notifyChannel{Platform: platformFeishu, URL: "https://open.feishu.cn/x"}, msg).body)
	if fs["msg_type"] != "interactive" {
		t.Errorf("%v", fs)
	}
	bk := decodeJSON(t, buildFor(t, notifyChannel{Platform: platformBark, URL: "https://api.day.app/k"}, msg).body)
	if bk["title"] != dw()["title_sample"] || bk["subtitle"] != digestSummaryLine(*msg.Digest) || bk["icon"] != richAppIcon {
		t.Errorf("%v", bk)
	}
	brief := msg.forChannel(notifyChannel{DigestStyle: digestStyleBrief})
	if brief.Style != digestStyleBrief || !strings.Contains(brief.Body, "最常听的歌手：周杰伦") {
		t.Errorf("测一下也按渠道选的那一套改写: %+v", brief)
	}
}

// 排过版的被平台说格式不对:当场改推纯文本;地址、密钥这类问题不重推。
func TestPushFallsBackToPlainWhenFormattedRejected(t *testing.T) {
	useDigestFeatures(t, featureFlags{DigestTopN: 2})
	var mu sync.Mutex
	var bodies []map[string]any
	status := http.StatusBadRequest
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		var m map[string]any
		_ = json.Unmarshal(b, &m)
		mu.Lock()
		bodies = append(bodies, m)
		mu.Unlock()
		if m["parse_mode"] != nil {
			w.WriteHeader(status)
			io.WriteString(w, `{"ok":false,"error_code":400,"description":"Bad Request: can't parse entities"}`)
			return
		}
		io.WriteString(w, `{"ok":true}`)
	}))
	t.Cleanup(srv.Close)
	ch := notifyChannel{ID: "c", Platform: platformTelegram, URL: srv.URL + "/botT/sendMessage", ChatID: "42", Enabled: true}
	r := pushToChannel(ch, richMessage())
	if !r.OK || len(bodies) != 2 || bodies[1]["parse_mode"] != nil || bodies[1]["text"] != richMessage().Title+"\n"+richMessage().Body {
		t.Fatalf("ok=%v kind=%s 次数=%d", r.OK, r.Kind, len(bodies))
	}
	bodies, status = nil, http.StatusUnauthorized
	if r := pushToChannel(ch, richMessage()); r.OK || len(bodies) != 1 {
		t.Errorf("令牌不对不该改格式重推: ok=%v 次数=%d", r.OK, len(bodies))
	}
}

// 推送记录存下这份数,重发时照它重新排版。
func TestNotifyLogKeepsDigestForResend(t *testing.T) {
	withNotifyLogForTest(t)
	ch := notifyChannel{ID: "c1", Platform: platformTelegram}
	recordNotifyDelivery(ch, richMessage(), notifyResult{Kind: notifyKindServer})
	f := readNotifyLog(notifyLogPath)
	if len(f.Entries) != 1 || f.Entries[0].Digest == nil || f.Entries[0].Digest.NewArtists != 44 || f.Entries[0].Digest.CoverURL == "" {
		t.Fatalf("%+v", f.Entries)
	}
}

func TestClipRunesKeepsCombiningMarksWithTheirLetter(t *testing.T) {
	for _, c := range []struct {
		in   string
		n    int
		want string
	}{
		{"abcdef", 6, "abcdef"},
		{"abcdefg", 6, "abcde…"},
		{"เนื้อเพลง", 5, "เนื้…"},
		{"เนื้อเพลง", 4, "เ…"},
		{"เนื้อเพลง", 3, "เ…"},
		{"เนื้อเพลง", 6, "เนื้อ…"},
	} {
		if got := clipRunes(c.in, c.n); got != c.want {
			t.Errorf("clipRunes(%q, %d) = %q, want %q", c.in, c.n, got, c.want)
		}
	}
}
