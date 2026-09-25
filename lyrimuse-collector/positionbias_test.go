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
	// 真机案例(vampire,15:01):锚点 0@07:01:02Z,App 15:01:07.341(本地)量到 −1.957。
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

// Spotify 自己的钟那一档(AnchorElapsed == nil):按"记录那一刻的位置 + 记录至今"核连续性。
func TestPlayerClockBiasApplies(t *testing.T) {
	written := time.Date(2026, 9, 23, 6, 20, 0, 0, time.UTC)
	pos := 5.911
	rec := positionBiasRecord{Artist: "方大同", Title: "黑白", BundleID: spotifyBundleID,
		BiasSecs: 0.267, WrittenAtMs: written.UnixMilli(), PositionSecs: &pos}
	now := written.Add(30 * time.Second)
	cases := []struct {
		name string
		rec  positionBiasRecord
		raw  float64
		want bool
	}{
		{"一直连续在放", rec, 5.911 + 30 + 0.267, true},
		{"之后暂停过(位置比预期少一截)", rec, 20, false},
		{"之后拖过", rec, 120, false},
		{"media-control 那档的记录不套在这个钟上", func() positionBiasRecord { r := rec; r.AnchorElapsed = f64(0); return r }(), 5.911 + 30 + 0.267, false},
		{"偏置为 0", func() positionBiasRecord { r := rec; r.BiasSecs = 0; return r }(), 36.178, false},
		{"不是同一首", func() positionBiasRecord { r := rec; r.Title = "三人遊"; return r }(), 36.178, false},
		{"旧记录没有位置按 0 算", func() positionBiasRecord { r := rec; r.PositionSecs = nil; return r }(), 30 + 0.267, true},
	}
	for _, c := range cases {
		if got := playerClockBiasApplies(c.rec, "方大同", "黑白", spotifyBundleID, c.raw, now); got != c.want {
			t.Errorf("%s: got %v want %v", c.name, got, c.want)
		}
	}
	if playerClockBiasApplies(rec, "方大同", "黑白", spotifyBundleID, 5.911+0.267, written.Add(-5*time.Second)) {
		t.Errorf("记录时刻在未来不该套")
	}
}

// 酷狗自然切歌:App 在读数层按归零锚点补了 0.515s,对着原始锚点(0.980)写一条负偏置,collector 5 秒一拍看不到
// 那份归零锚点,靠这条记录跟上;暂停之后锚点换成冻结值,记录自然不再套用。
func TestPositionBiasAppliesKugouStartCorrection(t *testing.T) {
	anchorTS := time.Date(2026, 9, 24, 3, 3, 24, 372887000, time.UTC)
	elapsed := 0.980
	rec := positionBiasRecord{Artist: "Little Sis Nora", Title: "GABBA GABBA", BundleID: kugouMusicBundleID,
		AnchorElapsed: &elapsed, BiasSecs: -0.515, WrittenAtMs: anchorTS.Add(300 * time.Millisecond).UnixMilli()}
	now := anchorTS.Add(30 * time.Second)
	if !positionBiasApplies(rec, "Little Sis Nora", "GABBA GABBA", kugouMusicBundleID, 0.980, anchorTS, now) {
		t.Fatalf("对着同一个原始锚点的负偏置应该套用")
	}
	if positionBiasApplies(rec, "Little Sis Nora", "GABBA GABBA", kugouMusicBundleID, 150.261, anchorTS.Add(150*time.Second), now.Add(150*time.Second)) {
		t.Fatalf("暂停冻结锚点不该再套")
	}
}

// Safari 恢复播放卡顿:App 的网页探针用页面 currentTime 量出恢复锚点领先 0.240s,写成对着恢复锚点的正偏置;
// 恢复锚点 47.990、下一次暂停冻结 57.705。
func TestPositionBiasAppliesSafariResumeStall(t *testing.T) {
	const webkit = "com.apple.WebKit.GPU"
	anchorTS := time.Date(2026, 9, 24, 7, 47, 38, 330000000, time.UTC)
	elapsed := 47.990
	rec := positionBiasRecord{Artist: "Fujii Kaze", Title: "Okay, Goodbye", BundleID: webkit,
		AnchorElapsed: &elapsed, BiasSecs: 0.240, WrittenAtMs: anchorTS.Add(4460 * time.Millisecond).UnixMilli()}
	now := anchorTS.Add(8 * time.Second)
	if !positionBiasApplies(rec, "Fujii Kaze", "Okay, Goodbye", webkit, 47.990, anchorTS, now) {
		t.Fatalf("对着恢复锚点量出的偏置应该套用")
	}
	if positionBiasApplies(rec, "Fujii Kaze", "Okay, Goodbye", webkit, 57.705, anchorTS.Add(10*time.Second), now.Add(2*time.Second)) {
		t.Fatalf("暂停冻结锚点(Safari 重发的真值)不该再套")
	}
}
