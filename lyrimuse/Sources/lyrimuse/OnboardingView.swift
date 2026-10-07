import AppKit
import Combine
import LyrimuseCore
import SwiftUI

// 首次启动的完整引导向导,做的是同类菜单栏音乐 App 常见的那种"一步步走一遍"的
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
    // 「自动化」权限的状态/请求跟设置页共用同一个模型 —— 需要这份权限的播放器不止一个,
    // 每家一套"请求中 / 超时 / 已确定"状态机分散在两个界面里必然漂。见那个类的头注。
    @ObservedObject private var automation = PlayerAutomationPermissions.shared
    // 「完全磁盘访问」同理,跟设置页「播放器」那张卡共用一个模型。
    @ObservedObject private var fullDiskAccess = FullDiskAccessPermission.shared
    // 「辅助功能」同理。
    @ObservedObject private var accessibility = AccessibilityPermission.shared
    // 这台 Mac 此刻有没有触控栏:决定「歌词怎么显示」那一步有没有触控栏那一行、几句文案带不带触控栏。
    // 它只有 `isPresent` 一个 @Published、只在触控栏出现 / 消失时变,整个订阅不会带来高频重渲染。
    @ObservedObject private var touchBar = TouchBarAvailability.shared
    // 引擎常驻服务是否真的在跑——这一步是"软强制"的必经步骤:锁住下一步按钮,
    // 但仍然可以直接关掉整个引导窗口跳过,不禁用/隐藏关闭按钮。
    @State private var engineRunning = false
    @State private var isTogglingEngineService = false
    /// 收尾页「放一首歌试试」那一行的输入,只订阅用得到的几个属性(理由同 `isPlayingNow`)。
    @State private var liveInput = OnboardingFlow.LiveInput(
        title: "", artist: "", hasLyrics: false, instrumental: false,
        noLyrics: false, adBreak: false, networkDown: false)
    // 只用来决定要不要提醒"灵动岛 / 菜单栏 / 触控栏歌词得等播起来才看得见"。
    //
    // 刻意**不**写成 `@ObservedObject private var coordinator = PlaybackCoordinator.shared`:
    // 那会订阅整个单例,而它有二十来个 @Published(currentLine/anchor/artworkImage… 每个播放
    // tick 都在变),整个向导会跟着高频重渲染 —— 这个仓库为"@ObservedObject 订阅整个单例"
    // 踩过一次真实的 20Hz 过度重渲染 bug(见"歌词管理"窗口那次)。这里只要 isPlayingNow 这
    // 一个布尔,单独订阅 + removeDuplicates,只有真的开始/停止播放时才动一次。
    // @Published 的 publisher 在订阅那一瞬间就会把当前值发过来,所以初值给 false 不会停在
    // 错的状态上。
    @State private var isPlayingNow = false
    /// "已经走到过"的最远一步 —— 进度点只允许往回跳到这个范围内(往前跳会绕过必需
    /// 步骤那道锁)。跟 `step` 一样是纯会话态,不持久化:引导本身就是一次性的流程,存下来
    /// 只会多一个跟"这次走到哪"对不上的字段。
    @State private var furthestStep = 0
    /// 常驻服务点了「启用」却没起来时,给用户的一句交代。nil = 没有待报告的失败。
    @State private var engineFailure: String?
    /// 「从应用程序中选择…」挑到一个驱不动的 App 时的错误文案(本体在
    /// `BrowserPairing.chooseFromApplications`,那边只返回文案、不碰视图状态)。
    @State private var browserPickerError: String?
    /// 撒花放过几次 —— 换一个更大的值就重放一阵(见 `ConfettiOverlay.burst`)。
    ///
    /// 跟 `step` / `furthestStep` 同一档**不持久化**:引导本身是一次性流程,存下来只会多一个
    /// 跟"这次走到哪"对不上的字段。
    @State private var confettiBurst = 0

    /// 步骤与流程判断(走哪几步、翻页夹下标、锁、体检清单、收尾页顺序)都在
    /// `OnboardingFlow`(LyrimuseCore,selftest onboarding 组钉着),这里只调用和排版。
    private typealias Step = OnboardingStep

    /// 上一步勾了「YouTube Music」——它不是 `features.players` 里的一个成员(见
    /// `WebPlatformChoiceCard` 的头注:网页播放器走的是"配对浏览器"那套状态),所以要单独
    /// 记一笔,用来决定后面那一步 `.browserPairing` 要不要出现。
    ///
    /// 刻意**不持久化**这个布尔。真正要落盘的东西是配对本身
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
    /// 判据翻过两次,别再收窄回去:
    ///  - (上午)从 `== [.appleMusic]`(恰好只选了它)放宽成 `contains` —— 同日
    ///    这一步从单选改成多选,而"同时选了 Apple Music 和别的播放器"时那条 AppleScript
    ///    路径照样会被走到,权限仍然需要。
    ///  - (本次)再补上 `.auto`。`MediaControlClient.adaptedSnapshot`
    ///    的第一道 guard 是 `bundleID == PlaybackPlayer.appleMusic.bundleIdentifier`,
    ///    **完全不看 `features.players`** —— 也就是说只要在播的是 Music.app 就会走那条路。
    ///    而 `features.players` 的默认值恰恰是 `[.auto]`(FeatureSettingsStore),于是"保持
    ///    默认、平时听 Apple Music"的人走完整个引导都不会被问过这个权限,然后一直用着一个
    ///    进度不准、播放控制全按不动的版本。
    ///  - 判据本身挪去 `Set<PlaybackPlayer>.playersNeedingAutomation`(LyrimuseCore),
    ///    因为设置页那张权限卡漏了 `.auto`、跟这里不一致(见那个属性的头注)。
    ///  - 从一个布尔扩成**一份列表**:有 AppleScript 字典的不止 Apple Music 一家,
    ///    Spotify 的曲目与位置同样走它。这一步与设置页那张卡列的是同一份列表。
    ///
    /// 按"这台机器上装了"过滤在 `PlayerAutomationPermissions.visiblePlayers` 里 ——
    /// 没装的播放器给不出权限,摆出来就是一行永远修不好的「未授权」。
    private var automationTargets: [PlaybackPlayer] {
        automation.visiblePlayers(for: features.players)
    }

    /// 「让它跑起来」那一页上已经授权了几项(自动化权限每家一项、完全磁盘访问一项、辅助功能一项)。
    /// 只在那一页计数,其余页恒 0 —— 供「授权完把窗口带回前台」用。
    private var grantedPermissionCount: Int {
        guard currentStep == .background else { return 0 }
        let automationGranted = automationTargets.filter { automation.status($0) == .authorized }.count
        let fdaTargets = fullDiskAccessTargets
        let fdaGranted = !fdaTargets.isEmpty && fullDiskAccess.grant(fdaTargets) == .granted
        let axGranted = !accessibilityTargets.isEmpty && accessibility.trusted
        return automationGranted + (fdaGranted ? 1 : 0) + (axGranted ? 1 : 0)
    }

    /// 那一页要的权限是不是都给了(不用再轮询)。
    private var allPermissionsGranted: Bool {
        grantedPermissionCount == automationTargets.count + (fullDiskAccessTargets.isEmpty ? 0 : 1)
            + (accessibilityTargets.isEmpty ? 0 : 1)
    }

    /// 收尾页实时状态要的那几个属性,合成一个去重后的发布者。不整个订阅协调器(理由见 `isPlayingNow`)。
    @MainActor private static let liveInputs: AnyPublisher<OnboardingFlow.LiveInput, Never> = {
        let c = PlaybackCoordinator.shared
        return Publishers.CombineLatest4(c.$title, c.$displayArtist, c.$hasLyricsContent, c.$isCurrentTrackInstrumental)
            .combineLatest(Publishers.CombineLatest3(c.$currentTrackHasNoLyrics, c.$isCurrentTrackAdBreak,
                                                     c.$engineNetworkDown))
            .map { track, flags in
                OnboardingFlow.LiveInput(title: track.0, artist: track.1, hasLyrics: track.2,
                                         instrumental: track.3, noLyrics: flags.0,
                                         adBreak: flags.1, networkDown: flags.2)
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }()

    /// 这一轮要替哪几家要「完全磁盘访问」—— 跟设置页那张卡同一份列表(选中 ∩ 需要 ∩ 装了)。
    private var fullDiskAccessTargets: [PlaybackPlayer] {
        fullDiskAccess.visiblePlayers(for: features.players)
    }

    /// 这一轮要替哪几家要「辅助功能」—— 跟设置页那张卡同一份列表(选中 ∩ 需要 ∩ 装了)。
    private var accessibilityTargets: [PlaybackPlayer] {
        accessibility.visiblePlayers(for: features.players)
    }

    // 这份列表本身不 @State,是纯粹从 features.players / wantsBrowserYouTubeMusic 派生出来
    // 的,它们一变下一次读到的就是新列表,不需要额外同步。
    private var steps: [Step] {
        OnboardingFlow.steps(flowConditions)
    }

    private var flowConditions: OnboardingFlow.Conditions {
        .init(wantsBrowserPairing: wantsBrowserYouTubeMusic)
    }

    /// 当前这一步。**所有地方都必须走这个访问器,不准再写 `steps[step]`**:
    /// `features.players` 是 `@Published`,设置窗口能同时开着改它、让 `steps` 变短,
    /// 渲染这一刻 `step` 可能已经越界(见 14 章首启引导「`steps[step]` 越界」)。
    ///
    /// 两道防线都要有:这个访问器保证**渲染这一刻**不会越界(SwiftUI 重算 body 可能早于
    /// 任何 onChange),下面 `.onChange(of: steps.count)` 负责把 `step` 这个存储值本身拉回
    /// 合法区间(否则"上一步/下一步"的加减法会从一个非法下标继续往下算)。
    private var currentStep: Step {
        OnboardingFlow.step(at: step, in: steps)
    }

    private var isLastStep: Bool { step >= steps.count - 1 }

    /// 「下一步」现在被锁住了没有。
    ///
    /// 只剩 `.background` 一条。`.automation` 从这里**移出去**了,理由是它的
    /// 前提本身站不住:基础的"在播什么"来自 media-control 通道,自动化权限管的是
    /// 进度精度和整套播放/资料库控制 —— 没有它歌词照样显示。多选之后更明显:勾了
    /// Apple Music + Spotify 的人,被一个只对其中一个播放器有意义的权限挡在原地。
    ///
    /// 那次把 automation 加进锁里,是为了治"用户误点了不允许还能一路走完、
    /// doneStep 却说一切就绪"。那个病根现在由 `doneStep` 的体检清单如实报告(见那边),
    /// 不需要再靠锁死按钮来兜。
    private var nextIsLocked: Bool {
        OnboardingFlow.nextIsLocked(at: currentStep, engineRunning: engineRunning)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 这一层 ScrollView 是**溢出兜底**,不是"让内容可以随便长"。
            //
            // 窗口固定 480×500、不可拖拽(App.swift 的 .windowResizability(.contentSize)),
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
                    case .browserPairing: browserPairingStep
                    case .background: backgroundStep
                    case .displayMode: displayModeStep
                    case .done: doneStep
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)

            Divider()

            HStack {
                stepDots
                Spacer()
                // 必需步骤被锁住时的**出口**。在此之前"仍然可以直接关掉整个
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
                        .controlSize(.large)
                        .settingsGlassButtons()
                }
                Button(isLastStep ? L10n.t("开始使用") : L10n.t("下一步")) {
                    if isLastStep {
                        finish()
                    } else {
                        goTo(step + 1)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .settingsProminentGlassButton(tint: .accentColor)
                // 判据收在 `nextIsLocked` 里一处(那边记着 automation 为什么被移出去)。
                // 仍然是"软强制":只锁这一个按钮,不禁用/隐藏窗口的关闭按钮,而且旁边现在
                // 有一个显式的「暂时跳过」。
                .disabled(nextIsLocked)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 480, height: 500)
        // 整扇窗的玻璃底(macOS 26+ 液态玻璃、窗口透明,旧系统磨砂材质),伸进标题栏那一截(窗口是
        // `.hiddenTitleBar`,见 App.swift),从窗顶一直铺到窗底;内容本身仍在安全区内,不会跑到红绿灯底下。
        .onboardingWindowBackground()
        // 撒花盖在**整扇窗**上(叠在 `.frame` 之后,所以它正好是窗口那么大):纸片会从进度点和
        // 「开始使用」上面落过去,而不是只落在上面那块内容区里 —— 后者在这个 500pt 高的窗口里
        // 看着像"纸片撞在一条看不见的线上"。它自己从不吃点击,按钮照常能按(见 ConfettiOverlay)。
        .overlay { ConfettiOverlay(burst: confettiBurst) }
        // 窗口标题跟着界面语言走。App.swift 里 `Window(L10n.t("欢迎使用 Lyrimuse"), id:)`
        // 的那个标题在 scene 构造时**只求值一次**,用户在第一步把语言切成英文之后它还是
        // 中文;`.navigationTitle` 每次重算 body 都会重新应用,正好补上这一处。
        .navigationTitle(L10n.t("欢迎使用 Lyrimuse"))
        // 见 `currentStep` 头注:这一条负责把 `step` 这个**存储值**拉回合法区间(设置窗口
        // 同时开着、改了播放器集合时 steps 会变短)。渲染那一刻的安全由 currentStep 兜。
        .onChange(of: steps.count) { _, newCount in
            let fixed = OnboardingFlow.clamped(.init(step: step, furthest: furthestStep), stepCount: newCount)
            if step != fixed.step { step = fixed.step }
            if furthestStep != fixed.furthest { furthestStep = fixed.furthest }
        }
        // 走到"体检"和"后台服务"这两步时重新读一次真实状态 —— 用户可能刚在系统设置里
        // 给了权限、或者从别处把服务装上了,清单必须反映此刻的事实而不是进门时的快照。
        // 只在这两步做,不是每步都做:`EngineServiceManager.isRunning` 要起一次
        // `launchctl print` 子进程,没必要在每次翻页都付这个钱。
        .onChange(of: step) { _, _ in
            guard currentStep == .done || currentStep == .background else { return }
            automation.refresh(automationTargets)
            accessibility.refresh()
            let arrivedAt = currentStep
            Task {
                await refreshEngineRunning()
                // 查状态的这一会儿又翻走了:别在别的页面上起安装。
                guard currentStep == arrivedAt else { return }
                // 走到这一步就开始装,页面照样显示安装过程和结果(不在 App 启动时静默装)。
                if OnboardingFlow.autoStartsBackgroundService(
                    at: currentStep, engineRunning: engineRunning,
                    installing: isTogglingEngineService, lastAttemptFailed: engineFailure != nil) {
                    enableEngineService()
                }
            }
        }
        // 走到最后一页就撒一阵花。判据挂 `currentStep` 而不是 `step`:最后一页的
        // **下标**会因为设置窗口同时改播放器集合而变(见 `currentStep` 头注),而"到了 .done
        // 这一步"才是要庆祝的那件事。`onChange` 只在值真变了时触发,所以停在这一页不会反复
        // 重放;退回去再翻回来会再撒一阵(那是用户主动重新走到终点)。
        .onChange(of: currentStep) { _, new in
            if new == .done { confettiBurst += 1 }
            if new == .done || new == .background { fullDiskAccess.refresh() }
        }
        // 「完全磁盘访问」的状态文件由引擎写,不会推通知过来;只在用得到它的两步轮询
        // (按 mtime 读,很便宜)。
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            // 服务没跑起来的时候,用户多半正照着失败文案去设置里「播放器 → 歌词引擎」修:修好了这里要跟着变绿、
            // 放开「下一步」,收尾页点「开始使用」也要能记成走完。跑起来之后就不用再问了。
            if (currentStep == .background || currentStep == .done), !engineRunning, !isTogglingEngineService {
                Task { await refreshEngineRunning() }
            }
            switch currentStep {
            case .done:
                fullDiskAccess.refresh()
                accessibility.refresh()
            // 用户可能去系统设置里手动开,窗口不在前台时收不到「切回来」那次刷新。
            case .background where !allPermissionsGranted:
                if !fullDiskAccessTargets.isEmpty { fullDiskAccess.refresh() }
                if !accessibilityTargets.isEmpty { accessibility.refresh() }
                if !automationTargets.isEmpty { automation.refresh(automationTargets) }
            default: break
            }
        }
        // 在系统设置里授权完、窗口还在后面时,把引导带回前台(只在已授权的项多了一项的那一刻)。
        .onChange(of: grantedPermissionCount) { before, now in
            if OnboardingFlow.bringsBackAfterGrant(grantedBefore: before, grantedNow: now,
                                                   appIsActive: NSApp.isActive) {
                AppActions.shared.openOnboarding?()
            }
        }
        .onReceive(Self.liveInputs) { liveInput = $0 }
        .onAppear {
            automation.refresh(automationTargets)
            Task { await refreshEngineRunning() }
            // 「YouTube Music」那一格的选中态按**当前真实配置**播种:已经配过
            // 浏览器的人重跑引导时,那一格该是亮的、后面那一步也该在,而不是让他重新勾一遍。
            // 这也是这个布尔不需要自己持久化的原因(见它的声明处)。
            wantsBrowserYouTubeMusic = BrowserPairing
                .hasAnyPair(platformID: Self.youTubeMusicPlatformID)
        }
        // 用户点"请求权限"之后可能会切到系统设置面板手动处理(尤其是等超时了、
        // 走"打开系统设置"这条备选路径的时候),切回来时重新读一次最新状态——不然
        // 界面会一直卡在切出去之前的旧状态,像是"我明明点了允许,这里怎么还没变"。
        // `clearRequestUI` 顺带把"正在等待"那套收掉:已经确定不再是 notDetermined 时还
        // 留着转圈/超时提示,就是状态文字说已授权、下面却还在等,两处互相矛盾。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            automation.refresh(automationTargets, clearRequestUI: true)
            accessibility.refresh()
            Task { await refreshEngineRunning() }
        }
        .onReceive(PlaybackCoordinator.shared.$isPlayingNow.removeDuplicates()) { playing in
            isPlayingNow = playing
        }
        // 这里原来挂着 `.onDisappear { settings.hasCompletedOnboarding = true }`,
        // 也就是"不管走没走完(包括直接点红绿灯关窗)都算引导过了"。去掉。
        //
        // 那个行为会造成一条不可自愈的死路:常驻服务默认不装,而歌词全部来自引擎
        // 写在磁盘上的缓存(见 LocalPlaybackSource 顶部注释)—— 第一步就关窗的用户,
        // 服务没装、引导又被标记成"已完成"再也不会出现,于是桌面上留着一个永远停在
        // "搜索歌词中…"的悬浮窗,而他没有任何入口把服务装起来。
        //
        // 现在 hasCompletedOnboarding 只由 finish() 置位(= 真的走到最后一步)。关窗
        // 等于"稍后再说",下次启动会再问一次;而已经走完的人可以从菜单栏的
        // "重新运行引导…"随时再来一遍。
        // 见 AuxiliaryWindowActivation 注释——只记账,不碰 Dock 图标。
        .onAppear { AuxiliaryWindowActivation.windowDidAppear("onboarding") }
        .onDisappear { AuxiliaryWindowActivation.windowDidDisappear("onboarding") }
    }

    /// 进度指示。补了三件事:
    ///  ① **一个"第几步/共几步"的数字** —— 步数按所选播放器动态算,最多能到 10 个点,光靠
    ///     数点数不出来自己走到哪了。
    ///  ② **走过的点可以点回去**。只允许回到 `furthestStep` 以内:往前跳会绕过必需步骤
    ///     那道锁(`nextIsLocked`),而 `furthestStep` 只由「下一步」/「暂时跳过」推进,
    ///     这两条路本身是受控的。
    ///  ③ 无障碍:整块合成一个元素并报出"第 N 步,共 M 步",否则旁白读到的是一串无意义的
    ///     圆点。
    ///
    /// 当前这一步拉长成 16pt 的胶囊,走过的点是淡强调色、没走到的是灰 —— 不数点也看得出位置。
    /// 数字写成紧凑的「2/8」(不带空格,斜杠两侧的空隙会让它看起来跟圆点脱节),跟圆点之间只隔 8pt。
    private var stepDots: some View {
        HStack(spacing: 8) {
            // 命中区靠**外扩一层 frame**做,不是 `.contentShape(Rectangle().size(…))`。
            // 后者构造的矩形从这个视图的原点(圆点左上角)往右下铺,而不是以圆点为中心 ——
            // 命中区整体偏移并盖到相邻那个点头上,几个点的命中区互相重叠之后"点第 N 个却跳到
            // 第 N±1 步"。外层 frame 比圆点宽 6pt + spacing 0:视觉间距 6pt,命中区互不重叠。
            HStack(spacing: 0) {
                ForEach(0..<steps.count, id: \.self) { i in
                    let dotWidth: CGFloat = i == step ? 16 : 6
                    Capsule()
                        .fill(i == step ? Color.accentColor
                              : i <= furthestStep ? Color.accentColor.opacity(0.35)
                              : Color.secondary.opacity(0.3))
                        .frame(width: dotWidth, height: 6)
                        .frame(width: dotWidth + 6, height: 12)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if OnboardingFlow.canJump(toDot: i, furthest: furthestStep) { goTo(i) }
                        }
                }
            }
            .animation(.easeOut(duration: 0.2), value: step)
            // `.fixedSize()` 不能省:不钉住的话,这一行分宽时会把这段数字压到一个字宽、逐字竖排
            // (10 步 + 大号按钮时实测出现),连带把底栏撑高、把上面的内容区挤矮。
            Text("\(step + 1)/\(steps.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            format: L10n.t("第 %1$d 步，共 %2$d 步"), step + 1, steps.count))
    }

    // 语言选择并在这一页,不再是后面单独的一步。`L10n.t` 每次调用都重新解析
    // 语言(见 L10n.swift 里"不缓存"那段),所以在这里一改,**从下一步开始整个向导都是新
    // 语言** —— 而它原来排在第 6 步,前 5 步早就用错的语言讲完了。
    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text(L10n.t("欢迎使用 Lyrimuse"))
                .font(.title.bold())
            Text(touchBar.isPresent
                 ? L10n.t("随正在播放的歌曲显示歌词，可显示在桌面、灵动岛、菜单栏、触控栏和歌词窗口中，并支持对照译文与标注读音。接下来几步将完成基本设置，之后可随时在设置中更改")
                 : L10n.t("随正在播放的歌曲显示歌词，可显示在桌面、灵动岛、菜单栏和歌词窗口中，并支持对照译文与标注读音。接下来几步将完成基本设置，之后可随时在设置中更改"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // 两个跟「这台 Mac 上怎么用它」有关的偏好:界面语言、开机启动。
            VStack(alignment: .leading, spacing: 0) {
                setupRow(icon: "globe", tint: .secondary, title: L10n.t("界面语言"), subtitle: nil) {
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
                setupDivider
                setupRow(icon: "power", tint: .secondary, title: L10n.t("开机时自动启动 Lyrimuse"), subtitle: nil) {
                    // 标题传给开关本身再 labelsHidden:视觉不变,旁白读得出这是哪个开关。
                    Toggle(L10n.t("开机时自动启动 Lyrimuse"), isOn: $settings.launchAtLoginEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
            .onboardingCard()
            // 一句不阻断的告知 + 链接,正文在 README(见 LegalNotices 头注),设置「关于」页
            // 还有同一个入口。刻意**不做**阻断式的「接受」页:引导的原则是介绍性内容不锁下一步,GPL 个人
            // 工具也没有需要「接受」的条款 —— 「接受版本号存偏好」那套是分发渠道场景的产物。
            HStack(spacing: 4) {
                Text(L10n.t("继续即表示你已了解"))
                    .foregroundStyle(.secondary)
                Button(L10n.t("版权说明")) { LegalNotices.openUsageNotice() }
                    .buttonStyle(.link)
            }
            .font(.callout)
        }
    }

    /// 标题问句 + 一句交代 Lyrimuse 跟着谁显示歌词;下面是装在一张淡玻璃卡里的 `PlayerPicker`
    /// (设置页那边包的是 `SettingsCard`,两处卡里的内容是同一个组件)。这一页不放设置页底下那行
    /// 「自动识别」说明:卡片上指向就能读到同一句提示。
    private var playerChoiceStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.t("选择播放器"))
                .font(.title2.bold())
            // 这句不逐个列播放器名:网格里的卡片就是完整清单,文案里再列一遍每加一家就得回来改。
            Text(L10n.t("Lyrimuse 将显示正在播放的 App 的歌词，之后可随时在设置中更改"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            // 图标网格(「自动识别」是其中一张卡)跟设置页「播放器」卡是同一个组件(PlayerPicker),两处必须长得一样。
            // 网格只摆装了的播放器,没装的收进「更多播放器」,摆放规则见 PlayerPickerLayout。
            //
            // YouTube Music 追加在播放器卡后面:它不是 `PlaybackPlayer` 的 case(理由见
            // `WebPlatformChoiceCard` 头注),点它**不会**立刻跳去选浏览器,只是让后面多出一步
            // `.browserPairing`。它走的是浏览器配对那套状态,跟「自动识别」那张卡无关,勾没勾它都能点。
            PlayerPicker(features: features) {
                WebPlatformChoiceCard(
                    icon: WebPlatformIcon.image(Self.youTubeMusicPlatformID),
                    title: "YouTube Music",
                    isSelected: wantsBrowserYouTubeMusic
                ) {
                    toggleYouTubeMusic()
                }
            }
            .padding(14)
            .onboardingCardBackground(cornerRadius: 14, fallbackFill: Color.primary.opacity(0.035),
                                      fallbackStroke: Color.primary.opacity(0.08))
            .padding(.top, 16)
        }
    }

    /// 勾/取消「YouTube Music」那一格。**取消是非破坏性的:只收起后面那一步,不动任何配对。**
    ///
    /// 取消勾选时**绝不能**把这个平台
    /// **已配对的浏览器全部 unpair 掉**。"否则格子看着没选、配对还在,状态说
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
        // 只会砍掉 index 1 之后的项,见 `OnboardingFlow.steps` 头注里条件步的位置约束。
    }

    /// 「配对浏览器」这一步。只在上一步勾了 YouTube Music 时出现。
    ///
    /// 为什么单独一步、而不是在勾选那一刻就地展开:"选了之后先不进行选择
    /// 浏览器,引导在后面选择浏览器"。选播放器那一步回答的是"你平时用什么听歌",配哪个
    /// 浏览器是另一个话题;塞在同一格里还会让那个网格在点击后突然长高。
    ///
    /// 配对动作走 `BrowserPairing.trustAndPair` —— 跟设置页「网页播放器」卡**同一份**
    /// 实现(那个函数体里的顺序是好几轮实测结论,见它的头注)。这一步不传 `revealPairing`:
    /// 设置页用它展开权限气泡,而这里两道门的说明本来就摊在页面上,没有气泡要开。
    ///
    /// 这一步**不**代劳授权。`trustAndPair` 只在那个浏览器已经在跑时顺手问一次系统
    /// 自动化授权(理由见它的头注),没在跑就留给用户之后自己处理 —— 引导里不该为了"把
    /// 流程走完"去后台拉起用户的浏览器抢焦点。所以这一步也**不锁下一步按钮**(跟
    /// `.lastfm` 同一档:介绍 + 可选动作,不是必需步骤),配不配得成都能往下走。
    private var browserPairingStep: some View {
        let platformID = Self.youTubeMusicPlatformID
        // **一份顺序固定的候选列表,不按"已配对/未配对"分两组渲染**。
        //
        // 分两组渲染(`ForEach(paired)` 在前、`ForEach(addable)` 在后)的问题:点一下会让
        // 那张卡**从一组跳到另一组、在网格里换位置**,跟选中态的视觉变化混在一起,反而看不出
        // 点击本身有没有生效。
        //
        // 改成一份稳定列表之后,点击的唯一视觉变化就是那张卡自己的选中态,位置不动。
        let candidates = BrowserPairing.candidateBrowsers(platformID: platformID)
        return VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("YouTube Music 使用哪个浏览器？"))
                .font(.title2.bold())
            Text(L10n.t("YouTube Music 在浏览器中播放，Lyrimuse 需要知道是哪个浏览器才能读取播放进度。请选择常用的浏览器（可多选），随后系统会请求授权，选择允许即可；之后可在设置的「网页播放器」中更改"))
                .foregroundStyle(.secondary)
            if candidates.isEmpty {
                // 默认候选一个都没有。实践中几乎进不来这个分支(macOS 上 Safari 恒存在,
                // 而 `candidateBrowsers` 只过滤"装没装"),留着是因为它比一个空网格诚实。
                //
                // 这句原来写的是「Safari、Chrome、Edge、**Arc** 这类」—— 那跟
                // 的产品决定正好相反:Arc 被有意从 `knownBrowserBundleIDs` 里拿掉了(适配
                // 全留着,只是不默认展示,见那边头注),点名它等于承诺一个这里不会出现的选项。
                // 改成如实说明"默认只列这几个,别的自己挑",正好接上下面那个按钮。
                Text(L10n.t("未在这台 Mac 上找到默认列出的浏览器（Safari、Chrome、Edge）。其他浏览器可通过下方的「从应用程序中选择…」添加"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(candidates, id: \.self) { bundleID in
                        browserCard(bundleID: bundleID, platformID: platformID)
                    }
                }
                // 这里**曾经**有一行小字「亮起来的就是已经配好的；再点一下取消」,
                // 同日加上又被去掉("去掉这个文案")。加它的理由是:点一张
                // 已经亮着的卡做的是取消配对,而正文邀请的是"选",怕用户误删(那天确实误删过
                // 一次,配对被删空、靠会话记录恢复的)。不要,取舍归他 —— 记在这里是
                // 为了下次别有人"好心"再加回来:真正治那次误删的是上面那两条改动(一份稳定
                // 列表不换位置 + 取消勾选不再批量删配对,两条都有 selftest 闸钉着),
                // 这行小字只是补充说明,不是那个 bug 的修复本体。
            }
            // 「从应用程序中选择…」。在此之前引导页只铺得出
            // `knownBrowserBundleIDs` 里装了的那几个(Chrome / Edge / Brave / Safari),而
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
            L10n.t("无法使用该应用"),
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
        // 选中态**现读**,不从外面传 —— 把 `isPaired` 当参数传进来的话,要求调用点
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

    /// 「让它跑起来」这一页:一张卡片里的一组状态行 —— 歌词引擎(必装,走到这一页自动开始装),
    /// 以及按需出现的每家播放器自动化权限、完全磁盘访问、辅助功能。每行只写名称和状态,需要处理时才出现
    /// 按钮;两项权限各有什么用收在卡片下面。开机启动是偏好不是要核对的状态,放在欢迎页。
    ///
    /// 歌词引擎和开机启动**不是同一件事**:引擎是独立的 launchd job(KeepAlive,装上
    /// 之后本来就开机自启),开机启动开关管的是 Lyrimuse 这个 App 自己(`LoginItemManager`)。
    /// 这条区别不写进界面文案。
    ///
    /// 自动化权限走到这一页时多半已经有结果了:选播放器那一下就请求过(`requestOnSelect`),
    /// 这里是核对 + 补救。几项权限都是推荐项,不在 `nextIsLocked` 里。
    private var backgroundStep: some View {
        let fdaTargets = fullDiskAccessTargets
        let axTargets = accessibilityTargets
        return VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t("启用歌词引擎与权限"))
                .font(.title2.bold())
            Text(L10n.t("请启用歌词引擎，并开启以下权限；未开启的权限只影响对应功能"))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                setupRow(icon: engineIcon, tint: engineTint, title: L10n.t("歌词引擎"),
                         subtitle: L10n.t("识别歌曲、查找歌词和封面；仅在本机运行，查找歌词时只发送歌名、歌手等曲目信息")) {
                    engineTrailing
                }
                // 自动启用没起来时的交代:原因 + 出路(按钮已经变成「重试」)。
                if let engineFailure {
                    rowNote(engineFailure, tint: .orange)
                }
                ForEach(automationTargets, id: \.self) { player in
                    setupDivider
                    setupRow(icon: automation.iconName(player), tint: automation.iconColor(player),
                             title: String(format: L10n.t("%@ 自动化权限"), player.displayName),
                             subtitle: automation.caption(player)) {
                        if automation.isRequesting(player) {
                            ProgressView().controlSize(.small)
                        } else if automation.status(player) != .authorized {
                            Button(automation.actionTitle(player)) { automation.handleAction(player) }
                                .controlSize(.small)
                        }
                    }
                    if automation.showsWaitingNote(player) {
                        VStack(alignment: .leading, spacing: 6) {
                            PlayerAutomationWaitingNote(timedOut: automation.hasTimedOut(player))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, Self.setupRowIndent)
                        .padding(.bottom, 8)
                    }
                }
                if !fdaTargets.isEmpty {
                    setupDivider
                    fullDiskAccessRow(fdaTargets)
                }
                if !axTargets.isEmpty {
                    setupDivider
                    accessibilityRow
                }
            }
            .onboardingCard()
            if let note = permissionBenefitNote(fdaTargets, axTargets) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var engineIcon: String {
        if engineRunning { return "checkmark.circle.fill" }
        return isTogglingEngineService ? "circle.dotted" : "xmark.circle.fill"
    }

    private var engineTint: Color {
        if engineRunning { return .green }
        return isTogglingEngineService ? .secondary : .red
    }

    /// 歌词引擎那一行的尾部:在跑只写状态;正在装转圈;没起来才给按钮(自动启用失败后是「重试」)。
    @ViewBuilder
    private var engineTrailing: some View {
        if engineRunning {
            Text(L10n.t("运行中"))
                .foregroundStyle(.secondary)
        } else if isTogglingEngineService {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.t("正在启用…"))
                    .foregroundStyle(.secondary)
            }
        } else {
            Button(engineFailure == nil ? L10n.t("启用") : L10n.t("重试")) { enableEngineService() }
                .controlSize(.small)
        }
    }

    /// 完全磁盘访问那一行。没授权时行尾「打开系统设置」,下面一句怎么生效 +「重启歌词引擎」
    /// (授权对已经在跑的歌词引擎不生效);授权后只剩状态。动作本体在 `FullDiskAccessPermission`。
    @ViewBuilder
    private func fullDiskAccessRow(_ targets: [PlaybackPlayer]) -> some View {
        let granted = fullDiskAccess.grant(targets) == .granted
        setupRow(icon: fullDiskAccess.iconName(targets), tint: fullDiskAccess.iconColor(targets),
                 title: L10n.t("完全磁盘访问权限"), subtitle: fullDiskAccess.caption(targets)) {
            if fullDiskAccess.restartPhase == .waiting {
                ProgressView().controlSize(.small)
            } else if !granted {
                Button(L10n.t("打开系统设置")) { fullDiskAccess.openSystemSettings() }
                    .controlSize(.small)
            }
        }
        if !granted {
            VStack(alignment: .leading, spacing: 4) {
                switch fullDiskAccess.restartPhase {
                case .waiting:
                    Text(L10n.t("正在重启歌词引擎并重新检查授权…"))
                case .stillDenied:
                    Text(L10n.t("歌词引擎已重启，但仍无法读取。请在系统设置的「完全磁盘访问权限」中确认 Lyrimuse 已开启。"))
                        .foregroundStyle(Color.orange)
                case .idle:
                    Text(L10n.t("授权不会作用于已在运行的歌词引擎。在系统设置中勾选后，请回到此处点按「重启歌词引擎」。"))
                }
                // 歌词引擎没在跑(没装上、被跳过)或者正在装的时候不给这颗按钮:重启一个不存在的服务只会白转圈,
                // 跟正在进行的安装撞在一起还可能互相杀掉对方刚拉起的进程。
                if fullDiskAccess.restartPhase != .waiting, engineRunning, !isTogglingEngineService {
                    Button(L10n.t("重启歌词引擎")) {
                        Task { await fullDiskAccess.restartEngine(for: targets) }
                    }
                    .buttonStyle(.link)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, Self.setupRowIndent)
            .padding(.bottom, 10)
        }
    }

    /// 辅助功能那一行。没授权时行尾「请求权限」(弹过一次之后是「打开系统设置」),下面一句怎么补救;
    /// 授权后只剩状态。动作本体在 `AccessibilityPermission`。
    @ViewBuilder
    private var accessibilityRow: some View {
        setupRow(icon: accessibility.iconName, tint: accessibility.iconColor,
                 title: L10n.t("辅助功能权限"), subtitle: accessibility.caption) {
            if !accessibility.trusted {
                Button(accessibility.actionTitle) { accessibility.handleAction() }
                    .controlSize(.small)
            }
        }
        if !accessibility.trusted, accessibility.prompted {
            Text(L10n.t("请在系统设置的「辅助功能」中开启 Lyrimuse。如已授权但此处仍显示未授权，请将 Lyrimuse 取消勾选后重新勾选。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Self.setupRowIndent)
                .padding(.bottom, 10)
        }
    }

    /// 卡片下面那几句:只讲这一轮真的出现了的权限各有什么用。完全磁盘访问那句按引擎实际读的
    /// 路径写(只读这几家在 ~/Library/Containers 下的歌词缓存与播放队列,localcachefs.go 头注);
    /// 别写「不上传」:开了网页中继时当前歌词会推到用户自己的服务器。
    private func permissionBenefitNote(_ fdaTargets: [PlaybackPlayer], _ axTargets: [PlaybackPlayer]) -> String? {
        var lines: [String] = []
        let refineTargets = automationTargets.filter { $0.automationUse == .refinesProgress }
        if !refineTargets.isEmpty {
            lines.append(String(format: L10n.t("自动化权限可让%@的播放进度更准确，并可在歌词上直接控制播放"),
                                automation.playerNames(refineTargets)))
        }
        let trackTargets = automationTargets.filter { $0.automationUse == .readsTrack }
        if !trackTargets.isEmpty {
            lines.append(String(format: L10n.t("自动化权限可让 Lyrimuse 准确识别%@正在播放的歌曲，并可在歌词上直接控制播放"),
                                automation.playerNames(trackTargets)))
        }
        if !fdaTargets.isEmpty {
            lines.append(String(format: L10n.t("完全磁盘访问权限可让%@直接使用本机已有的歌词，仅读取其歌词缓存和播放队列"),
                                fullDiskAccess.playerNames(fdaTargets)))
        }
        let progressTargets = axTargets.filter { $0.accessibilityUse == .calibratesProgress }
        if !progressTargets.isEmpty {
            lines.append(String(format: L10n.t("辅助功能权限可让%@的播放进度更准确，仅读取其界面上的播放时间"),
                                accessibility.playerNames(progressTargets)))
        }
        let playModeTargets = axTargets.filter { $0.accessibilityUse == .switchesPlayMode }
        if !playModeTargets.isEmpty {
            lines.append(String(format: L10n.t("辅助功能权限可显示%@的随机、循环键，点按时会操作其菜单栏"),
                                accessibility.playerNames(playModeTargets)))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// 卡片里的一行:左侧内容(固定宽度,几行的标题对齐在同一条竖线上)+ 名称(+ 一行小字)+ 尾部控件。
    private static let setupRowIndent: CGFloat = 30

    private func cardRow<Leading: View, Trailing: View>(
        leadingWidth: CGFloat = 20, title: String, subtitle: String?,
        @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            leading()
                .frame(width: leadingWidth)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 9)
    }

    /// 左侧是一个 SF Symbol 的卡片行。
    private func setupRow<Trailing: View>(icon: String, tint: Color, title: String, subtitle: String?,
                                          @ViewBuilder trailing: () -> Trailing) -> some View {
        cardRow(title: title, subtitle: subtitle) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .environment(\.locale, Locale(identifier: "en"))
        } trailing: {
            trailing()
        }
    }

    private func cardDivider(indent: CGFloat) -> some View {
        Divider().padding(.leading, indent)
    }

    private var setupDivider: some View {
        cardDivider(indent: Self.setupRowIndent)
    }

    private func rowNote(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, Self.setupRowIndent)
            .padding(.bottom, 8)
    }

    /// 「歌词怎么显示」页的下半部分:译文与罗马音。这是这个 App 对中日韩听众最核心的能力之一
    /// (设置里「歌词 → 译文/效果」整整两卡),介绍性质、不锁「下一步」。
    ///
    /// 这里只放「显示译文」「显示读音」两个开关,不放"标注读音的语言"那一排。那几个走的是
    /// `romanizationScripts` 的**双写**(AppSettings 持久化 + LocalPlaybackSource 让当前这首
    /// 歌立刻重新解析,见 SettingsView.romanizationToggle 的头注),只写一边就会出"改了要等
    /// 下一首才生效"这种错位 —— 引导页照抄一份等于给那条约束开第二个漂移点。默认值
    /// (`RomanizationScripts.defaultScripts(chineseUI:)`,跟界面语言走)对绝大多数人本来就是对的,细调留给设置页。
    ///
    /// 两个开关同时设悬浮歌词和歌词窗口两份(之后在「歌词显示」里各自改,见 `overlayAndWindow`);灵动岛、菜单栏
    /// 和触控栏的译文 / 罗马音走各自的「副行」(`LyricSecondaryLine`),不受这两个开关影响,页脚那句据此写
    /// (触控栏只在这台 Mac 有触控栏时提)。
    private var lyricsExtrasSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                toggleRow(
                    icon: "text.bubble",
                    title: L10n.t("显示译文"),
                    subtitle: L10n.t("在歌词下方显示一行译文"),
                    isOn: overlayAndWindow(\.overlayShowTranslation, \.showTranslation))
                toggleRow(
                    icon: "textformat.alt",
                    title: L10n.t("显示读音"),
                    subtitle: settings.romanizationScripts.contains(.chinese)
                        ? L10n.t("默认为日文、韩文、中文和粤语标注读音，可在设置中按语言关闭")
                        : L10n.t("默认为日文、韩文和粤语标注读音，普通话拼音可在设置中开启"),
                    isOn: overlayAndWindow(\.overlayShowRomanization, \.showRomanization))
            }
            Text(touchBar.isPresent
                 ? L10n.t("这两个开关作用于悬浮歌词和歌词窗口；灵动岛、菜单栏和触控栏可在各自的「副行」中选择译文或读音")
                 : L10n.t("这两个开关作用于悬浮歌词和歌词窗口；灵动岛和菜单栏可在各自的「副行」中选择译文或读音"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // 这几种显示形态在代码里完全正交(各自独立的开关 + 各自独立的控制器,可以同时开、
    // 也可以一个都不开),所以这里是几个独立开关,不是单选 Picker。触控栏那一行只在这台 Mac
    // 有触控栏时出现,开关直接绑设置:`TouchBarLyricsController` 自己订阅 `showLyricsInTouchBar`
    // 启停,所以下面第 1、2 条(两个窗口控制器)管不到它,第 3 条(不替用户预选)同样适用。
    // 见 17 章决策 32。"歌词窗口"刻意不放进来:它不是常驻的显示方式,而是一扇按需打开的窗口
    // (下次启动按上次退出时开没开重开),在向导里打开只会弹一扇窗盖住向导本身。
    //
    // 三条必须守住的写法约束:
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
    //    实测拨动开关。
    //
    // 还有一条口味上的约束(**不再是安全前提**):`steps` 的长度由 `features.players`
    // 和 `wantsBrowserYouTubeMusic` 两个值决定,所以能改它们的控件最好只留在 index 1
    // (playerChoiceStep),否则用户会看到进度点在脚下变长变短。
    //
    // 这条原来写的是"必须永不出现,因为 steps[step] 没有越界守卫" —— 那个论证
    // 被推翻了:它默认"引导页是唯一宿主",而设置窗口能同时开着改 `features.players`
    // (`@Published`),引导页自己的 .lastfm 那一步还有个按钮专门去开设置窗。真正的守卫现在
    // 是 `currentStep` + `.onChange(of: steps.count)` 那一对,详见 `currentStep` 头注。
    private var displayModeStep: some View {
        // 段间距比别的步骤紧(12 不是 16):有触控栏时这一步多一行,这样中文下四行也放得进窗口。
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("选择歌词显示方式"))
                .font(.title2.bold())
            Text(L10n.t("以上方式可同时开启，请先选择当前需要的，之后可随时在设置中分别开关"))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                displayModeRow(
                    kind: .classic,
                    title: L10n.t("桌面悬浮歌词"),
                    subtitle: L10n.t("显示在桌面上"),
                    isOn: Binding(
                        get: { settings.classicOverlayEnabled },
                        set: { LyricsOverlayWindowController.shared.setVisible($0) }))
                displayModeRow(
                    kind: .notch,
                    title: L10n.t("灵动岛歌词"),
                    subtitle: hasNotchedScreen
                        ? L10n.t("紧贴屏幕顶部的刘海显示")
                        : L10n.t("这台 Mac 无刘海，将显示在屏幕顶部中央"),
                    isOn: Binding(
                        get: { settings.notchOverlayEnabled },
                        set: { NotchLyricsWindowController.shared.setVisible($0) }))
                displayModeRow(
                    kind: .menuBar,
                    title: L10n.t("菜单栏歌词"),
                    subtitle: L10n.t("在菜单栏中显示一行歌词"),
                    isOn: $settings.showLyricsInMenuBar)
                if touchBar.isPresent {
                    displayModeRow(
                        kind: .touchBar,
                        title: L10n.t("触控栏歌词"),
                        subtitle: L10n.t("功能栏中的图标，轻点即可展开歌词"),
                        isOn: $settings.showLyricsInTouchBar)
                }
            }

            // 这两条提示**互斥**,任何时候最多出现一条 —— 窗口固定 480×500,两条同时出现会把这一步
            // 顶出窗口(超出时外层只是滚动兜底,见 body 头注)。全关时"等播起来才看得到"也没意义了,
            // 所以警告优先。
            if noDisplayModeEnabled {
                displayModeNote(
                    icon: "exclamationmark.triangle.fill",
                    tint: .orange,
                    text: L10n.t("以上方式均已关闭，播放时不会显示歌词。可随时通过菜单栏图标重新开启"))
            } else if !isPlayingNow {
                displayModeNote(
                    icon: "info.circle.fill",
                    tint: .secondary,
                    text: touchBar.isPresent
                        ? L10n.t("当前未在播放。桌面悬浮歌词会立即显示，灵动岛、菜单栏和触控栏歌词将在开始播放后显示")
                        : L10n.t("当前未在播放。桌面悬浮歌词会立即显示，灵动岛和菜单栏歌词将在开始播放后显示"))
            }
            Divider()
            lyricsExtrasSection
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

            // 必须显式 .toggleStyle(.switch):macOS 上 Toggle 默认画成**复选框**,只有
            // 放在 Form/List 里才会自动变成右侧胶囊开关。设置页是靠 SettingsRow 统一挂了
            // 这一句(Settings/SettingsDesignSystem.swift:346),向导里没有那个祖先,不写
            // 就是一排复选框,不报错也不崩,只是长得跟设置页对不上。
            // 标题传给开关本身再 labelsHidden:视觉不变,旁白读得出这是哪个开关。
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    /// 引导页的「显示译文」「显示读音」一次设悬浮歌词和歌词窗口两份(04 章决策 42),读悬浮歌词那份。
    private func overlayAndWindow(_ overlay: ReferenceWritableKeyPath<AppSettings, Bool>,
                                  _ window: ReferenceWritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: overlay] },
                set: { settings[keyPath: overlay] = $0; settings[keyPath: window] = $0 })
    }

    /// 带 SF Symbol 的一行开关。`displayModeRow` 是它的姐妹 —— 那边左边是手绘示意图,因为
    /// "灵动岛"光靠一枚符号解释不了它会出现在屏幕的哪个位置;这一批(开机启动、译文、罗马音)
    /// 没有那个问题,用符号就够了。
    ///
    /// 同样必须显式 `.toggleStyle(.switch)`:macOS 上 Toggle 默认画成**复选框**,只有放在
    /// Form/List 里才会自动变成右侧胶囊开关,而向导里没有那个祖先(完整理由见 displayModeRow)。
    private func toggleRow(
        icon: String, title: String, subtitle: String?, isOn: Binding<Bool>
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
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            // 标题传给开关本身再 labelsHidden:视觉不变,旁白读得出这是哪个开关。
            Toggle(title, isOn: isOn)
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
        !OnboardingFlow.anyDisplayModeEnabled(
            overlay: settings.classicOverlayEnabled, notch: settings.notchOverlayEnabled,
            menuBar: settings.showLyricsInMenuBar,
            touchBar: settings.showLyricsInTouchBar, touchBarPresent: touchBar.isPresent)
    }

    /// 最后一步要核对的几件事。只列**这一轮真的走过**的步骤 —— 跟 `steps` 派生自同一批
    /// 判据,没问 Apple Music 权限的人不该在清单上看到一条"未完成"的权限。
    /// 哪几条、好没好、「去处理」跳哪一步由 `OnboardingFlow.readinessItems` 决定,这里只读运行期事实。
    private var readinessItems: [OnboardingFlow.ReadinessItem] {
        let targets = automationTargets
        let fdaTargets = fullDiskAccessTargets
        let axTargets = accessibilityTargets
        return OnboardingFlow.readinessItems(.init(
            engineRunning: engineRunning,
            automationTargets: targets,
            authorized: Set(targets.filter { automation.status($0) == .authorized }),
            fullDiskAccessGranted: fdaTargets.isEmpty ? nil : fullDiskAccess.grant(fdaTargets) == .granted,
            browserPaired: wantsBrowserYouTubeMusic
                ? BrowserPairing.hasAnyPair(platformID: Self.youTubeMusicPlatformID) : nil,
            displayModeEnabled: !noDisplayModeEnabled,
            accessibilityGranted: axTargets.isEmpty ? nil : accessibility.trusted))
    }

    private func readinessTitle(_ kind: OnboardingFlow.ReadinessKind) -> String {
        switch kind {
        case .engine: return L10n.t("歌词引擎")
        case .automation(let player): return String(format: L10n.t("%@ 自动化权限"), player.displayName)
        case .fullDiskAccess: return L10n.t("完全磁盘访问权限")
        case .accessibility: return L10n.t("辅助功能权限")
        case .browser: return L10n.t("YouTube Music 的浏览器")
        case .displayMode: return L10n.t("歌词显示方式")
        }
    }

    /// 收尾页:居中的头部(App 图标 + 状态角标 + 标题 + 一句话)→ 实时状态横幅(「放一首歌试试」)
    /// →「要处理的」卡片(有才出现)→ 三格小卡片(跟着哪些播放器 / 菜单栏图标 / Last.fm)。
    ///
    /// 「要处理的」那张是 automation 从「下一步」那道锁里移出去之后**唯一如实报告缺什么**的地方
    /// (见 `nextIsLocked`):误点「不允许」还能一路走完,这一页不能无条件说「一切就绪」。
    /// 全绿时整张不出现。必需项在前(「去处理」),推荐项在后(「去开启」,写明开了能多得到什么)。
    ///
    /// 这是个**没有 Dock 图标的菜单栏 App**:点完「开始使用」窗口一关,屏幕上什么都不会发生,
    /// 所以图标在哪、长什么样,这一页必须自己讲(首启那个 ⌘+拖拽气泡等引导走完才弹)。
    private var doneStep: some View {
        let items = readinessItems
        let allOK = OnboardingFlow.requiredReady(items)
        let pending = items.filter { !$0.ok && !$0.isOptional } + items.filter { !$0.ok && $0.isOptional }
        return VStack(alignment: .leading, spacing: 14) {
            doneHeader(allOK: allOK)
            liveBanner
            if !pending.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(pending.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { setupDivider }
                        pendingRow(item)
                    }
                }
                .onboardingCard()
            }
            HStack(alignment: .top, spacing: 10) {
                playersTile
                menuBarTile
                lastfmTile
            }
            // 见 finish():歌词引擎没起来时这次不算走完引导,下次启动还会再问。写在脸上,不做无声惩罚。
            if !engineRunning {
                Text(L10n.t("歌词引擎尚未启用，本次引导未完成，下次启动时将再次显示"))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 只在没有要处理的项时出现:有待处理项时再加这一行就超出底栏以上的可见高度(高度账见 14 章决策 57)。
            // 文案里点名了菜单栏右键菜单的「反馈问题…」,改那一项的名字要连这句一起改(contracts 组「反馈链接」逐语言核对)。
            if pending.isEmpty {
                Text(L10n.t("遇到问题时，可右键点按菜单栏图标，选择「反馈问题…」"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func doneHeader(allOK: Bool) -> some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
                .overlay(alignment: .bottomTrailing) {
                    ZStack {
                        Circle().fill(Color.white).frame(width: 17, height: 17)
                        Image(systemName: allOK ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(allOK ? Color.green : Color.orange)
                    }
                    .offset(x: 3, y: 3)
                }
                .accessibilityHidden(true)
            Text(allOK ? L10n.t("一切就绪") : L10n.t("还有未完成的项目"))
                .font(.title2.bold())
            // 文案里点名了「开始使用」这个按钮(英文 "Get Started"),改按钮文案要连这句一起改。
            Text(allOK ? L10n.t("点按「开始使用」，让歌词随旋律逐句亮起")
                       : L10n.t("还差最后几步：请完成下方标为橙色的项目"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
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
    /// 图标那一行和名字那一行**必须共用这一个数组**。两处各拼一遍的话(图标一个
    /// `ForEach` + `if`,名字一个 `map` + 三元),两串顺序靠人肉对齐 —— 那正是会漂的写法,
    /// 而且真漂过:图标排到最后的是 YouTube Music,名字里排到最后的也是它,但两处
    /// 都把「自动识别」放在了 YouTube Music **前面**,跟选播放器那一步的网格顺序相反。
    ///
    /// 顺序跟 `playerChoiceStep` 的网格逐项一致:具体播放器(按 `PlaybackPlayer.displayOrder`,
    /// 那份顺序本身按系统语言算)→ YouTube Music → 「自动识别」垫底。「自动识别」排在
    /// YouTube Music 之后是对调后的顺序,收尾这一页也要跟上
    /// (「自动识别和 youtubemusic 的顺序是不是应该换一下」)—— 两处顺序不一致,读的人会以为
    /// 其中一处是错的。
    private var chosenEntries: [ChosenEntry] {
        OnboardingFlow.chosenEntries(
            players: features.players, displayOrder: PlaybackPlayer.displayOrder,
            webPlatformID: wantsBrowserYouTubeMusic ? Self.youTubeMusicPlatformID : nil
        ).map { entry in
            switch entry {
            case .player(let player): return .player(player)
            case .webPlatform(let id): return .webPlatform(id: id, title: "YouTube Music")
            }
        }
    }

    /// 实时状态横幅(「放一首歌试试」):判定在 `OnboardingFlow.liveCheck`,这里只管排版。
    /// 歌词已跟上是绿底,找不到 / 断网是橙底,其余中性。
    private var liveBanner: some View {
        let state = OnboardingFlow.liveCheck(liveInput)
        let song = liveInput.title
        let tint: Color? = switch state {
        case .lyricsReady: .green
        case .noLyrics, .offline: .orange
        default: nil
        }
        return HStack(alignment: .center, spacing: 10) {
            Group {
                switch state {
                case .searching: ProgressView().controlSize(.small)
                case .lyricsReady: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .noLyrics, .offline: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                case .notPlaying, .adBreak, .instrumental: Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 16))
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(liveHeadline(state))
                    .font(.system(size: 13, weight: .medium))
                Group {
                    switch state {
                    case .notPlaying:
                        Button(L10n.t("已在播放但未显示歌词？请检查所选的播放器")) { jump(to: .playerChoice) }
                            .buttonStyle(.link)
                    case .noLyrics:
                        Button(L10n.t("前往歌词管理手动查找")) { AppActions.shared.openLyricsManager?() }
                            .buttonStyle(.link)
                    case .adBreak:
                        Text(L10n.t("歌曲开始播放后将显示歌词"))
                            .foregroundStyle(.secondary)
                    default:
                        Text(String(format: L10n.t("正在播放「%@」"), song))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.system(size: 11))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onboardingCardBackground(cornerRadius: 12, tint: tint,
                                  fallbackFill: (tint ?? Color.primary).opacity(tint == nil ? 0.035 : 0.08),
                                  fallbackStroke: (tint ?? Color.primary).opacity(tint == nil ? 0.08 : 0.2))
    }

    private func liveHeadline(_ state: OnboardingFlow.LiveCheck) -> String {
        switch state {
        case .notPlaying: return L10n.t("请播放一首歌曲")
        case .adBreak: return L10n.t("正在播放广告")
        case .lyricsReady: return L10n.t("歌词已同步显示")
        case .instrumental: return L10n.t("这首歌曲为纯音乐")
        case .searching: return L10n.t("正在查找歌词…")
        case .noLyrics: return L10n.t("未找到这首歌曲的歌词")
        case .offline: return L10n.t("网络无法连接，暂时无法获取歌词")
        }
    }

    /// 三格小卡片的外壳:图标一行、标题 + 一两行说明,最底下可选一个链接。
    private func doneTile<Top: View, Bottom: View>(
        title: String, detail: String,
        @ViewBuilder top: () -> Top, @ViewBuilder bottom: () -> Bottom
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            top()
                .frame(height: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            bottom()
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .onboardingCardBackground(cornerRadius: 12, fallbackFill: Color(nsColor: .controlBackgroundColor).opacity(0.55),
                                  fallbackStroke: Color.primary.opacity(0.07))
    }

    /// 选的播放器:图标走 `PlayerIconView`(三级兜底取图,跟选项卡共用一份),最多并排四个;
    /// 名字那一行既是给眼睛的说明,也是旁白唯一能读到的内容。
    ///
    /// 「自动识别」不是一个 App,不画成图标:图标只排真实的播放器 / 网页平台(并排、不重叠),
    /// 自动识别用文字说。只开了自动识别时放一个普通的魔法棒符号占住图标位。
    private var playersTile: some View {
        let entries = chosenEntries
        let autoDetect = entries.contains { if case .player(.auto) = $0 { return true } else { return false } }
        let apps = entries.filter { if case .player(.auto) = $0 { return false } else { return true } }
        // 按界面语言拼(「A、B 和 C」/「A, B, and C」),不写死中文顿号。
        let appNames = ListFormatter.localizedString(byJoining: apps.map(\.displayName))
        let detail = !autoDetect ? appNames
            : apps.isEmpty ? L10n.t("自动识别正在播放的 App")
            : String(format: L10n.t("自动识别正在播放的 App，以及 %@"), appNames)
        return doneTile(title: L10n.t("已选择的播放器"), detail: detail) {
            if apps.isEmpty {
                Image(systemName: "wand.and.sparkles")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    ForEach(Array(apps.prefix(4))) { entry in
                        chosenEntryIcon(entry)
                    }
                }
            }
        } bottom: {
            EmptyView()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: L10n.t("已选择的播放器：%@"), detail))
    }

    @ViewBuilder
    private func chosenEntryIcon(_ entry: ChosenEntry) -> some View {
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
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.secondary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    /// 画出用户此刻选的那一款菜单栏图标(12 款可选,只说「在菜单栏里」新用户不知道找哪个)。
    /// 跟设置页图标选择器同一份绘制(`MenuBarIconStyle.cachedImage`)。
    private var menuBarTile: some View {
        doneTile(title: L10n.t("位于菜单栏"), detail: L10n.t("点按图标可打开设置和歌词窗口")) {
            Image(nsImage: MenuBarIconStyle.cachedImage(for: settings.menuBarIconStyle))
                .renderingMode(.template)
                .foregroundStyle(Color.primary)
                .frame(width: 36, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.14)))
                .accessibilityLabel(String(format: L10n.t("菜单栏图标：%@"), settings.menuBarIconStyle.displayName))
        } bottom: {
            EmptyView()
        }
    }

    /// Last.fm:纯介绍,不收集凭据。点「去连接」直接打开设置并停在 Last.fm 详情页
    /// (见 AppActions.pendingSettingsSelection)。图标跟设置页账号卡片同一张(`lastfmBadge`)。
    private var lastfmTile: some View {
        doneTile(title: "Last.fm", detail: L10n.t("同步你的收听记录")) {
            lastfmBadge(size: 24)
                .accessibilityHidden(true)
        } bottom: {
            Button(L10n.t("前往连接")) {
                AppActions.shared.requestSettings(.account(.lastfm))
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .buttonStyle(.link)
            .font(.system(size: 11, weight: .medium))
        }
    }

    /// 「要处理的」卡片里的一行:必需项橙色感叹号 +「去处理」;推荐项灰色 + 写明开了能多得到什么 +「去开启」。
    private func pendingRow(_ item: OnboardingFlow.ReadinessItem) -> some View {
        cardRow(title: readinessTitle(item.kind),
                subtitle: item.isOptional ? recommendedBenefit(item.kind) : nil) {
            if item.isOptional {
                Image(systemName: "sparkles")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else {
                // 图标是这一行唯一表达"没好"的东西,旁白必须读得出来。
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.orange)
                    .accessibilityLabel(L10n.t("未完成"))
            }
        } trailing: {
            Button(item.isOptional ? L10n.t("前往开启") : L10n.t("前往处理")) { jump(to: item.target) }
                .buttonStyle(.link)
        }
    }

    /// 辅助功能、自动化两项按用途说(`accessibilityUse` / `automationUse`),跟上一页那几句对得上。
    private func recommendedBenefit(_ kind: OnboardingFlow.ReadinessKind) -> String {
        switch kind {
        case .fullDiskAccess:
            return L10n.t("请开启此权限，以便直接使用本机已有的歌词，并提前准备下一首")
        case .accessibility:
            let targets = accessibilityTargets
            let progress = targets.filter { $0.accessibilityUse == .calibratesProgress }
            let playMode = targets.filter { $0.accessibilityUse == .switchesPlayMode }
            if progress.isEmpty {
                return String(format: L10n.t("请开启此权限，以显示%@的随机、循环键"),
                              accessibility.playerNames(playMode))
            }
            if playMode.isEmpty {
                return String(format: L10n.t("请开启此权限，让%@自动连播时的播放进度更准确"),
                              accessibility.playerNames(progress))
            }
            return String(format: L10n.t("请开启此权限，让%@自动连播时的播放进度更准确，并显示%@的随机、循环键"),
                          accessibility.playerNames(progress), accessibility.playerNames(playMode))
        case .automation(let player) where player.automationUse == .readsTrack:
            return L10n.t("请开启此权限，以便准确识别正在播放的歌曲，并可在歌词上直接控制播放")
        default:
            return L10n.t("请开启此权限，让播放进度更准确，并可在歌词上直接控制播放")
        }
    }

    // 跟 GeneralSettingsTab 同一套状态展示逻辑,这里独立写一份而不是抽共享组件——
    // 就这几行纯展示分支,抽象成本比重复它本身更高。
    /// 播放器网格点一下。切换本体走 `features.togglePlayer`(跟设置页共用那份"最后一个
    /// 不能取消"的判断),**勾上**的那一下顺带把「自动化」权限要出来 —— 跟设置页
    /// `toggleSelectedPlayer` 是同一条,分寸见 `PlayerAutomationPermissions.requestOnSelect`。
    ///
    /// 在这里要、而不是等到后面那一步:后面那一步只在**列表非空**时才存在,而列表正是由
    /// 这一下决定的;等翻过去再问,用户已经离开"我刚说我用它"那个语境了。
    /// 重新读一次后台服务在不在跑。`EngineServiceManager.isRunning` 会起 `launchctl print` 子进程同步等它退出,
    /// 放到后台线程上查,不卡引导窗口。
    private func refreshEngineRunning() async {
        let running = await Task.detached(priority: .userInitiated) { EngineServiceManager.isRunning }.value
        if engineRunning != running { engineRunning = running }
    }

    private func enableEngineService() {
        isTogglingEngineService = true
        engineFailure = nil
        Task {
            // 引导页只关心"起来了没",不铺开三态——那是设置页排查问题时才需要的粒度。
            // 先写开关(didSet 派发那唯一一次 install),再等它跑完拿状态,见 EngineServiceManager.operationQueue。
            settings.engineServiceEnabled = true
            let state = await EngineServiceManager.waitForPendingOperations()
            engineRunning = state.isRunning
            isTogglingEngineService = false
            // 起不来时给一句交代 + 一条出路。`LaunchdJobState.description`
            // 是固定英文的诊断串(见那边头注:它本来就是拿来贴给别人看的),所以只放进括号里
            // 当线索,不承担正文的表达。
            engineFailure = state.isRunning ? nil : String(
                format: L10n.t("启动失败（%@）。可先「暂时跳过」，之后在设置的「播放器 → 歌词引擎」中重试，该页面会显示更详细的状态。"),
                state.description)
        }
    }

    /// 翻到某一步。所有翻页都走它 —— `step` 的加减法和 `furthestStep` 的推进收在一处,
    /// 免得"下一步"按钮、进度点、体检清单的「去处理」各记一套。
    private func goTo(_ index: Int) {
        let next = OnboardingFlow.navigate(to: index, from: .init(step: step, furthest: furthestStep),
                                           stepCount: steps.count)
        step = next.step
        furthestStep = next.furthest
    }

    /// 跳到某一个具体步骤(体检清单的「去处理」用)。那一步不在本轮列表里就什么都不做 ——
    /// 清单本身是按同一份 `steps` 派生的,正常不会出现,但不值得为此崩一次。
    private func jump(to target: Step) {
        guard let index = OnboardingFlow.index(of: target, in: steps) else { return }
        goTo(index)
    }

    private func finish() {
        // **后台服务没起来就不算"引导过了"**(跟同日新增的「暂时跳过」配套)。
        //
        // `hasCompletedOnboarding` 一旦置真,这扇窗口再也不会自动出现,而它是把引擎
        // 服务装起来的主要入口 —— 15 章记着的那条不可自愈的死路正是这么形成的:服务没装、
        // 引导又被标记成已完成,用户看到的是桌面永久停在「搜索歌词中…」,界面上没有任何
        // 线索指向"后台服务没装"。加了「暂时跳过」之后,那条死路就又有了一条新的到达方式,
        // 所以这里必须挡住。
        //
        // 跳过的人代价只是"下次启动会再问一次"(跟直接关窗完全同一档待遇),而 doneStep 的
        // 体检清单已经把这件事写在脸上了,不是无声惩罚。
        if OnboardingFlow.marksCompleted(engineRunning: engineRunning) {
            settings.hasCompletedOnboarding = true
        }
        dismissWindow(id: "onboarding")
    }
}

// MARK: - 显示形态小示意图
//
// 仓库里没有任何现成的形态缩略图资产(设置页"外观"整页零预览,只有 SF Symbol),所以这几张
// 图用 SwiftUI 基本形状现画。悬浮歌词、灵动岛、菜单栏三张共用同一个"屏幕外框 + 顶部菜单栏条"的底,
// 差别只在歌词画在哪儿 —— 三行摆在一起才对照得出"灵动岛"到底跟另外两种差在哪。触控栏那张画的是
// 键盘(上沿一条深色触控栏),不画菜单栏条:它不在屏幕上。
//
// 尺寸全部写成固定常量、**不用 GeometryReader**:示意图必须是可预测的固定高度,不能跟着
// 容器变(窗口固定尺寸,这一步的高度预算按固定行高算)。
//
// 示意图**不跟着开关变灰**。做成"关掉就 saturation(0)+opacity(0.45)"是反效果:
// 灵动岛和菜单栏歌词默认都是关的,于是最需要被解释的那两张恰好被洗成
// 两团灰斑,而这张图存在的唯一理由就是"让没见过的人看懂它会出现在屏幕哪儿"。开关状态由右
// 边的 Toggle 表达,图只负责解释位置。
private struct DisplayModeThumbnail: View {
    enum Kind { case classic, notch, menuBar, touchBar }

    let kind: Kind

    private static let width: CGFloat = 56
    private static let height: CGFloat = 36
    private static let menuBarHeight: CGFloat = 6
    private static let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)

    var body: some View {
        ZStack(alignment: .top) {
            Self.shape.fill(Color.primary.opacity(0.08))
            // 顶部菜单栏条 —— 屏幕那三张图共用的参照物,没有它就分不出"贴着顶部"和"在桌面上"。
            if kind != .touchBar {
                Rectangle()
                    .fill(Color.primary.opacity(0.14))
                    .frame(height: Self.menuBarHeight)
            }
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
        case .touchBar:
            // 键盘上沿那一条深色的触控栏,歌词是条里一行强调色的字;下面三排小格是按键。
            VStack(spacing: 3) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.primary.opacity(0.85))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 22, height: 3)
                        .padding(.leading, 8)
                }
                .frame(width: Self.width - 8, height: Self.menuBarHeight)
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 2) {
                        ForEach(0..<8, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                .fill(Color.primary.opacity(0.2))
                                .frame(width: 4.5, height: 4)
                        }
                    }
                }
            }
            .padding(.top, 4)
            .frame(width: Self.width, height: Self.height, alignment: .top)
        }
    }
}

private extension View {
    /// 引导页里的卡片:欢迎页的两个偏好、「让它跑起来」的状态行、收尾页待处理那张共用一份。材质见
    /// `onboardingCardBackground`。
    func onboardingCard() -> some View {
        padding(.horizontal, 12)
            .onboardingCardBackground(cornerRadius: 12, fallbackFill: Color.primary.opacity(0.035),
                                      fallbackStroke: Color.primary.opacity(0.08))
    }
}
