import CoreGraphics
import Foundation

/// 菜单栏面板「声音」格上的滚动调音量:指针停在格子上,滚鼠标滚轮或触控板两指上下滑调系统输出音量。
///
/// 判法跟灵动岛卡片上的上下滑同一套(`NotchScrollGesture`):方向按手指算(自然滚动开不开一样,往上调大),鼠标滚轮一格
/// 调 `NotchScrollGesture.wheelStep`,触控板和平滑滚动的鼠标按位移 `NotchScrollGesture.volumePerPoint` 连续调,惯性余势不算,
/// 一次滑动先认方向、认成左右滑的那一次整段不调。这一格上左右滑什么都不做(不切歌)。
///
/// 没有阶段的滚动(鼠标滚轮)只在指针在格子出现之后动过时才认(`pointerMoved`):格子出现在不动的指针下面时(快捷键开面板、
/// 从背面翻回来),手上还在滚下层 App 的那几格不该落到这里调音量。触控板一次滑动从手指放上去开始,不受这条限制。
public struct PanelVolumeScroll: Equatable, Sendable {
    /// 指针挪开多远才算「动过」(pt)。同一个位置两种读法(事件自带的位置、`NSEvent.mouseLocation`)会差零点几。
    public static let pointerMoveTolerance: Double = 0.5

    private var gesture = NotchScrollGesture()

    public init() {}

    /// 喂一个滚动事件,返回系统音量该加减多少(0...1 的量纲),nil = 这一下不调。参数同 `NotchScrollGesture.feed`。
    public mutating func feed(dx: Double, dy: Double, phase: NotchScrollGesture.Phase, invertedFromDevice: Bool,
                              preciseDeltas: Bool, pointerMoved: Bool) -> Float? {
        if phase == .none, !pointerMoved { return nil }
        guard case .volume(let delta)? = gesture.feed(dx: dx, dy: dy, phase: phase, invertedFromDevice: invertedFromDevice,
                                                      preciseDeltas: preciseDeltas) else { return nil }
        return delta
    }

    /// 这一次滑动作废(格子此刻不接滚动:编辑布局、设备调不了音量),等下一个 `.began` 再认。
    public mutating func invalidate() {
        gesture.invalidate()
    }

    /// 指针从格子出现时的位置 `appearedAt` 挪到 `now` 算不算动过。`appearedAt` 为 nil(没记下)按动过算。
    public static func pointerMoved(from appearedAt: CGPoint?, to now: CGPoint) -> Bool {
        guard let appearedAt else { return true }
        return hypot(Double(now.x - appearedAt.x), Double(now.y - appearedAt.y)) > pointerMoveTolerance
    }
}

/// 系统音量加减一步之后的值:落在 0...1 里;调大时顺手解除静音,调小不碰静音。灵动岛手势、面板滚动都经
/// `VolumeMonitor.adjustSystemVolume` 用它。
public enum SystemVolumeStep {
    public static func apply(current: Float, muted: Bool, delta: Float) -> (volume: Float, unmute: Bool) {
        (min(1, max(0, current + delta)), muted && delta > 0)
    }
}
