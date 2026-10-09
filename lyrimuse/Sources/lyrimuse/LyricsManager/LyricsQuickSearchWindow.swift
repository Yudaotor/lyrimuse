import SwiftUI
import LyrimuseCore

// 悬浮窗 ⚙ 快捷菜单「搜索歌词…」的独立宿主——"点击只弹出搜索
// 歌词页面,不需要把歌词窗口也拉起"。所以这**不是**复用 LyricsWindowView 那条
// `.sheet(item:)`(那条必须先有一扇开着的歌词窗口才挂得上去),而是自己单独一扇
// `Window(id: "lyrics-quick-search")`(见 App.swift),`LyricsSearchSheet` 直接是这扇窗口
// 的根内容,不再套一层 .sheet()——`LyricsSearchSheet` 内部「关闭」按钮走的
// `@Environment(\.dismiss)`,在 `Window`/`WindowGroup` 场景里一样能把这扇窗口整个关掉
// (SwiftUI 对场景根内容的 dismiss() 就是"关闭这扇窗",不是只对 sheet/popover 有效),不需要
// 额外接一层判断。
//
// 这扇窗口**采纳后不关**(`keepsOpenAfterApply: true`,三个入口里只有它这么传)。
// 它是"边听边换词"的入口:换一个源听两句不对再换,原来得关窗→重开→再等九个源重搜一遍
// (最坏 20 秒);现在同一批候选留在原地,点即切,「当前使用」徽标跟着挪,标题栏给一条
// "已采用 X 的歌词"的回声。另外两个入口(歌词管理的编辑器模态、歌词窗口的 sheet)维持关窗:
// 前者留着会挡住刚回填的编辑器,后者关了才看得到背后的歌词。引擎重启照旧每次采纳排一次
// (`scheduleEngineRestart` 已合并:在飞最多一个、补一次),**刻意不**延后到关窗那一刻 ——
// 重启存在的理由正是引擎内存里还留着旧条目、它下一次落盘会把 App 刚写的盖回去。
//
// 曲目快照逻辑跟 `LyricsWindowView.openLyricsSearch()` 是同一套算法(resolvedKey 精确→
// 宽松两级,缺条目退 normalizedKey),没有抽成公用类型共享——那边多一层"sheet(item:) 的
// 身份即快照、弹窗期间换歌不串"的要求,这边窗口本来就是"每次点『搜索歌词…』都现查一次、
// 开着期间盯着看不跟着换歌重算",两处生命周期不一样,硬凑一个共享类型只会让"谁负责什么"
// 变得含糊。
//
// 上一段"每次新建都现查一次"这半句本身是错的:`Window(id:)` 这扇窗口只要没被真的关掉(只是
// 切到后台/被别的窗口挡住),再点一次「搜索歌词…」只是把已经存在的视图实例带到前台,
// `.task` 只在这个视图**首次挂载**时跑一遍,不会跟着"又点了一次按钮"重跑,`context` 停留
// 在第一次打开时查到的那首歌。修法见 `AppActions.quickSearchRefreshRequests`——每次调用
// `openLyricsQuickSearch` 都往那个 subject send 一下,这里额外 `.onReceive` 它、收到就
// 重新 `loadContext()`,跟 `.task` 各管一段("窗口还没建出来"用 `.task`,"窗口已经开着"用
// `.onReceive`),合起来才是真正的"每次点这个按钮都现查一次"。
// 上一条修法还留了一个问题:`.onReceive` 只替换了 `context`,而 SwiftUI 里
// `if let context { LyricsSearchSheet(...) }` 从 Optional(A) 换成 Optional(B) 保持**同一个视图
// 身份**——面板里的查询词 @State 与首次挂载才跑的 `.task` 都不会重置,屏幕上还是上一首的查询词
// 和候选,而下面 onApply 闭包捕获的已是新 `context.key`:采纳会把上一首的歌词写进当前这首的
// 条目。修在 `LyricsSearchSheet` 内部(按原始字段 `.task(id:)` 重搜 + `.onChange` 重置查询词),
// **刻意不**在这里加 `.id(context.key)` 整棵重建——探针实测重建时新面板的搜索会被旧面板迟到的
// 取消杀掉,详见那边 `.task(id:)` 上方的注释。
// 不像 LyricsWindowView 那边特意 `Task.detached` 到背景线程读 EnrichCacheReader(那扇
// 窗口有 60fps 的逐字填色,主线程哪怕短暂卡顿都会被看见)——这扇窗口只在打开这一瞬间读一次
// 缓存,直接在 MainActor 上做,没有必要为这一次性读多绕一层线程切换。
struct LyricsQuickSearchWindow: View {
    @State private var context: Context?
    /// 上一次重算「当前使用」时缓存文件的修改时间,见下面那条定时器。
    @State private var markedCacheMTime: Date?
    // 切换界面语言时重算 body,窗口标题(.navigationTitle)跟着换。经 AppLanguageObserver 窄代理,不整对象订阅 AppSettings。
    @ObservedObject private var languageSettings = AppLanguageObserver.shared

    private struct Context {
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
                    artist: context.artist, title: context.title, album: context.album,
                    currentSource: context.currentSource, currentFingerprint: context.currentFingerprint,
                    durationSecs: context.durationSecs, keepsOpenAfterApply: true, standaloneWindow: true,
                    isMarkedInstrumental: context.isInstrumental,
                    onSetInstrumental: { value in await EnrichCacheStore.shared.setInstrumental(key: context.key, value) },
                    onAutoMatch: { progress in
                        // 跟歌词管理「重新自动匹配」同一条路;换了词让播放侧立刻重载,「当前使用」随 refreshCurrentMarker 挪过去。
                        let line = await LyricsRematchRunner.run(key: context.key, onProgress: progress)
                        if let line, LyricsRematchRunner.rewroteLyrics(line) {
                            PlaybackCoordinator.shared.refreshLyricsForCurrentTrack()
                        }
                        return line
                    }
                ) { candidate in
                    // 同 LyricsWindowView 的 onApply:saveEdit → 让播放侧立刻重载,不等 2s 轮询的 mtime 检查。
                    // 保存前不用先把整份缓存读进 store:写入由引擎执行(EnrichEditChannel),不经 store 的内存副本;
                    // 歌词管理没开着时先读一遍就是白解析一整份缓存,commit 收尾还会再读一遍。
                    // 不再自己套 Task:面板要等这里回报"落盘成败"再决定挪徽标/回声。
                    let saved: Bool
                    if candidate.isPlainTextOnly {
                        // 这条分流必须按 isPlainTextOnly 走 savePlainTextEdit,跟歌词管理、
                        // 歌词窗口两处保持一致——喂没有时间戳的纯文本直接当 LRC 进 saveEdit,
                        // 后果正是 savePlainTextEdit 头注写的:这首歌在别的展示面上从"至少有
                        // 静态文字"退化成"看起来完全没有歌词"。selftest contracts 组的「采纳候选
                        // 入口」守卫钉住三处同进同出,防止漏改其中一处。
                        saved = await EnrichCacheStore.shared.savePlainTextEdit(
                            key: context.key, plainLyrics: candidate.lyrics, source: candidate.source)
                    } else {
                        // 必须显式传 markManual/sourceChoice,跟 `LyricsManagerView.swift`
                        // 那条「采纳候选」路径保持同一套行为——落进 saveEdit 的默认值是
                        // markManual: true,不传等于这扇小窗每次采纳都悄悄永久冻结这首歌,
                        // 跟"采纳候选不该冻结"这条设计决定不一致。
                        //
                        // sourceChoice 恒传空串(= 显式清掉):关态不留任何源约束,开态靠
                        // manual_lyrics 就够了。完整理由见 LyricsManagerView.swift 那个
                        // 调用点的注释,三处必须同进同出。
                        saved = await EnrichCacheStore.shared.saveEdit(
                            key: context.key,
                            lyrics: candidate.lyrics, tr: candidate.lyricsTr,
                            roma: candidate.lyricsRoma, yrc: candidate.lyricsYRC,
                            source: candidate.source, markManual: AppSettings.shared.manualPickLocksLyrics,
                            sourceChoice: "", fromManualPick: true, bg: candidate.lyricsBG, trLang: candidate.lyricsTrLang)
                    }
                    PlaybackCoordinator.shared.refreshLyricsForCurrentTrack()
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
        // 撑到 52pt,红绿灯才落进搜索面板侧栏的圆角里(面板那一侧见 LyricsSearchSheet.standaloneWindow)。
        .background(EmptyUnifiedToolbar())
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
        // 每拍只是一次 stat。见 11 章决策 97。
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            let mtime = EnrichCacheReader.fileModificationDate
            guard mtime != markedCacheMTime else { return }
            markedCacheMTime = mtime
            refreshCurrentMarker()
        }
        // 窗口标题跟着界面语言走:App.swift 里 Window 的标题只在构造场景时求值一次(同欢迎页)。
        .navigationTitle(L10n.t("搜索歌词…"))
    }

    /// 正在放的还是面板里这首时,按缓存现状重算「当前使用」要的来源、正文指纹和纯音乐标记。换了歌就不动:
    /// 这扇窗口开着期间不跟着换歌(见文件头注),换歌由再点一次「搜索歌词…」那条路接手。
    private func refreshCurrentMarker() {
        guard let old = context else { return }
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
            artist: old.artist, title: old.title, album: old.album, key: old.key,
            currentSource: source, currentFingerprint: fingerprint, durationSecs: old.durationSecs,
            isInstrumental: instrumental)
    }

    private func loadContext() {
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
        // title 传归一化后的,理由跟 LyricsWindowView.openLyricsSearch 同一处注释——两处
        // 曲目快照算法本来就是"同一套"(见本文件头注),这条也要保持一致。
        context = Context(
            artist: artist, title: EnrichCacheKeys.normalizedTitle(title),
            album: LocalPlaybackSource.albumOrListed(album: album, youtubeMusicAlbum: LocalPlaybackSource.shared.youtubeMusicAlbum),
            key: key, currentSource: source, currentFingerprint: fingerprint, durationSecs: durationSecs,
            isInstrumental: cached?.instrumental ?? false)
    }
}
