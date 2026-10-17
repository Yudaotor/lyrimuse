import AppKit
import Combine
import LyrimuseCore
import Network
import OSLog
import SystemConfiguration

/// 网页歌词、OBS 输出的本地服务(19 章),两个各自一个实例、各占一个端口:`GET /` 给页面,`/ws` 升级成 WebSocket,
/// 网页那个推画面帧、OBS 那个推歌词数据。
///
/// 两个各管各的:开关、「允许局域网设备访问」、密钥、端口都分开存(网页在「歌词显示 › 歌词窗口」,OBS 在
/// 「歌词显示 › 悬浮歌词」)。局域网关着时只绑 127.0.0.1,别的设备连不上、也不经过系统防火墙;开着时绑所有网卡,
/// 别的设备的请求要带链接里的密钥。端口被占用就报错,不自动换:OBS 里填好的地址、手机上存的链接要一直有效;
/// 两个端口相同时都不监听。换了密钥就断开别的设备的连接。
@MainActor
final class WebLyricsServer: ObservableObject {
    enum Channel {
        case screen
        case obs
    }

    static let screen = WebLyricsServer(channel: .screen)
    static let obs = WebLyricsServer(channel: .obs)
    /// 同时连着的连接上限(含还没升级的普通请求)。
    static let maxConnections = 8

    static func startAll() {
        screen.start()
        obs.start()
    }

    enum State: Equatable {
        case off
        case running(lan: Bool)
        case portInUse
        case failed(String)
    }

    let channel: Channel
    @Published private(set) var state: State = .off
    /// 此刻连着的页面。
    @Published private(set) var viewerCount = 0
    /// 其中从别的设备连进来的(不算这台 Mac 自己开的)。
    @Published private(set) var remoteViewerCount = 0

    let screens = WebLyricsScreenHub()
    let obsFeed = WebLyricsObsFeed()

    private var listener: NWListener?
    private var listenerLAN = false
    private var listenerPort = 0
    private var connections: [ObjectIdentifier: WebLyricsConnection] = [:]
    private var subs: [AnyCancellable] = []
    private var started = false
    private let log = Logger(subsystem: "me.yudaotor.lyrimuse", category: "web-lyrics")

    private init(channel: Channel) {
        self.channel = channel
    }

    // MARK: - 这一个的设置

    var port: Int {
        let s = AppSettings.shared
        return channel == .screen ? s.webLyricsPort : s.obsLyricsPort
    }

    var token: String {
        let s = AppSettings.shared
        return channel == .screen ? s.webLyricsToken : s.obsLyricsToken
    }

    var allowsLAN: Bool {
        let s = AppSettings.shared
        return channel == .screen ? s.webLyricsAllowLAN : s.obsLyricsAllowLAN
    }

    /// 另一个服务此刻占着的端口(开着才算)。
    private static func otherPort(of channel: Channel) -> Int? {
        let s = AppSettings.shared
        switch channel {
        case .screen: return s.obsLyricsEnabled ? s.obsLyricsPort : nil
        case .obs: return s.webLyricsEnabled ? s.webLyricsPort : nil
        }
    }

    func start() {
        guard !started else { return }
        started = true
        let s = AppSettings.shared
        let enabled = channel == .screen ? s.$webLyricsEnabled : s.$obsLyricsEnabled
        let lan = channel == .screen ? s.$webLyricsAllowLAN : s.$obsLyricsAllowLAN
        let port = channel == .screen ? s.$webLyricsPort : s.$obsLyricsPort
        let token = channel == .screen ? s.$webLyricsToken : s.$obsLyricsToken
        // 另一个的开关和端口也要听:两边端口撞了时谁都不监听,改开之后接着起来。
        let other = channel == .screen
            ? Publishers.CombineLatest(s.$obsLyricsEnabled, s.$obsLyricsPort).eraseToAnyPublisher()
            : Publishers.CombineLatest(s.$webLyricsEnabled, s.$webLyricsPort).eraseToAnyPublisher()
        subs = [
            Publishers.CombineLatest4(enabled, lan, port, other)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] enabled, lan, port, _ in self?.reconcile(enabled: enabled, lan: lan, port: port) },
            token.dropFirst().removeDuplicates()
                .sink { [weak self] _ in self?.dropRemoteConnections() },
        ]
    }

    // MARK: - 链接

    /// 这台 Mac 自己打开的地址(回环不要密钥)。
    var localURL: URL { WebLyricsLinks.url(host: "localhost", port: port)! }

    /// 铺一层棋盘格底,OBS 页在普通浏览器里也看得见效果。
    var previewURL: URL { WebLyricsLinks.url(host: "localhost", port: port, preview: true)! }

    /// 别的设备打开的地址。`.local` 那条换了 IP 也一直有效,二维码用它;IP 那条给认不了 `.local` 的设备
    /// (安卓浏览器不一定认,有的公共 Wi-Fi 拦局域网广播)。拿不到名字 / 没有局域网时为 nil。
    var lanHostURL: URL? {
        guard let name = LocalNetworkAddress.localHostNames().first else { return nil }
        return WebLyricsLinks.url(host: name, port: port, token: token)
    }

    var lanIPURL: URL? {
        guard let ip = LocalNetworkAddress.primaryIPv4() else { return nil }
        return WebLyricsLinks.url(host: ip, port: port, token: token)
    }

    // MARK: - 监听

    private func reconcile(enabled: Bool, lan: Bool, port: Int) {
        guard enabled else {
            stopListening()
            state = .off
            return
        }
        if Self.otherPort(of: channel) == port {
            stopListening()
            state = .portInUse
            return
        }
        if listener != nil, listenerLAN == lan, listenerPort == port, case .running = state { return }
        stopListening()
        startListening(lan: lan, portNumber: port)
    }

    /// 密钥换了:别的设备的连接全部断开(它们手里是旧链接,重连会被拦下);本机的不受影响。
    private func dropRemoteConnections() {
        for connection in Array(connections.values) where !connection.isLoopback { connection.close() }
    }

    private func startListening(lan: Bool, portNumber: Int) {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: portNumber)) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let made: NWListener
        do {
            if lan {
                made = try NWListener(using: params, on: port)
            } else {
                params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
                made = try NWListener(using: params)
            }
        } catch {
            state = .failed(error.localizedDescription)
            log.error("listener create failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        listener = made
        listenerLAN = lan
        listenerPort = portNumber
        made.stateUpdateHandler = { [weak self, weak made] newState in
            MainActor.assumeIsolated {
                guard let self, let made, self.listener === made else { return }
                switch newState {
                case .ready:
                    self.state = .running(lan: lan)
                    self.log.info("listening on \(portNumber, privacy: .public) lan=\(lan, privacy: .public) obs=\(self.channel == .obs, privacy: .public)")
                case .failed(let error):
                    if case .posix(let code) = error, code == .EADDRINUSE {
                        self.state = .portInUse
                    } else {
                        self.state = .failed(error.localizedDescription)
                    }
                    self.log.error("listener failed: \(error.localizedDescription, privacy: .public)")
                    self.stopListening()
                default:
                    break
                }
            }
        }
        made.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        made.start(queue: .main)
    }

    private func stopListening() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for connection in Array(connections.values) { connection.close() }
        connections = [:]
        updateViewerCount()
    }

    private func accept(_ nw: NWConnection) {
        guard connections.count < Self.maxConnections else {
            nw.cancel()
            return
        }
        let connection = WebLyricsConnection(nw: nw, server: self)
        connections[ObjectIdentifier(connection)] = connection
        connection.start()
    }

    func connectionClosed(_ connection: WebLyricsConnection) {
        guard connections.removeValue(forKey: ObjectIdentifier(connection)) != nil else { return }
        screens.remove(connection)
        obsFeed.remove(connection)
        updateViewerCount()
    }

    private func updateViewerCount() {
        viewerCount = connections.values.filter(\.isViewer).count
        remoteViewerCount = connections.values.filter { $0.isViewer && !$0.isLoopback }.count
    }

    // MARK: - 请求

    func handle(_ request: WebLyricsHTTP.Request, on connection: WebLyricsConnection) {
        guard request.method == "GET" else {
            connection.respondAndClose(WebLyricsHTTP.response(status: 405, reason: "Method Not Allowed"))
            return
        }
        guard WebLyricsAccess.hostAllowed(request.headers["host"], localNames: LocalNetworkAddress.localHostNames()) else {
            connection.respondAndClose(WebLyricsHTTP.response(status: 403, reason: "Forbidden"))
            return
        }
        guard WebLyricsAccess.permits(remoteIsLoopback: connection.isLoopback, lanEnabled: listenerLAN,
                                      token: token, query: request.query) else {
            connection.respondAndClose(WebLyricsHTTP.response(
                status: 403, reason: "Forbidden", contentType: "text/html; charset=utf-8",
                body: Data(WebLyricsPages.messagePage(L10n.t("链接无效或已失效")).utf8)))
            return
        }
        switch request.path {
        case "/":
            let page = channel == .obs ? WebLyricsPages.obsPage() : WebLyricsPages.screenPage()
            connection.respondAndClose(WebLyricsHTTP.response(
                status: 200, reason: "OK", contentType: "text/html; charset=utf-8", body: Data(page.utf8),
                extraHeaders: [("Content-Security-Policy",
                                "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src blob: data:; connect-src 'self' ws: wss:")]))
        case "/ws":
            guard request.isWebSocketUpgrade, let key = request.headers["sec-websocket-key"] else {
                connection.respondAndClose(WebLyricsHTTP.response(status: 400, reason: "Bad Request"))
                return
            }
            connection.upgrade(key: key)
            if channel == .obs {
                connection.role = .obs
                obsFeed.add(connection)
            } else {
                let viewport = WebLyricsViewport(query: request.query)
                connection.role = .screen(viewport)
                screens.add(connection, viewport: viewport)
            }
            connection.sendText(WebLyricsPages.helloMessage())
            updateViewerCount()
        case "/favicon.ico":
            connection.respondAndClose(WebLyricsHTTP.response(status: 204, reason: "No Content"))
        default:
            connection.respondAndClose(WebLyricsHTTP.response(status: 404, reason: "Not Found"))
        }
    }
}

/// 一条连接:先按 HTTP 收请求头,升级成 WebSocket 之后收控制帧、往外推数据。都在主队列上跑。
@MainActor
final class WebLyricsConnection {
    enum Role: Equatable {
        case http
        case screen(WebLyricsViewport)
        case obs
    }

    let nw: NWConnection
    var role: Role = .http
    private weak var server: WebLyricsServer?
    private var buffer = Data()
    private var closed = false
    /// 上一帧画面还没发完时新帧直接丢:网络慢的设备只会掉帧,不会越积越多、越来越迟。
    private var frameInFlight = false

    init(nw: NWConnection, server: WebLyricsServer) {
        self.nw = nw
        self.server = server
    }

    var isViewer: Bool { role != .http }

    /// 对端是本机回环(127.0.0.1 / ::1 / ::ffff:127.0.0.1)。
    var isLoopback: Bool {
        guard case let .hostPort(host, _) = nw.endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address):
            if address.isLoopback { return true }
            let bytes = [UInt8](address.rawValue)
            return bytes.count == 16 && bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF && bytes[12] == 127
        default: return false
        }
    }

    func start() {
        nw.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
        }
        nw.start(queue: .main)
        receive()
    }

    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.process()
                }
                if isComplete || error != nil {
                    self.close()
                } else if !self.closed {
                    self.receive()
                }
            }
        }
    }

    private func process() {
        switch role {
        case .http:
            switch WebLyricsHTTP.parse(buffer) {
            case .needMore: return
            case .invalid:
                respondAndClose(WebLyricsHTTP.response(status: 400, reason: "Bad Request"))
            case let .request(request, consumed):
                buffer.removeFirst(consumed)
                server?.handle(request, on: self)
            }
        case .screen, .obs:
            while !closed {
                switch WebSocketFrame.decode(buffer) {
                case .needMore: return
                case .invalid:
                    close()
                    return
                case let .frame(frame):
                    buffer.removeFirst(frame.consumed)
                    switch frame.opcode {
                    case WebSocketFrame.Opcode.close.rawValue:
                        nw.send(content: WebSocketFrame.encode(Data(), opcode: .close), completion: .contentProcessed { [weak self] _ in
                            MainActor.assumeIsolated { self?.close() }
                        })
                        return
                    case WebSocketFrame.Opcode.ping.rawValue:
                        nw.send(content: WebSocketFrame.encode(frame.payload, opcode: .pong), completion: .contentProcessed { _ in })
                    case WebSocketFrame.Opcode.text.rawValue:
                        if case .screen = role { server?.screens.message(self, payload: frame.payload) }
                    default:
                        break
                    }
                }
            }
        }
    }

    func respondAndClose(_ data: Data) {
        guard !closed else { return }
        nw.send(content: data, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }

    func upgrade(key: String) {
        nw.send(content: WebLyricsHTTP.upgradeResponse(key: key), completion: .contentProcessed { _ in })
    }

    /// `frame` 已经是包好的 WebSocket 帧(`WebLyricsFrameSource` 在出帧线程上包的),这里不再编码。
    func sendEncodedFrame(_ frame: Data) {
        guard !closed, !frameInFlight else { return }
        frameInFlight = true
        nw.send(content: frame, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                self?.frameInFlight = false
                if error != nil { self?.close() }
            }
        })
    }

    func sendText(_ text: String) {
        guard !closed else { return }
        nw.send(content: WebSocketFrame.encode(Data(text.utf8), opcode: .text), completion: .contentProcessed { _ in })
    }

    func close() {
        guard !closed else { return }
        closed = true
        nw.stateUpdateHandler = nil
        nw.cancel()
        server?.connectionClosed(self)
    }
}

/// 本机在局域网里的名字和地址。
enum LocalNetworkAddress {
    /// `Host` 头里认的本机名字:`<本地主机名>.local`。
    static func localHostNames() -> Set<String> {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else { return [] }
        return ["\(name).local"]
    }

    /// 第一块在用的网卡(en0 优先)上的局域网 IPv4。
    static func primaryIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var found: [(name: String, ip: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254.") else { continue }
            found.append((name, ip))
        }
        return found.sorted { $0.name < $1.name }.first?.ip
    }
}
