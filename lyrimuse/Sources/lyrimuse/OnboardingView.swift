import AppKit
import Combine
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
// 步数下标。首次启动自动出现一次;关窗等于"稍后再说"(下次启动会再问),真正走完最后
// 一步才算引导过。走完之后菜单栏的"重新运行引导…"可以随时再来一遍,这里涉及的每一项
// 也都能在设置里单独找到。
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
    // 只用来决定要不要提醒"灵动岛/菜单栏歌词得等播起来才看得见"。
    //
    // ⚠️ 刻意**不**写成 `@ObservedObject private var coordinator = PlaybackCoordinator.shared`:
    // 那会订阅整个单例,而它有二十来个 @Published(currentLine/anchor/artworkImage… 每个播放
    // tick 都在变),整个向导会跟着高频重渲染 —— 这个仓库为"@ObservedObject 订阅整个单例"
    // 踩过一次真实的 20Hz 过度重渲染 bug(见"歌词管理"窗口那次)。这里只要 isPlayingNow 这
    // 一个布尔,单独订阅 + removeDuplicates,只有真的开始/停止播放时才动一次。
    // @Published 的 publisher 在订阅那一瞬间就会把当前值发过来,所以初值给 false 不会停在
    // 错的状态上。
    @State private var isPlayingNow = false

    private enum Step: Equatable {
        case welcome, playerChoice, automation, collectorService, language, displayMode, lastfm, done
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
        s.append(contentsOf: [.collectorService, .language, .displayMode, .lastfm, .done])
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
                case .displayMode: displayModeStep
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
        .onReceive(PlaybackCoordinator.shared.$isPlayingNow.removeDuplicates()) { playing in
            isPlayingNow = playing
        }
        // ⚠️ 这里原来挂着 `.onDisappear { settings.hasCompletedOnboarding = true }`,
        // 也就是"不管走没走完(包括直接点红绿灯关窗)都算引导过了"。2026-08-13 去掉。
        //
        // 那个行为会造成一条不可自愈的死路:常驻服务默认不装,而歌词全部来自 collector
        // 写在磁盘上的缓存(见 LocalPlaybackSource 顶部注释)—— 第一步就关窗的用户,
        // 服务没装、引导又被标记成"已完成"再也不会出现,于是桌面上留着一个永远停在
        // "搜索歌词中…"的悬浮窗,而他没有任何入口把服务装起来。
        //
        // 现在 hasCompletedOnboarding 只由 finish() 置位(= 真的走到最后一步)。关窗
        // 等于"稍后再说",下次启动会再问一次;而已经走完的人可以从菜单栏的
        // "重新运行引导…"随时再来一遍。
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
            Text(L10n.t("Lyrimuse 支持 Apple Music、QQ 音乐、网易云音乐、Spotify，也可以交给「自动识别」——挑一个你平时用来听歌的，随时可以在设置里重新选择"))
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

    // 三种显示形态在代码里完全正交(各自独立的开关 + 各自独立的窗口控制器,可以同时开、
    // 也可以一个都不开),所以这里是三个独立开关,不是单选 Picker。第四种形态"歌词窗口"
    // 刻意不放进来:它没有任何持久化开关,在向导里打开只会弹一扇窗盖住向导本身,而且下次
    // 启动不保留 —— 在这里承诺它等于承诺一个不存在的偏好。
    //
    // ⚠️ 三条必须守住的写法约束:
    // 1) 关着的那个形态,渲染路径上连 `.shared` 都不能碰 —— 两个窗口控制器都是
    //    `static let shared`,init() 里订阅 PlaybackCoordinator.$isPlayingNow 的那个
    //    Combine sink 在订阅的一瞬间就会把窗口建出来并显示(NotchLyricsWindowController
    //    顶部 :31-39 那段注释记的就是这个)。所以两个 `.shared` 只允许出现在 Binding 的
    //    set 闭包里(只在用户真的拨动开关时执行),get 一律读 settings 上的持久化布尔值。
    //    落地自查:本文件里 `WindowController.shared` 必须恰好两处,且都在 set: 里。
    // 2) 开/关必须走 setVisible(_:) —— classicOverlayEnabled/notchOverlayEnabled 的
    //    didSet 只写 UserDefaults、没有任何副作用,直接赋值只会得到"设置里显示开着、窗口
    //    其实没出现"的错位,要重启 App 才对得上;还会漏掉 setVisible 打开时补应用的
    //    hideDuringScreenCapture / hideWhenNotPlaying / lockPosition。写法与设置页
    //    SettingsView.currentSection 里那三处逐字一致。
    // 3) 不做任何"帮用户预选"的 onAppear 赋值:全新用户本来就默认开着桌面悬浮歌词
    //    (AppSettings.init() 里的 ?? true),而 AppSettingsMirror.restoreIfPristine()
    //    会让重装/同机重来的用户带着自己的旧配置走到这一步,强行预选等于静默覆盖他的
    //    选择(而且绕过 setVisible,改完窗口还不动)。这一步只读不写,唯一的写入路径是
    //    用户亲手拨动开关。
    //
    // ⚠️ 还有一条结构性约束:这一步里永远不准出现能改 features.player 的控件。steps 的
    // 长度由 player 决定,而 `steps[step]` 没有任何越界守卫 —— 当前安全是因为唯一能让
    // steps 变短的控件在 index 1(playerChoiceStep),而 index 1 在 7 项/8 项列表里都合法。
    private var displayModeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("歌词显示在哪里"))
                .font(.title2.bold())
            Text(L10n.t("这几种可以同时开着，先挑你现在想用的——之后随时能在设置里单独开关"))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                displayModeRow(
                    kind: .classic,
                    title: L10n.t("桌面悬浮歌词"),
                    subtitle: L10n.t("贴在桌面上"),
                    isOn: Binding(
                        get: { settings.classicOverlayEnabled },
                        set: { LyricsOverlayWindowController.shared.setVisible($0) }))
                displayModeRow(
                    kind: .notch,
                    title: L10n.t("灵动岛歌词"),
                    subtitle: hasNotchedScreen
                        ? L10n.t("紧凑地贴着屏幕顶部的刘海")
                        : L10n.t("这台 Mac 没有刘海，会显示在屏幕顶部正中"),
                    isOn: Binding(
                        get: { settings.notchOverlayEnabled },
                        set: { NotchLyricsWindowController.shared.setVisible($0) }))
                displayModeRow(
                    kind: .menuBar,
                    title: L10n.t("菜单栏歌词"),
                    subtitle: L10n.t("菜单栏里的一行字"),
                    isOn: $settings.showLyricsInMenuBar)
            }

            // 这两条提示**互斥**,任何时候最多出现一条 —— 整个向导没有 ScrollView、窗口
            // 固定 480×420,超出部分既不滚动也不撑大窗口,只会被静默裁掉/压成省略号;两条
            // 同时出现正好会顶破这一步的高度预算。全关时"等播起来才看得到"也没意义了,
            // 所以警告优先。
            if noDisplayModeEnabled {
                displayModeNote(
                    icon: "exclamationmark.triangle.fill",
                    tint: .orange,
                    text: L10n.t("三种方式都关掉了，播放时屏幕上不会出现歌词——菜单栏图标一直都在，随时可以从那里重新打开"))
            } else if !isPlayingNow {
                displayModeNote(
                    icon: "info.circle.fill",
                    tint: .secondary,
                    text: L10n.t("现在没有在播放——桌面悬浮歌词会立刻出现，灵动岛和菜单栏歌词要等开始播放才看得到"))
            }
        }
    }

    // 向导不用设置窗口那套 SettingsCard/SettingsRow(两边是两套排版语言),这里自己拼一行。
    //
    // 左边不是 SF Symbol 而是一张手绘小示意图:"灵动岛"对没见过刘海机的人就是个黑话,一枚
    // rectangle.topthird.inset.filled 解释不了它到底会出现在屏幕的哪个位置;三张图并排才
    // 对照得出三种形态差在哪。
    private func displayModeRow(
        kind: DisplayModeThumbnail.Kind,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            DisplayModeThumbnail(kind: kind)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            // ⚠️ 必须显式 .toggleStyle(.switch):macOS 上 Toggle 默认画成**复选框**,只有
            // 放在 Form/List 里才会自动变成右侧胶囊开关。设置页是靠 SettingsRow 统一挂了
            // 这一句(Settings/SettingsDesignSystem.swift:346),向导里没有那个祖先,不写
            // 就是一排复选框,不报错也不崩,只是长得跟设置页对不上。
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private func displayModeNote(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                // 跟 SettingsRow 同一个理由钉死拉丁语区:SF Symbols 里有一批"字母造型"的
                // 符号带 CJK 本地化变体,中文界面下会被渲染成汉字。图标位置要的永远是图形
                // 而不是本地化文字,统一钉住。
                .environment(\.locale, Locale(identifier: "en"))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // 这台机器上有没有真刘海屏。判据直接复用 NotchLyricsWindowController 用的那一个
    // (ScreenIdentity.notched,即 safeAreaInsets.top > 0),不另起一套。
    //
    // 只换这一行的副标题文案,**不影响这个开关能不能开**:没刘海的机器上灵动岛依然可用,
    // 只是退化成屏幕顶部正中的一小条(NotchLyricsWindowController.geometry(for:) 里的
    // fallbackNotchHeight 分支)。隐藏它会让这批用户永远发现不了这个功能,禁用则是谎报
    // "不支持"。
    private var hasNotchedScreen: Bool { ScreenIdentity.notched != nil }

    private var noDisplayModeEnabled: Bool {
        !settings.classicOverlayEnabled
            && !settings.notchOverlayEnabled
            && !settings.showLyricsInMenuBar
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
            Text(L10n.t("同步收听到 Last.fm（可选）"))
                .font(.title.bold())
            Text(L10n.t("连上之后，你播放的每一首歌都会自动 scrobble 到 Last.fm，还能在这里看到你专属的听歌档案"))
                .foregroundStyle(.secondary)
            Button(L10n.t("现在去设置里连接")) {
                AppActions.shared.requestSettings(.account(.lastfm))
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
            // 引导页只关心"起来了没",不铺开三态——那是设置页排查问题时才需要的粒度。
            let state = await CollectorServiceManager.setEnabledAndWait(true)
            settings.collectorServiceEnabled = true
            collectorRunning = state.isRunning
            isTogglingCollectorService = false
        }
    }

    private func finish() {
        settings.hasCompletedOnboarding = true
        dismissWindow(id: "onboarding")
    }
}

// MARK: - 显示形态小示意图
//
// 仓库里没有任何现成的形态缩略图资产(设置页"外观"整页零预览,只有 SF Symbol),所以这三张
// 图用 SwiftUI 基本形状现画。三张共用同一个"屏幕外框 + 顶部菜单栏条"的底,差别只在歌词画
// 在哪儿 —— 三行摆在一起才对照得出"灵动岛"到底跟另外两种差在哪。
//
// 尺寸全部写成固定常量、**不用 GeometryReader**:示意图必须是可预测的固定高度,不能跟着
// 容器变(这一步没有 ScrollView,窗口固定 480×420,溢出是静默裁切)。
//
// ⚠️ 示意图**不跟着开关变灰**。第一版做过"关掉就 saturation(0)+opacity(0.45)",实测(2026-08-14
// 真机截图)是反效果:灵动岛和菜单栏歌词默认都是关的,于是最需要被解释的那两张恰好被洗成
// 两团灰斑,而这张图存在的唯一理由就是"让没见过的人看懂它会出现在屏幕哪儿"。开关状态由右
// 边的 Toggle 表达,图只负责解释位置。
private struct DisplayModeThumbnail: View {
    enum Kind { case classic, notch, menuBar }

    let kind: Kind

    private static let width: CGFloat = 56
    private static let height: CGFloat = 36
    private static let menuBarHeight: CGFloat = 6
    private static let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)

    var body: some View {
        ZStack(alignment: .top) {
            Self.shape.fill(Color.primary.opacity(0.08))
            // 顶部菜单栏条 —— 三张图共用的参照物,没有它就分不出"贴着顶部"和"在桌面上"。
            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(height: Self.menuBarHeight)
            sketch
        }
        .frame(width: Self.width, height: Self.height)
        .clipShape(Self.shape)
        .overlay(Self.shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
        // 纯装饰:位置信息已经由同一行的标题和副标题说清楚了,不让旁白再念一遍图形。
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var sketch: some View {
        switch kind {
        case .classic:
            // 桌面偏下方的两行歌词,第一行用强调色表示"正在唱的这一句"。
            VStack(spacing: 4) {
                Capsule().fill(Color.accentColor).frame(width: 32, height: 4)
                Capsule().fill(Color.primary.opacity(0.3)).frame(width: 22, height: 3)
            }
            .frame(width: Self.width, height: Self.height, alignment: .center)
            .offset(y: 5)
        case .notch:
            // 顶部正中垂下来的刘海(比菜单栏条更深、略高一点,读起来才像一块"挖掉的角"),
            // 歌词紧贴在它右边。
            HStack(spacing: 3) {
                UnevenRoundedRectangle(bottomLeadingRadius: 2, bottomTrailingRadius: 2, style: .continuous)
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: 18, height: Self.menuBarHeight + 2)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 15, height: 4)
                    .padding(.top, 1)
            }
            .frame(width: Self.width, alignment: .center)
        case .menuBar:
            // 桌面上什么都没有,只有菜单栏右端的一行字 —— 位置(靠右)是它跟灵动岛(居中)
            // 唯一的区别,所以刻意压到最右、和右边框只留 3pt。
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 20, height: 3)
                    .padding(.trailing, 3)
            }
            .frame(width: Self.width, height: Self.menuBarHeight, alignment: .trailing)
        }
    }
}
