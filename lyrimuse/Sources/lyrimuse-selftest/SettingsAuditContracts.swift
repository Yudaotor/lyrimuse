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
    expectEqual(sourceHas(features, "public var effectivePreferLocalFileLyrics: Bool { preferLocalFileLyrics ?? (lyricsSourceMode == .priority) }"),
                true, "优先用歌曲文件自带的歌词: 没碰过开关时顺序优先为开、智能算法为关(跟引擎 resolvePreferLocalFileLyrics 一致)")
    let lyricsView = app("SettingsView.swift")
    expectEqual(sourceHas(sourceBody("private var preferLocalFileRow: some View", in: lyricsView),
                          "get: { features.effectivePreferLocalFileLyrics },\nset: { features.preferLocalFileLyrics = $0; Task { await features.save() } }"),
                true, "优先用歌曲文件自带的歌词: 开关读按匹配算法补齐的值,写进文件")
    let settings = app("Settings/AppSettings.swift")
    expectEqual(sourceHas(settings, "if storedObs == nil { defaults.set(obsEnabled, forKey: Keys.obsLyricsEnabled) }"), true,
                "OBS 开关: 继承网页歌词开关的值当场落盘")
    expectEqual(sourceHas(settings, "if storedUnsungFollows == nil { defaults.set(unsungFollows, forKey: Keys.karaokeUnsungFollowsCoverArt) }"), true,
                "未唱色跟随封面: 推出来的默认值当场落盘")
    expectEqual(sourceHas(settings, "lyricsOffsetStepMs = min(max((defaults.object(forKey: Keys.lyricsOffsetStepMs) as? Int) ?? 200, 50), 2000)"), true,
                "偏移步长: 读盘夹进 0.05~2 秒")
    expectEqual(sourceHas(settings, ".flatMap { $0 == \"system\" || UILanguage.packs.contains($0) ? $0 : nil } ?? \"system\""), true,
                "界面语言: 读盘只认「跟随系统」和有语言包的几种")
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
    let sidebarGet = sourceBody("private var sidebarSelection: Binding<SettingsSidebarItem?>", in: view)
    expectEqual(sourceHas(sidebarGet, "case .softwareUpdate? where !updateBadge.isVisible: return .tab(.about)")
                && sourceHas(sidebarGet, "case .lastfmSuggestions? where suggestions.items.isEmpty: return .account(.lastfm)")
                && sourceHas(sidebarGet, "case .account(let destination)? where destination.livesInLabs: return .labs"), true,
                "侧栏: 停在没有自己那一行的页面时亮上一级(实验室子页 / 软件更新 / 账号建议)")
    expectEqual(sourceHas(view, "Button { selection = .tab(.about) } label: {")
                && sourceHas(view, "Button { selection = .account(.lastfm) } label: {")
                && sourceHas(view, "Button { selection = .labs } label: {"), true,
                "侧栏: 会被当成上一级亮着的三行包在按钮里,亮着时点它照样回到它自己那一页")
    let sidebarRows = sourceBody("@ViewBuilder private var sidebarSections: some View", in: view)
    expectEqual(sourceHas(app("AccountLinkingTab.swift"), "case .listenBrainz, .stateRelay: return true\n        case .lastfm, .discord, .bark: return false")
                && sourceHas(sidebarRows, "sidebarLabel(.shortcuts)\n            AccountSidebarRow(destination: .bark)\n                .tag(SettingsSidebarItem.account(.bark))\n            sidebarLabel(.general)"), true,
                "侧栏: 推送提醒不在实验室,是分类组里「通用」前面的一行")
    let deleteCopies = sourceBody("private func confirmDeleteLyricsWordFormatCopies()", in: view)
    expectEqual(sourceHas(deleteCopies, "guard alert.runModal() == .alertFirstButtonReturn else { return }")
                && (deleteCopies.range(of: "runModal")?.lowerBound ?? deleteCopies.endIndex)
                    < (deleteCopies.range(of: "applyLyricsWordFormats(")?.lowerBound ?? deleteCopies.startIndex)
                && sourceHas(view, "LyricsWordFormatDeleteCopiesButton { confirmDeleteLyricsWordFormatCopies() }"), true,
                "逐字歌词副本: 删除副本先确认再删")
    expectEqual(sourceHas(sourceBody("private struct LyricsWordFormatDeleteCopiesButton: View", in: view), ".disabled(monitor.isBusy)")
                && sourceHas(sourceBody("private func applyLyricsWordFormats(", in: view), "guard !monitor.isBusy else { return }"), true,
                "逐字歌词副本: 换格式那一趟没做完时删不了副本、也不起第二趟")
    expectEqual(sourceHas(view, "help: automation.unauthorizedHelp([player])"), true,
                "自动化权限: 每一行的「?」只说这一家")
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

    // ---- 名字填进中文句子时的中英文间距 ----
    typealias Spacing = MixedScriptSpacing
    expectEqual(Spacing.format("自动化权限可提高%@播放进度的准确性", ["Apple Music"]), "自动化权限可提高 Apple Music 播放进度的准确性",
                "中英文间距: 拉丁名两侧挨着汉字都补空格")
    expectEqual(Spacing.format("自动化权限可提高%@播放进度的准确性", ["网易云音乐"]), "自动化权限可提高网易云音乐播放进度的准确性",
                "中英文间距: 中文名不补")
    expectEqual(Spacing.format("提高%@播放", ["QQ音乐"]), "提高 QQ音乐播放", "中英文间距: 只看名字首尾那个字符")
    expectEqual(Spacing.format("%1$@拒收：%2$@", ["Telegram", "HTTP 400"]), "Telegram 拒收：HTTP 400",
                "中英文间距: 句首的名字只补后面;挨着标点的一侧不补")
    expectEqual(Spacing.format("已识别为%@，平台已自动切换", ["Bark"]), "已识别为 Bark，平台已自动切换", "中英文间距: 后面是全角标点不补")
    expectEqual(Spacing.format("以提高%@自动连播，并显示%@的按钮", ["Apple Music", "Spotify"]), "以提高 Apple Music 自动连播，并显示 Spotify 的按钮",
                "中英文间距: 多个参数各自处理")
    expectEqual(Spacing.format("%2$@ · %1$@", ["A", "B"]), "B · A", "中英文间距: 按位置取参数")
    expectEqual(Spacing.format("Accessibility keeps %@’s position accurate", ["Apple Music"]), "Accessibility keeps Apple Music’s position accurate",
                "中英文间距: 英文句子原样")
    expectEqual(Spacing.format("让%@直接使用", [""]), "让直接使用", "中英文间距: 空名字不留空格")
    let onboarding = app("OnboardingView.swift")
    expectEqual(onboarding.components(separatedBy: "L10n.formatNames(L10n.t(\"").count - 1 >= 15
                && !onboarding.contains("String(format: L10n.t(\"辅助功能权限可") && !onboarding.contains("String(format: L10n.t(\"请开启此权限，以"),
                true, "中英文间距: 引导页权限说明里贴着汉字的播放器名都走 formatNames")
    let channels = app("Settings/NotificationChannelsSection.swift")
    expectEqual(sourceHas(channels, "return L10n.formatNames(L10n.t(\"%1$@拒收：%2$@\"), name, head)")
                && sourceHas(channels, "L10n.formatNames(L10n.t(\"这个地址看起来是%@的。要换平台，请删除这个渠道后重新添加\"), mismatch.displayName)")
                && sourceHas(channels, "L10n.formatNames(L10n.t(\"已识别为%@，平台已自动切换\"), detected.displayName)"), true,
                "中英文间距: 推送渠道里贴着汉字的平台名走 formatNames")

    // ---- 编辑台工具栏胶囊:摘要读得完(悬浮歌词 / 灵动岛) ----
    let designSystem = app("Settings/SettingsDesignSystem.swift")
    let toggleText = sourceBody("static func text(_ entries: [(title: String, isOn: Bool)]) -> String", in: designSystem)
    expectEqual(sourceHas(toggleText, "return String(format: L10n.t(\"%@ 项开启\"), \"\\(onCount)\")") && !toggleText.contains("L10n.list"), true,
                "工具栏摘要: 开关类部分开着时只报开了几项,不列标题")
    expectEqual(sourceHas(sourceBody("static func detail(_ entries: [(title: String, isOn: Bool)]) -> String", in: designSystem),
                          "return L10n.list(onTitles)"), true, "工具栏摘要: 开着的是哪几项放进悬停说明")
    expectEqual(sourceHas(app("UI/EditorToolbarButtonLabel.swift"), ".help(title + \" · \" + (detail ?? summary))"), true,
                "工具栏摘要: 悬停说明优先用整句")
    let styleRows = app("UI/OverlayStyleSettingsRows.swift")
    expectEqual(sourceHas(sourceBody("static func fontText(family: String, weight: OverlayFontWeight, size: Int) -> String", in: styleRows),
                          "guard !family.isEmpty else { return \"\\(weight.displayName) \\(sizeText)\" }"), true,
                "工具栏摘要: 系统字体(空串)不报字体名")
    let layoutBody = sourceBody("static var layout: String", in: styleRows)
    expectEqual(sourceHas(layoutBody, "OverlayAlignmentSegmentedControl.label(for: AppSettings.shared.overlayDuetAlignmentOverride)")
                && !layoutBody.contains("OverlayLineOverflowLabel"), true, "工具栏摘要: 排版只报对齐方式")
    let screenSummary = sourceBody("enum NotchScreenSummary", in: app("UI/NotchSettingsRows.swift"))
    expectEqual(sourceHas(screenSummary, "if settings.notchFollowsActiveScreen { return L10n.t(\"跟随窗口\") }")
                && sourceHas(screenSummary, "return ScreenIdentity.isBuiltIn(screen) ? L10n.t(\"内建屏幕\") : screen.localizedName")
                && sourceHas(screenSummary, "return L10n.t(\"已断开\")"), true, "工具栏摘要: 屏幕报短名")
    let overlayStage = app("UI/OverlayEditorStage.swift")
    let notchStage = app("UI/NotchEditorStage.swift")
    expectEqual(sourceHas(overlayStage, "detail: SettingsToggleSummary.detail(behaviorEntries),")
                && sourceHas(overlayStage, "detail: OverlayStyleSummary.contentDetail,")
                && sourceHas(notchStage, "detail: SettingsToggleSummary.detail(expandedEntries),")
                && sourceHas(notchStage, "detail: SettingsToggleSummary.detail(behaviorEntries),"), true,
                "工具栏摘要: 报数量的几颗按钮都带悬停整句")
    // 胶囊上每截摘要约 55pt(中文 600pt 卡片列),固定文案得在这个量级里:中文 ≤5 字、英文 ≤13 个字符、繁体 ≤5 字。
    let packageDir = coreDir.deletingLastPathComponent().deletingLastPathComponent()
    var localized: [String: [String: String]] = [:]
    if let data = try? Data(contentsOf: packageDir.appendingPathComponent("Localization/Localizable.xcstrings")),
       let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let strings = root["strings"] as? [String: Any] {
        for (key, entry) in strings {
            guard let locs = (entry as? [String: Any])?["localizations"] as? [String: Any] else { continue }
            for lang in ["en", "zh-Hant"] {
                if let value = ((locs[lang] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String {
                    localized[key, default: [:]][lang] = value
                }
            }
        }
    }
    expectEqual(localized.isEmpty, false, "工具栏摘要: 读到了 Localizable.xcstrings")
    let summaryKeys = ["全部开启", "全部关闭", "%@ 项开启", "自动", "居中", "左对齐", "右对齐", "自由", "顶部居中", "底部居中",
                       "已开启", "未开启", "跟随窗口", "全部屏幕", "内建屏幕", "已断开", "无副行", "自动对齐"]
    let tooLong = summaryKeys.filter { key in
        guard let en = localized[key]?["en"], let hant = localized[key]?["zh-Hant"] else { return true }
        let filled = { (s: String) in s.replacingOccurrences(of: "%@", with: "9") }
        return filled(key).count > 5 || filled(hant).count > 5 || filled(en).count > 13
    }
    expectEqual(tooLong, [], "工具栏摘要: 固定文案中文 / 繁体 ≤5 字、英文 ≤13 个字符")
    expectEqual(sourceHas(app("SettingsView.swift"), "Button(allOn ? L10n.t(\"关闭全部\") : L10n.t(\"开启全部\"))"), true,
                "按钮用「开启全部 / 关闭全部」,「全部开启 / 全部关闭」只当状态摘要(法、西、韩两种语法形式不同)")

    // ---- 悬浮歌词 / 灵动岛设置的排版 ----
    let gallery = app("UI/OverlayThemeGallery.swift")
    expectEqual(sourceHas(gallery, "return (sung + unsung)") && !sourceBody("private func sample(", in: gallery).contains("HStack"), true,
                "主题卡: 示例字两半拼成一个 Text,整串一起缩放")
    expectEqual(sourceHas(sourceBody("private var totalHeight: CGFloat", in: notchStage), "(Self.toolbarHeight + Self.toolbarSpacing) * 2 + stageHeight")
                && !notchStage.contains("caption(stageWidth:"), true,
                "灵动岛编辑台: 舞台底下不留说明行,缩放提示在舞台里(到总开关卡的间距同悬浮歌词)")
    let notchBehavior = sourceBody("struct NotchBehaviorSettingsRows: View", in: app("SettingsView.swift"))
    expectEqual(sourceHas(notchBehavior, "SettingsTileGrid(title: L10n.t(\"收起与隐藏\"), columns: 3) { collapseAndHideTiles }")
                && sourceHas(notchBehavior, "SettingsTileGrid(title: L10n.t(\"提示\"), columns: 3) { notificationTiles }")
                && sourceHas(notchBehavior, "if inPopover {"), true,
                "灵动岛「行为」: 抽屉里分三组,浮层里平铺")
    let overlayBehavior = app("UI/OverlayBehaviorSettingsRows.swift")
    expectEqual(sourceHas(overlayBehavior, "case .dragNeedsLongPress: return AppSettings.shared.overlayPlacementMode == .free")
                && sourceHas(overlayBehavior, ".disabled(!item.isApplicable)"), true,
                "悬浮歌词「长按拖动」: 位置不是「自由」时置灰")

    // ---- 歌词窗口 / 菜单栏 / 触控栏:跨形态同名、同序 ----
    expectEqual(sourceHas(toggleText, "if entries.count == 1 { return onCount == 1 ? L10n.t(\"已开启\") : L10n.t(\"未开启\") }"), true,
                "工具栏摘要: 只有一项的开关报已开启 / 未开启,不报全部开启")
    expectEqual(OverlayDuetAlignmentOverride.allCases, [.automatic, .leading, .center, .trailing],
                "对齐方式: 悬浮歌词几档的顺序同另外几个形态(自动 / 左对齐 / 居中 / 右对齐)")
    let menuBarStage = app("UI/MenuBarEditorStage.swift")
    let menuBarColors = sourceBody("struct MenuBarColorRows: View {", in: menuBarStage)
    expectEqual(!menuBarColors.contains("SettingsTileGrid") && !menuBarColors.contains("SettingsToggleTile")
                && sourceHas(menuBarColors, "icon: \"sparkles\",\ntitle: L10n.t(\"卡拉OK效果\"),")
                && sourceHas(menuBarColors, "icon: settings.menuBarLyricsKaraoke ? \"circle.lefthalf.filled\" : \"paintpalette\","), true,
                "菜单栏「颜色」: 两颗开关和颜色行同一块行组,卡拉OK效果图标同另外几个形态,颜色行图标跟着标题换")
    expectEqual(sourceHas(menuBarStage, "settings.menuBarLyricsWidthMode == .fixed && !MenuBarPlacementRow.centerInUse(settings)\n? L10n.t(\"宽度\") : L10n.t(\"最大宽度\")")
                && sourceHas(menuBarStage, "SettingsRow(icon: \"arrow.left.and.right\", title: Self.title(settings)) {")
                && sourceHas(menuBarStage, ".accessibilityLabel(MenuBarWidthRow.title(settings))"), true,
                "菜单栏宽度滑杆: 固定宽度时叫「宽度」,自适应或放正中时叫「最大宽度」,读屏名同一个")
    expectEqual(sourceHas(menuBarStage, "parts.append(choice == .off ? L10n.t(\"无副行\") : choice.displayName)")
                && !sourceBody("private var contentSummary: String {", in: menuBarStage).contains("L10n.t(\"副行\")"), true,
                "菜单栏「内容」摘要: 副行只报档名(关掉报「无副行」),不带「副行 ·」前缀")
    expectEqual(sourceHas(notchStage, "parts.append(settings.notchSecondaryLine == .off ? L10n.t(\"无副行\") : settings.notchSecondaryLine.displayName)"),
                true, "灵动岛「歌词行」摘要: 副行只报档名,不带「副行 ·」前缀")
    let touchBarRows = app("UI/TouchBarSettingsRows.swift")
    expectEqual(sourceHas(touchBarRows, "case .content: return L10n.t(\"内容\")\ncase .color: return L10n.t(\"颜色\")")
                && sourceHas(touchBarRows, "case .layout: return \"rectangle.split.1x2\"")
                && sourceHas(touchBarRows, "SettingsRow(icon: \"paintpalette\", title: L10n.t(\"文字颜色\"),")
                && sourceHas(touchBarRows, "if settings.touchBarLyricsKaraoke { parts.append(L10n.t(\"卡拉OK效果\")) }"), true,
                "触控栏: 组名「内容 / 颜色 / 布局 / 行为」,颜色那一行叫文字颜色,布局图标同另外几个形态")
    let settingsRowBody = sourceBody("struct SettingsRow<Trailing: View>: View {", in: designSystem)
    expectEqual(sourceHas(touchBarRows, "? L10n.t(\"歌词使用封面主色；无法获取时为白色\") : nil,\ntrailingWrapsBelow: true) {")
                && sourceHas(settingsRowBody, "ViewThatFits(in: .horizontal) {\ninlineRow(measuringTitleOnly: true)\nstackedRow\n}")
                && sourceHas(settingsRowBody, ".frame(minWidth: 0, idealWidth: 0, alignment: .leading)"), true,
                "触控栏「文字颜色」: 四档跟标题排不下一行时换到标题下面,判据只拿标题单行宽去比(17 章决策 57)")
    expectEqual(sourceHas(menuBarStage, "icon: \"rectangle.split.1x2\",\ntitle: L10n.t(\"布局\"),"), true,
                "菜单栏: 「布局」入口图标同歌词窗口、触控栏")
    let overlayColors = sourceBody("struct OverlayColorSettingsRows: View {", in: styleRows)
    expectEqual(sourceHas(overlayColors, "title: pairedKaraokeColors ? L10n.t(\"已唱颜色\") : L10n.t(\"文字颜色\")) {")
                && sourceHas(overlayColors, "label: { $0 ? L10n.t(\"跟随封面\") : L10n.t(\"自定义\") },"), true,
                "悬浮歌词「颜色」: 开着卡拉OK时文字颜色那一格叫已唱颜色,下拉选项叫「自定义」")
    expectEqual(sourceHas(app("Settings/WebLyricsSettingsCard.swift"),
                          "note: settings.webLyricsAllowLAN ? L10n.t(\"更改后需重新扫码连接\") : L10n.t(\"更改后需重新打开本机地址\"))"),
                true, "网页歌词「端口」: 说明按局域网开没开写")
    let pageScroll = sourceBody("private struct FixedWidthScrollView<Content: View>: View {", in: app("Settings/SettingsDesignSystem.swift"))
    expectEqual(sourceHas(pageScroll, ".containerRelativeFrame(.horizontal)\n.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)")
                && !pageScroll.contains("onGeometryChange") && !pageScroll.contains("GeometryReader"), true,
                "设置页滚动: 内容按整宽排、靠左摆,常驻滚动条出现时卡片列不左移")
}
