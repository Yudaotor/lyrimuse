package main

import (
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
