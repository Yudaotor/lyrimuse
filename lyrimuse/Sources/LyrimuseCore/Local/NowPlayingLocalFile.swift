import Combine
import Foundation

/// 正在放的这首对应的本地音频文件和放它的播放器。真实播放时跟写给引擎的播放状态(`local_file`)同一份,
/// 模拟播放时取 `debug/simulate?file=`。歌词管理「写入歌曲文件」据此判断能不能写、写到哪。
public struct NowPlayingLocalFile: Equatable, Sendable {
    public var player: String
    public var path: String

    public init(player: String, path: String) {
        self.player = player
        self.path = path
    }
}

@MainActor
public final class NowPlayingLocalFileModel: ObservableObject {
    public static let shared = NowPlayingLocalFileModel()

    @Published public private(set) var current: NowPlayingLocalFile?

    public init() {}

    public func update(_ file: NowPlayingLocalFile?) {
        if file != current { current = file }
    }
}
