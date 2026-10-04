package main

import (
	"strconv"
	"testing"
)

// spotifyWebQueue 造一份 App 交来的 Spotify 网页版队列:第一行是当前这首,每行 歌名、歌手、专辑、秒、uri。读页面、
// 认字段都在 App(selftest player-query 组)。
func spotifyWebQueue(rows ...[]string) appQueryTracks {
	var r appQueryTracks
	for i, f := range rows {
		secs, _ := strconv.ParseFloat(f[3], 64)
		t := appQueryTrack{Title: f[0], Artist: f[1], Album: f[2], Duration: secs, URI: f[4]}
		if i == 0 {
			r.Current = &t
			continue
		}
		r.Tracks = append(r.Tracks, t)
	}
	return r
}

// 实测形态:第一条是当前这首,之后按播放顺序;多位歌手用 ", " 连(跟网页版设 MediaSession 同一个分隔符)。
func TestSpotifyWebUpcomingReadsQueue(t *testing.T) {
	cur, next, ok := spotifyWebQueueFrom(spotifyWebQueue(
		[]string{"Boston", "STELLA LEFTY", "Boston", "170.859", "spotify:track:36idurZmYRjJ56KQ8JD9bN"},
		[]string{"Been By Now", "Morgan Wallen", "Been By Now", "213.805", "spotify:track:3xwMjQriBVW0OGEvNKo9c0"},
		[]string{"I Remember Everything (feat. Kacey Musgraves)", "Zach Bryan, Kacey Musgraves", "Zach Bryan", "227.195", "spotify:track:4KULAymBBJcPRpk1yO4dOG"},
	))
	if !ok || cur.title != "Boston" || len(next) != 2 {
		t.Fatalf("没认出来: ok=%v cur=%+v next=%d", ok, cur, len(next))
	}
	got, ok := pickSpotifyWebUpcoming(cur, next, "STELLA LEFTY", "Boston", 5)
	if !ok || len(got) != 2 {
		t.Fatalf("该取到后面 2 首,得到 ok=%v %+v", ok, got)
	}
	if got[1].artist != "Zach Bryan, Kacey Musgraves" || got[1].album != "Zach Bryan" || got[1].duration != 227.195 {
		t.Errorf("字段不对: %+v", got[1])
	}
	if got, _ := pickSpotifyWebUpcoming(cur, next, "STELLA LEFTY", "Boston", 1); len(got) != 1 || got[0].title != "Been By Now" {
		t.Errorf("n 要限住条数,按顺序取,得到 %+v", got)
	}
}

// 网页版的当前这首跟播放器报的对不上(Spotify 网页版停着、在放别的网站):不信它的队列。
func TestSpotifyWebUpcomingRejectsOtherCurrent(t *testing.T) {
	cur, next, _ := spotifyWebQueueFrom(spotifyWebQueue(
		[]string{"Boston", "STELLA LEFTY", "Boston", "170.859", "a"},
		[]string{"Been By Now", "Morgan Wallen", "Been By Now", "213.805", "b"},
	))
	if got, ok := pickSpotifyWebUpcoming(cur, next, "Suchmos", "Miree", 5); ok {
		t.Errorf("当前这首对不上,该退回同专辑预取,得到 %+v", got)
	}
}

// 没有当前这首(App 交来空的:NOTFOUND、当前这首解不开)不认;后面没有歌名或歌手的丢掉。
func TestSpotifyWebQueueFromNeedsCurrent(t *testing.T) {
	if _, _, ok := spotifyWebQueueFrom(appQueryTracks{}); ok {
		t.Error("空的不该认")
	}
	if _, _, ok := spotifyWebQueueFrom(appQueryTracks{Current: &appQueryTrack{Artist: "甲"}}); ok {
		t.Error("当前这首没有歌名,不该认")
	}
	_, next, ok := spotifyWebQueueFrom(spotifyWebQueue(
		[]string{"当前", "甲", "专辑", "1", "u0"},
		[]string{"没有歌手", "", "专辑", "1", "u2"},
		[]string{"", "没有歌名", "专辑", "1", "u3"},
		[]string{"好的", "乙", "专辑", "2", "u4"},
	))
	if !ok || len(next) != 1 || next[0].title != "好的" {
		t.Errorf("只该留下最后一条,得到 ok=%v %+v", ok, next)
	}
}

// 浏览器分支:YouTube Music 那边对不上时转给 Spotify 网页版;Safari 的媒体代理进程换回宿主。
func TestUpcomingFromQueueFallsThroughToSpotifyWeb(t *testing.T) {
	oldYT, oldSP := ytmusicQueueScript, spotifyWebQueueScript
	t.Cleanup(func() { ytmusicQueueScript, spotifyWebQueueScript = oldYT, oldSP })
	ytmusicQueueScript = func(string) (appQueryTracks, bool) {
		return ytmusicQueue([]string{"1", "Miree", "Suchmos", "THE BAY", "243", "a"}), true // 停着的另一个标签页
	}
	var asked string
	spotifyWebQueueScript = func(bundleID string) (appQueryTracks, bool) {
		asked = bundleID
		return spotifyWebQueue(
			[]string{"Boston", "STELLA LEFTY", "Boston", "170.859", "a"},
			[]string{"Been By Now", "Morgan Wallen", "Been By Now", "213.805", "b"},
		), true
	}
	got, ok := upcomingFromQueue("STELLA LEFTY", "Boston", "Boston", "com.apple.WebKit.GPU", 170.859, 5)
	if !ok || len(got) != 1 || got[0].title != "Been By Now" {
		t.Fatalf("该从 Spotify 网页版取到队列,得到 ok=%v %+v", ok, got)
	}
	if asked != "com.apple.Safari" {
		t.Errorf("该换回宿主 Safari,实际 %q", asked)
	}
}

// getQueue 快照过期时 App 那段 JS 改用 getState 的 item + nextItems:通常只有下一首,照样取。
func TestSpotifyWebUpcomingSingleNextFromState(t *testing.T) {
	cur, next, ok := spotifyWebQueueFrom(spotifyWebQueue(
		[]string{"Cowgirl", "Shaboozey", "Cowgirl", "175.764", "spotify:track:a"},
		[]string{"Bloodline", "Alex Warren, Jelly Roll", "Bloodline", "182.008", "spotify:track:b"},
	))
	if !ok {
		t.Fatal("没认出来")
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
	spotifyWebQueueScript = func(string) (appQueryTracks, bool) {
		return spotifyWebQueue([]string{"Cowgirl", "Shaboozey", "Cowgirl", "175.764", "spotify:track:a"}), true
	}
	if got := spotifyWebUpcoming("Shaboozey", "Cowgirl", "com.apple.WebKit.GPU", 5); got.status != browserQueueUnavailable {
		t.Fatalf("后面没有曲目,该判读不到(不是对不上),得到 %+v", got)
	}
	if !spotifyWebCurrentMatches(spotifyWebTrack{title: "Cowgirl", artist: "Shaboozey"}, "Shaboozey", "Cowgirl") {
		t.Fatal("同一首该判为对得上")
	}
}
