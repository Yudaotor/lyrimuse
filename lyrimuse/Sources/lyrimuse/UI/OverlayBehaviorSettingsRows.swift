import LyrimuseCore
import SwiftUI

// 「歌词显示 → 悬浮歌词」那三个**行为**项(锁定位置 / 拖动前先长按 / 划过让开)的唯一一份
// 实现,2026-08-30(编辑台第三步)从 SettingsView 的「窗口」卡里抽出来。
//
// 为什么抽:跟 OverlayStyleSettingsRows 同一个理由 —— 这三项现在有**两个**宿主:
//   ① 编辑台工具栏第二行「行为 ▾」点开的浮层(OverlayBehaviorPopover);
//   ② 「全部设置」抽屉里「窗口」那一组(OverlayAllSettingsDrawer),键盘/VoiceOver/
//      "我就想找个开关"的全量兜底通路。
// (2026-09-02 之前① 是编辑台正下方一张常驻卡 `OverlayBehaviorBar`,三列小格、视觉上低一级;
//  用户要求改成跟灵动岛一致的"点开才配置",那张卡整个删掉,理由写在 OverlayBehaviorPopover 上。)
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
// (2026-08-30 第十步按用户要求做了一次纯删除:栏标题旁那句「这些改动在编辑台上看不出来,
//  所以留在这儿」、「锁定位置」那格的小字、「拖动前先长按」的副标题、以及「划过让开」旁边
//  那颗「预演」按钮,全部删掉。分栏这件事本身没变,只是不再用文案把理由写在界面上。
//  紧接着的第十二步又删掉了最后一句 ——「划过让开」的副标题「鼠标移到悬浮歌词上时它会淡
//  下去,移开恢复」。三项到此一句常显说明都不剩,`subtitle` 那个属性连同两个宿主里消费它
//  的分支一起清掉了:一个恒为 nil 的属性只会让下一个人以为"这里还能配一句"。「锁定位置」
//  的 ⓘ 帮助气泡**保留**,它交代的是解锁后点击会穿到桌面上,不是装饰。)
//
// 「宽度」**不在这一栏**:它已经能在编辑台里那条宽度调整条上直接改(看得见),抽屉里那根
// 滑杆只是兜底,不属于"设一次就不动"的行为项。
//
// ⚠️ **2026-09-02 起这两个宿主里各多两行,但它们不属于 `OverlayBehaviorItem`**:「截屏/录屏
// 时隐藏」和「暂停/无播放时隐藏」原来是设置页上一张独立的「自动隐藏」卡,用户要求"不要单独
// 放在外面,要遵循设计理念,放到行为卡片里面去",于是并进了「行为」这一组和抽屉「窗口」组。
// 它们的真源在 `UI/AutoHideSettingsRows.swift`(`AutoHideItem`),`OverlayBehaviorItem.allCases`
// **仍然恒为三项**。
// 别为了"都是行为项"把它们并进下面这个枚举:那两项要同时服务灵动岛(靠 `AutoHideSurface`
// 分流到 `notchHide*` 和另一个控制器),而 `OverlayBehaviorItem` 的 Binding 写死打的是悬浮窗
// 控制器。它们落在这一组里的判据跟这三项是同一条(在编辑台上看不出变化),这是那条判据的
// 延伸,不是新规矩。
// (2026-09-02 之前这里还有一条理由:「`OverlayBehaviorBar` 的三列格子版式不画副标题和 ⓘ
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

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .lockPosition: return "lock"
        case .dragNeedsLongPress: return "hand.tap"
        case .fadeOnHover: return "cursorarrow.motionlines"
        }
    }

    var title: String {
        switch self {
        case .lockPosition: return L10n.t("锁定位置")
        case .dragNeedsLongPress: return L10n.t("长按拖动")
        case .fadeOnHover: return L10n.t("悬浮淡化")
        }
    }


    // (第十步之前这里还有一个 `barCaption`:行为栏那一格底下的小字。两项直接返回 `subtitle`,
    //  「锁定位置」另配一句「锁上后编辑台左下角会出现锁标」——它在卡片里本来就没有副标题,
    //  行为栏那一格空着会显得像漏了一句。用户要求把那句和「拖动前先长按」的副标题一起删掉,
    //  剩下的两项直接读 `subtitle` 就够了,这个属性没有存在理由了。⚠️ 锁标本身**保留**,
    //  见 OverlayEditorStage.lockBadge。)

    /// 开关本体。
    ///
    /// ⚠️ `set` 里那句 WindowController 调用是**必须**的,不是顺手写的:AppSettings 里这几个
    /// @Published 的 didSet **只负责写 UserDefaults**("生效"这一步刻意留在 View 层,见
    /// AppSettings.lockPosition 声明处的注释),真窗口的点击穿透、鼠标监听器装卸都在
    /// LyricsOverlayWindowController 那边。丢掉就是"开关变了、真窗口纹丝不动"。
    ///
    /// ⚠️ 这两句**都套着** `if settings.classicOverlayEnabled` 守卫(2026-08-30 补的,逐条理由
    /// 写在下面各自的行内注释里)。
    /// (这段话 2026-08-30 拆文件时写的是"这两句**没有**套守卫、是原样搬过来的既有行为",守卫
    ///  补上之后就过期了,2026-09-02 更正。特意留一句而不是直接删:它正好会把
    ///  `UI/AutoHideSettingsRows.swift` 头注那条核心不变量读反 —— 那条说"`.shared` 只准出现在
    ///  set: 闭包里、必须带 `xxxEnabled` 守卫",而这里曾经写着"同族的行为项没有守卫"。)
    ///
    /// 「拖动前先长按」没有 WindowController 那一句:它是纯持久化项,长按判定每次鼠标事件
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
                    // ⚠️ 必须套 classicOverlayEnabled 守卫(2026-08-30 补)。
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

// MARK: - 宿主①:抽屉里的标准设置行

/// 「全部设置」抽屉「窗口」那一组里的三行。就是原来「窗口」卡下半截,一字未改地搬过来。
///
/// 行与行之间的 `CardDivider()` 由这个组件自己插 —— 宿主只知道"这里放一组行为设置",
/// 不该知道它内部有几行(同 OverlayTextSettingsRows 的做法)。
@MainActor
struct OverlayBehaviorSettingsRows: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(OverlayBehaviorItem.allCases.enumerated()), id: \.element.id) { index, item in
                if index > 0 { CardDivider() }
                SettingsRow(icon: item.icon, title: item.title) {
                    Toggle("", isOn: item.binding)
                }
            }
        }
    }
}

// MARK: - 宿主②:编辑台工具栏「行为」浮层

/// 编辑台工具栏第二行那颗「行为 ▾」点开的浮层(2026-09-02)。
///
/// **前身是编辑台正下方一张常驻卡 `OverlayBehaviorBar`**(三列小格 + 下面两行标准设置行),
/// 用户看过之后要求「你帮我和灵动岛设置页一样处理,放到上面的小按钮里面,点了出现下拉框」
/// —— 灵动岛那边同一批东西(`NotchBehaviorPopover`)早就是工具栏浮层,同一类设置在两个形态
/// 里长成两副样子,是用户读到的不一致。那张卡连同它的三列格子版式整个删掉。
///
/// 顺带解决了那张卡自己的一个结构性别扭:格子版式**只画"标题 + mini 开关"**,不画副标题
/// 也不画 ⓘ 气泡,而 2026-09-02 并进来的「截屏/录屏时隐藏」两样都有 —— 那时只能把它们摆在
/// 三列格子**外面**、走另一套版式,一张卡里两种行长相。浮层里全是标准 `SettingsRow`,五项
/// 长相一致。
///
/// ⚠️ **宽度 420 是实测值,别拍脑袋改**:瓶颈是英文标题 "Hide During Screenshots/Recording"
/// (216pt) + ⓘ(19pt),自动隐藏那两行的内容自然宽 271pt(中文)/ 385pt(英文),1pt 步进探出的
/// 英文不折行硬下限是 **386**;`SettingsRow` 的标题没有 `lineLimit`,超宽的表现是**折行**不是
/// 截断,而 ⓘ 跟标题同处一个 HStack 会垂直居中、尾部开关是 `.top` 对齐,三者当场错位。420 的
/// 余量 +34 跟 `NotchStylePopover` +28 / `NotchEarPopover` +24 / `OverlayLayoutPopover` +32
/// 同一档。上面那三项(锁定位置/长按拖动/悬浮淡化)都比它短,瓶颈不变。
/// 跟 `NotchBehaviorPopover` 同宽也让两个形态的「行为」浮层看起来是一件东西。
///
/// ⚠️ 内容必须跟 `OverlayAllSettingsDrawer.windowGroup` 和
/// `OverlayEditorStage.behaviorSummary` 三处一致 —— 抽屉那一组是这五项**不用点开浮层**就能
/// 摸到的兜底入口(键盘 / VoiceOver),别顺手把它也收进浮层。
@MainActor
struct OverlayBehaviorPopover: View {
    var body: some View {
        SettingsPopoverShell(title: L10n.t("行为"), width: 420) {
            OverlayBehaviorSettingsRows()
            // 「自动隐藏」两行。⚠️ "本组之前"这条分隔线由宿主插,组件内部只在自己两行之间
            // 插一条 —— 见 AutoHideSettingsRows.swift 顶部那条约定,四个宿主一处都不能漏。
            CardDivider()
            AutoHideSettingsRows(surface: .desktopOverlay)
        }
    }
}
