import Foundation

/// 「歌词管理」侧栏的状态胶囊:一次只看一类,点一下只看这一类,再点一下回到「全部」。逐字 / 逐行 / 纯文本是「筛选」里的
/// 「歌词类型」,不在这里。
///
/// 「缺歌词」「纯音乐」跟设置页「歌词库」统计同一个成色阶梯(`LyricsKind.classify`):标了纯音乐的只算纯音乐,有纯文本兜底的
/// 不算缺歌词,胶囊上的数跟统计对得上。
public enum LyricsManagerStatus: String, CaseIterable, Sendable {
    case all
    /// 没有歌词:不是纯音乐,也没有纯文本兜底(含最近一轮一个歌词源都没应答的那些)。
    case missing
    case instrumental
    /// 手动调整过:改过歌词(`manual_lyrics`),或者调过时间轴偏移(`LyricsPinStore`)。
    case adjusted

    /// 一条记录在胶囊判定里用到的几样事实。
    public struct Facts: Sendable, Equatable {
        public let kind: LyricsKind
        public let isManual: Bool
        public let isPinned: Bool

        public init(kind: LyricsKind, isManual: Bool, isPinned: Bool) {
            self.kind = kind
            self.isManual = isManual
            self.isPinned = isPinned
        }
    }

    public func matches(_ facts: Facts) -> Bool {
        switch self {
        case .all: return true
        case .missing: return facts.kind == .none
        case .instrumental: return facts.kind == .instrumental
        case .adjusted: return facts.isManual || facts.isPinned
        }
    }

    /// 每个胶囊各有几首,一遍扫完。
    public static func counts(_ facts: [Facts]) -> [LyricsManagerStatus: Int] {
        var out = Dictionary(uniqueKeysWithValues: allCases.map { ($0, 0) })
        for item in facts {
            for status in allCases where status.matches(item) {
                out[status, default: 0] += 1
            }
        }
        return out
    }
}

/// 「清理无效记录」挑哪些:不是歌、也找不回歌词的那些(广告、播客、有声书)。先要没有歌词(成色落在 `.none`)、没人工修正、
/// 没校准过时间轴,再满足两条之一:键里没有歌手;或者时长 ≥ `longDurationSecs`(见 11 章决策 83)。
public enum LyricsManagerCleanup {
    public static let longDurationSecs: Double = 20 * 60

    public static func isInvalid(artist: String, kind: LyricsKind, isManual: Bool, isPinned: Bool,
                                 durationSecs: Double) -> Bool {
        guard kind == .none, !isManual, !isPinned else { return false }
        if artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return durationSecs >= longDurationSecs
    }
}

/// 「歌词管理」侧栏的宽度:拖右边缘在 `minimum`～`maximum` 之间调,双击拖柄回到 `standard`。窗口窄到右边留不出
/// `detailMinimum` 时侧栏跟着让,但不小于 `minimum`;存下来的值不因此改动,窗口拉宽了就回到原来的宽度。
public enum LyricsManagerSidebarWidth {
    public static let minimum = 440.0
    public static let maximum = 640.0
    public static let standard = 540.0
    /// 右边详情至少留这么宽。
    public static let detailMinimum = 480.0

    /// 拖动中、存盘前夹进范围;不是有限数时回到 `standard`。
    public static func clamped(_ width: Double) -> Double {
        guard width.isFinite else { return standard }
        return min(max(width, minimum), maximum)
    }

    /// 存下来的宽度在这扇窗口里实际画多宽。`inset` 是侧栏左边离窗口边缘的距离。
    public static func shown(stored: Double, windowWidth: Double, inset: Double) -> Double {
        let room = windowWidth - inset - detailMinimum
        return max(minimum, min(clamped(stored), room))
    }
}
