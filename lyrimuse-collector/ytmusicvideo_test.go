package main

import (
	"context"
	"strings"
	"testing"
	"time"
)

func resetYTMusicVideoCacheForTest(t *testing.T) {
	t.Helper()
	reset := func() {
		ytmusicVideoMu.Lock()
		ytmusicVideoKey, ytmusicVideoType, ytmusicVideoAt = "", "", time.Time{}
		ytmusicVideoMu.Unlock()
	}
	reset()
	t.Cleanup(reset)
}

func stubYTMusicVideoTypeScript(t *testing.T, out string, ok bool, calls *int) {
	t.Helper()
	saved := ytmusicVideoTypeScript
	ytmusicVideoTypeScript = func(context.Context, string, string) (string, bool) {
		if calls != nil {
			*calls++
		}
		return out, ok
	}
	t.Cleanup(func() { ytmusicVideoTypeScript = saved })
}

func TestYTMusicVideoTypeJSHasNoQuotesOrBackslashes(t *testing.T) {
	if strings.Contains(ytmusicVideoTypeJS, `"`) || strings.Contains(ytmusicVideoTypeJS, `\`) {
		t.Fatal("ytmusicVideoTypeJS 里不能有双引号或反斜杠(整段要嵌进 AppleScript 的双引号字符串)")
	}
	for _, marker := range []string{"#movie_player", "getPlayerResponse", "musicVideoType", "NOTFOUND"} {
		if !strings.Contains(ytmusicVideoTypeJS, marker) {
			t.Errorf("JS 里缺少 %q", marker)
		}
	}
}

func TestParseYTMusicVideoType(t *testing.T) {
	cases := []struct{ raw, want string }{
		{"MUSIC_VIDEO_TYPE_OMV", "MUSIC_VIDEO_TYPE_OMV"},
		{"MUSIC_VIDEO_TYPE_ATV\n", "MUSIC_VIDEO_TYPE_ATV"},
		{`"MUSIC_VIDEO_TYPE_UGC"`, "MUSIC_VIDEO_TYPE_UGC"}, // Chromium 系会再包一层双引号
		{"NOTFOUND", ""},
		{"NONE", ""},
		{"", ""},
		{"missing value", ""},
		{"MUSIC_VIDEO_TYPE_OMV|x", ""},
	}
	for _, c := range cases {
		if got := parseYTMusicVideoType(c.raw); got != c.want {
			t.Errorf("parseYTMusicVideoType(%q) = %q, want %q", c.raw, got, c.want)
		}
	}
}

func TestYTMusicIsMusicVideoType(t *testing.T) {
	for vt, want := range map[string]bool{
		"MUSIC_VIDEO_TYPE_OMV":                   true,
		"MUSIC_VIDEO_TYPE_UGC":                   true,
		"MUSIC_VIDEO_TYPE_ATV":                   false, // 歌曲版:时长就是歌的长度
		"MUSIC_VIDEO_TYPE_PRIVATELY_OWNED_TRACK": false,
		"":                                       false, // 读不到按歌处理
	} {
		if got := ytmusicIsMusicVideoType(vt); got != want {
			t.Errorf("ytmusicIsMusicVideoType(%q) = %v, want %v", vt, got, want)
		}
	}
}

func TestYTMusicMusicVideoCachesPerTrackAndSkipsFailures(t *testing.T) {
	resetYTMusicVideoCacheForTest(t)
	const chrome = "com.google.Chrome"
	calls := 0

	// 读不到:按歌处理,而且不进缓存 —— 下一轮要重试。
	stubYTMusicVideoTypeScript(t, "", false, &calls)
	if ytmusicMusicVideo(context.Background(), chrome, "a\x00b") {
		t.Error("读不到时该按歌处理")
	}
	stubYTMusicVideoTypeScript(t, "NOTFOUND", true, &calls)
	if ytmusicMusicVideo(context.Background(), chrome, "a\x00b") {
		t.Error("页面上没有播放器时该按歌处理")
	}
	ytmusicVideoMu.Lock()
	if ytmusicVideoKey != "" {
		t.Errorf("失败的读数不该进缓存, key = %q", ytmusicVideoKey)
	}
	ytmusicVideoMu.Unlock()

	// 读到 OMV:认成 MV;同一首歌复用缓存,不再跑脚本。
	calls = 0
	stubYTMusicVideoTypeScript(t, "MUSIC_VIDEO_TYPE_OMV", true, &calls)
	if !ytmusicMusicVideo(context.Background(), chrome, "a\x00b") {
		t.Error("OMV 该认成 MV")
	}
	if !ytmusicMusicVideo(context.Background(), chrome, "a\x00b") || calls != 1 {
		t.Errorf("同一首歌该命中缓存, 脚本跑了 %d 次", calls)
	}
	// 换了曲目就重新问。
	stubYTMusicVideoTypeScript(t, "MUSIC_VIDEO_TYPE_ATV", true, &calls)
	if ytmusicMusicVideo(context.Background(), chrome, "c\x00d") {
		t.Error("ATV 不该认成 MV")
	}
	if calls != 2 {
		t.Errorf("换曲目该重新跑脚本, 共跑了 %d 次", calls)
	}
	// 驱动不了的浏览器(Firefox 等)不跑脚本。
	if ytmusicMusicVideo(context.Background(), "org.mozilla.firefox", "e\x00f") || calls != 2 {
		t.Errorf("没有脚本方言的浏览器不该跑脚本, 共跑了 %d 次", calls)
	}
}

// MV 只影响交给歌词解析的时长,Duration 本身原样保留(打卡门槛、上送时长、专辑回填都读它)。
func TestSnapshotYTMusicVideoKeepsDurationForEverythingButLyrics(t *testing.T) {
	mv := extract(map[string]any{"title": "Buddy", "artist": "Musiq Soulchild", "duration": 231.4, stateKeyYTMusicVideo: true})
	if !mv.NotAudio || mv.Duration != 231.4 || mv.lyricsDurationSecs() != 0 {
		t.Errorf("MV: NotAudio=%v Duration=%v lyricsDuration=%v", mv.NotAudio, mv.Duration, mv.lyricsDurationSecs())
	}
	if listenThreshold(mv.Duration) != 231.4/2 {
		t.Errorf("MV 的打卡门槛不该退成缺时长的 %v 秒", listenCapSecs)
	}
	song := extract(map[string]any{"title": "Buddy", "artist": "Musiq Soulchild", "duration": 223.8})
	if song.NotAudio || song.lyricsDurationSecs() != 223.8 {
		t.Errorf("普通曲目: NotAudio=%v lyricsDuration=%v", song.NotAudio, song.lyricsDurationSecs())
	}
}

func TestYTMusicPagePatchApply(t *testing.T) {
	raw := map[string]any{"album": ""}
	ytmusicPagePatch{album: "Already Gone", musicVideo: true}.apply(raw)
	if raw["album"] != "Already Gone" || raw[stateKeyYTMusicVideo] != true {
		t.Errorf("补丁没写进去: %+v", raw)
	}
	raw2 := map[string]any{"album": "原专辑"}
	ytmusicPagePatch{}.apply(raw2)
	if raw2["album"] != "原专辑" || raw2[stateKeyYTMusicVideo] != nil {
		t.Errorf("零值补丁不该改任何东西: %+v", raw2)
	}
}
