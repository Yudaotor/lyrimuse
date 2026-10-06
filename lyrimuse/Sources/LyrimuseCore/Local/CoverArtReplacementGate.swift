import Foundation
import ImageIO

/// 系统 Now Playing 那份封面「像不像一张封面」的判定,两处用它,判据只在这里:
/// - 展示:要不要换成引擎缓存里的高清替代(`reason` / `accepts`,`PlaybackCoordinator.refreshHighResCover`);
/// - 交给引擎:能不能当这首歌的设备封面(`isUsableDeviceArtwork`,`PlaybackStatePublisher.artworkForEngine`)。
///   引擎拿到就用、不再自己判。
///
/// 形状判据针对播放器上报的根本不是专辑图的情形:YouTube Music 的 MV 经 MediaSession 上报的是 320×180 的
/// 视频缩略图,竖屏短视频、横幅 banner 同理;正经封面自带的小幅不规则(带留白边框)落在 15% 容差之内。
/// 放在 LyrimuseCore 是为了让 selftest 能直接断言(PlaybackCoordinator 在 App target 里,自测进程碰不到)。
public enum CoverArtReplacementGate {
    /// 触发替代的理由。两条的后续接受判据不同,见 `accepts`。
    public enum Reason: Equatable, Sendable {
        /// 系统那份太小(宽 ≤ 阈值):网易云客户端 100×100、QQ 音乐客户端 300×300 那一类。
        case lowRes
        /// 系统那份不是封面的形状:播放器上报的根本不是专辑图(YouTube Music MV 给的 16:9 视频缩略图)。
        case notCoverShaped
        /// 这个播放器从不往系统里报封面(`systemNeverHasArtwork`),或者这一首它只推了登记在案的占位图
        /// (`KnownPlaceholderArtwork`,没当封面用,系统那份是空的或上一首留下的):缓存里匹配到的那张就是唯一能显示的。
        case playerHasNoArtwork
    }

    /// 这个播放器的系统会话里从来没有封面。Kaset:播放中把会话交给 WebKit,那份不带图;它自己发的只有歌名歌手。
    /// 对它们「没有图就显示占位音符」那条不成立 —— 等不到系统的图,整首都会是占位音符。
    public static func systemNeverHasArtwork(bundleID: String?) -> Bool {
        bundleID == PlaybackPlayer.kaset.bundleIdentifier
    }

    /// 长宽比偏离正方形的容差。
    public static let maxAspectSkew = 0.15

    /// 交给引擎当设备封面的最短边下限。64 挡的是没有封面时的 1×1 / 几像素占位图,放行浏览器
    /// MediaSession 常见的 120×120(Arc / Edge 播 Apple Music 网页版实测就是这一档,是真封面)。
    public static let deviceArtworkMinEdge = 64

    /// 这个尺寸像不像一张封面:`|宽-高| / 长边 ≤ 15%`。零尺寸不算。
    public static func isCoverShaped(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let longer = Double(max(width, height))
        return Double(abs(width - height)) / longer <= maxAspectSkew
    }

    /// 这份系统封面能不能交给引擎当设备封面:最短边够 `deviceArtworkMinEdge`,且是封面的形状。
    /// 引擎拿到设备封面就用、之后不再换源,不像封面的图交过去会一直挂在那首歌上。
    public static func isUsableDeviceArtwork(width: Int, height: Int) -> Bool {
        min(width, height) >= deviceArtworkMinEdge && isCoverShaped(width: width, height: height)
    }

    /// 只读图头取像素宽高(CGImageSource,不解码整图);没有图 / 读不出来返回 (0, 0)。
    public static func pixelSize(of data: Data?) -> (width: Int, height: Int) {
        guard let data,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return (0, 0) }
        return (w, h)
    }

    /// 系统那份封面要不要找替代。nil = 不找:没有图(该显示占位音符,不该悄悄换成缓存匹配出来
    /// 的另一张;从不报封面的播放器除外,见 `systemNeverHasArtwork`),或者系统那份本来就是一张够大的
    /// 方形封面(Apple Music 之类,权威图不动)。形状先于尺寸判:一张 1280×720 的视频帧再大也不是封面。
    /// `systemArtworkIsPlaceholder`:这一首播放器推的是登记在案的占位图(见 03 章决策 32)。这时系统那份要么是空的、
    /// 要么是留着的上一首的封面,尺寸都不作数,一律按「播放器没有封面」找替代。
    public static func reason(width: Int, height: Int, lowResThreshold: Int,
                              systemNeverHasArtwork: Bool = false, systemArtworkIsPlaceholder: Bool = false) -> Reason? {
        if systemArtworkIsPlaceholder { return .playerHasNoArtwork }
        guard width > 0, height > 0 else {
            return systemNeverHasArtwork ? .playerHasNoArtwork : nil
        }
        if !isCoverShaped(width: width, height: height) { return .notCoverShaped }
        if width <= lowResThreshold { return .lowRes }
        return nil
    }

    /// 缓存里那张下载回来之后值不值得换上:
    /// - `lowRes`:只有替代图确实比系统那份宽才换(缓存里可能存着一张同样小的图,白换)。
    /// - `notCoverShaped`:换的是**形状**不是分辨率,替代图自己是张方形封面就换 —— 不能再拿
    ///   「比系统那份宽」当门槛,否则 1280×720 的视频帧会把一张 600×600 的真封面挡在外面。
    /// - `playerHasNoArtwork`:没有系统那份可比,替代图是张方形封面就换。
    public static func accepts(candidateWidth: Int, candidateHeight: Int,
                               systemWidth: Int, reason: Reason) -> Bool {
        switch reason {
        case .lowRes:
            return candidateWidth > systemWidth
        case .notCoverShaped, .playerHasNoArtwork:
            return isCoverShaped(width: candidateWidth, height: candidateHeight)
        }
    }
}
