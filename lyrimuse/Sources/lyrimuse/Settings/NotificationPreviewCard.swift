import LyrimuseCore
import SwiftUI

/// 渠道编辑弹窗底部「预览」弹出的那块:用一份测试数据(Core `NotificationPreview`)画出报告推到这个平台上大概的样子。
/// 正文跟引擎真推出去的逐字一样,条数跟「每类列出」走;外框是照各平台样子画的示意,颜色写死、不随系统深浅色变。
/// 发件人名字用渠道「名称」,头像用平台图标 —— 群机器人、Telegram Bot 真正的名字和头像是在平台上设的,App 不知道。
struct NotificationPreviewCard: View {
    let platform: NotificationPlatform
    let senderName: String
    /// 通用 Webhook 填了签名密钥:请求头里多一行签名。
    let signed: Bool

    @ObservedObject private var features = FeatureSettingsStore.shared
    @State private var kind: NotificationPreview.Kind = .daily
    private let now = Date()

    var body: some View {
        let title = NotificationPreview.title(kind, now: now)
        let text = NotificationPreview.body(NotificationPreview.sample(kind), topN: features.digestTopN)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L10n.t("预览"))
                    .font(.system(size: 13, weight: .semibold))
                SettingsGlassTabPicker(selection: $kind, options: NotificationPreview.Kind.allCases, label: {
                    $0 == .daily ? L10n.t("每日报告") : L10n.t("每周小结")
                }, compact: true)
                .fixedSize()
                Spacer()
                Text(L10n.t("测试数据"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                stage(title: title, text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
    }

    private var caption: String {
        switch platform {
        case .webhook: return L10n.t("这就是会 POST 出去的内容，真正发出时是一行")
        // 这几种画出来没有发件人名字和头像。
        case .bark, .ntfy, .serverchan: return L10n.t("外框为示意。正文与实际推送逐字一致，数据为测试数据")
        default: return L10n.t("外框为示意，名字和头像以你在平台上的设置为准。正文与实际推送逐字一致，数据为测试数据")
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
        switch platform {
        case .bark, .ntfy: banner(title: title, text: text)
        case .telegram: telegram(title + "\n" + text)
        case .dingtalk, .wecom, .feishu: groupBot(title + "\n" + text)
        case .discord: discord(title: title, text: text)
        case .slack: slack(title: title, text: text)
        case .serverchan: serverChan(title: title, text: text)
        case .webhook: webhook(title: title, text: text)
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

    /// 头像贴顶(Telegram 里是贴底):正文长,贴底的头像会落到预览框下面看不见。
    private func telegram(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            avatar(32)
            VStack(alignment: .leading, spacing: 3) {
                Text(senderName).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0x3B8AD4))
                Text(message).font(.system(size: 12.5)).foregroundStyle(Color.black)
                Text(clock).font(.system(size: 10)).foregroundStyle(Color.black.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white))
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 24)
        }
        .padding(12)
    }

    /// 钉钉、企业微信、飞书的群机器人:名字后面一枚「机器人」。
    private func groupBot(_ message: String) -> some View {
        let (tagFG, tagBG, nameFG): (Color, Color, Color) = switch platform {
        case .dingtalk: (Color(hex: 0x3A7AFE), Color(hex: 0xE9F2FF), Color(hex: 0x858E9B))
        case .wecom: (Color(hex: 0x2E9E57), Color(hex: 0xEAF7EF), Color(hex: 0x8F959E))
        default: (Color(hex: 0x245BDB), Color(hex: 0xE1EAFF), Color(hex: 0x646A73))
        }
        return HStack(alignment: .top, spacing: 9) {
            avatar(32, circle: platform != .wecom)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(senderName).font(.system(size: 11.5)).foregroundStyle(nameFG)
                    tag(L10n.t("机器人"), fg: tagFG, bg: tagBG)
                }
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(hex: 0x1F2329))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 24)
        }
        .padding(12)
    }

    /// Discord:标题前后的 ** 渲染成粗体。
    private func discord(title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            avatar(34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(senderName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: 0xF2F3F5))
                    tag("APP", fg: .white, bg: Color(hex: 0x5865F2))
                    Text(String(format: L10n.t("今天 %@"), clock)).font(.system(size: 10.5)).foregroundStyle(Color(hex: 0x949BA4))
                }
                Group {
                    Text(title).bold()
                    Text(text)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Color(hex: 0xDBDEE1))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    /// Slack:标题前后的 * 渲染成粗体。
    private func slack(title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            avatar(34, circle: false)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(senderName).font(.system(size: 13, weight: .heavy)).foregroundStyle(Color(hex: 0x1D1C1D))
                    tag("APP", fg: Color(hex: 0x616061), bg: Color(hex: 0xE8E8E8))
                    Text(clock).font(.system(size: 10.5)).foregroundStyle(Color(hex: 0x616061))
                }
                Group {
                    Text(title).bold()
                    Text(text)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Color(hex: 0x1D1C1D))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    /// Server酱:微信「方糖」服务号的消息卡,只露正文前几行,点「查看详情」看全文。
    private func serverChan(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("方糖 · 服务通知")).font(.system(size: 11)).foregroundStyle(Color(hex: 0x888888))
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(hex: 0x111111))
            Text(text).font(.system(size: 12)).foregroundStyle(Color(hex: 0x666666)).lineLimit(3)
            Divider().overlay(Color(hex: 0xEEEEEE))
            Text(L10n.t("查看详情 ›")).font(.system(size: 12)).foregroundStyle(Color(hex: 0x576B95))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white))
        .padding(14)
    }

    /// 通用 Webhook:请求头和 JSON 原样给出。
    private func webhook(title: String, text: String) -> some View {
        var head = [L10n.t("POST 到你填的地址"), "Content-Type: application/json", "X-Lyrimuse-Event: \(kind.event)"]
        if signed { head.append("X-Lyrimuse-Signature: sha256=…") }
        return VStack(alignment: .leading, spacing: 10) {
            Text(head.joined(separator: "\n")).foregroundStyle(Color(hex: 0x6A9955))
            Text(NotificationPreview.webhookJSON(event: kind.event, title: title, body: text, sentAt: now))
                .foregroundStyle(Color(hex: 0xD4D4D4))
                .textSelection(.enabled)
        }
        .font(.system(size: 11, design: .monospaced))
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
    }
}

private extension Color {
    /// 0xRRGGBB。
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
