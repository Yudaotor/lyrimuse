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
        switch status {
        case .disabled:
            Label("未启用", systemImage: "circle").foregroundStyle(.secondary)
        case .missingCreds(let hint):
            Label(hint, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(dimmed ? Color.primary : Color.orange)
        case .active(let detail):
            Label(detail ?? "正在生效", systemImage: "checkmark.circle.fill")
                .foregroundStyle(dimmed ? Color.primary : Color.green)
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
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
                    Button("完成") { isEditing = false }
                        .buttonStyle(.link)
                }
            }
        } else {
            HStack {
                Text(label)
                Spacer()
                Label("已设置", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
                Button("更改") { isEditing = true }
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
        case .stateRelay: return "网页推送"
        case .bark: return "推送提醒"
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
        return config.isListenBrainzConfigured
            ? .active(config.listenbrainzUser.isEmpty ? nil : "已连接为 @\(config.listenbrainzUser)")
            : .error("未配置")
    case .stateRelay:
        if let hint = config.stateRelayMissingHint() { return .missingCreds(hint) }
        return .active()
    case .lastfm:
        if case .failed(let msg) = lastfmConnect.state { return .error(msg) }
        let bridgeOK = config.lastfmBridgeMissingHint() == nil
        let mirrorOK = config.lastfmMirrorMissingHint() == nil
        switch (bridgeOK, mirrorOK) {
        case (true, true): return .active("桥接+镜像已配置")
        case (true, false): return .active("桥接已配置")
        case (false, true): return .active("镜像已配置")
        case (false, false): return .missingCreds("未配置")
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

    @State private var isSaving = false
    @State private var lastSavedAt: Date?

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
            Text("用来把当前播放状态推送到网页小组件和状态徽章。")
                .font(.caption).foregroundStyle(.secondary)
        case .lastfm:
            Text("这台 Mac 用同一个 Last.fm 账号做两件事：读取 iPhone 上的播放记录、把 Mac 上的播放写回 Last.fm。")
                .font(.caption).foregroundStyle(.secondary)
        case .bark:
            Text("用来接收两类推送：「故障告警」和「每周听歌小结」。")
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
            Spacer()
            if destination == .listenBrainz {
                Text("必需")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(.secondary)
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
            SecretFieldRow("账户 Token", value: $config.listenbrainzToken)
            Link("在 ListenBrainz 网站获取 Token →", destination: URL(string: "https://listenbrainz.org/settings/")!)
                .font(.caption)
            TextField("用户名（选填，用于界面显示）", text: $config.listenbrainzUser)
        } header: {
            Text("账户信息")
        } footer: {
            Text("这是采集器提交播放记录的唯一账号，必须填写才能启动。")
        }
    }

    // MARK: - 状态中继

    @ViewBuilder
    private var stateRelayFields: some View {
        Section {
            TextField(text: $config.stateRelayURL, prompt: Text("例如 https://yourdomain.com/api/state")) {
                HStack(spacing: 4) {
                    Text("同步服务地址")
                    HelpButton(
                        text: "这是你自己用 Cloudflare Worker + KV 搭建的 state-worker 服务（项目里的 state-worker/ 目录），不是第三方产品——网页版靠它读取实时播放状态。完整从零搭建步骤（建 Cloudflare 账号/KV/自定义域名/secret）见 README「从零搭建 state-worker」一节。",
                        docTitle: "打开 README →",
                        // 私有仓库 desktop-lyrics-suite(2026-07-17 起改名,原 nowplaying-backend)
                        // 的 GitHub 网页版(排版好,不是本地 IDE 打开的原始文本)——用行号锚点而不是
                        // 标题锚点,不用去猜 GitHub 对中文/括号标题的 slug 生成规则;这份 README
                        // 改动已提交推送,行号跟远端一致。以后这一节挪动过要跟着改这两个行号。
                        docURL: URL(string: "https://github.com/Yudaotor/desktop-lyrics-suite/blob/main/README.md#L144-L166")!
                    )
                }
            }
            SecretFieldRow("访问令牌", value: $config.stateRelayToken)
        } header: {
            Text("连接信息")
        }

        Section {
            HStack(spacing: 4) {
                Text("默认全部开启。").font(.caption2).foregroundStyle(.secondary)
                HelpButton(text: "控制网页上显示哪些模块，默认全部开启。")
            }

            Toggle("推送状态到网页/徽章", isOn: Binding(
                get: { features.stateRelay },
                set: { features.stateRelay = $0; Task { await features.save() } }
            ))
            .disabled(config.stateRelayMissingHint() != nil)
            if config.stateRelayMissingHint() != nil {
                Text("填好上面的地址和令牌、点下面「保存并应用」后才能开启。")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Toggle("最近播放历史", isOn: Binding(
                get: { features.webShowHistory },
                set: { features.webShowHistory = $0; Task { await features.save() } }
            ))
            .disabled(!features.stateRelay)

            Toggle("留言墙", isOn: Binding(
                get: { features.webShowComments },
                set: { features.webShowComments = $0; Task { await features.save() } }
            ))
            .disabled(!features.stateRelay)

            Toggle("点赞", isOn: Binding(
                get: { features.webShowReactions },
                set: { features.webShowReactions = $0; Task { await features.save() } }
            ))
            .disabled(!features.stateRelay)

            Toggle("访客计数", isOn: Binding(
                get: { features.webShowVisitorCount },
                set: { features.webShowVisitorCount = $0; Task { await features.save() } }
            ))
            .disabled(!features.stateRelay)

            Toggle("历史 Top10 歌手", isOn: Binding(
                get: { features.webShowTopArtists },
                set: { features.webShowTopArtists = $0; Task { await features.save() } }
            ))
            .disabled(!features.stateRelay)
            Text("展示效果还依赖「Last.fm」卡片「历史统计」小节里的「历史 Top10 歌手统计」已开启且有数据，这里只是单独控制网页上要不要显示这个模块。")
                .font(.caption2).foregroundStyle(.secondary)

            if !features.stateRelay {
                Text("先开启上面的「推送状态到网页/徽章」才能设置这些模块。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } header: {
            Text("网页展示模块")
        }
    }

    // MARK: - Last.fm(合并 iPhone 桥接 + Mac 镜像——都是同一个 Last.fm 账号)

    @ViewBuilder
    private var lastfmFields: some View {
        Section {
            HStack(spacing: 4) {
                Text("在 Last.fm 官网申请一个 API Key 就够用（这是只读场景，不需要 Secret）。")
                    .font(.caption2).foregroundStyle(.secondary)
                HelpButton(
                    text: "在 Last.fm 官网申请一个 API Key 就够用（这是只读场景，不需要 Secret）。",
                    docTitle: "前往 Last.fm 申请 →",
                    docURL: URL(string: "https://www.last.fm/api/account/create")!
                )
            }
            TextField("Last.fm 用户名", text: $config.lastfmUser)
            SecretFieldRow("API Key", value: $config.lastfmAPIKey, prompt: "在 last.fm/api/account/create 申请")
            Toggle("桥接回 ListenBrainz", isOn: Binding(
                get: { features.lastfmBridge },
                set: { features.lastfmBridge = $0; Task { await features.save() } }
            ))
            .disabled(config.lastfmBridgeMissingHint() != nil)
        } header: {
            Text("iPhone 播放桥接")
        }

        Section {
            // 原来这里有两句几乎重复的话(HelpButton 文案 vs 单独一行 caption,说的是同一件
            // 事:跟上面桥接用的不是同一个 API Key),精简合并成一句,不是简单挪位置。
            HStack(spacing: 4) {
                Text("跟上面桥接用的不是同一个 API Key，需要单独申请。")
                    .font(.caption2).foregroundStyle(.secondary)
                HelpButton(
                    text: "需要单独申请一个有写入权限的 API Key + Secret，跟上面桥接用的不是同一个——在 Last.fm 后台创建应用时会同时给你这两项。",
                    docTitle: "前往 Last.fm 申请 →",
                    docURL: URL(string: "https://www.last.fm/api/account/create")!
                )
            }
            SecretFieldRow("Scrobble API Key", value: $config.lastfmScrobbleAPIKey)
            SecretFieldRow("Scrobble Secret", value: $config.lastfmScrobbleSecret, prompt: "在 last.fm/api/account/create 创建应用后可见")
            Toggle("同步进 Last.fm", isOn: Binding(
                get: { features.lastfmMirrorScrobble },
                set: { features.lastfmMirrorScrobble = $0; Task { await features.save() } }
            ))
            .disabled(config.lastfmMirrorMissingHint() != nil)
        } header: {
            Text("Mac 播放镜像")
        }

        // 原来外面套了一层 GroupBox("账号授权")——现在 Section 标题本身已经是"账号授权",
        // 再套一层同名 GroupBox 是双重装饰,直接删掉、内容平移进 Section 正文。
        Section {
            lastfmConnectArea
        } header: {
            Text("账号授权")
        }

        Section {
            Toggle("历史 Top10 歌手统计", isOn: Binding(
                get: { features.topArtistsDigest },
                set: { features.topArtistsDigest = $0; Task { await features.save() } }
            ))
            .disabled(config.lastfmBridgeMissingHint() != nil || config.stateRelayMissingHint() != nil)
            if config.lastfmBridgeMissingHint() == nil {
                accountHintRow(config.stateRelayMissingHint(), target: .stateRelay)
            }
        } header: {
            Text("历史统计")
        } footer: {
            Text("基于 iPhone 桥接读到的播放记录，展示在网页上，还需要「网页推送」配好。")
        }
    }

    // 有 hint 就说明依赖的另一个账号还没配好,点击直接跳到那个账号。账号名字直接读
    // target.title,不再单独传一份字符串——
    // 避免以后账号改名时这里的硬编码文案忘了跟着改(名字只有一个来源)。
    @ViewBuilder
    private func accountHintRow(_ hint: String?, target: AccountDestination) -> some View {
        if let hint {
            Button {
                onJumpToAccount(target)
            } label: {
                Label("还需要配置「\(target.title)」（\(hint)）→", systemImage: "arrow.right.circle")
            }
            .buttonStyle(.link)
            .font(.caption2)
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
                Button("连接 Last.fm 账号") { lastfmConnect.start(apiKey: config.lastfmScrobbleAPIKey) }
                    .buttonStyle(.borderedProminent)
            } else {
                HStack {
                    Label(
                        config.lastfmScrobbleUsername.isEmpty ? "已连接 Last.fm 账号" : "已连接：\(config.lastfmScrobbleUsername)",
                        systemImage: "checkmark.seal.fill"
                    ).foregroundStyle(.green)
                    Spacer()
                    Button("断开") {
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
                Text("正在获取授权令牌…").font(.caption)
            }
        case .waitingForBrowserAuth:
            stepDots(current: 2)
            VStack(alignment: .leading, spacing: 6) {
                Text("已在浏览器打开 Last.fm 授权页面。请在浏览器里点击「Yes, allow access」完成授权，然后回来点下面的按钮。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("我已完成授权，继续") {
                    lastfmConnect.confirmBrowserAuth(apiKey: config.lastfmScrobbleAPIKey, secret: config.lastfmScrobbleSecret)
                }
                .buttonStyle(.borderedProminent)
                HStack(spacing: 12) {
                    Button("重新打开授权页面") { lastfmConnect.reopenBrowserAuth(apiKey: config.lastfmScrobbleAPIKey) }
                        .buttonStyle(.link)
                    Button("取消") { lastfmConnect.reset() }
                        .buttonStyle(.link).foregroundStyle(.secondary)
                }
            }
        case .exchanging:
            stepDots(current: 3)
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在确认授权，即将完成…").font(.caption)
            }
        case .success(let username):
            Label("已连接：\(username)", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                Button("重试") { lastfmConnect.reset() }
                    .buttonStyle(.link)
            }
        }
    }

    private func stepDots(current: Int) -> some View {
        HStack(spacing: 4) {
            stepDot(filled: current >= 1, label: "① 填写密钥")
            stepLine(active: current >= 2)
            stepDot(filled: current >= 2, label: "② 浏览器授权")
            stepLine(active: current >= 3)
            stepDot(filled: current >= 3, label: "③ 完成连接")
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
    // 顺带把"故障告警"和"每周听歌小结"这两个开关从别处搬了过来(用户反馈"既然现在都是
    // 模块了，那把这个以及推送每周音乐报告的开关放到推送提醒里面"):这两个开关的共同点
    // 是"通知最终从这里推出去",放在推送提醒卡片里,跟"网页推送"卡片里的开关道理一样——
    // 开关跟着它依赖的账号模块走,而不是攒在"功能开关"tab 里让人猜"这个开关归哪个账号管"。
    // 每周听歌小结还依赖 Last.fm 桥接(数据来源),缺了给一个跳转提示。
    // 原来写的是"「后台出故障了」和「本周最常听的十首歌」",后半句不准确:每周听歌小结
    // 实际推的是 Top 歌手+Top 歌曲各三条+总播放次数(见 collector/weekly.go 的
    // weeklyDigestPush),不是十首歌,也别跟另一个不相关的功能"历史 Top10 歌手统计"
    // 搞混——那是网页上的常驻榜单,数据来源不同。这里直接用下面两个开关的原名,不重新
    // 描述内容,避免复述跟实际不一致。这句是整张卡的介绍,在 cardIntro 里。
    @ViewBuilder
    private var barkFields: some View {
        Section {
            Picker(selection: $config.notificationPlatform) {
                ForEach(NotificationPlatform.allCases) { platform in
                    Text(platform.displayName).tag(platform)
                }
            } label: {
                HStack(spacing: 4) {
                    Text("通知平台")
                    HelpButton(
                        text: config.notificationPlatform.setupGuide,
                        docTitle: "查看官方文档 →",
                        docURL: config.notificationPlatform.setupDocURL
                    )
                }
            }
            .pickerStyle(.menu)

            TextField(
                "Webhook 地址", text: $config.notificationWebhookURL,
                prompt: Text(config.notificationPlatform.urlPlaceholder)
            )

            if config.notificationPlatform == .dingtalk {
                SecretFieldRow("加签密钥（可选）", value: $config.dingtalkSignSecret)
                Text("机器人安全设置选了「加签」才需要填，留空按未加签处理。")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if config.notificationPlatform == .feishu {
                SecretFieldRow("签名密钥（可选）", value: $config.feishuSignSecret)
                Text("机器人安全设置开了「签名校验」才需要填，不开也能收到消息。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } header: {
            Text("推送设置")
        }

        Section {
            Toggle("故障告警", isOn: Binding(
                get: { features.barkAlerts },
                set: { features.barkAlerts = $0; Task { await features.save() } }
            ))
            .disabled(config.pushMissingHint() != nil)

            Toggle("每周听歌小结", isOn: Binding(
                get: { features.weeklyDigest },
                set: { features.weeklyDigest = $0; Task { await features.save() } }
            ))
            .disabled(config.pushMissingHint() != nil || config.lastfmBridgeMissingHint() != nil)
            if config.pushMissingHint() == nil {
                accountHintRow(config.lastfmBridgeMissingHint(), target: .lastfm)
            }
        } header: {
            Text("提醒开关")
        }
    }

    // MARK: - 底部保存栏

    private var saveBar: some View {
        HStack {
            saveStatusText
            Spacer()
            Button(isSaving ? "" : (config.isDirty ? "保存并应用" : "已全部保存")) {
                Task { await performSave() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!config.isDirty || isSaving)
            .keyboardShortcut(.defaultAction)
            .overlay {
                if isSaving {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在保存并应用…")
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
            Text("上次保存：\(lastSavedAt.formatted(date: .omitted, time: .shortened)) · 采集器已重启")
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
