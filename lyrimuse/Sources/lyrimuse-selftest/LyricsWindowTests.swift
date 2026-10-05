import LyrimuseCore
import CoreGraphics
import Foundation

// 歌词窗口:空状态优先级 / 字号公式 / 景深 / 迷你两行选取 / 窗口位置恢复 / 文字色调 / AM vibrancy /
// Last.fm 喜欢的写法与编解码 / 迷你顶部显示项,以及逐字填色、进度条共用的进度外推时钟。
// 由 main.swift 的注册表按组调用。窗口视图本身在 App target 里,这里测的是它调用的 Core 规则。

/// 浮点比较:保留三位小数。
private func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
private func r3(_ x: CGFloat) -> Double { r3(Double(x)) }

@MainActor
func runLyricsWindowTests() {
    // ---- 歌词窗口的空格 / ← / → ----
    do {
        print("\n== 歌词窗口按键 ==")
        typealias K = LyricsWindowKeyCommand
        func cmd(_ code: UInt16, mods: Bool = false, repeated: Bool = false, focus: Bool = false) -> K? {
            K.command(keyCode: code, hasModifiers: mods, isRepeat: repeated, keyboardFocusElsewhere: focus)
        }
        expectEqual(cmd(K.spaceKeyCode), .togglePlayPause, "歌词窗口按键: 空格播放 / 暂停")
        expectEqual(cmd(K.leftArrowKeyCode), .previousTrack, "歌词窗口按键: ← 上一首")
        expectEqual(cmd(K.rightArrowKeyCode), .nextTrack, "歌词窗口按键: → 下一首")
        expectEqual(K.spaceKeyCode, 49, "歌词窗口按键: 空格是 kVK_Space")
        expectEqual(K.leftArrowKeyCode, 123, "歌词窗口按键: ← 是 kVK_LeftArrow")
        expectEqual(K.rightArrowKeyCode, 124, "歌词窗口按键: → 是 kVK_RightArrow")
        expectEqual(cmd(53), nil, "歌词窗口按键: Esc 不接(留给退出全屏)")
        expectEqual(cmd(126), nil, "歌词窗口按键: ↑ 不接")
        expectEqual(cmd(36), nil, "歌词窗口按键: 回车不接")
        expectEqual(cmd(K.spaceKeyCode, mods: true), nil, "歌词窗口按键: 带修饰键的组合放行给菜单和系统")
        expectEqual(cmd(K.rightArrowKeyCode, mods: true), nil, "歌词窗口按键: ⌘→ 这类组合放行")
        expectEqual(cmd(K.spaceKeyCode, repeated: true), nil, "歌词窗口按键: 按住空格的自动重复不再来回切")
        expectEqual(cmd(K.rightArrowKeyCode, repeated: true), nil, "歌词窗口按键: 按住 → 不连跳")
        expectEqual(cmd(K.spaceKeyCode, focus: true), nil, "歌词窗口按键: 焦点在输入框或控件上时空格放行")
        expectEqual(cmd(K.leftArrowKeyCode, focus: true), nil, "歌词窗口按键: 焦点在滑块上时方向键放行")
        // 焦点:悬浮歌词 / 灵动岛 / 菜单栏点了之后 key window 仍是歌词窗口,但焦点已经不在它身上。
        var focus = K.Focus()
        expectEqual(focus.isFocused, false, "歌词窗口焦点: 起点不在")
        focus.windowBecameKey()
        expectEqual(focus.isFocused, true, "歌词窗口焦点: 窗口成为 key 时在")
        focus.mouseDown(inLyricsWindow: false)
        expectEqual(focus.isFocused, false, "歌词窗口焦点: 点了本 App 别的窗口(悬浮歌词 / 灵动岛)就不在")
        focus.mouseDown(inLyricsWindow: true)
        expectEqual(focus.isFocused, true, "歌词窗口焦点: 再点回歌词窗口又在")
        focus.windowResignedKey()
        expectEqual(focus.isFocused, false, "歌词窗口焦点: 窗口失去 key 就不在")
        focus.windowBecameKey()
        expectEqual(focus.isFocused, true, "歌词窗口焦点: 切回来窗口重新成为 key,不用再点一次")
        expectEqual(K.Focus(isFocused: true).isFocused, true, "歌词窗口焦点: 装上时窗口已经是 key 就从「在」开始")
    }

    // MARK: - 空状态:顺序就是优先级
    do {
        typealias E = LyricsWindowEmptyState
        let everything = E.Inputs(hasTitle: true, isAdBreak: true, isRadioTalkBreak: true,
                                  isInstrumental: true, hasNoLyrics: true, engineNetworkDown: true,
                                  hasLyricsContent: false, isPlaying: true)
        expectEqual(E.resolve(E.Inputs(hasTitle: false, isAdBreak: true, isPlaying: true)), .notPlaying,
                    "空状态: 曲名为空时一律「没有在播放」,哪怕别的标志还挂着")
        expectEqual(E.resolve(everything), .adBreak, "空状态: 广告排在口白 / 纯音乐 / 搜索之前")
        var i = everything
        i.isAdBreak = false
        expectEqual(E.resolve(i), .radioTalk, "空状态: 口白排在纯音乐之前(元数据还停在上一首)")
        i.isRadioTalkBreak = false
        expectEqual(E.resolve(i), .instrumental, "空状态: 纯音乐排在暂无歌词之前")
        i.isInstrumental = false
        expectEqual(E.resolve(i), .noLyrics, "空状态: 暂无歌词(明确结论)排在网络失败之前")
        i.hasNoLyrics = false
        expectEqual(E.resolve(i), .networkDown, "空状态: 断网且没有歌词内容 → 网络连接失败,不是一直「搜索中」")
        i.engineNetworkDown = false
        expectEqual(E.resolve(i), .searching, "空状态: 在放、没有内容、没有定论 → 搜索中")
        i.isPlaying = false
        expectEqual(E.resolve(i), .none, "空状态: 暂停且没有内容 → 兜底「无歌词」")
        expectEqual(E.resolve(E.Inputs(hasTitle: true, engineNetworkDown: true, hasLyricsContent: true,
                                       isPlaying: true)), .none,
                    "空状态: 有歌词内容时断网不算失败(内容已经在手里)")
        expectEqual([E.notPlaying, .adBreak, .radioTalk, .instrumental, .noLyrics, .networkDown, .searching, .none]
                        .filter(\.offersSearch), [.noLyrics, .networkDown],
                    "空状态: 只有「暂无歌词」「网络连接失败」给搜索入口")
        expectEqual(E.radioTalk.icon, "dot.radiowaves.left.and.right", "空状态: 口白图标")
    }

    // MARK: - 字号公式
    do {
        typealias T = LyricsWindowTypography
        expectEqual(r3(T.listFontSize(columnWidth: 896.7, viewportHeight: 845)), r3(845 * 0.0598),
                    "列表字号: AM 标定窗口下高度锚 0.0598×视口高")
        expectEqual(r3(T.listFontSize(columnWidth: 500, viewportHeight: 845)), r3(500 * 0.0564),
                    "列表字号: 栏偏窄时宽度锚 0.0564×栏宽接管")
        expectEqual(T.listFontSize(columnWidth: 200, viewportHeight: 200), 22, "列表字号: 下限 22")
        expectEqual(r3(T.listFontSize(columnWidth: 0, viewportHeight: 0)), r3(min(640 * 0.0598, 460 * 0.0564)),
                    "列表字号: 还没量到栏尺寸时按 460×640 算")
        expectEqual(T.listFontSize(columnWidth: 2000, viewportHeight: 2000, cap: 34), 34,
                    "列表字号: 迷你多行吃字号上限")
        expectEqual(T.listFontSize(columnWidth: 200, viewportHeight: 200, cap: 34), 22,
                    "列表字号: 上限只压大不抬小")
        expectEqual(r3(T.miniFontSize(CGSize(width: 420, height: 250), cap: 40)), r3(420 * 0.075),
                    "迷你字号: 默认尺寸下宽度锚 0.075×宽")
        expectEqual(T.miniFontSize(CGSize(width: 2000, height: 2000), cap: 30), 30,
                    "迷你字号: 大窗口按用户上限")
        expectEqual(T.miniFontSize(CGSize(width: 100, height: 50), cap: 30), 12,
                    "迷你字号: 下限 12")
    }

    // MARK: - 景深
    do {
        typealias D = LyricsWindowDepth
        expectEqual(D.distance(index: 5, anchorIndex: 5, inGap: false), 0, "景深: 当前行距离 0")
        expectEqual(D.distance(index: 3, anchorIndex: 5, inGap: false), -2, "景深: 上面唱过的行距离为负")
        expectEqual(D.distance(index: 7, anchorIndex: 5, inGap: false), 2, "景深: 下面没唱到的行距离为正")
        expectEqual(D.distance(index: 5, anchorIndex: 5, inGap: true), -1, "景深: 间奏中刚唱完那行在「•••」上面第 1 行")
        expectEqual(D.distance(index: 6, anchorIndex: 5, inGap: true), 1, "景深: 间奏中下一句在「•••」下面第 1 行")
        expectEqual(D.distance(index: 3, anchorIndex: 5, inGap: true), -3, "景深: 间奏中更早的行从「•••」往上数")
        expectEqual(D.distance(index: 0, anchorIndex: 40, inGap: false), -D.maxDistance, "景深: 往上封顶 4")
        expectEqual(D.distance(index: 40, anchorIndex: 0, inGap: false), D.maxDistance, "景深: 往下封顶 4")
        expectEqual(D.distance(index: 3, anchorIndex: nil, inGap: false), nil, "景深: 没有锚点 → nil")
        expectEqual(D.opacity(distance: 0), 1, "景深: 当前行不透明度 1")
        expectEqual(r3(D.opacity(distance: 1)), 0.56, "景深: 下面第 1 行 0.56")
        expectEqual(r3(D.opacity(distance: -1)), 0.36, "景深: 上面第 1 行 0.36")
        expectEqual(r3(D.opacity(distance: 2)), 0.54, "景深: 下面第 2 行 0.54")
        expectEqual(r3(D.opacity(distance: -4)), 0.22, "景深: 上面第 4 行到底 0.22")
        expectEqual((1...D.maxDistance).allSatisfy { D.opacity(distance: $0) > D.opacity(distance: -$0) }, true,
                    "景深: 一样远时下面没唱到的比上面唱过的亮")
        expectEqual((1..<D.maxDistance).allSatisfy {
            D.opacity(distance: $0 + 1) <= D.opacity(distance: $0)
                && D.opacity(distance: -$0 - 1) <= D.opacity(distance: -$0)
        }, true, "景深: 越远越暗")
        expectEqual(D.opacity(distance: nil), 0.45, "景深: 没有锚点 0.45")
        expectEqual(D.blurRadius(distance: 0, fontSize: 50), 0, "景深: 当前行不糊")
        expectEqual(r3(D.blurRadius(distance: 1, fontSize: 100)), 4.2, "景深: 下面第 1 行 0.042×字号")
        expectEqual(r3(D.blurRadius(distance: -1, fontSize: 100)), 5.5, "景深: 上面第 1 行 0.055×字号,比下面糊")
        expectEqual(r3(D.blurRadius(distance: 3, fontSize: 100) - D.blurRadius(distance: 2, fontSize: 100)), 1.9,
                    "景深: 每远一行加 0.019×字号")
        expectEqual(r3(D.blurRadius(distance: nil, fontSize: 100)), 3, "景深: 没有锚点 0.03×字号")
    }

    // MARK: - 换句逐行错开
    do {
        typealias S = LyricsLineStagger
        expectEqual(S.progress(elapsedMs: 0), 0, "错开: 起步那一刻不动")
        expectEqual(S.progress(elapsedMs: -30), 0, "错开: 没到起步时刻不动")
        let half = (1...400).first { S.progress(elapsedMs: Double($0)) >= 0.5 } ?? 0
        expectEqual((140...165).contains(half), true, "错开: 约 0.15 秒走到一半(Apple 录屏拟合)")
        let peak = (1...1500).map { S.progress(elapsedMs: Double($0)) }.max() ?? 0
        expectEqual(peak < 1.01, true, "错开: 不回弹,过冲不到 1%(Apple 录屏拟合)")
        expectEqual(S.springDampingRatio < 1, true, "错开: 阻尼比小于 1(progress 按欠阻尼解算)")
        expectEqual(abs(S.progress(elapsedMs: S.springSettleMs) - 1) <= 0.005, true, "错开: 落定时刻剩余不到千分之五")
        expectEqual(S.delayMs(distanceFromTop: -100, fontSize: 50), 0, "错开: 视口顶上面的行不等")
        expectEqual(r3(S.delayMs(distanceFromTop: 150, fontSize: 50)), 50, "错开: 往下 3 倍字号晚 50ms")
        expectEqual(S.delayMs(distanceFromTop: 100_000, fontSize: 50), S.maxDelayMs, "错开: 起步延迟封顶")
        expectEqual(S.remaining(elapsedMs: 30, delayMs: 50), 1, "错开: 起步前整段垫着")
        expectEqual(abs(S.remaining(elapsedMs: S.settleMs, delayMs: S.maxDelayMs)) <= 0.005, true,
                    "错开: settleMs 时最晚起步的那行也落定")
    }

    // MARK: - 跑马灯的滚动动画(源码契约)
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let marquee = (try? String(contentsOf: root.appendingPathComponent("lyrimuse/UI/MarqueeText.swift"),
                                   encoding: .utf8)) ?? ""
        expectEqual(marquee.isEmpty, false, "跑马灯(契约): 读到源码")
        expectEqual(sourceBytes(marquee, contain: ".transaction { $0.animation = nil }\n            .geometryGroup()\n            .offset(x: -offset)"),
                    true, "跑马灯(契约): 内容摘掉动画之后先 geometryGroup 再 offset —— 少了它 offset 的滚动动画一起被摘掉,一步跳到终点")
    }

    // MARK: - 在动的可点内容不常驻命中(源码契约)
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let window = (try? String(contentsOf: root.appendingPathComponent("lyrimuse/UI/LyricsWindowView.swift"),
                                  encoding: .utf8)) ?? ""
        expectEqual(window.isEmpty, false, "命中(契约): 读到源码")
        expectEqual(sourceBytes(window, contain: ".modifier(LineStagger(model: staggers ? stagger : .inert, fontSize: fontSize))\n        .allowsHitTesting(false)\n"),
                    true, "命中(契约): 歌词行的错开位移连同行内容不参与命中,悬停 / 点按由外面不动的矩形接 —— 在动的可命中内容让主线程每帧重算标题栏拖窗区")
    }

    // MARK: - 逐帧时钟节流(FrameCadence)
    do {
        typealias C = FrameCadence
        expectEqual(C.isDue(sinceLast: 1.0 / 60, minimumInterval: 1.0 / 60), true, "节流: 60Hz 屏上要 60Hz,每帧都刷")
        expectEqual(C.isDue(sinceLast: 0.0160, minimumInterval: 1.0 / 60), true, "节流: 帧间隔抖短 0.7ms 仍算到点,不隔帧")
        expectEqual(C.isDue(sinceLast: 1.0 / 120, minimumInterval: 1.0 / 60), false, "节流: 120Hz 屏上要 60Hz,隔一帧刷")
        expectEqual(C.isDue(sinceLast: 2.0 / 120, minimumInterval: 1.0 / 60), true, "节流: 120Hz 屏上第二帧到点")
        expectEqual(C.isDue(sinceLast: 0.001, minimumInterval: 0), true, "节流: 间隔 0 每帧都刷")
        var updates = 0
        var last = -1.0
        for k in 0..<60 {
            let t = Double(k) / 60
            if C.isDue(sinceLast: t - last, minimumInterval: 0.25) {
                updates += 1
                last = t
            }
        }
        expectEqual(updates, 4, "节流: 0.25 秒档在 60Hz 屏上每秒刷 4 次")
    }

    // MARK: - 各行景深的过渡曲线(LyricsDepthMotion,07 章决策 106)
    do {
        typealias M = LyricsDepthMotion
        expectEqual(M.progress(.line, elapsed: 0), 0, "景深过渡: 换句弹簧从 0 起")
        expectEqual(abs(M.progress(.line, elapsed: 0.225) - 0.8210) < 0.001, true,
                    "景深过渡: 半个 response 走到 82%(同 SwiftUI .smooth(duration: 0.45) 那条临界阻尼弹簧)")
        expectEqual(abs(M.progress(.line, elapsed: 0.45) - 0.9864) < 0.001, true, "景深过渡: 一个 response 走到 98.6%")
        expectEqual(abs(M.settleSeconds(.line) - 0.6613) < 0.001, true, "景深过渡: 离终点不到千分之一算走完,约 0.66 秒")
        expectEqual(M.progress(.line, elapsed: M.settleSeconds(.line)), 1, "景深过渡: 走完恒为 1")
        let ramp = stride(from: 0.0, through: 0.7, by: 0.005).map { M.progress(.line, elapsed: $0) }
        expectEqual(zip(ramp, ramp.dropFirst()).allSatisfy { $1 >= $0 }, true, "景深过渡: 换句弹簧单调、不过冲")
        expectEqual(abs(M.progress(.hover, elapsed: 0.08) - 0.6846) < 0.001, true,
                    "景深过渡: 悬停走一半时间到 68.5%(同 SwiftUI .easeOut(duration: 0.16))")
        expectEqual(abs(M.progress(.hover, elapsed: 0.04) - 0.3781) < 0.001, true, "景深过渡: 悬停走四分之一时间到 37.8%")
        expectEqual(M.progress(.hover, elapsed: 0.16), 1, "景深过渡: 悬停 0.16 秒到位")
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        var ch = M.Channel(value: 0.3, now: t0)
        expectEqual(ch.isMoving(at: t0), false, "景深过渡: 新建时不动")
        ch.retarget(to: 1, curve: .line, now: t0)
        let t1 = t0.addingTimeInterval(0.1)
        let mid = ch.value(at: t1)
        expectEqual(mid > 0.3 && mid < 1, true, "景深过渡: 走到一半在两端之间(\(mid))")
        ch.retarget(to: 0.2, curve: .line, now: t1)
        expectEqual(abs(ch.value(at: t1) - mid) < 1e-12, true, "景深过渡: 中途换目标从此刻画着的值接着走,不跳")
        expectEqual(ch.isMoving(at: t1.addingTimeInterval(0.3)), true, "景深过渡: 换目标之后还在走")
        let done = t1.addingTimeInterval(M.settleSeconds(.line))
        expectEqual(ch.value(at: done), 0.2, "景深过渡: 走完停在新目标")
        expectEqual(ch.isMoving(at: done), false, "景深过渡: 走完不再动")
        expectEqual(ch.end, done, "景深过渡: 走完的时刻 = 开始 + 这条曲线的时长")
        ch.retarget(to: 0.9, curve: nil, now: t0.addingTimeInterval(5))
        expectEqual(ch.value(at: t0.addingTimeInterval(5)), 0.9, "景深过渡: 瞬时那一种直接落到目标")
        expectEqual(ch.isMoving(at: t0.addingTimeInterval(5)), false, "景深过渡: 瞬时不开时钟")
    }

    // MARK: - 各行景深逐帧推、不挂隐式动画(源码契约)
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let window = (try? String(contentsOf: root.appendingPathComponent("lyrimuse/UI/LyricsWindowView.swift"),
                                  encoding: .utf8)) ?? ""
        expectEqual(window.isEmpty, false, "景深(契约): 读到源码")
        expectEqual(sourceBytes(window, contain: ".animation(LyricsWindowView.lineTransition, value: distance)"), false,
                    "景深(契约): 歌词行和创作者行不挂 SwiftUI 隐式动画 —— 进程里有 SwiftUI ScrollView 时它每帧渲染两次")
        expectEqual(sourceBytes(window, contain: ".animation(isActive ? nil : LyricsWindowView.lineTransition"), false,
                    "景深(契约): 当前行的不透明度也不靠隐式动画")
        expectEqual(window.components(separatedBy: ".modifier(RowDepth(inputs: .init(").count - 1, 2,
                    "景深(契约): 歌词行和创作者行都走 RowDepth")
        expectEqual(sourceBytes(window, contain: "o.retarget(to: new.opacity, curve: curve == .line && new.isActive ? nil : curve, now: now)"), true,
                    "景深(契约): 换句时当前行的不透明度瞬时到位(跟着爬会跟填色相乘出先暗一拍的凹陷)")
        expectEqual(window.components(separatedBy: "FrameTimeline(timebase: .transition, paused: !moving) { now in").count - 1, 2,
                    "景深(契约): 时钟是这扇窗的 display link(各行景深与滚动指示条)")
        expectEqual(sourceBytes(window, contain: "isActive: isActive)))\n        // 外层的动画"), true,
                    "景深(契约): 整行外面挡一道外层动画,景深自己逐帧走")
        expectEqual(sourceBytes(window, contain: "static let lineTransition: Animation = .smooth(duration: 0.45)"), true,
                    "景深(契约): 进出间奏那条曲线还是 0.45 秒")
        expectEqual(LyricsDepthMotion.lineResponse, 0.45, "景深(契约): 各行逐帧算的弹簧跟 lineTransition 同一个时长")
        expectEqual(sourceBytes(window, contain: ".animation(metrics.glides ? Self.glide : nil, value: f)"), false,
                    "景深(契约): 滚动指示条换句那一下也不挂 SwiftUI 隐式动画")
        expectEqual(sourceBytes(window, contain: "ch.retarget(to: new, curve: metrics.glides ? .line : nil, now: now)"), true,
                    "景深(契约): 指示条换句时沿同一条弹簧逐帧推,用户自己滚时直接跟手")
    }

    // MARK: - 歌词窗口逐帧时钟走 display link(源码契约)
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let window = (try? String(contentsOf: root.appendingPathComponent("lyrimuse/UI/LyricsWindowView.swift"),
                                  encoding: .utf8)) ?? ""
        let frame = (try? String(contentsOf: root.appendingPathComponent("lyrimuse/UI/FrameTimeline.swift"),
                                 encoding: .utf8)) ?? ""
        expectEqual(window.isEmpty || frame.isEmpty, false, "逐帧时钟(契约): 读到源码")
        expectEqual(sourceBytes(window, contain: "TimelineView(.animation("), false,
                    "逐帧时钟(契约): 歌词窗口不用 TimelineView(.animation) —— 进程里有 SwiftUI ScrollView 时它驱动的每一帧要完整渲染两次")
        expectEqual(sourceBytes(window, contain: "FrameTimeline(minimumInterval: WordKaraokeGradient.windowRefreshInterval,"), true,
                    "逐帧时钟(契约): 逐字填色细时钟走 FrameTimeline")
        expectEqual(sourceBytes(window, contain: "FrameTimeline(minimumInterval: Self.coarseInterval,"), true,
                    "逐帧时钟(契约): 逐字填色粗时钟走 FrameTimeline")
        expectEqual(sourceBytes(window, contain: "FrameTimeline(timebase: .transition, paused: shifts.isEmpty)"), true,
                    "逐帧时钟(契约): 换句错开走 FrameTimeline")
        expectEqual(sourceBytes(window, contain: ".environment(\\.frameClock, frameClock)"), true,
                    "逐帧时钟(契约): 时钟挂在这一份所在的窗口上")
        expectEqual(sourceBytes(frame, contain: "displayLink(target: proxy, selector: selector)"), true,
                    "逐帧时钟(契约): 时钟是宿主窗口的 display link")
    }

    // MARK: - 过渡的时间轴扣掉主线程卡住的那段(FrameStall,07 章决策 108)
    do {
        let f60 = 1.0 / 60, f120 = 1.0 / 120
        expectEqual(FrameStall.missedSeconds(gap: f60, frame: f60), 0, "卡顿: 正常一帧不算")
        expectEqual(FrameStall.missedSeconds(gap: 2 * f60, frame: f60), 0, "卡顿: 偶尔掉一帧不算")
        expectEqual(FrameStall.missedSeconds(gap: 2 * f120, frame: f120), 0,
                    "卡顿: 120Hz 屏降到 60Hz 跑不算 —— 算的话每一帧都是卡顿,过渡慢一半")
        expectEqual(FrameStall.missedSeconds(gap: 0.028, frame: f120), 0, "卡顿: 不到 30ms 的空档不算")
        expectEqual(abs(FrameStall.missedSeconds(gap: 0.072, frame: f60) - (0.072 - f60)) < 1e-12, true,
                    "卡顿: 卡了几帧,多出一帧的那段都扣掉")
        expectEqual(abs(FrameStall.missedSeconds(gap: 0.05, frame: f60) - (0.05 - f60)) < 1e-12, true,
                    "卡顿: 60Hz 屏上卡三帧(50ms)就算 —— 起步那一顿常常就这么长")
        expectEqual(abs(FrameStall.missedSeconds(gap: 0.04, frame: f120) - (0.04 - f120)) < 1e-12, true,
                    "卡顿: 120Hz 屏上 40ms 的空档算")
        expectEqual(FrameStall.missedSeconds(gap: 0.3, frame: f60), 0,
                    "卡顿: 长过 0.25 秒的空档不扣(窗口被盖住、系统睡眠),过渡照真实时间走")
        expectEqual(FrameStall.missedSeconds(gap: 0.072, frame: 0), 0, "卡顿: 帧长读不到时不扣")
    }

    // MARK: - 过渡走过渡时刻、逐字填色走墙钟(源码契约,07 章决策 108)
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let window = (try? String(contentsOf: root.appendingPathComponent("lyrimuse/UI/LyricsWindowView.swift"),
                                  encoding: .utf8)) ?? ""
        let frame = (try? String(contentsOf: root.appendingPathComponent("lyrimuse/UI/FrameTimeline.swift"),
                                 encoding: .utf8)) ?? ""
        expectEqual(window.isEmpty || frame.isEmpty, false, "过渡时刻(契约): 读到源码")
        expectEqual(sourceBytes(frame, contain: "stalledSeconds += FrameStall.missedSeconds(gap: target - last, frame: target - link.timestamp)"), true,
                    "过渡时刻(契约): 每帧把漏掉的那段记进累计卡顿")
        expectEqual(sourceBytes(frame, contain: "if idle { lastFrame = nil } else if lastFrame == nil { lastFrame = CACurrentMediaTime() }"), true,
                    "过渡时刻(契约): 停着的时钟恢复时从恢复那一刻算 —— 恢复它的那次更新卡住了也要算")
        expectEqual(sourceBytes(frame, contain: "content(timebase == .transition ? clock.transitionDate(ticket.date) : ticket.date)"), true,
                    "过渡时刻(契约): 过渡拿到的是扣掉卡顿的时刻")
        expectEqual(sourceBytes(window, contain: "lineStagger.begin(clock: frameClock,"), true,
                    "过渡时刻(契约): 换句错开的起点跟各行逐帧取值同一个时钟")
        expectEqual(sourceBytes(window, contain: ".onChange(of: inputs) { old, new in\n            let now = clock.transitionNow()"), true,
                    "过渡时刻(契约): 景深的起点按过渡时刻记")
        expectEqual(sourceBytes(window, contain: ".onChange(of: f) { old, new in\n                        let now = clock.transitionNow()"), true,
                    "过渡时刻(契约): 指示条的起点按过渡时刻记")
        expectEqual(sourceBytes(window, contain: "FrameTimeline(minimumInterval: WordKaraokeGradient.windowRefreshInterval,\n                      paused: !isPlaying || !isLive)"), true,
                    "过渡时刻(契约): 逐字填色细时钟照旧走墙钟 —— 扣掉卡顿就跟演唱错开")
        expectEqual(sourceBytes(window, contain: "FrameTimeline(minimumInterval: Self.coarseInterval,\n                      paused: !isActive || !isPlaying || fillSettled)"), true,
                    "过渡时刻(契约): 逐字填色粗时钟照旧走墙钟")
    }

    // MARK: - 换句错开只带视口附近的行(LyricsLineStagger.reachRows,07 章决策 109)
    do {
        expectEqual(LyricsLineStagger.reachRows(viewportHeight: 800, fontSize: 48), 12,
                    "错开范围: 800pt 高、48pt 字 → 视口放得下 8 行,再加 4 行")
        expectEqual(LyricsLineStagger.reachRows(viewportHeight: 0, fontSize: 48), Int.max, "错开范围: 还没量出尺寸时全都带上")
        expectEqual(LyricsLineStagger.reachRows(viewportHeight: 800, fontSize: 0), Int.max, "错开范围: 字号读不到时全都带上")
        // 跳 3 行、用户滚开四分之一视口的最坏情况下,原来看着的行(锚点上面约 37%、下面约 63%)都还在范围里
        for (h, f) in [(800.0, 48.0), (1200.0, 30.0), (500.0, 60.0), (900.0, 16.0)] {
            let v = h / (LyricsLineStagger.minimumRowPitchEm * f)
            let worst = Double(LyricsLineStagger.maxStaggerJumpRows) + v * (0.63 + LyricsLineStagger.maxStaggerDriftFraction)
            expectEqual(worst <= Double(LyricsLineStagger.reachRows(viewportHeight: h, fontSize: f)), true,
                        "错开范围: \(Int(h))pt 高、\(Int(f))pt 字时原来看着的行都还在范围里")
        }
    }

    // MARK: - 换句错开只带视口附近的行(源码契约,07 章决策 109)
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let window = (try? String(contentsOf: root.appendingPathComponent("lyrimuse/UI/LyricsWindowView.swift"),
                                  encoding: .utf8)) ?? ""
        expectEqual(window.isEmpty, false, "错开范围(契约): 读到源码")
        expectEqual(sourceBytes(window, contain: ".modifier(LineStagger(model: staggers ? stagger : .inert, fontSize: fontSize))"), true,
                    "错开范围(契约): 离得远的行挂从不开始的那一份")
        expectEqual(sourceBytes(window, contain: "&& a.staggers == b.staggers"), true,
                    "错开范围(契约): 参不参与进行的 ==,换句时只有跨过边界的行重算")
        expectEqual(sourceBytes(window, contain: "staggers: staggerAnchor.map { abs(index - $0) <= staggerReach } ?? true"), true,
                    "错开范围(契约): 按离滚动锚几行算")
        expectEqual(sourceBytes(window, contain: "jumpRows <= LyricsLineStagger.maxStaggerJumpRows,"), true,
                    "错开范围(契约): 一次跳得远时整页带动画滚 —— 离得远的行不会被垫回原处")
        expectEqual(sourceBytes(window, contain: "if let landed = landedScroll, abs(before - landed) > maxDrift {"), true,
                    "错开范围(契约): 用户自己滚开了整页带动画滚回来")
        expectEqual(sourceBytes(window, contain: "if left > 0.001 { self.clearWhenSettled(after: left) } else { self.clear() }"), true,
                    "错开范围(契约): 走完收掉时不清落定的滚动量 —— 清了的话下一次换句永远没有参照")
    }

    // MARK: - 歌词窗口间奏三点按时间点亮(源码契约)
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let dots = (try? String(contentsOf: root.appendingPathComponent("lyrimuse/UI/LyricsGapDots.swift"),
                                encoding: .utf8)) ?? ""
        expectEqual(dots.isEmpty, false, "窗口三点(契约): 读到源码")
        expectEqual(sourceBytes(dots, contain: "case .window:\n            return GapDotsCurve.windowOpacity(dot: dot,"), true,
                    "窗口三点(契约): 定格时按此刻的进度画亮度,不是恒满 —— 一开始就三颗实心看不出间奏走到哪")
        expectEqual(sourceBytes(dots, contain: "installFade(on: dot, frames: GapDotsCurve.windowOpacityKeyframes(dot: i,"), true,
                    "窗口三点(契约): 装动画时把点亮交给 Core Animation")
        expectEqual(sourceBytes(dots, contain: "let scales: [Double] = c.reduceMotion ? [] :"), true,
                    "窗口三点(契约): 减弱动态效果只停大小,点亮照走")
    }

    // MARK: - 歌词窗口看不见时不做隐式动画(源码契约)
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let window = (try? String(contentsOf: root.appendingPathComponent("lyrimuse/UI/LyricsWindowView.swift"),
                                  encoding: .utf8)) ?? ""
        expectEqual(window.isEmpty, false, "看不见停动画(契约): 读到源码")
        expectEqual(sourceBytes(window, contain: "        }\n        // 窗口看不见时整窗不做隐式动画"), true,
                    "看不见停动画(契约): 闸挂在根部那个 Group 上,迷你 / 完整两套布局和各处浮层胶囊都在它下面")
        expectEqual(sourceBytes(window, contain: ".transaction { transaction in\n            guard !windowController.isSurfaceVisible else { return }\n            transaction.disablesAnimations = true\n            transaction.animation = nil\n        }"),
                    true, "看不见停动画(契约): 看不见时关掉隐式动画 —— SwiftUI 不替被盖住的窗口停动画,换句的景深每帧照跑")
    }

    // MARK: - 系统判为看不见时算盖住(源码契约)
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let monitor = (try? String(contentsOf: root.appendingPathComponent("lyrimuse/UI/WindowCoverageMonitor.swift"),
                                   encoding: .utf8)) ?? ""
        expectEqual(monitor.isEmpty, false, "覆盖(契约): 读到源码")
        expectEqual(sourceBytes(monitor, contain: "guard window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible) else { return true }"), true,
                    "覆盖(契约): 没上屏 / 最小化 / 被遮住直接算盖住 —— 窗口一上屏就被整扇盖住时系统不发遮挡通知,宿主的初值停在「可见」")
    }

    // MARK: - 左栏跑马灯走图层、看不见时不滚(源码契约)
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let window = (try? String(contentsOf: root.appendingPathComponent("lyrimuse/UI/LyricsWindowView.swift"),
                                  encoding: .utf8)) ?? ""
        let marquee = (try? String(contentsOf: root.appendingPathComponent("lyrimuse/UI/LayerMarquee.swift"),
                                   encoding: .utf8)) ?? ""
        expectEqual(window.isEmpty || marquee.isEmpty, false, "图层跑马灯(契约): 读到源码")
        expectEqual(sourceBytes(window, contain: "LayerMarquee(id: displayTitle,\n                         edgeFadeWidth: Self.trackInfoTrailingFade,\n                         leadingFadeWidth: Self.trackInfoLeadingFade,\n                         isActive: windowController.isSurfaceVisible) {"),
                    true, "图层跑马灯(契约): 歌名走图层、按窗口可见性停 —— SwiftUI 跑马灯在这扇窗里每帧要完整渲染两次")
        expectEqual(sourceBytes(window, contain: "LayerMarquee(id: displayArtistAlbum,\n                         edgeFadeWidth: Self.trackInfoTrailingFade,\n                         leadingFadeWidth: Self.trackInfoLeadingFade,\n                         isActive: windowController.isSurfaceVisible,\n                         pausesOnHover: true) {"),
                    true, "图层跑马灯(契约): 副标题走图层、悬停时停住 —— 里面的歌手 / 专辑链接要落在看到的位置上")
        expectEqual(sourceBytes(marquee, contain: "animation.repeatCount = .infinity"), true,
                    "图层跑马灯(契约): 关键帧重复播放,装好之后主线程不再参与")
        expectEqual(sourceBytes(marquee, contain: "MenuBarAnimation.capped(animation, fps: MenuBarAnimation.scrollFPS)"), true,
                    "图层跑马灯(契约): 文字横移声明 60Hz,不交给系统降档")
        expectEqual(sourceBytes(marquee, contain: "animating: isActive && !reduceMotion"), true,
                    "图层跑马灯(契约): 看不见或减弱动态效果时不滚")
    }

    // MARK: - 迷你两行选取
    do {
        typealias M = MiniLyricsSelection
        expectEqual(M.currentIndex(currentLineIndex: 3, lineCount: 10), 3, "迷你两行: 当前行")
        expectEqual(M.nextIndex(currentLineIndex: 3, lineCount: 10), 4, "迷你两行: 下一行")
        expectEqual(M.currentIndex(currentLineIndex: nil, lineCount: 10), nil, "迷你两行: 还没唱到第一句没有当前行")
        expectEqual(M.nextIndex(currentLineIndex: nil, lineCount: 10), 0, "迷你两行: 还没唱到第一句时把第一句当预告")
        expectEqual(M.nextIndex(currentLineIndex: 9, lineCount: 10), nil, "迷你两行: 最后一句没有下一行")
        expectEqual(M.currentIndex(currentLineIndex: 12, lineCount: 10), nil, "迷你两行: 越界下标(换歌瞬间)不取")
        expectEqual(M.nextIndex(currentLineIndex: nil, lineCount: 0), nil, "迷你两行: 没有歌词时两行都空")
        // 罗马音 / 译文:当前句挂;前奏 / 间奏里只剩下一句时它也挂,有当前句时下一句不挂。
        expectEqual(M.showsSubLines(isCurrentRow: true, hasCurrentLine: true), true, "迷你副行: 当前句挂译文")
        expectEqual(M.showsSubLines(isCurrentRow: false, hasCurrentLine: true), false, "迷你副行: 有当前句时下一句只是预告")
        expectEqual(M.showsSubLines(isCurrentRow: false, hasCurrentLine: false), true,
                    "迷你副行: 前奏 / 间奏里下一句是唯一的一句,同悬浮歌词带上译文")
        let reelRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let reelSource = (try? String(contentsOf: reelRoot.appendingPathComponent("lyrimuse/UI/LyricsWindowView.swift"),
                                      encoding: .utf8)) ?? ""
        expectEqual(reelSource.contains("MiniLyricsSelection.showsSubLines(isCurrentRow: row.role == .current,"), true,
                    "迷你副行契约: reel 走 Core 的 showsSubLines")
        expectEqual(reelSource.contains("if row.role == .current, showTranslation,"), false,
                    "迷你副行契约: 不再只认当前句")
    }

    // MARK: - 迷你歌词布局:单行 / 双行 / 多行
    do {
        typealias L = LyricsWindowMiniLyricsLayout
        typealias M = MiniLyricsSelection
        expectEqual(L.allCases, [.oneLine, .twoLines, .list], "迷你布局: 分段顺序 单行 → 双行 → 多行")
        expectEqual(L.twoLines.rawValue, "compact", "迷你布局: 双行的存盘值固定是 compact")
        expectEqual(L(rawValue: "compact"), .twoLines, "迷你布局: 已存的 compact 读出来是双行")
        expectEqual(L(rawValue: "list"), .list, "迷你布局: 已存的 list 读出来还是多行")
        expectEqual(M.showsNextLine(layout: .oneLine, hasCurrentLine: true, inGap: false), false,
                    "迷你单行: 有当前句就只画当前句")
        expectEqual(M.showsNextLine(layout: .oneLine, hasCurrentLine: false, inGap: true), false,
                    "迷你单行: 前奏 / 间奏那一格是三颗点,不补下一句")
        expectEqual(M.showsNextLine(layout: .oneLine, hasCurrentLine: true, inGap: true), false,
                    "迷你单行: 句间间奏也不补")
        expectEqual(M.showsNextLine(layout: .oneLine, hasCurrentLine: false, inGap: false), true,
                    "迷你单行: 还没唱到第一句、又没有前奏三点时用下一句顶上,不留空白")
        for current in [true, false] {
            for gap in [true, false] {
                expectEqual(M.showsNextLine(layout: .twoLines, hasCurrentLine: current, inGap: gap), true,
                            "迷你双行: 下一句恒画(current=\(current) gap=\(gap))")
                expectEqual(M.showsNextLine(layout: .list, hasCurrentLine: current, inGap: gap), true,
                            "迷你多行退回两行那套时照两行画(current=\(current) gap=\(gap))")
            }
        }
    }

    // MARK: - 窗口位置恢复
    do {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        expectEqual(WindowFrameFit.clamp(CGRect(x: 100, y: 100, width: 800, height: 600), into: visible),
                    CGRect(x: 100, y: 100, width: 800, height: 600), "窗口位置: 放得下就原样")
        expectEqual(WindowFrameFit.clamp(CGRect(x: 1200, y: 100, width: 800, height: 600), into: visible),
                    CGRect(x: 640, y: 100, width: 800, height: 600), "窗口位置: 右边挂出去 → 推回来贴右缘")
        expectEqual(WindowFrameFit.clamp(CGRect(x: -300, y: -50, width: 800, height: 600), into: visible),
                    CGRect(x: 0, y: 25, width: 800, height: 600), "窗口位置: 左下挂出去 → 贴左缘和可见区底")
        expectEqual(WindowFrameFit.clamp(CGRect(x: 0, y: 0, width: 3000, height: 2000), into: visible),
                    visible, "窗口位置: 比屏幕大(换了小屏)→ 先缩到放得下")
        let size = CGSize(width: 420, height: 250), minimum = CGSize(width: 300, height: 110)
        expectEqual(WindowFrameFit.miniSize(saved: nil, defaultSize: size, minimum: minimum, visible: nil), size,
                    "迷你尺寸: 没拖过用默认")
        expectEqual(WindowFrameFit.miniSize(saved: CGSize(width: 387, height: 359), defaultSize: size,
                                            minimum: minimum, visible: nil),
                    CGSize(width: 387, height: 359), "迷你尺寸: 拖过的尺寸优先")
        expectEqual(WindowFrameFit.miniSize(saved: CGSize(width: 0, height: 359), defaultSize: size,
                                            minimum: minimum, visible: nil), size,
                    "迷你尺寸: 存坏的尺寸(宽或高为 0)不认")
        expectEqual(WindowFrameFit.miniSize(saved: CGSize(width: 200, height: 80), defaultSize: size,
                                            minimum: minimum, visible: nil), minimum,
                    "迷你尺寸: 不小于下限")
        expectEqual(WindowFrameFit.miniSize(saved: CGSize(width: 900, height: 700), defaultSize: size,
                                            minimum: minimum, visible: CGSize(width: 800, height: 600)),
                    CGSize(width: 800, height: 600), "迷你尺寸: 不大于屏幕可见区")
        let retired = [CGSize(width: 420, height: 180)]
        expectEqual(WindowFrameFit.miniSize(saved: CGSize(width: 420, height: 180), defaultSize: size,
                                            minimum: minimum, visible: nil, retiredDefaults: retired), size,
                    "迷你尺寸: 存的是旧默认(只挪过窗、没拖过大小)→ 换成现在的默认")
        expectEqual(WindowFrameFit.miniSize(saved: CGSize(width: 420, height: 181), defaultSize: size,
                                            minimum: minimum, visible: nil, retiredDefaults: retired),
                    CGSize(width: 420, height: 181), "迷你尺寸: 跟旧默认差一点的是用户拖出来的,照用")
    }

    // MARK: - 文字色调
    do {
        typealias C = LyricsWindowTextColorMode
        expectEqual(C.auto.tone(hasArtworkBackground: true), .white, "文字色: 自动档 + 封面背景 → 白(老行为)")
        expectEqual(C.auto.tone(hasArtworkBackground: false), .systemPrimary, "文字色: 自动档 + 纯色背景 → 跟随系统(老行为)")
        expectEqual(C.light.tone(hasArtworkBackground: false), .white, "文字色: 浅色档钉死白,不看背景")
        expectEqual(C.dark.tone(hasArtworkBackground: true), .dark, "文字色: 深色档钉死深色,不看背景")
        expectEqual(C.custom.tone(hasArtworkBackground: true), .custom, "文字色: 自定义档用用户的颜色")
    }

    // MARK: - AM vibrancy 亮度档
    do {
        typealias V = AMVibrancy
        expectEqual(V.brightness(base: 0.85, backgroundBrightness: 0.3, backgroundSaturation: 0.6, minContrast: 0.25), 0.85,
                    "vibrancy: 暗背景对比度够,用基础档")
        expectEqual(r3(V.brightness(base: 0.85, backgroundBrightness: 0.7, backgroundSaturation: 0.6, minContrast: 0.25)), 0.95,
                    "vibrancy: 背景亮起来 → 提亮到背景 +0.25")
        expectEqual(r3(V.brightness(base: 0.85, backgroundBrightness: 0.75, backgroundSaturation: 0.9, minContrast: 0.25)), 0.97,
                    "vibrancy: 提亮封顶 0.97")
        expectEqual(r3(V.brightness(base: 0.85, backgroundBrightness: 0.9, backgroundSaturation: 0.2, minContrast: 0.25)), 0.58,
                    "vibrancy: 近白封面(又亮又淡)→ 唯一压暗分支,背景 −0.32")
        expectEqual(V.brightness(base: 0.85, backgroundBrightness: 0.9, backgroundSaturation: 0.2, minContrast: nil), 0.85,
                    "vibrancy: 不传最小对比度(控件类)→ 不调")
        expectEqual(V.brightness(base: 0.85, backgroundBrightness: 0, backgroundSaturation: 0.2, minContrast: 0.25), 0.85,
                    "vibrancy: 背景亮度未知(0)→ 不调")
    }

    // MARK: - Last.fm 喜欢:打在哪个写法上 / 编解码
    do {
        typealias L = LastfmLove
        let np = L.Target(artist: "寶石Gem", title: "执子之手")
        expectEqual(L.resolveTarget(localArtist: "宝石Gem", localTitle: "执子之手", nowPlaying: np, nowPlayingFresh: true),
                    np, "Last.fm 喜欢: nowplaying 新鲜且歌名对得上 → 用上送的写法")
        expectEqual(L.resolveTarget(localArtist: "宝石Gem", localTitle: " 执子之手 ", nowPlaying: L.Target(artist: "寶石Gem", title: "執子之手"),
                                    nowPlayingFresh: true),
                    L.Target(artist: "宝石Gem", title: "执子之手"),
                    "Last.fm 喜欢: 歌名对不上(繁简不同)→ 退回本机写法(已知边界)")
        expectEqual(L.resolveTarget(localArtist: "A", localTitle: "Song", nowPlaying: L.Target(artist: "B", title: "song"),
                                    nowPlayingFresh: false),
                    L.Target(artist: "A", title: "Song"), "Last.fm 喜欢: nowplaying 不新鲜(停播残影)→ 不用")
        expectEqual(L.resolveTarget(localArtist: "A", localTitle: "Song", nowPlaying: L.Target(artist: "", title: "Song"),
                                    nowPlayingFresh: true),
                    L.Target(artist: "A", title: "Song"), "Last.fm 喜欢: nowplaying 歌手为空 → 不用")
        expectEqual(L.resolveTarget(localArtist: "A", localTitle: "SONG ", nowPlaying: L.Target(artist: "A & B", title: "song"),
                                    nowPlayingFresh: true),
                    L.Target(artist: "A & B", title: "song"), "Last.fm 喜欢: 大小写 / 首尾空白不算差异")
        expectEqual(L.resolveTarget(localArtist: "", localTitle: "Song", nowPlaying: nil, nowPlayingFresh: false), nil,
                    "Last.fm 喜欢: 本机歌手为空 → 没有目标")
        expectEqual(L.formBody(["track": "夜曲+窃爱 (Live)", "artist": "A B", "method": "track.love"]),
                    "artist=A%20B&method=track.love&track=%E5%A4%9C%E6%9B%B2%2B%E7%AA%83%E7%88%B1%20%28Live%29",
                    "Last.fm 喜欢: 表单体键按字母序、+ 编成 %2B(不是空格)、不做读接口那种双重转义")
        expectEqual(L.parseUserLoved(["track": ["userloved": "1"]]), true, "Last.fm 喜欢: userloved \"1\"")
        expectEqual(L.parseUserLoved(["track": ["userloved": "0"]]), false, "Last.fm 喜欢: userloved \"0\"")
        expectEqual(L.parseUserLoved(["track": ["userloved": 1]]), true, "Last.fm 喜欢: 数字形态也认")
        expectEqual(L.parseUserLoved(["error": 6, "message": "Track not found"]), false,
                    "Last.fm 喜欢: error 6(没收录)算没喜欢")
        expectEqual(L.parseUserLoved(["error": 29]), nil, "Last.fm 喜欢: 其它错误 → 没读到")
        expectEqual(L.parseUserLoved(["track": ["name": "x"]]), nil, "Last.fm 喜欢: 缺字段 → 没读到")
        expectEqual(L.writeSucceeded([:]), true, "Last.fm 喜欢: 写成功是空对象")
        expectEqual(L.writeSucceeded(["error": 9, "message": "Invalid session key"]), false,
                    "Last.fm 喜欢: HTTP 200 带 error 也是失败")

        // 喜欢列表(最近记录每行的心)。
        expectEqual(L.lovedKey(artist: " Taylor Swift ", title: "Love Story"),
                    L.lovedKey(artist: "taylor swift", title: "LOVE STORY"), "喜欢列表: 大小写 / 首尾空白不算差异")
        expectEqual(L.lovedKey(artist: "A", title: "Song") != L.lovedKey(artist: "A", title: "Song (Live)"), true,
                    "喜欢列表: 版本后缀不同就是另一首")
        expectEqual(L.lovedKey(artist: "", title: "Song"), nil, "喜欢列表: 空歌手没有键")
        let page = L.parseLovedTracksPage(["lovedtracks": [
            "track": [["name": "Love Story", "artist": ["name": "Taylor Swift"]],
                      ["name": "", "artist": ["name": "X"]]],
            "@attr": ["totalPages": "3", "total": "2001"]]])
        expectEqual(page?.targets, [L.Target(artist: "Taylor Swift", title: "Love Story")],
                    "喜欢列表: 歌手读 artist.name,空歌名丢掉")
        expectEqual(page?.totalPages, 3, "喜欢列表: 总页数读 @attr.totalPages 字符串")
        expectEqual(L.parseLovedTracksPage(["lovedtracks": [
            "track": ["name": "Only", "artist": ["name": "One"]], "@attr": ["totalPages": "1"]]])?.targets,
                    [L.Target(artist: "One", title: "Only")], "喜欢列表: 只有一首时 track 是对象也认")
        expectEqual(L.parseLovedTracksPage(["lovedtracks": ["track": [], "@attr": ["totalPages": "0", "total": "0"]]])?.targets.isEmpty,
                    true, "喜欢列表: 一首都没有 → 空列表(不是没读到)")
        expectEqual(L.parseLovedTracksPage(["lovedtracks": ["track": [], "@attr": ["totalPages": "0"]]])?.totalPages, 1,
                    "喜欢列表: 总页数至少 1")
        expectEqual(L.parseLovedTracksPage(["error": 6, "message": "User not found"]) == nil, true,
                    "喜欢列表: API 错误 → 没读到")
        // 合并:拉取先于写落地发出 / 读接口还没跟上时,窗口内以本机为准。
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let m1 = L.mergeLoved(fetched: ["a\nx"], overrides: ["b\ny": .init(loved: true, at: t0)],
                              now: t0.addingTimeInterval(5), window: 600)
        expectEqual(m1.keys, ["a\nx", "b\ny"], "喜欢列表合并: 刚点的喜欢不被旧列表盖掉")
        let m2 = L.mergeLoved(fetched: ["a\nx"], overrides: ["a\nx": .init(loved: false, at: t0)],
                              now: t0.addingTimeInterval(5), window: 600)
        expectEqual(m2.keys.isEmpty, true, "喜欢列表合并: 刚取消的不被旧列表加回来")
        let m3 = L.mergeLoved(fetched: [], overrides: ["b\ny": .init(loved: true, at: t0)],
                              now: t0.addingTimeInterval(601), window: 600)
        expectEqual(m3.keys.isEmpty && m3.overrides.isEmpty, true, "喜欢列表合并: 过了窗口以服务端为准、本机记录丢掉")
        expectEqual(m1.overrides.count, 1, "喜欢列表合并: 窗口内的本机记录留着")
    }

    // MARK: - 迷你顶部信息宽度(窗口宽度的百分比)
    do {
        typealias W = LyricsWindowMiniHeaderWidth
        expectEqual(W.percentRange, 40...100, "迷你顶部宽度: 范围 40%…100%")
        expectEqual(W.percentStep, 5, "迷你顶部宽度: 步长 5%")
        expectEqual(W.percentRange.contains(W.defaultPercent), true, "迷你顶部宽度: 默认值在范围里")
        expectEqual(W.width(windowWidth: 420, percent: W.defaultPercent), 273, "迷你顶部宽度: 默认 65% × 420 = 273pt")
        expectEqual(W.width(windowWidth: 420, percent: 100), 420, "迷你顶部宽度: 100% = 整窗宽")
        expectEqual(W.width(windowWidth: 600, percent: 50), 300, "迷你顶部宽度: 跟着窗口宽度走")
        expectEqual(W.width(windowWidth: 420, percent: 10), 168, "迷你顶部宽度: 存坏的过小值按 40% 算")
        expectEqual(W.width(windowWidth: 420, percent: 150), 420, "迷你顶部宽度: 越界的过大值按 100% 算")
        expectEqual(W.width(windowWidth: -5, percent: 65), 0, "迷你顶部宽度: 量到负宽时给 0,不给负数 frame")
    }

    // MARK: - 「设置 › 打开」按预览的形态开窗:请求只认刚发出的
    do {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let request = LyricsWindowFormRequest(mini: true, issuedAt: t0)
        expectEqual(LyricsWindowFormRequest.lifetime, 3, "开窗形态请求: 有效期 3 秒")
        expectEqual(request.isFresh(now: t0), true, "开窗形态请求: 刚发出的算数")
        expectEqual(request.isFresh(now: t0.addingTimeInterval(3)), true, "开窗形态请求: 3 秒整还算数")
        expectEqual(request.isFresh(now: t0.addingTimeInterval(3.1)), false,
                    "开窗形态请求: 过了 3 秒不算(那次没开成,之后别的入口打开不该被它带成迷你)")
        expectEqual(request.isFresh(now: t0.addingTimeInterval(-1)), false, "开窗形态请求: 时钟往回拨过也不算")
    }

    // MARK: - 迷你顶部信息高度(窗口高度的百分比,内容等比缩放)
    do {
        typealias S = LyricsWindowMiniHeaderSize
        func r3(_ v: CGFloat) -> Double { (Double(v) * 1000).rounded() / 1000 }
        expectEqual(S.percentRange, 8...25, "迷你顶部高度: 范围 8%…25%")
        expectEqual(S.percentStep, 1, "迷你顶部高度: 步长 1%")
        expectEqual(S.percentRange.contains(S.defaultPercent), true, "迷你顶部高度: 默认值在范围里")
        expectEqual(r3(S.referenceHeight), 44.9, "迷你顶部高度: 基准 = (12+11+10)×1.3 + 两道行距")
        expectEqual(abs(S.scale(windowHeight: 320, percent: S.defaultPercent) - 1) < 0.01, true,
                    "迷你顶部高度: 默认 14% 在默认 320 高的窗口里倍率约 1(跟没有这颗设置时一样大)")
        expectEqual(r3(S.scale(windowHeight: 320, percent: 25)), r3(320 * 0.25 / S.referenceHeight),
                    "迷你顶部高度: 倍率 = 窗口高度 × 百分比 ÷ 基准高度")
        expectEqual(S.scale(windowHeight: 640, percent: 14) > S.scale(windowHeight: 320, percent: 14), true,
                    "迷你顶部高度: 窗口拖高,顶部信息跟着变大")
        expectEqual(S.scale(windowHeight: 110, percent: 8), 0.8, "迷你顶部高度: 窗口再矮也不小于 0.8 倍")
        expectEqual(S.scale(windowHeight: 5000, percent: 25), 3, "迷你顶部高度: 窗口再高也不超过 3 倍")
        expectEqual(S.scale(windowHeight: 320, percent: 1), S.scale(windowHeight: 320, percent: 8),
                    "迷你顶部高度: 存坏的过小值按 8% 算")
        expectEqual(S.scale(windowHeight: 320, percent: 90), S.scale(windowHeight: 320, percent: 25),
                    "迷你顶部高度: 越界的过大值按 25% 算")
    }

    // MARK: - 迷你顶部显示项
    do {
        typealias H = LyricsWindowMiniHeaderFields
        expectEqual(H.default.visibleValues(title: "歌", artist: "人", album: "专辑"), ["歌", "人"],
                    "迷你顶部: 默认歌名 + 歌手")
        expectEqual(H([.album, .title]).visibleValues(title: "歌", artist: "人", album: "专辑"), ["歌", "专辑"],
                    "迷你顶部: 顺序固定 歌名 → 歌手 → 专辑,跟选择顺序无关")
        expectEqual(H([.title, .artist, .album]).visibleValues(title: "歌", artist: "人", album: "  "), ["歌", "人"],
                    "迷你顶部: 选了但值为空白的那项跳过(不画「歌 - 」尾巴)")
        expectEqual(H([]).visibleValues(title: "歌", artist: "人", album: "专辑"), [], "迷你顶部: 全关就是空")
        expectEqual(H([.title, .artist, .album]).visibleParts(title: "歌", artist: " 人 ", album: "专辑"),
                    [.init(field: .title, value: "歌"), .init(field: .artist, value: "人"), .init(field: .album, value: "专辑")],
                    "迷你顶部: 分段带上字段类型(歌手 / 专辑各自接看简介的点击),值同 visibleValues 一样收空白")
        expectEqual(H([.artist, .album]).visibleParts(title: "歌", artist: "人", album: "").map(\.field), [.artist],
                    "迷你顶部: 空的那项连段一起跳过")
        expectEqual(H.default.visibleValues(title: " 歌 ", artist: "人", album: ""), ["歌", "人"],
                    "迷你顶部: 首尾空白去掉")
    }

    // MARK: - 进度外推(逐字填色 / 进度条 / 间奏点共用的时间基准)
    do {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func anchor(progress: Int = 10_000, rate: Double = 1, ts: Int? = nil, age: Int? = nil,
                    duration: Int = 200_000) -> ProgressAnchor {
            ProgressAnchor(durationMs: duration, progressMs: progress, rate: rate, progressTs: ts,
                           baseAgeMs: age, fetchedAt: t0)
        }
        expectEqual(anchor(age: 0).extrapolatedPositionMs(now: t0.addingTimeInterval(2)), 12_000,
                    "进度外推: 锚点年龄 + 本机走过的时间 × 倍速")
        expectEqual(anchor(age: 500).extrapolatedPositionMs(now: t0.addingTimeInterval(1)), 11_500,
                    "进度外推: 服务器给的锚点年龄要加上")
        expectEqual(anchor(rate: 2, age: 0).extrapolatedPositionMs(now: t0.addingTimeInterval(1)), 12_000,
                    "进度外推: 倍速 2")
        expectEqual(anchor(rate: 0, age: 0).extrapolatedPositionMs(now: t0.addingTimeInterval(5)), 10_000,
                    "进度外推: 暂停(倍速 0)不动")
        let tsMs = Int(t0.timeIntervalSince1970 * 1000)
        expectEqual(anchor(ts: tsMs).extrapolatedPositionMs(now: t0.addingTimeInterval(3)), 13_000,
                    "进度外推: 没有锚点年龄时退回服务器时间戳")
        expectEqual(anchor().extrapolatedPositionMs(now: t0.addingTimeInterval(3)), 10_000,
                    "进度外推: 年龄和时间戳都没有 → 不外推")
        expectEqual(anchor(age: 0).extrapolatedPositionMs(now: t0.addingTimeInterval(91)), 101_000,
                    "进度外推: 不限龄(锚点放了 91s 照常外推,不回跳)")
        expectEqual(anchor(age: 0).extrapolatedPositionMs(now: t0.addingTimeInterval(-2)), 10_000,
                    "进度外推: 本机时钟倒退(年龄为负)不往回走")
        expectEqual(anchor(progress: 199_000, age: 0).extrapolatedPositionMs(now: t0.addingTimeInterval(5)), 200_000,
                    "进度外推: 不超过曲长")
    }

    // ---- 输出设备:跟着系统切换走、列表只由监听刷新(源码契约) ----
    do {
        let sourcesRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let audio = (try? String(contentsOf: sourcesRoot.appendingPathComponent("lyrimuse/AudioOutputDevices.swift"),
                                 encoding: .utf8)) ?? ""
        let view = (try? String(contentsOf: sourcesRoot.appendingPathComponent("lyrimuse/UI/LyricsWindowView.swift"),
                                encoding: .utf8)) ?? ""
        expectEqual(audio.isEmpty || view.isEmpty, false, "输出设备(契约): 读到两份源码")
        expectEqual(audio.contains("for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {")
                    && audio.contains("AudioObjectAddPropertyListenerBlock("), true,
                    "输出设备(契约): 监听默认输出与设备增减,控制中心 / AirPods 自动接管时输出键跟着变")
        expectEqual(audio.contains("guard hasOutputStreams(id), !isHidden(id), canBeDefaultOutput(id),"), true,
                    "输出设备(契约): 隐藏设备与不能当默认输出的设备不进列表")
        expectEqual(view.contains("AudioOutputDeviceManager.outputDevices()"), false,
                    "输出设备(契约): 歌词窗口不在渲染时现枚举设备,只读 AudioOutputMonitor")
        expectEqual(view.contains("output.isExternal\n                                    ? AnyShapeStyle(Color.red)"), true,
                    "输出设备(契约): 输出键染红读监听结果")
        expectEqual(view.contains("if output.select(device.id) { close() }"), true,
                    "输出设备(契约): 切换失败不关面板")
    }

    // ---- 窗口控制器的收尾与窗口不可见时停表(源码契约) ----
    do {
        let sourcesRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = (try? String(contentsOf: sourcesRoot.appendingPathComponent("lyrimuse/UI/LyricsWindowView.swift"),
                                encoding: .utf8)) ?? ""
        let monitor = (try? String(contentsOf: sourcesRoot.appendingPathComponent("lyrimuse/UI/WindowCoverageMonitor.swift"),
                                   encoding: .utf8)) ?? ""
        // LyricsWindowController 里每个 `private var xxxObserver: NSObjectProtocol?` 都要出现在 deinit 那张摘除表里。
        let controller = view.components(separatedBy: "private final class LyricsWindowController").dropFirst().first
            .flatMap { $0.components(separatedBy: "\nprivate struct LyricsWindowCapture").first } ?? ""
        let declared = controller.matches(of: #/private var (\w+Observer): NSObjectProtocol\?/#).map { String($0.1) }
        let deinitBody = controller.components(separatedBy: "deinit {").dropFirst().first ?? ""
        let removeList = deinitBody.components(separatedBy: "].compactMap").first ?? ""
        expectEqual(declared.count >= 10, true, "窗口收尾(契约): 扫到了控制器里的观察者声明(\(declared.count) 个)")
        expectEqual(declared.filter { !removeList.contains($0) }, [],
                    "窗口收尾(契约): attach 挂的观察者 deinit 都要摘掉")
        expectEqual(view.contains("if coverageMonitor == nil, window.isVisible { startCoverageMonitor(window) }"), true,
                    "窗口收尾(契约): 同一扇窗关了再开,遮挡检测要重新挂上")
        expectEqual(monitor.contains("deinit {") && monitor.contains("timer?.invalidate()"), true,
                    "窗口收尾(契约): 遮挡检测被放手时自己停表")
        expectEqual(view.contains("if let anchor, isVisible {")
                    && view.contains("isVisible: windowController.isSurfaceVisible,"), true,
                    "进度条(契约): 窗口面看不见时停掉每秒一次的推进")
        // 设置窗口(与「歌词管理」窗口)的可见性同样要过「几乎整扇被盖住」这一关,不能只看 occlusionState
        let surface = (try? String(contentsOf: sourcesRoot.appendingPathComponent("lyrimuse/UI/PreviewHostVisibility.swift"),
                                   encoding: .utf8)) ?? ""
        expectEqual(surface.contains("coverageMonitor = WindowCoverageMonitor(window: window)"), true,
                    "设置窗口可见性(契约): 接上窗口时挂遮挡检测")
        expectEqual(surface.contains("let visible = occlusionVisible && !coveredByOthers"), true,
                    "设置窗口可见性(契约): 系统报可见、且没被整扇盖住才算看得见")
    }
}
