#!/usr/bin/env swift
//
// 只读探针:一颗**刚建出来**的状态栏项,它的 appearance 什么时候才可信?
//
//   swift lyrimuse/scripts/statusitem-appearance-probe.swift
//
// 新建一个 1pt 宽的 NSStatusItem,往按钮里挂一个只会打印回调的子视图,每 5ms 采样一次按钮的
// window / 窗口 frame / effectiveAppearance,1.5s 后移除退出 —— 菜单栏上只会短暂出现一个 1pt
// 的空项,不点击、不发按键、不改任何状态。
//
// 为什么要有它(2026-09-07):设置页菜单栏预览"重建时闪一下",根因是 `MenuBarAppearanceStore`
// 在状态栏项重建那一刻当场读按钮的 effectiveAppearance。这个探针在 macOS 27 上抓到的时间线
// (见 MenuBar/MenuBarAppearance.swift 头注):刚建出来按钮已在窗口里但窗口高度 0、appearance 是
// VibrantLight(错);~60ms 后状态栏排版,6ms 内 viewDidChangeEffectiveAppearance 连发七次,
// 最后才落在 VibrantDark。要在别的 macOS 版本上核这段时序,跑一遍看输出即可。
import AppKit

final class Probe: NSObject, NSApplicationDelegate {
    var item: NSStatusItem?
    var last = ""
    var t0 = Date()
    var timer: Timer?
    var hover: HoverProbe?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.appearance = nil
        print("NSApp.effectiveAppearance = \(NSApp.effectiveAppearance.name.rawValue)")
        let item = NSStatusBar.system.statusItem(withLength: 1)
        self.item = item
        t0 = Date()
        let h = HoverProbe(t0: t0)
        hover = h
        if let b = item.button {
            h.frame = b.bounds
            h.autoresizingMask = [.width, .height]
            b.addSubview(h)
        }
        sample("immediately after create+addSubview")
        timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { [weak self] _ in self?.sample(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.timer?.invalidate()
            if let it = self?.item { NSStatusBar.system.removeStatusItem(it) }
            self?.item = nil
            print("removed; exiting")
            NSApp.terminate(nil)
        }
    }

    func sample(_ label: String?) {
        guard let b = item?.button else { print("no button"); return }
        let win = b.window
        let desc = "window=\(win == nil ? "nil" : "yes") visible=\(win?.isVisible ?? false) " +
            "winFrame=\(win.map { NSStringFromRect($0.frame) } ?? "-") " +
            "winAppearance=\(win?.appearance?.name.rawValue ?? "nil") winEff=\(win?.effectiveAppearance.name.rawValue ?? "-") " +
            "buttonEff=\(b.effectiveAppearance.name.rawValue) hoverEff=\(hover?.effectiveAppearance.name.rawValue ?? "-") " +
            "hoverWindow=\(hover?.window == nil ? "nil" : "yes")"
        if desc != last || label != nil {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[\(ms)ms] \(label.map { $0 + ": " } ?? "")\(desc)")
            last = desc
        }
    }
}

final class HoverProbe: NSView {
    let t0: Date
    init(t0: Date) { self.t0 = t0; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("[\(ms)ms] hover.viewDidChangeEffectiveAppearance → \(effectiveAppearance.name.rawValue) window=\(window == nil ? "nil" : "yes")")
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("[\(ms)ms] hover.viewDidMoveToWindow window=\(window == nil ? "nil" : "yes") eff=\(effectiveAppearance.name.rawValue)")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let d = Probe()
app.delegate = d
app.run()
