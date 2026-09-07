#!/usr/bin/env swift
//
// 只读探针:对某个窗口做**帧级**抓屏,抓一小块区域逐帧算亮度和差异,把突变帧存成 PNG。
// 肉眼看不清、`screencapture` 一秒几张又抓不到的那种"闪一下"(一两帧、几十毫秒)靠它坐实。
//
//   swift lyrimuse/scripts/capture-window-frames.swift <windowID> <秒数> <x> <y> <w> <h> <输出目录>
//     windowID 用 check-windows.swift 查;x y w h 是**窗口坐标系里的点**(左上原点),内部按 2x 换像素。
//   例:swift lyrimuse/scripts/capture-window-frames.swift 34959 12 270 168 580 66 /tmp/cap
//
// 走 ScreenCaptureKit 的 SCStream(单窗口过滤、120Hz 上限、窗口被遮住也抓得到),只在窗口有变化时
// 出帧;每帧算区域灰度均值 + 与上一帧差异 >24 的像素占比,占比 >8% 或均值跳 >6 记为 SPIKE,连同
// 前一帧、后一帧一起存 PNG。跑完打印所有 diff>2% 的帧。需要「屏幕录制」权限(跟 screencapture 同一份)。
//
// 2026-09-07 首次使用:设置页菜单栏预览"重建时闪一下",抓到每次换句那一帧起区域均值 +44、
// 2~3 帧后 −44,亮的那几帧里歌词是黑字、材质是浅色 —— 由此锁定是 `.environment(\.colorScheme)`
// 跟着 `MenuBarAppearanceStore.isDark` 翻了两次,见 MenuBar/MenuBarAppearance.swift 头注。
import AppKit
import ScreenCaptureKit
import CoreImage

let args = CommandLine.arguments
guard args.count >= 8, let wid = UInt32(args[1]), let seconds = Double(args[2]),
      let rx0 = Double(args[3]), let ry0 = Double(args[4]), let rw0 = Double(args[5]), let rh0 = Double(args[6])
else { print("usage: capture-window-frames.swift <windowID> <seconds> <x> <y> <w> <h> <outdir>"); exit(2) }
let rx = rx0, ry = ry0, rw = rw0, rh = rh0
let outDir = args[7]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

final class Output: NSObject, SCStreamOutput {
    var prev: [UInt8]? = nil
    var prevImage: CGImage? = nil
    var index = 0
    var pendingSaveNext = false
    var lastSavedIndex = -10
    let start = Date()
    let ctx = CIContext(options: [.useSoftwareRenderer: false])
    var stats: [(Int, Double, Double, Double)] = []
    var savedCount = 0
    var w = 0, h = 0

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        // 只处理有内容更新的帧(SCK 只在窗口有变化时才发新帧;status complete)
        guard let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = att.first?[.status] as? Int, let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete else { return }
        let ci = CIImage(cvPixelBuffer: pb)
        let scale = 2.0
        let fullH = Double(CVPixelBufferGetHeight(pb))
        // CIImage 原点左下;窗口坐标左上 → 换算
        let crop = CGRect(x: rx * scale, y: fullH - (ry + rh) * scale, width: rw * scale, height: rh * scale)
        let cropped = ci.cropped(to: crop)
        guard let cg = ctx.createCGImage(cropped, from: crop) else { return }
        w = cg.width; h = cg.height
        // 取灰度字节
        var gray = [UInt8](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        guard let gctx = CGContext(data: &gray, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                   space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        gctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0
        for v in gray { sum += Int(v) }
        let mean = Double(sum) / Double(gray.count)
        var diffFrac = 0.0
        var meanDelta = 0.0
        if let p = prev {
            var n = 0
            for i in 0..<gray.count where abs(Int(gray[i]) - Int(p[i])) > 24 { n += 1 }
            diffFrac = Double(n) / Double(gray.count)
            var ps = 0; for v in p { ps += Int(v) }
            meanDelta = mean - Double(ps) / Double(p.count)
        }
        let t = Date().timeIntervalSince(start)
        stats.append((index, t, mean, diffFrac))
        let spike = diffFrac > 0.08 || abs(meanDelta) > 6
        if spike || pendingSaveNext {
            if spike, let pi = prevImage, lastSavedIndex != index - 1 { save(pi, index - 1) }
            save(cg, index)
            pendingSaveNext = spike
            print(String(format: "frame %4d t=%6.3f mean=%6.2f diff=%.3f dMean=%+.2f %@", index, t, mean, diffFrac, meanDelta, spike ? "SPIKE" : "(after)"))
        }
        prev = gray
        prevImage = cg
        index += 1
    }

    func save(_ cg: CGImage, _ i: Int) {
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let path = "\(outDir)/f\(String(format: "%05d", i)).png"
        try? data.write(to: URL(fileURLWithPath: path))
        lastSavedIndex = i
        savedCount += 1
    }
}

let sema = DispatchSemaphore(value: 0)
var stream: SCStream?
let output = Output()
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let win = content.windows.first(where: { $0.windowID == wid }) else {
            print("window \(wid) not found"); exit(1)
        }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let cfg = SCStreamConfiguration()
        cfg.width = Int(win.frame.width * 2)
        cfg.height = Int(win.frame.height * 2)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        cfg.queueDepth = 8
        cfg.showsCursor = false
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.capturesShadowsOnly = false
        cfg.ignoreShadowsSingleWindow = true
        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try s.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cap"))
        try await s.startCapture()
        stream = s
        print("capturing window \(wid) \(Int(win.frame.width))x\(Int(win.frame.height)) for \(seconds)s …")
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        try await s.stopCapture()
        let st = output.stats
        print("frames=\(st.count) saved=\(output.savedCount) region=\(output.w)x\(output.h)")
        if let mn = st.map({ $0.2 }).min(), let mx = st.map({ $0.2 }).max() {
            print(String(format: "mean luminance range %.2f … %.2f", mn, mx))
        }
        let big = st.filter { $0.3 > 0.02 }
        print("frames with diff>2%: \(big.count)")
        for b in big.prefix(60) { print(String(format: "  #%d t=%.3f mean=%.2f diff=%.3f", b.0, b.1, b.2, b.3)) }
        sema.signal()
    } catch {
        print("error: \(error)"); exit(1)
    }
}
sema.wait()
