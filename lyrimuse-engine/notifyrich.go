package main

import (
	"encoding/json"
	"fmt"
	"html"
	"net/url"
	"strings"
	"unicode/utf8"
)

// 按平台排版:同一份报告(notifyMessage.Digest),每个平台用它自己支持的格式排 —— Telegram HTML、Discord 卡片(embed)、
// Slack Block Kit、飞书消息卡片、钉钉 markdown、企业微信 markdown_v2、Server酱 markdown;能放图的放头号专辑封面,
// 能点的点开去这一期的完整榜单。Bark、ntfy 正文保持纯文本(Bark 锁屏只显示前几行、ntfy 的 markdown iPhone 不认),
// 只加封面和点击跳转。渠道关了「按平台排版」(notifyChannel.PlainText)就一律推纯文本那份。
//
// 「测一下」那条(Digest 为 nil)也按平台的格式发(标题加粗、卡片),测得出这个渠道收不收排过版的消息。
// 超出平台上限(Telegram 4096 字、企业微信 4096 字节、Slack 一段 3000 字)时不排,推纯文本那份;推出去被平台说
// 格式不对时也当场改推纯文本(pushToChannel)。见 15 章决策 75。

// richColor:Discord 卡片左边那条竖线,同 App 图标的红。
const richColor = 0xE5484D

// buildRichPayload 拼排过版的请求体。ok=false 表示这个平台、这条消息不排,用纯文本那份(buildNotifyPayload)。
func buildRichPayload(ch notifyChannel, msg notifyMessage) (payload []byte, contentType string, ok bool, err error) {
	d := msg.Digest
	var v any
	switch ch.Platform {
	case platformTelegram:
		v, ok = telegramRich(ch.ChatID, msg.Title, msg.Body, d)
	case platformDiscord:
		v, ok = discordRich(msg.Title, msg.Body, d)
	case platformSlack:
		v, ok = slackRich(msg.Title, msg.Body, d)
	case platformFeishu:
		card := feishuRichCard(msg.Title, msg.Body, d)
		m := map[string]any{"msg_type": "interactive", "card": card}
		if ch.Secret != "" {
			ts := feishuTimestamp()
			m["timestamp"], m["sign"] = ts, feishuSign(ts, ch.Secret)
		}
		v, ok = m, true
	case platformDingtalk:
		v, ok = map[string]any{"msgtype": "markdown", "markdown": map[string]string{"title": msg.Title, "text": dingtalkRich(msg.Title, msg.Body, d)}}, true
	case platformWecom:
		content := wecomRich(msg.Title, msg.Body, d)
		v, ok = map[string]any{"msgtype": "markdown_v2", "markdown_v2": map[string]string{"content": content}}, len(content) <= wecomMarkdownMaxBytes
	case platformServerChan:
		if d == nil {
			return nil, "", false, nil
		}
		form := url.Values{"title": {msg.Title}, "desp": {serverChanRich(d)}}
		return []byte(form.Encode()), "application/x-www-form-urlencoded", true, nil
	case platformBark, "":
		if d == nil || (d.CoverURL == "" && d.Link == "") {
			return nil, "", false, nil
		}
		m := map[string]any{"title": msg.Title, "body": msg.Body, "group": "nowplaying", "level": "active"}
		if d.CoverURL != "" {
			m["image"] = d.CoverURL // 长按展开通知时显示大图
		}
		if d.Link != "" {
			m["url"] = d.Link // 点一下打开完整榜单
		}
		v, ok = m, true
	}
	if !ok {
		return nil, "", false, nil
	}
	b, err := json.Marshal(v)
	return b, "application/json", true, err
}

// ---- 共用的几块 ----

// richSection 是榜单的一类:标题(歌手 / 专辑 / 歌曲)和已经排好、按平台转义过的每一行。
type richSection struct {
	heading string
	lines   []string
}

// richSections 按 digestShown 的规则列三类。esc 是这个平台的转义。歌手写「1. 方大同 · 129」,专辑、歌曲写
// 「1. Xscape — Michael Jackson · 30」(排过版的读起来先看名字,纯文本那份照旧「歌手 - 歌名（次数）」)。
func richSections(d *digestStats, esc func(string) string) []richSection {
	var out []richSection
	add := func(heading string, list []digestTally) {
		if !digestShown(list) {
			return
		}
		s := richSection{heading: heading}
		for i, t := range list {
			if t.Sub == "" {
				s.lines = append(s.lines, fmt.Sprintf("%d. %s · %d", i+1, esc(t.Name), t.Count))
			} else {
				s.lines = append(s.lines, fmt.Sprintf("%d. %s — %s · %d", i+1, esc(t.Name), esc(t.Sub), t.Count))
			}
		}
		out = append(out, s)
	}
	add("歌手", d.TopArtists)
	add("专辑", d.TopAlbums)
	add("歌曲", d.TopTracks)
	return out
}

func digestSourceName(d *digestStats) string {
	if d.Source == digestSourceListenBrainz {
		return "ListenBrainz"
	}
	return "Last.fm"
}

func richLinkLabel(d *digestStats) string {
	return "在 " + digestSourceName(d) + " 上看完整榜单"
}

func richFooter(d *digestStats) string { return "Lyrimuse · 数据来自 " + digestSourceName(d) }

// clipRunes:超过 n 个字符的截掉,末尾放省略号(平台对标题有长度上限,超了整条拒收)。
func clipRunes(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	r := []rune(s)
	return string(r[:n-1]) + "…"
}

// ---- Telegram ----

// telegramMaxChars:sendMessage 的 text 上限(按解析掉 HTML 标签以后的字数算,这里按带标签的算,只会更保守)。
const telegramMaxChars = 4096

// telegramRich:parse_mode HTML。名字里的 & < > 必须转义,不然整条解析失败。封面放在链接预览里(link_preview_options.url
// 可以跟正文里的链接不是同一个),显示在文字上方;不用 sendPhoto,它的图片说明只有 1024 字,每类列 10 条就放不下。
func telegramRich(chatID, title, body string, d *digestStats) (any, bool) {
	esc := html.EscapeString
	var b strings.Builder
	b.WriteString("<b>" + esc(title) + "</b>\n")
	if d == nil {
		b.WriteString(esc(body))
	} else {
		b.WriteString(esc(digestSummaryLine(*d)))
		for _, s := range richSections(d, esc) {
			b.WriteString("\n\n<b>Top " + s.heading + "</b>\n" + strings.Join(s.lines, "\n"))
		}
		if line := digestNewArtistsLine(*d); line != "" {
			b.WriteString("\n\n🆕 " + esc(line))
		}
		if d.Link != "" {
			b.WriteString("\n\n<a href=\"" + esc(d.Link) + "\">" + esc(richLinkLabel(d)) + "</a>")
		}
	}
	text := b.String()
	if utf8.RuneCountInString(text) > telegramMaxChars {
		return nil, false
	}
	preview := map[string]any{"is_disabled": true}
	if d != nil && d.CoverURL != "" {
		preview = map[string]any{"url": d.CoverURL, "prefer_large_media": true, "show_above_text": true}
	}
	return map[string]any{
		"chat_id": strings.TrimSpace(chatID), "text": text, "parse_mode": "HTML", "link_preview_options": preview,
	}, true
}

// ---- Discord ----

// Discord embed 的上限:标题 256 字、正文 4096 字、每栏 1024 字。
const (
	discordTitleMax = 256
	discordDescMax  = 4096
	discordFieldMax = 1024
)

// discordEscaper:卡片正文和栏里按 markdown 渲染,名字里的这几个字符转义,免得被当成加粗、删除线、引用、链接。
var discordEscaper = strings.NewReplacer(`\`, `\\`, `*`, `\*`, `_`, `\_`, `~`, `\~`, "`", "\\`", `|`, `\|`, `>`, `\>`, `[`, `\[`, `]`, `\]`)

// discordRich:一张卡片,标题可点(去完整榜单)、右上角封面、歌手 / 专辑 / 歌曲并排三栏。某一栏超过 1024 字时截掉后面的名次。
func discordRich(title, body string, d *digestStats) (any, bool) {
	embed := map[string]any{"title": clipRunes(title, discordTitleMax), "color": richColor}
	if d == nil {
		embed["description"] = clipRunes(discordEscaper.Replace(body), discordDescMax)
		embed["footer"] = map[string]string{"text": "Lyrimuse"}
		return map[string]any{"embeds": []any{embed}}, true
	}
	desc := discordEscaper.Replace(digestSummaryLine(*d))
	if line := digestNewArtistsLine(*d); line != "" {
		desc += "\n\n🆕 " + discordEscaper.Replace(line)
	}
	embed["description"] = clipRunes(desc, discordDescMax)
	var fields []any
	for _, s := range richSections(d, discordEscaper.Replace) {
		lines := s.lines
		for len(lines) > 1 && utf8.RuneCountInString(strings.Join(lines, "\n")) > discordFieldMax {
			lines = lines[:len(lines)-1]
		}
		fields = append(fields, map[string]any{"name": s.heading, "value": clipRunes(strings.Join(lines, "\n"), discordFieldMax), "inline": true})
	}
	if len(fields) > 0 {
		embed["fields"] = fields
	}
	if d.Link != "" {
		embed["url"] = d.Link
	}
	if d.CoverURL != "" {
		embed["thumbnail"] = map[string]string{"url": d.CoverURL}
	}
	embed["footer"] = map[string]string{"text": richFooter(d)}
	return map[string]any{"embeds": []any{embed}}, true
}

// ---- Slack ----

// Slack Block Kit 的上限:header 150 字、一段 section 3000 字。
const (
	slackHeaderMax  = 150
	slackSectionMax = 3000
)

// slackRich:大标题、第一段带封面(右边)、每类一段、底部一行来源和链接。text 是通知横幅和不支持 blocks 的客户端显示的那份。
// 链接写在 context 里,不用按钮:按钮要求这个 Slack App 配了交互地址,Incoming Webhook 点了会报错。
func slackRich(title, body string, d *digestStats) (any, bool) {
	header := map[string]any{"type": "header", "text": map[string]any{"type": "plain_text", "text": clipRunes(title, slackHeaderMax), "emoji": true}}
	section := func(text string) map[string]any {
		return map[string]any{"type": "section", "text": map[string]string{"type": "mrkdwn", "text": text}}
	}
	if d == nil {
		text := slackEscape(body)
		if utf8.RuneCountInString(text) > slackSectionMax {
			return nil, false
		}
		return map[string]any{"text": slackEscape(title) + "\n" + slackEscape(body), "blocks": []any{header, section(text)}}, true
	}
	summary := slackEscape(digestSummaryLine(*d))
	sections := richSections(d, slackEscape)
	blocks := []any{header}
	first := summary
	rest := sections
	if len(sections) > 0 {
		first += "\n\n*Top " + sections[0].heading + "*\n" + strings.Join(sections[0].lines, "\n")
		rest = sections[1:]
	}
	firstBlock := section(first)
	if d.CoverURL != "" {
		alt := "封面"
		if len(d.TopAlbums) > 0 {
			alt = d.TopAlbums[0].Name
		}
		firstBlock["accessory"] = map[string]string{"type": "image", "image_url": d.CoverURL, "alt_text": alt}
	}
	blocks = append(blocks, firstBlock)
	texts := []string{first}
	for _, s := range rest {
		t := "*Top " + s.heading + "*\n" + strings.Join(s.lines, "\n")
		texts = append(texts, t)
		blocks = append(blocks, section(t))
	}
	if line := digestNewArtistsLine(*d); line != "" {
		blocks = append(blocks, section("🆕 "+slackEscape(line)))
	}
	ctx := slackEscape(richFooter(d))
	if d.Link != "" {
		ctx += " · <" + d.Link + "|" + slackEscape(richLinkLabel(d)) + ">"
	}
	blocks = append(blocks, map[string]any{"type": "context", "elements": []any{map[string]string{"type": "mrkdwn", "text": ctx}}})
	for _, t := range texts {
		if utf8.RuneCountInString(t) > slackSectionMax {
			return nil, false
		}
	}
	return map[string]any{"text": slackEscape(title) + "\n" + summary, "blocks": blocks}, true
}

// ---- 飞书 ----

// feishuRichCard:消息卡片(群机器人 webhook 收 msg_type=interactive)。蓝色标题栏、第一行、三栏榜单(窄屏上自动叠成一列)、
// 新听的歌手、去完整榜单的按钮、来源。名字都放在 plain_text 里,不进 markdown,不用转义。不带封面:卡片里的图片要先用
// 应用凭据上传换 image_key,群机器人地址做不到。
func feishuRichCard(title, body string, d *digestStats) map[string]any {
	plain := func(s string) map[string]any {
		return map[string]any{"tag": "div", "text": map[string]string{"tag": "plain_text", "content": s}}
	}
	card := map[string]any{
		"config": map[string]bool{"wide_screen_mode": true},
		"header": map[string]any{"title": map[string]string{"tag": "plain_text", "content": title}, "template": "blue"},
	}
	if d == nil {
		card["elements"] = []any{plain(body)}
		return card
	}
	elements := []any{plain(digestSummaryLine(*d))}
	var columns []any
	for _, s := range richSections(d, func(s string) string { return s }) {
		columns = append(columns, map[string]any{
			"tag": "column", "width": "weighted", "weight": 1, "vertical_align": "top",
			"elements": []any{
				map[string]string{"tag": "markdown", "content": "**" + s.heading + "**"},
				plain(strings.Join(s.lines, "\n")),
			},
		})
	}
	if len(columns) > 0 {
		elements = append(elements, map[string]any{"tag": "column_set", "flex_mode": "stretch", "background_style": "default", "columns": columns})
	}
	if line := digestNewArtistsLine(*d); line != "" {
		elements = append(elements, plain("🆕 "+line))
	}
	if d.Link != "" {
		elements = append(elements, map[string]any{"tag": "action", "actions": []any{map[string]any{
			"tag": "button", "type": "default", "url": d.Link,
			"text": map[string]string{"tag": "plain_text", "content": richLinkLabel(d)},
		}}})
	}
	elements = append(elements, map[string]any{"tag": "note", "elements": []any{map[string]string{"tag": "plain_text", "content": richFooter(d)}}})
	card["elements"] = elements
	return card
}

// ---- markdown 系(钉钉、企业微信、Server酱) ----

// markdownEscaper:名字里会被当成 markdown 语法的字符加反斜杠(企业微信 markdown_v2、Server酱按标准 markdown 渲染)。
var markdownEscaper = strings.NewReplacer(`\`, `\\`, "`", "\\`", `*`, `\*`, `_`, `\_`, `[`, `\[`, `]`, `\]`, `<`, `\<`, `>`, `\>`, `|`, `\|`, `~`, `\~`)

// markdownDigest 拼 markdown 正文的主体:第一行加粗、每类一个小标题和有序列表、新听的歌手、链接。
// heading 是小节标题的前缀(「#### 」或加粗),br 是行与行之间怎么断(钉钉要行尾两个空格才换行)。
func markdownDigest(d *digestStats, esc func(string) string, heading func(string) string, br string) string {
	var b strings.Builder
	b.WriteString("**" + esc(digestSummaryLine(*d)) + "**")
	for _, s := range richSections(d, esc) {
		b.WriteString("\n\n" + heading("Top "+s.heading) + "\n\n" + strings.Join(s.lines, br))
	}
	if line := digestNewArtistsLine(*d); line != "" {
		b.WriteString("\n\n🆕 " + esc(line))
	}
	if d.Link != "" {
		b.WriteString("\n\n[" + richLinkLabel(d) + "](" + d.Link + ")")
	}
	return b.String()
}

func markdownCover(d *digestStats) string {
	if d == nil || d.CoverURL == "" {
		return ""
	}
	return "![封面](" + d.CoverURL + ")\n\n"
}

// dingtalkRich:钉钉 markdown。只支持 markdown 的一个子集,名字不转义(它不认反斜杠转义,转了会原样显示出来);
// 行尾两个空格才换行。末尾一行「Lyrimuse」:开了「自定义关键词」安全设置的机器人,把关键词设成 Lyrimuse 就能收。
func dingtalkRich(title, body string, d *digestStats) string {
	if d == nil {
		return "#### " + title + "\n\n" + strings.ReplaceAll(body, "\n", "  \n")
	}
	bold := func(s string) string { return "**" + s + "**" }
	return "#### " + title + "\n\n" + markdownCover(d) + markdownDigest(d, func(s string) string { return s }, bold, "  \n") +
		"\n\n###### " + richFooter(d)
}

// wecomMarkdownMaxBytes:企业微信 markdown_v2 的 content 上限。
const wecomMarkdownMaxBytes = 4096

// wecomRich:企业微信 markdown_v2(标题、图片、列表、链接都认;旧版企业微信 4.1.36 以下会显示成带符号的纯文本 —— 群里有人用旧版
// 就在这个渠道上关掉「按平台排版」)。
func wecomRich(title, body string, d *digestStats) string {
	if d == nil {
		return "# " + title + "\n\n" + markdownEscaper.Replace(body)
	}
	bold := func(s string) string { return "**" + s + "**" }
	return "# " + title + "\n\n" + markdownCover(d) + markdownDigest(d, markdownEscaper.Replace, bold, "\n") + "\n\n> " + richFooter(d)
}

// serverChanRich:Server酱的 desp 按 markdown 渲染(微信里收到标题那条提醒,点进去看的是这一页)。
func serverChanRich(d *digestStats) string {
	h4 := func(s string) string { return "#### " + s }
	return markdownCover(d) + markdownDigest(d, markdownEscaper.Replace, h4, "\n") + "\n\n> " + richFooter(d)
}

// ---- 通用 Webhook ----

// webhookDigestData 是听歌报告推到通用 Webhook 时多带的 data:结构化的数,给 Home Assistant、n8n 直接取值。字段只增不改。
type webhookDigestData struct {
	From              string               `json:"from"` // 这一期的起止日期(本地,含两头)
	To                string               `json:"to"`
	Source            string               `json:"source"` // lastfm / listenbrainz
	TotalPlays        int                  `json:"total_plays"`
	Truncated         bool                 `json:"truncated,omitempty"` // 记录太多只统计了最近那部分,total_plays 是下限
	PreviousPlays     int                  `json:"previous_plays,omitempty"`
	DurationMinutes   int64                `json:"duration_minutes,omitempty"`
	DurationEstimated bool                 `json:"duration_estimated,omitempty"`
	TopArtists        []webhookDigestTally `json:"top_artists"`
	TopAlbums         []webhookDigestTally `json:"top_albums"`
	TopTracks         []webhookDigestTally `json:"top_tracks"`
	NewArtists        *webhookNewArtists   `json:"new_artists,omitempty"`
	CoverURL          string               `json:"cover_url,omitempty"`
	Link              string               `json:"link,omitempty"`
}

type webhookDigestTally struct {
	Name   string `json:"name"`
	Artist string `json:"artist,omitempty"`
	Count  int    `json:"count"`
}

type webhookNewArtists struct {
	Count int      `json:"count"`
	Names []string `json:"names"`
}

func webhookDigest(d *digestStats) *webhookDigestData {
	if d == nil {
		return nil
	}
	tallies := func(list []digestTally) []webhookDigestTally {
		out := make([]webhookDigestTally, 0, len(list))
		for _, t := range list {
			out = append(out, webhookDigestTally{Name: t.Name, Artist: t.Sub, Count: t.Count})
		}
		return out
	}
	w := &webhookDigestData{From: d.From, To: d.To, Source: d.Source, TotalPlays: d.TotalPlays, Truncated: d.Truncated,
		PreviousPlays: d.PrevPlays, DurationMinutes: d.TotalDurationMs / 60000, DurationEstimated: d.DurationEstimated,
		TopArtists: tallies(d.TopArtists), TopAlbums: tallies(d.TopAlbums), TopTracks: tallies(d.TopTracks),
		CoverURL: d.CoverURL, Link: d.Link}
	if d.NewArtists > 0 {
		w.NewArtists = &webhookNewArtists{Count: d.NewArtists, Names: d.NewArtistNames}
	}
	return w
}
