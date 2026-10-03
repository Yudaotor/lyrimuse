package main

import (
	"context"
	"errors"
	"net"
	"net/http"
	"slices"
	"strings"
	"testing"
	"time"
)

const rescoreTestArtist = "Someone"

const rescoreTestNewBody = "[00:05.00]Brand new first line\n[00:15.00]Brand new second line\n[00:25.00]Brand new third line\n" +
	"[00:35.00]Brand new fourth line\n[00:45.00]Brand new fifth line\n[02:50.00]Brand new last line"

// 走真实的 rescoreLyrics,歌词源只开 sources 里那几个,musixmatch 换成假的(返回 rescoreTestNewBody,并调一次 onFetch)。
// 可用源数够不上兜底轮门槛时会去解析歌手别名:MusicBrainz 那一路预先记成"查过、没有",走歌词源传输的请求拨号即失败,
// iTunes 指到不监听的本机端口 —— 整轮不连外网。
func setupRescoreTest(t *testing.T, sources []string, onFetch func(ctx context.Context)) {
	t.Helper()
	setupTranslateStart(t)
	savedPlaying := enrichPlayingKey.Load()
	savedResolve := musixmatchResolve
	savedBreaker, savedTransport := sharedLyricSourceBreaker(), sharedLyricSourceTransport()
	savedLookup, savedSearch, savedCatalog := itunesLookupTracksURL, itunesSearchBaseURL, appleCatalogLookupURL
	artistAliasMu.Lock()
	_, hadAlias := artistAliasCache[rescoreTestArtist]
	artistAliasCache[rescoreTestArtist] = ""
	artistAliasMu.Unlock()
	t.Cleanup(func() {
		enrichPlayingKey.Store(savedPlaying)
		musixmatchResolve = savedResolve
		setSharedLyricSourceBreaker(savedBreaker)
		setSharedLyricSourceTransport(savedTransport)
		itunesLookupTracksURL, itunesSearchBaseURL, appleCatalogLookupURL = savedLookup, savedSearch, savedCatalog
		artistAliasMu.Lock()
		if !hadAlias {
			delete(artistAliasCache, rescoreTestArtist)
		}
		artistAliasMu.Unlock()
	})
	enrichPlayingKey.Store(nil)
	itunesLookupTracksURL, itunesSearchBaseURL, appleCatalogLookupURL =
		"http://127.0.0.1:1/lookup", "http://127.0.0.1:1/search", "http://127.0.0.1:1/lookup"
	setSharedLyricSourceTransport(&http.Transport{DialContext: func(context.Context, string, string) (net.Conn, error) {
		return nil, errors.New("offline in tests")
	}})
	setSharedLyricSourceBreaker(newLyricSourceBreaker(time.Now))
	resetMusixmatchCacheForTest(t)
	enabled := map[string]bool{}
	for _, s := range sources {
		enabled[s] = true
	}
	featuresRef().LyricsSources = enabled
	featuresRef().LyricsAutoUpgrade = true
	musixmatchResolve = func(ctx context.Context, artist, title string, durationSecs float64, trLang, isrc string) musixmatchResult {
		if onFetch != nil {
			onFetch(ctx)
		}
		return musixmatchResult{lrc: rescoreTestNewBody, title: title, artist: artist, durationSecs: 180}
	}
}

// 有源被跳过:照常换上新冠军,但打分版本不追平、返回 deferred(全量扫库据此收尾再试),跳过名单如实落下。
// 被跳过的那一笔由假 musixmatch 记在这一轮的 round 上 —— 跟熔断冷却 / 后台暂停跳过时写的是同一个地方。
func TestRescoreWithSkippedSourceDoesNotCatchUpVersion(t *testing.T) {
	setupRescoreTest(t, []string{"musixmatch"}, func(ctx context.Context) {
		lyricSourceRoundFrom(ctx).markSkipped("lrclib")
	})
	const artist, title, album = rescoreTestArtist, "Skip Song", "Some Album"
	key := enrichKey(artist, title, album)
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{key: {
		Lyrics: "[00:05.00]Old line one\n[00:15.00]Old line two", LyricsSource: "musixmatch", LyricsScore: 10,
		LyricsScoringVersion: lyricsScoringVersion - 1,
	}}
	enrichMu.Unlock()

	deferred := rescoreLyrics(context.Background(), key, artist, title, album, 180)

	enrichMu.Lock()
	e := enrichCache[key]
	enrichMu.Unlock()
	if !deferred {
		t.Error("有源被跳过的一轮应当返回 deferred")
	}
	if !strings.HasPrefix(e.Lyrics, "[00:05.00]Brand new first line") {
		t.Errorf("照常重选,应换上这一轮的新正文,got %q", e.Lyrics)
	}
	if e.LyricsScoringVersion == lyricsScoringVersion {
		t.Error("有源被跳过时不该把打分版本标成已追平")
	}
	if !slices.Equal(e.LyricsSourcesSkipped, []string{"lrclib"}) {
		t.Errorf("跳过名单 %v,want [lrclib]", e.LyricsSourcesSkipped)
	}
	if e.LyricsDecision == nil || !slices.Contains(e.LyricsDecision.SourcesResponded, "musixmatch") {
		t.Errorf("可判的一轮照常写决策记录,got %+v", e.LyricsDecision)
	}
}

// 当前这份有逐字、打分版本落后(rescoreKeepsCurrent 管不着),这一轮冠军是另一份没有逐字的:留着当前这份,
// 决策记录照写、标成没采用,这一轮完整就照常追平打分版本。
func TestRescoreKeepsWordTimingOverAPlainWinner(t *testing.T) {
	setupRescoreTest(t, []string{"musixmatch"}, nil)
	const artist, title, album = rescoreTestArtist, "Timed Song", "Some Album"
	key := enrichKey(artist, title, album)
	const oldBody = "[00:05.00]Old line one\n[00:15.00]Old line two"
	const oldYRC = "[5000,1000](5000,500,0)Old(5500,500,0)line"
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{key: {
		Lyrics: oldBody, LyricsYRC: oldYRC, LyricsSource: "musixmatch", LyricsScore: 900,
		LyricsScoringVersion: lyricsScoringVersion - 1,
	}}
	enrichMu.Unlock()

	rescoreLyrics(context.Background(), key, artist, title, album, 180)

	enrichMu.Lock()
	e := enrichCache[key]
	enrichMu.Unlock()
	if e.Lyrics != oldBody || e.LyricsYRC != oldYRC || e.LyricsSource != "musixmatch" {
		t.Fatalf("冠军没有逐字时不该换掉有逐字的这份: lyrics=%q yrc=%q", e.Lyrics, e.LyricsYRC)
	}
	if e.LyricsScoringVersion != lyricsScoringVersion {
		t.Error("留着也算这一版规则评过,打分版本要追平")
	}
	if e.LyricsDecision == nil || e.LyricsDecision.Applied {
		t.Errorf("决策记录照写、标成没采用: %+v", e.LyricsDecision)
	}
}

// 不可判(当前歌词的来源 lrclib 正在熔断冷却、这一轮没应答):不改歌词、不写决策记录,三份名单保留上一轮的。
func TestRescoreUndecidableKeepsSourceLists(t *testing.T) {
	setupRescoreTest(t, []string{"musixmatch", "lrclib"}, nil)
	b := sharedLyricSourceBreaker()
	for range 2 {
		b.observe("lrclib.net", errors.New("connection reset"), 0, "")
	}
	if _, cooling := b.coolingDown("lrclib"); !cooling {
		t.Fatal("没能把 lrclib 置成冷却,测试前提不成立")
	}
	const artist, title, album = rescoreTestArtist, "Keep Song", "Some Album"
	key := enrichKey(artist, title, album)
	oldBody := "[00:05.00]Old line one\n[00:15.00]Old line two"
	prevDecision := &lyricsDecision{Path: lyricsDecisionPathRescore, Winner: "lrclib", SourcesResponded: []string{"lrclib", "musixmatch"}}
	enrichMu.Lock()
	enrichCache = map[string]enrichEntry{key: {
		Lyrics: oldBody, LyricsSource: "lrclib", LyricsScore: 10, LyricsScoringVersion: lyricsScoringVersion - 1,
		LyricsSourcesSeen: []string{"lrclib", "musixmatch"}, LyricsSourcesResponded: []string{"lrclib", "musixmatch"},
		LyricsDecision: prevDecision,
	}}
	enrichMu.Unlock()

	deferred := rescoreLyrics(context.Background(), key, artist, title, album, 180)

	enrichMu.Lock()
	e := enrichCache[key]
	enrichMu.Unlock()
	if !deferred {
		t.Error("不可判的一轮应当返回 deferred")
	}
	if e.Lyrics != oldBody || e.LyricsSource != "lrclib" {
		t.Errorf("不可判时不该换词,got source=%q", e.LyricsSource)
	}
	if !slices.Equal(e.LyricsSourcesResponded, []string{"lrclib", "musixmatch"}) || !slices.Equal(e.LyricsSourcesSeen, []string{"lrclib", "musixmatch"}) {
		t.Errorf("应答 / 出现过名单被残缺的一轮盖掉了: responded=%v seen=%v", e.LyricsSourcesResponded, e.LyricsSourcesSeen)
	}
	if len(e.LyricsSourcesSkipped) != 0 {
		t.Errorf("跳过名单也不该盖,got %v", e.LyricsSourcesSkipped)
	}
	if e.LyricsDecision != prevDecision {
		t.Error("不可判时不该写决策记录")
	}
}

// 这一轮被跳过的源不进别名补查名单:补查轮里它照样被跳过,为它解析别名白打请求。
func TestLyricSourcesWorthAliasRetryDropsSkippedSources(t *testing.T) {
	saved := features()
	t.Cleanup(func() { setFeatures(saved) })
	featuresRef().LyricsSources = map[string]bool{"qq": true, "lrclib": true, "musixmatch": true}
	results := []scoredLyricCandidateResult{{Source: "musixmatch", Score: 500}}
	ctx, round := withLyricSourceRound(context.Background())
	if got := lyricSourcesWorthAliasRetry(ctx, results); !slices.Equal(got, []string{"qq", "lrclib"}) {
		t.Fatalf("没有跳过时缺席的两个源都该补查,got %v", got)
	}
	round.markSkipped("lrclib")
	if got := lyricSourcesWorthAliasRetry(ctx, results); !slices.Equal(got, []string{"qq"}) {
		t.Errorf("被跳过的 lrclib 不该进补查名单,got %v", got)
	}
}
