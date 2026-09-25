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

    /// 一次导入(可多选)之后给用户的结论。
    public enum ImportSummary: Equatable {
        case allImported
        /// 一个都没进去:多半是选错了文件,提示直接说「不是有效的字体文件」。
        case allFailed
        /// 部分失败:报失败的个数,其余已经导入。
        case someFailed(Int)
    }

    public static func importSummary(failed: Int, total: Int) -> ImportSummary {
        guard failed > 0 else { return .allImported }
        return failed >= total ? .allFailed : .someFailed(failed)
    }
}
