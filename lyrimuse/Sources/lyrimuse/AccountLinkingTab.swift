import AppKit
import Combine
import SwiftUI

// 每张卡片的连接状态——只有三态会在"账号连接"这个分类里实际出现(这里只关心"有没有
// 配好",不关心"这个功能要不要用",所以 .disabled 这个"未启用"分支在这里永远不会被
// 构造;它是给"功能开关"tab 复用同一套视觉/文案时才会用到的第四态)。颜色驱动而不是
// 纯文字驱动,一眼扫过图标颜色就能分辨状态。
enum DestinationStatus {
    case disabled                  // 灰:开关关闭,不管凭据填没填都不报错(仅"功能开关"tab 用)
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
        return config.isListenBrainzConfigured
            ? .active(config.listenbrainzUser.isEmpty ? nil : String(format: L10n.t("已连接为 @%@"), config.listenbrainzUser))
            : .missingCreds(L10n.t("未配置（可选）"))
    case .stateRelay:
        if let hint = config.stateRelayMissingHint() { return .missingCreds(hint) }
        return .active()
    case .lastfm:
        if case .failed(let msg) = lastfmConnect.state { return .error(msg) }
        // bridgeOK 故意不能只看 lastfmBridgeMissingHint()——那个函数是"Last.fm 侧凭据
        // 填了没"这个更窄的判断,同时也被 resolvedDigestSource(听歌报告的数据源判定)
        // 复用,不能因为这里也要求 ListenBrainz 就把它改成两个账号联查,否则会误伤只
        // 配了 Last.fm、没配 ListenBrainz 的听歌报告场景。"读取"这个方向现在没有独立
        // 开关了(2026-07-29 起两边都配好就自动生效,见 cardIntro 附近的注释),这里的
        // 徽标要准确反映"真的在跑没有",所以额外叠一层 isListenBrainzConfigured。
        let bridgeOK = config.lastfmBridgeMissingHint() == nil && config.isListenBrainzConfigured
        let mirrorOK = config.lastfmMirrorMissingHint() == nil
        switch (bridgeOK, mirrorOK) {
        case (true, true): return .active(L10n.t("读取+写入已配置"))
        case (true, false): return .active(L10n.t("读取已配置"))
        case (false, true): return .active(L10n.t("写入已配置"))
        case (false, false): return .missingCreds(L10n.t("未配置"))
        }
    case .bark:
        if let hint = config.pushMissingHint() { return .missingCreds(hint) }
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

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailHeader
                    cardIntro
                    Form {
                        fields
                    }
                    .formStyle(.grouped)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        let lbOK = config.isListenBrainzConfigured
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
        case "listenbrainz": return (hint: config.isListenBrainzConfigured ? nil : L10n.t("未配置"), target: .listenBrainz)
        default: return (hint: L10n.t("未配置"), target: .listenBrainz)
        }
    }

    // 每张卡片最上面这句"整体介绍"文案(描述整张卡是干什么的,不是某一个 Section 的)
    // 放在这里,在 detailHeader 和 Form 之间,不塞进任何一个 Section 的 header/footer——
    // footer 只能放纯文字且只描述那一个 Section,不适合放"整张卡"级别的介绍。
    @ViewBuilder
    private var cardIntro: some View {
        switch destination {
        case .listenBrainz:
            // 2026-07-23:之前这里是 EmptyView(),理由是"账户信息" Section 的 footer
            // 已经有一句话——但那句("可选，不填不影响悬浮歌词")回答的是"要不要填"，
            // 不是"填了之后 App 会拿它做什么"，用户反馈缺一句跟其它三张卡片一样的
            // 用途说明，这里补上；下面 Section 的 footer 继续保留，两句话各自负责
            // 不同的信息，跟其它卡片的结构一致。
            Text(L10n.t("这台 Mac 上的播放记录会同步到 ListenBrainz，建立完整的听歌历史；也是网页展示、听歌报告的可选数据来源"))
                .font(.caption).foregroundStyle(.secondary)
        case .stateRelay:
            Text(L10n.t("用来把当前播放状态推送到网页小组件和状态徽章"))
                .font(.caption).foregroundStyle(.secondary)
        case .lastfm:
            // 2026-07-29:"读取"方向(同步到 ListenBrainz)原来是下面一个独立开关,现在
            // 去掉了——UI 上这个开关本来就要求"Last.fm 桥接凭据 + ListenBrainz 都配好"
            // 才能打开(toggleGuarded 的 sameCardHint/crossCard 两层校验),跟"两边都配好
            // 就默认生效"这个判定条件完全一样,单独留一个开关只是多一次点击,没有实际
            // 区分度。跟"网页推送"那两个字段"填好就是唯一的开关"是同一个思路(见
            // stateRelayFields 的 footer 注释)。
            Text(L10n.t("同一个 Last.fm 账号，可以双向同步收听记录"))
                .font(.caption).foregroundStyle(.secondary)
        case .bark:
            Text(L10n.t("用来接收「每周听歌小结」「每日听歌报告」推送"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 12) {
            accountIconBadge(destination, size: 36, cornerRadius: 8)
            Text(destination.title).font(.title3.weight(.semibold))
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
        Section {
            SecretFieldRow(L10n.t("账户 Token"), value: $config.listenbrainzToken)
            Link(L10n.t("在 ListenBrainz 网站获取 Token →"), destination: URL(string: "https://listenbrainz.org/settings/")!)
                .font(.caption)
            TextField(L10n.t("用户名（选填，用于界面显示）"), text: $config.listenbrainzUser)
        } header: {
            Text(L10n.t("账户信息"))
        } footer: {
            Text(L10n.t("可选，不填不影响悬浮歌词"))
        }
    }

    // MARK: - 状态中继

    @ViewBuilder
    private var stateRelayFields: some View {
        Section {
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
        } header: {
            Text(L10n.t("连接信息"))
        } footer: {
            // 这两个字段填好本身就是"要不要推"这件事唯一的开关,不再需要额外一层可以
            // 打开也可以关闭的开关;网页那边(state-worker/网页前端)看到 modules 配置
            // 缺失本来就按"全部启用"兜底,语义对得上。
            Text(L10n.t("填好这两项就会自动推送到网页"))
        }
    }

    // MARK: - Last.fm(合并 iPhone 桥接 + Mac 镜像——都是同一个 Last.fm 账号)

    // 2026-07-29:两个功能原来各自要求一套独立凭据(桥接用一把只读 Key,镜像用另一把
    // 带 Secret 的 Key),逼用户去 Last.fm 后台建两个"应用"填两遍——技术上没必要:
    // Last.fm 的只读接口(user.getrecenttracks 等)不校验签名,同一对 API Key/Secret
    // 既能免签名供桥接读,也能签名走连接流程供镜像写。现在合并成一套"账号信息",
    // 下面只剩"写入记录"这一个还需要手动开关的 Section——"读取"那一半(同步到
    // ListenBrainz)同一天又被去掉了独立开关,理由见上面 cardIntro 附近的注释。
    @ViewBuilder
    private var lastfmFields: some View {
        Section {
            HStack(spacing: 4) {
                Text(L10n.t("创建 Last.fm 应用即可获取 API Key + Secret"))
                    .font(.caption2).foregroundStyle(.secondary)
                HelpButton(
                    text: L10n.t("在 Last.fm 后台创建应用会同时给你 API Key 和 Secret"),
                    docTitle: L10n.t("前往 Last.fm 申请 →"),
                    docURL: URL(string: "https://www.last.fm/api/account/create")!
                )
            }
            TextField(L10n.t("Last.fm 用户名"), text: $config.lastfmUser)
            SecretFieldRow("API Key", value: $config.lastfmScrobbleAPIKey)
            SecretFieldRow("Secret", value: $config.lastfmScrobbleSecret, prompt: L10n.t("只用只读功能可以留空"))
            lastfmConnectArea
        } header: {
            Text(L10n.t("账号信息"))
        }

        Section {
            Toggle(L10n.t("同步进 Last.fm"), isOn: Binding(
                get: { features.lastfmMirrorScrobble },
                set: { newValue in
                    toggleGuarded(newValue, sameCardHint: config.lastfmMirrorMissingHint()) { v in
                        features.lastfmMirrorScrobble = v; Task { await features.save() }
                    }
                }
            ))
        } header: {
            Text(L10n.t("写入记录"))
        } footer: {
            Text(L10n.t("开启后会把播放记录同步写入 Last.fm"))
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
                Button(L10n.t("连接 Last.fm 账号")) { lastfmConnect.start(apiKey: config.lastfmScrobbleAPIKey) }
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
                        config.lastfmScrobbleSessionKey = ""
                        config.lastfmScrobbleUsername = ""
                        Task { await config.save() }
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
                Text(L10n.t("已在浏览器打开 Last.fm 授权页面。请在浏览器里点击「Yes, allow access」完成授权——授权完会自动跳回 Lyrimuse 继续；如果浏览器没有自动跳转，也可以回来手动点下面的按钮"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L10n.t("我已完成授权，继续")) {
                    lastfmConnect.confirmBrowserAuth(apiKey: config.lastfmScrobbleAPIKey, secret: config.lastfmScrobbleSecret)
                }
                .buttonStyle(.borderedProminent)
                HStack(spacing: 12) {
                    Button(L10n.t("重新打开授权页面")) { lastfmConnect.reopenBrowserAuth(apiKey: config.lastfmScrobbleAPIKey) }
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
        Section {
            Picker(selection: $config.notificationPlatform) {
                ForEach(NotificationPlatform.allCases) { platform in
                    Text(platform.displayName).tag(platform)
                }
            } label: {
                HStack(spacing: 4) {
                    Text(L10n.t("通知平台"))
                    HelpButton(
                        text: config.notificationPlatform.setupGuide,
                        docTitle: L10n.t("查看官方文档 →"),
                        docURL: config.notificationPlatform.setupDocURL
                    )
                }
            }
            .pickerStyle(.menu)

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
        } header: {
            Text(L10n.t("推送设置"))
        }

        Section {
            // 数据源可选——Last.fm 的周榜接口(user.getWeeklyTrackChart/getWeeklyArtistChart)
            // 其实接受任意 from/to,不是只认官方周边界,因此两个 cadence 都能自己选数据源。
            // Picker 挂在对应开关打开之后(参照"灵动岛风格"只在"灵动岛歌词"开着才出现的
            // 既有模式)——没开这个提醒,选哪个数据源无所谓;两个 Picker 各给了区分度更高
            // 的标签("每周数据源"/"每日数据源"而不是都叫"数据源"),避免分不清哪个 Picker
            // 归哪个开关管。Picker 显示的是"这次实际会用哪个"(未手动选时是
            // resolvedDigestSource 判定出的默认值),一旦手动选过就变成显式 persist 的偏好。
            Toggle(L10n.t("每周听歌小结"), isOn: Binding(
                get: { features.weeklyDigest },
                set: { newValue in
                    let source = resolvedDigestSource(preference: features.weeklyDigestSource)
                    toggleGuarded(newValue,
                        sameCardHint: config.pushMissingHint(),
                        crossCard: digestCrossCard(source: source)
                    ) { v in features.weeklyDigest = v; Task { await features.save() } }
                }
            ))
            if features.weeklyDigest {
                Picker(L10n.t("每周数据源"), selection: Binding(
                    get: { resolvedDigestSource(preference: features.weeklyDigestSource) },
                    set: { features.weeklyDigestSource = $0; Task { await features.save() } }
                )) {
                    Text("Last.fm").tag("lastfm")
                    Text("ListenBrainz").tag("listenbrainz")
                }
                .pickerStyle(.menu)
            }

            Toggle(L10n.t("每日听歌报告"), isOn: Binding(
                get: { features.dailyDigest },
                set: { newValue in
                    let source = resolvedDigestSource(preference: features.dailyDigestSource)
                    toggleGuarded(newValue,
                        sameCardHint: config.pushMissingHint(),
                        crossCard: digestCrossCard(source: source)
                    ) { v in features.dailyDigest = v; Task { await features.save() } }
                }
            ))
            if features.dailyDigest {
                Picker(L10n.t("每日数据源"), selection: Binding(
                    get: { resolvedDigestSource(preference: features.dailyDigestSource) },
                    set: { features.dailyDigestSource = $0; Task { await features.save() } }
                )) {
                    Text("Last.fm").tag("lastfm")
                    Text("ListenBrainz").tag("listenbrainz")
                }
                .pickerStyle(.menu)
            }
        } header: {
            Text(L10n.t("提醒开关"))
        } footer: {
            Text(L10n.t("数据源留空时自动判定：两个账号都配了优先用 Last.fm，只配了一个就用那个。每日听歌报告在本地时间晚上 10 点之后、当天第一次检查时推送，内容是当天播放次数、累计时长（数据源是 ListenBrainz 时才有），以及听得最多的几首歌"))
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
