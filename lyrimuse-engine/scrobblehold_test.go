package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// withScrobbleHold 把开关文件指到临时目录,写进这几条租约;不带租约 = 文件不存在。
func withScrobbleHold(t *testing.T, leases ...scrobbleHoldLease) string {
	t.Helper()
	saved := scrobbleHoldPath
	scrobbleHoldPath = filepath.Join(t.TempDir(), "scrobble-hold.json")
	t.Cleanup(func() { scrobbleHoldPath = saved })
	if len(leases) > 0 {
		writeScrobbleHold(t, leases...)
	}
	return scrobbleHoldPath
}

func writeScrobbleHold(t *testing.T, leases ...scrobbleHoldLease) {
	t.Helper()
	data, err := json.Marshal(scrobbleHoldFile{Holds: leases})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(scrobbleHoldPath, data, 0o644); err != nil {
		t.Fatal(err)
	}
}

func lease(id string, since, until time.Time) scrobbleHoldLease {
	return scrobbleHoldLease{ID: id, Since: since.Unix(), Until: until.Unix()}
}

// 开关:没文件、坏文件、到期的都当关着;每条租约从 since 起最长 scrobbleHoldMax;几条里取最晚的。
func TestScrobbleHoldUntil(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	saved := scrobbleHoldPath
	scrobbleHoldPath = ""
	if !scrobbleHoldUntil(now).IsZero() {
		t.Fatal("没登记路径 = 关着")
	}
	scrobbleHoldPath = saved

	withScrobbleHold(t)
	if !scrobbleHoldUntil(now).IsZero() {
		t.Fatal("文件不存在 = 关着")
	}
	writeScrobbleHold(t, lease("a", now.Add(-time.Minute), now.Add(30*time.Minute)))
	if got := scrobbleHoldUntil(now); !got.Equal(now.Add(30 * time.Minute)) {
		t.Fatalf("开着到 until: %v", got)
	}
	if got := scrobbleHoldUntil(now.Add(30 * time.Minute)); !got.IsZero() {
		t.Fatalf("到点就关: %v", got)
	}
	writeScrobbleHold(t, lease("a", now, now.Add(5*time.Hour)))
	if got := scrobbleHoldUntil(now.Add(time.Hour)); !got.Equal(now.Add(scrobbleHoldMax)) {
		t.Fatalf("until 写得再远也从 since 起封顶: %v", got)
	}
	if got := scrobbleHoldUntil(now.Add(scrobbleHoldMax)); !got.IsZero() {
		t.Fatalf("封顶到了就关: %v", got)
	}
	writeScrobbleHold(t, scrobbleHoldLease{ID: "no-since", Until: now.Add(time.Hour).Unix()},
		lease("future", now.Add(time.Hour), now.Add(90*time.Minute)))
	if got := scrobbleHoldUntil(now); !got.IsZero() {
		t.Fatalf("没有 since、since 在将来的不认: %v", got)
	}
	writeScrobbleHold(t, lease("a", now.Add(-time.Hour), now.Add(-time.Minute)), lease("c", now, now.Add(10*time.Minute)),
		lease("b", now, now.Add(20*time.Minute)))
	if got := scrobbleHoldUntil(now); !got.Equal(now.Add(20 * time.Minute)) {
		t.Fatalf("几条取没到期里最晚的: %v", got)
	}
	if err := os.WriteFile(scrobbleHoldPath, []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := scrobbleHoldUntil(now); !got.IsZero() {
		t.Fatalf("坏文件当关着: %v", got)
	}
}

// 名单:整串或前缀比对、不分大小写;不做子串,真实歌手、近似写法都不算。歌手为空时按没写标签的素材名整串认,有歌手时
// 素材名不算。名单和例句都读 shared/test-tracks.json,App 侧 selftest discord 组跑同一批例句;编进来的名单跟那份 JSON
// 对不上(生成物过期)这里就红。
func TestIsTestTrack(t *testing.T) {
	data, err := os.ReadFile("../shared/test-tracks.json")
	if err != nil {
		t.Fatal(err)
	}
	var spec struct {
		Prefixes      []string `json:"artist_prefixes"`
		Artists       []string `json:"artists"`
		Untagged      []string `json:"untagged_titles"`
		Match         []string `json:"match"`
		Keep          []string `json:"keep"`
		MatchUntagged []string `json:"match_untagged"`
		KeepTracks    []struct {
			Artist string `json:"artist"`
			Title  string `json:"title"`
		} `json:"keep_tracks"`
	}
	if err := json.Unmarshal(data, &spec); err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(testTrackArtistPrefixes) != fmt.Sprint(spec.Prefixes) || fmt.Sprint(testTrackArtists) != fmt.Sprint(spec.Artists) ||
		fmt.Sprint(testTrackUntaggedTitles) != fmt.Sprint(spec.Untagged) {
		t.Fatal("testtracks_generated.go 跟 shared/test-tracks.json 对不上,跑 python3 scripts/gen-test-tracks.py")
	}
	if len(spec.Match) == 0 || len(spec.Keep) == 0 || len(spec.MatchUntagged) == 0 || len(spec.KeepTracks) == 0 {
		t.Fatal("例句读空了")
	}
	for _, a := range spec.Match {
		if !isTestTrack(a, "") || !isTestTrack(a, "浮夸") {
			t.Errorf("%q 应认成测试曲", a)
		}
	}
	for _, a := range spec.Keep {
		if isTestTrack(a, "浮夸") {
			t.Errorf("%q 不该认成测试曲", a)
		}
	}
	for _, title := range spec.MatchUntagged {
		if !isTestTrack("", title) || !isTestTrack("  ", title) {
			t.Errorf("没有歌手的 %q 应认成测试曲", title)
		}
		if isTestTrack("陈奕迅", title) {
			t.Errorf("有歌手的 %q 不该按素材名认", title)
		}
	}
	for _, tr := range spec.KeepTracks {
		if isTestTrack(tr.Artist, tr.Title) {
			t.Errorf("%q - %q 不该认成测试曲", tr.Artist, tr.Title)
		}
	}
}

// 租约表此刻开到什么时候:跑 shared/testdata/scrobble-hold 的共用样例,App 侧 ScrobbleHold.activeUntil 跑同一批。
func TestScrobbleHoldSharedCases(t *testing.T) {
	data, err := os.ReadFile("../shared/testdata/scrobble-hold/cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var spec struct {
		Cases []struct {
			Name  string              `json:"name"`
			Now   int64               `json:"now"`
			Holds []scrobbleHoldLease `json:"holds"`
			Until int64               `json:"until"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &spec); err != nil || len(spec.Cases) == 0 {
		t.Fatalf("样例读不出来: %v", err)
	}
	withScrobbleHold(t)
	for _, c := range spec.Cases {
		writeScrobbleHold(t, c.Holds...)
		got := scrobbleHoldUntil(time.Unix(c.Now, 0))
		var gotUnix int64
		if !got.IsZero() {
			gotUnix = got.Unix()
		}
		if gotUnix != c.Until {
			t.Errorf("%s: until=%d, want %d", c.Name, gotUnix, c.Until)
		}
	}
}

// relayKeyAfterPush:推一次,返回这次推送(或推迟)的去重 key。
func relayKeyAfterPush(t *testing.T, p *poller, now time.Time) string {
	t.Helper()
	p.pushRelayState(now, false)
	if p.relayInflight {
		return (<-p.relayDoneCh).key
	}
	return p.relayDeferKey
}

// 网页中继:测试曲、开关开着时放的歌都不当「Mac 正在放」推,网页停在上一首;真歌照常推。会话认上之后开关收掉,
// 这一首照旧不推。
func TestPushRelayStateSkipsHeldTrack(t *testing.T) {
	t0 := time.Now()
	relayPoller := func(cur snapshot, held string) *poller {
		return &poller{ctx: context.Background(), cfg: &config{StateRelayURL: "http://127.0.0.1:9"},
			relayDoneCh: make(chan relayPushResult, 1), cur: cur,
			sess: &playSession{key: cur.key(), meta: cur, startedAt: t0.Add(-time.Minute), scrobbleHold: held}}
	}
	withScrobbleHold(t)
	// 推送要带这一首的补全信息,没缓存时会在后台起整轮联网解析,用例结束后还在跑。先标成解析在途。
	holdEnrichResolution(t, enrichKey("陈奕迅", "浮夸", "测试专辑"), enrichKey("", "Silence.mp3", "测试专辑"))
	for _, tc := range []struct {
		name, artist, title string
		hold                bool
		wantMac             bool
	}{
		{"真歌照常推", "陈奕迅", "浮夸", false, true},
		{"测试曲不推", "Lyrimuse测试", "浮夸", false, false},
		{"名单里的整串不推", "Test Artist One", "浮夸", false, false},
		{"开关开着真歌也不推", "陈奕迅", "浮夸", true, false},
		{"没写歌手标签的测试素材不推", "", "ToneClick", false, false},
		{"没写歌手标签的素材带扩展名也不推", "", "Click A.wav", false, false},
		{"没有歌手的真歌照常推", "", "Silence.mp3", false, true},
	} {
		if tc.hold {
			writeScrobbleHold(t, lease("t", t0, t0.Add(time.Hour)))
		} else {
			_ = os.Remove(scrobbleHoldPath)
		}
		p := relayPoller(heldSong(tc.artist, tc.title, 20, t0), "")
		key := relayKeyAfterPush(t, p, t0.Add(relayStartupWait))
		if tc.wantMac && !strings.HasPrefix(key, "mac|") || !tc.wantMac && key != "empty" {
			t.Errorf("%s: key=%q", tc.name, key)
		}
	}
	_ = os.Remove(scrobbleHoldPath)
	p := relayPoller(heldSong("陈奕迅", "浮夸", 20, t0), "test mode until 2026-11-18T00:00:00Z")
	if key := relayKeyAfterPush(t, p, t0.Add(relayStartupWait)); key != "empty" {
		t.Errorf("会话认上之后开关收掉,这一首照旧不推: key=%q", key)
	}
	p = relayPoller(heldSong("陈奕迅", "浮夸", 20, t0), "")
	p.sess.key = "上一首"
	p.cur = heldSong("Lyrimuse测试", "封面FLAC", 1, t0)
	if key := relayKeyAfterPush(t, p, t0.Add(relayStartupWait)); key != "empty" || p.sess.scrobbleHold != "" {
		t.Errorf("会话还没跟上的测试曲也不推,且不记到上一首的会话上: key=%q hold=%q", key, p.sess.scrobbleHold)
	}
	p = relayPoller(heldSong("陈奕迅", "浮夸", 20, t0), "")
	p.sess.key = "上一首"
	p.cur = heldSong("", "ToneClick", 1, t0)
	if key := relayKeyAfterPush(t, p, t0.Add(relayStartupWait)); key != "empty" {
		t.Errorf("会话还没跟上的无歌手测试素材也不推: key=%q", key)
	}
}

func heldSong(artist, title string, pos float64, at time.Time) snapshot {
	return snapshot{Title: title, Artist: artist, Album: "测试专辑", Bundle: "org.cogx.cog", Duration: 60,
		Playing: true, Rate: 1, Position: pos, AnchorTS: at}
}

// 测试曲放过门槛:不宣布正在播放、不提交、本地收听日志不写;同样放法的真歌照常宣布和提交。
func TestHandleTestTrackRecordsNothing(t *testing.T) {
	withScrobbleHold(t)
	at := handleClock()
	a := heldSong("Lyrimuse测试", "对时测试", 0, at(0))
	p := handleTestPoller(t, a)
	for s := 0; s <= 40; s += 5 {
		handleTick(p, at(s), heldSong("Lyrimuse测试", "对时测试", float64(s), at(s)))
	}
	if p.sess.scrobbleHold != "test track" || p.sess.announcing || !p.sess.listenSent || len(p.submitsInflight) != 0 {
		t.Fatalf("测试曲不记: hold=%q announcing=%v sent=%v inflight=%d",
			p.sess.scrobbleHold, p.sess.announcing, p.sess.listenSent, len(p.submitsInflight))
	}
	if n := len(readListenLog()); n != 0 {
		t.Fatalf("本地收听日志不该有: %d", n)
	}

	b := heldSong("陈奕迅", "浮夸", 0, at(0))
	q := handleTestPoller(t, b)
	for s := 0; s <= 40; s += 5 {
		handleTick(q, at(s), heldSong("陈奕迅", "浮夸", float64(s), at(s)))
	}
	if q.sess.scrobbleHold != "" || !q.sess.announcing || len(q.submitsInflight) != 1 {
		t.Fatalf("真歌照常: hold=%q announcing=%v inflight=%d", q.sess.scrobbleHold, q.sess.announcing, len(q.submitsInflight))
	}
}

// 开关开着:真歌也不记;放到一半关掉开关,这一首照旧不记;到期之后的下一首照常。
func TestHandleScrobbleHoldSwitch(t *testing.T) {
	at := handleClock()
	withScrobbleHold(t, lease("t", at(0), at(0).Add(time.Hour)))
	a, b := heldSong("陈奕迅", "浮夸", 0, at(0)), heldSong("陈奕迅", "十年", 0, at(100))
	p := handleTestPoller(t, a, b)
	for s := 0; s <= 10; s += 5 {
		handleTick(p, at(s), heldSong("陈奕迅", "浮夸", float64(s), at(s)))
	}
	if p.sess.scrobbleHold == "" || p.sess.announcing {
		t.Fatalf("开关开着不宣布: hold=%q announcing=%v", p.sess.scrobbleHold, p.sess.announcing)
	}
	if err := os.Remove(scrobbleHoldPath); err != nil {
		t.Fatal(err)
	}
	for s := 15; s <= 40; s += 5 {
		handleTick(p, at(s), heldSong("陈奕迅", "浮夸", float64(s), at(s)))
	}
	if !p.sess.listenSent || len(p.submitsInflight) != 0 {
		t.Fatalf("开关中途关掉,认上的这一首照旧不提交: sent=%v inflight=%d", p.sess.listenSent, len(p.submitsInflight))
	}
	handleTick(p, at(100), b)
	for s := 105; s <= 140; s += 5 {
		handleTick(p, at(s), heldSong("陈奕迅", "十年", float64(s-100), at(s)))
	}
	if p.sess.scrobbleHold != "" || len(p.submitsInflight) != 1 {
		t.Fatalf("开关关了之后的下一首照常: hold=%q inflight=%d", p.sess.scrobbleHold, len(p.submitsInflight))
	}
}

// 放到一半才打开开关:已经宣布过的这一首,到门槛也不提交。
func TestHandleScrobbleHoldTurnedOnMidSong(t *testing.T) {
	at := handleClock()
	withScrobbleHold(t)
	a := heldSong("陈奕迅", "浮夸", 0, at(0))
	p := handleTestPoller(t, a)
	for s := 0; s <= 10; s += 5 {
		handleTick(p, at(s), heldSong("陈奕迅", "浮夸", float64(s), at(s)))
	}
	if p.sess.scrobbleHold != "" || !p.sess.announcing {
		t.Fatalf("开关关着照常宣布: hold=%q announcing=%v", p.sess.scrobbleHold, p.sess.announcing)
	}
	writeScrobbleHold(t, lease("t", time.Now(), time.Now().Add(time.Hour)))
	for s := 15; s <= 40; s += 5 {
		handleTick(p, at(s), heldSong("陈奕迅", "浮夸", float64(s), at(s)))
	}
	if p.sess.scrobbleHold == "" || !p.sess.listenSent || len(p.submitsInflight) != 0 {
		t.Fatalf("中途打开也挡住提交: hold=%q sent=%v inflight=%d", p.sess.scrobbleHold, p.sess.listenSent, len(p.submitsInflight))
	}
}

// 退出兜底:测试播放不同步提交、不写本地收听日志;真歌照常写(没连 Last.fm 时落本地收听日志)。
func TestExitFlushSkipsHeldListen(t *testing.T) {
	// 写本地收听日志要带这一首的补全信息,没缓存时会在后台起整轮联网解析。先标成解析在途。
	holdEnrichResolution(t, enrichKey("陈奕迅", "浮夸", "测试专辑"), enrichKey("Test Artist One", "浮夸", "测试专辑"))
	for _, tc := range []struct {
		artist string
		hold   bool
		want   int
	}{
		{"陈奕迅", false, 1},
		{"Test Artist One", false, 0},
		{"陈奕迅", true, 0},
	} {
		if tc.hold {
			withScrobbleHold(t, lease("t", time.Now(), time.Now().Add(time.Hour)))
		} else {
			withScrobbleHold(t)
		}
		withTempListenLog(t)
		meta := heldSong(tc.artist, "浮夸", 40, time.Now())
		p := &poller{ctx: context.Background(), cfg: &config{}, lb: &lbClient{}}
		p.sess = &playSession{key: meta.key(), meta: meta, startedAt: time.Now().Add(-time.Minute), playedSecs: 40}
		p.flushSessionOnExit(context.Background())
		if n := len(readListenLog()); n != tc.want {
			t.Errorf("%s hold=%v: 本地收听日志 %d 条, want %d", tc.artist, tc.hold, n, tc.want)
		}
	}
}

// App 写、引擎读:文件名、上限两侧一致;App 写出的样子引擎读得懂。
func TestScrobbleHoldMatchesSwift(t *testing.T) {
	hold, err := os.ReadFile("../lyrimuse/Sources/LyrimuseCore/Models/ScrobbleHold.swift")
	if err != nil {
		t.Fatal(err)
	}
	link, err := os.ReadFile("../lyrimuse/Sources/LyrimuseCore/Models/LyrimuseDeepLink.swift")
	if err != nil {
		t.Fatal(err)
	}
	if !containsCode(string(hold), `public static let fileName = "`+clientName+`-scrobble-hold.json"`) {
		t.Error("ScrobbleHold.fileName 跟引擎的文件名不一致")
	}
	wantMax := fmt.Sprintf("public static let maxScrobbleHoldMinutes = %d", int(scrobbleHoldMax/time.Minute))
	if !containsCode(string(link), wantMax) {
		t.Errorf("深链上限跟 scrobbleHoldMax 不一致,要有 %s", wantMax)
	}
	withScrobbleHold(t)
	now := time.Now()
	body := fmt.Sprintf(`{"holds":[{"id":"a","since":%d,"until":%d}]}`, now.Unix(), now.Add(10*time.Minute).Unix())
	if err := os.WriteFile(scrobbleHoldPath, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if scrobbleHoldUntil(now).IsZero() {
		t.Fatal("App 写出的租约表引擎要读得懂")
	}
}

// 测试播放过了门槛:不提交,但「本机刚放过」照记,桥接据此认出播放器自己往 Last.fm 打的那条回声。
func TestHeldListenStillRecordsMacListen(t *testing.T) {
	at := handleClock()
	withScrobbleHold(t, lease("t", at(0), at(0).Add(time.Hour)))
	p := handleTestPoller(t, heldSong("陈奕迅", "浮夸", 0, at(0)))
	for s := 0; s <= 40; s += 5 {
		handleTick(p, at(s), heldSong("陈奕迅", "浮夸", float64(s), at(s)))
	}
	if !p.sess.listenSent || len(p.submitsInflight) != 0 {
		t.Fatalf("开关开着不提交: sent=%v inflight=%d", p.sess.listenSent, len(p.submitsInflight))
	}
	if !p.recentlyPlayedOnMac("陈奕迅", "浮夸 (Remaster)", p.sess.listenStart().Unix()+300) {
		t.Fatalf("测试播放也要记进本机刚放过: %+v", p.recentMacListens)
	}
}

// bridgeTestPoller:配了 LB 的桥接,LB 那头只数请求。
func bridgeTestPoller(t *testing.T) (*poller, *atomic.Int32) {
	t.Helper()
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)
	dir := t.TempDir()
	return &poller{
		ctx:                 context.Background(),
		cfg:                 &config{LastfmUser: "someone", LastfmAPIKey: "key", User: "lb-user", Token: "lb-token"},
		lb:                  &lbClient{root: srv.URL, token: "lb-token", hc: &http.Client{}},
		fwdSeeded:           true,
		forwarded:           map[int64]bool{},
		lfmMirrored:         map[int64]bool{},
		forwardedSet:        persistedTTLSet{path: dir + "/forwarded.json", ttl: forwardedTTL},
		lfmMirroredSet:      persistedTTLSet{path: dir + "/mirrored.json", ttl: lfmMirroredTTL},
		bridgeForwardDoneCh: make(chan []bridgeForwardResult, 1),
	}, &hits
}

// Last.fm 上的测试曲(播放器自己打的卡、报的正在播放)不当 iPhone 的收听转发,也不当 iPhone 在放;真歌照常。
func TestBridgeSkipsTestTracks(t *testing.T) {
	now := time.Now()
	p, _ := bridgeTestPoller(t)
	p.remoteTrack, p.remoteAt = snapshot{Title: "十年", Artist: "陈奕迅", Playing: true, Remote: true}, now.Add(-time.Minute)
	held := lastfmTrack{Artist: "Lyrimuse测试", Title: "对时测试", UTS: now.Unix() - 60}
	untagged := lastfmTrack{Artist: "", Title: "ToneClick", UTS: now.Unix() - 50}
	p.applyBridgeResult(bridgeFetchResult{now: now, ok: true,
		page: lastfmRecentPage{NowPlaying: &held, Done: []lastfmTrack{untagged, held}}})
	if p.bridgeForwarding || !p.forwarded[held.UTS] || !p.forwarded[untagged.UTS] {
		t.Fatalf("测试曲不转发、记成处理过: forwarding=%v forwarded=%v", p.bridgeForwarding, p.forwarded)
	}
	if !p.remoteAt.IsZero() || p.remoteKey != "" {
		t.Fatalf("测试曲的正在播放不当 iPhone 在放,之前那首也撤掉: remoteAt=%v key=%q", p.remoteAt, p.remoteKey)
	}

	q, _ := bridgeTestPoller(t)
	real := lastfmTrack{Artist: "陈奕迅", Title: "浮夸", UTS: now.Unix() - 60}
	q.applyBridgeResult(bridgeFetchResult{now: now, ok: true,
		page: lastfmRecentPage{NowPlaying: &real, Done: []lastfmTrack{real}}})
	if !q.bridgeForwarding || q.remoteAt.IsZero() {
		t.Fatalf("真歌照常转发、照常当 iPhone 在放: forwarding=%v remoteAt=%v", q.bridgeForwarding, q.remoteAt)
	}
	if r := <-q.bridgeForwardDoneCh; len(r) != 1 {
		t.Fatalf("真歌转发一条: %v", r)
	}
}
