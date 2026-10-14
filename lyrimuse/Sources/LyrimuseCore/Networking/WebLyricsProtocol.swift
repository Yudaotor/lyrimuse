import CryptoKit
import Foundation

/// 网页歌词本地服务的协议层:HTTP 请求解析与响应、WebSocket 握手与分帧、访问控制、副屏尺寸。
/// 只处理字节,不碰网络;连接与收发在 App 的 `WebLyricsServer`。见 19 章。
public enum WebLyricsHTTP {
    /// 请求头最多收这么多字节,超过就当坏请求断开(这个服务只有 GET,头很短)。
    public static let maxHeaderBytes = 16 * 1024

    public struct Request: Equatable, Sendable {
        public var method: String
        /// 不含查询串,已去掉百分号编码。
        public var path: String
        public var query: [String: String]
        /// 键一律小写。
        public var headers: [String: String]

        public init(method: String, path: String, query: [String: String], headers: [String: String]) {
            self.method = method
            self.path = path
            self.query = query
            self.headers = headers
        }

        public var isWebSocketUpgrade: Bool {
            guard headers["upgrade"]?.lowercased() == "websocket",
                  headers["connection"]?.lowercased().contains("upgrade") == true,
                  let key = headers["sec-websocket-key"], !key.isEmpty else { return false }
            return true
        }
    }

    public enum ParseResult: Equatable, Sendable {
        case needMore
        case invalid
        case request(Request, consumed: Int)
    }

    /// 从缓冲区开头解析一个请求头(到第一个空行为止)。没有请求体:这个服务只认 GET。
    public static func parse(_ data: Data) -> ParseResult {
        let terminator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: terminator) else {
            return data.count > maxHeaderBytes ? .invalid : .needMore
        }
        let headerBytes = data[data.startIndex..<end.lowerBound]
        guard headerBytes.count <= maxHeaderBytes,
              let text = String(data: headerBytes, encoding: .utf8) else { return .invalid }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .invalid }
            headers[name] = value
        }
        let target = String(requestLine[1])
        guard target.hasPrefix("/"), let components = URLComponents(string: target) else { return .invalid }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value ?? ""
        }
        let request = Request(method: String(requestLine[0]), path: components.path.isEmpty ? "/" : components.path,
                              query: query, headers: headers)
        return .request(request, consumed: data.distance(from: data.startIndex, to: end.upperBound))
    }

    /// 一个完整响应。`Connection: close`:除了升级成 WebSocket 的那条,每个请求回完就断。
    public static func response(status: Int, reason: String, contentType: String? = nil, body: Data = Data(),
                                extraHeaders: [(String, String)] = []) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        for (name, value) in extraHeaders { head += "\(name): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// RFC 6455 §4.2.2 的 `Sec-WebSocket-Accept`。
    public static func webSocketAccept(key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(digest).base64EncodedString()
    }

    public static func upgradeResponse(key: String) -> Data {
        Data(("HTTP/1.1 101 Switching Protocols\r\n"
              + "Upgrade: websocket\r\n"
              + "Connection: Upgrade\r\n"
              + "Sec-WebSocket-Accept: \(webSocketAccept(key: key))\r\n\r\n").utf8)
    }
}

/// WebSocket 分帧(RFC 6455 §5)。服务端发出的帧不加掩码;收到的客户端帧必须带掩码。
public enum WebSocketFrame {
    public enum Opcode: UInt8, Sendable {
        case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA
    }

    /// 客户端帧的载荷上限:网页只会发关闭、ping 这类控制帧,大帧一律当坏连接。
    public static let maxClientPayload = 64 * 1024

    public static func encode(_ payload: Data, opcode: Opcode) -> Data {
        var frame = Data([0x80 | opcode.rawValue])
        let count = payload.count
        if count < 126 {
            frame.append(UInt8(count))
        } else if count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(count >> 8))
            frame.append(UInt8(count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((UInt64(count) >> UInt64(shift)) & 0xFF)) }
        }
        frame.append(payload)
        return frame
    }

    public struct Decoded: Equatable, Sendable {
        public let opcode: UInt8
        public let payload: Data
        public let consumed: Int

        public init(opcode: UInt8, payload: Data, consumed: Int) {
            self.opcode = opcode
            self.payload = payload
            self.consumed = consumed
        }
    }

    public enum DecodeResult: Equatable, Sendable {
        case needMore
        case invalid
        case frame(Decoded)
    }

    public static func decode(_ data: Data) -> DecodeResult {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return .needMore }
        let opcode = bytes[0] & 0x0F
        let masked = bytes[1] & 0x80 != 0
        guard masked else { return .invalid }
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return .needMore }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return .needMore }
            var value: UInt64 = 0
            for i in 2..<10 { value = value << 8 | UInt64(bytes[i]) }
            guard value <= UInt64(maxClientPayload) else { return .invalid }
            length = Int(value)
            offset = 10
        }
        guard length <= maxClientPayload else { return .invalid }
        guard bytes.count >= offset + 4 + length else { return .needMore }
        let mask = Array(bytes[offset..<offset + 4])
        offset += 4
        var payload = [UInt8](repeating: 0, count: length)
        for i in 0..<length { payload[i] = bytes[offset + i] ^ mask[i % 4] }
        return .frame(Decoded(opcode: opcode, payload: Data(payload), consumed: offset + length))
    }
}

/// 谁能打开:本机回环一律放行;别的设备要「局域网设备也能打开」开着、链接里带对的密钥。
/// 另外只认按 IP、`localhost` 或本机 `.local` 名访问的请求,挡住借 DNS 重绑定从恶意网页读歌词。
public enum WebLyricsAccess {
    public static func permits(remoteIsLoopback: Bool, lanEnabled: Bool, token: String, query: [String: String]) -> Bool {
        if remoteIsLoopback { return true }
        guard lanEnabled, !token.isEmpty, let given = query["k"] else { return false }
        return constantTimeEqual(given, token)
    }

    /// `Host` 头去掉端口后:IPv4 / IPv6 字面量、`localhost`、`localNames` 里的名字(比较不分大小写)。
    public static func hostAllowed(_ host: String?, localNames: Set<String>) -> Bool {
        guard var value = host?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return false }
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return false }
            value = String(value[value.index(after: value.startIndex)..<close])
            return value.contains(":") && value.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        if let colon = value.lastIndex(of: ":") {
            let port = value[value.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return false }
            value = String(value[..<colon])
        }
        if value == "localhost" { return true }
        if isIPv4(value) { return true }
        return localNames.contains { $0.lowercased() == value }
    }

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber), let n = Int(part) else { return false }
            return n <= 255
        }
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    /// 新的随机密钥:128 位,十六进制。
    public static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }
}

/// 副屏画面的尺寸:网页报上来的视口(点)和像素倍数,夹进能画、能推的范围。
public struct WebLyricsViewport: Hashable, Sendable {
    public let width: Int
    public let height: Int
    /// 像素倍数,可以是小数(系统缩放 125% / 150% 的设备、按像素上限压下来的大窗口)。
    public let scale: Double
    /// 实际画的像素尺寸:点数乘倍数后取偶数(JPEG 按 2×2 块存色度)。
    public let pixelWidth: Int
    public let pixelHeight: Int

    public static let pointRange = 240...2560
    public static let scaleRange = 1.0...3.0
    /// 一帧最多这么多像素(14 寸 MacBook 全屏浏览器 2x 约 530 万),再大就按比例压倍数、不整档降:
    /// 编码、传输和显存跟像素数成正比,整档降到 1x 时浏览器放大两倍显示,字是糊的。见 19 章决策 3。
    public static let maxPixels = 7_000_000

    public init(width: Int, height: Int, scale: Double) {
        let w = min(max(width, Self.pointRange.lowerBound), Self.pointRange.upperBound)
        let h = min(max(height, Self.pointRange.lowerBound), Self.pointRange.upperBound)
        let requested = scale.isFinite ? min(max(scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound) : 2
        let cap = (Double(Self.maxPixels) / Double(w * h)).squareRoot()
        let s = max(Self.scaleRange.lowerBound, min(requested, cap))
        self.width = w
        self.height = h
        self.scale = s
        pixelWidth = Int(Double(w) * s / 2) * 2
        pixelHeight = Int(Double(h) * s / 2) * 2
    }

    /// 网页连上来时带的 `w` / `h` / `dpr`;缺了或认不出就按 1180×820@2x。
    public init(query: [String: String]) {
        func number(_ key: String) -> Double? { query[key].flatMap { Double($0) }.flatMap { $0.isFinite ? $0 : nil } }
        let w = number("w").map { Int($0.rounded()) } ?? 1180
        let h = number("h").map { Int($0.rounded()) } ?? 820
        let dpr = number("dpr") ?? 2
        self.init(width: w, height: h, scale: dpr)
    }
    /// 宽度够才摆左栏(封面卡 + 曲目信息),同歌词窗口完整布局的 640pt 断点。
    public var showsPlayerPane: Bool { width >= 640 }
}
