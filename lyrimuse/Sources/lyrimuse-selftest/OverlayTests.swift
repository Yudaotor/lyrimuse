import LyrimuseCore
import Foundation

// 桌面悬浮歌词 / 歌词窗口的几何与命中测试。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runOverlayTests() {
    // ---- OverlayControlHitTest: 悬浮窗按钮的命中测试 ----
    // (2026-08-18 结构性改动:悬浮窗改成常年 ignoresMouseEvents=true,胶囊上五个按钮的点击
    // 由控制器拿全局鼠标监听的屏幕坐标比对矩形自己分发。这段判定是整条链路上唯一能脱离
    // 窗口/事件系统单独验证的部分。)

    do {
        // 按 HStack 排开的五个按钮:26/30/26 宽,间距 18,y 都一样。
        let rects: [OverlayControlID: CGRect] = [
            .previous: CGRect(x: 100, y: 200, width: 26, height: 26),
            .playPause: CGRect(x: 144, y: 198, width: 30, height: 30),
            .next: CGRect(x: 192, y: 200, width: 26, height: 26),
            .favorite: CGRect(x: 236, y: 200, width: 26, height: 26),
            .lock: CGRect(x: 299, y: 200, width: 26, height: 26),
        ]
        expectEqual(OverlayControlHitTest.control(at: CGPoint(x: 113, y: 213), in: rects), .previous,
                    "命中测试: 上一首中心")
        expectEqual(OverlayControlHitTest.control(at: CGPoint(x: 159, y: 213), in: rects), .playPause,
                    "命中测试: 播放/暂停中心")
        expectEqual(OverlayControlHitTest.control(at: CGPoint(x: 311, y: 213), in: rects), .lock,
                    "命中测试: 锁定中心")
        // 按钮之间的空隙(间距 18)不该命中任何一个 —— 否则点在缝里会误触发相邻按钮。
        expectEqual(OverlayControlHitTest.control(at: CGPoint(x: 135, y: 213), in: rects) == nil, true,
                    "命中测试: 两个按钮之间的空隙不命中")
        // 胶囊之外(比如歌词文字上)一律不命中 —— 那里要留给长按拖动。
        expectEqual(OverlayControlHitTest.control(at: CGPoint(x: 400, y: 300), in: rects) == nil, true,
                    "命中测试: 胶囊之外不命中")
        // 空表(控制排没显示)不命中 —— 控制器靠这个避免"看不见却挡手"。
        expectEqual(OverlayControlHitTest.control(at: CGPoint(x: 113, y: 213), in: [:]) == nil, true,
                    "命中测试: 没显示控制排时一个都不命中")
    }

    do {
        // 重叠时取面积最小的那个,而且结果必须**稳定** —— 字典遍历顺序不确定,"取第一个命中的"
        // 会让重叠情形随机命中,是最难查的一类 bug。跑多次断言结果一致。
        let overlapping: [OverlayControlID: CGRect] = [
            .previous: CGRect(x: 0, y: 0, width: 100, height: 100),
            .next: CGRect(x: 10, y: 10, width: 20, height: 20),
        ]
        var results = Set<OverlayControlID?>()
        for _ in 1...50 {
            results.insert(OverlayControlHitTest.control(at: CGPoint(x: 15, y: 15), in: overlapping))
        }
        expectEqual(results.count, 1, "命中测试: 重叠情形下结果必须稳定,不随字典顺序变")
        expectEqual(results.first ?? nil, .next, "命中测试: 重叠时命中面积更小的那个")
    }

    // ---- LyricDuetLayout: 对唱行的两侧内缩(2026-08-23) ----
    do {
        let L = LyricDuetLayout.self
        // 没有对唱信息的行一律 0 —— 普通歌的排版必须逐像素不变,这是回归护栏
        do {
            let i = L.insets(for: nil, availableWidth: 400, fontSize: 30)
            expectEqual(i.leading, 0, "对唱内缩: 无声部信息不留白(leading)")
            expectEqual(i.trailing, 0, "对唱内缩: 无声部信息不留白(trailing)")
        }
        // 左声部远侧(右边)留得比近侧(左边)多,右声部反过来——近侧非零是
        // 2026-08-26 加的:不让字贴着卡片真边缘,近侧永远是远侧的一半。
        do {
            let i = L.insets(for: .leading, availableWidth: 400, fontSize: 200)
            expectEqual(i.leading, 30, "对唱内缩: 左声部近侧(左边)也留,是远侧的一半")
            expectEqual(i.trailing, 60, "对唱内缩: 左声部远侧(右边)留 15%")
        }
        do {
            let i = L.insets(for: .trailing, availableWidth: 400, fontSize: 200)
            expectEqual(i.leading, 60, "对唱内缩: 右声部远侧(左边)留 15%")
            expectEqual(i.trailing, 30, "对唱内缩: 右声部近侧(右边)也留,是远侧的一半")
        }
        // 合唱两边都留 —— 它既不属于左也不属于右
        do {
            let i = L.insets(for: .center, availableWidth: 400, fontSize: 200)
            expectEqual(i.leading, 60, "对唱内缩: 合唱左边也留")
            expectEqual(i.trailing, 60, "对唱内缩: 合唱右边也留")
        }
        // 字号封顶接管:窗口很宽时 15% 会变成一大片空白,4 个字宽就够读出偏向了
        // (近侧同理按一半的字宽封顶)。
        do {
            let i = L.insets(for: .leading, availableWidth: 4000, fontSize: 30)
            expectEqual(i.trailing, 120, "对唱内缩: 宽窗口下远侧由 4 字宽封顶接管(不是 600)")
            expectEqual(i.leading, 60, "对唱内缩: 宽窗口下近侧由 2 字宽封顶接管(不是 300)")
        }
        // 退化输入不产生负值/NaN(近侧同步核一遍,不止远侧)
        do {
            let zeroWidth = L.insets(for: .leading, availableWidth: 0, fontSize: 30)
            expectEqual(zeroWidth.trailing, 0, "对唱内缩: 宽度为 0 时远侧不留白")
            expectEqual(zeroWidth.leading, 0, "对唱内缩: 宽度为 0 时近侧不留白")
            let negWidth = L.insets(for: .leading, availableWidth: -100, fontSize: 30)
            expectEqual(negWidth.trailing, 0, "对唱内缩: 负宽度远侧不产生负内缩")
            expectEqual(negWidth.leading, 0, "对唱内缩: 负宽度近侧不产生负内缩")
            let zeroFont = L.insets(for: .leading, availableWidth: 400, fontSize: 0)
            expectEqual(zeroFont.trailing, 0, "对唱内缩: 字号为 0 时远侧封顶为 0")
            expectEqual(zeroFont.leading, 0, "对唱内缩: 字号为 0 时近侧封顶为 0")
        }
        // 不变式:任意合法输入下远侧内缩必须 ≥ 近侧——分栏的方向感不能被磨平。
        do {
            for (w, f) in [(400.0, 200.0), (4000.0, 30.0), (100.0, 12.0), (1200.0, 48.0)] {
                let i = L.insets(for: .leading, availableWidth: w, fontSize: f)
                expectEqual(i.trailing >= i.leading, true,
                            "对唱内缩不变式(w=\(w),f=\(f)): 远侧(\(i.trailing)) 必须 ≥ 近侧(\(i.leading))")
            }
        }
    }

    // ---- OverlayDuetAlignmentOverride: 悬浮歌词「对齐方式」覆盖(2026-08-29,GitHub issue #2) ----
    do {
        typealias O = OverlayDuetAlignmentOverride
        let D = LyricDuet.Side.self
        // automatic:两个函数都等价于旧行为——对齐值原样兜底居中,装饰值原样传回。
        for real: LyricDuet.Side? in [nil, D.leading, D.trailing, D.center] {
            expectEqual(O.automatic.effectiveAlignmentSide(realSide: real), real ?? .center,
                        "覆盖-自动: 对齐值等价旧的 ?? .center 兜底(real=\(String(describing: real)))")
            expectEqual(O.automatic.effectiveDecorationSide(realSide: real), real,
                        "覆盖-自动: 装饰值原样传回(real=\(String(describing: real)))")
        }
        // 非自动:对齐值固定成选定的方向,不管真实声部是什么(包括完全没有对唱标记的普通歌)。
        for real: LyricDuet.Side? in [nil, D.leading, D.trailing, D.center] {
            expectEqual(O.center.effectiveAlignmentSide(realSide: real), .center,
                        "覆盖-居中: 对齐值恒为居中(real=\(String(describing: real)))")
            expectEqual(O.leading.effectiveAlignmentSide(realSide: real), .leading,
                        "覆盖-左对齐: 对齐值恒为左(real=\(String(describing: real)))")
            expectEqual(O.trailing.effectiveAlignmentSide(realSide: real), .trailing,
                        "覆盖-右对齐: 对齐值恒为右(real=\(String(describing: real)))")
        }
        // ⚠️ 核心安全约束:非自动时装饰值(两侧内缩+声部指示圆点用)必须恒为 nil——
        // 否则"左对齐"这种覆盖会让完全没有对唱标记的普通歌也冒出内缩和圆点,那不是
        // issue 要的效果(见 OverlayDuetAlignmentOverride 声明处注释)。
        for override in [O.center, O.leading, O.trailing] {
            for real: LyricDuet.Side? in [nil, D.leading, D.trailing, D.center] {
                expectEqual(override.effectiveDecorationSide(realSide: real), nil,
                            "覆盖-\(override): 装饰值恒为 nil,不管真实声部是什么(real=\(String(describing: real)))")
            }
        }
    }

    // ---- OverlayCardGeometry: 卡片内容块与它上方那排控制按钮的横向落点(2026-09-03) ----
    //
    // 用户实机反馈:「在对唱模式下,这个悬浮菜单不是显示对应歌词上面的,看起来是在整个窗口的
    // 居中位置」。控制排原来吃外层 VStack 默认的 .center,而卡片按声部靠边 —— 对唱歌一把歌词
    // 甩到右半边就差出大半个窗宽。这一组钉的就是"两者贴同一条边"这条不变式:算法只有几行,
    // 但它必须跟卡片那一边逐字一致,而本仓已经为"同一个视觉属性两条渲染路径"付过三次账
    // (第 04 章:预览条对齐写死 leading / 灵动岛手搓预览 / 编辑台简化复刻件)。
    do {
        let G = OverlayCardGeometry.self
        let D = LyricDuet.Side.self
        // 1016pt 窗宽 / 31pt 字号那一档的实测 unit;具体数值不重要,不变式才重要。
        let unit: CGFloat = 124
        // = OverlayPlayback.cardHorizontalPadding(那个常量在 App target 里,core 侧拿不到)。
        let pad: CGFloat = 20

        // 卡片内缩:只留远侧那一份。nil = 没有对唱信息(普通歌的每一行、对唱歌第一个标记
        // 之前的前奏、非自动的「对齐方式」覆盖)——两侧恒为 0,普通歌排版逐像素不变。
        expectEqual(G.cardInsets(for: nil, unit: unit).leading, 0, "卡片内缩: 无声部时左侧 0")
        expectEqual(G.cardInsets(for: nil, unit: unit).trailing, 0, "卡片内缩: 无声部时右侧 0")
        expectEqual(G.cardInsets(for: D.leading, unit: unit).leading, 0, "卡片内缩: 左声部近侧不留")
        expectEqual(G.cardInsets(for: D.leading, unit: unit).trailing, unit, "卡片内缩: 左声部远侧留满")
        expectEqual(G.cardInsets(for: D.trailing, unit: unit).leading, unit, "卡片内缩: 右声部远侧留满")
        expectEqual(G.cardInsets(for: D.trailing, unit: unit).trailing, 0, "卡片内缩: 右声部近侧不留")
        expectEqual(G.cardInsets(for: D.center, unit: unit).leading, unit, "卡片内缩: 合唱两侧都留(左)")
        expectEqual(G.cardInsets(for: D.center, unit: unit).trailing, unit, "卡片内缩: 合唱两侧都留(右)")

        // ⚠️ 核心不变式:控制排的两侧留白 = 卡片内缩 + 卡片水平内边距。两者再按同一个方向
        // 靠边,按钮排的近侧边缘就跟歌词块的近侧边缘严格重合 —— 这条一破,控制排立刻又不在
        // "对应歌词上面"了,而这种偏移只有对唱歌才看得见,极易漏到用户截图里才发现。
        for side: LyricDuet.Side? in [nil, D.leading, D.trailing, D.center] {
            let card = G.cardInsets(for: side, unit: unit)
            let ctrl = G.controlsInsets(for: side, unit: unit, cardHorizontalPadding: pad)
            let tag = String(describing: side)
            expectEqual(ctrl.leading - card.leading, pad, "控制排落点: 左侧比卡片多且只多一份内边距(side=\(tag))")
            expectEqual(ctrl.trailing - card.trailing, pad, "控制排落点: 右侧比卡片多且只多一份内边距(side=\(tag))")
        }

        // 回归护栏:没有对唱信息(绝大多数歌)和真正的合唱,两侧留白必须**对称** —— 这两种
        // 情况对齐方向都是 .center,对称才能保证控制排的位置跟"这次改动之前"逐像素相同。
        for side: LyricDuet.Side? in [nil, D.center] {
            let ctrl = G.controlsInsets(for: side, unit: unit, cardHorizontalPadding: pad)
            expectEqual(ctrl.leading, ctrl.trailing,
                        "控制排落点: 无声部/合唱两侧对称,居中位置跟改动前不变(side=\(String(describing: side)))")
        }

        // 「对齐方式」覆盖生效时(非自动),装饰声部恒为 nil —— 控制排跟卡片一起退回"当成
        // 普通歌",两侧只剩卡片内边距,不会因为用户选了左/右对齐就凭空缩进一大块。
        for override in [OverlayDuetAlignmentOverride.center, .leading, .trailing] {
            for real: LyricDuet.Side? in [nil, D.leading, D.trailing, D.center] {
                let decoration = override.effectiveDecorationSide(realSide: real)
                let ctrl = G.controlsInsets(for: decoration, unit: unit, cardHorizontalPadding: pad)
                expectEqual(ctrl.leading, pad,
                            "控制排落点: 覆盖-\(override) 下左侧只剩卡片内边距(real=\(String(describing: real)))")
                expectEqual(ctrl.trailing, pad,
                            "控制排落点: 覆盖-\(override) 下右侧只剩卡片内边距(real=\(String(describing: real)))")
            }
        }
    }

    // ---- OverlayControlHitTest.windowLocalRect:SwiftUI 矩形 → AppKit 窗口本地 ----
    //
    // 2026-08-23 抽出来的:这套换算原先在控制器里抄了三遍(按钮矩形/控制热区/歌词热区),
    // 而且三处都把结果**直接转成屏幕坐标存起来** —— 窗口一移动,SwiftUI 布局没变、
    // PreferenceKey 不重发,存的屏幕坐标就还停在旧位置,按钮和热区当场失效
    // (用户报的「移动之后按钮会失效」)。现在只存窗口本地坐标,判定时把鼠标点转进来。
    do {
        let H = OverlayControlHitTest.self
        // y 翻转:SwiftUI 的 y 从顶部往下,AppKit 从底部往上
        expectEqual(H.windowLocalRect(swiftUI: CGRect(x: 10, y: 0, width: 30, height: 20), windowHeight: 100),
                    CGRect(x: 10, y: 80, width: 30, height: 20), "窗口本地: 贴顶的矩形翻到贴顶(y=80)")
        expectEqual(H.windowLocalRect(swiftUI: CGRect(x: 10, y: 80, width: 30, height: 20), windowHeight: 100),
                    CGRect(x: 10, y: 0, width: 30, height: 20), "窗口本地: 贴底的矩形翻到 y=0")
        // x 和尺寸不动
        expectEqual(H.windowLocalRect(swiftUI: CGRect(x: 7, y: 30, width: 13, height: 5), windowHeight: 60).minX,
                    7, "窗口本地: x 不变")
        expectEqual(H.windowLocalRect(swiftUI: CGRect(x: 7, y: 30, width: 13, height: 5), windowHeight: 60).width,
                    13, "窗口本地: 宽不变")
        // 翻两次回到原处 —— 换算是自逆的
        do {
            let a = CGRect(x: 4, y: 12, width: 20, height: 8)
            let once = H.windowLocalRect(swiftUI: a, windowHeight: 50)
            expectEqual(H.windowLocalRect(swiftUI: once, windowHeight: 50), a, "窗口本地: 翻两次回到原处")
        }
    }

    // ---- WrapLayoutMath ----
    //
    // 逐字歌词那个自动换行容器的几何。以前长在 LyricsOverlayView 里，改一次就只能盯屏幕看。
    do {
        func sz(_ w: CGFloat, _ h: CGFloat = 10) -> CGSize { CGSize(width: w, height: h) }
        func rowIndices(_ rows: [WrapLayoutMath.Row]) -> [[Int]] { rows.map { $0.indices } }

        // 装得下就一行。
        expectEqual(rowIndices(WrapLayoutMath.rows(sizes: [sz(10), sz(10), sz(10)], maxWidth: 100, horizontalSpacing: 0)),
                    [[0, 1, 2]], "WrapLayout: 装得下就一行")

        // 装不下就换行。
        expectEqual(rowIndices(WrapLayoutMath.rows(sizes: [sz(60), sz(60), sz(60)], maxWidth: 100, horizontalSpacing: 0)),
                    [[0], [1], [2]], "WrapLayout: 装不下逐个换行")

        // 间距要算进"还装不装得下"里：3 个 30 宽 + 2 个 10 间距 = 110 > 100。
        expectEqual(rowIndices(WrapLayoutMath.rows(sizes: [sz(30), sz(30), sz(30)], maxWidth: 100, horizontalSpacing: 10)),
                    [[0, 1], [2]], "WrapLayout: 间距要计入换行判断")

        // ⚠️ 单个元素本身就超宽时，必须独占一行且**保留**——这正是"长歌词行整行变成一串
        // 省略号"那个 bug 的修法。谁要是在这里加个"太宽就跳过"，这条会立刻红。
        expectEqual(rowIndices(WrapLayoutMath.rows(sizes: [sz(500)], maxWidth: 100, horizontalSpacing: 0)),
                    [[0]], "WrapLayout: 单个超宽元素独占一行,不能被丢掉")
        expectEqual(rowIndices(WrapLayoutMath.rows(sizes: [sz(10), sz(500), sz(10)], maxWidth: 100, horizontalSpacing: 0)),
                    [[0], [1], [2]], "WrapLayout: 超宽元素夹在中间也不丢")

        // 空输入不该炸，也不该造出一个空行。
        expectEqual(WrapLayoutMath.rows(sizes: [], maxWidth: 100, horizontalSpacing: 0).count, 0,
                    "WrapLayout: 空输入没有行")

        // 行高取本行最高的那个；总高度 = 各行行高 + 行距。
        let twoRows = WrapLayoutMath.totalSize(
            sizes: [sz(60, 20), sz(60, 30)], maxWidth: 100, horizontalSpacing: 0, verticalSpacing: 5)
        expectEqual(twoRows, CGSize(width: 100, height: 55), "WrapLayout: 两行高度 = 20+30+5 行距")

        // 三种对齐：同一行内容宽 60、容器宽 100，剩 40 的空隙。
        func firstX(_ alignment: WrapLayoutMath.RowAlignment) -> CGFloat {
            WrapLayoutMath.placements(
                sizes: [sz(60)], bounds: CGRect(x: 0, y: 0, width: 100, height: 50),
                horizontalSpacing: 0, verticalSpacing: 0, rowAlignment: alignment
            ).first?.origin.x ?? -1
        }
        expectEqual(firstX(.leading), 0, "WrapLayout: leading 贴左")
        expectEqual(firstX(.center), 20, "WrapLayout: center 居中")
        expectEqual(firstX(.trailing), 40, "WrapLayout: trailing 贴右")

        // bounds 不是从原点开始时，位置要跟着平移（悬浮窗里就不是原点）。
        let offsetPlacement = WrapLayoutMath.placements(
            sizes: [sz(60)], bounds: CGRect(x: 7, y: 3, width: 100, height: 50),
            horizontalSpacing: 0, verticalSpacing: 0, rowAlignment: .leading).first
        expectEqual(offsetPlacement?.origin.x, 7, "WrapLayout: 位置跟随 bounds.minX")

        // 行内竖直居中：本行高 30，这个元素高 10，应该往下让 10。
        let vcenter = WrapLayoutMath.placements(
            sizes: [sz(10, 10), sz(10, 30)], bounds: CGRect(x: 0, y: 0, width: 100, height: 50),
            horizontalSpacing: 0, verticalSpacing: 0, rowAlignment: .leading)
        expectEqual(vcenter.first?.origin.y, 10, "WrapLayout: 矮的元素在行内竖直居中")

        // 全局不变式：顺序保持、每个元素都被放置、不会超出 bounds 左边界、y 不倒退。
        var orderOK = true, allPlaced = true, noLeftOverflow = true, noOverlap = true
        for count in 1...12 {
            var sizes: [CGSize] = []
            for i in 0..<count {
                let w: CGFloat = CGFloat(20 + (i * 13) % 70)
                let h: CGFloat = CGFloat(10 + (i * 7) % 20)
                sizes.append(sz(w, h))
            }
            for alignment in [WrapLayoutMath.RowAlignment.leading, .center, .trailing] {
                let bounds = CGRect(x: 5, y: 5, width: 120, height: 500)
                let ps = WrapLayoutMath.placements(
                    sizes: sizes, bounds: bounds, horizontalSpacing: 3, verticalSpacing: 2,
                    rowAlignment: alignment)
                if ps.count != sizes.count { allPlaced = false }
                let indices: [Int] = ps.map { $0.index }
                if indices != Array(0..<sizes.count) { orderOK = false }
                for p in ps where p.origin.x < bounds.minX - 1e-9 { noLeftOverflow = false }
                // 不许有任何两个元素叠在一起。比"y 单调"强,也比它正确 —— 行内是**竖直
                // 居中**的,同一行里矮的元素 y 本来就比高的大,逐个比 y 会误判成倒退。
                for a in 0..<ps.count {
                    for b in (a + 1)..<ps.count {
                        let ra = CGRect(origin: ps[a].origin, size: ps[a].size)
                        let rb = CGRect(origin: ps[b].origin, size: ps[b].size)
                        if ra.insetBy(dx: 1e-6, dy: 1e-6).intersects(rb.insetBy(dx: 1e-6, dy: 1e-6)) {
                            noOverlap = false
                        }
                    }
                }
            }
        }
        expectEqual(allPlaced, true, "WrapLayout: 每个元素都要被放置,一个都不能少")
        expectEqual(orderOK, true, "WrapLayout: 顺序必须保持")
        expectEqual(noLeftOverflow, true, "WrapLayout: 不会跑到 bounds 左边界外")
        expectEqual(noOverlap, true, "WrapLayout: 任意两个元素都不重叠")

        // ---- contentBounds:文字真正占据的矩形(给「指针划过歌词才让开」当命中判据) ----
        //
        // 跟 totalSize 是两回事:那个恒返回 maxWidth(撑满是刻意的,对唱左右对齐要靠它),
        // 这个返回内容自己的包围盒。原来 hover 判据是整个窗口矩形,指针在歌词**附近**的
        // 空白处就触发淡出(2026-08-23 用户报的)。
        do {
            let bounds = CGRect(x: 0, y: 0, width: 200, height: 40)
            // 单行、宽 60:三种对齐分别贴左 / 居中 / 贴右
            let one = WrapLayoutMath.rows(sizes: [sz(60, 20)], maxWidth: 200, horizontalSpacing: 0)
            expectEqual(
                WrapLayoutMath.contentBounds(rows: one, bounds: bounds, verticalSpacing: 2, rowAlignment: .leading),
                CGRect(x: 0, y: 0, width: 60, height: 20), "内容矩形: 靠左时贴左缘")
            expectEqual(
                WrapLayoutMath.contentBounds(rows: one, bounds: bounds, verticalSpacing: 2, rowAlignment: .center),
                CGRect(x: 70, y: 0, width: 60, height: 20), "内容矩形: 居中时两边等分")
            expectEqual(
                WrapLayoutMath.contentBounds(rows: one, bounds: bounds, verticalSpacing: 2, rowAlignment: .trailing),
                CGRect(x: 140, y: 0, width: 60, height: 20), "内容矩形: 靠右时贴右缘")
            // 多行:宽度取最宽那行,高度含行距
            let two = WrapLayoutMath.rows(sizes: [sz(120, 20), sz(120, 20)], maxWidth: 150, horizontalSpacing: 0)
            expectEqual(two.count, 2, "内容矩形: 前置条件——两个 120 宽在 150 里装不下,折成两行")
            expectEqual(
                WrapLayoutMath.contentBounds(rows: two, bounds: CGRect(x: 0, y: 0, width: 150, height: 50),
                                             verticalSpacing: 2, rowAlignment: .leading),
                CGRect(x: 0, y: 0, width: 120, height: 42), "内容矩形: 多行取最宽行 + 行距计入高度")
            // bounds 原点非零时跟着平移
            expectEqual(
                WrapLayoutMath.contentBounds(rows: one, bounds: CGRect(x: 30, y: 7, width: 200, height: 40),
                                             verticalSpacing: 2, rowAlignment: .leading),
                CGRect(x: 30, y: 7, width: 60, height: 20), "内容矩形: 跟随 bounds 原点平移")
            // 退化输入不产生垃圾矩形
            expectEqual(
                WrapLayoutMath.contentBounds(rows: [], bounds: bounds, verticalSpacing: 2, rowAlignment: .center),
                .zero, "内容矩形: 没有行时返回 zero")
            // 内容比容器宽时钳到容器宽(不往外溢出,否则热区会盖到窗口之外)
            let wide = WrapLayoutMath.rows(sizes: [sz(300, 20)], maxWidth: 200, horizontalSpacing: 0)
            expectEqual(
                WrapLayoutMath.contentBounds(rows: wide, bounds: bounds, verticalSpacing: 2, rowAlignment: .leading).width,
                200, "内容矩形: 单个超宽子视图不让矩形溢出容器")
        }

    }

    // ---- OverlayPlacement ----
    //
    // 拔掉外接屏之后悬浮窗还找得回来吗。这台开发机只有一块内置屏，"两块屏拔掉一块"没法真机
    // 复现，这些断言是唯一覆盖它的手段。
    do {
        let mainScreen = CGRect(x: 0, y: 0, width: 1470, height: 900)
        let secondScreen = CGRect(x: 1470, y: 0, width: 1920, height: 1080)
        let overlaySize = CGSize(width: 900, height: 166)

        // 窗口好端端待在主屏上：不该动它。
        let onMain = CGRect(origin: CGPoint(x: 285, y: 700), size: overlaySize)
        expectEqual(OverlayPlacement.repositionIfOffscreen(frame: onMain, screens: [mainScreen]) == nil, true,
                    "OverlayPlacement: 窗口在屏内不动它")

        // 窗口在副屏上，两块屏都在：同样不该动。
        let onSecond = CGRect(origin: CGPoint(x: 1600, y: 100), size: overlaySize)
        expectEqual(
            OverlayPlacement.repositionIfOffscreen(frame: onSecond, screens: [mainScreen, secondScreen]) == nil, true,
            "OverlayPlacement: 窗口在副屏上、副屏还在,不动它")

        // 同一个窗口，副屏被拔掉 —— 这就是这次要修的场景。
        let rescued = OverlayPlacement.repositionIfOffscreen(frame: onSecond, screens: [mainScreen])
        expectEqual(rescued?.x, 570, "OverlayPlacement: 拔掉副屏后夹回主屏右边界内 (1470-900)")
        expectEqual(rescued?.y, 100, "OverlayPlacement: y 本来就在范围内,保持不变")

        // 保守判据：用户主动把窗口拖到边缘、只露一部分，是正常用法，不许"纠正"。
        // 露出 200pt 宽，远超 60pt 阈值。
        let mostlyOff = CGRect(origin: CGPoint(x: 1270, y: 700), size: overlaySize)
        expectEqual(OverlayPlacement.repositionIfOffscreen(frame: mostlyOff, screens: [mainScreen]) == nil, true,
                    "OverlayPlacement: 只露一部分但够得着,不动它")

        // 只剩 30pt 露在屏内，低于 60pt 阈值 → 救回来。
        let slivered = CGRect(origin: CGPoint(x: 1440, y: 700), size: overlaySize)
        expectEqual(OverlayPlacement.repositionIfOffscreen(frame: slivered, screens: [mainScreen]) != nil, true,
                    "OverlayPlacement: 只剩一丝可见时救回来")

        // 窗口比屏幕还宽：夹取不能把它推到右边界外面去（先 max 再 min 的顺序问题）。
        let tooWide = CGRect(x: 3000, y: 100, width: 2000, height: 166)
        let clampedWide = OverlayPlacement.clamped(frame: tooWide, into: mainScreen)
        expectEqual(clampedWide.x, 0, "OverlayPlacement: 比屏还宽时贴左边,不能被推出右边界")

        // 屏幕原点不是 (0,0) 时也要跟着走（多屏排列里副屏常有负坐标）。
        let leftScreen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let strayFrame = CGRect(x: -5000, y: 0, width: 900, height: 166)
        expectEqual(OverlayPlacement.clamped(frame: strayFrame, into: leftScreen).x, -1920,
                    "OverlayPlacement: 夹取跟随屏幕自己的原点,不假设从 0 开始")

        // 窗口比阈值还小时，阈值要退让到窗口尺寸，否则它永远判不出"可见"。
        let tiny = CGRect(x: 10, y: 10, width: 20, height: 10)
        expectEqual(OverlayPlacement.isSufficientlyVisible(frame: tiny, screens: [mainScreen]), true,
                    "OverlayPlacement: 比阈值还小的窗口只要整个在屏内就算可见")

        // 一块屏都没有（理论上不会发生）时别崩、别乱动。
        expectEqual(OverlayPlacement.repositionIfOffscreen(frame: onMain, screens: []) == nil, true,
                    "OverlayPlacement: 没有任何屏幕时不动")

        // 夹取结果跟原位置相同时不返回移动 —— 免得白白触发一次位置持久化。
        let exactlyAtEdge = CGRect(origin: CGPoint(x: 570, y: 100), size: overlaySize)
        expectEqual(OverlayPlacement.repositionIfOffscreen(frame: exactlyAtEdge, screens: [mainScreen]) == nil, true,
                    "OverlayPlacement: 已经在合法位置时不发多余的移动")
    }

    // ---- OverlayPlacement:启动还原不许跨屏搬家(2026-08-21) ----
    //
    // 用户主诉"悬浮歌词经常在我主屏幕和副屏幕之间切换位置"的那条根因。几何全部取自这台机器的
    // 真实读数,不是编的:
    //   内置屏 visibleFrame = (0, 70, 1470, 853)      ← NSScreen.main
    //   外接屏 visibleFrame = (-526, 956, 2560, 1440)
    //   盘上锚点 np:overlayPositionTop = "849.0,1202.0"(x, 顶边),窗口宽 900、初始高 120
    // 旧代码在 restoredOrigin 里把这个锚点无条件夹进 NSScreen.main.visibleFrame,于是每次启动
    // 都把好端端待在外接屏上的窗口拽回内置屏 (570, 803);用户拖回去,下次启动再拽一次。
    do {
        let builtIn = CGRect(x: 0, y: 70, width: 1470, height: 853)
        let external = CGRect(x: -526, y: 956, width: 2560, height: 1440)
        let size = CGSize(width: 900, height: 120)
        // 锚点存的是顶边,还原成 AppKit 的左下角 origin:1202 − 120 = 1082。
        let saved = CGRect(origin: CGPoint(x: 849, y: 1082), size: size)

        // 两块屏都在 → 原样保留,一个点都不许动(这是这次修的主判据)。
        let kept = OverlayPlacement.restored(frame: saved, screens: [builtIn, external])
        expectEqual(kept.origin.x, 849, "OverlayPlacement: 副屏上的锚点原样保留 x")
        expectEqual(kept.origin.y, 1082, "OverlayPlacement: 副屏上的锚点原样保留 y")
        expectEqual(kept.wasRescued, false, "OverlayPlacement: 看得见就不算救援")

        // 外接屏不在了(拔掉/休眠)→ 才允许借主屏摆,并且标记成"借来的"(调用方据此不写盘)。
        let rescued = OverlayPlacement.restored(frame: saved, screens: [builtIn])
        expectEqual(rescued.origin.x, 570, "OverlayPlacement: 一块屏都看不见时夹回主屏 (1470-900)")
        expectEqual(rescued.origin.y, 803, "OverlayPlacement: 一块屏都看不见时夹回主屏 (923-120)")
        expectEqual(rescued.wasRescued, true, "OverlayPlacement: 借屏落位必须标记出来")

        // 一块屏都枚举不到(理论上不会发生)→ 原样返回,别摆到凭空算出来的坐标上。
        let noScreens = OverlayPlacement.restored(frame: saved, screens: [])
        expectEqual(noScreens.origin.y, 1082, "OverlayPlacement: 没有屏幕时不动锚点")
        expectEqual(noScreens.wasRescued, false, "OverlayPlacement: 没有屏幕时不算救援")

        // hostVisibleFrame:窗口自身的钳制要按**它落在的那块屏**算,不是按 NSScreen.main。
        let host = OverlayPlacement.hostVisibleFrame(of: saved, screens: [builtIn, external])
        expectEqual(host?.minY, 956, "OverlayPlacement: 副屏上的窗口拿到副屏的可见区域")
        // 跨在两块屏之间时取相交面积大的那块:内置屏 200×23=4600,外接屏 200×144=28800。
        let straddling = CGRect(x: 0, y: 900, width: 200, height: 200)
        expectEqual(OverlayPlacement.hostVisibleFrame(of: straddling, screens: [builtIn, external])?.minY, 956,
                    "OverlayPlacement: 跨屏时取相交面积更大的那块")
        // 一块都不沾 → nil,调用方据此"那就不夹了",而不是硬按主屏算把窗口往主屏方向推。
        let nowhere = CGRect(x: 9000, y: 9000, width: 100, height: 100)
        expectEqual(OverlayPlacement.hostVisibleFrame(of: nowhere, screens: [builtIn, external]) == nil, true,
                    "OverlayPlacement: 不沾任何屏时没有可信边界")
    }

    // ---- 圆钮块的短按 / 长按 / 右键判定(2026-08-19) ----
    //
    // 菜单栏面板里那三个「歌词展示形态」的格子:短按 = 开关,长按或右键 = 展开它自己的快捷
    // 设置。真正容易写错的只有一点 —— **长按已经触发过之后,松手不能再当短按用一次**
    // (SwiftUI Button 的 action 认的就是松手,这也是那些格子不再用 Button 的原因)。

    do {
        func run(_ events: [TilePressState.Event]) -> [TilePressState.Action] {
            var state = TilePressState()
            return events.map { state.handle($0) }
        }

        expectEqual(run([.down, .up]), [.none, .primary], "钮块: 按下松开 = 主动作")
        expectEqual(run([.down, .holdElapsed]), [.none, .secondary], "钮块: 按住到点 = 快捷设置")
        expectEqual(run([.down, .holdElapsed, .up]), [.none, .secondary, .none],
                    "钮块: 长按之后松手不再补一次主动作")
        expectEqual(run([.secondaryClick]), [.secondary], "钮块: 右键直接进快捷设置")
        expectEqual(run([.down, .secondaryClick, .up]), [.none, .secondary, .none],
                    "钮块: 左键按着时右键 = 只出快捷设置")
        expectEqual(run([.down, .dragOutside, .up]), [.none, .none, .none],
                    "钮块: 拖出格子再松手什么都不做")
        expectEqual(run([.down, .dragOutside, .holdElapsed]), [.none, .none, .none],
                    "钮块: 拖出去之后晚到的长按计时器不算")
        expectEqual(run([.down, .dragOutside, .dragInside, .up]), [.none, .none, .none, .primary],
                    "钮块: 拖出去又拖回来,松手仍算主动作(跟原生按钮一致)")
        expectEqual(run([.down, .up, .up]), [.none, .primary, .none],
                    "钮块: 同一轮不会放出两次主动作")
        expectEqual(run([.down, .up, .down, .up]), [.none, .primary, .none, .primary],
                    "钮块: 下一轮按下重新计数")

        // 按压态视觉:按下亮、拖出去灭、拖回来又亮、长按到点即灭(此时快捷设置已经顶上来了)。
        var visual = TilePressState()
        _ = visual.handle(.down)
        expectEqual(visual.isPressing, true, "钮块: 按下进按压态")
        _ = visual.handle(.dragOutside)
        expectEqual(visual.isPressing, false, "钮块: 拖出格子退出按压态")
        _ = visual.handle(.dragInside)
        expectEqual(visual.isPressing, true, "钮块: 拖回格子重回按压态")
        _ = visual.handle(.holdElapsed)
        expectEqual(visual.isPressing, false, "钮块: 长按触发后退出按压态")
    }

    // MARK: - ProgressFillGeometry:歌词窗口进度条"已播段"的移出量
    //
    // 2026-08-22 新增。用户报「进度条有时候会变成方的,不是弧形」——根因是上一版用
    // scaleEffect(x: f) 横向压缩满宽胶囊,把两端圆头一起压扁,f 越小越方。现在改成满宽 +
    // offset 移出 + 固定胶囊裁剪,圆头形状与 f 无关。这里钉住那个移出量,尤其是两头的夹值。
    do {
        typealias G = ProgressFillGeometry
        let w: CGFloat = 300

        // ① 常规刻度:可见宽 = 容器宽 × f,移出量是补数
        expectEqual(G.visibleWidth(containerWidth: w, fraction: 0.5), 150, "可见宽 = w×f")
        expectEqual(G.leadingOffset(containerWidth: w, fraction: 0.5), 150, "移出量 = w - 可见宽")
        expectEqual(G.visibleWidth(containerWidth: w, fraction: 1), 300, "播完:整条可见")
        expectEqual(G.leadingOffset(containerWidth: w, fraction: 1), 0, "播完:不移出")

        // ② 下限:f=0 也要留一个 4pt 见方的小圆点,不能缩没
        expectEqual(G.visibleWidth(containerWidth: w, fraction: 0), G.minimumVisibleWidth,
                    "f=0 留下限那一小截")
        expectEqual(G.leadingOffset(containerWidth: w, fraction: 0), 296, "f=0 的移出量 = w - 4")
        // 用户截图那一档(3 分钟的歌播到 0:04,f≈0.022):真实可见宽 6.6pt,已超过下限
        expectEqual(G.visibleWidth(containerWidth: w, fraction: 0.022) > G.minimumVisibleWidth, true,
                    "f≈0.022 时用真实宽度而不是下限")

        // ③ 越界的 fraction 一律夹回 [0,1],不靠调用点保证
        expectEqual(G.visibleWidth(containerWidth: w, fraction: -1), G.minimumVisibleWidth,
                    "负 fraction 夹成 0")
        expectEqual(G.visibleWidth(containerWidth: w, fraction: 2), 300, "超 1 的 fraction 夹成 1")

        // ④ 退化容器:这层 min 是防 offset 变成正数把填充往右推、露出胶囊左半截
        expectEqual(G.visibleWidth(containerWidth: 2, fraction: 0), 2,
                    "容器比下限还窄:可见宽夹到容器宽,不是 4")
        expectEqual(G.leadingOffset(containerWidth: 2, fraction: 0), 0,
                    "退化容器的移出量必须 >= 0(负数会把填充往右推)")
        expectEqual(G.visibleWidth(containerWidth: 0, fraction: 0.5), 0, "容器宽 0(首帧):不画")
        expectEqual(G.leadingOffset(containerWidth: 0, fraction: 0.5), 0, "容器宽 0:移出量 0")

        // ⑤ 移出量恒非负 —— 这是 offset 方向正确的前提,扫一遍网格
        var negatives = 0
        for wi in [0, 1, 2, 4, 8, 120, 300, 900] as [CGFloat] {
            for fi in [-0.5, 0, 0.001, 0.022, 0.5, 0.999, 1, 1.5] as [CGFloat] {
                if G.leadingOffset(containerWidth: wi, fraction: fi) < 0 { negatives += 1 }
            }
        }
        expectEqual(negatives, 0, "移出量在 8×8 组容器宽/进度组合上恒非负")
    }
}
