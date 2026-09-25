package main

import "testing"

// 缓存 key / 宽松 key / 手动选词指纹的跨语言对拍向量。App 侧 lyrimuse-selftest 的
// CacheKeyTests「跨语言对拍」一节是逐条同样的输入和期望值:两边任何一侧的实现漂了,
// 这里或那里会当场红。改向量必须两边一起改。
func TestKeyParityVectors(t *testing.T) {
	loose := map[string]string{
		"张震岳|路口|OK":         "张震岳|路口|ok",
		"張震嶽|路口|OK":         "张震岳|路口|ok",
		"方大同|等著你回來|Soulboy": "方大同|等著你回来|soulboy",
		"谢安琪|囍帖街|":          "谢安琪|囍帖街|",
		"李荣浩|裙姊|嗯":          "李荣浩|裙姊|嗯",
		"不瞭解|一目瞭然|乾杯":       "不了解|一目了然|干杯",
		"İSTANBUL|ΣΟΦΙΑΣ|X": "istanbul|σοφιασ|x",
		"A/B、C|T|X":         "a&b&c|t|x",
		"A\uff0cB|T|X":      "a&b|t|x",     // 全角逗号也是分隔符
		"妳|祂|牠":             "你|他|它",       // OpenCC 表里没有,走异体字表兜底
		"藉藉无名|X|Y":          "藉藉无名|x|y",    // 词组取最长:「藉藉」单独也是词组,先命中它会变成「借借」
		"上\uf99b|X|Y":       "上\uf99b|x|y", // 兼容表意字符与「鍊」规范等价,但按字节不等,不命中「上鍊」
	}
	for in, want := range loose {
		if got := loosenEnrichKey(in); got != want {
			t.Errorf("loosenEnrichKey(%q) = %q, want %q", in, got, want)
		}
	}
	clean := map[string]string{
		"A\u200dB":         "AB",
		"👩\u200d🎤 Song":    "👩🎤 Song",
		"A\u2009B":         "A B",
		"\u3000X\u2028":    "X",
		" A\u00a0\u00a0B ": "A B",
	}
	for in, want := range clean {
		if got := cleanMediaTag(in); got != want {
			t.Errorf("cleanMediaTag(%q) = %q, want %q", in, got, want)
		}
	}
	title := map[string]string{
		"A (B (C)":        "A",
		"A (B) (C)":       "A",
		"歌 (Live)":        "歌 (Live)",
		"歌（译名）[Explicit]": "歌",
		"(Interlude)":     "(Interlude)",
		"歌 (Live\u0301)":  "歌 (Live\u0301)", // 版本词按字节找,后面跟组合符也算
	}
	for in, want := range title {
		if got := normEnrichTitle(in); got != want {
			t.Errorf("normEnrichTitle(%q) = %q, want %q", in, got, want)
		}
	}
	if got := sanitizeLyricsFilename("A|B\u200b"); got != "A - B\u200b" {
		t.Errorf("sanitizeLyricsFilename 不该裁掉 U+200B,got %q", got)
	}
	canon := []struct{ in, want, sha string }{
		{"[00:01.00]词\u200b\n[00:02.00]\u200b二", "词\u200b\n\u200b二", "75044a9df204"},
		{"[00:01.00]]\u0301x", "]\u0301x", "ff3cee9eb5f6"},
	}
	for _, c := range canon {
		if got := manualPickCanonicalLyrics(c.in); got != c.want {
			t.Errorf("manualPickCanonicalLyrics(%q) = %q, want %q", c.in, got, c.want)
		}
		if got := manualPickFingerprint(c.in); got != c.sha {
			t.Errorf("manualPickFingerprint(%q) = %q, want %q", c.in, got, c.sha)
		}
	}
}
