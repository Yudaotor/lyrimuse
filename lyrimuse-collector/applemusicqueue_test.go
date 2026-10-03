package main

import (
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

// 系统待播队列请 App 读:请求是 apple_music_queue、带首数,App 原样回的输出在这边解析。
func TestAppleMusicUpcomingFromSystemQueue(t *testing.T) {
	reqPath, repPath := useAppQueryChannel(t, true)
	seen := fakePlayerQueryApp(t, reqPath, repPath, func(r appQueryRequest) *appQueryReply {
		return &appQueryReply{Schema: 1, ID: r.ID, OK: true, Output: testAppleMusicQueueJSON}
	})
	if got, ok := appleMusicUpcomingFromSystemQueue("Michael Jackson", "You Are Not Alone", 2); !ok || len(got) != 2 {
		t.Fatalf("ok=%v 得到 %+v", ok, got)
	}
	if req := <-seen; req.Kind != appQueryAppleMusicQueue || req.Count != 2 {
		t.Fatalf("请求要是 %s、带首数 2: %+v", appQueryAppleMusicQueue, req)
	}

	// App 答失败(加载器不在包里、跑失败)、或此刻不可用:ok=false。
	reqPath, repPath = useAppQueryChannel(t, true)
	fakePlayerQueryApp(t, reqPath, repPath, func(r appQueryRequest) *appQueryReply {
		return &appQueryReply{Schema: 1, ID: r.ID, OK: false, Error: "queue unavailable"}
	})
	if _, ok := appleMusicUpcomingFromSystemQueue("Michael Jackson", "You Are Not Alone", 2); ok {
		t.Error("App 答失败不该取到")
	}
	useAppQueryChannel(t, false)
	if _, ok := appleMusicUpcomingFromSystemQueue("Michael Jackson", "You Are Not Alone", 2); ok {
		t.Error("App 不可用不该取到")
	}
}

// 系统队列读不到(加载器报 null)、或者它的当前这首对不上:再请 App 跑那段 AppleScript,两次请求按这个顺序。
func TestAppleMusicUpcomingFallsBackToTheScript(t *testing.T) {
	script := "You Are Not Alone\tMichael Jackson\nEarth Song\tMichael Jackson\tHIStory\t406.2\n"
	for name, queueOut := range map[string]string{
		"null":    "null\n",
		"当前这首对不上": `{"items":[{"title":"Bad","artist":"Michael Jackson"},{"title":"Smooth Criminal","artist":"Michael Jackson"}]}`,
	} {
		reqPath, repPath := useAppQueryChannel(t, true)
		seen := fakePlayerQueryApp(t, reqPath, repPath, func(r appQueryRequest) *appQueryReply {
			out := script
			if r.Kind == appQueryAppleMusicQueue {
				out = queueOut
			}
			return &appQueryReply{Schema: 1, ID: r.ID, OK: true, Output: out}
		})
		got, ok := appleMusicUpcoming("Michael Jackson", "You Are Not Alone", 3)
		if !ok || len(got) != 1 || got[0].title != "Earth Song" || got[0].duration != 406.2 {
			t.Fatalf("%s: 应退回 AppleScript 那份: ok=%v %+v", name, ok, got)
		}
		if first, second := <-seen, <-seen; first.Kind != appQueryAppleMusicQueue || second.Kind != appQueryAppleMusicUpcoming {
			t.Fatalf("%s: 先问系统队列、再问 AppleScript: %s, %s", name, first.Kind, second.Kind)
		}
	}
}
