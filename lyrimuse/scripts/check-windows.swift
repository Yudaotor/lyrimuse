#!/usr/bin/env swift
//
// 只读地问一句"Lyrimuse 现在到底显示着什么窗口"。
//
//   swift lyrimuse/scripts/check-windows.swift              # 列出全部窗口
//   swift lyrimuse/scripts/check-windows.swift --require-overlay
//   swift lyrimuse/scripts/check-windows.swift --owner Music
//   swift lyrimuse/scripts/check-windows.swift --menubar-items   # 各 App 的菜单栏项位置(要辅助功能权限)
//
// 为什么要有这个脚本:验证"悬浮歌词到底有没有画出来"以前只有两条路 —— 肉眼看,或者用
// AppleScript 去驱动界面。后者在这个项目上出过两次事故(盲发 Cmd+W 关掉了用户正在用的
// 别的 App;为验证列宽对着窗口连点几十次,触发了"清空全部"把歌词缓存清掉了)。这个脚本
// **只读** CGWindowList:不点击、不发按键、不激活、不改任何状态,拿到的却足以回答绝大多数
// "它是不是真的显示出来了"的问题。
//
// 配合按窗口 ID 截图更好用 —— `screencapture -l <id>` 只抓那一个窗口,不会连带把别的
// 窗口(比如聊天软件)拍进去:
//
//   swift lyrimuse/scripts/check-windows.swift | grep overlay
//   screencapture -x -o -l <那个 id> /tmp/shot.png
//
// 这里印的 bounds 是 CGWindowList 的读数,**不等于 NSWindow.frame**:窗口在非主显示器
// 上时会有系统级的缩放/取整偏差。实测(本机外接 LS27B61x,NSScreen frame
// (-526,956,2560,1440),1x):真实 frame 恰好 (849,1082,900,120) 的窗口在这里被报成
// x=858 y=-245 w=882 h=118 —— 宽度差 18pt、x 差 9pt(等于宽度差的一半,看起来极像一次
// "保持中心的缩放")、高度差 2pt。别拿这些数去反推"窗口是不是被谁挪过/缩过":那会追一个
// 根本不存在的 bug(本会话差点)。要精确坐标就在 App 内读 NSWindow.frame,或者像那次一样
// 起一个已知 frame 的探针窗口先量出这块屏的偏差。本脚本适合回答的是"在没在屏、是哪块屏、
// 大致多大"这类问题。
//
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

var owner = "Lyrimuse"
var requireOverlay = false
var menubarItems = false
var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--owner":
        guard let v = args.first else { print("--owner 后面要跟 App 名"); exit(2) }
        owner = v
        args.removeFirst()
    case "--require-overlay":
        requireOverlay = true
    case "--menubar-items":
        menubarItems = true
    case "-h", "--help":
        print("""
        用法: check-windows.swift [--owner <App名>] [--require-overlay | --menubar-items]
          --owner            要查的 App，默认 Lyrimuse
          --require-overlay  找不到可见的歌词悬浮窗就以非零码退出，可用作断言
          --menubar-items    从左到右列出所有 App 的菜单栏项（位置、宽度），--owner 那个 App 的项前面标 *。
                             菜单栏项不在窗口列表里，这一项改读辅助功能接口的只读属性（不点、不发动作），
                             运行脚本的终端要有「辅助功能」权限；读到的是系统记的位置，像素有没有排坏仍要截图对照

        ⚠️ --require-overlay 的前提是**正在播放**。开着「暂停/无播放时隐藏悬浮窗」
           这个设置时，停播状态下悬浮窗 onscreen=false 是正确行为，不是故障。
        """)
        exit(0)
    default:
        print("不认识的参数: \(arg)"); exit(2)
    }
}

// 菜单栏项（MenuBarExtra / NSStatusItem）不在 CGWindowList 里，只能读各 App 的 AXExtrasMenuBar。
// 只读属性；每个 App 的消息超时设 0.5 秒，没响应的 App 不会把脚本挂住。
func axRawValue(_ el: AXUIElement, _ attr: String) -> AXValue? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &raw) == .success, let raw,
          CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    return (raw as! AXValue)
}

func axPoint(_ el: AXUIElement) -> CGPoint? {
    guard let v = axRawValue(el, kAXPositionAttribute) else { return nil }
    var out = CGPoint.zero
    return AXValueGetValue(v, .cgPoint, &out) ? out : nil
}

func axSize(_ el: AXUIElement) -> CGSize? {
    guard let v = axRawValue(el, kAXSizeAttribute) else { return nil }
    var out = CGSize.zero
    return AXValueGetValue(v, .cgSize, &out) ? out : nil
}

func axString(_ el: AXUIElement, _ attr: String) -> String {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &raw) == .success else { return "" }
    return raw as? String ?? ""
}

if menubarItems {
    guard AXIsProcessTrusted() else {
        print("读不到菜单栏项：运行这个脚本的终端没有「辅助功能」权限（系统设置 › 隐私与安全性 › 辅助功能）")
        exit(1)
    }
    struct MenuBarItem { let app: String; let label: String; let frame: CGRect }
    var items: [MenuBarItem] = []
    for app in NSWorkspace.shared.runningApplications {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.5)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXExtrasMenuBar" as CFString, &bar) == .success,
              let bar else { continue }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let kids = children as? [AXUIElement] else { continue }
        for kid in kids {
            guard let pos = axPoint(kid), let size = axSize(kid) else { continue }
            let label = [axString(kid, kAXTitleAttribute), axString(kid, kAXDescriptionAttribute),
                         axString(kid, "AXIdentifier")].first { !$0.isEmpty } ?? ""
            items.append(MenuBarItem(app: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
                                     label: label, frame: CGRect(origin: pos, size: size)))
        }
    }
    if items.isEmpty { print("一个菜单栏项都没读到"); exit(1) }
    for item in items.sorted(by: { $0.frame.minX < $1.frame.minX }) {
        let mark = item.app.localizedCaseInsensitiveContains(owner) ? "*" : " "
        let label = item.label.isEmpty ? "(无标签)" : item.label
        print("\(mark) x=\(Int(item.frame.minX)) w=\(Int(item.frame.width)) h=\(Int(item.frame.height)) \(item.app) · \(label)")
    }
    exit(0)
}

guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]]
else {
    print("拿不到窗口列表（需要「屏幕录制」权限？）")
    exit(1)
}

struct WindowInfo {
    let id: Int
    let title: String
    let bounds: CGRect
    let onscreen: Bool
    let layer: Int
    let alpha: Double
}

let windows: [WindowInfo] = list.compactMap { w in
    let ownerName = w[kCGWindowOwnerName as String] as? String ?? ""
    guard ownerName.localizedCaseInsensitiveContains(owner) else { return nil }
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    return WindowInfo(
        id: w[kCGWindowNumber as String] as? Int ?? -1,
        title: w[kCGWindowName as String] as? String ?? "",
        bounds: CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0),
        onscreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? false,
        layer: w[kCGWindowLayer as String] as? Int ?? 0,
        alpha: w[kCGWindowAlpha as String] as? Double ?? -1)
}

if windows.isEmpty {
    print("没有找到属于 \(owner) 的窗口 —— 进程没起来，或者它此刻一个窗口都没开")
    exit(requireOverlay ? 1 : 0)
}

// 窗口层级(kCGWindowLayer)在这个 App 里的实际取值,实测:
//   0     普通窗口（设置 / 歌词窗口 / 歌词管理）
//   >0    歌词悬浮层（经典悬浮歌词等）
//   ≥1000 高度不超过菜单栏的是菜单栏那一项（旧系统上 MenuBarExtra 约 179x32）；更高的是罩在刘海上的
//         灵动岛卡片（macOS 27 实测 layer=1000、约 468x190，那一版菜单栏项本身不在窗口列表里，
//         要看菜单栏项用 --menubar-items）
// 菜单栏项和灵动岛卡片都不算悬浮窗 —— 混进去会让"悬浮窗可见"这个断言永远为真。
let menuBarMaxHeight: CGFloat = 50

func kind(of w: WindowInfo) -> String {
    if w.layer >= 1000 { return w.bounds.height <= menuBarMaxHeight ? "menubar" : "notch  " }
    if w.layer > 0 { return "overlay" }
    return "window "
}

for w in windows {
    let size = "\(Int(w.bounds.width))x\(Int(w.bounds.height))"
    let pos = "@(\(Int(w.bounds.minX)),\(Int(w.bounds.minY)))"
    let title = w.title.isEmpty ? "(无标题)" : w.title
    print("\(kind(of: w)) id=\(w.id) onscreen=\(w.onscreen) layer=\(w.layer) alpha=\(w.alpha) \(size)\(pos) \(title)")
}

if requireOverlay {
    // 断言:至少有一个在屏、非零尺寸、不透明的悬浮层窗口。
    // 尺寸和 alpha 都要查 —— 一个 0x0 或者 alpha=0 的窗口在列表里同样"存在",但用户
    // 什么也看不见,只查存在性等于没查。
    let live = windows.filter {
        kind(of: $0) == "overlay" && $0.onscreen
            && $0.bounds.width > 0 && $0.bounds.height > 0 && $0.alpha > 0
    }
    if live.isEmpty {
        print("FAIL: 没有可见的歌词悬浮窗（在屏 + 非零尺寸 + alpha>0）")
        print("      如果此刻没在播放、且开着「暂停/无播放时隐藏悬浮窗」，这是预期结果。")
        exit(1)
    }
    print("OK: \(live.count) 个可见悬浮窗")
}
