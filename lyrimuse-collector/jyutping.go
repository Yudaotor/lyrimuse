// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"bufio"
	"bytes"
	"embed"
	"strings"
	"unicode"
)

// dictionary/JyutpingChars.txt 是 rime-cantonese 项目
// (https://github.com/rime/rime-cantonese,CC-BY-4.0 许可,见 THIRD_PARTY_LICENSES)
// jyut6ping3.chars.dict.yaml 的单字级读音数据,经离线预处理压成"字\t读音"两列。原始
// 文件里同一个汉字常有多个候选读音(各自带一个可选的权重百分比,如"雅 aa1 3%"/
// "雅 ngaa5"),这里只取每个字的一个:优先取**没有权重标注**的那条(实测多个已知
// 多音字坐实这是主读音,如"雅→ngaa5"/"中→zung1"/"和→wo4"/"我→ngo5"/"唔→m4"/
// "係→hai6"/"嘅→ge3");都带权重时取权重最高的那条;再打平就按文件原始出现顺序取
// 第一条。单字层面这样简化没问题——真正影响读音的多音字消歧交给下面
// jyutpingWordMap 的词级匹配去做,单字表只兜底"词典完全没收这个词"的情况。
//
//go:embed dictionary/JyutpingChars.txt
var jyutpingDictFS embed.FS

// JyutpingChars.txt 主体是繁体字收字(粤语歌词的真实书写惯例本来就多是繁体),简体常用字
// 覆盖率很低(抽样 28 个简化字只命中 6 个,"爱/国/学/说/来/为/会/这"等高频字全部缺失)——
// 简体歌词逐字查不到读音会大片原样穿透、不转写。toJyutpingLine 直接查不到时,借 t2s.go
// 已经内嵌的 s2tCharMap(同一个 OpenCC 数据源,方向相反)转一次繁体再查一次,查到就用,
// 查不到才真的放弃——不为这一件事单独再嵌一份数据。
var jyutpingCharMap map[rune]string

// dictionary/JyutpingCollisionOverrides.txt 修一类跟上面单字表本身设计有关的坑,
// 2026-08-30 用户问"离"这个字为什么读错发现的:简体字里有 71 个字,本身**同时**是
// jyut6ping3.chars.dict.yaml 收录的另一个独立汉字(繁简共用同一个 Unicode 码位,
// 但那是两个不同的字,各有各的含义)。比如"离"——简体"离开"的"离"和文言里一个独立
// 的生僻字共用同一个码位,后者在词典里的读音是 ci1;"离"作为"離"的简体这层身份,
// 词典压根没有单独给它一条"当简体字用时怎么读"的记录。jyutpingReading 原来的查法是
// "先查这个字自己在字表里有没有,有就直接用"——查到的是那个生僻字的读音 ci1,查到就
// 直接返回,根本轮不到下面"转一次繁体再查"那条兜底,"離→lei4"这条正确读音永远用不上。
//
// 排查坐实这不是"离"一个字的偶发情况:系统性比对字表和 OpenCC 简→繁映射,发现有
// 71 个字都是这个模式(字表收了这个字自己的独立读音,而它作为另一个繁体字的简体时
// 该读的音跟字表给的不一样)。这份数据只收了当中证据最扎实的一部分——判据是"这个字
// 作为简体常用时该读的那个音,原始 yaml 里本来就是这个字自己候选列表中的一条(只是
// 带权重标注、被现有'优先取无权重那条'的规则排到了后面)",不是凭空猜的读音,是字表
// 自己已经承认过的候选,只是被规则排错了优先级。剩下的(如"几"作"茶几"的"几"跟
// "幾"的 gei2 谁更常见)缺这层独立证据,继续留给字表原有的优先级,不在这份覆盖表里
// 改——那些是真正没有客观依据能仲裁的多义字。
//
// ⚠️ 2026-08-30 同一天内自查自纠:最初收了 41 个,上线前拿公开粤拼资料反查用户真实
// 缓存里的歌词时,坐实"复/干/并"这 3 个选错了方向——这三个字不是"离"那种"只有一个
// 繁体身份、另一个是生僻字"的情况,是简体归并了**两个读音互不相同**的独立繁体字
// (复→復 fuk6/複 fuk1/覆 fuk1;干→幹 gon3/乾 gon1;并→並 bing6/併 ping3),没有
// 客观上更对的默认值。实测坐实的案例:林家谦《隔离》"回复掣 无情被废"(回复按钮,
// 覆/fuk1)被这条覆盖错改成"復"的 fuk6(恢复义)。判据可编程复核:同一简体字的
// 繁体候选,去掉指向自己的那个之后,剩下的候选如果读音不止一种,就不进这份覆盖表
// (jyutpingWordMap 覆盖不到的场景就老实退回字表默认值,好过强行选一个可能错的)。
// 最终定格 38 条。
//
//go:embed dictionary/JyutpingCollisionOverrides.txt
var jyutpingCollisionOverrideDictFS embed.FS

var jyutpingCollisionOverrideMap map[rune]string

// dictionary/JyutpingWords.txt 是同一个 rime-cantonese 项目
// jyut6ping3.words.dict.yaml(CC-BY-4.0,同上)的词级读音数据,同样离线预处理成
// "词\t读音"两列——跟 JyutpingChars.txt 一样,提取脚本本身没有入库,只入库处理好的
// 结果(这份数据基本不会跟着上游频繁更新,没必要为一次性提取常驻一个脚本)。
// 加这份词典就是为了修多音字问题:"重"这个字单字表只能给出一个固定读音,可"重要"该读
// zung6 jiu3、"重量"该读 cung5 loeng6,词义不同、读音也不同——纯单字查表两个都会拼成
// 同一个错的。toJyutpingLine 改成"先按最长的词匹配,匹配不到才退回单字"之后,这两个
// 词各自能查到自己收录的正确读音,不再共用单字表那一个读音。
//
// 原始文件没有权重标注,同一个词出现多次时全部是同词不同"变体读音"(比如口语里
// ng-声母脱落/保留的两种说法,如"吖嗱"同时收"aa1 laa4"和"aa1 naa4"),不是不同词义
// 分叉——跟上面单字表同一个道理,打平按文件原始出现顺序取第一条即可,不值得为这种
// 变体读音的优先级另外建一套规则。
//
//go:embed dictionary/JyutpingWords.txt
var jyutpingWordDictFS embed.FS

// jyutpingWordMap 只收长度 >= 2 个汉字的词条,跟 jyutpingCharMap 职责分开、互不重叠
// (单字永远走 jyutpingCharMap,查词只在 toJyutpingLine 里遇到 2 个字以上的窗口时才发生)。
var jyutpingWordMap map[string]string

// jyutpingMaxWordRunes 是 jyutpingWordMap 里最长词条的字数——toJyutpingLine 逐位置
// 贪心找词时用它限定最多往前看几个字,而不是拍脑袋定一个数字或者对每个位置试到行尾:
// 词典最长的词条是几十字的谚语,真按那个上限去试效率也够(逐行歌词最多几十字、一首歌
// 只转写一次、结果永久缓存),没必要额外设更小的上限自找麻烦。
var jyutpingMaxWordRunes int

func init() {
	jyutpingCharMap = loadJyutpingDict(jyutpingDictFS, "dictionary/JyutpingChars.txt")
	jyutpingCollisionOverrideMap = loadJyutpingDict(jyutpingCollisionOverrideDictFS, "dictionary/JyutpingCollisionOverrides.txt")
	jyutpingWordMap = loadJyutpingWordDict("dictionary/JyutpingWords.txt")
	for w := range jyutpingWordMap {
		if n := len([]rune(w)); n > jyutpingMaxWordRunes {
			jyutpingMaxWordRunes = n
		}
	}
}

// loadJyutpingDict 解析 "字\t读音" 格式的词典文件,fs 由调用方传入——这个格式被两份
// 不同的内嵌数据复用(JyutpingChars.txt 本身、JyutpingCollisionOverrides.txt 那份
// 派生表),各自嵌在自己的 embed.FS 里,不能共用同一个全局变量。词典文件本身是编译期
// 内嵌的常量数据,格式损坏(理论上不会发生,除非这个文件被手动改坏)时静默跳过那一行,
// 不 panic——跟 t2s.go 的 loadT2SDict 同一个防御姿势。
func loadJyutpingDict(fs embed.FS, path string) map[rune]string {
	m := map[rune]string{}
	data, err := fs.ReadFile(path)
	if err != nil {
		return m
	}
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "\t", 2)
		if len(parts) != 2 || parts[1] == "" {
			continue
		}
		r := []rune(parts[0])
		if len(r) != 1 {
			continue
		}
		m[r[0]] = parts[1]
	}
	return m
}

// loadJyutpingWordDict 跟 loadJyutpingDict 同一套解析逻辑,键允许多个汉字,但每个字符
// 都必须是汉字才收——原始 jyut6ping3.words.dict.yaml 除了真正的词,还混了一批带标点的
// 完整谚语(如"笑左，笑埋右"、"不自由，毋寧死",实测 103077 条 2 字以上词条里有 696 条
// 这样,含逗号顿号句号,甚至个别纯拉丁词条如"hee hee hur hur"也带空格)。toJyutpingLine
// 是按 rune 窗口整段吃掉命中的词、整段输出读音的,窗口里夹着的标点/空格不会单独产生
// 音节,一旦命中这类词条,标点就会被读音字符串"顶替"掉、从输出里凭空消失——这违反了
// 这个函数自己的契约"查不到读音的字符原样保留"(2026-08-30 review 坐实:
// `toJyutpingLine("笑左，笑埋右")` 曾经吐出 "siu3 zo2 siu3 maai4 jau6",逗号没了)。
// 词典文件本身已经在预处理阶段过滤掉了这类条目,这里的检查是独立防一手,不依赖那份
// 预处理的正确性——万一以后重新拉取上游数据时忘了过滤,这里能兜住,不会又把标点吃掉。
func loadJyutpingWordDict(path string) map[string]string {
	m := map[string]string{}
	data, err := jyutpingWordDictFS.ReadFile(path)
	if err != nil {
		return m
	}
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "\t", 2)
		if len(parts) != 2 || parts[1] == "" {
			continue
		}
		if len([]rune(parts[0])) < 2 {
			continue
		}
		if !isAllHan(parts[0]) {
			continue
		}
		m[parts[0]] = parts[1]
	}
	return m
}

// isAllHan 判断一个字符串是否全部由汉字组成——loadJyutpingWordDict 用它挡掉词典里混进
// 来的带标点/空格的完整谚语条目(见该函数注释)。
func isAllHan(s string) bool {
	for _, r := range s {
		if !unicode.Is(unicode.Han, r) {
			return false
		}
	}
	return true
}

// jyutpingReading 查一个字的粤拼读音:直接查不到时,借 s2tCharMap 转一次繁体再查一次
// (见 jyutpingCharMap 的注释)。两次都查不到返回 false。
func jyutpingReading(r rune) (string, bool) {
	// 见 jyutpingCollisionOverrideMap 的注释:这 38 个字自己在字表里就有独立的一条
	// (通常是某个生僻/罕见含义),必须先查这张表挡在前面,不然下面第一步会先命中那个
	// 无关的独立读音,永远轮不到"当简体字用时该读什么"这层。
	if jp, ok := jyutpingCollisionOverrideMap[r]; ok {
		return jp, true
	}
	if jp, ok := jyutpingCharMap[r]; ok {
		return jp, true
	}
	if trad, ok := s2tCharMap[string(r)]; ok {
		tr := []rune(trad)
		if len(tr) == 1 {
			if jp, ok := jyutpingCharMap[tr[0]]; ok {
				return jp, true
			}
		}
	}
	return "", false
}

// jyutpingWordReading 查一个词(2 个字以上)的粤拼读音,跟 jyutpingReading 同一套
// "查不到就转一次繁体再查"兜底,只是把单字的转换扩展成逐字转换再拼回词——
// JyutpingWords.txt 跟 JyutpingChars.txt 同源,主体同样是繁体收字。
func jyutpingWordReading(word string) (string, bool) {
	if jp, ok := jyutpingWordMap[word]; ok {
		return jp, true
	}
	runes := []rune(word)
	converted := make([]rune, len(runes))
	changed := false
	for i, r := range runes {
		if trad, ok := s2tCharMap[string(r)]; ok {
			tr := []rune(trad)
			if len(tr) == 1 {
				converted[i] = tr[0]
				if tr[0] != r {
					changed = true
				}
				continue
			}
		}
		converted[i] = r
	}
	if !changed {
		return "", false
	}
	jp, ok := jyutpingWordMap[string(converted)]
	return jp, ok
}

// toJyutpingLine 把一行文本转写成粤拼:优先按 jyutpingWordMap 做最长词匹配(见该
// 变量注释——这是修多音字的关键一步),当前位置往后数 jyutpingMaxWordRunes 个字开始
// 逐级缩短试,只要拼出的子串命中词典就整段吃掉、按词里的读音(词条本身就是空格分隔的
// 多音节字符串)整体输出;命中不了才退回单字 jyutpingReading。汉字之间(不管是按词
// 还是按单字转写出来的)、以及汉字与非汉字之间的音节用空格分隔;拉丁字母/数字保持原样
// 连写(不会把 "baby" 拆成 "b a b y");查不到读音的字符(词表/字表繁简都不在里面,或
// 本来就不是汉字)原样保留,不猜、不报错。
//
// 词表本身也不是万能的——遇到词表没收录的词,还是会退回单字、可能跟语境不符,跟单字表
// 那个"选一个主读音"的简化是同一类局限,只是覆盖面比纯单字查表宽得多。
func toJyutpingLine(text string) string {
	runes := []rune(text)
	var b strings.Builder
	// 分隔只发生在**读音**与相邻内容之间。原文里本来连写的东西(拉丁串内部、撇号跟
	// 它依附的词)一律保持原样,不插空格。
	//
	// lastRune 是已经写出去的最后一个字符(0 = 还没写过任何东西);lastWasSyllable 记
	// 最后写出去的那一段是不是查出来的读音。
	//
	// ⚠️ 2026-08-31 修:这里原来只用一个 needSpace,并在写出"查不到读音的字符"之后按
	// `needSpace = !(unicode.IsLetter(r) || unicode.IsDigit(r))` 决定下一段要不要空格。
	// 两处错:
	//  1. 它只看**当前**字符是不是字母/数字,没看下一个是什么 —— 意图是"连续拉丁串
	//     别被拆成 b a b y",实际把"拉丁→汉字"这个边界也判成不需要空格,输出成
	//     "babyngo5 oi3 nei5"、"OKlaa1"、"Do re midong1"(2026-08-31 用户截图坐实,
	//     真实缓存里就有《从何唱起》那行 "Do re midong1 zung1 …")。这直接违反本函数
	//     文档里写的"汉字与非汉字之间的音节用空格分隔"。
	//  2. unicode.IsLetter 对**汉字/假名/谚文同样返回 true** —— 一个查不到读音的汉字
	//     会被当成拉丁串的一部分,连带吞掉它后面那个音节前的空格。
	// 既有测试只覆盖了 "Baby 我爱你"(中间本来就有空格),恰好绕开了这两条。
	var lastRune rune
	lastWasSyllable := false
	// sep 在需要时补一个分隔空格:前面写过东西、且它不是空白(避免在原有空格旁再加一个)。
	sep := func() {
		if lastRune != 0 && !unicode.IsSpace(lastRune) {
			b.WriteByte(' ')
			lastRune = ' '
		}
	}
	emit := func(jp string) {
		if jp == "" {
			return
		}
		sep()
		b.WriteString(jp)
		jpRunes := []rune(jp)
		lastRune = jpRunes[len(jpRunes)-1]
		lastWasSyllable = true
	}
	for i := 0; i < len(runes); {
		matched := false
		maxLen := jyutpingMaxWordRunes
		if remaining := len(runes) - i; maxLen > remaining {
			maxLen = remaining
		}
		for l := maxLen; l >= 2; l-- {
			if jp, ok := jyutpingWordReading(string(runes[i : i+l])); ok {
				emit(jp)
				i += l
				matched = true
				break
			}
		}
		if matched {
			continue
		}
		r := runes[i]
		if jp, ok := jyutpingReading(r); ok {
			emit(jp)
			i++
			continue
		}
		if unicode.IsSpace(r) {
			b.WriteRune(r)
			lastRune = r
			lastWasSyllable = false
			i++
			continue
		}
		// 查不到读音的字符原样穿透。只有当它紧跟在一个读音后面时才需要分隔 —— 这样
		// 「ngo5 😀 nei5」「nei5 hou2 ， sai3 gaai3」照旧,而拉丁串内部、撇号跟词之间
		// (that’s)不会被凭空劈开。
		if lastWasSyllable {
			sep()
		}
		b.WriteRune(r)
		lastRune = r
		lastWasSyllable = false
		i++
	}
	return b.String()
}

// jyutpingLRC 把整份逐行 LRC 歌词转写成粤拼逐行 LRC,时间戳与原文逐行对齐——复用
// translate.go 的 parseLRCLines/assembleTranslationLRC,跟机器翻译走同一套"保留原
// 时间戳、转不出内容就整体放弃"逻辑,不是重新发明一套。
func jyutpingLRC(lyrics string) string {
	lines := parseLRCLines(lyrics)
	if len(lines) == 0 {
		return ""
	}
	texts := make([]string, len(lines))
	for i, l := range lines {
		texts[i] = toJyutpingLine(l.text)
	}
	return assembleTranslationLRC(lines, texts, len(lines)).lrc
}
