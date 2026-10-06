import Foundation

/// 「最近记录」每行尾部的相对时间(「4分钟前」/ `4 min. ago`)在某种语言下能写成的每一种样子。
///
/// App 拿它量尾格的宽度:尾格按这些写法和两个状态标签里最宽的那个定宽,所有行同宽,左边「第 N 次听」那一列
/// 在哪种语言下都对齐,加新语言不用再去调宽度。行上画相对时间的格式器也从这里取(`formatter(locale:)`),
/// 取样的和画出来的是同一种格式。
///
/// 数字按等宽算(行上的相对时间带 `.monospacedDigit()`):ASCII 数字都换成 0 之后一样的写法只留一个样本,
/// 别的数字体系不换,各留各的。selftest 按 catalog 里的每种语言拿更密的时间间隔核一遍,格式器写得出、
/// 这里却没取到样的写法会红。
public enum RecentRelativeTimeSamples {
    /// 行上画相对时间用的格式器:短单位(`4 min. ago`),语言跟界面走。
    public static func formatter(locale: Locale) -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = locale
        return formatter
    }

    /// 这种语言下每一种写法各一个样本,按第一次出现的顺序。
    public static func samples(locale: Locale) -> [String] {
        let formatter = formatter(locale: locale)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var seen = Set<String>()
        var samples: [String] = []
        for offset in offsets {
            let text = formatter.localizedString(for: now.addingTimeInterval(-offset), relativeTo: now)
            if seen.insert(shape(text)).inserted { samples.append(text) }
        }
        return samples
    }

    /// ASCII 数字都换成 0 之后的样子。只差数字的两种写法,在等宽数字下一样宽。
    public static func shape(_ text: String) -> String {
        String(text.map { ("0"..."9").contains($0) ? "0" : $0 })
    }

    /// 取样的时间间隔(秒):1–59 秒、1–59 分钟、1–23 小时、1–62 天逐个取;往后到 400 天每 15 天取一次,
    /// 每个月数都取得到;年取 1–30。复数形式按个位、十位分类的语言(如俄语),1–30 已经把每一类都走到。
    static let offsets: [TimeInterval] = {
        let minute: TimeInterval = 60, hour: TimeInterval = 3600, day: TimeInterval = 86400
        var offsets: [TimeInterval] = []
        offsets += (1...59).map { TimeInterval($0) }
        offsets += (1...59).map { TimeInterval($0) * minute }
        offsets += (1...23).map { TimeInterval($0) * hour }
        offsets += (1...62).map { TimeInterval($0) * day }
        offsets += stride(from: 77, through: 400, by: 15).map { TimeInterval($0) * day }
        offsets += (1...30).map { TimeInterval($0) * 365.25 * day }
        return offsets
    }()
}
