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
