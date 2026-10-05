package main

import (
	"context"
	"testing"
	"time"
)

// handle 是引擎的会话状态机:换歌开会话、短暂读空续接、单曲循环重新计时、广告标记、播放 / 暂停、累计收听、
// 到阈值提交一次。这里的测试一拍一拍喂快照进去。

// handleTestPoller:跑 handle 用的 poller。ListenBrainz 不带令牌(提交直接空返回、不联网),不配 Last.fm;
// 专辑预取关掉,收听日志写临时目录,tracks 这几首的歌词补全只查缓存、不起后台解析。
func handleTestPoller(t *testing.T, tracks ...snapshot) *poller {
	t.Helper()
	saved := features().AlbumPrefetch
	featuresRef().AlbumPrefetch = false
	withTempListenLog(t)
	keys := make([]string, 0, len(tracks))
	for _, s := range tracks {
		keys = append(keys, enrichKey(s.Artist, s.Title, s.Album))
	}
	suppressEnrichResolveForTest(t, keys...)
	playing := enrichPlayingKey.Load()
	t.Cleanup(func() {
		featuresRef().AlbumPrefetch = saved
		enrichPlayingKey.Store(playing)
		noteAppReportedAd(snapshot{}, false)
	})
	return &poller{ctx: context.Background(), cfg: &config{}, lb: &lbClient{},
		announceDoneCh: make(chan announceOutcome, 16), submitDoneCh: make(chan submitOutcome, 16)}
}

// handleSong:Apple Music 在放的一拍。at 非零 = 带 App 报的位置;零 = 没有位置可核。专辑给全,补全不会去反查专辑名。
func handleSong(title string, pos float64, at time.Time) snapshot {
	return snapshot{Title: title, Artist: "陈奕迅", Album: "U87", Bundle: "com.apple.Music", Duration: 200,
		Playing: true, Rate: 1, Position: pos, AnchorTS: at}
}

// handleTick:喂一拍 App 新读到的快照。
func handleTick(p *poller, now time.Time, cur snapshot) {
	p.cur, p.curStale = cur, false
	p.handle(now, false, false)
}

func handleClock() func(int) time.Time {
	t0 := time.Now()
	return func(s int) time.Time { return t0.Add(time.Duration(s) * time.Second) }
}

// 第一拍开会话,同一首续着计时;换到下一首时上一首收尾。只有读空之后同一首回来才续接:中间换过歌,
// 马上切回上一首也另开会话。
func TestHandleOpensAndSwitchesSessions(t *testing.T) {
	at := handleClock()
	a, b := handleSong("浮夸", 0, at(0)), handleSong("十年", 0, at(20))
	p := handleTestPoller(t, a, b)
	handleTick(p, at(0), a)
	first := p.sess
	if first == nil || first.key != a.key() || !first.startedAt.Equal(at(0)) {
		t.Fatalf("第一拍该开会话: %+v", first)
	}
	handleTick(p, at(10), handleSong("浮夸", 10, at(10)))
	if p.sess != first || first.playedSecs != 10 {
		t.Fatalf("同一首续着计时: same=%v played=%v", p.sess == first, first.playedSecs)
	}
	handleTick(p, at(20), b)
	if p.sess == first || p.sess.key != b.key() || !first.ended || p.recentFinalized != nil {
		t.Fatalf("换歌:新会话 %q,上一首收尾 ended=%v,不留着续接 %v", p.sess.key, first.ended, p.recentFinalized == nil)
	}
	handleTick(p, at(25), handleSong("浮夸", 0, at(25)))
	if p.sess == first || p.sess.key != a.key() || p.sess.playedSecs != 0 {
		t.Fatalf("切回上一首该另开会话: same=%v played=%v", p.sess == first, p.sess.playedSecs)
	}
}

// 短暂读空后同一首在宽限期内回来:续接原会话(另开会把一次收听切成两段、各自过线各记一次),
// 有位置可核的空档按位置补;过了宽限期才回来的另开新会话。
func TestHandleResumesSessionAfterBriefNull(t *testing.T) {
	at := handleClock()
	a := handleSong("浮夸", 0, at(0))
	p := handleTestPoller(t, a)
	handleTick(p, at(0), a)
	handleTick(p, at(30), handleSong("浮夸", 30, at(30)))
	sess := p.sess
	handleTick(p, at(31), snapshot{})
	if p.sess != nil || p.recentFinalized != sess {
		t.Fatalf("读空:会话该收尾并留着 sess=%v recent=%v", p.sess != nil, p.recentFinalized == sess)
	}
	handleTick(p, at(40), handleSong("浮夸", 40, at(40)))
	if p.sess != sess || sess.ended || sess.playedSecs != 30 {
		t.Fatalf("宽限期内回来该续接原会话: same=%v ended=%v played=%v", p.sess == sess, sess.ended, sess.playedSecs)
	}
	handleTick(p, at(50), handleSong("浮夸", 50, at(50)))
	if sess.playedSecs != 50 {
		t.Fatalf("空档按位置补上: played=%v", sess.playedSecs)
	}

	handleTick(p, at(51), snapshot{})
	late := at(51).Add(nullResumeGraceWindow + time.Second)
	handleTick(p, late, handleSong("浮夸", 0, late))
	if p.sess == sess || p.sess.playedSecs != 0 {
		t.Fatalf("过了宽限期回来该另开会话: same=%v played=%v", p.sess == sess, p.sess.playedSecs)
	}
}

// 没有位置可核的会话:读空时扔掉计时起点,续接之后读空那段不算(分不出那几秒放没放)。
func TestHandleDropsGapWithoutPosition(t *testing.T) {
	at := handleClock()
	a := handleSong("浮夸", 0, time.Time{})
	p := handleTestPoller(t, a)
	handleTick(p, at(0), a)
	handleTick(p, at(30), a)
	sess := p.sess
	if sess.playedSecs != 30 {
		t.Fatalf("没有位置按墙钟计: %v", sess.playedSecs)
	}
	handleTick(p, at(31), snapshot{})
	handleTick(p, at(50), a)
	handleTick(p, at(55), a)
	if p.sess != sess || sess.playedSecs != 30 {
		t.Fatalf("续接后读空那段不算: same=%v played=%v", p.sess == sess, sess.playedSecs)
	}
	handleTick(p, at(65), a)
	if sess.playedSecs != 40 {
		t.Fatalf("续接之后照常计: %v", sess.playedSecs)
	}
}

// 单曲循环重新起播(App 的 play_seq 加一、身份不变):另起一个会话重新计时,不当成读空续接。
func TestHandleLoopRestartStartsNewSession(t *testing.T) {
	at := handleClock()
	a := handleSong("浮夸", 0, at(0))
	p := handleTestPoller(t, a)
	for s := 0; s <= 50; s += 10 {
		handleTick(p, at(s), handleSong("浮夸", float64(s), at(s)))
	}
	first := p.sess
	p.cur, p.curStale = handleSong("浮夸", 1, at(55)), false
	p.handle(at(55), false, true)
	if p.sess == first || !first.ended || p.recentFinalized != nil || p.sess.playedSecs != 0 || !p.sess.startedAt.Equal(at(55)) {
		t.Fatalf("单曲循环该另起会话: same=%v ended=%v recent=%v played=%v",
			p.sess == first, first.ended, p.recentFinalized != nil, p.sess.playedSecs)
	}
}

// 同一首期间 App 任一拍判成广告就一直算广告(App 的结论会跟着字段闪变);广告播过阈值也不提交收听。
func TestHandleAdRatchetSkipsListen(t *testing.T) {
	at := handleClock()
	a := handleSong("Advertisement", 0, at(0))
	p := handleTestPoller(t, a)
	handleTick(p, at(0), a)
	if p.sess.isAd {
		t.Fatal("还没判成广告")
	}
	ad := handleSong("Advertisement", 5, at(5))
	noteAppReportedAd(ad, true)
	handleTick(p, at(5), ad)
	noteAppReportedAd(snapshot{}, false)
	for s := 10; s <= 110; s += 10 {
		handleTick(p, at(s), handleSong("Advertisement", float64(s), at(s)))
	}
	if !p.sess.isAd || !p.sess.listenSent || len(p.submitsInflight) != 0 {
		t.Fatalf("广告标记该一直在、过线不提交: isAd=%v sent=%v inflight=%d", p.sess.isAd, p.sess.listenSent, len(p.submitsInflight))
	}
}

// 播满阈值提交一次;结果回来之前、回来之后、读空续接之后都不再提交(否则一次收听记两条)。
// submitSingleAsync 每提交一次都会在 submitsInflight 里记一笔,清掉之后看它还会不会再出现。
func TestHandleSubmitsListenOnce(t *testing.T) {
	at := handleClock()
	a := handleSong("浮夸", 0, at(0))
	p := handleTestPoller(t, a)
	threshold := int(listenThreshold(a.Duration))
	for s := 0; s < threshold; s += 10 {
		handleTick(p, at(s), handleSong("浮夸", float64(s), at(s)))
	}
	if p.sess.submitting || len(p.submitsInflight) != 0 {
		t.Fatalf("没到阈值不提交: played=%v", p.sess.playedSecs)
	}
	handleTick(p, at(threshold), handleSong("浮夸", float64(threshold), at(threshold)))
	sess := p.sess
	if !sess.submitting || len(p.submitsInflight) != 1 {
		t.Fatalf("到阈值该提交: played=%v submitting=%v", sess.playedSecs, sess.submitting)
	}
	delete(p.submitsInflight, sess)
	handleTick(p, at(threshold+10), handleSong("浮夸", float64(threshold+10), at(threshold+10)))
	if len(p.submitsInflight) != 0 {
		t.Fatal("结果回来之前不该再提交")
	}
	select {
	case r := <-p.submitDoneCh:
		p.applySubmitOutcome(r)
	case <-time.After(3 * time.Second):
		t.Fatal("提交结果没回来")
	}
	if !sess.listenSent || sess.submitting {
		t.Fatalf("结果回来记成已提交: sent=%v submitting=%v", sess.listenSent, sess.submitting)
	}
	handleTick(p, at(threshold+20), handleSong("浮夸", float64(threshold+20), at(threshold+20)))
	handleTick(p, at(threshold+21), snapshot{})
	handleTick(p, at(threshold+30), handleSong("浮夸", float64(threshold+30), at(threshold+30)))
	handleTick(p, at(threshold+40), handleSong("浮夸", float64(threshold+40), at(threshold+40)))
	if p.sess != sess || sess.submitting || len(p.submitsInflight) != 0 {
		t.Fatalf("续接之后不再提交: same=%v submitting=%v inflight=%d", p.sess == sess, sess.submitting, len(p.submitsInflight))
	}
}

// App 没新读到的拍(按住、读空去抖):不计时、不挪「曲终」书签。
func TestHandleStaleTickKeepsBookmark(t *testing.T) {
	at := handleClock()
	a := handleSong("浮夸", 0, at(0))
	p := handleTestPoller(t, a)
	handleTick(p, at(0), a)
	handleTick(p, at(10), handleSong("浮夸", 10, at(10)))
	sess := p.sess
	p.cur, p.curStale = handleSong("浮夸", 15, at(15)), true
	p.handle(at(15), false, false)
	if sess.playedSecs != 10 || sess.lastPos != 10 || !sess.lastPosAt.Equal(at(10)) {
		t.Fatalf("旧读数不计时、不挪书签: played=%v lastPos=%v", sess.playedSecs, sess.lastPos)
	}
}

// 暂停期间不计时;播放 / 暂停切换记在会话上。
func TestHandlePauseStopsListeningClock(t *testing.T) {
	at := handleClock()
	a := handleSong("浮夸", 0, at(0))
	p := handleTestPoller(t, a)
	handleTick(p, at(0), a)
	handleTick(p, at(10), handleSong("浮夸", 10, at(10)))
	paused := handleSong("浮夸", 11, at(11))
	paused.Playing, paused.Rate = false, 0
	handleTick(p, at(11), paused)
	sess := p.sess
	if sess.lastPlaying || sess.playedSecs != 11 {
		t.Fatalf("暂停那一拍: lastPlaying=%v played=%v", sess.lastPlaying, sess.playedSecs)
	}
	handleTick(p, at(40), paused)
	handleTick(p, at(41), handleSong("浮夸", 11, at(41)))
	handleTick(p, at(51), handleSong("浮夸", 21, at(51)))
	if !sess.lastPlaying || sess.playedSecs != 21 {
		t.Fatalf("暂停那段不算: lastPlaying=%v played=%v", sess.lastPlaying, sess.playedSecs)
	}
}

// 专辑回填、电台真曲长都比会话起点晚到:同一首的会话元数据跟着补上;非电台的时长不回填(换曲预载窗口里
// 播放器会把下一首的时长拼进来)。
func TestHandleBackfillsSessionMeta(t *testing.T) {
	at := handleClock()
	radio := handleSong("Dumb Blonde", 0, at(0))
	radio.Radio, radio.Duration = true, 0
	song := handleSong("浮夸", 0, at(10))
	song.Duration = 0
	p := handleTestPoller(t, radio, song)
	handleTick(p, at(0), radio)
	later := handleSong("Dumb Blonde", 5, at(5))
	later.Radio, later.Duration, later.AlbumHint = true, 150, "Hello, I'm Dolly"
	handleTick(p, at(5), later)
	if p.sess.meta.Duration != 150 || p.sess.meta.AlbumHint != "Hello, I'm Dolly" {
		t.Fatalf("电台曲长、专辑回填: duration=%v hint=%q", p.sess.meta.Duration, p.sess.meta.AlbumHint)
	}
	handleTick(p, at(10), song)
	handleTick(p, at(15), handleSong("浮夸", 5, at(15)))
	if p.sess.meta.Duration != 0 {
		t.Fatalf("非电台的时长不回填: %v", p.sess.meta.Duration)
	}
}

// Spotify 原生播放开会话时,记下 App 带来的曲目 ID(歌词缓存的真曲目链接、上送都用它);别的播放器、广告不记。
func TestHandleNotesSpotifyTrackIDAtSessionStart(t *testing.T) {
	at := handleClock()
	song, ad := handleSong("Spotify Song", 0, at(0)), handleSong("Spotify Ad", 0, at(20))
	song.Bundle, ad.Bundle = spotifyBundleID, spotifyBundleID
	other := handleSong("Music Song", 0, at(10))
	p := handleTestPoller(t, song, other, ad)
	enrichMu.Lock()
	savedHints, savedLast := spotifyTrackIDHints, spotifyTrackIDLastKey
	spotifyTrackIDHints = map[string]string{}
	enrichMu.Unlock()
	t.Cleanup(func() {
		enrichMu.Lock()
		spotifyTrackIDHints, spotifyTrackIDLastKey = savedHints, savedLast
		enrichMu.Unlock()
	})
	hint := func(s snapshot) string {
		enrichMu.Lock()
		defer enrichMu.Unlock()
		return spotifyTrackIDHints[enrichKey(s.Artist, s.Title, s.Album)]
	}
	p.appSpotifyTrackID = "4uLU6hMCjMI75M1A2tKUQC"
	handleTick(p, at(0), song)
	handleTick(p, at(10), other)
	noteAppReportedAd(ad, true)
	handleTick(p, at(20), ad)
	if hint(song) != "4uLU6hMCjMI75M1A2tKUQC" || hint(other) != "" || hint(ad) != "" {
		t.Fatalf("只给 Spotify 的歌记曲目 ID: song=%q other=%q ad=%q", hint(song), hint(other), hint(ad))
	}
}
