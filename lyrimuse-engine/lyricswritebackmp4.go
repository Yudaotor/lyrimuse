package main

import (
	"bytes"
	"encoding/binary"
	"io"
)

// M4A 的歌词写回:moov › udta › meta › ilst 里写一个 ©lyr(data 原子类型 1 即 UTF-8,地区 0),纯文本和 LRC 都写进它。
// 标签区是整个 moov 原子(读法 mp4Tags 认的那个)。做法照 mutagen 的 MP4Tags.save:
//   - 原有的 ©lyr 全部去掉,新的放在第一个旧 ©lyr 的位置(没有就接在最后);别的条目原样、按原顺序留着。
//   - ilst 前后紧挨着的 free 原子当填充:新 ilst 放得下就在它后面补一个 free 凑回原长,moov 总长不变、音频不挪;放不下(或
//     剩的不够 8 字节的 free 头)就补 writebackPadding 大的 free,moov 变长。
//   - 没有 udta / meta 就新建(meta 里放 hdlr mdir,同 mutagen),接在父原子的子原子最后;meta 在、里面没有 ilst 的不写。
//   - moov 变长变短时,父原子 meta / udta / moov 的长度跟着改;各 trak 的 stco / co64 里指向 moov 之后的偏移加上变化量,
//     指向 moov 之前的不动,指进 moov 里面的、stco 加完超出 32 位的不写。
//   - 分片(moof)、压缩 moov(cmov)、带 saio 的(加密样本的辅助信息偏移这里不改)、两个 moov、原子长度越界、moov 里
//     出现 64 位或「到文件尾」长度的不写(wbErrUnsupportedTag)。见 11 章决策 173。

const mp4LyricsItem = "\xa9lyr"

// mp4Atom:一个 32 位长度的原子原样的字节(8 字节头 + 正文)。
type mp4Atom struct {
	kind string
	raw  []byte
}

func (a mp4Atom) body() []byte { return a.raw[8:] }

// mp4Atoms 拆一串首尾相接的原子;有长度小于 8、64 位长度、长度 0 或越界的为 false。
func mp4Atoms(b []byte) ([]mp4Atom, bool) {
	var out []mp4Atom
	for len(b) > 0 {
		if len(b) < 8 {
			return nil, false
		}
		size := int(binary.BigEndian.Uint32(b[:4]))
		if size < 8 || size > len(b) {
			return nil, false
		}
		out = append(out, mp4Atom{kind: string(b[4:8]), raw: b[:size]})
		b = b[size:]
	}
	return out, true
}

func mp4Box(kind string, body ...[]byte) []byte {
	n := 8
	for _, b := range body {
		n += len(b)
	}
	out := make([]byte, 8, n)
	binary.BigEndian.PutUint32(out, uint32(n))
	copy(out[4:], kind)
	for _, b := range body {
		out = append(out, b...)
	}
	return out
}

func mp4Join(atoms []mp4Atom) []byte {
	var out []byte
	for _, a := range atoms {
		out = append(out, a.raw...)
	}
	return out
}

// mp4NewHdlr:新建 meta 时放的 hdlr(处理类型 mdir、厂商 appl),跟 mutagen 写的逐字节相同。
var mp4NewHdlr = mp4Box("hdlr", make([]byte, 8), []byte("mdirappl"), make([]byte, 9))

// mp4ChunkOffsetContainers:从 moov 往下找 stco / co64 要钻进去的原子。
var mp4ChunkOffsetContainers = map[string]bool{"trak": true, "mdia": true, "minf": true, "stbl": true}

// mp4WalkChunkOffsets 顺着 trak › mdia › minf › stbl 找每个 stco / co64 / saio,把原子交给 fn(raw 跟 children 共用底层字节,
// 可就地改)。子原子拆不开为 false。
func mp4WalkChunkOffsets(children []mp4Atom, fn func(a mp4Atom) error) error {
	for _, a := range children {
		switch {
		case mp4ChunkOffsetContainers[a.kind]:
			sub, ok := mp4Atoms(a.body())
			if !ok {
				return wbErrf(wbErrUnsupportedTag, "malformed %q atom", a.kind)
			}
			if err := mp4WalkChunkOffsets(sub, fn); err != nil {
				return err
			}
		case a.kind == "stco" || a.kind == "co64" || a.kind == "saio":
			if err := fn(a); err != nil {
				return err
			}
		}
	}
	return nil
}

// mp4OffsetTable:stco / co64 的偏移表(版本标志 4 字节 + 条数 4 字节 + 每条 4 / 8 字节);条数跟长度对不上为 false。
func mp4OffsetTable(a mp4Atom) (entries []byte, width int, ok bool) {
	width = 4
	if a.kind == "co64" {
		width = 8
	}
	b := a.body()
	if len(b) < 8 {
		return nil, 0, false
	}
	n := int64(binary.BigEndian.Uint32(b[4:8]))
	if n*int64(width) != int64(len(b)-8) {
		return nil, 0, false
	}
	return b[8:], width, true
}

func mp4Offset(entries []byte, width, i int) uint64 {
	if width == 4 {
		return uint64(binary.BigEndian.Uint32(entries[i*4:]))
	}
	return binary.BigEndian.Uint64(entries[i*8:])
}

// mp4ShiftedOffset:moov 原来占 [start, end)、长度变化 delta 之后,一个块偏移该是多少。指进 moov 里或超出范围为 false。
func mp4ShiftedOffset(off uint64, width int, start, end, delta int64) (uint64, bool) {
	switch {
	case off < uint64(start):
		return off, true
	case off < uint64(end):
		return 0, false
	}
	v := int64(off) + delta
	if v < end+delta || width == 4 && v > 0xFFFFFFFF {
		return 0, false
	}
	return uint64(v), true
}

// mp4Path:moov 里第一个 udta、它里面第一个 meta、meta 里第一个 ilst 的下标(没有为 -1)。
type mp4Path struct {
	udta, meta, ilst int
	udtaKids         []mp4Atom
	metaKids         []mp4Atom
	items            []mp4Atom
}

func mp4FindPath(moovKids []mp4Atom) (mp4Path, error) {
	p := mp4Path{udta: -1, meta: -1, ilst: -1}
	for i, a := range moovKids {
		if a.kind == "udta" {
			p.udta = i
			break
		}
	}
	if p.udta < 0 {
		return p, nil
	}
	var ok bool
	if p.udtaKids, ok = mp4Atoms(moovKids[p.udta].body()); !ok {
		return p, wbErrf(wbErrUnsupportedTag, "malformed udta atom")
	}
	for i, a := range p.udtaKids {
		if a.kind == "meta" {
			p.meta = i
			break
		}
	}
	if p.meta < 0 {
		return p, nil
	}
	meta := p.udtaKids[p.meta].body()
	if len(meta) < 4 {
		return p, wbErrf(wbErrUnsupportedTag, "malformed meta atom")
	}
	if p.metaKids, ok = mp4Atoms(meta[4:]); !ok {
		return p, wbErrf(wbErrUnsupportedTag, "malformed meta atom")
	}
	for i, a := range p.metaKids {
		if a.kind == "ilst" {
			p.ilst = i
			break
		}
	}
	if p.ilst < 0 {
		return p, wbErrf(wbErrUnsupportedTag, "meta atom without ilst")
	}
	if p.items, ok = mp4Atoms(p.metaKids[p.ilst].body()); !ok {
		return p, wbErrf(wbErrUnsupportedTag, "malformed ilst atom")
	}
	return p, nil
}

// mp4WritebackLayout 走一遍顶层原子找 moov;标签区就是整个 moov。
func mp4WritebackLayout(r io.ReadSeeker, fileSize int64) (lyricsTagLayout, error) {
	moovStart, moovEnd := int64(-1), int64(-1)
	pos := int64(0)
	for i := 0; pos < fileSize; i++ {
		if i >= localFileEmbeddedMaxBlocks {
			return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "too many top-level atoms")
		}
		if _, err := r.Seek(pos, io.SeekStart); err != nil {
			return lyricsTagLayout{}, wbErr(wbErrIO, err)
		}
		kind, size, err := mp4AtomHeader(r)
		if err != nil {
			return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "malformed top-level atom at %d", pos)
		}
		hdr, _ := r.Seek(0, io.SeekCurrent)
		end := hdr + size
		if size < 0 {
			end = fileSize
		}
		if end > fileSize {
			return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "atom %q overruns the file", kind)
		}
		switch kind {
		case "moov":
			if moovStart >= 0 {
				return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "two moov atoms")
			}
			if size < 0 || hdr-pos != 8 {
				return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "moov atom with a 64-bit or open-ended size")
			}
			moovStart, moovEnd = pos, end
		case "moof", "mvex":
			return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "fragmented MP4")
		}
		pos = end
	}
	if moovStart < 0 {
		return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "no moov atom")
	}
	if moovEnd-moovStart > localFileEmbeddedMaxTagBytes {
		return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "moov atom larger than %d bytes", localFileEmbeddedMaxTagBytes)
	}
	moov := make([]byte, moovEnd-moovStart)
	if _, err := r.Seek(moovStart, io.SeekStart); err != nil {
		return lyricsTagLayout{}, wbErr(wbErrIO, err)
	}
	if _, err := io.ReadFull(r, moov); err != nil {
		return lyricsTagLayout{}, wbErr(wbErrIO, err)
	}
	kids, ok := mp4Atoms(moov[8:])
	if !ok {
		return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "malformed moov atom")
	}
	for _, a := range kids {
		if a.kind == "cmov" || a.kind == "mvex" {
			return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "%s atom in moov", a.kind)
		}
	}
	err := mp4WalkChunkOffsets(kids, func(a mp4Atom) error {
		if a.kind == "saio" {
			return wbErrf(wbErrUnsupportedTag, "saio atom in moov")
		}
		entries, width, ok := mp4OffsetTable(a)
		if !ok {
			return wbErrf(wbErrUnsupportedTag, "malformed %s atom", a.kind)
		}
		for i := 0; i < len(entries)/width; i++ {
			if _, ok := mp4ShiftedOffset(mp4Offset(entries, width, i), width, moovStart, moovEnd, 0); !ok {
				return wbErrf(wbErrUnsupportedTag, "chunk offset points into moov")
			}
		}
		return nil
	})
	if err != nil {
		return lyricsTagLayout{}, err
	}
	path, err := mp4FindPath(kids)
	if err != nil {
		return lyricsTagLayout{}, err
	}
	for _, it := range path.items {
		if it.kind != mp4LyricsItem {
			continue
		}
		data, ok := mp4Child(it.body(), "data")
		if ok && len(data) >= 8 && len(bytes.TrimSpace(bytes.Trim(data[8:], "\x00"))) > 0 {
			if _, ok := decodeLyricBytes(data[8:]); !ok {
				return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "lyrics item the reader cannot decode")
			}
		}
	}
	audio := fileSize - int64(len(moov))
	return lyricsTagLayout{
		head:        moov,
		regionStart: moovStart,
		audioStart:  moovEnd,
		hasLyrics:   tagsFromMP4Moov(moov[8:]).hasLyrics,
		build: func(text string) ([]byte, error) {
			return mp4BuildMoov(kids, path, text, audio, moovStart, moovEnd)
		},
		preserved: func(newMoov []byte) error {
			return mp4PreservedErr(moov, newMoov, moovStart, moovEnd)
		},
	}, nil
}

// mp4LyricsAtom:©lyr › data(类型 1 = UTF-8,地区 0)。
func mp4LyricsAtom(text string) []byte {
	return mp4Box(mp4LyricsItem, mp4Box("data", []byte{0, 0, 0, 1, 0, 0, 0, 0}, []byte(text)))
}

// mp4FreeAtom:总长 n(含 8 字节头)的 free。
func mp4FreeAtom(n int) []byte {
	return mp4Box("free", make([]byte, n-8))
}

// mp4BuildMoov 拼新的 moov:换掉 ilst(和它两边的 free),必要时新建 udta / meta,改父原子长度,最后平移块偏移。
func mp4BuildMoov(kids []mp4Atom, p mp4Path, text string, audio, moovStart, moovEnd int64) ([]byte, error) {
	var items []mp4Atom
	placed := false
	for _, it := range p.items {
		if it.kind != mp4LyricsItem {
			items = append(items, it)
		} else if !placed {
			items = append(items, mp4Atom{kind: mp4LyricsItem, raw: mp4LyricsAtom(text)})
			placed = true
		}
	}
	if !placed {
		items = append(items, mp4Atom{kind: mp4LyricsItem, raw: mp4LyricsAtom(text)})
	}
	ilst := mp4Box("ilst", mp4Join(items))
	pad := mp4FreeAtom(writebackPadding(audio))
	var udta []byte
	switch {
	case p.udta < 0:
		udta = mp4Box("udta", mp4Box("meta", make([]byte, 4), mp4NewHdlr, ilst, pad))
	case p.meta < 0:
		meta := mp4Box("meta", make([]byte, 4), mp4NewHdlr, ilst, pad)
		udta = mp4Box("udta", mp4Join(p.udtaKids), meta)
	default:
		from, to := p.ilst, p.ilst+1
		if from > 0 && p.metaKids[from-1].kind == "free" {
			from--
		}
		if to < len(p.metaKids) && p.metaKids[to].kind == "free" {
			to++
		}
		avail := len(mp4Join(p.metaKids[from:to]))
		fill := ilst
		switch rem := avail - len(ilst); {
		case rem == 0:
		case rem >= 8:
			fill = append(fill, mp4FreeAtom(rem)...)
		default:
			fill = append(fill, pad...)
		}
		old := p.udtaKids[p.meta].body()
		meta := mp4Box("meta", old[:4], mp4Join(p.metaKids[:from]), fill, mp4Join(p.metaKids[to:]))
		udta = mp4Box("udta", mp4Join(p.udtaKids[:p.meta]), meta, mp4Join(p.udtaKids[p.meta+1:]))
	}
	var body []byte
	for i, a := range kids {
		if i == p.udta {
			body = append(body, udta...)
		} else {
			body = append(body, a.raw...)
		}
	}
	if p.udta < 0 {
		body = append(body, udta...)
	}
	if 8+int64(len(body)) > 0xFFFFFFFF {
		return nil, wbErrf(wbErrUnsupportedTag, "moov atom would exceed 4 GiB")
	}
	moov := mp4Box("moov", body)
	delta := int64(len(moov)) - (moovEnd - moovStart)
	if delta == 0 {
		return moov, nil
	}
	newKids, _ := mp4Atoms(moov[8:])
	err := mp4WalkChunkOffsets(newKids, func(a mp4Atom) error {
		entries, width, _ := mp4OffsetTable(a)
		for i := 0; i < len(entries)/width; i++ {
			v, ok := mp4ShiftedOffset(mp4Offset(entries, width, i), width, moovStart, moovEnd, delta)
			if !ok {
				return wbErrf(wbErrUnsupportedTag, "chunk offset would overflow after moov grows")
			}
			if width == 4 {
				binary.BigEndian.PutUint32(entries[i*4:], uint32(v))
			} else {
				binary.BigEndian.PutUint64(entries[i*8:], v)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return moov, nil
}

// mp4PreservedErr:新 moov 跟原来比,只有这几处不同:第一个 udta › meta › ilst 里的 ©lyr(恰好一个)、那个 meta 里的 free、
// 新建的 udta / meta(只含 hdlr、ilst、free),以及 stco / co64 的偏移恰好按 moov 长度变化平移;别的原子逐字节相同、顺序一致。
func mp4PreservedErr(oldMoov, newMoov []byte, moovStart, moovEnd int64) error {
	if len(newMoov) < 8 || string(newMoov[4:8]) != "moov" || int(binary.BigEndian.Uint32(newMoov[:4])) != len(newMoov) {
		return wbErrf(wbErrTagsNotPreserved, "new moov header")
	}
	oldKids, _ := mp4Atoms(oldMoov[8:])
	newKids, ok := mp4Atoms(newMoov[8:])
	if !ok {
		return wbErrf(wbErrTagsNotPreserved, "new moov does not parse")
	}
	delta := int64(len(newMoov) - len(oldMoov))
	cmp := mp4Compare{start: moovStart, end: moovEnd, delta: delta}
	return cmp.children(oldKids, newKids, "moov")
}

type mp4Compare struct {
	start, end, delta int64
}

// children 对比同一个父原子下的子原子。parent 是 moov / udta / meta / ilst 时,只有第一个 udta / meta / ilst 往下钻。
func (c mp4Compare) children(old, got []mp4Atom, parent string) error {
	special := map[string]string{"moov": "udta", "udta": "meta", "meta": "ilst"}[parent]
	if parent == "meta" {
		old, got = mp4Without(old, "free"), mp4Without(got, "free")
	}
	if parent == "ilst" {
		if n := len(got) - len(mp4Without(got, mp4LyricsItem)); n != 1 {
			return wbErrf(wbErrTagsNotPreserved, "%d lyrics items in ilst", n)
		}
		old, got = mp4Without(old, mp4LyricsItem), mp4Without(got, mp4LyricsItem)
	}
	if special != "" && special != "ilst" && mp4Index(old, special) < 0 {
		if len(got) != len(old)+1 || got[len(got)-1].kind != special {
			return wbErrf(wbErrTagsNotPreserved, "%s: expected a new %s at the end", parent, special)
		}
		if err := mp4CreatedErr(got[len(got)-1]); err != nil {
			return err
		}
		got = got[:len(got)-1]
	}
	if len(got) != len(old) {
		return wbErrf(wbErrTagsNotPreserved, "%s has %d child atoms, expected %d", parent, len(got), len(old))
	}
	first := mp4Index(old, special)
	for i := range old {
		o, g := old[i], got[i]
		if o.kind != g.kind {
			return wbErrf(wbErrTagsNotPreserved, "%s child %d is %q, expected %q", parent, i, g.kind, o.kind)
		}
		switch {
		case i == first:
			ob, gb := o.body(), g.body()
			if special == "meta" {
				if len(gb) < 4 || !bytes.Equal(ob[:4], gb[:4]) {
					return wbErrf(wbErrTagsNotPreserved, "meta version and flags changed")
				}
				ob, gb = ob[4:], gb[4:]
			}
			oldSub, _ := mp4Atoms(ob)
			gk, ok := mp4Atoms(gb)
			if !ok {
				return wbErrf(wbErrTagsNotPreserved, "%s does not parse", special)
			}
			if err := c.children(oldSub, gk, special); err != nil {
				return err
			}
		case mp4ChunkOffsetContainers[o.kind]:
			oldSub, _ := mp4Atoms(o.body())
			gk, ok := mp4Atoms(g.body())
			if !ok {
				return wbErrf(wbErrTagsNotPreserved, "%s does not parse", o.kind)
			}
			if err := c.children(oldSub, gk, o.kind); err != nil {
				return err
			}
		case o.kind == "stco" || o.kind == "co64":
			if err := c.offsets(o, g); err != nil {
				return err
			}
		case !bytes.Equal(o.raw, g.raw):
			return wbErrf(wbErrTagsNotPreserved, "%s › %s changed", parent, o.kind)
		}
	}
	return nil
}

// offsets:新偏移表跟原来条数相同、每条恰好是 mp4ShiftedOffset 的结果。
func (c mp4Compare) offsets(o, g mp4Atom) error {
	oe, width, _ := mp4OffsetTable(o)
	ge, gw, ok := mp4OffsetTable(g)
	if !ok || gw != width || len(ge) != len(oe) || !bytes.Equal(o.body()[:8], g.body()[:8]) {
		return wbErrf(wbErrTagsNotPreserved, "%s table changed shape", o.kind)
	}
	for i := 0; i < len(oe)/width; i++ {
		want, _ := mp4ShiftedOffset(mp4Offset(oe, width, i), width, c.start, c.end, c.delta)
		if mp4Offset(ge, width, i) != want {
			return wbErrf(wbErrTagsNotPreserved, "%s entry %d is %d, expected %d", o.kind, i, mp4Offset(ge, width, i), want)
		}
	}
	return nil
}

// mp4CreatedErr:新建的 udta / meta 里只有 hdlr mdir、恰好一个 ©lyr 的 ilst 和 free。
func mp4CreatedErr(a mp4Atom) error {
	meta := a
	if a.kind == "udta" {
		kids, ok := mp4Atoms(a.body())
		if !ok || len(kids) != 1 || kids[0].kind != "meta" {
			return wbErrf(wbErrTagsNotPreserved, "new udta holds something besides meta")
		}
		meta = kids[0]
	}
	b := meta.body()
	if len(b) < 4 || !allZero(b[:4]) {
		return wbErrf(wbErrTagsNotPreserved, "new meta header")
	}
	kids, ok := mp4Atoms(b[4:])
	if !ok {
		return wbErrf(wbErrTagsNotPreserved, "new meta does not parse")
	}
	kids = mp4Without(kids, "free")
	if len(kids) != 2 || !bytes.Equal(kids[0].raw, mp4NewHdlr) || kids[1].kind != "ilst" {
		return wbErrf(wbErrTagsNotPreserved, "new meta holds something besides hdlr and ilst")
	}
	items, ok := mp4Atoms(kids[1].body())
	if !ok || len(items) != 1 || items[0].kind != mp4LyricsItem {
		return wbErrf(wbErrTagsNotPreserved, "new ilst holds something besides the lyrics")
	}
	return nil
}

func mp4Without(atoms []mp4Atom, kind string) []mp4Atom {
	var out []mp4Atom
	for _, a := range atoms {
		if a.kind != kind {
			out = append(out, a)
		}
	}
	return out
}

func mp4Index(atoms []mp4Atom, kind string) int {
	for i, a := range atoms {
		if a.kind == kind {
			return i
		}
	}
	return -1
}
