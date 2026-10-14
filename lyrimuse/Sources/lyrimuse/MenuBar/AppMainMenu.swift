import AppKit
import SwiftUI

/// 状态栏菜单和 App 主菜单(显示 Dock 图标时屏幕顶上那一条)共用的几样动作,两边点了去同一个地方。
@MainActor
enum AppMenuActions {
    /// 翻到设置的「关于」页(一次性信箱 `AppActions.pendingSettingsSelection`),不弹系统那张标准关于面板。
    static func openAbout() {
        AppActions.shared.requestSettings(.tab(.about))
        AppActions.shared.openSettings?()
    }

    /// 引导可以重来:走完的人后来想重新配一遍(换了播放器、服务被自己关掉了、想重新给权限)也得有入口。
    static func rerunOnboarding() { AppActions.shared.openOnboarding?() }

    /// 跟设置「关于」页的「反馈问题」同一个入口,见 FeedbackReporter。
    static func reportIssue() { FeedbackReporter.openNewIssue() }

    #if canImport(Sparkle)
    /// .accessory 策略下 Sparkle 弹出的检查更新界面得先手动激活 App,不然点了没反应(没有活跃窗口打底)。
    static func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        SparkleUpdaterManager.shared.checkForUpdates()
    }

    static func openSoftwareUpdate() {
        AppActions.shared.requestSettings(.softwareUpdate)
        AppActions.shared.openSettings?()
    }

    /// 查到还没装的新版本时那一项的标题,跟面板底栏同一句(06 章决策 46)。
    static func updateTitle(_ update: SparkleUpdaterManager.AvailableUpdate) -> String {
        String(format: update.downloaded ? L10n.t("%@ 已下载，点按安装") : L10n.t("有新版本 %@"), update.version)
    }
    #endif
}

/// App 主菜单:「关于 Lyrimuse」翻到设置的关于页,下面跟着「检查更新…」(查到新版本时换成那一句);「帮助」只留
/// 反馈问题、重新运行引导,跟状态栏菜单的「帮助」一样。无 Sparkle 构建里不给检查更新:点了没反应,不如不给。
struct AppMainMenuCommands: Commands {
    @ObservedObject private var updater = SparkleUpdaterManager.shared

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L10n.t("关于 Lyrimuse")) { AppMenuActions.openAbout() }
            #if canImport(Sparkle)
            if let update = updater.availableUpdate {
                Button(AppMenuActions.updateTitle(update)) { AppMenuActions.openSoftwareUpdate() }
            } else {
                Button(L10n.t("检查更新…")) { AppMenuActions.checkForUpdates() }
            }
            #endif
        }
        CommandGroup(replacing: .help) {
            Button(L10n.t("反馈问题…")) { AppMenuActions.reportIssue() }
            Button(L10n.t("重新运行引导…")) { AppMenuActions.rerunOnboarding() }
        }
    }
}

/// 系统在帮助菜单打开时插进来的「将 Lyrimuse 的使用反馈发送给 Apple」:它打开的是 Apple 的反馈助理,反馈到不了
/// 这个项目,插进来就当场移掉。替换 `.help` 那组命令、撤掉 `NSApp.helpMenu` 都挡不住它。按 action 认,不按标题
/// (随系统语言变);系统换了 action 名就认不出、照常留着,不会误删别的项。
enum HelpMenuFeedbackItem {
    static let action = Selector(("_openFeedbackAssistant:"))

    /// App 启动时调一次。
    static func installRemoval() {
        // queue: nil = 在插入它的那个线程(主线程)上同步收到,菜单画出来之前就移掉。
        NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                guard let menu = note.object as? NSMenu,
                      let index = note.userInfo?["NSMenuItemIndex"] as? Int,
                      menu.items.indices.contains(index),
                      menu.items[index].action == action else { return }
                menu.removeItem(at: index)
            }
        }
    }
}
