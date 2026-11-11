package main

// 动态封面从哪几处找(设置 › 歌词显示 › 歌词窗口 › 封面,「动态封面」下面那两项,可多选):Apple Music 一支,其余几支(QQ 音乐、
// 网易云、酷狗本机)合成一项。值跟 App 侧 MotionCoverSource 的 rawValue 逐字相同。见 03 章决策 71。
const (
	motionCoverSourceApple = "apple"
	motionCoverSourceOther = "other"
)

// resolveMotionCoverSources:文件里那份列表 → (找不找 Apple 那支, 找不找其余几支)。缺失 / 一个都认不得时两处都找。
func resolveMotionCoverSources(names []string) (apple, other bool) {
	for _, n := range names {
		switch n {
		case motionCoverSourceApple:
			apple = true
		case motionCoverSourceOther:
			other = true
		}
	}
	if !apple && !other {
		return true, true
	}
	return apple, other
}

// motionCoverSourcesKey:一条动态封面结论按哪组来源核的,记进条目的 MotionCoverSources。两处都找(默认)记空串,存量条目照旧算数。
func motionCoverSourcesKey(f featureFlags) string {
	switch {
	case f.MotionCoverSkipOther:
		return motionCoverSourceApple
	case f.MotionCoverSkipApple:
		return motionCoverSourceOther
	default:
		return ""
	}
}

// motionVerdictSourcesChanged:这条有动态封面结论,但不是按现在这组来源核的。播到时重核(trackEnrichment);后台补封面那一遍
// 不为它整库重来(coverSweepRecheckStaleMotion 只看 motionVerdictStale)。
func motionVerdictSourcesChanged(e enrichEntry) bool {
	return (e.MotionCoverChecked || e.MotionCoverURL != "") && e.MotionCoverSources != motionCoverSourcesKey(features())
}

// motionVerdictNone:可以找的几支都没给出动态封面。checked:有一支核出了「没有」(而不是根本没有可核的东西)—— 前者记「核过、没有」,
// 后者整组清掉。
func (e *enrichEntry) motionVerdictNone(checked bool) {
	if checked {
		e.recordMotionVerdict("", "", false)
	} else {
		e.clearMotionVerdict()
	}
}
