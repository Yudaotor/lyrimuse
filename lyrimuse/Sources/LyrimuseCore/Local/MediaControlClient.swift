import Foundation

// 跑 `media-control get` 拿一次性快照(collector/system.go 的 getState() 用的是同一条
// 命令,同样的一次性读取 + 轮询思路——不用 `media-control stream`,那个 collector 自己
// 都没用过,diff 载荷的合并逻辑没有先例代码可抄,贸然解析风险更高)。
public enum MediaControlClient {
    // 跟 collector/config.go 默认路径一致的探测顺序:先试 Homebrew Apple Silicon 的
    // 固定路径,找不到再退到 PATH 里查。
    private static let knownPaths = ["/opt/homebrew/bin/media-control", "/usr/local/bin/media-control"]

    private static func resolveExecutablePath() -> String? {
        for p in knownPaths where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["media-control"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        do {
            try which.run()
            which.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch {
            return nil
        }
    }

    // 失败(命令不存在/非零退出/解析失败)一律返回 nil,不抛出——上层按"这次没拿到数据,
    // 下一轮再试"处理,不应该让本地数据源因为一次瞬时失败就崩掉。
    public static func fetchSnapshot() -> MediaControlSnapshot? {
        guard let exe = resolveExecutablePath() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = ["get"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return try JSONDecoder().decode(MediaControlSnapshot.self, from: data)
        } catch {
            return nil
        }
    }
}
