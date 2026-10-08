import AppKit
import CoreGraphics

/// 悬浮歌词把接住了、又没拖起来的那一下单击补发给下层窗口(见 04 章决策 55)。
///
/// 「拖动前先长按」关着时,指针停在歌词文字上这扇窗就收回点击穿透,按下落在它身上:不收回的话,按住拖动时
/// 按下和整段拖动都会派给下层窗口(04 章决策 44)。所以按下时还分不出是单击还是拖动:拖出 `dragStartDistance`
/// 才开始拖窗口,不到就松手算单击,把这一下原样发回系统事件流,点击穿透还原之后由系统派给下层。这里是其中不碰
/// 窗口和事件派发的几样。
public enum OverlayClickReplay {
    /// 补发的事件在 `eventSourceUserData` 里带这个值,鼠标监听器认出来就跳过,不当成用户又按了一下。
    public static let eventTag: Int64 = 0x4C59_524D
    /// 按住歌词拖出这么远(pt)才算拖动、开始拖窗口;不到这么远就松手算单击。
    public static let dragStartDistance: CGFloat = 4
    /// 补发之后最多等这么久再恢复接住歌词文字:补发的松开一直没回到监听器(事件被丢掉)时不一直放着。
    public static let landingTimeout: TimeInterval = 0.5

    /// 从按下的位置挪到 `now` 算不算拖动。
    public static func isDrag(from start: CGPoint, to now: CGPoint) -> Bool {
        hypot(now.x - start.x, now.y - start.y) > dragStartDistance
    }

    /// AppKit 屏幕坐标(主屏左下原点、y 向上)换成鼠标事件用的全局坐标(主屏左上原点、y 向下)。
    public static func eventLocation(fromScreen point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// 按下时的修饰键原样带到补发的事件上(两边与设备无关的那几位取值相同)。
    public static func eventFlags(_ modifiers: NSEvent.ModifierFlags) -> CGEventFlags {
        CGEventFlags(rawValue: UInt64(modifiers.intersection(.deviceIndependentFlagsMask).rawValue))
    }

    /// 补发的一次按下 + 松开:按下在按下时的位置、松开在松开时的位置(都是全局坐标),修饰键、连击次数照原样,
    /// 都带 `eventTag`。只造不发。
    public static func events(button: CGMouseButton, down: CGPoint, up: CGPoint, clickCount: Int,
                              flags: CGEventFlags, source: CGEventSource?) -> [CGEvent] {
        let types: (down: CGEventType, up: CGEventType) = button == .right
            ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        return [(types.down, down), (types.up, up)].compactMap { type, location in
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: location, mouseButton: button) else { return nil }
            event.flags = flags
            event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
            event.setIntegerValueField(.eventSourceUserData, value: eventTag)
            return event
        }
    }

    /// 监听器收到的这一下是不是补发出去的。
    public static func isReplayed(_ event: CGEvent?) -> Bool {
        event?.getIntegerValueField(.eventSourceUserData) == eventTag
    }
}
