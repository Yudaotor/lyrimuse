package main

import "testing"

func TestYouTubeMusicWatchURL(t *testing.T) {
	if got := youtubeMusicWatchURL("OMOGaugKpzs"); got != "https://music.youtube.com/watch?v=OMOGaugKpzs" {
		t.Errorf("11 位 videoId 应拼成歌曲页,got %q", got)
	}
	for _, bad := range []string{"", "OMOGaugKpz", "OMOGaugKpzs1", "OMOGaugKp/s", "OMOGaug Kpz"} {
		if got := youtubeMusicWatchURL(bad); got != "" {
			t.Errorf("%q 不是 videoId 的形状,不该给链接: %q", bad, got)
		}
	}
}

func TestYouTubeMusicTrackURLFor(t *testing.T) {
	t.Cleanup(func() { noteKasetCurrentTrack("", "", "", "") })
	noteKasetCurrentTrack(kasetBundleID, "The Police", "Every Breath You Take", "OMOGaugKpzs")
	if youtubeMusicTrackURLFor(kasetBundleID, "The Police", "Every Breath You Take") == "" {
		t.Error("同一首应给出歌曲页")
	}
	if youtubeMusicTrackURLFor(kasetBundleID, "The Police", "Roxanne") != "" {
		t.Error("别的歌不能挂上这首的链接")
	}
	if youtubeMusicTrackURLFor(spotifyBundleID, "The Police", "Every Breath You Take") != "" {
		t.Error("别的播放器不给")
	}
	// 解析那一轮拿到的是剥掉 MV 标记的歌名,App 报的是原样的。
	noteKasetCurrentTrack(kasetBundleID, "Culture Club", "Karma Chameleon (Official Music Video)", "JmcA9LIIXWw")
	if youtubeMusicTrackURLFor(kasetBundleID, "Culture Club", normEnrichTitle("Karma Chameleon (Official Music Video)")) == "" {
		t.Error("歌名两边归一了再比,MV 标记不该让它认不出")
	}
	noteKasetCurrentTrack(spotifyBundleID, "The Police", "Every Breath You Take", "OMOGaugKpzs")
	if youtubeMusicTrackURLFor(kasetBundleID, "The Police", "Every Breath You Take") != "" {
		t.Error("App 报的不是 Kaset 时应清掉")
	}
}
