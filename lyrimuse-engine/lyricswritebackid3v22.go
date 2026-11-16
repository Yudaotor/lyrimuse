package main

import (
	"bytes"
	"strings"
)

// ID3v2.2 → v2.4 的升级,只给歌词写回用:帧名换成四字母、帧头换成 10 字节(同步安全帧长、标志全 0),正文原样;
// 唯一改正文的是 PIC → APIC(三字母图片格式换成 MIME)。帧名对照照 mutagen 的 v2.2 帧类和 TagLib 的
// id3v2framefactory;v2.4 里删掉或格式不同的帧(日期 TDA / TIM / TRD、TSI、RVA、EQU、CRM、LNK)和没登记的帧名
// 整个文件不写,不替用户丢帧。见 11 章决策 173。

// id3v22To24:v2.2 帧名 → v2.4 帧名。TYE / TOR 的正文是四位年份,本身就是合法的 TDRC / TDOR 时间戳;IPL 的
// 「职务\0人名」对子格式跟 TIPL 相同。
var id3v22To24 = map[string]string{
	"UFI": "UFID", "TT1": "TIT1", "TT2": "TIT2", "TT3": "TIT3", "TP1": "TPE1", "TP2": "TPE2", "TP3": "TPE3",
	"TP4": "TPE4", "TCM": "TCOM", "TXT": "TEXT", "TLA": "TLAN", "TCO": "TCON", "TAL": "TALB", "TPA": "TPOS",
	"TRK": "TRCK", "TRC": "TSRC", "TYE": "TDRC", "TOR": "TDOR", "TMT": "TMED", "TFT": "TFLT", "TBP": "TBPM",
	"TCP": "TCMP", "TCR": "TCOP", "TPB": "TPUB", "TEN": "TENC", "TST": "TSOT", "TSA": "TSOA", "TS2": "TSO2",
	"TSP": "TSOP", "TSC": "TSOC", "TSS": "TSSE", "TOF": "TOFN", "TLE": "TLEN", "TDY": "TDLY", "TKE": "TKEY",
	"TOT": "TOAL", "TOA": "TOPE", "TOL": "TOLY", "TXX": "TXXX", "WAF": "WOAF", "WAR": "WOAR", "WAS": "WOAS",
	"WCM": "WCOM", "WCP": "WCOP", "WPB": "WPUB", "WXX": "WXXX", "IPL": "TIPL", "MCI": "MCDI", "ETC": "ETCO",
	"MLL": "MLLT", "STC": "SYTC", "ULT": "USLT", "SLT": "SYLT", "COM": "COMM", "REV": "RVRB", "PIC": "APIC",
	"GEO": "GEOB", "CNT": "PCNT", "POP": "POPM", "BUF": "RBUF", "CRA": "AENC", "MVN": "MVNM", "MVI": "MVIN",
	"GP1": "GRP1",
}

// id3v22Frames 拆 v2.2 标签区里的帧(6 字节帧头:三字母帧名 + 24 位大端帧长),规则同 id3Frames。
func id3v22Frames(flags byte, tag []byte) ([]id3RawFrame, error) {
	if flags&0x80 != 0 {
		tag = bytes.ReplaceAll(tag, []byte{0xFF, 0x00}, []byte{0xFF})
	}
	var frames []id3RawFrame
	pos := 0
	for pos < len(tag) && tag[pos] != 0 {
		if pos+6 > len(tag) {
			return nil, wbErrf(wbErrUnsupportedTag, "truncated ID3v2.2 frame header")
		}
		size := int(tag[pos+3])<<16 | int(tag[pos+4])<<8 | int(tag[pos+5])
		if size > len(tag)-pos-6 {
			return nil, wbErrf(wbErrUnsupportedTag, "frame %q overruns the tag", tag[pos:pos+3])
		}
		frames = append(frames, id3RawFrame{id: string(tag[pos : pos+3]), raw: tag[pos : pos+6+size]})
		pos += 6 + size
	}
	for _, b := range tag[pos:] {
		if b != 0 {
			return nil, wbErrf(wbErrUnsupportedTag, "garbage after the frames")
		}
	}
	return frames, nil
}

// id3UpgradeV22 把 v2.2 的帧逐个换成 v2.4 的帧;有一帧换不了整个拒绝。
func id3UpgradeV22(old []id3RawFrame) ([]id3RawFrame, error) {
	out := make([]id3RawFrame, 0, len(old))
	for _, f := range old {
		id, ok := id3v22To24[f.id]
		if !ok {
			return nil, wbErrf(wbErrUnsupportedTag, "ID3v2.2 frame %q has no ID3v2.4 counterpart", f.id)
		}
		body := f.raw[6:]
		if f.id == "PIC" {
			var err error
			if body, err = id3APICFromPIC(body); err != nil {
				return nil, err
			}
		}
		raw := make([]byte, 10, 10+len(body))
		copy(raw, id)
		putSyncsafe(raw[4:8], len(body))
		out = append(out, id3RawFrame{id: id, raw: append(raw, body...)})
	}
	return out, nil
}

// id3APICFromPIC:PIC 正文「编码 + 三字母格式 + 图片类型 + 描述 + 数据」→ APIC 正文「编码 + MIME\0 + 图片类型 + 描述 + 数据」。
func id3APICFromPIC(body []byte) ([]byte, error) {
	if len(body) < 5 {
		return nil, wbErrf(wbErrUnsupportedTag, "truncated PIC frame")
	}
	mime, ok := id3PICMime(body[1:4])
	if !ok {
		return nil, wbErrf(wbErrUnsupportedTag, "PIC image format %q", body[1:4])
	}
	out := append([]byte{body[0]}, mime...)
	out = append(out, 0)
	return append(out, body[4:]...), nil
}

// id3PICMime:JPG / PNG 换成标准 MIME,别的格式写 image/<小写格式>(TagLib 的做法);外链图片(-->)和非 ASCII 字母数字的格式不认。
func id3PICMime(format []byte) (string, bool) {
	f := strings.TrimRight(string(format), "\x00 ")
	for _, c := range []byte(f) {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') {
			return "", false
		}
	}
	switch strings.ToUpper(f) {
	case "JPG", "JPEG":
		return "image/jpeg", true
	case "PNG":
		return "image/png", true
	case "":
		return "", true
	}
	return "image/" + strings.ToLower(f), true
}

// id3UpgradePreservedErr:升级写出的新标签里,歌词以外的帧跟原来的 v2.2 帧一一对应:帧名是对照表里那个、帧标志全 0、
// 正文相同(APIC 是 MIME 之后的部分跟 PIC 格式之后的部分相同)。跟 id3UpgradeV22 各走一遍,对照表或转换写错时拦得住。
func id3UpgradePreservedErr(old []id3RawFrame, newTag []byte) error {
	size := syncsafeInt(newTag[6:10])
	frames, err := id3Frames(4, newTag[5], newTag[10:10+size], true)
	if err != nil {
		return wbErr(wbErrTagsNotPreserved, err)
	}
	got := id3KeptFrames(frames)
	if len(got) != len(old) {
		return wbErrf(wbErrTagsNotPreserved, "%d frames after the ID3v2.2 upgrade, expected %d", len(got), len(old))
	}
	for i, g := range got {
		o := old[i]
		if g.id != id3v22To24[o.id] || g.raw[8] != 0 || g.raw[9] != 0 {
			return wbErrf(wbErrTagsNotPreserved, "frame %d: %s became %s", i, o.id, g.id)
		}
		gb, ob := g.raw[10:], o.raw[6:]
		if o.id == "PIC" {
			end := bytes.IndexByte(gb[min(1, len(gb)):], 0)
			mime, _ := id3PICMime(ob[1:4])
			if len(gb) == 0 || end < 0 || gb[0] != ob[0] || string(gb[1:1+end]) != mime {
				return wbErrf(wbErrTagsNotPreserved, "frame %d: APIC header does not match PIC", i)
			}
			gb, ob = gb[2+end:], ob[4:]
		}
		if !bytes.Equal(gb, ob) {
			return wbErrf(wbErrTagsNotPreserved, "frame %d (%s) body changed in the ID3v2.2 upgrade", i, o.id)
		}
	}
	return nil
}
