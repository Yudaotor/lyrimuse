package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

// 待播那首排在名额后面时开始播放:当场翻,不等名额;提前翻的那一路还没翻完时排队那一路轮到,也不再送翻第二遍。
func TestQueuedTranslationStartsWhenItPlays(t *testing.T) {
	setupTranslateStart(t)
	arrived := make(chan struct{}, 4)
	release := make(chan struct{})
	srv := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		arrived <- struct{}{}
		<-release
		lines := strings.Split(r.URL.Query().Get("q"), "\n")
		for i := range lines {
			lines[i] = fakeTranslated("译", lines[i])
		}
		body, _ := jsonEscape(strings.Join(lines, "\n"))
		fmt.Fprintf(w, `{"responseData":{"translatedText":%s},"responseStatus":200}`, body)
	})
	translateBaseURL, translateClient = srv.URL, srv.Client()
	const key = "Someone|Next Song|Some Album"
	prefetchTranslateSlot <- struct{}{}
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{key: {Lyrics: bt(translateStartLyrics)}}
	queued := translateUpcomingLocked(key)
	started := queued && startTranslationBackfillLocked(key, enrichCache[key])
	enrichMu.Unlock()
	if !started {
		<-prefetchTranslateSlot
		close(release)
		t.Fatalf("queued=%v started=%v:排着的那首开始播放时该当场起", queued, started)
	}
	<-arrived // 提前翻的那一路已经在请求里
	// 放开名额时排队那一路直接拿到它;它判完放回来,这边才塞得进去。它要是又送翻,会先撞到第二个请求。
	<-prefetchTranslateSlot
	judged := make(chan struct{})
	go func() {
		prefetchTranslateSlot <- struct{}{}
		close(judged)
	}()
	select {
	case <-judged:
	case <-arrived:
		t.Error("排队那一路轮到时又送翻了一遍")
	}
	close(release)
	<-judged
	<-prefetchTranslateSlot
	waitTranslationDone(t, key)
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if enrichCache[key].LyricsTr.IsZero() {
		t.Fatal("没等名额就翻,译文应已在缓存里")
	}
}

// 排队期间关掉了机翻:轮到时不再送翻,占位清掉。
func TestQueuedTranslationRechecksSwitchWhenItsTurnComes(t *testing.T) {
	calls := setupTranslateStart(t)
	const key = "Someone|Next Song|Some Album"
	prefetchTranslateSlot <- struct{}{}
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{key: {Lyrics: bt(translateStartLyrics)}}
	queued := translateUpcomingLocked(key)
	featuresRef().LyricsMachineTranslation = false
	enrichMu.Unlock()
	<-prefetchTranslateSlot
	if !queued {
		t.Fatal("该排进去")
	}
	waitTranslationDone(t, key)
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if *calls != 0 || !enrichCache[key].LyricsTr.IsZero() {
		t.Fatalf("关了机翻之后轮到时不该送翻: calls=%d", *calls)
	}
}

// 翻译服务一个都连不上:只节流,不记一次尝试。
func TestBackfillTranslationUnreachableDoesNotCountAttempt(t *testing.T) {
	setupTranslateStart(t)
	dead := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	translateBaseURL, translateClient = dead.URL, dead.Client()
	dead.Close()
	const key = "Someone|Offline Song|Some Album"
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{key: {Lyrics: bt(translateStartLyrics)}}
	translationInflight[key] = true
	enrichMu.Unlock()
	backfillTranslation(key)
	enrichMu.Lock()
	defer enrichMu.Unlock()
	e := enrichCache[key]
	if e.TranslationRetryCount != 0 || e.TranslationTS == 0 {
		t.Fatalf("连不上时只记时间戳: retries=%d ts=%d", e.TranslationRetryCount, e.TranslationTS)
	}
}

// 翻译期间改了译文语言:按旧语言翻出来的那份不挂。
func TestBackfillTranslationDropsResultAfterLanguageChange(t *testing.T) {
	setupTranslateStart(t)
	srv := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		enrichMu.Lock()
		featuresRef().LyricsTranslationLanguage = "ja"
		enrichMu.Unlock()
		body, _ := jsonEscape("译文一\n译文二")
		fmt.Fprintf(w, `{"responseData":{"translatedText":%s},"responseStatus":200}`, body)
	})
	translateBaseURL, translateClient = srv.URL, srv.Client()
	const key = "Someone|Some Song|Some Album"
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{key: {Lyrics: bt(translateStartLyrics)}}
	translationInflight[key] = true
	enrichMu.Unlock()
	backfillTranslation(key)
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if !enrichCache[key].LyricsTr.IsZero() {
		t.Fatalf("改了语言之后不该挂上旧语言的机翻: %q", enrichCache[key].LyricsTr.String())
	}
}

// MyMemory 只有一块说没有可用译文:那一块按没翻,别的块照拼,不整首作废。
func TestTranslateKeepsOtherChunksWhenOneHasNoTranslation(t *testing.T) {
	srv := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query().Get("q")
		if strings.Contains(q, "Second half") {
			fmt.Fprint(w, `{"responseData":{"translatedText":"PLEASE SELECT TWO DISTINCT LANGUAGES"},"responseStatus":200}`)
			return
		}
		lines := strings.Split(q, "\n")
		for i := range lines {
			lines[i] = fakeTranslated("译", lines[i])
		}
		body, _ := jsonEscape(strings.Join(lines, "\n"))
		fmt.Fprintf(w, `{"responseData":{"translatedText":%s},"responseStatus":200}`, body)
	})
	var lrc strings.Builder
	for i := 0; i < 16; i++ {
		fmt.Fprintf(&lrc, "%sFirst half line number %d of this rather long song\n", formatLRCTime(1000+i*3000), i)
	}
	for i := 0; i < 4; i++ {
		fmt.Fprintf(&lrc, "%sSecond half line %d\n", formatLRCTime(60000+i*3000), i)
	}
	if n := len(chunkForTranslation(selectTranslationWork(lrc.String(), "zh-CN", "", "").uniqueTexts)); n < 2 {
		t.Fatalf("样例要分成至少两块,只有 %d 块", n)
	}
	res, err := machineTranslateLRCWithBase(context.Background(), srv.Client(), srv.URL, lrc.String(), "zh-CN", "", "")
	if err != nil || !strings.Contains(res.lrc, fakeTranslated("译", "First half line number 0 of this rather long song")) {
		t.Fatalf("别的块的译文要留着: err=%v\n%s", err, res.lrc)
	}
}

// 换正文的几条自动路径都清掉上一份正文攒下的机翻失败次数和节流。
func TestLyricsSwapsResetTranslationAttempts(t *testing.T) {
	read := func(f string) string {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	if n := strings.Count(read("enrich.go"), "e.resetTranslationAttempts()\n"); n != 2 {
		t.Errorf("enrich.go 升级重试、重新打分两处换正文都要清,只找到 %d 处", n)
	}
	if !containsCode(read("crossalbum.go"), "e.LyricsTrLang = src.LyricsTrLang\n\te.resetTranslationAttempts()") {
		t.Error("跨专辑借词没清")
	}
	if !containsCode(read("songentityshare.go"), "e.LyricsTrLang, e.LyricsTrSource = c.LyricsTrLang, lyricsTrSourceFor(c)\n\te.resetTranslationAttempts()") {
		t.Error("同曲共享换词没清")
	}
	e := enrichEntry{TranslationTS: 5, TranslationRetryCount: 3}
	e.resetTranslationAttempts()
	if e.TranslationTS != 0 || e.TranslationRetryCount != 0 {
		t.Fatal("resetTranslationAttempts 没清干净")
	}
}
