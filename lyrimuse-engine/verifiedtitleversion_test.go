package main

import "testing"

// Amazon「Jay Chou - Rice Field (Live)」,专辑「Jay Chou The Invincible Concert Tour」(213s),即《地表最强世界巡回演唱会》。
func TestLiveAlbumConflictAcrossLanguages(t *testing.T) {
	const artist, title, album = "Jay Chou", "Rice Field (Live)", "Jay Chou The Invincible Concert Tour"
	// 同一场的中文叫法:名字比不出来,判据照旧判冲突;自报曲长对得上(213 对 213.28)才认作同一场。
	same := lyricCandidate{title: "稻香 (Live)", album: "周杰伦地表最强世界巡回演唱会", sourceReportedDurationSecs: 213.28}
	if !liveAlbumIdentityConflict(artist, title, album, same.title, same.album) || !sameLiveShowNamedInOtherLanguage(album, 213, same) {
		t.Error("中英两种叫法、曲长一致:认作同一场")
	}
	// 反过来(本地中文、候选英文)同样认:「NOW YOU SEE ME (Live)」musixmatch 写的是英文专辑名。
	if !sameLiveShowNamedInOtherLanguage("周杰伦地表最强世界巡回演唱会 (Live)", 168.066,
		lyricCandidate{album: "Jay Chou The Invincible Concert Tour", sourceReportedDurationSecs: 168}) {
		t.Error("本地中文、候选英文")
	}
	// 另一场(超时代演唱会,222s):中英混写、曲长也对不上,不认。
	era := lyricCandidate{title: "稻香 (Live)", album: "The Era 2010 超时代演唱会", sourceReportedDurationSecs: 222}
	if !liveAlbumIdentityConflict(artist, title, album, era.title, era.album) || sameLiveShowNamedInOtherLanguage(album, 213, era) {
		t.Error("另一场演出照旧判冲突")
	}
	// 全库回放里差点误放的两条:
	// 《龙卷风 (Live)》本地「The One 周杰伦演唱会」是中英混写,对「2004 无与伦比演唱会」不能当成另一种叫法(曲长凑巧只差 0.17s)。
	if sameLiveShowNamedInOtherLanguage("The One 周杰伦演唱会", 248.479, lyricCandidate{album: "2004 无与伦比演唱会 (Live)", sourceReportedDurationSecs: 248.307}) {
		t.Error("中英混写的专辑名不算另一种叫法")
	}
	// 《南音 (Live版)》大事发声(290.65s)对 Timeless演唱会(288s):一中一英,差 2.65s(不到 1%),是两场。
	if sameLiveShowNamedInOtherLanguage("大事发声.录音棚现场: 方大同 专场", 290.651, lyricCandidate{album: "Timeless演唱会", sourceReportedDurationSecs: 288}) {
		t.Error("曲长差 2.65s 不认作同一场")
	}
	if sameLiveShowNamedInOtherLanguage(album, 213, lyricCandidate{album: "周杰伦地表最强世界巡回演唱会"}) {
		t.Error("不知道候选曲长时不认")
	}
}

// Amazon「Jay Chou - Rice Field」(143s),原产地商店认出是《稻香 (Remix搖滾版)》。
func TestVerifiedTitleVersionAgrees(t *testing.T) {
	// 本地歌手写成中文:测试里没有「Jay Chou = 周杰伦」的别名缓存,英文署名配中文歌词会被语种闸整个拒掉,版本判定跟署名无关。
	const artist, title, album, dur = "周杰伦", "Rice Field", "Rice Field", 143.0
	daoxiang := func(c lyricCandidate) lyricCandidate {
		c.lyrics = "[00:15.10]对这个世界如果你有太多的抱怨\n[00:18.60]跌倒了就不敢继续往前走\n[00:21.70]为什么人要这么的脆弱堕落\n" +
			"[00:26.20]请你打开电视看看多少人为生命在努力勇敢的走下去\n[01:20.30]还记得你说家是唯一的城堡\n[02:18.50]让我感到幸福的就在身边\n"
		return c
	}
	build := func() []lyricCandidate {
		return []lyricCandidate{
			daoxiang(lyricCandidate{source: "migu", title: "稻香 (Remix摇滚版)", album: "稻香 (Remix摇滚版)", sourceReportedDurationSecs: dur}),
			daoxiang(lyricCandidate{source: "lrclib", title: "Rice Field", album: "Rice Field", sourceReportedDurationSecs: dur}),
			daoxiang(lyricCandidate{source: "kugou", title: "稻香 (Live)", album: "周杰伦地表最强世界巡回演唱会", sourceReportedDurationSecs: dur}),
			daoxiang(lyricCandidate{source: "qq", title: "稻香 (Remix摇滚版)", album: "稻香 (Remix摇滚版)", sourceReportedDurationSecs: dur + 3}),
			// 歌词头写着正式歌名:跟正式歌名对得上,不扣。
			withHeader(daoxiang(lyricCandidate{source: "kuwo", title: "稻香 (Remix摇滚版)", album: "稻香 (Remix摇滚版)", sourceReportedDurationSecs: dur}), "稻香 (Remix摇滚版)"),
			// 标题写 Remix、歌词头却写 Live:是给另一版做的词,照扣。
			withHeader(daoxiang(lyricCandidate{source: "netease", title: "稻香 (Remix摇滚版)", album: "稻香 (Remix摇滚版)", sourceReportedDurationSecs: dur}), "稻香 (Live)"),
		}
	}
	versionPoints := func(cands []lyricCandidate) map[string]int {
		out := map[string]int{}
		for _, c := range cands {
			score, terms := scoreLyricCandidateDetailed(artist, title, album, dur, c, false, 0)
			if score < 0 {
				t.Fatalf("%s 被整个拒掉,走不到版本那一项: %v", c.source, terms)
			}
			out[c.source] = termPoints(terms, scoreTermVersionTags)
		}
		return out
	}
	before := build()
	applyVerifiedTitleVersion(title, album, dur, "", before)
	if got := versionPoints(before); got["migu"] != -versionMismatchPenalty {
		t.Fatalf("前提:没有正式歌名时 Remix 版按本地标签判版本不符, got %v", got)
	}
	after := build()
	applyVerifiedTitleVersion(title, album, dur, "稻香 (Remix搖滾版)", after)
	got := versionPoints(after)
	if got["migu"] != 0 || got["lrclib"] != 0 {
		t.Errorf("跟正式歌名或本地标签对得上的都不扣, got %v", got)
	}
	if got["kugou"] != -versionMismatchPenalty {
		t.Errorf("两边都对不上的现场版照扣, got %v", got)
	}
	if got["qq"] != -versionMismatchPenalty {
		t.Errorf("曲长差 3s 的 Remix 版不沾正式歌名的光, got %v", got)
	}
	if got["kuwo"] != 0 {
		t.Errorf("歌词头写着正式歌名的不扣, got %v", got)
	}
	if got["netease"] != -versionMismatchPenalty {
		t.Errorf("歌词头带出正式歌名里也没有的 Live,照扣, got %v", got)
	}

	// 只认原产地商店那条反查,按专辑纯时长之类猜出来的不算。
	rounds := []scoredLyricCandidateResult{
		{Source: "qq", RetryMethod: lyricQueryReasonTitleAlbum, RetriedTitle: "爱爱爱 (Live)"},
		{Source: "migu", RetryMethod: lyricQueryReasonTitleStorefront, RetriedTitle: "稻香 (Remix搖滾版)"},
	}
	if v := verifiedRecordingTitle(rounds[:1]); v != "" {
		t.Errorf("按专辑纯时长猜的不算, got %q", v)
	}
	if v := verifiedRecordingTitle(nil, rounds); v != "稻香 (Remix搖滾版)" {
		t.Errorf("got %q", v)
	}
	// 正式歌名跟本地标签版本一样时什么都不标。
	same := build()
	applyVerifiedTitleVersion(title, album, dur, "稻香", same)
	for _, c := range same {
		if c.verifiedTitleVersionAgrees {
			t.Errorf("正式歌名没有多出版本限定词时不标: %s", c.source)
		}
	}
}

func withHeader(c lyricCandidate, ti string) lyricCandidate {
	c.lyrics = "[ti:" + ti + "]\n" + c.lyrics
	return c
}
