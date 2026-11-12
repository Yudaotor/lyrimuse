package main

import (
	"bytes"
	"encoding/binary"
	"io"
	"unicode/utf16"
)

// MP3 的歌词写回:文件开头的 ID3v2 标签里写一个 USLT 帧(描述留空),纯文本和 LRC 都写进它;不另写 SYLT。
//   - 原来是 v2.4 的保持 v2.4,正文 UTF-8;原来是 v2.3 的保持 v2.3,正文用带 BOM 的 UTF-16(v2.3 没有 UTF-8 这一档)。
//     原来没有标签的新建 v2.4。v2.2、v2.4 整个标签做过反同步的不写(wbErrUnsupportedTag)。
//   - 原有的歌词帧(USLT、SYLT、描述是歌词键的 TXXX)全部去掉,换成这一个;别的帧原样、按原顺序留着。语言沿用
//     原来第一个 USLT 的,没有就写 eng。
//   - 扩展头、标签尾不写回;v2.3 整个标签反同步过的,写回时不再反同步。
//   - 新帧放得进原标签区就用掉 padding、标签区总长不变;放不下整个标签变长,新留 writebackPadding 那么多 padding。

const id3WritebackDefaultLang = "eng"

// id3RawFrame:一帧原样的字节(10 字节帧头 + 帧正文)。
type id3RawFrame struct {
	id  string
	raw []byte
}

// id3WritebackLayout 读文件开头的 ID3v2 标签;没有标签时标签区为空。
func id3WritebackLayout(r io.ReadSeeker, fileSize int64) (lyricsTagLayout, error) {
	header := make([]byte, 10)
	n, err := io.ReadFull(r, header)
	if err != nil && err != io.ErrUnexpectedEOF && err != io.EOF {
		return lyricsTagLayout{}, wbErr(wbErrIO, err)
	}
	if n < 10 || !bytes.HasPrefix(header, []byte("ID3")) {
		return id3NewTagLayout(fileSize), nil
	}
	version, flags := header[3], header[5]
	switch {
	case version == 2:
		return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "ID3v2.2")
	case version != 3 && version != 4:
		return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "ID3v2.%d", version)
	case version == 4 && flags&0x80 != 0:
		return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "ID3v2.4 whole-tag unsynchronisation")
	}
	size := syncsafeInt(header[6:10])
	headLen := 10 + int64(size)
	if version == 4 && flags&0x10 != 0 {
		headLen += 10
	}
	if size > localFileEmbeddedMaxTagBytes || headLen > fileSize {
		return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "ID3 tag size %d", size)
	}
	head := make([]byte, headLen)
	copy(head, header)
	if _, err := io.ReadFull(r, head[10:]); err != nil {
		return lyricsTagLayout{}, wbErr(wbErrIO, err)
	}
	frames, err := id3Frames(version, flags, head[10:10+size])
	if err != nil {
		return lyricsTagLayout{}, err
	}
	lang := id3WritebackDefaultLang
	for _, f := range frames {
		if f.id == "USLT" && len(f.raw) >= 14 && isASCIILetters(f.raw[11:14]) {
			lang = string(f.raw[11:14])
			break
		}
	}
	kept := id3KeptFrames(frames)
	audio := fileSize - headLen
	return lyricsTagLayout{
		head:       head,
		audioStart: headLen,
		hasLyrics:  tagsFromID3(header, head[10:10+size]).hasLyrics,
		build: func(text string) ([]byte, error) {
			return id3BuildTag(version, kept, id3USLTFrame(version, lang, text), len(head), audio)
		},
		preserved: func(newHead []byte) error {
			return id3PreservedErr(kept, newHead)
		},
	}, nil
}

// id3NewTagLayout:文件开头没有 ID3v2 标签,写回时新建一份 v2.4。
func id3NewTagLayout(fileSize int64) lyricsTagLayout {
	return lyricsTagLayout{
		audioStart: 0,
		build: func(text string) ([]byte, error) {
			return id3BuildTag(4, nil, id3USLTFrame(4, id3WritebackDefaultLang, text), 0, fileSize)
		},
		preserved: func(newHead []byte) error {
			return id3PreservedErr(nil, newHead)
		},
	}
}

// id3Frames 拆标签区里的帧(不含 10 字节标签头),遇到 padding(0 字节)为止。帧长越界、padding 里有非 0 字节当损坏。
func id3Frames(version, flags byte, tag []byte) ([]id3RawFrame, error) {
	if flags&0x80 != 0 {
		tag = bytes.ReplaceAll(tag, []byte{0xFF, 0x00}, []byte{0xFF})
	}
	pos := 0
	if flags&0x40 != 0 {
		if len(tag) < 4 {
			return nil, wbErrf(wbErrUnsupportedTag, "truncated extended header")
		}
		if version == 4 {
			pos = syncsafeInt(tag[:4])
		} else {
			pos = int(binary.BigEndian.Uint32(tag[:4])) + 4
		}
		if pos < 0 || pos > len(tag) {
			return nil, wbErrf(wbErrUnsupportedTag, "bad extended header")
		}
	}
	var frames []id3RawFrame
	for pos < len(tag) && tag[pos] != 0 {
		if pos+10 > len(tag) {
			return nil, wbErrf(wbErrUnsupportedTag, "truncated frame header")
		}
		var size int
		if version == 4 {
			size = syncsafeInt(tag[pos+4 : pos+8])
		} else {
			size = int(binary.BigEndian.Uint32(tag[pos+4 : pos+8]))
		}
		if size < 0 || size > len(tag)-pos-10 {
			return nil, wbErrf(wbErrUnsupportedTag, "frame %q overruns the tag", tag[pos:pos+4])
		}
		frames = append(frames, id3RawFrame{id: string(tag[pos : pos+4]), raw: tag[pos : pos+10+size]})
		pos += 10 + size
	}
	for _, b := range tag[pos:] {
		if b != 0 {
			return nil, wbErrf(wbErrUnsupportedTag, "garbage after the frames")
		}
	}
	return frames, nil
}

// id3KeptFrames:写回时原样留下的帧,即歌词帧以外的全部。
func id3KeptFrames(frames []id3RawFrame) []id3RawFrame {
	var kept []id3RawFrame
	for _, f := range frames {
		if !id3IsLyricsFrame(f) {
			kept = append(kept, f)
		}
	}
	return kept
}

// id3IsLyricsFrame:USLT、SYLT,以及描述是歌词键(isLyricsTagKey)的 TXXX。
func id3IsLyricsFrame(f id3RawFrame) bool {
	switch f.id {
	case "USLT", "SYLT":
		return true
	case "TXXX":
		desc, _, ok := textFromTXXX(f.raw[10:])
		return ok && isLyricsTagKey(desc)
	}
	return false
}

// id3USLTFrame 拼一个 USLT 帧:编码 + 语言 + 空描述 + 正文。
func id3USLTFrame(version byte, lang, text string) []byte {
	var body []byte
	if version == 4 {
		body = append([]byte{3}, lang...)
		body = append(body, 0)
		body = append(body, text...)
	} else {
		body = append([]byte{1}, lang...)
		body = append(body, 0xFF, 0xFE, 0, 0, 0xFF, 0xFE)
		for _, u := range utf16.Encode([]rune(text)) {
			body = append(body, byte(u), byte(u>>8))
		}
	}
	frame := make([]byte, 10, 10+len(body))
	copy(frame, "USLT")
	if version == 4 {
		putSyncsafe(frame[4:8], len(body))
	} else {
		binary.BigEndian.PutUint32(frame[4:8], uint32(len(body)))
	}
	return append(frame, body...)
}

// id3BuildTag 拼整个标签(标签头 + 留下的帧 + 新歌词帧 + padding)。frames 放得进 oldLen 就补 padding 到 oldLen,
// 否则新留 writebackPadding。
func id3BuildTag(version byte, kept []id3RawFrame, lyricsFrame []byte, oldLen int, audioBytes int64) ([]byte, error) {
	var frames []byte
	for _, f := range kept {
		frames = append(frames, f.raw...)
	}
	frames = append(frames, lyricsFrame...)
	total := oldLen
	if 10+len(frames) > oldLen {
		total = 10 + len(frames) + writebackPadding(audioBytes)
	}
	if total-10 > 0x0FFFFFFF {
		return nil, wbErrf(wbErrUnsupportedTag, "tag would exceed the ID3 size limit")
	}
	tag := make([]byte, total)
	copy(tag, "ID3")
	tag[3], tag[4], tag[5] = version, 0, 0
	putSyncsafe(tag[6:10], total-10)
	copy(tag[10:], frames)
	return tag, nil
}

// id3PreservedErr:新标签里歌词以外的帧跟 kept 逐字节相同、顺序一致,而且恰好有一个歌词帧(USLT)。
func id3PreservedErr(kept []id3RawFrame, newHead []byte) error {
	if len(newHead) < 10 || !bytes.HasPrefix(newHead, []byte("ID3")) {
		return wbErrf(wbErrTagsNotPreserved, "no ID3 header")
	}
	version, flags := newHead[3], newHead[5]
	size := syncsafeInt(newHead[6:10])
	if 10+size > len(newHead) {
		return wbErrf(wbErrTagsNotPreserved, "bad tag size")
	}
	frames, err := id3Frames(version, flags, newHead[10:10+size])
	if err != nil {
		return wbErr(wbErrTagsNotPreserved, err)
	}
	got := id3KeptFrames(frames)
	if len(got) != len(kept) {
		return wbErrf(wbErrTagsNotPreserved, "%d frames kept, expected %d", len(got), len(kept))
	}
	for i := range got {
		if !bytes.Equal(got[i].raw, kept[i].raw) {
			return wbErrf(wbErrTagsNotPreserved, "frame %d (%s) changed", i, kept[i].id)
		}
	}
	if lyrics := len(frames) - len(got); lyrics != 1 {
		return wbErrf(wbErrTagsNotPreserved, "%d lyrics frames", lyrics)
	}
	return nil
}

func putSyncsafe(b []byte, n int) {
	b[0], b[1], b[2], b[3] = byte(n>>21&0x7F), byte(n>>14&0x7F), byte(n>>7&0x7F), byte(n&0x7F)
}

func isASCIILetters(b []byte) bool {
	for _, c := range b {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z') {
			return false
		}
	}
	return len(b) > 0
}
