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
        DestinationStatusLabel(status: self)
    }
}

// 侧边栏这一行被选中时系统会铺一层高亮蓝底——固定的 .orange/.green/.red 不会跟着换色,
// 深绿/深红字压在亮蓝底上对比度很差、看不清(实测反馈坐实)。用 backgroundProminence
// 这个环境值(选中+聚焦时是 .increased)判断当前是否铺着高亮底,是就退回 .primary(会
// 跟随高亮底自动换成清晰的颜色),不铺高亮底时才用状态本身的颜色,保持"一眼扫图标颜色
// 分辨状态"这个设计意图不变。
private struct DestinationStatusLabel: View {
    let status: DestinationStatus
    @Environment(\.backgroundProminence) private var backgroundProminence

    private var dimmed: Bool { backgroundProminence == .increased }

    var body: some View {
        // 真机实测坐实的 bug:这个 Label 嵌在 SettingsView 那层真侧边栏 List 里
        // (AccountSidebarRow 用到它),手动切换语言后,"歌手/歌名"这类直接
        // Text(destination.title) 的内容会立刻跟着换,但这个由自由函数
        // (destinationStatus(for:))层层包出来的状态文字却停留在切换前的语言、
        // 点进详情页(AccountLinkingTab,选中态变化触发这块内容整体重新构造)才会
        // 变过来——这是 SwiftUI List 在 macOS(NSTableView 桥接)下已知的一类行复用/
        // 局部刷新缺陷,不是这里的业务逻辑读错了值(L10n.t 本身每次都读的是当下最新的
        // 语言)。用 .id(L10n.current) 把这块内容的"身份"跟当前实际生效的语言绑死——
        // 语言一变,SwiftUI 就把它当成一个全新的 View 整个重新构造,而不是尝试局部
        // 复用/diff 出了问题的那份内容,绕开这个复用缺陷而不是指望"修" List 内部实现。
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
        .id(L10n.current)
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

    // 2026-07-16:后两个改名——ListenBrainz/Last.fm 是专有名词不动;"网页状态同步"→
    // "网页推送","故障与周报提醒"→"推送提醒"。后者尤其是在修正一个过时的名字:上一步
    // 把"每周听歌小结"开关挪进 Last.fm 卡片的"统计与提醒"小节之后,这张卡本身已经不再
    // 直接管"周报"这件事,只剩 Bark 推送地址+故障告警开关,继续叫"周报提醒"名不副实。
    var title: String {
        switch self {
        case .listenBrainz: return "ListenBrainz"
        case .lastfm: return "Last.fm"
        case .stateRelay: return L10n.t("网页推送")
        case .bark: return L10n.t("推送提醒")
        }
    }

    var icon: (name: String, tint: Color) {
        switch self {
        case .listenBrainz: return ("waveform.circle.fill", .orange)
        case .lastfm: return ("arrow.triangle.2.circlepath", .pink)
        case .stateRelay: return ("dot.radiowaves.left.and.right", .blue)
        case .bark: return ("bell.badge.fill", .red)
        }
    }
}

// 抽成自由函数而不是 AccountLinkingTab 的实例方法——侧边栏行(AccountSidebarRow)和
// 详情页头部(AccountLinkingTab.detailHeader)两处都要算同一个目的地的状态,不想维护
// 两份逻辑。两边各自持有同一对共享单例(ConfigStore.shared/LastfmConnectController.shared)
// 的 @ObservedObject 引用,传进来算,不做隐式全局访问。
@MainActor
func destinationStatus(for destination: AccountDestination, config: ConfigStore, lastfmConnect: LastfmConnectController) -> DestinationStatus {
    switch destination {
    case .listenBrainz:
        // 2026-07-17 起 collector 不再强制要求这个账号(只想用悬浮歌词可以完全不配)，
        // 未配置不再是"硬性错误"，改用跟其它卡片一致的橙色"缺凭据"提示。
        return config.isListenBrainzConfigured
            ? .active(config.listenbrainzUser.isEmpty ? nil : String(format: L10n.t("已连接为 @%@"), config.listenbrainzUser))
            : .missingCreds(L10n.t("未配置（可选）"))
    case .stateRelay:
        if let hint = config.stateRelayMissingHint() { return .missingCreds(hint) }
        return .active()
    case .lastfm:
        if case .failed(let msg) = lastfmConnect.state { return .error(msg) }
        let bridgeOK = config.lastfmBridgeMissingHint() == nil
        let mirrorOK = config.lastfmMirrorMissingHint() == nil
        switch (bridgeOK, mirrorOK) {
        case (true, true): return .active(L10n.t("桥接+镜像已配置"))
        case (true, false): return .active(L10n.t("桥接已配置"))
        case (false, true): return .active(L10n.t("镜像已配置"))
        case (false, false): return .missingCreds(L10n.t("未配置"))
        }
    case .bark:
        if let hint = config.pushMissingHint() { return .missingCreds(hint) }
        return .active(config.notificationPlatform.displayName)
    }
}

// "账号连接"侧边栏的一行(图标+名称+状态徽标)——单独抽成一个 View,而不是内嵌在
// SettingsView 里当作普通 Label,因为它需要订阅 ConfigStore/LastfmConnectController
// 才能实时刷新状态徽标(比如保存后从"还没有配置"变成"已连接")。这一行现在跟"播放"
// "外观"等其它分类平级放在 SettingsView 外层同一个 List 的 Section("账号连接")里——
// 全窗口自始至终只有一层真正的侧边栏 List,不再是"整个设置窗口的分类侧边栏"之外又
// 单独搭一层"账号连接内部专属的侧边栏"。
//
// 这个"只留一层真侧边栏"的结构调整,是趟坑趟出来的:最早"账号连接"内部自己套了一层
// NavigationSplitView,导致两层 NavigationSplitView 叠在同一个窗口里,macOS 在侧边栏/
// 工具栏这层窗口级 chrome 上打架(外层侧边栏整个不渲染、内层列表行错位重叠);改成手搭
// 的 HStack+List(.listStyle(.sidebar)) 规避了那个冲突,但这种"看起来像侧边栏、实际
// 不是 NavigationSplitView 真正分栏列"的 List,拿不到 AppKit 只对"真正的侧边栏列"做的
// 窗口圆角遮罩处理,导致侧边栏背景材质在窗口左下角露出一块方形黑影(实测截图坐实)。
// 两次踩坑指向同一个结论:伪造第二层"看起来像侧边栏"的容器,不管是嵌套 NavigationSplitView
// 还是手搭 HStack,都会跟 AppKit 只按"一个真正侧边栏列"设计的窗口级 chrome/遮罩打架。
// 唯一稳妥的解法是彻底拍平,让全窗口只有一层真正的 NavigationSplitView 侧边栏,把"账号"
// 这一级也变成这层真侧边栏里的普通行(用 Section 分组),而不是另起一层容器。
struct AccountSidebarRow: View {
    let destination: AccountDestination

    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var lastfmConnect = LastfmConnectController.shared
    // 只为了让这一行在手动切换语言时重新渲染——这个 View 本身已经嵌在 SettingsView
    // 的 List 里,父视图理论上会因为语言变化重新构造子行,这里独立再观察一份是保险,
    // 不依赖 ForEach 复用行为的具体细节。
    @ObservedObject private var languageSettings = AppSettings.shared

    var body: some View {
        let iconInfo = destination.icon
        return Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(destination.title)
                destinationStatus(for: destination, config: config, lastfmConnect: lastfmConnect)
                    .label.font(.caption2)
            }
        } icon: {
            iconBadge(iconInfo.name, tint: iconInfo.tint)
        }
        .padding(.vertical, 2)
    }
}

// 账号连接:回答"配好了没有"这个问题;每张账号卡片里也带对应的"要不要用这个功能"
// 开关(比如"推送状态到网页/徽章"),但那是各个账号自己的开关,不是一个笼统的"功能
// 开关"分类——不依赖任何账号的纯行为开关(比如封面/主色/平台跳转链接)已经从可关闭
// 设置项直接删掉、改成无条件执行,不再需要一个单独的地方安放它们(2026-07-17)。
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

    // 2026-07-18:开关校验从"预先灰置+旁边常驻小字"改成"打开时才校验,没满足就弹窗"——
    // 用户反馈静态提示文字太多、想要的是"点了才提醒缺什么+能直接跳转"。missingPrereqAlert
    // 非 nil 就弹一次;body 上只挂一个 .alert,所有开关共用同一套。
    private struct MissingPrereqAlert: Identifiable {
        let id = UUID()
        let message: String
        let jumpTarget: AccountDestination?
    }
    @State private var missingPrereqAlert: MissingPrereqAlert?

    private var status: DestinationStatus {
        destinationStatus(for: destination, config: config, lastfmConnect: lastfmConnect)
    }

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
            saveBar
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
            missingPrereqAlert = MissingPrereqAlert(message: String(format: L10n.t("请先在这张卡上填好：%@。"), sameCardHint), jumpTarget: nil)
            return
        }
        if let crossCard, let hint = crossCard.hint {
            missingPrereqAlert = MissingPrereqAlert(message: String(format: L10n.t("需要先配置「%@」（%@）。"), crossCard.target.title, hint), jumpTarget: crossCard.target)
            return
        }
        apply(true)
    }

    // 2026-07-17:视觉重设计——原来每张卡片手工用 Divider() 分割一整块 Form/Section,
    // 观感上跟另外四个纯设置 tab"每个话题一个真正 Section"的原生分组卡片完全不同,是
    // 这个窗口里视觉密度最高、最不像原生 macOS 设置的部分。现在改成每张卡片按话题拆成
    // 真正的具名 Section(见下面 fields 里各张卡片的实现)。每张卡片最上面那句"整体
    // 介绍"文案(描述整张卡是干什么的,不是某一个 Section 的)挪到这里,放在 detailHeader
    // 和 Form 之间,不塞进任何一个 Section 的 header/footer——footer 只能放纯文字且
    // 只描述那一个 Section,不适合放"整张卡"级别的介绍。ListenBrainz 没有这一段,因为
    // 它原来的介绍句已经原封不动变成了"账户信息" Section 的 footer(那句本来就是
    // 无条件常驻显示的静态文案,够格用 footer,是四张卡片里唯一一个)。
    @ViewBuilder
    private var cardIntro: some View {
        switch destination {
        case .listenBrainz:
            EmptyView()
        case .stateRelay:
            Text(L10n.t("用来把当前播放状态推送到网页小组件和状态徽章。"))
                .font(.caption).foregroundStyle(.secondary)
        case .lastfm:
            Text(L10n.t("这台 Mac 用同一个 Last.fm 账号做两件事：读取 iPhone 上的播放记录、把 Mac 上的播放写回 Last.fm。"))
                .font(.caption).foregroundStyle(.secondary)
        case .bark:
            Text(L10n.t("用来接收「每周听歌小结」推送。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var detailHeader: some View {
        let iconInfo = destination.icon
        return HStack(spacing: 12) {
            iconBadge(iconInfo.name, tint: iconInfo.tint, size: 36, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.title).font(.title3.weight(.semibold))
                status.label.font(.caption)
            }
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
            Text(L10n.t("可选，不填不影响悬浮歌词。"))
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
                        text: L10n.t("自己用 Cloudflare Worker + KV 搭建的 state-worker 服务（项目里的 state-worker/ 目录）。不想自建也行：配好「ListenBrainz」也能让网页兜底显示「正在播放」，两者配一个就够。完整从零搭建步骤见 README「从零搭建 state-worker」一节。"),
                        docTitle: L10n.t("打开 README →"),
                        // 仓库 lyrimuse(2026-07-20 起改名,原 desktop-lyrics-suite,再往前原
                        // nowplaying-backend)的 GitHub 网页版(排版好,不是本地 IDE 打开的原始
                        // 文本)——用行号锚点而不是标题锚点,不用去猜 GitHub 对中文/括号标题的
                        // slug 生成规则;这份 README 改动已提交推送,行号跟远端一致。以后这一节
                        // 挪动过要跟着改这两个行号。
                        docURL: URL(string: "https://github.com/Yudaotor/lyrimuse/blob/main/README.md#L198-L220")!
                    )
                }
            }
            SecretFieldRow(L10n.t("访问令牌"), value: $config.stateRelayToken)
        } header: {
            Text(L10n.t("连接信息"))
        } footer: {
            // 2026-07-20:去掉"推送状态到网页/徽章"总开关 + 5 个网页模块子开关——
            // 用户反馈"网页推送本来就是附加功能，只要填了地址就该默认全推，不需要
            // 逐项配置"。这两个字段填好本身就是"要不要推"这件事唯一的开关，不再需要
            // 额外一层可以打开也可以关闭的开关摞在上面；网页那边(state-worker/网页
            // 前端)看到 modules 配置缺失本来就按"全部启用"兜底，语义完全对得上。
            Text(L10n.t("填好这两项就会自动推送到网页，历史播放、留言墙等展示模块默认全部开启。"))
        }
    }

    // MARK: - Last.fm(合并 iPhone 桥接 + Mac 镜像——都是同一个 Last.fm 账号)

    @ViewBuilder
    private var lastfmFields: some View {
        // 原来外面套了一层 GroupBox("账号授权")——现在 Section 标题本身已经是"账号授权",
        // 再套一层同名 GroupBox 是双重装饰,直接删掉、内容平移进 Section 正文。
        //
        // 2026-07-20:这张卡原来在这下面还有一个"历史统计"Section,专门说明"配好这张卡
        // +「网页推送」会自动统计 Top10 歌手推送到网页"——用户反馈"这一块全部去掉",
        // 删掉了(连同上一轮把手动开关换成的这句纯说明文字一起删,不留任何痕迹)。
        //
        // 同一天:这个 Section 从原来排在最后挪到了整个 tab 最顶端——用户反馈应该放在
        // 最前面。这也更贴近实际依赖关系:下面"Mac 播放镜像"的"同步进 Last.fm"真正
        // 生效靠的是这里连接得到的 session key,不是"Scrobble API Key/Secret"这两个
        // 字段本身(那两个字段只是发起授权流程需要的参数,填好不代表已经走完授权),放在
        // 最前面更能体现"这是基础前提"而不是排在最后的一个附属细节。
        Section {
            lastfmConnectArea
        } header: {
            Text(L10n.t("账号授权"))
        }

        Section {
            HStack(spacing: 4) {
                Text(L10n.t("在 Last.fm 官网申请一个 API Key 就够用（这是只读场景，不需要 Secret）。"))
                    .font(.caption2).foregroundStyle(.secondary)
                HelpButton(
                    text: L10n.t("在 Last.fm 官网申请一个 API Key 就够用（这是只读场景，不需要 Secret）。"),
                    docTitle: L10n.t("前往 Last.fm 申请 →"),
                    docURL: URL(string: "https://www.last.fm/api/account/create")!
                )
            }
            TextField(L10n.t("Last.fm 用户名"), text: $config.lastfmUser)
            SecretFieldRow("API Key", value: $config.lastfmAPIKey, prompt: L10n.t("在 last.fm/api/account/create 申请"))
            Toggle(L10n.t("桥接回 ListenBrainz"), isOn: Binding(
                get: { features.lastfmBridge },
                set: { newValue in
                    toggleGuarded(newValue,
                        sameCardHint: config.lastfmBridgeMissingHint(),
                        crossCard: (hint: config.isListenBrainzConfigured ? nil : L10n.t("未配置"), target: .listenBrainz)
                    ) { v in features.lastfmBridge = v; Task { await features.save() } }
                }
            ))
        } header: {
            Text(L10n.t("iPhone 播放桥接"))
        } footer: {
            // 2026-07-20:用户反馈"'iPhone 播放桥接'这个词含义不明确，加一个说明是具体
            // 干什么事情的"——补一句说清楚具体在干什么(读 iPhone 已经报给 Last.fm 的
            // 播放记录、没在 Mac 播放时拿来当"正在播放"显示),再接上一轮已经改过的那句
            // "转发进 ListenBrainz 需要账号绑定好"。这个开关实际上是整条"读 iPhone
            // 播放"链路唯一的总开关(collector 侧 bridge() 只看 features.LastfmBridge
            // 这一个字段),关掉不只是不转发进 ListenBrainz,连"显示 iPhone 正在播放"
            // 这部分也会一起关掉——这里如实写清楚,不能让人以为只影响 ListenBrainz 那半句。
            //
            // 紧接着用户又指出上一版"用来显示「iPhone 正在播」"这半句容易被误读成跟
            // 歌词模块本身有关——查代码确认:这个"iPhone 正在播"效果只喂给
            // pushRelayState()(collector.go 里两处只读 p.remoteTrack/p.remoteAt 的地方
            // 都在这个函数内),而这台 Mac 本地悬浮歌词的数据源(LocalPlaybackSource)只读
            // 本机 media-control,压根不碰这条 iPhone/Last.fm 链路——歌词模块用不到这个
            // 东西,唯一看得到效果的地方是「网页推送」那张网页,所以这里明确点名"网页推送"
            // 而不是含糊地说"显示",避免让人误以为会影响本机悬浮歌词。
            Text(L10n.t("读取 iPhone 上已经报给 Last.fm 的播放记录：Mac 没有播放时会推给「网页推送」显示「iPhone 正在播」（这台 Mac 本地的悬浮歌词只读本机播放状态，不受影响）；打开下面的开关还会把这些记录转发进 ListenBrainz，统一两台设备的播放历史，这也需要「ListenBrainz」账号绑定好。"))
        }

        Section {
            // 原来这里有两句几乎重复的话(HelpButton 文案 vs 单独一行 caption,说的是同一件
            // 事:跟上面桥接用的不是同一个 API Key),精简合并成一句,不是简单挪位置。
            HStack(spacing: 4) {
                Text(L10n.t("跟上面桥接用的不是同一个 API Key，需要单独申请。"))
                    .font(.caption2).foregroundStyle(.secondary)
                HelpButton(
                    text: L10n.t("需要单独申请一个有写入权限的 API Key + Secret，跟上面桥接用的不是同一个——在 Last.fm 后台创建应用时会同时给你这两项。"),
                    docTitle: L10n.t("前往 Last.fm 申请 →"),
                    docURL: URL(string: "https://www.last.fm/api/account/create")!
                )
            }
            SecretFieldRow("Scrobble API Key", value: $config.lastfmScrobbleAPIKey)
            SecretFieldRow("Scrobble Secret", value: $config.lastfmScrobbleSecret, prompt: L10n.t("在 last.fm/api/account/create 创建应用后可见"))
            Toggle(L10n.t("同步进 Last.fm"), isOn: Binding(
                get: { features.lastfmMirrorScrobble },
                set: { newValue in
                    toggleGuarded(newValue, sameCardHint: config.lastfmMirrorMissingHint()) { v in
                        features.lastfmMirrorScrobble = v; Task { await features.save() }
                    }
                }
            ))
        } header: {
            Text(L10n.t("Mac 播放镜像"))
        } footer: {
            // 2026-07-20:同上一条,"Mac 播放镜像"也补一句说清楚具体在干什么——
            // Apple Music 本身不会自动同步到 Last.fm,这个开关是把这台 Mac 上的播放
            // 单独写回 Last.fm,补上这一份原本没有的记录,跟上面"读 iPhone"方向正好
            // 相反(这里是"写")。
            Text(L10n.t("把这台 Mac 上的播放同步写回 Last.fm——Apple Music 本身不会自动同步，需要这个开关补上这份记录，Last.fm 个人主页才能看到用 Mac 听的这部分。"))
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
                Text(L10n.t("已在浏览器打开 Last.fm 授权页面。请在浏览器里点击「Yes, allow access」完成授权，然后回来点下面的按钮。"))
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
            Label(String(format: L10n.t("已连接：%@"), username), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
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

    // 2026-07-16:从"只支持 Bark 一家"扩成"选平台+填对应 webhook 地址"——用户反馈
    // "现在不是只接入了bark吗，帮我继续接入dingding，企业微信，discord",随后又补了
    // "飞书自定义机器人，Server酱这两个也接入一下"。绝大多数平台都是"群机器人 webhook"
    // 这个模子(一个 URL,POST 一份 JSON),具体 payload 长什么样在 collector/notify.go
    // 里,这边只管选平台+填地址;Server酱是个例外,走表单编码不是 JSON,但那是纯后端
    // 的事,这边 UI 完全不用关心。钉钉/飞书这两个平台的机器人如果开了"加签"安全设置
    // 就还需要额外一个签名密钥(两边算法不同,分开存,见 ConfigStore 的字段注释),用
    // SecretFieldRow 收起来,不占地方——其余平台(Bark/企业微信/Discord/Server酱)都
    // 不需要。
    //
    // 顺带把"每周听歌小结"这个开关从别处搬了过来(用户反馈"既然现在都是模块了，那把
    // 推送每周音乐报告的开关放到推送提醒里面"):这个开关的特点是"通知最终从这里推出去",
    // 放在推送提醒卡片里,跟"网页推送"卡片里的开关道理一样——开关跟着它依赖的账号模块走,
    // 而不是攒在"功能开关"tab 里让人猜"这个开关归哪个账号管"。还依赖 Last.fm 桥接
    // (数据来源),缺了给一个跳转提示。
    // 2026-07-20:"故障告警"整个开关连同底层告警机制一起删掉了——用户反馈"压根不需要
    // 告警故障了"。这不是"默认打开、去掉可配置项"那种简化(跟"网页推送"/"历史 Top10
    // 歌手统计"两处不一样),是彻底不需要这个能力,所以 collector 侧 alerter.ok/fail
    // 这两个方法本身也一并删掉(alerter.push 还留着,weeklyDigestPush 在用)。
    // 实际推的是 Top 歌手+Top 歌曲各三条+总播放次数(见 collector/weekly.go 的
    // weeklyDigestPush),不是十首歌,也别跟另一个不相关的功能"历史 Top10 歌手统计"
    // 搞混——那是网页上的常驻榜单,数据来源不同。这句是整张卡的介绍,在 cardIntro 里。
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
                Text(L10n.t("机器人安全设置选了「加签」才需要填，留空按未加签处理。"))
                    .font(.caption2).foregroundStyle(.secondary)
            } else if config.notificationPlatform == .feishu {
                SecretFieldRow(L10n.t("签名密钥（可选）"), value: $config.feishuSignSecret)
                Text(L10n.t("机器人安全设置开了「签名校验」才需要填，不开也能收到消息。"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.t("推送设置"))
        }

        Section {
            Toggle(L10n.t("每周听歌小结"), isOn: Binding(
                get: { features.weeklyDigest },
                set: { newValue in
                    toggleGuarded(newValue,
                        sameCardHint: config.pushMissingHint(),
                        crossCard: (hint: config.lastfmBridgeMissingHint(), target: .lastfm)
                    ) { v in features.weeklyDigest = v; Task { await features.save() } }
                }
            ))
        } header: {
            Text(L10n.t("提醒开关"))
        }
    }

    // MARK: - 底部保存栏

    private var saveBar: some View {
        HStack {
            saveStatusText
            Spacer()
            Button(isSaving ? "" : (config.isDirty ? L10n.t("保存并应用") : L10n.t("已全部保存"))) {
                Task { await performSave() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!config.isDirty || isSaving)
            .keyboardShortcut(.defaultAction)
            .overlay {
                if isSaving {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L10n.t("正在保存并应用…"))
                    }
                    .font(.callout)
                }
            }
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

    private func performSave() async {
        isSaving = true
        defer { isSaving = false }
        if await config.save() {
            lastSavedAt = Date()
        }
    }
}
