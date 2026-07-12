import Foundation

// 镜像 state-worker /now 端点的响应形状(见 state-worker/src/index.js 的 fromLB()/`/now`
// 处理逻辑)。字段名跟 JSON key 完全一致,不用自定义 CodingKeys。
public struct NowPlayingState: Codable, Equatable {
    public struct Links: Codable, Equatable {
        public let apple: String?
        public let qq: String?
        public let netease: String?
        public let spotify: String?
    }

    public let ok: Bool?
    public let empty: Bool?
    public let title: String?
    public let artist: String?
    public let album: String?
    public let playing: Bool?
    public let listenedAt: Int?
    public let artwork: String?
    public let accent: String?
    public let device: String?
    public let lyrics: String?
    public let lyricsTr: String?
    public let lyricsRoma: String?
    public let lyricsYRC: String?
    public let coverSource: String?
    public let lyricsSource: String?
    public let links: Links?
    public let durationMs: Int?
    public let progressMs: Int?
    public let progressTs: Int?
    public let rate: Double?
    public let ageMs: Int?
    public let source: String?

    public var trackKey: String { "\(artist ?? "")|\(title ?? "")" }
}
