import AppKit
import LyrimuseCore
import SwiftUI

// 首次启动的完整引导向导,参照 Jukebox/PlayStatus/Tuneful 这类"一步步走一遍"的
// 体验。每一步的设置项都直接绑定到 AppSettings/FeatureSettingsStore 对应属性、立即
// 生效(跟 SettingsView 里同一批设置项一样,不做"最后统一确认"),向导只是把它们串成
// 一个有引导性的首次体验,不是另一套独立状态。
//
// 步数不再是写死的常量——选了 QQ 音乐时,"Apple Music 自动化权限"这一步整个不需要
// 出现(QQ 音乐走系统级 MediaRemote,没有这个权限的概念),steps 按当前选中的播放器
// 动态算出这一轮实际要走哪几步,下面的按钮/进度点都跟着这份列表走,不再硬编码具体
// 步数下标。也没有任何"重新打开"的入口(菜单栏/设置都不留)——只在首次启动自动出现
// 一次,关掉/走完都不会再自动弹出,想再调整这里涉及的每一项都能在设置里单独找到。
struct OnboardingView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var features = FeatureSettingsStore.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @State private var step = 0
    @State private var automationStatus: MusicAutomationPermissionStatus = .notDetermined
    // 点"请求权限"之后到系统弹窗真正有结果之前的等待状态——见
    // MusicAutomationPermission.requestWithTimeout 注释,这一步不能同步阻塞主线程。
    @State private var isRequestingAutomation = false
    // 等了 8 秒还没有结果(可能系统弹窗被晾在一边没处理,也可能就是那个已知的挂起
    // bug 撞上了)——提前亮出"打开系统设置"这条备选路径,不用死等这次请求。
    @State private var automationRequestTimedOut = false
    // collector 常驻服务是否真的在跑——这一步是"软强制"的必经步骤:锁住下一步按钮,
    // 但仍然可以直接关掉整个引导窗口跳过,不禁用/隐藏关闭按钮。
    @State private var collectorRunning = false
    @State private var isTogglingCollectorService = false

    private enum Step: Equatable {
        case welcome, playerChoice, automation, collectorService, language, lastfm, done
    }

    // Apple Music 才需要 automation 这一步——QQ 音乐没有"自动化"权限的概念(见文件
    // 顶部注释)。这份列表本身不 @State,是纯粹从 features.player 派生出来的,player
    // 一变(用户在上一步刚选完)下一次读到的就是新列表,不需要额外同步。
    private var steps: [Step] {
        var s: [Step] = [.welcome, .playerChoice]
        if features.player == .appleMusic {
            s.append(.automation)
        }
        // lastfm 放在 language 之后、done 之前——跟前面 automation/collectorService
        // 那两个"必需"步骤不同,这一步纯介绍性质、完全可跳过(下一步按钮从不为它禁用,
        // 见 body 里的 .disabled),只是提升 Last.fm 这个已经相当完整的功能被新用户
        // 发现的概率(之前完全没在 Onboarding 里出现过,只能自己摸到设置里折叠着的
        // 入口才会发现)。
        s.append(contentsOf: [.collectorService, .language, .lastfm, .done])
        return s
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch steps[step] {
                case .welcome: welcomeStep
                case .playerChoice: playerChoiceStep
                case .automation: automationStep
                case .collectorService: collectorServiceStep
                case .language: languageStep
                case .lastfm: lastfmStep
                case .done: doneStep
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
                Button(step == steps.count - 1 ? L10n.t("开始使用") : L10n.t("下一步")) {
                    if step == steps.count - 1 {
                        finish()
                    } else {
                        step += 1
                    }
                }
                .keyboardShortcut(.defaultAction)
                // collectorService 和 automation 都标着"（必需）",锁"下一步"的逻辑必须
                // 两步都覆盖到——2026-08-02 实测排查坐实:早先这里漏了 automation,用户
                // 如果误点了系统权限弹窗的"不允许"、或者弹窗还没处理就切走,回来能直接
                // 点到底走完向导,doneStep 却无条件显示"一切就绪",没有任何东西提醒用户
                // 核心权限其实没给。跟 collectorServiceStep 一样是"软强制"——只锁"下一步"
                // 按钮,不禁用/隐藏关闭按钮,用户仍然可以直接关掉整个引导窗口跳过。
                .disabled(
                    (steps[step] == .collectorService && !collectorRunning)
                        || (steps[step] == .automation && automationStatus != .authorized)
                )
            }
            .padding(16)
        }
        .frame(width: 480, height: 420)
        .onAppear {
            automationStatus = MusicAutomationPermission.check(askIfNeeded: false)
            collectorRunning = CollectorServiceManager.isRunning
        }
        // 用户点"请求权限"之后可能会切到系统设置面板手动处理(尤其是等超时了、
        // 走"打开系统设置"这条备选路径的时候),切回来时重新读一次最新状态——不然
        // 界面会一直卡在切出去之前的旧状态,像是"我明明点了允许,这里怎么还没变"。
        // 顺带清掉 isRequestingAutomation/automationRequestTimedOut:如果已经确定
        // 不再是 notDetermined,就没有理由继续显示"正在等待"这套 UI——不这样做的话,
        // 上面状态文字已经变成"已授权"了,下面却还卡在超时提示/转圈,两处互相矛盾。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            let latest = MusicAutomationPermission.check(askIfNeeded: false)
            automationStatus = latest
            if latest != .notDetermined {
                isRequestingAutomation = false
                automationRequestTimedOut = false
            }
        }
        // 不管走没走完(包括直接点红绿灯关掉窗口)都算"已经引导过一次"——这里没有任何
        // 重新打开的入口,关掉就是关掉了。
        .onDisappear { settings.hasCompletedOnboarding = true }
        // 见 AuxiliaryWindowActivation 注释——.accessory 策略下临时借一个 Dock 图标。
        .onAppear { AuxiliaryWindowActivation.windowDidAppear() }
        .onDisappear { AuxiliaryWindowActivation.windowDidDisappear() }
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<steps.count, id: \.self) { i in
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
            Text(L10n.t("一个贴心的桌面悬浮歌词小工具。接下来用几步简单设置，帮你把它调整成合适的样子——这些选项以后随时可以在设置里再调整"))
                .foregroundStyle(.secondary)
        }
    }

    private var playerChoiceStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("选择播放器"))
                .font(.title2.bold())
            Text(L10n.t("Lyrimuse 支持从 Apple Music 或 QQ 音乐读取播放状态——选一个你平时用来听歌的 App，随时可以在设置里重新选择"))
                .foregroundStyle(.secondary)
            Picker(L10n.t("播放器"), selection: Binding(
                get: { features.player },
                set: { features.player = $0; Task { await features.save() } }
            )) {
                ForEach(PlaybackPlayer.allCases) { player in
                    Text(player.displayName).tag(player)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var automationStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("Apple Music 自动化权限（必需）"))
                .font(.title2.bold())
            Text(L10n.t("Lyrimuse 需要这个权限来读取 Apple Music 当前正在播放的歌曲信息——没有它，悬浮歌词完全没法显示任何内容。点下面的按钮会弹出系统授权对话框，选择「允许」即可；随时可以在设置里重新打开这一步"))
                .foregroundStyle(.secondary)
            HStack {
                Image(systemName: automationStatusIconName)
                    .foregroundStyle(automationStatusIconColor)
                Text(automationStatusCaption)
                Spacer()
                if isRequestingAutomation {
                    ProgressView().controlSize(.small)
                } else {
                    Button(automationActionTitle) { handleAutomationAction() }
                }
            }
            if isRequestingAutomation {
                if automationRequestTimedOut {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.t("这次请求耗时有点久。如果你已经看到系统弹窗，请去处理它；找不到弹窗的话，可以直接去系统设置里手动开启"))
                        Button(L10n.t("打开系统设置")) {
                            NSWorkspace.shared.open(MusicAutomationPermission.systemSettingsURL)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text(L10n.t("请查看屏幕上弹出的系统授权对话框，选择「允许」"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var collectorServiceStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("常驻后台服务（必需）"))
                .font(.title2.bold())
            Text(L10n.t("Lyrimuse 需要一个后台程序常驻运行，负责读取播放状态、解析歌词/封面并写入本地缓存——没有它，悬浮歌词/灵动岛同样无法显示任何内容。点下面的按钮即可启用，之后开机会自动运行，不用再管"))
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

    // 纯介绍性质,不收集任何凭据(那些留给设置里的 Last.fm 详情页)——向导这一步只
    // 负责让用户知道有这个功能、值不值得现在就去配。点了"现在去设置里连接"会直接
    // 打开设置窗口并停在 Last.fm 详情页(见 AppActions.pendingSettingsSelection),
    // 不用先关掉引导向导再自己去侧边栏找。
    private var lastfmStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 44))
                .foregroundStyle(.pink)
            Text(L10n.t("连接 Last.fm（可选）"))
                .font(.title.bold())
            Text(L10n.t("连上同一个 Last.fm 账号，可以双向同步收听记录，还能解锁「每周听歌小结」「每日听歌报告」推送。不连接完全不影响悬浮歌词，随时可以之后在设置里配置"))
                .foregroundStyle(.secondary)
            Button(L10n.t("现在去设置里连接")) {
                AppActions.shared.pendingSettingsSelection = .account(.lastfm)
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text(L10n.t("一切就绪"))
                .font(.title.bold())
            Text(L10n.t("可以随时在设置里调整这些选项"))
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
            requestAutomationPermission()
        } else {
            NSWorkspace.shared.open(MusicAutomationPermission.systemSettingsURL)
        }
    }

    // 见 MusicAutomationPermission.requestWithTimeout 注释——这一步不能直接在按钮
    // 点击回调里同步调用,那样会把整个 App UI 冻结、表现成"点了没反应"。超时(返回
    // nil)时 isRequestingAutomation 故意保持 true、不重新允许点"请求权限":原来那次
    // 检查很可能还在后台跑着,不该让用户再并发触发第二次系统弹窗请求,只亮出"打开
    // 系统设置"这条不冲突的备选路径。
    private func requestAutomationPermission() {
        isRequestingAutomation = true
        automationRequestTimedOut = false
        Task {
            if let status = await MusicAutomationPermission.requestWithTimeout() {
                automationStatus = status
                isRequestingAutomation = false
                automationRequestTimedOut = false
            } else {
                automationRequestTimedOut = true
            }
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
