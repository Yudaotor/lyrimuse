import LyrimuseCore
import SwiftUI

// 「歌词显示 → 悬浮歌词」那三个**行为**项(锁定位置 / 拖动前先长按 / 划过让开)的唯一一份
// 实现,2026-08-30(编辑台第三步)从 SettingsView 的「窗口」卡里抽出来。
//
// 为什么抽:跟 OverlayStyleSettingsRows 同一个理由 —— 这三项现在有**两个**宿主:
//   ① 编辑台正下方那条独立的「行为」栏(OverlayBehaviorBar),三列小格、视觉上低一级;
//   ② 「全部设置」抽屉里「窗口」那一组(OverlayAllSettingsDrawer),键盘/VoiceOver/
//      "我就想找个开关"的全量兜底通路。
// 两个宿主的**排版**必然不一样(一个是三列格子、一个是标准设置行),但文案、图标和那个
// "改了要连带让真窗口生效"的 Binding 只有下面 OverlayBehaviorItem 这一份 —— 宿主只决定
// 怎么摆。这个仓库刚为"同一个属性两条路径"付过代价(「对齐方式」在预览条上失效),而设置项
// 漏改不会编译报错,只会变成"在行为栏里改了有用、在抽屉里改了没用"。
//
// 为什么把它们从「窗口」卡里提出来单独成一栏:这三项在编辑台上**看不出变化**(编辑台画的
// 是一张静态卡,没有点击穿透、没有拖动、没有指针悬停),混在配色/字体那些"改了当场看得见"
// 的项里,读者会一直等一个不会来的视觉反馈。提出来之后编辑台上方那一整块就只剩"所见即
// 所得"的项,行为项自己占一栏。
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
    /// ⚠️ 这两句**没有**套 `if settings.classicOverlayEnabled` 守卫,跟宽度那一路不一样 ——
    /// 这是**原样搬过来的既有行为**,不是漏写。宽度的三个写入点(编辑台调整条 / 菜单栏快捷
    /// 面板 / 抽屉滑杆)本来就都带守卫,而这两个开关从来没带过;要不要给它们补上是另一件事
    /// (牵涉控制器里 `isPositionLocked` 那份镜像会不会变陈旧,见那个属性声明处那段 bug 记录),
    /// 不该混在"把行搬个位置"这次改动里悄悄改掉。
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

// MARK: - 宿主②:编辑台下面那条「行为」栏

/// 编辑台正下方那一栏。三列排布,每格就是"标题 + 开关"一行(第十二步删掉最后一句副标题
/// 之后,三格的内容完全同构)。
///
/// 视觉上刻意比上面的卡低一级:标题只有 12pt、小字是次要色、整格垫一层比卡片更淡的底 ——
/// 这三项是"设一次就不动"的,不该跟字体/配色那些高频项抢注意力。
@MainActor
struct OverlayBehaviorBar: View {
    /// 三格之间的间距。
    private static let cellSpacing: CGFloat = 8

    var body: some View {
        SettingsCard {
            header
            HStack(alignment: .top, spacing: Self.cellSpacing) {
                ForEach(OverlayBehaviorItem.allCases) { item in
                    cell(item)
                        // maxHeight: .infinity 保的是**三格等高**:HStack 的高度取三格里最高
                        // 的那一格,再让每格撑满它。三格现在内容同构、本来就一样高,留着是因为
                        // 代价为零而失效是静默的 —— 哪天某一格的标题换行或多挂一个 ⓘ,少了这
                        // 一句就会变成底边参差不齐。
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
            .padding(.bottom, 12)
        }
    }

    /// 栏标题。
    ///
    /// 刻意不用 SettingsCardHeader:那个是"标题一行、说明另起一行"的两行结构,而这里只有一个
    /// 词,占不满两行。字号/字重/颜色/内边距全部沿用 SettingsCardHeader 的口径,不另立一套。
    ///
    /// (第十步之前标题右边还排着一句「这些改动在编辑台上看不出来,所以留在这儿」—— 把说明
    ///  挪到同一行是为了省下一行高度。那句按用户要求删了,`HStack` 留着:它撑的是标题左对齐
    ///  加尾部 Spacer 那套排版,换成裸 Text 反而要重调内边距。)
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L10n.t("行为"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, 7)
    }

    private func cell(_ item: OverlayBehaviorItem) -> some View {
        // 一行就够了。第十二步删掉最后一句副标题之后,原来那层 VStack(标题行 + 可选小字 +
        // 顶住上边的 Spacer)只剩下标题行 —— 留着它会在每格底下多垫一段 spacing + Spacer
        // 的空白,看着像"这里本该还有一句话没画出来"。
        HStack(spacing: 4) {
            Text(item.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                // 标题比开关重要:宽度不够时先让开关那一侧的最小间距去挤,别把标题
                // 截成"拖动前先长…"。
                .layoutPriority(1)
            Spacer(minLength: 4)
            Toggle("", isOn: item.binding)
                .labelsHidden()
                // ⚠️ 必须显式指定 .switch —— macOS 上 Toggle 默认画成复选框,只有在
                // Form/List 里才自动变开关(同 SettingsRow 里那条注释)。这一栏是自己
                // 用 VStack 搭的,不写这一句三个开关全是 ☑。
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(cellBackground)
    }

    // (第十步之前「划过让开」那一格底下还有一颗「预演」按钮:点一下让编辑台画布淡到 25% 再
    //  回来、约 1.2 秒演完,是这个开关在编辑台上唯一能"被看见"的方式。用户要求删掉,连带
    //  宿主那边的 overlayFadePreviewActive / overlayFadePreviewTask / playOverlayFadePreview
    //  和编辑台那三个时长常量一起清干净了。⚠️ 当年"刻意做成一次性演示、不去模拟'鼠标移到
    //  编辑台画布上就淡'"那条结论仍然有效:真视图对 isHoveringLyrics 的反应是整卡淡到 15%,
    //  在编辑台上接指针悬停就是"想点它、它就躲",见 OverlayEditorStage 里 OverlayPreviewChrome
    //  的注释。)

    /// 每一格的底。
    ///
    /// 跟编辑台底板一样刻意**不**用 settingsCardBackground 那套液态玻璃:这三格是嵌在
    /// 一张卡**里面**的,玻璃套玻璃只会糊成一片(SettingsGlassContainer 的 spacing 传 0
    /// 就是为了避免相邻的卡融成一整块)。一层低透明度中性填充 + 一条发丝描边,深浅色
    /// 模式下都成立。
    private var cellBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return shape
            .fill(Color.primary.opacity(0.04))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }
}
