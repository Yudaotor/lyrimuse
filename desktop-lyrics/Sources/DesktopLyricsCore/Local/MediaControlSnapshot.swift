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

    public var trackKey: String { "\(artist ?? "")|\(title ?? "")" }
}
