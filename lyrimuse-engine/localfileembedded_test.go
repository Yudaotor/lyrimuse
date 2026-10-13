package main

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// id3Frame 拼一帧:v2.3 用普通大端长度,v2.4 用同步安全整数。
func id3Frame(version byte, id string, body []byte) []byte {
	head := make([]byte, 10)
	copy(head, id)
	if version == 4 {
		n := len(body)
		head[4], head[5], head[6], head[7] = byte(n>>21&0x7F), byte(n>>14&0x7F), byte(n>>7&0x7F), byte(n&0x7F)
	} else {
		binary.BigEndian.PutUint32(head[4:8], uint32(len(body)))
	}
	return append(head, body...)
}

func id3Tag(version byte, frames ...[]byte) []byte {
	var tag []byte
	for _, f := range frames {
		tag = append(tag, f...)
	}
	n := len(tag)
	header := []byte{'I', 'D', '3', version, 0, 0, byte(n >> 21 & 0x7F), byte(n >> 14 & 0x7F), byte(n >> 7 & 0x7F), byte(n & 0x7F)}
	return append(header, tag...)
}

func usltBody(enc byte, text []byte) []byte {
	body := []byte{enc, 'c', 'h', 'i', 0}
	return append(body, text...)
}

func TestEmbeddedLyricsUSLT(t *testing.T) {
	lrc := "[00:01.00]稻香\n[00:05.20]对这个世界如果你有太多的抱怨\n"
	tag := id3Tag(3, id3Frame(3, "TIT2", []byte{3, 'x'}), id3Frame(3, "USLT", usltBody(3, []byte(lrc))))
	got, ok := embeddedLyricsFromID3(tag[:10], tag[10:])
	if !ok || got != lrc {
		t.Fatalf("UTF-8 的 USLT 写着 LRC:得到 %q, ok=%v", got, ok)
	}
	// 标成 Latin-1、实际是 GBK 的(「稻香」B5BE CFE3)。
	gbk := append([]byte("[00:01.00]"), 0xB5, 0xBE, 0xCF, 0xE3)
	tag = id3Tag(4, id3Frame(4, "USLT", usltBody(0, gbk)))
	if got, ok := embeddedLyricsFromID3(tag[:10], tag[10:]); !ok || got != "[00:01.00]稻香" {
		t.Errorf("GBK 写在 Latin-1 档里的 USLT:得到 %q, ok=%v", got, ok)
	}
	plain := id3Tag(3, id3Frame(3, "USLT", usltBody(3, []byte("稻香\n对这个世界\n"))))
	if _, ok := embeddedLyricsFromID3(plain[:10], plain[10:]); ok {
		t.Error("没有时间标签的 USLT 不该收")
	}
}

func TestEmbeddedLyricsSYLT(t *testing.T) {
	// UTF-16(带 BOM)、毫秒时间。
	utf16le := func(s string) []byte {
		out := []byte{0xFF, 0xFE}
		for _, r := range s {
			out = append(out, byte(r), byte(r>>8))
		}
		return append(out, 0, 0)
	}
	body := []byte{1, 'c', 'h', 'i', 2, 1}
	body = append(body, utf16le("")...)
	for _, line := range []struct {
		text string
		ms   uint32
	}{{"第一句", 1000}, {"第二句", 65230}} {
		body = append(body, utf16le(line.text)...)
		body = binary.BigEndian.AppendUint32(body, line.ms)
	}
	tag := id3Tag(3, id3Frame(3, "SYLT", body))
	got, ok := embeddedLyricsFromID3(tag[:10], tag[10:])
	want := "[00:01.00]第一句\n[01:05.23]第二句\n"
	if !ok || got != want {
		t.Fatalf("SYLT 换成 LRC:得到 %q,想要 %q", got, want)
	}
}

func TestLocalFileLyricsFallsBackToEmbedded(t *testing.T) {
	dir := t.TempDir()
	audio := filepath.Join(dir, "Song.mp3")
	tag := id3Tag(3, id3Frame(3, "USLT", usltBody(3, []byte("[00:01.00]embedded line\r\n"))))
	if err := os.WriteFile(audio, append(tag, 0xFF, 0xFB), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { noteLocalFileCurrentTrack("", "", "", "") })
	noteLocalFileCurrentTrack(reampBundleID, "A", "Song", audio)
	got, ok := localFileLyrics("A", "Song")
	if !ok || !strings.Contains(got, "embedded line") || strings.Contains(got, "\r") {
		t.Fatalf("没有同名 .lrc 时退到内嵌歌词:得到 %q, ok=%v", got, ok)
	}
	if err := os.WriteFile(filepath.Join(dir, "Song.lrc"), []byte("[00:02.00]sidecar line\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got, _ := localFileLyrics("A", "Song"); !strings.Contains(got, "sidecar line") {
		t.Errorf("同名 .lrc 优先于内嵌:得到 %q", got)
	}
}
