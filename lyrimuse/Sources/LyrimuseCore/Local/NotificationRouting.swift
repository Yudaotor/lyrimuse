import Foundation

/// 每档听歌报告推到哪些渠道:config.json 的 `notification_routes`(事件 → 渠道 id 列表,引擎 notifychannel.go 的
/// routedNotifyChannels)。**没有这个事件的键 = 推到全部启用、填齐的渠道**;列出来的渠道还得启用、填齐才推,列表里
/// 指向已删除渠道的 id 引擎直接跳过。
///
/// 界面上(推送提醒页「听歌报告」卡每档行尾的下拉)只在有两个以上渠道时出现。这里管路由跟着渠道增删怎么变,见 15 章决策 72:
///   - 新加渠道之前,四档里还没有键的(= 全部渠道)先落成「现有全部渠道 id」—— 否则「没有键」的语义会让新渠道自动
///     被四档用上;新渠道设成默认的,把它的 id 加进四档;不设默认的不进任何一档。加的是第一个渠道时什么都不写。
///   - 删渠道时从各档拿掉它的 id,某档因此空了就删掉这个键(回到全部渠道)。
///   - 勾选全部渠道时删掉这个键,不留一份跟「全部」等价的列表;至少要勾一个。
public enum NotificationRouting {
    public typealias Routes = [String: [String]]

    /// 四档听歌报告的事件名,跟引擎 notifychannel.go 的 notifyEventDaily / Weekly / Monthly / Yearly 逐字相同。
    public static let dailyDigest = "daily_digest"
    public static let weeklyDigest = "weekly_digest"
    public static let monthlyDigest = "monthly_digest"
    public static let yearlyDigest = "yearly_digest"
    public static let digestEvents = [dailyDigest, weeklyDigest, monthlyDigest, yearlyDigest]

    /// config.json 里的 `notification_routes`;没有这个键、或形状不对时为空。列表里不是字符串的项跳过。
    public static func routes(fromConfig raw: [String: Any]) -> Routes {
        guard let obj = raw["notification_routes"] as? [String: Any] else { return [:] }
        var out: Routes = [:]
        for (event, value) in obj {
            guard let items = value as? [Any] else { continue }
            out[event] = items.compactMap { $0 as? String }
        }
        return out
    }

    /// 选渠道这件事要不要出现在界面上:两个以上渠道才有得选。
    public static func showsChoice(channelCount: Int) -> Bool { channelCount >= 2 }

    /// 加一个新渠道(还不在 `channels` 里)。见类型头注。新渠道设成默认时,别的渠道的默认去掉。
    public static func adding(_ channel: NotificationChannel, to channels: [NotificationChannel], routes: Routes)
        -> (channels: [NotificationChannel], routes: Routes) {
        var routes = routes
        if !channels.isEmpty {
            let existing = channels.map(\.id)
            for event in digestEvents where routes[event] == nil {
                routes[event] = existing
            }
            if channel.isDefault {
                for event in digestEvents where routes[event]?.contains(channel.id) == false {
                    routes[event]?.append(channel.id)
                }
            }
        }
        return (makingDefaultUnique(channels + [channel], keeping: channel), routes)
    }

    /// 改一个已有的渠道:原地替换;它设成了默认就去掉别的渠道的默认。路由不动。
    public static func updating(_ channel: NotificationChannel, in channels: [NotificationChannel]) -> [NotificationChannel] {
        makingDefaultUnique(channels.map { $0.id == channel.id ? channel : $0 }, keeping: channel)
    }

    /// 删一个渠道:从各档路由里拿掉它的 id,某档因此空了就删掉这个键(回到全部渠道)。
    public static func removing(id: String, from channels: [NotificationChannel], routes: Routes)
        -> (channels: [NotificationChannel], routes: Routes) {
        var routes = routes
        for (event, ids) in routes where ids.contains(id) {
            let rest = ids.filter { $0 != id }
            routes[event] = rest.isEmpty ? nil : rest
        }
        return (channels.filter { $0.id != id }, routes)
    }

    /// 这一档此刻勾着哪些渠道:没有键 = 全部;有键的取列表里还在的那几个。
    public static func selectedIDs(event: String, channels: [NotificationChannel], routes: Routes) -> Set<String> {
        let all = Set(channels.map(\.id))
        guard let ids = routes[event] else { return all }
        return all.intersection(ids)
    }

    /// 勾 / 取消一个渠道。取消的是最后一个勾着的就不动(至少保留一个);勾满了删掉这个键。列表按渠道顺序写。
    public static func toggling(_ id: String, event: String, channels: [NotificationChannel], routes: Routes) -> Routes {
        var selected = selectedIDs(event: event, channels: channels, routes: routes)
        if selected.contains(id) {
            guard selected.count > 1 else { return routes }
            selected.remove(id)
        } else {
            selected.insert(id)
        }
        var routes = routes
        let ordered = channels.map(\.id).filter(selected.contains)
        routes[event] = ordered.count == channels.count ? nil : ordered
        return routes
    }

    /// 下拉上那几个字。
    public enum Label: Equatable, Sendable {
        /// 「全部渠道」
        case all
        /// 勾着的渠道名用「、」连起来
        case names(String)
        /// 放不下时「X 等 N 个」
        case firstOfMany(first: String, count: Int)
    }

    /// `selectedNames` 按渠道顺序;连起来超过 `maxLength` 个字时写成「第一个 等 N 个」。
    public static func label(selectedNames: [String], total: Int, maxLength: Int = 12) -> Label {
        if selectedNames.count >= total || selectedNames.isEmpty { return .all }
        let joined = selectedNames.joined(separator: "、")
        if selectedNames.count == 1 || joined.count <= maxLength { return .names(joined) }
        return .firstOfMany(first: selectedNames[0], count: selectedNames.count)
    }

    private static func makingDefaultUnique(_ channels: [NotificationChannel], keeping channel: NotificationChannel) -> [NotificationChannel] {
        guard channel.isDefault else { return channels }
        return channels.map { c in
            var c = c
            c.isDefault = c.id == channel.id
            return c
        }
    }
}

/// 推送提醒的静默时段(features.json 的 `notification_quiet_hours`,引擎 notifyquiet.go):这段时间里到点的听歌报告
/// 等静默结束再推。时刻是本地时间零点起的分钟数,文件里写成 "HH:MM"。跨午夜(23:00–08:00)按「开始之后或结束之前」算,
/// 左闭右开;开始和结束一样当成没有静默。默认关、23:00–08:00。见 15 章决策 72。
public struct NotificationQuietHours: Equatable, Sendable {
    public var enabled: Bool
    public var start: Int
    public var end: Int

    public static let defaultStart = 23 * 60
    public static let defaultEnd = 8 * 60

    public init(enabled: Bool = false, start: Int = NotificationQuietHours.defaultStart, end: Int = NotificationQuietHours.defaultEnd) {
        self.enabled = enabled
        self.start = start
        self.end = end
    }

    /// features.json 里那一段的形状,跟引擎 notifyQuietHoursFile 逐字段对应。
    public struct File: Codable, Equatable, Sendable {
        public var enabled: Bool?
        public var start: String?
        public var end: String?

        public init(enabled: Bool?, start: String?, end: String?) {
            self.enabled = enabled
            self.start = start
            self.end = end
        }
    }

    /// 段缺失 = 关、默认时刻;时刻写坏了按默认时刻(同引擎 resolveNotifyQuietHours)。
    public init(file: File?) {
        self.init(enabled: file?.enabled ?? false,
                  start: file?.start.flatMap(Self.minutes(fromClock:)) ?? Self.defaultStart,
                  end: file?.end.flatMap(Self.minutes(fromClock:)) ?? Self.defaultEnd)
    }

    public var file: File { File(enabled: enabled, start: Self.clockText(start), end: Self.clockText(end)) }

    /// "HH:MM"(24 小时制,补零)。
    public static func clockText(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    /// "HH:MM"(小时可以是一位)→ 分钟数;多余的字、越界的不认(同引擎 parseClockMinutes)。
    public static func minutes(fromClock text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    /// 这一分钟(零点起)在不在静默里。
    public func isActive(minuteOfDay m: Int) -> Bool {
        guard enabled, start != end else { return false }
        return start < end ? (m >= start && m < end) : (m >= start || m < end)
    }

    /// 副标题「HH:MM 到 HH:MM 之间要推的，等到 HH:MM 再推」的两个时刻。
    public var startText: String { Self.clockText(start) }
    public var endText: String { Self.clockText(end) }
}

/// 听歌报告「每类列出」:歌手、专辑、歌曲各列前几名(features.json 的 `digest_top_n`,引擎 digest.go 的 digestTopN)。
/// 四档共用。见 15 章决策 72。
public enum DigestTopN {
    public static let defaultValue = 3
    public static let range = 1...10

    /// 缺失按默认,越界夹回(同引擎 resolveDigestTopN)。
    public static func resolved(_ raw: Int?) -> Int {
        guard let raw else { return defaultValue }
        return min(max(raw, range.lowerBound), range.upperBound)
    }
}
