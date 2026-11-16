package main

import (
	"bytes"
	"encoding/binary"
	"io"
	"unicode/utf16"
)

// MP3 的歌词写回:文件开头的 ID3v2 标签里写一个 USLT 帧(描述留空),纯文本和 LRC 都写进它;不另写 SYLT。
// WAV / AIFF 的 ID3 块(lyricswritebackchunk.go)用同一套(id3EditTag)。
//   - 原来是 v2.4 的保持 v2.4,正文 UTF-8;原来是 v2.3 的保持 v2.3,正文用带 BOM 的 UTF-16(v2.3 没有 UTF-8 这一档)。
//     原来没有标签的新建 v2.4。v2.4 整个标签做过反同步的不写(wbErrUnsupportedTag)。
//   - v2.2 升成 v2.4(id3UpgradeV22):三字母帧名按 id3v22To24 换成四字母、PIC 换成 APIC,别的帧正文原样;
//     v2.4 里没有对应帧的(TDA、TIM、RVA、CRM…)和压缩过的 v2.2 不写。见 11 章决策 173。
//   - 原有的歌词帧(USLT、SYLT、描述是歌词键的 TXXX)全部去掉,换成这一个;别的帧原样、按原顺序留着。语言沿用
//     原来第一个 USLT 的,没有就写 eng。
//   - 扩展头、标签尾不写回;v2.3 整个标签反同步过的,写回时不再反同步。
//   - v2.4 的帧长照读法 id3v24FrameSize 认普通大端整数(iTunes 写法),写回一律写成同步安全整数,帧标志和正文原样;
//     要换算帧长的帧带格式标志(数据长度指示、压缩、加密、反同步、分组)的不写,那几样的长度字段读法同样拿不准。
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
		// 没有标签时在文件最前面插一份:开头得是 MPEG 帧同步,改了扩展名的 MP4 / WAV / OGG 插进去文件头就不在原位了。
		if n < 2 || !mpegFrameSync(header) {
			return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "no ID3 tag and no MPEG frame at the start")
		}
		edit, _ := id3EditTag(nil, fileSize)
		return lyricsTagLayout{build: edit.build, preserved: edit.preserved}, nil
	}
	headLen, err := id3TagLen(header)
	if err != nil {
		return lyricsTagLayout{}, err
	}
	if int64(headLen) > fileSize {
		return lyricsTagLayout{}, wbErrf(wbErrUnsupportedTag, "ID3 tag size %d", headLen)
	}
	head := make([]byte, headLen)
	copy(head, header)
	if _, err := io.ReadFull(r, head[10:]); err != nil {
		return lyricsTagLayout{}, wbErr(wbErrIO, err)
	}
	edit, err := id3EditTag(head, fileSize-int64(headLen))
	if err != nil {
		return lyricsTagLayout{}, err
	}
	return lyricsTagLayout{
		head:       head,
		audioStart: int64(headLen),
		hasLyrics:  edit.hasLyrics,
		build:      edit.build,
		preserved:  edit.preserved,
	}, nil
}

// id3TagLen 看 10 字节标签头:写回认不认这个版本,整个标签(标签头 + 标签区 + v2.4 标签尾)多长。
func id3TagLen(header []byte) (int, error) {
	version, flags := header[3], header[5]
	switch {
	case version != 2 && version != 3 && version != 4:
		return 0, wbErrf(wbErrUnsupportedTag, "ID3v2.%d", version)
	case version == 4 && flags&0x80 != 0:
		return 0, wbErrf(wbErrUnsupportedTag, "ID3v2.4 whole-tag unsynchronisation")
	case version == 2 && flags&0x40 != 0:
		return 0, wbErrf(wbErrUnsupportedTag, "ID3v2.2 compression")
	}
	size := syncsafeInt(header[6:10])
	if size > localFileEmbeddedMaxTagBytes {
		return 0, wbErrf(wbErrUnsupportedTag, "ID3 tag size %d", size)
	}
	n := 10 + size
	if version == 4 && flags&0x10 != 0 {
		n += 10
	}
	return n, nil
}

// id3TagEdit:一份 ID3v2 标签写进歌词要用的东西。build 交回整份新标签,preserved 核对它。
type id3TagEdit struct {
	hasLyrics bool
	build     func(text string) ([]byte, error)
	preserved func(newTag []byte) error
}

// id3EditTag 拆 tag(从 "ID3" 起、长度恰好是 id3TagLen);tag 为 nil 时新建一份 v2.4。audioBytes 只用来定 padding。
func id3EditTag(tag []byte, audioBytes int64) (id3TagEdit, error) {
	if tag == nil {
		return id3TagEdit{
			build: func(text string) ([]byte, error) {
				return id3BuildTag(4, nil, id3USLTFrame(4, id3WritebackDefaultLang, text), 0, audioBytes)
			},
			preserved: func(newTag []byte) error {
				return id3PreservedErr(4, nil, newTag)
			},
		}, nil
	}
	version, flags := tag[3], tag[5]
	size := syncsafeInt(tag[6:10])
	body := tag[10 : 10+size]
	outVersion := version
	var frames, from22 []id3RawFrame
	var err error
	if version == 2 {
		if from22, err = id3v22Frames(flags, body); err != nil {
			return id3TagEdit{}, err
		}
		if frames, err = id3UpgradeV22(from22); err != nil {
			return id3TagEdit{}, err
		}
		outVersion = 4
	} else {
		if frames, err = id3Frames(version, flags, body, false); err != nil {
			return id3TagEdit{}, err
		}
		if version == 4 {
			for _, f := range frames {
				if !id3SizeIsSyncsafe(f) && f.raw[9] != 0 {
					return id3TagEdit{}, wbErrf(wbErrUnsupportedTag, "frame %q: plain size with format flags %#x", f.id, f.raw[9])
				}
			}
		}
	}
	for _, f := range frames {
		if id3LyricsFrameUnreadable(f) {
			return id3TagEdit{}, wbErrf(wbErrUnsupportedTag, "lyrics frame %q the reader cannot decode", f.id)
		}
	}
	lang := id3WritebackDefaultLang
	for _, f := range frames {
		if f.id == "USLT" && len(f.raw) >= 14 && isASCIILetters(f.raw[11:14]) {
			lang = string(f.raw[11:14])
			break
		}
	}
	kept := id3KeptFrames(frames)
	var kept22 []id3RawFrame
	for i, f := range frames {
		if version == 2 && !id3IsLyricsFrame(f) {
			kept22 = append(kept22, from22[i])
		}
	}
	return id3TagEdit{
		hasLyrics: tagsFromID3(tag[:10], body).hasLyrics,
		build: func(text string) ([]byte, error) {
			return id3BuildTag(outVersion, kept, id3USLTFrame(outVersion, lang, text), len(tag), audioBytes)
		},
		preserved: func(newTag []byte) error {
			if err := id3PreservedErr(outVersion, kept, newTag); err != nil {
				return err
			}
			if version == 2 {
				return id3UpgradePreservedErr(kept22, newTag)
			}
			return nil
		},
	}, nil
}

// id3Frames 拆标签区里的帧(不含 10 字节标签头),遇到 padding(0 字节)为止。帧长越界、padding 里有非 0 字节当损坏。
// v2.4 的帧长:strictSyncsafe 为真只认同步安全整数(核对自己写出的标签),否则同读法 id3v24FrameSize。
func id3Frames(version, flags byte, tag []byte, strictSyncsafe bool) ([]id3RawFrame, error) {
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
		switch {
		case version == 4 && strictSyncsafe:
			size = syncsafeInt(tag[pos+4 : pos+8])
		case version == 4:
			size = id3v24FrameSize(tag, pos)
		default:
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

// id3SizeIsSyncsafe:帧头里的帧长字节就是正文长度的同步安全写法。
func id3SizeIsSyncsafe(f id3RawFrame) bool {
	var want [4]byte
	putSyncsafe(want[:], len(f.raw)-10)
	return bytes.Equal(f.raw[4:8], want[:])
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

// mpegFrameSync:b 开头是 MPEG 音频帧同步(11 个 1)。
func mpegFrameSync(b []byte) bool {
	return len(b) >= 2 && b[0] == 0xFF && b[1]&0xE0 == 0xE0
}

// id3LyricsFrameUnreadable:读法(tagsFromID3)解不出、帧里又带着内容的 USLT / SYLT。写回会删掉全部歌词帧,这种帧确认框、
// 覆盖前的备份都看不到,所以整个文件不写。见 11 章决策 169。
func id3LyricsFrameUnreadable(f id3RawFrame) bool {
	body := f.raw[10:]
	// 带格式标志的(压缩、加密、分组、反同步、数据长度指示)读法要先拆一层,这里不重算,一律当读不准。
	if (f.id == "USLT" || f.id == "SYLT") && f.raw[9] != 0 {
		return len(bytes.Trim(body, "\x00")) > 0
	}
	switch f.id {
	case "USLT":
		_, ok := textFromUSLT(body)
		return !ok && len(body) > 4 && len(bytes.Trim(body[4:], "\x00")) > 0
	case "SYLT":
		_, ok := lrcFromSYLT(body)
		return !ok && len(body) > 6 && len(bytes.Trim(body[6:], "\x00")) > 0
	}
	return false
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
		start := len(frames)
		frames = append(frames, f.raw...)
		if version == 4 {
			putSyncsafe(frames[start+4:start+8], len(f.raw)-10)
		}
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

// id3PreservedErr:新标签是 version 版,歌词以外的帧跟 kept 的帧名、帧标志、正文逐字节相同、顺序一致,而且恰好有一个
// 歌词帧(USLT)。v2.4 按同步安全整数拆帧,帧长写成别的样子拆不开或对不上。
func id3PreservedErr(version byte, kept []id3RawFrame, newHead []byte) error {
	if len(newHead) < 10 || !bytes.HasPrefix(newHead, []byte("ID3")) {
		return wbErrf(wbErrTagsNotPreserved, "no ID3 header")
	}
	if newHead[3] != version {
		return wbErrf(wbErrTagsNotPreserved, "ID3v2.%d written, want ID3v2.%d", newHead[3], version)
	}
	flags := newHead[5]
	size := syncsafeInt(newHead[6:10])
	if 10+size > len(newHead) {
		return wbErrf(wbErrTagsNotPreserved, "bad tag size")
	}
	frames, err := id3Frames(version, flags, newHead[10:10+size], true)
	if err != nil {
		return wbErr(wbErrTagsNotPreserved, err)
	}
	got := id3KeptFrames(frames)
	if len(got) != len(kept) {
		return wbErrf(wbErrTagsNotPreserved, "%d frames kept, expected %d", len(got), len(kept))
	}
	for i := range got {
		g, k := got[i].raw, kept[i].raw
		if got[i].id != kept[i].id || !bytes.Equal(g[8:], k[8:]) {
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
