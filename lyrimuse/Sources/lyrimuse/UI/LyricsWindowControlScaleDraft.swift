import SwiftUI
import LyrimuseCore

/// 设置页拖「控件大小」滑杆时还没写进设置的那个值。拖动中只给设置页的歌词窗口预览看(`LyricsWindowPreviewStage`
/// 经环境值 `lyricsWindowControlScaleOverride` 传进去),松手才写设置:写设置会连带重排真窗口、整个设置页和网页歌词,
/// 逐格写拖起来卡(07 章决策 198)。nil = 没在拖,照设置画。
@MainActor
final class LyricsWindowControlScaleDraft: ObservableObject {
    static let shared = LyricsWindowControlScaleDraft()
    @Published var percent: Double?
}

private struct LyricsWindowControlScaleOverrideKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// 歌词窗口完整尺寸「控件大小」的临时倍数,只有设置页预览会设;nil 时按设置走。
    var lyricsWindowControlScaleOverride: CGFloat? {
        get { self[LyricsWindowControlScaleOverrideKey.self] }
        set { self[LyricsWindowControlScaleOverrideKey.self] = newValue }
    }
}

/// 「控件大小」那根滑杆和右边的读数。单独成一个视图:拖动中的草稿值只让这一行和预览重算,
/// 别挂进整个设置页(那个视图观察着 AppSettings,一动就是整页重算)。
/// 拖动中只写草稿;松手、键盘或 VoiceOver 增减时直接写设置。
struct LyricsWindowControlScaleSlider: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var draft = LyricsWindowControlScaleDraft.shared
    @State private var dragging = false

    private var shown: Double { draft.percent ?? settings.lyricsWindowControlScalePercent }

    var body: some View {
        HStack(spacing: 8) {
            SteppedSlider(value: Binding(
                get: { shown },
                set: { v in
                    if dragging {
                        if draft.percent != v { draft.percent = v }
                    } else {
                        commit(v)
                    }
                }
            ), in: LyricsWindowControlScale.percentRange, step: LyricsWindowControlScale.percentStep,
               onEditingChanged: { began in
                dragging = began
                guard !began else { return }
                if let v = draft.percent { commit(v) }
                draft.percent = nil
            })
                .frame(width: 130)
            Text(verbatim: "\(Int(shown.rounded()))%")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                // 按最宽的「200%」留位,拖动时滑杆不左右挪。
                .frame(width: 38, alignment: .trailing)
        }
        // 拖到一半这一行没了(翻页、关窗口):草稿交给设置,别让预览一直停在没写进去的值上。
        .onDisappear {
            if let v = draft.percent { commit(v) }
            draft.percent = nil
        }
    }

    /// 相等守卫:同一个值不再广播。
    private func commit(_ v: Double) {
        guard v != settings.lyricsWindowControlScalePercent else { return }
        settings.lyricsWindowControlScalePercent = v
    }
}
