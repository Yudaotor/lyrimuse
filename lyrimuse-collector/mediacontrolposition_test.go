package main

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// mediaControlPositionSecs 把各条规则串起来:在播判定 → 外推 / 冻结 → 扣 App 写来的偏置 → 记住播放中位置。
// 各条规则自己的边界在各自的测试里;这里测的是接线(谁先谁后、改没改到 raw、偏置扣没扣、扣了几次)。

func approxSecs(a, b float64) bool { return math.Abs(a-b) < 0.0005 }

func TestMediaControlPositionPlayingUsesExtrapolation(t *testing.T) {
	now := time.Date(2026, 9, 25, 2, 0, 0, 0, time.UTC)
	raw := mediaControlRawState{BundleID: kugouMusicBundleID, Artist: "接线测试", Title: "在播外推",
		Duration: 240, ElapsedTime: 40, ElapsedTimeNow: 45.8, PlaybackRate: 1, Playing: true,
		Timestamp: now.Add(-5800 * time.Millisecond).Format(time.RFC3339Nano)}
	got, _ := mediaControlPositionSecs(&raw, now)
	if !approxSecs(got, 45.8) {
		t.Fatalf("播放中该用外推值 45.8,得到 %v", got)
	}
	if pos, ok := rememberedPlayingPosition("接线测试|在播外推"); !ok || !approxSecs(pos, 45.8) {
		t.Fatalf("播放中位置要记住(暂停规则用),得到 %v %v", pos, ok)
	}
}

// 酷狗单曲循环回到开头时报 playing:false、rate 仍是 1:这一拍要按在播外推,并把 raw.Playing 改成 true
// (下游 extract 读的是它)。
func TestMediaControlPositionKugouLoopCountsAsPlaying(t *testing.T) {
	anchor := time.Date(2026, 9, 24, 1, 55, 20, 0, time.UTC)
	now := anchor.Add(75 * time.Second)
	raw := mediaControlRawState{BundleID: kugouMusicBundleID, Artist: "张敬轩", Title: "灵魂相愿·接线",
		Duration: 300, ElapsedTime: 0, ElapsedTimeNow: 75, PlaybackRate: 1, Playing: false,
		Timestamp: "2026-09-24T01:55:20Z"}
	got, _ := mediaControlPositionSecs(&raw, now)
	if !raw.Playing {
		t.Fatal("循环中的 playing:false 要改成 true")
	}
	if !approxSecs(got, 75) {
		t.Fatalf("循环中按外推走,得到 %v", got)
	}
}

func TestMediaControlPositionPausedUsesFrozenValue(t *testing.T) {
	now := time.Date(2026, 9, 24, 2, 0, 0, 0, time.UTC)
	raw := mediaControlRawState{BundleID: kugouMusicBundleID, Artist: "张敬轩", Title: "灵魂相愿·真暂停",
		Duration: 300, ElapsedTime: 177.066, ElapsedTimeNow: 182.1, PlaybackRate: 0, Playing: false,
		Timestamp: now.Add(-5 * time.Second).Format(time.RFC3339Nano)}
	got, _ := mediaControlPositionSecs(&raw, now)
	if raw.Playing || !approxSecs(got, 177.066) {
		t.Fatalf("真暂停用冻结值 177.066、不改 Playing,得到 %v playing=%v", got, raw.Playing)
	}
}

// 锚点冻结的网页播放器(Arc 形态):暂停时报 0、锚点 187s 没刷新 → 用播放中最后一次位置,
// 而这个"最后位置"是同一个函数上一拍记下的。
func TestMediaControlPositionFrozenAnchorPauseFallsBackToLastPlaying(t *testing.T) {
	t0 := time.Date(2026, 9, 25, 3, 0, 0, 0, time.UTC)
	playing := mediaControlRawState{BundleID: "company.thebrowser.Browser", Artist: "接线测试", Title: "冻结锚点",
		Duration: 240, ElapsedTime: 0, ElapsedTimeNow: 187, PlaybackRate: 1, Playing: true,
		Timestamp: t0.Format(time.RFC3339)}
	if got, _ := mediaControlPositionSecs(&playing, t0.Add(187*time.Second)); !approxSecs(got, 187) {
		t.Fatalf("播放中外推 187,得到 %v", got)
	}
	paused := playing
	paused.Playing, paused.PlaybackRate, paused.ElapsedTimeNow = false, 0, 0
	if got, _ := mediaControlPositionSecs(&paused, t0.Add(188*time.Second)); !approxSecs(got, 187) {
		t.Fatalf("暂停时报 0 的冻结锚点要退回最后播放位置 187,得到 %v", got)
	}
}

func writeBiasRecordForTest(t *testing.T, rec positionBiasRecord) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "lyrimuse-position-bias.json")
	data, err := json.Marshal(rec)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	setPositionBiasPath(path)
	t.Cleanup(func() { setPositionBiasPath("") })
}

// Safari 恢复卡顿:App 用页面 currentTime 量出恢复锚点领先 0.24s、写进偏置文件;collector 的外推
// 对着同一个锚点就扣掉,并且记住的是扣过的位置。Safari 重发锚点之后(elapsed 变了)不再扣。
func TestMediaControlPositionAppliesAppBiasOnce(t *testing.T) {
	anchorTS := time.Date(2026, 9, 24, 7, 47, 38, 330000000, time.UTC)
	elapsed := 47.990
	writeBiasRecordForTest(t, positionBiasRecord{Artist: "Fujii Kaze", Title: "Okay, Goodbye·接线",
		BundleID: "com.apple.WebKit.GPU", AnchorElapsed: &elapsed, BiasSecs: 0.240,
		WrittenAtMs: anchorTS.Add(4460 * time.Millisecond).UnixMilli()})
	now := anchorTS.Add(8 * time.Second)
	raw := mediaControlRawState{BundleID: "com.apple.WebKit.GPU", Artist: "Fujii Kaze", Title: "Okay, Goodbye·接线",
		Duration: 231, ElapsedTime: elapsed, ElapsedTimeNow: elapsed + 8, PlaybackRate: 1, Playing: true,
		Timestamp: anchorTS.Format(time.RFC3339Nano)}
	got, _ := mediaControlPositionSecs(&raw, now)
	if !approxSecs(got, elapsed+8-0.240) {
		t.Fatalf("对着同一个锚点要扣 0.24 一次,期望 %.3f 得到 %.3f", elapsed+8-0.240, got)
	}
	if pos, _ := rememberedPlayingPosition("Fujii Kaze|Okay, Goodbye·接线"); !approxSecs(pos, got) {
		t.Fatalf("记住的播放位置要是扣过偏置的值,得到 %v", pos)
	}
	republishTS := anchorTS.Add(20 * time.Second)
	republished := raw
	republished.ElapsedTime, republished.ElapsedTimeNow = 67.75, 69.75
	republished.Timestamp = republishTS.Format(time.RFC3339Nano)
	if got, _ := mediaControlPositionSecs(&republished, republishTS.Add(2*time.Second)); !approxSecs(got, 69.75) {
		t.Fatalf("Safari 重发锚点之后不再扣,得到 %v", got)
	}
}
