import AppKit
import LyrimuseCore
import SwiftUI

// 「外观 → 桌面悬浮歌词」那一页钉在顶部的实时预览。
//
// 为什么需要它:这一页几乎每一项(字体/字号/文字色/背景色/描边/宽度)改完的效果都只在
// **桌面上那扇悬浮窗**里,而调这些设置的那一刻,那扇窗多半正被设置窗盖着;更糟的是
// hideWhenNotPlaying 开着而当前没在播放时,它压根不显示 —— 于是用户拖完滑杆什么都看不到,
// 分不清"是我没调对"还是"这设置没生效"。把同一段渲染搬到这一页顶上,改什么当场看得见。
//
// ⚠️ 这是**第二份渲染实现**,天然会跟真窗口漂。为把漂移压到最小,能复用的一律复用:
// settings.mainFont / settings.backgroundColor / settings.backgroundIsVisible /
// PlaybackCoordinator.displayForegroundColor(它才是"跟随封面"真正生效的地方),以及
// LyricsOverlayView 里那个 .lyricsTextStroke(为此把它从 private 放开成 internal)。
//
// 刻意**不**复制的东西,以及理由:
//   - 逐字卡拉OK填色:那是随播放进度连续变化的,预览要 60fps 跟着跑才不假,而这一页
//     不值得为此常驻一个高频重绘。预览只画整行的最终颜色。
//   - 罗马音/译文/下一句:它们各有独立的字体和显隐开关,画全了预览条会高得挤掉正文,
//     而这一页调的是主歌词那一行的字体和配色。
//   - 窗口圆角以外的窗口行为(点击穿透、拖动、随屏幕定位):跟外观无关。
//
// 高度是**固定**的(按字号算出来),不跟着内容变:它挂在 safeAreaInset 上,高度一变整页
// 内容就会跳一下,拖字号滑杆时会变成整页抖动。
@MainActor
struct OverlayPreviewBar: View {
    @ObservedObject private var settings = AppSettings.shared

    // ⚠️ 只订阅需要的那两个字段,**不要**写成 @ObservedObject PlaybackCoordinator.shared。
    // 那个单例有二十来个 @Published(anchor / pausedPositionMs / currentLyricsOffsetMs 等
    // 每个播放 tick 都在变),整页设置会跟着高频重绘 —— 这个仓库为"@ObservedObject 订阅
    // 整个单例"踩过一次真实的 20Hz 过度重渲染 bug。removeDuplicates 保证只有歌词真的换行、
    // 或封面主色真的变了才动一次。
    @State private var line: SyncedLyricLine?
    @State private var accent: Color?

    // 真窗口的圆角(LyricsOverlayView 里的 overlayBackgroundCornerRadius,那是个 private
    // 常量,取不到,只能同步一份)。改那边记得改这里。
    private let overlayCornerRadius: CGFloat = 16
    // 预览条允许占用的最大宽度。比卡片列(600)窄一点,两侧留出呼吸。
    private var maxPreviewWidth: CGFloat { Self.maxPreviewWidthShared }

    // 真窗口多宽就按多宽画,放不下时整体等比缩小 —— 这样拖"宽度"滑杆在预览里是看得见的。
    private var scale: CGFloat {
        min(1, maxPreviewWidth / max(settings.overlayWidth, 1))
    }

    // 一行主歌词的高度按字号推,不去实测 —— 见类型注释里"高度必须固定"那一段。
    // 1.5 是行高系数,上下各 14 是仿真窗口的内边距。
    private var contentHeight: CGFloat { Self.rawCardHeight }

    /// 缩放前的卡片高度。
    static var rawCardHeight: CGFloat { AppSettings.shared.fontSize * 1.5 + 28 }

    /// 这一条实际占的卡片高度(已含等比缩小),供 SectionPreviewMetrics 取三条的最大值。
    /// 它跟着字号走,所以那个统一高度不能写成一个死数字。
    static var cardHeight: CGFloat {
        let settings = AppSettings.shared
        let scale = min(1, maxPreviewWidthShared / max(settings.overlayWidth, 1))
        return rawCardHeight * scale
    }

    /// 见下面实例属性 maxPreviewWidth 的注释,同一个值。
    static let maxPreviewWidthShared: CGFloat = 520

    // 没在播放(或这首歌没解析出歌词)时给一句示例,而不是留白:留白的话文字颜色/字体/
    // 描边这几项就全都预览不到了,而那恰恰是最需要预览的几项。
    private var previewText: String {
        if let text = line?.plainText, !text.isEmpty { return text }
        return L10n.t("这里是一句歌词示例")
    }

    private var foreground: Color {
        // 跟 PlaybackCoordinator.displayForegroundColor 同一条规则:开着"跟随封面"且真的
        // 算出了封面主色才用它,否则用手选的固定色。不直接读那个计算属性是因为它每次求值
        // 都要摸一次单例,这里已经把需要的两个输入订阅进来了。
        if settings.followsCoverArt, let accent { return accent }
        return settings.foregroundColor
    }

    // 相对亮度用 BT.601 系数(0.299/0.587/0.114),跟人眼对绿色更敏感这一点吻合,够这里用。
    // 先转 sRGB:foregroundColor 可能是从 hex 造的、也可能是封面取色算出来的,色彩空间不定,
    // 不转的话取 redComponent 会在某些色彩空间上直接抛异常。
    private var backdrop: Color {
        let ns = NSColor(foreground).usingColorSpace(.sRGB)
        guard let ns else { return Color(nsColor: .textColor).opacity(0.08) }
        let luma = 0.299 * ns.redComponent + 0.587 * ns.greenComponent + 0.114 * ns.blueComponent
        return luma > 0.5 ? Color.black.opacity(0.62) : Color.white.opacity(0.72)
    }

    var body: some View {
        VStack(spacing: 6) {
            preview
            caption
        }
        .padding(.top, SectionPreviewMetrics.topPadding)
        .padding(.bottom, SectionPreviewMetrics.bottomPadding)
        // 三条预览栏共用一个高度,切段时这一条不能变高变矮(见 SectionPreviewMetrics)。
        .frame(height: SectionPreviewMetrics.barHeight)
        .frame(maxWidth: .infinity)
        // ⚠️ 必须自带不透明底色。这块是挂在 safeAreaInset 上的,而 SettingsPage 的
        // .background(windowBackgroundColor) 只铺在 ScrollView 上、盖不到 inset 区域 ——
        // 不画底色的话,下面滚动的卡片会从预览条底下透出来。
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(PlaybackCoordinator.shared.$currentLine.removeDuplicates()) { line = $0 }
        .onReceive(PlaybackCoordinator.shared.$artworkAccentColor.removeDuplicates()) { accent = $0 }
    }

    @ViewBuilder
    private var desktopUnderlay: some View {
        if let wallpaper = DesktopWallpaperSample.image {
            Image(nsImage: wallpaper)
                .resizable()
                .scaledToFill()
        } else {
            // 拿不到壁纸(读不到文件/没有权限)就退回棋盘格 —— 它至少明确表达了
            // "这一块是透明的、透出的是底下的东西",不会像纯色那样把人误导成不透明。
            Canvas { context, size in
                let cell: CGFloat = 8
                let cols = Int(size.width / cell) + 1
                let rows = Int(size.height / cell) + 1
                for row in 0 ..< rows {
                    for col in 0 ..< cols where (row + col).isMultiple(of: 2) {
                        let rect = CGRect(
                            x: CGFloat(col) * cell, y: CGFloat(row) * cell,
                            width: cell, height: cell)
                        context.fill(Path(rect), with: .color(.gray.opacity(0.22)))
                    }
                }
            }
        }
    }

    private var preview: some View {
        ZStack {
            // ⚠️ 卡片底下垫的是**真实桌面壁纸**,不是纯色。
            //
            // 悬浮歌词的窗口本身是透明的,用户设的"背景颜色"通常带 alpha —— 底下垫纯色的话,
            // 半透明会被合成成一块不透明的灰,"背景是透明的"这件事在预览里彻底看不出来
            // (2026-08-15 用户报的原话:"为什么实际背景是透明的,但是预览这里不是")。
            //
            // 铺满整个卡片区域(矩形)而不是只铺在圆角背景里面:真窗口的圆角**之外**露出的
            // 也是桌面,连这一点一起演出来才对得上。
            desktopUnderlay
            if settings.backgroundIsVisible {
                RoundedRectangle(cornerRadius: overlayCornerRadius, style: .continuous)
                    .fill(settings.backgroundColor)
            }
            Text(previewText)
                .font(settings.mainFont)
                .foregroundStyle(foreground)
                .lyricsTextStroke(settings.textStrokeEnabled, color: settings.textStrokeColor)
                .lineLimit(1)
                .padding(.horizontal, 20)
        }
        .frame(width: settings.overlayWidth, height: contentHeight)
        // 只给垫底那层收个小圆角,别让壁纸块直角戳在卡片列里;背景色自己的圆角不受影响。
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .scaleEffect(scale, anchor: .center)
        // 缩放不改变布局占位,得显式把外框收到缩放后的尺寸,否则会按原始宽度占位、把整条撑爆。
        .frame(width: settings.overlayWidth * scale, height: contentHeight * scale)
        // 垫底色**按文字明度自适应**:浅色文字垫深底,深色文字垫浅底。
        //
        // 2026-08-14 真机截图抓到的:第一版垫的是固定的浅灰(textColor 0.06),而这台机器
        // 开着"跟随封面取色"、当前封面主色是浅的,于是浅字浮在浅底上,整条预览等于白板 ——
        // 而"改文字色能当场看见"正是这块预览存在的理由。
        //
        // 不去冒充真实壁纸:那要读 NSWorkspace.desktopImageURL,它在动态/Aerial 壁纸下经常
        // 拿不到可用图,而且 NSScreen.main 在无屏时是 nil。宁可给一块诚实的中性底,也不要
        // 一个在部分机器上直接退化成灰块的"假壁纸"。
        .background(
            RoundedRectangle(cornerRadius: overlayCornerRadius, style: .continuous)
                .fill(backdrop)
        )
        .accessibilityHidden(true)
    }

    private var caption: some View {
        Text(
            scale < 1
                ? String(format: L10n.t("预览 · %@pt · 已缩放至 %@%%"),
                         "\(Int(settings.overlayWidth))", "\(Int(scale * 100))")
                : String(format: L10n.t("预览 · %@pt"), "\(Int(settings.overlayWidth))")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}


/// 预览里垫在悬浮歌词卡底下的那张桌面壁纸。
///
/// 只读一次并缩到预览用得着的尺寸:壁纸动辄几千像素,每次渲染都去读原图既慢又占内存。
/// 代价是换了壁纸要等下次启动才更新 —— 对一个"演示半透明效果"的垫底图来说够用了。
@MainActor
enum DesktopWallpaperSample {
    private static var loaded = false
    private static var cache: NSImage?

    static var image: NSImage? {
        if !loaded {
            loaded = true
            cache = load()
        }
        return cache
    }

    private static func load() -> NSImage? {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let original = NSImage(contentsOf: url)
        else { return nil }
        // 缩到预览条那么宽就够了(高度按比例)。
        let targetWidth: CGFloat = 640
        guard original.size.width > targetWidth else { return original }
        let scale = targetWidth / original.size.width
        let size = NSSize(
            width: targetWidth, height: (original.size.height * scale).rounded())
        return NSImage(size: size, flipped: false) { rect in
            original.draw(in: rect)
            return true
        }
    }
}
