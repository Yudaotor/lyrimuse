package main

import "testing"

// 系统待播队列请 App 读:请求是 apple_music_queue、带首数,App 整理好的那份在这边核对当前这首、往后取。
func TestAppleMusicUpcomingFromSystemQueue(t *testing.T) {
	reply := playerQueryReplySample(t, "apple-music-queue")
	reqPath, repPath := useAppQueryChannel(t, true)
	seen := fakePlayerQueryApp(t, reqPath, repPath, func(r appQueryRequest) *appQueryReply {
		return &appQueryReply{Schema: appQuerySchema, ID: r.ID, OK: true, Output: reply}
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
		return &appQueryReply{Schema: appQuerySchema, ID: r.ID, OK: false, Error: "queue unavailable"}
	})
	if _, ok := appleMusicUpcomingFromSystemQueue("Michael Jackson", "You Are Not Alone", 2); ok {
		t.Error("App 答失败不该取到")
	}
	useAppQueryChannel(t, false)
	if _, ok := appleMusicUpcomingFromSystemQueue("Michael Jackson", "You Are Not Alone", 2); ok {
		t.Error("App 不可用不该取到")
	}
}

// 系统队列读不到(加载器报 null,App 交来空的)、或者它的当前这首对不上:再请 App 跑那段 AppleScript,两次请求按这个顺序。
func TestAppleMusicUpcomingFallsBackToTheScript(t *testing.T) {
	script := appQueryTracksJSON(t, appQueryTracks{
		Current: &appQueryTrack{Title: "You Are Not Alone", Artist: "Michael Jackson"},
		Tracks:  []appQueryTrack{{Title: "Earth Song", Artist: "Michael Jackson", Album: "HIStory", Duration: 406.2}},
	})
	for name, queueOut := range map[string]string{
		"空的":      `{"tracks":[]}`,
		"当前这首对不上": `{"current":{"title":"Bad","artist":"Michael Jackson"},"tracks":[{"title":"Smooth Criminal","artist":"Michael Jackson"}]}`,
	} {
		reqPath, repPath := useAppQueryChannel(t, true)
		seen := fakePlayerQueryApp(t, reqPath, repPath, func(r appQueryRequest) *appQueryReply {
			out := script
			if r.Kind == appQueryAppleMusicQueue {
				out = queueOut
			}
			return &appQueryReply{Schema: appQuerySchema, ID: r.ID, OK: true, Output: out}
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
