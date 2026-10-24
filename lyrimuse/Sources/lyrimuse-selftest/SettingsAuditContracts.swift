import Foundation
import LyrimuseCore

/// 设置与配置整模块审计(14 章决策 135)那一轮修复的源码契约。挂在 settings-ui 组末尾。
func runSettingsAuditContracts() {
    let appDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("lyrimuse")
    func app(_ name: String) -> String {
        (try? String(contentsOf: appDir.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }
    let coreDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("LyrimuseCore")
    func core(_ name: String) -> String {
        (try? String(contentsOf: coreDir.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    // ---- 配置与持久化 ----
    let portability = app("Settings/ConfigPortability.swift")
    let clear = sourceBody("static func clearAllConfig()", in: portability)
    expectEqual(sourceHas(clear, "FeatureSettingsStore.shared.suspendWritesForReset()\nAppSettingsMirror.writesSuspended = true")
                && !clear.contains("FeatureSettingsStore.shared.load()"), true,
                "清除所有设置: 先停住功能开关和镜像的写盘,不再 load()(文件不在时会把内存旧值整份写回)")
    let features = app("Settings/FeatureSettingsStore.swift")
    expectEqual(sourceHas(sourceBody("public func persistFile()", in: features), "guard !writesSuspendedForReset else { return }"), true,
                "清除所有设置: 停写之后 features.json 一个字节不写")
    expectEqual(sourceHas(sourceBody("static func write()", in: app("Settings/AppSettingsMirror.swift")), "guard !writesSuspended else { return }"), true,
                "清除所有设置: 停写之后镜像不写(退出时那一次也不写)")
    expectEqual(sourceHas(portability, "dict[\"lyrics_dir\"] = nil"), true,
                "导入: 别的机器的歌词文件夹在本机建不出来就退回默认位置")
    expectEqual(features.contains("knownKeys: FeatureFlagsFile.knownFileKeys, secure: true)"), true,
                "features.json 按 0600 写(手动代理可带账号密码)")
    expectEqual(sourceHas(features, "players: (players.map(\\.rawValue) + unknownPlayers).sorted(),")
                && sourceHas(features, "launchLyrimuseOnPlayers: (launchLyrimuseOnPlayers.map(\\.rawValue) + unknownLaunchPlayers).sorted(),"), true,
                "功能开关: 这个版本不认识的播放器名写回时原样带上")
    let settings = app("Settings/AppSettings.swift")
    expectEqual(sourceHas(settings, "if storedObs == nil { defaults.set(obsEnabled, forKey: Keys.obsLyricsEnabled) }"), true,
                "OBS 开关: 继承网页歌词开关的值当场落盘")
    expectEqual(sourceHas(settings, "if storedUnsungFollows == nil { defaults.set(unsungFollows, forKey: Keys.karaokeUnsungFollowsCoverArt) }"), true,
                "未唱色跟随封面: 推出来的默认值当场落盘")
    expectEqual(sourceHas(settings, "lyricsOffsetStepMs = min(max((defaults.object(forKey: Keys.lyricsOffsetStepMs) as? Int) ?? 200, 50), 2000)"), true,
                "偏移步长: 读盘夹进 0.05~2 秒")
    expectEqual(sourceHas(settings, ".flatMap { [\"system\", \"zh-hans\", \"zh-hant\", \"en\"].contains($0) ? $0 : nil } ?? \"system\""), true,
                "界面语言: 读盘只认四个值")
    let delegate = app("AppDelegate.swift")
    expectEqual(sourceHas(delegate, "if launchAtLoginStored { AppSettings.shared.syncLaunchAtLoginFromSystem() }\nLoginItemManager.shared.syncAtLaunch(enabled: AppSettings.shared.launchAtLoginEnabled)"), true,
                "开机启动: 存过时先按系统实际状态对账,再注册(系统设置里移除了不会被注册回去)")
    expectEqual(sourceHas(delegate, "cached.target == nil || cached.target?.window === win {"), true,
                "滚轮兜底转发: 复用缓存前核对目标还在这扇窗里")
    expectEqual(sourceHas(core("Util/JSONConfigDocument.swift"), "let target = url.resolvingSymlinksInPath()"), true,
                "配置文件原子写: 写到软链接指向的那份,不把链接换成普通文件")
    expectEqual(sourceHas(core("Util/CredentialVault.swift"),
                          "if NSDictionary(dictionary: contents).isEqual(to: loaded.filter { !CredentialVault.isBlank($0.value) }) {"), true,
                "钥匙串保险箱: 内容没变就不写(账号页自动保存不再每次起 security 子进程)")

    // ---- 设置窗口与各页 ----
    let view = app("SettingsView.swift")
    expectEqual(sourceHas(view, "let base = follows ? offsets.globalOffsetMs : storedOffsetMs(scope)")
                && sourceHas(view, "Button { setOffset(max(-limit, base - step), scope: scope) } label: {")
                && sourceHas(view, "Button { setOffset(min(limit, base + step), scope: scope) } label: {"), true,
                "按播放器偏移: 跟随「全部」时 ± 从全局值起步")
    expectEqual(sourceHas(view, "lyricsRestoreFailed = restored == nil || (restored?.failed ?? 0) > 0")
                && sourceHas(view, "let failed = ConfigPortability.lastImportFailures + (lyricsRestoreFailed ? [L10n.t(\"歌词\")] : [])"), true,
                "导入: 歌词恢复失败也算没导全、不重启")
    let iCloud = sourceBody("private func importFromICloud()", in: view)
    expectEqual(sourceHas(iCloud, "} else {\npendingImportLyrics = nil\n}")
                && sourceHas(iCloud, "guard iCloudSnapshot?.url == snap.url else { return }"), true,
                "从 iCloud 恢复: 歌词包解不开当作不带;等下载期间换了文件夹不弹旧的确认框")
    expectEqual(sourceHas(view, "SettingsGlassActionMenu(title: L10n.t(\"备份文件夹…\"), entries: backupFolderMenuEntries)")
                && sourceHas(view, ".disabled(iCloudBusy)"), true,
                "备份文件夹菜单: 正在从 iCloud 读备份时禁用")
    expectEqual(sourceHas(view, "\"\\(Int(expandedWidthThrottle.value(or: NotchEditorStage.effectiveExpandedWidth("), true,
                "灵动岛展开宽度: 读数跟滑块同一个值")
    expectEqual(sourceHas(sourceBody("private var appleMusicConnectionSubtitle: String", in: view), "formatter.locale = L10n.locale"), true,
                "Apple Music 连接: 到期日按界面语言排")
    expectEqual(sourceHas(app("Settings/WebLyricsSettingsCard.swift"), "if armToken == token { armed = false }"), true,
                "重置访问密钥: 4 秒复原带令牌")
    let coverage = app("UI/WindowCoverageMonitor.swift")
    expectEqual(sourceHas(sourceBody("private func tick()", in: coverage), "guard let window, window.isVisible else {")
                && sourceHas(coverage, "self?.resumeTimerIfNeeded()"), true,
                "遮挡检测: 窗口收起就停 2 秒那个计时器,再露面接上")

    // ---- 全局件 ----
    let recorder = app("Settings/ShortcutRecorder.swift")
    expectEqual(sourceHas(sourceBody("override func viewDidMoveToWindow()", in: recorder), "guard let window else {\nstopRecording()\nreturn\n}"), true,
                "快捷键录制: 移出窗口时收尾,撤掉暂停全局快捷键")
    expectEqual(sourceHas(sourceBody("private func startRecording()", in: recorder), "clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown])")
                && sourceHas(sourceBody("private func stopRecording()", in: recorder), "NSEvent.removeMonitor(clickMonitor)"), true,
                "快捷键录制: 点在别处就收尾")
    let unknown = app("Settings/UnknownPlayerNotifier.swift")
    let trust = sourceBody("static func trust(_ bundleID: String) async", in: unknown)
    expectEqual(!trust.isEmpty
                && trust.range(of: "dismissDelivered")!.lowerBound < trust.range(of: "guard !TrustedPlayers.isAccepted")!.lowerBound, true,
                "信任播放器: 先撤通知再查重")
    expectEqual(view.contains("Task { await UnknownPlayerNotifier.trust(seen.bundleID) }")
                && view.contains("Task { await UnknownPlayerNotifier.trust(bundleID) }")
                && !view.contains("FeatureSettingsStore.shared.trust(bundleID:"), true,
                "信任播放器: 设置页两处走同一个入口(会撤通知)")
    expectEqual(sourceHas(unknown, "guard !announcing.contains(seen.bundleID) else { return }"), true,
                "新播放器提醒: 上一次还没走完不再发")
    expectEqual(sourceHas(unknown, "languageSink = AppSettings.shared.$appLanguage.dropFirst().removeDuplicates()"), true,
                "新播放器提醒: 换界面语言重注册通知按钮")
    expectEqual(sourceHas(app("Settings/NowPlayingNotifier.swift"), "guard !Task.isCancelled else {\ndiscardAttachments()\nreturn\n}"), true,
                "换歌通知: 没投出去的封面临时文件删掉")
    expectEqual(sourceHas(sourceBody("public static var state: LaunchdJobState", in: app("Settings/EngineServiceManager.swift")),
                          "LaunchdPrintParser.query(label: label)")
                && sourceHas(core("Local/LaunchdJobState.swift"),
                             "ProcessRunner.run(\"/bin/launchctl\", [\"print\", \"gui/\\(getuid())/\\(label)\"], timeout: timeout)"), true,
                "引擎服务状态: launchctl print 带超时")
    expectEqual(sourceHas(app("OnboardingView.swift"), "!refreshingEngineRunning {"), true,
                "引导页: 上一次查询没回来不再叠一次")
    expectEqual(sourceHas(app("Settings/DiagnosticsExporter.swift"), "} else if let current = try? OSLogStore(scope: .currentProcessIdentifier) {"), true,
                "诊断导出: 系统日志库打不开时退到本次启动的记录")
}
