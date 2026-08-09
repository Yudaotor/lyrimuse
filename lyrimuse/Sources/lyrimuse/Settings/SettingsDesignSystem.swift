import AppKit
import SwiftUI

// 设置窗口的一套卡片式组件(2026-08-06 新增)。参考 Dropover 的设置界面重做——它跟
// macOS 原生 `.formStyle(.grouped)` 的差别是结构性的,不是调调间距就能得到的:
//
// 1) 每页顶部有一个**居中的大标题 + 居中说明段落**。原生 Form 把标题交给工具栏
//    (navigationTitle),说明只能塞进 Section 的 header/footer。
// 2) 每一行是「前导图标 + 标题 + 标题下一行次要说明 + 尾部控件」四件套。原生 Form 的
//    Toggle/Picker 只有一个标签,说明得另外找地方放(尾注或"?"气泡)。
// 3) 有从属选项时,从属项在**同一张卡内**、用发丝分隔线隔开、控件右对齐,视觉上明确表达
//    "它属于上面那一项"。原生 Form 里从属项跟主项是同级并排的,看不出归属。
//
// 所以这套组件不是给 Form 套皮,而是直接用 ScrollView + VStack 手搭。原生 Form 的三个
// 好处(自动对齐控件标签、自动分组卡、自动尾注位置)在这里由 SettingsRow/SettingsCard
// 各自显式接管。
//
// ⚠️ 分隔线为什么要调用方自己插(CardDivider),不由 SettingsCard 自动加:SwiftUI 的
// ViewBuilder 不给遍历子视图的公开手段,想"在每两个子视图之间自动插一条线"只能用
// _VariadicView 那套下划线开头的私有 API。这个项目已经在 Package.swift 里吃过一次
// "依赖不稳定的东西就编译不过"的亏,不为省几行调用代码去碰私有 API。

// MARK: - 液态玻璃(macOS 26+)

// macOS 26 起系统提供"液态玻璃"材质(Liquid Glass):一层会折射背后内容、带镜面高光和
// 边缘光的半透明材质,并且同一个 GlassEffectContainer 里的多个玻璃元素靠近时会互相融合。
//
// 本项目部署目标是 macOS 14,所以三个入口全部用 #available 门控,旧系统原样退回改版前的
// 外观(一层 primary 低透明度叠加 + 普通按钮),不做任何降级模拟——半透明材质靠自己用
// 模糊+渐变糊出来通常比干净的纯色更糟。
//
// 2026-08-06 实测核实过这台机器(macOS 27.0 / SDK 26.4.1 / Swift 6.3.1)上这几个 API 在
// `-target arm64-apple-macosx14.0` 下确实能通过类型检查:.glassEffect(_:in:)、
// .glassEffect(.regular.tint(_).interactive())、GlassEffectContainer、
// .buttonStyle(.glass)、.buttonStyle(.glassProminent)。

extension View {
    /// 卡片背景。玻璃材质自带形状裁剪,不需要再额外 .background/.clipShape。
    ///
    /// ⚠️ 玻璃之外**必须**再补一条发丝描边。2026-08-06 拿两页的实机截图逐像素采样量过:
    /// 「播放器」页卡片填充 #FAFAFA~#FEFEFE、页面底色 #FFFEFF,**差值只有 1~5/255**,肉眼
    /// 基本看不出卡片边界;而「外观」页量出来底色 #F3F3F3、卡片 #FEFEFE(卡片比底色还亮,
    /// 方向相反)。同一份 SettingsCard 在两页长得不一样,是因为液态玻璃的可见度**完全取决于
    /// 它背后有什么**——纯白底上它几乎折射不到任何东西。描边不依赖背后内容,是"卡片边界一定
    /// 看得见、且每一页都一致"的唯一保证。
    @ViewBuilder
    func settingsCardBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        } else {
            background(shape.fill(Color.primary.opacity(0.05)))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        }
    }

    /// 页面里那个唯一的强调按钮(「请作者喝杯咖啡」)。macOS 26 起用 .glassProminent,
    /// 更早的系统退回原来的 .borderedProminent —— 两者都吃 .tint。
    @ViewBuilder
    func settingsProminentGlassButton(tint: Color) -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent).tint(tint)
        } else {
            buttonStyle(.borderedProminent).tint(tint)
        }
    }

    /// 行尾控件里的按钮统一套玻璃按钮样式。
    ///
    /// ⚠️ 它是挂在**祖先**上的:调用点自己显式写了 .buttonStyle(.link) 的按钮
    /// (「将当前配色存为新主题…」「恢复默认外观」这类文字链接)不会被它盖掉——SwiftUI 里
    /// 离 Button 更近的那个 buttonStyle 胜出,这正是我们想要的:它们本来就该是链接样式。
    @ViewBuilder
    func settingsGlassButtons() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            self
        }
    }

    /// 歌词窗口工具栏里那个音量控件的玻璃胶囊。跟卡片同一套写法(玻璃 + 一条发丝描边),
    /// 描边的理由见 settingsCardBackground:液态玻璃的可见度完全取决于背后有什么,而歌词
    /// 窗口的背景是被高斯模糊过的专辑封面,亮暗随歌变化 —— 没有描边时边界时有时无。
    @ViewBuilder
    func volumeCapsuleGlass() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        } else {
            background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        }
    }
}

/// 把一页里所有玻璃卡片包进同一个 GlassEffectContainer——同一个容器内的玻璃元素才会在
/// 靠近时互相融合、并共享一次材质采样(各自独立套 .glassEffect 只是 N 层互不相干的玻璃)。
struct SettingsGlassContainer<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

// MARK: - 卡片出现/消失的动画

extension Animation {
    /// 开关切换导致某张卡整体出现/消失时用的曲线。
    ///
    /// 必须在**改状态那一处**用 withAnimation 显式包起来,不要图省事在卡片列容器上挂
    /// .animation(_:value:)——那样动的是容器自身的几何,同一个事务里任何不相干的布局变化都
    /// 会被一起动起来(这个项目在"歌词窗口"的进度条上刚踩过:封面动画挂在容器外层链上,把
    /// 首次打开时进度条的位置也一起动了,看着像进度条从顶上飘下来)。
    static var settingsCardReveal: Animation { .smooth(duration: 0.3) }
}

extension AnyTransition {
    /// 卡片出现/消失:淡入淡出 + 从顶边轻微缩放,读起来像"从这一行下面长出来"。
    static var settingsCard: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
    }
}

// MARK: - 页面容器

// 一整页设置。负责:页面背景、居中的标题/说明、卡片列的宽度与间距、滚动。
//
// 卡片列宽度钉在 maxCardColumnWidth 并居中——窗口可以拖得很宽,但一行设置拉到 1000pt
// 宽会让"标题在最左、控件在最右"两端相距太远,眼睛要来回扫。参考图里 Dropover 也是
// 让卡片列保持一个固定的舒适宽度、两侧留白。
struct SettingsPage<Content: View>: View {
    let title: String
    var subtitle: String?
    // 只有"关于"页用得到:标题上方再压一张大图(App 图标)。做成可选参数而不是让"关于"页
    // 自己另搭一套页面容器,是为了让它跟其余几页共用同一份背景色/边距/滚动行为。
    var heroImage: NSImage?
    var heroSize: CGFloat = 88
    @ViewBuilder let content: () -> Content

    // 参考图里卡片列约占窗口宽度的三分之二;这个窗口 idealWidth 是 860、侧边栏约 190,
    // 内容区约 670,取 600 留下两侧各 35pt 的呼吸空间。
    static var maxCardColumnWidth: CGFloat { 600 }

    var body: some View {
        ScrollView {
            // spacing 传 0 而不是 14:GlassEffectContainer 的 spacing 是"多近才互相融合"的
            // 阈值,传 14 恰好等于卡片间距,相邻两张卡会**融成一整块玻璃**——间隙也被填成玻璃,
            // 这正是实测到「外观」页卡片间隙是 #F3F3F3(玻璃)而「播放器」页间隙是 #FFFEFF
            // (纯底色)的原因,两页因此长得不一样。每张卡都该是独立的一块面板,不要融合。
            SettingsGlassContainer(spacing: 0) {
                VStack(spacing: 14) {
                    header
                    content()
                }
            }
            .frame(maxWidth: Self.maxCardColumnWidth)
            // 顶部留白比底部大——标题上方需要明显的空,不然大标题会顶着工具栏
            .padding(.top, 26)
            .padding(.bottom, 28)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
        }
        // 页面底色用 .windowBackgroundColor,不用纯白的 .textBackgroundColor ——
        // 液态玻璃是"折射背后内容"的材质,铺在纯白上它几乎什么都折射不到(实测卡片与底色
        // 只差 1~5/255,见 settingsCardBackground 的注释)。换成窗口底色(浅色约 #ECECEC、
        // 深色约 #323232)之后,玻璃卡片相对底色是"抬起来、更亮"的一层,层次才立得住。
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 6) {
            if let heroImage {
                Image(nsImage: heroImage)
                    .resizable()
                    .frame(width: heroSize, height: heroSize)
                    .padding(.bottom, 2)
            }
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    // 比卡片列窄一截,让说明自然折成两三行居中排布(参考图就是这个观感),
                    // 而不是拉成贴着卡片边缘的一整行。
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 6)
    }
}

// 跟 SettingsPage 完全同一套背景/边距/卡片列宽度/滚动,但页头由调用方自己给。
//
// "账号"那几页需要它:它们的页头是一个彩色图标徽标,而 Last.fm 那一个徽标是位图
// (见 accountIconBadge —— 它不是 SF Symbol,没法用 SettingsPage 的 title/subtitle/
// heroImage 三件套表达)。与其把 SettingsPage 的参数扩成一堆互斥的可选项,不如另开一个
// 只换页头、其余全部共用的容器。
struct SettingsPageCustomHeader<Header: View, Content: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            // spacing 传 0,理由同 SettingsPage 那一处。
            SettingsGlassContainer(spacing: 0) {
                VStack(spacing: 14) {
                    header()
                        .padding(.bottom, 6)
                    content()
                }
            }
            .frame(maxWidth: SettingsPage<EmptyView>.maxCardColumnWidth)
            .padding(.top, 26)
            .padding(.bottom, 28)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
        }
        // 同 SettingsPage,理由见那一处注释。
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - 卡片

// 一张卡片。内部子行之间由调用方插 CardDivider() 隔开(理由见文件顶部注释)。
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        // macOS 26+ 是液态玻璃,更早的系统退回原来那层 primary 低透明度叠加(深浅外观下
        // 自动跟着前景色反转,不需要各写一套),见 settingsCardBackground。
        .settingsCardBackground(cornerRadius: 10)
    }
}

// 卡片内部的发丝分隔线。左侧缩进到跟标题文字对齐(不是贯穿整张卡)——参考图里分隔线
// 从标题的起始位置开始,不切到前导图标那一列。
struct CardDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, SettingsRowMetrics.textLeadingInset)
    }
}

// 行内各段的固定尺寸。抽出来是因为 CardDivider 的左缩进必须跟 SettingsRow 里图标列的
// 宽度严格一致,两处各写一个数字迟早会对不上。
enum SettingsRowMetrics {
    static let iconWidth: CGFloat = 20
    static let iconTextSpacing: CGFloat = 12
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 11
    // 图标列 + 图标与文字的间距 + 卡片左内边距 = 文字实际的左起点
    static var textLeadingInset: CGFloat { horizontalPadding + iconWidth + iconTextSpacing }
}

// MARK: - 主行

// 「前导图标 + 标题(+副标题) + 尾部控件」。
//
// 尾部控件跟标题**顶部对齐**而不是整行垂直居中:有副标题时,控件若居中会掉到两行文字
// 中间,跟标题错位(参考图里开关是跟标题那一行齐平的)。没有副标题时两种对齐等价。
struct SettingsRow<Trailing: View>: View {
    var icon: String?
    // 图标默认是次要灰(它只是行首的视觉锚点,不该抢标题的注意力)。只有真正在用图标本身
    // 表达状态的地方才传色:"权限已授权/已拒绝"、"后台服务运行中/未运行"这类绿勾红叉,
    // 以及歌词来源前面那个代表来源的彩色圆点。
    var iconTint: Color?
    let title: String
    var subtitle: String?
    // 说明文字里需要放"?"气泡这类交互元素时用它替代纯文本 subtitle。两者只用其一。
    var help: String?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: SettingsRowMetrics.iconTextSpacing) {
            // 即使这一行没有图标也占住同宽的位置——同一张卡里有的行有图标、有的没有时,
            // 标题必须仍然对齐在同一条竖线上。
            Group {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundStyle(iconTint ?? Color.secondary)
                        // ⚠️ 锁定成拉丁语区:SF Symbols 里 textformat / textformat.alt /
                        // textformat.size 这类"字母造型"的符号带 CJK 本地化变体,中文界面下
                        // 会被渲染成汉字「格式」——2026-08-06 实机截图里"显示罗马音"那一行
                        // 的图标位就是一个「格式」二字,夹在一列线条图标中间像是漏了个标签。
                        // 图标列要的是图形而不是本地化文字,这里显式钉住拉丁变体(其余不带
                        // 变体的符号不受任何影响)。
                        .environment(\.locale, Locale(identifier: "en"))
                }
            }
            .frame(width: SettingsRowMetrics.iconWidth, alignment: .center)
            // 图标跟标题那一行齐平(而不是跟整块文字顶端齐平)。
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 13))
                    if let help { HelpButton(text: help) }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            trailing()
                // 控件本身自带的标签一律不显示——标题已经在左边了,再显示一遍就是同一句
                // 话并排两次(原生 Form 里 Toggle/Picker 的标签就是这么来的)。
                .labelsHidden()
                // ⚠️ 必须显式指定 .switch:macOS 上 Toggle 的默认样式是**复选框**,只有放在
                // Form/List 里才会自动变成右侧那个开关。这套卡片是自己用 ScrollView+VStack
                // 搭的、不在 Form 里,不写这一句所有开关都会画成 ☑ 复选框(2026-08-06 第一版
                // 实机截图就是这个样子),跟参考设计差得很远。
                .toggleStyle(.switch)
                .settingsGlassButtons()
        }
        .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
        .padding(.vertical, SettingsRowMetrics.verticalPadding)
    }
}

// 没有尾部控件的纯说明/纯标题行。
extension SettingsRow where Trailing == EmptyView {
    init(icon: String? = nil, iconTint: Color? = nil, title: String, subtitle: String? = nil, help: String? = nil) {
        self.init(icon: icon, iconTint: iconTint, title: title, subtitle: subtitle, help: help) { EmptyView() }
    }
}

// MARK: - 破坏性操作按钮

/// 会造成不可撤销后果的按钮(清除配置、清空缓存这类)。
///
/// ⚠️ 单靠 `role: .destructive` 在 macOS 上**不会变红**:那个 role 只在菜单项和弹窗按钮里
/// 才被渲染成红色,普通按钮里它只是语义标记、外观跟普通按钮一模一样。所以这里显式把标签
/// 染红 + tint 也设成红,让"这一下按下去要出事"在外观上就看得出来,不依赖用户去读副标题。
struct DestructiveButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, role: .destructive, action: action)
            .foregroundStyle(.red)
            .tint(.red)
    }
}

// MARK: - 卡片里的说明块

/// 挂在某一行下面的一小段说明(+可选的操作按钮)。用在"正在等待系统授权弹窗""启用失败,
/// 导出诊断信息看原因"这类**临时出现**的引导上——它们不是常驻的设置项副标题,而是某个
/// 操作之后才冒出来的一段提示,所以单独一个组件、缩进到跟标题文字同一条竖线。
struct SettingsNote<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        SettingsRawRow(insetToText: true) {
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 从属行

// 从属于上一行的选项,右对齐。可选地在控件左边带一个短标签("宽度""风格"这种)。
//
// 左侧不放图标、不占图标列:参考图里从属行整块贴着卡片右侧,靠"右对齐 + 上方一条分隔线"
// 表达归属,不再重复一遍图标。
struct SettingsSubRow<Trailing: View>: View {
    var title: String?
    // 滑杆这类需要横向铺开的控件给一个宽度,纯下拉菜单不需要。
    var trailingWidth: CGFloat?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 13))
            }
            trailing()
                .labelsHidden()
                .toggleStyle(.switch)
                .settingsGlassButtons()
                .frame(maxWidth: trailingWidth)
        }
        .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
        .padding(.vertical, SettingsRowMetrics.verticalPadding)
    }
}

// MARK: - 卡片内的整行按钮 / 自定义内容

// 需要整行自己排版(一排按钮、来源排序列表、权限状态块这类)的场合,用它拿到跟
// SettingsRow 一致的内边距,不必每处重复写 padding 数值。
struct SettingsRawRow<Content: View>: View {
    var insetToText = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.leading, insetToText ? SettingsRowMetrics.textLeadingInset : SettingsRowMetrics.horizontalPadding)
            .padding(.trailing, SettingsRowMetrics.horizontalPadding)
            .padding(.vertical, SettingsRowMetrics.verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
