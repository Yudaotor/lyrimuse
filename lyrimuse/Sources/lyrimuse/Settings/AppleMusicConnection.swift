import AppKit
import Foundation
import LyrimuseCore
import WebKit

/// Apple Music 官方歌词源(collector/applemusic.go)的连接状态与登录流程。
///
/// Apple 的歌词端点(`/songs/{id}/lyrics`、`/syllable-lyrics`)只认订阅用户的 `media-user-token`,没有它
/// 一律回 404。这个令牌没有第二条路可拿:MusicKit 框架要付费开发者证书才能签的 entitlement(自签名强签会被
/// amfid 直接杀掉),本机 Music.app 也提取不到。所以做的是「去浏览器复制 cookie」那套手工流程的自动化版本:
/// **在 App 内嵌的 WebView 里打开 Apple 自己的登录页**,登录和授权全由 Apple 的页面完成,我们只在 cookie
/// store 里取结果。不走 MusicKit JS 的 `authorize()`:要 developer token,且在嵌入式 WebView 里认证不稳。
/// 取舍的完整依据见 09 章「Apple Music 连接」。
///
/// 令牌寿命:Apple 固定 6 个月且**不发可续期令牌**,到期只能重登一次。所以除了"连没连"还要记住到期时刻,
/// 接近到期时提前提示;collector 带着令牌被拒过(`rejected_at`)时同样提示,不等用户发现歌词悄悄少了一源。
@MainActor
public final class AppleMusicConnection: ObservableObject {
    public static let shared = AppleMusicConnection()

    /// 跟 collector 侧 applemusicUserTokenPath() 指的是同一个文件,两边都写死这个名字。
    private static let tokenURL = LyrimusePaths.configFile("lyrimuse-applemusic-token.json")

    /// 剩这么多时间就开始提示"该重连了"。
    private static let renewNoticeWindow: TimeInterval = 14 * 24 * 3600

    public enum State: Equatable {
        case disconnected
        /// savedAt 是拿到令牌的时刻。storefront 可能是空串 —— 登录时没等到 itua cookie。这**不是**未连接:
        /// collector 首次取词时会问 /v1/me/storefront 拿权威值并写回。别在这里退 "us":猜一个区会让取词
        /// 端点全线 404,见 applemusic.go 的注释。
        case connected(savedAt: Date, storefront: String)
    }

    @Published public private(set) var state: State = .disconnected
    /// collector 带着当前这份令牌被 Apple 拒过(过期或被吊销)。
    @Published public private(set) var isRejected = false
    /// 登录窗口开着(或正在清理旧登录态、准备打开)时为 true —— 按钮据此显示"登录中…"并禁用,避免开出两个窗口。
    @Published public private(set) var isConnecting = false

    private var tokenInfo: AppleMusicTokenFile.Info?
    private var loginWindow: AppleMusicLoginWindowController?

    private init() { refresh() }

    /// 重新读盘。连接成功、断开、以及设置页每次出现时都调一次。
    public func refresh() {
        let fileDate = (try? FileManager.default.attributesOfItem(atPath: Self.tokenURL.path))?[.modificationDate] as? Date
        guard let data = try? Data(contentsOf: Self.tokenURL),
              let info = AppleMusicTokenFile.parse(data, fileDate: fileDate ?? Date())
        else {
            tokenInfo = nil
            isRejected = false
            state = .disconnected
            return
        }
        tokenInfo = info
        isRejected = info.rejected
        state = .connected(savedAt: info.savedAt, storefront: info.storefront)
    }

    public var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// 到期时刻:cookie 自带的过期时刻,没有时按 Apple 的 6 个月硬上限推算。未连接时为 nil。
    public var expiresAt: Date? { tokenInfo?.expiresAt }

    /// 是否该提示用户重连了(被拒过、已过期,或进入到期前两周)。
    public var needsRenewal: Bool {
        guard let expiresAt else { return false }
        return isRejected || expiresAt.timeIntervalSinceNow < Self.renewNoticeWindow
    }

    /// 打开内嵌登录窗口。已经开着就只是把它带到前台,不重复开。
    ///
    /// 打开前先清掉 WebView 里 apple.com 的登录态、等清理完成再加载登录页:持久化的 cookie store 里还躺着
    /// 上一份令牌时,轮询一秒内就会把它原样读回来,窗口一闪就关,「重新连接」只是把倒计时重置了、令牌还是
    /// 那份快到期(或已被拒)的。
    public func connect() {
        if let loginWindow {
            loginWindow.showWindow(nil)
            loginWindow.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard !isConnecting else { return }
        isConnecting = true
        Self.clearAppleWebsiteData { [weak self] in
            guard let self, self.isConnecting, self.loginWindow == nil else { return }
            let controller = AppleMusicLoginWindowController(tokenURL: Self.tokenURL) { [weak self] success in
                guard let self else { return }
                self.loginWindow = nil
                self.isConnecting = false
                if success { self.refresh() }
            }
            self.loginWindow = controller
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 断开:删掉令牌文件,并清掉 WebView 那份登录态(否则下次点"连接"会直接跳过登录页、
    /// 把同一个账号的令牌又写回来,用户会以为断开没生效)。
    public func disconnect() {
        try? FileManager.default.removeItem(at: Self.tokenURL)
        Self.clearAppleWebsiteData {}
        refresh()
    }

    /// 清掉默认 WebView 数据存储里 apple.com 的全部数据,完成后在主线程回调。
    private static func clearAppleWebsiteData(then completion: @escaping @MainActor () -> Void) {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let apple = records.filter { $0.displayName.contains("apple.com") }
            guard !apple.isEmpty else {
                Task { @MainActor in completion() }
                return
            }
            store.removeData(ofTypes: types, for: apple) {
                Task { @MainActor in completion() }
            }
        }
    }
}

/// 内嵌的 Apple Music 登录窗口。只做一件事:把 Apple 的登录页显示出来,轮询 cookie store,
/// 一旦出现 `media-user-token` 就落盘并自动关窗。
///
/// 用轮询而不是监听导航完成:登录成功后 Apple 的页面会在**前端**继续走几步(授权、跳转、写 cookie),
/// `didFinish` 触发的时刻 cookie 未必已经写好;轮询只关心"cookie 出现了没有",跟页面走到哪一步无关。
@MainActor
final class AppleMusicLoginWindowController: NSWindowController, WKNavigationDelegate {
    private let tokenURL: URL
    private let completion: (Bool) -> Void
    private var webView: WKWebView!
    private var pollTimer: Timer?
    private var finished = false
    /// 先看到 media-user-token、但 itua 还没写上的时刻。用来给 itua 一段宽限期。
    private var tokenFirstSeenAt: Date?

    /// 看到令牌后,最多再等这么久让 itua cookie 落地。等不到就留空交给 collector 去问。
    /// 轮询 1 秒一次,8 秒给足 Apple 登录流程收尾的余量,又不至于让用户盯着已经登录成功的窗口干等。
    private static let storefrontGrace: TimeInterval = 8

    init(tokenURL: URL, completion: @escaping (Bool) -> Void) {
        self.tokenURL = tokenURL
        self.completion = completion

        let config = WKWebViewConfiguration()
        // 用持久化的默认 store:令牌写在 cookie 里,非持久化 store 一关窗就没了。
        config.websiteDataStore = .default()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 780), configuration: config)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 780),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = L10n.t("连接 Apple Music")
        window.contentView = web
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        self.webView = web
        web.navigationDelegate = self
        window.delegate = self

        web.load(URLRequest(url: URL(string: "https://music.apple.com/login")!))
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollForToken() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func pollForToken() {
        guard !finished else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                guard let tokenCookie = cookies.first(where: { $0.name == "media-user-token" }),
                      !tokenCookie.value.isEmpty else { return }
                // storefront 取 Apple 标记账号所在区的 itua cookie。它和 media-user-token 由登录流程分别写入、
                // 不保证同时就位。别在这里退回 "us":猜错区会让取词端点全线 404、整个 Apple Music 源静默失效
                // (见 applemusic.go 的 applemusicLoadUserToken)。先给 itua 一段宽限期,实在等不到就**留空**,
                // 由 collector 用 /v1/me/storefront 问权威答案(那个端点要 developer token,App 侧没有)。
                let itua = (cookies.first(where: { $0.name == "itua" })?.value ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !itua.isEmpty {
                    self.finish(token: tokenCookie.value, storefront: itua.lowercased(), expiresAt: tokenCookie.expiresDate)
                    return
                }
                guard let firstSeen = self.tokenFirstSeenAt else {
                    self.tokenFirstSeenAt = Date()
                    return
                }
                guard Date().timeIntervalSince(firstSeen) >= Self.storefrontGrace else { return }
                self.finish(token: tokenCookie.value, storefront: "", expiresAt: tokenCookie.expiresDate)
            }
        }
    }

    private func finish(token: String, storefront: String, expiresAt: Date?) {
        finished = true
        pollTimer?.invalidate()
        pollTimer = nil

        let payload = AppleMusicTokenFile.payload(token: token, storefront: storefront, savedAt: Date(), expiresAt: expiresAt)
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            try Self.writeCredentialFile(data, to: tokenURL)
        } catch {
            // 落盘失败(磁盘满/权限)时当作没连上——宁可让用户再点一次,也不要显示成"已连接"却查不到歌词。
            completion(false)
            close()
            return
        }
        completion(true)
        close()
    }

    /// 凭据文件从创建那一刻起就是 0o600(先建同目录临时文件再改名),不存在「先按默认权限写好、再 chmod」
    /// 之间同机其它用户读得到的窗口。collector 侧写 musixmatch token 同一档权限。
    private static func writeCredentialFile(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(tmp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

extension AppleMusicLoginWindowController: NSWindowDelegate {
    /// 用户自己把窗口关掉 = 放弃这次连接。计时器必须在这里停掉,否则窗口没了它还在跑。
    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        guard !finished else { return }
        finished = true
        completion(false)
    }
}
