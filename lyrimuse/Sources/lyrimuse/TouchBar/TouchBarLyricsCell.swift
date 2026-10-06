import AppKit
import Combine
import LyrimuseCore

/// 触控栏歌词那一格怎么画:尺寸、颜色、字体,以及交给图层行(`OverlayLyricScrollView`)的规格。触控栏本体
/// (`TouchBarLyricsController`)和设置页那块预览(`TouchBarPreviewStage`)共用这一份,两边画出来是同一个样子。
/// 输入一律由调用方传进来(`Inputs`),这里不读设置;播放状态只在 `content` / `dwellMs` 这两个取值入口里读,
/// 本体在攒拍之后调,预览在自己那份快照里调。
@MainActor
enum TouchBarLyricsCell {
    /// 触控栏的高(点)。
    static let barHeight: CGFloat = 30
    /// 歌词的字重;字号听设置(`TouchBarLyricsStyle`),行高在 30pt 里垂直居中(`OverlayLyricScrollView` 按字体的
    /// 上下伸量)。
    static let fontWeight = NSFont.Weight.medium
    /// 副行开着时主行的字体:字号由触控栏的高定(`TouchBarLyricsStyle.twoRowMainFontSize`),不听「字号」。
    static let twoRowMainFont = NSFont.systemFont(ofSize: CGFloat(TouchBarLyricsStyle.twoRowMainFontSize),
                                                  weight: fontWeight)
    /// 副行的字体:11pt,比主行细一档(同灵动岛副行)。
    static let secondaryFont = NSFont.systemFont(ofSize: CGFloat(TouchBarLyricsStyle.twoRowSecondaryFontSize),
                                                 weight: .regular)
    /// 歌词句的颜色:白色,开了「跟随封面」用封面主色(`coverAccent(hex:)`)。还没唱到的部分打 `unsungAlpha` 这个折,
    /// 打折走 `dimmedOnBlack`(不暗于白字打同一个折)。触控栏底色恒黑,不跟系统浅深色。
    static let lyricColor = NSColor.white
    static let unsungAlpha: CGFloat = 0.45
    /// 不是歌词的那几档(间奏、歌名、广告)。
    static let secondaryColor = NSColor.white.withAlphaComponent(0.6)
    static let interludeText = "•••"
    /// 放不下、还没开始滚时尾部那条渐隐带的宽。
    static let edgeFadeWidth: CGFloat = 24
    /// 歌词这一格至少这么宽;往上填满收起键、封面、三键之后剩下的宽度(系统按功能栏此刻占多宽来分)。
    /// 别给它一个固定的期望宽度:放不下时系统先藏优先级低的封面和三键,「显示封面」「显示播放控制」就拨了也没反应。
    static let lyricsMinWidth: CGFloat = 240
    /// 触控栏上相邻两项之间的间距。
    static let itemSpacing = CGFloat(TouchBarLyricsStyle.itemSpacing)
    static let artworkCornerRadius: CGFloat = 4
    /// 三键和它旁边那颗设置键,每一格的宽。
    static let controlSegmentWidth: CGFloat = 44
    /// 系统收起键(✕)的样子,实拍量的:浅灰圆钮,直径 23pt,圆心离展开条左缘 31.5pt,黑色粗体叉 11pt。隐藏功能栏时
    /// App 自己那颗收起键照它画(`collapseImage()`),设置页预览两种模式下也都照它画。
    static let closeBoxDiameter: CGFloat = 23
    static let closeBoxCenterX: CGFloat = 31.5
    static let closeBoxWhite: CGFloat = 0.78
    static let closeBoxSymbolSize: CGFloat = 11

    /// 规格的输入。
    struct Inputs {
        /// 这一档从歌词时间轴上哪一毫秒起显示(`TouchBarDisplayStart.sinceMs`)。
        var startMs: Int
        /// 主行这一句会显示多久(`dwellMs(_:secondary:)`);nil = 不知道,按固定速度。
        var dwellMs: Int?
        var isPlaying: Bool
        /// 时间基准指纹(`LyricsTimingEpoch.of`)与播放速率。
        var timingEpoch: Int
        var rate: Double
        /// 主行的字体(`mainFont(fontSize:secondary:)`)。
        var font: NSFont
        /// 歌词句的颜色(`lyricColor(followsCover:coverAccent:)`)。
        var color: NSColor
        /// 「卡拉OK效果」开没开。
        var karaoke: Bool
        /// 「对齐方式」:装得下的短句靠哪边;「自动」在这里按每一行的对唱声部落成具体方向(`side(_:duetSide:)`)。
        var alignment: LyricsRestingAlignment
    }

    /// 设置里选的对齐方式落到这一行:「自动」按这一行的对唱声部走,没有声部时靠左(`LyricsRestingAlignment.resolved`,
    /// 同灵动岛)。放不下要滚的句子一律从左起滚,对齐只管装得下的。
    static func side(_ alignment: LyricsRestingAlignment, duetSide: LyricDuet.Side?) -> LyricDuet.Side {
        switch alignment.resolved(duetSide: duetSide) {
        case .center: return .center
        case .trailing: return .trailing
        case .leading, .automatic: return .leading
        }
    }

    /// App 自己那颗收起键的图:宽 `TouchBarLyricsStyle.collapseItemWidth`、高满触控栏,圆钮落在跟系统 ✕ 一样的位置,
    /// 隐藏功能栏前后左端看起来一样。
    static func collapseImage() -> NSImage {
        let diameter = closeBoxDiameter
        let centerX = closeBoxCenterX
        let white = closeBoxWhite
        let symbolSize = closeBoxSymbolSize
        let height = barHeight
        let size = NSSize(width: CGFloat(TouchBarLyricsStyle.collapseItemWidth), height: height)
        return NSImage(size: size, flipped: false) { _ in
            let circle = NSRect(x: centerX - diameter / 2, y: (height - diameter) / 2, width: diameter, height: diameter)
            NSColor(white: white, alpha: 1).setFill()
            NSBezierPath(ovalIn: circle).fill()
            let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.black]))
            if let mark = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let markSize = mark.size
                mark.draw(in: NSRect(x: circle.midX - markSize.width / 2, y: circle.midY - markSize.height / 2,
                                     width: markSize.width, height: markSize.height))
            }
            return true
        }
    }

    static func font(size: Double) -> NSFont {
        .systemFont(ofSize: CGFloat(TouchBarLyricsStyle.clampedFontSize(size)), weight: fontWeight)
    }

    /// 主行的字体:副行开着时由触控栏的高定,关着听「字号」。
    static func mainFont(fontSize: Double, secondary: LyricSecondaryLine) -> NSFont {
        secondary.showsSecondaryRow ? twoRowMainFont : font(size: fontSize)
    }

    /// 此刻显示哪一档(Core `TouchBarLyricsContent.resolve(secondary:…)`)。参数从播放状态的哪几项取,只在这里写一遍。
    /// 歌词取触控栏自己那一份(`touchBarLyrics`):开了「长句拆开」「短句合并」时按这一格的宽度断过句
    /// (`LineBreakSurface.touchBar`,宽度见 `LineLayoutBudgets.setTouchBarWidth`),都关着时就是逐行的那一份。
    static func content(_ p: PlaybackCoordinator, secondary: LyricSecondaryLine) -> TouchBarLyricsContent {
        let lyrics = p.touchBarLyrics
        return TouchBarLyricsContent.resolve(
            secondary: secondary,
            compactLine: lyrics.compactLine, showsPlaceholder: lyrics.compactPlaceholder,
            currentLine: lyrics.line,
            inMarkedInterlude: p.rawGapWindow?.isMarked(in: p.lyricsGapMarkers) ?? false,
            title: p.title, artist: p.artist, isAdBreak: p.isCurrentTrackAdBreak)
    }

    /// 主行这一句会显示多久:单行时是提前亮出的那一句的(`compactDwellMs`,算不出来时退回这一段自己的),
    /// 副行开着时是正在唱的这一段的。
    static func dwellMs(_ p: PlaybackCoordinator, secondary: LyricSecondaryLine) -> Int? {
        let lyrics = p.touchBarLyrics
        return secondary.showsSecondaryRow ? lyrics.lineWindow?.dwellMs : (lyrics.compactDwellMs ?? lyrics.lineWindow?.dwellMs)
    }

    /// 主行这一句在触控栏这个面的段里的下标,判「换了一句、从头算显示起点」认它(`TouchBarDisplayStart`):单行时是
    /// 提前亮出的那一句的,副行开着时是正在唱的这一段的。拿正在唱的那一行的下标判的话,提前亮出的那句真正开唱时
    /// 下标往前走一格,会被当成又换了一句,按显示时长配速的滚动从头再滚一遍。
    static func displayedLineIndex(_ p: PlaybackCoordinator, secondary: LyricSecondaryLine) -> Int? {
        let lyrics = p.touchBarLyrics
        return secondary.showsSecondaryRow ? lyrics.lineIndex : lyrics.compactLineIndex
    }

    /// 歌词那一格跟着变的播放状态。本体和预览订同一批:漏一项不报错,只表现成那一项变了这一格不跟。
    static func playbackChanges(_ p: PlaybackCoordinator) -> [AnyPublisher<Void, Never>] {
        [signal(p.$touchBarLyrics), signal(p.$rawGapWindow), signal(p.$lyricsGapMarkers),
         signal(p.$currentLineIndex), signal(p.$title), signal(p.$artist), signal(p.$isCurrentTrackAdBreak),
         signal(p.$isPlayingNow), signal(p.$anchor), signal(p.$pausedPositionMs),
         signal(p.$currentLyricsOffsetMs), signal(p.$artworkImage), signal(p.$highResArtworkImage),
         signal(p.$highResArtworkThumbnail)]
    }

    static func signal<P: Publisher>(_ publisher: P) -> AnyPublisher<Void, Never> where P.Failure == Never {
        publisher.map { _ in () }.eraseToAnyPublisher()
    }

    /// 封面:高清替代优先、先取预缩小的那张(口径同菜单栏面板的小封面,这一格只有 30pt)。
    static func artwork(_ p: PlaybackCoordinator) -> NSImage? {
        p.highResArtworkThumbnail ?? p.highResArtworkImage ?? p.artworkImage
    }

    /// 没有封面时那一格画的音符;广告期间换成喇叭:全 App 的封面位在广告期间都让位给同一枚 `megaphone.fill`
    /// (清单见 05 章「广告态」⑦),播放器这时给的是广告物料的缩略图,不是「这一刻在听什么」的封面。两枚同一种画法、
    /// 只换符号(同那份清单的规矩):白色 70%,字号取格高的 0.44 倍(同灵动岛那枚广告方块的比例),画成 30×30 的图,
    /// 本体和预览贴同一张。
    static let placeholderArtwork = symbolTile("music.note")
    static let adBreakArtwork = symbolTile("megaphone.fill")

    /// 封面那一格贴哪张图:广告期间是喇叭,否则是封面,都没有时是音符。本体和预览都调这一份。
    static func artworkTile(_ p: PlaybackCoordinator, content: TouchBarLyricsContent) -> NSImage {
        if content == .adBreak { return adBreakArtwork }
        return artwork(p) ?? placeholderArtwork
    }

    private static func symbolTile(_ name: String) -> NSImage {
        let side = barHeight
        let pointSize = (side * 0.44).rounded()
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white.withAlphaComponent(0.7)]))
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return true }
            let size = symbol.size
            symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                   width: size.width, height: size.height))
            return true
        }
    }

    /// 「跟随封面」用的颜色:封面均值色先过亮度地板、再补感知亮度下限,同灵动岛纯黑 / 深色风格那一套
    /// (`PlaybackCoordinator.notchAccentColor` 去掉封面背景那一步:触控栏底色恒黑)。传高清替代的均值优先。
    static func coverAccent(hex: String?) -> NSColor? {
        guard let hex, let raw = NSColor(hexStringWithAlpha: hex) else { return nil }
        let base = LocalPlaybackSource.brightenedAccent(r: raw.redComponent, g: raw.greenComponent, b: raw.blueComponent)
        let lifted = LocalPlaybackSource.accentForDarkBackdrop(r: base.r, g: base.g, b: base.b)
        return NSColor(srgbRed: lifted.r, green: lifted.g, blue: lifted.b, alpha: 1)
    }

    static func lyricColor(followsCover: Bool, coverAccent: NSColor?) -> NSColor {
        followsCover ? (coverAccent ?? lyricColor) : lyricColor
    }

    /// 黑底上打 `opacity` 这个折的歌词色(未唱的部分、副行),不暗于白字打同一个折;算法见 Core
    /// `TouchBarLyricsStyle.dimmedOnBlack`。
    static func dimmedOnBlack(_ color: NSColor, opacity: CGFloat) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        let d = TouchBarLyricsStyle.dimmedOnBlack(r: Double(c.redComponent), g: Double(c.greenComponent),
                                                 b: Double(c.blueComponent), opacity: Double(opacity))
        return NSColor(srgbRed: d.r, green: d.g, blue: d.b, alpha: 1)
    }

    /// 这一档那一格显示的文字;`.idle` 是 nil(那一格整个藏起来)。
    static func text(for content: TouchBarLyricsContent) -> String? {
        switch content {
        case .idle: return nil
        case .lyric(let line): return line.plainText ?? ""
        case .interlude: return interludeText
        case .track(let text): return text
        case .adBreak: return L10n.t("广告中")
        }
    }

    /// 交给图层行的规格(主行);`.idle` 返回 nil。
    static func spec(for content: TouchBarLyricsContent, _ inputs: Inputs) -> OverlayScrollingLyricRow.Spec? {
        switch content {
        case .idle:
            return nil
        case .lyric(let line):
            let alignment = side(inputs.alignment, duetSide: line.side)
            if let words = line.words, !words.isEmpty {
                // 卡拉OK效果关着:照样按逐字时间轴跟唱滚动,只是不染色(已唱、未唱同一个颜色)。
                let unsung = inputs.karaoke ? dimmedOnBlack(inputs.color, opacity: unsungAlpha) : inputs.color
                return makeSpec(key: line.plainText ?? "", words: words, base: unsung, fill: inputs.color,
                                window: nil, alignment: alignment, inputs)
            }
            return pacedSpec(line.plainText ?? "", color: inputs.color, dwellMs: inputs.dwellMs,
                             alignment: alignment, inputs)
        case .interlude, .track, .adBreak:
            return pacedSpec(text(for: content) ?? "", color: secondaryColor, dwellMs: nil,
                             alignment: side(inputs.alignment, duetSide: nil), inputs)
        }
    }

    /// 副行那一行的规格:副行开着、这一刻也有字时才有;nil = 那一行留空,主行不挪位置。整行一个颜色(歌词色打
    /// `TouchBarLyricsStyle.secondaryRowOpacity` 的折,走 `dimmedOnBlack`,不做卡拉OK),放不下时跟主行同一个起点、按主行这一句的时长
    /// 配速滚;主行不是歌词句时(间奏、前奏里的歌名)按固定速度。对齐跟主行;「自动」时「下一句」按下一句自己的声部
    /// (`nextLineSide`),同灵动岛副行。
    static func secondarySpec(for content: TouchBarLyricsContent, kind: LyricSecondaryLine, nextLineText: String?,
                              nextLineSide: LyricDuet.Side?, _ inputs: Inputs) -> OverlayScrollingLyricRow.Spec? {
        guard let text = content.secondaryText(kind, nextLineText: nextLineText) else { return nil }
        var row = inputs
        row.font = secondaryFont
        let color = dimmedOnBlack(inputs.color, opacity: CGFloat(TouchBarLyricsStyle.secondaryRowOpacity(for: kind)))
        let duetSide: LyricDuet.Side?
        if kind == .nextLine {
            duetSide = nextLineSide
        } else if case .lyric(let line) = content {
            duetSide = line.side
        } else {
            duetSide = nil
        }
        var spec = pacedSpec(text, color: color, dwellMs: content.isLyric ? inputs.dwellMs : nil,
                             alignment: side(inputs.alignment, duetSide: duetSide), row)
        spec.translation = kind == .translation
        return spec
    }

    /// 整行一个颜色、从 `inputs.startMs` 起按显示时长配速滚动的一行(同悬浮歌词 `pacedLayerRow`:整行当一个词)。
    /// - Parameter dwellMs: 这一行会显示多久;nil 或短得算不出来时按固定速度。
    static func pacedSpec(_ text: String, color: NSColor, dwellMs: Int?, alignment: LyricDuet.Side,
                          _ inputs: Inputs) -> OverlayScrollingLyricRow.Spec {
        let dwell = dwellMs.flatMap { $0 > LyricDisplayWindow.minDwellMs ? $0 : nil }
        return makeSpec(key: text, words: [SyncedLyricWord(text: text, startMs: 0, durationMs: 0)],
                        base: color, fill: color, window: .init(startMs: inputs.startMs, dwellMs: dwell),
                        alignment: alignment, inputs)
    }

    private static func makeSpec(key: String, words: [SyncedLyricWord], base: NSColor, fill: NSColor,
                                 window: OverlayScrollingLyricRow.PacedWindow?, alignment: LyricDuet.Side,
                                 _ inputs: Inputs) -> OverlayScrollingLyricRow.Spec {
        OverlayScrollingLyricRow.Spec(
            lineKey: key, words: words, groups: nil,
            font: inputs.font, romaFont: inputs.font,
            baseColor: base, fillColor: fill, romaBaseColor: base, romaFillColor: fill,
            strokeColor: nil, alignment: alignment,
            paused: !inputs.isPlaying,
            pacedWindow: window,
            edgeFadeWidth: edgeFadeWidth,
            timingEpoch: inputs.timingEpoch,
            rate: inputs.rate)
    }
}

extension TouchBarSide {
    /// 「位置」那一项的选项名。
    var displayName: String {
        switch self {
        case .leading: return L10n.t("左")
        case .trailing: return L10n.t("右")
        }
    }
}
