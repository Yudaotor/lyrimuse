package main

import (
	"os"
	"reflect"
	"testing"
)

func donorLines(lrc ...string) []unmaskLine {
	var out []unmaskLine
	for _, s := range lrc {
		out = append(out, lrcTimedLines(s)...)
	}
	return out
}

// 同一行去掉星号以外的部分逐字一致才补:整词打码、词中打码、中文屏蔽词、行尾打码。
func TestUnmaskLRCFillsFromMatchingDonorLine(t *testing.T) {
	cases := []struct{ masked, donor, want string }{
		{"[02:25.90]But I'm ******* hungry", "[02:26.28]But I'm fuckin' hungry", "[02:25.90]But I'm fuckin' hungry"},
		{"[00:10.00]I don't give a f**k", "[00:10.40]I don't give a fuck", "[00:10.00]I don't give a fuck"},
		{"[02:38.70]我不需要**因为LOVE才是我的麻醉物", "[02:38.90]我不需要drug因为LOVE才是我的麻醉物", "[02:38.70]我不需要drug因为LOVE才是我的麻醉物"},
		{"[00:30.00]Can't say **", "[00:30.20]can't  say shit", "[00:30.00]Can't say shit"},
		{"[02:26.00]But I'm ****ing hungry", "[02:26.10]But I'm fucking hungry", "[02:26.00]But I'm fucking hungry"},
	}
	for _, c := range cases {
		got, filled := unmaskLRC("[ar:x]\n"+c.masked+"\n[00:50.00]next", donorLines(c.donor))
		if got != "[ar:x]\n"+c.want+"\n[00:50.00]next" || len(filled) != 1 {
			t.Errorf("unmaskLRC(%q) = %q, filled=%v", c.masked, got, filled)
		}
	}
}

// 别家同一行多带标点、把两行并成了一行(打码这一行是它的开头,或中间从词边界起的一段)也认。
func TestUnmaskLRCToleratesPunctuationAndMergedLines(t *testing.T) {
	cases := []struct{ masked, donor, want string }{
		{"[01:09.68]But ya n**ga think I'm live", "[01:09.44]But ya nigga think I'm live, I don't want him", "[01:09.68]But ya nigga think I'm live"},
		{"[00:08.26](This b***h gon' make me)", "[00:06.67]\"This bitch gon' make me\"", "[00:08.26](This bitch gon' make me)"},
		{"[00:41.20]When will I finally get some ** rest", "[00:41.07]When will I finally get some fucking rest?", "[00:41.20]When will I finally get some fucking rest"},
		{"[00:07.06]You a p***y boy we goin' bar for", "[00:06.93]You a pussy boy, we goin' bar for bar like back-to-back (Facts)", "[00:07.06]You a pussy boy we goin' bar for"},
		{"[01:00.00]she itching for some d**k", "[01:00.30]Yeah she itching for some dick and now", "[01:00.00]she itching for some dick"},
	}
	for _, c := range cases {
		if got, _ := unmaskLRC(c.masked, donorLines(c.donor)); got != c.want {
			t.Errorf("unmaskLRC(%q) = %q, want %q", c.masked, got, c.want)
		}
	}
	// 上下文短、打码在行尾、别家那一行更长:按开头对,原词吃到词尾。
	if got, _ := unmaskLRC("[00:10.00]go to ****", donorLines("[00:10.00]go to bed now")); got != "[00:10.00]go to bed" {
		t.Errorf("开头对上: %q", got)
	}
	// 中间一段要上下文够长、从词边界起;能整行对上的不用宽档。
	if got, _ := unmaskLRC("[00:10.00]go to ****", donorLines("[00:10.00]I said go to bed")); got != "[00:10.00]go to ****" {
		t.Errorf("上下文短的不该按中间一段对: %q", got)
	}
	if got, _ := unmaskLRC("[00:10.00]some ** rest", donorLines("[00:10.00]some good rest tonight", "[00:12.00]some fucking rest")); got != "[00:10.00]some fucking rest" {
		t.Errorf("整行对上的该比开头对上的优先: %q", got)
	}
}

// 对不上的不补:上下文不同、donor 自己也打码、只剩星号没有上下文、原词带空格。
func TestUnmaskLRCLeavesUnmatchedLines(t *testing.T) {
	for _, c := range []struct{ masked, donor string }{
		{"[00:10.00]I don't give a ****", "[00:10.00]I don't care a fuck"},
		{"[00:10.00]I'm ******* hungry", "[00:10.00]I'm ****in' hungry"},
		{"[00:10.00]*****", "[00:10.00]Fuck"},
		{"[00:10.00]** 你", "[00:10.00]我 你"},
		{"[00:10.00]say ** now", "[00:10.00]say two words now"},
	} {
		if got, filled := unmaskLRC(c.masked, donorLines(c.donor)); got != c.masked || filled != nil {
			t.Errorf("unmaskLRC(%q, %q) = %q, 该原样不动", c.masked, c.donor, got)
		}
	}
}

// 几行都对得上时取时间最近的那一行;时间差超过 3 秒的不认。
func TestUnmaskLRCPicksNearestDonorLine(t *testing.T) {
	donors := donorLines("[01:07.00]go to hell\n[01:10.00]go to bed")
	if got, _ := unmaskLRC("[01:09.00]go to ****", donors); got != "[01:09.00]go to bed" {
		t.Errorf("got %q, 要时间最近的 bed", got)
	}
	if got, _ := unmaskLRC("[00:20.00]I'm ******* hungry", donorLines("[02:26.00]I'm so hungry")); got != "[00:20.00]I'm ******* hungry" {
		t.Errorf("别处一句同形的歌词不该拿来填: %q", got)
	}
}

// 逐字:星号落在一个词条里只换字;连着几个词条(每个星号单独计时)并成一个词条,起点取头一个、终点取末一个;
// 别的词条时间一个不动。
func TestUnmaskYRCKeepsWordTiming(t *testing.T) {
	donors := donorLines("[02:26.28]But I'm fuckin' hungry", "[02:38.90]我不需要drug因为LOVE")
	one := "[145905,2288](145905,463,0)But (146368,200,0)I'm (146568,887,0)******* (147455,600,0)hungry"
	if got := unmaskYRC(one, donors); got != "[145905,2288](145905,463,0)But (146368,200,0)I'm (146568,887,0)fuckin' (147455,600,0)hungry" {
		t.Errorf("单个词条 = %q", got)
	}
	split := "[158708,2840](158708,100,0)我(158808,100,0)不(158908,100,0)需(159008,100,0)要(159108,60,0)*(159168,80,0)*(159248,100,0)因(159348,100,0)为(159448,300,0)LOVE"
	want := "[158708,2840](158708,100,0)我(158808,100,0)不(158908,100,0)需(159008,100,0)要(159108,140,0)drug(159248,100,0)因(159348,100,0)为(159448,300,0)LOVE"
	if got := unmaskYRC(split, donors); got != want {
		t.Errorf("跨词条 = %q\n want %q", got, want)
	}
	for _, mixed := range []string{
		"[158708,2840](158708,100,0)我不需要*(159108,60,0)*因(159248,100,0)为LOVE",
		"[158708,2840](158708,100,0)我不需要(159108,60,0)*(159168,80,0)*因(159248,100,0)为LOVE",
	} {
		if got := unmaskYRC(mixed, donors); got != mixed {
			t.Errorf("星号跟别的字混在词条里该不补: %q", got)
		}
	}
}

// 罗马音:同一时刻那一行星号段数一样、原词全是 ASCII 才补;补进去的是汉字就不补(那要重新注音)。
func TestUnmaskRomaASCII(t *testing.T) {
	roma := "[02:38.70]wǒ bù xū yào**yīn wèi\n[02:40.00]**"
	at := lrcTimedLines("[02:38.70]x")[0].at
	if got := unmaskRomaASCII(roma, map[int][]string{at: {"drug"}}); got != "[02:38.70]wǒ bù xū yàodrugyīn wèi\n[02:40.00]**" {
		t.Errorf("ASCII 原词 = %q", got)
	}
	if got := unmaskRomaASCII(roma, map[int][]string{at: {"毒品"}}); got != roma {
		t.Errorf("汉字原词不该补进罗马音: %q", got)
	}
}

// 候选这一层:打码的候选按别的候选补词、记下原文;分数和名次不动;两份都打码的不互相补。
func TestApplyUnmaskedWords(t *testing.T) {
	results := []scoredLyricCandidateResult{
		{Source: "kugou", Score: 1326, Lyrics: "[02:25.90]But I'm ******* hungry",
			LyricsYRC: "[145900,2000](145900,500,0)But (146400,200,0)I'm (146600,800,0)******* (147400,500,0)hungry"},
		{Source: "qq", Score: 1251, Lyrics: "[02:25.90]But I'm ******* hungry"},
		{Source: "deezer", Score: 1200, Lyrics: "[02:26.28]But I'm fuckin' hungry"},
	}
	applyUnmaskedWords(results)
	k := results[0]
	if k.Lyrics != "[02:25.90]But I'm fuckin' hungry" || k.Score != 1326 || k.unmasked == nil ||
		k.unmasked.lyrics != "[02:25.90]But I'm ******* hungry" || k.unmasked.yrc == "" {
		t.Fatalf("kugou = %+v", k)
	}
	if k.LyricsYRC != "[145900,2000](145900,500,0)But (146400,200,0)I'm (146600,800,0)fuckin' (147400,500,0)hungry" {
		t.Errorf("kugou 逐字 = %q", k.LyricsYRC)
	}
	if results[2].unmasked != nil || results[2].Lyrics != "[02:26.28]But I'm fuckin' hungry" {
		t.Errorf("deezer 不该动: %+v", results[2])
	}

	both := []scoredLyricCandidateResult{
		{Source: "kugou", Score: 2, Lyrics: "[00:01.00]go to ****"},
		{Source: "qq", Score: 1, Lyrics: "[00:01.00]go to ****"},
	}
	applyUnmaskedWords(both)
	if both[0].unmasked != nil || both[1].unmasked != nil {
		t.Error("两份都打码,没有可补的原词")
	}
}

// 存着的是打码原文:同源候选补好了就换成补好的那几份,罗马音照正文补进去的 ASCII 原词补;别的源、内容不同的不动。
func TestGainUnmaskedWords(t *testing.T) {
	scored := []scoredLyricCandidateResult{
		{Source: "qq", Score: 1200, Lyrics: "[02:38.70]我不需要**因为LOVE"},
		{Source: "netease", Score: 727, Lyrics: "[02:38.90]我不需要drug因为LOVE"},
	}
	applyUnmaskedWords(scored)
	e := enrichEntry{LyricsSource: "qq", Lyrics: bt("[02:38.70]我不需要**因为LOVE"), LyricsRoma: bt("[02:38.70]wǒ bù xū yào**yīn wèi LOVE")}
	if got := unmaskedCounterpart("qq", e.Lyrics, scored); !got.EqualString("[02:38.70]我不需要drug因为LOVE") {
		t.Errorf("unmaskedCounterpart = %q", got.String())
	}
	if !gainUnmaskedWords(&e, scored) || e.Lyrics.String() != "[02:38.70]我不需要drug因为LOVE" ||
		e.LyricsRoma.String() != "[02:38.70]wǒ bù xū yàodrugyīn wèi LOVE" {
		t.Fatalf("gain = %q / %q", e.Lyrics.String(), e.LyricsRoma.String())
	}
	withYRC := []scoredLyricCandidateResult{
		{Source: "qq", Score: 2, Lyrics: "[00:01.00]go to ****", LyricsYRC: "[1000,900](1000,300,0)go (1300,300,0)to (1600,300,0)****"},
		{Source: "deezer", Score: 1, Lyrics: "[00:01.10]go to bed"},
	}
	applyUnmaskedWords(withYRC)
	retimed := enrichEntry{LyricsSource: "qq", Lyrics: bt("[00:01.00]go to ****"), LyricsYRC: bt("[1000,900](1000,450,0)go (1450,150,0)to (1600,300,0)****")}
	if !gainUnmaskedWords(&retimed, withYRC) || retimed.LyricsYRC.String() != "[1000,900](1000,450,0)go (1450,150,0)to (1600,300,0)****" {
		t.Errorf("存着的逐字跟候选原文不同(校过时间)不该换: %q", retimed.LyricsYRC.String())
	}
	other := enrichEntry{LyricsSource: "kugou", Lyrics: bt("[02:38.70]我不需要**因为LOVE")}
	if gainUnmaskedWords(&other, scored) {
		t.Error("不同源的条目不该换")
	}
	edited := enrichEntry{LyricsSource: "qq", Lyrics: bt("[02:38.70]我不要**因为LOVE")}
	if gainUnmaskedWords(&edited, scored) || !unmaskedCounterpart("qq", edited.Lyrics, scored).Equal(edited.Lyrics) {
		t.Error("正文跟候选原文不同的不该换")
	}
}

// 开播补查:当前歌词有打码词才来,闸跟别的理由一样,算进重试次数上限,一次进程只来一次。
func TestMaskedLyricsRecheck(t *testing.T) {
	masked := enrichEntry{Lyrics: bt("[00:01.00]go to ****")}
	if !maskedLyricsWorthRecheck(masked, false, true) {
		t.Error("有打码词该补查")
	}
	for name, ok := range map[string]bool{
		"没打码":  maskedLyricsWorthRecheck(enrichEntry{Lyrics: bt("[00:01.00]go to bed")}, false, true),
		"关了跟进": maskedLyricsWorthRecheck(masked, false, false),
		"校准过":  maskedLyricsWorthRecheck(masked, true, true),
		"手改过":  maskedLyricsWorthRecheck(enrichEntry{Lyrics: masked.Lyrics, ManualLyrics: true}, false, true),
		"纯音乐":  maskedLyricsWorthRecheck(enrichEntry{Lyrics: masked.Lyrics, Instrumental: true}, false, true),
		"次数用完": maskedLyricsWorthRecheck(enrichEntry{Lyrics: masked.Lyrics, LyricsRetryCount: lyricsRetryMaxAttempts}, false, true),
	} {
		if ok {
			t.Errorf("%s:不该补查", name)
		}
	}
	t.Cleanup(func() { delete(maskedLyricsRechecked, "k") })
	r := lyricsRecheck{masked: true}
	if !r.due() || r.String() != "masked" {
		t.Errorf("due=%v String=%q", r.due(), r.String())
	}
	r.consumeLocked("k")
	if !maskedLyricsRechecked["k"] {
		t.Error("起过一轮该记成用过")
	}
}

// 两条打分流水线都在借译文之前补词;升级重试和重新打分两条路都先对齐快照、再换条目。
func TestUnmaskWiredIntoPipelines(t *testing.T) {
	data, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(data)
	for snippet, want := range map[string]int{
		"applyUnmaskedWords(out)\n\tapplyBorrowedTranslations(out)":         1,
		"applyUnmaskedWords(results)\n\tapplyBorrowedTranslations(results)": 1,
		"if gainUnmaskedWords(&e, scored) {":                                2,
		"startLyrics = unmaskedCounterpart(":                                2,
	} {
		if n := countCode(src, snippet); n != want {
			t.Errorf("%q 出现 %d 次,该是 %d 次", snippet, n, want)
		}
	}
	if !reflect.DeepEqual(lyricMaskRunRe.FindAllString("a*b**c***", -1), []string{"**", "***"}) {
		t.Error("单个星号不算打码")
	}
}
