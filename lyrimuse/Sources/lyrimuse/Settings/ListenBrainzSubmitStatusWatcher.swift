import Foundation
import LyrimuseCore

/// 设置页「ListenBrainz」令牌被拒红标、`ListenBrainzAuthNotifier` 的数据源。每 5 秒重读一次引擎的状态文件(按 mtime 缓存,
/// 常态代价是一次 stat),变了才发布。要定时重读的理由同 LastfmMirrorStatusWatcher:引擎删掉文件不在 SwiftUI 的观察体系里。
///
/// 读文件在后台,回到主线程才发布(14 章决策 194)。第一次读完之前 `info` 是 nil、`loaded` 是 false;
/// 要区分「没读到」和「读过、没被拒」的(系统通知)看 `loaded`。
@MainActor
final class ListenBrainzSubmitStatusWatcher: ObservableObject {
    static let shared = ListenBrainzSubmitStatusWatcher()

    @Published private(set) var info: ListenBrainzSubmitStatus.Info?
    /// 第一次后台读已经落下。
    @Published private(set) var loaded = false

    private let file = MTimeCachedFile(url: LyrimusePaths.configFile(ListenBrainzSubmitStatus.fileName),
                                       parse: ListenBrainzSubmitStatus.parse)
    private let reads = SingleFlightBackgroundRead<ListenBrainzSubmitStatus.Info?>()
    private var timer: Timer?

    private init() {
        refresh()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 在后台重读一次,读完值变了才发布;上一次还没读完就什么都不做。
    func refresh() {
        let file = self.file
        reads.start(read: { file.read() }) { [weak self] next in
            guard let self else { return }
            if next != self.info { self.info = next }
            if !self.loaded { self.loaded = true }
        }
    }
}
