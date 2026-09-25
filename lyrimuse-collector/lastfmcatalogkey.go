package main

import (
	"regexp"
	"strings"
)

// 「这两个写法指的是不是同一份录音」——上送前在 Last.fm 编目里找对应条目时的比对键。
//
// # 为什么需要单独一层
//
// 播放器报的标签和 Last.fm 编目里的写法经常不是同一套字:实测陶喆《那个女孩》,播放器
// 报简体、编目里的正规条目是繁体《那個女孩》(889 听众、有编目时长),简体那侧只有一个
// 126 听众的影子条目。`track.getInfo` 的 autocorrect 对繁简不做映射(实测简体串纠不到
// 繁体条目),所以只能靠自己把两种写法折到同一个键上再比。
//
// 方向是**繁 → 简**(normLoose 里的 toSimplified),不是反向:简体只有「你」,转过去时无从
// 判断该写「你」还是「妳」。编目候选来自 Last.fm、可能是任意写法,折过来比就够了。
//
// # 与 enrichKey 那层的区别(别把两者混用)
//
// `normEnrichTitle` 的 `enrichKeyVersionWords` 把 `feat`/`featuring` 也算作「必须保留的
// 版本标记」——那是为了不让两首歌撞同一个缓存 key,方向跟这里**相反**。这里要的恰恰是
// 把 `那個女孩 (feat. 盧廣仲)` 和 `那個女孩` 折到一起(它们在编目里是同一首歌的两条,
// 654 / 889 听众),所以客串署名必须剥掉,而 Live/Remix 这类真版本标记必须留。

// lastfmCatalogTitleKey 把曲名折成「同一份录音的不同写法应当相等」的键。
// 空串进空串出——调用方据此跳过比对,不要让两个空键判成相等。
func lastfmCatalogTitleKey(title string) string {
	return normLoose(stripCatalogNoiseSubtitle(title))
}

// lastfmCatalogArtistKey 同上,用于歌手名。歌手侧不剥副题:`盧廣仲 (Crowd Lu)` 这种
// 括号里装的是同一个人的另一种写法,剥不剥都不影响比对,而剥括号会把
// `K/DA (feat. ...)` 这类本身带括号的组合名弄短。
func lastfmCatalogArtistKey(artist string) string {
	return normLoose(artist)
}

// 尾部括号(半角/全角/方括号/方头括号)。只看结尾:中段的括号更可能是名字本身的一部分。
var catalogSubtitleTrailingRe = regexp.MustCompile(`\s*[（(\[【]([^）)\]】]*)[）)\]】]\s*$`)

var (
	// 再版/发行标签:同一份录音在不同版本专辑、不同分级下的收录标记。
	// 地区/渠道限定词是白名单而不是 `\w+` —— `(Live Bonus Track)` 那种带版本信息的必须挡住。
	catalogNoiseRemasterRe = regexp.MustCompile(`^(\d{4}\s+)?remaster(ed)?(\s+\d{4})?(\s+version)?$`)
	catalogNoiseBonusRe    = regexp.MustCompile(`^((japan(ese)?|jp|us|uk|eu|international|digital|itunes|deluxe(\s+edition)?|cd|hidden)\s+)?bonus(\s+track)?(\s+version)?$`)
	catalogNoiseExplicitRe = regexp.MustCompile(`^explicit(\s+version)?$`)
)

// 客串署名前缀。 前缀后必须跟点或空格、且署名非空 —— 这道守卫挡的是
// `(Feathers)` / `(Without You)` / `(Within Temptation)` 这类只是巧合同头的词组。
var catalogCreditPrefixes = []string{"featuring", "feat", "ft", "with"}

// stripCatalogNoiseSubtitle 反复剥掉尾部括号里的「目录学噪音」副题:同一份录音在不同
// 曲库间的写法差异,不是真版本。
//
// 只认**完整**命中。`(Live)` / `(Remix)` / `(Acoustic)` 是真的另一份录音,照旧留着;
// 混着别的词的副题(`(Live 2014 Remaster)`)也不动 —— 宁可漏合,也不能把两份不同的
// 音频折成一首后把收听记到错的条目上(写进 Last.fm 的 scrobble 基本删不掉)。
//
// 口径与 App 侧 `PlayCountFold.isCatalogNoiseSubtitle` 同源,两侧一起改。刻意不收的
// (`(Clean)` / `(original version)` / `(single version)` / `(國)`/`(粵)`)见那边头注。
func stripCatalogNoiseSubtitle(title string) string {
	t := cleanMediaTag(title)
	for {
		m := catalogSubtitleTrailingRe.FindStringSubmatchIndex(t)
		if m == nil {
			return t
		}
		if !isCatalogNoiseSubtitle(t[m[2]:m[3]]) {
			return t
		}
		stripped := strings.TrimSpace(t[:m[0]])
		if stripped == "" {
			return t // 整个曲名就是一对括号,剥完什么都不剩:原样留着
		}
		t = stripped
	}
}

func isCatalogNoiseSubtitle(sub string) bool {
	s := strings.ToLower(strings.TrimSpace(cleanMediaTag(sub)))
	if s == "" {
		return false
	}
	if catalogNoiseRemasterRe.MatchString(s) || catalogNoiseBonusRe.MatchString(s) ||
		catalogNoiseExplicitRe.MatchString(s) {
		return true
	}
	for _, prefix := range catalogCreditPrefixes {
		rest, ok := strings.CutPrefix(s, prefix)
		if !ok {
			continue
		}
		if rest == "" {
			continue
		}
		if b := rest[0]; b != '.' && b != ' ' {
			continue
		}
		if strings.TrimSpace(rest[1:]) != "" {
			return true
		}
	}
	return false
}
