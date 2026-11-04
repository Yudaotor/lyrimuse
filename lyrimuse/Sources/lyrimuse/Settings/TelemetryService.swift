import Combine
import Foundation
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "telemetry")

/// 匿名遥测的发送端。启动一分钟后查一次、之后每三小时查一次:今天还没发过心跳就发一条,有新的崩溃报告就各发一条。
/// 发什么、怎么脱敏在 Core `Telemetry`;这边只读设置、扫崩溃报告、发请求、记账。
///
/// 关着(`AppSettings.telemetryEnabled` 为假)时不发,也不记活动;关掉那一刻清空记下的活动。崩溃报告只发打开遥测
/// 之后出现的。只在正式身份下跑,Dev 变体与 selftest 不发。见 14 章决策 149。
@MainActor
final class TelemetryService {
    static let shared = TelemetryService()

    enum Keys {
        static let installID = "np:telemetryInstallID"
        static let lastHeartbeatDay = "np:telemetryLastHeartbeatDay"
        /// 发过的崩溃报告(`Telemetry.reportID`),最多留 `Telemetry.sentCrashMemory` 条。
        static let sentCrashReports = "np:telemetrySentCrashReports"
        /// `yyyy-MM-dd|条数`:今天发了几条崩溃。
        static let crashesSentDay = "np:telemetryCrashesSentDay"
        /// 这一次打开遥测的时刻;更早的崩溃报告不发。
        static let enabledSince = "np:telemetryEnabledSince"
        /// `TelemetryInstallOrigin` 的取值,判不出记 `unknown`;只判一次。
        static let installOrigin = "np:telemetryInstallOrigin"
    }

    static let firstCheckDelay: Duration = .seconds(60)
    static let checkInterval: TimeInterval = 3 * 3600

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var trustedSubscription: AnyCancellable?
    private var started = false
    private var checking = false

    private init() {}

    func start() {
        guard !started, Bundle.main.bundleIdentifier == LyrimuseIdentity.bundleIdentifier else { return }
        started = true
        decideInstallOrigin()
        apply(enabled: AppSettings.shared.telemetryEnabled)
        trustedSubscription = FeatureSettingsStore.shared.$trustedPlayers.sink { trusted in
            TelemetryActivity.shared.trustedBundleIDs = Set(trusted.keys)
        }
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { _ in
            Task { @MainActor in await TelemetryService.shared.checkNow() }
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task {
            try? await Task.sleep(for: Self.firstCheckDelay)
            await checkNow()
        }
    }

    /// `AppSettings.telemetryEnabled` 的 didSet 调进来。
    func preferenceChanged(enabled: Bool) {
        guard started else { return }
        apply(enabled: enabled)
        if enabled { Task { await checkNow() } }
    }

    private func apply(enabled: Bool) {
        TelemetryActivity.shared.isRecording = enabled
        if enabled {
            if defaults.object(forKey: Keys.enabledSince) == nil { defaults.set(Date(), forKey: Keys.enabledSince) }
        } else {
            TelemetryActivity.shared.clear()
            defaults.removeObject(forKey: Keys.enabledSince)
        }
    }

    func checkNow() async {
        guard started, AppSettings.shared.telemetryEnabled, !checking else { return }
        checking = true
        defer { checking = false }
        let env = environment()
        let installID = installID()
        let today = Telemetry.day(Date())
        if Telemetry.heartbeatDue(today: today, lastSentDay: defaults.string(forKey: Keys.lastHeartbeatDay)) {
            let activity = TelemetryActivity.shared.completedDays(before: today)
            let beat = TelemetryHeartbeat(installID: installID, day: today, env: env, features: await features(),
                                          activity: activity,
                                          origin: defaults.string(forKey: Keys.installOrigin).flatMap(TelemetryInstallOrigin.init(rawValue:)))
            if let status = await post(beat, to: Telemetry.heartbeatURL, operation: "heartbeat"), (200..<300).contains(status) {
                defaults.set(today, forKey: Keys.lastHeartbeatDay)
                TelemetryActivity.shared.remove(days: activity.map(\.day))
            }
        }
        await sendNewCrashes(installID: installID, env: env, today: today)
    }

    /// 此刻会发的那条心跳(排好版的 JSON),给 `debug/telemetry-preview` 用:不发、不改记账,遥测关着也照样生成。
    func previewHeartbeat() async throws -> Data {
        let today = Telemetry.day(Date())
        let beat = TelemetryHeartbeat(installID: defaults.string(forKey: Keys.installID) ?? "(no install id yet)", day: today,
                                      env: environment(), features: await features(),
                                      activity: TelemetryActivity.shared.completedDays(before: today),
                                      origin: defaults.string(forKey: Keys.installOrigin).flatMap(TelemetryInstallOrigin.init(rawValue:)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(beat)
    }

    private func sendNewCrashes(installID: String, env: TelemetryEnvironment, today: String) async {
        guard let since = defaults.object(forKey: Keys.enabledSince) as? Date else { return }
        var count = crashesSent(on: today)
        guard count < Telemetry.maxCrashesPerDay else { return }
        let cutoff = max(since, Date().addingTimeInterval(-Telemetry.crashLookback))
        var sent = defaults.stringArray(forKey: Keys.sentCrashReports) ?? []
        let alreadySent = Set(sent)
        // 发过的按文件名先跳过,不再读、不再解析。
        let scan = await Task.detached {
            DiagnosticsExporter.scanCrashReports(since: cutoff) { alreadySent.contains(Telemetry.reportID(fileName: $0)) }
        }.value
        for report in scan.reports.sorted(by: { $0.modified < $1.modified }) {
            guard count < Telemetry.maxCrashesPerDay else { break }
            let id = Telemetry.reportID(fileName: report.summary.fileName)
            let crash = TelemetryCrash(summary: report.summary, reportID: id,
                                       executableName: DiagnosticsExporter.crashExecutableName,
                                       installID: installID, env: env)
            let status = await post(crash, to: Telemetry.crashURL, operation: "crash")
            // 4xx 是这一份本身不合格(过大、字段不对),重发也一样,记为发过、接着发下一份;连不上、5xx、429(限流)才停下等下次。
            if let status, (400..<500).contains(status), status != 429 {
                logger.notice("telemetry: crash report rejected with \(status, privacy: .public), skipped")
            } else if !(status.map { (200..<300).contains($0) } ?? false) {
                break
            } else {
                count += 1
                defaults.set("\(today)|\(count)", forKey: Keys.crashesSentDay)
            }
            sent.append(id)
            defaults.set(Array(sent.suffix(Telemetry.sentCrashMemory)), forKey: Keys.sentCrashReports)
        }
    }

    private func crashesSent(on today: String) -> Int {
        guard let raw = defaults.string(forKey: Keys.crashesSentDay) else { return 0 }
        let parts = raw.split(separator: "|")
        guard parts.count == 2, parts[0] == today else { return 0 }
        return Int(parts[1]) ?? 0
    }

    /// 读的是上次启动留下的版本记录,所以 `start()` 必须排在 `WhatsNewCenter.shared.start()` 前面。
    private func decideInstallOrigin() {
        guard defaults.string(forKey: Keys.installOrigin) == nil else { return }
        let origin = TelemetryInstallOrigin.infer(
            hasInstallID: !(defaults.string(forKey: Keys.installID) ?? "").isEmpty,
            lastLaunched: defaults.string(forKey: WhatsNewCenter.Keys.lastLaunchedVersion),
            hasCompletedOnboarding: AppSettings.shared.hasCompletedOnboarding,
            storedBaseline: defaults.string(forKey: WhatsNewCenter.Keys.baseline))
        defaults.set(origin?.rawValue ?? "unknown", forKey: Keys.installOrigin)
    }

    private func installID() -> String {
        if let id = defaults.string(forKey: Keys.installID), !id.isEmpty { return id }
        let id = Telemetry.newInstallID()
        defaults.set(id, forKey: Keys.installID)
        return id
    }

    private func environment() -> TelemetryEnvironment {
        let info = Bundle.main.infoDictionary
        let language = AppSettings.shared.appLanguage
        return TelemetryEnvironment(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "0",
            build: info?["CFBundleVersion"] as? String ?? "0",
            osVersion: TelemetryEnvironment.osVersionString(ProcessInfo.processInfo.operatingSystemVersion),
            arch: TelemetryEnvironment.currentArch,
            uiLanguage: language == "system" ? UILanguage.resolve(preferredLanguages: Locale.preferredLanguages) : language,
            systemLanguage: TelemetryEnvironment.languageOnly(Locale.preferredLanguages.first ?? ""))
    }

    private func features() async -> TelemetryFeatures {
        let settings = AppSettings.shared
        let store = FeatureSettingsStore.shared
        let config = ConfigStore.shared
        let surfaces: [(Bool, String)] = [
            (settings.classicOverlayEnabled, "overlay"), (settings.notchOverlayEnabled, "notch"),
            (settings.showLyricsInMenuBar, "menubar"), (settings.showLyricsInTouchBar, "touchbar"),
            (settings.webLyricsEnabled, "web-lyrics"), (settings.obsLyricsEnabled, "obs"),
            (settings.discordPresenceEnabled, "discord"), (settings.nowPlayingNotifications, "notifications"),
            (LyricsWindowSession.shouldReopenAtLaunch, "lyrics-window"),
        ]
        let accounts: [(Bool, String)] = [
            (!config.lastfmScrobbleSessionKey.isEmpty, "lastfm"), (config.isListenBrainzConfigured, "listenbrainz"),
            (AppleMusicConnection.shared.isConnected, "apple-music"), (config.stateRelayMissingHint() == nil, "relay"),
            (config.pushMissingHint() == nil, "push"),
        ]
        return TelemetryFeatures(
            surfaces: surfaces.filter(\.0).map(\.1),
            playersSelected: store.players.map(\.rawValue),
            lyricsSourceMode: store.lyricsSourceMode.rawValue,
            lyricsSourcesEnabled: store.lyricsSources.count,
            translation: settings.showTranslation || settings.overlayShowTranslation,
            romanization: settings.showRomanization || settings.overlayShowRomanization,
            machineTranslation: store.lyricsMachineTranslation,
            accounts: accounts.filter(\.0).map(\.1),
            trustedPlayers: Array(store.trustedPlayers.keys),
            webPlatforms: settings.browserPlatformPairs.filter { !$0.value.isEmpty }.map(\.key),
            showInDock: settings.showInDock,
            launchAtLogin: settings.launchAtLoginEnabled,
            betaUpdates: settings.receiveBetaUpdates,
            installMethod: Telemetry.installMethod(caskroomExists: Telemetry.caskroomPaths.contains {
                FileManager.default.fileExists(atPath: $0)
            }),
            settingsChanged: Telemetry.changedSettings(current: settings.telemetrySettingValues(),
                                                       defaults: AppSettings.telemetryDefaultSettingValues()),
            permissionsMissing: await PlayerHealthMonitor.telemetryPermissionGaps())
    }

    /// 发一条,返回 HTTP 状态码;没发(关着、编码失败)或连不上为 nil。等回应的这段时间里用户关掉了遥测,这一条照样发完,
    /// 之后不再发。
    private func post<T: Encodable>(_ payload: T, to url: URL, operation: String) async -> Int? {
        guard AppSettings.shared.telemetryEnabled else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(payload) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        request.setValue("Lyrimuse/\(version)", forHTTPHeaderField: "User-Agent")
        let host = url.host ?? ""
        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            NetworkAuditLog.record(service: "telemetry", operation: operation, host: host, statusCode: status,
                                   durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
            return status
        } catch {
            NetworkAuditLog.record(service: "telemetry", operation: operation, host: host, statusCode: nil,
                                   durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            logger.notice("telemetry: \(operation, privacy: .public) not sent: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
