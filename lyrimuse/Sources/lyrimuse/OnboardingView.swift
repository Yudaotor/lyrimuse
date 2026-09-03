import AppKit
import Combine
import LyrimuseCore
import SwiftUI

// 首次启动的完整引导向导,参照 Jukebox/PlayStatus/Tuneful 这类"一步步走一遍"的
// 体验。每一步的设置项都直接绑定到 AppSettings/FeatureSettingsStore 对应属性、立即
// 生效(跟 SettingsView 里同一批设置项一样,不做"最后统一确认"),向导只是把它们串成
// 一个有引导性的首次体验,不是另一套独立状态。
//
// 步数不再是写死的常量——选了 QQ 音乐时,"Apple Music 自动化权限"这一步整个不需要
// 出现(QQ 音乐走系统级 MediaRemote,没有这个权限的概念),steps 按当前选中的播放器
// 动态算出这一轮实际要走哪几步,下面的按钮/进度点都跟着这份列表走,不再硬编码具体
// 步数下标。首次启动自动出现一次;关窗等于"稍后再说"(下次启动会再问),真正走完最后
// 一步才算引导过。走完之后菜单栏的"重新运行引导…"可以随时再来一遍,这里涉及的每一项
// 也都能在设置里单独找到。
struct OnboardingView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var features = FeatureSettingsStore.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @State private var step = 0
    @State private var automationStatus: MusicAutomationPermissionStatus = .notDetermined
    // 点"请求权限"之后到系统弹窗真正有结果之前的等待状态——见
    // MusicAutomationPermission.requestWithTimeout 注释,这一步不能同步阻塞主线程。
    @State private var isRequestingAutomation = false
    // 等了 8 秒还没有结果(可能系统弹窗被晾在一边没处理,也可能就是那个已知的挂起
    // bug 撞上了)——提前亮出"打开系统设置"这条备选路径,不用死等这次请求。
    @State private var automationRequestTimedOut = false
    // collector 常驻服务是否真的在跑——这一步是"软强制"的必经步骤:锁住下一步按钮,
    // 但仍然可以直接关掉整个引导窗口跳过,不禁用/隐藏关闭按钮。
    @State private var collectorRunning = false
    @State private var isTogglingCollectorService = false
    // 只用来决定要不要提醒"灵动岛/菜单栏歌词得等播起来才看得见"。
    //
    // ⚠️ 刻意**不**写成 `@ObservedObject private var coordinator = PlaybackCoordinator.shared`:
    // 那会订阅整个单例,而它有二十来个 @Published(currentLine/anchor/artworkImage… 每个播放
    // tick 都在变),整个向导会跟着高频重渲染 —— 这个仓库为"@ObservedObject 订阅整个单例"
    // 踩过一次真实的 20Hz 过度重渲染 bug(见"歌词管理"窗口那次)。这里只要 isPlayingNow 这
    // 一个布尔,单独订阅 + removeDuplicates,只有真的开始/停止播放时才动一次。
    // @Published 的 publisher 在订阅那一瞬间就会把当前值发过来,所以初值给 false 不会停在
    // 错的状态上。
    @State private var isPlayingNow = false
    /// 用户"已经走到过"的最远一步 —— 进度点只允许往回跳到这个范围内(往前跳会绕过必需
    /// 步骤那道锁)。跟 `step` 一样是纯会话态,不持久化:引导本身就是一次性的流程,存下来
    /// 只会多一个跟"这次走到哪"对不上的字段。
    @State private var furthestStep = 0
    /// 常驻服务点了「启用」却没起来时,给用户的一句交代。nil = 没有待报告的失败。
    @State private var collectorFailure: String?
    /// 「从应用程序中选择…」挑到一个驱不动的 App 时的错误文案(本体在
    /// `BrowserPairing.chooseFromApplications`,那边只返回文案、不碰视图状态)。
    @State private var browserPickerError: String?

    // 2026-09-03 这一版的三处结构调整:
    //  ① `.language` 整个去掉 —— 语言选择并进 `.welcome`。它原来排在第 6 步,而前 5 步
    //     早就用错的语言讲完了(`L10n.t` 每次调用都重新解析语言,见 L10n.swift 里那条
    //     "不缓存"的注释,所以切换本来就是即时生效的,没有理由放在后面)。并进欢迎页而不是
    //     单独排第 2 步,顺带治掉它"整页只有一个光秃秃 Picker、没有任何说明"这件事。
    //  ② `.collectorService` 改名 `.background` —— 那一步现在同时管"常驻后台服务(必需)"
    //     和"开机自动启动(可选)",两件事回答的是同一个问题:让 Lyrimuse 一直待命。
    //  ③ 新增 `.lyricsExtras`(译文/罗马音)。这是这个 App 对中日韩听众最核心的能力之一,
    //     此前完全埋在设置里,新用户发现不了。
    private enum Step: Equatable {
        case welcome, playerChoice, automation, browserPairing, background,
             displayMode, lyricsExtras, lastfm, done
    }

    /// 上一步勾了「YouTube Music」——它不是 `features.players` 里的一个成员(见
    /// `WebPlatformChoiceCard` 的头注:网页播放器走的是"配对浏览器"那套状态),所以要单独
    /// 记一笔,用来决定后面那一步 `.browserPairing` 要不要出现。
    ///
    /// ⚠️ 刻意**不持久化**这个布尔。真正要落盘的东西是配对本身
    /// (`AppSettings.browserPlatformPairs`),而它在下一步才产生;这里存一个"用户表达过
    /// 意愿"的中间态只会多一个跟真实状态对不上的字段。重新跑引导时按"已经配过没有"重新
    /// 播种(见 `onAppear`),这样格子的选中态如实反映当前配置,不是一个孤立的记忆。
    @State private var wantsBrowserYouTubeMusic = false

    /// 网页平台里目前只对接了 YouTube Music 这一格(Spotify 网页版在设置页那张卡里有,
    /// 但引导页网格里已经有 Spotify **桌面版**那一格了,再摆一个同名的会让人分不清)。
    /// 平台 id 必须跟 `BrowserPositionProbe.supportedPlatforms` 一字不差 —— 对不上不会
    /// 编译报错,只表现成"配对写进去了、探针却永远不认"。
    private static let youTubeMusicPlatformID = "youtubeMusic"

    /// 这一轮要不要问 Apple Music 自动化权限。
    ///
    /// ⚠️ 判据翻过两次,别再收窄回去:
    ///  - 2026-09-03(上午)从 `== [.appleMusic]`(恰好只选了它)放宽成 `contains` —— 同日
    ///    这一步从单选改成多选,而"同时选了 Apple Music 和别的播放器"时那条 AppleScript
    ///    路径照样会被走到,权限仍然需要。
    ///  - 2026-09-03(本次)再补上 `.auto`。`MediaControlClient.refinedAppleMusicSnapshotIfNeeded`
    ///    的第一道 guard 是 `bundleID == PlaybackPlayer.appleMusic.bundleIdentifier`,
    ///    **完全不看 `features.players`** —— 也就是说只要在播的是 Music.app 就会走那条路。
    ///    而 `features.players` 的默认值恰恰是 `[.auto]`(FeatureSettingsStore),于是"保持
    ///    默认、平时听 Apple Music"的人走完整个引导都不会被问过这个权限,然后一直用着一个
    ///    进度不准、播放控制全按不动的版本。
    private var needsAppleMusicAutomation: Bool {
        features.players.contains(.appleMusic) || features.players.contains(.auto)
    }

    // 这份列表本身不 @State,是纯粹从 features.players / wantsBrowserYouTubeMusic 派生出来
    // 的,它们一变下一次读到的就是新列表,不需要额外同步。
    private var steps: [Step] {
        var s: [Step] = [.welcome, .playerChoice]
        if needsAppleMusicAutomation {
            s.append(.automation)
        }
        // 勾了 YouTube Music 才有这一步。按用户要求**不在选完那一刻就跳浏览器选择**,
        // 而是把它排成后面单独一步("选了之后先不进行选择浏览器,引导在后面选择浏览器")
        // —— 选播放器那一步的职责是"你平时用什么听歌",配哪个浏览器是下一个话题。
        if wantsBrowserYouTubeMusic {
            s.append(.browserPairing)
        }
        // lastfm 放在 language 之后、done 之前——跟前面 automation/collectorService
        // 那两个"必需"步骤不同,这一步纯介绍性质、完全可跳过(下一步按钮从不为它禁用,
        // 见 body 里的 .disabled),只是提升 Last.fm 这个已经相当完整的功能被新用户
        // 发现的概率(之前完全没在 Onboarding 里出现过,只能自己摸到设置里折叠着的
        // 入口才会发现)。
        s.append(contentsOf: [.background, .displayMode, .lyricsExtras, .lastfm, .done])
        return s
    }

    /// 当前这一步。**所有地方都必须走这个访问器,不准再写 `steps[step]`**。
    ///
    /// ⚠️ 这是一处真的会崩的越界(2026-09-03 修)。原来的注释论证过"当前安全,因为能让
    /// `steps` 变短的控件全都在 index 1" —— 那句话只在"引导页是唯一宿主"时成立,而
    /// `features.players` 是 `@Published`(FeatureSettingsStore),**设置窗口能同时开着改它**,
    /// 引导页自己的 `.lastfm` 那一步还有个按钮专门去打开设置窗。失效路径:勾了 Apple Music
    /// → 一路走到最后一步 `.done`(index = count-1)→ 打开设置 → 播放器 tab 取消勾选
    /// Apple Music → `steps` 少一项 → body 重算 → `steps[count]` 数组越界,硬崩。
    ///
    /// 两道防线都要有:这个访问器保证**渲染这一刻**不会越界(SwiftUI 重算 body 可能早于
    /// 任何 onChange),下面 `.onChange(of: steps.count)` 负责把 `step` 这个存储值本身拉回
    /// 合法区间(否则"上一步/下一步"的加减法会从一个非法下标继续往下算)。
    /// `steps` 恒定至少 7 项,`count - 1` 不会是负数。
    private var currentStep: Step {
        let list = steps
        return list[min(max(step, 0), list.count - 1)]
    }

    private var isLastStep: Bool { step >= steps.count - 1 }

    /// 「下一步」现在被锁住了没有。
    ///
    /// ⚠️ 2026-09-03 只剩 `.background` 一条。`.automation` 从这里**移出去**了,理由是它的
    /// 前提本身站不住:基础的"在播什么"来自 media-control 通道(collector),自动化权限管的是
    /// 进度精度和整套播放/资料库控制 —— 没有它歌词照样显示。多选之后更明显:勾了
    /// Apple Music + Spotify 的人,被一个只对其中一个播放器有意义的权限挡在原地。
    ///
    /// 2026-08-02 那次把 automation 加进锁里,是为了治"用户误点了不允许还能一路走完、
    /// doneStep 却说一切就绪"。那个病根现在由 `doneStep` 的体检清单如实报告(见那边),
    /// 不需要再靠锁死按钮来兜。
    private var nextIsLocked: Bool { currentStep == .background && !collectorRunning }

    var body: some View {
        VStack(spacing: 0) {
            // ⚠️ 这一层 ScrollView 是**溢出兜底**,不是"让内容可以随便长"(2026-09-03 加)。
            //
            // 窗口固定 480×420、不可拖拽(App.swift 的 .windowResizability(.contentSize)),
            // 在此之前内容超出就是**静默裁切**:超出的部分既不滚动也不撑大窗口,只会被切掉
            // 或压成省略号,而且在开发机上通常看不出来 —— 最坏情况是英文界面(同一句话普遍
            // 比中文多占一到两行)叠上「辅助功能 → 更大文字」。`.basedOnSize` 让内容装得下
            // 时完全不出现滚动条、也不橡皮筋,观感跟改动前一模一样。
            //
            // 各步骤自己的高度预算(尤其"两条提示互斥"那种)照旧要守 —— 这层只是保证"预算
            // 算错时用户还够得着下面的东西",不是把预算作废。
            ScrollView(.vertical) {
                Group {
                    switch currentStep {
                    case .welcome: welcomeStep
                    case .playerChoice: playerChoiceStep
                    case .automation: automationStep
                    case .browserPairing: browserPairingStep
                    case .background: backgroundStep
                    case .displayMode: displayModeStep
                    case .lyricsExtras: lyricsExtrasStep
                    case .lastfm: lastfmStep
                    case .done: doneStep
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(28)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)

            Divider()

            HStack {
                stepDots
                Spacer()
                // 必需步骤被锁住时的**出口**(2026-09-03)。在此之前"仍然可以直接关掉整个
                // 引导窗口跳过"这句话**只存在于代码注释里** —— 用户点了系统弹窗的「不允许」
                // 之后,界面上只有一个永远灰着的「下一步」,没有任何东西告诉他还能怎么走。
                //
                // 用次要样式(.link)而不是普通按钮:它是逃生口,不该跟「下一步」抢视线。
                // 跳过之后 doneStep 的体检清单会如实标红这一项,`finish()` 也不会把
                // hasCompletedOnboarding 置真(见那边),下次启动还会再问一次。
                if nextIsLocked {
                    Button(L10n.t("暂时跳过")) { goTo(step + 1) }
                        .buttonStyle(.link)
                        .font(.callout)
                }
                if step > 0 {
                    Button(L10n.t("上一步")) { goTo(step - 1) }
                }
                Button(isLastStep ? L10n.t("开始使用") : L10n.t("下一步")) {
                    if isLastStep {
                        finish()
                    } else {
                        goTo(step + 1)
                    }
                }
                .keyboardShortcut(.defaultAction)
                // 判据收在 `nextIsLocked` 里一处(那边记着 automation 为什么被移出去)。
                // 仍然是"软强制":只锁这一个按钮,不禁用/隐藏窗口的关闭按钮,而且旁边现在
                // 有一个显式的「暂时跳过」。
                .disabled(nextIsLocked)
            }
            .padding(16)
        }
        .frame(width: 480, height: 420)
        // 窗口标题跟着界面语言走。App.swift 里 `Window(L10n.t("欢迎使用 Lyrimuse"), id:)`
        // 的那个标题在 scene 构造时**只求值一次**,用户在第一步把语言切成英文之后它还是
        // 中文;`.navigationTitle` 每次重算 body 都会重新应用,正好补上这一处。
        .navigationTitle(L10n.t("欢迎使用 Lyrimuse"))
        // 见 `currentStep` 头注:这一条负责把 `step` 这个**存储值**拉回合法区间(设置窗口
        // 同时开着、改了播放器集合时 steps 会变短)。渲染那一刻的安全由 currentStep 兜。
        .onChange(of: steps.count) { _, newCount in
            if step > newCount - 1 { step = newCount - 1 }
            if furthestStep > newCount - 1 { furthestStep = newCount - 1 }
        }
        // 走到"体检"和"后台服务"这两步时重新读一次真实状态 —— 用户可能刚在系统设置里
        // 给了权限、或者从别处把服务装上了,清单必须反映此刻的事实而不是进门时的快照。
        // 只在这两步做,不是每步都做:`CollectorServiceManager.isRunning` 要起一次
        // `launchctl print` 子进程,没必要在每次翻页都付这个钱。
        .onChange(of: step) { _, _ in
            guard currentStep == .done || currentStep == .background else { return }
            automationStatus = MusicAutomationPermission.check(askIfNeeded: false)
            collectorRunning = CollectorServiceManager.isRunning
        }
        .onAppear {
            automationStatus = MusicAutomationPermission.check(askIfNeeded: false)
            collectorRunning = CollectorServiceManager.isRunning
            // 「YouTube Music」那一格的选中态按**当前真实配置**播种(2026-09-03):已经配过
            // 浏览器的人重跑引导时,那一格该是亮的、后面那一步也该在,而不是让他重新勾一遍。
            // 这也是这个布尔不需要自己持久化的原因(见它的声明处)。
            wantsBrowserYouTubeMusic = BrowserPairing
                .hasAnyPair(platformID: Self.youTubeMusicPlatformID)
        }
        // 用户点"请求权限"之后可能会切到系统设置面板手动处理(尤其是等超时了、
        // 走"打开系统设置"这条备选路径的时候),切回来时重新读一次最新状态——不然
        // 界面会一直卡在切出去之前的旧状态,像是"我明明点了允许,这里怎么还没变"。
        // 顺带清掉 isRequestingAutomation/automationRequestTimedOut:如果已经确定
        // 不再是 notDetermined,就没有理由继续显示"正在等待"这套 UI——不这样做的话,
        // 上面状态文字已经变成"已授权"了,下面却还卡在超时提示/转圈,两处互相矛盾。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            let latest = MusicAutomationPermission.check(askIfNeeded: false)
            automationStatus = latest
            if latest != .notDetermined {
                isRequestingAutomation = false
                automationRequestTimedOut = false
            }
        }
        .onReceive(PlaybackCoordinator.shared.$isPlayingNow.removeDuplicates()) { playing in
            isPlayingNow = playing
        }
        // ⚠️ 这里原来挂着 `.onDisappear { settings.hasCompletedOnboarding = true }`,
        // 也就是"不管走没走完(包括直接点红绿灯关窗)都算引导过了"。2026-08-13 去掉。
        //
        // 那个行为会造成一条不可自愈的死路:常驻服务默认不装,而歌词全部来自 collector
        // 写在磁盘上的缓存(见 LocalPlaybackSource 顶部注释)—— 第一步就关窗的用户,
        // 服务没装、引导又被标记成"已完成"再也不会出现,于是桌面上留着一个永远停在
        // "搜索歌词中…"的悬浮窗,而他没有任何入口把服务装起来。
        //
        // 现在 hasCompletedOnboarding 只由 finish() 置位(= 真的走到最后一步)。关窗
        // 等于"稍后再说",下次启动会再问一次;而已经走完的人可以从菜单栏的
        // "重新运行引导…"随时再来一遍。
        // 见 AuxiliaryWindowActivation 注释——.accessory 策略下临时借一个 Dock 图标。
        .onAppear { AuxiliaryWindowActivation.windowDidAppear() }
        .onDisappear { AuxiliaryWindowActivation.windowDidDisappear() }
    }

    /// 进度指示。2026-09-03 补了三件事:
    ///  ① **一个"第几步/共几步"的数字** —— 步数按所选播放器动态算,最多能到 9 个点,光靠
    ///     数点数不出来自己走到哪了。
    ///  ② **走过的点可以点回去**。只允许回到 `furthestStep` 以内:往前跳会绕过必需步骤
    ///     那道锁(`nextIsLocked`),而 `furthestStep` 只由「下一步」/「暂时跳过」推进,
    ///     这两条路本身是受控的。
    ///  ③ 无障碍:整块合成一个元素并报出"第 N 步,共 M 步",否则旁白读到的是一串无意义的
    ///     圆点。
    private var stepDots: some View {
        HStack(spacing: 8) {
            // ⚠️ 命中区靠**外扩一层等大的 frame**做,不是 `.contentShape(Rectangle().size(…))`。
            // 后者构造的矩形从这个视图的原点(圆点左上角)往右下铺,而不是以圆点为中心 ——
            // 6pt 的点配 14pt 的矩形,命中区整体偏移 4pt 并盖到相邻那个点头上,几个点的
            // 命中区互相重叠之后"点第 N 个却跳到第 N±1 步"。12pt 的居中 frame + spacing 0
            // 之后视觉间距仍是 6pt,跟改动前一模一样,但每个点的命中区互不重叠。
            HStack(spacing: 0) {
                ForEach(0..<steps.count, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                        .onTapGesture { if i <= furthestStep { goTo(i) } }
                }
            }
            Text("\(step + 1) / \(steps.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            format: L10n.t("第 %1$d 步，共 %2$d 步"), step + 1, steps.count))
    }

    // 语言选择并在这一页(2026-09-03),不再是后面单独的一步。`L10n.t` 每次调用都重新解析
    // 语言(见 L10n.swift 里"不缓存"那段),所以在这里一改,**从下一步开始整个向导都是新
    // 语言** —— 而它原来排在第 6 步,前 5 步早就用错的语言讲完了。
    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "text.quote")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text(L10n.t("欢迎使用 Lyrimuse"))
                .font(.title.bold())
            Text(L10n.t("一个贴心的桌面悬浮歌词小工具。接下来用几步简单设置，帮你把它调整成合适的样子——这些选项以后随时可以在设置里再调整"))
                .foregroundStyle(.secondary)
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                Text(L10n.t("界面语言"))
                Spacer(minLength: 12)
                Picker(L10n.t("界面语言"), selection: $settings.appLanguage) {
                    Text(L10n.t("跟随系统")).tag("system")
                    Text(L10n.t("简体中文")).tag("zh-hans")
                    Text(L10n.t("繁體中文")).tag("zh-hant")
                    Text("English").tag("en")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            // 2026-09-03:一句不阻断的告知 + 链接,正文在 README(见 LegalNotices 头注),设置「关于」页
            // 还有同一个入口。刻意**不做**阻断式的「接受」页:引导的原则是介绍性内容不锁下一步,GPL 个人
            // 工具也没有需要用户「接受」的条款 —— 「接受版本号存偏好」那套是分发渠道场景的产物。
            HStack(spacing: 4) {
                Text(L10n.t("继续即表示你已了解"))
                    .foregroundStyle(.secondary)
                Button(L10n.t("使用与版权说明")) { LegalNotices.openUsageNotice() }
                    .buttonStyle(.link)
            }
            .font(.callout)
        }
    }

    private var playerChoiceStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("选择播放器"))
                .font(.title2.bold())
            // 2026-08-25 用户反馈"把支持的播放器都写全"——这句原来漏了酷狗音乐
            // (2026-08-21 才接入,这句文案没跟着补)。"陆续支持中"的提示挪到网格里那张
            // MorePlayersComingCard 卡片上了(用户第一次说"加几个点"时以为是指这句文案
            // 末尾,截图纠正过来——指的是网格空出来那格,见下面 MorePlayersComingCard)。
            Text(L10n.t("Lyrimuse 支持 Apple Music、QQ 音乐、网易云音乐、酷狗音乐、Spotify，浏览器里的 YouTube Music 也可以，还可以交给「自动识别」——平时用哪些就都勾上，随时可以在设置里改"))
                .foregroundStyle(.secondary)
            // 原来是一个纯文字下拉菜单,认不出图标、也看不出到底支持哪几家。换成一排
            // 图标卡片,理由和取图标的办法见 PlayerChoiceCard 类头注。三列排 8 格:五个
            // 具体播放器 + YouTube Music + 自动识别 + 一张 MorePlayersComingCard 占位,
            // 正好铺满 3 行——不用横向滚动、也不会显得稀疏。
            // (2026-09-03 之前是 6 格 + 占位共 7 格;加了 YouTube Music 那一格之后是 8 格,
            //  第三行仍然是"两张真卡 + 一格空",没有多出半空的一行。)
            //
            // 顺序不用 PlaybackPlayer.allCases 的声明顺序,走 displayOrder——2026-08-25
            // 用户要求按系统语言排:简体中文语境国内三家排在 Spotify 前面,非简体中文
            // 反过来。设置页"播放器"卡后来也用同一个顺序,见该属性类头注。
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                // 具体播放器(不含「自动识别」)。2026-09-03 用户要求把「自动识别」和
                // 「YouTube Music」的位置对调,所以这个 ForEach 从整份 displayOrder 收窄成
                // "只排具体播放器",把「自动识别」挪到 YouTube Music **后面**单独排。
                //
                // ⚠️ 用 `filter` 从 displayOrder 派生,**不重抄一份数组** —— 那份顺序本身
                // 是按系统语言算的(简体中文语境国内三家排在 Spotify 前面,非简体反过来,
                // 见 `PlaybackPlayer.displayOrder`),抄一份就等于把语言排序这件事复制了
                // 一遍;以后新增播放器也不用回来改这个文件。
                ForEach(PlaybackPlayer.displayOrder.filter { $0 != .auto }) { player in
                    // 2026-09-03 从单选改成多选,跟设置页「播放器」卡口径一致(用户原话:
                    // 「这个引导页面之前调整了播放器的多选逻辑这里没改过来」)。此前这里
                    // 刻意留着单选、注释里写着"不是遗漏",那条取舍被这次要求推翻了。
                    //
                    // 切换和"最后一个不能取消"的判断走 `features.togglePlayer` —— 跟设置页
                    // 共用同一份,见那个方法的头注(选中集合的非空不变量在那里)。
                    PlayerChoiceCard(player: player, isSelected: features.players.contains(player)) {
                        features.togglePlayer(player)
                    }
                }
                // 五个具体播放器占掉 1 行 + 2 格之后,这三张接着往下排(第 2 行第 3 格 =
                // YouTube Music,第 3 行 = 自动识别 + 陆续支持中)—— ForEach 之后紧跟着的
                // 视图会被 LazyVGrid 自然往下排,不需要另外指定位置。
                //
                // YouTube Music 摆在这里而不是混进上面那个 ForEach:它不是
                // `PlaybackPlayer` 的 case(理由见 `WebPlatformChoiceCard` 头注)。点它
                // **不会**立刻跳去选浏览器,只是让后面多出一步 `.browserPairing`。
                WebPlatformChoiceCard(
                    icon: WebPlatformIcon.image(Self.youTubeMusicPlatformID),
                    title: "YouTube Music",
                    isSelected: wantsBrowserYouTubeMusic
                ) {
                    toggleYouTubeMusic()
                }
                // 「自动识别」排在 YouTube Music 之后(2026-09-03 用户要求的对调)。
                //
                // ⚠️ 同样从 displayOrder 里取、不裸写 `PlaybackPlayer.auto`:这样"displayOrder
                // 里有什么就显示什么"这条不变量对整个网格成立 —— 万一以后 displayOrder 不再
                // 收 `.auto`(比如自动识别改成一个独立开关),这里跟着自动消失,而不是留一张
                // 点了不知道会发生什么的孤卡。它在两种语言序里都排最后(实测),所以上面
                // 那个 filter 摘掉它之后剩下的顺序逐项不变。
                ForEach(PlaybackPlayer.displayOrder.filter { $0 == .auto }) { player in
                    PlayerChoiceCard(player: player, isSelected: features.players.contains(player)) {
                        features.togglePlayer(player)
                    }
                }
                MorePlayersComingCard()
            }
        }
    }

    // PlayerChoiceCard/MorePlayersComingCard 2026-08-25 挪进独立文件
    // (Settings/PlayerChoiceCard.swift)——设置页"播放器"那张卡后来也换成了同一套图标
    // 网格,两处共用同一个组件,不重复维护。

    /// 勾/取消「YouTube Music」那一格。**取消是非破坏性的:只收起后面那一步,不动任何配对。**
    ///
    /// ⚠️ 这里翻过一次,而且是真出过事的那种翻(2026-09-03 同日):第一版在取消勾选时把这个
    /// 平台**已配对的浏览器全部 unpair 掉**,理由写的是"否则格子看着没选、配对还在,状态说
    /// 不通"。那个理由本身没错,但代价完全不对等 —— 那是一次**看不见的**破坏性耦合:站在
    /// 播放器网格前面,你无从得知点一下这个格子会把设置页里配好的一整份浏览器配对删掉,
    /// 而且没有二次确认、没有撤销。实测就是这么把用户 `youtubeMusic` 的四个配对(Safari/
    /// Chrome/Edge/Arc)删到只剩一个的(配对值我从会话记录里恢复了)。
    ///
    /// 现在的取舍:取消勾选只把 `wantsBrowserYouTubeMusic` 翻成 false(后面那一步收起来),
    /// 配对原样留着。代价是下次重开引导 `onAppear` 会按"配过没有"重新播种、格子又亮起来
    /// —— 这个代价可以接受,因为它**如实反映**"你确实还配着浏览器";而删配置这件事必须发生
    /// 在能看清后果的地方(设置页「网页播放器」卡,那里每个浏览器有自己的移除入口),不该
    /// 由引导页一个多选格子顺手替用户做。跟"清理临时文件不用通配"是同一条纪律:破坏性动作
    /// 只在用户能逐个确认的粒度上做。
    private func toggleYouTubeMusic() {
        wantsBrowserYouTubeMusic.toggle()
        // 收起的是**后面**那一步,当前停留的下标(选播放器 = 1)不受影响 —— steps 变短
        // 只会砍掉 index 1 之后的项,见 steps 上面那条结构性约束。
    }

    /// 「配对浏览器」这一步(2026-09-03)。只在上一步勾了 YouTube Music 时出现。
    ///
    /// 为什么单独一步、而不是在勾选那一刻就地展开:用户明确要求"选了之后先不进行选择
    /// 浏览器,引导在后面选择浏览器"。选播放器那一步回答的是"你平时用什么听歌",配哪个
    /// 浏览器是另一个话题;塞在同一格里还会让那个网格在点击后突然长高。
    ///
    /// 配对动作走 `BrowserPairing.trustAndPair` —— 跟设置页「网页播放器」卡**同一份**
    /// 实现(那个函数体里的顺序是好几轮实测结论,见它的头注)。这一步不传 `revealPairing`:
    /// 设置页用它展开权限气泡,而这里两道门的说明本来就摊在页面上,没有气泡要开。
    ///
    /// ⚠️ 这一步**不**代劳授权。`trustAndPair` 只在那个浏览器已经在跑时顺手问一次系统
    /// 自动化授权(理由见它的头注),没在跑就留给用户之后自己处理 —— 引导里不该为了"把
    /// 流程走完"去后台拉起用户的浏览器抢焦点。所以这一步也**不锁下一步按钮**(跟
    /// `.lastfm` 同一档:介绍 + 可选动作,不是必需步骤),配不配得成都能往下走。
    private var browserPairingStep: some View {
        let platformID = Self.youTubeMusicPlatformID
        // ⚠️ **一份顺序固定的候选列表,不按"已配对/未配对"分两组渲染**(2026-09-03 第二轮修)。
        //
        // 第一版正是分两组的:`ForEach(paired)` 在前、`ForEach(addable)` 在后。用户报
        // 「这里我怎么点了没反应」,而实测坐实**点击一直是生效的** —— 挂监视器盯
        // `np:browserPlatformPairsJSON`,抓到每点一次就少一个配对(基线四个 → 点完只剩
        // Arc)。问题全在反馈上:分两组时点一下会让那张卡**从一组跳到另一组、在网格里换
        // 位置**(用户第二次的原话:「点了以后图标会切换位置」),而"位置变了 + 边框变了"
        // 混在一起,反而读不出"我刚把它取消了"。
        //
        // 改成一份稳定列表之后,点击的唯一视觉变化就是那张卡自己的选中态,位置不动。
        let candidates = BrowserPairing.candidateBrowsers(platformID: platformID)
        return VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("YouTube Music 用哪个浏览器？"))
                .font(.title2.bold())
            Text(L10n.t("YouTube Music 是在浏览器里播的，Lyrimuse 需要知道是哪一个才能读到播放进度。选你平时用来听歌的（可以多选）——之后系统会问你要不要授权，同意就行；随时可以在设置的「网页播放器」里再改"))
                .foregroundStyle(.secondary)
            if candidates.isEmpty {
                // 默认候选一个都没有。实践中几乎进不来这个分支(macOS 上 Safari 恒存在,
                // 而 `candidateBrowsers` 只过滤"装没装"),留着是因为它比一个空网格诚实。
                //
                // ⚠️ 这句原来写的是「Safari、Chrome、Edge、**Arc** 这类」—— 那跟 2026-09-01
                // 的产品决定正好相反:Arc 被有意从 `knownBrowserBundleIDs` 里拿掉了(适配
                // 全留着,只是不默认展示,见那边头注),点名它等于承诺一个这里不会出现的选项。
                // 改成如实说明"默认只列这几个,别的自己挑",正好接上下面那个按钮。
                Text(L10n.t("这台电脑上没有找到默认列出的浏览器（Safari、Chrome、Edge）。别的浏览器可以用下面的「从应用程序中选择…」自己挑一个"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(candidates, id: \.self) { bundleID in
                        browserCard(bundleID: bundleID, platformID: platformID)
                    }
                }
                // ⚠️ 这里**曾经**有一行小字「亮起来的就是已经配好的；再点一下取消」,
                // 2026-09-03 同日加上又被用户要求去掉("去掉这个文案")。加它的理由是:点一张
                // 已经亮着的卡做的是取消配对,而正文邀请的是"选",怕用户误删(那天确实误删过
                // 一次,配对被删空、靠会话记录恢复的)。用户拍板不要,取舍归他 —— 记在这里是
                // 为了下次别有人"好心"再加回来:真正治那次误删的是上面那两条改动(一份稳定
                // 列表不换位置 + 取消勾选不再批量删配对,两条都有 selftest 闸钉着),
                // 这行小字只是补充说明,不是那个 bug 的修复本体。
            }
            // 「从应用程序中选择…」(2026-09-03 补)。在此之前引导页只铺得出
            // `knownBrowserBundleIDs` 里装了的那三个(Chrome / Edge / Safari),而 Brave /
            // Vivaldi / Opera / Chromium 各分支、以及被有意拿出默认名单的 Arc 都驱得动 ——
            // 这批用户在引导里**完全走不通**,只能靠正文那句"随时可以在设置里再改"兜底。
            // 设置页早就有这条路,引导页缺它没有道理。
            //
            // 逻辑本体在 `BrowserPairing.chooseFromApplications`(配对逻辑只允许一份,
            // selftest 有闸),这里只负责把它返回的错误文案接到下面那个 .alert 上。
            Button(L10n.t("从应用程序中选择…")) {
                browserPickerError = BrowserPairing.chooseFromApplications(platformID: platformID)
            }
            .buttonStyle(.link)
            .font(.callout)
        }
        .alert(
            L10n.t("这个应用用不了"),
            isPresented: Binding(
                get: { browserPickerError != nil },
                set: { if !$0 { browserPickerError = nil } })
        ) {
            Button(L10n.t("知道了"), role: .cancel) { browserPickerError = nil }
        } message: {
            Text(browserPickerError ?? "")
        }
    }

    private func browserCard(bundleID: String, platformID: String) -> some View {
        // 选中态**现读**,不从外面传 —— 上一版是把 `isPaired` 当参数传进来的,那要求调用点
        // 自己先把候选分成两组,正是"点一下换位置"那个问题的来源。
        let isPaired = BrowserPairing.isPaired(bundleID, platformID: platformID)
        return WebPlatformChoiceCard(
            icon: AppIconResolver.icon(forBundleID: bundleID),
            title: FeatureSettingsStore.appDisplayName(forBundleID: bundleID) ?? bundleID,
            isSelected: isPaired
        ) {
            if isPaired {
                // 取消配对只动配对关系,**不动信任列表** —— 信任是一次独立的显式动作
                // (设置页「已信任的其它播放器」那一段管它),在引导里顺手撤掉会让用户
                // 在别处配好的东西被这里替他删了。同 `unpairBrowser` 的口径。
                BrowserPairing.unpair(bundleID, platformID: platformID)
            } else {
                BrowserPairing.trustAndPair(bundleID, platformID: platformID)
            }
        }
    }

    private var automationStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            // ⚠️ 标题和正文 2026-09-03 一起改过,别照着旧版本改回去。
            //
            // 原文是「（必需）」+「没有它，悬浮歌词完全没法显示任何内容」。那是**旧世界的
            // 说法**:接入 media-control 通道之前,Apple Music 的一切确实只能靠 AppleScript
            // 读。现在基础的"在播什么"来自 collector 的 media-control 通道,自动化权限管的是
            // `MediaControlClient.refinedAppleMusicSnapshotIfNeeded`(借一个更精确的
            // elapsedTime)加上 `MusicPlaybackController` 里那一整套播放/资料库控制。也就是
            // 说没有它歌词照样显示 —— 继续写"完全没法显示"是在吓唬用户。
            //
            // 强度也跟着降成「推荐」并从 `nextIsLocked` 里移出去,理由见那边。
            Text(L10n.t("Apple Music 自动化权限（推荐）"))
                .font(.title2.bold())
            Text(L10n.t("这个权限用来把 Apple Music 的播放进度校得更准，以及让你直接在歌词上控制播放（播放/暂停、切歌、拖进度、喜欢、加资料库）。没有它歌词照样能显示——基本的播放信息由后台服务读取——只是进度会有偏差、那些按钮按不动。点下面的按钮会弹出系统授权对话框，选择「允许」即可；随时可以在设置里重新打开这一步"))
                .foregroundStyle(.secondary)
            HStack {
                Image(systemName: automationStatusIconName)
                    .foregroundStyle(automationStatusIconColor)
                Text(automationStatusCaption)
                Spacer()
                if isRequestingAutomation {
                    ProgressView().controlSize(.small)
                } else {
                    Button(automationActionTitle) { handleAutomationAction() }
                }
            }
            if isRequestingAutomation {
                if automationRequestTimedOut {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.t("这次请求耗时有点久。如果你已经看到系统弹窗，请去处理它；找不到弹窗的话，可以直接去系统设置里手动开启"))
                        Button(L10n.t("打开系统设置")) {
                            NSWorkspace.shared.open(MusicAutomationPermission.systemSettingsURL)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text(L10n.t("请查看屏幕上弹出的系统授权对话框，选择「允许」"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 「让它一直待命」这一步(2026-09-03 由原 `collectorServiceStep` 扩成)。
    ///
    /// 两件事摆在一页:**常驻后台服务(必需)** 和 **开机自动启动 Lyrimuse(可选)**。它们
    /// 回答的是同一个问题,但**不是同一件事**:collector 是一个独立的 launchd job(KeepAlive,
    /// 装上之后本来就开机自启,跟这个开关无关),而这个开关管的是 Lyrimuse 这个 App 自己
    /// (`LoginItemManager`,见 AppSettings.launchAtLoginEnabled 的 didSet)。两者互不拉起:
    /// App 退出后 collector 照常采集(见 01 章)。
    ///
    /// ⚠️ 这条区别**刻意不写进界面文案**(2026-09-03 用户要求"去掉括号里面的文案")。原来
    /// 副标题后面挂着一句"(后台采集服务是独立的,装上之后本来就会开机自启)",两行小字塞不下、
    /// 在窗口里撑出去了,而且它解释的是一个用户根本没问的区别 —— 上面那张卡已经说清 collector
    /// 自己会常驻。这里记着是给改代码的人看的,不是给用户看的。
    private var backgroundStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("让它一直待命"))
                .font(.title2.bold())
            Text(L10n.t("Lyrimuse 需要一个后台程序常驻运行，负责读取播放状态、解析歌词/封面并写入本地缓存——没有它，悬浮歌词/灵动岛无法显示任何内容"))
                .foregroundStyle(.secondary)
            HStack {
                Image(systemName: collectorRunning ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(collectorRunning ? .green : .red)
                Text(collectorRunning
                     ? L10n.t("后台采集服务：运行中")
                     : L10n.t("后台采集服务：未运行（必需）"))
                Spacer()
                if isTogglingCollectorService {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L10n.t("启用")) { enableCollectorService() }
                        .disabled(collectorRunning)
                }
            }
            // 点了「启用」却没起来时的交代(2026-09-03 补)。在此之前这条路是**全静默**的:
            // 图标停在红色「未运行」,没有原因、没有下一步,而这一步又锁着「下一步」——
            // 卡在这里的用户彻底走不动,界面上连"这不是你的错"都没说。
            if let collectorFailure {
                Text(collectorFailure)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            toggleRow(
                icon: "power",
                title: L10n.t("开机时自动启动 Lyrimuse"),
                subtitle: L10n.t("菜单栏图标开机就在，不用每次自己打开"),
                isOn: $settings.launchAtLoginEnabled)
        }
    }

    /// 「译文与罗马音」这一步(2026-09-03 新增)。
    ///
    /// 为什么值得单独占一步:这是这个 App 对中日韩听众最核心的能力之一(设置里「歌词 →
    /// 译文/效果」整整两卡),而在此之前引导里**一个字都没提** —— 新用户只有自己摸到设置
    /// 里折叠着的那几行才会发现。跟 `.lastfm` 同一档:介绍性质、不锁「下一步」。
    ///
    /// ⚠️ 这里只放**两个总开关**,不放"标注哪些语言"那一排。那几个走的是
    /// `romanizationScripts` 的**双写**(AppSettings 持久化 + LocalPlaybackSource 让当前这首
    /// 歌立刻重新解析,见 SettingsView.romanizationToggle 的头注),只写一边就会出"改了要等
    /// 下一首才生效"这种错位 —— 引导页照抄一份等于给那条约束开第二个漂移点。默认值
    /// (日/韩开、中文关)对绝大多数人本来就是对的,细调留给设置页。
    private var lyricsExtrasStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("译文与罗马音"))
                .font(.title2.bold())
            Text(L10n.t("听不懂的语言可以并排显示中文译文；日文、韩文、粤语还能标上罗马音跟着唱"))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                toggleRow(
                    icon: "text.bubble",
                    title: L10n.t("显示译文"),
                    subtitle: L10n.t("歌词下面并排显示一行译文"),
                    isOn: $settings.showTranslation)
                toggleRow(
                    icon: "textformat.alt",
                    title: L10n.t("显示罗马音"),
                    subtitle: L10n.t("日文、韩文、中文拼音、粤拼默认都会注音，可以在设置里单独关掉"),
                    isOn: $settings.showRomanization)
            }
            Text(L10n.t("这两项只在「桌面悬浮歌词」和「歌词窗口」里显示——灵动岛受限于胶囊空间放不下，菜单栏歌词只能显示一行纯文字"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // 三种显示形态在代码里完全正交(各自独立的开关 + 各自独立的窗口控制器,可以同时开、
    // 也可以一个都不开),所以这里是三个独立开关,不是单选 Picker。第四种形态"歌词窗口"
    // 刻意不放进来:它没有任何持久化开关,在向导里打开只会弹一扇窗盖住向导本身,而且下次
    // 启动不保留 —— 在这里承诺它等于承诺一个不存在的偏好。
    //
    // ⚠️ 三条必须守住的写法约束:
    // 1) 关着的那个形态,渲染路径上连 `.shared` 都不能碰 —— 两个窗口控制器都是
    //    `static let shared`,init() 里订阅 PlaybackCoordinator.$isPlayingNow 的那个
    //    Combine sink 在订阅的一瞬间就会把窗口建出来并显示(NotchLyricsWindowController
    //    顶部 :31-39 那段注释记的就是这个)。所以两个 `.shared` 只允许出现在 Binding 的
    //    set 闭包里(只在用户真的拨动开关时执行),get 一律读 settings 上的持久化布尔值。
    //    落地自查:本文件里 `WindowController.shared` 必须恰好两处,且都在 set: 里。
    // 2) 开/关必须走 setVisible(_:) —— classicOverlayEnabled/notchOverlayEnabled 的
    //    didSet 只写 UserDefaults、没有任何副作用,直接赋值只会得到"设置里显示开着、窗口
    //    其实没出现"的错位,要重启 App 才对得上;还会漏掉 setVisible 打开时补应用的
    //    hideDuringScreenCapture / hideWhenNotPlaying / lockPosition。写法与设置页
    //    SettingsView.currentSection 里那三处逐字一致。
    // 3) 不做任何"帮用户预选"的 onAppear 赋值:全新用户本来就默认开着桌面悬浮歌词
    //    (AppSettings.init() 里的 ?? true),而 AppSettingsMirror.restoreIfPristine()
    //    会让重装/同机重来的用户带着自己的旧配置走到这一步,强行预选等于静默覆盖他的
    //    选择(而且绕过 setVisible,改完窗口还不动)。这一步只读不写,唯一的写入路径是
    //    用户亲手拨动开关。
    //
    // ⚠️ 还有一条口味上的约束(**不再是安全前提**):`steps` 的长度由 `features.players`
    // 和 `wantsBrowserYouTubeMusic` 两个值决定,所以能改它们的控件最好只留在 index 1
    // (playerChoiceStep),否则用户会看到进度点在脚下变长变短。
    //
    // 这条原来写的是"必须永不出现,因为 steps[step] 没有越界守卫" —— 那个论证 2026-09-03
    // 被推翻了:它默认"引导页是唯一宿主",而设置窗口能同时开着改 `features.players`
    // (`@Published`),引导页自己的 .lastfm 那一步还有个按钮专门去开设置窗。真正的守卫现在
    // 是 `currentStep` + `.onChange(of: steps.count)` 那一对,详见 `currentStep` 头注。
    private var displayModeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("歌词显示在哪里"))
                .font(.title2.bold())
            Text(L10n.t("这几种可以同时开着，先挑你现在想用的——之后随时能在设置里单独开关"))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                displayModeRow(
                    kind: .classic,
                    title: L10n.t("桌面悬浮歌词"),
                    subtitle: L10n.t("贴在桌面上"),
                    isOn: Binding(
                        get: { settings.classicOverlayEnabled },
                        set: { LyricsOverlayWindowController.shared.setVisible($0) }))
                displayModeRow(
                    kind: .notch,
                    title: L10n.t("灵动岛歌词"),
                    subtitle: hasNotchedScreen
                        ? L10n.t("紧凑地贴着屏幕顶部的刘海")
                        : L10n.t("这台 Mac 没有刘海，会显示在屏幕顶部正中"),
                    isOn: Binding(
                        get: { settings.notchOverlayEnabled },
                        set: { NotchLyricsWindowController.shared.setVisible($0) }))
                displayModeRow(
                    kind: .menuBar,
                    title: L10n.t("菜单栏歌词"),
                    subtitle: L10n.t("菜单栏里的一行字"),
                    isOn: $settings.showLyricsInMenuBar)
            }

            // 这两条提示**互斥**,任何时候最多出现一条 —— 整个向导没有 ScrollView、窗口
            // 固定 480×420,超出部分既不滚动也不撑大窗口,只会被静默裁掉/压成省略号;两条
            // 同时出现正好会顶破这一步的高度预算。全关时"等播起来才看得到"也没意义了,
            // 所以警告优先。
            if noDisplayModeEnabled {
                displayModeNote(
                    icon: "exclamationmark.triangle.fill",
                    tint: .orange,
                    text: L10n.t("三种方式都关掉了，播放时屏幕上不会出现歌词——菜单栏图标一直都在，随时可以从那里重新打开"))
            } else if !isPlayingNow {
                displayModeNote(
                    icon: "info.circle.fill",
                    tint: .secondary,
                    text: L10n.t("现在没有在播放——桌面悬浮歌词会立刻出现，灵动岛和菜单栏歌词要等开始播放才看得到"))
            }
        }
    }

    // 向导不用设置窗口那套 SettingsCard/SettingsRow(两边是两套排版语言),这里自己拼一行。
    //
    // 左边不是 SF Symbol 而是一张手绘小示意图:"灵动岛"对没见过刘海机的人就是个黑话,一枚
    // rectangle.topthird.inset.filled 解释不了它到底会出现在屏幕的哪个位置;三张图并排才
    // 对照得出三种形态差在哪。
    private func displayModeRow(
        kind: DisplayModeThumbnail.Kind,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            DisplayModeThumbnail(kind: kind)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            // ⚠️ 必须显式 .toggleStyle(.switch):macOS 上 Toggle 默认画成**复选框**,只有
            // 放在 Form/List 里才会自动变成右侧胶囊开关。设置页是靠 SettingsRow 统一挂了
            // 这一句(Settings/SettingsDesignSystem.swift:346),向导里没有那个祖先,不写
            // 就是一排复选框,不报错也不崩,只是长得跟设置页对不上。
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    /// 带 SF Symbol 的一行开关。`displayModeRow` 是它的姐妹 —— 那边左边是手绘示意图,因为
    /// "灵动岛"光靠一枚符号解释不了它会出现在屏幕的哪个位置;这一批(开机启动、译文、罗马音)
    /// 没有那个问题,用符号就够了。
    ///
    /// ⚠️ 同样必须显式 `.toggleStyle(.switch)`:macOS 上 Toggle 默认画成**复选框**,只有放在
    /// Form/List 里才会自动变成右侧胶囊开关,而向导里没有那个祖先(完整理由见 displayModeRow)。
    private func toggleRow(
        icon: String, title: String, subtitle: String, isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                // 跟 displayModeNote 同一个理由钉死拉丁语区:SF Symbols 里有一批"字母造型"
                // 的符号带 CJK 本地化变体(这里用到的 textformat.alt 正是其中之一),中文界面
                // 下会被渲染成汉字。图标位置要的永远是图形而不是本地化文字。
                .environment(\.locale, Locale(identifier: "en"))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private func displayModeNote(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                // 跟 SettingsRow 同一个理由钉死拉丁语区:SF Symbols 里有一批"字母造型"的
                // 符号带 CJK 本地化变体,中文界面下会被渲染成汉字。图标位置要的永远是图形
                // 而不是本地化文字,统一钉住。
                .environment(\.locale, Locale(identifier: "en"))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // 这台机器上有没有真刘海屏。判据直接复用 NotchLyricsWindowController 用的那一个
    // (ScreenIdentity.notched,即 safeAreaInsets.top > 0),不另起一套。
    //
    // 只换这一行的副标题文案,**不影响这个开关能不能开**:没刘海的机器上灵动岛依然可用,
    // 只是退化成屏幕顶部正中的一小条(NotchLyricsWindowController.geometry(for:) 里的
    // fallbackNotchHeight 分支)。隐藏它会让这批用户永远发现不了这个功能,禁用则是谎报
    // "不支持"。
    private var hasNotchedScreen: Bool { ScreenIdentity.notched != nil }

    private var noDisplayModeEnabled: Bool {
        !settings.classicOverlayEnabled
            && !settings.notchOverlayEnabled
            && !settings.showLyricsInMenuBar
    }

    // 纯介绍性质,不收集任何凭据(那些留给设置里的 Last.fm 详情页)——向导这一步只
    // 负责让用户知道有这个功能、值不值得现在就去配。点了"现在去设置里连接"会直接
    // 打开设置窗口并停在 Last.fm 详情页(见 AppActions.pendingSettingsSelection),
    // 不用先关掉引导向导再自己去侧边栏找。
    private var lastfmStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 真实的 Last.fm 品牌图标(2026-09-03 用户要求),不再拿 SF Symbol 的循环箭头
            // 凑数 —— 跟设置页账号卡片、菜单栏面板底栏、Dock 右键菜单同一张 PNG
            // (`lastfmBadge` / `LastfmIcon.png`,素材来源和"为什么不设 isTemplate"见
            // AccountLinkingTab.swift 里 `lastfmBadgeImage` 的注释)。
            //
            // 圆角按 `lastfmBadge` 的默认比例(size * 0.22)走,不额外指定 —— 那个比例是
            // 这张图在别处已经在用的,写死一个数只会让同一张图在引导页长得不一样。
            lastfmBadge(size: 44)
            Text(L10n.t("同步收听到 Last.fm（可选）"))
                .font(.title.bold())
            Text(L10n.t("连上之后，你播放的每一首歌都会自动 scrobble 到 Last.fm，还能在这里看到你专属的听歌档案"))
                .foregroundStyle(.secondary)
            Button(L10n.t("现在去设置里连接")) {
                AppActions.shared.requestSettings(.account(.lastfm))
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
        }
    }

    /// 最后一步要核对的几件事。只列**这一轮真的走过**的步骤 —— 跟 `steps` 派生自同一批
    /// 判据,没问 Apple Music 权限的人不该在清单上看到一条"未完成"的权限。
    private struct ReadinessItem: Identifiable {
        let id: String
        let ok: Bool
        let title: String
        let target: Step
    }

    private var readinessItems: [ReadinessItem] {
        var items: [ReadinessItem] = [
            ReadinessItem(id: "collector", ok: collectorRunning,
                          title: L10n.t("常驻后台服务"), target: .background)
        ]
        if needsAppleMusicAutomation {
            items.append(ReadinessItem(
                id: "automation", ok: automationStatus == .authorized,
                title: L10n.t("Apple Music 自动化权限"), target: .automation))
        }
        if wantsBrowserYouTubeMusic {
            items.append(ReadinessItem(
                id: "browser",
                ok: BrowserPairing.hasAnyPair(platformID: Self.youTubeMusicPlatformID),
                title: L10n.t("YouTube Music 的浏览器"), target: .browserPairing))
        }
        items.append(ReadinessItem(
            id: "display", ok: !noDisplayModeEnabled,
            title: L10n.t("歌词显示方式"), target: .displayMode))
        return items
    }

    /// 2026-09-03 从"无条件一句「一切就绪」"改成一张**体检清单**。
    ///
    /// 这一改同时顶掉了两件旧设计:
    ///  ① 2026-08-02 那次把 automation 锁进「下一步」,治的是"用户误点不允许还能一路走完、
    ///     这一页却说一切就绪"。病根其实在这一页**撒谎**,不在按钮不够严 —— 清单如实报告
    ///     之后,那道锁就没必要了(见 `nextIsLocked`)。
    ///  ② 这一页原来只说"可以随时在设置里调整",而这是个**没有 Dock 图标的菜单栏 App**:
    ///     点完「开始使用」窗口一关,屏幕上什么都不会发生,新用户根本不知道它去哪了。首启
    ///     那个"⌘+拖拽可以挪位置"的气泡本来能交代这件事,但它 T+1.5s 就弹、8 秒后消失,
    ///     恰好被这扇引导窗口盖住(已在 MenuBarStatusItem 里改成引导走完才弹),所以图标
    ///     在哪、怎么挪、快捷键去哪配,这一页必须自己讲一遍。
    private var doneStep: some View {
        let items = readinessItems
        let allOK = items.allSatisfy(\.ok)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: allOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(allOK ? Color.green : Color.orange)
                Text(allOK ? L10n.t("一切就绪") : L10n.t("还差一点"))
                    .font(.title.bold())
            }
            // 一句俏皮话(2026-09-03 用户要求)。App 名 Lyrimuse = Lyric + Muse,收尾这一页
            // 是整个向导唯一适合把这个双关点破的地方 —— 前面每一步都在讲权限/服务/开关,
            // 只有这里是"配完了,去听歌吧"。两种状态各一句:全绿是送别,没全绿是"再等等你"。
            //
            // ⚠️ 文案里点名了「开始使用」这个按钮,英文那版对应 "Get Started"(catalog 里
            // 「开始使用」的既有译法)—— 以后改按钮文案要连这句一起改,别让它指向一个不存在
            // 的按钮。
            Text(allOK ? L10n.t("缪斯已经就位——接下来交给音乐。按下「开始使用」，让每一句歌词都跟着旋律亮起来")
                       : L10n.t("缪斯还在候场——把上面标橙的那几项补齐，她随时可以开嗓"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // 你在前面挑的那几个播放器 —— 2026-09-03 用户要求把这一片换成它
            // (「这个地方不要放着几个吧,放刚才选了的那些播放器」)。收尾这一页原来铺着
            // 四行清一色的绿勾,信息量约等于零;换成"歌词会跟着这些走"之后,这一页才真的
            // 在说"你配好了什么"。
            chosenPlayersStrip
            // ⚠️ **清单没有被删掉,只是全绿时不出现**。它是 `automation` 从「下一步」那道锁里
            // 移出去之后**唯一如实报告缺什么**的地方(见 nextIsLocked / doneStep 的头注) ——
            // 整条删掉就又回到 2026-08-02 治过的那个病:用户误点「不允许」还能一路走完,这一页
            // 却无条件说"一切就绪"。折中是只列**没就绪**的那几行:全绿时页面干净,出问题时
            // 一眼看到红的那条并能直接跳回去处理。
            if !allOK {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items.filter { !$0.ok }) { item in
                        readinessRow(item)
                    }
                }
            }
            Text(L10n.t("Lyrimuse 住在屏幕右上角的菜单栏里，点它就能打开设置、歌词管理和歌词窗口；按住 ⌘ 拖动可以把图标挪个位置。常用操作还能在设置的「快捷键」里配上全局热键"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // 见 finish():后台服务没起来时这次不算走完引导,下次启动还会再问。写在脸上,
            // 不做无声惩罚。
            if !collectorRunning {
                Text(L10n.t("后台采集服务还没启用，所以这次不算走完引导——下次启动会再问一次"))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 收尾这一页那一串里的一项。之所以要这么一个类型:这一串**混着两种东西** ——
    /// `PlaybackPlayer` 的 case,和不是 case 的网页平台 YouTube Music(状态在"配对了哪个
    /// 浏览器"那边,理由见 `WebPlatformChoiceCard` 头注)。
    private enum ChosenEntry: Identifiable {
        case player(PlaybackPlayer)
        case webPlatform(id: String, title: String)

        var id: String {
            switch self {
            case .player(let p): return "player.\(p)"
            case .webPlatform(let id, _): return "web.\(id)"
            }
        }

        var displayName: String {
            switch self {
            case .player(let p): return p.displayName
            case .webPlatform(_, let title): return title
            }
        }
    }

    /// 这一轮选中的东西,**顺序即展示顺序**。
    ///
    /// ⚠️ 图标那一行和名字那一行**必须共用这一个数组**。上一版是两处各拼一遍(图标一个
    /// `ForEach` + `if`,名字一个 `map` + 三元),两串顺序靠人肉对齐 —— 那正是会漂的写法,
    /// 而且第一版就漂了:图标排到最后的是 YouTube Music,名字里排到最后的也是它,但两处
    /// 都把「自动识别」放在了 YouTube Music **前面**,跟选播放器那一步的网格顺序相反。
    ///
    /// 顺序跟 `playerChoiceStep` 的网格逐项一致:具体播放器(按 `PlaybackPlayer.displayOrder`,
    /// 那份顺序本身按系统语言算)→ YouTube Music → 「自动识别」垫底。「自动识别」排在
    /// YouTube Music 之后是 2026-09-03 用户要求的对调,同日用户又指出收尾这一页没跟上
    /// (「自动识别和 youtubemusic 的顺序是不是应该换一下」)—— 两处顺序不一致,用户会以为
    /// 其中一处是错的。
    private var chosenEntries: [ChosenEntry] {
        var entries = PlaybackPlayer.displayOrder
            .filter { $0 != .auto && features.players.contains($0) }
            .map(ChosenEntry.player)
        if wantsBrowserYouTubeMusic {
            entries.append(.webPlatform(id: Self.youTubeMusicPlatformID, title: "YouTube Music"))
        }
        // 同样从 displayOrder 里取、不裸写 `PlaybackPlayer.auto` —— 理由同 playerChoiceStep
        // 里那个 filter:万一以后 displayOrder 不再收 .auto,这里跟着自动消失。
        entries += PlaybackPlayer.displayOrder
            .filter { $0 == .auto && features.players.contains($0) }
            .map(ChosenEntry.player)
        return entries
    }

    /// 收尾这一页的"你选的播放器"。图标走 `PlayerIconView`(三级兜底的取图本体,跟选项卡
    /// 共用一份,见那边头注)。
    private var chosenPlayersStrip: some View {
        let entries = chosenEntries
        let names = entries.map(\.displayName)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ForEach(entries) { entry in
                    switch entry {
                    case .player(let player):
                        PlayerIconView(player: player, size: 24)
                    case .webPlatform(let id, _):
                        if let icon = WebPlatformIcon.image(id) {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 24, height: 24)
                        } else {
                            // 没走 build.sh 打包时取不到随包图标 —— 同 WebPlatformChoiceCard 的兜底。
                            Image(systemName: "globe")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Color.secondary,
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
            }
            // 光排一串图标读不出名字(尤其"自动识别"那张纯色块),名字这一行既是给眼睛的
            // 说明,也是旁白唯一能读到的内容 —— 上面那排图标本身不带任何标签。
            Text(String(format: L10n.t("歌词会跟着这些走：%@"), names.joined(separator: " · ")))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("你选的播放器") + "：" + names.joined(separator: "、"))
    }

    private func readinessRow(_ item: ReadinessItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(item.ok ? Color.green : Color.orange)
                .environment(\.locale, Locale(identifier: "en"))
                // 图标是这一行唯一表达"好没好"的东西,旁白必须读得出来 —— 不然听到的只是
                // 一串标题,分不出哪条是红的。
                .accessibilityLabel(item.ok ? L10n.t("已就绪") : L10n.t("未完成"))
            Text(item.title)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            if !item.ok {
                Button(L10n.t("去处理")) { jump(to: item.target) }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }

    // 跟 GeneralSettingsTab 同一套状态展示逻辑,这里独立写一份而不是抽共享组件——
    // 就这几行纯展示分支,抽象成本比重复它本身更高。
    private var automationStatusCaption: String {
        switch automationStatus {
        case .authorized: return L10n.t("已授权")
        case .denied: return L10n.t("已拒绝")
        case .notDetermined: return L10n.t("未授权")
        }
    }

    private var automationStatusIconName: String {
        switch automationStatus {
        case .authorized: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .notDetermined: return "questionmark.circle.fill"
        }
    }

    private var automationStatusIconColor: Color {
        switch automationStatus {
        case .authorized: return .green
        case .denied: return .red
        case .notDetermined: return .orange
        }
    }

    private var automationActionTitle: String {
        automationStatus == .notDetermined ? L10n.t("请求权限") : L10n.t("打开系统设置")
    }

    private func handleAutomationAction() {
        if automationStatus == .notDetermined {
            requestAutomationPermission()
        } else {
            NSWorkspace.shared.open(MusicAutomationPermission.systemSettingsURL)
        }
    }

    // 见 MusicAutomationPermission.requestWithTimeout 注释——这一步不能直接在按钮
    // 点击回调里同步调用,那样会把整个 App UI 冻结、表现成"点了没反应"。超时(返回
    // nil)时 isRequestingAutomation 故意保持 true、不重新允许点"请求权限":原来那次
    // 检查很可能还在后台跑着,不该让用户再并发触发第二次系统弹窗请求,只亮出"打开
    // 系统设置"这条不冲突的备选路径。
    private func requestAutomationPermission() {
        isRequestingAutomation = true
        automationRequestTimedOut = false
        Task {
            if let status = await MusicAutomationPermission.requestWithTimeout() {
                automationStatus = status
                isRequestingAutomation = false
                automationRequestTimedOut = false
            } else {
                automationRequestTimedOut = true
            }
        }
    }

    private func enableCollectorService() {
        isTogglingCollectorService = true
        collectorFailure = nil
        Task {
            // 引导页只关心"起来了没",不铺开三态——那是设置页排查问题时才需要的粒度。
            let state = await CollectorServiceManager.setEnabledAndWait(true)
            settings.collectorServiceEnabled = true
            collectorRunning = state.isRunning
            isTogglingCollectorService = false
            // 起不来时给一句交代 + 一条出路(2026-09-03)。`LaunchdJobState.description`
            // 是固定英文的诊断串(见那边头注:它本来就是拿来贴给别人看的),所以只放进括号里
            // 当线索,不承担正文的表达。
            collectorFailure = state.isRunning ? nil : String(
                format: L10n.t("没能启动（%@）。可以先「暂时跳过」，之后到设置的「通用 → 后台采集服务」里重试，那一页会给出更细的状态。"),
                state.description)
        }
    }

    /// 翻到某一步。所有翻页都走它 —— `step` 的加减法和 `furthestStep` 的推进收在一处,
    /// 免得"下一步"按钮、进度点、体检清单的「去处理」各记一套。
    private func goTo(_ index: Int) {
        let list = steps
        step = min(max(index, 0), list.count - 1)
        furthestStep = max(furthestStep, step)
    }

    /// 跳到某一个具体步骤(体检清单的「去处理」用)。那一步不在本轮列表里就什么都不做 ——
    /// 清单本身是按同一份 `steps` 派生的,正常不会出现,但不值得为此崩一次。
    private func jump(to target: Step) {
        guard let index = steps.firstIndex(of: target) else { return }
        goTo(index)
    }

    private func finish() {
        // ⚠️ **后台服务没起来就不算"引导过了"**(2026-09-03,跟同日新增的「暂时跳过」配套)。
        //
        // `hasCompletedOnboarding` 一旦置真,这扇窗口再也不会自动出现,而它是把 collector
        // 服务装起来的主要入口 —— 15 章记着的那条不可自愈的死路正是这么形成的:服务没装、
        // 引导又被标记成已完成,用户看到的是桌面永久停在「搜索歌词中…」,界面上没有任何
        // 线索指向"后台服务没装"。加了「暂时跳过」之后,那条死路就又有了一条新的到达方式,
        // 所以这里必须挡住。
        //
        // 跳过的人代价只是"下次启动会再问一次"(跟直接关窗完全同一档待遇),而 doneStep 的
        // 体检清单已经把这件事写在脸上了,不是无声惩罚。
        if collectorRunning {
            settings.hasCompletedOnboarding = true
        }
        dismissWindow(id: "onboarding")
    }
}

// MARK: - 显示形态小示意图
//
// 仓库里没有任何现成的形态缩略图资产(设置页"外观"整页零预览,只有 SF Symbol),所以这三张
// 图用 SwiftUI 基本形状现画。三张共用同一个"屏幕外框 + 顶部菜单栏条"的底,差别只在歌词画
// 在哪儿 —— 三行摆在一起才对照得出"灵动岛"到底跟另外两种差在哪。
//
// 尺寸全部写成固定常量、**不用 GeometryReader**:示意图必须是可预测的固定高度,不能跟着
// 容器变(这一步没有 ScrollView,窗口固定 480×420,溢出是静默裁切)。
//
// ⚠️ 示意图**不跟着开关变灰**。第一版做过"关掉就 saturation(0)+opacity(0.45)",实测(2026-08-14
// 真机截图)是反效果:灵动岛和菜单栏歌词默认都是关的,于是最需要被解释的那两张恰好被洗成
// 两团灰斑,而这张图存在的唯一理由就是"让没见过的人看懂它会出现在屏幕哪儿"。开关状态由右
// 边的 Toggle 表达,图只负责解释位置。
private struct DisplayModeThumbnail: View {
    enum Kind { case classic, notch, menuBar }

    let kind: Kind

    private static let width: CGFloat = 56
    private static let height: CGFloat = 36
    private static let menuBarHeight: CGFloat = 6
    private static let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)

    var body: some View {
        ZStack(alignment: .top) {
            Self.shape.fill(Color.primary.opacity(0.08))
            // 顶部菜单栏条 —— 三张图共用的参照物,没有它就分不出"贴着顶部"和"在桌面上"。
            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(height: Self.menuBarHeight)
            sketch
        }
        .frame(width: Self.width, height: Self.height)
        .clipShape(Self.shape)
        .overlay(Self.shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
        // 纯装饰:位置信息已经由同一行的标题和副标题说清楚了,不让旁白再念一遍图形。
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var sketch: some View {
        switch kind {
        case .classic:
            // 桌面偏下方的两行歌词,第一行用强调色表示"正在唱的这一句"。
            VStack(spacing: 4) {
                Capsule().fill(Color.accentColor).frame(width: 32, height: 4)
                Capsule().fill(Color.primary.opacity(0.3)).frame(width: 22, height: 3)
            }
            .frame(width: Self.width, height: Self.height, alignment: .center)
            .offset(y: 5)
        case .notch:
            // 顶部正中垂下来的刘海(比菜单栏条更深、略高一点,读起来才像一块"挖掉的角"),
            // 歌词紧贴在它右边。
            HStack(spacing: 3) {
                UnevenRoundedRectangle(bottomLeadingRadius: 2, bottomTrailingRadius: 2, style: .continuous)
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: 18, height: Self.menuBarHeight + 2)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 15, height: 4)
                    .padding(.top, 1)
            }
            .frame(width: Self.width, alignment: .center)
        case .menuBar:
            // 桌面上什么都没有,只有菜单栏右端的一行字 —— 位置(靠右)是它跟灵动岛(居中)
            // 唯一的区别,所以刻意压到最右、和右边框只留 3pt。
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 20, height: 3)
                    .padding(.trailing, 3)
            }
            .frame(width: Self.width, height: Self.menuBarHeight, alignment: .trailing)
        }
    }
}
