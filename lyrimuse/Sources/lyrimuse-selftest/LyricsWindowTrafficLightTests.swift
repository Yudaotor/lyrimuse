import AppKit
import LyrimuseCore

/// 歌词窗口红绿灯的位置与显隐(07 章决策 203):切任何一颗的 `isHidden`,系统当场把三颗拉回默认位,
/// `TitlebarButtonPlacement.setHidden` 要在同一拍里摆回目标位。窗口不上屏(`defer: true`),不碰窗口服务器。
@MainActor
func checkLyricsWindowTrafficLights() {
    print("\n== 歌词窗口红绿灯位置 ==")
    let types = TitlebarButtonPlacement.buttonTypes
    func origins(_ window: NSWindow) -> [CGPoint] { types.compactMap { window.standardWindowButton($0)?.frame.origin } }
    func same(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0.x - $1.x) < 0.5 && abs($0.y - $1.y) < 0.5 }
    }

    // 几何:真的离屏窗口。
    do {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let systemDefault = origins(window)
        let placement = TitlebarButtonPlacement(closeCenterX: 26, topMargin: 19)
        placement.place(in: window)
        let placed = origins(window)
        if let close = window.standardWindowButton(.closeButton), let superview = close.superview, placed.count == 3 {
            expectEqual(abs(close.frame.midX - 26) < 0.5 && abs(superview.bounds.height - close.frame.maxY - 19) < 0.5, true,
                        "红绿灯位置: 关闭键中心 x 26、顶边离父视图顶 19")
            let dx = placed[0].x - systemDefault[0].x
            expectEqual(abs(dx) > 0.5 && zip(placed, systemDefault).allSatisfy { abs(($0.x - $1.x) - dx) < 0.5 }, true,
                        "红绿灯位置: 整组跟着关闭键平移,保留系统自己的间距")
        } else {
            expectEqual(false, true, "红绿灯位置: 离屏窗口有三颗标准按钮")
        }
    }

    // 显隐:selftest 按旧 SDK 链接,AppKit 走兼容模式、切显隐不重排,这里用一扇会重排的窗口模拟系统那一下
    // (macOS 26 起 `-[_NSThemeWidget setHidden:]` → `_tileTitlebarAndRedisplay:` 把三颗拉回默认位)。
    do {
        let window = RetilingTitlebarWindow()
        let placement = TitlebarButtonPlacement(closeCenterX: 26, topMargin: 19)
        placement.place(in: window)
        let placed = origins(window)
        expectEqual(same(placed, window.defaults), false, "红绿灯显隐: 摆过之后离开了默认位")
        window.standardWindowButton(.zoomButton)?.isHidden = true
        expectEqual(same(origins(window), window.defaults), true, "红绿灯显隐: 前提 —— 模拟窗口切显隐就把三颗拉回默认位")
        window.standardWindowButton(.zoomButton)?.isHidden = false
        placement.place(in: window)

        expectEqual(placement.setHidden(in: window) { _ in true }, true, "红绿灯显隐: 全藏报有翻")
        expectEqual(same(origins(window), placed), true, "红绿灯显隐: 全藏之后还在目标位")
        placement.setHidden(in: window) { _ in false }
        expectEqual(same(origins(window), placed) && types.allSatisfy { window.standardWindowButton($0)?.isHidden == false }, true,
                    "红绿灯显隐: 露出来那一刻就在目标位,不等下一次 didUpdate")
        placement.setHidden(in: window) { $0 == .zoomButton }
        expectEqual(same(origins(window), placed) && window.standardWindowButton(.zoomButton)?.isHidden == true, true,
                    "红绿灯显隐: 只藏绿键(迷你)时另两颗也不动")
        let retiles = window.retileCount
        expectEqual(placement.setHidden(in: window) { $0 == .zoomButton } == false && window.retileCount == retiles, true,
                    "红绿灯显隐: 显隐没变不写")
        placement.setHidden(in: window, reposition: false) { _ in false }
        expectEqual(same(origins(window), window.defaults), true, "红绿灯显隐: 原生全屏(reposition: false)只设显隐、不摆")
        placement.place(in: window)
        expectEqual(same(origins(window), placed), true, "红绿灯位置: 再摆一次回到同一个目标位(默认位只在第一次记)")
    }

    // 兜底:别处触发的重排由 track 排一次摆回。
    do {
        let window = RetilingTitlebarWindow()
        var queued: [@Sendable () -> Void] = []
        var fullScreen = false
        let placement = TitlebarButtonPlacement(closeCenterX: 26, topMargin: 19, schedule: { queued.append($0) })
        placement.place(in: window)
        let placed = origins(window)
        placement.track(window) { !fullScreen }
        expectEqual(queued.isEmpty, true, "红绿灯兜底: 挂上时不排")
        window.retile()
        expectEqual(same(origins(window), window.defaults) && queued.count == 1, true,
                    "红绿灯兜底: 被系统挪走时不当场摆(系统正排到一半),排一次")
        window.retile()
        expectEqual(queued.count, 1, "红绿灯兜底: 同一拍里被挪几次只排一次")
        queued.forEach { $0() }
        queued.removeAll()
        expectEqual(same(origins(window), placed), true, "红绿灯兜底: 排到的那一拍摆回目标位")
        placement.setHidden(in: window) { _ in true }
        placement.setHidden(in: window) { _ in false }
        placement.place(in: window)
        expectEqual(queued.isEmpty && same(origins(window), placed), true, "红绿灯兜底: 自己设显隐、摆位不算被挪走,不排")
        fullScreen = true
        window.retile()
        queued.forEach { $0() }
        queued.removeAll()
        expectEqual(same(origins(window), window.defaults), true, "红绿灯兜底: 原生全屏里不摆")
        fullScreen = false
        let other = RetilingTitlebarWindow()
        placement.track(other) { true }
        placement.place(in: other)
        window.retile()
        expectEqual(queued.isEmpty, true, "红绿灯兜底: 换了窗之后不再管旧窗")
        other.retile()
        expectEqual(queued.count, 1, "红绿灯兜底: 换了窗之后盯新的那扇")
        queued.forEach { $0() }
        expectEqual(same(origins(other), placed), true, "红绿灯兜底: 新窗被挪走也摆回去")
    }

    let lwv = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("lyrimuse/UI/LyricsWindowView.swift"), encoding: .utf8)) ?? ""
    expectEqual(sourceHas(lwv, "trafficLights.setHidden(in: window, reposition: !isNativeFullScreen) { type in"), true,
                "红绿灯显隐(契约): 歌词窗口的显隐走 TitlebarButtonPlacement.setHidden")
    expectEqual(lwv.isEmpty == false && !sourceBytes(lwv, contain: ".isHidden = hide"), true,
                "红绿灯显隐(契约): 歌词窗口不直接写红绿灯的 isHidden")
    expectEqual(sourceHas(lwv, "self?.clearNativeFullScreen()\n"
                    + "                // 出全屏时系统重排标题栏、把按钮拉回默认位,当场摆回去,不等下一次 didUpdate。\n"
                    + "                if let win = self?.window { self?.enforceTrafficLightPosition(win) }"), true,
                "红绿灯位置(契约): 出原生全屏当场摆回去")
    expectEqual(sourceHas(lwv, "trafficLights.track(window) { [weak self] in"), true,
                "红绿灯位置(契约): 窗口挂上来时盯着按钮,别处触发的重排也摆回去")
}

/// 模拟 macOS 26 的标题栏:三颗按钮任何一颗切 `isHidden`,当场把三颗拉回默认位。
@MainActor
private final class RetilingTitlebarWindow: NSWindow {
    let defaults: [CGPoint] = [CGPoint(x: 9, y: 9), CGPoint(x: 32, y: 9), CGPoint(x: 55, y: 9)]
    private(set) var retileCount = 0
    private let titlebar = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 32))
    private var buttons: [NSWindow.ButtonType.RawValue: RetilingButton] = [:]

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                   backing: .buffered, defer: true)
        for (i, type) in TitlebarButtonPlacement.buttonTypes.enumerated() {
            let button = RetilingButton(frame: NSRect(origin: defaults[i], size: CGSize(width: 14, height: 16)))
            button.onHiddenChange = { [weak self] in self?.retile() }
            titlebar.addSubview(button)
            buttons[type.rawValue] = button
        }
    }

    override func standardWindowButton(_ b: NSWindow.ButtonType) -> NSButton? { buttons[b.rawValue] }

    /// 系统重排一次:三颗拉回默认位(切显隐时自动调,也可从外面调,当作改标题、开始被录制这类别处触发的重排)。
    func retile() {
        retileCount += 1
        for (i, type) in TitlebarButtonPlacement.buttonTypes.enumerated() {
            buttons[type.rawValue]?.setFrameOrigin(defaults[i])
        }
    }
}

private final class RetilingButton: NSButton {
    var onHiddenChange: (() -> Void)?
    override var isHidden: Bool {
        didSet { if isHidden != oldValue { onHiddenChange?() } }
    }
}
