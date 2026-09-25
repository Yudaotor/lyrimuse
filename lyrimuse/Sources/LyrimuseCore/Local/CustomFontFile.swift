import CoreText
import Foundation

/// 导入自定义字体(`CustomFontStore`)里不碰进程级注册的那部分:收不收这个文件、它是不是一份认得出的字体、
/// 一批里失败了几个该怎么跟用户说。
public enum CustomFontFile {
    /// 只收 .ttf / .otf(大小写不限)。.ttc 这类集合文件不收:一份文件里好几个族,族名只取得到第一个。
    public static let allowedExtensions: Set<String> = ["ttf", "otf"]

    public static func isSupported(_ url: URL) -> Bool {
        allowedExtensions.contains(url.pathExtension.lowercased())
    }

    /// 这份文件的字体族名;不是字体(损坏、改了扩展名的别的文件)是 nil。只读文件、不注册。
    public static func familyName(ofFontAt url: URL) -> String? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first
        else { return nil }
        return CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String
    }

    /// 此刻进程里能用的字体族名(系统已装 + 本进程注册的),每次现问 Core Text。
    /// `NSFontManager.availableFontFamilies` / `availableMembers(ofFontFamily:)` 第一次读就缓存,反注册之后
    /// 还说「在」,判断一款导入字体删掉之后还有没有只能问这里。
    public static func availableFamilyNames() -> Set<String> {
        Set((CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? [])
    }

    /// 选中的族名此刻没有字体可用(换机后没带过来 / 删掉了):选择器在名字后面标「未安装」。空串是跟随系统字体,
    /// 永远可用。
    public static func isMissing(_ family: String, available: Set<String>) -> Bool {
        !family.isEmpty && !available.contains(family)
    }

    /// 已导入的文件按族名归并:同一族的 Regular / Bold 等几个文件在列表里只占一行。族名按不区分大小写排序,
    /// 族内文件名排序。
    public static func groupByFamily(_ files: [(fileName: String, family: String)]) -> [(family: String, fileNames: [String])] {
        Dictionary(grouping: files, by: \.family)
            .map { (family: $0.key, fileNames: $0.value.map(\.fileName).sorted()) }
            .sorted { $0.family.localizedCaseInsensitiveCompare($1.family) == .orderedAscending }
    }

    /// 一次导入(可多选)之后给用户的结论。
    public enum ImportSummary: Equatable {
        case allImported
        /// 一个都没进去,且全是读不到文件(没下载到本机、没有读取权限):提示说读不到,不说「不是字体」。
        case allUnreadable
        /// 一个都没进去:多半是选错了文件,提示直接说「不是有效的字体文件」。
        case allFailed
        /// 部分失败:报失败的个数,其余已经导入。
        case someFailed(Int)
    }

    /// `unreadable` 是 `failed` 里读不到文件的那几个。
    public static func importSummary(failed: Int, total: Int, unreadable: Int = 0) -> ImportSummary {
        guard failed > 0 else { return .allImported }
        guard failed >= total else { return .someFailed(failed) }
        return unreadable >= failed ? .allUnreadable : .allFailed
    }
}
