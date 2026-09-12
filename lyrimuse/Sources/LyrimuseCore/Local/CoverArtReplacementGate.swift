import Foundation

/// 「系统 Now Playing 那份封面要不要换成 collector 缓存里的高清替代」的纯判定。
///
/// 2026-09-08 从 `PlaybackCoordinator.refreshHighResCover` 里拆出来:原来那里只有一个判据
/// (宽 ≤ 300px 就找替代),用户报 YouTube Music 的 MV 条目「封面是视频的第一帧」——Safari 经
/// MediaSession 上报的 artwork 就是 **320×180 的视频缩略图**,宽 320 刚好越过 300 的门槛,
/// 被当成「够大的正经封面」原样显示,再被展示面的 scaledToFill 裁成方块。collector 那头
/// (`deviceartwork.go`)一直有 15% 的长宽比容差、把这张图拒收了,所以网页显示的是真封面,
/// 只有本机 App 显示视频帧 —— 两端口径不一致才是根因。这里把形状判据补齐,容差跟 collector
/// 逐字一致;放进 LyrimuseCore 是为了让 selftest 能直接断言(PlaybackCoordinator 在 App
/// target 里,自测进程碰不到)。
///
/// 通用性:任何播放器上报「不是方形」的封面都走这条 —— 视频网站的 16:9 缩略图、竖屏短视频、
/// 横幅 banner;正经封面自带的小幅不规则(带留白边框)落在 15% 容差之内不受影响。
public enum CoverArtReplacementGate {
    /// 触发替代的理由。两条的后续接受判据不同,见 `accepts`。
    public enum Reason: Equatable, Sendable {
        /// 系统那份太小(宽 ≤ 阈值):网易云客户端 100×100、QQ 音乐客户端 300×300 那一类。
        case lowRes
        /// 系统那份不是封面的形状:播放器上报的根本不是专辑图(YouTube Music MV 给的 16:9 视频缩略图)。
        case notCoverShaped
    }

    /// 长宽比偏离正方形的容差,跟 collector `deviceArtworkMaxAspectSkew`(deviceartwork.go)
    /// 逐字一致 —— 两端对「这像不像一张封面」的回答必须相同,否则又会出现网页对、App 错的分叉。
    public static let maxAspectSkew = 0.15

    /// 这个尺寸像不像一张封面:`|宽-高| / 长边 ≤ 15%`。零尺寸不算。
    public static func isCoverShaped(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let longer = Double(max(width, height))
        return Double(abs(width - height)) / longer <= maxAspectSkew
    }

    /// 系统那份封面要不要找替代。nil = 不找:没有图(该显示占位音符,不该悄悄换成缓存匹配出来
    /// 的另一张),或者系统那份本来就是一张够大的方形封面(Apple Music 之类,权威图不动)。
    /// 形状先于尺寸判:一张 1280×720 的视频帧再大也不是封面。
    public static func reason(width: Int, height: Int, lowResThreshold: Int) -> Reason? {
        guard width > 0, height > 0 else { return nil }
        if !isCoverShaped(width: width, height: height) { return .notCoverShaped }
        if width <= lowResThreshold { return .lowRes }
        return nil
    }

    /// 缓存里那张下载回来之后值不值得换上:
    /// - `lowRes`:只有替代图确实比系统那份宽才换(缓存里可能存着一张同样小的图,白换)。
    /// - `notCoverShaped`:换的是**形状**不是分辨率,替代图自己是张方形封面就换 —— 不能再拿
    ///   「比系统那份宽」当门槛,否则 1280×720 的视频帧会把一张 600×600 的真封面挡在外面。
    public static func accepts(candidateWidth: Int, candidateHeight: Int,
                               systemWidth: Int, reason: Reason) -> Bool {
        switch reason {
        case .lowRes:
            return candidateWidth > systemWidth
        case .notCoverShaped:
            return isCoverShaped(width: candidateWidth, height: candidateHeight)
        }
    }
}
