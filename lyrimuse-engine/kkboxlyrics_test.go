package main

import (
	"strings"
	"testing"
)

const testKKBOXLyricsBody = `{"status":"OK","data":{"info":{"lyricist":"","composer":"","lyrics":[
 {"start":0,"end":0,"type":0,"text":"Written By: Taylor Swift & Jack Antonoff"},
 {"start":0,"end":0,"type":0,"text":"Produced By: Jack Antonoff"},
 {"start":12340,"end":15000,"type":0,"text":"I have this thing where I get older"},
 {"start":15020,"end":18500,"type":1,"text":" but just never wiser "},
 {"start":61005,"end":65000,"type":0,"text":""},
 {"start":65010,"end":70000,"type":3,"text":"It's me, hi"},
 {"start":0,"end":0,"type":0,"text":""}
]},"uploadable":false,"reason":"已建歌詞"}}`

func TestKKBOXLyricsLRC(t *testing.T) {
	lrc, coarse, ok := kkboxLyricsLRC([]byte(testKKBOXLyricsBody))
	if !ok || coarse {
		t.Fatalf("ok=%v coarse=%v", ok, coarse)
	}
	want := "[00:12.34]I have this thing where I get older\n[00:15.02]but just never wiser\n[01:01.00]\n[01:05.01]It's me, hi\n"
	if lrc != want {
		t.Errorf("署名行(start=end=0)去掉、毫秒换成 LRC:\ngot  %q\nwant %q", lrc, want)
	}

	// 用户上传的那类只精确到整秒:照样出词,标成 coarse(不享受同源加权)。
	whole := `{"data":{"info":{"lyrics":[{"start":28000,"end":34000,"text":"a"},{"start":34000,"end":41000,"text":"b"},{"start":42000,"end":48000,"text":"c"}]}}}`
	if _, coarse, ok := kkboxLyricsLRC([]byte(whole)); !ok || !coarse {
		t.Errorf("整秒时间轴: ok=%v coarse=%v", ok, coarse)
	}

	for name, body := range map[string]string{
		"只有署名":    `{"data":{"info":{"lyrics":[{"start":0,"end":0,"text":"作詞:x"},{"start":0,"end":0,"text":"作曲:y"}]}}}`,
		"没有歌词":    `{"data":{"info":{"lyrics":[]}}}`,
		"没有 info": `{"data":{}}`,
		"不到三句":    `{"data":{"info":{"lyrics":[{"start":1000,"end":2000,"text":"a"},{"start":2500,"end":3000,"text":"b"}]}}}`,
		"坏 JSON":  `{`,
	} {
		if _, _, ok := kkboxLyricsLRC([]byte(body)); ok {
			t.Errorf("%s: 不该算有歌词", name)
		}
	}
}

func TestKKBOXLyricMatch(t *testing.T) {
	tr := kkboxTrack{Name: "最偉大的作品", DurationMs: 244062}
	tr.ArtistRoles = &struct {
		Main     []kkboxArtist `json:"main_artists"`
		Featured []kkboxArtist `json:"featured_artists"`
	}{Main: []kkboxArtist{{Name: "周杰倫"}}}
	if !kkboxLyricMatch(tr, "周杰倫", "最偉大的作品", 0) {
		t.Error("歌名、歌手都对上")
	}
	if !kkboxLyricMatch(tr, "周杰伦 (Jay Chou)", "最偉大的作品", 245) {
		t.Error("歌手写法不同(别的播放器),时长对得上:认")
	}
	if kkboxLyricMatch(tr, "Someone Else", "最偉大的作品", 200) {
		t.Error("歌手不同、时长也对不上:不认")
	}
	if kkboxLyricMatch(tr, "Someone Else", "最偉大的作品", 0) {
		t.Error("歌手不同、没有时长可比:不认")
	}
	if kkboxLyricMatch(tr, "周杰倫", "說好不哭", 244) {
		t.Error("歌名不同:不认")
	}
}

// 缓存里有歌词的曲目才解开单曲详情比对;歌词条目按曲目 id 对上。
func TestKKBOXLyricFromCache(t *testing.T) {
	withTestKKBOX(t, "kkbox:song-list:LIST==:0:0?track=T1", false)
	cache := kkboxCacheDirOverride
	testChromiumCacheEntry(t, cache, "l1_0", "https://api-webapps.kkbox.com.tw/v2/tracks/AH1?terr=tw",
		`{"data":{"id":"AH1","name":"Anti-Hero","artist":{"name":"Taylor Swift (泰勒絲)"},"artist_roles":{"main_artists":[{"name":"Taylor Swift"}],"featured_artists":[]},"album":{"name":"Midnights"},"duration_ms":200690}}`)
	testChromiumCacheEntry(t, cache, "l2_0", "https://api-webapps.kkbox.com.tw/v2/lyrics/AH1?terr=tw", testKKBOXLyricsBody)
	// 另一首有详情、没有歌词:不该被当成这首。
	testChromiumCacheEntry(t, cache, "l3_0", "https://api-webapps.kkbox.com.tw/v2/tracks/LV1?terr=tw",
		`{"data":{"id":"LV1","name":"Lavender Haze","artist_roles":{"main_artists":[{"name":"Taylor Swift"}]},"duration_ms":202000}}`)

	got, ok := kkboxLyric("Taylor Swift", "Anti-Hero", 200.7)
	if !ok {
		t.Fatal("有详情、有歌词:该取到")
	}
	if got.title != "Anti-Hero" || got.artist != "Taylor Swift" || got.album != "Midnights" || got.durationSecs != 200.69 || got.coarse {
		t.Errorf("结果: %+v", got)
	}
	if !strings.HasPrefix(got.lyrics, "[00:12.34]I have this thing") {
		t.Errorf("正文: %q", got.lyrics)
	}
	if _, ok := kkboxLyric("Taylor Swift", "Lavender Haze", 202); ok {
		t.Error("没有歌词的那首:空手而归")
	}
	if _, ok := kkboxLyric("Taylor Swift", "Not Played", 0); ok {
		t.Error("没用 KKBOX 放过的:空手而归")
	}
}

func TestKKBOXLyricsRecheckOnce(t *testing.T) {
	saved := kkboxLyricsRechecked
	kkboxLyricsRechecked = map[string]bool{}
	t.Cleanup(func() { kkboxLyricsRechecked = saved })
	if !kkboxLyricsRecheckOnce("a|b|c") || kkboxLyricsRecheckOnce("a|b|c") {
		t.Error("同一个条目这次进程里只重来一次")
	}
	if !kkboxLyricsRecheckOnce("a|x|c") {
		t.Error("别的条目各算各的")
	}
}

// kkbox 的同源候选落选不触发 needsLyricsRetry 的「同源落选」那条(见 enrich.go 里 nativeMissedOut 的注释)。
func TestKKBOXNativeMissNotRetried(t *testing.T) {
	setNativeLyricSourcesForPlayer(kkboxBundleID)
	t.Cleanup(func() { setNativeLyricSourcesForPlayer("") })
	e := enrichEntry{Lyrics: "[00:01.00]x", LyricsYRC: "yrc", LyricsSource: "kugou", LyricsSourcesSeen: []string{"kugou", "kkbox"}}
	if needsLyricsRetry(e, false, false, true) {
		t.Error("kkbox 带着同源加权输给逐字的酷狗:不该连着重搜")
	}
	setNativeLyricSourcesForPlayer(sodaMusicBundleID)
	e.LyricsSourcesSeen = []string{"kugou", "soda"}
	if !needsLyricsRetry(e, false, false, true) {
		t.Error("别的播放器的同源落选照旧重来一次(这条只对 kkbox 收窄)")
	}
}

// 只在正在用 KKBOX 放歌时读;来源不在设置的开关里,开关判据对它恒为 true。
func TestKKBOXLocalLyricsOnlyForKKBOX(t *testing.T) {
	withTestKKBOX(t, "kkbox:song-list:LIST==:0:0?track=T1", false)
	cache := kkboxCacheDirOverride
	testChromiumCacheEntry(t, cache, "l1_0", "https://api-webapps.kkbox.com.tw/v2/tracks/AH1?terr=tw",
		`{"data":{"id":"AH1","name":"Anti-Hero","artist_roles":{"main_artists":[{"name":"Taylor Swift"}]},"duration_ms":200690}}`)
	testChromiumCacheEntry(t, cache, "l2_0", "https://api-webapps.kkbox.com.tw/v2/lyrics/AH1?terr=tw", testKKBOXLyricsBody)
	t.Cleanup(func() { setNativeLyricSourcesForPlayer("") })

	setNativeLyricSourcesForPlayer(spotifyBundleID)
	if _, ok := kkboxLocalLyricsFor("Taylor Swift", "Anti-Hero", 200.7); ok {
		t.Error("不是在用 KKBOX 放:不读")
	}
	setNativeLyricSourcesForPlayer(kkboxBundleID)
	r, ok := kkboxLocalLyricsFor("Taylor Swift", "Anti-Hero", 200.7)
	if !ok || r.source != kkboxLocalLyricsSource || r.lyr == "" || !r.identityFromLocalClient {
		t.Errorf("用 KKBOX 放:读到一份同源候选,got %+v ok=%v", r, ok)
	}
	if !lyricSourceEnabled(kkboxLocalLyricsSource) {
		t.Error("KKBOX 本地歌词没有开关,开关判据对它恒为 true")
	}
}

func TestKKBOXLyricsWorthRecheck(t *testing.T) {
	fresh := enrichEntry{Lyrics: "[00:01.00]x", LyricsSourcesSeen: []string{"netease", "qq"}}
	if !kkboxLyricsWorthRecheck(fresh, kkboxBundleID, false, true, true) {
		t.Error("用 KKBOX 放、当初没见过 kkbox、现在有词:重来一次")
	}
	seen := fresh
	seen.LyricsSourcesSeen = append([]string{}, "netease", "kkbox")
	if kkboxLyricsWorthRecheck(seen, kkboxBundleID, false, true, true) {
		t.Error("当初见过 kkbox:不重来(一次之后就停)")
	}
	responded := fresh
	responded.LyricsDecision = &lyricsDecision{SourcesResponded: []string{"kugou", "kkbox"}}
	if kkboxLyricsWorthRecheck(responded, kkboxBundleID, false, true, true) {
		t.Error("最近一轮决策里 kkbox 应答过(别的路径刚重搜过):不再来")
	}
	if kkboxLyricsWorthRecheck(fresh, spotifyBundleID, false, true, true) {
		t.Error("不是在用 KKBOX 放:不管(同源加权只对 KKBOX 成立)")
	}
	if kkboxLyricsWorthRecheck(fresh, kkboxBundleID, false, true, false) {
		t.Error("KKBOX 这首还没有词:不重来")
	}
	if kkboxLyricsWorthRecheck(fresh, kkboxBundleID, true, true, true) {
		t.Error("校准过时间轴:不动")
	}
	if kkboxLyricsWorthRecheck(fresh, kkboxBundleID, false, false, true) {
		t.Error("关了自动升级:不动")
	}
	manual := fresh
	manual.ManualLyrics = true
	if kkboxLyricsWorthRecheck(manual, kkboxBundleID, false, true, true) {
		t.Error("手改过:不动")
	}
	used := fresh
	used.LyricsRetryCount = lyricsRetryMaxAttempts
	if kkboxLyricsWorthRecheck(used, kkboxBundleID, false, true, true) {
		t.Error("重试次数用完:不动")
	}
}

func TestKKBOXSongPageURL(t *testing.T) {
	for raw, want := range map[string]bool{
		"https://www.kkbox.com/tw/tc/song/4s7gyziTOGRFhEcFQf": true,
		"https://www.kkbox.com/jp/ja/song/AbC":                true,
		"http://www.kkbox.com/tw/tc/song/X":                   false,
		"https://evil.example.com/tw/tc/song/X":               false,
		"https://www.kkbox.com/tw/tc/album/X":                 false,
		"https://www.kkbox.com/tw/tc/song/":                   false,
		"":                                                    false,
	} {
		if got := kkboxSongPageURL(raw); got != want {
			t.Errorf("%q: got %v want %v", raw, got, want)
		}
	}
}

// 用 KKBOX 放的这首:单曲详情给的歌曲页记进条目,导出给 App 和网页。
func TestKKBOXPlayingInfoSongURL(t *testing.T) {
	withTestKKBOX(t, "kkbox:song-list:LIST==:0:0?track=T1", false)
	testChromiumCacheEntry(t, kkboxCacheDirOverride, "su1_0", "https://api-webapps.kkbox.com.tw/v2/tracks/AH1?terr=tw",
		`{"data":{"id":"AH1","name":"Anti-Hero","url":"https://www.kkbox.com/tw/tc/song/AH1","artist_roles":{"main_artists":[{"name":"Taylor Swift"}]},"duration_ms":200690}}`)
	c := scanKKBOXCache(kkboxCacheDir())
	if got := c.songURLFor("Taylor Swift", "Anti-Hero", 200.7); got != "https://www.kkbox.com/tw/tc/song/AH1" {
		t.Errorf("歌曲页: %q", got)
	}
	if got := c.songURLFor("Taylor Swift", "Not Played", 0); got != "" {
		t.Errorf("没放过的歌没有歌曲页: %q", got)
	}
	if got := (enrichEntry{KKBOXURL: "https://www.kkbox.com/tw/tc/song/AH1"}).fields()["kkbox_url"]; got == "" {
		t.Error("fields() 要带 kkbox_url")
	}
}
