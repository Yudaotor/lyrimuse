package main

import (
	"bytes"
	"encoding/binary"
	"io"
)

// FLAC 的歌词写回:改第一个 VORBIS_COMMENT 块(类型 4),纯文本和 LRC 都写成一条 LYRICS=…;不写 UNSYNCEDLYRICS。
//   - 原有的歌词条目(isLyricsTagKey 认的那几个键)全部去掉,厂商串和别的条目原样、按原顺序留着,新条目接在最后。
//     没有注释块就在 STREAMINFO 后面新建一个,厂商串写 Lyrimuse。
//   - 别的块(STREAMINFO、SEEKTABLE、图片、CUESHEET、APPLICATION…)原样、按原顺序留着。
//   - 注释块变长变短都先由第一个 PADDING 块吸收,元数据总长不变、音频帧不挪;吸收不了就把那个 PADDING 块改成
//     writebackPadding 那么大(没有就在最后补一个)。
//   - 文件开头不是 fLaC(前面套了 ID3 之类)的不写(wbErrUnsupportedTag)。

const (
	flacBlockStreamInfo    = 0
	flacBlockPadding       = 1
	flacBlockVorbisComment = 4
	flacMaxBlockBody       = 1<<24 - 1
	flacWritebackVendor    = "Lyrimuse"
)

// flacBlock:一个元数据块的类型和正文(不含 4 字节块头)。
type flacBlock struct {
	kind byte
	body []byte
}

// flacWritebackLayout 读 fLaC 和全部元数据块。
func flacWritebackLayout(r io.ReadSeeker, fileSize int64) (lyricsTagLayout, error) {
	magic := make([]byte, 4)
	if _, err := io.ReadFull(r, magic); err != nil || string(magic) != "fLaC" {
		return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "file does not start with fLaC")
	}
	head := bytes.NewBuffer(append([]byte(nil), magic...))
	var blocks []flacBlock
	for {
		bh := make([]byte, 4)
		if _, err := io.ReadFull(r, bh); err != nil {
			return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "truncated metadata block header")
		}
		last, kind := bh[0]&0x80 != 0, bh[0]&0x7F
		size := int(bh[1])<<16 | int(bh[2])<<8 | int(bh[3])
		if int64(head.Len()+4+size) > fileSize || head.Len()+4+size > localFileEmbeddedMaxTagBytes {
			return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "metadata block overruns the file")
		}
		body := make([]byte, size)
		if _, err := io.ReadFull(r, body); err != nil {
			return lyricsTagLayout{}, wbErr(wbErrIO, err)
		}
		head.Write(bh)
		head.Write(body)
		blocks = append(blocks, flacBlock{kind: kind, body: body})
		if last {
			break
		}
	}
	if len(blocks) == 0 || blocks[0].kind != flacBlockStreamInfo {
		return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "first metadata block is not STREAMINFO")
	}
	comment := -1
	for i, b := range blocks {
		if b.kind == flacBlockVorbisComment {
			comment = i
			break
		}
	}
	vendor, entries := []byte(flacWritebackVendor), [][]byte(nil)
	hasLyrics := false
	if comment >= 0 {
		var ok bool
		if vendor, entries, ok = parseVorbisComment(blocks[comment].body); !ok {
			return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "malformed VORBIS_COMMENT block")
		}
		hasLyrics = tagsFromVorbisComment(blocks[comment].body).hasLyrics
		// 读法解不出的歌词条目写回时会被删掉,确认框、覆盖前的备份都看不到它,整个文件不写(同 id3LyricsFrameUnreadable)。
		for _, e := range entries {
			key, value, _ := bytes.Cut(e, []byte("="))
			if !isLyricsTagKey(string(key)) || len(bytes.TrimSpace(value)) == 0 {
				continue
			}
			if _, ok := decodeLyricBytes(value); !ok {
				return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "lyrics entry %q the reader cannot decode", key)
			}
		}
	}
	keptEntries := vorbisKeptEntries(entries)
	headBytes := head.Bytes()
	audio := fileSize - int64(len(headBytes))
	return lyricsTagLayout{
		head:       headBytes,
		audioStart: int64(len(headBytes)),
		hasLyrics:  hasLyrics,
		build: func(text string) ([]byte, error) {
			body := buildVorbisComment(vendor, keptEntries, "LYRICS="+text)
			if len(body) > flacMaxBlockBody {
				return nil, wbErrf(wbErrUnsupportedTag, "VORBIS_COMMENT block would exceed the FLAC block size limit")
			}
			out := append([]flacBlock(nil), blocks...)
			if comment >= 0 {
				out[comment] = flacBlock{kind: flacBlockVorbisComment, body: body}
			} else {
				out = append(out[:1], append([]flacBlock{{kind: flacBlockVorbisComment, body: body}}, out[1:]...)...)
			}
			return flacFitHead(out, len(headBytes), audio), nil
		},
		preserved: func(newHead []byte) error {
			return flacPreservedErr(blocks, vendor, keptEntries, newHead)
		},
	}, nil
}

// flacFitHead 按 PADDING 把块拼回去:总长能凑成 oldLen 就凑成,不能就把 PADDING 设成 writebackPadding。
func flacFitHead(blocks []flacBlock, oldLen int, audioBytes int64) []byte {
	pad := -1
	for i, b := range blocks {
		if b.kind == flacBlockPadding {
			pad = i
			break
		}
	}
	length := 4
	for i, b := range blocks {
		if i != pad {
			length += 4 + len(b.body)
		}
	}
	switch {
	case pad >= 0 && oldLen-length-4 >= 0 && oldLen-length-4 <= flacMaxBlockBody:
		blocks[pad] = flacBlock{kind: flacBlockPadding, body: make([]byte, oldLen-length-4)}
	case pad >= 0:
		blocks[pad] = flacBlock{kind: flacBlockPadding, body: make([]byte, writebackPadding(audioBytes))}
	default:
		blocks = append(blocks, flacBlock{kind: flacBlockPadding, body: make([]byte, writebackPadding(audioBytes))})
	}
	var out bytes.Buffer
	out.WriteString("fLaC")
	for i, b := range blocks {
		h := byte(b.kind)
		if i == len(blocks)-1 {
			h |= 0x80
		}
		out.Write([]byte{h, byte(len(b.body) >> 16), byte(len(b.body) >> 8), byte(len(b.body))})
		out.Write(b.body)
	}
	return out.Bytes()
}

// parseVorbisComment 拆厂商串和各条「键=值」原样的字节;长度越界或条数对不上为 false。
func parseVorbisComment(b []byte) (vendor []byte, entries [][]byte, ok bool) {
	next := func() ([]byte, bool) {
		if len(b) < 4 {
			return nil, false
		}
		n := binary.LittleEndian.Uint32(b[:4])
		if uint64(n) > uint64(len(b)-4) {
			return nil, false
		}
		v := b[4 : 4+n]
		b = b[4+n:]
		return v, true
	}
	if vendor, ok = next(); !ok || len(b) < 4 {
		return nil, nil, false
	}
	count := binary.LittleEndian.Uint32(b[:4])
	b = b[4:]
	for i := uint32(0); i < count; i++ {
		c, ok := next()
		if !ok {
			return nil, nil, false
		}
		entries = append(entries, c)
	}
	return vendor, entries, true
}

// vorbisKeptEntries:写回时原样留下的条目,即键不是歌词键的全部。
func vorbisKeptEntries(entries [][]byte) [][]byte {
	var kept [][]byte
	for _, e := range entries {
		key, _, _ := bytes.Cut(e, []byte("="))
		if !isLyricsTagKey(string(key)) {
			kept = append(kept, e)
		}
	}
	return kept
}

func buildVorbisComment(vendor []byte, entries [][]byte, extra ...string) []byte {
	var out bytes.Buffer
	put := func(b []byte) {
		var n [4]byte
		binary.LittleEndian.PutUint32(n[:], uint32(len(b)))
		out.Write(n[:])
		out.Write(b)
	}
	put(vendor)
	var n [4]byte
	binary.LittleEndian.PutUint32(n[:], uint32(len(entries)+len(extra)))
	out.Write(n[:])
	for _, e := range entries {
		put(e)
	}
	for _, e := range extra {
		put([]byte(e))
	}
	return out.Bytes()
}

// flacPreservedErr:新元数据里注释块和 PADDING 以外的块跟原来逐字节相同、顺序一致;注释块的厂商串和非歌词条目不变,
// 恰好一条歌词条目。
func flacPreservedErr(orig []flacBlock, vendor []byte, keptEntries [][]byte, newHead []byte) error {
	if !bytes.HasPrefix(newHead, []byte("fLaC")) {
		return wbErrf(wbErrTagsNotPreserved, "no fLaC")
	}
	var got []flacBlock
	var comments [][]byte
	b := newHead[4:]
	for {
		if len(b) < 4 {
			return wbErrf(wbErrTagsNotPreserved, "truncated metadata")
		}
		last, kind := b[0]&0x80 != 0, b[0]&0x7F
		size := int(b[1])<<16 | int(b[2])<<8 | int(b[3])
		if 4+size > len(b) {
			return wbErrf(wbErrTagsNotPreserved, "block overruns the metadata")
		}
		body := b[4 : 4+size]
		b = b[4+size:]
		switch kind {
		case flacBlockVorbisComment:
			comments = append(comments, body)
			if len(comments) > 1 {
				got = append(got, flacBlock{kind: kind, body: body})
			}
		case flacBlockPadding:
		default:
			got = append(got, flacBlock{kind: kind, body: body})
		}
		if last {
			break
		}
	}
	if len(b) != 0 {
		return wbErrf(wbErrTagsNotPreserved, "bytes after the last metadata block")
	}
	var want []flacBlock
	seenComment := false
	for _, blk := range orig {
		switch {
		case blk.kind == flacBlockPadding:
		case blk.kind == flacBlockVorbisComment && !seenComment:
			seenComment = true
		default:
			want = append(want, blk)
		}
	}
	if len(got) != len(want) {
		return wbErrf(wbErrTagsNotPreserved, "%d metadata blocks kept, expected %d", len(got), len(want))
	}
	for i := range got {
		if got[i].kind != want[i].kind || !bytes.Equal(got[i].body, want[i].body) {
			return wbErrf(wbErrTagsNotPreserved, "metadata block %d (type %d) changed", i, want[i].kind)
		}
	}
	if len(comments) == 0 {
		return wbErrf(wbErrTagsNotPreserved, "no VORBIS_COMMENT block")
	}
	gotVendor, entries, ok := parseVorbisComment(comments[0])
	if !ok || !bytes.Equal(gotVendor, vendor) {
		return wbErrf(wbErrTagsNotPreserved, "VORBIS_COMMENT vendor changed")
	}
	kept := vorbisKeptEntries(entries)
	if len(kept) != len(keptEntries) || len(entries)-len(kept) != 1 {
		return wbErrf(wbErrTagsNotPreserved, "VORBIS_COMMENT has %d kept and %d lyrics entries", len(kept), len(entries)-len(kept))
	}
	for i := range kept {
		if !bytes.Equal(kept[i], keptEntries[i]) {
			return wbErrf(wbErrTagsNotPreserved, "VORBIS_COMMENT entry %d changed", i)
		}
	}
	return nil
}
