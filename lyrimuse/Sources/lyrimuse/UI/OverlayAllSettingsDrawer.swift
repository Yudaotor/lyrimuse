import LyrimuseCore
import SwiftUI

// 「歌词显示 → 悬浮歌词」那一段底部的**全部设置**抽屉。
//
// 编辑台 + 工具栏浮层已经接管了高频项,卡片列剩下的职责只有一个:**全量兜底通路**。既然是兜底,
// 就没有理由常年占着两屏,收成一个默认折叠的抽屉,展开是就地长出来(不跳页、不开新窗口:那两种都会
// 让"改一项、回头看一眼编辑台"变成来回切换)。
//
// 「桌面悬浮歌词」总开关**不收进来**。它是这一段的主开关,收进折叠区等于"要先展开
// 才能开这个形态";它留在编辑台正下方那张 modeToggleCard 里常驻可见。
//
// 抽屉里的每一组都是**别处那份组件**,这里只有外壳;**分组、顺序、标题跟工具栏各个入口一一
// 对应**(主题 → 字形 → 颜色 → 内容 → 排版(含宽度)→ 行为 → 位置 → 恢复默认),展开后一组一张卡。别给抽屉另起一套分组名:
// 用户是按工具栏的记忆到抽屉里找的,对不上名就会落空:
//   - 主题 / 字形 / 颜色 / 内容 / 排版 → OverlayStyleSettingsRows.swift(跟工具栏那几个浮层同一份)。
//     「跟随封面」在「主题」组,理由见 OverlayThemeSettingsRows 头注
//   - 行为 → OverlayBehaviorSettingsRows.swift(行为项 + 自动隐藏几项,跟工具栏「行为」浮层同一份视图)
//   - 位置 → OverlayPlacementSettingsRows.swift
//   - 恢复 → OverlayStyleDefaults.restoreTextAndColors()(跟工具栏「重置 ▾」同一个动作)
// 「宽度」那根滑杆写在本文件里,放在「排版」卡最后、自己一个框 ——
// 它跟编辑台里那条宽度调整条是同一个值的两个入口:
// 那边 step 2、紧挨着窗口、看得见效果;这边 step 10、跟其它设置行同列,是键盘/VoiceOver 和
// "我想输个准数"的兜底通路。两处的落点约束一模一样(相等守卫 + classicOverlayEnabled 守卫 +
// 同一个 widthRange),改一处记得对一下另一处。
@MainActor
struct OverlayAllSettingsDrawer: View {
    @ObservedObject private var settings = AppSettings.shared
    /// 设置搜索命中了这个抽屉里的行时,根视图经 Environment 发下来的"该展开了"信号
    /// (Settings/SettingsSearch.swift)。
    @Environment(\.settingsSearchPendingDrawer) private var pendingSearchDrawer

    /// 展开状态用 @State 而不是 @AppStorage:设计要求是"默认折叠",而 @AppStorage 会把
    /// 上一次展开的样子带到下一次打开设置窗口 —— 那就不再是"默认折叠"了。
    @State private var isExpanded = false

    var body: some View {
        // 展开后每组各成一张卡(组名粗体卡头,组内小标题是圆角分组框,同浮层),不并成一张三屏长的卡:
        // 组名和组内小标题都是灰色小字时两级看起来一样,分不清谁是谁的下级。
        VStack(spacing: 14) {
            SettingsCard(cornerRadius: 18) {
                disclosureHeader
            }
            if isExpanded {
                // 主题 / 字形 / 颜色三组,分法见 OverlayStyleSettingsRows.swift 里 OverlayTypeSettingsRows 的头注。
                // 顺序跟编辑台工具栏那几颗按钮一致 —— 抽屉的职责是"工具栏浮层的全量兜底通路",
                // 两个宿主分组不一样的话,用户按工具栏的记忆到抽屉里找会落空。
                //
                // 「我的配色主题」在「主题」组里(OverlayThemeSettingsRows 的第二段),不单独占一组。
                SettingsGroupCard(title: L10n.t("主题")) { OverlayThemeSettingsRows() }
                SettingsGroupCard(title: L10n.t("字形")) { OverlayTypeSettingsRows() }
                SettingsGroupCard(title: L10n.t("颜色")) { OverlayColorSettingsRows() }
                // 跟工具栏「内容」浮层同名、同一份视图。
                SettingsGroupCard(title: L10n.t("内容")) { OverlayContentSettingsRows() }
                // 「宽度」放在「排版」卡最后、自己一个框:它讲的也是版面,放在「间距」后面不加框会读成间距的第四行。
                SettingsGroupCard(title: L10n.t("排版")) {
                    SettingsRowGroupStack {
                        OverlayLayoutSettingsRows()
                        SettingsRowGroup { widthRow }
                    }
                }
                SettingsGroupCard(title: L10n.t("行为")) { OverlayBehaviorSettingsRows() }
                // 排在「行为」之后 = 工具栏第二行的顺序(排版 / 行为 / 位置)。
                SettingsGroupCard(title: L10n.t("位置")) { OverlayPlacementSettingsRows() }
                resetRow
            }
        }
        // 设置搜索命中抽屉里的行时自动展开:抽屉默认折叠、状态是 @State,
        // 不展开的话被高亮的那一行根本不在屏幕上。onAppear 管"分段刚切过来、抽屉刚建出来",
        // onChange 管"抽屉已经在屏、信号后到"。展开动画跟点标题那一处同一条。
        .onAppear { expandForSearchIfNeeded() }
        .onChange(of: pendingSearchDrawer) { _, _ in expandForSearchIfNeeded() }
        // 这里**故意没有** `.animation(_:value: isExpanded)`。展开/收起的动画写在改状态
        // 那一处(disclosureHeader 里的 withAnimation)—— 挂在卡片上动的是容器自身的几何,
        // 同一个事务里任何不相干的布局变化都会被一起动起来(理由见
        // Animation.settingsCardReveal 的声明)。抽屉里恰恰有
        // 一堆这种变化:拖字号滑杆、开关「文字描边」让「描边颜色」那行长出来、存一个新主题让
        // 列表多一行。
    }

    private func expandForSearchIfNeeded() {
        guard pendingSearchDrawer == .overlay else { return }
        if !isExpanded {
            withAnimation(.settingsCardReveal) { isExpanded = true }
        }
        SettingsSearchRouter.shared.consumeDrawer(.overlay)
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
            // 折起来时标题右边列出里面有哪几组(固定的组名,跟下面渲染顺序一致),不点开也知道里面有什么。
            // 不放当前值摘要:当前值在工具栏各按钮上。
            HStack(spacing: SettingsRowMetrics.iconTextSpacing) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: SettingsRowMetrics.iconWidth, alignment: .center)
                Text(L10n.t("全部设置"))
                    .font(.system(size: 13))
                // Spacer 是**必需**的:整行可点靠的是下面那句 `contentShape(Rectangle())`,而它认的是
                // HStack 的实际尺寸 —— 没有 Spacer 撑满宽度,命中区就缩回"三角形 + 两个字"那一小截。
                Spacer(minLength: 12)
                if !isExpanded {
                    Text(Self.groupNames)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
            .padding(.vertical, SettingsRowMetrics.verticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.glassRow)
        .accessibilityLabel(L10n.t("全部设置"))
        // VoiceOver 里这一行是"展开/收起"而不是普通按钮 —— 抽屉是键盘用户到达这些配置项的唯一入口,
        // 读不出"已折叠"的话,这一整段听上去就只有一个孤零零的按钮。
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
        .accessibilityValue(isExpanded ? L10n.t("已展开") : L10n.t("已折叠"))
    }

    /// 抽屉头右侧那串组名,顺序跟 body 里各组卡的顺序一致(改了分组两处一起改)。
    private static var groupNames: String {
        [L10n.t("主题"), L10n.t("字形"), L10n.t("颜色"), L10n.t("内容"), L10n.t("排版"),
         L10n.t("行为"), L10n.t("位置")].joined(separator: " · ")
    }

    // MARK: - 宽度与恢复

    /// 宽度滑杆。编辑台里那条宽度调整条改的是同一个值,这里是它的兜底通路(键盘/VoiceOver,
    /// 以及"我想输一个准数"的场合)。
    ///
    /// 区间是**跨三处的契约**(真源见 `OverlayEditorStage.widthRange`):这根滑杆、菜单栏快捷面板里的同一根、
    /// 以及编辑台调整条的 `OverlayEditorStage.widthRange`。三处必须一致:任何一处能产生别处
    /// 够不到的值,用户下次一动另一根滑杆就会被弹回去,表现是"我调好的宽度自己变了"。
    private var widthRow: some View {
        SettingsRow(icon: "arrow.left.and.right", title: L10n.t("宽度")) {
            HStack(spacing: 8) {
                // SteppedSlider 而不是原生带步长的构造器:后者会在轨道下面画一排刻度点,量化语义一模一样。
                SteppedSlider(value: Binding(
                    get: { settings.overlayWidth },
                    set: { newValue in
                        // 相等守卫:Slider 拖动中会按鼠标事件频率重复调 set,值经 step
                        // 量化后大量重复 —— @Published 是 willSet 语义,等值赋值照样
                        // 广播 objectWillChange 打醒所有观察 AppSettings 的界面,didSet
                        // 还会同步写一次 UserDefaults。
                        guard newValue != settings.overlayWidth else { return }
                        settings.overlayWidth = newValue
                        // `LyricsOverlayWindowController.shared` 是 `static let`,光是读一下
                        // 就会执行 init() 把窗口建出来 —— 悬浮歌词关着的用户,只要碰一下这根
                        // 滑杆就会凭空多出一扇(不可见但已经装好监听器和观察者的)窗。宽度的
                        // 另外两个写入点(编辑台调整条 OverlayEditorStage.widthBinding / 菜单栏快捷
                        // 面板 MenuBarPanelQuickSettings)同样带这条守卫。重新打开时 setVisible 会按
                        // 持久化值把几何一并应用上。
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

    /// 「恢复默认」。
    ///
    /// 动作本体在 OverlayStyleDefaults.restoreTextAndColors() —— 编辑台工具栏的「重置 ▾」
    /// 菜单执行的是同一件事,两处**不能**各写一份赋值:以后新增一个外观字段时很容易只往
    /// 其中一处补上,表现为"从菜单点恢复和从抽屉点恢复,恢复出来的样子不一样"。
    ///
    /// 副标题是这颗按钮的**作用范围声明**,不是装饰:它只恢复主题、字形、颜色几组,「内容」「排版」
    /// 「行为」「位置」几个浮层里的项和宽度一个都不碰,副标题把没覆盖的念出来,跟菜单栏那颗同一个
    /// 句式(见 MenuBarStyleDefaults 头注)。排版和行为该不该纳入是产品取舍。
    /// 抽屉展开后单独一张卡,挂在各组卡最后。
    private var resetRow: some View {
        SettingsCard(cornerRadius: 18) {
            SettingsRow(
                icon: "arrow.uturn.backward",
                title: L10n.t("恢复默认"),
                subtitle: L10n.t("不含内容、排版、行为、位置和宽度")
            ) {
                Button(L10n.t("恢复")) { OverlayStyleDefaults.restoreTextAndColors() }
                    .buttonBorderShape(.capsule)
            }
        }
    }
}
