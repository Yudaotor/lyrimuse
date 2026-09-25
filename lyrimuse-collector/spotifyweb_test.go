package main

import (
	"strings"
	"testing"
)

func spotifyWebRaw(rows ...[]string) string {
	recs := make([]string, 0, len(rows))
	for _, r := range rows {
		recs = append(recs, strings.Join(r, "\x1f"))
	}
	return strings.Join(recs, "\x1e")
}

// 实测形态:第一条是当前这首,之后按播放顺序;多位歌手用 ", " 连(跟网页版设 MediaSession 同一个分隔符)。
func TestSpotifyWebUpcomingReadsQueue(t *testing.T) {
	raw := spotifyWebRaw(
		[]string{"Boston", "STELLA LEFTY", "Boston", "170859", "spotify:track:36idurZmYRjJ56KQ8JD9bN"},
		[]string{"Been By Now", "Morgan Wallen", "Been By Now", "213805", "spotify:track:3xwMjQriBVW0OGEvNKo9c0"},
		[]string{"I Remember Everything (feat. Kacey Musgraves)", "Zach Bryan, Kacey Musgraves", "Zach Bryan", "227195", "spotify:track:4KULAymBBJcPRpk1yO4dOG"},
	)
	cur, next, ok := parseSpotifyWebQueue(raw + "\n")
	if !ok || cur.title != "Boston" || len(next) != 2 {
		t.Fatalf("解析失败: ok=%v cur=%+v next=%d", ok, cur, len(next))
	}
	got, ok := pickSpotifyWebUpcoming(cur, next, "STELLA LEFTY", "Boston", 5)
	if !ok || len(got) != 2 {
		t.Fatalf("该取到后面 2 首,得到 ok=%v %+v", ok, got)
	}
	if got[1].artist != "Zach Bryan, Kacey Musgraves" || got[1].album != "Zach Bryan" || got[1].duration != 227.195 {
		t.Errorf("字段解错: %+v", got[1])
	}
	if got, _ := pickSpotifyWebUpcoming(cur, next, "STELLA LEFTY", "Boston", 1); len(got) != 1 || got[0].title != "Been By Now" {
		t.Errorf("n 要限住条数,按顺序取,得到 %+v", got)
	}
}

// 网页版的当前这首跟播放器报的对不上(Spotify 网页版停着、在放别的网站):不信它的队列。
func TestSpotifyWebUpcomingRejectsOtherCurrent(t *testing.T) {
	cur, next, _ := parseSpotifyWebQueue(spotifyWebRaw(
		[]string{"Boston", "STELLA LEFTY", "Boston", "170859", "a"},
		[]string{"Been By Now", "Morgan Wallen", "Been By Now", "213805", "b"},
	))
	if got, ok := pickSpotifyWebUpcoming(cur, next, "Suchmos", "Miree", 5); ok {
		t.Errorf("当前这首对不上,该退回同专辑预取,得到 %+v", got)
	}
}

// 形状不对:当前这首都解不开就整份不信;后面坏掉的单条跳过;NOTFOUND 不认。
func TestParseSpotifyWebQueueRejectsMalformed(t *testing.T) {
	if _, _, ok := parseSpotifyWebQueue("NOTFOUND"); ok {
		t.Error("NOTFOUND 不该认")
	}
	if _, _, ok := parseSpotifyWebQueue(spotifyWebRaw([]string{"只有两段", "x"})); ok {
		t.Error("当前这首解不开,整份不该认")
	}
	_, next, ok := parseSpotifyWebQueue(spotifyWebRaw(
		[]string{"当前", "甲", "专辑", "1000", "u0"},
		[]string{"坏的"},
		[]string{"没有歌手", "", "专辑", "1000", "u2"},
		[]string{"好的", "乙", "专辑", "2000", "u3"},
	))
	if !ok || len(next) != 1 || next[0].title != "好的" {
		t.Errorf("只该留下最后一条,得到 ok=%v %+v", ok, next)
	}
}

// 浏览器分支:YouTube Music 那边对不上时转给 Spotify 网页版;Safari 的媒体代理进程换回宿主。
func TestUpcomingFromQueueFallsThroughToSpotifyWeb(t *testing.T) {
	oldYT, oldSP := ytmusicQueueScript, spotifyWebQueueScript
	t.Cleanup(func() { ytmusicQueueScript, spotifyWebQueueScript = oldYT, oldSP })
	ytmusicQueueScript = func(string, string) (string, bool) {
		return ytmusicQueueRaw([]string{"1", "Miree", "Suchmos", "THE BAY", "4:03", "a"}), true // 停着的另一个标签页
	}
	var asked string
	spotifyWebQueueScript = func(bundleID, family string) (string, bool) {
		asked = bundleID + "/" + family
		return spotifyWebRaw(
			[]string{"Boston", "STELLA LEFTY", "Boston", "170859", "a"},
			[]string{"Been By Now", "Morgan Wallen", "Been By Now", "213805", "b"},
		), true
	}
	got, ok := upcomingFromQueue("STELLA LEFTY", "Boston", "Boston", "com.apple.WebKit.GPU", 170.859, 5)
	if !ok || len(got) != 1 || got[0].title != "Been By Now" {
		t.Fatalf("该从 Spotify 网页版取到队列,得到 ok=%v %+v", ok, got)
	}
	if asked != "com.apple.Safari/safari" {
		t.Errorf("该换回宿主 Safari,实际 %q", asked)
	}
}

func TestSpotifyWebQueueJSSafeForAppleScript(t *testing.T) {
	if strings.Contains(spotifyWebQueueJS, `"`) || strings.Contains(spotifyWebQueueJS, `\`) {
		t.Fatal("spotifyWebQueueJS 里不能有双引号或反斜杠")
	}
}

// 歌名里的双引号原样保留(Safari);Chromium 系整段包一层引号、里面转义过的,剥掉外层并还原。
func TestUnwrapBrowserScriptOutputKeepsQuotesInNames(t *testing.T) {
	rec := spotifyWebRaw([]string{`"Heroes"`, "David Bowie", `"Heroes"`, "371000", "u"})
	if got := unwrapBrowserScriptOutput(rec + "\n"); !strings.HasPrefix(got, `"Heroes"`) {
		t.Errorf("以引号开头的歌名不该被削掉,得到 %q", got)
	}
	wrapped := `"` + strings.ReplaceAll(spotifyWebRaw([]string{`I Knew It - From "Toy Story 5"`, "Taylor Swift", "x", "1000", "u"}), `"`, `\"`) + `"`
	cur, _, ok := parseSpotifyWebQueue(wrapped)
	if !ok || cur.title != `I Knew It - From "Toy Story 5"` {
		t.Errorf("包了一层的该还原,得到 ok=%v %q", ok, cur.title)
	}
}

// getQueue 快照过期时脚本改用 getState 的 item + nextItems:通常只有下一首,照样取。
func TestSpotifyWebUpcomingSingleNextFromState(t *testing.T) {
	cur, next, ok := parseSpotifyWebQueue(spotifyWebRaw(
		[]string{"Cowgirl", "Shaboozey", "Cowgirl", "175764", "spotify:track:a"},
		[]string{"Bloodline", "Alex Warren, Jelly Roll", "Bloodline", "182008", "spotify:track:b"},
	))
	if !ok {
		t.Fatal("解析失败")
	}
	got, ok := pickSpotifyWebUpcoming(cur, next, "Shaboozey", "Cowgirl", 5)
	if !ok || len(got) != 1 || got[0].title != "Bloodline" || got[0].artist != "Alex Warren, Jelly Roll" {
		t.Fatalf("该取到下一首,得到 ok=%v %+v", ok, got)
	}
}

// 当前这首对得上、后面没有曲目:退回同专辑预取,且不当成"对不上"。
func TestSpotifyWebUpcomingMatchedButNothingNext(t *testing.T) {
	old := spotifyWebQueueScript
	t.Cleanup(func() { spotifyWebQueueScript = old })
	spotifyWebQueueScript = func(string, string) (string, bool) {
		return spotifyWebRaw([]string{"Cowgirl", "Shaboozey", "Cowgirl", "175764", "spotify:track:a"}), true
	}
	if got := spotifyWebUpcoming("Shaboozey", "Cowgirl", "com.apple.WebKit.GPU", 5); got.status != browserQueueUnavailable {
		t.Fatalf("后面没有曲目,该判读不到(不是对不上),得到 %+v", got)
	}
	if !spotifyWebCurrentMatches(spotifyWebTrack{title: "Cowgirl", artist: "Shaboozey"}, "Shaboozey", "Cowgirl") {
		t.Fatal("同一首该判为对得上")
	}
}
