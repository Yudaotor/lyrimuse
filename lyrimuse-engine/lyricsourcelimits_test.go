package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

// 在途名额的通道容量按描述符的 MaxInflight 开:单独定了上限的源用它的,没定的、没登记的名字用默认值。
func TestLyricSourceSlotCapacityFollowsDescriptor(t *testing.T) {
	lyricSourceSlotsMu.Lock()
	saved := lyricSourceSlots
	lyricSourceSlots = map[string]chan struct{}{}
	lyricSourceSlotsMu.Unlock()
	t.Cleanup(func() {
		lyricSourceSlotsMu.Lock()
		lyricSourceSlots = saved
		lyricSourceSlotsMu.Unlock()
	})
	capped := 0
	for _, name := range append(append([]string{}, lyricSourceNames...), "not-registered") {
		want := lyricSourceInflightCaps[name]
		if want == 0 {
			want = lyricSourceInflightDefault
		} else {
			capped++
		}
		if got := cap(lyricSourceSlotsFor(name)); got != want {
			t.Errorf("%s:在途名额 %d 个,期望 %d", name, got, want)
		}
	}
	if capped != len(lyricSourceInflightCaps) || capped == 0 {
		t.Errorf("期望表里 %d 个单独定上限的源,只比到 %d 个", len(lyricSourceInflightCaps), capped)
	}
}

// 每日额度的剩余次数跨过这个源的留量那一下落盘(别的进程读同一份文件,要马上看到「剩得少」);在留量同一侧的变动不落盘。
func TestSourceDayQuotaSavedWhenCrossingItsReserve(t *testing.T) {
	resetSourceDayQuotaForTest(t)
	path := filepath.Join(t.TempDir(), sourceDayQuotaFileName)
	useSourceDayQuotaFile(path)
	saved := func() int {
		t.Helper()
		var onDisk map[string]sourceDayQuotaRecord
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(raw, &onDisk); err != nil {
			t.Fatal(err)
		}
		return onDisk[lyricSourceMegalobiz].Remaining
	}
	reserve := lyricSourceDayQuotaReserve(lyricSourceMegalobiz)
	// 重置时刻落在一个整点之后 200 秒,下面隔一秒的几次应答不会跨整点(跨整点另算一条落盘的理由)。
	now := time.Unix(1_800_000_000, 0)
	note := func(remaining int, at time.Time) {
		reset := strconv.Itoa(int(time.Unix(1_800_065_000, 0).Sub(at) / time.Second))
		noteSourceDayQuota(lyricSourceMegalobiz, 200, dayQuotaHeader("X-RateLimit-Remaining-Day", strconv.Itoa(remaining), "X-RateLimit-Reset-Day", reset), at)
	}
	note(reserve+50, now)
	if got := saved(); got != reserve+50 {
		t.Fatalf("头一次看到每日额度要落盘,盘上剩 %d", got)
	}
	note(reserve+10, now.Add(time.Second))
	if got := saved(); got != reserve+50 {
		t.Errorf("还在留量之上、没跨过去不落盘,盘上剩 %d", got)
	}
	note(reserve-1, now.Add(2*time.Second))
	if got := saved(); got != reserve-1 {
		t.Errorf("跨过留量 %d 要落盘,盘上剩 %d", reserve, got)
	}
}
