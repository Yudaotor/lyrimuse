package main

import "unicode"

// searchQueryFields 把歌手 / 歌名 / 专辑转成发给各歌词源的查询词:繁体转简体(国内几家的曲库与搜索索引是简体,
// 拿繁体标签去搜整个查不到)。三栏里任何一栏带假名就当日文歌,三栏都原样送出:日文汉字不是繁体中文,
// 「夢」转成「梦」之后,按原文精确匹配的源(LRCLIB 的 /api/get、Deezer 的搜索)整个落空,国内几家存的也是
// 日文原文。判据按整首歌而不是逐栏:歌名是纯汉字的日文歌(歌手带假名)歌名也不能转。见 09 章决策 124。
//
// 只管发请求用的查询词;缓存 key、候选比对(normLoose 里的 toSimplified)不走这里。
func searchQueryFields(artist, title, album string) (string, string, string) {
	if containsKana(artist) || containsKana(title) || containsKana(album) {
		return composeNFC(artist), composeNFC(title), composeNFC(album)
	}
	return toSimplified(artist), toSimplified(title), toSimplified(album)
}

// containsKana:有没有平假名或片假名。按 Unicode 文字系统认,中文人名里常见的间隔号「・」(U+30FB)和长音符
// 「ー」(U+30FC)属于通用字符,不算。
func containsKana(s string) bool {
	for _, r := range s {
		if unicode.In(r, unicode.Hiragana, unicode.Katakana) {
			return true
		}
	}
	return false
}
