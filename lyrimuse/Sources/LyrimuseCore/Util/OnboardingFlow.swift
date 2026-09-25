import Foundation

/// 首启引导的步骤。`OnboardingView` 按它排页面。
public enum OnboardingStep: Equatable, Hashable, Sendable {
    case welcome, playerChoice, automation, browserPairing, background,
         fullDiskAccess, displayMode, lyricsExtras, lastfm, done
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
        /// 自动化权限那一步要列的播放器非空(选中 ∩ 需要 ∩ 装了)。
        public var needsAutomation: Bool
        /// 选播放器那一步勾了 YouTube Music。
        public var wantsBrowserPairing: Bool
        /// 完全磁盘访问那一步要列的播放器非空(选中 ∩ 需要 ∩ 装了)。
        public var needsFullDiskAccess: Bool

        public init(needsAutomation: Bool, wantsBrowserPairing: Bool, needsFullDiskAccess: Bool) {
            self.needsAutomation = needsAutomation
            self.wantsBrowserPairing = wantsBrowserPairing
            self.needsFullDiskAccess = needsFullDiskAccess
        }
    }

    /// 固定出现的步数,也是 `steps` 的长度下限。
    public static let minimumStepCount = 7

    /// 这一轮的步骤序列。三个条件步的位置是硬约束:
    /// - `.automation`、`.browserPairing` 紧跟选播放器,且只出现在它后面 —— 能让序列变长变短的
    ///   控件都在选播放器那一步,条件步排在它前面会让用户脚下的下标跟着变;
    /// - `.fullDiskAccess` 必须排在 `.background` 之后:授权状态由 collector 发布,授权完还要
    ///   重启它才生效。
    public static func steps(_ conditions: Conditions) -> [OnboardingStep] {
        var list: [OnboardingStep] = [.welcome, .playerChoice]
        if conditions.needsAutomation { list.append(.automation) }
        if conditions.wantsBrowserPairing { list.append(.browserPairing) }
        list.append(.background)
        if conditions.needsFullDiskAccess { list.append(.fullDiskAccess) }
        list.append(contentsOf: [.displayMode, .lyricsExtras, .lastfm, .done])
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

    /// 点「开始使用」时要不要把引导记成走完。服务没在跑就不记:标记一旦置真这扇窗口不会再自动
    /// 出现,而它是装 collector 的主要入口(服务没装 + 引导标记完成 = 桌面永久停在「搜索歌词中…」)。
    public static func marksCompleted(collectorRunning: Bool) -> Bool {
        collectorRunning
    }

    // MARK: - 收尾页体检清单

    /// 清单里的一项是什么。标题文案由视图层按它取。
    public enum ReadinessKind: Equatable, Hashable, Sendable {
        case collector
        case automation(PlaybackPlayer)
        case fullDiskAccess
        case browser
        case displayMode
    }

    public struct ReadinessItem: Equatable, Identifiable, Sendable {
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
    }

    /// 生成清单要的运行期事实。可选项为 nil = 本轮没有那一步,清单里也不列。
    public struct ReadinessInput: Equatable, Sendable {
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
                                       ok: input.authorized.contains(player), target: .automation))
        }
        if let granted = input.fullDiskAccessGranted {
            items.append(ReadinessItem(kind: .fullDiskAccess, ok: granted, target: .fullDiskAccess))
        }
        if let paired = input.browserPaired {
            items.append(ReadinessItem(kind: .browser, ok: paired, target: .browserPairing))
        }
        items.append(ReadinessItem(kind: .displayMode, ok: input.displayModeEnabled, target: .displayMode))
        return items
    }

    // MARK: - 收尾页「你选的播放器」

    /// 收尾页那一串里的一项:`PlaybackPlayer` 的 case,或不是 case 的网页平台(按平台 id)。
    public enum ChosenEntry: Equatable, Hashable, Sendable {
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
