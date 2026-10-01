package main

import (
	"fmt"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
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
// 必须与 Swift 侧 LyricDuet.soloMarkers / groupMarkers 逐字一致。
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
	for _, r := range " \t\u3000，,。.！!？?；;（()）[]【】「」、…—-\"'“”‘’" {
		m[r] = true
	}
	return m
}()

const lyricMaxLabelRunes = 10

// lyricSplitLabel 剥出行首的「标签 + 冒号」。只认形状,不判断它是不是演唱者。
// 第二个返回值是冒号后的正文(已 trim),第三个表示这一行到底有没有标签。
func lyricSplitLabel(text string) (label, rest string, ok bool) {
	rs := []rune(strings.TrimLeft(text, " \t\u3000"))
	// 标签与冒号之间允许有空白(`男 : 第一句` 跟 `男：第一句` 是同一种东西),但标签**内部**
	// 不允许 —— 一旦空白后面又来了别的字,这行就是带冒号的歌词句子而不是标签。
	// 别把空白整个当成 lyricLabelBreakers 里的普通中断字符:那样 `男 : …` 会在空格处
	// 直接判成"不是标签",于是署名行过滤那边的演唱者豁免拿不到标签、把对唱行当职员表剔掉。
	sawSpace := false
	for i, r := range rs {
		if r == '：' || r == ':' {
			if i == 0 {
				return "", "", false
			}
			return strings.TrimRight(string(rs[:i]), " \t\u3000"), strings.TrimSpace(string(rs[i+1:])), true
		}
		if r == ' ' || r == '\t' || r == '\u3000' {
			sawSpace = true
			continue
		}
		if sawSpace || lyricLabelBreakers[r] || i >= lyricMaxLabelRunes {
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
// 非补不可的理由:串烧 Live 里署名行会重复出现,《夜曲+窃爱 (Live)》
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

// lyricKeywordCreditRe 跟 Swift 侧 LyricsSyncEngine.creditLinePattern 逐字同一条:可选的语种前缀 + 角色词
// (可以用和/与/及/、/&连起来好几个)+ 可选 by + 冒号。改一边必须改另一边。
var lyricKeywordCreditRe = regexp.MustCompile(`(?i)^(所有|全部|中文|英文|韩文|日文|粤语|中|英|韩|日)?\s*` +
	`(唱片公司|发行公司|出品公司|专辑|翻译|作词|作曲|编曲|制作人|制作|监制|混音|录音|和声|吉他|贝斯|鼓|键盘|弦乐|乐器|编程|词|曲|编|唱|录|混|监|OP|SP|P\s*-\s*Line|C\s*-\s*Line|℗|©|lyrics|music|composed|produced|arranged|mixed|mastered|written)` +
	`(\s*(和|与|及|、|/|&|＆)?\s*(唱片公司|发行公司|出品公司|专辑|翻译|作词|作曲|编曲|制作人|制作|监制|混音|录音|和声|吉他|贝斯|鼓|键盘|弦乐|乐器|编程|词|曲|编|唱|录|混|监|OP|SP|lyrics|music|composed|produced|arranged|mixed|mastered|written))*` +
	`\s*(by\s*)?[:：]`)

// lyricCreditRoleWords 跟 Swift 侧 LyricsSyncEngine.creditRoleWords 同一张表(双字角色词),改一边必须改另一边。
// 标签**含**其中一个词就是职员表的角色名:「版权方」「总策划」「人声编辑」「封面设计」这种「角色词 + 一两个
// 尾字」够不着上面那条精确正则。
var lyricCreditRoleWords = []string{
	"作词", "作曲", "编曲", "编辑", "编程", "制作", "监制", "混音", "母带", "处理",
	"录音", "录制", "和声", "吉他", "贝斯", "键盘", "弦乐", "乐器", "工程", "企划",
	"统筹", "发行", "出品", "演奏", "指挥", "后期", "音效", "版权", "鸣谢", "摄影",
	"设计", "封面",
	"演唱", "原唱", "翻唱",
	"収録", "主題", "片頭", "片尾", "挿入",
	"收录", "主题", "片头", "插入",
	"歌手", "歌曲", "歌词",
	"钢琴", "箱琴", "笛子", "童声", "口琴", "二胡", "琵琶", "古筝", "长笛", "提琴",
	"唢呐", "手鼓", "打击", "合成", "采样", "编写", "小号", "萨克",
	"竖琴", "长号", "副唱", "和音", "三和",
	"著作", "推广",
	"合声", "人声", "剪辑", "厂牌", "感谢", "造型", "灯光", "宣发", "营销", "渠道", "说唱",
	"指导", "总监", "策划", "导演",
}

// lyricCreditLabelSeparators 同 Swift 侧 creditLabelSeparators:身兼两职的标签里夹着的分隔符。
const lyricCreditLabelSeparators = "/／、&＆·・和与及,，"

// lyricEnglishRoleNounRe 同 Swift 侧 englishRoleNounPattern:双语标签拉丁尾里的角色名。
var lyricEnglishRoleNounRe = regexp.MustCompile(`(?i)\b(producers?|composers?|lyricists?|lyrics|arrang(?:er|ement|ed)|` +
	`engineers?|engineering|studios?|drums?|bass|guitars?|keyboards?|strings|` +
	`vocals?|chorus|programming|mixing|mixed|mastering|mastered|recording|recorded|` +
	`assistant|producti?on|publisher|label|orchestra|conductor|percussion|piano|` +
	`synth(?:esizer)?|sax(?:ophone)?|trumpet|violin|cello|harmonica|` +
	`photograph(?:y|er)|artwork|design(?:er)?|mv|director)\b`)

// lyricLabelLooksLikeCreditRole 是 Swift 侧 LyricsSyncEngine.labelLooksLikeCreditRole 的移植:只看标签,判它像不像
// 职员表里的角色名。步骤同那边的 matchesRoleWordCredit:拆「汉字头 + 拉丁尾」的双语标签 → 去掉分隔符取汉字核心
// (标签混着型号、括号这类标注时只取汉字部分)→ 核心 1~10 个汉字 → 繁简两种写法里含角色词,或者拉丁尾本身是角色名。
func lyricLabelLooksLikeCreditRole(label string) bool {
	hanLabel, latinLabel := lyricSplitBilingualLabel(label)
	core := strings.Map(func(r rune) rune {
		if strings.ContainsRune(lyricCreditLabelSeparators, r) {
			return -1
		}
		return r
	}, hanLabel)
	if core == "" || !lyricAllHan(core) {
		var hanOnly strings.Builder
		nonHanOK := true
		for _, r := range label {
			switch {
			case unicode.Is(unicode.Han, r):
				hanOnly.WriteRune(r)
			case unicode.IsLetter(r) || unicode.IsDigit(r) || strings.ContainsRune(" ./&()'’-：:", r):
			default:
				nonHanOK = false
			}
		}
		if nonHanOK && hanOnly.Len() > 0 {
			core = hanOnly.String()
		}
	}
	if n := utf8.RuneCountInString(core); n < 1 || n > 10 || !lyricAllHan(core) {
		return false
	}
	for _, form := range []string{core, toSimplified(core)} {
		for _, w := range lyricCreditRoleWords {
			if strings.Contains(form, w) {
				return true
			}
		}
	}
	return latinLabel != "" && lyricEnglishRoleNounRe.MatchString(latinLabel)
}

// lyricSplitBilingualLabel 同 Swift 侧 splitBilingualLabel:拆不出干净的「汉字头 + 拉丁尾」时原样返回、拉丁尾为空。
// 标签里有括号、尾巴不以字母开头、尾巴里有数字 / 汉字 / 别的符号、尾巴超过 40 个字符时都算拆不出。
func lyricSplitBilingualLabel(label string) (han, latin string) {
	i := 0
	for i < len(label) {
		r, size := utf8.DecodeRuneInString(label[i:])
		if !unicode.Is(unicode.Han, r) && !strings.ContainsRune(lyricCreditLabelSeparators, r) {
			break
		}
		i += size
	}
	han = label[:i]
	tail := strings.TrimSpace(label[i:])
	if han == "" || tail == "" || utf8.RuneCountInString(tail) > 40 {
		return label, ""
	}
	if strings.ContainsAny(label, "()（）[]【】{}〔〕") {
		return label, ""
	}
	if first, _ := utf8.DecodeRuneInString(tail); !unicode.IsLetter(first) {
		return label, ""
	}
	for _, r := range tail {
		if unicode.Is(unicode.Han, r) || !(unicode.IsLetter(r) || unicode.IsSpace(r) || strings.ContainsRune("&/.,'()-＆", r)) {
			return label, ""
		}
	}
	return han, tail
}

func lyricAllHan(s string) bool {
	for _, r := range s {
		if !unicode.Is(unicode.Han, r) {
			return false
		}
	}
	return s != ""
}

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
	//
	// 用的是跟 Swift 那边同一条关键词正则(lyricKeywordCreditRe,对应 LyricsSyncEngine.creditLinePattern),
	// 不是打分用的 creditLineRe(那条窄得多,只认作词/作曲/编曲/制作人/演唱/混音/录音):两边对「哪些
	// 标签是说话人」必须一致,不然 App 删掉的署名行在这边被当成说话人豁免,曲末时间和正文共识都被带偏。
	if lyricKeywordCreditRe.MatchString(label+"：") || lyricLabelLooksLikeCreditRole(label) {
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
			// 这里**不能**用 isCreditLine 兜一道:它的 genericHanCreditLineRe 是
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
// 不能只 strings.Split(s, "\n"):酷狗那一支歌词是 CRLF,行尾会残留 \r,让
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
