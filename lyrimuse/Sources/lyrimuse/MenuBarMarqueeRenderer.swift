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

    /// 画一张宽度恒为 `width` 的模板图,文字整体向左偏移 `offset` 点。
    ///
    /// offset 只往左(取值 >= 0):跑马灯是"文字从右往左走过一个固定的窗口",窗口本身不动。
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
