package main

import (
	"context"
	"strings"
	"unicode"
)

// searchQueryFields 把歌手 / 歌名 / 专辑转成发给各歌词源的查询词:繁体转简体(国内几家的曲库与搜索索引是简体,
// 拿繁体标签去搜整个查不到)。三栏里任何一栏带假名就当日文歌,三栏都原样送出:日文汉字不是繁体中文,
// 「夢」转成「梦」之后,按原文精确匹配的源(LRCLIB 的 /api/get、Deezer 的搜索)整个落空,国内几家存的也是
// 日文原文。判据按整首歌而不是逐栏:歌名是纯汉字的日文歌(歌手带假名)歌名也不能转。见 09 章决策 124。
// 两种写法都先把同形异码字换回标准字(foldHanLookalikes),歌名、专辑名去掉「 - 電影《Y》主題曲」这类宣传尾段
// (withoutPromoTitleTail):各源曲库存的是标准字、多数只登记歌名本身。见 09 章决策 189。撇号的几种误用写法换成「'」
// (foldQuoteLookalikes),见 09 章决策 191。
//
// 只管发请求用的查询词;缓存 key、候选比对(normLoose 里的 toSimplified)不走这里。
func searchQueryFields(artist, title, album string) (string, string, string) {
	artist, title, album = foldHanLookalikes(artist), foldHanLookalikes(title), foldHanLookalikes(album)
	artist, title, album = foldQuoteLookalikes(artist), foldQuoteLookalikes(title), foldQuoteLookalikes(album)
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

// quoteLookalikes:被当成撇号打进标签的几个字符 —— 角分号 U+2032、反角分号 U+2035、尖音符 U+00B4、反引号、修饰字母撇号 U+02BC。
var quoteLookalikes = strings.NewReplacer("\u2032", "'", "\u2035", "'", "\u00b4", "'", "`", "'", "\u02bc", "'")

// foldQuoteLookalikes 把 quoteLookalikes 换成「'」:按字面搜的源(Apple Music 等)拿「Can\u2032t」搜不到「Can't」。
func foldQuoteLookalikes(s string) string {
	return quoteLookalikes.Replace(s)
}

// lyricIdentityFields:按播放器原样标签记下的东西(播放时的平台曲目 ID、由它换来的 ISRC、本机客户端的歌词缓存、
// 缓存条目里存的 ID)拿哪组写法去查。这一轮问的就是归一化之前那组标签(手上三栏正好是它们经 searchQueryFields
// 改写的结果)时用原样那组;换了身份的轮次(别名、拆分、标题反查)或 ctx 上没记原样写法时用手上这组。
// 只管这类查找,发给歌词源的查询词照旧用手上这组。见 09 章决策 190。手上的歌名是交给各歌词源的带编号那一份
// (lyricSourceTitleFor)时先换回 key 里的歌名:这类查找按 key 里的歌名记。
func lyricIdentityFields(ctx context.Context, artist, title, album string) (string, string, string) {
	if t := normEnrichTitle(title); t != title && lyricSourceTitleFor(ctx, t) == title {
		title = t
	}
	oa, ot, oal, ok := searchQueryOriginalFrom(ctx)
	if !ok {
		return artist, title, album
	}
	if qa, qt, qal := searchQueryFields(oa, ot, oal); qa != artist || qt != title || qal != album {
		return artist, title, album
	}
	return oa, ot, oal
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
