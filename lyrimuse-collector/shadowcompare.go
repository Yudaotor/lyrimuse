package main

import (
	"encoding/json"
	"log"
	"math"
	"os"
	"sort"
	"time"
)

// 影子对比:collector 照旧用自己读播放器得到的快照,同时读 App 写的播放状态(appstate.go),逐拍比对,
// 并按 App 状态**模拟**一遍收听会话、跟实际提交的收听逐条对。不改变任何行为;结果按播放器汇总写进
// lyrimuse-shadow-compare.json(跨重启累计,删掉文件即重新计),给「collector 改用 App 状态」之前判断差异用。
//
// 模拟会话的规则跟 handle() 一致:换曲 / 同一 App 进程内 play_seq 增加(单曲循环)开新会话;停播 60 秒内回到同一首
// 续接;在播且不在 holding 时按墙钟累计;累计到 listenThreshold 且不是广告、不是过短曲目就算一条收听。
type shadowHist struct {
	// 分档上界(秒):0.1 / 0.25 / 0.5 / 1 / 2 / 5,最后一档是 5 秒以上。
	Buckets [7]int `json:"buckets"`
}

var shadowHistBounds = [6]float64{0.1, 0.25, 0.5, 1, 2, 5}

func (h *shadowHist) add(v float64) {
	v = math.Abs(v)
	for i, b := range shadowHistBounds {
		if v < b {
			h.Buckets[i]++
			return
		}
	}
	h.Buckets[len(h.Buckets)-1]++
}

type shadowPlayerStats struct {
	Ticks              int `json:"ticks"`
	BothTracked        int `json:"both_tracked"`
	CollectorOnly      int `json:"collector_only"`
	AppOnly            int `json:"app_only"`
	IdentityMismatch   int `json:"identity_mismatch"`
	FixWindow          int `json:"fix_window"`
	PlayingMismatch    int `json:"playing_mismatch"`
	AdMismatch         int `json:"ad_mismatch"`
	RadioMismatch      int `json:"radio_mismatch"`
	MusicVideoMismatch int `json:"music_video_mismatch"`
	Holding            int `json:"holding"`
	// Settling:任一边刚换过歌、切过播放暂停、或位置刚重新对齐(shadowSettleWindow 内)的拍数。两边读播放器的
	// 时刻本来就差一两秒,这几拍的差异是时间差,不计入上面几项。
	Settling      int        `json:"settling"`
	PositionDelta shadowHist `json:"position_delta"`
	DurationDelta shadowHist `json:"duration_delta"`
}

type shadowSample struct {
	At        int64  `json:"at"`
	Kind      string `json:"kind"`
	Player    string `json:"player"`
	Collector string `json:"collector"`
	App       string `json:"app"`
}

type shadowListen struct {
	Key       string `json:"key"`
	StartedAt int64  `json:"started_at"`
	At        int64  `json:"at"`
}

type shadowListenStats struct {
	Matched       int            `json:"matched"`
	OnlyActual    int            `json:"only_actual"`
	OnlySimulated int            `json:"only_simulated"`
	Unmatched     []shadowListen `json:"unmatched,omitempty"`
}

type shadowReport struct {
	Since       int64                         `json:"since"`
	UpdatedAt   int64                         `json:"updated_at"`
	Ticks       int                           `json:"ticks"`
	Unavailable map[string]int                `json:"unavailable"`
	Players     map[string]*shadowPlayerStats `json:"players"`
	Listens     shadowListenStats             `json:"listens"`
	Samples     []shadowSample                `json:"samples"`
}

const (
	shadowSampleMax        = 40
	shadowUnmatchedMax     = 40
	shadowFlushInterval    = time.Minute
	shadowListenSettle     = 3 * time.Minute
	shadowListenStartSlack = 60 * time.Second
	shadowLogRepeatAfter   = 30 * time.Minute
	shadowPositionLogSecs  = 2.0
	shadowSettleWindow     = 10 * time.Second
	// collector 这一拍的位置比上一拍外推的跳出这么多,算它这边位置重新对齐了(拖动、重锚)。
	shadowCollectorJumpSecs = 2.0
	shadowLoggedMax         = 500
)

type shadowSession struct {
	key        string
	pid        int
	playSeq    int64
	startedAt  time.Time
	playedSecs float64
	lastSeen   time.Time
	duration   float64
	ad         bool
	counted    bool
}

type shadowCompare struct {
	path   string
	reader *appStateReader
	report shadowReport

	sess      *shadowSession
	recent    *shadowSession
	recentAt  time.Time
	simulated []shadowListen
	actual    []shadowListen
	lastFlush time.Time
	logged    map[string]time.Time

	// 两边最近一次换歌 / 切播放暂停 / 位置重新对齐的时刻,判「过渡期」用。
	colKey, appKey             string
	colPlaying, appPlaying     bool
	appAnchorSeq               int64
	colChangedAt, appChangedAt time.Time
	// collector 上一拍的位置与速率(暂停为 0);colPosAt 为零 = 上一拍没有位置。
	colPos, colRate float64
	colPosAt        time.Time
}

func newShadowCompare(reportPath string, reader *appStateReader, now time.Time) *shadowCompare {
	sc := &shadowCompare{path: reportPath, reader: reader, logged: map[string]time.Time{}}
	if raw, err := os.ReadFile(reportPath); err == nil {
		_ = json.Unmarshal(raw, &sc.report)
	}
	if sc.report.Since == 0 {
		sc.report.Since = now.Unix()
	}
	if sc.report.Unavailable == nil {
		sc.report.Unavailable = map[string]int{}
	}
	if sc.report.Players == nil {
		sc.report.Players = map[string]*shadowPlayerStats{}
	}
	if sc.report.Samples == nil {
		sc.report.Samples = []shadowSample{}
	}
	return sc
}

func (sc *shadowCompare) player(bundle string) *shadowPlayerStats {
	if bundle == "" {
		bundle = "(none)"
	}
	ps := sc.report.Players[bundle]
	if ps == nil {
		ps = &shadowPlayerStats{}
		sc.report.Players[bundle] = ps
	}
	return ps
}

// observe 比对这一拍:cur 是 collector 自己的快照(位置已按本拍算好),curTracked 是 isTracked(),
// curAd 是 collector 眼里这一首是不是广告。
func (sc *shadowCompare) observe(now time.Time, cur snapshot, curTracked, curAd bool) {
	if sc == nil || sc.reader == nil {
		return
	}
	rec, avail := sc.reader.read(now)
	sc.report.Ticks++
	usable := avail == appStateAvailable
	if w := sc.simulate(rec, usable, now); w != nil {
		sc.simulated = append(sc.simulated, *w)
	}
	bundle := cur.Bundle
	if !curTracked {
		bundle = rec.Player
	}
	ps := sc.player(bundle)
	ps.Ticks++
	if !usable {
		sc.report.Unavailable[string(avail)]++
		if curTracked {
			ps.CollectorOnly++
		}
		return
	}
	sc.classify(now, cur, curTracked, curAd, rec, ps)
}

// classify 把一拍可用的 App 状态跟 collector 的快照比,计入 ps 的对应一项。
func (sc *shadowCompare) classify(now time.Time, cur snapshot, curTracked, curAd bool, rec appStateRecord, ps *shadowPlayerStats) {
	bundle := cur.Bundle
	if !curTracked {
		bundle = rec.Player
	}
	if rec.Holding {
		ps.Holding++
	}
	appTracked := rec.hasTrack()
	settling := sc.noteChanges(now, cur, curTracked, rec)
	switch {
	case !curTracked && !appTracked:
		return
	case settling:
		ps.Settling++
		return
	case curTracked && !appTracked:
		ps.CollectorOnly++
		sc.sample(now, "collector_only", bundle, cur.key(), "", false)
		return
	case !curTracked && appTracked:
		ps.AppOnly++
		sc.sample(now, "app_only", bundle, "", rec.Track.key(), false)
		return
	}
	ps.BothTracked++
	t := rec.Track
	if cur.key() != t.key() {
		if rev := currentPlayerArtistFixRev(); rev > t.AppliedFixRev {
			ps.FixWindow++
		} else {
			ps.IdentityMismatch++
			sc.sample(now, "identity", bundle, cur.key(), t.key()+" raw="+t.Raw.Title+"|"+t.Raw.Artist+"|"+t.Raw.Album, true)
		}
		return
	}
	appPlaying := rec.State == "playing"
	if cur.Playing != appPlaying {
		ps.PlayingMismatch++
		sc.sample(now, "playing", bundle, boolWord(cur.Playing), boolWord(appPlaying), false)
	}
	if curAd != t.Ad {
		ps.AdMismatch++
		sc.sample(now, "ad", bundle, cur.key()+" ad="+boolWord(curAd), "ad="+boolWord(t.Ad), true)
	}
	if cur.Radio != (t.Radio != nil) {
		ps.RadioMismatch++
		sc.sample(now, "radio", bundle, cur.key()+" radio="+boolWord(cur.Radio), "radio="+boolWord(t.Radio != nil), true)
	}
	if cur.NotAudio != t.MusicVideo {
		ps.MusicVideoMismatch++
		sc.sample(now, "music_video", bundle, cur.key()+" mv="+boolWord(cur.NotAudio), "mv="+boolWord(t.MusicVideo), true)
	}
	if t.DurationSecs != nil && *t.DurationSecs > 0 && cur.Duration > 0 {
		ps.DurationDelta.add(cur.Duration - *t.DurationSecs)
	}
	if collectorPos, ok := shadowCollectorPosition(cur, now); ok && cur.Playing && appPlaying && rec.Position != nil {
		delta := collectorPos - rec.Position.at(now)
		ps.PositionDelta.add(delta)
		if math.Abs(delta) >= shadowPositionLogSecs {
			sc.sample(now, "position", bundle, cur.key(), "delta="+formatSecs(delta), true)
		}
	}
}

// shadowCollectorPosition:collector 快照的位置外推到 now(暂停不外推)。没有锚点时 ok=false。
func shadowCollectorPosition(cur snapshot, now time.Time) (float64, bool) {
	if cur.AnchorTS.IsZero() {
		return 0, false
	}
	if !cur.Playing {
		return cur.Position, true
	}
	return cur.Position + max(now.Sub(cur.AnchorTS).Seconds(), 0)*cur.Rate, true
}

// noteChanges 记下两边这一拍有没有换歌 / 切播放暂停 / 位置重新对齐,返回此刻是否还在过渡期里。
// 位置重新对齐:App 看 anchor_seq;collector 看这一拍的位置比上一拍外推的跳出 shadowCollectorJumpSecs 以上
// (它先看到拖动时,App 那份要到 App 下一拍才写出来)。
func (sc *shadowCompare) noteChanges(now time.Time, cur snapshot, curTracked bool, rec appStateRecord) bool {
	colKey := ""
	if curTracked {
		colKey = cur.key()
	}
	colPos, colPosOK := shadowCollectorPosition(cur, now)
	colPosOK = colPosOK && curTracked
	switch {
	case colKey != sc.colKey || cur.Playing != sc.colPlaying:
		sc.colKey, sc.colPlaying, sc.colChangedAt = colKey, cur.Playing, now
	case colPosOK && !sc.colPosAt.IsZero() &&
		math.Abs(colPos-(sc.colPos+now.Sub(sc.colPosAt).Seconds()*sc.colRate)) > shadowCollectorJumpSecs:
		sc.colChangedAt = now
	}
	sc.colPos, sc.colRate, sc.colPosAt = colPos, 0, time.Time{}
	if colPosOK {
		sc.colPosAt = now
		if cur.Playing {
			sc.colRate = cur.Rate
		}
	}
	appKey, appPlaying, anchorSeq := "", false, int64(0)
	if rec.hasTrack() {
		appKey, appPlaying = rec.Track.key(), rec.State == "playing"
	}
	if rec.Position != nil {
		anchorSeq = rec.Position.AnchorSeq
	}
	if appKey != sc.appKey || appPlaying != sc.appPlaying || anchorSeq != sc.appAnchorSeq {
		sc.appKey, sc.appPlaying, sc.appAnchorSeq, sc.appChangedAt = appKey, appPlaying, anchorSeq, now
	}
	return now.Sub(sc.colChangedAt) < shadowSettleWindow || now.Sub(sc.appChangedAt) < shadowSettleWindow
}

// simulate 按 App 状态推一遍收听会话,返回这一拍「按 App 状态会记下的一条收听」(没有为 nil)。
func (sc *shadowCompare) simulate(rec appStateRecord, usable bool, now time.Time) *shadowListen {
	if !usable || !rec.hasTrack() {
		return sc.endSession(now)
	}
	t := rec.Track
	key := t.key()
	duration := 0.0
	if t.DurationSecs != nil {
		duration = *t.DurationSecs
	}
	var ended *shadowListen
	loop := sc.sess != nil && sc.sess.key == key && sc.sess.pid == rec.AppPID && t.PlaySeq > sc.sess.playSeq
	if sc.sess == nil || sc.sess.key != key || loop {
		ended = sc.endSession(now)
		if !loop && sc.recent != nil && sc.recent.key == key && now.Sub(sc.recentAt) < nullResumeGraceWindow {
			sc.sess = sc.recent
		} else {
			sc.sess = &shadowSession{key: key, startedAt: now, duration: duration}
		}
		sc.recent = nil
	}
	s := sc.sess
	s.pid, s.playSeq = rec.AppPID, t.PlaySeq
	if s.duration <= 0 && duration > 0 {
		s.duration = duration
	}
	s.ad = s.ad || t.Ad || isAdBreak(rec.Player, t.Artist, t.Title, t.Album)
	if rec.State == "playing" && !rec.Holding {
		if !s.lastSeen.IsZero() {
			if d := now.Sub(s.lastSeen).Seconds(); d > 0 && d <= maxAccrualGapSecs {
				s.playedSecs += d
			}
		}
		s.lastSeen = now
	} else {
		s.lastSeen = time.Time{}
	}
	if w := sc.countIfDue(s, now); w != nil {
		return w
	}
	return ended
}

func (sc *shadowCompare) endSession(now time.Time) *shadowListen {
	if sc.sess == nil {
		return nil
	}
	s := sc.sess
	sc.sess = nil
	sc.recent, sc.recentAt = s, now
	s.lastSeen = time.Time{}
	return sc.countIfDue(s, now)
}

func (sc *shadowCompare) countIfDue(s *shadowSession, now time.Time) *shadowListen {
	if s.counted || s.playedSecs < listenThreshold(s.duration) || tooShortToScrobble(s.duration) {
		return nil
	}
	s.counted = true
	if s.ad {
		return nil
	}
	return &shadowListen{Key: s.key, StartedAt: s.startedAt.Unix(), At: now.Unix()}
}

// noteActualListen 记下一条实际要提交的收听(submitSingleAsync 过了广告与缺歌手两道闸之后调)。
func (sc *shadowCompare) noteActualListen(key string, startedAt, now time.Time) {
	if sc == nil {
		return
	}
	sc.actual = append(sc.actual, shadowListen{Key: key, StartedAt: startedAt.Unix(), At: now.Unix()})
}

// flush 把沉淀够久的收听逐条配对,并按 shadowFlushInterval 落盘汇总。
func (sc *shadowCompare) flush(now time.Time) {
	if sc == nil || now.Sub(sc.lastFlush) < shadowFlushInterval {
		return
	}
	sc.lastFlush = now
	sc.matchListens(now)
	sc.report.UpdatedAt = now.Unix()
	data, err := json.MarshalIndent(sc.report, "", "  ")
	if err != nil {
		return
	}
	if err := writeFileAtomic(sc.path, data); err != nil {
		log.Printf("shadow: report write failed: %v", err)
	}
}

// matchListens:两边各自沉淀满 shadowListenSettle 的收听,同一首、起点相差不超过 shadowListenStartSlack 即算对上。
func (sc *shadowCompare) matchListens(now time.Time) {
	settled := func(l shadowListen) bool { return now.Sub(time.Unix(l.At, 0)) >= shadowListenSettle }
	sort.Slice(sc.actual, func(i, j int) bool { return sc.actual[i].At < sc.actual[j].At })
	var keepActual []shadowListen
	for _, a := range sc.actual {
		matched := -1
		for i, s := range sc.simulated {
			if s.Key == a.Key && math.Abs(float64(s.StartedAt-a.StartedAt)) <= shadowListenStartSlack.Seconds() {
				matched = i
				break
			}
		}
		switch {
		case matched >= 0:
			sc.report.Listens.Matched++
			sc.simulated = append(sc.simulated[:matched], sc.simulated[matched+1:]...)
		case settled(a):
			sc.report.Listens.OnlyActual++
			sc.noteUnmatched(a, "actual")
		default:
			keepActual = append(keepActual, a)
		}
	}
	sc.actual = keepActual
	var keepSim []shadowListen
	for _, s := range sc.simulated {
		if settled(s) {
			sc.report.Listens.OnlySimulated++
			sc.noteUnmatched(s, "simulated")
		} else {
			keepSim = append(keepSim, s)
		}
	}
	sc.simulated = keepSim
}

func (sc *shadowCompare) noteUnmatched(l shadowListen, side string) {
	l.Key = side + ": " + l.Key
	sc.report.Listens.Unmatched = append(sc.report.Listens.Unmatched, l)
	if n := len(sc.report.Listens.Unmatched); n > shadowUnmatchedMax {
		sc.report.Listens.Unmatched = sc.report.Listens.Unmatched[n-shadowUnmatchedMax:]
	}
	log.Printf("shadow: listen only on the %s side: %q started %s", side, l.Key, time.Unix(l.StartedAt, 0).Format(time.RFC3339))
}

// sample 记一条差异样本;logIt 时同一对内容 shadowLogRepeatAfter 内只打一行日志。
func (sc *shadowCompare) sample(now time.Time, kind, player, collector, app string, logIt bool) {
	sig := kind + "\x00" + player + "\x00" + collector + "\x00" + app
	if last, ok := sc.logged[sig]; ok && now.Sub(last) < shadowLogRepeatAfter {
		return
	}
	if len(sc.logged) >= shadowLoggedMax {
		for k, at := range sc.logged {
			if now.Sub(at) >= shadowLogRepeatAfter {
				delete(sc.logged, k)
			}
		}
	}
	sc.logged[sig] = now
	sc.report.Samples = append(sc.report.Samples, shadowSample{At: now.Unix(), Kind: kind, Player: player, Collector: collector, App: app})
	if n := len(sc.report.Samples); n > shadowSampleMax {
		sc.report.Samples = sc.report.Samples[n-shadowSampleMax:]
	}
	if logIt {
		log.Printf("shadow: %s differs (%s): collector=%q app=%q", kind, player, collector, app)
	}
}

func boolWord(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

func formatSecs(v float64) string {
	return time.Duration(v * float64(time.Second)).Round(10 * time.Millisecond).String()
}
