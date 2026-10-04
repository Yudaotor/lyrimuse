package main

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
	"time"
)

// playerQueryReplySample:shared/testdata/player-query/<name>.json 里 App 整理好的那份(reply),原样当 App 应答的 output。
func playerQueryReplySample(t *testing.T, name string) string {
	t.Helper()
	raw, err := os.ReadFile("../shared/testdata/player-query/" + name + ".json")
	if err != nil {
		t.Fatal(err)
	}
	var s struct {
		Reply json.RawMessage `json:"reply"`
	}
	if err := json.Unmarshal(raw, &s); err != nil || len(s.Reply) == 0 {
		t.Fatalf("样例 %s 读不出 reply: %v", name, err)
	}
	return string(s.Reply)
}

func playerQueryTracksSample(t *testing.T, name string) appQueryTracks {
	t.Helper()
	var r appQueryTracks
	if err := json.Unmarshal([]byte(playerQueryReplySample(t, name)), &r); err != nil {
		t.Fatal(err)
	}
	return r
}

func appQueryTracksJSON(t *testing.T, r appQueryTracks) string {
	t.Helper()
	b, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// 样例两侧共用:App 把原始输出整理成 reply(selftest player-query 组核对),这边拿同一份 reply 核对当前这首、往后取。
func TestPlayerQuerySamples(t *testing.T) {
	// Music 系统待播队列:没有名字的那一项跳过。
	got, ok := pickAppleMusicUpcoming(playerQueryTracksSample(t, "apple-music-queue"), "Michael Jackson", "You Are Not Alone", 5)
	want := []upcomingTrack{
		{artist: "Michael Jackson", title: "Come Together", album: "HIStory - PAST, PRESENT AND FUTURE - BOOK I", duration: 242.434},
		{artist: "PRINCE", title: "Bambi", album: "Prince", duration: 262},
		{artist: "陈奕迅", title: "富士山下", album: "What's Going On...?", duration: 259},
	}
	if !ok || !reflect.DeepEqual(got, want) {
		t.Errorf("系统待播队列: ok=%v %+v", ok, got)
	}

	// Music 当前列表往后几首:地区小数逗号的时长 App 已经换好;解不出时长的按不知道。
	got, ok = pickAppleMusicUpcoming(playerQueryTracksSample(t, "apple-music-upcoming"), "Michael Jackson", "Earth Song", 5)
	want = []upcomingTrack{
		{artist: "Michael Jackson", title: "You Are Not Alone", album: "HIStory Continues", duration: 344.825988769531},
		{artist: "Michael Jackson", title: "The Lost Children", album: "Invincible", duration: 240.533004760742},
		{artist: "Michael Jackson", title: "Speed Demon", album: "Bad"},
	}
	if !ok || !reflect.DeepEqual(got, want) {
		t.Errorf("当前列表往后几首: ok=%v %+v", ok, got)
	}

	// YouTube Music:从 selected 那首往后取;App 认出的 MV 交给预取的时长是「不知道」,跟真播到时一致。
	got, ok = pickYTMusicUpcoming(ytmusicQueueItems(playerQueryTracksSample(t, "youtube-music-queue")), "Suchmos", "Miree", 0, 5)
	want = []upcomingTrack{
		{artist: "BTS", title: "Dynamite"},
		{artist: "Harryan Yoonsoan", title: "Officially Missing You", album: "Harryan Yoonsoan Covers"},
		{artist: "甲", title: "两行 歌名", album: "专辑", duration: 3723},
		{artist: "Fujii Kaze", title: "Okay, Goodbye", album: "Prema", duration: 231},
	}
	if !ok || !reflect.DeepEqual(got, want) {
		t.Errorf("YouTube Music 队列: ok=%v %+v", ok, got)
	}

	// Spotify 网页版:当前这首对得上,后面没有歌手的丢掉。
	cur, next, ok := spotifyWebQueueFrom(playerQueryTracksSample(t, "spotify-web-queue"))
	if !ok {
		t.Fatal("Spotify 网页版队列: 该认出当前这首")
	}
	got, ok = pickSpotifyWebUpcoming(cur, next, "STELLA LEFTY", "Boston", 5)
	want = []upcomingTrack{
		{artist: "Morgan Wallen", title: "Been By Now", album: "Been By Now", duration: 213.805},
		{artist: "Zach Bryan, Kacey Musgraves", title: "I Remember Everything (feat. Kacey Musgraves)", album: "Zach Bryan", duration: 227.195},
	}
	if !ok || !reflect.DeepEqual(got, want) {
		t.Errorf("Spotify 网页版队列: ok=%v %+v", ok, got)
	}
}

// App 交来的不是这份形状(旧版 App 回的原始输出、半截 JSON):当查不到,调用方退回同专辑预取。
func TestAskAppTracksRejectsGarbage(t *testing.T) {
	for _, out := range []string{"Earth Song\tMichael Jackson\n", `{"tracks":`, "NOTFOUND"} {
		reqPath, repPath := useAppQueryChannel(t, true)
		fakePlayerQueryApp(t, reqPath, repPath, func(r appQueryRequest) *appQueryReply {
			return &appQueryReply{Schema: appQuerySchema, ID: r.ID, OK: true, Output: out}
		})
		if r, ok := askAppTracks(appQueryRequest{Kind: appQueryAppleMusicUpcoming, Count: 3}, time.Second); ok {
			t.Errorf("%q: 不该当成拿到了,得到 %+v", out, r)
		}
	}
}

// 专辑曲目表请 App 读:请求带专辑名,App 整理好的曲目表原样换成 albumTrack。
func TestAlbumTracksFromMusicApp(t *testing.T) {
	reply := playerQueryReplySample(t, "apple-music-album-tracks")
	reqPath, repPath := useAppQueryChannel(t, true)
	seen := fakePlayerQueryApp(t, reqPath, repPath, func(r appQueryRequest) *appQueryReply {
		return &appQueryReply{Schema: appQuerySchema, ID: r.ID, OK: true, Output: reply}
	})
	got, ok := albumTracksFromMusicApp("Bad")
	want := []albumTrack{
		{title: "Bad", artist: "Michael Jackson", duration: 247.16},
		{title: "The Way You Make Me Feel", artist: "Michael Jackson", duration: 298.426},
		{title: "Speed Demon", artist: "Michael Jackson"},
	}
	if !ok || !reflect.DeepEqual(got, want) {
		t.Fatalf("ok=%v %+v", ok, got)
	}
	if req := <-seen; req.Kind != appQueryAppleMusicAlbumTracks || req.Album != "Bad" {
		t.Fatalf("请求要是 %s、带专辑名: %+v", appQueryAppleMusicAlbumTracks, req)
	}
}

// Spotify 随机状态:App 交 {"shuffling":…};别的形状当问不到。
func TestSpotifyShufflingReadsTheAppsReply(t *testing.T) {
	for out, want := range map[string][2]bool{
		`{"shuffling":true}`:  {true, true},
		`{"shuffling":false}`: {false, true},
		`{}`:                  {false, false},
		"true":                {false, false},
	} {
		reqPath, repPath := useAppQueryChannel(t, true)
		fakePlayerQueryApp(t, reqPath, repPath, func(r appQueryRequest) *appQueryReply {
			return &appQueryReply{Schema: appQuerySchema, ID: r.ID, OK: true, Output: out}
		})
		if on, ok := spotifyShuffling(); on != want[0] || ok != want[1] {
			t.Errorf("%s: on=%v ok=%v, want %v", out, on, ok, want)
		}
	}
}
