import AppKit

// 菜单栏歌词跑马灯的渲染侧(2026-08-15 加)——把一行歌词画成一整条长图,交给
// MenuBarScrollingLabel 里的 CALayer 当内容,由 Core Animation 平移。
//
// 为什么要画成图片,而不是发布一个字符串让文本控件去渲染:
// 平滑滚动的最小单位必须是**像素**,而文本能表达的最小单位是**一个字**。按字取窗那版
// (2026-08-15 前)每 0.25 秒整体平移一个字,本质上是 4fps 的动画,肉眼看就是一跳一跳;
// 而且一个窗口固定 N 个字符、字符宽度却不相等(英文 'i' 和 'm' 差一倍,中文又比拉丁宽得多),
// 每跳一次这段文字的像素宽度也在变,菜单栏项跟着伸缩,把右边其它 App 的图标一起顶得左右晃。
// 图片这条路两个问题一起解决:宽度由我们钉死,偏移可以是任意小数。
//
// ⚠️ 2026-08-16 之前这里画的是**模板图**(isTemplate = true),靠系统按浅色/深色/反白
// 自动上色。改成自建 NSStatusItem 之后我们自己拿着图层,没有系统的模板处理这一层了,
// 所以颜色改由调用方显式传进来(见 MenuBarScrollingLabel.tintColor:平时 labelColor、
// 菜单打开时 selectedMenuItemTextColor,都在按钮当前的 effectiveAppearance 下解析)。
@MainActor
enum MenuBarMarqueeRenderer {
    /// 跟系统菜单栏项同一套字体。ofSize: 0 = 用系统当前的菜单栏字号,不要写死数字,
    /// 否则用户改了系统字号之后这行歌词会跟旁边的菜单项不齐。
    static var font: NSFont { NSFont.menuBarFont(ofSize: 0) }

    /// 这段文字画出来有多宽(点)。取窗宽度和滚动距离都靠它算。
    static func width(of text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// 一行文字的高度(含上下各 1pt 的富余,避免 'g'/'q' 的下伸部分被裁掉一丝)。
    static var lineHeight: CGFloat {
        let f = font
        return ceil(f.ascender - f.descender) + 2
    }

    /// 把文字按**宽度**截断,超出部分换成省略号。装得下的句子不走这里,只有极端情况
    /// (宽度小到连滚都没意义)才用得上。
    ///
    /// 按宽度而不是按字数逐字试,是因为字符宽度差得很远(同为 10 个字,中文 128pt、
    /// 英文 65pt),按字数截出来的实际长度完全不受控。
    static func truncate(_ text: String, toWidth limit: CGFloat) -> String {
        guard limit > 0 else { return "" }
        guard width(of: text) > limit else { return text }
        let ellipsis = "…"
        let ellipsisWidth = width(of: ellipsis)
        var kept = ""
        for ch in text {
            let next = kept + String(ch)
            if width(of: next) + ellipsisWidth > limit { break }
            kept = next
        }
        // 一个字都放不下时也要给点东西,别返回空串(菜单栏上会变成一块什么都没有的空白)。
        return kept.isEmpty ? ellipsis : kept + ellipsis
    }

    // MARK: - 这一句到底怎么显示

    /// 滚动速度:每秒 4 个字。跟 2026-08-05 的初版一致(那时是每 0.25 秒挪一个字),
    /// 换过两次驱动方式,这个观感参数一直没动。
    static let scrollCharsPerSecond: CGFloat = 4
    /// 首尾各停 1.5 秒。一句歌词最关键的往往是开头,一上来就滚会看不清。
    static let scrollHoldSeconds: Double = 1.5

    /// 一行歌词在菜单栏上的两种形态。
    ///
    /// ⚠️ 这个判定**必须**只有一份:菜单栏本体(MenuBarStatusItem)和设置页里那条预览
    /// (MenuBarPreviewBar)都走它。2026-08-16 之前预览是自己另写的一套(自己判断截断、
    /// 演的是滚动的第一帧),结果预览和实际长得并不一样 —— 用户报的"预览里要真实模拟
    /// 实际的菜单栏"就是这个。两份实现必然漂,唯一的解法是让它们共用同一个函数。
    enum Presentation: Equatable {
        /// 装得下(或者宽度被设得极小、只能截断):按钮直接画这段文字。
        case text(String)
        /// 装不下:交给 MenuBarScrollingLabel 用 Core Animation 平移。
        case scroll(text: String, windowWidth: CGFloat,
                    pointsPerSecond: CGFloat, holdSeconds: Double)
    }

    static func presentation(for text: String, windowWidth: CGFloat) -> Presentation {
        let fullWidth = width(of: text)
        // 差不到半个点就别滚了(滚也看不出来)。宽度算成 0 的极端情况也走这条路 ——
        // truncate 会返回空串,跟改动之前的行为一致。
        guard windowWidth > 0, fullWidth > windowWidth + 0.5 else {
            return .text(truncate(text, toWidth: windowWidth))
        }
        // 速度按这一句的平均字宽换算,这样中文歌和英文歌"每秒滚过几个字"是一致的。
        // 兜一个正数下限:宽度算出 0 的话速度也会是 0,关键帧那边会当成"不滚"。
        let averageCharWidth = fullWidth / CGFloat(max(1, text.count))
        return .scroll(
            text: text,
            windowWidth: windowWidth,
            pointsPerSecond: max(1, scrollCharsPerSecond * averageCharWidth),
            holdSeconds: scrollHoldSeconds)
    }

    /// 一句歌词排好版的整条长图。**一句只画一次**,之后每一帧都是 Core Animation 在
    /// 渲染层平移这一张图,主线程完全不参与。
    ///
    /// 2026-08-16 之前这里还有一个 frame(_:offset:)(从长图上按偏移裁一个窗口出来)和
    /// 一个 image(text:width:offset:)(每帧重排整段文本)。两个都随 MenuBarExtra 一起
    /// 删掉了:现在没有任何一方需要"某一帧长什么样"这个概念 —— 那正是逐帧驱动才需要的东西。
    struct PreparedLine {
        let cg: CGImage
        /// 位图的像素/点比例。图层的 contentsScale 要用它,不能猜。
        let scale: CGFloat
        /// 整条长图的点宽 = 这句话画出来有多宽。
        let textWidth: CGFloat
        let pointHeight: CGFloat
        let text: String
        /// 画这张图时用的颜色。菜单打开/系统换浅深色时要拿它比对、决定要不要重画。
        let color: NSColor
    }

    /// - Parameter color: 文字颜色。调用方负责在正确的 appearance 下解析动态颜色
    ///   (见 MenuBarScrollingLabel.rebuildImage)。
    static func prepare(text: String, color: NSColor) -> PreparedLine? {
        guard !text.isEmpty else { return nil }
        let font = Self.font
        let boxHeight = lineHeight
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let textWidth = ceil((text as NSString).size(withAttributes: attributes).width)
        // 不留尾部空白:旧版要留一个窗口宽,是因为要用 CGImage.cropping 裁窗口、越界会
        // 拿到 nil。现在是图层平移 + 上层 masksToBounds 裁剪,平移量永远不超过
        // textWidth - windowWidth,右边不会露出图外。
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pxW = Int(textWidth * scale), pxH = Int(boxHeight * scale)
        guard pxW > 0, pxH > 0,
              let ctx = CGContext(
                data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        // flipped: false → 原点在左下、y 向上。NSString.draw(at:) 收的是文本框左下角,
        // 所以 y 给 1 就是"底部留 1pt 内边距"。
        (text as NSString).draw(at: NSPoint(x: 0, y: 1), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }
        return PreparedLine(cg: cg, scale: scale, textWidth: textWidth,
                            pointHeight: boxHeight, text: text, color: color)
    }
}
