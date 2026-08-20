package main

import "testing"

// 守的是"Spotify 插播广告被当成一次收听上送"这个真实故障(2026-08-14):用户在网页
// 「最近播放」和 App「最近记录」里看到了 "Now Streaming on Hulu." / "BLIZZARD® Double
// Flip Deal BOGO for 99¢"。广告当时已经被挡住不去搜歌词,但上送路径完全没设防。
func TestIsAdBreak(t *testing.T) {
	cases := []struct {
		name, bundle, artist, title, album string
		want                               bool
	}{
		// 真实数据:media-control 在广告期间把 album 报成空串。
		{"Spotify 广告(无专辑)", spotifyBundleID, "Häagen-Dazs", "Take your sweet time.", "", true},
		{"Spotify 正常曲目", spotifyBundleID, "Michael Jackson", "Bad", "Bad", false},
		// 2026-08-19 实测漏网形态:标题「—」占位广告,artist 空、album **非空**,
		// 熬过 8 秒 pnPending 仍被 announce 成 Last.fm nowplaying(用户截图)。
		{"Spotify 广告(artist 空)", spotifyBundleID, "", "—", "SomeBrand", true},
		{"Spotify 广告(占位标题—)", spotifyBundleID, "Brand", "—", "Brand", true},
		// 判据只对 Spotify 生效 —— 另外三家的正常曲目本来就带专辑名,不该被这条规则波及,
		// 更不该因为偶尔缺专辑名就整首歌不上送。
		{"Apple Music 无专辑不算广告", "com.apple.Music", "A", "T", "", false},
		{"QQ 音乐无专辑不算广告", qqMusicBundleID, "A", "T", "", false},
		{"网易云无专辑不算广告", neteaseMusicBundleID, "A", "T", "", false},
		{"空 bundle 不算广告", "", "", "", "", false},
	}
	for _, c := range cases {
		if got := isAdBreak(c.bundle, c.artist, c.title, c.album); got != c.want {
			t.Errorf("%s: isAdBreak(%q, %q, %q, %q) = %v, want %v",
				c.name, c.bundle, c.artist, c.title, c.album, got, c.want)
		}
	}
}
