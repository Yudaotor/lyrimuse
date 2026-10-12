import Foundation
import os

/// 本机验证用的模拟播放(`lyrimuse://debug/simulate`,见 14 章决策 98)。开着时 `LocalPlaybackSource` 不读播放器,
/// 每拍按这一份造快照,走跟真实播放同一条 apply 路径,界面拿到的就是一首「正在播放」的歌。
///
/// 对外的出口一律不动:不写给引擎的播放状态(引擎据此打卡 Last.fm / ListenBrainz、推送),Discord 状态、换歌通知、
/// 「上次在听」落盘、各播放器的校准表都不跟着变,播放控制不发给真实播放器(播放 / 暂停、跳转改的是这一份)。
/// 歌词只从本机缓存读,引擎不会去搜,所以要模拟缓存里已经有歌词的歌。
///
/// 只在内存里,App 重启就没了。
public struct PlaybackSimulation: Equatable, Sendable {
    /// 快照里的播放器 bundle id。不是任何真实播放器,按播放器分的规则(广告、校准、跳转方式)都不认它。
    public static let bundleIdentifier = "me.yudaotor.lyrimuse.simulated"
    /// 收尾之后这么久里换回真实曲目,不算用户换了歌(换歌通知不发)。
    public static let endGrace: TimeInterval = 10

    public var title: String
    public var artist: String
    public var album: String
    /// 秒;nil = 不知道时长,位置一直往前走。
    public var duration: Double?
    /// `anchoredAt` 那一刻的位置(秒)。
    public var position: Double
    public var playing: Bool
    public var anchoredAt: Date

    public init(title: String, artist: String, album: String, duration: Double?, position: Double, playing: Bool,
                anchoredAt: Date = Date()) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.position = max(0, position)
        self.playing = playing
        self.anchoredAt = anchoredAt
    }

    /// 此刻的位置(秒),放到头停在时长上。
    public func elapsed(at now: Date) -> Double {
        let raw = playing ? position + now.timeIntervalSince(anchoredAt) : position
        return min(max(0, raw), duration ?? .infinity)
    }

    /// 放到头就算停了,跟播放器放完一首停住一样。
    public func isPlaying(at now: Date) -> Bool {
        guard playing else { return false }
        guard let duration else { return true }
        return position + now.timeIntervalSince(anchoredAt) < duration
    }

    public func snapshot(at now: Date) -> MediaControlSnapshot {
        .forReplay(title: title, artist: artist, album: album, duration: duration, elapsedTime: elapsed(at: now),
                   playing: isPlaying(at: now), playbackRate: 1, bundleIdentifier: Self.bundleIdentifier,
                   anchorElapsedTime: nil, capturedAt: now)
    }

    /// 从此刻的位置重新起算(暂停 / 继续、跳转都先落到这里,位置不跳)。
    func reanchored(at now: Date) -> PlaybackSimulation {
        var copy = self
        copy.position = elapsed(at: now)
        copy.anchoredAt = now
        return copy
    }

    // MARK: 全局状态

    private struct State: Sendable {
        var current: PlaybackSimulation?
        var endedAt: Date?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    public static var current: PlaybackSimulation? { state.withLock { $0.current } }
    public static var isActive: Bool { current != nil }

    public static func begin(_ simulation: PlaybackSimulation) {
        state.withLock { $0 = State(current: simulation, endedAt: nil) }
    }

    public static func end(now: Date = Date()) {
        state.withLock { s in
            guard s.current != nil else { return }
            s = State(current: nil, endedAt: now)
        }
    }

    /// 模拟期间的播放 / 暂停。没在模拟返回 false。
    @discardableResult
    public static func togglePlaying(now: Date = Date()) -> Bool {
        state.withLock { s in
            guard let current = s.current else { return false }
            var next = current.reanchored(at: now)
            next.playing = !current.isPlaying(at: now)
            if next.playing, let duration = next.duration, next.position >= duration { next.position = 0 }
            s.current = next
            return true
        }
    }

    /// 模拟期间的跳转。没在模拟返回 false。
    @discardableResult
    public static func seek(toSeconds seconds: Double, now: Date = Date()) -> Bool {
        state.withLock { s in
            guard let current = s.current else { return false }
            var next = current.reanchored(at: now)
            next.position = min(max(0, seconds), current.duration ?? .infinity)
            s.current = next
            return true
        }
    }

    /// 换歌引起的对外动作(换歌通知)此刻该不该做:模拟中不做,收尾后 `endGrace` 秒内换回真实曲目也不做。
    public static func suppressesTrackChange(now: Date = Date()) -> Bool {
        state.withLock { s in
            if s.current != nil { return true }
            guard let endedAt = s.endedAt else { return false }
            return now.timeIntervalSince(endedAt) < endGrace
        }
    }
}
