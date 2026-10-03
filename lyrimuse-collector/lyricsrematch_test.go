package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 结论按动手前后的条目定:真换了就是 changed(哪一步换的都算),没换再看为什么;断网只用来解释没有结论。
func TestLyricsRematchOutcome(t *testing.T) {
	timed := enrichEntry{Lyrics: "[00:01.00]a", LyricsYRC: "yrc", LyricsSource: "qq", LyricsScore: 900}
	winner := &scoredLyricCandidateResult{Source: "lrclib", Score: 700}
	cases := []struct {
		name string
		f    lyricsRematchFacts
		want lyricsRematchResult
	}{
		{"换了来源和正文",
			lyricsRematchFacts{before: timed, after: enrichEntry{Lyrics: "[00:01.00]b", LyricsSource: "kugou", LyricsScore: 950},
				picked: winner, reached: true, decidable: true},
			lyricsRematchResult{Outcome: lyricsRematchChanged, Winner: "kugou", WinnerScore: 950, Previous: "qq", HadLyrics: true,
				TextChanged: true, TimingChanged: true}},
		{"没词的补上了",
			lyricsRematchFacts{before: enrichEntry{}, after: enrichEntry{Lyrics: "x", LyricsSource: "qq", LyricsScore: 800},
				picked: winner, decidable: true},
			lyricsRematchResult{Outcome: lyricsRematchChanged, Winner: "qq", WinnerScore: 800, TextChanged: true}},
		{"只换了来源",
			lyricsRematchFacts{before: timed, after: enrichEntry{Lyrics: timed.Lyrics, LyricsYRC: timed.LyricsYRC, LyricsSource: "kugou"},
				picked: winner, reached: true, decidable: true},
			lyricsRematchResult{Outcome: lyricsRematchChanged, Winner: "kugou", Previous: "qq", HadLyrics: true}},
		{"不可判又一个源都没连上 = 断网",
			lyricsRematchFacts{before: timed, after: timed},
			lyricsRematchResult{Outcome: lyricsRematchOffline, Previous: "qq", HadLyrics: true}},
		{"不可判",
			lyricsRematchFacts{before: timed, after: timed, picked: winner, reached: true},
			lyricsRematchResult{Outcome: lyricsRematchNotDecidable, Previous: "qq", HadLyrics: true}},
		{"连上了但没候选",
			lyricsRematchFacts{before: timed, after: timed, reached: true, decidable: true},
			lyricsRematchResult{Outcome: lyricsRematchNoCandidate, Previous: "qq", HadLyrics: true}},
		{"没候选、一个源都没连上 = 断网",
			lyricsRematchFacts{before: timed, after: timed, decidable: true},
			lyricsRematchResult{Outcome: lyricsRematchOffline, Previous: "qq", HadLyrics: true}},
		{"标上纯音乐",
			lyricsRematchFacts{before: enrichEntry{}, after: enrichEntry{Instrumental: true}, reached: true, decidable: true},
			lyricsRematchResult{Outcome: lyricsRematchInstrumental}},
		{"本来就标着纯音乐不算这一轮标的",
			lyricsRematchFacts{before: enrichEntry{Instrumental: true}, after: enrichEntry{Instrumental: true}, reached: true, decidable: true},
			lyricsRematchResult{Outcome: lyricsRematchNoCandidate}},
		{"收下纯文本",
			lyricsRematchFacts{before: enrichEntry{}, after: enrichEntry{PlainLyrics: "plain"}, reached: true, decidable: true},
			lyricsRematchResult{Outcome: lyricsRematchPlainText}},
		{"没词的条目冠军够不上",
			lyricsRematchFacts{before: enrichEntry{}, after: enrichEntry{}, picked: winner, reached: true, decidable: true},
			lyricsRematchResult{Outcome: lyricsRematchNoCandidate}},
		{"保住逐字",
			lyricsRematchFacts{before: timed, after: timed, picked: winner, reached: true, decidable: true, keptWordTiming: true},
			lyricsRematchResult{Outcome: lyricsRematchKeptWordTiming, Winner: "lrclib", WinnerScore: 700, Previous: "qq", HadLyrics: true}},
		{"没换(本地源给的冠军,没连上联网的源也照样有结论)",
			lyricsRematchFacts{before: timed, after: timed, picked: winner, decidable: true},
			lyricsRematchResult{Outcome: lyricsRematchUnchanged, Winner: "qq", WinnerScore: 900, Previous: "qq", HadLyrics: true}},
	}
	for _, c := range cases {
		if got := lyricsRematchOutcome(c.f); got != c.want {
			t.Errorf("%s: got %+v, want %+v", c.name, got, c.want)
		}
	}
}

// 请求的写法跟 App 侧 LyricsRematch.requestBody / cancelBody 一致(键按字母序)。
func TestParseLyricsRematchRequest(t *testing.T) {
	if req, ok := parseLyricsRematchRequest([]byte(`{"id":"r1","key":"周杰伦|晴天|叶惠美"}`)); !ok || req.ID != "r1" ||
		req.Key != "周杰伦|晴天|叶惠美" || req.Cancel {
		t.Errorf("开一轮: %+v %v", req, ok)
	}
	if req, ok := parseLyricsRematchRequest([]byte(`{"cancel":true,"id":"r1"}`)); !ok || !req.Cancel || req.ID != "r1" {
		t.Errorf("停一轮: %+v %v", req, ok)
	}
	for _, bad := range []string{``, `not json`, `{"key":"a|b|c"}`, `{"id":"r1"}`} {
		if _, ok := parseLyricsRematchRequest([]byte(bad)); ok {
			t.Errorf("%q 应当不认", bad)
		}
	}
}

func setupLyricsRematchTest(t *testing.T) {
	t.Helper()
	savedReq, savedStatus, savedRun := lyricsRematchRequestPath, lyricsRematchStatusPath, lyricsRematchRun
	dir := t.TempDir()
	lyricsRematchRequestPath = filepath.Join(dir, "rematch-request.json")
	lyricsRematchStatusPath = filepath.Join(dir, "rematch-status.json")
	t.Cleanup(func() {
		lyricsRematchRequestPath, lyricsRematchStatusPath, lyricsRematchRun = savedReq, savedStatus, savedRun
	})
}

func readLyricsRematchStatusFile(t *testing.T) lyricsRematchStatus {
	t.Helper()
	data, err := os.ReadFile(lyricsRematchStatusPath)
	if err != nil {
		t.Fatal(err)
	}
	var s lyricsRematchStatus
	if err := json.Unmarshal(data, &s); err != nil {
		t.Fatal(err)
	}
	return s
}

// 跑一轮:状态文件先写在跑、报进度,跑完写结论。
func TestRunLyricsRematchWritesProgressAndResult(t *testing.T) {
	setupLyricsRematchTest(t)
	var mid lyricsRematchStatus
	lyricsRematchRun = func(_ context.Context, key string, progress func(done, total int)) lyricsRematchResult {
		progress(2, 9)
		mid = readLyricsRematchStatusFile(t)
		return lyricsRematchResult{Outcome: lyricsRematchUnchanged, Winner: "qq", WinnerScore: 900}
	}
	runLyricsRematch(context.Background(), lyricsRematchRequest{ID: "r1", Key: "a|b|c"})
	if !mid.Running || mid.ID != "r1" || mid.Key != "a|b|c" || mid.Done != 2 || mid.Total != 9 || mid.Result != nil {
		t.Errorf("跑着时的状态 %+v", mid)
	}
	s := readLyricsRematchStatusFile(t)
	if s.Running || s.ID != "r1" || s.FinishedAt == 0 || s.Result == nil || *s.Result != (lyricsRematchResult{
		Outcome: lyricsRematchUnchanged, Winner: "qq", WinnerScore: 900}) {
		t.Errorf("跑完的状态 %+v", s)
	}
}

// 补空扫描 / 全量扫库在跑时不接,结论是 busy。
func TestRunLyricsRematchBusyWhileSweepRuns(t *testing.T) {
	setupLyricsRematchTest(t)
	lyricsRematchRun = func(context.Context, string, func(int, int)) lyricsRematchResult {
		t.Error("补搜在跑时不该开跑")
		return lyricsRematchResult{}
	}
	lyricsFillSweepMu.Lock()
	lyricsFillSweepRunning = true
	lyricsFillSweepMu.Unlock()
	t.Cleanup(func() {
		lyricsFillSweepMu.Lock()
		lyricsFillSweepRunning = false
		lyricsFillSweepMu.Unlock()
	})
	runLyricsRematch(context.Background(), lyricsRematchRequest{ID: "r1", Key: "a|b|c"})
	if s := readLyricsRematchStatusFile(t); s.ID != "r1" || s.Running || s.Result == nil || s.Result.Outcome != lyricsRematchBusy {
		t.Errorf("补搜在跑时结论应是 busy: %+v", s)
	}
}

// 停止请求只停对应的那一轮;新请求先停掉还在跑的那一轮、等它收尾再开跑。
func TestLyricsRematchCancelAndSupersede(t *testing.T) {
	setupLyricsRematchTest(t)
	ctxs := make(chan context.Context, 2)
	lyricsRematchRun = func(ctx context.Context, _ string, _ func(int, int)) lyricsRematchResult {
		ctxs <- ctx
		<-ctx.Done()
		return lyricsRematchResult{Outcome: lyricsRematchCancelled}
	}
	first := make(chan struct{})
	go func() {
		runLyricsRematch(context.Background(), lyricsRematchRequest{ID: "r1", Key: "a|b|c"})
		close(first)
	}()
	ctx1 := <-ctxs
	cancelLyricsRematch("r0")
	if ctx1.Err() != nil {
		t.Fatal("别的 id 的停止请求不该停掉这一轮")
	}
	second := make(chan struct{})
	go func() {
		runLyricsRematch(context.Background(), lyricsRematchRequest{ID: "r2", Key: "d|e|f"})
		close(second)
	}()
	// 回归时这两处会一直等下去,设个上限让它当场红。
	var ctx2 context.Context
	select {
	case ctx2 = <-ctxs:
	case <-time.After(5 * time.Second):
		t.Fatal("新请求一直没开跑")
	}
	select {
	case <-first:
	case <-time.After(5 * time.Second):
		t.Fatal("被顶掉的那一轮一直没收尾")
	}
	if ctx1.Err() == nil {
		t.Error("新请求应当先停掉还在跑的那一轮")
	}
	if ctx2.Err() != nil {
		t.Fatal("新的一轮不该一开跑就被停")
	}
	cancelLyricsRematch("r2")
	<-second
	if s := readLyricsRematchStatusFile(t); s.ID != "r2" || s.Result == nil || s.Result.Outcome != lyricsRematchCancelled {
		t.Errorf("最后的状态应是 r2 的收据: %+v", s)
	}
}

// 手动重评走真实的 rescoreLyricsWith:人工修正过、选定过源的条目照跑,换上冠军后两个标记清掉、决策记录标成手动。
func TestManualRematchRescoresHandEditedEntry(t *testing.T) {
	setupRescoreTest(t, []string{"musixmatch"}, func(ctx context.Context) {
		lyricSourceRoundFrom(ctx).markReached("musixmatch")
	})
	const artist, title, album = rescoreTestArtist, "Hand Edited", "Some Album"
	key := enrichKey(artist, title, album)
	const handBody = "[00:05.00]My own first line\n[00:15.00]My own second line"
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{key: {
		Lyrics: handBody, ManualLyrics: true, LyricsSourceChoice: "qq",
		LyricsScoringVersion: lyricsScoringVersion - 1,
	}}
	enrichMu.Unlock()

	// 后台重评不碰人工修正过的条目。
	rescoreLyrics(context.Background(), key, artist, title, album, 180)
	enrichMu.Lock()
	untouched := enrichCache[key].Lyrics
	enrichMu.Unlock()
	if untouched != handBody {
		t.Fatalf("后台重评改了人工修正过的词: %q", untouched)
	}

	progressCalls := 0
	got := runLyricsRematchOne(context.Background(), key, func(done, total int) { progressCalls++ })

	enrichMu.Lock()
	e := enrichCache[key]
	inflight := enrichInflight[key]
	enrichMu.Unlock()
	if !strings.HasPrefix(e.Lyrics, "[00:05.00]Brand new first line") || e.LyricsSource != "musixmatch" {
		t.Fatalf("手动重评应换上冠军: source=%q lyrics=%q", e.LyricsSource, e.Lyrics)
	}
	if e.ManualLyrics || e.LyricsSourceChoice != "" {
		t.Errorf("换上冠军后人工修正与选定源两个标记都该清掉: manual=%v choice=%q", e.ManualLyrics, e.LyricsSourceChoice)
	}
	if e.LyricsDecision == nil || e.LyricsDecision.Path != lyricsDecisionPathManualRematch || !e.LyricsDecision.Applied {
		t.Errorf("决策记录应标成手动重新匹配、已采用: %+v", e.LyricsDecision)
	}
	if got.Outcome != lyricsRematchChanged || got.Winner != "musixmatch" || got.Previous != "" || !got.HadLyrics || !got.TextChanged {
		t.Errorf("结论 %+v", got)
	}
	if progressCalls == 0 {
		t.Error("每个源回话时应报进度")
	}
	if inflight {
		t.Error("跑完要清掉 enrichInflight")
	}
}

// 没词的条目走补空那条路(retryLyricsUpgradeWith),决策记录同样标成手动。
func TestManualRematchFillsEmptyEntry(t *testing.T) {
	setupRescoreTest(t, []string{"musixmatch"}, nil)
	const artist, title, album = rescoreTestArtist, "Empty Song", "Some Album"
	key := enrichKey(artist, title, album)
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{key: {}}
	enrichMu.Unlock()

	got := runLyricsRematchOne(context.Background(), key, nil)

	enrichMu.Lock()
	e := enrichCache[key]
	enrichMu.Unlock()
	if e.LyricsSource != "musixmatch" || e.Lyrics == "" {
		t.Fatalf("没词的条目应补上冠军: %+v", e)
	}
	if e.LyricsDecision == nil || e.LyricsDecision.Path != lyricsDecisionPathManualRematch {
		t.Errorf("决策记录应标成手动重新匹配: %+v", e.LyricsDecision)
	}
	if got.Outcome != lyricsRematchChanged || got.HadLyrics || got.Winner != "musixmatch" {
		t.Errorf("结论 %+v", got)
	}
}

// 当前歌词的来源这一轮没应答:不动,结论 not_decidable 带上那个来源。lrclib 走测试里拨号即失败的传输,不会应答。
func TestManualRematchNotDecidable(t *testing.T) {
	setupRescoreTest(t, []string{"musixmatch", "lrclib"}, func(ctx context.Context) {
		lyricSourceRoundFrom(ctx).markReached("musixmatch")
	})
	const artist, title, album = rescoreTestArtist, "Lrclib Song", "Some Album"
	key := enrichKey(artist, title, album)
	const body = "[00:05.00]Old line one\n[00:15.00]Old line two"
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{key: {Lyrics: body, LyricsSource: "lrclib", LyricsScoringVersion: lyricsScoringVersion - 1}}
	enrichMu.Unlock()

	got := runLyricsRematchOne(context.Background(), key, nil)

	enrichMu.Lock()
	e := enrichCache[key]
	enrichMu.Unlock()
	if e.Lyrics != body || e.LyricsSource != "lrclib" {
		t.Fatalf("不可判时不该动: %+v", e)
	}
	if got.Outcome != lyricsRematchNotDecidable || got.Previous != "lrclib" {
		t.Errorf("结论 %+v", got)
	}
}

// 搜的时候条目被改过 / 被删了:什么都不写,结论分别是 edited / missing;删了的不复活。
func TestManualRematchEditedOrDeletedMidway(t *testing.T) {
	const artist, title, album = rescoreTestArtist, "Busy Song", "Some Album"
	key := enrichKey(artist, title, album)
	const body = "[00:05.00]Old line one\n[00:15.00]Old line two"

	setupRescoreTest(t, []string{"musixmatch"}, func(context.Context) {
		enrichMu.Lock()
		markEnrichEditedLocked(false, key)
		enrichMu.Unlock()
	})
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{key: {Lyrics: body, LyricsSource: "musixmatch", LyricsScoringVersion: lyricsScoringVersion - 1}}
	enrichMu.Unlock()
	if got := runLyricsRematchOne(context.Background(), key, nil); got.Outcome != lyricsRematchEdited {
		t.Errorf("期间被改过: %+v", got)
	}
	enrichMu.Lock()
	kept := enrichCache[key].Lyrics
	enrichMu.Unlock()
	if kept != body {
		t.Errorf("期间被改过就不该写: %q", kept)
	}

	// 换一首:进程内的 musixmatch 缓存按歌名命中,同名会绕过下面这个假源。
	const deletedTitle = "Deleted Song"
	deleted := enrichKey(artist, deletedTitle, album)
	musixmatchResolve = func(ctx context.Context, artist, title string, durationSecs float64, trLang, isrc string) musixmatchResult {
		enrichMu.Lock()
		delete(enrichCache, deleted)
		enrichMu.Unlock()
		return musixmatchResult{lrc: rescoreTestNewBody, title: title, artist: artist, durationSecs: 180}
	}
	enrichMu.Lock()
	enrichCache[deleted] = enrichEntry{Lyrics: body, LyricsSource: "musixmatch", LyricsScoringVersion: lyricsScoringVersion - 1}
	enrichMu.Unlock()
	if got := runLyricsRematchOne(context.Background(), deleted, nil); got.Outcome != lyricsRematchMissing {
		t.Errorf("期间被删了: %+v", got)
	}
	enrichMu.Lock()
	_, revived := enrichCache[deleted]
	enrichMu.Unlock()
	if revived {
		t.Error("删了的条目不该被复活")
	}
}

// 缓存里没有、这首正在别处搜索:不发请求,结论分别是 missing / busy。
func TestManualRematchMissingOrBusy(t *testing.T) {
	setupRescoreTest(t, []string{"musixmatch"}, func(context.Context) {
		t.Error("不该发请求")
	})
	const key = "Someone|Busy|Album"
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{}
	enrichMu.Unlock()
	if got := runLyricsRematchOne(context.Background(), key, nil); got.Outcome != lyricsRematchMissing {
		t.Errorf("缓存里没有: %+v", got)
	}
	enrichMu.Lock()
	enrichCache[key] = enrichEntry{Lyrics: "[00:01.00]x"}
	enrichInflight[key] = true
	enrichMu.Unlock()
	t.Cleanup(func() {
		enrichMu.Lock()
		delete(enrichInflight, key)
		enrichMu.Unlock()
	})
	if got := runLyricsRematchOne(context.Background(), key, nil); got.Outcome != lyricsRematchBusy {
		t.Errorf("正在别处搜索: %+v", got)
	}
}

// 报结论之前已经落盘:常驻进程里保存有节流,没换词的一轮只排一次记账补写(最多晚一分钟),App 拿到结论就重读。
func TestManualRematchSavesBeforeReporting(t *testing.T) {
	setupRescoreTest(t, []string{"musixmatch"}, nil)
	const artist, title, album = rescoreTestArtist, "Same Song", "Some Album"
	key := enrichKey(artist, title, album)
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{key: {
		Lyrics: rescoreTestNewBody, LyricsSource: "musixmatch", LyricsScoringVersion: lyricsScoringVersion - 1,
	}}
	enrichMu.Unlock()
	saves := 0
	savedNow := enrichSaveNow
	enrichSaveNow = func() { saves++ }
	enrichSaveThrottleMu.Lock()
	savedThrottled := enrichSaveThrottled
	enrichSaveThrottled, enrichLastSaveAt = true, time.Now()
	enrichSaveThrottleMu.Unlock()
	t.Cleanup(func() {
		enrichSaveThrottleMu.Lock()
		for _, timer := range []*time.Timer{enrichBookkeepingTimer, enrichSaveTimer} {
			if timer != nil {
				timer.Stop()
			}
		}
		enrichBookkeepingTimer, enrichSaveTimer, enrichSaveThrottled = nil, nil, savedThrottled
		enrichSaveThrottleMu.Unlock()
		enrichSaveNow = savedNow
	})

	got := runLyricsRematchOne(context.Background(), key, nil)

	if got.Outcome != lyricsRematchUnchanged {
		t.Fatalf("前提:这一轮的冠军就是现在这一份: %+v", got)
	}
	enrichSaveThrottleMu.Lock()
	pending := enrichBookkeepingTimer != nil || enrichSaveTimer != nil
	enrichSaveThrottleMu.Unlock()
	if saves == 0 || pending {
		t.Errorf("报结论之前要当场落盘: saves=%d 还排着补写=%v", saves, pending)
	}
}
