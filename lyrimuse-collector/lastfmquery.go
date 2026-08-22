package main

import (
	neturl "net/url"
	"sort"
	"strings"
)

// Last.fm 2.0 端点的 GET query 编码。
//
// 为什么不能直接 url.Values.Encode()(2026-08-22 实测坐实):**这个端点会对 query value
// 多解一次码**。它先做一遍标准 percent-decode,再对结果做一遍 form-urlencoded 解码 ——
// 后面那一遍把 `+` 当成空格。于是含加号的歌名/歌手名走标准编码必然查不到:
//
//	track=夜曲%2B窃爱 (Live)    → 两遍解完是「夜曲 窃爱 (Live)」→ error 6 Track not found
//	track=夜曲%252B窃爱 (Live)  → 两遍解完是「夜曲+窃爱 (Live)」→ 命中
//
// 端点级行为,不是某首歌的问题:拿真实存在的乐队 `+44`(733,475 听众)单测过 ——
// `artist=%2B44` 同样 error 6,`artist=%252B44` 才命中。
//
// ⚠️ 只有 GET query 这样。scrobble 走的是 POST form body(lastfm.go 的 form.Encode()),
// 只解一遍,**不能**套这里的规则 —— 套了会把字面 `%2B` 写进 Last.fm 的曲名。
// 「记得对、却查不到」这个不对称正是本坑的表征。
//
// Swift 侧同一份规则在 LyrimuseCore/Networking/LastfmQuery.swift,两边要一起改。
func lastfmGetQuery(q neturl.Values) string {
	keys := make([]string, 0, len(q))
	for k := range q {
		keys = append(keys, k)
	}
	// 跟 url.Values.Encode() 一样按 key 排序:同一组参数每次拼出同一个 URL,抓包/日志对得上。
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		for _, v := range q[k] {
			if b.Len() > 0 {
				b.WriteByte('&')
			}
			b.WriteString(lastfmEscape(k))
			b.WriteByte('=')
			b.WriteString(lastfmEscape(v))
		}
	}
	return b.String()
}

// lastfmEscape 给 `%` 和 `+` 各多编一层,其余走标准 percent-encoding。
//
// 两次 ReplaceAll 的顺序不能反:先换 `%` 再换 `+`,反过来的话第一步产出的 `%2B` 里那个
// `%` 会被第二步再啃一遍。QueryEscape 把空格编成 `+`,那个 `+` 会被端点的第二遍解码还原
// 成空格、结果其实是对的,但统一改成 `%20` —— 跟 Swift 侧逐字节一致,核对时不用两套心智。
func lastfmEscape(s string) string {
	doubled := strings.ReplaceAll(s, "%", "%25")
	doubled = strings.ReplaceAll(doubled, "+", "%2B")
	return strings.ReplaceAll(neturl.QueryEscape(doubled), "+", "%20")
}
