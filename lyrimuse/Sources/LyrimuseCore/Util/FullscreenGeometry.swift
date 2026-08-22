import CoreGraphics

/// 「一个窗口有没有铺满一块屏」的纯几何判据。
///
/// 拆出来放 Core 是为了能被 `lyrimuse-selftest` **无屏**覆盖 —— 跟 `KaraokeFill` /
/// `MarqueeMath` / `WrapLayoutMath` 拆出来的理由一样:调用侧那一层要 `NSScreen` 和
/// `CGWindowListCopyWindowInfo`,没有屏幕就跑不起来,而判据本身错没错是纯算术问题。
/// 消费方是 `FullscreenAppMonitor.detectFullscreenApp()`。
///
/// **全部入参都在 CG 坐标系**(原点主屏左上、y 向下),跟 `CGWindowListCopyWindowInfo`
/// 报的 bounds 同源。
public enum FullscreenGeometry {
    /// 顶边容差。2pt 要盖住两件事:
    ///   - 「刘海下沿」与「菜单栏下沿」在本机差 1pt(实测 32 vs 33),换机型这个差还会变;
    ///   - 缩放屏的亚像素。
    /// 再放大就会开始把「顶边随便靠上一点的大窗口」算进来。
    public static let defaultTolerance: CGFloat = 2

    /// 这块屏上,窗口顶边落在哪几个位置才算「铺满」。三个位置对应三种真实的全屏形态:
    ///
    ///   1. `屏幕顶`     —— 原生全屏且内容延伸进刘海两侧(App 没开安全区兼容模式);
    ///   2. `刘海下沿`   —— 原生全屏但内容避开刘海(safeAreaInsets.top,刘海区留黑);
    ///   3. `菜单栏下沿` —— 伪全屏:App 自己的全屏按钮(微信视频通话、部分播放器)不走 macOS
    ///                      原生全屏 API,不新建 Space、菜单栏也不收起,只是把窗口拉到
    ///                      「整块屏减去菜单栏那一条」。
    ///
    /// ⚠️ 形态 2 必须单列。原生全屏时菜单栏已被系统收起 → `menuBarHeight` 变成 0 → 形态 3
    /// 算出来的期望顶边塌回屏幕顶,跟实际的刘海下沿差一整个刘海高(本机 32pt),直接漏判。
    /// 桌面态下 2 和 3 只差 1pt 看着像同一条,但那 1pt 是本机特例不是系统契约。
    public static func legalTops(screen: CGRect, safeAreaTop: CGFloat, menuBarHeight: CGFloat) -> [CGFloat] {
        [screen.minY, screen.minY + safeAreaTop, screen.minY + menuBarHeight]
    }

    /// 窗口是否铺满了这块屏。
    ///
    /// 四条同时成立:宽度顶格、左边缘对齐、**底边探到屏幕最底**、顶边落在 `legalTops` 之一。
    ///
    /// 「底边探到屏幕最底」是把**标准最大化窗口**挡在外面的关键一条:绿键 zoom 铺的是
    /// `visibleFrame`,底边停在 Dock 的保留区上方。本机实测(2026-08-22 桌面态):音乐
    /// (0,33,1470,858) 底边 891、Arc/Code/Edge 底边 878,而屏幕高 956,全部不命中;而微信
    /// 视频通话的伪全屏是 (0,33,1470,923),底边正好 956,命中。
    ///
    /// ⚠️ 已知不可判定的边界:用户把 Dock 设成自动隐藏时,最大化窗口的底边也会探到屏幕最底,
    /// 那时它与伪全屏在公开 API 下几何完全同构、分不开。接受这个误判方向 —— 代价只是浮层
    /// 临时让开(移开窗口即恢复),而反方向(漏判)是用户已经报过的「全屏时隐藏根本不生效」。
    public static func covers(window: CGRect,
                              screen: CGRect,
                              legalTops: [CGFloat],
                              tolerance: CGFloat = defaultTolerance) -> Bool {
        guard window.width >= screen.width - tolerance else { return false }
        guard abs(window.minX - screen.minX) <= tolerance else { return false }
        guard window.maxY >= screen.maxY - tolerance else { return false }
        return legalTops.contains { abs(window.minY - $0) <= tolerance }
    }
}
