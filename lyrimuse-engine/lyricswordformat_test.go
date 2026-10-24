package main

import (
	"bytes"
	"encoding/base64"
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

// TTML 把译文、罗马音挂到逐字各行上:逐行的时间戳跟逐字差两秒也按文字配得上;文字对不上的行不挂。
func TestLyricsWordTTMLCarriesTranslation(t *testing.T) {
	in := lyricsWordSampleInput()
	in.lrc = "[00:03.00]你好吗\n[00:06.00]早了\n[00:10.00]别的行"
	in.tr = "[00:03.00]How are you\n[00:06.00]Too early\n[00:10.00]Other"
	in.roma = "[00:03.00]ni hao ma"
	in.trLang = "en"
	plain := encodeLyricsWordText(lyricsWordTTML, in)
	if !strings.Contains(plain, `>吗</span><span ttm:role="x-bg">`) ||
		!strings.Contains(plain, `<span ttm:role="x-translation" xml:lang="en">How are you</span><span ttm:role="x-roman">ni hao ma</span></p>`) {
		t.Errorf("第二行(你好吗)要带译文和罗马音: %s", plain)
	}
	if !strings.Contains(plain, `>了</span><span ttm:role="x-translation" xml:lang="en">Too early</span></p>`) {
		t.Errorf("第三行(早了)带译文: %s", plain)
	}
	if strings.Contains(plain, "Other") || !strings.Contains(plain, "&amp; go</span></p>") {
		t.Errorf("对不上的行不挂译文: %s", plain)
	}
	r, ok := parseTTMLLyrics(plain, "", false)
	if !ok || !strings.Contains(r.tr, "How are you") || !strings.Contains(r.roma, "ni hao ma") {
		t.Errorf("TTML 读回来认得出译文和罗马音: %q / %q", r.tr, r.roma)
	}
	if p := decodeLyricsWordText(lyricsWordTTML, plain); lyricsWordTimedLines(p.body)[1] != lyricsWordTimedLines(in.yrc)[1] {
		t.Errorf("逐字不受译文影响: %q", p.body)
	}
}

// KRC 把译文写成酷狗的 [language:] 轨:酷狗那套读法(krcLanguageTracks)按行序号对得上,配不上的行留空项占位;
// 罗马音不写;读回来的逐字里没有这一行;没有译文就不写这一行。指纹跟着译文变(YRC 不受影响)。
func TestLyricsWordKRCCarriesTranslation(t *testing.T) {
	in := lyricsWordSampleInput()
	in.lrc = "[00:01.00]Say \"hi\" & go\n[00:03.00]你好吗\n[00:06.00]早了\n[00:20.00]别的行"
	in.tr = "[00:01.00]说声嗨就走\n[00:03.00]How are you\n[00:06.00]Too early\n[00:20.00]Other"
	in.roma = "[00:03.00]ni hao ma"
	// 没有词的计时行不占项;写进文件的逐字接回了括号和声,配译文按缓存原样的那份。
	in.nativeYRC += "\n[12000,500]"
	in.yrc = strings.Replace(in.nativeYRC, "(8500,500,0)了", "(8500,500,0)了 (ooh)", 1)
	plain := encodeLyricsWordText(lyricsWordKRC, in)
	p := parseLyricsBytes([]byte(plain))
	b64, rest := splitKRCLanguageLine(p.body)
	tr, roma := krcLanguageTracks(b64, rest)
	if want := "[00:01.000]说声嗨就走\n[00:04.000]How are you\n[00:08.000]Too early"; tr != want || roma != "" {
		t.Errorf("酷狗读法读回来的译文 / 罗马音不对\n got  %q / %q\n want %q", tr, roma, want)
	}
	if d := decodeLyricsWordText(lyricsWordKRC, plain); strings.Contains(d.body, "[language:") ||
		strings.Join(lyricsWordTimedLines(d.body), "\n") != strings.Join(lyricsWordTimedLines(in.yrc), "\n") {
		t.Errorf("读回来的逐字带着译文行,或逐字变了: %q", d.body)
	}

	partial := in
	partial.tr = "[00:03.00]How are you"
	b64, _ = splitKRCLanguageLine(parseLyricsBytes([]byte(encodeLyricsWordText(lyricsWordKRC, partial))).body)
	raw, _ := base64.StdEncoding.DecodeString(b64)
	if !strings.Contains(string(raw), `"lyricContent":[[""],["How are you"],[""]]`) {
		t.Errorf("每条计时行一项,配不上的留空: %s", raw)
	}

	bare := in
	bare.tr = ""
	far := in
	far.tr = "[00:50.00]远处"
	if strings.Contains(encodeLyricsWordText(lyricsWordKRC, bare), "[language:") ||
		strings.Contains(encodeLyricsWordText(lyricsWordKRC, far), "[language:") {
		t.Errorf("没有译文、或一行都没配上,不写 [language:] 行")
	}
	if lyricsWordFileSource(lyricsWordKRC, "", in) == lyricsWordFileSource(lyricsWordKRC, "", bare) ||
		lyricsWordFileSource(lyricsWordYRC, "", in) != lyricsWordFileSource(lyricsWordYRC, "", bare) {
		t.Errorf("KRC 的指纹要跟着译文变,YRC 的不变")
	}
}

// 配对:同一句挨着唱两遍,各配各的译文(配过的那行不再配);同一句隔着十秒的不配。
func TestLyricsWordLineAuxPairing(t *testing.T) {
	lines := parseYRCDoc("[4000,500](4000,500,0)早了\n[5000,500](5000,500,0)早了\n[30000,500](30000,500,0)走了")
	aux := lyricsWordLineAux(lines, "[00:06.00]早了\n[00:07.50]早了\n[00:40.00]走了", "[00:06.00]A\n[00:07.50]B\n[00:40.00]C", "")
	if aux[0][0] != "A" || aux[1][0] != "B" {
		t.Errorf("挨着的两遍各配各的: %v", aux)
	}
	if _, ok := aux[2]; ok {
		t.Errorf("隔着十秒的不配: %v", aux)
	}
	// 译文多写一位毫秒(`[00:04.681]` 对逐行的 `[00:04.68]`),逐字起点又离得远,只能靠逐行那一行配上。
	aux = lyricsWordLineAux(parseYRCDoc("[2000,500](2000,500,0)Yo this song"), "[00:04.68]Yo this song", "[00:04.681]哟，这首歌", "")
	if aux[0][0] != "哟，这首歌" {
		t.Errorf("译文时间戳差 1 毫秒也算逐行那一行: %v", aux)
	}
}

// 译文跟着逐字的时间走、配不上逐行的那一行时,按逐字行起点 700 毫秒以内最近的找。
func TestLyricsWordLineAuxFallsBackToWordTiming(t *testing.T) {
	lines := parseYRCDoc("[962,4263](962,4263,0)I'm a woman\n[5350,3112](5350,3112,0)Lord knows")
	aux := lyricsWordLineAux(lines, "[00:00.67]I'm a woman\n[00:04.84]Lord knows", "[00:00.96]我是个女人\n[00:06.20]上帝知道", "")
	if aux[0][0] != "我是个女人" {
		t.Errorf("逐行配上了但时间戳对不上逐行,按逐字起点找: %v", aux)
	}
	if _, ok := aux[1]; ok {
		t.Errorf("离逐字起点超过 700 毫秒的不挂: %v", aux)
	}
}
