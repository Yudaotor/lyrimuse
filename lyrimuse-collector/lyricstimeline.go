package main

import (
	"log"
	"sort"
	"strconv"
	"strings"
	"unicode"
)

// LRC↔YRC 时间轴自洽修复。
//
// 起因(2026-08-27,用户报《Rumour Has It》"明显进度对不上"):Musixmatch 在同一个
// track_id 下挂着两份**不同年份做的、互不兼容**的资产 —— track.subtitle.get 那份
// 行级 LRC(2023-01-29 制,自报 215s)与 track.richsync.get 那份逐字(2026-06-21 制,
// 自报 232s),曲长实际 223.3s。实调把两边原始 body 拉回来比 sha256,证实都是上游原样
// 落库、我们零清洗 —— 坏的是上游数据本身。
//
// 这份坏 LRC 单调递增、末句时间戳也正常(204.81s),坏只坏在**内部**:第 27→28 行凭空
// 跳 48.6 秒,第 41~49 行 9 句完整长句挤在 6.86 秒里(同样这 9 句在 richsync 里跨 46 秒)。
// 而引擎里所有与时间有关的判据(durationFits/corroboratedEndings/sourceDurationOff)
// **全都只看末句这一个标量**,25% 容差对这首歌意味着 167~228s 这个 61 秒宽的窗口全算
// "吻合" —— 端点判据在原理上就看不见这种坏法。
//
// 为什么是"修数据"而不是"改打分":
//
//	实测本机 86 条 musixmatch 双轴条目,LRC 与 YRC **逐行文本 100% 相同、行数 100% 相同**
//	—— subtitle.get 那一趟请求除了带回一份坏时间轴,没提供任何 richsync 没有的信息。
//	既然文本一一对应,直接把行级时间戳换成逐字轴的行起点即可,不必换源、不必动打分,
//	因此**不需要 bump lyricsScoringVersion**(全库不会被拖去重跑五源检索)。
//	反事实消融(784 首/3063 候选)结果:冠军翻盘 2 首、回归 0 首。
//
// 适用范围由判据自己划出来,不按源写死白名单:
//
//	musixmatch 86/86 满足前提(它的病就是"同一批行、两套时间");
//	kugou 710/714、qq 196/428 满足(它们本来就自洽,重挂是空操作);
//	netease 只有 24/568 满足 —— 它的两份是**根本不同的资产**(LRC 常带署名行、行数对不上),
//	对它重挂会挂错,判据会自动放弃。
//
// ⚠️ "以逐字轴为准"不是无条件成立的,必须带安全闸:消融过程中抓到反例
// MJ《Rock With You (Single Version)》—— 两套轴同样打架,但坏的是 **YRC** 那边,重挂后
// 末句从 176.1s 跳到 216.6s,而曲长只有 204.2s,歌词尾巴反而甩出曲目 12 秒。全库 516 条
// 可判时长的条目里正好有这么 1 条会被改坏,闸把它挡住了。

// yrcLineHead 是 YRC 一行的(行首毫秒, 该行词文本拼接)。
type yrcLineHead struct {
	ms   int
	text string
}

// yrcLineHeads 按**文档序**解析 YRC 的行(不排序:要与 LRC 的行顺序一一对应)。
//
// ⚠️ 抓词文本只能用"把词标记整体删掉、剩下的就是文本",不能用
// `\((\d+),(\d+),\d+\)([^(]*)` 这种"标记后面跟非左括号"的写法 —— 歌词正文里本来就有
// 字面左括号(和声/伴唱标注),`[^(]*` 会在它那里截断。实测《Rumour Has It》第 14 行
// `(59954,1182,0)(rumour)` 会被解析成空串,整行从 "Rumour has it (rumour)" 缩成
// "Rumour has it",于是与 LRC 侧字面对不上,本该重挂的条目被静默放弃。
func yrcLineHeads(yrc string) []yrcLineHead {
	if yrc == "" {
		return nil
	}
	var out []yrcLineHead
	for _, line := range strings.Split(yrc, "\n") {
		m := yrcLineTimeRegex.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		ms, err := strconv.Atoi(m[1])
		if err != nil {
			continue
		}
		body := yrcLineTimeRegex.ReplaceAllString(line, "")
		text := strings.TrimSpace(yrcWordTokenRe.ReplaceAllString(body, ""))
		if text == "" {
			continue
		}
		out = append(out, yrcLineHead{ms: ms, text: text})
	}
	return out
}

// normTimelineText 是配对用的归一化 —— 繁转简(实测有条目 LRC 繁体、YRC 简体,不归一化
// 配对数直接 0)、小写、只留字母/数字/汉字/假名(unicode.IsLetter 同时覆盖三者)。
func normTimelineText(s string) string {
	s = toSimplified(strings.ToLower(s))
	var b strings.Builder
	for _, r := range s {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// lrcStampMs 把 lrcTimestampCaptureRe 的一次匹配换算成毫秒。
// 小数位按位数解释:2 位是百分秒(xx→xx*10ms),3 位是毫秒。
func lrcStampMs(m []string) int {
	mm, _ := strconv.Atoi(m[1])
	ss, _ := strconv.Atoi(m[2])
	frac, _ := strconv.Atoi(m[3])
	ms := (mm*60 + ss) * 1000
	switch len(m[3]) {
	case 3:
		ms += frac
	default:
		ms += frac * 10
	}
	return ms
}

// formatLRCStamp 按仓库既有导出口径写 [mm:ss.xx]。
func formatLRCStamp(ms int) string {
	if ms < 0 {
		ms = 0
	}
	return "[" + twoDigits(ms/60000) + ":" + twoDigits((ms%60000)/1000) + "." + twoDigits((ms%1000)/10) + "]"
}

func twoDigits(n int) string {
	if n < 10 {
		return "0" + strconv.Itoa(n)
	}
	return strconv.Itoa(n)
}

// rehangLRCOnYRC 用逐字轴的行起点重挂行级 LRC 的时间戳。
//
// 返回(新 LRC, 旧毫秒→新毫秒映射, 是否真的改过)。映射给译文/罗马音复用 —— 它们的
// 时间戳是照原文 LRC 抄的(translate.go 的 assembleTranslationLRC / musixmatch.go 的
// buildTranslatedLRC),不跟着重挂就会相对正文错位。
//
// 前提(任一不满足就原样返回,不改):
//   - 两侧都解析得出 >=2 行;
//   - LRC 的内容行数与 YRC 行数相同,且**逐行**归一化文本相同;
//   - LRC 没有"一行挂多个时间戳"的行(那种行与 YRC 行不再一一对应);
//   - YRC 行起点严格非递减(乱序的逐字数据不能拿来当时间基准)。
//
// 安全闸:重挂后 durationFits 不允许从 true 变 false(见文件头 Rock With You 那例)。
// durationFits 本来就是仓库里"这份歌词长度对不对得上"的唯一权威(match.go),不新造判据。
//
// 幂等:时间戳本来就一致时返回 changed=false,重复跑是空操作。
func rehangLRCOnYRC(lrc, yrc string, durationSecs float64, guard bool) (string, map[int]int, bool) {
	heads := yrcLineHeads(yrc)
	if lrc == "" || len(heads) < 2 {
		return lrc, nil, false
	}
	for i := 1; i < len(heads); i++ {
		if heads[i].ms < heads[i-1].ms {
			return lrc, nil, false // 逐字轴自己就是乱的,没资格当基准
		}
	}
	lines := strings.Split(lrc, "\n")
	var idxs []int
	var texts []string
	var oldMs []int
	for i, line := range lines {
		stamps := lrcTimestampCaptureRe.FindAllStringSubmatch(line, -1)
		if len(stamps) == 0 {
			continue
		}
		if len(stamps) > 1 {
			return lrc, nil, false
		}
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
		if text == "" {
			continue
		}
		idxs = append(idxs, i)
		texts = append(texts, text)
		oldMs = append(oldMs, lrcStampMs(stamps[0]))
	}
	if len(idxs) < 2 || len(idxs) != len(heads) {
		return lrc, nil, false
	}
	for i := range texts {
		if normTimelineText(texts[i]) != normTimelineText(heads[i].text) {
			return lrc, nil, false
		}
	}
	// ⚠️ 判"要不要改"必须带容差,不能直接比毫秒:输出格式 [mm:ss.xx] 只到百分秒,
	// 18315ms 写出去是 [00:18.31]、读回来就成了 18310ms。按精确相等判的话,重挂过的
	// 内容每次读回都还差那 5ms,启动期迁移会**每次开机都重写一遍整份缓存**(单测
	// TestRehangLRCOnYRCIdempotent 抓到的就是这个)。容差取 10ms = 一个百分秒位。
	const stampQuantMs = 10
	changed := false
	for i := range oldMs {
		d := oldMs[i] - heads[i].ms
		if d < 0 {
			d = -d
		}
		if d > stampQuantMs {
			changed = true
			break
		}
	}
	if !changed {
		return lrc, nil, false
	}
	// ⚠️ 只替换内容行的时间戳,**原样保留**元数据行([ti:]/[ar:]/[al:]/[by:])与空行。
	// 打分的 lines 项按 len(strings.Split(lyrics,"\n")) 计分(match.go),把元数据行和
	// 空行也数进去 —— 按内容行重新生成整个文件会把它们丢掉,实测会让全库最干净的 kugou
	// 集体掉分被 qq 反超(消融里假翻盘 175 条)。修数据的改动只动该动的那一维。
	out := make([]string, len(lines))
	copy(out, lines)
	remap := make(map[int]int, len(idxs))
	for k, i := range idxs {
		out[i] = formatLRCStamp(heads[k].ms) + texts[k]
		remap[oldMs[k]] = heads[k].ms
	}
	newLRC := strings.Join(out, "\n")
	// 再兜一道:上面按容差判过"时间实质变了",但若原文本来就是这个格式、只是小数位写法
	// 不同(netease 有 [mm:ss.xxx] 三位的),重写出来可能与原文逐字节相同 —— 那就不算改。
	if newLRC == lrc {
		return lrc, nil, false
	}
	if guard {
		// 曲长未知时**放弃重挂**:闸校验不了,就没法保证"改完不会更坏"。
		// 实测本机 41 条候选里有 22 条属于这种(从没真正播放过、缓存里没记时长),其中
		// 《大内低手》重挂后末句会从 190.31s 缩到 140.18s —— 到底是 LRC 多转写了 50 秒
		// 还是 YRC 少覆盖了 50 秒,没有曲长根本判不了。这些条目等它真正被播放时(那条
		// 路径带着 durationSecs 走 rehangCandidateTimelines)自然会修,不必在这里赌。
		if durationSecs <= 0 {
			return lrc, nil, false
		}
		oldLast, okOld := lastLRCTimestampSecs(lrc)
		newLast, okNew := lastLRCTimestampSecs(newLRC)
		if okOld && okNew && durationFits(oldLast, durationSecs) && !durationFits(newLast, durationSecs) {
			return lrc, nil, false
		}
	}
	return newLRC, remap, true
}

// ---- 逐字轴与行级轴自相矛盾时弃用逐字轴(2026-09-01,陈奕迅《2001太空漫游 (Live)》案) ----
//
// rehangLRCOnYRC 只能修"两边逐行文本严格一一对应"的打架(musixmatch 的病正是那个形态)。
// netease 的两套轴是**两条独立产线**(行级 /api/song/lyric 老接口 vs 逐字 /api/song/lyric/v1
// 新接口),同一首歌可能**断行方式都不一样**(LRC 拆两行的,YRC 合成一行)、还夹着对方没有的
// 署名行/纯音乐占位行 —— 行结构对不上,重挂在前提检查那一步就放弃,打架原样留给播放。
// 用户报的《2001太空漫游 (Live)》:LRC 首句 32.3s、YRC 同一句 74.3s,差 42 秒,配对行
// 中位偏差 55.5s;播放走 YRC,「歌词管理」显示的是 LRC —— 用户看着 32 秒该有词,播放到
// 32 秒(人已开唱)什么都不出。
//
// 修法:重挂修不了、且两套轴的配对行中位偏差大到不可能是同一次转写的合理误差时,
// **弃用逐字轴**(候选构造清掉 wordTimingYRC/hasWordTiming;存量缓存由启动迁移清掉),
// 播放退回行级 LRC。方向的依据:LRC 是打分管线全套校验过的主资产(isTimedLRC/durationFits/
// 跨源 3-gram 共识全部读它),「歌词管理」展示的也是它;YRC 只过了一道覆盖率守卫
// (usableWordTiming)。两边矛盾而无法调和时,继续拿只受过弱校验的增强资产驱动播放,
// 等于让播放跟系统其余全部判断对着干。代价是这几首歌没有逐字卡拉OK效果 —— 正确的逐行
// 显示胜过错 42 秒的逐字显示。
//
// 阈值 10s 从全库分布量出来(2026-09-01,2915 条可分析双轴条目):99.3%(2894 条)中位
// 偏差 <3s(其中 92% <0.5s —— qq/kugou/amll 的 LRC 本来就是从逐字轴转出来的,天生自洽),
// ≥10s 的只有 10 条、逐条核对全部是无可争辩的坏数据(含已知旧案 Rock With You 19.4s ——
// 那条当年确认坏的是 YRC 侧,rehang 的时长闸拦下了"修",但没有"弃",坏 YRC 一直在驱动
// 播放;这次一并解决)。3~6.5s 之间还有 11 条含糊地带刻意不动 —— 哪边对判不了,等有
// 真实反馈再说。
//
// 配对用 LCS(最长公共子序列)对齐两边归一化文本相同的行,配对行 ≥8 且 ≥LRC 内容行的
// 一半才评估(配太少时中位数不可信);中位数(不是均值)抗个别错配。

const (
	wordTimingContradictionSkewMs     = 10000
	wordTimingContradictionMinMatched = 8
)

// timelineLCSAlign 返回 texts[i] 对齐到的 heads 下标,没配上是 -1。标准 LCS,相等关系
// 用 normTimelineText 归一化后比较,空串不参与配对。
func timelineLCSAlign(tn, hn []string) []int {
	n, m := len(tn), len(hn)
	dp := make([][]int32, n+1)
	for i := range dp {
		dp[i] = make([]int32, m+1)
	}
	for i := 1; i <= n; i++ {
		for j := 1; j <= m; j++ {
			if tn[i-1] == hn[j-1] && tn[i-1] != "" {
				dp[i][j] = dp[i-1][j-1] + 1
			} else if dp[i-1][j] >= dp[i][j-1] {
				dp[i][j] = dp[i-1][j]
			} else {
				dp[i][j] = dp[i][j-1]
			}
		}
	}
	align := make([]int, n)
	for i := range align {
		align[i] = -1
	}
	i, j := n, m
	for i > 0 && j > 0 {
		if tn[i-1] == hn[j-1] && tn[i-1] != "" && dp[i][j] == dp[i-1][j-1]+1 {
			align[i-1] = j - 1
			i--
			j--
		} else if dp[i-1][j] >= dp[i][j-1] {
			i--
		} else {
			j--
		}
	}
	return align
}

// wordTimingContradictsLRC 判定"这份逐字轴与行级轴自相矛盾、不该再拿来驱动播放"。
// 只在 rehangLRCOnYRC 修不了(或无需修)之后调用 —— 能重挂对齐的两套轴不算矛盾。
func wordTimingContradictsLRC(lrc, yrc string) bool {
	heads := yrcLineHeads(yrc)
	if len(heads) < 2 {
		return false
	}
	var texts []string
	var oldMs []int
	for _, line := range strings.Split(lrc, "\n") {
		stamps := lrcTimestampCaptureRe.FindAllStringSubmatch(line, -1)
		if len(stamps) != 1 {
			continue // 无戳行不参与;一行多戳的行与 YRC 行不一一对应,同样跳过
		}
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
		if text == "" {
			continue
		}
		texts = append(texts, text)
		oldMs = append(oldMs, lrcStampMs(stamps[0]))
	}
	if len(texts) < 2 {
		return false
	}
	tn := make([]string, len(texts))
	for i, s := range texts {
		tn[i] = normTimelineText(s)
	}
	hn := make([]string, len(heads))
	for i, h := range heads {
		hn[i] = normTimelineText(h.text)
	}
	align := timelineLCSAlign(tn, hn)
	var diffs []int
	for i, a := range align {
		if a < 0 {
			continue
		}
		d := oldMs[i] - heads[a].ms
		if d < 0 {
			d = -d
		}
		diffs = append(diffs, d)
	}
	if len(diffs) < wordTimingContradictionMinMatched || len(diffs)*2 < len(texts) {
		return false // 配对太少,中位数不可信 —— 拿不准就不动
	}
	sort.Ints(diffs)
	return diffs[len(diffs)/2] >= wordTimingContradictionSkewMs
}

// remapLRCTimestamps 把一份**照原文 LRC 时间戳生成**的附属歌词(译文/罗马音)搬到新
// 时间轴上。按旧毫秒查映射,查不到的行原样保留 —— 附属歌词常比正文少几行(没译到的行
// 本来就不写),缺行是正常情况,不该因此整份放弃。
func remapLRCTimestamps(lrc string, remap map[int]int) (string, bool) {
	if lrc == "" || len(remap) == 0 {
		return lrc, false
	}
	lines := strings.Split(lrc, "\n")
	changed := false
	for i, line := range lines {
		stamps := lrcTimestampCaptureRe.FindAllStringSubmatch(line, -1)
		if len(stamps) != 1 {
			continue
		}
		text := strings.TrimSpace(lrcTimestampRe.ReplaceAllString(line, ""))
		if text == "" {
			continue
		}
		newMs, ok := remap[lrcStampMs(stamps[0])]
		if !ok {
			continue
		}
		lines[i] = formatLRCStamp(newMs) + text
		changed = true
	}
	if !changed {
		return lrc, false
	}
	return strings.Join(lines, "\n"), true
}

// rehangCandidateTimelines 就地把一批候选的行级时间轴修到与各自的逐字轴自洽;修不了
// 且两套轴自相矛盾的,弃用逐字轴(见 wordTimingContradictsLRC 头注)。
//
// 调用时机(enrich.go):候选构造完、corroboratedEndings 之前 —— 时长/共识判据都读
// LRC 末句,必须先修完再算,否则打分看到的还是坏时间轴。弃用发生在打分前,这样自相
// 矛盾的逐字轴也拿不到 wordTiming 那 +400 —— 它不是质量证据。跟 rehang 一样属于
// "修数据"而不是"改打分判据",沿用第 23 条确立的先例,不 bump lyricsScoringVersion。
func rehangCandidateTimelines(candidates []lyricCandidate, durationSecs float64) {
	for i := range candidates {
		fixed, remap, ok := rehangLRCOnYRC(candidates[i].lyrics, candidates[i].wordTimingYRC, durationSecs, true)
		if ok {
			candidates[i].lyrics = fixed
			candidates[i].timelineRemap = remap
			continue
		}
		if candidates[i].wordTimingYRC != "" && wordTimingContradictsLRC(candidates[i].lyrics, candidates[i].wordTimingYRC) {
			candidates[i].wordTimingYRC = ""
			candidates[i].hasWordTiming = false
		}
	}
}

// migrateLyricTimelines 对整个 enrich 缓存跑一遍重挂,连带把译文/罗马音搬到新轴上。
//
// 调用时机(main.go):importLyricsFromFiles 之后、exportLyricsFiles 之前 —— 修的是
// 权威内容,修完由 export 写回 lyrics/ 导出文件(那份 .lrc 才是给第三方播放器看的)。
// 形态照抄 migrateYRCWhitespaceTokens。幂等:改过的内容再跑是空操作。
//
// 跳过用户手改过的条目:manual_lyrics 是全部自愈路径的一票否决闸,这里同样尊重。
func migrateLyricTimelines() {
	enrichMu.Lock()
	fixed := 0
	dropped := 0
	for k, e := range enrichCache {
		if e.ManualLyrics {
			continue
		}
		dur := e.DurationSecs
		if dur <= 0 {
			dur = e.ResolvedDurationSecs
		}
		newLyrics, remap, ok := rehangLRCOnYRC(e.Lyrics, e.LyricsYRC, dur, true)
		if !ok {
			// 重挂修不了的,再看两套轴是否自相矛盾 —— 是就弃用逐字轴,播放退回行级
			// (见 wordTimingContradictsLRC 头注,《2001太空漫游 (Live)》案)。
			if e.LyricsYRC != "" && wordTimingContradictsLRC(e.Lyrics, e.LyricsYRC) {
				e.LyricsYRC = ""
				enrichCache[k] = e
				dropped++
			}
			continue
		}
		e.Lyrics = newLyrics
		if tr, ok2 := remapLRCTimestamps(e.LyricsTr, remap); ok2 {
			e.LyricsTr = tr
		}
		if roma, ok2 := remapLRCTimestamps(e.LyricsRoma, remap); ok2 {
			e.LyricsRoma = roma
		}
		enrichCache[k] = e
		fixed++
	}
	if fixed > 0 || dropped > 0 {
		// ⚠️ 必须显式置脏:saveEnrichCache 只在 enrichDirty 时才真的写盘。这里不置的话,
		// 迁移结果能不能落盘取决于同一次启动里**别的路径**有没有恰好把标志置过 true ——
		// 2026-09-01 实测坐实这个潜伏 bug:弃用逐字轴的迁移连续两次启动都报"dropped 10
		// entries"、JSON 的 mtime 却纹丝不动,每次开机白干一遍;而 08-28 那次 1010 条
		// 重挂能落盘纯属搭了别的脏标志的顺风车。
		enrichDirty = true
	}
	enrichMu.Unlock()
	if fixed > 0 || dropped > 0 {
		log.Printf("lyric timeline migration: rehung %d entries, dropped contradictory word timing in %d entries", fixed, dropped)
		saveEnrichCache()
	}
}
