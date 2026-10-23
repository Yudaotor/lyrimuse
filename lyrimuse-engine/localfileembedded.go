package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"math"
	"os"
	"strings"
	"unicode/utf16"
)

// 正在放的文件自己标签里的歌词:同目录没有同名 .lrc 时的退路(见 localFileLyrics)。写成 LRC(带时间标签)的优先 ——
// 不少中文歌曲文件把整份 LRC 塞在歌词字段里;没有才交不带时间的那份,由调用方当纯文本兜底(localFileLyricsFor)。
// 同一遍顺带取注释(网易云下载的文件在这里写曲目身份,见 neteasefilekey.go)。按扩展名认格式:
//   - MP3:开头的 ID3v2(v2.3 / v2.4;v2.2 三字母帧名不认)。SYLT 逐行带时间,换成 LRC;USLT;TXXX 里描述叫 LYRICS /
//     UNSYNCEDLYRICS / USLT 的(有的工具把歌词写成这种自定义帧)。注释是 COMM。
//   - AIFF / WAV:块里嵌着的那份 ID3v2(`ID3 ` / `id3 ` 块),同 MP3。
//   - FLAC:VORBIS_COMMENT 块;OGG / Opus:第二个包(Vorbis 的注释头、OpusTags)。都是 LYRICS / UNSYNCEDLYRICS 这类键,
//     注释是 COMMENT / DESCRIPTION。
//   - M4A / MP4:moov › udta › meta › ilst › ©lyr 的 data,注释是 ©cmt。

// localFileEmbeddedMaxTagBytes:标签区大过这个就不读(多半塞了大图,歌词帧不会这么大)。
const localFileEmbeddedMaxTagBytes = 16 << 20

// localFileTags:一个文件标签区里读到的歌词(带时间的优先)和各条注释。
type localFileTags struct {
	lyrics    string
	hasLyrics bool
	comments  []string
}

// localFileEmbeddedLyrics 按扩展名读文件标签里的歌词(带时间的优先);认不出的格式、没有能用的为 false。
func localFileEmbeddedLyrics(path string) (string, bool) {
	t := readLocalFileTags(path)
	return t.lyrics, t.hasLyrics
}

// readLocalFileTags 按扩展名读一遍文件的标签区,歌词和注释一起取;认不出的格式、读不了为零值。
func readLocalFileTags(path string) localFileTags {
	ext := strings.ToLower(strings.TrimPrefix(fileExt(path), "."))
	switch ext {
	case "mp3", "flac", "ogg", "oga", "opus", "m4a", "m4b", "mp4", "aif", "aiff", "aifc", "wav", "wave":
	default:
		return localFileTags{}
	}
	f, err := os.Open(path)
	if err != nil {
		noteFileErr("read", path, err)
		return localFileTags{}
	}
	defer f.Close()
	switch ext {
	case "mp3":
		return id3TagsAt(f)
	case "flac":
		return flacTags(f)
	case "ogg", "oga", "opus":
		return oggTags(f)
	case "m4a", "m4b", "mp4":
		return mp4Tags(f)
	default:
		return chunkedID3Tags(f, ext == "wav" || ext == "wave")
	}
}

// id3TagsAt:从读写位置开始是一份 ID3v2 标签(10 字节头 + 标签区)时读里面的歌词和注释。
func id3TagsAt(r io.Reader) localFileTags {
	header := make([]byte, 10)
	if _, err := io.ReadFull(r, header); err != nil || !bytes.HasPrefix(header, []byte("ID3")) {
		return localFileTags{}
	}
	size := syncsafeInt(header[6:10])
	if size <= 0 || size > localFileEmbeddedMaxTagBytes {
		return localFileTags{}
	}
	tag := make([]byte, size)
	if _, err := io.ReadFull(r, tag); err != nil {
		return localFileTags{}
	}
	return tagsFromID3(header, tag)
}

// chunkedID3Tags:AIFF(FORM,块长大端)/ WAV(RIFF,块长小端)里 `ID3 ` / `id3 ` 块装着的 ID3v2。
func chunkedID3Tags(f io.ReadSeeker, riff bool) localFileTags {
	head := make([]byte, 12)
	if _, err := io.ReadFull(f, head); err != nil {
		return localFileTags{}
	}
	if riff && (string(head[:4]) != "RIFF" || string(head[8:12]) != "WAVE") {
		return localFileTags{}
	}
	if !riff && (string(head[:4]) != "FORM" || (string(head[8:12]) != "AIFF" && string(head[8:12]) != "AIFC")) {
		return localFileTags{}
	}
	for {
		ch := make([]byte, 8)
		if _, err := io.ReadFull(f, ch); err != nil {
			return localFileTags{}
		}
		var size uint32
		if riff {
			size = binary.LittleEndian.Uint32(ch[4:8])
		} else {
			size = binary.BigEndian.Uint32(ch[4:8])
		}
		if id := string(ch[:4]); id == "ID3 " || id == "id3 " {
			if size > localFileEmbeddedMaxTagBytes {
				return localFileTags{}
			}
			return id3TagsAt(io.LimitReader(f, int64(size)))
		}
		if _, err := f.Seek(int64(size)+int64(size&1), io.SeekCurrent); err != nil {
			return localFileTags{}
		}
	}
}

// flacTags:FLAC 元数据块里的 VORBIS_COMMENT(类型 4);图片之类的块跳过。
func flacTags(f io.ReadSeeker) localFileTags {
	magic := make([]byte, 4)
	if _, err := io.ReadFull(f, magic); err != nil || string(magic) != "fLaC" {
		return localFileTags{}
	}
	for {
		bh := make([]byte, 4)
		if _, err := io.ReadFull(f, bh); err != nil {
			return localFileTags{}
		}
		last, kind := bh[0]&0x80 != 0, bh[0]&0x7F
		size := int(bh[1])<<16 | int(bh[2])<<8 | int(bh[3])
		if kind == 4 {
			body := make([]byte, size)
			if _, err := io.ReadFull(f, body); err != nil {
				return localFileTags{}
			}
			return tagsFromVorbisComment(body)
		}
		if last {
			return localFileTags{}
		}
		if _, err := f.Seek(int64(size), io.SeekCurrent); err != nil {
			return localFileTags{}
		}
	}
}

// oggTags:OGG 第一个逻辑流的第二个包(Vorbis 注释头 `\x03vorbis`、Opus 的 `OpusTags`)。包可能跨页,按分段表拼。
func oggTags(f io.Reader) localFileTags {
	var packets [][]byte
	var cur []byte
	read := 0
	for len(packets) < 2 {
		h := make([]byte, 27)
		if _, err := io.ReadFull(f, h); err != nil || string(h[:4]) != "OggS" {
			return localFileTags{}
		}
		segs := make([]byte, h[26])
		if _, err := io.ReadFull(f, segs); err != nil {
			return localFileTags{}
		}
		total := 0
		for _, s := range segs {
			total += int(s)
		}
		data := make([]byte, total)
		if _, err := io.ReadFull(f, data); err != nil {
			return localFileTags{}
		}
		if read += 27 + len(segs) + total; read > localFileEmbeddedMaxTagBytes {
			return localFileTags{}
		}
		off := 0
		for _, s := range segs {
			cur = append(cur, data[off:off+int(s)]...)
			off += int(s)
			if s < 255 {
				packets = append(packets, cur)
				cur = nil
			}
		}
	}
	p := packets[1]
	switch {
	case bytes.HasPrefix(p, []byte("\x03vorbis")):
		return tagsFromVorbisComment(p[7:])
	case bytes.HasPrefix(p, []byte("OpusTags")):
		return tagsFromVorbisComment(p[8:])
	}
	return localFileTags{}
}

// tagsFromVorbisComment:厂商串 + 若干条「键=值」(长度都是小端 32 位)。键不分大小写,歌词认 LYRICS / UNSYNCEDLYRICS /
// UNSYNCED LYRICS,注释认 COMMENT / DESCRIPTION。纯函数,单测覆盖。
func tagsFromVorbisComment(b []byte) localFileTags {
	next := func() ([]byte, bool) {
		if len(b) < 4 {
			return nil, false
		}
		n := int(binary.LittleEndian.Uint32(b[:4]))
		if n < 0 || n > len(b)-4 {
			return nil, false
		}
		v := b[4 : 4+n]
		b = b[4+n:]
		return v, true
	}
	var out localFileTags
	if _, ok := next(); !ok {
		return out
	}
	if len(b) < 4 {
		return out
	}
	count := int(binary.LittleEndian.Uint32(b[:4]))
	b = b[4:]
	var timed, plain string
	for i := 0; i < count; i++ {
		c, ok := next()
		if !ok {
			break
		}
		key, value, found := bytes.Cut(c, []byte("="))
		if !found {
			continue
		}
		if isCommentTagKey(string(key)) {
			if text, ok := decodeLyricBytes(value); ok && strings.TrimSpace(text) != "" {
				out.comments = append(out.comments, text)
			}
			continue
		}
		if !isLyricsTagKey(string(key)) {
			continue
		}
		text, ok := decodeLyricBytes(value)
		if !ok {
			continue
		}
		if localFileLRCTimestamp.MatchString(text) {
			if timed == "" {
				timed = text
			}
			continue
		}
		if plain == "" && strings.TrimSpace(text) != "" {
			plain = text
		}
	}
	out.lyrics = timed
	if out.lyrics == "" {
		out.lyrics = plain
	}
	out.hasLyrics = out.lyrics != ""
	return out
}

func isCommentTagKey(key string) bool {
	switch strings.ToUpper(strings.TrimSpace(key)) {
	case "COMMENT", "DESCRIPTION":
		return true
	}
	return false
}

func isLyricsTagKey(key string) bool {
	switch strings.ToUpper(strings.TrimSpace(key)) {
	case "LYRICS", "UNSYNCEDLYRICS", "UNSYNCED LYRICS", "USLT":
		return true
	}
	return false
}

// mp4Tags:顶层找 moov(mdat 跳过,moov 在文件末尾也找得到),再顺着 udta › meta › ilst 往下。
func mp4Tags(f io.ReadSeeker) localFileTags {
	for {
		kind, size, err := mp4AtomHeader(f)
		if err != nil {
			return localFileTags{}
		}
		if kind == "moov" {
			if size < 0 {
				// 长度 0:moov 一直到文件末尾,读到末尾为止,同样不超过上限。
				body, err := io.ReadAll(io.LimitReader(f, localFileEmbeddedMaxTagBytes+1))
				if err != nil || len(body) > localFileEmbeddedMaxTagBytes {
					return localFileTags{}
				}
				return tagsFromMP4Moov(body)
			}
			if size > localFileEmbeddedMaxTagBytes {
				return localFileTags{}
			}
			body := make([]byte, size)
			if _, err := io.ReadFull(f, body); err != nil {
				return localFileTags{}
			}
			return tagsFromMP4Moov(body)
		}
		if size < 0 {
			return localFileTags{}
		}
		if _, err := f.Seek(size, io.SeekCurrent); err != nil {
			return localFileTags{}
		}
	}
}

// mp4AtomHeader:读一个原子头,交回类型和正文长度(去掉头);64 位长度也认,长度 0(到文件末尾)交回 -1。
// 头里写的长度比头本身还短、或 64 位长度超出 int64 的,当坏文件报错 —— 交回的长度只会是 -1 或非负数。
func mp4AtomHeader(r io.Reader) (string, int64, error) {
	h := make([]byte, 8)
	if _, err := io.ReadFull(r, h); err != nil {
		return "", 0, err
	}
	size := int64(binary.BigEndian.Uint32(h[:4]))
	kind := string(h[4:8])
	switch size {
	case 0:
		return kind, -1, nil
	case 1:
		ext := make([]byte, 8)
		if _, err := io.ReadFull(r, ext); err != nil {
			return "", 0, err
		}
		n := binary.BigEndian.Uint64(ext)
		if n < 16 || n > math.MaxInt64 {
			return "", 0, fmt.Errorf("mp4 atom %q has bad 64-bit size %d", kind, n)
		}
		return kind, int64(n) - 16, nil
	}
	if size < 8 {
		return "", 0, fmt.Errorf("mp4 atom %q too short", kind)
	}
	return kind, size - 8, nil
}

// tagsFromMP4Moov:moov 正文里 udta › meta(正文前有 4 字节版本标志)› ilst,歌词是 ©lyr、注释是 ©cmt,各自 › data(正文前
// 8 字节类型与地区)。纯函数,单测覆盖。
func tagsFromMP4Moov(moov []byte) localFileTags {
	var out localFileTags
	ilst := moov
	for _, step := range []struct {
		kind string
		skip int
	}{{"udta", 0}, {"meta", 4}, {"ilst", 0}} {
		body, ok := mp4Child(ilst, step.kind)
		if !ok || len(body) < step.skip {
			return out
		}
		ilst = body[step.skip:]
	}
	text := func(item string) (string, bool) {
		atom, ok := mp4Child(ilst, item)
		if !ok {
			return "", false
		}
		data, ok := mp4Child(atom, "data")
		if !ok || len(data) < 8 {
			return "", false
		}
		s, ok := decodeLyricBytes(data[8:])
		return s, ok && strings.TrimSpace(s) != ""
	}
	out.lyrics, out.hasLyrics = text("\xa9lyr")
	if c, ok := text("\xa9cmt"); ok {
		out.comments = append(out.comments, c)
	}
	return out
}

// mp4Child:在一串原子里找第一个类型对得上的,交回它的正文。
func mp4Child(b []byte, kind string) ([]byte, bool) {
	for len(b) >= 8 {
		size := int(binary.BigEndian.Uint32(b[:4]))
		if size < 8 || size > len(b) {
			return nil, false
		}
		if string(b[4:8]) == kind {
			return b[8:size], true
		}
		b = b[size:]
	}
	return nil, false
}

func fileExt(path string) string {
	if i := strings.LastIndexByte(path, '.'); i >= 0 && !strings.ContainsRune(path[i:], '/') {
		return path[i:]
	}
	return ""
}

// tagsFromID3:标签头(10 字节)和标签区 → 歌词和注释。纯函数,单测覆盖。
func tagsFromID3(header, tag []byte) localFileTags {
	var out localFileTags
	version, flags := header[3], header[5]
	if version != 3 && version != 4 {
		return out
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
	var timed, plain string
	fromSYLT := false
	keep := func(text string) {
		switch {
		case localFileLRCTimestamp.MatchString(text):
			if timed == "" {
				timed = text
			}
		case plain == "" && strings.TrimSpace(text) != "":
			plain = text
		}
	}
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
			// 第一份 SYLT 压过别的歌词帧,排在它前面的也一样。
			if lrc, ok := lrcFromSYLT(body); ok && !fromSYLT {
				timed, fromSYLT = lrc, true
			}
		case "COMM":
			// 同 USLT 的布局:编码 + 语言 + 描述 + 正文。
			if text, ok := textFromUSLT(body); ok && strings.TrimSpace(text) != "" {
				out.comments = append(out.comments, text)
			}
		case "USLT":
			if text, ok := textFromUSLT(body); ok {
				keep(text)
			}
		case "TXXX":
			// 自定义帧:描述是歌词那几个键的当歌词,是 comment / description 的当注释(ffmpeg 这类工具重写标签时注释存成这样)。
			desc, text, ok := textFromTXXX(body)
			switch {
			case !ok:
			case isLyricsTagKey(desc):
				keep(text)
			case isCommentTagKey(desc) && strings.TrimSpace(text) != "":
				out.comments = append(out.comments, text)
			}
		}
		pos += 10 + size
	}
	out.lyrics = timed
	if out.lyrics == "" {
		out.lyrics = plain
	}
	out.hasLyrics = out.lyrics != ""
	return out
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

// textFromTXXX 取 TXXX 帧的描述和正文。帧正文是编码(1) + 描述(以编码对应的结束符收尾) + 正文。
func textFromTXXX(body []byte) (desc, text string, ok bool) {
	if len(body) < 2 {
		return "", "", false
	}
	enc := body[0]
	descRaw, rest, ok := splitID3Terminated(enc, body[1:])
	if !ok {
		return "", "", false
	}
	if desc, ok = decodeID3Text(enc, descRaw); !ok {
		return "", "", false
	}
	if text, ok = decodeID3Text(enc, rest); !ok {
		return "", "", false
	}
	return desc, text, true
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
