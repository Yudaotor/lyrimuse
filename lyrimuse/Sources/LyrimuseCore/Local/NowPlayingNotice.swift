import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 「换歌时显示通知」的判据、文案和封面文件,纯函数。投递、授权、等封面在 App 侧 `NowPlayingNotifier`。
public enum NowPlayingNotice {
    /// 开始盯之后这么久以内第一次看到的歌,是启动前就在放的那首,不算换歌。
    public static let startupGrace: TimeInterval = 10

    /// 这一刻该不该给这首发通知。`isFirstSighting` = 开始盯以来第一次看到歌名,`sinceStart` 是那一刻离开始盯
    /// 过了多久。只在放着、不是广告或电台口白、Lyrimuse 自己不在前台时发。
    public static func shouldAnnounce(
        enabled: Bool, title: String, isPlaying: Bool, isBreak: Bool, appIsActive: Bool,
        isFirstSighting: Bool, sinceStart: TimeInterval
    ) -> Bool {
        guard enabled, !title.isEmpty, isPlaying, !isBreak, !appIsActive else { return false }
        return !(isFirstSighting && sinceStart < startupGrace)
    }

    /// 通知正文:「歌手 — 专辑」。专辑空着、就是歌名、或是同名单曲 / EP(「歌名 - Single」)时只写歌手。
    public static func body(title: String, artist: String, album: String) -> String {
        let title = title.trimmingCharacters(in: .whitespaces)
        let artist = artist.trimmingCharacters(in: .whitespaces)
        let album = album.trimmingCharacters(in: .whitespaces)
        let albumRepeatsTitle = album.isEmpty
            || album.caseInsensitiveCompare(title) == .orderedSame
            || album.lowercased().hasPrefix(title.lowercased() + " - ")
        return [artist, albumRepeatsTitle ? "" : album].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    /// 通知附哪一张封面。
    public enum CoverPick: String, Sendable {
        /// 这首的高清替代。
        case highRes
        /// 系统那份。
        case system
        /// 不附图。
        case noCover
        /// 还没定,接着等。
        case wait
    }

    /// 跟界面上显示的是同一张:这首的高清替代优先,没有才用系统那份;界面会换成高清替代时先等它。
    /// - Parameters:
    ///   - highResArrived: 换歌之后这首的高清替代到了。
    ///   - systemSettled: 换歌之后系统那份定案了(取到这首的图,或判定这首没有图)。
    ///   - systemHasImage: 系统那份此刻有图。
    ///   - seeksHighRes: 界面会把系统那份换成高清替代:太小、不是封面的形状,或播放器从不报封面(Kaset)。
    ///   - timedOut: 等封面的时限到了,手上有什么用什么。
    public static func coverPick(highResArrived: Bool, systemSettled: Bool, systemHasImage: Bool,
                                 seeksHighRes: Bool, timedOut: Bool) -> CoverPick {
        if highResArrived { return .highRes }
        if systemSettled, !seeksHighRes { return systemHasImage ? .system : .noCover }
        guard timedOut else { return .wait }
        return systemSettled && systemHasImage ? .system : .noCover
    }

    /// 通知封面的最长边(像素)。通知里的图显示得不大,高清替代的原图档动辄一两千像素。
    public static let artworkMaxPixel = 600

    /// 把封面写成 JPEG 文件,最长边超过 `artworkMaxPixel` 的等比缩到这个尺寸。写不成返回 false。
    /// 缩放选项只在超过时才给:ImageIO 的这个选项也会把小图放大到这个尺寸。
    public static func writeArtworkJPEG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        if max(image.width, image.height) > artworkMaxPixel {
            options[kCGImageDestinationImageMaxPixelSize] = artworkMaxPixel
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
