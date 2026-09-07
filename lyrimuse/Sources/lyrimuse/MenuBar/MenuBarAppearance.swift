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
// `viewDidChangeEffectiveAppearance` 时报信,设置页订阅它自动重画。
//
// ---- 为什么报信之后不能**当场读**,要等它坐稳(2026-09-07,预览"重建时闪一下") ----
//
// 状态栏项每次重建(`MenuBarStatusItem.rebuildStatusItem`,自适应模式下**逐句**都可能)都是
// `NSStatusBar.system.statusItem(withLength:)` 新建一个按钮。离屏探针(`scripts/statusitem-appearance-probe.swift`,
// 在这台 macOS 27 上抓的时间线)显示刚建出来的按钮**已经在窗口里**(`window != nil`,`isVisible`
// 也是 true),但窗口 frame 是 `{0,0},{17,0}` —— 高度 0、还没被状态栏排过版 —— 此时
// `effectiveAppearance` 是 **VibrantLight**(错的:菜单栏明明是深的);约 60ms 后状态栏给它排版,
// 6ms 内 `viewDidChangeEffectiveAppearance` 连发七次(DarkAqua / VibrantLight / DarkAqua /
// VibrantLight / VibrantDark / DarkAqua / VibrantDark),最后落在 VibrantDark。原来的做法是
// `installTracking` 当场读一次 + 每次 viewDidChange 当场读一次,于是每次重建 `isDark` 都先翻成
// false 再翻回 true,两次 @Published 之间隔着 40~60ms —— 设置页里整块舞台(材质、壁纸上那层
// `windowBackgroundColor` 薄纱、歌词字色、色块)跟着切成浅色再切回来,肉眼就是"重建时闪一下"。
// 帧级抓屏(`scripts/capture-window-frames.swift`,SCStream 120Hz)坐实:每次换句那一帧起区域平均亮度
// +44、2~3 帧后 −44,亮的那几帧里歌词是黑字、材质是浅色。
//
// 所以这里改成**报信只是排一次延迟读数**(`settleDelay`),期间再来的报信只是把读数往后推;
// 到点时按**当前登记的**观察点(不是报信那一刻的——旧按钮在 removeStatusItem 之后仍可能带着一个
// 没拆完的窗口)重读一次,窗口还没排过版(高度 0)就再等一轮。重建我们**自己**发起,菜单栏本身
// 的明暗不会因此改变,所以重建期间的一切读数都不该改动这个值;真正的明暗变化(切系统外观 /
// 换壁纸)照样会到 —— 只是晚 `settleDelay` 这么一点,而系统自己的切换动画都比这长。
@MainActor
final class MenuBarAppearanceStore: ObservableObject {
    static let shared = MenuBarAppearanceStore()

    /// 真实菜单栏此刻是不是深色。初值取系统外观 —— 状态栏项建起来之前(App 刚启动那一瞬)
    /// 没有别的依据,而绝大多数情况下两者一致。
    @Published private(set) var isDark: Bool = NSApp?.effectiveAppearance
        .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

    /// 观察点:真菜单栏上那颗状态栏按钮。弱引用 —— 按钮每次重建都是新的,旧的随旧项一起没了,
    /// 这里只认 `observe(_:)` 最后登记的那一颗。
    private weak var host: NSView?
    private var pendingSettle: DispatchWorkItem?

    /// 报信之后等多久再读。得盖过"新建按钮 → 状态栏排版 → appearance 连翻七次落定"这一整段
    /// (这台 27 机器上约 70ms;26.5.1 那台按 `rebuildStatusItem` 头注的记录,项落位要 0.3~1s,
    /// 排版应当在落位之前),又不能让真正的明暗变化显得迟钝。0.4s:系统切深浅色的过渡动画本身就
    /// 比这长,用户看不出这点延迟。
    nonisolated static let settleDelay: TimeInterval = 0.4
    /// 到点时窗口还没排过版就再等一轮,最多等这么多轮(2s)。再等不到就放弃这一轮,
    /// 等下一次报信 —— 排版落定时 appearance 若真的变了,`viewDidChangeEffectiveAppearance` 必到。
    private nonisolated static let maxSettleRetries = 5

    private init() {}

    /// 登记观察点(状态栏按钮首次建出 / 重建都要来一次)。⚠️ **只能**登记真菜单栏上的视图:
    /// 预览里那份 `MenuBarScrollingLabel` 的 appearance 是设置窗口的,登记进来就把这里污染成浅色了。
    func observe(_ view: NSView) {
        host = view
        scheduleSettle()
    }

    /// 观察点报告 effectiveAppearance 变了。⚠️ 这里**不读值**,只把延迟读数往后推 —— 理由见头注:
    /// 重建期间这个回调连发七次、七次里六次是错的。
    func hostAppearanceDidChange() {
        scheduleSettle()
    }

    private func scheduleSettle(retriesLeft: Int = maxSettleRetries) {
        pendingSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settle(retriesLeft: retriesLeft) }
        pendingSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private func settle(retriesLeft: Int) {
        pendingSettle = nil
        guard let host else { return }
        guard Self.isLaidOut(host.window) else {
            if retriesLeft > 0 { scheduleSettle(retriesLeft: retriesLeft - 1) }
            return
        }
        let dark = host.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard dark != isDark else { return }
        isDark = dark
    }

    /// 状态栏按钮所在窗口有没有被状态栏排过版。刚建出来的项窗口就在(`window != nil` 不够用),
    /// 但高度是 0;排过版才是 33(菜单栏高)。排版之前读到的 appearance 是 App 自己那一档,不是菜单栏的。
    static func isLaidOut(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.frame.height > 0
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
