package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

// 没有进度条的状态(上次播放 / 暂停 / 空),重锚不写;带进度条的照写。
func TestRelayShouldPushIgnoresReanchorWithoutProgress(t *testing.T) {
	now := time.Now()
	for _, key := range []string{"last|t|a|b", "macpause|t|a|b|c", "empty"} {
		p := &poller{relayLastState: key, relayLastAt: now.Add(-time.Minute), relayStateSince: now.Add(-time.Minute)}
		if _, ok := p.relayShouldPush(now, key, nil, true); ok {
			t.Errorf("%s: 重锚不该写", key)
		}
	}
	p := &poller{relayLastState: "mac|t|a|b|c", relayLastAt: now.Add(-time.Minute), relayStateSince: now.Add(-time.Minute)}
	if reason, ok := p.relayShouldPush(now, "mac|t|a|b|c", nil, true); !ok || reason != "reanchor" {
		t.Errorf("正在放时重锚要写: %q %v", reason, ok)
	}
}

// 不在播放的状态维持 30 分钟后不再续心跳;正在放的一直续。
func TestRelayShouldPushStopsIdleHeartbeat(t *testing.T) {
	now := time.Now()
	idle := &poller{relayLastState: "macpause|t|a|b", relayLastAt: now.Add(-5 * time.Minute), relayStateSince: now.Add(-10 * time.Minute)}
	if reason, ok := idle.relayShouldPush(now, "macpause|t|a|b", nil, false); !ok || reason != "heartbeat" {
		t.Errorf("暂停 10 分钟时心跳照续: %q %v", reason, ok)
	}
	idle.relayStateSince = now.Add(-31 * time.Minute)
	if _, ok := idle.relayShouldPush(now, "macpause|t|a|b", nil, false); ok {
		t.Error("暂停超过 30 分钟不该再续心跳")
	}
	playing := &poller{relayLastState: "mac|t|a|b|c", relayLastAt: now.Add(-5 * time.Minute), relayStateSince: now.Add(-2 * time.Hour)}
	if _, ok := playing.relayShouldPush(now, "mac|t|a|b|c", nil, false); !ok {
		t.Error("正在放的心跳一直续")
	}
	recent := &poller{relayLastState: "macpause|t|a|b", relayLastAt: now.Add(-time.Minute), relayStateSince: now.Add(-time.Minute)}
	if _, ok := recent.relayShouldPush(now, "macpause|t|a|b", nil, false); ok {
		t.Error("没到心跳间隔不写")
	}
}

// 换了一首歌、封面还没到:先等,最多 5 秒;封面到了立刻推。同一首歌暂停后继续不等。
func TestRelayShouldPushWaitsForCoverOnTrackChange(t *testing.T) {
	now := time.Now()
	p := &poller{relayLastState: "mac|A|x|y|c", relayLastAt: now.Add(-time.Minute), relayStateSince: now.Add(-time.Minute)}
	noCover := map[string]any{"artwork": ""}
	if _, ok := p.relayShouldPush(now, "mac|B|x|y", noCover, false); ok {
		t.Fatal("换歌没封面时先等")
	}
	if _, ok := p.relayShouldPush(now.Add(3*time.Second), "mac|B|x|y", noCover, false); ok {
		t.Fatal("没到 5 秒继续等")
	}
	if reason, ok := p.relayShouldPush(now.Add(6*time.Second), "mac|B|x|y", noCover, false); !ok || reason != "change" {
		t.Fatalf("等够了就推: %q %v", reason, ok)
	}

	q := &poller{relayLastState: "mac|A|x|y|c", relayLastAt: now.Add(-time.Minute), relayStateSince: now.Add(-time.Minute)}
	if _, ok := q.relayShouldPush(now, "mac|B|x|y|c", map[string]any{"artwork": "https://c/1.jpg"}, false); !ok {
		t.Error("封面已到立刻推")
	}

	r := &poller{relayLastState: "macpause|B|x|y", relayLastAt: now.Add(-time.Minute), relayStateSince: now.Add(-time.Minute)}
	if _, ok := r.relayShouldPush(now, "mac|B|x|y", noCover, false); ok {
		t.Error("同一首歌从暂停到继续,先等 relayResumeSettle")
	}
	if _, ok := r.relayShouldPush(now.Add(relayResumeSettle), "mac|B|x|y", noCover, false); !ok {
		t.Error("同一首歌从暂停到继续,等够了就推、不等封面")
	}
}

// 同一首反复暂停、继续:每一次从暂停到在放都先等 relayResumeSettle,不只第一次(02 章决策 119)。
func TestRelayShouldPushSettlesEveryResume(t *testing.T) {
	now := time.Now()
	p := &poller{relayLastState: "macpause|B|x|y|c", relayLastAt: now.Add(-time.Minute), relayStateSince: now.Add(-time.Minute)}
	cover := map[string]any{"artwork": "https://c/1.jpg"}
	for round := 0; round < 3; round++ {
		if _, ok := p.relayShouldPush(now, "mac|B|x|y|c", cover, false); ok {
			t.Fatalf("第 %d 次继续:先等 relayResumeSettle", round+1)
		}
		now = now.Add(relayResumeSettle)
		reason, ok := p.relayShouldPush(now, "mac|B|x|y|c", cover, false)
		if !ok || reason != "change" {
			t.Fatalf("第 %d 次继续:等够了就推: %q %v", round+1, reason, ok)
		}
		p.applyRelayResult(relayPushResult{key: "mac|B|x|y|c", reason: reason, at: now})
		now = now.Add(time.Minute)
		if _, ok := p.relayShouldPush(now, "macpause|B|x|y|c", cover, false); !ok {
			t.Fatalf("第 %d 次暂停应立刻推", round+1)
		}
		p.applyRelayResult(relayPushResult{key: "macpause|B|x|y|c", reason: "change", at: now})
		now = now.Add(time.Minute)
	}
	// 在飞期间不推,也不把等待记录作废。
	p.relayInflight = true
	p.relayShouldPush(now, "mac|B|x|y|c", cover, false)
	if _, ok := p.relayShouldPush(now.Add(relayResumeSettle), "mac|B|x|y|c", cover, false); ok {
		t.Fatal("在飞期间不推")
	}
	p.relayInflight = false
	if _, ok := p.relayShouldPush(now.Add(relayResumeSettle), "mac|B|x|y|c", cover, false); !ok {
		t.Fatal("在飞的回来了,已经等够的照推")
	}
}

// 暂停着开播另一首:先报上一首在放、紧接着换了歌名,上一首不被推成在放(02 章决策 119)。
func TestRelayShouldPushSettlesResumeBeforeTrackChange(t *testing.T) {
	now := time.Now()
	p := &poller{relayLastState: "macpause|A|x|y|c", relayLastAt: now.Add(-time.Minute), relayStateSince: now.Add(-time.Minute)}
	cover := map[string]any{"artwork": "https://c/1.jpg"}
	if _, ok := p.relayShouldPush(now, "mac|A|x|y|c", cover, false); ok {
		t.Fatal("上一首刚报在放,先等")
	}
	if _, ok := p.relayShouldPush(now.Add(350*time.Millisecond), "mac|B|x|y|c", cover, false); !ok {
		t.Fatal("换成新歌照常推")
	}
}

// 推送成功才挪去重锚点,换了状态才重置「从什么时候起没变」;失败进退避。
func TestApplyRelayResult(t *testing.T) {
	t0 := time.Now()
	p := &poller{relayInflight: true, relayLastState: "mac|a", relayStateSince: t0.Add(-time.Hour)}
	p.applyRelayResult(relayPushResult{key: "mac|a", reason: "heartbeat", at: t0})
	if p.relayInflight || p.relayLastAt != t0 || !p.relayStateSince.Equal(t0.Add(-time.Hour)) {
		t.Fatalf("同状态心跳不该重置 since: %+v", p)
	}
	p.applyRelayResult(relayPushResult{key: "macpause|a", reason: "change", at: t0.Add(time.Minute)})
	if p.relayLastState != "macpause|a" || !p.relayStateSince.Equal(t0.Add(time.Minute)) {
		t.Fatalf("换状态要重置 since: %+v", p)
	}
	p.relayInflight = true
	p.applyRelayResult(relayPushResult{key: "last|b", at: t0.Add(2 * time.Minute), err: errors.New("boom")})
	if p.relayInflight || p.relayLastState != "macpause|a" || p.relayFailKey != "last|b" || p.relayBackoff != 30*time.Second {
		t.Fatalf("失败不动锚点、进退避: %+v", p)
	}
}

// 推送在后台跑:中继再慢,pushRelayState 也立刻返回;在飞期间不再另起一次。
func TestPushRelayStateDoesNotBlock(t *testing.T) {
	release := make(chan struct{})
	hits := make(chan struct{}, 4)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits <- struct{}{}
		<-release
	}))
	t.Cleanup(srv.Close)
	t.Cleanup(func() {
		select {
		case <-release:
		default:
			close(release)
		}
	})
	p := &poller{ctx: context.Background(), cfg: &config{StateRelayURL: srv.URL}, relayDoneCh: make(chan relayPushResult, 1)}
	start := time.Now()
	p.pushRelayState(start, false)
	if d := time.Since(start); d > 200*time.Millisecond {
		t.Fatalf("pushRelayState 用了 %v,像是在主循环里同步推", d)
	}
	if !p.relayInflight {
		t.Fatal("应标记在飞")
	}
	<-hits
	p.pushRelayState(start.Add(time.Second), true)
	select {
	case <-hits:
		t.Fatal("在飞期间不该另起一次")
	case <-time.After(100 * time.Millisecond):
	}
	close(release)
	select {
	case r := <-p.relayDoneCh:
		p.applyRelayResult(r)
	case <-time.After(3 * time.Second):
		t.Fatal("没收到结果")
	}
	if p.relayInflight || p.relayLastState != "empty" {
		t.Fatalf("结果回来后记账: inflight=%v last=%q", p.relayInflight, p.relayLastState)
	}
}

// 启动时从 ListenBrainz 取最近一条收听补「上次播放」;取不到也送一条空的,主循环据此知道补种结束了。
func TestSeedLastListen(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/1/user/u%20x/listens" && r.URL.Path != "/1/user/u x/listens" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte(`{"payload":{"listens":[{"listened_at":1700000000,"track_metadata":{"track_name":"浮夸","artist_name":"陈奕迅","release_name":"U87","additional_info":{"source":"iphone"}}}]}}`))
	}))
	t.Cleanup(srv.Close)
	out := make(chan lastListenSeed, 1)
	seedLastListen(context.Background(), srv.URL, "u x", out)
	select {
	case s := <-out:
		if s.track.key() != "浮夸|陈奕迅|U87" || s.listenedAt != 1700000000 || s.device != "iphone" {
			t.Fatalf("字段不对: %+v", s)
		}
	default:
		t.Fatal("该取到一条")
	}

	empty := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"payload":{"listens":[]}}`))
	}))
	t.Cleanup(empty.Close)
	down := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	t.Cleanup(down.Close)
	for _, root := range []string{empty.URL, down.URL} {
		seedLastListen(context.Background(), root, "u", out)
		select {
		case s := <-out:
			if s.track.key() != "" {
				t.Fatalf("%s: 取不到时送的是空的一条: %+v", root, s)
			}
		default:
			t.Fatalf("%s: 取不到也要送一条", root)
		}
	}
}

// 引擎刚启动:App 的播放状态读到之前什么都不推,补种回来之前不推「空」;两样都到齐、或等满就撤掉这道等。
func TestRelayStartupPending(t *testing.T) {
	now := time.Now()
	p := &poller{app: &appPlayback{usedAvail: appStateExiting}, relayStartupUntil: now.Add(relayStartupWait), lastListenSeeding: true}
	if !p.relayStartupPending(now, "macpause|t|a|b") {
		t.Error("App 的播放状态还没读到,什么都先不推")
	}
	p.app.usedAvail = appStateAvailable
	if p.relayStartupPending(now, "macpause|t|a|b") {
		t.Error("读到 App 的播放状态了,Mac 的状态照推")
	}
	if !p.relayStartupPending(now, "empty") {
		t.Error("补种没回来,不推「空」")
	}
	p.lastListenSeeding = false
	if p.relayStartupPending(now, "empty") || !p.relayStartupUntil.IsZero() {
		t.Error("两样都到齐了,撤掉这道等")
	}
	p.app.usedAvail = appStateExiting
	if p.relayStartupPending(now, "empty") {
		t.Error("撤掉之后 App 再不可用也照推")
	}

	late := &poller{app: &appPlayback{usedAvail: appStateMissing}, relayStartupUntil: now.Add(relayStartupWait), lastListenSeeding: true}
	if late.relayStartupPending(now.Add(relayStartupWait), "empty") || !late.relayStartupUntil.IsZero() {
		t.Error("等满了就照推")
	}
	if (&poller{}).relayStartupPending(now, "empty") {
		t.Error("没上这道等(单测、子命令)时照推")
	}
}

// Mac 空闲时启动:不先推一次「空」,补种一回来就推「上次播放」,只写一次;补种取不到时推「空」。
func TestRelayStartupPushesSeedOnce(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	t.Cleanup(srv.Close)
	seed := lastListenSeed{track: snapshot{Title: "浮夸", Artist: "陈奕迅", Album: "U87"}, listenedAt: 1700000000, device: "iphone"}
	suppressEnrichResolveForTest(t, enrichKey(seed.track.Artist, seed.track.Title, seed.track.Album))
	starting := func() *poller {
		return &poller{ctx: context.Background(), cfg: &config{StateRelayURL: srv.URL}, relayDoneCh: make(chan relayPushResult, 1),
			app: &appPlayback{usedAvail: appStateAvailable}, relayStartupUntil: time.Now().Add(relayStartupWait), lastListenSeeding: true}
	}
	pushed := func(p *poller) string {
		t.Helper()
		if !p.relayInflight {
			return ""
		}
		select {
		case r := <-p.relayDoneCh:
			if r.err != nil {
				t.Fatalf("推送失败: %v", r.err)
			}
			p.applyRelayResult(r)
			return r.key
		case <-time.After(3 * time.Second):
			t.Fatal("没收到推送结果")
			return ""
		}
	}

	p := starting()
	p.pushRelayState(time.Now(), false)
	if k := pushed(p); k != "" {
		t.Fatalf("补种没回来,不该先推: %q", k)
	}
	p.applyLastListenSeed(seed)
	if k := pushed(p); k != "last|浮夸|陈奕迅|U87" {
		t.Fatalf("补种回来就推「上次播放」: %q", k)
	}
	p.pushRelayState(time.Now(), false)
	if k := pushed(p); k != "" || p.relayWrites != 1 {
		t.Fatalf("只写一次: 又推了 %q,共 %d 次", k, p.relayWrites)
	}

	q := starting()
	q.applyLastListenSeed(lastListenSeed{})
	if k := pushed(q); k != "empty" {
		t.Fatalf("补种取不到就推「空」: %q", k)
	}
}

// run() 在第一拍之前发出补种、上这道等;补种回来交给 applyLastListenSeed。
func TestRelayStartupWaitIsWired(t *testing.T) {
	src, err := os.ReadFile("poller.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	first := strings.Index(s, "p.poll() // render immediately")
	if first < 0 {
		t.Fatal("找不到 run() 里的第一拍")
	}
	for _, needle := range []string{"p.lastListenSeeding = true", "p.relayStartupUntil = time.Now().Add(relayStartupWait)"} {
		if i := strings.Index(s, needle); i < 0 || i > first {
			t.Errorf("run() 要在第一拍之前: %s", needle)
		}
	}
	if !containsCode(s, "case r := <-p.lastListenSeedCh:\n\t\t\tp.applyLastListenSeed(r)\n") {
		t.Error("补种回来要交给 applyLastListenSeed")
	}
}

// 补种回来时本进程已经记下过一条真实收听:那条更新,不用补种的。
func TestApplyLastListenSeedKeepsRealListen(t *testing.T) {
	heard := snapshot{Title: "十年", Artist: "陈奕迅"}
	p := &poller{cfg: &config{}, lastListen: heard, lastListenAt: 1800000000, lastListenDev: "mac", lastListenSeeding: true}
	p.applyLastListenSeed(lastListenSeed{track: snapshot{Title: "浮夸", Artist: "陈奕迅"}, listenedAt: 1700000000, device: "iphone"})
	if p.lastListen.key() != heard.key() || p.lastListenAt != 1800000000 || p.lastListenDev != "mac" || p.lastListenSeeding {
		t.Fatalf("真实收听不该被补种盖掉: %+v / %d / %q / seeding=%v", p.lastListen, p.lastListenAt, p.lastListenDev, p.lastListenSeeding)
	}
}

// relayTickPayload:一拍的负载,只有封面这一样内容,key 带 |c 的有封面。
func relayTickPayload(key string) map[string]any {
	payload := map[string]any{"artwork": ""}
	if strings.HasSuffix(key, "|c") {
		payload["artwork"] = "https://relay/artwork/0123456789abcdef.jpg"
	}
	return payload
}

// relayTick 是喂给 relayShouldPush 的一拍:这一刻算出来的去重 key,有 |c 的带上封面。
type relayTick struct {
	at  time.Duration
	key string
}

// driveRelay 按拍喂 relayShouldPush,要推的当场记成推成功(applyRelayResult),返回真写出去的 key。
func driveRelay(p *poller, t0 time.Time, ticks []relayTick) []string {
	var wrote []string
	for _, tk := range ticks {
		payload := relayTickPayload(tk.key)
		now := t0.Add(tk.at)
		reason, ok := p.relayShouldPush(now, tk.key, payload, false)
		if !ok {
			continue
		}
		p.applyRelayResult(relayPushResult{key: tk.key, reason: reason, at: now, digest: relayContentDigest(payload)})
		wrote = append(wrote, tk.key)
	}
	return wrote
}

// 同一首歌只是封面从有变无(设备封面刚换上、还没确认传上中继):最多等 relayCoverWait。等的时候封面回来了就一次都不写;
// 等满了还没回来照推,回来再推。重锚不等。见 13 章决策 14。
func TestRelayShouldPushWaitsForCoverBackOnSameTrack(t *testing.T) {
	const lit, bare = "mac|Muñeca|Andria Rose|Muñeca|c", "mac|Muñeca|Andria Rose|Muñeca"
	t0 := time.Now()
	fresh := func(last string) *poller {
		return &poller{relayLastState: last, relayLastAt: t0.Add(-time.Minute), relayStateSince: t0.Add(-time.Minute),
			relayLastDigest: relayContentDigest(relayTickPayload(last))}
	}
	// 照 Muñeca 那次的实况:封面没了 2.47 秒又回来,不等的话会写「无」「有」两次。
	p := fresh(lit)
	if got := driveRelay(p, t0, []relayTick{{0, bare}, {time.Second, bare}, {2470 * time.Millisecond, lit}, {7 * time.Second, lit}}); len(got) != 0 {
		t.Fatalf("封面几秒内就回来,一次都不该写: %q", got)
	}
	if p.relayDeferKey != "" {
		t.Fatalf("回到推上去的那份,等的那条要作废: %q", p.relayDeferKey)
	}
	// 隔一会儿又闪一次:从头等,不拿上一次开始等的时刻算。
	if got := driveRelay(p, t0, []relayTick{{time.Minute, bare}, {time.Minute + 3*time.Second, lit}}); len(got) != 0 {
		t.Fatalf("第二次闪空也从头等: %q", got)
	}

	// 传得慢:等满 relayCoverWait 照推无封面,回来再推有封面。
	slow := fresh(lit)
	got := driveRelay(slow, t0, []relayTick{{0, bare}, {3 * time.Second, bare}, {relayCoverWait, bare}, {8 * time.Second, lit}})
	if len(got) != 2 || got[0] != bare || got[1] != lit {
		t.Fatalf("等满了照推、回来再推: %q", got)
	}

	// 暂停态同样等。
	paused := fresh("macpause|M|a|b|c")
	if got := driveRelay(paused, t0, []relayTick{{0, "macpause|M|a|b"}, {2 * time.Second, "macpause|M|a|b|c"}}); len(got) != 0 {
		t.Fatalf("暂停态的封面闪空也不写: %q", got)
	}

	// 别的也变了(暂停、换歌)不等;重锚不等。
	if _, ok := fresh(lit).relayShouldPush(t0, "macpause|Muñeca|Andria Rose|Muñeca", map[string]any{"artwork": ""}, false); !ok {
		t.Error("暂停了照推,不等封面")
	}
	if _, ok := fresh(lit).relayShouldPush(t0, bare, map[string]any{"artwork": ""}, true); !ok {
		t.Error("重锚照推,不等封面")
	}
}

// 推送失败的退避从 30 秒起翻倍,封顶 10 分钟。
func TestRelayBackoffCapsAtTenMinutes(t *testing.T) {
	p := &poller{}
	at := time.Now()
	var got []time.Duration
	for range 9 {
		p.relayInflight = true
		p.applyRelayResult(relayPushResult{key: "mac|a", at: at, err: errors.New("dial tcp: no such host")})
		got = append(got, p.relayBackoff)
		at = at.Add(p.relayBackoff)
	}
	want := []time.Duration{30 * time.Second, time.Minute, 2 * time.Minute, 4 * time.Minute, 8 * time.Minute,
		10 * time.Minute, 10 * time.Minute, 10 * time.Minute, 10 * time.Minute}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("退避序列 %v,要 %v", got, want)
	}
}

// 网页「上次播放」在收听成立时就更新,不看 ListenBrainz 的结果:LB 失败进重发队列、拒收、还在放待重试、没配 LB(submit 直接
// 返回 nil)都一样。照 A.I.N.Y. 那次 LB 回 404:只在提交成功后才记的话,空闲时推的是「空」。见 13 章决策 14。
func TestApplySubmitOutcomeRecordsLastListenRegardlessOfLB(t *testing.T) {
	withLBRetryFile(t)
	withLBStatusFiles(t)
	meta := snapshot{Title: "A.I.N.Y.", Artist: "G.E.M. 邓紫棋", Album: "T.I.M.E.", Duration: 200}
	cases := []struct {
		name string
		sess *playSession
		err  error
	}{
		{"LB 404 进重发队列", &playSession{meta: meta, lastfmSettled: true, ended: true}, errors.New("post single: status 404")},
		{"LB 拒收", &playSession{meta: meta, lastfmSettled: true, ended: true}, fmt.Errorf("post single: 400: %w", errListenRejected)},
		{"还在放,待重试", &playSession{meta: meta, lastfmSettled: true}, errors.New("timeout")},
		{"没配 LB / 提交成功", &playSession{meta: meta, lastfmSettled: true, ended: true}, nil},
	}
	for _, c := range cases {
		p := &poller{ctx: context.Background(), cfg: &config{}}
		p.applySubmitOutcome(submitOutcome{sess: c.sess, meta: meta, artistName: meta.Artist, startedAt: 1760168144, err: c.err})
		if p.lastListen.key() != meta.key() || p.lastListenAt != 1760168144 || p.lastListenDev != "mac" {
			t.Errorf("%s: 「上次播放」该是这首: %+v / %d / %q", c.name, p.lastListen, p.lastListenAt, p.lastListenDev)
		}
	}

	// 接着空闲:推的是「上次播放」这首,不是「空」。
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	t.Cleanup(srv.Close)
	suppressEnrichResolveForTest(t, enrichKey(meta.Artist, meta.Title, meta.Album))
	p := &poller{ctx: context.Background(), cfg: &config{StateRelayURL: srv.URL}, relayDoneCh: make(chan relayPushResult, 1)}
	p.applySubmitOutcome(submitOutcome{sess: &playSession{meta: meta, lastfmSettled: true, ended: true}, meta: meta, artistName: meta.Artist,
		startedAt: 1760168144, err: errors.New("post single: status 404")})
	p.pushRelayState(time.Now(), false)
	select {
	case r := <-p.relayDoneCh:
		if r.key != "last|"+meta.key() {
			t.Fatalf("空闲时推「上次播放」: %q", r.key)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("没推")
	}
}

// 启动补种取回的那条带着 LB 记下的播放器标签(网页页脚据此显示),且只查歌词缓存:这首此刻没在放,缓存没有就不起解析。
// 见 13 章决策 14。
func TestSeedLastListenKeepsPlayerAndStaysCacheOnly(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"payload":{"listens":[{"listened_at":1760168144,"track_metadata":{"track_name":"偷笑","artist_name":"方大同",` +
			`"release_name":"爱爱爱","additional_info":{"source":"mac","media_player":"QQ Music (macOS)"}}}]}}`))
	}))
	t.Cleanup(srv.Close)
	seed := fetchLastListen(context.Background(), srv.URL, "u")
	if !seed.track.Remote || seed.track.MediaPlayer != "QQ Music (macOS)" {
		t.Fatalf("补种的快照要只查缓存、带上 LB 的播放器标签: %+v", seed.track)
	}
	withEnrichCache(t, map[string]enrichEntry{})
	before := inflightSnapshot()
	st := relayState(seed.track, false, seed.device, seed.listenedAt, false)
	if st["mediaPlayer"] != "QQ Music (macOS)" {
		t.Errorf("网页页脚的播放器该照 LB 记下的: %v", st["mediaPlayer"])
	}
	assertNoNewResolution(t, before, 0)
	// 本机播放的快照照常按 bundle 推。
	if got := lbMetaWith(snapshot{Title: "x", Artist: "y", Bundle: "com.tencent.QQMusicMac"}, nil).AdditionalInfo["media_player"]; got != mediaPlayerLabel("com.tencent.QQMusicMac") {
		t.Error("本机播放照常按 bundle 推出播放器标签")
	}
}
