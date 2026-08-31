import Foundation
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "collector-restart")

/// 全 App **唯一**的 collector 重启入口(带去抖)。
///
/// ## 为什么必须是共享的一个
///
/// `CollectorControl.restartAndWaitAsync()` 走 `launchctl kickstart -k`,而 **launchd 对
/// 间隔太近的两次 kickstart 会节流到约 10 秒才返回**;每重启一次,"正在播放"推送就中断
/// 一次。FeatureSettingsStore 2026-08-02 为此加过一个去抖 —— 但那份去抖是它**私有**的,
/// 只能合并它自己的连续 save(),完全看不见 ConfigStore 也在重启。
///
/// 后果(2026-08-30 通盘梳理时坐实):在"推送账号"tab 里同时改一个凭据和一个开关 ——
/// 这是最常见的操作,连一次账号就会发生 —— 会触发**两次独立重启**:
///
///   - ConfigStore.save() 由 AccountLinkingTab 的 1.2s 输入去抖触发,然后**立刻**重启;
///   - FeatureSettingsStore.save() 走它自己的 0.5s 去抖,再重启一次。
///
/// 两次间隔极近,第二次几乎必然撞上 launchd 的节流,阻塞约 10 秒 —— 而这正是当初加去抖
/// 想消灭的场景,只是当时没料到另一个 store 也会重启。
///
/// ⚠️ 历史包袱:两个 store 里都还留着"'推送账号'tab 底部的保存栏会把两处 persistFile()
/// 一起调用、之后统一重启一次"这类注释。**那个保存栏已经不存在了**(现在是
/// AccountLinkingTab 的只读 `autosaveStatusBar` + 1.2s 防抖自动保存),它描述的正是本类
/// 现在负责的这件事 —— 那些注释已随本次改动订正,别再照着它们推断行为。
///
/// ## 语义
///
/// 每次 `requestRestart()` 都会取消上一次还没触发的延时、重新计时;**只有连续调用真正
/// 停下来之后才会触发唯一一次重启**。等待期间调用过的所有地方,都会在这唯一一次重启
/// 真正完成后收到**同一份**结果,不需要各自等自己那次(那次可能已经被取消)。
/// 这套语义原样搬自 FeatureSettingsStore 的私有实现,不是重新设计。
@MainActor
public final class CollectorRestartCoordinator {
    public static let shared = CollectorRestartCoordinator()

    private init() {}

    /// 0.5s:够把"连着改好几项"合并成一次,又短到用户不会觉得保存卡住。沿用
    /// FeatureSettingsStore 原来的取值,不趁这次改动顺手调参 —— 那是另一件事。
    private static let debounceNanoseconds: UInt64 = 500_000_000

    private var pendingTask: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    /// 请求一次重启。返回值是**那唯一一次真正执行的重启**成没成功。
    public func requestRestart() async -> Bool {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            pendingTask?.cancel()
            pendingTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.fire()
            }
        }
    }

    private func fire() async {
        // 先把等待者取走再 await:重启期间进来的新请求会另起一轮(它们要的是**改动之后**
        // 的那次重启,不能被这一轮顺手应付掉)。
        let pending = waiters
        waiters = []
        pendingTask = nil

        let ok = await CollectorControl.restartAndWaitAsync()
        if !ok {
            logger.error("collector restart failed (\(pending.count, privacy: .public) waiter(s))")
        }
        for continuation in pending {
            continuation.resume(returning: ok)
        }
    }
}
