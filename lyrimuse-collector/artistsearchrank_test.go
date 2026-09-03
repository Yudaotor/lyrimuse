package main

import "testing"

// 「标题反查泛搜」那条兜底的两处判据缺陷,2026-09-02 修(用户报「打上花火」整屏显示的是
// 《春雷》的歌词)。
//
// 下面三组曲目表是**真查网易云量回来的**(2026-09-02,`/api/search/get?type=1&limit=30`),
// 不是编的:名次就是搜索结果里的名次,时长是接口给的毫秒 / 1000。三组分别对应
//   ① 这次的错例(打上花火 → 春雷),
//   ② 2026-08-30 修好、这次不能打死的正例(方大同 Love Love Love → 爱爱爱),
//   ③ 这条兜底当初存在的理由(陶喆 Airport in 10:30 → 飞机场的10:30)。
// 只保留每组前 30 名里跟判定有关的那几条 + 足够的填充,好让名次对得上。

// 查询:"米津玄师 Uchiagehanabi",本地时长 289.334s。
// 落在 2s 容差内的四条分别排第 12 / 24 / 25 / 30 名 —— 全在前 5 名之外。
func uchiagehanabiSearchResults() []albumTrack {
	tracks := []albumTrack{
		{title: "打上花火", artist: "米津玄師", duration: 259.459},      // 1(正确的歌,但版本不同、差 29.9s)
		{title: "Lemon", artist: "米津玄師", duration: 256.000},     // 2
		{title: "IRIS OUT", artist: "米津玄師", duration: 151.626},  // 3
		{title: "LOSER", artist: "米津玄師", duration: 243.879},     // 4
		{title: "KICK BACK", artist: "米津玄師", duration: 193.561}, // 5
		{title: "BOW AND ARROW", artist: "米津玄師", duration: 175.775},
		{title: "烏 - Raven", artist: "米津玄師", duration: 248.528},
		{title: "M八七", artist: "米津玄師", duration: 263.123},
		{title: "地球儀", artist: "米津玄師", duration: 273.437},
		{title: "さよーならまたいつか！", artist: "米津玄師", duration: 201.280},
		{title: "PLACEBO", artist: "米津玄師", duration: 218.000}, // 11
		{title: "春雷", artist: "米津玄師", duration: 288.949},      // 12 ← 纯时长判据的赢家,差 0.385s
	}
	for len(tracks) < 23 {
		tracks = append(tracks, albumTrack{
			title: "填充" + string(rune('A'+len(tracks))), artist: "米津玄師", duration: 200.0})
	}
	return append(tracks,
		albumTrack{title: "打上花火 (Cover)", artist: "米津玄師", duration: 288.376},      // 24,差 0.958s
		albumTrack{title: "打上花火 (Cover) [其他]", artist: "米津玄師", duration: 288.376}, // 25
		albumTrack{title: "填充X", artist: "米津玄師", duration: 200.0},
		albumTrack{title: "填充Y", artist: "米津玄師", duration: 200.0},
		albumTrack{title: "填充Z", artist: "米津玄師", duration: 200.0},
		albumTrack{title: "填充W", artist: "米津玄師", duration: 200.0},
		albumTrack{title: "Uchiage Hanabi", artist: "米津玄師", duration: 287.432}, // 30,差 1.902s
	)
}

// 查询:"方大同 Love Love Love",本地时长 213.000s。《爱爱爱》排第 2 名。
func loveLoveLoveSearchResults() []albumTrack {
	tracks := []albumTrack{
		{title: "特别的人", artist: "方大同", duration: 259.064}, // 1
		{title: "爱爱爱", artist: "方大同", duration: 213.266},  // 2 ← 正确答案,差 0.266s
		{title: "Love Song", artist: "方大同", duration: 269.293},
		{title: "天气先生", artist: "方大同", duration: 271.583},
		{title: "Love Song [Timeless Live]", artist: "方大同", duration: 270.133}, // 5
	}
	for len(tracks) < 12 {
		tracks = append(tracks, albumTrack{
			title: "填充" + string(rune('A'+len(tracks))), artist: "方大同", duration: 240.0})
	}
	// 13:同一首歌被合辑重复收录 —— 2026-08-30 那次专门保住的形态,不构成歧义。
	tracks = append(tracks, albumTrack{title: "爱爱爱", artist: "方大同", duration: 213.266})
	for len(tracks) < 18 {
		tracks = append(tracks, albumTrack{
			title: "填充b" + string(rune('A'+len(tracks))), artist: "方大同", duration: 240.0})
	}
	// 19:另一首歌,时长也在容差内(差 0.696s)。
	return append(tracks, albumTrack{title: "听", artist: "方大同", duration: 212.304})
}

func TestArtistSearchRankCutoffRejectsCatalogCollision(t *testing.T) {
	const localDuration = 289.334
	all := uchiagehanabiSearchResults()

	// 改动前的行为:整份 30 条都交给纯时长判据,矬出排第 12 名的《春雷》。
	// ⚠️ 这一条断言的是**旧行为仍然可复现**,它证明这个 bug 不是靠排歧义守卫能修的 ——
	// 亚军(打上花火 Cover,0.958s)比冠军(春雷,0.385s)差 0.573s,超过 0.5s 余量,
	// 守卫不会触发。真正修掉它的是下面的名次截断。
	if got, _, ok := bestAlbumTrackByDurationDetailed(all, localDuration); !ok || got != "春雷" {
		t.Fatalf("前置条件不成立:不截断时应当仍然选出《春雷》,实际 got=%q ok=%v", got, ok)
	}

	// 改动后:只有前 5 名够格,而前 5 名里一条都落不进 2s 容差 → 整体弃权。
	// 弃权是**正确**结果:上层还有 musixmatch 那条按本地标题搜到的正确候选兜着。
	if got, _, ok := bestAlbumTrackByDurationDetailed(
		topSearchRanked(all, retryTitleFromArtistSearchMaxRank), localDuration); ok {
		t.Fatalf("名次截断后应当弃权,实际选出了 %q", got)
	}
}

func TestArtistSearchRankCutoffKeepsKnownGoodCases(t *testing.T) {
	// ② 爱爱爱案:正确答案排第 2 名,截断后必须照样选得出来。
	got, diff, ok := bestAlbumTrackByDurationDetailed(
		topSearchRanked(loveLoveLoveSearchResults(), retryTitleFromArtistSearchMaxRank), 213.0)
	if !ok || got != "爱爱爱" {
		t.Fatalf("爱爱爱案被打死了:got=%q ok=%v", got, ok)
	}
	if diff > 0.3 {
		t.Fatalf("爱爱爱案的时长误差不该这么大:%v", diff)
	}

	// ③ 飞机场案:正确答案排第 1 名(这条兜底当初存在的理由)。
	airport := []albumTrack{
		{title: "飞机场的10:30", artist: "陶喆", duration: 280.773},
		{title: "飞机场的10:30 (Live)", artist: "陶喆", duration: 336.245},
	}
	if got, _, ok := bestAlbumTrackByDurationDetailed(
		topSearchRanked(airport, retryTitleFromArtistSearchMaxRank), 280.773); !ok || got != "飞机场的10:30" {
		t.Fatalf("飞机场案被打死了:got=%q ok=%v", got, ok)
	}
}

func TestTopSearchRanked(t *testing.T) {
	five := []albumTrack{{title: "a"}, {title: "b"}, {title: "c"}, {title: "d"}, {title: "e"}}
	if got := topSearchRanked(five, 3); len(got) != 3 || got[2].title != "c" {
		t.Fatalf("截断应当保序取前 3 条,实际 %v", got)
	}
	// 不足 n 条、n 非正、空表都原样返回,不能 panic。
	if got := topSearchRanked(five, 99); len(got) != 5 {
		t.Fatalf("不足 n 条应当全给,实际 %d 条", len(got))
	}
	if got := topSearchRanked(five, 0); len(got) != 5 {
		t.Fatalf("n<=0 应当原样返回,实际 %d 条", len(got))
	}
	if got := topSearchRanked(nil, 5); got != nil {
		t.Fatalf("空表应当原样返回,实际 %v", got)
	}
}

// 排歧义守卫:2026-09-02 之前写的是 `d == bestDiff`(浮点精确相等),两首不同的歌时长差要
// bit 级完全一样才会触发 —— 等于这道守卫从来没生效过。
func TestAmbiguityGuardUsesRealMargin(t *testing.T) {
	const local = 200.0

	// 两个**不同标题**、误差只差 0.3s(小于 0.5s 余量)→ 分不出是哪首,弃权。
	// 旧的精确相等判据在这里会直接把「甲」当答案交出去。
	close2 := []albumTrack{
		{title: "甲", artist: "X", duration: 200.1},
		{title: "乙", artist: "X", duration: 200.4},
	}
	if got, _, ok := bestAlbumTrackByDurationDetailed(close2, local); ok {
		t.Fatalf("两首异名歌相差 0.3s 时应当弃权,实际选出 %q", got)
	}

	// 顺序反过来同样要弃权 —— 冠军被换掉时旧冠军必须降级成亚军候选,
	// 否则先出现的那条会被静默忘掉、守卫退化成"只看最后一次打平"。
	if got, _, ok := bestAlbumTrackByDurationDetailed(
		[]albumTrack{close2[1], close2[0]}, local); ok {
		t.Fatalf("换个顺序也应当弃权,实际选出 %q", got)
	}

	// 差得够开(1.2s > 0.5s 余量)→ 不算歧义,冠军照常胜出。
	far := []albumTrack{
		{title: "甲", artist: "X", duration: 200.1},
		{title: "乙", artist: "X", duration: 201.3},
	}
	if got, _, ok := bestAlbumTrackByDurationDetailed(far, local); !ok || got != "甲" {
		t.Fatalf("差 1.2s 不该算歧义:got=%q ok=%v", got, ok)
	}

	// ⚠️ 2026-08-30 那条不变量:**同一个标题**被不同专辑/合辑重复收录不构成歧义。
	// 破了它,《爱爱爱》那个案例会重新回到"本该毫无疑问的正确答案被判成分不清"。
	dupes := []albumTrack{
		{title: "爱爱爱", artist: "方大同", duration: 213.266},
		{title: "爱爱爱", artist: "方大同", duration: 213.266},
	}
	if got, _, ok := bestAlbumTrackByDurationDetailed(dupes, 213.0); !ok || got != "爱爱爱" {
		t.Fatalf("同名重复收录不该算歧义:got=%q ok=%v", got, ok)
	}
}
