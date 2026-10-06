package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"reflect"
	"strings"
	"testing"
)

// 外文那部分原样没动(只换了繁简、标点、空白、大小写)的不算译文;留着人名、歌名的真译文照算。
func TestLineTranslated(t *testing.T) {
	for _, c := range []struct {
		orig, got, target string
		want              bool
	}{
		{"Lonely is the night 看著天花板自己發呆", "Lonely is the night 看着天花板自己发呆", "zh-CN", false},
		{"Love oh love 你怎么了", "LOVE OH LOVE 你怎么了", "zh-CN", false},
		{"OP: Sure Recordings Co., Ltd", "OP：Sure Recordings Co., Ltd", "zh-CN", false},
		{"Gotta keep it blazin' hot", "Gotta keep it blazin 'hot", "zh-CN", false},
		{"Hello", "", "zh-CN", false},
		{"Hello", " Hello ", "zh-CN", false},
		{"1999", "1999", "zh-CN", false},
		{"Thank you, my dear friend", "谢谢你，我亲爱的朋友", "zh-CN", true},
		{"S Jabberloop, let's go", "S Jabberloop，我们走吧", "zh-CN", true},
		{`I sing that sweet "Amazing Grace"`, "我唱了那首甜美的《Amazing Grace》", "zh-CN", true},
		{"愛してる", "爱してる", "zh-CN", false},
		{"あいたいよ", "想见你", "zh-CN", true},
		{"Hello world", "Hello world!", "ja", false},
		{"Hello world", "ハローワールド", "ja", true},
		{"我爱你", "我爱你。", "en", false},
		{"我爱你", "I love you", "en", true},
	} {
		if got := lineTranslated(c.orig, c.got, c.target); got != c.want {
			t.Errorf("lineTranslated(%q, %q, %s) = %v, want %v", c.orig, c.got, c.target, got, c.want)
		}
	}
}

func TestDropUntranslated(t *testing.T) {
	texts := []string{"Lonely is the night 看著", "Thank you", "Hello", "Yeah", "extra"}
	got := []string{"Lonely is the night 看着", "谢谢你", "Hello", "", "多出来的"}
	dropUntranslated(texts[:4], got, "zh-CN")
	if want := []string{"", "谢谢你", "", "", "多出来的"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q, want %q", got, want)
	}
}

const pseudoMixedLRC = "[00:01.00]誰來救救我 save me from the lonely night\n[00:02.00]Thank you, my dear friend\n" +
	"[00:03.00]Don't you ever worry about me 我在你身邊"

// pseudoGoogle:混排行只转简体、英文原样留着,纯英文行真翻。
func pseudoGoogle(t *testing.T, sent *[]string) {
	useFakeGoogle(t, func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		var out []string
		for _, l := range strings.Split(r.PostForm.Get("q"), "\n") {
			*sent = append(*sent, l)
			if hasLatinOnly(l) {
				out = append(out, fakeTranslated("谷:", l))
			} else {
				out = append(out, toSimplified(l))
			}
		}
		fmt.Fprint(w, googleReply(t, out))
	})
}

func hasLatinOnly(s string) bool {
	for _, r := range s {
		if runeScript(r) != scriptLatin && runeScript(r) != scriptNone {
			return false
		}
	}
	return true
}

// Google 给的只转了简体的行不写进译文;够数时不再去问 MyMemory。
func TestGooglePseudoTranslationsNotWritten(t *testing.T) {
	saved := onDeviceTranslator
	onDeviceTranslator = func(context.Context, string, []string) ([]string, error) { return nil, errOnDeviceUnavailable }
	t.Cleanup(func() { onDeviceTranslator = saved })
	var sent []string
	pseudoGoogle(t, &sent)
	srv := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("够数了不该再问 MyMemory: %q", r.URL.Query().Get("q"))
	})
	res, err := machineTranslateLRCWithBase(context.Background(), srv.Client(), srv.URL, pseudoMixedLRC, "zh-CN", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if want := "[00:02.00]" + fakeTranslated("谷:", "Thank you, my dear friend"); res.lrc != want || res.engines != "google=1" {
		t.Fatalf("只该留真翻过的那行: engines=%q\n%s", res.engines, res.lrc)
	}
}

// Google 只真翻了一小部分、不够数时,只转了简体的那几行跟没翻的一样交给 MyMemory;MyMemory 给的只转了简体的也不写。
func TestGooglePseudoTranslationsGoToMyMemory(t *testing.T) {
	saved := onDeviceTranslator
	onDeviceTranslator = func(context.Context, string, []string) ([]string, error) { return nil, errOnDeviceUnavailable }
	t.Cleanup(func() { onDeviceTranslator = saved })
	var sent []string
	pseudoGoogle(t, &sent)
	var asked []string
	srv := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		lines := strings.Split(r.URL.Query().Get("q"), "\n")
		asked = append(asked, lines...)
		out := make([]string, len(lines))
		for i, l := range lines {
			out[i] = fakeTranslated("记:", l)
			if l == "I'm here for you tonight 妳在這裡" {
				out[i] = toSimplified(l)
			}
		}
		body, _ := jsonEscape(strings.Join(out, "\n"))
		fmt.Fprintf(w, `{"responseData":{"translatedText":%s},"responseStatus":200}`, body)
	})
	lrc := pseudoMixedLRC + "\n[00:04.00]I'm here for you tonight 妳在這裡"
	res, err := machineTranslateLRCWithBase(context.Background(), srv.Client(), srv.URL, lrc, "zh-CN", "", "")
	if err != nil {
		t.Fatal(err)
	}
	wantAsked := []string{"誰來救救我 save me from the lonely night", "Don't you ever worry about me 我在你身邊", "I'm here for you tonight 妳在這裡"}
	if !reflect.DeepEqual(asked, wantAsked) {
		t.Errorf("MyMemory 该收到只转了简体的那三行: %q", asked)
	}
	if !strings.Contains(res.lrc, "[00:02.00]"+fakeTranslated("谷:", "Thank you, my dear friend")) ||
		!strings.Contains(res.lrc, "[00:01.00]"+fakeTranslated("记:", "誰來救救我 save me from the lonely night")) ||
		strings.Contains(res.lrc, "[00:04.00]") || res.engines != "google=1 mymemory=2" {
		t.Fatalf("engines=%q\n%s", res.engines, res.lrc)
	}
}

// 端上给的只转了简体的行不算翻成:那一组判没翻成,整组交给 Google。
func TestOnDevicePseudoTranslationsGoToGoogle(t *testing.T) {
	saved := onDeviceTranslator
	onDeviceTranslator = func(_ context.Context, _ string, lines []string) ([]string, error) {
		out := make([]string, len(lines))
		for i, l := range lines {
			out[i] = toSimplified(l)
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
	res, err := machineTranslateLRCWithBase(context.Background(), http.DefaultClient, "http://127.0.0.1:1", pseudoMixedLRC, "zh-CN", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(sent) != 3 || res.engines != "google=3" {
		t.Fatalf("三行都该交给 Google: sent=%q engines=%q\n%s", sent, res.engines, res.lrc)
	}
}

const untranslatedLyrics = "[00:01.00]Lonely is the night 看著天花板\n[00:02.00]Thank you, my dear friend\n" +
	"[00:03.00]Don't you worry 我就在你身邊\n[00:04.00]I'm here for you\n[00:05.00]Everything's alright"

// 按时间戳对到原文行,删掉外文原样没动的;没有要删的原样返回;剩下的不够 3 行也留着,一行不剩才返回空串。
func TestDropUntranslatedLines(t *testing.T) {
	tr := "[00:01.00]Lonely is the night 看着天花板\n[00:02.00]谢谢你，亲爱的朋友\n[00:03.00]Don't you worry 我就在你身边\n" +
		"[00:04.00]我为你而来\n[00:05.00]一切都好"
	got, ok := dropUntranslatedLines(untranslatedLyrics, tr, "zh-CN")
	if want := "[00:02.00]谢谢你，亲爱的朋友\n[00:04.00]我为你而来\n[00:05.00]一切都好"; !ok || got != want {
		t.Fatalf("got %v %q, want %q", ok, got, want)
	}
	clean := "[00:02.00]谢谢你，亲爱的朋友\n[00:04.00]我为你而来\n[00:05.00]一切都好"
	if got, ok := dropUntranslatedLines(untranslatedLyrics, clean, "zh-CN"); ok || got != clean {
		t.Errorf("没有要删的该原样返回: %v %q", ok, got)
	}
	few := "[00:01.00]Lonely is the night 看着天花板\n[00:02.00]谢谢你\n[00:03.00]Don't you worry 我就在你身边"
	if got, ok := dropUntranslatedLines(untranslatedLyrics, few, "zh-CN"); !ok || got != "[00:02.00]谢谢你" {
		t.Errorf("剩一行真译文也留着: %v %q", ok, got)
	}
	none := "[00:01.00]Lonely is the night 看着天花板\n[00:03.00]Don't you worry 我就在你身边"
	if got, ok := dropUntranslatedLines(untranslatedLyrics, none, "zh-CN"); !ok || got != "" {
		t.Errorf("一行不剩该返回空串: %v %q", ok, got)
	}
}

// 存量迁移:只动记了语言的机翻;删空的连语言、来源一起清掉;带水位,只跑一次。
func TestMigrateUntranslatedMachineLines(t *testing.T) {
	withTempMigrationState(t)
	withTempDecisionCache(t)
	pseudo := "[00:01.00]Lonely is the night 看着天花板\n[00:02.00]谢谢你，亲爱的朋友\n[00:03.00]Don't you worry 我就在你身边\n" +
		"[00:04.00]我为你而来\n[00:05.00]一切都好"
	allPseudo := "[00:01.00]Lonely is the night 看着天花板\n[00:03.00]Don't you worry 我就在你身边"
	noLang := "[00:02.00]谢谢你\n[00:05.00]Everything's alright"
	enrichMu.Lock()
	enrichPath = ""
	enrichCache = map[string]enrichEntry{
		"a|machine|":   {Lyrics: untranslatedLyrics, LyricsTr: pseudo, LyricsTrSource: lyricsTrSourceMachine, LyricsTrLang: "zh-CN"},
		"b|emptied|":   {Lyrics: untranslatedLyrics, LyricsTr: allPseudo, LyricsTrSource: lyricsTrSourceMachine, LyricsTrLang: "zh-CN"},
		"c|community|": {Lyrics: untranslatedLyrics, LyricsTr: pseudo, LyricsTrLang: "zh"},
		"d|no-lang|":   {Lyrics: untranslatedLyrics, LyricsTr: noLang, LyricsTrSource: lyricsTrSourceMachine},
	}
	enrichMu.Unlock()
	migrateUntranslatedMachineLines()
	if e := enrichCache["a|machine|"]; e.LyricsTr != "[00:02.00]谢谢你，亲爱的朋友\n[00:04.00]我为你而来\n[00:05.00]一切都好" ||
		e.LyricsTrSource != lyricsTrSourceMachine || e.LyricsTrLang != "zh-CN" {
		t.Errorf("机翻里只转了简体的两行该删掉: %+v", e)
	}
	if e := enrichCache["b|emptied|"]; e.LyricsTr != "" || e.LyricsTrSource != "" || e.LyricsTrLang != "" {
		t.Errorf("删空的连语言、来源一起清: %+v", e)
	}
	if e := enrichCache["c|community|"]; e.LyricsTr != pseudo {
		t.Errorf("社区译文不动: %+v", e)
	}
	if e := enrichCache["d|no-lang|"]; e.LyricsTr != noLang {
		t.Errorf("没记语言的不动: %+v", e)
	}
	enrichMu.Lock()
	enrichCache["e|later|"] = enrichEntry{Lyrics: untranslatedLyrics, LyricsTr: pseudo, LyricsTrSource: lyricsTrSourceMachine, LyricsTrLang: "zh-CN"}
	enrichMu.Unlock()
	migrateUntranslatedMachineLines()
	if e := enrichCache["e|later|"]; e.LyricsTr != pseudo {
		t.Errorf("有水位之后不再全库重扫: %+v", e)
	}
	invalidateMigrationState("test")
	migrateUntranslatedMachineLines()
	if e := enrichCache["e|later|"]; e.LyricsTr == pseudo {
		t.Errorf("水位作废后照常扫: %+v", e)
	}
}

// 接线:两道都夹在 importLyricsFromFiles 与 exportLyricsFiles 之间。
func TestMigrateUntranslatedMachineLinesIsWired(t *testing.T) {
	data, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(data)
	imp := strings.Index(src, `startupStep("importLyricsFromFiles"`)
	exp := strings.Index(src, `startupStep("exportLyricsFiles", exportLyricsFiles)`)
	for _, step := range []string{
		`startupStep("migrateUntranslatedMachineLines", migrateUntranslatedMachineLines)`,
		`startupStep("migrateUnneededMachineLines", migrateUnneededMachineLines)`,
	} {
		mig := strings.Index(src, step)
		if imp < 0 || mig < 0 || exp < 0 || !(imp < mig && mig < exp) {
			t.Fatalf("%s 要夹在 import 与 export 之间: import=%d migrate=%d export=%d", step, imp, mig, exp)
		}
	}
}

const unneededLyrics = "[00:01.00]跟着我Flow\n[00:02.00]It represent my heart\n[00:03.00]男：Khalil\n" +
	"[00:04.00]女：你在哪里\n[00:05.00]声音是交流的媒介\n[00:05.00]A collage of vibrations\n[00:06.00]Chinese lady 我爱你"

// 按时间戳对到原文行,删掉原文那一行现在不用翻的;演唱者标签先剥掉再判;同一时间戳有一行要翻就留着;
// 对不上原文的行不动;没有要删的原样返回,一行不剩返回空串。
func TestDropUnneededLines(t *testing.T) {
	tr := "[00:01.00]跟着我流程\n[00:02.00]它代表我的心\n[00:03.00]哈利勒\n[00:05.00]振动的拼贴画\n" +
		"[00:06.00]中国女士我爱你\n[00:09.00]对不上原文的行"
	want := "[00:02.00]它代表我的心\n[00:03.00]哈利勒\n[00:05.00]振动的拼贴画\n[00:09.00]对不上原文的行"
	if got, ok := dropUnneededLines(unneededLyrics, tr, "zh-CN"); !ok || got != want {
		t.Fatalf("got %v %q, want %q", ok, got, want)
	}
	if got, ok := dropUnneededLines(unneededLyrics, want, "zh-CN"); ok || got != want {
		t.Errorf("没有要删的该原样返回: %v %q", ok, got)
	}
	none := "[00:01.00]跟着我流程\n[00:06.00]中国女士我爱你"
	if got, ok := dropUnneededLines(unneededLyrics, none, "zh-CN"); !ok || got != "" {
		t.Errorf("一行不剩该返回空串: %v %q", ok, got)
	}
	if got, ok := dropUnneededLines(unneededLyrics, none, "en"); ok || got != none {
		t.Errorf("目标是英文时汉字为主的行要翻,不该删: %v %q", ok, got)
	}
}

// 存量迁移:只动记了语言的机翻;删空的连语言、来源一起清掉;带水位,只跑一次。
func TestMigrateUnneededMachineLines(t *testing.T) {
	withTempMigrationState(t)
	withTempDecisionCache(t)
	mixed := "[00:01.00]跟着我流程\n[00:02.00]它代表我的心"
	allMixed := "[00:01.00]跟着我流程\n[00:06.00]中国女士我爱你"
	enrichMu.Lock()
	enrichPath = ""
	enrichCache = map[string]enrichEntry{
		"a|machine|":   {Lyrics: unneededLyrics, LyricsTr: mixed, LyricsTrSource: lyricsTrSourceMachine, LyricsTrLang: "zh-CN"},
		"b|emptied|":   {Lyrics: unneededLyrics, LyricsTr: allMixed, LyricsTrSource: lyricsTrSourceMachine, LyricsTrLang: "zh-CN"},
		"c|community|": {Lyrics: unneededLyrics, LyricsTr: mixed, LyricsTrLang: "zh"},
		"d|no-lang|":   {Lyrics: unneededLyrics, LyricsTr: mixed, LyricsTrSource: lyricsTrSourceMachine},
	}
	enrichMu.Unlock()
	migrateUnneededMachineLines()
	if e := enrichCache["a|machine|"]; e.LyricsTr != "[00:02.00]它代表我的心" || e.LyricsTrSource != lyricsTrSourceMachine || e.LyricsTrLang != "zh-CN" {
		t.Errorf("机翻里汉字为主的那行该删掉: %+v", e)
	}
	if e := enrichCache["b|emptied|"]; e.LyricsTr != "" || e.LyricsTrSource != "" || e.LyricsTrLang != "" {
		t.Errorf("删空的连语言、来源一起清: %+v", e)
	}
	if e := enrichCache["c|community|"]; e.LyricsTr != mixed {
		t.Errorf("社区译文不动: %+v", e)
	}
	if e := enrichCache["d|no-lang|"]; e.LyricsTr != mixed {
		t.Errorf("没记语言的不动: %+v", e)
	}
	enrichMu.Lock()
	enrichCache["e|later|"] = enrichEntry{Lyrics: unneededLyrics, LyricsTr: mixed, LyricsTrSource: lyricsTrSourceMachine, LyricsTrLang: "zh-CN"}
	enrichMu.Unlock()
	migrateUnneededMachineLines()
	if e := enrichCache["e|later|"]; e.LyricsTr != mixed {
		t.Errorf("有水位之后不再全库重扫: %+v", e)
	}
	invalidateMigrationState("test")
	migrateUnneededMachineLines()
	if e := enrichCache["e|later|"]; e.LyricsTr == mixed {
		t.Errorf("水位作废后照常扫: %+v", e)
	}
}
