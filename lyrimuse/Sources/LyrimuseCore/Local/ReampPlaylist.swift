import Foundation

/// reAMP 的播放列表,给引擎预解析(`PlayerQueryServer` 的 `reamp_queue`,引擎侧 `reampqueue.go`)。reAMP 把列表存在
/// `~/Library/Application Support/Reamp/playlist.m3u`(不在沙盒容器里,不要权限),但只在退出时写:文件是上次退出时的列表,
/// reAMP 重开会恢复它,这一轮换过列表就对不上 —— 引擎按当前文件在里面找不到就退回同专辑预取。每个文件的歌名歌手按认当前这首
/// 那一套换(`PlayerTitleSplit.identity(from:)`,没写歌名的按文件名拆),跟真放到时写进播放状态的是同一份;随机 / 循环读它菜单里的
/// 勾(`ReampMenuControl`,是此刻的,同目录 `config` 里那两个开关也是退出时才写)。交出去的形状同 Pine 那份(`PinePlaylist.QueueReply`)。
/// 见 02 章决策 175。
public enum ReampPlaylist {
    public static let maxTracks = 500

    public static var playlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Reamp/playlist.m3u")
    }

    /// m3u 正文 → 本地文件路径(绝对路径或 `file://` 地址;注释、空行、网络地址跳过),最多 `maxTracks` 条。纯函数,selftest 覆盖。
    public static func paths(m3u: String) -> [String] {
        var out: [String] = []
        for raw in m3u.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("/") {
                out.append(line)
            } else if line.hasPrefix("file://"), let url = URL(string: line), url.isFileURL {
                out.append(url.path)
            } else {
                continue
            }
            if out.count == maxTracks { break }
        }
        return out
    }

    /// 一个文件 → 曲目:标签里有歌名的用标签(乱码还原);没有的照 reAMP 报文件名的样子拆。`file` 交完整路径:引擎按它认当前这首,
    /// 也按它读待播文件的标签(`neteasefilekey.go`)。`tags` 为 nil = 读不出。纯函数,selftest 覆盖。
    public static func track(path: String, tags: LocalAudioFileTags?) -> PinePlaylist.Track {
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        if let tags, let id = PlayerTitleSplit.identity(from: tags) {
            return PinePlaylist.Track(title: id.title, artist: id.artist, album: id.album, duration: id.duration ?? 0, file: path)
        }
        let split = PlayerTitleSplit.split(bundleID: PlaybackPlayer.reamp.bundleIdentifier, title: fileName, artist: nil)
        return PinePlaylist.Track(title: split?.title ?? fileName, artist: split?.artist ?? "", album: "",
                                  duration: tags?.duration ?? 0, file: path)
    }

    /// 菜单里的档 → 交给引擎的写法:开着随机交 `shuffle`(随机优先,这时读不出循环),列表循环 `all`,都关 `off`;读不出为 nil。
    /// 纯函数,selftest 覆盖。
    public static func repeating(_ mode: MusicPlaybackController.MusicPlaybackMode?) -> String? {
        switch mode {
        case .shuffle?: return "shuffle"
        case .repeatAll?: return "all"
        case .list?: return "off"
        case .repeatOne?, nil: return nil
        }
    }

    /// 读列表与菜单里的档;没有列表文件、一首都没有时为 nil。会读盘、阻塞一次跨进程查询,别在主线程调。
    public static func queueReply() -> PinePlaylist.QueueReply? {
        guard let text = FileIO.readString(playlistURL) else { return nil }
        let files = paths(m3u: text)
        guard !files.isEmpty else { return nil }
        let tracks = files.map { track(path: $0, tags: LocalAudioFileTags.read(path: $0)) }
        return PinePlaylist.QueueReply(tracks: tracks, repeating: repeating(ReampMenuControl.readMode()))
    }
}
