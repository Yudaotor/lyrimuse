package main

import (
	"strconv"
	"testing"
)

// ytmusicQueue 造一份 App 交来的 YouTube Music 队列:每行 selected(0/1)、歌名、歌手、专辑、秒、videoId,第七段写 "mv" 表示
// App 认出这一首是 MV。读页面、认字段、认 MV 都在 App(selftest player-query 组)。
func ytmusicQueue(rows ...[]string) appQueryTracks {
	var r appQueryTracks
	for _, f := range rows {
		secs, _ := strconv.ParseFloat(f[4], 64)
		r.Tracks = append(r.Tracks, appQueryTrack{Selected: f[0] == "1", Title: f[1], Artist: f[2], Album: f[3],
			Duration: secs, VideoID: f[5], MusicVideo: len(f) > 6 && f[6] == "mv"})
	}
	return r
}

// 实测形态:当前那首带 selected,后面按页面顺序往后取。
func TestYTMusicUpcomingReadsQueueAfterSelected(t *testing.T) {
	items := ytmusicQueueItems(ytmusicQueue(
		[]string{"0", "Superwoman", "曹格", "gary/曹格首張創作專輯/格格blue", "314", "qj2_y35XApk"},
		[]string{"1", "Miree", "Suchmos", "THE BAY", "243", "qrVxEBIKwco"},
		[]string{"0", "Officially Missing You", "Harryan Yoonsoan", "Harryan Yoonsoan Covers", "222", "DIL8AvMVP24"},
		[]string{"0", "Okay, Goodbye", "Fujii Kaze", "Prema", "231", "EAtRDZQLsgk"},
	))
	got, ok := pickYTMusicUpcoming(items, "Suchmos", "Miree", 0, 5)
	if !ok || len(got) != 2 {
		t.Fatalf("该取到 selected 之后的 2 首,得到 ok=%v %+v", ok, got)
	}
	if got[0].title != "Officially Missing You" || got[0].album != "Harryan Yoonsoan Covers" || got[0].duration != 222 {
		t.Errorf("字段不对: %+v", got[0])
	}
}

// selected 那首跟播放器报的对不上(同一个浏览器改放了别的网站、YouTube Music 标签页停在上次那首):
// 不拿它的队列;按名字在队列里找得到才算。
func TestYTMusicUpcomingIgnoresStaleSelected(t *testing.T) {
	items := ytmusicQueueItems(ytmusicQueue(
		[]string{"1", "Miree", "Suchmos", "THE BAY", "243", "a"},
		[]string{"0", "Okay, Goodbye", "Fujii Kaze", "Prema", "231", "b"},
		[]string{"0", "Lemon", "Kenshi Yonezu", "STRAY SHEEP", "257", "c"},
	))
	if got, ok := pickYTMusicUpcoming(items, "别的歌手", "别的歌", 0, 5); ok {
		t.Errorf("当前这首不在队列里,该退回同专辑预取,得到 %+v", got)
	}
	// selected 还没跟上(页面比播放器晚一拍):按名字找到 Okay, Goodbye,从它往后取。
	got, ok := pickYTMusicUpcoming(items, "Fujii Kaze", "Okay, Goodbye", 0, 5)
	if !ok || len(got) != 1 || got[0].title != "Lemon" {
		t.Errorf("该按名字定位到 Okay, Goodbye,得到 ok=%v %+v", ok, got)
	}
}

// 分发:Safari 报的是媒体代理进程(com.apple.WebKit.GPU),要换回 Safari 去问(配对那道门见
// TestBrowserPageProbesSkipUnpairedBrowsers)。
func TestUpcomingFromQueueRoutesBrowsersToYTMusic(t *testing.T) {
	old := ytmusicQueueScript
	t.Cleanup(func() { ytmusicQueueScript = old })
	var asked []string
	ytmusicQueueScript = func(bundleID string) (appQueryTracks, bool) {
		asked = append(asked, bundleID)
		return ytmusicQueue(
			[]string{"1", "Miree", "Suchmos", "THE BAY", "243", "a"},
			[]string{"0", "Lemon", "Kenshi Yonezu", "STRAY SHEEP", "257", "c"},
		), true
	}
	got, ok := upcomingFromQueue("Suchmos", "Miree", "THE BAY", "com.apple.WebKit.GPU", 0, 5)
	if !ok || len(got) != 1 || got[0].title != "Lemon" {
		t.Fatalf("Safari 播放该读到 YouTube Music 队列,得到 ok=%v %+v", ok, got)
	}
	if len(asked) != 1 || asked[0] != "com.apple.Safari" {
		t.Errorf("该换回宿主 Safari,实际 %v", asked)
	}
}

// 队列按账号语言本地化、名字对不上时:唯一那条 selected 的时长跟播放器报的相差 2s 内也认。
func TestYTMusicQueueCurrentFallsBackToSelectedDuration(t *testing.T) {
	items := ytmusicQueueItems(ytmusicQueue(
		[]string{"0", "今天有没有", "陶喆", "乐之路", "242", "a"},
		[]string{"1", "飞机场的10.30", "陶喆", "乐之路", "281", "b"},
		[]string{"0", "Always Been You", "Jesse Gold", "Always Been You", "185", "c"},
	))
	if got := ytmusicQueueCurrent(items, "David Tao", "Airport in 10:30", 280.773); got != 1 {
		t.Fatalf("该认 selected 那条,得到 %d", got)
	}
	got, ok := pickYTMusicUpcoming(items, "David Tao", "Airport in 10:30", 280.773, 5)
	if !ok || len(got) != 1 || got[0].title != "Always Been You" {
		t.Fatalf("该取到后面那首,得到 ok=%v %+v", ok, got)
	}
	if got := ytmusicQueueCurrent(items, "David Tao", "Airport in 10:30", 250); got != -1 {
		t.Errorf("时长差太多不该认(多半是停着的旧标签页),得到 %d", got)
	}
	if got := ytmusicQueueCurrent(items, "David Tao", "Airport in 10:30", 0); got != -1 {
		t.Errorf("不知道时长时不走兜底,得到 %d", got)
	}
	two := ytmusicQueueItems(ytmusicQueue(
		[]string{"1", "飞机场的10.30", "陶喆", "乐之路", "281", "b"},
		[]string{"1", "别的", "陶喆", "乐之路", "281", "c"},
	))
	if got := ytmusicQueueCurrent(two, "David Tao", "Airport in 10:30", 280.773); got != -1 {
		t.Errorf("不止一条 selected 时不猜,得到 %d", got)
	}
}

// 换歌那一拍页面的高亮还停在上一首:对不上时隔一会儿重读一次,第二次对上就用。
func TestBrowserUpcomingRetriesOnceOnMismatch(t *testing.T) {
	old := ytmusicQueueScript
	t.Cleanup(func() { ytmusicQueueScript = old })
	calls := 0
	ytmusicQueueScript = func(string) (appQueryTracks, bool) {
		calls++
		if calls == 1 {
			return ytmusicQueue(
				[]string{"1", "Okay, Goodbye", "Fujii Kaze", "Prema", "240", "a"},
				[]string{"0", "Superwoman", "曹格", "格格blue", "313", "b"},
				[]string{"0", "Miree", "Suchmos", "THE BAY", "243", "c"},
			), true
		}
		return ytmusicQueue(
			[]string{"0", "Okay, Goodbye", "Fujii Kaze", "Prema", "240", "a"},
			[]string{"1", "Superwoman", "曹格", "格格blue", "313", "b"},
			[]string{"0", "Miree", "Suchmos", "THE BAY", "243", "c"},
		), true
	}
	// 第一次读到的高亮是上一首;按名字找也能找到 Superwoman,所以用一个名字对不上的当前曲目来测重读。
	got, ok := browserUpcoming("曹格", "Superwoman", "com.apple.WebKit.GPU", 313, 5)
	if !ok || len(got) != 1 || got[0].title != "Miree" {
		t.Fatalf("该取到 Superwoman 后面那首,得到 ok=%v %+v", ok, got)
	}
	if calls != 1 {
		t.Fatalf("按名字就能定位时不该重读,实际读了 %d 次", calls)
	}

	calls = 0
	ytmusicQueueScript = func(string) (appQueryTracks, bool) {
		calls++
		sel := map[bool]string{true: "1", false: "0"}
		return ytmusicQueue(
			[]string{sel[calls == 1], "上一首", "甲", "专辑", "180", "a"},
			[]string{sel[calls > 1], "本地化的名字", "乙", "专辑", "281", "b"},
			[]string{"0", "下一首", "丙", "专辑", "190", "c"},
		), true
	}
	got, ok = browserUpcoming("B", "Localized", "com.apple.WebKit.GPU", 280.8, 5)
	if !ok || calls != 2 || len(got) != 1 || got[0].title != "下一首" {
		t.Fatalf("第一次对不上、第二次靠 selected+时长对上:该读 2 次并取到下一首,得到 ok=%v calls=%d %+v", ok, calls, got)
	}

	calls = 0
	ytmusicQueueScript = func(string) (appQueryTracks, bool) {
		calls++
		return ytmusicQueue([]string{"1", "停着的另一首", "甲", "专辑", "180", "a"}, []string{"0", "x", "乙", "专辑", "180", "b"}), true
	}
	if _, ok := browserUpcoming("B", "Localized", "com.apple.WebKit.GPU", 280.8, 5); ok || calls != 2 {
		t.Fatalf("两次都对不上:该读 2 次后放弃,得到 ok=%v calls=%d", ok, calls)
	}

	// 没有这个网站的标签页:App 交来空的队列,不重读。
	calls = 0
	ytmusicQueueScript = func(string) (appQueryTracks, bool) { calls++; return appQueryTracks{}, true }
	if _, ok := browserUpcoming("B", "Localized", "com.apple.WebKit.GPU", 280.8, 5); ok || calls != 1 {
		t.Fatalf("没有这个网站的标签页时不该重读,得到 ok=%v calls=%d", ok, calls)
	}
}

// App 认出的 MV(实测 Safari 里一份 MV 队列 51 条,每条都是官方 MV)交给预取的时长是 0 = 未知,跟真播到时一致;
// 别的照报时长。
func TestYTMusicUpcomingMusicVideoDurationUnknown(t *testing.T) {
	items := ytmusicQueueItems(ytmusicQueue(
		[]string{"1", "Dynamite", "BTS", "", "224", "gdZLi9oWNZg", "mv"},
		[]string{"0", "My Universe", "Coldplay和BTS", "", "283", "3YqPKLZF_WU", "mv"},
		[]string{"0", "Butter", "BTS", "Butter", "165", "a"},
		[]string{"0", "Seven", "Jung Kook", "Seven", "184", "b"},
		[]string{"0", "Lemon", "Kenshi Yonezu", "STRAY SHEEP", "257", "c"},
	))
	got, ok := pickYTMusicUpcoming(items, "BTS", "Dynamite", 0, 5)
	if !ok || len(got) != 4 {
		t.Fatalf("该取到 4 首,得到 ok=%v %+v", ok, got)
	}
	want := []float64{0, 165, 184, 257}
	for i, w := range want {
		if got[i].duration != w {
			t.Errorf("第 %d 首(%s)时长该是 %v,得到 %v", i, got[i].title, w, got[i].duration)
		}
	}
}
