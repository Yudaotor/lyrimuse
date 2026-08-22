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

    /// 这个窗口**自己落在**哪块屏上 —— 与它相交面积最大的那块屏的可见区域。一块都不相交
    /// 时返回 nil(调用方据此选择"那就不夹了")。
    ///
    /// 存在的理由:窗口自身的尺寸钳制(高度上限、宽度重定中心)必须以**它所在的那块屏**为
    /// 准。调用方原来写的是 `window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame`,
    /// 而 NSScreen.main 是"当前有键盘焦点的那块屏",跟这个窗口在哪儿毫无关系 —— 窗口在副屏、
    /// 焦点在主屏,且 window.screen 恰好拿不到值(刚 orderOut 过、或整块屏在重新枚举中)的
    /// 那一刻,钳制就会按主屏的边界去算,把副屏上的窗口往主屏方向推。
    public static func hostVisibleFrame(of frame: CGRect, screens: [CGRect]) -> CGRect? {
        var best: (frame: CGRect, area: CGFloat)?
        for screen in screens {
            let inter = screen.intersection(frame)
            if inter.isNull || inter.isEmpty { continue }
            let area = inter.width * inter.height
            if let b = best, b.area >= area { continue }
            best = (screen, area)
        }
        return best?.frame
    }

    /// 启动还原时,存下来的那个位置该怎么摆。
    ///
    /// `wasRescued == true` 表示这个落点**不是**用户存的那个:存的位置在当前显示器配置下一块
    /// 屏都看不见(窗口停在已经拔掉/已经休眠的外接屏上),只好临时借主屏显示。调用方据此把
    /// 这次落点标记成"借来的",不许写回磁盘 —— 否则拔屏这一下就把用户拖出来的位置永久改写
    /// 成主屏坐标,外接屏插回来也回不去了。
    ///
    /// 关键:位置**看得见就原样保留**,不再无条件夹进主屏。原来 `restoredOrigin` 里那两行
    /// 无条件 clamp 是"悬浮歌词经常在主屏和副屏之间来回跳"的根因 —— 实测:外接屏
    /// (-526,956,2560,1440)上的锚点 x=849/顶边=1202、窗口 900×120,被夹成 (570,803) 整个
    /// 落回内置屏(0,70,1470,853);用户拖回去,下次启动再被夹走一次。
    public struct RestoredPlacement: Equatable {
        public let origin: CGPoint
        public let wasRescued: Bool
        public init(origin: CGPoint, wasRescued: Bool) {
            self.origin = origin
            self.wasRescued = wasRescued
        }
    }

    /// `screens` 的第一个元素同样约定为主屏(见 `repositionIfOffscreen`)。
    public static func restored(frame: CGRect, screens: [CGRect]) -> RestoredPlacement {
        if isSufficientlyVisible(frame: frame, screens: screens) {
            return RestoredPlacement(origin: frame.origin, wasRescued: false)
        }
        // 一块屏都没有(理论上不会发生)时原样返回,别把窗口摆到凭空算出来的坐标上。
        guard let primary = screens.first else {
            return RestoredPlacement(origin: frame.origin, wasRescued: false)
        }
        return RestoredPlacement(origin: clamped(frame: frame, into: primary), wasRescued: true)
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
