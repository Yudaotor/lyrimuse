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
        expectEqual(link("lyrimuse://lyrics-manager/song-versions?key=a%7Cb%7C&compare=a%7Cb%7Cc"),
                    .lyricsManagerSongVersions(key: "a|b|", showEvidence: false, compare: "a|b|c"), "深链: 同曲条目面板带 compare 选中那一条的对照")
        expectEqual(link("lyrimuse://lyrics-manager/song-versions?compare="), .lyricsManagerSongVersions(key: nil, showEvidence: false),
                    "深链: 空的 compare 当没带")
        expectEqual(link("lyrimuse://lyrics-search"), .lyricsSearch, "深链: 搜索歌词小窗")
        expectEqual(link("lyrimuse://lyrics-share"), .lyricsShare, "深链: 分享歌词窗口")
        expectEqual(link("lyrimuse://whats-new"), .whatsNew, "深链: 本次更新卡片")
        expectEqual(link("lyrimuse://lyrics-window/search"), .lyricsWindowSearch, "深链: 歌词窗口搜索面板")
        expectEqual(link("lyrimuse://menubar-panel"), .menuBarPanel(quick: nil), "深链: 菜单栏面板")
        expectEqual(link("lyrimuse://menubar-panel?quick=Lyrics-Manager"), .menuBarPanel(quick: "lyrics-manager"),
                    "深链: 面板 quick 取值转小写")
        expectEqual(link("lyrimuse://menubar-menu"), .menuBarMenu, "深链: 菜单栏右键菜单")
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
        expectEqual(sourceBytes(hotkeys, contain: "static let allLyrimuseNames: [Self] = LyrimuseAction.allCases.map { Self($0) }")
                    && sourceHas(hotkeys, "init(_ action: LyrimuseAction) {\n        self.init(action.rawValue)"), true,
                    "动作: 快捷键名单和名字从 LyrimuseAction 派生")
        expectEqual(hotkeys.contains("= Self(\""), false, "动作: App 里不再逐个声明快捷键名(名单只有 LyrimuseAction 一份)")
        // 快捷键页的格子、撞键提示、设置搜索都按 LyrimuseAction 的排布和名字来:漏摆一格就是录不了,名字重了撞键提示分不清。
        let laidOut = LyrimuseAction.shortcutLayout.flatMap(\.actions)
        expectEqual(laidOut.count == LyrimuseAction.allCases.count && Set(laidOut) == Set(LyrimuseAction.allCases), true,
                    "快捷键页: 每个动作正好摆一格")
        expectEqual(LyrimuseAction.shortcutLayout.map(\.group), LyrimuseAction.ShortcutGroup.allCases, "快捷键页: 四张卡各一次、顺序同枚举")
        expectEqual(Set(LyrimuseAction.allCases.map(\.titleKey)).count, LyrimuseAction.allCases.count, "快捷键页: 名字不重复")
        expectEqual(LyrimuseAction.allCases.filter { $0.iconName.isEmpty || $0.searchKeywords.isEmpty }, [],
                    "快捷键页: 每个动作都有图标和搜索关键词")
        expectEqual(LyrimuseAction.allCases.filter { action in
                        !SettingsSearchCatalog.entries.contains { $0.titleKey == action.titleKey && $0.destination == .tab("shortcuts") }
                    }, [], "快捷键页: 每个动作在设置搜索里都有一条,落在「快捷键」页")
        expectEqual(link("lyrimuse://action/toggle-all-lyrics?on=0"), .action(.toggleAllLyricsHotkey, on: false, stepSeconds: nil),
                    "动作: 隐藏 / 恢复全部歌词带目标状态")
        expectEqual(link("lyrimuse://action/toggle-favorite?on=1"), .action(.toggleFavoriteHotkey, on: true, stepSeconds: nil),
                    "动作: 喜欢带目标状态")
        expectEqual(sourceHas(hotkeys, "KeyboardShortcuts.onKeyUp(for: KeyboardShortcuts.Name(action.rawValue)) {\n                LyrimuseActionRunner.perform(action)")
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
        expectEqual(link("lyrimuse://action/open-player"), .action(.openPlayerHotkey, on: nil, stepSeconds: nil),
                    "回到播放器: 链接写法不变,并进了快捷键动作")
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

        // x-callback:网页 / 文件 / 脚本的回传地址解析时就不收;别的 scheme 回传前看本机由谁来开,浏览器开的不回。
        let local = URL(string: "shortcuts://x-callback-url/ic-success?id=abc")!
        expectEqual(link("lyrimuse://x-callback-url/now-playing?x-success=\(local.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)"),
                    .nowPlayingCallback(success: local), "回传: 本机 App 的地址收")
        for bad in ["https://evil.example/steal", "HTTP://x", "file:///tmp/x", "javascript:alert(1)", "data:text/html,x",
                    "lyrimuse://x-callback-url/now-playing"] {
            let encoded = bad.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            expectEqual(link("lyrimuse://x-callback-url/now-playing?x-success=\(encoded)"), .nowPlayingCallback(success: nil),
                        "回传: 解析时不收 \(bad)")
        }
        let shortcutsApp = URL(fileURLWithPath: "/System/Applications/Shortcuts.app")
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        let browsers: Set<URL> = [safari, URL(fileURLWithPath: "/Applications/Google Chrome.app")]
        expectEqual(LyrimuseDeepLink.isCallbackTarget(local, handler: shortcutsApp, browsers: browsers), true,
                    "回传: 本机非浏览器 App 开的地址回传(不用登记名单)")
        expectEqual(LyrimuseDeepLink.isCallbackTarget(URL(string: "x-safari-https://evil.example")!, handler: safari,
                                                      browsers: browsers), false,
                    "回传: 浏览器自己的 scheme 不回(会被转成网页打开)")
        expectEqual(LyrimuseDeepLink.isCallbackTarget(URL(string: "someapp://forward?u=x")!, handler: nil, browsers: browsers),
                    false, "回传: 本机没有 App 开得了的不回")
        expectEqual(LyrimuseDeepLink.isCallbackTarget(URL(string: "https://evil.example")!, handler: shortcutsApp,
                                                      browsers: []), false, "回传: 网页地址就算有人开也不回")
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
        expectEqual(link("lyrimuse://debug/telemetry-preview"), .debug(.telemetryPreview), "debug: 遥测心跳预览")
        expectEqual(link("lyrimuse://debug/app-move"), .debug(.appMove(source: nil, destination: nil, answer: nil)), "debug: 移到应用程序文件夹那一问")
        expectEqual(link("lyrimuse://debug/app-move?source=/Volumes/Lyrimuse/Lyrimuse.app&dest=/tmp/a%20b&answer=move"),
                    .debug(.appMove(source: "/Volumes/Lyrimuse/Lyrimuse.app", destination: "/tmp/a b", answer: true)), "debug: app-move 带来源、目标、直接移动")
        expectEqual(link("lyrimuse://debug/app-move?answer=decline"), .debug(.appMove(source: nil, destination: nil, answer: false)), "debug: app-move 直接选不了")
        expectEqual(link("lyrimuse://debug/app-move?answer=maybe"), nil, "debug: app-move 认不出的 answer 整条不认")
        expectEqual(link("lyrimuse://debug/diagnostics"), .debug(.diagnostics), "debug: 不弹面板导出诊断包")
        expectEqual(link("lyrimuse://debug/drag-region?window=Lyrics-Window"), .debug(.dragRegion(window: "lyrics-window")),
                    "debug: 拖窗区")
        expectEqual(link("lyrimuse://debug/drag-region"), nil, "debug: 拖窗区不带窗口名认不出")
        expectEqual(link("lyrimuse://debug/snapshot?window=Lyrics-Manager"), .debug(.snapshot(window: "lyrics-manager")),
                    "debug: 窗口快照,名字转小写")
        expectEqual(link("lyrimuse://debug/snapshot") == nil && link("lyrimuse://debug/nope") == nil, true,
                    "debug: 快照没给窗口名、认不出的命令返回 nil")
        expectEqual(link("lyrimuse://debug/checkpoint"), .debug(.checkpoint), "debug: 记下")
        expectEqual(link("lyrimuse://debug/restore"), .debug(.restore), "debug: 恢复")
        expectEqual(link("lyrimuse://debug/config-save"), .debug(.saveConfig), "debug: 账号配置原样保存一次")
        expectEqual(link("lyrimuse://debug/release-closed-windows"), .debug(.releaseClosedWindows), "debug: 当作锁屏,拆掉关着的窗口内容")
        expectEqual(link("lyrimuse://debug/panel-layout"), .debug(.panelLayout(json: nil)), "debug: 面板布局不带 json 恢复默认")
        expectEqual(link("lyrimuse://debug/panel-pin?on=1"), .debug(.panelPin(on: true)), "debug: 面板不自动收起")
        expectEqual(link("lyrimuse://debug/panel-pin") == nil, true, "debug: 面板钉住没给 on 不认")
        expectEqual(link("lyrimuse://debug/panel-drag?from=205,436&to=350.5,436"),
                    .debug(.panelDrag(from: CGPoint(x: 205, y: 436), to: CGPoint(x: 350.5, y: 436))), "debug: 面板里拖一下")
        expectEqual(link("lyrimuse://debug/panel-drag?from=1,2&to=3,4&via=5,6;7,8"),
                    .debug(.panelDrag(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 3, y: 4), via: [CGPoint(x: 5, y: 6), CGPoint(x: 7, y: 8)])),
                    "debug: 按住先经过几个点再到终点")
        expectEqual(link("lyrimuse://debug/panel-drag?from=1,2&to=3,4&via=5,6;7"), nil, "debug: 途经点写错整条不认")
        expectEqual(link("lyrimuse://debug/panel-drag?from=1,2&to=3,4&in=gallery"),
                    .debug(.panelDrag(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 3, y: 4), inGallery: true)), "debug: 按在「可添加」面板上拖")
        expectEqual(link("lyrimuse://debug/panel-click?at=60,208.5"), .debug(.panelClick(at: CGPoint(x: 60, y: 208.5))),
                    "debug: 面板里点一下")
        expectEqual(link("lyrimuse://debug/panel-click?at=1,2&in=gallery"), .debug(.panelClick(at: CGPoint(x: 1, y: 2), inGallery: true)),
                    "debug: 在「可添加」面板上点一下")
        expectEqual(link("lyrimuse://debug/panel-scroll?at=60,208&dy=1"),
                    .debug(.panelScroll(at: CGPoint(x: 60, y: 208), dy: 1)), "debug: 面板里滚轮往上一格")
        expectEqual(link("lyrimuse://debug/panel-scroll?at=60,208&dy=-4.5&kind=trackpad&steps=12"),
                    .debug(.panelScroll(at: CGPoint(x: 60, y: 208), dy: -4.5, trackpad: true, steps: 12)), "debug: 面板里触控板往下滑")
        expectEqual(link("lyrimuse://debug/panel-scroll?at=1,2&dy=1&kind=wheel&steps=3"),
                    .debug(.panelScroll(at: CGPoint(x: 1, y: 2), dy: 1, steps: 3)), "debug: kind=wheel 同不带")
        expectEqual(["lyrimuse://debug/panel-scroll?dy=1", "lyrimuse://debug/panel-scroll?at=1,2", "lyrimuse://debug/panel-scroll?at=1,2&dy=0",
                     "lyrimuse://debug/panel-scroll?at=1,2&dy=abc", "lyrimuse://debug/panel-scroll?at=1,2&dy=201",
                     "lyrimuse://debug/panel-scroll?at=1,2&dy=1&kind=pinch", "lyrimuse://debug/panel-scroll?at=1,2&dy=1&steps=0",
                     "lyrimuse://debug/panel-scroll?at=1,2&dy=1&steps=61", "lyrimuse://debug/panel-scroll?at=1,2&dy=1&steps=x"]
                        .allSatisfy { link($0) == nil }, true,
                    "debug: 面板滚动缺位置或位移、位移为 0 或超上限、kind 不认得、步数越界都不认")
        expectEqual(link("lyrimuse://debug/panel-click") == nil && link("lyrimuse://debug/panel-click?at=1") == nil, true,
                    "debug: 点的位置缺了或写错不认")
        expectEqual(link("lyrimuse://debug/window-click?window=lyrics-window&at=210,640.5"),
                    .debug(.windowClick(window: "lyrics-window", at: CGPoint(x: 210, y: 640.5))), "debug: 在某扇窗里点一下")
        expectEqual(["lyrimuse://debug/window-click?at=1,2", "lyrimuse://debug/window-click?window=&at=1,2",
                     "lyrimuse://debug/window-click?window=lyrics-window", "lyrimuse://debug/window-click?window=lyrics-window&at=1"]
                        .allSatisfy { link($0) == nil }, true,
                    "debug: 窗口点按缺窗口名、缺位置或位置写错不认")
        expectEqual([link("lyrimuse://debug/window-key?window=lyrics-search&key=down"),
                     link("lyrimuse://debug/window-key?window=lyrics-search&key=r&cmd=1")],
                    [.debug(.windowKey(window: "lyrics-search", key: "down", command: false)),
                     .debug(.windowKey(window: "lyrics-search", key: "r", command: true))], "debug: 往某扇窗送一次按键,cmd=1 按住 ⌘")
        expectEqual(["lyrimuse://debug/window-key?key=down", "lyrimuse://debug/window-key?window=&key=down",
                     "lyrimuse://debug/window-key?window=lyrics-search", "lyrimuse://debug/window-key?window=lyrics-search&key=R",
                     "lyrimuse://debug/window-key?window=lyrics-search&key=pageup", "lyrimuse://debug/window-key?window=lyrics-search&key=ab"]
                        .allSatisfy { link($0) == nil }, true,
                    "debug: 窗口按键缺窗口名、缺键、键不认得(大写、没有的键名、两个字母)不认")
        expectEqual(link("lyrimuse://debug/panel-drag?from=1,2") == nil && link("lyrimuse://debug/panel-drag?from=1&to=3,4") == nil, true,
                    "debug: 面板拖动缺终点或坐标不全不认")
        expectEqual(link("lyrimuse://debug/panel-layout?json=%7B%22tiles%22%3A%5B%5D%7D"), .debug(.panelLayout(json: "{\"tiles\":[]}")),
                    "debug: 面板布局带 json")
        expectEqual(link("lyrimuse://debug/stall?ms=120"), .debug(.stall(ms: 120)), "debug: 主线程睡一段")
        expectEqual(link("lyrimuse://debug/stall") == nil && link("lyrimuse://debug/stall?ms=0") == nil
                    && link("lyrimuse://debug/stall?ms=2001") == nil, true, "debug: 睡多久没给、0、超上限都不认")
        expectEqual(link("lyrimuse://debug/knockout?leg=vox-script&on=0"), .debug(.knockout(leg: .voxScript, on: false)),
                    "debug: 关掉一条来源")
        expectEqual(link("lyrimuse://debug/knockout?leg=Stream-Events&on=1"), .debug(.knockout(leg: .streamEvents, on: true)),
                    "debug: 接回一条来源,名字大小写不敏感")
        expectEqual(link("lyrimuse://debug/knockout?leg=nope&on=0") == nil && link("lyrimuse://debug/knockout?leg=vox-script") == nil,
                    true, "debug: 认不出的来源、没带 on 都不认")
        expectEqual(link("lyrimuse://debug/menubar-center?center=1&ignore-notch=1"),
                    .debug(.menuBarCenter(center: true, ignoreNotch: true)), "debug: 菜单栏歌词放正中并忽略刘海")
        expectEqual(link("lyrimuse://debug/menubar-center?ignore-notch=0"), .debug(.menuBarCenter(center: nil, ignoreNotch: false)),
                    "debug: 只改忽略刘海")
        expectEqual(link("lyrimuse://debug/menubar-center"), nil, "debug: 菜单栏正中什么都没带不认")
        expectEqual(link("lyrimuse://debug/menubar-center?hover=1&click=Right"),
                    .debug(.menuBarCenter(center: nil, ignoreNotch: nil, hover: true, click: "right")),
                    "debug: 当作指针停在正中、右键点一下")
        expectEqual(link("lyrimuse://debug/menubar-center?click=middle"), nil, "debug: 认不出的点法不认")
        expectEqual(link("lyrimuse://debug/menubar-display?artwork=1"),
                    .debug(.menuBarDisplay(artwork: true, content: nil)), "debug: 菜单栏图标用封面")
        expectEqual(link("lyrimuse://debug/menubar-display?content=titleArtist&artwork=0"),
                    .debug(.menuBarDisplay(artwork: false, content: "titleArtist")), "debug: 菜单栏显示歌名和歌手、图标不用封面")
        expectEqual(link("lyrimuse://debug/menubar-display?icon-size=large"),
                    .debug(.menuBarDisplay(artwork: nil, content: nil, iconSize: "large")), "debug: 只改菜单栏图标大小")
        expectEqual(link("lyrimuse://debug/menubar-display?icon-style=vinyl"),
                    .debug(.menuBarDisplay(artwork: nil, content: nil, iconStyle: "vinyl")), "debug: 只改菜单栏图标款式")
        expectEqual(link("lyrimuse://debug/menubar-display?hover-controls=1"),
                    .debug(.menuBarDisplay(artwork: nil, content: nil, hoverControls: true)), "debug: 只开悬停显示播放控制")
        expectEqual(link("lyrimuse://debug/menubar-display?secondary=translationInline"),
                    .debug(.menuBarDisplay(artwork: nil, content: nil, secondary: "translationInline")),
                    "debug: 只改菜单栏副行")
        expectEqual(link("lyrimuse://debug/menubar-display?alignment=trailing"),
                    .debug(.menuBarDisplay(artwork: nil, content: nil, alignment: "trailing")), "debug: 只改菜单栏对齐方式")
        expectEqual(link("lyrimuse://debug/menubar-display?icon-animates=0"),
                    .debug(.menuBarDisplay(artwork: nil, content: nil, iconAnimates: false)), "debug: 只关图标动画")
        expectEqual(link("lyrimuse://debug/menubar-display?keep-paused=1"),
                    .debug(.menuBarDisplay(artwork: nil, content: nil, keepsLyricsWhenPaused: true)),
                    "debug: 只开暂停时保留歌词")
        expectEqual(link("lyrimuse://debug/menubar-display"), nil, "debug: 菜单栏显示什么都没带不认")
        expectEqual(link("lyrimuse://debug/notch-behavior?hide-when-not-playing=1"),
                    .debug(.notchBehavior(collapseWhenPaused: nil, hideWhenNotPlaying: true)), "debug: 只开灵动岛暂停时隐藏")
        expectEqual(link("lyrimuse://debug/notch-behavior"), nil, "debug: 灵动岛行为什么都没带不认")
        expectEqual(link("lyrimuse://debug/notch-pass-through?x=200&y=50.5"), .debug(.notchPassThrough(x: 200, y: 50.5)),
                    "debug: 灵动岛模拟指针停在卡片一点上")
        expectEqual(link("lyrimuse://debug/notch-behavior?show-lyrics=0"),
                    .debug(.notchBehavior(collapseWhenPaused: nil, hideWhenNotPlaying: nil, showLyrics: false)),
                    "debug: 只关灵动岛显示歌词")
        expectEqual(link("lyrimuse://debug/notch-behavior?lyric-row-fade=1"),
                    .debug(.notchBehavior(collapseWhenPaused: nil, hideWhenNotPlaying: nil, lyricRowFade: true)),
                    "debug: 只开灵动岛悬浮淡化")
        expectEqual(link("lyrimuse://debug/notch-pass-through?off=1"), .debug(.notchPassThroughOff), "debug: 灵动岛结束模拟指针")
        expectEqual(link("lyrimuse://debug/notch-pass-through?x=200"), nil, "debug: 灵动岛模拟指针缺 y 不认")
        expectEqual(link("lyrimuse://debug/notch-pointer?x=200&y=20"), .debug(.notchPointer(x: 200, y: 20)),
                    "debug: 灵动岛一直当作指针停在卡片一点上")
        expectEqual(link("lyrimuse://debug/notch-pointer?y=20"), nil, "debug: 灵动岛常驻模拟指针缺 x 不认")
        expectEqual(link("lyrimuse://debug/notch-hover?path=-150,10;40.5,12"),
                    .debug(.notchHover(path: [CGPoint(x: -150, y: 10), CGPoint(x: 40.5, y: 12)], stepSecs: 0.03)),
                    "debug: 灵动岛模拟指针走一串点,步长缺省")
        expectEqual(link("lyrimuse://debug/notch-hover?path=0,10&step=0.1"),
                    .debug(.notchHover(path: [CGPoint(x: 0, y: 10)], stepSecs: 0.1)), "debug: 灵动岛模拟指针带步长")
        expectEqual(link("lyrimuse://debug/notch-hover?off=1"), .debug(.notchHoverOff), "debug: 灵动岛结束模拟悬停")
        expectEqual(link("lyrimuse://debug/notch-hover?path=0,10;5"), nil, "debug: 灵动岛模拟悬停有一点缺 y 不认")
        expectEqual(link("lyrimuse://debug/notch-hover?path=0,nan"), nil, "debug: 灵动岛模拟悬停不是有限数不认")
        expectEqual(link("lyrimuse://debug/notch-hover?path=0,10&step=5"), nil, "debug: 灵动岛模拟悬停步长超范围不认")
        expectEqual(link("lyrimuse://debug/notch-hover"), nil, "debug: 灵动岛模拟悬停没有路径不认")
        expectEqual(link("lyrimuse://debug/notch-hint?key=gearshape.fill"), .debug(.notchHint(key: "gearshape.fill")),
                    "debug: 灵动岛当作指针停在这颗快捷键上")
        expectEqual(link("lyrimuse://debug/notch-hint"), .debug(.notchHint(key: nil)), "debug: 灵动岛收起快捷键说明")
        expectEqual(link("lyrimuse://debug/notch-behavior?progress-line=Ears"),
                    .debug(.notchBehavior(collapseWhenPaused: nil, hideWhenNotPlaying: nil, progressLine: .ears)),
                    "debug: 灵动岛进度线只带样式")
        expectEqual(link("lyrimuse://debug/notch-behavior?progress-line=side"), nil, "debug: 灵动岛进度线认不出的档不认")
        expectEqual(link("lyrimuse://debug/notch-behavior?all-screens=1"),
                    .debug(.notchBehavior(collapseWhenPaused: nil, hideWhenNotPlaying: nil, allScreens: true)),
                    "debug: 灵动岛只开所有屏幕")
        expectEqual(link("lyrimuse://debug/menubar-center?screen=auto"),
                    .debug(.menuBarCenter(center: nil, ignoreNotch: nil, screen: "auto")), "debug: 只改正中放哪几块屏")
        expectEqual(link("lyrimuse://debug/notch-style?expanded=solidBlack"),
                    .debug(.notchStyle(style: nil, expanded: "solidBlack")), "debug: 只改灵动岛展开背景")
        expectEqual(link("lyrimuse://debug/notch-style?style=coverArt&expanded=same"),
                    .debug(.notchStyle(style: "coverArt", expanded: "same")), "debug: 背景、展开背景一起设")
        expectEqual(link("lyrimuse://debug/notch-style"), nil, "debug: 灵动岛风格什么都没带不认")
        expectEqual(link("lyrimuse://debug/notch-lyric-list?on=1&lines=7&secondary=translation"),
                    .debug(.notchLyricList(on: true, lines: 7, secondary: .translation)), "debug: 多行歌词开关、行数、副行一起设")
        expectEqual(link("lyrimuse://debug/notch-lyric-list?secondary=off"),
                    .debug(.notchLyricList(on: nil, lines: nil, secondary: .off)), "debug: 只改灵动岛副行")
        expectEqual(link("lyrimuse://debug/notch-lyric-list?secondary=bilingual"), nil, "debug: 认不出的副行不认")
        expectEqual(link("lyrimuse://debug/notch-lyric-list"), nil, "debug: 多行歌词什么都没带不认")
        expectEqual(link("lyrimuse://debug/notch-quick-actions?layout=close,,settings%7Cfavorite"),
                    .debug(.notchQuickActions(layout: "close,,settings|favorite")), "debug: 灵动岛快捷操作格子")
        expectEqual(link("lyrimuse://debug/notch-quick-actions"), nil, "debug: 快捷操作排法没带 layout 不认")
        expectEqual(link("lyrimuse://debug/notch-preview?state=expanded"),
                    .debug(.notchPreview(state: "expanded")), "debug: 设置页灵动岛预览钉在展开态")
        expectEqual(link("lyrimuse://debug/notch-preview?state=open"), nil, "debug: 预览状态只认 expanded / collapsed / auto")
        expectEqual(link("lyrimuse://debug/labs-writeback?auto=1&overwrite=0"),
                    .debug(.labsWriteback(auto: true, overwrite: false)), "debug: 实验室自动写入和覆盖子开关一起设")
        expectEqual(link("lyrimuse://debug/labs-writeback?overwrite=on"),
                    .debug(.labsWriteback(auto: nil, overwrite: true)), "debug: 只设覆盖子开关")
        expectEqual(link("lyrimuse://debug/labs-writeback?auto=maybe"), nil, "debug: 实验室写回开关什么都没认出来不认")
        expectEqual(link("lyrimuse://debug/word-format-switch?state=converting&format=qrc&done=30&total=100"),
                    .debug(.wordFormatSwitch(state: "converting", format: "qrc", done: 30, total: 100)), "debug: 逐字格式切换摆到改存中")
        expectEqual(link("lyrimuse://debug/word-format-switch?state=backup&done=-3"),
                    .debug(.wordFormatSwitch(state: "backup", format: nil, done: nil, total: nil)), "debug: 负数、缺的参数按没带")
        expectEqual(link("lyrimuse://debug/word-format-switch?state=finished&remove=yrc,qrc"),
                    .debug(.wordFormatSwitch(state: "finished", format: nil, done: nil, total: nil, removing: ["yrc", "qrc"])),
                    "debug: 逐字格式切换摆成删副本那一趟")
        expectEqual(link("lyrimuse://debug/word-format-switch"), nil, "debug: 逐字格式切换不带 state 不认")
        expectEqual(link("lyrimuse://debug/move-window?title=%E6%90%9C%E7%B4%A2&x=-200&y=-1200.5"),
                    .debug(.moveWindow(title: "搜索", x: -200, y: -1200.5)), "debug: 按标题挪窗口")
        expectEqual(link("lyrimuse://debug/move-window?title=a&x=1") == nil
                    && link("lyrimuse://debug/move-window?x=1&y=2") == nil, true, "debug: 挪窗口缺标题或坐标不认")
        expectEqual(link("lyrimuse://debug/overlay-layout?width=1270&line-change=0"),
                    .debug(.overlayLayout(width: 1270, lineChange: false)), "debug: 悬浮歌词宽度、换句动画一起设")
        expectEqual(link("lyrimuse://debug/overlay-layout?next-line=0.7"),
                    .debug(.overlayLayout(width: nil, lineChange: nil, nextLine: 0.7)), "debug: 只设下一句字号比例")
        expectEqual(link("lyrimuse://debug/overlay-layout?next-line=-1"), nil, "debug: 下一句字号比例不是正数不认")
        expectEqual(link("lyrimuse://debug/overlay-layout?overflow=scroll"),
                    .debug(.overlayLayout(width: nil, lineChange: nil, overflow: .scroll)), "debug: 只设长句换行 / 滚动")
        expectEqual(link("lyrimuse://debug/overlay-layout?overflow=marquee"), nil, "debug: 长句处理不认的值不认")
        expectEqual(link("lyrimuse://debug/overlay-layout?next-arrangement=alternate"),
                    .debug(.overlayLayout(width: nil, lineChange: nil, nextArrangement: .alternate)), "debug: 只设下一句排法")
        expectEqual(link("lyrimuse://debug/overlay-layout?next-arrangement=zigzag"), nil, "debug: 下一句排法不认的值不认")
        expectEqual(link("lyrimuse://debug/overlay-layout?width=abc") == nil
                    && link("lyrimuse://debug/overlay-layout?width=-5") == nil
                    && link("lyrimuse://debug/overlay-layout") == nil, true, "debug: 宽度不是正数、什么都没带不认")
        expectEqual(link("lyrimuse://debug/japanese-reading?style=Kana"), .debug(.japaneseReading(.kana)),
                    "debug: 日语读音切到假名,大小写不敏感")
        expectEqual(link("lyrimuse://debug/japanese-reading?style=furigana") == nil
                    && link("lyrimuse://debug/japanese-reading") == nil, true, "debug: 认不出的样式、没带都不认")
        expectEqual(link("lyrimuse://debug/lyrics-window-controls?percent=135"), .debug(.lyricsWindowControls(percent: 135)),
                    "debug: 歌词窗口控件大小设成 135%")
        expectEqual(link("lyrimuse://debug/lyrics-window-controls?percent=150&draft=1"),
                    .debug(.lyricsWindowControls(percent: 150, draft: true)), "debug: 控件大小只给预览(同拖动途中)")
        expectEqual(link("lyrimuse://debug/lyrics-window-controls?percent=90") == nil
                    && link("lyrimuse://debug/lyrics-window-controls?percent=abc") == nil
                    && link("lyrimuse://debug/lyrics-window-controls") == nil, true, "debug: 控件大小越界、不是数、没带都不认")
        expectEqual(link("lyrimuse://debug/lyrics-window-pointer?inside=1"), .debug(.lyricsWindowPointer(inside: true)),
                    "debug: 当作指针进了歌词窗口")
        expectEqual(link("lyrimuse://debug/lyrics-window-pointer?inside=0"), .debug(.lyricsWindowPointer(inside: false)),
                    "debug: 当作指针出了歌词窗口")
        expectEqual(link("lyrimuse://debug/lyrics-window-pointer?inside=maybe") == nil
                    && link("lyrimuse://debug/lyrics-window-pointer") == nil, true, "debug: 指针进出认不出、没带都不认")
        expectEqual([link("lyrimuse://debug/lyrics-window-key?state=on"), link("lyrimuse://debug/lyrics-window-key?state=OFF"),
                     link("lyrimuse://debug/lyrics-window-key?state=auto")],
                    [.debug(.lyricsWindowKey(override: true)), .debug(.lyricsWindowKey(override: false)),
                     .debug(.lyricsWindowKey(override: nil))], "debug: 歌词窗口红绿灯当作是 / 不是 key、交还")
        expectEqual(link("lyrimuse://debug/lyrics-window-key?state=maybe") == nil
                    && link("lyrimuse://debug/lyrics-window-key") == nil, true, "debug: 歌词窗口 key 覆盖认不出的、没带都不认")
        expectEqual([link("lyrimuse://debug/lyrics-window-fullscreen?state=on"), link("lyrimuse://debug/lyrics-window-fullscreen?state=OFF")],
                    [.debug(.lyricsWindowFullScreen(on: true)), .debug(.lyricsWindowFullScreen(on: false))],
                    "debug: 歌词窗口进 / 出全屏")
        expectEqual(link("lyrimuse://debug/lyrics-window-fullscreen?state=auto") == nil
                    && link("lyrimuse://debug/lyrics-window-fullscreen") == nil, true, "debug: 歌词窗口全屏认不出的、没带都不认")
        expectEqual(link("lyrimuse://debug/rainbow?overlay=1"), .debug(.rainbow(overlay: true, notch: nil)), "debug: 只开悬浮歌词彩虹")
        expectEqual(link("lyrimuse://debug/rainbow?overlay=0&notch=1"), .debug(.rainbow(overlay: false, notch: true)),
                    "debug: 悬浮歌词、灵动岛彩虹一起设")
        expectEqual(link("lyrimuse://debug/rainbow?menubar=1"), .debug(.rainbow(overlay: nil, notch: nil, menuBar: true)),
                    "debug: 只开菜单栏彩虹")
        expectEqual(link("lyrimuse://debug/rainbow"), nil, "debug: 彩虹什么都没带不认")
        expectEqual(link("lyrimuse://debug/overlay-text?opacity=0.4&color=Cover"),
                    .debug(.overlayText(opacity: 0.4, color: "cover")), "debug: 悬浮歌词文字不透明度和颜色来源一起设")
        expectEqual(link("lyrimuse://debug/overlay-text?color=custom"), .debug(.overlayText(opacity: nil, color: "custom")),
                    "debug: 只设文字颜色来源")
        expectEqual(link("lyrimuse://debug/overlay-text?color=accent"), nil, "debug: 文字颜色来源不认的值不认")
        expectEqual(link("lyrimuse://debug/overlay-text?opacity=0"), nil, "debug: 不透明度不是正数不认")
        expectEqual(link("lyrimuse://debug/overlay-text"), nil, "debug: 文字设置什么都没带不认")
        expectEqual(link("lyrimuse://debug/touchbar-display?color=Rainbow"), .debug(.touchBarDisplay(color: .rainbow)),
                    "debug: 触控栏歌词颜色切彩虹(大小写不敏感)")
        expectEqual([link("lyrimuse://debug/touchbar-typing?state=on"), link("lyrimuse://debug/touchbar-typing?state=OFF"),
                     link("lyrimuse://debug/touchbar-typing?state=auto")],
                    [.debug(.touchBarTyping(override: true)), .debug(.touchBarTyping(override: false)),
                     .debug(.touchBarTyping(override: nil))], "debug: 触控栏当作在 / 不在输入框里、交还")
        expectEqual(link("lyrimuse://debug/touchbar-typing?state=maybe") == nil
                    && link("lyrimuse://debug/touchbar-typing") == nil, true, "debug: 触控栏输入状态认不出的、没带都不认")
        expectEqual([link("lyrimuse://debug/manager-visibility?state=hidden"), link("lyrimuse://debug/manager-visibility?state=Visible"),
                     link("lyrimuse://debug/manager-visibility?state=auto")],
                    [.debug(.managerVisibility(override: false)), .debug(.managerVisibility(override: true)),
                     .debug(.managerVisibility(override: nil))], "debug: 歌词管理当作挡住 / 露出来 / 交还")
        expectEqual(link("lyrimuse://debug/manager-instrumental?key=a%7Cb%7Cc&on=1"), .debug(.managerInstrumental(key: "a|b|c", on: true)),
                    "debug: 歌词管理把一条标成纯音乐")
        expectEqual(link("lyrimuse://debug/manager-instrumental?on=1") == nil && link("lyrimuse://debug/manager-instrumental?key=a%7Cb%7Cc") == nil,
                    true, "debug: 歌词管理标纯音乐没带 key 或 on 不认")
        expectEqual([link("lyrimuse://debug/manager-list?op=search%3Ajay"), link("lyrimuse://debug/main-thread-gaps?on=1"),
                     link("lyrimuse://debug/main-thread-gaps?on=0"), link("lyrimuse://debug/main-thread-gaps?on=1&min=30"),
                     link("lyrimuse://debug/main-thread-gaps?on=1&min=0")],
                    [.debug(.managerList(op: "search:jay")), .debug(.mainThreadGaps(on: true)), .debug(.mainThreadGaps(on: false)),
                     .debug(.mainThreadGaps(on: true, minMs: 30)), .debug(.mainThreadGaps(on: true))],
                    "debug: 歌词管理列表动作、主线程心跳")
        expectEqual(link("lyrimuse://debug/manager-list") == nil && link("lyrimuse://debug/manager-list?op=") == nil
                    && link("lyrimuse://debug/main-thread-gaps") == nil, true, "debug: 列表动作没带 op、心跳没带 on 不认")
        expectEqual([link("lyrimuse://debug/main-thread-stall?seconds=7"), link("lyrimuse://debug/main-thread-stall?seconds=6.5&throttle=locked"),
                     link("lyrimuse://debug/main-thread-stall?seconds=12&throttle=low_priority")],
                    [.debug(.mainThreadStall(seconds: 7, throttle: nil)), .debug(.mainThreadStall(seconds: 6.5, throttle: "locked")),
                     .debug(.mainThreadStall(seconds: 12, throttle: "low_priority"))], "debug: 让主线程停几秒,可带节流读数")
        expectEqual([link("lyrimuse://debug/main-thread-stall"), link("lyrimuse://debug/main-thread-stall?seconds=0"),
                     link("lyrimuse://debug/main-thread-stall?seconds=13"), link("lyrimuse://debug/main-thread-stall?seconds=5&throttle=asleep")],
                    [nil, nil, nil, nil], "debug: 主线程停顿没带秒数、超过上限、节流读数认不出都不认")
        expectEqual(link("lyrimuse://debug/manager-visibility?state=on") == nil
                    && link("lyrimuse://debug/manager-visibility") == nil, true, "debug: 歌词管理可见性认不出的、没带都不认")
        expectEqual([link("lyrimuse://debug/settings-visibility?state=hidden"), link("lyrimuse://debug/settings-visibility?state=Visible"),
                     link("lyrimuse://debug/settings-visibility?state=auto")],
                    [.debug(.settingsVisibility(override: false)), .debug(.settingsVisibility(override: true)),
                     .debug(.settingsVisibility(override: nil))], "debug: 设置窗口当作挡住 / 露出来 / 交还")
        expectEqual([link("lyrimuse://debug/engine-alive?state=absent"), link("lyrimuse://debug/engine-alive?state=Present"),
                     link("lyrimuse://debug/engine-alive?state=auto")],
                    [.debug(.engineAlive(override: false)), .debug(.engineAlive(override: true)),
                     .debug(.engineAlive(override: nil))], "debug: 歌词引擎常驻进程当作不在 / 在 / 交还")
        expectEqual(link("lyrimuse://debug/engine-alive?state=down") == nil
                    && link("lyrimuse://debug/engine-alive") == nil, true, "debug: 引擎在不在认不出的、没带都不认")
        expectEqual(link("lyrimuse://debug/settings-visibility?state=on") == nil
                    && link("lyrimuse://debug/settings-visibility") == nil, true, "debug: 设置窗口可见性认不出的、没带都不认")
        expectEqual([link("lyrimuse://debug/onboarding-step?step=done"), link("lyrimuse://debug/onboarding-step?step=Background"),
                     link("lyrimuse://debug/onboarding-step?step=players")],
                    [.debug(.onboardingStep(.done)), .debug(.onboardingStep(.background)), .debug(.onboardingStep(.playerChoice))],
                    "debug: 引导翻到某一步")
        expectEqual(link("lyrimuse://debug/onboarding-step?step=finish") == nil
                    && link("lyrimuse://debug/onboarding-step") == nil, true, "debug: 引导步骤认不出的、没带都不认")
        expectEqual(link("lyrimuse://debug/touchbar-display?color=pink") == nil
                    && link("lyrimuse://debug/touchbar-display") == nil, true, "debug: 触控栏颜色认不出的、没带都不认")
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
        expectEqual(link("lyrimuse://debug/simulate?idle=1"), .debug(.simulateIdle), "模拟播放: 什么都没在放(不用带歌名)")
        expectEqual(link("lyrimuse://debug/simulate?title=x&ad=1"),
                    .debug(.simulate(title: "x", artist: "", album: "", duration: nil, position: 0, playing: true, ad: true)),
                    "模拟播放: 这一首按广告报")
        expectEqual(link("lyrimuse://debug/simulate?title=x&artwork=%2FUsers%2Fme%2Fcover.jpg"),
                    .debug(.simulate(title: "x", artist: "", album: "", duration: nil, position: 0, playing: true,
                                     artworkPath: "/Users/me/cover.jpg")), "模拟播放: 带封面路径")
        expectEqual(link("lyrimuse://debug/simulate?title=x&artwork=cover.jpg"),
                    .debug(.simulate(title: "x", artist: "", album: "", duration: nil, position: 0, playing: true)),
                    "模拟播放: 封面路径不是绝对路径不认")
        expectEqual(link("lyrimuse://action/play-mode?mode=Repeat-All"), .setPlayMode(.repeatAll), "播放模式: 取值不分大小写")
        expectEqual(link("lyrimuse://action/play-mode?mode=loop") == nil && link("lyrimuse://action/play-mode") == nil, true,
                    "播放模式: 认不出的取值、没带取值都认不出")
        expectEqual(link("lyrimuse://debug/simulate?artist=x"), nil, "模拟播放: 没给歌名认不出")
        expectEqual(link("lyrimuse://debug/favorite"), .debug(.toggleFavorite), "debug: 翻转喜欢")
        expectEqual(link("lyrimuse://debug/idle-resume"), .debug(.idleResume), "debug: 停播页继续播放")
        expectEqual(link("lyrimuse://debug/seek?seconds=99.7"), .debug(.seek(seconds: 99.7)), "debug: 跳转")
        expectEqual([link("lyrimuse://debug/seek?seconds=-1"), link("lyrimuse://debug/seek"), link("lyrimuse://debug/seek?seconds=nan")]
                        .allSatisfy { $0 == nil }, true, "debug: 跳转负数、没带、不是数都认不出")
        for leg in ["apple-music-script", "spotify-script", "kaset-script", "player-file", "foobar-slider"] {
            expectEqual(link("lyrimuse://debug/knockout?leg=\(leg)&on=0").map { "\($0)" }?.contains("knockout") ?? false, true,
                        "debug: 拔腿开关认得 \(leg)")
        }
        expectEqual(link("lyrimuse://debug/reporting-switch-hint?bundle=com.tencent.QQMusicMac"),
                    .debug(.reportingSwitchHint(bundleID: "com.tencent.QQMusicMac")), "debug: 播放器开关提示")
        expectEqual(link("lyrimuse://debug/reporting-switch-hint") == nil && link("lyrimuse://debug/reporting-switch-hint?bundle=") == nil,
                    true, "debug: 播放器开关提示没带 bundle 认不出")
        expectEqual(link("lyrimuse://debug/volume?percent=35"), .debug(.volume(percent: 35)), "debug: 音量")
        expectEqual(link("lyrimuse://debug/volume?percent=101") == nil && link("lyrimuse://debug/volume") == nil, true,
                    "debug: 音量超出 0…100、没带取值都认不出")
        expectEqual([link("lyrimuse://debug/notch-volume?step=up"), link("lyrimuse://debug/notch-volume?step=Down"),
                     link("lyrimuse://debug/notch-volume"), link("lyrimuse://debug/notch-volume?step=left")],
                    [.debug(.notchVolume(up: true)), .debug(.notchVolume(up: false)), nil, nil],
                    "debug: 灵动岛调系统音量认 up / down,别的不认")
        expectEqual(link("lyrimuse://debug/notch-behavior?volume-key-banner=0"),
                    .debug(.notchBehavior(collapseWhenPaused: nil, hideWhenNotPlaying: nil, volumeKeyBanner: false)),
                    "debug: 只关灵动岛按音量键时提示")
        expectEqual([link("lyrimuse://debug/notify-channel"), link("lyrimuse://debug/notify-channel?id="),
                     link("lyrimuse://debug/notify-channel?id=Legacy")],
                    [.debug(.editNotifyChannel(id: nil)), .debug(.editNotifyChannel(id: nil)), .debug(.editNotifyChannel(id: "Legacy"))],
                    "debug: 打开渠道编辑弹窗,没带 id 或空的是第一个,id 原样")
        expectEqual([link("lyrimuse://debug/hover-note?q=%E8%B6%8A%E5%8D%97"), link("lyrimuse://debug/hover-note?q=Zing%20"),
                     link("lyrimuse://debug/hover-note"), link("lyrimuse://debug/hover-note?q="),
                     link("lyrimuse://debug/hover-note?off=1"), link("lyrimuse://debug/hover-note?q=abc&off=1")],
                    [.debug(.hoverNote(query: "越南")), .debug(.hoverNote(query: "Zing")),
                     .debug(.hoverNote(query: nil)), .debug(.hoverNote(query: nil)),
                     .debug(.hoverNote(query: nil)), .debug(.hoverNote(query: nil))],
                    "debug: 悬停气泡,匹配文字去首尾空白、原样不转小写;没带、空、off=1 都是收回")
        expectEqual(link("lyrimuse://debug/settings-search?q=%E7%BD%91%E9%A1%B5%E6%AD%8C%E8%AF%8D"),
                    .debug(.settingsSearch(query: "网页歌词")), "debug: 设置搜索,搜索词原样(不转小写)")
        expectEqual(link("lyrimuse://debug/settings-search") == nil && link("lyrimuse://debug/settings-search?q=%20") == nil, true,
                    "debug: 设置搜索没带词、只有空白都认不出")
        expectEqual(link("lyrimuse://debug/import-lyrics?path=/tmp/a%20b.lrc&path=rel.lrc&PATH=/tmp/a.tr.lrc"),
                    .debug(.importLyrics(paths: ["/tmp/a b.lrc", "/tmp/a.tr.lrc"])), "debug: 导入歌词文件,只认绝对路径、按顺序")
        expectEqual(link("lyrimuse://debug/import-lyrics"), .debug(.importLyrics(paths: [])),
                    "debug: 导入歌词文件不带 path 是空列表(窗口弹选文件框)")
        expectEqual(link("lyrimuse://debug/import-lyrics?path=x.lrc") == nil, true,
                    "debug: 导入歌词文件带了 path 却没有绝对路径认不出")
        expectEqual(link("lyrimuse://debug/import-lyrics-folder?path=/Users/a/%E6%AD%8C%E8%AF%8D"),
                    .debug(.importLyricsFolder(path: "/Users/a/歌词")), "debug: 导入歌词文件夹,路径原样")
        expectEqual(link("lyrimuse://debug/import-lyrics-folder") == nil && link("lyrimuse://debug/import-lyrics-folder?path=rel") == nil, true,
                    "debug: 导入歌词文件夹没带绝对路径认不出")
        expectEqual([link("lyrimuse://debug/import-library"), link("lyrimuse://debug/import-watch?path=/Users/a/x"),
                     link("lyrimuse://debug/import-watch?off=1")],
                    [.debug(.importLibrary), .debug(.importWatch(path: "/Users/a/x")), .debug(.importWatch(path: nil))],
                    "debug: 导入库面板、设监视文件夹、停止监视")
        expectEqual([link("lyrimuse://debug/manager-decision"), link("lyrimuse://debug/manager-decision?key="),
                     link("lyrimuse://debug/manager-decision?key=A%7CB%7CC")],
                    [.debug(.managerDecision(key: nil)), .debug(.managerDecision(key: nil)), .debug(.managerDecision(key: "A|B|C"))],
                    "debug: 歌词管理解析决策面板,没带 key / 空 key 是详情页那条,键原样")
        expectEqual(link("lyrimuse://debug/lyrics-search?key=A%7CB%7CC"), .debug(.lyricsSearch(key: "A|B|C")),
                    "debug: 按写法键开搜索歌词窗口,键原样")
        let searchInBackground = URL(string: "lyrimuse://debug/lyrics-search?key=A%7CB%7CC&background=1")!
        expectEqual(link(searchInBackground.absoluteString) == .debug(.lyricsSearch(key: "A|B|C"))
                    && LyrimuseDeepLink.wantsBackground(searchInBackground), true,
                    "debug: 按写法键开搜索歌词窗口可带 background=1,不影响认哪条链接")
        expectEqual([link("lyrimuse://debug/lyrics-writeback?step=open"), link("lyrimuse://debug/lyrics-writeback?step=confirm"),
                     link("lyrimuse://debug/lyrics-writeback?step=cancel")],
                    [.debug(.lyricsWriteback(step: "open")), .debug(.lyricsWriteback(step: "confirm")),
                     .debug(.lyricsWriteback(step: "cancel"))], "debug: 写入歌曲文件的三步")
        expectEqual(link("lyrimuse://debug/lyrics-writeback") == nil && link("lyrimuse://debug/lyrics-writeback?step=write") == nil, true,
                    "debug: 写入歌曲文件认不出的步骤不收")
        expectEqual(link("lyrimuse://debug/simulate?title=x&file=/Users/a/b%20c.mp3&file_player=com.apple.Music"),
                    .debug(.simulate(title: "x", artist: "", album: "", duration: nil, position: 0, playing: true,
                                     localFile: "/Users/a/b c.mp3", localFilePlayer: "com.apple.Music")),
                    "debug: 模拟播放带本地文件和它的播放器")
        expectEqual(link("lyrimuse://debug/simulate?title=x&file=rel.mp3"),
                    .debug(.simulate(title: "x", artist: "", album: "", duration: nil, position: 0, playing: true)),
                    "debug: 模拟播放的本地文件不是绝对路径就不认")
        expectEqual(link("lyrimuse://debug/lyrics-search") == nil && link("lyrimuse://debug/lyrics-search?key=") == nil, true,
                    "debug: 搜索歌词窗口没带写法键认不出")
        expectEqual(link("lyrimuse://debug/import-watch") == nil && link("lyrimuse://debug/import-watch?path=rel") == nil, true,
                    "debug: 监视文件夹没带绝对路径也没说停止,认不出")

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
        // 已开着的场景窗再 openWindow 会 makeKeyAndOrderFront,处理深链时窗口服务器借这一下把 App 切到前台(14 章决策 197)。
        let sceneOpens = scene.components(separatedBy: "openWindowAction(id:").count - 1
        let viaOpenScene = scene.components(separatedBy: "WindowActivation.openScene(").count - 1
        expectEqual(viaOpenScene >= 7 && sceneOpens - viaOpenScene == 1, true,
                    "后台开窗: 歌词管理 / 歌词窗口两处 / 搜索小窗 / 分享 / 本次更新 / 引导都走 openScene,只有启动重开直接 openWindow")
        expectEqual(sourceHas(sourceBody("static func presentSettings(", in: scene),
                              #"if WindowActivation.surfaceIfOnScreen("settings") { return } WindowActivation.activateApp()"#),
                    true, "后台开窗: 设置窗口开着时只摆到最前,不再走菜单项(那条路 makeKeyAndOrderFront)")
        let activation = source("lyrimuse/Settings/WindowActivation.swift")
        expectEqual(sourceHas(sourceBody("static func openScene(", in: activation),
                              "if surfaceIfOnScreen(identifier) { return } activateApp() open()"),
                    true, "后台开窗: openScene 先看窗口在不在屏上,在就不再 open;不带 background 时照旧激活再开")
        expectEqual(sourceHas(sourceBody("static func surfaceIfOnScreen(", in: activation),
                              "guard isBackground, let window = window(matching: identifier, visibleOnly: true) else { return false } window.orderFrontRegardless()"),
                    true, "后台开窗: 只在 background=1 那一段、窗口可见时跳过 openWindow,摆到最前不当 key")
        // debug/lyrics-search 开的也是搜索小窗:background=1 时由路由摆到最前;列表没读完、晚开的那一次自己补上后台那一段。
        let router = source("lyrimuse/Settings/DeepLinkRouter.swift")
        let lateSearch = sourceBody("private static func openLyricsSearch(", in: debug)
        expectEqual([sourceHas(router, ".debug(.lyricsSearch): return \"lyrics-quick-search\""),
                     sourceHas(debug, "openLyricsSearch(key: key, background: WindowActivation.isBackground, attempt: 0)"),
                     sourceHas(lateSearch, "if late { WindowActivation.beginBackground() } AppActions.shared.openLyricsSearch(for:")
                         && sourceHas(lateSearch, "if late { WindowActivation.surface(identifier: \"lyrics-quick-search\") }")],
                    [true, true, true],
                    "后台开窗: debug/lyrics-search 认 background=1,歌词管理列表晚读完时补开的那一次也不激活 App")
        let windowKey = sourceBody("static func windowKey(", in: debug)
        expectEqual(sourceHas(windowKey, "equivalent = command && window.performKeyEquivalent(with: down) if !equivalent { window.sendEvent(down) }")
                    && !windowKey.contains("NSApp.activate") && !windowKey.contains("makeKey"), true,
                    "debug: 窗口按键带 ⌘ 先走快捷键那条路,其余经 sendEvent 送进窗口,不激活 App、不抢 key")

        // 模拟播放:位置怎么走,以及对外的出口都挡住(引擎读播放状态打卡 Last.fm,控制会发给真实播放器)。
        let t0 = Date(timeIntervalSince1970: 1_000)
        let sim = PlaybackSimulation(title: "a", artist: "b", album: "", duration: 10, position: 8, playing: true, anchoredAt: t0)
        expectEqual(sim.elapsed(at: t0.addingTimeInterval(1)), 9, "模拟播放: 位置随时间走")
        expectEqual(sim.elapsed(at: t0.addingTimeInterval(5)), 10, "模拟播放: 放到头停在时长上")
        expectEqual(sim.isPlaying(at: t0.addingTimeInterval(5)), false, "模拟播放: 放到头算停了")
        expectEqual(sim.snapshot(at: t0)?.bundleIdentifier, PlaybackSimulation.bundleIdentifier, "模拟播放: 快照带模拟的 bundle id")
        expectEqual(sim.snapshot(at: t0)?.isAd == nil
                        && PlaybackSimulation(title: "a", artist: "", album: "", duration: 30, position: 0, playing: true, ad: true)
                            .snapshot(at: t0)?.isAd == true, true,
                    "模拟播放: ad=1 时快照带 isAd(走播放器报广告那一路),平时不带")
        expectEqual(PlaybackSimulation.nothingPlaying(anchoredAt: t0).snapshot(at: t0) == nil, true,
                    "模拟播放: 什么都没在放时交空快照(同播放器撤掉正在播放)")
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
        expectEqual(PlaybackSimulation.isLeftover(shownBundleID: PlaybackSimulation.bundleIdentifier), true,
                    "模拟播放: 收尾后屏上还是模拟那首,算留下的")
        expectEqual(PlaybackSimulation.isLeftover(shownBundleID: PlaybackPlayer.appleMusic.bundleIdentifier)
                        || PlaybackSimulation.isLeftover(shownBundleID: nil), false,
                    "模拟播放: 屏上是真实播放器的歌或什么都没有,不算留下的")
        PlaybackSimulation.begin(.nothingPlaying(anchoredAt: t0))
        expectEqual(PlaybackSimulation.isLeftover(shownBundleID: PlaybackSimulation.bundleIdentifier), false,
                    "模拟播放: idle=1 模拟中不算留下的(照播放器撤掉正在播放那一路的宽限清)")
        PlaybackSimulation.end(now: t0.addingTimeInterval(2))
        let lps = source("LyrimuseCore/Local/LocalPlaybackSource.swift")
        expectEqual(sourceHas(lps, """
            if PlaybackSimulation.isLeftover(shownBundleID: self.lastSnapshot?.bundleIdentifier)
                || MediaControlClient.nilSnapshotClearsState(
            """), true,
                    "模拟播放: off=1 后读回空快照,屏上模拟那首当拍清掉,不按焦点被占留 300 秒")
        let publish = lps.components(separatedBy: "private func publishPlaybackState(").dropFirst().first ?? ""
        expectEqual(publish.prefix(400).contains("guard !PlaybackSimulation.isActive else { return }"), true,
                    "模拟播放: 不写给引擎的播放状态(引擎据此打卡 Last.fm)")
        expectEqual(lps.contains("bid != lastPersistedPlayerBundleID, !PlaybackSimulation.isActive")
                    && sourceHas(lps, "newTitle != lastPersistedTrackTitle,\n           !PlaybackSimulation.isActive"), true,
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
            .lyricsManagerSongVersions(key: "周杰伦|那天下雨了|太阳之子", showEvidence: false, compare: "周杰倫|那天下雨了|"),
            .lyricsWindow, .lyricsWindowSearch, .lyricsSearch, .lyricsShare, .whatsNew,
            .menuBarPanel(quick: nil), .menuBarPanel(quick: "overlay"), .menuBarMenu, .onboarding, .lastfmAuthCallback,
            .action(.toggleOverlay, on: true, stepSeconds: nil), .action(.lyricsAdvanceHotkey, on: nil, stepSeconds: 0.5),
            .copyLyric(includeTranslation: true), .copyLyric(includeTranslation: false),
            .setSurfaces(overlay: true, notch: false, menuBar: nil), .setLyricsOffset(ms: -300),
            .nowPlayingCallback(success: URL(string: "shortcuts://x-callback-url/ic-success")),
            .debug(.state), .debug(.telemetryPreview), .debug(.appMove(source: nil, destination: nil, answer: nil)),
            .debug(.appMove(source: "/Volumes/X Y/Lyrimuse.app", destination: "/tmp/t", answer: false)), .debug(.diagnostics), .debug(.checkpoint), .debug(.restore), .debug(.snapshot(window: "panel")),
            .debug(.dragRegion(window: "lyrics-window")),
            .debug(.simulate(title: "Orange Moon", artist: "Khalil", album: "", duration: 280, position: 12.5, playing: false)),
            .debug(.simulate(title: "x", artist: "y", album: "z", duration: nil, position: 0, playing: true)), .debug(.simulateOff),
            .debug(.simulate(title: "x", artist: "", album: "", duration: 30, position: 0, playing: true, ad: true)),
            .debug(.simulate(title: "x", artist: "", album: "", duration: nil, position: 0, playing: true,
                             artworkPath: "/tmp/cover 1.jpg")),
            .debug(.simulate(title: "x", artist: "", album: "", duration: nil, position: 0, playing: true,
                             localFile: "/tmp/a b.flac", localFilePlayer: "com.apple.Music")),
            .debug(.lyricsWriteback(step: "open")), .debug(.lyricsWriteback(step: "confirm")),
            .debug(.simulateIdle),
            .debug(.toggleFavorite), .debug(.idleResume), .debug(.seek(seconds: 99.7)), .debug(.seek(seconds: 0)),
            .debug(.knockout(leg: .appleMusicScript, on: false)), .debug(.knockout(leg: .spotifyScript, on: true)),
            .debug(.knockout(leg: .kasetScript, on: false)), .debug(.saveConfig), .debug(.releaseClosedWindows), .debug(.panelLayout(json: nil)), .debug(.panelPin(on: true)), .debug(.panelPin(on: false)), .debug(.panelDrag(from: CGPoint(x: 1.5, y: 2), to: CGPoint(x: 300, y: 400))), .debug(.panelDrag(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 3, y: 4), via: [CGPoint(x: 5, y: 6)])), .debug(.panelDrag(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 3, y: 4), inGallery: true)), .debug(.panelClick(at: CGPoint(x: 1, y: 2))), .debug(.panelClick(at: CGPoint(x: 1, y: 2), inGallery: true)), .debug(.windowClick(window: "lyrics-window", at: CGPoint(x: 1.5, y: 2))), .debug(.windowKey(window: "lyrics-search", key: "down", command: false)), .debug(.windowKey(window: "lyrics-search", key: "r", command: true)), .debug(.panelScroll(at: CGPoint(x: 1.5, y: 2), dy: 1)), .debug(.panelScroll(at: CGPoint(x: 1, y: 2), dy: -2.5, trackpad: true, steps: 20)),
            .debug(.panelLayout(json: MenuBarPanelLayout(placements: [.init(tile: .translation, size: .large, column: 0, row: 0)], footer: [.version]).encoded())), .debug(.volume(percent: 0)), .debug(.volume(percent: 100)),
            .debug(.stall(ms: 1)), .debug(.stall(ms: 2000)), .debug(.milestonePreview),
            .debug(.notchBehavior(collapseWhenPaused: true, hideWhenNotPlaying: nil)),
            .debug(.notchBehavior(collapseWhenPaused: false, hideWhenNotPlaying: true)),
            .debug(.notchBehavior(collapseWhenPaused: nil, hideWhenNotPlaying: nil, progressLine: .off)),
            .debug(.notchBehavior(collapseWhenPaused: true, hideWhenNotPlaying: nil, progressLine: .bottom)),
            .debug(.notchBehavior(collapseWhenPaused: nil, hideWhenNotPlaying: nil, allScreens: false)),
            .debug(.notchBehavior(collapseWhenPaused: nil, hideWhenNotPlaying: nil, volumeKeyBanner: true)),
            .debug(.notchVolume(up: true)), .debug(.notchVolume(up: false)),
            .debug(.notchStyle(style: "solidBlack", expanded: "coverArt")),
            .debug(.notchStyle(style: nil, expanded: "same")),
            .debug(.notchQuickActions(layout: "close,,settings|favorite")),
            .debug(.notchQuickActions(layout: "")),
            .debug(.notchPreview(state: "auto")), .debug(.notchPreview(state: "collapsed")),
            .debug(.notchLyricList(on: false, lines: 3, secondary: .romanization)),
            .debug(.notchLyricList(on: nil, lines: 5, secondary: nil)),
            .debug(.labsWriteback(auto: true, overwrite: nil)), .debug(.labsWriteback(auto: false, overwrite: true)),
            .debug(.wordFormatSwitch(state: "finished", format: "ttml", done: nil, total: 17564)),
            .debug(.wordFormatSwitch(state: "queued", format: nil, done: nil, total: nil)),
            .debug(.overlayLayout(width: 640, lineChange: true)),
            .debug(.moveWindow(title: "搜索歌词…", x: 7, y: 33)),
            .debug(.overlayLayout(width: nil, lineChange: false)),
            .debug(.overlayLayout(width: nil, lineChange: nil, nextLine: 0.75)),
            .debug(.overlayLayout(width: nil, lineChange: nil, overflow: .wrap)),
            .debug(.overlayLayout(width: nil, lineChange: nil, nextArrangement: .below)),
            .debug(.notchPassThrough(x: 120.5, y: 48)), .debug(.notchPassThroughOff), .debug(.notchPointer(x: 30, y: 12.5)),
            .debug(.notchHover(path: [CGPoint(x: -150, y: 10), CGPoint(x: 220.25, y: 0)], stepSecs: 0.05)), .debug(.notchHoverOff),
            .debug(.notchHint(key: "heart")), .debug(.notchHint(key: nil)),
            .debug(.notchBehavior(collapseWhenPaused: nil, hideWhenNotPlaying: nil, showLyrics: true)),
            .debug(.notchBehavior(collapseWhenPaused: nil, hideWhenNotPlaying: nil, lyricRowFade: false)),
            .debug(.knockout(leg: .voxScript, on: false)), .debug(.knockout(leg: .systemArtwork, on: true)),
            .debug(.reportingSwitchHint(bundleID: "com.tencent.QQMusic")),
            .debug(.menuBarCenter(center: true, ignoreNotch: true)), .debug(.menuBarCenter(center: false, ignoreNotch: nil)),
            .debug(.menuBarCenter(center: nil, ignoreNotch: false)),
            .debug(.menuBarCenter(center: true, ignoreNotch: nil, screen: "37D8832A-2D66-02CA-B9F7-8F30A301B230")),
            .debug(.menuBarCenter(center: nil, ignoreNotch: nil, hover: false, click: "left")),
            .debug(.japaneseReading(.kana)), .debug(.japaneseReading(.romaji)),
            .debug(.lyricsWindowControls(percent: 100)), .debug(.lyricsWindowControls(percent: 162.5)),
            .debug(.lyricsWindowControls(percent: 140, draft: true)),
            .debug(.lyricsWindowPointer(inside: true)), .debug(.lyricsWindowPointer(inside: false)),
            .debug(.lyricsWindowKey(override: true)), .debug(.lyricsWindowKey(override: false)), .debug(.lyricsWindowKey(override: nil)),
            .debug(.lyricsWindowFullScreen(on: true)), .debug(.lyricsWindowFullScreen(on: false)),
            .debug(.touchBarDisplay(color: .rainbow)), .debug(.touchBarDisplay(color: .cover)),
            .debug(.touchBarTyping(override: true)), .debug(.touchBarTyping(override: false)), .debug(.touchBarTyping(override: nil)),
            .debug(.managerVisibility(override: true)), .debug(.managerVisibility(override: false)), .debug(.managerVisibility(override: nil)),
            .debug(.settingsVisibility(override: true)), .debug(.settingsVisibility(override: false)), .debug(.settingsVisibility(override: nil)),
            .debug(.engineAlive(override: true)), .debug(.engineAlive(override: false)), .debug(.engineAlive(override: nil)),
            .debug(.onboardingStep(.welcome)), .debug(.onboardingStep(.playerChoice)), .debug(.onboardingStep(.browserPairing)),
            .debug(.onboardingStep(.background)), .debug(.onboardingStep(.displayMode)), .debug(.onboardingStep(.done)),
            .debug(.managerInstrumental(key: "歌手|歌 & 名|专辑", on: true)), .debug(.managerInstrumental(key: "a|b|", on: false)),
            .debug(.managerList(op: "search:歌 & 名")), .debug(.managerList(op: "key:down")),
            .debug(.managerList(op: "rightclick:3")),
            .debug(.mainThreadGaps(on: true)), .debug(.mainThreadGaps(on: false)), .debug(.mainThreadGaps(on: true, minMs: 20)),
            .debug(.mainThreadStall(seconds: 7, throttle: nil)), .debug(.mainThreadStall(seconds: 6.5, throttle: "low_priority")),
            .debug(.rainbow(overlay: true, notch: nil)), .debug(.rainbow(overlay: false, notch: true)),
            .debug(.rainbow(overlay: nil, notch: nil, menuBar: false)),
            .debug(.overlayText(opacity: 0.4, color: "cover")), .debug(.overlayText(opacity: 1, color: nil)),
            .debug(.overlayText(opacity: nil, color: "rainbow")),
            .debug(.menuBarDisplay(artwork: true, content: nil)), .debug(.menuBarDisplay(artwork: nil, content: "title")),
            .debug(.menuBarDisplay(artwork: false, content: "lyrics")),
            .debug(.menuBarDisplay(artwork: nil, content: nil, iconSize: "small")),
            .debug(.menuBarDisplay(artwork: nil, content: nil, iconSize: "large", iconStyle: "classic")),
            .debug(.menuBarDisplay(artwork: nil, content: nil, hoverControls: false)),
            .debug(.menuBarDisplay(artwork: nil, content: "translation", secondary: "off")),
            .debug(.menuBarDisplay(artwork: nil, content: nil, alignment: "center")),
            .debug(.menuBarDisplay(artwork: nil, content: nil, iconAnimates: true)),
            .debug(.menuBarDisplay(artwork: nil, content: nil, keepsLyricsWhenPaused: false)),
            .debug(.settingsSearch(query: "OBS 输出")),
            .debug(.hoverNote(query: "越南 VNG")), .debug(.hoverNote(query: nil)),
            .debug(.importLyrics(paths: ["/tmp/歌 词.lrc", "/tmp/歌 词.tr.lrc"])),
            .debug(.importLyrics(paths: [])),
            .debug(.importLyricsFolder(path: "/tmp/歌 词")),
            .debug(.importLibrary), .debug(.importWatch(path: "/tmp/歌 词")), .debug(.importWatch(path: nil)),
            .debug(.managerDecision(key: nil)), .debug(.managerDecision(key: "Michael Jackson|Billie Jean|Thriller")),
            .debug(.lyricsSearch(key: "Michael Jackson|Blood on the Dance Floor|HIStory ~dur254")),
            .debug(.editNotifyChannel(id: nil)), .debug(.editNotifyChannel(id: "Legacy-1")),
            .setPlayMode(.list), .setPlayMode(.shuffle), .setPlayMode(.repeatAll), .setPlayMode(.repeatOne),
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
                    "设置分段: 歌词 › 歌词库")
        for (alias, value) in [("sources", "fetch"), ("language", "translation"), ("timing", "display"), ("library", "manage")] {
            expectEqual(S.section(in: "/lyrics/\(alias)"), .init(storageKey: SettingsSearchCatalog.lyricsSectionKey, value: value),
                        "设置分段: 歌词页按显示名的别名 \(alias) 落到 \(value)")
        }
        expectEqual(S.section(in: "/appearance/menu-bar"), .init(storageKey: LyricsSurface.appearanceSectionStorageKey, value: "menuBar"),
                    "设置分段: 连字符写法换成 rawValue")
        expectEqual(S.section(in: "/account/lastfm/on-this-day"), .init(storageKey: SettingsSearchCatalog.lastfmSectionKey, value: "onThisDay"),
                    "设置分段: 账号页分段")
        expectEqual(S.section(in: "/lyrics"), nil, "设置分段: 没带分段")
        expectEqual(S.section(in: "/lyrics/nope"), nil, "设置分段: 认不出的分段")
        expectEqual(S.pagePath(of: "/lyrics/manage"), "/lyrics", "设置分段: 去掉分段剩下那一页")
        expectEqual(S.pagePath(of: "/account/discord/privacy"), "/account/discord", "设置分段: 账号页去掉分段")
        expectEqual(S.pagePath(of: "/lyrics/nope"), "/lyrics", "设置分段: 认不出的分段也去掉,翻到那一页")
        expectEqual(S.pagePath(of: "/shortcuts/nope"), "/shortcuts", "设置分段: 没有分段的页带了一段也翻到那一页")
        expectEqual(S.pagePath(of: "/account/lastfm"), "/account/lastfm", "设置分段: 两段的账号页本身原样")
        expectEqual(S.pagePath(of: "/account/nope"), "/account/nope", "设置分段: 去掉一段也不是一页时原样(只叫出设置窗口)")
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
            "appearance": settingsView.contains("case overlay, notch, menuBar, touchBar, lyricsWindow\n"),
            "account/lastfm": accounts.contains("case stats, chart, onThisDay") && accounts.contains("        case settings\n"),
            "account/discord": accounts.contains("case display, buttons, privacy"),
        ]
        expectEqual(Set(S.sectionTable.keys), Set(declared.keys), "设置分段: 有分段的就这五页")
        for (page, ok) in declared.sorted(by: { $0.key < $1.key }) {
            expectEqual(ok, true, "设置分段: \(page) 的取值跟 App 枚举对得上(枚举改了这张表要跟着改)")
        }
    }

    // ---- 对外文档 docs/url-scheme(.<语言>).md:每一份都写到每个动作、播放模式、设置页和分段 ----
    do {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let names = LyrimuseAction.allCases.map(\.linkName) + LyrimuseDeepLink.extraActionNames
        let modes = LyrimuseDeepLink.playModeNames.keys.sorted()
        let pages = SettingsDeepLink.tabNames.map { "/" + $0 } + SettingsDeepLink.Account.allCases.map { "/account/" + $0.rawValue }
            + ["/software-update", "/lastfm-suggestions", "/labs"]
        // 分段别名(web-lyrics、obs 跳到同页的另一个分段)不写进对外文档。
        let sections = SettingsDeepLink.sectionTable.values.flatMap { $0.values.keys }
            .filter { !["web-lyrics", "obs"].contains($0) }.map { "/" + $0 }
        for file in ["docs/url-scheme.md", "docs/url-scheme.zh-CN.md"] + LyrimuseDeepLink.docsLanguages.map({ "docs/url-scheme.\(UILanguage.localeIdentifier(for: $0)).md" }) {
            let doc = (try? String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8)) ?? ""
            expectEqual(doc.isEmpty, false, "对外文档: \(file) 在")
            let missing = names.filter { !doc.contains("`\($0)`") && !doc.contains("action/\($0)") }
                + (modes + pages + Set(sections).sorted()).filter { !doc.contains("`\($0)`") }
            expectEqual(missing, [], "对外文档: \(file) 写到了每个动作、播放模式、设置页和分段")
        }
        expectEqual(LyrimuseDeepLink.referenceURL(language: "zh-hant").lastPathComponent, "url-scheme.zh-CN.md",
                    "对外文档: 中文界面开中文那份")
        expectEqual(LyrimuseDeepLink.referenceURL(language: "en").lastPathComponent, "url-scheme.md", "对外文档: 英文界面开英文那份")
        expectEqual(["ja", "ko", "es", "fr", "de", "it", "pt-br", "vi", "ru", "uk", "th", "tr", "pl"].map { LyrimuseDeepLink.referenceURL(language: $0).lastPathComponent },
                    ["url-scheme.ja.md", "url-scheme.ko.md", "url-scheme.es.md", "url-scheme.fr.md", "url-scheme.de.md", "url-scheme.it.md", "url-scheme.pt-BR.md", "url-scheme.vi.md", "url-scheme.ru.md", "url-scheme.uk.md", "url-scheme.th.md", "url-scheme.tr.md", "url-scheme.md"],
                    "对外文档: 日韩西法德意葡越俄乌泰土界面开各自那份,认不出的语言开英文")
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
        expectEqual(sourceHas(router, "case let .lyricsManagerSongVersions(key, showEvidence, compare):\n            AppActions.shared.openLyricsManager?()\n            AppActions.shared.requestSongVersions(key: key, showEvidence: showEvidence, compare: compare)")
                    && manager.contains(".onReceive(AppActions.shared.songVersionsRequests) { if !pendingAutoFocus { consumeSongVersionsRequest() } }")
                    && sourceHas(manager, "guard pendingAutoFocus else {\n                    consumeSongVersionsRequest()")
                    && sourceHas(manager, "DispatchQueue.main.async { windowFrame.focusList() }\n                // 链接带的条目排在自动定位之后")
                    && manager.contains("guard showSongVersions || !windowFrame.hasAttachedSheet,")
                    && manager.contains("Date().timeIntervalSince(request.at) < 60, let key = request.key ?? singleSelectedKey,")
                    && manager.contains("store.songMembership(forKey: key) != nil, select(key) else { return }"), true,
                    "深链接线: 同曲条目面板在开窗那一轮读完缓存、自动定位之后才取,条件同「⋯」里那一项,有没保存的修改先问,开着别的面板不动,信箱只认 60 秒内的请求")
        let sheet = source("lyrimuse/LyricsManager/SongVersionsSheet.swift")
        expectEqual(sourceHas(manager, "songVersionsShowEvidence = request.showEvidence\n        songVersionsCompare = request.compare\n        showSongVersions = true")
                    && manager.contains(".sheet(isPresented: $showSongVersions, onDismiss: { songVersionsShowEvidence = false; songVersionsCompare = nil }) {")
                    && sourceHas(manager, "onOpen: { other in revealInList(other) }, showEvidence: songVersionsShowEvidence,\n                                  compareKey: songVersionsCompare)")
                    && sheet.contains(".onChange(of: \"\\(summary.key)#\\(showEvidence)\", initial: true) { _, _ in if showEvidence { evidenceExpanded = true } }")
                    && sheet.contains(".onChange(of: \"\\(summary.key)#\\(compareKey ?? \"\")\", initial: true) { _, _ in if let compareKey { selected = compareKey } }"), true,
                    "深链接线: evidence=1 打开同曲条目就展开匹配依据、compare 选中那一条的对照,开着时换一首也照办;面板关掉后手点打开照旧")
        expectEqual(statusItem.contains("if quick != nil || editing, panelIsOpen { panelController.close() }"), true,
                    "深链接线: 面板带 quick(含 quick=edit)时开着也不关,翻到那一页")
        expectEqual(router.contains("guard let success else {") && router.contains("NSWorkspace.shared.open(url)"), true,
                    "深链接线: x-callback 只往解析层放行的地址回传")
        expectEqual(router.contains("playing: hasTrack && p.isPlayingSmoothed"), true,
                    "深链接线: x-callback 的 playing 按在不在放算,暂停时为 0(曲目各项照样带上)")
        expectEqual(delegate.contains("DeepLinkRouter.handle(url)") && !delegate.contains("handleAuthCallback()"), true,
                    "深链接线: AppDelegate 只交给 DeepLinkRouter,不再兜底调授权回调")
        expectEqual(router.contains("let logged = (url.host ?? \"\") + url.path") && !router.contains("url.absoluteString"), true,
                    "深链接线: 日志不记查询参数(Last.fm 回跳带 token,导出诊断会带走 App 日志)")
        expectEqual(sourceHas(router, "case .lastfmAuthCallback:\n            LastfmConnectController.shared.handleAuthCallback()")
                    && router.contains("GlobalHotkeys.flashHint(icon: \"link\", text: L10n.t(\"无法识别的链接\"))"), true,
                    "深链接线: 授权回调只认自己那个 host,认不出的闪一句")
    }
}
