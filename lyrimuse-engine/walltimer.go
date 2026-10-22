package main

import "time"

// wallTimerStep:wallTimer 每次最多睡多久就醒来对一次墙钟。
const wallTimerStep = 5 * time.Minute

// wallTimer:按墙钟到点的定时器,给按小时、按天的后台循环用。time.Timer 走 Go 的单调时钟,darwin 上它在系统睡眠时不走
// (15 章决策 69),每天合盖大半天的话「每 24 小时一次」会拖成两三天一次。这里一次最多睡 wallTimerStep,醒来按墙钟判到没到。
// 用法:select 里等 C,收到之后 Due(time.Now()) 为假就接着等,为真再干活、干完 Reset。
type wallTimer struct {
	C   <-chan time.Time
	t   *time.Timer
	due time.Time
}

func newWallTimer(d time.Duration) *wallTimer {
	t := time.NewTimer(min(d, wallTimerStep))
	return &wallTimer{C: t.C, t: t, due: time.Now().Round(0).Add(d)}
}

// Due:C 刚收到一次之后调。墙钟到点了返回 true(调用方干完活再 Reset);没到就按剩下的时间再睡一段,返回 false。
func (w *wallTimer) Due(now time.Time) bool {
	left := w.due.Sub(now.Round(0))
	if left <= 0 {
		return true
	}
	w.t.Reset(min(left, wallTimerStep))
	return false
}

// Reset:从现在起 d 之后到点。只在 C 已经收过(Due 返回 true 之后)时调。
func (w *wallTimer) Reset(d time.Duration) {
	w.due = time.Now().Round(0).Add(d)
	w.t.Reset(min(d, wallTimerStep))
}

// Restart:不管 C 收没收过,从现在起 d 之后到点(先停掉、排空 C 再重设)。
func (w *wallTimer) Restart(d time.Duration) {
	if !w.t.Stop() {
		select {
		case <-w.t.C:
		default:
		}
	}
	w.Reset(d)
}

func (w *wallTimer) Stop() { w.t.Stop() }
