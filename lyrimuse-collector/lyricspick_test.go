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

// pickLyricCandidatePreferring 的回归测试 —— 2026-08-22 加,跟着「用户选定的歌词源」
// (enrichEntry.LyricsSourceChoice)一起上线。
//
// 这条机制存在的理由:在此之前「在联网搜索里采纳一条候选」走的是 markManual: true,而那个
// 标记是**所有**自动路径的一票否决闸 —— 于是"我只是想换个源"的代价是这首歌从此永久冻结,
// 以后打分规则改进、那个源后来开始给逐字时间轴,都再也不会被采纳。现在拆成两件事:
// manual_lyrics 仍然只表示"我改过正文",选源单独记，自愈照常跑但被约束在该源内。
//
// 这组用例钉的正是那个"约束"的边界 —— 尤其是最后两条:约束不成立时必须**不换**,
// 而不是悄悄退回全局最优(那等于推翻用户的选择,而"这一轮没应答"最常见的原因只是超时)。
func TestPickLyricCandidatePreferring(t *testing.T) {
	saved := features
	defer func() { features = saved }()

	scored := []scoredLyricCandidateResult{
		{Source: "netease", Score: 300},
		{Source: "qq", Score: 900},
		{Source: "kugou", Score: 500},
	}
	enabled := map[string]bool{"netease": true, "qq": true, "kugou": true, "lrclib": true}
	features = featureFlags{LyricsSources: enabled, LyricsSourceMode: lyricsModeSmart}

	// 没选过源 → 逐字等价于 pickLyricCandidate。
	if got := pickLyricCandidatePreferring(scored, ""); got == nil || got.Source != "qq" {
		t.Fatalf("空 choice 该退化成普通挑选(qq 900),得到 %v", got)
	}

	// 选定了 kugou → 即使 qq 分更高也取 kugou。这正是"别把我选的源换掉"。
	if got := pickLyricCandidatePreferring(scored, "kugou"); got == nil || got.Source != "kugou" {
		t.Fatalf("选定 kugou 时该取 kugou(500)而不是最高分,得到 %v", got)
	}

	// 同一个源内仍然按规则选最好的那条 —— "被约束在这个源内"不等于"冻结在这一份内容上",
	// 那个源后来给出更好的候选(有逐字/正文更全)照样能升上来,这是整条机制的收益所在。
	sameSource := []scoredLyricCandidateResult{
		{Source: "kugou", Score: 400},
		{Source: "kugou", Score: 800},
		{Source: "qq", Score: 999},
	}
	if got := pickLyricCandidatePreferring(sameSource, "kugou"); got == nil || got.Score != 800 {
		t.Fatalf("同源内该取最好的那条(800),得到 %v", got)
	}

	// 选定的源这一轮一条候选都没有 → 不换(nil),绝不退回全局最优。
	if got := pickLyricCandidatePreferring(scored, "musixmatch"); got != nil {
		t.Fatalf("选定的源没有候选时该返回 nil(不换),得到 %v", got)
	}

	// 选定的源这一轮只给出不可用候选(Score<0)→ 同样不换。
	rejected := []scoredLyricCandidateResult{
		{Source: "kugou", Score: -1},
		{Source: "qq", Score: 900},
	}
	if got := pickLyricCandidatePreferring(rejected, "kugou"); got != nil {
		t.Fatalf("选定的源只有不可用候选时该返回 nil,得到 %v", got)
	}

	// 用户后来在设置里禁用了那个源 → 落到"不换"。保守是对的:"我选了这个源"和"我不想再用
	// 这个源"是两个独立的意图,不该由这里替用户合并成"那就随便挑一个别的"。
	features = featureFlags{
		LyricsSources:    map[string]bool{"netease": true, "qq": true, "lrclib": true},
		LyricsSourceMode: lyricsModeSmart,
	}
	if got := pickLyricCandidatePreferring(scored, "kugou"); got != nil {
		t.Fatalf("选定的源被禁用时该返回 nil(不换),得到 %v", got)
	}
}
