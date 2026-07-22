import SwiftUI

// 首次启动的完整引导向导,参照 Jukebox/PlayStatus/Tuneful 这类"一步步走一遍"的
// 体验。每一步的设置项都直接绑定到 AppSettings 对应属性、立即生效(跟 SettingsView
// 里同一批设置项一样,不做"最后统一确认"),向导只是把它们串成一个有引导性的首次
// 体验,不是另一套独立状态。
//
// 不含"播放状态来源"选择——本地数据源是唯一的数据源(见 PlaybackCoordinator.start()),
// 不是可配置项。也没有任何"重新打开"的入口(菜单栏/设置都不留)——只在首次启动自动
// 出现一次,关掉/走完都不会再自动弹出,想再调整这里涉及的每一项都能在设置里单独找到。
struct OnboardingView: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step = 0
    @State private var automationStatus: MusicAutomationPermissionStatus = .notDetermined
    // collector 常驻服务是否真的在跑——这一步是"软强制"的必经步骤:锁住下一步按钮,
    // 但仍然可以直接关掉整个引导窗口跳过,不禁用/隐藏关闭按钮。
    @State private var collectorRunning = false
    @State private var isTogglingCollectorService = false

    private static let totalSteps = 5

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcomeStep
                case 1: automationStep
                case 2: collectorServiceStep
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
                .disabled(step == 2 && !collectorRunning)
            }
            .padding(16)
        }
        .frame(width: 480, height: 420)
        .onAppear {
            automationStatus = MusicAutomationPermission.check(askIfNeeded: false)
            collectorRunning = CollectorServiceManager.isRunning
        }
        // 不管走没走完(包括直接点红绿灯关掉窗口)都算"已经引导过一次"——这里没有任何
        // 重新打开的入口,关掉就是关掉了。
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
            Text(L10n.t("欢迎使用 Lyrimuse"))
                .font(.title.bold())
            Text(L10n.t("一个贴心的桌面悬浮歌词小工具。接下来用几步简单设置，帮你把它调整成合适的样子——这些选项以后随时可以在设置里再调整。"))
                .foregroundStyle(.secondary)
        }
    }

    private var automationStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("Apple Music 自动化权限（必需）"))
                .font(.title2.bold())
            Text(L10n.t("Lyrimuse 需要这个权限来读取 Apple Music 当前正在播放的歌曲信息——没有它，悬浮歌词完全没法显示任何内容。点下面的按钮会弹出系统授权对话框，选择「允许」即可；随时可以在设置里重新打开这一步。"))
                .foregroundStyle(.secondary)
            HStack {
                Image(systemName: automationStatusIconName)
                    .foregroundStyle(automationStatusIconColor)
                Text(automationStatusCaption)
                Spacer()
                Button(automationActionTitle) { handleAutomationAction() }
            }
        }
    }

    private var collectorServiceStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("常驻后台服务（必需）"))
                .font(.title2.bold())
            Text(L10n.t("Lyrimuse 需要一个后台程序常驻运行，负责读取播放状态、解析歌词/封面并写入本地缓存——没有它，悬浮歌词/灵动岛同样无法显示任何内容。点下面的按钮即可启用，之后开机会自动运行，不用再管。"))
                .foregroundStyle(.secondary)
            HStack {
                Image(systemName: collectorRunning ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(collectorRunning ? .green : .red)
                Text(collectorRunning ? L10n.t("运行中") : L10n.t("未运行"))
                Spacer()
                if isTogglingCollectorService {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L10n.t("启用")) { enableCollectorService() }
                        .disabled(collectorRunning)
                }
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
            Text(L10n.t("可以随时在设置里调整这些选项。"))
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

    private func enableCollectorService() {
        isTogglingCollectorService = true
        Task {
            let running = await CollectorServiceManager.setEnabledAndWait(true)
            settings.collectorServiceEnabled = true
            collectorRunning = running
            isTogglingCollectorService = false
        }
    }

    private func finish() {
        settings.hasCompletedOnboarding = true
        dismissWindow(id: "onboarding")
    }
}
