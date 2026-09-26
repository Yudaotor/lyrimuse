import LyrimuseCore
import Foundation

// 桌面悬浮歌词 / 歌词窗口的几何与命中测试。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runOverlayTests() {
    // ---- GapDotsCurve.opacityKeyframes:间奏三点交给 Core Animation 的亮度关键帧 ----
    do {
        let start = 10_000, end = 22_000
        for dot in 0..<GapDotsCurve.dotCount {
            for from in [10_000.0, 13_500.0, 17_000.0, 21_999.0] {
                let frames = GapDotsCurve.opacityKeyframes(dot: dot, startMs: start, endMs: end, fromMs: from)
                expectEqual(frames.first?.ms, from, "间奏三点关键帧: 从装动画那一刻起排(dot \(dot) from \(from))")
                expectEqual(frames.last?.ms, Double(end), "间奏三点关键帧: 排到间奏结束")
                // 关键帧之间线性插值必须逐点等于现算的 opacity —— 这正是「4 个关键帧就精确」的前提。
                var exact = true
                var t = from
                while t <= Double(end) {
                    let k = frames.lastIndex(where: { $0.ms <= t }) ?? 0
                    let a = frames[k], b = frames[min(k + 1, frames.count - 1)]
                    let f = b.ms > a.ms ? (t - a.ms) / (b.ms - a.ms) : 0
                    let interp = a.opacity + (b.opacity - a.opacity) * f
                    let want = GapDotsCurve.opacity(dot: dot, progress: GapDotsCurve.progress(posMs: Int(t), startMs: start, endMs: end))
                    if abs(interp - want) > 0.002 { exact = false }
                    t += 37
                }
                expectEqual(exact, true, "间奏三点关键帧: 线性插值逐点等于现算亮度(dot \(dot) from \(from))")
            }
        }
        expectEqual(GapDotsCurve.opacityKeyframes(dot: 0, startMs: start, endMs: end, fromMs: 22_000).isEmpty, true,
                    "间奏三点关键帧: 已到结束时间不排")
    }

    // ---- WindowCoverage:几乎被别的窗口整扇盖住(补 occlusionState 的盲区) ----
    do {
        // 实测那组几何:歌词窗口 (0,33,1470×863),终端只盖到 y=880,底下露一条 16pt 的缝。
        let lw = CGRect(x: 0, y: 33, width: 1470, height: 863)
        let term = CGRect(x: 0, y: 33, width: 1470, height: 847)
        expectEqual(WindowCoverage.isEffectivelyHidden(target: lw, covers: [term]), true,
                    "窗口遮挡: 只露一条 16pt 的缝(实测那组)算看不见")
        expectEqual(WindowCoverage.isEffectivelyHidden(target: lw, covers: []), false,
                    "窗口遮挡: 没有遮挡物时可见")
        expectEqual(WindowCoverage.isEffectivelyHidden(target: lw, covers: [lw]), true,
                    "窗口遮挡: 整扇盖住算看不见")
        let fortyGap = CGRect(x: 0, y: 33, width: 1470, height: 823)
        expectEqual(WindowCoverage.isEffectivelyHidden(target: lw, covers: [fortyGap]), false,
                    "窗口遮挡: 露一条 40pt(一行歌词露得出来)仍算可见")
        let far = CGRect(x: 2000, y: 0, width: 800, height: 600)
        expectEqual(WindowCoverage.isEffectivelyHidden(target: lw, covers: [far]), false,
                    "窗口遮挡: 不相交的窗口不算遮挡")
        // 两扇窗拼起来盖住:左右各一半,中间不留缝。
        let left = CGRect(x: 0, y: 0, width: 735, height: 1000)
        let right = CGRect(x: 735, y: 0, width: 735, height: 1000)
        expectEqual(WindowCoverage.isEffectivelyHidden(target: lw, covers: [left, right]), true,
                    "窗口遮挡: 两扇窗拼起来整扇盖住也算")
        let area = WindowCoverage.uncoveredArea(target: lw, covers: [term])
        expectEqual(abs(area - 1470 * 16) < 1470 * 4, true, "窗口遮挡: 露出面积 ≈ 1470×16(实测 \(area))")
    }

    // ---- OverlayControlHitTest: 悬浮窗按钮的命中测试 ----
    // (结构性改动:悬浮窗改成常年 ignoresMouseEvents=true,胶囊上五个按钮的点击
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

    // ---- OverlayControlHitTest.hoveredControl: 该把哪一颗按钮画亮 ----
    //
    // 跟上面"点击派给谁"是两个问题:点击本来就只在按钮显示时才分发,而这个每次鼠标移动都要
    // 求值,可见性得它自己兜住 —— 画亮一颗其实没显示的按钮是"看得见的 bug"。
    do {
        let rects: [OverlayControlID: CGRect] = [
            .playPause: CGRect(x: 144, y: 198, width: 30, height: 30),
            .unlockPill: CGRect(x: 240, y: 198, width: 22, height: 22),
        ]
        let onPlay = CGPoint(x: 159, y: 213)
        let onUnlock = CGPoint(x: 251, y: 209)
        let H = OverlayControlHitTest.self

        expectEqual(H.hoveredControl(at: onPlay, in: rects, insideWindow: true, positionLocked: false,
                                     hoverControlsEnabled: true),
                    .playPause, "悬停高亮: 压在播放键上就亮播放键")
        // 窗口常年点击穿透、监听器是全局的:指针早跑到别的 App 上去了照样有事件进来。
        expectEqual(H.hoveredControl(at: onPlay, in: rects, insideWindow: false, positionLocked: false,
                                     hoverControlsEnabled: true) == nil,
                    true, "悬停高亮: 指针不在窗口里就不亮(全局监听器照样会送事件进来)")
        // 锁定态那一格只画得出解锁一颗,别的矩形是上一轮布局的残留。
        expectEqual(H.hoveredControl(at: onPlay, in: rects, insideWindow: true, positionLocked: true,
                                     hoverControlsEnabled: true) == nil,
                    true, "悬停高亮: 锁定态不认播放键(那颗此刻根本没画出来)")
        expectEqual(H.hoveredControl(at: onUnlock, in: rects, insideWindow: true, positionLocked: true,
                                     hoverControlsEnabled: true),
                    .unlockPill, "悬停高亮: 锁定态只认解锁键")
        expectEqual(H.hoveredControl(at: onUnlock, in: rects, insideWindow: true, positionLocked: false,
                                     hoverControlsEnabled: true),
                    .unlockPill, "悬停高亮: 未锁定时解锁键自己也照常(显示与否由上报矩形决定)")
        // 缝里/胶囊外/没上报矩形三种"没压着"都该是 nil,不能留着上一颗亮着。
        expectEqual(H.hoveredControl(at: CGPoint(x: 200, y: 213), in: rects,
                                     insideWindow: true, positionLocked: false, hoverControlsEnabled: true) == nil,
                    true, "悬停高亮: 两颗之间的缝里不亮")
        expectEqual(H.hoveredControl(at: onPlay, in: [:], insideWindow: true, positionLocked: false,
                                     hoverControlsEnabled: true) == nil,
                    true, "悬停高亮: 没有上报矩形时一颗都不亮")
        // 锁定态下解锁键自己也要过 hoverControlsEnabled 这一闸——「悬停控制条」
        // 关掉时那一格压根不画,矩形却仍会无条件上报,不拦住就是"高亮一颗没画出来的按钮"。
        expectEqual(H.hoveredControl(at: onUnlock, in: rects, insideWindow: true, positionLocked: true,
                                     hoverControlsEnabled: false) == nil,
                    true, "悬停高亮: 锁定 + 悬停控制条关掉 → 解锁键也不亮")
    }

    // ---- OverlayControlHitTest.chromeHoverZone: 控制排该不该露出来的命中区域 ----
    //
    // 从"整扇窗"收紧成"歌词 ∪ 控制排"。这一组守的是收紧之后**按钮还点不点得到**:按钮在歌词
    // 外面(卡片内边距 + 槽位 4+4pt),区域漏掉按钮或漏掉中间那道缝,整排按钮就会在指针挪过去
    // 的路上消失。
    do {
        let H = OverlayControlHitTest.self
        // 一屏典型布局(SwiftUI 内容坐标,y 向下):控制排在上、歌词卡在下,中间隔着 8pt 的缝。
        let pill = CGRect(x: 400, y: 4, width: 216, height: 30)
        let buttons: [OverlayControlID: CGRect] = [
            .previous: CGRect(x: 410, y: 8, width: 22, height: 22),
            .playPause: CGRect(x: 440, y: 8, width: 22, height: 22),
        ]
        let lyrics = CGRect(x: 120, y: 62, width: 780, height: 46)
        // 不用 guard/return:这一组失败也不该把后面几组测试一起带走(整个文件是顺序执行的)。
        let zone = H.chromeHoverZone(lyrics: lyrics, controlsPill: pill, controlRects: buttons) ?? .null
        expectEqual(zone.contains(CGPoint(x: 500, y: 80)), true, "控制排命中区: 歌词文字上命中")
        expectEqual(zone.contains(CGPoint(x: 450, y: 18)), true, "控制排命中区: 按钮上命中")
        // 缝里必须命中 —— 包围盒存在的全部理由。分开判的话指针穿过这里控制排会闪一下。
        expectEqual(zone.contains(CGPoint(x: 450, y: 48)), true, "控制排命中区: 歌词与按钮之间的缝里命中")
        // 窗口四周的空白不该命中 —— 这次收紧要解决的正是这个(旧判据是整扇窗)。
        expectEqual(zone.contains(CGPoint(x: 20, y: 20)), false, "控制排命中区: 窗口左上角空白不命中")
        expectEqual(zone.contains(CGPoint(x: 500, y: 160)), false, "控制排命中区: 歌词下方空白不命中")

        // 锁定态:胶囊热区压根不上报,只有"🔒 解锁"那一颗按钮 —— 不并按钮矩形就再没有解锁出路。
        let unlock: [OverlayControlID: CGRect] = [.unlockPill: CGRect(x: 494, y: 8, width: 28, height: 22)]
        let locked = H.chromeHoverZone(lyrics: lyrics, controlsPill: nil, controlRects: unlock)
        expectEqual(locked?.contains(CGPoint(x: 508, y: 18)) ?? false, true,
                    "控制排命中区: 锁定态解锁键上命中(那时没有胶囊热区)")

        // 三份都没有 = 这一轮谁都没上报,返回 nil 让调用点退回整窗判定,别让功能整个失灵。
        expectEqual(H.chromeHoverZone(lyrics: nil, controlsPill: nil, controlRects: [:]) == nil, true,
                    "控制排命中区: 什么都没上报时为 nil(调用点退回整窗)")
        // .zero 按缺席处理:算进去会把包围盒拉到内容块左上角,在窗口角上留一块看不见的命中区。
        let zeroed = H.chromeHoverZone(lyrics: lyrics, controlsPill: .zero, controlRects: [.lock: .zero])
        expectEqual(zeroed == lyrics, true, "控制排命中区: .zero 矩形按缺席处理,不把包围盒拉到原点")
        expectEqual(H.chromeHoverZone(lyrics: .zero, controlsPill: nil, controlRects: [:]) == nil, true,
                    "控制排命中区: 只有 .zero 等于什么都没有")

        // 并集与顺序无关(字典遍历顺序不确定),结果必须稳定。
        let repeated = (1...50).map {
            _ in H.chromeHoverZone(lyrics: lyrics, controlsPill: pill, controlRects: buttons) ?? .null
        }
        expectEqual(repeated.allSatisfy { $0 == zone }, true, "控制排命中区: 结果不随字典遍历顺序变")
    }

    // ---- OverlayControlHitTest.chromeHoverHit: 进入严、退出宽的滞后闸 ----
    //
    // 上面那组用的歌词矩形宽 780、胶囊才 216 —— 歌词比按钮排宽,恰好把这个 bug 藏住了。
    // 真实的「暂无歌词」是反过来的:四个字 ~96pt,按钮排 216pt,包围盒被按钮排撑到 216 还带
    // 上下两截,于是文字左右一大片空白照样把整排按钮叫出来。
    do {
        let H = OverlayControlHitTest.self
        // 「暂无歌词」这一屏:控制排在上(y 4..34),歌词卡在下,文字只有中间那一小截。
        let pill = CGRect(x: 400, y: 4, width: 216, height: 30)
        let buttons: [OverlayControlID: CGRect] = [
            .previous: CGRect(x: 410, y: 8, width: 22, height: 22),
            .playPause: CGRect(x: 440, y: 8, width: 22, height: 22),
        ]
        let lyrics = CGRect(x: 460, y: 52, width: 96, height: 40)   // 窄:只有四个字
        let chrome = H.chromeHoverZone(lyrics: lyrics, controlsPill: pill, controlRects: buttons)

        // ① 正题:还没露出来时,文字**左右两侧**的空白不许把按钮叫出来 —— 那两点都在包围盒里,
        //    旧的单档判据在这里恒为 true,这两条就是这次的红/绿。
        expectEqual(H.chromeHoverHit(at: CGPoint(x: 410, y: 70), lyrics: lyrics, chrome: chrome,
                                     alreadyShowing: false), false,
                    "滞后闸: 未显示时文字左侧空白不叫出控制排")
        expectEqual(H.chromeHoverHit(at: CGPoint(x: 600, y: 70), lyrics: lyrics, chrome: chrome,
                                     alreadyShowing: false), false,
                    "滞后闸: 未显示时文字右侧空白不叫出控制排")
        // 文字上照样要能叫出来,否则功能直接没了。
        expectEqual(H.chromeHoverHit(at: CGPoint(x: 500, y: 70), lyrics: lyrics, chrome: chrome,
                                     alreadyShowing: false), true,
                    "滞后闸: 未显示时压在文字上要叫出控制排")

        // ② 反面:已经露出来之后判据放宽到包围盒 —— 这几条守的是 chromeHoverZone 注释里那三条
        //    (按钮在歌词外面、中间那道缝、锁定态的解锁出路)一条都没被这次收紧带走。
        expectEqual(H.chromeHoverHit(at: CGPoint(x: 450, y: 18), lyrics: lyrics, chrome: chrome,
                                     alreadyShowing: true), true,
                    "滞后闸: 已显示时按钮上命中(按钮在歌词外面)")
        expectEqual(H.chromeHoverHit(at: CGPoint(x: 450, y: 44), lyrics: lyrics, chrome: chrome,
                                     alreadyShowing: true), true,
                    "滞后闸: 已显示时歌词与按钮之间的缝里命中")
        expectEqual(H.chromeHoverHit(at: CGPoint(x: 410, y: 70), lyrics: lyrics, chrome: chrome,
                                     alreadyShowing: true), true,
                    "滞后闸: 已显示时文字左侧空白仍命中(指针斜着挪向最左那颗按钮的必经之路)")
        // 出了包围盒就该收 —— 滞后不是"进去就再也出不来"。
        expectEqual(H.chromeHoverHit(at: CGPoint(x: 900, y: 200), lyrics: lyrics, chrome: chrome,
                                     alreadyShowing: true), false,
                    "滞后闸: 已显示时离开包围盒要收回去")

        // ③ 严格档 ⊆ 宽松档 —— 不存在"严格判 true 而宽松判 false"的点,否则状态会每帧翻转。
        //   在这一屏上铺一张网穷举,比挑几个点更能守住这条不变式。
        var monotone = true
        for x in stride(from: 380.0, through: 660.0, by: 7.0) {
            for y in stride(from: 0.0, through: 120.0, by: 4.0) {
                let p = CGPoint(x: x, y: y)
                let strict = H.chromeHoverHit(at: p, lyrics: lyrics, chrome: chrome, alreadyShowing: false)
                let loose = H.chromeHoverHit(at: p, lyrics: lyrics, chrome: chrome, alreadyShowing: true)
                if strict == true && loose != true { monotone = false }
            }
        }
        expectEqual(monotone, true, "滞后闸: 严格档恒含于宽松档(不会在边界上抖)")

        // ④ 歌词矩形这一轮没上报 → 严格档退回包围盒,别让按钮整个叫不出来。
        expectEqual(H.chromeHoverHit(at: CGPoint(x: 450, y: 18), lyrics: nil, chrome: chrome,
                                     alreadyShowing: false), true,
                    "滞后闸: 没有歌词矩形时进入判定退回包围盒")
        expectEqual(H.chromeHoverHit(at: CGPoint(x: 450, y: 18), lyrics: .zero, chrome: chrome,
                                     alreadyShowing: false), true,
                    "滞后闸: .zero 歌词矩形按缺席处理,同上")
        // 谁都没上报 = nil,调用点退回整窗判定(旧行为)。
        expectEqual(H.chromeHoverHit(at: CGPoint(x: 450, y: 18), lyrics: nil, chrome: nil,
                                     alreadyShowing: false) == nil, true,
                    "滞后闸: 什么都没上报时为 nil(调用点退回整窗)")
        expectEqual(H.chromeHoverHit(at: CGPoint(x: 450, y: 18), lyrics: nil, chrome: nil,
                                     alreadyShowing: true) == nil, true,
                    "滞后闸: 什么都没上报时为 nil(已显示这一档同样)")

        // ⑤ 锁定态:没有胶囊热区,包围盒 = 歌词 ∪ 解锁键。进入仍只认文字,进去之后够得到解锁键
        //    —— 不然锁定之后就再没有解锁出路了。
        let unlock: [OverlayControlID: CGRect] = [.unlockPill: CGRect(x: 494, y: 8, width: 28, height: 22)]
        let lockedChrome = H.chromeHoverZone(lyrics: lyrics, controlsPill: nil, controlRects: unlock)
        expectEqual(H.chromeHoverHit(at: CGPoint(x: 500, y: 70), lyrics: lyrics, chrome: lockedChrome,
                                     alreadyShowing: false), true,
                    "滞后闸: 锁定态压在文字上要露出解锁键")
        expectEqual(H.chromeHoverHit(at: CGPoint(x: 508, y: 18), lyrics: lyrics, chrome: lockedChrome,
                                     alreadyShowing: true), true,
                    "滞后闸: 锁定态露出后够得到解锁键")
    }

    // ---- LyricDuetLayout: 对唱行的两侧内缩 ----
    do {
        let L = LyricDuetLayout.self
        // 没有对唱信息的行一律 0 —— 普通歌的排版必须逐像素不变,这是回归护栏
        do {
            let i = L.insets(for: nil, availableWidth: 400, fontSize: 30)
            expectEqual(i.leading, 0, "对唱内缩: 无声部信息不留白(leading)")
            expectEqual(i.trailing, 0, "对唱内缩: 无声部信息不留白(trailing)")
        }
        // 左声部远侧(右边)留得比近侧(左边)多,右声部反过来——近侧非零是
        // 加的:不让字贴着卡片真边缘,近侧永远是远侧的一半。
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

    // ---- OverlayDuetAlignmentOverride: 悬浮歌词「对齐方式」覆盖 ----
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
        // 核心安全约束:非自动时装饰值(两侧内缩+声部指示圆点用)必须恒为 nil——
        // 否则"左对齐"这种覆盖会让完全没有对唱标记的普通歌也冒出内缩和圆点,那不是
        // issue 要的效果(见 OverlayDuetAlignmentOverride 声明处注释)。
        for override in [O.center, O.leading, O.trailing] {
            for real: LyricDuet.Side? in [nil, D.leading, D.trailing, D.center] {
                expectEqual(override.effectiveDecorationSide(realSide: real), nil,
                            "覆盖-\(override): 装饰值恒为 nil,不管真实声部是什么(real=\(String(describing: real)))")
            }
        }
    }

    // ---- OverlayCardGeometry: 卡片内容块与它上方那排控制按钮的横向落点 ----
    //
    // 控制排若只吃外层 VStack 默认的 .center,而卡片按声部靠边,对唱歌一把歌词甩到
    // 右半边就会差出大半个窗宽。这一组钉的就是"两者贴同一条边"这条不变式:算法只有几行,
    // 但它必须跟卡片那一边逐字一致,而本仓已经为"同一个视觉属性两条渲染路径"付过三次账
    // (第 04 章:预览条对齐写死 leading / 灵动岛手搓预览 / 编辑台简化复刻件)。
    do {
        let G = OverlayCardGeometry.self
        let D = LyricDuet.Side.self
        // 1016pt 窗宽 / 31pt 字号那一档的实测 unit;具体数值不重要,不变式才重要。
        let unit: CGFloat = 124
        // = OverlayPlayback.cardHorizontalPadding(那个常量在 App target 里,core 侧拿不到)。
        let pad: CGFloat = 20

        // 卡片内缩:左右声部不留远侧空白 —— 贴着文字那一侧已经有圆点+竖线标出是哪一边,
        // 不需要再靠留白区分。nil = 没有对唱信息(普通歌的每一行、对唱歌第一个标记之前的
        // 前奏、非自动的「对齐方式」覆盖)——两侧恒为 0,普通歌排版逐像素不变。合唱没有
        // 圆点标记,两侧仍留 unit。
        expectEqual(G.cardInsets(for: nil, unit: unit).leading, 0, "卡片内缩: 无声部时左侧 0")
        expectEqual(G.cardInsets(for: nil, unit: unit).trailing, 0, "卡片内缩: 无声部时右侧 0")
        expectEqual(G.cardInsets(for: D.leading, unit: unit).leading, 0, "卡片内缩: 左声部近侧不留")
        expectEqual(G.cardInsets(for: D.leading, unit: unit).trailing, 0, "卡片内缩: 左声部远侧不再留白")
        expectEqual(G.cardInsets(for: D.trailing, unit: unit).leading, 0, "卡片内缩: 右声部远侧不再留白")
        expectEqual(G.cardInsets(for: D.trailing, unit: unit).trailing, 0, "卡片内缩: 右声部近侧不留")
        expectEqual(G.cardInsets(for: D.center, unit: unit).leading, unit, "卡片内缩: 合唱两侧都留(左)")
        expectEqual(G.cardInsets(for: D.center, unit: unit).trailing, unit, "卡片内缩: 合唱两侧都留(右)")

        // 核心不变式:控制排的两侧留白 = 卡片内缩 + 卡片水平内边距。两者再按同一个方向
        // 靠边,按钮排的近侧边缘就跟歌词块的近侧边缘严格重合 —— 这条一破,控制排立刻又不在
        // "对应歌词上面"了,而这种偏移只有对唱歌才看得见,极易漏到对拍里才发现。
        for side: LyricDuet.Side? in [nil, D.leading, D.trailing, D.center] {
            let card = G.cardInsets(for: side, unit: unit)
            let ctrl = G.controlsInsets(for: side, unit: unit, cardHorizontalPadding: pad)
            let tag = String(describing: side)
            expectEqual(ctrl.leading - card.leading, pad, "控制排落点: 左侧比卡片多且只多一份内边距(side=\(tag))")
            expectEqual(ctrl.trailing - card.trailing, pad, "控制排落点: 右侧比卡片多且只多一份内边距(side=\(tag))")
        }

        // 回归护栏:没有对唱信息(绝大多数歌)和真正的合唱,两侧留白必须**对称** —— 这两种
        // 情况对齐方向都是 .center,对称才能保证控制排的位置逐像素稳定。
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

    // ---- OverlayCardGeometry.duetStageInset: 对唱舞台 ----
    //
    // 「如果歌词已经拉得很宽,这时候遇上对唱类歌词,左右两句就会分得很开……哪怕宽度拉得
    // 很宽,也尽量还是居中显示;剩余的宽度留给很长的歌词做冗余」。左右声部只在卡片正中一条
    // 固定宽度的带(舞台)里分栏:近侧多缩进"舞台两侧各让出的量",远侧不留白;带外的宽度是
    // 长句的冗余。
    do {
        let G = OverlayCardGeometry.self
        let D = LyricDuet.Side.self
        let pad: CGFloat = 20 // = OverlayPlayback.cardHorizontalPadding(App target 里的常量)
        let ref = G.duetStageReferenceWidth
        expectEqual(ref, 448, "对唱舞台: 基准宽度 = 默认窗宽 488 − 两侧 20pt 卡片内边距")

        // 回归护栏:不比默认宽的窗口(含默认本身)舞台就是整张卡片,一个像素都不挪。
        expectEqual(G.duetStageInset(availableWidth: 448, fontSize: 31), 0, "对唱舞台: 默认窗宽下不缩进")
        expectEqual(G.duetStageInset(availableWidth: 300, fontSize: 31), 0, "对唱舞台: 比默认窄也不缩进")
        // 拉宽:多出来的宽度两侧各分一半 —— 1400 窗宽可用 1360,减 448 舞台,各让 456。
        expectEqual(G.duetStageInset(availableWidth: 1360, fontSize: 31), 456,
                    "对唱舞台: 1400 窗宽 / 31pt 两侧各让 (1360−448)/2")
        // 大字号按 12 个字宽兜底:48pt × 12 = 576 > 448,舞台按 576 算。
        expectEqual(G.duetStageInset(availableWidth: 1360, fontSize: 48), (1360 - 576) / 2,
                    "对唱舞台: 大字号时舞台按 12 个字宽兜底")
        // 字宽兜底不会把舞台撑出卡片:可用 500、字号 48 → 舞台 min(500, 576) = 500 → 不缩进。
        expectEqual(G.duetStageInset(availableWidth: 500, fontSize: 48), 0,
                    "对唱舞台: 12 字宽超过可用宽度时舞台就是整张卡片")
        // 退化输入不产生负值/NaN。
        expectEqual(G.duetStageInset(availableWidth: 0, fontSize: 31), 0, "对唱舞台: 宽度 0 → 0")
        expectEqual(G.duetStageInset(availableWidth: -100, fontSize: 31), 0, "对唱舞台: 负宽度 → 0")
        expectEqual(G.duetStageInset(availableWidth: 1360, fontSize: 0), 456, "对唱舞台: 字号 0 时只剩基准宽度")
        expectEqual(G.duetStageInset(availableWidth: 1360, fontSize: -5), 456, "对唱舞台: 负字号同字号 0")

        // 1400 窗宽 / 31pt 那一档:unit 走 LyricDuetLayout(15% 被 4 字宽封顶 = 124),现在只喂给
        // 合唱用(左右声部不再用它)。
        let unit = LyricDuetLayout.insets(for: .leading, availableWidth: 1360, fontSize: 31).trailing
        expectEqual(unit, 124, "对唱舞台: 合唱用的内缩是 4 字宽封顶的 124")
        let stage = G.duetStageInset(availableWidth: 1360, fontSize: 31)

        // 舞台进 cardInsets:近侧 = 舞台让出的量,远侧不再留白(圆点标记已经够用);合唱
        // 本来就居中、不需要舞台,两侧仍是 unit;nil(普通歌 / 前奏 / 覆盖生效)恒 0。
        expectEqual(G.cardInsets(for: D.leading, unit: unit, stageInset: stage).leading, stage, "对唱舞台: 左声部近侧缩进舞台让出的量")
        expectEqual(G.cardInsets(for: D.leading, unit: unit, stageInset: stage).trailing, 0, "对唱舞台: 左声部远侧不再留白")
        expectEqual(G.cardInsets(for: D.trailing, unit: unit, stageInset: stage).leading, 0, "对唱舞台: 右声部远侧不再留白")
        expectEqual(G.cardInsets(for: D.trailing, unit: unit, stageInset: stage).trailing, stage, "对唱舞台: 右声部近侧缩进舞台让出的量")
        expectEqual(G.cardInsets(for: D.center, unit: unit, stageInset: stage).leading, unit, "对唱舞台: 合唱左侧不加舞台")
        expectEqual(G.cardInsets(for: D.center, unit: unit, stageInset: stage).trailing, unit, "对唱舞台: 合唱右侧不加舞台")
        expectEqual(G.cardInsets(for: nil, unit: unit, stageInset: stage).leading, 0, "对唱舞台: 无声部左侧仍是 0")
        expectEqual(G.cardInsets(for: nil, unit: unit, stageInset: stage).trailing, 0, "对唱舞台: 无声部右侧仍是 0")
        expectEqual(G.cardInsets(for: D.leading, unit: unit, stageInset: -10).leading, 0, "对唱舞台: 负的舞台量不产生负内缩")

        // 缺省 stageInset = 0 就是改动前的结果 —— 不传的调用方(歌词窗口那套不走这里,但护栏要在)行为不变。
        for side: LyricDuet.Side? in [nil, D.leading, D.trailing, D.center] {
            let old = G.cardInsets(for: side, unit: unit)
            let new = G.cardInsets(for: side, unit: unit, stageInset: 0)
            let tag = String(describing: side)
            expectEqual(old.leading, new.leading, "对唱舞台: stageInset 缺省时左侧同旧值(side=\(tag))")
            expectEqual(old.trailing, new.trailing, "对唱舞台: stageInset 缺省时右侧同旧值(side=\(tag))")
        }

        // 控制排不变式带着舞台照样成立:两侧留白 = 卡片内缩 + 一份卡片内边距 —— 按钮排跟着
        // 歌词块一起收进舞台,不会歌词进了正中、按钮还钉在窗口两端。
        for side: LyricDuet.Side? in [nil, D.leading, D.trailing, D.center] {
            let card = G.cardInsets(for: side, unit: unit, stageInset: stage)
            let ctrl = G.controlsInsets(for: side, unit: unit, stageInset: stage, cardHorizontalPadding: pad)
            let tag = String(describing: side)
            expectEqual(ctrl.leading - card.leading, pad, "对唱舞台: 控制排左侧只比卡片多一份内边距(side=\(tag))")
            expectEqual(ctrl.trailing - card.trailing, pad, "对唱舞台: 控制排右侧只比卡片多一份内边距(side=\(tag))")
        }

        // 几何核算(1400 窗宽 / 31pt):左声部的字从 x=20+456=476 起,右声部的字到 1400−20−456=924
        // 止 —— 两栏落在正中一条 448 宽的带里,而不是像改动前那样隔着 1360。
        let leftStart = pad + G.cardInsets(for: D.leading, unit: unit, stageInset: stage).leading
        let rightEnd = 1400 - pad - G.cardInsets(for: D.trailing, unit: unit, stageInset: stage).trailing
        expectEqual(leftStart, 476, "对唱舞台: 左声部起笔 x")
        expectEqual(rightEnd, 924, "对唱舞台: 右声部收笔 x")
        expectEqual(rightEnd - leftStart, ref, "对唱舞台: 两栏之间正好一个舞台宽")
        expectEqual((leftStart + rightEnd) / 2, 700, "对唱舞台: 舞台在窗口正中")
        let oldLeftStart = pad + G.cardInsets(for: D.leading, unit: unit).leading
        let oldRightEnd = 1400 - pad - G.cardInsets(for: D.trailing, unit: unit).trailing
        expectEqual(oldRightEnd - oldLeftStart, 1360, "对唱舞台: 改动前两栏隔着整个可用宽度(对照)")

        // 长句冗余:左声部远侧不再留白,换行点一路排到卡片右边缘(1400−20−0=1380)—— 舞台
        // 只挪近侧的起笔位置,不吃掉长句能用的宽度。
        let leftWrapAt = 1400 - pad - G.cardInsets(for: D.leading, unit: unit, stageInset: stage).trailing
        expectEqual(leftWrapAt, 1380, "对唱舞台: 左声部换行点")
        expectEqual(leftWrapAt, 1400 - pad - G.cardInsets(for: D.leading, unit: unit).trailing,
                    "对唱舞台: 左声部换行点跟不加舞台时相同")
    }

    // ---- OverlayCardGeometry.elasticInsetScale:留白只吃"这一行本来就用不到"的富余 ----
    //
    // 判据是**填没填满**,不是**会不会多折一行**:一句话不管让不让留白都要折两行,但让开
    // 之后第一行能多装一个词、右边那截空白才填得上。真实环境里的自然宽由 SwiftUI 的
    // `sizeThatFits(.unspecified)` 量,这里直接喂数字。
    do {
        let G = OverlayCardGeometry.self
        let pad: CGFloat = 20 // = OverlayPlayback.cardHorizontalPadding(App target 里的常量)

        // 没有留白可让:恒 1。绝大多数歌(非对唱 / 窗口不比默认宽)走这一支。
        expectEqual(G.elasticInsetScale(totalInset: 0, availableWidth: 526, naturalContentWidth: 900), 1,
                    "弹性留白: 没有留白可让时恒 1")

        // 短句:富余 126 比理想留白 39 还多,留白照留(排版逐像素不变)。
        expectEqual(G.elasticInsetScale(totalInset: 39, availableWidth: 526, naturalContentWidth: 400), 1,
                    "弹性留白: 短句留白照留")
        // 富余正好等于理想留白:还是全留,文字正好顶到远侧边缘。
        expectEqual(G.elasticInsetScale(totalInset: 39, availableWidth: 526, naturalContentWidth: 487), 1,
                    "弹性留白: 富余正好够时全留")

        // 富余不够一整份:按比例退,文字仍然正好顶到远侧边缘、一个像素不浪费。
        let k1 = G.elasticInsetScale(totalInset: 39, availableWidth: 526, naturalContentWidth: 500)
        expectEqual(k1, 26.0 / 39, "弹性留白: 富余不够时按比例退")
        expectEqual(526 - 39 * k1, 500, "弹性留白: 退完之后内容宽正好等于自然宽")

        // 一行装不下:留白整份让开,换行前先把整宽吃满。**这一条就是"左侧都没满就换行了"**
        // 的修法 —— 按行数判的旧判据在这里会判成 1(让不让都是两行),空白留着不填。
        expectEqual(G.elasticInsetScale(totalInset: 39, availableWidth: 526, naturalContentWidth: 527), 0,
                    "弹性留白: 差一点装不下就整份让开")
        expectEqual(G.elasticInsetScale(totalInset: 39, availableWidth: 526, naturalContentWidth: 771), 0,
                    "弹性留白: 一行装不下时整份让开")

        // 退化输入:自然宽为负 / 0 当没有内容(全留);可用宽为 0 → 全让。
        expectEqual(G.elasticInsetScale(totalInset: 39, availableWidth: 526, naturalContentWidth: -100), 1,
                    "弹性留白: 负自然宽当空内容,全留")
        expectEqual(G.elasticInsetScale(totalInset: 39, availableWidth: 0, naturalContentWidth: 100), 0,
                    "弹性留白: 可用宽 0 时全让")
        // 留白比可用宽还大:照样只吃富余那么多,内容宽正好落在自然宽上,不会被缩成负数。
        let k2 = G.elasticInsetScale(totalInset: 600, availableWidth: 526, naturalContentWidth: 100)
        expectEqual(k2, 426.0 / 600, "弹性留白: 留白超过可用宽时也只吃掉富余")
        expectEqual(526 - 600 * k2, 100, "弹性留白: 超大留白下内容宽仍等于自然宽")

        // 控制排跟着同一份系数走 —— 让开多少按钮排就让开多少,不变式仍是"只比卡片多一份内边距"。
        let unit = LyricDuetLayout.insets(for: .leading, availableWidth: 526, fontSize: 36).trailing
        let stage = G.duetStageInset(availableWidth: 526, fontSize: 36)
        expectEqual(stage, 39, "弹性留白: 566 窗宽 / 36pt 的舞台缩进")
        for side: LyricDuet.Side? in [nil, .leading, .trailing, .center] {
            for scale: CGFloat in [0, 0.5, 1] {
                let card = G.cardInsets(for: side, unit: unit, stageInset: stage)
                let ctrl = G.controlsInsets(for: side, unit: unit, stageInset: stage, scale: scale,
                                            cardHorizontalPadding: pad)
                let tag = "side=\(String(describing: side)) scale=\(scale)"
                expectEqual(ctrl.leading - card.leading * scale, pad, "弹性留白: 控制排左侧跟着让开(\(tag))")
                expectEqual(ctrl.trailing - card.trailing * scale, pad, "弹性留白: 控制排右侧跟着让开(\(tag))")
            }
            // scale 缺省 = 1 = 改动前的结果,不传的调用点行为不变。
            let old = G.controlsInsets(for: side, unit: unit, stageInset: stage, cardHorizontalPadding: pad)
            let one = G.controlsInsets(for: side, unit: unit, stageInset: stage, scale: 1, cardHorizontalPadding: pad)
            expectEqual(old.leading, one.leading, "弹性留白: 控制排 scale 缺省同旧值(左)")
            expectEqual(old.trailing, one.trailing, "弹性留白: 控制排 scale 缺省同旧值(右)")
        }
        // 越界的 scale 被夹住,不会算出负留白或者超过一份留白。
        let clampedLow = G.controlsInsets(for: .leading, unit: unit, stageInset: stage, scale: -3, cardHorizontalPadding: pad)
        let clampedHigh = G.controlsInsets(for: .leading, unit: unit, stageInset: stage, scale: 9, cardHorizontalPadding: pad)
        expectEqual(clampedLow.leading, pad, "弹性留白: 负 scale 夹到 0")
        expectEqual(clampedHigh.leading, stage + pad, "弹性留白: 超过 1 的 scale 夹到 1")
    }

    // ---- OverlayControlHitTest.windowLocalRect:SwiftUI 矩形 → AppKit 窗口本地 ----
    //
    // 这套换算不能**直接转成屏幕坐标存起来** —— 窗口一移动,SwiftUI 布局没变、
    // PreferenceKey 不重发,存的屏幕坐标就还停在旧位置,按钮和热区当场失效。
    // 只存窗口本地坐标,判定时把鼠标点转进来。
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

    // ---- OverlayRowPlan:一帧里各行显示什么、动不动、怎么动 ----
    //
    // 真值表。改判据之前先看这张表:每一格都是真机上踩过的 —— 滚完跳回开头、下一句跟着滚、
    // 前奏首句读音没对齐、示例行拿不到时间轴。
    do {
        typealias P = OverlayRowPlan
        func plan(_ o: OverlayLineOverflow, line: Bool = true, words: Bool = true, groups: Bool = false,
                  preview: Bool = false, timing: Bool = true, roma: Bool = true, nextGroups: Bool = false) -> P.Plan {
            P.resolve(.init(overflow: o, hasLine: line, lineHasWords: words, lineHasWordGroups: groups,
                            lineRomanization: "cur-roma", lineTranslation: "cur-tr",
                            isPreviewLine: preview, hasTimingWindow: timing,
                            showRomanization: roma, showTranslation: true, showNextLinePreview: true,
                            nextText: "next", nextRomanization: "next-roma", nextTranslation: "next-tr",
                            nextHasWordGroups: nextGroups))
        }
        func row(_ t: String, _ m: P.Motion) -> P.Row { P.Row(text: t, motion: m) }

        // 换行模式:什么都不滚。
        let wrap = plan(.wrap)
        expectEqual(wrap.main, .wrap, "行排版: 换行模式主行折行")
        expectEqual(wrap.romanization, row("cur-roma", .wrap), "行排版: 换行模式罗马音折行")
        expectEqual(wrap.translation, row("cur-tr", .wrap), "行排版: 换行模式译文折行")
        expectEqual(wrap.next, row("next", .wrap), "行排版: 换行模式下一句折行")

        // 滚动模式 + 带逐字 + 有时间窗口:主行跟唱,当前行副行按时长配速,下一句不动。
        let follow = plan(.scroll)
        expectEqual(follow.main, .follow, "行排版: 带逐字的当前行跟唱滚动")
        expectEqual(follow.romanization, row("cur-roma", .paced), "行排版: 当前行罗马音按时长配速")
        expectEqual(follow.translation, row("cur-tr", .paced), "行排版: 当前行译文按时长配速")
        expectEqual(follow.next, row("next", .still), "行排版: 下一句还没唱,滚动模式下不动")

        // 没有逐字:有时间窗口按时长配速,没有就退回固定速度跑马灯。
        expectEqual(plan(.scroll, words: false).main, .paced, "行排版: 没有逐字的主行按时长配速")
        let noTiming = plan(.scroll, words: false, timing: false)
        expectEqual(noTiming.main, .marquee, "行排版: 拿不到时间窗口时主行退回固定速度")
        expectEqual(noTiming.translation, row("cur-tr", .marquee), "行排版: 拿不到时间窗口时副行退回固定速度")

        // 设置页示例行没有时间轴:哪怕协调器那边有窗口(真实在播的那首)也不能拿来配速。
        let preview = plan(.scroll, words: false, preview: true)
        expectEqual(preview.main, .marquee, "行排版: 示例行不按真实歌曲的窗口配速")
        expectEqual(preview.romanization?.motion, .marquee, "行排版: 示例行的副行同样退回固定速度")

        // 没有当前行(前奏 / 间奏「•••」):下方那几行是接下来那句,滚动模式下全都不动。
        let gap = plan(.scroll, line: false)
        expectEqual(gap.main, nil, "行排版: 间奏没有主行")
        expectEqual(gap.romanization, row("next-roma", .still), "行排版: 间奏里显示接下来那句的罗马音,不动")
        expectEqual(gap.translation, row("next-tr", .still), "行排版: 间奏里显示接下来那句的译文,不动")
        expectEqual(gap.next, row("next", .still), "行排版: 间奏里的下一句不动")
        expectEqual(plan(.wrap, line: false).romanization, row("next-roma", .wrap), "行排版: 换行模式间奏照旧折行")

        // 逐词罗马音:当前行分得出词组就标在每个词底下,整行罗马音那一行不出现。
        let perWord = plan(.scroll, groups: true)
        expectEqual(perWord.perWordRomanization, true, "行排版: 当前行分得出词组就逐词标")
        expectEqual(perWord.romanization == nil, true, "行排版: 逐词标时整行罗马音让位")
        // 间奏里接下来那句分得出词组:同样逐词标在它底下。
        let gapPerWord = plan(.scroll, line: false, nextGroups: true)
        expectEqual(gapPerWord.nextPerWordRomanization, true, "行排版: 前奏首句分得出词组就逐词标")
        expectEqual(gapPerWord.romanization == nil, true, "行排版: 前奏首句逐词标时整行罗马音让位")
        expectEqual(plan(.scroll, nextGroups: true).nextPerWordRomanization, false,
                    "行排版: 有当前行时下一句预览不逐词标(那是另一句的小字预览)")

        // 开关关掉就不出现。
        let romaOff = plan(.scroll, groups: true, roma: false)
        expectEqual(romaOff.romanization == nil && !romaOff.perWordRomanization, true, "行排版: 罗马音关掉哪儿都不出现")
        expectEqual(plan(.scroll, line: false, roma: false, nextGroups: true).nextPerWordRomanization, false,
                    "行排版: 罗马音关掉前奏首句也不逐词标")
        let nextOff = P.resolve(.init(overflow: .scroll, hasLine: true, showNextLinePreview: false, nextText: "next"))
        expectEqual(nextOff.next == nil, true, "行排版: 双行关掉没有下一句")
        let noNext = P.resolve(.init(overflow: .scroll, hasLine: true, showNextLinePreview: true, nextText: nil))
        expectEqual(noNext.next == nil, true, "行排版: 没有下一句就不出这一行")
        // 当前行自己没有罗马音时不借用下一句的(只有没有当前行时才用接下来那句的)。
        let curNoRoma = P.resolve(.init(overflow: .scroll, hasLine: true, lineRomanization: nil,
                                        showRomanization: true, nextRomanization: "next-roma"))
        expectEqual(curNoRoma.romanization == nil, true, "行排版: 当前行没有罗马音时不借下一句的")
    }

    // ---- OverlayRowLayout:图层行的横向排版(字的起止、读音落点、长图总宽) ----
    //
    // 字宽按「字数 × 10」、读音按「字数 × 6」测,每个数都能手算。
    do {
        typealias L = OverlayRowLayout
        func w(_ t: String) -> SyncedLyricWord { SyncedLyricWord(text: t, startMs: 0, durationMs: 100) }
        let main: (String) -> CGFloat = { CGFloat($0.count) * 10 }
        let roma: (String) -> CGFloat = { CGFloat($0.count) * 6 }
        let pad = L.romaSidePadding

        // 一行字:逐个紧挨着排,左右各一份 inset。
        let plain = L.layOut(words: [w("你"), w("好吗")], groups: nil, inset: 3, measureMain: main, measureRoma: roma)
        expectEqual(plain.wordStartXs, [3, 13], "图层排版: 字从 inset 起逐个紧挨")
        expectEqual(plain.wordEndXs, [13, 33], "图层排版: 每个字的右缘")
        expectEqual(plain.boxWidth, 36, "图层排版: 总宽 = 字宽之和 + 两侧 inset")
        expectEqual(plain.romaPlacements.isEmpty, true, "图层排版: 没开逐词罗马音就没有读音")

        // 逐词罗马音:读音比字宽时列宽取读音 + 两侧留白,读音从列首 + 留白起画。
        let g1 = SyncedLyricWordGroup(id: 0, words: [w("痛")], romanization: "tung3")   // 字 10,读音 30+4
        let g2 = SyncedLyricWordGroup(id: 1, words: [w("到没")], romanization: "d")      // 字 20,读音 6+4
        let grouped = L.layOut(words: [], groups: [g1, g2], inset: 0, measureMain: main, measureRoma: roma)
        expectEqual(grouped.wordStartXs, [0, 30 + 2 * pad], "图层排版: 下一组从上一列的列宽之后起")
        expectEqual(grouped.romaPlacements, [L.RomaPlacement(x: pad, text: "tung3"),
                                             L.RomaPlacement(x: 30 + 2 * pad + pad, text: "d")],
                    "图层排版: 读音从各自列首 + 留白起画")
        expectEqual(grouped.boxWidth, 30 + 2 * pad + 20, "图层排版: 字比读音宽时列宽取字宽")
        expectEqual(grouped.flatWords.map(\.text), ["痛", "到没"], "图层排版: 摊平的字保持排版顺序")

        // 没有读音的组(混语言行里的英文词)按一个空格占位,不画读音、列宽照样算留白。
        let bare = SyncedLyricWordGroup(id: 0, words: [w("a")], romanization: nil)   // 字 10,占位 6+4
        let noRoma = L.layOut(words: [], groups: [bare, g1], inset: 0, measureMain: main, measureRoma: roma)
        expectEqual(noRoma.romaPlacements.map(\.text), ["tung3"], "图层排版: 没有读音的组不画读音")
        expectEqual(noRoma.wordStartXs[1], max(10, 6 + 2 * pad), "图层排版: 没有读音的组按空格占位算列宽")

        // 相邻两组读音之间至少隔两份留白,不会首尾相接读成一串。
        let tight = L.layOut(words: [], groups: [g1, SyncedLyricWordGroup(id: 1, words: [w("到")], romanization: "dou2")],
                             inset: 0, measureMain: main, measureRoma: roma)
        let firstEnd = tight.romaPlacements[0].x + roma("tung3")
        expectEqual(tight.romaPlacements[1].x - firstEnd, 2 * pad, "图层排版: 相邻读音之间隔两份留白")

        // 描边开着:每侧再让一份描边外扩,描边之外看到的字缝跟不描边时一样宽。
        let stroke: CGFloat = 2.4
        expectEqual(L.romaSidePadding(strokeInset: 0), pad, "图层排版: 不描边时留白就是基础值")
        expectEqual(L.romaSidePadding(strokeInset: stroke), pad + stroke, "图层排版: 描边时每侧多让一份描边外扩")
        let stroked = L.layOut(words: [], groups: [g1, SyncedLyricWordGroup(id: 1, words: [w("到")], romanization: "dou2")],
                               inset: 0, strokeInset: stroke, measureMain: main, measureRoma: roma)
        let strokedGap = stroked.romaPlacements[1].x - (stroked.romaPlacements[0].x + roma("tung3"))
        expectEqual(abs(strokedGap - 2 * stroke - 2 * pad) < 0.001, true, "图层排版: 描边时扣掉两侧描边,看得见的字缝仍是两份基础留白")
        expectEqual(abs(stroked.romaPlacements[0].x - (pad + stroke)) < 0.001, true, "图层排版: 描边时读音从列首 + 加宽后的留白起画")
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

        // 单个元素本身就超宽时，必须独占一行且**保留**——这正是"长歌词行整行变成一串
        // 省略号"那个 bug 的修法。谁要是在这里加个"太宽就跳过"，这条会立刻红。
        expectEqual(rowIndices(WrapLayoutMath.rows(sizes: [sz(500)], maxWidth: 100, horizontalSpacing: 0)),
                    [[0]], "WrapLayout: 单个超宽元素独占一行,不能被丢掉")
        expectEqual(rowIndices(WrapLayoutMath.rows(sizes: [sz(10), sz(500), sz(10)], maxWidth: 100, horizontalSpacing: 0)),
                    [[0], [1], [2]], "WrapLayout: 超宽元素夹在中间也不丢")

        // 空输入不该炸，也不该造出一个空行。
        expectEqual(WrapLayoutMath.rows(sizes: [], maxWidth: 100, horizontalSpacing: 0).count, 0,
                    "WrapLayout: 空输入没有行")
        // 没有宽度约束时的兜底尺寸:全部铺成一行,宽 = 各宽之和 + (n-1) 个间距,高 = 最高那个。
        expectEqual(WrapLayoutMath.unconstrainedSize(sizes: [sz(30, 10), sz(40, 24), sz(20, 12)], horizontalSpacing: 5),
                    CGSize(width: 100, height: 24), "WrapLayout: 无约束尺寸 = 宽之和 + 间距,高取最大")
        expectEqual(WrapLayoutMath.unconstrainedSize(sizes: [sz(30, 10)], horizontalSpacing: 5),
                    CGSize(width: 30, height: 10), "WrapLayout: 单个元素不加间距")
        expectEqual(WrapLayoutMath.unconstrainedSize(sizes: [], horizontalSpacing: 5), .zero,
                    "WrapLayout: 空输入尺寸为 0,不出负数间距")

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
        // 这个返回内容自己的包围盒。 hover 判据不能用整个窗口矩形:指针在歌词**附近**的
        // 空白处也会触发淡出。
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
        // 露出多少才算够:宽 ≥ 60 且高 ≥ 30,两样缺一不可;跨两块屏时看任意一块。
        let main1920 = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let peek = { (x: CGFloat, y: CGFloat) in CGRect(x: x, y: y, width: 446, height: 154) }
        expectEqual(OverlayPlacement.isSufficientlyVisible(frame: peek(1920 - 60, 500), screens: [main1920]), true,
                    "OverlayPlacement: 右边只露 60pt 仍算够得着")
        expectEqual(OverlayPlacement.isSufficientlyVisible(frame: peek(1920 - 59, 500), screens: [main1920]), false,
                    "OverlayPlacement: 右边只露 59pt 不够")
        expectEqual(OverlayPlacement.isSufficientlyVisible(frame: peek(500, 1080 - 29), screens: [main1920]), false,
                    "OverlayPlacement: 宽度够但只露 29pt 高也不够")
        expectEqual(OverlayPlacement.isSufficientlyVisible(frame: peek(5000, 5000), screens: [main1920]), false,
                    "OverlayPlacement: 完全不沾屏不可见")
        expectEqual(OverlayPlacement.isSufficientlyVisible(frame: peek(-300, 500),
                                                           screens: [main1920, CGRect(x: -1920, y: 0, width: 1920, height: 1080)]),
                    true, "OverlayPlacement: 落在副屏上也算可见")
        expectEqual(OverlayPlacement.isSufficientlyVisible(frame: peek(100, 100), screens: []), false,
                    "OverlayPlacement: 没有屏幕时不算可见")

        // 一块屏都没有（理论上不会发生）时别崩、别乱动。
        expectEqual(OverlayPlacement.repositionIfOffscreen(frame: onMain, screens: []) == nil, true,
                    "OverlayPlacement: 没有任何屏幕时不动")

        // 夹取结果跟原位置相同时不返回移动 —— 免得白白触发一次位置持久化。
        let exactlyAtEdge = CGRect(origin: CGPoint(x: 570, y: 100), size: overlaySize)
        expectEqual(OverlayPlacement.repositionIfOffscreen(frame: exactlyAtEdge, screens: [mainScreen]) == nil, true,
                    "OverlayPlacement: 已经在合法位置时不发多余的移动")
    }

    // ---- OverlayPlacement:启动还原不许跨屏搬家 ----
    //
    // 用户主诉"悬浮歌词经常在我主屏幕和副屏幕之间切换位置"的那条根因。几何全部取自这台机器的
    // 真实读数,不是编的:
    //   内置屏 visibleFrame = (0, 70, 1470, 853)      —— NSScreen.main
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

    // ---- 位置预设:自由 / 顶部居中 / 底部居中 ----
    //
    // 几何取这台机器内置屏的真实 visibleFrame (0, 70, 1470, 853):Dock 在底部占掉 70pt,菜单栏在
    // 顶上扣掉之后可见区顶边在 923。窗口 488×120(默认宽 / 地板高)。
    do {
        let screen = CGRect(x: 0, y: 70, width: 1470, height: 853)
        let size = CGSize(width: 488, height: 120)

        // 模式本身:rawValue 是持久化格式,别改;默认 free 才能让老用户零迁移。
        expectEqual(OverlayPlacementMode(rawValue: "free"), .free, "位置预设: rawValue free")
        expectEqual(OverlayPlacementMode(rawValue: "topCenter"), .topCenter, "位置预设: rawValue topCenter")
        expectEqual(OverlayPlacementMode(rawValue: "bottomCenter"), .bottomCenter, "位置预设: rawValue bottomCenter")
        expectEqual(OverlayPlacementMode.free.isPreset, false, "位置预设: free 不是预设")
        expectEqual(OverlayPlacementMode.topCenter.isPreset, true, "位置预设: topCenter 是预设")
        expectEqual(OverlayPlacementMode.bottomCenter.anchorsBottom, true, "位置预设: 只有 bottomCenter 守底边")
        expectEqual(OverlayPlacementMode.topCenter.anchorsBottom, false, "位置预设: topCenter 守顶边")
        expectEqual(OverlayPlacementMode.free.anchorsBottom, false, "位置预设: free 守顶边(现状)")
        expectEqual(OverlayPlacementMode.allCases.count, 3, "位置预设: 三档")

        // 自由:没有预设落点,调用方"那就别动"。
        expectEqual(OverlayPlacement.presetFrame(mode: .free, size: size, visibleFrame: screen) == nil, true,
                    "位置预设: free 不给落点")

        // 顶部居中 = x 居中、顶边贴着可见区顶(菜单栏底)下方 12 —— 跟底部同一个数(从 40 收紧)。
        let top = OverlayPlacement.presetFrame(mode: .topCenter, size: size, visibleFrame: screen)
        expectEqual(top?.midX, 735, "位置预设: 顶部居中 x 居中 (1470/2)")
        expectEqual(top?.maxY, 923 - OverlayPlacement.presetTopMargin, "位置预设: 顶部居中顶边距可见区顶 = 顶部边距")
        expectEqual(top?.size.height, 120, "位置预设: 顶部居中不改尺寸")
        expectEqual(OverlayPlacement.presetTopMargin, 12, "位置预设: 顶部边距 12(贴菜单栏,不是默认落点那个 40)")
        expectEqual(OverlayPlacement.presetTopMargin, OverlayPlacement.presetBottomMargin, "位置预设: 上下边距对称")

        // 底部居中 = 贴着可见区底边(Dock 顶)上方 12pt。
        let bottom = OverlayPlacement.presetFrame(mode: .bottomCenter, size: size, visibleFrame: screen)
        expectEqual(bottom?.midX, 735, "位置预设: 底部居中 x 居中")
        expectEqual(bottom?.minY, 70 + OverlayPlacement.presetBottomMargin, "位置预设: 底部居中底边在 Dock 顶上方 12")
        expectEqual(bottom?.size.width, 488, "位置预设: 底部居中不改尺寸")

        // 屏幕原点不是 (0,0)(外接屏常有负坐标)时跟着屏走。
        let external = CGRect(x: -526, y: 956, width: 2560, height: 1440)
        let onExternal = OverlayPlacement.presetFrame(mode: .bottomCenter, size: size, visibleFrame: external)
        expectEqual(onExternal?.midX, external.midX, "位置预设: 外接屏上按外接屏居中")
        expectEqual(onExternal?.minY, 956 + 12, "位置预设: 外接屏上贴外接屏的底边")

        // 增高:守顶边向下长(现状,逐字对得上 updateHeight 原逻辑)。
        let topFrame = top!
        let grownDown = OverlayPlacement.grownFrame(
            current: topFrame, contentHeight: 150.4, minHeight: 120, anchorsBottom: false, visibleFrame: screen)
        expectEqual(grownDown.maxY, topFrame.maxY, "增高: 守顶边时顶边不动")
        expectEqual(grownDown.height, 151, "增高: 高度 = ceil(内容高)")
        expectEqual(grownDown.minX, topFrame.minX, "增高: x 不动")
        // 地板:内容比 120 矮时窗口仍是 120。
        expectEqual(OverlayPlacement.grownFrame(
            current: topFrame, contentHeight: 70, minHeight: 120, anchorsBottom: false, visibleFrame: screen).height,
            120, "增高: 不低于地板")
        // 夹取:守顶边时底边不许越过可见区底边 —— 顶边 911(923−12)、可见区底 70,最多 841。
        let tallDown = OverlayPlacement.grownFrame(
            current: topFrame, contentHeight: 2000, minHeight: 120, anchorsBottom: false, visibleFrame: screen)
        expectEqual(tallDown.minY, 70, "增高: 守顶边时底边夹到可见区底边")
        expectEqual(tallDown.height, topFrame.maxY - 70, "增高: 守顶边时上限 = 顶边 − 可见区底边")

        // 增高:守底边向上长(底部居中)。 手动拖到底边贴着 Dock 顶的窗口
        // 照旧向下长的话,上限 = 顶边 − 可见区底边 = 120 = 地板,一点都长不了,译文直接被裁;
        // 预设留的 12pt 边距也只多给 12pt,150 的内容仍被裁掉一截。
        let flush = CGRect(x: 491, y: 70, width: 488, height: 120)
        let stuck = OverlayPlacement.grownFrame(
            current: flush, contentHeight: 150, minHeight: 120, anchorsBottom: false, visibleFrame: screen)
        expectEqual(stuck.height, 120, "增高: 底边贴 Dock 的窗口守顶边时长不了(坐实 issue #5 的坑)")
        let bottomFrame = bottom!
        let stuckPreset = OverlayPlacement.grownFrame(
            current: bottomFrame, contentHeight: 150, minHeight: 120, anchorsBottom: false, visibleFrame: screen)
        expectEqual(stuckPreset.height, 132, "增高: 底部预设位置守顶边时只能长到 Dock 顶(132),150 装不下")
        let grownUp = OverlayPlacement.grownFrame(
            current: bottomFrame, contentHeight: 150, minHeight: 120, anchorsBottom: true, visibleFrame: screen)
        expectEqual(grownUp.minY, bottomFrame.minY, "增高: 守底边时底边不动")
        expectEqual(grownUp.height, 150, "增高: 守底边时按内容长到 150")
        expectEqual(grownUp.maxY, bottomFrame.minY + 150, "增高: 守底边时顶边上移")
        // 夹取对称:守底边时顶边不许越过可见区顶边 —— 底边 82、可见区顶 923,最多 841。
        let tallUp = OverlayPlacement.grownFrame(
            current: bottomFrame, contentHeight: 2000, minHeight: 120, anchorsBottom: true, visibleFrame: screen)
        expectEqual(tallUp.maxY, 923, "增高: 守底边时顶边夹到可见区顶边")
        expectEqual(tallUp.height, 841, "增高: 守底边时上限 = 可见区顶边 − 底边")
        // 一块屏都不沾:不夹。
        expectEqual(OverlayPlacement.grownFrame(
            current: bottomFrame, contentHeight: 2000, minHeight: 120, anchorsBottom: true, visibleFrame: nil).height,
            2000, "增高: 没有可信边界时不夹")

        // 热区换算:内容贴底时内容块顶边离窗口顶边 = 窗高 − 内容高,按钮矩形要多扣这一截。
        typealias H = OverlayControlHitTest
        expectEqual(H.contentTopInset(anchorsBottom: false, windowHeight: 120, contentHeight: 70), 0,
                    "热区: 贴顶时 inset 恒为 0")
        expectEqual(H.contentTopInset(anchorsBottom: true, windowHeight: 120, contentHeight: 70), 50,
                    "热区: 贴底时 inset = 窗高 − 内容高")
        expectEqual(H.contentTopInset(anchorsBottom: true, windowHeight: 120, contentHeight: 150), -30,
                    "热区: 内容比窗还高(从顶上溢出)时 inset 为负")
        // 内容块里顶部 (y 0…20) 的一排按钮,在 120pt 窗里贴底放、内容高 70:按钮实际占窗口的 y 50…70。
        let btn = CGRect(x: 10, y: 0, width: 30, height: 20)
        let local = H.windowLocalRect(swiftUI: btn, windowHeight: 120, contentTopInset: 50)
        expectEqual(local.minY, 50, "热区: 贴底换算后按钮底边在窗口本地 y=50")
        expectEqual(local.maxY, 70, "热区: 贴底换算后按钮顶边在窗口本地 y=70")
        expectEqual(local.minX, 10, "热区: x 不受对齐影响")
        // inset 默认 0 = 原口径,既有调用点不变。
        expectEqual(H.windowLocalRect(swiftUI: btn, windowHeight: 120),
                    H.windowLocalRect(swiftUI: btn, windowHeight: 120, contentTopInset: 0),
                    "热区: 不传 inset 等于贴顶")
    }

    // ---- 圆钮块的短按 / 长按 / 右键判定 ----
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
    // 不能用 scaleEffect(x: f) 横向压缩满宽胶囊来画已播段:会把两端圆头一起压扁,
    // f 越小越方。改成满宽 + offset 移出 + 固定胶囊裁剪,圆头形状与 f 无关。这里钉住
    // 那个移出量,尤其是两头的夹值。
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
        // 对拍那一档(3 分钟的歌播到 0:04,f≈0.022):真实可见宽 6.6pt,已超过下限
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

    // ---- OverlayControlHitTest.controlsShown / unlockPillShown: 控制排 / 解锁提示
    //      该不该露出来(加开关,让解锁提示也接上开关) ----
    //
    // 这条判据以前散在两处(View 的 controlsVisible、控制器的 controlsShown),加「悬停控制条」
    // 开关时合并进 Core。这一组守的是合并后**两处等价**,以及两支(播放控制排 / 解锁提示)
    // 在「悬停控制条」开关下的表现。
    do {
        let H = OverlayControlHitTest.self

        // ① 基线:开关开着时行为跟改动前逐字一致 —— 悬停且未锁定才显示。
        expectEqual(H.controlsShown(hovering: true, positionLocked: false, hoverControlsEnabled: true),
                    true, "控制排: 开关开 + 悬停 + 未锁定 → 显示")
        expectEqual(H.controlsShown(hovering: false, positionLocked: false, hoverControlsEnabled: true),
                    false, "控制排: 没悬停不显示")
        expectEqual(H.controlsShown(hovering: true, positionLocked: true, hoverControlsEnabled: true),
                    false, "控制排: 锁定位置时不显示(那一格换成解锁提示)")
        expectEqual(H.unlockPillShown(hovering: true, positionLocked: true, hoverControlsEnabled: true),
                    true, "解锁提示: 开关开 + 悬停 + 锁定 → 显示")

        // ② 正题:开关关掉后,播放控制排 / 解锁提示都不显示——「悬停控制条」
        //    关掉时锁定态也不该在悬浮窗上冒出解锁图标,那本身就是开关没生效的表现;窗口之外还有
        //    菜单栏面板/菜单/全局热键三条解锁出路,不会把用户困住(见 unlockPillShown 声明处)。
        var shownWhileOff = 0
        for hovering in [false, true] {
            for locked in [false, true] {
                if H.controlsShown(hovering: hovering, positionLocked: locked, hoverControlsEnabled: false) {
                    shownWhileOff += 1
                }
                if H.unlockPillShown(hovering: hovering, positionLocked: locked, hoverControlsEnabled: false) {
                    shownWhileOff += 1
                }
            }
        }
        expectEqual(shownWhileOff, 0, "控制排/解锁提示: 开关关掉后 4 种悬停/锁定组合一律不显示")

        // ③ 两支恒不同时为真 —— 它们共用同一个槽位,同时为真就是两颗胶囊叠画。互斥性只系于
        //    positionLocked(controlsShown 要求 !locked、unlockPillShown 要求 locked),
        //    因此在 enabled 的所有组合下都该成立,不止 enabled=true 这一种。
        var bothTrue = 0
        for hovering in [false, true] {
            for locked in [false, true] {
                for enabled in [false, true] {
                    if H.controlsShown(hovering: hovering, positionLocked: locked, hoverControlsEnabled: enabled),
                       H.unlockPillShown(hovering: hovering, positionLocked: locked, hoverControlsEnabled: enabled) {
                        bothTrue += 1
                    }
                }
            }
        }
        expectEqual(bothTrue, 0, "控制排与解锁提示在 8 种组合下互斥(同一个槽位)")

        // ④ 「调整宽度」模式:不悬停也显示;锁定、关掉「悬停控制条」时照样不显示。
        expectEqual(H.controlsShown(hovering: false, positionLocked: false, hoverControlsEnabled: true, adjustingWidth: true),
                    true, "控制排: 调整宽度模式下不悬停也显示")
        expectEqual(H.controlsShown(hovering: false, positionLocked: true, hoverControlsEnabled: true, adjustingWidth: true),
                    false, "控制排: 调整宽度模式也压不过锁定")
        expectEqual(H.controlsShown(hovering: true, positionLocked: false, hoverControlsEnabled: false, adjustingWidth: true),
                    false, "控制排: 调整宽度模式也压不过「悬停控制条」关掉")
    }

    // MARK: - 悬浮歌词:拖窗口边缘改宽度(OverlayWidthDrag)
    do {
        typealias D = OverlayWidthDrag
        let size = CGSize(width: 400, height: 150)
        expectEqual(D.edge(at: CGPoint(x: 3, y: 70), windowSize: size), .leading, "调宽: 左缘 10pt 内算左边")
        expectEqual(D.edge(at: CGPoint(x: 395, y: 10), windowSize: size), .trailing, "调宽: 右缘 10pt 内算右边")
        expectEqual(D.edge(at: CGPoint(x: 200, y: 70), windowSize: size), nil, "调宽: 中间不算边缘")
        expectEqual(D.edge(at: CGPoint(x: 11, y: 70), windowSize: size), nil, "调宽: 离左缘 11pt 已经不算")
        expectEqual(D.edge(at: CGPoint(x: -2, y: 70), windowSize: size), nil, "调宽: 窗口外不算(那是下层 App 的)")
        expectEqual(D.edge(at: CGPoint(x: 3, y: 151), windowSize: size), nil, "调宽: 窗口上下之外不算")
        expectEqual(D.edge(at: CGPoint(x: 9, y: 5), windowSize: CGSize(width: 24, height: 50)), nil,
                    "调宽: 窗口很窄时每侧最多四分之一宽")

        let start = CGRect(x: 100, y: 500, width: 400, height: 150)
        let range: ClosedRange<CGFloat> = 300 ... 1400
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // 自由位置:拖哪边动哪边。
        var r = D.resizedFrame(start: start, edge: .trailing, deltaX: 60, symmetric: false, widthRange: range, visibleFrame: screen)
        expectEqual(r, CGRect(x: 100, y: 500, width: 460, height: 150), "调宽: 拖右缘右移 60 → 左缘不动、宽 +60")
        r = D.resizedFrame(start: start, edge: .leading, deltaX: -50, symmetric: false, widthRange: range, visibleFrame: screen)
        expectEqual(r, CGRect(x: 50, y: 500, width: 450, height: 150), "调宽: 拖左缘左移 50 → 右缘不动、宽 +50")
        r = D.resizedFrame(start: start, edge: .leading, deltaX: 30, symmetric: false, widthRange: range, visibleFrame: screen)
        expectEqual(r.maxX, start.maxX, "调宽: 拖左缘右移时右缘仍不动")
        // 宽度夹进区间。
        r = D.resizedFrame(start: start, edge: .trailing, deltaX: -300, symmetric: false, widthRange: range, visibleFrame: screen)
        expectEqual(r.width, 300, "调宽: 不窄于下限")
        r = D.resizedFrame(start: start, edge: .leading, deltaX: 200, symmetric: false, widthRange: range, visibleFrame: screen)
        expectEqual(r, CGRect(x: 200, y: 500, width: 300, height: 150), "调宽: 左缘拖到下限时右缘仍不动")
        // 被拖的边不越过可见区。
        r = D.resizedFrame(start: start, edge: .trailing, deltaX: 2000, symmetric: false, widthRange: range, visibleFrame: screen)
        expectEqual(r.maxX, screen.maxX, "调宽: 右缘最多拖到可见区右边")
        r = D.resizedFrame(start: start, edge: .leading, deltaX: -2000, symmetric: false, widthRange: range, visibleFrame: screen)
        expectEqual(r.minX, screen.minX, "调宽: 左缘最多拖到可见区左边")
        r = D.resizedFrame(start: start, edge: .trailing, deltaX: 2000, symmetric: false, widthRange: range, visibleFrame: nil)
        expectEqual(r.width, 1400, "调宽: 不沾任何屏时只受区间上限")
        // 预设位置:对称伸缩,中心不动。
        r = D.resizedFrame(start: start, edge: .trailing, deltaX: 40, symmetric: true, widthRange: range, visibleFrame: screen)
        expectEqual(r, CGRect(x: 60, y: 500, width: 480, height: 150), "调宽: 预设下拖右缘 40 → 两边各长 40")
        r = D.resizedFrame(start: start, edge: .leading, deltaX: 40, symmetric: true, widthRange: range, visibleFrame: screen)
        expectEqual(r.midX, start.midX, "调宽: 预设下拖左缘右移仍居中")
        expectEqual(r.width, 320, "调宽: 预设下拖左缘右移 40 → 窄 80")
        r = D.resizedFrame(start: start, edge: .trailing, deltaX: 5000, symmetric: true, widthRange: range, visibleFrame: screen)
        expectEqual(r.width, 1400, "调宽: 预设下对称放大也受区间上限")
        expectEqual(r.minX >= screen.minX && r.maxX <= screen.maxX, true, "调宽: 预设下对称放大不出可见区")
        // 取整。
        r = D.resizedFrame(start: start, edge: .trailing, deltaX: 10.4, symmetric: false, widthRange: range, visibleFrame: screen)
        expectEqual(r.width, 410, "调宽: 宽度取整")
    }

    // MARK: - 歌词窗口:自定义背景色该配白字还是深色字(LyricsWindowBackgroundLuma)
    //
    // 这一组钉的是"用户填了背景色之后,窗里的文字还看不看得见"。歌词窗口的正文一直是白的,
    // 那是因为封面背景**必然**够暗(烘焙压过 EV −1.9 + 0.15 黑遮罩);能自己填色之后这个前提
    // 就没了。判据里有 sRGB 线性化、alpha 与窗口底色混合、渐变取平均三处,算错了不会崩、
    // 只会让某个配色下文字静默糊掉,肉眼盯界面是发现不了边界的。
    do {
        typealias L = LyricsWindowBackgroundLuma

        // ---- hex 解析:三种合法写法 + 认不出来就是认不出来 ----
        expectEqual(L.parse(hex: "#000000")?.a, 1, "背景色: 6 位 hex 的 alpha 补满")
        expectEqual(L.parse(hex: "000000FF")?.a, 1, "背景色: 井号可省")
        expectEqual(L.parse(hex: "#00000080").map { ($0.a * 100).rounded() / 100 }, 0.5,
                    "背景色: 8 位 hex 读出 alpha")
        expectEqual(L.parse(hex: "#12345") == nil, true, "背景色: 位数不对 → nil(不要自己编默认色)")
        expectEqual(L.parse(hex: "#GGGGGG") == nil, true, "背景色: 非十六进制 → nil")

        // ---- 不透明色:两端 ----
        expectEqual(L.prefersLightText(hexes: ["#000000FF"], darkAppearance: false), true,
                    "背景色: 纯黑 → 白字")
        expectEqual(L.prefersLightText(hexes: ["#FFFFFFFF"], darkAppearance: false), false,
                    "背景色: 纯白 → 深色字")
        // 浅黄正是"白字会直接消失"的那一类,加这颗设置之前它必然出事
        expectEqual(L.prefersLightText(hexes: ["#FFE680FF"], darkAppearance: true), false,
                    "背景色: 浅黄 → 深色字(不因为系统是深色模式就维持白字)")
        // 默认的自定义色必须落在白字一侧 —— 否则用户切到「纯色」第一眼就是文字翻转
        expectEqual(L.prefersLightText(hexes: ["#2B2D42FF"], darkAppearance: false), true,
                    "背景色: 默认深蓝灰 → 白字")

        // ---- 半透明:同一个颜色,结论跟着系统外观走 ----
        // 半透明黑盖在浅色窗口底上,实际看到的是中灰偏亮,白字在上面是看不清的。
        // 这条最容易写错成"只看颜色自己的亮度",那样两种外观会给出同一个答案。
        expectEqual(L.prefersLightText(hexes: ["#00000080"], darkAppearance: false), false,
                    "背景色: 半透明黑 + 浅色外观 → 混出中灰,该用深色字")
        expectEqual(L.prefersLightText(hexes: ["#00000080"], darkAppearance: true), true,
                    "背景色: 同一个半透明黑 + 深色外观 → 仍然是暗底,白字")
        // 全透明 = 整个就是窗口底色,结论完全由外观决定
        expectEqual(L.prefersLightText(hexes: ["#FFFFFF00"], darkAppearance: true), true,
                    "背景色: alpha 0 → 看的是窗口底色,深色外观下白字")
        expectEqual(L.prefersLightText(hexes: ["#00000000"], darkAppearance: false), false,
                    "背景色: alpha 0 + 浅色外观 → 深色字")

        // ---- 渐变:取两端平均 ----
        expectEqual(L.prefersLightText(hexes: ["#000000FF", "#FFFFFFFF"], darkAppearance: false), false,
                    "背景色: 黑到白渐变取平均(0.5)→ 越过阈值,深色字")
        expectEqual(L.prefersLightText(hexes: ["#000000FF", "#333333FF"], darkAppearance: false), true,
                    "背景色: 黑到深灰渐变 → 主体仍是暗的,白字")

        // ---- 认不出来时维持这扇窗原来的样子,不要翻转 ----
        expectEqual(L.prefersLightText(hexes: ["坏值"], darkAppearance: false), true,
                    "背景色: 颜色认不出来 → 维持白字(不拿坏配置去翻转文字)")
        expectEqual(L.prefersLightText(hexes: [], darkAppearance: false), true,
                    "背景色: 一个颜色都没有 → 维持白字")

        // ---- 档位:一档跟封面,两档自定义完全不碰封面 ----
        expectEqual(LyricsWindowBackgroundMode.artwork.usesArtwork, true, "背景档: 跟随封面用封面")
        expectEqual(LyricsWindowBackgroundMode.solid.usesArtwork, false, "背景档: 纯色不碰封面")
        expectEqual(LyricsWindowBackgroundMode.gradient.usesArtwork, false, "背景档: 渐变不碰封面")
        expectEqual(LyricsWindowBackgroundMode.glass.usesArtwork, false, "背景档: 毛玻璃不碰封面")
        // 颜色那一行只该在这两档出现 —— 毛玻璃画的是系统材质、不读颜色,跟随封面更不读。
        expectEqual(LyricsWindowBackgroundMode.solid.usesCustomColor, true, "背景档: 纯色要给颜色")
        expectEqual(LyricsWindowBackgroundMode.gradient.usesCustomColor, true, "背景档: 渐变要给颜色")
        expectEqual(LyricsWindowBackgroundMode.glass.usesCustomColor, false,
                    "背景档: 毛玻璃**不**读颜色(别再让颜色行跟着冒出来)")
        expectEqual(LyricsWindowBackgroundMode.artwork.usesCustomColor, false, "背景档: 跟随封面不读颜色")
        expectEqual(LyricsWindowBackgroundMode.allCases.count, 4, "背景档: 就四档")
        // 毛玻璃折射的是窗口背后的桌面 —— 窗口自己不透明的话它只折射得到窗口底色,看着是块死灰。
        // 这条不是观感取舍,是这一档能不能成立的前提,所以钉在类型上、不留给调用方记着。
        expectEqual(LyricsWindowBackgroundMode.glass.alwaysNeedsTransparentWindow, true,
                    "背景档: 毛玻璃必须让窗口透出去")
        for mode in [LyricsWindowBackgroundMode.artwork, .solid, .gradient] {
            expectEqual(mode.alwaysNeedsTransparentWindow, false,
                        "背景档: 只有毛玻璃恒需透明窗口(\(mode.rawValue) 另看 alpha)")
        }
        // 删掉的那一档:存过它的配置必须认不出来,这样 AppSettings 那边的
        // `flatMap(init(rawValue:)) ?? .artwork` 才会把它退回默认档,而不是卡在一个不存在的状态。
        expectEqual(LyricsWindowBackgroundMode(rawValue: "artworkBlur") == nil, true,
                    "背景档: 已删的「模糊封面」rawValue 认不出来 → 调用方回落默认档")

        // ---- 渐变方向 ----
        expectEqual(LyricsWindowGradientDirection.allCases.count, 2, "渐变方向: 竖向 / 横向")
        expectEqual(LyricsWindowGradientDirection(rawValue: "vertical"), .vertical, "渐变方向: 竖向 rawValue")
        expectEqual(LyricsWindowGradientDirection(rawValue: "horizontal"), .horizontal, "渐变方向: 横向 rawValue")
    }
}
