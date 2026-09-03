package main

import "testing"

// 专辑路线"最优档并列"的放宽判据(2026-09-02,裘德《寻找一片青草地》案)。
//
// 病灶:原规则是"最优档位里出现两条同档就整条路线放弃"。实测撞到它判错性质的形态——
// QQ 把裘德《离开银色荒原》整张上架了两遍(GetAlbumSongList 回 20 条 = 同样 10 首各一条,
// 两个母带),于是这张专辑的**每一首**都并列两条、整张专辑的歌词全被挡在外面。而那两条
// 是同一首歌的两个版本(实测《火山灰》《变色龙》两条 mid 取回的歌词逐字节相同),不是
// "两个不同的东西分不清"。
//
// ⚠️ 这组用例的重点不是"并列能通过",而是**放宽没有放过头**:每一条正例都配了一条
// 只差一个维度的反例(改歌名 / 改歌手 / 拉开时长 / 抹掉时长),证明三道判据各自都在生效。
func TestQQAlbumTiedSongsAreSameTrack(t *testing.T) {
	cases := []struct {
		name string
		tied []qqAlbumSong
		want bool
	}{
		{
			// 现场抓的真实形态:《寻找一片青草地》在专辑里出现两次,都是 221 秒。
			"同一张专辑上架两遍,同名同歌手同时长",
			[]qqAlbumSong{
				{mid: "002ZZkxD2Niba1", name: "寻找一片青草地", singer: "裘德", interval: 221},
				{mid: "0023jZIS4Ml5xu", name: "寻找一片青草地", singer: "裘德", interval: 221},
			},
			true,
		},
		{
			// 同专辑《银色荒原》实测差 7 秒(母带首尾静音长度不同),仍算同一首。
			"时长差 7 秒仍算同一首",
			[]qqAlbumSong{
				{mid: "a", name: "银色荒原", singer: "裘德", interval: 240},
				{mid: "b", name: "银色荒原", singer: "裘德", interval: 247},
			},
			true,
		},
		{
			// 反例①:时长拉开 —— 这才是原规则真正要防的"同名不同版本"。
			"时长差 40 秒 → 真·不同版本,放弃",
			[]qqAlbumSong{
				{mid: "a", name: "龙拳", singer: "周杰伦", interval: 200},
				{mid: "b", name: "龙拳", singer: "周杰伦", interval: 240},
			},
			false,
		},
		{
			// 反例②:歌手不同 —— 合辑里的同名曲可能是别人唱的。
			"同名但歌手不同 → 放弃",
			[]qqAlbumSong{
				{mid: "a", name: "小情歌", singer: "苏打绿", interval: 250},
				{mid: "b", name: "小情歌", singer: "某翻唱", interval: 250},
			},
			false,
		},
		{
			// 反例③:归一化后并不同名(能走到并列是因为 lyricTitleAccepted 比精确同名宽)。
			"归一化后不同名 → 放弃",
			[]qqAlbumSong{
				{mid: "a", name: "寻找一片青草地", singer: "裘德", interval: 221},
				{mid: "b", name: "寻找一片青草地 (伴奏)", singer: "裘德", interval: 221},
			},
			false,
		},
		{
			// 反例④:没有时长就没有判据 —— 不能"缺失当通过"。
			"缺时长 → 核不了,放弃",
			[]qqAlbumSong{
				{mid: "a", name: "某曲", singer: "某人", interval: 0},
				{mid: "b", name: "某曲", singer: "某人", interval: 0},
			},
			false,
		},
		{
			// ⚠️ 只让**第一条**缺时长。原来只有"两条都缺"那一条用例,而循环里对 tied[1:]
			// 的检查会把它拦下 —— 于是 first.interval 那道守卫删掉也照样全绿(变异测试
			// 当场抓出这个盲点)。两条守卫要各自被覆盖。
			// 第二条故意取 8 秒:跨度 8≤10,**去掉守卫就会返回 true**。原来写 200 秒时
			// 跨度 200>10、时长闸自己就拦下了,守卫删掉照样全绿 —— 等于没测到。
			"只有第一条缺时长 → 同样核不了,放弃",
			[]qqAlbumSong{
				{mid: "a", name: "某曲", singer: "某人", interval: 0},
				{mid: "b", name: "某曲", singer: "某人", interval: 8},
			},
			false,
		},
		{
			"只有一条时也应成立(调用方对单条不走这个判据,但函数本身要自洽)",
			[]qqAlbumSong{{mid: "a", name: "某曲", singer: "某人", interval: 200}},
			true,
		},
		{"空切片", nil, false},
	}
	for _, c := range cases {
		if got := qqAlbumTiedSongsAreSameTrack(c.tied); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

// 用**真实抓下来的**《离开银色荒原》曲目单钉住整段挑选逻辑(2026-09-02)。
//
// 这张专辑在 QQ 上整个上架了两遍:GetAlbumSongList 回 20 条 = 同样 10 首各一条。改之前
// 「最优档并列就放弃」让这张专辑的每一首都挑不出来,整张专辑的歌词全军覆没。
//
// ⚠️ 测 pickQQAlbumTrack 而不是只测 qqAlbumTiedSongsAreSameTrack:后者是判据,前者才是
// 真正会回归的那段。变异测试实测——把调用点改回「并列一律放弃」,只测判据的用例全绿。
func TestPickQQAlbumTrackHandlesDoubleListedAlbum(t *testing.T) {
	// 2026-09-02 实测数据,mid/时长原样照抄。
	album := []qqAlbumSong{
		{mid: "003C6uoW3TRsod", name: "银色荒原", singer: "裘德", interval: 240},
		{mid: "0018yJhH3fxaJm", name: "火山灰", singer: "裘德", interval: 277},
		{mid: "000S5SKd2IYzXh", name: "春天的临终", singer: "裘德", interval: 282},
		{mid: "002XiEr80jaw70", name: "飞鸟在风暴中", singer: "裘德", interval: 327},
		{mid: "000KM2qt3lx50r", name: "奇卡奇卡", singer: "裘德", interval: 177},
		{mid: "0020GiE02VMADK", name: "变色龙", singer: "裘德/吴青峰", interval: 209},
		{mid: "001yUXxe2AfN2R", name: "没有羊的牧羊人", singer: "裘德", interval: 279},
		{mid: "000rNaTW106smh", name: "请求迷失在七月森林", singer: "裘德/孙盛希", interval: 292},
		{mid: "002ggjaX0xnbqi", name: "我们不要躲雨了", singer: "裘德", interval: 260},
		{mid: "002ZZkxD2Niba1", name: "寻找一片青草地", singer: "裘德", interval: 221},
		{mid: "002Kwihi0MJICc", name: "银色荒原", singer: "裘德", interval: 247},
		{mid: "0018cZzB0KEuTx", name: "火山灰", singer: "裘德", interval: 277},
		{mid: "002zM0Qx0z0H6h", name: "春天的临终", singer: "裘德", interval: 282},
		{mid: "004aw8Yz0CeoZb", name: "飞鸟在风暴中", singer: "裘德", interval: 328},
		{mid: "003sS2By1P8RgX", name: "奇卡奇卡", singer: "裘德", interval: 177},
		{mid: "002CHe7F1awrUu", name: "变色龙", singer: "裘德/吴青峰", interval: 211},
		{mid: "0016R7Zr4RrhTp", name: "没有羊的牧羊人", singer: "裘德", interval: 279},
		{mid: "001iIR2f4f6MjR", name: "请求迷失在七月森林", singer: "裘德", interval: 292},
		{mid: "002N66hL2lpaQs", name: "我们不要躲雨了", singer: "裘德", interval: 262},
		{mid: "0023jZIS4Ml5xu", name: "寻找一片青草地", singer: "裘德", interval: 221},
	}
	// 用户报的那首,以及同专辑另外两首(它们的两条 mid 实测都取得回逐字节相同的歌词)。
	for _, title := range []string{"寻找一片青草地", "火山灰", "变色龙", "银色荒原"} {
		got, ok := pickQQAlbumTrack(album, "裘德", title)
		if !ok {
			t.Errorf("%q: 整张专辑上架两遍不该让它挑不出来", title)
			continue
		}
		if got.name != title {
			t.Errorf("%q: 挑中的是 %q", title, got.name)
		}
	}

	// 反面锚点:同名但时长差得远 —— 这是原规则真正要防的形态,必须仍然放弃,
	// 否则等于把放宽做成了"并列一律取第一条"。
	twoLive := []qqAlbumSong{
		{mid: "a", name: "龙拳", singer: "周杰伦", interval: 200},
		{mid: "b", name: "龙拳", singer: "周杰伦", interval: 260},
	}
	if _, ok := pickQQAlbumTrack(twoLive, "周杰伦", "龙拳"); ok {
		t.Error("同名但时长差 60 秒(两场不同现场)不该被认成同一首")
	}

	// 档位仍然要生效:精确同名优先于"剥括号后相等",不能因为放宽就串到别的档。
	tiered := []qqAlbumSong{
		{mid: "strip", name: "某曲 (Live)", singer: "某人", interval: 200},
		{mid: "exact", name: "某曲", singer: "某人", interval: 200},
	}
	got, ok := pickQQAlbumTrack(tiered, "某人", "某曲")
	if !ok || got.mid != "exact" {
		t.Errorf("精确同名档应优先,得到 ok=%v mid=%q", ok, got.mid)
	}
}
