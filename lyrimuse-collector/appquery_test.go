package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// useAppQueryChannel 把请求 / 应答文件指到临时目录,轮询调到 5 毫秒;收尾还原。
func useAppQueryChannel(t *testing.T, ready bool) (reqPath, repPath string) {
	t.Helper()
	dir := t.TempDir()
	reqPath, repPath = filepath.Join(dir, "request.json"), filepath.Join(dir, "reply.json")
	oldPoll := appQueryPoll
	appQueryPoll = 5 * time.Millisecond
	setAppQueryChannel(reqPath, repPath, func() bool { return ready })
	t.Cleanup(func() {
		appQueryPoll = oldPoll
		setAppQueryChannel("", "", nil)
	})
	return reqPath, repPath
}

// fakePlayerQueryApp 扮演 App:看到请求就按 answer 写应答(answer 返回 nil = 不答)。
func fakePlayerQueryApp(t *testing.T, reqPath, repPath string, answer func(appQueryRequest) *appQueryReply) <-chan appQueryRequest {
	t.Helper()
	seen := make(chan appQueryRequest, 4)
	done := make(chan struct{})
	t.Cleanup(func() { close(done) })
	go func() {
		handled := ""
		for {
			select {
			case <-done:
				return
			case <-time.After(2 * time.Millisecond):
			}
			raw, err := os.ReadFile(reqPath)
			if err != nil {
				continue
			}
			var req appQueryRequest
			if json.Unmarshal(raw, &req) != nil || req.ID == handled {
				continue
			}
			handled = req.ID
			seen <- req
			if rep := answer(req); rep != nil {
				data, _ := json.Marshal(rep)
				_ = writeFileAtomic(repPath, data)
			}
		}
	}()
	return seen
}

func TestAskAppRoundTrip(t *testing.T) {
	reqPath, repPath := useAppQueryChannel(t, true)
	seen := fakePlayerQueryApp(t, reqPath, repPath, func(r appQueryRequest) *appQueryReply {
		return &appQueryReply{Schema: 1, ID: r.ID, OK: true, Output: "true\n"}
	})
	out, ok := askApp(appQueryRequest{Kind: appQuerySpotifyShuffle}, time.Second)
	if !ok || out != "true\n" {
		t.Fatalf("应拿到 App 的原始输出: ok=%v out=%q", ok, out)
	}
	req := <-seen
	if req.Schema != appQuerySchema || req.Kind != appQuerySpotifyShuffle || req.ID == "" || req.WrittenAtMs == 0 {
		t.Fatalf("请求要带契约版本、种类、id、写出时刻: %+v", req)
	}
	raw, _ := os.ReadFile(reqPath)
	for _, key := range []string{`"schema"`, `"id"`, `"kind"`, `"written_at_ms"`} {
		if !strings.Contains(string(raw), key) {
			t.Errorf("请求里少了键 %s: %s", key, raw)
		}
	}

	// 浏览器那种带 bundle id 与平台,键名是 App 认的那两个。
	if _, ok := askApp(appQueryRequest{Kind: appQueryBrowserQueue, BundleID: "com.apple.Safari", Platform: browserPlatformYouTubeMusic}, time.Second); !ok {
		t.Fatal("网页队列查询应拿到应答")
	}
	raw, _ = os.ReadFile(reqPath)
	if !strings.Contains(string(raw), `"bundle_id":"com.apple.Safari"`) || !strings.Contains(string(raw), `"platform":"youtubeMusic"`) {
		t.Errorf("网页队列请求的键名不对: %s", raw)
	}
}

// 应答文件里留着的是别的请求的(上一次的、别人的),不认,等到超时。
func TestAskAppIgnoresOtherReplies(t *testing.T) {
	reqPath, repPath := useAppQueryChannel(t, true)
	fakePlayerQueryApp(t, reqPath, repPath, func(r appQueryRequest) *appQueryReply {
		return &appQueryReply{Schema: 1, ID: r.ID + "-other", OK: true, Output: "stale"}
	})
	if out, ok := askApp(appQueryRequest{Kind: appQuerySpotifyShuffle}, 100*time.Millisecond); ok || out != "" {
		t.Fatalf("id 对不上的应答不认: ok=%v out=%q", ok, out)
	}
}

// App 回报没跑成(参数不对、浏览器没配对、脚本失败):当查不到。
func TestAskAppFailureReply(t *testing.T) {
	reqPath, repPath := useAppQueryChannel(t, true)
	fakePlayerQueryApp(t, reqPath, repPath, func(r appQueryRequest) *appQueryReply {
		return &appQueryReply{Schema: 1, ID: r.ID, OK: false, Error: "browser not paired"}
	})
	if _, ok := askApp(appQueryRequest{Kind: appQueryBrowserQueue, BundleID: "com.google.Chrome", Platform: browserPlatformSpotifyWeb}, time.Second); ok {
		t.Fatal("App 答失败时应当查不到")
	}
}

// App 不可用、或者根本没登记通道(CLI 子命令):不写请求,当场返回。
func TestAskAppWhenAppUnavailable(t *testing.T) {
	reqPath, _ := useAppQueryChannel(t, false)
	if _, ok := askApp(appQueryRequest{Kind: appQuerySpotifyShuffle}, time.Second); ok {
		t.Fatal("App 不可用时不该有结果")
	}
	if _, err := os.Stat(reqPath); !os.IsNotExist(err) {
		t.Fatal("App 不可用时不该写请求")
	}
	setAppQueryChannel("", "", nil)
	if _, ok := askApp(appQueryRequest{Kind: appQuerySpotifyShuffle}, time.Second); ok {
		t.Fatal("没登记通道时不该有结果")
	}
}

// 几段脚本只在 App 里(PlayerQueryServer.swift),输出由这边解析:文件名、键名、种类、守卫与字段顺序两边一起改。
func TestAppQueryContractMatchesTheApp(t *testing.T) {
	raw, err := os.ReadFile("../lyrimuse/Sources/LyrimuseCore/Local/PlayerQueryServer.swift")
	if err != nil {
		t.Fatal(err)
	}
	src := string(raw)
	for _, want := range []string{
		`"lyrimuse-player-query-request.json"`, `"lyrimuse-player-query-reply.json"`,
		`"` + appQueryAppleMusicUpcoming + `"`, `"` + appQueryAppleMusicAlbumTracks + `"`,
		`"` + appQuerySpotifyShuffle + `"`, `"` + appQueryBrowserQueue + `"`,
		`case bundleID = "bundle_id"`, `case writtenAtMs = "written_at_ms"`,
		`case "` + browserPlatformYouTubeMusic + `"`, `case "` + browserPlatformSpotifyWeb + `"`,
		// Music 待播:三道守卫 + 云端内容读不到时的兜底;第一行是当前这首(parseAppleMusicUpcoming 靠它核对)。
		`if application "Music" is not running then`, `if player state is stopped then return ""`,
		`if shuffle enabled then return ""`, `on error`,
		`set output to (name of t) & tab & (artist of t) & linefeed`,
		`(name of tk) & tab & (artist of tk) & tab & (album of tk) & tab & (duration of tk) & linefeed`,
		// 专辑曲目:只收 song,每行 名 / 歌手 / 时长(parseMusicAppAlbumTracks)。
		`and media kind is song`, `(name of t) & tab & (artist of t) & tab & (duration of t) & linefeed`,
		`if application "Spotify" is running then tell application "Spotify" to return shuffling`,
		// 网页队列:记录与字段的分隔符、每条记录的字段顺序(parseYTMusicQueue / parseSpotifyWebQueue)。
		`String.fromCharCode(31), RS = String.fromCharCode(30);`,
		`out.push([sel, text(d.title), artist.join(''), album, text(d.lengthText), String(d.videoId || ''), vt].join(US));`,
		`return [String(t.name || ''), arts, String((t.album && t.album.name) || ''), String((t.duration && t.duration.milliseconds) || 0), String(t.uri || '')].join(US); };`,
		`watchEndpointMusicConfig`,
	} {
		if !strings.Contains(src, want) {
			t.Errorf("PlayerQueryServer.swift 里找不到 %q", want)
		}
	}
	// App 跑脚本的超时要比这边等的短,否则 App 还在跑这边已经放弃。
	for _, want := range []string{"public static let scriptTimeout: TimeInterval = 6", "public static let shuffleTimeout: TimeInterval = 2"} {
		if !strings.Contains(src, want) {
			t.Errorf("App 侧超时变了,同步检查 appQueryScriptTimeout / appQueryShuffleTimeout: 找不到 %q", want)
		}
	}
	if appQueryScriptTimeout <= 6*time.Second || appQueryShuffleTimeout <= 2*time.Second {
		t.Error("这边等应答的时间要比 App 跑脚本的超时长")
	}
}
