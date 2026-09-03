import LyrimuseCore
import SwiftUI

// 「歌词显示 → 悬浮歌词」那一段底部的**全部设置**抽屉,2026-08-30(编辑台第三步)。
//
// 它替掉的是原来铺在编辑台下面的六张卡(总开关 / 配色 / 我的配色主题 / 文字 / 窗口 /
// 恢复)。那六张卡在 552pt 高的设置窗口里要滚两屏,而编辑台+工具栏浮层已经把高频项
// 全接管了 —— 卡片列剩下的职责只有一个:**全量兜底通路**。既然是兜底,就没有理由常年
// 占着两屏,收成一个默认折叠的抽屉,展开是就地长出来(不跳页、不开新窗口:那两种都会
// 让"改一项、回头看一眼编辑台"变成来回切换)。
//
// ⚠️ 「桌面悬浮歌词」总开关**不收进来**。它是这一段的主开关,收进折叠区等于"要先展开
// 才能开这个形态";它留在编辑台正下方那张 modeToggleCard 里常驻可见。
//
// ⚠️ 抽屉里的每一组都是**别处那份组件**,这里只有外壳:
//   - 主题 / 文字 / 背景 / 排版 → OverlayStyleSettingsRows.swift(跟工具栏那几个浮层同一份)。
//     ⚠️ 2026-09-02 从「配色 / 我的配色主题 / 文字 / 排版」重新分的组:原「配色」那七行混着
//     文字层和背景层,拆分判据见那个文件里 OverlayBackgroundSettingsRows 的头注
//   - 窗口里那三个行为项 → OverlayBehaviorSettingsRows.swift(跟上面那条行为栏同一份)
//   - 「窗口」组末尾那两行自动隐藏 → AutoHideSettingsRows.swift(2026-09-02 从撤掉的独立
//     「自动隐藏」卡并进来;跟行为栏那份、以及灵动岛「行为」浮层/抽屉那两处是同一个组件)
//   - 恢复 → OverlayStyleDefaults.restoreTextAndColors()(跟工具栏「重置 ▾」同一个动作)
// 「宽度」那根滑杆写在本文件里 —— 它跟编辑台里那条宽度调整条(2026-08-30 第六步替掉了
// 原来的拖拽握柄)是同一个值的两个入口:那边 step 2、紧挨着窗口、看得见效果;这边 step 10、
// 跟其它设置行同列,是键盘/VoiceOver 和"我想输个准数"的兜底通路。两处的落点约束一模一样
// (相等守卫 + classicOverlayEnabled 守卫 + 同一个 widthRange),改一处记得对一下另一处。
@MainActor
struct OverlayAllSettingsDrawer: View {
    @ObservedObject private var settings = AppSettings.shared

    /// 展开状态用 @State 而不是 @AppStorage:设计要求是"默认折叠",而 @AppStorage 会把
    /// 上一次展开的样子带到下一次打开设置窗口 —— 那就不再是"默认折叠"了。
    @State private var isExpanded = false

    var body: some View {
        SettingsCard {
            disclosureHeader
            if isExpanded {
                CardDivider()
                // 2026-09-02 重新分组:原来是「配色」(七行混着文字色和背景色)+ 一组无标题的
                // 「我的配色主题」,现在按"这个字段改的是哪一层"拆成 主题 / 文字 / 背景 三组
                // (拆分判据见 OverlayStyleSettingsRows.swift 里 OverlayBackgroundSettingsRows
                // 的头注)。顺序跟编辑台工具栏那几颗按钮一致 —— 抽屉的职责是"工具栏浮层的
                // 全量兜底通路",两个宿主分组不一样的话,用户按工具栏的记忆到抽屉里找会落空。
                //
                // 「我的配色主题」不再单独占一组:它现在长在「主题」组里(OverlayThemeSettingsRows
                // 的第二段),原来那组之所以没有组标题,就是因为它第一行本身就叫「我的配色主题」、
                // 再加一条组标题是同一句话说两遍 —— 并进「主题」之后这个别扭之处一起没了。
                themeGroup
                CardDivider()
                textGroup
                CardDivider()
                backgroundGroup
                CardDivider()
                layoutGroup
                CardDivider()
                windowGroup
                CardDivider()
                resetRow
            }
        }
        // ⚠️ 这里**故意没有** `.animation(_:value: isExpanded)`。展开/收起的动画写在改状态
        // 那一处(disclosureHeader 里的 withAnimation)—— 挂在卡片上动的是容器自身的几何,
        // 同一个事务里任何不相干的布局变化都会被一起动起来(理由见
        // Animation.settingsCardReveal 的声明,那条是踩过实例之后定下的)。抽屉里恰恰有
        // 一堆这种变化:拖字号滑杆、开关「跟随封面」让两行条件行长出来、存一个新主题让
        // 列表多一行。
    }

    // MARK: - 抽屉头

    /// 折叠/展开那一行。
    ///
    /// 用 Button 手搭而不是 DisclosureGroup:后者在 macOS 上自带一套三角形+缩进的排版,
    /// 跟这套卡片组件的行高、图标列、分隔线缩进全对不上,套进来会比自己画一行更费劲。
    ///
    /// 整行(不只是三角形)都可点:折叠区的标题是最常被点的地方,只让 12pt 的三角形接
    /// 事件等于逼人瞄准。`contentShape` 把命中范围抬到整行,包括右边那段留白。
    private var disclosureHeader: some View {
        Button {
            withAnimation(.settingsCardReveal) { isExpanded.toggle() }
        } label: {
            // (2026-08-30 按用户要求,标题右边那两句都删了:展开时的「键盘 / VoiceOver 的
            //  全量兜底通路…」和折起来时那串当前值摘要「系统字体 31pt · 跟随封面 · 486pt」。
            //  这一行现在就是一个三角形加两个字。)
            HStack(spacing: SettingsRowMetrics.iconTextSpacing) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: SettingsRowMetrics.iconWidth, alignment: .center)
                Text(L10n.t("全部设置"))
                    .font(.system(size: 13))
                // ⚠️ Spacer 是**必需**的,不是那两句话留下的残骸:整行可点靠的是下面那句
                // `contentShape(Rectangle())`,而它认的是 HStack 的实际尺寸 —— 没有 Spacer
                // 撑满宽度,命中区就缩回"三角形 + 两个字"那一小截。
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
            .padding(.vertical, SettingsRowMetrics.verticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("全部设置"))
        // VoiceOver 里这一行是"展开/收起"而不是普通按钮 —— 抽屉是键盘用户到达那 18 项的
        // 唯一入口(2026-08-30 的 16 项 + 2026-09-02 并进「窗口」组的两行自动隐藏),读不出
        // "已折叠"的话,这一整段听上去就只有一个孤零零的按钮。
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
        .accessibilityValue(isExpanded ? L10n.t("已展开") : L10n.t("已折叠"))
    }

    // MARK: - 各组

    private var themeGroup: some View {
        Group {
            SettingsCardHeader(title: L10n.t("主题"))
            CardDivider()
            OverlayThemeSettingsRows()
        }
    }

    private var backgroundGroup: some View {
        Group {
            SettingsCardHeader(title: L10n.t("背景"))
            CardDivider()
            OverlayBackgroundSettingsRows()
        }
    }

    private var textGroup: some View {
        Group {
            SettingsCardHeader(title: L10n.t("文字"))
            CardDivider()
            OverlayTextSettingsRows()
        }
    }

    /// 2026-08-31 从「文字」里拆出来的第二组(用户判断:双行显示和对齐方式是排版、不是字形,
    /// 拆的判据见 OverlayLayoutSettingsRows)。抽屉这边跟着拆,是因为抽屉的职责是"工具栏那
    /// 几个浮层的全量兜底通路" —— 浮层分了三组、抽屉还并成两组的话,同一批设置在两个宿主里
    /// 分组不一样,用户按浮层的记忆到抽屉里找会落空。
    private var layoutGroup: some View {
        Group {
            SettingsCardHeader(title: L10n.t("排版"))
            CardDivider()
            OverlayLayoutSettingsRows()
        }
    }

    /// ⚠️ 组名的不对称是**有意接受**的,不是漏改:页面上那张常驻卡叫「行为」,抽屉这一组叫
    /// 「窗口」,而 2026-09-02 起两处装的是同一批开关(三个行为项 + 两行自动隐藏)。抽屉这边按
    /// "这扇窗的事"归组(它还带着「宽度」滑杆),行为栏那边按"设一次就不动的行为"归组,两个
    /// 名字各自成立;要取齐就得连「宽度」一起重新分组,不值得为两行改动一整组的语义。
    private var windowGroup: some View {
        Group {
            SettingsCardHeader(title: L10n.t("窗口"))
            CardDivider()
            widthRow
            CardDivider()
            OverlayBehaviorSettingsRows()
            // 「自动隐藏」两行。⚠️ "本组之前"这条分隔线由宿主插,组件内部只在自己两行之间
            // 插一条 —— 见 AutoHideSettingsRows.swift 顶部那条约定,四个宿主一处都不能漏。
            CardDivider()
            AutoHideSettingsRows(surface: .desktopOverlay)
        }
    }

    /// 宽度滑杆。编辑台里那条宽度调整条改的是同一个值,这里是它的兜底通路(键盘/VoiceOver,
    /// 以及"我想输一个准数"的场合)。
    ///
    /// ⚠️ 区间是**跨三处的契约**(真源见 `OverlayEditorStage.widthRange`):这根滑杆、菜单栏快捷面板里的同一根、
    /// 以及编辑台调整条的 `OverlayEditorStage.widthRange`。三处必须一致:任何一处能产生别处
    /// 够不到的值,用户下次一动另一根滑杆就会被弹回去,表现是"我调好的宽度自己变了"。
    private var widthRow: some View {
        SettingsRow(icon: "arrow.left.and.right", title: L10n.t("宽度")) {
            HStack(spacing: 8) {
                // SteppedSlider 而不是原生带步长的构造器:后者会在轨道下面画一排刻度点
                // (2026-09-02 用户点名「没有意义,不好看」),量化语义一模一样。
                SteppedSlider(value: Binding(
                    get: { settings.overlayWidth },
                    set: { newValue in
                        // 相等守卫:Slider 拖动中会按鼠标事件频率重复调 set,值经 step
                        // 量化后大量重复 —— @Published 是 willSet 语义,等值赋值照样
                        // 广播 objectWillChange 打醒所有观察 AppSettings 的界面,didSet
                        // 还会同步写一次 UserDefaults。
                        guard newValue != settings.overlayWidth else { return }
                        settings.overlayWidth = newValue
                        // ⚠️ 2026-08-30 补上的守卫(原来这一句是裸调的)。
                        // `LyricsOverlayWindowController.shared` 是 `static let`,光是读一下
                        // 就会执行 init() 把窗口建出来 —— 悬浮歌词关着的用户,只要碰一下这根
                        // 滑杆就会凭空多出一扇(不可见但已经装好监听器和观察者的)窗。宽度的
                        // 另外两个写入点(编辑台调整条 OverlayEditorStage.widthBinding / 菜单栏快捷
                        // 面板 MenuBarPanelQuickSettings)本来就都带这条守卫,这里是最后一个
                        // 没带的。重新打开时 setVisible 会按持久化值把几何一并应用上。
                        if settings.classicOverlayEnabled {
                            LyricsOverlayWindowController.shared.setWidth(newValue)
                        }
                    }
                ), in: OverlayEditorStage.widthRange, step: 10)
                .frame(width: 150)
                Text(String(format: L10n.t("%@pt"), "\(Int(settings.overlayWidth))"))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }

    /// 「恢复默认主题、文字与背景」。
    ///
    /// 动作本体在 OverlayStyleDefaults.restoreTextAndColors() —— 编辑台工具栏的「重置 ▾」
    /// 菜单执行的是同一件事,两处**不能**各写一份赋值:以后新增一个外观字段时很容易只往
    /// 其中一处补上,表现为"从菜单点恢复和从抽屉点恢复,恢复出来的样子不一样"。
    ///
    /// ⚠️ 标题和副标题合起来是这颗按钮的**作用范围声明**,两个入口都要带,不是装饰。
    /// 2026-09-03 两句都改过,因为老那两句合起来在说谎:标题「恢复默认文字与配色」+ 副标题
    /// 「不含宽度和锁定位置」会让人理解成"除这两样之外都恢复",而实际上它只写 9 个字段,
    /// 「排版」「行为」两个浮层里的 6 项(双行显示 / 对齐方式 / 长按拖动 / 悬浮淡化 /
    /// 截屏录屏时隐藏 / 暂停无播放时隐藏)一个都不碰。
    /// 现在标题念**它真正覆盖的那三个浮层**、副标题念**没覆盖的**,跟菜单栏那颗同一个句式
    /// (见 MenuBarStyleDefaults 头注)。⚠️ 功能本身没改 —— 排版和行为该不该纳入是产品取舍,
    /// 不是这次要顺手动的东西。
    private var resetRow: some View {
        SettingsRow(
            icon: "arrow.uturn.backward",
            title: L10n.t("恢复默认主题、文字与背景"),
            subtitle: L10n.t("不含排版、行为和宽度")
        ) {
            Button(L10n.t("恢复")) { OverlayStyleDefaults.restoreTextAndColors() }
        }
    }
}
