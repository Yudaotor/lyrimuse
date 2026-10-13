package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"strings"
	"unicode/utf16"
)

// 正在放的 MP3 自己 ID3v2 标签里的歌词:同目录没有同名 .lrc 时的退路(见 localFileLyrics)。
// USLT 只收写成 LRC(带时间标签)的那种 —— 不少中文 MP3 把整份 LRC 塞在这一帧里;纯文本对不上时间,不要。
// SYLT 是逐行带时间的,换成 LRC。只认 ID3v2.3 / v2.4;v2.2(三字母帧名)不认。

// localFileEmbeddedMaxTagBytes:标签区大过这个就不读(多半塞了大图,歌词帧不会这么大)。
const localFileEmbeddedMaxTagBytes = 16 << 20

// localFileEmbeddedLyrics 读 MP3 的 ID3v2 标签,先 SYLT、后 USLT;都没有能用的为 false。
func localFileEmbeddedLyrics(path string) (string, bool) {
	if !strings.EqualFold(strings.TrimPrefix(fileExt(path), "."), "mp3") {
		return "", false
	}
	f, err := os.Open(path)
	if err != nil {
		noteFileErr("read", path, err)
		return "", false
	}
	defer f.Close()
	header := make([]byte, 10)
	if _, err := io.ReadFull(f, header); err != nil || !bytes.HasPrefix(header, []byte("ID3")) {
		return "", false
	}
	size := syncsafeInt(header[6:10])
	if size <= 0 || size > localFileEmbeddedMaxTagBytes {
		return "", false
	}
	tag := make([]byte, size)
	if _, err := io.ReadFull(f, tag); err != nil {
		return "", false
	}
	return embeddedLyricsFromID3(header, tag)
}

func fileExt(path string) string {
	if i := strings.LastIndexByte(path, '.'); i >= 0 && !strings.ContainsRune(path[i:], '/') {
		return path[i:]
	}
	return ""
}

// embeddedLyricsFromID3:标签头(10 字节)和标签区 → 歌词。纯函数,单测覆盖。
func embeddedLyricsFromID3(header, tag []byte) (string, bool) {
	version, flags := header[3], header[5]
	if version != 3 && version != 4 {
		return "", false
	}
	if flags&0x80 != 0 {
		// 整个标签做过反同步:0xFF 0x00 还原成 0xFF。
		tag = bytes.ReplaceAll(tag, []byte{0xFF, 0x00}, []byte{0xFF})
	}
	pos := 0
	if flags&0x40 != 0 && len(tag) >= 4 {
		// 扩展头:v2.4 的长度含自己、是同步安全整数;v2.3 的不含那 4 字节。
		if version == 4 {
			pos = syncsafeInt(tag[:4])
		} else {
			pos = int(binary.BigEndian.Uint32(tag[:4])) + 4
		}
	}
	var unsynced string
	for pos+10 <= len(tag) {
		id := string(tag[pos : pos+4])
		if tag[pos] == 0 {
			break
		}
		var size int
		if version == 4 {
			size = syncsafeInt(tag[pos+4 : pos+8])
		} else {
			size = int(binary.BigEndian.Uint32(tag[pos+4 : pos+8]))
		}
		body := tag[pos+10:]
		if size < 0 || size > len(body) {
			break
		}
		body = body[:size]
		switch id {
		case "SYLT":
			if lrc, ok := lrcFromSYLT(body); ok {
				return lrc, true
			}
		case "USLT":
			if unsynced == "" {
				if text, ok := textFromUSLT(body); ok && localFileLRCTimestamp.MatchString(text) {
					unsynced = text
				}
			}
		}
		pos += 10 + size
	}
	return unsynced, unsynced != ""
}

func syncsafeInt(b []byte) int {
	return int(b[0]&0x7F)<<21 | int(b[1]&0x7F)<<14 | int(b[2]&0x7F)<<7 | int(b[3]&0x7F)
}

// textFromUSLT:编码(1) + 语言(3) + 描述(以编码对应的结束符收尾) + 正文。
func textFromUSLT(body []byte) (string, bool) {
	if len(body) < 4 {
		return "", false
	}
	enc := body[0]
	_, rest, ok := splitID3Terminated(enc, body[4:])
	if !ok {
		return "", false
	}
	return decodeID3Text(enc, rest)
}

// lrcFromSYLT:编码(1) + 语言(3) + 时间格式(1,2 = 毫秒) + 内容类型(1) + 描述 + 若干组(文字 + 结束符 + 4 字节时间)。
func lrcFromSYLT(body []byte) (string, bool) {
	if len(body) < 6 || body[4] != 2 {
		return "", false
	}
	enc := body[0]
	_, rest, ok := splitID3Terminated(enc, body[6:])
	if !ok {
		return "", false
	}
	var b strings.Builder
	lines := 0
	for len(rest) > 0 {
		raw, after, ok := splitID3Terminated(enc, rest)
		if !ok || len(after) < 4 {
			break
		}
		ms := binary.BigEndian.Uint32(after[:4])
		rest = after[4:]
		text, ok := decodeID3Text(enc, raw)
		if !ok {
			continue
		}
		text = strings.TrimSpace(strings.TrimLeft(text, "\n"))
		fmt.Fprintf(&b, "[%02d:%02d.%02d]%s\n", ms/60000, ms/1000%60, ms%1000/10, text)
		lines++
	}
	return b.String(), lines > 0
}

// splitID3Terminated:按编码找结束符(Latin-1 / UTF-8 一个 0,UTF-16 两个 0 且对齐),交回结束符之前和之后。
func splitID3Terminated(enc byte, b []byte) (head, rest []byte, ok bool) {
	if enc == 1 || enc == 2 {
		for i := 0; i+1 < len(b); i += 2 {
			if b[i] == 0 && b[i+1] == 0 {
				return b[:i], b[i+2:], true
			}
		}
		return nil, nil, false
	}
	i := bytes.IndexByte(b, 0)
	if i < 0 {
		return b, nil, true
	}
	return b[:i], b[i+1:], true
}

// decodeID3Text:0 = 标为 Latin-1 —— 中文 MP3 常把 GBK 字节写在这一档,交给 decodeLyricBytes(合法 UTF-8 原样、别的按
// GB18030 转;纯 ASCII 两种解法一样);1 = 带 BOM 的 UTF-16;2 = UTF-16BE;3 = UTF-8。
func decodeID3Text(enc byte, b []byte) (string, bool) {
	switch enc {
	case 0, 3:
		return decodeLyricBytes(bytes.TrimRight(b, "\x00"))
	case 1, 2:
		big := enc == 2
		if len(b) >= 2 && b[0] == 0xFF && b[1] == 0xFE {
			big, b = false, b[2:]
		} else if len(b) >= 2 && b[0] == 0xFE && b[1] == 0xFF {
			big, b = true, b[2:]
		}
		units := make([]uint16, 0, len(b)/2)
		for i := 0; i+1 < len(b); i += 2 {
			if big {
				units = append(units, uint16(b[i])<<8|uint16(b[i+1]))
			} else {
				units = append(units, uint16(b[i+1])<<8|uint16(b[i]))
			}
		}
		return strings.TrimRight(string(utf16.Decode(units)), "\x00"), true
	}
	return "", false
}
