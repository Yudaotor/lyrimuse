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
	`"album":{"name":"I Can't Love You Anymore","asin":"B0TESTALB1","image":"https://m.media-amazon.com/images/I/5194nbHWBoL._FMwebp_SX500_.jpg"},"artist":{"name":"Ella Langley & Morgan Wallen","asin":"B0TESTART1"}}` +
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
	amazonQueueMu.Lock()
	queuedAlbum := amazonQueueAlbums[amazonTrackIdentity(got[0].artist, got[0].title)]
	amazonQueueMu.Unlock()
	if queuedAlbum == "" || queuedAlbum != got[0].album {
		t.Errorf("队列里记下这首的专辑: %q, want %q", queuedAlbum, got[0].album)
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
	r, ok := amazonLocalLyricsFor("Ella Langley & Morgan Wallen", "I Can't Love You Anymore", "")
	if !ok || r.source != amazonLocalLyricsSource || !r.identityFromLocalClient || r.srcDur != 229 || r.matchAlbum == "" ||
		r.matchCover != "https://m.media-amazon.com/images/I/5194nbHWBoL._SX500_.jpg" {
		t.Fatalf("本地歌词: %+v ok=%v", r, ok)
	}
	// 开播先上屏的那份:只给正在放的这首,预取的(isNewTrack=false)不垫。
	if p, ok := amazonProvisionalLyrics(true, amazonMusicBundleID, "Ella Langley & Morgan Wallen", "I Can't Love You Anymore", ""); !ok ||
		p.LyricsSource != amazonLocalLyricsSource || !strings.Contains(p.Lyrics, "nightstand") {
		t.Errorf("开播先上屏 Amazon 缓存里的那份: %+v ok=%v", p, ok)
	}
	if _, ok := amazonProvisionalLyrics(false, amazonMusicBundleID, "Ella Langley & Morgan Wallen", "I Can't Love You Anymore", ""); ok {
		t.Error("预取的不是在放的歌,不垫")
	}
	setNativeLyricSourcesForPlayer(spotifyBundleID)
	if _, ok := amazonLocalLyricsFor("Ella Langley & Morgan Wallen", "I Can't Love You Anymore", ""); ok {
		t.Error("没在用 Amazon Music 放时不读")
	}
	if _, ok := amazonProvisionalLyrics(true, spotifyBundleID, "Ella Langley & Morgan Wallen", "I Can't Love You Anymore", ""); ok {
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

	if got := amazonASINFor("Ella Langley & Morgan Wallen", "I Can't Love You Anymore [Explicit]", ""); got != "B0TESTAAA2" {
		t.Errorf("缓存里记着曲目页的那首认得出(歌名尾巴照常剥): %q", got)
	}
	if got := amazonASINFor("Someone", "Broken Link", ""); got != "" {
		t.Errorf("不是曲目页形状的链接不认: %q", got)
	}
	setNativeLyricSourcesForPlayer(amazonMusicBundleID)
	if r, ok := amazonLocalLyricsFor("Ella Langley & Morgan Wallen", "I Can't Love You Anymore", ""); !ok || r.source != amazonLocalLyricsSource {
		t.Errorf("不在放的那首也读得到本地歌词: %+v ok=%v", r, ok)
	}
	for _, u := range []string{"", "https://music.amazon.com/tracks/", "https://music.amazon.com/tracks/b0lower0000", "https://music.amazon.com/tracks/B0TESTAAA2x"} {
		if got := amazonASINFromTrackURL(u); got != "" {
			t.Errorf("amazonASINFromTrackURL(%q) = %q, want 空", u, got)
		}
	}
}

// 专辑页 / 歌单页曲目表(跟单曲目录记录同一组键)里每首带 ISRC,单曲那份不带。
const amazonTestAlbumLookupValue = "\x16\x00\x00\x00\x00\x00\x00\x00serialization::archive\x13\x00\x04\x08\x04\x08\x01\x00\x00\x00" +
	`{"albumList":[{"asin":"B0TESTALB2","title":"JOURNEY TO THE WEST","tracks":[` +
	`{"asin":"B0TESTTRK1","globalAsin":"B0TESTGLB1","isrc":"HKC381600015","title":"Stressed","duration":282},` +
	`{"asin":"B0TESTTRK2","globalAsin":"B0TESTTRK2","isrc":"ZZZZZ9999999","title":"Placeholder","duration":200}]}]}` +
	"\xe5\x00\x01garbage"

const amazonTestPlaylistLookupValue = "\x16\x00\x00\x00\x00\x00\x00\x00serialization::archive\x13\x00\x04\x08\x04\x08\x01\x00\x00\x00" +
	`{"albumList":[],"playlistList":[{"asin":"B0TESTPL01","tracks":[` +
	`{"asin":"B0TESTAAA2","globalAsin":"B0TESTAAA2","isrc":"usum72401234","title":"I Can't Love You Anymore"}]}]}`

func TestAmazonISRCFromLookupEntries(t *testing.T) {
	localStorage, _ := useTempAmazonData(t)
	testWriteLog(t, filepath.Join(localStorage, "000016.log"), [][]testLDBEntry{{
		{key: "*.MusicContent.CacheEntry.PrimeCatalog_KATANA_B0TESTALB2", seq: 9, value: amazonTestAlbumLookupValue},
		{key: "*.MusicContent.CacheEntry.PrimeCatalog_KATANA_B0TESTPL01", seq: 10, value: amazonTestPlaylistLookupValue},
	}})
	reset := func() {
		amazonISRCIndexMu.Lock()
		amazonISRCIndex = nil
		amazonISRCIndexMu.Unlock()
	}
	reset()
	t.Cleanup(reset)
	for asin, want := range map[string]string{
		"B0TESTTRK1": "HKC381600015", // 专辑页曲目表,按曲目 ASIN
		"B0TESTGLB1": "HKC381600015", // 同一首的 globalAsin
		"B0TESTAAA2": "USUM72401234", // 歌单页曲目表,ISRC 统一转大写
		"B0TESTTRK2": "",             // 占位符样式的 ISRC 不收
		"B0TESTALB2": "",             // 专辑自己的 ASIN 不是曲目
		"":           "",
	} {
		if got := amazonISRCForASIN(asin); got != want {
			t.Errorf("amazonISRCForASIN(%q) = %q, want %q", asin, got, want)
		}
	}

	amazonCurrentMu.Lock()
	saved := amazonCurrentTrack
	amazonCurrentTrack.artist, amazonCurrentTrack.title, amazonCurrentTrack.trackID = "Khalil Fong", "Stressed", "asin://B0TESTTRK1"
	amazonCurrentMu.Unlock()
	t.Cleanup(func() {
		amazonCurrentMu.Lock()
		amazonCurrentTrack = saved
		amazonCurrentMu.Unlock()
	})
	if got := playbackISRC("Khalil Fong", "Stressed", "JOURNEY TO THE WEST"); got != "HKC381600015" {
		t.Errorf("用 Amazon Music 放的这首,播放器给的 ISRC 取它曲目表里记着的: %q", got)
	}
	if got := playbackISRC("方大同", "烦", "JTW西游记"); got != "" {
		t.Errorf("换了身份(别名轮)不再对应这一条录音: %q", got)
	}
}

// 同一份正文挂在两个 ASIN 上:「Ai!」(《唉!》,221s)挂的是同专辑「Love Love Love」(《爱爱爱》,213s)的词。
func TestAmazonLyricsBorrowedFromAnotherSong(t *testing.T) {
	_, hammer := useTempAmazonData(t)
	localStorage := amazonLocalStorageOverride
	catalog := func(asin, title, dur string) string {
		return "\x16\x00\x00\x00\x00\x00\x00\x00serialization::archive\x13\x00\x04\x08\x04\x08\x01\x00\x00\x00" +
			`{"id":"","uniqueId":"` + asin + `","asin":"` + asin + `","title":"` + title + `","duration":"` + dur + `","hasLyrics":true,` +
			`"album":{"name":"This Love","asin":"B0TESTALB2","image":""},"artist":{"name":"Khalil Fong","asin":"B0TESTART2"}}`
	}
	lyrics := strings.Replace(amazonTestLyricsJSON, "B0TESTAAA2", "B0TESTAI01", 1)
	testWriteLog(t, filepath.Join(localStorage, "000016.log"), [][]testLDBEntry{{
		{key: amazonCatalogKeyPrefix + "B0TESTAI01", seq: 20, value: catalog("B0TESTAI01", "Ai!", "221")},
		{key: amazonCatalogKeyPrefix + "B0TESTLLL1", seq: 21, value: catalog("B0TESTLLL1", "Love Love Love", "213")},
		{key: amazonCatalogKeyPrefix + "B0TESTRAD1", seq: 22, value: catalog("B0TESTRAD1", "Ai! (Radio Edit)", "200")},
		{key: amazonCatalogKeyPrefix + "B0TESTNEAR", seq: 23, value: catalog("B0TESTNEAR", "Something Else", "222")},
	}})
	writeHammer := func(name string, entries ...testLDBEntry) {
		testWriteLog(t, filepath.Join(hammer, name), [][]testLDBEntry{entries})
	}
	writeHammer("000012.log", testLDBEntry{key: "B0TESTAI01-ATVPDKIKX0DER", seq: 30, value: lyrics})
	meta := amazonCatalog([]string{"B0TESTAI01"})["B0TESTAI01"]
	lrc, _, _ := amazonLyricsForASIN("B0TESTAI01")

	// 用例共用的 B0TESTAAA2 那份(目录里歌名「I Can't Love You Anymore」、229s)本来就跟它一字不差:时长差 8s、歌名不同。
	if got := amazonLyricsBorrowedBy("B0TESTAI01", meta, lrc); got != `B0TESTAAA2 "I Can't Love You Anymore [Explicit]"` {
		t.Fatalf("同一份正文挂在歌名不同、时长差 8s 的另一首上要认出来, got %q", got)
	}
	// 只剩同名剪辑版和时长接近的另一首:都不算借来的。
	hammer2 := t.TempDir()
	amazonHammerCacheOverride = hammer2
	testWriteLog(t, filepath.Join(hammer2, "000013.log"), [][]testLDBEntry{{
		{key: "B0TESTAI01-ATVPDKIKX0DER", seq: 40, value: lyrics},
		{key: "B0TESTRAD1-ATVPDKIKX0DER", seq: 41, value: strings.Replace(lyrics, "B0TESTAI01", "B0TESTRAD1", 1)},
		{key: "B0TESTNEAR-ATVPDKIKX0DER", seq: 42, value: strings.Replace(lyrics, "B0TESTAI01", "B0TESTNEAR", 1)},
	}})
	if got := amazonLyricsBorrowedBy("B0TESTAI01", meta, lrc); got != "" {
		t.Fatalf("同一首歌的剪辑版、时长差不到 3s 的都不算, got %q", got)
	}
	testWriteLog(t, filepath.Join(hammer2, "000014.log"), [][]testLDBEntry{{
		{key: "B0TESTLLL1-ATVPDKIKX0DER", seq: 43, value: strings.Replace(lyrics, "B0TESTAI01", "B0TESTLLL1", 1)},
	}})
	if got := amazonLyricsBorrowedBy("B0TESTAI01", meta, lrc); got != `B0TESTLLL1 "Love Love Love"` {
		t.Fatalf("got %q", got)
	}

	// 接到检索上:借来的不置 identityFromLocalClient(不拿同源加权),也不先上屏;候选照样给。
	amazonCurrentMu.Lock()
	savedCur := amazonCurrentTrack
	amazonCurrentMu.Unlock()
	t.Cleanup(func() {
		setNativeLyricSourcesForPlayer("")
		amazonCurrentMu.Lock()
		amazonCurrentTrack = savedCur
		amazonCurrentMu.Unlock()
	})
	noteAmazonCurrentTrack(amazonMusicBundleID, "Khalil Fong", "Ai!", "asin://B0TESTAI01")
	setNativeLyricSourcesForPlayer(amazonMusicBundleID)
	r, ok := amazonLocalLyricsFor("Khalil Fong", "Ai!", "")
	if !ok || r.identityFromLocalClient || r.lyr == "" {
		t.Fatalf("借来的正文照样给候选,但不置 identityFromLocalClient: %+v ok=%v", r, ok)
	}
	if _, ok := amazonProvisionalLyrics(true, amazonMusicBundleID, "Khalil Fong", "Ai!", ""); ok {
		t.Error("借来的正文不先上屏")
	}
}

// 同一个歌手 + 歌名在缓存里记着好几版(单曲与专辑版、精选集、删减与不删减)、各是各的 ASIN 时按专辑认;专辑对不上、没有专辑名、
// 同一张专辑记着两个 ASIN 都认不出;只有一个 ASIN 时不看专辑。重建几次索引结果都一样(不看遍历缓存的顺序)。队列记着的专辑跟
// 这一首的对不上时改用缓存那份,队列没记专辑、这一首没给专辑时照用队列的。
func TestAmazonCachedASINPicksTheVersionByAlbum(t *testing.T) {
	amazonCurrentMu.Lock()
	savedCur := amazonCurrentTrack
	amazonCurrentTrack.artist, amazonCurrentTrack.title, amazonCurrentTrack.trackID = "", "", ""
	amazonCurrentMu.Unlock()
	amazonQueueMu.Lock()
	savedQueue, savedAlbums := amazonQueueASINs, amazonQueueAlbums
	amazonQueueASINs, amazonQueueAlbums = map[string]string{}, map[string]string{}
	amazonQueueMu.Unlock()
	resetIndex := func() {
		amazonCachedASINsMu.Lock()
		amazonCachedASINs = nil
		amazonCachedASINsMu.Unlock()
	}
	t.Cleanup(func() {
		amazonCurrentMu.Lock()
		amazonCurrentTrack = savedCur
		amazonCurrentMu.Unlock()
		amazonQueueMu.Lock()
		amazonQueueASINs, amazonQueueAlbums = savedQueue, savedAlbums
		amazonQueueMu.Unlock()
		resetIndex()
	})
	track := func(asin string) enrichEntry {
		return enrichEntry{AmazonURL: "https://music.amazon.com/tracks/" + asin}
	}
	withEnrichCache(t, map[string]enrichEntry{
		"Leehom Wang|Gong Zhuan Zi Zhuan|Revolution":                  track("B00FAEYA98"),
		"Leehom Wang|Gong Zhuan Zi Zhuan|The Only One [Clean]":        track("B073MW9HHQ"),
		"Leehom Wang|Gong Zhuan Zi Zhuan|Open Fire [Clean]":           track("B0060BJAQI"),
		"Ariana Grande|hate that i made you love me|petal [Clean]":    track("B0CLEAN001"),
		"Ariana Grande|hate that i made you love me|petal [Explicit]": track("B0EXPL0001"),
		"Someone|Dup|Same Album":                                      track("B0DUP00001"),
		"Some One|Dup|Same Album":                                     track("B0DUP00002"),
		"Jay Chou|Mojito|Mojito":                                      track("B0MOJITO01"),
		"Jay Chou|Mojito|Greatest Works Of Art":                       track("B0MOJITO01"),
	})
	resetIndex()
	for _, c := range []struct{ artist, title, album, want string }{
		{"Leehom Wang", "Gong Zhuan Zi Zhuan", "Revolution", "B00FAEYA98"},
		{"Leehom Wang", "Gong Zhuan Zi Zhuan", "The Only One [Clean]", "B073MW9HHQ"},
		{"Leehom Wang", "Gong Zhuan Zi Zhuan", " the only one  [clean]", "B073MW9HHQ"},
		{"Leehom Wang", "Gong Zhuan Zi Zhuan", "The Only One\u00a0[Clean]", "B073MW9HHQ"}, // 不换行空格
		{"Leehom Wang", "Gong Zhuan Zi Zhuan", "Greatest Hits", ""},
		{"Leehom Wang", "Gong Zhuan Zi Zhuan", "", ""},
		{"Ariana Grande", "hate that i made you love me", "petal [Explicit]", "B0EXPL0001"},
		{"Ariana Grande", "hate that i made you love me", "petal [Clean]", "B0CLEAN001"},
		{"Someone", "Dup", "Same Album", ""},
		{"Jay Chou", "Mojito", "Anything", "B0MOJITO01"},
		{"Jay Chou", "Mojito", "", "B0MOJITO01"},
	} {
		for i := 0; i < 5; i++ {
			resetIndex()
			if got := amazonASINFor(c.artist, c.title, c.album); got != c.want {
				t.Errorf("amazonASINFor(%q, %q, %q) = %q, want %q", c.artist, c.title, c.album, got, c.want)
				break
			}
		}
	}

	id := amazonTrackIdentity("Leehom Wang", "Gong Zhuan Zi Zhuan")
	amazonQueueMu.Lock()
	amazonQueueASINs[id], amazonQueueAlbums[id] = "B0QUEUE001", "Revolution"
	amazonQueueMu.Unlock()
	for album, want := range map[string]string{"Revolution": "B0QUEUE001", "The Only One [Clean]": "B073MW9HHQ", "": "B0QUEUE001"} {
		if got := amazonASINFor("Leehom Wang", "Gong Zhuan Zi Zhuan", album); got != want {
			t.Errorf("队列记着 Revolution,这一首的专辑 %q: got %q, want %q", album, got, want)
		}
	}
	amazonQueueMu.Lock()
	delete(amazonQueueAlbums, id)
	amazonQueueMu.Unlock()
	if got := amazonASINFor("Leehom Wang", "Gong Zhuan Zi Zhuan", "The Only One [Clean]"); got != "B0QUEUE001" {
		t.Errorf("队列没记专辑时照用队列的: %q", got)
	}
}

// 借词结论按库目录指纹记下:两个库目录里的文件没变就交记下的结论(不再整库扫),Hammer Cache 有了新文件就重扫。
func TestAmazonLyricsBorrowedMemoByDirStamp(t *testing.T) {
	_, hammer := useTempAmazonData(t)
	amazonBorrowedMemoMu.Lock()
	clear(amazonBorrowedMemo)
	amazonBorrowedMemoMu.Unlock()
	lyrics := strings.Replace(amazonTestLyricsJSON, "B0TESTAAA2", "B0TESTAI01", 1)
	testWriteLog(t, filepath.Join(hammer, "000012.log"), [][]testLDBEntry{{
		{key: "B0TESTAI01-ATVPDKIKX0DER", seq: 30, value: lyrics},
	}})
	lrc, _, ok := amazonLyricsForASIN("B0TESTAI01")
	if !ok {
		t.Fatal("测试库里应有 B0TESTAI01 的词")
	}
	meta := amazonCatalogTrack{Title: "Ai!"}
	first := amazonLyricsBorrowedBy("B0TESTAI01", meta, lrc)

	amazonBorrowedMemoMu.Lock()
	if len(amazonBorrowedMemo) != 1 {
		amazonBorrowedMemoMu.Unlock()
		t.Fatalf("应记下一条结论,got %d", len(amazonBorrowedMemo))
	}
	for k, v := range amazonBorrowedMemo {
		v.other = "memo"
		amazonBorrowedMemo[k] = v
	}
	amazonBorrowedMemoMu.Unlock()
	if got := amazonLyricsBorrowedBy("B0TESTAI01", meta, lrc); got != "memo" {
		t.Errorf("库目录没变应交记下的结论,got %q", got)
	}
	testWriteLog(t, filepath.Join(hammer, "000013.log"), [][]testLDBEntry{{
		{key: "B0TESTZZZ9-ATVPDKIKX0DER", seq: 31, value: "{}"},
	}})
	if got := amazonLyricsBorrowedBy("B0TESTAI01", meta, lrc); got != first {
		t.Errorf("Hammer Cache 变了应重扫,got %q want %q", got, first)
	}
}
