package main

import "testing"

// Spotify 真曲目 ID(2026-09-09):URI 解析、真链接派生、提示表消费、LB 标准字段。
// 全是纯函数 / 内存表,不碰网络与磁盘。

func TestSpotifyTrackIDFromURI(t *testing.T) {
	cases := []struct{ in, want string }{
		{"spotify:track:7HuBDWi18s4aJM8UFnNheH", "7HuBDWi18s4aJM8UFnNheH"},
		{"  spotify:track:0H5iEzn4EWoevLeB60ZJfj\n", "0H5iEzn4EWoevLeB60ZJfj"}, // osascript 回声带换行
		{"spotify:ad:abc", ""},                         // 广告
		{"spotify:local:a:b:c:1", ""},                  // 本地文件
		{"spotify:episode:7HuBDWi18s4aJM8UFnNheH", ""}, // 播客节目
		{"spotify:track:short", ""},                    // 形状不对
		{"spotify:track:7HuBDWi18s4aJM8UFnNhe-", ""},   // 非 base62
		{"missing value", ""},
		{"", ""},
	}
	for _, c := range cases {
		if got := spotifyTrackIDFromURI(c.in); got != c.want {
			t.Errorf("spotifyTrackIDFromURI(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestSpotifyURIIsAd(t *testing.T) {
	if !spotifyURIIsAd("spotify:ad:1234") || !spotifyURIIsAd(" spotify:ad:x\n") {
		t.Fatal("spotify:ad: 前缀必须判成广告")
	}
	if spotifyURIIsAd("spotify:track:7HuBDWi18s4aJM8UFnNheH") || spotifyURIIsAd("") {
		t.Fatal("曲目 / 空串不是广告")
	}
}

func TestSpotifyLinkPrefersTrackID(t *testing.T) {
	e := enrichEntry{SpotifyURL: "https://open.spotify.com/search/x%20y"}
	if got := e.spotifyLink(); got != "https://open.spotify.com/search/x%20y" {
		t.Fatalf("没有 ID 时退回搜索链接, got %q", got)
	}
	e.SpotifyTrackID = "7HuBDWi18s4aJM8UFnNheH"
	if got := e.spotifyLink(); got != "https://open.spotify.com/track/7HuBDWi18s4aJM8UFnNheH" {
		t.Fatalf("有 ID 时给真曲目链接, got %q", got)
	}
	if (enrichEntry{}).spotifyLink() != "" {
		t.Fatal("两者都没有时是空串")
	}
	// fields() 是 relay / LB 读的那份:spotify_url 走 spotifyLink,spotify_track_id 原样带出。
	f := e.fields()
	if f["spotify_url"] != "https://open.spotify.com/track/7HuBDWi18s4aJM8UFnNheH" || f["spotify_track_id"] != "7HuBDWi18s4aJM8UFnNheH" {
		t.Fatalf("fields() 里的 spotify_url / spotify_track_id 不对: %v", f)
	}
}

func TestSpotifyTrackIDHintRoundTrip(t *testing.T) {
	saved := spotifyTrackIDHints
	defer func() { spotifyTrackIDHints = saved }()
	spotifyTrackIDHints = map[string]string{}

	noteSpotifyTrackID("Taylor Swift", "King Of My Heart", "reputation", "7HuBDWi18s4aJM8UFnNheH")
	noteSpotifyTrackID("Taylor Swift", "", "reputation", "7HuBDWi18s4aJM8UFnNheH") // 没歌名不记
	noteSpotifyTrackID("Taylor Swift", "Delicate", "reputation", "")               // 没 ID 不记

	key := enrichKey("Taylor Swift", "King Of My Heart", "reputation")
	e := enrichEntry{SpotifyURL: "https://open.spotify.com/search/Taylor%20Swift%20King%20Of%20My%20Heart"}
	enrichMu.Lock()
	changed := applySpotifyTrackIDHintLocked(key, &e)
	again := applySpotifyTrackIDHintLocked(key, &e)
	other := applySpotifyTrackIDHintLocked(enrichKey("Taylor Swift", "Delicate", "reputation"), &e)
	enrichMu.Unlock()
	if !changed || e.SpotifyTrackID != "7HuBDWi18s4aJM8UFnNheH" {
		t.Fatalf("第一次应用要写进 ID 并报告有改动: changed=%v id=%q", changed, e.SpotifyTrackID)
	}
	if again {
		t.Fatal("同一 ID 第二次应用不该再报改动(否则每拍都落盘)")
	}
	if other {
		t.Fatal("没有提示的 key 不该改条目")
	}
	if len(spotifyTrackIDHints) != 1 {
		t.Fatalf("没歌名 / 没 ID 的调用不该进表, got %d 条", len(spotifyTrackIDHints))
	}
	// 键按 enrichKey 归一:歌名结尾的译名括号会被剥掉,poller 与 trackEnrichment 两边算出来的必须是同一个键。
	noteSpotifyTrackID("方大同", "簡單最浪漫（Simple Love Song）", "未來", "0H5iEzn4EWoevLeB60ZJfj")
	e2 := enrichEntry{}
	enrichMu.Lock()
	ok := applySpotifyTrackIDHintLocked(enrichKey("方大同", "簡單最浪漫", "未來"), &e2)
	enrichMu.Unlock()
	if !ok || e2.SpotifyTrackID != "0H5iEzn4EWoevLeB60ZJfj" {
		t.Fatalf("提示键要走 enrichKey 归一化, ok=%v id=%q", ok, e2.SpotifyTrackID)
	}
}

func TestSpotifyTrackIDHintCap(t *testing.T) {
	saved := spotifyTrackIDHints
	defer func() { spotifyTrackIDHints = saved }()
	spotifyTrackIDHints = map[string]string{}
	for i := 0; i < spotifyTrackIDHintCap; i++ {
		noteSpotifyTrackID("a", "t"+string(rune('A'+i%26))+string(rune('a'+i/26%26))+string(rune('0'+i/676%10)), "al", "7HuBDWi18s4aJM8UFnNheH")
	}
	if len(spotifyTrackIDHints) != spotifyTrackIDHintCap {
		t.Fatalf("到上限前应该都在, got %d", len(spotifyTrackIDHints))
	}
	noteSpotifyTrackID("a", "overflow", "al", "7HuBDWi18s4aJM8UFnNheH")
	if len(spotifyTrackIDHints) != 1 {
		t.Fatalf("超过上限整表清掉、只留最新一条, got %d", len(spotifyTrackIDHints))
	}
}

func TestSpotifyListenFields(t *testing.T) {
	got := spotifyListenFields(spotifyBundleID, "7HuBDWi18s4aJM8UFnNheH")
	want := "https://open.spotify.com/track/7HuBDWi18s4aJM8UFnNheH"
	if got["spotify_id"] != want || got["origin_url"] != want || got["music_service"] != "spotify.com" || len(got) != 3 {
		t.Fatalf("Spotify 原生播放要给三个标准字段: %v", got)
	}
	if spotifyListenFields("com.apple.Music", "7HuBDWi18s4aJM8UFnNheH") != nil {
		t.Fatal("别的播放器放同一首歌,不能说是在 spotify.com 听的")
	}
	if spotifyListenFields(spotifyBundleID, "") != nil {
		t.Fatal("没有 ID 就一个键都不写")
	}
}

func TestMergePeripheralKeepsSpotifyTrackID(t *testing.T) {
	winner := enrichEntry{Lyrics: "w"}
	loser := enrichEntry{SpotifyTrackID: "7HuBDWi18s4aJM8UFnNheH", SpotifyURL: "https://open.spotify.com/search/x"}
	m := mergePeripheralInto(winner, loser)
	if m.SpotifyTrackID != "7HuBDWi18s4aJM8UFnNheH" {
		t.Fatalf("重复条目合并时 winner 没有 ID 要从 loser 继承, got %q", m.SpotifyTrackID)
	}
	winner.SpotifyTrackID = "0H5iEzn4EWoevLeB60ZJfj"
	if mergePeripheralInto(winner, loser).SpotifyTrackID != "0H5iEzn4EWoevLeB60ZJfj" {
		t.Fatal("winner 自己有 ID 时不被 loser 覆盖")
	}
}
