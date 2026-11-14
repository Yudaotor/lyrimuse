package main

import (
	"bytes"
	"encoding/binary"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf16"
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

// embeddedLyricsFromID3:只看 tagsFromID3 里的歌词。
func embeddedLyricsFromID3(header, tag []byte) (string, bool) {
	t := tagsFromID3(header, tag)
	return t.lyrics, t.hasLyrics
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
	before := id3Tag(3, id3Frame(3, "USLT", usltBody(3, []byte(embeddedLRC))), id3Frame(3, "SYLT", body))
	if got, ok := embeddedLyricsFromID3(before[:10], before[10:]); !ok || got != want {
		t.Errorf("SYLT 压过排在它前面、写成 LRC 的 USLT:得到 %q", got)
	}
}

// 标成 Latin-1、实为 CP949 的韩文 SYLT:一行只有几个音节,单看一行认不出 EUC-KR,按整帧认。
func TestEmbeddedLyricsSYLTKoreanShortLines(t *testing.T) {
	body := []byte{0, 'k', 'o', 'r', 2, 1, 0}
	for _, line := range []struct {
		hex string
		ms  uint32
	}{
		{"bab8b0ed20bdcdb4d9", 1000},
		{"c0ccb7b8b0d420b8bbc7cfb4cfb1ee", 5000},
		{"b4f520bab8b0ed20bdcdb4d9", 9000},
		{"b3cac8f120bbe7c1f8c0bb", 13000},
	} {
		body = append(body, mustHex(t, line.hex)...)
		body = append(body, 0)
		body = binary.BigEndian.AppendUint32(body, line.ms)
	}
	tag := id3Tag(3, id3Frame(3, "SYLT", body))
	got, ok := embeddedLyricsFromID3(tag[:10], tag[10:])
	want := "[00:01.00]보고 싶다\n[00:05.00]이렇게 말하니까\n[00:09.00]더 보고 싶다\n[00:13.00]너희 사진을\n"
	if !ok || got != want {
		t.Fatalf("韩文 SYLT:得到 %q,想要 %q", got, want)
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

// 原子头里的长度是坏的(32 位长度 0、64 位长度比头还短或超出 int64)时不能让引擎崩:这条在轮询主循环里同步跑,没有 recover。
func TestEmbeddedLyricsMP4BadAtomSizes(t *testing.T) {
	be32 := func(n uint32) []byte { return binary.BigEndian.AppendUint32(nil, n) }
	be64 := func(n uint64) []byte { return binary.BigEndian.AppendUint64(nil, n) }
	atom := func(kind string, body ...[]byte) []byte {
		var b []byte
		for _, x := range body {
			b = append(b, x...)
		}
		return append(append(be32(uint32(8+len(b))), kind...), b...)
	}
	ilst := atom("udta", atom("meta", []byte{0, 0, 0, 0},
		atom("ilst", atom("\xa9lyr", atom("data", []byte{0, 0, 0, 1, 0, 0, 0, 0}, []byte(embeddedLRC))))))
	ftyp := atom("ftyp", []byte("M4A \x00\x00\x00\x00"))
	cases := []struct {
		name string
		data []byte
	}{
		{"moov 64 位长度 8(比头还短)", append(append(append([]byte{}, ftyp...), append(be32(1), "moov"...)...), be64(8)...)},
		{"moov 64 位长度 0", append(append(append([]byte{}, ftyp...), append(be32(1), "moov"...)...), be64(0)...)},
		{"moov 64 位长度超出 int64", append(append(append([]byte{}, ftyp...), append(be32(1), "moov"...)...), be64(1<<63|16)...)},
		{"moov 64 位长度全 1", append(append(append([]byte{}, ftyp...), append(be32(1), "moov"...)...), be64(^uint64(0))...)},
		{"mdat 64 位长度比头还短", append(append(append([]byte{}, ftyp...), append(be32(1), "mdat"...)...), be64(9)...)},
		{"mdat 64 位长度超出 int64", append(append(append([]byte{}, ftyp...), append(be32(1), "mdat"...)...), be64(^uint64(0)-3)...)},
		{"顶层原子 32 位长度 4", append(append([]byte{}, ftyp...), append(be32(4), "free"...)...)},
		{"moov 超过上限", append(append([]byte{}, ftyp...), append(be32(localFileEmbeddedMaxTagBytes+9), "moov"...)...)},
		{"moov 64 位长度超过上限", append(append(append([]byte{}, ftyp...), append(be32(1), "moov"...)...), be64(localFileEmbeddedMaxTagBytes+17)...)},
		{"moov 只有头", append(append([]byte{}, ftyp...), append(be32(8+64), "moov"...)...)},
	}
	for _, c := range cases {
		if got, ok := localFileEmbeddedLyrics(writeTemp(t, "bad.m4a", c.data)); ok {
			t.Errorf("%s:坏文件不该读出歌词,得到 %q", c.name, got)
		}
	}
	for _, n := range []uint64{0, 8, 15, 1 << 63, ^uint64(0)} {
		h := append(append(be32(1), "moov"...), be64(n)...)
		if _, size, err := mp4AtomHeader(bytes.NewReader(h)); err == nil {
			t.Errorf("64 位长度 %d 应当报错,得到长度 %d", n, size)
		}
	}

	// 32 位长度 0 = 一直到文件末尾:照样读得出,长度按实际剩下的算。
	toEOF := append(append(append([]byte{}, ftyp...), append(be32(0), "moov"...)...), ilst...)
	if got, ok := localFileEmbeddedLyrics(writeTemp(t, "eof.m4a", toEOF)); !ok || got != embeddedLRC {
		t.Errorf("moov 长度 0(到文件末尾):得到 %q, ok=%v", got, ok)
	}
	// 64 位长度写对的照样读得出。
	ext := append(append(append(append([]byte{}, ftyp...), append(be32(1), "moov"...)...), be64(uint64(16+len(ilst)))...), ilst...)
	if got, ok := localFileEmbeddedLyrics(writeTemp(t, "ext.m4a", ext)); !ok || got != embeddedLRC {
		t.Errorf("moov 64 位长度:得到 %q, ok=%v", got, ok)
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

// id3v22Frame 拼一帧 v2.2:3 字节帧名 + 3 字节大端长度,没有帧标志。
func id3v22Frame(id string, body []byte) []byte {
	n := len(body)
	return append([]byte{id[0], id[1], id[2], byte(n >> 16), byte(n >> 8), byte(n)}, body...)
}

// utf16BOM:带 BOM 的 UTF-16LE,末尾带两字节结束符。
func utf16BOM(s string) []byte {
	out := []byte{0xFF, 0xFE}
	for _, u := range utf16.Encode([]rune(s)) {
		out = append(out, byte(u), byte(u>>8))
	}
	return append(out, 0, 0)
}

// v2.2 的 ULT / SLT / TXX / COM 跟 v2.3 的 USLT / SYLT / TXXX / COMM 一样读;前面垫几帧别的,帧头长度算错就对不齐。
func TestEmbeddedLyricsID3v22(t *testing.T) {
	plain := "稻香\n对这个世界\n"
	lead := [][]byte{id3v22Frame("TT2", append([]byte{1}, utf16BOM("稻香")...)), id3v22Frame("TP1", []byte{0, 'J', 'a', 'y'})}
	ult := func(text string) []byte {
		// Apple Music 写的样子:带 BOM 的 UTF-16、语言 eng、空描述。
		return id3v22Frame("ULT", append(append([]byte{1, 'e', 'n', 'g'}, utf16BOM("")...), utf16BOM(text)...))
	}
	for _, c := range []struct {
		name, text string
	}{{"ULT 纯文本", plain}, {"ULT 写着 LRC", embeddedLRC}} {
		tag := id3Tag(2, append(append([][]byte{}, lead...), ult(c.text))...)
		if got, ok := embeddedLyricsFromID3(tag[:10], tag[10:]); !ok || got != c.text {
			t.Errorf("v2.2 %s:得到 %q, ok=%v", c.name, got, ok)
		}
	}

	slt := []byte{1, 'c', 'h', 'i', 2, 1}
	slt = append(slt, utf16BOM("")...)
	for _, line := range []struct {
		text string
		ms   uint32
	}{{"第一句", 1000}, {"第二句", 65230}} {
		slt = append(slt, utf16BOM(line.text)...)
		slt = binary.BigEndian.AppendUint32(slt, line.ms)
	}
	tag := id3Tag(2, append(append([][]byte{}, lead...), ult(plain), id3v22Frame("SLT", slt))...)
	if got, ok := embeddedLyricsFromID3(tag[:10], tag[10:]); !ok || got != "[00:01.00]第一句\n[01:05.23]第二句\n" {
		t.Errorf("v2.2 SLT 换成 LRC、压过纯文本的 ULT:得到 %q, ok=%v", got, ok)
	}

	for _, c := range []struct {
		name, desc, text string
	}{{"TXX:LYRICS 纯文本", "LYRICS", plain}, {"TXX:UNSYNCEDLYRICS 写着 LRC", "UNSYNCEDLYRICS", embeddedLRC}} {
		txx := append(append([]byte{0}, c.desc...), 0)
		tag := id3Tag(2, append(append([][]byte{}, lead...), id3v22Frame("TXX", append(txx, c.text...)))...)
		if got, ok := embeddedLyricsFromID3(tag[:10], tag[10:]); !ok || got != c.text {
			t.Errorf("v2.2 %s:得到 %q, ok=%v", c.name, got, ok)
		}
	}

	com := append([]byte{0, 'e', 'n', 'g', 0}, realNeteaseFileKey...)
	tag = id3Tag(2, id3v22Frame("COM", com), ult(embeddedLRC))
	if got := tagsFromID3(tag[:10], tag[10:]); got.lyrics != embeddedLRC || len(got.comments) != 1 || got.comments[0] != realNeteaseFileKey {
		t.Errorf("v2.2 COM 当注释:%+v", got)
	}

	// 四字母帧名写进 v2.2 标签不认(帧头只有 6 字节,按 v2.3 读会错位)。
	tag = id3Tag(2, id3Frame(3, "USLT", usltBody(3, []byte(embeddedLRC))))
	if _, ok := embeddedLyricsFromID3(tag[:10], tag[10:]); ok {
		t.Error("v2.2 标签里的四字母帧名不该认出歌词")
	}

	// 标了整个标签压缩过的不读,哪怕按 v2.3 扩展头跳过 4 字节后正好像一帧。
	compressed := id3Tag(2, []byte{0, 0, 0, 0}, ult(embeddedLRC))
	compressed[5] |= 0x40
	if _, ok := embeddedLyricsFromID3(compressed[:10], compressed[10:]); ok {
		t.Error("v2.2 标了整个标签压缩的不读")
	}

	file := id3Tag(2, append(append([][]byte{}, lead...), ult(embeddedLRC))...)
	if got, ok := localFileEmbeddedLyrics(writeTemp(t, "v22.mp3", append(file, 0xFF, 0xFB))); !ok || got != embeddedLRC {
		t.Errorf("v2.2 的 MP3 文件:得到 %q, ok=%v", got, ok)
	}
}

// v2.4 标签里帧长写成普通大端整数(iTunes 等老写法)时按落点认出来,不把歌词读成前一截;规范的同步安全写法照旧。见 02 章决策 260。
func TestEmbeddedLyricsID3v24PlainFrameSize(t *testing.T) {
	header := func(tag []byte) []byte {
		n := len(tag)
		return []byte{'I', 'D', '3', 4, 0, 0, byte(n >> 21 & 0x7F), byte(n >> 14 & 0x7F), byte(n >> 7 & 0x7F), byte(n & 0x7F)}
	}
	plainFrame := func(id string, body []byte) []byte {
		return append(append([]byte(id), binary.BigEndian.AppendUint32(nil, uint32(len(body)))...), append([]byte{0, 0}, body...)...)
	}
	album := id3Frame(4, "TALB", append([]byte{3}, "专辑"...))
	// 帧长字节带最高位(200 = 0xC8),后面跟着杂字节:只看最高位就认得出是普通整数。
	high := "[00:01.00]" + strings.Repeat("一", 61) + ".."
	if len(usltBody(3, []byte(high))) != 200 {
		t.Fatalf("测试帧长应为 200,得到 %d", len(usltBody(3, []byte(high))))
	}
	tag := append(plainFrame("USLT", usltBody(3, []byte(high))), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)
	if got, ok := embeddedLyricsFromID3(header(tag), tag); !ok || got != high {
		t.Errorf("v2.4 普通大端帧长(字节带最高位):得到 %q", got)
	}
	// 帧长 0x523 的四个字节都没有最高位:按同步安全读是 675,落在歌词里那串 Z 上(像帧 ID,帧长却超出标签区)。
	low := "[00:01.00]" + strings.Repeat("Z", 0x523-15)
	lowBody := usltBody(3, []byte(low))
	if len(lowBody) != 0x523 {
		t.Fatalf("测试帧长应为 0x523,得到 %d", len(lowBody))
	}
	for _, c := range []struct {
		name string
		tag  []byte
	}{
		{"后面接着下一帧", append(plainFrame("USLT", lowBody), album...)},
		{"后面是补白", append(plainFrame("USLT", lowBody), make([]byte, 64)...)},
		{"正好到标签区末尾", plainFrame("USLT", lowBody)},
		{"规范的同步安全写法", append(id3Frame(4, "USLT", lowBody), album...)},
	} {
		if got, ok := embeddedLyricsFromID3(header(c.tag), c.tag); !ok || got != low {
			t.Errorf("v2.4 帧长,%s:得到 %d 字节, ok=%v", c.name, len(got), ok)
		}
	}
}

// 块头连着是 0 的坏文件每块只前进 4 / 8 字节:FLAC、MP4、WAV 都要有块数上限,不逐块读到文件尾。见 02 章决策 260。
func TestEmbeddedLyricsMalformedBlocksBounded(t *testing.T) {
	block := func(kind byte, last bool, body []byte) []byte {
		if last {
			kind |= 0x80
		}
		return append([]byte{kind, byte(len(body) >> 16), byte(len(body) >> 8), byte(len(body))}, body...)
	}
	repeat := func(b []byte, n int) []byte { return bytes.Repeat(b, n) }
	comment := block(4, true, vorbisComment("LYRICS="+embeddedLRC))
	head := append([]byte("fLaC"), block(0, false, make([]byte, 34))...)
	le := func(n int) []byte { return binary.LittleEndian.AppendUint32(nil, uint32(n)) }
	ftyp := append(binary.BigEndian.AppendUint32(nil, 16), "ftypM4A \x00\x00\x00\x00"...)
	free := append(binary.BigEndian.AppendUint32(nil, 8), "free"...)
	lyr := []byte("\x00\x00\x00\x00")
	moov := func() []byte {
		atom := func(kind string, body ...[]byte) []byte {
			var b []byte
			for _, x := range body {
				b = append(b, x...)
			}
			return append(append(binary.BigEndian.AppendUint32(nil, uint32(8+len(b))), kind...), b...)
		}
		return atom("moov", atom("udta", atom("meta", lyr, atom("ilst", atom("\xa9lyr", atom("data", []byte{0, 0, 0, 1, 0, 0, 0, 0}, []byte(embeddedLRC)))))))
	}()
	for _, c := range []struct {
		name, file string
		data       []byte
		want       bool
	}{
		{"FLAC 全是 0", "zeros.flac", append([]byte("fLaC"), make([]byte, 4<<20)...), false},
		{"FLAC 100 块以内照读", "ok.flac", append(append(head, repeat(block(1, false, nil), 100)...), comment...), true},
		{"FLAC 块数超过上限就停", "many.flac", append(append(head, repeat(block(1, false, nil), 200)...), comment...), false},
		{"FLAC 遇到类型 127 就停", "127.flac", append(append(head, block(127, false, nil)...), comment...), false},
		{"FLAC 第二块又是 STREAMINFO 就停", "si.flac", append(append(head, block(0, false, make([]byte, 34))...), comment...), false},
		{"MP4 全是 8 字节小原子", "tiny.m4a", append(ftyp, repeat(free, 512<<10)...), false},
		{"MP4 moov 前面有 100 个小原子照读", "ok.m4a", append(append(ftyp, repeat(free, 100)...), moov...), true},
		{"MP4 顶层原子超过上限就停", "many.m4a", append(append(ftyp, repeat(free, 5000)...), moov...), false},
		{"WAV 全是空块", "empty.wav", append(append(append([]byte("RIFF"), le(0)...), "WAVE"...), repeat(append([]byte("junk"), le(0)...), 512<<10)...), false},
	} {
		start := time.Now()
		_, ok := localFileEmbeddedLyrics(writeTemp(t, c.file, c.data))
		if ok != c.want {
			t.Errorf("%s:有歌词=%v,应为 %v", c.name, ok, c.want)
		}
		if took := time.Since(start); took > 200*time.Millisecond {
			t.Errorf("%s:耗时 %v,块数没有上限", c.name, took)
		}
	}
}

// v2.4 的反同步按帧还原:帧长是反同步后的字节数,整段先还原再拆会错位。数据长度指示、分组标识跳过,压缩、加密的帧不读。
func TestEmbeddedLyricsID3v24FrameFormatFlags(t *testing.T) {
	lrc := "[00:01.00]稻香"
	title := []byte{1, 0xFF, 0x00, 0xFE, 'x', 0}
	tag := id3Tag(4, id3Frame(4, "TIT2", title), id3Frame(4, "USLT", usltBody(3, []byte(lrc))))
	tag[5] = 0x80
	if got, ok := embeddedLyricsFromID3(tag[:10], tag[10:]); !ok || got != lrc {
		t.Errorf("整个标签标了反同步的 v2.4:得到 %q, ok=%v", got, ok)
	}
	withFlags := func(flags byte, body []byte) []byte {
		f := id3Frame(4, "USLT", body)
		f[9] = flags
		return f
	}
	dli := append([]byte{0, 0, 0, 0x20}, usltBody(3, []byte(lrc))...)
	group := append([]byte{7}, usltBody(3, []byte(lrc))...)
	for name, frame := range map[string][]byte{"数据长度指示": withFlags(0x01, dli), "分组标识": withFlags(0x40, group)} {
		tag := id3Tag(4, frame)
		if got, ok := embeddedLyricsFromID3(tag[:10], tag[10:]); !ok || got != lrc {
			t.Errorf("v2.4 帧带%s:得到 %q, ok=%v", name, got, ok)
		}
	}
	compressed := id3Tag(4, withFlags(0x08|0x01, append([]byte{0, 0, 0, 0x20}, 0x78, 0x9C, 1, 2, 3)))
	if got, ok := embeddedLyricsFromID3(compressed[:10], compressed[10:]); ok {
		t.Errorf("压缩的帧不读:得到 %q", got)
	}
}
