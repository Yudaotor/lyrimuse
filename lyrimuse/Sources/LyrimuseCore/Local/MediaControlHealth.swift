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
// ⚠️ 只做**诊断**,不做降级:Apple Music 和 Spotify 走 AppleScript,压根不经过这条通道,
// 不受影响;而 QQ 音乐/网易云没有任何替代路径可退,查出来也只能如实告诉用户。所以这里
// 不设任何 fallback 逻辑,只置一个标志供 UI/诊断导出显示。
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

    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "mc-health")
    /// 自检本身要跑一个子进程。给足超时但别无限等 —— 它卡住时最坏也只是标志停在 unknown,
    /// 不影响任何播放路径。
    private static let timeout: TimeInterval = 8

    private init() {}

    /// 启动时调一次。放在后台跑,不挡启动。
    public func checkInBackground() {
        guard case .unknown = state else { return }
        guard let binary = MediaControlClient.binaryPath() else {
            // 没走 build.sh 打包时(直接 swift build)拿不到二进制。这不是"通道坏了",
            // 别报成不可用去吓用户。
            Self.logger.info("media-control binary unavailable; skipping health check")
            return
        }
        Task.detached(priority: .utility) {
            let result = ProcessRunner.run(binary, ["test"], timeout: Self.timeout)
            await MainActor.run {
                self.apply(result)
            }
        }
    }

    private func apply(_ result: ProcessRunner.Result?) {
        // nil = 进程根本没起来(文件不在/没有执行权限),跟"跑了但失败"是两回事,见
        // ProcessRunner.run 的注释。两者对用户的意思都是"这台机器上用不了",但日志要分开。
        guard let result else {
            state = .unavailable(message: "media-control could not be launched")
            Self.logger.error("media-control health check: process failed to launch")
            return
        }
        if result.succeeded {
            state = .healthy
            Self.logger.info("media-control channel healthy")
            return
        }
        if result.timedOut {
            // 正常情况下 test 是瞬间返回的(实测健康时静默退出、耗时可忽略),卡到超时
            // 多半就是坏的 —— 但没有确凿的退出码,措辞上不把话说死。
            state = .unavailable(message: "media-control test timed out")
            Self.logger.error("media-control health check timed out")
            return
        }
        let detail = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .unavailable(message: detail.isEmpty ? "exit status \(result.status)" : detail)
        Self.logger.error(
            "media-control channel unavailable (status \(result.status, privacy: .public)): \(detail, privacy: .public)")
    }
}
