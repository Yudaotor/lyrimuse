package main

import (
	"os"
	"strings"
	"testing"
	"time"
)

func TestDurationVariantSteady(t *testing.T) {
	durationVariantSeen = map[string]durationVariantObs{}
	t0 := time.Unix(1_800_000_000, 0)
	const k = "赵雷|成都|成都"
	if durationVariantSteadyLocked(k, 226.2, t0) {
		t.Fatal("第一拍不该建")
	}
	if durationVariantSteadyLocked(k, 226.5, t0.Add(2*time.Second)) {
		t.Fatal("没满 4 秒不该建")
	}
	if !durationVariantSteadyLocked(k, 226.3, t0.Add(4*time.Second)) {
		t.Fatal("同一个时长连续满 4 秒该建")
	}
	if _, ok := durationVariantSeen[k]; ok {
		t.Fatal("建过之后要清掉记录")
	}
	// 换了个时长:重新计时
	durationVariantSteadyLocked(k, 226, t0)
	if durationVariantSteadyLocked(k, 30, t0.Add(5*time.Second)) {
		t.Fatal("时长换了要重新计时")
	}
	// 断流:重新计时
	durationVariantSeen = map[string]durationVariantObs{}
	durationVariantSteadyLocked(k, 226, t0)
	if durationVariantSteadyLocked(k, 226, t0.Add(20*time.Second)) {
		t.Fatal("两次观察隔太久要重新计时")
	}
	durationVariantSeen = map[string]durationVariantObs{}
}

// 接线:要另开的变体还空着时先过去抖,时长对上就清记录。
func TestDurationVariantSteadyIsWired(t *testing.T) {
	b, err := os.ReadFile("enrich.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, n := range []string{
		"if !rok && !durationVariantSteadyLocked(key, durationSecs, time.Now()) {\n\t\t\t\tenrichMu.Unlock()\n\t\t\t\treturn nil\n\t\t\t}",
		"} else {\n\t\t\tdelete(durationVariantSeen, key)\n\t\t}",
	} {
		if !strings.Contains(string(b), n) {
			t.Errorf("enrich.go 缺 %q", n)
		}
	}
}
