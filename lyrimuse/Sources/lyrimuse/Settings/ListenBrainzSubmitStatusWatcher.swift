import Foundation
import LyrimuseCore

/// 设置页「ListenBrainz」令牌被拒红标、`ListenBrainzAuthNotifier` 的数据源。每 5 秒重读一次引擎的状态文件(按 mtime 缓存,
/// 常态代价是一次 stat),变了才发布。要定时重读的理由同 LastfmMirrorStatusWatcher:引擎删掉文件不在 SwiftUI 的观察体系里。
final class ListenBrainzSubmitStatusWatcher: ObservableObject {
    static let shared = ListenBrainzSubmitStatusWatcher()

    @Published private(set) var info: ListenBrainzSubmitStatus.Info?

    private let url = LyrimusePaths.configFile(ListenBrainzSubmitStatus.fileName)
    private var cachedMTime: Date?
    private var cached: ListenBrainzSubmitStatus.Info?
    private var timer: Timer?

    private init() {
        refresh()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        let next = currentInfo()
        if next != info { info = next }
    }

    private func currentInfo() -> ListenBrainzSubmitStatus.Info? {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard let mtime else {
            cachedMTime = nil
            cached = nil
            return nil
        }
        if mtime == cachedMTime { return cached }
        cachedMTime = mtime
        cached = FileIO.read(url).flatMap(ListenBrainzSubmitStatus.parse)
        return cached
    }
}
