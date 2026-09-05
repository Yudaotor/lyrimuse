import AppKit
import LyrimuseCore
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "menubar-hover")

// 菜单栏歌词的「悬停三键」那一层(2026-09-03,见 `MenuBarHoverControls` 头注的用户原话)。
// 这个文件只管两件事:**收 hover 事件**、**把三个键画出来**。排在哪、点中哪一个是纯几何,
// 在 LyrimuseCore 的 `MenuBarHoverControls` 里(selftest 覆盖);何时接管、点击怎么分派、
// 接管期间怎么把槽宽冻住,在 `MenuBarStatusItem` 里。
//
// ---- 为什么 tracking area 装在**按钮**上、owner 却是这个视图 ----
//
// 状态栏项里的两个自绘层(MenuBarScrollingLabel / MenuBarLiveIconView)都覆写了
// `hitTest -> nil`,让点击一路落到底下的 NSStatusBarButton —— 这是保住"⌘拖动换位置 /
// 右键完整菜单 / ⌃左键"这些既有手势的前提,这一层也照办。可 `hitTest -> nil` 的视图能不能
// 照样收到 mouseEntered,取决于 AppKit 内部拿不拿 hitTest 参与 tracking 判定,是件"我说不
// 准、又只能在真菜单栏上才验得到"的事。绕开的办法很简单:**tracking area 装到按钮身上**
// (按钮当然是收事件的),owner 填这个视图 —— NSTrackingArea 的 owner 只是"消息发给谁",
// 跟区域装在谁身上是两回事,而 NSView 天生就有 mouseEntered/mouseExited/mouseMoved 可覆写。
// 这样 hover 的可靠性只依赖"按钮在被 tracking",不依赖这一层的命中测试语义。
//
// 用 `.inVisibleRect`:区域跟着按钮的可见矩形自动更新,状态栏项换槽宽(用户拖宽度滑杆、
// 自适应模式逐句变宽)时不用自己重算 rect。`.activeAlways` 是必须的 —— 这是个
// accessory App,大多数时候根本不是前台。
@MainActor
final class MenuBarHoverControlsView: NSView {
    /// 指针进/出这一项。**不做防抖**:进出判定原样上报,"停多久才算真想按"由
    /// MenuBarStatusItem 决定(它才知道当前形态能不能接管)。
    var onHoverChange: ((Bool) -> Void)?

    /// 现在是不是接管态(接管 = 歌词收掉、三个键画出来)。
    private var engaged = false
    /// 菜单/面板打开时状态栏项整块反白,字形得跟着换色 —— 跟 MenuBarScrollingLabel
    /// .setHighlighted 同一个理由(自己拿图层/自绘之后,模板图那份系统免费着色没了)。
    private var highlighted = false
    /// 中间那个键画 ⏸ 还是 ▶。
    private var isPlaying = false
    /// 指针正压在哪个键上(画一层浅底当准星)。
    private var hoveredControl: MenuBarTransportControl?
    /// 三个键落在哪一块里。nil = 整个按钮(没开「歌词旁的图标」时就是这样)。
    /// 开着图标时由 MenuBarStatusItem 把**歌词那一格**传进来 —— 图标那一块要原样留着,
    /// 点它也照旧弹面板(2026-09-03 用户要求)。
    private var slot: CGRect?

    private weak var trackingHost: NSView?
    private var installedArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不使用") }

    // 这一层只负责画。点击必须落到底下的 NSStatusBarButton 上去(理由见头注)。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - 对外

    /// 把 hover 追踪装到这一项的按钮上。按钮每次重建(见 MenuBarStatusItem
    /// .rebuildStatusItem)都要重装一次:旧按钮连着旧区域一起没了,新按钮身上什么都没有。
    func installTracking(on host: NSView) {
        if let old = installedArea, let oldHost = trackingHost {
            oldHost.removeTrackingArea(old)
        }
        let area = NSTrackingArea(
            rect: .zero, // .inVisibleRect 下这个值被忽略
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        host.addTrackingArea(area)
        trackingHost = host
        installedArea = area
        // 顺带把"菜单栏此刻是深是浅"记一笔:这一层只存在于**真**菜单栏上(预览里没有),
        // 是这个 App 里唯一能可靠回答这个问题的地方。设置页的色块和预览都按它解析
        // 「跟随系统」,见 MenuBarAppearanceStore 头注。
        MenuBarAppearanceStore.shared.update(from: host)
    }

    /// 进入/退出接管态。退出时把准星一起清掉 —— 不清的话下次接管会先闪一下上次那个键的浅底。
    func setEngaged(_ on: Bool) {
        guard on != engaged else { return }
        engaged = on
        if !on { hoveredControl = nil }
        isHidden = !on
        needsDisplay = true
    }

    var isEngaged: Bool { engaged }

    func setPlaying(_ on: Bool) {
        guard on != isPlaying else { return }
        isPlaying = on
        if engaged { needsDisplay = true }
    }

    func setHighlighted(_ on: Bool) {
        guard on != highlighted else { return }
        highlighted = on
        if engaged { needsDisplay = true }
    }

    /// 三个键该落在哪一块里。接管**之前**由 MenuBarStatusItem 设好(接管期间歌词层的几何
    /// 已经被收掉、问不出来了),退出接管时置 nil。
    func setSlot(_ rect: CGRect?) {
        guard rect != slot else { return }
        slot = rect
        if engaged { needsDisplay = true }
    }

    /// 实际用的那一块:没给就用整个按钮。
    private var slotRect: CGRect { slot ?? bounds }

    /// 按钮坐标系里的三个命中格。视图的 frame 恒等于 button.bounds(autoresizing 跟着走),
    /// 所以视图坐标 = 按钮坐标,MenuBarStatusItem 那边把 event 的位置转进按钮就能直接比。
    var controlRects: [MenuBarTransportControl: CGRect]? {
        MenuBarHoverControls.layout(in: slotRect)
    }

    /// 这一下点在哪个键上。接管态之外恒为 nil —— 没接管的时候整块还是"点开面板"那个语义。
    func control(at point: CGPoint) -> MenuBarTransportControl? {
        guard engaged, let rects = controlRects else { return nil }
        return MenuBarHoverControls.control(at: point, in: rects)
    }

    /// 当前槽宽装不装得下三个键。MenuBarStatusItem 用它决定要不要接管。
    /// 当前这一块装不装得下三个键。⚠️ 判的是 `slotRect` 不是整个按钮:开着「歌词旁的图标」时
    /// 歌词那一格要窄一截(图标 + 5pt 间距),门槛必须按窄的那个算,不然会接管出一排画到
    /// 图标上的键。
    var fitsControls: Bool { MenuBarHoverControls.layout(in: slotRect) != nil }

    // MARK: - 事件

    override func mouseEntered(with event: NSEvent) {
        updateHovered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredControl != nil {
            hoveredControl = nil
            if engaged { needsDisplay = true }
        }
        onHoverChange?(false)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHovered(with: event)
    }

    private func updateHovered(with event: NSEvent) {
        guard engaged, let window else { return }
        // ⚠️ 跟点击那一侧同一条纪律:**从屏幕坐标换算**,不能用 `event.locationInWindow`。
        // 状态栏这个宿主上后者给出的点跟真实指针差约 11.5pt(实测,见 MenuBarStatusItem
        // 里那段注释),而每个键只有 24pt 宽 —— 用错了准星会亮在隔壁那个键上,跟点击结果
        // 也对不上。两侧必须用同一条换算,否则"看着高亮哪个"和"点下去是哪个"会分家。
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let next = controlRects.flatMap { MenuBarHoverControls.control(at: point, in: $0) }
        guard next != hoveredControl else { return }
        hoveredControl = next
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // 槽宽一变,三个键的居中位置就变了(窄到装不下时还要整块不画)。
        if engaged { needsDisplay = true }
    }

    // 系统在浅色/深色之间切换时 labelColor 解析出来是另一个值,得重画
    // (跟 MenuBarScrollingLabel.viewDidChangeEffectiveAppearance 同一个理由)。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // 菜单栏由亮转暗(或反过来)时,设置页那两个色块和预览要跟着重画 —— 它们按这个值
        // 解析「跟随系统」。这一层是真菜单栏上的常驻视图,拿它当唯一的观察点。
        if let host = trackingHost { MenuBarAppearanceStore.shared.update(from: host) }
        if engaged { needsDisplay = true }
    }

    // MARK: - 画

    override func draw(_ dirtyRect: NSRect) {
        guard engaged, let rects = MenuBarHoverControls.layout(in: slotRect) else { return }
        // ⚠️ labelColor / selectedMenuItemTextColor 是**动态**色,真正解析成 RGB 是在绘制
        // 那一刻按"当前绘制 appearance"决定的。不套这一层的话,深色菜单栏上会画出几乎
        // 看不见的深色字形(取决于 App 自己的 appearance,而不是菜单栏的)。同
        // MenuBarScrollingLabel.rebuildImage。
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let tint = highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
            // 三个字形各自染色。染色用 `.sourceAtop`(只碰字形覆盖到的像素,边缘的半透明
            // 像素保持原样,不会长出一圈硬边)—— 手法照抄 MenuBarProgressIcon.tinted。
            for control in MenuBarTransportControl.allCases {
                guard let hit = rects[control],
                      let glyph = Self.glyph(for: control, playing: isPlaying) else { continue }
                glyph.image.draw(in: glyph.box(centeredIn: hit))
                tint.set()
                glyph.box(centeredIn: hit).fill(using: .sourceAtop)
            }
            // 准星那层浅底**最后**画,而且用 `.destinationOver` 垫到字形**下面**。
            // ⚠️ 顺序不是随便定的:上面那一步的 `.sourceAtop` 会把这一层视图里已经画过的
            // 任何有 alpha 的像素一起染上 tint 色 —— 先画浅底的话,浅底会被染成字形色。
            if let hovered = hoveredControl, let hit = rects[hovered] {
                let base = highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
                base.withAlphaComponent(0.15).set()
                NSBezierPath(roundedRect: hit.insetBy(dx: 1, dy: 3), xRadius: 4, yRadius: 4)
                    .fill(using: .destinationOver)
            }
        }
    }

    /// 一个键的字形:图 + 它的**墨迹**在画布里的包围盒。
    ///
    /// ---- 为什么要额外记墨迹,不能直接按画布居中 ----
    ///
    /// SF Symbol 出的画布**不是**围着墨迹对称的,而且 `backward.fill` / `forward.fill` 这对
    /// 镜像字形的留白也不镜像。11.5pt / medium 下离屏实测(2026-09-03,逐像素扫非透明):
    ///
    /// | 符号 | 画布 | 墨迹 x | 墨迹中心 − 画布中心 |
    /// |---|---|---|---|
    /// | `backward.fill` | 18.00×11.00 | 0.00…16.00 | **−1.00** |
    /// | `forward.fill`  | 18.00×11.00 | 1.50…17.50 | **+0.50** |
    /// | `pause.fill`    | 11.00×12.00 | 1.50…9.00  | −0.25 |
    /// | `play.fill`     | 11.00×12.00 | 1.50…10.50 | **+0.50** |
    ///
    /// 按画布居中的后果有两条,都是实测出来的、不是推的:①上一曲偏左 1pt、下一曲偏右 0.5pt,
    /// 三个键看着整体偏左、间距不匀;②更烦的是 ▶ 和 ⏸ 差 0.75pt —— **点一下暂停,中间那个
    /// 字形会横跳一下**,而那正是最常点的键。所以按墨迹居中。
    ///
    /// 墨迹是**运行时量**的(每个符号只量一次),不写成常量:符号的 metric 跨 macOS 版本会变,
    /// 写死的话哪天变了就是静默偏移;量一遍则自动跟上。
    private struct Glyph {
        let image: NSImage
        let ink: CGRect

        /// 让**墨迹**的中心落在这一格中心时,图该画在哪。
        ///
        /// 落点取整到**半点**而不是整点:菜单栏这个尺寸下 2x 屏上半点正好压在设备像素上(仍然
        /// 清晰),而整点取整会让 `forward.fill` 这种墨迹中心带 .5 的字形永远差 0.5pt。取整到
        /// 半点后四个字形的残差都 ≤0.25pt(实测:上一曲 85.0 / 暂停 109.25 / 播放 109.0 /
        /// 下一曲 133.0,格中心 85 / 109 / 133)。
        func box(centeredIn hit: CGRect) -> CGRect {
            CGRect(x: Self.roundedToHalf(hit.midX - ink.midX),
                   y: Self.roundedToHalf(hit.midY - ink.midY),
                   width: image.size.width, height: image.size.height)
        }

        private static func roundedToHalf(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
    }

    /// SF Symbol 出的图不随内容变,按符号名缓存一份就够 —— hover 一次要画三张,每次重新出图
    /// 加重新量墨迹是白费(同 MenuBarIconStyle.cachedImage 的理由)。
    private static var glyphCache: [String: Glyph] = [:]

    private static func glyph(for control: MenuBarTransportControl, playing: Bool) -> Glyph? {
        let name: String
        switch control {
        case .previous: name = "backward.fill"
        case .playPause: name = playing ? "pause.fill" : "play.fill"
        case .next: name = "forward.fill"
        }
        if let cached = glyphCache[name] { return cached }
        let config = NSImage.SymbolConfiguration(
            pointSize: MenuBarHoverControls.glyphPointSize, weight: .medium)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            logger.error("SF Symbol not found: \(name, privacy: .public)")
            return nil
        }
        // 量不出来(位图建不起来 / 画出来是空的)就退回画布居中 —— 偏一点点也比不画好。
        let glyph = Glyph(image: image,
                          ink: inkRect(of: image) ?? CGRect(origin: .zero, size: image.size))
        glyphCache[name] = glyph
        return glyph
    }

    /// 把符号画到一张 2x 位图上,扫出非透明像素的包围盒(点坐标)。
    /// 只在每个符号第一次用到时跑一次;字形本身只有 18×11pt 上下,扫一遍可以忽略。
    private static func inkRect(of image: NSImage) -> CGRect? {
        let size = image.size
        let scale: CGFloat = 2
        let pxW = Int((size.width * scale).rounded()), pxH = Int((size.height * scale).rounded())
        guard pxW > 0, pxH > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        // rep 的**点**尺寸(像素尺寸已经由 pxW/pxH 定了),不设的话画出来只占左下角
        // —— 同 MenuBarProgressIcon.tinted 里那一行。
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        var minX = pxW, maxX = -1, minY = pxH, maxY = -1
        for x in 0..<pxW {
            for y in 0..<pxH {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0, maxY >= 0 else { return nil }
        // ⚠️ y 要翻过来:NSBitmapImageRep 的 colorAt 是**左上原点、y 向下**,而画的时候用的是
        // AppKit 的左下原点坐标系。不翻的话对上下不对称的字形会得到一个上下颠倒的墨迹盒
        // (这四个符号纵向恰好对称,所以翻不翻都对 —— 正因为看不出来才更要写对)。
        let x0 = CGFloat(minX) / scale, x1 = CGFloat(maxX + 1) / scale
        let yTop = CGFloat(minY) / scale, yBottom = CGFloat(maxY + 1) / scale
        return CGRect(x: x0, y: size.height - yBottom, width: x1 - x0, height: yBottom - yTop)
    }
}

private extension NSBezierPath {
    /// NSBezierPath 自己没有"按指定合成模式填充"的接口,`fill()` 恒等于 `.sourceOver`。
    /// 上面那层准星底要 `.destinationOver`(垫到已画好的字形下面),所以在这里把合成模式
    /// 临时切一下再填 —— 比自己拿 CGContext 画一遍圆角矩形短。
    func fill(using operation: NSCompositingOperation) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = operation
        fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
