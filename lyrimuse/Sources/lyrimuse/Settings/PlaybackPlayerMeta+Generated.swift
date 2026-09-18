// 由 scripts/gen-players.py 从 shared/players.json 生成,请勿手改。
// 接一个新播放器:改那份 JSON → 跑 `python3 scripts/gen-players.py` → 补一张品牌图标。
// CI 跑 `--check` 对账,手改这里会红。
//
// 展示层的每播放器一行数据。类型本身在 LyrimuseCore(见 PlaybackPlayer+Generated.swift)
// —— MediaControlClient / LocalPlaybackSource 也要认它,而它们在被依赖的下层。

import SwiftUI

import LyrimuseCore

extension PlaybackPlayer {
    public var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .qqMusic: return L10n.t("QQ 音乐")
        case .netease: return L10n.t("网易云音乐")
        case .kugou: return L10n.t("酷狗音乐")
        case .spotify: return "Spotify"
        case .auto: return L10n.t("自动识别")
        }
    }

    /// 没装这个 App 时的占位色。品牌色跟「歌词来源」复用同一份(`sourceColor`)——
    /// 国内三家本来就是同一批 App,没理由维护第二份配色映射。
    public var tintColor: Color {
        switch self {
        case .appleMusic: return Color(red: 0.98, green: 0.2, blue: 0.35)
        case .qqMusic: return sourceColor("qq")
        case .netease: return sourceColor("netease")
        case .kugou: return sourceColor("kugou")
        case .spotify: return Color(red: 0.11, green: 0.73, blue: 0.33)
        case .auto: return .secondary
        }
    }

    public var fallbackSymbolName: String {
        switch self {
        case .appleMusic: return "music.note"
        case .qqMusic: return "music.note"
        case .netease: return "music.note"
        case .kugou: return "music.note"
        case .spotify: return "music.note"
        case .auto: return "wand.and.stars"
        }
    }

    /// 这台机器没装对应 App 时,`AppIconResolver.icon(bundledResourceName:)` 去找哪张
    /// 随包打包的品牌图。nil = 没有这一层,直接落到 tintColor + fallbackSymbolName。
    public var bundledIconResourceName: String? {
        switch self {
        case .appleMusic: return nil
        case .qqMusic: return "QQMusicIcon"
        case .netease: return "NeteaseIcon"
        case .kugou: return "KugouIcon"
        case .spotify: return "SpotifyIcon"
        case .auto: return nil
        }
    }

    public static let displayOrderForSimplifiedChinese: [PlaybackPlayer] = [.appleMusic, .qqMusic, .netease, .kugou, .spotify, .auto]

    public static let displayOrderDefault: [PlaybackPlayer] = [.appleMusic, .spotify, .qqMusic, .netease, .kugou, .auto]
}
