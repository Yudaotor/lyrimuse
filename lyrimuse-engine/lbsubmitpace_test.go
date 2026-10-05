package main

import (
	"context"
	"reflect"
	"testing"
	"time"
)

// LB 挂着时 playing_now 按刷新间隔重发,不是每拍:发出去失败了等下一次刷新(pnTriedAt)。两条路都要守住:
// 挂起的首条(这首缓存里还没有,首条等歌词)和周期刷新(首条已经发成)。
func TestHandlePlayingNowWaitsForRefreshAfterFailure(t *testing.T) {
	for _, firstOK := range []bool{false, true} {
		at := handleClock()
		p := handleTestPoller(t, handleSong("浮夸", 0, at(0)))
		var sent []int
		for s := 0; s <= 150; s += 5 {
			handleTick(p, at(s), handleSong("浮夸", float64(s), at(s)))
			if !p.sess.announcing {
				continue
			}
			select {
			case r := <-p.announceDoneCh:
				r.ok = firstOK && len(sent) == 0 // 之后每一次都当 LB 挂着
				p.applyAnnounceOutcome(r)
			case <-time.After(3 * time.Second):
				t.Fatal("playing_now 的结果没回来")
			}
			sent = append(sent, s)
		}
		// 第 0 秒开会话、这首没缓存 → 首条挂起,pnPendingMax(8 秒)之后那一拍发出;之后每 playingNowRefresh 一次。
		if want := []int{10, 70, 130}; !reflect.DeepEqual(sent, want) {
			t.Errorf("首条成功=%v: playing_now 在第 %v 秒发出,应为 %v", firstOK, sent, want)
		}
	}
}

// 歌还在放时收听提交失败:按 listenRetrySchedule 隔开再试,不是每拍。
func TestHandleBacksOffListenRetries(t *testing.T) {
	at := handleClock()
	a := handleSong("浮夸", 0, at(0))
	p := handleTestPoller(t, a)
	threshold := int(listenThreshold(a.Duration))
	tick := func(s int) { handleTick(p, at(s), handleSong("浮夸", float64(s), at(s))) }
	fail := func(s int) {
		t.Helper()
		select {
		case r := <-p.submitDoneCh:
			r.err, r.doneAt = context.DeadlineExceeded, at(s)
			p.applySubmitOutcome(r)
		case <-time.After(3 * time.Second):
			t.Fatal("提交结果没回来")
		}
	}
	for s := 0; s <= threshold; s += 5 {
		tick(s)
	}
	sess := p.sess
	if !sess.submitting {
		t.Fatalf("到阈值该提交: played=%v", sess.playedSecs)
	}
	fail(threshold)
	var attempts []int
	for s := threshold + 5; s <= threshold+120; s += 5 {
		tick(s)
		if sess.submitting {
			attempts = append(attempts, s-threshold)
			fail(s)
		}
	}
	// 失败后 15 秒再试,再失败 30 秒,再失败 1 分钟。
	if want := []int{15, 45, 105}; !reflect.DeepEqual(attempts, want) {
		t.Errorf("重试发生在失败后第 %v 秒,应为 %v", attempts, want)
	}
	if sess.listenFailures != 4 || sess.listenSent {
		t.Errorf("failures=%d sent=%v", sess.listenFailures, sess.listenSent)
	}
	if got := listenRetryDelay(99); got != 2*time.Minute {
		t.Errorf("退避封顶 2 分钟: %v", got)
	}
}
