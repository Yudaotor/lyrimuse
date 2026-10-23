import CryptoKit
import Foundation

/// 网易云歌曲动态封面的视频地址。引擎把它记成 `ncmv:<歌曲 id>`(地址带签名、约半小时过期,只能记 id,见引擎
/// `motioncoverne.go`);下载时问 `/api/songplay/dynamic-cover` 换成 mp4 地址。这个接口要登录,用网易云的游客身份
/// (`/api/register/anonimous` 发的 MUSIC_A,半年有效),身份落盘在数据目录里跟引擎共用的那份(`guestFileName`),谁先注册谁写。
/// 画面是方形的,不用裁。纯函数部分 selftest 钉着。见 03 章决策 68。
public enum NeteaseMotionCover {
    public static let scheme = "ncmv"
    /// 游客身份那份文件,引擎读写同一份(`neteaseGuestFileName`)。
    public static let guestFileName = "lyrimuse-netease-guest.json"

    /// `ncmv:<id>` → 歌曲 id;不是这种地址、id 形状不对为 nil。
    public static func songID(from master: URL) -> String? {
        guard master.scheme == scheme else { return nil }
        let id = String(master.absoluteString.dropFirst(scheme.count + 1))
        return id.range(of: "^[0-9]{1,20}$", options: .regularExpression) != nil ? id : nil
    }

    // MARK: - 游客身份

    /// 游客身份。`expires` 是 Unix 秒。
    public struct Guest: Codable, Equatable, Sendable {
        public var musicA: String
        public var expires: Int64

        public init(musicA: String, expires: Int64) {
            self.musicA = musicA
            self.expires = expires
        }

        enum CodingKeys: String, CodingKey {
            case musicA = "music_a"
            case expires
        }

        /// 离过期还有一天以上。
        public func usable(now: Date) -> Bool {
            !musicA.isEmpty && Date(timeIntervalSince1970: TimeInterval(expires)).timeIntervalSince(now) > 86_400
        }
    }

    /// 游客注册时设备号的混淆密钥。网易云客户端协议里的固定常量,各开源实现通用,不是账号凭据。
    private static let guestXorKey = Array("3go8&$8*3*3h0k(2)2".utf8)

    /// 游客注册的 username = base64("<设备号> <base64(md5(设备号逐字节异或密钥))>")。跟引擎 `neteaseGuestUsername` 用同一组向量。
    public static func guestUsername(deviceID: String) -> String {
        let bytes = Array(deviceID.utf8)
        let mixed = bytes.enumerated().map { $0.element ^ guestXorKey[$0.offset % guestXorKey.count] }
        let digest = Data(Insecure.MD5.hash(data: Data(mixed))).base64EncodedString()
        return Data("\(deviceID) \(digest)".utf8).base64EncodedString()
    }

    /// username 里 base64 的 `+ / =` 都要转义(URLComponents 不转 `+` 和 `=`)。
    public static func registerURL(deviceID: String) -> URL? {
        guard let username = guestUsername(deviceID: deviceID).addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { return nil }
        return URL(string: "https://music.163.com/api/register/anonimous?username=\(username)")
    }

    /// 注册应答 → 游客身份。HTTP 不是 200、code 不是 200、没发 MUSIC_A 为 nil。Cookie 没写有效期时按 150 天算。
    public static func guest(status: Int, body: Data, setCookie: [String: String], url: URL, now: Date) -> Guest? {
        guard status == 200,
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              (root["code"] as? NSNumber)?.intValue == 200 else { return nil }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: setCookie, for: url)
        guard let cookie = cookies.first(where: { $0.name == "MUSIC_A" && !$0.value.isEmpty }) else { return nil }
        let expiry = cookie.expiresDate ?? now.addingTimeInterval(150 * 86_400)
        return Guest(musicA: cookie.value, expires: Int64(expiry.timeIntervalSince1970))
    }

    // MARK: - 动态封面

    /// dynamic-cover 的几种结局。
    public enum Lookup: Equatable, Sendable {
        case video(URL)
        /// 问成了、这首没有(或者给的地址不是网易云的视频主机)。
        case none
        /// code 301:身份无效。
        case loggedOut
        /// 网络、HTTP 状态不是 200、别的 code(含限流的 405)、形状不对:没问成。
        case failed
    }

    public static func dynamicCoverURL(songID: String) -> URL? {
        URL(string: "https://music.163.com/api/songplay/dynamic-cover?songId=\(songID)")
    }

    /// 应答 → 结局。视频地址一律换成 https,只认 `*.music.126.net` 主机。
    public static func lookup(fromResponse data: Data) -> Lookup {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = (root["code"] as? NSNumber)?.intValue else { return .failed }
        if code == 301 { return .loggedOut }
        guard code == 200, let payload = root["data"] as? [String: Any] else { return .failed }
        guard let raw = (payload["videoPlayUrl"] as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              var parts = URLComponents(string: raw), let host = parts.host?.lowercased(),
              host.hasSuffix(".music.126.net") else { return .none }
        parts.scheme = "https"
        return parts.url.map(Lookup.video) ?? .none
    }

    /// 带游客身份问一次。记进对外请求审计日志(服务名 `netease`)。
    public static func fetchLookup(songID: String, guest: String, session: URLSession) async -> Lookup {
        guard let url = dynamicCoverURL(songID: songID) else { return .failed }
        var req = request(url)
        req.setValue("os=pc; MUSIC_A=\(guest)", forHTTPHeaderField: "Cookie")
        guard let (status, data, _) = await send(req, operation: "dynamic-cover", session: session), status == 200 else {
            return .failed
        }
        return lookup(fromResponse: data)
    }

    /// 换一个随机设备号注册一次游客。
    public static func register(session: URLSession, now: Date = Date()) async -> Guest? {
        let deviceID = (0..<26).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined()
        guard let url = registerURL(deviceID: deviceID) else { return nil }
        var req = request(url)
        req.setValue("os=pc", forHTTPHeaderField: "Cookie")
        guard let (status, data, resp) = await send(req, operation: "guest.register", session: session) else { return nil }
        let setCookie = (resp.value(forHTTPHeaderField: "Set-Cookie")).map { ["Set-Cookie": $0] } ?? [:]
        return guest(status: status, body: data, setCookie: setCookie, url: url, now: now)
    }

    /// 浏览器的 User-Agent 和网易云的 Referer,同 `NeteaseEditorialInfo`;Cookie 只发自己设的那条,不进共享的 Cookie 存储。
    private static func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.httpShouldHandleCookies = false
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                     + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        return req
    }

    private static func send(_ req: URLRequest, operation: String,
                             session: URLSession) async -> (Int, Data, HTTPURLResponse)? {
        let host = req.url?.host ?? "music.163.com"
        let start = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let http = resp as? HTTPURLResponse
            NetworkAuditLog.record(service: "netease", operation: operation, host: host, statusCode: http?.statusCode,
                                   durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
            return http.map { ($0.statusCode, data, $0) }
        } catch {
            NetworkAuditLog.record(service: "netease", operation: operation, host: host, statusCode: nil,
                                   durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            return nil
        }
    }
}

/// 游客身份的取用:内存里、盘上(引擎可能先注册了)都没有能用的才注册,连试几次都没成就隔一阵再试;被拒的身份丢掉、
/// 换一个再问一次。
public actor NeteaseGuestSession {
    public static let shared = NeteaseGuestSession(file: LyrimusePaths.configFile(NeteaseMotionCover.guestFileName))

    private let file: URL
    private let attempts: Int
    private let gap: Duration
    private let cooldown: TimeInterval
    private let registerOnce: @Sendable () async -> NeteaseMotionCover.Guest?
    private var cached: NeteaseMotionCover.Guest?
    private var retryAt: Date?
    /// 正在注册的那一次:同时来问的等它,不各注册一个。
    private var registering: Task<NeteaseMotionCover.Guest?, Never>?

    public init(file: URL, attempts: Int = 3, gap: Duration = .seconds(2), cooldown: TimeInterval = 600,
                register: (@Sendable () async -> NeteaseMotionCover.Guest?)? = nil) {
        self.file = file
        self.attempts = attempts
        self.gap = gap
        self.cooldown = cooldown
        self.registerOnce = register ?? { await NeteaseMotionCover.register(session: .shared) }
    }

    /// 能用的游客身份(MUSIC_A 的值);注册不成为 nil。
    public func guest(now: Date = Date()) async -> String? {
        if let cached, cached.usable(now: now) { return cached.musicA }
        if let disk = readFile(), disk.usable(now: now) {
            cached = disk
            return disk.musicA
        }
        if let retryAt, now < retryAt { return nil }
        let task = registering ?? Task { [attempts, gap, registerOnce] in
            for attempt in 0..<attempts {
                if attempt > 0 { try? await Task.sleep(for: gap) }
                if let fresh = await registerOnce() { return fresh }
            }
            return nil
        }
        registering = task
        let fresh = await task.value
        registering = nil
        guard let fresh else {
            retryAt = now.addingTimeInterval(cooldown)
            return nil
        }
        cached = fresh
        if let data = try? JSONEncoder().encode(fresh), FileIO.write(data, to: file) {
            FileIO.attempt("chmod", file) {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        return fresh.musicA
    }

    /// 这个身份被拒了:内存里和盘上(还是它的话)都丢掉。
    public func forget(_ musicA: String) {
        if cached?.musicA == musicA { cached = nil }
        if readFile()?.musicA == musicA { FileIO.remove(file) }
    }

    /// 带游客身份问这首的动态封面;身份被拒就丢掉、换一个再问一次。没有身份按没问成算。
    public func lookup(songID: String, session: URLSession,
                       fetch: (@Sendable (String, String) async -> NeteaseMotionCover.Lookup)? = nil) async
        -> NeteaseMotionCover.Lookup {
        let ask = fetch ?? { id, guest in await NeteaseMotionCover.fetchLookup(songID: id, guest: guest, session: session) }
        for _ in 0..<2 {
            guard let guest = await guest() else { return .failed }
            let result = await ask(songID, guest)
            guard result == .loggedOut else { return result }
            forget(guest)
        }
        return .failed
    }

    private func readFile() -> NeteaseMotionCover.Guest? {
        FileIO.decodeJSON(NeteaseMotionCover.Guest.self, from: file)
    }
}
