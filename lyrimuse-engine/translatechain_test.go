package main

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"testing"
	"unicode"
)

// fakeTranslated:单测替身翻译器给的「译文」—— 前缀 + 原文,拉丁字母换成全角、平假名换成片假名。只加前缀、外文
// 照抄的话,跟只转了简体、外文原样留着的假译文分不开,lineTranslated 会把它当成没翻。
func fakeTranslated(prefix, line string) string {
	return prefix + strings.Map(func(r rune) rune {
		switch {
		case r >= 'A' && r <= 'Z', r >= 'a' && r <= 'z':
			return r + 0xFEE0
		case r >= 'ぁ' && r <= 'ゖ':
			return r + ('ァ' - 'ぁ')
		}
		return r
	}, line)
}

func hasKana(s string) bool {
	for _, r := range s {
		if unicode.Is(unicode.Hiragana, r) || unicode.Is(unicode.Katakana, r) {
			return true
		}
	}
	return false
}

// 端上翻译按整批识别一个源语言:批里有假名就当日文,拉丁行原样退回。
func fakeOnDeviceJapaneseBatch(batches *[][]string, mu *sync.Mutex) func(context.Context, string, []string) ([]string, error) {
	return func(_ context.Context, _ string, lines []string) ([]string, error) {
		mu.Lock()
		*batches = append(*batches, append([]string(nil), lines...))
		mu.Unlock()
		japanese := false
		for _, l := range lines {
			japanese = japanese || hasKana(l)
		}
		out := make([]string, len(lines))
		for i, l := range lines {
			if japanese && !hasKana(l) {
				out[i] = l
				continue
			}
			out[i] = fakeTranslated("端:", l)
		}
		return out, nil
	}
}

const mixedJapaneseEnglishLRC = "[00:01.00]きみのことがすき\n[00:02.00]あいたいよ\n[00:03.00]よるがあける\n" +
	"[00:04.00]Kick back\n[00:05.00]I want it all\n"

// 日文夹英文:按文字系统分组各翻一次,两种行都有译文。
func TestMixedScriptSongTranslatesEveryScript(t *testing.T) {
	var batches [][]string
	var mu sync.Mutex
	saved := onDeviceTranslator
	onDeviceTranslator = fakeOnDeviceJapaneseBatch(&batches, &mu)
	t.Cleanup(func() { onDeviceTranslator = saved })

	res, err := machineTranslateLRCWithBase(context.Background(), http.DefaultClient, "http://127.0.0.1:1", mixedJapaneseEnglishLRC, "zh-CN", "", "")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{fakeTranslated("端:", "きみのことがすき"), fakeTranslated("端:", "Kick back"), fakeTranslated("端:", "I want it all")} {
		if !strings.Contains(res.lrc, want) {
			t.Errorf("缺 %q:\n%s", want, res.lrc)
		}
	}
	if len(batches) != 2 {
		t.Fatalf("该按文字系统分两批送,实际 %d 批: %q", len(batches), batches)
	}
	if res.engines != "on-device=5" {
		t.Errorf("engines = %q", res.engines)
	}
}

// 端上翻不了的那一组(比如语言包没装)交给 Google 补,端上已经翻好的那组不再送出去。
func TestOnDeviceFailedGroupFilledByGoogle(t *testing.T) {
	saved := onDeviceTranslator
	onDeviceTranslator = func(_ context.Context, _ string, lines []string) ([]string, error) {
		if !hasKana(lines[0]) {
			return nil, errOnDeviceUnavailable
		}
		out := make([]string, len(lines))
		for i, l := range lines {
			out[i] = fakeTranslated("端:", l)
		}
		return out, nil
	}
	t.Cleanup(func() { onDeviceTranslator = saved })
	var sent []string
	useFakeGoogle(t, func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		var out []string
		for _, l := range strings.Split(r.PostForm.Get("q"), "\n") {
			sent = append(sent, l)
			out = append(out, fakeTranslated("谷:", l))
		}
		fmt.Fprint(w, googleReply(t, out))
	})

	res, err := machineTranslateLRCWithBase(context.Background(), http.DefaultClient, "http://127.0.0.1:1", mixedJapaneseEnglishLRC, "zh-CN", "", "")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{fakeTranslated("端:", "あいたいよ"), fakeTranslated("谷:", "Kick back"), fakeTranslated("谷:", "I want it all")} {
		if !strings.Contains(res.lrc, want) {
			t.Errorf("缺 %q:\n%s", want, res.lrc)
		}
	}
	if len(sent) != 2 {
		t.Fatalf("只该把端上没翻成的两行英文送 Google,实际送了 %q", sent)
	}
	if res.engines != "on-device=3 google=2" {
		t.Errorf("engines = %q", res.engines)
	}
}

// Google 只翻出一小部分、不够数时,MyMemory 只补还没翻出来的行,Google 翻好的那几行保留。
func TestMyMemoryOnlyFillsWhatIsStillMissing(t *testing.T) {
	saved := onDeviceTranslator
	onDeviceTranslator = func(context.Context, string, []string) ([]string, error) { return nil, errOnDeviceUnavailable }
	t.Cleanup(func() { onDeviceTranslator = saved })
	useFakeGoogle(t, func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		var out []string
		for i, l := range strings.Split(r.PostForm.Get("q"), "\n") {
			if i == 0 {
				out = append(out, fakeTranslated("谷:", l))
			} else {
				out = append(out, l) // 原样,没翻动
			}
		}
		fmt.Fprint(w, googleReply(t, out))
	})
	var asked []string
	srv := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		lines := strings.Split(r.URL.Query().Get("q"), "\n")
		asked = append(asked, lines...)
		out := make([]string, len(lines))
		for i, l := range lines {
			out[i] = fakeTranslated("记:", l)
		}
		body, _ := jsonEscape(strings.Join(out, "\n"))
		fmt.Fprintf(w, `{"responseData":{"translatedText":%s},"responseStatus":200}`, body)
	})
	lrc := "[00:01.00]one line\n[00:02.00]two line\n[00:03.00]three line\n[00:04.00]four line\n[00:05.00]five line"
	res, err := machineTranslateLRCWithBase(context.Background(), srv.Client(), srv.URL, lrc, "zh-CN", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(res.lrc, fakeTranslated("谷:", "one line")) || !strings.Contains(res.lrc, fakeTranslated("记:", "five line")) {
		t.Fatalf("Google 那一行要保留、其余由 MyMemory 补:\n%s", res.lrc)
	}
	if len(asked) != 4 {
		t.Fatalf("MyMemory 只该收到还没翻出来的 4 行,实际 %q", asked)
	}
	if res.engines != "google=1 mymemory=4" {
		t.Errorf("engines = %q", res.engines)
	}
}

func TestGroupTextsByScript(t *testing.T) {
	got := groupTextsByScript([]string{"Kick back", "きみ", "I want", "사랑해", "よる"})
	want := [][]int{{0, 2}, {1, 4}, {3}}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("got %v want %v", got, want)
	}
	// 跟选行同一个口径:汉字为主的混排行跟中文行一组,不跟英文行一组。
	got = groupTextsByScript([]string{"跟着我Flow", "Kick back", "我爱你"})
	if want := [][]int{{0, 2}, {1}}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("混排行分组: got %v want %v", got, want)
	}
}

// 抬头判据追平 Swift 侧:繁简、多歌手、双语歌名(含 Apple Music 的「 - 版本」尾巴)、歌手名在括号里。
func TestLooksLikeLyricHeaderLineMirrorsSwift(t *testing.T) {
	cases := []struct {
		text, title, artist string
		want                bool
	}{
		// Swift selftest(CreditLineTests)同名用例
		{"小步舞曲 - 陈绮贞", "小步舞曲", "陳綺貞", true},
		{"无所谓 (Explicit) - 方大同 (Khalil Fong)/张靓颖 (Jane Zhang)", "无所谓", "方大同 & 张靓颖", true},
		{"电子羊 - 某幻君", "电子羊", "某幻君 & 王瀚哲 (中国BOY)", true},
		{"丁世光 - 日出", "日出 The Dawn", "丁世光", true},
		{"GF - 方大同", "GF", "方大同", true},
		{"追 - 陶喆 (David Zee Tao)", "追", "陶喆", true},
		{"陳柏宇-最後的擁抱", "最后的拥抱", "陈柏宇", true},
		{"新的经典 蛋堡 x Jabberloop", "经典!", "蛋堡", false},
		{"First Love", "First Love", "宇多田ヒカル", false},
		{"我 - 你 - 他都在等", "我", "某人", false},
		// 本机缓存里 Go 旧判据漏掉的真实抬头
		{"でしょましょ - 米津玄師 (よねづ けんし)", "でしょましょ", "米津玄师", true},
		{"Caughtup - Musiq Soulchild", "Caughtup", "Musiq Soulchild & AAries", true},
		{"Mine (POP Mix) - Taylor Swift (泰勒·斯威夫特)", "Mine - POP Mix", "Taylor Swift", true},
		{"黑色柳丁 (Live) - 陶喆 (David Zee Tao)", "黑色柳丁 - Live", "陶喆", true},
		{"熊猫 - 江语晨 (Jessie Chiang)", "熊貓", "江語晨 (Jessie Chiang)", true},
		{"Patient Zero - Taylor Swift", "Patient Zero", "Taylor Swift (泰勒絲)", true},
		{"Love Outrolude - 方大同", "Love Outrolude - Instrumental", "方大同", true},
		{"蔡健雅 - 达尔文 II (进化版)", "达尔文 II 进化版", "蔡健雅", true},
		{"Jam - 带不走的风景", "带不走的风景", "Jam", true},
		{"Smoking on my Ex Pack (Explicit) - SZA", "Smoking on my Ex Pack", "SZA", true},
		// 拆出来的短段仍受下限:歌手「Tyler, The Creator」拆出的「The」不能拿去配
		{"Hello - The night", "Hello", "Tyler, The Creator", false},
		// 歌手名换了语种:展示端不认
		{"Throw It Off - 方大同", "Throw It Off", "Khalil Fong", false},
	}
	for _, c := range cases {
		if got := looksLikeLyricHeaderLine(c.text, c.title, c.artist); got != c.want {
			t.Errorf("looksLikeLyricHeaderLine(%q, %q, %q) = %v, want %v", c.text, c.title, c.artist, got, c.want)
		}
	}
}

// 翻译这边再放宽一档:一段等于歌名就跳过,不要求歌手名对得上。
func TestTranslationHeaderLineOnlyNeedsTitle(t *testing.T) {
	cases := []struct {
		text, title, artist string
		want                bool
	}{
		{"Throw It Off - 方大同", "Throw It Off", "Khalil Fong", true},
		{"Official髭男dism - Subtitle", "Subtitle", "Official胡子男dism", true},
		{"熊猫 - 江语晨 (Jessie Chiang)", "熊貓", "江語晨", true},
		{"First Love", "First Love", "宇多田ヒカル", false},
		{"Hello there - my friend", "Hello", "Adele", false},
		{"我 - 你 - 他都在等", "我", "某人", false},
		{"The Dawn - is coming", "日出 The Dawn", "丁世光", false}, // 双语歌名的半段不算
	}
	for _, c := range cases {
		if got := looksLikeTranslationHeaderLine(c.text, c.title, c.artist, "", ""); got != c.want {
			t.Errorf("looksLikeTranslationHeaderLine(%q, %q, %q) = %v, want %v", c.text, c.title, c.artist, got, c.want)
		}
	}
}

func TestTranslationSkipLines(t *testing.T) {
	speakers := map[string]bool{"男": true}
	skip := []string{
		"鼓共同监制/录音师：钱炜安@112F Recording Studio",
		"母带后期处理工程师：黄文萱@Purring Sound Studio",
		"Mastering Engineer: Dale Becker，",
		"Vocal Producer: Someone",
		"Woo woo", "Oh-oh-oh-oh", "Wu ～", "Ooh", "Yeah oh oh oh oh", "Whoa", "Na na na", "Mm",
		"Doo", "(Ooh) Doo-doo-doo-doo",
		// 唱名三种以上,或者只有 do / doo
		"Re So So Si Do Si La", "So, fa, mi, re, la, so, mi, re, do", "Sol Sol Ti Sol Sol La Do", "Do-Re-Mi",
		"Do-do-do-do", "do do do do do do", "(Doo-doo-doo-do-doo-doo-doo-doo)",
	}
	for _, s := range skip {
		if !isTranslationSkipLine(s, speakers) {
			t.Errorf("该跳过: %q", s)
		}
	}
	keep := []string{
		"男：It represent my heart!",
		"Oh baby I love you",
		"Who are you",
		"I'll do anything for you",
		"So tell me baby what're you waiting for?",
		"Turn it up",
		"No no no",
		// 一两种唱名是真歌词;do 后面跟着别的词也是
		"So", "Si, si, si", "So la la", "Do", "Do ya, do ya?", "Doo-wop",
	}
	for _, s := range keep {
		if isTranslationSkipLine(s, speakers) {
			t.Errorf("不该跳过: %q", s)
		}
	}
}

// 中文歌里外文只剩抬头 / 署名 / 拟声行时,整首判成"没东西可翻",不起机翻、不烧重试额度。
func TestChineseSongWithOnlyNoiseLinesHasNothingToTranslate(t *testing.T) {
	lrc := "[00:00.00]熊猫 - 江语晨 (Jessie Chiang)\n[00:05.00]母带后期处理工程师：黄文萱@Purring Sound Studio\n" +
		"[00:06.00]Mastering Engineer: Dale Becker\n" +
		"[00:10.00]我想要一只熊猫\n[00:15.00]陪我看月亮\n[00:20.00]Woo woo\n"
	if hasTranslatableLines(lrc, "zh-CN", "江語晨 (Jessie Chiang)", "熊貓") {
		t.Fatalf("送翻筛选: %q", selectTranslationWork(lrc, "zh-CN", "江語晨 (Jessie Chiang)", "熊貓").uniqueTexts)
	}
	// 同一首歌真有一行英文歌词,照样要翻。
	if !hasTranslatableLines(lrc+"[00:25.00]I'll be there for you\n", "zh-CN", "江語晨 (Jessie Chiang)", "熊貓") {
		t.Fatal("真英文歌词行被一起跳过了")
	}
}
