package main

import "testing"

// pickLyricCandidate 的回归测试 —— 2026-08-21 补,因为「歌词管理」新加的「重新自动匹配」
// 按钮开始依赖它了:那颗按钮的冠军**必须**由 Go 这边算(search-lyrics -pick),而不是让
// Swift 侧自己取最高分。
//
// 理由全在下面这两组用例里:
//
//	① 顺序优先模式取的是"用户配置顺序里第一个 Score>=0 的源",**根本不比分数** ——
//	   在 Swift 侧写 max(score) 的人不会知道这件事,而它的表现是"手动匹配完,下一拍自愈
//	   路径又按用户真正的配置给换回去",两边互相打架;
//	② Score<0 是"这个候选明确不可用"(没有时间戳/语言对不上/整份只有署名行)。五源全废时
//	   自动路径一个字都不写,而"取第一条"会把一份废歌词写进用户的缓存。
func TestPickLyricCandidateModes(t *testing.T) {
	saved := features
	defer func() { features = saved }()

	scored := []scoredLyricCandidateResult{
		{Source: "netease", Score: 300},
		{Source: "qq", Score: 900},
		{Source: "kugou", Score: 500},
	}
	enabled := map[string]bool{"netease": true, "qq": true, "kugou": true, "lrclib": true}

	// 智能:取最高分。
	features = featureFlags{LyricsSources: enabled, LyricsSourceMode: lyricsModeSmart}
	if got := pickLyricCandidate(scored); got == nil || got.Source != "qq" {
		t.Fatalf("智能模式该取最高分 qq(900),得到 %v", got)
	}

	// 顺序优先:按用户排的顺序取第一个能用的,不看分数(kugou 只有 500 分,但排在最前)。
	features = featureFlags{
		LyricsSources:     enabled,
		LyricsSourceMode:  lyricsModePriority,
		LyricsSourceOrder: []string{"kugou", "qq", "netease"},
	}
	if got := pickLyricCandidate(scored); got == nil || got.Source != "kugou" {
		t.Fatalf("顺序优先该取配置里第一个能用的 kugou,得到 %v", got)
	}

	// 顺序优先 + 排最前的那个源被判废:跳过它,继续往后找。
	withRejected := []scoredLyricCandidateResult{
		{Source: "kugou", Score: -1},
		{Source: "qq", Score: 900},
	}
	if got := pickLyricCandidate(withRejected); got == nil || got.Source != "qq" {
		t.Fatalf("顺序优先要跳过 Score<0 的候选,得到 %v", got)
	}

	// 关掉的源不许被选中(两种模式都要过这道过滤)。
	features = featureFlags{
		LyricsSources:    map[string]bool{"netease": true, "kugou": true},
		LyricsSourceMode: lyricsModeSmart,
	}
	if got := pickLyricCandidate(scored); got == nil || got.Source != "kugou" {
		t.Fatalf("关掉 qq 之后该取 kugou(500),得到 %v", got)
	}

	// 全被判废 → nil。调用方(CLI 的 -pick / 新按钮)必须按"一个能用的都没有"处理,
	// 绝不能退回"取第一条"。
	features = featureFlags{LyricsSources: enabled, LyricsSourceMode: lyricsModeSmart}
	allRejected := []scoredLyricCandidateResult{
		{Source: "qq", Score: -1},
		{Source: "kugou", Score: -1},
	}
	if got := pickLyricCandidate(allRejected); got != nil {
		t.Fatalf("全部判废时该返回 nil,得到 %v", got)
	}

	// 同分:先到的先赢(严格大于才换),两次调用结果必须一样 —— 不然同一首歌连点两次
	// 「重新自动匹配」会在两个源之间来回跳。
	tie := []scoredLyricCandidateResult{
		{Source: "netease", Score: 700},
		{Source: "qq", Score: 700},
	}
	first := pickLyricCandidate(tie)
	second := pickLyricCandidate(tie)
	if first == nil || second == nil || first.Source != second.Source || first.Source != "netease" {
		t.Fatalf("同分该稳定取先到的 netease,得到 %v / %v", first, second)
	}
}
