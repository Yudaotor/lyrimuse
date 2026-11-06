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
        case .soda: return L10n.t("汽水音乐")
        case .kkbox: return "KKBOX"
        case .spotify: return "Spotify"
        case .amazonMusic: return "Amazon Music"
        case .kaset: return "Kaset"
        case .pearDesktop: return "Pear Desktop"
        case .reamp: return "reAMP"
        case .lxMusic: return L10n.t("洛雪音乐")
        case .vox: return "VOX"
        case .pinePlayer: return "Pine Player"
        case .foobar2000: return "foobar2000"
        case .swinsian: return "Swinsian"
        case .weread: return L10n.t("微信读书")
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
        case .soda: return Color(red: 0.3, green: 0.85, blue: 0.35)
        case .kkbox: return Color(red: 0.0, green: 0.85, blue: 0.97)
        case .spotify: return Color(red: 0.11, green: 0.73, blue: 0.33)
        case .amazonMusic: return Color(red: 0.12, green: 0.85, blue: 0.88)
        case .kaset: return Color(red: 0.94, green: 0.12, blue: 0.36)
        case .pearDesktop: return Color(red: 0.94, green: 0.27, blue: 0.4)
        case .reamp: return Color(red: 1.0, green: 0.58, blue: 0.0)
        case .lxMusic: return Color(red: 0.37, green: 0.84, blue: 0.6)
        case .vox: return Color(red: 0.96, green: 0.62, blue: 0.07)
        case .pinePlayer: return Color(red: 0.36, green: 0.66, blue: 0.24)
        case .foobar2000: return Color(red: 0.6, green: 0.6, blue: 0.62)
        case .swinsian: return Color(red: 0.95, green: 0.67, blue: 0.13)
        case .weread: return Color(red: 0.16, green: 0.6, blue: 0.98)
        case .auto: return .secondary
        }
    }

    public var fallbackSymbolName: String {
        switch self {
        case .appleMusic: return "music.note"
        case .qqMusic: return "music.note"
        case .netease: return "music.note"
        case .kugou: return "music.note"
        case .soda: return "music.note"
        case .kkbox: return "music.note"
        case .spotify: return "music.note"
        case .amazonMusic: return "music.note"
        case .kaset: return "music.note"
        case .pearDesktop: return "music.note"
        case .reamp: return "music.note"
        case .lxMusic: return "music.note"
        case .vox: return "hifispeaker"
        case .pinePlayer: return "music.note"
        case .foobar2000: return "music.note"
        case .swinsian: return "waveform"
        case .weread: return "book"
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
        case .soda: return "SodaMusicIcon"
        case .kkbox: return "KKBOXIcon"
        case .spotify: return "SpotifyIcon"
        case .amazonMusic: return "AmazonMusicIcon"
        case .kaset: return "KasetIcon"
        case .pearDesktop: return "PearDesktopIcon"
        case .reamp: return "ReampIcon"
        case .lxMusic: return "LXMusicIcon"
        case .vox: return "VoxIcon"
        case .pinePlayer: return "PinePlayerIcon"
        case .foobar2000: return "Foobar2000Icon"
        case .swinsian: return "SwinsianIcon"
        case .weread: return "WeReadIcon"
        case .auto: return nil
        }
    }

    public static let displayOrderForSimplifiedChinese: [PlaybackPlayer] = [.appleMusic, .qqMusic, .netease, .kugou, .soda, .lxMusic, .kkbox, .spotify, .amazonMusic, .kaset, .pearDesktop, .reamp, .vox, .pinePlayer, .foobar2000, .swinsian, .weread, .auto]

    public static let displayOrderDefault: [PlaybackPlayer] = [.appleMusic, .spotify, .amazonMusic, .kaset, .pearDesktop, .kkbox, .qqMusic, .netease, .kugou, .soda, .lxMusic, .reamp, .vox, .pinePlayer, .foobar2000, .swinsian, .weread, .auto]
}
