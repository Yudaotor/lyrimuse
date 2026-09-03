import AppKit
import LyrimuseCore

/// 网页播放器平台(YouTube Music / Spotify 网页版)的图标。
///
/// 2026-09-03 从 `SettingsView.swift` 的 `PlayerSettingsTab` 里整块搬出来 —— 它当时是那个
/// **private** 结构体上的一组 static,而引导页「选择播放器」那一格 YouTube Music 要用同一张图
/// (用户要求"这里也给我加上 youtube music 的选项"),private 类型外面够不着。
///
/// 一度想只把查表函数放开成 internal 了事,行不通:`youtubeMusicIcon` 依赖同文件里的
/// `whiteFilledCutouts`(垫白那一步,理由见它的头注),拆开放会把"这张图该长什么样"这件事
/// 劈成两处。整块搬走之后,两个宿主读同一份实现。
@MainActor
enum WebPlatformIcon {
    /// 平台图标——YouTube Music 是个网站,没有 `.app` 可以像浏览器那样用 AppIconResolver
    /// 取真图标。2026-08-31 用户要求用真实图标,跟 lastfmBadgeImage/listenBrainzBadgeImage
    /// 同一个既有先例:素材取自 Simple Icons(CC0 授权、专门收录给第三方集成场景用的品牌
    /// 图标合集,矢量描摹自官方标志,不是截图抠像素),PNG 由 build.sh 拷进
    /// Contents/Resources/,用 Bundle.main(不是 Bundle.module)加载——理由见 L10n.swift
    /// 顶部注释、AccountLinkingTab.swift 里 lastfmBadgeImage 的同款写法。以后新增别的网页
    /// 平台,照这个模式再加一份资源 + 一个 case 就行。
    /// ⚠️ 这里的 key 必须跟 `BrowserPositionProbe.supportedPlatforms` 里的 `id` 一字不差 ——
    /// 对不上不会编译报错,只表现成"那张平台卡的图标位空着"。
    static func image(_ platformID: String) -> NSImage? {
        switch platformID {
        case "youtubeMusic": return youtubeMusicIcon
        case "spotifyWeb": return spotifyIcon
        default: return nil
        }
    }

    /// ⚠️ 图片取自本机 `/Applications/Spotify.app` 的 `AppIcon.icns`(2026-09-01 用 sips 转成
    /// 1024×1024 PNG),跟 `YouTubeMusicIcon.png` 同规格同来路 —— 不去网上抓品牌资源。
    private static let spotifyIcon: NSImage = {
        guard let path = Bundle.main.path(forResource: "SpotifyIcon", ofType: "png"),
              let image = NSImage(contentsOfFile: path)
        else {
            return NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil) ?? NSImage()
        }
        return image
    }()

    private static let youtubeMusicIcon: NSImage = {
        guard let path = Bundle.main.path(forResource: "YouTubeMusicIcon", ofType: "png"),
              let image = NSImage(contentsOfFile: path)
        else {
            // 没走 build.sh 打包时(直接 swift build 跑)找不到资源,退回 SF Symbol,
            // 别让图标位裸奔成空白——跟 lastfmBadgeImage/listenBrainzBadgeImage 同一个兜底。
            // (这个兜底本身也有下面那条镂空问题——`play.circle.fill` 的三角同样是抠掉的——
            //  但它只在开发时直接 `swift build` 跑才会走到,发布包里恒不触发,不为它加复杂度。)
            return whiteFilledCutouts(image: nil)
        }
        return whiteFilledCutouts(image: image)
    }()

    /// 把 Simple Icons 那份 YouTube Music 素材里**镂空**的部分垫成白色(2026-09-02 用户要求:
    /// 「不要是这种会随外观是白天模式还是黑色模式变里面的颜色…固定为白色」)。
    ///
    /// 病根不在代码而在素材:Simple Icons 是**单色**图标集,整张图只有一个红色实心圆是
    /// 不透明的,中间那圈细白环和播放三角**是抠掉的透明像素**(实测 alpha 恒为 0),所以显示成
    /// 什么颜色完全取决于背后是什么——浅色外观下卡片底是浅的,看着就是白的;深色外观下卡片底
    /// 是深的,那两处就跟着变深(用户截图里那个"深色三角"就是这么来的)。跟 SwiftUI 的着色、
    /// 模板图(`isTemplate`)、`.foregroundStyle` 都无关,**改视图那一侧改不掉**。
    ///
    /// 做法:在图标下面垫一个纯白圆,红圆自己会把多余的白盖住,只剩镂空处透出白色。
    /// ⚠️ 白圆必须**小于红圆、大于镂空**,两头都有实测的窗口(1024×1024 源图,原点在中心):
    ///   - 红圆是满幅内切圆,半径 512(四条中线上第一个不透明像素分别在 0 / 1023);
    ///   - 所有镂空像素离中心最远 303(细白环的外沿,不是三角——三角更靠里)。
    /// 所以白圆半径的安全区间是 (303, 508];取 inset 8%(半径 430)落在正中间,离两头各有
    /// 一百多像素的余量,26pt 显示尺寸下红边仍有约 2pt,不会因为边缘抗锯齿漏出白圈。
    /// ⚠️ 别改成"在视图里垫一层 `Circle().fill(.white)`":那样只有这一个调用点是对的,换个
    /// 地方用 `platformIcon("youtubeMusic")` 又会退回镂空。垫白这件事属于这张图本身。
    ///
    /// ⚠️ **不改磁盘上那份 PNG**,保持素材跟 Simple Icons 原样一致(来路可查,同
    /// `SpotifyIcon.png` 的纪律);垫白只发生在运行时。用 `NSImage(size:flipped:drawingHandler:)`
    /// 而不是 `lockFocus()` 烤成位图:前者保持分辨率无关(按实际需要的尺寸重画),后者会把
    /// 图钉死在一个像素尺寸上。`NSColor.white` 是固定的白,不是 `labelColor` 那种会跟外观翻转的
    /// 语义色——这正是这次要的"固定"。
    ///
    /// 只有 YouTube Music 需要这一步:`SpotifyIcon.png` 取自本机 `.app` 的 `AppIcon.icns`,
    /// 图形内部整片不透明(实测中心 alpha = 1),没有镂空可漏。
    private static func whiteFilledCutouts(image: NSImage?) -> NSImage {
        guard let image else {
            return NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil) ?? NSImage()
        }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        return NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            let inset = min(rect.width, rect.height) * 0.08
            NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset)).fill()
            image.draw(in: rect)
            return true
        }
    }
}
