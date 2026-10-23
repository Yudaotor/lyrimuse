package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

// withReampQueue 把问 App 换成固定的列表(repeating 为菜单的档),清掉顺序 / 随机的证据。
func withReampQueue(t *testing.T, repeating string, tracks []pineQueueTrack) {
	t.Helper()
	b, err := json.Marshal(pineQueueReply{Repeating: repeating, Tracks: tracks})
	if err != nil {
		t.Fatal(err)
	}
	saved := reampQueueAsk
	reampQueueAsk = func() (string, bool) { return string(b), true }
	reampPlayOrderMu.Lock()
	reampPlayOrderLast = queueOrder{}
	reampPlayOrderMu.Unlock()
	t.Cleanup(func() { reampQueueAsk = saved })
}

// 按列表往后取;关循环到最后为止、列表循环接回开头;列表里没有当前这首(这一轮换过列表)退回同专辑预取。
func TestReampUpcomingFollowsSavedPlaylist(t *testing.T) {
	withReampQueue(t, "off", pineTracks("A", "B", "C", "D"))
	if res, ok := reampUpcoming("歌手B", "B", 5); !ok || pineGot(res) != "C,D" {
		t.Errorf("往后取: ok=%v %q", ok, pineGot(res))
	}
	withReampQueue(t, "off", pineTracks("A", "B", "C", "D"))
	if _, ok := reampUpcoming("歌手D", "D", 5); ok {
		t.Error("关循环时最后一首后面没有")
	}
	withReampQueue(t, "all", pineTracks("A", "B", "C", "D"))
	if res, ok := reampUpcoming("歌手D", "D", 2); !ok || pineGot(res) != "A,B" {
		t.Errorf("列表循环接回开头: ok=%v %q", ok, pineGot(res))
	}
	withReampQueue(t, "off", pineTracks("A", "B"))
	if _, ok := reampUpcoming("谁", "这一轮新加的歌", 5); ok {
		t.Error("列表里没有当前这首要退回")
	}
	saved := reampQueueAsk
	reampQueueAsk = func() (string, bool) { return "", false }
	if _, ok := reampUpcoming("歌手B", "B", 5); ok {
		t.Error("App 读不到列表要退回")
	}
	reampQueueAsk = saved
}

// 菜单读得到随机就按它(第一首就交整份候选);读到关 / 列表循环就按列表,手动跳着点也不当随机;读不到才按换歌行为推断。
func TestReampUpcomingShuffleFromMenu(t *testing.T) {
	withReampQueue(t, "shuffle", pineTracks("A", "B", "C", "D"))
	if res, ok := reampUpcoming("歌手B", "B", 1); !ok || pineGot(res) != "C,D,A" {
		t.Errorf("菜单开着随机: ok=%v %q", ok, pineGot(res))
	}
	withReampQueue(t, "off", pineTracks("A", "B", "C", "D"))
	reampUpcoming("歌手A", "A", 1)
	if res, ok := reampUpcoming("歌手C", "C", 1); !ok || pineGot(res) != "D" {
		t.Errorf("菜单是关:跳着点也按列表: ok=%v %q", ok, pineGot(res))
	}
	withReampQueue(t, "", pineTracks("A", "B", "C", "D"))
	reampUpcoming("歌手A", "A", 1)
	if res, ok := reampUpcoming("歌手C", "C", 1); !ok || pineGot(res) != "D,A,B" {
		t.Errorf("读不出菜单时按换歌行为推断随机: ok=%v %q", ok, pineGot(res))
	}
}

// 列表由 App 代读:请求种类 reamp_queue;分发接上。
func TestReampQueueContract(t *testing.T) {
	reqPath, repPath := useAppQueryChannel(t, true)
	seen := fakePlayerQueryApp(t, reqPath, repPath, func(r appQueryRequest) *appQueryReply {
		return &appQueryReply{Schema: appQuerySchema, ID: r.ID, OK: true, Output: `{"tracks":[]}`}
	})
	if _, ok := reampQueueAsk(); !ok {
		t.Fatal("应拿到 App 的应答")
	}
	select {
	case req := <-seen:
		if req.Kind != appQueryReampQueue {
			t.Errorf("请求种类: %q", req.Kind)
		}
	case <-time.After(time.Second):
		t.Fatal("没看到请求")
	}
	src, err := os.ReadFile("../lyrimuse/Sources/LyrimuseCore/Local/ReampPlaylist.swift")
	if err != nil {
		t.Fatal(err)
	}
	for _, v := range []string{`return "shuffle"`, `return "all"`, `return "off"`} {
		if !strings.Contains(string(src), v) {
			t.Errorf("ReampPlaylist.repeating 里找不到 %s(两边一起改)", v)
		}
	}
	b, err := os.ReadFile("upcoming.go")
	if err != nil {
		t.Fatal(err)
	}
	if !containsCode(string(b), "case reampBundleID:\n") || !containsCode(string(b), "return reampUpcoming(artist, title, n)\n") {
		t.Error("upcomingFromQueue 里 reAMP 没接上读列表")
	}
}
