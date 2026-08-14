package main

import "testing"

// 同专辑预取的专辑名闸门:albumScore >= 100(宽松包含)。
//
// 这个阈值 2026-08-14 从 200 降到 100,原因是 200 会把"同一张专辑写法不同"全部挡掉。
// 下面每一条都是当时真实量到的分数,别凭印象改阈值 —— 想调之前先把这些跑一遍。
func TestAlbumPrefetchGate(t *testing.T) {
	const gate = 100

	// 必须放行:同一张专辑,只是写法不同。
	pass := []struct {
		candidate, local, why string
	}{
		{"神经志", "神經志 The Journal", "繁简 + 英文副标题(用户实测被 200 挡住的那张)"},
		{"黑色柳丁", "黑色柳丁", "完全相同"},
		{"Bad", "Bad", "完全相同"},
	}
	for _, c := range pass {
		if got := albumScore(c.candidate, c.local); got < gate {
			t.Errorf("应放行(%s): albumScore(%q, %q) = %d, 需要 >= %d",
				c.why, c.candidate, c.local, got, gate)
		}
	}

	// 必须拦下:名字跟本地专辑毫不沾边的合集/作品集。这些才是"一次性炸出上百个解析请求"
	// 的真实来源 —— 而它们天然就是 0 分,不需要把闸门抬到 200 去挡。
	reject := []struct{ candidate, local string }{
		{"King of Pop [Box set]", "Bad"},
		{"The Collection", "Bad"},
		{"Ultrasound 乐之路 1997-2003", "黑色柳丁"},
	}
	for _, c := range reject {
		if got := albumScore(c.candidate, c.local); got >= gate {
			t.Errorf("应拦下: albumScore(%q, %q) = %d, 应当 < %d",
				c.candidate, c.local, got, gate)
		}
	}

	// 已知会被放行的边界:同一张专辑的加长版。名字上跟"带副标题"分不开(都是 100),
	// 靠 albumPrefetchMaxTracks 兜底,不靠这道闸。
	if got := albumScore("Bad 25th Anniversary", "Bad"); got < gate {
		t.Errorf("加长版预期是 100 这一档(靠曲目数上限兜底), 实际 albumScore = %d", got)
	}
	if albumPrefetchMaxTracks > 30 {
		t.Errorf("曲目数上限放宽到 %d 了 —— 闸门降到 100 之后,这个上限是挡加长版/合集的唯一一道", albumPrefetchMaxTracks)
	}
}
