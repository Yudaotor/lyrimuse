import Foundation

/// 「歌词管理」保存修改之前的核对:编辑缓冲是打开这一页时载入的,这期间引擎可能补了机翻、重新打分换了词。
/// 用户没动的那几格交盘上此刻的值就行;动过的那几格要是盘上也变了,交上去就会把新内容静默盖掉、还置成人工修正,
/// 这时不存,让用户重新打开最新的那份再改(同歌词窗口外部编辑器那条检查)。
public enum LyricsEditConflict {
    /// 条目里的四块正文。逐字只认有能摊开的逐字行的那份(`LyricsWordTimingEdit.hasWordLines`),没有时当空。
    public struct Cells: Equatable, Sendable {
        public var lyrics: String
        public var yrc: String
        public var tr: String
        public var roma: String

        public init(lyrics: String = "", yrc: String = "", tr: String = "", roma: String = "") {
            self.lyrics = lyrics
            self.yrc = yrc
            self.tr = tr
            self.roma = roma
        }
    }

    /// 用户改过哪几格。`main` = 整行歌词或逐字的文字。
    public struct Edits: Equatable, Sendable {
        public var main: Bool
        public var tr: Bool
        public var roma: Bool

        public init(main: Bool = false, tr: Bool = false, roma: Bool = false) {
            self.main = main
            self.tr = tr
            self.roma = roma
        }
    }

    /// true = 不能存:正文(整行或逐字)在盘上变了而用户改了任何一格(译文、读音按句对着正文,改的是旧正文那一份),
    /// 或者用户改过的译文 / 读音在盘上也变了。什么都没改时不算冲突。
    public static func conflicts(loaded: Cells, disk: Cells, edits: Edits) -> Bool {
        let mainChanged = loaded.lyrics != disk.lyrics || wordYRC(loaded.yrc) != wordYRC(disk.yrc)
        if mainChanged, edits.main || edits.tr || edits.roma { return true }
        if edits.tr, loaded.tr != disk.tr { return true }
        if edits.roma, loaded.roma != disk.roma { return true }
        return false
    }

    private static func wordYRC(_ yrc: String) -> String {
        LyricsWordTimingEdit.hasWordLines(yrc) ? yrc : ""
    }
}
