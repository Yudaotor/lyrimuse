import Foundation
import LyrimuseCore

/// 迷你窗「悬浮淡化」(07 章决策 118):判据、跟悬浮歌词同一组数和同一个标题 / 图标、接线。
func checkLyricsWindowHoverFade() {
    print("\n== 迷你窗悬浮淡化 ==")
    typealias F = LyricsWindowMiniHoverFade
    expectEqual(F.shouldDim(enabled: true, isMini: true, hovered: true, heldOpenByClick: false), true,
                "迷你悬浮淡化: 开着、迷你、指针在窗里就淡")
    expectEqual(F.shouldDim(enabled: false, isMini: true, hovered: true, heldOpenByClick: false), false,
                "迷你悬浮淡化: 开关关着不淡")
    expectEqual(F.shouldDim(enabled: true, isMini: false, hovered: true, heldOpenByClick: false), false,
                "迷你悬浮淡化: 完整尺寸不淡")
    expectEqual(F.shouldDim(enabled: true, isMini: true, hovered: false, heldOpenByClick: false), false,
                "迷你悬浮淡化: 指针不在窗里不淡")
    expectEqual(F.shouldDim(enabled: true, isMini: true, hovered: true, heldOpenByClick: true), false,
                "迷你悬浮淡化: 这次停留里按过鼠标就恢复")

    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    func source(_ path: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }
    // 跟悬浮歌词「悬浮淡化」同一组数:那边改了,这边跟着改。
    let overlayView = source("lyrimuse/UI/LyricsOverlayView.swift")
    expectEqual(sourceBytes(overlayView, contain: "!overlayController.isAdjustingWidth ? 0.15 : 1") && F.dimmedAlpha == 0.15, true,
                "迷你悬浮淡化: 淡到的透明度跟悬浮歌词一样")
    expectEqual(sourceBytes(overlayView, contain: "duration: hoverFadeOpacity < 1 ? 0.12 : 0.18")
                && F.dimSeconds == 0.12 && F.restoreSeconds == 0.18, true,
                "迷你悬浮淡化: 淡下去 / 回来的快慢跟悬浮歌词一样")

    let fade = source("lyrimuse/UI/LyricsWindowHoverFade.swift")
    let window = source("lyrimuse/UI/LyricsWindowView.swift")
    let appSettings = source("lyrimuse/Settings/AppSettings.swift")
    let settingsView = source("lyrimuse/SettingsView.swift")
    expectEqual(sourceBytes(fade, contain: "[.mouseEnteredAndExited, .activeAlways, .inVisibleRect]"), true,
                "迷你悬浮淡化: 跟踪区带 .activeAlways,Lyrimuse 不在前台也报")
    expectEqual(sourceBytes(fade, contain: "override func hitTest(_ point: NSPoint) -> NSView? { nil }"), true,
                "迷你悬浮淡化: 跟踪视图不接点击,点按照常落到下面的控件上")
    expectEqual(sourceBytes(fade, contain: "window.animator().alphaValue = target"), true,
                "迷你悬浮淡化: 动的是整扇窗的 alphaValue")
    expectEqual(window.components(separatedBy: ".overlay { miniHoverTracker }").count - 1, 1,
                "迷你悬浮淡化: 挂在整个迷你布局上(进窗就算),不只挂歌词那块")
    expectEqual(sourceBytes(window, contain: "MiniWindowHoverTracker { windowController.setMiniHovered($0) }\n                .ignoresSafeArea()"),
                true, "迷你悬浮淡化: 跟踪铺进标题栏那一条")
    expectEqual(sourceBytes(window, contain: "if !previewMode {\n            MiniWindowHoverTracker {"), true,
                "迷你悬浮淡化: 设置页预览里不挂")
    expectEqual(sourceBytes(window, contain: "hoverFade.attach(window, isMini: $isMini.eraseToAnyPublisher())")
                && sourceBytes(window, contain: "self?.hoverFade.windowClosed()"), true,
                "迷你悬浮淡化: 窗口 attach 时接上、跟着进出迷你,关窗复位")
    expectEqual(sourceBytes(window, contain: "lyricsWindowMiniFadeOnHover"), false,
                "迷你悬浮淡化: 开关不在窗口里(在设置页「行为」)")
    expectEqual(sourceBytes(settingsView, contain: "SettingsRow(icon: \"cursorarrow.motionlines\", title: L10n.t(\"悬浮淡化\")) {\n"
                            + "            Toggle(\"\", isOn: $settings.lyricsWindowMiniFadeOnHover)"), true,
                "迷你悬浮淡化: 设置页迷你「行为」摆这颗开关")
    let overlayBehavior = source("lyrimuse/UI/OverlayBehaviorSettingsRows.swift")
    expectEqual(sourceBytes(overlayBehavior, contain: "case .fadeOnHover: return \"cursorarrow.motionlines\"")
                && sourceBytes(overlayBehavior, contain: "case .fadeOnHover: return L10n.t(\"悬浮淡化\")"), true,
                "迷你悬浮淡化: 标题、图标跟悬浮歌词「悬浮淡化」那颗一样")
    expectEqual(sourceBytes(settingsView, contain: "s.lyricsWindowMiniFadeOnHover = false"), true,
                "迷你悬浮淡化: 迷你「重置」恢复成关")
    expectEqual(sourceBytes(appSettings, contain: "lyricsWindowMiniFadeOnHover = (defaults.object(forKey: Keys.lyricsWindowMiniFadeOnHover) as? Bool) ?? false"),
                true, "迷你悬浮淡化: 默认关,同悬浮歌词「悬浮淡化」")
}

/// 歌词窗口完整布局「闲置隐藏」:判据 + 接线。
@MainActor
func checkLyricsWindowChromeIdle() {
    print("\n== 歌词窗口闲置隐藏 ==")
    typealias C = LyricsWindowChromeIdle
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    var s = C.State()
    expectEqual(C.isVisible(s, now: t0), false, "闲置隐藏: 指针不在窗里、没刚打开,收着")
    s.revealUntil = t0.addingTimeInterval(C.idleSeconds)
    expectEqual(C.isVisible(s, now: t0.addingTimeInterval(2.9)), true, "闲置隐藏: 刚打开先露 3 秒,指针不在窗里也露")
    expectEqual(C.isVisible(s, now: t0.addingTimeInterval(3)), false, "闲置隐藏: 刚打开那 3 秒过了就收")
    expectEqual(C.nextCheck(s, now: t0), t0.addingTimeInterval(3), "闲置隐藏: 刚打开那段的到期时刻")
    s.pointerInside = true
    s.lastActivity = t0.addingTimeInterval(2)
    expectEqual(C.nextCheck(s, now: t0), t0.addingTimeInterval(5), "闲置隐藏: 两段都在时取晚到期的那个")
    expectEqual(C.isVisible(s, now: t0.addingTimeInterval(4.9)), true, "闲置隐藏: 指针动过后 3 秒内露着")
    expectEqual(C.isVisible(s, now: t0.addingTimeInterval(5)), false, "闲置隐藏: 指针在窗里静止 3 秒收")
    s.held = true
    expectEqual(C.isVisible(s, now: t0.addingTimeInterval(100)), true, "闲置隐藏: 指针停在按钮上 / 面板开着不收")
    expectEqual(C.nextCheck(s, now: t0.addingTimeInterval(100)), nil, "闲置隐藏: 按住不收时不排下一次检查")
    s.held = false
    s.pointerInside = false
    expectEqual(C.isVisible(s, now: t0.addingTimeInterval(4)), false, "闲置隐藏: 指针离开窗口立刻收")
    s.mouseDown = true
    expectEqual(C.isVisible(s, now: t0.addingTimeInterval(100)), true, "闲置隐藏: 按着鼠标(拖音量拖出窗外)不收")
    s.mouseDown = false
    s.voiceOver = true
    expectEqual(C.isVisible(s, now: t0.addingTimeInterval(100)), true, "闲置隐藏: 开着旁白不收")
    s.voiceOver = false
    expectEqual(C.nextCheck(s, now: t0.addingTimeInterval(100)), nil, "闲置隐藏: 收着时不排检查")

    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    func source(_ path: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }
    let window = source("lyrimuse/UI/LyricsWindowView.swift")
    let fade = source("lyrimuse/UI/LyricsWindowChromeFade.swift")
    expectEqual(sourceBytes(fade, contain: "[.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect]"), true,
                "闲置隐藏: 跟踪区报指针移动、带 .activeAlways(窗口常放在副屏、焦点在别的 App)")
    expectEqual(sourceBytes(fade, contain: "guard let frameView = window.contentView?.superview ?? window.contentView else { return }"), true,
                "闲置隐藏: 跟踪区挂在整扇窗最外层的框架上,标题栏那一条(左上那组按钮所在)也算在窗里")
    expectEqual(sourceBytes(fade, contain: "if !inside, let window, window.isVisible, window.frame.contains(NSEvent.mouseLocation) { return }"), true,
                "闲置隐藏: 报离开时按真实指针位置再核一次")
    for group in ["volume", "window", "lyrics", "scroll"] {
        expectEqual(window.components(separatedBy: ".lyricsWindowChromeFade(windowController.chromeFade, group: \"\(group)\")").count - 1, 1,
                    "闲置隐藏: \(group) 那一组跟着收")
    }
    expectEqual(sourceBytes(window, contain: "            chromeFade: windowController.chromeFade,\n            nowMs:"), true,
                "闲置隐藏: 图层版歌词列表的指示条也跟着收(SwiftUI 版那一份见上面 scroll 那组)")
    expectEqual(sourceBytes(source("lyrimuse/UI/LyricsLayerList.swift"), contain: "view.bindChromeFade(chromeFade)"), true,
                "闲置隐藏: 图层版歌词列表接上淡入淡出")
    expectEqual(sourceBytes(window, contain: "let hidden = isActive || !window.isKeyWindow || (chromeHidden && !isMini)"), true,
                "闲置隐藏: 红绿灯跟着收,迷你不管")
    expectEqual(sourceBytes(window, contain: "chromeFade.attach(window, isMini: $isMini.eraseToAnyPublisher())")
                && sourceBytes(window, contain: "self?.chromeFade.windowClosed()")
                && sourceBytes(window, contain: "MainActor.assumeIsolated { chromeFade.reveal() }"), true,
                "闲置隐藏: attach 接上、关窗复位、同一扇窗再打开先露 3 秒")
}
