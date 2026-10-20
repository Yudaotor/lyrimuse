import Foundation

/// 渠道编辑弹窗「预览」里那条示例报告:一份固定的假数据(不读真实听歌记录,打开就能看),标题、正文按引擎真推出去的
/// 逐字拼 —— 标题见 daily.go 的 dailyDigestTarget、weekly.go 的 weeklyDigestTitle,正文见 digest.go 的 digestBody。
/// 两边对得上靠共用样例 shared/testdata/notify/preview.json(引擎 notifypreview_test.go、selftest 各读一遍),
/// 改了引擎的文案这里跟着改。月报、年报跟周报同一个正文格式,只是标题不同,不单列。见 15 章决策 72。
public enum NotificationPreview {
    public enum Kind: String, CaseIterable, Sendable {
        case daily, weekly

        /// 引擎推这一档时带的事件名(通用 Webhook 的 `event` 字段)。
        public var event: String {
            switch self {
            case .daily: return NotificationRouting.dailyDigest
            case .weekly: return NotificationRouting.weeklyDigest
            }
        }
    }

    /// 同引擎 digestTally:歌手 `sub` 为空;专辑、歌曲 `sub` 是歌手。
    public struct Tally: Equatable, Sendable {
        public let name: String
        public let sub: String
        public let count: Int

        public init(_ name: String, _ sub: String, _ count: Int) {
            self.name = name
            self.sub = sub
            self.count = count
        }

        /// 歌手。
        public init(_ name: String, _ count: Int) { self.init(name, "", count) }
    }

    public struct Stats: Equatable, Sendable {
        public let totalPlays: Int
        public let totalDurationMs: Int
        public let artists: [Tally]
        public let albums: [Tally]
        public let tracks: [Tally]

        public init(totalPlays: Int, totalDurationMs: Int, artists: [Tally], albums: [Tally], tracks: [Tally]) {
            self.totalPlays = totalPlays
            self.totalDurationMs = totalDurationMs
            self.artists = artists
            self.albums = albums
            self.tracks = tracks
        }
    }

    /// 每类 10 条(「每类列出」的上限),按设置截前几条。
    public static func sample(_ kind: Kind) -> Stats {
        switch kind {
        case .daily:
            return Stats(
                totalPlays: 42, totalDurationMs: 9_960_000,
                artists: [Tally("周杰伦", 12), Tally("方大同", 8), Tally("陈绮贞", 5), Tally("孙燕姿", 4), Tally("陶喆", 3),
                          Tally("王菲", 3), Tally("林忆莲", 2), Tally("卢广仲", 2), Tally("Prince", 1), Tally("D'Angelo", 1)],
                albums: [Tally("叶惠美", "周杰伦", 6), Tally("15", "方大同", 5), Tally("还是会寂寞", "陈绮贞", 4),
                         Tally("未完成", "孙燕姿", 3), Tally("黑色柳丁", "陶喆", 3), Tally("只爱陌生人", "王菲", 2),
                         Tally("范特西", "周杰伦", 2), Tally("野花", "林忆莲", 2), Tally("100 种生活", "卢广仲", 2),
                         Tally("橙月", "方大同", 1)],
                tracks: [Tally("晴天", "周杰伦", 4), Tally("春风吹", "方大同", 3), Tally("越洋电话", "陈绮贞", 3),
                         Tally("遇见", "孙燕姿", 2), Tally("爱很简单", "陶喆", 2), Tally("红豆", "王菲", 2),
                         Tally("以父之名", "周杰伦", 2), Tally("至少还有你", "林忆莲", 1), Tally("我爱你", "卢广仲", 1),
                         Tally("特别的人", "方大同", 1)])
        case .weekly:
            return Stats(
                totalPlays: 286, totalDurationMs: 64_320_000,
                artists: [Tally("方大同", 61), Tally("周杰伦", 48), Tally("Prince", 33), Tally("陈绮贞", 27), Tally("孙燕姿", 22),
                          Tally("陶喆", 18), Tally("D'Angelo", 15), Tally("王菲", 12), Tally("林忆莲", 9), Tally("卢广仲", 7)],
                albums: [Tally("JTW 西游记", "方大同", 29), Tally("叶惠美", "周杰伦", 21), Tally("For You", "Prince", 17),
                         Tally("还是会寂寞", "陈绮贞", 14), Tally("15", "方大同", 12), Tally("未完成", "孙燕姿", 11),
                         Tally("Voodoo", "D'Angelo", 10), Tally("黑色柳丁", "陶喆", 9), Tally("范特西", "周杰伦", 8),
                         Tally("只爱陌生人", "王菲", 7)],
                tracks: [Tally("NMW", "方大同", 11), Tally("晴天", "周杰伦", 9), Tally("For You", "Prince", 8),
                         Tally("越洋电话", "陈绮贞", 7), Tally("春风吹", "方大同", 7),
                         Tally("Untitled (How Does It Feel)", "D'Angelo", 6), Tally("遇见", "孙燕姿", 6),
                         Tally("爱很简单", "陶喆", 5), Tally("红豆", "王菲", 5), Tally("至少还有你", "林忆莲", 4)])
        }
    }

    /// 日报按「今天 22 点推今天那期」的标题;周报是 `now` 所在周的上一周(周一到周日,同引擎 ListenBrainz 源)。
    public static func title(_ kind: Kind, now: Date, calendar: Calendar = .current) -> String {
        switch kind {
        case .daily:
            return "🎧 今日听歌报告（\(monthDay(now, calendar))）"
        case .weekly:
            let today = calendar.startOfDay(for: now)
            // weekday:周日 1 … 周六 7;离本周一几天。
            let sinceMonday = (calendar.component(.weekday, from: today) + 5) % 7
            let monday = calendar.date(byAdding: .day, value: -sinceMonday, to: today) ?? today
            let from = calendar.date(byAdding: .day, value: -7, to: monday) ?? monday
            let end = calendar.date(byAdding: .day, value: -1, to: monday) ?? monday
            return "🎵 上周听歌小结（\(monthDay(from, calendar))~\(monthDay(end, calendar))）"
        }
    }

    private static func monthDay(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.month, .day], from: date)
        return String(format: "%02d-%02d", c.month ?? 0, c.day ?? 0)
    }

    /// 同引擎 digestBody:每类截前 `topN` 条;某类只有一条时不列(排名没意义),`topN` 是 1 时照列。
    public static func body(_ stats: Stats, topN: Int) -> String {
        let n = DigestTopN.resolved(topN)
        var out = "共播放 \(stats.totalPlays) 次"
        if stats.totalDurationMs > 0 {
            let minutes = stats.totalDurationMs / 60000
            out += minutes >= 60 ? " · 约 \(minutes / 60) 小时 \(minutes % 60) 分" : " · 约 \(minutes) 分"
        }
        out += "\n"
        func section(_ heading: String, _ list: [Tally]) {
            let top = Array(list.prefix(n))
            guard top.count > 1 || (top.count == 1 && n == 1) else { return }
            out += "\n\(heading)：\n"
            for (i, t) in top.enumerated() {
                out += t.sub.isEmpty ? "\(i + 1). \(t.name)（\(t.count)）\n" : "\(i + 1). \(t.sub) - \(t.name)（\(t.count)）\n"
            }
        }
        section("Top 歌手", stats.artists)
        section("Top 专辑", stats.albums)
        section("Top 歌曲", stats.tracks)
        while out.hasSuffix("\n") { out.removeLast() }
        return out
    }

    /// 通用 Webhook 会 POST 的 JSON(引擎 notify.go 的 webhookPayload),字段顺序、转义同 Go 的 json.Marshal,
    /// 只是这里分行缩进给人看(真发出去的是一行)。
    public static func webhookJSON(event: String, title: String, body: String, sentAt: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(identifier: "UTC")
        let fields: [(String, String)] = [("app", "lyrimuse"), ("event", event), ("title", title), ("body", body),
                                          ("sent_at", iso.string(from: sentAt))]
        let lines = fields.map { "  \(jsonString($0.0)): \(jsonString($0.1))" }
        return "{\n" + lines.joined(separator: ",\n") + "\n}"
    }

    /// Go encoding/json 的字符串转义:引号、反斜杠、\n \r \t,其余控制字符 \u00XX,< > & 也转(Go 默认的 HTML 安全转义)。
    static func jsonString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "<", ">", "&", "\u{2028}", "\u{2029}": out += String(format: "\\u%04x", u.value)
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}
