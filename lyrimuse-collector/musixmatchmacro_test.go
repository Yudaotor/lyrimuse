package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

const mxmTestLRC = "[00:05.00] line one\n[00:15.00] line two\n[00:25.00] line three\n[00:35.00] line four\n[00:45.00] line five\n[02:50.00] line six"

// mxmMacroFixture 拼一份 macro.subtitles.get 应答。richsyncStatus 为 0 时不带逐字那一块。
func mxmMacroFixture(t *testing.T, name, artist string, subLength float64, restricted int, richsyncStatus int, trTo ...string) string {
	t.Helper()
	status := make([]map[string]any, 0, len(trTo))
	for _, to := range trTo {
		status = append(status, map[string]any{"from": "eng", "to": to, "perc": 1})
	}
	wrap := func(code int, body any) map[string]any {
		return map[string]any{"message": map[string]any{"header": map[string]any{"status_code": code}, "body": body}}
	}
	rsBody, _ := json.Marshal([]map[string]any{{"ts": 5.0, "te": 9.0, "l": []map[string]any{{"c": "line", "o": 0}, {"c": " ", "o": 0.5}, {"c": "one", "o": 0.6}}}})
	calls := map[string]any{
		"matcher.track.get": wrap(200, map[string]any{"track": map[string]any{
			"track_id": 42, "track_name": name, "artist_name": artist, "album_name": "Album",
			"has_subtitles": 1, "has_richsync": 1, "track_length": 0, "track_lyrics_translation_status": status}}),
		"track.subtitles.get": wrap(200, map[string]any{"subtitle_list": []any{map[string]any{"subtitle": map[string]any{
			"subtitle_body": mxmTestLRC, "subtitle_length": subLength, "restricted": restricted}}}}),
		"track.lyrics.get": wrap(200, map[string]any{"lyrics": map[string]any{"lyrics_body": "line one\nline two"}}),
	}
	if richsyncStatus == 200 {
		calls["track.richsync.get"] = wrap(200, map[string]any{"richsync": map[string]any{"richsync_body": string(rsBody)}})
	} else if richsyncStatus != 0 {
		calls["track.richsync.get"] = wrap(richsyncStatus, nil)
	}
	b, _ := json.Marshal(wrap(200, map[string]any{"macro_calls": calls}))
	return string(b)
}

func TestParseMusixmatchMacro(t *testing.T) {
	m, ok := parseMusixmatchMacro([]byte(mxmMacroFixture(t, "Song", "Singer", 194, 0, 200, "spa", "zht")))
	if !ok || m.match.trackID != 42 || m.lrc != mxmTestLRC || m.yrc == "" || m.subLength != 194 || !m.musixmatchHasTranslation("zht") || m.subFailed {
		t.Fatalf("正常应答没解析全: ok=%v %+v", ok, m)
	}
	if m, _ := parseMusixmatchMacro([]byte(mxmMacroFixture(t, "Song", "Singer", 194, 1, 200))); m.lrc != "" {
		t.Error("受限(restricted)的逐行歌词不该用")
	}
	if m, _ := parseMusixmatchMacro([]byte(mxmMacroFixture(t, "Song", "Singer", 194, 0, 401))); !m.subFailed || m.yrc != "" {
		t.Errorf("逐字那一块没问成(401)要标成不完整: %+v", m)
	}
	if m, _ := parseMusixmatchMacro([]byte(mxmMacroFixture(t, "Song", "Singer", 194, 0, 404))); m.subFailed {
		t.Error("逐字 404 是这首没有,不算没问成")
	}
	if _, ok := parseMusixmatchMacro([]byte(`{"message":{"body":{"macro_calls":{"matcher.track.get":{"message":{"header":{"status_code":404}}}}}}}`)); ok {
		t.Error("matcher 没认出曲目时应返回 ok=false")
	}
}

func TestMusixmatchIDDurationFits(t *testing.T) {
	for _, c := range []struct {
		local, src float64
		want       bool
	}{{194, 194, true}, {194, 197, true}, {194, 198, false}, {400, 407, true}, {400, 409, false}, {243, 258, false}, {0, 200, false}, {200, 0, false}} {
		if got := musixmatchIDDurationFits(c.local, c.src); got != c.want {
			t.Errorf("musixmatchIDDurationFits(%v, %v) = %v, want %v", c.local, c.src, got, c.want)
		}
	}
}

type mxmFakeServer struct {
	mu    sync.Mutex
	calls []string
}

func (f *mxmFakeServer) called(action string) []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []string
	for _, c := range f.calls {
		if strings.HasPrefix(c, action+"?") {
			out = append(out, c)
		}
	}
	return out
}

// withMxmFake 把 musixmatchBases 换成本地假服务器,token 直接放进内存(不申请、不落盘)。
func withMxmFake(t *testing.T, handle func(action string, r *http.Request) string) *mxmFakeServer {
	t.Helper()
	resetMusixmatchTokenStateForTest(t)
	musixmatchDoFetchToken = func(context.Context) string { return "" }
	musixmatchTokenMu.Lock()
	musixmatchToken, musixmatchTokenExpiry = "test-token", time.Now().Add(time.Hour)
	musixmatchTokenMu.Unlock()
	f := &mxmFakeServer{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		action := r.URL.Path[strings.LastIndex(r.URL.Path, "/")+1:]
		f.mu.Lock()
		f.calls = append(f.calls, action+"?"+r.URL.RawQuery)
		f.mu.Unlock()
		fmt.Fprint(w, handle(action, r))
	}))
	t.Cleanup(srv.Close)
	saved := musixmatchBases
	musixmatchBases = []string{srv.URL + "/ws/1.1/"}
	t.Cleanup(func() { musixmatchBases = saved })
	return f
}

const mxmEmpty404 = `{"message":{"header":{"status_code":404},"body":""}}`

func mxmTranslations(lines map[string]string) string {
	var list []map[string]any
	for orig, tr := range lines {
		list = append(list, map[string]any{"translation": map[string]any{"subtitle_matched_line": orig, "description": tr}})
	}
	b, _ := json.Marshal(map[string]any{"message": map[string]any{"header": map[string]any{"status_code": 200}, "body": map[string]any{"translations_list": list}}})
	return string(b)
}

// 带播放器给的 Apple ID:一次 macro 取齐逐行 + 逐字,不走 track.search;按 zh 取回空、状态列了 zht 时补取繁体并转成简体。
func TestResolveMusixmatchUsesMacroByPlaybackID(t *testing.T) {
	hant := map[string]string{"line one": "第一行說話", "line two": "第二行說話", "line three": "第三行說話", "line four": "第四行說話", "line five": "第五行說話", "line six": "第六行說話"}
	f := withMxmFake(t, func(action string, r *http.Request) string {
		switch action {
		case "macro.subtitles.get":
			return mxmMacroFixture(t, "Gomenne", "Kenshi Yonezu", 212, 0, 200, "zht")
		case "crowd.track.translations.get":
			if r.URL.Query().Get("selected_language") == "zht" {
				return mxmTranslations(hant)
			}
			return mxmTranslations(nil)
		}
		return mxmEmpty404
	})
	ctx := withMusixmatchPlaybackIDs(context.Background(), "1234", "")
	r := resolveMusixmatchLyric(ctx, "米津玄师", "ごめんね", 212, "zh", "")
	if r.lrc != mxmTestLRC || r.yrc == "" || r.title != "Gomenne" {
		t.Fatalf("按 ID 应一次取齐逐行 + 逐字(名字对不上也认): %+v", r)
	}
	if got := f.called("macro.subtitles.get"); len(got) != 1 || !strings.Contains(got[0], "track_itunes_id=1234") {
		t.Errorf("应按 track_itunes_id 发一次 macro: %v", got)
	}
	if n := len(f.called("track.search")) + len(f.called("track.subtitle.get")) + len(f.called("track.richsync.get")); n != 0 {
		t.Errorf("macro 命中后不该再走原来的搜索 / 逐行 / 逐字请求,多发了 %d 次", n)
	}
	if !strings.Contains(r.tr, "第一行说话") || strings.Contains(r.tr, "說") {
		t.Errorf("繁体译文应补取并转成简体: %q", r.tr)
	}
}

// 按 ID 取回来的时长差太多(实测那例 258 对 243 秒)、按歌名取回来的歌手对不上:都退回原来的 track.search 流程。
func TestResolveMusixmatchMacroFallsBackToSearch(t *testing.T) {
	f := withMxmFake(t, func(action string, r *http.Request) string {
		switch action {
		case "macro.subtitles.get":
			if r.URL.Query().Get("track_itunes_id") != "" {
				return mxmMacroFixture(t, "小さな魔女と僕", "Someone Else", 258, 0, 200)
			}
			return mxmMacroFixture(t, "魔女と僕", "Someone Else", 243, 0, 200)
		case "crowd.track.translations.get":
			return mxmTranslations(nil)
		}
		return mxmEmpty404
	})
	ctx := withMusixmatchPlaybackIDs(context.Background(), "6804398728", "")
	r := resolveMusixmatchLyric(ctx, "back number", "魔女と僕", 243, "zh", "")
	if r.lrc != "" {
		t.Fatalf("两条 macro 都不该被采用(搜索也没结果): %+v", r)
	}
	if got := len(f.called("macro.subtitles.get")); got != 2 {
		t.Errorf("应先按 ID、再按歌名各试一次 macro,got %d", got)
	}
	if len(f.called("track.search")) != 1 {
		t.Errorf("两条 macro 都没过检查时应退回 track.search: %v", f.calls)
	}
}

func TestAppleCatalogIDFromURL(t *testing.T) {
	for in, want := range map[string]string{
		"https://music.apple.com/us/album/mark-on-me/6802917476?i=6802917479&uo=4": "6802917479",
		"https://music.apple.com/cn/album/x/1?uo=4&i=42":                           "42",
		"https://music.apple.com/us/album/mark-on-me/6802917476":                   "",
		"": "",
	} {
		if got := appleCatalogIDFromURL(in); got != want {
			t.Errorf("appleCatalogIDFromURL(%q) = %q, want %q", in, got, want)
		}
	}
}

// 这一拍没有播放器给的 ID(全量扫库、手动搜索)时取缓存条目里存的;两种都有时按 Spotify 取。
func TestMusixmatchTrackIDsFallBackToCache(t *testing.T) {
	const artist, title, album = "Someone", "Cached Song", "Album"
	savedCache := enrichCache
	t.Cleanup(func() { enrichCache = savedCache })
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{enrichKey(artist, title, album): {
		AppleURL: "https://music.apple.com/us/album/x/1?i=777", SpotifyTrackID: "4uLU6hMCjMI75M1A2tKUQC"}}
	enrichMu.Unlock()
	apple, spotify := musixmatchTrackIDsFor(artist, title, album)
	if apple != "777" || spotify != "4uLU6hMCjMI75M1A2tKUQC" {
		t.Fatalf("没有播放提示时应取缓存里的 ID: apple=%q spotify=%q", apple, spotify)
	}
	f := withMxmFake(t, func(action string, r *http.Request) string {
		if action == "macro.subtitles.get" {
			return mxmMacroFixture(t, "Cached Song", "Someone", 200, 0, 200)
		}
		return mxmTranslations(nil)
	})
	resolveMusixmatchLyric(withMusixmatchPlaybackIDs(context.Background(), apple, spotify), artist, title, 200, "", "")
	if got := f.called("macro.subtitles.get"); len(got) != 1 || !strings.Contains(got[0], "track_spotify_id=4uLU6hMCjMI75M1A2tKUQC") || strings.Contains(got[0], "track_itunes_id") {
		t.Errorf("两种 ID 都有时应按 Spotify 取: %v", got)
	}
}

// 手动搜索把查询词统一成简体,缓存 key 里留着繁体专辑名:精确 key 查不到时按宽松 key 找回同一条。
func TestMusixmatchCachedTrackIDsLooseKey(t *testing.T) {
	savedCache := enrichCache
	t.Cleanup(func() { enrichCache = savedCache })
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{enrichKey("李荣浩", "落俗", "李榮浩"): {AppleURL: "https://music.apple.com/cn/album/x/1?i=935654982"}}
	enrichMu.Unlock()
	if apple, _ := musixmatchCachedTrackIDs("李荣浩", "落俗", "李荣浩"); apple != "935654982" {
		t.Errorf("繁简不同的 key 应按宽松 key 找到, got %q", apple)
	}
}

func mxmRichsyncLines(texts ...[]string) []musixmatchRichsyncLine {
	var out []musixmatchRichsyncLine
	for i, words := range texts {
		l := musixmatchRichsyncLine{Ts: float64(10 * i), Te: float64(10*i + 5)}
		for j, w := range words {
			l.L = append(l.L, musixmatchRichsyncWord{C: w, O: float64(j) * 0.3})
		}
		out = append(out, l)
	}
	return out
}

// 整行一个词的(行级时间伪装成逐字)丢掉;正常逐词、本来就只有一个短词的行、一半行成句的混合情况都保留。
func TestMusixmatchRichsyncIsLineLevel(t *testing.T) {
	whole := mxmRichsyncLines([]string{"你一手拿着苹果一手拿着命运"}, []string{"在寻找你自己的香"}, []string{"窗外的人们匆匆忙忙"},
		[]string{"把眼光丢在潮湿的路上"}, []string{"你的舞步划过空空的房间"}, []string{"时光就变成了烟"})
	if !musixmatchRichsyncIsLineLevel(whole) {
		t.Error("整行一个词的应判成只有行级时间")
	}
	raw, _ := json.Marshal(whole)
	if got := musixmatchRichsyncBodyToYRC(string(raw)); got != "" {
		t.Errorf("行级的 richsync 不该转出 YRC: %q", got)
	}
	words := mxmRichsyncLines([]string{"I'm", " ", "a", " ", "crack"}, []string{"in", " ", "the", " ", "pavement"}, []string{"I'm", " ", "afraid"},
		[]string{"that", " ", "my", " ", "fortress"}, []string{"is", " ", "a", " ", "glass", " ", "box"}, []string{"Yeah"})
	short := mxmRichsyncLines([]string{"Yeah"}, []string{"Oh"}, []string{"Yeah"}, []string{"Hey"}, []string{"Oh"}, []string{"Yeah"})
	mixed := mxmRichsyncLines([]string{"二人だけの空が広がる夜に"}, []string{"さよなら", "だけだった"}, []string{"その一言で全てが分かった"},
		[]string{"日が沈み出した", "空と君の姿"}, []string{"フェンス越しに重なっていた"}, []string{"初めて会った日から", "僕の心の全てを"})
	for name, lines := range map[string][]musixmatchRichsyncLine{"逐词": words, "短单词行": short, "一半成句": mixed} {
		if musixmatchRichsyncIsLineLevel(lines) {
			t.Errorf("%s 不该判成行级", name)
		}
	}
	if musixmatchRichsyncIsLineLevel(whole[:4]) {
		t.Error("不到 5 行有字的不判")
	}
}
