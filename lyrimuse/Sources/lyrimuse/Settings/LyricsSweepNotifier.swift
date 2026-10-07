import AppKit
import LyrimuseCore
import OSLog
import UserNotifications

/// 「自动匹配缺失歌词」与「全量重新扫库」跑完时的系统通知,说一句结果。
///
/// 引擎是 launchd 常驻的命令行进程,没有通知权限;它只把进度写进状态文件
/// (`LyricsFillSweep`),这里常驻盯着那份文件,看到一轮收尾就投递。弹不弹、弹哪一种由
/// `LyricsFillSweep.finishNotice` 决定(纯函数,selftest 覆盖),这里只管轮询、去重和投递。
///
/// 常驻而不是挂在歌词管理 / 设置页的轮询上:一轮补搜几十分钟、全量扫库一两天,跑完时那两个窗口
/// 多半早关了,而用户要的正是"不用盯着窗口也知道它跑完了"。
@MainActor
final class LyricsSweepNotifier {
    static let shared = LyricsSweepNotifier()

    private let log = Logger(subsystem: "me.yudaotor.lyrimuse", category: "notify")

    /// 通知的 category / 线程 / identifier 前缀。点通知时 `UnknownPlayerNotifier` 的 delegate 按它
    /// 分流到「打开歌词管理」(系统只允许一个 delegate)。
    static let categoryID = "lyrics-sweep"

    /// 通知器开始盯的时刻:在这之前开工、又没被看见在跑的一轮不弹(见 `finishNotice`)。
    private let startedSince = Int64(Date().timeIntervalSince1970)
    /// 最近一次看见在跑的那一轮(按 `startedAt` 认)。
    private var runningStartedAt: Int64?
    /// 已经弹过的那一轮,同一份收据不弹第二次。
    private var notifiedStartedAt: Int64?
    /// 全量扫库断网期间引擎每 10 分钟重试一次、每次都是新的一轮;连着的几次暂停只弹第一次。
    private var lastWasFullOffline = false

    private var timer: Timer?

    /// 5 秒一拍:读的是按 mtime 缓存的状态文件,没变时就是一次 stat。
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 1
    }

    private func tick() {
        guard let info = LyricsFillSweep.current else { return }
        if info.running {
            runningStartedAt = info.startedAt
            return
        }
        guard notifiedStartedAt != info.startedAt else { return }
        guard let notice = LyricsFillSweep.finishNotice(
            info, startedSince: startedSince, sawRunning: runningStartedAt == info.startedAt) else { return }
        notifiedStartedAt = info.startedAt
        if notice == .fullOffline {
            if lastWasFullOffline { return }
            lastWasFullOffline = true
        } else {
            lastWasFullOffline = false
        }
        Task { await deliver(notice) }
    }

    private func deliver(_ notice: LyricsFillSweep.FinishNotice) async {
        guard await UnknownPlayerNotifier.shared.ensureAuthorized() else { return }
        let (title, body) = Self.text(notice)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.categoryID
        content.threadIdentifier = Self.categoryID
        content.sound = .default
        // 固定 identifier:新的一轮结果替换通知中心里上一轮那条,不越攒越多。
        let request = UNNotificationRequest(identifier: Self.categoryID, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            log.notice("announced lyrics sweep result")
        } catch {
            log.error("lyrics sweep announce failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 通知的标题与正文。
    private static func text(_ notice: LyricsFillSweep.FinishNotice) -> (String, String) {
        switch notice {
        case let .fillDone(done, filled, missed, skipped):
            return (L10n.t("自动匹配完成"),
                    done == 0
                        ? L10n.t("没有需要自动匹配的歌曲")
                        : String(format: L10n.plural("共 %1$@ 首：找到 %2$@，未找到 %3$@，跳过 %4$@", count: done),
                                 "\(done)", "\(filled)", "\(missed)", "\(skipped)"))
        case let .fillOffline(done, filled):
            return (L10n.t("自动匹配已停止"),
                    String(format: L10n.plural("网络不可用，已搜索 %1$@ 首、找到 %2$@ 首后停止", count: done), "\(done)", "\(filled)"))
        case let .fullDone(done, filled):
            return (L10n.t("全量重新扫库完成"),
                    done == 0
                        ? L10n.t("已全部跟进")
                        : String(format: L10n.plural("共检查 %1$@ 首，更新 %2$@ 首", count: done), "\(done)", "\(filled)"))
        case .fullOffline:
            return (L10n.t("全量重新扫库已暂停"), L10n.t("网络不可用，已暂停，稍后将自动继续"))
        }
    }
}
