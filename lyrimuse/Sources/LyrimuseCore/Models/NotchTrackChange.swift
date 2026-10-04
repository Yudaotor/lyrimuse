import CoreGraphics
import Foundation

/// 换歌翻牌里从刘海掉出来的那一条:新歌的歌名 + 歌手。`id` 每次换歌递增,视图按它做「旧的收回去、新的掉下来」。
public struct NotchTrackDrop: Equatable, Sendable {
    public let id: Int
    public let title: String
    public let artist: String

    public init(id: Int, title: String, artist: String) {
        self.id = id
        self.title = title
        self.artist = artist
    }
}

/// 换歌翻牌:什么时候让新歌名掉出来。卡片此刻看不看得见、是不是在展开 / 收起 / 报喜,由灵动岛控制器另外判。
public enum NotchTrackDropRules {
    /// 歌名停多久。
    public static let holdDuration: Duration = .milliseconds(2_800)

    /// 一首曲目的身份:歌名 + 歌手,广告单独一类(广告结束回到同名的歌也算换了一首)。
    public static func key(title: String, artist: String, isAdBreak: Bool) -> String {
        "\(isAdBreak ? "ad" : "track")\u{1F}\(title)\u{1F}\(artist)"
    }

    /// 去抖之后看到这一首,要不要掉歌名。只认「上一首也有曲目,而且换了」:灵动岛刚建出来的第一首
    /// (`previousKey` 为 nil)、从没在放切到在放都不掉;广告不掉,广告结束回到歌掉。
    public static func shouldDrop(previousKey: String?, title: String, artist: String, isAdBreak: Bool) -> Bool {
        guard !isAdBreak, !title.isEmpty, let previousKey,
              previousKey != key(title: "", artist: "", isAdBreak: false)
        else { return false }
        return previousKey != key(title: title, artist: artist, isAdBreak: false)
    }
}

/// 换歌翻牌:去抖之后看到的每一拍喂进来(`observe`),判掉不掉歌名;记着上一首。卡片此刻看不看得见由控制器另外判。
///
/// 播放器说在放、声音还没走起来(`isWaitingToPlay`:加载、前贴片广告、卡住)时先不判,记着的上一首不动,等走起来那一拍
/// 按那时的曲目和广告态判。前贴片广告报的是接下来那首的身份,「广告中」要等广告真放起来才亮,比歌名晚到:这时候就判,
/// 会把广告当成新歌掉一次、广告结束回到歌再掉一次。
public struct NotchTrackDropTracker: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// 换了一首,掉新歌名。
        case drop
        /// 曲目变了、这一拍不掉(广告、第一首、没歌名、声音还没走起来);正停着的那条收掉。
        case clear
        /// 曲目没变。
        case none
    }

    /// 上一次判过的曲目(`NotchTrackDropRules.key`);nil = 还没判过,第一首不掉。
    public private(set) var lastKey: String?

    public init() {}

    public mutating func observe(title: String, artist: String, isAdBreak: Bool, isWaitingToPlay: Bool) -> Outcome {
        let key = NotchTrackDropRules.key(title: title, artist: artist, isAdBreak: isAdBreak)
        guard key != lastKey else { return .none }
        if isWaitingToPlay { return .clear }
        let previous = lastKey
        lastKey = key
        return NotchTrackDropRules.shouldDrop(previousKey: previous, title: title, artist: artist, isAdBreak: isAdBreak)
            ? .drop : .clear
    }
}

/// 换歌翻牌:耳朵里那枚封面(左耳在广告时是喇叭)换成另一面时怎么过渡。纯状态机:视图把「换歌了」和
/// 「这一刻该显示哪一面」喂进来,拿回过渡方式;nil = 这一面先不换。
///
/// 换歌那一刻耳朵用得上的图(包括马上会被撤掉的高清图、退回来的上一首系统封面)都记成旧图。旧图不算新封面:
/// 新图到之前接着显示原来那一面,到了才翻;翻之前比一眼是不是同一张(同一张专辑),是就原地换、不翻。
/// 等新封面最多等 `awaitWindow`,过了之后的换图一律原地换(跟没有这个功能时一样)。
public struct NotchArtworkFlipPlanner<Token: Equatable> {
    public enum Face: Equatable {
        case empty
        case adIcon
        case artwork(Token)
    }

    public enum Transition: Equatable, Sendable {
        /// 原地直接换。
        case cut
        /// 翻过来。
        case flip
        /// 有图和没图之间淡入淡出。
        case fade
    }

    /// 换歌之后最多等新封面多久。
    public static var awaitWindow: TimeInterval { 15 }
    /// 等来的是「没有图」,或者广告刚结束、新封面还没到时,最多再留原来那一面多久。
    public static var shortHold: TimeInterval { 4 }

    public private(set) var shown: Face
    /// 正留着原来那一面等新封面时,该回头再看一眼的时刻;nil = 不用。
    public private(set) var recheckAt: Date?
    private var stale: [Token] = []
    private var changedAt: Date?

    public init(shown: Face) {
        self.shown = shown
    }

    /// 换歌了。`staleArtwork` 是换歌之前耳朵用得上的那几张图;此刻显示着的那张自动算进去。
    public mutating func trackChanged(staleArtwork: [Token], now: Date) {
        if !isAwaiting(now: now) { stale = [] }
        for token in staleArtwork where !stale.contains(token) { stale.append(token) }
        if case .artwork(let token) = shown, !stale.contains(token) { stale.append(token) }
        changedAt = now
        recheckAt = nil
    }

    /// 广告结束、回到的还是进广告前那首(前贴片广告报的就是这首的身份)。不算换歌:广告期间到的图就是这首的,不记成旧图,
    /// 手上有就当场翻;等新封面的计时从这一刻重新算,手上还只有旧图或没图时喇叭照样最多再留 `shortHold`。
    public mutating func adBreakEnded(now: Date) {
        if !isAwaiting(now: now) { stale = [] }
        changedAt = now
        recheckAt = nil
    }

    /// 这一刻该显示 `target`。`samePicture` 判两张图是不是同一张封面,只在要翻的时候调。
    public mutating func update(target: Face, now: Date, samePicture: (Token, Token) -> Bool) -> Transition? {
        recheckAt = nil
        let awaiting = isAwaiting(now: now)
        if !awaiting {
            changedAt = nil
            stale = []
        }
        guard target != shown else { return nil }
        let elapsed = changedAt.map { now.timeIntervalSince($0) } ?? .infinity
        let targetIsStale: Bool
        if case .artwork(let token) = target { targetIsStale = stale.contains(token) } else { targetIsStale = false }

        switch (shown, target) {
        case (_, .adIcon):
            shown = target
            return .cut
        case (.adIcon, _):
            if awaiting, targetIsStale || target == .empty, elapsed < Self.shortHold {
                return hold(Self.shortHold)
            }
            finish(target)
            return target == .empty ? .fade : .flip
        case (.artwork(let from), .artwork(let to)):
            guard awaiting else {
                shown = target
                return .cut
            }
            if targetIsStale { return hold(Self.awaitWindow) }
            finish(target)
            return samePicture(from, to) ? .cut : .flip
        case (.artwork, .empty):
            if awaiting, elapsed < Self.shortHold { return hold(Self.shortHold) }
            finish(target)
            return .fade
        case (.empty, _):
            finish(target)
            return .fade
        }
    }

    private func isAwaiting(now: Date) -> Bool {
        guard let changedAt else { return false }
        return now.timeIntervalSince(changedAt) < Self.awaitWindow
    }

    private mutating func hold(_ limit: TimeInterval) -> Transition? {
        recheckAt = changedAt?.addingTimeInterval(limit)
        return nil
    }

    private mutating func finish(_ target: Face) {
        shown = target
        changedAt = nil
        stale = []
        recheckAt = nil
    }
}

/// 两张封面是不是同一张(同一张专辑的下一首、同一张图的高清 / 低清两份):各缩成 8×8 比颜色。
public struct ArtworkFingerprint: Equatable, Sendable {
    public static let side = 8
    /// 每个通道的平均差(0–255)不超过它就算同一张。同一张图不同分辨率缩下来只差个位数,不同封面通常差几十。
    public static let sameTolerance: Double = 12

    public let rgb: [UInt8]

    public init?(rgb: [UInt8]) {
        guard rgb.count == Self.side * Self.side * 3 else { return nil }
        self.rgb = rgb
    }

    /// 居中裁方、高质量缩到 8×8(`ArtworkThumbnail.squareBitmap`),取 RGB。建不出来返回 nil。
    public init?(image: CGImage) {
        let n = Self.side
        guard let small = ArtworkThumbnail.squareBitmap(from: image, pixelSide: n),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgba = [UInt8](repeating: 0, count: n * n * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                      bytesPerRow: n * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(small, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return nil }
        var rgb = [UInt8]()
        rgb.reserveCapacity(n * n * 3)
        for pixel in 0..<(n * n) {
            rgb.append(rgba[pixel * 4])
            rgb.append(rgba[pixel * 4 + 1])
            rgb.append(rgba[pixel * 4 + 2])
        }
        self.rgb = rgb
    }

    public func isSamePicture(as other: ArtworkFingerprint) -> Bool {
        var total = 0
        for index in rgb.indices { total += abs(Int(rgb[index]) - Int(other.rgb[index])) }
        return Double(total) / Double(rgb.count) <= Self.sameTolerance
    }
}
