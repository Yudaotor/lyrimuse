package main

import (
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
)

// amll-ttml-db 歌词源(2026-08-23)。
//
// 它是社区维护的 Apple Music 风格 TTML 歌词库(CC0、免登录、raw 直取),跟现有五个源
// 最大的不同是**歌词格式本身能携带结构化信息**:
//
//	<ttm:agent type="person" xml:id="v1"/>      ← 演唱者在 head 里声明
//	<p begin="00:26.510" ttm:agent="v1">        ← 每一行明确归属
//	  <span begin="00:26.510" end="00:26.740">没</span>   ← 逐字
//	  <span ttm:role="x-translation" xml:lang="zh-CN">…</span>  ← 内嵌译文
//
// LRC / Enhanced LRC(A2) / 网易云 YRC / QQ QRC 四种格式在**规范层面**都装不下演唱者
// 信息(AMLL 官方格式对照表里 "Native background/duet" 一列只有 TTML 和 .lys 是 Yes),
// 所以现有五个源的对唱标注全是歌词上传者用行首前缀夹带的民间写法。这个源是唯一能拿到
// 真·结构化对唱的路子。
//
// ⚠️ 覆盖率有限:实测(2026-08-23)对用户 439 首曲库严格命中 **17 首(3.9%)** ——
// 口径是"歌名一字不差 + 只算 ncm/qq 两个平台"(只有这两个平台的音乐 ID 我们拿得到)。
// 别用"去掉括号后缀再比"的宽松口径去估这个数:那样会把《告白气球 (Live)》算成录音室版
// 的命中,而按 ID 直取时 Live 版有自己的 songID、amll 里并没有,实测就是 404。
//
// 库的重心也跟华语老歌不重合:索引里 HOYO-MiX(米哈游)841 条、Shawn Mendes/Camila
// Cabello 各 510、Taylor Swift 418、原子邦妮 395、GARNiDELiA 332 —— 游戏音乐 / V 家 /
// 欧美新流行为主,华语部分主要是周杰伦(176)和邓紫棋。用户库那 17 首里 11 首是周杰伦。
//
// 接它的理由是**命中那些歌的歌词质量**(逐字 + 内嵌译文 + 人工校对),不是对唱兼容率 ——
// 用户库里 15 首对唱歌它只有 3 首,而那 3 首现有解析已经能处理。
//
// 取用方式:不下载索引(ncm+qq 两份共 7.8MB),直接按音乐 ID 试取 raw 文件,404 即没有。

const (
	amllRawBase     = "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main"
	amllHTTPTimeout = 8 * time.Second
	// 背景人声(ttm:role="x-bg")跳过,不并进主歌词:它跟主歌词时间轴重叠,并进去会让
	// 逐字填色同一时刻有两个词在亮。我们还没有"背景人声"这个显示概念,先如实丢掉。
	amllRoleBackground  = "x-bg"
	amllRoleTranslation = "x-translation"
)

type amllResult struct {
	lrc, yrc, tr string
	// hasDuet:这份 TTML 里出现了两个及以上的非 group 演唱者。只用于日志,选源不看它。
	hasDuet bool
}

func (r amllResult) empty() bool { return r.lrc == "" && r.yrc == "" }

// ---- TTML 结构 ----
//
// 命名空间:ttm = http://www.w3.org/ns/ttml#metadata, xml = XML 内建。
// Go 的 encoding/xml 用 "命名空间URI 局部名" 的形式指定带命名空间的属性。

type ttmlDoc struct {
	XMLName xml.Name    `xml:"tt"`
	Agents  []ttmlAgent `xml:"head>metadata>agent"`
	Divs    []ttmlDiv   `xml:"body>div"`
}

type ttmlAgent struct {
	Type string `xml:"type,attr"`
	ID   string `xml:"http://www.w3.org/XML/1998/namespace id,attr"`
}

type ttmlDiv struct {
	Lines []ttmlLine `xml:"p"`
}

// ⚠️ 一行/一个 span 的孩子必须按**文档顺序**读,不能用声明式 tag。2026-08-24 用户截图
// 报「这些歌词没有翻译」,根因就在这里:原来 ttmlLine/ttmlSpan 写的是一个 Spans []ttmlSpan
// 加一个 xml:",chardata" 字段,而 Go 的 encoding/xml 会把一个元素的**全部**直接文本合并成
// 一个字符串 —— 位置信息全丢。而位置就是全部要点,因为
// amll-ttml-db 里两种写法并存:
//
//	<span>What</span> <span>a</span> <span>ride</span>   ← 空格在 span **之间**(父节点 chardata)
//	<span>How </span><span>it </span><span>goes</span>   ← 空格在 span **内部**
//
// 前者的空白收不到,拼出来就是 "Whataride"。往下的连锁反应:粘住的假词翻译器原样返回,
// translate.go 那道「没翻动的行不写进译文」(t == l.text)把整行丢掉 → 用户看到的
// 「没有翻译」。实测用户库 4 首 amll 来源的歌全中,每首 26~42 行粘连。
// 中文那种逐字写法(<span>没</span><span>有</span>)span 之间本来就没有空白,不受影响。
const ttmMetadataNS = "http://www.w3.org/ns/ttml#metadata"

// ttmlNode 是一个元素的一个孩子:Span == nil 表示这是一段字面文本(词之间的空白就在
// 这儿),否则是一个子 span。
type ttmlNode struct {
	Text string
	Span *ttmlSpan
}

type ttmlLine struct {
	Begin string
	End   string
	Agent string
	Kids  []ttmlNode
}

type ttmlSpan struct {
	Begin string
	End   string
	Role  string
	Kids  []ttmlNode
}

// decodeTTMLKids 按文档顺序读完当前元素的孩子(读到它的 EndElement 为止)。
// 只认 span 子元素,其余整枝跳过 —— TTML 里 <p> 下面出现别的元素属于我们不处理的形态,
// 跳过比猜着解析安全。
func decodeTTMLKids(d *xml.Decoder) ([]ttmlNode, error) {
	var kids []ttmlNode
	for {
		tok, err := d.Token()
		if err != nil {
			// 元素没闭合就到头了 = 这份 TTML 坏了。往上冒,让 parseAMLLTTML 整份判废、
			// 退回其它源,别把半份歌词当成功。
			return kids, err
		}
		switch t := tok.(type) {
		case xml.CharData:
			// 立刻转成 string:Token 返回的字节只在下次 Token 之前有效。
			if s := string(t); s != "" {
				kids = append(kids, ttmlNode{Text: s})
			}
		case xml.StartElement:
			if t.Name.Local != "span" {
				if err := d.Skip(); err != nil {
					return kids, err
				}
				continue
			}
			var sp ttmlSpan
			if err := d.DecodeElement(&sp, &t); err != nil {
				return kids, err
			}
			kids = append(kids, ttmlNode{Span: &sp})
		case xml.EndElement:
			return kids, nil
		}
	}
}

func (l *ttmlLine) UnmarshalXML(d *xml.Decoder, start xml.StartElement) error {
	for _, a := range start.Attr {
		switch {
		case a.Name.Space == "" && a.Name.Local == "begin":
			l.Begin = a.Value
		case a.Name.Space == "" && a.Name.Local == "end":
			l.End = a.Value
		case a.Name.Space == ttmMetadataNS && a.Name.Local == "agent":
			l.Agent = a.Value
		}
	}
	kids, err := decodeTTMLKids(d)
	l.Kids = kids
	return err
}

func (s *ttmlSpan) UnmarshalXML(d *xml.Decoder, start xml.StartElement) error {
	for _, a := range start.Attr {
		switch {
		case a.Name.Space == "" && a.Name.Local == "begin":
			s.Begin = a.Value
		case a.Name.Space == "" && a.Name.Local == "end":
			s.End = a.Value
		case a.Name.Space == ttmMetadataNS && a.Name.Local == "role":
			s.Role = a.Value
		}
	}
	kids, err := decodeTTMLKids(d)
	s.Kids = kids
	return err
}

// text 是这个 span 里的全部字面文本(含子 span,按文档顺序)。
func (s *ttmlSpan) text() string {
	var b strings.Builder
	for _, k := range s.Kids {
		if k.Span == nil {
			b.WriteString(k.Text)
		} else {
			b.WriteString(k.Span.text())
		}
	}
	return b.String()
}

// hasSpanKid:这个 span 里还套着 span —— 它自己不是一个词,要往下拆。
func (s *ttmlSpan) hasSpanKid() bool {
	for _, k := range s.Kids {
		if k.Span != nil {
			return true
		}
	}
	return false
}

// ttmlWord 是一个逐字词。text 里**含**它后面那段分隔空白(原文有的话)——
// 这样 words 拼起来恒等于整行文本,Swift 侧 `plainText = words.joined()` 才对得上
// (对不上会让逐字填色整行不生效,见 MenuBarStatusItem.karaokeFillPath 那道守卫),
// 而且填色边界落在空格之后,跟 amll 里那些本来就把空格写在 span 内部的行完全一致。
type ttmlWord struct {
	begin, end, text string
}

// parseTTMLTime 解析 TTML 的时间戳。见过两种写法:`mm:ss.mmm` 和 `hh:mm:ss.mmm`。
// 返回毫秒;解析不了返回 -1(调用方据此丢弃这一行/这个词)。
func parseTTMLTime(s string) int {
	s = strings.TrimSpace(s)
	if s == "" {
		return -1
	}
	parts := strings.Split(s, ":")
	if len(parts) < 2 || len(parts) > 3 {
		return -1
	}
	var total float64
	for _, p := range parts {
		v, err := strconv.ParseFloat(p, 64)
		if err != nil || v < 0 {
			return -1
		}
		total = total*60 + v
	}
	return int(total*1000 + 0.5)
}

func formatLRCTime(ms int) string {
	if ms < 0 {
		ms = 0
	}
	return fmt.Sprintf("[%02d:%02d.%02d]", ms/60000, (ms/1000)%60, (ms%1000)/10)
}

// amllSpeakerPrefixes 把 TTML 的 agent 映射成我们的行首前缀。
//
// 为什么要绕这一道:歌词落盘/传给 App 的格式是 .lrc/.yrc 文本,装不下 agent 属性,
// 所以把归属编码成行首前缀,复用 Swift 侧 LyricDuet 那条现成的管线(它认得 v1/v2 这类
// 匿名声部,见 LyricDuet.anonymousMarkers)。
//
// 两个刻意的处理:
//   - group 类型统一写成「合」(已知声部词,直通判据、UI 上居中)。
//   - person/other 按**出现顺序**重新编号成 v1/v2/…,不用原始 xml:id —— 规范惯例是
//     group 用 v1000,直接透传会落到 anonymousMarkers 范围之外。
//   - **只有一位非 group 演唱者时不写前缀**:TTML 规范要求单人歌也标 ttm:agent="v1",
//     照写就是给每一首单人歌的每一行都加个没用的「v1：」,徒增噪音。
func amllSpeakerPrefixes(agents []ttmlAgent) map[string]string {
	var persons []string
	groups := map[string]bool{}
	for _, a := range agents {
		if a.ID == "" {
			continue
		}
		if strings.EqualFold(a.Type, "group") {
			groups[a.ID] = true
		} else {
			persons = append(persons, a.ID)
		}
	}
	out := map[string]string{}
	for id := range groups {
		out[id] = "合"
	}
	if len(persons) < 2 {
		return out
	}
	sort.Strings(persons) // v1 < v2 < …,与 TTML 里的声明顺序一致
	for i, id := range persons {
		if i >= 8 { // anonymousMarkers 只到 v8,超出的不标(极罕见)
			break
		}
		out[id] = fmt.Sprintf("v%d", i+1)
	}
	return out
}

// flattenTTMLLine 把一行的有序孩子拆成「逐字词」和「译文」两摊。
// 背景人声整枝跳过(见 amllRoleBackground);span 之间的字面文本(词间空白)挂到**前一个
// 词**的尾巴上,见 ttmlWord 的注释。
func flattenTTMLLine(kids []ttmlNode, words *[]ttmlWord, translation *string) {
	for _, k := range kids {
		if k.Span == nil {
			appendTTMLGap(words, k.Text)
			continue
		}
		sp := k.Span
		switch {
		case sp.Role == amllRoleBackground:
			continue
		case sp.Role == amllRoleTranslation:
			if *translation == "" {
				*translation = strings.TrimSpace(sp.text())
			}
		case sp.hasSpanKid():
			flattenTTMLLine(sp.Kids, words, translation)
		default:
			*words = append(*words, ttmlWord{begin: sp.Begin, end: sp.End, text: sp.text()})
		}
	}
}

// appendTTMLGap 把 span 之间那段字面文本并进前一个词。
//
// 空白折成**一个**空格:实测同一份文件里 span 之间有 1 个空格的、也有 4 个的(行尾那种),
// 原样保留会在歌词里留一串洞。非空白内容(极罕见的裸文本)按 trim 后原样留下 —— 丢掉
// 才是真的改歌词。行首那段空白没有可挂的词,直接丢。
func appendTTMLGap(words *[]ttmlWord, raw string) {
	if raw == "" || len(*words) == 0 {
		return
	}
	body := strings.TrimSpace(raw)
	last := &(*words)[len(*words)-1]
	if body == "" {
		if !strings.HasSuffix(last.text, " ") {
			last.text += " "
		}
		return
	}
	if strings.HasPrefix(raw, " ") || strings.HasPrefix(raw, "\t") ||
		strings.HasPrefix(raw, "\n") || strings.HasPrefix(raw, "\r") {
		body = " " + body
	}
	if strings.HasSuffix(raw, " ") || strings.HasSuffix(raw, "\t") ||
		strings.HasSuffix(raw, "\n") || strings.HasSuffix(raw, "\r") {
		body += " "
	}
	last.text += body
}

// trimTTMLWordEdges 去掉整行首尾的空白:整行文本是 words **原样**拼出来的,首尾留着空白
// 会让逐字填色多出一段永远填不满的宽度。变空的词直接剔掉(它本来也进不了 YRC)。
func trimTTMLWordEdges(words []ttmlWord) []ttmlWord {
	const cut = " \t\r\n"
	for len(words) > 0 {
		t := strings.TrimLeft(words[0].text, cut)
		if t == "" {
			words = words[1:]
			continue
		}
		words[0].text = t
		break
	}
	for len(words) > 0 {
		t := strings.TrimRight(words[len(words)-1].text, cut)
		if t == "" {
			words = words[:len(words)-1]
			continue
		}
		words[len(words)-1].text = t
		break
	}
	return words
}

// parseAMLLTTML 把一份 TTML 转成我们的三件套(整行 LRC / 逐字 YRC / 译文 LRC)。
func parseAMLLTTML(raw string) (amllResult, bool) {
	var doc ttmlDoc
	if err := xml.Unmarshal([]byte(raw), &doc); err != nil {
		return amllResult{}, false
	}
	prefixes := amllSpeakerPrefixes(doc.Agents)
	var lrc, yrc, tr strings.Builder
	lines, distinctPersons := 0, map[string]bool{}
	for _, div := range doc.Divs {
		for _, ln := range div.Lines {
			start := parseTTMLTime(ln.Begin)
			if start < 0 {
				continue
			}
			var words []ttmlWord
			translation := ""
			flattenTTMLLine(ln.Kids, &words, &translation)
			words = trimTTMLWordEdges(words)

			prefix := ""
			if p, ok := prefixes[ln.Agent]; ok {
				prefix = p + "："
			}
			if p, ok := prefixes[ln.Agent]; ok && p != "合" {
				distinctPersons[p] = true
			}

			// 整行文本:优先拼逐字词(**原样**拼接,分隔空白已经在词里了 —— 见 ttmlWord),
			// 没有逐字数据时退回 <p> 自己的字面文本。
			body := ttmlWordsText(words)
			if body == "" {
				body = strings.TrimSpace(ttmlLiteralText(ln.Kids))
			}
			if body == "" {
				continue
			}
			lines++
			lrc.WriteString(formatLRCTime(start) + prefix + body + "\n")
			if translation != "" {
				tr.WriteString(formatLRCTime(start) + translation + "\n")
			}
			if w := buildYRCLine(start, parseTTMLTime(ln.End), prefix, words); w != "" {
				yrc.WriteString(w + "\n")
			}
		}
	}
	if lines == 0 {
		return amllResult{}, false
	}
	return amllResult{
		lrc:     lrc.String(),
		yrc:     yrc.String(),
		tr:      tr.String(),
		hasDuet: len(distinctPersons) >= 2,
	}, true
}

// ttmlWordsText 把逐字词原样拼成整行文本。**必须**跟 buildYRCLine 写进 YRC 的那串词
// 逐字节一致 —— Swift 侧靠 `plainText == words.joined()` 判断这一行的逐字数据可不可信。
func ttmlWordsText(words []ttmlWord) string {
	var b strings.Builder
	for _, w := range words {
		b.WriteString(w.text)
	}
	return b.String()
}

// ttmlLiteralText 是一个元素里的全部字面文本(含子 span),给「这一行没有逐字数据」兜底。
func ttmlLiteralText(kids []ttmlNode) string {
	var b strings.Builder
	for _, k := range kids {
		if k.Span == nil {
			b.WriteString(k.Text)
		} else {
			b.WriteString(k.Span.text())
		}
	}
	return b.String()
}

// buildYRCLine 拼一行 YRC:`[行始,行长](词始,词长,0)词…`,与 YRCParser 的语法一致。
//
// 前缀作为**独立的一个词**塞在最前面,时长 0 —— Swift 侧 LyricDuet.planWords 会按字符数
// 把它剥掉,时长 0 保证剥不干净时也不会占用可见的发声时间。
func buildYRCLine(startMs, endMs int, prefix string, words []ttmlWord) string {
	type w struct {
		start, dur int
		text       string
	}
	var ws []w
	for _, sp := range words {
		s, e := parseTTMLTime(sp.begin), parseTTMLTime(sp.end)
		if s < 0 || e < s || sp.text == "" {
			continue
		}
		ws = append(ws, w{s, e - s, sp.text})
	}
	if len(ws) == 0 {
		return ""
	}
	if endMs < startMs {
		endMs = ws[len(ws)-1].start + ws[len(ws)-1].dur
	}
	var b strings.Builder
	fmt.Fprintf(&b, "[%d,%d]", startMs, endMs-startMs)
	if prefix != "" {
		fmt.Fprintf(&b, "(%d,0,0)%s", startMs, prefix)
	}
	for _, x := range ws {
		fmt.Fprintf(&b, "(%d,%d,0)%s", x.start, x.dur, x.text)
	}
	return b.String()
}

// amllFetch 按平台目录 + 音乐 ID 直取 TTML。404 = 这首歌不在库里,不是错误。
func amllFetch(platformDir, musicID string) (string, bool) {
	if platformDir == "" || musicID == "" {
		return "", false
	}
	url := fmt.Sprintf("%s/%s/%s.ttml", amllRawBase, platformDir, musicID)
	client := &http.Client{Timeout: amllHTTPTimeout}
	resp, err := client.Get(url)
	if err != nil {
		return "", false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", false
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return "", false
	}
	return string(body), true
}

// amllLyric 按网易云 / QQ 的音乐 ID 查 amll-ttml-db。两个 ID 都给时先试网易云
// (实测它那份索引最全:命中的 26 首里 20 首有 ncm ID)。
func amllLyric(neteaseID, qqID string) amllResult {
	for _, try := range []struct{ dir, id string }{
		{"ncm-lyrics", neteaseID},
		{"qq-lyrics", qqID},
	} {
		if try.id == "" {
			continue
		}
		raw, ok := amllFetch(try.dir, try.id)
		if !ok {
			continue
		}
		if r, ok := parseAMLLTTML(raw); ok {
			return r
		}
	}
	return amllResult{}
}
