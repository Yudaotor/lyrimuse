package main

import "testing"

// 2026-09-01 真实bug(周杰伦《简单爱 (Live)》/《The One 周杰伦演唱会》,「搜索候选歌词」
// 弹窗 8 个源只有酷狗回了一条错场次的「无与伦比演唱会」版):这首歌在网易云明明存在
// (album 18906 / song 186043,自报 273.0s 与本地 273.227s 只差 0.227s,52 行 LRC),但
// 曲目搜索被 UGC 翻做/仿冒号刷屏,四条查询词各自的前 30 条里官方版一次都没出现——搜索
// 召回失败不等于曲库没有。anchorAlbumTrackForLocalTitle 是补这个缺口的专辑锚定判据,
// 见其头注。
func TestAnchorAlbumTrackForLocalTitle(t *testing.T) {
	// 按 /api/album/18906 的真实数据裁剪(时长取真实值)。
	theOne := []albumTrack{
		{title: "双截棍(Live)", artist: "周杰伦", duration: 250.0, neteaseSongID: 186025, neteaseAlbum: "The One 周杰伦演唱会"},
		{title: "星晴(Live)", artist: "周杰伦", duration: 262.0, neteaseSongID: 186038, neteaseAlbum: "The One 周杰伦演唱会"},
		{title: "简单爱(Live)", artist: "周杰伦", duration: 273.0, neteaseSongID: 186043, neteaseAlbum: "The One 周杰伦演唱会"},
		{title: "开不了口(Live)", artist: "周杰伦", duration: 555.0, neteaseSongID: 186044, neteaseAlbum: "The One 周杰伦演唱会"},
	}

	t.Run("真实案例:本地标题带空格括号,锚定到无空格的官方曲目", func(t *testing.T) {
		got, ok := anchorAlbumTrackForLocalTitle(theOne, "周杰伦", "简单爱 (Live)", 273.227)
		if !ok {
			t.Fatal("应该锚定成功")
		}
		if got.neteaseSongID != 186043 {
			t.Errorf("锚定到了 %d(%q),想要 186043", got.neteaseSongID, got.title)
		}
	})

	t.Run("标题闸:时长接近但标题对不上的曲目不能锚定", func(t *testing.T) {
		// 262.0s 的《星晴(Live)》离 261.9 只差 0.1s,但本地放的是《爱在西元前 (Live)》——
		// 这张裁剪过的列表里没有它,时长再近也不能拿别的歌顶包。
		if got, ok := anchorAlbumTrackForLocalTitle(theOne, "周杰伦", "爱在西元前 (Live)", 261.9); ok {
			t.Errorf("不该锚定,却给了 %q", got.title)
		}
	})

	t.Run("歌手闸:曲目歌手对不上时不能锚定", func(t *testing.T) {
		tracks := []albumTrack{
			{title: "简单爱(Live)", artist: "别的歌手", duration: 273.0, neteaseSongID: 1},
		}
		if _, ok := anchorAlbumTrackForLocalTitle(tracks, "周杰伦", "简单爱 (Live)", 273.227); ok {
			t.Error("歌手对不上不该锚定")
		}
	})

	t.Run("歌手闸:曲目歌手为空时跳过歌手闸(专辑已按歌手核验过)", func(t *testing.T) {
		tracks := []albumTrack{
			{title: "简单爱(Live)", artist: "", duration: 273.0, neteaseSongID: 1},
		}
		if _, ok := anchorAlbumTrackForLocalTitle(tracks, "周杰伦", "简单爱 (Live)", 273.227); !ok {
			t.Error("歌手为空时应该只按标题+时长锚定")
		}
	})

	t.Run("时长容差:超出 2 秒不锚定", func(t *testing.T) {
		if _, ok := anchorAlbumTrackForLocalTitle(theOne, "周杰伦", "简单爱 (Live)", 273.0+retryTitleFromAlbumMaxDurationDiffSecs+0.5); ok {
			t.Error("时长差超容差不该锚定")
		}
	})

	t.Run("歧义:两条标题不同的曲目同误差时整体放弃", func(t *testing.T) {
		tracks := []albumTrack{
			// 「简单爱」和「简单爱(Live)」都能过 lyricTitleAccepted(剥括号相等档),
			// 时长又一样——分不出该是哪条,宁可没有,也不要错。
			{title: "简单爱", artist: "周杰伦", duration: 273.0, neteaseSongID: 1},
			{title: "简单爱(Live)", artist: "周杰伦", duration: 273.0, neteaseSongID: 2},
		}
		if got, ok := anchorAlbumTrackForLocalTitle(tracks, "周杰伦", "简单爱 (Live)", 273.227); ok {
			t.Errorf("同误差歧义不该锚定,却给了 %q", got.title)
		}
	})

	t.Run("没有 neteaseSongID 的曲目(Apple 本地资料库来源)整条忽略", func(t *testing.T) {
		tracks := []albumTrack{
			{title: "简单爱(Live)", artist: "周杰伦", duration: 273.0, neteaseSongID: 0},
		}
		if _, ok := anchorAlbumTrackForLocalTitle(tracks, "周杰伦", "简单爱 (Live)", 273.227); ok {
			t.Error("没有歌曲 ID 的条目锚定了也取不了词,不该返回")
		}
	})

	t.Run("时长为零的曲目忽略(v1 端点字段名坑的防线,见 neAlbumSong 注释)", func(t *testing.T) {
		tracks := []albumTrack{
			{title: "简单爱(Live)", artist: "周杰伦", duration: 0, neteaseSongID: 1},
		}
		if _, ok := anchorAlbumTrackForLocalTitle(tracks, "周杰伦", "简单爱 (Live)", 273.227); ok {
			t.Error("时长缺失的曲目无法做时长锚定,不该返回")
		}
	})
}
