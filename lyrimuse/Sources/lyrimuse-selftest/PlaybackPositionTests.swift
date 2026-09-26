import LyrimuseCore
import Foundation

// 播放位置:外推伺服 / 锚点 / seek / 浏览器探针。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runPlaybackPositionTests() {
    // ---- MediaControlClient.livePositionSeconds: rate 缺失时别信 elapsedTimeNow ----
    // (Spotify 暂停后恢复播放,上报的 playbackRate 变成 null,而
    // media-control 的 --now 外推是 elapsed + (now-ts)*rate —— rate 缺失时增量为 0,
    // elapsedTimeNow 15 秒纹丝不动。那个恒定值喂进伺服会把位置一路拽回去、歌词冻在一行。)

    // ---- 汽水非会员试听:换回原曲口径(collector 发布、App 换算) ----
    // 真机:《一分之二》整首 282.801s,试听段 240.000 起、长 30.001;播放器报 duration 30、位置 6。
    do {
        let state = PlayerPreviewFix.State(bundle: "com.soda.music", title: "一分之二", artist: "HUSH, 孙盛希",
                                           previewStart: 240, previewDuration: 30.001, fullDuration: 282.801)
        func snap(_ duration: Double, title: String = "一分之二", bundle: String = "com.soda.music") -> MediaControlSnapshot {
            let json: [String: Any] = ["title": title, "artist": "HUSH, 孙盛希", "album": "出没地带", "duration": duration,
                                       "elapsedTime": 6, "playing": true, "playbackRate": 1, "isMusicApp": true,
                                       "bundleIdentifier": bundle, "anchorElapsedTime": 0]
            let data = try! JSONSerialization.data(withJSONObject: json)
            return try! JSONDecoder().decode(MediaControlSnapshot.self, from: data)
        }
        let fixed = PlayerPreviewFix.applied(to: snap(30), state: state)
        expectEqual(fixed?.duration, 282.801, "试听换算: 时长换成整首")
        expectEqual(fixed?.elapsedTime, 246, "试听换算: 位置加上试听段起点(6 → 246)")
        expectEqual(fixed?.anchorElapsedTime, 240, "试听换算: 原始锚点同样加上起点,锚点身份前后一致")
        expectEqual(PlayerPreviewFix.applied(to: snap(282.801), state: state)?.elapsedTime, 6,
                    "试听换算: 报的已经是整首(会员 / 限免)→ 不动")
        expectEqual(PlayerPreviewFix.applied(to: snap(30, title: "别的歌"), state: state)?.elapsedTime, 6,
                    "试听换算: 换歌了 → 不动")
        expectEqual(PlayerPreviewFix.applied(to: snap(30, bundle: "com.netease.163music"), state: state)?.elapsedTime, 6,
                    "试听换算: 别的播放器 → 不动")
        expectEqual(PlayerPreviewFix.stateURL.lastPathComponent, "lyrimuse-player-preview.json",
                    "试听换算: 文件名与 collector 的 clientName+\"-player-preview.json\" 一致")
    }

    // ---- 暂停中发布的锚点(网易云换歌):从真正起播那一刻算 ----
    // 真机时间线(音频截取当真值):新曲 `elapsed=0` 在出声前 1.113s、暂停态下发布,最后一次翻成
    // playing 在出声前 0.068s。此刻 = 出声后 0.26s,真实位置 0.26。
    do {
        let t0 = Date(timeIntervalSince1970: 2_000_000)                 // 锚点整秒时间戳
        let sighting = MediaControlClient.AnchorSighting(at: t0.addingTimeInterval(0.3), tight: true)
        let audioStart = t0.addingTimeInterval(0.3 + 1.113)
        let playFlip = audioStart.addingTimeInterval(-0.068 - MediaControlClient.streamAnchorLatency)
        let now = audioStart.addingTimeInterval(0.26)
        func pos(_ start: Date?) -> Double? {
            MediaControlClient.livePositionSeconds(
                playing: true, elapsedTime: 0, elapsedTimeNow: nil, playbackRate: 1,
                timestamp: t0, now: now, sighting: sighting, playbackStartedAt: start)
        }
        let r3: (Double?) -> Double? = { $0.map { ($0 * 1000).rounded() / 1000 } }
        expectEqual(r3(pos(playFlip)), 0.353, "暂停锚点: 从起播那一刻算,0.353(真值 0.26)")
        expectEqual(r3(pos(nil)), 1.398, "暂停锚点: 不接的话从发布那一刻算,1.398 —— 整首快 1.1s")
        expectEqual(r3(pos(t0)), 1.398, "暂停锚点: 起播时刻早于锚点时刻时不采用")
        expectEqual(MediaControlClient.pausedAnchorStartApplies(publishedAt: t0, startedAt: t0.addingTimeInterval(1.2)), true,
                    "暂停锚点: 发布后 1.2s 的 playing:true 算它的起播")
        expectEqual(MediaControlClient.pausedAnchorStartApplies(publishedAt: t0, startedAt: t0.addingTimeInterval(30)), false,
                    "暂停锚点: 30s 后的恢复是用户自己按的播放,不算")
        expectEqual(MediaControlClient.startsPausedAnchorOnPlay(bundleID: PlaybackPlayer.netease.bundleIdentifier), true,
                    "暂停锚点: 网易云开")
        expectEqual(MediaControlClient.startsPausedAnchorOnPlay(bundleID: PlaybackPlayer.qqMusic.bundleIdentifier), false,
                    "暂停锚点: 没实测过的播放器不开(QQ 音乐)")
    }

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

        // ---- 整秒时间戳的相位订正 ----
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

        // ---- stream 事件到达时刻钉锚点 ----
        //
        // 实测(Spotify 暂停后恢复播放,3 次):恢复那一刻 Spotify 重打锚点且 playbackRate 变 null,
        // media-control 的 elapsedTimeNow 从此不再外推(2 分 14 秒纹丝不动),App 只能自己按
        // elapsedTime + (now − 整秒 ts) 补算 —— 整秒抹掉的小数(实测 .914/.724/.560)就是那首歌
        // 余下部分偏快的量,一按暂停(冻结值是准的)显示就退回去 0.95/0.73s;这个错位再被自然切歌
        // 校正当成旧曲真值,下一首偏置低估同样的量(实测真实 1.114 估成 0.533)。
        // stream 事件在锚点打好后 17~26ms 就到,用到达时刻反推锚点,误差从 [0,1) 缩到 ±20ms。
        do {
            let ts = Date(timeIntervalSince1970: 1_000_000)
            let tsString = "1970-01-12T13:46:40Z"
            func ms(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
            expectEqual(MC.parseTimestamp(tsString), ts, "钉锚点: 测试用的整秒字符串对得上 ts")

            // tight:到达 ts+0.585(实测 00:40:25.580 对整秒 :25)→ 锚点 ≈ ts+0.560
            let tight = MC.AnchorSighting(at: ts.addingTimeInterval(0.585), tight: true)
            expectEqual(ms(MC.estimatedAnchorInstant(timestamp: ts, sighting: tight).timeIntervalSince(ts)), 0.56,
                        "钉锚点: tight 目击 = 到达时刻回退典型延迟")
            // 夹逼下界:到达只比整秒晚 10ms(锚点打在整秒边界上)→ 不倒推到上一秒
            let early = MC.AnchorSighting(at: ts.addingTimeInterval(0.010), tight: true)
            expectEqual(MC.estimatedAnchorInstant(timestamp: ts, sighting: early), ts, "钉锚点: tight 目击不早于整秒时间戳")
            // 夹逼上界:到达 ts+1.3(事件迟到)→ 夹在 ts+0.999,不越过下一秒
            let late = MC.AnchorSighting(at: ts.addingTimeInterval(1.3), tight: true)
            expectEqual(ms(MC.estimatedAnchorInstant(timestamp: ts, sighting: late).timeIntervalSince(ts)), 0.999,
                        "钉锚点: tight 目击不越过 ts+1")
            // loose 目击退回中点法,与 firstSeenAt 版逐字相同
            let loose = MC.AnchorSighting(at: ts.addingTimeInterval(0.4), tight: false)
            expectEqual(MC.estimatedAnchorInstant(timestamp: ts, sighting: loose),
                        MC.estimatedAnchorInstant(timestamp: ts, firstSeenAt: ts.addingTimeInterval(0.4)),
                        "钉锚点: loose 目击退回中点法")

            // rate 缺失分支现在也套相位订正。实测样本:恢复锚点 elapsed=172.994、ts=:25(真实 :25.560),
            // 42.647s 后 App 那拍 —— 改动前算 215.641(快 0.56),Spotify 自己的钟是 215.081。
            let resumed = MC.livePositionSeconds(
                playing: true, elapsedTime: 172.994, elapsedTimeNow: 172.994,
                playbackRate: nil, timestamp: ts, now: ts.addingTimeInterval(42.647),
                lastPlayingPosition: nil, sighting: tight)
            expectEqual(resumed.map(ms), 215.081, "钉锚点: rate 缺失 + tight 目击对上 Spotify 自己的钟(实测样本)")
            // 没有目击(watcher 挂了 / 既有调用方)→ 行为跟改动前逐字相同(仍偏快 frac,但不更差)
            let noSighting = MC.livePositionSeconds(
                playing: true, elapsedTime: 172.994, elapsedTimeNow: 172.994,
                playbackRate: nil, timestamp: ts, now: ts.addingTimeInterval(42.647))
            expectEqual(noSighting.map(ms), 215.641, "钉锚点: rate 缺失、无目击时行为跟改动前相同")
            // loose 目击(只有轮询看到,首见 ts+0.4)→ 中点 ts+0.2
            let looseResumed = MC.livePositionSeconds(
                playing: true, elapsedTime: 172.994, elapsedTimeNow: 172.994,
                playbackRate: nil, timestamp: ts, now: ts.addingTimeInterval(42.647),
                lastPlayingPosition: nil, sighting: loose)
            expectEqual(looseResumed.map(ms), 215.441, "钉锚点: rate 缺失 + loose 目击退回中点法")
            // rate 正常、锚点陈旧:tight 目击同样接管(替代原来的中点)
            let staleTight = MC.livePositionSeconds(
                playing: true, elapsedTime: 100, elapsedTimeNow: 130.0,
                playbackRate: 1, timestamp: ts, now: ts.addingTimeInterval(30),
                lastPlayingPosition: nil, sighting: tight)
            expectEqual(staleTight.map(ms), 129.44, "钉锚点: rate 正常 + 陈旧锚点按 tight 锚点时刻外推")
            // 旧入参 firstSeenAt 与 sighting 同传时 sighting 优先
            let both = MC.livePositionSeconds(
                playing: true, elapsedTime: 100, elapsedTimeNow: 130.0,
                playbackRate: 1, timestamp: ts, now: ts.addingTimeInterval(30),
                lastPlayingPosition: nil, firstSeenAt: ts.addingTimeInterval(0.4), sighting: tight)
            expectEqual(both.map(ms), 129.44, "钉锚点: sighting 与 firstSeenAt 同传时 sighting 优先")

            // anchorKey:轮询与 stream watcher 共用一个构造,elapsedTime 定格三位小数
            expectEqual(MC.anchorKey(artist: "方大同", title: "南音", elapsedTime: 172.994, timestamp: "2026-09-06T16:40:25Z"),
                        "方大同|南音|172.994|2026-09-06T16:40:25Z", "anchorKey: 三段拼接")
            expectEqual(MC.anchorKey(artist: nil, title: "x", elapsedTime: 0, timestamp: nil), "|x|0.000|-", "anchorKey: 缺项占位")

            // stream watcher 的行消化:full 整份替换、diff 合并;只有带 elapsedTime/timestamp 的
            // 事件才算锚点目击;刚(重)启时整份吐出的旧锚点(时间戳已经很老)只算 loose。
            let arrival = ts.addingTimeInterval(0.585)
            let full = Data(("{\"type\":\"data\",\"diff\":false,\"payload\":{\"bundleIdentifier\":\"com.spotify.client\","
                + "\"title\":\"南音\",\"artist\":\"方大同\",\"playing\":true,\"elapsedTime\":26.458,"
                + "\"timestamp\":\"\(tsString)\",\"duration\":215.853}}").utf8)
            let d1 = MediaControlStreamWatcher.digest(line: full, merged: [:], arrivedAt: arrival)
            expectEqual(d1.anchorKey, "方大同|南音|26.458|\(tsString)", "digest: full payload 直接给出锚点身份")
            expectEqual(d1.tight, true, "digest: 刚打好的锚点(到达时 0.585s 老)算 tight")
            expectEqual(d1.anchorAge.map(ms), 0.585, "digest: 报出到达时的锚点年龄")
            // diff 只带 elapsedTime/timestamp/playbackRate(恢复播放的实测形态):曲目沿用合并状态
            let diff = Data("{\"type\":\"data\",\"diff\":true,\"payload\":{\"elapsedTime\":162.05,\"timestamp\":\"\(tsString)\",\"playbackRate\":null}}".utf8)
            let d2 = MediaControlStreamWatcher.digest(line: diff, merged: d1.merged, arrivedAt: arrival)
            expectEqual(d2.anchorKey, "方大同|南音|162.050|\(tsString)", "digest: diff 沿用合并状态里的曲目")
            expectEqual(d2.merged["title"] as? String, "南音", "digest: diff 不丢合并状态里未变的键")
            // 不带锚点字段的 diff(只是 playing 翻转)不算目击
            let playingOnly = Data("{\"type\":\"data\",\"diff\":true,\"payload\":{\"playing\":false}}".utf8)
            expectEqual(MediaControlStreamWatcher.digest(line: playingOnly, merged: d1.merged, arrivedAt: arrival).anchorKey, nil,
                        "digest: 只翻 playing 不算锚点目击")
            // watcher 重启时整份吐出的旧锚点:到达时时间戳已经 30s 老 → loose
            let stale = MediaControlStreamWatcher.digest(line: full, merged: [:], arrivedAt: ts.addingTimeInterval(30))
            expectEqual(stale.anchorKey != nil && stale.tight == false, true, "digest: 重启时看到的旧锚点只算 loose")
            // 空 payload(没人在报)/ 非 JSON 行:不崩、不产生目击;空 payload 还要清掉合并状态
            let empty = MediaControlStreamWatcher.digest(
                line: Data("{\"type\":\"data\",\"diff\":false,\"payload\":{}}".utf8), merged: d1.merged, arrivedAt: arrival)
            expectEqual(empty.anchorKey == nil && empty.merged.isEmpty, true, "digest: 空 payload 无目击且清空合并状态")
            expectEqual(MediaControlStreamWatcher.digest(line: Data("garbage".utf8), merged: d1.merged, arrivedAt: arrival).anchorKey, nil,
                        "digest: 非 JSON 行无目击")
        }

        // ---- media-control --micros:精确锚点时间戳 ----
        //
        // 样本取自同一时刻的两次实测输出:整秒 timestamp 与 timestampEpochMicros = 1790180829813474
        // 只差被截掉的 .813474。带 --micros 时四个时间键被替换成微秒版,解析入口换算回原键名;精确的
        // 锚点时刻不再经过 estimatedAnchorInstant 的估算。
        do {
            func ms(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
            let preciseString = "@1790180829813474"
            let precise = Date(timeIntervalSince1970: 1_790_180_829.813474)
            let floored = Date(timeIntervalSince1970: 1_790_180_829)

            // 时间戳格式与精度判定
            expectEqual(MediaControlMicros.timestampString(1_790_180_829_813_474), preciseString, "micros: 时间戳写成 @<epoch 微秒>")
            expectEqual(MC.parseTimestamp(preciseString).map { ms($0.timeIntervalSince1970) }, 1_790_180_829.813,
                        "micros: parseTimestamp 认 @ 格式")
            expectEqual(MC.parseTimestamp("2026-09-23T16:27:09Z"), floored, "micros: 旧的整秒格式照常解析")
            expectEqual(MediaControlMicros.isPrecise(precise), true, "micros: 带小数秒的锚点是精确值")
            expectEqual(MediaControlMicros.isPrecise(floored), false, "micros: 整秒锚点不是精确值")

            // JSONDecoder 路径(轮询快照):微秒键换算回原键名,原键名照常可用
            let microsJSON = Data(#"{"durationMicros":247152993,"elapsedTimeMicros":143288238,"elapsedTimeNowMicros":150000000,"timestampEpochMicros":1790180829813474}"#.utf8)
            let decoded = try? JSONDecoder().decode(MediaControlMicros.TimeFields.self, from: microsJSON)
            expectEqual(decoded?.duration, 247.152993, "micros: durationMicros 换算回 duration")
            expectEqual(decoded?.elapsedTime, 143.288238, "micros: elapsedTimeMicros 换算回 elapsedTime")
            expectEqual(decoded?.elapsedTimeNow, 150, "micros: elapsedTimeNowMicros 换算回 elapsedTimeNow")
            expectEqual(decoded?.timestamp, preciseString, "micros: timestampEpochMicros 换算回 timestamp")
            let plainJSON = Data(#"{"duration":247.152993,"elapsedTime":143.288238,"timestamp":"2026-09-23T16:27:09Z"}"#.utf8)
            let plain = try? JSONDecoder().decode(MediaControlMicros.TimeFields.self, from: plainJSON)
            expectEqual(plain?.timestamp, "2026-09-23T16:27:09Z", "micros: 不带 --micros 的旧输出原样解码")
            expectEqual(plain?.elapsedTime, 143.288238, "micros: 旧输出的 elapsedTime 原样")

            // JSONSerialization 路径(stream):同一套换算,NSNull 原样换到原键,原键已存在时不覆盖
            let norm = MediaControlMicros.normalized(["elapsedTimeMicros": NSNumber(value: 143_288_238),
                                                      "timestampEpochMicros": NSNumber(value: 1_790_180_829_813_474 as Int64),
                                                      "durationMicros": NSNull(), "title": "x"])
            expectEqual(norm["elapsedTime"] as? Double, 143.288238, "micros: stream 载荷 elapsedTime 换算")
            expectEqual(norm["timestamp"] as? String, preciseString, "micros: stream 载荷 timestamp 换算")
            expectEqual(norm["duration"] is NSNull, true, "micros: stream diff 里被清掉的键保留 NSNull")
            expectEqual(norm["elapsedTimeMicros"] == nil && norm["title"] as? String == "x", true, "micros: 微秒键移除、其它键不动")
            let keepPlain = MediaControlMicros.normalized(["elapsedTime": 1.5, "elapsedTimeMicros": NSNumber(value: 9_000_000)])
            expectEqual(keepPlain["elapsedTime"] as? Double, 1.5, "micros: 原键已存在时不覆盖")

            // 精确锚点不再估算:tight / loose / firstSeenAt 三种入参都原样返回
            let tight = MC.AnchorSighting(at: precise.addingTimeInterval(0.030), tight: true)
            let loose = MC.AnchorSighting(at: precise.addingTimeInterval(1.7), tight: false)
            expectEqual(MC.estimatedAnchorInstant(timestamp: precise, sighting: tight), precise, "micros: tight 目击不再改精确锚点")
            expectEqual(MC.estimatedAnchorInstant(timestamp: precise, sighting: loose), precise, "micros: loose 目击不再改精确锚点")
            expectEqual(MC.estimatedAnchorInstant(timestamp: precise, firstSeenAt: precise.addingTimeInterval(1.7)), precise,
                        "micros: firstSeenAt 入参不再改精确锚点")
            // 整秒锚点照旧估算(旧路径逐字不变)
            expectEqual(MC.estimatedAnchorInstant(timestamp: floored, firstSeenAt: floored.addingTimeInterval(1.7)),
                        floored.addingTimeInterval(0.5), "micros: 整秒锚点仍走中点估算")

            // rate 缺失分支(Spotify 暂停后恢复的形态):精确锚点直接外推,没有 0~1s 的偏快
            let live = MC.livePositionSeconds(
                playing: true, elapsedTime: 143.288238, elapsedTimeNow: 143.288238,
                playbackRate: nil, timestamp: precise, now: precise.addingTimeInterval(10),
                lastPlayingPosition: nil, sighting: loose)
            expectEqual(live.map(ms), 153.288, "micros: rate 缺失时按精确锚点外推")

            // stream 行带 --micros:锚点身份用 @ 格式,与轮询路径同一把 key;年龄按精确时刻算
            let microsLine = Data(("{\"type\":\"data\",\"diff\":false,\"payload\":{\"bundleIdentifier\":\"com.spotify.client\","
                + "\"title\":\"南音\",\"artist\":\"方大同\",\"playing\":true,\"elapsedTimeMicros\":26458000,"
                + "\"timestampEpochMicros\":1790180829813474,\"durationMicros\":215853000}}").utf8)
            let dm = MediaControlStreamWatcher.digest(line: microsLine, merged: [:], arrivedAt: precise.addingTimeInterval(0.025))
            expectEqual(dm.anchorKey, "方大同|南音|26.458|\(preciseString)", "micros: stream 锚点身份用 @ 格式")
            expectEqual(dm.anchorKey, MC.anchorKey(artist: "方大同", title: "南音", elapsedTime: 26.458, timestamp: preciseString),
                        "micros: stream 与轮询路径拼出同一把 key")
            expectEqual(dm.anchorAge.map(ms), 0.025, "micros: 锚点年龄按精确时刻算")
            expectEqual(dm.tight, true, "micros: 刚打好的锚点仍算 tight")
        }

        // ---- Spotify 陈旧锚点重发 ----
        //
        // 实测(忘了美麗):01:40:09 恢复播放 elapsed=10.477 @ :09;01:40:43 Spotify 重发了一次
        // now-playing,elapsed 仍是 10.477、时间戳换成 :43。media-control 据此外推,位置退回 34 秒
        // (01:41:46 读到 73.75,真实 ≈107.6),用户看到"歌词落后很多、一暂停往前补一大段"。
        do {
            let ts = Date(timeIntervalSince1970: 1_000_000)
            func ms(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
            let last = MC.PlayingAnchor(track: "方大同|忘了美麗", elapsed: 10.477, timestamp: "T09", instant: ts.addingTimeInterval(0.555))
            let later = ts.addingTimeInterval(34.5)
            // 同曲、elapsed 逐 ms 相等、时间戳变了、旧锚点外推 44s 远没到 268s 曲长 → 陈旧重发
            expectEqual(MC.isStaleAnchorRepublish(last: last, track: "方大同|忘了美麗", elapsed: 10.477, timestamp: "T43", duration: 268.92, bundleID: PlaybackPlayer.spotify.bundleIdentifier, now: later),
                        true, "陈旧重发: 同 elapsed 换时间戳判为重发(实测样本)")
            // elapsed 变了(真实 seek / 恢复)→ 不是
            expectEqual(MC.isStaleAnchorRepublish(last: last, track: "方大同|忘了美麗", elapsed: 44.2, timestamp: "T43", duration: 268.92, bundleID: PlaybackPlayer.spotify.bundleIdentifier, now: later),
                        false, "陈旧重发: elapsed 变了就是真锚点")
            // 时间戳没变(同一个锚点被轮询多次看到)→ 不是
            expectEqual(MC.isStaleAnchorRepublish(last: last, track: "方大同|忘了美麗", elapsed: 10.477, timestamp: "T09", duration: 268.92, bundleID: PlaybackPlayer.spotify.bundleIdentifier, now: later),
                        false, "陈旧重发: 同一个锚点不算重发")
            // 换歌 → 不是
            expectEqual(MC.isStaleAnchorRepublish(last: last, track: "方大同|南音", elapsed: 10.477, timestamp: "T43", duration: 268.92, bundleID: PlaybackPlayer.spotify.bundleIdentifier, now: later),
                        false, "陈旧重发: 换歌不算")
            // elapsed == 0:跟「上一曲」重头播放签名相同,只按**时间**分(zeroAnchorRepublishWindowSecs)。
            // 实测两簇:开播双发挤在 2 秒内(汽水音乐 0.5~1.99s、连发累计 3.4s),真的回到 0 最近也在 175s 后。
            let atStart = MC.PlayingAnchor(track: "x|y", elapsed: 0, timestamp: "T00", instant: ts)
            expectEqual(MC.isStaleAnchorRepublish(last: atStart, track: "x|y", elapsed: 0, timestamp: "T44", duration: 268.92, bundleID: PlaybackPlayer.soda.bundleIdentifier, now: ts.addingTimeInterval(44)),
                        false, "陈旧重发: elapsed=0 隔得太久(44s)不算重发")
            expectEqual(MC.isStaleAnchorRepublish(last: atStart, track: "x|y", elapsed: 0, timestamp: "T02", duration: 268.92, bundleID: PlaybackPlayer.soda.bundleIdentifier, now: ts.addingTimeInterval(2)),
                        true, "陈旧重发: elapsed=0 开播 2 秒内重发算重发(时间戳解不出时按墙钟)")
            // 带真时间戳的实测样本(讨厌红楼梦:0.000@10:19:58 → 0.000@10:20:00,整首歌因此慢 1.93s)
            let zeroTS = "2026-09-18T10:19:58Z"
            let zeroInstant = MC.parseTimestamp(zeroTS) ?? ts
            let zeroAnchor = MC.PlayingAnchor(track: "陶喆|讨厌红楼梦", elapsed: 0, timestamp: zeroTS, instant: zeroInstant)
            expectEqual(MC.isStaleAnchorRepublish(last: zeroAnchor, track: "陶喆|讨厌红楼梦", elapsed: 0,
                                                  timestamp: "2026-09-18T10:20:00Z", duration: 268.92,
                                                  bundleID: PlaybackPlayer.soda.bundleIdentifier,
                                                  now: zeroInstant.addingTimeInterval(2.4)),
                        true, "陈旧重发: 开播双发的 0 锚点判为重发(实测样本)")
            // 连发三次时累计 3.4s,仍在窗口内(第二次重发也是跟**原**锚点比)
            expectEqual(MC.isStaleAnchorRepublish(last: zeroAnchor, track: "陶喆|讨厌红楼梦", elapsed: 0,
                                                  timestamp: "2026-09-18T10:20:02Z", duration: 268.92,
                                                  bundleID: PlaybackPlayer.soda.bundleIdentifier,
                                                  now: zeroInstant.addingTimeInterval(4)),
                        true, "陈旧重发: 连发三次时第二次仍在窗口内")
            // 曲末归零 / 隔很久重播:实测最近的一次在 175s 之后,必须当真锚点
            expectEqual(MC.isStaleAnchorRepublish(last: zeroAnchor, track: "陶喆|讨厌红楼梦", elapsed: 0,
                                                  timestamp: "2026-09-18T10:22:53Z", duration: 268.92,
                                                  bundleID: PlaybackPlayer.soda.bundleIdentifier,
                                                  now: zeroInstant.addingTimeInterval(175)),
                        false, "陈旧重发: 隔 175 秒的 0 锚点是真的回到 0")
            // 旧锚点外推已越过曲长(单曲循环回绕 / 曲末)→ 旧锚点已死,新的是真的
            expectEqual(MC.isStaleAnchorRepublish(last: last, track: "方大同|忘了美麗", elapsed: 10.477, timestamp: "T99", duration: 268.92, bundleID: PlaybackPlayer.spotify.bundleIdentifier, now: ts.addingTimeInterval(270)),
                        false, "陈旧重发: 旧锚点外推越过曲长就信新锚点")
            // 没有时长信息 → 只看签名
            expectEqual(MC.isStaleAnchorRepublish(last: last, track: "方大同|忘了美麗", elapsed: 10.477, timestamp: "T43", duration: nil, bundleID: PlaybackPlayer.spotify.bundleIdentifier, now: later),
                        true, "陈旧重发: 无时长时只看签名")
            expectEqual(MC.isStaleAnchorRepublish(last: nil, track: "方大同|忘了美麗", elapsed: 10.477, timestamp: "T43", duration: 268.92, bundleID: PlaybackPlayer.spotify.bundleIdentifier, now: later),
                        false, "陈旧重发: 没有上一个锚点不判")

            // Spotify 实测(Dancing With Our Hands Tied):0.000@:53 | 0.000@:54 | 0.000@:55,
            // 用它自己的 AppleScript 反推真起播点落在**第一个**锚点那一秒内 —— 跟汽水音乐同向。
            let spotZeroTS = "2026-09-20T02:32:53Z"
            let spotZeroInstant = MC.parseTimestamp(spotZeroTS) ?? ts
            let spotZeroAnchor = MC.PlayingAnchor(track: "Taylor Swift|Dancing With Our Hands Tied", elapsed: 0,
                                                  timestamp: spotZeroTS, instant: spotZeroInstant)
            expectEqual(MC.isStaleAnchorRepublish(last: spotZeroAnchor, track: "Taylor Swift|Dancing With Our Hands Tied",
                                                  elapsed: 0, timestamp: "2026-09-20T02:32:54Z", duration: 211,
                                                  bundleID: PlaybackPlayer.spotify.bundleIdentifier,
                                                  now: spotZeroInstant.addingTimeInterval(1)),
                        true, "陈旧重发: Spotify 的 0 锚点连发判为重发(实测样本)")

            // elapsed == 0 那条分支按播放器收窄:连发里**哪一个**是真起播点各家相反。Apple Music
            // 切歌时连发 2~3 个 0 锚点(实测 :20/:22/:24),真起播点是**最后**一个 —— 判成重发就
            // 整首歌快 4 秒,而且伺服看不见、只有暂停才纠得回来。名单外一律采信最新的那个。
            let amZeroTS = "2026-09-20T01:50:20Z"
            let amZeroInstant = MC.parseTimestamp(amZeroTS) ?? ts
            let amZeroAnchor = MC.PlayingAnchor(track: "陈绮贞|嫉妒", elapsed: 0, timestamp: amZeroTS, instant: amZeroInstant)
            expectEqual(MC.isStaleAnchorRepublish(last: amZeroAnchor, track: "陈绮贞|嫉妒", elapsed: 0,
                                                  timestamp: "2026-09-20T01:50:24Z", duration: 267.6,
                                                  bundleID: PlaybackPlayer.appleMusic.bundleIdentifier,
                                                  now: amZeroInstant.addingTimeInterval(4)),
                        false, "陈旧重发: Apple Music 的 0 锚点连发不判重发(实测样本)")
            expectEqual(MC.isStaleAnchorRepublish(last: atStart, track: "x|y", elapsed: 0, timestamp: "T02", duration: 268.92,
                                                  bundleID: PlaybackPlayer.kugou.bundleIdentifier, now: ts.addingTimeInterval(2)),
                        false, "陈旧重发: 名单外的播放器(酷狗)0 锚点不判重发")
            expectEqual(MC.isStaleAnchorRepublish(last: atStart, track: "x|y", elapsed: 0, timestamp: "T02", duration: 268.92,
                                                  bundleID: "com.example.player", now: ts.addingTimeInterval(2)),
                        false, "陈旧重发: 认不出的第三方播放器 0 锚点不判重发")
            expectEqual(MC.isStaleAnchorRepublish(last: atStart, track: "x|y", elapsed: 0, timestamp: "T02", duration: 268.92,
                                                  bundleID: nil, now: ts.addingTimeInterval(2)),
                        false, "陈旧重发: 拿不到 bundle id 时 0 锚点不判重发")

            // 命中后 livePositionSeconds 按原锚点时刻自己外推,不信 elapsedTimeNow(它按假时间戳算成 73.75)
            let kept = MC.livePositionSeconds(
                playing: true, elapsedTime: 10.477, elapsedTimeNow: 73.752,
                playbackRate: 1, timestamp: ts.addingTimeInterval(34), now: ts.addingTimeInterval(97.7),
                lastPlayingPosition: nil, sighting: MC.AnchorSighting(at: ts.addingTimeInterval(34.5), tight: true),
                republishedAnchorInstant: last.instant)
            expectEqual(kept.map(ms), ms(10.477 + 97.7 - 0.555), "陈旧重发: 命中后按原锚点外推(≈107.6 而不是 73.75)")
            // rate 缺失同样按 1 外推
            let keptNoRate = MC.livePositionSeconds(
                playing: true, elapsedTime: 10.477, elapsedTimeNow: 10.477,
                playbackRate: nil, timestamp: ts.addingTimeInterval(34), now: ts.addingTimeInterval(97.7),
                republishedAnchorInstant: last.instant)
            expectEqual(keptNoRate.map(ms), ms(10.477 + 97.7 - 0.555), "陈旧重发: rate 缺失时同样按原锚点外推")
            // 暂停态不受它影响:仍用冻结值
            let pausedKept = MC.livePositionSeconds(
                playing: false, elapsedTime: 44.0, elapsedTimeNow: 73.752,
                playbackRate: 1, timestamp: ts.addingTimeInterval(34), now: ts.addingTimeInterval(97.7),
                republishedAnchorInstant: last.instant)
            expectEqual(pausedKept, 44.0, "陈旧重发: 暂停态照旧用冻结值")
        }

        // ---- Spotify 一次性地面真值探针:外推与过期 ----
        do {
            let t = Date(timeIntervalSince1970: 1_000_000)
            func ms(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
            expectEqual(SpotifyPositionProbe.extrapolate(position: 3.2, capturedAt: t, now: t.addingTimeInterval(0.4), rate: 1).map(ms),
                        3.6, "spotify 探针: 按 age 外推到消费时刻")
            expectEqual(SpotifyPositionProbe.extrapolate(position: 3.2, capturedAt: t, now: t.addingTimeInterval(0.4), rate: 0).map(ms),
                        3.6, "spotify 探针: rate 缺失按 1")
            expectEqual(SpotifyPositionProbe.extrapolate(position: 3.2, capturedAt: t, now: t.addingTimeInterval(7), rate: 1),
                        nil, "spotify 探针: 过期不用")
            expectEqual(SpotifyPositionProbe.extrapolate(position: 3.2, capturedAt: t, now: t.addingTimeInterval(-1), rate: 1),
                        nil, "spotify 探针: 时钟倒退不用")
        }
        // ---- Spotify 探针两次采样:钟得在走才采信,读数从此折进整曲偏置,读错就是整首错 ----
        do {
            let gap = SpotifyPositionProbe.livenessGapSeconds
            expectEqual(SpotifyPositionProbe.clockIsRunning(first: 4.96, second: 4.96 + gap, wallGap: gap), true,
                        "spotify 探针活性: 前进量等于墙钟间隔 → 采信")
            expectEqual(SpotifyPositionProbe.clockIsRunning(first: 4.96, second: 4.96 + gap * 0.7, wallGap: gap), true,
                        "spotify 探针活性: 往返抖动让前进量偏少三成 → 仍采信")
            expectEqual(SpotifyPositionProbe.clockIsRunning(first: 0, second: 0, wallGap: gap), false,
                        "spotify 探针活性: 钟停着(缓冲中读到 0/0)→ 不采,否则整曲慢 3 秒")
            expectEqual(SpotifyPositionProbe.clockIsRunning(first: 4.96, second: 4.96 + gap * 0.3, wallGap: gap), false,
                        "spotify 探针活性: 只走了三成 → 不采")
            expectEqual(SpotifyPositionProbe.clockIsRunning(first: 4.96, second: 2.0, wallGap: gap), false,
                        "spotify 探针活性: 倒退(拖动)→ 不采")
            expectEqual(SpotifyPositionProbe.clockIsRunning(first: 4.96, second: 30.0, wallGap: gap), false,
                        "spotify 探针活性: 跳跃(换歌/拖动)→ 不采")
            expectEqual(SpotifyPositionProbe.clockIsRunning(first: 1, second: 2, wallGap: 0), false,
                        "spotify 探针活性: 墙钟间隔为 0 无法判定 → 不采")
        }
        // ---- Spotify 探针钟领先量的学习(现象是「有一点点偏快」;同日晚订正:残差是增量) ----
        // 真机:蓝牙 AirPods 先验 0.5 下第一次暂停量到残差 0.07 → 真值 0.57;内建输出 0.06~0.14。
        do {
            func r3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
            expectEqual(r3(LocalPlaybackSource.learnedProbeLead(current: 0.5, residual: 0.07, hasPrior: false)), 0.57,
                        "探针领先量: 没学过时 = 先验 + 残差(19:43 真机:0.5 + 0.07 = 0.57,不是 0.07)")
            expectEqual(r3(LocalPlaybackSource.learnedProbeLead(current: 0.57, residual: 0.0, hasPrior: true)), 0.57,
                        "探针领先量: 学准了之后残差≈0,值不动")
            expectEqual(r3(LocalPlaybackSource.learnedProbeLead(current: 0.57, residual: -0.46, hasPrior: true)), 0.34,
                        "探针领先量: 残差 −0.46(真值 0.11)时 α=0.5 往真值靠一半")
            expectEqual(r3(LocalPlaybackSource.learnedProbeLead(current: 0.569, residual: 2.3, hasPrior: true)), 0.569,
                        "探针领先量: 残差 >1.5s(暂停中拖了进度条)不学")
            expectEqual(r3(LocalPlaybackSource.learnedProbeLead(current: 0.5, residual: -1.8, hasPrior: false)), 0.5,
                        "探针领先量: 没先验时离谱残差同样不采")
            expectEqual(r3(LocalPlaybackSource.learnedProbeLead(current: 0.1, residual: -0.3, hasPrior: true)), -0.05,
                        "探针领先量: 允许学到负值(探针钟落后的链路)")
            expectEqual(LocalPlaybackSource.probeLeadPrior(for: .bluetooth), 0.5, "探针领先量先验: 蓝牙 0.5(真机 0.51~0.65)")
            expectEqual(LocalPlaybackSource.probeLeadPrior(for: .builtIn), 0.1, "探针领先量先验: 内建 0.1(真机 0.06~0.14)")
            expectEqual(LocalPlaybackSource.probeLeadPrior(for: .airPlay), 0, "探针领先量先验: 没量过的传输类型不假设")
            expectEqual(LocalPlaybackSource.probeLeadPrior(for: .other), 0, "探针领先量先验: 未知设备不假设")
        }
        // ---- 锚点滞后的学习(现象是「汽水音乐歌词滞后」) ----
        // 真机(09-19 汽水音乐,com.soda.music):三次假暂停量到 0.443 / 0.443 / 0.444,
        // 四首歌用「开播锚点 → 歌尾真实上报」独立反推 0.435 / 0.430 / 0.405 / 0.399。
        do {
            func r3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
            expectEqual(r3(LocalPlaybackSource.learnedAnchorLag(current: 0, residual: 0.443, hasPrior: false)), 0.443,
                        "锚点滞后: 没学过时第一份直接采信(真机汽水音乐 0.443)")
            expectEqual(r3(LocalPlaybackSource.learnedAnchorLag(current: 0.443, residual: 0, hasPrior: true)), 0.443,
                        "锚点滞后: 学准了之后残差≈0,值不动 —— 这正是补偿生效的形态")
            expectEqual(r3(LocalPlaybackSource.learnedAnchorLag(current: 0.443, residual: -0.043, hasPrior: true)), 0.426,
                        "锚点滞后: 学过之后按 α=0.4 往新样本靠,不被单次样本整份顶掉")
            expectEqual(r3(LocalPlaybackSource.learnedAnchorLag(current: 0.43, residual: 2.4, hasPrior: true)), 0.43,
                        "锚点滞后: 残差 >1.5s(seek / 换歌错位)不学")
            expectEqual(r3(LocalPlaybackSource.learnedAnchorLag(current: 0, residual: -1.9, hasPrior: false)), 0,
                        "锚点滞后: 没先验时离谱残差同样不采")
            expectEqual(r3(LocalPlaybackSource.learnedAnchorLag(current: 0.1, residual: -0.5, hasPrior: false)), 0,
                        "锚点滞后: 夹到 0 以下 —— 锚点反而超前真声不归这条路管(那是自然切歌偏置)")
            expectEqual(r3(LocalPlaybackSource.learnedAnchorLag(current: 1.4, residual: 0.9, hasPrior: false)), 1.5,
                        "锚点滞后: 夹在上限,别把别的毛病当滞后补成偏快")
        }
        // ---- App → collector 的位置偏置文件:JSON 形状与 Go 侧 positionbias_test.go 的 fixture 逐字节一致 ----
        do {
            let rec = PositionBiasRecord(artist: "Olivia Rodrigo", title: "vampire", bundleID: "com.spotify.client",
                                         anchorElapsed: 0, biasSecs: -1.957, writtenAtMs: 1_789_002_067_341)
            let encoded = (try? PositionBiasFile.encode(rec)).flatMap { String(data: $0, encoding: .utf8) }
            expectEqual(encoded,
                        #"{"anchor_elapsed":0,"artist":"Olivia Rodrigo","bias_secs":-1.957,"bundle_id":"com.spotify.client","title":"vampire","written_at_ms":1789002067341}"#,
                        "位置偏置文件: 编码结果必须逐字节等于 Go 测试里的 positionBiasFixture(键名 / 键序 / 数字格式)")
            let cleared = PositionBiasRecord(artist: "Olivia Rodrigo", title: "vampire", bundleID: "com.spotify.client",
                                             anchorElapsed: nil, biasSecs: 0, writtenAtMs: 1)
            let clearedJSON = (try? PositionBiasFile.encode(cleared)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // 合成的 Codable 对 nil 可选项是**省略键**而不是写 null;Go 侧 *float64 两种都解成 nil → 不扣。
            expectEqual(clearedJSON.contains(#""anchor_elapsed""#), false,
                        "位置偏置文件: 清零记录不带 anchor_elapsed 键(Go 侧 *float64 解成 nil → 不扣)")
            expectEqual(clearedJSON.contains(#""bias_secs":0"#), true, "位置偏置文件: 清零记录显式写 bias_secs: 0")
            expectEqual(rec.sameContent(as: PositionBiasRecord(artist: "Olivia Rodrigo", title: "vampire", bundleID: "com.spotify.client",
                                                                anchorElapsed: 0, biasSecs: -1.957, writtenAtMs: 9)), true,
                        "位置偏置文件: 只有写入时刻不同不算内容变化(不重写)")
            expectEqual(rec.sameContent(as: cleared), false, "位置偏置文件: 偏置变了要重写")
            expectEqual(PositionBiasFile.fileName, "lyrimuse-position-bias.json", "位置偏置文件: 文件名与 Go 侧 main.go 逐字节一致")
        }

        // ---- 暂停时刻外推:MediaRemote 指令暂停时 Spotify 不发布冻结值 ----
        //
        // 实测(蘇麗珍,media-control pause):事件流只有 playing:false,原始 elapsedTime 仍是开播锚点
        // 0@:44;旧规则退回上一拍记住的 5.225(旧了 ~1.9s),屏上 6.961 一下退到 5.225;Spotify 自己
        // 的钟是 6.858。把上一拍位置外推到暂停事件到达的时刻就对上了。
        do {
            let ts = Date(timeIntervalSince1970: 1_000_000)          // 开播锚点整秒
            let sampled = ts.addingTimeInterval(5.30)                 // 上一拍轮询
            let pauseAt = ts.addingTimeInterval(7.05)                 // playing:false 到达
            let now = ts.addingTimeInterval(7.35)                     // 暂停后那一拍轮询
            func ms(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
            // 锚点(开播时)早于暂停事件 7s → 不是暂停锚点 → 外推:5.225 + 1.75 = 6.975
            let extrapolated = MC.pausedPositionSeconds(
                elapsedTime: 0, anchorTimestamp: ts, lastPlaying: (5.225, sampled), pauseObservedAt: pauseAt, now: now)
            expectEqual(extrapolated.map(ms), 6.975, "暂停外推: 锚点早于暂停事件 → 上一拍外推到暂停时刻")
            // 暂停锚点(Spotify 界面里按暂停,带新时间戳 = 暂停那一秒)→ 原样用冻结值
            let frozen = MC.pausedPositionSeconds(
                elapsedTime: 6.858, anchorTimestamp: ts.addingTimeInterval(7), lastPlaying: (5.225, sampled), pauseObservedAt: pauseAt, now: now)
            expectEqual(frozen, 6.858, "暂停外推: 锚点是暂停时发布的 → 用冻结值")
            // 暂停事件早于上一拍(watcher 记的是上一次暂停)→ 退回旧规则(陈旧 + 掉得离谱 → 记住的值)
            let stalePause = MC.pausedPositionSeconds(
                elapsedTime: 0, anchorTimestamp: ts, lastPlaying: (5.225, sampled), pauseObservedAt: ts.addingTimeInterval(1), now: now)
            expectEqual(stalePause, 5.225, "暂停外推: 暂停事件不在上一拍之后 → 退回旧规则")
            // 没有暂停事件时刻 → 旧规则
            let noEvent = MC.pausedPositionSeconds(
                elapsedTime: 0, anchorTimestamp: ts, lastPlaying: (5.225, sampled), pauseObservedAt: nil, now: now)
            expectEqual(noEvent, 5.225, "暂停外推: 无事件时刻 → 旧规则")
            // 没有记住的播放位置 → 冻结值原样
            expectEqual(MC.pausedPositionSeconds(elapsedTime: 12, anchorTimestamp: ts, lastPlaying: nil, pauseObservedAt: pauseAt, now: now),
                        12, "暂停外推: 没有上一拍 → 冻结值")
            // 暂停事件早于上一拍不到 0.5s(轮询在事件之后才落定)→ 仍认,外推量为 0
            let justBefore = MC.pausedPositionSeconds(
                elapsedTime: 0, anchorTimestamp: ts, lastPlaying: (5.225, sampled), pauseObservedAt: sampled.addingTimeInterval(-0.2), now: now)
            expectEqual(justBefore, 5.225, "暂停外推: 事件略早于上一拍 → 外推量 0")
            // livePositionSeconds 暂停态接上这条(传了 lastPlayingSampledAt 才走新规则)
            let viaLive = MC.livePositionSeconds(
                playing: false, elapsedTime: 0, elapsedTimeNow: 999, playbackRate: 1, timestamp: ts, now: now,
                lastPlayingPosition: 5.225, lastPlayingSampledAt: sampled, pauseObservedAt: pauseAt)
            expectEqual(viaLive.map(ms), 6.975, "暂停外推: livePositionSeconds 暂停态走新规则")
            let viaLiveLegacy = MC.livePositionSeconds(
                playing: false, elapsedTime: 0, elapsedTimeNow: 999, playbackRate: 1, timestamp: ts, now: now,
                lastPlayingPosition: 5.225)
            expectEqual(viaLiveLegacy, 5.225, "暂停外推: 不传采样时刻仍走旧规则")
            // digest:playing:false 的行报 pausedAtArrival
            let pausedLine = Data("{\"type\":\"data\",\"diff\":true,\"payload\":{\"playing\":false}}".utf8)
            expectEqual(MediaControlStreamWatcher.digest(line: pausedLine, merged: [:], arrivedAt: now).pausedAtArrival, true,
                        "digest: playing:false 行标记暂停到达")
            let playingLine = Data("{\"type\":\"data\",\"diff\":true,\"payload\":{\"playing\":true}}".utf8)
            expectEqual(MediaControlStreamWatcher.digest(line: playingLine, merged: [:], arrivedAt: now).pausedAtArrival, false,
                        "digest: playing:true 行不标记")

            // ---- 酷狗单曲循环报 playing:false(rate 仍是 1) ----
            let kugou = PlaybackPlayer.kugou.bundleIdentifier
            // 真机:循环之后一直是 playing:false + rate 1,这时真暂停只来一行 {playbackRate:0, elapsed, timestamp}。
            let loopFull = Data("{\"type\":\"data\",\"diff\":false,\"payload\":{\"bundleIdentifier\":\"\(kugou)\",\"title\":\"灵魂相愿\",\"artist\":\"张敬轩\",\"elapsedTime\":0,\"timestamp\":\"2026-09-24T02:18:20Z\",\"playbackRate\":1,\"playing\":false}}".utf8)
            let loopMerged = MediaControlStreamWatcher.digest(line: loopFull, merged: [:], arrivedAt: now).merged
            let ratePauseLine = Data("{\"type\":\"data\",\"diff\":true,\"payload\":{\"playbackRate\":0,\"elapsedTime\":8.692,\"timestamp\":\"2026-09-24T02:18:29Z\"}}".utf8)
            expectEqual(MediaControlStreamWatcher.digest(line: ratePauseLine, merged: loopMerged, arrivedAt: now).pausedAtArrival, true,
                        "酷狗循环: 只来 rate 0 那一行也是暂停信号")
            var spotifyMerged = loopMerged
            spotifyMerged["bundleIdentifier"] = "com.spotify.client"
            expectEqual(MediaControlStreamWatcher.digest(line: ratePauseLine, merged: spotifyMerged, arrivedAt: now).pausedAtArrival, false,
                        "酷狗循环: 别的播放器的 rate 0 行照旧不算")
            let rateResumeLine = Data("{\"type\":\"data\",\"diff\":true,\"payload\":{\"playbackRate\":1,\"timestamp\":\"2026-09-24T02:18:31Z\"}}".utf8)
            expectEqual(MediaControlStreamWatcher.digest(line: rateResumeLine, merged: loopMerged, arrivedAt: now).pausedAtArrival, false,
                        "酷狗循环: rate 1 那一行不算暂停")
            let loopAnchor = ts
            let atLoop = { (secs: Double) in loopAnchor.addingTimeInterval(secs) }
            expectEqual(MC.effectivePlaying(bundleID: kugou, playing: false, playbackRate: 1, elapsedTime: 0,
                                            timestamp: loopAnchor, duration: 300, now: atLoop(75)), true,
                        "酷狗循环: rate 1 且没越过曲长 → 在播")
            expectEqual(MC.effectivePlaying(bundleID: kugou, playing: false, playbackRate: 0, elapsedTime: 177.066,
                                            timestamp: loopAnchor, duration: 300, now: atLoop(5)), false,
                        "酷狗循环: 真暂停 rate 0 → 暂停")
            expectEqual(MC.effectivePlaying(bundleID: kugou, playing: false, playbackRate: 1, elapsedTime: 0,
                                            timestamp: loopAnchor, duration: 300, now: atLoop(303)), false,
                        "酷狗循环: 越过曲长还没新锚点 → 停了")
            expectEqual(MC.effectivePlaying(bundleID: kugou, playing: false, playbackRate: 1, elapsedTime: 0,
                                            timestamp: loopAnchor, duration: 300, now: atLoop(301.5)), true,
                        "酷狗循环: 越过曲长 2s 以内仍算在播")
            expectEqual(MC.effectivePlaying(bundleID: "com.spotify.client", playing: false, playbackRate: 1, elapsedTime: 0,
                                            timestamp: loopAnchor, duration: 300, now: atLoop(75)), false,
                        "酷狗循环: 别的播放器原样")
            expectEqual(MC.effectivePlaying(bundleID: kugou, playing: nil, playbackRate: 1, elapsedTime: 0,
                                            timestamp: nil, duration: 300, now: atLoop(75)), nil,
                        "酷狗循环: 没有时间戳 → 原样")
            expectEqual(MC.effectivePlaying(bundleID: kugou, playing: true, playbackRate: 0, elapsedTime: 0,
                                            timestamp: loopAnchor, duration: 300, now: atLoop(75)), true,
                        "酷狗循环: 报 playing:true 的不动")
        }

        // ---- 自然切歌偏置只属于开播锚点 ----
        // 实测:偏置 1.080 在位时按暂停,Spotify 发布的冻结值 152.673 与 App 已扣偏置的显示 152.689
        // 只差 16ms,再扣一遍就退 1.097s。播放器重新发布的锚点(原始 elapsedTime>0)对齐它自己的钟,偏置作废。
        expectEqual(LocalPlaybackSource.biasSurvivesAnchor(anchorElapsedTime: 0), true, "偏置归属: 开播锚点(0)保留偏置")
        expectEqual(LocalPlaybackSource.biasSurvivesAnchor(anchorElapsedTime: 0.0005), true, "偏置归属: 毫秒内的 0 也算开播锚点")
        expectEqual(LocalPlaybackSource.biasSurvivesAnchor(anchorElapsedTime: 152.673), false, "偏置归属: 暂停冻结锚点作废偏置")
        expectEqual(LocalPlaybackSource.biasSurvivesAnchor(anchorElapsedTime: 50.844), false, "偏置归属: 恢复锚点作废偏置")
        expectEqual(LocalPlaybackSource.biasSurvivesAnchor(anchorElapsedTime: nil), true, "偏置归属: 没有锚点信息(AppleScript 路径)不动")
        // 偏置归属改成"量它时对着的那个锚点"。Spotify 开播半秒内会把 0@T 改发成 1.923@T
        // (BIRDS OF A FEATHER 实测),按旧判据这首歌的偏置活不过下一拍;探针量出的负偏置也要能跟着
        // 一个 elapsed>0 的锚点活下去。
        expectEqual(LocalPlaybackSource.biasSurvivesAnchor(anchorElapsedTime: 1.923, measuredAgainst: 1.923), true,
                    "偏置归属: 对着 1.923 量的偏置,锚点仍是 1.923 就保留")
        expectEqual(LocalPlaybackSource.biasSurvivesAnchor(anchorElapsedTime: 1.923, measuredAgainst: 0), false,
                    "偏置归属: 对着 0 量的偏置,锚点改发成 1.923 就作废")
        expectEqual(LocalPlaybackSource.biasSurvivesAnchor(anchorElapsedTime: 0, measuredAgainst: 0), true,
                    "偏置归属: 开播锚点重复出现(同 elapsed)保留")
        expectEqual(LocalPlaybackSource.biasSurvivesAnchor(anchorElapsedTime: 41.377, measuredAgainst: 0), false,
                    "偏置归属: 暂停冻结锚点(41.377)作废对着开播锚点量的偏置")
        expectEqual(LocalPlaybackSource.biasSurvivesAnchor(anchorElapsedTime: nil, measuredAgainst: 1.923), true,
                    "偏置归属: 没有锚点信息时不动,与 measuredAgainst 无关")
        // 没有锚点信息 = 读的是 Spotify 自己的钟(AppleScript)。那个钟一暂停就对回出声位置:
        // 实测暂停冻结值比暂停前一刻的读数退回 0.926 / 0.963s,伺服 errEMA 同期 ≈0。
        expectEqual(LocalPlaybackSource.biasSurvivesAnchor(anchorElapsedTime: nil, playing: false), false,
                    "偏置归属: 播放器自己的钟,暂停那一拍作废偏置")
        expectEqual(LocalPlaybackSource.biasSurvivesAnchor(anchorElapsedTime: nil, playing: true), true,
                    "偏置归属: 播放器自己的钟,播放中保留偏置")
        expectEqual(LocalPlaybackSource.biasSurvivesAnchor(anchorElapsedTime: 0, playing: false), true,
                    "偏置归属: media-control 开播锚点没重发的暂停(指令暂停)照旧保留,playing 只管没有锚点的那一档")

        // ---- 自然切歌领先按播放器开,不按档位开 ----
        // Spotify 的 `player position` 归 precise 档,但 gapless 自然切歌后照样整首领先 ~1s、暂停才对齐。
        let spotifyID = PlaybackPlayer.spotify.bundleIdentifier
        expectEqual(LocalPlaybackSource.positionSourceTier(forBundleID: spotifyID) == .precise, true,
                    "gapless 领先: 前提 —— Spotify 归 precise 档(不然下一条测的不是这件事)")
        expectEqual(LocalPlaybackSource.carriesGaplessLead(tier: .precise, bundleID: spotifyID), true,
                    "gapless 领先: Spotify 在 precise 档也要自然切歌校正")
        expectEqual(LocalPlaybackSource.carriesGaplessLead(tier: .precise, bundleID: PlaybackPlayer.appleMusic.bundleIdentifier), false,
                    "gapless 领先: Apple Music 的播放头是真值,不校正")
        expectEqual(LocalPlaybackSource.carriesGaplessLead(tier: .cleanExtrapolated, bundleID: PlaybackPlayer.soda.bundleIdentifier), true,
                    "gapless 领先: cleanExtrapolated 档照旧校正")
        // 酷狗的钟在单曲循环回绕与自然切歌处都连续(实测差 0.04~0.08s),不按越界量估。
        expectEqual(LocalPlaybackSource.carriesGaplessLead(tier: .cleanExtrapolated, bundleID: PlaybackPlayer.kugou.bundleIdentifier), false,
                    "gapless 领先: 酷狗不估")
        expectEqual(LocalPlaybackSource.carriesGaplessLead(tier: .noisyFloored, bundleID: PlaybackPlayer.qqMusic.bundleIdentifier), false,
                    "gapless 领先: 整秒地板源不校正")
        // 锚点滞后:酷狗晚打时有时无,不学平均值;汽水照旧。
        expectEqual(LocalPlaybackSource.learnsAnchorLag(bundleID: PlaybackPlayer.kugou.bundleIdentifier), false,
                    "锚点滞后: 酷狗不学")
        expectEqual(LocalPlaybackSource.learnsAnchorLag(bundleID: PlaybackPlayer.soda.bundleIdentifier), true,
                    "锚点滞后: 汽水照旧")

        // ---- 酷狗自然切歌:按先到的归零锚点(还挂着上一首标题)的起播时刻补 ----
        // 真机四首(时间戳取末几位,单位秒):真实起播由暂停冻结值反推。
        do {
            typealias MC = MediaControlClient
            func at(_ secs: Double) -> Date { Date(timeIntervalSince1970: 1_790_219_000 + secs) }
            func ms(_ v: Double?) -> Double? { v.map { ($0 * 1000).rounded() / 1000 } }
            // GABBA GABBA:归零 0.110@2.988443(旧标题《奔赴超无限》),新标题 0.364@3.790431、0.980@4.372887;真实起播 2.920
            let gabba = MC.ResetAnchor(title: "奔赴超无限", elapsed: 0.110, timestamp: at(2.988443))
            expectEqual(ms(MC.resetAnchorStartCorrection(resets: [gabba], title: "GABBA GABBA", elapsed: 0.364, timestamp: at(3.790431))), 0.548,
                        "切歌补偿: 新标题第一份锚点晚 0.548")
            expectEqual(ms(MC.resetAnchorStartCorrection(resets: [gabba], title: "GABBA GABBA", elapsed: 0.980, timestamp: at(4.372887))), 0.514,
                        "切歌补偿: 重发的那份照样补")
            // 天际:归零 0.030@212.135、新标题 0.591@212.703 —— 起播只差 0.007,不补(本来就准)
            let tianji = MC.ResetAnchor(title: "灵魂相愿", elapsed: 0.030, timestamp: at(212.135))
            expectEqual(MC.resetAnchorStartCorrection(resets: [tianji], title: "天际 (粤语版)", elapsed: 0.591, timestamp: at(212.703)), nil,
                        "切歌补偿: 差不到 0.05 不补")
            // 别来无恙:归零 0.036@226.766、新标题 0.495@227.735,真实起播 226.766 → 补 0.51
            let bielai = MC.ResetAnchor(title: "天际 (粤语版)", elapsed: 0.036, timestamp: at(226.766))
            expectEqual(ms(MC.resetAnchorStartCorrection(resets: [bielai], title: "歌曲：别来无恙", elapsed: 0.495, timestamp: at(227.735))), 0.51,
                        "切歌补偿: 别来无恙补 0.51")
            // 同一个标题下的归零是单曲循环回绕,不补
            expectEqual(MC.resetAnchorStartCorrection(resets: [gabba], title: "奔赴超无限", elapsed: 0.364, timestamp: at(3.790431)), nil,
                        "切歌补偿: 同标题(循环)不补")
            // 离归零锚点超过 3s、或新锚点已经放到 3s 以后(暂停 / 恢复重发的),不补
            expectEqual(MC.resetAnchorStartCorrection(resets: [gabba], title: "GABBA GABBA", elapsed: 0.364, timestamp: at(6.5)), nil,
                        "切歌补偿: 超出窗口不补")
            expectEqual(MC.resetAnchorStartCorrection(resets: [gabba], title: "GABBA GABBA", elapsed: 150.261, timestamp: at(153.181)), nil,
                        "切歌补偿: 暂停冻结锚点不补")
            expectEqual(MC.resetAnchorStartCorrection(resets: [], title: "GABBA GABBA", elapsed: 0.364, timestamp: at(3.790431)), nil,
                        "切歌补偿: 没见过归零锚点不补")
            // 新标题自己那份位置也很小,会紧跟着被记成归零锚点;对照时要越过它、找标题不同的那份(真机:百鬼夜行 0.172 顶掉了 Regression 0.043)
            let own = MC.ResetAnchor(title: "GABBA GABBA", elapsed: 0.364, timestamp: at(3.790431))
            expectEqual(ms(MC.resetAnchorStartCorrection(resets: [gabba, own], title: "GABBA GABBA", elapsed: 0.364, timestamp: at(3.790431))), 0.548,
                        "切歌补偿: 越过新标题自己那份")
            expectEqual(MC.correctsFromResetAnchor(bundleID: PlaybackPlayer.kugou.bundleIdentifier), true, "切歌补偿: 酷狗开")
            expectEqual(MC.correctsFromResetAnchor(bundleID: PlaybackPlayer.soda.bundleIdentifier), false, "切歌补偿: 别的播放器不开")
        }
        expectEqual(LocalPlaybackSource.carriesGaplessLead(tier: .noisyFloored, bundleID: nil), false,
                    "gapless 领先: 认不出播放器不校正")

        // ---- 没看到的暂停:读数退回约一个偏置量 = Spotify 的钟已对回出声位置 ----
        expectEqual(LocalPlaybackSource.playerClockResynced(error: -0.963, bias: 1.0, anchorElapsedTime: nil), true,
                    "钟对齐: 退回≈偏置 → 已对齐")
        expectEqual(LocalPlaybackSource.playerClockResynced(error: -1.6, bias: 1.0, anchorElapsedTime: nil), true,
                    "钟对齐: 退回=偏置+漏掉的暂停时长,同样算")
        expectEqual(LocalPlaybackSource.playerClockResynced(error: -0.5, bias: 1.0, anchorElapsedTime: nil), false,
                    "钟对齐: 只退回一半,不像对齐,交给伺服")
        expectEqual(LocalPlaybackSource.playerClockResynced(error: -0.04, bias: 1.0, anchorElapsedTime: nil), false,
                    "钟对齐: 稳态噪声不算")
        expectEqual(LocalPlaybackSource.playerClockResynced(error: -0.12, bias: 0.08, anchorElapsedTime: nil), false,
                    "钟对齐: 偏置很小时噪声级退回不误清")
        expectEqual(LocalPlaybackSource.playerClockResynced(error: -0.963, bias: 1.0, anchorElapsedTime: 0), false,
                    "钟对齐: media-control 那条路另有锚点重发判据,这里不管")
        expectEqual(LocalPlaybackSource.playerClockResynced(error: -0.963, bias: -1.0, anchorElapsedTime: nil), false,
                    "钟对齐: 负偏置(锚点落后)语义相反,不管")
        expectEqual(LocalPlaybackSource.playerClockResynced(error: -0.963, bias: 0, anchorElapsedTime: nil), false,
                    "钟对齐: 没有偏置就没有要清的")

        // ---- 歌尾:Spotify 的钟停住 / 往回退,照外推走 ----
        // 真机:《中國姑娘》时长 274.33,读数停在 273.356,外推 273.857 —— 旧逻辑把它当成钟对齐、往回拽 0.5s,
        // 下一首的偏置因此多估 0.5s。
        expectEqual(LocalPlaybackSource.inPlayerClockTail(predicted: 273.857, raw: 273.356, duration: 274.33, anchorElapsedTime: nil), true,
                    "歌尾: 最后一秒停住的读数照外推走")
        expectEqual(LocalPlaybackSource.inPlayerClockTail(predicted: 29.9, raw: 29.110, duration: 30.0, anchorElapsedTime: nil), true,
                    "歌尾: 往回退的读数同样照外推走")
        expectEqual(LocalPlaybackSource.inPlayerClockTail(predicted: 272.0, raw: 120.0, duration: 274.33, anchorElapsedTime: nil), false,
                    "歌尾: 从歌尾往回拖,读数离开歌尾 → 不吞,交给 seek 分支")
        expectEqual(LocalPlaybackSource.inPlayerClockTail(predicted: 200.0, raw: 200.6, duration: 274.33, anchorElapsedTime: nil), false,
                    "歌尾: 还没到歌尾照常")
        expectEqual(LocalPlaybackSource.inPlayerClockTail(predicted: 273.857, raw: 273.356, duration: 274.33, anchorElapsedTime: 0), false,
                    "歌尾: media-control 那条路不归这里管")
        expectEqual(LocalPlaybackSource.inPlayerClockTail(predicted: 10, raw: 10, duration: 0, anchorElapsedTime: nil), false,
                    "歌尾: 不知道时长不判")

        // ---- App 重启后接回上一个进程的偏置 ----
        do {
            let written = Date(timeIntervalSince1970: 1_790_000_000)
            let rec = PositionBiasRecord(artist: "周杰倫", title: "火車叼位去", bundleID: PlaybackPlayer.spotify.bundleIdentifier,
                                         anchorElapsed: nil, biasSecs: 0.8, writtenAtMs: Int64(written.timeIntervalSince1970 * 1000))
            func restore(_ r: PositionBiasRecord = rec, artist: String = "周杰倫", raw: Double, after secs: Double) -> Double? {
                LocalPlaybackSource.restorablePlayerClockBias(
                    record: r, bundleID: PlaybackPlayer.spotify.bundleIdentifier, artist: artist, title: "火車叼位去",
                    raw: raw, now: written.addingTimeInterval(secs))
            }
            expectEqual(restore(raw: 34.8, after: 34), 0.8, "重启接回: 一直连续在放 → 接回")
            expectEqual(restore(raw: 20.8, after: 34) == nil, true, "重启接回: 中途暂停过(位置比记录至今少一截)→ 不接")
            expectEqual(restore(raw: 90.8, after: 34) == nil, true, "重启接回: 中途往前拖过 → 不接")
            expectEqual(restore(artist: "方大同", raw: 34.8, after: 34) == nil, true, "重启接回: 不是同一首 → 不接")
            var mc = rec; mc.anchorElapsed = 0
            expectEqual(restore(mc, raw: 34.8, after: 34) == nil, true, "重启接回: media-control 那档的偏置不接")
            var zero = rec; zero.biasSecs = 0
            expectEqual(restore(zero, raw: 34.8, after: 34) == nil, true, "重启接回: 记录里没有偏置 → 不接")
            expectEqual(restore(raw: 34.8, after: -5) == nil, true, "重启接回: 记录时刻在未来(时钟乱了)→ 不接")
            // 恢复播放那一拍量的偏置:记录写在曲中,带着那一刻的位置。
            var mid = rec; mid.positionSecs = 123.766; mid.biasSecs = 1.336
            expectEqual(restore(mid, raw: 123.766 + 40 + 1.336, after: 40), 1.336, "重启接回: 曲中量的偏置按记录里的位置核连续性")
            expectEqual(restore(mid, raw: 40 + 1.336, after: 40) == nil, true, "重启接回: 曲中量的偏置不能按位置 0 去核")
        }

        // ---- Spotify 自己的钟:按起播方式分档的领先量(ScreenCaptureKit 截音频实测) ----
        do {
            typealias K = LocalPlaybackSource.SpotifyStartKind
            func r3(_ x: Double?) -> Double? { x.map { ($0 * 1000).rounded() / 1000 } }
            expectEqual(LocalPlaybackSource.spotifyStartLeadPrior(.fresh), 0.24, "起播领先: 手动点播 / 没预载换歌 先验 0.24")
            // 同曲跳回开头:重新起播(`play track` / 点同一首)先发 Playing@0 通知,真实领先 0.21~0.27(同 fresh);
            // 拖动(含拖到 0)不发通知,真实领先 0.43~0.51。
            do {
                let t = Date(timeIntervalSince1970: 1_790_229_862)
                expectEqual(LocalPlaybackSource.spotifyJumpKind(raw: 0.25, playingFromStartNoticeAt: t, now: t.addingTimeInterval(0.4)), .fresh,
                            "起播领先: 刚收到从头播放的通知 → 重新起播")
                expectEqual(LocalPlaybackSource.spotifyJumpKind(raw: 0.004, playingFromStartNoticeAt: nil, now: t), .seek,
                            "起播领先: 拖到 0、没有通知 → 拖动")
                expectEqual(LocalPlaybackSource.spotifyJumpKind(raw: 0.25, playingFromStartNoticeAt: t, now: t.addingTimeInterval(8)), .seek,
                            "起播领先: 通知是很久以前的 → 拖动")
                expectEqual(LocalPlaybackSource.spotifyJumpKind(raw: 90.5, playingFromStartNoticeAt: t, now: t.addingTimeInterval(0.4)), .seek,
                            "起播领先: 跳到曲中 → 拖动")
            }
            expectEqual(LocalPlaybackSource.spotifyStartLeadPrior(.seek), 0.45, "起播领先: 播放中拖动 先验 0.45")
            expectEqual(LocalPlaybackSource.spotifyStartLeadPrior(.gapless), 0.66, "起播领先: 预载无缝换歌 先验 0.66(实测 0.49~0.73 的均值)")
            // 预载:新曲的钟在旧曲钟走到头那一刻接上(实测差 ~0.1);没预载:新曲的钟晚 1.9s。
            expectEqual(LocalPlaybackSource.isPreloadedGaplessStart(raw: 0.056, clockOverrun: 0.13), true, "起播方式: 钟接得上 → 预载无缝")
            expectEqual(LocalPlaybackSource.isPreloadedGaplessStart(raw: 0.05, clockOverrun: 1.95), false, "起播方式: 钟晚 1.9s → 没预载")
            expectEqual(LocalPlaybackSource.isPreloadedGaplessStart(raw: 0.3, clockOverrun: -120), false, "起播方式: 旧曲远没放完(手动跳歌)→ 不算")
            // 广告放完接着放的那首(真机:广告报 29.99s、29.09 就结束,新曲 raw 0.527、旧曲钟越界 1.05 → 差 0.52 刚好过不了
            // 预载判据;暂停反推真实领先 0.766)。它得单独一档,学进 fresh 会把手动点播(真实 0.27)抬到 0.6。
            expectEqual(LocalPlaybackSource.spotifyNaturalStartKind(raw: 0.527, clockOverrun: 1.05, previousWasAd: true), .afterAd,
                        "起播方式: 广告之后接着放 → afterAd")
            expectEqual(LocalPlaybackSource.spotifyNaturalStartKind(raw: 0.527, clockOverrun: 1.05, previousWasAd: false), .fresh,
                        "起播方式: 不是广告之后,同样的数照旧 → fresh")
            expectEqual(LocalPlaybackSource.spotifyNaturalStartKind(raw: 0.056, clockOverrun: 0.13, previousWasAd: false), .gapless,
                        "起播方式: 预载无缝换歌照旧")
            expectEqual(LocalPlaybackSource.spotifyNaturalStartKind(raw: 0.3, clockOverrun: -120, previousWasAd: true), .fresh,
                        "起播方式: 广告远没放完就换了(不是自然接上)→ 不算 afterAd")
            expectEqual(LocalPlaybackSource.spotifyStartLeadPrior(.afterAd), 0.66, "起播领先: 广告之后 先验同预载无缝 0.66")
            // 表的规则版本:旧表(没有版本号 = 1)里的 fresh 混着广告之后的样本(本机被抬到 0.542,真实 0.27),
            // 升到 2 时只作废 fresh;别的档规则没变,原样保留。按规则作废,不按数值大小。
            do {
                let old: [String: Double] = ["fresh": 0.542, "gapless": 0.705, "seek": 0.466]
                let v2 = LocalPlaybackSource.migratedStartLeadTable(old, fromSchema: 1)
                expectEqual(v2["fresh"], nil, "起播领先表迁移: 旧 fresh 作废,回到先验")
                expectEqual(v2["gapless"], 0.705, "起播领先表迁移: gapless 保留")
                expectEqual(v2["seek"], 0.466, "起播领先表迁移: seek 保留")
                expectEqual(LocalPlaybackSource.migratedStartLeadTable(["fresh": 0.3], fromSchema: 1)["fresh"], nil,
                            "起播领先表迁移: 旧 fresh 看着像准的也作废(不按数值猜)")
                expectEqual(LocalPlaybackSource.migratedStartLeadTable(["fresh": 0.26, "afterAd": 0.7], fromSchema: 2),
                            ["fresh": 0.26, "afterAd": 0.7], "起播领先表迁移: 已是当前版本的表原样不动")
                expectEqual(LocalPlaybackSource.migratedStartLeadTable([:], fromSchema: 1), [:], "起播领先表迁移: 空表(新装)不出错")
                expectEqual(LocalPlaybackSource.spotifyStartLeadSchema, 2, "起播领先表迁移: 当前版本 2")
            }
            // 暂停残差:偏置为 0、delta −0.504 → 真实领先 0.774(音频直接量 0.732);偏置量得准时 delta ≈ +0.27。
            expectEqual(r3(LocalPlaybackSource.pauseResidualLead(bias: 0, pauseDelta: -0.504)), 0.774, "暂停残差: 没扣偏置的一段反推出 0.774")
            expectEqual(r3(LocalPlaybackSource.pauseResidualLead(bias: 0.256, pauseDelta: 0.303)), 0.223, "暂停残差: 偏置准时样本≈偏置本身")
            expectEqual(LocalPlaybackSource.pauseResidualLead(bias: 0.24, pauseDelta: -1.5) == nil, true, "暂停残差: 残差超过 1s 不学")
            expectEqual(LocalPlaybackSource.pauseResidualLead(bias: 0, pauseDelta: 0.9) == nil, true, "暂停残差: 反推出负领先不学")
            expectEqual(r3(LocalPlaybackSource.learnedStartLead(current: 0.72, sample: 1.2)), 0.864, "起播领先学习: EMA α=0.3")
            // 开播钟起步晚:真机首笔 0.001、1.3s 后 0.087,扣完偏置 −0.167、外推 1.061。
            expectEqual(LocalPlaybackSource.playerClockStartedLate(raw: 0.087, reported: -0.167, predicted: 1.061), true,
                        "开播起步晚: 曲首读数落在外推后面 → 跟着钟重新对准、偏置保留")
            expectEqual(LocalPlaybackSource.playerClockStartedLate(raw: 120.3, reported: 120.05, predicted: 121.0), false,
                        "开播起步晚: 曲中的落后不算(那是钟对齐,归 playerClockResynced)")
            expectEqual(LocalPlaybackSource.playerClockStartedLate(raw: 1.5, reported: 1.26, predicted: 1.3), false,
                        "开播起步晚: 噪声级不算")
            _ = K.allCases
        }

        // ---- 恢复播放:Spotify 自己的钟重新领先,播种值(暂停值 + 信号至今)即真声 ----
        // 真机:暂停 123.553,恢复 0.213s 后读数 125.102,播种 123.766 → 领先 1.336(下一拍伺服照这个量吸附过去)。
        expectEqual(LocalPlaybackSource.resumeLead(raw: 125.102, seed: 123.766).map { ($0 * 1000).rounded() / 1000 }, 1.336,
                    "恢复领先: 读数比播种值快 1.336 → 折进偏置")
        expectEqual(LocalPlaybackSource.resumeLead(raw: 80.107, seed: 80.136) == nil, true, "恢复领先: 读数不快(−0.03)不折")
        expectEqual(LocalPlaybackSource.resumeLead(raw: 20.83, seed: 20.807) == nil, true, "恢复领先: 噪声级(0.02)不折")
        expectEqual(LocalPlaybackSource.resumeLead(raw: 60, seed: 20) == nil, true, "恢复领先: 大到不像领先(暂停中拖过)不折")

        // ---- 同一首歌里读数换了钟:偶发一拍挡住,持续才换 ----
        do {
            let t = Date(timeIntervalSince1970: 1_790_000_000)
            typealias A = LocalPlaybackSource.SpotifyClockAction
            func act(_ accepted: Bool?, _ reads: Bool, _ sinceAgo: Double?) -> A {
                LocalPlaybackSource.spotifyClockAction(
                    acceptedPlayerClock: accepted, readsPlayerClock: reads,
                    foreignSince: sinceAgo.map { t.addingTimeInterval(-$0) }, now: t)
            }
            expectEqual(act(nil, false, nil), A.accept, "换钟: 这一首还没定钟 → 照常")
            expectEqual(act(true, true, nil), A.accept, "换钟: 一直是 AppleScript → 照常")
            expectEqual(act(true, false, nil), A.hold, "换钟: 第一拍退回 media-control → 挡住")
            expectEqual(act(true, false, 2), A.hold, "换钟: 退回 2s → 还在挡")
            expectEqual(act(true, false, 4.5), A.switchClock, "换钟: 退回超过 4s → 认定换钟")
            expectEqual(act(false, true, nil), A.switchClock, "换钟: 从 media-control 回到 AppleScript → 立即换回")
            expectEqual(act(false, false, nil), A.accept, "换钟: 已经换到 media-control 之后 → 照常")
        }

        // ---- 锚点冻结的源:暂停时不能回退到那个恒为 0 的 elapsedTime ----
        //
        // 现象是「用 Arc 播放音乐歌词进度慢」时查出来的连带 bug。Arc 这类网页播放器
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
    // (实测排查坐实:稳定播放分支只按墙钟外推、不回看真实读数,播种偏差/漏观察
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

    // ---- resumeSeedSeconds:从暂停恢复那一拍的播种值 ----
    //
    // 真机实测:每一次恢复的前跳都是正的(+0.37~+1.93s),而位置在暂停期间根本没走 ——
    // 来源是 elapsedTimeNow 暂停期间照样空转。上界取"恢复信号到达至今"(实测 0.31~0.43s,
    // 中位数 0.338);不能取"距上一次观测"——暂停档轮询 6 秒一拍,那个上界砍不到东西。
    do {
        // 实测案例:冻结 50.570,恢复那一笔报 51.971(前跳 1.401),信号才到 0.328 秒。
        let seed = LocalPlaybackSource.resumeSeedSeconds(
            reported: 51.971, frozen: 50.570, maxForwardSecs: 0.328)
        expectEqual((seed * 1000).rounded() / 1000, 50.898, "resumeSeed: 不可能发生的前跳削到上界")
    }

    do {
        // 上界之内的超前原样采信 —— 那是真的播了这么久。
        let seed = LocalPlaybackSource.resumeSeedSeconds(
            reported: 50.8, frozen: 50.570, maxForwardSecs: 0.328)
        expectEqual(seed, 50.8, "resumeSeed: 上界内的超前照单全收")
    }

    do {
        // 落后不砍:暂停中拖了进度条 / 播放器自报了更早的位置,该听它的。
        let seed = LocalPlaybackSource.resumeSeedSeconds(
            reported: 10.0, frozen: 50.570, maxForwardSecs: 0.328)
        expectEqual(seed, 10.0, "resumeSeed: 报得更早时原样采信(暂停中拖动)")
    }

    do {
        // 没有冻结真值(首次观察同曲)时无从比较,原样采信。
        let seed = LocalPlaybackSource.resumeSeedSeconds(
            reported: 42.0, frozen: nil, maxForwardSecs: 0.328)
        expectEqual(seed, 42.0, "resumeSeed: 没有冻结真值就不砍")
    }

    do {
        // 拿不到信号时上界退回兜底,宁可少砍也别按猜出来的上界砍。
        let seed = LocalPlaybackSource.resumeSeedSeconds(
            reported: 999, frozen: 25.0, maxForwardSecs: 600)
        expectEqual(seed, 25.0 + LocalPlaybackSource.resumeMaxForwardCapSecs,
                    "resumeSeed: 上界本身也要被硬上限封顶")
    }

    // ---- servoDecision 第三档:Spotify(cleanExtrapolated,拆档) ----
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

    // ---- shouldProbeLateAnchor: Spotify 中途重发的晚锚点 ----
    //
    // 真机一天的日志:这种锚点 30 次,幅度集中在 1.0~2.0 秒。它比 seek 容差(2s)小、又不满足
    // isStaleAnchorRepublish 的"elapsed 逐 ms 相等",两道闸都不管,伺服几拍后把它当新真相 ——
    // 整首歌恒定落后,暂停才纠得回来。机制见 LocalPlaybackSource.shouldProbeLateAnchor。
    do {
        // 日志里的四个真实样本(真实位置 → 锚点报的值)。
        let samples: [(String, Double, Double)] = [
            ("Ed Sheeran|Castle on the Hill", 25.8, 23.8),
            ("Olivia Rodrigo|vampire", 71.3, 69.6),
            ("Dua Lipa|IDGAF", 200.3, 199.2),
            ("Chappell Roan|Pink Pony Club", 258.1, 257.1),
        ]
        for (name, predicted, reported) in samples {
            expectEqual(
                LocalPlaybackSource.shouldProbeLateAnchor(
                    reported: reported, predicted: predicted, tier: .cleanExtrapolated),
                true, "shouldProbeLateAnchor: 实测样本 \(name) 应触发确认")
        }
    }

    do {
        // 稳态抖动与边界:0.05s 噪声不问,恰好 0.5s 不问(要**过**下沿才问)。
        expectEqual(
            LocalPlaybackSource.shouldProbeLateAnchor(reported: 100.0, predicted: 100.05, tier: .cleanExtrapolated),
            false, "shouldProbeLateAnchor: ±0.05s 稳态抖动不问探针")
        expectEqual(
            LocalPlaybackSource.shouldProbeLateAnchor(reported: 100.0, predicted: 100.5, tier: .cleanExtrapolated),
            false, "shouldProbeLateAnchor: 恰好 0.5s 在下沿上,不问")
        expectEqual(
            LocalPlaybackSource.shouldProbeLateAnchor(reported: 100.0, predicted: 100.51, tier: .cleanExtrapolated),
            true, "shouldProbeLateAnchor: 过了下沿就问")
    }

    do {
        // 跳变过 2 秒归 seek 分支(它自己会问探针),这里不重复;向前跳不是晚锚点。
        expectEqual(
            LocalPlaybackSource.shouldProbeLateAnchor(reported: 4.172, predicted: 101.481, tier: .cleanExtrapolated),
            false, "shouldProbeLateAnchor: 差 97s 的假锚点归 seek 分支,不在这里问")
        expectEqual(
            LocalPlaybackSource.shouldProbeLateAnchor(reported: 100.0, predicted: 97.5, tier: .cleanExtrapolated),
            false, "shouldProbeLateAnchor: 读数向前跳不是晚锚点")
    }

    do {
        // 只对 Spotify 那一档开:Apple Music 的播放头是真值,QQ/网易云的整秒地板天天向后差。
        expectEqual(
            LocalPlaybackSource.shouldProbeLateAnchor(reported: 100.0, predicted: 101.5, tier: .precise),
            false, "shouldProbeLateAnchor: 精确源不问")
        expectEqual(
            LocalPlaybackSource.shouldProbeLateAnchor(reported: 100.0, predicted: 101.5, tier: .noisyFloored),
            false, "shouldProbeLateAnchor: 地板量化源不问")
    }

    // ---- probeMeasuredBias: 两个数必须同域,连着两次探针不许叠加偏置 ----
    //
    // 用户报"Spotify 歌词忽快忽慢、暂停重播就对齐"。真机日志里两次命中,都是偏置还在位时
    // 第二个探针落地(开播那次与锚点变化那次隔百来毫秒),把旧偏置叠进了新偏置。方向跟着旧
    // 偏置的符号走,所以一会儿快一会儿慢。机制见 LocalPlaybackSource.probeMeasuredBias。
    do {
        // 日志实测样本:(流读数, 探针值, 落地前已在位的旧偏置, 正解)。
        // 叠加版会算成 正解 + 旧偏置 —— 分别是 -1.443 与 +2.187,正是屏上偏快 0.7s / 偏慢 1.1s。
        let samples: [(String, Double, Double, Double, Double)] = [
            ("Daniel Caesar|Valentina", 2.214, 2.943, -0.714, -0.729),
            ("Daniel Caesar|Toronto 2014", 2.766, 1.677, 1.098, 1.089),
        ]
        for (name, streamRaw, probeRaw, oldBias, want) in samples {
            let got = LocalPlaybackSource.probeMeasuredBias(streamRaw: streamRaw, probeRaw: probeRaw)
            expectEqual(abs(got - want) < 1e-9, true,
                "probeMeasuredBias: 实测样本 \(name) 应为 \(want),得到 \(got)")
            // 同一组数按旧的混域写法(减数扣过旧偏置)会多出正好一个旧偏置。
            let mixedDomain = streamRaw - (probeRaw - oldBias)
            expectEqual(abs(mixedDomain - (want + oldBias)) < 1e-9, true,
                "probeMeasuredBias: 混域写法叠加的就是旧偏置这一段(\(name))")
            expectEqual(abs(got - mixedDomain) > 0.5, true,
                "probeMeasuredBias: 实测样本 \(name) 两种写法差得够大,不是数值噪声")
        }
        // 幂等:偏置在位时同一笔观测再量一次,结果必须不变(这才是"不叠加"的真正含义)。
        let first = LocalPlaybackSource.probeMeasuredBias(streamRaw: 2.214, probeRaw: 2.943)
        let second = LocalPlaybackSource.probeMeasuredBias(streamRaw: 2.214, probeRaw: 2.943)
        expectEqual(first == second, true, "probeMeasuredBias: 纯函数,重复量同一笔不累积")
        expectEqual(LocalPlaybackSource.probeMeasuredBias(streamRaw: 50, probeRaw: 50) == 0, true,
            "probeMeasuredBias: 流读数与探针一致时偏置为 0")
    }

    // ---- probeLeadApplies: 领先量只属于开播锚点那一档 ----
    //
    // 用户报"歌词进度有时快有时慢,暂停之后就是准确的"。按偏置对着哪个锚点量的分组,真机一
    // 上午的暂停残差分成符号完全不重叠的两簇:开播锚点那档全正(领先量是真的、还差一点没扣够),
    // 曲中重打那档全负、且量值正好等于当时的领先量(说明那一档真实领先量是 0,扣了就是错)。
    // 两簇喂进同一个数会互相拽,学出来的中间值两边都错、方向相反。机制见 probeLeadApplies。
    do {
        // (残差, 偏置对着的锚点 elapsed, 该不该算领先量样本)
        let samples: [(Double, Double, Bool)] = [
            (0.252, 0.000, true),
            (0.262, 0.000, true),
            (0.585, 0.000, true),
            (-1.004, 2.458, false),
            (-0.832, 27.160, false),
        ]
        for (residual, measuredAgainst, wantSample) in samples {
            expectEqual(LocalPlaybackSource.probeLeadApplies(anchorElapsedTime: measuredAgainst), wantSample,
                "probeLeadApplies: 残差 \(residual) 对着锚点 \(measuredAgainst),该不该学 = \(wantSample)")
        }
        // 这条钉住"两簇确实分得开"——将来判据被改松导致混样,这里会先红。
        let kept = samples.filter { LocalPlaybackSource.probeLeadApplies(anchorElapsedTime: $0.1) }.map(\.0)
        let dropped = samples.filter { !LocalPlaybackSource.probeLeadApplies(anchorElapsedTime: $0.1) }.map(\.0)
        expectEqual(kept.allSatisfy { $0 > 0 } && dropped.allSatisfy { $0 < 0 }, true,
            "probeLeadApplies: 留下的残差全正、剔掉的全负,两簇不重叠")
        expectEqual(kept.count == 3 && dropped.count == 2, true,
            "probeLeadApplies: 实测五个样本分成 3 留 2 剔")

        expectEqual(LocalPlaybackSource.probeLeadApplies(anchorElapsedTime: 0), true,
            "probeLeadApplies: 开播锚点(0)要扣领先量")
        expectEqual(LocalPlaybackSource.probeLeadApplies(anchorElapsedTime: 0.0005), true,
            "probeLeadApplies: 毫秒内的 0 也算开播锚点(判据与 biasSurvivesAnchor 同一条)")
        expectEqual(LocalPlaybackSource.probeLeadApplies(anchorElapsedTime: 1.923), false,
            "probeLeadApplies: 曲中重打的锚点上探针即真值,不扣")
        expectEqual(LocalPlaybackSource.probeLeadApplies(anchorElapsedTime: nil), true,
            "probeLeadApplies: 没有锚点信息(AppleScript 路径)维持原行为")
    }

    do {
        // 这条钉住"为什么只问探针、不动位置":同样的 1.2s 晚锚点,伺服要第 3 拍才 snap 过去,
        // 而探针 ~1 秒就回来 —— 坏值来不及固化。伺服真的更早 snap 的话这个设计就不成立了。
        var ema = 0.0
        var rounds = 0
        for _ in 1...5 {
            rounds += 1
            let (newEMA, snap) = LocalPlaybackSource.servoDecision(errEMA: ema, error: -1.2, tier: .cleanExtrapolated)
            ema = newEMA
            if snap { break }
        }
        expectEqual(rounds >= 3, true, "晚锚点: 伺服不该早于第 3 拍 snap 到坏锚点,实际 \(rounds) 拍")
    }

    // ---- 自然切歌锚点超前校正:Spotify gapless 整曲偏快的根修 ----
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

    // ---- 冻结守卫:曲目/广告结尾 Spotify 锚点冻住 ----
    //
    // 实测(边界探针):广告结尾 elapsedTimeNow 卡死 6 秒,真声一路走到落后 8 秒。不拦的话
    // 冻结值几秒后超过 2s seek 容差,位置被"重锚"回冻结值,歌尾歌词整段倒回去 —— 现象是
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

    // ---- LocalPlaybackSource: seek 之后丢弃陈旧位置读数 ----
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

    // ---- MusicPlaybackController.seek: 参数格式化与夹值 ----
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

    // ── 逐字数据退化时必须退回整行模式 ──
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
        // Spotify(cleanExtrapolated)的读数恒略**超前**真值,棘轮前提
        // 正好反着——只往前吸附会把位置锁在抖动上包络,拆档时明确排除。
        expectEqual(ratchet(23.1, 22.1, tier: .cleanExtrapolated), false,
                    "棘轮: Spotify 干净外推源不适用")
    }

    // ---- BrowserPositionProbe:解析逻辑 ----
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
        // 别让 JS 直接 return JSON.stringify(...):`execute … javascript` 会把返回
        // 字符串里已有的双引号**真的**转义成反斜杠字符(不是打印时的显示转义),等于整段
        // JSON 被二次转义,解析会静默出错而不是干脆地失败。固定住裸文本竖线分隔、不含任何
        // 引号的格式绝不会撞上这个坑,并且钉住一条"就算某处不小心传回带引号的 JSON 残留,
        // 也不能被误判成合法数据"的回归用例。
        expectEqual(P.parseSeconds(fromOsascriptOutput: "\"{\\\"found\\\":true,\\\"seconds\\\":168}\""),
                    nil, "浏览器探针解析: 万一混进 JSON 残留也不能误判成合法数据(2026-08-30 回归)")
    }

    // ---- MV 时间轴:探针第五段 / SponsorBlock 片段 / 换算 ----
    // 数据取自真机与接口实测(见 02 章决策 50)。
    do {
        typealias P = BrowserPositionProbe
        typealias T = MusicVideoTimeline
        let omv = P.VideoIdentity(videoID: "e-ORhEE9VVg", musicVideoType: "MUSIC_VIDEO_TYPE_OMV")
        expectEqual(P.parseReading(fromOsascriptOutput: "57|0|||#e-ORhEE9VVg,MUSIC_VIDEO_TYPE_OMV")?.video, omv,
                    "MV 探针: 第五段解析出 videoId 与类型")
        let withPrecise = P.parseReading(fromOsascriptOutput: "57|0||@57.123,1790000000000|#e-ORhEE9VVg,MUSIC_VIDEO_TYPE_OMV")
        expectEqual(withPrecise?.video, omv, "MV 探针: 带精确读数时第五段照样解析")
        expectEqual(withPrecise?.precise != nil, true, "MV 探针: 第五段不影响第四段")
        expectEqual(P.parseReading(fromOsascriptOutput: "57|0||")?.video, nil, "MV 探针: 旧格式没有第五段")
        expectEqual(P.parseReading(fromOsascriptOutput: "57|0|||")?.video, nil, "MV 探针: 第五段为空")
        expectEqual(P.parseReading(fromOsascriptOutput: "57|0|||#short,MUSIC_VIDEO_TYPE_OMV")?.video, nil,
                    "MV 探针: videoId 不是 11 位就整段作废")
        expectEqual(P.parseReading(fromOsascriptOutput: "57|0|||#e-ORhEE9VVg,")?.video?.musicVideoType, nil,
                    "MV 探针: 类型读不到时为 nil")
        expectEqual(P.parseReading(fromOsascriptOutput: "57|1|||#e-ORhEE9VVg,MUSIC_VIDEO_TYPE_OMV"), nil,
                    "MV 探针: 暂停中整条不采信")

        expectEqual(T.isMusicVideoType("MUSIC_VIDEO_TYPE_OMV"), true, "MV 类型: 官方 MV")
        expectEqual(T.isMusicVideoType("MUSIC_VIDEO_TYPE_UGC"), true, "MV 类型: 用户上传")
        expectEqual(T.isMusicVideoType("MUSIC_VIDEO_TYPE_ATV"), false, "MV 类型: 歌曲版不算")
        expectEqual(T.isMusicVideoType(nil), false, "MV 类型: 读不到不算")

        // 专辑位写「MV」用的那一位:Apple Music 的 JXA 快照带 isMusicVideo,按曲目记住。
        let decode = { (json: String) in try? JSONDecoder().decode(MediaControlSnapshot.self, from: Data(json.utf8)) }
        expectEqual(decode(#"{"title":"黑白","artist":"方大同","album":"","isMusicVideo":true}"#)?.isMusicVideo, true,
                    "MV 标记: JXA 快照里的 isMusicVideo 解得出来")
        expectEqual(decode(#"{"title":"黑白","artist":"方大同","album":""}"#)?.isMusicVideo, nil,
                    "MV 标记: media-control 载荷没有这一位")
        let L = LocalPlaybackSource.self
        expectEqual(L.musicVideoTrackKey(previous: nil, currentKey: "BTS|SWIM", markedMusicVideo: true), "BTS|SWIM",
                    "MV 标记: 这一拍认出来就记下")
        expectEqual(L.musicVideoTrackKey(previous: "BTS|SWIM", currentKey: "BTS|SWIM", markedMusicVideo: false), "BTS|SWIM",
                    "MV 标记: 同一首后面几拍没带这一位(Apple Music 暂停不走 JXA)仍然是 MV")
        expectEqual(L.musicVideoTrackKey(previous: "BTS|SWIM", currentKey: "TWICE|THIS IS FOR", markedMusicVideo: false), nil,
                    "MV 标记: 换歌作废")
        expectEqual(L.musicVideoTrackKey(previous: nil, currentKey: "TWICE|THIS IS FOR", markedMusicVideo: false), nil,
                    "MV 标记: 普通歌不是 MV")

        // 《Blank Space》MV:片头 0–3.112、片尾 233.808–272.441,歌曲版 231 秒。
        let blank = T.make(cuts: [.init(start: 0, end: 3.112), .init(start: 233.808, end: 272.441)],
                           videoDurationSecs: 272.441, songDurationSecs: 231)
        expectEqual(blank?.isComplete, true, "MV 时间轴: 标全的 MV 用上全部片段")
        expectEqual(blank?.offsetMs(atVideoMs: 0), -3112, "MV 时间轴: 片头里就整首扣掉片头")
        expectEqual(blank?.offsetMs(atVideoMs: 100_000), -3112, "MV 时间轴: 正片里扣片头")
        expectEqual(blank?.offsetMs(atVideoMs: 250_000), -3112, "MV 时间轴: 走进片尾不再停(已在最后一句之后)")
        // 《Blinding Lights》MV 剪完 219 秒、歌曲版 200 秒:检查不过,只扣片头。
        let blinding = T.make(cuts: [.init(start: 0, end: 23.1), .init(start: 241.7, end: 262.5)],
                              videoDurationSecs: 263, songDurationSecs: 200)
        expectEqual(blinding?.isComplete, false, "MV 时间轴: 剪完与歌曲版差太多时不用全部片段")
        expectEqual(blinding?.offsetMs(atVideoMs: 100_000), -23100, "MV 时间轴: 检查不过仍扣片头")
        // 还不知道歌曲版时长(歌词判决没出来):先只扣片头,《Super Shy》MV 片头 41.4 秒。
        let early = T.make(cuts: [.init(start: 0, end: 41.4), .init(start: 195.4, end: 200.8)],
                           videoDurationSecs: 200.9, songDurationSecs: nil)
        expectEqual(early?.isComplete, false, "MV 时间轴: 不知道歌曲版时长时先只扣片头")
        expectEqual(early?.offsetMs(atVideoMs: 10_000), -41400, "MV 时间轴: 片头先行,不等判决")
        // 《Royals》MV 只标了片尾、检查也不过:没有片头可扣 → 不启用。
        expectEqual(T.make(cuts: [.init(start: 199.2, end: 200.1)], videoDurationSecs: 201, songDurationSecs: 190.2) == nil, true,
                    "MV 时间轴: 只标片尾且检查不过时不启用")
        expectEqual(T.make(cuts: [], videoDurationSecs: 245, songDurationSecs: 231) == nil, true,
                    "MV 时间轴: 没有片段不启用")
        // BTS《SWIM》MV(b4iVv91Z6lY,244.221 秒):片头 + 中间插段 + 片尾,歌曲版 159 秒。剪完 155.85 秒,差 3.15 超过容差,
        // 但片尾 49.8 秒盖住的歌曲尾音在弹性区间 [152.85, 208.65] 里 → 全部启用,2:12 之后连插段一起扣。
        let swim = T.make(cuts: [.init(start: 0, end: 29.414), .init(start: 122.663, end: 131.823),
                                 .init(start: 194.424, end: 244.221)],
                          videoDurationSecs: 244.221, songDurationSecs: 159)
        expectEqual(swim?.isComplete, true, "MV 时间轴: 片尾盖住歌曲尾音时放宽,片头 + 插段全部启用")
        expectEqual(swim?.offsetMs(atVideoMs: 140_000), -38574, "MV 时间轴: 插段之后片头 + 插段一起扣(29.414 + 9.16)")
        // 反方向不放宽:剪完比歌曲版长出容差以上(片段没标全),即使有片尾也只扣片头。
        let longer = T.make(cuts: [.init(start: 0, end: 29.414), .init(start: 194.424, end: 244.221)],
                            videoDurationSecs: 244.221, songDurationSecs: 159)
        expectEqual(longer?.isComplete, false, "MV 时间轴: 剪完比歌曲版长出容差以上时照旧只扣片头")
        // 没有片尾时 trailing = 0,退回 ±3 秒:差 3.15 不过、差 2.9 过。
        let noTailFail = T.make(cuts: [.init(start: 0, end: 10), .init(start: 100, end: 110)],
                                videoDurationSecs: 240, songDurationSecs: 216.85)
        expectEqual(noTailFail?.isComplete, false, "MV 时间轴: 没有片尾时差 3.15 秒不放宽")
        let noTailPass = T.make(cuts: [.init(start: 0, end: 10), .init(start: 100, end: 110)],
                                videoDurationSecs: 240, songDurationSecs: 217.1)
        expectEqual(noTailPass?.isComplete, true, "MV 时间轴: 没有片尾时差 2.9 秒照旧通过")
        // 中间插段:进去之后停住,出来整段扣掉。
        let interlude = T.make(cuts: [.init(start: 0, end: 5), .init(start: 100, end: 110)],
                               videoDurationSecs: 245, songDurationSecs: 230)
        expectEqual(interlude?.offsetMs(atVideoMs: 50_000), -5000, "MV 时间轴: 插段之前只扣片头")
        expectEqual(interlude?.offsetMs(atVideoMs: 105_000), -10000, "MV 时间轴: 插段里歌词停在插段开始那一刻")
        expectEqual(interlude?.offsetMs(atVideoMs: 120_000), -15000, "MV 时间轴: 插段之后整段扣掉")
        // Tame Impala MV 的重叠片段合并。
        expectEqual(T.merged([.init(start: 0, end: 78.5), .init(start: 0, end: 1.2), .init(start: 294.8, end: 342.8)],
                             videoDurationSecs: 343).count, 2, "MV 时间轴: 重叠片段合并")
        // 片段起点差零点几秒也按片头处理(《One More Time》MV 的 [0, 0.6] 那类)。
        let nearZero = T.make(cuts: [.init(start: 0.6, end: 3)], videoDurationSecs: 233, songDurationSecs: 230)
        expectEqual(nearZero?.offsetMs(atVideoMs: 1000), -2400, "MV 时间轴: 起点在 1 秒内按片头处理")

        // 歌曲版时长:优先取显示的那份歌词的来源,否则取中位数(《黑白》的真实候选)。
        let record: [String: Any] = ["latest": ["candidates": [
            ["source": "kugou", "source_reported_duration_secs": 231],
            ["source": "netease", "source_reported_duration_secs": 231.613],
            ["source": "qq", "source_reported_duration_secs": 231],
        ]]]
        expectEqual(T.songDurationSecs(fromDecisionRecord: record, lyricsSource: "netease"), 231.613,
                    "MV 歌曲时长: 取显示的那份歌词的来源")
        expectEqual(T.songDurationSecs(fromDecisionRecord: record, lyricsSource: nil), 231,
                    "MV 歌曲时长: 来源对不上时取中位数")
        expectEqual(T.songDurationSecs(fromDecisionRecord: [:], lyricsSource: "kugou"), nil,
                    "MV 歌曲时长: 没有候选明细")

        // 总偏移为负时前奏窗口从播放位置 0 对应的歌词时间算起,不然 MV 片头那段会落到兜底的「♪」。
        do {
            let yrc = "[2000,1000](2000,500,0)aa (2500,500,0)bb \n"
                + "[6000,1000](6000,500,0)cc (6500,500,0)dd \n"
            let engine = LyricsSyncEngine()
            engine.load(lyrics: "", lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc)
            engine.offsetMs = -41400
            expectEqual(engine.rawActiveGapWindow(atMs: 0), LyricsGapWindow(startMs: -41400, endMs: 2000),
                        "MV 前奏: 负偏移下前奏窗口从视频开头就接住")
            expectEqual(engine.rawActiveGapWindow(atMs: 30_000) != nil, true, "MV 前奏: 片头中段仍在前奏窗口里")
            expectEqual(engine.gapMarkers().first?.index, -1, "MV 前奏: 前奏按实际长度过门槛,歌词窗口也标前奏点")
            engine.offsetMs = 0
            expectEqual(engine.rawActiveGapWindow(atMs: 500)?.startMs, 0, "MV 前奏: 偏移为 0 时前奏起点仍是 0")
        }

        typealias S = SponsorBlockSegments
        expectEqual(S.hashPrefix(forVideoID: "e-ORhEE9VVg"), "037d", "SponsorBlock: 哈希前缀(接口实测值)")
        let url = S.requestURL(forVideoID: "e-ORhEE9VVg")?.absoluteString ?? ""
        expectEqual(url.contains("/api/skipSegments/037d?"), true, "SponsorBlock: 走哈希前缀接口,不带 videoID")
        expectEqual(url.contains("e-ORhEE9VVg"), false, "SponsorBlock: 请求里不出现 videoID")
        let body = Data("""
        [{"videoID":"zzzzzzzzzzz","segments":[{"category":"music_offtopic","actionType":"skip","segment":[0,9],"videoDuration":100}]},
         {"videoID":"e-ORhEE9VVg","segments":[
           {"category":"music_offtopic","actionType":"skip","segment":[0,3.112],"videoDuration":272.441,"locked":1},
           {"category":"sponsor","actionType":"skip","segment":[10,20],"videoDuration":272.441},
           {"category":"music_offtopic","actionType":"skip","segment":[233.808,272.441],"videoDuration":272.441,"locked":1}]}]
        """.utf8)
        let parsed = S.parse(body, videoID: "e-ORhEE9VVg")
        expectEqual(parsed?.cuts.count, 2, "SponsorBlock: 只取自己那支的 music_offtopic 片段")
        expectEqual(parsed?.videoDurationSecs, 272.441, "SponsorBlock: 带回视频时长")
        expectEqual(S.parse(body, videoID: "3UlcSiBruxg")?.cuts.isEmpty, true, "SponsorBlock: 前缀下没有自己那支 = 没有标注")
        expectEqual(S.parse(Data("oops".utf8), videoID: "e-ORhEE9VVg") == nil, true, "SponsorBlock: 形状不对返回 nil")
    }

    // ---- BrowserPositionProbe:平台与浏览器配对门禁 ----
    // 只测"没配对就不探测"这道门禁本身——它在 kickIfNeeded 内部、发起任何 AppleScript
    // 调用之前就短路返回,不依赖真实 Arc,能在 CI/无 GUI 环境里稳定跑。真正的探测行为
    // (配对过之后)依赖真实浏览器,已手动验证过(见该文件头注)。
    do {
        expectEqual(BrowserPositionProbe.supportedPlatforms.contains { $0.id == "youtubeMusic" }, true,
                    "浏览器歌词同步: YouTube Music 在受支持平台列表里")
        expectEqual(BrowserPositionProbe.supportedPlatforms.contains { $0.id == "spotifyWeb" }, true,
                    "浏览器歌词同步: Spotify 网页版在受支持平台列表里")
        // **滚轮兜底转发的判定必须能被同一次手势复用**(真机 sample 抓栈坐实)。
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
        // **读到"错的标签页"要被挡住,但判据不能拿 MediaRemote 的位置当参照物。**
        //
        // **把参照物写死成一个常数的用例,证明不了任何跟参照物有关的判据** —— 它只是把
        // 写用例时的那个假设复述了一遍(跟"用同一假设写的单测自证阈值"是同一个坑)。下面
        // 这些用例的 first/second 都是真实会变化的读数,不固定参照值。
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
        // 采样间隔必须**大于**读数本身的量化步长(整秒),否则"没前进"分不出是钟停了
        // 还是还没跨过整秒边界 —— 这条一破,活性判据就退化成随机噪声。
        expectEqual(BrowserPositionProbe.livenessGapSeconds > 1.0, true,
                    "探针活性: 采样间隔必须大于整秒读数的量化步长")
        // 有界重试:瞬时失败(页面缓冲/后台标签页节流)要有第二次机会,但不能整首歌每轮都
        // 去 tell 一遍浏览器。
        expectEqual(BrowserPositionProbe.maxProbeAttempts >= 2, true,
                    "探针重试: 至少要给瞬时失败一次重试机会")
        expectEqual(BrowserPositionProbe.probeRetryBackoffSecs > BrowserPositionProbe.livenessGapSeconds, true,
                    "探针重试: 退避必须比一次探测本身(两次采样+间隔)更长")
        // 广告是这套判据**认不出来**的那一类,靠时长对不上兜:YouTube Music 插广告时页面那
        // 行进度文字是**广告自己的**,而且**是在走的** —— `pageClockIsRunning` 对它一路放行。
        // 容差必须留得住"页面显示 floor(总时长)、MediaRemote 给小数"这点固有差(实测
        // duration=218.781 对页面 3:38=218),又不能大到把一首歌和一段广告混为一谈。
        expectEqual(BrowserPositionProbe.pageDurationToleranceSecs >= 1
                    && BrowserPositionProbe.pageDurationToleranceSecs <= 5, true,
                    "探针同曲判据: 时长容差要够吃下 floor 偏置又不至于放过广告")
        // **一次性地面真值不能走周期性噪声源那套 EMA 闸门**(真机日志坐实的 bug)。
        // 探针每首歌只给一个样本,而 servoDecision 对 noisyFloored 是 alpha 0.3 / 门槛 1.0 ——
        // 单样本最多把 EMA 推到 0.3×误差,要误差 >3.33s 才可能触发。实测这档偏差是 0.7~0.9s,
        // 于是纠偏连着三首歌全部 snap=false。这两条断言把"为什么必须另开一条路径"钉住。
        expectEqual(LocalPlaybackSource.servoDecision(errEMA: 0, error: -0.7, tier: .noisyFloored).snap,
                    false, "伺服: 单个 -0.7s 样本进不了 noisyFloored 的 EMA 门槛")
        expectEqual(0.7 > LocalPlaybackSource.groundTruthSnapToleranceSecs, true,
                    "探针重锚: 0.30s 门槛必须接得住实测那档 0.7s 偏差")
        // 拖动刚发出去的 1.2s 内,读数更靠近拖动前的位置 = 播放器还没跟上,这一份整份丢弃;
        // 靠近目标、正好居中、窗口外、时钟倒退都照常采信(居中丢了反而卡住自愈)。
        do {
            let reject = LocalPlaybackSource.shouldRejectStalePositionAfterSeek
            expectEqual(reject(60.8, 120, 60, 0.5), true, "拖动后陈旧读数: 窗口内、还在旧位置附近 → 丢")
            expectEqual(reject(120.3, 120, 60, 0.5), false, "拖动后陈旧读数: 已到目标附近 → 收")
            expectEqual(reject(90, 120, 60, 0.5), false, "拖动后陈旧读数: 正好居中 → 收")
            expectEqual(reject(60.8, 120, 60, LocalPlaybackSource.seekSettleWindow - 0.01), true, "拖动后陈旧读数: 窗口末尾仍丢")
            expectEqual(reject(60.8, 120, 60, LocalPlaybackSource.seekSettleWindow), false, "拖动后陈旧读数: 过了 1.2s 窗口 → 收")
            expectEqual(reject(60.8, 120, 60, -0.1), false, "拖动后陈旧读数: 时钟倒退(拖动时刻在未来)→ 收")
            expectEqual(reject(10.2, 10, 130, 0.3), false, "拖动后陈旧读数: 往回拖到开头、读数已跟上 → 收")
        }
        expectEqual(BrowserPositionProbe.flooredMidpointBiasSecs, 0.5,
                    "探针读数: 页面是 floor,取区间中点才无偏(实测 elapsed=165.627 → 页面 165)")
        // YouTube Music 第四段:`currentTime,epochMs`。样本是 Safari 真机读数(文字 0:45、currentTime 45.810)。
        let preciseReading = BrowserPositionProbe.parseReading(fromOsascriptOutput: "\"45|0||@45.810,1790235032042\"")
        expectEqual(preciseReading?.seconds, 45, "探针精确读数: 整秒段照旧")
        expectEqual(preciseReading?.precise?.seconds, 45.81, "探针精确读数: 第四段是 currentTime")
        expectEqual(preciseReading?.precise.map { abs($0.readAt.timeIntervalSince1970 - 1790235032.042) < 0.0005 }, true,
                    "探针精确读数: 读数时刻取 JS 的 Date.now(毫秒)")
        expectEqual(BrowserPositionProbe.parseReading(fromOsascriptOutput: "45|0||")?.precise, nil,
                    "探针精确读数: 第四段为空(currentTime 对不上文字)时只有整秒读数")
        expectEqual(BrowserPositionProbe.parseReading(fromOsascriptOutput: "45|0||")?.seconds, 45,
                    "探针精确读数: 第四段为空时整秒读数仍成立")
        expectEqual(BrowserPositionProbe.parseReading(fromOsascriptOutput: "45|0||@45.8")?.precise, nil,
                    "探针精确读数: 缺时间戳当没有")
        expectEqual(BrowserPositionProbe.parseReading(fromOsascriptOutput: "45|0||@x,y")?.precise, nil,
                    "探针精确读数: 不是数字当没有")
        expectEqual(BrowserPositionProbe.parseReading(fromOsascriptOutput: "160|0||160.812,1790235032042")?.precise, nil,
                    "探针精确读数: 缺 @ 前缀当没有(AppleScript 会把 ||1… 误认成暂停)")
        // AppleScript 那层认暂停的判据是 `r does not contain "|1"`:以 1 开头的精确读数不能撞上它。
        expectEqual("160|0||@160.812,1790235032042".contains("|1"), false,
                    "探针精确读数: 播放中的输出不含 |1(真机撞过:160s 起的读数全被当成暂停)")
        expectEqual(BrowserPositionProbe.parseReading(fromOsascriptOutput: "45|1||@45.810,1790235032042") == nil, true,
                    "探针精确读数: 暂停的读数整条不要")
        // currentTime 窗口:正常领先 < 1.05s(文字 floor + 渲染滞后 ≤0.05s),电台累计时间(516 对 243)远在窗口外。
        expectEqual(45.810 - 45 < BrowserPositionProbe.currentTimeSlackSecs, true, "探针精确读数: 真机样本落在窗口内")
        expectEqual(BrowserPositionProbe.currentTimeSlackSecs >= 1.05, true, "探针精确读数: 窗口吃得下 floor + 渲染滞后")
        expectEqual(516.0 - 243 < BrowserPositionProbe.currentTimeSlackSecs, false, "探针精确读数: 电台累计时间挡在窗口外")
        // 精确读数的门槛要接得住 Safari 起播卡顿(实测恢复锚点比页面钟超前 0.36s),又不能小于两边钟的实测差(0.001s)。
        expectEqual(0.36 > BrowserPositionProbe.preciseSnapToleranceSecs, true, "探针精确读数: 门槛接得住 0.36s 起播卡顿")
        // Safari 上整秒读数不用:后台标签页的文字两秒一刷、晚 2~3s(Spotify 网页版真机:纠偏 −0.557 / −1.168,
        // 扣掉探针这一步暂停残差只有 −0.03)。别的浏览器照旧(Chrome / Arc 的锚点会冻在会话创建时刻)。
        expectEqual(BrowserPositionProbe.floorReadingApplies(reportedBundleID: "com.apple.WebKit.GPU"), false,
                    "网页探针整秒读数: Safari 媒体进程不用")
        expectEqual(BrowserPositionProbe.floorReadingApplies(reportedBundleID: "com.google.Chrome"), true,
                    "网页探针整秒读数: Chrome 照旧用")
        expectEqual(BrowserPositionProbe.floorReadingApplies(reportedBundleID: "company.thebrowser.Browser"), true,
                    "网页探针整秒读数: Arc 照旧用")
        // 读到的时刻只给实测过的播放器盖(决策 41):酷狗、Safari 的媒体进程;别家照旧按处理时刻算。
        expectEqual(MediaControlClient.stampsCaptureTime(bundleID: "com.apple.WebKit.GPU"), true, "读数时刻: Safari 媒体进程盖")
        expectEqual(MediaControlClient.stampsCaptureTime(bundleID: PlaybackPlayer.kugou.bundleIdentifier), true, "读数时刻: 酷狗盖")
        expectEqual(MediaControlClient.stampsCaptureTime(bundleID: "com.google.Chrome"), false, "读数时刻: Chrome 没量过不盖")
        expectEqual(MediaControlClient.stampsCaptureTime(bundleID: PlaybackPlayer.soda.bundleIdentifier), false, "读数时刻: 汽水不盖")
        expectEqual(BrowserPositionProbe.preciseSnapToleranceSecs < LocalPlaybackSource.groundTruthSnapToleranceSecs, true,
                    "探针精确读数: 门槛比整秒读数那档紧")
        // **Safari 的媒体代理进程要被解析成宿主**,否则探针对 Safari 一次都不会出手
        // (MediaRemote 报 com.apple.WebKit.GPU,而配对表和 AppleScript 认的是 com.apple.Safari)。
        expectEqual(BrowserPositionProbe.probeTargetBundleID(forReported: "com.apple.WebKit.GPU"),
                    "com.apple.Safari", "浏览器歌词同步: WebKit.GPU 解析成 Safari 宿主")
        expectEqual(BrowserPositionProbe.probeTargetBundleID(forReported: "company.thebrowser.Browser"),
                    "company.thebrowser.Browser", "浏览器歌词同步: 非代理进程原样返回")
        expectEqual(BrowserPositionProbe.probeTargetBundleID(forReported: nil), nil,
                    "浏览器歌词同步: nil 原样返回")
        // **每个摆出来的平台都必须真有一条站点规则**,反之亦然。对不上不会编译报错,只表现成
        // "卡片在、配对得上、却永远不探测"。
        expectEqual(BrowserPositionProbe.platformIDsWithSiteRules,
                    Set(BrowserPositionProbe.supportedPlatforms.map(\.id)),
                    "浏览器歌词同步: 受支持平台与站点规则一一对应")
        // 平台 id 必须唯一:`platformBrowserPairs` 用它当键,撞了就是两个平台共用一份配对。
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
        // 探测改成"两次采样 + 中间等 `livenessGapSeconds`"之后这 2 秒仍然够:
        // 这个用例把配对表清空了,门禁**万一**失效,`probeOnce` 也会因为没有任何规则匹配得上
        // 而立刻返回 nil、根本走不到那次等待。盖不住的只有"门禁失效**且**真有配对"的组合,
        // 而那不是这条用例要证明的东西。
        Thread.sleep(forTimeInterval: 2.0)
        expectEqual(probe.consumeCorrection(forKey: key, rate: 1, now: Date()), nil,
                    "浏览器歌词同步: 没配对任何平台时 kickIfNeeded 不应该发起探测")
        probe.trackChanged()
        probe.platformBrowserPairs = [:]
        // Spotify 网页版广告识别:LocalPlaybackSource
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

    // ---- 来源角标:浏览器在放哪个网页音乐平台 ----
    //
    // "这里显示 youtubemusic,如果确实是 youtube music 的情况下,不再显示浏览器;
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
        //    配置(一个浏览器只配一个平台),也是这台机器上 Edge/Chrome 的形状 —— 对拍
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

        // ⑤ 旧证据必须**仍在配对表里**才作数:用户后来取消配对了,探测就不跑了、那条旧
        //    证据再也刷新不掉 —— 认它的话角标会永远挂着一个已经被取消的平台。
        expectEqual(P.resolvePlayingPlatformID(pairedPlatformIDs: ["spotifyWeb"],
                                               recentMatch: "youtubeMusic"),
                    "spotifyWeb", "来源角标: 命中的平台已被取消配对 → 证据作废,退回单配对推断")
        expectEqual(P.resolvePlayingPlatformID(pairedPlatformIDs: [], recentMatch: "youtubeMusic"),
                    nil, "来源角标: 全部取消配对后旧证据也不作数")

        // ⑤b 暂停时认平台(identifyIfNeeded):哪个平台的标签页报的 mediaSession 标题就是当前这首。
        //    Safari 里 YouTube Music 停在《Standing Next to You》、Spotify 网页版停在另一首 —— 角标原来画成 Safari。
        let ytm = P.PageTitle(platformID: "youtubeMusic", title: "Standing Next to You (Usher Remix)")
        let spo = P.PageTitle(platformID: "spotifyWeb", title: "Chicken Fried")
        expectEqual(P.platformMatchingTitle("Standing Next to You (Usher Remix)", pages: [ytm, spo]),
                    "youtubeMusic", "来源角标: 暂停时按页面标题认出 YouTube Music")
        expectEqual(P.platformMatchingTitle("Chicken Fried", pages: [ytm, spo]),
                    "spotifyWeb", "来源角标: 暂停时按页面标题认出 Spotify 网页版")
        expectEqual(P.platformMatchingTitle("  standing next to you (usher remix) ", pages: [ytm]),
                    "youtubeMusic", "来源角标: 标题比较忽略首尾空白和大小写")
        expectEqual(P.platformMatchingTitle("Say \"Hi\"", pages: [P.PageTitle(platformID: "spotifyWeb", title: "Say \\\"Hi\\\"")]),
                    "spotifyWeb", "来源角标: execute javascript 转义出来的反斜杠不影响比较")
        expectEqual(P.platformMatchingTitle("Standing Next to You", pages: [ytm, spo]), nil,
                    "来源角标: 只是前缀对得上不算(要的是就是这首)")
        expectEqual(P.platformMatchingTitle("Chicken Fried",
                                            pages: [spo, P.PageTitle(platformID: "youtubeMusic", title: "Chicken Fried")]),
                    nil, "来源角标: 两个平台都开着这首 → 不下结论")
        expectEqual(P.platformMatchingTitle("", pages: [ytm]), nil, "来源角标: 当前标题为空 → 不下结论")
        expectEqual(P.parseIdentifyOutput("youtubeMusic:A: B\nspotifyWeb:\n\nspotifyWeb:C\n"),
                    [P.PageTitle(platformID: "youtubeMusic", title: "A: B"), P.PageTitle(platformID: "spotifyWeb", title: "C")],
                    "来源角标: 解析认平台输出(标题里的冒号保留、空标题丢掉)")

        // ⑥ 契约:第 ② 档能推断出来的平台一定得画得出图标。图标那一侧(`WebPlatformIcon`)
        //    在 app target、这里够不着,只钉 id 集合这一半 —— 新增平台时这条会红,提醒去补
        //    站点规则和图标(两处对不上不会编译报错,只表现成"角标位空着")。
        expectEqual(Set(P.supportedPlatforms.map(\.id)), both,
                    "来源角标: 支持的平台就是这两个(新增时这条红,提醒补站点规则与图标)")

        // ⑦ 契约:「点角标跳到正在放歌的那枚标签页」的接线。此前网页平台只激活整个浏览器
        //    —— 歌就在那个浏览器里放、浏览器多半已是前台,激活一次等于没反应。现在网页平台
        //    先翻标签页(revealPlayingTab,URL 判据与进度探测同一份 siteRules),翻不到退回
        //    整 App 激活。翻页脚本本体是真 AppleScript、selftest 够不着,只能钉接线与两种
        //    方言的关键行。
        let sourcesRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        func src(_ path: String) -> String {
            (try? String(contentsOf: sourcesRoot.appendingPathComponent(path), encoding: .utf8)) ?? ""
        }
        let probeSrc = src("LyrimuseCore/Local/BrowserPositionProbe.swift")
        let coordinatorSrc = src("lyrimuse/PlaybackCoordinator.swift")
        let panelSrc = src("lyrimuse/MenuBar/MenuBarPanel.swift")
        let windowSrc = src("lyrimuse/UI/LyricsWindowView.swift")
        expectEqual(probeSrc.contains("set active tab index of window wi to ti")
                    && probeSrc.contains("set current tab of window wi to tab ti of window wi"), true,
                    "来源角标(契约): 翻标签页的两种方言(Chromium active tab index / Safari current tab)都在")
        expectEqual(coordinatorSrc.contains("revealPlayingTab(bundleID: id, platformID: platformID)")
                    && coordinatorSrc.contains("self?.openResolvedPlayerApp()"), true,
                    "来源角标(契约): 网页平台先翻标签页,翻不到退回整 App 激活")
        expectEqual(panelSrc.contains("openResolvedPlayer()")
                    && windowSrc.contains("openResolvedPlayer()"), true,
                    "来源角标(契约): 菜单栏角标与歌词窗口「在 XX 中显示」都走统一入口")
        // Safari 上报 com.apple.WebKit.GPU:翻标签页和整 App 激活两条路都得先折回宿主,
        // 漏任一处,点 Safari 里的 YouTube Music 角标就毫无反应。
        expectEqual(probeSrc.contains("guard let host = probeTargetBundleID(forReported: bundleID),\n              let rule = siteRules.first(where: { $0.platformID == platformID })")
                    && coordinatorSrc.contains("guard let id = BrowserPositionProbe.probeTargetBundleID(\n            forReported: LocalPlaybackSource.shared.lastResolvedBundleID)"), true,
                    "来源角标(契约): 翻标签页与整 App 激活都按宿主(WebKit.GPU 到 Safari)")
    }

    // ---- 电台曲内时钟(RadioTrackClock)----
    // 实测:电台的 duration 与 elapsedTime 都是**整档节目**的,换歌不复位 —— 07:15:35 锚点归零,
    // 07:20:39 换到《Juna》,07:23:22 读到 467s(= 墙钟差),而曲内真值是 163s,偏 304 秒。
    // 系统没有单曲级位置可取,只能按"元数据换了"这一刻自己起表。
    do {
        typealias R = RadioTrackClock
        let t0 = Date(timeIntervalSince1970: 1_788_000_000)
        // 第一次见:归零。
        let first = R.advance(nil, trackKey: "Daniel Caesar|Who Knows", playing: true, now: t0)
        expectEqual(first.position, 0, "电台时钟: 第一次见这首歌从 0 起")
        expectEqual(first.trackKey, "Daniel Caesar|Who Knows", "电台时钟: 记住是哪首歌")
        // 播放中按墙钟累加。
        let t10 = R.advance(R.advance(first, trackKey: "Daniel Caesar|Who Knows", playing: true, now: t0.addingTimeInterval(5)),
                            trackKey: "Daniel Caesar|Who Knows", playing: true, now: t0.addingTimeInterval(10))
        expectEqual(t10.position, 10, "电台时钟: 播放中按墙钟走")
        // 换歌归零 —— 系统那块表恰恰不做这件事,这条就是整个改动的要害。
        let changed = R.advance(t10, trackKey: "Clairo|Juna", playing: true, now: t0.addingTimeInterval(11))
        expectEqual(changed.position, 0, "电台时钟: 换歌必须归零(系统的位置不复位,偏差就是从这来的)")
        // 暂停:上一拍还在播 → 那段算数(基本都在播);之后每一拍冻结。
        let played = R.advance(changed, trackKey: "Clairo|Juna", playing: true, now: t0.addingTimeInterval(21))
        expectEqual(played.position, 10, "电台时钟: 暂停前走了 10 秒")
        let pausing = R.advance(played, trackKey: "Clairo|Juna", playing: false, now: t0.addingTimeInterval(23))
        expectEqual(pausing.position, 12, "电台时钟: 以暂停收尾的那一段基本都在播,照算")
        let paused = R.advance(pausing, trackKey: "Clairo|Juna", playing: false, now: t0.addingTimeInterval(120))
        expectEqual(paused.position, 12, "电台时钟: 暂停期间位置冻结")
        // 回归守卫(现象是「暂停久一点再恢复,歌词进度就不正常」):恢复那一拍绝不能把整段
        // 暂停间隔算成播放时间。按"这一拍在播"累加的老写法在这里会跳到 109 —— 日志实测前跳 3.5~5.8 秒。
        let resumed = R.advance(paused, trackKey: "Clairo|Juna", playing: true, now: t0.addingTimeInterval(125))
        expectEqual(resumed.position, 12, "电台时钟: 恢复那一拍不把暂停那段算进来")
        let afterResume = R.advance(resumed, trackKey: "Clairo|Juna", playing: true, now: t0.addingTimeInterval(128))
        expectEqual(afterResume.position, 15, "电台时钟: 恢复之后照常走")
        // 单拍上限:休眠 / 长卡顿后墙钟差不再等于"播了多久"。
        let slept = R.advance(afterResume, trackKey: "Clairo|Juna", playing: true, now: t0.addingTimeInterval(128 + 7200))
        expectEqual(slept.position, 15 + R.maxAdvancePerTick, "电台时钟: 超长间隔按上限截断,不凭空跳一大截")
        // 时钟倒退(NTP 校时)不减位置。
        expectEqual(R.advance(slept, trackKey: "Clairo|Juna", playing: true, now: t0).position, slept.position,
                    "电台时钟: 墙钟倒退时位置不后退")
    }

    // ---- 起表时刻:用观察到换歌的那一刻,不是轮询那一拍(现象是「歌词进度偏慢」)----
    // 实测同一晚开台那次:锚点说播放头 0.000 是 23:18:22,标题到达事件流 23:18:23.425,App 应用新曲目
    // 23:18:23.816。老写法在应用那一拍归零 → 整首歌恒慢 1.8 秒。
    do {
        typealias R = RadioTrackClock
        typealias W = MediaControlStreamWatcher
        let t0 = Date(timeIntervalSince1970: 1_788_000_000)
        // seedPosition 的三个边界。
        expectEqual(R.seedPosition(startedAt: nil, now: t0), 0, "起表: 没有观察时刻就是 0(跟没这个参数时一样)")
        expectEqual(R.seedPosition(startedAt: t0.addingTimeInterval(5), now: t0), 0, "起表: 观察时刻在未来 → 0,不要负位置")
        expectEqual((R.seedPosition(startedAt: t0, now: t0.addingTimeInterval(1.43)) * 1000).rounded(), 1430,
                    "起表: 正常情况就是这段间隔")
        expectEqual(R.seedPosition(startedAt: t0, now: t0.addingTimeInterval(600)), R.maxStartSeed,
                    "起表: 错配的陈旧时刻要夹住,不能把位置推走几十秒")
        // 换歌那一拍按观察时刻播种;**同一首歌的后续拍不再重新播种**。
        let seeded = R.advance(nil, trackKey: "NCT 127|英雄", playing: true, now: t0.addingTimeInterval(1.816),
                               startedAt: t0.addingTimeInterval(0.999))
        expectEqual((seeded.position * 1000).rounded(), 817, "起表: 开台那次实测应播种 0.817 秒(老写法是 0)")
        let next = R.advance(seeded, trackKey: "NCT 127|英雄", playing: true, now: t0.addingTimeInterval(4.816),
                             startedAt: t0.addingTimeInterval(0.999))
        expectEqual((next.position * 1000).rounded(), 3817, "起表: 同一首歌后续拍只累加,不拿观察时刻再播种一次")
        // 报单曲位置的电台 + 歌曲过渡:新歌从 13 秒切进来,系统位置 262.5 → 13.0。
        expectEqual(R.perTrackSeed(systemPosition: 13.004, anchorAge: 0.07, previousPosition: 262.506), 13.004,
                    "单曲口径: 换歌时系统位置归零到小值 → 用它起表")
        expectEqual(R.perTrackSeed(systemPosition: 467, anchorAge: 0.07, previousPosition: 460), nil,
                    "单曲口径: 整档节目口径换歌不归零 → 不采信")
        expectEqual(R.perTrackSeed(systemPosition: 13, anchorAge: 0.07, previousPosition: nil), nil,
                    "单曲口径: 冷启动没有上一首读数、也不知道时长 → 不判")
        expectEqual(R.perTrackSeed(systemPosition: 0.423, anchorAge: 0.05, previousPosition: nil, reportedDuration: 255.181),
                    0.423, "单曲口径: 开台第一首没有上一首读数,系统报的时长是单曲量级 → 判成单曲位置")
        expectEqual(R.perTrackSeed(systemPosition: 33.4, anchorAge: 0.05, previousPosition: nil, reportedDuration: 3390.122),
                    nil, "单曲口径: 整档节目口径的台报的是整档时长 → 冷启动也不判")
        expectEqual(R.perTrackSeed(systemPosition: 0.4, anchorAge: 0.05, previousPosition: nil, reportedDuration: 0),
                    nil, "单曲口径: 时长为 0(直播流读不到)不算单曲量级")
        expectEqual(R.perTrackSeed(systemPosition: 13, anchorAge: 236, previousPosition: 262), nil,
                    "单曲口径: 陈旧锚点 → 不采信")
        expectEqual(R.perTrackSeed(systemPosition: 75, anchorAge: 0, previousPosition: 300), nil,
                    "单曲口径: 超过上限 → 不采信")
        expectEqual(R.perTrackSeed(systemPosition: 30, anchorAge: 0, previousPosition: 45), nil,
                    "单曲口径: 归零幅度不够 → 不采信")
        let perTrack = R.advance(seeded, trackKey: "MagnusTheMagnus|Area", playing: true,
                                 now: t0.addingTimeInterval(10), startedAt: t0.addingTimeInterval(9.4),
                                 perTrackSeed: 13.004)
        expectEqual(perTrack.position, 13.004, "单曲口径: 给了 perTrackSeed 就优先于观察时刻播种")
        expectEqual(perTrack.perTrack, true, "单曲口径: 用 perTrackSeed 起表就标 perTrack")
        expectEqual(seeded.perTrack, false, "单曲口径: 按观察时刻起表的不标 perTrack")
        let perTrackNext = R.advance(perTrack, trackKey: "MagnusTheMagnus|Area", playing: true,
                                     now: t0.addingTimeInterval(12), perTrackSeed: 99)
        expectEqual((perTrackNext.position * 1000).rounded(), 15004, "单曲口径: perTrackSeed 只在起表那一拍用")
        // 起播缓冲时系统连报几次 0,最后一个才是真起点:标了 perTrack 的那首跟着系统位置走,不按墙钟累加。
        let rebuffer = R.advance(perTrack, trackKey: "MagnusTheMagnus|Area", playing: true,
                                 now: t0.addingTimeInterval(14), systemPosition: 0)
        expectEqual(rebuffer.position, 0, "单曲口径: 同一首系统重报 0 → 跟着回到 0(不是墙钟累加的 17 秒)")
        expectEqual(rebuffer.perTrack, true, "单曲口径: perTrack 一直带到这首结束")
        let wall = R.advance(seeded, trackKey: "NCT 127|英雄", playing: true, now: t0.addingTimeInterval(6.816),
                             systemPosition: 400)
        expectEqual((wall.position * 1000).rounded(), 5817, "单曲口径: 没标 perTrack 的照旧按墙钟累加,不看系统位置")
        // 交叉渐入渐出:起表那一拍读到的是上一首的位置(没判成),半秒后调用方补给 perTrackSeed → 从这一拍起跟系统位置。
        let torn = R.advance(nil, trackKey: "橘子海|夏日漱石", playing: true, now: t0, startedAt: t0.addingTimeInterval(-0.5))
        expectEqual(torn.perTrack, false, "单曲口径: 起表那一拍没判成就先按观察时刻起表")
        let upgraded = R.advance(torn, trackKey: "橘子海|夏日漱石", playing: true, now: t0.addingTimeInterval(0.5),
                                 perTrackSeed: 6.566)
        expectEqual(upgraded.position, 6.566, "单曲口径: 同一首补判成单曲位置 → 改用系统位置")
        expectEqual(upgraded.perTrack, true, "单曲口径: 补判之后标 perTrack")
        // 换歌判定:空标题(切台/加载中实测会先吐几行只有 artist 的载荷)不算换歌。
        expectEqual(W.changedTrackKey(before: ["artist": "NCT 127", "title": "英雄"],
                                      after: ["artist": "NCT 127", "title": "Fact Check (不可思议)"]),
                    "NCT 127|Fact Check (不可思议)", "换歌判定: 标题变了就是换歌,给出新 key")
        expectEqual(W.changedTrackKey(before: ["artist": "NCT 127", "title": "英雄"],
                                      after: ["artist": "NCT 127", "title": "英雄"]),
                    nil, "换歌判定: 没变就不是换歌")
        expectEqual(W.changedTrackKey(before: ["artist": "周杰伦", "title": "说好的幸福呢"],
                                      after: ["artist": "NCT 127", "title": "  "]),
                    nil, "换歌判定: 空标题不算换歌(切台加载中的那几行)")
        // 换歌时刻:锚点刚打好就用锚点(带亚秒估计),陈旧锚点只能退回到达时刻。
        let ts = t0
        expectEqual(W.trackChangeInstant(anchorTimestamp: ts, tight: true, arrivedAt: ts.addingTimeInterval(1.425)),
                    ts.addingTimeInterval(0.999), "换歌时刻: 锚点新鲜就用锚点时刻(整秒的亚秒部分按既有估计法补)")
        expectEqual(W.trackChangeInstant(anchorTimestamp: ts, tight: false, arrivedAt: ts.addingTimeInterval(236.8)),
                    ts.addingTimeInterval(236.8),
                    "换歌时刻: 陈旧锚点(电台换歌实测 age 236s/487s)绝不能当换歌时刻,退回到达时刻")
        expectEqual(W.trackChangeInstant(anchorTimestamp: nil, tight: true, arrivedAt: ts.addingTimeInterval(3)),
                    ts.addingTimeInterval(3), "换歌时刻: 没有可解析的时间戳就用到达时刻")
    }

    // ---- 主持人说话那一段:越过真曲长就把歌词收掉----
    // 实测这个台两首歌之间多出 66~110 秒非歌曲内容,那段时间元数据还停在上一首。
    do {
        typealias R = RadioTrackClock
        expectEqual(R.passedTrackEnd(position: 300, durationSecs: nil), false,
                    "放完判定: 时长拿不到就一律 false —— 刚换曲时快照里还是整档节目那个大数")
        expectEqual(R.passedTrackEnd(position: 300, durationSecs: 0), false, "放完判定: 时长为 0 也不判")
        expectEqual(R.passedTrackEnd(position: 180, durationSecs: 184.653), false, "放完判定: 曲子还没放完")
        expectEqual(R.passedTrackEnd(position: 184.653 + R.tailGraceSecs, durationSecs: 184.653), false,
                    "放完判定: 余量之内不收(末句歌词通常结束得比曲长早)")
        expectEqual(R.passedTrackEnd(position: 184.653 + R.tailGraceSecs + 0.001, durationSecs: 184.653), true,
                    "放完判定: 越过曲长 + 余量才收")
    }

    // ---- 落盘副本:App 重启后把表接回去----
    // 实测两次装机都把当时那首歌打回 0 起 —— 《Step Up》已播 12.6s,新进程从 0.284s 起。
    do {
        typealias F = RadioClockFile
        let t0 = Date(timeIntervalSince1970: 1_788_000_000)
        func rec(_ key: String, _ pos: Double, _ at: Date, _ playing: Bool) -> RadioClockRecord {
            RadioClockRecord(trackKey: key, position: pos, tickedAtMs: Int64(at.timeIntervalSince1970 * 1000),
                             playing: playing)
        }
        let saved = rec("NCT 127|Step Up", 12.6, t0, true)
        // 编解码往返 + 键名(文件是给下一个进程读的,键名换了就是静默失效)。
        let data = try! F.encode(saved)
        expectEqual(String(data: data, encoding: .utf8),
                    "{\"playing\":true,\"position\":12.6,\"ticked_at_ms\":1788000000000,\"track_key\":\"NCT 127|Step Up\"}",
                    "落盘副本: 键名与顺序稳定(sortedKeys)")
        expectEqual(F.decode(data), saved, "落盘副本: 往返相等")
        expectEqual(F.decode(Data("not json".utf8)), nil, "落盘副本: 坏文件解不出来就当没有,不崩")
        // perTrack 只在为真时落键,旧文件(没有这个键)照旧能读;接回来时带上它,重启后那首歌仍以系统位置为准。
        let perTrackRec = RadioClockRecord(trackKey: "MagnusTheMagnus|Area", position: 40,
                                           tickedAtMs: Int64(t0.timeIntervalSince1970 * 1000), playing: true, perTrack: true)
        expectEqual(String(data: try! F.encode(perTrackRec), encoding: .utf8),
                    "{\"per_track\":true,\"playing\":true,\"position\":40,\"ticked_at_ms\":1788000000000,\"track_key\":\"MagnusTheMagnus|Area\"}",
                    "落盘副本: perTrack 落成 per_track")
        expectEqual(F.decode(data)?.perTrack, nil, "落盘副本: 没有 per_track 的旧文件读出来是 nil")
        expectEqual(F.shouldWrite(previous: rec("MagnusTheMagnus|Area", 3, t0, true), next: perTrackRec,
                                  now: t0.addingTimeInterval(1)), true,
                    "写盘: 补判成单曲位置那一拍立刻写(重启接回要带上它)")
        expectEqual(F.restorable(perTrackRec, trackKey: "MagnusTheMagnus|Area", now: t0.addingTimeInterval(8))?.perTrack,
                    true, "恢复: 接回时带上 perTrack")
        expectEqual(F.restorable(saved, trackKey: "NCT 127|Step Up", now: t0.addingTimeInterval(8))?.perTrack,
                    false, "恢复: 没标的记录接回来不是 perTrack")
        // 恢复判据三条。
        expectEqual(F.restorable(nil, trackKey: "NCT 127|Step Up", now: t0.addingTimeInterval(8)), nil,
                    "恢复: 没有记录就是没有")
        expectEqual(F.restorable(saved, trackKey: "NCT 127|Piñata", now: t0.addingTimeInterval(8)), nil,
                    "恢复: 曲目对不上不接(上一首的位置没有参考价值)")
        expectEqual(F.restorable(rec("NCT 127|Step Up", 12.6, t0, false), trackKey: "NCT 127|Step Up",
                                 now: t0.addingTimeInterval(8)), nil,
                    "恢复: 落盘那一刻没在播就不接(停着的那段不能算成播放时间)")
        expectEqual(F.restorable(saved, trackKey: "NCT 127|Step Up",
                                 now: t0.addingTimeInterval(F.maxRestoreGap + 1)), nil,
                    "恢复: 记录太老不接(多半已经不是这一次播放了)")
        expectEqual(F.restorable(saved, trackKey: "NCT 127|Step Up", now: t0.addingTimeInterval(-5)), nil,
                    "恢复: 记录来自未来(时钟毛刺)不接")
        let restored = F.restorable(saved, trackKey: "NCT 127|Step Up", now: t0.addingTimeInterval(8))
        expectEqual(restored?.position, 12.6, "恢复: 接回落盘时的位置")
        expectEqual(restored?.playing, true, "恢复: 接回时按'上一拍在播'算,后面那段追得上")
        // 接回去之后交给既有的 advance:8 秒装机时间照常补上,追赶量由 maxAdvancePerTick 夹住。
        let after = RadioTrackClock.advance(restored, trackKey: "NCT 127|Step Up", playing: true,
                                            now: t0.addingTimeInterval(8))
        expectEqual((after.position * 1000).rounded(), 20600, "恢复: 接回来 12.6 + 停机 8 秒 = 20.6(老写法这里是 0)")
        let longGap = RadioTrackClock.advance(
            F.restorable(rec("NCT 127|Step Up", 12.6, t0, true), trackKey: "NCT 127|Step Up",
                         now: t0.addingTimeInterval(50)),
            trackKey: "NCT 127|Step Up", playing: true, now: t0.addingTimeInterval(50))
        expectEqual(longGap.position, 12.6 + RadioTrackClock.maxAdvancePerTick,
                    "恢复: 停机久一点时追赶量按单拍上限夹住,宁可少算")
        // 什么时候写盘。
        expectEqual(F.shouldWrite(previous: nil, next: saved, now: t0), true, "写盘: 第一次无条件写")
        expectEqual(F.shouldWrite(previous: saved, next: rec("NCT 127|Piñata", 0, t0, true), now: t0), true,
                    "写盘: 换歌立刻写")
        expectEqual(F.shouldWrite(previous: saved, next: rec("NCT 127|Step Up", 14, t0, false), now: t0), true,
                    "写盘: 播放状态翻转立刻写(漏了它,下次恢复会把停着的那段算成播放)")
        expectEqual(F.shouldWrite(previous: saved, next: rec("NCT 127|Step Up", 14, t0, true),
                                  now: t0.addingTimeInterval(2)), false,
                    "写盘: 同一首歌平凡推进不必每拍刷盘")
        expectEqual(F.shouldWrite(previous: saved, next: rec("NCT 127|Step Up", 30, t0, true),
                                  now: t0.addingTimeInterval(F.minWriteInterval)), true,
                    "写盘: 隔够了就刷一次,免得记录太老恢复时被判据 2 挡掉")
    }

    // ---- 台卡:开台那一刻是唯一能拿到台名台标的时机----
    // 实测两次:23:18:15 → title 空 / artist `NCT 127`;09-11 00:26:50 → title 空 /
    // artist `petal radio`。09-10 早先还见过反过来的形态(title 是台名、artist 空)。
    // 口白期间系统一个字段都不变(抓了整段 61 秒坐实),所以只能靠这一刻记下来。
    do {
        typealias C = RadioStationCardFile
        let hash = "CgkIBRoF0aDTpxkQBA"
        expectEqual(C.stationName(isRadio: true, stationHash: hash, title: "", artist: "petal radio"),
                    "petal radio", "台卡: title 空 → artist 就是台名(实测形态)")
        expectEqual(C.stationName(isRadio: true, stationHash: hash, title: "YEONJUN", artist: ""),
                    "YEONJUN", "台卡: 反过来的形态同样认(2026-09-10 实测)")
        expectEqual(C.stationName(isRadio: true, stationHash: hash, title: "   ", artist: "petal radio"),
                    "petal radio", "台卡: 只有空白也算空")
        expectEqual(C.stationName(isRadio: true, stationHash: hash, title: "big feelings", artist: "Ariana Grande"),
                    nil, "台卡: 两个都在 = 真歌,不是台卡")
        expectEqual(C.stationName(isRadio: true, stationHash: hash, title: "", artist: ""),
                    nil, "台卡: 两个都空 = 加载中的空载荷,不是台卡")
        expectEqual(C.stationName(isRadio: false, stationHash: hash, title: "", artist: "petal radio"),
                    nil, "台卡: 不是电台就无所谓台卡")
        expectEqual(C.stationName(isRadio: true, stationHash: nil, title: "", artist: "petal radio"),
                    nil, "台卡: 没有台标哈希就分不了台,不认")
        expectEqual(C.stationName(isRadio: true, stationHash: hash, title: "",
                                  artist: String(repeating: "长", count: C.maxNameLength + 1)),
                    nil, "台卡: 长得离谱的不是台名(多半把一整段口播文案当台名了)")
        // 换台就作废。
        let card = RadioStationCard(stationHash: hash, name: "petal radio", artwork: Data([1, 2, 3]))
        expectEqual(C.card(card, forStation: hash)?.name, "petal radio", "台卡: 同一个台才拿得出来")
        expectEqual(C.card(card, forStation: "别的台"), nil, "台卡: 换台作废(旧台的名字扣在新台头上更糟)")
        expectEqual(C.card(card, forStation: nil), nil, "台卡: 已经不是电台了就别拿")
        expectEqual(C.card(nil, forStation: hash), nil, "台卡: 没抓到就是没抓到,界面退回原样")
    }

    // ---- 「只勾了 Apple Music」这条路上的电台探针----
    //
    // 那条路走纯 JXA,AppleScript 问 Music.app 要不到 radioStationHash(MediaRemote 独有的键),
    // 所以电台整层在这一种配置下曾经完全不生效 —— 判据本身一处 bundleID 都不认,这反而是唯一
    // 不生效的配置。补法是按曲目探一次 media-control:判据在同一个曲目 key 内不会翻转
    // (台卡、每首歌各是不同的 key;口白期间系统一个字段都不变、沿用上一首的 key,判据也确实
    // 还成立),所以缓存到 key 这一粒度就够,换歌才多一次 fork,不必 2 秒一次。
    do {
        typealias M = MediaControlClient
        expectEqual(M.radioProbeNeeded(cachedKey: nil, trackKey: "Clairo|Juna"), true,
                    "探针: 冷启动没探过就得探(否则开台第一首整首不生效)")
        expectEqual(M.radioProbeNeeded(cachedKey: "Clairo|Juna", trackKey: "Clairo|Juna"), false,
                    "探针: 同一首歌不必每拍都问 —— 这条路当初跳过 media-control 就是为了省这次往返")
        expectEqual(M.radioProbeNeeded(cachedKey: "Clairo|Juna", trackKey: "NCT 127|Step Up"), true,
                    "探针: 换歌要重探")
        expectEqual(M.radioProbeNeeded(cachedKey: "|petal radio", trackKey: "Clairo|Juna"), true,
                    "探针: 台卡→第一首歌是两个 key,同样要重探")
        expectEqual(M.radioProbeNeeded(cachedKey: "Clairo|Juna", trackKey: ""), true,
                    "探针: 空 key(载荷还没齐)跟已缓存的不是一回事,别拿旧结果顶上")
    }

    // ---- 焦点被别的 App 抢走时退回 AppleScript----
    //
    // MediaRemote 的「正在播放」是系统级的**单一焦点**,网页里一个 video 元素就能占走它。
    // 默认配置(.auto)下 Apple Music 的快照基座也是 media-control,所以焦点一被占,整条路
    // 原来直接 return nil、播放状态被全清 —— 而 Music.app 一直在放,AppleScript 一问就知道。
    // 坐实:本机 `np:unknownPlayerNotices` 里存着 Chrome 2 次、Edge 1 次、Arc 2 次,而那份
    // 记录有 6 秒稳定门槛,短于 6 秒的抢夺根本不记。
    //
    // 这一组钉的是**收敛性** —— 这条回退不会让"从不用 Apple Music 的人"白 fork osascript,
    // 也不会在 Music.app 真的退出之后没完没了地试。
    do {
        typealias M = MediaControlClient
        let am = PlaybackPlayer.appleMusic.bundleIdentifier

        let sp = PlaybackPlayer.spotify.bundleIdentifier

        // 哪些播放器有"绕开 media-control 直接问它自己"的通路。
        expectEqual(M.directQueryPlayer(forBundleID: am), .appleMusic, "直查名单: Apple Music 有 JXA 通路")
        expectEqual(M.directQueryPlayer(forBundleID: sp), .spotify, "直查名单: Spotify 有 JXA 通路")
        // 没有 AppleScript 字典的几家**也在名单里**:NowPlayingClientsProbe 是按 bundle id 直接
        // 问系统的,不挑播放器。它们只是少了 JXA 那一级兜底(见 snapshotAfterFocusLost 的两级顺序)。
        expectEqual(M.directQueryPlayer(forBundleID: "com.tencent.QQMusicMac"), .qqMusic,
                    "直查名单: QQ 音乐没有 AppleScript 字典,但探针按 bundle id 照样问得到")
        expectEqual(M.directQueryPlayer(forBundleID: PlaybackPlayer.kugou.bundleIdentifier), .kugou,
                    "直查名单: 酷狗同理")
        expectEqual(M.directQueryPlayer(forBundleID: "com.example.unknown"), nil,
                    "直查名单: 不认识的 App 不进名单 —— 别为一个没适配过的东西去问")
        expectEqual(M.directQueryPlayer(forBundleID: ""), nil,
                    "直查名单: 空 bundle id(.auto 就是空)不能匹配到任何播放器")
        expectEqual(M.directQueryPlayer(forBundleID: nil), nil, "直查名单: 没有 bundle id 就没有通路")

        // 正常路径:被接受的快照是谁报的,开关就跟谁走。
        expectEqual(M.nextFocusFallbackPlayer(current: nil, acceptedBundleID: am,
                                              fallbackSucceeded: nil), .appleMusic,
                    "回退开关: 通过 Apple Music 拿到过快照才打开(权限与 Music.app 在跑都已被证明)")
        expectEqual(M.nextFocusFallbackPlayer(current: nil, acceptedBundleID: sp,
                                              fallbackSucceeded: nil), .spotify,
                    "回退开关: Spotify 同理 —— 它也有自己的 JXA 通路")
        expectEqual(M.nextFocusFallbackPlayer(current: .appleMusic, acceptedBundleID: sp,
                                              fallbackSucceeded: nil), .spotify,
                    "回退开关: 换成另一个能直查的播放器,开关跟着换 —— 别拿旧那家的通路去问")
        expectEqual(M.nextFocusFallbackPlayer(current: .appleMusic, acceptedBundleID: "com.tencent.QQMusicMac",
                                              fallbackSucceeded: nil), .qqMusic,
                    "回退开关: 切到 QQ 音乐就跟着换 —— 别拿 Music.app 的通路去问一个没在用的播放器")
        expectEqual(M.nextFocusFallbackPlayer(current: .appleMusic, acceptedBundleID: "com.example.unknown",
                                              fallbackSucceeded: nil), nil,
                    "回退开关: 切到没适配过的 App 当场关掉")
        // "不给不相关用户弹自动化权限框"这条保证现在**不靠开关**,靠的是 snapshotAfterFocusLost
        // 里那个 switch 只对 Apple Music / Spotify 调 JXA:只听 QQ 音乐的人开关虽然是 .qqMusic,
        // 走的却是 per-client 探针(一个 perl 子进程),一个 Apple Event 都不会发。
        expectEqual(M.nextFocusFallbackPlayer(current: nil, acceptedBundleID: "com.netease.163music",
                                              fallbackSucceeded: nil), .netease,
                    "回退开关: 网易云也进名单 —— 它走探针那一级,不发 Apple Event")

        // 回退路径:拿到了就保持(焦点被占多久都兜得住),拿不到就关掉(收敛)。
        expectEqual(M.nextFocusFallbackPlayer(current: .appleMusic, acceptedBundleID: nil,
                                              fallbackSucceeded: true), .appleMusic,
                    "回退开关: 回退问到了就保持 —— 浏览器占着焦点期间每拍都得继续兜")
        expectEqual(M.nextFocusFallbackPlayer(current: .spotify, acceptedBundleID: nil,
                                              fallbackSucceeded: true), .spotify,
                    "回退开关: Spotify 的回退同样保持,而且保持的必须还是它自己")
        expectEqual(M.nextFocusFallbackPlayer(current: .appleMusic, acceptedBundleID: nil,
                                              fallbackSucceeded: false), nil,
                    "回退开关: 回退也问不到(播放器退出/stopped/权限没了)就关掉,此后不再 fork")
        expectEqual(M.nextFocusFallbackPlayer(current: .spotify, acceptedBundleID: nil,
                                              fallbackSucceeded: false), nil,
                    "回退开关: Spotify 的收敛方向一致")
        // 这一拍既没拿到被接受的快照、也没走回退(开关本来就是关的)——维持原样。
        expectEqual(M.nextFocusFallbackPlayer(current: nil, acceptedBundleID: nil,
                                              fallbackSucceeded: nil), nil,
                    "回退开关: 这一拍什么都没发生就别动它")
        expectEqual(M.nextFocusFallbackPlayer(current: .appleMusic, acceptedBundleID: nil,
                                              fallbackSucceeded: nil), .appleMusic,
                    "回退开关: 同上,反向也钉一条")

        // ---- 单拍 nil 不清状态 ----
        //
        // 改动前一拍 nil 就 clearIfWasPlaying(),把 title/allLines/封面/lastKey 全清掉。
        // 菜单栏有那层 hold 看不出来,悬浮歌词窗和灵动岛会当场闪一下。
        expectEqual(M.nilSnapshotClearsState(consecutiveNilCount: 1, failure: nil, nilStreakSeconds: 2), false,
                    "nil 宽限: 单拍拿不到不清状态(实测 24 小时里 2 次都是单次、下一拍就恢复)")
        expectEqual(M.nilSnapshotClearsState(consecutiveNilCount: M.nilSnapshotGrace, failure: nil,
                                             nilStreakSeconds: 4), true,
                    "nil 宽限: 连着到门槛就照清 —— 真停了不能一直挂着上一首")
        expectEqual(M.nilSnapshotClearsState(consecutiveNilCount: M.nilSnapshotGrace + 5, failure: nil,
                                             nilStreakSeconds: 20), true,
                    "nil 宽限: 超过门槛当然也清")
        // 门槛必须 ≥2,否则这条宽限等于没有;也不该大到让"播放列表放完"明显拖着。
        expectEqual(M.nilSnapshotGrace >= 2 && M.nilSnapshotGrace <= 3, true,
                    "nil 宽限: 门槛钉在 2~3 拍(播放档 2s 轮询 ≈ 4~6 秒)")

        // ---- 焦点被别的 App 占走:这一档按秒宽限,跟拍数无关 ----
        //
        // 系统级 Now Playing 是单焦点,浏览器里一个 video 元素就能占走它;目标播放器这时多半还在放,
        // 拿到的是**别人**的快照而不是"没人在放"。两件事在这里必须分开。
        expectEqual(M.isFocusHeldElsewhere(.focusHeldByOtherApp), true,
                    "焦点档: 焦点在不接受的 App 手里 —— 有别人在放")
        expectEqual(M.isFocusHeldElsewhere(.playerNotSelected), true,
                    "焦点档: 在报的 App 不在用户选中的名单里 —— 同样是有别人在放")
        expectEqual(M.isFocusHeldElsewhere(.notASong), true,
                    "焦点档: 信任的 App 在报但这不是歌(浏览器视频)—— 正是要兜的场景")
        expectEqual(M.isFocusHeldElsewhere(.nobodyReporting), false,
                    "焦点档: 真的没有任何 App 在报 ≠ 焦点被占,目标播放器自己也停了,不延长")
        expectEqual(M.isFocusHeldElsewhere(.mediaControlUnavailable), false,
                    "焦点档: 通道坏了是故障,不走这一档")
        expectEqual(M.isFocusHeldElsewhere(nil), false,
                    "焦点档: 没有失败原因时不延长")
        expectEqual(M.nilSnapshotClearsState(consecutiveNilCount: 999,
                                             failure: .focusHeldByOtherApp, nilStreakSeconds: 10), false,
                    "焦点档: 拍数再多也不清 —— 判据是秒,不是拍(nil 期间轮询档位会变)")
        expectEqual(M.nilSnapshotClearsState(consecutiveNilCount: 1,
                                             failure: .focusHeldByOtherApp,
                                             nilStreakSeconds: M.focusHeldGraceSeconds), true,
                    "焦点档: 到了秒门槛就收手 —— 不能无限期挂着一份可能早就不成立的状态")
        // 这一档必须明显长于普通 nil 宽限,否则"看个视频回来歌词还是断的",等于没改。
        expectEqual(M.focusHeldGraceSeconds >= 60, true,
                    "焦点档: 宽限要够长,至少覆盖一段短视频")
    }
}
