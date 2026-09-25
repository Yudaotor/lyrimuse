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
    // MARK: - 空状态:顺序就是优先级
    do {
        typealias E = LyricsWindowEmptyState
        let everything = E.Inputs(hasTitle: true, isAdBreak: true, isRadioTalkBreak: true,
                                  isInstrumental: true, hasNoLyrics: true, collectorNetworkDown: true,
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
        i.collectorNetworkDown = false
        expectEqual(E.resolve(i), .searching, "空状态: 在放、没有内容、没有定论 → 搜索中")
        i.isPlaying = false
        expectEqual(E.resolve(i), .none, "空状态: 暂停且没有内容 → 兜底「无歌词」")
        expectEqual(E.resolve(E.Inputs(hasTitle: true, collectorNetworkDown: true, hasLyricsContent: true,
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
        expectEqual(D.distance(index: 3, anchorIndex: 5, inGap: false), 2, "景深: 上下对称按行数")
        expectEqual(D.distance(index: 5, anchorIndex: 5, inGap: true), 1, "景深: 间奏中当前行也退一档")
        expectEqual(D.distance(index: 0, anchorIndex: 40, inGap: false), D.maxDistance, "景深: 封顶 4")
        expectEqual(D.distance(index: 3, anchorIndex: nil, inGap: false), nil, "景深: 没有锚点 → nil")
        expectEqual(D.opacity(distance: 0), 1, "景深: 当前行不透明度 1")
        expectEqual(r3(D.opacity(distance: 1)), 0.42, "景深: d1 0.42")
        expectEqual(r3(D.opacity(distance: 2)), 0.42, "景深: d2 仍 0.42")
        expectEqual(r3(D.opacity(distance: 3)), 0.32, "景深: d3 每行再降 0.10")
        expectEqual(r3(D.opacity(distance: 4)), 0.22, "景深: d4 到底 0.22")
        expectEqual(D.opacity(distance: nil), 0.45, "景深: 没有锚点 0.45")
        expectEqual(D.blurRadius(distance: 0, fontSize: 50), 0, "景深: 当前行不糊")
        expectEqual(r3(D.blurRadius(distance: 1, fontSize: 100)), r3(100 * 0.0148 * 2), "景深: σ=0.0148×(d+1)×字号")
        expectEqual(r3(D.blurRadius(distance: nil, fontSize: 100)), 3, "景深: 没有锚点 0.03×字号")
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
                    fresh: Bool = true, duration: Int = 200_000) -> ProgressAnchor {
            ProgressAnchor(durationMs: duration, progressMs: progress, rate: rate, progressTs: ts,
                           baseAgeMs: age, fetchedAt: t0, fresh: fresh)
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
        expectEqual(anchor(age: 0, fresh: false).extrapolatedPositionMs(now: t0.addingTimeInterval(30)), 40_000,
                    "进度外推: 非直推锚点 90s 内照常外推")
        expectEqual(anchor(age: 0, fresh: false).extrapolatedPositionMs(now: t0.addingTimeInterval(91)), 10_000,
                    "进度外推: 非直推锚点超过 90s 视为陈旧,停在锚点位置不再外推")
        expectEqual(anchor(age: 0, fresh: true).extrapolatedPositionMs(now: t0.addingTimeInterval(91)), 101_000,
                    "进度外推: 直推锚点不限龄")
        expectEqual(anchor(age: 0).extrapolatedPositionMs(now: t0.addingTimeInterval(-2)), 10_000,
                    "进度外推: 本机时钟倒退(年龄为负)不往回走")
        expectEqual(anchor(progress: 199_000, age: 0).extrapolatedPositionMs(now: t0.addingTimeInterval(5)), 200_000,
                    "进度外推: 不超过曲长")
    }
}
