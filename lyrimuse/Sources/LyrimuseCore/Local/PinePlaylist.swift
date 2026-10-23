import ApplicationServices
import Foundation

/// Pine Player 的播放列表,给引擎预解析(`PlayerQueryServer` 的 `pine_queue`,引擎侧 `pinequeue.go`)。它没有脚本接口、列表不落盘,
/// 只有主窗口里那张表:每行一格,格里依次是歌名(`AXHelp` 是文件名)、「歌手 ∙ 专辑」、封面、时长。看不见的行辅助功能树里照样有、
/// 文字齐全。随机开着时列表不重排、跳着放,开没开读不出,由引擎按换歌行为推断;循环档读菜单的勾(`PineMenuControl`)。
/// 每行的歌名歌手按系统那份的拆法换(`PinePlayerInfo.identity(title:artist:)`),跟这首真播到时写进播放状态的是同一份。
/// 跨进程读一行约 3 毫秒、占它的主线程,最多读 `maxRows` 行、到 `readBudget` 为止。见 02 章决策 168。
public enum PinePlaylist {
    public static let maxRows = 500
    public static let readBudget: TimeInterval = 4

    /// 表里一行的原文。
    public struct Row: Equatable, Sendable {
        public var title: String
        public var artistAlbum: String
        public var duration: String
        public var fileName: String

        public init(title: String, artistAlbum: String, duration: String, fileName: String) {
            self.title = title
            self.artistAlbum = artistAlbum
            self.duration = duration
            self.fileName = fileName
        }
    }

    public struct Track: Codable, Equatable, Sendable {
        public var title: String
        public var artist: String
        public var album: String
        /// 秒,0 = 读不出。
        public var duration: Double
        public var file: String

        public init(title: String, artist: String, album: String, duration: Double, file: String) {
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = duration
            self.file = file
        }
    }

    /// 交给引擎的那份;`repeating` 是 `off` / `one` / `all`(同 `PlayerQueryRepeat`),读不出为 nil。
    public struct QueueReply: Codable, Equatable, Sendable {
        public var tracks: [Track]
        public var repeating: String?

        public init(tracks: [Track], repeating: String?) {
            self.tracks = tracks
            self.repeating = repeating
        }
    }

    /// 一行换成曲目。纯函数,selftest 覆盖。
    public static func track(_ row: Row) -> Track {
        let id = PinePlayerInfo.identity(title: row.title, artist: row.artistAlbum)
        return Track(title: id.title, artist: id.artist, album: id.album, duration: duration(row.duration) ?? 0, file: row.fileName)
    }

    /// 「03:39」「1:02:03」→ 秒。纯函数,selftest 覆盖。
    public static func duration(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0
        for part in parts {
            guard let v = Int(part), v >= 0 else { return nil }
            total = total * 60 + v
        }
        return Double(total)
    }

    /// 档位 → 交给引擎的写法。纯函数,selftest 覆盖。
    public static func repeating(_ mode: MusicPlaybackController.MusicPlaybackMode?) -> String? {
        switch mode {
        case .list: return "off"
        case .repeatOne: return "one"
        case .repeatAll: return "all"
        case .shuffle, nil: return nil
        }
    }

    /// 读列表与循环档;Pine 没在跑、没有辅助功能权限、找不到那张表时为 nil。会阻塞跨进程查询,别在主线程调。
    public static func queueReply() -> QueueReply? {
        guard let rows = readRows() else { return nil }
        return QueueReply(tracks: rows.map(track), repeating: repeating(PineMenuControl.readMode()))
    }

    /// 主窗口里那张表的行(格里至少三段文字的那张;侧栏的列表表每格只有一段)。
    static func readRows() -> [Row]? {
        guard let app = MenuBarAX.application(bundleID: PinePlayerInfo.bundleID) else { return nil }
        let deadline = Date().addingTimeInterval(readBudget)
        for window in MenuBarAX.children(app, attribute: kAXWindowsAttribute) {
            for area in MenuBarAX.children(window) where MenuBarAX.string(area, kAXRoleAttribute) == kAXScrollAreaRole {
                for table in MenuBarAX.children(area) where MenuBarAX.string(table, kAXRoleAttribute) == kAXTableRole {
                    let rows = MenuBarAX.children(table, attribute: kAXRowsAttribute)
                    guard let first = rows.first, let firstRow = row(first) else { continue }
                    var out = [firstRow]
                    for element in rows.dropFirst().prefix(maxRows - 1) {
                        guard Date() < deadline else { break }
                        if let r = row(element) { out.append(r) }
                    }
                    return out
                }
            }
        }
        return nil
    }

    /// 一行:格里的文字依次是歌名(`AXHelp` 是文件名)、「歌手 ∙ 专辑」,最后一段是时长;不到三段为 nil。
    private static func row(_ element: AXUIElement) -> Row? {
        guard let cell = MenuBarAX.children(element).first else { return nil }
        var texts: [(value: String, help: String)] = []
        for child in MenuBarAX.children(cell) {
            var values: CFArray?
            let names = [kAXRoleAttribute, kAXValueAttribute, kAXHelpAttribute] as CFArray
            guard AXUIElementCopyMultipleAttributeValues(child, names, [], &values) == .success,
                  let list = values as? [AnyObject], list.count == 3,
                  (list[0] as? String) == kAXStaticTextRole else { continue }
            texts.append(((list[1] as? String) ?? "", (list[2] as? String) ?? ""))
        }
        guard texts.count >= 3, let last = texts.last else { return nil }
        return Row(title: texts[0].value, artistAlbum: texts[1].value, duration: last.value, fileName: texts[0].help)
    }
}
