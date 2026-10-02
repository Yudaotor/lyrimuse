package main

import "strings"

// untimedLyricsMinLines:不带时间戳的歌词至少要这么多行正文才交出去。网易云 / QQ 对没词的歌会给一两行的占位
// (「N/A」、一句口白提示),这道线把它们挡掉。
const untimedLyricsMinLines = 3

// untimedLyricsText 把源给的「不带时间戳的歌词」(网易云 / QQ 只有纯文本时)理成可以当 plainOnly 交出去的正文:
// 统一换行,去掉 [ti:] 这类元数据标签行、行首零星的时间戳和署名行,连续的空行收成一行。正文不到
// untimedLyricsMinLines 行,或者整份是纯音乐占位,返回空串。
func untimedLyricsText(raw string) string {
	if isInstrumentalPlaceholderLyric(raw) {
		return ""
	}
	var out []string
	body := 0
	for _, l := range strings.Split(strings.NewReplacer("\r\n", "\n", "\r", "\n").Replace(raw), "\n") {
		if isLRCMetaTagLine(l) {
			continue
		}
		l = strings.TrimSpace(lrcTimestampRe.ReplaceAllString(l, ""))
		if l == "" {
			if len(out) > 0 && out[len(out)-1] != "" {
				out = append(out, "")
			}
			continue
		}
		if isCreditLine(l) {
			continue
		}
		out = append(out, l)
		body++
	}
	if body < untimedLyricsMinLines {
		return ""
	}
	return strings.TrimSpace(strings.Join(out, "\n"))
}
