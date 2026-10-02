import Foundation

/// 诊断导出里健康检查那一段:怎么调引擎的 `healthcheck`,跑完怎么写进报告。
public enum DiagnosticsHealthCheck {
    /// 整个子进程最多跑多久,到点由 ProcessRunner 终止。
    public static let timeoutSeconds: TimeInterval = 15

    /// 联网探测的时限,传给引擎的 `-probe-timeout`。引擎到点之后最多再等 2 秒收尾(healthcheckcli.go
    /// `healthProbeGrace`),本地检查不到 1 秒:三段加起来必须小于 `timeoutSeconds`,两处一起改。
    public static let probeBudgetSeconds = 10

    public static var arguments: [String] {
        ["healthcheck", "-probe-timeout", "\(probeBudgetSeconds)s"]
    }

    /// 子进程跑完之后写进报告的行。stdout 是报告本体;stderr(探测期间的网络日志、报错)非空就折叠后附在
    /// 后面,stdout 为空时它常常是唯一的线索。
    public static func reportLines(stdout: String, stderr: String, status: Int32, timedOut: Bool) -> [String] {
        var lines: [String]
        if stdout.isEmpty {
            lines = [timedOut
                ? "(engine healthcheck did not finish within \(Int(timeoutSeconds))s and was terminated before printing anything)"
                : "(engine healthcheck produced no output, exit code \(status))"]
        } else {
            lines = stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if timedOut {
                lines.append("(healthcheck timed out after \(Int(timeoutSeconds))s and was terminated — the report above may be incomplete)")
            }
        }
        if !stderr.isEmpty {
            lines.append("")
            lines.append("-- healthcheck 探测期间产生的原始日志(通常是探测曲触发的网络审计行,非结构化报告本体) --")
            lines.append(contentsOf: collapseRepeatedLines(
                stderr.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)))
        }
        return lines
    }

    /// 把抹掉数字之后长得一样的行(只有时间戳、耗时、计数不同)折叠起来:同一类出现满 `minRepeat` 次才折,
    /// 保留第一条和最后一条(各自带真实时间戳),中间换成一行「又重复了 N 次」;不到阈值的原样留着。
    /// 按类全局折叠,不要求连续出现。「同一类」的口径(抹数字)跟引擎日志出口的 `repeatSquelcher` 一致,
    /// 两处一起改。
    public static func collapseRepeatedLines(_ lines: [String], minRepeat: Int = 12) -> [String] {
        func template(_ line: String) -> String {
            var out = ""
            out.reserveCapacity(line.count)
            var lastWasDigit = false
            for ch in line {
                if ch.isASCII, ch.isNumber {
                    if !lastWasDigit { out.append("#") }
                    lastWasDigit = true
                } else {
                    out.append(ch)
                    lastWasDigit = false
                }
            }
            return out
        }

        var indicesByTemplate: [String: [Int]] = [:]
        for (i, line) in lines.enumerated() {
            indicesByTemplate[template(line), default: []].append(i)
        }

        var dropped = Set<Int>()
        var insertAfter: [Int: String] = [:]
        for indices in indicesByTemplate.values where indices.count >= minRepeat {
            let middle = indices.dropFirst().dropLast()
            for i in middle { dropped.insert(i) }
            insertAfter[indices.first!] =
                "    ⋯ 以上这类日志又重复了 \(middle.count) 次（已省略，下一行是最后一次出现）⋯"
        }

        var out: [String] = []
        out.reserveCapacity(lines.count)
        for (i, line) in lines.enumerated() {
            if dropped.contains(i) { continue }
            out.append(line)
            if let note = insertAfter[i] { out.append(note) }
        }
        return out
    }
}
