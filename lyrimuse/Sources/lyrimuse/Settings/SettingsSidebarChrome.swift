import AppKit
import Combine
import LyrimuseCore
import SwiftUI

// 设置侧栏的"chrome"组件(整张侧栏按系统「设置」的侧栏重排):
// 顶部身份区(Last.fm 与其下「关联平台」那一行)、有更新时的提示行、红色计数徽标,以及身份区头像的取图。分类行本身仍在
// SettingsView.sidebarLabel,账号行仍是 AccountSidebarRow —— 这里只放系统设置侧栏有、
// 我们原来没有的那几样东西。
//
// 对照关系(系统设置 → 我们):
//   Apple 账户块(头像 + 名字 + 「Apple 账户」)      → Last.fm 身份区(头像 + 用户名 + 「Last.fm 账户」)
//   「有软件更新可用 ①」                            → Sparkle 查到新版本时的同名一行,点了进「软件更新」页
//   「Apple 账户建议 ①」                             → Last.fm 账号有待处理的建议时的「Last.fm 账号建议」一行,点了进建议页
//   分组之间只留空白、没有小标题                     → 「核心设置」「账号」两个 Section 标题撤掉
//   行尾红色数字徽标                                 → 「播放器」健康警告从橙色三角改成红色计数
//   彩色圆角方块图标带一点上亮下暗的渐变              → IconBadge 统一加渐变与高光(见 SettingsView.swift)

// MARK: - 身份区

/// 侧栏顶部的 Last.fm 身份区。整行是 List 里 tag 为 `.account(.lastfm)` 的普通可选行,点了进
/// Last.fm 页,选中时跟别的分类一样铺高亮底。
///
/// 三种处境:
///  - 已连接、拿到头像:圆形头像 + 用户名 + 「Last.fm 账户」;
///  - 已连接、没头像(Last.fm 默认头像是占位星,过滤成 nil):Last.fm 品牌图裁成圆 + 用户名;
///  - 未连接:灰底白人像的占位圆 + 「连接 Last.fm」+ 「同步收听记录」。副标题必须够短:这一列只有
///    130pt 左右给文字:Last.fm 页头那句「把你播放的歌记录到 Last.fm」在这里尾巴会被截成省略号、
///    很难看;系统设置未登录时那行也是一句极短的话(「设置 iCloud、App Store 等」)。
/// 账户出问题(授权失效 / 连接失败)不在头像上挂标记,在身份区下面那一行「Last.fm 账号建议」里计数(仿系统设置
/// 「Apple 账户建议」,见 `LastfmSuggestionsSidebarRow`)。
struct LastfmIdentityRow: View {
    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var avatars = LastfmAvatarStore.shared
    // 手动切语言时让这一行重画(理由同 AccountSidebarRow)。
    @ObservedObject private var languageSettings = AppSettings.shared

    static let avatarSize: CGFloat = 36
    /// 这一行的几种文字。侧栏宽度按它们算(SettingsSidebarWidth),跟下面 body 用的是同一处;用户名是用户自己的数据,不算。
    static var connectTitle: String { L10n.t("连接 Last.fm") }
    static var connectSubtitle: String { L10n.t("同步收听记录") }
    static var connectedSubtitle: String { L10n.t("Last.fm 账号") }

    private var connected: Bool { !config.lastfmScrobbleSessionKey.isEmpty }
    private var name: String { lastfmDisplayName(config: config) }

    var body: some View {
        HStack(spacing: 10) {
            avatar
                .frame(width: Self.avatarSize, height: Self.avatarSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(connected && !name.isEmpty ? name : Self.connectTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(connected ? Self.connectedSubtitle : Self.connectSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // 取头像**不**挂在这一行的 .task 上:装机实测,侧栏 List 行上的 .task(id) 一次都
        // 没跑(设置窗口开着、行画出来了,日志里却没有 user.getinfo)。改由 LastfmAvatarStore 自己驱动:
        // SettingsView.onAppear 拉一次,之后盯 ConfigStore 的变化(连上 / 断开 / 换账号),见 refreshFromConfig。
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var avatar: some View {
        if connected, let image = avatars.image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: Self.avatarSize, height: Self.avatarSize)
                .clipShape(Circle())
        } else if connected {
            // 品牌图本身是圆角方块;裁成圆之后四角的白边一并切掉(见 lastfmBadge 注释)。
            lastfmBadge(size: Self.avatarSize)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(LinearGradient(
                    colors: [Color(nsColor: .systemGray).opacity(0.72), Color(nsColor: .systemGray)],
                    startPoint: .top, endPoint: .bottom))
                Image(systemName: "person.fill")
                    .font(.system(size: Self.avatarSize * 0.5, weight: .medium))
                    .foregroundStyle(.white)
                    .offset(y: 1)
            }
        }
    }
}

// MARK: - 关联平台

/// 身份区 Last.fm 下面那一行,仿系统设置 Apple 账户下面的「家人」:图标位是一排圆形平台标志(现在只有 Discord),文字「关联平台」。
/// Last.fm 是主账号,其余平台都排进这一行;圆圈里只放平台标志,不放你的头像。List 里 tag 为 `.account(.discord)`,点了直接进
/// Discord 页;再接平台时这一行改成先进一页总览。见 14 章决策 51、53。
struct LinkedPlatformsRow: View {
    // 手动切语言时这一行要重画。
    @ObservedObject private var languageSettings = AppSettings.shared

    static let circleSize: CGFloat = 20
    /// 侧栏宽度按它算(SettingsSidebarWidth)。
    static var title: String { L10n.t("关联平台") }

    var body: some View {
        Label {
            Text(Self.title)
                .lineLimit(1)
        } icon: {
            HStack(spacing: -Self.circleSize * 0.3) {
                accountIconBadge(.discord, size: Self.circleSize, cornerRadius: Self.circleSize / 2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 「有软件更新可用」

/// Sparkle 查到新版本时在身份区下面多出的一行,右侧红色「1」。它是 List 里 tag 为 `.softwareUpdate` 的
/// 可选行(此前是一颗按钮,点了去「关于」弹 Sparkle 的对话框),点了进「软件更新」页,跟系统
/// 设置一样这一行会亮起来。没有新版本时整行不存在,不占位;页面本身仍可从「关于 › 更新 › 软件更新」进。
struct SoftwareUpdateSidebarRow: View {
    @ObservedObject private var languageSettings = AppSettings.shared

    /// 侧栏宽度按它算(SettingsSidebarWidth)。
    static var title: String { L10n.t("有软件更新可用") }

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 4)
            SidebarCountBadge(count: 1)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 「Last.fm 账号建议」

/// 仿系统设置身份区下面那一行「Apple 账户建议 ①」:Last.fm 账号有待处理的建议时才有,右侧红色计数。它是 List 里 tag 为
/// `.lastfmSuggestions` 的可选行,点了进「Last.fm 账号建议」页,这一行亮起来。有哪几种建议见 Core `LastfmAccountSuggestion`。
struct LastfmSuggestionsSidebarRow: View {
    let count: Int
    @ObservedObject private var languageSettings = AppSettings.shared

    /// 侧栏宽度按它算(SettingsSidebarWidth)。
    static var title: String { L10n.t("Last.fm 账号建议") }

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 4)
            SidebarCountBadge(count: count)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 侧栏收不起来

/// 设置窗的侧栏不许收起:它是这扇窗唯一的导航,收起后界面里没有地方能把它拿回来(工具栏的边栏开关去掉了,App 也没有
/// 「显示边栏」菜单),而收起的状态系统会存进偏好(`NSSplitView Subview Frames …`),重启也还是收着。所以把
/// NavigationSplitView 底下侧栏那一项设成不能收起(往左拖到最窄就停),已经收着的当场展开。SwiftUI 改这一列的宽度区间
/// (切界面语言)时会把 canCollapse 改回 true,所以分栏每次重新布局都再设一遍。
///
/// 侧栏的默认宽度变了(切界面语言、系统「侧栏图标大小」换档)时把侧栏放回新的默认宽度,不然分栏存档里上一种语言的宽度
/// 会卡在新区间的边上(英文 250 切回中文停在 240)。默认宽度没变时不动,用户拖出来的宽度照旧。见 14 章决策 58。
@MainActor
final class SettingsSidebarCollapseGuard: NSObject {
    private weak var split: NSSplitView?
    private weak var item: NSSplitViewItem?
    /// 侧栏现在的默认宽度(SettingsView.sidebarWidth),SettingsWindowConfigurator 每次更新都传进来。
    private var defaultWidth: CGFloat?
    /// 等着放回的宽度。SwiftUI 把新的宽度区间交给分栏可能比这一拍晚,没放到位就等分栏下次重新布局再放,最多 maxAttempts 次。
    private var pendingWidth: CGFloat?
    private var pendingAttempts = 0

    /// 窗口挂上来时调。侧栏那一列可能还没进窗口,找不到就下一拍再找,最多 maxAttempts 次。
    func attach(to window: NSWindow, attempt: Int = 0) {
        guard let content = window.contentView, let (split, item) = Self.sidebar(in: content) else {
            guard attempt < Self.maxAttempts else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.attach(to: window, attempt: attempt + 1)
            }
            return
        }
        self.split = split
        self.item = item
        NotificationCenter.default.removeObserver(self, name: NSSplitView.didResizeSubviewsNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(splitViewDidResize(_:)),
                                               name: NSSplitView.didResizeSubviewsNotification, object: split)
        enforce()
        restoreIfDefaultChanged()
    }

    /// 侧栏现在的默认宽度。跟上一次记下的不一样,就把侧栏放回这个宽度。
    func setDefaultWidth(_ width: CGFloat) {
        guard width != defaultWidth else { return }
        defaultWidth = width
        restoreIfDefaultChanged()
    }

    @objc private func splitViewDidResize(_ notification: Notification) {
        enforce()
        if pendingWidth != nil { DispatchQueue.main.async { [weak self] in self?.applyPendingWidth() } }
    }

    private func enforce() {
        guard let item else { return }
        if item.canCollapse { item.canCollapse = false }
        // 在分栏自己的布局回调里直接展开会重入,挪到下一拍。
        if item.isCollapsed { DispatchQueue.main.async { [weak item] in item?.isCollapsed = false } }
    }

    /// 窗口挂上来之前不比也不记:那时放不了,挂上来再比。
    private func restoreIfDefaultChanged() {
        guard split != nil, let width = defaultWidth else { return }
        let defaults = UserDefaults.standard
        let last = (defaults.object(forKey: SettingsSidebarWidth.lastDefaultWidthKey) as? Double).map { CGFloat($0) }
        defaults.set(Double(width), forKey: SettingsSidebarWidth.lastDefaultWidthKey)
        guard let target = SettingsSidebarWidth.widthToRestore(lastDefault: last, currentDefault: width) else { return }
        pendingWidth = target
        pendingAttempts = 0
        // SwiftUI 在这次更新里才把新的宽度区间交给分栏,挪到下一拍再放,不然会被旧区间截住。
        DispatchQueue.main.async { [weak self] in self?.applyPendingWidth() }
    }

    private func applyPendingWidth() {
        guard let split, let target = pendingWidth, let sidebar = split.arrangedSubviews.first else { return }
        if sidebar.frame.width != target { split.setPosition(target, ofDividerAt: 0) }
        pendingAttempts += 1
        if sidebar.frame.width == target || pendingAttempts >= Self.maxAttempts { pendingWidth = nil }
    }

    private static let maxAttempts = 10

    /// 窗口里 NavigationSplitView 的分栏和它的侧栏那一项:分栏的代理是 NSSplitViewController,第一项是 sidebar。
    private static func sidebar(in view: NSView) -> (NSSplitView, NSSplitViewItem)? {
        if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController,
           let first = controller.splitViewItems.first, first.behavior == .sidebar {
            return (split, first)
        }
        for sub in view.subviews {
            if let found = sidebar(in: sub) { return found }
        }
        return nil
    }
}

// MARK: - 红色计数徽标

/// 行尾的红色计数徽标(系统设置 / Dock 那种):红胶囊白数字,最小 18pt 见方,两位以上自动变宽。
/// 选中(高亮底)时保持红色 —— 系统设置里「有软件更新可用」被选中时那枚也还是红的。
struct SidebarCountBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : String(count))
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(.red))
            .accessibilityHidden(true)
    }
}

// MARK: - 头像取图

/// 身份区头像的取图与缓存。只在内存里缓存一张(App 常驻,换账号才会变),不落盘、不加
/// UserDefaults 键;失败(没网 / 没头像)后 10 分钟内不重试。
///
/// 两跳网络都记进 NetworkAuditLog:`user.getinfo` 那一跳走 LastfmStatsService 的统一请求
/// 通道(限速 + 审计都在那边),拿到图 URL 后这里自己下载一次并单独记一笔 `user.avatar`。
@MainActor
final class LastfmAvatarStore: ObservableObject {
    static let shared = LastfmAvatarStore()

    @Published private(set) var image: NSImage?

    private var loadedUser = ""
    private var lastAttempt: Date?
    private var inflight: Task<Void, Never>?
    private var configObserver: AnyCancellable?
    private static let retryInterval: TimeInterval = 600

    private init() {
        // 账号一变(连上 / 断开 / 换账号)就跟着换头像。ConfigStore 的 objectWillChange 在**改之前**发,
        // 而且用户在账号页敲字时每个字符都发一次 —— 延 1.5 s 再读,读到的才是改完的值,也不会一个
        // 字符打一次接口(refresh 里按用户名去重,同名不重复请求)。
        configObserver = ConfigStore.shared.objectWillChange
            .debounce(for: .seconds(1.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refreshFromConfig() }
    }

    /// 按当前配置决定给谁取头像:连着(有 session key)就是显示名,没连就是空串(清掉)。
    /// SettingsView.onAppear 调一次;配置一变(见 init)再调。refresh 自己有去重与失败冷却,重复调不花钱。
    func refreshFromConfig() {
        let config = ConfigStore.shared
        let user = config.lastfmScrobbleSessionKey.isEmpty ? "" : lastfmDisplayName(config: config)
        Task { await refresh(user: user) }
    }

    func refresh(user: String) async {
        if user.isEmpty {
            inflight?.cancel()
            inflight = nil
            loadedUser = ""
            image = nil
            return
        }
        if user == loadedUser {
            if image != nil { return }
            if let inflight { await inflight.value; return }
            if let last = lastAttempt, Date().timeIntervalSince(last) < Self.retryInterval { return }
        } else {
            inflight?.cancel()
            image = nil
        }
        loadedUser = user
        lastAttempt = Date()
        let task = Task { [weak self] in
            let fetched = await Self.download(user: user)
            guard !Task.isCancelled, let self, self.loadedUser == user else { return }
            self.image = fetched
        }
        inflight = task
        await task.value
        if inflight == task { inflight = nil }
    }

    private static func download(user: String) async -> NSImage? {
        guard let url = await LastfmStatsService.shared.fetchUserAvatarURL(user: user) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            NetworkAuditLog.record(service: "lastfm", operation: "user.avatar", host: url.host ?? "",
                                   statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
            guard status == 200 else { return nil }
            return NSImage(data: data)
        } catch {
            NetworkAuditLog.record(service: "lastfm", operation: "user.avatar", host: url.host ?? "",
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            return nil
        }
    }
}

/// 圆形的 Discord 头像:连上 Discord 并取到了就画头像,否则画 Discord 标志。
struct DiscordAvatarImage: View {
    @ObservedObject private var avatars = DiscordAvatarStore.shared
    @ObservedObject private var discord = DiscordPresenceController.shared
    let size: CGFloat

    var body: some View {
        Group {
            if case .connected = discord.status, let image = avatars.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                accountIconBadge(.discord, size: size, cornerRadius: 0)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// 身份区 Discord 那一行的头像,以及 Discord 页预览里的头像框。连上 Discord 时按握手拿到的账号各取一次
/// (`DiscordUser.avatarURL`、`avatarDecorationURL`),只在内存里缓存,不落盘、不加 UserDefaults 键;失败后 10 分钟内
/// 不重试。下载记进 NetworkAuditLog。
@MainActor
final class DiscordAvatarStore: ObservableObject {
    static let shared = DiscordAvatarStore()

    @Published private(set) var image: NSImage?
    /// 头像的平均色:没设横幅的人,Discord 用头像的主色画资料卡横幅,预览照这个画。
    @Published private(set) var averageColor: NSColor?
    /// 头像框:Discord 上戴着才有,预先画成一组位图(`AppIconResolver.prerendered`);摘掉以后清空。
    @Published private(set) var decoration: NSImage?

    private enum Kind { case avatar, decoration }
    private var loadedURL: [Kind: URL] = [:]
    private var lastAttempt: [Kind: Date] = [:]
    private var inflight: [Kind: Task<Void, Never>] = [:]
    private var statusObserver: AnyCancellable?
    private static let retryInterval: TimeInterval = 600

    private init() {
        statusObserver = DiscordPresenceController.shared.$status
            .sink { [weak self] status in
                guard case .connected(let user?) = status else { return }
                self?.load(user.avatarURL(), .avatar)
                self?.load(user.avatarDecorationURL(), .decoration)
            }
    }

    private func load(_ url: URL?, _ kind: Kind) {
        // 没地址就清掉旧的:头像框没戴、或者摘掉了(头像总有地址,没传过头像时是默认头像)。
        guard let url else {
            inflight[kind]?.cancel()
            inflight[kind] = nil
            loadedURL[kind] = nil
            apply(nil, kind)
            return
        }
        if url == loadedURL[kind] {
            if loaded(kind) || inflight[kind] != nil { return }
            if let last = lastAttempt[kind], Date().timeIntervalSince(last) < Self.retryInterval { return }
        } else {
            inflight[kind]?.cancel()
            apply(nil, kind)
        }
        loadedURL[kind] = url
        lastAttempt[kind] = Date()
        inflight[kind] = Task { [weak self] in
            let fetched = await Self.download(url, operation: kind == .avatar ? "avatar" : "avatar-decoration")
            guard let self, !Task.isCancelled, self.loadedURL[kind] == url else { return }
            self.apply(fetched, kind)
            self.inflight[kind] = nil
        }
    }

    private func loaded(_ kind: Kind) -> Bool {
        kind == .avatar ? image != nil : decoration != nil
    }

    private func apply(_ fetched: NSImage?, _ kind: Kind) {
        switch kind {
        case .avatar:
            image = fetched
            averageColor = fetched.flatMap(Self.averageColor(of:))
        case .decoration:
            decoration = fetched.map(AppIconResolver.prerendered)
        }
    }

    /// 整张图缩到一个像素取颜色。全透明时为 nil。
    static func averageColor(of image: NSImage) -> NSColor? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn, pixel[3] > 0 else { return nil }
        let alpha = CGFloat(pixel[3])
        return NSColor(srgbRed: CGFloat(pixel[0]) / alpha, green: CGFloat(pixel[1]) / alpha, blue: CGFloat(pixel[2]) / alpha,
                       alpha: 1)
    }

    private static func download(_ url: URL, operation: String) async -> NSImage? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            NetworkAuditLog.record(service: "discord", operation: operation, host: url.host ?? "",
                                   statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
            guard status == 200 else { return nil }
            return NSImage(data: data)
        } catch {
            NetworkAuditLog.record(service: "discord", operation: operation, host: url.host ?? "",
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            return nil
        }
    }
}
