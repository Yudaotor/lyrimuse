import AppKit
import LyrimuseCore

/// 悬浮歌词补发单击(`OverlayClickReplay`,04 章决策 55)的纯计算部分。在 `runOverlayTests` 里调用。
@MainActor
func overlayClickReplayChecks() {
    let R = OverlayClickReplay.self
    // 拖出多远才算拖动:4pt 以内(含)是单击,按下时手抖一下不该把窗口拖走。
    expectEqual(R.isDrag(from: .zero, to: CGPoint(x: 4, y: 0)), false, "补发单击: 挪 4pt 还算单击")
    expectEqual(R.isDrag(from: .zero, to: CGPoint(x: 4.1, y: 0)), true, "补发单击: 挪过 4pt 算拖动")
    expectEqual(R.isDrag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 13, y: 13)), true,
                "补发单击: 斜着挪按直线距离算(4.24pt)")
    // 坐标:AppKit 主屏左下原点、y 向上 → 鼠标事件用的主屏左上原点、y 向下。
    expectEqual(R.eventLocation(fromScreen: CGPoint(x: 100, y: 800), primaryScreenHeight: 956),
                CGPoint(x: 100, y: 156), "补发单击: 纵坐标按主屏高度翻过来")
    expectEqual(R.eventLocation(fromScreen: CGPoint(x: -300, y: 1200), primaryScreenHeight: 956),
                CGPoint(x: -300, y: -244), "补发单击: 主屏左边、上面的副屏照样换算")
    // 修饰键原样带过去,只留与设备无关的几位。
    let flags = R.eventFlags([.command, .shift, NSEvent.ModifierFlags(rawValue: 0x1)])
    expectEqual(flags.contains(.maskCommand) && flags.contains(.maskShift) && !flags.contains(.maskAlternate), true,
                "补发单击: ⌘⇧ 原样带上")
    expectEqual(flags.rawValue & 0xFFFF, UInt64(0), "补发单击: 设备相关的低位不带")
    // 造出来的一对事件。
    let left = R.events(button: .left, down: CGPoint(x: 10, y: 20), up: CGPoint(x: 12, y: 21), clickCount: 2,
                        flags: .maskCommand, source: nil)
    expectEqual(left.map(\.type), [.leftMouseDown, .leftMouseUp], "补发单击: 左键一按一松")
    expectEqual(left.map(\.location), [CGPoint(x: 10, y: 20), CGPoint(x: 12, y: 21)],
                "补发单击: 按下在按下处、松开在松开处")
    expectEqual(left.map { $0.getIntegerValueField(.mouseEventClickState) }, [2, 2],
                "补发单击: 连击次数照原样,双击补发过去还是双击")
    expectEqual(left.allSatisfy { $0.flags.contains(.maskCommand) }, true, "补发单击: 修饰键带在两下上")
    expectEqual(left.allSatisfy { R.isReplayed($0) }, true, "补发单击: 两下都带记号,监听器认得出")
    let right = R.events(button: .right, down: .zero, up: .zero, clickCount: 0, flags: [], source: nil)
    expectEqual(right.map(\.type), [.rightMouseDown, .rightMouseUp], "补发单击: 右键一按一松")
    expectEqual(right.map { $0.getIntegerValueField(.mouseEventClickState) }, [1, 1], "补发单击: 连击次数至少记 1")
    let userClick = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero,
                            mouseButton: .left)
    expectEqual(R.isReplayed(userClick), false, "补发单击: 用户自己的点击不带记号")
    expectEqual(R.isReplayed(nil), false, "补发单击: 没有底层事件时不算")
}
