package main

import "testing"

func TestNormalizeLyricText(t *testing.T) {
	cases := map[string]string{
		"\ufeff[00:01.00]a\r\n[00:02.00]b\r\n": "[00:01.00]a\n[00:02.00]b\n",
		"\ufeff\ufeffx\ry":                     "x\ny",
		"plain\n":                              "plain\n",
		"a\ufeffb":                             "a\ufeffb",        // 只去开头的
		"[00:01.00]a\n\x00\x00\n":              "[00:01.00]a\n\n", // 咪咕文件末尾的 NUL
		"a\tb\x01c\x7fd":                       "a bcd",           // 制表符换成空格,别的控制字符去掉
		"":                                     "",
		// 制表符、行 / 段分隔符:换成一个空格,挨着空白或在行首行尾的去掉
		"vagyok\u2028elalszom\u2029x":                    "vagyok elalszom x",
		"sithandana\u2028 (Ngicela":                      "sithandana (Ngicela",
		"[02:47.33]意义\u2028\n[02:53.33]原因":               "[02:47.33]意义\n[02:53.33]原因",
		"[02:18.93]\t不管\n[00:52.17]\t\n":                 "[02:18.93] 不管\n[00:52.17]\n",
		"a\t\tb\t":                                       "a b",
		"\u2028a":                                        "a",
		"(29744,600,0)vagyok\u2028(32375,480,0)elalszom": "(29744,600,0)vagyok (32375,480,0)elalszom",
		// 只有一行占位文字的当成没有歌词
		"[00:00.00]暂无歌词\n": "",
		"无歌词\n":            "",
		"<not found>":      "",
		"[ti:x]\n[ar:y]\n[00:00.00]暫無歌詞\r\n": "",
		"[00:00.00]暂无歌词\n[00:01.00]第一句":      "[00:00.00]暂无歌词\n[00:01.00]第一句",
		"[00:00.00]暂无歌词了":                    "[00:00.00]暂无歌词了",
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
	enrichCache["a|inline|b"] = enrichEntry{Lyrics: bt("[00:29.74]vagyok\u2028elalszom\n"), LyricsTr: bt("[00:19.44]回忆\t如同\n"),
		PlainLyrics: bt("[00:00.00]暂无歌词\n")}
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
	if e := enrichCache["a|inline|b"]; !e.Lyrics.EqualString("[00:29.74]vagyok elalszom\n") || !e.LyricsTr.EqualString("[00:19.44]回忆 如同\n") ||
		!e.PlainLyrics.IsZero() {
		t.Fatalf("分隔符、制表符换成空格,占位文字清掉: %+v", e)
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
