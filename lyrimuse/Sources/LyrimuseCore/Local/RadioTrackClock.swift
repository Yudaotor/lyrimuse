import Foundation

/// 电台(Apple Music Radio / 直播流)的**曲内**播放时钟。
///
/// 起因是实测:电台播放时,系统 Now Playing 报的 `duration` 和 `elapsedTime` **都是整档节目的**,
/// 不是当前这首歌的。连续采样 30 次抓到一次换歌:锚点 07:15:35 归零,07:20:39 换到
/// Clairo《Juna》时位置**没有复位**,07:23:22 读到 467s —— 正好等于 07:23:22 − 07:15:35。而《Juna》
/// 此刻真实的曲内位置是 163s,**喂给歌词引擎的位置偏了 304 秒**,歌词从头到尾对不上。
/// `duration` 同样是整档节目(实测 3390.122s = 56 分半),它还会被写进歌词缓存的 resolved_duration,
/// 之后正常播放同一首歌时跟真实时长差 94%、超过 12% 的 durationMismatch 阈值,触发变体键重解析。
///
/// 这种台系统这一层**没有**任何单曲级别的位置可取,唯一能标出曲目边界的信息就是"元数据换了"这一刻。
/// 所以这里自己起表:曲目 key 一变就归零,之后只在播放中按墙钟累加。也有报单曲位置的台,那种台换歌时
/// 用系统位置起表,判据见 perTrackSeed(...)。
///
/// ## 起表时刻要用"观察到换歌的那一刻",不是"我们轮询到的那一刻"(现象是「歌词进度偏慢」)
///
/// 归零若发生在轮询那一拍,从换歌到那一拍之间的时间就被永久吞掉,整首歌恒慢那么多。实测同一晚
/// 开台那次:锚点说播放头 0.000 的时刻是 23:18:22,标题到达事件流是 23:18:23.425(迟 1.43s),
/// App 真正应用新曲目要到 23:18:23.816(再迟 0.39s)—— 也就是整首歌恒慢约 1.8 秒。
/// 所以 `advance` 收一个 `startedAt`:调用方(stream watcher 记的换歌时刻,见
/// `MediaControlClient.noteTrackChangeObserved`)把观察到的那一刻传进来,这里据此播种初始位置。
///
/// 仍未验证的那一段:元数据切换本身跟声音同不同步。同一晚量到这个台**每两首歌之间还有约 65 秒
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
        /// 这首歌起表时判成了「系统报单曲位置」(见 perTrackSeed)。为真时这首余下的时间都以系统位置为准,
        /// 调用方不再拿这块表的位置去顶替快照;表只跟着系统位置记账(落盘、重启接回用)。
        public let perTrack: Bool

        public init(trackKey: String, position: Double, tickedAt: Date, playing: Bool, perTrack: Bool = false) {
            self.trackKey = trackKey
            self.position = position
            self.tickedAt = tickedAt
            self.playing = playing
            self.perTrack = perTrack
        }
    }

    /// 推进一拍。纯函数,selftest 直接覆盖。
    ///
    /// - 换歌(key 变了)或第一次见 → 重新起表:给了 `perTrackSeed`(见 perTrackSeed(...))就用它并标 perTrack,
    ///   否则位置 = 从 `startedAt` 到现在这段(见 seedPosition);两个都没给就是 0。
    /// - 同一首、还没标 perTrack、给了 `perTrackSeed` → 改用它并标 perTrack(起表那一拍读到的还是上一首的位置时)。
    /// - 同一首、已标 perTrack、给了 `systemPosition` → 位置直接取系统位置(缓冲时重报的 0、暂停、拖动都跟着走)。
    /// - 否则按 **上一拍** 的播放状态决定要不要累加 [上一拍, 现在] 这段(单拍夹在 [0, maxAdvancePerTick])。
    ///
    /// 判据是**上一拍**在不在播,不是这一拍(修一个真实回归)。按"这一拍在播"
    /// 累加的话,「上一拍暂停、这一拍恢复」会把整段暂停间隔当成播放时间加进去 —— 而暂停时轮询降到 6s
    /// 一拍(空闲 10s),所以停得越久跳得越多。现象是「暂停久一点再恢复,歌词进度就不正常」,日志里的
    /// resume transition 逐条坐实:0.000→5.841、26.416→29.953、13.801→17.545,跳了 3.5~5.8 秒。
    /// 反过来「上一拍在播、这一拍暂停」照旧累加:那一段确实基本都在播,而暂停事件本身会立刻唤醒一次
    /// 轮询,过冲很小。两边都以"这段区间的多数状态"为准,方向对称。
    public static func advance(_ state: State?, trackKey: String, playing: Bool, now: Date,
                               startedAt: Date? = nil, perTrackSeed: Double? = nil,
                               systemPosition: Double? = nil) -> State {
        guard let state, state.trackKey == trackKey else {
            return State(trackKey: trackKey, position: perTrackSeed ?? seedPosition(startedAt: startedAt, now: now),
                         tickedAt: now, playing: playing, perTrack: perTrackSeed != nil)
        }
        // 起表之后才判成单曲位置(调用方只在 perTrackDecisionWindow 内给):从这一拍起改跟系统位置。
        if !state.perTrack, let perTrackSeed {
            return State(trackKey: trackKey, position: perTrackSeed, tickedAt: now, playing: playing, perTrack: true)
        }
        if state.perTrack, let systemPosition, systemPosition >= 0 {
            return State(trackKey: trackKey, position: systemPosition, tickedAt: now, playing: playing, perTrack: true)
        }
        guard state.playing else {
            return State(trackKey: trackKey, position: state.position, tickedAt: now, playing: playing,
                         perTrack: state.perTrack)
        }
        let raw = now.timeIntervalSince(state.tickedAt)
        let step = min(max(raw, 0), maxAdvancePerTick)
        return State(trackKey: trackKey, position: state.position + step, tickedAt: now, playing: playing,
                     perTrack: state.perTrack)
    }

    /// 过了真曲长多久就认为"这首歌放完了"。电台在两首歌之间还有主持人说话(实测这个台
    /// 多出 66~110 秒),那段时间元数据还停在上一首,表也还在走 —— 留一点余量是因为末句歌词通常
    /// 结束得比曲长早,而这块表本身还有秒级误差,收早了会把最后一句吞掉。
    public static let tailGraceSecs: TimeInterval = 5

    /// 这首歌是不是已经放完了(位置越过真曲长 + tailGraceSecs)。纯函数,selftest 直接覆盖。
    ///
    /// 时长拿不到 / 不是正数就一律返回 false(fail-closed):电台刚换曲、歌词缓存里还没有这首歌时,
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

    // MARK: - 报单曲位置的电台

    /// 换歌那一拍系统锚点最多多旧还算「换歌时新打的」。整档节目口径的台换歌时常常不重打锚点(锚点是几百秒前的)。
    public static let perTrackAnchorMaxAge: TimeInterval = 5
    /// 换歌那一拍系统位置的上限。起播跳过的前奏落在这之内;更大的值当成整档节目口径,不采信。
    public static let perTrackSeedMax: Double = 60
    /// 换歌那一拍的系统位置至少要比上一首最后的系统位置小这么多,才算「换歌时归零了」。整档节目口径换歌不归零、只会接着往上涨。
    public static let perTrackResetMargin: Double = 20
    /// 系统报的时长不超过这个值算「单曲量级」。整档节目口径的台报的是整档节目长度(几十分钟起)。
    public static let perTrackMaxDuration: Double = 900
    /// 起表后多久之内还可以补判成单曲位置。「交叉渐入渐出」换歌时系统先推新标题、进度还是上一首的,
    /// 约半秒后才推新歌自己的进度;起表那一拍可能正好读到前一份。比较对象固定是换歌前上一首最后的系统位置。
    public static let perTrackDecisionWindow: TimeInterval = 10

    /// 有的电台系统报的是**单曲**位置(换歌归零、每拍都对),「歌曲过渡」开着时新歌还会跳过前奏、
    /// 从十几秒处切进来。这种台换歌时直接用系统位置起表,否则从 0 起的表会整首慢一段前奏的长度。
    /// 判成之后这首余下的时间也都以系统位置为准(State.perTrack):起播缓冲时 Apple Music 会连报几次 0,
    /// 最后一个才是真起点,只在起表那一拍取一次会整首快几秒。
    /// 纯函数,selftest 直接覆盖;collector 的 radioPerTrackSeed 同一套判据、同一组常量,两边一起改。
    ///
    /// 前两条必须成立、后两条至少成立一条,才返回 `systemPosition`,否则 nil(调用方照旧按 seedPosition 起表):
    /// - 读数来自换歌时新打的锚点:`anchorAge` 在 [0, perTrackAnchorMaxAge](现读的 AppleScript 位置传 0);
    /// - `systemPosition` 在 [0, perTrackSeedMax];
    /// - 相对上一首最后的系统位置归零了:`previousPosition − systemPosition ≥ perTrackResetMargin`;
    /// - 系统报的时长是单曲量级:`reportedDuration` 在 (0, perTrackMaxDuration]。开台第一首、App 重启后的
    ///   第一首没有上一首的读数,靠这一条判。
    public static func perTrackSeed(systemPosition: Double?, anchorAge: TimeInterval?,
                                    previousPosition: Double?, reportedDuration: Double? = nil) -> Double? {
        guard let systemPosition, let anchorAge else { return nil }
        guard anchorAge >= 0, anchorAge <= perTrackAnchorMaxAge else { return nil }
        guard systemPosition >= 0, systemPosition <= perTrackSeedMax else { return nil }
        let reset = previousPosition.map { $0 - systemPosition >= perTrackResetMargin } ?? false
        let trackScale = reportedDuration.map { $0 > 0 && $0 <= perTrackMaxDuration } ?? false
        guard reset || trackScale else { return nil }
        return systemPosition
    }
}
