package main

import (
	"context"
	"unicode"
)

// searchQueryFields 把歌手 / 歌名 / 专辑转成发给各歌词源的查询词:繁体转简体(国内几家的曲库与搜索索引是简体,
// 拿繁体标签去搜整个查不到)。三栏里任何一栏带假名就当日文歌,三栏都原样送出:日文汉字不是繁体中文,
// 「夢」转成「梦」之后,按原文精确匹配的源(LRCLIB 的 /api/get、Deezer 的搜索)整个落空,国内几家存的也是
// 日文原文。判据按整首歌而不是逐栏:歌名是纯汉字的日文歌(歌手带假名)歌名也不能转。见 09 章决策 124。
// 两种写法都先把同形异码字换回标准字(foldHanLookalikes),歌名、专辑名去掉「 - 電影《Y》主題曲」这类宣传尾段
// (withoutPromoTitleTail):各源曲库存的是标准字、多数只登记歌名本身。见 09 章决策 189。
//
// 只管发请求用的查询词;缓存 key、候选比对(normLoose 里的 toSimplified)不走这里。
func searchQueryFields(artist, title, album string) (string, string, string) {
	artist, title, album = foldHanLookalikes(artist), foldHanLookalikes(title), foldHanLookalikes(album)
	title, album = withoutPromoTitleTail(title), withoutPromoTitleTail(album)
	if containsKana(artist) || containsKana(title) || containsKana(album) {
		return composeNFC(artist), composeNFC(title), composeNFC(album)
	}
	return toSimplified(artist), toSimplified(title), toSimplified(album)
}

type searchQueryOriginalKey struct{}

// withSearchQueryOriginal 记下 searchQueryFields 归一化之前的写法(NFC 组合后),给按原样收录的源多试一种写法(lrclib.go
// resolveLRCLIBLyricForms)。归一化没改动任何一栏时原样返回 ctx。调用方传的是归一化之前的三栏。
func withSearchQueryOriginal(ctx context.Context, artist, title, album string) context.Context {
	oa, ot, oal := composeNFC(artist), composeNFC(title), composeNFC(album)
	qa, qt, qal := searchQueryFields(artist, title, album)
	if oa == qa && ot == qt && oal == qal {
		return ctx
	}
	return context.WithValue(ctx, searchQueryOriginalKey{}, [3]string{oa, ot, oal})
}

// searchQueryOriginalFrom:withSearchQueryOriginal 记下的写法;没记(归一化没改动)时 ok 为 false。
func searchQueryOriginalFrom(ctx context.Context) (artist, title, album string, ok bool) {
	v, ok := ctx.Value(searchQueryOriginalKey{}).([3]string)
	return v[0], v[1], v[2], ok
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
