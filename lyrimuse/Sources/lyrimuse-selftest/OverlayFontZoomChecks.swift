import AppKit
import LyrimuseCore

/// 悬浮歌词上按住 ⌘ 滚动调字号(`OverlayFontZoom`,04 章决策 62)的纯计算部分。在 `runOverlayTests` 里调用。
@MainActor
func overlayFontZoomChecks() {
    typealias Z = OverlayFontZoom
    expectEqual(Z.modifier, .command, "调字号: 按住 ⌘")
    // 方向:滚轮往前推、手指往上 = 放大,自然滚动开着时系统给的量是反的。
    expectEqual(Z.deviceDeltaY(3, invertedFromDevice: false), 3, "调字号: 没开自然滚动,量照原样")
    expectEqual(Z.deviceDeltaY(-3, invertedFromDevice: true), 3, "调字号: 开着自然滚动,翻回设备方向")

    // 鼠标滚轮:一格一档,不看量多大。
    var wheel = Z()
    expectEqual(wheel.steps(scrollDeltaY: 1, precise: false, momentum: false), 1, "调字号: 滚轮往前一格放大一档")
    expectEqual(wheel.steps(scrollDeltaY: -6.5, precise: false, momentum: false), -1, "调字号: 滚轮快速一格也只算一档")
    expectEqual(wheel.steps(scrollDeltaY: 0, precise: false, momentum: false), 0, "调字号: 量为 0 不算")

    // 触控板:攒够 pointsPerStep 才算一档,余数留着。
    var pad = Z()
    expectEqual(pad.steps(scrollDeltaY: 10, precise: true, momentum: false), 0, "调字号: 触控板 10pt 还不到一档")
    expectEqual(pad.steps(scrollDeltaY: 10, precise: true, momentum: false), 0, "调字号: 攒到 20pt 还不到一档")
    expectEqual(pad.steps(scrollDeltaY: 10, precise: true, momentum: false), 1, "调字号: 攒到 30pt 算一档")
    expectEqual(pad.steps(scrollDeltaY: 18, precise: true, momentum: false), 1, "调字号: 余下 6pt 接着攒")
    expectEqual(pad.steps(scrollDeltaY: 60, precise: true, momentum: false), 2, "调字号: 一次滚得多算几档")
    expectEqual(pad.steps(scrollDeltaY: 200, precise: true, momentum: true), 0, "调字号: 松手后的惯性滚动不算")
    expectEqual(pad.steps(scrollDeltaY: -20, precise: true, momentum: false), 0, "调字号: 换方向从零攒起,攒下的正数不抵掉")
    expectEqual(pad.steps(scrollDeltaY: -10, precise: true, momentum: false), -1, "调字号: 往回攒够一档缩小")
    pad.reset()
    expectEqual(pad.steps(scrollDeltaY: 20, precise: true, momentum: false), 0, "调字号: 重置后从零攒起")
}
