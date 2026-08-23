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

type ttmlLine struct {
	Begin string     `xml:"begin,attr"`
	End   string     `xml:"end,attr"`
	Agent string     `xml:"http://www.w3.org/ns/ttml#metadata agent,attr"`
	Spans []ttmlSpan `xml:"span"`
	Text  string     `xml:",chardata"`
}

type ttmlSpan struct {
	Begin string     `xml:"begin,attr"`
	End   string     `xml:"end,attr"`
	Role  string     `xml:"http://www.w3.org/ns/ttml#metadata role,attr"`
	Text  string     `xml:",chardata"`
	Spans []ttmlSpan `xml:"span"`
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

// flattenSpans 把一行里的 span 拆成「逐字词」和「译文」两摊。
// 背景人声整枝跳过(见 amllRoleBackground)。
func flattenSpans(spans []ttmlSpan, words *[]ttmlSpan, translation *string) {
	for _, sp := range spans {
		switch {
		case sp.Role == amllRoleBackground:
			continue
		case sp.Role == amllRoleTranslation:
			if *translation == "" {
				*translation = strings.TrimSpace(sp.Text)
			}
		case len(sp.Spans) > 0:
			flattenSpans(sp.Spans, words, translation)
		default:
			*words = append(*words, sp)
		}
	}
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
			var words []ttmlSpan
			translation := ""
			flattenSpans(ln.Spans, &words, &translation)

			prefix := ""
			if p, ok := prefixes[ln.Agent]; ok {
				prefix = p + "："
			}
			if p, ok := prefixes[ln.Agent]; ok && p != "合" {
				distinctPersons[p] = true
			}

			// 整行文本:优先拼逐字词,没有逐字数据时退回 <p> 自己的文本。
			body := strings.TrimSpace(strings.Join(spanTexts(words), ""))
			if body == "" {
				body = strings.TrimSpace(ln.Text)
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

func spanTexts(spans []ttmlSpan) []string {
	out := make([]string, 0, len(spans))
	for _, sp := range spans {
		out = append(out, sp.Text)
	}
	return out
}

// buildYRCLine 拼一行 YRC:`[行始,行长](词始,词长,0)词…`,与 YRCParser 的语法一致。
//
// 前缀作为**独立的一个词**塞在最前面,时长 0 —— Swift 侧 LyricDuet.planWords 会按字符数
// 把它剥掉,时长 0 保证剥不干净时也不会占用可见的发声时间。
func buildYRCLine(startMs, endMs int, prefix string, words []ttmlSpan) string {
	type w struct {
		start, dur int
		text       string
	}
	var ws []w
	for _, sp := range words {
		s, e := parseTTMLTime(sp.Begin), parseTTMLTime(sp.End)
		if s < 0 || e < s || sp.Text == "" {
			continue
		}
		ws = append(ws, w{s, e - s, sp.Text})
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
