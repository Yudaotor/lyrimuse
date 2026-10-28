import ApplicationServices
import Foundation

/// Pine Player 的音量:主窗口里那根取值 0~1 的 `AXSlider`(另一根是进度条,最大值是这首的整秒时长,`PinePlayhead.ProgressBar`)。
/// 读它的值、写它的值都直接改到 Pine 的音量(写 0.5 之后按一下菜单「提高音量」读回 0.505);菜单「提高 / 减小音量」一档只差
/// 0.005,不用它。窗口隐藏、没在放时照样读写。要辅助功能权限。会阻塞跨进程调用,别在主线程调。
public enum PineVolume {
    /// 一根滑块的取值范围和当前值。
    public struct Slider: Equatable, Sendable {
        public var min: Double
        public var max: Double
        public var value: Double

        public init(min: Double, max: Double, value: Double) {
            self.min = min
            self.max = max
            self.value = value
        }
    }

    /// 几根滑块里哪一根是音量:取值范围正好 0~1 的那一根;没有或不止一根(这首恰好 1 秒长时进度条也是 0~1)为 nil。纯函数,
    /// selftest 覆盖。
    public static func volumeIndex(_ sliders: [Slider]) -> Int? {
        let hits = sliders.indices.filter { sliders[$0].min == 0 && sliders[$0].max == 1 }
        return hits.count == 1 ? hits[0] : nil
    }

    /// 0~1 的滑块值 → 0~100 的音量(四舍五入,越界夹住)。纯函数,selftest 覆盖。
    public static func percent(_ value: Double) -> Int {
        Int((Swift.min(1, Swift.max(0, value)) * 100).rounded())
    }

    /// 当前音量 0~100;Pine 没在跑、没授权、找不到那根滑块为 nil。
    public static func read() -> Int? {
        guard let slider = volumeSlider(),
              let value = (attribute(slider, kAXValueAttribute) as? NSNumber)?.doubleValue else { return nil }
        return percent(value)
    }

    /// 设成 0~100(越界夹住)。写成了为 true。
    public static func set(_ percent: Int) -> Bool {
        guard let slider = volumeSlider() else { return false }
        let value = Double(Swift.min(100, Swift.max(0, percent))) / 100
        return AXUIElementSetAttributeValue(slider, kAXValueAttribute as CFString, value as CFNumber) == .success
    }

    /// 跨进程查询超时,App 元素和往下取到的每个元素都设。
    static let axTimeout: Float = 0.25

    private static func volumeSlider() -> AXUIElement? {
        guard AXIsProcessTrusted(), let pid = PlayerProcess.pid(bundleID: PinePlayerInfo.bundleID) else { return nil }
        let app = MenuBarAX.timed(AXUIElementCreateApplication(pid), timeout: axTimeout)
        var found: [(element: AXUIElement, slider: Slider)] = []
        for window in MenuBarAX.children(app, attribute: kAXWindowsAttribute, timeout: axTimeout) {
            for child in MenuBarAX.children(window, timeout: axTimeout) {
                for element in [child] + MenuBarAX.children(child, timeout: axTimeout) {
                    guard (attribute(element, kAXRoleAttribute) as? String) == kAXSliderRole,
                          let min = (attribute(element, kAXMinValueAttribute) as? NSNumber)?.doubleValue,
                          let max = (attribute(element, kAXMaxValueAttribute) as? NSNumber)?.doubleValue,
                          let value = (attribute(element, kAXValueAttribute) as? NSNumber)?.doubleValue else { continue }
                    found.append((element, Slider(min: min, max: max, value: value)))
                }
            }
        }
        return volumeIndex(found.map(\.slider)).map { found[$0].element }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
