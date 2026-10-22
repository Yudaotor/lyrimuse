import CoreGraphics
import Foundation

/// 歌词分享卡片(歌词窗口「⋯ › 分享歌词…」):能选哪几句、怎么选、卡片上写什么。画卡片和出图在 App 侧
/// (`LyricShareWindow`)。见 07 章决策 180。
public enum LyricShareCard {
    /// 出图宽度(像素)。高度至少 1350(4:5,常见社交平台的图片流都不裁),句子多了按内容加高。
    public static let pixelWidth: CGFloat = 1080
    public static let minPixelHeight: CGFloat = 1350

    /// 正文字号(按 540 点宽排版):句子越多字越小,读音、译文按它的比例。
    public static func fontSize(lineCount: Int) -> CGFloat {
        switch lineCount {
        case ...4: return 31
        case ...8: return 26
        default: return 22
        }
    }

    /// 卡片上的一句。
    public struct Line: Equatable, Identifiable, Sendable {
        public let id: String
        public let text: String
        public let translation: String?
        public let romanization: String?
        /// 读音按字分好的组(字在上、读音在下),拼起来等于 `text`;分不出来时为 nil,读音整句放在下面一行。
        public let rubyGroups: [LyricsRubyGroup]?

        public init(id: String, text: String, translation: String?, romanization: String?,
                    rubyGroups: [LyricsRubyGroup]? = nil) {
            self.id = id
            self.text = text
            self.translation = translation
            self.romanization = romanization
            self.rubyGroups = rubyGroups
        }
    }

    /// 能选的行:歌词窗口的每一行里有正文的那些,按先后。译文、读音取那一行显示的那份,空的当没有。`groups` 给有读音
    /// 的行按字分组(同歌词管理预览,`LyricsSyncEngine.romanizationGroups`),拼不回正文的不用。
    public static func lines(from all: [LyricsWindowLine],
                             groups: (_ text: String, _ timeMs: Int) -> [SyncedLyricWordGroup]? = { _, _ in nil }) -> [Line] {
        all.compactMap { item in
            let line = item.line
            let text = trimmed(line.plainText ?? line.mainText ?? line.words?.map(\.text).joined())
            guard let text else { return nil }
            let romanization = trimmed(line.romanization)
            let ruby = romanization == nil ? nil : groups(text, item.timeMs)?.map {
                LyricsRubyGroup(text: $0.words.map(\.text).joined(), romanization: $0.romanization)
            }
            return Line(id: item.id, text: text, translation: trimmed(line.translation), romanization: romanization,
                        rubyGroups: ruby.flatMap { $0.map(\.text).joined() == text ? $0 : nil })
        }
    }

    /// 勾 / 取消一句:已选的取消,没选的加上。结果按先后排好。
    public static func toggled(_ selection: [String], _ id: String, order: [String]) -> [String] {
        var picked = Set(selection)
        if picked.contains(id) {
            picked.remove(id)
        } else {
            picked.insert(id)
        }
        return order.filter(picked.contains)
    }

    /// 打开时默认选中的那句:歌词窗口当前那一行(它没有正文就往前找最近的一句),都没有就第一句。
    public static func initialSelection(lines: [Line], allLineIDs: [String], currentIndex: Int?) -> [String] {
        guard !lines.isEmpty else { return [] }
        let selectable = Set(lines.map(\.id))
        if let currentIndex, allLineIDs.indices.contains(currentIndex),
           let id = allLineIDs[...currentIndex].last(where: selectable.contains) {
            return [id]
        }
        return [lines[0].id]
    }

    /// 保存时的默认文件名:「歌名 - 歌手」,文件名里不能用的字符换成空格。
    public static func fileName(title: String, artist: String) -> String {
        let base = [title, artist].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " - ")
        let cleaned = String(base.map { "/:\\".contains($0) ? " " : $0 })
        return (cleaned.isEmpty ? "Lyrimuse" : cleaned) + ".png"
    }

    private static func trimmed(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
