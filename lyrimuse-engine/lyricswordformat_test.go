package main

import (
	"bytes"
	"regexp"
	"slices"
	"strings"
	"testing"
)

func lyricsWordSampleInput() lyricsWordFileInput {
	yrc := strings.Join([]string{
		"[ti:Sample]",
		`[1000,2500](1000,500,0)Say (1500,500,0)"hi" (2000,1000,0)& go`,
		"[4000,3000](4000,600,0)你(4600,400,0)好(5500,1000,0)吗",
		"[8000,1500](7950,550,0)早(8500,500,0)了",
	}, "\n")
	return lyricsWordFileInput{
		artist: "A & B", title: "Song \"1\"", album: "Al <x>", source: "qq", manual: true,
		yrc: yrc, nativeYRC: yrc, bg: "[4000,3000](4700,800,0)(ooh(5500,500,0) ah)", durationSecs: 241.6,
	}
}

func lyricsWordTimedLines(yrc string) []string {
	var out []string
	for _, l := range strings.Split(yrc, "\n") {
		if lyricsWordYRCHeadRe.MatchString(l) {
			out = append(out, l)
		}
	}
	return out
}

// 每种格式写出来再读回去:认得出是哪一首、文件头一样,逐字的行原样回来(时间都是 10 毫秒的整数倍,增强 LRC 也不丢)。
func TestLyricsWordFormatsRoundTrip(t *testing.T) {
	in := lyricsWordSampleInput()
	for _, f := range lyricsWordFormatsAll {
		data := sealLyricsWordFile(f, encodeLyricsWordText(f, in))
		if !lyricsWordFileMatches(f, data, in) {
			t.Errorf("%s: 刚写出的文件认不出是导出的那一份", f)
			continue
		}
		plain, ok := openLyricsWordFile(f, data)
		p := decodeLyricsWordText(f, plain)
		if !ok || !p.ok || p.artist != in.artist || p.title != in.title || p.album != in.album || p.source != in.source || !p.manual {
			t.Errorf("%s: 身份读不回来: %+v", f, p.parsedLyricsFile)
			continue
		}
		got, want := lyricsWordTimedLines(p.body), lyricsWordTimedLines(in.yrc)
		if strings.Join(got, "\n") != strings.Join(want, "\n") {
			t.Errorf("%s: 逐字读回来不一样\n got  %q\n want %q", f, got, want)
		}
		other := in
		other.yrc = strings.Replace(in.yrc, "(4600,400,0)好", "(4600,400,0)坏", 1)
		other.nativeYRC = other.yrc
		if lyricsWordFileMatches(f, data, other) {
			t.Errorf("%s: 缓存变了,旧文件还被当成导出的那一份", f)
		}
	}
}

// QQ 音乐本地 .qrc 的布局:整份异或后开头是固定的 11 字节,后面的 3DES 密文按 8 字节对齐;3DES 那层跟接口给的 hex
// 密文同一种,接口那条解密路径也解得开;正文用 LDDC 那条正则(非贪婪、不反转义)取得到。
func TestLyricsWordQRCFileLayout(t *testing.T) {
	in := lyricsWordSampleInput()
	data := sealLyricsWordFile(lyricsWordQRC, encodeLyricsWordText(lyricsWordQRC, in))
	x := append([]byte(nil), data...)
	qmc1XOR(x)
	if string(x[:len(lyricsQRCFileHeader)]) != lyricsQRCFileHeader || (len(x)-len(lyricsQRCFileHeader))%8 != 0 {
		t.Fatalf("外壳不对: %q", x[:min(len(x), 16)])
	}
	var hex strings.Builder
	for _, b := range x[len(lyricsQRCFileHeader):] {
		hex.WriteString(strings.ToUpper(strings.TrimPrefix(string("0123456789abcdef"[b>>4])+string("0123456789abcdef"[b&15]), "")))
	}
	plain := decryptQRC(hex.String())
	if !strings.Contains(plain, `SaveTime="242"`) {
		t.Errorf("接口那条解密路径解不开,或 SaveTime 不是整首秒数: %.200q", plain)
	}
	m := regexp.MustCompile(`(?s)<Lyric_1 LyricType="1" LyricContent="(.*?)"/>`).FindStringSubmatch(plain)
	if m == nil || !strings.Contains(m[1], `Say (1000,500)"hi" (1500,500)`) || !strings.Contains(m[1], "[ar:A & B]") {
		t.Errorf("别的工具按 QQ 的写法取不到正文: %.300q", plain)
	}
}

func TestLyricsWordKRCFileLayout(t *testing.T) {
	in := lyricsWordSampleInput()
	data := sealLyricsWordFile(lyricsWordKRC, encodeLyricsWordText(lyricsWordKRC, in))
	if !bytes.HasPrefix(data, []byte("krc1")) {
		t.Fatalf("没有 krc1 魔数: %q", data[:4])
	}
	plain := decryptKRCBytes(data)
	if !strings.Contains(plain, "[8000,1500]<-50,550,0>早<500,500,0>了") {
		t.Errorf("词始要写成相对行始的偏移(可以是负数): %q", plain)
	}
}

// TTML 带得上背景人声,读回来是单独一轨,不并进主句。
func TestLyricsWordTTMLKeepsBackgroundVocals(t *testing.T) {
	in := lyricsWordSampleInput()
	plain := encodeLyricsWordText(lyricsWordTTML, in)
	if !strings.Contains(plain, `<span ttm:role="x-bg">`) {
		t.Fatalf("背景人声没写进去: %s", plain)
	}
	p := decodeLyricsWordText(lyricsWordTTML, plain)
	if !p.hasBG || p.bg != in.bg {
		t.Errorf("背景人声读回来: %q, want %q", p.bg, in.bg)
	}
	if strings.Contains(p.body, "ooh") {
		t.Errorf("背景人声并进了主句: %q", p.body)
	}
}

// 别处来的增强 LRC:三位毫秒、最后一个词没写终点、没有逐字标记的行,都读得出来。
func TestEnhancedLRCToYRCForeignShapes(t *testing.T) {
	got := enhancedLRCToYRC(strings.Join([]string{
		"[ar:x]",
		"[00:01.000]<00:01.000>Hel<00:01.250>lo <00:01.500>world",
		"[00:03.00]plain line",
		"[00:05.00]<00:05.10>a<00:05.30><00:05.50>b<00:05.80>",
	}, "\n"))
	want := strings.Join([]string{
		"[ar:x]",
		"[1000,500](1000,250,0)Hel(1250,250,0)lo (1500,1500,0)world",
		"[3000,2000](3000,2000,0)plain line",
		"[5000,800](5100,200,0)a(5500,300,0)b",
	}, "\n")
	if got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
}

func TestLyricsWordFormatSuffixes(t *testing.T) {
	for _, f := range lyricsWordFormatsAll {
		if g, ok := lyricsWordFormatOfSuffix(f.suffix()); !ok || g != f {
			t.Errorf("%s 的后缀 %s 认不回来", f, f.suffix())
		}
		if g, ok := lyricsWordFormatNamed(string(f)); !ok || g != f {
			t.Errorf("%s 的名字认不回来", f)
		}
	}
	if _, ok := lyricsWordFormatOfSuffix(".lrc"); ok {
		t.Error(".lrc 是逐行文件,不是逐字格式")
	}
	// App 那边 CacheKeyTests 钉着同一份字面量(EnrichCacheKeys.lyricsFileSuffixes)。
	if got := lyricsAllFileSuffixes(); !slices.Equal(got, []string{".lrc", ".tr.lrc", ".roma.lrc", ".yrc", ".ttml", ".qrc", ".krc", ".enhanced.lrc"}) {
		t.Errorf("后缀表跟 App 对不上: %v", got)
	}
	if lyricsFileSuffixOf("A - B.enhanced.lrc") != ".enhanced.lrc" {
		t.Errorf("增强 LRC 的文件要认成 .enhanced.lrc,不能认成 .lrc: %q", lyricsFileSuffixOf("A - B.enhanced.lrc"))
	}
}
