package main

import (
	"net/http"
	"testing"
	"time"
)

// 2026-08-25 实测坐实:ListenBrainz 持续 429(收听记录已经过了 2.5 小时都是同一个错)
// 时,submit() 原来的 tries/退避只管一次调用内的几次重试——poller.go 四个调用点(Mac
// 原生 single/playing_now、桥接 iPhone single/playing_now)各自独立按自己的节奏发起
// 新一轮 submit,互相不知道对方也在被拒,合起来对一个持续故障的服务器反而在加压,
// 而且每一次失败的 single 在歌换下一首之后就没有下一次重试机会了——真的会丢收听记录。
// 这组用例钉住跨调用的退避状态机(coolingDown/noteOutcome),不碰真实网络。
func TestLbCooldownEscalatesOnRepeated429(t *testing.T) {
	c := &lbClient{}

	if c.coolingDown() {
		t.Fatal("初始状态不该在冷却中")
	}

	// 第 1 次整轮都 429:进入冷却
	c.noteOutcome(false, http.StatusTooManyRequests)
	if !c.coolingDown() {
		t.Fatal("第一次 429 后应该立刻进入冷却")
	}
	first := c.cooldownUntil

	// 冷却"过期"后(手动往回拨,不真的睡)再报一次 429:冷却时长应该更长(指数升级),
	// 不是每次都回到同一个起点。
	c.mu.Lock()
	c.cooldownUntil = time.Time{}
	c.mu.Unlock()
	c.noteOutcome(false, http.StatusTooManyRequests)
	second := c.cooldownUntil
	if !second.After(first) {
		t.Fatalf("第二次连续 429 的冷却期限应该比第一次晚(指数升级),first=%v second=%v", first, second)
	}

	// 升级要封顶,不能无限涨到"几乎永远不重试"。
	c.mu.Lock()
	c.consecutive429 = 1000
	c.mu.Unlock()
	c.noteOutcome(false, http.StatusTooManyRequests)
	capped := time.Until(c.cooldownUntil)
	maxSchedule := lbCooldownSchedule[len(lbCooldownSchedule)-1]
	if capped > maxSchedule+time.Second {
		t.Fatalf("冷却时长应该封顶在 %v 附近,实际 %v", maxSchedule, capped)
	}
}

func TestLbCooldownClearsOnSuccess(t *testing.T) {
	c := &lbClient{}
	c.noteOutcome(false, http.StatusTooManyRequests)
	if !c.coolingDown() {
		t.Fatal("429 后应该在冷却中")
	}
	c.noteOutcome(true, http.StatusOK)
	if c.coolingDown() {
		t.Fatal("成功一次之后冷却应该清零,不能继续挡后面的请求")
	}
	c.mu.Lock()
	consecutive := c.consecutive429
	c.mu.Unlock()
	if consecutive != 0 {
		t.Fatalf("成功后 consecutive429 应该清零,实际 %d", consecutive)
	}
}

// ⚠️ 非 429 的失败(超时/5xx/网络错误)不该升级这套专用冷却——那是另一类问题,
// 用 429 的退避去惩罚它治不了,也不该让"网络抖了一下"连累后面正常的请求。
func TestLbCooldownIgnoresNon429Failures(t *testing.T) {
	c := &lbClient{}
	c.noteOutcome(false, http.StatusInternalServerError)
	if c.coolingDown() {
		t.Fatal("非 429 失败不该触发冷却")
	}
	c.noteOutcome(false, 0) // 网络层错误,status 拿不到值
	if c.coolingDown() {
		t.Fatal("网络层错误(status=0)不该触发冷却")
	}
}
