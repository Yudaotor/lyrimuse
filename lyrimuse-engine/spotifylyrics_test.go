package main

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const spotifyLyricsTestID = "64k13LiYgEIymYEZpqv6ch"

// spotifySimpleCacheEntry 按 Simple Cache 的形状拼一个条目文件:24 字节文件头 + key + 响应体。
func spotifySimpleCacheEntry(key string, body []byte) []byte {
	var b bytes.Buffer
	head := make([]byte, 24)
	binary.LittleEndian.PutUint64(head[0:8], spotifySimpleCacheMagic)
	binary.LittleEndian.PutUint32(head[8:12], 5)
	binary.LittleEndian.PutUint32(head[12:16], uint32(len(key)))
	b.Write(head)
	b.WriteString(key)
	b.Write(body)
	b.Write([]byte{0xd8, 0x41, 0x0d, 0x97, 0x45, 0x6f, 0xfa, 0xf4}) // 流末尾的 EOF 记录,解析时要被忽略
	return b.Bytes()
}

func spotifyLyricsKey(id string) string {
	return "1/0/_dk_https://spotify.com https://spotify.com https://spclient.wg.spotify.com/color-lyrics/v2/track/" + id +
		"/image/spotify%3Aimage%3Aab67616d0000b273?format=json&vocalRemoval=false&market=from_token"
}

func gzipBytes(t *testing.T, s string) []byte {
	t.Helper()
	var b bytes.Buffer
	zw := gzip.NewWriter(&b)
	if _, err := zw.Write([]byte(s)); err != nil {
		t.Fatal(err)
	}
	zw.Close()
	return b.Bytes()
}

const spotifyLyricsTestJSON = `{"lyrics":{"syncType":"LINE_SYNCED","lines":[` +
	`{"startTimeMs":"14980","words":"First line","syllables":[],"endTimeMs":"0"},` +
	`{"startTimeMs":"20500","words":"♪","syllables":[],"endTimeMs":"0"},` +
	`{"startTimeMs":"61230","words":"Second line","syllables":[],"endTimeMs":"0"},` +
	`{"startTimeMs":"125004","words":"Third line","syllables":[],"endTimeMs":"0"}],` +
	`"provider":"MusixMatch","language":"en"},"colors":{"background":-1}}`

func useSpotifyLyricsCacheDir(t *testing.T, dir string) {
	t.Helper()
	old := spotifyLyricsCacheDirOverride
	spotifyLyricsCacheDirOverride = dir
	spotifyLyricsMu.Lock()
	spotifyLyricsDir = ""
	spotifyLyricsMu.Unlock()
	parserDriftMu.Lock()
	delete(parserDrift, spotifyLyricsParserName)
	parserDriftMu.Unlock()
	t.Cleanup(func() {
		spotifyLyricsCacheDirOverride = old
		spotifyLyricsMu.Lock()
		spotifyLyricsDir = ""
		spotifyLyricsMu.Unlock()
		parserDriftMu.Lock()
		delete(parserDrift, spotifyLyricsParserName)
		parserDriftMu.Unlock()
	})
}

func TestSpotifyColorLyricsLRC(t *testing.T) {
	lrc, recognized, ok := spotifyColorLyricsLRC([]byte(spotifyLyricsTestJSON))
	if !recognized || !ok {
		t.Fatalf("recognized=%v ok=%v", recognized, ok)
	}
	want := "[00:14.98]First line\n[00:20.50]\n[01:01.23]Second line\n[02:05.00]Third line\n"
	if lrc != want {
		t.Errorf("lrc =\n%s\nwant\n%s", lrc, want)
	}
	if _, recognized, ok := spotifyColorLyricsLRC([]byte(`{"lyrics":{"syncType":"UNSYNCED","lines":[]}}`)); !recognized || ok {
		t.Errorf("没有时间轴的应答: recognized=%v ok=%v, want 认得但不用", recognized, ok)
	}
	if _, recognized, _ := spotifyColorLyricsLRC([]byte(`{"text":{"rows":[]}}`)); recognized {
		t.Error("没有 lyrics 对象应算认不出")
	}
}

func TestSpotifyLyricsBodyGzipAndPlain(t *testing.T) {
	key := spotifyLyricsKey(spotifyLyricsTestID)
	for name, body := range map[string][]byte{
		"gzip":  gzipBytes(t, spotifyLyricsTestJSON),
		"plain": []byte(spotifyLyricsTestJSON),
	} {
		got, ok := spotifyLyricsBody(spotifySimpleCacheEntry(key, body))
		if !ok || !strings.Contains(string(got), `"MusixMatch"`) {
			t.Errorf("%s: ok=%v body=%.60q", name, ok, got)
		}
	}
	if _, ok := spotifyLyricsBody(spotifySimpleCacheEntry(key, []byte{0xce, 0xb2, 0xcf})); ok {
		t.Error("认不出的编码(比如 br)不该当成有")
	}
	if _, ok := spotifyLyricsBody([]byte("not a cache entry at all, just bytes........")); ok {
		t.Error("不是 Simple Cache 文件头不该认")
	}
}

// 按文件头建索引:只认歌词接口的条目,同一首有多份取最新的;文件删掉之后索引跟着拿掉。
func TestSpotifyLocalLyricsFromCacheDir(t *testing.T) {
	dir := t.TempDir()
	useSpotifyLyricsCacheDir(t, dir)
	write := func(name string, data []byte) {
		if err := os.WriteFile(filepath.Join(dir, name), data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write("aaaaaaaaaaaaaaaa_0", spotifySimpleCacheEntry(spotifyLyricsKey(spotifyLyricsTestID), gzipBytes(t, spotifyLyricsTestJSON)))
	write("bbbbbbbbbbbbbbbb_0", spotifySimpleCacheEntry("1/0/_dk_https://spotify.com https://spotify.com https://i.scdn.co/image/x", []byte("img")))
	write("cccccccccccccccc_1", []byte("stream 2 file"))

	lrc, ok := spotifyLocalLyricsByTrackID(spotifyLyricsTestID)
	if !ok || !strings.HasPrefix(lrc, "[00:14.98]First line") {
		t.Fatalf("ok=%v lrc=%q", ok, lrc)
	}
	if _, ok := spotifyLocalLyricsByTrackID("0000000000000000000000"); ok {
		t.Error("缓存里没有的曲目不该有")
	}

	os.Remove(filepath.Join(dir, "aaaaaaaaaaaaaaaa_0"))
	spotifyLyricsMu.Lock()
	spotifyLyricsScannedAt = spotifyLyricsScannedAt.Add(-spotifyLyricsRescanMin)
	spotifyLyricsMu.Unlock()
	if _, ok := spotifyLocalLyricsByTrackID(spotifyLyricsTestID); ok {
		t.Error("文件没了之后不该还在索引里")
	}
}

// 读到的文件头全都不是 Simple Cache 的格式,记进认不出计数。
func TestSpotifyLyricsCacheFormatChangeCountsAsDrift(t *testing.T) {
	dir := t.TempDir()
	useSpotifyLyricsCacheDir(t, dir)
	if err := os.WriteFile(filepath.Join(dir, "dddddddddddddddd_0"), bytes.Repeat([]byte{1}, 64), 0o600); err != nil {
		t.Fatal(err)
	}
	spotifyLocalLyricsByTrackID(spotifyLyricsTestID)
	parserDriftMu.Lock()
	e := parserDrift[spotifyLyricsParserName]
	parserDriftMu.Unlock()
	if e == nil || e.Streak != 1 {
		t.Fatalf("认不出计数 = %+v, want 1", e)
	}
}

func TestSpotifyLyricsWorthRecheck(t *testing.T) {
	base := enrichEntry{LyricsSourcesSeen: []string{"netease", "lrclib"}}
	if !spotifyLyricsWorthRecheck(base, spotifyBundleID, false, true, true) {
		t.Fatal("Musixmatch 没给出、Spotify 缓存里有,应补一次")
	}
	withMxm := base
	withMxm.LyricsSourcesSeen = append([]string{"musixmatch"}, base.LyricsSourcesSeen...)
	cases := map[string]bool{
		"Musixmatch 给出过":    spotifyLyricsWorthRecheck(withMxm, spotifyBundleID, false, true, true),
		"缓存里没有":             spotifyLyricsWorthRecheck(base, spotifyBundleID, false, true, false),
		"不是在用 Spotify 放":    spotifyLyricsWorthRecheck(base, appleMusicBundleID, false, true, true),
		"钉住了":               spotifyLyricsWorthRecheck(base, spotifyBundleID, true, true, true),
		"关了自动升级":            spotifyLyricsWorthRecheck(base, spotifyBundleID, false, false, true),
		"已经见过 Spotify 本地歌词": spotifyLyricsWorthRecheck(enrichEntry{LyricsSourcesResponded: []string{spotifyLocalLyricsSource}}, spotifyBundleID, false, true, true),
	}
	for name, got := range cases {
		if got {
			t.Errorf("%s: 不该补", name)
		}
	}
}

// 索引落盘:新进程读回来,比水位旧的文件不再读文件头;比它新的照常补进来。
func TestSpotifyLyricsIndexPersists(t *testing.T) {
	dir := t.TempDir()
	useSpotifyLyricsCacheDir(t, dir)
	oldPath := spotifyLyricsIndexPathOverride
	spotifyLyricsIndexPathOverride = filepath.Join(t.TempDir(), "index.json")
	t.Cleanup(func() { spotifyLyricsIndexPathOverride = oldPath })
	resetMemory := func() {
		spotifyLyricsMu.Lock()
		spotifyLyricsDir = ""
		spotifyLyricsMu.Unlock()
	}
	oldTime := time.Now().Add(-time.Hour)
	first := filepath.Join(dir, "aaaaaaaaaaaaaaaa_0")
	if err := os.WriteFile(first, spotifySimpleCacheEntry(spotifyLyricsKey(spotifyLyricsTestID), gzipBytes(t, spotifyLyricsTestJSON)), 0o600); err != nil {
		t.Fatal(err)
	}
	os.Chtimes(first, oldTime, oldTime)
	noLyrics := filepath.Join(dir, "bbbbbbbbbbbbbbbb_0")
	if err := os.WriteFile(noLyrics, spotifySimpleCacheEntry("1/0/_dk_https://spotify.com https://spotify.com https://i.scdn.co/image/x", []byte("img")), 0o600); err != nil {
		t.Fatal(err)
	}
	os.Chtimes(noLyrics, oldTime, oldTime)
	if _, ok := spotifyLyricsFileFor(spotifyLyricsTestID); !ok {
		t.Fatal("第一次扫应建出索引")
	}

	// 「新进程」:比水位旧的那个没有歌词的文件,就算现在改成了歌词条目也不会被读。
	resetMemory()
	const otherID = "11111111111111111111aa"
	if err := os.WriteFile(noLyrics, spotifySimpleCacheEntry(spotifyLyricsKey(otherID), gzipBytes(t, spotifyLyricsTestJSON)), 0o600); err != nil {
		t.Fatal(err)
	}
	os.Chtimes(noLyrics, oldTime, oldTime)
	fresh := filepath.Join(dir, "cccccccccccccccc_0")
	const freshID = "22222222222222222222bb"
	if err := os.WriteFile(fresh, spotifySimpleCacheEntry(spotifyLyricsKey(freshID), gzipBytes(t, spotifyLyricsTestJSON)), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, ok := spotifyLyricsFileFor(spotifyLyricsTestID); !ok {
		t.Error("读回来的索引里应该还有第一首")
	}
	if _, ok := spotifyLyricsFileFor(otherID); ok {
		t.Error("比水位旧的文件不该再读文件头")
	}
	if _, ok := spotifyLyricsFileFor(freshID); !ok {
		t.Error("比水位新的文件应补进索引")
	}
}
