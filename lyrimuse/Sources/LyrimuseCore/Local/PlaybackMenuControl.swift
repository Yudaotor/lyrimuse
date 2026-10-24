import AppKit
import ApplicationServices
import Foundation

/// QQ / 网易云 / 酷狗 / Pine Player / reAMP 失去系统媒体焦点时,只按目标进程菜单栏里的播放 / 暂停、上一首、下一首;汽水的菜单栏里没有这几项,
/// 按它底部播放条上的键(`SodaMusicControl.press`)。不激活 App、不模拟按键,不回落到全局媒体控制,没有跳转。
public enum PlaybackMenuControl {
    /// 失焦时能这样控制的播放器。路由(`MusicPlaybackController.controlRoute`)和 `press` 都按它,selftest 覆盖。
    public static let players: Set<PlaybackPlayer> = [.qqMusic, .netease, .kugou, .soda, .pinePlayer, .reamp]

    public enum Command: String, Equatable, Sendable {
        case playPause = "toggle-play-pause"
        case nextTrack = "next-track"
        case previousTrack = "previous-track"
    }

    public enum Outcome: Equatable, Sendable {
        case pressed
        case notTrusted
        case playerNotRunning
        /// 菜单未暴露、超时、改了标题、项目被禁用或没有 AXPress 时都不发。
        case menuUnavailable
        case pressFailed(code: Int32)
    }

    /// 菜单项标题 → 哪个控制。播放 / 暂停是同一项,标题随状态变,按下去都是切换。QQ 只有中文界面(简繁两套),
    /// 网易云只有简体和英文两套,标题取自它自己的语言包;酷狗只有简体,「播放/暂停」标题不随状态变。reAMP(英文、俄文两套)
    /// 的播放和暂停是两项:「暂停」在放着和暂停着时按下去都是切换,播放 / 暂停只按它,不认「播放」。纯函数,selftest 覆盖。
    public static func command(forMenuTitle title: String, player: PlaybackPlayer) -> Command? {
        let title = title.trimmingCharacters(in: .whitespaces)
        switch player {
        case .qqMusic:
            switch title {
            case "播放", "暂停", "暫停": return .playPause
            case "下一首": return .nextTrack
            case "上一首": return .previousTrack
            default: return nil
            }
        case .netease:
            switch title {
            case "播放", "暂停", "播放/暂停", "Play", "Pause", "Play/Pause": return .playPause
            case "下一个", "Next": return .nextTrack
            case "上一个", "Previous": return .previousTrack
            default: return nil
            }
        case .kugou:
            switch title {
            case "播放/暂停": return .playPause
            case "下一曲": return .nextTrack
            case "上一曲": return .previousTrack
            default: return nil
            }
        case .reamp:
            switch title {
            case "Pause", "Пауза": return .playPause
            case "Next", "Следующий": return .nextTrack
            case "Previous", "Предыдущий": return .previousTrack
            default: return nil
            }
        default:
            return nil
        }
    }

    /// 播放 / 暂停那一项的标题说明它在不在放:QQ、网易云在放时是「暂停」、停着时是「播放」;标题不随状态变(酷狗、网易云的
    /// 「播放/暂停」、Pine)或认不出为 nil。纯函数,selftest 覆盖。
    public static func showsPlaying(menuTitle title: String, player: PlaybackPlayer) -> Bool? {
        guard titleShowsState(player) else { return nil }
        switch title.trimmingCharacters(in: .whitespaces) {
        case "暂停", "暫停", "Pause": return true
        case "播放", "Play": return false
        default: return nil
        }
    }

    /// 播放 / 暂停那一项的标题随在不在放而变(`showsPlaying` 认得出)的播放器。
    public static func titleShowsState(_ player: PlaybackPlayer) -> Bool { player == .qqMusic || player == .netease }

    /// 菜单项的快捷键 → 哪个控制。Pine 有十种界面语言、菜单标题不在它的语言包里,按快捷键认:空格是播放 / 暂停,左、右方向键是
    /// 上一首、下一首,都不带 ⌘(修饰键 `noCommandModifier`)。纯函数,selftest 覆盖。
    public static func command(forMenuKey key: String, modifiers: Int, player: PlaybackPlayer) -> Command? {
        guard player == .pinePlayer, modifiers == noCommandModifier else { return nil }
        switch key {
        case " ": return .playPause
        case "\u{F702}": return .previousTrack
        case "\u{F703}": return .nextTrack
        default: return nil
        }
    }

    /// 菜单项修饰键里「不带 ⌘」那一位(`AXMenuItemCmdModifiers`,同 Carbon 的 `kMenuNoCommandModifier`)。
    static let noCommandModifier = 1 << 3

    /// 播放控制所在的那个菜单:里面认得出的控制至少有两种。只认一种的不算(英文界面的 Play、Next 是常见短词)。纯函数,selftest 覆盖。
    public static func isTransportMenu(_ commands: [Command]) -> Bool { Set(commands).count >= 2 }

    /// 同步返回 AXPress 是否送出,不把 API 成功当作播放器状态确认。
    /// 会阻塞跨进程调用,不要在主线程调;播放控制由 MusicPlaybackController 排入命令队列。
    /// 只读菜单三层,最多 20 个顶层菜单 / 每层 32 项。总读取预算 0.5s,
    /// 单次 AX 消息 0.1s(含按下动作);最多再等一条已经发出的消息,不重试动作。
    public static func press(_ command: Command, for player: PlaybackPlayer) -> Outcome {
        if player == .soda { return SodaMusicControl.press(command) }
        return withTransportItem(command, for: player) { item, attribute, inBudget in
            var actions: CFArray?
            guard AXUIElementCopyActionNames(item, &actions) == .success,
                  (actions as? [String])?.contains(kAXPressAction) == true, inBudget() else { return .menuUnavailable }
            let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
            return result == .success ? .pressed : .pressFailed(code: result.rawValue)
        }
    }

    /// 播放 / 暂停那一项此刻的标题,只读不按;读不到为 nil。QQ、网易云在放时是「暂停」、停着时是「播放」,按下去之后靠它确认
    /// 真的放起来了。会阻塞跨进程调用,不要在主线程调。
    public static func playPauseTitle(for player: PlaybackPlayer) -> String? {
        var title: String?
        _ = withTransportItem(.playPause, for: player) { item, attribute, _ in
            title = attribute(item, kAXTitleAttribute) as? String
            return .pressed
        }
        return title
    }

    /// 在播放控制那个菜单里找 `command` 那一项(要启用着),交给 `body`;找不到、没授权、播放器没在跑时不调 `body`,按原因返回。
    /// `body` 拿到读属性的函数(同一份读取预算)和「预算还没用完」。
    private static func withTransportItem(
        _ command: Command, for player: PlaybackPlayer,
        body: (AXUIElement, (AXUIElement, String) -> AnyObject?, () -> Bool) -> Outcome
    ) -> Outcome {
        guard player == .qqMusic || player == .netease || player == .kugou || player == .pinePlayer || player == .reamp else {
            return .menuUnavailable
        }
        guard AXIsProcessTrusted() else { return .notTrusted }
        guard let pid = PlayerProcess.pid(bundleID: player.bundleIdentifier) else { return .playerNotRunning }
        let app = AXUIElementCreateApplication(pid)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        func inBudget() -> Bool { ProcessInfo.processInfo.systemUptime < deadline }
        func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
            // AX 超时只属于这个对象,不会从 application 继承到新取得的菜单/菜单项。
            guard inBudget(), AXUIElementSetMessagingTimeout(element, 0.1) == .success else { return nil }
            var value: AnyObject?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        guard let rawMenuBar = attribute(app, kAXMenuBarAttribute),
              CFGetTypeID(rawMenuBar) == AXUIElementGetTypeID() else { return .menuUnavailable }
        let menuBar = rawMenuBar as! AXUIElement
        for top in children(menuBar).prefix(20) {
            guard attribute(top, kAXRoleAttribute) as? String == kAXMenuBarItemRole else { continue }
            for menu in children(top).prefix(32) where attribute(menu, kAXRoleAttribute) as? String == kAXMenuRole {
                let found = children(menu).prefix(32).compactMap { item -> (command: Command, element: AXUIElement)? in
                    guard attribute(item, kAXRoleAttribute) as? String == kAXMenuItemRole else { return nil }
                    if player == .pinePlayer {
                        guard let key = attribute(item, kAXMenuItemCmdCharAttribute) as? String,
                              let modifiers = (attribute(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue,
                              let command = Self.command(forMenuKey: key, modifiers: modifiers, player: player) else { return nil }
                        return (command, item)
                    }
                    guard let title = attribute(item, kAXTitleAttribute) as? String,
                          let command = Self.command(forMenuTitle: title, player: player) else { return nil }
                    return (command, item)
                }
                guard isTransportMenu(found.map(\.command)) else { continue }
                guard let item = found.first(where: { $0.command == command })?.element,
                      attribute(item, kAXEnabledAttribute) as? Bool == true, inBudget() else { return .menuUnavailable }
                return body(item, attribute, inBudget)
            }
        }
        return .menuUnavailable
    }
}
