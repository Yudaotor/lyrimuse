import AppKit
import ApplicationServices
import Foundation

/// QQ 失去系统媒体焦点时,只按它自己的「播放控制」菜单。不激活 App、不模拟按键,
/// 不回落到全局媒体控制。QQ 不暴露 AX 进度条,因此这里没有 seek。
public enum QQMusicAccessibilityControl {
    public enum Command: String, Equatable, Sendable {
        case playPause = "toggle-play-pause"
        case nextTrack = "next-track"
        case previousTrack = "previous-track"

        /// 只匹配真机确认过的菜单标题。播放/暂停标题会延迟刷新,两者都是同一个 toggle 动作。
        public func matches(menuTitle: String) -> Bool {
            switch self {
            case .playPause: return menuTitle == "播放" || menuTitle == "暂停"
            case .nextTrack: return menuTitle == "下一首"
            case .previousTrack: return menuTitle == "上一首"
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        case pressed
        case notTrusted
        case playerNotRunning
        /// 菜单未暴露、超时、改了标题、项目被禁用或没有 AXPress 时都不发。
        case menuUnavailable
        case pressFailed(code: Int32)
    }

    /// 同步返回 AXPress 是否送出,不把 API 成功当作播放器状态确认。
    /// 会阻塞跨进程调用,不要在主线程调;播放控制由 MusicPlaybackController 排入命令队列。
    /// 只读菜单三层,最多 20 个顶层菜单 / 每层 32 项。总读取预算 0.5s,
    /// 单次 AX 消息 0.1s(含按下动作);最多再等一条已经发出的消息,不重试动作。
    public static func press(_ command: Command) -> Outcome {
        guard AXIsProcessTrusted() else { return .notTrusted }
        guard let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: PlaybackPlayer.qqMusic.bundleIdentifier).first else { return .playerNotRunning }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
            // AX 超时只属于这个对象,不会从 application 继承到新取得的菜单/菜单项。
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  AXUIElementSetMessagingTimeout(element, 0.1) == .success else { return nil }
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
            guard attribute(top, kAXRoleAttribute) as? String == kAXMenuBarItemRole,
                  attribute(top, kAXTitleAttribute) as? String == "播放控制" else { continue }
            for menu in children(top).prefix(32) where attribute(menu, kAXRoleAttribute) as? String == kAXMenuRole {
                for item in children(menu).prefix(32) {
                    guard attribute(item, kAXRoleAttribute) as? String == kAXMenuItemRole,
                          let title = attribute(item, kAXTitleAttribute) as? String,
                          command.matches(menuTitle: title) else { continue }
                    guard attribute(item, kAXEnabledAttribute) as? Bool == true,
                          ProcessInfo.processInfo.systemUptime < deadline else { return .menuUnavailable }
                    var actions: CFArray?
                    guard AXUIElementCopyActionNames(item, &actions) == .success,
                          (actions as? [String])?.contains(kAXPressAction) == true,
                          ProcessInfo.processInfo.systemUptime < deadline else { return .menuUnavailable }
                    let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
                    return result == .success ? .pressed : .pressFailed(code: result.rawValue)
                }
            }
        }
        return .menuUnavailable
    }
}
