import Foundation
import OSLog

// 启动时自检一次:media-control 赖以工作的私有 MediaRemote 通道在这台机器的这个系统版本
// 上还能不能用。
//
// 要解决的问题是**归因**。QQ 音乐/网易云的所有播放信息都经 media-control 读,一旦 Apple
// 在某次系统更新里动了那套私有 API,用户看到的现象是"歌词不动了",而这跟"没在放歌""这首歌
// 没歌词""collector 挂了"从表象上完全分不开 —— 排查会从歌词源、缓存、网络一路查过去,
// 而真正的原因在最底层且根本修不了(只能等上游适配)。`media-control test` 专门回答这一件事:
// 它不看有没有歌在放,只验通道本身通不通,非零退出即"这台机器上用不了"。
//
// 别以为「Apple Music 和 Spotify 走 AppleScript,压根不经过这条通道,不受影响」
// —— **那是错的**,而且它正好会把排查带偏。默认配置是
// `[.auto]`,那条路上 **Apple Music 的快照基座也是 media-control**(AppleScript 只在
// `adaptedSnapshot` 里把位置与曲目信息整份换成 AppleScript 那份);只有「恰好只勾
// Apple Music、没勾自动识别」才连"谁在放"都不问它。所以这条通道坏掉时 Apple Music 用户同样会受影响。
//
// 只做**诊断**、不做降级这一点仍然成立,但理由换了:Apple Music 的降级已经在
// `MediaControlClient.appleMusicSnapshotAfterFocusLost` 里做了(通道坏 / 焦点被抢一视同仁,
// 见那个函数的头注),不归这里管;而 QQ 音乐/网易云确实没有任何替代路径可退,查出来也只能
// 如实告诉用户。所以这里不设 fallback,只置一个标志供 UI/诊断导出显示。
@MainActor
public final class MediaControlHealth: ObservableObject {
    public static let shared = MediaControlHealth()

    public enum State: Equatable {
        case unknown
        case healthy
        /// 通道不可用(退出码非零)。message 是它自己吐的原因,原样带给用户。
        case unavailable(message: String)
    }

    @Published public private(set) var state: State = .unknown

    /// 此刻正跑着一次自检。
    ///
    /// **必须跟 `state` 分开记**:重试期间 `state` 还停在 `.unknown`(失败还没落成
    /// "不可用"),光靠 `state` 那道 guard 挡不住第二个调用方进来,会多 fork 一个子进程。
    private var isChecking = false

    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "mc-health")
    /// 自检本身要跑一个子进程。给足超时但别无限等 —— 它卡住时最坏也只是标志停在 unknown,
    /// 不影响任何播放路径。
    private static let timeout: TimeInterval = 8

    /// **启动那一下失败不算数,要再试**。
    ///
    /// 实测:安装脚本刚换掉 App 包、重新拉起的那零点几秒里跑的自检回了 4(stdout 全空),
    /// 而同一台机器上手动跑五次 `test` 全是 0、下一次启动的自检也是 healthy。启动瞬间
    /// (新包首次验签、系统正忙着拉起一堆东西)恰恰是最容易抖的时刻,而这个标志一旦落成
    /// "不可用"就**整个会话不再复查**(见下面那道 guard),界面上那句警告会一直挂到用户
    /// 重启 App 为止 —— 一次抖动换来一整个会话的假警报。
    ///
    /// 代价很小:真坏了也只是多跑两次瞬间返回的子进程。
    private static let launchRetries = 2
    private static let retryDelay: TimeInterval = 5

    private init() {}

    /// 启动时调一次。放在后台跑,不挡启动。
    public func checkInBackground() {
        guard case .unknown = state else { return }
        run(retriesLeft: Self.launchRetries)
    }

    /// 界面上正挂着「不可用」的时候再验一次(设置页「播放器」那页 onAppear 调)。
    ///
    /// 只在 `.unavailable` 时才真跑:healthy / unknown 进来什么都不做 —— 别让"打开一次
    /// 设置页"变成"白 fork 一个子进程"。这条路覆盖的是重试也救不回来的那种抖动(通道在自检
    /// 跑完之后才恢复),用户看到那句警告时的自然动作就是回设置页看看,正好借这一下复查。
    public func recheckIfUnavailable() {
        guard case .unavailable = state else { return }
        run(retriesLeft: 0)
    }

    private func run(retriesLeft: Int) {
        guard !isChecking else { return }
        guard let binary = MediaControlClient.binaryPath() else {
            // 没走 build.sh 打包时(直接 swift build)拿不到二进制。这不是"通道坏了",
            // 别报成不可用去吓用户。
            Self.logger.notice("media-control binary unavailable; skipping health check")
            return
        }
        isChecking = true
        // 超时值先取到本地再进 detached task:`Self.timeout` 是 MainActor 隔离的,
        // 在那条任务里直接读它在 Swift 6 语言模式下是错误。
        let timeout = Self.timeout
        Task.detached(priority: .utility) {
            // `captureStderr: true` 不能省:失败原因只写在 stderr 上(适配框架那句
            // "The test client did not signal setup_done within …"),stdout 是空的。
            // 不接那根管子,用户看到的就只有一句没有任何信息量的「exit status 4」。
            let result = ProcessRunner.run(binary, ["test"], timeout: timeout, captureStderr: true)
            await MainActor.run {
                self.apply(result, retriesLeft: retriesLeft)
            }
        }
    }

    private func apply(_ result: ProcessRunner.Result?, retriesLeft: Int) {
        isChecking = false
        if let result, result.succeeded {
            state = .healthy
            Self.logger.info("media-control channel healthy")
            return
        }
        let message = Self.failureMessage(result)
        if retriesLeft > 0 {
            // 还没落成"不可用" —— `state` 留在原值(启动那条路上就是 .unknown),
            // 界面因此不会先闪一下警告再自己收回去。
            Self.logger.info(
                "media-control health check failed (\(message, privacy: .public)); \(retriesLeft, privacy: .public) retries left")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.retryDelay * 1_000_000_000))
                self?.run(retriesLeft: retriesLeft - 1)
            }
            return
        }
        state = .unavailable(message: message)
        Self.logger.error("media-control channel unavailable: \(message, privacy: .public)")
    }

    /// 给用户看的失败原因。
    ///
    /// **stderr 排在 stdout 前面**:那个适配框架把真正的原因写在 stderr 上,stdout 是空的。
    /// 两边都空才退回退出码 —— 「exit status 4」是最后的兜底,不是常态。
    private static func failureMessage(_ result: ProcessRunner.Result?) -> String {
        // nil = 进程根本没起来(文件不在/没有执行权限),跟"跑了但失败"是两回事,见
        // ProcessRunner.run 的注释。两者对用户的意思都是"这台机器上用不了",但原因要分开说。
        guard let result else { return "media-control could not be launched" }
        if result.timedOut {
            // 正常情况下 test 是瞬间返回的(实测健康时静默退出、耗时可忽略),卡到超时
            // 多半就是坏的 —— 但没有确凿的退出码,措辞上不把话说死。
            return "media-control test timed out"
        }
        let detail = [result.stderrText, result.stdoutText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return detail.isEmpty ? "exit status \(result.status)" : detail
    }
}
