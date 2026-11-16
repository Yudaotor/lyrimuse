import Foundation

/// 诊断包里的两段权限诊断,只读、只出诊断,不碰权限申请流程(见 02 章决策 256):
/// - `automationLines`:要查的播放器里靠脚本接口取数的那几家,各自的「自动化」授权状态;在跑且已授权的再用脚本只读问一次
///   播放状态和有没有歌名(`AutomationReadProbe`)。
/// - `browserLines`:「网页播放器」卡配对的各浏览器:Lyrimuse 对它的「自动化」授权,和它自己那道「允许 Apple 事件中的 JavaScript」
///   开关(见 02 章决策 257)。
/// - `accessLines`:Lyrimuse 自己的「辅助功能」与「完全磁盘访问」授权状态,以及要查的播放器里哪几家的哪些能力靠它们。
///
/// 要查的播放器跟 `PlayerReportingDiagnostics.watchedPlayers` 同一个口径。
public enum PermissionDiagnostics {
    /// 一次脚本只读探测的结果。
    public enum ReadProbe: Equatable, Sendable {
        /// 读到了播放状态。`hasTitle` 只说有没有歌名,不带原文。
        case ok(state: String, hasTitle: Bool)
        /// 脚本按进程号找播放器时它已经不在了。
        case notRunning
        /// Apple Event 报错,带错误码。
        case appleEventError(Int)
        case timedOut
        /// osascript 非零退出,或输出解不出来。
        case failed(String)
    }

    // MARK: - 自动化

    /// 「自动化」那一段。`runningBundleID` 给这个播放器此刻在跑的那个 bundle id(没在跑为 nil);`grant` 给在跑的那个 bundle id
    /// 的授权状态(nil = 查询超时);`lastKnown` 是它上次运行时查到的结论;`probe` 只对在跑且已授权的调。纯函数,selftest 覆盖。
    public static func automationLines(
        selected: Set<PlaybackPlayer>,
        runningBundleID: (PlaybackPlayer) -> String?,
        grant: (PlaybackPlayer) -> AutomationAlert.Grant?,
        lastKnown: (PlaybackPlayer) -> AutomationAlert.Grant?,
        probe: (PlaybackPlayer, String) -> ReadProbe
    ) -> [String] {
        var lines = ["== Automation permission (selected players) =="]
        let players = PlayerReportingDiagnostics.watchedPlayers(selected: selected) { runningBundleID($0) != nil }
            .filter(\.needsAutomationPermission)
        if selected.contains(.auto) { lines.append("Auto-detect is on: running built-in players are listed too") }
        if players.isEmpty { lines.append("(no selected or running player reads through its script interface)") }
        for player in players {
            guard let bundleID = runningBundleID(player) else {
                let last = lastKnown(player).map(describe) ?? "none"
                lines.append("- \(player.rawValue): not running | last known: \(last) | read probe: skipped (not running)")
                continue
            }
            let status = grant(player)
            let timedOut = "query timed out (last known: \(lastKnown(player).map(describe) ?? "none"))"
            let head = "- \(player.rawValue) (\(bundleID)): running | TCC: \(status.map(describe) ?? timedOut)"
            switch status {
            case .authorized?:
                lines.append(head + " | read probe: " + describe(probe(player, bundleID)))
            case .denied?:
                lines.append(head + " | read probe: skipped (denied)")
            case .undetermined?:
                lines.append(head + " | read probe: skipped (not asked yet, a read would prompt)")
            case nil:
                lines.append(head + " | read probe: skipped")
            }
        }
        return lines
    }

    static func describe(_ grant: AutomationAlert.Grant) -> String {
        switch grant {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .undetermined: return "not determined"
        }
    }

    static func describe(_ probe: ReadProbe) -> String {
        switch probe {
        case let .ok(state, hasTitle): return "ok state=\(state) title=\(hasTitle ? "present" : "empty")"
        case .notRunning: return "player quit before the read"
        case let .appleEventError(code):
            switch code {
            case -1743: return "failed: not authorized (-1743)"
            case -1712: return "failed: Apple Event timed out (-1712)"
            case -600: return "failed: app not running (-600)"
            default: return "failed: Apple Event error \(code)"
            }
        case .timedOut: return "timed out"
        case let .failed(reason): return "failed: \(reason)"
        }
    }

    // MARK: - 网页播放器配对的浏览器

    /// 一个配对浏览器此刻查到的事实。只读得来:TCC 只问在跑的、`askIfNeeded: false`;开关读的是偏好文件
    /// (`BrowserAutomationPermission.status`,不执行 JavaScript);另两条是已存的证据。
    public struct BrowserFacts: Equatable, Sendable {
        public var family: BrowserAutomationPermission.Family?
        public var installed: Bool
        public var running: Bool
        /// 在跑时的授权状态;nil = 没在跑没问,或查询超时。
        public var grant: AutomationAlert.Grant?
        public var jsPref: BrowserAutomationPermission.Status
        public var prefsLocationKnown: Bool
        public var appFullDiskAccess: Bool
        /// 设置里「检测是否已生效」上次通过的时刻(明确失败会抹掉)。
        public var selfTestPassedAt: Date?
        /// 这次运行里最近一次有页面脚本读到它的标签页。
        public var lastPageRead: (platformID: String, at: Date)?

        public init(family: BrowserAutomationPermission.Family?, installed: Bool, running: Bool,
                    grant: AutomationAlert.Grant?, jsPref: BrowserAutomationPermission.Status,
                    prefsLocationKnown: Bool, appFullDiskAccess: Bool,
                    selfTestPassedAt: Date?, lastPageRead: (platformID: String, at: Date)?) {
            self.family = family
            self.installed = installed
            self.running = running
            self.grant = grant
            self.jsPref = jsPref
            self.prefsLocationKnown = prefsLocationKnown
            self.appFullDiskAccess = appFullDiskAccess
            self.selfTestPassedAt = selfTestPassedAt
            self.lastPageRead = lastPageRead
        }

        public static func == (a: BrowserFacts, b: BrowserFacts) -> Bool {
            a.family == b.family && a.installed == b.installed && a.running == b.running && a.grant == b.grant
                && a.jsPref == b.jsPref && a.prefsLocationKnown == b.prefsLocationKnown
                && a.appFullDiskAccess == b.appFullDiskAccess && a.selfTestPassedAt == b.selfTestPassedAt
                && a.lastPageRead?.platformID == b.lastPageRead?.platformID && a.lastPageRead?.at == b.lastPageRead?.at
        }
    }

    /// 「网页播放器配对的浏览器」那一段。`pairs` 是平台 → 浏览器 bundle id(`AppSettings.browserPlatformPairs`),
    /// 每个浏览器一行授权、一行 JS 开关。纯函数,selftest 覆盖。
    public static func browserLines(pairs: [String: Set<String>], facts: (String) -> BrowserFacts) -> [String] {
        var lines = ["== Browser permissions (paired web players) =="]
        var platformsByBrowser: [String: [String]] = [:]
        for (platformID, browsers) in pairs {
            for browser in browsers { platformsByBrowser[browser, default: []].append(platformID) }
        }
        if platformsByBrowser.isEmpty { lines.append("(no web player is paired with a browser)") }
        let iso = ISO8601DateFormatter()
        for bundleID in platformsByBrowser.keys.sorted() {
            let f = facts(bundleID)
            let head = "- \(bundleID) (paired for \(platformsByBrowser[bundleID, default: []].sorted().joined(separator: ", ")))"
            guard f.installed else { lines.append(head + ": not installed"); continue }
            guard f.family != nil else {
                lines.append(head + ": not scriptable (no JavaScript command in its scripting dictionary)")
                continue
            }
            if f.running {
                lines.append(head + ": running | TCC: " + (f.grant.map(describe) ?? "query timed out"))
            } else {
                lines.append(head + ": not running | TCC: not queried (only answered for a running app)")
            }
            let selfTest = f.selfTestPassedAt.map { iso.string(from: $0) } ?? "none"
            let pageRead = f.lastPageRead.map { "\(iso.string(from: $0.at)) (\($0.platformID))" } ?? "none"
            lines.append("    JavaScript from Apple Events: pref (applies on next launch): \(describePref(f))"
                         + " | last self-test pass: \(selfTest) | last page read this session: \(pageRead)")
        }
        return lines
    }

    public static func describePref(_ f: BrowserFacts) -> String {
        switch f.jsPref {
        case .enabled: return "enabled"
        case .disabled: return "disabled"
        case .unsupported: return "unknown (not a registered browser)"
        case .unknown:
            if !f.prefsLocationKnown { return "unknown (where this browser stores it is not registered)" }
            if !f.appFullDiskAccess { return "unknown (reading it needs Full Disk Access)" }
            return f.family == .safari ? "unknown (no value set)" : "unknown (preferences file missing or unreadable)"
        }
    }

    // MARK: - 辅助功能与完全磁盘访问

    /// 「辅助功能 / 完全磁盘访问」那一段。完全磁盘访问分两行:App 进程自己探到的,和引擎发布的各来源结论(真正去读播放器容器的
    /// 是引擎,`LocalCacheAccess` 头注)。纯函数,selftest 覆盖。
    public static func accessLines(
        selected: Set<PlaybackPlayer>, isRunning: (PlaybackPlayer) -> Bool,
        accessibilityTrusted: Bool, accessibilityEverGranted: Bool,
        appFullDiskAccess: Bool, fullDiskAccessEverGranted: Bool,
        engineState: LocalCacheAccess.State?
    ) -> [String] {
        var lines = ["== Accessibility / Full Disk Access (selected players) =="]
        let players = PlayerReportingDiagnostics.watchedPlayers(selected: selected, isRunning: isRunning)
        if selected.contains(.auto) { lines.append("Auto-detect is on: running built-in players are listed too") }

        lines.append("Accessibility (Lyrimuse): " + grantText(accessibilityTrusted, everGranted: accessibilityEverGranted))
        let axPlayers = players.filter(\.needsAccessibilityPermission)
        if axPlayers.isEmpty { lines.append("  (no selected or running player uses it)") }
        for player in axPlayers {
            guard let use = player.accessibilityUse else { continue }
            lines.append("  - \(player.rawValue): \(describe(use).uses)")
            if !accessibilityTrusted { lines.append("      without it: \(describe(use).without)") }
        }

        lines.append("Full Disk Access (Lyrimuse app process): " + grantText(appFullDiskAccess, everGranted: fullDiskAccessEverGranted))
        lines.append("Full Disk Access (engine): "
                     + (engineState.map { "last published \(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval($0.updatedAt))))" }
                        ?? "no state published (engine not running or not probed yet)"))
        let fdaPlayers = players.filter(\.needsFullDiskAccess)
        if fdaPlayers.isEmpty { lines.append("  (no selected or running player uses it)") }
        for player in fdaPlayers {
            guard let use = player.fullDiskAccessUse else { continue }
            let engine = engineVerdict(player.localCacheSource, state: engineState)
            lines.append("  - \(player.rawValue): \(describe(use).uses) | engine: \(engine)")
            if engine == "denied" { lines.append("      without it: \(describe(use).without)") }
        }
        return lines
    }

    static func grantText(_ granted: Bool, everGranted: Bool) -> String {
        if granted { return "granted" }
        return everGranted ? "NOT granted (was granted on this Mac before: likely invalidated by an update or re-sign)"
            : "NOT granted"
    }

    /// 引擎对这个来源的结论:`readable` / `denied` / `not protected`(读的那一份不在私有容器里)/ `not probed`。
    public static func engineVerdict(_ source: String?, state: LocalCacheAccess.State?) -> String {
        guard let source else { return "not tracked" }
        guard let state else { return "not probed" }
        if state.denied.contains(source) { return "denied" }
        if state.unprotected.contains(source) { return "not protected (no grant needed)" }
        if state.readable.contains(source) { return "readable" }
        return "not probed (not installed, or older engine)"
    }

    static func describe(_ use: PlaybackPlayer.AccessibilityUse) -> (uses: String, without: String) {
        switch use {
        case .calibratesProgress:
            return ("reads the on-screen time to correct position; presses shuffle / repeat on its player bar",
                    "position may be off by 1-2 s after auto-advance; no shuffle / repeat buttons")
        case .switchesPlayMode:
            return ("reads and presses its shuffle / repeat / favorite menus; presses its playback menu while another app holds Now Playing focus",
                    "no shuffle / repeat / favorite buttons; playback controls do nothing while it lacks Now Playing focus")
        case .controlsPlayback:
            return ("reads and presses its favorite control; presses its playback controls while another app holds Now Playing focus",
                    "no favorite button; playback controls do nothing while it lacks Now Playing focus")
        case .controlsTransport:
            return ("presses its play / pause / previous / next menu items while another app holds Now Playing focus",
                    "playback controls do nothing while it lacks Now Playing focus")
        case .pressesPlayMode:
            return ("reads and presses shuffle / repeat in its menu; reads and sets its volume slider; presses its playback menu while another app holds Now Playing focus",
                    "no shuffle / repeat buttons or volume; playback controls do nothing while it lacks Now Playing focus")
        case .refinesProgress:
            return ("reads its progress bar to refine whole-second position; reads its playlist for pre-resolve; presses repeat in its menu; reads and sets volume",
                    "lyrics may be about 0.5 s off after seeking; no repeat button or volume; playback controls do nothing while it lacks Now Playing focus")
        case .adjustsModeAndVolume:
            return ("reads and presses shuffle / repeat on its window; reads and sets its volume slider",
                    "no shuffle / repeat buttons or volume (lyrics and playback controls still work)")
        case .switchesModeAndTransport:
            return ("reads and presses the play-mode button on its window; presses its playback menu while another app holds Now Playing focus",
                    "no shuffle / repeat buttons; playback controls do nothing while it lacks Now Playing focus")
        }
    }

    static func describe(_ use: PlaybackPlayer.FullDiskAccessUse) -> (uses: String, without: String) {
        switch use {
        case .readsLyricsAndQueue:
            return ("engine reads its lyrics cache and play queue in its private container",
                    "its own cached lyrics are skipped (lyrics are searched online) and upcoming tracks are not pre-resolved")
        case .readsQueue:
            return ("engine reads its play queue in its private container",
                    "pre-resolve falls back to other tracks of the same album")
        }
    }
}

/// 「自动化」诊断的只读探测:按进程号找到在跑的播放器,只读播放状态和当前曲目的歌名,报错时交回 Apple Event 错误码。
/// 每次起一个新的 osascript,不走常驻那个。按进程号发事件,播放器在两步之间退掉也不会被拉起(`JXARunningApp`)。
/// 只在授权状态已经是「已授权」时调:未决时发 Apple Event 会弹授权框。
public enum AutomationReadProbe {
    public static let timeout: TimeInterval = 3

    /// 每家读状态和歌名的 JS 表达式,`P` 是播放器对象。只读属性,不调任何会改播放器状态的命令。
    /// 需要自动化权限的播放器每一家都要有一条,selftest 守着。
    public static func expressions(for player: PlaybackPlayer) -> (state: String, title: String)? {
        switch player {
        case .appleMusic, .spotify, .swinsian:
            return ("P.playerState()", "P.currentTrack.name()")
        case .vox:
            return ("(() => { const s = P.playerState(); return s === 1 ? 'playing' : s === 0 ? 'paused' : 'stopped(' + s + ')'; })()",
                    "P.track()")
        case .audirvana:
            return ("P.playerState()", "P.playingTrackTitle()")
        case .kaset:
            return ("(() => { const i = JSON.parse(P.getPlayerInfo()); return i.isPlaying ? 'playing' : i.isPaused ? 'paused' : 'idle'; })()",
                    "(JSON.parse(P.getPlayerInfo()).currentTrack || {}).name")
        default:
            return nil
        }
    }

    /// 发给 osascript 的 JXA。输出一行 JSON:`{"notRunning":true}`、`{"error":<码>}` 或 `{"state":…,"title":<有没有>}`。
    public static func script(for player: PlaybackPlayer, bundleID: String) -> String? {
        guard let expr = expressions(for: player) else { return nil }
        return """
        (() => {
            \(JXARunningApp.attach("P", bundleID: bundleID, notRunning: "JSON.stringify({ notRunning: true })"))
            let state;
            try { state = String(\(expr.state)); } catch (e) {
                return JSON.stringify({ error: typeof e.errorNumber === "number" ? e.errorNumber : null });
            }
            let title = "";
            try { title = String(\(expr.title) || ""); } catch (e) { title = ""; }
            return JSON.stringify({ state: state, title: title.length > 0 });
        })()
        """
    }

    private struct Output: Decodable {
        let notRunning: Bool?
        let error: Int?
        let state: String?
        let title: Bool?
    }

    /// osascript 的结果 → 探测结论。纯函数,selftest 覆盖。
    public static func parse(status: Int32, stdout: Data, timedOut: Bool) -> PermissionDiagnostics.ReadProbe {
        if timedOut { return .timedOut }
        guard status == 0 else { return .failed("osascript exit \(status)") }
        guard let out = try? JSONDecoder().decode(Output.self, from: stdout) else { return .failed("unreadable output") }
        if out.notRunning == true { return .notRunning }
        if out.state == nil, out.title == nil {
            return out.error.map(PermissionDiagnostics.ReadProbe.appleEventError) ?? .failed("script error without a code")
        }
        return .ok(state: String((out.state ?? "").prefix(24)), hasTitle: out.title == true)
    }

    /// 真跑一次。会起子进程、最多阻塞 `timeout` 秒,别在主线程上调。
    public static func run(_ player: PlaybackPlayer, bundleID: String) -> PermissionDiagnostics.ReadProbe {
        guard let source = script(for: player, bundleID: bundleID) else { return .failed("no probe for this player") }
        guard let r = ProcessRunner.run("/usr/bin/osascript", ["-l", "JavaScript", "-e", source], timeout: timeout) else {
            return .failed("osascript did not start")
        }
        return parse(status: r.status, stdout: r.stdout, timedOut: r.timedOut)
    }
}
