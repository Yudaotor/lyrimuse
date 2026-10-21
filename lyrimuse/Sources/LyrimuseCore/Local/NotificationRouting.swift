import Foundation

/// 每档听歌报告推到哪些渠道:config.json 的 `notification_routes`(事件 → 渠道 id 列表,引擎 notifychannel.go 的
/// routedNotifyChannels)。**没有这个事件的键 = 推到全部启用、填齐的渠道**;列出来的渠道还得启用、填齐才推,列表里
/// 指向已删除渠道的 id 引擎直接跳过。
///
/// 界面上(推送提醒页「听歌报告」卡每档行尾的下拉)只在有两个以上渠道时出现。这里管路由跟着渠道增删怎么变,见 15 章决策 72、76:
///   - 新加的渠道四档都推:还没选过渠道的那几档(没有键 = 全部渠道)本来就包括它,选过的几档把它的 id 加到末尾。
///     不想推哪一档再到下拉里取消。
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

    /// 加一个新渠道(还不在 `channels` 里),四档都推它。见类型头注。
    public static func adding(_ channel: NotificationChannel, to channels: [NotificationChannel], routes: Routes)
        -> (channels: [NotificationChannel], routes: Routes) {
        var routes = routes
        for event in digestEvents where routes[event]?.contains(channel.id) == false {
            routes[event]?.append(channel.id)
        }
        return (channels + [channel], routes)
    }

    /// 改一个已有的渠道:原地替换,路由不动。
    public static func updating(_ channel: NotificationChannel, in channels: [NotificationChannel]) -> [NotificationChannel] {
        channels.map { $0.id == channel.id ? channel : $0 }
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

    /// 这一档勾着的渠道一个都推不了(都停用了或没填齐):引擎那边这一档整个不推(同 routedNotifyChannels),下拉上要说出来。
    public static func noneDeliverable(event: String, channels: [NotificationChannel], routes: Routes) -> Bool {
        let ids = selectedIDs(event: event, channels: channels, routes: routes)
        return !channels.isEmpty && !channels.contains { ids.contains($0.id) && $0.enabled && $0.isComplete }
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
}

/// 四档听歌报告的推送时间(推送提醒页「推送时间」,features.json 的 `digest_push_time`,"HH:MM",引擎 digestschedule.go)。
/// 四档共用,按这台 Mac 当前的时区算,换了时区跟着变。每日报告:推送时间在 `sameDayFrom`(12:00)及以后推当天,在那之前推
/// 前一天一整天;每周 / 每月 / 年度:周期结束后的第一个推送时间推。见 15 章决策 77。
public enum DigestPushTime {
    public static let defaultMinutes = 22 * 60
    public static let sameDayFrom = 12 * 60

    /// 缺失、写坏了按默认(同引擎 resolveDigestPushTime)。
    public static func resolved(_ text: String?) -> Int {
        text.flatMap(minutes(fromClock:)) ?? defaultMinutes
    }

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

    /// 每日报告推的是当天(到推送那一刻为止)还是前一天一整天。
    public static func dailyCoversSameDay(_ minutes: Int) -> Bool { minutes >= sameDayFrom }

    /// 时区写法:「GMT+8 · Asia/Shanghai」,不随界面语言变。
    public static func timeZoneText(_ zone: TimeZone, at date: Date = Date()) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let h = abs(seconds) / 3600, m = abs(seconds) % 3600 / 60
        let offset = "GMT" + (seconds < 0 ? "-" : "+") + (m == 0 ? "\(h)" : String(format: "%d:%02d", h, m))
        return offset + " · " + zone.identifier
    }
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
