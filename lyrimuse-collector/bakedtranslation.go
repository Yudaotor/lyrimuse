package main

import (
	"regexp"
	"strconv"
	"strings"
	"unicode"
)

// 烘进正文的逐行译文(2026-09-04)。
//
// 起因:用户报 PRINCE《Diamonds and Pearls (2023 Remaster)》匹配错了,追下去发现 QQ 那条正确候选
// 的**正文**长这样(上传者用「krc转qrc工具」把中文译文直接烘进了歌词):
//
//	[00:36.08]This will be the day
//	[00:38.34]这将是我们约定的日子
//	[00:39.00]That you will hear me say
//	[00:41.30]你会听见我郑重承诺
//
// 每句英文后面紧跟一行**独立时间戳**的中文译文,QRC 逐字轨里同样有这些行(每个汉字 66ms 的假计时)。
// 后果有三层:①共识——正文里一半是中文,跟 lrclib/musixmatch 的纯英文正文 3-gram 相似度只有 0.41,
// 拿不到 150~250 的共识分,而冠亚军分差中位只有 22 分;②行数——118 行里 59 行是译文,+1/行 的行数分
// 虚高;③显示——App 把它当歌词逐行播,用户看到英中交替,悬浮窗逐字填色也会在中文行上跑一遍假计时。
// collector 明明有 lyrics_tr 这条专门放译文的轨,这份数据只是放错了地方。
//
// 做法:候选装配前(rankLyricSourceResults)把这种形态识别出来,中文行从正文与逐字轨里摘掉、改挂到
// 原文行的时间戳上放进 lyrics_tr(App 侧译文按 700ms 最近邻贴行,所以译文行必须复用原文行的时间戳,
// 不能留上传者那个偏 2 秒的戳)。
//
// 判据刻意保守——误伤的代价是把一首**真的**中英双语歌的中文歌词降级成译文:
//   - 这首歌得是外文歌:本地标签(歌手+歌名)不含汉字,或者原文行里过半带假名/谚文(日韩歌常用汉字
//     标歌名,不能靠标签判);
//   - 外文行(F)与纯汉字行(H)各 ≥ 8 行,H/F 在 0.7~1.3 之间(逐句对译才会一比一);
//   - ≥ 80% 的 H 行紧跟在一个 F 行后面(逐句交替)。
//
// 2026-09-04 拿用户 3481 条缓存里的**冠军**正文扫过:F、H 各 ≥8 行的有 351 条,其中"紧跟比例"最高的
// 是 0.67(茜拉班级《日出》,真的中英混唱),没有一条 ≥0.8——真双语歌的中文行跟英文行是段落级
// 交错,不是逐句一比一。阈值 0.8 与实测最高值之间有 0.13 的余量。
//
// 只处理"外文原文 + 中文译文"这一种方向:中文平台的上传者烘进去的几乎只有中文;反过来(中文歌烘英文译文)
// 没见过实例,不猜。

// yrcWordTimingRe 匹配 YRC 行里每个词前面的 (起始,时长[,0]) 计时段。
var yrcWordTimingRe = regexp.MustCompile(`\(\d+,\d+(?:,\d+)?\)`)

const (
	bakedTranslationMinLines   = 8
	bakedTranslationMinRatio   = 0.7
	bakedTranslationMaxRatio   = 1.3
	bakedTranslationMinPaired  = 0.8
	bakedTranslationYRCSlackMs = 80
)

type bakedLineClass int

const (
	bakedLineSkip    bakedLineClass = iota // 空行 / 元数据标签 / 署名 / 无时间戳
	bakedLineForeign                       // 外文原文行:含假名/谚文,或 ≥2 个拉丁字母且不含汉字
	bakedLineHan                           // 纯汉字行:≥2 个汉字,不含拉丁字母/假名/谚文
	bakedLineMixed                         // 其它(中英混杂、纯数字/标点等)
)

type bakedLine struct {
	raw     string
	stamps  string // 行首全部时间戳原文,如 "[00:36.08]"
	text    string
	class   bakedLineClass
	startMs int  // 第一个时间戳,毫秒;-1 = 无
	jk      bool // 外文行里含假名/谚文
}

func classifyBakedLine(line string) bakedLine {
	bl := bakedLine{raw: line, startMs: -1}
	m := lrcTimestampCaptureRe.FindAllStringSubmatchIndex(line, -1)
	if len(m) == 0 {
		bl.class = bakedLineSkip
		return bl
	}
	// 只认行首连续的时间戳;正文中间夹的方括号不当时间戳看。
	end := 0
	for _, mm := range m {
		if strings.TrimSpace(line[end:mm[0]]) != "" {
			break
		}
		end = mm[1]
	}
	if end == 0 {
		bl.class = bakedLineSkip
		return bl
	}
	bl.stamps = line[:end]
	bl.text = strings.TrimSpace(line[end:])
	if first := lrcTimestampCaptureRe.FindStringSubmatch(bl.stamps); first != nil {
		mm, _ := strconv.Atoi(first[1])
		ss, _ := strconv.Atoi(first[2])
		frac, _ := strconv.Atoi(first[3])
		switch len(first[3]) {
		case 1:
			frac *= 100
		case 2:
			frac *= 10
		}
		bl.startMs = mm*60000 + ss*1000 + frac
	}
	if bl.text == "" || isLRCMetaTagLine(bl.text) || isCreditLine(bl.text) {
		bl.class = bakedLineSkip
		return bl
	}
	han, latin, jk := 0, 0, 0
	for _, r := range bl.text {
		switch {
		case unicode.Is(unicode.Han, r):
			han++
		case r < 0x80 && unicode.IsLetter(r):
			latin++
		case unicode.Is(unicode.Hiragana, r), unicode.Is(unicode.Katakana, r), unicode.Is(unicode.Hangul, r):
			jk++
		}
	}
	switch {
	case jk > 0:
		bl.class, bl.jk = bakedLineForeign, true
	case latin >= 2 && han == 0:
		bl.class = bakedLineForeign
	case han >= 2 && latin == 0:
		bl.class = bakedLineHan
	default:
		bl.class = bakedLineMixed
	}
	return bl
}

// splitBakedTranslation 识别"外文原文 + 逐行中文译文烘在一起"的正文。命中时返回摘掉译文的正文、
// 挂回原文行时间戳的译文 LRC、摘掉对应行的逐字轨,以及摘掉的译文行数;不命中时原样返回、n=0。
// foreignSong:本地标签(歌手+歌名)不含汉字。
func splitBakedTranslation(lyrics, yrc string, foreignSong bool) (cleanLRC, trLRC, cleanYRC string, n int) {
	if lyrics == "" {
		return lyrics, "", yrc, 0
	}
	lines := splitLyricLines(lyrics)
	parsed := make([]bakedLine, len(lines))
	foreign, han, jkForeign, paired := 0, 0, 0, 0
	prevClass := bakedLineSkip
	for i, l := range lines {
		parsed[i] = classifyBakedLine(l)
		c := parsed[i].class
		switch c {
		case bakedLineForeign:
			foreign++
			if parsed[i].jk {
				jkForeign++
			}
		case bakedLineHan:
			han++
			if prevClass == bakedLineForeign {
				paired++
			}
		}
		if c != bakedLineSkip {
			prevClass = c
		}
	}
	if foreign < bakedTranslationMinLines || han < bakedTranslationMinLines {
		return lyrics, "", yrc, 0
	}
	ratio := float64(han) / float64(foreign)
	if ratio < bakedTranslationMinRatio || ratio > bakedTranslationMaxRatio {
		return lyrics, "", yrc, 0
	}
	if float64(paired) < bakedTranslationMinPaired*float64(han) {
		return lyrics, "", yrc, 0
	}
	if !foreignSong && 2*jkForeign < foreign {
		return lyrics, "", yrc, 0
	}

	// 摘译文:每个 H 行挂到它前面最近那个 F 行的时间戳上;同一 F 行下连续多行译文合成一行。
	var clean, tr []string
	removedMs := map[int]bool{}
	removedText := map[string]bool{}
	lastStamps := ""
	trText := map[string]string{} // stamps -> 译文
	var trOrder []string
	for _, bl := range parsed {
		switch bl.class {
		case bakedLineHan:
			n++
			if bl.startMs >= 0 {
				removedMs[bl.startMs] = true
			}
			removedText[normLoose(bl.text)] = true
			stamps := lastStamps
			if stamps == "" {
				stamps = bl.stamps
			}
			if prev, ok := trText[stamps]; ok {
				trText[stamps] = prev + " " + bl.text
			} else {
				trText[stamps] = bl.text
				trOrder = append(trOrder, stamps)
			}
			continue
		case bakedLineForeign:
			lastStamps = bl.stamps
		}
		clean = append(clean, bl.raw)
	}
	for _, stamps := range trOrder {
		tr = append(tr, stamps+trText[stamps])
	}
	cleanLRC = strings.Join(clean, "\n")
	trLRC = strings.Join(tr, "\n")
	cleanYRC = stripBakedYRCLines(yrc, removedMs, removedText)
	return cleanLRC, trLRC, cleanYRC, n
}

// stripBakedYRCLines 把逐字轨里对应被摘掉的译文行删掉:先按行起始毫秒对(±80ms),对不上再按
// 词文本拼接后的归一形态对。
func stripBakedYRCLines(yrc string, removedMs map[int]bool, removedText map[string]bool) string {
	if yrc == "" || (len(removedMs) == 0 && len(removedText) == 0) {
		return yrc
	}
	lines := strings.Split(yrc, "\n")
	kept := make([]string, 0, len(lines))
	for _, l := range lines {
		m := yrcLineTimeRegex.FindStringSubmatch(l)
		if m == nil {
			kept = append(kept, l)
			continue
		}
		start, _ := strconv.Atoi(m[1])
		drop := false
		for ms := range removedMs {
			if d := ms - start; d <= bakedTranslationYRCSlackMs && d >= -bakedTranslationYRCSlackMs {
				drop = true
				break
			}
		}
		if !drop {
			text := normLoose(yrcWordTimingRe.ReplaceAllString(l[len(m[0]):], ""))
			if text != "" && removedText[text] {
				drop = true
			}
		}
		if !drop {
			kept = append(kept, l)
		}
	}
	return strings.Join(kept, "\n")
}

// adoptBakedTranslation 是候选装配处的入口:命中就摘,译文轨为空时把摘出来的译文接上(语言固定中文,
// 所以只给译文轨本来就是中文语义的源用——netease/qq/kugou;musixmatch/amll 的译文语言跟设置走,
// 调用方传 acceptTr=false,只摘不接)。返回 (正文, 译文, 逐字轨, 摘掉的行数)。
func adoptBakedTranslation(lyr, tr, yrc string, foreignSong, acceptTr bool) (string, string, string, int) {
	clean, bakedTr, cleanYRC, n := splitBakedTranslation(lyr, yrc, foreignSong)
	if n == 0 {
		return lyr, tr, yrc, 0
	}
	if acceptTr && tr == "" {
		tr = bakedTr
	}
	return clean, tr, cleanYRC, n
}
