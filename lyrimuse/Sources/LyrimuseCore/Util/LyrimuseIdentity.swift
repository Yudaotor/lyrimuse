import Foundation

/// 这个 App 的一整套名字:显示名、bundle id(= App 自己那个 LaunchAgent 的 label)、配置目录名、collector 的 launchd
/// label、两份日志文件名、默认安装位置、URL scheme。所有随之变化的路径都从这里派生,别处不许再写字面量(selftest
/// contracts 组「身份与路径收口」守着;Go 侧的对应口径是 paths.go,经环境变量拿到同一套值)。
///
/// 2026-09-05 加(借鉴清单 #33 第一步:纯重构,行为一个字节不变)。同日第二步曾按 Info.plist 的 `LyrimuseVariant` 派生出
/// 一套并排安装的「Lyrimuse Dev」;**2026-09-06 用户拍板整体回退**——没有收益,反而带来问题:在 Dev 里恢复一份配置备份就把
/// 账号带了进去,两个 collector 各 scrobble 一次;同事会话仍在装正式版;用户分不清手里是哪个二进制。现在只剩这一套固定
/// 名字,`Resolved` 保留是为了让 selftest 能整体断言、别处按字段取。整个来回见 15 章决策 12。
public enum LyrimuseIdentity {
    public struct Resolved: Equatable {
        /// 给人看的名字,也是 .app 的文件名主体。
        public let displayName: String
        /// CFBundleIdentifier,同时是 App 自己那个 LaunchAgent 的 label(TCC 自动化权限、UserDefaults 域都按它认)。
        public let bundleIdentifier: String
        /// `~/.config/<这个>`。
        public let configDirName: String
        public let collectorLaunchdLabel: String
        /// `~/Library/Logs/<这个>`:collector 常驻进程的日志。
        public let logFileName: String
        /// `~/Library/Logs/<这个>`:App 进程由 launchd 拉起时的 stdout / stderr。
        public let appLogFileName: String
        /// build.sh 默认装到哪(LoginItemManager 在拿不到运行中 bundle 路径时的兜底)。
        public let defaultAppBundlePath: String
        /// CFBundleURLSchemes 里那一个(Last.fm 授权回调 `<scheme>://lastfm-auth-callback` 用)。
        public let urlScheme: String

        public var appLaunchdLabel: String { bundleIdentifier }
    }

    /// 唯一的一套名字。
    public static let current = Resolved(
        displayName: "Lyrimuse",
        bundleIdentifier: "me.yudaotor.lyrimuse",
        configDirName: "lyrimuse",
        collectorLaunchdLabel: "com.lyrimuse.collector",
        logFileName: "lyrimuse.log",
        appLogFileName: "lyrimuse-app.log",
        defaultAppBundlePath: "/Applications/Lyrimuse.app",
        urlScheme: "lyrimuse"
    )

    public static var displayName: String { current.displayName }
    public static var bundleIdentifier: String { current.bundleIdentifier }
    public static var configDirName: String { current.configDirName }
    public static var collectorLaunchdLabel: String { current.collectorLaunchdLabel }
    public static var appLaunchdLabel: String { current.appLaunchdLabel }
    public static var urlScheme: String { current.urlScheme }
}

/// 所有落盘位置的唯一口径。App 与 Core 里任何要碰 `~/.config/lyrimuse` / `~/Library/Logs` / `~/Library/LaunchAgents`
/// 的地方都从这里取,不许自己拼 `homeDirectoryForCurrentUser.appendingPathComponent(".config/lyrimuse/…")`。
public enum LyrimusePaths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// `~/.config/lyrimuse`。config.json、features、enrich 缓存、歌词、封面、收听日志、
    /// 状态文件、单实例锁全在它下面;collector 侧用同一个目录(见 `collectorEnvironment`)。
    public static var configDir: URL { home.appendingPathComponent(".config/\(LyrimuseIdentity.configDirName)") }

    /// 配置目录下的一个文件或子目录。
    public static func configFile(_ name: String) -> URL { configDir.appendingPathComponent(name) }

    public static var launchAgentsDir: URL { home.appendingPathComponent("Library/LaunchAgents") }
    public static func launchAgentPlist(label: String) -> URL { launchAgentsDir.appendingPathComponent("\(label).plist") }

    /// build.sh 默认安装位置的 .app。
    public static var defaultAppBundleURL: URL { URL(fileURLWithPath: LyrimuseIdentity.current.defaultAppBundlePath) }

    /// 传给 collector 的环境变量 —— 常驻 job 的 plist(`EnvironmentVariables`)和 App spawn 的每一个一次性子命令
    /// (search-lyrics / healthcheck / backfill…)都要带上,否则子命令会落回 collector 自己的默认目录、跟本 App 不是同一份数据。
    /// 正式版传的就是 collector 的默认值,所以永远只有一条代码路径,不存在「正式版不传」这种分叉。
    /// Go 侧的读取方是 `paths.go` 的 `configDir()` / `logFilePath()` / `appBundleID()`。
    public static var collectorEnvironment: [String: String] {
        [
            "LYRIMUSE_CONFIG_DIR": configDir.path,
            "LYRIMUSE_LOG_FILE": LogFiles.collector.path,
            // companion launch(播放器起来了顺手拉起 App)要 `open -b` 的 bundle id 也从这里下发,Go 侧不写死。
            "LYRIMUSE_APP_BUNDLE_ID": LyrimuseIdentity.bundleIdentifier,
        ]
    }

    /// 给 `Process.environment` 用:在继承的环境上叠加上面两项(子进程默认继承父进程环境,一旦显式设了
    /// environment 就只有你给的那些,所以必须先拿父进程的再叠)。
    public static func collectorProcessEnvironment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        for (key, value) in collectorEnvironment { env[key] = value }
        return env
    }
}

/// 两侧日志文件的落点。唯一口径:LoginItemManager / CollectorServiceManager 写 plist、DiagnosticsExporter 读文件、
/// collector 侧经环境变量 LYRIMUSE_LOG_FILE 拿到的都是这一份;uninstall.sh 的清理列表(那边是 shell)手工同步。
public enum LogFiles {
    private static var logsDir: URL { LyrimusePaths.home.appendingPathComponent("Library/Logs") }

    /// collector 常驻进程的日志(launchd 的 StandardErrorPath,也是 collector 自己打开并按大小轮转的那份)。
    public static var collector: URL { logsDir.appendingPathComponent(LyrimuseIdentity.current.logFileName) }

    /// App 进程由 launchd 拉起时的 stdout / stderr(2026-09-05 起单独一份;此前跟 collector 共用
    /// `lyrimuse.log`,两个进程两种格式两种时区混在一个文件里,launchctl 子进程漏出来的报错也
    /// 分不清是谁的)。正常情况下几乎是空的 —— App 的日志走 os.Logger;能落进来的只有 Swift
    /// 运行时的 fatal 信息、被子进程漏出的 stderr 这类"本不该有"的东西,正因为如此它排查崩溃时最有用。
    public static var appStderr: URL { logsDir.appendingPathComponent(LyrimuseIdentity.current.appLogFileName) }
}
