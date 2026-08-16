import AppKit

// 菜单栏歌词跑马灯的渲染侧(2026-08-15 加)——把一行歌词画成一张**固定宽度**的模板图,
// 文字在这张图里按像素连续平移。
//
// 为什么要画成图片,而不是继续发布一个字符串让 SwiftUI 的 Text 去渲染:
// 平滑滚动的最小单位必须是**像素**,而 Text 能表达的最小单位是**一个字**。按字取窗那版
// (MenuBarMarquee.window,现在只剩关掉滚动时的截断还在用)每 0.25 秒整体平移一个字,本质
// 上是 4fps 的动画,肉眼看就是一跳一跳;而且一个窗口固定 N 个字符、字符宽度却不相等
// (英文 'i' 和 'm' 差一倍,中文又比拉丁宽得多),每跳一次这段文字的像素宽度也在变,菜单栏
// 项跟着伸缩,把右边其它 App 的图标一起顶得左右晃。图片这条路两个问题一起解决:宽度由
// 我们钉死,偏移可以是任意小数。
//
// ⚠️ 必须是**模板图**(isTemplate = true)。菜单栏文字有三种状态(浅色/深色/点开菜单时反白),
// 系统只对模板图自动处理这件事 —— 模板图只取 alpha 通道,画的时候用什么颜色都不影响结果。
// 反过来说,这也意味着这里没法把彩色画进菜单栏,不过菜单栏歌词本来就是纯文字、没有配色项。
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

    /// 把文字按**宽度**截断,超出部分换成省略号。关掉滚动时用它。
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

    /// 一句歌词**只画一次**的整条长图,以及从它身上按偏移裁窗口的能力。
    ///
    /// 2026-08-16 加。原来是每帧调下面那个 image(text:width:offset:) —— 每一帧都把整段
    /// 文本重新排版、重新绘制一遍,30fps。而一句歌词**在它自己那几秒里文本根本不变**,
    /// 变的只有"取哪一段",所以那份排版开销是纯浪费,用户反馈的"菜单栏滚动还是有点卡"
    /// 就是它。现在整句排版一次,每帧只做 CGImage.cropping —— 那是纯内存操作、共享底层
    /// 像素、不复制也不重排。
    ///
    /// ⚠️ 为什么不能像灵动岛歌名那样交给 Core Animation 插值:那边是真窗口里的 SwiftUI
    /// 视图,offset 交给渲染层就行;菜单栏这边是 MenuBarExtra 的 label,它挂不住 SwiftUI
    /// 的动画修饰符(见 MenuBarMarqueeTicker 顶部那段实测),只能靠"模型侧换图、label 跟着
    /// 重渲染"。所以能省的只有画图这一层 —— 那也正是最贵的一层。
    struct PreparedLine {
        let cg: CGImage
        /// 位图的像素/点比例。裁剪要用像素坐标,这个值不能猜。
        let scale: CGFloat
        let pointHeight: CGFloat
        let text: String
        let windowWidth: CGFloat
    }

    static func prepare(text: String, width: CGFloat) -> PreparedLine? {
        let windowWidth = ceil(width)
        guard windowWidth > 0, !text.isEmpty else { return nil }
        let font = Self.font
        let boxHeight = ceil(font.ascender - font.descender) + 2
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        // 长图宽度 = 整句文字宽 + 一个窗口宽的留白。留白是必须的:滚到最后一帧时窗口右半边
        // 已经越过文字末尾,没有留白就会裁到图外、拿到 nil。
        let textWidth = ceil((text as NSString).size(withAttributes: attributes).width)
        let fullWidth = textWidth + windowWidth
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pxW = Int(fullWidth * scale), pxH = Int(boxHeight * scale)
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
        (text as NSString).draw(at: NSPoint(x: 0, y: 1), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }
        return PreparedLine(cg: cg, scale: scale, pointHeight: boxHeight,
                            text: text, windowWidth: windowWidth)
    }

    /// 从整条长图里裁出当前这一帧要显示的窗口。offset 只往左(>= 0)。
    static func frame(_ line: PreparedLine, offset: CGFloat) -> NSImage? {
        let s = line.scale
        let x = Int((max(0, offset) * s).rounded())
        let w = Int((line.windowWidth * s).rounded())
        let h = line.cg.height
        // 夹回图内 —— 越界 cropping 直接返回 nil,那一帧菜单栏就会闪一下空白。
        let maxX = max(0, line.cg.width - w)
        let rect = CGRect(x: min(x, maxX), y: 0, width: min(w, line.cg.width), height: h)
        guard let piece = line.cg.cropping(to: rect) else { return nil }
        let image = NSImage(cgImage: piece,
                            size: NSSize(width: line.windowWidth, height: line.pointHeight))
        image.isTemplate = true
        return image
    }

    /// 画一张宽度恒为 `width` 的模板图,文字整体向左偏移 `offset` 点。
    ///
    /// offset 只往左(取值 >= 0):跑马灯是"文字从右往左走过一个固定的窗口",窗口本身不动。
    ///
    /// ⚠️ 每帧调它就是上面 PreparedLine 要解决的那个开销。留着是因为**预览**那条路只画
    /// 静止的一帧(SectionPreviewBars),为一帧去建整条长图不划算。
    static func image(text: String, width: CGFloat, offset: CGFloat) -> NSImage? {
        let boxWidth = ceil(width)
        guard boxWidth > 0, !text.isEmpty else { return nil }
        let font = Self.font
        // 上下各留 1pt,避免 'g'/'q' 的下伸部分和中文的某些字形被裁掉一丝。
        let boxHeight = ceil(font.ascender - font.descender) + 2
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            // 模板图只看 alpha,这里用什么颜色都一样;给个不透明的黑保证 alpha 是满的。
            .foregroundColor: NSColor.black,
        ]
        // 用 drawingHandler 这个形式而不是 lockFocus:AppKit 会在需要的每种 backing scale
        // 下各调一次这个闭包,Retina 屏上就是实打实的 2x 重绘,文字不会糊。
        let image = NSImage(size: NSSize(width: boxWidth, height: boxHeight), flipped: false) {
            _ in
            // flipped: false → 原点在左下、y 向上。NSString.draw(at:) 收的是文本框左下角,
            // 所以 y 给 1 就是"底部留 1pt 内边距"。超出这张图的部分由绘制上下文自动裁掉,
            // 这正是"窗口"效果的来源。
            (text as NSString).draw(
                at: NSPoint(x: -offset, y: 1), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }
}
