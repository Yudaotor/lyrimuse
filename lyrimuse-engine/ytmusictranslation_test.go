package main

import (
	"context"
	"crypto/sha256"
	"fmt"
	"io"
	"net/http"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

// resetYtmusicTranslatable:清空进程里记下的 lyricfind 歌词,用例结束时换回原样。
func resetYtmusicTranslatable(t *testing.T) {
	t.Helper()
	ytmusicTranslatableMu.Lock()
	saved := ytmusicTranslatable
	ytmusicTranslatable = map[[sha256.Size]byte]string{}
	ytmusicTranslatableMu.Unlock()
	t.Cleanup(func() {
		ytmusicTranslatableMu.Lock()
		ytmusicTranslatable = saved
		ytmusicTranslatableMu.Unlock()
	})
}

func ytmFakeTranslations(texts ...string) string {
	var items []string
	for _, s := range texts {
		items = append(items, `{"translatedLyricText":"`+s+`"}`)
	}
	return `{"continuationContents":{"musicLyricsContinuation":{"lyricsTranslations":[` + strings.Join(items, ",") + `]}}}`
}

// 拼出来的 token 跟 YouTube Music 在歌词页应答里给的 translationContinuationToken 是同一串。
func TestYtmusicTranslationContinuation(t *testing.T) {
	const want = "4qmFsgIiEhRNUExZdF90OEc1NHR3UkZZdy0xNhoKdWdzQ0NBRSUzRA=="
	if got := ytmusicTranslationContinuation("MPLYt_t8G54twRFYw-16"); got != want {
		t.Fatalf("token = %q, want %q", got, want)
	}
}

func TestYtmusicParseTranslations(t *testing.T) {
	if got := ytmusicParseTranslations([]byte(ytmFakeTranslations("甲", "乙"))); !reflect.DeepEqual(got, []string{"甲", "乙"}) {
		t.Errorf("got %q", got)
	}
	for _, raw := range []string{`not json`, `{}`, ytmFakeTranslations()} {
		if got := ytmusicParseTranslations([]byte(raw)); got != nil {
			t.Errorf("%s: 该是 nil,got %q", raw, got)
		}
	}
}

// 去零宽字符;原文行末不是句号时去掉译文末尾的一个句号,省略号、问号不动。
func TestCleanYTMusicTranslation(t *testing.T) {
	for _, c := range []struct{ orig, tr, want string }{
		{"Hello", "你好。", "你好"},
		{"Hello", "Hi there.", "Hi there"},
		{"Hello", "等等……", "等等……"},
		{"Hello", "Wait...", "Wait..."},
		{"Hello", "你好吗？", "你好吗？"},
		{"I'm done.", "我受够了。", "我受够了。"},
		{"Hello", " 你\u200b好\ufeff ", "你好"},
		{"Hello", "。", ""},
	} {
		if got := cleanYTMusicTranslation(c.orig, c.tr); got != c.want {
			t.Errorf("cleanYTMusicTranslation(%q, %q) = %q, want %q", c.orig, c.tr, got, c.want)
		}
	}
}

const ytmTranslatableLRC = "[00:01.00]♪\n[00:02.00]Hello, it's me\n[00:03.00]\n[00:04.00]I was wondering\n" +
	"[00:05.00]Hello, it's me\n[00:06.00]Ok\n[00:07.00]Lonely is the night 看著天花板\n[00:08.00]S Jabberloop, let's go\n"

// 译文按顺序对上正文非空、不是「♪」的行;跟原文一样的、只转了简体的不收,留着人名的真译文照收;同一句出现两次收第一份。
// 请求带 Android 身份、hl 和续页 token。
func TestYtmusicTranslationsForAligns(t *testing.T) {
	resetYtmusicRegionState(t)
	resetYtmusicTranslatable(t)
	reqs := withYtmusicFake(t, func(w http.ResponseWriter, req ytmusicFakeReq) {
		if req.target == ytmBrowseURL {
			_, _ = io.WriteString(w, ytmFakeTranslations("你好，是我。", "我在想", "你好，是我呀", "Ok", "Lonely is the night，看着天花板", "S Jabberloop，我们走吧"))
			return
		}
		w.WriteHeader(http.StatusNotFound)
	})
	ytmusicRememberTranslatable(ytmTranslatableLRC, "MPLYt_x1")
	got := ytmusicTranslationsFor(qqRoundCtx(), ytmTranslatableLRC, "zh-CN")
	want := map[string]string{"Hello, it's me": "你好，是我", "I was wondering": "我在想", "S Jabberloop, let's go": "S Jabberloop，我们走吧"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q, want %q", got, want)
	}
	rs := reqs()
	if len(rs) != 1 {
		t.Fatalf("该只发一次续页请求: %+v", rs)
	}
	ctxBody, _ := rs[0].body["context"].(map[string]any)
	client, _ := ctxBody["client"].(map[string]any)
	if rs[0].clientName != ytmusicMobileClientName || client["hl"] != "zh-CN" ||
		rs[0].body["continuation"] != ytmusicTranslationContinuation("MPLYt_x1") {
		t.Errorf("续页请求不对: %+v", rs[0].body)
	}
}

// 条数对不上整份不用。
func TestYtmusicTranslationsForCountMismatch(t *testing.T) {
	resetYtmusicRegionState(t)
	resetYtmusicTranslatable(t)
	withYtmusicFake(t, func(w http.ResponseWriter, req ytmusicFakeReq) {
		_, _ = io.WriteString(w, ytmFakeTranslations("你好，是我", "我在想", "你好，是我"))
	})
	ytmusicRememberTranslatable(ytmTranslatableLRC, "MPLYt_x1")
	if got := ytmusicTranslationsFor(qqRoundCtx(), ytmTranslatableLRC, "zh-CN"); got != nil {
		t.Fatalf("条数对不上该是 nil: %q", got)
	}
}

// 没记过的歌词、地区受限、没有目标语言:一个请求都不发。
func TestYtmusicTranslationsForSkips(t *testing.T) {
	resetYtmusicRegionState(t)
	resetYtmusicTranslatable(t)
	reqs := withYtmusicFake(t, func(w http.ResponseWriter, req ytmusicFakeReq) {
		_, _ = io.WriteString(w, ytmFakeTranslations("甲", "乙", "丙", "丁", "戊", "己"))
	})
	if got := ytmusicTranslationsFor(qqRoundCtx(), ytmTranslatableLRC, "zh-CN"); got != nil {
		t.Errorf("没记过的歌词该是 nil: %q", got)
	}
	ytmusicRememberTranslatable(ytmTranslatableLRC, "MPLYt_x1")
	edited := strings.Replace(ytmTranslatableLRC, "I was wondering", "I was thinking", 1)
	if got := ytmusicTranslationsFor(qqRoundCtx(), edited, "zh-CN"); got != nil {
		t.Errorf("改过一行就不是记下的那份: %q", got)
	}
	if got := ytmusicTranslationsFor(qqRoundCtx(), ytmTranslatableLRC, ""); got != nil {
		t.Errorf("没有目标语言该是 nil: %q", got)
	}
	ytmusicVisitorMu.Lock()
	ytmusicRegionBlocked, ytmusicRegionCheckedAt = true, time.Now()
	ytmusicVisitorMu.Unlock()
	if got := ytmusicTranslationsFor(qqRoundCtx(), ytmTranslatableLRC, "zh-CN"); got != nil {
		t.Errorf("地区受限该是 nil: %q", got)
	}
	if n := len(reqs()); n != 0 {
		t.Errorf("这几种都不该发请求,实际 %d 个", n)
	}
}

// 第 0 级有总时限:YouTube Music 迟迟不回时到点当没有。超时会记进 lyricfind 的熔断,这条用一个自己的熔断器。
func TestYtmusicTranslationsForTimeout(t *testing.T) {
	resetYtmusicRegionState(t)
	resetYtmusicTranslatable(t)
	saved, savedBreaker := ytmusicTranslationTimeout, sharedLyricSourceBreaker()
	ytmusicTranslationTimeout = 50 * time.Millisecond
	setSharedLyricSourceBreaker(newLyricSourceBreaker(time.Now))
	t.Cleanup(func() { ytmusicTranslationTimeout = saved; setSharedLyricSourceBreaker(savedBreaker) })
	release := make(chan struct{})
	withYtmusicFake(t, func(w http.ResponseWriter, req ytmusicFakeReq) {
		select {
		case <-release:
		case <-time.After(2 * time.Second):
		}
		_, _ = io.WriteString(w, ytmFakeTranslations("甲", "乙", "丙", "丁", "戊", "己"))
	})
	t.Cleanup(func() { close(release) })
	ytmusicRememberTranslatable(ytmTranslatableLRC, "MPLYt_x1")
	if got := ytmusicTranslationsFor(qqRoundCtx(), ytmTranslatableLRC, "zh-CN"); got != nil {
		t.Fatalf("到点该当没有: %q", got)
	}
}

// 记录封顶:满了丢一条再放新的。
func TestYtmusicRememberTranslatableCapped(t *testing.T) {
	resetYtmusicTranslatable(t)
	for i := 0; i < ytmusicTranslatableMax+5; i++ {
		ytmusicRememberTranslatable("[00:01.00]line "+itoa(i)+"\n", "MPLYt_"+itoa(i))
	}
	ytmusicTranslatableMu.Lock()
	n := len(ytmusicTranslatable)
	ytmusicTranslatableMu.Unlock()
	if n != ytmusicTranslatableMax {
		t.Fatalf("条数 = %d, want %d", n, ytmusicTranslatableMax)
	}
	last := ytmusicTranslatableLines("[00:01.00]line " + itoa(ytmusicTranslatableMax+4) + "\n")
	if got := ytmusicTranslatableBrowseID(last); got != "MPLYt_"+itoa(ytmusicTranslatableMax+4) {
		t.Errorf("最后放进去的那条该在: %q", got)
	}
}

// 机翻链第 0 级给了的行不再送端上,端上只翻剩下的。
func TestMachineTranslateUsesLyricsSourceFirst(t *testing.T) {
	var batches [][]string
	var mu sync.Mutex
	savedDevice, savedSource := onDeviceTranslator, lyricsSourceTranslations
	onDeviceTranslator = fakeOnDeviceJapaneseBatch(&batches, &mu)
	var asked []string
	lyricsSourceTranslations = func(_ context.Context, lyrics, target string) map[string]string {
		asked = append(asked, target)
		if lyrics != mixedJapaneseEnglishLRC {
			t.Errorf("该拿整份歌词去问: %q", lyrics)
		}
		return map[string]string{"きみのことがすき": "源:喜欢你", "あいたいよ": "源:想见你", "よるがあける": "源:天亮了", "Kick back": "源:放松"}
	}
	t.Cleanup(func() { onDeviceTranslator, lyricsSourceTranslations = savedDevice, savedSource })

	res, err := machineTranslateLRCWithBase(context.Background(), http.DefaultClient, "http://127.0.0.1:1", mixedJapaneseEnglishLRC, "zh-CN", "", "")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"[00:01.00]源:喜欢你", "[00:04.00]源:放松", "[00:05.00]" + fakeTranslated("端:", "I want it all")} {
		if !strings.Contains(res.lrc, want) {
			t.Errorf("缺 %q:\n%s", want, res.lrc)
		}
	}
	if !reflect.DeepEqual(batches, [][]string{{"I want it all"}}) {
		t.Errorf("端上只该收到第 0 级没给的那一行: %q", batches)
	}
	if !reflect.DeepEqual(asked, []string{"zh-CN"}) {
		t.Errorf("第 0 级该按目标语言问一次: %q", asked)
	}
	if res.engines != "ytmusic=4 on-device=1" {
		t.Errorf("engines = %q", res.engines)
	}
}

// 第 0 级给了一部分、端上那一组没翻成时,交给 Google 的是还没译文的那几行。
func TestLyricsSourceThenGoogleGetsTheRest(t *testing.T) {
	savedDevice, savedSource := onDeviceTranslator, lyricsSourceTranslations
	onDeviceTranslator = func(context.Context, string, []string) ([]string, error) { return nil, errOnDeviceUnavailable }
	lyricsSourceTranslations = func(context.Context, string, string) map[string]string {
		return map[string]string{"きみのことがすき": "源:喜欢你", "あいたいよ": "源:想见你", "よるがあける": "源:天亮了"}
	}
	t.Cleanup(func() { onDeviceTranslator, lyricsSourceTranslations = savedDevice, savedSource })
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
	if !reflect.DeepEqual(sent, []string{"Kick back", "I want it all"}) {
		t.Errorf("Google 只该收到还没译文的两行: %q", sent)
	}
	for _, want := range []string{"[00:02.00]源:想见你", "[00:04.00]" + fakeTranslated("谷:", "Kick back"), "[00:05.00]" + fakeTranslated("谷:", "I want it all")} {
		if !strings.Contains(res.lrc, want) {
			t.Errorf("缺 %q:\n%s", want, res.lrc)
		}
	}
	if res.engines != "ytmusic=3 google=2" {
		t.Errorf("engines = %q", res.engines)
	}
}

// 接线:lyricfind 源取回的逐行歌词走完挑选流水线,机翻时第 0 级凭它取到 YouTube Music 的译文,时间戳跟正文一致。
func TestLyricFindTranslationThroughPipeline(t *testing.T) {
	saved := features()
	savedDevice, savedSource := onDeviceTranslator, lyricsSourceTranslations
	t.Cleanup(func() {
		setFeatures(saved)
		onDeviceTranslator, lyricsSourceTranslations = savedDevice, savedSource
		ytmusicMu.Lock()
		delete(ytmusicCache, "Adele|Hello|25")
		ytmusicMu.Unlock()
	})
	featuresRef().LyricsSources = map[string]bool{"lyricfind": true}
	onDeviceTranslator = func(context.Context, string, []string) ([]string, error) { return nil, errOnDeviceUnavailable }
	lyricsSourceTranslations = ytmusicTranslationsFor
	resetYtmusicRegionState(t)
	resetYtmusicTranslatable(t)
	withYtmusicFake(t, func(w http.ResponseWriter, req ytmusicFakeReq) {
		switch {
		case req.target == ytmSearchURL:
			_, _ = io.WriteString(w, ytmFakeSearch(ytmusicSearchItemJSON("Hello", "Adele • 25 • 4:55", "vid1", "MUSIC_VIDEO_TYPE_ATV")))
		case req.target == ytmNextURL:
			_, _ = io.WriteString(w, ytmFakeNext)
		case req.target == ytmBrowseURL && req.body["continuation"] != nil:
			_, _ = io.WriteString(w, ytmFakeTranslations("你好，是我。", "我在想", "这么多年过去了", "你是否还想见面"))
		case req.target == ytmBrowseURL && req.clientName == ytmusicMobileClientName:
			_, _ = io.WriteString(w, ytmFakeTimed("Source: LyricFind"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	_, got := fetchScoredLyricCandidatesStreaming(qqRoundCtx(), "Adele", "Hello", "25", 295, nil)
	var lyrics string
	for _, r := range got {
		if r.Source == "lyricfind" {
			lyrics = r.Lyrics
		}
	}
	if !isTimedLRC(lyrics) {
		t.Fatalf("没有 lyricfind 的逐行候选: %+v", got)
	}
	res, err := machineTranslateLRCWithBase(qqRoundCtx(), http.DefaultClient, "http://127.0.0.1:1", lyrics, "zh-CN", "Adele", "Hello")
	if err != nil {
		t.Fatal(err)
	}
	if res.lrc != "[00:01.00]你好，是我\n[00:05.00]我在想\n[00:09.00]这么多年过去了\n[00:13.00]你是否还想见面" || res.engines != "ytmusic=4" {
		t.Fatalf("译文不对: engines=%q\n%s", res.engines, res.lrc)
	}
}
