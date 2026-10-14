package main

import (
	"slices"
	"strings"
	"unicode"
)

// mandarinSyllables:普通话拼音的全部音节,不带声调;ü 写成 v、u 两种都收。
var mandarinSyllables = func() map[string]bool {
	m := map[string]bool{}
	for _, s := range strings.Fields(`
		a o e ai ei ao ou an en ang eng er
		ba bo bai bei bao ban ben bang beng bi bie biao bian bin bing bu
		pa po pai pei pao pou pan pen pang peng pi pie piao pian pin ping pu
		ma mo me mai mei mao mou man men mang meng mi mie miao miu mian min ming mu
		fa fo fei fou fan fen fang feng fu
		da de dai dei dao dou dan den dang deng dong di dia die diao diu dian ding du duo dui duan dun
		ta te tai tei tao tou tan tang teng tong ti tie tiao tian ting tu tuo tui tuan tun
		na ne nai nei nao nou nan nen nang neng nong ni nie niao niu nian nin niang ning nu nuo nuan nv nve nue
		la lo le lai lei lao lou lan lang leng long li lia lie liao liu lian lin liang ling lu luo luan lun lv lve lue
		ga ge gai gei gao gou gan gen gang geng gong gu gua guo guai gui guan gun guang
		ka ke kai kei kao kou kan ken kang keng kong ku kua kuo kuai kui kuan kun kuang
		ha he hai hei hao hou han hen hang heng hong hu hua huo huai hui huan hun huang
		ji jia jie jiao jiu jian jin jiang jing jiong ju jue juan jun
		qi qia qie qiao qiu qian qin qiang qing qiong qu que quan qun
		xi xia xie xiao xiu xian xin xiang xing xiong xu xue xuan xun
		zha zhe zhi zhai zhei zhao zhou zhan zhen zhang zheng zhong zhu zhua zhuo zhuai zhui zhuan zhun zhuang
		cha che chi chai chao chou chan chen chang cheng chong chu chua chuo chuai chui chuan chun chuang
		sha she shi shai shei shao shou shan shen shang sheng shu shua shuo shuai shui shuan shun shuang
		re ri rao rou ran ren rang reng rong ru rua ruo rui ruan run
		za ze zi zai zei zao zou zan zen zang zeng zong zu zuo zui zuan zun
		ca ce ci cai cao cou can cen cang ceng cong cu cuo cui cuan cun
		sa se si sai sao sou san sen sang seng song su suo sui suan sun
		ya yo ye yao you yan yang yi yin ying yong yu yue yuan yun
		wa wo wai wei wan wen wang weng wu`) {
		m[s] = true
	}
	return m
}()

// pinyinTitleBase:曲名去掉括号段、` - ` 之后的后缀(版本、现场这类)。
func pinyinTitleBase(s string) string {
	s = stripParens(cleanMediaTag(s))
	if i := strings.Index(s, " - "); i > 0 {
		s = s[:i]
	}
	return s
}

// pinyinMaxSegmentations / pinyinMaxReadings:一个词最多交回几种切法、一个曲名最多交回几种读法。按「词中间不以 a/o/e 开头」切,
// 实际几乎只有一种。
const (
	pinyinMaxSegmentations = 4
	pinyinMaxReadings      = 8
)

// pinyinSegmentations:一个词(小写、去声调)切成普通话音节的各种切法,切不出来是 nil。词中间的音节不以 a/o/e 开头:拼音里那个
// 位置要加隔音符号(xi'an),英文词就切不出 re-a-li-ze 这种形状。
func pinyinSegmentations(w string) [][]string {
	var out [][]string
	var walk func(rest string, acc []string)
	walk = func(rest string, acc []string) {
		if len(out) >= pinyinMaxSegmentations {
			return
		}
		if rest == "" {
			out = append(out, slices.Clone(acc))
			return
		}
		for n := min(len(rest), 6); n >= 1; n-- {
			s := rest[:n]
			if !mandarinSyllables[s] || (len(acc) > 0 && strings.IndexByte("aoe", s[0]) >= 0) {
				continue
			}
			walk(rest[n:], append(acc, s))
		}
	}
	walk(w, nil)
	return out
}

// pinyinTitleReadings:曲名按普通话拼音切成音节的几种读法(小写、去声调);有词切不出来、带数字(数字跟汉字对不齐)是 nil。
// spaced:至少两个词、每个词恰好是一个音节(一字一词)。别的形状 —— 连写成一个词的、整个曲名只有一个音节的 —— 英文词、日文
// 罗马字也常切得出来,要另有「是中文歌」的线索才拿来判(pinyinTitleContradicts)。
func pinyinTitleReadings(title string) (readings [][]string, spaced bool) {
	words := strings.FieldsFunc(foldDiacritics(strings.ToLower(pinyinTitleBase(title))), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	})
	if len(words) == 0 {
		return nil, false
	}
	spaced = len(words) >= 2
	for _, w := range words {
		if !mandarinSyllables[w] {
			spaced = false
		}
	}
	if spaced {
		return [][]string{words}, true
	}
	readings = [][]string{nil}
	for _, w := range words {
		segs := pinyinSegmentations(w)
		if len(segs) == 0 {
			return nil, false
		}
		var next [][]string
		for _, r := range readings {
			for _, sg := range segs {
				if len(next) < pinyinMaxReadings {
					next = append(next, append(slices.Clone(r), sg...))
				}
			}
		}
		readings = next
	}
	return readings, false
}

// pinyinTitleHan:曲名去掉括号段和后缀之后的汉字;带假名、谚文、拉丁字母或数字时为空(读音对不齐)。
func pinyinTitleHan(found string) string {
	var b strings.Builder
	for _, r := range pinyinTitleBase(found) {
		switch {
		case unicode.Is(unicode.Han, r):
			b.WriteRune(r)
		case unicode.IsLetter(r), unicode.IsDigit(r):
			return ""
		}
	}
	return b.String()
}

// hanTitleReading:汉字的普通话读音(romanizedHanReading)。单测换成假的。
var hanTitleReading = romanizedHanReading

// romanizedHanReading:汉字的普通话读音,一个字一个音节(小写、去声调)。交给 lyrics-romanize 算,它只认带时间戳的歌词行;
// helper 不在、没算出来时为 nil。
func romanizedHanReading(han string) []string {
	reply, err := runLyricsRomanize(romanizeRequest{Lyrics: "[00:00.00]" + han})
	if err != nil || !reply.OK {
		return nil
	}
	return strings.Fields(foldDiacritics(strings.ToLower(lrcTimestampRe.ReplaceAllString(reply.Roma, ""))))
}

// pinyinTitleContradicts:标题反查凭时长挑出来的汉字曲名 found,读音跟拼音曲名 title 明摆着对不上 —— title 的每种读法都对不上
// (pinyinReadingContradicts)。一字一词的拼音直接判;连写的、只有一个音节的要 chinese(这首是中文歌的线索,titleReverseSungInChinese)
// 才判。本地专辑名里就有 found 时不算,理由同 titleSearchContradicts。title 切不出拼音、found 不是纯汉字、读不出读音的都不算。
// 见 09 章决策 246;连写、单音节、专辑曲目表那一路见 09 章决策 253。
func pinyinTitleContradicts(title, album, found string, chinese bool) bool {
	readings, spaced := pinyinTitleReadings(title)
	if readings == nil || (!spaced && !chinese) {
		return false
	}
	han := pinyinTitleHan(found)
	if han == "" {
		return false
	}
	if na := normLoose(album); na != "" && strings.Contains(na, normLoose(han)) {
		return false
	}
	reading := hanTitleReading(han)
	if len(reading) == 0 || len(reading) != len([]rune(han)) {
		return false
	}
	return pinyinReadingsContradict(readings, reading)
}

// pinyinReadingsContradict:本地拼音的每种读法都跟汉字读音 reading 对不上(pinyinReadingContradicts);有一种对得上就不算。
func pinyinReadingsContradict(readings [][]string, reading []string) bool {
	for _, syllables := range readings {
		if !pinyinReadingContradicts(syllables, reading) {
			return false
		}
	}
	return len(readings) > 0
}

// pinyinReadingContradicts:本地拼音的一种读法 syllables 跟汉字读音 reading 对不上 —— 音节数不同,或者首字母相同的音节不到一半
// (比首字母:zh/ch/sh 跟 z/c/s 算一个,非标准拼写常把 sh 写成 s;多音字读错一两个也不至于判错)。
func pinyinReadingContradicts(syllables, reading []string) bool {
	if len(reading) != len(syllables) {
		return true
	}
	same := 0
	for i, s := range syllables {
		if reading[i][0] == s[0] {
			same++
		}
	}
	return same*2 < len(syllables)
}
