import Foundation

/// 面板格子这类窄位置上的标题能不能折成两行。
/// 中日文标题没有空格时，折行会落在任意两个字之间（会把一个词拆开），这类标题只放一行、靠缩字放下；
/// 带空格或连字符的标题（英文、德文、韩文）按词折行。
public enum TileTitleWrap {
    public static func breaksInsideWords(_ title: String) -> Bool {
        if title.contains(where: { $0.isWhitespace }) { return false }
        return title.unicodeScalars.contains { s in
            switch s.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return true
            default: return false
            }
        }
    }

    /// 标题没有空白、又含泰、老挝、高棉、缅甸文:系统按词典断行,复合词(แถบ|เมนู)也会被拆到两行。
    /// 这类标题先试一行(字号可缩到八成),放不下再按词典折行(见 06 章决策 97)。
    public static func prefersOneLine(_ title: String) -> Bool {
        !title.contains(where: \.isWhitespace) && title.unicodeScalars.contains { s in
            switch s.value {
            case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF: return true
            default: return false
            }
        }
    }

    /// 设置行标题是不是一个按空格分词的单词(拉丁、西里尔字母这类,不含空白):是的话只排一行、放不下就缩字,
    /// 否则 SwiftUI 会把这个词从中间拆开折行。中日韩字和泰、老挝、高棉、缅甸文词间本来就不写空格,
    /// 没有空白也可能是一整句,不算,交给系统按词典断行。
    public static func isSingleSpacedWord(_ title: String) -> Bool {
        !title.isEmpty && !title.contains(where: \.isWhitespace) && title.unicodeScalars.allSatisfy { s in
            switch s.value {
            case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, 0x2E80...: return false
            default: return true
            }
        }
    }
}
