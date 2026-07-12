import Foundation

// `media-control get` 的 elapsedTime 在稳定播放期间会冻结不动(collector/system.go 的
// appleMusicPosition() 注释里已经记录过这个坑:"media-control's elapsed+timestamp...
// drifts ~1-2s" ——实测坐实更严重,直接整段冻结在轨道刚开始播放那一刻,完全不随真实
// 播放时间推进)。跟 collector 一样,改用 AppleScript 直接问 Music.app 本身要精确到
// ~0.1s 的实时播放位置——只在 Music.app 本身在播放时才有意义,其它情况(没在播/其它
// 播放器)由上层退回 media-control 的 elapsedTime 兜底。
public enum AppleMusicPositionClient {
    public static func fetchPositionSeconds() -> Double? {
        let script = """
        tell application "Music"
            if player state is playing then return (player position as text)
            return "x"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            guard let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            guard let value = Double(str), value >= 0 else { return nil }
            return value
        } catch {
            return nil
        }
    }
}
