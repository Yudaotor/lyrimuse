import Foundation

/// 浏览器里 YouTube Music 网页版的循环键、点赞、音量。都读写它自己页面上的东西,跟界面语言无关:
/// - 循环:播放条 `ytmusic-player-bar` 的 `repeat-mode` 属性(NONE / ALL / ONE);写入用脚本点它那颗循环键
///   (`yt-icon-button.repeat`),点一下立即翻到下一档(关 → 全部 → 单曲 → 关)。网页版的「随机播放」是把队列打乱一次的
///   动作、没有状态可读,随机键不显示。
/// - 点赞:播放条里 `ytmusic-like-button-renderer` 的 `like-status`(LIKE / DISLIKE / INDIFFERENT);写入点它的「赞」键。
///   踩过(DISLIKE)算没赞,点一下变成赞。
/// - 音量:它自己的音量条 `#volume-slider`(0~100,按听感换算,跟它界面上显示的一致);写入改值再发 change 事件,
///   播放器音量和它记住的音量一起变。直接调播放器的 `setVolume` 只改实际音量、音量条和记住的值不变,换歌会被改回去。
///
/// 注入走 `BrowserTabProbeScript`(跟广告探针同一份模板、同一个 JavaScript 授权);只在这个浏览器配对过 YouTube Music
/// 时用。开着几个 YouTube Music 标签页时认在放的那一页:写入先只动在放的那页,一页都没在放(全暂停着)再动第一页。
/// 见 07 章决策 136、138。
public enum YouTubeMusicWebControls {
    public static let platformID = "youtubeMusic"
    public static let modeOptions: MusicPlaybackController.PlaybackModeOptions = [.repeatAll, .repeatOne]
    static let eventTimeoutSeconds = 4
    static let processTimeout: TimeInterval = 6

    /// 往哪个浏览器注入:浏览器本体的 bundle id(Safari 报的 `com.apple.WebKit.GPU` 已换成 `com.apple.Safari`)和脚本方言。
    public struct Target: Equatable, Sendable {
        public let bundleID: String
        public let family: BrowserAutomationPermission.Family
    }

    /// 一次读回的三样;哪样读不懂就是 nil。
    public struct State: Equatable, Sendable {
        public let mode: MusicPlaybackController.MusicPlaybackMode?
        public let liked: Bool?
        public let volume: Int?

        public init(mode: MusicPlaybackController.MusicPlaybackMode?, liked: Bool?, volume: Int?) {
            self.mode = mode
            self.liked = liked
            self.volume = volume
        }
    }

    /// `repeat-mode` 的值 → 档位。
    public static func mode(fromAttribute value: String) -> MusicPlaybackController.MusicPlaybackMode? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "NONE": return .list
        case "ALL": return .repeatAll
        case "ONE": return .repeatOne
        default: return nil
        }
    }

    static func attribute(for mode: MusicPlaybackController.MusicPlaybackMode) -> String? {
        switch mode {
        case .list: return "NONE"
        case .repeatAll: return "ALL"
        case .repeatOne: return "ONE"
        case .shuffle: return nil
        }
    }

    /// `like-status` → 赞了没有(踩过算没赞)。
    public static func liked(fromStatus value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "LIKE": return true
        case "INDIFFERENT", "DISLIKE": return false
        default: return nil
        }
    }

    /// 读三样,回 `STATE:<repeat-mode>|<like-status>|<音量条>`;暂停的标签页带 `PAUSED:` 前缀,模板据此先找在放的那一页。
    /// 不许出现双引号(见 `BrowserTabProbeScript`)。
    public static let readJS = """
    (function(){\
    var bar = document.querySelector('ytmusic-player-bar');\
    if (!bar) return 'NOTFOUND';\
    var lk = bar.querySelector('ytmusic-like-button-renderer');\
    var s = document.querySelector('#volume-slider');\
    var out = 'STATE:' + (bar.getAttribute('repeat-mode') || '') + '|' + (lk ? (lk.getAttribute('like-status') || '') : '') + '|' + (s ? String(s.value) : '');\
    var v = document.querySelector('video');\
    return (v && v.paused) ? 'PAUSED:' + out : out;\
    })()
    """

    /// 写入脚本的公共头:找播放条;`force` 为 false 时暂停的标签页不动、回 `PAUSED:SKIP`,让模板接着找在放的那页。
    static func setPrologue(force: Bool) -> String {
        """
        var bar = document.querySelector('ytmusic-player-bar');\
        if (!bar) return 'NOTFOUND';\
        var v = document.querySelector('video');\
        if (\(force ? "false" : "true") && v && v.paused) return 'PAUSED:SKIP';
        """
    }

    /// 点循环键直到到目标档(最多三下),回 `SET:<repeat-mode>`。
    public static func setRepeatJS(attribute target: String, force: Bool) -> String {
        "(function(){" + setPrologue(force: force) + """
        var b = bar.querySelector('yt-icon-button.repeat');\
        if (!b) return 'NOTFOUND';\
        var m = bar.getAttribute('repeat-mode') || '';\
        for (var i = 0; i < 3 && m !== '\(target)'; i++) { b.click(); m = bar.getAttribute('repeat-mode') || ''; }\
        return 'SET:' + m;\
        })()
        """
    }

    /// 赞 / 取消赞:跟目标不一样才点「赞」键,回 `SET:<like-status>`。
    /// 只认 `#button-shape-like`,找不到回 `NOTFOUND`;别拿渲染器里第一个按钮兜底,那是「踩」。
    public static func setLikeJS(liked: Bool, force: Bool) -> String {
        "(function(){" + setPrologue(force: force) + """
        var lk = bar.querySelector('ytmusic-like-button-renderer');\
        if (!lk) return 'NOTFOUND';\
        var b = lk.querySelector('#button-shape-like button');\
        if (!b) return 'NOTFOUND';\
        if ((lk.getAttribute('like-status') === 'LIKE') !== \(liked ? "true" : "false")) b.click();\
        return 'SET:' + (lk.getAttribute('like-status') || '');\
        })()
        """
    }

    /// 改音量条并发 change 事件,回 `SET:<音量条>`。
    public static func setVolumeJS(_ value: Int, force: Bool) -> String {
        "(function(){" + setPrologue(force: force) + """
        var s = document.querySelector('#volume-slider');\
        if (!s) return 'NOTFOUND';\
        s.value = \(min(100, max(0, value)));\
        s.dispatchEvent(new Event('change', {bubbles: true}));\
        return 'SET:' + String(s.value);\
        })()
        """
    }

    public static func parseRead(_ raw: String) -> State? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("STATE:") else { return nil }
        let parts = s.dropFirst(6).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        return State(mode: mode(fromAttribute: parts[0]), liked: liked(fromStatus: parts[1]),
                     volume: Double(parts[2]).map { Int($0.rounded()) })
    }

    public enum SetOutcome: Equatable, Sendable {
        /// 动过了,`SET:` 后面那个值(到没到目标调用方自己比)。
        case set(String)
        /// 只找到暂停着的页面、没动。
        case skipped
        case failed
    }

    public static func parseSet(_ raw: String) -> SetOutcome {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("SET:") { return .set(String(s.dropFirst(4))) }
        if s == "SKIP" { return .skipped }
        return .failed
    }

    /// 当前这条播放要不要走这里:播放器是浏览器、认出来在放 YouTube Music、而且这个浏览器配对过它。
    public static func target(reportedBundleID: String?, webPlatformID: String?, isPaired: (String) -> Bool) -> Target? {
        guard webPlatformID == platformID,
              let host = BrowserPositionProbe.probeTargetBundleID(forReported: reportedBundleID), !host.isEmpty,
              let family = BrowserAutomationPermission.family(forBundleID: host),
              isPaired(host) else { return nil }
        return Target(bundleID: host, family: family)
    }

    /// 读三样;页面没找到、读不懂为 nil。会阻塞到 osascript 结束,别在主线程调。
    public static func readState(_ target: Target) -> State? {
        run(target, js: readJS).flatMap(parseRead)
    }

    /// 切循环档,返回到没到。网页版没有随机这一档,传 `.shuffle` 回 false。会阻塞,别在主线程调。
    public static func setMode(_ mode: MusicPlaybackController.MusicPlaybackMode, _ target: Target) -> Bool {
        guard let attr = attribute(for: mode) else { return false }
        return writeUntilSet(target) { setRepeatJS(attribute: attr, force: $0) }.map { Self.mode(fromAttribute: $0) == mode } ?? false
    }

    /// 赞 / 取消赞,返回到没到。会阻塞,别在主线程调。
    public static func setLiked(_ value: Bool, _ target: Target) -> Bool {
        writeUntilSet(target) { setLikeJS(liked: value, force: $0) }.map { liked(fromStatus: $0) == value } ?? false
    }

    /// 设音量(0~100),返回写没写进去。会阻塞,别在主线程调。
    public static func setVolume(_ value: Int, _ target: Target) -> Bool {
        writeUntilSet(target) { setVolumeJS(value, force: $0) } != nil
    }

    /// 先只动在放的那页,一页都没在放再动第一页;回 `SET:` 后面的值,没写成为 nil。
    private static func writeUntilSet(_ target: Target, js: (Bool) -> String) -> String? {
        for force in [false, true] {
            guard let raw = run(target, js: js(force)) else { return nil }
            switch parseSet(raw) {
            case .set(let value): return value
            case .skipped: continue
            case .failed: return nil
            }
        }
        return nil
    }

    private static func run(_ target: Target, js: String) -> String? {
        BrowserTabProbeScript.run(bundleID: target.bundleID, family: target.family, hostMarker: YouTubeMusicAdProbe.hostMarker,
                                  js: js, eventTimeoutSeconds: eventTimeoutSeconds, processTimeout: processTimeout,
                                  label: "ytmusic-controls")
    }
}
