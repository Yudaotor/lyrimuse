package main

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 问 YouTube Music 回了 200、里面却没有这一条:不记成问过,下一次照样问;认得出的照常只问一次。
func TestYTMusicCreditUnrecognizedNotCached(t *testing.T) {
	withYTMusicCredits(t, nil)
	reqs := withYtmusicFake(t, func(w http.ResponseWriter, req ytmusicFakeReq) {
		if req.target == ytmNextURL {
			_, _ = w.Write([]byte(`{"contents":{}}`))
			return
		}
		w.WriteHeader(http.StatusNotFound)
	})
	for i := 0; i < 2; i++ {
		if c := ytmusicListedTrack(context.Background(), "Qt2mbGP6vFI", "zh-CN"); c != (ytmusicCredit{}) {
			t.Fatalf("认不出时是空的: %+v", c)
		}
	}
	if n := len(reqs()); n != 2 {
		t.Errorf("认不出的应答不缓存,两次都要问: %d", n)
	}
	if _, settled := ytmusicListedTrackSettled(context.Background(), "Qt2mbGP6vFI", "zh-CN"); settled {
		t.Error("认不出的不算问成,补判不据此记结论")
	}
}

// 汽水按 id 补曲目信息:接口答了没有这首的隔一阵再问,时刻只记墙钟;断网这种一时没问成的不拉黑。
func TestSodaTrackMetaTransientFailureNotBlacklisted(t *testing.T) {
	withSodaTrackMeta(t, nil, func(_ context.Context, id string) (sodaTrackMeta, error) {
		if id == "missing" {
			return sodaTrackMeta{}, errSodaTrackMetaMissing
		}
		return sodaTrackMeta{}, errors.New("dial tcp: network is unreachable")
	}, true)
	sodaTrackMetaMu.Lock()
	sodaTrackMetaPending = []string{"offline", "missing"}
	sodaTrackMetaQueued["offline"], sodaTrackMetaQueued["missing"] = true, true
	sodaTrackMetaMu.Unlock()
	sodaTrackMetaWorker()
	sodaTrackMetaMu.Lock()
	defer sodaTrackMetaMu.Unlock()
	if _, ok := sodaTrackMetaFailed["offline"]; ok {
		t.Error("一时没问成的不拉黑")
	}
	at, ok := sodaTrackMetaFailed["missing"]
	if !ok || strings.Contains(at.String(), "m=") {
		t.Errorf("查无此曲的隔一阵再问,只记墙钟: ok=%v at=%v", ok, at)
	}
}

// 洛雪当前这首不在 playInfo 那个列表里时,同名同歌手但登记时长对不上的不认。
func TestLXMusicCurrentTrackRejectsOtherLength(t *testing.T) {
	withLXMusicData(t, lxTestList, nil, "userlist_gone", 0, "")
	if tr, _, _, ok := lxMusicCurrentTrack(context.Background(), "周杰伦", "晴天", 400); ok {
		t.Errorf("时长差三成的同名歌不认: %+v", tr)
	}
	if tr, _, _, ok := lxMusicCurrentTrack(context.Background(), "周杰伦", "晴天", 271); !ok || tr.ID != "kw_9" {
		t.Errorf("时长对得上的照认: %+v ok=%v", tr, ok)
	}
}

// 好几条队列都停在这首上时用最近落盘的那条(文件里是一张表,遍历顺序随机,所以多问几次)。
func TestSodaUpcomingPrefersNewestQueue(t *testing.T) {
	writeTestSodaQueues(t, map[string]testSodaQueue{
		"feed": {savedAt: 100, lastPlayed: 0, tracks: []map[string]any{
			sodaSong("当前", "甲"), sodaSong("旧队列的下一首", "乙"),
		}},
		"focus": {savedAt: 900, lastPlayed: 0, tracks: []map[string]any{
			sodaSong("当前", "甲"), sodaSong("新队列的下一首", "丙"),
		}},
	})
	for i := 0; i < 20; i++ {
		got, ok := sodaUpcoming("甲", "当前", 5)
		if !ok || len(got) != 1 || got[0].title != "新队列的下一首" {
			t.Fatalf("第 %d 次: ok=%v got=%v", i+1, ok, got)
		}
	}
}

// Amazon 日志被换成新文件、读到之前就长过了旧的读取位置:认出是另一个文件,从头读。
func TestAmazonLogTailNewFileLongerThanOffset(t *testing.T) {
	path := filepath.Join(t.TempDir(), "AmazonMusic.log")
	appendAmazonLog(t, path, amazonTestPlainStart, amazonTestQueueLine("asin-//B0TESTAAA1"))
	tail := &amazonLogTail{path: path}
	tail.poll()
	if strings.Join(tail.queue, ",") != "asin://B0TESTAAA1" {
		t.Fatalf("第一次读: %v", tail.queue)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	long := strings.Repeat("260928:025700      Browser INFO in Harley : padding line\n", 20)
	appendAmazonLog(t, path, amazonTestCQStart, amazonTestQueueLine("asin-//B0TESTBBB1", "asin-//B0TESTBBB2"), long)
	tail.poll()
	if strings.Join(tail.queue, ",") != "asin://B0TESTBBB1,asin://B0TESTBBB2" || !tail.cloudQueue {
		t.Fatalf("新文件从头读: queue=%v cloud=%v", tail.queue, tail.cloudQueue)
	}
}

// Spotify 歌词缓存里扫到一个头还没写全的条目:不记看过、不推水位,写完之后下一轮读得到。
func TestSpotifyLyricsHalfWrittenEntryRereadLater(t *testing.T) {
	dir := t.TempDir()
	useSpotifyLyricsCacheDir(t, dir)
	path := filepath.Join(dir, "aaaaaaaaaaaaaaaa_0")
	if err := os.WriteFile(path, []byte{0, 1, 2}, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, ok := spotifyLocalLyricsByTrackID(spotifyLyricsTestID); ok {
		t.Fatal("还没写全时没有")
	}
	if err := os.WriteFile(path, spotifySimpleCacheEntry(spotifyLyricsKey(spotifyLyricsTestID), gzipBytes(t, spotifyLyricsTestJSON)), 0o600); err != nil {
		t.Fatal(err)
	}
	later := time.Now().Add(time.Minute)
	if err := os.Chtimes(path, later, later); err != nil {
		t.Fatal(err)
	}
	spotifyLyricsMu.Lock()
	spotifyLyricsScannedAt = spotifyLyricsScannedAt.Add(-spotifyLyricsRescanMin)
	spotifyLyricsMu.Unlock()
	if _, ok := spotifyLocalLyricsByTrackID(spotifyLyricsTestID); !ok {
		t.Error("写完之后下一轮读得到")
	}
}

// 源码契约:同专辑预取、Kaset 专辑补判走后台出站档;QQ 本机曲库被调用方取消时不占重扫间隔;队列文件认不出记进解析漂移;
// msgpackr 预分配有上限;Spotify 随机状态只记墙钟。
func TestPlayersAuditContracts(t *testing.T) {
	read := func(name string) string {
		data, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}
	for _, c := range []struct{ file, snippet, why string }{
		{"qqlocal.go", "ctx, cancel := withCancelAfter(withBackgroundOutbound(context.Background()), 10*time.Second)\n\tdefer cancel()\n\tsongs, err := qqAlbumSongs(ctx, mid)", "QQ 同专辑预取走后台档"},
		{"sodaalbum.go", "ctx, cancel := withCancelAfter(withBackgroundOutbound(context.Background()), 10*time.Second)", "汽水同专辑预取走后台档"},
		{"kugouqueue.go", "ctx, cancel := withCancelAfter(withBackgroundOutbound(context.Background()), 10*time.Second)", "酷狗同专辑预取走后台档"},
		{"kasetalbum.go", "ctx = withBackgroundOutbound(ctx)\n\thl := ytmusicDisplayLanguage()", "Kaset 专辑补判走后台档"},
		{"qqlocal.go", "if ctx.Err() != nil {\n\t\t\tqqLocalScanned = time.Time{}\n\t\t}", "QQ 本机曲库被取消时下一次照常扫"},
		{"qqlocal.go", `noteParserUnrecognized("qq-playing-list", "PlayingList.ListData missing")`, "QQ 播放列表认不出记漂移"},
		{"kugouqueue.go", `noteParserUnrecognized("kugou-play-list", "userPlayList missing")`, "酷狗播放列表认不出记漂移"},
		{"neteaselocal.go", `noteParserUnrecognized("netease-playing-list", err.Error())`, "网易云播放列表认不出记漂移"},
		{"sodapreload.go", "out := make([]any, 0, min(n, msgpackrPreallocMax))", "msgpackr 数组预分配有上限"},
		{"sodapreload.go", "m := make(map[string]any, min(n, msgpackrPreallocMax))", "msgpackr 表预分配有上限"},
		{"spotifyqueue.go", "spotifyLastShuffle.on, spotifyLastShuffle.at = on, now.Round(0)", "Spotify 随机状态只记墙钟"},
		{"soda.go", "sodaSearchCacheEntry{items: items, at: now.Round(0), host: host}", "汽水搜索缓存只记墙钟"},
	} {
		if !containsCode(read(c.file), c.snippet) {
			t.Errorf("%s: %s", c.file, c.why)
		}
	}
}
