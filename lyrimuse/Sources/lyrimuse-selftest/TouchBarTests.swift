import AppKit
import Foundation
import LyrimuseCore

// 触控栏歌词:那一格显示哪一档(Core `TouchBarLyricsContent`)、字号区间(`TouchBarLyricsStyle`)、图层行的
// 时间基准指纹(`LyricsTimingEpoch`)、副行开着时两行显示什么和怎么摆(两行的墨迹照图层行的画法量),加几条接线契约 ——
// 展开态从左到右排哪几项(`TouchBarSlot.order`)、隐藏功能栏时的宽度、广告期间封面那一格贴喇叭、按触控栏这一格的宽度断句;
// 私有入口只在 `TouchBar/TouchBarPrivateAPI.swift` 一个文件里、App 启动时起控制器、开关和十项设置在「歌词显示」页
// 自己那一段(「触控栏」)里、控制器都接上了;这台 Mac 有没有触控栏的判据(`TouchBarPresence`)和它在设置页 / 搜索 /
// 控制器三处的接线;菜单栏左键面板第二排那一格「触控栏歌词」;全局快捷键「展开/收起触控栏歌词」;占满整条的展开收起后功能栏图标重新露面。
// 由 main.swift 的注册表按组调用。

func runTouchBarTests() {
    func line(_ text: String) -> SyncedLyricLine {
        SyncedLyricLine(romanization: nil, translation: nil, mainText: text, words: nil, wordGroups: nil, side: nil)
    }
    func resolve(_ compactLine: SyncedLyricLine?, placeholder: Bool = false,
                 title: String = "", artist: String = "", ad: Bool = false) -> TouchBarLyricsContent {
        TouchBarLyricsContent.resolve(compactLine: compactLine, showsPlaceholder: placeholder,
                                      title: title, artist: artist, isAdBreak: ad)
    }

    // ---- 显示哪一档:广告 > 歌词句 > 间奏 > 歌名 > 空 ----
    do {
        let sung = line("故事的小黄花")
        let words = [SyncedLyricWord(text: "故事", startMs: 1000, durationMs: 400),
                     SyncedLyricWord(text: "的", startMs: 1400, durationMs: 200)]
        let wordLine = SyncedLyricLine(romanization: nil, translation: nil, mainText: nil, words: words,
                                       wordGroups: nil, side: nil)
        expectEqual(resolve(sung, title: "晴天", artist: "周杰伦"), .lyric(sung), "触控栏: 有歌词句就显示歌词句")
        expectEqual(resolve(wordLine), .lyric(wordLine), "触控栏: 逐字行原样交出去(填色要用它的词)")
        expectEqual(resolve(sung, placeholder: true, title: "晴天"), .lyric(sung),
                    "触控栏: 歌词句压过间奏占位")
        expectEqual(resolve(sung, title: "晴天", ad: true), .adBreak, "触控栏: 广告压过一切")
        expectEqual(resolve(nil, placeholder: true, title: "晴天", artist: "周杰伦"), .interlude,
                    "触控栏: 间奏时显示占位,不显示歌名")
        expectEqual(resolve(nil, title: "晴天", artist: "周杰伦"), .track("晴天 — 周杰伦"),
                    "触控栏: 没歌词显示「歌名 — 歌手」")
        expectEqual(resolve(nil, title: "晴天"), .track("晴天"), "触控栏: 只有歌名")
        expectEqual(resolve(nil, artist: "周杰伦"), .track("周杰伦"), "触控栏: 只有歌手")
        expectEqual(resolve(nil, title: "  晴天\n", artist: " "), .track("晴天"), "触控栏: 歌名歌手去掉首尾空白")
        expectEqual(resolve(nil), .idle, "触控栏: 没曲目")
        expectEqual(resolve(line("   "), title: "晴天"), .track("晴天"), "触控栏: 只有空白的行不算歌词句")
        expectEqual(resolve(nil, ad: true), .adBreak, "触控栏: 广告时没有标题也显示广告")

        // 只有歌词句的滚动跟着歌词时间轴走,别的几档由触控栏自己定起点。
        expectEqual(TouchBarLyricsContent.lyric(sung).isLyric, true, "触控栏: 歌词句跟着时间轴")
        expectEqual([TouchBarLyricsContent.interlude, .track("晴天"), .adBreak, .idle].map(\.isLyric),
                    [false, false, false, false], "触控栏: 间奏 / 歌名 / 广告 / 空都不跟时间轴")
    }

    // ---- 副行开着时:主行认正在唱的那一句,够格的间奏显示占位、前奏照旧显示歌名;副行的字同灵动岛 / 菜单栏那条规则 ----
    do {
        let current = SyncedLyricLine(romanization: "gu shi de xiao huang hua", translation: "The little yellow flower",
                                      mainText: "故事的小黄花", words: nil, wordGroups: nil, side: nil)
        let upcoming = line("从出生那年就飘着")
        func resolve(_ kind: LyricSecondaryLine, compact: SyncedLyricLine?, placeholder: Bool = false,
                     current: SyncedLyricLine?, marked: Bool = false, ad: Bool = false) -> TouchBarLyricsContent {
            TouchBarLyricsContent.resolve(secondary: kind, compactLine: compact, showsPlaceholder: placeholder,
                                          currentLine: current, inMarkedInterlude: marked,
                                          title: "晴天", artist: "周杰伦", isAdBreak: ad)
        }
        expectEqual(resolve(.off, compact: upcoming, current: current), .lyric(upcoming),
                    "触控栏副行: 关着时照旧取提前亮出的那一句")
        expectEqual(resolve(.nextLine, compact: upcoming, current: current), .lyric(current),
                    "触控栏副行: 开着时主行取正在唱的那一句,不抢跑")
        expectEqual(resolve(.translation, compact: nil, placeholder: true, current: current, marked: true), .interlude,
                    "触控栏副行: 够格的间奏里显示占位")
        expectEqual(resolve(.translation, compact: nil, placeholder: true, current: current), .lyric(current),
                    "触控栏副行: 不够格的句间空档留着上一句")
        expectEqual(resolve(.nextLine, compact: nil, current: nil, marked: true), .track("晴天 — 周杰伦"),
                    "触控栏副行: 前奏里还没有当前句,同单行时显示歌名")
        expectEqual(resolve(.romanization, compact: upcoming, current: current, ad: true), .adBreak,
                    "触控栏副行: 广告照样压过一切")

        let next = "从出生那年就飘着"
        let lyric = TouchBarLyricsContent.lyric(current)
        expectEqual(lyric.secondaryText(.translation, nextLineText: next), "The little yellow flower",
                    "触控栏副行的字: 译文是这一句的")
        expectEqual(lyric.secondaryText(.romanization, nextLineText: next), "gu shi de xiao huang hua",
                    "触控栏副行的字: 读音是这一句的")
        expectEqual(lyric.secondaryText(.nextLine, nextLineText: next), next, "触控栏副行的字: 下一句")
        expectEqual(lyric.secondaryText(.off, nextLineText: next), nil, "触控栏副行的字: 关着时没有")
        expectEqual(lyric.secondaryText(.nextLine, nextLineText: "  \n"), nil, "触控栏副行的字: 只有空白算没有")
        expectEqual(TouchBarLyricsContent.interlude.secondaryText(.translation, nextLineText: next), nil,
                    "触控栏副行的字: 间奏里没有当前句,也就没有译文")
        expectEqual(TouchBarLyricsContent.interlude.secondaryText(.nextLine, nextLineText: next), next,
                    "触控栏副行的字: 间奏里照样预告下一句")
        expectEqual(TouchBarLyricsContent.track("晴天").secondaryText(.nextLine, nextLineText: "故事的小黄花"),
                    "故事的小黄花", "触控栏副行的字: 前奏里预告第一句")
        expectEqual([TouchBarLyricsContent.adBreak, .idle].map { $0.secondaryText(.nextLine, nextLineText: next) },
                    [nil, nil], "触控栏副行的字: 广告、没曲目时没有")
    }

    // ---- 这一档从哪一刻起显示(配速滚动的起点):换档 / 换行下标从此刻算,往回拖跟着挪,只有非歌词档重新起滚 ----
    do {
        let a = TouchBarLyricsContent.track("晴天")
        let b = TouchBarLyricsContent.lyric(line("故事的小黄花"))
        var start = TouchBarDisplayStart()
        start.update(content: a, lineIndex: nil, nowMs: 1_000)
        expectEqual(start.sinceMs, 1_000, "显示起点: 第一档从此刻算")
        start.update(content: a, lineIndex: nil, nowMs: 5_000)
        expectEqual(start.sinceMs, 1_000, "显示起点: 同一档、同一行下标不动")
        start.update(content: a, lineIndex: nil, nowMs: 500)
        expectEqual(start.sinceMs, 500, "显示起点: 往回拖到起点之前,起点跟着挪")
        start.restartIfNotLyric(nowMs: 8_000)
        expectEqual(start.sinceMs, 8_000, "显示起点: 歌名这类变成看得见时重新起滚")
        start.update(content: b, lineIndex: 3, nowMs: 9_000)
        expectEqual(start.sinceMs, 9_000, "显示起点: 换一档从此刻算")
        start.restartIfNotLyric(nowMs: 12_000)
        expectEqual(start.sinceMs, 9_000, "显示起点: 歌词句不重新起滚(按歌词时间轴算)")
        start.update(content: b, lineIndex: 4, nowMs: 13_000)
        expectEqual(start.sinceMs, 13_000, "显示起点: 同样的词换了行下标也从头算")
    }

    // ---- 显示起点认主行显示的那一句的下标:提前亮出的那一句开唱时,正在唱的下标往前走一格,显示的那一句的不动 ----
    do {
        // 第 1 句 12000 唱完、第 2 句 12100 开唱(进了提前量窗口就亮出第 2 句);第 2 句 14100 唱完、第 3 句 30000 才开唱
        // (中间先停 tailHoldMs、再换成占位、最后 5 秒亮出第 3 句)。
        let yrc = "[10000,2000](10000,2000,0)first line\n"
            + "[12100,2000](12100,2000,0)second line\n"
            + "[30000,2000](30000,2000,0)third line\n"
        let engine = LyricsSyncEngine()
        engine.load(lyrics: "", lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc, lineBreaks: .all)
        let revealed = engine.surfaceTick(.touchBar, atMs: 12_050)
        let singing = engine.surfaceTick(.touchBar, atMs: 12_500)
        expectEqual(revealed.compactLine?.plainText, "second line", "显示的那一句下标: 提前量窗口里亮出下一句")
        expectEqual([revealed.lineIndex, revealed.compactLineIndex], [0, 1],
                    "显示的那一句下标: 提前量窗口里正在唱的还是上一句,显示的是下一句")
        expectEqual([singing.lineIndex, singing.compactLineIndex], [1, 1], "显示的那一句下标: 开唱后两个下标对上")
        let intro = engine.surfaceTick(.touchBar, atMs: 5_000)
        expectEqual(intro.lineIndex == nil && intro.compactLineIndex == nil, true,
                    "显示的那一句下标: 还没到第一句时两个都没有")
        let gap = engine.surfaceTick(.touchBar, atMs: 20_000)
        expectEqual(gap.compactPlaceholder && gap.lineIndex == 1 && gap.compactLineIndex == nil, true,
                    "显示的那一句下标: 长间奏里显示占位时没有")
        func content(_ tick: LyricsSyncEngine.SurfaceLyrics) -> TouchBarLyricsContent {
            TouchBarLyricsContent.resolve(compactLine: tick.compactLine, showsPlaceholder: tick.compactPlaceholder,
                                          title: "", artist: "", isAdBreak: false)
        }
        var start = TouchBarDisplayStart()
        start.update(content: content(revealed), lineIndex: revealed.compactLineIndex, nowMs: 12_050)
        start.update(content: content(singing), lineIndex: singing.compactLineIndex, nowMs: 12_500)
        expectEqual(start.sinceMs, 12_050, "显示起点: 提前亮出的那一句开唱时不从头算(按显示时长配速的滚动不重来)")
    }

    // ---- 有没有触控栏:ControlStrip 没在跑就没有;在跑再看系统报告的主触控栏,查不了按有算 ----
    do {
        typealias P = TouchBarPresence
        expectEqual(P.isPresent(controlStripRunning: false, touchBarReported: true), false,
                    "触控栏判定: ControlStrip 没在跑就没有(不看下一层)")
        expectEqual(P.isPresent(controlStripRunning: false, touchBarReported: nil), false,
                    "触控栏判定: ControlStrip 没在跑、下一层也没查")
        expectEqual(P.isPresent(controlStripRunning: true, touchBarReported: true), true,
                    "触控栏判定: 在跑、系统报告有")
        expectEqual(P.isPresent(controlStripRunning: true, touchBarReported: false), false,
                    "触控栏判定: 在跑、系统报告没有(模拟器关着)")
        expectEqual(P.isPresent(controlStripRunning: true, touchBarReported: nil), true,
                    "触控栏判定: 在跑、接口缺了查不了,按有算")
    }

    // ---- 字号:夹进区间;区间里每一档在 30pt 高的触控栏里都放得下 ----
    do {
        typealias S = TouchBarLyricsStyle
        expectEqual(S.clampedFontSize(16), 16, "触控栏字号: 区间内原样")
        expectEqual(S.clampedFontSize(8), S.fontSizeRange.lowerBound, "触控栏字号: 太小夹到下限")
        expectEqual(S.clampedFontSize(40), S.fontSizeRange.upperBound, "触控栏字号: 太大夹到上限")
        expectEqual(S.clampedFontSize(.nan), S.defaultFontSize, "触控栏字号: 存坏了用默认值")
        expectEqual(S.fontSizeRange.contains(S.defaultFontSize), true, "触控栏字号: 默认值在区间里")
        // 图层行的位图高 = ceil(上伸 − 下伸 + 行距) + 2(同 `OverlayLyricScrollView.textHeight`),得放进 30pt。
        var tooTall: [Int] = []
        for size in stride(from: S.fontSizeRange.lowerBound, through: S.fontSizeRange.upperBound, by: 1) {
            let font = NSFont.systemFont(ofSize: CGFloat(size), weight: .medium)
            if ceil(font.ascender - font.descender + font.leading) + 2 > 30 { tooTall.append(Int(size)) }
        }
        expectEqual(tooTall, [], "触控栏字号: 区间内每一档的行高都放得进 30pt")

        // 展开态版面:歌词那一格分到收起键、封面、三键(连同旁边那颗设置键)之后剩下的宽。两项都显示时 393pt,
        // 跟模拟器里实测的一致;藏起来的那一项连同间距让给歌词。
        expectEqual(S.lyricsWidth(showsArtwork: true, showsControls: true), 393, "触控栏版面: 封面 + 三键都在")
        expectEqual(S.lyricsWidth(showsArtwork: false, showsControls: true), 431, "触控栏版面: 藏起封面")
        expectEqual(S.lyricsWidth(showsArtwork: true, showsControls: false), 583, "触控栏版面: 藏起三键")
        expectEqual(S.lyricsWidth(showsArtwork: false, showsControls: false), 621, "触控栏版面: 两样都藏起")
        // 「⋯」键(决策 47):定宽 44 + 前面的间距 8,从歌词那一格里扣。
        expectEqual(S.moreKeySlot, 52, "触控栏版面: 「⋯」键连间距 52pt")
        expectEqual(S.lyricsWidth(showsArtwork: false, showsControls: false, showsMoreKey: true), 569,
                    "触控栏版面: 只有「⋯」键")
        expectEqual(S.lyricsWidth(showsArtwork: false, showsControls: false, hidesControlStrip: true, showsMoreKey: true),
                    888, "触控栏版面: 隐藏功能栏 + 「⋯」键")
        // 隐藏功能栏:展开条占满整条(实测 1004pt),左端是 App 自己的收起键,收起键连同间距正好等于系统 ✕ 那一段,
        // 封面、三键、歌词的左缘跟不隐藏时一样。
        expectEqual(S.collapseItemWidth + S.itemSpacing, S.firstItemX, "触控栏版面: 自己的收起键连同间距 = 系统 ✕ 那一段")
        expectEqual(S.lyricsWidth(showsArtwork: true, showsControls: true, hidesControlStrip: true), 712,
                    "触控栏版面: 隐藏功能栏时封面 + 三键都在")
        expectEqual(S.lyricsWidth(showsArtwork: false, showsControls: false, hidesControlStrip: true), 940,
                    "触控栏版面: 隐藏功能栏时两样都藏起")
        // 1st generation(左端是虚拟 Esc 键,17 章决策 36):前面多一个 Esc 那一格(自己的 esc 键连同后面的间距),收起键
        // 一直跟在后面。模拟器实测:默认展开时跟 2nd generation 一样宽,隐藏功能栏时整条 1085pt。
        expectEqual(S.lyricsWidth(showsArtwork: true, showsControls: true, escapeKey: true), 393,
                    "触控栏版面: 1st generation 默认展开、封面 + 三键都在")
        expectEqual(S.lyricsWidth(showsArtwork: true, showsControls: true, hidesControlStrip: true, escapeKey: true), 713,
                    "触控栏版面: 1st generation 隐藏功能栏、封面 + 三键都在")
        expectEqual(S.lyricsWidth(showsArtwork: false, showsControls: false, escapeKey: true), 621,
                    "触控栏版面: 1st generation 默认展开、两样都藏起")
        expectEqual(S.lyricsWidth(showsArtwork: false, showsControls: false, hidesControlStrip: true, escapeKey: true), 941,
                    "触控栏版面: 1st generation 隐藏功能栏、两样都藏起")

        // 副行:译文最清楚、读音次之、下一句最淡(同灵动岛副行那三档),不显示是 0。
        expectEqual(S.secondaryRowOpacity(for: .off), 0, "触控栏副行: 不显示时不透明度是 0")
        expectEqual(S.secondaryRowOpacity(for: .translation) > S.secondaryRowOpacity(for: .romanization)
                        && S.secondaryRowOpacity(for: .romanization) > S.secondaryRowOpacity(for: .nextLine)
                        && S.secondaryRowOpacity(for: .nextLine) > 0, true,
                    "触控栏副行: 译文最清楚、读音次之、下一句最淡")

        // 暗部亮度(17 章决策 51):默认值跟加这一项之前一样;副行按它同比抬、封顶 1;越界、存坏了夹回区间。
        let kinds: [LyricSecondaryLine] = [.off, .nextLine, .translation, .romanization]
        for kind in kinds {
            expectEqual(abs(S.secondaryRowOpacity(for: kind, dimLevel: S.defaultDimLevel) - S.secondaryRowOpacity(for: kind)) < 1e-9,
                        true, "触控栏暗部亮度: 默认值时副行 \(kind) 不变")
            expectEqual(S.secondaryRowOpacity(for: kind, dimLevel: 1) <= 1, true, "触控栏暗部亮度: 副行 \(kind) 封顶 1")
        }
        expectEqual(S.secondaryRowOpacity(for: .translation, dimLevel: 1), 1, "触控栏暗部亮度: 拉满时译文满亮")
        expectEqual(S.secondaryRowOpacity(for: .nextLine, dimLevel: 0.9) > S.secondaryRowOpacity(for: .nextLine), true,
                    "触控栏暗部亮度: 调高时副行跟着亮")
        expectEqual(S.secondaryRowOpacity(for: .translation, dimLevel: 0.2) < S.secondaryRowOpacity(for: .translation), true,
                    "触控栏暗部亮度: 调低时副行跟着暗")
        expectEqual(S.clampedDimLevel(0.05), S.dimLevelRange.lowerBound, "触控栏暗部亮度: 太低夹到下限")
        expectEqual(S.clampedDimLevel(3), 1, "触控栏暗部亮度: 太高夹到 1")
        expectEqual(S.clampedDimLevel(.nan), S.defaultDimLevel, "触控栏暗部亮度: 存坏了用默认值")

        // 歌词颜色(17 章决策 51):存过就用存的;没存过按旧的「跟随封面」开关落档;都没有用默认。
        typealias M = TouchBarLyricsColorMode
        expectEqual(M.resolved(stored: "custom", legacyFollowsCover: true, fallback: .cover), .custom, "触控栏歌词颜色: 存过的优先")
        expectEqual(M.resolved(stored: nil, legacyFollowsCover: true, fallback: .white), .cover, "触控栏歌词颜色: 旧开关开着 → 跟随封面")
        expectEqual(M.resolved(stored: nil, legacyFollowsCover: false, fallback: .cover), .white, "触控栏歌词颜色: 旧开关关着 → 白色")
        expectEqual(M.resolved(stored: nil, legacyFollowsCover: nil, fallback: .cover), .cover, "触控栏歌词颜色: 都没存过用默认")
        expectEqual(M.resolved(stored: "bogus", legacyFollowsCover: false, fallback: .cover), .white, "触控栏歌词颜色: 存坏了按旧开关")
    }

    // ---- 黑底上打折的歌词色(未唱的部分、副行):不暗于白字打同一个折,只往亮里补,色相族不变,未唱仍比已唱暗 ----
    do {
        typealias S = TouchBarLyricsStyle
        typealias RGB = (r: Double, g: Double, b: Double)
        func luma(_ c: RGB) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }
        func strongest(_ c: RGB) -> Int { c.r >= c.g && c.r >= c.b ? 0 : (c.g >= c.b ? 1 : 2) }
        let white = S.dimmedOnBlack(r: 1, g: 1, b: 1, opacity: 0.45)
        expectEqual(abs(white.r - 0.45) < 0.001 && abs(white.g - 0.45) < 0.001 && abs(white.b - 0.45) < 0.001, true,
                    "触控栏配色: 白字打折就是同一档的灰(白字模式的样子不变)")
        // 深红 / 宝蓝 / 墨绿三种封面均值色,先走「跟随封面」本来那两步得到已唱色。
        let raws: [RGB] = [(0.55, 0.11, 0.11), (0.16, 0.27, 0.71), (0.12, 0.42, 0.23)]
        for raw in raws {
            let base = LocalPlaybackSource.brightenedAccent(r: raw.r, g: raw.g, b: raw.b)
            let sung = LocalPlaybackSource.accentForDarkBackdrop(r: base.r, g: base.g, b: base.b)
            for opacity in [0.45, 0.6, 0.75] {
                let dim = S.dimmedOnBlack(r: sung.r, g: sung.g, b: sung.b, opacity: opacity)
                expectEqual(luma(dim) >= opacity - 0.001, true, "触控栏配色: \(raw) 打 \(opacity) 的折不暗于白字同一档")
                expectEqual(dim.r >= sung.r * opacity - 1e-9 && dim.g >= sung.g * opacity - 1e-9
                                && dim.b >= sung.b * opacity - 1e-9, true,
                            "触控栏配色: \(raw) 打 \(opacity) 的折只往亮里补,不比直接打折暗")
            }
            let unsung = S.dimmedOnBlack(r: sung.r, g: sung.g, b: sung.b, opacity: 0.45)
            expectEqual(luma(unsung) < luma(sung), true, "触控栏配色: \(raw) 未唱仍比已唱暗,看得出唱到哪")
            expectEqual(strongest(unsung), strongest(sung), "触控栏配色: \(raw) 未唱跟已唱同一个色相族")
        }
    }

    // ---- 副行开着时的两行:各自那一格的高正好是位图高;照图层行画字的办法量墨迹,两行都不出触控栏、也不互相碰 ----
    do {
        typealias S = TouchBarLyricsStyle
        // 字重同 `TouchBarLyricsCell`:主行 medium、副行 regular。
        let mainFont = NSFont.systemFont(ofSize: CGFloat(S.twoRowMainFontSize), weight: .medium)
        let secondaryFont = NSFont.systemFont(ofSize: CGFloat(S.twoRowSecondaryFontSize), weight: .regular)
        func boxHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) + 2 }
        expectEqual(Double(boxHeight(mainFont)), S.twoRowMainHeight, "触控栏两行: 主行那一格的高 = 主行的位图高")
        expectEqual(Double(boxHeight(secondaryFont)), S.twoRowSecondaryHeight, "触控栏两行: 副行那一格的高 = 副行的位图高")

        // 一串字的墨迹在它那一格里的上下沿(点,从那一格的上缘往下量)。画法照 `OverlayLyricScrollView.drawText`:
        // 不翻转的坐标、底边留 1pt,按 2 倍像素画;排字语言照 `LyricTypesetting` 标上。
        func ink(_ text: String, font: NSFont) -> (top: CGFloat, bottom: CGFloat)? {
            let scale: CGFloat = 2
            let width = 480
            let height = Int(boxHeight(font) * scale)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.scaleBy(x: scale, y: scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            (text as NSString).draw(at: NSPoint(x: 0, y: 1), withAttributes: LyricTypesetting.attributes(
                [.font: font, .foregroundColor: NSColor.white], for: text))
            NSGraphicsContext.restoreGraphicsState()
            guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            // 位图内存里第 0 行是最上面那一行。
            let inked = (0..<height).filter { row in (0..<width).contains { data[(row * width + $0) * 4 + 3] > 20 } }
            guard let first = inked.first, let last = inked.last else { return nil }
            return (CGFloat(first) / scale, CGFloat(last + 1) / scale)
        }
        // 几串字合起来的墨迹,换算成离触控栏上缘多少点。
        func span(_ texts: [String], font: NSFont, rowTop: Double) -> (top: CGFloat, bottom: CGFloat) {
            let marks = texts.compactMap { ink($0, font: font) }
            expectEqual(marks.count, texts.count, "触控栏两行: 量到了墨迹(\(texts.joined(separator: " / ")))")
            return (CGFloat(rowTop) + (marks.map(\.top).min() ?? 0), CGFloat(rowTop) + (marks.map(\.bottom).max() ?? 0))
        }
        let cjk = ["我们的歌词", "歌詞の光が", "사랑해요"]
        let latin = ["Thy gypsy"]
        let mainCJK = span(cjk, font: mainFont, rowTop: S.twoRowMainTop)
        let mainLatin = span(latin, font: mainFont, rowTop: S.twoRowMainTop)
        let secondaryCJK = span(cjk, font: secondaryFont, rowTop: S.twoRowSecondaryTop)
        let secondaryLatin = span(latin, font: secondaryFont, rowTop: S.twoRowSecondaryTop)
        expectEqual(min(mainCJK.top, mainLatin.top) >= 1, true,
                    "触控栏两行: 主行的字顶离触控栏上缘至少 1pt(\(min(mainCJK.top, mainLatin.top)))")
        expectEqual(secondaryCJK.bottom <= 29, true, "触控栏两行: 副行汉字底离下缘至少 1pt(\(secondaryCJK.bottom))")
        expectEqual(secondaryLatin.bottom <= 29.5, true,
                    "触控栏两行: 副行 g / y 的下伸不出下缘(\(secondaryLatin.bottom))")
        expectEqual(secondaryCJK.top - mainCJK.bottom >= 2, true,
                    "触控栏两行: 两行汉字之间至少空 2pt(\(secondaryCJK.top - mainCJK.bottom))")
        expectEqual(min(secondaryCJK.top, secondaryLatin.top) - mainLatin.bottom >= 0.5, true,
                    "触控栏两行: 主行 g / y 的下伸碰不到副行的字(\(min(secondaryCJK.top, secondaryLatin.top) - mainLatin.bottom))")
    }

    // ---- 「⋯」键一直在最右端;「更多」页放哪几项(决策 47)----
    do {
        expectEqual(TouchBarSlot.order(artworkSide: .trailing, controlsSide: .leading, showsArtwork: true,
                                       showsControls: true, showsCollapseKey: true, showsMoreKey: true),
                    [.collapse, .controls, .lyrics, .artwork, .more], "触控栏排列: 「⋯」键在摆在右边的那几项之后")
        expectEqual(TouchBarSlot.order(artworkSide: .leading, controlsSide: .leading, showsArtwork: false,
                                       showsControls: false, showsCollapseKey: false, showsMoreKey: false),
                    [.lyrics], "触控栏排列: 关掉「⋯」键就没有它")
        typealias M = TouchBarMorePage
        expectEqual(M.items(hasDuration: true, isAdBreak: false, supportsFavorite: true, canShuffle: true, canRepeat: true, supportsVolume: true),
                    [.back, .progress, .offset, .favorite, .shuffle, .repeat, .volume], "更多页: 全都支持时七项、顺序固定")
        expectEqual(M.items(hasDuration: false, isAdBreak: false, supportsFavorite: false, canShuffle: false, canRepeat: false,
                            supportsVolume: false),
                    [.back, .offset], "更多页: 不知道时长、什么都不支持时只有返回和歌词校准")
        expectEqual(M.items(hasDuration: true, isAdBreak: false, supportsFavorite: false, canShuffle: false, canRepeat: true,
                            supportsVolume: false),
                    [.back, .progress, .offset, .repeat], "更多页: 只有循环(QQ 音乐那种)")
        expectEqual(M.items(hasDuration: true, isAdBreak: false, supportsFavorite: false, canShuffle: true, canRepeat: true,
                            supportsVolume: true),
                    [.back, .progress, .offset, .shuffle, .repeat, .volume], "更多页: 没有喜欢(Spotify 那种)")
        expectEqual(M.items(hasDuration: true, isAdBreak: true, supportsFavorite: false, canShuffle: true, canRepeat: true,
                            supportsVolume: false),
                    [.back, .progress, .shuffle, .repeat], "更多页: 广告期间不放歌词校准")
        expectEqual(M.autoReturnDelayMs, 8_000, "更多页: 8 秒没有操作回到歌词")
        // 不占满整条时只有约 621pt(决策 48):返回、校准、喜欢、随机、循环按定宽排,两条滑杆缩到最窄,刚好放得下全部七项。
        let narrow = 3 * M.keyWidth + (M.keyWidth * 2 + 8 + M.offsetReadoutWidth) + M.keyWidth
            + M.progressMinWidth + M.volumeMinWidth + 6 * 8
        expectEqual(narrow <= 621, true, "更多页: 不占满整条时七项按最窄宽度排得下(\(narrow)pt)")
    }

    // ---- 展开态从左到右:封面、三键各自摆在歌词哪一边;同一边上封面在三键左边;关掉的那项拿掉;系统不给 ✕ 时最左边加自己的收起键 ----
    do {
        func order(_ artworkSide: TouchBarSide, _ controlsSide: TouchBarSide, artwork: Bool = true,
                   controls: Bool = true, collapse: Bool = false) -> [TouchBarSlot] {
            TouchBarSlot.order(artworkSide: artworkSide, controlsSide: controlsSide,
                               showsArtwork: artwork, showsControls: controls, showsCollapseKey: collapse)
        }
        expectEqual(order(.leading, .leading), [.artwork, .controls, .lyrics],
                    "触控栏排列: 都在左边(默认,加这两项之前的排法)")
        expectEqual(order(.leading, .trailing), [.artwork, .lyrics, .controls], "触控栏排列: 封面在左、三键在右")
        expectEqual(order(.trailing, .leading), [.controls, .lyrics, .artwork], "触控栏排列: 三键在左、封面在右")
        expectEqual(order(.trailing, .trailing), [.lyrics, .artwork, .controls],
                    "触控栏排列: 都在右边,同一边上封面在三键左边")
        expectEqual(order(.leading, .trailing, artwork: false), [.lyrics, .controls], "触控栏排列: 关掉封面,三键照旧在右")
        expectEqual(order(.leading, .trailing, controls: false), [.artwork, .lyrics], "触控栏排列: 关掉三键,封面照旧在左")
        let sides = TouchBarSide.allCases.flatMap { a in TouchBarSide.allCases.map { (a, $0) } }
        expectEqual(sides.allSatisfy { order($0.0, $0.1, artwork: false, controls: false) == [.lyrics] }, true,
                    "触控栏排列: 两样都关掉时只剩歌词")
        expectEqual(sides.allSatisfy { order($0.0, $0.1, collapse: true).first == .collapse }, true,
                    "触控栏排列: 要自己的收起键时它在最左边")
        expectEqual(sides.allSatisfy { !order($0.0, $0.1).contains(.collapse) }, true,
                    "触控栏排列: 不要时没有自己的收起键(用系统的 ✕)")
        // 系统不给 ✕ 的两种情形放自己的:占满整条(隐藏功能栏)、本 App 在前台(模拟器实测,见 17 章)。
        typealias Slot = TouchBarSlot
        expectEqual(Slot.showsCollapseKey(fullWidth: true, appIsActive: false, canMinimize: true), true,
                    "触控栏收起键: 占满整条时系统不给 ✕,放自己的")
        expectEqual(Slot.showsCollapseKey(fullWidth: false, appIsActive: true, canMinimize: true), true,
                    "触控栏收起键: 本 App 在前台时系统不给 ✕,放自己的")
        expectEqual(Slot.showsCollapseKey(fullWidth: false, appIsActive: false, canMinimize: true), false,
                    "触控栏收起键: 在后台、不占满整条时用系统的 ✕")
        expectEqual(Slot.showsCollapseKey(fullWidth: false, appIsActive: false, replacesEscapeKey: true, canMinimize: true),
                    true, "触控栏收起键: 1st generation 左端换成自己的 esc 键时系统的 ✕ 跟着没了,放自己的")
        expectEqual(Slot.showsCollapseKey(fullWidth: false, appIsActive: false, replacesEscapeKey: true, canMinimize: false),
                    false, "触控栏收起键: 收起的系统入口缺了就不放")
        expectEqual([true, false].allSatisfy { fullWidth in
            [true, false].allSatisfy { !Slot.showsCollapseKey(fullWidth: fullWidth, appIsActive: $0, canMinimize: false) }
        }, true, "触控栏收起键: 收起的系统入口缺了就不放")
        expectEqual(TouchBarSide.allCases.map(\.rawValue), ["leading", "trailing"],
                    "触控栏排列: rawValue 是存量配置的一部分,别动")
    }

    // ---- 快捷键「展开/收起触控栏歌词」:照此刻看不看得见来翻,总开关关着先打开;没有触控栏、取不到系统入口时只说明 ----
    do {
        typealias Action = TouchBarHotkeyAction
        let bools = [true, false]
        expectEqual(bools.allSatisfy { available in bools.allSatisfy { on in bools.allSatisfy { visible in
            Action.resolve(touchBarPresent: false, entryPointsAvailable: available, switchOn: on, visible: visible)
                == .noTouchBar
        } } }, true, "触控栏快捷键: 没有触控栏时只说明,不碰开关")
        expectEqual(bools.allSatisfy { on in bools.allSatisfy { visible in
            Action.resolve(touchBarPresent: true, entryPointsAvailable: false, switchOn: on, visible: visible)
                == .unavailable
        } }, true, "触控栏快捷键: 取不到触控栏的系统入口时只说明,不去拨开关")
        expectEqual(Action.resolve(touchBarPresent: true, entryPointsAvailable: true, switchOn: false, visible: false),
                    .turnOn, "触控栏快捷键: 总开关关着就打开(打开那一下当场展开)")
        expectEqual(Action.resolve(touchBarPresent: true, entryPointsAvailable: true, switchOn: true, visible: true),
                    .collapse, "触控栏快捷键: 看得见就收起")
        expectEqual(Action.resolve(touchBarPresent: true, entryPointsAvailable: true, switchOn: true, visible: false),
                    .expand, "触控栏快捷键: 开着、看不见时展开,不去翻总开关")
    }

    // ---- 按宽度断句:触控栏是第四个断句的面,按它自己报的宽拆长句、并短句;没报宽度时一句一句换 ----
    do {
        expectEqual(LineBreakSurface.allCases.map(\.rawValue), ["overlay", "notch", "menuBar", "touchBar"],
                    "触控栏断句: 断句的面是三个形态加触控栏")
        expectEqual(LyricsSurface.allCases.map { LineBreakSurface($0).rawValue }, LyricsSurface.allCases.map(\.rawValue),
                    "触控栏断句: 三个形态对得上同名的断句面")
        // 量宽:每个字符 10pt(同 sync-engine 组那一段),期望值可以手算。
        let measure: (String) -> CGFloat = { CGFloat($0.count) * 10 }
        func budget(_ width: CGFloat) -> LineLayoutBudget {
            LineLayoutBudget(key: width, maxWidth: width, measure: measure)
        }
        let yrc = "[69920,1900](69920,1900,0)You got to be startin' somethin'\n"
            + "[71860,1400](71860,1400,0)It's too high to get over\n"
            + "[73260,600](73260,600,0)Yeah yeah\n"
            + "[73890,1300](73890,1300,0)Too low to get under\n"
            + "[75160,600](75160,600,0)Yeah yeah\n"
            + "[75780,3000](75780,1000,0)You're stuck, (76780,1000,0)in the middle (77780,1000,0)of it all\n"
            + "[80000,2000](80000,2000,0)yes\n"
        let engine = LyricsSyncEngine()
        engine.load(lyrics: "", lyricsTr: "", lyricsRoma: "", lyricsYRC: yrc, lineBreaks: .all)
        expectEqual(engine.surfaceTick(.touchBar, atMs: 76000).line?.plainText, "You're stuck, in the middle of it all",
                    "触控栏断句: 还没报宽度时一句一行")
        engine.setLayoutBudget(budget(300), for: .touchBar)
        expectEqual(engine.surfaceTick(.touchBar, atMs: 76000).line?.plainText, "You're stuck,",
                    "触控栏断句: 放不下的长句按触控栏的宽拆开")
        engine.setLayoutBudget(budget(400), for: .touchBar)
        expectEqual(engine.surfaceTick(.touchBar, atMs: 72000).line?.plainText, "It's too high to get over Yeah yeah",
                    "触控栏断句: 很短的一句合进前一句")
        expectEqual(engine.surfaceTick(.overlay, atMs: 72000).line?.plainText, "It's too high to get over",
                    "触控栏断句: 别的面不受触控栏的宽度影响")
        engine.setLayoutBudget(nil, for: .touchBar)
        expectEqual(engine.surfaceTick(.touchBar, atMs: 76000).line?.plainText, "You're stuck, in the middle of it all",
                    "触控栏断句: 撤掉宽度(没启用)回到一句一行")

        // 合并规则:触控栏放得下就并(`MergeRule.whenFits`),别的面只并一闪而过的短句。《拖男带女》里这两句各停
        // 2.9 / 2.0 秒、9 / 7 个字,不算「很短」;合完 4.9 秒,不超过 5 秒。前一句停 4.3 秒,跟它合就超了。
        let lrc = "[00:36.12]每分每秒每天时时刻刻在延续\n[00:40.42]多少钱与多少名和利\n[00:43.34]换回来的是空虚\n"
            + "[00:45.35]放开我们的怀抱\n[00:48.00]让我们的爱带动世界\n"
        let lrcEngine = LyricsSyncEngine()
        lrcEngine.load(lyrics: lrc, lyricsTr: "", lyricsRoma: "", lyricsYRC: "", lineBreaks: .all)
        lrcEngine.setLayoutBudget(LineLayoutBudget(key: "touchBar", main: .init(maxWidth: 400, measure: measure),
                                                   mergeRule: .whenFits), for: .touchBar)
        lrcEngine.setLayoutBudget(budget(400), for: .overlay)
        let joined = lrcEngine.surfaceTick(.touchBar, atMs: 41000).line?.plainText ?? ""
        expectEqual(joined.hasPrefix("多少钱与多少名和利") && joined.hasSuffix("换回来的是空虚"), true,
                    "触控栏合并: 两句完整的句子放得下、合完不超过 5 秒就并成一屏(\(joined))")
        expectEqual(lrcEngine.surfaceTick(.overlay, atMs: 41000).line?.plainText, "多少钱与多少名和利",
                    "触控栏合并: 别的面照旧只并一闪而过的短句")
        expectEqual(lrcEngine.surfaceTick(.touchBar, atMs: 37000).line?.plainText, "每分每秒每天时时刻刻在延续",
                    "触控栏合并: 合完超过 5 秒不并")
        lrcEngine.setLayoutBudget(LineLayoutBudget(key: "narrow", main: .init(maxWidth: 120, measure: measure),
                                                   mergeRule: .whenFits), for: .touchBar)
        expectEqual(lrcEngine.surfaceTick(.touchBar, atMs: 41000).line?.plainText, "多少钱与多少名和利",
                    "触控栏合并: 放不下就不并")
    }

    // ---- 时间基准指纹:锚点、暂停位置、偏移任一变了就变,全一样就不变 ----
    do {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        func anchor(progress: Int = 30_000, rate: Double = 1, at date: Date = at) -> ProgressAnchor {
            ProgressAnchor(durationMs: 200_000, progressMs: progress, rate: rate, progressTs: nil,
                           baseAgeMs: 0, fetchedAt: date)
        }
        let base = LyricsTimingEpoch.of(anchor: anchor(), pausedPositionMs: nil, offsetMs: 0)
        expectEqual(LyricsTimingEpoch.of(anchor: anchor(), pausedPositionMs: nil, offsetMs: 0), base,
                    "时间基准指纹: 输入全一样,值不变")
        let changed: [(String, Int)] = [
            ("锚点进度", LyricsTimingEpoch.of(anchor: anchor(progress: 31_000), pausedPositionMs: nil, offsetMs: 0)),
            ("锚点速率", LyricsTimingEpoch.of(anchor: anchor(rate: 1.5), pausedPositionMs: nil, offsetMs: 0)),
            ("锚点时刻", LyricsTimingEpoch.of(anchor: anchor(at: at.addingTimeInterval(1)), pausedPositionMs: nil,
                                          offsetMs: 0)),
            ("没有锚点", LyricsTimingEpoch.of(anchor: nil, pausedPositionMs: nil, offsetMs: 0)),
            ("暂停位置", LyricsTimingEpoch.of(anchor: anchor(), pausedPositionMs: 30_000, offsetMs: 0)),
            ("歌词偏移", LyricsTimingEpoch.of(anchor: anchor(), pausedPositionMs: nil, offsetMs: 200)),
        ]
        for (what, value) in changed {
            expectNotEqual(value, base, "时间基准指纹: \(what)变了,值跟着变")
        }
    }

    // ---- 自动展开 / 收起(TouchBarAutoPresent,17 章决策 45)----
    do {
        typealias Auto = TouchBarAutoPresent
        func opts(play: Bool = false, pause: Bool = false, noLyrics: Bool = false) -> Auto.Options {
            .init(expandOnPlay: play, collapseWhenPaused: pause, collapseWhenNoLyrics: noLyrics)
        }
        let all = opts(play: true, pause: true, noLyrics: true)

        // 三个开关都关:什么都不动。
        do {
            var a = Auto()
            expectEqual(a.start(isPlaying: false, lacksLyrics: false, trackKey: "A", nowMs: 0, visible: false,
                                options: opts()), .none, "自动展开: 全关时启用不动")
            expectEqual(a.update(isPlaying: true, lacksLyrics: false, trackKey: "A", nowMs: 5_000, visible: false,
                                 options: opts()), .none, "自动展开: 全关时开始播放不动")
            expectEqual(a.update(isPlaying: false, lacksLyrics: true, trackKey: "B", nowMs: 6_000, visible: true,
                                 options: opts()), .none, "自动展开: 全关时暂停、没歌词都不动")
        }
        // 启用时正在播放:开了「开始播放时自动展开」就展开;这首已知没歌词、又开了「无歌词时收起」的不展开;已经看得见的不重复。
        do {
            var a = Auto()
            expectEqual(a.start(isPlaying: true, lacksLyrics: false, trackKey: "A", nowMs: 0, visible: false,
                                options: opts(play: true)), .expandAfterSettle, "自动展开: 启用时正在播放,等再确认")
            expectEqual(a.start(isPlaying: true, lacksLyrics: true, trackKey: "A", nowMs: 0, visible: false,
                                options: all), .none, "自动展开: 启用时这首没歌词、开着无歌词收起,不展开")
            expectEqual(a.start(isPlaying: true, lacksLyrics: false, trackKey: "A", nowMs: 0, visible: true,
                                options: opts(play: true)), .none, "自动展开: 已经展开着(拨开开关那一下)不再展开")
            expectEqual(a.start(isPlaying: false, lacksLyrics: false, trackKey: "A", nowMs: 0, visible: false,
                                options: opts(play: true)), .none, "自动展开: 启用时没在播放不展开")
        }
        // 开始播放:停够了才算;切歌、缓冲那一下(停不到 resumeDebounceMs)不展开;同一状态重复报不重复动作。
        do {
            var a = Auto()
            _ = a.start(isPlaying: true, lacksLyrics: false, trackKey: "A", nowMs: 0, visible: false, options: opts(play: true))
            expectEqual(a.update(isPlaying: false, lacksLyrics: false, trackKey: "A", nowMs: 10_000, visible: false,
                                 options: opts(play: true)), .none, "自动展开: 暂停时不动(没开暂停收起)")
            expectEqual(a.update(isPlaying: true, lacksLyrics: false, trackKey: "B", nowMs: 10_000 + Auto.resumeDebounceMs - 1,
                                 visible: false, options: opts(play: true)), .none, "自动展开: 切歌那一下的暂停不算开始播放")
            expectEqual(a.update(isPlaying: false, lacksLyrics: false, trackKey: "B", nowMs: 20_000, visible: false,
                                 options: opts(play: true)), .none, "自动展开: 再暂停")
            expectEqual(a.update(isPlaying: true, lacksLyrics: false, trackKey: "B", nowMs: 20_000 + Auto.resumeDebounceMs,
                                 visible: false, options: opts(play: true)), .expandAfterSettle, "自动展开: 停够了再播,等再确认")
            expectEqual(a.settleElapsed(isPlaying: true, lacksLyrics: false, nowMs: 0, visible: false, options: opts(play: true)),
                        .expand, "自动展开: 再确认时还在放、还收着,展开")
            expectEqual(a.settleElapsed(isPlaying: true, lacksLyrics: false, nowMs: 0, visible: false, options: opts(play: true)),
                        .none, "自动展开: 再确认只认一次")
            expectEqual(a.update(isPlaying: true, lacksLyrics: false, trackKey: "B", nowMs: 23_000, visible: false,
                                 options: opts(play: true)), .none, "自动展开: 同一状态重复报不重复展开")
            expectEqual(a.update(isPlaying: true, lacksLyrics: false, trackKey: "C", nowMs: 30_000, visible: false,
                                 options: opts(play: true)), .none, "自动展开: 播放中自然换歌不展开(手动收起的保持收起)")
        }
        // 开始播放后再确认(settleExpandDelayMs):启动时先把播客当成在放歌、随即认出不是歌,不展开;期间用户自己动了、
        // 已经展开着、开关关了、这首确认没歌词又开着无歌词收起,都不展开。
        do {
            var a = Auto()
            expectEqual(a.start(isPlaying: false, lacksLyrics: false, trackKey: "播客", nowMs: 0, visible: false,
                                options: opts(play: true)), .none, "再确认: 启动时还没认出在放")
            expectEqual(a.update(isPlaying: true, lacksLyrics: false, trackKey: "播客", nowMs: 2_400, visible: false,
                                 options: opts(play: true)), .expandAfterSettle, "再确认: 先当成在放,等再确认")
            expectEqual(a.update(isPlaying: false, lacksLyrics: false, trackKey: "播客", nowMs: 3_800, visible: false,
                                 options: opts(play: true)), .none, "再确认: 认出不是歌(当成没在放)")
            expectEqual(a.settleElapsed(isPlaying: false, lacksLyrics: false, nowMs: 0, visible: false, options: opts(play: true)),
                        .none, "再确认: 启动时的播客不展开")
            func pending() -> Auto {
                var b = Auto()
                _ = b.start(isPlaying: true, lacksLyrics: false, trackKey: "A", nowMs: 0, visible: false, options: all)
                return b
            }
            var b = pending()
            b.userChangedVisibility()
            expectEqual(b.settleElapsed(isPlaying: true, lacksLyrics: false, nowMs: 0, visible: false, options: all), .none,
                        "再确认: 期间用户自己动了,不展开")
            b = pending()
            expectEqual(b.settleElapsed(isPlaying: true, lacksLyrics: false, nowMs: 0, visible: true, options: all), .none,
                        "再确认: 已经展开着,不重复")
            b = pending()
            expectEqual(b.settleElapsed(isPlaying: true, lacksLyrics: false, nowMs: 0, visible: false, options: opts(noLyrics: true)),
                        .none, "再确认: 期间开关关了,不展开")
            b = pending()
            expectEqual(b.settleElapsed(isPlaying: true, lacksLyrics: true, nowMs: 0, visible: false, options: all), .none,
                        "再确认: 期间确认这首没歌词、开着无歌词收起,不展开")
            var c = Auto()
            expectEqual(c.settleElapsed(isPlaying: true, lacksLyrics: false, nowMs: 0, visible: false, options: all), .none,
                        "再确认: 没在等就不展开")
        }
        // 开始播放触发的展开算临时的(provisionalExpandMs,决策 49):期间判定没在放歌(启动时先把播客当成歌、过了几秒才认出来)
        // 当场收回,不看「暂停时自动收起」;过了这段时间按普通暂停;用户自己动过就不算临时的了。
        do {
            func expandedOnPlay(at ms: Int) -> Auto {
                var a = Auto()
                _ = a.start(isPlaying: false, lacksLyrics: false, trackKey: "播客", nowMs: 0, visible: false,
                            options: opts(play: true))
                _ = a.update(isPlaying: true, lacksLyrics: false, trackKey: "播客", nowMs: 2_400, visible: false,
                             options: opts(play: true))
                _ = a.settleElapsed(isPlaying: true, lacksLyrics: false, nowMs: ms, visible: false, options: opts(play: true))
                return a
            }
            var a = expandedOnPlay(at: 5_000)
            expectEqual(a.update(isPlaying: false, lacksLyrics: false, trackKey: "播客", nowMs: 11_300, visible: true,
                                 options: opts(play: true)), .collapse, "临时展开: 认出不是歌(当成停了)当场收回")
            expectEqual(a.autoCollapsed, .paused, "临时展开: 收回记成因为暂停,真是歌再放起来会展开回来")
            a = expandedOnPlay(at: 5_000)
            expectEqual(a.update(isPlaying: false, lacksLyrics: false, trackKey: "A", nowMs: 5_000 + Auto.provisionalExpandMs,
                                 visible: true, options: opts(play: true, pause: true)), .schedulePauseCollapse,
                        "临时展开: 过了临时期按普通暂停")
            a = expandedOnPlay(at: 5_000)
            a.userChangedVisibility()
            expectEqual(a.update(isPlaying: false, lacksLyrics: false, trackKey: "A", nowMs: 6_000, visible: true,
                                 options: opts(play: true)), .none, "临时展开: 用户自己动过就不算临时的")
        }
        // 暂停时收起:暂停排一次计时,满了还暂停、还看得见才收;继续播放时展开回来,不看「开始播放时自动展开」。
        do {
            var a = Auto()
            _ = a.start(isPlaying: true, lacksLyrics: false, trackKey: "A", nowMs: 0, visible: true, options: opts(pause: true))
            expectEqual(a.update(isPlaying: false, lacksLyrics: false, trackKey: "A", nowMs: 1_000, visible: true,
                                 options: opts(pause: true)), .schedulePauseCollapse, "暂停收起: 暂停时排计时")
            expectEqual(a.pauseDelayElapsed(isPlaying: true, visible: true, options: opts(pause: true)), .none,
                        "暂停收起: 计时满时已经在播,不收")
            expectEqual(a.pauseDelayElapsed(isPlaying: false, visible: false, options: opts(pause: true)), .none,
                        "暂停收起: 计时满时已经收着,不收")
            expectEqual(a.pauseDelayElapsed(isPlaying: false, visible: true, options: opts()), .none,
                        "暂停收起: 计时期间开关关了,不收")
            expectEqual(a.pauseDelayElapsed(isPlaying: false, visible: true, options: opts(pause: true)), .collapse,
                        "暂停收起: 满了还暂停、还展开着,收起")
            expectEqual(a.autoCollapsed, .paused, "暂停收起: 记下是因为暂停收的")
            expectEqual(a.update(isPlaying: true, lacksLyrics: false, trackKey: "A", nowMs: 2_000, visible: false,
                                 options: opts(pause: true)), .expand, "暂停收起: 继续播放时展开回来(哪怕停得很短)")
            expectEqual(a.autoCollapsed, nil, "暂停收起: 展开后不再记着")
            expectEqual(a.update(isPlaying: false, lacksLyrics: false, trackKey: "A", nowMs: 3_000, visible: false,
                                 options: opts(pause: true)), .none, "暂停收起: 收着时暂停不排计时")
        }
        // 用户自己收起 / 展开之后:自动收起的原因作废,手动的结果保持到下一次变化。
        do {
            var a = Auto()
            _ = a.start(isPlaying: true, lacksLyrics: false, trackKey: "A", nowMs: 0, visible: true, options: opts(pause: true))
            _ = a.update(isPlaying: false, lacksLyrics: false, trackKey: "A", nowMs: 1_000, visible: true, options: opts(pause: true))
            _ = a.pauseDelayElapsed(isPlaying: false, visible: true, options: opts(pause: true))
            a.userChangedVisibility()
            expectEqual(a.update(isPlaying: true, lacksLyrics: false, trackKey: "A", nowMs: 30_000, visible: false,
                                 options: opts(pause: true)), .none, "手动操作后: 暂停收起的原因作废,继续播放不展开")
            expectEqual(a.update(isPlaying: false, lacksLyrics: false, trackKey: "A", nowMs: 31_000, visible: true,
                                 options: opts(pause: true)), .schedulePauseCollapse, "手动展开后: 下一次暂停照常排计时")
        }
        // 纯音乐 / 无歌词时收起:确认没歌词那一刻收;下一首(搜索期间算有)或者后来有了歌词时展开回来;手动展开的不再收。
        do {
            var a = Auto()
            let o = opts(noLyrics: true)
            _ = a.start(isPlaying: true, lacksLyrics: false, trackKey: "A", nowMs: 0, visible: true, options: o)
            expectEqual(a.update(isPlaying: true, lacksLyrics: true, trackKey: "A", nowMs: 3_000, visible: true, options: o),
                        .collapse, "无歌词收起: 确认没歌词时收起")
            expectEqual(a.autoCollapsed, .noLyrics, "无歌词收起: 记下是因为没歌词收的")
            expectEqual(a.update(isPlaying: true, lacksLyrics: false, trackKey: "B", nowMs: 200_000, visible: false, options: o),
                        .expand, "无歌词收起: 换到下一首(搜索期间)展开回来")
            expectEqual(a.update(isPlaying: true, lacksLyrics: true, trackKey: "C", nowMs: 400_000, visible: true, options: o),
                        .collapse, "无歌词收起: 换到一首已知没歌词的,收起")
            expectEqual(a.update(isPlaying: false, lacksLyrics: true, trackKey: "C", nowMs: 401_000, visible: false, options: all),
                        .none, "无歌词收起: 没歌词的这首暂停不动")
            expectEqual(a.update(isPlaying: true, lacksLyrics: true, trackKey: "C", nowMs: 420_000, visible: false, options: all),
                        .none, "无歌词收起: 没歌词的这首继续播放不展开(哪怕开着自动展开)")
            a.userChangedVisibility()
            expectEqual(a.update(isPlaying: true, lacksLyrics: true, trackKey: "C", nowMs: 421_000, visible: true, options: o),
                        .none, "无歌词收起: 手动展开后同一首不再收")
            expectEqual(a.update(isPlaying: true, lacksLyrics: false, trackKey: "D", nowMs: 600_000, visible: true, options: o),
                        .none, "无歌词收起: 看得见时换到有歌词的不动")
        }
        // 没歌词收起后、暂停期间换到有歌词的一首:开着暂停收起时先不展开,继续播放时展开。
        do {
            var a = Auto()
            let o = opts(pause: true, noLyrics: true)
            _ = a.start(isPlaying: true, lacksLyrics: true, trackKey: "A", nowMs: 0, visible: true, options: o)
            expectEqual(a.update(isPlaying: true, lacksLyrics: true, trackKey: "B", nowMs: 1_000, visible: true, options: o),
                        .collapse, "无歌词收起: 换到没歌词的一首,收起")
            _ = a.update(isPlaying: false, lacksLyrics: true, trackKey: "B", nowMs: 2_000, visible: false, options: o)
            expectEqual(a.update(isPlaying: false, lacksLyrics: false, trackKey: "C", nowMs: 3_000, visible: false, options: o),
                        .none, "无歌词收起: 暂停期间换到有歌词的,先不展开")
            expectEqual(a.update(isPlaying: true, lacksLyrics: false, trackKey: "C", nowMs: 3_500, visible: false, options: o),
                        .expand, "无歌词收起: 继续播放时展开回来")
        }
    }

    // ---- 接线契约 ----
    let sourcesRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let appDir = sourcesRoot.appendingPathComponent("lyrimuse")
    func code(_ url: URL) -> String? {
        guard let text = try? String(contentsOfFile: url.path, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    // 私有入口(四个类方法、两个 C 函数和它们所在的框架)只在封装文件里出现:别处要用就经 TouchBarPrivateAPI。
    do {
        let privateNames = ["addSystemTrayItem", "removeSystemTrayItem", "presentSystemModalTouchBar",
                            "dismissSystemModalTouchBar", "DFRElementSetControlStripPresenceForIdentifier",
                            "DFRSystemModalShowsCloseBoxWhenFrontMost", "DFRTouchBarGetMain",
                            "DFRRegisterStatusChangeCallback", "DFRFoundation", "minimizeSystemModalTouchBar",
                            "DFRTouchBarWantsEscOverrides"]
        let home = "TouchBar/TouchBarPrivateAPI.swift"
        var scanned = 0
        var strays: [String] = []
        let files = FileManager.default.enumerator(at: appDir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        for file in files {
            let relative = String(file.path.dropFirst(appDir.path.count + 1))
            guard let text = code(file) else { continue }
            scanned += 1
            guard relative != home else { continue }
            for name in privateNames where sourceBytes(text, contain: name) && text.contains(name) {
                strays.append("\(name) @ \(relative)")
            }
        }
        expectEqual(scanned > 50, true, "触控栏: 扫到了 App 源码(\(scanned) 个文件)")
        expectEqual(strays.sorted(), [], "触控栏: 私有入口只出现在 \(home)")
        if let api = code(appDir.appendingPathComponent(home)) {
            for name in privateNames {
                expectEqual(api.contains(name), true, "触控栏: \(home) 里有 \(name)")
            }
        } else {
            expectEqual(false, true, "触控栏: 读到了 \(home)")
        }
    }

    do {
        let delegate = code(appDir.appendingPathComponent("AppDelegate.swift")) ?? ""
        expectEqual(delegate.contains("TouchBarLyricsController.shared.start()"), true,
                    "触控栏: AppDelegate 启动时起控制器")
    }

    // 开关在「歌词显示 › 触控栏」那一段(`currentSection` 的 `case .touchBar:` 分支),不在菜单栏那段;
    // 那一段的分段取值不是任何 LyricsSurface。
    do {
        expectEqual(LyricsSurface(rawValue: SettingsSearchCatalog.touchBarSectionValue), nil,
                    "触控栏: 「触控栏」分段不是一个 LyricsSurface")
        let settingsView = code(appDir.appendingPathComponent("SettingsView.swift")) ?? ""
        func branch(_ start: String, until end: String) -> String? {
            guard let from = settingsView.range(of: start),
                  let to = settingsView.range(of: end, range: from.upperBound..<settingsView.endIndex) else { return nil }
            return String(settingsView[from.upperBound..<to.lowerBound])
        }
        let touchBarBranch = branch("\n        case .touchBar:\n", until: "\n        case .lyricsWindow:\n")
        let menuBarBranch = branch("\n        case .menuBar:\n", until: "\n        case .touchBar:\n")
        expectEqual(touchBarBranch?.contains("isOn: $settings.showLyricsInTouchBar"), true,
                    "触控栏: 开关在 currentSection 的 .touchBar 分支里")
        expectEqual(menuBarBranch.map { $0.contains("showLyricsInTouchBar") }, false,
                    "触控栏: 菜单栏那段不再放触控栏的开关")

        // 十项设置:设置行在 TouchBarSettingsRows.swift 的三组行视图里,`.touchBar` 那一支装着工具栏和「全部设置」抽屉;
        // 控制器都接上了,「恢复默认」每一项都管到、不碰总开关(漏一项都不报错,只表现成拨了没反应 / 恢复不了)。
        let controller = code(appDir.appendingPathComponent("TouchBar/TouchBarLyricsController.swift")) ?? ""
        let rows = code(appDir.appendingPathComponent("UI/TouchBarSettingsRows.swift")) ?? ""
        func structBody(_ name: String) -> String {
            guard let from = rows.range(of: "struct \(name): View {") else { return "" }
            let to = rows.range(of: "\nstruct ", range: from.upperBound..<rows.endIndex)?.lowerBound ?? rows.endIndex
            return String(rows[from.upperBound..<to])
        }
        let rowViews = structBody("TouchBarLyricsRows") + structBody("TouchBarStyleRows") + structBody("TouchBarLayoutRows")
            + structBody("TouchBarBehaviorRows")
        let restore = rows.range(of: "static func restoreDefaults() {")
            .map { String(rows[$0.upperBound...].prefix { $0 != "}" }) } ?? ""
        expectEqual(touchBarBranch?.contains("TouchBarEditorToolbar()") == true
                        && touchBarBranch?.contains("TouchBarAllSettingsDrawer()") == true, true,
                    "触控栏: .touchBar 那一支装着工具栏和「全部设置」抽屉")
        for key in ["touchBarLyricsKaraoke", "touchBarLyricsColorMode", "touchBarLyricsColorHex", "touchBarLyricsDimLevel",
                    "touchBarLyricsFontSize",
                    "touchBarShowsArtwork", "touchBarShowsControls", "touchBarSecondaryLine",
                    "touchBarArtworkSide", "touchBarControlsSide", "touchBarHidesControlStrip",
                    "touchBarLyricsAlignment", "touchBarShowsMoreKey", "touchBarExpandOnPlay", "touchBarCollapseWhenPaused",
                    "touchBarCollapseWhenNoLyrics"] {
            expectEqual(rowViews.contains("settings.\(key)"), true, "触控栏: \(key) 的设置行在三组行视图里")
            expectEqual(controller.contains("settings.$\(key)"), true, "触控栏: 控制器订阅了 \(key)")
            expectEqual(restore.contains("settings.\(key) = "), true, "触控栏: 「恢复默认」管到 \(key)")
        }
        expectEqual(restore.contains("showLyricsInTouchBar"), false, "触控栏: 「恢复默认」不碰总开关")
        // 主行未唱的部分、副行在黑底上打折都走 dimmedOnBlack,不直接打透明度(跟随封面时那样会发糊)。
        let dimmedColorCell = code(appDir.appendingPathComponent("TouchBar/TouchBarLyricsCell.swift")) ?? ""
        expectEqual(dimmedColorCell.contains("dimmedOnBlack(inputs.color, opacity: CGFloat(inputs.dimLevel))")
                        && dimmedColorCell.contains("opacity: CGFloat(TouchBarLyricsStyle.secondaryRowOpacity(for: kind, dimLevel: inputs.dimLevel))")
                        && !dimmedColorCell.contains("withAlphaComponent(CGFloat(inputs.dimLevel))")
                        && !dimmedColorCell.contains("withAlphaComponent(CGFloat(TouchBarLyricsStyle.secondaryRowOpacity"), true,
                    "触控栏配色: 未唱的部分、副行打折走 dimmedOnBlack")
        // 自动展开 / 收起(17 章决策 45):启用那一刻先记状态再订阅播放状态(订阅的头一拍丢掉);四项一起防抖;可见状态的变化
        // 跟自己发起的对不上就当成用户动的;工具栏第二行是「行为」加两份占位和「重置 ▾」的占位。漏一处不报错,只表现成
        // 自动展开 / 收起不灵、或者手动收起后又被弹出来。
        expectEqual(sourceHas(controller, "startAuto(presentingNow: presentNow)\n            observePlayback()")
                        && sourceHas(controller, "Publishers.CombineLatest4(p.$isPlayingNow, p.$currentTrackLacksLyrics, p.$title, p.$artist)\n                .dropFirst()\n                .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)")
                        && sourceHas(controller, "Self.expectedVisibilityTimeout {\n            } else {\n                autoPresent.userChangedVisibility()")
                        && controller.contains("try? await Task.sleep(for: .milliseconds(TouchBarAutoPresent.pauseCollapseDelayMs))")
                        && controller.contains("if isPlaying { cancelPauseCollapse() } else { cancelSettleExpand() }")
                        && controller.contains("try? await Task.sleep(for: .milliseconds(TouchBarAutoPresent.settleExpandDelayMs))")
                        && controller.contains("self.performAuto(self.autoPresent.settleElapsed("), true,
                    "触控栏自动展开: 控制器接线(先记状态再订阅、防抖、认出用户操作、暂停计时、开始播放后再确认)")
        expectEqual(sourceHas(rows, "toolbarButton(.behavior)\n            ghostButton(.style)\n            ghostButton(.layout)\n            Spacer(minLength: 8)\n            EditorToolbarResetReserve()")
                        && rows.contains("static let firstRow: [TouchBarSettingsGroup] = [.lyrics, .style, .layout]")
                        && rows.contains("ForEach(TouchBarSettingsGroup.firstRow, id: \\.self)"), true,
                    "触控栏自动展开: 「行为」在工具栏第二行,带对齐占位")
        // 「更多」页(17 章决策 47):换页改 defaultItemIdentifiers(弹出式触控栏项在系统模态条里弹不出来);「更多」页左端收起键照旧;
        // 返回、8 秒没有操作、收起、换歌、停用都回到歌词;这一页的键由 TouchBarMorePageBar 建。漏一处不报错,只表现成点了没反应、
        // 回不到歌词,或者收起键没了。
        expectEqual(controller.contains("bar.defaultItemIdentifiers = (layout.slots.contains(.collapse) ? [Item.collapse] : []) + morePage.identifiers()")
                        && sourceHas(controller, "case Item.more:\n            item.view = moreButton")
                        && controller.contains("return morePage.makeItem(for: identifier)")
                        && controller.contains("page.onBack = { [weak self] in self?.showLyricsPage(reason: \"back\") }")
                        && controller.contains("try? await Task.sleep(for: .milliseconds(TouchBarMorePage.autoReturnDelayMs))")
                        && sourceHas(controller, "guard visible else {\n            showLyricsPage(reason: \"collapsed\")")
                        && controller.contains(".sink { [weak self] _ in self?.showLyricsPage(reason: \"track changed\") }")
                        && controller.contains("showLyricsPage(reason: \"disabled\")")
                        && controller.contains("playbackObservers = morePage.observations() + [")
                        && sourceHas(controller, "morePage.refreshStates()\n        morePage.setActive(true)")
                        && sourceHas(controller, "showingMorePage = false\n        morePage.setActive(false)"), true,
                    "触控栏更多页: 换页、回到歌词的几个时机、这一页的键")
        // 进度(决策 47):这一页显示着才跟播放位置走;拖着时不盖滑杆,松手一会儿才跳一次;不接受跳转的播放器只显示不能拖;
        // 位置不叠歌词偏移。
        let moreBar = code(appDir.appendingPathComponent("TouchBar/TouchBarMorePageBar.swift")) ?? ""
        expectEqual(sourceHas(moreBar, "repeats: true) { [weak self] _ in\n            MainActor.assumeIsolated { self?.refreshProgress() }"), true,
                    "触控栏更多页: 进度定时器弱引用写在定时器闭包上,不被定时器强持有")
        expectEqual(moreBar.contains("progressItem.slider.isEnabled = p.acceptsSeek")
                        && moreBar.contains("let position = p.anchor?.extrapolatedPositionMs(now: Date()) ?? p.pausedPositionMs ?? 0")
                        && moreBar.contains("Date().timeIntervalSince(lastProgressDrag) > 1.5")
                        && moreBar.contains("pendingSeek?.cancel()")
                        && moreBar.contains("DispatchQueue.main.asyncAfter(deadline: .now() + Self.seekSettleSeconds, execute: work)")
                        && !moreBar.contains("currentLyricsOffsetMs"), true,
                    "触控栏更多页: 进度条跟着走、拖动不被盖、松手才跳、只读不叠偏移的播放位置")
        // 审查后补的三条(决策 48):这一页没显示时状态变了不重排;进度、音量优先级最低、返回最高、每颗键定宽;
        // 自动展开 / 收起等的可见状态有时限。
        expectEqual(sourceHas(moreBar, "private func stateChanged() {\n        guard active else { return }")
                        && moreBar.contains("item.visibilityPriority = .low")
                        && moreBar.components(separatedBy: "item.visibilityPriority = .low").count == 3
                        && moreBar.contains("custom.visibilityPriority = .high")
                        && moreBar.contains("button.widthAnchor.constraint(equalToConstant: CGFloat(TouchBarMorePage.keyWidth)).isActive = true"),
                    true, "触控栏更多页: 只在显示时重排、放不下先藏两条滑杆、键定宽")
        expectEqual(controller.contains("Date().timeIntervalSince(expected.at) < Self.expectedVisibilityTimeout")
                        && controller.contains("expectedVisibility = (true, Date())")
                        && controller.contains("expectedVisibility = (false, Date())"), true,
                    "触控栏自动展开: 等着的可见状态有时限,过时的不再当成自己做的")
        expectEqual(controller.contains("button.widthAnchor.constraint(equalToConstant: CGFloat(TouchBarLyricsStyle.moreKeyWidth))")
                        && (code(appDir.appendingPathComponent("UI/TouchBarPreviewStage.swift")) ?? "")
                            .contains(".frame(width: CGFloat(TouchBarLyricsStyle.moreKeyWidth), height: Self.barSize.height)"), true,
                    "触控栏更多页: 「⋯」键本体和预览都按定宽画,估算宽扣得准")
        // 系统开了「减弱动态效果」(17 章决策 43):本体和预览都把它传成图层行的 `still`,图层行这时不装动画、摆在开头、
        // 整行用已唱那张;本体收到系统通知当场重画,预览的「横向滚动」提示也看它。漏一处不报错,只表现成照样滚 / 填色。
        let scrollRow = code(appDir.appendingPathComponent("UI/OverlayScrollingLyricRow.swift")) ?? ""
        let previewSource = code(appDir.appendingPathComponent("UI/TouchBarPreviewStage.swift")) ?? ""
        expectEqual(sourceHas(dimmedColorCell, "rate: inputs.rate,\n            still: inputs.still)"), true,
                    "触控栏减弱动态: 规格把 still 传给图层行")
        expectEqual(sourceHas(scrollRow, "if spec.still {\n            scrollPath = []")
                        && scrollRow.contains("let running = reinstall && !spec.paused && !spec.still")
                        && scrollRow.contains("spec.pacedWindow != nil || spec.still")
                        && scrollRow.contains("a.still = b.still")
                        && scrollRow.contains("spec?.still != next.still"), true,
                    "触控栏减弱动态: 图层行 still 时不装动画、停在开头、整行用已唱那张")
        expectEqual(controller.contains("still: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)")
                        && controller.contains(".publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)"),
                    true, "触控栏减弱动态: 本体读系统设置、拨了当场重画")
        expectEqual(previewSource.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion")
                        && previewSource.contains("still: reduceMotion)")
                        && previewSource.contains("let scrolls = !reduceMotion && "), true,
                    "触控栏减弱动态: 预览同本体,「横向滚动」提示也看它")
        expectEqual(structBody("TouchBarStyleRows").contains(
                        "subtitle: reduceMotion ? L10n.t(\"系统已开启「减弱动态效果」，触控栏歌词不滚动、不逐字高亮\") : nil"),
                    true, "触控栏减弱动态: 卡拉OK效果那一行说明为什么没效果")

        // 没有触控栏时:那一段照样在、点进去只有说明卡,搜索只留总开关那一条,控制器不启用。漏一处都不报错,只表现成
        // 没有触控栏的 Mac 上冒出几项拨了没用的设置,或者白调私有接口。
        expectEqual(touchBarBranch?.contains("if touchBar.settingsShowsPresent {"), true,
                    "触控栏: .touchBar 那一支按有没有触控栏分两种内容")
        expectEqual(touchBarBranch?.contains("L10n.t(\"此 Mac 未配备触控栏\")"), true,
                    "触控栏: 没有触控栏时放「这台 Mac 没有触控栏」那张说明卡")
        // 副行开着时两行字号由触控栏的高定,「字号」那一行留着、尾部换成「由副行决定」(同菜单栏),而且紧跟在「副行」下面。
        let lyricsRows = structBody("TouchBarLyricsRows")
        expectEqual(lyricsRows.contains("if settings.touchBarSecondaryLine.showsSecondaryRow {")
                        && lyricsRows.contains("L10n.t(\"由副行决定\")"), true,
                    "触控栏: 副行开着时「字号」那一行显示「由副行决定」")
        let secondaryAt = lyricsRows.range(of: "title: L10n.t(\"副行\")")?.lowerBound
        let sizeAt = lyricsRows.range(of: "title: L10n.t(\"字号\")")?.lowerBound
        let alignAt = lyricsRows.range(of: "title: L10n.t(\"对齐方式\")")?.lowerBound
        expectEqual(secondaryAt != nil && sizeAt != nil && alignAt != nil && secondaryAt! < sizeAt! && sizeAt! < alignAt!, true,
                    "触控栏: 「歌词」组按 副行 → 字号 → 对齐方式 排")
        // 歌词那一格填满剩下的宽度,不给固定的期望宽度:给了的话放不下时系统先藏封面和三键,
        // 「显示封面」「显示播放控制」拨了也没反应。
        expectEqual(controller.contains("lyricsContainer.setContentHuggingPriority(.init(1), for: .horizontal)"), true,
                    "触控栏: 歌词那一格横向最不抗拉伸、填满剩下的宽度")
        for name in ["lyricsContainer", "lyricsView", "secondaryView"] {
            expectEqual(controller.contains("\(name).widthAnchor.constraint(equalToConstant:"), false,
                        "触控栏: 歌词那一格(\(name))没有固定的期望宽度")
        }
        // 预览排在这一段最前面,而且跟本体用同一份规格和同一份显示起点 —— 两边各拼一份就会画得不一样。
        expectEqual(touchBarBranch?.contains("TouchBarPreviewStage()"), true, "触控栏: .touchBar 那一支放了预览")
        let preview = code(appDir.appendingPathComponent("UI/TouchBarPreviewStage.swift")) ?? ""
        for (name, text) in [("预览", preview), ("控制器", controller)] {
            expectEqual(text.contains("TouchBarLyricsCell.spec(for:") && text.contains("TouchBarDisplayStart()"), true,
                        "触控栏: \(name)用 TouchBarLyricsCell.spec 拼规格、用 TouchBarDisplayStart 记显示起点")
            expectEqual(text.contains("TouchBarLyricsCell.content(p, secondary:")
                            && text.contains("TouchBarLyricsCell.dwellMs(p, secondary:")
                            && text.contains("TouchBarLyricsCell.secondarySpec(")
                            && text.contains("TouchBarLyricsCell.playbackChanges(p)"), true,
                        "触控栏: \(name)显示哪一档、时长、副行规格、订哪些播放状态都走 TouchBarLyricsCell 那一份")
            expectEqual(text.contains("TouchBarLyricsStyle.twoRowMainTop")
                            && text.contains("TouchBarLyricsStyle.twoRowSecondaryTop"), true,
                        "触控栏: \(name)两行的落点读 TouchBarLyricsStyle")
            expectEqual(text.contains("TouchBarSlot.order("), true, "触控栏: \(name)从左到右的排法走 TouchBarSlot.order")
            expectEqual(text.contains("TouchBarPrivateAPI.supportsHidingControlStrip"), true,
                        "触控栏: \(name)只在系统入口在时才当隐藏功能栏算")
        }
        // 「显示封面」「显示播放控制」开着时那一块各挂一个位置下拉,两项各管各的。
        let layoutRows = structBody("TouchBarLayoutRows")
        expectEqual(layoutRows.contains("if settings.touchBarShowsArtwork {")
                        && layoutRows.contains("if settings.touchBarShowsControls {")
                        && layoutRows.components(separatedBy: "TouchBarSidePicker(selection:").count - 1 == 2
                        && layoutRows.contains(".help(L10n.t(\"封面位置\"))")
                        && layoutRows.contains(".help(L10n.t(\"播放控制位置\"))"),
                    true, "触控栏: 封面、三键开着时那一块各挂一个左 / 右下拉(「封面位置」「播放控制位置」)")
        // 「系统功能栏」那一行(17 章决策 37):右边那排系统按键 App 改不了,按钮带锚点直接弹出系统设置里的「触控栏设置…」。
        // 锚点丢了不报错,只表现成按下去停在「键盘」页、还得自己找。
        expectEqual(layoutRows.contains("SettingsRow(icon: \"keyboard\", title: L10n.t(\"系统功能栏\"),")
                        && layoutRows.contains("x-apple.systempreferences:com.apple.Keyboard-Settings.extension?TouchBarSettings"),
                    true, "触控栏: 「布局」里有一行直接打开系统设置的「触控栏设置…」")
        // 三键旁边那颗设置键:分段控件的第四格,按下去打开设置、翻到「触控栏」这一段。
        expectEqual(controller.contains("case 3: openTouchBarSettings()")
                        && controller.contains("UserDefaults.standard.set(SettingsSearchCatalog.touchBarSectionValue,")
                        && controller.contains("AppActions.shared.openSettings?()"), true,
                    "触控栏: 三键旁边的设置键打开设置里「触控栏」那一段")
        // 封面那一格按下去打开歌词窗口,跟灵动岛的封面键、菜单栏菜单同一个入口。
        expectEqual(controller.contains("action: #selector(artworkTapped)")
                        && sourceHas(controller, "@objc private func artworkTapped() {\n        AppActions.shared.openLyricsWindow?()\n    }")
                        && controller.contains("item.view = artworkButton"), true,
                    "触控栏: 封面那一格按下去打开歌词窗口")
        // 预览:整条按真实大小画(1:1),比内容列宽出来的部分左右滑动看,不再整体缩小。
        expectEqual(preview.contains("return ScrollView(.horizontal) {") && !preview.contains(".scaleEffect("), true,
                    "触控栏: 预览整条按真实大小画、左右滑动看")
        // 预览上的可点区域(17 章决策 38):歌词那一格开「歌词」,封面、三键、收起键、功能栏开「布局」,浮层同工具栏那一份;
        // 那一排用 padding 摆位置(浮层认布局 frame、不认 offset)。漏了不报错,只表现成点了没反应、或浮层弹在别处。
        expectEqual(preview.contains("case lyrics, artwork, controls, more, collapse, controlStrip")
                        && preview.contains("var group: TouchBarSettingsGroup { self == .lyrics ? .lyrics : .layout }")
                        && preview.contains("spot.group.popoverContent()")
                        && preview.contains(".environment(\\.colorScheme, colorScheme)")
                        && preview.contains(".padding(.leading, escapeSlot + CGFloat(TouchBarLyricsStyle.firstItemX))")
                        && !preview.contains(".offset(x: CGFloat(TouchBarLyricsStyle.firstItemX))"), true,
                    "触控栏预览: 点歌词开「歌词」,点封面 / 三键 / 收起键 / 功能栏开「布局」")
        for spot in ["lyrics", "artwork", "controls", "more", "collapse", "controlStrip"] {
            expectEqual(preview.contains(".overlay { hotspot(.\(spot)) }"), true, "触控栏预览: \(spot) 那一块挂了可点区域")
        }
        // 预览按这台 Mac 的触控栏画(17 章决策 39):判据跟本体放不放 esc 键是同一条;第一代时整条加宽、左端先画 esc 键,
        // 收起键和后面那一排往右挪 Esc 那一格,歌词那一格的宽按第一代算。没有触控栏的 Mac 上判据恒为 false,照第二代画。
        // 漏一处不报错,只表现成第一代上预览跟真机对不上(左端少一颗 esc,或者歌词那一格宽了 / 窄了)。
        let escapePredicate = "hasEscapeKey && TouchBarPrivateAPI.supportsHidingControlStrip"
        expectEqual(preview.contains("@ObservedObject private var touchBar = TouchBarAvailability.shared")
                        && preview.contains("let escapeKey = touchBar." + escapePredicate)
                        && controller.contains("let escapeKey = " + escapePredicate), true,
                    "触控栏预览: 第一代的判据跟本体放 esc 键那一条一样")
        expectEqual(preview.contains("hidesControlStrip: hidesStrip, escapeKey: escapeKey,")
                        && sourceHas(preview, "if escapeKey {\n                escapeKeyCap")
                        && preview.contains(".offset(x: escapeSlot + TouchBarLyricsCell.closeBoxCenterX")
                        && sourceHas(preview, ".overlay { hotspot(.collapse) }\n                .padding(.leading, escapeSlot)")
                        && preview.contains(".frame(width: Self.barWidth(escapeKey: escapeKey), height: Self.barSize.height")
                        && preview.contains("CGFloat(TouchBarLyricsStyle.fullWidthModalWidthWithEscapeKey - TouchBarLyricsStyle.fullWidthModalWidth)"),
                    true, "触控栏预览: 第一代整条加宽、左端先画 esc 键、收起键和后面那一排往右挪、歌词宽按第一代算")
        let toolbarSource = code(appDir.appendingPathComponent("UI/TouchBarSettingsRows.swift")) ?? ""
        expectEqual(toolbarSource.contains("group.popoverContent()"), true, "触控栏: 工具栏和预览弹同一份浮层")
        // 对齐方式:「自动」按每一行的对唱声部落成方向(同灵动岛),本体和预览都把设置传进规格。
        let cellSource = code(appDir.appendingPathComponent("TouchBar/TouchBarLyricsCell.swift")) ?? ""
        expectEqual(cellSource.contains("switch alignment.resolved(duetSide: duetSide) {"), true,
                    "触控栏: 对齐方式按这一行的声部落成方向")
        for (name, text) in [("预览", preview), ("控制器", controller)] {
            expectEqual(text.contains("alignment: settings.touchBarLyricsAlignment"), true,
                        "触控栏: \(name)把对齐方式传进规格")
        }
        // 广告期间封面那一格贴喇叭:全 App 的封面位在广告期间都让位给同一枚 megaphone.fill(05 章「广告态」⑦),
        // 本体和预览贴同一张图、走同一个判断。
        let cell = code(appDir.appendingPathComponent("TouchBar/TouchBarLyricsCell.swift")) ?? ""
        expectEqual(cell.contains("static let adBreakArtwork = symbolTile(\"megaphone.fill\")")
                        && cell.contains("if content == .adBreak { return adBreakArtwork }"), true,
                    "触控栏广告态: 封面那一格在广告期间换成同一枚喇叭")
        for (name, text) in [("预览", preview), ("控制器", controller)] {
            expectEqual(text.contains("TouchBarLyricsCell.artworkTile(p, content: content)"), true,
                        "触控栏广告态: \(name)封面那一格走 TouchBarLyricsCell.artworkTile")
        }
        // 按宽度断句:触控栏读断好的那一份,控制器报这一格的宽,LineLayoutBudgets 按触控栏的字体报预算,
        // LocalPlaybackSource 逐拍算这个面;设置里那两项的说明也写上触控栏。漏一处不报错,只表现成触控栏不断句。
        expectEqual(cellSource.contains("let lyrics = p.touchBarLyrics") && !cellSource.contains("p.compactLine")
                        && !cellSource.contains("p.currentLine,"), true,
                    "触控栏断句: 显示哪一档读触控栏自己那一份断句")
        for (name, text) in [("预览", preview), ("控制器", controller)] {
            expectEqual(text.contains("p.touchBarLyrics.nextText") && text.contains("p.touchBarLyrics.nextSide"), true,
                        "触控栏断句: \(name)副行的「下一句」也读断好的那一份")
        }
        expectEqual(controller.contains("LineLayoutBudgets.shared.setTouchBarWidth(width)")
                        && controller.contains("let width = measured > 0 && measuredUnderEstimate == estimate ? measured : CGFloat(estimate)")
                        && controller.contains("LineLayoutBudgets.shared.setTouchBarWidth(0)"), true,
                    "触控栏断句: 控制器报这一格量到的宽(量的时候是这种排法才算),没启用时报 0")
        // 收起时这一格从窗口里拿下来,frame 停在上次摆着时的宽:收着时改了排法先报估算宽,摆上去(看得见、在窗口里)
        // 才认量到的。漏了不报错,只表现成收着时拨了「显示封面」之类,下次展开头一下按旧宽度断句。
        expectEqual(controller.contains("if measured > 0, bar.isVisible, lyricsContainer.window != nil { measuredUnderEstimate = estimate }")
                        && controller.contains("if !bar.isVisible { reportLyricsWidth() }"), true,
                    "触控栏断句: 收着时改了排法先报估算宽,摆上去才认量到的")
        let budgets = code(appDir.appendingPathComponent("UI/LineLayoutBudgets.swift")) ?? ""
        expectEqual(budgets.contains("report(.touchBar, LineLayoutBudget(")
                        && budgets.contains("TouchBarLyricsCell.mainFont(fontSize: fontSize, secondary: kind)")
                        && budgets.contains("setLineLayoutBudget(nil, for: .touchBar)"), true,
                    "触控栏断句: 按触控栏的字体报预算,宽为 0 时撤掉")
        expectEqual(budgets.components(separatedBy: "mergeRule: .whenFits").count - 1, 1,
                    "触控栏断句: 只有触控栏放得下就并,别的面照旧只并短句")
        let coreDir = sourcesRoot.appendingPathComponent("LyrimuseCore")
        let local = code(coreDir.appendingPathComponent("Local/LocalPlaybackSource.swift")) ?? ""
        expectEqual(local.contains("syncEngine.surfaceTick(.touchBar, atMs: pos, trackEndMs: currentDurationMs)")
                        && local.contains("if touchBar != touchBarLyrics { touchBarLyrics = touchBar }"), true,
                    "触控栏断句: 逐拍算触控栏这个面并发布")
        let settingsSource = code(appDir.appendingPathComponent("SettingsView.swift")) ?? ""
        expectEqual(settingsSource.contains("SettingsCardHeader(title: L10n.t(\"断句\"), subtitle: L10n.t(\"仅用于悬浮歌词、灵动岛、菜单栏和触控栏\"))"), true,
                    "触控栏断句: 「长句拆分」「短句合并」所在的「断句」卡头写明适用范围含触控栏")
        // 隐藏功能栏时系统不给 ✕:自己那颗收起键要接上「收起」,展开着的时候切换要按新的方式重新展开。
        expectEqual(controller.contains("TouchBarPrivateAPI.minimizeSystemModal(bar)"), true,
                    "触控栏: 自己那颗收起键收回成功能栏图标")
        // 本 App 在前台时系统模态条也不画 ✕(「前台时给 ✕」那个开关实测传什么都一样):排法跟着激活 / 失活变,前台时
        // 左端放自己那颗;那个开关明确传 false。漏了不报错,只表现成开着设置 / 歌词窗口时展开条收不起来。
        expectEqual(controller.contains("TouchBarSlot.showsCollapseKey(")
                        && controller.contains("fullWidth: fullWidth, appIsActive: active,")
                        && controller.contains("center.publisher(for: NSApplication.didBecomeActiveNotification)")
                        && controller.contains("center.publisher(for: NSApplication.didResignActiveNotification)"), true,
                    "触控栏: 本 App 在前台时左端放自己的收起键,跟着激活 / 失活变")
        expectEqual(controller.contains("TouchBarPrivateAPI.showCloseBoxWhenFrontmost(false)")
                        && !controller.contains("showCloseBoxWhenFrontmost(true)"), true,
                    "触控栏: 「前台时给 ✕」明确传 false,不跟自己那颗收起键同时出现")
        for (name, text) in [("预览", preview), ("控制器", controller)] {
            expectEqual(text.contains("lineIndex: TouchBarLyricsCell.displayedLineIndex(p, secondary: secondary)")
                            && !text.contains("p.currentLineIndex"), true,
                        "触控栏: \(name)记显示起点认主行显示的那一句的下标")
        }
        expectEqual(controller.contains("hidingControlStrip: AppSettings.shared.touchBarHidesControlStrip")
                        && controller.contains("representIfVisible(hidingControlStrip:"), true,
                    "触控栏: 展开时按「展开时隐藏功能栏」选方式,展开着切换时重新展开")
        let search = code(appDir.appendingPathComponent("Settings/SettingsSearch.swift")) ?? ""
        expectEqual(search.contains("TouchBarAvailability.shared.isPresent")
                        && search.contains("SettingsSearchCatalog.touchBarSectionValue")
                        && search.contains("SettingsSearchCatalog.touchBarToggleTitleKey"), true,
                    "触控栏: 没有触控栏时设置搜索只留总开关那一条")
        expectEqual(controller.contains("on && TouchBarAvailability.shared.isPresent")
                        && controller.contains("availability.$isPresent"), true,
                    "触控栏: 控制器只在有触控栏时启用,并跟着触控栏出现 / 消失启停")
    }

    // 菜单栏左键面板第二排那一格「触控栏歌词」(06 章决策 37):只在有触控栏时出现,短按翻总开关,长按 / 右键翻出它自己的
    // 快捷设置,底栏「全部设置…」翻到「触控栏」这一段。漏一处都不报错:要么没有触控栏的 Mac 上冒出一格拨了没用的开关,
    // 要么长按退化成普通按一下、翻出来的那页少了旋钮。
    do {
        let panel = code(appDir.appendingPathComponent("MenuBar/MenuBarPanel.swift")) ?? ""
        let quick = code(appDir.appendingPathComponent("MenuBar/MenuBarPanelQuickSettings.swift")) ?? ""
        let settingsView = code(appDir.appendingPathComponent("SettingsView.swift")) ?? ""
        expectEqual(panel.contains("if playback.touchBarPresent {")
                        && panel.contains("TouchBarAvailability.shared.$isPresent")
                        && panel.contains("if !present, quickTarget == .touchBar { setQuickTarget(nil) }"), true,
                    "触控栏面板: 那一格只在有触控栏时出现,跟着触控栏出现 / 消失,没了时快捷设置退回网格")
        expectEqual(panel.contains("quick: .touchBar")
                        && panel.contains("case .touchBar: return toggleTouchBarAction")
                        && panel.contains("{ AppSettings.shared.showLyricsInTouchBar.toggle() }"), true,
                    "触控栏面板: 短按和快捷设置头部那颗开关走同一条闭包,翻的是同一个总开关")
        expectEqual(panel.contains("symbol: PanelQuickTarget.touchBar.symbolName"), true,
                    "触控栏面板: 格子和它翻过来的背面读同一个符号")
        let menu = code(appDir.appendingPathComponent("MenuBar/MenuBarStatusMenu.swift")) ?? ""
        expectEqual(quick.contains("case .touchBar: return SurfaceGlyph.touchBar.rawValue")
                        && settingsView.contains("icon: SurfaceGlyph.touchBar.rawValue")
                        && menu.contains("symbol: SurfaceGlyph.touchBar.rawValue"), true,
                    "触控栏面板: 那一格、设置页开关卡、右键菜单那一项都用自画的触控栏图标")
        expectEqual(quick.contains("case .touchBar: return SettingsSearchCatalog.touchBarSectionValue"), true,
                    "触控栏面板: 「全部设置…」翻到「触控栏」那一段,取值读 Core 常量")
        for needle in ["toggleRow(L10n.t(\"显示封面\"), isOn: $settings.touchBarShowsArtwork)",
                       "toggleRow(L10n.t(\"显示播放控制\"), isOn: $settings.touchBarShowsControls)",
                       "alignmentRow(selection: $settings.touchBarLyricsAlignment,",
                       "secondaryLineRow(selection: $settings.touchBarSecondaryLine)",
                       "range: TouchBarLyricsStyle.fontSizeRange",
                       "if settings.touchBarSecondaryLine.showsSecondaryRow {"] {
            expectEqual(quick.contains(needle), true, "触控栏面板: 快捷设置里有 \(needle)")
        }
    }

    // 1st generation 触控栏的 esc 键(17 章决策 36):判据只在有触控栏时问;排法里带上它,左端那一格用
    // escapeKeyReplacementItemIdentifier 放进去、只在收得起来时放、放了就带上自己的收起键;按下去先看辅助功能权限再发 Esc。
    // 漏一处都不报错:要么 2nd generation 上也冒出一颗 esc,要么 1st generation 上照旧没有 Esc,要么没授权时按了没反应。
    do {
        let controller = code(appDir.appendingPathComponent("TouchBar/TouchBarLyricsController.swift")) ?? ""
        let availability = code(appDir.appendingPathComponent("TouchBar/TouchBarAvailability.swift")) ?? ""
        let escape = code(appDir.appendingPathComponent("TouchBar/TouchBarEscapeKey.swift")) ?? ""
        expectEqual(availability.contains("let escapeKey = present && (TouchBarPrivateAPI.touchBarHasEscapeKey() ?? false)"),
                    true, "触控栏 esc 键: 只在有触控栏时问左端是不是虚拟 Esc 键")
        expectEqual(controller.contains("availability.$hasEscapeKey")
                        && controller.contains("let escapeKey = hasEscapeKey && TouchBarPrivateAPI.supportsHidingControlStrip")
                        && controller.contains("replacesEscapeKey: escapeKey,")
                        && controller.contains("bar.escapeKeyReplacementItemIdentifier = new.escapeKey ? Item.escape : nil")
                        && sourceHas(controller, "case Item.escape:\n            item.view = escapeButton"), true,
                    "触控栏 esc 键: 1st generation 上放进左端 Esc 那一格,收得起来时才放,放了就带上自己的收起键")
        expectEqual(controller.contains("escapeKey: escapeKey)"), true, "触控栏 esc 键: 估算宽带上 Esc 那一格")
        if let guardAt = escape.range(of: "guard AccessibilitySkipPress.isTrusted else {"),
           let postAt = escape.range(of: ".post(tap: .cghidEventTap)") {
            expectEqual(guardAt.lowerBound < postAt.lowerBound
                            && escape.contains("AccessibilityPermission.shared.handleAction()"), true,
                        "触控栏 esc 键: 先看辅助功能权限,没授权就去要、这一下不发")
        } else {
            expectEqual(false, true, "触控栏 esc 键: 按下去先看权限再发 Esc")
        }
        expectEqual(escape.contains("private static let keyCode: CGKeyCode = 0x35")
                        && escape.contains("for keyDown in [true, false] {")
                        && escape.contains("TouchBarLyricsStyle.escapeKeyWidth"), true,
                    "触控栏 esc 键: 发 kVK_Escape 的按下 + 抬起,键宽同系统那颗")
    }

    // 快捷键「展开/收起触控栏歌词」(17 章决策 40):登记进撞键检查和标题表,按下去交给控制器、做了哪一件都回声;控制器照判定做,
    // 收起走 ✕ 那个入口;设置页那一行和设置搜索那一条只在有触控栏时出现;灵动岛提示条画得出自画的触控栏图标。漏一处都不报错:
    // 要么撞键查不出、提示里露出内部标识符,要么按下去翻成了总开关,要么没有触控栏的 Mac 上冒出一行录了没用的键。
    do {
        let controller = code(appDir.appendingPathComponent("TouchBar/TouchBarLyricsController.swift")) ?? ""
        let settingsView = code(appDir.appendingPathComponent("SettingsView.swift")) ?? ""
        let search = code(appDir.appendingPathComponent("Settings/SettingsSearch.swift")) ?? ""
        let notchHint = code(appDir.appendingPathComponent("UI/NotchTransientCenter.swift")) ?? ""
        expectEqual(LyrimuseAction.toggleTouchBarLyricsHotkey.titleKey == SettingsSearchCatalog.touchBarHotkeyTitleKey
                        && LyrimuseAction.toggleTouchBarLyricsHotkey.iconName == "lyrimuse.touchbar", true,
                    "触控栏快捷键: 标题跟设置搜索那一条同一份,图标是自画的触控栏")
        let actions = code(appDir.appendingPathComponent("Settings/LyrimuseActionRunner.swift")) ?? ""
        expectEqual(actions.contains("switch TouchBarLyricsController.shared.toggleFromHotkey() {")
                        && actions.contains("case .noTouchBar: text = L10n.t(\"未检测到触控栏\")")
                        && actions.contains("case .turnOn, .expand: text = L10n.t(\"已展开触控栏歌词\")")
                        && actions.contains("flashHint(icon: SurfaceGlyph.touchBar.rawValue, text: text)"), true,
                    "触控栏快捷键: 按下去交给控制器,做了哪一件都回声")
        expectEqual(controller.contains("let action = TouchBarHotkeyAction.resolve(")
                        && controller.contains("touchBarPresent: TouchBarAvailability.shared.isPresent, entryPointsAvailable: TouchBarPrivateAPI.isAvailable,")
                        && controller.contains("switchOn: settings.showLyricsInTouchBar, visible: bar.isVisible)"), true,
                    "触控栏快捷键: 控制器按此刻有没有触控栏、有没有系统入口、开关和看不看得见判定")
        expectEqual(sourceHas(controller, "case .turnOn:\n            settings.showLyricsInTouchBar = true")
                        && sourceHas(controller, "case .expand:\n            presentLyrics(hidingControlStrip: settings.touchBarHidesControlStrip)")
                        && sourceHas(controller, "case .collapse:\n            collapseBar()\n        }")
                        && sourceHas(controller, "private func collapseBar() {\n        if TouchBarPrivateAPI.supportsHidingControlStrip {\n"
                                               + "            TouchBarPrivateAPI.minimizeSystemModal(bar)"), true,
                    "触控栏快捷键: 关着就打开开关(订阅当场展开),收着就展开,看得见就照 ✕ 收起")
        expectEqual(settingsView.contains("return actions.filter { $0 != .toggleTouchBarLyricsHotkey || touchBar.isPresent }"), true,
                    "触控栏快捷键: 设置页那一行只在有触控栏时出现")
        expectEqual(search.contains("$0.entry.titleKey != SettingsSearchCatalog.touchBarHotkeyTitleKey)"), true,
                    "触控栏快捷键: 没有触控栏时设置搜索不收这一条")
        expectEqual(SettingsSearchCatalog.entries.filter { $0.titleKey == SettingsSearchCatalog.touchBarHotkeyTitleKey }
                        .map(\.destination), [.tab("shortcuts")], "触控栏快捷键: 设置搜索里有这一条,落在「快捷键」页")
        expectEqual(notchHint.contains("SymbolImage(name: banner.icon, size: 12, weight: .semibold)")
                        && !notchHint.contains("Image(systemName: banner.icon)"), true,
                    "触控栏快捷键: 灵动岛提示条的图标位画得出自画的触控栏图标")
    }

    // 占满整条的展开收起后把功能栏图标重新露一次面(17 章决策 42):展开时按实际用的方式记下,收起时只在占满整条
    // (或展开期间开始放歌、换了曲目,决策 46)时做,先藏再露。漏了不报错,只表现成放歌时收起之后功能栏那一格是系统的「正在播放」、Lyrimuse 图标点不回来。
    do {
        let controller = code(appDir.appendingPathComponent("TouchBar/TouchBarLyricsController.swift")) ?? ""
        let api = code(appDir.appendingPathComponent("TouchBar/TouchBarPrivateAPI.swift")) ?? ""
        expectEqual(sourceHas(controller, "presentedFullWidth = hidingControlStrip && TouchBarPrivateAPI.supportsHidingControlStrip\n"
                                        + "        TouchBarPrivateAPI.presentSystemModal("), true,
                    "功能栏图标: 展开时按实际用的方式记下是不是占满整条")
        expectEqual(sourceHas(controller, "guard visible else {\n            showLyricsPage(reason: \"collapsed\")\n"
                                        + "            if presentedFullWidth || trayDisplaced {\n"
                                        + "                presentedFullWidth = false\n"
                                        + "                trayDisplaced = false\n"
                                        + "                TouchBarPrivateAPI.reassertInControlStrip(trayItem)"), true,
                    "功能栏图标: 收起时只在占满整条展开过、或展开期间开始放歌 / 换了曲目时重新露面")
        // 收着时开始放歌、换曲目,系统「正在播放」随后占掉那一格(决策 46):在不在放歌、歌名、歌手一变就排计时,到点收着就露面,
        // 展开着就记下等收起。漏了不报错,只表现成放歌后功能栏里没有 Lyrimuse 图标。
        expectEqual(controller.contains("Publishers.CombineLatest3(p.$isPlayingNow, p.$title, p.$artist)")
                        && controller.contains(".sink { [weak self] _ in self?.scheduleTrayReassert() }")
                        && controller.contains("try? await Task.sleep(for: .milliseconds(Self.trayReassertDelayMs))")
                        && sourceHas(controller, "if self.bar.isVisible {\n                self.trayDisplaced = true\n            } else {\n"
                                               + "                TouchBarPrivateAPI.reassertInControlStrip(self.trayItem)"), true,
                    "功能栏图标: 开始放歌、换曲目后重新露面(收着当场、展开着等收起)")
        if api.contains("static func reassertInControlStrip(") {
            expectEqual(sourceHas(sourceBody("static func reassertInControlStrip(", in: api),
                                  "e.setPresence(identifier, false)\n        e.setPresence(identifier, true)"), true,
                        "功能栏图标: 重新露面是先藏再露")
        } else {
            expectEqual(false, true, "功能栏图标: TouchBarPrivateAPI 里有 reassertInControlStrip")
        }
    }
}
