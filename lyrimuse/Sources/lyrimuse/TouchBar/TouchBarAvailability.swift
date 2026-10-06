import AppKit
import Combine
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "touchbar")

/// 这台 Mac 此刻有没有触控栏(真机,或者 Xcode 的触控栏模拟器开着)。没有时设置页「触控栏」那一段只放一张
/// 「这台 Mac 没有触控栏」的说明卡、设置搜索只留总开关那一条,触控栏歌词也不启用(开关的值留着,换到有触控栏的
/// Mac 上照常生效)。
///
/// 判据在 Core `TouchBarPresence`,这里取输入、跟着变:
/// - 运行中 App 列表(KVO)里系统的 ControlStrip 起停;
/// - ControlStrip 在跑之后注册的 DFRFoundation 状态回调(模拟器开 / 关、触控栏出现 / 消失,实测一两秒内就到);
/// - 设置页「歌词显示」每次出现时补判一次,兜住漏掉的通知。
@MainActor
final class TouchBarAvailability: ObservableObject {
    static let shared = TouchBarAvailability()
    /// 系统的 ControlStrip(功能栏那一条就是它画的)。launchd 只在系统匹配到触控栏时拉起它。
    static let controlStripBundleID = "com.apple.controlstrip"

    @Published private(set) var isPresent = false
    /// 这块触控栏左端是不是一颗虚拟 Esc 键(1st generation 是,2nd generation 是实体键),跟 `isPresent` 一起判;
    /// 没有触控栏时 false。是的话展开歌词时左端补一颗自己的 esc 键(`TouchBarEscapeKey`,见 17 章决策 36)。
    @Published private(set) var hasEscapeKey = false
    private var started = false
    private var controlStripRunning = false
    private var statusCallbackRegistered = false
    private var runningAppsObservation: NSKeyValueObservation?

    private init() {}

    /// App 启动时由 `TouchBarLyricsController.start()` 调一次。
    func start() {
        guard !started else { return }
        started = true
        runningAppsObservation = NSWorkspace.shared.observe(\.runningApplications) { _, _ in
            DispatchQueue.main.async { TouchBarAvailability.shared.runningAppsChanged() }
        }
        reevaluate()
    }

    /// 重判一次。不在 ControlStrip 在跑的时候,一个私有接口都不碰(见 `TouchBarPresence`)。
    func reevaluate() {
        controlStripRunning = Self.isControlStripRunning()
        if controlStripRunning, !statusCallbackRegistered {
            statusCallbackRegistered = TouchBarPrivateAPI.registerStatusChange {
                DispatchQueue.main.async { TouchBarAvailability.shared.reevaluate() }
            }
        }
        let present = TouchBarPresence.isPresent(
            controlStripRunning: controlStripRunning,
            touchBarReported: controlStripRunning ? TouchBarPrivateAPI.touchBarReported() : nil)
        let escapeKey = present && (TouchBarPrivateAPI.touchBarHasEscapeKey() ?? false)
        if escapeKey != hasEscapeKey {
            hasEscapeKey = escapeKey
            logger.notice("[TouchBarAvailability.reevaluate] escapeKey=\(escapeKey)")
        }
        guard present != isPresent else { return }
        isPresent = present
        logger.notice("[TouchBarAvailability.reevaluate] present=\(present) controlStrip=\(self.controlStripRunning)")
    }

    /// 任何 App 起停都会来一次;只在 ControlStrip 那一位变了时重判。
    private func runningAppsChanged() {
        guard Self.isControlStripRunning() != controlStripRunning else { return }
        reevaluate()
    }

    private static func isControlStripRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == controlStripBundleID }
    }
}
