import AppKit
import Combine
import LyrimuseCore
import SwiftUI

/// 灵动岛展开态的多行歌词(「多行歌词」,05 章决策 90):歌词窗口那套图层列表(`LyricsLayerList`),逐字填色、换句滚动、
/// 间奏「•••」都是装给 Core Animation 的动画,主线程只在换句那一刻装一次。换成灵动岛的字体族、粗细、强调色和对齐方式,
/// 字号固定(`NotchExpandedMetrics.lyricListFontSize`)。
///
/// 点一句跳到那一句(同歌词窗口,减回歌词偏移),指针停在哪句哪句变亮;播放器不能挪进度时(`acceptsSeek`)只看不点。
/// 鼠标由这一层的 SwiftUI 接住、再按位置问列表是哪一行:卡片同一个宿主视图里有 SwiftUI 交互视图(悬停判定、按钮),
/// 里面的 AppKit 列表收不到点击和悬停,所以列表本身 `interactive: false`,滚轮照旧归触控板手势。不做景深模糊:13pt 的字
/// 一模糊就糊成一片。所在那一层看不见时(没展开、窗口藏着)按 `notchCardLayerActive` 停表。
///
/// 订阅挂在自己的 `NotchLyricListFeed` 上:换句只失效这一块,不打醒整卡(同 `NotchPlayback` 那条纪律)。
struct NotchExpandedLyricList: View {
    let tint: Color
    @StateObject private var feed = NotchLyricListFeed()
    @State private var listHandle = LyricsLayerListHandle()
    @Environment(\.notchCardLayerActive) private var layerActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    /// 歌词这一列离卡片左右边的距离,同展开区别的几块的 16pt。
    private static let horizontalInset: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            LyricsLayerList(
                spec: spec(width: proxy.size.width),
                nowMs: { PlaybackCoordinator.shared.lyricsTimelineMs() },
                onTapLine: { _ in },
                interactive: false,
                minimumEdgePadding: 0,
                placement: placement(height: proxy.size.height),
                handle: listHandle)
        }
        .overlay {
            if PlaybackCoordinator.shared.acceptsSeek {
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): listHandle.view?.hoverLine(at: point)
                        case .ended: listHandle.view?.hoverLine(at: nil)
                        }
                    }
                    .gesture(SpatialTapGesture().onEnded { value in
                        guard let index = listHandle.view?.lineIndex(at: value.location) else { return }
                        seek(toLine: index)
                    })
                    // 这一层撤掉时(换到不能挪进度的播放器)收不到「指针离开」,自己把点亮的那句放掉。
                    .onDisappear { listHandle.view?.hoverLine(at: nil) }
                    // 只接鼠标、没有内容;各句读屏由列表自己给。
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// 减回歌词偏移,理由同歌词窗口点行跳转。
    private func seek(toLine index: Int) {
        let lines = feed.lines
        guard PlaybackCoordinator.shared.acceptsSeek, lines.indices.contains(index) else { return }
        PlaybackCoordinator.shared.seek(
            toMs: max(0, lines[index].timeMs - PlaybackCoordinator.shared.currentLyricsOffsetMs))
    }

    /// 当前句上面正好放下整数行、渐隐只淡行距那道缝(`NotchExpandedMetrics.lyricListActiveAnchor` / `lyricListEdgeFade`)。
    /// 行数从这一格的高度反推:高度就是行数 × 每行高度。
    private func placement(height: CGFloat) -> LyricsLayerListPlacement {
        let secondary = feed.secondaryLine.showsLyricListSecondary
        let pitch = NotchExpandedMetrics.lyricListPitch(secondaryRow: secondary)
        let count = max(1, Int((height / pitch).rounded()))
        let fade = height > 0 ? min(0.5, NotchExpandedMetrics.lyricListEdgeFade / height) : 0
        return LyricsLayerListPlacement(
            activeAnchor: NotchExpandedMetrics.lyricListActiveAnchor(lineCount: count, secondaryRow: secondary),
            topClear: 0, topOpaque: fade, bottomOpaque: 1 - fade, bottomClear: 1)
    }

    private func spec(width: CGFloat) -> LyricsLayerList.Spec {
        let fontSize = NotchExpandedMetrics.lyricListFontSize
        let secondarySize = NotchLyricRowMetrics.secondaryFontSize
        let ink = NSColor(tint)
        let column = max(1, width - 2 * Self.horizontalInset)
        return .init(
            lines: feed.lines,
            gapMarkers: feed.gapMarkers,
            songwriters: [],
            style: .init(fontSize: fontSize, romaFontSize: secondarySize, translationFontSize: secondarySize,
                         fontFamily: feed.fontFamily, textColor: ink,
                         secondaryColor: ink.withAlphaComponent(ink.alphaComponent * 0.75),
                         showRomanization: feed.secondaryLine == .romanization,
                         showTranslation: feed.secondaryLine == .translation,
                         centered: false, wordRise: false, reduceMotion: reduceMotion,
                         duetInsetUnit: LyricDuetLayout.insets(for: .leading, availableWidth: column, fontSize: fontSize).trailing,
                         scale: displayScale, weight: feed.fontWeight,
                         forcedSide: feed.alignment.forcedDuetSide),
            lineSpacing: NotchExpandedMetrics.lyricListLineSpacing,
            showsScrollIndicator: false,
            leading: Self.horizontalInset, trailing: Self.horizontalInset,
            onArtwork: true,
            suspendsBlur: true,
            currentLineIndex: feed.currentLineIndex,
            scrollLineIndex: feed.scrollLineIndex,
            overlapping: feed.overlapping,
            currentGapIndex: feed.currentGapIndex,
            fillSettled: feed.fillSettled,
            isPlaying: feed.clockRunning,
            surfaceVisible: layerActive,
            timingEpoch: feed.timingEpoch,
            rate: feed.rate)
    }
}

/// `NotchExpandedLyricList` 的窄订阅:只转发列表要的那几样,值类型一律去重。sink 只用参数值,不回读源属性(@Published
/// 在 willSet 发布,回读是旧值)。
@MainActor
private final class NotchLyricListFeed: ObservableObject {
    /// 整首的行;灵动岛「卡拉OK效果」关着时压成整行(`MiniLyricsSelection.lines`,同歌词窗口)。
    @Published private(set) var lines: [LyricsWindowLine] = []
    @Published private(set) var gapMarkers: [Int: LyricsGapMarker] = [:]
    @Published private(set) var currentLineIndex: Int?
    @Published private(set) var scrollLineIndex: Int?
    @Published private(set) var overlapping: Set<Int> = []
    @Published private(set) var currentGapIndex: Int?
    @Published private(set) var fillSettled = true
    @Published private(set) var clockRunning = false
    @Published private(set) var timingEpoch = 0
    @Published private(set) var rate: Double = 1
    @Published private(set) var fontFamily = AppSettings.shared.notchFontFamilyName
    @Published private(set) var fontWeight = AppSettings.shared.notchFontWeight
    @Published private(set) var secondaryLine = AppSettings.shared.notchSecondaryLine
    @Published private(set) var alignment = AppSettings.shared.notchLyricsAlignment
    private var subs: [AnyCancellable] = []

    init() {
        let p = PlaybackCoordinator.shared
        let s = AppSettings.shared
        subs = [
            Publishers.CombineLatest(p.$allLines.removeDuplicates(), s.$notchLyricsKaraoke.removeDuplicates())
                .map { MiniLyricsSelection.lines($0, karaoke: $1) }
                .sink { [weak self] in self?.lines = $0 },
            p.$lyricsGapMarkers.removeDuplicates().sink { [weak self] markers in
                // index 按理不重复,重复了留第一个(同歌词窗口)。
                self?.gapMarkers = Dictionary(markers.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
            },
            p.$currentLineIndex.removeDuplicates().sink { [weak self] in self?.currentLineIndex = $0 },
            p.$scrollLineIndex.removeDuplicates().sink { [weak self] in self?.scrollLineIndex = $0 },
            p.$overlappingLineIndices.removeDuplicates().map(Set.init).sink { [weak self] in self?.overlapping = $0 },
            p.$currentGapIndex.removeDuplicates().sink { [weak self] in self?.currentGapIndex = $0 },
            p.$currentLineFillSettled.removeDuplicates().sink { [weak self] in self?.fillSettled = $0 },
            Publishers.CombineLatest(p.$isPlayingNow, p.$anchor)
                .map { playing, anchor in playing && !(anchor?.isFrozen ?? false) }
                .removeDuplicates()
                .sink { [weak self] in self?.clockRunning = $0 },
            Publishers.CombineLatest3(p.$anchor, p.$pausedPositionMs, p.$currentLyricsOffsetMs)
                .map { LyricsTimingEpoch.of(anchor: $0, pausedPositionMs: $1, offsetMs: $2) }
                .removeDuplicates()
                .sink { [weak self] in self?.timingEpoch = $0 },
            p.$anchor.map { $0?.rate ?? 1 }.removeDuplicates().sink { [weak self] in self?.rate = $0 },
            s.$notchFontFamilyName.removeDuplicates().sink { [weak self] in self?.fontFamily = $0 },
            s.$notchFontWeight.removeDuplicates().sink { [weak self] in self?.fontWeight = $0 },
            s.$notchSecondaryLine.removeDuplicates().sink { [weak self] in self?.secondaryLine = $0 },
            s.$notchLyricsAlignment.removeDuplicates().sink { [weak self] in self?.alignment = $0 },
        ]
    }
}
