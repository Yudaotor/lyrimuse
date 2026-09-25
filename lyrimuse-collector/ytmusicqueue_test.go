package main

import (
	"strings"
	"testing"
)

// 造一段 ytmusicQueueJS 的输出:字段用 US、记录用 RS。
func ytmusicQueueRaw(rows ...[]string) string {
	recs := make([]string, 0, len(rows))
	for _, r := range rows {
		recs = append(recs, strings.Join(r, "\x1f"))
	}
	return strings.Join(recs, "\x1e")
}

// 实测形态:当前那首带 selected,后面按页面顺序往后取;专辑、时长都解出来。
func TestYTMusicUpcomingReadsQueueAfterSelected(t *testing.T) {
	raw := ytmusicQueueRaw(
		[]string{"0", "Superwoman", "曹格", "gary/曹格首張創作專輯/格格blue", "5:14", "qj2_y35XApk"},
		[]string{"1", "Miree", "Suchmos", "THE BAY", "4:03", "qrVxEBIKwco"},
		[]string{"0", "Officially Missing You", "Harryan Yoonsoan", "Harryan Yoonsoan Covers", "3:42", "DIL8AvMVP24"},
		[]string{"0", "Okay, Goodbye", "Fujii Kaze", "Prema", "3:51", "EAtRDZQLsgk"},
	)
	got, ok := pickYTMusicUpcoming(parseYTMusicQueue(raw+"\n"), "Suchmos", "Miree", 0, 5)
	if !ok || len(got) != 2 {
		t.Fatalf("该取到 selected 之后的 2 首,得到 ok=%v %+v", ok, got)
	}
	if got[0].title != "Officially Missing You" || got[0].album != "Harryan Yoonsoan Covers" || got[0].duration != 222 {
		t.Errorf("字段解错: %+v", got[0])
	}
}

// selected 那首跟播放器报的对不上(同一个浏览器改放了别的网站、YouTube Music 标签页停在上次那首):
// 不拿它的队列;按名字在队列里找得到才算。
func TestYTMusicUpcomingIgnoresStaleSelected(t *testing.T) {
	items := parseYTMusicQueue(ytmusicQueueRaw(
		[]string{"1", "Miree", "Suchmos", "THE BAY", "4:03", "a"},
		[]string{"0", "Okay, Goodbye", "Fujii Kaze", "Prema", "3:51", "b"},
		[]string{"0", "Lemon", "Kenshi Yonezu", "STRAY SHEEP", "4:17", "c"},
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

// 形状不对的记录、没有歌名的、NOTFOUND 都不认;名字里的换行压平。
func TestParseYTMusicQueueRejectsMalformed(t *testing.T) {
	if got := parseYTMusicQueue("NOTFOUND"); got != nil {
		t.Errorf("NOTFOUND 该返回空,得到 %+v", got)
	}
	items := parseYTMusicQueue(ytmusicQueueRaw(
		[]string{"0", "只有三段", "x"},
		[]string{"0", "", "无名", "专辑", "3:00", "v"},
		[]string{"0", "两行\n歌名", "甲", "专辑", "1:02:03", "w"},
	))
	if len(items) != 1 || items[0].title != "两行 歌名" || items[0].seconds != 3723 {
		t.Errorf("只该留下最后一条、换行压平、时长按时分秒算,得到 %+v", items)
	}
}

// 分发:Safari 报的是媒体代理进程(com.apple.WebKit.GPU),要换回 Safari 去跑探针;不能驱动的浏览器不跑。
func TestUpcomingFromQueueRoutesBrowsersToYTMusic(t *testing.T) {
	old := ytmusicQueueScript
	t.Cleanup(func() { ytmusicQueueScript = old })
	var asked []string
	ytmusicQueueScript = func(bundleID, family string) (string, bool) {
		asked = append(asked, bundleID+"/"+family)
		return ytmusicQueueRaw(
			[]string{"1", "Miree", "Suchmos", "THE BAY", "4:03", "a"},
			[]string{"0", "Lemon", "Kenshi Yonezu", "STRAY SHEEP", "4:17", "c"},
		), true
	}
	got, ok := upcomingFromQueue("Suchmos", "Miree", "THE BAY", "com.apple.WebKit.GPU", 0, 5)
	if !ok || len(got) != 1 || got[0].title != "Lemon" {
		t.Fatalf("Safari 播放该读到 YouTube Music 队列,得到 ok=%v %+v", ok, got)
	}
	if len(asked) != 1 || asked[0] != "com.apple.Safari/safari" {
		t.Errorf("该换回宿主 Safari、用 safari 方言,实际 %v", asked)
	}
	asked = nil
	if _, ok := upcomingFromQueue("Suchmos", "Miree", "THE BAY", "org.mozilla.firefox", 0, 5); ok || len(asked) != 0 {
		t.Errorf("驱动不了的浏览器不该跑探针,ok=%v asked=%v", ok, asked)
	}
}

// JS 要嵌进 AppleScript 的双引号字符串:不许有双引号,也不许有反斜杠(AppleScript 的转义字符)。
func TestYTMusicQueueJSSafeForAppleScript(t *testing.T) {
	if strings.Contains(ytmusicQueueJS, `"`) || strings.Contains(ytmusicQueueJS, `\`) {
		t.Fatal("ytmusicQueueJS 里不能有双引号或反斜杠")
	}
}

// 队列按账号语言本地化、名字对不上时:唯一那条 selected 的时长跟播放器报的相差 2s 内也认。
func TestYTMusicQueueCurrentFallsBackToSelectedDuration(t *testing.T) {
	items := parseYTMusicQueue(ytmusicQueueRaw(
		[]string{"0", "今天有没有", "陶喆", "乐之路", "4:02", "a"},
		[]string{"1", "飞机场的10.30", "陶喆", "乐之路", "4:41", "b"},
		[]string{"0", "Always Been You", "Jesse Gold", "Always Been You", "3:05", "c"},
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
	two := parseYTMusicQueue(ytmusicQueueRaw(
		[]string{"1", "飞机场的10.30", "陶喆", "乐之路", "4:41", "b"},
		[]string{"1", "别的", "陶喆", "乐之路", "4:41", "c"},
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
	ytmusicQueueScript = func(string, string) (string, bool) {
		calls++
		if calls == 1 {
			return ytmusicQueueRaw(
				[]string{"1", "Okay, Goodbye", "Fujii Kaze", "Prema", "4:00", "a"},
				[]string{"0", "Superwoman", "曹格", "格格blue", "5:13", "b"},
				[]string{"0", "Miree", "Suchmos", "THE BAY", "4:03", "c"},
			), true
		}
		return ytmusicQueueRaw(
			[]string{"0", "Okay, Goodbye", "Fujii Kaze", "Prema", "4:00", "a"},
			[]string{"1", "Superwoman", "曹格", "格格blue", "5:13", "b"},
			[]string{"0", "Miree", "Suchmos", "THE BAY", "4:03", "c"},
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
	ytmusicQueueScript = func(string, string) (string, bool) {
		calls++
		sel := map[bool]string{true: "1", false: "0"}
		return ytmusicQueueRaw(
			[]string{sel[calls == 1], "上一首", "甲", "专辑", "3:00", "a"},
			[]string{sel[calls > 1], "本地化的名字", "乙", "专辑", "4:41", "b"},
			[]string{"0", "下一首", "丙", "专辑", "3:10", "c"},
		), true
	}
	got, ok = browserUpcoming("B", "Localized", "com.apple.WebKit.GPU", 280.8, 5)
	if !ok || calls != 2 || len(got) != 1 || got[0].title != "下一首" {
		t.Fatalf("第一次对不上、第二次靠 selected+时长对上:该读 2 次并取到下一首,得到 ok=%v calls=%d %+v", ok, calls, got)
	}

	calls = 0
	ytmusicQueueScript = func(string, string) (string, bool) {
		calls++
		return ytmusicQueueRaw([]string{"1", "停着的另一首", "甲", "专辑", "3:00", "a"}, []string{"0", "x", "乙", "专辑", "3:00", "b"}), true
	}
	if _, ok := browserUpcoming("B", "Localized", "com.apple.WebKit.GPU", 280.8, 5); ok || calls != 2 {
		t.Fatalf("两次都对不上:该读 2 次后放弃,得到 ok=%v calls=%d", ok, calls)
	}

	calls = 0
	ytmusicQueueScript = func(string, string) (string, bool) { calls++; return "NOTFOUND", true }
	if _, ok := browserUpcoming("B", "Localized", "com.apple.WebKit.GPU", 280.8, 5); ok || calls != 1 {
		t.Fatalf("没有这个网站的标签页时不该重读,得到 ok=%v calls=%d", ok, calls)
	}
}
