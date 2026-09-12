package main

import "testing"

// 2026-09-09 真实 bug:Prince《Free》(酷狗)的灵动岛歌词里满屏 `they&apos;re` / `Don&apos;t`。
// 全库核实酷狗 11 条 + 网易云 1 条带字符实体(`&apos;` / `&quot;` / `&amp;` / `&nbsp;`),整行与
// 逐字两轨同样带着,见 lyricentities.go 头注。下面的歌词行都是自编的形状样本,不是真实歌词。
func TestDecodeLyricEntities(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"没有 & 原样返回", "[00:32.64]普通歌词，没有实体", "[00:32.64]普通歌词，没有实体"},
		{"空串", "", ""},
		{"XML 撇号实体(酷狗真实形态)", "[00:32.64]Don&apos;t sleep &apos;til the sunrise", "[00:32.64]Don't sleep 'til the sunrise"},
		{"引号 / 与号", "[00:10.47]Carvin &quot;Ransum&quot; Haggins &amp; friends", "[00:10.47]Carvin \"Ransum\" Haggins & friends"},
		{"源自带的头部标签也解", "[ar:Earth, Wind &amp; Fire]\n[ti:Everybody (Backstreet&apos;s Back) (7&quot; Version)]", "[ar:Earth, Wind & Fire]\n[ti:Everybody (Backstreet's Back) (7\" Version)]"},
		{"十进制 / 十六进制数字实体", "it&#39;s &#x27;bout time", "it's 'bout time"},
		{"HTML 命名实体(标准库认识的都解)", "wait&hellip; &mdash; she said &lsquo;go&rsquo;", "wait… — she said ‘go’"},
		{"逐字 YRC 词条里的实体(酷狗 KRC 转出来的形态)", "[33581,1060](33581,1060,0)&apos;til (34641,310,0)the", "[33581,1060](33581,1060,0)'til (34641,310,0)the"},
		// 三条边界
		{"不带分号的遗留实体不碰(Q&A / R&B / &notice)", "Q&A at the R&B show, take &notice", "Q&A at the R&B show, take &notice"},
		{"不认识的实体名原样保留", "R&B; and &foo; and &x1;", "R&B; and &foo; and &x1;"},
		{"控制字符不换(&#10; 会拆行)", "line one&#10;line two &#9;tab", "line one&#10;line two &#9;tab"},
		{"nbsp 换成普通空格而不是 U+00A0", "Whoa&nbsp;? and&#160;this&#xa0;too", "Whoa ? and this too"},
		// 只解一层
		{"双重转义只解一层", "they&amp;apos;re", "they&apos;re"},
		{"孤立的 & 原样", "rock & roll & more &", "rock & roll & more &"},
		{"实体名过长不匹配", "&" + "abcdefghijklmnopqrstuvwxyzabcdefghij;", "&abcdefghijklmnopqrstuvwxyzabcdefghij;"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := decodeLyricEntities(c.in); got != c.want {
				t.Errorf("decodeLyricEntities(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}

// decodeLyricEntities 对已经解过的文本必须是空操作——migrateLyricEntities 每次启动都跑,
// 靠这条保证"跑一次和跑十次一样"(除了刻意只解一层的双重转义,那不是干净文本)。
func TestDecodeLyricEntitiesIdempotentOnCleanText(t *testing.T) {
	clean := decodeLyricEntities("[00:32.64]Don&apos;t sleep &apos;til the sunrise &amp; Carvin &quot;Ransum&quot;")
	if again := decodeLyricEntities(clean); again != clean {
		t.Errorf("second pass changed clean text: %q -> %q", clean, again)
	}
}

// rank 入口那一步:九个源的全部歌词文本字段都要过一遍,而且不能改调用方那份 raw——
// fetchScoredLyricCandidatesStreaming 每来一个源就全量重跑一次 rank,原地改会解好几层。
func TestDecodeLyricSourceEntitiesCoversEveryTextFieldAndLeavesInputAlone(t *testing.T) {
	raw := map[string]lyricSourceResult{
		"kugou":   {source: "kugou", lyr: "[00:01.00]Don&apos;t", yrc: "[1000,500](1000,500,0)Don&apos;t", tr: "[00:01.00]译&amp;文", roma: "[00:01.00]don&apos;t", matchTitle: "Don&apos;t Stop"},
		"netease": {source: "netease", ne: neteaseInfo{Lyrics: "[00:01.00]Whoa&nbsp;?", Trans: "[00:01.00]哇&quot;", Roma: "[00:01.00]wo&apos;a", YRC: "[1000,500](1000,500,0)Whoa&nbsp;?"}},
		"amll":    {source: "amll", amll: amllResult{lrc: "[00:01.00]it&apos;s", yrc: "[1000,500](1000,500,0)it&apos;s", tr: "[00:01.00]它&amp;"}},
	}
	out := decodeLyricSourceEntities(raw)

	k := out["kugou"]
	if k.lyr != "[00:01.00]Don't" || k.yrc != "[1000,500](1000,500,0)Don't" || k.tr != "[00:01.00]译&文" || k.roma != "[00:01.00]don't" {
		t.Errorf("kugou fields not decoded: %+v", k)
	}
	if k.matchTitle != "Don&apos;t Stop" {
		t.Errorf("matchTitle must be left alone (it feeds title matching), got %q", k.matchTitle)
	}
	n := out["netease"].ne
	if n.Lyrics != "[00:01.00]Whoa ?" || n.Trans != "[00:01.00]哇\"" || n.Roma != "[00:01.00]wo'a" || n.YRC != "[1000,500](1000,500,0)Whoa ?" {
		t.Errorf("netease fields not decoded: %+v", n)
	}
	a := out["amll"].amll
	if a.lrc != "[00:01.00]it's" || a.yrc != "[1000,500](1000,500,0)it's" || a.tr != "[00:01.00]它&" {
		t.Errorf("amll fields not decoded: %+v", a)
	}
	// 调用方那份原样
	if raw["kugou"].lyr != "[00:01.00]Don&apos;t" || raw["netease"].ne.Lyrics != "[00:01.00]Whoa&nbsp;?" || raw["amll"].amll.lrc != "[00:01.00]it&apos;s" {
		t.Errorf("input map was mutated: %+v", raw)
	}
	// 拿同一份 raw 再跑一次(模拟下一个源到达后的全量重跑),结果必须一样——而不是再解一层
	if again := decodeLyricSourceEntities(raw); again["kugou"].lyr != out["kugou"].lyr {
		t.Errorf("re-running rank over the same raw changed the result: %q vs %q", again["kugou"].lyr, out["kugou"].lyr)
	}
}

// 存量迁移:五个字段都解;manual_pick_sha 在改前跟正文对得上的要按新正文重算(否则
// ManualPickLock.state 会把用户选过的歌改判成「已被换掉」),对不上的不碰;manual_lyrics 不跳过;
// 没实体的条目一个字节不动、不置脏。
func TestMigrateLyricEntities(t *testing.T) {
	enrichMu.Lock()
	savedCache, savedDirty, savedPath := enrichCache, enrichDirty, enrichPath
	enrichMu.Unlock()
	t.Cleanup(func() {
		enrichMu.Lock()
		enrichCache, enrichDirty, enrichPath = savedCache, savedDirty, savedPath
		enrichMu.Unlock()
	})

	dirtyLyrics := "[00:32.64]Don&apos;t sleep &apos;til the sunrise\n[00:39.19]Don&apos;t worry"
	cleanLyrics := "[00:32.64]Don't sleep 'til the sunrise\n[00:39.19]Don't worry"
	enrichMu.Lock()
	enrichPath = "" // saveEnrichCache 对空路径早退,测试不落盘
	enrichDirty = false
	enrichCache = map[string]enrichEntry{
		"kugou-matching-sha": {
			Lyrics: dirtyLyrics, LyricsYRC: "[32640,1000](32640,1000,0)Don&apos;t", LyricsTr: "[00:32.64]译&amp;文",
			LyricsRoma: "[00:32.64]don&apos;t", PlainLyrics: "Don&apos;t",
			ManualPickSHA: manualPickFingerprint(dirtyLyrics), ManualLyrics: true,
		},
		"kugou-stale-sha": {Lyrics: dirtyLyrics, ManualPickSHA: "000000000000"},
		"clean":           {Lyrics: "[00:01.00]rock & roll", LyricsYRC: "[1000,500](1000,500,0)rock & roll", ManualPickSHA: "abcdefabcdef"},
	}
	enrichMu.Unlock()

	migrateLyricEntities()

	enrichMu.Lock()
	defer enrichMu.Unlock()
	e := enrichCache["kugou-matching-sha"]
	if e.Lyrics != cleanLyrics || e.LyricsYRC != "[32640,1000](32640,1000,0)Don't" || e.LyricsTr != "[00:32.64]译&文" || e.LyricsRoma != "[00:32.64]don't" || e.PlainLyrics != "Don't" {
		t.Errorf("fields not decoded: %+v", e)
	}
	if !e.ManualLyrics {
		t.Errorf("manual_lyrics flag must survive")
	}
	if e.ManualPickSHA != manualPickFingerprint(cleanLyrics) {
		t.Errorf("manual_pick_sha must be recomputed on the decoded text: got %q want %q", e.ManualPickSHA, manualPickFingerprint(cleanLyrics))
	}
	if s := enrichCache["kugou-stale-sha"]; s.Lyrics != cleanLyrics || s.ManualPickSHA != "000000000000" {
		t.Errorf("stale sha must be left alone while text is still decoded: %+v", s)
	}
	if c := enrichCache["clean"]; c.Lyrics != "[00:01.00]rock & roll" || c.LyricsYRC != "[1000,500](1000,500,0)rock & roll" || c.ManualPickSHA != "abcdefabcdef" {
		t.Errorf("clean entry must be untouched: %+v", c)
	}
	if !enrichDirty {
		t.Errorf("migration changed entries but did not mark the cache dirty")
	}

	// 幂等:再跑一次什么都不改、不置脏
	enrichDirty = false
	enrichMu.Unlock()
	migrateLyricEntities()
	enrichMu.Lock()
	if enrichDirty {
		t.Errorf("second run must be a no-op")
	}
}
