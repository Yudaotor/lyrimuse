import CryptoKit
import Foundation

/// 歌词窗口「用外部编辑器改歌词」的判据(07 章决策 112):工作副本里摊开什么、编辑器存回来的文本怎么套回这首歌、
/// 打开时盘上已有的工作副本能不能覆盖。写文件、开编辑器、盯文件、交给引擎存在 App 侧(LyricsExternalEditor)。
public enum LyricsExternalEdit {
    /// 条目里存着的三块正文。工作副本只摊开它们;译文、读音保存时原样交回。
    public struct Content: Equatable, Sendable {
        public var lyrics: String
        public var yrc: String
        public var plain: String

        public init(lyrics: String = "", yrc: String = "", plain: String = "") {
            self.lyrics = lyrics
            self.yrc = yrc
            self.plain = plain
        }
    }

    /// 这首的歌词是哪一种,决定摊开什么、存回来怎么套。
    public enum Mode: Equatable, Sendable {
        /// 有逐字:摊开逐字拼出来的每一行,存回来只改字(`LyricsWordTimingEdit`)。
        case wordTimed
        /// 有整行歌词、没有逐字:原样摊开,存回来整份换掉。
        case lineTimed
        /// 只有纯文本。
        case plainText
        /// 没有歌词(标了纯音乐、条目里也没留词的也是这一种)。
        case empty
    }

    public static func mode(of content: Content) -> Mode {
        if LyricsWordTimingEdit.hasWordLines(content.yrc) { return .wordTimed }
        if !isBlank(content.lyrics) { return .lineTimed }
        if !isBlank(content.plain) { return .plainText }
        return .empty
    }

    /// 工作副本。整行歌词原样;另外三种开头是歌名 / 歌手 / 专辑三行文件头,在编辑器里认得出是哪一首。
    public static func workingCopy(_ content: Content, title: String, artist: String, album: String) -> String {
        let head = header(title: title, artist: artist, album: album)
        switch mode(of: content) {
        case .wordTimed:
            return head + LyricsWordTimingEdit.editableText(yrc: content.yrc) + "\n"
        case .lineTimed:
            return content.lyrics
        case .plainText:
            return head + content.plain + (content.plain.hasSuffix("\n") ? "" : "\n")
        case .empty:
            return head
        }
    }

    /// `[ti:]` / `[ar:]` / `[al:]`,空的那项不写;有内容时后面空一行。
    static func header(title: String, artist: String, album: String) -> String {
        var lines: [String] = []
        for (tag, value) in [("ti", title), ("ar", artist), ("al", album)] {
            let flat = value.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !flat.isEmpty { lines.append("[\(tag):\(flat)]") }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n\n"
    }

    /// 编辑器存回来的文本怎么办。
    public enum Decision: Equatable, Sendable {
        /// 跟摊开的那一份没有要存的区别。
        case unchanged
        /// 没有歌词(空文件、只剩文件头):不算录入了歌词,不存,纯音乐标记也不动。
        case empty
        /// 原来带时间轴,存回来的一行时间戳都没有:整份换掉会丢掉时间轴,不存。
        case missingTimestamps
        /// 逐字只改字的结果。
        case word(LyricsWordTimingEdit.Result)
        /// 整行歌词换成这一份。
        case lines(String)
        /// 存成纯文本。
        case plain(String)
    }

    /// 存回来的 `edited`(开头的 BOM 已经去掉)对着摊开时那一份 `base` 怎么套。
    public static func decide(edited: String, base: Content) -> Decision {
        guard hasLyricText(edited) else { return .empty }
        let timed = hasTimedLines(edited)
        switch mode(of: base) {
        case .wordTimed:
            guard timed else { return .missingTimestamps }
            let result = LyricsWordTimingEdit.apply(edited: edited, yrc: base.yrc, lrc: base.lyrics)
            return result.changedLines + result.estimatedLines + result.removedLines == 0 ? .unchanged : .word(result)
        case .lineTimed:
            if sameIgnoringTrailingWhitespace(edited, base.lyrics) { return .unchanged }
            if !timed, hasTimedLines(base.lyrics) { return .missingTimestamps }
            return .lines(edited)
        case .plainText, .empty:
            if timed { return .lines(edited) }
            let body = plainBody(edited)
            return sameIgnoringTrailingWhitespace(body, plainBody(base.plain)) ? .unchanged : .plain(body)
        }
    }

    /// 两份文本只差行尾空白和末尾的空行。编辑器存盘时常顺手补上文件末尾的换行、删掉行尾空格(Vim、Zed 默认都这样),
    /// 这类差别不算改过:算成改过的话,一次什么都没动的保存也会把这首存成人工修正、锁住,还清掉「手动选定」的记号。
    static func sameIgnoringTrailingWhitespace(_ a: String, _ b: String) -> Bool {
        trailingWhitespaceTrimmed(a) == trailingWhitespaceTrimmed(b)
    }

    private static func trailingWhitespaceTrimmed(_ text: String) -> [String] {
        var out = lines(text).map(LyricsWordTimingEdit.trimmingTrailingWhitespace)
        while out.last?.isEmpty == true { out.removeLast() }
        return out
    }

    /// 有没有一行剥掉开头的 `[...]`(时间戳、文件头标签)之后还有字。
    static func hasLyricText(_ text: String) -> Bool {
        lines(text).contains { !isBlank(String(afterBrackets($0))) }
    }

    /// 有没有一行是时间戳开头、后面跟着字。
    static func hasTimedLines(_ text: String) -> Bool {
        lines(text).contains { line in
            let trimmed = String(line.drop { $0.isWhitespace })
            guard let stamps = LyricsWordTimingEdit.leadingStamps(trimmed) else { return false }
            return !isBlank(String(trimmed[stamps.end...]))
        }
    }

    /// 纯文本正文:去掉开头的文件头标签行和头尾空行,行尾的 `\r` 去掉。
    static func plainBody(_ text: String) -> String {
        var out = lines(text).map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        while let first = out.first, isBlank(first) || LyricsWordTimingEdit.isHeaderTag(first) { out.removeFirst() }
        while let last = out.last, isBlank(last) { out.removeLast() }
        return out.joined(separator: "\n")
    }

    private static func afterBrackets(_ line: String) -> Substring {
        var body = Substring(line).drop { $0.isWhitespace }
        while body.first == "[", let end = body.firstIndex(of: "]") {
            body = body[body.index(after: end)...].drop { $0.isWhitespace }
        }
        return body
    }

    private static func lines(_ text: String) -> [String] {
        text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 工作副本文件

    /// 打开时盘上已有工作副本怎么办。
    public enum FileAction: Equatable, Sendable {
        /// 没有,或者盘上那份是写进去 / 套用过的:写这一份。
        case write
        /// 盘上那份就是要写的这一份。
        case reuse
        /// 盘上那份是在编辑器里存过、还没套用的修改:先挪开另存,再写这一份。
        case setAsideThenWrite
    }

    /// `existing` 是盘上那份(nil = 没有),`recorded` 是上次写进去或套用过的那份的指纹(`fingerprint`)。
    public static func fileAction(existing: String?, fresh: String, recorded: String?) -> FileAction {
        guard let existing else { return .write }
        if existing == fresh { return .reuse }
        if let recorded, fingerprint(existing) == recorded { return .write }
        return .setAsideThenWrite
    }

    public static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// 编辑器存下来的字节 → 文本。UTF-8(开头的 BOM 由 Foundation 去掉),带 BOM 的 UTF-16 也认;都不是返回 nil。
    public static func text(from data: Data) -> String? {
        let bytes = [UInt8](data.prefix(2))
        if bytes == [0xFF, 0xFE] || bytes == [0xFE, 0xFF] {
            guard let text = String(data: data, encoding: .utf16) else { return nil }
            return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        }
        return String(data: data, encoding: .utf8)
    }
}
