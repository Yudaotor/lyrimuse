import Foundation
import os

/// 验证「一条来源断了另一条撑不撑得住」用的开关:关掉某一条来源,代码按它断了走退路。只经 `debug/knockout` 深链改
/// (本机偏好 `debug:deepLinks` 打开时才认),不落盘,App 重启全部复原。见 16 章「来源冗余与拔腿测试」。
public enum SourceKnockout {
    /// 能关掉的来源。名字就是深链里 `leg=` 的取值。
    public enum Leg: String, CaseIterable, Sendable {
        /// VOX 的 AppleScript 读数(曲目、位置、当前文件、封面):关掉后当成没授「自动化」权限。
        case voxScript = "vox-script"
        /// VOX 换歌时发的分布式通知(`com.coppertino.Vox.trackChanged`)。
        case voxNotice = "vox-notice"
        /// media-control 事件流(暂停、恢复、换歌的即时信号):关掉后只剩轮询和各播放器自己的通知。
        case streamEvents = "stream-events"
        /// 系统 Now Playing 里的封面图(含按 bundle id 单问的那份)。
        case systemArtwork = "system-artwork"
        /// Pine Player 开着的文件(按标签认曲目、精确时长,`PinePlayerInfo`):关掉后只拆系统那份的歌手一栏。
        case pineFile = "pine-file"
        /// Pine Player 界面上的进度条(跳转、恢复之后补位置的小数,`PinePlayhead`):关掉后当成没授「辅助功能」权限。
        case pineSlider = "pine-slider"
    }

    private static let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "knockout")
    private static let state = OSAllocatedUnfairLock<Set<Leg>>(initialState: [])

    public static func isOut(_ leg: Leg) -> Bool {
        state.withLock { $0.contains(leg) }
    }

    public static func set(_ leg: Leg, out: Bool) {
        state.withLock { if out { $0.insert(leg) } else { $0.remove(leg) } }
        logger.notice("source knockout \(leg.rawValue, privacy: .public) \(out ? "off" : "back on", privacy: .public)")
    }

    /// 此刻关着的来源(按名字排),写进 `debug/state`。
    public static var knockedOut: [String] {
        state.withLock { $0.map(\.rawValue).sorted() }
    }
}
