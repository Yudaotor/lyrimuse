package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 12 章打卡与账号审计:钥匙串读失败后的热重读、开播时刻、按账号补交、重发节流、退出兜底、本机收听登记。

// 启动那一下钥匙串读不出、config.json 之后一直没变:到了重试时刻热重读照样重叠一次,凭据补上;还是读不出就不换快照。
func TestLiveConfigRetriesUnreadableVaultWithoutFileChange(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("LYRIMUSE_CONFIG_DIR", dir)
	path := filepath.Join(dir, "config.json")
	stub := stubCredentialVault(t, `{"config":{"listenbrainz_token":"t1"}}`, errors.New("locked"))
	resetLiveConfigForTest(t)
	writeConfigForTest(t, path, `{"listenbrainz_user":"u"}`)
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	setLiveConfigAt(path, cfg, st)
	if cfg.Token != "" || stub.calls != 1 {
		t.Fatalf("启动时读失败:token=%q calls=%d", cfg.Token, stub.calls)
	}

	configCheckedAt.Store(0)
	if got := liveConfig(); got != cfg || stub.calls != 1 {
		t.Fatalf("没到重试时刻不该再读钥匙串、不该换快照:calls=%d", stub.calls)
	}

	setCredentialVaultRetryAtForTest(time.Now().Add(-time.Second))
	configCheckedAt.Store(0)
	if got := liveConfig(); got != cfg || stub.calls != 2 {
		t.Fatalf("到点重读还是失败、文件也没变:不该换快照(calls=%d)", stub.calls)
	}

	stub.err = nil
	setCredentialVaultRetryAtForTest(time.Now().Add(-time.Second))
	configCheckedAt.Store(0)
	if got := liveConfig(); got.Token != "t1" || got.User != "u" {
		t.Fatalf("钥匙串能读了,文件没变也该叠上:token=%q user=%q", got.Token, got.User)
	}
	calls := stub.calls
	configCheckedAt.Store(0)
	if liveConfig(); stub.calls != calls {
		t.Errorf("读成功之后文件没变就不再起 security,多读了 %d 次", stub.calls-calls)
	}
}

func setCredentialVaultRetryAtForTest(at time.Time) {
	c := &credentialVaultCache
	c.Lock()
	c.retryAt = at
	c.Unlock()
}

// 开播时刻:会话开在暂停那一拍时取第一次在播的那一拍;开在播放中就是开会话那一刻;之后的拍不再挪。
func TestListenStartIsFirstPlayingTick(t *testing.T) {
	t0 := time.Unix(1_800_000_000, 0)
	s := &playSession{startedAt: t0}
	s.accrueListening(t0, snapshot{Playing: false})
	if got := s.listenStart(); !got.Equal(t0) {
		t.Fatalf("还没播过:退回开会话那一刻,got %v", got)
	}
	resume := t0.Add(time.Hour)
	s.accrueListening(resume, snapshot{Playing: true, Position: 0})
	s.accrueListening(resume.Add(5*time.Second), snapshot{Playing: true, Position: 5})
	if got := s.listenStart(); !got.Equal(resume) {
		t.Fatalf("暂停一小时后才播:开播时刻应是按播放那一拍 %v,got %v", resume, got)
	}

	playing := &playSession{startedAt: t0}
	playing.accrueListening(t0, snapshot{Playing: true})
	if got := playing.listenStart(); !got.Equal(t0) {
		t.Fatalf("开在播放中:就是开会话那一刻,got %v", got)
	}
}

// 上送的三处(播放中到点、换歌收尾、退出兜底)和续接记录都取 listenStart,不取开会话那一刻。
func TestListenSubmitsUseListenStart(t *testing.T) {
	poller, err := os.ReadFile("poller.go")
	if err != nil {
		t.Fatal(err)
	}
	resume, err := os.ReadFile("sessionresume.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, snippet := range []string{
		"p.submitSingleAsync(s, s.meta, s.listenStart().Unix())",
		"p.submitSingleAsync(p.sess, p.sess.meta, p.sess.listenStart().Unix())",
		`p.lb.submit(flushCtx, "single", p.sess.listenStart().Unix(), lm)`,
		"startedAt: p.sess.listenStart().Unix()}",
	} {
		if !containsCode(string(poller), snippet) {
			t.Errorf("poller.go 少了 %s", snippet)
		}
	}
	if containsCode(string(poller), "startedAt.Unix()") {
		t.Error("poller.go 还有拿开会话那一刻上送的地方")
	}
	if !containsCode(string(resume), "StartedAt: s.listenStart().Unix(),") {
		t.Error("续接记录要记开播时刻")
	}
}

// 续接:上次退出前放过的,新会话的开播时刻接着那次;没放过的(暂停着开的会话)第一次在播再记。
func TestSessionResumeKeepsListenStart(t *testing.T) {
	r := &sessionResumeFile{Key: "k", AppPID: 1, PlaySeq: 2, StartedAt: 1_800_000_000, PlayedSecs: 30, SavedAt: time.Now().UnixMilli()}
	p := &poller{resume: r, app: &appPlayback{marks: appPlaybackMarks{pid: 1, playSeq: 2, key: "k"}}}
	s := &playSession{key: "k", startedAt: time.Now()}
	if !p.resumeSession(s, time.Now()) {
		t.Fatal("应续接")
	}
	s.accrueListening(time.Now(), snapshot{Playing: true, Position: 40})
	if got := s.listenStart().Unix(); got != 1_800_000_000 {
		t.Fatalf("开播时刻应接着上次的,续接后接着播也不挪,got %d", got)
	}
	r2 := *r
	r2.PlayedSecs = 0
	p = &poller{resume: &r2, app: p.app}
	s = &playSession{key: "k", startedAt: time.Now()}
	p.resumeSession(s, time.Now())
	if !s.playStartedAt.IsZero() {
		t.Fatal("上次还没放过:开播时刻留到第一次在播再记")
	}
}

// 镜像失败留痕的收听带着当时的账号:换了账号之后补提交不把它交到新账号上;没连账号时写的谁连上都能补。
func TestFailedMirrorListenStaysWithItsAccount(t *testing.T) {
	withTempListenLog(t)
	withLfmRetryFile(t)
	now := time.Now()
	recordFailedMirror(errDNS, "alice", "A", "失败那首", "", now.Add(-2*time.Hour).Unix(), 200)
	appendListen("", "B", "没连账号时那首", "", now.Add(-time.Hour).Unix(), 200)

	titles := func(user string) []string {
		pending, _ := pendingBackfillListens(now, user)
		var out []string
		for _, l := range pending {
			out = append(out, l.TI)
		}
		return out
	}
	if got := titles("bob"); len(got) != 1 || got[0] != "没连账号时那首" {
		t.Errorf("换成 bob:只补没连账号时那首,got %v", got)
	}
	if got := titles("Alice"); len(got) != 2 {
		t.Errorf("重连回 alice(大小写不同):两首都补,got %v", got)
	}
	if got := titles(""); len(got) != 1 {
		t.Errorf("没连账号时的清单不列别的账号的,got %v", got)
	}
}

// 补提交命令建的写入器带账号名:隔离行记账号,常驻进程才核对得了(reconcileQuarantined 不认没账号的隔离行)。
func TestBackfillScrobblerKnowsItsAccount(t *testing.T) {
	if got := lastfmScrobbleUser(&config{LastfmScrobbleUsername: " Alice ", LastfmUser: "bob"}); got != "alice" {
		t.Errorf("写入授权的账号优先,小写去空白:got %q", got)
	}
	if got := lastfmScrobbleUser(&config{LastfmUser: "Bob"}); got != "bob" {
		t.Errorf("没记授权账号退回只读用户名:got %q", got)
	}
	src, err := os.ReadFile("backfillcli.go")
	if err != nil {
		t.Fatal(err)
	}
	if !containsCode(string(src), "scrobbler.user = lastfmScrobbleUser(cfg)") {
		t.Error("补提交命令的写入器要带账号名")
	}
}

// 重发一轮里两次提交之间停 lfmRetryPause;停的时候退出就不再发。
func TestProcessLfmRetryPausesBetweenSubmits(t *testing.T) {
	withLfmRetryFile(t)
	saved := lfmRetryPause
	lfmRetryPause = 40 * time.Millisecond
	t.Cleanup(func() { lfmRetryPause = saved })
	now := time.Now()
	for i := range 3 {
		enqueueLastfmRetryIfSafe(errDNS, lfmRetryItem{User: "u", Timestamp: now.Add(-time.Hour).Unix() + int64(i), Artist: "a", Title: "t"})
	}
	hooks := lfmRetryHooks{handled: func() map[int64]bool { return nil }, submitted: func(int64) error { return nil }, quarantine: func(int64) {}}
	var at []time.Time
	processLfmRetry(context.Background(), now, "u", func(context.Context, lfmRetryItem) error {
		at = append(at, time.Now())
		return nil
	}, hooks)
	if len(at) != 3 {
		t.Fatalf("应发 3 条,发了 %d", len(at))
	}
	for i := 1; i < len(at); i++ {
		if gap := at[i].Sub(at[i-1]); gap < lfmRetryPause {
			t.Errorf("第 %d 条跟上一条只隔了 %v", i+1, gap)
		}
	}

	for i := range 2 {
		enqueueLastfmRetryIfSafe(errDNS, lfmRetryItem{User: "u", Timestamp: now.Add(-time.Hour).Unix() + 10 + int64(i), Artist: "a", Title: "t"})
	}
	lfmRetryPause = time.Second
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	calls := 0
	start := time.Now()
	processLfmRetry(ctx, now, "u", func(context.Context, lfmRetryItem) error {
		calls++
		time.AfterFunc(10*time.Millisecond, cancel) // 下一条之前的停顿里退出
		return nil
	}, hooks)
	if calls != 1 {
		t.Errorf("停顿时退出:只该发第一条,发了 %d", calls)
	}
	if elapsed := time.Since(start); elapsed > 500*time.Millisecond {
		t.Errorf("停顿时退出应立刻返回,等了 %v", elapsed)
	}
}

// 退出兜底跟 submitSingleAsync 同一道闸:没有歌手、有声节目都不上送。
func TestExitFlushSkipsListensWithoutArtist(t *testing.T) {
	src, err := os.ReadFile("poller.go")
	if err != nil {
		t.Fatal(err)
	}
	if !containsCode(string(src), `!p.sess.isSpoken && !p.sess.meta.Spoken && lbMeta(p.sess.meta).ArtistName != "" &&`) {
		t.Error("flushSessionOnExit 少了「没有歌手」或有声节目那道闸")
	}
}

// LB 提交失败时这次收听照样记成「本机刚放过」,桥接才认得出 Last.fm 上同一首的回声;重试再走到一次不重复记。
func TestRecentMacListenRecordedWhenLBFails(t *testing.T) {
	withTempListenLog(t)
	p := &poller{ctx: context.Background(), cfg: &config{}}
	meta := snapshot{Artist: "歌手", Title: "歌"}
	sess := &playSession{key: "k", meta: meta, submitting: true, lastfmExcluded: true}
	out := submitOutcome{sess: sess, meta: meta, artistName: "歌手", startedAt: 1_800_000_000,
		lm: lbTrackMeta{ArtistName: "歌手", TrackName: "歌"}, err: errors.New("lb down")}
	p.applySubmitOutcome(out)
	if !p.recentlyPlayedOnMac("歌手", "歌", 1_800_000_030) {
		t.Fatal("LB 失败也要记本机刚放过")
	}
	sess.submitting = true
	out.err = nil
	p.applySubmitOutcome(out)
	if len(p.recentMacListens) != 1 {
		t.Errorf("同一次收听重试成功不该再记一条:%d", len(p.recentMacListens))
	}
}
