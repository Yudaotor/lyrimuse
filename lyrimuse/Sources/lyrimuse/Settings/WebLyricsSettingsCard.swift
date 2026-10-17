import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import LyrimuseCore
import SwiftUI

/// 「歌词显示 › 歌词窗口」的「网页歌词」那一组:编辑台工具栏「网页歌词」浮层和「全部设置」抽屉的「网页歌词」组都调它
/// (同另外几组,一份视图两个宿主;排法同悬浮歌词的 `OverlayObsSettingsRows`)。样式就是歌词窗口完整尺寸那一套。见 19 章。
struct LyricsWindowWebSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var server = WebLyricsServer.screen
    @State private var links = WebLyricsLANLinks()

    var body: some View {
        SettingsRowGroupStack {
            SettingsRowGroup {
                SettingsRow(icon: "globe", title: L10n.t("网页歌词"),
                            subtitle: L10n.t("在浏览器中显示歌词窗口")) {
                    Toggle("", isOn: $settings.webLyricsEnabled)
                }
                CardDivider()
                SettingsRow(icon: "safari", title: L10n.t("本机地址"), subtitle: server.localURL.absoluteString) {
                    WebLyricsOpenButton(title: L10n.t("在浏览器中打开"), url: server.localURL, enabled: server.isRunning)
                }
                WebLyricsProblemRow(server: server)
            }
            SettingsRowGroup(title: L10n.t("局域网")) {
                SettingsRow(icon: "wifi", title: L10n.t("允许局域网访问"),
                            subtitle: L10n.t("同一网络中的设备可通过带密钥的链接访问")) {
                    Toggle("", isOn: $settings.webLyricsAllowLAN)
                }
                if settings.webLyricsAllowLAN {
                    CardDivider()
                    SettingsRow(icon: "playpause", title: L10n.t("允许远程控制"),
                                subtitle: L10n.t("可在其他设备上控制播放、跳转歌词")) {
                        Toggle("", isOn: $settings.webLyricsAllowLANControl)
                    }
                    WebLyricsLANLinkRows(links: links, remoteViewers: server.remoteViewerCount, qrCaption: L10n.t("使用相机扫描二维码"))
                    CardDivider()
                    WebLyricsRegenerateRow { settings.regenerateWebLyricsToken() }
                }
            }
            SettingsRowGroup(title: L10n.t("高级")) {
                WebLyricsPortRow(value: $settings.webLyricsPort, otherPort: settings.obsLyricsPort,
                                 duplicateMessage: L10n.t("该端口已被 OBS 输出使用"), note: L10n.t("更改后需重新扫码连接"))
            }
        }
        .onAppear { links.refresh(server) }
        .onChange(of: settings.webLyricsAllowLAN) { _, _ in links.refresh(server) }
        .onChange(of: settings.webLyricsToken) { _, _ in links.refresh(server) }
        .onChange(of: settings.webLyricsPort) { _, _ in links.refresh(server) }
        .onChange(of: server.state) { _, _ in links.refresh(server) }
    }
}

/// 「歌词显示 › 悬浮歌词」的「OBS」那一组:编辑台工具栏「OBS」浮层和「全部设置」抽屉的「OBS」组都调它
/// (同另外几组,一份视图两个宿主)。样式就是悬浮歌词那一套。见 19 章。
struct OverlayObsSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var server = WebLyricsServer.obs
    @State private var links = WebLyricsLANLinks()

    var body: some View {
        SettingsRowGroupStack {
            SettingsRowGroup {
                SettingsRow(icon: "video", title: L10n.t("OBS 输出"),
                            subtitle: L10n.t("作为浏览器源叠加到直播画面，宽高设为 OBS 画布尺寸")) {
                    Toggle("", isOn: $settings.obsLyricsEnabled)
                }
                CardDivider()
                SettingsRow(icon: "link", title: L10n.t("浏览器源地址"), subtitle: server.localURL.absoluteString) {
                    HStack(spacing: 8) {
                        WebLyricsOpenButton(title: L10n.t("预览"), url: server.previewURL, enabled: server.isRunning)
                        CopyLinkButton(url: server.localURL)
                    }
                }
                WebLyricsProblemRow(server: server)
            }
            SettingsRowGroup(title: L10n.t("局域网")) {
                SettingsRow(icon: "wifi", title: L10n.t("允许局域网访问"),
                            subtitle: L10n.t("同一网络中的设备可通过带密钥的链接访问")) {
                    Toggle("", isOn: $settings.obsLyricsAllowLAN)
                }
                if settings.obsLyricsAllowLAN {
                    WebLyricsLANLinkRows(links: links, remoteViewers: server.remoteViewerCount, qrCaption: nil)
                    CardDivider()
                    WebLyricsRegenerateRow { settings.regenerateObsLyricsToken() }
                }
            }
            SettingsRowGroup(title: L10n.t("高级")) {
                WebLyricsPortRow(value: $settings.obsLyricsPort, otherPort: settings.webLyricsPort,
                                 duplicateMessage: L10n.t("该端口已被网页歌词使用"), note: L10n.t("更改后需同步修改 OBS 中的地址"))
            }
        }
        .onAppear { links.refresh(server) }
        .onChange(of: settings.obsLyricsAllowLAN) { _, _ in links.refresh(server) }
        .onChange(of: settings.obsLyricsToken) { _, _ in links.refresh(server) }
        .onChange(of: settings.obsLyricsPort) { _, _ in links.refresh(server) }
        .onChange(of: server.state) { _, _ in links.refresh(server) }
    }
}

// MARK: - 网页歌词和 OBS 两组共用的零件(各自的设置分开存,只是长得一样)

extension WebLyricsServer {
    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }
}

/// 局域网链接那几行显示的地址(状态判断在 Core `WebLyricsLANStatus`)。
enum WebLyricsLANSummary {
    @MainActor
    static func text(enabled: Bool, allowLAN: Bool, host: URL?, remoteViewers: Int) -> String {
        switch WebLyricsLANStatus.make(enabled: enabled, allowLAN: allowLAN, link: host, remoteViewers: remoteViewers) {
        case .off: return L10n.t("未开启")
        case .lanOff: return L10n.t("局域网访问已关闭")
        case .noNetwork: return L10n.t("未连接局域网")
        case let .reachable(address, 0): return address
        case let .reachable(address, count): return String(format: L10n.t("%@ · 已连接 %lld 台设备"), address, count)
        }
    }

    /// 链接行显示的地址:名字(或 IP)加端口,不带密钥;拷贝按钮拷的才是带密钥的完整链接。
    @MainActor
    static func address(_ link: URL, remoteViewers: Int = 0) -> String {
        text(enabled: true, allowLAN: true, host: link, remoteViewers: remoteViewers)
    }
}

/// 局域网的两条链接:`.local`(二维码用它,换了 IP 也有效)和 IP。没有局域网 IP 时都不给(`.local` 名字断网时也拿得到,
/// 但那时谁也连不上);拿不到 `.local` 名字时 `host` 退回 IP、不另给 IP 那一条。
struct WebLyricsLANLinks {
    var host: URL?
    var ip: URL?

    @MainActor
    mutating func refresh(_ server: WebLyricsServer) {
        guard let ipURL = server.lanIPURL else {
            host = nil
            ip = nil
            return
        }
        if let hostURL = server.lanHostURL {
            host = hostURL
            ip = ipURL
        } else {
            host = ipURL
            ip = nil
        }
    }
}

/// 局域网链接那几行:访问链接(可带二维码)和备用链接(IP 地址)。行上只显示地址不带密钥(OBS 那一组在「全部设置」里
/// 常驻显示,直播、录屏时会拍进画面),访问链接那一行后面带上别的设备连进来几个页面。
private struct WebLyricsLANLinkRows: View {
    let links: WebLyricsLANLinks
    let remoteViewers: Int
    let qrCaption: String?

    var body: some View {
        CardDivider()
        SettingsRow(icon: "link", title: L10n.t("访问链接"),
                    subtitle: links.host.map { WebLyricsLANSummary.address($0, remoteViewers: remoteViewers) }
                        ?? L10n.t("未连接局域网")) {
            if let host = links.host { CopyLinkButton(url: host) }
        }
        if let qrCaption, let host = links.host, let qr = WebLyricsQRCode.image(for: host.absoluteString) {
            VStack(spacing: 6) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 120, height: 120)
                    .padding(8)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(qrCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 12)
        }
        if let ip = links.ip {
            CardDivider()
            SettingsRow(icon: "network", title: L10n.t("备用链接（IP 地址）"), subtitle: WebLyricsLANSummary.address(ip)) {
                CopyLinkButton(url: ip)
            }
        }
    }
}

/// 「重置访问密钥」:点一次变成「确认重置」,4 秒内再点才换密钥(放在浮层里,不弹确认框)。
private struct WebLyricsRegenerateRow: View {
    let regenerate: () -> Void
    @State private var armed = false

    var body: some View {
        SettingsRow(icon: "arrow.triangle.2.circlepath", title: L10n.t("重置访问密钥"), subtitle: L10n.t("已分享的链接将失效")) {
            Button(armed ? L10n.t("确认重置") : L10n.t("重置")) {
                if armed {
                    armed = false
                    regenerate()
                } else {
                    armed = true
                    Task {
                        try? await Task.sleep(for: .seconds(4))
                        armed = false
                    }
                }
            }
            .controlSize(.small)
            .settingsGlassButtons()
            .buttonBorderShape(.capsule)
            .tint(armed ? .red : nil)
        }
    }
}

/// 端口输入:回车或离开输入框时提交,不在范围里、跟另一个服务的端口相同都不改、提示一行。
private struct WebLyricsPortRow: View {
    @Binding var value: Int
    let otherPort: Int
    let duplicateMessage: String
    let note: String
    @State private var text = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        SettingsRow(icon: "number", title: L10n.t("端口"), subtitle: problem ?? note) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 56)
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .settingsSearchFieldBackground(cornerRadius: 6)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .onChange(of: text) { _, _ in problem = nil }
                .accessibilityLabel(L10n.t("端口"))
        }
        .onAppear {
            text = String(value)
            // 浮层弹出时系统会把焦点给第一个输入框;端口框不该一打开就接键盘输入。
            DispatchQueue.main.async { focused = false }
        }
        .onChange(of: value) { _, newValue in text = String(newValue) }
    }

    private func commit() {
        guard let port = WebLyricsPort.parse(text) else {
            problem = String(format: L10n.t("端口须介于 %lld 至 %lld 之间"),
                             WebLyricsPort.range.lowerBound, WebLyricsPort.range.upperBound)
            return
        }
        guard port != otherPort else {
            problem = duplicateMessage
            return
        }
        problem = nil
        if port != value { value = port }
    }
}

/// 启动失败的说明(端口被占用、跟另一个撞了、别的错误),开关关着时不显示。
private struct WebLyricsProblemRow: View {
    @ObservedObject var server: WebLyricsServer

    var body: some View {
        if let text = problem {
            CardDivider()
            SettingsRow(icon: "exclamationmark.triangle.fill", iconTint: .orange, title: text) { EmptyView() }
        }
    }

    private var problem: String? {
        switch server.state {
        case .portInUse:
            return String(format: L10n.t("端口 %lld 已被占用，服务未能启动"), server.port)
        case .failed(let reason):
            return String(format: L10n.t("服务未能启动：%@"), reason)
        case .off, .running:
            return nil
        }
    }
}

/// 「在浏览器中打开」「预览」:服务没在跑时打开只会是连不上的页面,按钮置灰。
private struct WebLyricsOpenButton: View {
    let title: String
    let url: URL
    let enabled: Bool

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium))
        }
        .controlSize(.small)
        .settingsGlassButtons()
        .buttonBorderShape(.capsule)
        .disabled(!enabled)
    }
}

/// 链接的二维码(纠错 M 档,按整数倍放大成位图,显示时不插值)。
@MainActor
enum WebLyricsQRCode {
    private static var cache: (text: String, image: NSImage)?

    static func image(for text: String) -> NSImage? {
        if let cache, cache.text == text { return cache.image }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache = (text, image)
        return image
    }
}
