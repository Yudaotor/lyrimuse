package main

import (
	"reflect"
	"testing"
)

func TestNormEnrichTitle(t *testing.T) {
	cases := []struct {
		name, in, want string
	}{
		// 真正要修的那一类:中文歌名 + 括号里的英文译名。三条都是本机缓存里实际存在过的
		// 重复条目(2026-08-14),播放器报带译名的写法,网易云/专辑预取报不带的。
		{"全角括号译名", "不散的筵席（I Miss You）", "不散的筵席"},
		{"全角括号译名2", "神探（The Detective）", "神探"},
		{"半角括号译名", "小師妹 (Love Triangle)", "小師妹"},

		// 版本标记必须原样保留 —— 合并了就是把两个不同的录音当成同一首。
		{"remix 保留", "Song (Remix)", "Song (Remix)"},
		{"live 保留", "告白气球 (Live)", "告白气球 (Live)"},
		{"remaster 保留", "Bad (2012 Remaster)", "Bad (2012 Remaster)"},
		{"feat 保留", "爱我的人 (feat. MOE.)", "爱我的人 (feat. MOE.)"},
		{"instrumental 保留", "Song (Instrumental)", "Song (Instrumental)"},
		// interlude 这一条是真实数据逼出来的:《神經志 The Journal》里同时存在
		// `The Girl In Red (Interlude)` 和 `Interlude : The Girl In Red`,剥掉括号会得到
		// `The Girl In Red`,而那可能是另一首完整曲目。
		{"interlude 保留", "The Girl In Red (Interlude)", "The Girl In Red (Interlude)"},
		{"中文版本标记保留", "月亮代表我的心 (现场版)", "月亮代表我的心 (现场版)"},
		// 2026-08-31 真实bug(周杰伦《不能说的秘密》电影原声带):"慢板"版是电影原声带里
		// 单独收录的钢琴慢版重奏,时长只有 68 秒,跟正式完整版《Secret》是两个不同的录音,
		// 剥掉会跟正式版撞成同一个 key。
		{"慢板保留", "Secret (慢板)", "Secret (慢板)"},
		{"快板保留", "第二圆舞曲 (快板)", "第二圆舞曲 (快板)"},

		// 边界
		{"括号就是整个歌名", "(Interlude)", "(Interlude)"},
		{"括号就是整个歌名2", "（前奏）", "（前奏）"},
		{"两层括号连剥", "歌名（译名）[Explicit]", "歌名"},
		{"剥到版本标记停手", "歌名（译名）(Live)", "歌名（译名）(Live)"},
		{"中间的括号不动", "Song (A) tail", "Song (A) tail"},
		{"没有括号", "不散的筵席", "不散的筵席"},
		{"空串", "", ""},

		// 跟 media-control 入口同一套不可见空白清洗
		{"不换行空格", "Song\u00a0(I Miss You)", "Song"},
		{"零宽字符", "不散\u200b的筵席", "不散的筵席"},
		{"全角空格", "不散的筵席\u3000（I Miss You）", "不散的筵席"},
	}
	for _, c := range cases {
		if got := normEnrichTitle(c.in); got != c.want {
			t.Errorf("%s: normEnrichTitle(%q) = %q, want %q", c.name, c.in, got, c.want)
		}
	}
}

func TestEnrichKeyDoesNotFoldCaseOrScript(t *testing.T) {
	// 刻意不转小写、不折繁简:缓存条目里没有单独的 title/artist/album 字段,"歌词管理"
	// 显示的就是 key 拆出来的三段,折了就会看到 "神经志 the journal"。大小写另有
	// canonicalEnrichKey 在查询时兜底。
	got := enrichKey("PRINCE", "The Girl In Red (Interlude)", "神經志 The Journal")
	want := "PRINCE|The Girl In Red (Interlude)|神經志 The Journal"
	if got != want {
		t.Errorf("enrichKey = %q, want %q", got, want)
	}
}

func TestEnrichKeyIsIdempotent(t *testing.T) {
	// 迁移会反复跑(每次 collector 启动),归一化过的 key 再算一次必须还是它自己。
	for _, in := range []string{
		"丁世光|不散的筵席（I Miss You）|神經志 The Journal",
		"丁世光|The Girl In Red (Interlude)|神經志 The Journal",
		"Prince|Song (Remix)|3121",
	} {
		a, ti, al := splitEnrichKey(in)
		once := enrichKey(a, ti, al)
		a2, ti2, al2 := splitEnrichKey(once)
		if twice := enrichKey(a2, ti2, al2); twice != once {
			t.Errorf("not idempotent: %q -> %q -> %q", in, once, twice)
		}
	}
}

func TestPlanEnrichKeyMigrationGroups(t *testing.T) {
	cache := map[string]enrichEntry{
		"丁世光|不散的筵席|神經志 The Journal":                       {LyricsSource: "netease"},
		"丁世光|不散的筵席（I Miss You）|神經志 The Journal":           {LyricsSource: "kugou"},
		"丁世光|The Girl In Red (Interlude)|神經志 The Journal": {LyricsSource: "qq"},
	}
	got := planEnrichKeyMigration(cache)
	want := map[string][]string{
		"丁世光|不散的筵席|神經志 The Journal": {
			"丁世光|不散的筵席|神經志 The Journal",
			"丁世光|不散的筵席（I Miss You）|神經志 The Journal",
		},
		"丁世光|The Girl In Red (Interlude)|神經志 The Journal": {
			"丁世光|The Girl In Red (Interlude)|神經志 The Journal",
		},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("planEnrichKeyMigration = %#v, want %#v", got, want)
	}
}

func TestPlanEnrichKeyMigrationDurationGuard(t *testing.T) {
	// 两个译名括号(都不等于归一化后的 nk 本身)时长差太多,不该被合并 —— 模拟
	// "慢板/快板"那次真实bug的下一次翻版:关键词清单没漏词(两个都是译名,理应剥括号),
	// 但时长说明这其实是两个不同的录音。时长兼容的那条仍按原逻辑重命名到 nk,
	// 只有真正冲突的那条被排除、保留在自己原来的 key 下。
	t.Run("时长差太多不合并", func(t *testing.T) {
		cache := map[string]enrichEntry{
			"某人|神探（Sherlock）|专辑":       {LyricsSource: "kugou", LyricsScore: 1203, DurationSecs: 68},
			"某人|神探（The Detective）|专辑": {LyricsSource: "netease", LyricsScore: 1107, DurationSecs: 261},
		}
		got := planEnrichKeyMigration(cache)
		want := map[string][]string{
			"某人|神探|专辑":                {"某人|神探（Sherlock）|专辑"},
			"某人|神探（The Detective）|专辑": {"某人|神探（The Detective）|专辑"},
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("planEnrichKeyMigration = %#v, want %#v", got, want)
		}
	})

	// 时长接近(差在 12% 阈值以内)的正常按原逻辑合并 —— 守卫不能误伤真正的重复条目。
	t.Run("时长接近正常合并", func(t *testing.T) {
		cache := map[string]enrichEntry{
			"丁世光|不散的筵席|神經志 The Journal":           {LyricsSource: "netease", LyricsScore: 1107, DurationSecs: 258},
			"丁世光|不散的筵席（I Miss You）|神經志 The Journal": {LyricsSource: "kugou", LyricsScore: 1203, DurationSecs: 261},
		}
		got := planEnrichKeyMigration(cache)
		want := map[string][]string{
			"丁世光|不散的筵席|神經志 The Journal": {
				"丁世光|不散的筵席|神經志 The Journal",
				"丁世光|不散的筵席（I Miss You）|神經志 The Journal",
			},
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("planEnrichKeyMigration = %#v, want merged: %#v", got, want)
		}
	})

	// 旧条目没有时长数据(DurationSecs=0,历史条目/从没解析成功过)——未知时长不能拦合并,
	// 否则一次升级就把全库没时长字段的旧条目全部冻结在原地。
	t.Run("时长未知不拦合并", func(t *testing.T) {
		cache := map[string]enrichEntry{
			"丁世光|不散的筵席|神經志 The Journal":           {LyricsSource: "netease", LyricsScore: 1107, DurationSecs: 0},
			"丁世光|不散的筵席（I Miss You）|神經志 The Journal": {LyricsSource: "kugou", LyricsScore: 1203, DurationSecs: 261},
		}
		got := planEnrichKeyMigration(cache)
		if len(got) != 1 {
			t.Errorf("want 1 merged group when one side has unknown duration, got %#v", got)
		}
	})

	// nk 这个名字被两头都想要(其中一条 entry 恰好就存在归一化后的名字下,但时长又跟
	// 该组里分数更高的另一条冲突)——三方打架,宁可整组都不合并。
	t.Run("nk名字冲突时整组放弃合并", func(t *testing.T) {
		cache := map[string]enrichEntry{
			"丁世光|不散的筵席|神經志 The Journal":           {LyricsSource: "netease", LyricsScore: 1107, DurationSecs: 68},
			"丁世光|不散的筵席（I Miss You）|神經志 The Journal": {LyricsSource: "kugou", LyricsScore: 1203, DurationSecs: 261},
		}
		got := planEnrichKeyMigration(cache)
		want := map[string][]string{
			"丁世光|不散的筵席|神經志 The Journal":           {"丁世光|不散的筵席|神經志 The Journal"},
			"丁世光|不散的筵席（I Miss You）|神經志 The Journal": {"丁世光|不散的筵席（I Miss You）|神經志 The Journal"},
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("planEnrichKeyMigration = %#v, want both kept standalone: %#v", got, want)
		}
	})
}

func TestEnrichKeyDurationVariant(t *testing.T) {
	got := enrichKeyDurationVariant("周杰倫|Secret|不能說的秘密 電影原聲帶", 2)
	want := "周杰倫|Secret~dur2|不能說的秘密 電影原聲帶"
	if got != want {
		t.Errorf("enrichKeyDurationVariant = %q, want %q", got, want)
	}
	// 落在标题段,不能污染专辑段 —— "歌词管理"直接显示这三段。
	if artist, _, album := splitEnrichKey(got); artist != "周杰倫" || album != "不能說的秘密 電影原聲帶" {
		t.Errorf("variant polluted artist/album: artist=%q album=%q", artist, album)
	}
}

// resolveEnrichKeyForDuration 是"慢板/快板"真实bug的第二道兜底(splitByDuration 挡的是
// 启动迁移合并,这个挡的是实时首次撞车)——见其声明处头注。
func TestResolveEnrichKeyForDuration(t *testing.T) {
	key := "周杰倫|Secret|不能說的秘密 電影原聲帶"

	t.Run("key不存在直接放行", func(t *testing.T) {
		cache := map[string]enrichEntry{}
		rk, _, ok := resolveEnrichKeyForDuration(cache, key, 231)
		if rk != key || ok {
			t.Errorf("got (%q, ok=%v), want (%q, ok=false)", rk, ok, key)
		}
	})

	t.Run("时长兼容直接复用原key", func(t *testing.T) {
		cache := map[string]enrichEntry{key: {LyricsScore: 1200, DurationSecs: 231}}
		rk, e, ok := resolveEnrichKeyForDuration(cache, key, 233)
		if rk != key || !ok || e.LyricsScore != 1200 {
			t.Errorf("got (%q, %+v, ok=%v), want reuse of %q", rk, e, ok, key)
		}
	})

	t.Run("任一方时长未知也当兼容", func(t *testing.T) {
		cache := map[string]enrichEntry{key: {LyricsScore: 1200, DurationSecs: 0}}
		rk, _, ok := resolveEnrichKeyForDuration(cache, key, 68)
		if rk != key || !ok {
			t.Errorf("got (%q, ok=%v), want reuse of %q (unknown duration must not block)", rk, ok, key)
		}
	})

	t.Run("时长冲突且无变体位_落到第一个空位新建", func(t *testing.T) {
		cache := map[string]enrichEntry{key: {LyricsScore: 1200, DurationSecs: 231}}
		rk, _, ok := resolveEnrichKeyForDuration(cache, key, 68)
		want := enrichKeyDurationVariant(key, 2)
		if rk != want || ok {
			t.Errorf("got (%q, ok=%v), want (%q, ok=false)", rk, ok, want)
		}
	})

	t.Run("变体位已存在且时长兼容_复用它", func(t *testing.T) {
		v2 := enrichKeyDurationVariant(key, 2)
		cache := map[string]enrichEntry{
			key: {LyricsScore: 1200, DurationSecs: 231},
			v2:  {LyricsScore: 900, DurationSecs: 68},
		}
		rk, e, ok := resolveEnrichKeyForDuration(cache, key, 68)
		if rk != v2 || !ok || e.LyricsScore != 900 {
			t.Errorf("got (%q, %+v, ok=%v), want reuse of %q", rk, e, ok, v2)
		}
	})

	t.Run("变体位存在但也冲突_跳到下一个空位", func(t *testing.T) {
		v2 := enrichKeyDurationVariant(key, 2)
		cache := map[string]enrichEntry{
			key: {LyricsScore: 1200, DurationSecs: 231},
			v2:  {LyricsScore: 900, DurationSecs: 400}, // 第三个互不相容的时长
		}
		rk, _, ok := resolveEnrichKeyForDuration(cache, key, 68)
		want := enrichKeyDurationVariant(key, 3)
		if rk != want || ok {
			t.Errorf("got (%q, ok=%v), want (%q, ok=false)", rk, ok, want)
		}
	})

	t.Run("变体位全部冲突_放弃消歧退回原key", func(t *testing.T) {
		cache := map[string]enrichEntry{key: {LyricsScore: 1200, DurationSecs: 231}}
		for n := 2; n <= maxEnrichKeyDurationVariants; n++ {
			cache[enrichKeyDurationVariant(key, n)] = enrichEntry{DurationSecs: float64(n) * 500} // 故意都跟 68 冲突
		}
		rk, _, ok := resolveEnrichKeyForDuration(cache, key, 68)
		if rk != key || !ok {
			t.Errorf("got (%q, ok=%v), want fallback to (%q, ok=true)", rk, ok, key)
		}
	})
}

func TestBetterEnrichEntry(t *testing.T) {
	manual := enrichEntry{ManualLyrics: true, Lyrics: "x", LyricsScore: 1}
	high := enrichEntry{Lyrics: "x", LyricsScore: 1203}
	low := enrichEntry{Lyrics: "x", LyricsScore: 1107}
	empty := enrichEntry{LyricsScore: 9999}

	// 人工修正过的永远赢,分数再高也顶不过 —— 它是唯一删了找不回来的东西。
	if !betterEnrichEntry(manual, high, "a", "b") {
		t.Error("manual entry must win over a higher-scored automatic one")
	}
	// 有歌词压过没歌词,哪怕后者分数虚高。
	if !betterEnrichEntry(low, empty, "a", "b") {
		t.Error("entry with lyrics must win over an empty one")
	}
	// 同等条件下按 collector 自己的五源打分选 —— 这正是重复条目原来丢掉的那个判断:
	// 用哪一份纯看播放器怎么拼歌名,跟分数无关。
	if !betterEnrichEntry(high, low, "a", "b") {
		t.Error("higher lyrics_score must win")
	}
	// 完全平手时按 key 字典序,保证同一份数据每次迁移选出同一个赢家(Go 的 map 遍历
	// 顺序每次进程重启都不同)。
	same := enrichEntry{Lyrics: "x", LyricsScore: 5, TS: 7}
	if !betterEnrichEntry(same, same, "a", "b") || betterEnrichEntry(same, same, "b", "a") {
		t.Error("ties must break deterministically on key order")
	}
}

func TestMergePeripheralIntoKeepsLyricsBundleIntact(t *testing.T) {
	winner := enrichEntry{Lyrics: "winner lyrics", LyricsSource: "kugou", LyricsScore: 1203}
	loser := enrichEntry{
		Lyrics: "loser lyrics", LyricsTr: "loser translation", LyricsYRC: "loser yrc",
		LyricsSource: "netease", LyricsScore: 1107,
		CoverURL: "https://cover", CoverSource: "netease", AccentColor: "#123456",
		NeteaseURL: "https://ne", CanonicalArtist: "丁世光", DurationSecs: 261,
	}
	got := mergePeripheralInto(winner, loser)

	// 外围字段补过来
	if got.CoverURL != "https://cover" || got.CoverSource != "netease" ||
		got.AccentColor != "#123456" || got.NeteaseURL != "https://ne" ||
		got.CanonicalArtist != "丁世光" || got.DurationSecs != 261 {
		t.Errorf("peripheral fields not filled from loser: %#v", got)
	}
	// 歌词那一组一个字都不能串。译文的断行是跟着它自己那份歌词走的,贴到别人的歌词上
	// 时间轴直接错位 —— 宁可缺译文,让 needsTranslationBackfill 自己补。
	if got.Lyrics != "winner lyrics" || got.LyricsSource != "kugou" || got.LyricsScore != 1203 {
		t.Errorf("winner's lyrics identity was overwritten: %#v", got)
	}
	if got.LyricsTr != "" || got.LyricsYRC != "" {
		t.Errorf("loser's lyric variants leaked onto the winner: tr=%q yrc=%q", got.LyricsTr, got.LyricsYRC)
	}
}

func TestStaleExportKeysAlwaysDropsLosers(t *testing.T) {
	plain := "丁世光|不散的筵席|神經志 The Journal"                 // = 归一化后的 key
	subtitled := "丁世光|不散的筵席（I Miss You）|神經志 The Journal" // 胜出的那条(kugou 分更高)
	olds := []string{plain, subtitled}

	// 2026-08-14 实测的回归:带译名的那条胜出,而落选的 plain 恰好**就叫**归一化后的名字。
	// 第一版判据("k != newKey 才删")会把它的 .lrc 留在盘上,import 再按头部标签把落选正文
	// 盖回胜出条目 —— 记录变成"分数是胜者的、正文是败者的"。落选者必须无条件删。
	got := staleExportKeys(plain, subtitled, olds)
	want := map[string]bool{plain: true, subtitled: true}
	if len(got) != 2 {
		t.Fatalf("want both keys stale (loser's file must go even though it already has the final name), got %v", got)
	}
	for _, k := range got {
		if !want[k] {
			t.Errorf("unexpected stale key %q", k)
		}
	}

	// 反过来:胜出的那条本来就叫归一化后的名字 → 它的文件留着,只删落选那条。
	got = staleExportKeys(plain, plain, olds)
	if len(got) != 1 || got[0] != subtitled {
		t.Errorf("want only the loser stale, got %v", got)
	}

	// 单条、纯改名:旧文件要删,export 会用新名字重写一份。
	got = staleExportKeys(plain, subtitled, []string{subtitled})
	if len(got) != 1 || got[0] != subtitled {
		t.Errorf("rename case should mark the old name stale, got %v", got)
	}

	// 单条、名字没变:什么都不用删。
	if got = staleExportKeys(plain, plain, []string{plain}); len(got) != 0 {
		t.Errorf("no-op case should mark nothing stale, got %v", got)
	}
}

func TestEnrichExportedFileNamesCoversBothForms(t *testing.T) {
	// 普通名 4 个 + 带消歧哈希后缀 4 个。漏了带后缀那半,迁移删不掉落选条目的文件,
	// importLyricsFromFiles 会把它又导回来 —— 2026-08-05 的"删了又自己回来"就是这个坑。
	names := enrichExportedFileNames("丁世光|不散的筵席|神經志 The Journal")
	if len(names) != 8 {
		t.Fatalf("want 8 candidate names, got %d: %v", len(names), names)
	}
	var plain, hashed int
	for _, n := range names {
		if n == "丁世光 - 不散的筵席 - 神經志 The Journal.lrc" {
			plain++
		}
		if len(n) > 0 && n[len(n)-4:] == ".lrc" && containsTilde(n) {
			hashed++
		}
	}
	if plain != 1 {
		t.Errorf("plain .lrc name missing from %v", names)
	}
	if hashed == 0 {
		t.Errorf("hashed .lrc name missing from %v", names)
	}
}

func containsTilde(s string) bool {
	for _, r := range s {
		if r == '~' {
			return true
		}
	}
	return false
}
