import Foundation
import LyrimuseCore

/// 设置页「网页推送」状态的数据源。每 5 秒重读一次引擎的状态文件(按 mtime 缓存,常态代价是一次 stat),
/// 判定变了才发布。要定时重读的理由同 LastfmMirrorStatusWatcher:引擎删掉文件不在 SwiftUI 的观察体系里;
/// 另外暂时性的失败要持续一阵才报(RelayPushStatus.transientGrace),判定本身也随时间变。
final class RelayPushStatusWatcher: ObservableObject {
    static let shared = RelayPushStatusWatcher()

    @Published private(set) var verdict: RelayPushStatus.Verdict = .ok

    private let url = LyrimusePaths.configFile(RelayPushStatus.fileName)
    private var cachedMTime: Date?
    private var cached: RelayPushStatus.Info?
    private var timer: Timer?

    private init() {
        refresh()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        let next = RelayPushStatus.verdict(currentInfo(), now: Date())
        if next != verdict { verdict = next }
    }

    private func currentInfo() -> RelayPushStatus.Info? {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard let mtime else {
            cachedMTime = nil
            cached = nil
            return nil
        }
        if mtime == cachedMTime { return cached }
        cachedMTime = mtime
        cached = FileIO.read(url).flatMap(RelayPushStatus.parse)
        return cached
    }
}
