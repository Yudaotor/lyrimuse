import Foundation

/// `lyrimuse://…` 链接的路由表:整条 URL 解析成一个值,App 只按这个值分派(`DeepLinkRouter`)。认不出的返回 nil,
/// App 闪一句「无法识别的链接」,不再落进 Last.fm 授权回调。见 docs/proposals/deep-links.md 与 14 章「深链」。
///
///     settings/<路径>[/<分段>]      设置窗口翻到那一页(路径表见 `SettingsDeepLink`,分段见 `SettingsDeepLink.section(in:)`)
///     settings/software-update?check=1    软件更新页并顺手检查一次
///     lyrics-manager                歌词管理
///     lyrics-manager/song-versions[?key=<写法键>][&evidence=1][&compare=<写法键>]   歌词管理 + 那一条的「同曲条目」面板(没带 key 是
///                                   详情页正显示的那条;evidence=1 打开就展开概况里的「匹配依据」;compare 打开就选中这一条、显示它跟
///                                   当前条目的对照)
///     lyrics-window                 歌词窗口
///     lyrics-window/search          歌词窗口 + 搜索候选歌词面板
///     lyrics-search                 「搜索歌词…」小窗(当前这首)
///     menubar-panel[?quick=<格子>]   开 / 关菜单栏左键面板,带 quick 时翻到那一格的快捷设置
///     menubar-menu                  弹出菜单栏右键菜单(同右键点状态栏图标)
///     onboarding                    欢迎引导
///     action/<名字>[?on=1|0][&step=<秒>]   执行一个动作(= 全局快捷键那一套,见 `LyrimuseAction`)
///     action/copy-lyric[?translation=1]    把当前这句歌词(可连译文)放进剪贴板
///     action/open-player            把 Lyrimuse 正在读的播放器带到前台
///     action/surfaces?overlay=1&notch=0&menubar=1   一次设好几个展示面(只带要改的那几个)
///     action/lyrics-offset?ms=-300  这首歌的歌词时间轴直接设成某个值(±10 秒以内)
///     action/play-mode?mode=shuffle 播放模式设成 list / shuffle / repeat-all / repeat-one(同歌词窗口那两颗键;播放器够不到的档位落到 list)
///     x-callback-url/now-playing?x-success=…   把正在播放的信息作为参数打开 x-success(只回给本机 App)
///     lastfm-auth-callback          Last.fm 浏览器授权回跳(内部用)
///     debug/<命令>                  本机验证用(见 `DebugCommand`),只在本机偏好 `debug:deepLinks` 打开时才执行
///
/// 开窗类的链接(settings、lyrics-manager、lyrics-window、lyrics-search、onboarding、action/open-*)可以再带
/// `background=1`:窗口摆出来,但不激活 App、不抢键盘焦点(`wantsBackground(_:)`)。
/// host 和路径大小写不敏感;scheme 由调用方给(正式 `lyrimuse`,Dev `lyrimuse-dev`,`LyrimuseIdentity.urlScheme`)。
/// 改名、删除任何一条都要先看对外说过没有(CHANGELOG、README、支持回复),说过的保持能用。
public enum LyrimuseDeepLink: Equatable, Sendable {
    case settings(path: String, checkForUpdates: Bool)
    case lyricsManager
    /// `key`:写法键(`EnrichCacheKeys.normalizedKey` 那种「歌手|歌名|专辑」);nil = 详情页正显示的那一条。`showEvidence`:
    /// 面板打开就展开概况里的「匹配依据」。`compare`:面板打开就选中这一条写法,显示它跟当前条目的对照。
    case lyricsManagerSongVersions(key: String?, showEvidence: Bool, compare: String? = nil)
    case lyricsWindow
    case lyricsWindowSearch
    case lyricsSearch
    /// `quick` 是原样的取值(App 侧 `PanelQuickTarget(deepLinkValue:)` 认),认不出时 App 当没带。
    case menuBarPanel(quick: String?)
    case menuBarMenu
    case onboarding
    /// `on`:开关的目标状态(只有 `acceptsTargetState` 的动作收,别的动作带了也当没带);`stepSeconds`:歌词提前 /
    /// 延后的步长(只有 `acceptsStep` 的收,超出 0…`maxStepSeconds` 当没带)。
    case action(LyrimuseAction, on: Bool?, stepSeconds: Double?)
    case copyLyric(includeTranslation: Bool)
    case openPlayer
    /// nil = 这一个不动。三个都是 nil 的链接认不出(返回 nil)。
    case setSurfaces(overlay: Bool?, notch: Bool?, menuBar: Bool?)
    /// 这首歌自己的那一份偏移(毫秒),在 ±`maxLyricsOffsetMs` 以内。
    case setLyricsOffset(ms: Int)
    case setPlayMode(MusicPlaybackController.MusicPlaybackMode)
    /// x-callback-url:`success` 只收本机 App 的地址(`isCallbackTarget`),网页拿不到正在听什么。
    case nowPlayingCallback(success: URL?)
    case debug(DebugCommand)
    case lastfmAuthCallback

    /// 本机验证用的命令(`lyrimuse://debug/…`)。只给开发机上的验证脚本用,发布出去的 App 默认不认(见 `DebugDeepLinks`)。
    public enum DebugCommand: Equatable, Sendable {
        /// 把一扇窗画成 PNG(App 自己画,不需要屏幕录制权限,窗口在别的桌面空间也画得出)。
        case snapshot(window: String)
        /// 把界面状态写成 JSON(开着哪些窗口、面板翻在哪一格、当前播放与第几句、各开关)。
        case state
        /// 记下此刻的窗口与开关,`restore` 时按它恢复。
        case checkpoint
        /// 回到最近一次 `checkpoint`:关掉之后开出来的窗口,开关设回原值。
        case restore
        /// 模拟播放(`PlaybackSimulation`):不读播放器,按这首驱动界面。时长、位置以秒计,`playing=0` 停在 `position`。
        case simulate(title: String, artist: String, album: String, duration: Double?, position: Double, playing: Bool)
        /// 结束模拟,交还真实播放器(`debug/simulate?off=1`)。
        case simulateOff
        /// 翻转当前曲目的「喜欢」,跟点歌词窗口那颗心走同一条路(`debug/favorite`)。
        case toggleFavorite
        /// 把播放器音量设成 0…100,跟拖歌词窗口的音量条走同一条路(`debug/volume?percent=`)。
        case volume(percent: Int)
    }

    /// `action/` 下不对应快捷键的那几个名字(跟 `LyrimuseAction.linkName` 不能重名,selftest 核对)。
    public static let extraActionNames = ["copy-lyric", "open-player", "surfaces", "lyrics-offset", "play-mode"]
    /// `action/play-mode?mode=` 的取值。
    public static let playModeNames: [String: MusicPlaybackController.MusicPlaybackMode] = [
        "list": .list, "shuffle": .shuffle, "repeat-all": .repeatAll, "repeat-one": .repeatOne,
    ]
    /// 歌词时间轴绝对值的上限(毫秒)。再大就不是校准了,链接里写错一位数会把整首歌词错开很远。
    public static let maxLyricsOffsetMs = 10_000

    public init?(url: URL, scheme: String) {
        guard url.scheme?.lowercased() == scheme.lowercased(), let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()
        let trimmedPath = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name.lowercased() == name }?.value }
        switch (host, trimmedPath) {
        case ("settings", _):
            let check = value("check").flatMap(Self.parseBool) ?? false
            self = .settings(path: trimmedPath, checkForUpdates: check)
        case ("lyrics-manager", ""), ("lyrics-manager", "/"):
            self = .lyricsManager
        case ("lyrics-manager", "/song-versions"):
            self = .lyricsManagerSongVersions(key: value("key").flatMap { $0.isEmpty ? nil : $0 },
                                              showEvidence: value("evidence").flatMap(Self.parseBool) ?? false,
                                              compare: value("compare").flatMap { $0.isEmpty ? nil : $0 })
        case ("lyrics-window", ""), ("lyrics-window", "/"):
            self = .lyricsWindow
        case ("lyrics-window", "/search"):
            self = .lyricsWindowSearch
        case ("lyrics-search", ""), ("lyrics-search", "/"):
            self = .lyricsSearch
        case ("menubar-panel", ""), ("menubar-panel", "/"):
            self = .menuBarPanel(quick: value("quick")?.lowercased())
        case ("menubar-menu", ""), ("menubar-menu", "/"):
            self = .menuBarMenu
        case ("onboarding", ""), ("onboarding", "/"):
            self = .onboarding
        case ("action", "/copy-lyric"):
            self = .copyLyric(includeTranslation: value("translation").flatMap(Self.parseBool) ?? false)
        case ("action", "/open-player"):
            self = .openPlayer
        case ("action", "/surfaces"):
            let overlay = value("overlay").flatMap(Self.parseBool)
            let notch = value("notch").flatMap(Self.parseBool)
            let menuBar = value("menubar").flatMap(Self.parseBool)
            guard overlay != nil || notch != nil || menuBar != nil else { return nil }
            self = .setSurfaces(overlay: overlay, notch: notch, menuBar: menuBar)
        case ("action", "/lyrics-offset"):
            guard let ms = value("ms").flatMap(Int.init), abs(ms) <= Self.maxLyricsOffsetMs else { return nil }
            self = .setLyricsOffset(ms: ms)
        case ("action", "/play-mode"):
            guard let mode = value("mode").flatMap({ Self.playModeNames[$0.lowercased()] }) else { return nil }
            self = .setPlayMode(mode)
        case ("x-callback-url", "/now-playing"):
            self = .nowPlayingCallback(success: value("x-success").flatMap(URL.init(string:)).flatMap {
                Self.isCallbackTarget($0) ? $0 : nil
            })
        case ("action", _):
            let name = trimmedPath.hasPrefix("/") ? String(trimmedPath.dropFirst()) : trimmedPath
            guard !name.contains("/"), let action = LyrimuseAction(linkName: name) else { return nil }
            let on = action.acceptsTargetState ? value("on").flatMap(Self.parseBool) : nil
            let step = action.acceptsStep
                ? value("step").flatMap(Double.init).flatMap { $0 > 0 && $0 <= LyrimuseAction.maxStepSeconds ? $0 : nil }
                : nil
            self = .action(action, on: on, stepSeconds: step)
        case ("debug", "/snapshot"):
            guard let window = value("window"), !window.isEmpty else { return nil }
            self = .debug(.snapshot(window: window.lowercased()))
        case ("debug", "/state"):
            self = .debug(.state)
        case ("debug", "/checkpoint"):
            self = .debug(.checkpoint)
        case ("debug", "/restore"):
            self = .debug(.restore)
        case ("debug", "/simulate"):
            func seconds(_ name: String) -> Double? {
                value(name).flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            }
            if value("off").flatMap(Self.parseBool) == true {
                self = .debug(.simulateOff)
            } else {
                guard let title = value("title"), !title.isEmpty else { return nil }
                self = .debug(.simulate(
                    title: title, artist: value("artist") ?? "", album: value("album") ?? "",
                    duration: seconds("duration").flatMap { $0 > 0 ? $0 : nil }, position: seconds("position") ?? 0,
                    playing: value("playing").flatMap(Self.parseBool) ?? true))
            }
        case ("debug", "/favorite"):
            self = .debug(.toggleFavorite)
        case ("debug", "/volume"):
            guard let percent = value("percent").flatMap(Int.init), (0...100).contains(percent) else { return nil }
            self = .debug(.volume(percent: percent))
        case ("lastfm-auth-callback", _):
            self = .lastfmAuthCallback
        default:
            return nil
        }
    }

    /// 反向生成链接(「复制链接」、文档清单用),跟 `init(url:scheme:)` 互逆,selftest 逐条往返核对。
    public func url(scheme: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        switch self {
        case let .settings(path, check):
            components.host = "settings"
            components.path = path
            if check { components.queryItems = [URLQueryItem(name: "check", value: "1")] }
        case .lyricsManager:
            components.host = "lyrics-manager"
        case let .lyricsManagerSongVersions(key, showEvidence, compare):
            components.host = "lyrics-manager"
            components.path = "/song-versions"
            var items: [URLQueryItem] = []
            if let key { items.append(URLQueryItem(name: "key", value: key)) }
            if showEvidence { items.append(URLQueryItem(name: "evidence", value: "1")) }
            if let compare { items.append(URLQueryItem(name: "compare", value: compare)) }
            if !items.isEmpty { components.queryItems = items }
        case .lyricsWindow:
            components.host = "lyrics-window"
        case .lyricsWindowSearch:
            components.host = "lyrics-window"
            components.path = "/search"
        case .lyricsSearch:
            components.host = "lyrics-search"
        case let .menuBarPanel(quick):
            components.host = "menubar-panel"
            if let quick { components.queryItems = [URLQueryItem(name: "quick", value: quick)] }
        case .menuBarMenu:
            components.host = "menubar-menu"
        case .onboarding:
            components.host = "onboarding"
        case let .action(action, on, step):
            components.host = "action"
            components.path = "/" + action.linkName
            var items: [URLQueryItem] = []
            if let on { items.append(URLQueryItem(name: "on", value: on ? "1" : "0")) }
            if let step { items.append(URLQueryItem(name: "step", value: String(step))) }
            if !items.isEmpty { components.queryItems = items }
        case let .copyLyric(includeTranslation):
            components.host = "action"
            components.path = "/copy-lyric"
            if includeTranslation { components.queryItems = [URLQueryItem(name: "translation", value: "1")] }
        case .openPlayer:
            components.host = "action"
            components.path = "/open-player"
        case let .setSurfaces(overlay, notch, menuBar):
            components.host = "action"
            components.path = "/surfaces"
            components.queryItems = [("overlay", overlay), ("notch", notch), ("menubar", menuBar)].compactMap { name, on in
                on.map { URLQueryItem(name: name, value: $0 ? "1" : "0") }
            }
        case let .setLyricsOffset(ms):
            components.host = "action"
            components.path = "/lyrics-offset"
            components.queryItems = [URLQueryItem(name: "ms", value: String(ms))]
        case let .setPlayMode(mode):
            components.host = "action"
            components.path = "/play-mode"
            components.queryItems = [URLQueryItem(name: "mode", value: Self.playModeNames.first { $0.value == mode }?.key)]
        case let .nowPlayingCallback(success):
            components.host = "x-callback-url"
            components.path = "/now-playing"
            if let success { components.queryItems = [URLQueryItem(name: "x-success", value: success.absoluteString)] }
        case let .debug(command):
            components.host = "debug"
            switch command {
            case let .snapshot(window):
                components.path = "/snapshot"
                components.queryItems = [URLQueryItem(name: "window", value: window)]
            case .state: components.path = "/state"
            case .checkpoint: components.path = "/checkpoint"
            case .restore: components.path = "/restore"
            case let .simulate(title, artist, album, duration, position, playing):
                components.path = "/simulate"
                components.queryItems = [
                    URLQueryItem(name: "title", value: title), URLQueryItem(name: "artist", value: artist),
                    URLQueryItem(name: "album", value: album),
                ] + (duration.map { [URLQueryItem(name: "duration", value: String($0))] } ?? []) + [
                    URLQueryItem(name: "position", value: String(position)),
                    URLQueryItem(name: "playing", value: playing ? "1" : "0"),
                ]
            case .simulateOff:
                components.path = "/simulate"
                components.queryItems = [URLQueryItem(name: "off", value: "1")]
            case .toggleFavorite: components.path = "/favorite"
            case let .volume(percent):
                components.path = "/volume"
                components.queryItems = [URLQueryItem(name: "percent", value: String(percent))]
            }
        case .lastfmAuthCallback:
            components.host = "lastfm-auth-callback"
        }
        return components.url
    }

    /// 链接带了 `background=1`(认法同 `on=`):开窗时不激活 App,窗口摆到最前但不抢键盘焦点。只对开窗类有意义,
    /// 别的链接带了也不影响什么。
    public static func wantsBackground(_ url: URL) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.first { $0.name.lowercased() == "background" }?.value.flatMap(parseBool) ?? false
    }

    /// x-callback 的回传地址只收本机 App 的 scheme:网页(http / https)、本地文件和脚本类 scheme 一律不回传 ——
    /// 任何网页都能拉起 `lyrimuse://`,不挡的话网页就能读到用户正在听什么。
    public static func isCallbackTarget(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
        return !["http", "https", "file", "ftp", "javascript", "data", "about", "blob"].contains(scheme)
    }

    /// 回传时附在 `x-success` 后面的参数(歌名 / 歌手 / 专辑 / 当前这句 / 播放器 / 在不在放)。保留 `x-success` 自带的参数。
    public static func callbackURL(_ base: URL, title: String, artist: String, album: String, lyric: String,
                                   player: String, playing: Bool) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "title", value: title), URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "album", value: album), URLQueryItem(name: "lyric", value: lyric),
            URLQueryItem(name: "player", value: player), URLQueryItem(name: "playing", value: playing ? "1" : "0"),
        ]
        return components.url
    }

    /// `on=` 认 1 / 0、true / false、on / off(大小写不敏感),别的当没带。
    static func parseBool(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "1", "true", "on", "yes": return true
        case "0", "false", "off", "no": return false
        default: return nil
        }
    }
}

extension SettingsDeepLink {
    /// `settings/<页>/<分段>` 里的分段:写进哪个 UserDefaults 键、写什么值(设置页各分段选择器读的就是这几个键)。
    /// 分段名在链接里用小写加连字符(`menu-bar`),存的值是 App 里各 `Section` 枚举的 rawValue(`menuBar`)。
    /// 认不出的分段返回 nil,App 只翻到那一页、停在上次的分段。表里的取值 selftest 对着 App 的枚举逐个核对。
    public struct Section: Equatable, Sendable {
        public let storageKey: String
        public let value: String

        public init(storageKey: String, value: String) {
            self.storageKey = storageKey
            self.value = value
        }
    }

    /// 每一页的分段:链接里的名字 → 存的值。
    public static let sectionTable: [String: (key: String, values: [String: String])] = [
        "lyrics": (SettingsSearchCatalog.lyricsSectionKey,
                   ["fetch": "fetch", "translation": "translation", "display": "display", "manage": "manage"]),
        "player": (SettingsSearchCatalog.playerSectionKey,
                   ["players": "players", "linkage": "linkage", "permissions": "permissions"]),
        "appearance": (LyricsSurface.appearanceSectionStorageKey,
                       ["overlay": "overlay", "notch": "notch", "menu-bar": "menuBar", "touch-bar": "touchBar",
                        "lyrics-window": "lyricsWindow", "web-lyrics": "webLyrics"]),
        "account/lastfm": (SettingsSearchCatalog.lastfmSectionKey,
                           ["stats": "stats", "chart": "chart", "on-this-day": "onThisDay", "settings": "settings"]),
        "account/discord": (SettingsSearchCatalog.discordSectionKey,
                            ["display": "display", "buttons": "buttons", "privacy": "privacy"]),
    ]

    /// 路径去掉最后一段分段之后剩下的那一页(`/lyrics/manage` → `/lyrics`);没有分段时原样。给 `init(path:)` 用。
    public static func pagePath(of path: String) -> String {
        guard section(in: path) != nil else { return path }
        var parts = path.lowercased().split(separator: "/").map(String.init)
        parts.removeLast()
        return "/" + parts.joined(separator: "/")
    }

    /// 路径里带的分段;没带、或者这一页没有这个分段时是 nil。
    public static func section(in path: String) -> Section? {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        guard parts.count >= 2, let name = parts.last else { return nil }
        let page = parts.dropLast().joined(separator: "/")
        guard let entry = sectionTable[page], let value = entry.values[name] else { return nil }
        return Section(storageKey: entry.key, value: value)
    }
}
