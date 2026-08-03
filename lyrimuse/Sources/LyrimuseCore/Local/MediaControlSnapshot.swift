import Foundation

// 镜像 `media-control get` 的 JSON 输出,只取本地播放数据源需要的那几个字段——
// collector/system.go 的 getState() 用的是同一条命令,同样只关心这几个字段。
public struct MediaControlSnapshot: Decodable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let duration: Double?
    public let elapsedTime: Double?
    public let playing: Bool?
    public let playbackRate: Double?
    // media-control 自己算好的"这个 Now Playing 会话是不是 Apple Music"标记——系统级
    // Now Playing 是任何注册了 MPNowPlayingInfoCenter 的 App 都能占用的(网页视频、
    // Safari/Chrome 里的播放器等),只有 Apple Music 才该算,不能把当前系统里随便谁在放
    // 的东西当成这个 App 的"正在播放"。
    public let isMusicApp: Bool?
    // 这次快照实际匹配到的播放器 bundle id——Apple Music 走 AppleScript 时 JS 脚本自己
    // 字面量给"com.apple.Music";QQ音乐/网易云音乐/Spotify/.auto 走 media-control 时是
    // 它自己报的 bundleIdentifier(见 fetchRawMediaControlSnapshot)。2026-08-03 补上——
    // 供 LocalPlaybackSource 判断"这次是不是 Spotify 在报告"(用于 Spotify 广告插播
    // 检测),不参与 trackKey/既有逻辑,纯附加信息。
    public let bundleIdentifier: String?

    public var trackKey: String { "\(artist ?? "")|\(title ?? "")" }
}
