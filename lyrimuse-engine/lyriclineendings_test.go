package main

import "testing"

func TestNormalizeLyricText(t *testing.T) {
	cases := map[string]string{
		"\ufeff[00:01.00]a\r\n[00:02.00]b\r\n": "[00:01.00]a\n[00:02.00]b\n",
		"\ufeff\ufeffx\ry":                     "x\ny",
		"plain\n":                              "plain\n",
		"a\ufeffb":                             "a\ufeffb",        // 只去开头的
		"[00:01.00]a\n\x00\x00\n":              "[00:01.00]a\n\n", // 咪咕文件末尾的 NUL
		"a\tb\x01c\x7fd":                       "a\tbcd",          // 制表符留着,别的控制字符去掉
		"":                                     "",
	}
	for in, want := range cases {
		if got := normalizeLyricText(in); got != want {
			t.Errorf("normalizeLyricText(%q) = %q, want %q", in, got, want)
		}
	}
}

// rank 门口:换行、BOM、字符实体一起统一,各个字段都过。
func TestDecodeLyricSourceResultNormalizesLineEndings(t *testing.T) {
	r := lyricSourceResult{lyr: "\ufeff[00:01.00]they&apos;re\r\n[00:02.00]b\r\n", yrc: "[0,1](0,1,0)a\r\n", tr: "[00:01.00]译\r\n"}
	r.ne.Lyrics = "[00:01.00]a\r\n"
	r.amll.lrc = "[00:01.00]a\r"
	got := decodeLyricSourceResultEntities(r)
	if got.lyr != "[00:01.00]they're\n[00:02.00]b\n" || got.yrc != "[0,1](0,1,0)a\n" || got.tr != "[00:01.00]译\n" ||
		got.ne.Lyrics != "[00:01.00]a\n" || got.amll.lrc != "[00:01.00]a\n" {
		t.Fatalf("got %+v", got)
	}
}

// 存量迁移:六个字段统一,手动选定留痕按新正文重算,只跑一遍。
func TestMigrateLyricLineEndings(t *testing.T) {
	withTempMigrationState(t)
	withTempDecisionCache(t)
	old := "\ufeff[00:01.00]第一句\r\n[00:02.00]第二句\r\n"
	enrichMu.Lock()
	enrichPath = ""
	enrichCache["a|t|b"] = enrichEntry{Lyrics: bt(old), LyricsTr: bt("[00:01.00]tr\r\n"), LyricsYRC: bt("\ufeff[0,1](0,1,0)x\r\n"),
		PlainLyrics: bt("p\r\n"), LyricsRoma: bt("r\r"), LyricsBG: bt("bg\r\n"), ManualPickSHA: manualPickFingerprint(old), ManualLyrics: true}
	enrichCache["a|clean|b"] = enrichEntry{Lyrics: bt("[00:01.00]x\n")}
	enrichCache["a|nul|b"] = enrichEntry{Lyrics: bt("[00:01.00]夜来香\n\x00\x00\n")}
	enrichCache["a|stale-pick|b"] = enrichEntry{Lyrics: bt("[00:01.00]y\r\n"), ManualPickSHA: "deadbeef0000"}
	enrichDirty = false
	enrichMu.Unlock()
	migrateLyricLineEndings()
	e := enrichCache["a|t|b"]
	if !e.Lyrics.EqualString("[00:01.00]第一句\n[00:02.00]第二句\n") || !e.LyricsTr.EqualString("[00:01.00]tr\n") || !e.LyricsYRC.EqualString("[0,1](0,1,0)x\n") ||
		!e.PlainLyrics.EqualString("p\n") || !e.LyricsRoma.EqualString("r\n") || !e.LyricsBG.EqualString("bg\n") {
		t.Fatalf("六个字段都该统一: %+v", e)
	}
	if e.ManualPickSHA != manualPickFingerprint(e.Lyrics.String()) || !e.ManualLyrics {
		t.Fatalf("手动选定留痕应当跟着新正文: %+v", e)
	}
	if !enrichCache["a|nul|b"].Lyrics.EqualString("[00:01.00]夜来香\n\n") {
		t.Fatalf("NUL 去掉: %q", enrichCache["a|nul|b"].Lyrics.String())
	}
	if enrichCache["a|stale-pick|b"].ManualPickSHA != "deadbeef0000" {
		t.Fatal("本来就对不上的留痕不动")
	}
	if !enrichCache["a|clean|b"].Lyrics.EqualString("[00:01.00]x\n") || !enrichDirty {
		t.Fatal("干净的不动,改过就置脏")
	}
	enrichMu.Lock()
	enrichCache["a|later|b"] = enrichEntry{Lyrics: bt("[00:01.00]z\r\n")}
	enrichMu.Unlock()
	migrateLyricLineEndings()
	if !enrichCache["a|later|b"].Lyrics.EqualString("[00:01.00]z\r\n") {
		t.Fatal("有水位之后不再跑")
	}
}
