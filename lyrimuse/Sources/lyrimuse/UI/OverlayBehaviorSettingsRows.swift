import LyrimuseCore
import SwiftUI

// 「歌词显示 → 悬浮歌词」那几个**行为**项(锁定位置 / 长按拖动 / 悬浮淡化 / 悬停时显示控制条)的唯一一份实现。
//
// 两个宿主:① 编辑台工具栏第二行「行为」按钮点开的浮层(OverlayEditorStage.toolbarButton);
// ② 「全部设置」抽屉里「行为」那一组(OverlayAllSettingsDrawer),键盘/VoiceOver/"我就想找个开关"的
// 全量兜底通路。两个宿主调的都是下面同一个 `OverlayBehaviorSettingsRows`(行为项 + 自动隐藏几项),
// 灵动岛那边是同一个做法(`NotchBehaviorSettingsRows`)。文案、图标和那个"改了要连带让真窗口生效"的
// Binding 只有 `OverlayBehaviorItem` 这一份:设置项漏改不会编译报错,只会变成"在浮层里改了有用、
// 在抽屉里改了没用"。
//
// 单独成一组的判据:这几项在编辑台上**看不出变化**(编辑台画的是一张静态卡,没有点击穿透、没有拖动、
// 没有指针悬停),混在配色/字体那些"改了当场看得见"的项里,读者会一直等一个不会来的视觉反馈。所以
// 编辑台画布上方那几个入口里,"所见即所得"的(文字/配色/排版)排第一行,行为项自己占第二行。
//
// 「宽度」**不在这一组**:它能在编辑台里那条宽度调整条上直接改(看得见),抽屉里那根滑杆只是兜底,
// 不属于"设一次就不动"的行为项。
//
// **自动隐藏那几项跟这一组一起展示,但不属于 `OverlayBehaviorItem`**:真源在
// `UI/AutoHideSettingsRows.swift`(`AutoHideItem`),这里只是把 `AutoHideToggleTiles(surface: .desktopOverlay)`
// 放在行为项后面。别为了"都是行为项"把它们并进下面这个枚举:那几项要同时服务灵动岛(靠
// `AutoHideSurface` 分流到灵动岛的键和另一个控制器),而 `OverlayBehaviorItem` 的 Binding 写死打的是
// 悬浮窗控制器。
//
// 例外是「全屏时隐藏」(`OverlayBehaviorItem.hideInFullScreen`):它只属于悬浮歌词(灵动岛的同名开关在
// `NotchBehaviorItem` 里),所以留在这个枚举,只是按 `isAutoHide` 画进「自动隐藏」那一格。

/// 行为项的唯一真源:文案、图标、以及那个"改了要连带让真窗口生效"的 Binding。
///
/// 做成一个枚举而不是几份写死的行:两个宿主都按 `allCases` 迭代,顺序和成员因此天然一致,
/// 以后增删一项也不会出现"行为栏加了、抽屉忘了"。
///
/// 类型本身**不**标 `@MainActor`(只有 `binding` 标)—— `title` 走的是
/// `L10n.t()`,那是个刻意不带 actor 隔离的纯查找工具(见 L10n.swift 顶部注释),整个类型
/// 标上去只会把它们也一起圈进主线程,没有必要。
enum OverlayBehaviorItem: String, CaseIterable, Identifiable {
    case lockPosition
    case dragNeedsLongPress
    case fadeOnHover
    /// 悬停时露不露出那排播放控制按钮。排在 `fadeOnHover` 后面:两项都是
    /// "指针悬到歌词上会发生什么",放一起读者好对照(一个让歌词淡开、一个叫出按钮排)。
    case showHoverControls
    /// 所在屏幕的当前 Space 是全屏 App 时整扇藏起来。画在「自动隐藏」那一格(`isAutoHide`),跟截屏 / 暂停
    /// 那几项并排;不并进 `AutoHideItem`:灵动岛的同名开关在 `NotchBehaviorItem` 里,两边不是一一对应。
    case hideInFullScreen

    var id: String { rawValue }

    /// 画在「自动隐藏」那一格、不在「窗口」那一格。
    var isAutoHide: Bool { self == .hideInFullScreen }

    var icon: String {
        switch self {
        case .lockPosition: return "lock"
        case .dragNeedsLongPress: return "hand.tap"
        case .fadeOnHover: return "cursorarrow.motionlines"
        // 这一项管的就是那排播放按钮本身,用播放/暂停符号最直白;不用 cursorarrow 一族,
        // 免得跟上一行的「悬浮淡化」在图标上也撞成一对。
        case .showHoverControls: return "playpause.circle"
        case .hideInFullScreen: return "arrow.up.left.and.arrow.down.right"
        }
    }

    var title: String {
        switch self {
        case .lockPosition: return L10n.t("锁定位置")
        case .dragNeedsLongPress: return L10n.t("长按拖动")
        case .fadeOnHover: return L10n.t("悬浮淡化")
        case .showHoverControls: return L10n.t("悬停时显示控制条")
        case .hideInFullScreen: return L10n.t("全屏时隐藏")
        }
    }

    /// ⓘ 帮助。只有「全屏时隐藏」有。
    var help: String? {
        switch self {
        case .hideInFullScreen: return L10n.t("所在屏幕有 App 全屏时隐藏")
        case .lockPosition, .dragNeedsLongPress, .fadeOnHover, .showHoverControls: return nil
        }
    }

    /// 开关本体。
    ///
    /// `set` 里那句 WindowController 调用是**必须**的,不是顺手写的:AppSettings 里这几个
    /// @Published 的 didSet **只负责写 UserDefaults**("生效"这一步刻意留在 View 层,见
    /// AppSettings.lockPosition 声明处的注释),真窗口的点击穿透、鼠标监听器装卸都在
    /// LyricsOverlayWindowController 那边。丢掉就是"开关变了、真窗口纹丝不动"。
    ///
    /// 这两句**都套着** `if settings.classicOverlayEnabled` 守卫(理由写在下面各自的行内注释里),
    /// 跟 `UI/AutoHideSettingsRows.swift` 里 `binding(for:)` 那条不变量一致:`.shared` 只准出现在
    /// set: 闭包里、必须带 `xxxEnabled` 守卫。
    ///
    /// 「长按拖动」没有 WindowController 那一句:它是纯持久化项,长按判定每次鼠标事件
    /// 现读 AppSettings(handleGlobalMouseEvent),不需要谁去"应用"一次。
    @MainActor
    var binding: Binding<Bool> {
        let settings = AppSettings.shared
        switch self {
        case .lockPosition:
            return Binding(
                get: { settings.lockPosition },
                set: { newValue in
                    settings.lockPosition = newValue
                    // 必须套 classicOverlayEnabled 守卫。
                    // `LyricsOverlayWindowController.shared` 是 `static let`,**光是读一下**
                    // 就会执行 init() 把窗口建出来 —— 悬浮歌词关着的用户点一下这个开关,
                    // 屏幕上会凭空多出一扇窗。
                    //
                    // 跳过这一句**不会**让控制器里的 isPositionLocked 镜像变陈旧,两处兜底:
                    //   ① 镜像的初始值就是从真值读的
                    //      (`@Published private(set) var isPositionLocked = AppSettings.shared.lockPosition`);
                    //   ② 窗口真被打开时会再应用一次(setVisible 里的 `setLocked(AppSettings.shared.lockPosition)`)。
                    // 真值始终在 AppSettings,控制器只是镜像 —— 这正是那份文件顶部注释
                    // 反复强调的不变量。
                    if settings.classicOverlayEnabled {
                        LyricsOverlayWindowController.shared.setLocked(newValue)
                    }
                })
        case .dragNeedsLongPress:
            return Binding(
                get: { settings.overlayDragNeedsLongPress },
                set: { settings.overlayDragNeedsLongPress = $0 })
        case .showHoverControls:
            // 纯持久化项,没有 WindowController 那一句 —— 两侧都是现读(View 侧经
            // OverlayPlayback 订阅、控制器侧每次鼠标事件直读),同 dragNeedsLongPress。
            // 也因此不需要 classicOverlayEnabled 守卫:这里根本不碰 `.shared`,
            // 不会把关着的悬浮窗凭空建出来。
            return Binding(
                get: { settings.overlayShowHoverControls },
                set: { settings.overlayShowHoverControls = $0 })
        // 只写设置:控制器自己订阅这个值(同「纯音乐/无歌词时隐藏」),不碰 `.shared`,也就不用守卫。
        case .hideInFullScreen:
            return Binding(get: { settings.overlayHideInFullScreen }, set: { settings.overlayHideInFullScreen = $0 })
        case .fadeOnHover:
            return Binding(
                get: { settings.overlayFadeOnHover },
                set: { newValue in
                    settings.overlayFadeOnHover = newValue
                    // 同 lockPosition:不套守卫的话,悬浮歌词关着时点它会把窗口建出来。
                    // 跳过同样安全 —— setFadeOnHover 只做 syncMouseMonitors() + 清理陈旧的
                    // 悬停态,不持有任何需要保持同步的镜像;而 syncMouseMonitors 在**可见性
                    // 变化**时本来就会被调一次,窗口真打开时监听器自然装得上。
                    if settings.classicOverlayEnabled {
                        LyricsOverlayWindowController.shared.setFadeOnHover(newValue)
                    }
                })
        }
    }
}

// MARK: - 「行为」组的行(浮层与抽屉同一份)

/// 「行为」那一组:锁定位置 / 长按拖动 / 悬浮淡化 / 悬停时显示控制条 + 自动隐藏几项(含 `OverlayBehaviorItem.hideInFullScreen`)。
/// 编辑台「行为」浮层(`OverlayEditorStage.toolbarButton`)和抽屉「行为」组(`OverlayAllSettingsDrawer`)调的
/// 是这同一份。
///
/// 分两组小块(三列):「窗口」(各项行为开关)、「自动隐藏」(`AutoHideToggleTiles`)。宿主只知道"这里放一组
/// 行为设置",不该知道它内部有几项(同 OverlayTypeSettingsRows)。
@MainActor
struct OverlayBehaviorSettingsRows: View {
    var body: some View {
        SettingsRowGroupStack {
            // 「位置」三选一**不在这一组**:它有自己的「位置」入口,抽屉里也单独一组,见
            // `OverlayPlacementSettingsRows.swift`。这一组是 `OverlayBehaviorItem` 的各项开关 + 自动隐藏几项。
            SettingsTileGrid(title: L10n.t("窗口"), columns: 3) {
                ForEach(OverlayBehaviorItem.allCases.filter { !$0.isAutoHide }) { item in
                    OverlayBehaviorToggleTile(item: item)
                }
            }
            SettingsTileGrid(title: L10n.t("自动隐藏"), columns: 3) {
                AutoHideToggleTiles(surface: .desktopOverlay)
                ForEach(OverlayBehaviorItem.allCases.filter(\.isAutoHide)) { item in
                    OverlayBehaviorToggleTile(item: item)
                }
            }
        }
    }
}

/// ForEach 的枚举项不随配置变化,只观察外层分组不能保证内部行刷新。
/// 每个开关小块独立观察配置,并在 body 中创建原有 Binding,把最新值传给控件。
@MainActor
private struct OverlayBehaviorToggleTile: View {
    let item: OverlayBehaviorItem
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let binding = item.binding
        return SettingsToggleTile(icon: item.icon, title: item.title, help: item.help, isOn: binding)
    }
}
