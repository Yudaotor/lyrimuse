package main

import "testing"

// 2026-08-05 加:LRCLIB 原来只打 /api/get 带 album_name 那一次,而 album_name 是参与匹配
// 的——传一个 LRCLIB 那边没有的专辑名会直接 404,整源判"没收录"。降级链见
// resolveLRCLIBLyric 的注释。这里覆盖第三级 /api/search 的挑选逻辑:它必须挑,而且绝不能
// 盲取第一条(实测真实响应里第一条 duration=4.0 是脏数据)。
func TestPickLRCLIBSearchResult(t *testing.T) {
	lrc := "[00:01.00]line one\n[00:05.00]line two\n[00:09.00]line three\n"
	item := func(track string, dur float64, synced string) lrclibSearchItem {
		return lrclibSearchItem{TrackName: track, ArtistName: "Michael Jackson", AlbumName: "XSCAPE", Duration: dur, SyncedLyrics: synced}
	}

	// 核心回归:第一条是脏数据(4 秒),必须挑到时长真正吻合的那条
	got := pickLRCLIBSearchResult([]lrclibSearchItem{
		item("Blue Gangsta", 4, lrc),
		item("Blue Gangsta", 257, lrc),
	}, "Michael Jackson", "Blue Gangsta", "", 255)
	if got == nil || got.Duration != 257 {
		t.Errorf("应挑到 257s 那条(而不是 4s 的脏数据),实际 %v", got)
	}

	// 多个都在容差内 → 取最接近的
	got = pickLRCLIBSearchResult([]lrclibSearchItem{
		item("Blue Gangsta", 270, lrc),
		item("Blue Gangsta", 256, lrc),
		item("Blue Gangsta", 240, lrc),
	}, "Michael Jackson", "Blue Gangsta", "", 255)
	if got == nil || got.Duration != 256 {
		t.Errorf("应取最接近 255s 的 256s,实际 %v", got)
	}

	// 版本限定词相反的候选必须跳过——搜 "Song" 很容易返回 "Song (Live)"
	got = pickLRCLIBSearchResult([]lrclibSearchItem{
		item("Blue Gangsta (Live)", 255, lrc),
	}, "Michael Jackson", "Blue Gangsta", "", 255)
	if got != nil {
		t.Errorf("版本限定词相反的候选不该被采纳,实际 %v", got.TrackName)
	}
	// 两边版本一致则可以采纳
	got = pickLRCLIBSearchResult([]lrclibSearchItem{
		item("Blue Gangsta (Live)", 255, lrc),
	}, "Michael Jackson", "Blue Gangsta (Live)", "", 255)
	if got == nil {
		t.Error("两边都是 Live 版应该采纳")
	}

	// 没有逐行时间戳的候选跳过
	if got = pickLRCLIBSearchResult([]lrclibSearchItem{item("Blue Gangsta", 255, "")}, "Michael Jackson", "Blue Gangsta", "", 255); got != nil {
		t.Error("syncedLyrics 为空的候选不该被采纳")
	}
	if got = pickLRCLIBSearchResult([]lrclibSearchItem{item("Blue Gangsta", 255, "no timestamps here")}, "Michael Jackson", "Blue Gangsta", "", 255); got != nil {
		t.Error("没有时间戳的候选不该被采纳")
	}

	// 歌手对不上跳过
	bad := item("Blue Gangsta", 255, lrc)
	bad.ArtistName = "Someone Else"
	if got = pickLRCLIBSearchResult([]lrclibSearchItem{bad}, "Michael Jackson", "Blue Gangsta", "", 255); got != nil {
		t.Error("歌手对不上的候选不该被采纳")
	}

	// 全部超出时长容差 → 挑不出,宁可这一源没结果
	if got = pickLRCLIBSearchResult([]lrclibSearchItem{item("Blue Gangsta", 600, lrc)}, "Michael Jackson", "Blue Gangsta", "", 255); got != nil {
		t.Error("时长差一倍以上的候选不该被采纳")
	}

	// 本地时长未知 → 退回"取第一个过门的",不因为无法核对就整源放弃
	got = pickLRCLIBSearchResult([]lrclibSearchItem{item("Blue Gangsta", 0, lrc), item("Blue Gangsta", 257, lrc)}, "Michael Jackson", "Blue Gangsta", "", 0)
	if got == nil || got.Duration != 0 {
		t.Errorf("本地时长未知时应取第一个过门的候选,实际 %v", got)
	}

	// 候选为空 / 全不过门
	if got = pickLRCLIBSearchResult(nil, "Michael Jackson", "Blue Gangsta", "", 255); got != nil {
		t.Error("空候选列表应返回 nil")
	}
}

// 审查确认的 BLOCKER 的回归测试:第三级曲名门原来用 looseContains(双向子串包含),而第三级
// 只在前两级精确 get 都 404 后才跑,正是"search 返回同歌手近似曲名"的场合,双向包含会把
// 另一首歌的歌词当成本曲。当时收紧成 lrclib 专用的 lrclibStrictTitleMatch;2026-08-09 起
// 这条规则推广到全部五个源、合并成 lyricTitleAccepted,这里改为直接钉它。
func TestLRCLIBTitleGate(t *testing.T) {
	cases := []struct {
		candidate, local string
		want             bool
		label            string
	}{
		{"Blue Gangsta", "Blue Gangsta", true, "完全相同"},
		{"blue gangsta", "Blue Gangsta", true, "大小写不敏感"},
		{"Blue  Gangsta", "Blue Gangsta", true, "空白差异归一化后相等"},
		// 去掉括号段后相等 —— 容 feat./remaster 这类后缀差异
		{"Blue Gangsta (Remastered)", "Blue Gangsta", true, "候选带括号后缀,去括号后相等"},
		{"Blue Gangsta", "Blue Gangsta (feat. X)", true, "本地带括号后缀,去括号后相等"},
		// 核心回归:双向子串包含必须被拒
		{"Real Love", "Love", false, "候选包含本地曲名(另一首歌)→ 拒"},
		{"Real Love Baby", "Real Love", false, "候选更长(另一首歌)→ 拒"},
		{"Love", "Real Love", false, "本地包含候选曲名 → 拒"},
		{"Beat It", "Bad", false, "完全不同 → 拒"},
		{"", "Blue Gangsta", false, "候选空 → 拒"},
		{"Blue Gangsta", "", false, "本地空 → 拒"},
	}
	for _, c := range cases {
		if got := lyricTitleAccepted(c.candidate, c.local); got != c.want {
			t.Errorf("%s: lyricTitleAccepted(%q, %q) = %v, want %v", c.label, c.candidate, c.local, got, c.want)
		}
	}
}

// 顺带钉住"另一首歌的候选整体过不了门"这条端到端语义(时长/歌手都对得上,只有曲名不同)。
func TestPickLRCLIBSearchResultRejectsNearMissTitle(t *testing.T) {
	lrc := "[00:01.00]a\n[00:05.00]b\n[00:09.00]c\n"
	items := []lrclibSearchItem{
		{TrackName: "Real Love", ArtistName: "Michael Jackson", Duration: 255, SyncedLyrics: lrc},
	}
	if got := pickLRCLIBSearchResult(items, "Michael Jackson", "Love", "", 255); got != nil {
		t.Errorf("同歌手的近似曲名不该被采纳,实际选中 %q", got.TrackName)
	}
}
