import Foundation

/// 歌词写回(把一首歌的歌词写进它的本地音频文件)在 App 一侧的判据:能不能写、Apple Music 的曲目写什么、引擎的错误码
/// 对应哪句文案。写入本身在引擎(lyricswriteback.go),见 11 章决策 162、163。
public enum LyricsWriteback {
    /// 写回支持的扩展名,跟引擎 lyricsWritebackFormats 一致。
    public static let supportedExtensions: Set<String> = ["mp3", "flac"]

    public static func supports(path: String) -> Bool {
        supportedExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// 写给这个播放器放的文件时只写歌词文字(去掉时间标签),跟引擎 writebackWantsPlainText 一致:Apple Music 把文件里的
    /// 歌词原样当纯文本显示。
    public static func wantsPlainText(player: String) -> Bool {
        player == PlaybackPlayer.appleMusic.bundleIdentifier
    }

    /// 菜单项为什么是灰的。
    public enum Unavailable: Equatable, Sendable {
        /// 这一首不是正在放的、或者没在放本地文件
        case notPlayingLocalFile
        /// 不是 MP3 / FLAC
        case unsupportedFormat
        /// 引擎查文件(probe_file_lyrics)报的错误码
        case engine(String)
    }

    /// 歌词管理里这一首的「写入歌曲文件…」能不能点:要是正在放的那首、放的是本地 MP3 / FLAC,引擎查过没报错
    /// (`probeError` 为 nil = 没查过或查过没问题)。
    public static func unavailable(isNowPlaying: Bool, file: NowPlayingLocalFile?, probeError: String?) -> Unavailable? {
        guard isNowPlaying, let file else { return .notPlayingLocalFile }
        guard supports(path: file.path) else { return .unsupportedFormat }
        if let probeError { return .engine(probeError) }
        return nil
    }

    /// 灰掉时悬停说明的 L10n 键。
    public static func reasonKey(_ reason: Unavailable) -> String {
        switch reason {
        case .notPlayingLocalFile: return "只能写入正在播放的本地 MP3 或 FLAC 文件"
        case .unsupportedFormat: return "目前只支持 MP3 和 FLAC 文件"
        case let .engine(code): return errorKey(code: code)
        }
    }

    /// 引擎错误码(lyricswriteback.go 的 wbErr…)→ 文案的 L10n 键;认不出的码交通用的一句。
    public static func errorKey(code: String) -> String {
        switch code {
        case "unsupported_format": return "目前只支持 MP3 和 FLAC 文件"
        case "unsupported_tag": return "这个文件的标签格式暂不支持写入"
        case "not_found": return "找不到这个文件"
        case "not_regular": return "这不是普通的音频文件"
        case "not_writable": return "没有写入这个文件的权限"
        case "read_only_volume": return "文件所在的磁盘是只读的"
        case "cloud_location": return "云盘里的文件暂不支持写入"
        case "network_location": return "网络位置上的文件暂不支持写入"
        case "hard_linked": return "这个文件有多个硬链接，写入会把它们拆开"
        case "file_changed": return "写入时文件被其他程序改动"
        case "audio_mismatch", "readback_mismatch", "tags_not_preserved": return "写入后的校验没有通过"
        case "no_lyrics": return "这首歌没有可写入的歌词"
        default: return "写入失败"
        }
    }

    /// 引擎会回的全部错误码,selftest 拿它跟引擎源码对拍。
    public static let engineErrorCodes: [String] = [
        "unsupported_format", "unsupported_tag", "not_found", "not_regular", "hard_linked", "not_writable",
        "read_only_volume", "cloud_location", "network_location", "file_has_lyrics", "no_lyrics", "no_file",
        "file_changed", "audio_mismatch", "readback_mismatch", "tags_not_preserved", "io",
    ]
}
