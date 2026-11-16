package main

import (
	"bytes"
	"encoding/binary"
	"io"
)

// WAV / AIFF 的歌词写回:ID3v2 标签放在 RIFF / FORM 里的 ID3 块("ID3 " 或 "id3 ",读法 chunkedID3Tags 认的那个),
// 块里的标签照 MP3 那套改(id3EditTag)。
//   - 已有 ID3 块就整块换掉,块名、标签之后的块内字节原样;没有就在 RIFF / FORM 末尾新加一块(WAV 写 "id3 "、AIFF
//     写 "ID3 ",同 mutagen)。标签区变长多少,文件头的 RIFF / FORM 长度就跟着加多少;别的块一个字节不动、不挪顺序。
//   - 块走不齐(块长越界、最后一块没落在 RIFF / FORM 末尾)、有两个 ID3 块、RF64 / RIFX、块里不是 ID3v2 的不写。
// 见 11 章决策 173。

const (
	chunkMaxCount = 4096
)

// riffKind:WAV(小端 RIFF)或 AIFF(大端 FORM)。
type riffKind struct {
	magic     string
	forms     []string
	bigEndian bool
	newID     string
}

var (
	wavChunks  = riffKind{magic: "RIFF", forms: []string{"WAVE"}, newID: "id3 "}
	aiffChunks = riffKind{magic: "FORM", forms: []string{"AIFF", "AIFC"}, bigEndian: true, newID: "ID3 "}
)

func wavWritebackLayout(r io.ReadSeeker, fileSize int64) (lyricsTagLayout, error) {
	return chunkWritebackLayout(r, fileSize, wavChunks)
}

func aiffWritebackLayout(r io.ReadSeeker, fileSize int64) (lyricsTagLayout, error) {
	return chunkWritebackLayout(r, fileSize, aiffChunks)
}

func (k riffKind) u32(b []byte) uint32 {
	if k.bigEndian {
		return binary.BigEndian.Uint32(b)
	}
	return binary.LittleEndian.Uint32(b)
}

func (k riffKind) put32(b []byte, v uint32) {
	if k.bigEndian {
		binary.BigEndian.PutUint32(b, v)
	} else {
		binary.LittleEndian.PutUint32(b, v)
	}
}

// chunkWritebackLayout 走一遍顶层块,找出 ID3 块(没有就定在 RIFF / FORM 末尾新加)。
func chunkWritebackLayout(r io.ReadSeeker, fileSize int64, k riffKind) (lyricsTagLayout, error) {
	head := make([]byte, 12)
	if _, err := io.ReadFull(r, head); err != nil || string(head[:4]) != k.magic {
		return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "file does not start with %s", k.magic)
	}
	formOK := false
	for _, f := range k.forms {
		formOK = formOK || string(head[8:12]) == f
	}
	if !formOK {
		return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "%s form type %q", k.magic, head[8:12])
	}
	formSize := k.u32(head[4:8])
	end := 8 + int64(formSize)
	if end > fileSize {
		return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "%s size overruns the file", k.magic)
	}
	tagStart, tagEnd := int64(-1), int64(-1)
	var tagID string
	pos := int64(12)
	for i := 0; pos < end; i++ {
		if i >= chunkMaxCount || pos+8 > end {
			return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "chunk list does not end at the %s size", k.magic)
		}
		ch := make([]byte, 8)
		if _, err := r.Seek(pos, io.SeekStart); err != nil {
			return lyricsTagLayout{}, wbErr(wbErrIO, err)
		}
		if _, err := io.ReadFull(r, ch); err != nil {
			return lyricsTagLayout{}, wbErr(wbErrIO, err)
		}
		size := int64(k.u32(ch[4:8]))
		next := pos + 8 + size
		if next > end {
			return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "chunk %q overruns the %s size", ch[:4], k.magic)
		}
		if size&1 == 1 && next < end {
			next++
		}
		if id := string(ch[:4]); id == "ID3 " || id == "id3 " {
			if tagStart >= 0 {
				return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "two ID3 chunks")
			}
			if size > localFileEmbeddedMaxTagBytes {
				return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "ID3 chunk size %d", size)
			}
			tagStart, tagEnd, tagID = pos, next, id
		}
		pos = next
	}
	if tagStart < 0 {
		if end&1 == 1 {
			return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "%s ends on an odd offset", k.magic)
		}
		tagStart, tagEnd, tagID = end, end, k.newID
	}
	region := make([]byte, tagEnd-tagStart)
	if _, err := r.Seek(tagStart, io.SeekStart); err != nil {
		return lyricsTagLayout{}, wbErr(wbErrIO, err)
	}
	if _, err := io.ReadFull(r, region); err != nil {
		return lyricsTagLayout{}, wbErr(wbErrIO, err)
	}
	var tag, trailing []byte
	if len(region) > 0 {
		size := int(k.u32(region[4:8]))
		payload := region[8 : 8+size]
		if len(payload) < 10 || !bytes.HasPrefix(payload, []byte("ID3")) {
			return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "ID3 chunk does not hold an ID3v2 tag")
		}
		n, err := id3TagLen(payload[:10])
		if err != nil {
			return lyricsTagLayout{}, err
		}
		if n > len(payload) {
			return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "ID3 tag overruns its chunk")
		}
		tag, trailing = payload[:n], payload[n:]
	}
	edit, err := id3EditTag(tag, fileSize-int64(len(region)))
	if err != nil {
		return lyricsTagLayout{}, err
	}
	return lyricsTagLayout{
		head:        region,
		regionStart: tagStart,
		audioStart:  tagEnd,
		hasLyrics:   edit.hasLyrics,
		sizeField:   &lyricsSizeField{offset: 4, bigEndian: k.bigEndian, value: formSize},
		build: func(text string) ([]byte, error) {
			newTag, err := edit.build(text)
			if err != nil {
				return nil, err
			}
			return k.chunk(tagID, append(newTag, trailing...)), nil
		},
		preserved: func(newHead []byte) error {
			if len(newHead) < 8 || string(newHead[:4]) != tagID {
				return wbErrf(wbErrTagsNotPreserved, "ID3 chunk id changed")
			}
			size := int(k.u32(newHead[4:8]))
			if 8+size+size&1 != len(newHead) || size&1 == 1 && newHead[len(newHead)-1] != 0 {
				return wbErrf(wbErrTagsNotPreserved, "ID3 chunk size %d does not fit %d bytes", size, len(newHead))
			}
			payload := newHead[8 : 8+size]
			if len(payload) < 10 {
				return wbErrf(wbErrTagsNotPreserved, "ID3 chunk too short")
			}
			n, err := id3TagLen(payload[:10])
			if err != nil || n > len(payload) {
				return wbErrf(wbErrTagsNotPreserved, "bad ID3 tag in the chunk")
			}
			if !bytes.Equal(payload[n:], trailing) {
				return wbErrf(wbErrTagsNotPreserved, "bytes after the ID3 tag in its chunk changed")
			}
			return edit.preserved(payload[:n])
		},
	}, nil
}

// chunk 拼一个块:块名 + 长度 + 正文,长度为奇数时补一个 0。
func (k riffKind) chunk(id string, payload []byte) []byte {
	out := make([]byte, 8, 8+len(payload)+1)
	copy(out, id)
	k.put32(out[4:8], uint32(len(payload)))
	out = append(out, payload...)
	if len(payload)&1 == 1 {
		out = append(out, 0)
	}
	return out
}
