package main

import (
	"encoding/json"
	"log"
	"os"
	"time"
)

// 引擎重启时正在放的那一首接着计时。
//
// 引擎重启(装机、改设置 kickstart、崩溃拉起)时 App 和播放器都没停,但新进程第一拍会把这首当成刚开播:startedAt 记成
// 此刻、已播时长从零算。退出兜底只提交已经过了门槛的(run 里那段 flush),前后两段各自都没到门槛、合起来够的那次
// 收听两边都不记;前一段已经记过的,后一段要是自己又放够了门槛,还会以新的开播时刻再记一次。
//
// 退出时把当前会话记一份(saveSessionResume):会话键、App 的 app_pid / play_seq、开播时刻、已播时长、收听提交过没有、
// Last.fm 那一路发过没有 / 还挂着没有、最近一拍的位置。新进程第一次开会话时(handle 的换曲分支)这一首还是同一首、
// App 进程和 play_seq 都没变(同一次起播,不是重新放了一遍)、离退出不到 nullResumeGraceWindow,就照 recentFinalized
// 那样接着这次收听:开播时刻、已播时长、两路是否发过都带过来,中间那段空档按 App 报的位置补(listenAccrualSecs)。
// 别的情况一律另开会话,跟没有这份记录时一样。
//
// 不会重复上送:收听提交过的(listenSent,含退出兜底那一刻交给 LB 或待重发队列的)续接回来不再提交;Last.fm 发过的
// (lastfmSettled)不再发,还挂着的照原来的开播时刻接着等 scrobble 时点。开播时刻沿用原值,Last.fm 那一路的 uts
// 守卫(lfmMirrored)和 ListenBrainz 按 listened_at 去重也还认得是同一次。见 12 章决策 89。
//
// 文件只读一次:新进程读到就删,不管用没用上。
var sessionResumePath string

type sessionResumeFile struct {
	Key           string  `json:"key"`
	AppPID        int     `json:"app_pid"`
	PlaySeq       int64   `json:"play_seq"`
	StartedAt     int64   `json:"started_at"` // Unix 秒
	PlayedSecs    float64 `json:"played_secs"`
	ListenSent    bool    `json:"listen_sent"`
	LastfmSettled bool    `json:"lastfm_settled"`
	LastfmPending bool    `json:"lastfm_pending"`
	// LastSeen*:计时起点(playSession.lastSeen 那三项),LastSeenAt 为 0 = 没在计时(暂停着)。LastPos*:「曲终」档的位置书签。
	LastSeenAt     int64   `json:"last_seen_at,omitempty"` // Unix 毫秒
	LastSeenPos    float64 `json:"last_seen_pos,omitempty"`
	LastSeenHasPos bool    `json:"last_seen_has_pos,omitempty"`
	LastPos        float64 `json:"last_pos,omitempty"`
	LastPosAt      int64   `json:"last_pos_at,omitempty"` // Unix 毫秒
	SavedAt        int64   `json:"saved_at"`              // Unix 毫秒
}

// saveSessionResume 在退出兜底跑完之后调:当前会话还是 App 报的那一首时记下来。写失败只记日志(代价是这首从零计时)。
func (p *poller) saveSessionResume(now time.Time) {
	s := p.sess
	if sessionResumePath == "" || s == nil || p.app == nil || p.app.marks.pid == 0 || p.app.marks.key != s.key {
		return
	}
	f := sessionResumeFile{Key: s.key, AppPID: p.app.marks.pid, PlaySeq: p.app.marks.playSeq, StartedAt: s.listenStart().Unix(),
		PlayedSecs: s.playedSecs, ListenSent: s.listenSent, LastfmSettled: s.lastfmSettled, LastfmPending: s.lastfmPending != nil,
		SavedAt: now.UnixMilli()}
	if !s.lastSeen.IsZero() {
		f.LastSeenAt, f.LastSeenPos, f.LastSeenHasPos = s.lastSeen.UnixMilli(), s.lastSeenPos, s.lastSeenHasPos
	}
	if !s.lastPosAt.IsZero() {
		f.LastPos, f.LastPosAt = s.lastPos, s.lastPosAt.UnixMilli()
	}
	data, err := json.Marshal(f)
	if err != nil {
		return
	}
	if err := writeFileAtomic(sessionResumePath, data); err != nil {
		warnf("session resume: save failed (%v), the current track restarts its listen timer after the restart", err)
	}
}

// takeSessionResume 读回上次退出时记的会话并删掉文件;没有、坏了返回 nil。
func takeSessionResume(path string) *sessionResumeFile {
	if path == "" {
		return nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		noteFileErr("read", path, err)
		return nil
	}
	if err := os.Remove(path); err != nil {
		noteFileErr("remove", path, err)
	}
	var f sessionResumeFile
	if err := json.Unmarshal(data, &f); err != nil || f.Key == "" || f.StartedAt <= 0 || f.SavedAt <= 0 {
		return nil
	}
	return &f
}

// resumeSession:新进程第一次开会话时,s 是刚建的这一首,符合续接条件就把上次退出时的状态接上。不管接没接上,
// 记录都用掉了(只给第一次开的会话用)。接上了返回 true,调用方不再按新开播处理计时起点。
func (p *poller) resumeSession(s *playSession, now time.Time) bool {
	r := p.resume
	p.resume = nil
	if r == nil || p.app == nil {
		return false
	}
	savedAt := time.UnixMilli(r.SavedAt)
	gap := now.Sub(savedAt)
	if r.Key != s.key || r.AppPID != p.app.marks.pid || r.PlaySeq != p.app.marks.playSeq || p.app.marks.key != s.key ||
		gap < 0 || gap >= nullResumeGraceWindow {
		return false
	}
	s.startedAt = time.Unix(r.StartedAt, 0)
	if r.PlayedSecs > 0 {
		s.playStartedAt = s.startedAt
	}
	s.playedSecs = r.PlayedSecs
	s.listenSent, s.lastfmSettled = r.ListenSent, r.LastfmSettled
	if r.LastfmPending && !r.LastfmSettled && !s.lastfmExcluded {
		s.lastfmPending = &pendingLastfmListen{artistName: lbMeta(s.meta).ArtistName, meta: s.meta, startedAt: r.StartedAt}
	}
	if r.LastPosAt > 0 {
		s.lastPos, s.lastPosAt = r.LastPos, time.UnixMilli(r.LastPosAt)
	}
	// 计时起点接着上一个进程最后那一拍;空档里 App 一直在读播放器,这一拍的位置是新读到的:按位置补,不受
	// maxAccrualGapSecs 限制(同按住解除那一拍)。退出时暂停着(没在计时)的不补,这一拍起重新计。
	s.lastSeen = time.Time{}
	if r.LastSeenAt > 0 {
		s.lastSeen, s.lastSeenPos, s.lastSeenHasPos, s.gapHeld = time.UnixMilli(r.LastSeenAt), r.LastSeenPos, r.LastSeenHasPos, true
	}
	log.Printf("session resume: continuing %q from before the restart (played %.0fs, listen sent %v, gap %s)",
		s.key, r.PlayedSecs, r.ListenSent, gap.Round(time.Second))
	return true
}
