import LyrimuseCore
import SwiftUI

/// 「歌词 › 语言 › 文字」卡顶上的示例:三句样句和它们此刻的读音,改一项立刻看到结果。算法在 Core
/// `LyricsReadingSample`(播放时同一套读音和繁简函数),这里只管排版。
struct LyricsTextSample: View {
    let scripts: RomanizationScripts
    let japaneseReading: JapaneseReadingStyle
    let chineseVariant: ChineseVariant

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("示例"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            SettingsEqualColumns(columns: 3, spacing: 10) {
                ForEach(Array(LyricsReadingSample.lines(scripts: scripts, japaneseReading: japaneseReading,
                                                       chineseVariant: chineseVariant).enumerated()),
                        id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: line.original)
                            .font(.system(size: 13, weight: .medium))
                        Text(line.reading ?? L10n.t("不标注读音"))
                            .font(.system(size: 11))
                            .foregroundStyle(line.reading == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
        .accessibilityElement(children: .combine)
    }
}
