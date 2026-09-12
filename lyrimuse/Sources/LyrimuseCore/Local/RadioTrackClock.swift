import Foundation

/// 电台(Apple Music Radio / 直播流)的**曲内**播放时钟(2026-09-10)。
///
/// 起因是实测:电台播放时,系统 Now Playing 报的 `duration` 和 `elapsedTime` **都是整档节目的**,
/// 不是当前这首歌的。2026-09-10 连续采样 30 次抓到一次换歌:锚点 07:15:35 归零,07:20:39 换到
/// Clairo《Juna》时位置**没有复位**,07:23:22 读到 467s —— 正好等于 07:23:22 − 07:15:35。而《Juna》
/// 此刻真实的曲内位置是 163s,**喂给歌词引擎的位置偏了 304 秒**,歌词从头到尾对不上。
/// `duration` 同样是整档节目(实测 3390.122s = 56 分半),它还会被写进歌词缓存的 resolved_duration,
/// 之后正常播放同一首歌时跟真实时长差 94%、超过 12% 的 durationMismatch 阈值,触发变体键重解析。
///
/// 系统这一层**没有**任何单曲级别的位置可取,唯一能标出曲目边界的信息就是"元数据换了"这一刻。
/// 所以这里自己起表:曲目 key 一变就归零,之后只在播放中按墙钟累加。
///
/// ## 起表时刻要用"观察到换歌的那一刻",不是"我们轮询到的那一刻"(2026-09-10,用户报「歌词进度偏慢」)
///
/// 归零若发生在轮询那一拍,从换歌到那一拍之间的时间就被永久吞掉,整首歌恒慢那么多。实测同一晚
/// 开台那次:锚点说播放头 0.000 的时刻是 23:18:22,标题到达事件流是 23:18:23.425(迟 1.43s),
/// App 真正应用新曲目要到 23:18:23.816(再迟 0.39s)—— 也就是整首歌恒慢约 1.8 秒。
/// 所以 `advance` 收一个 `startedAt`:调用方(stream watcher 记的换歌时刻,见
/// `MediaControlClient.noteTrackChangeObserved`)把观察到的那一刻传进来,这里据此播种初始位置。
///
/// ⚠️ 仍未验证的那一段:元数据切换本身跟声音同不同步。同一晚量到这个台**每两首歌之间还有约 65 秒
/// 非歌曲内容**(英雄→Fact Check 多 63.3s、Fact Check→Blingy 多 66.3s,都是拿 Apple 目录曲长比的),
/// 说明这是有主持人说话的节目;元数据要是在说话段开头就切,这套表会超前一整分钟 —— 用户听到的是
/// "偏慢一点"而不是"快了一分钟",所以切换点确实靠近歌曲起点,残差是秒级。那几秒需要耳朵核,
/// 真是恒定偏移就走时间轴偏移那套设置,不在这里硬编常量。
public enum RadioTrackClock {
    /// 单次推进的上限。正常轮询是 2s(App)/ 5s(collector);超过这个量说明中间发生了休眠、
    /// 长时间卡顿或进程被挂起,这时"墙钟差"不再等于"播了多久",宁可少算也不要凭空跳一大截。
    public static let maxAdvancePerTick: TimeInterval = 30

    /// 播种初始位置的上限。换歌时刻只可能比"现在"早一点点(事件到达 → 去抖动 250ms → 子进程往返),
    /// 实测这段是 0.4~1.8 秒;夹在 8 秒是防"事件时刻是上一首留下的陈旧值"这类错配 —— 宁可少播种,
    /// 也不要凭一个错时刻把一首歌的位置直接推走几十秒。
    public static let maxStartSeed: TimeInterval = 8

    public struct State: Equatable, Sendable {
        /// 这块表当前属于哪首歌(MediaControlSnapshot.trackKey 那一套)。
        public let trackKey: String
        /// 曲内位置(秒)。
        public let position: Double
        /// 上一次推进的时刻。
        public let tickedAt: Date
        /// **上一拍**是不是在播。决定这一拍要不要把 [上一拍, 现在] 这段算成播放时间,见 advance。
        public let playing: Bool

        public init(trackKey: String, position: Double, tickedAt: Date, playing: Bool) {
            self.trackKey = trackKey
            self.position = position
            self.tickedAt = tickedAt
            self.playing = playing
        }
    }

    /// 推进一拍。纯函数,selftest 直接覆盖。
    ///
    /// - 换歌(key 变了)或第一次见 → 重新起表,位置 = 从 `startedAt` 到现在这段(见 seedPosition);
    ///   没给 `startedAt` 就是 0,跟这个参数加进来之前逐字相同。
    /// - 否则按 **上一拍** 的播放状态决定要不要累加 [上一拍, 现在] 这段(单拍夹在 [0, maxAdvancePerTick])。
    ///
    /// ⚠️ 判据是**上一拍**在不在播,不是这一拍(2026-09-10 当天第二轮,修一个真实回归)。按"这一拍在播"
    /// 累加的话,「上一拍暂停、这一拍恢复」会把整段暂停间隔当成播放时间加进去 —— 而暂停时轮询降到 6s
    /// 一拍(空闲 10s),所以停得越久跳得越多。用户报「暂停久一点再恢复,歌词进度就不正常」,日志里的
    /// resume transition 逐条坐实:0.000→5.841、26.416→29.953、13.801→17.545,跳了 3.5~5.8 秒。
    /// 反过来「上一拍在播、这一拍暂停」照旧累加:那一段确实基本都在播,而暂停事件本身会立刻唤醒一次
    /// 轮询,过冲很小。两边都以"这段区间的多数状态"为准,方向对称。
    public static func advance(_ state: State?, trackKey: String, playing: Bool, now: Date,
                               startedAt: Date? = nil) -> State {
        guard let state, state.trackKey == trackKey else {
            return State(trackKey: trackKey, position: seedPosition(startedAt: startedAt, now: now),
                         tickedAt: now, playing: playing)
        }
        guard state.playing else {
            return State(trackKey: trackKey, position: state.position, tickedAt: now, playing: playing)
        }
        let raw = now.timeIntervalSince(state.tickedAt)
        let step = min(max(raw, 0), maxAdvancePerTick)
        return State(trackKey: trackKey, position: state.position + step, tickedAt: now, playing: playing)
    }

    /// 过了真曲长多久就认为"这首歌放完了"。电台在两首歌之间还有主持人说话(2026-09-10 实测这个台
    /// 多出 66~110 秒),那段时间元数据还停在上一首,表也还在走 —— 留一点余量是因为末句歌词通常
    /// 结束得比曲长早,而这块表本身还有秒级误差,收早了会把最后一句吞掉。
    public static let tailGraceSecs: TimeInterval = 5

    /// 这首歌是不是已经放完了(位置越过真曲长 + tailGraceSecs)。纯函数,selftest 直接覆盖。
    ///
    /// ⚠️ 时长拿不到 / 不是正数就一律返回 false(fail-closed):电台刚换曲、歌词缓存里还没有这首歌时,
    /// 快照里的 duration 仍是**整档节目**那个大数,这时判"放完了"会把整首歌的歌词都收掉。
    public static func passedTrackEnd(position: Double, durationSecs: Double?) -> Bool {
        guard let durationSecs, durationSecs > 0 else { return false }
        return position > durationSecs + tailGraceSecs
    }

    /// 换歌那一刻到现在这段,就是这首歌已经播了的量。纯函数,selftest 直接覆盖。
    ///
    /// 三个边界各挡一种错配:没有观察时刻 → 0(跟没有这个参数时逐字相同);观察时刻在未来(时钟毛刺)
    /// → 0,不要负位置;超过 maxStartSeed → 夹住,见那个常量的注释。
    public static func seedPosition(startedAt: Date?, now: Date) -> Double {
        guard let startedAt else { return 0 }
        let gap = now.timeIntervalSince(startedAt)
        guard gap > 0 else { return 0 }
        return min(gap, maxStartSeed)
    }
}
