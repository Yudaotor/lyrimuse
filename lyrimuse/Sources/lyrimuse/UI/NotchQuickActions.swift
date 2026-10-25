import AppKit
import SwiftUI
import Combine
import LyrimuseCore
import os

/// 灵动岛展开卡那排播放键:播放控制被拦下时悬停弹那句说明(自绘气泡,见 `QuickActionTooltipOverlay`)。key 为 nil 不挂。
struct WithheldControlHint: ViewModifier {
    let key: String?
    let reason: String?
    @Binding var hovered: QuickActionHint?

    func body(content: Content) -> some View {
        if let key {
            content
                // 离开时只在记着的还是自己时才清,理由同 `quickActionButton`。
                .onHover { inside in
                    if inside, let reason {
                        hovered = QuickActionHint(key: key, text: reason)
                    } else if hovered?.key == key {
                        hovered = nil
                    }
                }
                .onChange(of: reason) { _, newReason in
                    guard hovered?.key == key else { return }
                    hovered = newReason.map { QuickActionHint(key: key, text: $0) }
                }
                .anchorPreference(key: QuickActionAnchorKey.self, value: .bounds) { [key: $0] }
        } else {
            content
        }
    }
}

/// 快捷操作那排键上此刻被指到的那一颗。`key` 用 SF Symbol 名(每颗键都不重复、且**不随状态变**),
/// `text` 是要弹的那句 —— 「显示 / 隐藏歌词」那颗的文案会跟着开关翻,所以两者得分开存:靠 key 认人,
/// 靠 text 显示(见 `quickActionButton` 里那条 `onChange`)。
struct QuickActionHint: Equatable {
    let key: String
    let text: String
}

/// 快捷操作那排图标键的悬浮文案提示。
///
/// 不能靠 `.help`:AppKit 的 tooltip(`NSToolTipManager`)只在前台 App 的窗口上显示,而 lyrimuse 是 LSUIElement、灵动岛这扇
/// `.nonactivatingPanel` 又刻意不激活 App(见 `NotchLyricsWindow.canBecomeKey` 那段),hover 的时候前台是用户正在用的那个 App,
/// 小黄框永远不会来(悬浮歌词那排图标同理,那边窗口点击穿透、连 hover 都收不到)。所以这里自绘,也别留 `.help()`:哪天 App 恰好
/// 在前台,系统气泡会跟自绘的这个一起弹两个。
///
/// **落点对准那颗键**:头部那排往**下**弹(下面是歌词行)、空闲面板那排往**上**弹(它贴着卡片底,
/// `idlePanelBottomSpacing` 只剩 10pt,往下会被窗口硬裁 —— 窗口恒按 `cardHeight` 开,放不进就是裁掉,
/// 不会自己长高)。气泡**不能**钉在按钮排**左侧**固定位置:指到最右那颗 ✕ 时
/// 气泡出现在最左边、跟高亮的键隔着四个图标,"这句话说的是哪颗"当场断掉。
///
/// 位置怎么来的:每颗键用 `anchorPreference` 把自己的 bounds 报上来(见 `quickActionButton`),这里
/// `proxy[anchor]` 取回来 —— **几何交给 SwiftUI 算**,不在这儿照着「22 + spacing 2 + 分隔线 1 + 6」
/// 再手写一份坐标(那种两处各算一份的数迟早会漂,同 `cardHeight` 与内容高度共用一个函数的理由)。
/// 挂在**整行**上而不是那排按钮上,是因为要把气泡收敛在卡片内:按钮排自己只有 100pt 宽,量不到
/// "内容区还剩多少"。气泡尺寸靠一层 `GeometryReader` 回填(同 `NotchScrubber` 量宽度的老办法),
/// 量到之前不显示 —— 否则第一帧会按半宽 0 定位、然后跳一下。
///
/// `overlay` 不参与布局,邻居一个像素不动(同 `NotchIconButton` 那条「悬停不许推动邻居」);整层
/// `allowsHitTesting(false)`,气泡不拦下面歌词行 / 顶行的点击。底色**破例用黑**、不用这张卡惯用的
/// `tint` 低透明度:它得**盖住**底下的歌词才读得清,而 tint 低透明度是透的;卡片永远深底(纯黑 /
/// 深色渐变 / 封面模糊),黑底气泡不突兀。
///
/// 时序照系统 tooltip 的手感:**首次悬停等 `initialDelayMs`** 再弹(扫过一排键时不该一路闪)、
/// **已经弹着时换键立即换字**。`shown` 与 `hovered` 因此是两个 state,不是一个。
struct QuickActionTooltipOverlay: ViewModifier {
    let hovered: QuickActionHint?
    @Binding var shown: QuickActionHint?
    let tint: Color
    /// 气泡贴在那颗键的哪一侧。
    let edge: VerticalEdge

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 气泡自己量出来的尺寸(见下面那层 preference)。**只用来收敛边界**,不是显示的前提 ——
    /// 量不到时走 `fallbackHeight` 那条降级路,气泡照画,只是不夹边;拿它当前提就变成
    /// "量不到 → 永远不显示"的全有全无。
    @State private var bubbleSize: CGSize = .zero

    private static let gap: CGFloat = 5
    /// 首次悬停到弹出的延迟。**跟系统 tooltip 在这个 App 里的延迟同一档** —— `AppDelegate` 把
    /// `NSInitialToolTipDelay` 注册成了 150(系统默认 1～1.5s "太长,容易被误以为悬浮提示没工作"),
    /// 自绘的这份要是另取一个数,同一个 App 里就有两种悬浮提示、两种手感。
    private static let initialDelayMs = 150
    /// 还没量到时的估算高度:11pt 字 + 上下各 3pt 内边距,离线量过就是 20。垂直位置对得上比
    /// 夹边重要 —— 差一点会压在键上。
    private static let fallbackHeight: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(QuickActionAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    if let shown, let anchor = anchors[shown.key] {
                        let key = proxy[anchor]
                        let half = bubbleSize.width / 2
                        let height = bubbleSize.height > 0 ? bubbleSize.height : Self.fallbackHeight
                        bubble(shown.text)
                            // 量自己多宽多高,回填给上面收敛用。走 preference 而不是
                            // `onAppear`:preference 是布局的产物,不靠视图生命周期的回调
                            // (同 `SettingsPopoverShell` 量浮层高度那份)。
                            .background(
                                GeometryReader { g in
                                    Color.clear.preference(key: QuickActionBubbleSizeKey.self,
                                                           value: g.size)
                                }
                            )
                            .position(
                                // 对准键的中心,再夹进内容区 —— 最右那颗 ✕ 的气泡不夹的话会溢出
                                // 卡片、被那道圆角裁掉半句话。
                                x: min(max(key.midX, half), max(half, proxy.size.width - half)),
                                y: edge == .bottom
                                    ? key.maxY + Self.gap + height / 2
                                    : key.minY - Self.gap - height / 2)
                    }
                }
                // 收在 overlay 里面接:气泡的 preference 只要传到同一层的这个祖先,不用穿出
                // overlay 边界。
                .onPreferenceChange(QuickActionBubbleSizeKey.self) { bubbleSize = $0 }
                .allowsHitTesting(false)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: shown)
            .task(id: hovered) {
                guard let hovered else {
                    shown = nil
                    return
                }
                if shown == nil {
                    try? await Task.sleep(for: .milliseconds(Self.initialDelayMs))
                    if Task.isCancelled { return }
                }
                shown = hovered
            }
            // 兜底:这块内容整个走掉时别把气泡的状态留在身上(展开/收起走的是透明度、不会 disappear,
            // 真正会走的是切屏幕镜像 / 关灵动岛那种整树重建)。
            .onDisappear { shown = nil }
    }

    /// 气泡本体。字形 11pt medium、`tint` **全亮** —— 它是"要读的那句话",不该比旁边 0.75 的图标还淡
    /// (次要 ≠ 该看不清)。
    private func bubble(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(bubbleTextColor)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    // 0.78 而不是更轻的一档:卡片底可以是**封面模糊**(亮封面时那块底是浅的),
                    // 离线渲染过 0.62 那版 —— 底下的字会从气泡里透出来。它的活儿是盖住,不是透。
                    .fill(Color.black.opacity(0.78))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(tint.opacity(0.14))
                    )
            )
            .fixedSize()
    }

    /// 气泡上的字:强调色在黑底上的对比度够正文那一档(≥ 4.5)就用它,不够就用白 —— 封面偏暗时强调色发黑,
    /// 黑字跟气泡底融在一起(05 章决策 74)。亮度公式同顶行胶囊的 `seamTextColor`。
    private var bubbleTextColor: Color {
        guard let ns = NSColor(tint).usingColorSpace(.sRGB) else { return .white }
        let lum = LocalPlaybackSource.relativeLuminance(
            r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
        return LocalPlaybackSource.contrastRatio(lum, 0) >= 4.5 ? tint : .white
    }
}

/// 气泡量出来的尺寸,只给 `QuickActionTooltipOverlay` 收敛边界用。
struct QuickActionBubbleSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// 那排键各自的位置(键名 → bounds),`quickActionButton` 报上来、`QuickActionTooltipOverlay` 取用。
struct QuickActionAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}
