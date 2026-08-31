import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts

// 录制全局快捷键时的冲突检查。
//
// ⚠️ 2026-08-31 加。在这之前 `ShortcutRecorderButton.handle(_:)` 只校验了"必须含
// ⌘/⌥/⌃ 之一",校验完直接 `setShortcut` 写入,于是有两个静默失败:
//
//  1. **录一个被 macOS 占用的组合(⌘Space、⌃↑ 这类)会"成功"**,按钮上正常显示出那个
//     组合 —— 但底层 `RegisterEventHotKey` 注册失败后是 `guard ... else { return }`
//     静默返回,这个键**永远不会触发**。用户没有任何办法自己发现,只会觉得"这软件的
//     快捷键坏了"。
//  2. **两个动作绑同一个组合不会被拦**,而库的派发是遍历全部 name、凡匹配就逐个执行
//     (`KeyboardShortcuts.handleOnKeyUp`,没有 break):按一次两个动作都会发生。更糟的是
//     `CarbonKeyboardShortcuts.unregister(_:)` 按 shortcut 删**所有**匹配项,事后清掉
//     其中一个会连带把另一个的注册也拆了。
//
// ⚠️ 库自己的 Recorder(`RecorderCocoa`)本来做了前两类检查(`shortcut.isTakenBySystem` /
// `shortcut.takenByMainMenu`),但这个项目因为输入法问题换成了自己的 NSButton 实现
// (理由见 ShortcutRecorder.swift 顶部),换的时候只抄了 modifier 那一条。**那两个 API 是
// 库的 internal 成员,跨模块调不到**,所以这里不是"把它们接回来",而是照同样的口径自己
// 实现一遍(系统占用表同样走 `CopySymbolicHotKeys`)。
enum ShortcutConflict {
    enum Kind {
        /// 撞了 Lyrimuse 自己另一个全局快捷键;带上那个动作给用户看的名字。
        case otherHotkey(String)
        /// 撞了本 App 主菜单里的一项(⌘W/⌘, 这类);带上那一项的标题。
        case mainMenu(String)
        /// 被 macOS 系统快捷键占用。
        case system

        /// 弹窗标题。三种冲突的处置方式不同,所以文案分开写,不合并成一句泛泛的"冲突"。
        var message: String {
            switch self {
            case .otherHotkey(let title):
                return String(format: L10n.t("这个组合已经分配给「%@」了。"), title)
            case .mainMenu(let title):
                return String(format: L10n.t("这个组合是本 App 菜单里「%@」的快捷键。"), title)
            case .system:
                return L10n.t("这个组合已被 macOS 系统占用。")
            }
        }

        var hint: String {
            switch self {
            case .otherHotkey:
                return L10n.t("换一个组合，或者先清除那一项。")
            case .mainMenu:
                return L10n.t("换一个组合——否则 Lyrimuse 在前台时，按下它会同时触发菜单里的那一项。")
            case .system:
                return L10n.t("换一个组合。系统占用的组合注册不上，录进去也不会生效；要用它得先到「系统设置 → 键盘 → 键盘快捷键」里把系统那一项关掉。")
            }
        }
    }

    /// 检查这个组合能不能给 `recording` 这个动作用。返回 nil 表示没冲突。
    ///
    /// `event` 是录制时那一下真实按键 —— 主菜单比对需要"这个键印出来是哪个字符"
    /// (`NSMenuItem.keyEquivalent` 存的就是字符,不是 keyCode),而从 carbonKeyCode 反推
    /// 字符要走 UCKeyTranslate + 当前键盘布局,是一整套活;录制现场手上就有 NSEvent,
    /// `charactersIgnoringModifiers` 正好是同一个口径,直接用它。
    @MainActor
    static func check(
        _ shortcut: KeyboardShortcuts.Shortcut,
        event: NSEvent,
        recording name: KeyboardShortcuts.Name
    ) -> Kind? {
        // 顺序有意:自家撞键最常见、也最好改,先报它。
        for other in KeyboardShortcuts.Name.allLyrimuseNames where other != name {
            if KeyboardShortcuts.getShortcut(for: other) == shortcut {
                return .otherHotkey(KeyboardShortcuts.Name.title(for: other))
            }
        }
        if let item = mainMenuItem(matching: event) {
            return .mainMenu(item)
        }
        if isTakenBySystem(shortcut) {
            return .system
        }
        return nil
    }

    // MARK: - 主菜单

    @MainActor
    private static func mainMenuItem(matching event: NSEvent) -> String? {
        guard let mainMenu = NSApp.mainMenu else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else { return nil }
        return search(mainMenu, chars: chars, modifiers: modifiers)
    }

    @MainActor
    private static func search(_ menu: NSMenu, chars: String, modifiers: NSEvent.ModifierFlags) -> String? {
        for item in menu.items {
            var equivalent = item.keyEquivalent
            var mask = item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift])
            // 菜单项把 Shift 编码在**字符本身**里(⌘⇧S 存成 keyEquivalent="S"、mask 不含
            // .shift)。统一成"小写字符 + 显式 .shift",两边才比得起来 —— 这一步跟库
            // `menuItemWithMatchingShortcut` 的做法一致。
            if equivalent.lowercased() != equivalent {
                equivalent = equivalent.lowercased()
                mask.insert(.shift)
            }
            if equivalent == chars, mask == modifiers {
                return item.title
            }
            if let submenu = item.submenu, let hit = search(submenu, chars: chars, modifiers: modifiers) {
                return hit
            }
        }
        return nil
    }

    // MARK: - 系统占用

    /// macOS 自己占用的组合(⌘Space 切输入法、⌃↑ 调度中心……)。
    ///
    /// 每次录制现算一遍、不缓存:用户随时可能去「系统设置 → 键盘快捷键」里改,缓存下来
    /// 就会拿着一份过期的表拒绝一个其实已经空出来的组合。这个调用很轻(一次
    /// `CopySymbolicHotKeys`),而录制是低频操作。
    private static func isTakenBySystem(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        // F12 是唯一的例外,照抄库的判断:系统把它登记成"显示 Dashboard"(那个功能早就
        // 没了),不排除的话 F12 会被误判成被占用。
        if shortcut.carbonKeyCode == kVK_F12, shortcut.carbonModifiers == 0 { return false }

        var raw: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&raw) == noErr,
              let entries = raw?.takeRetainedValue() as? [[String: Any]]
        else {
            // 拿不到系统表时**放行**,不是拦截 —— 这道检查是帮忙,不该因为它自己失败就
            // 让用户连快捷键都录不了。
            return false
        }
        for e in entries {
            guard (e[kHISymbolicHotKeyEnabled] as? Bool) == true,
                  let code = e[kHISymbolicHotKeyCode] as? Int,
                  let mods = e[kHISymbolicHotKeyModifiers] as? Int
            else { continue }
            if code == shortcut.carbonKeyCode, mods == shortcut.carbonModifiers { return true }
        }
        return false
    }

    // MARK: - 提示

    /// 弹一条说明并放弃这次录制。
    ///
    /// ⚠️ 必须异步弹:调用点在 `NSEvent.addLocalMonitorForEvents` 的回调里,在事件监听
    /// 闭包内部起模态会话是重入,轻则弹窗吃不到键盘、重则卡住。先让这一轮事件处理结束
    /// (调用方已经 stopRecording、把监听摘掉了),下一个 runloop 回合再弹。
    @MainActor
    static func present(_ kind: Kind, over window: NSWindow?) {
        NSSound.beep()
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = kind.message
            alert.informativeText = kind.hint
            alert.addButton(withTitle: L10n.t("好"))
            if let window {
                alert.beginSheetModal(for: window, completionHandler: nil)
            } else {
                alert.runModal()
            }
        }
    }
}
