package main

import (
	"os"
	"strings"
	"testing"
)

// 决策存档 path 取值与 App 侧中文译名的**成对**守卫。
//
// 背景(2026-08-21 真实翻的车):加「重新自动匹配」时在 Go 这边新写了一条 path
// "manual-rematch",却忘了在 LyricsDecisionSheet.pathLabel 那个 switch 里补译名 ——
// 那边 default 分支是"原样显示 decision.path",于是「解析决策」弹窗上直接印了一个蓝色
// 英文胶囊 `manual-rematch` 给用户看,用户截图问「这里的文案是否没做好中文的」。
// 编译不报错、selftest 也不报错,只有肉眼能发现。
//
// 这个测试把两边钉在一起:Go 里新增一条 path(必须登记进 lyricsDecisionPaths),就必须
// 在那个 Swift switch 里出现同名 case,否则这里直接红。
func TestLyricsDecisionPathsHaveChineseLabels(t *testing.T) {
	const sheet = "../lyrimuse/Sources/lyrimuse/LyricsManager/LyricsDecisionSheet.swift"
	data, err := os.ReadFile(sheet)
	if err != nil {
		t.Fatalf("读不到 %s: %v(路径变了就跟着改,别把这个测试删掉)", sheet, err)
	}
	src := string(data)
	for _, path := range lyricsDecisionPaths() {
		needle := `case "` + path + `":`
		if !strings.Contains(src, needle) {
			t.Errorf("path %q 在 LyricsDecisionSheet.pathLabel 里没有中文译名(缺 %s)——"+
				"不补的话界面上会直接把这个英文串印给用户看", path, needle)
		}
	}
	// 反方向:Swift 那边写了译名、Go 这边却没有登记进 lyricsDecisionPaths,说明清单漏了。
	for _, line := range strings.Split(src, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, `case "`) {
			continue
		}
		rest := strings.TrimPrefix(line, `case "`)
		idx := strings.Index(rest, `"`)
		if idx <= 0 {
			continue
		}
		got := rest[:idx]
		found := false
		for _, path := range lyricsDecisionPaths() {
			if path == got {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("Swift 里有 case %q 的译名,但 lyricsDecisionPaths() 没登记它 —— 清单漏了", got)
		}
	}
}
