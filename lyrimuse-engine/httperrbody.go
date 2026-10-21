package main

import (
	"encoding/json"
	"html"
	"regexp"
	"strings"
	"unicode/utf8"
)

// httpErrorBodyMax:错误信息里最多带多少字节的响应体。
const httpErrorBodyMax = 200

var htmlTitleRe = regexp.MustCompile(`(?is)<title[^>]*>(.*?)</title>`)

// httpErrorBody:非 200 响应体里放进错误信息(也就进了日志)的那一段。网关、CDN 的 HTML 错误页只取 <title>,
// 取不到就写 "an HTML page";别的压成一行、截到 httpErrorBodyMax 字节。别把整页 HTML 原样拼进错误:一条就是
// 半 KB 带 \n 转义的样式表,服务挂着的时候满屏都是。
//
// JSON 对象带 "error" / "message" 字符串字段时只取它:ListenBrainz 的 400 先把提交的字段原样回显、按键名排序,
// 说明原因的 "error" 排在后面,整段截到 httpErrorBodyMax 字节就只剩回显(见 12 章决策 90)。
func httpErrorBody(contentType string, body []byte) string {
	s := strings.TrimSpace(string(body))
	if s == "" {
		return ""
	}
	if msg := jsonErrorMessage(s); msg != "" {
		return clipUTF8(strings.Join(strings.Fields(msg), " "), httpErrorBodyMax)
	}
	lower := strings.ToLower(s)
	if strings.Contains(strings.ToLower(contentType), "html") ||
		strings.HasPrefix(lower, "<!doctype html") || strings.HasPrefix(lower, "<html") {
		if m := htmlTitleRe.FindStringSubmatch(s); m != nil {
			if title := strings.Join(strings.Fields(html.UnescapeString(m[1])), " "); title != "" {
				return clipUTF8(title, httpErrorBodyMax)
			}
		}
		return "an HTML page"
	}
	return clipUTF8(strings.Join(strings.Fields(s), " "), httpErrorBodyMax)
}

// clipUTF8:超过 max 字节就截到 max 字节以内(不截断字符)再接上省略号。
func clipUTF8(s string, max int) string {
	if len(s) <= max {
		return s
	}
	cut := max
	for cut > 0 && !utf8.RuneStart(s[cut]) {
		cut--
	}
	return s[:cut] + "…"
}

// jsonErrorMessage:s 是 JSON 对象时取它的 "error",没有再取 "message";都不是非空字符串时为空。
func jsonErrorMessage(s string) string {
	if !strings.HasPrefix(s, "{") {
		return ""
	}
	var obj map[string]json.RawMessage
	if json.Unmarshal([]byte(s), &obj) != nil {
		return ""
	}
	for _, k := range []string{"error", "message"} {
		var v string
		if raw, ok := obj[k]; ok && json.Unmarshal(raw, &v) == nil && strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}
