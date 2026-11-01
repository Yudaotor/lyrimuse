package main

import (
	"encoding/hex"
	"strings"
	"testing"
)

func importOneFile(t *testing.T, name string, data []byte) importLyricsResult {
	t.Helper()
	return parseImportedLyrics([]importLyricsFile{{Name: name, Data: data}}, "")
}

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// 只有标签、只有时间戳、一个字都没有的文件不当歌词。
func TestImportRejectsFilesWithoutLyricText(t *testing.T) {
	for name, body := range map[string]string{
		"tags.lrc":   "[ti:X]\n[ar:Y]\n[by:]\n[offset:0]\n",
		"tags.txt":   "[ti:X]\n[ar:Y]\n",
		"stamps.lrc": "[00:00.00]\n[03:59.00]\n",
	} {
		if r := importOneFile(t, name, []byte(body)); r.Candidate != nil || r.Error != "unrecognized" {
			t.Errorf("%s 不该认成歌词: %+v", name, r)
		}
	}
}

// 带 BOM 的 UTF-16、末尾补 NUL、只用 CR 换行的文件照常认。
func TestImportNormalizesTextEncodingAndNewlines(t *testing.T) {
	lrc := "[ti:Song]\n[00:01.00]第一句\n[00:04.00]第二句\n"
	le := []byte{0xFF, 0xFE}
	for _, r := range lrc {
		le = append(le, byte(r), byte(r>>8))
	}
	be := []byte{0xFE, 0xFF}
	for _, r := range lrc {
		be = append(be, byte(r>>8), byte(r))
	}
	cases := map[string][]byte{
		"utf16le.lrc": le,
		"utf16be.lrc": be,
		"nul.lrc":     append([]byte(lrc), 0, 0),
		"cr.lrc":      []byte(strings.ReplaceAll(lrc, "\n", "\r")),
	}
	for name, data := range cases {
		r := importOneFile(t, name, data)
		if r.Candidate == nil || r.Format != "lrc" || !strings.Contains(r.Candidate.Lyrics, "[00:04.00]第二句") || r.Candidate.Title != "Song" {
			t.Errorf("%s 应认成 LRC: %+v", name, r)
		}
	}
}

// 不是 UTF-8 的日文、韩文文件按 Shift_JIS、EUC-KR 转,中文 GBK 照旧。
func TestImportDecodesJapaneseAndKoreanLegacyEncodings(t *testing.T) {
	cases := []struct {
		name, hex, want, title string
	}{
		{"sjis.lrc", "5b74693a914f914f914f90a25d0a5b30303a30312e30305d82e282c182c68ae182f08a6f82dc82b582bd82a982a20a5b30303a30352e30305d82bb82ea82c882cc82c982c882ba8ae182e08d8782ed82b982e282b582c882a282f182be82a20a",
			"やっと眼を覚ましたかい", "前前前世"},
		{"euckr.lrc", "5b74693ababdb3af5d0a5b30303a30312e30305dbab8b0ed20bdcdb4d920c0ccb7b8b0d420b8bbc7cfb4cfb1ee20b4f520bab8b0ed20bdcdb4d90a5b30303a30352e30305db3cac8f120bbe7c1f8c0bb20bab8b0ed20c0d6beeeb5b520bab8b0ed20bdcdb4d90a",
			"보고 싶다 이렇게 말하니까", "봄날"},
		{"gbk.lrc", "5b74693acaaec4ea5d0a5b30303a30312e30305dc8e7b9fbc4c7c1bdb8f6d7d6c3bbd3d0b2fcb6b60a5b30303a30352e30305dced2b2bbbbe1b7a2cfd6ced2c4d1cadc0a",
			"如果那两个字没有颤抖", "十年"},
	}
	for _, c := range cases {
		r := importOneFile(t, c.name, mustHex(t, c.hex))
		if r.Candidate == nil || !strings.Contains(r.Candidate.Lyrics, c.want) || r.Candidate.Title != c.title {
			t.Errorf("%s 转码不对: %+v", c.name, r.Candidate)
		}
	}
}

// LyricsX 的 .lrcx:[tr:] 行拆进译文,[tt] 行变成逐字。
func TestImportLyricsXTranslationAndWordTiming(t *testing.T) {
	body := "[00:12.340]Hello it's me\n[00:12.340][tr:zh-Hans]你好，是我\n[00:12.340][tt]<0,0><300,6><900,11><1800>\n[00:15.000]Next\n"
	r := importOneFile(t, "song.lrcx", []byte(body))
	c := r.Candidate
	if c == nil {
		t.Fatalf("应认得: %+v", r)
	}
	if strings.Contains(c.Lyrics, "[tr:") || strings.Contains(c.Lyrics, "[tt]") || strings.Contains(c.Lyrics, "<0,0>") {
		t.Errorf("正文里不该留 LyricsX 的附加行: %q", c.Lyrics)
	}
	if !strings.Contains(c.Lyrics, "[00:12.34]Hello it's me") || !strings.Contains(c.Lyrics, "[00:15.000]Next") {
		t.Errorf("正文行不对: %q", c.Lyrics)
	}
	if c.LyricsTr != "[00:12.34]你好，是我" {
		t.Errorf("译文: %q", c.LyricsTr)
	}
	if !c.HasWordTiming || !strings.Contains(c.LyricsYRC, "Hello ") || !strings.Contains(c.LyricsYRC, "it's ") {
		t.Errorf("逐字: %q", c.LyricsYRC)
	}
}

// 酷狗 / QQ 的标签行、大写标签都去掉、不算行数;大写的身份标签照读;值里带方括号的整段取。
func TestImportStripsAllTagLines(t *testing.T) {
	body := "[ID:$00000000]\n[TI:Song [Live]]\n[AR:Singer]\n[hash:abc]\n[sign:x]\n[total:200000]\n[offset:0]\n[00:01.00]第一句\n[00:04.00]第二句\n"
	c := importOneFile(t, "k.lrc", []byte(body)).Candidate
	if c == nil || c.Title != "Song [Live]" || c.Artist != "Singer" {
		t.Fatalf("身份: %+v", c)
	}
	if c.Lyrics != "[offset:0]\n[00:01.00]第一句\n[00:04.00]第二句" {
		t.Errorf("标签行没去干净: %q", c.Lyrics)
	}
}

// 译文、读音文件配同名的正文;没用上的都记进 Ignored。
func TestImportCompanionFilesPairByName(t *testing.T) {
	lrc := func(s string) []byte { return []byte("[00:01.00]" + s + "\n[00:04.00]" + s + "2\n") }
	r := parseImportedLyrics([]importLyricsFile{
		{Name: "A.lrc", Data: lrc("a")}, {Name: "B.lrc", Data: lrc("b")}, {Name: "B.tr.lrc", Data: lrc("译")},
	}, "")
	if r.Candidate == nil || r.Candidate.LyricsTr != "" {
		t.Errorf("A 不该配上 B 的译文: %+v", r.Candidate)
	}
	if !strings.Contains(strings.Join(r.Ignored, ","), "B.tr.lrc") {
		t.Errorf("没用上的译文应记进 Ignored: %v", r.Ignored)
	}
	r = parseImportedLyrics([]importLyricsFile{
		{Name: "a.txt", Data: []byte("第一句\n第二句")}, {Name: "a.tr.lrc", Data: lrc("译")},
	}, "")
	if !strings.Contains(strings.Join(r.Ignored, ","), "a.tr.lrc") {
		t.Errorf("纯文本用不上译文,应记进 Ignored: %v", r.Ignored)
	}
	r = parseImportedLyrics([]importLyricsFile{
		{Name: "Song.lrc", Data: lrc("s")}, {Name: "song.tr.lrc", Data: lrc("译")},
	}, "")
	if r.Candidate == nil || r.Candidate.LyricsTr == "" {
		t.Errorf("同名(不分大小写)的译文应配上: %+v", r.Candidate)
	}
}

// App 读到上限就停、只交文件名的文件报 too-large。
func TestImportTooLargeFlag(t *testing.T) {
	r := parseImportedLyrics([]importLyricsFile{{Name: "big.lrc", TooLarge: true}}, "")
	if r.Error != "too-large" {
		t.Errorf("应报 too-large: %+v", r)
	}
}
