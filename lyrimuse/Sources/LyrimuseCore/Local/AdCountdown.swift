import Foundation

/// 「广告中」那一行的倒计时从哪来(灵动岛 `adCountdown`)。
public enum AdCountdown: Equatable, Sendable {
    /// 广告本身就是一首「曲目」(Spotify、YouTube Music 网页版):按曲目的时长和位置算。
    case track
    /// 广告跟接下来那首歌共用身份(Kaset):曲目的时长是那首歌的,按广告自己的时长和进度算。
    case own(AdBreakClock)
    /// 共用身份、又拿不到广告自己的时长:不画,不拿歌的时长凑数。
    case unknown

    /// 这一拍的倒计时从哪来。纯函数,selftest 覆盖。
    /// - sharesIdentity: 这个播放器的广告跟正片共用身份(`LocalPlaybackSource.adSharesTrackIdentity`)。
    /// - adDuration / adElapsed: 播放器给出的广告自己的时长与这一拍的进度(秒,`MediaControlSnapshot.adDuration`)。
    /// - sameTrack: 跟上一拍是同一首。同一首、这一拍没读到广告时长时沿用上一拍那只表(两秒一拍,读漏一次别让倒计时闪没)。
    public static func next(isAdBreak: Bool, sharesIdentity: Bool, adDuration: Double?, adElapsed: Double?,
                            capturedAt: Date, previous: AdCountdown, sameTrack: Bool) -> AdCountdown {
        guard isAdBreak, sharesIdentity else { return .track }
        if let adDuration, adDuration > 0, let adElapsed {
            return .own(AdBreakClock(durationMs: Int((adDuration * 1000).rounded()),
                                     positionMs: Int((max(0, adElapsed) * 1000).rounded()),
                                     capturedAt: capturedAt))
        }
        if sameTrack, case .own = previous { return previous }
        return .unknown
    }
}

/// 一段广告自己的时长和进度:读到那一刻记下,按墙钟往后推。
public struct AdBreakClock: Equatable, Sendable {
    public let durationMs: Int
    public let positionMs: Int
    public let capturedAt: Date

    public init(durationMs: Int, positionMs: Int, capturedAt: Date) {
        self.durationMs = durationMs
        self.positionMs = positionMs
        self.capturedAt = capturedAt
    }

    /// 此刻的进度,不超过时长。
    public func positionMs(now: Date) -> Int {
        let moved = Int((now.timeIntervalSince(capturedAt) * 1000).rounded())
        return min(durationMs, positionMs + max(0, moved))
    }
}
