import Foundation

/// macOS 应用防火墙会不会挡住这个程序的传入连接。网页歌词、OBS 输出开了「允许局域网访问」以后,防火墙挡着时别的设备
/// 连得上端口、却收不到任何回应(连接被直接掐掉),设置页要把这件事说出来。读 `socketfilterfw` 的输出,不要管理员权限。
/// 见 19 章决策 39。
public enum ApplicationFirewall {
    public static let tool = "/usr/libexec/ApplicationFirewall/socketfilterfw"

    /// `--getglobalstate` 的输出里那个状态号:0 = 关着,1 = 开着,2 = 阻止所有传入连接。认不出为 nil。
    public static func globalState(from output: String) -> Int? {
        guard let range = output.range(of: #"State = (\d)"#, options: .regularExpression),
              let digit = output[range].last?.wholeNumberValue else { return nil }
        return digit
    }

    /// `--getappblocked <路径>` 的输出:「… is blocked.」为 true,「… is permitted.」为 false,别的(没加进防火墙列表等)为 nil。
    public static func appBlocked(from output: String) -> Bool? {
        if output.contains("is blocked") { return true }
        if output.contains("is permitted") { return false }
        return nil
    }

    /// 别的设备连不进来:防火墙开着,并且要么阻止所有传入连接,要么这个程序被明确挡住。认不出的一律当没挡。
    public static func blocksIncoming(globalState: Int?, appBlocked: Bool?) -> Bool {
        guard let state = globalState, state >= 1 else { return false }
        return state == 2 || appBlocked == true
    }

    /// 实际跑一遍 `socketfilterfw`(两次,各限时 3 秒)。会阻塞,别在主线程上调。
    public static func blocksIncoming(executablePath: String) -> Bool {
        let state = ProcessRunner.run(tool, ["--getglobalstate"], timeout: 3).map { globalState(from: $0.stdoutText) } ?? nil
        guard let state, state >= 1 else { return false }
        let blocked = ProcessRunner.run(tool, ["--getappblocked", executablePath], timeout: 3)
            .map { appBlocked(from: $0.stdoutText) } ?? nil
        return blocksIncoming(globalState: state, appBlocked: blocked)
    }
}
