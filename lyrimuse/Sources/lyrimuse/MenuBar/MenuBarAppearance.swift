import AppKit
import Combine
import SwiftUI

// 「菜单栏此刻是深的还是浅的」——以及由它决定的两个歌词颜色(2026-09-03)。
//
// ---- 为什么需要这么一个东西 ----
//
// 菜单栏歌词的两个颜色默认都是「跟随系统」:文字色 = `labelColor`,已唱到 = 系统强调色
// (深色菜单栏上再向白提亮四成)。`labelColor` 是**动态色** —— 同一个 `NSColor` 在深色
// appearance 下解析成白、浅色下解析成黑,取值时"当前是哪个 appearance"决定一切。
//
// 于是同一个「跟随系统」在三个宿主里给出了三个答案(2026-09-03 用户截图报的):
//   * **真实菜单栏**:状态栏按钮的 appearance 是菜单栏那一档(用户机器上是深的)→ **白字**,对;
//   * **设置页的色块**:`Color(nsColor: .labelColor)` 在**设置窗口**(浅色)里求值 → **黑块**;
//   * **设置页的预览**:那条预览用的是真的 `MenuBarScrollingLabel`,但它嵌在设置窗口里,
//     `effectiveAppearance` 同样是浅色 → 画出**黑字**。
// 三处说的是同一件事、画出来三个样,而用户要照着色块和预览去判断菜单栏上会看到什么。
//
// 修法是把"按哪个 appearance 解析"从各自的宿主里拿出来,统一钉到**真实状态栏那一项**上。
// 明暗还会变(切深浅色模式、换壁纸让菜单栏由亮转暗),所以做成 ObservableObject,由挂在
// 真实按钮上的那一层(`MenuBarHoverControlsView`,它只存在于真菜单栏,预览里没有)在
// `viewDidChangeEffectiveAppearance` 时喂进来,设置页订阅它自动重画。
@MainActor
final class MenuBarAppearanceStore: ObservableObject {
    static let shared = MenuBarAppearanceStore()

    /// 真实菜单栏此刻是不是深色。初值取系统外观 —— 状态栏项建起来之前(App 刚启动那一瞬)
    /// 没有别的依据,而绝大多数情况下两者一致。
    @Published private(set) var isDark: Bool = NSApp?.effectiveAppearance
        .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

    private init() {}

    /// 由真实状态栏那一项上的视图喂进来。⚠️ **只能**由真菜单栏上的视图调用:预览里那份
    /// `MenuBarScrollingLabel` 的 appearance 是设置窗口的,喂进来就把这里污染成浅色了。
    func update(from view: NSView) {
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard dark != isDark else { return }
        isDark = dark
    }

    /// 拿去给别的视图/求值用的 appearance。
    var appearance: NSAppearance {
        NSAppearance(named: isDark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
    }

    /// SwiftUI 那一侧的同一件事(预览里的 `.ultraThinMaterial`、wifi/电池那几个参照物的
    /// 语义色都靠它跟着变)。
    var colorScheme: ColorScheme { isDark ? .dark : .light }
}

extension NSColor {
    /// 把一个**动态色**在指定 appearance 下定型成具体的 RGB。
    ///
    /// 设置页那两个色块要的就是这个:`ColorPicker` 拿到的是一个静态 `Color`,它不会再随
    /// 宿主的 appearance 变 —— 所以必须在**菜单栏那一档**下取值,而不是让它在设置窗口
    /// (浅色)里自己解析。
    func resolved(in appearance: NSAppearance) -> NSColor {
        var out = self
        appearance.performAsCurrentDrawingAppearance {
            out = usingColorSpace(.sRGB) ?? self
        }
        return out
    }
}
