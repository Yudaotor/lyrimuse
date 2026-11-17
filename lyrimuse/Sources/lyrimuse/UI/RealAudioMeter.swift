import AppKit
import Combine
import CoreAudio
import Foundation
import LyrimuseCore
import os

/// 灵动岛音浪「跟随音乐跳动」(`AppSettings.notchEqualizerFollowsAudio`)的电平源。
///
/// 只在有人要的时候读:开关开着、而且有一扇灵动岛的音浪此刻在播、在窗口里(`EqualizerBarsNSView` 来登记)。
/// 读的是此刻那个播放器的进程(`ProcessAudioTap`,macOS 14.2+);换了播放器就换 tap,没人要了过几秒拆掉。
/// 读不到(没授权、播放器不在本机出声、系统太旧)时各音浪照旧走歌词时间轴那套(`EqualizerBarCurve`),判据在
/// `RealAudioLevelGate`。只读频段能量,采样不出内存、不写盘。见 05 章决策 146。
@MainActor
final class RealAudioMeter: ObservableObject {
    static let shared = RealAudioMeter()

    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "real-audio")

    /// 系统支不支持进程级 tap。
    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    /// 播放器在出声、却一直只读到静音:多半没给「仅系统录音」授权。设置页据此提示。
    @Published private(set) var likelyDenied = false
    /// 此刻音浪是不是跟着真实音频在跳。
    private(set) var isLive = false
    private(set) var lastLevels: [Double] = []

    private struct WeakBars { weak var view: EqualizerBarsNSView? }
    private var listeners: [ObjectIdentifier: WeakBars] = [:]
    private var bundleTimer: Timer?
    private var wantedBundleID: String?
    private var settingsSubscription: AnyCancellable?
    private let engine: RealAudioEngine

    private init() {
        engine = RealAudioEngine()
        engine.onUpdate = { [weak self] update in
            DispatchQueue.main.async { self?.receive(update) }
        }
        // 开关从关拨到开的那一下就去要授权(没在播也弹),别等到下一次播放才突然弹框。
        settingsSubscription = AppSettings.shared.$notchEqualizerFollowsAudio
            .removeDuplicates().dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                if on { self.engine.primeAuthorization() } else { self.likelyDenied = false }
                self.refreshDemand(followsAudio: on)
            }
    }

    /// 一扇音浪要不要真实电平。音浪在播、在窗口里、开关开着时登记,否则撤销。
    func setListening(_ view: EqualizerBarsNSView, _ listening: Bool) {
        let key = ObjectIdentifier(view)
        if listening {
            listeners[key] = WeakBars(view: view)
            if isLive { view.realAudioModeChanged(live: true) }
        } else {
            listeners[key] = nil
        }
        refreshDemand()
    }

    /// `followsAudio` 给了就用它(设置订阅里 @Published 还没写进去),没给就现读设置。
    private func refreshDemand(followsAudio: Bool? = nil) {
        listeners = listeners.filter { $0.value.view != nil }
        let follows = followsAudio ?? AppSettings.shared.notchEqualizerFollowsAudio
        let wanted = follows && Self.isSupported && !listeners.isEmpty
        if wanted {
            if bundleTimer == nil {
                // 换播放器不一定伴随暂停 / 换行(两个播放器先后在放),定时看一眼此刻是谁在放。
                let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.syncBundle() }
                }
                timer.tolerance = 0.5
                RunLoop.main.add(timer, forMode: .common)
                bundleTimer = timer
            }
            syncBundle()
        } else {
            bundleTimer?.invalidate()
            bundleTimer = nil
            wantedBundleID = nil
            engine.want(bundleID: nil)
        }
    }

    private func syncBundle() {
        let id = LocalPlaybackSource.shared.lastResolvedBundleID ?? ""
        guard id != wantedBundleID else { return }
        wantedBundleID = id
        engine.want(bundleID: id)
    }

    private func receive(_ update: RealAudioEngine.Update) {
        if update.likelyDenied != likelyDenied { likelyDenied = update.likelyDenied }
        if update.live != isLive {
            isLive = update.live
            Self.logger.info("real-audio: live=\(update.live, privacy: .public) bundle=\(self.wantedBundleID ?? "", privacy: .public)")
            for entry in listeners.values { entry.view?.realAudioModeChanged(live: update.live) }
        }
        guard update.live, let levels = update.levels else { return }
        lastLevels = levels
        for entry in listeners.values { entry.view?.applyRealLevels(levels) }
    }

    /// `debug/state` 里的那一段。
    var debugState: [String: Any] {
        ["enabled": AppSettings.shared.notchEqualizerFollowsAudio, "supported": Self.isSupported,
         "listeners": listeners.values.filter { $0.view != nil }.count, "bundle": wantedBundleID ?? "",
         "live": isLive, "likelyDenied": likelyDenied,
         "levels": lastLevels.map { ($0 * 1000).rounded() / 1000 },
         "engine": engine.debugState()]
    }
}

/// tap 的建拆和逐帧分析,全在自己那条串行队列上做(建 tap、建聚合设备要几十毫秒,不能放主线程)。
/// 有 tap 时每秒分析 30 次,没有 tap 时每 2 秒看一次要读的播放器出现了没有;没人要了 `stopGrace` 秒后拆掉。
private final class RealAudioEngine: @unchecked Sendable {
    struct Update: Sendable {
        var live: Bool
        var likelyDenied: Bool
        /// 已按条子顺序排好、已抬上地板的 5 个高度比例;不在跟随时 nil。
        var levels: [Double]?
    }

    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "real-audio")
    private static let analysisInterval: Double = 1.0 / 30
    private static let idleInterval: Double = 2
    /// 暂停、窗口暂时不在时不马上拆:几秒内又要的话接着用,不来回建。
    private static let stopGrace: Double = 3
    /// 开开关时建一个全局 tap 去触发授权框,读这么久就拆。
    private static let primeSeconds: Double = 1.5

    var onUpdate: (@Sendable (Update) -> Void)?

    private let queue = DispatchQueue(label: "lyrimuse.real-audio", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var timerInterval: Double = 0
    /// 要读的播放器;nil = 没人要,空串 = 有人要但此刻没识别出播放器。
    private var bundleID: String?
    private var stopGeneration = 0
    private var tap: AnyObject?
    private var analyzer: RealAudioSpectrum.Analyzer?
    private var follower = RealAudioBandFollower()
    private var delay = RealAudioDelayLine()
    private var gate = RealAudioLevelGate()
    private var lastCallbacks = 0
    private var lastHeard = 0
    private var lastAnalysisAt: Double?
    private var nextRetargetAt: Double = 0
    private var latency: Double = 0
    private var playerOutputting = false
    private var lastSent: (live: Bool, denied: Bool)?
    private var primeTap: AnyObject?
    private var tapTargets: [AudioObjectID] = []
    /// tap 着的进程,`debug/state` 用:「bundle id pid」。
    private var tapProcesses: [String] = []

    func want(bundleID: String?) {
        queue.async { self.apply(bundleID: bundleID) }
    }

    func primeAuthorization() {
        queue.async {
            guard #available(macOS 14.2, *), self.tap == nil, self.primeTap == nil else { return }
            self.primeTap = ProcessAudioTap(processObjects: [], label: "permission")
            self.queue.asyncAfter(deadline: .now() + Self.primeSeconds) { self.primeTapStop() }
        }
    }

    func debugState() -> [String: Any] {
        queue.sync {
            ["tap": tap != nil, "targets": tapTargets.count, "processes": tapProcesses, "latencyMs": Int((latency * 1000).rounded()),
             "everHeard": gate.everHeard, "playerOutputting": playerOutputting, "callbacks": lastCallbacks]
        }
    }

    private func apply(bundleID newValue: String?) {
        if let newValue {
            stopGeneration += 1
            if newValue != bundleID {
                bundleID = newValue
                teardownTap()
                nextRetargetAt = 0
            }
            schedule(interval: tap == nil ? Self.idleInterval : Self.analysisInterval, immediately: true)
        } else {
            guard bundleID != nil else { return }
            stopGeneration += 1
            let generation = stopGeneration
            queue.asyncAfter(deadline: .now() + Self.stopGrace) {
                guard generation == self.stopGeneration else { return }
                self.bundleID = nil
                self.teardownTap()
                self.timer?.cancel()
                self.timer = nil
                self.timerInterval = 0
                self.send(live: false, denied: false, levels: nil)
            }
        }
    }

    private func schedule(interval: Double, immediately: Bool) {
        if timer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            t.schedule(deadline: .now() + (immediately ? 0 : interval), repeating: interval, leeway: .milliseconds(5))
            timerInterval = interval
            t.resume()
        } else if interval != timerInterval {
            timer?.schedule(deadline: .now() + (immediately ? 0 : interval), repeating: interval, leeway: .milliseconds(5))
            timerInterval = interval
        }
    }

    private func teardownTap() {
        if #available(macOS 14.2, *) { (tap as? ProcessAudioTap)?.stop() }
        tap = nil
        tapTargets = []
        tapProcesses = []
        analyzer = nil
        gate.tapStopped()
        follower.reset()
        delay.removeAll()
        lastCallbacks = 0
        lastHeard = 0
        lastAnalysisAt = nil
    }

    private func tick() {
        guard #available(macOS 14.2, *), let bundleID else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now >= nextRetargetAt {
            nextRetargetAt = now + Self.idleInterval
            retarget(bundleID: bundleID, now: now)
        }
        guard let tap = tap as? ProcessAudioTap, let analyzer else {
            send(live: false, denied: gate.likelyDenied(now: now, playerOutputting: playerOutputting), levels: nil)
            return
        }
        let snap = tap.snapshot()
        if snap.callbacks > lastCallbacks {
            let heard = snap.heardCallbacks > lastHeard
            lastCallbacks = snap.callbacks
            lastHeard = snap.heardCallbacks
            gate.noteCallbacks(at: now, heard: heard)
            let dt = lastAnalysisAt.map { now - $0 } ?? Self.analysisInterval
            lastAnalysisAt = now
            let levels = follower.update(powers: analyzer.bandPowers(snap.samples), dt: dt)
            delay.push(time: now, levels: RealAudioSpectrum.barBand.map { RealAudioSpectrum.barLevel(levels[$0]) })
        }
        let live = gate.isLive(now: now)
        let denied = gate.likelyDenied(now: now, playerOutputting: playerOutputting)
        send(live: live, denied: denied, levels: live ? delay.pop(now: now, delay: latency) : nil)
    }

    @available(macOS 14.2, *)
    private func retarget(bundleID: String, now: Double) {
        let rows = ProcessAudioOutput.tapTargets(bundleID: bundleID)
        let targets = rows.map(\.object)
        playerOutputting = rows.contains(where: \.outputting)
        latency = ProcessAudioOutput.defaultOutputLatencySeconds()
        guard ProcessAudioOutput.needsRetap(targets: targets, tapped: tapTargets, tapOutputUID: (tap as? ProcessAudioTap)?.outputDeviceUID,
                                            outputUID: ProcessAudioTap.defaultOutputDeviceUID()) else { return }
        teardownTap()
        guard !targets.isEmpty else {
            schedule(interval: Self.idleInterval, immediately: false)
            return
        }
        primeTapStop()
        guard let created = ProcessAudioTap(processObjects: targets, label: "notch-equalizer"),
              let analyzer = RealAudioSpectrum.Analyzer(sampleRate: created.sampleRate) else {
            schedule(interval: Self.idleInterval, immediately: false)
            return
        }
        tap = created
        tapTargets = targets
        tapProcesses = rows.map { "\($0.bundleID) \($0.pid)" }
        self.analyzer = analyzer
        gate.tapStarted(at: now)
        Self.logger.info("real-audio: tap bundle=\(bundleID, privacy: .public) processes=\(targets.count, privacy: .public) latencyMs=\(Int(self.latency * 1000), privacy: .public)")
        schedule(interval: Self.analysisInterval, immediately: false)
    }

    private func primeTapStop() {
        if #available(macOS 14.2, *) { (primeTap as? ProcessAudioTap)?.stop() }
        primeTap = nil
    }

    private func send(live: Bool, denied: Bool, levels: [Double]?) {
        let changed = lastSent.map { $0.live != live || $0.denied != denied } ?? true
        guard changed || levels != nil else { return }
        lastSent = (live, denied)
        onUpdate?(Update(live: live, likelyDenied: denied, levels: levels))
    }
}
