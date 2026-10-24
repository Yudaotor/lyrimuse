import Foundation

/// JXA 读数脚本找播放器的开头:按 bundle id 找在跑的进程,之后的 Apple Event 按进程号发;没在跑时 `return <notRunning>`。
/// 别写成 `Application("名字")` 先判 `running()` 再发:两步之间播放器退掉,按名字发的事件会把它重新启动,按进程号发的只报错。
/// 见 02 章决策 186。
public enum JXARunningApp {
    /// `name` 是脚本里接下来用的变量名,`notRunning` 是没在跑时 return 的 JS 表达式。
    public static func attach(_ name: String, player: PlaybackPlayer, notRunning: String) -> String {
        attach(name, bundleID: player.bundleIdentifier, notRunning: notRunning)
    }

    /// AppKit 在同一个 osascript 里只 import 一次:每次 import 约 90 毫秒,常驻那个每拍都要跑。
    public static func attach(_ name: String, bundleID: String, notRunning: String) -> String {
        """
        if (!globalThis.lyrimuseAppKit) { ObjC.import('AppKit'); globalThis.lyrimuseAppKit = true; }
        const \(name)Running = $.NSRunningApplication.runningApplicationsWithBundleIdentifier("\(bundleID)");
        if (Number(\(name)Running.count) === 0) return \(notRunning);
        const \(name) = Application(Number(\(name)Running.objectAtIndex(0).processIdentifier));
        """
    }
}
