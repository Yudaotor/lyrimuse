// simevaltimeline_test.go — simeval 的追加维度:LRC↔YRC 时间轴自洽。
//
// 起因(2026-08-27《Rumour Has It》案)与完整机理见生产实现 lyricstimeline.go 的文件头。
// 这里只放**消融维度**,判据实现一律复用包内真实函数,不重抄(README 三条纪律之一:
// 维度实现与生产代码零漂移,才是这套评测区别于"另写一份打分"的全部价值)。
//
// 三种判据分开消融、各自扫阈值:
//
//	A endpointGate —— simeval_test.go 里 deltaWordTimingCoverage 自洽闸(b)的**单独**版本,
//	  只比 |YRC 末行 start − LRC 末句 start|。拆出来单独测是因为原维度是组合体(覆盖率
//	  阶梯 + 两道闸),混着测答不出"单独接这道闸值不值"。
//	  实测结论:**不能接**。15s 阈值下 36 条翻盘里 34 条是误杀 —— lastLRCTimestampSecs
//	  只跳空行、不跳署名行,网易云 LRC 末尾那行 `[08:36.866] 人声 : Prince` 让
//	  《Purple Rain》的端点差算出 292.4s,而两套轴对真实歌词行只差 0.2s。
//	B skewGate —— 逐行中位偏差(按归一化文本唯一配对)。判别力远高于 A:全库正常条目
//	  p95≈0.68s,而打架的条目在 3s 以上。3s 阈值 2 条翻盘、0 回归。
//	C richsyncGeneratedLRC —— 不治选源、治数据:直接把行级时间戳重挂到逐字轴上
//	  (rehangLRCOnYRC)。这条**不改打分逻辑,因此不需要 bump lyricsScoringVersion**。
//	  带闸版 2 条翻盘、0 回归,且《Rumour Has It》不翻盘 —— 它保住冠军、时间轴被修好,
//	  比 B 的"换成 kugou"更优。
//
// A/B 都只做**撤销逐字加分资格**(delta = −该候选实际拿到的 wordTiming 项分值),不新增
// 正分 —— 与既有维度同款保守口径:拿不准就放行,宁可漏杀不可错杀。
package main

import (
	"math"
	"sort"
)

// timelineSkewMedian: LRC 与 YRC 按归一化文本**唯一配对**后的逐行 |Δ| 中位数(秒)。
//
// ⚠️ 只用两侧各自都只出现一次的文本 —— 「Rumour has it」这种整首重复 20 次的句子根本
// 无法定位到具体是哪一句,计进去只是噪音。也正因如此不依赖两侧行数相等(署名行/空行/
// 合并行的存在使行数天然不等,按下标对齐会整体错位一格)。
//
// 配对数 < minPairs 时返回 ok=false = 拿不准,调用方一律放行(沿用 usableWordTiming 的
// 既有纪律:证据不足不动手)。
func timelineSkewMedian(lrc, yrc string, minPairs int) (median float64, pairs int, ok bool) {
	le := lrcEventsOf(lrc)
	ye := yrcLineHeads(yrc)
	if len(le) < minPairs || len(ye) < minPairs {
		return 0, 0, false
	}
	lby := map[string][]int{}
	for _, e := range le {
		if n := normTimelineText(e.text); n != "" {
			lby[n] = append(lby[n], e.ms)
		}
	}
	yby := map[string][]int{}
	for _, e := range ye {
		if n := normTimelineText(e.text); n != "" {
			yby[n] = append(yby[n], e.ms)
		}
	}
	var diffs []float64
	for n, lts := range lby {
		yts := yby[n]
		if len(lts) != 1 || len(yts) != 1 {
			continue
		}
		diffs = append(diffs, math.Abs(float64(lts[0]-yts[0]))/1000)
	}
	if len(diffs) < minPairs {
		return 0, len(diffs), false
	}
	sort.Float64s(diffs)
	mid := len(diffs) / 2
	if len(diffs)%2 == 1 {
		return diffs[mid], len(diffs), true
	}
	return (diffs[mid-1] + diffs[mid]) / 2, len(diffs), true
}

// wordTimingPointsOf: 该候选**实际**拿到的逐字项分值。写死 400 会在以后调权重时静默
// 失真,从 terms 里取。
func wordTimingPointsOf(ec *evalCand) int {
	return scoreTermPoints(ec.v2Terms, scoreTermWordTiming)
}

// deltaTimelineEndpointGate: 判据 A。delta = 命中闸 ? −wordTiming 项分值 : 0。
func deltaTimelineEndpointGate(thresholdSecs float64) func(tr *evalTrack, i int) int {
	return func(tr *evalTrack, i int) int {
		ec := tr.cands[i]
		wt := wordTimingPointsOf(ec)
		if wt <= 0 || ec.c.wordTimingYRC == "" || !ec.hasLast {
			return 0
		}
		st := parseYRCStats(ec.c.wordTimingYRC)
		if st.lastLineStartMs == 0 {
			return 0
		}
		if math.Abs(float64(st.lastLineStartMs)/1000-ec.last) > thresholdSecs {
			return -wt
		}
		return 0
	}
}

// deltaTimelineSkewGate: 判据 B。delta = 命中闸 ? −wordTiming 项分值 : 0。
func deltaTimelineSkewGate(thresholdSecs float64) func(tr *evalTrack, i int) int {
	return func(tr *evalTrack, i int) int {
		ec := tr.cands[i]
		wt := wordTimingPointsOf(ec)
		if wt <= 0 || ec.c.wordTimingYRC == "" {
			return 0
		}
		med, _, ok := timelineSkewMedian(ec.c.lyrics, ec.c.wordTimingYRC, 4)
		if !ok {
			return 0
		}
		if med > thresholdSecs {
			return -wt
		}
		return 0
	}
}

// deltaRichsyncLRCAt: 判据 C。直接调生产实现 rehangLRCOnYRC(lyricstimeline.go),
// 消融量的就是真代码。guardDuration 传 0 = 绕过那道"重挂后 durationFits 不许从 true
// 变 false"的安全闸,用来单独量闸本身值多少。
//
// delta = 新原始项和 − 旧原始项和(rawSum 口径,夹底交给 runAblation)。
func deltaRichsyncLRCAt(guarded bool) func(tr *evalTrack, i int) int {
	return func(tr *evalTrack, i int) int {
		ec := tr.cands[i]
		if ec.c.wordTimingYRC == "" {
			return 0
		}
		newLyrics, _, ok := rehangLRCOnYRC(ec.c.lyrics, ec.c.wordTimingYRC, tr.dur, guarded)
		if !ok {
			return 0
		}
		// 时长/共识判据是**跨候选**的,换了正文要连带重算,不能只重算自己那一项。
		batch := make([]lyricCandidate, len(tr.cands))
		for j := range tr.cands {
			batch[j] = tr.cands[j].c
		}
		batch[i].lyrics = newLyrics
		corro := corroboratedEndings(batch, tr.dur)
		peers := contentConsensusPeers(tr.la, tr.lt, batch, tr.dur)
		_, terms := scoreLyricCandidateDetailed(tr.la, tr.lt, tr.lal, tr.dur, batch[i], corro[batch[i].source], peers[batch[i].source])
		newRaw := 0
		for _, t := range terms {
			newRaw += t.Points
		}
		return newRaw - ec.rawSum
	}
}
