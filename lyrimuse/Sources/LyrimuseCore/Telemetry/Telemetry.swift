import CryptoKit
import Foundation
import NaturalLanguage

/// 匿名遥测的纯逻辑:发什么、什么时候发、崩溃摘要怎么脱敏。发请求在 App 侧 `TelemetryService`。
///
/// 两种事件,都 POST JSON 给作者自建的 Cloudflare Worker(仓库 `telemetry-worker/`):
/// - 心跳:每个本地自然日最多一条,带随机安装 ID、版本与系统、此刻开着哪些功能,以及之前几天记下的活动(放过哪些
///   播放器、主线程卡住几次)。
/// - 崩溃:App 和引擎的 .ips 报告各发一条摘要(异常类型、终止原因、故障线程的帧),每天最多 `maxCrashesPerDay` 条。
///
/// 不发歌名、歌手、专辑、本机路径、账号名和凭据:负载里只有枚举值、版本号、计数和开关;崩溃摘要里的路径一律换成
/// `<path>`,源码文件名不带。安装 ID 是本机随机生成的,不跟硬件或账号挂钩。关着时什么都不发,也不记活动。
/// 见 14 章决策 149。
public enum Telemetry {
    public static let endpoint = URL(string: "https://telemetry.yudaotor.me")!
    public static let heartbeatURL = endpoint.appendingPathComponent("v1/heartbeat")
    public static let crashURL = endpoint.appendingPathComponent("v1/crash")
    /// 负载格式版本,Worker 按它认字段。
    public static let schemaVersion = 1
    public static let maxCrashesPerDay = 5
    /// 只发这么久以内的崩溃报告;更早的不补。
    public static let crashLookback: TimeInterval = 7 * 86_400
    /// 记住最近发过的多少份崩溃报告,防重发。
    public static let sentCrashMemory = 50
    /// 崩溃摘要最多带几帧。
    public static let maxCrashFrames = 12
    /// 崩溃摘要里各字符串的长度上限,跟 Worker(telemetry-worker/src/index.js 的 crash())截的一致,两处要一起改。
    public static let crashSymbolLimit = 300, crashImageLimit = 80, crashReasonLimit = 300, crashIndicatorLimit = 200
    public static let crashShortFieldLimit = 80

    /// 本地自然日,`yyyy-MM-dd`,一律按公历算:系统日历设成佛历、和历时 `Calendar.current` 的年份不是公历年,Worker 会拒收。
    public static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 今天还没发过心跳。
    public static func heartbeatDue(today: String, lastSentDay: String?) -> Bool {
        lastSentDay != today
    }

    public static func newInstallID() -> String { UUID().uuidString.lowercased() }

    /// 崩溃报告的去重键:文件名的 SHA-256 前 16 位。
    public static func reportID(fileName: String) -> String {
        SHA256.hash(data: Data(fileName.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// 把文本里的绝对路径(含 `~/` 开头的)换成 `<path>`。崩溃报告的终止原因、异常说明里常带库和 App 的完整路径,
    /// 路径里有用户名。
    /// 引号里的整段都算路径(路径里可以有空格);没引号的,空格后面那个词里还有 `/` 就接着算(`/Applications/Lyrimuse 2.app/…`)。
    public static func redactPaths(_ text: String) -> String {
        text.replacingOccurrences(of: #"(['"])(~/|/)[^'"\n]*\1"#, with: "$1<path>$1", options: .regularExpression)
            .replacingOccurrences(of: #"(~/|(?<![A-Za-z0-9_.~<])/)[^\s'"()\[\],;]+(?: +[^\s'"()\[\],;/]*/[^\s'"()\[\],;]*)*"#,
                                  with: "<path>", options: .regularExpression)
    }

    /// 崩溃时间只发到哪一天(`yyyy-MM-dd`),不带时分秒和时区。
    public static func crashDay(_ timestamp: String?) -> String? {
        guard let timestamp, timestamp.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil else { return nil }
        return String(timestamp.prefix(10))
    }

    /// 播放器在负载里的写法:内置播放器用目录里的 id,用户信任的第三方播放器 / 浏览器用 bundle id,其余一律 `other`
    /// (没信任过的 App 不发出去)。
    public static func playerTag(forBundleID bundleID: String?, trusted: Set<String> = []) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let builtin = PlaybackPlayer.builtin(forBundleID: bundleID) { return builtin.rawValue }
        if trusted.contains(bundleID), let id = bundleIDTag(bundleID) { return id }
        return "other"
    }

    /// 能当 bundle id 发出去的写法:字母数字开头,只含字母数字、点和连字符,最长 100。别的(带空格、路径)不发。
    public static func bundleIDTag(_ id: String) -> String? {
        id.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]{0,99}$"#, options: .regularExpression) == nil ? nil : id
    }

    /// Homebrew cask 装的,Caskroom 里会有 `lyrimuse` 目录(Apple 芯片和 Intel 的 Homebrew 各一个位置)。
    public static let caskroomPaths = ["/opt/homebrew/Caskroom/lyrimuse", "/usr/local/Caskroom/lyrimuse"]

    /// 安装渠道:Homebrew cask 装的记 homebrew,其余(下载 DMG、各下载站)记 direct。
    public static func installMethod(caskroomExists: Bool) -> String { caskroomExists ? "homebrew" : "direct" }

    /// 发出去的「改过默认值的设置项」最多几个。
    public static let maxChangedSettings = 200

    /// 设置项的值写成可比较的字符串:集合、字典的 `String(describing:)` 顺序每次不同,按元素排好再拼;可选值拆开。
    public static func settingFingerprint(_ value: Any) -> String {
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional:
            return mirror.children.first.map { settingFingerprint($0.value) } ?? "nil"
        case .set:
            return "{" + mirror.children.map { settingFingerprint($0.value) }.sorted().joined(separator: ",") + "}"
        case .dictionary:
            let pairs = mirror.children.map { child -> String in
                let kv = Array(Mirror(reflecting: child.value).children)
                guard kv.count == 2 else { return settingFingerprint(child.value) }
                return settingFingerprint(kv[0].value) + ":" + settingFingerprint(kv[1].value)
            }
            return "[" + pairs.sorted().joined(separator: ",") + "]"
        default:
            return String(describing: value)
        }
    }

    /// 跟全默认的那一份比,值不一样的设置项名字(排好序,最多 `maxChangedSettings` 个)。只比两边都有的项,只发名字、不发值。
    public static func changedSettings(current: [String: String], defaults: [String: String]) -> [String] {
        Array(current.filter { name, value in defaults[name].map { $0 != value } ?? false }.keys.sorted()
            .prefix(maxChangedSettings))
    }

    /// 缺的权限在负载里的写法:`automation.apple_music`、`full-disk.qq_music`、`accessibility.kugou_music`。
    public static func permissionTag(_ kind: TelemetryPermissionKind, _ player: PlaybackPlayer) -> String {
        kind.rawValue + "." + player.rawValue
    }
}

/// 播放器要的三种权限。
public enum TelemetryPermissionKind: String, CaseIterable, Sendable {
    case automation, fullDisk = "full-disk", accessibility
}

/// 每日活动里记次数的几个动作。
public enum TelemetryAction: String, CaseIterable, Codable, Sendable {
    /// 歌词窗口开出来(含启动时按上次状态重开)。
    case lyricsWindow = "lyrics_window"
    /// 在歌词搜索里手动采用了一份候选。
    case lyricsPicked = "lyrics_picked"
    /// 手动调了某首歌或某个电台的时间偏移。
    case offsetAdjusted = "offset_adjusted"
    /// 分享歌词卡拷贝或保存成功。
    case shareCard = "share_card"
}

/// 一首歌最后拿到的歌词是哪一档(活动里的 `lyrics`),阶梯同 `LyricsKind`。见 14 章决策 171。
public enum TelemetryLyricsResult: String, CaseIterable, Codable, Sendable {
    case word, line, plain, instrumental, none

    public init(_ kind: LyricsKind) {
        switch kind {
        case .wordByWord: self = .word
        case .lineByLine: self = .line
        case .plainText: self = .plain
        case .instrumental: self = .instrumental
        case .none: self = .none
        }
    }
}

/// 一首歌的语言(活动里的 `languages`,ISO 639-1 代码)。按歌词正文判,没有歌词的歌不记。见 14 章决策 171。
public enum TelemetrySongLanguage: String, CaseIterable, Codable, Sendable {
    case zh, yue, ja, ko
    case ru, uk, bg, be, sr, mk, kk, el, th, ar
    case hi, bn, pa, gu, ta, te, kn, ml, si
    case en, es, pt, fr, de, it, nl, sv, pl, tr, vi, he
    case other

    /// 系统认出来的语言只收这几种,别的(和认不准的)记 `other`。别加印尼语:日语罗马字、拼音、韩语罗马字、
    /// 马来语、他加禄语都会被系统高把握地认成印尼语。
    public static let recognized: [NLLanguage: TelemetrySongLanguage] = [
        .english: .en, .spanish: .es, .portuguese: .pt, .french: .fr, .german: .de, .italian: .it, .dutch: .nl,
        .swedish: .sv, .polish: .pl, .turkish: .tr, .vietnamese: .vi, .hebrew: .he,
    ]
    /// 系统认语言的把握低于这个就记 `other`:系统不认识的语言会被硬套成相近的一种,把握多在 0.6 上下。
    static let minimumConfidence = 0.8

    /// `script` 是整首歌的文字种类(`Romanizer.songScript(of:)`,粤语已按引擎真值盖过)。这些文字种类本身就定了语言;
    /// 只有拉丁、希伯来这类 `.other` 再拿正文让系统认。阿拉伯字母只记文字种类(`ar`):系统把波斯语也认成阿拉伯语。
    public init(script: LyricScript, text: String) {
        switch script {
        case .chinese: self = .zh
        case .cantonese: self = .yue
        case .japanese: self = .ja
        case .korean: self = .ko
        case .russian: self = .ru
        case .ukrainian: self = .uk
        case .bulgarian: self = .bg
        case .belarusian: self = .be
        case .serbian: self = .sr
        case .macedonian: self = .mk
        case .kazakh: self = .kk
        case .greek: self = .el
        case .thai: self = .th
        case .arabic: self = .ar
        case .hindi: self = .hi
        case .bengali: self = .bn
        case .punjabi: self = .pa
        case .gujarati: self = .gu
        case .tamil: self = .ta
        case .telugu: self = .te
        case .kannada: self = .kn
        case .malayalam: self = .ml
        case .sinhala: self = .si
        case .unsupportedCyrillic: self = .other
        case .other: self = Self.recognize(text)
        }
    }

    static func recognize(_ text: String) -> TelemetrySongLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= minimumConfidence else { return .other }
        return recognized[language] ?? .other
    }
}

/// 这台机器上的 Lyrimuse 是新装的还是从旧版本升级上来的(心跳的 `origin`),统计页按它把「新增安装」拆成新下载和老用户。
/// 见 14 章决策 165。
public enum TelemetryInstallOrigin: String, Codable, Sendable {
    case new, existing

    /// 启动时判一次,必须在 `WhatsNewCenter.start()` 改写上次启动的版本和基准版本之前。
    /// - 本机还没有安装 ID:上次启动记过版本或走完过引导就是升级上来的,否则是新装的。
    /// - 已经有安装 ID(那时还不记这一项):按更新提示存着的基准版本倒推。基准是 `WhatsNew.legacyBaseline` = 第一次跑到
    ///   基准判断那一版时已经走完过引导;基准等于上次启动的版本 = 从那一版装起、之后没升级过。都不是(中间升级过)判不出,返回 nil。
    public static func infer(hasInstallID: Bool, lastLaunched: String?, hasCompletedOnboarding: Bool,
                             storedBaseline: String?) -> TelemetryInstallOrigin? {
        guard hasInstallID else { return lastLaunched != nil || hasCompletedOnboarding ? .existing : .new }
        guard let storedBaseline else { return nil }
        if storedBaseline == WhatsNew.legacyBaseline { return .existing }
        if storedBaseline == lastLaunched { return .new }
        return nil
    }
}

/// 版本与系统。
public struct TelemetryEnvironment: Codable, Equatable, Sendable {
    public var appVersion: String
    public var build: String
    public var osVersion: String
    public var arch: String
    /// 界面实际用的语言包(`UILanguage.packs` 之一)。
    public var uiLanguage: String
    /// 系统首选语言的第一项(只要语言和文字,不要地区)。
    public var systemLanguage: String

    public init(appVersion: String, build: String, osVersion: String, arch: String,
                uiLanguage: String, systemLanguage: String) {
        self.appVersion = appVersion
        self.build = build
        self.osVersion = osVersion
        self.arch = arch
        self.uiLanguage = uiLanguage
        self.systemLanguage = systemLanguage
    }

    enum CodingKeys: String, CodingKey {
        case appVersion = "app_version", build, osVersion = "os_version", arch
        case uiLanguage = "ui_language", systemLanguage = "system_language"
    }

    /// `zh-Hans-CN` → `zh-Hans`,`en-US` → `en`:地区不发。
    public static func languageOnly(_ tag: String) -> String {
        let parts = tag.split(separator: "-").map(String.init)
        guard let first = parts.first else { return "" }
        if parts.count > 1, parts[1].count == 4 { return first + "-" + parts[1] }
        return first
    }

    public static func osVersionString(_ v: OperatingSystemVersion) -> String {
        v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    public static var currentArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}

/// 此刻开着哪些功能。只有枚举值、计数和开关。
public struct TelemetryFeatures: Codable, Equatable, Sendable {
    /// 开着的展示面与输出:overlay / notch / menubar / touchbar / lyrics-window(此刻歌词窗口开着)/ web-lyrics / obs / discord /
    /// notifications。
    public var surfaces: [String]
    /// 设置里勾着的播放器(`PlaybackPlayer` 的 rawValue,含 auto)。
    public var playersSelected: [String]
    public var lyricsSourceMode: String
    public var lyricsSourcesEnabled: Int
    public var translation: Bool
    public var romanization: Bool
    public var machineTranslation: Bool
    /// 连上了的账号与服务:lastfm / listenbrainz / apple-music / relay / push。只说连没连,不带账号名。
    public var accounts: [String]
    /// 用户信任的第三方播放器与浏览器(bundle id,`Telemetry.bundleIDTag` 过滤、排序后取前 `maxTrustedPlayers` 个),不带名字。
    public var trustedPlayers: [String]
    public static let maxTrustedPlayers = 40
    /// 网页版配了浏览器的平台(`BrowserPositionProbe.supportedPlatforms` 的 id)。
    public var webPlatforms: [String]
    public var showInDock: Bool
    public var launchAtLogin: Bool
    public var betaUpdates: Bool
    /// homebrew / direct(`Telemetry.installMethod`)。
    public var installMethod: String?
    /// 改过默认值的设置项(`AppSettings` 的属性名,`Telemetry.changedSettings`),只有名字。
    public var settingsChanged: [String]
    /// 勾选的播放器里缺的权限(`Telemetry.permissionTag`),只算本机装了的。
    public var permissionsMissing: [String]

    public init(surfaces: [String], playersSelected: [String], lyricsSourceMode: String, lyricsSourcesEnabled: Int,
                translation: Bool, romanization: Bool, machineTranslation: Bool, accounts: [String],
                trustedPlayers: [String], webPlatforms: [String],
                showInDock: Bool, launchAtLogin: Bool, betaUpdates: Bool,
                installMethod: String? = nil,
                settingsChanged: [String] = [], permissionsMissing: [String] = []) {
        self.surfaces = surfaces.sorted()
        self.playersSelected = playersSelected.sorted()
        self.lyricsSourceMode = lyricsSourceMode
        self.lyricsSourcesEnabled = lyricsSourcesEnabled
        self.translation = translation
        self.romanization = romanization
        self.machineTranslation = machineTranslation
        self.accounts = accounts.sorted()
        self.trustedPlayers = Array(Set(trustedPlayers.compactMap(Telemetry.bundleIDTag)).sorted().prefix(Self.maxTrustedPlayers))
        self.webPlatforms = webPlatforms.sorted()
        self.showInDock = showInDock
        self.launchAtLogin = launchAtLogin
        self.betaUpdates = betaUpdates
        self.installMethod = installMethod
        self.settingsChanged = Array(settingsChanged.sorted().prefix(Telemetry.maxChangedSettings))
        self.permissionsMissing = permissionsMissing.sorted()
    }

    enum CodingKeys: String, CodingKey {
        case surfaces, playersSelected = "players_selected", lyricsSourceMode = "lyrics_source_mode"
        case lyricsSourcesEnabled = "lyrics_sources_enabled", translation, romanization
        case machineTranslation = "machine_translation", accounts, trustedPlayers = "trusted_players"
        case webPlatforms = "web_platforms", showInDock = "show_in_dock"
        case launchAtLogin = "launch_at_login", betaUpdates = "beta_updates"
        case installMethod = "install_method"
        case settingsChanged = "settings_changed", permissionsMissing = "permissions_missing"
    }
}

/// 某一天记下的活动。
public struct TelemetryActivityDay: Codable, Equatable, Sendable {
    public var day: String
    /// 这一天放过歌的播放器(`Telemetry.playerTag`:内置的 id、信任的 bundle id,其余 `other`)。
    public var playersPlayed: [String]
    /// 主线程卡住到报「unresponsive」的次数(`MainThreadWatchdog`)。
    public var hangs: Int
    /// 几个动作各做了几次(`TelemetryAction` 的 rawValue → 次数),没做过的不写。
    public var actions: [String: Int]
    /// 这一天放过的歌各拿到哪一档歌词(`TelemetryLyricsResult` 的 rawValue → 首数),同一首一天只算一次,各档之和就是放了几首。
    public var lyrics: [String: Int]
    /// 这一天放过的有歌词的歌各是什么语言(`TelemetrySongLanguage` 的 rawValue → 首数)。
    public var languages: [String: Int]

    public init(day: String, playersPlayed: [String] = [], hangs: Int = 0, actions: [String: Int] = [:],
                lyrics: [String: Int] = [:], languages: [String: Int] = [:]) {
        self.day = day
        self.playersPlayed = playersPlayed
        self.hangs = hangs
        self.actions = actions
        self.lyrics = lyrics
        self.languages = languages
    }

    /// 旧版本存下的活动没有 `actions`、`lyrics`、`languages`。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        playersPlayed = try c.decodeIfPresent([String].self, forKey: .playersPlayed) ?? []
        hangs = try c.decodeIfPresent(Int.self, forKey: .hangs) ?? 0
        actions = try c.decodeIfPresent([String: Int].self, forKey: .actions) ?? [:]
        lyrics = try c.decodeIfPresent([String: Int].self, forKey: .lyrics) ?? [:]
        languages = try c.decodeIfPresent([String: Int].self, forKey: .languages) ?? [:]
    }

    enum CodingKeys: String, CodingKey {
        case day, playersPlayed = "players_played", hangs, actions, lyrics, languages
    }
}

public struct TelemetryHeartbeat: Codable, Equatable, Sendable {
    public var v = Telemetry.schemaVersion
    public var installID: String
    public var day: String
    public var env: TelemetryEnvironment
    public var features: TelemetryFeatures
    /// 今天之前、还没发出去的那几天(最多 `TelemetryActivity.maxStoredDays` 天)。
    public var activity: [TelemetryActivityDay]
    /// 判不出时不发这个键。
    public var origin: TelemetryInstallOrigin?

    public init(installID: String, day: String, env: TelemetryEnvironment, features: TelemetryFeatures,
                activity: [TelemetryActivityDay], origin: TelemetryInstallOrigin? = nil) {
        self.installID = installID
        self.day = day
        self.env = env
        self.features = features
        self.activity = activity
        self.origin = origin
    }

    enum CodingKeys: String, CodingKey {
        case v, installID = "install_id", day, env, features, activity, origin
    }
}

public struct TelemetryCrash: Codable, Equatable, Sendable {
    public struct Frame: Codable, Equatable, Sendable {
        public var image: String?
        public var symbol: String?
        public var offset: Int?

        public init(image: String?, symbol: String?, offset: Int?) {
            self.image = image
            self.symbol = symbol
            self.offset = offset
        }
    }

    public var v = Telemetry.schemaVersion
    public var installID: String
    /// 报告文件名的 SHA-256 前 16 位:Worker 按它去重,文件名本身不发。
    public var reportID: String
    /// app / engine。
    public var process: String
    /// 报告自己记的版本(崩溃时跑的那一版,不一定是现在这一版)。
    public var appVersion: String?
    public var osVersion: String?
    public var occurredAt: String?
    public var exceptionType: String?
    public var exceptionSignal: String?
    public var terminationNamespace: String?
    public var terminationIndicator: String?
    public var terminationReasons: [String]
    public var frames: [Frame]
    /// 抛出未捕获异常时的调用栈(`CrashReportSummary.exceptionFrames`),同样截到 `Telemetry.maxCrashFrames`;没有就是空。
    public var exceptionFrames: [Frame]
    public var env: TelemetryEnvironment

    enum CodingKeys: String, CodingKey {
        case v, installID = "install_id", reportID = "report_id", process, appVersion = "app_version"
        case osVersion = "os_version", occurredAt = "occurred_at", exceptionType = "exception_type"
        case exceptionSignal = "exception_signal", terminationNamespace = "termination_namespace"
        case terminationIndicator = "termination_indicator", terminationReasons = "termination_reasons"
        case frames, exceptionFrames = "exception_frames", env
    }

    /// 由崩溃报告摘要组出要发的那份:路径换成 `<path>`,源码文件与行号不带,帧数截到 `Telemetry.maxCrashFrames`。
    public init(summary: CrashReportSummary, reportID: String, executableName: String, installID: String,
                env: TelemetryEnvironment) {
        func redact(_ text: String?, _ limit: Int = Telemetry.crashShortFieldLimit) -> String? {
            text.map { String(Telemetry.redactPaths($0).prefix(limit)) }
        }
        self.installID = installID
        self.reportID = reportID
        process = summary.processName?.lowercased() == executableName.lowercased() ? "app" : "engine"
        appVersion = summary.version
        osVersion = redact(summary.osVersion)
        occurredAt = Telemetry.crashDay(summary.timestamp)
        exceptionType = redact(summary.exceptionType)
        exceptionSignal = redact(summary.exceptionSignal)
        terminationNamespace = redact(summary.terminationNamespace)
        terminationIndicator = redact(summary.terminationIndicator, Telemetry.crashIndicatorLimit)
        terminationReasons = summary.terminationReasons.prefix(3).map {
            String(Telemetry.redactPaths($0).prefix(Telemetry.crashReasonLimit))
        }
        func payload(_ list: [CrashReportSummary.Frame]) -> [Frame] {
            list.prefix(Telemetry.maxCrashFrames).map {
                Frame(image: redact($0.imageName, Telemetry.crashImageLimit), symbol: redact($0.symbol, Telemetry.crashSymbolLimit),
                      offset: $0.imageOffset)
            }
        }
        frames = payload(summary.frames)
        exceptionFrames = payload(summary.exceptionFrames)
        self.env = env
    }
}
