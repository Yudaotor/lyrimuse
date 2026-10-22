import Foundation

/// 一行歌词按从右往左排还是从左往右排(阿拉伯语、希伯来语、波斯语等是从右往左)。逐词画的那几条路
/// 都按这个结论把整行镜像:词序、填色、滚动一起变成从右往左(见 04 章决策 73)。
public enum LyricTextDirection {
    /// 第一个有方向的字母是从右往左的文字就算从右往左(Unicode 双向算法 P2 的段落方向判法)。
    /// 数字、标点、空白没有方向,跳过;一个有方向的字母都没有按从左往右。
    public static func isRightToLeft(_ text: String) -> Bool {
        for s in text.unicodeScalars {
            if isStrongRightToLeft(s) { return true }
            if s.properties.isAlphabetic || s.properties.isIdeographic { return false }
        }
        return false
    }

    /// 去掉尾部空白。从右往左的字排版时行尾空白不占宽(量出来的宽不含它),逐词排的几处把词本身和
    /// 它后面的空格分开量、分开摆。
    public static func trimmingTrailingWhitespace(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let prev = text.index(before: end)
            guard text[prev].isWhitespace else { break }
            end = prev
        }
        return String(text[..<end])
    }

    /// 希伯来、阿拉伯、叙利亚、它拿、西非书面文字及它们的展示形式区块里的字母。阿拉伯-印度数字(U+0660–0669、
    /// U+06F0–06F9)在双向算法里不算有方向,不认。
    static func isStrongRightToLeft(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0660...0x0669, 0x06F0...0x06F9: return false
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
            return s.properties.isAlphabetic
        default: return false
        }
    }
}
