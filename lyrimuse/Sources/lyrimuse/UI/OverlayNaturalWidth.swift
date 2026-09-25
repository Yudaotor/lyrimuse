import AppKit
import SwiftUI

/// 悬浮窗歌词卡片四行字体的 AppKit 孪生(见 `AppSettings.overlayNSFonts`)。
///
/// 收成一个结构体而不是四个 `@Published`:它们必然同时变(同一次 `recomputeFonts()`),
/// 拆成四个只会让订阅方多写三条订阅、还得自己保证拿到的是同一代。
struct OverlayNSFonts: Equatable {
    var main: NSFont = .systemFont(ofSize: 20, weight: .bold)
    var romanization: NSFont = .systemFont(ofSize: 13, weight: .medium)
    var translation: NSFont = .systemFont(ofSize: 14, weight: .regular)
    var preview: NSFont = .systemFont(ofSize: 14, weight: .medium)
}

/// "这段文字不换行的话要多宽" —— 对唱两侧留白让多少全靠它
/// (`OverlayCardGeometry.elasticInsetScale`)。
///
/// **为什么不在布局阶段问 SwiftUI**:`WrapLayout` 一旦收到有限宽度提案就声明占满整宽,
/// 只有无宽度提案才如实作答;而要拿到那个答案就得在自定义 `Layout` 里对整棵卡片子树
/// 发一次无约束试探 —— 那棵子树里有 `TimelineView`、有 `OptionalTextStroke` 的 `Canvas`
/// 剪影,试探会把它们一起按"不换行"的尺寸走一遍,实测会让主歌词行真的按不换行摆出来、
/// 冲出卡片右边缘被窗口裁掉。测文字宽度不需要布局参与,`NSAttributedString` 直接量就是了。
///
/// 量的是**整串一行**的宽度,跟 `WrapLayout` 那边"逐词量宽再相加"会差一点点(词间 kerning),
/// 对这个用途够了 —— 它只决定留白让多少,差几 pt 不会让人看出来。
@MainActor
enum OverlayNaturalWidth {
    /// 量过的结果存住:同一句歌词在同一份字体下的宽度是常量,而调用点在 body 里,
    /// 每次状态变化都会问一遍。
    private static var cache: [Key: CGFloat] = [:]
    private static let cacheLimit = 256

    private struct Key: Hashable {
        let text: String
        let font: NSFont
    }

    static func width(_ text: String?, font: NSFont) -> CGFloat {
        guard let text, !text.isEmpty else { return 0 }
        let key = Key(text: text, font: font)
        if let hit = cache[key] { return hit }
        let w = (text as NSString).size(withAttributes: [.font: font]).width
        // 换歌换字号都会长新条目,粗暴清空即可 —— 它只是省重复测量,不是正确性依赖。
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = w
        return w
    }
}
