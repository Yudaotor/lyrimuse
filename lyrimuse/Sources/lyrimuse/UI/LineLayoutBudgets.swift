import AppKit
import Combine
import LyrimuseCore
import SwiftUI

/// 把三个单行展示面的宽度预算报给 LocalPlaybackSource(按宽度重新断句,见 08 章决策 25):每个面上会出现的
/// 每一行(主行、译文、罗马音、下一句)各多宽、用什么字体量。悬浮歌词和菜单栏的宽度、字体都在设置里,这里订阅了报;
/// 灵动岛歌词列的宽度跟刘海、耳朵模块、封面有关,由那个视图自己量了报(LineLayoutWidthReporter)。
///
/// 这里的宽度和量法必须跟各面判「装不装得下」的那一处一致:悬浮歌词 / 灵动岛的图层行按词相加再加描边预留
/// (OverlayRowLayout),菜单栏按整串量(MenuBarMarqueeRenderer.presentation)。那边改了,这里同步改。
@MainActor
final class LineLayoutBudgets {
    static let shared = LineLayoutBudgets()
    private var subs: [AnyCancellable] = []
    private let notchWidth = CurrentValueSubject<CGFloat, Never>(0)

    /// 量出来的宽度再让出这么多,吸收 SwiftUI 排版取整。
    private static let safety: CGFloat = 1

    private init() {}

    func start() {
        guard subs.isEmpty else { return }
        let s = AppSettings.shared
        // 闭包里只用参数,别回头读 AppSettings:@Published 在 willSet 时发布,那一刻存储属性还是旧值。
        subs = [
            Publishers.CombineLatest4(s.$overlayWidth, s.$overlayNSFonts, s.$textStrokeEnabled,
                                      s.$overlayDuetAlignmentOverride)
                .combineLatest(Publishers.CombineLatest3(s.$showTranslation, s.$showRomanization,
                                                         s.$showNextLinePreview))
                .sink { a, b in
                    let (width, fonts, stroke, duetOverride) = a
                    let (translation, romanization, preview) = b
                    Self.reportOverlay(width: CGFloat(width), fonts: fonts, stroke: stroke,
                                       sided: duetOverride == .automatic, translation: translation,
                                       romanization: romanization, preview: preview)
                },
            Publishers.CombineLatest4(s.$menuBarLyricsWidth, s.$menuBarLyricsFontFamily,
                                      s.$menuBarLyricsFontWeight, s.$menuBarLyricsFontSize)
                .combineLatest(s.$menuBarSecondaryLine)
                .sink { values, secondary in
                    let (width, family, weight, size) = values
                    Self.reportMenuBar(width: width, family: family, weight: weight, size: size,
                                       secondary: secondary)
                },
            Publishers.CombineLatest4(notchWidth.removeDuplicates(), s.$notchMainNSFont,
                                      s.$notchSecondaryNSFont, s.$notchSecondaryLine)
                .sink { width, main, secondary, kind in
                    Self.reportNotch(width: width, main: main, secondary: secondary, kind: kind)
                },
        ]
    }

    /// 灵动岛歌词列此刻的宽度(LineLayoutWidthReporter 报上来)。
    func setNotchWidth(_ width: CGFloat) {
        notchWidth.send((width * 2).rounded() / 2)
    }

    /// `translation`:量的是译文行(排字语言按译文判,见 `LyricTypesetting`)。
    private static func measurer(_ font: NSFont, translation: Bool = false) -> (String) -> CGFloat {
        { OverlayNaturalWidth.width($0, font: font, translation: translation) }
    }

    private static func fontKey(_ font: NSFont) -> [AnyHashable] { [font.fontName, font.pointSize] }

    /// 悬浮歌词:每一行的宽 = 窗宽 − 卡片两侧内边距 − 描边两侧预留;对唱行再让出演唱者标记。下一句换人唱时
    /// 用主行字号(nextLinePreviewFont),所以按主行和预览两种字号里宽的那个量。
    private static func reportOverlay(width: CGFloat, fonts: OverlayNSFonts, stroke: Bool, sided: Bool,
                                      translation: Bool, romanization: Bool, preview: Bool) {
        let strokeInset = stroke ? LyricsTextStrokeMetrics.inset : 0
        let rowWidth = width - OverlayMetrics.cardHorizontalPadding * 2 - strokeInset * 2 - safety
        let main = measurer(fonts.main)
        let previewMeasure = measurer(fonts.preview)
        let key: [AnyHashable] = [LyricsSurface.overlay, (rowWidth * 2).rounded(), fontKey(fonts.main),
                                  fontKey(fonts.preview), fontKey(fonts.translation), fontKey(fonts.romanization),
                                  stroke, sided, translation, romanization, preview]
        report(.overlay, LineLayoutBudget(
            key: key,
            main: .init(maxWidth: rowWidth, measure: main),
            sidedInset: sided ? OverlayMetrics.speakerIndicatorWidth : 0,
            preview: preview ? .init(maxWidth: rowWidth, measure: { max(main($0), previewMeasure($0)) }) : nil,
            translation: translation ? .init(maxWidth: rowWidth, measure: measurer(fonts.translation, translation: true)) : nil,
            romanization: romanization ? .init(maxWidth: rowWidth, measure: measurer(fonts.romanization)) : nil,
            wordRomanization: romanization
                ? .init(measure: measurer(fonts.romanization),
                        sidePadding: OverlayRowLayout.romaSidePadding(strokeInset: strokeInset))
                : nil))
    }

    /// 菜单栏:一行的宽就是「最大宽度」(进度图标另占,不在里面);单排 / 双排主行字号不同,双排的副行用副行字号。
    /// 判据同 MenuBarMarqueeRenderer.presentation:整串宽超过窗宽半个点才滚。
    private static func reportMenuBar(width: CGFloat, family: String, weight: OverlayFontWeight, size: CGFloat,
                                      secondary: LyricSecondaryLine) {
        let twoRows = secondary.showsSecondaryRow
        let mainFont = twoRows
            ? MenuBarMarqueeRenderer.font(family: family, weight: weight, pointSize: MenuBarLyricRows.mainPointSize)
            : MenuBarMarqueeRenderer.font(family: family, weight: weight, size: size)
        let secondaryFont = MenuBarMarqueeRenderer.font(family: family, weight: weight,
                                                        pointSize: MenuBarLyricRows.secondaryPointSize)
        let main: (String) -> CGFloat = { MenuBarMarqueeRenderer.width(of: $0, font: mainFont) }
        let second = LineLayoutBudget.Row(
            maxWidth: width, measure: { MenuBarMarqueeRenderer.width(of: $0, font: secondaryFont) })
        let secondTranslation = LineLayoutBudget.Row(
            maxWidth: width, measure: { MenuBarMarqueeRenderer.width(of: $0, font: secondaryFont, translation: true) })
        let key: [AnyHashable] = [LyricsSurface.menuBar, (width * 2).rounded(), fontKey(mainFont),
                                  fontKey(secondaryFont), secondary.rawValue]
        report(.menuBar, LineLayoutBudget(
            key: key,
            main: .init(maxWidth: width, measure: main),
            preview: secondary == .nextLine ? second : nil,
            translation: secondary == .translation ? secondTranslation : nil,
            romanization: secondary == .romanization ? second : nil))
    }

    /// 灵动岛:主行和副行都占歌词列的整宽。
    private static func reportNotch(width: CGFloat, main: NSFont, secondary: NSFont, kind: LyricSecondaryLine) {
        guard width > 0 else { return }
        let rowWidth = width - safety
        let second = LineLayoutBudget.Row(maxWidth: rowWidth, measure: measurer(secondary))
        let secondTranslation = LineLayoutBudget.Row(maxWidth: rowWidth, measure: measurer(secondary, translation: true))
        let key: [AnyHashable] = [LyricsSurface.notch, (rowWidth * 2).rounded(), fontKey(main),
                                  fontKey(secondary), kind.rawValue]
        report(.notch, LineLayoutBudget(
            key: key,
            main: .init(maxWidth: rowWidth, measure: measurer(main)),
            preview: kind == .nextLine ? second : nil,
            translation: kind == .translation ? secondTranslation : nil,
            romanization: kind == .romanization ? second : nil))
    }

    private static func report(_ surface: LyricsSurface, _ budget: LineLayoutBudget) {
        guard budget.main.maxWidth > 0 else { return }
        LocalPlaybackSource.shared.setLineLayoutBudget(budget, for: surface)
    }
}

/// 挂在灵动岛歌词列的背景里:量到的宽度变了就报给按宽度断句。
struct LineLayoutWidthReporter: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { LineLayoutBudgets.shared.setNotchWidth(proxy.size.width) }
                .onChange(of: proxy.size.width) { _, width in LineLayoutBudgets.shared.setNotchWidth(width) }
        }
    }
}
