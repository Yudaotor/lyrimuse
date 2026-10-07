import Foundation

/// 浏览器里 YouTube Music 网页版的循环键:读写播放条 `ytmusic-player-bar` 上的 `repeat-mode` 属性(NONE / ALL / ONE,
/// 跟界面语言无关),写入是用脚本点它自己那颗循环键(`yt-icon-button.repeat`),点一下立即翻到下一档(关 → 全部 → 单曲 → 关)。
/// 网页版的「随机播放」不是开关、是把队列打乱一次的动作,没有状态可读,随机键不显示。见 07 章决策 136。
///
/// 注入走 `BrowserTabProbeScript`(跟广告探针同一份模板、同一个 JavaScript 授权);只在这个浏览器配对过 YouTube Music
/// 时用。开着几个 YouTube Music 标签页时认在放的那一页:写入先只点在放的那页,一页都没在放(全暂停着)再对第一页点。
public enum YouTubeMusicWebRepeat {
    public static let platformID = "youtubeMusic"
    public static let options: MusicPlaybackController.PlaybackModeOptions = [.repeatAll, .repeatOne]
    static let eventTimeoutSeconds = 4
    static let processTimeout: TimeInterval = 6

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

    /// 读当前档。暂停的标签页带 `PAUSED:` 前缀,模板据此先找在放的那一页。不许出现双引号(见 `BrowserTabProbeScript`)。
    public static let readJS = """
    (function(){\
    var bar = document.querySelector('ytmusic-player-bar');\
    if (!bar) return 'NOTFOUND';\
    var out = 'MODE:' + (bar.getAttribute('repeat-mode') || '');\
    var v = document.querySelector('video');\
    return (v && v.paused) ? 'PAUSED:' + out : out;\
    })()
    """

    /// 点循环键直到到目标档(最多三下)。`force` 为 false 时暂停的标签页不点、回 `PAUSED:SKIP:…`,让模板接着找在放的那页。
    public static func setJS(attribute target: String, force: Bool) -> String {
        """
        (function(){\
        var bar = document.querySelector('ytmusic-player-bar');\
        if (!bar) return 'NOTFOUND';\
        var m = bar.getAttribute('repeat-mode') || '';\
        var v = document.querySelector('video');\
        if (\(force ? "false" : "true") && v && v.paused) return 'PAUSED:SKIP:' + m;\
        var b = bar.querySelector('yt-icon-button.repeat');\
        if (!b) return 'NOTFOUND';\
        for (var i = 0; i < 3 && m !== '\(target)'; i++) { b.click(); m = bar.getAttribute('repeat-mode') || ''; }\
        return 'SET:' + m;\
        })()
        """
    }

    /// 读的返回值 → 档位;没找到页面、读不懂为 nil。
    public static func parseRead(_ raw: String) -> MusicPlaybackController.MusicPlaybackMode? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("MODE:") else { return nil }
        return mode(fromAttribute: String(s.dropFirst(5)))
    }

    public enum SetOutcome: Equatable, Sendable {
        /// 点过了,停在这一档(到没到目标看它等不等于目标)。
        case set(MusicPlaybackController.MusicPlaybackMode?)
        /// 只找到暂停着的页面、没点。
        case skipped
        case failed
    }

    public static func parseSet(_ raw: String) -> SetOutcome {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("SET:") { return .set(mode(fromAttribute: String(s.dropFirst(4)))) }
        if s.hasPrefix("SKIP:") { return .skipped }
        return .failed
    }

    /// 当前这条播放要不要走这里:播放器是浏览器、认出来在放 YouTube Music、而且这个浏览器配对过它。
    /// 回浏览器本体的 bundle id(Safari 报的 `com.apple.WebKit.GPU` 换成 `com.apple.Safari`)和脚本方言。
    public static func target(reportedBundleID: String?, webPlatformID: String?,
                              isPaired: (String) -> Bool) -> (bundleID: String, family: BrowserAutomationPermission.Family)? {
        guard webPlatformID == platformID,
              let host = BrowserPositionProbe.probeTargetBundleID(forReported: reportedBundleID), !host.isEmpty,
              let family = BrowserAutomationPermission.family(forBundleID: host),
              isPaired(host) else { return nil }
        return (host, family)
    }

    /// 读当前档;读不到为 nil。会阻塞到 osascript 结束,别在主线程调。
    public static func readMode(bundleID: String, family: BrowserAutomationPermission.Family) -> MusicPlaybackController.MusicPlaybackMode? {
        BrowserTabProbeScript.run(bundleID: bundleID, family: family, hostMarker: YouTubeMusicAdProbe.hostMarker,
                                  js: readJS, eventTimeoutSeconds: eventTimeoutSeconds,
                                  processTimeout: processTimeout, label: "ytmusic-repeat")
            .flatMap(parseRead)
    }

    /// 切到某一档,返回到没到。网页版没有随机这一档,传 `.shuffle` 回 false。会阻塞,别在主线程调。
    public static func setMode(_ mode: MusicPlaybackController.MusicPlaybackMode, bundleID: String,
                               family: BrowserAutomationPermission.Family) -> Bool {
        guard let target = attribute(for: mode) else { return false }
        for force in [false, true] {
            guard let raw = BrowserTabProbeScript.run(
                bundleID: bundleID, family: family, hostMarker: YouTubeMusicAdProbe.hostMarker,
                js: setJS(attribute: target, force: force), eventTimeoutSeconds: eventTimeoutSeconds,
                processTimeout: processTimeout, label: "ytmusic-repeat") else { return false }
            switch parseSet(raw) {
            case .set(let reached): return reached == mode
            case .skipped: continue
            case .failed: return false
            }
        }
        return false
    }
}
