package main

import (
	"context"
	"errors"
	"testing"
)

// 形状照搬加载器真机输出:第一项是当前这首,之后是打乱后的真实顺序(跨专辑、跨歌手)。
const testAppleMusicQueueJSON = `{"items":[
{"duration":344.87,"title":"You Are Not Alone","album":"HIStory - PAST, PRESENT AND FUTURE - BOOK I","identifier":"13235::13257","artist":"Michael Jackson"},
{"duration":242.434,"title":"Come Together","album":"HIStory - PAST, PRESENT AND FUTURE - BOOK I","identifier":"13235::13261","artist":"Michael Jackson"},
{"duration":262,"title":"Bambi","album":"Prince","identifier":"13235::13279","artist":"PRINCE"},
{"title":"","artist":"没有名字的一项"},
{"duration":259,"title":"富士山下","album":"What's Going On...?","identifier":"13235::13267","artist":"陈奕迅"}]}`

func TestParseAppleMusicSystemQueue(t *testing.T) {
	got, ok := parseAppleMusicSystemQueue([]byte(testAppleMusicQueueJSON), "Michael Jackson", "You Are Not Alone", 5)
	if !ok {
		t.Fatal("当前这首对得上,该取到")
	}
	want := []upcomingTrack{
		{artist: "Michael Jackson", title: "Come Together", album: "HIStory - PAST, PRESENT AND FUTURE - BOOK I", duration: 242.434},
		{artist: "PRINCE", title: "Bambi", album: "Prince", duration: 262},
		{artist: "陈奕迅", title: "富士山下", album: "What's Going On...?", duration: 259},
	}
	if len(got) != len(want) {
		t.Fatalf("得到 %+v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("第 %d 首得到 %+v,期望 %+v", i, got[i], want[i])
		}
	}
	if got, _ := parseAppleMusicSystemQueue([]byte(testAppleMusicQueueJSON), "Michael Jackson", "You Are Not Alone", 1); len(got) != 1 {
		t.Errorf("只要 1 首就只给 1 首,得到 %d", len(got))
	}
}

// 队列里的当前这首跟此刻在播的对不上、只有当前这一首、输出不是 JSON(加载器报 null):都不算数。
func TestParseAppleMusicSystemQueueRejects(t *testing.T) {
	for name, tc := range map[string]struct{ out, artist, title string }{
		"当前这首对不上": {testAppleMusicQueueJSON, "Michael Jackson", "Bad"},
		"只有当前这首":  {`{"items":[{"title":"Bad","artist":"Michael Jackson"}]}`, "Michael Jackson", "Bad"},
		"null":    {"null\n", "Michael Jackson", "Bad"},
		"垃圾":      {"not json", "Michael Jackson", "Bad"},
	} {
		if got, ok := parseAppleMusicSystemQueue([]byte(tc.out), tc.artist, tc.title, 5); ok {
			t.Errorf("%s: 不该取到,得到 %+v", name, got)
		}
	}
}

// 找得到加载器就用它;跑失败返回 ok=false(由 appleMusicUpcoming 退回 AppleScript)。
func TestAppleMusicUpcomingFromSystemQueue(t *testing.T) {
	oldPaths, oldRun := nowPlayingClientsPathsOverride, appleMusicQueueRun
	t.Cleanup(func() { nowPlayingClientsPathsOverride, appleMusicQueueRun = oldPaths, oldRun })
	nowPlayingClientsPathsOverride = func() (string, string) { return "/x/loader.pl", "/x/lib.dylib" }
	var gotN int
	appleMusicQueueRun = func(_ context.Context, script, lib string, n int) ([]byte, error) {
		gotN = n
		return []byte(testAppleMusicQueueJSON), nil
	}
	if got, ok := appleMusicUpcomingFromSystemQueue("Michael Jackson", "You Are Not Alone", 2); !ok || len(got) != 2 || gotN != 2 {
		t.Fatalf("ok=%v n=%d 得到 %+v", ok, gotN, got)
	}
	appleMusicQueueRun = func(context.Context, string, string, int) ([]byte, error) { return nil, errors.New("boom") }
	if _, ok := appleMusicUpcomingFromSystemQueue("Michael Jackson", "You Are Not Alone", 2); ok {
		t.Error("加载器跑失败不该取到")
	}
	nowPlayingClientsPathsOverride = func() (string, string) { return "", "" }
	appleMusicQueueRun = func(context.Context, string, string, int) ([]byte, error) {
		t.Error("找不到加载器就不该去跑")
		return nil, nil
	}
	if _, ok := appleMusicUpcomingFromSystemQueue("Michael Jackson", "You Are Not Alone", 2); ok {
		t.Error("找不到加载器不该取到")
	}
}
