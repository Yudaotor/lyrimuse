import Combine
import Foundation
import LyrimuseCore

/// 收听里程碑:开播几秒后看一眼这首歌是第几次、账号累计第几次,碰上一档就让灵动岛报一次喜。
///
/// 次数都来自 `LastfmStatsService`:单曲用「第 N 次听」那个数(`nowPlayingCount`,写法族合并、已把正在放的这一次
/// 算进去),累计用引擎每 15 秒落盘的总数(`overview.total`,+1 = 正在放的这一次)。没连 Last.fm 不报。
/// 报不报还要过 `ListenMilestoneLedger` 那几道:一档只报一次、单曲每天最多两次、跨过太久的累计档不补。
///
/// 只由灵动岛控制器订阅(`NotchLyricsWindowController.milestoneObserver`),灵动岛没开过就不会被建出来;
/// 自己不引用控制器的单例(一读就会建出窗口)。
@MainActor
final class ListenMilestoneCenter: ObservableObject {
    static let shared = ListenMilestoneCenter()

    /// 此刻要报的那一条;nil = 没有。
    @Published private(set) var current: ListenMilestone?

    /// 开播多久后看次数:「第 N 次听」换歌时先拿历史表顶一个数,真取回来要一到几秒,等它落定再判。
    static let checkDelay: Duration = .seconds(8)
    /// 那次真取还没回来时,隔多久再看、最多再看几次。
    static let recheckDelay: Duration = .seconds(6)
    static let maxRechecks = 2
    /// 报喜面板停多久(指针停在卡片上时,控制器等它离开再收)。
    static let showDuration: Duration = .milliseconds(4_500)

    /// 报过哪几档、累计数上次看到多少。机器本地状态,在 `ConfigPortability.machineLocalDefaultsKeys` 里。
    private static let ledgerKey = "np:listenMilestoneLedger"

    private var trackObserver: AnyCancellable?
    private var checkTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    private init() {
        let playback = PlaybackCoordinator.shared
        // 换歌时歌名、歌手先后各发一次,攒一下再看,别拿「新歌名 + 旧歌手」去取一次次数。
        // 去抖挂主队列、别挂 RunLoop.main:菜单开着时它不走(见 01 章决策 11)。
        trackObserver = Publishers.CombineLatest(playback.$title, playback.$artist)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] title, artist in self?.trackChanged(title: title, artist: artist) }
    }

    private var enabled: Bool {
        let settings = AppSettings.shared
        return settings.notchOverlayEnabled && settings.notchListenMilestones
    }

    private func trackChanged(title: String, artist: String) {
        checkTask?.cancel()
        guard !title.isEmpty, enabled else { return }
        let stats = LastfmStatsService.shared
        guard stats.isConnected else { return }
        // 先把这首的「第 N 次听」取起来,到判的时候多半已经落定。
        stats.refreshNowPlayingCount(title: title, artist: artist)
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: Self.checkDelay)
            guard !Task.isCancelled else { return }
            self?.evaluate(title: title, artist: artist, rechecks: 0)
        }
    }

    private func evaluate(title: String, artist: String, rechecks: Int) {
        let playback = PlaybackCoordinator.shared
        guard enabled, playback.title == title, playback.artist == artist,
              playback.isPlayingSmoothed, !playback.isCurrentTrackAdBreak else { return }
        let stats = LastfmStatsService.shared
        guard stats.isConnected else { return }
        var ledger = loadLedger()
        // 累计先判:很稀,也不占单曲的每日名额。
        if let total = stats.overview?.total {
            let milestone = ledger.takeTotalMilestone(ordinal: total + 1)
            saveLedger(ledger)
            if let milestone {
                show(ListenMilestone(kind: .total, count: milestone, title: title, artist: artist))
                return
            }
        }
        guard let count = stats.nowPlayingCount else {
            guard rechecks < Self.maxRechecks else { return }
            checkTask = Task { [weak self] in
                try? await Task.sleep(for: Self.recheckDelay)
                guard !Task.isCancelled else { return }
                self?.evaluate(title: title, artist: artist, rechecks: rechecks + 1)
            }
            return
        }
        guard ListenMilestoneRules.isTrackMilestone(count) else { return }
        let key = ListenMilestoneLedger.trackKey(familyKey: PlayCountFold.familyKey(artist: artist, title: title),
                                                 count: count)
        let today = Self.dayString(Date())
        guard ledger.allowsTrack(key, today: today) else { return }
        ledger.recordTrack(key, today: today)
        saveLedger(ledger)
        show(ListenMilestone(kind: .track, count: count, title: title, artist: artist))
    }

    /// 「试一下」:拿正在放的歌摆一次「第 100 次听」,不记账。
    func preview() {
        let playback = PlaybackCoordinator.shared
        let title = playback.title.isEmpty ? "Lyrimuse" : playback.title
        show(ListenMilestone(kind: .track, count: 100, title: title, artist: playback.artist))
    }

    private func show(_ milestone: ListenMilestone) {
        dismissTask?.cancel()
        current = milestone
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.showDuration)
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }

    private func loadLedger() -> ListenMilestoneLedger {
        guard let data = UserDefaults.standard.data(forKey: Self.ledgerKey),
              let ledger = try? JSONDecoder().decode(ListenMilestoneLedger.self, from: data)
        else { return ListenMilestoneLedger() }
        return ledger
    }

    private func saveLedger(_ ledger: ListenMilestoneLedger) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        UserDefaults.standard.set(data, forKey: Self.ledgerKey)
    }

    private static func dayString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
