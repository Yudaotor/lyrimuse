import AppKit
import Combine
import LyrimuseCore
import SwiftUI

// 设置侧栏的"chrome"组件(2026-09-12,整张侧栏按系统「设置」的侧栏重排,用户拍板):
// 顶部身份区、有更新时的提示行、红色计数徽标,以及身份区头像的取图。分类行本身仍在
// SettingsView.sidebarLabel,账号行仍是 AccountSidebarRow —— 这里只放系统设置侧栏有、
// 我们原来没有的那几样东西。
//
// 对照关系(系统设置 → 我们):
//   Apple 账户块(头像 + 名字 + 「Apple 账户」)      → Last.fm 身份区(头像 + 用户名 + 「Last.fm 账户」)
//   「有软件更新可用 ①」                            → Sparkle 查到新版本时的同名一行,点了进「软件更新」页
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
///    130pt 左右给文字,首版用的是 Last.fm 页头那句「把你播放的歌记录到 Last.fm」,尾巴截成省略号,
///    用户 2026-09-12 看了说丑;系统设置未登录时那行也是一句极短的话(「设置 iCloud、App Store 等」)。
/// 授权失效 / 连接失败时头像右上角挂一枚红色「!」小徽标(系统设置在账户出问题时就是把红点
/// 挂在头像上),悬停看原因;这一档判定沿用 destinationStatus,跟 Last.fm 页头同一份逻辑。
struct LastfmIdentityRow: View {
    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var lastfmConnect = LastfmConnectController.shared
    @ObservedObject private var mirrorStatus = LastfmMirrorStatusWatcher.shared
    @ObservedObject private var avatars = LastfmAvatarStore.shared
    // 手动切语言时让这一行重画(理由同 AccountSidebarRow)。
    @ObservedObject private var languageSettings = AppSettings.shared

    static let avatarSize: CGFloat = 36

    private var connected: Bool { !config.lastfmScrobbleSessionKey.isEmpty }
    private var name: String { lastfmDisplayName(config: config) }

    private var status: DestinationStatus {
        destinationStatus(for: .lastfm, config: config, lastfmConnect: lastfmConnect, mirrorInfo: mirrorStatus.info)
    }

    var body: some View {
        HStack(spacing: 10) {
            avatar
                .frame(width: Self.avatarSize, height: Self.avatarSize)
                .overlay(alignment: .topTrailing) {
                    if case .error(let message) = status {
                        SidebarAlertDot()
                            .offset(x: 3, y: -3)
                            .help(message)
                            .accessibilityLabel(message)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(connected && !name.isEmpty ? name : L10n.t("连接 Last.fm"))
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(connected ? L10n.t("Last.fm 账户") : L10n.t("同步收听记录"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // 取头像**不**挂在这一行的 .task 上:2026-09-12 装机实测,侧栏 List 行上的 .task(id:) 一次都
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

/// 头像右上角的红色「!」小圆点(账户出问题)。
private struct SidebarAlertDot: View {
    var body: some View {
        ZStack {
            Circle().fill(.red)
            Text("!")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 14, height: 14)
        // 跟高亮底 / 侧栏底之间描一圈,不管底色是什么都不会跟头像粘在一起。
        .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
    }
}

// MARK: - 「有软件更新可用」

/// Sparkle 查到新版本时在身份区下面多出的一行,右侧红色「1」。它是 List 里 tag 为 `.softwareUpdate` 的
/// 可选行(2026-09-12 起;此前是一颗按钮,点了去「关于」弹 Sparkle 的对话框),点了进「软件更新」页,跟系统
/// 设置一样这一行会亮起来。没有新版本时整行不存在,不占位;页面本身仍可从「关于 › 更新 › 软件更新」进。
struct SoftwareUpdateSidebarRow: View {
    @ObservedObject private var languageSettings = AppSettings.shared

    var body: some View {
        HStack(spacing: 8) {
            Text(L10n.t("有软件更新可用"))
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
