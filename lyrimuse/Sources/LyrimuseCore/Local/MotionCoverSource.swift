import Foundation

/// 动态封面从哪几处找(设置 › 歌词显示 › 歌词窗口 › 封面,「动态封面」下面那两项,可多选,至少留一个):Apple Music 一支,
/// 其余几支(QQ 音乐、网易云、酷狗本机)合成一项。rawValue 跟引擎 `motionCoverSourceApple` / `motionCoverSourceOther` 逐字相同,
/// 存进 features.json 的 `motion_cover_sources`。引擎按它跳过关掉的那几支;App 按地址的来源再筛一遍,改了当场生效,不等引擎重核。
/// 见 03 章决策 71。
public enum MotionCoverSource: String, CaseIterable, Sendable {
    case apple
    case other

    public static let all = Set(allCases)

    /// 一段动态封面地址是哪一处的:QQ 音乐、网易云、酷狗的是各自的自定义 scheme,其余都是 Apple 的 HLS master。
    public init(master: URL) {
        switch master.scheme {
        case QQMotionCover.scheme, NeteaseMotionCover.scheme, KugouMotionCover.scheme: self = .other
        default: self = .apple
        }
    }

    /// features.json 里那份列表 → 集合。缺失 / 一个都认不得时两处都找(同引擎 `resolveMotionCoverSources`)。
    public static func resolve(_ names: [String]?) -> Set<MotionCoverSource> {
        let out = Set((names ?? []).compactMap(MotionCoverSource.init(rawValue:)))
        return out.isEmpty ? all : out
    }

    /// 落盘的写法:两处都找时不写(nil),否则按 allCases 的顺序。
    public static func fileValue(_ sources: Set<MotionCoverSource>) -> [String]? {
        sources == all || sources.isEmpty ? nil : allCases.filter(sources.contains).map(\.rawValue)
    }
}

extension Set where Element == MotionCoverSource {
    /// 勾上 / 取消一处;最后一处取消不掉,原样返回。
    public func toggling(_ source: MotionCoverSource) -> Set<MotionCoverSource> {
        var next = self
        if next.contains(source) { next.remove(source) } else { next.insert(source) }
        return next.isEmpty ? self : next
    }
}
