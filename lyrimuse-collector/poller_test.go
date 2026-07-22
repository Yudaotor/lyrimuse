// Command collector watches the macOS system now-playing state via
// AppleScript and submits playing_now / listen events to ListenBrainz.
package main

import (
	"testing"
	"time"
)

var baseTestTime = time.Date(2026, 7, 21, 12, 0, 0, 0, time.UTC)

// nowAt 返回一个固定基准时间往后推 offsetSecs 秒的时间点,避免测试里用真实 time.Now()
// (相邻两次 time.Now() 调用间隔是真实墙钟时间、不受控,会让 gap 计算失真)。
func nowAt(offsetSecs int) time.Time {
	return baseTestTime.Add(time.Duration(offsetSecs) * time.Second)
}

// 回归测试:AppleScript 换掉 media-control 之后,Music.playerPosition() 每轮轮询都是
// 新鲜的实时进度,不再像旧版 media-control 那样在稳定播放期间冻结。updatePosition()
// 里"是否需要重新锚定"的判断如果还用逐字节的 elapsed != prevElapse 比较,稳定播放时
// 每一轮都会被误判成一次 seek,导致 pushRelayState 每个轮询间隔就写一次 KV,足以烧穿
// 1000 写/天的免费额度。这里直接覆盖"稳定播放不应重锚"和"真实 seek 应该重锚"两个
// 分支,防止这个判断以后又被改回逐字节比较。
func TestUpdatePosition_SteadyPlaybackDoesNotReanchor(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "T", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 10, Rate: 1}
	if reanchor, _ := p.updatePosition(nowAt(0)); !reanchor {
		t.Fatalf("first observation should reanchor")
	}

	// 接下来连续 5 轮,每轮间隔 5 秒(= pollInterval),Elapsed 按真实播放时间正常前进——
	// 这正是 AppleScript 实时读法下,稳定播放时每一轮都会看到的样子。
	base := 10.0
	for i := 1; i <= 5; i++ {
		p.cur.Elapsed = base + float64(i)*5
		reanchor, _ := p.updatePosition(nowAt(i * 5))
		if reanchor {
			t.Fatalf("round %d: steady playback must not reanchor (elapsed=%v prevElapse=%v)", i, p.cur.Elapsed, p.prevElapse)
		}
	}
}

func TestUpdatePosition_RealSeekReanchors(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "T", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 10, Rate: 1}
	p.updatePosition(nowAt(0)) // seed first observation

	// 用户把进度条拖到了 90s——跟按 gap*rate 预测的 15s 差得远,必须重锚。
	p.cur.Elapsed = 90
	reanchor, _ := p.updatePosition(nowAt(5))
	if !reanchor {
		t.Fatalf("a real seek (10s -> 90s over one 5s poll) must reanchor")
	}
	if p.trackPos != 90 {
		t.Fatalf("trackPos should snap to the seeked-to position, got %v", p.trackPos)
	}
}

func TestUpdatePosition_PauseDoesNotReanchor(t *testing.T) {
	p := &poller{}
	p.cur = snapshot{Title: "T", Artist: "A", Album: "Alb", Duration: 200, Playing: true, Elapsed: 10, Rate: 1}
	p.updatePosition(nowAt(0))

	p.cur.Playing = false
	p.cur.Rate = 0
	// 暂停这个事件本身(以及暂停后位置冻结、多轮不动)都不该重锚——pushRelayState 那边
	// 靠 key 从 mac|X 变成 macpause|X 自己触发过一次写入,不需要 updatePosition 再帮它
	// 强制重写(见 poller.go 里 !p.cur.Playing 分支的注释)。
	for i := 1; i <= 4; i++ {
		reanchor, _ := p.updatePosition(nowAt(i * 5))
		if reanchor {
			t.Fatalf("round %d: paused must not reanchor", i)
		}
	}
}
