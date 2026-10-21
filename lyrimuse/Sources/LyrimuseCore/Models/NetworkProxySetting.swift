import Foundation

/// 设置 › 通用 › 网络 › 代理:直连失败时经哪个代理重试。rawValue 跟引擎 networkproxy.go 的 networkProxyAuto / Manual / Off
/// 逐字相同,两侧经 features.json 的 network_proxy 交换,引擎不认识的值按 auto。见 09 章决策 321。
///
/// case 的声明顺序就是设置页分段从左到右的顺序。
public enum NetworkProxyMode: String, CaseIterable, Identifiable, Sendable {
    case auto, manual, off
    public var id: Self { self }
}

/// 手动档的代理服务器(features.json 的 network_proxy_server)。判据跟引擎 parseProxyServer 一致:host:port,
/// 可带 http:// / https:// / socks5:// / socks5h:// 前缀,端口 1…65535。
public enum NetworkProxyServer {
    public static let placeholder = "127.0.0.1:7890"

    public static func isValid(_ text: String) -> Bool {
        var s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return false }
        if !s.contains("://") { s = "http://" + s }
        guard let c = URLComponents(string: s),
              let scheme = c.scheme?.lowercased(), ["http", "https", "socks5", "socks5h"].contains(scheme),
              let host = c.host, !host.isEmpty,
              let port = c.port, (1...65535).contains(port) else { return false }
        return true
    }
}
