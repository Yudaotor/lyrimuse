package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 值跟目录缓存一样是 boost 归档,前缀照真实数据的形状。
const amazonTestLyricsJSON = "\x16\x00\x00\x00\x00\x00\x00\x00serialization::archive\x0f\x00\x04\x08\x04\x08\x01\x00\x00\x00\xe1\x0c\x00\x00\x00\x00\x00\x00" +
	`{"lrcSource":"AMAZON_INTERNAL","lyricsResponseCode":1002,"lyricsSource":"LYRIC_FIND","lyrics":{"lines":[` +
	`{"startTime":0,"endTime":16338,"text":"..."},` +
	`{"startTime":16338,"endTime":19959,"text":"I found your lighter in my nightstand"},` +
	`{"startTime":20227,"endTime":23965,"text":"That's why I'm thinking of you, I guess"},` +
	`{"startTime":24307,"endTime":27896,"text":"What part of over don't I understand?"}]},` +
	`"trackAsinAndMarketplace":{"asin":"B0TESTAAA2","marketplaceId":"ATVPDKIKX0DER"}}`

// 目录缓存的值是 boost 归档,中间夹一个 JSON 对象,后面还跟着二进制尾巴。
const amazonTestCatalogValue = "\x16\x00\x00\x00\x00\x00\x00\x00serialization::archive\x13\x00\x04\x08\x04\x08\x01\x00\x00\x00" +
	`{"id":"","uniqueId":"B0TESTAAA2","asin":"B0TESTAAA2","title":"I Can't Love You Anymore [Explicit]","duration":"229","hasLyrics":true,` +
	`"album":{"name":"I Can't Love You Anymore","asin":"B0TESTALB1"},"artist":{"name":"Ella Langley & Morgan Wallen","asin":"B0TESTART1"}}` +
	"\xe5\x00\x01garbage"

func useTempAmazonData(t *testing.T) (localStorage, hammer string) {
	t.Helper()
	localStorage, hammer = t.TempDir(), t.TempDir()
	savedLS, savedHC := amazonLocalStorageOverride, amazonHammerCacheOverride
	amazonLocalStorageOverride, amazonHammerCacheOverride = localStorage, hammer
	t.Cleanup(func() { amazonLocalStorageOverride, amazonHammerCacheOverride = savedLS, savedHC })
	testWriteLog(t, filepath.Join(localStorage, "000015.log"), [][]testLDBEntry{{
		{key: "*.MusicContent.CacheEntry.PrimeCatalog_KATANA_B0TESTAAA2", seq: 5, value: amazonTestCatalogValue},
	}})
	testWriteLog(t, filepath.Join(hammer, "000011.log"), [][]testLDBEntry{{
		{key: "B0TESTAAA2-ATVPDKIKX0DER", seq: 7, value: amazonTestLyricsJSON},
	}})
	return localStorage, hammer
}

func TestAmazonLyricsLRC(t *testing.T) {
	lrc, coarse, ok := amazonLyricsLRC([]byte(amazonTestLyricsJSON))
	if !ok || coarse {
		t.Fatalf("ok=%v coarse=%v", ok, coarse)
	}
	if strings.Contains(lrc, "...") || !strings.HasPrefix(lrc, "[00:16.33]I found your lighter") {
		t.Errorf("前奏占位去掉、时间按毫秒换算: %q", lrc)
	}
	if _, coarse, _ := amazonLyricsLRC([]byte(`{"lyrics":{"lines":[{"startTime":1000,"text":"a"},{"startTime":2000,"text":"b"},{"startTime":3000,"text":"c"}]}}`)); !coarse {
		t.Error("每句都是整秒的标成 coarse")
	}
	if _, _, ok := amazonLyricsLRC([]byte(`{"lyrics":{"lines":[{"startTime":1500,"text":"a"}]}}`)); ok {
		t.Error("句子太少不算有歌词")
	}
}

func TestAmazonCatalogAndLyricsFromLevelDB(t *testing.T) {
	useTempAmazonData(t)
	meta := amazonCatalog([]string{"B0TESTAAA2", "B0MISSING0"})
	got, ok := meta["B0TESTAAA2"]
	if !ok || got.Title != "I Can't Love You Anymore [Explicit]" || got.Artist.Name != "Ella Langley & Morgan Wallen" ||
		got.albumName() != "I Can't Love You Anymore" || got.durationSecs() != 229 {
		t.Fatalf("目录缓存: %+v", got)
	}
	if _, ok := meta["B0MISSING0"]; ok {
		t.Error("查不到的不在结果里")
	}
	if lrc, _, ok := amazonLyricsForASIN("B0TESTAAA2"); !ok || !strings.Contains(lrc, "nightstand") {
		t.Errorf("按 ASIN 前缀找歌词: ok=%v", ok)
	}
	if _, _, ok := amazonLyricsForASIN("B0TESTAAA"); ok {
		t.Error("ASIN 前缀要带分隔符,不能半截命中")
	}
}

func TestParseAmazonQueueLine(t *testing.T) {
	q, ok := parseAmazonQueueLine("260928:025618 MorphoBrowser : I HarleyPlayerController : PlayerFlow : Playables : UriList = asin-//B0TESTAAA1, asin-//B0TESTAAA2, asin-//B0TESTAAA3 , function = updateQueue : line 571, ")
	if !ok || strings.Join(q, ",") != "asin://B0TESTAAA1,asin://B0TESTAAA2,asin://B0TESTAAA3" {
		t.Fatalf("队列窗口: %v ok=%v", q, ok)
	}
	if _, ok := parseAmazonQueueLine("260928:025618 Browser INFO in Harley : new track playing : asin://B0TESTAAA1:1:1"); ok {
		t.Error("别的行不认")
	}
}

// useTempAmazonLog 把 Amazon Music 日志指到一份临时文件,读到一半的状态清掉重来。
func useTempAmazonLog(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "AmazonMusic.log")
	amazonLogMu.Lock()
	savedOverride, savedLog := amazonMusicLogOverride, amazonLog
	amazonMusicLogOverride, amazonLog = path, nil
	amazonLogMu.Unlock()
	t.Cleanup(func() {
		amazonLogMu.Lock()
		amazonMusicLogOverride, amazonLog = savedOverride, savedLog
		amazonLogMu.Unlock()
	})
	return path
}

func appendAmazonLog(t *testing.T, path string, lines ...string) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	for _, l := range lines {
		if _, err := f.WriteString(l + "\n"); err != nil {
			t.Fatal(err)
		}
	}
}

func amazonTestQueueLine(uris ...string) string {
	return "260928:025618 MorphoBrowser : I HarleyPlayerController : PlayerFlow : Playables : UriList = " +
		strings.Join(uris, ", ") + " , function = updateQueue : line 571, "
}

const (
	amazonTestCQStart    = "260928:082218 MorphoBrowser : I CQPlaybackRequestImpl : PlayerFlow : StartingCQPlayback : function = startPlayback , identifierType = TRACK_LIST_SEED , identifiers = B0TESTAAA1 : line 58, "
	amazonTestPlainStart = "260928:090000 MorphoBrowser : I BasePlaybackRequest : PlayerFlow : StartPlaybackLookupCompleted : function = startPlaybackCallback : line 115, "
)

// 队列预解析:窗口(日志里最近一行 updateQueue)第一首要是 App 认出的、也是播放器报的这首;交出后两首,
// 并记下 ASIN 给歌词用。
func TestAmazonUpcomingAndLocalLyrics(t *testing.T) {
	useTempAmazonData(t)
	logPath := useTempAmazonLog(t)
	amazonCurrentMu.Lock()
	savedCur := amazonCurrentTrack
	amazonCurrentMu.Unlock()
	t.Cleanup(func() {
		amazonCurrentMu.Lock()
		amazonCurrentTrack = savedCur
		amazonCurrentMu.Unlock()
	})
	noteAmazonCurrentTrack(amazonMusicBundleID, "Morgan Wallen", "Been By Now", "asin://B0TESTAAA1")
	appendAmazonLog(t, logPath, amazonTestPlainStart, amazonTestQueueLine("asin-//B0TESTAAA1", "asin-//B0TESTAAA2", "asin-//B0MISSING0"))

	got, ok := amazonUpcoming("Morgan Wallen", "Been By Now", 5)
	if !ok || len(got) != 1 || got[0].title != "I Can't Love You Anymore [Explicit]" || got[0].artist != "Ella Langley & Morgan Wallen" || got[0].duration != 229 {
		t.Fatalf("交出后面那首(目录里查不到的不交): %+v ok=%v", got, ok)
	}
	if _, ok := amazonUpcoming("Someone Else", "Other", 5); ok {
		t.Error("播放器报的不是 App 认出的那首,退回同专辑预取")
	}
	appendAmazonLog(t, logPath, amazonTestQueueLine("asin-//B0OTHER000", "asin-//B0TESTAAA2"))
	if _, ok := amazonUpcoming("Morgan Wallen", "Been By Now", 5); ok {
		t.Error("窗口第一首不是当前这首,退回")
	}
	// 窗口里的都查不到名字:电台不预取(ok、零首),歌单 / 专辑退回同专辑预取。
	appendAmazonLog(t, logPath, amazonTestCQStart, amazonTestQueueLine("asin-//B0TESTAAA1", "asin-//B0MISSING0"))
	if got, ok := amazonUpcoming("Morgan Wallen", "Been By Now", 5); !ok || len(got) != 0 {
		t.Errorf("电台里认不出名字就不预取,也不退回同专辑: %+v ok=%v", got, ok)
	}
	appendAmazonLog(t, logPath, amazonTestPlainStart)
	if _, ok := amazonUpcoming("Morgan Wallen", "Been By Now", 5); ok {
		t.Error("歌单 / 专辑认不出名字,退回同专辑预取")
	}
	// App 没从日志认出这首(没带曲目标识):拿不准,退回同专辑预取。
	appendAmazonLog(t, logPath, amazonTestQueueLine("asin-//B0TESTAAA1", "asin-//B0TESTAAA2"))
	noteAmazonCurrentTrack(amazonMusicBundleID, "Morgan Wallen", "Been By Now", "")
	if _, ok := amazonUpcoming("Morgan Wallen", "Been By Now", 5); ok {
		t.Error("App 没带曲目标识,退回同专辑预取")
	}

	// 队列里那首解析歌词时按记下的 ASIN 认身份(歌名是剥过 [Explicit] 的);只在正用 Amazon Music 放时读。
	setNativeLyricSourcesForPlayer(amazonMusicBundleID)
	t.Cleanup(func() { setNativeLyricSourcesForPlayer("") })
	r, ok := amazonLocalLyricsFor("Ella Langley & Morgan Wallen", "I Can't Love You Anymore")
	if !ok || r.source != amazonLocalLyricsSource || !r.identityFromLocalClient || r.srcDur != 229 || r.matchAlbum == "" {
		t.Fatalf("本地歌词: %+v ok=%v", r, ok)
	}
	// 开播先上屏的那份:只给正在放的这首,预取的(isNewTrack=false)不垫。
	if p, ok := amazonProvisionalLyrics(true, amazonMusicBundleID, "Ella Langley & Morgan Wallen", "I Can't Love You Anymore"); !ok ||
		p.LyricsSource != amazonLocalLyricsSource || !strings.Contains(p.Lyrics, "nightstand") {
		t.Errorf("开播先上屏 Amazon 缓存里的那份: %+v ok=%v", p, ok)
	}
	if _, ok := amazonProvisionalLyrics(false, amazonMusicBundleID, "Ella Langley & Morgan Wallen", "I Can't Love You Anymore"); ok {
		t.Error("预取的不是在放的歌,不垫")
	}
	setNativeLyricSourcesForPlayer(spotifyBundleID)
	if _, ok := amazonLocalLyricsFor("Ella Langley & Morgan Wallen", "I Can't Love You Anymore"); ok {
		t.Error("没在用 Amazon Music 放时不读")
	}
	if _, ok := amazonProvisionalLyrics(true, spotifyBundleID, "Ella Langley & Morgan Wallen", "I Can't Love You Anymore"); ok {
		t.Error("别的播放器不垫")
	}
}

func TestAmazonLyricsWorthRecheck(t *testing.T) {
	e := enrichEntry{Lyrics: "[00:01.00]x", LyricsSourcesSeen: []string{"qq", "kugou"}}
	if !amazonLyricsWorthRecheck(e, amazonMusicBundleID, false, true, true) {
		t.Error("没见过 Amazon 那份、现在有 → 重来一次")
	}
	e.LyricsSourcesSeen = append(e.LyricsSourcesSeen, amazonLocalLyricsSource)
	if amazonLyricsWorthRecheck(e, amazonMusicBundleID, false, true, true) {
		t.Error("见过就不再来")
	}
	if amazonLyricsWorthRecheck(enrichEntry{}, kkboxBundleID, false, true, true) {
		t.Error("只管 Amazon Music")
	}
}

// 开播请求的两种形态:云端队列(电台)与普通开播(歌单 / 专辑)、播客。行照真实日志的形状。
func TestAmazonPlaybackStartKind(t *testing.T) {
	cq := "260928:082218 MorphoBrowser : I CQPlaybackRequestImpl : PlayerFlow : StartingCQPlayback : function = startPlayback , identifierType = TRACK_LIST_SEED , identifiers = B0TESTAAA1, B0TESTAAA2 : line 58, "
	plain := "260928:073659 MorphoBrowser : I BasePlaybackRequest : PlayerFlow : StartPlaybackLookupCompleted : function = startPlaybackCallback : line 115, "
	podcast := "260928:030035 MorphoBrowser : I PodcastPlayback : PlayerFlow : StartPodcastPlayback : function = startPlayback : line 108, "
	if cloud, ok := amazonPlaybackStartKind(cq); !ok || !cloud {
		t.Error("云端队列开播认成电台")
	}
	for _, l := range []string{plain, podcast} {
		if cloud, ok := amazonPlaybackStartKind(l); !ok || cloud {
			t.Errorf("普通开播 / 播客不算电台: %q", l)
		}
	}
	if _, ok := amazonPlaybackStartKind("260928:082220 MorphoBrowser : I CQPlaybackRequestImpl : PlayerFlow : CheckingRemainingTracks : function = needToGetNextTracks"); ok {
		t.Error("别的行不认")
	}
	if !amazonLastStartIsCloudQueue([]byte(plain+"\n"+cq+"\n")) || amazonLastStartIsCloudQueue([]byte(cq+"\n"+plain+"\n")) {
		t.Error("按最后一次开播算")
	}
	if amazonLastStartIsCloudQueue(nil) {
		t.Error("没有开播行不算电台")
	}
}

// 第一次只读末尾一段时,开播行在更前面也要认得出来。
func TestAmazonLogTailCloudQueueFromHead(t *testing.T) {
	path := filepath.Join(t.TempDir(), "AmazonMusic.log")
	cq := "260928:082218 MorphoBrowser : I CQPlaybackRequestImpl : PlayerFlow : StartingCQPlayback : function = startPlayback , identifierType = TRACK_LIST_SEED , identifiers = B0TESTAAA1 : line 58, \n"
	filler := strings.Repeat("260928:082300      Browser INFO in Harley : DT:M [DASHRangeFragmentLoader.cpp:100] Fetching fragment\n", (amazonLogTailOnFirstRead/80)+10)
	if err := os.WriteFile(path, []byte(cq+filler), 0o644); err != nil {
		t.Fatal(err)
	}
	tail := &amazonLogTail{path: path}
	tail.poll()
	if !tail.cloudQueue {
		t.Error("开播行在末尾那段之前,也要从前面补看出来")
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	f.WriteString("260928:090000 MorphoBrowser : I BasePlaybackRequest : PlayerFlow : StartPlaybackLookupCompleted : function = startPlaybackCallback : line 115, \n")
	f.Close()
	tail.poll()
	if tail.cloudQueue {
		t.Error("之后换成普通开播就不再算电台")
	}
}

// 不是在放、也不在队列里的那首(手动搜索另起的进程、补空 / 全量扫库),靠歌词缓存里记着的曲目页认出 ASIN。
func TestAmazonCachedASIN(t *testing.T) {
	useTempAmazonData(t)
	amazonCurrentMu.Lock()
	savedCur := amazonCurrentTrack
	amazonCurrentTrack.artist, amazonCurrentTrack.title, amazonCurrentTrack.trackID = "", "", ""
	amazonCurrentMu.Unlock()
	amazonQueueMu.Lock()
	savedQueue := amazonQueueASINs
	amazonQueueASINs = map[string]string{}
	amazonQueueMu.Unlock()
	enrichMu.Lock()
	savedCache := enrichCache
	enrichCache = map[string]enrichEntry{
		"Ella Langley & Morgan Wallen|I Can't Love You Anymore|Dandelion": {AmazonURL: "https://music.amazon.com/tracks/B0TESTAAA2"},
		"Someone|Broken Link|": {AmazonURL: "https://music.amazon.com/albums/B0TESTAAA1"},
	}
	enrichMu.Unlock()
	resetIndex := func() {
		amazonCachedASINsMu.Lock()
		amazonCachedASINs = nil
		amazonCachedASINsMu.Unlock()
	}
	resetIndex()
	t.Cleanup(func() {
		amazonCurrentMu.Lock()
		amazonCurrentTrack = savedCur
		amazonCurrentMu.Unlock()
		amazonQueueMu.Lock()
		amazonQueueASINs = savedQueue
		amazonQueueMu.Unlock()
		enrichMu.Lock()
		enrichCache = savedCache
		enrichMu.Unlock()
		resetIndex()
		setNativeLyricSourcesForPlayer("")
	})

	if got := amazonASINFor("Ella Langley & Morgan Wallen", "I Can't Love You Anymore [Explicit]"); got != "B0TESTAAA2" {
		t.Errorf("缓存里记着曲目页的那首认得出(歌名尾巴照常剥): %q", got)
	}
	if got := amazonASINFor("Someone", "Broken Link"); got != "" {
		t.Errorf("不是曲目页形状的链接不认: %q", got)
	}
	setNativeLyricSourcesForPlayer(amazonMusicBundleID)
	if r, ok := amazonLocalLyricsFor("Ella Langley & Morgan Wallen", "I Can't Love You Anymore"); !ok || r.source != amazonLocalLyricsSource {
		t.Errorf("不在放的那首也读得到本地歌词: %+v ok=%v", r, ok)
	}
	for _, u := range []string{"", "https://music.amazon.com/tracks/", "https://music.amazon.com/tracks/b0lower0000", "https://music.amazon.com/tracks/B0TESTAAA2x"} {
		if got := amazonASINFromTrackURL(u); got != "" {
			t.Errorf("amazonASINFromTrackURL(%q) = %q, want 空", u, got)
		}
	}
}
