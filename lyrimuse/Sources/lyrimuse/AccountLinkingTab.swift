import AppKit
import Combine
import SwiftUI

// 每张卡片的连接状态——只有三态会在"账号连接"这个分类里实际出现(这里只关心"有没有
// 配好",不关心"这个功能要不要用",所以 .disabled 这个"未启用"分支在这里永远不会被
// 构造;它是给"功能开关"tab 复用同一套视觉/文案时才会用到的第四态)。颜色驱动而不是
// 纯文字驱动,一眼扫过图标颜色就能分辨状态。
enum DestinationStatus {
    case disabled                  // 灰:开关关闭,不管凭据填没填都不报错(仅"功能开关"tab 用)
    // 这是个**可选**功能,而且用户一个字段都没填过 —— 侧边栏不给徽标。
    //
    // 2026-08-15:这几项(ListenBrainz / 网页推送 / 推送提醒 / Last.fm)原来都走
    // .missingCreds,于是侧边栏一排橙色警告三角。但"你没配这个可选功能"根本不是问题,
    // 拿警告图标去说它,等于让用户在一列感叹号里自己分辨哪个才是真出事了 —— 而真出事
    // (.error)恰恰长得差不多。没什么要说的时候就什么都不说。
    //
    // ⚠️ 跟 .missingCreds 的分界是"碰没碰过":填了一半(网页推送有地址没令牌、
    // ListenBrainz 有 token 没用户名)仍然是 .missingCreds —— 那种"我明明配过却不工作"
    // 才是真需要被指出来的。
    case notConfigured(String)     // 无徽标:可选功能,从没配过
    case missingCreds(String)      // 橙:凭据不全(hint 点名具体缺哪个字段)
    case active(String? = nil)     // 绿:凭据齐全,可选带一句更具体的文案(如"已连接:xxx")
    case error(String)             // 红:硬性错误(ListenBrainz 缺 token / Last.fm 连接失败)

    var label: some View {
        // .id(L10n.current) 必须加在这里(调用方外部),不能加在 DestinationStatusLabel 自己
        // body 内部:SwiftUI 判断是否重新执行某个子 View 的 body,依据是这个子 View 自己的
        // 存储属性(这里是 status)有没有变,跟父视图是否重新渲染无关。切换语言时 status 的
        // 值没变,若 .id() 放在子 View body 内部就永远等不到被重新求值的机会。放在这里让
        // 调用方在决定"要不要跳过"之前先比较 id,id 一变就判定是全新 View、无条件整体
        // 重新构造。
        DestinationStatusLabel(status: self)
            .id(L10n.current)
    }

    // 只要图标、不带文字的紧凑版——2026-07-29 起侧边栏行(AccountSidebarRow)改用这个:
    // 一行"Last.fm + 一堆状态描述文字"在只有 220pt 宽的侧边栏里本来就挤不下、也没必要,
    // 颜色/图标本身已经足够传达"配好了没有",文字留给有更多空间、也更需要具体信息的
    // 详情页头部(仍然用上面的 label)。不需要绑 .id(L10n.current)——图标本身不随语言
    // 变化,没有"切语言后没刷新"这个问题。
    var indicator: some View {
        DestinationStatusIndicator(status: self)
    }
}

// 侧边栏这一行被选中时系统会铺一层高亮蓝底——固定的 .orange/.green/.red 不会跟着换色,
// 深绿/深红字压在亮蓝底上对比度很差、看不清。用 backgroundProminence 这个环境值(选中+
// 聚焦时是 .increased)判断当前是否铺着高亮底,是就退回 .primary(会跟随高亮底自动换成
// 清晰的颜色),不铺高亮底时才用状态本身的颜色,保持"一眼扫图标颜色分辨状态"这个设计
// 意图不变。
private struct DestinationStatusLabel: View {
    let status: DestinationStatus
    @Environment(\.backgroundProminence) private var backgroundProminence

    private var dimmed: Bool { backgroundProminence == .increased }

    var body: some View {
        // .id(L10n.current) 放在这个 body 内部不生效——SwiftUI 判断是否重新执行这个 View
        // 的 body 依据的是 DestinationStatusLabel 自己的存储属性(status)有没有变,跟
        // 父视图/List 是否重新渲染无关。真正生效的修复在 DestinationStatus.label 那个
        // 计算属性里(调用方外部),见那边的注释。
        Group {
            switch status {
            case .disabled:
                Label(L10n.t("未启用"), systemImage: "circle").foregroundStyle(.secondary)
            case .notConfigured(let hint):
                // 详情页仍然如实说明状态(用户既然点进来了就是想知道),只是外观中性 ——
                // 空心圆 + 次要色,跟"未启用"一个量级,不是警告。
                Label(hint, systemImage: "circle").foregroundStyle(.secondary)
            case .missingCreds(let hint):
                Label(hint, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(dimmed ? Color.primary : Color.orange)
            case .active(let detail):
                Label(detail ?? L10n.t("正在生效"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(dimmed ? Color.primary : Color.green)
            case .error(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(dimmed ? Color.primary : Color.red)
            }
        }
    }
}

// DestinationStatusLabel 的图标——文字部分,同一套颜色/图标映射,只是不带 Label 的
// 文字槽位。.disabled 分支的图标沿用"circle"(空心圆),视觉上跟"未启用"这个语义
// 一致,不会被误认成"出错了"。
private struct DestinationStatusIndicator: View {
    let status: DestinationStatus
    @Environment(\.backgroundProminence) private var backgroundProminence

    private var dimmed: Bool { backgroundProminence == .increased }

    var body: some View {
        switch status {
        case .disabled:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .notConfigured:
            // 侧边栏这一档**什么都不画**。没配一个可选功能不是状态,不需要占一个位置。
            EmptyView()
        case .missingCreds:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(dimmed ? Color.primary : Color.orange)
        case .active:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(dimmed ? Color.primary : Color.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(dimmed ? Color.primary : Color.red)
        }
    }
}

// 敏感凭据字段(Token/API Key/Secret)的统一展示方式——已经填过的凭据不再永久摆一个
// 遮罩输入框(一排圆点堆在一起不好看,而且反正内容不可见,摆着也没有信息量);改成一行
// 紧凑的"已设置 + 更改"状态,只有从没填过、或者用户主动点"更改"时,才展开成可编辑的
// SecureField。isEditing 的初始值取决于构造时刻 value 是否为空——已配置的字段一开始
// 收起,从没配置过的字段一开始就是展开可填状态,行为上跟原来"直接摆一个 SecureField"
// 没有区别,只是多了"配置好之后收起来"这一步。
private struct SecretFieldRow: View {
    let label: String
    @Binding var value: String
    var prompt: String? = nil

    @State private var isEditing: Bool

    init(_ label: String, value: Binding<String>, prompt: String? = nil) {
        self.label = label
        self._value = value
        self.prompt = prompt
        self._isEditing = State(initialValue: value.wrappedValue.isEmpty)
    }

    var body: some View {
        if isEditing {
            HStack {
                SecureField(label, text: $value, prompt: prompt.map(Text.init))
                if !value.isEmpty {
                    Button(L10n.t("完成")) { isEditing = false }
                        .buttonStyle(.link)
                }
            }
        } else {
            HStack {
                Text(label)
                Spacer()
                Label(L10n.t("已设置"), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
                Button(L10n.t("更改")) { isEditing = true }
                    .buttonStyle(.link)
            }
        }
    }
}

// 4 个可连接的账号/目的地——只是 UI 层的路由标识,不涉及底层数据结构。
enum AccountDestination: Hashable, CaseIterable, Identifiable {
    case listenBrainz, lastfm, stateRelay, bark
    var id: Self { self }

    var title: String {
        switch self {
        case .listenBrainz: return "ListenBrainz"
        case .lastfm: return "Last.fm"
        case .stateRelay: return L10n.t("网页推送")
        case .bark: return L10n.t("推送提醒")
        }
    }

}

// 账号图标徽标——ListenBrainz/网页推送/推送提醒仍用 iconBadge(SF Symbol 白色剪影+纯色
// 圆角方块背景);Last.fm 换成真实品牌图标(见 lastfmBadgeImage 注释),不再用泛化的
// 循环箭头符号凑数。放在这里而不是 SettingsView.swift 的 iconBadge 旁边——只有
// AccountDestination 这一种目的地需要"某个 case 换成自定义图片"这个分支,不该让通用的
// iconBadge 也认识 AccountDestination。
@ViewBuilder
func accountIconBadge(_ destination: AccountDestination, size: CGFloat = 22, cornerRadius: CGFloat = 6) -> some View {
    switch destination {
    case .listenBrainz:
        iconBadge("waveform.circle.fill", tint: .orange, size: size, cornerRadius: cornerRadius)
    case .lastfm:
        Image(nsImage: lastfmBadgeImage)
            .resizable()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    case .stateRelay:
        iconBadge("dot.radiowaves.left.and.right", tint: .blue, size: size, cornerRadius: cornerRadius)
    case .bark:
        iconBadge("bell.badge.fill", tint: .red, size: size, cornerRadius: cornerRadius)
    }
}

// 真实的 Last.fm 品牌图标(红底+白色"scrobble"符号),取代之前拿 SF Symbol 循环箭头
// 凑数的做法——素材取自 Simple Icons(CC0 授权、专门收录给第三方集成场景用的品牌图标
// 合集),矢量描摹自 Last.fm 官方标志,不是从官网截图里抠像素。跟 MenuBarMenu.swift 里
// menuBarIconImage 同一套加载方式:用 Bundle.main 而不是 Bundle.module(原因见
// L10n.swift 顶部注释),PNG 由 build.sh 拷进 Contents/Resources/。不设 isTemplate——
// 这不是状态栏图标,不需要跟随系统明暗色重新上色,品牌色本身就该固定显示红+白。
private let lastfmBadgeImage: NSImage = {
    guard let path = Bundle.main.path(forResource: "LastfmIcon", ofType: "png"),
          let image = NSImage(contentsOfFile: path) else {
        // 找不到就退回泛化符号兜底(比如 swift build 直接跑、没走 build.sh 打包的场景),
        // 不让图标位置裸奔成空白。
        return NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil) ?? NSImage()
    }
    return image
}()

// 抽成自由函数而不是 AccountLinkingTab 的实例方法——侧边栏行(AccountSidebarRow)和
// 详情页头部(AccountLinkingTab.detailHeader)两处都要算同一个目的地的状态,不想维护
// 两份逻辑。两边各自持有同一对共享单例(ConfigStore.shared/LastfmConnectController.shared)
// 的 @ObservedObject 引用,传进来算,不做隐式全局访问。
@MainActor
func destinationStatus(for destination: AccountDestination, config: ConfigStore, lastfmConnect: LastfmConnectController) -> DestinationStatus {
    switch destination {
    case .listenBrainz:
        // ListenBrainz 是可选账号(只想用悬浮歌词可以完全不配),未配置不算硬性错误,
        // 跟其它卡片一致用橙色"缺凭据"提示。
        if config.isListenBrainzReadable {
            return .active(String(format: L10n.t("已连接为 @%@"), config.listenbrainzUser))
        }
        // 只填了 token、没填用户名:提交收听其实已经在跑了,但听歌报告读不回数据。这跟
        // "压根没配"是两种不同的状态,混成一句"未配置"会让填了 token 的人以为自己没填。
        if config.isListenBrainzConfigured {
            return .missingCreds(L10n.t("还缺用户名，听歌报告用不了"))
        }
        return .notConfigured(L10n.t("未配置（可选）"))
    case .stateRelay:
        // 一个字段都没填 = 没碰过;填了地址没填令牌 = 真的缺东西,那个仍然报橙色。
        if config.isStateRelayUntouched { return .notConfigured(L10n.t("未配置（可选）")) }
        if let hint = config.stateRelayMissingHint() { return .missingCreds(hint) }
        return .active()
    case .lastfm:
        if case .failed(let msg) = lastfmConnect.state { return .error(msg) }
        // 2026-08-11 起徽标只报"连没连"。旧版把读/写两条链路的组合状态摊给用户
        // ("读取+写入已配置"那一套)——那是在解释用户不需要理解的架构,见 lastfmFields
        // 顶部注释。
        if config.lastfmScrobbleSessionKey.isEmpty { return .notConfigured(L10n.t("未配置（可选）")) }
        // collector 报告凭据已死(用户在网站上撤销了授权等)——必须压过"已连接":
        // 本地攥着的 session key 是废的,绿标就是在撒谎。
        if LastfmMirrorStatus.current != nil { return .error(L10n.t("授权已失效")) }
        let name = config.lastfmScrobbleUsername.isEmpty ? config.lastfmUser : config.lastfmScrobbleUsername
        return .active(name.isEmpty ? nil : String(format: L10n.t("已连接：%@"), name))
    case .bark:
        // 只有一个字段,所以"没填"就等于"没碰过",没有中间态。
        if let hint = config.pushMissingHint() { return .notConfigured(hint) }
        return .active(config.notificationPlatform.displayName)
    }
}

// "账号连接"侧边栏的一行(图标+名称+状态徽标)——单独抽成一个 View,而不是内嵌在
// SettingsView 里当作普通 Label,因为它需要订阅 ConfigStore/LastfmConnectController
// 才能实时刷新状态徽标(比如保存后从"还没有配置"变成"已连接")。这一行跟"播放"
// "外观"等其它分类平级放在 SettingsView 外层同一个 List 的 Section("账号连接")里——
// 全窗口自始至终只有一层真正的侧边栏 List。
//
// 这一层不能再拆出第二层"看起来像侧边栏"的容器:嵌套 NavigationSplitView 会导致外层
// 侧边栏/工具栏在窗口级 chrome 上跟内层打架(外层侧边栏整个不渲染、内层列表行错位重叠);
// 手搭的 HStack+List(.listStyle(.sidebar)) 能绕开这个冲突,但拿不到 AppKit 只对"真正的
// 侧边栏列"做的窗口圆角遮罩,背景材质会在窗口角落露出一块方形黑影。全窗口只留一层真正的
// NavigationSplitView 侧边栏,"账号"这一级用 Section 分组变成这层真侧边栏里的普通行,
// 是唯一不会跟 AppKit 窗口级 chrome 打架的做法。
struct AccountSidebarRow: View {
    let destination: AccountDestination

    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var lastfmConnect = LastfmConnectController.shared
    // 只为了让这一行在手动切换语言时重新渲染——这个 View 本身已经嵌在 SettingsView
    // 的 List 里,父视图理论上会因为语言变化重新构造子行,这里独立再观察一份是保险,
    // 不依赖 ForEach 复用行为的具体细节。
    @ObservedObject private var languageSettings = AppSettings.shared

    // 2026-07-29:只保留一个状态图标,不带文字——"读取+写入已配置"这类描述性文案在
    // 侧边栏这个只有 170~220pt 宽的位置本来就容易被挤断行,颜色/图标本身已经足够表达
    // "配好了没有";需要具体缺了哪个字段这种细节,详情页头部(AccountLinkingTab.
    // detailHeader)仍然用带文字的 .label,那里空间够、也更需要具体信息。
    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(destination.title)
                destinationStatus(for: destination, config: config, lastfmConnect: lastfmConnect)
                    .indicator
            }
        } icon: {
            accountIconBadge(destination)
        }
        .padding(.vertical, 2)
    }
}

// 账号连接:回答"配好了没有"这个问题;每张账号卡片里也带对应的"要不要用这个功能"
// 开关(比如"推送状态到网页/徽章"),但那是各个账号自己的开关,不是一个笼统的"功能
// 开关"分类——不依赖任何账号的纯行为开关(比如封面/主色/平台跳转链接)已经从可关闭
// 设置项直接删掉、改成无条件执行,不再需要一个单独的地方安放它们。
//
// 只负责渲染"某一个目的地"的详情/编辑区+底部保存栏,不再自己管"当前选中哪个账号"——
// 侧边栏(AccountSidebarRow)现在跟 SettingsView 的分类列表拍平在同一个 List 里,"选中
// 哪个目的地"这件事完全交给外层,这个 View 只需要知道 destination 是谁。
//
// 完全不依赖 FeatureSettingsStore——只碰 ConfigStore,底部保存栏直接复用现成的
// ConfigStore.save()(持久化+异步重启+提交快照一步到位)。字段直接双向绑定 ConfigStore
// 的 @Published 属性(不是本地编辑缓冲区)——切换外层选中的账号不会丢失任何输入,因为
// 数据本来就活在共享的 ConfigStore 里,跟"当前显示哪个账号"完全无关。
struct AccountLinkingTab: View {
    let destination: AccountDestination
    // 只用于同一个模块内"这个统计功能还依赖另一个账号"的跨账号跳转(比如 Last.fm 卡片
    // 里的"每周听歌小结"依赖推送提醒、"历史 Top10"依赖网页推送)——由 SettingsView 传入
    // 同一个改 selection 的闭包,点击后把侧边栏选中切到对应账号。
    var onJumpToAccount: (AccountDestination) -> Void = { _ in }

    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var features = FeatureSettingsStore.shared
    @ObservedObject private var lastfmConnect = LastfmConnectController.shared
    @ObservedObject private var backfill = ScrobbleBackfillService.shared
    @State private var pendingListensExpanded = false
    /// 待补清单里鼠标停在哪一条上(uts)。删除按钮只在它上面显形 —— 见 pendingListensRow。
    @State private var hoveredPendingUTS: Int64?
    // 只为了让手动切换语言时这块详情页重新渲染,同 AccountSidebarRow 的理由。
    @ObservedObject private var languageSettings = AppSettings.shared

    @State private var isSaving = false
    @State private var lastSavedAt: Date?

    // 开关校验采用"打开时才校验,没满足就弹窗"(而不是预先灰置+旁边常驻小字提示)。
    // missingPrereqAlert 非 nil 就弹一次;body 上只挂一个 .alert,所有开关共用同一套。
    private struct MissingPrereqAlert: Identifiable {
        let id = UUID()
        let message: String
        let jumpTarget: AccountDestination?
    }
    @State private var missingPrereqAlert: MissingPrereqAlert?
    // "连接 Last.fm"向导 sheet 开没开——见 lastfmFields 顶部注释,未连接时打开
    // scrobble 开关就是打开它。
    @State private var showLastfmWizard = false
    // 「断开」的确认框 —— 重连要重新走一遍浏览器授权,一次误点的代价不小,值得拦一下
    // (2026-08-11 发散采纳)。
    @State private var showLastfmDisconnectConfirm = false
    // 点过「前往申请」才展开"怎么填"提示 —— 没点之前它是噪声(密钥早就填好的人根本
    // 不会去申请页)。
    @State private var showLastfmApplyHint = false

    var body: some View {
        // 2026-08-06 从 .formStyle(.grouped) 换成跟其余六个设置分类同一套卡片组件
        // (见 SettingsDesignSystem.swift)。页头从"左对齐的小徽标 + 标题"改成居中的
        // "大徽标 + 大标题 + 说明",跟其它分类一致;底部那条自动保存状态栏保持原样留在
        // 滚动区之外——它是常驻状态,不该跟着内容滚走。
        //
        // ⚠️ 这次只改外壳:.onReceive 的自动保存防抖、.onDisappear 的兜底保存、
        // .alert 的前置条件提示全部原样保留在同一个位置。Last.fm 连接流程那一块
        // (lastfmConnectArea/stepDots)和 SecretFieldRow 也没有拆成 SettingsRow ——
        // 它们各自带着真实逻辑(密钥的展开/收起、三步授权状态机),硬塞进"图标+标题+尾部
        // 控件"这个模子要重写控件本身,而这是全 App 最不该冒风险重写的地方(授权流程一旦
        // 坏掉,用户连不上账号且不容易看出是 UI 改动导致的)。这些成组控件整块放进
        // SettingsRawRow,拿到跟其它行一致的内边距即可。
        VStack(spacing: 0) {
            SettingsPageCustomHeader {
                VStack(spacing: 6) {
                    accountIconBadge(destination, size: 52, cornerRadius: 12)
                        .padding(.bottom, 2)
                    Text(destination.title)
                        .font(.system(size: 22, weight: .bold))
                    if let intro = cardIntroText {
                        Text(intro)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 380)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } content: {
                fields
            }
            Divider()
            autosaveStatusBar
        }
        // 文本字段(Token/API Key/Secret/Webhook 地址等,由 ConfigStore 承载)自动保存:
        // 不用 .onChange(of:)逐字符/失焦触发,而是监听 config.objectWillChange(任何
        // @Published 字段变化都会发一次信号,包括 Last.fm 连接成功后自动写入的
        // lastfmScrobbleSessionKey/lastfmScrobbleUsername)做 1.2 秒防抖,避免每敲一个
        // 字符/每次切换字段就重启一次 collector,也不需要给每个字段分别写 onChange。
        // performAutoSave() 内部会先判断 isDirty,不会被 lastError 这类非表单内容变化
        // 误触发做无意义的写盘+重启。
        .onReceive(config.objectWillChange.debounce(for: .milliseconds(1200), scheduler: DispatchQueue.main)) {
            Task { await performAutoSave() }
        }
        // 兜底:防抖计时器还没到 1.2 秒、用户就切换到别的账号卡片(这个 View 会被销毁
        // 重建)或者关掉设置窗口,不能让这最后一段编辑内容悄悄丢掉不生效。
        .onDisappear {
            if config.isDirty {
                Task { await performAutoSave() }
            }
        }
        .alert(
            L10n.t("还差一步"),
            isPresented: Binding(
                get: { missingPrereqAlert != nil },
                set: { if !$0 { missingPrereqAlert = nil } }
            ),
            presenting: missingPrereqAlert
        ) { alert in
            if let target = alert.jumpTarget {
                Button(String(format: L10n.t("去配置「%@」"), target.title)) { onJumpToAccount(target) }
                Button(L10n.t("取消"), role: .cancel) {}
            } else {
                Button(L10n.t("好的"), role: .cancel) {}
            }
        } message: { alert in
            Text(alert.message)
        }
        // 跟 SettingsView.swift 里给每个 Form 加 .id(L10n.current) 同一次修复、同一个
        // 理由——这个详情页整体也绑一份,双重保险,详细机制见 DestinationStatus.label
        // 的注释。
        .id(L10n.current)
    }

    // 关闭永远放行;打开前先查前置条件——sameCardHint 非 nil 就是"这张卡自己的字段
    // 还没填好"(没有跳转,弹完窗留在原地填);crossCard 非 nil 才检查另一张卡,同样
    // 缺了就弹窗+带跳转按钮。两层都过了才真的调用 apply(true)。
    private func toggleGuarded(
        _ newValue: Bool,
        sameCardHint: String?,
        crossCard: (hint: String?, target: AccountDestination)? = nil,
        apply: (Bool) -> Void
    ) {
        guard newValue else { apply(false); return }
        if let sameCardHint {
            missingPrereqAlert = MissingPrereqAlert(message: String(format: L10n.t("请先在这张卡上填好：%@"), sameCardHint), jumpTarget: nil)
            return
        }
        if let crossCard, let hint = crossCard.hint {
            missingPrereqAlert = MissingPrereqAlert(message: String(format: L10n.t("需要先配置「%@」（%@）"), crossCard.target.title, hint), jumpTarget: crossCard.target)
            return
        }
        apply(true)
    }

    // 这两个 helper 按 collector/digest.go 的 resolveDigestSource 同一套规则在 Swift 侧
    // 算一遍——两边各自独立实现(跑在不同进程/语言里),规则必须保持一致,改一处务必同步
    // 改另一处。
    //
    // resolvedDigestSource:preference 非空且对应账号确实配好了就用它;否则按"两个都配了
    // →Last.fm,只配了一个→用那个,都没配→空字符串(交给调用方按'需要先配置'处理)"解析。
    private func resolvedDigestSource(preference: String) -> String {
        let lastfmOK = config.lastfmBridgeMissingHint() == nil
        // 数据源是要去**读**统计的,所以看 isListenBrainzReadable(token+用户名),
        // 不是 isListenBrainzConfigured(只有 token)—— 后者会让只填 token 的用户
        // 在这里看到 ListenBrainz 可选,而 collector 那边永远跳过。
        let lbOK = config.isListenBrainzReadable
        switch preference {
        case "lastfm": if lastfmOK { return "lastfm" }
        case "listenbrainz": if lbOK { return "listenbrainz" }
        default: break
        }
        if lastfmOK { return "lastfm" }
        if lbOK { return "listenbrainz" }
        return ""
    }

    // digestCrossCard:给 toggleGuarded 的 crossCard 参数用——按"这次实际会用哪个数据源"
    // 动态指向对应的账号卡片,不再像改动前那样写死指向 Last.fm。source 为空(两个账号都
    // 没配)时仍需要给一个具体的 target(toggleGuarded 的 tuple 里这个字段不是 Optional),
    // 这里选 ListenBrainz 卡片没有特殊含义,纯粹是两个都不满足时随便选一个当跳转目标。
    private func digestCrossCard(source: String) -> (hint: String?, target: AccountDestination) {
        switch source {
        case "lastfm": return (hint: config.lastfmBridgeMissingHint(), target: .lastfm)
        case "listenbrainz": return (hint: config.isListenBrainzReadable ? nil : L10n.t("还缺用户名"), target: .listenBrainz)
        default: return (hint: L10n.t("未配置"), target: .listenBrainz)
        }
    }

    // digestSourcePicked:两个"数据源" Picker 的 set 分支共用。
    //
    // 原来这里是无条件 `features.xxxDigestSource = $0; save()`,而 get 读的是
    // resolvedDigestSource(**解析后**的值)——两边口径不一致。选一个还没配好的源(比如
    // ListenBrainz 一个字段都没填)会同时发生两件事:偏好被静默写盘并触发 save()(重写
    // 配置文件、重启 collector),而 Picker 因为 get 把它解析回 Last.fm 立刻弹回去。用户
    // 看到的是"点了没反应",但一个看不见的偏好已经落盘,等哪天真把那个账号配好,数据源
    // 会自己悄悄换过去。
    //
    // 现在:没配好就不写偏好、也不重启 collector,复用开关那套 missingPrereqAlert
    // ("需要先配置「X」"+跳转到对应账号卡片)给出跟 toggleGuarded 一致的反馈。
    // digestCrossCard 本来就是按 source 返回 (hint, target) 的,直接拿它判断配好了没。
    // 反过来,如果之前已经落过一个用不了的偏好,用户改选一个配好的源就能把它治回来。
    private func digestSourcePicked(_ picked: String, current: String, apply: (String) -> Void) {
        guard picked != current else { return }
        let cross = digestCrossCard(source: picked)
        if let hint = cross.hint {
            missingPrereqAlert = MissingPrereqAlert(
                message: String(format: L10n.t("需要先配置「%@」（%@）"), cross.target.title, hint),
                jumpTarget: cross.target
            )
            return
        }
        apply(picked)
    }

    // 每张卡片最上面这句"整体介绍"文案(描述整张卡是干什么的,不是某一个 Section 的)
    // 放在这里,在 detailHeader 和 Form 之间,不塞进任何一个 Section 的 header/footer——
    // footer 只能放纯文字且只描述那一个 Section,不适合放"整张卡"级别的介绍。
    private var cardIntroText: String? {
        switch destination {
        case .listenBrainz:
            // 2026-07-23:之前这里是 EmptyView(),理由是"账户信息" Section 的 footer
            // 已经有一句话——但那句("可选，不填不影响悬浮歌词")回答的是"要不要填"，
            // 不是"填了之后 App 会拿它做什么"，用户反馈缺一句跟其它三张卡片一样的
            // 用途说明，这里补上；下面 Section 的 footer 继续保留，两句话各自负责
            // 不同的信息，跟其它卡片的结构一致。
            return L10n.t("这台 Mac 上的播放记录会同步到 ListenBrainz，建立完整的听歌历史；也是网页展示、听歌报告的可选数据来源")
        case .stateRelay:
            return L10n.t("用来把当前播放状态推送到网页小组件和状态徽章")
        case .lastfm:
            // 2026-07-29:"读取"方向(同步到 ListenBrainz)原来是下面一个独立开关,现在
            // 去掉了——UI 上这个开关本来就要求"Last.fm 桥接凭据 + ListenBrainz 都配好"
            // 才能打开(toggleGuarded 的 sameCardHint/crossCard 两层校验),跟"两边都配好
            // 就默认生效"这个判定条件完全一样,单独留一个开关只是多一次点击,没有实际
            // 区分度。跟"网页推送"那两个字段"填好就是唯一的开关"是同一个思路(见
            // stateRelayFields 的 footer 注释)。
            return L10n.t("把你播放的歌记录到 Last.fm")
        case .bark:
            return L10n.t("用来接收「每周听歌小结」「每日听歌报告」推送")
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch destination {
        case .listenBrainz: listenBrainzFields
        case .lastfm: lastfmFields
        case .stateRelay: stateRelayFields
        case .bark: barkFields
        }
    }

    // MARK: - ListenBrainz

    private var listenBrainzFields: some View {
        SettingsCard {
            SettingsRow(
                icon: "key",
                title: L10n.t("账户信息"),
                subtitle: L10n.t("可选，不填不影响悬浮歌词")
            )
            CardDivider()
            SettingsRawRow(insetToText: true) {
                VStack(alignment: .leading, spacing: 8) {
                    SecretFieldRow(L10n.t("账户 Token"), value: $config.listenbrainzToken)
                    Link(L10n.t("在 ListenBrainz 网站获取 Token →"), destination: URL(string: "https://listenbrainz.org/settings/")!)
                        .font(.caption)
                    TextField(L10n.t("用户名（听歌报告需要）"), text: $config.listenbrainzUser)
                }
            }
        }
    }

    // MARK: - 状态中继

    @ViewBuilder
    private var stateRelayFields: some View {
        SettingsCard {
            SettingsRow(
                icon: "antenna.radiowaves.left.and.right",
                title: L10n.t("连接信息"),
                subtitle: L10n.t("填好这两项就会自动推送到网页")
            )
            CardDivider()
            SettingsRawRow(insetToText: true) {
                VStack(alignment: .leading, spacing: 8) {
            TextField(text: $config.stateRelayURL, prompt: Text(L10n.t("例如 https://yourdomain.com/api/state"))) {
                HStack(spacing: 4) {
                    Text(L10n.t("同步服务地址"))
                    HelpButton(
                        text: L10n.t("自己用 Cloudflare Worker + KV 搭建的 state-worker 服务（独立公开仓库 Yudaotor/nowplaying-workers）。不想自建也行：配好「ListenBrainz」也能让网页兜底显示「正在播放」，两者配一个就够。效果截图 + 完整从零搭建步骤见该仓库自己的 README"),
                        docTitle: L10n.t("查看效果 + 教程 →"),
                        // 指向 Yudaotor/nowplaying-workers 仓库自己的 README(#readme 锚点,
                        // GitHub 会自动渲染仓库首页那份)。
                        docURL: URL(string: "https://github.com/Yudaotor/nowplaying-workers#readme")!
                    )
                }
            }
            SecretFieldRow(L10n.t("访问令牌"), value: $config.stateRelayToken)
                }
            }
        }
    }

    // MARK: - Last.fm(合并 iPhone 桥接 + Mac 镜像——都是同一个 Last.fm 账号)

    // 2026-07-29:两个功能原来各自要求一套独立凭据(桥接用一把只读 Key,镜像用另一把
    // 带 Secret 的 Key),逼用户去 Last.fm 后台建两个"应用"填两遍——技术上没必要:
    // Last.fm 的只读接口(user.getrecenttracks 等)不校验签名,同一对 API Key/Secret
    // 既能免签名供桥接读,也能签名走连接流程供镜像写。现在合并成一套"账号信息",
    // 下面只剩"写入记录"这一个还需要手动开关的 Section——"读取"那一半(同步到
    // ListenBrainz)同一天又被去掉了独立开关,理由见上面 cardIntro 附近的注释。
    // 2026-08-11 按「一个开关」方案重做:这一页 99% 的时间处于"已连接"态,旧版却把
    // 配置期才需要的东西(用户名输入框、API Key/Secret 两行、"前往申请")永久平铺着,
    // 三个绿色指示器("已设置"×2 +"已连接")说的其实是同一件事。现在:
    //   - 主界面只剩一行开关(+ 已连接时一行状态);
    //   - API Key/Secret 收进"连接向导"sheet,只在配置那一刻出现;
    //   - 未连接时打开开关 = 打开向导,连接成功自动开启 scrobble——消灭"已连接但开关
    //     没开"这个死状态(用户以为连上就会记录,实际还差一个开关);断开时同步关掉;
    //   - 手填用户名框删掉:授权成功返回的真实用户名自动回填(LastfmAuthFlow 里已有
    //     该逻辑),桥接/周报读的就是它。
    /// 未连接时那一栏:本地已记录的收听清单。
    ///
    /// 折起来只占一行(显示条数),展开才是清单 —— 攒到几十首时不该把整页顶开。
    @ViewBuilder
    private var pendingListensRow: some View {
        let items = backfill.pending?.items ?? []
        SettingsRawRow(insetToText: true) {
            DisclosureGroup(isExpanded: $pendingListensExpanded) {
                // 高度封顶 + 自己滚:清单可能几十上百条,不能让它无限撑高这张卡。
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(items, id: \.uts) { item in
                            let hovered = hoveredPendingUTS == item.uts
                            HStack(spacing: 6) {
                                Text(item.title)
                                    .font(.caption)
                                    .lineLimit(1)
                                Text(item.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(Self.listenTimeText(item.uts))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                                // 槽位常驻、只改 opacity:按钮跟着 hover 出现/消失的话,
                                // 整行会跟着变宽变窄,鼠标扫过清单时每一行都在抖。
                                Button {
                                    backfill.deleteListen(uts: item.uts)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .opacity(hovered ? 1 : 0)
                                // 藏起来的时候必须同时不接受点击 —— 否则清单右侧会有一条
                                // 看不见却挡手的区域。
                                .allowsHitTesting(hovered && !backfill.busy)
                                .help(L10n.t("从待补提交清单里移除这条（不可恢复）"))
                            }
                            .contentShape(Rectangle())
                            .onHover { inside in
                                hoveredPendingUTS = inside ? item.uts : nil
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .frame(maxHeight: 180)
            } label: {
                Label(
                    String(format: L10n.t("本地已记录 %@ 首，连接后可补提交"), "\(items.count)"),
                    systemImage: "tray.full"
                )
                .font(.callout)
            }
        }
    }

    private static func listenTimeText(_ uts: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(uts)))
    }

    /// 「补提交历史收听」那一行。数量来自 collector 的 dry-run(不发任何请求)。
    @ViewBuilder
    private var backfillRow: some View {
        let pending = backfill.pending?.eligible ?? 0
        let tooOld = backfill.pending?.skippedTooOld ?? 0
        let last = backfill.lastRun
        SettingsRow(
            icon: "clock.arrow.circlepath",
            title: L10n.t("补提交历史收听"),
            subtitle: backfillSubtitle(pending: pending, tooOld: tooOld, last: last)
        ) {
            HStack(spacing: 8) {
                if backfill.busy { ProgressView().controlSize(.small) }
                Button(L10n.t("补提交")) { backfill.runBackfill() }
                    .disabled(backfill.busy || pending == 0)
            }
        }
    }

    private func backfillSubtitle(
        pending: Int, tooOld: Int, last: ScrobbleBackfillService.Outcome?
    ) -> String {
        // 刚跑完就报这次的结果,比"还剩几条"更是用户此刻想知道的。
        if let last, last.accepted + last.ignored + last.quarantined > 0 {
            var parts = [String(format: L10n.t("已补 %@ 条"), "\(last.accepted)")]
            if last.quarantined > 0 {
                parts.append(String(format: L10n.t("%@ 条状态未知，不会自动重试"), "\(last.quarantined)"))
            }
            if last.ignored > 0 {
                parts.append(String(format: L10n.t("%@ 条被 Last.fm 拒绝"), "\(last.ignored)"))
            }
            return parts.joined(separator: "，")
        }
        if pending == 0 {
            // 没有可补的是最常见的状态(一直连着账号的人永远看到这句),所以这句话要
            // 解释清楚这栏存在的意义,而不是干巴巴一个"没有"。
            return tooOld > 0
                ? String(format: L10n.t("没有待补的收听；%@ 条已超过 Last.fm 能接受的两周期限"), "\(tooOld)")
                : L10n.t("没连账号时听的歌会记在本地，连上之后可以补提交到 Last.fm")
        }
        var s = String(format: L10n.t("有 %@ 条本地收听还没提交"), "\(pending)")
        if tooOld > 0 {
            s += String(format: L10n.t("，另有 %@ 条太旧、Last.fm 不再接受"), "\(tooOld)")
        }
        return s
    }

    @ViewBuilder
    private var lastfmFields: some View {
        // ⚠️ refreshPending 必须挂在**总会渲染**的这张卡上,不能挂在下面那两行里。
        //
        // 2026-08-13 用户实测"断开听了几首、回来什么都没有"抓到的死锁:那两行的显示条件都是
        // `eligible > 0`,而 eligible 又只有 refreshPending 跑过才不是 0 —— 把刷新挂在它们
        // 自己的 .onAppear 上,就成了"不显示 → 不刷新 → 永远是 0 → 永远不显示"。
        // 当时数据层是完全正确的(日志里躺着 3 条待补),纯粹是界面永远不去问一次。
        SettingsCard {
            SettingsRow(
                icon: "arrow.up.circle",
                title: L10n.t("Scrobble 到 Last.fm")
            ) {
                Toggle("", isOn: Binding(
                    get: { lastfmConnected && features.lastfmMirrorScrobble },
                    set: { on in
                        if on {
                            if lastfmConnected {
                                features.lastfmMirrorScrobble = true
                                Task { await features.save() }
                            } else {
                                // 开关本身就是配置入口。视觉上不先扳过去(get 算出来
                                // 仍是 false),等向导真正连接成功再亮。
                                showLastfmWizard = true
                            }
                        } else {
                            features.lastfmMirrorScrobble = false
                            Task { await features.save() }
                        }
                    }
                ))
            }
            // 未连接时:把本地已经记下来的歌列出来。
            //
            // 光说"会记在本地"是空头承诺 —— 用户没法验证到底记了没有、记了什么。列出来
            // 之后这件事就是可核对的,连账号时也能预期"补上去大概是这些"。
            if !lastfmConnected, (backfill.pending?.eligible ?? 0) > 0 {
                CardDivider()
                pendingListensRow
            }
            if lastfmConnected, LastfmMirrorStatus.current != nil {
                CardDivider()
                SettingsRawRow(insetToText: true) {
                    HStack(spacing: 8) {
                        Label(L10n.t("Last.fm 拒绝了写入，Scrobble 已暂停——授权可能已在网站上被撤销"),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                        Spacer()
                        Button(L10n.t("重新连接")) { showLastfmWizard = true }
                    }
                }
            }
            // 补提交历史收听 —— **只在真有东西可补时才出现**。
            //
            // 这是个一辈子可能只点一次的操作(先用了一阵、之后才连账号的那段空窗),
            // 常驻一行"没有待补的收听"纯属占地方。有内容才露出来,没内容就完全不存在。
            //
            // 仍然坚持"必须人工点一下"、不做连接成功自动弹窗:这一步往用户的 Last.fm
            // 写数据,而 scrobble 落进去基本删不掉(只能在网页上一条条手删),自动弹窗
            // 容易被顺手点掉,而顺手的代价是永久污染自己的听歌历史。
            if lastfmConnected, (backfill.pending?.eligible ?? 0) > 0 {
                CardDivider()
                backfillRow
            }
            if lastfmConnected {
                CardDivider()
                SettingsRawRow(insetToText: true) {
                    HStack {
                        Label(
                            lastfmDisplayName.isEmpty
                                ? L10n.t("已连接 Last.fm 账号")
                                : String(format: L10n.t("已连接：%@"), lastfmDisplayName),
                            systemImage: "checkmark.seal.fill"
                        ).foregroundStyle(.green)
                        Spacer()
                        lastfmProfileLinkButton
                        Button(L10n.t("断开")) { showLastfmDisconnectConfirm = true }
                        .buttonStyle(.link)
                    }
                }
            }
        }
        .onAppear { backfill.refreshPending() }
        // 连接状态一变就重算:刚断开的那一刻要立刻列出本地已记的歌,刚连上的那一刻要立刻
        // 露出补提交那一行。只靠 .onAppear 的话,用户不离开这一页就什么都不会变。
        .onChange(of: lastfmConnected) { _, _ in backfill.refreshPending() }
        .sheet(isPresented: $showLastfmWizard) { lastfmWizardSheet }
        .alert(L10n.t("断开 Last.fm？"), isPresented: $showLastfmDisconnectConfirm) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("断开"), role: .destructive) { performLastfmDisconnect() }
        } message: {
            Text(L10n.t("重新连接需要再走一次浏览器授权"))
        }

        // 信息展示区(方案 A「档案页」):已连接才有数据可看;未连接给一句预告,
        // 不画一页空骨架。
        if lastfmConnected {
            LastfmStatsSection()
        } else {
            SettingsCard {
                Text(L10n.t("连接后这里会展示你的听歌档案"))
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            }
        }
    }

    private var lastfmConnected: Bool { !config.lastfmScrobbleSessionKey.isEmpty }

    /// 断开的完整不变量集:清凭据、清"授权失效"红标(描述的是刚扔掉的旧钥匙)、
    /// 统计归零(数字/榜单/头像都是这个账号的,重连别人不该看到前任数据)、关掉
    /// scrobble 开关(断开后一定发不出去,不留假状态)。
    private func performLastfmDisconnect() {
        config.lastfmScrobbleSessionKey = ""
        config.lastfmScrobbleUsername = ""
        LastfmMirrorStatus.clear()
        LastfmStatsService.shared.resetAll()
        features.lastfmMirrorScrobble = false
        Task {
            await config.save()
            await features.save()
        }
    }

    // 展示用的用户名。scrobbleUsername 是授权返回的权威值,但老用户的连接早于"授权返回
    // 用户名"这个功能(2026-07-29 加的),它可能是空的——这时退回手填时代留下的
    // lastfmUser,别让老用户看到一行没有名字的"已连接"。
    private var lastfmDisplayName: String {
        config.lastfmScrobbleUsername.isEmpty ? config.lastfmUser : config.lastfmScrobbleUsername
    }

    private var lastfmConnectSucceeded: Bool {
        if case .success = lastfmConnect.state { return true }
        return false
    }

    /// 拿去连接用的密钥:去掉首尾空白,并把修剪后的值写回配置(修剪结果和签名用的是
    /// 同一份)。从网页拷贝 Key/Secret 极易带上换行/空格,不修剪的话换回来的是一句
    /// 晦涩的 "Invalid API key"(2026-08-11 审阅指出)。
    private func trimmedLastfmKeys() -> (key: String, secret: String) {
        let k = config.lastfmScrobbleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = config.lastfmScrobbleSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if k != config.lastfmScrobbleAPIKey { config.lastfmScrobbleAPIKey = k }
        if s != config.lastfmScrobbleSecret { config.lastfmScrobbleSecret = s }
        return (k, s)
    }

    // 连接向导——整个 App 里唯一会见到 API Key/Secret 的地方。
    private var lastfmWizardSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.t("连接 Last.fm")).font(.title3.bold())
                Spacer()
                Button(L10n.t("取消")) {
                    lastfmConnect.reset()
                    showLastfmWizard = false
                }
            }
            HStack {
                Text(L10n.t("下面的「连接」要用这对密钥完成授权：先在 Last.fm 创建一个应用，拿到 API Key 和 Secret"))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    // 不是纯 Link:打开申请页的同时展开下面那条"怎么填"。申请页在登录墙
                    // 后面、不支持 URL 参数预填(2026-08-11 实测:未登录 302 到 /login),
                    // 帮用户填表做不到,能做的是把"该填什么"送到眼前。
                    Button(L10n.t("前往申请")) {
                        NSWorkspace.shared.open(URL(string: "https://www.last.fm/api/account/create")!)
                        withAnimation { showLastfmApplyHint = true }
                    }
                    .buttonStyle(.link)
                    // 重装/重置配置/换机器之后要重新填这对密钥,而这些人**早就创建过应用**
                    // 了 —— 只给"前往申请"的话他们只能再建一个重复的。这个入口必须常驻:
                    // 上面那条"怎么填"的提示要点过「前往申请」才展开,而他们恰恰不会点它。
                    // /api/accounts 是 Last.fm 的"我的 API 应用"列表(2026-08-15 实测:
                    // 未登录 302 到 /login,页面存在;/api/account 不带 s 是 404)。
                    Button(L10n.t("查看已有应用")) {
                        NSWorkspace.shared.open(URL(string: "https://www.last.fm/api/accounts")!)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help(L10n.t("之前创建过就从这里找回：列表里点应用名，页面上就有 API Key 和 Shared Secret"))
                }
            }
            if showLastfmApplyHint {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(L10n.t("申请页基本只需要填「应用名称」，其余留空即可；提交后页面会直接显示 API Key 和 Shared Secret"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L10n.t("拷贝名称")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("Lyrimuse", forType: .string)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help(L10n.t("把「Lyrimuse」拷到剪贴板，粘进申请页的应用名称"))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            }
            SecretFieldRow("API Key", value: $config.lastfmScrobbleAPIKey)
            SecretFieldRow("Secret", value: $config.lastfmScrobbleSecret)
            Divider()
            lastfmConnectArea
        }
        .padding(20)
        .frame(width: 460)
        // Esc / 点外面关掉 sheet 时状态机跟着复位 —— 原来残留在 waitingForBrowserAuth,
        // 下次打开向导直接停在中间步骤,还带着一个已经作废的 token(审阅确认)。成功
        // 自动关闭那条路里 reset 已经调用过,这里重复调用无害(幂等)。
        .onDisappear { lastfmConnect.reset() }
        .onChange(of: lastfmConnectSucceeded) { _, ok in
            guard ok else { return }
            // 连接成功 = 想要 scrobble,直接开,不让用户猜"还差一个开关"。
            features.lastfmMirrorScrobble = true
            Task { await features.save() }
            // 停一拍让"已连接"那行被看见,再收起向导。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                showLastfmWizard = false
                lastfmConnect.reset()
            }
        }
    }

    // Last.fm 的公开主页地址就是 last.fm/user/<用户名>,不需要走已连接账号那一步——
    // 只填了用户名(还没走连接流程)也能跳转,用户名是这个链接唯一需要的信息。用户名
    // 本身没有格式校验(填错会跳转到一个不存在的 Last.fm 用户页,那是用户自己的输入
    // 问题,不是这个链接的责任),这里只做"清空首尾空白 + URL 转义",避免空白/特殊
    // 字符拼出一个明显打不开的地址。
    private var lastfmProfileURL: URL? {
        let trimmed = config.lastfmUser.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "https://www.last.fm/user/\(encoded)")
    }

    // 跳转按钮而不是单独一行——"查看主页"这个动作最自然的落点就是紧挨着"已连接"这行
    // 状态信息,不需要在页面里单占一整行。图标用而不是文字,保持这一行紧凑;两处调用点
    // (lastfmConnectArea 的 .idle 已连接分支 + .success 分支)都嵌进各自那个 HStack 的
    // Spacer 之后,跟"断开"按钮同一行。
    @ViewBuilder
    private var lastfmProfileLinkButton: some View {
        if let profileURL = lastfmProfileURL {
            Link(destination: profileURL) {
                Image(systemName: "arrow.up.forward.square")
            }
            .help(L10n.t("在 Last.fm 网站查看主页"))
        }
    }

    // Last.fm 经典 auth API 没有回调机制,中间必须有一步用户手动确认——三步小圆点让
    // 这个"看起来复杂"的流程翻译成"其实就三步,你现在在第几步"。
    @ViewBuilder
    private var lastfmConnectArea: some View {
        switch lastfmConnect.state {
        case .idle:
            if config.lastfmScrobbleSessionKey.isEmpty {
                stepDots(current: 0)
                Button(L10n.t("连接 Last.fm 账号")) {
                    let keys = trimmedLastfmKeys()
                    lastfmConnect.start(apiKey: keys.key, secret: keys.secret)
                }
                    .buttonStyle(.borderedProminent)
            } else {
                HStack {
                    Label(
                        config.lastfmScrobbleUsername.isEmpty ? L10n.t("已连接 Last.fm 账号") : String(format: L10n.t("已连接：%@"), config.lastfmScrobbleUsername),
                        systemImage: "checkmark.seal.fill"
                    ).foregroundStyle(.green)
                    Spacer()
                    lastfmProfileLinkButton
                    Button(L10n.t("断开")) {
                        // 同一套不变量,复用主卡的方法。不再弹确认:这里已经在
                        // 「重新连接」两层交互之下,误点概率低,sheet 上叠 alert 反而别扭。
                        performLastfmDisconnect()
                    }
                    .buttonStyle(.link)
                }
            }
        case .requestingToken:
            stepDots(current: 1)
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.t("正在获取授权令牌…")).font(.caption)
            }
        case .waitingForBrowserAuth:
            stepDots(current: 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("已在浏览器打开 Last.fm 授权页面。请在浏览器里点击「Yes, allow access」完成授权，授权完会自动跳回 Lyrimuse 继续；如果浏览器没有自动跳转，也可以回来手动点下面的按钮"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L10n.t("我已完成授权，继续")) { lastfmConnect.confirmBrowserAuth() }
                .buttonStyle(.borderedProminent)
                HStack(spacing: 12) {
                    Button(L10n.t("重新打开授权页面")) { lastfmConnect.reopenBrowserAuth() }
                        .buttonStyle(.link)
                    Button(L10n.t("取消")) { lastfmConnect.reset() }
                        .buttonStyle(.link).foregroundStyle(.secondary)
                }
            }
        case .exchanging:
            stepDots(current: 3)
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.t("正在确认授权，即将完成…")).font(.caption)
            }
        case .success(let username):
            HStack {
                Label(String(format: L10n.t("已连接：%@"), username), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                Spacer()
                lastfmProfileLinkButton
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                Button(L10n.t("重试")) { lastfmConnect.reset() }
                    .buttonStyle(.link)
            }
        }
    }

    private func stepDots(current: Int) -> some View {
        HStack(spacing: 4) {
            stepDot(filled: current >= 1, label: L10n.t("① 填写密钥"))
            stepLine(active: current >= 2)
            stepDot(filled: current >= 2, label: L10n.t("② 浏览器授权"))
            stepLine(active: current >= 3)
            stepDot(filled: current >= 3, label: L10n.t("③ 完成连接"))
        }
    }

    private func stepDot(filled: Bool, label: String) -> some View {
        Circle()
            .fill(filled ? Color.accentColor : Color.clear)
            .overlay(Circle().strokeBorder(filled ? Color.clear : Color.secondary.opacity(0.5), lineWidth: 1))
            .frame(width: 6, height: 6)
            .accessibilityLabel(label)
    }

    private func stepLine(active: Bool) -> some View {
        Rectangle()
            .fill(active ? Color.accentColor : Color.secondary.opacity(0.3))
            .frame(width: 16, height: 1)
    }

    // MARK: - 推送提醒

    // 绝大多数平台都是"群机器人 webhook"这个模子(一个 URL,POST 一份 JSON),具体 payload
    // 长什么样在 collector/notify.go 里,这边只管选平台+填地址;Server酱是个例外,走表单
    // 编码不是 JSON,但那是纯后端的事,这边 UI 完全不用关心。钉钉/飞书这两个平台的机器人
    // 如果开了"加签"安全设置就还需要额外一个签名密钥(两边算法不同,分开存,见 ConfigStore
    // 的字段注释),用 SecretFieldRow 收起来;其余平台(Bark/企业微信/Discord/Server酱)
    // 都不需要。
    //
    // 两个听歌报告开关放在这里(而不是单独的"功能开关"tab),是因为开关跟着它依赖的账号
    // 模块走,不用去别处猜"这个开关归哪个账号管";还依赖 Last.fm 桥接(数据来源),缺了给
    // 一个跳转提示。实际推送的是 Top 歌手+Top 歌曲各三条+总播放次数(见 collector/weekly.go
    // 的 weeklyDigestPush),别跟另一个不相关的功能"历史 Top10 歌手统计"搞混——那是网页上
    // 的常驻榜单,数据来源不同。
    @ViewBuilder
    private var barkFields: some View {
        SettingsCard {
            // 这一行的"?"里带官方文档外链(docTitle/docURL),SettingsRow 的 help 参数只收
            // 纯文本,所以这一行整块用 SettingsRawRow 自己排:图标列宽和左缩进都取
            // SettingsRowMetrics,跟其它行对齐在同一条竖线上。
            SettingsRawRow {
                HStack(spacing: SettingsRowMetrics.iconTextSpacing) {
                    Image(systemName: "bell.badge")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: SettingsRowMetrics.iconWidth)
                    Text(L10n.t("通知平台"))
                        .font(.system(size: 13))
                    HelpButton(
                        text: config.notificationPlatform.setupGuide,
                        docTitle: L10n.t("查看官方文档 →"),
                        docURL: config.notificationPlatform.setupDocURL
                    )
                    Spacer(minLength: 12)
                    Picker("", selection: $config.notificationPlatform) {
                        ForEach(NotificationPlatform.allCases) { platform in
                            Text(platform.displayName).tag(platform)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            CardDivider()
            SettingsRawRow(insetToText: true) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(
                        L10n.t("Webhook 地址"), text: $config.notificationWebhookURL,
                        prompt: Text(config.notificationPlatform.urlPlaceholder)
                    )
                    if config.notificationPlatform == .dingtalk {
                        SecretFieldRow(L10n.t("加签密钥（可选）"), value: $config.dingtalkSignSecret)
                        Text(L10n.t("机器人安全设置选了「加签」才需要填，留空按未加签处理"))
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if config.notificationPlatform == .feishu {
                        SecretFieldRow(L10n.t("签名密钥（可选）"), value: $config.feishuSignSecret)
                        Text(L10n.t("机器人安全设置开了「签名校验」才需要填，不开也能收到消息"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }

        SettingsCard {
            SettingsRow(
                icon: "chart.bar.doc.horizontal",
                title: L10n.t("提醒开关"),
                subtitle: L10n.t("数据源留空时自动判定：两个账号都配了优先用 Last.fm，只配了一个就用那个")
            )
            CardDivider()
            // 数据源可选——Last.fm 的周榜接口(user.getWeeklyTrackChart/getWeeklyArtistChart)
            // 其实接受任意 from/to,不是只认官方周边界,因此两个 cadence 都能自己选数据源。
            // Picker 挂在对应开关打开之后(参照"灵动岛风格"只在"灵动岛歌词"开着才出现的
            // 既有模式)——没开这个提醒,选哪个数据源无所谓;两个 Picker 各给了区分度更高
            // 的标签("每周数据源"/"每日数据源"而不是都叫"数据源"),避免分不清哪个 Picker
            // 归哪个开关管。Picker 显示的是"这次实际会用哪个"(未手动选时是
            // resolvedDigestSource 判定出的默认值),一旦手动选过就变成显式 persist 的偏好。
            SettingsRow(
                icon: "calendar",
                title: L10n.t("每周听歌小结"),
                subtitle: L10n.t("Top 歌手 + Top 歌曲各三条 + 总播放次数")
            ) {
                Toggle("", isOn: Binding(
                    get: { features.weeklyDigest },
                    set: { newValue in
                        let source = resolvedDigestSource(preference: features.weeklyDigestSource)
                        toggleGuarded(newValue,
                            sameCardHint: config.pushMissingHint(),
                            crossCard: digestCrossCard(source: source)
                        ) { v in features.weeklyDigest = v; Task { await features.save() } }
                    }
                ))
            }
            if features.weeklyDigest {
                CardDivider()
                SettingsSubRow(title: L10n.t("每周数据源")) {
                    Picker("", selection: Binding(
                        get: { resolvedDigestSource(preference: features.weeklyDigestSource) },
                        set: { picked in
                            digestSourcePicked(picked, current: features.weeklyDigestSource) {
                                features.weeklyDigestSource = $0
                                Task { await features.save() }
                            }
                        }
                    )) {
                        Text("Last.fm").tag("lastfm")
                        Text("ListenBrainz").tag("listenbrainz")
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            CardDivider()
            SettingsRow(
                icon: "sun.max",
                title: L10n.t("每日听歌报告"),
                subtitle: L10n.t("本地时间晚上 10 点之后当天第一次检查时推送：当天播放次数、累计时长、听得最多的几首歌")
            ) {
                Toggle("", isOn: Binding(
                    get: { features.dailyDigest },
                    set: { newValue in
                        let source = resolvedDigestSource(preference: features.dailyDigestSource)
                        toggleGuarded(newValue,
                            sameCardHint: config.pushMissingHint(),
                            crossCard: digestCrossCard(source: source)
                        ) { v in features.dailyDigest = v; Task { await features.save() } }
                    }
                ))
            }
            if features.dailyDigest {
                CardDivider()
                SettingsSubRow(title: L10n.t("每日数据源")) {
                    Picker("", selection: Binding(
                        get: { resolvedDigestSource(preference: features.dailyDigestSource) },
                        set: { picked in
                            digestSourcePicked(picked, current: features.dailyDigestSource) {
                                features.dailyDigestSource = $0
                                Task { await features.save() }
                            }
                        }
                    )) {
                        Text("Last.fm").tag("lastfm")
                        Text("ListenBrainz").tag("listenbrainz")
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
        }
    }

    // MARK: - 底部状态栏

    // 文本字段已经自动保存(见 body 的 .onReceive),这里只保留状态展示:正在自动保存/
    // 上次保存时间/报错。
    private var autosaveStatusBar: some View {
        HStack(spacing: 8) {
            if isSaving {
                ProgressView().controlSize(.small)
                Text(L10n.t("正在自动保存…"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                saveStatusText
            }
            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private var saveStatusText: some View {
        if let error = config.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        } else if let lastSavedAt {
            Text(String(format: L10n.t("上次保存：%@ · 采集器已重启"), lastSavedAt.formatted(date: .omitted, time: .shortened)))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func performAutoSave() async {
        guard config.isDirty, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        if await config.save() {
            lastSavedAt = Date()
        }
    }
}
