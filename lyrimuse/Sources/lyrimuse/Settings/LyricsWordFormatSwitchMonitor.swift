import Foundation
import LyrimuseCore

/// 设置页「逐字歌词格式」那一行的切换反馈:先备份(选「删除原文件」时)、再等引擎把整库逐字文件按新格式重写
/// (`LyricsWordFormatSwitch` 的状态文件),做完显示「已改存」几秒再回到格式说明。
///
/// 单例:离开设置页再回来,正在进行的那一趟照样接着显示。只在等结论时每 0.25 秒读一次状态文件,平时不读。
/// 读和解在后台,上一次没读完不再派,回到主线程才判阶段(14 章决策 194)。
@MainActor
final class LyricsWordFormatSwitchMonitor: ObservableObject {
    static let shared = LyricsWordFormatSwitchMonitor()

    enum Display: Equatable {
        case idle
        case backingUp
        case phase(LyricsWordFormatSwitch.Phase)
    }

    @Published private(set) var display: Display = .idle
    /// 这一趟换成的格式(第一个是主格式),行里的文案用它。
    @Published private(set) var formats: [LyricsWordFormat] = []
    /// 这一趟删掉的副本格式(「同时存为」那行的「删除副本…」);空 = 换主格式。行里按它说「删除」还是「改存」。
    @Published private(set) var removing: [LyricsWordFormat] = []

    /// 「已改存」停多久再回到格式说明。
    static let finishedHold: TimeInterval = 4
    static let pollInterval: TimeInterval = 0.25
    /// 引擎没接手时最多再盯多久。
    static let queuedWatch: TimeInterval = 300

    private var requestedAt = Date()
    private var timer: Timer?
    private var generation = 0
    private let reads = SingleFlightBackgroundRead<LyricsWordFormatSwitch.Status?>()

    /// 正在备份或改存:下拉框锁住、旁边转圈。
    var isBusy: Bool {
        switch display {
        case .backingUp, .phase(.waiting), .phase(.converting): true
        case .idle, .phase(.finished), .phase(.queued): false
        }
    }

    private init() {}

    func beginBackup(to formats: [LyricsWordFormat], removing: [LyricsWordFormat] = []) {
        stop()
        self.formats = formats
        self.removing = removing
        display = .backingUp
    }

    /// 备份没写成、这次不改:回到平常的样子。
    func cancel() {
        stop()
        display = .idle
    }

    /// 设置已写进 features.json,开始等引擎。
    func requested(_ formats: [LyricsWordFormat], removing: [LyricsWordFormat] = []) {
        stop()
        self.formats = formats
        self.removing = removing
        requestedAt = Date()
        display = .phase(.waiting)
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { _ in
            Task { @MainActor in LyricsWordFormatSwitchMonitor.shared.poll() }
        }
    }

    /// `debug/word-format-switch`:把那一行摆到某一步,不读状态文件、不自己回到平常的样子。
    func simulate(_ display: Display, formats: [LyricsWordFormat], removing: [LyricsWordFormat] = []) {
        stop()
        self.formats = formats
        self.removing = removing
        self.display = display
    }

    private func poll() {
        let current = generation
        reads.start(read: { LyricsWordFormatSwitch.current }) { [weak self] status in
            guard let self, self.generation == current else { return }
            self.apply(status)
        }
    }

    private func apply(_ status: LyricsWordFormatSwitch.Status?) {
        let phase = LyricsWordFormatSwitch.phase(formats: formats.map(\.rawValue), status: status,
                                                 requestedAt: requestedAt, now: Date())
        if display != .phase(phase) { display = .phase(phase) }
        switch phase {
        case .finished:
            stop()
            let current = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.finishedHold) { [weak self] in
                guard let self, self.generation == current else { return }
                self.display = .idle
            }
        case .queued:
            // 引擎晚些起来还会接着做:再盯一阵,接上了照常显示进度。
            if Date().timeIntervalSince(requestedAt) > Self.queuedWatch { stop() }
        case .waiting, .converting:
            break
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        generation += 1
        reads.invalidate()
    }
}
