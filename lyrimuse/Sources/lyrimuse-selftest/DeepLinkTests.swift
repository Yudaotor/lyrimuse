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
        expectEqual(link("lyrimuse://debug/snapshot?window=Lyrics-Manager"), .debug(.snapshot(window: "lyrics-manager")),
                    "debug: 窗口快照,名字转小写")
        expectEqual(link("lyrimuse://debug/snapshot") == nil && link("lyrimuse://debug/nope") == nil, true,
                    "debug: 快照没给窗口名、认不出的命令返回 nil")
        expectEqual(link("lyrimuse://debug/checkpoint"), .debug(.checkpoint), "debug: 记下")
        expectEqual(link("lyrimuse://debug/restore"), .debug(.restore), "debug: 恢复")
        expectEqual(link("lyrimuse://debug/config-save"), .debug(.saveConfig), "debug: 账号配置原样保存一次")
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
        expectEqual(link("lyrimuse://debug/panel-click") == nil && link("lyrimuse://debug/panel-click?at=1") == nil, true,
                    "debug: 点的位置缺了或写错不认")
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
        expectEqual(link("lyrimuse://debug/notch-quick-actions?layout=close,,settings%7Cfavorite"),
                    .debug(.notchQuickActions(layout: "close,,settings|favorite")), "debug: 灵动岛快捷操作格子")
        expectEqual(link("lyrimuse://debug/notch-quick-actions"), nil, "debug: 快捷操作排法没带 layout 不认")
        expectEqual(link("lyrimuse://debug/notch-preview?state=expanded"),
                    .debug(.notchPreview(state: "expanded")), "debug: 设置页灵动岛预览钉在展开态")
        expectEqual(link("lyrimuse://debug/notch-preview?state=open"), nil, "debug: 预览状态只认 expanded / collapsed / auto")
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
        expectEqual(link("lyrimuse://debug/rainbow?overlay=1"), .debug(.rainbow(overlay: true, notch: nil)), "debug: 只开悬浮歌词彩虹")
        expectEqual(link("lyrimuse://debug/rainbow?overlay=0&notch=1"), .debug(.rainbow(overlay: false, notch: true)),
                    "debug: 悬浮歌词、灵动岛彩虹一起设")
        expectEqual(link("lyrimuse://debug/rainbow?menubar=1"), .debug(.rainbow(overlay: nil, notch: nil, menuBar: true)),
                    "debug: 只开菜单栏彩虹")
        expectEqual(link("lyrimuse://debug/rainbow"), nil, "debug: 彩虹什么都没带不认")
        expectEqual(link("lyrimuse://debug/touchbar-display?color=Rainbow"), .debug(.touchBarDisplay(color: .rainbow)),
                    "debug: 触控栏歌词颜色切彩虹(大小写不敏感)")
        expectEqual([link("lyrimuse://debug/touchbar-typing?state=on"), link("lyrimuse://debug/touchbar-typing?state=OFF"),
                     link("lyrimuse://debug/touchbar-typing?state=auto")],
                    [.debug(.touchBarTyping(override: true)), .debug(.touchBarTyping(override: false)),
                     .debug(.touchBarTyping(override: nil))], "debug: 触控栏当作在 / 不在输入框里、交还")
        expectEqual(link("lyrimuse://debug/touchbar-typing?state=maybe") == nil
                    && link("lyrimuse://debug/touchbar-typing") == nil, true, "debug: 触控栏输入状态认不出的、没带都不认")
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
        expectEqual(link("lyrimuse://debug/settings-search?q=%E7%BD%91%E9%A1%B5%E6%AD%8C%E8%AF%8D"),
                    .debug(.settingsSearch(query: "网页歌词")), "debug: 设置搜索,搜索词原样(不转小写)")
        expectEqual(link("lyrimuse://debug/settings-search") == nil && link("lyrimuse://debug/settings-search?q=%20") == nil, true,
                    "debug: 设置搜索没带词、只有空白都认不出")
        expectEqual(link("lyrimuse://debug/import-lyrics?path=/tmp/a%20b.lrc&path=rel.lrc&PATH=/tmp/a.tr.lrc"),
                    .debug(.importLyrics(paths: ["/tmp/a b.lrc", "/tmp/a.tr.lrc"])), "debug: 导入歌词文件,只认绝对路径、按顺序")
        expectEqual(link("lyrimuse://debug/import-lyrics") == nil && link("lyrimuse://debug/import-lyrics?path=x.lrc") == nil, true,
                    "debug: 导入歌词文件没带绝对路径认不出")
        expectEqual(link("lyrimuse://debug/import-lyrics-folder?path=/Users/a/%E6%AD%8C%E8%AF%8D"),
                    .debug(.importLyricsFolder(path: "/Users/a/歌词")), "debug: 导入歌词文件夹,路径原样")
        expectEqual(link("lyrimuse://debug/import-lyrics-folder") == nil && link("lyrimuse://debug/import-lyrics-folder?path=rel") == nil, true,
                    "debug: 导入歌词文件夹没带绝对路径认不出")
        expectEqual([link("lyrimuse://debug/import-library"), link("lyrimuse://debug/import-watch?path=/Users/a/x"),
                     link("lyrimuse://debug/import-watch?off=1")],
                    [.debug(.importLibrary), .debug(.importWatch(path: "/Users/a/x")), .debug(.importWatch(path: nil))],
                    "debug: 导入库面板、设监视文件夹、停止监视")
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
        expectEqual(scene.components(separatedBy: "WindowActivation.activateApp()").count - 1 >= 6, true,
                    "后台开窗: 设置 / 歌词管理 / 歌词窗口两处 / 搜索小窗 / 引导六处入口")

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
        let lps = source("LyrimuseCore/Local/LocalPlaybackSource.swift")
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
            .debug(.state), .debug(.telemetryPreview), .debug(.checkpoint), .debug(.restore), .debug(.snapshot(window: "panel")),
            .debug(.simulate(title: "Orange Moon", artist: "Khalil", album: "", duration: 280, position: 12.5, playing: false)),
            .debug(.simulate(title: "x", artist: "y", album: "z", duration: nil, position: 0, playing: true)), .debug(.simulateOff),
            .debug(.simulate(title: "x", artist: "", album: "", duration: 30, position: 0, playing: true, ad: true)),
            .debug(.simulate(title: "x", artist: "", album: "", duration: nil, position: 0, playing: true,
                             artworkPath: "/tmp/cover 1.jpg")),
            .debug(.simulateIdle),
            .debug(.toggleFavorite), .debug(.idleResume), .debug(.seek(seconds: 99.7)), .debug(.seek(seconds: 0)),
            .debug(.knockout(leg: .appleMusicScript, on: false)), .debug(.knockout(leg: .spotifyScript, on: true)),
            .debug(.knockout(leg: .kasetScript, on: false)), .debug(.saveConfig), .debug(.panelLayout(json: nil)), .debug(.panelPin(on: true)), .debug(.panelPin(on: false)), .debug(.panelDrag(from: CGPoint(x: 1.5, y: 2), to: CGPoint(x: 300, y: 400))), .debug(.panelDrag(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 3, y: 4), via: [CGPoint(x: 5, y: 6)])), .debug(.panelDrag(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 3, y: 4), inGallery: true)), .debug(.panelClick(at: CGPoint(x: 1, y: 2))), .debug(.panelClick(at: CGPoint(x: 1, y: 2), inGallery: true)),
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
            .debug(.menuBarCenter(center: true, ignoreNotch: true)), .debug(.menuBarCenter(center: false, ignoreNotch: nil)),
            .debug(.menuBarCenter(center: nil, ignoreNotch: false)),
            .debug(.menuBarCenter(center: true, ignoreNotch: nil, screen: "37D8832A-2D66-02CA-B9F7-8F30A301B230")),
            .debug(.menuBarCenter(center: nil, ignoreNotch: nil, hover: false, click: "left")),
            .debug(.japaneseReading(.kana)), .debug(.japaneseReading(.romaji)),
            .debug(.lyricsWindowControls(percent: 100)), .debug(.lyricsWindowControls(percent: 162.5)),
            .debug(.lyricsWindowControls(percent: 140, draft: true)),
            .debug(.touchBarDisplay(color: .rainbow)), .debug(.touchBarDisplay(color: .cover)),
            .debug(.touchBarTyping(override: true)), .debug(.touchBarTyping(override: false)), .debug(.touchBarTyping(override: nil)),
            .debug(.rainbow(overlay: true, notch: nil)), .debug(.rainbow(overlay: false, notch: true)),
            .debug(.rainbow(overlay: nil, notch: nil, menuBar: false)),
            .debug(.menuBarDisplay(artwork: true, content: nil)), .debug(.menuBarDisplay(artwork: nil, content: "title")),
            .debug(.menuBarDisplay(artwork: false, content: "lyrics")),
            .debug(.menuBarDisplay(artwork: nil, content: nil, iconSize: "small")),
            .debug(.menuBarDisplay(artwork: nil, content: nil, iconSize: "large", iconStyle: "classic")),
            .debug(.menuBarDisplay(artwork: nil, content: nil, hoverControls: false)),
            .debug(.menuBarDisplay(artwork: nil, content: "translation", secondary: "off")),
            .debug(.menuBarDisplay(artwork: nil, content: nil, alignment: "center")),
            .debug(.settingsSearch(query: "OBS 输出")),
            .debug(.importLyrics(paths: ["/tmp/歌 词.lrc", "/tmp/歌 词.tr.lrc"])),
            .debug(.importLyricsFolder(path: "/tmp/歌 词")),
            .debug(.importLibrary), .debug(.importWatch(path: "/tmp/歌 词")), .debug(.importWatch(path: nil)),
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
        expectEqual(["ja", "ko", "es", "fr", "de", "it", "pt-br", "vi", "ru", "uk", "th", "pl"].map { LyrimuseDeepLink.referenceURL(language: $0).lastPathComponent },
                    ["url-scheme.ja.md", "url-scheme.ko.md", "url-scheme.es.md", "url-scheme.fr.md", "url-scheme.de.md", "url-scheme.it.md", "url-scheme.pt-BR.md", "url-scheme.vi.md", "url-scheme.ru.md", "url-scheme.uk.md", "url-scheme.th.md", "url-scheme.md"],
                    "对外文档: 日韩西法德意葡越俄乌泰界面开各自那份,认不出的语言开英文")
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
