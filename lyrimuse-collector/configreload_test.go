package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"
)

var configTestClock int

// resetLiveConfigForTest 撤掉热重读登记,测试结束时还原成未登记(CLI / 其它测试的形态)。
func resetLiveConfigForTest(t *testing.T) {
	t.Helper()
	setLiveConfig("", nil)
	t.Cleanup(func() {
		setLiveConfig("", nil)
		configCheckedAt.Store(0)
	})
}

// writeConfigForTest 写一份 config.json,并把探盘节流拨到"已经过期",下一次 liveConfig() 就会探盘。
func writeConfigForTest(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	// 同一秒里连写两次时 mtime 可能不变,size 也可能碰巧一样:每次把 mtime 往后多拨一秒,确保判得出"变了"。
	configTestClock++
	future := time.Now().Add(time.Duration(configTestClock) * time.Second)
	if err := os.Chtimes(path, future, future); err != nil {
		t.Fatal(err)
	}
	configCheckedAt.Store(time.Now().Add(-2 * configReloadInterval).UnixNano())
}

func startLiveConfigForTest(t *testing.T, body string) string {
	t.Helper()
	resetLiveConfigForTest(t)
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	setLiveConfig(path, cfg)
	return path
}

func TestLiveConfigNilWithoutRegistration(t *testing.T) {
	resetLiveConfigForTest(t)
	if liveConfig() != nil {
		t.Fatal("没登记路径(CLI 子命令的形态)时 liveConfig() 应返回 nil")
	}
}

func TestLiveConfigPicksUpChanges(t *testing.T) {
	path := startLiveConfigForTest(t, `{"listenbrainz_token":"old","bark_url":"https://api.day.app/a"}`)
	if got := liveConfig().Token; got != "old" {
		t.Fatalf("起始值不对 got %q", got)
	}
	writeConfigForTest(t, path, `{"listenbrainz_token":"new-token","bark_url":"https://api.day.app/a","notification_platform":"telegram"}`)
	got := liveConfig()
	if got.Token != "new-token" || got.NotificationPlatform != "telegram" {
		t.Errorf("改完没读到新值 token=%q platform=%q", got.Token, got.NotificationPlatform)
	}
	if got.APIRoot != "https://api.listenbrainz.org" {
		t.Errorf("热重读要跟启动时一样补默认值,api_root=%q", got.APIRoot)
	}
}

func TestLiveConfigKeepsCurrentOnBrokenJSON(t *testing.T) {
	path := startLiveConfigForTest(t, `{"listenbrainz_token":"keep-me"}`)
	writeConfigForTest(t, path, `{"listenbrainz_token":"half`)
	if got := liveConfig().Token; got != "keep-me" {
		t.Errorf("整份 JSON 坏了不该把配置清空,got %q", got)
	}
}

func TestLiveConfigKeepsCurrentWhenFileRemoved(t *testing.T) {
	path := startLiveConfigForTest(t, `{"listenbrainz_token":"keep-me"}`)
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	configCheckedAt.Store(time.Now().Add(-2 * configReloadInterval).UnixNano())
	if got := liveConfig().Token; got != "keep-me" {
		t.Errorf("文件被删掉不该把配置清空,got %q", got)
	}
}

func TestChangedConfigKeysListsNamesOnly(t *testing.T) {
	a := &config{Token: "t1", NotificationWebhookURL: "https://x/1"}
	b := &config{Token: "t2", NotificationWebhookURL: "https://x/1", TelegramChatID: "42"}
	got := changedConfigKeys(a, b)
	sort.Strings(got)
	if strings.Join(got, ",") != "listenbrainz_token,telegram_chat_id" {
		t.Errorf("changed = %v", got)
	}
}

// LB 提交跑在各自的 goroutine 里,地址和令牌必须现读热重读后的那份,不能用构造时的字段。
func TestLBClientFollowsLiveConfig(t *testing.T) {
	var mu sync.Mutex
	var gotAuth []string
	hit := func(name string) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			mu.Lock()
			gotAuth = append(gotAuth, name+" "+r.Header.Get("Authorization"))
			mu.Unlock()
			w.WriteHeader(http.StatusOK)
		}
	}
	oldSrv := httptest.NewServer(hit("old"))
	defer oldSrv.Close()
	newSrv := httptest.NewServer(hit("new"))
	defer newSrv.Close()

	path := startLiveConfigForTest(t, `{"listenbrainz_token":"t-old","api_root":"`+oldSrv.URL+`"}`)
	c := &lbClient{root: oldSrv.URL, token: "t-old", hc: &http.Client{}}
	meta := lbTrackMeta{ArtistName: "A", TrackName: "T", AdditionalInfo: map[string]any{}}
	if err := c.submit(context.Background(), "playing_now", 0, meta); err != nil {
		t.Fatal(err)
	}
	writeConfigForTest(t, path, `{"listenbrainz_token":"t-new","api_root":"`+newSrv.URL+`"}`)
	if err := c.submit(context.Background(), "playing_now", 0, meta); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(gotAuth) != 2 || gotAuth[0] != "old Token t-old" || gotAuth[1] != "new Token t-new" {
		t.Errorf("requests = %v", gotAuth)
	}
}

// 推送通道:相关字段变了才重建;别的字段变了沿用原来那个。
func TestSyncLiveConfigRebuildsAlerter(t *testing.T) {
	resetFeaturesForTest(t)
	setFeatures(featureFlags{})
	path := startLiveConfigForTest(t, `{"notification_platform":"bark","bark_url":"https://api.day.app/k"}`)
	start := liveConfig()
	p := &poller{cfg: start, lb: &lbClient{alerter: alerterFromConfig(start)}, lfmKey: lastfmScrobblerKeyOf(start)}

	writeConfigForTest(t, path, `{"notification_platform":"bark","bark_url":"https://api.day.app/k","listenbrainz_user":"u"}`)
	before := p.lb.alerter
	p.syncLiveConfig()
	if p.cfg.User != "u" {
		t.Fatalf("poller 没换上新快照 user=%q", p.cfg.User)
	}
	if p.lb.alerter != before {
		t.Error("推送字段没变,不该重建 alerter")
	}

	writeConfigForTest(t, path, `{"notification_platform":"telegram","bark_url":"123:abc","telegram_chat_id":"42","listenbrainz_user":"u"}`)
	p.syncLiveConfig()
	a := p.lb.alerter
	if a == before || a.platform != platformTelegram || a.url != "123:abc" || a.telegramChatID != "42" {
		t.Errorf("换了平台 / 地址 / Chat ID 应重建 alerter,got %+v", a)
	}
}

// Last.fm 镜像写入:凭据或 lastfm_mirror_scrobble 开关变了才重建;都没变时沿用原来那个(它身上有
// 「凭据已判死」这类状态)。
func TestSyncLiveConfigRebuildsLastfmWriter(t *testing.T) {
	resetFeaturesForTest(t)
	setFeatures(featureFlags{})
	creds := `"lastfm_scrobble_api_key":"k","lastfm_scrobble_secret":"s","lastfm_scrobble_session_key":"sk"`
	path := startLiveConfigForTest(t, `{`+creds+`}`)
	start := liveConfig()
	p := &poller{cfg: start, lb: &lbClient{}, lfm: lastfmScrobblerIfEnabled(start), lfmKey: lastfmScrobblerKeyOf(start)}
	if p.lfm != nil {
		t.Fatal("开关关着时不该有 writer")
	}

	setFeatures(featureFlags{LastfmMirrorScrobble: true})
	p.syncLiveConfig()
	if p.lfm == nil {
		t.Fatal("打开 lastfm_mirror_scrobble 后应建出 writer(不用重启)")
	}
	first := p.lfm

	writeConfigForTest(t, path, `{`+creds+`,"listenbrainz_user":"u"}`)
	p.syncLiveConfig()
	if p.lfm != first {
		t.Error("Last.fm 凭据没变,不该重建 writer")
	}

	writeConfigForTest(t, path, `{"lastfm_scrobble_api_key":"k","lastfm_scrobble_secret":"s","lastfm_scrobble_session_key":"sk2"}`)
	p.syncLiveConfig()
	if p.lfm == first || p.lfm == nil || p.lfm.sk != "sk2" {
		t.Error("session key 换了应重建 writer")
	}

	setFeatures(featureFlags{})
	p.syncLiveConfig()
	if p.lfm != nil {
		t.Error("关掉 lastfm_mirror_scrobble 后 writer 应撤掉")
	}
}

// 换中继地址:旧中继的「已上传」记录全部作废;只换令牌时保留。
func TestSwitchStateRelayResetsConfirmations(t *testing.T) {
	savedURL, savedToken := artworkRelayTarget()
	t.Cleanup(func() { setStateRelay(savedURL, savedToken) })
	savedPath := artworkConfirmPath
	artworkConfirmPath = ""
	t.Cleanup(func() { artworkConfirmPath = savedPath })

	setStateRelay("https://relay-a.example", "t1")
	artworkMu.Lock()
	artworkUploaded["abc"] = true
	artworkMu.Unlock()

	switchStateRelay("https://relay-a.example/", "t2")
	artworkMu.Lock()
	kept := artworkUploaded["abc"]
	artworkMu.Unlock()
	if !kept {
		t.Error("只换令牌(地址只差尾部斜杠)不该作废上传记录")
	}
	if _, tok := artworkRelayTarget(); tok != "t2" {
		t.Errorf("令牌没换上 got %q", tok)
	}

	switchStateRelay("https://relay-b.example", "t2")
	artworkMu.Lock()
	kept = artworkUploaded["abc"]
	artworkMu.Unlock()
	if kept {
		t.Error("换了中继地址,旧中继的上传记录应作废")
	}
	if !webRelayConfigured() {
		t.Error("网页取色的中继开关应跟着地址走")
	}
}

// 常驻路径上,main() 读 cfg 字段的地方只有这些:它们要么只在启动时有意义(日志等级由热重读自己
// 再应用),要么已经在 configreload.go 里有换快照时的处理。main() 里新多出一处 cfg.X,多半是
// 把某个字段在启动时抄进了别的状态,热重读就够不着它了 —— 改成在读点上经 liveConfig() 现读,
// 或者在 applyConfigChange / syncLiveConfig 里处理,再把字段加进这张表。
func TestMainReadsConfigOnlyAtKnownSites(t *testing.T) {
	allowed := map[string]bool{
		"LogLevel": true, "loadIssues": true, "Token": true, "StateRelayURL": true,
		"StateRelayToken": true, "APIRoot": true, "BundleIDs": true,
	}
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range regexp.MustCompile(`\bcfg\.(\w+)`).FindAllStringSubmatch(string(src), -1) {
		if !allowed[m[1]] {
			t.Errorf("main.go 读了 cfg.%s:确认它能被热重读更新(见本测试注释),再加进 allowed", m[1])
		}
	}
}

// 配置快照必须是只读的:configFromBytes 每次都给一份新的,热重读换的是指针。这里钉住"改了文件
// 拿到的是新指针",poller.syncLiveConfig 靠指针比较判断要不要换。
func TestLiveConfigSwapsPointer(t *testing.T) {
	path := startLiveConfigForTest(t, `{"listenbrainz_user":"a"}`)
	first := liveConfig()
	if liveConfig() != first {
		t.Fatal("文件没变时应返回同一份快照")
	}
	writeConfigForTest(t, path, `{"listenbrainz_user":"b"}`)
	second := liveConfig()
	if second == first || first.User != "a" {
		t.Error("热重读应换一份新快照,旧快照原样不动")
	}
	var probe map[string]any
	b, _ := json.Marshal(second)
	_ = json.Unmarshal(b, &probe)
	if probe["listenbrainz_user"] != "b" {
		t.Errorf("新快照内容不对 %v", probe)
	}
}

// poll() 每一拍第一件事就是换上最新配置。poll 本身要读系统播放状态、单测里跑不了,所以钉源码。
func TestPollSyncsLiveConfigFirst(t *testing.T) {
	src, err := os.ReadFile("poller.go")
	if err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`func \(p \*poller\) poll\(\) \{\n\tp\.syncLiveConfig\(\)\n`).Match(src) {
		t.Error("poller.poll() 开头要先调 p.syncLiveConfig(),否则改了 config.json 主循环一直用旧的")
	}
}
