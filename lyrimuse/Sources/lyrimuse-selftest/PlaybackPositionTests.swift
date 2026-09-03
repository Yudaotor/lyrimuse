import LyrimuseCore
import Foundation

// 播放位置:外推伺服 / 锚点 / seek / 浏览器探针。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runPlaybackPositionTests() {
    // ---- MediaControlClient.ageCompensatedCachedElapsed: 借用后台 AppleScript 缓存 ----
    // 快照前的年龄补偿+合理性核对(2026-08-04 实测排查坐实的回归:缓存值不补偿年龄直接
    // 当"当前位置"用,本地整条展示链慢 ~1.8s,详见该函数注释)。

    do {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // 稳定播放:缓存读数 100.0s、1.8s 前抓的、速率 1 → 补偿到 101.8s;新鲜读数 101.9s,
        // 差 0.1s 在核对容差内 → 借用补偿后的值,而不是原始的 100.0。
        let steady = MediaControlClient.ageCompensatedCachedElapsed(
            cachedElapsed: 100.0, cachedPlaying: true, cachedRate: 1, cachedAt: t0,
            freshElapsed: 101.9, freshPlaying: true, now: t0.addingTimeInterval(1.8)
        )
        expectEqual(steady.map { abs($0 - 101.8) < 0.001 }, true, "ageCompensatedCachedElapsed: 稳定播放按读数年龄×速率补偿")
        // 单曲循环重启:缓存还是上一轮循环的位置(240s),真实已经回到 1.6s → 补偿后跟新鲜
        // 读数差 2s 以上,缓存不可信,返回 nil(调用方退回新鲜读数)。
        let loopRestart = MediaControlClient.ageCompensatedCachedElapsed(
            cachedElapsed: 240.0, cachedPlaying: true, cachedRate: 1, cachedAt: t0,
            freshElapsed: 1.6, freshPlaying: true, now: t0.addingTimeInterval(1.8)
        )
        expectEqual(loopRestart == nil, true, "ageCompensatedCachedElapsed: 单曲循环重启后过期缓存不借用")
        // 缓存是暂停态读数(刚恢复播放):这段年龄里位置没在走,没法按速率外推 → 不借用。
        let pausedCache = MediaControlClient.ageCompensatedCachedElapsed(
            cachedElapsed: 100.0, cachedPlaying: false, cachedRate: 0, cachedAt: t0,
            freshElapsed: 100.1, freshPlaying: true, now: t0.addingTimeInterval(1.8)
        )
        expectEqual(pausedCache == nil, true, "ageCompensatedCachedElapsed: 暂停态缓存读数不借用")
        // 切歌加载瞬间速率短暂报 0 但确实在播:按速率 1 计,跟 collector/lb.go 同一处理。
        let zeroRate = MediaControlClient.ageCompensatedCachedElapsed(
            cachedElapsed: 100.0, cachedPlaying: true, cachedRate: 0, cachedAt: t0,
            freshElapsed: 101.9, freshPlaying: true, now: t0.addingTimeInterval(1.8)
        )
        expectEqual(zeroRate.map { abs($0 - 101.8) < 0.001 }, true, "ageCompensatedCachedElapsed: 播放中速率报 0 按 1 计")
    }

    // ---- MediaControlClient.livePositionSeconds: rate 缺失时别信 elapsedTimeNow ----
    // (2026-08-18 实测坐实:Spotify 暂停后恢复播放,上报的 playbackRate 变成 null,而
    // media-control 的 --now 外推是 elapsed + (now-ts)*rate —— rate 缺失时增量为 0,
    // elapsedTimeNow 15 秒纹丝不动。那个恒定值喂进伺服会把位置一路拽回去、歌词冻在一行。)

    do {
        let ts = Date(timeIntervalSince1970: 1_000_000)
        // rate 正常:优先用 media-control 自己的外推(实测比自算准一个量级)。
        let healthy = MediaControlClient.livePositionSeconds(
            playing: true, elapsedTime: 170.866, elapsedTimeNow: 176.21,
            playbackRate: 1, timestamp: ts, now: ts.addingTimeInterval(6.0))
        expectEqual(healthy.map { ($0 * 100).rounded() / 100 }, 176.21,
                    "livePositionSeconds: rate 正常时用 elapsedTimeNow")

        // rate 缺失(恢复播放后的实测形态):elapsedTimeNow 已经退化成 elapsedTime,
        // 必须自己按 rate=1 补算,否则位置恒定不动。
        let stalled = MediaControlClient.livePositionSeconds(
            playing: true, elapsedTime: 178.604, elapsedTimeNow: 178.604,
            playbackRate: nil, timestamp: ts, now: ts.addingTimeInterval(16.0))
        expectEqual(stalled.map { ($0 * 1000).rounded() / 1000 }, 194.604,
                    "livePositionSeconds: rate 缺失时按墙钟自己补算,不能停在 178.604")

        // 同一份输入连采两次必须给出**不同**的位置 —— 这条才是这个 bug 的直接断言。
        let a = MediaControlClient.livePositionSeconds(
            playing: true, elapsedTime: 178.604, elapsedTimeNow: 178.604,
            playbackRate: nil, timestamp: ts, now: ts.addingTimeInterval(2))
        let b = MediaControlClient.livePositionSeconds(
            playing: true, elapsedTime: 178.604, elapsedTimeNow: 178.604,
            playbackRate: nil, timestamp: ts, now: ts.addingTimeInterval(15))
        expectEqual((a ?? 0) < (b ?? 0), true,
                    "livePositionSeconds: rate 缺失时位置必须随时间前进(暂停后恢复的冻结 bug)")

        // 暂停态:elapsedTimeNow 在暂停期间照样涨(实测拿到过远超曲长的值),必须用原始 elapsedTime。
        let paused = MediaControlClient.livePositionSeconds(
            playing: false, elapsedTime: 104.948, elapsedTimeNow: 108.428,
            playbackRate: 1, timestamp: ts, now: ts.addingTimeInterval(30))
        expectEqual(paused, 104.948, "livePositionSeconds: 暂停时用冻结的 elapsedTime,不外推")

        // ---- 整秒时间戳的相位订正(2026-08-21) ----
        //
        // 实测:media-control 的 timestamp 恒无小数秒,`ts = floor(真实时刻)`,于是
        // `位置 + (now − ts)` 恒偏快 frac 秒。用 Apple Music 的 AppleScript 播放头当独立真值
        // 采了 12 个样本:偏差 +0.824s、极差只有 0.042s —— 同一个锚点上稳如磐石(锚点冻结了
        // 51 秒没刷新,所以测到的就是这一个锚点的 frac)。
        //
        // 订正靠夹逼:τ ∈ [ts, min(ts+1, 首见时刻)],取中点。下面守的是这个式子的三条性质。
        do {
            let ts = Date(timeIntervalSince1970: 1_000_000)
            func est(_ gap: Double) -> Double {
                MC.estimatedAnchorInstant(timestamp: ts, firstSeenAt: ts.addingTimeInterval(gap))
                    .timeIntervalSince(ts)
            }
            // 事件流即时发现:订正量 = 间隔的一半,很小
            // Date 走 Double 秒数(基准 1e6 量级),往返会掉有效位 —— 这几条按毫秒四舍五入再比,
            // 不是放宽要求,是别把浮点表示误差当成逻辑错。
            func ms(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
            expectEqual(ms(est(0.10)), 0.05, "相位订正: 即时发现时只订正间隔的一半")
            expectEqual(ms(est(0.90)), 0.45, "相位订正: 间隔 0.9 → 订正 0.45")
            // 只靠 2 秒轮询发现:间隔 ≥ 1 一律夹到 1(frac < 1),退化成 ts + 0.5
            expectEqual(est(1.00), 0.5, "相位订正: 间隔到 1 就夹住(frac 不可能 ≥ 1)")
            expectEqual(est(5.00), 0.5, "相位订正: 间隔再大也只到 ts+0.5,不会过冲")
            // 永远不会比现状(ts 本身)更差:订正量恒在 [0, 0.5]
            for gap in [0.01, 0.3, 0.7, 1.0, 2.0, 30.0] {
                let v = est(gap)
                expectEqual(v >= 0 && v <= 0.5, true, "相位订正: 订正量恒在 [0,0.5](间隔 \(gap))")
            }
            // 首见时刻早于时间戳(时钟回拨/解析异常)→ 不猜,原样返回
            expectEqual(MC.estimatedAnchorInstant(timestamp: ts, firstSeenAt: ts.addingTimeInterval(-3)),
                        ts, "相位订正: 首见早于时间戳时原样返回,不倒推")

            // 冻结锚点走自己的外推(订正后基准),不再用 media-control 那个偏快的 elapsedTimeNow
            let frozen = MC.livePositionSeconds(
                playing: true, elapsedTime: 100, elapsedTimeNow: 130.0,
                playbackRate: 1, timestamp: ts, now: ts.addingTimeInterval(30),
                lastPlayingPosition: nil, firstSeenAt: ts.addingTimeInterval(0.4))
            // 订正后基准 = ts+0.2 → 位置 = 100 + (30 − 0.2) = 129.8(比 130 慢 0.2,正是订正量)
            expectEqual(frozen.map { (($0) * 1000).rounded() / 1000 }, 129.8,
                        "相位订正: 冻结锚点按订正后的基准自己外推")
            // 锚点还新鲜(age ≤ 门槛)→ 不接手,仍然用 elapsedTimeNow(QQ/网易云那条路不受影响)
            let fresh = MC.livePositionSeconds(
                playing: true, elapsedTime: 100, elapsedTimeNow: 100.9,
                playbackRate: 1, timestamp: ts, now: ts.addingTimeInterval(0.9),
                lastPlayingPosition: nil, firstSeenAt: ts.addingTimeInterval(0.2))
            expectEqual(fresh, 100.9, "相位订正: 锚点新鲜时不接手,行为跟改动前一致")
            // 不传 firstSeenAt(既有调用方)同样不接手
            let legacy = MC.livePositionSeconds(
                playing: true, elapsedTime: 100, elapsedTimeNow: 130.0,
                playbackRate: 1, timestamp: ts, now: ts.addingTimeInterval(30))
            expectEqual(legacy, 130.0, "相位订正: 不传首见时刻时行为跟改动前逐字相同")
        }

        // ---- 锚点冻结的源:暂停时不能回退到那个恒为 0 的 elapsedTime(2026-08-21) ----
        //
        // 2026-08-21 用户报「用 Arc 播放音乐歌词进度慢」时查出来的连带 bug。Arc 这类网页播放器
        // (页面没调 mediaSession.setPositionState)实测 elapsedTime 恒 0、timestamp 恒为开播
        // 那一刻,于是"暂停时用原始 elapsedTime"这条既有规则会让位置**直接归零** —— 用户视角
        // 是"在浏览器里一按暂停,歌词跳回第一句"。
        typealias MC = MediaControlClient
        // ① Arc 形态:锚点 187 秒没刷新 + 报告值 0 → 用播放中最后一次位置
        expectEqual(MC.pausedPositionSeconds(elapsedTime: 0, anchorAge: 187, lastPlayingPosition: 187),
                    187, "暂停位置: 锚点冻结的源用最后已知位置,不归零")
        // ② 会刷新锚点的源:时间戳新鲜 → 原样用报告值,哪怕它比最后位置低得多
        //    (向后 seek 之后暂停就是这个形状,这一条保住它不被误改)
        expectEqual(MC.pausedPositionSeconds(elapsedTime: 12, anchorAge: 0.3, lastPlayingPosition: 100),
                    12, "暂停位置: 锚点新鲜时原样用报告值(向后 seek 后暂停)")
        // ③ 正常暂停:两者只差一拍
        expectEqual(MC.pausedPositionSeconds(elapsedTime: 99, anchorAge: 30, lastPlayingPosition: 100),
                    99, "暂停位置: 只差一拍不算冻结")
        // ④⑤ 缺输入时一律原样,不猜
        expectEqual(MC.pausedPositionSeconds(elapsedTime: 0, anchorAge: 999, lastPlayingPosition: nil),
                    0, "暂停位置: 没有最后位置时原样返回")
        expectEqual(MC.pausedPositionSeconds(elapsedTime: 0, anchorAge: nil, lastPlayingPosition: 187),
                    0, "暂停位置: 拿不到锚点年龄时原样返回")
        // ⑥⑦ 两个门槛的边界都是"等于不算"
        expectEqual(MC.pausedPositionSeconds(elapsedTime: 0, anchorAge: MC.staleAnchorAfter,
                                             lastPlayingPosition: 187),
                    0, "暂停位置: 年龄等于门槛不算陈旧")
        expectEqual(MC.pausedPositionSeconds(elapsedTime: 100, anchorAge: 60,
                                             lastPlayingPosition: 100 + MC.frozenAnchorPauseDrop),
                    100, "暂停位置: 跌幅等于门槛不算冻结")
        // ⑧ 既有行为不变:不传 lastPlayingPosition 时 livePositionSeconds 跟改动前逐字相同
        expectEqual(MC.livePositionSeconds(playing: false, elapsedTime: 104.948, elapsedTimeNow: 999,
                                           playbackRate: 1, timestamp: nil, now: Date()),
                    104.948, "暂停位置: 不传最后位置时行为跟改动前一致")

        // rate 为 0 跟缺失同义(media-control 恢复播放后也报过 0)。
        let zeroRate = MediaControlClient.livePositionSeconds(
            playing: true, elapsedTime: 10, elapsedTimeNow: 10,
            playbackRate: 0, timestamp: ts, now: ts.addingTimeInterval(5))
        expectEqual(zeroRate, 15, "livePositionSeconds: rate=0 与缺失同义,同样自己补算")

        // 时钟回拨/时间戳解析异常时不倒推。
        let backwards = MediaControlClient.livePositionSeconds(
            playing: true, elapsedTime: 50, elapsedTimeNow: 50,
            playbackRate: nil, timestamp: ts, now: ts.addingTimeInterval(-10))
        expectEqual(backwards, 50, "livePositionSeconds: 时间戳在未来时不倒推位置")
    }

    do {
        // timestamp 解析:media-control 实测给不带小数秒的 Z 形式,也要兼容带小数秒的。
        expectEqual(MediaControlClient.parseTimestamp("2026-08-18T08:51:46Z") != nil, true,
                    "parseTimestamp: 不带小数秒的 ISO8601 能解")
        expectEqual(MediaControlClient.parseTimestamp("2026-08-18T08:51:46.123Z") != nil, true,
                    "parseTimestamp: 带小数秒的 ISO8601 能解")
        expectEqual(MediaControlClient.parseTimestamp(nil) == nil, true,
                    "parseTimestamp: nil 进 nil 出")
    }

    // ---- LocalPlaybackSource.servoDecision: 播放位置外推的"锁死偏差"伺服校正 ----
    // (2026-08-04 实测排查坐实:稳定播放分支只按墙钟外推、不回看真实读数,播种偏差/漏观察
    // 的短暂停会造成小于 seek 容差的永久锁死,详见该函数注释。)

    do {
        // 精确源(Apple Music):持续 1.2s 的锁死偏差(漏观察的短暂停)应在几轮内触发校正。
        var ema = 0.0
        var snapped = false
        var rounds = 0
        for _ in 1...5 {
            rounds += 1
            let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: -1.2, tier: .precise)
            ema = newEMA
            if snap { snapped = true; break }
        }
        expectEqual(snapped, true, "servoDecision(精确源): 持续 1.2s 偏差应触发校正")
        expectEqual(rounds <= 3, true, "servoDecision(精确源): 校正应在 3 轮(6 秒)内发生,实际 \(rounds) 轮")
    }

    do {
        // 精确源:实测抓到的那次 0.205s 启动播种偏差,同样应该被修正(原实现会永久锁死)。
        var ema = 0.0
        var snapped = false
        for _ in 1...10 {
            let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: 0.205, tier: .precise)
            ema = newEMA
            if snap { snapped = true; break }
        }
        expectEqual(snapped, true, "servoDecision(精确源): 0.205s 的播种偏差(实测案例)应被校正")
    }

    do {
        // 精确源:±0.06s 的正常读数噪声(零均值)不该误触发校正。
        var ema = 0.0
        var falseSnap = false
        for i in 1...50 {
            let err = i % 2 == 0 ? 0.06 : -0.06
            let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: err, tier: .precise)
            ema = newEMA
            if snap { falseSnap = true; break }
        }
        expectEqual(falseSnap, false, "servoDecision(精确源): ±0.06s 零均值噪声不该误触发")
    }

    do {
        // 噪声源(QQ 音乐):±1.5s 的零均值抖动不该误触发校正——这正是原来"只按墙钟外推"
        // 设计要防的场景,伺服不能把它破坏掉。
        var ema = 0.0
        var falseSnap = false
        for i in 1...50 {
            let err = i % 2 == 0 ? 1.5 : -1.5
            let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: err, tier: .noisyFloored)
            ema = newEMA
            if snap { falseSnap = true; break }
        }
        expectEqual(falseSnap, false, "servoDecision(噪声源): ±1.5s 零均值抖动不该误触发")
    }

    do {
        // 噪声源:持续 +1.5s 的真锁死偏差(低于 2s seek 容差,原来永远修不掉)应该能修正。
        var ema = 0.0
        var snapped = false
        for _ in 1...10 {
            let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: 1.5, tier: .noisyFloored)
            ema = newEMA
            if snap { snapped = true; break }
        }
        expectEqual(snapped, true, "servoDecision(噪声源): 持续 1.5s 锁死偏差应最终被校正")
    }

    // ---- servoDecision 第三档:Spotify(cleanExtrapolated,2026-08-18 拆档) ----
    //
    // 背景(实测 140+ 样本):Spotify 的 elapsedTimeNow 稳态偏差 ±0.05s、比 QQ 音乐干净
    // 一个量级,但换歌头几秒 MediaRemote 报数是脏的(最高 +1.32s)。播种进 <1.0s 的超前值
    // 后,老的 noisyFloored 1.0s 门槛让它整曲不被纠正——"Spotify 歌词经常偏快"的主因。
    do {
        // 换歌脏窗口播种 +0.8s 超前(老门槛下整曲锁死)——应在 3 轮(~6 秒)内校正。
        var ema = 0.0
        var snapped = false
        var rounds = 0
        for _ in 1...5 {
            rounds += 1
            let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: -0.8, tier: .cleanExtrapolated)
            ema = newEMA
            if snap { snapped = true; break }
        }
        expectEqual(snapped, true, "servoDecision(Spotify): 0.8s 播种超前应触发校正")
        expectEqual(rounds <= 3, true, "servoDecision(Spotify): 校正应在 3 轮内发生,实际 \(rounds) 轮")
    }

    do {
        // 暂停/切换瞬间的单发陈旧读数(实测 -1.27s)不该触发回跳——EMA 只到 -0.38,低于门槛。
        let (ema1, snap1) = LocalPlaybackSource.servoDecision(errEMA: 0, error: -1.27, tier: .cleanExtrapolated)
        expectEqual(snap1, false, "servoDecision(Spotify): 单发 -1.27s 陈旧读数不回跳")
        // 下一轮恢复干净读数,EMA 衰减、依旧不触发。
        let (_, snap2) = LocalPlaybackSource.servoDecision(errEMA: ema1, error: -0.05, tier: .cleanExtrapolated)
        expectEqual(snap2, false, "servoDecision(Spotify): 陈旧读数后一轮即衰减不触发")
    }

    do {
        // 稳态 ±0.05s 抖动(实测量级)绝不该误触发。
        var ema = 0.0
        var falseSnap = false
        for i in 1...50 {
            let err = i % 2 == 0 ? 0.05 : -0.05
            let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: err, tier: .cleanExtrapolated)
            ema = newEMA
            if snap { falseSnap = true; break }
        }
        expectEqual(falseSnap, false, "servoDecision(Spotify): ±0.05s 稳态抖动不误触发")
    }

    // ---- 自然切歌锚点超前校正(2026-08-20):Spotify gapless 整曲偏快的根修 ----
    //
    // 实测(Forever Love→在那遙遠的地方,0.25s 采样):自然切歌时元数据/新锚点先于真声
    // 0.837s 打好,整曲 elapsedTimeNow 恒定超前 +0.888s±0.009 且锚点从不重打——伺服对
    // "每笔读数与外推步调一致的常量偏置"结构性失明,必须在换歌那拍用旧曲连续外推当真值
    // 把偏置量出来、之后逐笔扣除。机制详见 LocalPlaybackSource.naturalAdvanceCorrection。
    do {
        // 实测样本:首笔原始读数 0.048、旧曲连续外推越界 -0.837(真声还剩 0.837s)。
        let corr = LocalPlaybackSource.naturalAdvanceCorrection(reported: 0.048, overrun: -0.837)
        expectEqual(corr != nil, true, "naturalAdvance: 实测切歌样本应被校正")
        if let corr {
            expectEqual(abs(corr.seed - (-0.837)) < 1e-9, true, "naturalAdvance: 播种=越界量(允许为负,UI 钳 0 等真声)")
            expectEqual(abs(corr.bias - 0.885) < 1e-9, true, "naturalAdvance: 偏置=读数-越界量")
        }
    }

    do {
        // 元数据晚于真声切换(越界为正):真值=越界量,同样成立。
        let corr = LocalPlaybackSource.naturalAdvanceCorrection(reported: 1.5, overrun: 0.6)
        expectEqual(corr?.seed == 0.6 && corr?.bias == 0.9, true, "naturalAdvance: 晚切元数据也按连续性播种")
    }

    do {
        // 四类不校正:手动跳歌(窗口外)/噪声级偏置/陈旧读数(08-18 实测换歌瞬间还挂上一首的
        // 30.3)/负偏置(模型外)。返回 nil = 按原逻辑采信读数(改动前行为)。
        expectEqual(LocalPlaybackSource.naturalAdvanceCorrection(reported: 0.3, overrun: -188) == nil, true, "naturalAdvance: 手动跳歌不校正")
        expectEqual(LocalPlaybackSource.naturalAdvanceCorrection(reported: 0.3, overrun: 0.28) == nil, true, "naturalAdvance: 噪声级偏置不校正")
        expectEqual(LocalPlaybackSource.naturalAdvanceCorrection(reported: 30.3, overrun: -0.5) == nil, true, "naturalAdvance: 陈旧首笔读数不校正")
        expectEqual(LocalPlaybackSource.naturalAdvanceCorrection(reported: 0.1, overrun: 0.9) == nil, true, "naturalAdvance: 负偏置不校正")
    }

    do {
        // 误判伤害上限:偏置守卫把"手动跳歌恰好发生在结尾窗口内"的错误校正钉死在 ≤2.5s。
        let corr = LocalPlaybackSource.naturalAdvanceCorrection(reported: 3.2, overrun: 0.2)
        expectEqual(corr == nil, true, "naturalAdvance: 超过 \(LocalPlaybackSource.naturalAdvanceMaxBiasSecs)s 的偏置不采信")
    }

    // ---- 冻结守卫(2026-08-18):曲目/广告结尾 Spotify 锚点冻住 ----
    //
    // 实测(边界探针):广告结尾 elapsedTimeNow 卡死 6 秒,真声一路走到落后 8 秒。不拦的话
    // 冻结值几秒后超过 2s seek 容差,位置被"重锚"回冻结值,歌尾歌词整段倒回去 —— 用户报
    // "自动切歌之后变慢"的主要成分。
    do {
        typealias L = LocalPlaybackSource
        expectEqual(L.isFrozenReport(reportedAdvance: 0.0, gap: 2.0, rate: 1, tier: .cleanExtrapolated),
                    true, "冻结守卫: 报告值 2 秒没动判冻结")
        expectEqual(L.isFrozenReport(reportedAdvance: 2.0, gap: 2.0, rate: 1, tier: .cleanExtrapolated),
                    false, "冻结守卫: 正常推进不误判")
        expectEqual(L.isFrozenReport(reportedAdvance: -8.0, gap: 2.0, rate: 1, tier: .cleanExtrapolated),
                    false, "冻结守卫: 向后 seek 是大负数,不误判(判的是几乎没动)")
        expectEqual(L.isFrozenReport(reportedAdvance: 8.2, gap: 2.0, rate: 1, tier: .cleanExtrapolated),
                    false, "冻结守卫: 解冻大步前跳不拦,落回 seek 分支瞬间追上")
        expectEqual(L.isFrozenReport(reportedAdvance: 0.02, gap: 0.3, rate: 1, tier: .cleanExtrapolated),
                    false, "冻结守卫: 事件触发的短间隔补查不判(正常前进量也接近 0)")
        expectEqual(L.isFrozenReport(reportedAdvance: 0.0, gap: 2.0, rate: 1, tier: .noisyFloored),
                    false, "冻结守卫: QQ/网易云档不启用")
        // 冻结的**第一拍**检测还认不出(只有一次大负偏差),靠单样本限幅兜住:
        // 0.3×(-1.74) = -0.52 本会冲过 0.4 门槛把歌词拖回半秒,限幅后只到 -0.225。
        let (_, snap) = L.servoDecision(errEMA: 0, error: -1.74, tier: .cleanExtrapolated)
        expectEqual(snap, false, "冻结守卫: 第一拍大负偏差被限幅拦住,不回拖")
    }

    // ---- LocalPlaybackSource: seek 之后丢弃陈旧位置读数(2026-08-05) ----
    //
    // 审查确认的 IMPORTANT:seek 发出去之后,在飞的那次 poll(子进程往返几十到几百毫秒)拿到的
    // 是 seek **之前**的位置,落地后会被当成"真实 seek 跳变"硬重锚回旧位置——松手跳过去、一瞬间
    // 又弹回来。除了作废在飞的 poll(pollGeneration),还需要这道判据兜住"seek 之后新发起、但
    // 播放器状态还没跟上"的那些读数(Music.app 实测要 ~294ms 才切换)。

    do {
        let f = LocalPlaybackSource.shouldRejectStalePositionAfterSeek
        // 从 30s 拖到 120s,读数还是 30s → 更靠近旧位置 → 丢弃
        expectEqual(f(30.2, 120, 30, 0.1), true, "seek 静默窗: 读数还在旧位置附近 → 丢弃")
        // 读数已经跟上目标 → 接受
        expectEqual(f(120.3, 120, 30, 0.1), false, "seek 静默窗: 读数已跟上目标 → 接受")
        // 窗口过了就一律接受,不能永久拒收(否则真的 seek 到别处就再也纠正不回来)
        expectEqual(f(30.2, 120, 30, 5.0), false, "seek 静默窗: 超出窗口后不再拦")
        // 小幅拖动:从 100s 拖到 100.5s,读数 100.0 更靠近旧位置 → 丢弃
        // (这一支很重要:Apple Music 是 preciseSource,servo 门槛只有 0.15s,不拦就会被
        //  snap 回旧位置,根本用不着超过 2s 的 seek 容差)
        expectEqual(f(100.0, 100.5, 100, 0.1), true, "seek 静默窗: 小幅拖动同样要拦")
        // 正好等距时不丢——拖动幅度极小时两者本来分不开,丢了反而卡住自愈
        expectEqual(f(75, 100, 50, 0.1), false, "seek 静默窗: 与新旧位置等距时不拦")
        // 负的 elapsed(时钟回跳)不拦
        expectEqual(f(30, 120, 30, -1), false, "seek 静默窗: 时间差为负时不拦")
    }

    // ---- MusicPlaybackController.seek: 参数格式化与夹值(2026-08-05) ----
    //
    // seek 的 I/O(发 AppleScript / 跑 media-control)没法在 selftest 里跑,但"传进去的数值
    // 长什么样"是纯计算、而且是最容易出错的地方:直接插值 Double 可能吐出
    // "2.2000000000000002" 这种长尾表示,拼进 AppleScript 源码里不保险。

    do {
        let arg = MusicPlaybackController.seekArgument(forSeconds:)
        expectEqual(arg(2.2), "2.200", "seek: 浮点长尾被截成 3 位小数")
        expectEqual(arg(255.4567), "255.457", "seek: 四舍五入到毫秒精度")
        expectEqual(arg(0), "0.000", "seek: 0 正常")
        expectEqual(arg(-5), "0.000", "seek: 负值夹到 0")
        // 上界故意不夹(这一层不知道时长),原样透给播放器
        expectEqual(arg(99999.5), "99999.500", "seek: 上界不夹,原样透传")
        // 非有限值(比例算式里 0 除 0 之类)不能拼出 "nan"/"inf" 进 AppleScript
        expectEqual(arg(.nan), "0.000", "seek: NaN 退化成 0 而不是拼出 nan")
        expectEqual(arg(.infinity), "0.000", "seek: 无穷大退化成 0")
        // 钉住"小数点必须是点"。实测核实过 String(format:) 不带 locale 本来就不本地化,所以
        // 这条不是在防一个现存 bug,而是防以后有人顺手把 locale 改成 .current —— 那样在逗号
        // 小数点的区域会拼出 "2,200",AppleScript 直接语法错误。
        expectEqual(arg(2.2).contains(","), false, "seek: 小数点固定用点(拼进 AppleScript 不能是逗号)")
    }

    // ── 逐字数据退化时必须退回整行模式(2026-08-06) ──
    // 实测过的真实形态:某些源给的 YRC 只包含开头的署名行,正文一行都没有;署名行被过滤后
    // wordLines 只剩极少几行,而 activeLine 取的是"时间戳 <= 当前位置的最后一行",于是整首歌
    // 从头到尾都停在那一行上。判据是覆盖率,不是"YRC 是否为空"。
    do {
        let yrc = [
            "[60,900](60,400,0)特别的人 - 方大同",
            "[1110,600](1110,600,0)词：方大同",
            "[1760,600](1760,600,0)曲：方大同",
        ].joined(separator: "\n")
        var lrcLines: [String] = []
        for i in 0..<10 {
            lrcLines.append("[00:" + String(format: "%02d", i * 5) + ".000]第 " + String(i) + " 句歌词")
        }
        let lrc = lrcLines.joined(separator: "\n")

        let engine = LyricsSyncEngine()
        engine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc)
        // 3 行逐字 vs 10 行整行 → 覆盖率不足,退回整行;45 秒处应命中第 9 句
        expectEqual(engine.activeLine(atMs: 45_000)?.plainText, "第 9 句歌词", "逐字数据退化时退回整行歌词")

        // 没有整行歌词可退时仍然用逐字数据(不能因为覆盖率判据把唯一的内容也否掉)
        let onlyWords = LyricsSyncEngine()
        onlyWords.load(lyrics: "", lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc)
        expectEqual(onlyWords.hasContent, true, "没有整行歌词时仍使用逐字数据")
    }

    // ---- 地板量化源的前向棘轮 ----
    do {
        typealias Tier = LocalPlaybackSource.PositionSourceTier
        func ratchet(_ reported: Double, _ predicted: Double, tier: Tier) -> Bool {
            LocalPlaybackSource.shouldRatchetForward(
                reported: reported, predicted: predicted, tier: tier)
        }
        // QQ 音乐实测的形状：新锚点比外推值靠前 1 秒（旧锚点被向下取整拖晚了）。
        expectEqual(ratchet(23.1, 22.1, tier: .noisyFloored), true, "棘轮: 前向 1s 立刻采纳")
        expectEqual(ratchet(22.4, 22.1, tier: .noisyFloored), true, "棘轮: 前向 0.3s(半个字)也采纳")
        // 反方向分不清是取整噪声还是真实回退，绝不能棘轮 —— 交给原有 EMA 路径。
        expectEqual(ratchet(21.5, 22.1, tier: .noisyFloored), false, "棘轮: 后向不采纳(交给 EMA)")
        // 同锚点外推的 ±2ms 漂移不值得重建锚点。
        expectEqual(ratchet(22.102, 22.1, tier: .noisyFloored), false, "棘轮: 毫米级漂移不触发")
        // 精确源(Apple Music)的读数本来就是真值，不适用"reported ≤ 真实位置"这条
        // 不等式，走原有 EMA。
        expectEqual(ratchet(23.1, 22.1, tier: .precise), false, "棘轮: 精确源不适用")
        // Spotify(cleanExtrapolated)的读数恒略**超前**真值(2026-08-18 实测),棘轮前提
        // 正好反着——只往前吸附会把位置锁在抖动上包络,2026-08-18 拆档时明确排除。
        expectEqual(ratchet(23.1, 22.1, tier: .cleanExtrapolated), false,
                    "棘轮: Spotify 干净外推源不适用")
    }

    // ---- BrowserPositionProbe:解析逻辑(2026-08-30) ----
    // 只测这段纯解析——真正发 AppleScript 的部分依赖真实 Arc + 已打开的网页,没法在
    // CI/无 GUI 环境里稳定跑,端到端行为已手动验证过(见该文件头注)。
    do {
        typealias P = BrowserPositionProbe
        expectEqual(P.parseSeconds(fromOsascriptOutput: "\"168|0\""), 168,
                    "浏览器探针解析: 正常格式(带 osascript 外层引号)")
        expectEqual(P.parseSeconds(fromOsascriptOutput: "168|0"), 168,
                    "浏览器探针解析: 没有外层引号也能解析(防御性)")
        expectEqual(P.parseSeconds(fromOsascriptOutput: "\"168|1\""), nil,
                    "浏览器探针解析: paused=1(暂停中)不采信")
        expectEqual(P.parseSeconds(fromOsascriptOutput: "\"NOTFOUND\""), nil,
                    "浏览器探针解析: 脚本自己判定找不到播放进度元素")
        expectEqual(P.parseSeconds(fromOsascriptOutput: "\"\""), nil, "浏览器探针解析: 空字符串")
        expectEqual(P.parseSeconds(fromOsascriptOutput: ""), nil, "浏览器探针解析: 真空输入")
        // ⚠️ 2026-08-30 实测坐实的真实回归:早期版本让 JS 直接 return JSON.stringify(...),
        // 而 `execute … javascript` 会把返回字符串里已有的双引号**真的**转义成反斜杠字符
        // (不是打印时的显示转义),等于整段 JSON 被二次转义——旧的"脱一层引号再反转义"解析
        // 逻辑在这种输入下会静默解析出错误结果,而不是干脆地失败。这里固定住新格式(裸文本
        // 竖线分隔、不含任何引号)绝不会撞上这个坑,并且钉住一条"就算某处不小心传回带引号的
        // JSON 残留,也不能被误判成合法数据"的回归用例。
        expectEqual(P.parseSeconds(fromOsascriptOutput: "\"{\\\"found\\\":true,\\\"seconds\\\":168}\""),
                    nil, "浏览器探针解析: 万一混进 JSON 残留也不能误判成合法数据(2026-08-30 回归)")
    }

    // ---- BrowserPositionProbe:平台↔浏览器配对门禁(2026-08-31) ----
    // 只测"没配对就不探测"这道门禁本身——它在 kickIfNeeded 内部、发起任何 AppleScript
    // 调用之前就短路返回,不依赖真实 Arc,能在 CI/无 GUI 环境里稳定跑。真正的探测行为
    // (配对过之后)依赖真实浏览器,已手动验证过(见该文件头注)。
    do {
        expectEqual(BrowserPositionProbe.supportedPlatforms.contains { $0.id == "youtubeMusic" }, true,
                    "浏览器歌词同步: YouTube Music 在受支持平台列表里")
        expectEqual(BrowserPositionProbe.supportedPlatforms.contains { $0.id == "spotifyWeb" }, true,
                    "浏览器歌词同步: Spotify 网页版在受支持平台列表里")
        // ⚠️ **滚轮兜底转发的判定必须能被同一次手势复用**(2026-09-02,真机 sample 抓栈坐实)。
        // 那个判定里有一次全窗口递归命中测试,装在全局滚轮监视器里 = 每秒几十上百次压主线程;
        // 抓到的栈里它占了主线程 74/1439 个采样。下面四条钉住复用条件,少一条都会退回逐事件重算。
        do {
            let t0 = Date()
            let p = CGPoint(x: 100, y: 200)
            typealias A = ScrollForwardDecision
            expectEqual(A.canReuse(cachedWindow: 7, cachedPoint: p, cachedAt: t0,
                                                 window: 7, point: p, now: t0.addingTimeInterval(0.05)),
                        true, "滚轮判定复用: 同窗口+同点+新鲜 → 复用")
            expectEqual(A.canReuse(cachedWindow: 7, cachedPoint: p, cachedAt: t0,
                                                 window: 8, point: p, now: t0.addingTimeInterval(0.05)),
                        false, "滚轮判定复用: 换了窗口 → 必须重算")
            expectEqual(A.canReuse(cachedWindow: 7, cachedPoint: p, cachedAt: t0,
                                                 window: 7, point: CGPoint(x: 140, y: 200),
                                                 now: t0.addingTimeInterval(0.05)),
                        false, "滚轮判定复用: 指针挪出容差 → 必须重算")
            expectEqual(A.canReuse(cachedWindow: 7, cachedPoint: p, cachedAt: t0,
                                                 window: 7, point: p, now: t0.addingTimeInterval(5)),
                        false, "滚轮判定复用: 过期 → 必须重算")
        }
        // ⚠️ **读到"错的标签页"要被挡住,但判据不能拿 MediaRemote 的位置当参照物。**
        //
        // 这里原来是一张五行表,测的是当天加的 `isPlausibleCorrection(probed:reference:)`。
        // 那道守卫当天就被真机抓出来删了(原委见 `BrowserPositionProbe.pageClockIsRunning`
        // 头注):它拿 `snapshot.elapsedTime` 当参照,而网页播放器的这个字段**恒为 0**,守卫
        // 直接退化成"只有页面放在前 8 秒内的修正才采纳";消费又是每首歌一次性的,于是整首歌
        // 都跑在错锚点上,用户报「歌词进度不准」。
        //
        // ⚠️ **这张表当初不但没抓到那次退化,还把它固化成了断言** —— 三行放行用例写的是
        // `(0.23, 0.0, true)` / `(1.60, 0.0, true)` / `(8.0, 0.0, true)`,reference 一律填 0,
        // 等于把"锚点误差 0.23s"顺手写成了"reference=0, probed=0.23"。真实场景里 reference
        // 恒为 0 而 probed 是歌曲当前位置(几十上百秒),这三行断言的其实是 `probed <= 8`。
        // **教训:把参照物写死成一个常数的用例,证明不了任何跟参照物有关的判据** —— 它只是把
        // 你写用例时的那个假设复述了一遍(跟"用同一假设写的单测自证阈值"是同一个坑)。
        for (first, second, want, why) in [
            (7.0, 8.0, true, "正常播放:整秒读数 +1 就是钟在走"),
            (7.0, 9.0, true, "间隔跨了两个整秒边界(+2)同样算在走"),
            (120.0, 121.0, true, "判据跟位置绝对值无关 —— 这正是旧守卫栽的地方,必须钉住"),
            (7.0, 7.0, false, "陈旧镜像标签页:实测 15 次采样一直读 7 秒,必须挡掉"),
            (35.0, 7.0, false, "读数往回跳(拖进度条/读到别的标签页)不采信,下一轮重试"),
        ] as [(Double, Double, Bool, String)] {
            expectEqual(BrowserPositionProbe.pageClockIsRunning(first: first, second: second), want,
                        "探针活性: \(why)")
        }
        // ⚠️ 采样间隔必须**大于**读数本身的量化步长(整秒),否则"没前进"分不出是钟停了
        // 还是还没跨过整秒边界 —— 这条一破,活性判据就退化成随机噪声。
        expectEqual(BrowserPositionProbe.livenessGapSeconds > 1.0, true,
                    "探针活性: 采样间隔必须大于整秒读数的量化步长")
        // 有界重试:瞬时失败(页面缓冲/后台标签页节流)要有第二次机会,但不能整首歌每轮都
        // 去 tell 一遍浏览器。
        expectEqual(BrowserPositionProbe.maxProbeAttempts >= 2, true,
                    "探针重试: 至少要给瞬时失败一次重试机会")
        expectEqual(BrowserPositionProbe.probeRetryBackoffSecs > BrowserPositionProbe.livenessGapSeconds, true,
                    "探针重试: 退避必须比一次探测本身(两次采样+间隔)更长")
        // ⚠️ 广告是这套判据**认不出来**的那一类,靠时长对不上兜:YouTube Music 插广告时页面那
        // 行进度文字是**广告自己的**,而且**是在走的** —— `pageClockIsRunning` 对它一路放行。
        // 容差必须留得住"页面显示 floor(总时长)、MediaRemote 给小数"这点固有差(实测
        // duration=218.781 对页面 3:38=218),又不能大到把一首歌和一段广告混为一谈。
        expectEqual(BrowserPositionProbe.pageDurationToleranceSecs >= 1
                    && BrowserPositionProbe.pageDurationToleranceSecs <= 5, true,
                    "探针同曲判据: 时长容差要够吃下 floor 偏置又不至于放过广告")
        // ⚠️ **一次性地面真值不能走周期性噪声源那套 EMA 闸门**(2026-09-02 真机日志坐实的 bug)。
        // 探针每首歌只给一个样本,而 servoDecision 对 noisyFloored 是 alpha 0.3 / 门槛 1.0 ——
        // 单样本最多把 EMA 推到 0.3×误差,要误差 >3.33s 才可能触发。实测这档偏差是 0.7~0.9s,
        // 于是纠偏连着三首歌全部 snap=false。这两条断言把"为什么必须另开一条路径"钉住。
        expectEqual(LocalPlaybackSource.servoDecision(errEMA: 0, error: -0.7, tier: .noisyFloored).snap,
                    false, "伺服: 单个 -0.7s 样本进不了 noisyFloored 的 EMA 门槛")
        expectEqual(0.7 > LocalPlaybackSource.groundTruthSnapToleranceSecs, true,
                    "探针重锚: 0.30s 门槛必须接得住实测那档 0.7s 偏差")
        expectEqual(BrowserPositionProbe.flooredMidpointBiasSecs, 0.5,
                    "探针读数: 页面是 floor,取区间中点才无偏(实测 elapsed=165.627 → 页面 165)")
        // ⚠️ **Safari 的媒体代理进程要被解析成宿主**,否则探针对 Safari 一次都不会出手
        // (MediaRemote 报 com.apple.WebKit.GPU,而配对表和 AppleScript 认的是 com.apple.Safari)。
        expectEqual(BrowserPositionProbe.probeTargetBundleID(forReported: "com.apple.WebKit.GPU"),
                    "com.apple.Safari", "浏览器歌词同步: WebKit.GPU 解析成 Safari 宿主")
        expectEqual(BrowserPositionProbe.probeTargetBundleID(forReported: "company.thebrowser.Browser"),
                    "company.thebrowser.Browser", "浏览器歌词同步: 非代理进程原样返回")
        expectEqual(BrowserPositionProbe.probeTargetBundleID(forReported: nil), nil,
                    "浏览器歌词同步: nil 原样返回")
        // ⚠️ **每个摆出来的平台都必须真有一条站点规则**,反之亦然。对不上不会编译报错,只表现成
        // "卡片在、配对得上、却永远不探测"。
        expectEqual(BrowserPositionProbe.platformIDsWithSiteRules,
                    Set(BrowserPositionProbe.supportedPlatforms.map(\.id)),
                    "浏览器歌词同步: 受支持平台与站点规则一一对应")
        // ⚠️ 平台 id 必须唯一:`platformBrowserPairs` 用它当键,撞了就是两个平台共用一份配对。
        expectEqual(Set(BrowserPositionProbe.supportedPlatforms.map(\.id)).count,
                    BrowserPositionProbe.supportedPlatforms.count,
                    "浏览器歌词同步: 平台 id 不重复")
        let probe = BrowserPositionProbe.shared
        probe.trackChanged()
        probe.platformBrowserPairs = [:] // 确保没有任何配对
        let key = "selftest-pairing-gate-key"
        probe.kickIfNeeded(bundleIdentifier: "company.thebrowser.Browser", key: key, expectedDuration: 240)
        // 没配对过任何平台,kickIfNeeded 应该在发起探测之前就直接返回——短暂等待后确认
        // 没有任何结果被缓存(如果门禁失效、真的发起了探测,这里会因为异步任务还没跑完
        // 而是 nil,也会因为跑完了拿到真实值而非 nil,两种情况这条断言都盖不住;门禁生效
        // 时唯一保证的是"从头到尾都不会有值"——所以额外拉长等待,给"万一门禁失效"的探测
        // 留够时间跑完,这样"仍是 nil"才是门禁生效的可靠证据)。
        // ⚠️ 2026-09-02 探测改成"两次采样 + 中间等 `livenessGapSeconds`"之后这 2 秒仍然够:
        // 这个用例把配对表清空了,门禁**万一**失效,`probeOnce` 也会因为没有任何规则匹配得上
        // 而立刻返回 nil、根本走不到那次等待。盖不住的只有"门禁失效**且**真有配对"的组合,
        // 而那不是这条用例要证明的东西。
        Thread.sleep(forTimeInterval: 2.0)
        expectEqual(probe.consumeCorrection(forKey: key, rate: 1, now: Date()), nil,
                    "浏览器歌词同步: 没配对任何平台时 kickIfNeeded 不应该发起探测")
        probe.trackChanged()
        probe.platformBrowserPairs = [:]
        // ⚠️ Spotify 网页版广告识别(2026-09-02,用户实测截图坐实):LocalPlaybackSource
        // 判断"这是不是 Spotify"时,除了原生客户端的 bundleIdentifier,还要认"这个浏览器
        // 有没有被用户配对给 spotifyWeb 平台"——`isPaired` 就是那道判断,复用同一份
        // `platformBrowserPairs`,不是另起一份状态。
        probe.platformBrowserPairs = ["spotifyWeb": ["com.apple.Safari"]]
        expectEqual(probe.isPaired(bundleID: "com.apple.Safari", platformID: "spotifyWeb"), true,
                    "浏览器歌词同步: 配对过 spotifyWeb 的浏览器应判定为已配对")
        expectEqual(probe.isPaired(bundleID: "com.apple.Safari", platformID: "youtubeMusic"), false,
                    "浏览器歌词同步: 配对给别的平台不算配对给 spotifyWeb")
        expectEqual(probe.isPaired(bundleID: "com.microsoft.edgemac", platformID: "spotifyWeb"), false,
                    "浏览器歌词同步: 没配对过的浏览器不算配对")
        expectEqual(probe.isPaired(bundleID: nil, platformID: "spotifyWeb"), false,
                    "浏览器歌词同步: nil bundle id 不算配对")
        probe.platformBrowserPairs = [:]
    }

    // ---- 来源角标:浏览器在放哪个网页音乐平台(2026-09-03) ----
    //
    // 用户原话:"这里显示 youtubemusic,如果确实是 youtube music 的情况下,不再显示浏览器;
    // 如果是浏览器里面播放 spotify 就显示 spotify;其他的不是这两个的话就正常显示浏览器图标"。
    // 判据是**证据优先、配对推断兜底**两档,收在这个纯函数里(消费点
    // `PlaybackCoordinator.resolvedPlayerIcon` / `resolvedPlayerDisplayName`)。
    do {
        typealias P = BrowserPositionProbe
        let both: Set<String> = ["youtubeMusic", "spotifyWeb"]

        // ① 探测真命中过 → 就是它。这是硬证据:探测成功意味着我们刚从那个站点自己的 DOM
        //    里读到了一个**在走**的进度。一个浏览器同时配对了两个平台时(这台机器上
        //    Safari / Arc 就是),只有这一档答得上来。
        expectEqual(P.resolvePlayingPlatformID(pairedPlatformIDs: both, recentMatch: "youtubeMusic"),
                    "youtubeMusic",
                    "来源角标: 探测命中 YouTube Music → 认它(两个平台都配对时唯一的依据)")
        expectEqual(P.resolvePlayingPlatformID(pairedPlatformIDs: both, recentMatch: "spotifyWeb"),
                    "spotifyWeb", "来源角标: 探测命中 Spotify 网页版 → 认它")

        // ② 只配对了一个平台 → 推断成它,**不用等探测成功**。这一档覆盖绝大多数人的实际
        //    配置(一个浏览器只配一个平台),也是这台机器上 Edge/Chrome 的形状 —— 用户截图
        //    里那枚 Edge 角标就是靠这一档立刻变成 YouTube Music 的。
        expectEqual(P.resolvePlayingPlatformID(pairedPlatformIDs: ["youtubeMusic"], recentMatch: nil),
                    "youtubeMusic", "来源角标: 只配了一个平台 → 直接推断成它,不必等探测")

        // ③ 配了两个、又还没探到 → **不猜**,退回浏览器图标。对一半错一半的猜测,不如
        //    如实显示浏览器。
        expectEqual(P.resolvePlayingPlatformID(pairedPlatformIDs: both, recentMatch: nil), nil,
                    "来源角标: 配了两个又没探到 → 不猜,退回浏览器图标")

        // ④ 一个都没配对 → 压根不是网页播放器那条路,照常显示浏览器。
        expectEqual(P.resolvePlayingPlatformID(pairedPlatformIDs: [], recentMatch: nil), nil,
                    "来源角标: 没配对过任何平台 → 显示浏览器图标")

        // ⑤ ⚠️ 旧证据必须**仍在配对表里**才作数:用户后来取消配对了,探测就不跑了、那条旧
        //    证据再也刷新不掉 —— 认它的话角标会永远挂着一个已经被取消的平台。
        expectEqual(P.resolvePlayingPlatformID(pairedPlatformIDs: ["spotifyWeb"],
                                               recentMatch: "youtubeMusic"),
                    "spotifyWeb", "来源角标: 命中的平台已被取消配对 → 证据作废,退回单配对推断")
        expectEqual(P.resolvePlayingPlatformID(pairedPlatformIDs: [], recentMatch: "youtubeMusic"),
                    nil, "来源角标: 全部取消配对后旧证据也不作数")

        // ⑥ 契约:第 ② 档能推断出来的平台一定得画得出图标。图标那一侧(`WebPlatformIcon`)
        //    在 app target、这里够不着,只钉 id 集合这一半 —— 新增平台时这条会红,提醒去补
        //    站点规则和图标(两处对不上不会编译报错,只表现成"角标位空着")。
        expectEqual(Set(P.supportedPlatforms.map(\.id)), both,
                    "来源角标: 支持的平台就是这两个(新增时这条红,提醒补站点规则与图标)")
    }
}
