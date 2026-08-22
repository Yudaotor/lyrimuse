package main

import "testing"

// observeWrongDuration 的回归测试。
//
// 背景(2026-08-22 实测):换曲/预载窗口里 media-control 会把**下一首**的时长和当前曲目
// 的标题拼进同一份快照 ——「开不了口 (Live)」(272.973s)开播 6 秒后,relay 推送的快照
// 携带同专辑下一首「床边故事 (Live)」的 220.239s(逐位一致)。这个一次性脏观察值直接
// 喂给 durationMismatch 就白烧一轮升级重试、所有候选按错误时长吃 -700、决策记录被盖。
// 去抖规则:同一个脏值(±1s)持续满 wrongDurationConfirmSecs 才确认;时长又对上就清零;
// 换了个不同的脏值就重新计时;确认放行的同时清记录(下一轮要重新攒满)。
func TestObserveWrongDuration(t *testing.T) {
	reset := func() { wrongDurationSeen = map[string]wrongDurationObs{} }
	key := "周杰伦|开不了口 (Live)|周杰伦地表最强世界巡回演唱会 (Live)"

	t.Run("单次脏观察不确认", func(t *testing.T) {
		reset()
		if observeWrongDuration(key, true, 220.239, 1000) {
			t.Error("第一眼看到 mismatch 就放行,去抖等于没有")
		}
	})

	t.Run("窗口内同值仍不确认_攒满才放行_放行后重新计时", func(t *testing.T) {
		reset()
		observeWrongDuration(key, true, 220.239, 1000)
		if observeWrongDuration(key, true, 220.239, 1000+wrongDurationConfirmSecs-1) {
			t.Error("还差 1 秒没攒满窗口就放行了")
		}
		if !observeWrongDuration(key, true, 220.239, 1000+wrongDurationConfirmSecs) {
			t.Error("同值稳定满窗口该放行")
		}
		// 放行的同时应清掉记录:重试没换成时不能每次调用连发,把 3 次预算一口气烧光。
		if observeWrongDuration(key, true, 220.239, 1000+wrongDurationConfirmSecs+1) {
			t.Error("刚放行过一次,下一轮要重新攒满窗口")
		}
	})

	t.Run("换了个不同的脏值要重新计时", func(t *testing.T) {
		reset()
		observeWrongDuration(key, true, 220.239, 2000)
		if observeWrongDuration(key, true, 399.0, 2000+wrongDurationConfirmSecs) {
			t.Error("观察值变了(220→399),不是同一个稳定的 mismatch,不该放行")
		}
	})

	t.Run("时长又对上了就清零", func(t *testing.T) {
		reset()
		observeWrongDuration(key, true, 220.239, 3000)
		// 事故里的自愈路径:几秒后快照恢复,duration 重新匹配 resolved。
		observeWrongDuration(key, false, 272.973, 3005)
		if observeWrongDuration(key, true, 220.239, 3000+wrongDurationConfirmSecs+10) {
			t.Error("中途出现过匹配观察,之前攒的窗口该作废")
		}
	})

	t.Run("毫秒级抖动算同值", func(t *testing.T) {
		reset()
		observeWrongDuration(key, true, 220.239, 4000)
		if !observeWrongDuration(key, true, 220.9, 4000+wrongDurationConfirmSecs) {
			t.Error("±1s 内的抖动该算同一个观察值")
		}
	})

	t.Run("跨播放残留的陈旧记录要重新计时", func(t *testing.T) {
		reset()
		// 脏快照落在曲目**切出**侧(标题还是当前曲、时长已是下一首的)时,切歌后该 key
		// 再收不到清零观察,记录会一直残留(2026-08-22 审阅指出的复发路径)。
		observeWrongDuration(key, true, 220.239, 5000)
		// 一天后重放同曲、第一口又是同值脏观察:断流远超陈旧上限,必须重新计时,
		// 不能拿着昨天的 firstSeen 一步凑满窗口。
		if observeWrongDuration(key, true, 220.239, 5000+86400) {
			t.Error("陈旧记录直接放行,一次性串扰又能触发重试了")
		}
		if observeWrongDuration(key, true, 220.239, 5000+86400+wrongDurationConfirmSecs-1) {
			t.Error("重置后没攒满窗口就放行")
		}
		if !observeWrongDuration(key, true, 220.239, 5000+86400+wrongDurationConfirmSecs) {
			t.Error("重置后同值稳定满窗口该正常放行")
		}
	})

	t.Run("正常喂食间隔不算断流", func(t *testing.T) {
		reset()
		// 稳定播放期 trackEnrichment 的喂食来自 relay 心跳/LB 提交(≤4 分钟一次),
		// 陈旧上限必须盖过它 —— 卡 60 秒会把合法确认饿死(实际调用不是每拍 poll 都有)。
		observeWrongDuration(key, true, 220.239, 6000)
		if !observeWrongDuration(key, true, 220.239, 6000+240) {
			t.Error("4 分钟一次的心跳间隔被当成断流,合法的时长不匹配永远确认不了")
		}
	})

	t.Run("事故重放_一次性串扰不触发", func(t *testing.T) {
		reset()
		// 14:28:36 first-resolve 后,:37/:40 两次 relay 快照带着下一首的 220.239s,
		// 之后恢复 272.973s(匹配 resolved,mismatch=false)。旧逻辑在 :37 就放行了。
		if observeWrongDuration(key, true, 220.239, 1787380117) {
			t.Fatal("串扰第一眼就放行")
		}
		if observeWrongDuration(key, true, 220.239, 1787380120) {
			t.Fatal("串扰 3 秒内就放行")
		}
		observeWrongDuration(key, false, 272.973, 1787380127)
		if len(wrongDurationSeen) != 0 {
			t.Error("恢复匹配后观察记录该被清空")
		}
	})
}

// durationMismatch 的直接覆盖(原来搭在 needsLyricsRetry 的时长用例里,签名改掉后挪到这)。
func TestDurationMismatch(t *testing.T) {
	cases := []struct {
		name             string
		resolved, actual float64
		want             bool
	}{
		{"差 33% 算不匹配", 300, 200, true},
		{"完全一致", 272.973, 272.973, false},
		{"12% 以内的标注差异不算", 280, 273, false},
		{"resolved 缺失(老条目)不回溯", 0, 273, false},
		{"actual 缺失不可比", 273, 0, false},
	}
	for _, c := range cases {
		if got := durationMismatch(c.resolved, c.actual); got != c.want {
			t.Errorf("%s: durationMismatch(%v, %v) = %v, want %v", c.name, c.resolved, c.actual, got, c.want)
		}
	}
}
