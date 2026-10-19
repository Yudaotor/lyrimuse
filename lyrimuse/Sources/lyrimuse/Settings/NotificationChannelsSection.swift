import LyrimuseCore
import SwiftUI

// 「推送提醒」页(实验室)的渠道列表、渠道编辑表单、推送记录。推送由引擎发(notifychannel.go / alerter.go),
// 这边只管渠道配置(ConfigStore.notificationChannels)、读引擎写的推送记录、经请求文件请引擎「测一下」「重发」。

/// 引擎推送记录(`lyrimuse-notify-log.json`)的观察器。设置窗口看得见时每 5 秒按 mtime 重读一次,定时重读同样挂在
/// `LabsSidebarRow` 上(见 RelayPushStatusWatcher);测一下、重发之后调用方立刻 `refresh()`。
final class NotificationDeliveryWatcher: ObservableObject {
    static let shared = NotificationDeliveryWatcher()

    /// 新的在前。
    @Published private(set) var entries: [NotificationDeliveryLog.Entry] = []

    private let url = LyrimusePaths.configFile(NotificationDeliveryLog.fileName)
    private var cachedMTime: Date?

    private init() {
        refresh()
    }

    var latestByChannel: [String: NotificationDeliveryLog.Entry] { NotificationDeliveryLog.latestByChannel(entries) }

    func refresh() {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard mtime != cachedMTime else { return }
        cachedMTime = mtime
        let next = mtime == nil ? [] : (FileIO.read(url).map(NotificationDeliveryLog.parse) ?? [])
        if next != entries { entries = next }
    }
}

/// 请引擎测一个渠道 / 重发一条推送,等结论。
@MainActor
enum NotificationTestRunner {
    enum Outcome: Equatable {
        case delivered(seconds: Double)
        case failed(NotificationFailure)
        /// 请求写不出去,或引擎一直没接手(后台服务没在跑)。
        case noEngine
    }

    private static let requestURL = LyrimusePaths.configFile(NotificationTest.requestFileName)
    private static let resultURL = LyrimusePaths.configFile(NotificationTest.resultFileName)

    static func test(_ channel: NotificationChannel) async -> Outcome? {
        let id = UUID().uuidString
        return await run(id: id, body: NotificationTest.testBody(id: id, channel: channel))
    }

    static func resend(entryID: String) async -> Outcome? {
        let id = UUID().uuidString
        return await run(id: id, body: NotificationTest.resendBody(id: id, entryID: entryID))
    }

    /// 任务被取消(表单关了)时返回 nil。
    private static func run(id: String, body: Data) async -> Outcome? {
        // 测试请求里带着渠道的密钥:0600 写,引擎一读到就删。
        guard (try? body.writeSecurely(to: requestURL)) != nil else { return .noEngine }
        let deadline = Date().addingTimeInterval(NotificationTest.timeout)
        while Date() < deadline {
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return nil }
            guard let data = FileIO.read(resultURL), let result = NotificationTest.result(id: id, in: data) else { continue }
            NotificationDeliveryWatcher.shared.refresh()
            if let failure = result.failure { return .failed(failure) }
            return .delivered(seconds: Double(result.elapsedMS) / 1000)
        }
        return .noEngine
    }
}

/// 推送没成的原因翻成一句话加一句该怎么改。按平台说:同一个「鉴权不过」,钉钉是安全设置、飞书是签名、Telegram 是 Token。
enum NotificationFailureText {
    /// 报告和测试消息的标题里都有「听歌」二字,钉钉 / 飞书机器人的自定义关键词填它就都能过。
    static let keyword = "听歌"

    static func summary(_ f: NotificationFailure, platform: NotificationPlatform?) -> String {
        let reason: String
        switch (f.kind, platform) {
        case (.network, _): reason = L10n.t("无法连接")
        case (.config, _): reason = L10n.t("渠道信息不完整，或地址无效")
        case (.rateLimited, _): reason = L10n.t("发送过于频繁，已被限流")
        case (.server, _): reason = L10n.t("平台服务出错")
        case (.notFound, .telegram?): reason = L10n.t("找不到该会话（Chat ID 有误，或尚未向机器人发送过消息）")
        case (.notFound, .ntfy?), (.notFound, .webhook?): reason = L10n.t("地址不存在")
        case (.notFound, _): reason = L10n.t("机器人不存在（已被删除，或地址拷贝有误）")
        case (.auth, .dingtalk?): reason = L10n.t("未通过安全设置校验（关键词、加签或 IP 地址）")
        case (.auth, .feishu?):
            switch f.code {
            case "19024": reason = L10n.t("消息里没有自定义关键词")
            case "19022": reason = L10n.t("本机 IP 不在机器人的白名单中")
            default: reason = L10n.t("签名有误")
            }
        case (.auth, .telegram?): reason = L10n.t("机器人 Token 有误，或机器人已被移出会话")
        case (.auth, .ntfy?): reason = L10n.t("该主题需要访问令牌，或令牌有误")
        case (.auth, .serverchan?): reason = L10n.t("SendKey 无效")
        case (.auth, _): reason = L10n.t("密钥或地址有误")
        case (.rejected, _): reason = L10n.t("平台拒收了这条消息")
        }
        var parts = [reason]
        if let code = f.code { parts.append(code) } else if let status = f.status, f.kind != .network { parts.append("HTTP \(status)") }
        let head = parts.count > 1 ? "\(parts[0])（\(parts[1])）" : parts[0]
        guard let name = platform?.displayName, f.kind != .network, f.kind != .config else { return head }
        return String(format: L10n.t("%1$@拒收：%2$@"), name, head)
    }

    /// 该怎么改;说不出具体建议时为 nil(平台原话见 `detail`)。
    static func advice(_ f: NotificationFailure, platform: NotificationPlatform?) -> String? {
        switch (f.kind, platform) {
        case (.network, .telegram?): return L10n.t("请检查网络；在部分网络环境下，Telegram 需开启系统代理才能连接")
        case (.network, _): return L10n.t("请检查网络和地址")
        case (.rateLimited, _): return L10n.t("请稍后重试")
        case (.server, _): return L10n.t("通常为暂时性问题，请稍后重试")
        case (.notFound, .telegram?): return L10n.t("请先向机器人发送一条消息（群组需先将机器人添加到群中），再核对 Chat ID")
        case (.notFound, _): return L10n.t("请在平台上重新拷贝地址")
        case (.auth, .dingtalk?):
            return String(format: L10n.t("若机器人安全设置选择了「自定义关键词」，请添加关键词「%@」；若选择了「加签」，请将密钥填入「加签密钥」"), keyword)
        case (.auth, .feishu?) where f.code == "19024":
            return String(format: L10n.t("请在机器人安全设置中添加关键词「%@」，或改用签名校验"), keyword)
        case (.auth, .feishu?) where f.code == "19022":
            return L10n.t("请在机器人安全设置中关闭 IP 白名单，或改用签名校验")
        case (.auth, .feishu?):
            return L10n.t("请检查「签名密钥」是否与机器人设置一致；若未开启签名校验，请清空此栏")
        case (.auth, .telegram?): return L10n.t("请在 @BotFather 中核对 Token")
        case (.auth, .ntfy?): return L10n.t("请在「访问令牌」中填写以 tk_ 开头的令牌，或「用户名:密码」")
        case (.auth, _), (.config, _), (.rejected, _): return nil
        }
    }
}

/// 渠道行、推送记录里那一行时间:今年的不写年份。
func notificationTimeText(_ date: Date) -> String {
    let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
    return date.formatted(sameYear
        ? .dateTime.month(.twoDigits).day(.twoDigits).hour().minute()
        : .dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
}

/// 推送平台的图标:品牌图(圆角由这里裁),通用 Webhook 是灰底花括号。图预先画成一组位图(`AppIconResolver.prerendered`),
/// 整张 512 直接缩到二三十像素满是锯齿。
struct NotificationPlatformBadge: View {
    let platform: NotificationPlatform
    var size: CGFloat = 20

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor private static func image(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        // 没走 build.sh 打包(直接 swift build 跑)时找不到资源,退回下面的符号。
        guard let path = Bundle.main.path(forResource: name, ofType: "png"), let raw = NSImage(contentsOfFile: path) else { return nil }
        let image = AppIconResolver.prerendered(raw)
        cache[name] = image
        return image
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        if let name = platform.iconResource, let image = Self.image(name) {
            Image(nsImage: image)
                .resizable()
                .frame(width: size, height: size)
                .clipShape(shape)
        } else {
            Image(systemName: platform == .webhook ? "curlybraces" : "bell.fill")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(shape.fill(Color.gray))
        }
    }
}

extension NotificationChannel {
    /// 没起名字的用平台名。
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (NotificationPlatform(rawValue: platform)?.displayName ?? platform) : trimmed
    }
}

// MARK: - 渠道列表

/// 「推送渠道」卡:每个渠道一行(名字、平台、上次推送成没成、启用开关),点一行编辑,右上角添加。
struct NotificationChannelsCard: View {
    @ObservedObject var config: ConfigStore
    @ObservedObject private var log = NotificationDeliveryWatcher.shared
    /// 正在编辑的渠道;新建时是一个还不在列表里的空渠道。
    @State private var editing: NotificationChannel?
    @State private var pendingDelete: NotificationChannel?

    var body: some View {
        SettingsCard(cornerRadius: 18) {
            SettingsCardHeader(
                title: L10n.t("推送渠道"),
                help: L10n.t("报告将推送到所有已启用的渠道。点按一行可编辑或发送测试；右键点按可删除")
            ) {
                Button {
                    editing = NotificationChannel(platform: NotificationPlatform.displayOrder.first?.rawValue ?? "bark")
                } label: {
                    Label(L10n.t("添加渠道"), systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            if config.notificationChannels.isEmpty {
                emptyState
            } else {
                ForEach(Array(config.notificationChannels.enumerated()), id: \.element.id) { index, channel in
                    if index > 0 { CardDivider() }
                    row(channel)
                }
                .padding(.bottom, 4)
            }
        }
        .sheet(item: $editing) { channel in
            NotificationChannelEditor(
                original: channel,
                isNew: !config.notificationChannels.contains { $0.id == channel.id },
                onSave: save,
                onDelete: delete
            )
        }
        .alert(
            String(format: L10n.t("删除「%@」？"), pendingDelete?.displayName ?? ""),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { channel in
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("删除"), role: .destructive) { delete(channel) }
        } message: { _ in
            Text(L10n.t("删除后不再向此渠道推送，推送记录将保留"))
        }
    }

    private func delete(_ channel: NotificationChannel) {
        config.notificationChannels.removeAll { $0.id == channel.id }
        editing = nil
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell.badge")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text(L10n.t("尚无推送渠道"))
                .font(.system(size: 13, weight: .medium))
            Text(L10n.t("添加渠道后，收听报告将推送到手机、群聊或自建服务"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
    }

    private func row(_ channel: NotificationChannel) -> some View {
        let platform = NotificationPlatform(rawValue: channel.platform)
        let status = rowStatus(channel, platform: platform)
        return HStack(spacing: SettingsRowMetrics.iconTextSpacing) {
            NotificationPlatformBadge(platform: platform ?? .bark, size: 22)
                .opacity(channel.enabled ? 1 : 0.45)
                .frame(width: SettingsRowMetrics.iconWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(channel.enabled ? .primary : .secondary)
                    .lineLimit(1)
                Text(status.text)
                    .font(.system(size: 11))
                    .foregroundStyle(status.tint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { channel.enabled },
                set: { on in
                    guard let i = config.notificationChannels.firstIndex(where: { $0.id == channel.id }) else { return }
                    config.notificationChannels[i].enabled = on
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
        .padding(.vertical, 8)
        .settingsHoverRow()
        .contentShape(Rectangle())
        .onTapGesture { editing = channel }
        .contextMenu {
            Button(L10n.t("编辑…")) { editing = channel }
            Button(L10n.t("删除…"), role: .destructive) { pendingDelete = channel }
        }
        .help(status.help ?? "")
    }

    /// 行里第二行字:平台,加上次推送的结果。
    private func rowStatus(_ channel: NotificationChannel, platform: NotificationPlatform?) -> (text: String, tint: Color, help: String?) {
        let platformName = platform?.displayName ?? channel.platform
        let prefix = channel.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : platformName + " · "
        if !channel.enabled { return (prefix + L10n.t("已停用"), .secondary, nil) }
        if !channel.isComplete {
            let missing = channel.platform == "telegram" && !channel.url.isEmpty ? L10n.t("未填写 Chat ID") : L10n.t("未填写地址")
            return (prefix + missing, .orange, nil)
        }
        guard let last = log.latestByChannel[channel.id] else { return (prefix + L10n.t("尚未推送"), .secondary, nil) }
        let when = notificationTimeText(last.date)
        guard let failure = last.failure else {
            return (prefix + String(format: L10n.t("%@ 已送达"), when), .secondary, last.title)
        }
        let reason = NotificationFailureText.summary(failure, platform: platform)
        let advice = NotificationFailureText.advice(failure, platform: platform)
        return (prefix + String(format: L10n.t("%1$@ 失败 · %2$@"), when, reason), .red,
                [reason, advice, failure.detail].compactMap { $0 }.joined(separator: "\n"))
    }

    private func save(_ channel: NotificationChannel) {
        if let i = config.notificationChannels.firstIndex(where: { $0.id == channel.id }) {
            config.notificationChannels[i] = channel
        } else {
            config.notificationChannels.append(channel)
        }
        editing = nil
    }
}

// MARK: - 添加 / 编辑渠道

/// 添加 / 编辑一个渠道的表单。添加时先选平台(平铺,悬停有说明),再填字段;也可以直接粘一整段地址,认出平台就切过去。
/// 编辑已有的渠道只出这个平台自己的字段,不列别的平台:平台定了就不换,要换平台删掉再添加。
/// 「发送测试」用表单里此刻的内容(还没保存也行)推一条示例消息,结果就地显示,表单不关。
struct NotificationChannelEditor: View {
    let original: NotificationChannel
    let isNew: Bool
    let onSave: (NotificationChannel) -> Void
    let onDelete: (NotificationChannel) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: NotificationChannel
    /// 粘贴地址时认出来的平台,表单里提示一句;用户自己改了平台就收起。
    @State private var detected: NotificationPlatform?
    /// 编辑时粘进来的地址像是别的平台的(编辑不换平台,只提醒一句)。
    @State private var mismatch: NotificationPlatform?
    /// 地址里带着凭据(Bark 的 Key、机器人 Token、webhook 的 access_token):编辑已保存的渠道时默认遮住,眼睛按钮切换。
    /// 新建时明文 —— 要看着粘进来的对不对。
    @State private var revealURL: Bool
    @State private var testing = false
    @State private var testOutcome: NotificationTestRunner.Outcome?
    @State private var testTask: Task<Void, Never>?
    @State private var confirmingDelete = false

    init(original: NotificationChannel, isNew: Bool,
         onSave: @escaping (NotificationChannel) -> Void, onDelete: @escaping (NotificationChannel) -> Void) {
        self.original = original
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        _draft = State(initialValue: original)
        _revealURL = State(initialValue: isNew || original.url.isEmpty)
    }

    private var platform: NotificationPlatform { NotificationPlatform(rawValue: draft.platform) ?? .bark }

    private var canSave: Bool { draft.isComplete }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if isNew { platformGrid }
            fields
            testResult
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 480)
        .onDisappear { testTask?.cancel() }
        .confirmationDialog(String(format: L10n.t("删除「%@」？"), original.displayName), isPresented: $confirmingDelete) {
            Button(L10n.t("删除"), role: .destructive) { onDelete(original) }
        } message: {
            Text(L10n.t("删除后不再向此渠道推送，推送记录将保留"))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            NotificationPlatformBadge(platform: platform, size: 30)
                .hoverNote(platform.summary)
            VStack(alignment: .leading, spacing: 1) {
                Text(isNew ? L10n.t("添加推送渠道") : String(format: L10n.t("编辑「%@」"), original.displayName))
                    .font(.system(size: 15, weight: .bold))
                // 编辑时没有平台列表,标题下面写明是哪个平台(名字是用户起的,不一定看得出)。
                if !isNew {
                    Text(platform.displayName)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HelpButton(text: platform.setupGuide, docTitle: platform.setupDocURL == nil ? nil : L10n.t("查看官方文档 →"),
                       docURL: platform.setupDocURL)
        }
    }

    /// 平台不分组、一排铺开(10 个平台平铺两行就看全,分组的轴怎么取都有放哪组都不对的),通用 Webhook 排最后。
    /// 每个是什么靠悬停说明,不在外面另写字。
    private var platformGrid: some View {
        SettingsFlowRow(spacing: 6) {
            ForEach(NotificationPlatform.displayOrder + [.webhook]) { p in platformChip(p) }
        }
    }

    private func platformChip(_ p: NotificationPlatform) -> some View {
        let selected = p == platform
        return Button {
            selectPlatform(p)
        } label: {
            HStack(spacing: 5) {
                NotificationPlatformBadge(platform: p, size: 16)
                Text(p.displayName)
            }
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .padding(.leading, 5)
                .padding(.trailing, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
                .overlay(Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.6) : .clear))
                .foregroundStyle(selected ? Color.accentColor : .primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // 自绘气泡,不用 .help():系统提示要停约 2 秒才弹,设置窗不在前台时还不弹(见 HoverNote 头注)。
        .hoverNote(p.summary)
    }

    private func selectPlatform(_ p: NotificationPlatform) {
        guard p != platform else { return }
        draft.platform = p.rawValue
        detected = nil
        testOutcome = nil
        // 密钥按平台是不同的东西,换平台不带过去。
        if p.secretField == nil { draft.secret = "" }
        if p != .telegram { draft.chatID = "" }
    }

    private var fields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Text(platform.fieldLabel).gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        let url = Binding(get: { draft.url }, set: urlChanged)
                        Group {
                            if revealURL {
                                TextField(platform.fieldLabel, text: url, prompt: Text(platform.urlPlaceholder))
                            } else {
                                SecureField(platform.fieldLabel, text: url, prompt: Text(platform.urlPlaceholder))
                            }
                        }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        if !isNew {
                            Button {
                                revealURL.toggle()
                            } label: {
                                Image(systemName: revealURL ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(revealURL ? L10n.t("隐藏") : L10n.t("显示"))
                        }
                    }
                    if let mismatch {
                        Label(String(format: L10n.t("此地址似乎属于%@。如需更换平台，请删除此渠道后重新添加"), mismatch.displayName),
                              systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    } else if let detected {
                        Label(String(format: L10n.t("已识别为%@的地址并自动切换"), detected.displayName), systemImage: "sparkle.magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else if isNew && draft.url.isEmpty {
                        Text(L10n.t("可直接粘贴完整地址，可识别的平台将自动切换"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if platform == .telegram {
                GridRow {
                    Text(L10n.t("Chat ID"))
                    TextField(L10n.t("Chat ID"), text: $draft.chatID, prompt: Text(L10n.t("Chat ID：个人为一串数字，群组以 -100 开头")))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }
            }
            if let secret = platform.secretField {
                GridRow {
                    Text(secret.label)
                    VStack(alignment: .leading, spacing: 4) {
                        SecureField(secret.label, text: $draft.secret)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                        Text(secret.note)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            GridRow {
                Text(L10n.t("名称"))
                TextField(L10n.t("名称"), text: $draft.name, prompt: Text(platform.displayName))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
        }
        .font(.system(size: 13))
    }

    private func urlChanged(_ value: String) {
        draft.url = value
        testOutcome = nil
        mismatch = nil
        guard let hit = NotificationPlatformDetector.detect(value), let p = NotificationPlatform(rawValue: hit.platform) else { return }
        if p != platform, !isNew {
            mismatch = p
            return
        }
        if p != platform {
            selectPlatform(p)
            detected = p
        }
        if !hit.chatID.isEmpty, draft.chatID.isEmpty { draft.chatID = hit.chatID }
    }

    @ViewBuilder
    private var testResult: some View {
        if testing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.t("正在发送测试消息…"))
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        } else if let outcome = testOutcome {
            switch outcome {
            case .delivered(let seconds):
                Label(String(format: L10n.t("已送达 · %.1f 秒。请在手机或群聊中确认是否收到"), seconds), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            case .failed(let failure):
                VStack(alignment: .leading, spacing: 3) {
                    Label(NotificationFailureText.summary(failure, platform: platform), systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    if let advice = NotificationFailureText.advice(failure, platform: platform) {
                        Text(advice).foregroundStyle(.secondary).padding(.leading, 20)
                    }
                    if let detail = failure.detail {
                        Text(detail).foregroundStyle(.tertiary).padding(.leading, 20).textSelection(.enabled)
                    }
                }
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            case .noEngine:
                Label(L10n.t("歌词引擎未响应，测试消息未发送。请确认歌词引擎正在运行后重试"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(L10n.t("发送测试")) { runTest() }
                .disabled(!draft.isComplete || testing)
            if !isNew {
                Button(L10n.t("删除…"), role: .destructive) { confirmingDelete = true }
            }
            Spacer()
            Button(L10n.t("取消")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L10n.t("保存")) { onSave(cleaned) }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
    }

    private var cleaned: NotificationChannel {
        var c = draft
        c.name = c.name.trimmingCharacters(in: .whitespacesAndNewlines)
        c.url = c.url.trimmingCharacters(in: .whitespacesAndNewlines)
        c.secret = c.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        c.chatID = c.chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        return c
    }

    private func runTest() {
        testing = true
        testOutcome = nil
        let channel = cleaned
        testTask = Task { @MainActor in
            let outcome = await NotificationTestRunner.test(channel)
            guard !Task.isCancelled else { return }
            testing = false
            testOutcome = outcome
        }
    }
}

// MARK: - 推送记录

/// 「推送记录」卡:最近几次推送,没成的写原因、可以重发;点一行展开看推出去的完整内容和渠道、耗时、平台返回。
/// 没有记录时整张卡不出现。
struct NotificationLogCard: View {
    @ObservedObject var config: ConfigStore
    @ObservedObject private var log = NotificationDeliveryWatcher.shared
    @State private var showAll = false
    /// 正在重发的那条记录。
    @State private var resending: String?
    @State private var resendOutcome: (entry: String, outcome: NotificationTestRunner.Outcome)?
    /// 展开着的记录。
    @State private var expanded: Set<String> = []

    private static let collapsedCount = 6

    var body: some View {
        if !log.entries.isEmpty {
            SettingsCard(cornerRadius: 18) {
                SettingsCardHeader(title: L10n.t("推送记录")) {
                    if log.entries.count > Self.collapsedCount {
                        Button(showAll ? L10n.t("收起") : String(format: L10n.t("全部 %d 条"), log.entries.count)) {
                            showAll.toggle()
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
                let shown = showAll ? log.entries : Array(log.entries.prefix(Self.collapsedCount))
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { CardDivider() }
                    row(entry)
                }
                .padding(.bottom, 4)
            }
        }
    }

    private func row(_ entry: NotificationDeliveryLog.Entry) -> some View {
        let platform = NotificationPlatform(rawValue: entry.platform)
        let channel = config.notificationChannels.first { $0.id == entry.channel }
        let channelName = channel?.displayName ?? entry.channelName.flatMap { $0.isEmpty ? nil : $0 } ?? platform?.displayName ?? entry.platform
        let isOpen = expanded.contains(entry.id)
        return VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(notificationTimeText(entry.date))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title ?? "")
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(channelName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let failure = entry.failure {
                    Text(NotificationFailureText.summary(failure, platform: platform))
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .help([NotificationFailureText.advice(failure, platform: platform), failure.detail].compactMap { $0 }.joined(separator: "\n"))
                }
                if let r = resendOutcome, r.entry == entry.id {
                    resendText(r.outcome, platform: platform)
                }
            }
            Spacer(minLength: 8)
            if entry.ok {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12))
            } else if resending == entry.id {
                ProgressView().controlSize(.small)
            } else if entry.body != nil, channel != nil, resendOutcome?.entry != entry.id {
                Button(L10n.t("重发")) { resend(entry) }
                    .controlSize(.small)
                    .disabled(resending != nil)
            } else {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.system(size: 12))
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
        }
        .settingsHoverRow(cornerRadius: 6, inset: -3)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) {
                if isOpen { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
            }
        }
        if isOpen {
            details(entry, platform: platform, channelName: channelName)
                .padding(.leading, 102)
        }
        }
        .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
        .padding(.vertical, 7)
    }

    /// 展开后的完整信息:推出去的正文,渠道、结果、耗时,没推成的再加该怎么改和平台的原话。
    private func details(_ entry: NotificationDeliveryLog.Entry, platform: NotificationPlatform?, channelName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let body = entry.body, !body.isEmpty {
                    Text(body)
                        .textSelection(.enabled)
                } else {
                    // 引擎早先只给没推成的记正文,那时推成功的记录只有标题。
                    Text(L10n.t("该记录未保存推送内容"))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text(L10n.t("渠道")).foregroundStyle(.secondary)
                    Text(platform.map { channelName == $0.displayName ? channelName : "\(channelName)（\($0.displayName)）" } ?? channelName)
                }
                GridRow {
                    Text(L10n.t("结果")).foregroundStyle(.secondary)
                    if let failure = entry.failure {
                        Text(NotificationFailureText.summary(failure, platform: platform)).foregroundStyle(.red)
                    } else {
                        Text(L10n.t("已送达")).foregroundStyle(.green)
                    }
                }
                if let failure = entry.failure, let advice = NotificationFailureText.advice(failure, platform: platform) {
                    GridRow {
                        Text(L10n.t("建议")).foregroundStyle(.secondary)
                        Text(advice)
                    }
                }
                if let detail = entry.failure?.detail {
                    GridRow {
                        Text(L10n.t("平台返回")).foregroundStyle(.secondary)
                        Text(detail).textSelection(.enabled)
                    }
                }
                GridRow {
                    Text(L10n.t("耗时")).foregroundStyle(.secondary)
                    Text(String(format: L10n.t("%.1f 秒"), Double(entry.elapsedMS) / 1000))
                }
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func resendText(_ outcome: NotificationTestRunner.Outcome, platform: NotificationPlatform?) -> some View {
        switch outcome {
        case .delivered:
            Text(L10n.t("已重发")).font(.system(size: 11)).foregroundStyle(.green)
        case .failed(let failure):
            Text(String(format: L10n.t("重发失败：%@"), NotificationFailureText.summary(failure, platform: platform)))
                .font(.system(size: 11)).foregroundStyle(.red)
        case .noEngine:
            Text(L10n.t("歌词引擎未响应，未重发")).font(.system(size: 11)).foregroundStyle(.orange)
        }
    }

    private func resend(_ entry: NotificationDeliveryLog.Entry) {
        resending = entry.id
        Task { @MainActor in
            let outcome = await NotificationTestRunner.resend(entryID: entry.id)
            resending = nil
            if let outcome { resendOutcome = (entry.id, outcome) }
        }
    }
}
