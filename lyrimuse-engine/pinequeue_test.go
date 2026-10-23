package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

// withPineQueue 把问 App 换成固定的列表(repeating 为循环档),清掉顺序 / 随机的证据;calls 记问了几次。
func withPineQueue(t *testing.T, repeating string, tracks []pineQueueTrack) *int {
	t.Helper()
	b, err := json.Marshal(pineQueueReply{Repeating: repeating, Tracks: tracks})
	if err != nil {
		t.Fatal(err)
	}
	calls := 0
	saved := pineQueueAsk
	pineQueueAsk = func() (string, bool) { calls++; return string(b), true }
	pinePlayOrderMu.Lock()
	pinePlayOrderLast = queueOrder{}
	pinePlayOrderMu.Unlock()
	t.Cleanup(func() { pineQueueAsk = saved })
	return &calls
}

func pineTracks(names ...string) []pineQueueTrack {
	out := make([]pineQueueTrack, len(names))
	for i, n := range names {
		out[i] = pineQueueTrack{Title: n, Artist: "歌手" + n, Album: "专辑", Duration: 200, File: n + ".mp3"}
	}
	return out
}

func pineGot(res []upcomingTrack) string {
	var s []string
	for _, r := range res {
		s = append(s, r.title)
	}
	return strings.Join(s, ",")
}

// 按列表往后取,带专辑、时长;不循环时到最后为止,最后一首后面没有退回同专辑预取。
func TestPineUpcomingFollowsPlaylist(t *testing.T) {
	withPineQueue(t, "off", pineTracks("A", "B", "C", "D"))
	res, ok := pineUpcoming("歌手B", "B", 5)
	if !ok || pineGot(res) != "C,D" {
		t.Fatalf("从当前这首往后: ok=%v %q", ok, pineGot(res))
	}
	if res[0].artist != "歌手C" || res[0].album != "专辑" || res[0].duration != 200 {
		t.Errorf("歌手、专辑、时长带上: %+v", res[0])
	}
	withPineQueue(t, "off", pineTracks("A", "B", "C", "D"))
	if _, ok := pineUpcoming("歌手D", "D", 5); ok {
		t.Error("不循环时最后一首后面没有,退回同专辑预取")
	}
	if _, ok := pineUpcoming("谁", "不在列表里", 5); ok {
		t.Error("列表里没有当前这首要退回")
	}
	saved := pineQueueAsk
	pineQueueAsk = func() (string, bool) { return "", false }
	if _, ok := pineUpcoming("歌手B", "B", 5); ok {
		t.Error("App 读不到列表要退回")
	}
	pineQueueAsk = func() (string, bool) { return `{"tracks":[]}`, true }
	if _, ok := pineUpcoming("歌手B", "B", 5); ok {
		t.Error("空列表要退回")
	}
	pineQueueAsk = saved
}

// 单曲循环不预取(也不退回);列表循环在最后接回开头、绕一圈不含当前这首;读不出循环档时到最后为止。
func TestPineUpcomingFollowsRepeatMode(t *testing.T) {
	for _, mode := range []string{"one", "stop"} {
		withPineQueue(t, mode, pineTracks("A", "B", "C"))
		if res, ok := pineUpcoming("歌手B", "B", 5); !ok || len(res) != 0 {
			t.Errorf("%s(单曲循环 / 放完这首就停): ok=%v %q", mode, ok, pineGot(res))
		}
	}
	withPineQueue(t, "all", pineTracks("A", "B", "C", "D"))
	if res, ok := pineUpcoming("歌手D", "D", 2); !ok || pineGot(res) != "A,B" {
		t.Errorf("列表循环在最后一首: ok=%v %q", ok, pineGot(res))
	}
	withPineQueue(t, "all", pineTracks("A", "B", "C", "D"))
	if res, ok := pineUpcoming("歌手B", "B", 9); !ok || pineGot(res) != "C,D,A" {
		t.Errorf("列表循环绕一圈到当前为止: ok=%v %q", ok, pineGot(res))
	}
	withPineQueue(t, "", pineTracks("A", "B", "C", "D"))
	if _, ok := pineUpcoming("歌手D", "D", 5); ok {
		t.Error("读不出循环档时按不循环")
	}
}

// 当前这首按文件名认:同名同歌手的两份(两个目录 / 两种格式)取文件名对上的那一行;文件名对不上或不止一行时按歌名歌手。
func TestPineUpcomingLocatesByFile(t *testing.T) {
	tracks := []pineQueueTrack{
		{Title: "A", Artist: "甲", File: "a.mp3"}, {Title: "B", Artist: "乙", File: "b.mp3"},
		{Title: "A", Artist: "甲", File: "a.flac"}, {Title: "C", Artist: "丙", File: "c.mp3"},
	}
	if got := pineCurrentIndex(tracks, "a.flac", "甲", "A"); got != 2 {
		t.Errorf("按文件名认出后一份: %d", got)
	}
	if got := pineCurrentIndex(tracks, "", "乙", "B"); got != 1 {
		t.Errorf("没有文件名时按歌名歌手: %d", got)
	}
	if got := pineCurrentIndex(tracks, "other.mp3", "丙", "C"); got != 3 {
		t.Errorf("文件名对不上时按歌名歌手: %d", got)
	}
	dup := append([]pineQueueTrack{}, tracks...)
	dup[1].File = "c.mp3"
	if got := pineCurrentIndex(dup, "c.mp3", "乙", "B"); got != 1 {
		t.Errorf("文件名不止一行时按歌名歌手: %d", got)
	}

	localFileCurrentMu.Lock()
	savedCur := localFileCurrent
	localFileCurrent.path, localFileCurrent.artist, localFileCurrent.title = "/Users/x/Music/2/a.flac", "甲", "A"
	localFileCurrentMu.Unlock()
	t.Cleanup(func() {
		localFileCurrentMu.Lock()
		localFileCurrent = savedCur
		localFileCurrentMu.Unlock()
	})
	withPineQueue(t, "off", tracks)
	if res, ok := pineUpcoming("甲", "A", 1); !ok || pineGot(res) != "C" {
		t.Errorf("用 App 报的当前文件定位: ok=%v %q", ok, pineGot(res))
	}
}

// 随机开没开读不出:相邻两次换歌跳了位置就按随机交整份列表(不超过 queueShuffleWholeListMax 首时);接着又按顺序走就翻回来。
// 列表循环从最后一首接回第一首算顺序。
func TestPineUpcomingInfersShuffle(t *testing.T) {
	withPineQueue(t, "all", pineTracks("A", "B", "C", "D", "E"))
	step := func(title string) string {
		res, ok := pineUpcoming("歌手"+title, title, 2)
		if !ok {
			t.Fatalf("%s: 没取到", title)
		}
		return pineGot(res)
	}
	if got := step("B"); got != "C,D" {
		t.Errorf("头一次没有证据,按顺序: %q", got)
	}
	if got := step("C"); got != "D,E" {
		t.Errorf("下一位是顺序: %q", got)
	}
	if got := step("A"); got != "B,C,D,E" {
		t.Errorf("跳了位置按随机交整份列表(不含当前): %q", got)
	}
	if got := step("B"); got != "C,D" {
		t.Errorf("又按顺序走了就翻回顺序: %q", got)
	}
	step("C")
	step("D")
	step("E")
	if got := step("A"); got != "B,C" {
		t.Errorf("列表循环从最后一首接回第一首不算随机: %q", got)
	}
	// 换了一份列表(加了一首)重新攒证据。
	withPineQueue(t, "off", pineTracks("A", "B", "C", "D", "E", "F"))
	if got := step("E"); got != "F" {
		t.Errorf("换了列表按顺序: %q", got)
	}
}

// 歌手空的行(没写标签、拆不出歌手)跳过。
func TestPineUpcomingSkipsRowsWithoutArtist(t *testing.T) {
	tracks := pineTracks("A", "B", "C")
	tracks[1].Artist = ""
	withPineQueue(t, "off", tracks)
	if res, ok := pineUpcoming("歌手A", "A", 5); !ok || pineGot(res) != "C" {
		t.Errorf("跳过歌手空的: ok=%v %q", ok, pineGot(res))
	}
}

// 列表由 App 代读:请求种类是 pine_queue;键名跟 App 侧 PinePlaylist 一起改;分发接上。
func TestPineQueueContract(t *testing.T) {
	reqPath, repPath := useAppQueryChannel(t, true)
	seen := fakePlayerQueryApp(t, reqPath, repPath, func(r appQueryRequest) *appQueryReply {
		return &appQueryReply{Schema: appQuerySchema, ID: r.ID, OK: true, Output: `{"tracks":[]}`}
	})
	if _, ok := pineQueueAsk(); !ok {
		t.Fatal("应拿到 App 的应答")
	}
	select {
	case req := <-seen:
		if req.Kind != appQueryPineQueue {
			t.Errorf("请求种类: %q", req.Kind)
		}
	case <-time.After(time.Second):
		t.Fatal("没看到请求")
	}

	src, err := os.ReadFile("../lyrimuse/Sources/LyrimuseCore/Local/PinePlaylist.swift")
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"title: String", "artist: String", "album: String", "duration: Double", "file: String",
		"tracks: [Track]", "repeating: String?"} {
		if !strings.Contains(string(src), "public var "+f) {
			t.Errorf("PinePlaylist.swift 里找不到 %q(pineQueueReply 的键名两边一起改)", f)
		}
	}
	for _, mode := range []string{"off", "one", "all"} {
		if !strings.Contains(string(src), fmt.Sprintf("return %q", mode)) {
			t.Errorf("PinePlaylist.repeating 里找不到 %q", mode)
		}
	}
	b, err := os.ReadFile("upcoming.go")
	if err != nil {
		t.Fatal(err)
	}
	if !containsCode(string(b), "case pinePlayerBundleID:\n") || !containsCode(string(b), "return pineUpcoming(artist, title, n)\n") {
		t.Error("upcomingFromQueue 里 Pine 没接上读列表")
	}
}
