import CoreGraphics
import Foundation

/// 悬浮歌词图层行(`OverlayScrollingLyricRow`)的横向排版:每个字的起止位置、逐词读音的落点、
/// 整张长图多宽。文字宽度由调用方传进来(Core 里没有字体)。
///
/// 开了逐词罗马音时一组一列:上面是这一组的字,下面是它的读音,两行都左对齐;列宽取上下两行
/// 更宽的那个。读音左右各留 `romaSidePadding(strokeInset:)`,没有读音的组按一个空格占位 —— 滚动
/// 模式、换行模式(`WrappedKaraokeRows` 每行一条图层行,同样走这里)和前奏首句的逐词列(SwiftUI)
/// 都读这一个函数,列宽一致,开唱或切换模式那一刻读音不挪位,相邻两组读音也不会首尾相接。
public enum OverlayRowLayout {
    /// 逐词读音左右各留的空白(不算描边)。
    public static let romaSidePadding: CGFloat = 2

    /// 读音每侧实际留多少。描边开着时每侧再让出一份描边外扩(`strokeInset`):描边往外胀,
    /// 只留 `romaSidePadding` 的话相邻两组读音的描边会在字缝里连成一片、看不出词界;多让这一份,
    /// 描边之外看到的字缝跟不描边时一样宽。三处排版都读这里,别各写一个数。
    public static func romaSidePadding(strokeInset: CGFloat) -> CGFloat {
        romaSidePadding + max(0, strokeInset)
    }

    public struct RomaPlacement: Equatable, Sendable {
        public let x: CGFloat
        public let text: String

        public init(x: CGFloat, text: String) {
            self.x = x
            self.text = text
        }
    }

    public struct Result: Equatable, Sendable {
        /// 每个字的左缘 / 右缘(点,长图坐标,含左侧 `inset`),与 `flatWords` 一一对应。
        public var wordStartXs: [CGFloat]
        public var wordEndXs: [CGFloat]
        /// 有读音的组各一条:读音从哪儿画。
        public var romaPlacements: [RomaPlacement]
        /// 按排版顺序摊平的字。
        public var flatWords: [SyncedLyricWord]
        /// 整张长图的宽度,左右各含一份 `inset`。
        public var boxWidth: CGFloat
    }

    /// - Parameter groups: 非 nil = 逐词罗马音,按组排两行;nil = 只排 `words` 一行。
    /// - Parameter inset: 长图四周的预留(描边 / 阴影出血),左右各一份。
    /// - Parameter strokeInset: 描边外扩(没开描边传 0),决定读音两侧留白,见 `romaSidePadding(strokeInset:)`。
    public static func layOut(
        words: [SyncedLyricWord], groups: [SyncedLyricWordGroup]?, inset: CGFloat, strokeInset: CGFloat = 0,
        measureMain: (String) -> CGFloat, measureRoma: (String) -> CGFloat
    ) -> Result {
        let pad = romaSidePadding(strokeInset: strokeInset)
        var starts: [CGFloat] = []
        var ends: [CGFloat] = []
        var romas: [RomaPlacement] = []
        var flat: [SyncedLyricWord] = []
        func place(_ ws: [SyncedLyricWord], from origin: CGFloat) -> CGFloat {
            var x = origin
            for w in ws {
                starts.append(x)
                x += measureMain(w.text)
                ends.append(x)
                flat.append(w)
            }
            return x - origin
        }
        var cursor = inset
        if let groups {
            for g in groups {
                let columnStart = cursor
                let wordsWidth = place(g.words, from: columnStart)
                let romaWidth = measureRoma(g.romanization ?? " ") + pad * 2
                if let r = g.romanization { romas.append(RomaPlacement(x: columnStart + pad, text: r)) }
                cursor = columnStart + max(wordsWidth, romaWidth)
            }
        } else {
            cursor += place(words, from: cursor)
        }
        return Result(wordStartXs: starts, wordEndXs: ends, romaPlacements: romas,
                      flatWords: flat, boxWidth: cursor + inset)
    }
}
