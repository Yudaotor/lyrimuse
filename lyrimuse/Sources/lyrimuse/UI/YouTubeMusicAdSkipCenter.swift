import AppKit
import Combine
import LyrimuseCore
import os

/// YouTube Music 广告的「能不能跳」门槛轮询 + 跳过动作,App 里只有一份。
///
/// 两个消费方:
///  - 灵动岛那颗「跳过广告」键读 `adSkipAvailable` / `skipInFlight`,按下走 `skip(trigger: .manual)`;
///  - 「自动跳过 YouTube Music 广告」(`AppSettings.youTubeMusicAutoSkipAds`)开着时,门槛一读到
///    `.ready` 就替用户按一次,判据在 Core `YouTubeMusicAdAutoSkip`。
///
/// 轮询只在「广告中」**且**有人要结果时跑:自动跳过开着,或者至少有一扇真的灵动岛窗口在广告态
/// (`setNotchDemand`)。灵动岛关着、自动跳过也关着时一次 AppleEvent 都不发。编辑台预览的
/// `isAdBreakNow` 恒 false、从不登记需求,预览不产生副作用。
///
/// 每块屏一份灵动岛都读这同一份结果,同一条广告只有一轮轮询、同一时刻只有一次按键。
@MainActor
final class YouTubeMusicAdSkipCenter: ObservableObject {
    static let shared = YouTubeMusicAdSkipCenter()

    static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "ytmusic-skip")

    enum Trigger { case manual, auto }

    /// 页面上那颗「跳过」键此刻放出来没有。只有门槛确认 `.ready` 才是 true;问不出来(脚本跑不成)同样 false。
    /// 必须是 `@Published`:倒计时过完、键刚放出来的那一刻,广告态那一格没有任何别的东西在变,
    /// 读缓存的计算属性不会被重估,键就一直不出现。
    @Published private(set) var adSkipAvailable = false
    /// 一次跳过正在跑(按 + 复核,约 1～3s)。期间再按忽略 —— 几份并行的 run 交错,各自的复核读到的是
    /// 别人按完的页面。手动与自动共用这一把。
    @Published private(set) var skipInFlight = false

    private var adBreak = false
    private var title = ""
    private var autoSkipEnabled = false
    private var notchDemand: Set<ObjectIdentifier> = []

    /// 正在轮询的是哪一条广告(按标题认)。nil = 没在轮询。
    private var gatedAdTitle: String?
    private var gateTask: Task<Void, Never>?
    /// 这一条广告自动按过几次、还要不要再试。换到下一条广告时清零。
    private var autoAttempts = 0
    private var autoStopped = false
    /// 这段运行里是否已经因为自动跳过缺辅助功能权限提示过一次。
    private var promptedAccessibilityForAuto = false

    private var subs: [AnyCancellable] = []

    private init() {
        let p = PlaybackCoordinator.shared
        subs = [
            p.$isCurrentTrackAdBreak.removeDuplicates().sink { [weak self] in
                self?.adBreak = $0
                self?.reconcile()
            },
            // 插播里连放两条广告时 isCurrentTrackAdBreak 一直是 true,只有标题在变:按新一条重新判。
            p.$title.removeDuplicates().sink { [weak self] in
                self?.title = $0
                self?.reconcile()
            },
            AppSettings.shared.$youTubeMusicAutoSkipAds.removeDuplicates().sink { [weak self] in
                self?.autoSkipEnabled = $0
                self?.reconcile()
            },
        ]
    }

    /// 灵动岛窗口登记 / 撤销「我在广告态、要看门槛结果」。由视图按 `controller.isAdBreakNow` 驱动,
    /// 持有方销毁时撤销(`NotchPlayback.deinit`)。
    func setNotchDemand(_ id: ObjectIdentifier, active: Bool) {
        let changed = active ? notchDemand.insert(id).inserted : notchDemand.remove(id) != nil
        if changed { reconcile() }
    }

    private func reconcile() {
        let wanted = adBreak && (autoSkipEnabled || !notchDemand.isEmpty)
        guard wanted else {
            if gateTask != nil { Self.logger.notice("gate: stop") }
            gateTask?.cancel()
            gateTask = nil
            gatedAdTitle = nil
            if adSkipAvailable { adSkipAvailable = false }
            return
        }
        // 同一条广告已经在轮询就不重起(广告开始那一拍 isCurrentTrackAdBreak 与标题两条订阅会前后脚到)。
        guard gatedAdTitle != title else { return }
        // 插播里换到了下一条:上一条的判定(尤其「能跳」)不能延续过来,先收键、清缓存,从快探重新判。
        let nextAdInBreak = gatedAdTitle != nil
        gatedAdTitle = title
        autoAttempts = 0
        autoStopped = false
        Self.logger.notice("gate: start\(nextAdInBreak ? " (next ad in break)" : "", privacy: .public) auto=\(self.autoSkipEnabled, privacy: .public)")
        if nextAdInBreak { YouTubeMusicAdSkipper.invalidateGateCache() }
        gateTask?.cancel()
        adSkipAvailable = false
        gateTask = Task.detached(priority: .utility) { [weak self] in
            for round in 0 ..< YouTubeMusicAdSkipper.gateMaxRounds {
                if Task.isCancelled { return }
                // 每一拍现读:广告刚开始那一拍播放源可能还没解析到浏览器,只读一次会让整条广告都探不到。
                let bundleID = await MainActor.run { LocalPlaybackSource.shared.lastResolvedBundleID }
                let state = YouTubeMusicAdSkipper.probeSkippability(reportedBundleID: bundleID)
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    self.apply(gateState: state)
                }
                // 脚本没跑成(nil)不画键、也不收摊:超时这类偶发失败下一拍就可能好。
                if state == .notInAd { return }
                try? await Task.sleep(for: .seconds(YouTubeMusicAdSkipper.gateRetryDelay(after: state, round: round)))
            }
        }
    }

    private func apply(gateState state: YouTubeMusicAdSkipper.Skippability?) {
        let shows = YouTubeMusicAdSkipper.showsSkipButton(state)
        if adSkipAvailable != shows {
            adSkipAvailable = shows
            Self.logger.notice("gate: adSkipAvailable -> \(shows, privacy: .public) (state \(String(describing: state), privacy: .public))")
        }
        if !skipInFlight,
           YouTubeMusicAdAutoSkip.shouldAttempt(enabled: autoSkipEnabled, state: state,
                                                attempts: autoAttempts, stopped: autoStopped) {
            autoAttempts += 1
            Self.logger.notice("auto: attempt \(self.autoAttempts, privacy: .public)")
            skip(trigger: .auto)
        }
    }

    /// 去按 YT Music 页面自己的「跳过广告」键(`YouTubeMusicAdSkipper.skip`:门槛 → 辅助功能按键 → 复核,
    /// 正常 ~1.2s、极端 6s 超时),放后台线程,结果回主线程按触发方式给反馈。
    func skip(trigger: Trigger) {
        guard !skipInFlight else { return }
        skipInFlight = true
        let bundleID = LocalPlaybackSource.shared.lastResolvedBundleID
        let adTitle = gatedAdTitle
        Task.detached(priority: .userInitiated) {
            let outcome = YouTubeMusicAdSkipper.skip(reportedBundleID: bundleID)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.skipInFlight = false
                switch trigger {
                case .manual:
                    Self.reportManualOutcome(outcome)
                case .auto:
                    self.handleAutoOutcome(outcome, adTitle: adTitle)
                }
            }
        }
    }

    private func handleAutoOutcome(_ outcome: YouTubeMusicAdSkipper.Outcome?, adTitle: String?) {
        Self.logger.notice("auto: outcome \(String(describing: outcome), privacy: .public)")
        // 按键期间已经换到下一条广告的话,这次结果不算在新那条头上。
        if adTitle == gatedAdTitle, YouTubeMusicAdAutoSkip.stopsRetrying(after: outcome) {
            autoStopped = true
        }
        switch YouTubeMusicAdAutoSkip.feedback(for: outcome, alreadyPromptedAccessibility: promptedAccessibilityForAuto) {
        case .skipped:
            NotchTransientCenter.shared.show(.init(icon: "forward.end", text: L10n.t("已自动跳过广告"), progress: nil))
        case .needsAccessibility:
            promptedAccessibilityForAuto = true
            AccessibilitySkipPress.promptForTrust()
            NotchTransientCenter.shared.show(.init(icon: "hand.raised", text: L10n.t("跳过广告需要「辅助功能」权限"), progress: nil),
                                             for: 2.4)
        case .none:
            break
        }
    }

    /// 手动按的结果,**每一种都有反馈**:只给触觉不够 —— 触觉在 Mac 上几乎察觉不到,一颗键按下去
    /// 没有任何可见反应是最坏的交互。
    ///   * 跳过了 → 只给一下触觉(页面随即切正片,灵动岛按换曲流程自己刷新);
    ///   * 键还没出现 → 读得到倒数就说「N 秒后可跳过」,读不到(不可跳过的广告)说「这条广告还不能跳过」;
    ///   * 没权限 → 弹系统授权对话框 + 说明(ad-hoc 签名的构建每次重装授权都会失效,见 AccessibilitySkipPress 头注);
    ///   * 标签页不在前面 → 让用户切过去;
    ///   * 按了没生效 / 没有标签页在放广告 / 脚本没跑成 → 「没能跳过这条广告」。
    private static func reportManualOutcome(_ outcome: YouTubeMusicAdSkipper.Outcome?) {
        switch outcome {
        case .skipped?:
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        case .notYetSkippable(let seconds)?:
            let text = seconds.map { String(format: L10n.t("%@ 秒后可跳过"), String($0)) } ?? L10n.t("这条广告还不能跳过")
            NotchTransientCenter.shared.show(.init(icon: "forward.end", text: text, progress: nil))
        case .needsAccessibility?:
            AccessibilitySkipPress.promptForTrust()
            NotchTransientCenter.shared.show(.init(icon: "hand.raised", text: L10n.t("跳过广告需要「辅助功能」权限"), progress: nil),
                                             for: 2.4)
        case .tabNotFrontmost?:
            NotchTransientCenter.shared.show(.init(icon: "macwindow", text: L10n.t("把 YouTube Music 标签页切到前面再试"), progress: nil),
                                             for: 2.4)
        case .clickedNoEffect?, .notFound?, nil:
            NotchTransientCenter.shared.show(.init(icon: "megaphone", text: L10n.t("没能跳过这条广告"), progress: nil))
        }
    }
}
