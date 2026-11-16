package main

import (
	"bytes"
	"encoding/binary"
	"math/rand"
	"os"
	"path/filepath"
	"testing"
)

// 第二期格式(M4A、OGG / Opus、WAV / AIFF、ID3v2.2 升级)的写回单测。样本在这里按字节拼,核对用的拆法都独立于写入器。

func randBytes(seed int64, n int) []byte {
	b := make([]byte, n)
	rand.New(rand.NewSource(seed)).Read(b)
	return b
}

// writebackRoundTrip 写入 text,核对回读一字不差、inode 换了、没有残留克隆,交回写后的字节。
func writebackRoundTrip(t *testing.T, name string, data []byte, text string) []byte {
	t.Helper()
	path := writeTemp(t, name, data)
	oldIno := fileIno(t, path)
	if _, err := writeLyricsToFile(path, text, true); err != nil {
		t.Fatalf("%s 写入失败:%v", name, err)
	}
	if fileIno(t, path) == oldIno {
		t.Errorf("%s:inode 没变,说明是就地写", name)
	}
	if tags := readLocalFileTags(path); !tags.hasLyrics || tags.lyrics != normalizeWritebackLyrics(text) {
		t.Errorf("%s 回读:得到 %q", name, tags.lyrics)
	}
	noLeftoverClones(t, filepath.Dir(path))
	out, _ := os.ReadFile(path)
	return out
}

// wantRefused:写入被拒、错误码对、原文件逐字节不动、没有残留克隆。
func wantRefused(t *testing.T, name string, data []byte, overwrite bool, code string) {
	t.Helper()
	path := writeTemp(t, name, data)
	_, err := writeLyricsToFile(path, writebackLRC, overwrite)
	if lyricsWritebackCode(err) != code {
		t.Errorf("%s:想要 %s,得到 %v", name, code, err)
	}
	if out, _ := os.ReadFile(path); !bytes.Equal(out, data) {
		t.Errorf("%s:拒绝时原文件要不动", name)
	}
	noLeftoverClones(t, filepath.Dir(path))
}

// ---- ID3v2.2 升级 ----

func sampleV22Tag(extra ...[]byte) ([]byte, [][]byte) {
	pic := append([]byte{0}, "JPG"...)
	pic = append(pic, 3)
	pic = append(pic, "封面\x00"...)
	pic = append(pic, randBytes(7, 2000)...)
	frames := [][]byte{
		id3v22Frame("TT2", append([]byte{1}, utf16BOM("稻香")...)),
		id3v22Frame("TP1", []byte{0, 'J', 'a', 'y'}),
		id3v22Frame("TAL", []byte{0, 'A', 'l', 'b'}),
		id3v22Frame("TYE", []byte{0, '2', '0', '0', '8'}),
		id3v22Frame("TCP", []byte{0, '1'}),
		id3v22Frame("COM", append([]byte{0, 'e', 'n', 'g', 'i', 'T', 'u', 'n', 'N', 'O', 'R', 'M', 0}, " 0000"...)),
		id3v22Frame("PIC", pic),
	}
	ult := id3v22Frame("ULT", append(append([]byte{1, 'z', 'h', 'o'}, utf16BOM("")...), utf16BOM("旧歌词")...))
	all := append(append([][]byte{frames[0], ult}, frames[1:]...), extra...)
	return id3TagPadded(2, 128, all...), frames
}

func TestLyricsWritebackID3v22Upgrade(t *testing.T) {
	audio := writebackAudio(20000)
	tag, frames := sampleV22Tag()
	data := append(append([]byte(nil), tag...), audio...)
	out := writebackRoundTrip(t, "v22.mp3", data, writebackLRC)
	version, tagLen, got := parseID3ForTest(t, out)
	if version != 4 {
		t.Fatalf("v2.2 要升成 v2.4,得到 v2.%d", version)
	}
	if !bytes.Equal(out[tagLen:], audio) {
		t.Errorf("音频要逐字节相同")
	}
	wantIDs := []string{"TIT2", "TPE1", "TALB", "TDRC", "TCMP", "COMM", "APIC"}
	var kept [][]byte
	lyrics := 0
	for _, f := range got {
		if string(f[:4]) == "USLT" {
			lyrics++
			if string(f[11:14]) != "zho" {
				t.Errorf("USLT 语言沿用 ULT 的:%q", f[11:14])
			}
			continue
		}
		kept = append(kept, f)
	}
	if lyrics != 1 || len(kept) != len(wantIDs) {
		t.Fatalf("帧:%d 个歌词帧、%d 个别的帧", lyrics, len(kept))
	}
	for i, f := range kept {
		if string(f[:4]) != wantIDs[i] || f[8] != 0 || f[9] != 0 {
			t.Errorf("第 %d 帧 %q,想要 %s", i, f[:4], wantIDs[i])
		}
		body, old := f[10:], frames[i][6:]
		if wantIDs[i] == "APIC" {
			want := append(append([]byte{0}, "image/jpeg\x00"...), old[4:]...)
			if !bytes.Equal(body, want) {
				t.Errorf("PIC → APIC:格式换成 MIME,其余原样")
			}
			continue
		}
		if !bytes.Equal(body, old) {
			t.Errorf("%s 的正文要原样", wantIDs[i])
		}
	}
}

func TestLyricsWritebackID3v22Refusals(t *testing.T) {
	audio := writebackAudio(3000)
	for name, extra := range map[string][]byte{
		"CRM":  id3v22Frame("CRM", []byte("owner\x00x")),
		"TDA":  id3v22Frame("TDA", []byte{0, '0', '1', '0', '1'}),
		"ZZZ":  id3v22Frame("ZZZ", []byte{0}),
		"link": id3v22Frame("PIC", append([]byte{0}, "-->\x03\x00http://x"...)),
	} {
		tag, _ := sampleV22Tag(extra)
		wantRefused(t, "v22-"+name+".mp3", append(tag, audio...), true, wbErrUnsupportedTag)
	}
	compressed := append([]byte{'I', 'D', '3', 2, 0, 0x40, 0, 0, 0, 10}, make([]byte, 10)...)
	wantRefused(t, "v22-zip.mp3", append(compressed, audio...), true, wbErrUnsupportedTag)
	tag, _ := sampleV22Tag()
	wantRefused(t, "v22-has.mp3", append(tag, audio...), false, wbErrHasLyrics)
	overrun := append([]byte(nil), tag...)
	overrun[10+5] = 0xFF
	wantRefused(t, "v22-overrun.mp3", append(overrun, audio...), true, wbErrUnsupportedTag)
}

// ---- WAV / AIFF ----

func riffChunk(be bool, id string, payload []byte) []byte {
	out := make([]byte, 8)
	copy(out, id)
	if be {
		binary.BigEndian.PutUint32(out[4:], uint32(len(payload)))
	} else {
		binary.LittleEndian.PutUint32(out[4:], uint32(len(payload)))
	}
	out = append(out, payload...)
	if len(payload)%2 == 1 {
		out = append(out, 0)
	}
	return out
}

func riffFile(be bool, form string, chunks ...[]byte) []byte {
	body := append([]byte(form), bytes.Join(chunks, nil)...)
	if be {
		return append(riffChunk(true, "FORM", nil)[:4], append(binary.BigEndian.AppendUint32(nil, uint32(len(body))), body...)...)
	}
	return append([]byte("RIFF"), append(binary.LittleEndian.AppendUint32(nil, uint32(len(body))), body...)...)
}

type testChunk struct {
	id  string
	raw []byte
}

// parseRIFFForTest 独立拆顶层块。
func parseRIFFForTest(t *testing.T, data []byte, be bool) []testChunk {
	t.Helper()
	u32 := binary.LittleEndian.Uint32
	if be {
		u32 = binary.BigEndian.Uint32
	}
	if int(u32(data[4:8]))+8 != len(data) {
		t.Fatalf("RIFF / FORM 长度 %d,文件 %d", u32(data[4:8]), len(data))
	}
	var out []testChunk
	for pos := 12; pos < len(data); {
		n := int(u32(data[pos+4 : pos+8]))
		end := pos + 8 + n + n%2
		out = append(out, testChunk{id: string(data[pos : pos+4]), raw: data[pos:end]})
		pos = end
	}
	return out
}

func TestLyricsWritebackWAVAndAIFF(t *testing.T) {
	v23 := id3TagPadded(3, 32,
		id3Frame(3, "TIT2", append([]byte{1}, utf16BOM("稻香")...)),
		id3Frame(3, "USLT", usltBody(0, []byte("old lyrics"))),
		id3Frame(3, "APIC", append([]byte{0}, randBytes(3, 1500)...)))
	v22, _ := sampleV22Tag()
	for _, c := range []struct {
		name string
		be   bool
		form string
		tag  []byte
		pos  int // 0:没有 ID3 块;1:放在中间;2:放在最后
	}{
		{"none.wav", false, "WAVE", nil, 0},
		{"mid.wav", false, "WAVE", v23, 1},
		{"end.wav", false, "WAVE", v22, 2},
		{"none.aiff", true, "AIFF", nil, 0},
		{"mid.aif", true, "AIFC", v23, 1},
		{"end.aiff", true, "AIFF", append(append([]byte(nil), v23...), 0xEE, 0xEE, 0xEE), 2},
	} {
		fmtChunk := riffChunk(c.be, map[bool]string{false: "fmt ", true: "COMM"}[c.be], randBytes(1, 18))
		dataChunk := riffChunk(c.be, map[bool]string{false: "data", true: "SSND"}[c.be], randBytes(2, 30001))
		list := riffChunk(c.be, "LIST", append([]byte("INFOINAM"), randBytes(4, 21)...))
		id3ID := map[bool]string{false: "id3 ", true: "ID3 "}[c.be]
		chunks := [][]byte{fmtChunk, dataChunk, list}
		switch c.pos {
		case 1:
			chunks = [][]byte{fmtChunk, riffChunk(c.be, id3ID, c.tag), dataChunk, list}
		case 2:
			chunks = append(chunks, riffChunk(c.be, id3ID, c.tag))
		}
		data := riffFile(c.be, c.form, chunks...)
		for _, text := range []string{writebackLRC, writebackPlain} {
			out := writebackRoundTrip(t, c.name, data, text)
			if !bytes.Equal(out[8:12], data[8:12]) {
				t.Errorf("%s:表单类型要原样", c.name)
			}
			in, got := parseRIFFForTest(t, data, c.be), parseRIFFForTest(t, out, c.be)
			var inOther, gotOther []testChunk
			var tagChunk []byte
			for _, ch := range in {
				if ch.id != id3ID {
					inOther = append(inOther, ch)
				}
			}
			for _, ch := range got {
				if ch.id == id3ID {
					if tagChunk != nil {
						t.Errorf("%s:写出两个 ID3 块", c.name)
					}
					tagChunk = ch.raw
				} else {
					gotOther = append(gotOther, ch)
				}
			}
			if len(inOther) != len(gotOther) {
				t.Fatalf("%s:别的块 %d 个,原来 %d 个", c.name, len(gotOther), len(inOther))
			}
			for i := range inOther {
				if inOther[i].id != gotOther[i].id || !bytes.Equal(inOther[i].raw, gotOther[i].raw) {
					t.Errorf("%s:块 %q 要逐字节相同", c.name, inOther[i].id)
				}
			}
			if c.pos == 0 && got[len(got)-1].id != id3ID {
				t.Errorf("%s:新 ID3 块接在最后", c.name)
			}
			if c.pos == 1 && got[1].id != id3ID {
				t.Errorf("%s:ID3 块留在原位", c.name)
			}
			if tagChunk == nil {
				t.Fatalf("%s:没有 ID3 块", c.name)
			}
			_, tagLen, frames := parseID3ForTest(t, tagChunk[8:])
			if c.name == "end.aiff" && !bytes.HasSuffix(tagChunk[8:8+tagLen+3], []byte{0xEE, 0xEE, 0xEE}) {
				t.Errorf("%s:块里标签之后的字节要原样", c.name)
			}
			ids := ""
			for _, f := range frames {
				ids += string(f[:4]) + " "
			}
			want := map[int]string{0: "USLT ", 1: "TIT2 APIC USLT ", 2: "TIT2 APIC USLT "}[c.pos]
			if c.name == "end.wav" {
				want = "TIT2 TPE1 TALB TDRC TCMP COMM APIC USLT "
			}
			if ids != want {
				t.Errorf("%s:帧 %q,想要 %q", c.name, ids, want)
			}
			if c.pos == 1 {
				for _, f := range frames {
					if string(f[:4]) == "APIC" && !bytes.Equal(f[10:], append([]byte{0}, randBytes(3, 1500)...)) {
						t.Errorf("%s:APIC 正文要原样", c.name)
					}
				}
			}
		}
	}
}

func TestLyricsWritebackChunkRefusals(t *testing.T) {
	fmtChunk := riffChunk(false, "fmt ", randBytes(1, 16))
	dataChunk := riffChunk(false, "data", randBytes(2, 4000))
	has := riffChunk(false, "id3 ", id3TagPadded(4, 16, id3Frame(4, "USLT", usltBody(3, []byte("x")))))
	wantRefused(t, "has.wav", riffFile(false, "WAVE", fmtChunk, dataChunk, has), false, wbErrHasLyrics)
	two := riffFile(false, "WAVE", fmtChunk, has, dataChunk, riffChunk(false, "ID3 ", id3TagPadded(4, 16)))
	wantRefused(t, "two.wav", two, true, wbErrUnsupportedTag)
	overrun := riffFile(false, "WAVE", fmtChunk, dataChunk)
	binary.LittleEndian.PutUint32(overrun[12+24+4:], 999999)
	wantRefused(t, "overrun.wav", overrun, true, wbErrUnsupportedTag)
	rifx := riffFile(false, "WAVE", fmtChunk, dataChunk)
	copy(rifx, "RIFX")
	wantRefused(t, "rifx.wav", rifx, true, wbErrUnsupportedTag)
	notID3 := riffFile(false, "WAVE", fmtChunk, dataChunk, riffChunk(false, "id3 ", randBytes(5, 40)))
	wantRefused(t, "junk.wav", notID3, true, wbErrUnsupportedTag)
	truncated := riffFile(true, "AIFF", riffChunk(true, "COMM", randBytes(1, 18)), riffChunk(true, "SSND", randBytes(2, 4000)))
	wantRefused(t, "cut.aiff", truncated[:len(truncated)-100], true, wbErrUnsupportedTag)
}

// ---- OGG Vorbis / Opus ----

func oggTestPage(serial, seq uint32, flags byte, granule uint64, segs []byte, data []byte) []byte {
	p := make([]byte, 27)
	copy(p, "OggS")
	p[5] = flags
	binary.LittleEndian.PutUint64(p[6:], granule)
	binary.LittleEndian.PutUint32(p[14:], serial)
	binary.LittleEndian.PutUint32(p[18:], seq)
	p[26] = byte(len(segs))
	p = append(append(p, segs...), data...)
	oggSetCRC(p)
	return p
}

func lacing(n int) []byte {
	segs := bytes.Repeat([]byte{255}, n/255)
	return append(segs, byte(n%255))
}

// oggTestStream:识别头单独一页;其余头包按 maxSegs 段一页排;之后 audioPages 页音频,每页一个包,最后一页 EOS。
func oggTestStream(serial uint32, headers [][]byte, maxSegs, audioPages int) []byte {
	out := oggTestPage(serial, 0, 0x02, 0, lacing(len(headers[0])), headers[0])
	seq := uint32(1)
	var segs []byte
	var data []byte
	continued := false
	flush := func() {
		ends := false
		for _, x := range segs {
			ends = ends || x < 255
		}
		flags := byte(0)
		if continued {
			flags = 1
		}
		granule := uint64(0)
		if !ends {
			granule = oggGranuleNone
		}
		out = append(out, oggTestPage(serial, seq, flags, granule, segs, data)...)
		continued = segs[len(segs)-1] == 255
		seq++
		segs, data = nil, nil
	}
	for _, h := range headers[1:] {
		pkt := h
		for _, s := range lacing(len(h)) {
			if len(segs) == maxSegs {
				flush()
			}
			segs = append(segs, s)
			data = append(data, pkt[:int(s)]...)
			pkt = pkt[int(s):]
		}
	}
	flush()
	for i := 0; i < audioPages; i++ {
		flags := byte(0)
		if i == audioPages-1 {
			flags = 0x04
		}
		pkt := randBytes(int64(100+i), 3000+i)
		out = append(out, oggTestPage(serial, seq, flags, uint64(960*(i+1)), lacing(len(pkt)), pkt)...)
		seq++
	}
	return out
}

func vorbisCommentBytes(vendor string, entries ...string) []byte {
	var e [][]byte
	for _, s := range entries {
		e = append(e, []byte(s))
	}
	return buildVorbisComment([]byte(vendor), e)
}

type testOggPage struct {
	raw              []byte
	flags            byte
	granule          uint64
	serial, seq, crc uint32
	segs, data       []byte
}

// parseOggForTest 独立拆页、核校验和,交回页和第一条流的全部包。
func parseOggForTest(t *testing.T, data []byte) ([]testOggPage, [][]byte) {
	t.Helper()
	var pages []testOggPage
	var packets [][]byte
	var cur []byte
	for pos := 0; pos < len(data); {
		if string(data[pos:pos+4]) != "OggS" {
			t.Fatalf("偏移 %d 不是页头", pos)
		}
		n := int(data[pos+26])
		segs := data[pos+27 : pos+27+n]
		total := 0
		for _, s := range segs {
			total += int(s)
		}
		end := pos + 27 + n + total
		p := testOggPage{raw: data[pos:end], flags: data[pos+5], granule: binary.LittleEndian.Uint64(data[pos+6:]),
			serial: binary.LittleEndian.Uint32(data[pos+14:]), seq: binary.LittleEndian.Uint32(data[pos+18:]),
			crc: binary.LittleEndian.Uint32(data[pos+22:]), segs: segs, data: data[pos+27+n : end]}
		check := append([]byte(nil), p.raw...)
		copy(check[22:26], []byte{0, 0, 0, 0})
		var c uint32
		for _, b := range check {
			c = c<<8 ^ oggCRCTable[byte(c>>24)^b]
		}
		if c != p.crc {
			t.Errorf("页 %d 校验和不对", len(pages))
		}
		off := 0
		for _, s := range segs {
			cur = append(cur, p.data[off:off+int(s)]...)
			off += int(s)
			if s < 255 {
				packets = append(packets, cur)
				cur = nil
			}
		}
		pages = append(pages, p)
		pos = end
	}
	return pages, packets
}

func TestLyricsWritebackOgg(t *testing.T) {
	picture := "METADATA_BLOCK_PICTURE=" + string(bytes.Repeat([]byte("QUJD"), 20000))
	vorbisHead := append([]byte("\x01vorbis"), randBytes(9, 23)...)
	setup := append([]byte("\x05vorbis"), randBytes(10, 3000)...)
	opusHead := append([]byte("OpusHead"), randBytes(11, 11)...)
	for _, c := range []struct {
		name     string
		opus     bool
		entries  []string
		padding  int
		tail     []byte
		maxSegs  int
		text     string
		wantSame bool // 文件长度不变(填充吸收)
	}{
		{name: "pad.ogg", entries: []string{"TITLE=稻香", "LYRICS=旧歌词", "ARTIST=周杰伦"}, padding: 4096, text: writebackLRC, wantSame: true},
		{name: "grow.ogg", entries: []string{"TITLE=稻香", picture}, text: writebackPlain},
		{name: "renumber.oga", entries: []string{"TITLE=稻香", picture[:61858]}, maxSegs: 255, text: writebackLRC},
		{name: "pad.opus", opus: true, entries: []string{"TITLE=稻香", "UNSYNCEDLYRICS=old", "ARTIST=周杰伦"}, padding: 2000, text: writebackLRC, wantSame: true},
		{name: "bin.opus", opus: true, entries: []string{"TITLE=稻香"}, tail: []byte{0x01, 0xAA, 0xBB}, text: writebackPlain},
		{name: "big.opus", opus: true, entries: []string{"TITLE=稻香", picture}, maxSegs: 100, text: writebackLRC},
	} {
		comment := append([]byte("\x03vorbis"), vorbisCommentBytes("Lavf61", c.entries...)...)
		if c.opus {
			comment = append([]byte("OpusTags"), vorbisCommentBytes("Lavf61", c.entries...)...)
			comment = append(comment, c.tail...)
		} else {
			comment = append(comment, 1)
		}
		comment = append(comment, make([]byte, c.padding)...)
		headers := [][]byte{vorbisHead, comment, setup}
		if c.opus {
			headers = [][]byte{opusHead, comment}
		}
		maxSegs := c.maxSegs
		if maxSegs == 0 {
			maxSegs = 255
		}
		data := oggTestStream(0x1234, headers, maxSegs, 12)
		inPages, inPackets := parseOggForTest(t, data)
		out := writebackRoundTrip(t, c.name, data, c.text)
		if c.wantSame && len(out) != len(data) {
			t.Errorf("%s:填充吸收得下时文件长度不变,%d → %d", c.name, len(data), len(out))
		}
		pages, packets := parseOggForTest(t, out)
		if len(packets) != len(inPackets) {
			t.Fatalf("%s:包数 %d,原来 %d", c.name, len(packets), len(inPackets))
		}
		for i := range packets {
			if i != 1 && !bytes.Equal(packets[i], inPackets[i]) {
				t.Errorf("%s:包 %d 要逐字节相同", c.name, i)
			}
		}
		prefix := 7
		if c.opus {
			prefix = 8
		}
		vendor, entries, ok := parseVorbisComment(packets[1][prefix:])
		if !ok || string(vendor) != "Lavf61" {
			t.Fatalf("%s:注释头拆不开", c.name)
		}
		var kept []string
		lyrics := 0
		for _, e := range entries {
			if bytes.HasPrefix(e, []byte("LYRICS=")) {
				lyrics++
				continue
			}
			kept = append(kept, string(e))
		}
		var wantKept []string
		for _, e := range c.entries {
			if !bytes.HasPrefix([]byte(e), []byte("LYRICS=")) && !bytes.HasPrefix([]byte(e), []byte("UNSYNCEDLYRICS=")) {
				wantKept = append(wantKept, e)
			}
		}
		if lyrics != 1 || len(kept) != len(wantKept) {
			t.Fatalf("%s:%d 条歌词、%d 条别的", c.name, lyrics, len(kept))
		}
		for i := range kept {
			if kept[i] != wantKept[i] {
				t.Errorf("%s:条目 %d 变了", c.name, i)
			}
		}
		used := prefix + 8 + len(vendor)
		for _, e := range entries {
			used += 4 + len(e)
		}
		rest := packets[1][used:]
		switch {
		case !c.opus && (len(rest) == 0 || rest[0] != 1 || !allZero(rest[1:])):
			t.Errorf("%s:成帧位之后只许是 0 填充", c.name)
		case c.tail != nil && !bytes.Equal(rest, c.tail):
			t.Errorf("%s:Opus 注释后最低位是 1 的数据要原样", c.name)
		case c.opus && c.tail == nil && !allZero(rest):
			t.Errorf("%s:Opus 填充是 0", c.name)
		}
		headerPages := len(pages) - 12
		inHeaderPages := len(inPages) - 12
		delta := uint32(headerPages - inHeaderPages)
		if c.name == "renumber.oga" && delta == 0 {
			t.Errorf("%s:这份样本应该要加页", c.name)
		}
		for i := range 12 {
			a, b := inPages[inHeaderPages+i], pages[headerPages+i]
			if b.seq != a.seq+delta || !bytes.Equal(a.data, b.data) || !bytes.Equal(a.segs, b.segs) ||
				a.granule != b.granule || a.flags != b.flags || a.serial != b.serial {
				t.Errorf("%s:音频页 %d 只许页序号跟着头页数变", c.name, i)
			}
		}
		for i, p := range pages {
			if p.seq != uint32(i) || p.serial != 0x1234 {
				t.Errorf("%s:页 %d 序号 %d", c.name, i, p.seq)
			}
		}
		for i, p := range pages[1:headerPages] {
			ends := false
			for _, s := range p.segs {
				ends = ends || s < 255
			}
			if want := map[bool]uint64{true: 0, false: oggGranuleNone}[ends]; p.granule != want || p.flags&^1 != 0 {
				t.Errorf("%s:头页 %d 的粒度位置 %d / 标志 %#x", c.name, i+1, p.granule, p.flags)
			}
		}
	}
}

func TestLyricsWritebackOggRefusals(t *testing.T) {
	opusHead := append([]byte("OpusHead"), randBytes(11, 11)...)
	tags := append([]byte("OpusTags"), vorbisCommentBytes("v", "TITLE=x")...)
	good := oggTestStream(7, [][]byte{opusHead, tags}, 255, 3)
	has := oggTestStream(7, [][]byte{opusHead, append([]byte("OpusTags"), vorbisCommentBytes("v", "LYRICS=x")...)}, 255, 3)
	wantRefused(t, "has.opus", has, false, wbErrHasLyrics)

	badCRC := append([]byte(nil), good...)
	badCRC[len(opusHead)+28+40] ^= 0xFF
	wantRefused(t, "crc.opus", badCRC, true, wbErrUnsupportedTag)

	p0 := 27 + 1 + len(opusHead)
	other := append(append([]byte(nil), good[:p0]...), oggTestPage(8, 0, 0x02, 0, lacing(len(opusHead)), opusHead)...)
	other = append(other, good[p0:]...)
	wantRefused(t, "mux.opus", other, true, wbErrUnsupportedTag)

	flac := append([]byte("\x7fFLAC"), randBytes(1, 40)...)
	wantRefused(t, "flac.ogg", oggTestStream(7, [][]byte{flac, tags}, 255, 2), true, wbErrUnsupportedTag)

	vorbisHead := append([]byte("\x01vorbis"), randBytes(9, 23)...)
	vc := append(append([]byte("\x03vorbis"), vorbisCommentBytes("v", "TITLE=x")...), 1, 0, 7)
	wantRefused(t, "junk.ogg", oggTestStream(7, [][]byte{vorbisHead, vc, []byte("\x05vorbis")}, 255, 2), true, wbErrUnsupportedTag)

	// 音频包跟最后一个头包挤在同一页
	vcOK := append(append([]byte("\x03vorbis"), vorbisCommentBytes("v", "TITLE=x")...), 1)
	shared := oggTestStream(7, [][]byte{vorbisHead, vcOK, []byte("\x05vorbis"), randBytes(3, 50)}, 255, 2)
	wantRefused(t, "shared.ogg", shared, true, wbErrUnsupportedTag)

	wantRefused(t, "cut.opus", good[:len(opusHead)+28+10], true, wbErrUnsupportedTag)
}

// ---- M4A ----

func mp4TestBox(kind string, body ...[]byte) []byte { return mp4Box(kind, body...) }

type m4aSample struct {
	data    []byte
	samples [][2]int64 // 每个块:原文件里的偏移、长度
}

// m4aTestFile 拼一个 M4A:ftyp、moov(mvhd、两个 trak 各带 stco / co64、udta)、mdat;moovFirst 决定 moov 在 mdat 前还是后。
func m4aTestFile(moovFirst bool, udta []byte, co64 bool) m4aSample {
	ftyp := mp4TestBox("ftyp", []byte("M4A \x00\x00\x02\x00isomiso2"))
	mdatBody := randBytes(21, 50000)
	chunks := [][2]int64{{100, 4000}, {9000, 3000}, {30000, 7000}}
	build := func(mdatAt int64) []byte {
		stco := mp4TestBox("stco", []byte{0, 0, 0, 0}, binary.BigEndian.AppendUint32(nil, uint32(len(chunks))))
		for _, c := range chunks {
			stco = binary.BigEndian.AppendUint32(stco, uint32(mdatAt+8+c[0]))
		}
		binary.BigEndian.PutUint32(stco, uint32(len(stco)))
		off := mp4TestBox("co64", []byte{0, 0, 0, 0}, binary.BigEndian.AppendUint32(nil, 1), binary.BigEndian.AppendUint64(nil, uint64(mdatAt+8+chunks[0][0])))
		if !co64 {
			off = mp4TestBox("stco", []byte{0, 0, 0, 0}, binary.BigEndian.AppendUint32(nil, 1), binary.BigEndian.AppendUint32(nil, uint32(mdatAt+8+chunks[0][0])))
		}
		trak := func(table []byte) []byte {
			stbl := mp4TestBox("stbl", mp4TestBox("stsd", randBytes(30, 60)), mp4TestBox("stsz", randBytes(31, 20)), table)
			return mp4TestBox("trak", mp4TestBox("tkhd", randBytes(32, 84)),
				mp4TestBox("mdia", mp4TestBox("mdhd", randBytes(33, 24)), mp4TestBox("minf", mp4TestBox("smhd", make([]byte, 8)), stbl)))
		}
		parts := [][]byte{mp4TestBox("mvhd", randBytes(34, 100)), trak(stco), trak(off)}
		if udta != nil {
			parts = append(parts, udta)
		}
		return mp4TestBox("moov", parts...)
	}
	mdat := mp4TestBox("mdat", mdatBody)
	var data []byte
	var mdatAt int64
	if moovFirst {
		moovLen := int64(len(build(0)))
		mdatAt = int64(len(ftyp)) + moovLen
		data = bytes.Join([][]byte{ftyp, build(mdatAt), mdat}, nil)
	} else {
		mdatAt = int64(len(ftyp))
		data = bytes.Join([][]byte{ftyp, mdat, build(mdatAt)}, nil)
	}
	var samples [][2]int64
	for _, c := range chunks {
		samples = append(samples, [2]int64{mdatAt + 8 + c[0], c[1]})
	}
	return m4aSample{data: data, samples: samples}
}

func ilstItem(kind, text string) []byte {
	return mp4TestBox(kind, mp4TestBox("data", []byte{0, 0, 0, 1, 0, 0, 0, 0}, []byte(text)))
}

func m4aUdta(items [][]byte, free int, extra ...[]byte) []byte {
	ilst := mp4TestBox("ilst", bytes.Join(items, nil))
	metaKids := [][]byte{make([]byte, 4), mp4NewHdlr, ilst}
	if free > 0 {
		metaKids = append(metaKids, mp4TestBox("free", make([]byte, free-8)))
	}
	return mp4TestBox("udta", append(append([][]byte{}, extra...), mp4TestBox("meta", metaKids...))...)
}

// testMP4Find 独立地按路径找原子(meta 跳过 4 字节),交回所有同名的。
func testMP4Find(b []byte, path ...string) [][]byte {
	var out [][]byte
	for len(b) >= 8 {
		n := int(binary.BigEndian.Uint32(b))
		if n < 8 || n > len(b) {
			return out
		}
		if string(b[4:8]) == path[0] {
			body := b[8:n]
			if path[0] == "meta" {
				body = body[4:]
			}
			if len(path) == 1 {
				out = append(out, b[:n])
			} else {
				out = append(out, testMP4Find(body, path[1:]...)...)
			}
		}
		b = b[n:]
	}
	return out
}

func testChunkOffsets(t *testing.T, data []byte) []uint64 {
	t.Helper()
	moov := testMP4Find(data, "moov")
	if len(moov) != 1 {
		t.Fatalf("moov %d 个", len(moov))
	}
	var offs []uint64
	for _, kind := range []string{"stco", "co64"} {
		for _, a := range testMP4Find(moov[0][8:], "trak", "mdia", "minf", "stbl", kind) {
			n := int(binary.BigEndian.Uint32(a[12:16]))
			for i := 0; i < n; i++ {
				if kind == "stco" {
					offs = append(offs, uint64(binary.BigEndian.Uint32(a[16+4*i:])))
				} else {
					offs = append(offs, binary.BigEndian.Uint64(a[16+8*i:]))
				}
			}
		}
	}
	return offs
}

func TestLyricsWritebackM4A(t *testing.T) {
	cover := mp4TestBox("covr", mp4TestBox("data", []byte{0, 0, 0, 13, 0, 0, 0, 0}, randBytes(40, 5000)))
	items := [][]byte{ilstItem("\xa9nam", "稻香"), ilstItem("\xa9lyr", "旧歌词"), ilstItem("\xa9ART", "周杰伦"), cover, ilstItem("\xa9lyr", "第二份")}
	quickTime := mp4TestBox("\xa9swr", []byte("Lavf"))
	for _, c := range []struct {
		name      string
		moovFirst bool
		udta      []byte
		co64      bool
		sameSize  bool
	}{
		{"fits.m4a", true, m4aUdta(items, 4096), false, true},
		{"grow-first.m4a", true, m4aUdta(items, 0), false, false},
		{"grow-co64.m4a", true, m4aUdta(items, 0, quickTime), true, false},
		{"grow-last.m4a", false, m4aUdta(items, 0), false, false},
		{"no-udta.m4a", true, nil, false, false},
		{"no-meta.m4a", true, mp4TestBox("udta", quickTime), false, false},
		{"no-meta-last.m4a", false, mp4TestBox("udta", quickTime), true, false},
	} {
		s := m4aTestFile(c.moovFirst, c.udta, c.co64)
		for _, text := range []string{writebackLRC, writebackPlain} {
			out := writebackRoundTrip(t, c.name, s.data, text)
			if c.sameSize && len(out) != len(s.data) {
				t.Errorf("%s:free 吸收得下时文件长度不变", c.name)
			}
			offs := testChunkOffsets(t, out)
			if len(offs) != 4 {
				t.Fatalf("%s:块偏移 %d 个", c.name, len(offs))
			}
			for i, smp := range s.samples {
				o := offs[i]
				if !bytes.Equal(out[o:o+uint64(smp[1])], s.data[smp[0]:smp[0]+smp[1]]) {
					t.Errorf("%s:块 %d 的偏移没指到原来那段音频", c.name, i)
				}
			}
			if o := offs[3]; !bytes.Equal(out[o:o+4000], s.data[s.samples[0][0]:s.samples[0][0]+4000]) {
				t.Errorf("%s:第二个 trak 的偏移", c.name)
			}
			inMdat, outMdat := testMP4Find(s.data, "mdat"), testMP4Find(out, "mdat")
			if !bytes.Equal(inMdat[0], outMdat[0]) {
				t.Errorf("%s:mdat 要逐字节相同", c.name)
			}
			if !bytes.Equal(testMP4Find(out, "ftyp")[0], testMP4Find(s.data, "ftyp")[0]) {
				t.Errorf("%s:ftyp 要原样", c.name)
			}
			for _, path := range [][]string{{"moov", "mvhd"}, {"moov", "trak", "tkhd"}, {"moov", "trak", "mdia", "minf", "stbl", "stsd"}} {
				a, b := testMP4Find(s.data, path...), testMP4Find(out, path...)
				if len(a) != len(b) || !bytes.Equal(bytes.Join(a, nil), bytes.Join(b, nil)) {
					t.Errorf("%s:%v 要原样", c.name, path)
				}
			}
			lyr := testMP4Find(out, "moov", "udta", "meta", "ilst", "\xa9lyr")
			if len(lyr) != 1 {
				t.Fatalf("%s:©lyr %d 个", c.name, len(lyr))
			}
			if want := ilstItem("\xa9lyr", normalizeWritebackLyrics(text)); !bytes.Equal(lyr[0], want) {
				t.Errorf("%s:©lyr 写成 data 类型 1、地区 0", c.name)
			}
			if c.udta != nil && bytes.Contains(c.udta, []byte("ilst")) {
				var gotItems []string
				for _, k := range []string{"\xa9nam", "\xa9ART", "covr"} {
					a, b := testMP4Find(s.data, "moov", "udta", "meta", "ilst", k), testMP4Find(out, "moov", "udta", "meta", "ilst", k)
					if len(b) != 1 || !bytes.Equal(a[0], b[0]) {
						t.Errorf("%s:条目 %q 要原样", c.name, k)
					}
					gotItems = append(gotItems, k)
				}
				ilst := testMP4Find(out, "moov", "udta", "meta", "ilst")[0]
				if i, j := bytes.Index(ilst, []byte("\xa9lyr")), bytes.Index(ilst, []byte("\xa9ART")); i > j {
					t.Errorf("%s:新 ©lyr 放在第一个旧 ©lyr 的位置", c.name)
				}
			}
			if bytes.Contains(c.udta, quickTime) && len(testMP4Find(out, "moov", "udta", "\xa9swr")) != 1 {
				t.Errorf("%s:udta 里别的原子要留着", c.name)
			}
			if c.udta == nil || !bytes.Contains(c.udta, []byte("meta")) {
				hdlr := testMP4Find(out, "moov", "udta", "meta", "hdlr")
				if len(hdlr) != 1 || !bytes.Equal(hdlr[0], mp4NewHdlr) {
					t.Errorf("%s:新建 meta 带 hdlr mdir", c.name)
				}
			}
		}
	}
}

func TestLyricsWritebackM4ARefusals(t *testing.T) {
	items := [][]byte{ilstItem("\xa9nam", "x"), ilstItem("\xa9lyr", "旧歌词")}
	s := m4aTestFile(true, m4aUdta(items, 0), false)
	wantRefused(t, "has.m4a", s.data, false, wbErrHasLyrics)

	frag := append(append([]byte(nil), m4aTestFile(false, nil, false).data...), mp4TestBox("moof", make([]byte, 20))...)
	wantRefused(t, "frag.m4a", frag, true, wbErrUnsupportedTag)

	noIlst := m4aTestFile(true, mp4TestBox("udta", mp4TestBox("meta", make([]byte, 4), mp4NewHdlr)), false)
	wantRefused(t, "noilst.m4a", noIlst.data, true, wbErrUnsupportedTag)

	cut := m4aTestFile(true, nil, false).data
	wantRefused(t, "cut.m4a", cut[:len(cut)-10], true, wbErrUnsupportedTag)

	noMoov := mp4TestBox("ftyp", []byte("M4A "))
	wantRefused(t, "nomoov.m4a", append(noMoov, mp4TestBox("mdat", randBytes(1, 100))...), true, wbErrUnsupportedTag)

	// 块偏移指进 moov 里
	in := m4aTestFile(false, nil, false)
	bad := append([]byte(nil), in.data...)
	stco := bytes.Index(bad, []byte("stco"))
	binary.BigEndian.PutUint32(bad[stco+12:], uint32(len(bad)-20))
	wantRefused(t, "intomoov.m4a", bad, true, wbErrUnsupportedTag)

	// moov 在前、stco 加上变长量会超出 32 位
	big := m4aTestFile(true, nil, false)
	over := append([]byte(nil), big.data...)
	stco = bytes.Index(over, []byte("stco"))
	binary.BigEndian.PutUint32(over[stco+12:], 0xFFFFFFF0)
	wantRefused(t, "overflow.m4a", over, true, wbErrUnsupportedTag)
}

// ---- 自校验:每种格式的克隆被改坏都放弃替换 ----

func TestLyricsWritebackSelfCheckNewFormats(t *testing.T) {
	t.Cleanup(func() { lyricsWritebackAfterWrite = nil })
	v23 := id3TagPadded(3, 64, id3Frame(3, "TIT2", append([]byte{1}, utf16BOM("title-frame-bytes")...)))
	v22, _ := sampleV22Tag()
	wav := riffFile(false, "WAVE", riffChunk(false, "id3 ", v23), riffChunk(false, "fmt ", randBytes(1, 16)), riffChunk(false, "data", randBytes(2, 6000)))
	aiff := riffFile(true, "AIFF", riffChunk(true, "COMM", randBytes(1, 18)), riffChunk(true, "ID3 ", v23), riffChunk(true, "SSND", randBytes(2, 6000)))
	opusHead := append([]byte("OpusHead"), randBytes(11, 11)...)
	opus := oggTestStream(5, [][]byte{opusHead, append(append([]byte("OpusTags"), vorbisCommentBytes("vendor-bytes", "TITLE=title-entry")...), make([]byte, 1024)...)}, 255, 4)
	vorbis := oggTestStream(5, [][]byte{append([]byte("\x01vorbis"), randBytes(9, 23)...),
		append(append([]byte("\x03vorbis"), vorbisCommentBytes("vendor-bytes", "TITLE=title-entry")...), 1), append([]byte("\x05vorbis"), randBytes(3, 200)...)}, 255, 4)
	m4a := m4aTestFile(true, m4aUdta([][]byte{ilstItem("\xa9nam", "title-entry")}, 0), false).data
	samples := map[string][]byte{
		"v22.mp3": append(append([]byte(nil), v22...), writebackAudio(6000)...),
		"c.wav":   wav, "c.aiff": aiff, "c.opus": opus, "c.ogg": vorbis, "c.m4a": m4a,
	}
	for name, data := range samples {
		t.Run(name, func(t *testing.T) { selfCheckOneFormat(t, name, data) })
	}
}

func selfCheckOneFormat(t *testing.T, name string, data []byte) {
	type corruption struct {
		code   string
		mutate func(d []byte)
	}
	flipAt := func(needle string) func(d []byte) {
		return func(d []byte) {
			if i := bytes.Index(d, []byte(needle)); i >= 0 {
				d[i+len(needle)-1] ^= 0x01
			} else if i := bytes.Index(d, utf16BOM(needle)[2:8]); i >= 0 {
				d[i+2] ^= 0x01
			}
		}
	}
	{
		tagNeedle := "title-entry"
		if name == "v22.mp3" {
			tagNeedle = "Alb"
		} else if name == "c.wav" || name == "c.aiff" {
			tagNeedle = "title-frame-bytes"
		}
		corruptions := []corruption{
			{wbErrAudioMismatch, func(d []byte) { d[len(d)-300] ^= 0xFF }},
			{wbErrTagsNotPreserved, flipAt(tagNeedle)},
			{wbErrReadbackMismatch, func(d []byte) {
				if i := bytes.Index(d, []byte("第三行")); i >= 0 {
					copy(d[i:], "第四行")
					return
				}
				from, to := utf16BOM("第三行")[2:8], utf16BOM("第四行")[2:8]
				copy(d[bytes.Index(d, from):], to)
			}},
		}
		// 标签区前面的字节(AIFF 的 COMM 块、M4A 的 ftyp)被改。
		if at, ok := map[string]int{"c.aiff": 25, "c.m4a": 20}[name]; ok {
			corruptions = append(corruptions, corruption{wbErrAudioMismatch, func(d []byte) { d[at] ^= 0xFF }})
		}
		for _, c := range corruptions {
			if name == "c.ogg" || name == "c.opus" {
				inner := c.mutate
				c.mutate = func(d []byte) {
					inner(d)
					// 改过的页重算校验和,只让要测的那一项不对。
					for pos := 0; pos+27 <= len(d) && string(d[pos:pos+4]) == "OggS"; {
						n := int(d[pos+26])
						total := 0
						for _, s := range d[pos+27 : pos+27+n] {
							total += int(s)
						}
						oggSetCRC(d[pos : pos+27+n+total])
						pos += 27 + n + total
					}
				}
			}
			path := writeTemp(t, name, data)
			lyricsWritebackAfterWrite = func(clone string) {
				d, err := os.ReadFile(clone)
				if err != nil {
					t.Fatal(err)
				}
				c.mutate(d)
				if err := os.WriteFile(clone, d, 0o644); err != nil {
					t.Fatal(err)
				}
			}
			_, err := writeLyricsToFile(path, writebackLRC, true)
			if lyricsWritebackCode(err) != c.code {
				t.Errorf("%s:想要 %s,得到 %v", name, c.code, err)
			}
			if out, _ := os.ReadFile(path); !bytes.Equal(out, data) {
				t.Errorf("%s %s:自校验失败时原文件不动", name, c.code)
			}
			noLeftoverClones(t, filepath.Dir(path))
		}
	}
}
