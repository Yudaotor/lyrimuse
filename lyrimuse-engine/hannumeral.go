package main

import (
	"strconv"
	"strings"
)

// 歌名里的汉字数字:同一首歌各家写法不一,「爱情三十六计」「爱情36计」,「二〇二六」「2026」。歌名闸只在两边都换成阿拉伯数字之后
// 整串相等时多认一档(lyricTitleAccepted),不放宽包含关系。见 09 章决策 280。

const hanNumeralRunes = "零〇一二两三四五六七八九十百千"

var hanDigitValues = map[rune]int{'零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9}

// foldHanNumerals 把 s 里每一段连续的汉字数字换成阿拉伯数字;换不了的段(hanNumeralValue)原样留着。
func foldHanNumerals(s string) string {
	if !strings.ContainsAny(s, hanNumeralRunes) {
		return s
	}
	var b, run strings.Builder
	flush := func() {
		if run.Len() == 0 {
			return
		}
		if v, ok := hanNumeralValue(run.String()); ok {
			b.WriteString(v)
		} else {
			b.WriteString(run.String())
		}
		run.Reset()
	}
	for _, r := range s {
		if strings.ContainsRune(hanNumeralRunes, r) {
			run.WriteRune(r)
			continue
		}
		flush()
		b.WriteRune(r)
	}
	flush()
	return b.String()
}

// hanNumeralValue:一段汉字数字的阿拉伯写法。带十 / 百 / 千的按位值算,算出来的数按标准写法写回去跟原文一样才认(「三十六」「一百零八」
// 「十二」;「十十」「三百六」这类不认);不带的逐位读(「二〇二六」→「2026」)。
func hanNumeralValue(run string) (string, bool) {
	if !strings.ContainsAny(run, "十百千") {
		var b strings.Builder
		for _, r := range run {
			d, ok := hanDigitValues[r]
			if !ok {
				return "", false
			}
			b.WriteString(strconv.Itoa(d))
		}
		return b.String(), true
	}
	total, cur := 0, -1
	for _, r := range run {
		unit := 0
		switch r {
		case '十':
			unit = 10
		case '百':
			unit = 100
		case '千':
			unit = 1000
		}
		if unit == 0 {
			d, ok := hanDigitValues[r]
			if !ok {
				return "", false
			}
			cur = d
			continue
		}
		if cur < 0 {
			cur = 1
		}
		total += cur * unit
		cur = -1
	}
	if cur > 0 {
		total += cur
	}
	if total <= 0 || total >= 10000 || !hanNumeralCanonical(run, total) {
		return "", false
	}
	return strconv.Itoa(total), true
}

// hanNumeralCanonical:n 按标准写法写出来(十位是一时可省「一」、百 / 千位的二可写「两」、中间缺位补一个「零」)跟 run 一样。
func hanNumeralCanonical(run string, n int) bool {
	digits := []rune("零一二三四五六七八九")
	var forms []string
	var build func(n int, leading bool) []string
	build = func(n int, leading bool) []string {
		if n == 0 {
			return []string{""}
		}
		for _, u := range []struct {
			v int
			c string
		}{{1000, "千"}, {100, "百"}, {10, "十"}} {
			if n < u.v {
				continue
			}
			d, rest := n/u.v, n%u.v
			heads := []string{string(digits[d]) + u.c}
			if d == 2 && u.v >= 100 {
				heads = append(heads, "两"+u.c)
			}
			if d == 1 && u.v == 10 && leading {
				heads = append(heads, "十")
			}
			var tails []string
			if rest > 0 && rest < u.v/10 {
				for _, t := range build(rest, false) {
					tails = append(tails, "零"+t)
				}
			} else {
				tails = build(rest, false)
			}
			var out []string
			for _, h := range heads {
				for _, t := range tails {
					out = append(out, h+t)
				}
			}
			return out
		}
		return []string{string(digits[n])}
	}
	forms = build(n, true)
	for _, f := range forms {
		if f == run {
			return true
		}
	}
	return false
}
