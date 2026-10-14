import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// 「歌词显示 › 网页歌词」那一段总开关下面的卡片:本机打开、局域网开关与控制开关、两条链接、二维码、启动失败的说明。见 19 章。
struct WebLyricsSettingsCard: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var server = WebLyricsServer.shared
    @State private var lanURL: URL?

    var body: some View {
        SettingsCard {
            SettingsRow(icon: "macwindow", title: L10n.t("副屏画面"), subtitle: WebLyricsServer.screenURL.absoluteString) {
                openInBrowserButton
            }
            CardDivider()
            SettingsRow(icon: "wifi", title: L10n.t("允许局域网设备访问"),
                        subtitle: L10n.t("同一 Wi-Fi 下的手机、平板扫描二维码即可打开，链接带有随机密钥")) {
                Toggle("", isOn: $settings.webLyricsAllowLAN)
            }
            CardDivider()
            SettingsRow(icon: "video", title: L10n.t("OBS 浏览器源"), subtitle: WebLyricsServer.obsURL.absoluteString) {
                CopyLinkButton(url: WebLyricsServer.obsURL)
            }
            if settings.webLyricsAllowLAN {
                CardDivider()
                SettingsRow(icon: "playpause", title: L10n.t("允许局域网设备控制播放"),
                            subtitle: L10n.t("在手机、平板上点按钮暂停、切歌，点歌词跳到那一句")) {
                    Toggle("", isOn: $settings.webLyricsAllowLANControl)
                }
                CardDivider()
                SettingsRow(icon: "ipad.and.iphone", title: L10n.t("手机、平板"),
                            subtitle: lanURL?.absoluteString ?? L10n.t("未连接局域网")) {
                    if let lanURL { CopyLinkButton(url: lanURL) }
                }
                if let lanURL, let qr = WebLyricsQRCode.image(for: lanURL.absoluteString) {
                    VStack(spacing: 6) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 120, height: 120)
                            .padding(8)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Text(L10n.t("用手机相机扫描二维码"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)
                }
            }
            if let problem {
                CardDivider()
                SettingsRow(icon: "exclamationmark.triangle.fill", iconTint: .orange, title: problem) { EmptyView() }
            }
        }
        .onAppear { refreshLanURL() }
        .onChange(of: settings.webLyricsAllowLAN) { _, _ in refreshLanURL() }
        .onChange(of: server.state) { _, _ in refreshLanURL() }
    }

    /// 服务没在跑(总开关关着、端口被占)时打开只会是连不上的页面,按钮置灰。
    private var openInBrowserButton: some View {
        Button {
            NSWorkspace.shared.open(WebLyricsServer.screenURL)
        } label: {
            HStack(spacing: 4) {
                Text(L10n.t("在浏览器中打开"))
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium))
        }
        .controlSize(.small)
        .settingsGlassButtons()
        .buttonBorderShape(.capsule)
        .disabled(!isRunning)
    }

    private var isRunning: Bool {
        if case .running = server.state { return true }
        return false
    }

    private var problem: String? {
        guard settings.webLyricsEnabled else { return nil }
        switch server.state {
        case .portInUse:
            return String(format: L10n.t("端口 %lld 已被占用，网页歌词未能启动"), Int(WebLyricsServer.port))
        case .failed(let reason):
            return String(format: L10n.t("网页歌词未能启动：%@"), reason)
        case .off, .running:
            return nil
        }
    }

    private func refreshLanURL() {
        lanURL = WebLyricsServer.lanURL(token: settings.webLyricsToken)
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
