import ApplicationServices
import Foundation

/// reAMP 的音量:它窗口里那根取值 0~100 的 `AXSlider`(没有描述;均衡器那十一根是 0~63,左右声道那根是 −100~100)。
/// 读它的值、写它的值都直接改到 reAMP 的音量;窗口被「Hide Reamp」藏起来时照样读写。窗口在辅助功能树里的序号每次启动都不一样,
/// 按取值范围认。要辅助功能权限。会阻塞跨进程调用,别在主线程调。见 02 章决策 189。
public enum ReampVolume {
    /// 几根滑块里哪一根是音量:取值范围正好 0~100 的那一根;没有或不止一根为 nil。纯函数,selftest 覆盖。
    public static func volumeIndex(_ sliders: [PineVolume.Slider]) -> Int? {
        let hits = sliders.indices.filter { sliders[$0].min == 0 && sliders[$0].max == 100 }
        return hits.count == 1 ? hits[0] : nil
    }

    /// 滑块值 → 0~100 的音量(四舍五入,越界夹住)。纯函数,selftest 覆盖。
    public static func percent(_ value: Double) -> Int {
        Int(Swift.min(100, Swift.max(0, value)).rounded())
    }

    /// 当前音量 0~100;reAMP 没在跑、没授权、找不到那根滑块为 nil。
    public static func read() -> Int? {
        guard let slider = volumeSlider(),
              let value = (attribute(slider, kAXValueAttribute) as? NSNumber)?.doubleValue else { return nil }
        return percent(value)
    }

    /// 设成 0~100(越界夹住)。写成了为 true。
    public static func set(_ percent: Int) -> Bool {
        guard let slider = volumeSlider() else { return false }
        let value = Double(Swift.min(100, Swift.max(0, percent)))
        return AXUIElementSetAttributeValue(slider, kAXValueAttribute as CFString, value as CFNumber) == .success
    }

    private static func volumeSlider() -> AXUIElement? {
        guard AXIsProcessTrusted(), let pid = PlayerProcess.pid(bundleID: PlaybackPlayer.reamp.bundleIdentifier) else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var found: [(element: AXUIElement, slider: PineVolume.Slider)] = []
        for window in children(app, kAXWindowsAttribute) {
            for child in children(window, kAXChildrenAttribute) {
                for element in [child] + children(child, kAXChildrenAttribute) {
                    guard (attribute(element, kAXRoleAttribute) as? String) == kAXSliderRole,
                          let min = (attribute(element, kAXMinValueAttribute) as? NSNumber)?.doubleValue,
                          let max = (attribute(element, kAXMaxValueAttribute) as? NSNumber)?.doubleValue,
                          let value = (attribute(element, kAXValueAttribute) as? NSNumber)?.doubleValue else { continue }
                    found.append((element, PineVolume.Slider(min: min, max: max, value: value)))
                }
            }
        }
        return volumeIndex(found.map(\.slider)).map { found[$0].element }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func children(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        (attribute(element, name) as? [AXUIElement]) ?? []
    }
}
