package main

import (
	"math"
	"testing"
	"time"
)

// 「暂停时该报哪个位置」(2026-08-21)。样本全是真抓的:
//   - Arc(网页播放器,页面没调 setPositionState):elapsedTime 恒 0、timestamp 恒为开播
//     那一刻 → 一按暂停位置就归零,这是要修的那个 bug。
//   - QQ/网易云/Apple Music:暂停时会带新鲜时间戳重发一次 elapsedTime,那个值就是暂停位置
//     → 必须保持原样,一点都不能动。
func TestPausedPositionSecs(t *testing.T) {
	// ① Arc 形态:锚点 187 秒没刷新、报告值 0,而播放中最后一次位置是 187
	if got := pausedPositionSecs(0, 187, true, 187, true); got != 187 {
		t.Errorf("锚点冻结的源该用最后已知位置,得到 %v", got)
	}
	// ② 会刷新锚点的源:时间戳新鲜(0.3s),报告值就是暂停位置 —— 哪怕它比最后位置低
	//    (向后 seek 之后暂停),也必须照报
	if got := pausedPositionSecs(12, 0.3, true, 100, true); got != 12 {
		t.Errorf("锚点新鲜时必须原样用报告值(向后 seek 后暂停),得到 %v", got)
	}
	// ③ 正常暂停:两者只差一拍(≤2s),不该改写
	if got := pausedPositionSecs(99, 30, true, 100, true); got != 99 {
		t.Errorf("只差一拍不算冻结,得到 %v", got)
	}
	// ④ 没有"最后位置"可用(刚启动/刚换歌)→ 原样
	if got := pausedPositionSecs(0, 999, true, 0, false); got != 0 {
		t.Errorf("没有最后位置时原样返回,得到 %v", got)
	}
	// ⑤ 时间戳解不出来 → 不猜,原样
	if got := pausedPositionSecs(0, 0, false, 187, true); got != 0 {
		t.Errorf("拿不到锚点年龄时原样返回,得到 %v", got)
	}
	// ⑥ 边界:年龄正好在门槛上不算陈旧
	if got := pausedPositionSecs(0, staleAnchorAfterSecs, true, 187, true); got != 0 {
		t.Errorf("年龄等于门槛不算陈旧,得到 %v", got)
	}
	// ⑦ 边界:跌幅正好在门槛上不算冻结
	if got := pausedPositionSecs(100, 60, true, 100+frozenAnchorPauseDropSecs, true); got != 100 {
		t.Errorf("跌幅等于门槛不算冻结,得到 %v", got)
	}
}

func TestMediaControlAnchorAge(t *testing.T) {
	now := time.Date(2026, 8, 20, 19, 47, 16, 0, time.UTC)
	// media-control 实测的时间戳形态(无小数秒)
	age, ok := mediaControlAnchorAge("2026-08-20T19:44:16Z", now)
	if !ok || age != 180 {
		t.Errorf("age = %v ok = %v，期望 180 true", age, ok)
	}
	// 带小数秒的也要能解
	if _, ok := mediaControlAnchorAge("2026-08-20T19:44:16.500Z", now); !ok {
		t.Error("带小数秒的时间戳也该能解")
	}
	// 空/解不出来一律 false —— 调用方据此退回原样,不猜
	if _, ok := mediaControlAnchorAge("", now); ok {
		t.Error("空时间戳该返回 false")
	}
	if _, ok := mediaControlAnchorAge("不是时间戳", now); ok {
		t.Error("解不出来该返回 false")
	}
}

// 按曲目记位置:换歌必须自动作废,不然上一首的位置会漏到下一首头上。
func TestRememberedPlayingPositionIsPerTrack(t *testing.T) {
	t.Cleanup(func() {
		playingPositionMu.Lock()
		playingPositionKnown = false
		playingPositionTrack = ""
		playingPositionValue = 0
		playingPositionMu.Unlock()
	})
	rememberPlayingPosition("华晨宇|异类", 187.5)
	if v, ok := rememberedPlayingPosition("华晨宇|异类"); !ok || v != 187.5 {
		t.Errorf("同一首该取到 187.5,得到 %v %v", v, ok)
	}
	if _, ok := rememberedPlayingPosition("周杰伦|搁浅"); ok {
		t.Error("换歌之后不该取到上一首的位置")
	}
}

func TestPlayingPositionSecs(t *testing.T) {
	ts := time.Date(2026, 9, 6, 16, 40, 25, 0, time.UTC)
	tsStr := ts.Format(time.RFC3339)
	// rate 正常:信 media-control 自己的外推
	if got := playingPositionSecs(100, 130.4, 1, tsStr, ts.Add(30*time.Second)); got != 130.4 {
		t.Fatalf("rate>0 should use elapsedTimeNow, got %.3f", got)
	}
	// rate 缺失(恢复播放的实测形态):elapsedTimeNow 冻结,按 ts+0.5 自己补算。
	// 实测样本:锚点 172.994@:25(真实 :25.560),42.647s 后 Spotify 自己的钟 215.081;
	// 中点法给 215.141(差 0.06),改动前直接用整秒给 215.641(差 0.56)。
	got := playingPositionSecs(172.994, 172.994, 0, tsStr, ts.Add(42647*time.Millisecond))
	if want := 172.994 + 42.647 - 0.5; math.Abs(got-want) > 1e-6 {
		t.Fatalf("rate missing should extrapolate from ts+0.5: got %.3f want %.3f", got, want)
	}
	// 锚点还不到 0.5s 老:不倒推,原样用 elapsedTime
	if got := playingPositionSecs(50, 50, 0, tsStr, ts.Add(200*time.Millisecond)); got != 50 {
		t.Fatalf("young anchor should return elapsedTime, got %.3f", got)
	}
	// 时间戳缺失/解析失败:退回 elapsedTimeNow(跟改动前一致)
	if got := playingPositionSecs(50, 51, 0, "", ts); got != 51 {
		t.Fatalf("missing ts should fall back to elapsedTimeNow, got %.3f", got)
	}
	if got := playingPositionSecs(50, 51, 0, "garbage", ts); got != 51 {
		t.Fatalf("bad ts should fall back to elapsedTimeNow, got %.3f", got)
	}
}

func TestIsStaleAnchorRepublish(t *testing.T) {
	ts := time.Date(2026, 9, 6, 16, 40, 9, 0, time.UTC)
	last := &playingAnchor{track: "方大同|忘了美麗", elapsed: 10.477, ts: "T09", at: ts.Add(500 * time.Millisecond)}
	later := ts.Add(34500 * time.Millisecond)
	cases := []struct {
		name     string
		last     *playingAnchor
		track    string
		elapsed  float64
		ts       string
		duration float64
		now      time.Time
		want     bool
	}{
		{"实测样本: 同 elapsed 换时间戳", last, "方大同|忘了美麗", 10.477, "T43", 268.92, later, true},
		{"elapsed 变了是真锚点", last, "方大同|忘了美麗", 44.2, "T43", 268.92, later, false},
		{"同一个锚点不算重发", last, "方大同|忘了美麗", 10.477, "T09", 268.92, later, false},
		{"换歌不算", last, "方大同|南音", 10.477, "T43", 268.92, later, false},
		{"elapsed=0 不判(重头播放歧义)", &playingAnchor{track: "x|y", elapsed: 0, ts: "T00", at: ts}, "x|y", 0, "T44", 268.92, ts.Add(44 * time.Second), false},
		{"旧锚点越过曲长就信新锚点", last, "方大同|忘了美麗", 10.477, "T99", 268.92, ts.Add(270 * time.Second), false},
		{"无时长只看签名", last, "方大同|忘了美麗", 10.477, "T43", 0, later, true},
		{"没有上一个锚点不判", nil, "方大同|忘了美麗", 10.477, "T43", 268.92, later, false},
		{"时间戳为空不判", last, "方大同|忘了美麗", 10.477, "", 268.92, later, false},
	}
	for _, c := range cases {
		if got := isStaleAnchorRepublish(c.last, c.track, c.elapsed, c.ts, c.duration, c.now); got != c.want {
			t.Errorf("%s: got %v want %v", c.name, got, c.want)
		}
	}
}

func TestResolvePlayingAnchorTSKeepsOriginalOnRepublish(t *testing.T) {
	playingAnchorMu.Lock()
	lastPlayingAnchor, lastIgnoredRepublishTS = nil, ""
	playingAnchorMu.Unlock()
	t0 := time.Date(2026, 9, 6, 16, 40, 9, 0, time.UTC)
	ts0 := t0.Format(time.RFC3339)
	if got, rep := resolvePlayingAnchorTS("方大同|忘了美麗", 10.477, ts0, 268.92, t0.Add(600*time.Millisecond)); got != ts0 || rep {
		t.Fatalf("first anchor should be taken as is: got %s rep=%v", got, rep)
	}
	ts1 := t0.Add(34 * time.Second).Format(time.RFC3339)
	got, rep := resolvePlayingAnchorTS("方大同|忘了美麗", 10.477, ts1, 268.92, t0.Add(34500*time.Millisecond))
	if got != ts0 || !rep {
		t.Fatalf("republish should keep original ts: got %s rep=%v", got, rep)
	}
	// 命中后按原时间戳自己外推:10.477 + (97.7 − 0.5) ≈ 107.68,而不是按假时间戳的 73.75
	pos := playingPositionSecs(10.477, 73.752, 0, got, t0.Add(97700*time.Millisecond))
	if want := 10.477 + 97.7 - 0.5; math.Abs(pos-want) > 1e-6 {
		t.Fatalf("position should extrapolate from the original anchor: got %.3f want %.3f", pos, want)
	}
	// 真锚点(elapsed 变了)替换记录
	ts2 := t0.Add(60 * time.Second).Format(time.RFC3339)
	if got, rep := resolvePlayingAnchorTS("方大同|忘了美麗", 61.2, ts2, 268.92, t0.Add(60500*time.Millisecond)); got != ts2 || rep {
		t.Fatalf("genuine anchor should replace: got %s rep=%v", got, rep)
	}
}
