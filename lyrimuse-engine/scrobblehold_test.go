package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
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

// 名单:整串或前缀比对、不分大小写;不做子串,真实歌手、近似写法都不算。
func TestIsTestTrack(t *testing.T) {
	for _, a := range []string{"Lyrimuse测试", "Lyrimuse测试A", "lyrimuse test", "LYRIMUSE TEST RADIO", " 测试歌手 ", "測試歌手",
		"Test Artist", "test artist one", "Test Artist Two", "Test Artist Three", "歌手A-B"} {
		if !isTestTrack(a) {
			t.Errorf("%q 应认成测试曲", a)
		}
	}
	for _, a := range []string{"", "陈奕迅", "Lyrimuse", "Test", "Test Artists", "Test Artist Four", "The Test Artist", "测试歌手乐队",
		"新测试歌手", "歌手A", "Artist Test", "周杰伦, Lyrimuse测试"} {
		if isTestTrack(a) {
			t.Errorf("%q 不该认成测试曲", a)
		}
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
