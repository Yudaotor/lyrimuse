import AppKit
import Combine
import LyrimuseCore

/// 各块屏幕的当前 Space 是不是全屏 App,给灵动岛「全屏时收起歌词」用。判据在 Core `FullScreenSpaces`。
///
/// 只在切 Space、屏幕配置变化时读一次,不轮询。通知到达时系统的 Space 表偶尔还没换过来,
/// 所以每次通知之后再补读一次(`settleDelay`)。私有函数取不到数据时按「没有全屏」算,
/// 也就是维持不隐藏。见 05 章决策 45。
@MainActor
final class FullScreenSpaceMonitor: ObservableObject {
    static let shared = FullScreenSpaceMonitor()

    /// 当前 Space 为全屏的屏幕标识(大写 UUID 串,或 `FullScreenSpaces.sharedSpacesIdentifier`)。
    @Published private(set) var fullScreenDisplays: Set<String> = []

    private static let settleDelay: TimeInterval = 0.6
    private var observers: [NSObjectProtocol] = []
    private var settleWork: DispatchWorkItem?

    private init() {
        refresh()
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNowAndAfterSettle() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNowAndAfterSettle() }
        })
    }

    /// 这块屏幕此刻是否被全屏 App 占着。
    func covers(_ screen: NSScreen?) -> Bool {
        guard let screen else { return false }
        return FullScreenSpaces.covers(screenID: ScreenIdentity.id(of: screen),
                                       isMainScreen: screen == NSScreen.screens.first,
                                       fullScreenDisplays: fullScreenDisplays)
    }

    private func refreshNowAndAfterSettle() {
        refresh()
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private func refresh() {
        let raw = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] ?? []
        let next = FullScreenSpaces.fullScreenDisplays(in: raw)
        if next != fullScreenDisplays { fullScreenDisplays = next }
    }
}

// SkyLight 私有函数。返回值按 Copy 规则是 +1 引用,Swift 调用约定按已持有接管;可能为 NULL,所以声明成可选。
@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") private func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray?
