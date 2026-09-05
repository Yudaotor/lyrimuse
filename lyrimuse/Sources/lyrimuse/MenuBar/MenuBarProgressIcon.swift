import AppKit
import LyrimuseCore

// 菜单栏歌词旁边那枚**带播放进度**的图标(2026-09-03)。用户原话:"帮我菜单栏歌词仿照
// 这个加一个功能配置项,就是可以选择是否在最左侧或者是最右侧展示软件图标,图标上会逐渐
// 染色代表当前歌曲进度条"(附酷狗菜单栏歌词的截图)。
//
// ---- 这个文件只管两样东西 ----
//
// **几何**(占多宽、间距多少)和**位图**(把模板图染成一张 CGImage)。另外两半各在各的
// 地方,别在这里长出第三份:
//   * 进度怎么走 = 纯数学,`MenuBarMarquee.progressFillLength` / `progressFillRamp`
//     (在 LyrimuseCore 里,selftest 逐点覆盖 —— 这也正是它没写在这里的原因:这个文件
//     依赖 AppKit,selftest 那个 target 只连 LyrimuseCore);
//   * 图层怎么摆、动画怎么装 = `MenuBarScrollingLabel`(跟逐字染色共用互补裁剪那套手法)。
//
// ---- 为什么用 MenuBarIconStyle 而不是 App 的彩色图标 ----
//
// 2026-09-03 用户在两个方案里挑的这个。它本来就是这个软件在菜单栏上的脸(12 款里用户
// 自己挑过一款),而且是**模板图** —— 单色字形,染成任意颜色都干净,能直接复用歌词那套
// 「基础色/强调色两张同字形图做互补裁剪」的管线,还天然跟旁边的歌词共用同两个颜色设置
// (未唱到的颜色 / 已唱到的颜色)、跟着浅深色菜单栏和菜单反白一起走。彩色 App 图标要另做
// 一版灰度、两张位图对齐互补裁剪,而且 22pt 高的菜单栏里彩色细节本来就比单色矢量糊。
@MainActor
enum MenuBarProgressIcon {
    /// 图标和歌词之间留多少。
    ///
    /// 5pt 是照真菜单栏上的观感取的:比 AppKit 给 `.imageLeading` 的默认间距(~2pt)宽一点,
    /// 免得图标看着像黏在第一个字上;又明显比两个**状态栏项**之间的空隙(~8pt)窄 ——
    /// 这样一眼看得出"图标和歌词是同一项",而不是旁边多冒出来一个别的 App 的图标。
    static let gap: CGFloat = 5

    /// 开着这个功能时,这一项要在歌词之外**额外**占多宽(图标宽 + 间距)。关着是 0。
    ///
    /// ⚠️ 槽宽公式的**唯一**一份:菜单栏本体的三条路径(fixed / adaptive / 几何推迟期的
    /// 过渡渲染)和设置页预览都从这里取。macOS 26 起菜单栏项的宽度必须在**出生那一刻**
    /// 就是对的(事后改宽邻居不让位,见 `MenuBarStatusItem.present` 头注),各写一遍
    /// 算漏一处的后果不是"差几个点",是歌词压到邻居图标头上、而且不自愈。
    static func reservedWidth(for style: MenuBarIconStyle?) -> CGFloat {
        guard let style else { return 0 }
        return MenuBarIconStyle.cachedImage(for: style).size.width + gap
    }

    /// 这一款图标画出来多大(点)。各款不一样(「经典」20.5 × 14,SF Symbol 那几款按 15pt
    /// 字号出图),所以宽度不能写死一个常量。
    static func size(of style: MenuBarIconStyle) -> CGSize {
        MenuBarIconStyle.cachedImage(for: style).size
    }

    /// 染好色的一张位图。
    struct Prepared {
        let cg: CGImage
        /// 像素/点比例,图层的 `contentsScale` 要用它,不能猜。
        let scale: CGFloat
        let size: CGSize
    }

    /// 把这一款图标染成指定颜色。
    ///
    /// `MenuBarIconStyle` 出的是**模板图**(`isTemplate = true`)—— 那是给 NSButton /
    /// NSImageView 用的,系统会按明暗/悬停/反白自动上色;而这里要把它塞进裸 CALayer 的
    /// contents,那一层享受不到模板着色(跟 `MenuBarLiveIconView.tintedContents` 同一个
    /// 处境),所以自己染。染法也照抄那边:先原样画一遍拿到字形的 alpha,再用
    /// `.sourceAtop` 把颜色压上去 —— 只在字形覆盖到的地方上色,边缘的半透明像素保持原样,
    /// 不会长出一圈硬边。
    ///
    /// ⚠️ 调用方负责在正确的 appearance 下解析动态颜色(labelColor / controlAccentColor
    /// 都是动态色,深色菜单栏上解析错就是画出一枚几乎看不见的图标)。做法见
    /// `MenuBarScrollingLabel.rebuildImage` 外面那层 `performAsCurrentDrawingAppearance`。
    /// - Parameter scale: 栅格化比例,调用方传图层所在窗口的 `menuBarBitmapScale`(2026-09-05 起不在这里猜屏)。
    static func tinted(style: MenuBarIconStyle, color: NSColor, scale: CGFloat) -> Prepared? {
        let image = MenuBarIconStyle.cachedImage(for: style)
        let size = image.size
        let pxW = Int((size.width * scale).rounded())
        let pxH = Int((size.height * scale).rounded())
        guard pxW > 0, pxH > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        // rep 的**点**尺寸(像素尺寸已经由上面的 pxW/pxH 定了),不设的话画出来只占左下角。
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage else { return nil }
        return Prepared(cg: cg, scale: scale, size: size)
    }
}
