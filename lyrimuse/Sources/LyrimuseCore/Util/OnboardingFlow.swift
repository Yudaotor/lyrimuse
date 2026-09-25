import Foundation

/// 首启引导的步骤。`OnboardingView` 按它排页面。
public enum OnboardingStep: Equatable, Hashable, Sendable {
    case welcome, playerChoice, browserPairing, background, displayMode, done
}

/// 首启引导的流程判断:走哪几步、翻页怎么夹下标、哪一步锁「下一步」、收尾页列什么。
///
/// `OnboardingView` 只负责调用和排版,判断都收在这里,selftest onboarding 组逐条钉着。
/// 运行期事实(装没装、授权状态、collector 在不在跑)由视图层读好传进来,这里不碰
/// NSWorkspace / launchctl。
public enum OnboardingFlow {

    // MARK: - 步骤序列

    /// 决定这一轮走哪几步的条件。
    public struct Conditions: Equatable, Sendable {
        /// 选播放器那一步勾了 YouTube Music。
        public var wantsBrowserPairing: Bool

        public init(wantsBrowserPairing: Bool) {
            self.wantsBrowserPairing = wantsBrowserPairing
        }
    }

    /// 固定出现的步数,也是 `steps` 的长度下限。
    public static let minimumStepCount = 5

    /// 这一轮的步骤序列。唯一的条件步 `.browserPairing` 紧跟选播放器、只出现在它后面 ——
    /// 能让序列变长变短的控件都在选播放器那一步,条件步排在它前面会让用户脚下的下标跟着变。
    /// 自动化权限、完全磁盘访问不是单独的步骤,是 `.background`(「让它跑起来」)页里按需出现的
    /// 小节:完全磁盘访问的状态由 collector 发布,授权完还要重启它,所以放在装歌词引擎的同一页、
    /// 排在它下面。
    public static func steps(_ conditions: Conditions) -> [OnboardingStep] {
        var list: [OnboardingStep] = [.welcome, .playerChoice]
        if conditions.wantsBrowserPairing { list.append(.browserPairing) }
        list.append(contentsOf: [.background, .displayMode, .done])
        return list
    }

    // MARK: - 翻页

    /// 把下标夹进 `[0, count - 1]`。`count` 不为正时返回 0。
    public static func clampedIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    /// 当前这一步。设置窗口能同时改播放器集合、让序列变短,渲染那一刻 `index` 可能已经越界,
    /// 所以取值一律经这里夹住,别在视图里写 `steps[index]`。
    public static func step(at index: Int, in steps: [OnboardingStep]) -> OnboardingStep {
        guard !steps.isEmpty else { return .welcome }
        return steps[clampedIndex(index, count: steps.count)]
    }

    /// 视图里的两个存储值:当前下标,和走到过的最远下标(决定进度点能点回哪里)。
    public struct Position: Equatable, Sendable {
        public var step: Int
        public var furthest: Int

        public init(step: Int, furthest: Int) {
            self.step = step
            self.furthest = furthest
        }
    }

    /// 翻到 `index`(「下一步」「上一步」「暂时跳过」、进度点、体检清单的「去处理」都走这里)。
    /// 目标先夹进合法区间;`furthest` 只增不减。
    public static func navigate(to index: Int, from position: Position, stepCount: Int) -> Position {
        let target = clampedIndex(index, count: stepCount)
        return Position(step: target, furthest: max(position.furthest, target))
    }

    /// 序列变短之后,把两个存储值拉回合法区间(否则「上一步/下一步」会从非法下标继续加减)。
    public static func clamped(_ position: Position, stepCount: Int) -> Position {
        let last = max(stepCount - 1, 0)
        return Position(step: min(max(position.step, 0), last),
                        furthest: min(max(position.furthest, 0), last))
    }

    /// 第 `index` 个进度点能不能点。只允许回到走到过的范围:往前跳会绕过 `.background` 那道锁,
    /// 而 `furthest` 只由「下一步」/「暂时跳过」推进。
    public static func canJump(toDot index: Int, furthest: Int) -> Bool {
        index >= 0 && index <= furthest
    }

    /// 体检清单「去处理」要跳到的下标;那一步不在本轮序列里就是 nil(什么都不做)。
    public static func index(of target: OnboardingStep, in steps: [OnboardingStep]) -> Int? {
        steps.firstIndex(of: target)
    }

    // MARK: - 锁与收尾

    /// 「下一步」锁没锁。只有后台服务那一步、且服务没在跑时才锁。
    /// 自动化权限不进这把锁:没有它歌词照样显示,缺了什么由收尾页的体检清单如实报告。
    public static func nextIsLocked(at step: OnboardingStep, collectorRunning: Bool) -> Bool {
        step == .background && !collectorRunning
    }

    /// 走到后台服务那一步时要不要自动开始启用。服务已在跑、正在装、或上一次装失败了都不自动
    /// 再来:失败之后由用户点「重试」,不在每次翻回这一步时反复重试。
    public static func autoStartsBackgroundService(at step: OnboardingStep, collectorRunning: Bool,
                                                   installing: Bool, lastAttemptFailed: Bool) -> Bool {
        step == .background && !collectorRunning && !installing && !lastAttemptFailed
    }

    /// 用户在系统设置里授权完、引导窗口此刻不在前台时,要不要把它带回来。只在「这一页已授权的
    /// 权限多了一项」的那一刻触发,不在每次状态刷新时抢焦点。
    public static func bringsBackAfterGrant(grantedBefore: Int, grantedNow: Int, appIsActive: Bool) -> Bool {
        grantedNow > grantedBefore && !appIsActive
    }

    /// 点「开始使用」时要不要把引导记成走完。服务没在跑就不记:标记一旦置真这扇窗口不会再自动
    /// 出现,而它是装 collector 的主要入口(服务没装 + 引导标记完成 = 桌面永久停在「搜索歌词中…」)。
    public static func marksCompleted(collectorRunning: Bool) -> Bool {
        collectorRunning
    }

    // MARK: - 收尾页体检清单

    /// 清单里的一项是什么。标题文案由视图层按它取。
    public enum ReadinessKind: Equatable, Hashable {
        case collector
        case automation(PlaybackPlayer)
        case fullDiskAccess
        case browser
        case displayMode
    }

    public struct ReadinessItem: Equatable, Identifiable {
        public let kind: ReadinessKind
        public let ok: Bool
        /// 「去处理」跳回哪一步。
        public let target: OnboardingStep

        public var id: String {
            switch kind {
            case .collector: return "collector"
            case .automation(let player): return "automation-\(player.rawValue)"
            case .fullDiskAccess: return "full-disk-access"
            case .browser: return "browser"
            case .displayMode: return "display"
            }
        }

        public init(kind: ReadinessKind, ok: Bool, target: OnboardingStep) {
            self.kind = kind
            self.ok = ok
            self.target = target
        }

        /// 推荐项(自动化权限、完全磁盘访问):没开也不算没做完 —— 收尾页标题照样是「一切就绪」,
        /// 这一行改成「推荐开启」的提示。其余几项没好就是真没做完(没有它们屏幕上就没有歌词)。
        public var isOptional: Bool {
            switch kind {
            case .automation, .fullDiskAccess: return true
            case .collector, .browser, .displayMode: return false
            }
        }
    }

    /// 必需项都好了没有(决定收尾页标题是「一切就绪」还是「还差一点」)。推荐项不算在内。
    public static func requiredReady(_ items: [ReadinessItem]) -> Bool {
        items.allSatisfy { $0.ok || $0.isOptional }
    }

    /// 生成清单要的运行期事实。可选项为 nil = 本轮没有那一步,清单里也不列。
    public struct ReadinessInput: Equatable {
        public var collectorRunning: Bool
        /// 自动化权限那一步列的播放器,顺序即清单顺序。
        public var automationTargets: [PlaybackPlayer]
        /// 其中已授权的。
        public var authorized: Set<PlaybackPlayer>
        public var fullDiskAccessGranted: Bool?
        public var browserPaired: Bool?
        /// 至少开着一种歌词显示方式。
        public var displayModeEnabled: Bool

        public init(collectorRunning: Bool, automationTargets: [PlaybackPlayer],
                    authorized: Set<PlaybackPlayer>, fullDiskAccessGranted: Bool?,
                    browserPaired: Bool?, displayModeEnabled: Bool) {
            self.collectorRunning = collectorRunning
            self.automationTargets = automationTargets
            self.authorized = authorized
            self.fullDiskAccessGranted = fullDiskAccessGranted
            self.browserPaired = browserPaired
            self.displayModeEnabled = displayModeEnabled
        }
    }

    /// 收尾页要核对的几件事。只列这一轮真的走过的步骤:没问自动化权限的人不该看到一条
    /// 「未完成」的权限。
    public static func readinessItems(_ input: ReadinessInput) -> [ReadinessItem] {
        var items = [ReadinessItem(kind: .collector, ok: input.collectorRunning, target: .background)]
        for player in input.automationTargets {
            items.append(ReadinessItem(kind: .automation(player),
                                       ok: input.authorized.contains(player), target: .background))
        }
        if let granted = input.fullDiskAccessGranted {
            items.append(ReadinessItem(kind: .fullDiskAccess, ok: granted, target: .background))
        }
        if let paired = input.browserPaired {
            items.append(ReadinessItem(kind: .browser, ok: paired, target: .browserPairing))
        }
        items.append(ReadinessItem(kind: .displayMode, ok: input.displayModeEnabled, target: .displayMode))
        return items
    }

    // MARK: - 收尾页「放一首歌试试」

    /// 收尾页那一行实时状态:从「服务在跑」到「屏幕上真的有歌词」中间还有好几环
    /// (认出播放器、读到曲目、找到歌词),在引导里就让人看到结果,而不是关掉窗口才发现。
    public enum LiveCheck: Equatable, Sendable {
        /// 没读到在播的曲目(没在放,或在放的播放器没被认出来)。
        case notPlaying
        case adBreak
        case lyricsReady
        case instrumental
        case searching
        case noLyrics
        case offline
    }

    public struct LiveInput: Equatable, Sendable {
        public var title: String
        public var artist: String
        public var hasLyrics: Bool
        public var instrumental: Bool
        public var noLyrics: Bool
        public var adBreak: Bool
        public var networkDown: Bool

        public init(title: String, artist: String, hasLyrics: Bool, instrumental: Bool,
                    noLyrics: Bool, adBreak: Bool, networkDown: Bool) {
            self.title = title
            self.artist = artist
            self.hasLyrics = hasLyrics
            self.instrumental = instrumental
            self.noLyrics = noLyrics
            self.adBreak = adBreak
            self.networkDown = networkDown
        }
    }

    /// 优先级:没有曲目 > 广告 > 有歌词 > 纯音乐 > 确定没歌词 > 断网 > 还在找。
    /// 「有歌词」排在「断网」前面:歌词已经在手,断网不影响它显示。
    public static func liveCheck(_ input: LiveInput) -> LiveCheck {
        guard !input.title.isEmpty else { return .notPlaying }
        if input.adBreak { return .adBreak }
        if input.hasLyrics { return .lyricsReady }
        if input.instrumental { return .instrumental }
        if input.noLyrics { return .noLyrics }
        if input.networkDown { return .offline }
        return .searching
    }

    // MARK: - 收尾页「你选的播放器」

    /// 收尾页那一串里的一项:`PlaybackPlayer` 的 case,或不是 case 的网页平台(按平台 id)。
    public enum ChosenEntry: Equatable, Hashable {
        case player(PlaybackPlayer)
        case webPlatform(String)
    }

    /// 收尾页那一串,顺序即展示顺序,图标行和名字行共用这一份。顺序跟选播放器那一步的网格一致:
    /// 具体播放器(按 `displayOrder`)→ 网页平台 → 「自动识别」垫底。勾着自动识别时,单独勾过的
    /// 具体播放器不参与识别,不列。「自动识别」也从 `displayOrder` 里取:它不在那份顺序里时这里
    /// 跟着不出现。
    public static func chosenEntries(players: Set<PlaybackPlayer>,
                                     displayOrder: [PlaybackPlayer],
                                     webPlatformID: String?) -> [ChosenEntry] {
        let autoDetect = players.contains(.auto)
        var entries = displayOrder
            .filter { $0 != .auto && !autoDetect && players.contains($0) }
            .map(ChosenEntry.player)
        if let webPlatformID { entries.append(.webPlatform(webPlatformID)) }
        entries += displayOrder
            .filter { $0 == .auto && autoDetect }
            .map(ChosenEntry.player)
        return entries
    }
}
