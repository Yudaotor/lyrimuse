import Foundation

// 镜像 `media-control get` 的 JSON 输出(已实测确认字段名),只取本地播放数据源需要的
// 那几个——collector/system.go 的 getState() 用的是同一条命令,同样只关心这几个字段。
public struct MediaControlSnapshot: Decodable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let duration: Double?
    public let elapsedTime: Double?
    public let playing: Bool?
    public let playbackRate: Double?
    // media-control 自己算好的"这个 Now Playing 会话是不是 Apple Music"标记(已实测
    // 确认真实字段名/取值)——系统级 Now Playing 是任何注册了 MPNowPlayingInfoCenter 的
    // App 都能占用的(网页视频、Safari/Chrome 里的播放器等),用户反馈"只有 Apple Music
    // 才该算",不能不分青红皂白地把当前系统里随便谁在放的东西当成这个 App 的"正在播放"。
    public let isMusicApp: Bool?

    public var trackKey: String { "\(artist ?? "")|\(title ?? "")" }
}
