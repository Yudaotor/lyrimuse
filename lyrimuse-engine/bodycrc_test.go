package main

import (
	"hash/crc32"
	"strings"
	"testing"
)

// 旧写法原样留在这里当对照:落盘文件里的 crc 必须跟以前算的逐位一致,否则存量正文小文件全被判成
// 「跟主缓存对不上」。
func enrichBodyCRCReference(e enrichEntry) uint32 {
	if e.Lyrics == "" && e.LyricsTr == "" && e.LyricsRoma == "" && e.LyricsYRC == "" && e.PlainLyrics == "" {
		return 0
	}
	h := crc32.NewIEEE()
	for _, s := range []string{e.Lyrics, e.LyricsTr, e.LyricsRoma, e.LyricsYRC, e.PlainLyrics} {
		h.Write([]byte(s))
		h.Write([]byte{0})
	}
	if c := h.Sum32(); c != 0 {
		return c
	}
	return 1
}

func TestEnrichBodyCRCMatchesReference(t *testing.T) {
	long := strings.Repeat("[00:01.00]一句很长的歌词 some words\n", 5000)
	for _, e := range []enrichEntry{
		{},
		{Lyrics: "a"},
		{Lyrics: "a", LyricsTr: "bc"},
		{Lyrics: "ab", LyricsTr: "c"},
		{PlainLyrics: "only plain"},
		{Lyrics: long, LyricsTr: long, LyricsRoma: "r", LyricsYRC: long, PlainLyrics: "p"},
		{LyricsYRC: "\x00\x00"},
	} {
		if got, want := enrichBodyCRC(e), enrichBodyCRCReference(e); got != want {
			t.Errorf("crc %08x, want %08x for %+v", got, want, e.PlainLyrics)
		}
	}
}

// 背景人声只在非空时接在五个字段后面算:有它时等于六个字段按同一规则算,跟没有它时不同。
func TestEnrichBodyCRCBackground(t *testing.T) {
	base := enrichEntry{Lyrics: "[00:01.00]What you doing?", LyricsYRC: "[1000,500](1000,500,0)What"}
	withBG := base
	withBG.LyricsBG = "[1000,500](1600,300,0)(What)"
	h := crc32.NewIEEE()
	for _, s := range []string{withBG.Lyrics, "", "", withBG.LyricsYRC, "", withBG.LyricsBG} {
		h.Write([]byte(s))
		h.Write([]byte{0})
	}
	if got := enrichBodyCRC(withBG); got != h.Sum32() {
		t.Errorf("crc(withBG) = %08x, want %08x", got, h.Sum32())
	}
	if enrichBodyCRC(withBG) == enrichBodyCRC(base) {
		t.Error("背景人声变了校验值没变")
	}
	if got := enrichBodyFields(withBG); got != 128|1|16|32 {
		t.Errorf("fields = %d", got)
	}
}

func TestEnrichBodyCRCDoesNotAllocate(t *testing.T) {
	e := enrichEntry{Lyrics: strings.Repeat("[00:01.00]歌词\n", 2000), LyricsTr: strings.Repeat("译", 3000),
		LyricsBG: strings.Repeat("[1000,500](1600,300,0)(oh)\n", 200)}
	enrichBodyCRC(e) // 预热缓冲区
	if n := testing.AllocsPerRun(50, func() { enrichBodyCRC(e) }); n > 0.5 {
		t.Errorf("每次分配 %.1f 次,缓冲区没复用上", n)
	}
}
