import CoreGraphics

/// 悬浮窗落点的**纯几何判断**:它现在还看得见吗?看不见的话该挪到哪儿?
///
/// 这套判断原本只以三行 clamp 的形式存在于 `restoredOrigin` 里,而那个函数只在
/// `convenience init()` 里跑一次 —— 它的注释写着"显示器配置可能变了(比如拔了外接屏)",
/// 说的没错,但**只在启动那一刻成立**。App 跑着的时候拔掉外接屏,窗口就留在一个不存在的
/// 坐标上,用户看不见、也没有任何自我纠正机制。
///
/// 抽成纯函数是因为这件事没法在只有一块屏的机器上真机验证 —— 单元测试是唯一能覆盖
/// "两块屏时拔掉其中一块"的手段。
public enum OverlayPlacement {
    /// 窗口至少要露出多少才算"够得着"。
    ///
    /// 判据取得**保守**:只要还露出这么多就一律不动。误把用户精心摆好的窗口挪走,比拔屏
    /// 之后需要手动找回窗口更让人恼火,所以宁可少动。用户主动把窗口拖到屏幕边缘、只留一
    /// 条边在外面,是完全正常的用法,不该被"纠正"。
    public static let minVisibleWidth: CGFloat = 60
    public static let minVisibleHeight: CGFloat = 30

    /// 这个窗口还有没有足够部分落在某块屏的可见区域里。
    public static func isSufficientlyVisible(frame: CGRect, screens: [CGRect]) -> Bool {
        for screen in screens {
            let inter = screen.intersection(frame)
            if inter.isNull { continue }
            // 阈值不能超过窗口自身尺寸 —— 否则一个比阈值还小的窗口永远判不出"可见"。
            let needW = min(minVisibleWidth, frame.width)
            let needH = min(minVisibleHeight, frame.height)
            if inter.width >= needW && inter.height >= needH { return true }
        }
        return false
    }

    /// 把窗口夹回给定屏幕的可见区域。跟 `restoredOrigin` 里那三行是同一套算法。
    public static func clamped(frame: CGRect, into screen: CGRect) -> CGPoint {
        var origin = frame.origin
        // maxX - width 可能小于 minX(窗口比屏还宽),那时以 minX 为准 —— 先取 max 再取 min
        // 会把它推到右边界外,顺序不能反。
        origin.x = min(max(origin.x, screen.minX), max(screen.minX, screen.maxX - frame.width))
        origin.y = min(max(origin.y, screen.minY), max(screen.minY, screen.maxY - frame.height))
        return origin
    }

    /// 屏幕配置变化后该把窗口挪到哪儿。`nil` = 不用动。
    ///
    /// `screens` 的第一个元素约定为主屏(调用方传 `NSScreen.main` 优先的那份列表)——窗口
    /// 无处可去时的落脚点。
    public static func repositionIfOffscreen(frame: CGRect, screens: [CGRect]) -> CGPoint? {
        guard let primary = screens.first else { return nil }
        if isSufficientlyVisible(frame: frame, screens: screens) { return nil }
        let target = clamped(frame: frame, into: primary)
        // 夹完还是原地(浮点误差之外)就别发多余的移动 —— 会白白触发一次位置持久化。
        if abs(target.x - frame.origin.x) < 0.5 && abs(target.y - frame.origin.y) < 0.5 {
            return nil
        }
        return target
    }
}
