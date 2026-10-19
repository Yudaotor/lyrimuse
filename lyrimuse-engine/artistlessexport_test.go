package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 播放器不报歌手的歌(key 没有歌手)照常导出歌词文件、导得回来;没有歌名的残缺 key 照旧不导出。见 11 章决策 138。
func TestArtistlessKeyRoundTripsThroughLyricsFiles(t *testing.T) {
	key := "|Love Song|"
	broken := "歌手||专辑"
	dir := withExportFixture(t, map[string]enrichEntry{
		key:    {Lyrics: bt("[00:01.00]原文"), LyricsSource: "netease", ManualLyrics: true},
		broken: {Lyrics: bt("[00:01.00]残缺")},
	})
	exportLyricsFiles()
	path := filepath.Join(dir, sanitizeLyricsFilename(key)+".lrc")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("没有歌手的 key 也要导出: %v", err)
	}
	p := parseLyricsBytes(data)
	if !p.ok || p.artist != "" || p.title != "Love Song" || !p.manual || p.body != "[00:01.00]原文" {
		t.Fatalf("导出的文件读回来要认得出: %+v", p)
	}
	if _, err := os.Stat(filepath.Join(dir, sanitizeLyricsFilename(broken)+".lrc")); !os.IsNotExist(err) {
		t.Fatal("没有歌名的 key 不导出")
	}
	if err := os.WriteFile(path, []byte(strings.Replace(string(data), "原文", "改过", 1)), 0o644); err != nil {
		t.Fatal(err)
	}
	importLyricsFrom(dir, false)
	enrichMu.Lock()
	got := enrichCache[key]
	_, stray := enrichCache["||"]
	enrichMu.Unlock()
	if !got.Lyrics.EqualString("[00:01.00]改过") {
		t.Fatalf("文件里改的要导回同一条: %q", got.Lyrics)
	}
	if stray {
		t.Fatal("不该导出 || 这种空身份")
	}
}

// 歌名为空的头部照旧不算有效(酷狗原文自带的空 ID 标签行那一类)。
func TestLyricsHeaderNeedsTitle(t *testing.T) {
	if p := parseLyricsBytes([]byte("[ar:歌手]\n[ti:]\n[al:]\n\n[00:01.00]词")); p.ok {
		t.Fatalf("歌名为空不算有效头部: %+v", p)
	}
	if p := parseLyricsBytes([]byte("[ar:]\n[ti:歌名]\n[al:]\n\n[00:01.00]词")); !p.ok {
		t.Fatalf("歌手为空、歌名在,算有效头部: %+v", p)
	}
}
