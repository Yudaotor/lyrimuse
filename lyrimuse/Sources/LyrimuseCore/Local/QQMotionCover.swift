import Foundation

/// QQ 音乐专辑动态封面的视频地址。引擎把它记成 `qqmv:<vid>`(地址带签名、约 6 小时过期,只能记 vid,见引擎
/// `motioncoverqq.go`);下载时经客户端网关 `musicu.fcg` 的 `music.stream.MvUrlProxy` / `GetMvUrls` 换成 mp4 地址,不用登录。
/// 各档是 3:4 竖幅:filetype 10 / 20 / 30 / 40 / 60 依次是 360 / 480 / 720 / 1080 / 2160 宽(实测)。纯函数部分 selftest 钉着。
/// 见 03 章决策 67。
public enum QQMotionCover {
    public static let scheme = "qqmv"

    /// `qqmv:<vid>` → vid;不是这种地址、vid 形状不对为 nil。
    public static func vid(from master: URL) -> String? {
        guard master.scheme == scheme else { return nil }
        let vid = String(master.absoluteString.dropFirst(scheme.count + 1))
        return vid.range(of: "^[0-9A-Za-z]{6,32}$", options: .regularExpression) != nil ? vid : nil
    }

    /// 取视频地址的请求体。
    public static func urlsBody(vid: String) -> Data? {
        let body: [String: Any] = [
            "comm": ["ct": 24, "cv": 0],
            "req": ["module": "music.stream.MvUrlProxy", "method": "GetMvUrls", "param": ["vids": [vid]]],
        ]
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// 各档的宽度(像素)。
    public static let widths: [Int: Int] = [10: 360, 20: 480, 30: 720, 40: 1080, 60: 2160]

    /// 按 `targetWidth` 排档:不比它窄的里头最窄的先,然后由宽到窄排比它窄的,最后是更宽的。
    public static func preferenceOrder(targetWidth: Int) -> [Int] {
        let sorted = widths.sorted { $0.value < $1.value }
        let wide = sorted.filter { $0.value >= targetWidth }.map(\.key)
        let narrow = sorted.filter { $0.value < targetWidth }.reversed().map(\.key)
        return Array(wide.prefix(1)) + narrow + wide.dropFirst()
    }

    /// 应答 → 按 `preferenceOrder` 排好的 mp4 地址(一律 https)。顶层或 `req` 的 code 不是 0、形状不对为 nil(没问成);
    /// 问成了但一档都没有为空数组。
    public static func candidates(fromResponse data: Data, vid: String, targetWidth: Int) -> [URL]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["code"] as? NSNumber)?.intValue == 0,
              let req = root["req"] as? [String: Any], (req["code"] as? NSNumber)?.intValue == 0,
              let byVid = req["data"] as? [String: Any] else { return nil }
        let files = (byVid[vid] as? [String: Any])?["mp4"] as? [[String: Any]] ?? []
        var byType: [Int: URL] = [:]
        for f in files {
            guard let type = (f["filetype"] as? NSNumber)?.intValue, widths[type] != nil,
                  let raw = (f["freeflow_url"] as? [String])?.first,
                  var parts = URLComponents(string: raw), parts.host != nil else { continue }
            parts.scheme = "https"
            if let url = parts.url { byType[type] = url }
        }
        return preferenceOrder(targetWidth: targetWidth).compactMap { byType[$0] }
    }

    /// 问一次视频地址。nil = 没问成(网络、HTTP 状态不是 200、应答形状不对)。记进对外请求审计日志(服务名 `qq`)。
    public static func fetchCandidates(vid: String, targetWidth: Int, session: URLSession) async -> [URL]? {
        guard let body = urlsBody(vid: vid) else { return nil }
        var req = URLRequest(url: QQSongInfo.gatewayURL)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                     + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        let host = QQSongInfo.gatewayURL.host ?? "u.y.qq.com"
        let start = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode
            NetworkAuditLog.record(service: "qq", operation: "mv.urls", host: host,
                                   statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
            guard status == 200 else { return nil }
            return candidates(fromResponse: data, vid: vid, targetWidth: targetWidth)
        } catch {
            NetworkAuditLog.record(service: "qq", operation: "mv.urls", host: host,
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            return nil
        }
    }
}
