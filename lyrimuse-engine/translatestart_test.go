package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// setupTranslateStart 接一个假 MyMemory、打开机翻,返回的 calls 记录送翻请求数。
func setupTranslateStart(t *testing.T) *int {
	t.Helper()
	calls := new(int)
	srv := fakeMyMemory(t, func(w http.ResponseWriter, r *http.Request) {
		enrichMu.Lock()
		*calls++
		enrichMu.Unlock()
		lines := strings.Split(r.URL.Query().Get("q"), "\n")
		out := make([]string, len(lines))
		for i := range lines {
			out[i] = fakeTranslated("译", lines[i])
		}
		body, _ := jsonEscape(strings.Join(out, "\n"))
		fmt.Fprintf(w, `{"responseData":{"translatedText":%s},"responseStatus":200}`, body)
	})
	savedFeatures, savedCache, savedPath, savedBase, savedDir, savedClient :=
		features(), enrichCache, enrichPath, translateBaseURL, lyricsDir(), translateClient
	savedInflight, savedTr, savedProv := enrichInflight, translationInflight, enrichProvisional
	t.Cleanup(func() {
		setFeatures(savedFeatures)
		enrichCache, enrichPath, translateBaseURL, translateClient =
			savedCache, savedPath, savedBase, savedClient
		enrichInflight, translationInflight, enrichProvisional = savedInflight, savedTr, savedProv
		setLyricsDir(savedDir)
	})
	featuresRef().LyricsMachineTranslation = true
	featuresRef().LyricsTranslationLanguage = "zh"
	translateBaseURL = srv.URL
	translateClient = srv.Client()
	setLyricsDir("")
	enrichPath = filepath.Join(t.TempDir(), "enrich-cache.json")
	enrichInflight, translationInflight, enrichProvisional = map[string]bool{}, map[string]bool{}, map[string]bool{}
	return calls
}

const translateStartLyrics = "[00:01.00]The painful youth\n[00:02.00]I have had"

func waitTranslationDone(t *testing.T, key string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		enrichMu.Lock()
		busy := translationInflight[key]
		enrichMu.Unlock()
		if !busy {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("%s 的机翻 10 秒没跑完", key)
}

// 别的后台任务占着 enrichInflight 时照样起机翻,而且机翻收尾不能把别人的占位清掉。
func TestTranslationRunsAlongsideOtherBackgroundWork(t *testing.T) {
	setupTranslateStart(t)
	const key = "Someone|Some Song|Some Album"
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{key: {Lyrics: translateStartLyrics}}
	enrichInflight[key] = true // 比如重打分正在跑
	started := startTranslationBackfillLocked(key, enrichCache[key])
	again := startTranslationBackfillLocked(key, enrichCache[key])
	enrichMu.Unlock()
	if !started || again {
		t.Fatalf("started=%v again=%v:第一次该起、在途时不该重复起", started, again)
	}
	waitTranslationDone(t, key)
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if enrichCache[key].LyricsTrSource != lyricsTrSourceMachine {
		t.Fatalf("没翻出来: %+v", enrichCache[key])
	}
	if !enrichInflight[key] {
		t.Fatal("机翻收尾把别的任务在 enrichInflight 里的占位清掉了")
	}
	// 同时在跑的重打分随后换了正文、译文跟着清空:下一次轮询要能马上按新正文重翻,不被节流挡住。
	e := enrichCache[key]
	e.Lyrics, e.LyricsTr, e.LyricsTrLang, e.LyricsTrSource = "[00:01.00]Another line\n[00:02.00]And one more", "", "", ""
	if !needsTranslationBackfill(e, key) {
		t.Fatalf("翻成之后换了正文,重翻被节流挡住了: ts=%d retries=%d", e.TranslationTS, e.TranslationRetryCount)
	}
}

func TestTranslateAfterResolveMark(t *testing.T) {
	if translateAfterResolve(context.Background()) || !translateAfterResolve(withBackgroundOutbound(withTranslateAfterResolve(context.Background()))) {
		t.Fatal("标记要能穿过 withBackgroundOutbound 读出来,没标的读成 false")
	}
}

// 首次解析在途(先上屏那一份)时不起:最终提交会整条覆盖,译文会被冲掉。
func TestTranslationWaitsForProvisionalCommit(t *testing.T) {
	setupTranslateStart(t)
	const key = "Someone|Some Song|Some Album"
	enrichMu.Lock()
	defer enrichMu.Unlock()
	enrichCache = map[string]enrichEntry{key: {Lyrics: translateStartLyrics}}
	enrichProvisional[key] = true
	if startTranslationBackfillLocked(key, enrichCache[key]) || translateUpcomingLocked(key) {
		t.Fatal("先上屏那一份还会被整条覆盖,不该起机翻")
	}
	delete(enrichProvisional, key)
	if !translationStartableLocked(key, enrichCache[key]) {
		t.Fatal("最终提交之后应该能起")
	}
}

// 预取来的机翻排队:槽被占着时不送翻,槽空出来才翻;翻完译文在缓存里。
func TestTranslateUpcomingQueuesBehindSlot(t *testing.T) {
	calls := setupTranslateStart(t)
	const key = "Someone|Next Song|Some Album"
	prefetchTranslateSlot <- struct{}{}
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{key: {Lyrics: translateStartLyrics}}
	queued := translateUpcomingLocked(key)
	enrichMu.Unlock()
	if !queued {
		<-prefetchTranslateSlot
		t.Fatal("该排进去")
	}
	time.Sleep(100 * time.Millisecond)
	enrichMu.Lock()
	early := *calls
	enrichMu.Unlock()
	<-prefetchTranslateSlot
	if early != 0 {
		t.Fatalf("槽被占着时已经送翻了 %d 次", early)
	}
	waitTranslationDone(t, key)
	enrichMu.Lock()
	defer enrichMu.Unlock()
	if enrichCache[key].LyricsTr == "" {
		t.Fatal("槽空出来之后没翻")
	}
}

// 接线守卫:正在播的那首的机翻不挂在「一次只跑一路」那条链里;待播预取解析完接着排机翻;
// 同专辑预取不排。
func TestTranslationStartIsWired(t *testing.T) {
	read := func(f string) string {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	enrich := read("enrich.go")
	if strings.Contains(enrich, "go backfillTranslation(") || strings.Contains(enrich, "needsTranslationBackfill(e, key) && !enrichInflight[key]") {
		t.Error("enrich.go 里机翻又挂回了 enrichInflight 那条链")
	}
	if !strings.Contains(enrich, "\t\tstartTranslationBackfillLocked(key, e)\n\t\tenrichMu.Unlock()") {
		t.Error("enrich.go 缓存命中那段没接 startTranslationBackfillLocked")
	}
	if !strings.Contains(enrich, "\t\tif translateAfterResolve(ctx) {\n\t\t\ttranslateUpcomingLocked(key)\n\t\t}\n\t\tenrichMu.Unlock()") {
		t.Error("resolveEnrichAsync 收尾没接 translateAfterResolve")
	}
	upcoming := read("upcoming.go")
	for _, needle := range []string{
		"go resolveEnrichAsync(withBackgroundOutbound(withLyricSearchTitle(withTranslateAfterResolve(withYouTubeMusicVideoID(context.Background(), t.videoID)), lyricSearchTitle(t.title))), key,",
		"} else if exists && !claim {\n\t\t\t\t// 解析过、但还没译文的",
	} {
		if !strings.Contains(upcoming, needle) {
			t.Errorf("upcoming.go 缺 %q", needle)
		}
	}
	album := read("albumprefetch.go")
	if strings.Contains(album, "translateUpcomingLocked(") || strings.Contains(album, "withTranslateAfterResolve(") {
		t.Error("同专辑预取不该排机翻")
	}
}

// 自动换正文之后:正在播的那首当场按新正文起机翻,翻完写单条快照(App 不等整份缓存落盘);没在播的
// (补空扫描 / 全量扫库换下来的)不起。
func TestTranslateAfterLyricsSwapOnlyForPlayingKey(t *testing.T) {
	setupTranslateStart(t)
	savedPlaying := enrichPlayingKey.Load()
	t.Cleanup(func() { enrichPlayingKey.Store(savedPlaying) })
	const playing, other = "Someone|Playing Song|Some Album", "Someone|Swept Song|Some Album"
	noteEnrichPlayingKey(playing)
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{
		playing: {Lyrics: translateStartLyrics},
		other:   {Lyrics: translateStartLyrics},
	}
	translateAfterLyricsSwapLocked(other)
	sweptStarted := translationInflight[other]
	translateAfterLyricsSwapLocked(playing)
	playingStarted := translationInflight[playing]
	enrichMu.Unlock()
	if sweptStarted || !playingStarted {
		t.Fatalf("swept=%v playing=%v:只该给正在播的那首起", sweptStarted, playingStarted)
	}
	waitTranslationDone(t, playing)
	b, err := os.ReadFile(playingEntryPath())
	if err != nil {
		t.Fatalf("翻完没写单条快照: %v", err)
	}
	if !strings.Contains(string(b), `"key":"`+playing+`"`) || !strings.Contains(string(b), fakeTranslated("译", "The painful youth")) {
		t.Fatalf("单条快照里没有这首的译文: %s", b)
	}
}

// 接线守卫:升级 / 重新打分两条换正文的路径换完当场起机翻,三条路径(外加机翻本身)换了歌词族字段都写单条快照。
func TestLyricsSwapPathsTranslateAndWritePlayingEntry(t *testing.T) {
	b, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	enrich := string(b)
	// 两条路径都还有「条目里有词、只打了纯音乐标记」这一种:同样落盘、通知,但没换词、不导出(见 rescoreTurnsInstrumental /
	// playerSaysInstrumental)。
	swap := "\t\tif lyricsChanged {\n\t\t\ttranslateAfterLyricsSwapLocked(key)\n\t\t}\n\t\tenrichMu.Unlock()\n\t\tif !lyricsChanged && !markedInstrumental {\n\t\t\trequestEnrichBookkeepingSave(key)\n\t\t\treturn\n\t\t}\n\t\tcommitEnrichSave(key)\n\t\tif lyricsChanged {\n\t\t\texportLyricsFilesFor(key)\n\t\t}\n"
	for fn, want := range map[string]string{"func retryLyricsUpgradeWith(": swap, "func rescoreLyricsWith(": swap} {
		i := strings.Index(enrich, fn)
		if i < 0 {
			t.Fatalf("enrich.go 找不到 %s", fn)
		}
		body := enrich[i:]
		if j := strings.Index(body[1:], "\nfunc "); j >= 0 {
			body = body[:j+1]
		}
		if !strings.Contains(body, want) {
			t.Errorf("%s 收尾没接 translateAfterLyricsSwapLocked / commitEnrichSave", fn)
		}
	}
	tb, err := os.ReadFile("translate.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(tb), "\t\tcommitEnrichSave(key)\n\t\texportLyricsFilesFor(key)\n") {
		t.Error("backfillTranslation 翻出译文之后没写单条快照")
	}
}
