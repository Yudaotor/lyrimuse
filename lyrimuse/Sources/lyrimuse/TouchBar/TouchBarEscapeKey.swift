import AppKit
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "touchbar")

/// 1st generation 触控栏(左端是一颗虚拟 Esc 键)上展开歌词时,系统模态条占掉 Esc 那一格;歌词条用
/// `escapeKeyReplacementItemIdentifier` 把这颗键放回去(见 17 章决策 36)。键帽上是「esc」,同系统那颗,不分语言;
/// 宽同系统那颗(`TouchBarLyricsStyle.escapeKeyWidth`)。
///
/// 按下去往系统事件流里发一次 Esc(按下 + 抬起),跟实体键一样落到此刻的前台 App。发键盘事件要辅助功能权限:
/// 没授权时这一下不发,交给 `AccessibilityPermission.handleAction()`(头一次弹系统的授权对话框,之后再按直接打开
/// 系统设置的「辅助功能」),跟设置页那一行同一份状态。
@MainActor
enum TouchBarEscapeKey {
    /// `kVK_Escape`。
    private static let keyCode: CGKeyCode = 0x35

    static func makeButton(target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: "esc", target: target, action: action)
        button.setAccessibilityLabel("esc")
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: CGFloat(TouchBarLyricsStyle.escapeKeyWidth)).isActive = true
        return button
    }

    static func press() {
        guard AccessibilitySkipPress.isTrusted else {
            logger.notice("[TouchBarEscapeKey.press] accessibility not granted, asking for it")
            AccessibilityPermission.shared.handleAction()
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)?.post(tap: .cghidEventTap)
        }
        logger.info("[TouchBarEscapeKey.press] posted")
    }
}
