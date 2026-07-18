import SwiftUI

// 首次启动的完整引导向导——之前只有"自动化权限"这一步单独的 NSAlert(见
// AppSettings.hasCompletedOnboarding 迁移注释),用户反馈参照 Jukebox/PlayStatus/
// Tuneful 这类"选数据源模式、语言等一步步走一遍"的完整体验。5 个固定步骤(欢迎/
// 数据源/自动化权限/语言/完成),每一步的设置项都直接绑定到 AppSettings 对应属性、
// 立即生效(跟 SettingsView 里同一批设置项一样,不做"最后统一确认"这种这个项目里
// 从未出现过的模式),向导只是把它们串成一个有引导性的首次体验,不是另一套独立状态。
struct OnboardingView: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step = 0
    @State private var automationStatus: MusicAutomationPermissionStatus = .notDetermined

    private static let totalSteps = 5

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcomeStep
                case 1: dataSourceStep
                case 2: automationStep
                case 3: languageStep
                default: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(28)

            Divider()

            HStack {
                stepDots
                Spacer()
                if step > 0 {
                    Button(L10n.t("上一步")) { step -= 1 }
                }
                Button(step == Self.totalSteps - 1 ? L10n.t("开始使用") : L10n.t("下一步")) {
                    if step == Self.totalSteps - 1 {
                        finish()
                    } else {
                        step += 1
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: 420)
        .onAppear { automationStatus = MusicAutomationPermission.check(askIfNeeded: false) }
        // 不管走没走完(包括直接点红绿灯关掉窗口)都算"已经引导过一次"——跟这个 App
        // 里其它一次性引导(旧版自动化权限 NSAlert)同样的"不反复打扰"哲学,想再看
        // 可以从菜单栏"重新查看引导向导"手动重新打开。
        .onDisappear { settings.hasCompletedOnboarding = true }
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<Self.totalSteps, id: \.self) { i in
                Circle()
                    .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "text.quote")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text(L10n.t("欢迎使用 desktop-lyrics"))
                .font(.title.bold())
            Text(L10n.t("一个贴心的桌面悬浮歌词小工具。接下来用几步简单设置，帮你把它调整成合适的样子——这些选项以后随时可以在设置里再调整。"))
                .foregroundStyle(.secondary)
        }
    }

    private var dataSourceStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("播放状态来源"))
                .font(.title2.bold())
            Picker(selection: Binding(
                get: { settings.dataSourceMode },
                set: { newValue in
                    settings.dataSourceMode = newValue
                    PlaybackCoordinator.shared.applyMode(newValue)
                }
            )) {
                Text(L10n.t("远程(网页同源)")).tag(PlaybackSourceMode.relay)
                Text(L10n.t("本地播放(这台 Mac)")).tag(PlaybackSourceMode.local)
            } label: { EmptyView() }
                .pickerStyle(.segmented)
                .labelsHidden()
            Text(L10n.t("远程(网页同源)：跟网页版读同一份数据，来自你自己部署的状态中继服务，适合想跟网页显示保持完全一致的场景。本地播放(这台 Mac)：直接读这台 Mac 上系统正在播放的内容，不经过网络，更实时。"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var automationStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("Apple Music 自动化权限"))
                .font(.title2.bold())
            Text(L10n.t("desktop-lyrics 可以在本地模式下读取 Apple Music 的精确播放进度(误差 <0.1 秒)，需要系统「自动化」权限允许控制 Music.app。不授权也能正常使用——播放进度会改用估算值，可能有 1-2 秒误差。"))
                .foregroundStyle(.secondary)
            if settings.dataSourceMode != .local {
                Text(L10n.t("这一步只在「本地播放」模式下生效，当前选的是远程数据源，可以跳过。"))
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            HStack {
                Image(systemName: automationStatusIconName)
                    .foregroundStyle(automationStatusIconColor)
                Text(automationStatusCaption)
                Spacer()
                Button(automationActionTitle) { handleAutomationAction() }
            }
        }
    }

    private var languageStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("语言"))
                .font(.title2.bold())
            Picker(L10n.t("语言"), selection: $settings.appLanguage) {
                Text(L10n.t("跟随系统")).tag("system")
                Text(L10n.t("简体中文")).tag("zh-hans")
                Text("English").tag("en")
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text(L10n.t("一切就绪"))
                .font(.title.bold())
            Text(L10n.t("可以随时在设置里调整这些选项，也可以从菜单栏重新打开这个引导向导。"))
                .foregroundStyle(.secondary)
        }
    }

    // 跟 GeneralSettingsTab 同一套状态展示逻辑,这里独立写一份而不是抽共享组件——
    // 就这几行纯展示分支,抽象成本比重复它本身更高。
    private var automationStatusCaption: String {
        switch automationStatus {
        case .authorized: return L10n.t("已授权")
        case .denied: return L10n.t("已拒绝")
        case .notDetermined: return L10n.t("未授权")
        }
    }

    private var automationStatusIconName: String {
        switch automationStatus {
        case .authorized: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .notDetermined: return "questionmark.circle.fill"
        }
    }

    private var automationStatusIconColor: Color {
        switch automationStatus {
        case .authorized: return .green
        case .denied: return .red
        case .notDetermined: return .orange
        }
    }

    private var automationActionTitle: String {
        automationStatus == .notDetermined ? L10n.t("请求权限") : L10n.t("打开系统设置")
    }

    private func handleAutomationAction() {
        if automationStatus == .notDetermined {
            automationStatus = MusicAutomationPermission.check(askIfNeeded: true)
        } else {
            NSWorkspace.shared.open(MusicAutomationPermission.systemSettingsURL)
        }
    }

    private func finish() {
        settings.hasCompletedOnboarding = true
        dismissWindow(id: "onboarding")
    }
}
