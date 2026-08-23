package main

import (
	"fmt"
	"strings"
	"unicode"
)

// 演唱者标签的识别 —— 跟 Swift 侧 LyricDuet.speakers(in:) **同一套口径**,改一边必须改
// 另一边(两处口径都写在这里和 LyricDuet.swift 的注释里,别只改一处)。
//
// 为什么 collector 也需要认它:这边的 isCreditLine 是"短汉字标签 + 冒号"的结构判定,
// 「男：」「女：」「周杰伦：」全部命中,而它被用在两个**决定命运**的地方:
//
//   1. lyricConsensusBody —— 跨源共识比对时把命中行**整行**丢掉(连冒号后的真歌词一起)。
//      《好好说再见》53 行里 40 行是「男：/女：」,丢完只剩 13 行去跟别的源比 3-gram,
//      相似度自然上不去,拿不到共识分。共识分是 250(≥2 源互证)/150(1 源),而冠亚军
//      分差中位只有 22 分 —— 等于在选源那一步**系统性偏好没有对唱标注的那一版**。
//   2. isCreditOnlyLRC —— "非署名行 < 3 行"就整份判废。一首每句都带行内前缀的对唱歌
//      理论上会被整份拒收(当前全库 0 命中,但库里都是幸存者,判废的根本不会落盘)。
//
// Swift 侧 LyricsSyncEngine 早就给同一条正则加了说话人豁免,Go 侧一直没有 —— 这条不
// 一致就是"很多歌没有对唱"里唯一由我们自己造成的那部分。

// 明确的声部词。本身没有别的意思,单独出现就算数,不用过下面那道整份闸。
// ⚠️ 必须与 Swift 侧 LyricDuet.soloMarkers / groupMarkers 逐字一致。
var lyricSoloMarkers = []string{
	"男声", "女声", "男合", "女合", "男", "女", "Male", "Female", "M", "F",
}
var lyricGroupMarkers = []string{
	"合唱", "齐唱", "伴唱", "男女", "合", "众", "齐",
	"白", "旁白", "念", "说", "对白", "口白",
	"Both", "All", "Duet", "Chorus", "Together",
}

// 匿名声部标记 —— 给结构化歌词源(TTML 的 ttm:agent="v1")用,见 Swift 侧 anonymousMarkers。
var lyricAnonymousMarkers = func() []string {
	var out []string
	for i := 1; i <= 8; i++ {
		out = append(out, fmt.Sprintf("v%d", i), fmt.Sprintf("V%d", i))
	}
	return out
}()

var lyricKnownSpeakerSet = func() map[string]bool {
	m := map[string]bool{}
	for _, group := range [][]string{lyricSoloMarkers, lyricGroupMarkers, lyricAnonymousMarkers} {
		for _, s := range group {
			m[s] = true
		}
	}
	return m
}()

// 冒号左边不允许出现的字符 —— "标签"和"带冒号的歌词句子"之间唯一的形状差别。
var lyricLabelBreakers = func() map[rune]bool {
	m := map[rune]bool{}
	for _, r := range " \t　，,。.！!？?；;（()）[]【】「」、…—-\"'“”‘’" {
		m[r] = true
	}
	return m
}()

const lyricMaxLabelRunes = 10

// lyricSplitLabel 剥出行首的「标签 + 冒号」。只认形状,不判断它是不是演唱者。
// 第二个返回值是冒号后的正文(已 trim),第三个表示这一行到底有没有标签。
func lyricSplitLabel(text string) (label, rest string, ok bool) {
	rs := []rune(strings.TrimLeft(text, " \t　"))
	for i, r := range rs {
		if r == '：' || r == ':' {
			if i == 0 {
				return "", "", false
			}
			return string(rs[:i]), strings.TrimSpace(string(rs[i+1:])), true
		}
		if lyricLabelBreakers[r] || i >= lyricMaxLabelRunes {
			return "", "", false
		}
	}
	return "", "", false
}

// 人名标签里绝不会出现的字:代词、虚词、动词、语气词。挡住「我说：」「然后她问我：」
// 这类叙事句 —— 它们重复次数够,光靠计数拦不住。
const lyricNonNameRunes = "我你他她它们的了着过吗呢吧啊呀哦嗯不没很就都也还又再和跟与及说问答讲道是有在会要能可想觉得看听之乎者然后最先但而且或如果因为所以这那些"

// 乐器/职能词根。逐行的署名过滤漏网的那些在这里第二次被挡下来。
var lyricInstrumentRoots = []string{
	"琴", "鼓", "号", "笛", "箫", "筝", "胡", "铃", "钹", "提琴", "吉他", "贝斯",
	"弦乐", "打击", "合成", "口琴", "竖琴", "单簧", "双簧", "萨克斯", "定音", "电子",
	"乐器", "乐团", "乐队", "编曲", "录音", "混音", "制作", "母带", "工程", "监制",
	"演出", "数字", "执行", "统筹", "企划", "发行", "出品", "作词", "作曲",
	"scratch", "beatbox", "mellotron", "sample", "programming",
}

// 整个标签正好是这些词之一才算署名 —— 只能等值比,不能包含比:「曲」是姓(曲婉婷)。
// 非补不可的理由(2026-08-23 实测):串烧 Live 里署名行会重复出现,《夜曲+窃爱 (Live)》
// 「词」x2「曲」x2、《大笨钟+暗号+彩虹+龙卷风 (Live)》各 x4,整份判据拦不住。
// 与 Swift 侧 LyricDuet.exactCreditLabels 同一份表,改一边必须改另一边。
var lyricExactCreditLabels = func() map[string]bool {
	m := map[string]bool{}
	for _, s := range []string{
		"词", "詞", "曲", "编", "編", "唱", "录", "錄", "混", "监", "監", "译", "譯",
		"词曲", "詞曲", "原唱", "演唱", "歌手", "出品", "发行", "發行", "策划", "策劃",
		"翻唱", "原曲", "歌名", "歌曲", "专辑", "專輯", "标题", "標題", "歌词", "歌詞",
		"op", "sp", "vocal", "lyrics", "music", "composer", "arranger", "producer",
	} {
		m[s] = true
	}
	return m
}()

func lyricPlausibleSpeakerName(label string) bool {
	rs := []rune(label)
	if len(rs) == 0 || len(rs) > lyricMaxLabelRunes {
		return false
	}
	if lyricExactCreditLabels[label] || lyricExactCreditLabels[strings.ToLower(label)] {
		return false
	}
	// 复用 match.go 的角色词表(creditLineRe,和声/监制/母带/翻译…)否决 —— 注意只能用
	// **关键词那条**,不能用 isCreditLine:后者含 genericHanCreditLineRe 这条纯结构正则,
	// 「周杰伦：」自己就命中,加上去等于把所有中文人名标签全排掉。
	// 关键词那条天然放过真人名:「曲婉婷：」里「曲」是角色词,但正则要求它后面紧跟冒号或
	// 另一个角色词,「婉」两者都不是,整条匹配失败。
	if creditLineRe.MatchString(label + "：") {
		return false
	}
	if strings.ContainsAny(label, lyricNonNameRunes) {
		return false
	}
	hasWord := false
	for _, r := range rs {
		if unicode.IsLetter(r) {
			hasWord = true
			break
		}
	}
	if !hasWord {
		return false
	}
	lowered := strings.ToLower(label)
	for _, root := range lyricInstrumentRoots {
		if strings.Contains(lowered, root) {
			return false
		}
	}
	return true
}

// 未知标签要过的整份闸,数字与 Swift 侧一致:≥2 个不同标签、合计 ≥3 处、至少一个重复。
// 三条各挡一类:一个人不算对唱;两处的一次性标记(「Rap：」「Rap2：」)不算;每个都只出现
// 一次的多标签是职员表(「执行制作/录音师/混音师…」)。
const (
	lyricMinDistinctUnknownSpeakers = 2
	lyricMinUnknownSpeakerHits      = 3
	lyricMinUnknownSpeakerRepeat    = 2
)

// lyricSpeakerLabels 认出这一份 LRC 里的演唱者标签。传进来的是**原始 LRC 文本**。
func lyricSpeakerLabels(lyrics string) map[string]bool {
	speakers := map[string]bool{}
	unknown := map[string]int{}
	for _, line := range splitLyricLines(lyrics) {
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
		if text == "" {
			continue
		}
		label, _, ok := lyricSplitLabel(text)
		if !ok {
			continue
		}
		if lyricKnownSpeakerSet[label] {
			speakers[label] = true
		} else if lyricPlausibleSpeakerName(label) {
			// ⚠️ 这里**不能**用 isCreditLine 兜一道:它的 genericHanCreditLineRe 是
			// "1~8 个汉字 + 冒号"的纯结构判定,「周杰伦：」自己就命中,加上去等于把所有
			// 中文人名标签全排掉。署名的排除由 lyricPlausibleSpeakerName 那两张表负责。
			unknown[label]++
		}
	}
	if len(unknown) < lyricMinDistinctUnknownSpeakers {
		return speakers
	}
	total, maxHits := 0, 0
	for _, n := range unknown {
		total += n
		if n > maxHits {
			maxHits = n
		}
	}
	if total < lyricMinUnknownSpeakerHits || maxHits < lyricMinUnknownSpeakerRepeat {
		return speakers
	}
	for label := range unknown {
		speakers[label] = true
	}
	return speakers
}

// splitLyricLines 按 CRLF/CR/LF 三种换行切行。
//
// ⚠️ 不能只 strings.Split(s, "\n"):酷狗那一支歌词是 CRLF,行尾会残留 \r,让
// 「男：」变成「男：\r」这类尾部带控制符的串,后续 trim 之外的比较全部对不上。
// 这跟 Swift 侧那个"CRLF 被当成一个扩展字形簇"的坑同源。
func splitLyricLines(s string) []string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	s = strings.ReplaceAll(s, "\r", "\n")
	return strings.Split(s, "\n")
}

// isCreditLineForBody 是 isCreditLine 的"带这一份歌词上下文"的版本:演唱者标签行一律
// 不算署名 —— 它后面跟的是真歌词,或者它自己是独占标记行(那个由 Swift 侧 LyricDuet
// 负责丢掉,不该在这里被当署名整行摘掉、连累共识比对)。
func isCreditLineWithSpeakers(text string, speakers map[string]bool) bool {
	if len(speakers) > 0 {
		if label, _, ok := lyricSplitLabel(text); ok && speakers[label] {
			return false
		}
	}
	return isCreditLine(text)
}
