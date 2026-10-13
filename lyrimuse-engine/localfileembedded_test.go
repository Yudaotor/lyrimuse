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
	if got, ok := embeddedLyricsFromID3(plain[:10], plain[10:]); !ok || got != "稻香\n对这个世界\n" {
		t.Errorf("只有不带时间的 USLT 时交它(当纯文本):得到 %q, ok=%v", got, ok)
	}
	for _, order := range [][2]string{{"纯文字", lrc}, {lrc, "纯文字"}} {
		both := id3Tag(3, id3Frame(3, "USLT", usltBody(3, []byte(order[0]))), id3Frame(3, "USLT", usltBody(3, []byte(order[1]))))
		if got, ok := embeddedLyricsFromID3(both[:10], both[10:]); !ok || got != lrc {
			t.Errorf("带时间的排在不带时间的前面(帧顺序 %q 在先):得到 %q, ok=%v", order[0], got, ok)
		}
	}
	blank := id3Tag(3, id3Frame(3, "USLT", usltBody(3, []byte(" \n"))))
	if _, ok := embeddedLyricsFromID3(blank[:10], blank[10:]); ok {
		t.Error("只有空白的 USLT 不算")
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

func TestLocalFileLyricsPlainTextOnly(t *testing.T) {
	dir := t.TempDir()
	audio := filepath.Join(dir, "Plain.mp3")
	tag := id3Tag(3, id3Frame(3, "USLT", usltBody(3, []byte("first line\r\nsecond line"))))
	if err := os.WriteFile(audio, append(tag, 0xFF, 0xFB), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { noteLocalFileCurrentTrack("", "", "", "") })
	noteLocalFileCurrentTrack(reampBundleID, "A", "Plain", audio)
	setNativeLyricSourcesForPlayer(reampBundleID)
	t.Cleanup(func() { setNativeLyricSourcesForPlayer("") })
	r, ok := localFileLyricsFor("A", "Plain", 200)
	if !ok || !r.plainOnly || r.lyr != "first line\nsecond line" {
		t.Fatalf("文件里只有不带时间的歌词:交成纯文本,得到 %+v ok=%v", r, ok)
	}
	if localFileLyricsAvailable(reampBundleID, "A", "Plain") {
		t.Error("只有纯文本时不算「有本地歌词」(不为它重来一轮)")
	}
}

func vorbisComment(fields ...string) []byte {
	le := func(n int) []byte { return binary.LittleEndian.AppendUint32(nil, uint32(n)) }
	out := append(le(6), "vendor"...)
	out = append(out, le(len(fields))...)
	for _, f := range fields {
		out = append(append(out, le(len(f))...), f...)
	}
	return out
}

func writeTemp(t *testing.T, name string, data []byte) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, data, 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

const embeddedLRC = "[00:01.00]稻香\n[00:05.20]对这个世界如果你有太多的抱怨"

func TestEmbeddedLyricsFLAC(t *testing.T) {
	block := func(kind byte, last bool, body []byte) []byte {
		if last {
			kind |= 0x80
		}
		return append([]byte{kind, byte(len(body) >> 16), byte(len(body) >> 8), byte(len(body))}, body...)
	}
	data := append([]byte("fLaC"), block(0, false, make([]byte, 34))...)
	data = append(data, block(6, false, make([]byte, 100))...)
	data = append(data, block(4, true, vorbisComment("TITLE=稻香", "lyrics="+embeddedLRC))...)
	if got, ok := localFileEmbeddedLyrics(writeTemp(t, "a.flac", data)); !ok || got != embeddedLRC {
		t.Fatalf("FLAC 的 VORBIS_COMMENT(图片块跳过、键不分大小写):得到 %q, ok=%v", got, ok)
	}
	plain := append([]byte("fLaC"), block(4, true, vorbisComment("LYRICS=只有文字"))...)
	if got, ok := localFileEmbeddedLyrics(writeTemp(t, "b.flac", plain)); !ok || got != "只有文字" {
		t.Errorf("FLAC 里只有不带时间的歌词时交它(当纯文本):得到 %q, ok=%v", got, ok)
	}
	both := append([]byte("fLaC"), block(4, true, vorbisComment("UNSYNCEDLYRICS=只有文字", "LYRICS="+embeddedLRC))...)
	if got, ok := localFileEmbeddedLyrics(writeTemp(t, "c.flac", both)); !ok || got != embeddedLRC {
		t.Errorf("FLAC 里带时间的排在不带时间的前面:得到 %q, ok=%v", got, ok)
	}
}

func TestEmbeddedLyricsOgg(t *testing.T) {
	page := func(packets ...[]byte) []byte {
		var segs, body []byte
		for _, p := range packets {
			n := len(p)
			for n >= 255 {
				segs = append(segs, 255)
				n -= 255
			}
			segs = append(segs, byte(n))
			body = append(body, p...)
		}
		h := make([]byte, 27)
		copy(h, "OggS")
		h[26] = byte(len(segs))
		return append(append(h, segs...), body...)
	}
	tags := append([]byte("OpusTags"), vorbisComment("UNSYNCEDLYRICS="+embeddedLRC)...)
	for len(tags) < 300 {
		tags = append(tags, 0)
	}
	data := append(page([]byte("OpusHead........")), page(tags)...)
	if got, ok := localFileEmbeddedLyrics(writeTemp(t, "a.opus", data)); !ok || got != embeddedLRC {
		t.Fatalf("Opus 的 OpusTags(包长过 255、分段拼回):得到 %q, ok=%v", got, ok)
	}
	vorbis := append(page(append([]byte("\x01vorbis"), make([]byte, 23)...)),
		page(append([]byte("\x03vorbis"), vorbisComment("LYRICS="+embeddedLRC)...))...)
	if got, ok := localFileEmbeddedLyrics(writeTemp(t, "a.ogg", vorbis)); !ok || got != embeddedLRC {
		t.Fatalf("OGG Vorbis 的注释头:得到 %q, ok=%v", got, ok)
	}
}

func TestEmbeddedLyricsMP4(t *testing.T) {
	atom := func(kind string, body ...[]byte) []byte {
		var b []byte
		for _, x := range body {
			b = append(b, x...)
		}
		return append(append(binary.BigEndian.AppendUint32(nil, uint32(8+len(b))), kind...), b...)
	}
	lyr := atom("\xa9lyr", atom("data", []byte{0, 0, 0, 1, 0, 0, 0, 0}, []byte(embeddedLRC)))
	moov := atom("moov", atom("mvhd", make([]byte, 100)), atom("udta", atom("meta", []byte{0, 0, 0, 0}, atom("hdlr", make([]byte, 25)),
		atom("ilst", atom("\xa9nam", atom("data", []byte{0, 0, 0, 1, 0, 0, 0, 0}, []byte("稻香"))), lyr))))
	data := append(append(atom("ftyp", []byte("M4A \x00\x00\x00\x00")), atom("mdat", make([]byte, 4096))...), moov...)
	if got, ok := localFileEmbeddedLyrics(writeTemp(t, "a.m4a", data)); !ok || got != embeddedLRC {
		t.Fatalf("M4A 的 ©lyr(moov 在 mdat 后面):得到 %q, ok=%v", got, ok)
	}
	plain := atom("moov", atom("udta", atom("meta", []byte{0, 0, 0, 0},
		atom("ilst", atom("\xa9lyr", atom("data", []byte{0, 0, 0, 1, 0, 0, 0, 0}, []byte("喜歡那深夜的安靜\r和我約定")))))))
	if got, ok := localFileEmbeddedLyrics(writeTemp(t, "b.m4a", plain)); !ok || got != "喜歡那深夜的安靜\r和我約定" {
		t.Errorf("M4A 的 ©lyr 只有不带时间的歌词时交它(当纯文本):得到 %q, ok=%v", got, ok)
	}
}

func TestEmbeddedLyricsChunkedID3(t *testing.T) {
	tag := id3Tag(3, id3Frame(3, "USLT", usltBody(3, []byte(embeddedLRC))))
	be := func(n int) []byte { return binary.BigEndian.AppendUint32(nil, uint32(n)) }
	le := func(n int) []byte { return binary.LittleEndian.AppendUint32(nil, uint32(n)) }
	aiff := append(append([]byte("FORM"), be(0)...), "AIFF"...)
	aiff = append(append(append(aiff, "COMM"...), be(18)...), make([]byte, 18)...)
	aiff = append(append(append(aiff, "ID3 "...), be(len(tag))...), tag...)
	if got, ok := localFileEmbeddedLyrics(writeTemp(t, "a.aiff", aiff)); !ok || got != embeddedLRC {
		t.Fatalf("AIFF 的 ID3 块:得到 %q, ok=%v", got, ok)
	}
	wav := append(append([]byte("RIFF"), le(0)...), "WAVE"...)
	wav = append(append(append(wav, "fmt "...), le(17)...), make([]byte, 18)...)
	wav = append(append(append(wav, "id3 "...), le(len(tag))...), tag...)
	if got, ok := localFileEmbeddedLyrics(writeTemp(t, "a.wav", wav)); !ok || got != embeddedLRC {
		t.Fatalf("WAV 的 id3 块(奇数长度的块补一字节):得到 %q, ok=%v", got, ok)
	}
}

func TestEmbeddedLyricsTXXX(t *testing.T) {
	utf16 := func(s string) []byte {
		out := []byte{0xFF, 0xFE}
		for _, r := range s {
			out = append(out, byte(r), byte(r>>8))
		}
		return out
	}
	body := append([]byte{1}, utf16("USLT")...)
	body = append(append(body, 0, 0), utf16(embeddedLRC)...)
	tag := id3Tag(3, id3Frame(3, "TXXX", body))
	if got, ok := embeddedLyricsFromID3(tag[:10], tag[10:]); !ok || got != embeddedLRC {
		t.Fatalf("描述叫 USLT 的 TXXX(ffmpeg 就这么写):得到 %q, ok=%v", got, ok)
	}
	other := append(append([]byte{3}, "comment\x00"...), embeddedLRC...)
	tag = id3Tag(3, id3Frame(3, "TXXX", other))
	if _, ok := embeddedLyricsFromID3(tag[:10], tag[10:]); ok {
		t.Error("别的描述的 TXXX 不当歌词")
	}
}
