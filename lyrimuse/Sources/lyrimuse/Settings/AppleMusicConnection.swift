import AppKit
import Foundation
import LyrimuseCore
import WebKit

/// Apple Music 官方歌词源(collector/applemusic.go)的连接状态与登录流程。
///
/// 为什么需要"连接"这一步:Apple 的歌词端点(`/songs/{id}/lyrics`、`/syllable-lyrics`)
/// 只认订阅用户的 `media-user-token`,没有它一律回 404。而这个令牌拿不到第二条路——
/// 逐条实测过:
///   · 官方 MusicKit 框架要 `com.apple.developer.musickit` entitlement,只发给 Apple
///     Developer Program 成员的正式证书;本 App 是自签名,强签这条 entitlement 会被
///     amfid 直接 SIGKILL(退出码 137),连进程都起不来。
///   · 本机 Music.app 也提取不到:歌词不落盘、AppleScript 的 `lyrics` 属性对流媒体曲目
///     恒为空串、凭据由 itunescloudd 在内存里管(钥匙串里相关条目零条)。
///   · 开源社区(librelyrics-applemusic / Manzana / Music Assistant)清一色让用户去浏览器
///     复制 cookie。
///
/// 所以这里做的是那套手工流程的自动化版本:**在 App 内嵌的 WebView 里打开 Apple 自己的
/// 登录页**,登录和授权全由 Apple 的页面完成,我们只在 cookie store 里取结果。
/// ⚠️ 刻意**不**走 MusicKit JS 的 `authorize()`——那个要 developer token(付费账号),
/// 而且在嵌入式 WebView 里有已知的认证失败问题(Apple Developer Forums thread 710088,
/// Cider / lito 这些客户端都踩过)。
///
/// 令牌寿命:Apple 固定 6 个月且**不发可续期令牌**,到期只能重登一次。所以这里除了
/// "连没连"还要记住保存时间,好在接近到期时提前提示,而不是等用户某天发现歌词悄悄少了一源。
@MainActor
public final class AppleMusicConnection: ObservableObject {
    public static let shared = AppleMusicConnection()

    /// 跟 collector 侧 applemusicUserTokenPath() 指的是同一个文件,两边都写死这个名字。
    private static let tokenURL = LyrimusePaths.configFile("lyrimuse-applemusic-token.json")

    /// Apple 的硬上限。超过就必须重登,没有续期接口。
    private static let tokenLifetime: TimeInterval = 180 * 24 * 3600
    /// 剩这么多时间就开始提示"该重连了"。
    private static let renewNoticeWindow: TimeInterval = 14 * 24 * 3600

    public enum State: Equatable {
        case disconnected
        /// savedAt 是拿到令牌的时刻;expiresAt 是按 Apple 的 6 个月硬上限推出来的,
        /// 不是它自己声明的(令牌本身不是 JWT,没有可读的 exp)。
        case connected(savedAt: Date, storefront: String)
    }

    @Published public private(set) var state: State = .disconnected
    /// 登录窗口开着的时候为 true —— 按钮据此显示"登录中…"并禁用,避免开出两个窗口。
    @Published public private(set) var isConnecting = false

    private var loginWindow: AppleMusicLoginWindowController?

    private init() { refresh() }

    /// 重新读盘。连接成功、断开、以及设置页每次出现时都调一次。
    public func refresh() {
        guard let data = try? Data(contentsOf: Self.tokenURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["media_user_token"] as? String, !token.isEmpty
        else {
            state = .disconnected
            return
        }
        let saved = (obj["saved_at"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        // storefront 可能是空串 —— 登录时没等到 itua cookie。这**不是**未连接:
        // collector 首次取词时会问 /v1/me/storefront 拿权威值并写回这个文件。
        // 这里刻意不退 "us":猜一个区会让取词端点全线 404,见 applemusic.go 的注释。
        let storefront = (obj["storefront"] as? String) ?? ""
        state = .connected(savedAt: saved, storefront: storefront)
    }

    public var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// 到期时刻(按 Apple 的 6 个月硬上限推算)。未连接时为 nil。
    public var expiresAt: Date? {
        guard case let .connected(savedAt, _) = state else { return nil }
        return savedAt.addingTimeInterval(Self.tokenLifetime)
    }

    /// 是否该提示用户重连了(已过期,或进入到期前两周)。
    public var needsRenewal: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < Self.renewNoticeWindow
    }

    /// 打开内嵌登录窗口。已经开着就只是把它带到前台,不重复开。
    public func connect() {
        if let loginWindow {
            loginWindow.showWindow(nil)
            loginWindow.window?.makeKeyAndOrderFront(nil)
            return
        }
        isConnecting = true
        let controller = AppleMusicLoginWindowController(tokenURL: Self.tokenURL) { [weak self] success in
            guard let self else { return }
            self.loginWindow = nil
            self.isConnecting = false
            if success { self.refresh() }
        }
        loginWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 断开:删掉令牌文件,并清掉 WebView 那份登录态(否则下次点"连接"会直接跳过登录页、
    /// 把同一个账号的令牌又写回来,用户会以为断开没生效)。
    public func disconnect() {
        try? FileManager.default.removeItem(at: Self.tokenURL)
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let apple = records.filter { $0.displayName.contains("apple.com") }
            guard !apple.isEmpty else { return }
            store.removeData(ofTypes: types, for: apple) {}
        }
        refresh()
    }
}

/// 内嵌的 Apple Music 登录窗口。只做一件事:把 Apple 的登录页显示出来,轮询 cookie store,
/// 一旦出现 `media-user-token` 就落盘并自动关窗。
///
/// 为什么用轮询而不是监听导航完成:登录成功后 Apple 的页面会在**前端**继续走几步
/// (授权、跳转、写 cookie),`didFinish` 触发的时刻 cookie 未必已经写好;而轮询只关心
/// "cookie 出现了没有",跟页面走到哪一步无关,对 Apple 改版也更不敏感。
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
    /// 8 秒是拍的:轮询本身 1 秒一次,这里给足 Apple 登录流程收尾的余量,又不至于让用户
    /// 盯着一个已经登录成功的窗口干等太久。
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
                guard let token = cookies.first(where: { $0.name == "media-user-token" })?.value,
                      !token.isEmpty else { return }
                // storefront 取 Apple 标记账号所在区的 itua cookie。
                //
                // ⚠️ 这两个 cookie 由 Apple 的登录流程**分别**写入,不保证同时就位,而这个
                // 轮询是在 media-user-token 一出现就收网的 —— 早先的写法在这里直接
                // `?? "us"`,于是这个时序差会被固化成一个错的区,后果是取词端点全线 404、
                // 整个 Apple Music 源静默失效(详见 applemusic.go 的 applemusicLoadUserToken)。
                // 所以这里改成:先给 itua 一段宽限期;实在等不到就**留空**,让 collector
                // 用 /v1/me/storefront 问权威答案(那个端点要 developer token,App 侧没有)。
                let itua = (cookies.first(where: { $0.name == "itua" })?.value ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !itua.isEmpty {
                    self.finish(token: token, storefront: itua.lowercased())
                    return
                }
                guard let firstSeen = self.tokenFirstSeenAt else {
                    self.tokenFirstSeenAt = Date()
                    return
                }
                guard Date().timeIntervalSince(firstSeen) >= Self.storefrontGrace else { return }
                self.finish(token: token, storefront: "")
            }
        }
    }

    private func finish(token: String, storefront: String) {
        finished = true
        pollTimer?.invalidate()
        pollTimer = nil

        let payload: [String: Any] = [
            "media_user_token": token,
            "storefront": storefront,
            "saved_at": Int(Date().timeIntervalSince1970),
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            try FileManager.default.createDirectory(
                at: tokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 0o600:这是用户 Apple Music 账号的访问凭据,跟 collector 侧写 musixmatch
            // token 用同一档权限,不让同机其它用户读到。
            try data.write(to: tokenURL, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        } catch {
            // 落盘失败(磁盘满/权限)时当作没连上——宁可让用户再点一次,也不要显示成"已连接"
            // 却查不到歌词。
            completion(false)
            close()
            return
        }
        completion(true)
        close()
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
