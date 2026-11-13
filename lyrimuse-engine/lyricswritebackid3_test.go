package main

import (
	"bytes"
	"encoding/binary"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// id3PlainV24Frame:iTunes 写法的 v2.4 帧,帧长是普通大端整数;status、format 是帧头最后两个标志字节。
func id3PlainV24Frame(id string, status, format byte, body []byte) []byte {
	head := make([]byte, 10)
	copy(head, id)
	binary.BigEndian.PutUint32(head[4:8], uint32(len(body)))
	head[8], head[9] = status, format
	return append(head, body...)
}

// itunesV24Sample:v2.4 标签,帧长全按普通大端写:有小于 128 的(两种读法一样)、带最高位的、不带最高位但两种读法不一样的,
// 还有一个旧 USLT。kept 是写回后该原样留下的帧(按原顺序)。
func itunesV24Sample() (data, audio []byte, kept [][]byte) {
	tpe1 := append([]byte{3}, strings.Repeat("周杰伦 jay chou ", 20)...)
	kept = [][]byte{
		id3PlainV24Frame("TIT2", 0, 0, append([]byte{3}, "稻香"...)),
		id3PlainV24Frame("TPE1", 0x40, 0, tpe1),
		id3PlainV24Frame("APIC", 0, 0, append([]byte{0}, bytes.Repeat([]byte{0xAB}, 2999)...)),
		id3PlainV24Frame("COMM", 0, 0, usltBody(3, []byte(strings.Repeat("注释保留", 12)))),
		id3PlainV24Frame("TXXX", 0, 0, txxxBody("iTunNORM", " 00000193 00000180")),
	}
	oldLyrics := id3PlainV24Frame("USLT", 0, 0, usltBody(3, []byte(strings.Repeat("旧歌词一行\n", 15))))
	audio = writebackAudio(30000)
	data = append(id3TagPadded(4, 64, kept[0], kept[1], kept[2], oldLyrics, kept[3], kept[4]), audio...)
	return data, audio, kept
}

func TestLyricsWritebackITunesV24FrameSizes(t *testing.T) {
	data, audio, kept := itunesV24Sample()
	if tpe1 := kept[1][4:8]; tpe1[3]&0x80 != 0 || syncsafeInt(tpe1) == int(binary.BigEndian.Uint32(tpe1)) {
		t.Fatalf("样本里 TPE1 的帧长应不带最高位、两种读法不一样:% x", tpe1)
	}
	if apic := kept[2][4:8]; apic[3]&0x80 == 0 {
		t.Fatalf("样本里 APIC 的帧长应带最高位:% x", apic)
	}
	path := writeTemp(t, "itunes.mp3", data)
	_, err := writeLyricsToFile(path, writebackLRC, false)
	wantWritebackCode(t, err, wbErrHasLyrics)

	if _, err := writeLyricsToFile(path, writebackLRC, true); err != nil {
		t.Fatalf("iTunes 写法的 v2.4 应能写:%v", err)
	}
	out, _ := os.ReadFile(path)
	if tags := readLocalFileTags(path); tags.lyrics != normalizeWritebackLyrics(writebackLRC) {
		t.Errorf("回读:%q", tags.lyrics)
	}
	v, headLen, frames := parseID3ForTest(t, out)
	if v != 4 || !bytes.Equal(out[headLen:], audio) {
		t.Fatalf("版本 v2.%d,或音频字节变了", v)
	}
	var others [][]byte
	uslt := 0
	for _, f := range frames {
		if string(f[:4]) == "USLT" {
			uslt++
			continue
		}
		others = append(others, f)
	}
	if uslt != 1 || len(others) != len(kept) {
		t.Fatalf("USLT %d 个、别的帧 %d 个,想要 1 个、%d 个", uslt, len(others), len(kept))
	}
	for i, f := range others {
		k := kept[i]
		if !bytes.Equal(f[:4], k[:4]) || !bytes.Equal(f[8:], k[8:]) {
			t.Errorf("第 %d 个帧 %s 的帧名、标志或正文变了", i, k[:4])
		}
		var want [4]byte
		putSyncsafe(want[:], len(k)-10)
		if !bytes.Equal(f[4:8], want[:]) {
			t.Errorf("%s 的帧长应写成同步安全整数 % x,得到 % x", k[:4], want, f[4:8])
		}
	}
	noLeftoverClones(t, filepath.Dir(path))
}

func TestLyricsWritebackITunesV24FormatFlagsRefused(t *testing.T) {
	audio := writebackAudio(2000)
	dli := append([]byte{0, 0, 1, 0x2C}, bytes.Repeat([]byte{'x'}, 296)...)
	data := append(id3TagPadded(4, 16, id3PlainV24Frame("TIT2", 0, 0x01, dli)), audio...)
	path := writeTemp(t, "dli.mp3", data)
	_, err := writeLyricsToFile(path, writebackLRC, true)
	wantWritebackCode(t, err, wbErrUnsupportedTag)
	if out, _ := os.ReadFile(path); !bytes.Equal(out, data) {
		t.Errorf("拒写时文件不动")
	}

	small := id3PlainV24Frame("TIT2", 0, 0x01, []byte{0, 0, 0, 2, 3, 'x'})
	ok := writeTemp(t, "dli-small.mp3", append(id3TagPadded(4, 16, small), audio...))
	if _, err := writeLyricsToFile(ok, writebackLRC, true); err != nil {
		t.Fatalf("帧长本来就是同步安全的帧带格式标志照写:%v", err)
	}
	out, _ := os.ReadFile(ok)
	if _, _, frames := parseID3ForTest(t, out); !bytes.Equal(frames[0], small) {
		t.Errorf("带数据长度指示的帧应原样留下")
	}
}

func TestLyricsWritebackITunesV24SelfCheck(t *testing.T) {
	t.Cleanup(func() { lyricsWritebackAfterWrite = nil })
	corrupt := map[string]func(d []byte){
		"APIC 帧长写回普通整数": func(d []byte) {
			i := bytes.Index(d, []byte("APIC"))
			binary.BigEndian.PutUint32(d[i+4:i+8], 3000)
		},
		"APIC 正文变了": func(d []byte) {
			i := bytes.Index(d, []byte("APIC"))
			d[i+500] ^= 0x01
		},
		"TIT2 帧名变了": func(d []byte) {
			i := bytes.Index(d, []byte("TIT2"))
			d[i+3] = '3'
		},
		"TPE1 标志变了": func(d []byte) {
			i := bytes.Index(d, []byte("TPE1"))
			d[i+8] = 0
		},
	}
	for name, mutate := range corrupt {
		data, _, _ := itunesV24Sample()
		path := writeTemp(t, "selfcheck.mp3", data)
		lyricsWritebackAfterWrite = func(clone string) {
			d, err := os.ReadFile(clone)
			if err != nil {
				t.Fatal(err)
			}
			mutate(d)
			if err := os.WriteFile(clone, d, 0o644); err != nil {
				t.Fatal(err)
			}
		}
		_, err := writeLyricsToFile(path, writebackLRC, true)
		if lyricsWritebackCode(err) != wbErrTagsNotPreserved {
			t.Errorf("%s:想要 %s,得到 %v", name, wbErrTagsNotPreserved, err)
		}
		if out, _ := os.ReadFile(path); !bytes.Equal(out, data) {
			t.Errorf("%s:自校验失败时原文件不动", name)
		}
		noLeftoverClones(t, filepath.Dir(path))
	}
}
