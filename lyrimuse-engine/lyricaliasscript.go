package main

import "unicode"

// lyricAliasScripts:歌词源按署名检索时认得的文字系统。各源的曲库只按拉丁字母与中日韩文字索引署名,
// 一位歌手在 MusicBrainz 上登记的希腊文、西里尔文、亚美尼亚文、天城文……音译拿去查,一个源也查不到;
// 大牌歌手这类音译能有几十个,别名轮逐个试一遍就是几十轮检索。见 09 章决策 102。
var lyricAliasScripts = []*unicode.RangeTable{unicode.Latin, unicode.Han, unicode.Hiragana, unicode.Katakana, unicode.Hangul}

// lyricAliasMissingMaxTries:只为补缺席的源跑的别名轮最多试几个别名。首轮已经有可用候选,这几轮只是给
// 没露面的源再换个名字问一次;缺着的源多半是曲库里本来就没有这首,别名再多也补不上,逐个试完就是
// 几十轮检索。日志里别名轮真正补上缺席源的,绝大多数用的是前两三个别名。救急轮(一个可用候选都没有)
// 与补罗马音那一轮不受这个上限约束。见 09 章决策 102。
const lyricAliasMissingMaxTries = 6

// lyricAliasScriptUsable:alias 的每个字母都属于 lyricAliasScripts,或者属于原署名 original 自己用到的文字
// (原署名是西里尔文的歌手,西里尔文的别名照样有用)。数字、标点、空格、附加符号,以及不属于任何一种文字的
// 通用字符(片假名长音符「ー」在 Unicode 里归 Common)不看。
func lyricAliasScriptUsable(alias, original string) bool {
	for _, r := range alias {
		if !unicode.IsLetter(r) || runeInScripts(r, lyricAliasScripts) ||
			unicode.Is(unicode.Common, r) || unicode.Is(unicode.Inherited, r) {
			continue
		}
		if !originalUsesScriptOf(original, r) {
			return false
		}
	}
	return true
}

// orderMBAliasesForRetry 给 MusicBrainz 的别名候选定序、取舍:
//   - 第一个一律收、排最前:主名跟本地署名不同时它就排第一(mbAliasCandidatesForRetry),原名是西里尔文、
//     本地标的是拉丁转写的歌手,要靠它换回原名;
//   - 其余只收 lyricAliasScriptUsable 的;
//   - 跟原署名用的文字不同的(周杰伦 → Jay Chou、Taylor Swift → テイラー・スウィフト)排在同文字的前面。
//     同文字的多半是原名的变体拼法(Taylur Swift、Teýlor Swift),各源的模糊检索早就覆盖了;
//     别名轮真正补上缺席源的,大多是换了一种文字的名字。补缺席源那几轮有次数上限
//     (lyricAliasMissingMaxTries),排在后面就轮不到。
func orderMBAliasesForRetry(aliases []string, original string) []string {
	if len(aliases) == 0 {
		return nil
	}
	own := letterScripts(original)
	out := []string{aliases[0]}
	var same []string
	for _, a := range aliases[1:] {
		if !lyricAliasScriptUsable(a, original) {
			continue
		}
		if sameScriptSet(letterScripts(a), own) {
			same = append(same, a)
		} else {
			out = append(out, a)
		}
	}
	return append(out, same...)
}

// letterScripts:s 里字母用到的文字系统(不含 Common / Inherited)。
func letterScripts(s string) map[string]bool {
	out := map[string]bool{}
	for _, r := range s {
		if !unicode.IsLetter(r) || unicode.Is(unicode.Common, r) || unicode.Is(unicode.Inherited, r) {
			continue
		}
		for name, t := range unicode.Scripts {
			if unicode.Is(t, r) {
				out[name] = true
				break
			}
		}
	}
	return out
}

func sameScriptSet(a, b map[string]bool) bool {
	if len(a) != len(b) {
		return false
	}
	for k := range a {
		if !b[k] {
			return false
		}
	}
	return true
}

func runeInScripts(r rune, tables []*unicode.RangeTable) bool {
	for _, t := range tables {
		if unicode.Is(t, r) {
			return true
		}
	}
	return false
}

// originalUsesScriptOf:original 里有没有跟 r 同一种文字的字母。
func originalUsesScriptOf(original string, r rune) bool {
	for name, t := range unicode.Scripts {
		if name == "Common" || name == "Inherited" || !unicode.Is(t, r) {
			continue
		}
		for _, o := range original {
			if unicode.Is(t, o) {
				return true
			}
		}
		return false
	}
	return false
}
