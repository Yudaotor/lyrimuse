import Foundation

// 跟 AppleMusicPositionClient(同目录,"读"精确播放进度)对称的"写"操作——发指令
// 控制当前选定播放器(PlaybackPlayerPreference.selected,2026-09-01 起可多选)的播放。
//
// 2026-07-29 之前这里无条件发 AppleScript 给"Music"这一个应用,不管当前选的是哪个
// 播放器——QQ 音乐/网易云音乐接入时都没有同步修这一处,导致选了它们之后悬浮窗/全局
// 快捷键的播放/暂停/上一首/下一首按钮全部不生效(AppleScript 发给了根本没在播的
// Music.app),是遗留下来一直没修的坑,这次一起补上。
//
// Apple Music 继续走 AppleScript(复用同一份"自动化"权限,TCC 是按 (发起方 App,
// 目标 App) 这一对整体授权,不是按具体某条 AppleScript 指令单独授权,调用方在真正
// 发指令之前应该自己检查 MusicAutomationPermission,这里不重复做判断)。QQ 音乐/
// 网易云音乐都没有 AppleScript 支持,改发 media-control 的控制指令(实测坐实:
// media-control 的播放控制指令走的是系统级 MediaRemote,对"当前系统认定的 Now
// Playing 焦点"生效,不需要指定具体是哪个 App——跟读取状态那条路径依赖同一个
// "当前是谁在报告"的系统机制,QQ 音乐/网易云音乐被读取路径确认正在播放时,这几个
// 控制指令天然作用在它们身上,不会误控到别的 App)。失败就静默失败(跟
// AppleMusicPositionClient 一样宽松,不是核心路径)。
public enum MusicPlaybackController {
    public static func playPause() {
        dispatch(appleScript: #"tell application "Music" to playpause"#, mediaControlCommand: "toggle-play-pause")
    }

    public static func nextTrack() {
        dispatch(appleScript: #"tell application "Music" to next track"#, mediaControlCommand: "next-track")
    }

    public static func previousTrack() {
        dispatch(appleScript: #"tell application "Music" to previous track"#, mediaControlCommand: "previous-track")
    }

    /// 「喜欢」这件事只有 Apple Music 有——QQ 音乐/网易云音乐没有 AppleScript 支持,
    /// media-control 走的系统级 MediaRemote 也只有播放控制、没有"收藏"这个概念。所以下面
    /// 这两个函数不走 dispatch 的双后端分派,只发 AppleScript;调用方负责先确认当前播放器
    /// 确实是 Apple Music、以及自动化权限已经拿到(跟上面几个动作同一个约定)。
    ///
    /// ⚠️ 属性名在不同 macOS 上不一样。这台 macOS 27 的 Music.app 脚本字典里已经没有
    /// `loved` 了,同一个属性(四字符码都是 `pLov`)改名成了 `favorited`;而更早的系统上
    /// 只有 `loved`。
    /// 订正(2026-08-20 真机实测):这段注释原来断言"字典里不存在的属性会让整段编译失败、
    /// on error 轮不到执行"——那只对 `shuffle enabled` 这类**多词术语**成立;`favorited`/
    /// `loved` 这种单字标识符编译期会被当变量放行,错误留到**运行期**(-2753),`try` 接得住。
    /// 所以 extendedControlsState 的合并脚本能用 try 嵌套一趟搞定双候选;这里的两段式
    /// 调用保留给单项回读路径,行为不变。
    private static let favoritedPropertyNames = ["favorited", "loved"]

    /// 读当前曲目的"喜欢"状态。读不到(不是 Apple Music / 没权限 / 当前没有曲目 / 两个
    /// 属性名都不认)时返回 nil,调用方据此决定要不要显示这个按钮。
    ///
    /// 会阻塞到子进程结束,**不要在主线程调用**。
    public static func favoritedState() -> Bool? {
        for name in favoritedPropertyNames {
            guard let out = runAppleScriptCapturing(
                #"tell application "Music" to get \#(name) of current track"#
            ) else { continue }
            switch out.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "true": return true
            case "false": return false
            default: continue
            }
        }
        return nil
    }

    /// 设置当前曲目的"喜欢"状态。跟上面同一套属性名兜底。
    ///
    /// 返回值 = 指令有没有被接受(osascript 正常退出)。调用方**应该据此决定要不要回读**:
    /// 见 setPlaybackMode 的注释,Music.app 的 getter 会滞后于 setter,写完马上读会读到旧值。
    @discardableResult
    public static func setFavorited(_ value: Bool) -> Bool {
        for name in favoritedPropertyNames {
            if runAppleScriptCapturing(
                #"tell application "Music" to set \#(name) of current track to \#(value)"#
            ) != nil {
                return true
            }
        }
        return false
    }

    /// 把当前曲目加进资料库。Apple Music 专属(调用方约定同 setFavorited:先确认播放器
    /// 是 Apple Music、权限已拿到)。流媒体曲目唯一可行的路 = `duplicate current track
    /// to source 1`(2026-08-22 实机验证:对正在播的订阅曲目成功入库;命令不返回新副本
    /// 的引用,这里也不需要)。个别内容类型在部分系统上要退到 library playlist(用类引用
    /// `library playlist 1`,不能用名字 "Library"——中文系统叫「资料库」),try 兜底一趟。
    /// 2026-08-22 补充实测:来自共享播放列表源的 `shared track` 走 source 1 会报
    /// -10006,由 library playlist 1 兜底接住;曲目已在资料库时整个 duplicate 是
    /// **静默 no-op**(不报错、不产生重复条目)。所以返回 true ≠ 真的新增了 ——
    /// 要确认"点完之后确实在库",用 currentTrackIsInLibrary() 读回。
    ///
    /// 会阻塞到子进程结束,**不要在主线程调用**。
    @discardableResult
    public static func addCurrentTrackToLibrary() -> Bool {
        runAppleScriptCapturing(#"""
        tell application "Music"
            try
                duplicate current track to source 1
            on error
                duplicate current track to library playlist 1
            end try
            return "ok"
        end tell
        """#) != nil
    }

    /// 当前曲目是否已在资料库(只读)。Music 的 AppleScript 对流媒体 current track 没有
    /// "是否在库"的直连属性,按元数据在 library playlist 1 里数匹配是唯一可行路:
    /// 歌名+歌手+专辑(专辑空则退成 歌名+歌手)。专辑参与匹配是为了不把"同曲不同专辑
    /// 版本"误判成已在库 —— AM 自己把它们当两条曲目。whose 子句只认字符串变量,
    /// 不能内联 `name of t`(2026-08-22 实测报 -1728)。
    /// nil = 查不出来(无曲目/权限被拒/超时)。Apple Music 专属;不要在主线程调用。
    public static func currentTrackIsInLibrary() -> Bool? {
        guard let out = runAppleScriptCapturing(#"""
        tell application "Music"
            set t to current track
            set tName to name of t
            set tArtist to artist of t
            set tAlbum to album of t
            if tAlbum is not "" then
                return (count of (every track of library playlist 1 whose name is tName and artist is tArtist and album is tAlbum)) > 0
            end if
            return (count of (every track of library playlist 1 whose name is tName and artist is tArtist)) > 0
        end tell
        """#) else { return nil }
        if out.contains("true") { return true }
        if out.contains("false") { return false }
        return nil
    }

    /// 把当前曲目从资料库删除。匹配口径与 currentTrackIsInLibrary() 完全同一套
    /// (歌名+歌手+专辑,专辑空退两字段),删匹配的第一条 —— delete 作用在 library
    /// playlist 上就是从资料库整个移除(区别于从普通歌单移除)。没匹配时脚本报错→
    /// 返回 false。Apple Music 专属,调用方约定同上;不要在主线程调用。
    @discardableResult
    public static func removeCurrentTrackFromLibrary() -> Bool {
        runAppleScriptCapturing(#"""
        tell application "Music"
            set t to current track
            set tName to name of t
            set tArtist to artist of t
            set tAlbum to album of t
            set matches to {}
            if tAlbum is not "" then
                set matches to (every track of library playlist 1 whose name is tName and artist is tArtist and album is tAlbum)
            end if
            if (count of matches) is 0 then
                set matches to (every track of library playlist 1 whose name is tName and artist is tArtist)
            end if
            if (count of matches) is 0 then error "not in library"
            delete (item 1 of matches)
            return "ok"
        end tell
        """#) != nil
    }

    /// 恢复播放(歌词窗口欢迎态「继续播放」,Apple Music)。⚠️ 裸 `play` 对空队列是
    /// **静默 no-op**(2026-08-22 实测:stopped 态发 play,state 仍 stopped——Music 停播/
    /// 重启后队列是空的,没有"上次上下文"可恢复)。三段式:①裸 play(接住"有队列只是
    /// 停了");②读回仍没在播 → 在资料库找上次播的那首(调用方从 UserDefaults 记录里给)
    /// 直接播,资料库上下文会自然续播后面的歌;③都不行返回 false,调用方兜底激活 App。
    /// 曲名/歌手是外部数据,拼进 AppleScript 前必须转义引号/反斜杠。不要在主线程调用。
    public static func resumePlayback(lastTitle: String?, lastArtist: String?) -> Bool {
        _ = runAppleScriptCapturing(#"tell application "Music" to play"#)
        if let state = runAppleScriptCapturing(#"tell application "Music" to player state as text"#),
           state.contains("playing") {
            return true
        }
        guard let title = lastTitle, !title.isEmpty else { return false }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        var whose = "name is \"\(esc(title))\""
        if let artist = lastArtist, !artist.isEmpty {
            whose += " and artist is \"\(esc(artist))\""
        }
        return runAppleScriptCapturing("""
        tell application "Music"
            play (first track of library playlist 1 whose \(whose))
            return "ok"
        end tell
        """) != nil
    }

    /// Spotify 的「继续播放」:它的 `play` 自带恢复上次上下文(重启后也能续),一条就够。
    /// 首次调用会触发一次对 Spotify 的自动化授权弹窗。不要在主线程调用。
    @discardableResult
    public static func resumeSpotifyPlayback() -> Bool {
        runAppleScriptCapturing(#"tell application "Spotify" to play"#) != nil
    }

    /// 「减少推荐」。UI 里的 Suggest Less 就是老的 Dislike,AppleScript 属性一直叫
    /// `disliked`(iTunes 12.5 起,2026-08-22 实机验证可写)。Apple Music 专属,
    /// 调用方约定同上;不要在主线程调用。
    @discardableResult
    public static func setDisliked(_ value: Bool) -> Bool {
        runAppleScriptCapturing(
            #"tell application "Music" to set disliked of current track to \#(value)"#
        ) != nil
    }

    /// 「减少推荐」当前值(只读,给菜单状态行回显用)。nil = 查不出来。
    /// Apple Music 专属;不要在主线程调用。
    public static func currentTrackDisliked() -> Bool? {
        guard let out = runAppleScriptCapturing(
            #"tell application "Music" to get disliked of current track"#
        ) else { return nil }
        if out.contains("true") { return true }
        if out.contains("false") { return false }
        return nil
    }

    /// 在 Music.app 里定位并选中当前曲目(reveal),顺带把 Music 带到前台 —— 「在 Music
    /// 中显示」。流媒体曲目实测可用(2026-08-22)。Apple Music 专属;不要在主线程调用。
    @discardableResult
    public static func revealCurrentTrack() -> Bool {
        runAppleScriptCapturing(#"""
        tell application "Music"
            reveal current track
            activate
        end tell
        """#) != nil
    }

    /// 播放模式。Music.app 那边是**两个互相独立的属性** —— `shuffle enabled`(布尔)和
    /// `song repeat`(off/one/all)。这里把它们收成用户熟悉的一个三档循环。
    ///
    /// 所有组合都得能读出一档来:用户完全可能绕过我们、直接在 Music.app 里调那两个开关,
    /// 所以 current 是个**全函数**,优先级 单曲循环 > 随机 > 列表循环 > 列表。
    public enum MusicPlaybackMode: String, CaseIterable, Sendable {
        case list
        case shuffle
        case repeatOne
        /// 列表循环(Music.app `song repeat = all`)。2026-08-21 补上:AM 的循环键是三态
        /// 关→全部→单曲,此前这一档被解析塌缩成 list —— 用户在 Music.app 开着整张循环,
        /// 我们的循环键却是灰的,还没法从 UI 点出这一档。
        case repeatAll

        /// 下一档。allowsRepeatOne=false 时跳过「单曲循环」,只在 列表 ↔ 随机 之间倒。
        ///
        /// Spotify 就是这一档:它的 AppleScript 字典里只有 `repeating`(布尔),够不到
        /// repeat-one —— 它 App 内部虽然有三态,脚本接口只暴露开/关。与其让按钮点到一个
        /// 落不了地的档位,不如在这个播放器上就只有两档。
        public func next(allowsRepeatOne: Bool) -> MusicPlaybackMode {
            switch self {
            case .list: return .shuffle
            case .shuffle: return allowsRepeatOne ? .repeatOne : .list
            case .repeatOne: return .list
            // 顺 AM 循环键语义:全部 → 单曲(够不到单曲的播放器直接回列表)。
            case .repeatAll: return allowsRepeatOne ? .repeatOne : .list
            }
        }
    }

    /// 这个播放器支不支持「播放模式 / 音量」这两组扩展控制。
    ///
    /// Apple Music 和 Spotify 都有可写的 AppleScript 属性;QQ 音乐/网易云音乐两个 .app 里
    /// 根本没有 .sdef(不可脚本化),而 media-control 走的系统级 MediaRemote 只有播放控制、
    /// 没有音量和模式的概念 —— 对它们只能不显示这些控件。
    public static func supportsExtendedControls(_ player: PlaybackPlayer) -> Bool {
        player == .appleMusic || player == .spotify
    }

    /// 这个播放器的循环档位里有没有「单曲循环」。见 MusicPlaybackMode.next(allowsRepeatOne:)。
    public static func supportsRepeatOne(_ player: PlaybackPlayer) -> Bool {
        player == .appleMusic
    }

    /// Spotify 的脚本前面都要垫这一句。
    ///
    /// ⚠️ `tell application "Spotify" to …` 只要发出任何命令就会**启动** Spotify —— 一个只用
    /// Apple Music 的用户会被莫名其妙拉起一个播放器。本仓另外两处 Spotify 脚本
    /// (MediaControlClient.spotifyPlayerPosition、collector 的 spotifyPositionScript)开头
    /// 都有同样的守卫,同一个理由。读不到时返回空串,上层解析不出来自然就是 nil。
    private static let spotifyRunningGuard = #"""
        if application "Spotify" is not running then
            return ""
        end if

        """#

    /// 换歌时三项后台回读(喜欢/播放模式/音量)的合并结果。
    public struct ExtendedControlsState {
        public let favorited: Bool?
        public let mode: MusicPlaybackMode?
        public let volume: Int?
        public static let empty = ExtendedControlsState(favorited: nil, mode: nil, volume: nil)
    }

    /// 三项一次脚本读回来(2026-08-20 性能审计):原来换歌要起三个独立的 osascript 子进程
    /// (喜欢那项的属性候选循环最坏还要两趟)+ 三次 TCC 权限检查,合并后一趟搞定。三段
    /// 各自包 try:任何一段读不出来(无曲目/属性名不认/老版本)只是那一段为 "nil",不把
    /// 整个脚本拖垮 —— 语义与三个单项函数各自的失败路径一致。favorited 的
    /// favorited/loved 双候选也折进脚本里(外层 try 失败退内层),不再需要两趟子进程。
    ///
    /// 会阻塞到子进程结束,**不要在主线程调用**。
    public static func extendedControlsState(
        for player: PlaybackPlayer, includeFavorited: Bool
    ) -> ExtendedControlsState {
        let script: String
        switch player {
        case .appleMusic:
            script = #"""
                tell application "Music"
                    set favPart to "nil"
                    try
                        set favPart to ((favorited of current track) as text)
                    on error
                        try
                            set favPart to ((loved of current track) as text)
                        end try
                    end try
                    set modePart to "nil"
                    try
                        set modePart to (shuffle enabled as text) & ";" & (song repeat as text)
                    end try
                    set volPart to "nil"
                    try
                        set volPart to (sound volume as text)
                    end try
                    return favPart & "|" & modePart & "|" & volPart
                end tell
                """#
        case .spotify:
            script = spotifyRunningGuard + #"""
                tell application "Spotify"
                    set modePart to "nil"
                    try
                        set modePart to (shuffling as text)
                    end try
                    set volPart to "nil"
                    try
                        set volPart to (sound volume as text)
                    end try
                    return "nil|" & modePart & "|" & volPart
                end tell
                """#
        case .qqMusic, .netease, .kugou, .auto:
            return .empty
        }
        guard let out = runAppleScriptCapturing(script) else { return .empty }
        let parts = out.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "|")
        guard parts.count == 3 else { return .empty } // 空串 = Spotify 没在跑,也落这里
        var favorited: Bool?
        if includeFavorited {
            // "missing value"/"nil" 等一律当读不出来 —— 与 favoritedState 的 default: continue 同口径。
            if parts[0] == "true" { favorited = true } else if parts[0] == "false" { favorited = false }
        }
        var mode: MusicPlaybackMode?
        switch player {
        case .appleMusic:
            // 与 playbackMode(for:) 的解析同一套优先级:单曲循环 > 随机 > 列表循环 > 列表。
            let m = parts[1].split(separator: ";")
            if m.count == 2 {
                if m[1] == "one" {
                    mode = .repeatOne
                } else if m[0] == "true" {
                    mode = .shuffle
                } else if m[1] == "all" {
                    mode = .repeatAll
                } else {
                    mode = .list
                }
            }
        case .spotify:
            if parts[1] == "true" { mode = .shuffle } else if parts[1] == "false" { mode = .list }
        default:
            break
        }
        return ExtendedControlsState(favorited: favorited, mode: mode, volume: Int(parts[2]))
    }

    /// 读当前播放模式。不是 Apple Music / 没权限 / 读不出来时返回 nil,调用方据此不显示按钮。
    ///
    /// 两个属性一次脚本读回来,不发两趟 —— 每趟都是一个 osascript 子进程。
    ///
    /// 会阻塞到子进程结束,**不要在主线程调用**。
    public static func playbackMode(for player: PlaybackPlayer) -> MusicPlaybackMode? {
        switch player {
        case .appleMusic:
            guard let out = runAppleScriptCapturing(
                #"tell application "Music" to return (shuffle enabled as text) & "," & (song repeat as text)"#
            ) else { return nil }
            let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
            guard parts.count == 2 else { return nil }
            if parts[1] == "one" { return .repeatOne }
            if parts[0] == "true" { return .shuffle }
            if parts[1] == "all" { return .repeatAll }
            return .list
        case .spotify:
            // 只读 shuffling:repeating 是布尔,映射不到「单曲循环」,而它开着与否不该影响
            // 这颗按钮显示的档位(用户可能在 Spotify 里自己开了整张循环,那不是我们这三档
            // 里的任何一档,按「列表」显示才是诚实的)。
            guard let out = runAppleScriptCapturing(
                spotifyRunningGuard + #"tell application "Spotify" to return shuffling as text"#
            ) else { return nil }
            switch out.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "true": return .shuffle
            case "false": return .list
            default: return nil // 空串 = Spotify 没在跑
            }
        case .qqMusic, .netease, .kugou, .auto:
            return nil
        }
    }

    /// 切到某个播放模式。
    ///
    /// ⚠️ 「列表播放」**不**顺手把 `song repeat` 设成 all —— 那是"列表循环",是另一回事,
    /// 用户没要求就把整个资料库改成永远循环下去是多管闲事。这里只保证"不是单曲循环、
    /// 不是随机",repeat 原来是 off 还是 all 一概保留(用户可能在 Music.app 里特意开的)。
    /// 只有从单曲循环切出来时才必须动它,否则读回来还是单曲循环。
    /// 返回值 = 指令有没有被接受。
    ///
    /// ⚠️ **写完不要马上回读**。2026-08-08 实测坐实:`set shuffle enabled to true` 这段脚本
    /// 正常退出、值也确实写进去了,但另起一个进程去 `get shuffle enabled`,250ms 之后读回来
    /// 的仍是旧值(再等一会儿才变)。原来的 cyclePlaybackMode 正是写完就回读,于是那个旧值
    /// 把已经画出来的正确图标又覆盖回去,表现成"点了要过一会儿才变"。
    /// 既然退出码已经能回答"指令被接受了吗",成功时就不必再问 Music.app 一遍。
    @discardableResult
    public static func setPlaybackMode(_ mode: MusicPlaybackMode, for player: PlaybackPlayer) -> Bool {
        switch player {
        case .appleMusic:
            let script: String
            switch mode {
            case .list:
                script = #"""
                    tell application "Music"
                        set shuffle enabled to false
                        if song repeat is one then set song repeat to off
                    end tell
                    """#
            case .shuffle:
                script = #"""
                    tell application "Music"
                        set shuffle enabled to true
                        if song repeat is one then set song repeat to off
                    end tell
                    """#
            case .repeatOne:
                script = #"""
                    tell application "Music"
                        set shuffle enabled to false
                        set song repeat to one
                    end tell
                    """#
            case .repeatAll:
                // 列表循环(2026-08-21 补档):跟 repeatOne 同一个互斥约定 —— 点亮循环就
                // 关掉随机。
                script = #"""
                    tell application "Music"
                        set shuffle enabled to false
                        set song repeat to all
                    end tell
                    """#
            }
            return runAppleScriptCapturing(script) != nil
        case .spotify:
            // 只动 shuffling,`repeating` 一概不碰 —— 跟 Apple Music 分支里"不顺手改
            // song repeat"同一个原则:用户可能在 Spotify 里特意开着整张循环,那是他的设置,
            // 切随机/顺序不该把它顺手关掉。
            guard mode != .repeatOne, mode != .repeatAll else {
                // 走不到:UI 的循环键在 Spotify 上整颗不显示(supportsRepeatOne=false;
                // repeating 布尔虽能写但读不回,乐观态会漂)。万一真被调到,返回 false
                // 让调用方回读纠正,而不是悄悄按别的档执行。
                return false
            }
            return runAppleScriptCapturing(
                spotifyRunningGuard
                    + #"tell application "Spotify" to set shuffling to "#
                    + (mode == .shuffle ? "true" : "false")
            ) != nil
        case .qqMusic, .netease, .kugou, .auto:
            return false
        }
    }

    /// 读 Music.app 自己的输出音量(0~100)。读不到返回 nil —— 跟"喜欢"同一个约定:
    /// 别的播放器没有这个概念,调用方据此不显示这个控件。
    ///
    /// 注意这是**Music.app 的音量**,不是系统音量 —— 跟 Apple Music 自己那个滑杆是同一个
    /// 东西。调它不会影响别的 App 的声音。
    ///
    /// 会阻塞到子进程结束,**不要在主线程调用**。
    public static func soundVolume(for player: PlaybackPlayer) -> Int? {
        let script: String
        switch player {
        case .appleMusic:
            script = #"tell application "Music" to get sound volume"#
        case .spotify:
            // Spotify 的 `sound volume` 也是 0~100 的整数,跟 Music.app 同一个量纲,
            // 上层的滑杆不需要换算。
            script = spotifyRunningGuard + #"tell application "Spotify" to get sound volume"#
        case .qqMusic, .netease, .kugou, .auto:
            return nil
        }
        guard let out = runAppleScriptCapturing(script) else { return nil }
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 设置 Music.app 的输出音量。超出 0~100 会被夹住 —— AppleScript 那边给越界值会报错,
    /// 报错就整条指令不生效,不如在这里夹好。
    @discardableResult
    public static func setSoundVolume(_ value: Int, for player: PlaybackPlayer) -> Bool {
        let v = min(100, max(0, value))
        switch player {
        case .appleMusic:
            return runAppleScriptCapturing(
                #"tell application "Music" to set sound volume to \#(v)"#) != nil
        case .spotify:
            return runAppleScriptCapturing(
                spotifyRunningGuard + #"tell application "Spotify" to set sound volume to \#(v)"#) != nil
        case .qqMusic, .netease, .kugou, .auto:
            return false
        }
    }

    /// 跳到曲目内的某个位置(秒)。跟上面三个动作走同一套双后端分派:Apple Music 用
    /// AppleScript 的 `set player position to`,其余播放器用 media-control 的 `seek`
    /// (实测核实过内置二进制的 `--help` 里有 `seek POSITION` 这个一等命令)。
    ///
    /// 小数位固定截到 3 位:AppleScript 的 player position 和 media-control 都吃浮点秒,
    /// 但直接插值 Double 可能吐出 `2.2000000000000002` 这种科学计数/长尾表示,拼进
    /// AppleScript 源码里不保险。
    ///
    /// 负值夹到 0。上界故意**不**在这里夹——这一层不知道曲目时长(调用方才知道),多传一点
    /// 由播放器自己处理(实测两个后端都只是跳到结尾/切下一首,不会出错),在这里凭猜测夹
    /// 反而会掩盖调用方的计算错误。
    /// preferAppleScript 让调用方按"这一刻实际在播的是谁"覆盖后端选择。设置里选了
    /// "自动识别"(或者选了 Apple Music 以外的其它播放器组合)时
    /// PlaybackPlayerPreference.isExclusivelyAppleMusic 是 false,dispatch 默认会走
    /// media-control;但如果实际在播的就是 Apple Music,那么位置**读**路径走的是精确的
    /// AppleScript 播放头,写路径也该走同一条,两边保持一致。
    public static func seek(toSeconds seconds: Double, preferAppleScript: Bool = false) {
        let value = seekArgument(forSeconds: seconds)
        let script = #"tell application "Music" to set player position to "# + value
        if preferAppleScript {
            runAppleScript(script)
            return
        }
        dispatch(appleScript: script, mediaControlCommand: "seek", mediaControlArguments: [value])
    }

    /// 把秒数格式化成两个后端都吃、且能安全拼进 AppleScript 源码的字符串。抽成独立的纯
    /// 函数是为了能被 lyrimuse-selftest 覆盖——seek 本身要发子进程,测不了。
    ///
    /// 三件事:
    /// ① 固定 3 位小数。直接插值 Double 可能吐出 "2.2000000000000002" 这种长尾表示,
    ///    拼进 AppleScript 源码里不保险。
    /// ② locale 显式固定成 en_US_POSIX。2026-08-05 实测核实过:`String(format:)` **不带**
    ///    locale 参数时本来就不做本地化(输出 "2.200"),只有显式传一个逗号小数点的区域
    ///    (如 de_DE)才会吐 "2,200"。所以这里不是在修一个现存 bug,而是把"必须是点"这个
    ///    要求写死在代码里——这个字符串要拼进 AppleScript 源码,一旦变成逗号就是语法错误,
    ///    不该依赖"默认行为恰好正确"这种隐式前提。
    /// ③ 负值夹到 0。上界故意**不**在这里夹:这一层不知道曲目时长(调用方才知道),多传一点
    ///    由播放器自己处理(跳到结尾/切下一首,不会出错),在这里凭猜测夹反而会掩盖调用方的
    ///    计算错误。
    public static func seekArgument(forSeconds seconds: Double) -> String {
        let clamped = seconds.isFinite ? max(0, seconds) : 0
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), clamped)
    }

    private static func dispatch(appleScript: String, mediaControlCommand: String, mediaControlArguments: [String] = []) {
        if PlaybackPlayerPreference.isExclusivelyAppleMusic {
            runAppleScript(appleScript)
        } else {
            runMediaControl(mediaControlCommand, arguments: mediaControlArguments)
        }
    }

    /// 问播放器要状态的超时上限。
    ///
    /// 正常一次往返约 100ms(实测:Music 90ms / Spotify 101ms)。给到 5 秒纯粹是兜底 ——
    /// 关键在于它**远小于 AppleScript 自己 60 秒的默认超时**:Music.app 一旦无响应
    /// (大曲库、iCloud 同步时并不罕见),没有这道闸就是整条链路停一分钟,表现为悬浮
    /// 歌词莫名其妙不动了。
    static let appleScriptTimeout: TimeInterval = 5

    // ⚠️ 下面两个 runXxx 是**发完就不管**(try? process.run(),不等退出),所以它们不会
    // 卡住调用方,不需要走 ProcessRunner。改成等待反而会把"发一条播放指令"变成一次阻塞。
    private static func runAppleScript(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    /// 跟 runAppleScript 的区别:这个要**等**子进程结束并取回 stdout,失败(非零退出)返回
    /// nil。上面那个是"发完就不管"的写指令,这个给需要读回值、或者需要知道这条脚本到底
    /// 有没有成功的场景用(见 favoritedState/setFavorited 的属性名兜底)。
    ///
    /// 会阻塞到子进程结束,调用方负责别在主线程上调。
    private static func runAppleScriptCapturing(_ script: String) -> String? {
        // stderr 由 ProcessRunner 丢进 nullDevice:属性名不认时 osascript 会往 stderr 打
        // 一段编译错误,那是这里预期内的兜底路径,不该污染 App 自己的日志。
        guard let r = ProcessRunner.run(
            "/usr/bin/osascript", ["-e", script], timeout: appleScriptTimeout),
            r.succeeded
        else { return nil }
        return r.stdoutText
    }

    // 二进制路径解析复用 MediaControlClient.binaryPath()(同目录,读取状态那条路径
    // 也要用这同一个二进制),不重复各写一份。
    private static func runMediaControl(_ command: String, arguments: [String] = []) {
        guard let binaryPath = MediaControlClient.binaryPath() else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = [command] + arguments
        try? process.run()
    }
}
