package main

import (
	"bytes"
	"compress/zlib"
	"context"
	"encoding/hex"
	"net/http"
	"strings"
	"testing"
)

// qqEncryptQRCForTest 是 decryptQRC 的逆过程(zlib 压缩、补齐 8 字节、3DES-EDE3 加密、转十六进制),
// 给单测造 GetPlayLyricInfo 的 QRC 密文。造完先拿 decryptQRC 解一遍,对不上就直接失败。
func qqEncryptQRCForTest(t *testing.T, plain string) string {
	t.Helper()
	var buf bytes.Buffer
	zw := zlib.NewWriter(&buf)
	if _, err := zw.Write([]byte(plain)); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	data := buf.Bytes()
	for len(data)%8 != 0 {
		data = append(data, 0)
	}
	sched := [3][16]qmRoundKey{
		qmKeySchedule(qrcDESKey[0:8], qmEncrypt),
		qmKeySchedule(qrcDESKey[8:16], qmDecrypt),
		qmKeySchedule(qrcDESKey[16:24], qmEncrypt),
	}
	out := make([]byte, len(data))
	for off := 0; off < len(data); off += 8 {
		block := data[off : off+8]
		for _, s := range sched {
			b := qmCrypt(block, s)
			block = b[:]
		}
		copy(out[off:off+8], block)
	}
	cipher := hex.EncodeToString(out)
	if decryptQRC(cipher) != plain {
		t.Fatal("测试用的 QRC 加密跟 decryptQRC 对不上")
	}
	return cipher
}

const qqTestQRCContent = "[ti:测试曲]\n" +
	"[0,800]测试曲(0,400) - (400,100)歌手(500,300)\n" +
	"[1000,900]第(1000,300)一(1300,300)句(1600,300)\n" +
	"[2000,900]第(2000,300)二(2300,300)句(2600,300)\n" +
	"[3000,900]第(3000,300)三(3300,300)句(3600,300)\n" +
	"[4000,900]第(4000,300)四(4300,300)句(4600,300)"

const qqTestQRCLine = "[00:00.000]测试曲 - 歌手\n[00:01.000]第一句\n[00:02.000]第二句\n[00:03.000]第三句\n[00:04.000]第四句"

// QRC 正文同时交出逐字和压成的整行;整行接口没给词时 QQ 候选的整行歌词用后者。
func TestQQQRCLyricGivesLineLyric(t *testing.T) {
	resetQQSessionForTest(t)
	qqSessionFetch = func(ctx context.Context) ([]byte, error) {
		return []byte(`{"session":{"uid":"1","sid":"s1","userip":"1.1.1.1"}}`), nil
	}
	xml := `<?xml version="1.0" encoding="utf-8"?>` + "\n" + `<QrcInfos><QrcHeadInfo SaveTime="1" Version="100"/><LyricInfo LyricCount="1">` +
		`<Lyric_1 LyricType="1" LyricContent="` + qqTestQRCContent + `"/></LyricInfo></QrcInfos>`
	cipher := qqEncryptQRCForTest(t, xml)
	withQQFake(t, func(target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/v8/fcg-bin/fcg_play_single_song.fcg"):
			return http.StatusOK, `{"code":0,"data":[` + qqDetailRow + `]}`
		case target == "u.y.qq.com/musicu:GetPlayLyricInfo":
			return http.StatusOK, musicuOK(`{"lyric":"` + cipher + `","qrc_t":1,"lrc_t":0,"trans":"","roma":""}`)
		}
		return http.StatusNotFound, ""
	})
	res := qqQRCLyric(qqRoundCtx(), "m1", "周杰伦", "测试曲", "叶惠美", 269)
	if res.line != qqTestQRCLine {
		t.Fatalf("QRC 该压出整行歌词:\n got %q\nwant %q", res.line, qqTestQRCLine)
	}
	if !strings.Contains(res.yrc, "第") {
		t.Fatalf("逐字照常: %q", res.yrc)
	}
	if got := qqLineLyric(qqLyricResult{trackFoundNoLyrics: true}, res); got != qqTestQRCLine {
		t.Errorf("整行接口说没词时该用 QRC 的整行: %q", got)
	}
}

func TestQQLineLyricPrefersLineEndpoint(t *testing.T) {
	qrc := qqQRCResult{line: qqTestQRCLine}
	if got := qqLineLyric(qqLyricResult{lrc: qqTestLRC}, qrc); got != qqTestLRC {
		t.Errorf("整行接口给了词就用它: %q", got)
	}
	if got := qqLineLyric(qqLyricResult{}, qrc); got != qqTestQRCLine {
		t.Errorf("整行接口没问成时用 QRC 的整行: %q", got)
	}
	if got := qqLineLyric(qqLyricResult{instrumental: true}, qrc); got != "" {
		t.Errorf("纯音乐的结论不拿 QRC 推翻: %q", got)
	}
	if got := qqLineLyric(qqLyricResult{trackFoundNoLyrics: true}, qqQRCResult{}); got != "" {
		t.Errorf("两边都没有就是空: %q", got)
	}
}

const qqTestQRCRoma = "[0,800]ce (0,400)shi (400,400)\n" +
	"[1000,900]di (1000,300)yi (1300,300)ju (1600,300)\n" +
	"[2000,900]di (2000,300)er (2300,300)ju (2600,300)\n" +
	"[3000,900]di (3000,300)san (3300,300)ju (3600,300)"

func qqTestQRCXML(content string) string {
	return `<?xml version="1.0" encoding="utf-8"?>` + "\n" + `<QrcInfos><QrcHeadInfo SaveTime="1" Version="100"/><LyricInfo LyricCount="1">` +
		`<Lyric_1 LyricType="1" LyricContent="` + content + `"/></LyricInfo></QrcInfos>`
}

// qqTestLyricDownloadBody 仿 lyric_download.fcg 的应答:包在注释里、带 `<miniversion="1" />` 这种不合法的写法。
func qqTestLyricDownloadBody(result, content, trans, roma string) string {
	return "\n<!--\n<command-lable-xwl78-qq-music>\n<cmd value=\"1031\" verson=\"4\"><miniversion=\"1\" /><result>" + result +
		"</result><reason>success</reason><lyric musicid=\"97773\" encode=\"1\"><content type=\"file\" mime=\"file\" filescroll=\"3\"><![CDATA[" + content +
		"]]></content><contentts type=\"file\" mime=\"file\"><![CDATA[" + trans + "]]></contentts><contentroma type=\"file\" mime=\"file\"><![CDATA[" + roma +
		"]]></contentroma></lyric></cmd>\n</command-lable-xwl78-qq-music>\n-->\n"
}

// 网关没问成(拿不到会话,或几个主机都不通)时,逐字 / 整行 / 译文 / 罗马音从网页接口 lyric_download.fcg 取;
// 它第一个主机挂了换下一个。
func TestQQQRCLyricFallsBackToLyricDownload(t *testing.T) {
	cipher := qqEncryptQRCForTest(t, qqTestQRCXML(qqTestQRCContent))
	romaCipher := qqEncryptQRCForTest(t, qqTestQRCXML(qqTestQRCRoma))
	trans := "[ti:测试曲]\n[00:00.00]QQ音乐享有本翻译作品的著作权\n[00:00.80]//\n[00:01.00]First line\n[00:02.00]Second line\n[00:03.00]Third line\n[00:04.00]Fourth line"
	body := qqTestLyricDownloadBody("0", cipher, trans, romaCipher)
	for _, sessionOK := range []bool{false, true} {
		resetQQSessionForTest(t)
		qqSessionFetch = func(ctx context.Context) ([]byte, error) {
			if !sessionOK {
				return nil, context.DeadlineExceeded
			}
			return []byte(`{"session":{"uid":"1","sid":"s1","userip":"1.1.1.1"}}`), nil
		}
		f := withQQFake(t, func(target string) (int, string) {
			switch {
			case strings.HasSuffix(target, "/v8/fcg-bin/fcg_play_single_song.fcg"):
				return http.StatusOK, `{"code":0,"data":[` + qqDetailRow + `]}`
			case strings.HasSuffix(target, "/musicu:GetPlayLyricInfo"):
				return http.StatusBadGateway, ""
			case target == "c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg":
				return http.StatusBadGateway, ""
			case target == "shc.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg":
				return http.StatusOK, body
			}
			return http.StatusNotFound, ""
		})
		res := qqQRCLyric(qqRoundCtx(), "m1", "周杰伦", "测试曲", "叶惠美", 269)
		if res.line != qqTestQRCLine || !strings.Contains(res.yrc, "第") {
			t.Fatalf("sessionOK=%v: 逐字和整行该从 lyric_download 拿到: line=%q yrc=%q", sessionOK, res.line, res.yrc)
		}
		if res.tr != "[00:01.00]First line\n[00:02.00]Second line\n[00:03.00]Third line\n[00:04.00]Fourth line" {
			t.Errorf("sessionOK=%v: 译文段是明文,洗掉标题、声明和 // 之后接上: %q", sessionOK, res.tr)
		}
		if !strings.HasPrefix(res.roma, "[00:00.000]ce shi") {
			t.Errorf("sessionOK=%v: 罗马音段是密文,解开后接上: %q", sessionOK, res.roma)
		}
		if n := f.count("i.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg"); n != 0 {
			t.Errorf("sessionOK=%v: 拿到了就停, i.y 被问了 %d 次", sessionOK, n)
		}
		if gw := f.count("u.y.qq.com/musicu:GetPlayLyricInfo"); (gw > 0) != sessionOK {
			t.Errorf("sessionOK=%v: 有会话才问网关, 网关被问了 %d 次", sessionOK, gw)
		}
	}
}

// lyric_download 答了「查无此曲」(-1)就停;网关正常答了(哪怕这首没有逐字)就不去问 lyric_download。
func TestQQLyricDownloadAnswerIsFinal(t *testing.T) {
	resetQQSessionForTest(t)
	qqSessionFetch = func(ctx context.Context) ([]byte, error) { return nil, context.DeadlineExceeded }
	f := withQQFake(t, func(target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/v8/fcg-bin/fcg_play_single_song.fcg"):
			return http.StatusOK, `{"code":0,"data":[` + qqDetailRow + `]}`
		case target == "c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg":
			return http.StatusOK, qqTestLyricDownloadBody("-1", "", "", "")
		}
		return http.StatusNotFound, ""
	})
	if res := qqQRCLyric(qqRoundCtx(), "m1", "周杰伦", "测试曲", "叶惠美", 269); res != (qqQRCResult{}) {
		t.Fatalf("查无此曲该是零值: %+v", res)
	}
	if f.count("shc.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg") != 0 {
		t.Error("答了就停,不该换主机")
	}

	resetQQSessionForTest(t)
	qqSessionFetch = func(ctx context.Context) ([]byte, error) {
		return []byte(`{"session":{"uid":"1","sid":"s1","userip":"1.1.1.1"}}`), nil
	}
	f = withQQFake(t, func(target string) (int, string) {
		switch {
		case strings.HasSuffix(target, "/v8/fcg-bin/fcg_play_single_song.fcg"):
			return http.StatusOK, `{"code":0,"data":[` + qqDetailRow + `]}`
		case target == "u.y.qq.com/musicu:GetPlayLyricInfo":
			return http.StatusOK, musicuOK(`{"lyric":"","trans":"","roma":""}`)
		}
		return http.StatusNotFound, ""
	})
	qqQRCLyric(qqRoundCtx(), "m1", "周杰伦", "测试曲", "叶惠美", 269)
	if f.count("c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg") != 0 {
		t.Error("网关答了就不该再问 lyric_download")
	}
}
