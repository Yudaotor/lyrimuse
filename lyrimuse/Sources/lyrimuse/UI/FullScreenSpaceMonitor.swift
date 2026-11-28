import AppKit
import Combine
import LyrimuseCore

/// 各块屏幕的当前 Space 是不是全屏 App,给灵动岛「全屏时隐藏」用。判据在 Core `FullScreenSpaces`。
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
        let raw = Self.spaceFunctions.flatMap { mainConnection, copySpaces in
            copySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]]
        } ?? []
        let next = FullScreenSpaces.fullScreenDisplays(in: raw)
        if next != fullScreenDisplays { fullScreenDisplays = next }
    }
}

// SkyLight 私有函数,运行时查找(同 BackgroundCursor):强链接的话系统哪天拿掉这两个符号,整个 App 启动时就被 dyld 拦下;
// 查不到时 refresh 按「没有全屏」算。返回值按 Copy 规则是 +1 引用,用 Unmanaged 接住再 takeRetainedValue;可能为 NULL。
extension FullScreenSpaceMonitor {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let spaceFunctions: (MainConnectionID, CopyManagedDisplaySpaces)? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let main = dlsym(handle, "CGSMainConnectionID"),
              let copy = dlsym(handle, "CGSCopyManagedDisplaySpaces") else { return nil }
        return (unsafeBitCast(main, to: MainConnectionID.self), unsafeBitCast(copy, to: CopyManagedDisplaySpaces.self))
    }()
}
