import Foundation

/// 一行歌词按从右往左排还是从左往右排(阿拉伯语、希伯来语、波斯语等是从右往左)。逐词画的那几条路
/// 都按这个结论把整行镜像:词序、填色、滚动一起变成从右往左(见 04 章决策 73);菜单栏整句一次画时
/// 也按它定 CoreText 的段落方向。
public enum LyricTextDirection {
    /// 有方向的字母里从右往左的占多数就算从右往左;两边一样多时看第一个有方向的字母。数字、标点、空白、
    /// LRM / RLM 和双向嵌入、隔离控制符没有方向,跳过;一个有方向的字母都没有按从左往右。
    /// 别改回只看第一个字母:以拉丁词开头的阿拉伯文行会被判成从左往右(见 04 章决策 114)。
    public static func isRightToLeft(_ text: String) -> Bool {
        var rightToLeft = 0, leftToRight = 0
        var first: Bool?
        for s in text.unicodeScalars {
            if isStrongRightToLeft(s) {
                rightToLeft += 1
                if first == nil { first = true }
            } else if s.properties.isAlphabetic || s.properties.isIdeographic {
                leftToRight += 1
                if first == nil { first = false }
            }
        }
        return rightToLeft == leftToRight ? first ?? false : rightToLeft > leftToRight
    }

    /// 逐词单独排字时,这个词要不要显式按从右往左的段落方向排:整行从右往左、词里两种方向的字母都有时要
    /// (歌词源把一个拉丁词和一个阿拉伯词合成了一个计时词)。不定的话 CoreText 按词里第一个字母
    /// 把它排成从左往右,拉丁词落到阿拉伯词左边,整行读序就乱了。只有一种方向的词不定:交给 CoreText 按
    /// 第一个字母判,纯从右往左的词结果一样,纯拉丁词保持原样(见 04 章决策 115)。
    public static func wordNeedsRightToLeftBase(_ word: String, lineRightToLeft: Bool) -> Bool {
        guard lineRightToLeft else { return false }
        var rightToLeft = false, leftToRight = false
        for s in word.unicodeScalars {
            if isStrongRightToLeft(s) {
                rightToLeft = true
            } else if s.properties.isAlphabetic || s.properties.isIdeographic {
                leftToRight = true
            }
            if rightToLeft, leftToRight { return true }
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
