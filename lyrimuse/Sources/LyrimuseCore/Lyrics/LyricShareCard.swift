import CoreGraphics
import Foundation

/// 歌词分享卡片(歌词窗口「⋯ › 分享歌词…」):能选哪几句、怎么选、卡片上写什么。画卡片和出图在 App 侧
/// (`LyricShareWindow`)。见 07 章决策 180。
public enum LyricShareCard {
    /// 一张卡片最多几句:再多字号就得缩到手机上看不清。
    public static let maxLines = 4
    /// 出图尺寸(像素):4:5 竖图,常见社交平台的图片流都不裁。
    public static let pixelSize = CGSize(width: 1080, height: 1350)

    /// 卡片上的一句。
    public struct Line: Equatable, Identifiable, Sendable {
        public let id: String
        public let text: String
        public let translation: String?
        public let romanization: String?

        public init(id: String, text: String, translation: String?, romanization: String?) {
            self.id = id
            self.text = text
            self.translation = translation
            self.romanization = romanization
        }
    }

    /// 能选的行:歌词窗口的每一行里有正文的那些,按先后。译文、读音取那一行显示的那份,空的当没有。
    public static func lines(from all: [LyricsWindowLine]) -> [Line] {
        all.compactMap { item in
            let line = item.line
            let text = trimmed(line.plainText ?? line.mainText ?? line.words?.map(\.text).joined())
            guard let text else { return nil }
            return Line(id: item.id, text: text, translation: trimmed(line.translation),
                        romanization: trimmed(line.romanization))
        }
    }

    /// 勾 / 取消一句:已选的取消;没选的加上,已经满 `maxLines` 句时不加。结果按先后排好。
    public static func toggled(_ selection: [String], _ id: String, order: [String]) -> [String] {
        var picked = Set(selection)
        if picked.contains(id) {
            picked.remove(id)
        } else if picked.count < maxLines {
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
