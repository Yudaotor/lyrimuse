import AppKit
import Combine
import SwiftUI

/// 设置 › 通用 › 外观:App 的普通窗口(设置、歌词窗口、歌词管理、菜单栏面板、首启引导,以及从它们弹出的
/// 菜单与对话框)用浅色、深色还是跟随系统。做法是设 `NSApp.appearance`,没有单独设过外观的窗口都跟着它。
///
/// 不跟它的展示面:悬浮歌词跟随系统(`SystemAppearanceStore.surfaceAppearance`,它的毛玻璃底压在桌面上,
/// 该和桌面一致),灵动岛固定深色,菜单栏歌词跟着真实菜单栏(`MenuBarAppearanceStore`)。
/// 存储为 rawValue(`np:appearanceMode`),认不出的值按 `.system`。见 14 章决策 103。
enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L10n.t("自动")
        case .light: return L10n.t("浅色")
        case .dark: return L10n.t("深色")
        }
    }

    /// 给 `NSApp.appearance` 的值;`nil` = 跟随系统。
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// 启动时(AppDelegate)和设置改动时各调一次。
    @MainActor
    func apply() {
        NSApp.appearance = nsAppearance
    }
}

/// 系统此刻是深色还是浅色。App 选了浅色 / 深色之后 `NSApp.effectiveAppearance` 就是那一档,
/// 要跟系统走的展示面只能从这里读。
@MainActor
final class SystemAppearanceStore: ObservableObject {
    static let shared = SystemAppearanceStore()

    @Published private(set) var isDark: Bool = SystemAppearanceStore.readSystemIsDark()

    private var observer: NSObjectProtocol?

    private init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let dark = SystemAppearanceStore.readSystemIsDark()
                if dark != SystemAppearanceStore.shared.isDark { SystemAppearanceStore.shared.isDark = dark }
            }
        }
    }

    /// 系统「外观」选自动时,这个键也跟着当前是深是浅改写。
    nonisolated static func readSystemIsDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// 跟随系统的展示面该用的外观:App 也跟随系统时返回 `nil`(直接继承,不靠上面那个键);
    /// App 选了浅色 / 深色时返回系统那一档。
    func surfaceAppearance(for mode: AppAppearanceMode) -> NSAppearance? {
        guard mode != .system else { return nil }
        return NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    /// `surfaceAppearance` 的 SwiftUI 版,给嵌在 App 窗口里、要画成真实展示面样子的预览用。
    func surfaceColorScheme(for mode: AppAppearanceMode) -> ColorScheme? {
        guard mode != .system else { return nil }
        return isDark ? .dark : .light
    }

    /// 两个输入(App 的外观设置、系统深浅)任一变了就回放一次,订阅时先回放当前值。
    func surfaceAppearancePublisher() -> AnyPublisher<NSAppearance?, Never> {
        AppSettings.shared.$appearanceMode
            .combineLatest($isDark)
            .map { mode, dark in
                guard mode != .system else { return nil }
                return NSAppearance(named: dark ? .darkAqua : .aqua)
            }
            .eraseToAnyPublisher()
    }
}

/// 预览里的展示面按系统深浅画(App 外观跟随系统时什么也不改)。
private struct FollowsSystemAppearance: ViewModifier {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var system = SystemAppearanceStore.shared
    @Environment(\.colorScheme) private var inherited

    func body(content: Content) -> some View {
        content.environment(\.colorScheme, system.surfaceColorScheme(for: settings.appearanceMode) ?? inherited)
    }
}

extension View {
    func followsSystemAppearance() -> some View {
        modifier(FollowsSystemAppearance())
    }
}
