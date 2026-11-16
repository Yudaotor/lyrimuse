package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"io"
	"os"
)

// OGG Vorbis / Opus 的歌词写回:改第二个包(注释头 "\x03vorbis" / "OpusTags")里的 Vorbis 注释,纯文本和 LRC 都写成一条
// LYRICS=…;条目规则同 FLAC(vorbisKeptEntries、buildVorbisComment)。
//   - 注释包变长变短先由包尾的 0 填充吸收(Vorbis 填在成帧位之后,Opus 填在注释之后,同 mutagen),包长不变时原来的分页
//     一字不改、只重算校验和;吸收不了就补 writebackPadding 的填充,头几页在原页数里重新分段,原页数放不下才加页,
//     此后这条流每一页的页序号跟着变、重算校验和(同 mutagen 的 OggPage.replace)。
//   - Opus 注释之后最低位是 1 的二进制数据原样留着(RFC 7845 5.2 节),最低位是 0 的当填充。
//   - 只认第一页是 Vorbis / Opus 的那条流;头几页里有别的流(多路复用)、头包没在页尾收住、校验和不对、Vorbis 成帧位
//     之后不全是 0 的不写(wbErrUnsupportedTag)。见 11 章决策 173。

const oggGranuleNone = ^uint64(0)

// oggPage:一页原样的字节(27 字节页头 + 段表 + 数据)。
type oggPage struct {
	raw      []byte
	segCount int
}

func (p oggPage) flags() byte      { return p.raw[5] }
func (p oggPage) granule() uint64  { return binary.LittleEndian.Uint64(p.raw[6:14]) }
func (p oggPage) serial() uint32   { return binary.LittleEndian.Uint32(p.raw[14:18]) }
func (p oggPage) seq() uint32      { return binary.LittleEndian.Uint32(p.raw[18:22]) }
func (p oggPage) segments() []byte { return p.raw[27 : 27+p.segCount] }
func (p oggPage) data() []byte     { return p.raw[27+p.segCount:] }

// readOggPage 读一页;页开头就到文件尾时交回 io.EOF。
func readOggPage(r io.Reader) (oggPage, error) {
	h := make([]byte, 27)
	if n, err := io.ReadFull(r, h); err != nil {
		if n == 0 && err == io.EOF {
			return oggPage{}, io.EOF
		}
		return oggPage{}, wbErrf(wbErrUnsupportedTag, "truncated Ogg page")
	}
	if string(h[:4]) != "OggS" || h[4] != 0 {
		return oggPage{}, wbErrf(wbErrUnsupportedTag, "not an Ogg page")
	}
	segs := make([]byte, h[26])
	if _, err := io.ReadFull(r, segs); err != nil {
		return oggPage{}, wbErrf(wbErrUnsupportedTag, "truncated Ogg page")
	}
	total := 0
	for _, s := range segs {
		total += int(s)
	}
	raw := make([]byte, 27+len(segs)+total)
	copy(raw, h)
	copy(raw[27:], segs)
	if _, err := io.ReadFull(r, raw[27+len(segs):]); err != nil {
		return oggPage{}, wbErrf(wbErrUnsupportedTag, "truncated Ogg page")
	}
	return oggPage{raw: raw, segCount: len(segs)}, nil
}

var oggCRCTable = func() (t [256]uint32) {
	for i := range t {
		c := uint32(i) << 24
		for range 8 {
			if c&0x80000000 != 0 {
				c = c<<1 ^ 0x04C11DB7
			} else {
				c <<= 1
			}
		}
		t[i] = c
	}
	return t
}()

// oggCRC:页的校验和(校验和字段按 0 算)。
func oggCRC(page []byte) uint32 {
	var c uint32
	for i, b := range page {
		if i >= 22 && i < 26 {
			b = 0
		}
		c = c<<8 ^ oggCRCTable[byte(c>>24)^b]
	}
	return c
}

func oggCRCValid(page []byte) bool {
	return oggCRC(page) == binary.LittleEndian.Uint32(page[22:26])
}

func oggSetCRC(page []byte) {
	binary.LittleEndian.PutUint32(page[22:26], oggCRC(page))
}

// oggHeaders:文件开头属于头包的那几页,拆好的头包,和这条流的编码。
type oggHeaders struct {
	pages   []oggPage
	packets [][]byte
	opus    bool
}

// oggSplitHeaders 从 r 读头几页,直到头包收齐(Vorbis 三个、Opus 两个),最后一个头包得在页尾收住;每页校验和要对、
// 第一页只有 BOS 标志、后面的页属于同一条流。读过的字节超过 limit 就拒绝。
func oggSplitHeaders(r io.Reader, limit int) (oggHeaders, error) {
	var h oggHeaders
	var cur []byte
	need, read := 1, 0
	for len(h.packets) < need {
		p, err := readOggPage(r)
		if err != nil {
			if err == io.EOF {
				return h, wbErrf(wbErrUnsupportedTag, "file ends inside the Ogg headers")
			}
			return h, err
		}
		if read += len(p.raw); read > limit {
			return h, wbErrf(wbErrUnsupportedTag, "Ogg headers larger than %d bytes", limit)
		}
		first := len(h.pages) == 0
		switch {
		case !oggCRCValid(p.raw):
			return h, wbErrf(wbErrUnsupportedTag, "Ogg page %d checksum mismatch", len(h.pages))
		case first && p.flags() != 0x02:
			return h, wbErrf(wbErrUnsupportedTag, "first Ogg page flags %#x", p.flags())
		case !first && p.serial() != h.pages[0].serial():
			return h, wbErrf(wbErrUnsupportedTag, "multiplexed Ogg stream")
		case !first && p.flags()&^0x01 != 0:
			return h, wbErrf(wbErrUnsupportedTag, "Ogg header page flags %#x", p.flags())
		case !first && (p.flags()&0x01 != 0) != (len(cur) > 0):
			return h, wbErrf(wbErrUnsupportedTag, "Ogg continued-packet flag does not match")
		}
		h.pages = append(h.pages, p)
		off, data := 0, p.data()
		for _, s := range p.segments() {
			cur = append(cur, data[off:off+int(s)]...)
			off += int(s)
			if s < 255 {
				h.packets = append(h.packets, cur)
				cur = nil
			}
		}
		if first {
			switch {
			case len(h.packets) != 1 || len(cur) != 0:
				return h, wbErrf(wbErrUnsupportedTag, "first Ogg page does not hold exactly the identification header")
			case bytes.HasPrefix(h.packets[0], []byte("\x01vorbis")):
				need = 3
			case bytes.HasPrefix(h.packets[0], []byte("OpusHead")):
				need, h.opus = 2, true
			default:
				return h, wbErrf(wbErrUnsupportedTag, "Ogg stream is neither Vorbis nor Opus")
			}
		}
	}
	if len(h.packets) != need || len(cur) != 0 {
		return h, wbErrf(wbErrUnsupportedTag, "audio starts on the last Ogg header page")
	}
	return h, nil
}

// oggComment:注释包拆开的样子。rest 是 Vorbis 注释之后的字节(Vorbis 的成帧位、填充,Opus 的填充或二进制数据)。
type oggComment struct {
	prefix  string
	vendor  []byte
	entries [][]byte
	rest    []byte
}

func parseOggComment(p []byte, opus bool) (oggComment, bool) {
	c := oggComment{prefix: "\x03vorbis"}
	if opus {
		c.prefix = "OpusTags"
	}
	if !bytes.HasPrefix(p, []byte(c.prefix)) {
		return c, false
	}
	body := p[len(c.prefix):]
	vendor, entries, ok := parseVorbisComment(body)
	if !ok {
		return c, false
	}
	used := 8 + len(vendor)
	for _, e := range entries {
		used += 4 + len(e)
	}
	c.vendor, c.entries, c.rest = vendor, entries, body[used:]
	return c, true
}

func allZero(b []byte) bool {
	for _, x := range b {
		if x != 0 {
			return false
		}
	}
	return true
}

// keptTail:注释之后要原样留下的字节。Vorbis 是成帧位 0x01;Opus 最低位是 1 的二进制数据。其余当填充。
// ok 为 false:Vorbis 成帧位不对或后面的填充不全是 0。
func (c oggComment) keptTail(opus bool) (tail []byte, ok bool) {
	if !opus {
		if len(c.rest) == 0 || c.rest[0] != 1 || !allZero(c.rest[1:]) {
			return nil, false
		}
		return []byte{1}, true
	}
	if len(c.rest) > 0 && c.rest[0]&1 == 1 {
		return c.rest, true
	}
	return nil, true
}

// oggWritebackLayout 读 OGG 开头的头几页;标签区就是这几页。
func oggWritebackLayout(r io.ReadSeeker, fileSize int64) (lyricsTagLayout, error) {
	h, err := oggSplitHeaders(bufio.NewReader(r), localFileEmbeddedMaxTagBytes)
	if err != nil {
		return lyricsTagLayout{}, err
	}
	comment, ok := parseOggComment(h.packets[1], h.opus)
	if !ok {
		return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "malformed Ogg comment header")
	}
	tail, ok := comment.keptTail(h.opus)
	if !ok {
		return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "unexpected bytes after the Vorbis comment")
	}
	for _, e := range comment.entries {
		key, value, _ := bytes.Cut(e, []byte("="))
		if !isLyricsTagKey(string(key)) || len(bytes.TrimSpace(value)) == 0 {
			continue
		}
		if _, ok := decodeLyricBytes(value); !ok {
			return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "lyrics entry %q the reader cannot decode", key)
		}
	}
	var head []byte
	for _, p := range h.pages {
		head = append(head, p.raw...)
	}
	kept := vorbisKeptEntries(comment.entries)
	audio := fileSize - int64(len(head))
	oldPages := len(h.pages)
	pageDelta := func(newHead []byte) (uint32, error) {
		n, err := oggPageCount(newHead)
		return uint32(n - oldPages), err
	}
	return lyricsTagLayout{
		head:       head,
		audioStart: int64(len(head)),
		hasLyrics:  tagsFromVorbisComment(h.packets[1][len(comment.prefix):]).hasLyrics,
		build: func(text string) ([]byte, error) {
			pkt := append([]byte(comment.prefix), buildVorbisComment(comment.vendor, kept, "LYRICS="+text)...)
			pkt = append(pkt, tail...)
			if !h.opus || len(tail) == 0 {
				if old := len(h.packets[1]); len(pkt) <= old {
					pkt = append(pkt, make([]byte, old-len(pkt))...)
				} else {
					pkt = append(pkt, make([]byte, writebackPadding(audio))...)
				}
			}
			packets := append([][]byte{h.packets[0], pkt}, h.packets[2:]...)
			out := oggPaginate(h.pages, h.packets, packets)
			if len(out) > localFileEmbeddedMaxTagBytes {
				return nil, wbErrf(wbErrUnsupportedTag, "Ogg headers would exceed %d bytes", localFileEmbeddedMaxTagBytes)
			}
			return out, nil
		},
		preserved: func(newHead []byte) error {
			return oggPreservedErr(h, comment, kept, tail, newHead)
		},
		copyTail: func(dst io.Writer, src io.Reader, newHead []byte) (int64, error) {
			delta, err := pageDelta(newHead)
			if err != nil {
				return 0, err
			}
			if delta == 0 {
				return io.Copy(dst, src)
			}
			return oggRenumber(dst, src, h.pages[0].serial(), delta)
		},
		tailCheck: func(orig, clone string, origStart, cloneStart int64, newHead []byte) error {
			delta, err := pageDelta(newHead)
			if err != nil {
				return wbErr(wbErrAudioMismatch, err)
			}
			if delta == 0 {
				return sameAudioRegion(orig, origStart, clone, cloneStart)
			}
			return oggSameRenumbered(orig, origStart, clone, cloneStart, h.pages[0].serial(), delta)
		},
	}, nil
}

// oggPaginate 把新的头包排成页。第一页(识别头)原样;各包长度都没变就沿用原来每页的段表、只换数据重算校验和;
// 变了就把其余头包的段在原页数里摊开,原页数放不下(每页最多 255 段)才按每页 255 段加页。
func oggPaginate(old []oggPage, oldPackets, packets [][]byte) []byte {
	out := append([]byte(nil), old[0].raw...)
	same := len(oldPackets) == len(packets)
	for i := range packets {
		same = same && len(packets[i]) == len(oldPackets[i])
	}
	if same {
		data := bytes.Join(packets[1:], nil)
		for _, p := range old[1:] {
			page := append([]byte(nil), p.raw[:27+p.segCount]...)
			n := len(p.data())
			page = append(page, data[:n]...)
			data = data[n:]
			oggSetCRC(page)
			out = append(out, page...)
		}
		return out
	}
	type seg struct {
		data []byte
		ends bool
	}
	var segs []seg
	for _, pkt := range packets[1:] {
		for len(pkt) >= 255 {
			segs = append(segs, seg{data: pkt[:255]})
			pkt = pkt[255:]
		}
		segs = append(segs, seg{data: pkt, ends: true})
	}
	pages := len(old) - 1
	if len(segs) > 255*pages || len(segs) < pages {
		pages = (len(segs) + 254) / 255
	}
	serial, seq := old[0].serial(), old[0].seq()
	continued := false
	total := len(segs)
	for i := range pages {
		n := total / pages
		if i < total%pages {
			n++
		}
		chunk := segs[:n]
		segs = segs[n:]
		page := make([]byte, 27, 27+n)
		copy(page, "OggS")
		if continued {
			page[5] = 0x01
		}
		granule := oggGranuleNone
		for _, s := range chunk {
			if s.ends {
				granule = 0
			}
		}
		binary.LittleEndian.PutUint64(page[6:14], granule)
		binary.LittleEndian.PutUint32(page[14:18], serial)
		binary.LittleEndian.PutUint32(page[18:22], seq+1+uint32(i))
		page[26] = byte(n)
		for _, s := range chunk {
			page = append(page, byte(len(s.data)))
		}
		for _, s := range chunk {
			page = append(page, s.data...)
		}
		continued = !chunk[len(chunk)-1].ends
		oggSetCRC(page)
		out = append(out, page...)
	}
	return out
}

func oggPageCount(head []byte) (int, error) {
	r := bytes.NewReader(head)
	n := 0
	for {
		if _, err := readOggPage(r); err == io.EOF {
			return n, nil
		} else if err != nil {
			return 0, err
		}
		n++
	}
}

// oggPreservedErr:新的头几页里,识别头那页逐字节相同;其余页属于同一条流、页序号接着排、标志位和粒度位置合规、校验和对;
// 头包个数不变,识别头和 Vorbis 设置头逐字节相同;注释包的厂商串和非歌词条目不变、恰好一条歌词条目,之后是原来留着的字节
// 加全 0 的填充。
func oggPreservedErr(orig oggHeaders, comment oggComment, kept [][]byte, tail, newHead []byte) error {
	r := bytes.NewReader(newHead)
	got, err := oggSplitHeaders(r, len(newHead))
	if err != nil {
		return wbErr(wbErrTagsNotPreserved, err)
	}
	if r.Len() != 0 {
		return wbErrf(wbErrTagsNotPreserved, "bytes after the last Ogg header page")
	}
	if !bytes.Equal(got.pages[0].raw, orig.pages[0].raw) {
		return wbErrf(wbErrTagsNotPreserved, "Ogg identification page changed")
	}
	for i, p := range got.pages[1:] {
		if p.seq() != orig.pages[0].seq()+1+uint32(i) {
			return wbErrf(wbErrTagsNotPreserved, "Ogg header page %d sequence %d", i+1, p.seq())
		}
		if i+1 < len(orig.pages) && bytes.Equal(p.raw[:22], orig.pages[i+1].raw[:22]) {
			continue
		}
		ends := false
		for _, s := range p.segments() {
			ends = ends || s < 255
		}
		if want := map[bool]uint64{true: 0, false: oggGranuleNone}[ends]; p.granule() != want {
			return wbErrf(wbErrTagsNotPreserved, "Ogg header page %d granule position %d", i+1, p.granule())
		}
	}
	if len(got.packets) != len(orig.packets) {
		return wbErrf(wbErrTagsNotPreserved, "%d Ogg header packets, expected %d", len(got.packets), len(orig.packets))
	}
	for i := range got.packets {
		if i != 1 && !bytes.Equal(got.packets[i], orig.packets[i]) {
			return wbErrf(wbErrTagsNotPreserved, "Ogg header packet %d changed", i)
		}
	}
	c, ok := parseOggComment(got.packets[1], orig.opus)
	if !ok || !bytes.Equal(c.vendor, comment.vendor) {
		return wbErrf(wbErrTagsNotPreserved, "Ogg comment header vendor changed")
	}
	gotKept := vorbisKeptEntries(c.entries)
	if len(gotKept) != len(kept) || len(c.entries)-len(gotKept) != 1 {
		return wbErrf(wbErrTagsNotPreserved, "Ogg comment has %d kept and %d lyrics entries", len(gotKept), len(c.entries)-len(gotKept))
	}
	for i := range kept {
		if !bytes.Equal(gotKept[i], kept[i]) {
			return wbErrf(wbErrTagsNotPreserved, "Ogg comment entry %d changed", i)
		}
	}
	if !bytes.HasPrefix(c.rest, tail) || !allZero(c.rest[len(tail):]) {
		return wbErrf(wbErrTagsNotPreserved, "bytes after the Vorbis comment changed")
	}
	return nil
}

// oggRenumber 把 src 里的页接进 dst:serial 这条流的页(到它的 EOS 页为止)页序号加 delta、重算校验和,别的页原样。
// src 里有不是页的字节就拒绝。
func oggRenumber(dst io.Writer, src io.Reader, serial, delta uint32) (int64, error) {
	br := bufio.NewReaderSize(src, 1<<20)
	var n int64
	ended := false
	for {
		p, err := readOggPage(br)
		if err == io.EOF {
			return n, nil
		}
		if err != nil {
			return n, err
		}
		if !ended && p.serial() == serial {
			binary.LittleEndian.PutUint32(p.raw[18:22], p.seq()+delta)
			oggSetCRC(p.raw)
			ended = p.flags()&0x04 != 0
		}
		w, err := dst.Write(p.raw)
		n += int64(w)
		if err != nil {
			return n, err
		}
	}
}

// oggSameRenumbered:原文件从 aStart、克隆从 bStart 起逐页对比,serial 这条流的页(到 EOS 为止)只许页序号恰好差 delta、
// 校验和是改过之后的;别的字节都相同,两边同时到文件尾。
func oggSameRenumbered(orig string, aStart int64, clone string, bStart int64, serial, delta uint32) error {
	open := func(path string, start int64) (*bufio.Reader, func(), error) {
		f, err := os.Open(path)
		if err != nil {
			return nil, nil, wbErr(wbErrIO, err)
		}
		if _, err := f.Seek(start, io.SeekStart); err != nil {
			f.Close()
			return nil, nil, wbErr(wbErrIO, err)
		}
		return bufio.NewReaderSize(f, 1<<20), func() { f.Close() }, nil
	}
	ra, closeA, err := open(orig, aStart)
	if err != nil {
		return err
	}
	defer closeA()
	rb, closeB, err := open(clone, bStart)
	if err != nil {
		return err
	}
	defer closeB()
	ended := false
	for i := 0; ; i++ {
		pa, errA := readOggPage(ra)
		pb, errB := readOggPage(rb)
		if errA == io.EOF && errB == io.EOF {
			return nil
		}
		if errA != nil || errB != nil {
			return wbErrf(wbErrAudioMismatch, "Ogg page %d after the headers: %v / %v", i, errA, errB)
		}
		if len(pa.raw) != len(pb.raw) {
			return wbErrf(wbErrAudioMismatch, "Ogg page %d after the headers changed length", i)
		}
		if !ended && pa.serial() == serial {
			if pb.seq() != pa.seq()+delta || !oggCRCValid(pb.raw) ||
				!bytes.Equal(pa.raw[:18], pb.raw[:18]) || !bytes.Equal(pa.raw[26:], pb.raw[26:]) {
				return wbErrf(wbErrAudioMismatch, "Ogg page %d after the headers changed beyond its sequence number", i)
			}
			ended = pa.flags()&0x04 != 0
			continue
		}
		if !bytes.Equal(pa.raw, pb.raw) {
			return wbErrf(wbErrAudioMismatch, "Ogg page %d after the headers changed", i)
		}
	}
}
