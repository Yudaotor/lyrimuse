import Foundation
import LyrimuseCore

/// 设置页「网页推送」状态的数据源。设置窗口看得见时每 5 秒重读一次引擎的状态文件(按 mtime 缓存,常态代价是一次 stat),
/// 判定变了才发布。要定时重读的理由同 LastfmMirrorStatusWatcher:引擎删掉文件不在 SwiftUI 的观察体系里;
/// 另外暂时性的失败要持续一阵才报(RelayPushStatus.transientGrace),判定本身也随时间变。
/// 只有设置页用它,定时重读挂在侧栏的 `LabsSidebarRow` 上(`settingsPolling`,窗口看不见就停),自己不起定时器。
/// 见 14 章决策 126。读文件在后台,回到主线程才判定、发布(14 章决策 194)。
@MainActor
final class RelayPushStatusWatcher: ObservableObject {
    static let shared = RelayPushStatusWatcher()

    @Published private(set) var verdict: RelayPushStatus.Verdict = .ok

    private let file = MTimeCachedFile(url: LyrimusePaths.configFile(RelayPushStatus.fileName), parse: RelayPushStatus.parse)
    private let reads = SingleFlightBackgroundRead<RelayPushStatus.Info?>()

    private init() {
        refresh()
    }

    func refresh() {
        let file = self.file
        reads.start(read: { file.read() }) { [weak self] info in
            guard let self else { return }
            let next = RelayPushStatus.verdict(info, now: Date())
            if next != self.verdict { self.verdict = next }
        }
    }
}
