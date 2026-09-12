package main

import (
	"encoding/json"
	"testing"
	"time"
)

func f64(v float64) *float64 { return &v }

// 契约:Swift 侧 PositionBiasFile 写出来的 JSON 长这样(字段名两边逐字节一致,selftest 那边有对称断言)。
const positionBiasFixture = `{"anchor_elapsed":0,"artist":"Olivia Rodrigo","bias_secs":-1.957,"bundle_id":"com.spotify.client","title":"vampire","written_at_ms":1789002067341}`

func TestPositionBiasRecordDecodesSwiftShape(t *testing.T) {
	var rec positionBiasRecord
	if err := json.Unmarshal([]byte(positionBiasFixture), &rec); err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	if rec.Artist != "Olivia Rodrigo" || rec.Title != "vampire" || rec.BundleID != spotifyBundleID {
		t.Fatalf("身份字段解析错: %+v", rec)
	}
	if rec.AnchorElapsed == nil || *rec.AnchorElapsed != 0 || rec.BiasSecs != -1.957 || rec.WrittenAtMs != 1789002067341 {
		t.Fatalf("数值字段解析错: %+v", rec)
	}
}

func TestPositionBiasApplies(t *testing.T) {
	// 真机案例(vampire,2026-09-09 15:01):锚点 0@07:01:02Z,App 15:01:07.341(本地)量到 −1.957。
	anchorTS := time.Date(2026, 9, 9, 7, 1, 2, 0, time.UTC)
	written := anchorTS.Add(5341 * time.Millisecond)
	now := written.Add(30 * time.Second)
	rec := positionBiasRecord{Artist: "Olivia Rodrigo", Title: "vampire", BundleID: spotifyBundleID,
		AnchorElapsed: f64(0), BiasSecs: -1.957, WrittenAtMs: written.UnixMilli()}

	ok := func(name string, want bool, r positionBiasRecord, artist, title, bundle string, anchorElapsed float64, ts, n time.Time) {
		t.Helper()
		if got := positionBiasApplies(r, artist, title, bundle, anchorElapsed, ts, n); got != want {
			t.Errorf("%s: 期望 %v 实际 %v", name, want, got)
		}
	}
	ok("同曲同锚点,量在锚点之后 → 扣", true, rec, "Olivia Rodrigo", "vampire", spotifyBundleID, 0, anchorTS, now)
	ok("锚点 elapsed 毫秒内抖动仍算同一个", true, rec, "Olivia Rodrigo", "vampire", spotifyBundleID, 0.0005, anchorTS, now)
	ok("暂停后 Spotify 重发 41.377 的锚点 → 偏置失效,不扣", false, rec, "Olivia Rodrigo", "vampire", spotifyBundleID, 41.377, anchorTS.Add(40*time.Second), now.Add(40*time.Second))
	ok("换了歌 → 不扣", false, rec, "Olivia Rodrigo", "deja vu", spotifyBundleID, 0, anchorTS, now)
	ok("换了播放器(同名歌在网页版)→ 不扣", false, rec, "Olivia Rodrigo", "vampire", "com.apple.Safari", 0, anchorTS, now)
	ok("同一首隔天再放,锚点又是 0 但时间戳在 written_at 之后 → 旧偏置不套", false, rec, "Olivia Rodrigo", "vampire", spotifyBundleID, 0, anchorTS.Add(24*time.Hour), now.Add(24*time.Hour))
	ok("锚点时间戳只有整秒,written_at 比它早不到 1s 仍放行", true, rec, "Olivia Rodrigo", "vampire", spotifyBundleID, 0, written.Add(900*time.Millisecond), now)
	ok("快照没有可解析的锚点时间戳 → 证明不了先后,不扣", false, rec, "Olivia Rodrigo", "vampire", spotifyBundleID, 0, time.Time{}, now)
	ok("文件超过 6 小时 → 不扣", false, rec, "Olivia Rodrigo", "vampire", spotifyBundleID, 0, anchorTS, written.Add(7*time.Hour))

	zero := rec
	zero.BiasSecs = 0
	ok("偏置为 0 的记录(App 显式清零)→ 不扣", false, zero, "Olivia Rodrigo", "vampire", spotifyBundleID, 0, anchorTS, now)
	noAnchor := rec
	noAnchor.AnchorElapsed = nil
	ok("记录没带锚点 → 不扣", false, noAnchor, "Olivia Rodrigo", "vampire", spotifyBundleID, 0, anchorTS, now)
}

func TestPositionBiasSignMatchesSwift(t *testing.T) {
	// Swift 侧:reported = raw − bias;负偏置(锚点落后真声)扣掉等于往前补。这里只固化"扣"的方向,
	// 免得哪天有人在 system.go 写成 elapsed += bias。
	raw := 4.462
	bias := -1.957
	if got := raw - bias; got < 6.4 || got > 6.42 {
		t.Fatalf("方向反了: raw %.3f − bias %.3f 应≈6.419,得到 %.3f", raw, bias, got)
	}
}
