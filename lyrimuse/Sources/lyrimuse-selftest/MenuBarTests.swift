import LyrimuseCore
import Foundation

// 菜单栏跑马灯 / 逐字染色 / 进度图标。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runMenuBarTests() {
    // ---- 菜单栏跑马灯:像素级偏移 ----
    do {
        // 一段固定的参数:滚 100pt，每秒 50pt（走完要 2 秒），首尾各停 1 秒。
        // 于是一个完整周期 = 1 + 2 + 1 = 4 秒。
        func offset(_ elapsed: Double) -> CGFloat {
            MenuBarMarquee.scrollOffset(
                elapsed: elapsed, maxOffset: 100, pointsPerSecond: 50, holdSeconds: 1)
        }

        // 装得下就不滚。这条最要紧：maxOffset<=0 时若不早退，下面的除法会算出无穷大。
        expectEqual(
            MenuBarMarquee.scrollOffset(
                elapsed: 5, maxOffset: 0, pointsPerSecond: 50, holdSeconds: 1), 0,
            "像素滚动: 装得下(maxOffset=0)就不滚")
        expectEqual(
            MenuBarMarquee.scrollOffset(
                elapsed: 5, maxOffset: -10, pointsPerSecond: 50, holdSeconds: 1), 0,
            "像素滚动: maxOffset 为负也不滚")
        // 速度非正是调用方算错了，退化成不滚，而不是除零。
        expectEqual(
            MenuBarMarquee.scrollOffset(
                elapsed: 5, maxOffset: 100, pointsPerSecond: 0, holdSeconds: 1), 0,
            "像素滚动: 速度为 0 不除零")

        // 开头停留：这一段是整个设计的重点，一句歌词最该看清的是开头。
        expectEqual(offset(0), 0, "像素滚动: 第 0 秒停在开头")
        expectEqual(offset(0.99), 0, "像素滚动: 停留期内一直在开头")
        // 停留一结束就开始走，且是连续的——按字符那版这里会直接跳一整个字。
        expectEqual(offset(1.5), 25, "像素滚动: 停留结束后匀速前进")
        expectEqual(offset(2.0), 50, "像素滚动: 走到一半")
        // 末尾必须夹住，不能因为浮点乘法多算出一点点而露出右边的空白。
        expectEqual(offset(3.0), 100, "像素滚动: 走到底正好是 maxOffset")
        expectEqual(offset(3.5), 100, "像素滚动: 末尾停留期停在最右")

        // 循环：一个周期之后回到开头。歌词通常几秒就换一句、走不完一整轮，这只是兜底，
        // 但不能卡在末尾不动。
        expectEqual(offset(4.0), 0, "像素滚动: 满一个周期回到开头")
        expectEqual(offset(5.5), 25, "像素滚动: 第二轮的位置跟第一轮一致")

        // 时钟回拨/传负数不能跳到奇怪的位置（CACurrentMediaTime 单调，但这函数是纯的，
        // 不该对调用方的取值做假设）。负数会被归一化到周期内的某个位置，那没问题——
        // 真正要守的不变式是**偏移永远落在 [0, maxOffset]**：小于 0 会让文字往右跑出窗口，
        // 大于 maxOffset 会在右边露出一条空白。
        var offsetOutOfRange = 0
        for i in -80 ... 400 {
            let v = offset(Double(i) / 20)
            if v < 0 || v > 100 { offsetOutOfRange += 1 }
        }
        expectEqual(offsetOutOfRange, 0, "像素滚动: 扫全区间(含负数/多个周期)偏移都在 [0,maxOffset]")

        // 同一时刻反复问必须得到同一个答案（这条保证了"偏移没变就不重画"那个优化是安全的）。
        expectEqual(offset(2.0), offset(2.0), "像素滚动: 纯函数,同输入同输出")
    }

    // ---- 菜单栏跑马灯:关键帧与逐帧采样必须描述同一段运动 ----
    //
    // 2026-08-16 菜单栏从 MenuBarExtra 换成自建 NSStatusItem 之后，滚动不再由计时器逐帧
    // 驱动，而是把 scrollKeyframes 交给 Core Animation 去插值。换驱动方式最容易出的事故
    // 不是"不动了"（那一眼就看得见），而是**悄悄变了观感**：停留时长、速度、循环点任何
    // 一个抄错，滚动看起来都还挺正常，只是跟以前不一样了。
    //
    // 所以这里不去单独断言关键帧的几个数字，而是拿上面那个已经测透的 scrollOffset 当验收
    // 标准：对关键帧做线性插值（CA 的 .linear 就是这么算的），逐点跟 scrollOffset 对答案。
    do {
        let maxOffset: CGFloat = 100
        let pps: CGFloat = 50
        let hold = 1.0

        /// 验收标准：上面那个已经测透的逐帧采样函数，同一组参数。
        func offsetReference(_ elapsed: Double) -> CGFloat {
            MenuBarMarquee.scrollOffset(
                elapsed: elapsed, maxOffset: maxOffset, pointsPerSecond: pps, holdSeconds: hold)
        }

        guard let frames = MenuBarMarquee.scrollKeyframes(
            maxOffset: maxOffset, pointsPerSecond: pps, holdSeconds: hold) else {
            expectEqual(true, false, "关键帧: 该滚的参数却返回了 nil")
            fatalError("unreachable")
        }

        // 周期跟逐帧那版一致：停 1 + 走 2 + 停 1 = 4 秒。
        expectEqual(frames.duration, 4.0, "关键帧: 一个周期 4 秒")
        expectEqual(frames.keyTimes.count, frames.offsets.count,
                    "关键帧: keyTimes 与 offsets 一一对应")
        expectEqual(frames.keyTimes[0], 0, "关键帧: 从 0 开始")
        expectEqual(frames.keyTimes[frames.keyTimes.count - 1], 1, "关键帧: 到 1 结束")
        // keyTimes 必须单调不减，否则 CA 的插值结果是未定义的。
        var monotonic = true
        for i in 1 ..< frames.keyTimes.count where frames.keyTimes[i] < frames.keyTimes[i - 1] {
            monotonic = false
        }
        expectEqual(monotonic, true, "关键帧: keyTimes 单调不减")

        // CA 的 .linear 插值：给定周期内的时刻，在相邻两个关键帧之间线性取值。
        func interpolate(_ elapsed: Double) -> CGFloat {
            var t = elapsed.truncatingRemainder(dividingBy: frames.duration)
            if t < 0 { t += frames.duration }
            let normalized = t / frames.duration
            for i in 1 ..< frames.keyTimes.count {
                let t0 = frames.keyTimes[i - 1], t1 = frames.keyTimes[i]
                guard normalized <= t1 else { continue }
                guard t1 > t0 else { return frames.offsets[i] }
                let ratio = (normalized - t0) / (t1 - t0)
                return frames.offsets[i - 1]
                    + (frames.offsets[i] - frames.offsets[i - 1]) * CGFloat(ratio)
            }
            return frames.offsets[frames.offsets.count - 1]
        }

        // 扫两个完整周期，每 0.05 秒一个采样点，逐点跟 scrollOffset 对答案。
        var worstGap = 0.0
        var worstAt = 0.0
        for i in 0 ... 160 {
            let elapsed = Double(i) / 20
            let gap = abs(Double(interpolate(elapsed) - offsetReference(elapsed)))
            if gap > worstGap { worstGap = gap; worstAt = elapsed }
        }
        // 允许极小的浮点误差（两条路径的乘除顺序不同），但不能有真实的行为差异。
        expectEqual(worstGap < 0.001, true,
                    "关键帧: 与逐帧采样处处一致(最大偏差 \(worstGap) 出现在 t=\(worstAt)s)")

        // 装得下 / 速度非正 → 没有可滚的东西，必须是 nil 而不是一条跑不起来的空动画。
        expectEqual(
            MenuBarMarquee.scrollKeyframes(maxOffset: 0, pointsPerSecond: 50, holdSeconds: 1) == nil,
            true, "关键帧: 装得下就没有动画")
        expectEqual(
            MenuBarMarquee.scrollKeyframes(maxOffset: 100, pointsPerSecond: 0, holdSeconds: 1) == nil,
            true, "关键帧: 速度为 0 不生成动画(也不除零)")

        // 不停留(hold=0)时首尾两个关键帧会重合在同一时刻——这是合法的，但 keyTimes 仍然
        // 必须单调不减，不能出现 0.0 之后跟着一个负数这类会让 CA 插值发疯的输入。
        guard let noHold = MenuBarMarquee.scrollKeyframes(
            maxOffset: 100, pointsPerSecond: 50, holdSeconds: 0) else {
            expectEqual(true, false, "关键帧: hold=0 不该返回 nil")
            fatalError("unreachable")
        }
        expectEqual(noHold.keyTimes, [0, 0, 1, 1], "关键帧: 不停留时首尾各自重合")
        expectEqual(noHold.duration, 2.0, "关键帧: 不停留时周期就是走完全程的时间")
    }

    // ---- 菜单栏逐字染色:填色边界路径与剩余关键帧 ----
    //
    // 2026-08-22 加(用户点名"像酷狗菜单栏歌词")。填色跟滚动同一套哲学:整行进程编成一条
    // CA 关键帧,装好后主线程一帧都不碰。这里钉死三件事:路径构造对脏数据的钳制、词间空隙
    // 的"平保持"语义、以及"从任意时刻起步"的剩余关键帧跟静态取值(karaokeFillX)自洽。
    do {
        // 三个词:0-500ms 宽 10pt、500-1000ms 累计到 30pt、1200-1500ms 累计到 60pt。
        // 第二、三个词之间有 200ms 空隙(伴奏),边界应停在 30pt 不动。
        let words = [
            SyncedLyricWord(text: "甲", startMs: 0, durationMs: 500),
            SyncedLyricWord(text: "乙", startMs: 500, durationMs: 500),
            SyncedLyricWord(text: "丙", startMs: 1200, durationMs: 300),
        ]
        let path = MenuBarMarquee.karaokeFillPath(words: words, wordEndXs: [10, 30, 60])
        expectEqual(path.isEmpty, false, "填色路径: 正常输入不为空")
        var msMonotonic = true
        var xMonotonic = true
        for i in 1 ..< path.count {
            if path[i].ms <= path[i - 1].ms { msMonotonic = false }
            if path[i].x < path[i - 1].x { xMonotonic = false }
        }
        expectEqual(msMonotonic, true, "填色路径: 时间严格递增(词首尾相接也被钳开)")
        expectEqual(xMonotonic, true, "填色路径: 边界单调不减")
        expectEqual(path[path.count - 1].x, 60, "填色路径: 终点停在整句末端")

        // 静态取值:词中线性、词间空隙平保持、路径外取端点。
        expectEqual(MenuBarMarquee.karaokeFillX(atMs: -100, path: path), 0, "填色取值: 开唱前是 0")
        expectEqual(MenuBarMarquee.karaokeFillX(atMs: 250, path: path), 5, "填色取值: 词中线性插值")
        expectEqual(MenuBarMarquee.karaokeFillX(atMs: 1100, path: path), 30, "填色取值: 词间空隙停住")
        expectEqual(MenuBarMarquee.karaokeFillX(atMs: 9999, path: path), 60, "填色取值: 唱完停在末端")

        // 剩余关键帧:从 250ms(第一个词唱到一半)起步。
        guard let frames = MenuBarMarquee.karaokeFillKeyframes(path: path, nowMs: 250, rate: 1) else {
            expectEqual(true, false, "填色关键帧: 行没唱完却返回了 nil")
            fatalError("unreachable")
        }
        expectEqual(frames.widths[0], 5, "填色关键帧: 起点就是此刻的静态取值")
        expectEqual(frames.keyTimes[0], 0, "填色关键帧: 从 0 开始")
        expectEqual(frames.keyTimes[frames.keyTimes.count - 1], 1, "填色关键帧: 到 1 结束")
        expectEqual(frames.duration, 1.25, "填色关键帧: 时长 = 剩余毫秒 ÷ 1000 ÷ 速率")
        var ktMonotonic = true
        for i in 1 ..< frames.keyTimes.count where frames.keyTimes[i] <= frames.keyTimes[i - 1] {
            ktMonotonic = false
        }
        expectEqual(ktMonotonic, true, "填色关键帧: keyTimes 严格递增")
        expectEqual(frames.widths[frames.widths.count - 1], 60, "填色关键帧: 终点全填")

        // 速率折算:2x 播放剩余动画减半。
        expectEqual(MenuBarMarquee.karaokeFillKeyframes(path: path, nowMs: 250, rate: 2)?.duration,
                    0.625, "填色关键帧: 速率参与折算")
        // 没有可动余量的三种情况都必须是 nil,别留一条跑不起来的动画。
        expectEqual(MenuBarMarquee.karaokeFillKeyframes(path: path, nowMs: 1500, rate: 1) == nil,
                    true, "填色关键帧: 已唱完返回 nil")
        expectEqual(MenuBarMarquee.karaokeFillKeyframes(path: path, nowMs: 250, rate: 0) == nil,
                    true, "填色关键帧: 暂停(速率 0)返回 nil")
        expectEqual(MenuBarMarquee.karaokeFillKeyframes(path: [], nowMs: 0, rate: 1) == nil,
                    true, "填色关键帧: 空路径返回 nil")

        // 脏数据:时间戳乱序/重叠(酷狗偶发)钳成递增,x 跟着钳单调 —— CA 收到相等的
        // keyTimes 插值结果未定义,这层钳制是硬保证。
        let dirty = [
            SyncedLyricWord(text: "a", startMs: 300, durationMs: 400),
            SyncedLyricWord(text: "b", startMs: 200, durationMs: 100), // 起点倒退,还比前词早结束
        ]
        let dirtyPath = MenuBarMarquee.karaokeFillPath(words: dirty, wordEndXs: [20, 15]) // x 也倒退
        var dirtyOK = true
        for i in 1 ..< dirtyPath.count {
            if dirtyPath[i].ms <= dirtyPath[i - 1].ms || dirtyPath[i].x < dirtyPath[i - 1].x {
                dirtyOK = false
            }
        }
        expectEqual(dirtyOK, true, "填色路径: 乱序/倒退的脏数据被钳成合法单调序列")
        // 词数与宽度数组对不上是调用方 bug,宁可不染也不崩。
        expectEqual(MenuBarMarquee.karaokeFillPath(words: words, wordEndXs: [10]).isEmpty, true,
                    "填色路径: 词数与宽度数不一致返回空")
    }

    // ---- 菜单栏跟唱滚动:阅读位置路径与滚动偏移路径 ----
    //
    // 2026-09-04 加(用户:"可以根据实际的宽度以及播放逐字进度去滚吗")。有逐字时间轴的句子,滚动不再按
    // dwell 倒推的匀速配速走,而是跟着正在唱的字:阅读位置 = 正在唱的词的左缘(词起点连线,词间空隙被
    // 吸收进运动里),滚动偏移 = clamp(阅读位置 − 锚点, 0, maxOffset)。这里钉死:空隙不停顿、钳位折点
    // 补齐后线性插值逐点等于钳位函数、装得下不滚、静态取值 / 剩余关键帧与填色那套同一条插值。
    do {
        let words = [
            SyncedLyricWord(text: "甲", startMs: 0, durationMs: 500),
            SyncedLyricWord(text: "乙", startMs: 500, durationMs: 500),
            SyncedLyricWord(text: "丙", startMs: 1200, durationMs: 300),
        ]
        let reading = MenuBarMarquee.followReadingPath(words: words, wordEndXs: [10, 30, 60])
        expectEqual(reading.count, 4, "跟唱阅读位置: 每个词起点一个点 + 句末一个点")
        expectEqual(reading[0].ms, 0, "跟唱阅读位置: 首词起唱的时刻")
        expectEqual(reading[0].x, 0, "跟唱阅读位置: 首词左缘是 0")
        expectEqual(reading[1].x, 10, "跟唱阅读位置: 第二个词起唱时在第一个词末端")
        expectEqual(reading[2].ms, 1200, "跟唱阅读位置: 第三个词起唱的时刻")
        expectEqual(reading[2].x, 30, "跟唱阅读位置: 第三个词起唱时在第二个词末端")
        expectEqual(reading[3].ms, 1500, "跟唱阅读位置: 末词唱完的时刻")
        expectEqual(reading[3].x, 60, "跟唱阅读位置: 末词唱完到整句末端")
        // 词间空隙(1000~1200ms)不停顿:阅读位置在 10 → 30 之间连续走,而填色边界那条此刻是停在 30 的。
        let midGap = MenuBarMarquee.karaokeFillX(atMs: 1100, path: reading)
        expectEqual(midGap > 10 && midGap < 30, true, "跟唱阅读位置: 词间空隙被吸收进运动,不停顿(\(midGap))")
        expectEqual(abs(midGap - (10 + 20 * 600 / 700)) < 0.01, true, "跟唱阅读位置: 空隙里按词起点连线线性插值")
        expectEqual(MenuBarMarquee.followReadingPath(words: words, wordEndXs: [10]).isEmpty, true,
                    "跟唱阅读位置: 词数与宽度数不一致返回空")

        // 偏移路径:格子宽 40、整句宽 60 → maxOffset 20;锚点 40 × 0.45 = 18。
        let path = MenuBarMarquee.followScrollPath(reading: reading, windowWidth: 40, textWidth: 60)
        expectEqual(path.isEmpty, false, "跟唱偏移: 放不下就有路径")
        expectEqual(path[0].ms, 0, "跟唱偏移: 从句首开始")
        expectEqual(path[0].x, 0, "跟唱偏移: 开唱前偏移 0")
        expectEqual(path[path.count - 1].x, 20, "跟唱偏移: 终点停在 maxOffset")
        var pathMonotonic = true
        for i in 1 ..< path.count where path[i].ms <= path[i - 1].ms || path[i].x < path[i - 1].x {
            pathMonotonic = false
        }
        expectEqual(pathMonotonic, true, "跟唱偏移: 时间严格递增、偏移单调不减")
        // 钳位折点:阅读位置 18 落在 500~1200ms 那段(10→30),t = 0.4 → 780ms;38 落在 1200~1500ms
        // (30→60),t = 8/30 → 1280ms。补了折点之后,线性插值必须逐点等于 clamp(阅读位置 − 18, 0, 20)。
        expectEqual(path.contains { $0.ms == 780 && $0.x == 0 }, true, "跟唱偏移: 穿过下钳位处补折点(780ms)")
        expectEqual(path.contains { $0.ms == 1280 && $0.x == 20 }, true, "跟唱偏移: 穿过上钳位处补折点(1280ms)")
        var worst: CGFloat = 0
        for ms in stride(from: -100, through: 1700, by: 10) {
            let expected = min(20, max(0, MenuBarMarquee.karaokeFillX(atMs: ms, path: reading) - 18))
            worst = max(worst, abs(MenuBarMarquee.followScrollOffset(atMs: ms, path: path) - expected))
        }
        expectEqual(worst < 0.05, true, "跟唱偏移: 线性插值逐点等于钳位函数(最大偏差 \(worst))")
        // 同值连跑的中间点被删掉:0~780ms 一路是 0,只留首尾两点。
        expectEqual(path.filter { $0.x == 0 }.count, 2, "跟唱偏移: 偏移为 0 的一段只留首尾两点")
        expectEqual(MenuBarMarquee.followScrollOffset(atMs: 1000, path: path) > 0, true,
                    "跟唱偏移: 唱过锚点之后开始滚")
        // 装得下 / 输入无效 → 空。
        expectEqual(MenuBarMarquee.followScrollPath(reading: reading, windowWidth: 60, textWidth: 60).isEmpty,
                    true, "跟唱偏移: 装得下不滚")
        expectEqual(MenuBarMarquee.followScrollPath(reading: reading, windowWidth: 0, textWidth: 60).isEmpty,
                    true, "跟唱偏移: 格子宽 0 不滚")
        expectEqual(MenuBarMarquee.followScrollPath(reading: [], windowWidth: 40, textWidth: 60).isEmpty,
                    true, "跟唱偏移: 没有阅读位置不滚")
        // 锚点比例越界被钳到 [0, 1]:比例 5 → 锚点就是格子右缘,阅读位置到 40 才开始滚。
        let farAnchor = MenuBarMarquee.followScrollPath(reading: reading, windowWidth: 40, textWidth: 60,
                                                        anchorFraction: 5)
        expectEqual(MenuBarMarquee.followScrollOffset(atMs: 1200, path: farAnchor), 0,
                    "跟唱偏移: 锚点比例钳到 1,阅读位置 30 还没到 40 不滚")
        // 剩余关键帧 / 静态取值跟填色那套是同一条插值。
        guard let frames = MenuBarMarquee.followScrollKeyframes(path: path, nowMs: 1000, rate: 1) else {
            expectEqual(true, false, "跟唱关键帧: 句子没唱完却返回了 nil")
            fatalError("unreachable")
        }
        expectEqual(frames.widths[0], MenuBarMarquee.followScrollOffset(atMs: 1000, path: path),
                    "跟唱关键帧: 起点就是此刻的静态取值")
        expectEqual(frames.widths[frames.widths.count - 1], 20, "跟唱关键帧: 终点停在 maxOffset")
        expectEqual(frames.duration, 0.5, "跟唱关键帧: 时长 = 剩余毫秒 ÷ 1000 ÷ 速率")
        expectEqual(MenuBarMarquee.followScrollKeyframes(path: path, nowMs: 1500, rate: 1) == nil, true,
                    "跟唱关键帧: 唱完返回 nil,静置在末端")
        expectEqual(MenuBarMarquee.followScrollKeyframes(path: path, nowMs: 1000, rate: 0) == nil, true,
                    "跟唱关键帧: 暂停返回 nil,静置在此刻偏移")
    }

    // ---- 菜单栏歌词旁那枚图标:整首歌的播放进度 ----
    //
    // 2026-09-03 加(用户:"可以选择是否在最左侧或者是最右侧展示软件图标,图标上会逐渐染色
    // 代表当前歌曲进度条")。跟上面那套逐字染色**不是**一回事:进度来自播放位置/曲长而不是
    // 歌词时间轴,范围是整首歌而不是这一句,而且是匀速的(所以是一条线性动画,不是关键帧)。
    //
    // 这里钉死三件事:① 边界取值线性、两端夹住;② 曲长缺失/非正一律退化成"不染"而不是
    // 画出格子或除零;③ ramp 的 duration 就是"剩下这段按当前速率要放多久"。
    do {
        let h: CGFloat = 15 // 图标高(菜单栏那一档 SF Symbol 的典型值)

        // ① 线性 + 夹两端。
        expectEqual(MenuBarMarquee.progressFillLength(positionMs: 0, durationMs: 200_000,
                                                      fullLength: h),
                    0, "进度取值: 开头是 0")
        expectEqual(MenuBarMarquee.progressFillLength(positionMs: 100_000, durationMs: 200_000,
                                                      fullLength: h),
                    h / 2, "进度取值: 一半就是一半")
        expectEqual(MenuBarMarquee.progressFillLength(positionMs: 200_000, durationMs: 200_000,
                                                      fullLength: h),
                    h, "进度取值: 放完是满格")
        // 位置越界不是假设、是真会发生的:锚点外推 + 播放器上报的曲长偏短,末尾几百毫秒里
        // position 会超过 duration。夹住,别画出格子外面去。
        expectEqual(MenuBarMarquee.progressFillLength(positionMs: 260_000, durationMs: 200_000,
                                                      fullLength: h),
                    h, "进度取值: 位置超过曲长夹在满格")
        expectEqual(MenuBarMarquee.progressFillLength(positionMs: -5_000, durationMs: 200_000,
                                                      fullLength: h),
                    0, "进度取值: 位置为负夹在 0")

        // ② 曲长未知/非正 → 0(整枚基础色,不假装有进度),而不是崩或者除零。
        expectEqual(MenuBarMarquee.progressFillLength(positionMs: 50_000, durationMs: 0,
                                                      fullLength: h),
                    0, "进度取值: 曲长为 0 时不染")
        expectEqual(MenuBarMarquee.progressFillLength(positionMs: 50_000, durationMs: -1,
                                                      fullLength: h),
                    0, "进度取值: 曲长为负时不染")

        // ③ ramp:从此刻到放完。
        guard let ramp = MenuBarMarquee.progressFillRamp(
            positionMs: 60_000, durationMs: 180_000, rate: 1, fullLength: h) else {
            expectEqual(true, false, "进度动画: 播放中却返回了 nil")
            fatalError("unreachable")
        }
        expectEqual(ramp.from, h / 3, "进度动画: 起点就是此刻的边界")
        expectEqual(ramp.to, h, "进度动画: 终点是满格")
        expectEqual(ramp.duration, 120, "进度动画: 时长 = 剩余 2 分钟")
        // 倍速播放剩余时间要跟着折算 —— 跟逐字染色那条同一个口径。
        expectEqual(MenuBarMarquee.progressFillRamp(positionMs: 60_000, durationMs: 180_000,
                                                    rate: 2, fullLength: h)?.duration,
                    60, "进度动画: 2 倍速剩余时间减半")
        // ramp 的起点必须跟静态取值是同一个数 —— 两者算不到一起就是"装动画那一下边界跳一下"。
        expectEqual(ramp.from,
                    MenuBarMarquee.progressFillLength(positionMs: 60_000, durationMs: 180_000,
                                                      fullLength: h),
                    "进度动画: 起点与静态取值自洽")

        // 四种"不该动"的情况都返回 nil,调用方据此静置(留一条跑不起来的动画会让渲染层空转)。
        expectEqual(MenuBarMarquee.progressFillRamp(positionMs: 60_000, durationMs: 180_000,
                                                    rate: 0, fullLength: h) == nil,
                    true, "进度动画: 暂停(rate 0)没有行程")
        expectEqual(MenuBarMarquee.progressFillRamp(positionMs: 180_000, durationMs: 180_000,
                                                    rate: 1, fullLength: h) == nil,
                    true, "进度动画: 已经放完没有行程")
        expectEqual(MenuBarMarquee.progressFillRamp(positionMs: 60_000, durationMs: 0,
                                                    rate: 1, fullLength: h) == nil,
                    true, "进度动画: 曲长未知没有行程")
        expectEqual(MenuBarMarquee.progressFillRamp(positionMs: 60_000, durationMs: 180_000,
                                                    rate: 1, fullLength: 0) == nil,
                    true, "进度动画: 图标高度为 0(取不到图)没有行程")
    }

    // ---- 菜单栏跑马灯:按这一句的停留时长配速 ----
    //
    // 2026-08-17 用户报的:"一句歌词比较长的时候滚动太慢，还没滚到底就切换到下一行了"。
    // 根因是速度写死成每秒 4 个字，跟这一句实际能显示多久完全脱钩——句子越长越看不到后半截。
    //
    // 下面这组断言把"能不能滚完"这件事本身钉死：不是断言某个速度数字，而是断言
    // **首停 + 走完全程 + 尾停 ≤ 这一句的停留时长**。
    do {
        /// 一句中文歌词的典型参数：13pt 菜单栏字，一个汉字约 13pt 宽。
        let charWidth: CGFloat = 13
        /// 用户设的显示宽度（默认档位附近）。
        let windowWidth: CGFloat = 80

        /// 这一句画出来有多宽 → 要滚多远。
        func maxOffset(chars: Int) -> CGFloat { CGFloat(chars) * charWidth - windowWidth }

        /// **滚到末尾**要多久（首停 + 走完全程）。这才是"看不看得到整句"的判据 ——
        /// 尾停是走完之后停在末尾等着换句，它超出 dwell 是故意的（见 loopGuardSeconds）。
        func finishTime(chars: Int, dwell: Double?) -> Double {
            let offset = maxOffset(chars: chars)
            let p = MenuBarMarquee.pacing(
                maxOffset: offset, averageCharWidth: charWidth, dwellSeconds: dwell)
            return p.headHoldSeconds + Double(offset / p.pointsPerSecond)
        }

        /// 以最快可读速度（上限）走完全程要多久 —— 比这还短的停留时长，物理上就滚不完。
        func travelAtCap(chars: Int) -> Double {
            Double(maxOffset(chars: chars) / (MenuBarMarquee.maxCharsPerSecond * charWidth))
        }

        // 不知道停留多久 → 完全维持改动之前的行为（这条是防回归：菜单栏歌词在拿不到
        // 歌词时间轴的场景下不该突然变快）。
        let unknown = MenuBarMarquee.pacing(
            maxOffset: 300, averageCharWidth: charWidth, dwellSeconds: nil)
        expectEqual(unknown.pointsPerSecond, MenuBarMarquee.baseCharsPerSecond * charWidth,
                    "配速: 不知道停留时长时用基准速度")
        expectEqual(unknown.headHoldSeconds, MenuBarMarquee.baseHoldSeconds, "配速: 未知时首停 1.5 秒")
        expectEqual(unknown.tailHoldSeconds, MenuBarMarquee.baseHoldSeconds, "配速: 未知时尾停 1.5 秒")

        // 用户报的那一类：30 字的长句，只显示 4 秒。
        //
        // 改动之前：速度 52pt/s，走完 310pt 要 5.96 秒，加上开头那 1.5 秒共 7.46 秒 ——
        // 而这一句 4 秒就换掉了，只滚过大约四成，后半截永远看不到。
        expectEqual(finishTime(chars: 30, dwell: nil) > 4.0, true,
                    "配速: 长句 + 固定速度确实滚不完（这就是被报的 bug）")
        expectEqual(finishTime(chars: 30, dwell: 4.0) <= 4.0 + 0.001, true,
                    "配速: 30 字长句在 4 秒内滚得完（\(finishTime(chars: 30, dwell: 4.0)) 秒）")

        // 扫一片真实取值范围。判据不是"全都滚得完"——句子长到一定程度、时间短到一定程度，
        // 在**可读速度上限之内**physically 就是走不完。所以断言的是那条真正的不变式：
        // **只要在上限速度下走得完，就必须走完**。
        var missed: [String] = []
        for chars in [12, 18, 24, 30, 40, 60] {
            for dwell in [2.0, 2.5, 3.0, 4.0, 5.0, 8.0, 12.0] {
                guard travelAtCap(chars: chars) <= dwell else { continue } // 物理上不可能，跳过
                if finishTime(chars: chars, dwell: dwell) > dwell + 0.001 {
                    missed.append("\(chars)字/\(dwell)秒")
                }
            }
        }
        expectEqual(missed, [], "配速: 只要上限速度内走得完就一定走完")

        // 句尾预留(2026-08-19 用户反馈"一到最后一个字就马上到下一句了"):时间允许时,
        // 滚动必须比换句**提前** tailReadSeconds 走完,让末尾几个字来得及读。
        // 30 字 / 6 秒:改动前 travel 吃满 dwell - head,恰好 6.0 秒走完、尾停为 0。
        expectEqual(finishTime(chars: 30, dwell: 6.0)
                        <= 6.0 - MenuBarMarquee.tailReadSeconds + 0.001, true,
                    "配速: 时间允许时提前 \(MenuBarMarquee.tailReadSeconds) 秒滚完,句尾留得住"
                        + "(\(finishTime(chars: 30, dwell: 6.0)) 秒)")
        // 时间紧时尾停先让路(先于首停),整句可见仍然优先:2.1 秒里 30 字撞着上限刚好
        // 走得完,不能为了句尾预留把滚动挤到滚不完。
        expectEqual(finishTime(chars: 30, dwell: 2.1) <= 2.1 + 0.001, true,
                    "配速: 时间紧时尾停让路,不挤掉滚动本身")

        // 停留时间很长的句子不该被拖快——那是现有观感，没人抱怨，不动它。
        let roomy = MenuBarMarquee.pacing(
            maxOffset: maxOffset(chars: 14), averageCharWidth: charWidth, dwellSeconds: 20)
        expectEqual(roomy.pointsPerSecond, MenuBarMarquee.baseCharsPerSecond * charWidth,
                    "配速: 时间充裕时仍走基准速度，不会无谓地甩快")
        // 而且**只滚一轮**：走完就停在末尾等着换句，不会反复从头再来（那样很闹）。
        expectEqual(roomy.headHoldSeconds + Double(maxOffset(chars: 14) / roomy.pointsPerSecond)
                        + roomy.tailHoldSeconds >= 20, true,
                    "配速: 时间充裕时一句只滚一轮，不会循环重来")

        // 首尾停顿必须跟着句子时长缩：一句只显示 2 秒时，照搬 1.5+1.5 等于根本没滚。
        let tight = MenuBarMarquee.pacing(
            maxOffset: maxOffset(chars: 30), averageCharWidth: charWidth, dwellSeconds: 2.0)
        expectEqual(tight.headHoldSeconds < 2.0, true, "配速: 短句的开头停顿不会吃光整句时间")

        // 速度有上限，不会为了滚完把字甩成残影。
        let absurd = MenuBarMarquee.pacing(
            maxOffset: maxOffset(chars: 120), averageCharWidth: charWidth, dwellSeconds: 2.0)
        expectEqual(absurd.pointsPerSecond <= MenuBarMarquee.maxCharsPerSecond * charWidth,
                    true, "配速: 速度不超过每秒 12 个字的上限")
        // 而撞到上限之后它**确实滚不完** —— 这是明知的取舍，钉在这里免得以后被当成 bug 去"修"：
        // 比起把字甩成一片糊影，宁可少看几个字。
        expectEqual(finishTime(chars: 120, dwell: 2.0) > 2.0, true,
                    "配速: 极端长句撞上限后滚不完（已知且接受的取舍）")
        // 这种情况下开头那一停必须让到 0 —— 一秒都不该浪费在"停着"上。
        expectEqual(absurd.headHoldSeconds, 0, "配速: 时间不够时开头那一停让到 0")

        // 停留时间短到连停顿都塞不下时，不能除以一个≈0 的数算出无穷大速度。
        let sliver = MenuBarMarquee.pacing(
            maxOffset: 300, averageCharWidth: charWidth, dwellSeconds: 0.06)
        expectEqual(sliver.pointsPerSecond.isFinite && sliver.pointsPerSecond > 0, true,
                    "配速: 停留时间极短也算得出有限速度")

        // 关键帧和逐帧采样在**首尾不等长**时也必须描述同一段运动（上一组只验了等长的情况）。
        let pacing = MenuBarMarquee.pacing(
            maxOffset: maxOffset(chars: 30), averageCharWidth: charWidth, dwellSeconds: 4.0)
        let offset = maxOffset(chars: 30)
        guard let frames = MenuBarMarquee.scrollKeyframes(
            maxOffset: offset, pointsPerSecond: pacing.pointsPerSecond,
            headHoldSeconds: pacing.headHoldSeconds, tailHoldSeconds: pacing.tailHoldSeconds) else {
            expectEqual(true, false, "配速: 该滚的参数却没有关键帧")
            fatalError("unreachable")
        }
        func interpolate(_ elapsed: Double) -> CGFloat {
            var t = elapsed.truncatingRemainder(dividingBy: frames.duration)
            if t < 0 { t += frames.duration }
            let normalized = t / frames.duration
            for i in 1 ..< frames.keyTimes.count {
                let t0 = frames.keyTimes[i - 1], t1 = frames.keyTimes[i]
                guard normalized <= t1 else { continue }
                guard t1 > t0 else { return frames.offsets[i] }
                let ratio = (normalized - t0) / (t1 - t0)
                return frames.offsets[i - 1] + (frames.offsets[i] - frames.offsets[i - 1]) * CGFloat(ratio)
            }
            return frames.offsets[frames.offsets.count - 1]
        }
        var worst = 0.0
        for i in 0 ... 200 {
            let elapsed = Double(i) / 25
            let reference = MenuBarMarquee.scrollOffset(
                elapsed: elapsed, maxOffset: offset, pointsPerSecond: pacing.pointsPerSecond,
                headHoldSeconds: pacing.headHoldSeconds, tailHoldSeconds: pacing.tailHoldSeconds)
            worst = max(worst, abs(Double(interpolate(elapsed) - reference)))
        }
        expectEqual(worst < 0.001, true, "配速: 首尾不等长时关键帧仍与逐帧采样一致(最大偏差 \(worst))")

        // ---- 提前量:开唱之前一步都不许滚(2026-08-24) ----
        //
        // 用户报的:「已经到下一行了,但是还没开始染色的时候不需要滚动,现在是会滚」。单行展示面
        // 会在上一句唱完、本句还没开唱之前就把本句亮出来(CompactLyricLead.revealMs,最长 5 秒),
        // 那段时间它是**没有染色**的;而 head 原来只看 baseHoldSeconds(1.5 秒),提前量一超过它,
        // 一句还没开唱的歌词就自己先滚起来了。实测提前量平均 0.90s、p90 1.75s、p95 3.03s
        // (12893 个行间隙),所以这不是边缘情况。
        //
        // 下面这组断言钉的是三件事:① 提前量之内绝不滚;② 提前量为 0 时逐字段维持旧行为;
        // ③ 扣掉提前量之后"能滚完就必须滚完"(提前量不能变成放弃滚完的借口)。

        /// 滚到末尾要多久(首停 + 走完全程),带提前量的版本。
        func finishTimeLed(chars: Int, dwell: Double?, lead: Double) -> Double {
            let offset = maxOffset(chars: chars)
            let p = MenuBarMarquee.pacing(
                maxOffset: offset, averageCharWidth: charWidth, dwellSeconds: dwell,
                leadInSeconds: lead)
            return p.headHoldSeconds + Double(offset / p.pointsPerSecond)
        }

        // ① 首停必须**至少**盖住提前量 —— 这就是"开唱之前不滚"落到参数上的形状。
        //    取值覆盖实测分布(中位 0.22、均值 0.90、p90 1.75、p95 3.03)和上限 5.0。
        var scrolledTooEarly: [String] = []
        var loopedTooSoon: [String] = []
        for lead in [0.0, 0.22, 0.9, 1.75, 3.03, 5.0] {
            for dwell in [2.0, 3.0, 4.0, 6.0, 12.0, 30.0] where dwell > lead {
                for chars in [12, 30, 60, 120] {
                    let p = MenuBarMarquee.pacing(
                        maxOffset: maxOffset(chars: chars), averageCharWidth: charWidth,
                        dwellSeconds: dwell, leadInSeconds: lead)
                    if p.headHoldSeconds + 1e-9 < lead {
                        scrolledTooEarly.append("\(chars)字/\(dwell)秒/提前\(lead)秒"
                            + "→首停\(p.headHoldSeconds)")
                    }
                    // 顺手钉住"一轮盖住整个显示窗口":提前量是折进首停的,而滚动动画
                    // repeatCount = .infinity —— 一旦周期短于显示窗口,第二轮会在句子还在唱
                    // 的时候把首停(现在含提前量,最长 5 秒)**再停一遍**,末尾几个字闪一下跳回
                    // 开头。loopGuardSeconds 那条老约束在带提前量时同样不能破。
                    let cycle = p.headHoldSeconds
                        + Double(maxOffset(chars: chars) / p.pointsPerSecond) + p.tailHoldSeconds
                    if cycle + 1e-9 < dwell + MenuBarMarquee.loopGuardSeconds {
                        loopedTooSoon.append("\(chars)字/\(dwell)秒/提前\(lead)秒→周期\(cycle)")
                    }
                }
            }
        }
        expectEqual(scrolledTooEarly, [], "配速: 提前量之内一步都不滚(首停 >= 提前量)")
        expectEqual(loopedTooSoon, [], "配速: 带提前量时一轮仍盖住显示窗口,不会在句中循环重停")

        // ② 提前量为 0 时必须跟改动前**逐字段**一致 —— 绝大多数换行(中位间隙 0.22s)靠这条
        //    保证观感没被顺手改掉;行级 LRC 的提前量恒为 0,整条也走这一档。
        var drifted: [String] = []
        for chars in [12, 30, 60] {
            for dwell in [nil, 2.0, 4.0, 8.0, 20.0] as [Double?] {
                let before = MenuBarMarquee.pacing(
                    maxOffset: maxOffset(chars: chars), averageCharWidth: charWidth,
                    dwellSeconds: dwell)
                let after = MenuBarMarquee.pacing(
                    maxOffset: maxOffset(chars: chars), averageCharWidth: charWidth,
                    dwellSeconds: dwell, leadInSeconds: 0)
                if before != after { drifted.append("\(chars)字/\(String(describing: dwell))") }
            }
        }
        expectEqual(drifted, [], "配速: 提前量为 0 时跟改动前逐字段一致")

        // ③ 扣掉提前量之后只要走得完就必须走完 —— 抬高 head 之后 travel 是从 dwell 里扣掉
        //    head 算的,所以不能滚的那段时间是**自动**从行程里去掉的,不会重蹈 2026-08-17
        //    那个"按偏大的 dwell 配速、长句只滚出开头一小截"的坑。
        var missedWithLead: [String] = []
        for chars in [12, 18, 24, 30, 40] {
            for lead in [0.22, 0.9, 1.75, 3.0] {
                for dwell in [3.0, 4.0, 6.0, 8.0, 12.0] {
                    guard lead + travelAtCap(chars: chars) <= dwell else { continue } // 物理上不可能
                    if finishTimeLed(chars: chars, dwell: dwell, lead: lead) > dwell + 0.001 {
                        missedWithLead.append("\(chars)字/\(dwell)秒/提前\(lead)秒")
                    }
                }
            }
        }
        expectEqual(missedWithLead, [], "配速: 扣掉提前量之后能滚完的就一定滚完")

        // 一整轮(首停+行程+尾停)仍然覆盖整个显示窗口 —— 否则换句之前会先循环回开头,
        // 末尾几个字闪一下就跳走(loopGuardSeconds 那条老约束,提前量不能把它破掉)。
        let led = MenuBarMarquee.pacing(
            maxOffset: maxOffset(chars: 30), averageCharWidth: charWidth,
            dwellSeconds: 8.0, leadInSeconds: 5.0)
        expectEqual(led.headHoldSeconds, 5.0, "配速: 提前量 5 秒时首停就是 5 秒")
        expectEqual(led.headHoldSeconds + Double(maxOffset(chars: 30) / led.pointsPerSecond)
                        + led.tailHoldSeconds >= 8.0, true,
                    "配速: 带提前量时一整轮仍覆盖显示窗口,不会在换句前循环回开头")

        // 不知道停留多久那条路(最后一句/拿不到时间轴)也要等到开唱 —— 它原来固定 1.5 秒。
        let unknownLed = MenuBarMarquee.pacing(
            maxOffset: 300, averageCharWidth: charWidth, dwellSeconds: nil, leadInSeconds: 3.0)
        expectEqual(unknownLed.headHoldSeconds, 3.0, "配速: 停留时长未知时也要等到开唱才滚")

        // 脏数据:提前量比 revealMs 还长(上游时钟/时间轴出错)。head 是**死等**,不钳住的话
        // 一次脏数据就能把跑马灯钉死不动。
        let overlong = MenuBarMarquee.pacing(
            maxOffset: 300, averageCharWidth: charWidth, dwellSeconds: 2.0, leadInSeconds: 9.0)
        expectEqual(overlong.headHoldSeconds, Double(CompactLyricLead.revealMs) / 1000,
                    "配速: 提前量超出 revealMs 被钳住,不会把跑马灯钉死")
        expectEqual(overlong.pointsPerSecond.isFinite && overlong.pointsPerSecond > 0
                        && overlong.tailHoldSeconds >= 0, true,
                    "配速: 提前量脏数据下参数仍然有限且非负")
        // 负数(时钟回拨)按 0 处理,不能算出负的首停。
        expectEqual(MenuBarMarquee.pacing(maxOffset: 300, averageCharWidth: charWidth,
                                          dwellSeconds: 4.0, leadInSeconds: -3.0),
                    MenuBarMarquee.pacing(maxOffset: 300, averageCharWidth: charWidth,
                                          dwellSeconds: 4.0),
                    "配速: 提前量为负(时钟回拨)时按 0 处理")

        // 带提前量的关键帧同样必须跟逐帧采样描述同一段运动 —— 上面两组只验了提前量为 0 的情况,
        // 而 CA 那边真正跑的就是这条关键帧。
        /// 关键帧线性插值(CA 的 .linear 就是这么算的)。刻意不跟上面那个同名 helper 合并:
        /// 它捕获的是上面那组 frames,而**同一个文件里已经有两个 interpolate**了,再抽一层
        /// 公共函数只会让"这条断言在验哪一组关键帧"更难看清。
        func interpolateLed(_ frames: MenuBarMarquee.ScrollKeyframes, _ elapsed: Double) -> CGFloat {
            var t = elapsed.truncatingRemainder(dividingBy: frames.duration)
            if t < 0 { t += frames.duration }
            let normalized = t / frames.duration
            for i in 1 ..< frames.keyTimes.count {
                let t0 = frames.keyTimes[i - 1], t1 = frames.keyTimes[i]
                guard normalized <= t1 else { continue }
                guard t1 > t0 else { return frames.offsets[i] }
                let ratio = (normalized - t0) / (t1 - t0)
                return frames.offsets[i - 1] + (frames.offsets[i] - frames.offsets[i - 1]) * CGFloat(ratio)
            }
            return frames.offsets[frames.offsets.count - 1]
        }
        guard let ledFrames = MenuBarMarquee.scrollKeyframes(
            maxOffset: maxOffset(chars: 30), pointsPerSecond: led.pointsPerSecond,
            headHoldSeconds: led.headHoldSeconds, tailHoldSeconds: led.tailHoldSeconds) else {
            expectEqual(true, false, "配速: 带提前量该滚的参数却没有关键帧")
            fatalError("unreachable")
        }
        var ledWorst = 0.0
        for i in 0 ... 400 {
            let elapsed = Double(i) / 25
            let reference = MenuBarMarquee.scrollOffset(
                elapsed: elapsed, maxOffset: maxOffset(chars: 30),
                pointsPerSecond: led.pointsPerSecond,
                headHoldSeconds: led.headHoldSeconds, tailHoldSeconds: led.tailHoldSeconds)
            ledWorst = max(ledWorst, abs(Double(interpolateLed(ledFrames, elapsed) - reference)))
        }
        expectEqual(ledWorst < 0.001, true,
                    "配速: 带提前量时关键帧仍与逐帧采样一致(最大偏差 \(ledWorst))")
        // 提前量走完之前偏移必须**恒为 0**(这是"没染色不滚"最直接的形状)。
        var movedEarly: [String] = []
        for i in 0 ... 50 {
            let elapsed = 5.0 * Double(i) / 50
            let offset = MenuBarMarquee.scrollOffset(
                elapsed: elapsed, maxOffset: maxOffset(chars: 30),
                pointsPerSecond: led.pointsPerSecond,
                headHoldSeconds: led.headHoldSeconds, tailHoldSeconds: led.tailHoldSeconds)
            if offset != 0 { movedEarly.append("\(elapsed)s→\(offset)") }
        }
        expectEqual(movedEarly, [], "配速: 提前量 5 秒之内偏移恒为 0")
    }

    // MARK: - MarqueeMath:跑马灯溢出判定 + 右端渐隐带
    //
    // 2026-08-22 新增。用户报「灵动岛歌词有时候被封面挡住」——歌词行右边紧挨一枚 32pt 封面、
    // 只隔 10pt,长歌词停在开头 hold 的那 1.1 秒里末端被硬切在那个间隙上,肉眼分不清是
    // "裁掉了"还是"被封面盖住了"。修法是给那一端一条渐隐带,判据下沉到这里以便钉死边界。
    do {
        typealias M = MarqueeMath

        // ① 溢出判定与 4pt 死区
        expectEqual(M.overflow(contentWidth: 400, containerWidth: 286), 114, "overflow: 正数=装不下")
        expectEqual(M.overflow(contentWidth: 200, containerWidth: 286), -86, "overflow: 负数=装得下")
        expectEqual(M.isOverflowing(contentWidth: 400, containerWidth: 286), true, "溢出")
        expectEqual(M.isOverflowing(contentWidth: 200, containerWidth: 286), false, "装得下")
        expectEqual(M.isOverflowing(contentWidth: 290, containerWidth: 286), false,
                    "死区:只多 4pt 不算溢出(滚起来只是抖一下)")
        expectEqual(M.isOverflowing(contentWidth: 290.5, containerWidth: 286), true,
                    "死区是严格大于 4pt")
        expectEqual(M.isOverflowing(contentWidth: 400, containerWidth: 0), false,
                    "容器宽度还没测出来(首帧 0)时一律不算溢出——否则 distance 恒等于内容宽")

        // ② 渐隐带只在「溢出 + 停在开头」时给
        let fade: CGFloat = 10
        let lyricRow: CGFloat = 286   // 灵动岛稳态歌词区:360 - 32(padding) - 32(封面) - 10(间距)
        expectEqual(M.trailingFadeWidth(configured: fade, contentWidth: 400,
                                        containerWidth: lyricRow, offset: 0), 10,
                    "停在开头且溢出:给满宽渐隐——这正是用户看到「被封面挡住」的那一帧")
        expectEqual(M.trailingFadeWidth(configured: fade, contentWidth: 400,
                                        containerWidth: lyricRow, offset: 114), 0,
                    "滚到末端:必须不渐隐,否则真正的最后一个字被淡掉(信息损失,不是观感)")
        expectEqual(M.trailingFadeWidth(configured: fade, contentWidth: 400,
                                        containerWidth: lyricRow, offset: 50), 0,
                    "滚动途中不渐隐:文字在动,观感是滚过去而不是被挡住")
        expectEqual(M.trailingFadeWidth(configured: fade, contentWidth: 200,
                                        containerWidth: lyricRow, offset: 0), 0,
                    "短歌词装得下:右端不能莫名淡出")
        expectEqual(M.trailingFadeWidth(configured: 0, contentWidth: 400,
                                        containerWidth: lyricRow, offset: 0), 0,
                    "调用点没开渐隐(默认 0,顶行歌名/歌手走这条)")

        // ③ 容器被形态过渡插值到很窄时按一半封顶
        //    灵动岛收起态卡片 = notchWidth + 2*34 + 20;notchWidth=0 的屏上只有 88pt,
        //    歌词区在弹簧插值里会一路掠过十几 pt,不封顶那几帧整行会被渐隐糊掉。
        expectEqual(M.trailingFadeWidth(configured: fade, contentWidth: 400,
                                        containerWidth: 14, offset: 0), 7,
                    "极窄容器:渐隐带按容器一半封顶")
        expectEqual(M.trailingFadeWidth(configured: fade, contentWidth: 400,
                                        containerWidth: 30, offset: 0), 10,
                    "容器 30pt 已经容得下 10pt 渐隐带,不必封顶")
    }

    // ---- 菜单栏悬停三键:排布与命中(2026-09-03) ----
    //
    // hover 这件事本身没法离线验(要有真鼠标进出才触发 mouseEntered,ImageRenderer 造不出来),
    // 所以按 AGENTS.md 那条"把判据下沉进 Core + selftest 钉死"办:排在哪、点中哪一个全在
    // MenuBarHoverControls 里,UI 层只剩一层薄绑定。
    do {
        typealias H = MenuBarHoverControls
        // 固定宽度模式的**最小**槽宽:滑杆下限 80 + 系统内边距 18(MenuBarStatusItem
        // .fixedSlotPadding)。三个键必须在这一档就装得下 —— 否则"开了这个开关却没反应"
        // 会变成一个只在窄配置下出现的谜。
        let minimumFixedSlot = CGRect(x: 0, y: 0, width: 98, height: 22)

        expectEqual(H.minimumWidth, 72, "三键总宽 = 24pt 一格 × 3(命中区连续,键之间没有死缝)")

        // ① 窄到装不下就**放弃接管**(返回 nil),而不是挤成一坨
        expectEqual(H.layout(in: CGRect(x: 0, y: 0, width: 71.9, height: 22)) == nil, true,
                    "悬停三键: 比总宽差一点点也不接管")
        expectEqual(H.layout(in: CGRect(x: 0, y: 0, width: 72, height: 22)) == nil, false,
                    "悬停三键: 刚好等于总宽就接管")
        // 自适应宽度模式下一句 ♪ 的槽宽实测约 24.5pt、图标槽约 38.5pt —— 两者都必须不接管。
        expectEqual(H.layout(in: CGRect(x: 0, y: 0, width: 24.5, height: 22)) == nil, true,
                    "悬停三键: 自适应模式的 ♪ 占位槽(~24.5pt)不接管")
        expectEqual(H.layout(in: CGRect(x: 0, y: 0, width: 38.5, height: 22)) == nil, true,
                    "悬停三键: 图标槽(~38.5pt)不接管")
        expectEqual(H.layout(in: CGRect(x: 0, y: 0, width: 200, height: 0)) == nil, true,
                    "悬停三键: 高度为 0(尺寸还没落定)不接管")
        expectEqual(H.layout(in: minimumFixedSlot) == nil, false,
                    "悬停三键: 固定宽度模式的最小槽宽(80+18)装得下")

        // 下面这些都要三个格子在手。用 if let 而不是 guard-return:这一节现在排在最后,
        // 用 return 早退的话以后谁在后面加一节就被静默跳过了(else 分支照旧大声失败)。
        if let rects = H.layout(in: minimumFixedSlot),
           let prev = rects[.previous], let mid = rects[.playPause], let nxt = rects[.next] {
            // ② 三格等宽、纵向占满、整块居中
            expectEqual(rects.count, 3, "悬停三键: 恰好三个键")
            expectEqual(prev.width, 24, "悬停三键: 每格 24pt 宽")
            expectEqual(mid.height, 22, "悬停三键: 命中区纵向占满(菜单栏只有 22pt 高)")
            expectEqual(prev.minX, 13, "悬停三键: 98pt 槽里整块居中 → 左边距 (98-72)/2")
            expectEqual(nxt.maxX, 85, "悬停三键: 右边距与左边距对称")

            // ③ 左→右必须是 上一曲 / 播放暂停 / 下一曲 —— 画的顺序和测的顺序是同一份表,
            //    顺序反了就是"看着点下一曲、实际切上一曲"。
            expectEqual(prev.minX < mid.minX && mid.minX < nxt.minX, true,
                        "悬停三键: 左→右 = 上一曲 / 播放暂停 / 下一曲")

            // ④ 命中:三格紧邻,共享的那条边只算给右边那一格(CGRect.contains 是
            //    minX <= x < maxX),所以格与格之间**没有**不命中的缝
            expectEqual(H.control(at: CGPoint(x: 13, y: 11), in: rects), .previous,
                        "命中: 最左那一格的左边界算命中")
            expectEqual(H.control(at: CGPoint(x: 36.9, y: 11), in: rects), .previous,
                        "命中: 边界前一点点还在上一曲")
            expectEqual(H.control(at: CGPoint(x: 37, y: 11), in: rects), .playPause,
                        "命中: 共享边归右边那一格,缝里不落空")
            expectEqual(H.control(at: CGPoint(x: 61, y: 11), in: rects), .next,
                        "命中: 第三格的左边界算命中")
            expectEqual(H.control(at: CGPoint(x: 84.9, y: 11), in: rects), .next,
                        "命中: 右边界前一点点还在下一曲")

            // ⑤ 三个键之外**不命中** —— 那块空地要落回默认动作(弹面板),不能被吞掉
            expectEqual(H.control(at: CGPoint(x: 12.9, y: 11), in: rects) == nil, true,
                        "命中: 左侧留白不命中(要让给弹面板)")
            expectEqual(H.control(at: CGPoint(x: 85, y: 11), in: rects) == nil, true,
                        "命中: 右侧留白不命中")
            expectEqual(H.control(at: CGPoint(x: 40, y: 22), in: rects) == nil, true,
                        "命中: 上边界外不命中(contains 的 maxY 是开区间)")

            // ⑥ 结果必须**稳定**。同 OverlayControlHitTest 那条:字典遍历顺序不确定,靠
            //    "取第一个命中的字典项"会让结果随机,是最难查的一类 bug。这里的实现按
            //    allCases 顺序取,这条断言钉住它别退化回字典遍历。
            var seen = Set<MenuBarTransportControl?>()
            for _ in 1...50 { seen.insert(H.control(at: CGPoint(x: 37, y: 11), in: rects)) }
            expectEqual(seen.count, 1, "命中: 同一点跑 50 次结果必须一致,不随字典顺序变")

            // ⑦ 字形在命中格里居中 —— 画和测同一份格子算出来,不会"看着在这儿、点着在那儿"
            expectEqual(H.glyphRect(in: prev, side: 12),
                        CGRect(x: 19, y: 5, width: 12, height: 12),
                        "字形: 在 24×22 的格子里居中")
        } else {
            expectEqual(true, false, "悬停三键: 最小槽宽(98pt)应当排得出三个键(排不出 = 门槛算错了)")
        }

        // ⑧ 开着「歌词旁的图标」时,三个键只占**歌词那一格**,图标那一块整个留给"弹面板"
        //    (2026-09-03 用户要求:"图标依旧保留…点击图标范围之后依旧是唤起面板")。
        //    这里直接喂一个偏在右侧的格子,模拟"图标在左"那一档:整项 218pt、图标(经典款
        //    20.5)+ 间距 5 占掉最左那 25.5,歌词格 = x 98.5 起、宽 100。
        let lyricsSlot = CGRect(x: 98.5, y: 0, width: 100, height: 22)
        if let rects = H.layout(in: lyricsSlot), let prev = rects[.previous], let nxt = rects[.next] {
            expectEqual(prev.minX, 112.5, "歌词格里居中: 左边距 = (100-72)/2 从格子左边起算,不是从按钮左边")
            expectEqual(nxt.maxX, 184.5, "歌词格里居中: 右端不越出歌词格")
            expectEqual(prev.minX >= lyricsSlot.minX && nxt.maxX <= lyricsSlot.maxX, true,
                        "三个键完全落在歌词格内(越界就会画到图标上)")
            expectEqual(H.control(at: CGPoint(x: 10, y: 11), in: rects) == nil, true,
                        "命中: 图标那一块不属于任何键(点它要落回弹面板)")
            expectEqual(H.control(at: CGPoint(x: 98.5, y: 11), in: rects) == nil, true,
                        "命中: 歌词格左边缘但在三个键左侧的留白,同样不命中")
        } else {
            expectEqual(true, false, "悬停三键: 100pt 宽的歌词格应当排得出三个键")
        }
        // 歌词格窄到放不下就不接管 —— 图标占掉一截之后这件事比整块判定更容易发生
        expectEqual(H.layout(in: CGRect(x: 98.5, y: 0, width: 60, height: 22)) == nil, true,
                    "悬停三键: 歌词格只有 60pt(图标占掉一截)时不接管")

        // ⑨ 歌词格本身怎么算(2026-09-03 修"点暂停生效上一首")。
        //    那个 bug 是同一格算出了两套位置:歌词层按 plan 算(易失,被清了就答不出)、
        //    状态栏项按槽宽算。现在只有这一份算式,两个入口都调它 —— 下面这组数就是用户
        //    真机那套配置(固定宽度 100 + 经典款图标在左 20.5+5 + 系统内边距 18 = 槽宽 143.5),
        //    真机日志实测歌词格 {34.5, 100}、三个键 48.5/72.5/96.5。
        let iconReserved: CGFloat = 20.5 + 5
        if let slot = H.lyricsSlot(buttonWidth: 143.5, contentWidth: 143.5 - 18,
                                   reservedIconWidth: iconReserved, iconLeading: true) {
            expectEqual(slot.x, 34.5, "歌词格: 图标在左时从 左边距 + 图标块 起算")
            expectEqual(slot.width, 100, "歌词格: 宽度 = 整块内容 - 图标块 = 用户设的最大宽度")
            // 两个入口必须算出同一格:歌词层那边喂的是 plan.windowWidth + reserved,
            // 状态栏项那边喂的是 item.length - 系统内边距,数值相等 → 结果必须逐点相同。
            if let viaLabel = H.lyricsSlot(buttonWidth: 143.5, contentWidth: 100 + iconReserved,
                                           reservedIconWidth: iconReserved, iconLeading: true) {
                expectEqual(viaLabel.x, slot.x, "歌词格: 两个入口(按 plan / 按槽宽)算出同一个 x")
                expectEqual(viaLabel.width, slot.width, "歌词格: 两个入口算出同一个宽度")
            } else {
                expectEqual(true, false, "歌词格: 按 plan 那条入口不该算不出来")
            }
            // 三个键落在这一格里 —— 跟真机日志那组数对上
            if let rects = H.layout(in: CGRect(x: slot.x, y: 0, width: slot.width, height: 22)),
               let prev = rects[.previous], let mid = rects[.playPause], let nxt = rects[.next] {
                expectEqual(prev.minX, 48.5, "真机那套配置: 上一曲格 48.5(日志实测值)")
                expectEqual(mid.minX, 72.5, "真机那套配置: 播放暂停格 72.5")
                expectEqual(nxt.minX, 96.5, "真机那套配置: 下一曲格 96.5")
                // ⚠️ 回归钉子:退回"整个按钮居中"会得到 36/60/84,差 12.5pt —— 正好够把
                //    "点暂停"变成"上一首"。这一条就是防这个。
                expectNotEqual(prev.minX, 36, "上一曲格不能退回按整个按钮居中的 36")
            } else {
                expectEqual(true, false, "真机那套配置: 100pt 的歌词格应当排得出三个键")
            }
        } else {
            expectEqual(true, false, "歌词格: 143.5pt 的槽应当算得出歌词格")
        }
        // 图标在右:歌词格从左边距起算,右边让给图标
        if let slot = H.lyricsSlot(buttonWidth: 143.5, contentWidth: 143.5 - 18,
                                   reservedIconWidth: iconReserved, iconLeading: false) {
            expectEqual(slot.x, 9, "歌词格: 图标在右(或没图标)时从左边距起算")
            expectEqual(slot.width, 100, "歌词格: 宽度与图标在哪边无关")
        } else {
            expectEqual(true, false, "歌词格: 图标在右这一档也该算得出来")
        }
        // 没有图标:整块就是歌词格
        expectEqual(H.lyricsSlot(buttonWidth: 118, contentWidth: 100,
                                 reservedIconWidth: 0, iconLeading: false)?.width, 100,
                    "歌词格: 没开图标时整块内容都是歌词格")
        // 算不出来的两种退化:内容宽非正、图标把整块吃光
        expectEqual(H.lyricsSlot(buttonWidth: 143.5, contentWidth: 0,
                                 reservedIconWidth: 0, iconLeading: false) == nil, true,
                    "歌词格: 内容宽为 0 时算不出来(返回 nil,调用方据此不接管)")
        expectEqual(H.lyricsSlot(buttonWidth: 60, contentWidth: 25.5,
                                 reservedIconWidth: 25.5, iconLeading: true) == nil, true,
                    "歌词格: 图标把整块吃光时算不出来")
    }
    // ---- 菜单栏槽宽:短命行不缩槽(2026-09-03,用户报"自适应模式换行时抖动") ----
    //
    // 钉的是那条不变式:只有"活得比静默窗长"的行才有资格改几何 —— 于是下一行的换行时刻
    // 必然已经离上次重建 ≥ 静默窗,它的槽宽变化一定在换行那一刻当场落地,不会拖到句中。
    // 实测抓到的现行与 37% 那组统计见 MenuBarSlotPolicy 的声明处。
    do {
        let P = MenuBarSlotPolicy.self
        let quiet: Double = 3

        // 收缩 + 短命 → 跳过。这就是实测那一幕:121.19 的槽为一句只活 1.2s 的短句缩到 56.70,
        // 结果下一句要 134.09 的加宽被推到句中才落地。
        expectEqual(P.skipsShrink(currentLength: 121.19, targetLength: 56.70,
                                  dwellSeconds: 1.24, quietSecs: quiet), true,
                    "短命行不缩槽: 1.2s 的短句不值得为它收窄")
        // 加宽**永远**不跳过 —— 装不下就是可读性问题,那一句正被迫当跑马灯滚。
        expectEqual(P.skipsShrink(currentLength: 56.70, targetLength: 134.09,
                                  dwellSeconds: 0.5, quietSecs: quiet), false,
                    "短命行不缩槽: 加宽不受这条限制,再短也照改")
        // 活得够久的行照旧收缩,自适应模式该省的空间还是省。
        expectEqual(P.skipsShrink(currentLength: 200, targetLength: 100,
                                  dwellSeconds: 4.5, quietSecs: quiet), false,
                    "短命行不缩槽: 活得比静默窗长的行照旧收窄")
        // 边界:恰好等于静默窗算"够久"(它换到下一行时静默窗刚好走完,不拖累下一行)。
        expectEqual(P.skipsShrink(currentLength: 200, targetLength: 100,
                                  dwellSeconds: quiet, quietSecs: quiet), false,
                    "短命行不缩槽: 恰好等于静默窗的行不算短命")
        expectEqual(P.skipsShrink(currentLength: 200, targetLength: 100,
                                  dwellSeconds: quiet - 0.001, quietSecs: quiet), true,
                    "短命行不缩槽: 差一点点没到静默窗就算短命")
        // 时长取不到(dwell 为 nil)时一律照旧 —— 判据不成立就不该改变既有行为。
        expectEqual(P.skipsShrink(currentLength: 200, targetLength: 100,
                                  dwellSeconds: nil, quietSecs: quiet), false,
                    "短命行不缩槽: 算不出这一句会显示多久时照旧收窄")
        // 宽度没变不算收缩(present 那边本来就走 needsRebuild=false 的早退)。
        expectEqual(P.skipsShrink(currentLength: 150, targetLength: 150,
                                  dwellSeconds: 0.2, quietSecs: quiet), false,
                    "短命行不缩槽: 宽度没变不算收缩")

        // ---- 收缩死区:太小的收缩一律不值一次重建(2026-09-03 复采日志时抓到的第二种浪费)
        // 实测原样:text(250.749512) -> text(250.438477),0.31pt 的差也触发了整项重建。
        expectEqual(P.skipsShrink(currentLength: 250.749512, targetLength: 250.438477,
                                  dwellSeconds: 12, quietSecs: quiet), true,
                    "收缩死区: 0.31pt 的亚像素收缩跳过,哪怕这一句活得很久")
        expectEqual(P.skipsShrink(currentLength: 200, targetLength: 200 - P.minimumShrinkPoints + 0.01,
                                  dwellSeconds: 12, quietSecs: quiet), true,
                    "收缩死区: 差一点点没到死区门槛就跳过")
        expectEqual(P.skipsShrink(currentLength: 200, targetLength: 200 - P.minimumShrinkPoints,
                                  dwellSeconds: 12, quietSecs: quiet), false,
                    "收缩死区: 恰好等于门槛就照常收缩")
        // ⚠️ 死区**只对收缩**:加宽差几 pt 也得给 —— 差一点点装不下,整句就退化成跑马灯滚。
        expectEqual(P.skipsShrink(currentLength: 250.438477, targetLength: 250.749512,
                                  dwellSeconds: 0.5, quietSecs: quiet), false,
                    "收缩死区: 同样 0.31pt,加宽方向照改不误")
        // 死区不累积:每次都跟**当前槽宽**比,连着几句各小一点,越过门槛就照常收缩。
        expectEqual(P.skipsShrink(currentLength: 200, targetLength: 185,
                                  dwellSeconds: 12, quietSecs: quiet), false,
                    "收缩死区: 相对当前槽宽累到 15pt 就照常收缩,不会永远缩不回去")
    }

    // ---- 「♪ 歌名」占槽兜底(2026-09-04)----
    //
    // 整首没歌词 / 还在搜的歌,菜单栏此前直接塌回小图标(灵动岛 / 悬浮歌词都有占位文案,唯它没有)。
    // 判据在 MenuBarSlotPolicy.displayText,三条边界是刻意保留的:暂停不占宽(2026-08-19 用户定的)、
    // 广告不显示广告标题、没歌名不做品牌兜底。
    do {
        typealias P = MenuBarSlotPolicy
        func t(_ lyric: String, _ title: String, playing: Bool = true, ad: Bool = false, on: Bool = true)
            -> (text: String, isFallback: Bool)? {
            P.displayText(lyricText: lyric, title: title, isPlaying: playing, isAdBreak: ad,
                          showsTitleWhenNoLyrics: on, placeholderGlyph: "♪")
        }
        expectEqual(t("对这个世界如果你有太多的抱怨", "稻香")?.text, "对这个世界如果你有太多的抱怨", "歌名兜底: 有歌词句就显示歌词句")
        expectEqual(t("对这个世界如果你有太多的抱怨", "稻香")?.isFallback, false, "歌名兜底: 歌词句不算兜底")
        expectEqual(t("♪", "稻香")?.text, "♪", "歌名兜底: 间奏的 ♪ 原样保留,不换成歌名")
        expectEqual(t("", "稻香")?.text, "♪ 稻香", "歌名兜底: 没有可显示的行 → ♪ 歌名")
        expectEqual(t("", "稻香")?.isFallback, true, "歌名兜底: 标成兜底,配速不按歌词时长算")
        expectEqual(t("", "  稻香  ")?.text, "♪ 稻香", "歌名兜底: 歌名去首尾空白")
        expectEqual(t("", "稻香", playing: false) == nil, true, "歌名兜底: 暂停一律收回图标(2026-08-19「暂停不占宽」)")
        expectEqual(t("有词", "稻香", playing: false) == nil, true, "歌名兜底: 暂停时有词也收回,既有行为不变")
        expectEqual(t("", "Ad Title", ad: true) == nil, true, "歌名兜底: 广告态不显示广告标题")
        expectEqual(t("", "") == nil, true, "歌名兜底: 没歌名就还是图标,不做品牌兜底")
        expectEqual(t("", "稻香", on: false) == nil, true, "歌名兜底: 开关关着照旧收回图标")
    }
}
