import LyrimuseCore
import SwiftUI

/// 推送渠道「预览」弹出的那块(渠道列表每一行、编辑弹窗底部各有一个入口):画出报告推到这个平台上大概的样子。
/// 内容用这一期的真实数据 —— 请引擎按真推送同一套取数算一份(`NotificationPreviewLoader`,引擎 digestpreview.go),
/// 日报是今天到现在(今天还没听就是昨天)、周报是最近一个整周;取的那十几秒、或者取不到(没连账号、没听、网络)时画测试数据
/// (Core `NotificationPreview.sample`),底部写明。正文跟引擎真推出去的逐字一样,条数跟「每类列出」走;外框是照各平台样子画的
/// 示意,颜色写死、不随系统深浅色变。
/// 发件人名字用渠道「名称」,头像用平台图标 —— 群机器人、Telegram Bot 真正的名字和头像是在平台上设的,App 不知道。
/// 照引擎 notifyrich.go 各平台的排法画(推送一律按平台排版):加粗、分栏、卡片;封面用真实数据里的专辑封面
/// (测试数据、没取到封面时画占位方块),飞书不画(群机器人带不了图)。见 15 章决策 75。
struct NotificationPreviewCard: View {
    let platform: NotificationPlatform
    let senderName: String
    /// 通用 Webhook 填了签名密钥:请求头里多一行签名。
    let signed: Bool

    @ObservedObject private var features = FeatureSettingsStore.shared
    @State private var kind: NotificationPreview.Kind = .daily
    @State private var loaded: [NotificationPreview.Kind: NotificationPreviewLoader.State] = [:]
    @State private var loading: Set<NotificationPreview.Kind> = []
    private let now = Date()

    /// 这一档取到的真实报告;还没取到 / 取不到时为 nil,画测试数据。
    private var real: (title: String, stats: NotificationPreview.Stats)? {
        if case .real(let title, let stats)? = loaded[kind] { return (title, stats) }
        return nil
    }

    fileprivate var stats: NotificationPreview.Stats { real?.stats ?? NotificationPreview.sample(kind) }

    var body: some View {
        let title = real?.title ?? NotificationPreview.title(kind, now: now)
        let text = NotificationPreview.body(stats, topN: features.digestTopN)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L10n.t("预览"))
                    .font(.system(size: 13, weight: .semibold))
                SettingsGlassTabPicker(selection: $kind, options: NotificationPreview.Kind.allCases, label: {
                    $0 == .daily ? L10n.t("每日报告") : L10n.t("每周小结")
                }, compact: true)
                .fixedSize()
                Spacer()
                dataBadge
            }
            ScrollView {
                stage(title: title, text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(real == nil && loading.contains(kind) ? 0.45 : 1)
            }
            .frame(height: 300)
            .background(backdrop)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 420)
        .task(id: kind) { await load(kind) }
    }

    private func load(_ kind: NotificationPreview.Kind) async {
        if let hit = NotificationPreviewLoader.cached(kind) {
            loaded[kind] = hit
            return
        }
        loading.insert(kind)
        let state = await NotificationPreviewLoader.load(kind)
        loading.remove(kind)
        if let state { loaded[kind] = state }
    }

    /// 右上角:真实数据(数据源)、正在取、测试数据。
    @ViewBuilder
    private var dataBadge: some View {
        if let real {
            Text(String(format: L10n.t("真实数据 · %@"), real.stats.sourceName))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if loading.contains(kind) {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(L10n.t("正在取真实数据…"))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        } else {
            Text(L10n.t("测试数据"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var caption: String {
        let frame: String
        switch platform {
        case .webhook: frame = L10n.t("这就是实际 POST 的内容，发送时是一行。")
        // 这几种画出来没有发件人名字和头像。
        case .bark, .ntfy, .serverchan: frame = L10n.t("外框为示意。")
        default: frame = L10n.t("外框为示意，名字和头像以你在平台上的设置为准。")
        }
        if real != nil { return frame + L10n.t("内容来自这一期的真实数据，跟实际推送一致") }
        if loading.contains(kind) { return frame + L10n.t("正在取这一期的真实数据，先显示测试数据") }
        switch loaded[kind] {
        case .unavailable(.noAccount)?: return frame + L10n.t("还没有连接 Last.fm 或 ListenBrainz，先用测试数据示意")
        case .unavailable(.empty)?: return frame + L10n.t("这一期还没有收听记录，先用测试数据示意")
        default: return frame + L10n.t("没能取到真实数据（网络或后台服务未响应），先用测试数据示意")
        }
    }

    private var clock: String { now.formatted(date: .omitted, time: .shortened) }

    // MARK: 各平台外观

    private var backdrop: some View {
        Group {
            switch platform {
            case .bark, .ntfy:
                LinearGradient(colors: [Color(hex: 0x6C8FB8), Color(hex: 0x3B4F74)], startPoint: .topLeading, endPoint: .bottomTrailing)
            case .telegram: Color(hex: 0x9BBAD1)
            case .dingtalk: Color(hex: 0xF2F3F5)
            case .wecom: Color(hex: 0xF3F5F8)
            case .feishu: Color(hex: 0xF5F6F7)
            case .discord: Color(hex: 0x313338)
            case .slack: Color.white
            case .serverchan: Color(hex: 0xEDEDED)
            case .webhook: Color(hex: 0x1E1E1E)
            }
        }
    }

    @ViewBuilder
    private func stage(title: String, text: String) -> some View {
        if platform == .webhook {
            webhook(title: title, text: text)
        } else {
            richStage(title: title, text: text)
        }
    }

    private func avatar(_ size: CGFloat, circle: Bool = true) -> some View {
        NotificationPlatformBadge(platform: platform, size: size)
            .clipShape(RoundedRectangle(cornerRadius: circle ? size / 2 : size * 0.18, style: .continuous))
    }

    private func tag(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(bg))
    }

    /// Bark、ntfy:手机通知横幅,锁屏上只看得到前几行。
    private func banner(title: String, text: String) -> some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    NotificationPlatformBadge(platform: platform, size: 18)
                    Text(platform.displayName.uppercased())
                    Spacer()
                    Text(L10n.t("现在"))
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.black.opacity(0.55))
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12.5)).lineLimit(4)
            }
            .foregroundStyle(Color(hex: 0x111111))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: 0xF5F5F7).opacity(0.9)))
            Text(L10n.t("锁屏上约显示前 4 行，点开可看全文"))
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.85))
        }
        .padding(14)
    }

    /// 通用 Webhook:请求头和 JSON 原样给出。
    private func webhook(title: String, text: String) -> some View {
        var head = [L10n.t("POST 到你填的地址"), "Content-Type: application/json", "X-Lyrimuse-Event: \(kind.event)"]
        if signed { head.append("X-Lyrimuse-Signature: sha256=…") }
        return VStack(alignment: .leading, spacing: 10) {
            Text(head.joined(separator: "\n")).foregroundStyle(Color(hex: 0x6A9955))
            Text(NotificationPreview.webhookJSON(event: kind.event, title: title, body: text, sentAt: now, data: stats,
                                                 period: webhookPeriod))
                .foregroundStyle(Color(hex: 0xD4D4D4))
                .textSelection(.enabled)
        }
        .font(.system(size: 11, design: .monospaced))
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
    }
}

// MARK: 真实数据

/// 请引擎算这一期的真实报告(请求走「测一下」那条通道,结果见 `NotificationTest.previewResult`)。同一档十分钟内不重取:
/// 来回切平台、关了再开预览都直接用上次的。
@MainActor
enum NotificationPreviewLoader {
    enum State: Equatable {
        case real(title: String, stats: NotificationPreview.Stats)
        /// 取不到;原因为 nil 表示引擎没响应。
        case unavailable(NotificationTest.PreviewResult.Reason?)
    }

    private static let ttl: TimeInterval = 600
    private static var cache: [NotificationPreview.Kind: (at: Date, state: State)] = [:]
    private static let requestURL = LyrimusePaths.configFile(NotificationTest.requestFileName)
    private static let resultURL = LyrimusePaths.configFile(NotificationTest.previewResultFileName)

    static func cached(_ kind: NotificationPreview.Kind) -> State? {
        guard let hit = cache[kind], Date().timeIntervalSince(hit.at) < ttl, case .real = hit.state else { return nil }
        return hit.state
    }

    /// 任务被取消(预览关了、切了档)时返回 nil。
    static func load(_ kind: NotificationPreview.Kind) async -> State? {
        let id = UUID().uuidString
        guard (try? NotificationTest.previewBody(id: id, kind: kind).writeSecurely(to: requestURL)) != nil else { return .unavailable(nil) }
        let deadline = Date().addingTimeInterval(NotificationTest.previewTimeout)
        while Date() < deadline {
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return nil }
            guard let data = FileIO.read(resultURL), let result = NotificationTest.previewResult(id: id, in: data) else { continue }
            let state: State = result.stats.map { .real(title: result.title, stats: $0) } ?? .unavailable(result.reason)
            cache[kind] = (Date(), state)
            return state
        }
        return .unavailable(nil)
    }
}

// MARK: 按平台排版(notifyrich.go)

extension NotificationPreviewCard {
    fileprivate var webhookPeriod: NotificationPreview.WebhookPeriod {
        let p = NotificationPreview.period(kind, now: now)
        return NotificationPreview.WebhookPeriod(from: p.from, to: p.to, topN: features.digestTopN)
    }

    fileprivate var summary: String { NotificationPreview.summaryLine(stats) }
    fileprivate var sections: [NotificationPreview.RichSection] { NotificationPreview.richSections(stats, topN: features.digestTopN) }
    fileprivate var newLine: String { NotificationPreview.newArtistsLine(stats) }
    fileprivate var linkLabel: String { String(format: L10n.t("在 %@ 上看完整榜单"), stats.sourceName) }
    fileprivate var footerText: String { "Lyrimuse · " + String(format: L10n.t("数据来自 %@"), stats.sourceName) }

    @ViewBuilder
    fileprivate func richStage(title: String, text: String) -> some View {
        switch platform {
        case .bark, .ntfy: richBanner(title: title, text: text)
        case .telegram: richTelegram(title: title)
        case .discord: richDiscord(title: title)
        case .slack: richSlack(title: title)
        case .feishu: richFeishu(title: title)
        case .dingtalk, .wecom: richGroupBot(title: title)
        case .serverchan: richServerChan(title: title)
        case .webhook: EmptyView()
        }
    }

    /// 封面:真实数据里有头号专辑的封面就加载它;测试数据、没取到封面、还没加载出来时画一块渐变加音符。
    fileprivate func cover(_ size: CGFloat?, height: CGFloat? = nil, corner: CGFloat = 6) -> some View {
        let placeholder = RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: 0xE5484D), Color(hex: 0x8E44AD)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Image(systemName: "music.note").font(.system(size: (size ?? height ?? 60) * 0.32, weight: .semibold)).foregroundStyle(.white.opacity(0.9)))
        return AsyncImage(url: URL(string: stats.coverURL)) { phase in
            if let image = phase.image {
                // 专辑封面是方图:整张显示,不裁(推出去的也是整张)。
                image.resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            } else {
                placeholder
            }
        }
        .frame(width: size, height: height ?? size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    /// 第一行、每类、新听的歌手、链接,按一种字色、链接色排成一列。headingPrefix:小节标题前缀(Telegram「Top 」)。
    fileprivate func digestColumn(fg: Color, link: Color, boldSummary: Bool, headingPrefix: String = "Top ", showLink: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary).fontWeight(boldSummary ? .semibold : .regular)
            ForEach(sections, id: \.heading) { sec in
                VStack(alignment: .leading, spacing: 1) {
                    Text(headingPrefix + sec.heading).fontWeight(.bold)
                    ForEach(sec.lines, id: \.self) { Text($0) }
                }
            }
            if !newLine.isEmpty { Text("🆕 " + newLine) }
            if showLink { Text(linkLabel).foregroundStyle(link) }
        }
        .foregroundStyle(fg)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Bark、ntfy:正文还是纯文本,锁屏横幅跟以前一样;长按展开多一张封面大图,点一下去完整榜单。
    fileprivate func richBanner(title: String, text: String) -> some View {
        VStack(spacing: 10) {
            banner(title: title, text: text)
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("长按展开")).font(.system(size: 11)).foregroundStyle(Color.black.opacity(0.55))
                cover(nil, height: 120, corner: 10).frame(maxWidth: .infinity)
                Text(L10n.t("点一下打开完整榜单")).font(.system(size: 11)).foregroundStyle(Color.black.opacity(0.55))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: 0xF5F5F7).opacity(0.9)))
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }

    /// Telegram:封面在链接预览里、显示在文字上方;标题、小节名加粗,链接蓝色。
    fileprivate func richTelegram(title: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            avatar(32)
            VStack(alignment: .leading, spacing: 6) {
                cover(nil, height: 150, corner: 8)
                Text(senderName).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0x3B8AD4))
                Text(title).font(.system(size: 12.5, weight: .bold)).foregroundStyle(Color.black)
                digestColumn(fg: .black, link: Color(hex: 0x2A8BD8), boldSummary: false).font(.system(size: 12.5))
                Text(clock).font(.system(size: 10)).foregroundStyle(Color.black.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white))
            Spacer(minLength: 24)
        }
        .padding(12)
    }

    /// Discord:一张卡片,左边红色竖线,标题可点,右上角封面,歌手 / 专辑 / 歌曲三栏。
    fileprivate func richDiscord(title: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            avatar(34)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(senderName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: 0xF2F3F5))
                    tag("APP", fg: .white, bg: Color(hex: 0x5865F2))
                    Text(String(format: L10n.t("今天 %@"), clock)).font(.system(size: 10.5)).foregroundStyle(Color(hex: 0x949BA4))
                }
                HStack(alignment: .top, spacing: 0) {
                    Rectangle().fill(Color(hex: 0xE5484D)).frame(width: 4)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(title).font(.system(size: 12.5, weight: .bold)).foregroundStyle(Color(hex: 0x00A8FC))
                                Text(summary).font(.system(size: 12)).foregroundStyle(Color(hex: 0xDBDEE1))
                            }
                            Spacer(minLength: 6)
                            cover(48)
                        }
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(sections, id: \.heading) { sec in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(sec.heading).font(.system(size: 11, weight: .bold)).foregroundStyle(Color(hex: 0xF2F3F5))
                                    ForEach(sec.lines, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(Color(hex: 0xDBDEE1)) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if !newLine.isEmpty { Text("🆕 " + newLine).font(.system(size: 11.5)).foregroundStyle(Color(hex: 0xDBDEE1)) }
                        Text(footerText).font(.system(size: 10)).foregroundStyle(Color(hex: 0x949BA4))
                    }
                    .padding(9)
                }
                .background(Color(hex: 0x2B2D31))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    /// Slack:大标题,第一段右边带封面,每类一段,底部一行来源和链接。
    fileprivate func richSlack(title: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            avatar(34, circle: false)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(senderName).font(.system(size: 13, weight: .heavy)).foregroundStyle(Color(hex: 0x1D1C1D))
                    tag("APP", fg: Color(hex: 0x616061), bg: Color(hex: 0xE8E8E8))
                    Text(clock).font(.system(size: 10.5)).foregroundStyle(Color(hex: 0x616061))
                }
                Text(title).font(.system(size: 15, weight: .heavy)).foregroundStyle(Color(hex: 0x1D1C1D))
                HStack(alignment: .top) {
                    digestColumn(fg: Color(hex: 0x1D1C1D), link: Color(hex: 0x1264A3), boldSummary: false, showLink: false)
                        .font(.system(size: 12.5))
                    Spacer(minLength: 6)
                    cover(56, corner: 4)
                }
                (Text(footerText + " · ") + Text(linkLabel).foregroundColor(Color(hex: 0x1264A3)))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(hex: 0x616061))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    /// 飞书:消息卡片,蓝色标题栏、三栏榜单、按钮、来源。不带封面。
    fileprivate func richFeishu(title: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            avatar(32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(senderName).font(.system(size: 11.5)).foregroundStyle(Color(hex: 0x646A73))
                    tag(L10n.t("机器人"), fg: Color(hex: 0x245BDB), bg: Color(hex: 0xE1EAFF))
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11).padding(.vertical, 8)
                        .background(Color(hex: 0x3370FF))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(summary).font(.system(size: 12.5))
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(sections, id: \.heading) { sec in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(sec.heading).font(.system(size: 11.5, weight: .bold))
                                    ForEach(sec.lines, id: \.self) { Text($0).font(.system(size: 11)) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if !newLine.isEmpty { Text("🆕 " + newLine).font(.system(size: 12)) }
                        Text(linkLabel).font(.system(size: 11.5)).foregroundStyle(Color(hex: 0x3370FF))
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: 0x3370FF)))
                        Text(footerText).font(.system(size: 10.5)).foregroundStyle(Color(hex: 0x8F959E))
                    }
                    .foregroundStyle(Color(hex: 0x1F2329))
                    .padding(11)
                }
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
        }
        .padding(12)
    }

    /// 钉钉、企业微信:markdown 消息,气泡里大标题、封面、加粗第一行、小节、链接。
    fileprivate func richGroupBot(title: String) -> some View {
        let (tagFG, tagBG, nameFG): (Color, Color, Color) = platform == .dingtalk
            ? (Color(hex: 0x3A7AFE), Color(hex: 0xE9F2FF), Color(hex: 0x858E9B))
            : (Color(hex: 0x2E9E57), Color(hex: 0xEAF7EF), Color(hex: 0x8F959E))
        return HStack(alignment: .top, spacing: 9) {
            avatar(32, circle: platform != .wecom)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(senderName).font(.system(size: 11.5)).foregroundStyle(nameFG)
                    tag(L10n.t("机器人"), fg: tagFG, bg: tagBG)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.system(size: 14, weight: .bold))
                    cover(nil, height: 110)
                    digestColumn(fg: Color(hex: 0x1F2329), link: Color(hex: 0x3A7AFE), boldSummary: true).font(.system(size: 12.5))
                    if platform == .dingtalk {
                        Text(footerText).font(.system(size: 10.5)).foregroundStyle(Color(hex: 0x8F959E))
                    }
                }
                .foregroundStyle(Color(hex: 0x1F2329))
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white))
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 24)
        }
        .padding(12)
    }

    /// Server酱:微信里收到的提醒跟以前一样只有几行;点进方糖看到的是这一页 markdown 详情。
    fileprivate func richServerChan(title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("方糖 · 消息详情")).font(.system(size: 11)).foregroundStyle(Color(hex: 0x888888))
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(hex: 0x111111))
            cover(nil, height: 110)
            digestColumn(fg: Color(hex: 0x333333), link: Color(hex: 0x576B95), boldSummary: true).font(.system(size: 12.5))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white))
        .padding(14)
    }
}


private extension Color {
    /// 0xRRGGBB。
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
