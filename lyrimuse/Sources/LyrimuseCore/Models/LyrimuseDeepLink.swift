import Foundation

/// `lyrimuse://…` 链接的路由表:整条 URL 解析成一个值,App 只按这个值分派(`DeepLinkRouter`)。认不出的返回 nil,
/// App 闪一句「无法识别的链接」,不再落进 Last.fm 授权回调。见 docs/proposals/deep-links.md 与 14 章「深链」。
///
///     settings/<路径>[/<分段>]      设置窗口翻到那一页(路径表见 `SettingsDeepLink`,分段见 `SettingsDeepLink.section(in:)`)
///     settings/software-update?check=1    软件更新页并顺手检查一次
///     lyrics-manager                歌词管理
///     lyrics-manager/song-versions[?key=<写法键>][&evidence=1][&compare=<写法键>]   歌词管理 + 那一条的「同曲条目」面板(没带 key 是
///                                   详情页正显示的那条;evidence=1 打开就展开概况里的「匹配依据」;compare 打开就选中这一条、显示它跟
///                                   当前条目的对照)
///     lyrics-window                 歌词窗口
///     lyrics-window/search          歌词窗口 + 「搜索歌词…」窗口(同 lyrics-search 那扇)
///     lyrics-search                 「搜索歌词…」小窗(当前这首)
///     lyrics-share                  「分享歌词」窗口(当前这首)
///     whats-new                     「本次更新」卡片(当前版本的更新内容)
///     menubar-panel[?quick=<格子>]   开 / 关菜单栏左键面板,带 quick 时翻到那一格的快捷设置,quick=edit 进编辑
///     menubar-menu                  弹出菜单栏右键菜单(同右键点状态栏图标)
///     onboarding                    欢迎引导
///     action/<名字>[?on=1|0][&step=<秒>]   执行一个动作(= 全局快捷键那一套,见 `LyrimuseAction`)
///     action/copy-lyric[?translation=1]    把当前这句歌词(可连译文)放进剪贴板
///     action/surfaces?overlay=1&notch=0&menubar=1   一次设好几个展示面(只带要改的那几个)
///     action/lyrics-offset?ms=-300  这首歌的歌词时间轴直接设成某个值(±10 秒以内)
///     action/play-mode?mode=shuffle 播放模式设成 list / shuffle / repeat-all / repeat-one(同歌词窗口那两颗键;播放器够不到的档位落到 list)
///     x-callback-url/now-playing?x-success=…   把正在播放的信息作为参数打开 x-success(只回给本机 App)
///     lastfm-auth-callback          Last.fm 浏览器授权回跳(内部用)
///     debug/<命令>                  本机验证用(见 `DebugCommand`),只在本机偏好 `debug:deepLinks` 打开时才执行
///
/// 开窗类的链接(settings、lyrics-manager、lyrics-window、lyrics-search、lyrics-share、whats-new、onboarding、action/open-*)可以再带
/// `background=1`:窗口摆出来,但不激活 App、不抢键盘焦点(`wantsBackground(_:)`)。
/// host 和路径大小写不敏感;scheme 由调用方给(正式 `lyrimuse`,Dev `lyrimuse-dev`,`LyrimuseIdentity.urlScheme`)。
/// 改名、删除任何一条都要先看对外说过没有(CHANGELOG、README、支持回复),说过的保持能用。对外开放的链接都写在
/// docs/url-scheme.md 及其简中、日、韩、西、法、德、意、葡、越、俄、乌克兰、泰语版(`docsLanguages`),加、改一条几份一起改(selftest deep-links 组对着动作、设置页和分段查)。
public enum LyrimuseDeepLink: Equatable, Sendable {
    /// 对外文档在 GitHub 上的地址,按界面语言挑一份;`language` 同 `LegalNoticeLinks.usageNoticeURL(language:)`。
    public static func referenceURL(language: String) -> URL {
        let lang = language.lowercased()
        let suffix = lang.hasPrefix("zh") ? ".zh-CN" : docsLanguages.contains(lang) ? "." + UILanguage.localeIdentifier(for: lang) : ""
        return URL(string: LegalNoticeLinks.repo + "/blob/main/docs/url-scheme" + suffix + ".md")!
    }

    /// 除英文、简中外另有一份 docs/url-scheme.<语言>.md 的界面语言;文件名里的语言码按 `UILanguage.localeIdentifier(for:)`(pt-br → pt-BR)。
    public static let docsLanguages = ["ja", "ko", "es", "fr", "de", "it", "pt-br", "vi", "ru", "uk", "th"]

    case settings(path: String, checkForUpdates: Bool)
    case lyricsManager
    /// `key`:写法键(`EnrichCacheKeys.normalizedKey` 那种「歌手|歌名|专辑」);nil = 详情页正显示的那一条。`showEvidence`:
    /// 面板打开就展开概况里的「匹配依据」。`compare`:面板打开就选中这一条写法,显示它跟当前条目的对照。
    case lyricsManagerSongVersions(key: String?, showEvidence: Bool, compare: String? = nil)
    case lyricsWindow
    case lyricsWindowSearch
    case lyricsSearch
    case lyricsShare
    case whatsNew
    /// `quick` 是原样的取值(App 侧 `PanelQuickTarget(deepLinkValue:)` 认),认不出时 App 当没带。
    case menuBarPanel(quick: String?)
    case menuBarMenu
    case onboarding
    /// `on`:开关的目标状态(只有 `acceptsTargetState` 的动作收,别的动作带了也当没带);`stepSeconds`:歌词提前 /
    /// 延后的步长(只有 `acceptsStep` 的收,超出 0…`maxStepSeconds` 当没带)。
    case action(LyrimuseAction, on: Bool?, stepSeconds: Double?)
    case copyLyric(includeTranslation: Bool)
    /// nil = 这一个不动。三个都是 nil 的链接认不出(返回 nil)。
    case setSurfaces(overlay: Bool?, notch: Bool?, menuBar: Bool?)
    /// 这首歌自己的那一份偏移(毫秒),在 ±`maxLyricsOffsetMs` 以内。
    case setLyricsOffset(ms: Int)
    case setPlayMode(MusicPlaybackController.MusicPlaybackMode)
    /// x-callback-url:`success` 不收网页、文件、脚本的地址(`isCallbackCandidate`);回传前再看本机由谁来开,
    /// 浏览器开的不回(`isCallbackTarget(_:handler:browsers:)`),网页拿不到正在听什么。
    case nowPlayingCallback(success: URL?)
    case debug(DebugCommand)
    case lastfmAuthCallback

    /// 本机验证用的命令(`lyrimuse://debug/…`)。只给开发机上的验证脚本用,发布出去的 App 默认不认(见 `DebugDeepLinks`)。
    public enum DebugCommand: Equatable, Sendable {
        /// 把一扇窗画成 PNG(App 自己画,不需要屏幕录制权限,窗口在别的桌面空间也画得出)。
        case snapshot(window: String)
        /// 把界面状态写成 JSON(开着哪些窗口、面板翻在哪一格、当前播放与第几句、各开关)。
        case state
        /// 把此刻会发的那条遥测心跳写成 JSON(`telemetry-preview.json`),不发出去、不动记账。
        case telemetryPreview
        /// 记下此刻的窗口与开关,`restore` 时按它恢复。
        case checkpoint
        /// 回到最近一次 `checkpoint`:关掉之后开出来的窗口,开关设回原值。
        case restore
        /// 模拟播放(`PlaybackSimulation`):不读播放器,按这首驱动界面。时长、位置以秒计,`playing=0` 停在 `position`,
        /// `ad=1` 这一首按广告报。
        case simulate(title: String, artist: String, album: String, duration: Double?, position: Double, playing: Bool,
                      ad: Bool = false)
        /// 模拟什么都没在放(停播页,`debug/simulate?idle=1`)。
        case simulateIdle
        /// 结束模拟,交还真实播放器(`debug/simulate?off=1`)。
        case simulateOff
        /// 翻转当前曲目的「喜欢」,跟点歌词窗口那颗心走同一条路(`debug/favorite`)。
        case toggleFavorite
        /// 停播页的「继续播放」,跟点那颗键走同一条路、对停播页此刻指的那家播放器(`debug/idle-resume`)。
        case idleResume
        /// 跳到这一首的第几秒,跟拖进度条走同一条路(`debug/seek?seconds=`,0 及以上)。
        case seek(seconds: Double)
        /// 把播放器音量设成 0…100,跟拖歌词窗口的音量条走同一条路(`debug/volume?percent=`)。
        case volume(percent: Int)
        /// 系统音量调大 / 调小一格,跟灵动岛上滚一格滚轮走同一条路(`debug/notch-volume?step=up|down`)。
        case notchVolume(up: Bool)
        /// 设置窗口里搜这个词、打开第一条结果:翻页、切分段、展开抽屉,把那一行高亮并滚进可见区
        /// (`debug/settings-search?q=`)。设置窗口要先开着。
        case settingsSearch(query: String)
        /// 打开推送提醒页「推送渠道」里这个渠道的编辑弹窗,跟点那一行走同一条路(`debug/notify-channel?id=`,没带 id 是第一个)。
        /// 设置窗口要先翻到推送提醒页(`settings/account/bark`)。
        case editNotifyChannel(id: String?)
        /// 账号配置按内存里的样子原样保存一次,跟账号页自动保存走同一条 `ConfigStore.save()`(`debug/config-save`)。
        case saveConfig
        /// 关掉 / 接回一条来源(`debug/knockout?leg=<名字>&on=0|1`,`on=0` 关掉):验证退路撑不撑得住,见 `SourceKnockout`。
        case knockout(leg: SourceKnockout.Leg, on: Bool)
        /// 菜单栏歌词放正中 / 放回图标旁(`center`)、正中放哪几块屏(`screen`:all / auto / 屏幕身份串,同设置页「显示在」),
        /// 以及当作没有刘海、直接压在屏幕正中(`ignoreNotch`,不落盘,App 重启复原):
        /// `debug/menubar-center?center=1&screen=all&ignore-notch=1`,至少带一个。刘海屏的开发机靠它验无刘海屏的摆法。
        /// `hover=1|0`、`click=left|right`:当作指针进出、在正中第一扇正中点了一下(左键 / 右键),不动真鼠标验交互;
        /// 右键弹出的菜单 3 秒后自己收。
        case menuBarCenter(center: Bool?, ignoreNotch: Bool?, screen: String? = nil, hover: Bool? = nil, click: String? = nil)
        /// 菜单栏图标用不用封面(`artwork`)、那一格显示什么(`content`:lyrics / translation / title / titleArtist,同设置页
        /// 「显示内容」四档)、图标大小(`icon-size`:small / standard / large)、图标款式(`icon-style`:
        /// `MenuBarIconStyle` 的 rawValue)、悬停显示播放控制(`hover-controls`)、副行(`secondary`:off / nextLine /
        /// translation / translationInline / romanization,同设置页「副行」五档)、对齐方式(`alignment`:leading / center /
        /// trailing),跟设置页走同一个设置:
        /// `debug/menubar-display?artwork=1&content=title&icon-size=large&icon-style=vinyl&hover-controls=1&secondary=off&alignment=trailing`,
        /// 至少带一个。
        case menuBarDisplay(artwork: Bool?, content: String?, iconSize: String? = nil, iconStyle: String? = nil,
                            hoverControls: Bool? = nil, secondary: String? = nil, alignment: String? = nil)
        /// 日语读音标罗马字还是假名,跟设置页「日语读音」走同一条路(`debug/japanese-reading?style=romaji|kana`)。
        case japaneseReading(JapaneseReadingStyle)
        /// 歌词窗口完整尺寸的「控件大小」,跟设置页走同一个设置(`debug/lyrics-window-controls?size=standard|large|extraLarge`)。
        case lyricsWindowControls(size: LyricsWindowControlSize)
        /// 触控栏「歌词颜色」那一档,跟设置页走同一个设置(`debug/touchbar-display?color=white|cover|custom|rainbow`)。
        case touchBarDisplay(color: TouchBarLyricsColorMode)
        /// 当作键盘焦点在 / 不在输入框里,不看辅助功能读到的(`debug/touchbar-typing?state=on|off|auto`,`auto` = 交还给它)。
        /// 不动用户的焦点验「输入时收起」。nil = auto。
        case touchBarTyping(override: Bool?)
        /// 悬浮歌词、灵动岛、菜单栏的彩虹开关,跟设置页走同一个设置(`debug/rainbow?overlay=0|1&notch=0|1&menubar=0|1`,
        /// 至少带一个)。
        case rainbow(overlay: Bool?, notch: Bool?, menuBar: Bool? = nil)
        /// 菜单栏左键面板的布局,跟面板里「编辑」改的同一个设置(`debug/panel-layout?json=<MenuBarPanelLayout.encoded()>`,
        /// 不带 json 恢复默认)。
        case panelLayout(json: String?)
        /// 菜单栏面板点到外面、切 App、切桌面空间时不自动收起(`debug/panel-pin?on=1`,`on=0` 恢复),不落盘:
        /// 验证脚本得先把窗口提到前台才能拖动,一提前台面板就被当成点到外面收掉了。
        case panelPin(on: Bool)
        /// 在菜单栏面板里从 (x1, y1) 按下、拖到 (x2, y2) 松开(面板窗口内的点坐标,左上角为原点),事件直接送进面板窗口,
        /// 跟手拖走同一条路:`debug/panel-drag?from=205,436&to=350,436`。验证脚本合成的系统鼠标事件进不了这扇面板。
        /// `via=x,y;x,y` 按住不放先依次拖过这几个点再到 `to`(验一次拖动里来回调);`in=gallery` 按在编辑时旁边那块
        /// 「可添加」面板上,坐标按那扇窗算。
        case panelDrag(from: CGPoint, to: CGPoint, via: [CGPoint] = [], inGallery: Bool = false)
        /// 在菜单栏面板里 (x, y) 处点一下(按下、30 毫秒后松开,坐标同 `panelDrag`):`debug/panel-click?at=60,208`。
        /// 格子的点按 / 长按按按住多久分,`panelDrag` 按住约 0.4 秒,会被认成长按。`in=gallery` 同 `panelDrag`。
        case panelClick(at: CGPoint, inGallery: Bool = false)
        /// 主线程原地睡这么多毫秒(`debug/stall?ms=`,1…`maxStallMs`):造出「别的窗口把主线程占住」那一下,验动画扛不扛得住。
        case stall(ms: Int)
        /// 灵动岛摆一次报喜,跟设置页「收听里程碑」旁那颗「试用」走同一条路(`debug/milestone-preview`)。
        case milestonePreview
        /// 灵动岛「暂停时收起」「暂停时隐藏」「进度线」「所有屏幕」「显示歌词」「悬浮淡化」「按音量键时提示」,跟设置页那几项走同一个设置:
        /// `debug/notch-behavior?collapse-when-paused=1&hide-when-not-playing=0&progress-line=off|bottom|ears&all-screens=1&show-lyrics=1&lyric-row-fade=1&volume-key-banner=0`,
        /// 至少带一个。
        case notchBehavior(collapseWhenPaused: Bool?, hideWhenNotPlaying: Bool?, progressLine: NotchProgressLineChoice? = nil,
                           allScreens: Bool? = nil, showLyrics: Bool? = nil, lyricRowFade: Bool? = nil,
                           volumeKeyBanner: Bool? = nil)
        /// 灵动岛「风格」里的「背景」「展开背景」,跟设置页走同两个设置:`debug/notch-style?style=coverArt&expanded=solidBlack|same`
        /// (值是 `NotchCardStyle` 的 rawValue,`same` = 展开背景「同上」),至少带一个。认不认得这个值由 App 判。
        case notchStyle(style: String?, expanded: String?)
        /// 灵动岛展开卡快捷操作的格子,跟「展开时」浮层的编辑区走同一个设置:`debug/notch-quick-actions?layout=close,,settings|favorite`
        /// (`|` 分两行,每行逗号分隔、从**最右一格**数起,空着写空串;值是 `NotchQuickAction` 的 rawValue;`default` = 恢复默认)。
        case notchQuickActions(layout: String)
        /// 设置页灵动岛预览摆成哪一态,不用指针悬停:`debug/notch-preview?state=expanded|collapsed|auto`(`auto` = 交还给指针)。
        case notchPreview(state: String)
        /// 悬浮歌词的宽度(pt,按设置的区间夹取、量化)、「换句动画」、下一句字号占主句的比例(按设置的区间夹取)、长句处理和下一句排法,
        /// 跟设置页走同五个设置:`debug/overlay-layout?width=1270&line-change=0|1&next-line=0.7&overflow=wrap|scroll&next-arrangement=below|alternate`,
        /// 至少带一个。
        case overlayLayout(width: Double?, lineChange: Bool?, nextLine: Double? = nil, overflow: OverlayLineOverflow? = nil,
                           nextArrangement: OverlayNextLineArrangement? = nil)
        /// 把标题为 `title` 的那扇 App 窗口挪到 (x, y):全局坐标、左上角原点(同 `check-windows.swift` 打印的),不改大小、
        /// 不激活。`debug/move-window?title=搜索歌词…&x=-200&y=-1200`:把预览会停表的窗口挪到没被盖住的屏上再录帧。
        case moveWindow(title: String, x: Double, y: Double)
        /// 当作指针停在灵动岛卡片的这一点上(卡片局部坐标,原点左上角),走真指针那一条判区域:落在只显示的那一截就穿透、挖洞
        /// (`debug/notch-pass-through?x=200&y=50`)。不动真鼠标验穿透和洞的位置。
        case notchPassThrough(x: Double, y: Double)
        /// 一直当作指针停在灵动岛卡片的这一点上(卡片局部坐标),不只这一次穿透,直到下面那条交还(`debug/notch-pointer?x=200&y=20`)。
        /// 不动真鼠标验穿透过之后的点击收放(05 章决策 126)。
        case notchPointer(x: Double, y: Double)
        /// 结束上面两条模拟,交还真指针(`debug/notch-pass-through?off=1`)。
        case notchPassThroughOff
        /// 把设置页「逐字歌词格式」那一行摆到换格式的某一步,不真换、不碰歌词文件:
        /// `debug/word-format-switch?state=backup|waiting|converting|finished|queued|idle&format=qrc&done=3214&total=17564`
        /// (`format` 是 `LyricsWordFormat` 的 rawValue,缺省 = 当前主格式;`done` / `total` 只在 converting / finished 时用;
        /// `remove=yrc,qrc` 摆成「删除副本…」那一趟,文案说删除哪几种)。
        case wordFormatSwitch(state: String, format: String?, done: Int?, total: Int?, removing: [String] = [])
        /// 把这几个文件交给「搜索歌词…」窗口导入,跟点「导入文件…」选完文件走同一条路(`debug/import-lyrics?path=<绝对路径>&path=…`)。
        /// 不开窗:窗口没开着时请求留 60 秒,开窗时取走(先 `lyrics-search?background=1`)。
        case importLyrics(paths: [String])
        /// 歌词管理弹「导入歌词文件夹」预览面板,读这个文件夹(`debug/import-lyrics-folder?path=<绝对路径>`)。歌词管理窗口要开着
        /// (先 `lyrics-manager?background=1`)。
        case importLyricsFolder(path: String)
        /// 歌词管理弹「导入库」面板(`debug/import-library`),歌词管理窗口要开着。
        case importLibrary
        /// 设监视文件夹(`debug/import-watch?path=<绝对路径>`),`debug/import-watch?off=1` 停止监视。
        case importWatch(path: String?)
    }

    /// `debug/stall` 的上限(毫秒)。再长就是把 App 卡死了。
    public static let maxStallMs = 2_000

    /// `action/` 下不对应快捷键的那几个名字(跟 `LyrimuseAction.linkName` 不能重名,selftest 核对)。
    public static let extraActionNames = ["copy-lyric", "surfaces", "lyrics-offset", "play-mode"]
    /// `action/play-mode?mode=` 的取值。
    public static let playModeNames: [String: MusicPlaybackController.MusicPlaybackMode] = [
        "list": .list, "shuffle": .shuffle, "repeat-all": .repeatAll, "repeat-one": .repeatOne,
    ]
    /// 歌词时间轴绝对值的上限(毫秒)。再大就不是校准了,链接里写错一位数会把整首歌词错开很远。
    public static let maxLyricsOffsetMs = 10_000

    public init?(url: URL, scheme: String) {
        guard url.scheme?.lowercased() == scheme.lowercased(), let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()
        let trimmedPath = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name.lowercased() == name }?.value }
        switch (host, trimmedPath) {
        case ("settings", _):
            let check = value("check").flatMap(Self.parseBool) ?? false
            self = .settings(path: trimmedPath, checkForUpdates: check)
        case ("lyrics-manager", ""), ("lyrics-manager", "/"):
            self = .lyricsManager
        case ("lyrics-manager", "/song-versions"):
            self = .lyricsManagerSongVersions(key: value("key").flatMap { $0.isEmpty ? nil : $0 },
                                              showEvidence: value("evidence").flatMap(Self.parseBool) ?? false,
                                              compare: value("compare").flatMap { $0.isEmpty ? nil : $0 })
        case ("lyrics-window", ""), ("lyrics-window", "/"):
            self = .lyricsWindow
        case ("lyrics-window", "/search"):
            self = .lyricsWindowSearch
        case ("lyrics-search", ""), ("lyrics-search", "/"):
            self = .lyricsSearch
        case ("lyrics-share", ""), ("lyrics-share", "/"):
            self = .lyricsShare
        case ("whats-new", ""), ("whats-new", "/"):
            self = .whatsNew
        case ("menubar-panel", ""), ("menubar-panel", "/"):
            self = .menuBarPanel(quick: value("quick")?.lowercased())
        case ("menubar-menu", ""), ("menubar-menu", "/"):
            self = .menuBarMenu
        case ("onboarding", ""), ("onboarding", "/"):
            self = .onboarding
        case ("action", "/copy-lyric"):
            self = .copyLyric(includeTranslation: value("translation").flatMap(Self.parseBool) ?? false)
        case ("action", "/surfaces"):
            let overlay = value("overlay").flatMap(Self.parseBool)
            let notch = value("notch").flatMap(Self.parseBool)
            let menuBar = value("menubar").flatMap(Self.parseBool)
            guard overlay != nil || notch != nil || menuBar != nil else { return nil }
            self = .setSurfaces(overlay: overlay, notch: notch, menuBar: menuBar)
        case ("action", "/lyrics-offset"):
            guard let ms = value("ms").flatMap(Int.init), abs(ms) <= Self.maxLyricsOffsetMs else { return nil }
            self = .setLyricsOffset(ms: ms)
        case ("action", "/play-mode"):
            guard let mode = value("mode").flatMap({ Self.playModeNames[$0.lowercased()] }) else { return nil }
            self = .setPlayMode(mode)
        case ("x-callback-url", "/now-playing"):
            self = .nowPlayingCallback(success: value("x-success").flatMap(URL.init(string:)).flatMap {
                Self.isCallbackCandidate($0) ? $0 : nil
            })
        case ("action", _):
            let name = trimmedPath.hasPrefix("/") ? String(trimmedPath.dropFirst()) : trimmedPath
            guard !name.contains("/"), let action = LyrimuseAction(linkName: name) else { return nil }
            let on = action.acceptsTargetState ? value("on").flatMap(Self.parseBool) : nil
            let step = action.acceptsStep
                ? value("step").flatMap(Double.init).flatMap { $0 > 0 && $0 <= LyrimuseAction.maxStepSeconds ? $0 : nil }
                : nil
            self = .action(action, on: on, stepSeconds: step)
        case ("debug", "/snapshot"):
            guard let window = value("window"), !window.isEmpty else { return nil }
            self = .debug(.snapshot(window: window.lowercased()))
        case ("debug", "/state"):
            self = .debug(.state)
        case ("debug", "/telemetry-preview"):
            self = .debug(.telemetryPreview)
        case ("debug", "/checkpoint"):
            self = .debug(.checkpoint)
        case ("debug", "/restore"):
            self = .debug(.restore)
        case ("debug", "/simulate"):
            func seconds(_ name: String) -> Double? {
                value(name).flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            }
            if value("off").flatMap(Self.parseBool) == true {
                self = .debug(.simulateOff)
            } else if value("idle").flatMap(Self.parseBool) == true {
                self = .debug(.simulateIdle)
            } else {
                guard let title = value("title"), !title.isEmpty else { return nil }
                self = .debug(.simulate(
                    title: title, artist: value("artist") ?? "", album: value("album") ?? "",
                    duration: seconds("duration").flatMap { $0 > 0 ? $0 : nil }, position: seconds("position") ?? 0,
                    playing: value("playing").flatMap(Self.parseBool) ?? true, ad: value("ad").flatMap(Self.parseBool) ?? false))
            }
        case ("debug", "/favorite"):
            self = .debug(.toggleFavorite)
        case ("debug", "/idle-resume"):
            self = .debug(.idleResume)
        case ("debug", "/seek"):
            guard let seconds = value("seconds").flatMap(Double.init), seconds.isFinite, seconds >= 0 else { return nil }
            self = .debug(.seek(seconds: seconds))
        case ("debug", "/volume"):
            guard let percent = value("percent").flatMap(Int.init), (0...100).contains(percent) else { return nil }
            self = .debug(.volume(percent: percent))
        case ("debug", "/notch-volume"):
            switch value("step")?.lowercased() {
            case "up": self = .debug(.notchVolume(up: true))
            case "down": self = .debug(.notchVolume(up: false))
            default: return nil
            }
        case ("debug", "/config-save"):
            self = .debug(.saveConfig)
        case ("debug", "/panel-layout"):
            self = .debug(.panelLayout(json: value("json").flatMap { $0.isEmpty ? nil : $0 }))
        case ("debug", "/panel-drag"):
            guard let from = Self.panelPoint(Substring(value("from") ?? "")),
                  let to = Self.panelPoint(Substring(value("to") ?? "")) else { return nil }
            let viaText = (value("via") ?? "").split(separator: ";")
            let via = viaText.compactMap(Self.panelPoint)
            guard via.count == viaText.count else { return nil }
            self = .debug(.panelDrag(from: from, to: to, via: via, inGallery: value("in") == "gallery"))
        case ("debug", "/panel-click"):
            guard let at = Self.panelPoint(Substring(value("at") ?? "")) else { return nil }
            self = .debug(.panelClick(at: at, inGallery: value("in") == "gallery"))
        case ("debug", "/panel-pin"):
            guard let on = value("on").flatMap(Self.parseBool) else { return nil }
            self = .debug(.panelPin(on: on))
        case ("debug", "/stall"):
            guard let ms = value("ms").flatMap(Int.init), (1...Self.maxStallMs).contains(ms) else { return nil }
            self = .debug(.stall(ms: ms))
        case ("debug", "/milestone-preview"):
            self = .debug(.milestonePreview)
        case ("debug", "/import-library"):
            self = .debug(.importLibrary)
        case ("debug", "/import-watch"):
            if value("off").flatMap(Self.parseBool) == true {
                self = .debug(.importWatch(path: nil))
            } else {
                guard let path = value("path"), path.hasPrefix("/") else { return nil }
                self = .debug(.importWatch(path: path))
            }
        case ("debug", "/import-lyrics-folder"):
            guard let path = value("path"), path.hasPrefix("/") else { return nil }
            self = .debug(.importLyricsFolder(path: path))
        case ("debug", "/import-lyrics"):
            let paths = query.filter { $0.name.lowercased() == "path" }.compactMap(\.value).filter { $0.hasPrefix("/") }
            guard !paths.isEmpty else { return nil }
            self = .debug(.importLyrics(paths: paths))
        case ("debug", "/settings-search"):
            guard let query = value("q")?.trimmingCharacters(in: .whitespaces), !query.isEmpty else { return nil }
            self = .debug(.settingsSearch(query: query))
        case ("debug", "/notify-channel"):
            self = .debug(.editNotifyChannel(id: value("id").flatMap { $0.isEmpty ? nil : $0 }))
        case ("debug", "/knockout"):
            guard let leg = value("leg").flatMap({ SourceKnockout.Leg(rawValue: $0.lowercased()) }),
                  let on = value("on").flatMap(Self.parseBool) else { return nil }
            self = .debug(.knockout(leg: leg, on: on))
        case ("debug", "/menubar-center"):
            let center = value("center").flatMap(Self.parseBool)
            let ignoreNotch = value("ignore-notch").flatMap(Self.parseBool)
            let screen = value("screen").flatMap { $0.isEmpty ? nil : $0 }
            let hover = value("hover").flatMap(Self.parseBool)
            let click = value("click").map { $0.lowercased() }
            if let click, click != "left", click != "right" { return nil }
            guard center != nil || ignoreNotch != nil || screen != nil || hover != nil || click != nil else { return nil }
            self = .debug(.menuBarCenter(center: center, ignoreNotch: ignoreNotch, screen: screen, hover: hover, click: click))
        case ("debug", "/menubar-display"):
            let artwork = value("artwork").flatMap(Self.parseBool)
            let content = value("content").flatMap { $0.isEmpty ? nil : $0 }
            let iconSize = value("icon-size").flatMap { $0.isEmpty ? nil : $0 }
            let iconStyle = value("icon-style").flatMap { $0.isEmpty ? nil : $0 }
            let hoverControls = value("hover-controls").flatMap(Self.parseBool)
            let secondary = value("secondary").flatMap { $0.isEmpty ? nil : $0 }
            let alignment = value("alignment").flatMap { $0.isEmpty ? nil : $0 }
            guard artwork != nil || content != nil || iconSize != nil || iconStyle != nil || hoverControls != nil
                    || secondary != nil || alignment != nil else { return nil }
            self = .debug(.menuBarDisplay(artwork: artwork, content: content, iconSize: iconSize, iconStyle: iconStyle,
                                          hoverControls: hoverControls, secondary: secondary, alignment: alignment))
        case ("debug", "/notch-behavior"):
            let collapse = value("collapse-when-paused").flatMap(Self.parseBool)
            let hide = value("hide-when-not-playing").flatMap(Self.parseBool)
            let progressLine = value("progress-line").flatMap { NotchProgressLineChoice(rawValue: $0.lowercased()) }
            let allScreens = value("all-screens").flatMap(Self.parseBool)
            let showLyrics = value("show-lyrics").flatMap(Self.parseBool)
            let lyricRowFade = value("lyric-row-fade").flatMap(Self.parseBool)
            let volumeKeyBanner = value("volume-key-banner").flatMap(Self.parseBool)
            guard collapse != nil || hide != nil || progressLine != nil || allScreens != nil || showLyrics != nil
                    || lyricRowFade != nil || volumeKeyBanner != nil else { return nil }
            self = .debug(.notchBehavior(collapseWhenPaused: collapse, hideWhenNotPlaying: hide, progressLine: progressLine,
                                         allScreens: allScreens, showLyrics: showLyrics, lyricRowFade: lyricRowFade,
                                         volumeKeyBanner: volumeKeyBanner))
        case ("debug", "/move-window"):
            guard let title = value("title"), !title.isEmpty,
                  let x = value("x").flatMap(Double.init), let y = value("y").flatMap(Double.init),
                  x.isFinite, y.isFinite else { return nil }
            self = .debug(.moveWindow(title: title, x: x, y: y))
        case ("debug", "/overlay-layout"):
            let width = value("width").flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let lineChange = value("line-change").flatMap(Self.parseBool)
            let nextLine = value("next-line").flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let overflow = value("overflow").flatMap(OverlayLineOverflow.init(rawValue:))
            let arrangement = value("next-arrangement").flatMap(OverlayNextLineArrangement.init(rawValue:))
            guard width != nil || lineChange != nil || nextLine != nil || overflow != nil || arrangement != nil else { return nil }
            self = .debug(.overlayLayout(width: width, lineChange: lineChange, nextLine: nextLine, overflow: overflow,
                                         nextArrangement: arrangement))
        case ("debug", "/notch-style"):
            let style = value("style").flatMap { $0.isEmpty ? nil : $0 }
            let expanded = value("expanded").flatMap { $0.isEmpty ? nil : $0 }
            guard style != nil || expanded != nil else { return nil }
            self = .debug(.notchStyle(style: style, expanded: expanded))
        case ("debug", "/notch-quick-actions"):
            guard let layout = value("layout") else { return nil }
            self = .debug(.notchQuickActions(layout: layout))
        case ("debug", "/notch-preview"):
            guard let state = value("state"), ["expanded", "collapsed", "auto"].contains(state) else { return nil }
            self = .debug(.notchPreview(state: state))
        case ("debug", "/word-format-switch"):
            guard let state = value("state"), !state.isEmpty else { return nil }
            let nonNegative = { (s: String?) in s.flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil } }
            self = .debug(.wordFormatSwitch(state: state, format: value("format").flatMap { $0.isEmpty ? nil : $0 },
                                            done: nonNegative(value("done")), total: nonNegative(value("total")),
                                            removing: (value("remove") ?? "").split(separator: ",").map(String.init)))
        case ("debug", "/notch-pass-through"):
            if value("off").flatMap(Self.parseBool) == true {
                self = .debug(.notchPassThroughOff)
                break
            }
            guard let x = value("x").flatMap(Double.init), let y = value("y").flatMap(Double.init),
                  x.isFinite, y.isFinite else { return nil }
            self = .debug(.notchPassThrough(x: x, y: y))
        case ("debug", "/notch-pointer"):
            guard let x = value("x").flatMap(Double.init), let y = value("y").flatMap(Double.init),
                  x.isFinite, y.isFinite else { return nil }
            self = .debug(.notchPointer(x: x, y: y))
        case ("debug", "/japanese-reading"):
            guard let style = value("style").flatMap({ JapaneseReadingStyle(rawValue: $0.lowercased()) }) else { return nil }
            self = .debug(.japaneseReading(style))
        case ("debug", "/lyrics-window-controls"):
            guard let raw = value("size")?.lowercased(),
                  let size = LyricsWindowControlSize.allCases.first(where: { $0.rawValue.lowercased() == raw }) else { return nil }
            self = .debug(.lyricsWindowControls(size: size))
        case ("debug", "/rainbow"):
            let overlay = value("overlay").flatMap(Self.parseBool)
            let notch = value("notch").flatMap(Self.parseBool)
            let menuBar = value("menubar").flatMap(Self.parseBool)
            guard overlay != nil || notch != nil || menuBar != nil else { return nil }
            self = .debug(.rainbow(overlay: overlay, notch: notch, menuBar: menuBar))
        case ("debug", "/touchbar-typing"):
            switch value("state")?.lowercased() {
            case "on": self = .debug(.touchBarTyping(override: true))
            case "off": self = .debug(.touchBarTyping(override: false))
            case "auto": self = .debug(.touchBarTyping(override: nil))
            default: return nil
            }
        case ("debug", "/touchbar-display"):
            guard let color = value("color").flatMap({ TouchBarLyricsColorMode(rawValue: $0.lowercased()) }) else { return nil }
            self = .debug(.touchBarDisplay(color: color))
        case ("lastfm-auth-callback", _):
            self = .lastfmAuthCallback
        default:
            return nil
        }
    }

    /// 反向生成链接(「复制链接」、文档清单用),跟 `init(url:scheme:)` 互逆,selftest 逐条往返核对。
    public func url(scheme: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        switch self {
        case let .settings(path, check):
            components.host = "settings"
            components.path = path
            if check { components.queryItems = [URLQueryItem(name: "check", value: "1")] }
        case .lyricsManager:
            components.host = "lyrics-manager"
        case let .lyricsManagerSongVersions(key, showEvidence, compare):
            components.host = "lyrics-manager"
            components.path = "/song-versions"
            var items: [URLQueryItem] = []
            if let key { items.append(URLQueryItem(name: "key", value: key)) }
            if showEvidence { items.append(URLQueryItem(name: "evidence", value: "1")) }
            if let compare { items.append(URLQueryItem(name: "compare", value: compare)) }
            if !items.isEmpty { components.queryItems = items }
        case .lyricsWindow:
            components.host = "lyrics-window"
        case .lyricsWindowSearch:
            components.host = "lyrics-window"
            components.path = "/search"
        case .lyricsSearch:
            components.host = "lyrics-search"
        case .lyricsShare:
            components.host = "lyrics-share"
        case .whatsNew:
            components.host = "whats-new"
        case let .menuBarPanel(quick):
            components.host = "menubar-panel"
            if let quick { components.queryItems = [URLQueryItem(name: "quick", value: quick)] }
        case .menuBarMenu:
            components.host = "menubar-menu"
        case .onboarding:
            components.host = "onboarding"
        case let .action(action, on, step):
            components.host = "action"
            components.path = "/" + action.linkName
            var items: [URLQueryItem] = []
            if let on { items.append(URLQueryItem(name: "on", value: on ? "1" : "0")) }
            if let step { items.append(URLQueryItem(name: "step", value: String(step))) }
            if !items.isEmpty { components.queryItems = items }
        case let .copyLyric(includeTranslation):
            components.host = "action"
            components.path = "/copy-lyric"
            if includeTranslation { components.queryItems = [URLQueryItem(name: "translation", value: "1")] }
        case let .setSurfaces(overlay, notch, menuBar):
            components.host = "action"
            components.path = "/surfaces"
            components.queryItems = [("overlay", overlay), ("notch", notch), ("menubar", menuBar)].compactMap { name, on in
                on.map { URLQueryItem(name: name, value: $0 ? "1" : "0") }
            }
        case let .setLyricsOffset(ms):
            components.host = "action"
            components.path = "/lyrics-offset"
            components.queryItems = [URLQueryItem(name: "ms", value: String(ms))]
        case let .setPlayMode(mode):
            components.host = "action"
            components.path = "/play-mode"
            components.queryItems = [URLQueryItem(name: "mode", value: Self.playModeNames.first { $0.value == mode }?.key)]
        case let .nowPlayingCallback(success):
            components.host = "x-callback-url"
            components.path = "/now-playing"
            if let success { components.queryItems = [URLQueryItem(name: "x-success", value: success.absoluteString)] }
        case let .debug(command):
            components.host = "debug"
            switch command {
            case let .snapshot(window):
                components.path = "/snapshot"
                components.queryItems = [URLQueryItem(name: "window", value: window)]
            case .state: components.path = "/state"
            case .telemetryPreview: components.path = "/telemetry-preview"
            case .checkpoint: components.path = "/checkpoint"
            case .restore: components.path = "/restore"
            case let .simulate(title, artist, album, duration, position, playing, ad):
                components.path = "/simulate"
                components.queryItems = [
                    URLQueryItem(name: "title", value: title), URLQueryItem(name: "artist", value: artist),
                    URLQueryItem(name: "album", value: album),
                ] + (duration.map { [URLQueryItem(name: "duration", value: String($0))] } ?? []) + [
                    URLQueryItem(name: "position", value: String(position)),
                    URLQueryItem(name: "playing", value: playing ? "1" : "0"),
                ] + (ad ? [URLQueryItem(name: "ad", value: "1")] : [])
            case .simulateIdle:
                components.path = "/simulate"
                components.queryItems = [URLQueryItem(name: "idle", value: "1")]
            case .simulateOff:
                components.path = "/simulate"
                components.queryItems = [URLQueryItem(name: "off", value: "1")]
            case .toggleFavorite: components.path = "/favorite"
            case .idleResume: components.path = "/idle-resume"
            case let .seek(seconds):
                components.path = "/seek"
                components.queryItems = [URLQueryItem(name: "seconds", value: String(seconds))]
            case let .volume(percent):
                components.path = "/volume"
                components.queryItems = [URLQueryItem(name: "percent", value: String(percent))]
            case let .notchVolume(up):
                components.path = "/notch-volume"
                components.queryItems = [URLQueryItem(name: "step", value: up ? "up" : "down")]
            case let .settingsSearch(query):
                components.path = "/settings-search"
                components.queryItems = [URLQueryItem(name: "q", value: query)]
            case let .editNotifyChannel(id):
                components.path = "/notify-channel"
                if let id { components.queryItems = [URLQueryItem(name: "id", value: id)] }
            case .saveConfig: components.path = "/config-save"
            case let .panelLayout(json):
                components.path = "/panel-layout"
                if let json { components.queryItems = [URLQueryItem(name: "json", value: json)] }
            case let .panelDrag(from, to, via, inGallery):
                components.path = "/panel-drag"
                func text(_ p: CGPoint) -> String { "\(p.x),\(p.y)" }
                components.queryItems = [URLQueryItem(name: "from", value: text(from)), URLQueryItem(name: "to", value: text(to))]
                if !via.isEmpty { components.queryItems?.append(URLQueryItem(name: "via", value: via.map(text).joined(separator: ";"))) }
                if inGallery { components.queryItems?.append(URLQueryItem(name: "in", value: "gallery")) }
            case let .panelClick(at, inGallery):
                components.path = "/panel-click"
                components.queryItems = [URLQueryItem(name: "at", value: "\(at.x),\(at.y)")]
                if inGallery { components.queryItems?.append(URLQueryItem(name: "in", value: "gallery")) }
            case let .panelPin(on):
                components.path = "/panel-pin"
                components.queryItems = [URLQueryItem(name: "on", value: on ? "1" : "0")]
            case let .stall(ms):
                components.path = "/stall"
                components.queryItems = [URLQueryItem(name: "ms", value: String(ms))]
            case .milestonePreview: components.path = "/milestone-preview"
            case let .importLyrics(paths):
                components.path = "/import-lyrics"
                components.queryItems = paths.map { URLQueryItem(name: "path", value: $0) }
            case let .importLyricsFolder(path):
                components.path = "/import-lyrics-folder"
                components.queryItems = [URLQueryItem(name: "path", value: path)]
            case .importLibrary: components.path = "/import-library"
            case let .importWatch(path):
                components.path = "/import-watch"
                components.queryItems = [path.map { URLQueryItem(name: "path", value: $0) } ?? URLQueryItem(name: "off", value: "1")]
            case let .knockout(leg, on):
                components.path = "/knockout"
                components.queryItems = [URLQueryItem(name: "leg", value: leg.rawValue), URLQueryItem(name: "on", value: on ? "1" : "0")]
            case let .menuBarCenter(center, ignoreNotch, screen, hover, click):
                components.path = "/menubar-center"
                // 逐项 append:同一个表达式里 `+` 串起五个 `map ?? []`,CI 的编译器类型检查超时。
                var items: [URLQueryItem] = []
                if let center { items.append(URLQueryItem(name: "center", value: center ? "1" : "0")) }
                if let ignoreNotch { items.append(URLQueryItem(name: "ignore-notch", value: ignoreNotch ? "1" : "0")) }
                if let screen { items.append(URLQueryItem(name: "screen", value: screen)) }
                if let hover { items.append(URLQueryItem(name: "hover", value: hover ? "1" : "0")) }
                if let click { items.append(URLQueryItem(name: "click", value: click)) }
                components.queryItems = items
            case let .menuBarDisplay(artwork, content, iconSize, iconStyle, hoverControls, secondary, alignment):
                components.path = "/menubar-display"
                var items: [URLQueryItem] = []
                if let artwork { items.append(URLQueryItem(name: "artwork", value: artwork ? "1" : "0")) }
                if let content { items.append(URLQueryItem(name: "content", value: content)) }
                if let iconSize { items.append(URLQueryItem(name: "icon-size", value: iconSize)) }
                if let iconStyle { items.append(URLQueryItem(name: "icon-style", value: iconStyle)) }
                if let hoverControls { items.append(URLQueryItem(name: "hover-controls", value: hoverControls ? "1" : "0")) }
                if let secondary { items.append(URLQueryItem(name: "secondary", value: secondary)) }
                if let alignment { items.append(URLQueryItem(name: "alignment", value: alignment)) }
                components.queryItems = items
            case let .notchBehavior(collapse, hide, progressLine, allScreens, showLyrics, lyricRowFade, volumeKeyBanner):
                components.path = "/notch-behavior"
                var items: [URLQueryItem] = []
                if let collapse { items.append(URLQueryItem(name: "collapse-when-paused", value: collapse ? "1" : "0")) }
                if let hide { items.append(URLQueryItem(name: "hide-when-not-playing", value: hide ? "1" : "0")) }
                if let progressLine { items.append(URLQueryItem(name: "progress-line", value: progressLine.rawValue)) }
                if let allScreens { items.append(URLQueryItem(name: "all-screens", value: allScreens ? "1" : "0")) }
                if let showLyrics { items.append(URLQueryItem(name: "show-lyrics", value: showLyrics ? "1" : "0")) }
                if let lyricRowFade { items.append(URLQueryItem(name: "lyric-row-fade", value: lyricRowFade ? "1" : "0")) }
                if let volumeKeyBanner {
                    items.append(URLQueryItem(name: "volume-key-banner", value: volumeKeyBanner ? "1" : "0"))
                }
                components.queryItems = items
            case let .moveWindow(title, x, y):
                components.path = "/move-window"
                components.queryItems = [URLQueryItem(name: "title", value: title),
                                         URLQueryItem(name: "x", value: String(x)), URLQueryItem(name: "y", value: String(y))]
            case let .overlayLayout(width, lineChange, nextLine, overflow, arrangement):
                components.path = "/overlay-layout"
                var items: [URLQueryItem] = []
                if let width { items.append(URLQueryItem(name: "width", value: String(width))) }
                if let lineChange { items.append(URLQueryItem(name: "line-change", value: lineChange ? "1" : "0")) }
                if let nextLine { items.append(URLQueryItem(name: "next-line", value: String(nextLine))) }
                if let overflow { items.append(URLQueryItem(name: "overflow", value: overflow.rawValue)) }
                if let arrangement { items.append(URLQueryItem(name: "next-arrangement", value: arrangement.rawValue)) }
                components.queryItems = items
            case let .notchStyle(style, expanded):
                components.path = "/notch-style"
                components.queryItems = (style.map { [URLQueryItem(name: "style", value: $0)] } ?? [])
                    + (expanded.map { [URLQueryItem(name: "expanded", value: $0)] } ?? [])
            case let .notchQuickActions(layout):
                components.path = "/notch-quick-actions"
                components.queryItems = [URLQueryItem(name: "layout", value: layout)]
            case let .notchPreview(state):
                components.path = "/notch-preview"
                components.queryItems = [URLQueryItem(name: "state", value: state)]
            case let .notchPassThrough(x, y):
                components.path = "/notch-pass-through"
                components.queryItems = [URLQueryItem(name: "x", value: String(x)), URLQueryItem(name: "y", value: String(y))]
            case let .notchPointer(x, y):
                components.path = "/notch-pointer"
                components.queryItems = [URLQueryItem(name: "x", value: String(x)), URLQueryItem(name: "y", value: String(y))]
            case .notchPassThroughOff:
                components.path = "/notch-pass-through"
                components.queryItems = [URLQueryItem(name: "off", value: "1")]
            case let .wordFormatSwitch(state, format, done, total, removing):
                components.path = "/word-format-switch"
                var items = [URLQueryItem(name: "state", value: state)]
                if let format { items.append(URLQueryItem(name: "format", value: format)) }
                if let done { items.append(URLQueryItem(name: "done", value: String(done))) }
                if let total { items.append(URLQueryItem(name: "total", value: String(total))) }
                if !removing.isEmpty { items.append(URLQueryItem(name: "remove", value: removing.joined(separator: ","))) }
                components.queryItems = items
            case let .japaneseReading(style):
                components.path = "/japanese-reading"
                components.queryItems = [URLQueryItem(name: "style", value: style.rawValue)]
            case let .lyricsWindowControls(size):
                components.path = "/lyrics-window-controls"
                components.queryItems = [URLQueryItem(name: "size", value: size.rawValue)]
            case let .rainbow(overlay, notch, menuBar):
                components.path = "/rainbow"
                var items: [URLQueryItem] = []
                if let overlay { items.append(URLQueryItem(name: "overlay", value: overlay ? "1" : "0")) }
                if let notch { items.append(URLQueryItem(name: "notch", value: notch ? "1" : "0")) }
                if let menuBar { items.append(URLQueryItem(name: "menubar", value: menuBar ? "1" : "0")) }
                components.queryItems = items
            case let .touchBarDisplay(color):
                components.path = "/touchbar-display"
                components.queryItems = [URLQueryItem(name: "color", value: color.rawValue)]
            case let .touchBarTyping(override):
                components.path = "/touchbar-typing"
                components.queryItems = [URLQueryItem(name: "state", value: override.map { $0 ? "on" : "off" } ?? "auto")]
            }
        case .lastfmAuthCallback:
            components.host = "lastfm-auth-callback"
        }
        return components.url
    }

    /// 链接带了 `background=1`(认法同 `on=`):开窗时不激活 App,窗口摆到最前但不抢键盘焦点。只对开窗类有意义,
    /// 别的链接带了也不影响什么。
    public static func wantsBackground(_ url: URL) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.first { $0.name.lowercased() == "background" }?.value.flatMap(parseBool) ?? false
    }

    /// x-callback 的回传地址先按 scheme 挡掉网页、文件、脚本这几类(解析时用):任何网页都能拉起 `lyrimuse://`,回传给
    /// 网页,网页就能读到用户正在听什么。过了这一步还要看本机由谁来开(`isCallbackTarget(_:handler:browsers:)`)。
    public static func isCallbackCandidate(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
        return !nonCallbackSchemes.contains(scheme)
    }

    /// 回传前的最后一道:这个地址本机得有 App 来开(`handler`),而且那个 App 不是浏览器(`browsers` = 能开 http / https
    /// 的那些 App)。浏览器自己的私有 scheme(`x-safari-https` 之类)会被它转成网页打开,按开它的 App 判,不按名单判:
    /// 用户装的自动化工具不用一个个登记。
    public static func isCallbackTarget(_ url: URL, handler: URL?, browsers: Set<URL>) -> Bool {
        guard isCallbackCandidate(url), let handler else { return false }
        return !browsers.contains(handler.standardizedFileURL)
    }

    /// 回传地址不收的 scheme:网页、文件、脚本,和 `lyrimuse` 自己(回传给自己会再触发一次)。
    static let nonCallbackSchemes: Set<String> = [
        "http", "https", "file", "ftp", "javascript", "data", "about", "blob", "lyrimuse",
    ]

    /// 回传时附在 `x-success` 后面的参数(歌名 / 歌手 / 专辑 / 当前这句 / 播放器 / 在不在放)。保留 `x-success` 自带的参数。
    public static func callbackURL(_ base: URL, title: String, artist: String, album: String, lyric: String,
                                   player: String, playing: Bool) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "title", value: title), URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "album", value: album), URLQueryItem(name: "lyric", value: lyric),
            URLQueryItem(name: "player", value: player), URLQueryItem(name: "playing", value: playing ? "1" : "0"),
        ]
        return components.url
    }

    /// `on=` 认 1 / 0、true / false、on / off(大小写不敏感),别的当没带。
    static func parseBool(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "1", "true", "on", "yes": return true
        case "0", "false", "off", "no": return false
        default: return nil
        }
    }
}

extension SettingsDeepLink {
    /// `settings/<页>/<分段>` 里的分段:写进哪个 UserDefaults 键、写什么值(设置页各分段选择器读的就是这几个键)。
    /// 分段名在链接里用小写加连字符(`menu-bar`),存的值是 App 里各 `Section` 枚举的 rawValue(`menuBar`)。
    /// 认不出的分段返回 nil,App 只翻到那一页、停在上次的分段。表里的取值 selftest 对着 App 的枚举逐个核对。
    public struct Section: Equatable, Sendable {
        public let storageKey: String
        public let value: String

        public init(storageKey: String, value: String) {
            self.storageKey = storageKey
            self.value = value
        }
    }

    /// 每一页的分段:链接里的名字 → 存的值。
    public static let sectionTable: [String: (key: String, values: [String: String])] = [
        "lyrics": (SettingsSearchCatalog.lyricsSectionKey,
                   ["fetch": "fetch", "translation": "translation", "display": "display", "manage": "manage",
                    "sources": "fetch", "language": "translation", "timing": "display", "library": "manage"]),
        "player": (SettingsSearchCatalog.playerSectionKey,
                   ["players": "players", "linkage": "linkage", "permissions": "permissions"]),
        "appearance": (LyricsSurface.appearanceSectionStorageKey,
                       ["overlay": "overlay", "notch": "notch", "menu-bar": "menuBar", "touch-bar": "touchBar",
                        "lyrics-window": "lyricsWindow", "web-lyrics": "lyricsWindow", "obs": "overlay"]),
        "account/lastfm": (SettingsSearchCatalog.lastfmSectionKey,
                           ["stats": "stats", "chart": "chart", "on-this-day": "onThisDay", "settings": "settings"]),
        "account/discord": (SettingsSearchCatalog.discordSectionKey,
                            ["display": "display", "buttons": "buttons", "privacy": "privacy"]),
    ]

    /// 路径本身不是一页、去掉最后一段恰好是一页时,返回那一页(`/lyrics/manage` → `/lyrics`;认不出的分段同样翻到那一页,
    /// 见 14 章决策 92);别的原样。给 `init(path:)` 用。
    public static func pagePath(of path: String) -> String {
        var parts = path.lowercased().split(separator: "/").map(String.init)
        guard parts.count >= 2, SettingsDeepLink(path: path) == nil else { return path }
        parts.removeLast()
        let page = "/" + parts.joined(separator: "/")
        return SettingsDeepLink(path: page) == nil ? path : page
    }

    /// 路径里带的分段;没带、或者这一页没有这个分段时是 nil。
    public static func section(in path: String) -> Section? {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        guard parts.count >= 2, let name = parts.last else { return nil }
        let page = parts.dropLast().joined(separator: "/")
        guard let entry = sectionTable[page], let value = entry.values[name] else { return nil }
        return Section(storageKey: entry.key, value: value)
    }
}

extension LyrimuseDeepLink {
    /// 面板调试深链里的一个点:`x,y`(面板窗口内的点坐标)。
    static func panelPoint(_ text: Substring) -> CGPoint? {
        let parts = text.split(separator: ",").compactMap { Double($0) }
        return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
    }
}
