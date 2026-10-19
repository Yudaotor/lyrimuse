package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 引擎重启时正在放的那一首接着计时(sessionresume.go)。判错的代价两头都是收听记错:不续接 = 前后两段各自不够门槛、
// 合起来够的那次两边都不记;续接错 = 已经记过的再记一次,或者把另一次播放算进这一次。

// resumePoller:App 进程 42 正在放 track、play_seq 7(同一次起播)。
func resumePoller(t *testing.T, track snapshot, tracks ...snapshot) *poller {
	t.Helper()
	p := handleTestPoller(t, append([]snapshot{track}, tracks...)...)
	p.app = &appPlayback{marks: appPlaybackMarks{pid: 42, playSeq: 7, key: track.key()}}
	return p
}

// resumeRecord:上一个进程在 at(-2) 退出时记下的这一首,最后一拍在 at(-5)、位置 lastPos。
func resumeRecord(track snapshot, at func(int) time.Time, startedAgo int, played, lastPos float64, sent bool) *sessionResumeFile {
	return &sessionResumeFile{Key: track.key(), AppPID: 42, PlaySeq: 7, StartedAt: at(-startedAgo).Unix(), PlayedSecs: played,
		ListenSent: sent, LastfmSettled: sent, LastSeenAt: at(-5).UnixMilli(), LastSeenPos: lastPos, LastSeenHasPos: true,
		SavedAt: at(-2).UnixMilli()}
}

// longSong:10 分钟的歌,门槛 240 s(listenCapSecs)。
func longSong(pos float64, at time.Time) snapshot {
	s := handleSong("Long Song", pos, at)
	s.Duration = 600
	return s
}

// 重启前已经过了门槛、提交过:续接回来接着计时,开播时刻是原来的,重启后再放够一个门槛也不再提交。
func TestSessionResumeAfterListenSentDoesNotResubmit(t *testing.T) {
	at := handleClock()
	song := longSong(0, time.Time{})
	p := resumePoller(t, song)
	p.resume = resumeRecord(song, at, 260, 250, 250, true)
	for s := 0; s <= 250; s += 10 {
		handleTick(p, at(s), longSong(float64(255+s), at(s)))
	}
	if !p.sess.startedAt.Equal(time.Unix(at(-260).Unix(), 0)) || !p.sess.listenSent || !p.sess.lastfmSettled {
		t.Fatalf("该续接原来那次收听: started=%v sent=%v settled=%v", p.sess.startedAt, p.sess.listenSent, p.sess.lastfmSettled)
	}
	if p.sess.submitting || len(p.submitsInflight) != 0 {
		t.Fatalf("重启前已经提交过,续接回来不该再提交: played=%v", p.sess.playedSecs)
	}
	if p.resume != nil {
		t.Error("续接记录只用一次")
	}
}

// 重启前没过门槛:已播时长接着算,空档按 App 报的位置补,合起来过了门槛提交一次,开播时刻是原来的。
func TestSessionResumeAccruesAcrossRestart(t *testing.T) {
	at := handleClock()
	song := handleSong("浮夸", 0, time.Time{})
	p := resumePoller(t, song)
	p.resume = resumeRecord(song, at, 70, 60, 60, false)
	handleTick(p, at(0), handleSong("浮夸", 65, at(0)))
	if p.sess.playedSecs != 65 {
		t.Fatalf("空档按位置补(60 → 65): played=%v", p.sess.playedSecs)
	}
	handleTick(p, at(40), handleSong("浮夸", 105, at(40)))
	r, ok := p.submitsInflight[p.sess]
	if !ok || r.startedAt != at(-70).Unix() {
		t.Fatalf("合起来过了门槛该按原来的开播时刻提交一次: inflight=%v started=%d played=%v", ok, r.startedAt, p.sess.playedSecs)
	}
}

// 重启前 Last.fm 那一路还挂着等 scrobble 时点(LB 已经提交):续接回来照原来的开播时刻接着挂。
func TestSessionResumeKeepsPendingLastfmListen(t *testing.T) {
	at := handleClock()
	song := handleSong("浮夸", 0, time.Time{})
	p := resumePoller(t, song)
	r := resumeRecord(song, at, 150, 120, 120, true)
	r.LastfmSettled, r.LastfmPending = false, true
	p.resume = r
	saved := features().LastfmScrobblePoint
	featuresRef().LastfmScrobblePoint = scrobblePoint90
	t.Cleanup(func() { featuresRef().LastfmScrobblePoint = saved })
	handleTick(p, at(0), handleSong("浮夸", 125, at(0)))
	if p.sess.lastfmPending == nil || p.sess.lastfmPending.startedAt != at(-150).Unix() || p.sess.lastfmSettled {
		t.Fatalf("挂着的 Last.fm 收听该接着挂: %+v settled=%v", p.sess.lastfmPending, p.sess.lastfmSettled)
	}
}

// 不续接的几种:重启后换了歌、离退出太久、App 重新放了一遍(play_seq 变了)、App 换了进程。都按新开播从零计时。
func TestSessionResumeRejects(t *testing.T) {
	at := handleClock()
	song := handleSong("浮夸", 0, time.Time{})
	other := handleSong("十年", 0, time.Time{})
	cases := []struct {
		name  string
		first snapshot
		edit  func(p *poller, r *sessionResumeFile)
	}{
		{"换了歌", other, func(p *poller, r *sessionResumeFile) { p.app.marks.key = other.key() }},
		{"间隔太长", song, func(p *poller, r *sessionResumeFile) {
			r.SavedAt = at(0).Add(-nullResumeGraceWindow - time.Second).UnixMilli()
		}},
		{"重新起播", song, func(p *poller, r *sessionResumeFile) { p.app.marks.playSeq = 8 }},
		{"App 换了进程", song, func(p *poller, r *sessionResumeFile) { p.app.marks.pid = 43 }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p := resumePoller(t, song, other)
			r := resumeRecord(song, at, 70, 60, 60, true)
			c.edit(p, r)
			p.resume = r
			first := c.first
			first.Position, first.AnchorTS = 65, at(0)
			handleTick(p, at(0), first)
			if p.sess.listenSent || p.sess.playedSecs != 0 || !p.sess.startedAt.Equal(at(0)) {
				t.Fatalf("不该续接: sent=%v played=%v started=%v", p.sess.listenSent, p.sess.playedSecs, p.sess.startedAt)
			}
			if p.resume != nil {
				t.Error("没用上也只给第一次开的会话,之后作废")
			}
		})
	}
}

// 退出时记、启动时读回并删掉;当前会话不是 App 报的那一首时不记。
func TestSessionResumeSaveAndTake(t *testing.T) {
	saved := sessionResumePath
	sessionResumePath = filepath.Join(t.TempDir(), "session-resume.json")
	t.Cleanup(func() { sessionResumePath = saved })
	at := handleClock()
	song := handleSong("浮夸", 0, time.Time{})
	p := resumePoller(t, song)
	handleTick(p, at(0), handleSong("浮夸", 0, at(0)))
	handleTick(p, at(10), handleSong("浮夸", 10, at(10)))
	p.sess.listenSent = true
	p.saveSessionResume(at(11))
	r := takeSessionResume(sessionResumePath)
	if r == nil || r.Key != song.key() || r.AppPID != 42 || r.PlaySeq != 7 || r.PlayedSecs != 10 || !r.ListenSent ||
		r.StartedAt != at(0).Unix() || r.LastSeenAt != at(10).UnixMilli() || r.LastSeenPos != 10 || r.SavedAt != at(11).UnixMilli() {
		t.Fatalf("读回的记录不对: %+v", r)
	}
	if _, err := os.Stat(sessionResumePath); !os.IsNotExist(err) {
		t.Error("读回之后该删掉文件")
	}
	p.app.marks.key = "别的歌"
	p.saveSessionResume(at(12))
	if _, err := os.Stat(sessionResumePath); !os.IsNotExist(err) {
		t.Error("当前会话不是 App 报的那一首时不该记")
	}
}

// 退出兜底:过了门槛还没提交的那一首当场提交,记下的续接状态是「已提交」—— 重启后续接回来不会再提交一次。
func TestFlushSessionOnExitRecordsListenSent(t *testing.T) {
	saved := sessionResumePath
	sessionResumePath = filepath.Join(t.TempDir(), "session-resume.json")
	t.Cleanup(func() { sessionResumePath = saved })
	at := handleClock()
	song := handleSong("浮夸", 0, time.Time{})
	p := resumePoller(t, song)
	handleTick(p, at(0), handleSong("浮夸", 0, at(0)))
	p.sess.submitting = true // 活路径那次提交还在飞:drainSubmitsOnExit 不管当前会话,由兜底同步再交一次
	p.sess.playedSecs = 150
	p.exitFlushCtx = context.Background()
	p.flushSessionOnExit(p.exitFlushCtx)
	r := takeSessionResume(sessionResumePath)
	if r == nil || !r.ListenSent || !r.LastfmSettled {
		t.Fatalf("退出兜底交过了,记下的该是已提交: %+v", r)
	}
}
