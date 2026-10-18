import LyrimuseCore
import SwiftUI

// 「自动隐藏」三项(截屏时隐藏 / 暂停时隐藏 / 纯音乐/无歌词时隐藏)的唯一一份实现。第三项在灵动岛上是
// 「纯音乐/无歌词时收起歌词行」:只收歌词行、不整卡隐藏,标题和 ⓘ 按形态分开写。
//
// 这几项放在各形态的「行为」入口里,不单独开一张「自动隐藏」卡:它们跟「行为」里那几项(锁定位置 /
// 长按拖动 / 悬浮淡化 / 暂停时收起)是同一类东西 —— **设一次就不动、而且在编辑台上看不出任何变化**
// (判据见 OverlayBehaviorSettingsRows.swift 顶部)。
//
// **值按形态分两份,不能合成一份**(悬浮歌词 `hideDuringScreenCapture` / `hideWhenNotPlaying` /
// `hideWhenNoLyrics`,灵动岛 `notchHide*` / `notchCollapseLyricsWhenNoLyrics`)。按形态分栏展示,用户就会
// **按形态去理解**这些开关(「我在灵动岛页面关掉的,当然只关灵动岛」)。`AutoHideSurface` 最大的诱惑正是
// "共用一份值、按 surface 只换文案" —— **共用的是渲染与文案,不是值**:改文案两个形态一起变是预期的;
// Binding 必须按 surface 分流到各自的 AppSettings 键和各自的 WindowController。
//
// 同理**别把 AutoHideItem 并进 `OverlayBehaviorItem` 或 `NotchBehaviorItem`**:那两个枚举都是单形态的
// (Binding 里写死了自己那一个控制器),合并会立刻需要一个 surface 参数。
//
// **宿主有两处(每个形态一份分组视图),增删内容必须一起对**(漏一处不会编译报错,只会表现成
// "在这个入口改了有用、在那个入口找不到"):
//   ① 悬浮歌词:`OverlayBehaviorSettingsRows`(OverlayBehaviorSettingsRows.swift)
//   ② 灵动岛:`NotchBehaviorSettingsRows`(SettingsView.swift)
// 各自的工具栏「行为」浮层和「全部设置」抽屉「行为」组调的是同一份视图,自动隐藏这几项都经
// `AutoHideToggleTiles` 渲染。此外两个编辑台工具栏按钮上那句摘要(`OverlayEditorStage.behaviorSummary` /
// `NotchEditorStage.behaviorSummary`)也要把这几项算进去 —— 漏了就会出现"浮层里开关开着、按钮摘要
// 仍然写着「全部关闭」"这种会撒谎的派生值。

/// 自动隐藏这几项服务的是哪个形态。用来分流 Binding(各自的 AppSettings 键 + 各自的 WindowController);
/// 文案除了无歌词那一项(两个形态做的事不同)都逐字相同,理由见文件头。
enum AutoHideSurface {
    case desktopOverlay
    case notch
}

/// 自动隐藏开关的唯一真源:图标、文案(标题 / 副标题 / ⓘ 帮助)、以及那个"改了要连带
/// 让真窗口生效"的 Binding。
///
/// 类型本身**不**标 `@MainActor`(只有 `binding(for:)` 标)—— `title`/`subtitle`/`help` 走的是
/// `L10n.t()`,那是个刻意不带 actor 隔离的纯查找工具(见 L10n.swift 顶部注释),整个类型标上去
/// 只会把它们也圈进主线程。同 `OverlayBehaviorItem` / `NotchBehaviorItem`。
enum AutoHideItem: String, CaseIterable, Identifiable {
    case duringScreenCapture
    case whenNotPlaying
    case whenNoLyrics

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .duringScreenCapture: return "camera.viewfinder"
        case .whenNotPlaying: return "pause.circle"
        case .whenNoLyrics: return "text.badge.xmark"
        }
    }

    func title(for surface: AutoHideSurface) -> String {
        switch (self, surface) {
        case (.duringScreenCapture, _): return L10n.t("截屏时隐藏")
        case (.whenNotPlaying, _): return L10n.t("暂停时隐藏")
        case (.whenNoLyrics, .desktopOverlay): return L10n.t("纯音乐/无歌词时隐藏")
        case (.whenNoLyrics, .notch): return L10n.t("纯音乐/无歌词时收起歌词行")
        }
    }

    /// 都不带副标题。
    var subtitle: String? { nil }

    /// 截屏那一项的覆盖范围、无歌词那一项什么时候算「没有歌词」放在 ⓘ 气泡里。截屏那句**不写死是哪个形态**:同一份文案
    /// 悬浮歌词和灵动岛各渲染一次。
    func help(for surface: AutoHideSurface) -> String? {
        switch (self, surface) {
        case (.duringScreenCapture, _): return L10n.t("截屏、录屏和屏幕共享均无法捕捉，但你仍可正常看到")
        case (.whenNotPlaying, _): return nil
        case (.whenNoLyrics, .desktopOverlay): return L10n.t("搜索确认无歌词后才隐藏，搜索期间照常显示")
        case (.whenNoLyrics, .notch):
            return L10n.t("搜索确认无歌词后才收起，仅保留顶部窄条，悬停时仍可展开；搜索期间照常显示歌词行")
        }
    }

    /// 开关本体。
    ///
    /// **`.shared` 只准出现在 `set:` 闭包里,而且必须带 `if settings.xxxEnabled` 守卫。**
    /// 两个控制器都是 `static let shared`,**读一下就把整扇窗建出来**(含鼠标监听器和一堆
    /// 观察者,见 `NotchLyricsWindowController` 顶部那条不变量)。关着的那个形态一行都不能碰,
    /// 否则表现成"用户没开灵动岛,在设置页拨一下开关,屏幕顶上凭空冒出一个胶囊"。
    ///
    /// 控制器调用写在枚举内部(由每个宿主各传一份 Binding 会变成几份重复的守卫逻辑,漂移风险更大),
    /// 这条不变量因此没有结构性保证,只靠这条注释 —— 别删。
    ///
    /// `get:` 分支必须是**纯 AppSettings 读**,一个 `.shared` 都不许有。两条路径会在形态
    /// **关着**的时候求值 get:① 宿主的 body(设置项刻意不跟总开关联动,关着也照样渲染);
    /// ② 两个编辑台工具栏按钮上那句摘要(`OverlayEditorStage.behaviorSummary` /
    /// `NotchEditorStage.behaviorSummary`)为了拼串会读 `wrappedValue`。
    ///
    /// 悬浮歌词那两项顺序必须是**先写 AppSettings、再调控制器**(真值在 AppSettings,控制器只是镜像)。灵动岛那两项只写设置:
    /// 每个灵动岛实例(含镜像副本)自己订阅 `$notchHide*`(`NotchLyricsWindowController` init),这里不碰它的 `.shared`。
    ///
    /// 跳过被守卫拦下的那一次调用是**安全**的:两个控制器在 `setVisible` 真把窗口打开时都会
    /// 重新应用一遍这两个值(悬浮歌词见 `LyricsOverlayWindowController.setVisible`,灵动岛同理),
    /// 真值始终在 AppSettings、控制器只是镜像。
    @MainActor
    func binding(for surface: AutoHideSurface) -> Binding<Bool> {
        let settings = AppSettings.shared
        switch (surface, self) {
        case (.desktopOverlay, .duringScreenCapture):
            return Binding(
                get: { settings.hideDuringScreenCapture },
                set: { newValue in
                    settings.hideDuringScreenCapture = newValue
                    if settings.classicOverlayEnabled {
                        LyricsOverlayWindowController.shared.setHiddenFromCapture(newValue)
                    }
                })
        case (.desktopOverlay, .whenNotPlaying):
            return Binding(
                get: { settings.hideWhenNotPlaying },
                set: { newValue in
                    settings.hideWhenNotPlaying = newValue
                    if settings.classicOverlayEnabled {
                        LyricsOverlayWindowController.shared.setHideWhenNotPlaying(newValue)
                    }
                })
        case (.notch, .duringScreenCapture):
            return Binding(get: { settings.notchHideDuringScreenCapture },
                           set: { settings.notchHideDuringScreenCapture = $0 })
        // 开着这一项,灵动岛暂停后是整个 orderOut,**看不到"歌词行卷回顶行"那段收起动画**
        // (窗口都没了)。关掉才看得到。这是设置本身的语义,不写进 UI —— 用户试一下就知道。
        // 同一个「行为」入口里还有一项「暂停时收起」,两者都以"暂停"起头但不是一回事:那个是
        // 收起、这个是整扇窗消失,而这一项开着会盖住那个的效果。
        case (.notch, .whenNotPlaying):
            return Binding(get: { settings.notchHideWhenNotPlaying },
                           set: { settings.notchHideWhenNotPlaying = $0 })
        // 无歌词这一项只写设置:每个窗口实例(含灵动岛镜像副本)自己订阅这个值,不经这里调控制器。
        case (.desktopOverlay, .whenNoLyrics):
            return Binding(get: { settings.hideWhenNoLyrics }, set: { settings.hideWhenNoLyrics = $0 })
        case (.notch, .whenNoLyrics):
            return Binding(get: { settings.notchCollapseLyricsWhenNoLyrics },
                           set: { settings.notchCollapseLyricsWhenNoLyrics = $0 })
        }
    }
}

/// 标准设置行版本,每项一行,只把 `surface` 换掉。
///
/// `@ObservedObject` 是**必需**的,不是照抄的样板:宿主里 `NotchBehaviorPopover` 自己不观察 `AppSettings`,只靠父层(`AppearanceSettingsTab` /
/// `NotchEditorStage`)的对象级失效顺带刷新。新组件继续吃这个隐式依赖的话,哪天它被放进一个
/// 不观察 AppSettings 的宿主,开关就会显示陈旧值("在另一个入口改完再回来看,还是旧的")。
/// 同 `NotchLyricRowSettingsRows`。
@MainActor
struct AutoHideSettingsRows: View {
    let surface: AutoHideSurface
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(AutoHideItem.allCases.enumerated()), id: \.element.id) { index, item in
                if index > 0 { CardDivider() }
                SettingsRow(
                    icon: item.icon,
                    title: item.title(for: surface),
                    subtitle: item.subtitle,
                    help: item.help(for: surface)
                ) {
                    Toggle("", isOn: item.binding(for: surface))
                }
            }
        }
    }
}

/// 自动隐藏几项的小块版本,放进 `SettingsTileGrid`(一列一个开关太高)。内容、顺序都按 `AutoHideItem.allCases`。
@MainActor
struct AutoHideToggleTiles: View {
    let surface: AutoHideSurface
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ForEach(AutoHideItem.allCases) { item in
            SettingsToggleTile(icon: item.icon, title: item.title(for: surface), help: item.help(for: surface),
                               isOn: item.binding(for: surface))
        }
    }
}
