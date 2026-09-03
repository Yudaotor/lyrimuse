// 置乱器自身的单测:双射 / 分类保持 / 结构段原样 / 明文探针,以及最关键的一条——对一组合成的
// 多源候选,置乱前后 rankLyricSourceResults 的结果逐项相同(这也是采集器写样本前的硬闸)。
// 下面的"歌词"全是虚构占位,不是任何真实曲目。
package main

import (
	"strings"
	"testing"
	"unicode"
)

func TestGoldenHanPoolIsSimplifiedStable(t *testing.T) {
	pool := goldenHanPool()
	if len(pool) < 5000 {
		t.Fatalf("扩展 A 区可用池太小: %d", len(pool))
	}
	for _, r := range pool {
		s := string(r)
		if toSimplified(s) != s {
			t.Fatalf("池里的 %q 会被 toSimplified 改写,置乱后 normLoose 就不再是恒等了", s)
		}
		if !unicode.Is(unicode.Han, r) || !unicode.IsLetter(r) {
			t.Fatalf("池里的 %q 不是 Han/Letter", s)
		}
	}
}

func TestGoldenSegmentLRCLineKeepsStructure(t *testing.T) {
	cases := []struct {
		line       string
		wantKeep   []string // 必须原样出现在 keep 段里的片段
		wantScramb string   // 唯一的置乱段
	}{
		{"[00:12.34]占位歌词一句", []string{"[00:12.34]"}, "占位歌词一句"},
		{"[00:12.34][01:20.00]两个戳的占位行\r", []string{"[00:12.34][01:20.00]"}, "两个戳的占位行\r"},
		{"[00:01.00]男：占位对唱句", []string{"[00:01.00]", "男："}, "占位对唱句"},
		{"[00:01.00]v1：Placeholder duet", []string{"v1："}, "Placeholder duet"},
		{"[00:01.00]作词 : 某某人", []string{"作词 :"}, " 某某人"},
		{"[00:01.00]电吉他：某某人", []string{"电吉他："}, "某某人"},
		{"[00:01.00]OP: Some Publisher", []string{"OP:"}, " Some Publisher"},
		{"[00:01.00]陈某某：占位对唱句", nil, "陈某某：占位对唱句"},
		{"[00:01.00]Executive Producer : 某某人", nil, "Executive Producer : 某某人"},
		{"[ti:占位标题]", []string{"[ti:占位标题]"}, ""},
		{"[kana:ひらがな]", []string{"[kana:", "]"}, "ひらがな"},
		{"[00:00.00]纯音乐，请欣赏", []string{"[00:00.00]纯音乐，请欣赏"}, ""},
		{"\uFEFF[id:$00000000]", []string{"\uFEFF", "[id:$00000000]"}, ""},
		{"", nil, ""},
	}
	for _, c := range cases {
		segs := goldenSegmentLRCLine(c.line)
		var keep, scr []string
		for _, s := range segs {
			if s.scramble {
				scr = append(scr, s.text)
			} else {
				keep = append(keep, s.text)
			}
		}
		joined := strings.Join(keep, "")
		for _, k := range c.wantKeep {
			if !strings.Contains(joined, k) {
				t.Errorf("%q: 原样段里缺 %q(实际 %q)", c.line, k, keep)
			}
		}
		if got := strings.Join(scr, ""); got != c.wantScramb {
			t.Errorf("%q: 置乱段 期望 %q 实际 %q", c.line, c.wantScramb, got)
		}
		// 段拼回去必须等于原行——分段不许丢字。
		var all strings.Builder
		for _, s := range segs {
			all.WriteString(s.text)
		}
		if all.String() != c.line {
			t.Errorf("%q: 段拼回去不等于原行: %q", c.line, all.String())
		}
	}
}

func TestGoldenSegmentYRCLine(t *testing.T) {
	line := "[1000,2000](1000,500,0)v1：(1500,500,0)占位(2000,500,0)Word (2500,500,0)词"
	segs := goldenSegmentYRCLine(line)
	var scr []string
	for _, s := range segs {
		if s.scramble {
			scr = append(scr, s.text)
		}
	}
	if got := strings.Join(scr, "|"); got != "占位|Word |词" {
		t.Errorf("YRC 置乱段 期望 [占位|Word |词] 实际 [%s]", got)
	}
	var all strings.Builder
	for _, s := range segs {
		all.WriteString(s.text)
	}
	if all.String() != line {
		t.Errorf("段拼回去不等于原行")
	}
}

func TestGoldenScramblerIsClassPreservingBijection(t *testing.T) {
	text := "[00:01.00]占位汉字句子 Placeholder Words ひらがな カタカナ 한글 123\n[00:02.00]占位汉字重复 words"
	s := newGoldenScrambler("unit", []goldenText{{text, false}})
	out := s.scrambleText(text, false)
	in := goldenCanon(text)
	ir, or := []rune(in), []rune(out)
	if len(ir) != len(or) {
		t.Fatalf("长度变了: %d → %d", len(ir), len(or))
	}
	fwd := map[rune]rune{}
	bwd := map[rune]rune{}
	for i := range ir {
		a, b := ir[i], or[i]
		if goldenClassify(a) != goldenClassify(b) {
			t.Errorf("字符类变了: %q → %q", a, b)
		}
		if goldenClassify(a) == goldenClassOther && a != b {
			t.Errorf("非文字字符不该动: %q → %q", a, b)
		}
		if prev, ok := fwd[a]; ok && prev != b {
			t.Errorf("同一字符映到两个替身: %q → %q / %q", a, prev, b)
		}
		if prev, ok := bwd[b]; ok && prev != a {
			t.Errorf("两个字符映到同一替身: %q ← %q / %q", b, prev, a)
		}
		fwd[a], bwd[b] = b, a
		if goldenClassify(a) == goldenClassHan && a == b {
			t.Errorf("汉字没被替换: %q", a)
		}
		if unicode.IsUpper(a) != unicode.IsUpper(b) {
			t.Errorf("大小写变了: %q → %q", a, b)
		}
	}
	if !strings.HasPrefix(out, "[00:01.00]") || !strings.Contains(out, "\n[00:02.00]") || !strings.Contains(out, " 123") {
		t.Errorf("时间戳/数字没有原样保留: %q", out)
	}
	if line, bad := goldenFindUnscrambledLine(out); bad {
		t.Errorf("置乱后的文本被探针判成明文: %q", line)
	}
	if _, bad := goldenFindUnscrambledLine(text); !bad {
		t.Errorf("明文没被探针识别")
	}
}

// 合成一组多源候选(占位文本),验证置乱前后打分链路结果逐项相同——共识、时长、署名、语言闸、
// 逐字、译文/罗马音全部走到。
func TestGoldenScrambleKeepsRankingParity(t *testing.T) {
	saved := features
	t.Cleanup(func() { features = saved })
	features.LyricsTranslationLanguage = "zh"
	features.LyricsSources = nil
	features.LyricsSourceMode = lyricsModeSmart

	body := func(prefix string, n int, withCredit bool) string {
		var b strings.Builder
		if withCredit {
			b.WriteString("[00:00.50]作词：占位甲\r\n[00:01.00]作曲：占位乙\r\n")
		}
		for i := 0; i < n; i++ {
			b.WriteString("[00:")
			b.WriteString(pad2(10 + i*3))
			b.WriteString(".00]")
			if i%4 == 0 {
				b.WriteString("女：")
			}
			b.WriteString(prefix)
			b.WriteString("占位歌词第")
			b.WriteRune(rune('一' + i%9))
			b.WriteString("句 placeholder line\r\n")
		}
		return b.String()
	}
	yrc := func(n int) string {
		var b strings.Builder
		b.WriteString("[ti:占位]\n")
		for i := 0; i < n; i++ {
			start := (10 + i*3) * 1000
			b.WriteString("[")
			b.WriteString(itoa(start))
			b.WriteString(",2000](")
			b.WriteString(itoa(start))
			b.WriteString(",500,0)占位(")
			b.WriteString(itoa(start + 500))
			b.WriteString(",500,0)歌词(")
			b.WriteString(itoa(start + 1000))
			b.WriteString(",1000,0)placeholder\n")
		}
		return b.String()
	}
	ja := "[00:10.00]ひらがなのプレースホルダー\n[00:13.00]カタカナ の 占位\n[00:16.00]もう一つの プレースホルダー行\n[00:19.00]終わり の 行\n"
	roma := "[00:10.00]hiragana no pureesuhorudaa\n[00:13.00]katakana no zhanwei\n[00:16.00]mou hitotsu\n[00:19.00]owari\n"
	tr := "[00:10.00]占位译文一\n[00:13.00]占位译文二\n[00:16.00]占位译文三\n[00:19.00]占位译文四\n"
	raw := map[string]lyricSourceResult{
		"netease": {source: "netease", ne: neteaseInfo{
			Lyrics: body("", 40, true), YRC: yrc(40), Trans: tr, Roma: roma, DurationSecs: 130,
			Title: "占位曲", Artist: "占位歌手", Album: "占位专辑",
		}},
		"qq":     {source: "qq", lyr: body("", 40, true), yrc: yrc(40), tr: tr, matchTitle: "占位曲", matchArtist: "占位歌手", matchAlbum: "占位专辑 (Live)", srcDur: 131},
		"kugou":  {source: "kugou", lyr: body("另一版", 38, false), matchTitle: "占位曲 (Remix)", matchArtist: "占位歌手", matchAlbum: "精选", srcDur: 200},
		"lrclib": {source: "lrclib", lyr: "只有一行纯文本没有时间戳", plainOnly: true, matchTitle: "占位曲", matchArtist: "占位歌手"},
		"amll":   {source: "amll", amll: amllResult{lrc: ja, tr: tr}},
		"musixmatch": {source: "musixmatch", lyr: "[00:00.50]作词：占位甲\n[00:01.00]作曲：占位乙\n[00:02.00]编曲：占位丙\n[00:03.00]纯音乐，请欣赏\n",
			matchTitle: "占位曲", matchArtist: "占位歌手"},
		"applecover": {source: "applecover", matchCover: "https://example.invalid/cover.jpg"},
	}
	before := goldenExpectFromRanked(rankLyricSourceResults("占位歌手", "占位曲", "占位专辑", 130, raw))
	scrambled := scrambleLyricRound(raw, "parity")
	after := goldenExpectFromRanked(rankLyricSourceResults("占位歌手", "占位曲", "占位专辑", 130, scrambled))
	// 冠军正文指纹本来就会变(正文换了字),比对前对齐。
	after.WinnerFingerprint = before.WinnerFingerprint
	d := diffGoldenExpect(before, after)
	if len(d.semantic)+len(d.snapshot) > 0 {
		t.Fatalf("置乱破坏了打分结果:\n  %s", strings.Join(append(d.semantic, d.snapshot...), "\n  "))
	}
	// 这组合成数据得真的走到那几条判据,不然 parity 是空话。
	if before.Winner == "" || len(before.Ranked) < 5 {
		t.Fatalf("合成数据没产生足够的候选: %+v", before)
	}
	if before.Verdicts["lrclib"] != scoreRejectPlainTextOnly || before.Verdicts["musixmatch"] != scoreRejectCreditOnly {
		t.Errorf("合成数据的否决没按预期落下: %v", before.Verdicts)
	}
	for src, r := range scrambled {
		for _, text := range []string{r.lyr, r.yrc, r.tr, r.roma, r.ne.Lyrics, r.ne.YRC, r.ne.Trans, r.amll.lrc, r.amll.tr} {
			if line, bad := goldenFindUnscrambledLine(text); bad {
				t.Errorf("%s 置乱后仍有明文: %q", src, line)
			}
		}
	}
}

func pad2(n int) string {
	if n < 10 {
		return "0" + itoa(n)
	}
	return itoa(n)
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}
