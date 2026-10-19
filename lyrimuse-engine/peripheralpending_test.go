package main

import (
	"encoding/json"
	"testing"
	"time"
)

// 外围待补(PeripheralPending)的条目不等节流:提前提交上屏后进程就退了,重启后第一次碰到就该补,
// 不能按 TS 再等 enrichPeripheralRetryInterval。见 09 章决策 249。
func TestPeripheralPendingSkipsThrottle(t *testing.T) {
	savedRelay := webRelayURL
	defer func() { webRelayURL = savedRelay }()
	webRelayURL = ""

	fresh := enrichEntry{Lyrics: bt("[00:01.00]x"), TS: time.Now().Unix()}
	if peripheralBackfillThrottleElapsed(fresh) {
		t.Fatal("刚写下、没有待补标记的条目应该还在节流里")
	}
	if needsPeripheralBackfill(fresh, "Leehom Wang", "Open Fire") {
		t.Fatal("刚写下、没有待补标记的条目不该立刻补")
	}

	pending := fresh
	pending.PeripheralPending = true
	if !peripheralBackfillThrottleElapsed(pending) {
		t.Fatal("外围待补的条目应该跳过节流")
	}
	if !needsPeripheralBackfill(pending, "Leehom Wang", "Open Fire") {
		t.Fatal("外围待补、缺 canonical 和链接的条目应该立刻补")
	}

	capped := pending
	capped.PeripheralRetryCount = peripheralBackfillMaxAttempts
	if needsPeripheralBackfill(capped, "Leehom Wang", "Open Fire") {
		t.Fatal("待补标记不越过次数上限")
	}
}

// 后台补封面那一遍同样认待补标记:没被播到的预取条目(同专辑的下一首)重启后也能在第一遍里补上。
func TestCoverSweepTakesPeripheralPending(t *testing.T) {
	key := "Leehom Wang|Wei Yi|Open Fire [Clean]"
	e := enrichEntry{Lyrics: bt("[00:01.00]x"), TS: time.Now().Unix()}
	if coverSweepEligibleLocked(key, e) {
		t.Fatal("刚写下、没有待补标记的条目这一遍不补")
	}
	e.PeripheralPending = true
	if !coverSweepEligibleLocked(key, e) {
		t.Fatal("外围待补、没封面的条目这一遍该补")
	}
}

// 标记要能存下来:进程退出后靠缓存文件里的这一位接着补。
func TestPeripheralPendingPersists(t *testing.T) {
	data, err := json.Marshal(enrichEntry{PeripheralPending: true})
	if err != nil {
		t.Fatal(err)
	}
	var back enrichEntry
	if err := json.Unmarshal(data, &back); err != nil {
		t.Fatal(err)
	}
	if !back.PeripheralPending {
		t.Fatalf("peripheral_pending 没有存下来: %s", data)
	}
	if _, ok := songEntityFieldClasses["peripheral_pending"]; !ok {
		t.Fatal("peripheral_pending 要在 songEntityFieldClasses 里登记")
	}
}
