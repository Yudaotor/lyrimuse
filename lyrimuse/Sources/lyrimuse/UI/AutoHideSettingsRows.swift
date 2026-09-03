import LyrimuseCore
import SwiftUI

// 「自动隐藏」两项(截屏/录屏时隐藏 / 暂停·无播放时隐藏)的唯一一份实现,2026-09-02。
//
// **搬家史**(两次,一天之隔,方向不同,别把后一次读成前一次的回退):
//   ① 2026-09-01:原来它是「歌词显示」页第四段「其它」里一张跨形态的卡、**只有一份值**。
//      用户要求"把这两个配置全都塞到对应的页面里面去,悬浮歌词和灵动岛都塞一个进去",
//      于是「其它」段整个撤掉、值也拆成两份(`hideDuringScreenCapture`/`hideWhenNotPlaying`
//      归悬浮歌词,`notchHide*` 归灵动岛),两个形态各得一张独立的「自动隐藏」卡。
//   ② 2026-09-02(本文件):用户要求"不要单独放在外面,要遵循设计理念,放到行为卡片里面去"
//      —— 那两张独立卡整个删掉(连带 `SettingsView.autoHideCard(...)` 这个函数),两行并进
//      各形态**已经存在**的「行为」入口。
//
// 为什么并进「行为」是对的、而不是又一次挪窝:这两项跟「行为」里原有那几项(锁定位置 /
// 长按拖动 / 悬浮淡化 / 暂停缩回)是同一类东西 —— **设一次就不动、而且在编辑台上看不出
// 任何变化**。悬浮歌词那一组「行为」当初就是按这条判据从「窗口」卡里拆出来的
// (见 OverlayBehaviorSettingsRows.swift 顶部),截屏隐藏/暂停隐藏落进同一组是那条判据的
// 延伸,不是新规矩。
//
// **⚠️ 拆成两份值这一步没有回退,而且不能回退。** 一旦按形态分栏展示,用户就会**按形态去
// 理解**这两个开关(「我在灵动岛页面关掉的,当然只关灵动岛」)。本文件里 `AutoHideSurface`
// 这个新抽象最大的诱惑正是"共用一份值、按 surface 只换文案" —— 那是 2026-09-01 刚被推翻
// 的方案。**共用的是渲染与文案,不是值**:改文案两个形态一起变是预期的;Binding 必须按
// surface 分流到各自的 AppSettings 键和各自的 WindowController。
//
// ⚠️ 同理**别把 AutoHideItem 并进 `OverlayBehaviorItem` 或 `NotchBehaviorItem`**:那两个
// 枚举都是单形态的(Binding 里写死了自己那一个控制器),合并会立刻需要一个 surface 参数。
// (2026-09-02 之前这里还有第二条理由:`OverlayBehaviorItem` 当时的宿主之一是三列小格,
//  格子版式不画副标题和 ⓘ 气泡,并进 `allCases` 会静默丢掉文案。那张卡当天就被换成浮层了,
//  这条不再成立;**上面那条按形态分流的理由没变**。)
//
// ⚠️ **宿主有四个,增删内容必须四处一起对**(漏一处不会编译报错,只会表现成"在这个入口
// 改了有用、在那个入口找不到"):
//   ① 悬浮歌词:编辑台工具栏第二行「行为」浮层(`OverlayBehaviorPopover`)
//   ② 悬浮歌词:「全部设置」抽屉「窗口」组(`OverlayAllSettingsDrawer.windowGroup`)
//   ③ 灵动岛:编辑台工具栏「行为」浮层(`NotchBehaviorPopover`)
//   ④ 灵动岛:「全部设置」抽屉「行为」组(`NotchAllSettingsDrawer.behaviorGroup`)
// (① 2026-09-02 当天又搬过一次:并进来时它还是编辑台下面那张常驻卡 `OverlayBehaviorBar`
//  的末尾两行,同日用户要求"和灵动岛设置页一样…放到上面的小按钮里面,点了出现下拉框",
//  那张卡整个删掉、五项进了浮层。**值仍然是两份**,这次搬家不影响那条禁令。)
// 同一形态的两处 item 内容按既有约定必须**逐字相同**;此外两个编辑台工具栏按钮上那句摘要
// (`OverlayEditorStage.behaviorSummary` / `NotchEditorStage.behaviorSummary`)也要把这两项
// 算进去 —— 漏了就会出现"浮层里两个开关都开着、按钮摘要仍然写着「全部关闭」"这种会撒谎的
// 派生值。
//
// ⚠️ **分隔线的分工**(同 OverlayBehaviorSettingsRows / NotchBehaviorItemRows 的约定):
// 本组件只在**自己两行之间**插一条 `CardDivider()`,首尾都不插;"本组之前"那一条由宿主插。
// `SettingsCard` 只是 `VStack(spacing: 0)`,不会替谁补分隔线。

/// 这两行服务的是哪个形态。**只用来分流 Binding**(各自的 AppSettings 键 + 各自的
/// WindowController),不影响任何文案 —— 文案两个形态逐字相同,理由见文件头。
enum AutoHideSurface {
    case desktopOverlay
    case notch
}

/// 两项自动隐藏开关的唯一真源:图标、文案(标题 / 副标题 / ⓘ 帮助)、以及那个"改了要连带
/// 让真窗口生效"的 Binding。
///
/// 类型本身**不**标 `@MainActor`(只有 `binding(for:)` 标)—— `title`/`subtitle`/`help` 走的是
/// `L10n.t()`,那是个刻意不带 actor 隔离的纯查找工具(见 L10n.swift 顶部注释),整个类型标上去
/// 只会把它们也圈进主线程。同 `OverlayBehaviorItem` / `NotchBehaviorItem`。
enum AutoHideItem: String, CaseIterable, Identifiable {
    case duringScreenCapture
    case whenNotPlaying

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .duringScreenCapture: return "camera.viewfinder"
        case .whenNotPlaying: return "pause.circle"
        }
    }

    var title: String {
        switch self {
        case .duringScreenCapture: return L10n.t("截屏/录屏时隐藏")
        case .whenNotPlaying: return L10n.t("暂停/无播放时隐藏")
        }
    }

    /// ⚠️ 只有截屏那一项有副标题,`.whenNotPlaying` 恒为 nil —— 这是**原样保留**改版前的
    /// 文案组合,不是漏写。别顺手给另一项补一句:那会是一个新的 L10n 键(得同步进
    /// Localizable.xcstrings 再跑 generate-strings.py),而这次改动刻意做到零新增键。
    var subtitle: String? {
        switch self {
        case .duringScreenCapture: return L10n.t("别人看不到，你仍看得见")
        case .whenNotPlaying: return nil
        }
    }

    /// ⚠️ 措辞刻意**不写死是哪个形态**:同一份文案两个形态各渲染一次,改版前那句
    /// 「…都不会拍到悬浮歌词」摆在灵动岛那一段上就是错的。
    ///
    /// (`SettingsRow` 的声明处注释写着 subtitle 和 help「两者只用其一」,但它的 body 实际
    ///  两个都画:help 是标题右边那个 ⓘ 气泡、subtitle 是下面那行 11pt 小字。截屏这一行
    ///  改版前就是**同时**带这两样的,搬家时逐字保留 —— 别在这里"顺手规范化"成只留一个,
    ///  那会改掉用户看到的文案。)
    var help: String? {
        switch self {
        case .duringScreenCapture: return L10n.t("截图、录屏、视频会议共享屏幕都拍不到它")
        case .whenNotPlaying: return nil
        }
    }

    /// 开关本体。
    ///
    /// ⚠️ **`.shared` 只准出现在 `set:` 闭包里,而且必须带 `if settings.xxxEnabled` 守卫。**
    /// 两个控制器都是 `static let shared`,**读一下就把整扇窗建出来**(含鼠标监听器和一堆
    /// 观察者,见 `NotchLyricsWindowController` 顶部那条不变量)。关着的那个形态一行都不能碰,
    /// 否则表现成"用户没开灵动岛,在设置页拨一下开关,屏幕顶上凭空冒出一个胶囊"。
    ///
    /// 改版前这条不变量是**结构性**保证的:`autoHideCard` 只收 Binding、不认识任何控制器。
    /// 现在控制器被请进了枚举内部(四个宿主各传一份 Binding 会变成四份重复的守卫逻辑,那是
    /// 更大的漂移风险),防线因此退化成"靠这条注释" —— 所以它写在这里,别删。
    ///
    /// ⚠️ `get:` 分支必须是**纯 AppSettings 读**,一个 `.shared` 都不许有。两条路径会在形态
    /// **关着**的时候求值 get:① 四个宿主的 body(设置项刻意不跟总开关联动,关着也照样渲染);
    /// ② 两个编辑台工具栏按钮上那句摘要(`OverlayEditorStage.behaviorSummary` /
    /// `NotchEditorStage.behaviorSummary`)为了拼串会读 `wrappedValue`。
    ///
    /// ⚠️ 顺序必须是**先写 AppSettings、再调控制器**,不能只调控制器:副屏镜像走的是
    /// `AppSettings.$notchHide*` 的 Combine 广播(`NotchMirrorManager`),跳过写入会让副屏
    /// 静默不同步。
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
            return Binding(
                get: { settings.notchHideDuringScreenCapture },
                set: { newValue in
                    settings.notchHideDuringScreenCapture = newValue
                    if settings.notchOverlayEnabled {
                        NotchLyricsWindowController.shared.setHiddenFromCapture(newValue)
                    }
                })
        // ⚠️ 开着这一项,灵动岛暂停后是整个 orderOut,**看不到"歌词行卷回顶行"那段收起动画**
        // (窗口都没了)。关掉才看得到。这是设置本身的语义,不写进 UI —— 用户试一下就知道。
        // 同一个「行为」入口里还有一项「暂停缩回」,两者都以"暂停"起头但不是一回事:那个是
        // 缩回、这个是整扇窗消失,而这一项开着会盖住那个的效果。
        case (.notch, .whenNotPlaying):
            return Binding(
                get: { settings.notchHideWhenNotPlaying },
                set: { newValue in
                    settings.notchHideWhenNotPlaying = newValue
                    if settings.notchOverlayEnabled {
                        NotchLyricsWindowController.shared.setHideWhenNotPlaying(newValue)
                    }
                })
        }
    }
}

/// 两行标准设置行。四个宿主都调这一份,只把 `surface` 换掉。
///
/// ⚠️ `@ObservedObject` 是**必需**的,不是照抄的样板:四个宿主里 `OverlayBehaviorPopover` 和
/// `NotchBehaviorPopover` 自己都不观察 `AppSettings`,现在只靠父层(`AppearanceSettingsTab` /
/// `NotchEditorStage`)的对象级失效顺带刷新。新组件继续吃这个隐式依赖的话,哪天它被放进第五个
/// 不观察 AppSettings 的宿主,开关就会显示陈旧值("在另一个入口改完再回来看,还是旧的")。
/// 同 `NotchBehaviorItemRows`。
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
                    title: item.title,
                    subtitle: item.subtitle,
                    help: item.help
                ) {
                    Toggle("", isOn: item.binding(for: surface))
                }
            }
        }
    }
}
