package main

import (
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

// pinyinTitleSyllables:曲名是一字一词写的普通话拼音时交回各个音节(小写、去声调),否则 nil。至少两个词、每个词都恰好是
// 一个音节才算:一个英文词也可能切得成几个拼音音节,日文罗马字的假名大多也是合法音节,它们都不是一字一词;连写成一个词
// 的拼音同样不算,判不了就不判。带数字的不算(数字跟汉字对不齐)。
func pinyinTitleSyllables(title string) []string {
	var out []string
	for _, w := range strings.FieldsFunc(foldDiacritics(strings.ToLower(pinyinTitleBase(title))), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	}) {
		if !mandarinSyllables[w] {
			return nil
		}
		out = append(out, w)
	}
	if len(out) < 2 {
		return nil
	}
	return out
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

// hanTitleReading:汉字的普通话读音,一个字一个音节(小写、去声调)。交给 lyrics-romanize 算,它要带时间戳的歌词行;helper 不在、
// 没算出来时为 nil。单测换成假的。
var hanTitleReading = func(han string) []string {
	reply, err := runLyricsRomanize(romanizeRequest{Lyrics: "[00:00.00]" + han})
	if err != nil || !reply.OK {
		return nil
	}
	return strings.Fields(foldDiacritics(strings.ToLower(lrcTimestampRe.ReplaceAllString(reply.Roma, ""))))
}

// pinyinTitleContradicts:歌手泛搜只凭时长挑出来的汉字曲名 found,读音跟一字一词的拼音曲名 title 明摆着对不上 —— 字数跟音节数
// 不同,或者首字母相同的音节不到一半(比首字母:zh/ch/sh 跟 z/c/s 算一个,非标准拼写常把 sh 写成 s;多音字读错一两个也不至于判错)。
// 本地专辑名里就有 found 时不算,理由同 titleSearchContradicts。title 不是这种拼音、found 不是纯汉字、读不出读音的都不算。
// 见 09 章决策 246。
func pinyinTitleContradicts(title, album, found string) bool {
	syllables := pinyinTitleSyllables(title)
	if syllables == nil {
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
