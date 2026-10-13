import Foundation
import LyrimuseCore

/// `lyrimuse://` 路由表(Core `LyrimuseDeepLink`):对外说过的老链接照旧认、认不出的不落进 Last.fm 授权回调、
/// 设置二级分段的取值跟 App 里各 Section 枚举对得上。见 docs/proposals/deep-links.md、14 章「深链」。
func runDeepLinkTests() {
    let scheme = "lyrimuse"
    func link(_ string: String) -> LyrimuseDeepLink? {
        URL(string: string).flatMap { LyrimuseDeepLink(url: $0, scheme: scheme) }
    }

    // ---- 老链接全兼容(CHANGELOG / 支持回复里可能给过) ----
    do {
        expectEqual(link("lyrimuse://settings/lyrics"), .settings(path: "/lyrics", checkForUpdates: false), "深链: settings/<分类>")
        expectEqual(link("lyrimuse://settings/software-update?check=1"), .settings(path: "/software-update", checkForUpdates: true),
                    "深链: 软件更新页带 check=1")
        expectEqual(link("lyrimuse://settings/software-update?check=0"), .settings(path: "/software-update", checkForUpdates: false),
                    "深链: check=0 不检查")
        expectEqual(link("lyrimuse://settings/software-update?check=false"), .settings(path: "/software-update", checkForUpdates: false),
                    "深链: check 跟 on 同一套写法,false 不检查")
        expectEqual(link("lyrimuse://lyrics-manager"), .lyricsManager, "深链: 歌词管理")
        expectEqual(link("lyrimuse://lyrics-manager/song-versions"), .lyricsManagerSongVersions(key: nil, showEvidence: false),
                    "深链: 歌词管理的同曲条目面板")
        expectEqual(link("lyrimuse://lyrics-manager/song-versions?key=a%20%26%20b%7Cx%7C"), .lyricsManagerSongVersions(key: "a & b|x|", showEvidence: false),
                    "深链: 同曲条目面板带写法键,值不转小写")
        expectEqual(link("lyrimuse://lyrics-manager/song-versions?key="), .lyricsManagerSongVersions(key: nil, showEvidence: false),
                    "深链: 空的 key 当没带")
        expectEqual(link("lyrimuse://lyrics-manager/song-versions?key=a%7Cb%7C&evidence=1"), .lyricsManagerSongVersions(key: "a|b|", showEvidence: true),
                    "深链: 同曲条目面板带 evidence=1 展开匹配依据")
        expectEqual(link("lyrimuse://lyrics-manager/song-versions?evidence=0"), .lyricsManagerSongVersions(key: nil, showEvidence: false),
                    "深链: evidence=0 不展开")
        expectEqual(link("lyrimuse://lyrics-search"), .lyricsSearch, "深链: 搜索歌词小窗")
        expectEqual(link("lyrimuse://lyrics-window/search"), .lyricsWindowSearch, "深链: 歌词窗口搜索面板")
        expectEqual(link("lyrimuse://menubar-panel"), .menuBarPanel(quick: nil), "深链: 菜单栏面板")
        expectEqual(link("lyrimuse://menubar-panel?quick=Lyrics-Manager"), .menuBarPanel(quick: "lyrics-manager"),
                    "深链: 面板 quick 取值转小写")
        expectEqual(link("lyrimuse://lastfm-auth-callback?token=abc"), .lastfmAuthCallback, "深链: Last.fm 回跳带 token")
        expectEqual(link("LYRIMUSE://Lyrics-Manager/"), .lyricsManager, "深链: scheme / host 大小写、结尾斜杠不敏感")
    }

    // ---- 新增的打开类 ----
    do {
        expectEqual(link("lyrimuse://lyrics-window"), .lyricsWindow, "深链: 单独打开歌词窗口")
        expectEqual(link("lyrimuse://onboarding"), .onboarding, "深链: 欢迎引导")
    }

    // ---- 认不出的返回 nil(App 闪一句,不落进授权回调) ----
    do {
        for bad in ["lyrimuse://", "lyrimuse://nope", "lyrimuse://lyrics-window/nope", "lyrimuse://lyrics-manager/x",
                    "lyrimuse-dev://lyrics-manager", "https://lyrics-manager"] {
            expectEqual(link(bad) == nil, true, "深链: 认不出 \(bad)")
        }
        expectEqual(URL(string: "lyrimuse-dev://lyrics-manager").flatMap { LyrimuseDeepLink(url: $0, scheme: "lyrimuse-dev") },
                    .lyricsManager, "深链: Dev 变体按自己的 scheme 认")
    }

    // ---- 动作(= 全局快捷键那一套) ----
    do {
        expectEqual(link("lyrimuse://action/toggle-overlay"), .action(.toggleOverlay, on: nil, stepSeconds: nil), "动作: 不带参数 = 翻转")
        expectEqual(link("lyrimuse://action/toggle-notch?on=1"), .action(.toggleNotchOverlayHotkey, on: true, stepSeconds: nil),
                    "动作: on=1 指定目标状态")
        expectEqual(link("lyrimuse://action/toggle-translation?on=OFF"), .action(.toggleTranslationHotkey, on: false, stepSeconds: nil),
                    "动作: on 认 off / 大小写不敏感")
        expectEqual(link("lyrimuse://action/toggle-touchbar?on=1"), .action(.toggleTouchBarLyricsHotkey, on: nil, stepSeconds: nil),
                    "动作: 触控栏没有目标状态,on 当没带")
        expectEqual(link("lyrimuse://action/play-pause?on=1"), .action(.playPauseHotkey, on: nil, stepSeconds: nil),
                    "动作: 非开关类带 on 当没带")
        expectEqual(link("lyrimuse://action/lyrics-advance?step=0.25"), .action(.lyricsAdvanceHotkey, on: nil, stepSeconds: 0.25),
                    "动作: 提前带步长")
        expectEqual(link("lyrimuse://action/lyrics-delay?step=50"), .action(.lyricsDelayHotkey, on: nil, stepSeconds: nil),
                    "动作: 步长超上限当没带")
        expectEqual(link("lyrimuse://action/lyrics-delay?step=-1"), .action(.lyricsDelayHotkey, on: nil, stepSeconds: nil),
                    "动作: 负步长当没带")
        expectEqual(link("lyrimuse://action/next-track?step=1"), .action(.nextTrackHotkey, on: nil, stepSeconds: nil),
                    "动作: 非微调类带 step 当没带")
        expectEqual(link("lyrimuse://action/nope") == nil && link("lyrimuse://action") == nil
                    && link("lyrimuse://action/toggle-overlay/x") == nil, true, "动作: 认不出的名字返回 nil")
        expectEqual(Set(LyrimuseAction.allCases.map(\.linkName)).count, LyrimuseAction.allCases.count, "动作: 链接名不重复")
        expectEqual(LyrimuseAction.allCases.allSatisfy { LyrimuseAction(linkName: $0.linkName) == $0 }, true, "动作: 链接名往返")

        // rawValue 必须就是快捷键名:对不上的话快捷键注册到一个用户从没录过的名字上,按了没反应。
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let hotkeys = (try? String(contentsOf: root.appendingPathComponent("lyrimuse/Settings/GlobalHotkeys.swift"), encoding: .utf8)) ?? ""
        for action in LyrimuseAction.allCases {
            expectEqual(hotkeys.contains("= Self(\"\(action.rawValue)\")"), true, "动作: \(action.rawValue) 是一个登记过的快捷键名")
        }
        expectEqual(hotkeys.components(separatedBy: "= Self(\"").count - 1, LyrimuseAction.allCases.count,
                    "动作: 快捷键和动作一样多(新加快捷键要同时加进 LyrimuseAction)")
        expectEqual(hotkeys.contains("KeyboardShortcuts.onKeyUp(for: KeyboardShortcuts.Name(action.rawValue)) {\n                LyrimuseActionRunner.perform(action)")
                    && hotkeys.components(separatedBy: "KeyboardShortcuts.onKeyUp(for:").count - 1 == 1, true,
                    "动作: 快捷键只经 LyrimuseActionRunner 执行,跟深链同一份逻辑")
        expectEqual(link("lyrimuse://action/overlay-font-larger") == .action(.overlayFontLargerHotkey, on: nil, stepSeconds: nil)
                    && link("lyrimuse://action/overlay-font-smaller") == .action(.overlayFontSmallerHotkey, on: nil, stepSeconds: nil),
                    true, "动作: 悬浮歌词字号放大 / 缩小")
        let runner = (try? String(contentsOf: root.appendingPathComponent("lyrimuse/Settings/LyrimuseActionRunner.swift"), encoding: .utf8)) ?? ""
        let gearMenu = (try? String(contentsOf: root.appendingPathComponent("lyrimuse/UI/OverlayQuickSettingsMenu.swift"), encoding: .utf8)) ?? ""
        expectEqual(sourceBytes(runner, contain: "AppSettings.steppedOverlayFontSize(from: settings.fontSize, direction: larger ? 1 : -1)")
                    && sourceBytes(gearMenu, contain: "AppSettings.steppedOverlayFontSize(from: settings.fontSize, direction: direction)"),
                    true, "动作: 字号快捷键跟 ⚙ 菜单「字号」同一个步长和范围")
    }

    // ---- action/ 下不对应快捷键的几个,x-callback 回传 ----
    do {
        expectEqual(link("lyrimuse://action/copy-lyric"), .copyLyric(includeTranslation: false), "拷贝歌词: 默认只拷原文")
        expectEqual(link("lyrimuse://action/copy-lyric?translation=1"), .copyLyric(includeTranslation: true), "拷贝歌词: 连译文")
        expectEqual(link("lyrimuse://action/open-player"), .openPlayer, "回到播放器")
        expectEqual(link("lyrimuse://action/surfaces?overlay=0&menubar=1"), .setSurfaces(overlay: false, notch: nil, menuBar: true),
                    "展示面: 只动带了的那几个")
        expectEqual(link("lyrimuse://action/surfaces") == nil && link("lyrimuse://action/surfaces?overlay=maybe") == nil, true,
                    "展示面: 一个都没带(或认不出)时整条认不出")
        expectEqual(link("lyrimuse://action/lyrics-offset?ms=-300"), .setLyricsOffset(ms: -300), "时间轴绝对值")
        expectEqual(link("lyrimuse://action/lyrics-offset?ms=10000"), .setLyricsOffset(ms: 10_000), "时间轴绝对值: 上限本身认")
        expectEqual(link("lyrimuse://action/lyrics-offset?ms=10001") == nil && link("lyrimuse://action/lyrics-offset") == nil
                    && link("lyrimuse://action/lyrics-offset?ms=0.5") == nil, true, "时间轴绝对值: 超界、没带、不是整数都认不出")
        expectEqual(Set(LyrimuseDeepLink.extraActionNames).isDisjoint(with: LyrimuseAction.allCases.map(\.linkName)), true,
                    "action/ 下的额外名字跟快捷键动作不重名")

        // x-callback:本机 App 的回传地址收,网页 / 文件 / 脚本的不收(网页拿不到正在听什么)。
        let local = URL(string: "shortcuts://x-callback-url/ic-success?id=abc")!
        expectEqual(link("lyrimuse://x-callback-url/now-playing?x-success=\(local.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)"),
                    .nowPlayingCallback(success: local), "回传: 本机 App 的地址收")
        for bad in ["https://evil.example/steal", "http://x", "file:///tmp/x", "javascript:alert(1)"] {
            let encoded = bad.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            expectEqual(link("lyrimuse://x-callback-url/now-playing?x-success=\(encoded)"), .nowPlayingCallback(success: nil),
                        "回传: 不回给 \(bad)")
        }
        let reply = LyrimuseDeepLink.callbackURL(local, title: "爱爱爱", artist: "方大同", album: "", lyric: "I watched Godfather",
                                                 player: "Apple Music", playing: true)
        let items = reply.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        expectEqual(items.first { $0.name == "id" }?.value, "abc", "回传: 保留 x-success 自带的参数")
        expectEqual(items.first { $0.name == "title" }?.value, "爱爱爱", "回传: 歌名")
        expectEqual(items.first { $0.name == "playing" }?.value, "1", "回传: 在不在放")
        expectEqual(items.first { $0.name == "lyric" }?.value, "I watched Godfather", "回传: 当前这句")
    }

    // ---- 本机验证用的 debug/ 与 background=1 ----
    do {
        expectEqual(link("lyrimuse://debug/state"), .debug(.state), "debug: 状态快照")
        expectEqual(link("lyrimuse://debug/snapshot?window=Lyrics-Manager"), .debug(.snapshot(window: "lyrics-manager")),
                    "debug: 窗口快照,名字转小写")
        expectEqual(link("lyrimuse://debug/snapshot") == nil && link("lyrimuse://debug/nope") == nil, true,
                    "debug: 快照没给窗口名、认不出的命令返回 nil")
        expectEqual(link("lyrimuse://debug/checkpoint"), .debug(.checkpoint), "debug: 记下")
        expectEqual(link("lyrimuse://debug/restore"), .debug(.restore), "debug: 恢复")
        expectEqual(LyrimuseDeepLink.wantsBackground(URL(string: "lyrimuse://lyrics-manager?background=1")!), true, "后台开窗: 带了")
        expectEqual(LyrimuseDeepLink.wantsBackground(URL(string: "lyrimuse://lyrics-manager")!), false, "后台开窗: 没带")
        expectEqual(link("lyrimuse://lyrics-manager?background=1"), .lyricsManager, "后台开窗: 不影响认哪条链接")
        expectEqual(link("lyrimuse://debug/simulate?title=Orange%20Moon&artist=Khalil&album=Orange&duration=280&position=12.5"),
                    .debug(.simulate(title: "Orange Moon", artist: "Khalil", album: "Orange", duration: 280, position: 12.5,
                                     playing: true)), "模拟播放: 带全了")
        expectEqual(link("lyrimuse://debug/simulate?title=x&position=nan&duration=-3&playing=0"),
                    .debug(.simulate(title: "x", artist: "", album: "", duration: nil, position: 0, playing: false)),
                    "模拟播放: 位置、时长写坏了按没给")
        expectEqual(link("lyrimuse://debug/simulate?off=1"), .debug(.simulateOff), "模拟播放: 结束")
        expectEqual(link("lyrimuse://debug/simulate?artist=x"), nil, "模拟播放: 没给歌名认不出")

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ rel: String) -> String {
            (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
        }
        let debug = source("lyrimuse/Settings/DebugDeepLinks.swift")
        expectEqual(debug.contains("static let enabledKey = \"debug:deepLinks\"")
                    && debug.contains("guard isEnabled else {"), true,
                    "debug: 只在本机偏好 debug:deepLinks 打开时执行(网页改不了本机偏好)")
        expectEqual(debug.contains("enabledKey = \"np:"), false, "debug: 开关键不带 np: 前缀,导出配置不带走")
        // 开窗入口一律走 WindowActivation,background=1 时才能不抢焦点;漏一处那一处就照样抢。
        let scene = source("lyrimuse/MenuBar/MenuBarSceneActions.swift")
        expectEqual(scene.contains("NSApp.activate(ignoringOtherApps: true)"), false,
                    "后台开窗: 开窗入口不直接激活 App,走 WindowActivation.activateApp()")
        expectEqual(scene.components(separatedBy: "WindowActivation.activateApp()").count - 1 >= 6, true,
                    "后台开窗: 设置 / 歌词管理 / 歌词窗口两处 / 搜索小窗 / 引导六处入口")

        // 模拟播放:位置怎么走,以及对外的出口都挡住(引擎读播放状态打卡 Last.fm,控制会发给真实播放器)。
        let t0 = Date(timeIntervalSince1970: 1_000)
        let sim = PlaybackSimulation(title: "a", artist: "b", album: "", duration: 10, position: 8, playing: true, anchoredAt: t0)
        expectEqual(sim.elapsed(at: t0.addingTimeInterval(1)), 9, "模拟播放: 位置随时间走")
        expectEqual(sim.elapsed(at: t0.addingTimeInterval(5)), 10, "模拟播放: 放到头停在时长上")
        expectEqual(sim.isPlaying(at: t0.addingTimeInterval(5)), false, "模拟播放: 放到头算停了")
        expectEqual(sim.snapshot(at: t0).bundleIdentifier, PlaybackSimulation.bundleIdentifier, "模拟播放: 快照带模拟的 bundle id")
        expectEqual(PlaybackPlayer.builtin(forBundleID: PlaybackSimulation.bundleIdentifier) == nil, true,
                    "模拟播放: bundle id 不是任何内置播放器,按播放器分的规则不认它")
        expectEqual(PlaybackSimulation.togglePlaying(now: t0), false, "模拟播放: 没在模拟时不接管播放 / 暂停")
        PlaybackSimulation.begin(sim)
        PlaybackSimulation.togglePlaying(now: t0.addingTimeInterval(1))
        expectEqual(PlaybackSimulation.current?.playing == false && PlaybackSimulation.current?.position == 9, true,
                    "模拟播放: 暂停停在此刻的位置")
        PlaybackSimulation.seek(toSeconds: 3, now: t0.addingTimeInterval(2))
        expectEqual(PlaybackSimulation.current?.elapsed(at: t0.addingTimeInterval(9)), 3, "模拟播放: 暂停中跳转")
        expectEqual(PlaybackSimulation.suppressesTrackChange(now: t0), true, "模拟播放: 模拟中不发换歌通知")
        PlaybackSimulation.end(now: t0.addingTimeInterval(2))
        expectEqual(PlaybackSimulation.isActive, false, "模拟播放: 结束")
        expectEqual(PlaybackSimulation.suppressesTrackChange(now: t0.addingTimeInterval(5)), true,
                    "模拟播放: 刚结束换回真实曲目不算换歌")
        expectEqual(PlaybackSimulation.suppressesTrackChange(now: t0.addingTimeInterval(2 + PlaybackSimulation.endGrace + 1)), false,
                    "模拟播放: 过了收尾那一段照常")
        let lps = source("LyrimuseCore/Local/LocalPlaybackSource.swift")
        let publish = lps.components(separatedBy: "private func publishPlaybackState(").dropFirst().first ?? ""
        expectEqual(publish.prefix(400).contains("guard !PlaybackSimulation.isActive else { return }"), true,
                    "模拟播放: 不写给引擎的播放状态(引擎据此打卡 Last.fm)")
        expectEqual(lps.contains("bid != lastPersistedPlayerBundleID, !PlaybackSimulation.isActive")
                    && lps.contains("newTitle != lastPersistedTrackTitle,\n           !PlaybackSimulation.isActive"), true,
                    "模拟播放: 不落「上次在听」")
        expectEqual(lps.contains("if let simulated = PlaybackSimulation.current {")
                    && lps.contains("if PlaybackSimulation.seek(toSeconds: seconds) {"), true,
                    "模拟播放: 轮询不读播放器、跳转不发给播放器")
        let control = source("LyrimuseCore/Local/MusicPlaybackController.swift")
        expectEqual(control.contains("if PlaybackSimulation.togglePlaying() {")
                    && control.components(separatedBy: "guard !PlaybackSimulation.isActive else {").count - 1 >= 3, true,
                    "模拟播放: 播放 / 暂停、上一首、下一首、跳转都不发给真实播放器")
        expectEqual(source("lyrimuse/Settings/DiscordPresenceController.swift")
                        .contains("guard !PlaybackSimulation.isActive else { return }"), true, "模拟播放: Discord 状态不变")
        expectEqual(source("lyrimuse/Settings/NowPlayingNotifier.swift")
                        .contains("guard !PlaybackSimulation.suppressesTrackChange() else { return }"), true, "模拟播放: 不发换歌通知")
    }

    // ---- 往返:生成的链接再解析回来是同一个值 ----
    do {
        let all: [LyrimuseDeepLink] = [
            .settings(path: "/lyrics/manage", checkForUpdates: false), .settings(path: "/software-update", checkForUpdates: true),
            .lyricsManager, .lyricsManagerSongVersions(key: nil, showEvidence: false),
            .lyricsManagerSongVersions(key: "方大同|为妳写的歌|橙月", showEvidence: false),
            .lyricsManagerSongVersions(key: "daniel caesar & mustafa|never enough|toronto 2014", showEvidence: false),
            .lyricsManagerSongVersions(key: "方大同|为妳写的歌|橙月", showEvidence: true), .lyricsManagerSongVersions(key: nil, showEvidence: true),
            .lyricsWindow, .lyricsWindowSearch, .lyricsSearch,
            .menuBarPanel(quick: nil), .menuBarPanel(quick: "overlay"), .onboarding, .lastfmAuthCallback,
            .action(.toggleOverlay, on: true, stepSeconds: nil), .action(.lyricsAdvanceHotkey, on: nil, stepSeconds: 0.5),
            .copyLyric(includeTranslation: true), .copyLyric(includeTranslation: false), .openPlayer,
            .setSurfaces(overlay: true, notch: false, menuBar: nil), .setLyricsOffset(ms: -300),
            .nowPlayingCallback(success: URL(string: "shortcuts://x-callback-url/ic-success")),
            .debug(.state), .debug(.checkpoint), .debug(.restore), .debug(.snapshot(window: "panel")),
            .debug(.simulate(title: "Orange Moon", artist: "Khalil", album: "", duration: 280, position: 12.5, playing: false)),
            .debug(.simulate(title: "x", artist: "y", album: "z", duration: nil, position: 0, playing: true)), .debug(.simulateOff),
        ] + LyrimuseAction.allCases.map { .action($0, on: nil, stepSeconds: nil) }
        for value in all {
            let url = value.url(scheme: scheme)
            expectEqual(url.flatMap { LyrimuseDeepLink(url: $0, scheme: scheme) }, value,
                        "深链往返: \(url?.absoluteString ?? "nil")")
        }
    }

    // ---- 设置二级分段 ----
    do {
        typealias S = SettingsDeepLink
        expectEqual(S.section(in: "/lyrics/manage"), .init(storageKey: SettingsSearchCatalog.lyricsSectionKey, value: "manage"),
                    "设置分段: 歌词 › 管理")
        expectEqual(S.section(in: "/appearance/menu-bar"), .init(storageKey: LyricsSurface.appearanceSectionStorageKey, value: "menuBar"),
                    "设置分段: 连字符写法换成 rawValue")
        expectEqual(S.section(in: "/account/lastfm/on-this-day"), .init(storageKey: SettingsSearchCatalog.lastfmSectionKey, value: "onThisDay"),
                    "设置分段: 账号页分段")
        expectEqual(S.section(in: "/lyrics"), nil, "设置分段: 没带分段")
        expectEqual(S.section(in: "/lyrics/nope"), nil, "设置分段: 认不出的分段")
        expectEqual(S.pagePath(of: "/lyrics/manage"), "/lyrics", "设置分段: 去掉分段剩下那一页")
        expectEqual(S.pagePath(of: "/account/discord/privacy"), "/account/discord", "设置分段: 账号页去掉分段")
        expectEqual(S.pagePath(of: "/lyrics/nope"), "/lyrics/nope", "设置分段: 认不出的分段不去掉(只叫出设置窗口)")
        expectEqual(S(path: S.pagePath(of: "/appearance/notch")), .tab("appearance"), "设置分段: 去掉分段后认得出那一页")

        // 表里存的值必须是 App 里各 Section 枚举真有的 rawValue:对不上的话链接翻过去落在一个不存在的分段上。
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ rel: String) -> String {
            (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
        }
        let settingsView = source("lyrimuse/SettingsView.swift")
        let accounts = source("lyrimuse/AccountLinkingTab.swift")
        let declared: [String: Bool] = [
            "lyrics": settingsView.contains("case fetch, translation, display, manage"),
            "player": settingsView.contains("case players, linkage, permissions"),
            "appearance": settingsView.contains("case overlay, notch, menuBar, touchBar, lyricsWindow"),
            "account/lastfm": accounts.contains("case stats, chart, onThisDay") && accounts.contains("        case settings\n"),
            "account/discord": accounts.contains("case display, buttons, privacy"),
        ]
        expectEqual(Set(S.sectionTable.keys), Set(declared.keys), "设置分段: 有分段的就这五页")
        for (page, ok) in declared.sorted(by: { $0.key < $1.key }) {
            expectEqual(ok, true, "设置分段: \(page) 的取值跟 App 枚举对得上(枚举改了这张表要跟着改)")
        }
    }

    // ---- App 侧接线:只有一处分派,认不出的不落进授权回调 ----
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ rel: String) -> String {
            (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
        }
        let delegate = source("lyrimuse/AppDelegate.swift")
        let router = source("lyrimuse/Settings/DeepLinkRouter.swift")
        let statusItem = source("lyrimuse/MenuBar/MenuBarStatusItem.swift")
        let manager = source("lyrimuse/LyricsManager/LyricsManagerView.swift")
        expectEqual(router.contains("case let .lyricsManagerSongVersions(key, showEvidence):\n            AppActions.shared.openLyricsManager?()\n            AppActions.shared.requestSongVersions(key: key, showEvidence: showEvidence)")
                    && manager.contains(".onReceive(AppActions.shared.songVersionsRequests) { if !pendingAutoFocus { consumeSongVersionsRequest() } }")
                    && manager.contains("guard pendingAutoFocus else {\n                    consumeSongVersionsRequest()")
                    && manager.contains("DispatchQueue.main.async { windowFrame.focusList() }\n                // 链接带的条目排在自动定位之后")
                    && manager.contains("guard showSongVersions || !windowFrame.hasAttachedSheet,")
                    && manager.contains("Date().timeIntervalSince(request.at) < 60, let key = request.key ?? singleSelectedKey,")
                    && manager.contains("store.songMembership(forKey: key) != nil, select(key) else { return }"), true,
                    "深链接线: 同曲条目面板在开窗那一轮读完缓存、自动定位之后才取,条件同「⋯」里那一项,有没保存的修改先问,开着别的面板不动,信箱只认 60 秒内的请求")
        let sheet = source("lyrimuse/LyricsManager/SongVersionsSheet.swift")
        expectEqual(manager.contains("songVersionsShowEvidence = request.showEvidence\n        showSongVersions = true")
                    && manager.contains(".sheet(isPresented: $showSongVersions, onDismiss: { songVersionsShowEvidence = false }) {")
                    && manager.contains("onOpen: { other in _ = select(other) }, showEvidence: songVersionsShowEvidence)")
                    && sheet.contains(".onChange(of: \"\\(summary.key)#\\(showEvidence)\", initial: true) { _, _ in if showEvidence { evidenceExpanded = true } }"), true,
                    "深链接线: evidence=1 打开同曲条目就展开匹配依据,开着时换一首也展开;面板关掉后手点打开照旧收着")
        expectEqual(statusItem.contains("if quick != nil, panelIsOpen { panelController.close() }"), true,
                    "深链接线: 面板带 quick 时开着也不关,翻到那一格")
        expectEqual(router.contains("guard let success else {") && router.contains("NSWorkspace.shared.open(url)"), true,
                    "深链接线: x-callback 只往解析层放行的地址回传")
        expectEqual(delegate.contains("DeepLinkRouter.handle(url)") && !delegate.contains("handleAuthCallback()"), true,
                    "深链接线: AppDelegate 只交给 DeepLinkRouter,不再兜底调授权回调")
        expectEqual(router.contains("let logged = (url.host ?? \"\") + url.path") && !router.contains("url.absoluteString"), true,
                    "深链接线: 日志不记查询参数(Last.fm 回跳带 token,导出诊断会带走 App 日志)")
        expectEqual(router.contains("case .lastfmAuthCallback:\n            LastfmConnectController.shared.handleAuthCallback()")
                    && router.contains("GlobalHotkeys.flashHint(icon: \"link\", text: L10n.t(\"无法识别的链接\"))"), true,
                    "深链接线: 授权回调只认自己那个 host,认不出的闪一句")
    }
}
