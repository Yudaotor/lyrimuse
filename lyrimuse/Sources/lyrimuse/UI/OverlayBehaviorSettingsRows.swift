import LyrimuseCore
import SwiftUI

// 「歌词显示 → 悬浮歌词」那几个**行为**项(锁定位置 / 拖动前先长按 / 划过让开 / 悬停控制条)
// 的唯一一份实现,(编辑台第三步)从 SettingsView 的「窗口」卡里抽出来。
// (加第四项「悬停时显示控制条」;在那之前这里一直是三项,下面几处注释里的"三项"
//  已随之改口 —— `allCases` 的项数不是不变量,"自动隐藏那两行不进这个枚举"才是。)
//
// 为什么抽:跟 OverlayStyleSettingsRows 同一个理由 —— 这三项现在有**两个**宿主:
//   ① 编辑台工具栏第二行「行为」按钮点开的浮层(OverlayEditorStage.stagePopoverAnchors);
//   ② 「全部设置」抽屉里「行为」那一组(OverlayAllSettingsDrawer;前叫「窗口」、还带着
//      「宽度」滑杆,同日按"抽屉分组跟工具栏一一对应"拆开),键盘/VoiceOver/"我就想找个开关"的
//      全量兜底通路。
// 两个宿主调的都是下面同一个 `OverlayBehaviorSettingsRows`(三个行为项 + 两行自动隐藏
// 一起),不再各自拼一次 —— 灵动岛那边同日同一条改法(`NotchBehaviorSettingsRows`)。
// 两个宿主的**排版**曾经不一样(一个是三列格子、一个是标准设置行),但文案、图标和那个
// "改了要连带让真窗口生效"的 Binding 只有下面 OverlayBehaviorItem 这一份 —— 宿主只决定
// 怎么摆。这个仓库刚为"同一个属性两条路径"付过代价(「对齐方式」在预览条上失效),而设置项
// 漏改不会编译报错,只会变成"在行为栏里改了有用、在抽屉里改了没用"。
//
// 为什么把它们从「窗口」卡里提出来单独成一组:这三项在编辑台上**看不出变化**(编辑台画的
// 是一张静态卡,没有点击穿透、没有拖动、没有指针悬停),混在配色/字体那些"改了当场看得见"
// 的项里,读者会一直等一个不会来的视觉反馈。分出来之后编辑台画布上方那几个入口里,"所见即
// 所得"的(文字/配色/排版)排第一行,行为项自己占第二行。
//
// (第十步按做了一次纯删除:栏标题旁那句「这些改动在编辑台上看不出来,
//  所以留在这儿」、「锁定位置」那格的小字、「长按拖动」的副标题、以及「鼠标经过时避开」旁边
//  那颗「预演」按钮,全部删掉。分栏这件事本身没变,只是不再用文案把理由写在界面上。
//  紧接着的第十二步又删掉了最后一句 ——「鼠标经过时避开」的副标题「鼠标移到悬浮歌词上时它会淡
//  下去,移开恢复」。三项到此一句常显说明都不剩,`subtitle` 那个属性连同两个宿主里消费它
//  的分支一起清掉了:一个恒为 nil 的属性只会让下一个人以为"这里还能配一句"。「锁定位置」
//  的 ⓘ 帮助气泡**保留**,它交代的是解锁后点击会穿到桌面上,不是装饰。)
//
// 「宽度」**不在这一栏**:它已经能在编辑台里那条宽度调整条上直接改(看得见),抽屉里那根
// 滑杆只是兜底,不属于"设一次就不动"的行为项。
//
// **这一组末尾多两行,但它们不属于 `OverlayBehaviorItem`**:「截屏/录屏
// 时隐藏」和「暂停/无播放时隐藏」跟"行为"这一组一起展示,遵循"同一类设置归同一张卡"
// 的分组原则,不单独开一张「自动隐藏」卡。
// 它们的真源在 `UI/AutoHideSettingsRows.swift`(`AutoHideItem`),**不在** `OverlayBehaviorItem.allCases`
// 里;`OverlayBehaviorSettingsRows` 只是把 `AutoHideSettingsRows(surface: .desktopOverlay)`
// 接在这个枚举的各项后面。
// 别为了"都是行为项"把它们并进下面这个枚举:那两项要同时服务灵动岛(靠 `AutoHideSurface`
// 分流到 `notchHide*` 和另一个控制器),而 `OverlayBehaviorItem` 的 Binding 写死打的是悬浮窗
// 控制器。它们落在这一组里的判据跟这三项是同一条(在编辑台上看不出变化),这是那条判据的
// 延伸,不是新规矩。
// (之前这里还有一条理由:「`OverlayBehaviorBar` 的三列格子版式不画副标题和 ⓘ
//  气泡,并进 allCases 会把那两行的文案静默丢掉」。那张卡删掉之后这条不再成立 —— 浮层里
//  全是标准 `SettingsRow`,副标题和 ⓘ 都画得出来。**但上面那条按形态分流的理由没变**,
//  仍然不能合并。)

/// 三个行为项的唯一真源:文案、图标、以及那个"改了要连带让真窗口生效"的 Binding。
///
/// 做成一个枚举而不是三份写死的行:两个宿主都按 `allCases` 迭代,顺序和成员因此天然一致,
/// 以后增删一项也不会出现"行为栏加了、抽屉忘了"。
///
/// 类型本身**不**标 `@MainActor`(只有 `binding` 标)—— `title`/`subtitle` 走的是
/// `L10n.t()`,那是个刻意不带 actor 隔离的纯查找工具(见 L10n.swift 顶部注释),整个类型
/// 标上去只会把它们也一起圈进主线程,没有必要。
enum OverlayBehaviorItem: String, CaseIterable, Identifiable {
    case lockPosition
    case dragNeedsLongPress
    case fadeOnHover
    /// 悬停时露不露出那排播放控制按钮。排在 `fadeOnHover` 后面:两项都是
    /// "指针悬到歌词上会发生什么",放一起读者好对照(一个让歌词淡开、一个叫出按钮排)。
    case showHoverControls

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .lockPosition: return "lock"
        case .dragNeedsLongPress: return "hand.tap"
        case .fadeOnHover: return "cursorarrow.motionlines"
        // 这一项管的就是那排播放按钮本身,用播放/暂停符号最直白;不再用 cursorarrow 一族,
        // 免得跟上一行的「悬浮淡化」在图标上也撞成一对。
        case .showHoverControls: return "playpause.circle"
        }
    }

    var title: String {
        switch self {
        case .lockPosition: return L10n.t("锁定位置")
        case .dragNeedsLongPress: return L10n.t("长按拖动")
        case .fadeOnHover: return L10n.t("悬浮淡化")
        case .showHoverControls: return L10n.t("悬停时显示控制条")
        }
    }


    // (第十步之前这里还有一个 `barCaption`:行为栏那一格底下的小字。两项直接返回 `subtitle`,
    //  「锁定位置」另配一句「锁上后编辑台左下角会出现锁标」——它在卡片里本来就没有副标题,
    //  行为栏那一格空着会显得像漏了一句。把那句和「长按拖动」的副标题一起删掉,
    // 剩下的两项直接读 `subtitle` 就够了,这个属性没有存在理由了。 锁标本身**保留**,
    //  见 OverlayEditorStage.lockBadge。)

    /// 开关本体。
    ///
    /// `set` 里那句 WindowController 调用是**必须**的,不是顺手写的:AppSettings 里这几个
    /// @Published 的 didSet **只负责写 UserDefaults**("生效"这一步刻意留在 View 层,见
    /// AppSettings.lockPosition 声明处的注释),真窗口的点击穿透、鼠标监听器装卸都在
    /// LyricsOverlayWindowController 那边。丢掉就是"开关变了、真窗口纹丝不动"。
    ///
    /// 这两句**都套着** `if settings.classicOverlayEnabled` 守卫(补的,逐条理由
    /// 写在下面各自的行内注释里)。
    /// (这段话拆文件时写的是"这两句**没有**套守卫、是原样搬过来的既有行为",守卫
    ///  补上之后就过期了,更正。特意留一句而不是直接删:它正好会把
    ///  `UI/AutoHideSettingsRows.swift` 头注那条核心不变量读反 —— 那条说"`.shared` 只准出现在
    ///  set: 闭包里、必须带 `xxxEnabled` 守卫",而这里曾经写着"同族的行为项没有守卫"。)
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
                    // 屏幕上会凭空多出一扇窗。改造前设置页这里一直是裸调的(菜单栏面板那个
                    // 入口反而从一开始就带着守卫,两边不一致)。
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

/// 「行为」那一组:锁定位置 / 长按拖动 / 悬浮淡化 + 截屏/录屏时隐藏 / 暂停/无播放时隐藏。
/// 编辑台「行为」浮层(`OverlayEditorStage.stagePopoverAnchors`)和抽屉「行为」组(`OverlayAllSettingsDrawer`)调的
/// 是这同一份 —— 之前两处各自拼「三项 + 分隔线 + 自动隐藏两行」,靠注释警告别漏。
///
/// 行与行之间的 `CardDivider()` 由这个组件自己插 —— 宿主只知道"这里放一组行为设置",
/// 不该知道它内部有几行(同 OverlayTextSettingsRows 的做法)。`AutoHideSettingsRows` 自己只在
/// 它两行之间插一条,"本组之前"那一条在这里插(见那个文件头的约定)。
///
/// `@ObservedObject` 是**必需**的,不是照抄的样板:`item.binding` 是手搓的 `Binding(get:set:)`,
/// 写入不经过任何能让 SwiftUI 失效的通道,而这个视图一个存储属性都没有 —— 宿主刷新时 SwiftUI 判等
/// 相等就跳过它的 body,开关会画着陈旧值(表现与 `NotchBehaviorToggleRow` 那条一字不差)。
@MainActor
struct OverlayBehaviorSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            // 「位置」三选一**不在这一组**:它一度是这里的第一行,后来
            // 单开一颗「位置」入口,抽屉
            // 跟着单开一组,见 `OverlayPlacementSettingsRows.swift`。这一组是 `OverlayBehaviorItem`
            // 的各项开关 + 两行自动隐藏。
            ForEach(Array(OverlayBehaviorItem.allCases.enumerated()), id: \.element.id) { index, item in
                if index > 0 { CardDivider() }
                SettingsRow(icon: item.icon, title: item.title) {
                    Toggle("", isOn: item.binding)
                }
            }
            CardDivider()
            AutoHideSettingsRows(surface: .desktopOverlay)
        }
    }
}
