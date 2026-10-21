import SwiftUI
import LyrimuseCore

// 「搜索歌词…」的独立窗口:悬浮窗 ⚙、菜单栏、快捷键、歌词窗口里的「搜索歌词…」和歌词管理的「搜索候选歌词」都开这一扇
// (`Window(id: "lyrics-quick-search")`,见 App.swift),窗口大小由系统记着,`LyricsSearchSheet` 直接是它的根内容。Esc 走的
// `@Environment(\.dismiss)` 在场景根内容上就是关掉这扇窗口。别的地方别另挂一张 sheet:宿主一多,尺寸和采纳后的行为就各走各的
// (见 11 章决策 130、131)。
//
// 这扇窗口**采纳后不关**:它是"边听边换词"的入口,同一批候选留在原地,点即切,「当前使用」徽标跟着挪,标题栏给一条"已采用 X
// 的歌词"的回声。引擎重启每次采纳照旧排一次(`scheduleEngineRestart` 已合并:在飞最多一个、补一次),不延后到关窗:引擎内存里
// 还留着旧条目,它下一次落盘会把 App 刚写的盖回去。
//
// 搜哪一首:歌词管理开的时候带着选中那首(`AppActions.lyricsSearchTarget`,写回按它的 key),别的入口搜正在放的那首。
// 正在放的那首的写回 key 用缓存里实际命中的那条(`resolvedKey`,精确→宽松两级),播放器报法与缓存写法有空格 / 繁简出入时,
// 写回必须落在读取路径同一条上;缓存里还没有条目(引擎未解析)就退回 normalizedKey 新建。窗口开着期间不跟着换歌。
//
// 每次点「搜索歌词…」都按正在放的那首现查一次:窗口还没建出来时由 `.task` 查;已经开着(只是在后台 / 被挡住)时再点,
// `Window(id:)` 只是把已有的视图带到前台、`.task` 不会重跑,由 `.onReceive(AppActions.quickSearchRefreshRequests)` 重查。
// 换了曲目时 `if let context { LyricsSearchSheet(...) }` 保持同一个视图身份,查询词和候选的重置在 `LyricsSearchSheet` 内部
// (按原始字段 `.task(id:)` 重搜 + `.onChange` 重置查询词);不在这里 `.id(context.key)` 整棵重建 —— 重建时新面板的搜索会被
// 旧面板迟到的取消杀掉,见那边 `.task(id:)` 上方的注释。缓存只在打开那一下读一次,直接在 MainActor 上读。
//
// 窗口看不见时(`windowSurface`,同歌词管理窗口)下面那条查缓存文件修改时间的定时停;面板里预览的停表由面板自己按所在窗口管。
struct LyricsQuickSearchWindow: View {
    @State private var context: Context?
    /// 上一次重算「当前使用」时缓存文件的修改时间,见下面那条定时器。
    @State private var markedCacheMTime: Date?
    // 切换界面语言时重算 body,窗口标题(.navigationTitle)跟着换。经 AppLanguageObserver 窄代理,不整对象订阅 AppSettings。
    @ObservedObject private var languageSettings = AppLanguageObserver.shared
    @StateObject private var windowSurface = SettingsWindowSurface()

    private struct Context {
        /// 正在放的那首(按播放器报的三段算「当前使用」);false = 歌词管理指定的那一首(按 key 算)。
        let followsPlayback: Bool
        let artist: String
        let title: String
        let album: String
        /// 写回用的缓存条目 key(实际命中优先,新建退 normalizedKey)。
        let key: String
        let currentSource: String?
        /// 当前正文的只取词指纹(「当前使用」双判据);没有正文时 nil。
        let currentFingerprint: String?
        let durationSecs: Double
        /// 这首眼下是不是标成了纯音乐(搜索面板里纯音乐按钮和说明条的初值)。
        let isInstrumental: Bool
    }

    var body: some View {
        Group {
            if let context, context.title.trimmingCharacters(in: .whitespaces).isEmpty {
                // 没在播放:拿空歌名去搜只会报错,手动填完再采纳会写进一条没有元数据的空条目。
                ContentUnavailableView(L10n.t("当前无正在播放的歌曲"), systemImage: "music.note",
                                       description: Text(L10n.t("请先播放一首歌曲，再选择「搜索歌词…」")))
                    .frame(minWidth: LyricsSearchSheet.minimumSize.width, minHeight: LyricsSearchSheet.minimumSize.height)
            } else if let context {
                LyricsSearchSheet(
                    artist: context.artist, title: context.title, album: context.album, songKey: context.key,
                    currentSource: context.currentSource, currentFingerprint: context.currentFingerprint,
                    durationSecs: context.durationSecs,
                    isMarkedInstrumental: context.isInstrumental,
                    onSetInstrumental: { value in await EnrichCacheStore.shared.setInstrumental(key: context.key, value) },
                    onAutoMatch: { progress in
                        // 跟歌词管理「重新自动匹配」同一条路;换了词让播放侧立刻重载,「当前使用」随 refreshCurrentMarker 挪过去。
                        let line = await LyricsRematchRunner.run(key: context.key, onProgress: progress)
                        if let line, LyricsRematchRunner.rewroteLyrics(line) {
                            PlaybackCoordinator.shared.refreshLyricsForCurrentTrack()
                        }
                        if let line { AppActions.shared.lyricsSearchRematched.send(.init(key: context.key, line: line)) }
                        return line
                    }
                ) { candidate in
                    // 同 LyricsWindowView 的 onApply:saveEdit → 让播放侧立刻重载,不等 2s 轮询的 mtime 检查。
                    // 保存前不用先把整份缓存读进 store:写入由引擎执行(EnrichEditChannel),不经 store 的内存副本;
                    // 歌词管理没开着时先读一遍就是白解析一整份缓存,commit 收尾还会再读一遍。
                    // 不再自己套 Task:面板要等这里回报"落盘成败"再决定挪徽标/回声。
                    let saved: Bool
                    if candidate.isPlainTextOnly {
                        // 仅纯文本的候选必须走 savePlainTextEdit:喂没有时间戳的纯文本直接当 LRC 进 saveEdit,
                        // 后果正是 savePlainTextEdit 头注写的,这首歌在别的展示面上从"至少有静态文字"退化成
                        // "看起来完全没有歌词"。selftest contracts 组的「采纳候选入口」守卫钉着这条分流。
                        saved = await EnrichCacheStore.shared.savePlainTextEdit(
                            key: context.key, plainLyrics: candidate.lyrics, source: candidate.source)
                    } else {
                        // 必须显式传 markManual / sourceChoice:saveEdit 的默认值是 markManual: true,不传等于每次采纳
                        // 都悄悄永久冻结这首歌。采纳要不要顺带冻结由 `manualPickLocksLyrics` 决定:关 = 之后的自动更新照常
                        // 调整这首歌、不限制源,开 = 定在这份歌词上不动。两种状态都不写 lyrics_source_choice(空串 = 显式
                        // 清掉),别加"记下选了哪个源、自愈只在该源内挑"的中间档:那是一条看不见的约束。直接编辑正文
                        // (歌词管理的「保存修改」)永远置 manual_lyrics,不受这个开关影响。
                        saved = await EnrichCacheStore.shared.saveEdit(
                            key: context.key,
                            lyrics: candidate.lyrics, tr: candidate.lyricsTr,
                            roma: candidate.lyricsRoma, yrc: candidate.lyricsYRC,
                            source: candidate.source, markManual: AppSettings.shared.manualPickLocksLyrics,
                            sourceChoice: "", fromManualPick: true, bg: candidate.lyricsBG, trLang: candidate.lyricsTrLang,
                            trFrom: candidate.lyricsTrFrom)
                    }
                    // 正在放的那首重读歌词由 EnrichCacheStore.commit 收尾时做,这里不再调一次。
                    if saved { AppActions.shared.lyricsSearchApplied.send(context.key) }
                    return saved
                }
            } else {
                // 极短暂的占位——曲目快照是纯内存读取(PlaybackCoordinator 当前值 + 一次
                // 缓存查找),这一帧几乎不可见,但窗口刚建出来时 body 总要先渲染点什么。
                ProgressView()
                    .frame(minWidth: LyricsSearchSheet.minimumSize.width, minHeight: LyricsSearchSheet.minimumSize.height)
            }
        }
        // 标题栏透明、内容铺到顶是场景的 .windowStyle(.hiddenTitleBar)(App.swift);这里再挂一条空工具栏,把标题栏
        // 撑到 52pt,红绿灯才落进搜索面板侧栏的圆角里(面板那一侧见 LyricsSearchSheet.sidebar 顶上让出的那一截)。
        .background(EmptyUnifiedToolbar())
        .background(WindowSurfaceCapture(surface: windowSurface).frame(width: 0, height: 0))
        .task { loadContext() }
        // 窗口没被真关掉(只是切到后台/被挡住)时再点一次「搜索歌词…」,.task 不会重跑——
        // 见 AppActions.quickSearchRefreshRequests 的注释,这里补上"每次点击都重新现查一次"
        // 这条路。
        .onReceive(AppActions.shared.quickSearchRefreshRequests) { loadContext() }
        // 开着期间这首的正文可能被后台换掉(播到时升级、重打分),「当前使用」得跟着挪;
        // 只重算来源和指纹,不重搜、不动查询词。
        .onReceive(PlaybackCoordinator.shared.$allLines.dropFirst()) { _ in refreshCurrentMarker() }
        // 后台换了来源、正文一字不差(两个源给的是同一份)时,播放侧的歌词行不变、上面那条不触发,「当前使用」会一直
        // 认着旧来源 —— 打开面板那一刻引擎刚先用了一个源、随后换成另一个,就会一条都标不上。缓存文件一变就重算一次,
        // 每 2 秒一次 stat,只在窗口看得见时跑;重新看得见时先查一次。见 11 章决策 97。
        .task(id: windowSurface.isVisible) {
            guard windowSurface.isVisible else { return }
            while !Task.isCancelled {
                checkCacheFileChanged()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        // 窗口标题跟着界面语言走:App.swift 里 Window 的标题只在构造场景时求值一次(同欢迎页)。
        .navigationTitle(L10n.t("搜索歌词…"))
    }

    private func checkCacheFileChanged() {
        let mtime = EnrichCacheReader.fileModificationDate
        guard mtime != markedCacheMTime else { return }
        markedCacheMTime = mtime
        refreshCurrentMarker()
    }

    /// 正在放的还是面板里这首时,按缓存现状重算「当前使用」要的来源、正文指纹和纯音乐标记。换了歌就不动:
    /// 这扇窗口开着期间不跟着换歌(见文件头注),换歌由再点一次「搜索歌词…」那条路接手。
    private func refreshCurrentMarker() {
        guard let old = context else { return }
        guard old.followsPlayback else {
            let marker = Self.storedMarker(key: old.key)
            guard marker.source != old.currentSource || marker.fingerprint != old.currentFingerprint
                    || marker.instrumental != old.isInstrumental else { return }
            context = Context(
                followsPlayback: false, artist: old.artist, title: old.title, album: old.album, key: old.key,
                currentSource: marker.source, currentFingerprint: marker.fingerprint, durationSecs: old.durationSecs,
                isInstrumental: marker.instrumental)
            return
        }
        let p = PlaybackCoordinator.shared
        let artist = p.artist, title = p.title, album = p.album
        let key = EnrichCacheReader.resolvedKey(artist: artist, title: title, album: album)
            ?? EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
        guard key == old.key else { return }
        let source = EnrichCacheReader.sourceInfo(artist: artist, title: title, album: album)?.lyricsSource
        let cached = EnrichCacheReader.lookup(artist: artist, title: title, album: album)
        let lyrics = cached?.storedLyrics ?? ""
        let fingerprint = lyrics.isEmpty ? nil : ManualPickLock.fingerprint(lyrics: lyrics)
        let instrumental = cached?.instrumental ?? false
        guard source != old.currentSource || fingerprint != old.currentFingerprint || instrumental != old.isInstrumental
        else { return }
        context = Context(
            followsPlayback: true, artist: old.artist, title: old.title, album: old.album, key: old.key,
            currentSource: source, currentFingerprint: fingerprint, durationSecs: old.durationSecs,
            isInstrumental: instrumental)
    }

    private func loadContext() {
        if let target = AppActions.shared.lyricsSearchTarget {
            let marker = Self.storedMarker(key: target.key)
            context = Context(
                followsPlayback: false, artist: target.artist, title: target.title, album: target.album, key: target.key,
                currentSource: marker.source, currentFingerprint: marker.fingerprint, durationSecs: target.durationSecs,
                isInstrumental: marker.instrumental)
            return
        }
        let p = PlaybackCoordinator.shared
        let artist = p.artist, title = p.title, album = p.album
        let durationSecs = Double(p.currentDurationMs ?? 0) / 1000
        let key = EnrichCacheReader.resolvedKey(artist: artist, title: title, album: album)
            ?? EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
        let source = EnrichCacheReader.sourceInfo(artist: artist, title: title, album: album)?.lyricsSource
        // 「当前使用」双判据要的正文指纹。lookup 走同一份内存缓存,再读一次不贵。
        let cached = EnrichCacheReader.lookup(artist: artist, title: title, album: album)
        let lyrics = cached?.storedLyrics ?? ""
        let fingerprint = lyrics.isEmpty ? nil : ManualPickLock.fingerprint(lyrics: lyrics)
        // title 传归一化后的(EnrichCacheKeys.normalizedTitle),不是原始播放器标题:引擎算缓存 key 时会把标题结尾那种非版本标记的
        // 括号剥掉,传原始标题的话手动搜索跟自动解析一样各个源都搜不到。key / source 两个查找仍然传原始 title,它们各自内部会归一化。
        context = Context(
            followsPlayback: true, artist: artist, title: EnrichCacheKeys.normalizedTitle(title),
            album: LocalPlaybackSource.albumOrListed(album: album, youtubeMusicAlbum: LocalPlaybackSource.shared.youtubeMusicAlbum),
            key: key, currentSource: source, currentFingerprint: fingerprint, durationSecs: durationSecs,
            isInstrumental: cached?.instrumental ?? false)
    }

    /// 指定的那一首此刻的「当前使用」来源、正文指纹和纯音乐标记,按 key 原样从缓存取:lookup 会按正在播放的快照、时长变体去认,
    /// 同名的另一份录音在放时取到的是那一条。指纹取条目里存着的正文,标了纯音乐也照给。别借歌词管理的内存快照
    /// (`EnrichCacheStore.summary`):歌词管理关掉几秒后它就放了,这扇窗口照样开着;两边重读的先后也对不上。
    private static func storedMarker(key: String) -> (source: String?, fingerprint: String?, instrumental: Bool) {
        let stored = EnrichCacheReader.storedEntry(forKey: key)
        let fingerprint = stored.map { ManualPickLock.fingerprint(lyrics: $0.lyrics) }.flatMap { $0.isEmpty ? nil : $0 }
        return (stored?.lyricsSource, fingerprint, stored?.instrumental ?? false)
    }
}

/// 「搜索歌词…」窗口按指定的一首开(歌词管理选中那首):写回的 key,给各源搜的歌名(已去掉时长变体的 `~durN`)、歌手、专辑和时长。
struct LyricsSearchTarget: Equatable {
    let key: String
    let artist: String
    let title: String
    let album: String
    let durationSecs: Double
}

/// 「搜索歌词…」窗口里「重新自动匹配」的结论,带是哪一首(`AppActions.lyricsSearchRematched`)。
struct LyricsSearchRematchResult {
    let key: String
    let line: LyricsRematch.Line
}
