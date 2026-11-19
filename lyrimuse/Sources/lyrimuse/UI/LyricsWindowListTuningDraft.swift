import SwiftUI
import LyrimuseCore

/// 设置页拖歌词窗口排版 / 景深滑杆(`LyricsWindowListTuning` 那九项)时还没写进设置的值。拖动中只给设置页的歌词窗口预览看
/// (`LyricsWindowPreviewStage` 经环境值 `lyricsWindowListTuningOverride` 传进去),松手才写设置:字号、副行、间距一变整张列表
/// 后台重建,逐格写会连带重排真窗口、整个设置页和网页歌词(同「控件大小」,07 章决策 198)。空 = 没在拖,照设置画。
@MainActor
final class LyricsWindowListTuningDraft: ObservableObject {
    static let shared = LyricsWindowListTuningDraft()
    @Published var values: [LyricsWindowListTuning.Item: Double] = [:]
}

private struct LyricsWindowListTuningOverrideKey: EnvironmentKey {
    static let defaultValue: [LyricsWindowListTuning.Item: Double] = [:]
}

extension EnvironmentValues {
    /// 歌词窗口完整尺寸排版 / 景深的临时值,只有设置页预览会设;空时按设置走。
    var lyricsWindowListTuningOverride: [LyricsWindowListTuning.Item: Double] {
        get { self[LyricsWindowListTuningOverrideKey.self] }
        set { self[LyricsWindowListTuningOverrideKey.self] = newValue }
    }
}

/// 九项里某一项的一格(标题、读数、滑杆,样式同悬浮歌词「读音间距」那几格 `OverlayRowSliderTile`)。单独成一个视图,理由同
/// `LyricsWindowControlScaleSlider`:拖动中的草稿只让这一格和预览重算,别挂进整个设置页。
/// 拖动中只写草稿;松手、键盘或 VoiceOver 增减时直接写设置。
struct LyricsWindowListTuningTile: View {
    let item: LyricsWindowListTuning.Item
    let title: String
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var draft = LyricsWindowListTuningDraft.shared
    @State private var dragging = false

    private var shown: Double { draft.values[item] ?? settings.lyricsWindowListTuning[item] }

    var body: some View {
        OverlayRowSliderTile(
            title: title,
            reading: item.percentText(shown),
            value: Binding(
                get: { shown },
                set: { v in
                    if dragging {
                        if draft.values[item] != v { draft.values[item] = v }
                    } else {
                        commit(v)
                    }
                }),
            range: item.range, step: item.step,
            onEditingChanged: { began in
                dragging = began
                guard !began else { return }
                if let v = draft.values[item] { commit(v) }
                draft.values[item] = nil
            })
        // 拖到一半这一格没了(翻页、关浮层):草稿交给设置,别让预览一直停在没写进去的值上。
        .onDisappear {
            if let v = draft.values[item] { commit(v) }
            draft.values[item] = nil
        }
    }

    /// 相等守卫:同一个值不再广播。
    private func commit(_ v: Double) {
        guard v != settings.lyricsWindowListTuning[item] else { return }
        settings.lyricsWindowListTuning[item] = v
    }
}
