package main

import "testing"

// 这道防线的**粒度**是有历史的:2026-08-22 之前 neteaseLookup 对黑名单艺人直接 return
// 空、一个请求都不发,代价是这位艺人每一首歌都先天少一个源(而网易云是五源里唯一同时供
// 逐字 YRC、社区译文和罗马音的那个)。收窄成"只扣身份/封面"之后,下面两条不变量就是这次
// 收窄的全部安全边界,任何一条被改松都等于把原防线拆了:
//
//	① 黑名单艺人:身份/封面/跳转链接/专辑 id/纯音乐结论一律不给 —— 下游行为跟原来的
//	   整源跳过逐条一致(封面退 Apple、canonical_artist 走其它链路、专辑预取早退);
//	② 歌词族连同 Title/Album/DurationSecs 照常给 —— 后三个不是"展示用",它们是版本
//	   限定词、专辑亲和、时长吻合那几道打分闸的**输入**,扣掉等于把放行歌词之后唯一的
//	   把关依据也一起拿走。
//
// 详见 withholdImpersonatorRiddenIdentity 的注释与 docs/features/09 的已知坑 12。
func TestWithholdImpersonatorRiddenIdentity(t *testing.T) {
	full := neteaseInfo{
		Cover:        "https://p1.music.126.net/cover.jpg",
		SongURL:      "https://music.163.com/song?id=1400391910",
		Lyrics:       "[00:17.45]才离开没多久就开始",
		Trans:        "[00:17.45]translated",
		Roma:         "[00:17.45]cai li kai",
		YRC:          `{"t":17450,"c":[{"tx":"才"}]}`,
		DurationSecs: 272.973,
		Artist:       "周杰伦",
		Title:        "开不了口 (Live)",
		Album:        "周杰伦地表最强世界巡回演唱会",
		AlbumID:      123456,
		PureMusic:    true,
	}

	t.Run("非黑名单艺人原样透传", func(t *testing.T) {
		got := withholdImpersonatorRiddenIdentity("Addison Rae", full)
		if got != full {
			t.Errorf("withholdImpersonatorRiddenIdentity(非黑名单) 改动了字段:\n got  %+v\n want %+v", got, full)
		}
	})

	t.Run("黑名单艺人只留歌词族与打分输入", func(t *testing.T) {
		got := withholdImpersonatorRiddenIdentity("周杰伦", full)

		// ① 扣下:采信这些就等于把仿冒号的署名/配图/链接当成官方的。
		if got.Cover != "" {
			t.Errorf("Cover 必须扣下(封面选源要退到 Apple),got %q", got.Cover)
		}
		if got.Artist != "" {
			t.Errorf("Artist 必须扣下(它会被写进 canonical_artist),got %q", got.Artist)
		}
		if got.SongURL != "" {
			t.Errorf("SongURL 必须扣下(它会被写进 netease_url),got %q", got.SongURL)
		}
		if got.AlbumID != 0 {
			t.Errorf("AlbumID 必须扣下(专辑预取会拿它拉整张曲目表),got %d", got.AlbumID)
		}
		if got.PureMusic {
			t.Error("PureMusic 必须扣下:这类艺人的曲库记录不可信,不该由它下「本来就没词」的结论——" +
				"那个标记会挡掉后续重搜(needsLyricsFirstFill)")
		}

		// ② 放行:歌词族,以及三个打分闸的输入。
		if got.Lyrics != full.Lyrics || got.Trans != full.Trans ||
			got.Roma != full.Roma || got.YRC != full.YRC {
			t.Errorf("歌词族必须原样放行,got %+v", got)
		}
		if got.Title != full.Title {
			t.Errorf("Title 必须放行(lyricTitleAccepted / versionTagsMismatch 的输入),got %q", got.Title)
		}
		if got.Album != full.Album {
			t.Errorf("Album 必须放行(albumScore / versionTagsMismatch 的输入),got %q", got.Album)
		}
		if got.DurationSecs != full.DurationSecs {
			t.Errorf("DurationSecs 必须放行(时长吻合/overshoot 那两档的输入),got %v", got.DurationSecs)
		}
	})

	t.Run("繁体写法同样按黑名单处理", func(t *testing.T) {
		if got := withholdImpersonatorRiddenIdentity("周杰倫", full); got.Cover != "" || got.Artist != "" {
			t.Errorf("繁体名也在 neteaseImpersonatorRiddenArtists 里,身份/封面同样要扣下,got %+v", got)
		}
	})
}
