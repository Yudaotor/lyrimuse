package main

import (
	"strings"
	"testing"
)

func TestLyricNoticeRulesCompile(t *testing.T) {
	if len(compiledLyricNotices) != len(lyricNoticeRules) {
		for _, r := range lyricNoticeRules {
			expr := r.pattern
			if r.ignoreCase {
				expr = "(?i)" + expr
			}
			if len(compileLyricNotices([]lyricNoticeRule{r})) == 0 {
				t.Errorf("规则 %s 在 RE2 下编不过: %s", r.id, expr)
			}
		}
	}
}

// 跟 App 的 selftest 跑同一批例句(shared/lyric-notices.json):drop 必须被那一条命中,keep 任何一条都不许命中;
// translation 那一面的 drop 还要过 isTranslationNotice 这个真实入口。
func TestLyricNoticeExamples(t *testing.T) {
	byID := map[string]compiledLyricNotice{}
	for _, n := range compiledLyricNotices {
		byID[n.id] = n
	}
	for _, ex := range lyricNoticeExamples {
		text := strings.TrimSpace(ex.text)
		if ex.drop {
			n, ok := byID[ex.rule]
			if !ok {
				t.Errorf("例句指向不存在的规则 %s", ex.rule)
				continue
			}
			if !n.re.MatchString(text) {
				t.Errorf("%s 应当命中 %q", ex.rule, ex.text)
			}
			if n.translation && !isTranslationNotice(ex.text) {
				t.Errorf("isTranslationNotice(%q) 应当为 true(规则 %s)", ex.text, ex.rule)
			}
			continue
		}
		for _, n := range compiledLyricNotices {
			if n.re.MatchString(text) {
				t.Errorf("%q 是真歌词,却被 %s 命中(例句挂在 %s 下)", ex.text, n.id, ex.rule)
			}
		}
	}
}
