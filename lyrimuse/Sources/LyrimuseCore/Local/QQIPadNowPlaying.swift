import Foundation

/// iPad 版 QQ 音乐(iOS 应用跑在 Apple 芯片 Mac 上,bundle id `com.tencent.QQMusic`)报给系统的 Now Playing,在按 QQ 音乐 Mac 版认
/// (`PlayerBundleAliases`)之前整理成真名。
///
/// 它设置里的「锁屏、车载蓝牙歌词」默认开着:每首先报一帧真名(歌名、歌手、专辑齐),开播后改写成 title「歌名 — 歌手」(U+2014,
/// 两边各一个空格)、专辑空、歌手不变,之后整首不再改。title 末尾正好是「 — 」加这一帧歌手的,去掉这一截;专辑空的按记住的同一首
/// 真名那帧补回。关掉开关时不改写,碰不到这一条。
///
/// 轮询、媒体事件流、单问会话和封面几条路都过这里,记住的那份共用;同一帧再过一次结果不变。见 02 章决策 204。
public enum QQIPadNowPlaying {
    public static let bundleID = "com.tencent.QQMusic"

    /// 改写帧里歌名和歌手之间的那一截。
    static let separator = " \u{2014} "

    public struct Names: Equatable, Sendable {
        public var title: String?
        public var artist: String?
        public var album: String?

        public init(title: String?, artist: String?, album: String?) {
            self.title = title
            self.artist = artist
            self.album = album
        }
    }

    private static let lock = NSLock()
    /// 最近一份带专辑的真名。
    nonisolated(unsafe) private static var lastReal: Names?

    /// 是 iPad 版报上来的就整理,别的原样交回。
    public static func normalized(_ names: Names, bundleID: String?) -> Names {
        guard bundleID == Self.bundleID else { return names }
        lock.lock()
        defer { lock.unlock() }
        return normalized(names, memory: &lastReal)
    }

    /// 纯函数(状态由调用方给),selftest 覆盖。
    public static func normalized(_ raw: Names, memory: inout Names?) -> Names {
        guard let title = strippedTitle(raw.title, artist: raw.artist), title != raw.title else {
            if let album = raw.album, !album.isEmpty, let title = raw.title, !title.isEmpty { memory = raw }
            return raw
        }
        var out = raw
        out.title = title
        if raw.album?.isEmpty ?? true, let real = memory, real.title == title, real.artist == raw.artist {
            out.album = real.album
        }
        return out
    }

    /// title 末尾正好是「 — 」加歌手的,去掉这一截;不是这种写法的原样交回。纯函数,selftest 覆盖。
    public static func strippedTitle(_ title: String?, artist: String?) -> String? {
        guard let title, let artist, !artist.isEmpty else { return title }
        let suffix = separator + artist
        guard title.hasSuffix(suffix), title.count > suffix.count else { return title }
        return String(title.dropLast(suffix.count))
    }

    /// 只有歌名、歌手的那几份(封面载荷)去掉改写的那一截,不改状态。
    public static func names(title: String?, artist: String?, bundleID: String?) -> (title: String?, artist: String?) {
        guard bundleID == Self.bundleID else { return (title, artist) }
        return (strippedTitle(title, artist: artist), artist)
    }

    /// 整份 JSON 载荷(单问会话那一路,解出来的快照字段不能改)里的 title / album 换成整理过的,别的键原样留着。
    /// 不是 iPad 版报的、解不开的原样交回。
    public static func normalizedPayload(_ data: Data) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["bundleIdentifier"] as? String == Self.bundleID else { return data }
        let names = normalized(Names(title: object["title"] as? String, artist: object["artist"] as? String,
                                     album: object["album"] as? String), bundleID: Self.bundleID)
        object["title"] = names.title ?? NSNull()
        if let album = names.album { object["album"] = album }
        return (SafeSerialization.jsonData(object)) ?? data
    }

    /// 媒体事件流的合并状态里的 title / album 换成整理过的,别的键原样留着。
    public static func normalizedFields(_ fields: [String: Any]) -> [String: Any] {
        guard fields["bundleIdentifier"] as? String == Self.bundleID else { return fields }
        let names = normalized(Names(title: fields["title"] as? String, artist: fields["artist"] as? String,
                                     album: fields["album"] as? String), bundleID: Self.bundleID)
        var out = fields
        out["title"] = names.title
        out["album"] = names.album
        return out
    }

    /// 测试用:清掉共用状态。
    public static func resetForTesting() {
        lock.lock()
        lastReal = nil
        lock.unlock()
    }
}
