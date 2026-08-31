#!/usr/bin/env swift
// 离屏复现 lyrimuse/Sources/lyrimuse/PlaybackCoordinator.swift 里
// `bakeWindowBackgroundLayers` 的取色算法,脱离整个 App 直接对一张封面图跑一遍。
//
// 用途:诊断"歌词窗口背景颜色跟封面/跟 Apple Music 对不上"这类问题——不用真的
// 播放音乐、不用重新编译 App,几秒钟就能看到某张封面会烘出什么颜色,配合
// sample-bg-saturation.py 对着 Apple Music 原生「播放中」窗口的截图做定量对比。
//
// 背景/来龙去脉见 docs/features/07-lyrics-window.md 的"专项:背景取色逼近
// Apple Music"一节——2026-08-23 那轮发现 satTarget 的基础倍率方向反了(该是
// 源图鲜艳端的 ~0.35 倍,不是 1.5 倍),这份脚本就是当时用来反复验证的工具,
// 从会话的 /private/tmp scratchpad 整理进仓库,后续要接着调参/换算法照这份改。
//
// 用法:
//   swift scripts/bakebg-repro.swift path/to/cover.jpg [--verbose] [--out baked.png]
//
// 跟真实 PlaybackCoordinator.swift 保持同步的责任在改代码的人身上——这是离屏
// 复现,不是同一份源码;每次改了正式代码里的算法,记得同步改这份脚本。

import AppKit
import CoreImage
import Foundation

let args = CommandLine.arguments.dropFirst()
guard let path = args.first(where: { !$0.hasPrefix("--") }) else {
    print("usage: swift bakebg-repro.swift <image path> [--verbose] [--out baked.png]")
    exit(1)
}
let verbose = args.contains("--verbose")
var outPath: String?
if let idx = args.firstIndex(of: "--out"), args.index(after: idx) < args.endIndex {
    outPath = args[args.index(after: idx)]
}

guard let nsImage = NSImage(contentsOfFile: path),
      let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("failed to load image at \(path)")
    exit(1)
}

let blurBakeContext = CIContext(options: [.workingColorSpace: NSNull()])

struct BakeResult {
    let base: NSImage?
    let satP75: Double
    let hueCoherenceScale: Double
    let satTarget: Double
    let fieldS: Double
    let satMul: Double
    let tintHue: Double
    let tintSat: Double
    let tintBright: Double
}

// 与 PlaybackCoordinator.bakeWindowBackgroundLayers 逐行对应(2026-08-27 第十轮,
// 幂函数 satTarget 系数 refit 版)。
func bake(cgImage: CGImage, verbose: Bool) -> BakeResult? {
    let W: CGFloat = 720
    let frame = CGRect(x: 0, y: 0, width: W, height: W)

    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let cgctx = CGContext(data: nil, width: 6, height: 6, bitsPerComponent: 8,
                                bytesPerRow: 6 * 4, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    cgctx.interpolationQuality = .medium
    cgctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 6, height: 6))
    guard let data = cgctx.data else { return nil }
    let px = data.bindMemory(to: UInt8.self, capacity: 36 * 4)

    var cellLuma = [Double](repeating: 0, count: 36)
    for i in 0..<36 {
        let o = i * 4
        cellLuma[i] = (0.299 * Double(px[o]) + 0.587 * Double(px[o + 1]) + 0.114 * Double(px[o + 2])) / 255
    }
    let meanLuma = cellLuma.reduce(0, +) / 36
    let homog = 0.55
    for i in 0..<36 {
        let f0 = meanLuma / max(0.02, cellLuma[i])
        let f = (1 - homog) + homog * min(3.5, max(0.4, f0))
        for ch in 0..<3 {
            px[i * 4 + ch] = UInt8(min(255, Double(px[i * 4 + ch]) * f))
        }
        px[i * 4 + 3] = 255
    }

    var cellSat = [Double](repeating: 0, count: 36)
    for i in 0..<36 {
        let o = i * 4
        let mx = Double(max(px[o], max(px[o + 1], px[o + 2])))
        let mn = Double(min(px[o], min(px[o + 1], px[o + 2])))
        cellSat[i] = mx > 0 ? (mx - mn) / mx : 0
    }

    func rgbToHSV(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
        let mx = Swift.max(r, g, b), mn = Swift.min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = (g - b) / d } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
            h *= 60
            if h < 0 { h += 360 }
        }
        return (h, mx > 0 ? d / mx : 0, mx)
    }
    func hsvToRGB(_ h: Double, _ s: Double, _ v: Double) -> (r: Double, g: Double, b: Double) {
        let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let i = Int(hh), f = hh - Double(i)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    if verbose {
        print("--- per-cell hue/sat after luma normalize ---")
        for i in 0..<36 {
            let o = i * 4
            let (h, s, v) = rgbToHSV(Double(px[o]) / 255, Double(px[o + 1]) / 255, Double(px[o + 2]) / 255)
            print("  cell \(i) (\(i % 6),\(i / 6)): rgb=(\(px[o]),\(px[o + 1]),\(px[o + 2])) h=\(Int(h)) s=\(String(format: "%.2f", s)) v=\(String(format: "%.2f", v))")
        }
    }

    // 近黑格的饱和度读数不可信(2026-08-27 第十一轮,见 PlaybackCoordinator.swift
    // 同一处的完整推导注释)——用归一化前的原始格亮度设一道下限,低于它的格子不参与
    // 色相判定/p75 统计/欠饱和格子的拉升修正。
    let darkLumaFloor = 0.08
    var hueSin = 0.0, hueCos = 0.0
    for i in 0..<36 where cellSat[i] > 0.05 && cellLuma[i] > darkLumaFloor {
        let o = i * 4
        let (h, s, _) = rgbToHSV(Double(px[o]) / 255, Double(px[o + 1]) / 255, Double(px[o + 2]) / 255)
        hueSin += sin(h * .pi / 180) * s * s
        hueCos += cos(h * .pi / 180) * s * s
    }
    var hueCoherenceScale = 1.0
    if hueSin != 0 || hueCos != 0 {
        let hDom = atan2(hueSin, hueCos) * 180 / .pi
        if verbose { print("hDom = \(hDom < 0 ? hDom + 360 : hDom)") }
        var totalHueWeight = 0.0, offHueWeight = 0.0
        for i in 0..<36 where cellSat[i] > 0.05 && cellLuma[i] > darkLumaFloor {
            let o = i * 4
            let (h, s, _) = rgbToHSV(Double(px[o]) / 255, Double(px[o + 1]) / 255, Double(px[o + 2]) / 255)
            var d = h - hDom
            while d > 180 { d -= 360 }
            while d < -180 { d += 360 }
            totalHueWeight += s * s
            if abs(d) > 60 && abs(d) <= 120 { offHueWeight += s * s }
        }
        let offHueFraction = totalHueWeight > 0 ? offHueWeight / totalHueWeight : 0
        if totalHueWeight > 0 {
            let resultantMag = (hueSin * hueSin + hueCos * hueCos).squareRoot()
            let coherenceLinear = min(1, (resultantMag / totalHueWeight) / 0.4)
            hueCoherenceScale = coherenceLinear * coherenceLinear
        }
        if verbose { print("offHueFraction = \(offHueFraction) hueCoherenceScale = \(hueCoherenceScale)") }
        if offHueFraction < 0.2 {
            for i in 0..<36 where cellSat[i] > 0.05 && cellLuma[i] > darkLumaFloor {
                let o = i * 4
                let (h, s, v) = rgbToHSV(Double(px[o]) / 255, Double(px[o + 1]) / 255, Double(px[o + 2]) / 255)
                var d = h - hDom
                while d > 180 { d -= 360 }
                while d < -180 { d += 360 }
                guard abs(d) > 60, abs(d) <= 120 else { continue }
                let newHue = hDom + (d > 0 ? 60 : -60)
                if verbose { print("  collapse cell \(i): h \(Int(h)) -> \(Int(newHue.truncatingRemainder(dividingBy: 360)))") }
                let (r, g, b) = hsvToRGB(newHue, s, v)
                px[o] = UInt8(min(255, max(0, r * 255)))
                px[o + 1] = UInt8(min(255, max(0, g * 255)))
                px[o + 2] = UInt8(min(255, max(0, b * 255)))
            }
        }
    }

    // satP75 同样排除近黑格,亮格不够 9 个时退回全 36 格(见 PlaybackCoordinator.swift
    // 同一处注释)。
    let brightIdx = (0..<36).filter { cellLuma[$0] > darkLumaFloor }
    let satP75: Double
    if brightIdx.count >= 9 {
        let sats = brightIdx.map { cellSat[$0] }.sorted()
        satP75 = sats[min(sats.count - 1, Int(Double(sats.count) * 26.0 / 36.0))]
    } else {
        satP75 = cellSat.sorted()[26]
    }
    // 2026-08-27 第十轮:系数从 0.94/1.45 refit 到 1.029/1.433(36 组真机对拍回归,
    // R²≈0.754);中途试过加色相项去修"暖色调发灰"但被数据推翻,不采纳。见
    // PlaybackCoordinator.swift 同一行上方的完整推导注释,以及
    // docs/features/07-lyrics-window.md 第十轮记录。
    let satTarget = min(0.95, 1.029 * pow(satP75, 1.433)) * hueCoherenceScale
    for i in 0..<36 where cellSat[i] > 0.01 && cellSat[i] < satTarget && cellLuma[i] > darkLumaFloor {
        let target = satTarget
        let k = target / cellSat[i]
        let o = i * 4
        let mx = Double(max(px[o], max(px[o + 1], px[o + 2])))
        for ch in 0..<3 {
            let c = Double(px[o + ch])
            px[o + ch] = UInt8(min(255, max(0, mx - (mx - c) * k)))
        }
    }
    guard let fieldCG = cgctx.makeImage() else { return nil }

    func clamp(_ img: CIImage) -> CIImage {
        img.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ])
    }
    func render(_ img: CIImage) -> NSImage? {
        guard let out = blurBakeContext.createCGImage(img, from: frame) else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: frame.width / 2, height: frame.height / 2))
    }

    let field = CIImage(cgImage: fieldCG)
        .transformed(by: CGAffineTransform(scaleX: W / 6, y: W / 6))
        .clampedToExtent()
        .applyingGaussianBlur(sigma: 35)
        .cropped(to: frame)
    var satMul = 0.85
    var fieldS = 0.0
    let fieldAvg = field.applyingFilter("CIAreaAverage", parameters: [
        kCIInputExtentKey: CIVector(cgRect: frame),
    ])
    if let avgCG = blurBakeContext.createCGImage(fieldAvg, from: CGRect(x: 0, y: 0, width: 1, height: 1)),
       let d = avgCG.dataProvider?.data as Data?, d.count >= 3 {
        let mx = Double(max(d[0], max(d[1], d[2])))
        let mn = Double(min(d[0], min(d[1], d[2])))
        fieldS = mx > 0 ? (mx - mn) / mx : 0
        if fieldS > 0.02 {
            satMul = min(1.6 * max(0.4, hueCoherenceScale), max(0.35 * hueCoherenceScale, satTarget / fieldS))
        }
    }
    let vivified = field
        .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.4 * hueCoherenceScale])
        .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: satMul])

    let baseImage = clamp(vivified
        .applyingFilter("CIExposureAdjust", parameters: ["inputEV": -0.15]))
    guard let base = render(baseImage) else { return nil }

    var tintHue = 0.0, tintSat = 0.0, tintBright = 0.0
    let avg = baseImage.applyingFilter("CIAreaAverage", parameters: [
        kCIInputExtentKey: CIVector(cgRect: frame),
    ])
    if let avgCG = blurBakeContext.createCGImage(avg, from: CGRect(x: 0, y: 0, width: 1, height: 1)),
       let data = avgCG.dataProvider?.data as Data?, data.count >= 3 {
        let color = NSColor(red: CGFloat(data[0]) / 255, green: CGFloat(data[1]) / 255,
                             blue: CGFloat(data[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
        color.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &v, alpha: nil)
        tintHue = Double(h) * 360
        tintSat = Double(s)
        tintBright = Double(v) * 0.85
    }
    return BakeResult(base: base, satP75: satP75, hueCoherenceScale: hueCoherenceScale,
                       satTarget: satTarget, fieldS: fieldS, satMul: satMul,
                       tintHue: tintHue, tintSat: tintSat, tintBright: tintBright)
}

guard let result = bake(cgImage: cgImage, verbose: verbose) else {
    print("bake failed")
    exit(1)
}
print("satP75=\(result.satP75) hueCoherenceScale=\(result.hueCoherenceScale) satTarget=\(result.satTarget)")
print("fieldS=\(result.fieldS) satMul=\(result.satMul)")
print("FINAL(area-average) tintHue=\(result.tintHue) tintSat=\(result.tintSat) tintBright=\(result.tintBright)")

if let out = outPath, let base = result.base,
   let tiff = base.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: out))
    print("wrote \(out)")
}
