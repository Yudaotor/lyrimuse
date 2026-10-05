import AppKit
import Combine
import LyrimuseCore
import SwiftUI

/// 「歌词显示 › 触控栏」那一段的预览:一整条触控栏(展开成系统模态条时的样子),按真实尺寸(1:1)画,比内容列宽出来的
/// 部分左右滑动看 —— 整条缩进内容列只有约 0.57 倍,字小得看不清(见 17 章决策 26)。版面照 Xcode 触控栏模拟器里实拍的样子:
/// 左边是给 App 的那一块(`TouchBarLyricsStyle.systemModalWidth`),最左是收起键(✕),后面封面、三键、歌词那一格按
/// 封面和三键各自的「位置」排(跟本体同一份 `TouchBarSlot.order`),封面 / 三键跟着「显示封面」「显示播放控制」出没、
/// 让出来的宽度归歌词,封面那一格贴哪张图也跟本体同一份(`TouchBarLyricsCell.artworkTile`,广告期间是喇叭);右边是收起的系统功能栏(默认那四颗:亮度、音量、静音、Siri),只是参照物。开了「展开时隐藏功能栏」时
/// 右边那排不画,歌词那一格放宽到整条(`fullWidthModalWidth`),左端照画收起键 —— 本体那时用的是 App 自己那颗,样子
/// 跟系统的一样。
///
/// 歌词那一格就是触控栏本体那一格:同一个图层行、同一份规格(`TouchBarLyricsCell.spec` / `secondarySpec`),歌词也是
/// 本体那一份(`touchBarLyrics`,按真触控栏那一格量到的宽度断句,不按这里的估算宽),字号 /
/// 卡拉OK效果 / 跟随封面 / 副行改了这里当场跟着变;副行开着时两行的落点同本体(`TouchBarLyricsStyle` 的两行那一节)。
/// 在放歌时演真实的这一句;没在放歌时是示例句(同悬浮歌词编辑台那组自我说明的句子,副行开着也有字看),只画最终
/// 颜色、不演逐字染色(全仓预览的原则,见 `SectionPreviewBars` 头注)。设置窗口看不见时停表(`previewHostVisible`)。
/// 不收事件:三键点不动,预览不该能操作真实播放。
struct TouchBarPreviewStage: View {
    /// 整条触控栏(模拟器 2nd generation 实拍量的):给 App 的那一块 + 间隙 + 收起的功能栏 + 右端留白。
    private static let barSize = CGSize(width: 1015, height: TouchBarLyricsCell.barHeight)
    /// 收起的功能栏:左端一格窄的展开箭头 + 四颗键(实拍量的宽),右端离触控栏边缘 10pt。
    private static let stripChevronWidth: CGFloat = 15
    private static let stripButtonWidth: CGFloat = 57
    private static let stripTrailingInset: CGFloat = 10
    /// 触控栏四周露出来的那一圈键盘面。
    private static let deckPadding: CGFloat = 18
    private static let barCornerRadius: CGFloat = 7
    private static let buttonCornerRadius: CGFloat = 6
    /// 键钮的底色(收起键、三键那一块)。
    private static let buttonFill = Color(white: 0.22)
    /// 圆角跟设置卡片同一档,同 `LyricsWindowPreviewStage`。
    private static let stageCornerRadius: CGFloat = 12
    private static var contentSize: CGSize {
        CGSize(width: barSize.width + deckPadding * 2, height: barSize.height + deckPadding * 2)
    }

    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var feed = TouchBarPreviewFeed()
    @Environment(\.previewHostVisible) private var previewHostVisible

    var body: some View {
        let snapshot = feed.snapshot
        // 没有曲目时演示例句(整行、不带逐字时间轴,停着不动)。
        let isSample = snapshot.content == .idle
        let content = isSample ? Self.sampleContent : snapshot.content
        let font = TouchBarLyricsCell.mainFont(fontSize: settings.touchBarLyricsFontSize, secondary: snapshot.secondary)
        // 隐藏功能栏只在系统入口在时才算数,同本体。
        let hidesStrip = settings.touchBarHidesControlStrip && TouchBarPrivateAPI.supportsHidingControlStrip
        let lyricsWidth = CGFloat(TouchBarLyricsStyle.lyricsWidth(showsArtwork: settings.touchBarShowsArtwork,
                                                                  showsControls: settings.touchBarShowsControls,
                                                                  hidesControlStrip: hidesStrip))
        let inputs = TouchBarLyricsCell.Inputs(
            startMs: snapshot.startMs, dwellMs: snapshot.dwellMs, isPlaying: snapshot.isPlaying,
            timingEpoch: snapshot.timingEpoch, rate: snapshot.rate, font: font,
            color: TouchBarLyricsCell.lyricColor(followsCover: settings.touchBarLyricsFollowsCover,
                                                 coverAccent: snapshot.coverAccent),
            karaoke: settings.touchBarLyricsKaraoke,
            alignment: settings.touchBarLyricsAlignment)
        var spec = TouchBarLyricsCell.spec(for: content, inputs)
        var secondarySpec = TouchBarLyricsCell.secondarySpec(
            for: content, kind: snapshot.secondary,
            nextLineText: isSample ? L10n.t("这里是下一句歌词示例") : snapshot.nextLineText,
            nextLineSide: isSample ? nil : snapshot.nextLineSide, inputs)
        if !previewHostVisible {
            spec?.paused = true
            secondarySpec?.paused = true
        }
        let scrolls = TouchBarLyricsCell.text(for: content).map {
            MenuBarMarqueeRenderer.width(of: $0, font: font) > lyricsWidth + 0.5
        } ?? false
        let rows = LyricRows(main: spec, secondary: secondarySpec, twoRows: snapshot.secondary.showsSecondaryRow)
        return VStack(spacing: SectionPreviewMetrics.captionSpacing) {
            stage(rows: rows, lyricsWidth: lyricsWidth, hidesStrip: hidesStrip, snapshot: snapshot)
            Text(scrolls ? L10n.t("预览 · 左右滑动看整条 · 本句会横向滚动") : L10n.t("预览 · 左右滑动看整条"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: SectionPreviewMetrics.captionHeight)
        }
        .frame(maxWidth: .infinity)
        .onAppear { feed.restart() }
        .accessibilityHidden(true)
    }

    /// 示例句带上译文和读音(下一句在 `body` 里给),副行切到哪一档都有字。
    private static var sampleContent: TouchBarLyricsContent {
        .lyric(SyncedLyricLine(romanization: L10n.t("这里是读音示例"), translation: L10n.t("这里是译文示例"),
                               mainText: L10n.t("这里是一句歌词示例"), words: nil, wordGroups: nil, side: nil))
    }

    /// 歌词那一格的两行规格;一行时 `secondary` 恒为 nil。
    private struct LyricRows {
        var main: OverlayScrollingLyricRow.Spec?
        var secondary: OverlayScrollingLyricRow.Spec?
        var twoRows: Bool
    }

    private func stage(rows: LyricRows, lyricsWidth: CGFloat, hidesStrip: Bool,
                       snapshot: TouchBarPreviewFeed.Snapshot) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.stageCornerRadius, style: .continuous)
        let size = Self.contentSize
        // 横向滚动条常显:触控板下系统默认只在滑动时露出滚动条,不显示的话看不出这一条能滑。
        return ScrollView(.horizontal) {
            bar(rows: rows, lyricsWidth: lyricsWidth, hidesStrip: hidesStrip, snapshot: snapshot)
                .padding(Self.deckPadding)
                .frame(width: size.width, height: size.height)
                .background(deck)
                .allowsHitTesting(false)
        }
        .scrollIndicators(.visible)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: SettingsPage<EmptyView>.maxCardColumnWidth)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }

    /// 触控栏四周那一圈键盘面(深空灰铝)。不跟设置窗口的浅深色走:那一块本来就是机身。
    private var deck: some View {
        LinearGradient(colors: [Color(white: 0.27), Color(white: 0.19)], startPoint: .top, endPoint: .bottom)
    }

    /// 1:1 的那一条触控栏。
    private func bar(rows: LyricRows, lyricsWidth: CGFloat, hidesStrip: Bool,
                     snapshot: TouchBarPreviewFeed.Snapshot) -> some View {
        // 收起键两种模式都画在同一个位置(隐藏功能栏时本体左端是 App 自己那颗),不进下面这一排。
        let slots = TouchBarSlot.order(
            artworkSide: settings.touchBarArtworkSide, controlsSide: settings.touchBarControlsSide,
            showsArtwork: settings.touchBarShowsArtwork, showsControls: settings.touchBarShowsControls,
            hidesControlStrip: hidesStrip)
            .filter { $0 != .collapse }
        return ZStack(alignment: .leading) {
            closeBox
                .offset(x: TouchBarLyricsCell.closeBoxCenterX - TouchBarLyricsCell.closeBoxDiameter / 2)
            HStack(spacing: TouchBarLyricsCell.itemSpacing) {
                ForEach(slots, id: \.self) { slot in
                    item(slot, rows: rows, lyricsWidth: lyricsWidth, snapshot: snapshot)
                }
            }
            .offset(x: CGFloat(TouchBarLyricsStyle.firstItemX))
            if !hidesStrip {
                controlStrip
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, Self.stripTrailingInset)
            }
        }
        .frame(width: Self.barSize.width, height: Self.barSize.height, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Self.barCornerRadius, style: .continuous).fill(Color.black))
    }

    @ViewBuilder
    private func item(_ slot: TouchBarSlot, rows: LyricRows, lyricsWidth: CGFloat,
                      snapshot: TouchBarPreviewFeed.Snapshot) -> some View {
        switch slot {
        case .collapse:
            EmptyView()
        case .artwork:
            artwork(snapshot.artwork)
        case .controls:
            controls(playing: snapshot.isPlaying)
        case .lyrics:
            lyricCell(rows)
                .frame(width: lyricsWidth, height: Self.barSize.height, alignment: .topLeading)
        }
    }

    /// 歌词那一格:一行时占满整条高、垂直居中;副行开着时两行各占一格,落点同本体(`TouchBarLyricsStyle.twoRow*`,
    /// 两格上下叠一点、各探出触控栏一点,探出去的只是位图的留白)。
    @ViewBuilder
    private func lyricCell(_ rows: LyricRows) -> some View {
        if rows.twoRows {
            ZStack(alignment: .topLeading) {
                lyricRow(rows.main)
                    .frame(height: CGFloat(TouchBarLyricsStyle.twoRowMainHeight))
                    .offset(y: CGFloat(TouchBarLyricsStyle.twoRowMainTop))
                lyricRow(rows.secondary)
                    .frame(height: CGFloat(TouchBarLyricsStyle.twoRowSecondaryHeight))
                    .offset(y: CGFloat(TouchBarLyricsStyle.twoRowSecondaryTop))
            }
        } else {
            lyricRow(rows.main)
        }
    }

    @ViewBuilder
    private func lyricRow(_ spec: OverlayScrollingLyricRow.Spec?) -> some View {
        if let spec {
            OverlayScrollingLyricRow(spec: spec, nowMs: { PlaybackCoordinator.shared.lyricsTimelineMs() })
        } else {
            Color.clear
        }
    }

    private var closeBox: some View {
        Circle()
            .fill(Color(white: TouchBarLyricsCell.closeBoxWhite))
            .overlay(Image(systemName: "xmark")
                .font(.system(size: TouchBarLyricsCell.closeBoxSymbolSize, weight: .bold))
                .foregroundStyle(.black))
            .frame(width: TouchBarLyricsCell.closeBoxDiameter, height: TouchBarLyricsCell.closeBoxDiameter)
    }

    /// 收起的系统功能栏,只是参照物:箭头 + 亮度 / 音量 / 静音 / Siri。
    private var controlStrip: some View {
        HStack(spacing: 0) {
            Image(systemName: "chevron.compact.left")
                .font(.system(size: 16, weight: .medium))
                .frame(width: Self.stripChevronWidth, height: Self.barSize.height)
            ForEach(["sun.max.fill", "speaker.wave.2.fill", "speaker.slash.fill"], id: \.self) { name in
                Self.stripDivider
                Image(systemName: name)
                    .font(.system(size: 15))
                    .frame(width: Self.stripButtonWidth - 1, height: Self.barSize.height)
            }
            Self.stripDivider
            Circle()
                .fill(AngularGradient(colors: [.purple, .blue, .cyan, .pink, .purple], center: .center))
                .frame(width: 18, height: 18)
                .frame(width: Self.stripButtonWidth - 1, height: Self.barSize.height)
        }
        .foregroundStyle(.white.opacity(0.9))
        .background(RoundedRectangle(cornerRadius: Self.buttonCornerRadius, style: .continuous).fill(Self.buttonFill))
    }

    private static var stripDivider: some View {
        Rectangle().fill(Color.black.opacity(0.45)).frame(width: 1, height: 18)
    }

    private func artwork(_ image: NSImage?) -> some View {
        let side = TouchBarLyricsCell.barHeight
        return Image(nsImage: image ?? TouchBarLyricsCell.placeholderArtwork)
            .resizable()
            .scaledToFill()
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: TouchBarLyricsCell.artworkCornerRadius, style: .continuous))
    }

    /// 三键 + 设置键(同本体那个分段控件的四格)。
    private func controls(playing: Bool) -> some View {
        let names = [NSImage.touchBarSkipToStartTemplateName,
                     playing ? NSImage.touchBarPauseTemplateName : NSImage.touchBarPlayTemplateName,
                     NSImage.touchBarSkipToEndTemplateName]
        return HStack(spacing: 0) {
            ForEach(names.indices, id: \.self) { index in
                if index > 0 { Self.segmentDivider }
                Group {
                    if let image = NSImage(named: names[index]) {
                        Image(nsImage: image).renderingMode(.template).foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Self.segmentDivider
            Image(systemName: "gearshape")
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 真机上 4 × 44 的分段控件量出来是 182pt(带外框),跟 `TouchBarLyricsStyle.controlsSlot` 同一个数。
        .frame(width: CGFloat(TouchBarLyricsStyle.controlsSlot) - TouchBarLyricsCell.itemSpacing,
               height: Self.barSize.height)
        .background(RoundedRectangle(cornerRadius: Self.buttonCornerRadius, style: .continuous).fill(Self.buttonFill))
    }

    private static var segmentDivider: some View {
        Rectangle().fill(Color.black.opacity(0.45)).frame(width: 1, height: 18)
    }
}

/// 预览自己那份播放快照。订阅的源跟 `TouchBarLyricsController` 同一批(`TouchBarLyricsCell.playbackChanges`),
/// 搬到这里是因为预览没有控制器那份实例可复用(同 `MenuBarPreviewBar` 的做法);攒到下一拍再算,躲开 @Published 在
/// willSet 时发布、回读还是旧值的坑。「副行」也在这里读:它决定显示哪一档,跟着快照一起换,一行 / 两行的版面不会
/// 跟内容差一拍。
@MainActor
final class TouchBarPreviewFeed: ObservableObject {
    struct Snapshot: Equatable {
        var content: TouchBarLyricsContent = .idle
        var secondary: LyricSecondaryLine = .off
        var nextLineText: String?
        var nextLineSide: LyricDuet.Side?
        var startMs = 0
        var dwellMs: Int?
        var isPlaying = false
        var timingEpoch = 0
        var rate: Double = 1
        var coverAccent: NSColor?
        var artwork: NSImage?
    }

    @Published private(set) var snapshot = Snapshot()
    private var start = TouchBarDisplayStart()
    private var observers: [AnyCancellable] = []
    private var refreshScheduled = false

    init() {
        let p = PlaybackCoordinator.shared
        let changes = TouchBarLyricsCell.playbackChanges(p) + [
            TouchBarLyricsCell.signal(p.$highResAverageHex),
            TouchBarLyricsCell.signal(LocalPlaybackSource.shared.$artworkAverageHex),
            TouchBarLyricsCell.signal(AppSettings.shared.$touchBarSecondaryLine),
        ]
        observers = [Publishers.MergeMany(changes).sink { [weak self] in self?.scheduleRefresh() }]
        refresh()
    }

    /// 预览出现时调:歌名这类只滚一轮的从此刻重新起滚。
    func restart() {
        start.restartIfNotLyric(nowMs: PlaybackCoordinator.shared.lyricsTimelineMs())
        refresh()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        let p = PlaybackCoordinator.shared
        let secondary = AppSettings.shared.touchBarSecondaryLine
        let content = TouchBarLyricsCell.content(p, secondary: secondary)
        start.update(content: content, lineIndex: p.currentLineIndex, nowMs: p.lyricsTimelineMs())
        let next = Snapshot(
            content: content, secondary: secondary,
            nextLineText: p.touchBarLyrics.nextText, nextLineSide: p.touchBarLyrics.nextSide,
            startMs: start.sinceMs, dwellMs: TouchBarLyricsCell.dwellMs(p, secondary: secondary),
            isPlaying: p.isPlayingNow,
            timingEpoch: LyricsTimingEpoch.of(anchor: p.anchor, pausedPositionMs: p.pausedPositionMs,
                                              offsetMs: p.currentLyricsOffsetMs),
            rate: p.anchor?.rate ?? 1,
            coverAccent: TouchBarLyricsCell.coverAccent(
                hex: p.highResAverageHex ?? LocalPlaybackSource.shared.artworkAverageHex),
            artwork: TouchBarLyricsCell.artworkTile(p, content: content))
        if next != snapshot { snapshot = next }
    }
}
