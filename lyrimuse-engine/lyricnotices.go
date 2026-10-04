package main

import (
	"regexp"
	"strings"
)

// 歌词源塞进歌词里的声明行(版权 / 授权 / 译文版权 / 来源说明)。规则本体在 shared/lyric-notices.json,
// 由 scripts/gen-lyric-notices.py 生成 lyricnotices_generated.go,App 那边读同一份
// (LyricNotices+Generated.swift)。改规则改那份 JSON,别在这里单独加。
//
// 引擎只用 translation 那一面(isTranslationNotice 清洗译文轨);body 那一面是 App 显示正文时用的,
// 这里也编译一遍,只为让两侧测试跑同一批例句。
type lyricNoticeRule struct {
	id          string
	pattern     string
	ignoreCase  bool
	translation bool
	body        bool
}

type compiledLyricNotice struct {
	lyricNoticeRule
	re *regexp.Regexp
}

// 编不过的规则跳过、不 panic:一条坏规则不该让引擎起不来。TestLyricNoticeRulesCompile 要求全部编得过。
var compiledLyricNotices = compileLyricNotices(lyricNoticeRules)

func compileLyricNotices(rules []lyricNoticeRule) []compiledLyricNotice {
	out := make([]compiledLyricNotice, 0, len(rules))
	for _, r := range rules {
		expr := r.pattern
		if r.ignoreCase {
			expr = "(?i)" + expr
		}
		re, err := regexp.Compile(expr)
		if err != nil {
			continue
		}
		out = append(out, compiledLyricNotice{lyricNoticeRule: r, re: re})
	}
	return out
}

// lyricNoticeMatches:这一行是不是 translation(true)/ body(false)那一面的声明。比较前去掉首尾空白,
// 有几条规则锚在整行上。
func lyricNoticeMatches(text string, translation bool) bool {
	t := strings.TrimSpace(text)
	for _, n := range compiledLyricNotices {
		if (translation && n.translation) || (!translation && n.body) {
			if n.re.MatchString(t) {
				return true
			}
		}
	}
	return false
}
