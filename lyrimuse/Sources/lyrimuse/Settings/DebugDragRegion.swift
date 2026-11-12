import AppKit
import LyrimuseCore
import os

/// `debug/drag-region`:这扇窗此刻交给窗口服务器的拖窗区。全尺寸内容窗口的标题栏按住哪里能拖,是 AppKit 按
/// `mouseDownCanMoveWindow` 等算好一份区域交给窗口服务器、由窗口服务器判的(07 章决策 14、92),进程里看不到
/// 别的痕迹,只能读这份区域。读的是 AppKit 私有接口,接口不在就写 `available: false`。
///
/// 坐标一律换成窗口左上原点、y 向下(跟截图、issue 里报的拖动点一致)。
@MainActor
extension DebugDeepLinks {
    private static let dragLogger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "deep-link")

    static func writeDragRegion(_ name: String) {
        guard let window = window(named: name) else {
            dragLogger.notice("debug drag-region: no visible window named \(name, privacy: .public)")
            return
        }
        let url = outputDir.appendingPathComponent("drag-region-\(name).json")
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            let data = try SafeSerialization.jsonDataThrowing(dragRegionReport(window), options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            dragLogger.notice("debug drag-region written: \(url.path, privacy: .public)")
        } catch {
            dragLogger.error("debug drag-region failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func dragRegionReport(_ window: NSWindow) -> [String: Any] {
        let height = window.frame.height
        func topDown(_ r: CGRect) -> [Double] {
            [Double(r.minX), Double(height - r.maxY), Double(r.width), Double(r.height)]
        }
        var report: [String: Any] = ["windowSize": [Double(window.frame.width), Double(height)]]
        let frameSel = NSSelectorFromString("_draggableFrame")
        let dataSel = NSSelectorFromString("_lastDragRegionData")
        guard window.responds(to: frameSel), window.responds(to: dataSel),
              let frameIMP = class_getMethodImplementation(type(of: window), frameSel) else {
            report["available"] = false
            return report
        }
        report["available"] = true
        typealias FrameFn = @convention(c) (AnyObject, Selector) -> CGRect
        let draggable = unsafeBitCast(frameIMP, to: FrameFn.self)(window, frameSel)
        report["draggableFrame"] = topDown(draggable)
        let data = window.perform(dataSel)?.takeUnretainedValue() as? Data
        report["draggableRects"] = data.map { decodeRegionBands($0).map(topDown) } ?? []
        report["blockingViews"] = blockingViews(window).map { item in
            ["class": item.name, "rect": topDown(item.rect)] as [String: Any]
        }
        report["isMovable"] = window.isMovable
        report["isZoomed"] = window.isZoomed
        report["styleMask"] = window.styleMask.rawValue
        if let data { report["regionInts"] = data.count <= 4096 ? data.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)).map(Int.init) } : [] }
        let draggableSel = NSSelectorFromString("_isDraggable")
        if window.responds(to: draggableSel), let imp = class_getMethodImplementation(type(of: window), draggableSel) {
            typealias BoolFn = @convention(c) (AnyObject, Selector) -> Bool
            report["isDraggable"] = unsafeBitCast(imp, to: BoolFn.self)(window, draggableSel)
        }
        report["opaqueRects"] = opaqueRegion(window, draggable).map(topDown)
        // 标题栏里几个点的命中测试落到哪个视图(左上原点):标题栏空白处的按下、双击是谁先收到。
        if let frameView = window.contentView?.superview {
            report["hitTests"] = [CGPoint(x: 338, y: 19.5), CGPoint(x: window.frame.width / 2, y: 10)].map { p -> [String: Any] in
                let hit = frameView.hitTest(NSPoint(x: p.x, y: height - p.y))
                return ["point": [Double(p.x), Double(p.y)], "view": hit.map { String(describing: type(of: $0)) } ?? "nil"]
            }
        }
        report["opaqueByView"] = opaqueByView(window, draggable).map { item in
            ["class": item.name, "depth": item.depth, "frame": topDown(item.frame), "rects": item.rects.prefix(6).map(topDown)]
                as [String: Any]
        }
        return report
    }

    private typealias RegionEnumFn = @convention(c) (OpaquePointer) -> OpaquePointer?
    private typealias RegionNextFn = @convention(c) (OpaquePointer) -> UnsafePointer<CGRect>?
    private typealias RegionReleaseFn = @convention(c) (OpaquePointer) -> Int32

    private static func regionRects(_ region: OpaquePointer?) -> [CGRect] {
        guard let region, let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let e = dlsym(sky, "CGSRegionEnumerator"), let n = dlsym(sky, "CGSNextRect"),
              let r = dlsym(sky, "CGSReleaseRegionEnumerator"),
              let it = unsafeBitCast(e, to: RegionEnumFn.self)(region) else { return [] }
        var out: [CGRect] = []
        while let p = unsafeBitCast(n, to: RegionNextFn.self)(it) { out.append(p.pointee) }
        _ = unsafeBitCast(r, to: RegionReleaseFn.self)(it)
        return out
    }

    private static func opaqueRegion(_ window: NSWindow, _ draggable: CGRect) -> [CGRect] {
        let sel = NSSelectorFromString("_regionForOpaqueViewsBlockingDraggableFrame:")
        guard window.responds(to: sel), let imp = class_getMethodImplementation(type(of: window), sel) else { return [] }
        typealias Fn = @convention(c) (AnyObject, Selector, CGRect) -> OpaquePointer?
        return regionRects(unsafeBitCast(imp, to: Fn.self)(window, sel, draggable))
    }

    /// 每个视图(连同子孙)在拖窗区里报的不透明块,只列跟拖窗区相交的。
    private static func opaqueByView(_ window: NSWindow, _ draggable: CGRect)
        -> [(name: String, depth: Int, frame: CGRect, rects: [CGRect])] {
        let sel = NSSelectorFromString("_regionForOpaqueDescendants:forMove:forUnderTitlebar:")
        typealias Fn = @convention(c) (AnyObject, Selector, CGRect, Bool, Bool) -> OpaquePointer?
        guard let root = window.contentView?.superview else { return [] }
        var out: [(String, Int, CGRect, [CGRect])] = []
        var stack: [(NSView, Int)] = [(root, 0)]
        while let (view, depth) = stack.popLast(), out.count < 200 {
            guard view.responds(to: sel), let imp = class_getMethodImplementation(type(of: view), sel) else { continue }
            let rects = regionRects(unsafeBitCast(imp, to: Fn.self)(view, sel, draggable, true, true))
                .filter { $0.intersects(draggable) }
            guard !rects.isEmpty else { continue }
            out.append((String(describing: type(of: view)), depth, view.convert(view.bounds, to: nil), rects))
            for sub in view.subviews.reversed() { stack.append((sub, depth + 1)) }
        }
        return out
    }

    /// 区域数据是一串 Int32 扫描带:`[y, 本带整数个数, x0, x1, x2, x3, …]`,y 向上递增,一带管到下一带的 y 为止;
    /// 首带 y 是 Int32.min、末带是 Int32.max。
    static func decodeRegionBands(_ data: Data) -> [CGRect] {
        let ints: [Int32] = data.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
        var bands: [(y: Int32, xs: [Int32])] = []
        var i = 0
        while i + 1 < ints.count {
            let count = Int(ints[i + 1])
            guard count >= 2, i + count <= ints.count else { break }
            bands.append((ints[i], Array(ints[(i + 2)..<(i + count)])))
            i += count
        }
        var rects: [CGRect] = []
        for (k, band) in bands.enumerated() where k + 1 < bands.count && band.y != Int32.min {
            let top = bands[k + 1].y
            var j = 0
            while j + 1 < band.xs.count {
                rects.append(CGRect(x: CGFloat(band.xs[j]), y: CGFloat(band.y),
                                    width: CGFloat(band.xs[j + 1] - band.xs[j]), height: CGFloat(top - band.y)))
                j += 2
            }
        }
        return rects
    }

    /// 框架视图下所有在标题栏里报了「这块按下不拖窗」的视图(`_opaqueRectForWindowMoveWhenInTitlebar` 非空),
    /// 换成窗口坐标(y 向上)。
    private static func blockingViews(_ window: NSWindow) -> [(name: String, rect: CGRect)] {
        let sel = NSSelectorFromString("_opaqueRectForWindowMoveWhenInTitlebar")
        typealias RectFn = @convention(c) (AnyObject, Selector) -> CGRect
        guard let root = window.contentView?.superview else { return [] }
        var out: [(String, CGRect)] = []
        var stack = [root]
        while let view = stack.popLast() {
            stack.append(contentsOf: view.subviews)
            guard view.responds(to: sel), let imp = class_getMethodImplementation(type(of: view), sel) else { continue }
            let local = unsafeBitCast(imp, to: RectFn.self)(view, sel)
            guard !local.isEmpty, !local.isNull else { continue }
            out.append((String(describing: type(of: view)), view.convert(local, to: nil)))
        }
        return out
    }
}
