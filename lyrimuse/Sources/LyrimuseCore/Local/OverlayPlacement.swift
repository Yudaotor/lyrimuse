import CoreGraphics

/// 悬浮窗的位置模式。
///
/// 要的是**程序算出来的精确对齐**,不是"把窗口挪一下"—— 手动拖过去凑居中不算解决。所以做成
/// 模式而不是一次性的"对齐到…"动作:预设模式下位置由几何推导,屏幕 / Dock 变了自动跟,
/// 用户拖不动它(要挪就切回「自由」)。
///
/// 存储为字符串 rawValue(UserDefaults `np:overlayPlacementMode`);默认 `.free` = 改动前的
/// 全部行为,老用户零迁移。
public enum OverlayPlacementMode: String, Codable, Hashable, CaseIterable, Sendable {
    /// 现状:位置只由用户拖动决定(见 `OverlayPlacement` 头注与 04 章「多屏」一节的不变量)。
    case free
    /// 贴着所在屏可见区顶边(菜单栏底边)、水平居中,见 `OverlayPlacement.presetTopMargin`。
    case topCenter
    /// 贴着所在屏可见区**底边**、水平居中,见 `OverlayPlacement.presetBottomMargin`。`visibleFrame`
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

    // MARK: - 位置预设(OverlayPlacementMode)

    /// 「顶部居中」离可见区顶边(= 菜单栏底)的距离:0,卡片顶边贴着菜单栏底边。这一档控制排在卡片下方,
    /// 窗口顶边就是卡片顶边。没存过位置时的默认落点 40 是另一回事,不动。见 04 章决策 49。
    public static let presetTopMargin: CGFloat = 0
    /// 「底部居中」离可见区底边(= Dock 顶)的距离:0,卡片底边贴着 Dock 顶。这一档控制排在卡片上方、内容在
    /// 窗口里贴底,窗口底边就是卡片底边。见 04 章决策 49。
    public static let presetBottomMargin: CGFloat = 0

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
    ///   可见区底边(修的"撑到 Dock 后面"),守底边时对称地不许顶边越过可见区顶边。
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

    // MARK: - 控制排在卡片上方还是下方(「自由」模式)

    /// 控制排槽位的高度:胶囊 22 + 离卡片 4 + 离窗口边 4。`LyricsOverlayView.controlsSlot` 按它定高;
    /// 槽位从卡片上方挪到下方时卡片在窗口里正好上移这么多,窗口反向挪同样的量卡片才不动,两处必须是同一个数。
    public static let controlsSlotHeight: CGFloat = 30

    /// 卡片顶边(屏幕坐标,y 向上)。槽位在上方时卡片在窗口顶边往下一个槽位。
    public static func cardTop(windowTop: CGFloat, controlsBelow: Bool) -> CGFloat {
        controlsBelow ? windowTop : windowTop - controlsSlotHeight
    }

    /// 卡片顶边落在 `cardTop` 时窗口顶边该在哪儿。
    public static func windowTop(cardTop: CGFloat, controlsBelow: Bool) -> CGFloat {
        controlsBelow ? cardTop : cardTop + controlsSlotHeight
    }

    /// 控制排该不该放到卡片下方:卡片上方放不下整个槽位(槽位会伸进可见区顶边以上、被菜单栏盖住)时放下方。
    /// 按卡片顶边判,别按窗口顶边判:那样卡片离菜单栏不到一个槽位的位置停不住(见 04 章决策 41)。
    public static func controlsBelowCard(cardTop: CGFloat, visibleTop: CGFloat) -> Bool {
        cardTop + controlsSlotHeight > visibleTop + 0.5
    }

    // MARK: - 松手护位(「自由」模式拖动)

    /// 拖动松手那一刻窗口的 x 和顶边。松手后系统会接着挪窗口(拖进菜单栏松手被摆到屏幕正中、拖到屏幕边缘
    /// 被平铺,窗口行为标志关不掉),`holdSeconds` 之内被挪走就挪回这里(见 04 章决策 41)。
    public struct ReleaseAnchor: Equatable {
        public static let holdSeconds: CFTimeInterval = 0.8
        public let x: CGFloat
        public let top: CGFloat
        public let until: CFTimeInterval

        public init(frame: CGRect, now: CFTimeInterval) {
            x = frame.minX
            top = frame.maxY
            until = now + Self.holdSeconds
        }

        public func expired(at now: CFTimeInterval) -> Bool { now > until }

        /// 窗口被挪走了就返回该挪回去的 origin,没挪返回 nil。只比 x 和顶边:换行变高守顶边,不算挪动;
        /// 挪回时按窗口当前的高度守顶边。
        public func restoredOrigin(for frame: CGRect) -> CGPoint? {
            guard abs(frame.minX - x) > 0.5 || abs(frame.maxY - top) > 0.5 else { return nil }
            return CGPoint(x: x, y: top - frame.height)
        }
    }
}
