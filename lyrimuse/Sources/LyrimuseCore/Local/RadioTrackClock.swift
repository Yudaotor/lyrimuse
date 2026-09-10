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
/// ⚠️ 一处未验证:元数据切换的时刻是不是跟声音严格同步。如果苹果提前几秒推下一首的信息,这套表
/// 会整体超前那几秒 —— 那需要用耳朵核,不是代码能判的。真出现固定偏移就在这里补一个常量。
public enum RadioTrackClock {
    /// 单次推进的上限。正常轮询是 2s(App)/ 5s(collector);超过这个量说明中间发生了休眠、
    /// 长时间卡顿或进程被挂起,这时"墙钟差"不再等于"播了多久",宁可少算也不要凭空跳一大截。
    public static let maxAdvancePerTick: TimeInterval = 30

    public struct State: Equatable, Sendable {
        /// 这块表当前属于哪首歌(MediaControlSnapshot.trackKey 那一套)。
        public let trackKey: String
        /// 曲内位置(秒)。
        public let position: Double
        /// 上一次推进的时刻。
        public let tickedAt: Date

        public init(trackKey: String, position: Double, tickedAt: Date) {
            self.trackKey = trackKey
            self.position = position
            self.tickedAt = tickedAt
        }
    }

    /// 推进一拍。纯函数,selftest 直接覆盖。
    ///
    /// - 换歌(key 变了)或第一次见 → 归零重新起表,位置 0。
    /// - 播放中 → 按墙钟累加(单拍夹在 [0, maxAdvancePerTick])。
    /// - 暂停 → 位置冻结,只把 tick 时刻推到现在,恢复后不会把暂停的那段补进去。
    public static func advance(_ state: State?, trackKey: String, playing: Bool, now: Date) -> State {
        guard let state, state.trackKey == trackKey else {
            return State(trackKey: trackKey, position: 0, tickedAt: now)
        }
        guard playing else {
            return State(trackKey: trackKey, position: state.position, tickedAt: now)
        }
        let raw = now.timeIntervalSince(state.tickedAt)
        let step = min(max(raw, 0), maxAdvancePerTick)
        return State(trackKey: trackKey, position: state.position + step, tickedAt: now)
    }
}
