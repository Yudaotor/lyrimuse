import AppKit
import Foundation
import LyrimuseCore

// 触控栏歌词:那一格显示哪一档(Core `TouchBarLyricsContent`)、字号区间(`TouchBarLyricsStyle`)、图层行的
// 时间基准指纹(`LyricsTimingEpoch`)、副行开着时两行显示什么和怎么摆(两行的墨迹照图层行的画法量),加几条接线契约 ——
// 展开态从左到右排哪几项(`TouchBarSlot.order`)、隐藏功能栏时的宽度、广告期间封面那一格贴喇叭、按触控栏这一格的宽度断句;
// 私有入口只在 `TouchBar/TouchBarPrivateAPI.swift` 一个文件里、App 启动时起控制器、开关和十项设置在「歌词显示」页
// 自己那一段(「触控栏」)里、控制器都接上了;这台 Mac 有没有触控栏的判据(`TouchBarPresence`)和它在设置页 / 搜索 /
// 控制器三处的接线;菜单栏左键面板第二排那一格「触控栏歌词」。
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
            + "[80000,2000](80000,2000,0)end\n"
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
        let restore = rows.range(of: "static func restoreDefaults() {")
            .map { String(rows[$0.upperBound...].prefix { $0 != "}" }) } ?? ""
        expectEqual(touchBarBranch?.contains("TouchBarEditorToolbar()") == true
                        && touchBarBranch?.contains("TouchBarAllSettingsDrawer()") == true, true,
                    "触控栏: .touchBar 那一支装着工具栏和「全部设置」抽屉")
        for key in ["touchBarLyricsKaraoke", "touchBarLyricsFollowsCover", "touchBarLyricsFontSize",
                    "touchBarShowsArtwork", "touchBarShowsControls", "touchBarSecondaryLine",
                    "touchBarArtworkSide", "touchBarControlsSide", "touchBarHidesControlStrip",
                    "touchBarLyricsAlignment"] {
            expectEqual(rowViews.contains("settings.\(key)"), true, "触控栏: \(key) 的设置行在三组行视图里")
            expectEqual(controller.contains("settings.$\(key)"), true, "触控栏: 控制器订阅了 \(key)")
            expectEqual(restore.contains("settings.\(key) = "), true, "触控栏: 「恢复默认」管到 \(key)")
        }
        expectEqual(restore.contains("showLyricsInTouchBar"), false, "触控栏: 「恢复默认」不碰总开关")
        // 主行未唱的部分、副行在黑底上打折都走 dimmedOnBlack,不直接打透明度(跟随封面时那样会发糊)。
        let dimmedColorCell = code(appDir.appendingPathComponent("TouchBar/TouchBarLyricsCell.swift")) ?? ""
        expectEqual(dimmedColorCell.contains("dimmedOnBlack(inputs.color, opacity: unsungAlpha)")
                        && dimmedColorCell.contains("dimmedOnBlack(inputs.color, opacity: CGFloat(TouchBarLyricsStyle.secondaryRowOpacity(for: kind)))")
                        && !dimmedColorCell.contains("withAlphaComponent(unsungAlpha)")
                        && !dimmedColorCell.contains("withAlphaComponent(CGFloat(TouchBarLyricsStyle.secondaryRowOpacity"), true,
                    "触控栏配色: 未唱的部分、副行打折走 dimmedOnBlack")

        // 没有触控栏时:那一段照样在、点进去只有说明卡,搜索只留总开关那一条,控制器不启用。漏一处都不报错,只表现成
        // 没有触控栏的 Mac 上冒出几项拨了没用的设置,或者白调私有接口。
        expectEqual(touchBarBranch?.contains("if touchBar.isPresent {"), true,
                    "触控栏: .touchBar 那一支按有没有触控栏分两种内容")
        expectEqual(touchBarBranch?.contains("L10n.t(\"这台 Mac 没有触控栏\")"), true,
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
        // 「显示封面」「显示播放控制」开着时下面各挂一行位置(从属行),两项各管各的。
        let layoutRows = structBody("TouchBarLayoutRows")
        expectEqual(layoutRows.contains("if settings.touchBarShowsArtwork {")
                        && layoutRows.contains("if settings.touchBarShowsControls {")
                        && layoutRows.components(separatedBy: "TouchBarSidePicker(selection:").count - 1 == 2
                        && layoutRows.contains("SettingsSubRow(title: L10n.t(\"封面位置\"))")
                        && layoutRows.contains("SettingsSubRow(title: L10n.t(\"播放控制位置\"))"),
                    true, "触控栏: 封面、三键开着时下面各有一行「封面位置」「播放控制位置」")
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
                        && controller.contains("@objc private func artworkTapped() {\n        AppActions.shared.openLyricsWindow?()\n    }")
                        && controller.contains("item.view = artworkButton"), true,
                    "触控栏: 封面那一格按下去打开歌词窗口")
        // 预览:整条按真实大小画(1:1),比内容列宽出来的部分左右滑动看,不再整体缩小。
        expectEqual(preview.contains("return ScrollView(.horizontal) {") && !preview.contains(".scaleEffect("), true,
                    "触控栏: 预览整条按真实大小画、左右滑动看")
        // 预览上的可点区域(17 章决策 38):歌词那一格开「歌词」,封面、三键、收起键、功能栏开「布局」,浮层同工具栏那一份;
        // 那一排用 padding 摆位置(浮层认布局 frame、不认 offset)。漏了不报错,只表现成点了没反应、或浮层弹在别处。
        expectEqual(preview.contains("case lyrics, artwork, controls, collapse, controlStrip")
                        && preview.contains("var group: TouchBarSettingsGroup { self == .lyrics ? .lyrics : .layout }")
                        && preview.contains("spot.group.popoverContent()")
                        && preview.contains(".environment(\\.colorScheme, colorScheme)")
                        && preview.contains(".padding(.leading, escapeSlot + CGFloat(TouchBarLyricsStyle.firstItemX))")
                        && !preview.contains(".offset(x: CGFloat(TouchBarLyricsStyle.firstItemX))"), true,
                    "触控栏预览: 点歌词开「歌词」,点封面 / 三键 / 收起键 / 功能栏开「布局」")
        for spot in ["lyrics", "artwork", "controls", "collapse", "controlStrip"] {
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
        expectEqual(preview.contains("hidesControlStrip: hidesStrip, escapeKey: escapeKey))")
                        && preview.contains("if escapeKey {\n                escapeKeyCap")
                        && preview.contains(".offset(x: escapeSlot + TouchBarLyricsCell.closeBoxCenterX")
                        && preview.contains(".overlay { hotspot(.collapse) }\n                .padding(.leading, escapeSlot)")
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
        expectEqual(settingsSource.contains("悬浮歌词、灵动岛、菜单栏和触控栏上放不下一行的句子")
                        && settingsSource.contains("悬浮歌词、灵动岛、菜单栏和触控栏上连续几句很短的歌词"), true,
                    "触控栏断句: 「长句拆开」「短句合并」的说明写上触控栏")
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
                        && controller.contains("case Item.escape:\n            item.view = escapeButton"), true,
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
}
