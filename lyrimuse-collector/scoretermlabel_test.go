package main

import (
	"os"
	"strings"
	"testing"
)

// 打分项 kind 与 App 侧中文译名的**成对**守卫,跟 TestLyricsDecisionPathsHaveChineseLabels
// 是同一个路子、同一个教训 —— 而且这个教训 2026-08 已经翻过**两次**车:
//
//	① 2026-08-21 加决策 path "manual-rematch",忘了补 Swift 译名,弹窗直接印英文串给用户看,
//	   用户截图问「这里的文案是否没做好中文的」→ 于是有了 lyricsdecisionpath_test.go;
//	② 2026-08-22 加打分项 "sourceDurationOff",**照样又漏了一次** —— score_terms 这条当时
//	   没有任何守卫,而 LyricsSearchService.ScoreTerm.label 的 default 是 `return kind`,
//	   -400 这么大的扣分基本会排在解释文案第一行,用户第一眼看到的就是 `-400 sourceDurationOff`。
//
// 所以这一类也钉死:新增打分项 → 加进 lyricScoreTermKinds() → 必须在那个 Swift switch 里
// 有同名 case,否则这里直接红。编译不报错、selftest 也不报错,只有肉眼或这个测试能发现。
func TestLyricScoreTermKindsHaveChineseLabels(t *testing.T) {
	const svc = "../lyrimuse/Sources/lyrimuse/LyricsManager/LyricsSearchService.swift"
	data, err := os.ReadFile(svc)
	if err != nil {
		t.Fatalf("读不到 %s: %v(路径变了就跟着改,别把这个测试删掉)", svc, err)
	}
	src := string(data)
	for _, kind := range lyricScoreTermKinds() {
		needle := `case "` + kind + `":`
		// label 那个 switch 里 case 后面直接跟 return,写法是 `case "x": return ...`
		if !strings.Contains(src, needle) && !strings.Contains(src, `case "`+kind+`": return`) {
			t.Errorf("打分项 %q 在 LyricsSearchService.ScoreTerm.label 里没有中文译名——"+
				"不补的话「解析决策」/「搜索候选」弹窗会把这个英文串直接印给用户看", kind)
		}
	}
}
