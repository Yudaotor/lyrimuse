package main

import "testing"

func kkboxTestTrack(name, artist string, durMs float64) kkboxTrack {
	tr := kkboxTrack{Name: name, DurationMs: durMs}
	tr.ArtistRoles = &struct {
		Main     []kkboxArtist `json:"main_artists"`
		Featured []kkboxArtist `json:"featured_artists"`
	}{Main: []kkboxArtist{{Name: artist}}}
	return tr
}

// 歌手对不上时只认「去掉括号别名后沾边 + 时长对得上」;光时长对得上的翻唱不认。
func TestKKBOXLyricMatchLevel(t *testing.T) {
	orig := kkboxTestTrack("晴天", "周杰倫", 269000)
	cases := []struct {
		name   string
		track  kkboxTrack
		artist string
		dur    float64
		want   int
	}{
		{"歌手逐字对上", orig, "周杰倫", 0, kkboxMatchExact},
		{"繁简不同也算逐字对上", orig, "周杰伦", 0, kkboxMatchExact},
		{"括号别名 + 时长", orig, "周杰伦 (Jay Chou)", 270, kkboxMatchByAlias},
		{"全角括号别名 + 时长", kkboxTestTrack("晴天", "五月天（Mayday）", 200000), "五月天", 201, kkboxMatchByAlias},
		{"别名沾边但没有时长", orig, "周杰伦 (Jay Chou)", 0, kkboxMatchNone},
		{"翻唱:时长只差一秒也不认", orig, "某翻唱歌手", 270, kkboxMatchNone},
		{"歌名不同", kkboxTestTrack("说好不哭", "周杰倫", 269000), "周杰倫", 269, kkboxMatchNone},
	}
	for _, c := range cases {
		if got := kkboxLyricMatchLevel(c.track, c.artist, "晴天", c.dur); got != c.want {
			t.Errorf("%s: got %d, want %d", c.name, got, c.want)
		}
	}
}

// 缓存里同名的两条:歌手逐字对上的优先,哪怕别名那条更新;只有别名那条时标 weakIdentity。
func TestKKBOXLyricPrefersExactArtist(t *testing.T) {
	withTestKKBOX(t, "kkbox:song-list:LIST==:0:0?track=T1", false)
	cache := kkboxCacheDirOverride
	testChromiumCacheEntry(t, cache, "l1_0", "https://api-webapps.kkbox.com.tw/v2/tracks/ALIAS?terr=tw",
		`{"data":{"id":"ALIAS","name":"Song","artist_roles":{"main_artists":[{"name":"五月天 (Mayday)"}]},"duration_ms":200000}}`)
	testChromiumCacheEntry(t, cache, "l2_0", "https://api-webapps.kkbox.com.tw/v2/lyrics/ALIAS?terr=tw", testKKBOXLyricsBody)
	testChromiumCacheEntry(t, cache, "l3_0", "https://api-webapps.kkbox.com.tw/v2/tracks/EXACT?terr=tw",
		`{"data":{"id":"EXACT","name":"Song","artist_roles":{"main_artists":[{"name":"五月天"}]},"duration_ms":201000}}`)
	testChromiumCacheEntry(t, cache, "l4_0", "https://api-webapps.kkbox.com.tw/v2/lyrics/EXACT?terr=tw", testKKBOXLyricsBody)

	got, ok := kkboxLyric("五月天", "Song", 200.5)
	if !ok || got.artist != "五月天" || got.weakIdentity {
		t.Fatalf("应当取歌手逐字对上的那条: %+v %v", got, ok)
	}
	got, ok = kkboxLyric("五月天阿信", "Song", 200.5)
	if !ok || !got.weakIdentity {
		t.Fatalf("只有别名沾边的那条时应当标 weakIdentity: %+v %v", got, ok)
	}
	if _, ok := kkboxLyric("别的歌手", "Song", 200.5); ok {
		t.Fatal("歌手完全不沾边时不认")
	}
}
