import CoreGraphics

/// 悬浮窗的位置模式(2026-09-11,GitHub issue #5「可否增加底部在 Dock 栏之上水平居中对齐选项」)。
///
/// 报告人的诉求不是"把窗口挪一下",是**程序算出来的精确对齐**——他明说「很难接受手动进行
/// 调整」,拖过去凑居中对他不算解决。所以做成模式而不是一次性的"对齐到…"动作:预设模式下
/// 位置由几何推导,屏幕 / Dock 变了自动跟,用户拖不动它(要挪就切回「自由」)。
///
/// 存储为字符串 rawValue(UserDefaults `np:overlayPlacementMode`);默认 `.free` = 改动前的
/// 全部行为,老用户零迁移。
public enum OverlayPlacementMode: String, Codable, Hashable, CaseIterable, Sendable {
    /// 现状:位置只由用户拖动决定(见 `OverlayPlacement` 头注与 04 章「多屏」一节的不变量)。
    case free
    /// 所在屏可见区顶边下方 `OverlayPlacement.presetTopMargin`、水平居中 —— 跟没存过位置时的
    /// 默认落点同一个数,只是从"一次性默认"变成"一直钉着"。
    case topCenter
    /// 所在屏可见区**底边**上方 `OverlayPlacement.presetBottomMargin`、水平居中。`visibleFrame`
    /// 本来就扣掉了 Dock(Dock 在底部且未自动隐藏时),所以"Dock 之上"不用自己算 Dock 有多高;
    /// Dock 放侧边 / 自动隐藏时退化成"屏幕底部居中",跟任何按 visibleFrame 摆的 App 一致。
    case bottomCenter

    /// 位置是不是由预设推导(而不是用户拖出来的)。
    public var isPreset: Bool { self != .free }

    /// 窗口高度变化时**守底边**、向上长(而不是守顶边向下长)。只有 `.bottomCenter`:贴着 Dock
    /// 的窗口若照旧向下长,`updateHeight` 那条"底边不许越过可见区底边"的钳制会让它**一点都
    /// 长不了**(顶边到 Dock 顶正好等于 120pt 地板),译文 / 罗马音 / 换行一出来直接被裁掉——
    /// 这不是新功能的边角,是"手动拖到 Dock 上方"今天就有的坑。
    public var anchorsBottom: Bool { self == .bottomCenter }
}

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

    // MARK: - 位置预设(OverlayPlacementMode,2026-09-11)

    /// 「顶部居中」离可见区顶边(= 菜单栏底)的距离。第一版取 40(照搬没存过位置时那个默认落点),
    /// 用户实机反馈「上面怎么还留了这么多空间」—— 预设的意图是"贴着菜单栏",跟"新装 App 随手
    /// 丢一个好抓的位置"不是一回事,改成跟底部同一个 12(2026-09-11)。默认落点那个 40 不动。
    public static let presetTopMargin: CGFloat = 12
    /// 「底部居中」离可见区底边(= Dock 顶)的距离。这条边本身就是 Dock 图标的顶沿,贴得太远就
    /// 不像"Dock 之上"了。
    public static let presetBottomMargin: CGFloat = 12

    /// 预设模式下窗口该在的 frame。`.free` 返回 nil(调用方:那就别动)。
    ///
    /// `visibleFrame` 是**窗口所在那块屏**的可见区域(调用方按 `hostVisibleFrame` 选,选不出来
    /// 才退主屏)—— 预设是"在这块屏上居中",不是"搬去主屏居中"。
    public static func presetFrame(mode: OverlayPlacementMode, size: CGSize, visibleFrame: CGRect) -> CGRect? {
        let x = visibleFrame.midX - size.width / 2
        switch mode {
        case .free:
            return nil
        case .topCenter:
            return CGRect(x: x, y: visibleFrame.maxY - presetTopMargin - size.height,
                          width: size.width, height: size.height)
        case .bottomCenter:
            return CGRect(x: x, y: visibleFrame.minY + presetBottomMargin,
                          width: size.width, height: size.height)
        }
    }

    /// 内容高度变了之后窗口该长成什么样 —— `updateHeight` 的几何本体,抽成纯函数是为了把
    /// "守顶边向下长"和"守底边向上长"两条路一起钉进 selftest。
    ///
    /// - 高度 = max(地板, ceil(内容高)),再夹到"锚边到可见区另一侧"—— 守顶边时不许底边越过
    ///   可见区底边(2026-08-02 修的"撑到 Dock 后面"),守底边时对称地不许顶边越过可见区顶边。
    ///   夹取仍保证不低于地板(内容真的需要空间时优先满足地板,同原逻辑)。
    /// - `visibleFrame` 为 nil(窗口一块屏都不沾)时不夹 —— 没有可信的边界可用。
    /// - 返回的 frame 高度可能跟 `current` 只差亚像素,调用方按自己的阈值决定要不要真的 setFrame。
    public static func grownFrame(
        current: CGRect, contentHeight: CGFloat, minHeight: CGFloat,
        anchorsBottom: Bool, visibleFrame: CGRect?
    ) -> CGRect {
        let rawHeight = max(minHeight, ceil(contentHeight))
        if anchorsBottom {
            let bottom = current.minY
            let maxHeight = visibleFrame.map { max(minHeight, $0.maxY - bottom) }
            let newHeight = min(rawHeight, maxHeight ?? rawHeight)
            return CGRect(x: current.minX, y: bottom, width: current.width, height: newHeight)
        }
        let top = current.minY + current.height
        let maxHeight = visibleFrame.map { max(minHeight, top - $0.minY) }
        let newHeight = min(rawHeight, maxHeight ?? rawHeight)
        return CGRect(x: current.minX, y: top - newHeight, width: current.width, height: newHeight)
    }
}
