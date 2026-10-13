package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLocalFileLyricsName(t *testing.T) {
	entries := []string{"Sold Out.mp3", "Sold Out.LRC", "Other.lrc", "sold out.lrc"}
	if got := localFileLyricsName("Sold Out.mp3", entries); got != "Sold Out.LRC" {
		t.Errorf("同名 .lrc(扩展名不分大小写)应取 Sold Out.LRC,得到 %q", got)
	}
	if got := localFileLyricsName("Missing.mp3", entries); got != "" {
		t.Errorf("没有同名的不该取别首的,得到 %q", got)
	}
}

func TestDecodeLocalLyricsFile(t *testing.T) {
	lrc := "[00:01.00]稻香\n[00:05.20]对这个世界如果你有太多的抱怨\n"
	cases := []struct {
		name string
		data []byte
		ok   bool
	}{
		{"UTF-8", []byte(lrc), true},
		{"UTF-8 带 BOM", append([]byte{0xEF, 0xBB, 0xBF}, lrc...), true},
		{"UTF-16LE", utf16LE(lrc), true},
		// 「稻香」的 GBK:B5BE CFE3。
		{"GBK", append([]byte("[00:01.00]"), 0xB5, 0xBE, 0xCF, 0xE3, '\n'), true},
		{"没有时间标签", []byte("稻香\n对这个世界\n"), false},
	}
	for _, c := range cases {
		got, ok := decodeLocalLyricsFile(c.data)
		if ok != c.ok {
			t.Errorf("%s: ok=%v,想要 %v", c.name, ok, c.ok)
			continue
		}
		if ok && !localFileLRCTimestamp.MatchString(got) {
			t.Errorf("%s: 解出来没有时间标签: %q", c.name, got)
		}
		if ok && c.name != "GBK" && got != lrc {
			t.Errorf("%s: 解出来 %q,想要 %q", c.name, got, lrc)
		}
		if ok && c.name == "GBK" && got != "[00:01.00]稻香\n" {
			t.Errorf("GBK: 解出来 %q", got)
		}
	}
}

func utf16LE(s string) []byte {
	out := []byte{0xFF, 0xFE}
	for _, r := range s {
		if r > 0xFFFF {
			continue
		}
		out = append(out, byte(r), byte(r>>8))
	}
	return out
}

func TestLocalFileLyricsOnlyForCurrentTrack(t *testing.T) {
	dir := t.TempDir()
	audio := filepath.Join(dir, "Sold Out.mp3")
	if err := os.WriteFile(audio, []byte{0}, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "Sold Out.lrc"), []byte("[00:01.00]I'm sold out\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { noteLocalFileCurrentTrack("", "", "", "") })

	noteLocalFileCurrentTrack(reampBundleID, "Hawk Nelson", "Sold Out", audio)
	if _, ok := localFileLyrics("hawk nelson", "sold out"); !ok {
		t.Error("正在放的这首(大小写不同)应读到同名 .lrc")
	}
	if _, ok := localFileLyrics("Hawk Nelson", "Diamonds"); ok {
		t.Error("别的歌(预解析的下一首)不该读到这首的 .lrc")
	}
	noteLocalFileCurrentTrack(kkboxBundleID, "Hawk Nelson", "Sold Out", audio)
	if _, ok := localFileLyrics("Hawk Nelson", "Sold Out"); ok {
		t.Error("只对 reAMP 记当前文件")
	}
}

func TestLocalFileLyricsWorthRecheck(t *testing.T) {
	e := enrichEntry{LyricsSource: "qq"}
	if !localFileLyricsWorthRecheck(e, reampBundleID, false, true, true) {
		t.Error("正用 reAMP 放、有同名 .lrc、条目没见过这份 → 值得重来一次")
	}
	if localFileLyricsWorthRecheck(e, kkboxBundleID, false, true, true) {
		t.Error("别的播放器不重来")
	}
	if localFileLyricsWorthRecheck(e, reampBundleID, true, true, true) {
		t.Error("用户钉住的不重来")
	}
	seen := enrichEntry{LyricsSource: "qq", LyricsSourcesSeen: []string{localFileLyricsSource}}
	if localFileLyricsWorthRecheck(seen, reampBundleID, false, true, true) {
		t.Error("已经带着这份比过的不重来")
	}
}
