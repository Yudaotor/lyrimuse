import Foundation

/// 反馈要打开的链接。issue 表单在仓库 `.github/ISSUE_TEMPLATE/`,链接里的查询参数名就是表单字段的 `id`,GitHub 把它们
/// 填进表单;两边一起改(selftest contracts 组「反馈链接」核对两边的名字)。表单只在默认分支 main 上生效。环境信息由 App
/// 侧 `FeedbackReporter` 收集,见 14 章决策 57、59。
public enum FeedbackLinks {
    /// 填进表单的环境信息。`player` 为空时链接里不带这一项。
    public struct Environment: Equatable, Sendable {
        public var appVersion: String
        public var macOSVersion: String
        public var player: String

        public init(appVersion: String, macOSVersion: String, player: String = "") {
            self.appVersion = appVersion
            self.macOSVersion = macOSVersion
            self.player = player
        }
    }

    /// 歌词类表单要的那首歌。空的项链接里不带。
    public struct LyricsReport: Equatable, Sendable {
        public var song: String
        public var artist: String
        public var album: String
        /// 现在用的歌词来源(显示名)。
        public var source: String
        /// 这一轮返回了候选的来源(显示名,已经用顿号或逗号连好)。
        public var answered: String

        public init(song: String, artist: String, album: String = "", source: String = "", answered: String = "") {
            self.song = song
            self.artist = artist
            self.album = album
            self.source = source
            self.answered = answered
        }
    }

    /// 歌词类表单的文件名,链接里用它直接打开这一类,不经选择页。
    public static let lyricsTemplate = "2-lyrics.yml"
    /// 歌词类 issue 的标题前缀,不跟界面语言走;表单文件里的默认标题是同一串。
    public static let lyricsTitlePrefix = "[Lyrics] "
    /// 没有 GitHub 账号时用的邮箱。
    public static let feedbackEmail = "yudaotor@qq.com"
    /// 「使用求助」:讨论区的问答分类。
    public static let helpURL = URL(string: LegalNoticeLinks.repo + "/discussions/categories/q-a")!

    /// 「功能清单」:落地页的 features/ 页,按界面语言(`L10n.current` 的取值)开对应的那一份,认不出的值当英文。
    /// 页面由 `scripts/gen-feature-list.py` 的数据生成,跟 GitHub 上的 docs/feature-list*.md 是同一份,见 14 章决策 68。
    public static func featureListURL(language: String) -> URL {
        let dir: String
        switch language.lowercased() {
        case "zh-hans": dir = "zh/"
        case "zh-hant": dir = "zh-Hant/"
        default: dir = ""
        }
        return URL(string: "https://yudaotor.github.io/lyrimuse/" + dir + "features/")!
    }

    /// issue 模板选择页,版本、系统、播放器带在参数里,用户选哪一类都已经填好。
    public static func newIssueURL(_ environment: Environment) -> URL {
        url(LegalNoticeLinks.repo + "/issues/new/choose", [
            ("version", environment.appVersion), ("macos", environment.macOSVersion), ("player", environment.player),
        ])
    }

    /// 直接打开歌词类表单,标题和歌曲信息已经填好。标题是「[Lyrics] Title: 歌名 · Artist: 歌手 · Album: 专辑」,空的那一段不带。
    public static func lyricsIssueURL(_ report: LyricsReport, environment: Environment) -> URL {
        let parts = [("Title", report.song), ("Artist", report.artist), ("Album", report.album)]
            .filter { !$0.1.isEmpty }
            .map { "\($0.0): \($0.1)" }
        let title = lyricsTitlePrefix + parts.joined(separator: " · ")
        return url(LegalNoticeLinks.repo + "/issues/new", [
            ("template", lyricsTemplate), ("title", title),
            ("song", report.song), ("artist", report.artist), ("album", report.album), ("player", environment.player),
            ("source", report.source), ("answered", report.answered), ("version", environment.appVersion),
        ])
    }

    /// 播放器请求表单的文件名。
    public static let playerRequestTemplate = "3-player.yml"

    /// 直接打开播放器请求表单,带上版本(表单里只有这一项要 App 填)。
    public static func playerRequestURL(appVersion: String) -> URL {
        url(LegalNoticeLinks.repo + "/issues/new", [("template", playerRequestTemplate), ("version", appVersion)])
    }

    /// 写给 `feedbackEmail` 的邮件,正文末尾带一行版本、系统和播放器。
    public static func emailURL(subject: String, environment: Environment) -> URL {
        var footer = "Lyrimuse \(environment.appVersion) · macOS \(environment.macOSVersion)"
        if !environment.player.isEmpty { footer += " · \(environment.player)" }
        return url("mailto:" + feedbackEmail, [("subject", subject), ("body", "\n\n—\n" + footer)])
    }

    /// 芯片架构的产品名(不本地化:Apple 自己的界面里这几个词也不翻)。universal 包在两种机器上跑的是各自原生那一半;
    /// 在「显示简介」里勾了「使用 Rosetta 打开」时,Apple Silicon 上跑的是 Intel 那一半,这时写成「Apple Silicon, Rosetta」。
    public static var architectureName: String {
        #if arch(arm64)
        let nativeArm64 = true
        #else
        let nativeArm64 = false
        #endif
        return architectureName(nativeArm64: nativeArm64, translated: !nativeArm64 && runsUnderRosetta)
    }

    /// `architectureName` 的判断本体:编译出的是不是 arm64 那一半,这个进程是不是经 Rosetta 转译在跑。
    public static func architectureName(nativeArm64: Bool, translated: Bool) -> String {
        if nativeArm64 { return "Apple Silicon" }
        return translated ? "Apple Silicon, Rosetta" : "Intel"
    }

    /// 读 `sysctl.proc_translated`;Intel 机器上没有这个键,读不到按没有转译。
    private static var runsUnderRosetta: Bool {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
    }

    /// 「27.0.1」这样的系统版本号。
    public static func macOSVersionString(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// 值为空的参数不带。URLComponents 不编码「+」,查询串里的「+」会被当成空格,这里编成 %2B。
    private static func url(_ base: String, _ params: [(String, String)]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = params.filter { !$0.1.isEmpty }.map { URLQueryItem(name: $0.0, value: $0.1) }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}
