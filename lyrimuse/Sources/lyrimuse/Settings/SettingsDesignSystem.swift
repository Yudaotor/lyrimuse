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
    /// (「将当前配色存为新主题…」「恢复默认文字与配色」这类文字链接)不会被它盖掉——SwiftUI 里
    /// 离 Button 更近的那个 buttonStyle 胜出,这正是我们想要的:它们本来就该是链接样式。
    @ViewBuilder
    func settingsGlassButtons() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            self
        }
    }

    /// 歌词窗口里那些浮在内容之上的玻璃胶囊(音量、窗口操作)。跟卡片同一套写法(玻璃 + 一条发丝描边),
    /// 描边的理由见 settingsCardBackground:液态玻璃的可见度完全取决于背后有什么,而歌词
    /// 窗口的背景是被高斯模糊过的专辑封面,亮暗随歌变化 —— 没有描边时边界时有时无。
    @ViewBuilder
    func clearGlassCapsule(rim: Color) -> some View {
        if #available(macOS 26.0, *) {
            // ⚠️ 用 .clear 不是 .regular。
            //
            // Liquid Glass 有两档材质:.regular 是磨砂,给普通 UI 用,在深色背景上就是一块
            // 不透明的浅灰;.clear 才是给**浮在图像/媒体之上**的元素用的,更通透、能让背后
            // 的内容透过来 —— Apple Music 那个音量胶囊正是这种场景。2026-08-09 用户连着
            // 两次指出"这个没透明",第一次的原因是玻璃套玻璃(见调用点注释),第二次就是
            // 这里:位置改对了,材质档还是磨砂的那一档。
            //
            // 官方guidance 说 .clear 通常需要配一层压暗来保证对比度 —— 这里的图标和滑块
            // 本来就是白色系,压暗那一层由 rim 描边和滑块自身的阴影兜住,不额外加。
            glassEffect(.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(rim, lineWidth: 0.5))
        } else {
            background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().strokeBorder(rim, lineWidth: 0.5))
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
// 把内容宽度钉死成"滚动视图外部的宽度",不让滚动条参与决定它。
//
// 2026-08-15 用户报的抖动就是这个:展开一个 DisclosureGroup 让内容超过一屏,滚动条出现,
// **占掉约 15pt 布局宽度**,于是这一列卡片可用的宽度变窄、居中点左移 —— 整页看着往左挤
// 了一下。收起来时反向再抖一次。
//
// ⚠️ 别被 `defaults read -g AppleShowScrollBars` 读不到值骗了(我第一次就是这么误判的):
// 没设置 = "自动",而"自动"的含义是**按输入设备定** —— 接着鼠标就是常驻滚动条、占宽度,
// 只有纯触控板才是不占宽度的 overlay。所以这事不能靠"默认应该是 overlay"来推断。
//
// 修法:量一次宽度,内容按这个宽度铺。滚动条出现与否都不再改变它。滚动条会盖住右边缘
// 那一小条,但卡片列本身居中、最大 600pt、两侧还有 20pt padding,盖不到内容。
//
// ⚠️ 2026-08-15 当天的二次修正,这个"量"必须**不改变视图层级**。第一版是把整个
// ScrollView 包进 GeometryReader(GeometryReader 在外、ScrollView 在内),抖动确实治好了,
// 但换来一个更糟的回归:GeometryReader 会截断 safe area 的传播,而「外观」页顶上那条预览
// 正是拿 .safeAreaInset 挂的 —— 两者一叠加,往下滚之后内容的实际位置和点击命中区域就
// 错开了,表现是"分段选择器看得见却点不动,必须滚回顶部才点得着"。
//
// 所以改成 GeometryReader 只待在 .background 里**量**,ScrollView 仍然是这一层的根,
// safe area 照常传播。量到的是 ScrollView 自己的布局宽度 —— 这个值本来就不随滚动条出现
// 而变(变的是内容可用宽度),所以钉死内容宽度、防抖的效果一点没丢。
private struct SettingsPageWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct FixedWidthScrollView<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var measuredWidth: CGFloat = 0

    var body: some View {
        ScrollView {
            content()
                // 首帧还没量到,传 nil 让内容自己撑开,别闪一帧 0 宽。
                .frame(width: measuredWidth > 0 ? measuredWidth : nil)
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: SettingsPageWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(SettingsPageWidthKey.self) { measuredWidth = $0 }
    }
}

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
        FixedWidthScrollView {
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
// 顶部钉一条(分段选择器 / 实时预览),下面才是滚动区。
//
// ⚠️ 这里刻意**不用** .safeAreaInset。那个修饰符是"悬浮"语义:被它修饰的 ScrollView 仍然
// 占着整块区域,内容会滑到那条悬浮层**底下**去。表现出来就是往下滚一段之后,分段选择器和
// 第一张卡明明还看得见,却既点不动、鼠标放上去连滚都滚不动 —— 用户连报了两次,第二次特意
// 补了"鼠标放在这个区域里面也不能滚动",正是这个语义的指纹(坐标错位只会影响点击,滚轮
// 照样该到 ScrollView)。
//
// VStack 把固定头部和滚动区真正分成上下两块:滚动区只存在于头部下方,不存在"看得见却够不着"
// 的夹层,选择器也因此永远点得到,不必先滚回顶部。
struct SettingsPageWithStickyHeader<Header: View, Page: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let page: () -> Page

    var body: some View {
        VStack(spacing: 0) {
            header()
                .frame(maxWidth: .infinity)
                // 头部自带不透明底色。
                .background(Color(nsColor: .windowBackgroundColor))
            // 写成 VStack 的子项而不是 header 的 .overlay(alignment: .bottom) —— 两者
            // 渲染结果实测一致(离线渲染对比过,overlay 里的 Divider 同样是横线,并不会像
            // 一度怀疑的那样变成竖线),但子项这个写法把"它占一行高度"说清楚了,不用去想
            // overlay 会不会盖住底下那一行。
            // 各个预览条原来各画各的 Divider,统一收到这里 —— 没有预览的那几段(「其它」/
            // 歌词页)才不会缺一条线。
            Divider()
            page()
        }
    }
}

struct SettingsPageCustomHeader<Header: View, Content: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        FixedWidthScrollView {
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

// MARK: - 卡片标题行

// 卡片顶上那一行标题(「配色」「文字」「菜单栏歌词」这类)。
//
// ⚠️ 它跟卡片里的设置行**必须**长得不一样。2026-08-15 之前这里用的就是一个不带尾部控件的
// SettingsRow —— 同样的 13pt 字号、同样的图标列、同样的行高,于是「配色」和它下面的
// 「跟随封面取色」「配色主题」在视觉上完全平级,读者只能靠一条分隔线去猜谁是谁的标题。
// 用户报的原话是"块标题和下面的内容太相似了,没什么区分度"。
//
// 改法是把它往"分组标签"的方向拉开(macOS 系统设置里的分组标题也是这个路子):字号压到 12、
// 字重加到 semibold、颜色降为次要色、字距拉开一点,行本身也更紧凑。
//
// **刻意不给图标**:图标列是设置行的视觉锚点,标题一旦也占那一列,两者就又对齐成平级了。
// 让标题从卡片左边缘直接起排、不参与那一列,层级一眼就分得开 —— 四个候选样式离线渲染
// 对比过(带小图标的那版图标跟下面的图标列对不齐,反而显得半吊子)。
struct SettingsCardHeader: View {
    let title: String
    // 少数几张卡的标题下面还有一句适用范围说明(比如「自动隐藏」要讲清它对哪几个形态生效)。
    var subtitle: String?
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                if let help { HelpButton(text: help) }
                Spacer(minLength: 0)
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    // 比标题再淡一档 —— 标题本身已经是次要色,两行同色会糊成一团。
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, 7)
    }
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
    // 子行也能带一句说明。像"标注哪些语言"那样光有几个选项名、不说各自会标成什么的行,
    // 就是需要这个。
    var subtitle: String?
    // 滑杆这类需要横向铺开的控件给一个宽度,纯下拉菜单不需要。
    var trailingWidth: CGFloat?
    /// 标题右边那个「?」气泡(点了/悬停展开一段说明)。跟 SettingsCardHeader 用同一个
    /// HelpButton —— 需要写一段话而不是一句副标题时用它:副标题是常显的,长文案会把整张卡
    /// 撑成一堵墙(2026-08-19「宽度模式」那一行就是这么从副标题改过来的)。
    var help: String?
    @ViewBuilder let trailing: () -> Trailing

    // 2026-08-15 重排。原来这一行是"Spacer + 标题 + 控件"整体右对齐、左边什么都没有,
    // 跟主行长得几乎一样,读起来像是并列的另一项 —— 用户报的就是"看不出附属关系"。
    // 现在靠两样东西表达从属:
    //   1. 一条淡竖线,画在标题左边;
    //   2. 标题缩进到**跟主行标题同一列**。主行那一列的左边是图标,子行没有图标,
    //      这个空位本身就是层级信号(macOS 系统设置里的子项也是这么排的)。
    // 顺带把标题从右对齐改回左对齐:主行是"标题在左、控件在右",子行跟着同一套结构,
    // 眼睛才好顺着同一条竖线往下扫。
    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 2)
                .padding(.vertical, 1)
            VStack(alignment: .leading, spacing: 2) {
                if let title, !title.isEmpty {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.system(size: 13))
                        if let help { HelpButton(text: help) }
                    }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            trailing()
                // ⚠️ 跟主行一样统一藏掉控件自带的标签(标题已经在左边了)。所以放在这里的
                // 控件**不能**指望 Toggle/Picker 自己的 label 显示文字 —— 需要文字就自己
                // 摆一个 Text,见 SettingsView 里 romanizationToggle 那段注释。
                .labelsHidden()
                .toggleStyle(.switch)
                .settingsGlassButtons()
                .frame(maxWidth: trailingWidth)
        }
        // 竖线本身 2pt、后面还有 10pt 间距,左内边距取"主行文字左起点 - 12",标题正好
        // 落回主行标题那一列。
        .padding(.leading, SettingsRowMetrics.textLeadingInset - 12)
        .padding(.trailing, SettingsRowMetrics.horizontalPadding)
        .padding(.vertical, SettingsRowMetrics.verticalPadding)
    }
}

// MARK: - 卡片内的整行按钮 / 自定义内容

// 需要整行自己排版(一排按钮、来源排序列表、权限状态块这类)的场合,用它拿到跟
// SettingsRow 一致的内边距,不必每处重复写 padding 数值。
struct SettingsRawRow<Content: View>: View {
    var insetToText = false
    // insetToText 的行会空出一整条图标列(那是它跟其它行文字对齐的代价)。给了图标就把那块
    // 填上,不给就还是空着 —— 空着本身不是 bug,但一张卡里别的行都有图标、唯独这一行留个
    // 空洞,看起来就像漏画了(2026-08-15 用户指的就是「账户 Token」那一行)。
    var icon: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: SettingsRowMetrics.iconTextSpacing) {
            if insetToText {
                Group {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            // 锁拉丁语区,理由同 SettingsRow 里那处注释(SF Symbols 的部分
                            // 符号有 CJK 变体,中文界面下会被渲染成汉字)。
                            .environment(\.locale, Locale(identifier: "en"))
                    }
                }
                .frame(width: SettingsRowMetrics.iconWidth, alignment: .center)
                .padding(.top, 1)
            }
            content()
        }
        // 图标列自己占了宽度,所以这里一律用卡片内边距 —— 加起来仍然是
        // horizontalPadding + iconWidth + spacing = textLeadingInset,跟原来的对齐一致。
        .padding(.leading, SettingsRowMetrics.horizontalPadding)
        .padding(.trailing, SettingsRowMetrics.horizontalPadding)
        .padding(.vertical, SettingsRowMetrics.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
