import AppKit

/// 把一棵**不挂窗口**的视图树拼成图层树,给离屏渲染(`CARenderer`)用。
///
/// AppKit 只在视图进了窗口时才把子视图的图层挂到父视图的图层下;不挂窗口时父图层下面是空的,
/// 画出来什么都没有。而挂在窗口上的树属于窗口自己的渲染上下文,`CARenderer` 也画不了。
/// 所以离屏渲染时照视图层级手工拼:子视图的图层挂到父视图图层下、位置取子视图的 frame、
/// 父图层的 bounds 取父视图的 bounds(滚动视图的偏移在 `bounds.origin` 里)、
/// 视图翻转与否跟父视图不同时翻转这一层坐标。已经从视图树里拿掉的子视图,它的图层一并摘掉。
///
/// 每帧渲染前调一次:滚动、换子视图、改 frame 都要靠它同步到图层上。见 19 章决策 1。
@MainActor
public enum DetachedLayerTree {
    public static func assemble(_ view: NSView, parentFlipped: Bool = false) {
        guard let layer = view.layer else { return }
        layer.isGeometryFlipped = view.isFlipped != parentFlipped
        layer.bounds = view.bounds
        let backing = Set(view.subviews.compactMap { $0.layer.map(ObjectIdentifier.init) })
        for sub in layer.sublayers ?? [] where sub.delegate is NSView && !backing.contains(ObjectIdentifier(sub)) {
            sub.removeFromSuperlayer()
        }
        for subview in view.subviews {
            if subview.layer == nil { subview.wantsLayer = true }
            guard let child = subview.layer else { continue }
            if child.superlayer !== layer { layer.addSublayer(child) }
            child.anchorPoint = .zero
            child.position = subview.frame.origin
            child.isHidden = subview.isHidden
            // 不同步 alphaValue:组件里有直接给子视图图层的 opacity 装淡入淡出动画的(间奏「•••」),
            // 在这里按 alphaValue 改回去会把它们的模型值冲掉。
            assemble(subview, parentFlipped: view.isFlipped)
        }
    }
}
