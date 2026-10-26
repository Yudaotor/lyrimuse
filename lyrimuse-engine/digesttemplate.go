package main

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// 听歌报告的自定义内容(推送提醒页「推送内容」):标题、正文各一段模板,四档共用,用 {占位符} 取这一期的数。
// 模板是空的、或者跟默认一字不差(标题 {title}、正文 {body})时按默认推,照旧按平台排版;用了自定义就按纯文本推,
// 不套各平台的卡片排版(notifyrich.go),Bark / ntfy 照旧带封面和点击跳转,通用 Webhook 照旧带 data。
// App 侧同一套渲染在 Core `DigestTemplate`,两边对得上靠共用样例 shared/testdata/notify/template.json。见 15 章决策 84。

// digestTemplate 是 features.json 的 digest_template。
type digestTemplate struct {
	Title string `json:"title,omitempty"`
	Body  string `json:"body,omitempty"`
}

const (
	digestTemplateDefaultTitle = "{title}"
	digestTemplateDefaultBody  = "{body}"
	// digestTemplateMaxRunes:每段模板最多留多少字,文件里手写的超长内容截掉(推送平台本来就有上限)。
	digestTemplateMaxRunes = 4000
)

// resolveDigestTemplate:跟默认一样的那一段存成空;超长的截断。
func resolveDigestTemplate(t *digestTemplate) digestTemplate {
	if t == nil {
		return digestTemplate{}
	}
	clean := func(s, def string) string {
		s = strings.ReplaceAll(s, "\r\n", "\n")
		if strings.TrimSpace(s) == def {
			return ""
		}
		if r := []rune(s); len(r) > digestTemplateMaxRunes {
			s = string(r[:digestTemplateMaxRunes])
		}
		return s
	}
	return digestTemplate{Title: clean(t.Title, digestTemplateDefaultTitle), Body: clean(t.Body, digestTemplateDefaultBody)}
}

// custom:有没有自定义(标题、正文任一段)。
func (t digestTemplate) custom() bool {
	return strings.TrimSpace(t.Title) != "" || strings.TrimSpace(t.Body) != ""
}

var digestPlaceholderRe = regexp.MustCompile(`\{([a-z_]+)\}`)

// digestPlaceholderNames:认得的占位符,顺序同 App 编辑器里那一排(Core `DigestTemplate.placeholders`),两边要一致。
var digestPlaceholderNames = []string{
	"title", "body", "summary", "plays", "prev_plays", "prev_label", "change", "duration",
	"top_artists", "top_albums", "top_tracks", "top_artist", "top_album", "top_track",
	"new_artists", "new_artist_names", "source", "from", "to", "link",
}

// digestPlaceholders 算这一期每个占位符的值。取不到的是空串(那一行整行不写,见 renderDigestTemplateText)。
// defaultTitle / defaultBody 是默认会推的标题和正文。
func digestPlaceholders(defaultTitle, defaultBody string, s digestStats, topN int) map[string]string {
	v := make(map[string]string, len(digestPlaceholderNames))
	for _, name := range digestPlaceholderNames {
		v[name] = ""
	}
	v["title"], v["body"], v["summary"] = defaultTitle, defaultBody, digestSummaryLine(s)
	v["plays"], v["source"] = strconv.Itoa(s.TotalPlays), digestSourceName(&s)
	v["from"], v["to"], v["link"] = s.From, s.To, s.Link
	if s.PrevPlays > 0 && s.PrevLabel != "" && !s.Truncated {
		v["prev_plays"] = strconv.Itoa(s.PrevPlays)
		v["prev_label"] = s.PrevLabel
		v["change"] = digestChange(s.TotalPlays, s.PrevPlays)
	}
	if m := s.TotalDurationMs / 60000; m >= 60 {
		v["duration"] = fmt.Sprintf("%d 小时 %d 分", m/60, m%60)
	} else if m > 0 {
		v["duration"] = fmt.Sprintf("%d 分", m)
	}
	list := func(tallies []digestTally) (lines, first string) {
		if len(tallies) > topN {
			tallies = tallies[:topN]
		}
		var b strings.Builder
		for i, t := range tallies {
			name := t.Name
			if t.Sub != "" {
				name = t.Sub + " - " + t.Name
			}
			if i == 0 {
				first = name
			} else {
				b.WriteString("\n")
			}
			fmt.Fprintf(&b, "%d. %s（%d）", i+1, name, t.Count)
		}
		return b.String(), first
	}
	v["top_artists"], v["top_artist"] = list(s.TopArtists)
	v["top_albums"], v["top_album"] = list(s.TopAlbums)
	v["top_tracks"], v["top_track"] = list(s.TopTracks)
	if s.NewArtists > 0 {
		v["new_artists"] = strconv.Itoa(s.NewArtists)
		v["new_artist_names"] = strings.Join(s.NewArtistNames, "、")
	}
	return v
}

// renderDigestTemplateText 按行替换:一行里认得的占位符全都取不到值时整行不写(「跟上一期比」日报没有,那一行就没了);
// 认不得的 {xxx} 原样留着。首尾空行去掉。
func renderDigestTemplateText(tpl string, values map[string]string) string {
	var out []string
	for _, line := range strings.Split(strings.ReplaceAll(tpl, "\r\n", "\n"), "\n") {
		known, filled := 0, 0
		rendered := digestPlaceholderRe.ReplaceAllStringFunc(line, func(m string) string {
			value, ok := values[m[1:len(m)-1]]
			if !ok {
				return m
			}
			known++
			if value != "" {
				filled++
			}
			return value
		})
		if known > 0 && filled == 0 {
			continue
		}
		out = append(out, strings.TrimRight(rendered, " \t"))
	}
	return strings.Trim(strings.Join(out, "\n"), "\n")
}

// renderDigestTemplate 出这一期实际推的标题和正文。哪一段没自定义、或者渲染出来是空的,那一段用默认。
func renderDigestTemplate(t digestTemplate, defaultTitle, defaultBody string, s digestStats, topN int) (title, body string) {
	values := digestPlaceholders(defaultTitle, defaultBody, s, topN)
	title, body = defaultTitle, defaultBody
	if strings.TrimSpace(t.Title) != "" {
		// 标题只有一行:模板里的换行当空格。
		if r := strings.TrimSpace(strings.ReplaceAll(renderDigestTemplateText(t.Title, values), "\n", " ")); r != "" {
			title = r
		}
	}
	if strings.TrimSpace(t.Body) != "" {
		if r := renderDigestTemplateText(t.Body, values); strings.TrimSpace(r) != "" {
			body = r
		}
	}
	return title, body
}
