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
/// - 运行中 App 列表(KVO)一变就在后台查一次 ControlStrip 在不在跑(`ControlStripProcess`,只问内核进程表);
/// - ControlStrip 在跑之后注册的 DFRFoundation 状态回调(模拟器开 / 关、触控栏出现 / 消失,实测一两秒内就到);
/// - 设置页「歌词显示」每次出现时补判一次,兜住漏掉的通知。
@MainActor
final class TouchBarAvailability: ObservableObject {
    static let shared = TouchBarAvailability()

    @Published private(set) var isPresent = false

    /// 设置页「歌词显示 › 触控栏」那一段按「有触控栏」来画(工具栏、浮层、总开关、抽屉)。预览钩子:没有触控栏的机器上
    /// `defaults write me.yudaotor.lyrimuse settings:previewTouchBarPresent -bool true` 之后切到这一段就能看全、调设置界面;
    /// `defaults delete … settings:previewTouchBarPresent` 恢复。只给设置页这一段用:触控栏歌词本身、设置搜索、菜单、引导都还看
    /// `isPresent`,这台机器上照旧不启用,一个私有接口都不碰。`settings:` 前缀 = 机器状态,配置导出不带走。
    var settingsShowsPresent: Bool {
        isPresent || UserDefaults.standard.bool(forKey: Self.previewPresentKey)
    }
    static let previewPresentKey = "settings:previewTouchBarPresent"
    /// 这块触控栏左端是不是一颗虚拟 Esc 键(1st generation 是,2nd generation 是实体键),跟 `isPresent` 一起判;
    /// 没有触控栏时 false。是的话展开歌词时左端补一颗自己的 esc 键(`TouchBarEscapeKey`,见 17 章决策 36)。
    @Published private(set) var hasEscapeKey = false
    private var started = false
    private var controlStripRunning = false
    private var controlStripPID: pid_t?
    private var statusCallbackRegistered = false
    private var runningAppsObservation: NSKeyValueObservation?
    /// 查 ControlStrip 一次只派一个;派不出去时记下,这一次回来后再查一遍。
    private let probes = SingleFlightBackgroundRead<ControlStripProcess.Probe>()
    private var probeAgain = false

    private init() {}

    /// App 启动时由 `TouchBarLyricsController.start()` 调一次。
    func start() {
        guard !started else { return }
        started = true
        // 回调里不读那张表、也不读里面 App 的属性:读一次就是同步问 launchservicesd(17 章决策 60)。
        runningAppsObservation = NSWorkspace.shared.observe(\.runningApplications) { _, _ in
            DispatchQueue.main.async { TouchBarAvailability.shared.probeControlStrip() }
        }
        probeControlStrip()
    }

    /// 补判一次(设置页出现时):按上次查到的 ControlStrip 立刻重判,另在后台再查一次它,变了再重判。
    func reevaluate() {
        probeControlStrip()
        apply()
    }

    /// 在后台查 ControlStrip,回主线程只拿结论。
    private func probeControlStrip() {
        let known = controlStripPID
        let issued = probes.start(read: { ControlStripProcess.probe(known: known) }, apply: { probe in
            TouchBarAvailability.shared.controlStripProbed(probe)
        })
        if !issued { probeAgain = true }
    }

    private func controlStripProbed(_ probe: ControlStripProcess.Probe) {
        if probeAgain {
            probeAgain = false
            probeControlStrip()
        }
        let running: Bool
        switch probe {
        case let .running(pid):
            controlStripPID = pid
            running = true
        case .notRunning:
            controlStripPID = nil
            running = false
        case .unknown:
            return
        }
        guard running != controlStripRunning else { return }
        controlStripRunning = running
        apply()
    }

    /// 按此刻知道的 ControlStrip 在不在跑重判。不在跑的时候,一个私有接口都不碰(见 `TouchBarPresence`)。
    private func apply() {
        if controlStripRunning, !statusCallbackRegistered {
            statusCallbackRegistered = TouchBarPrivateAPI.registerStatusChange {
                DispatchQueue.main.async { TouchBarAvailability.shared.apply() }
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

    /// `debug/state` 里的一段:此刻的结论和用来判的 ControlStrip 进程。
    var debugState: [String: Any] {
        ["present": isPresent, "hasEscapeKey": hasEscapeKey, "controlStripRunning": controlStripRunning,
         "controlStripPID": controlStripPID.map { Int($0) as Any } ?? NSNull()]
    }
}
