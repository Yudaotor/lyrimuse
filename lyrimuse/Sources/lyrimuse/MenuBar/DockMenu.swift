import AppKit

// Dock 图标右键菜单的自定义部分。2026-08-26 用户对照 Apple Music 自己的 Dock 菜单
// (播放中信息+一串播放/收藏动作,前置在系统默认项之上)要求也给这里加几个常用跳转——
// 这个 App 没有 Apple Music 那类"当前播放"可操作的动作(播放/暂停/切歌已经有独立的
// 桌面悬浮控制胶囊),能加的是"跳到几扇常用窗口/页面",所以只做这四条:设置/歌词管理/
// 歌词窗口/Last.fm。
//
// 不实现这个类的话,`.regular` 激活策略(显示 Dock 图标)下右键 Dock 图标能看到的只有
// 系统自动附加的那部分:当前开着的窗口列表("◇ 歌词窗口 / ✓ 设置"那两行就是这个,不是
// 这个类画的)、"选项"子菜单、显示所有窗口/隐藏/退出——这几项由 AppKit 自动追加在这里
// 返回的菜单**下面**,这个类不需要重复画它们。
//
// 跟 MenuBarStatusMenu(状态栏下拉菜单)分成两个独立的类而不是共用一份:那边是
// NSStatusItem 的下拉菜单,靠 NSMenuDelegate.menuNeedsUpdate 在打开前重建;而
// applicationDockMenu(_:) 本身就是"AppKit 每次右键都会重新问 delegate 要一份"的调用
// 形态,不需要另外接 delegate 才能保证内容是最新的,菜单项也少得多(没有状态开关/子菜单
// 那一整套),硬凑成一份反而让两边互相牵制。
@MainActor
final class DockMenuController: NSObject {
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item(L10n.t("设置…"), symbol: "gearshape",
                          selector: #selector(openSettings)))
        menu.addItem(item(L10n.t("歌词管理…"), symbol: "music.note.list",
                          selector: #selector(openLyricsManager)))
        menu.addItem(item(L10n.t("歌词窗口…"), symbol: "text.quote",
                          selector: #selector(openLyricsWindow)))
        // Last.fm 用真实品牌图标(跟菜单栏面板底栏、设置页账号卡片同一张 PNG),不用
        // 泛化 SF Symbol 凑数——见 AccountLinkingTab.swift 里 lastfmBadgeImage 的注释。
        // 标题不加"…"、也不像 MenuBarPanel.lastfmButton 那样显示已连接的账号名——这里
        // 是固定入口(不管连没连都指向设置里的 Last.fm 那一页,没连的话那页本身就有
        // "连接 Last.fm"引导),跟"设置…/歌词管理…/歌词窗口…"三个开窗动作保持同一种
        // 简单跳转语义就够。
        menu.addItem(item("Last.fm", image: lastfmBadgeImage,
                          selector: #selector(openLastfm)))
        return menu
    }

    private func item(_ title: String, symbol: String, selector: Selector) -> NSMenuItem {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        return item(title, image: image, selector: selector)
    }

    private func item(_ title: String, image: NSImage?, selector: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        menuItem.target = self
        menuItem.isEnabled = true
        menuItem.image = image
        return menuItem
    }

    // 下面几个动作都走 AppActions——那几个闭包里已经带了 NSApp.activate(ignoringOtherApps:),
    // 这里不需要另外激活一次(跟 MenuBarStatusMenu 里同名动作同一个理由)。
    @objc private func openSettings() { AppActions.shared.openSettings?() }
    @objc private func openLyricsManager() { AppActions.shared.openLyricsManager?() }
    @objc private func openLyricsWindow() { AppActions.shared.openLyricsWindow?() }

    @objc private func openLastfm() {
        AppActions.shared.requestSettings(.account(.lastfm))
        AppActions.shared.openSettings?()
    }
}
