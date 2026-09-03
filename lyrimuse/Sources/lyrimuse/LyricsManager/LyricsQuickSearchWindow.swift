import SwiftUI
import LyrimuseCore

// 悬浮窗 ⚙ 快捷菜单「搜索歌词…」的独立宿主(2026-08-30)——用户明确要求"点击只弹出搜索
// 歌词页面,不需要把歌词窗口也拉起"。所以这**不是**复用 LyricsWindowView 那条
// `.sheet(item:)`(那条必须先有一扇开着的歌词窗口才挂得上去),而是自己单独一扇
// `Window(id: "lyrics-quick-search")`(见 App.swift),`LyricsSearchSheet` 直接是这扇窗口
// 的根内容,不再套一层 .sheet()——`LyricsSearchSheet` 内部"关闭"/"采用此候选"两个按钮走
// 的 `@Environment(\.dismiss)`,在 `Window`/`WindowGroup` 场景里一样能把这扇窗口整个关掉
// (SwiftUI 对场景根内容的 dismiss() 就是"关闭这扇窗",不是只对 sheet/popover 有效),不需要
// 额外接一层判断。
//
// 曲目快照逻辑跟 `LyricsWindowView.openLyricsSearch()` 是同一套算法(resolvedKey 精确→
// 宽松两级,缺条目退 normalizedKey),没有抽成公用类型共享——那边多一层"sheet(item:) 的
// 身份即快照、弹窗期间换歌不串"的要求,这边窗口本来就是"每次点『搜索歌词…』都现查一次、
// 开着期间盯着看不跟着换歌重算",两处生命周期不一样,硬凑一个共享类型只会让"谁负责什么"
// 变得含糊。
//
// ⚠️ 2026-08-31 真实bug(用户报"已经切歌了,点开搜索页面看到的还是上一首"):上一句里
// "每次新建都现查一次"这半句本身就是错的——`Window(id:)` 这扇窗口只要没被真的关掉(只是
// 切到后台/被别的窗口挡住),再点一次「搜索歌词…」只是把已经存在的视图实例带到前台,
// `.task` 只在这个视图**首次挂载**时跑一遍,不会跟着"又点了一次按钮"重跑,`context` 停留
// 在第一次打开时查到的那首歌。修法见 `AppActions.quickSearchRefreshRequests`——每次调用
// `openLyricsQuickSearch` 都往那个 subject send 一下,这里额外 `.onReceive` 它、收到就
// 重新 `loadContext()`,跟 `.task` 各管一段("窗口还没建出来"用 `.task`,"窗口已经开着"用
// `.onReceive`),合起来才是真正的"每次点这个按钮都现查一次"。
// ⚠️ 2026-09-02 第二个真实bug(由上一条修法引出):`.onReceive` 只替换了 `context`,而 SwiftUI 里
// `if let context { LyricsSearchSheet(...) }` 从 Optional(A) 换成 Optional(B) 保持**同一个视图
// 身份**——面板里的查询词 @State 与首次挂载才跑的 `.task` 都不会重置,屏幕上还是上一首的查询词
// 和候选,而下面 onApply 闭包捕获的已是新 `context.key`:采纳会把上一首的歌词写进当前这首的
// 条目。修在 `LyricsSearchSheet` 内部(按原始字段 `.task(id:)` 重搜 + `.onChange` 重置查询词),
// **刻意不**在这里加 `.id(context.key)` 整棵重建——探针实测重建时新面板的搜索会被旧面板迟到的
// cancelRunning() 杀掉,详见那边 `.task(id:)` 上方的注释。这个文件的代码没有变,只有这条说明。
// ⚠️ 不像 LyricsWindowView 那边特意 `Task.detached` 到背景线程读 EnrichCacheReader(那扇
// 窗口有 60fps 的逐字填色,主线程哪怕短暂卡顿都会被看见)——这扇窗口只在打开这一瞬间读一次
// 缓存,直接在 MainActor 上做,没有必要为这一次性读多绕一层线程切换。
struct LyricsQuickSearchWindow: View {
    @State private var context: Context?

    private struct Context {
        let artist: String
        let title: String
        let album: String
        /// 写回用的缓存条目 key(实际命中优先,新建退 normalizedKey)。
        let key: String
        let currentSource: String?
        let durationSecs: Double
    }

    var body: some View {
        Group {
            if let context {
                LyricsSearchSheet(
                    artist: context.artist, title: context.title, album: context.album,
                    currentSource: context.currentSource, durationSecs: context.durationSecs
                ) { candidate in
                    Task {
                        // 同 LyricsWindowView 的 onApply 三步:reload 兜"store 还没加载过"
                        // (空 raw 上 saveEdit 会把条目其它字段如 cover_url 整个丢掉)→
                        // saveEdit → 让播放侧立刻重载,不等 2s 轮询的 mtime 检查。
                        //
                        // ⚠️ 2026-09-01 真实bug修复:这里原来一直没传 markManual/sourceChoice,
                        // 落进 saveEdit 的默认值 markManual: true——跟 LyricsManagerView.swift
                        // 那条「采纳候选」路径不是同一套行为,等于这扇小窗每次采纳都在悄悄
                        // 永久冻结这首歌,跟 2026-08-22 那次"采纳候选不该冻结"的设计决定
                        // 不一致——补齐,让两个入口保持同一套逻辑。
                        //
                        // sourceChoice 恒传空串(= 显式清掉):关态不留任何源约束,开态靠
                        // manual_lyrics 就够了。完整理由见 LyricsManagerView.swift 那个
                        // 调用点的注释,两处必须同进同出。
                        await EnrichCacheStore.shared.reload(onlyIfChanged: true)
                        await EnrichCacheStore.shared.saveEdit(
                            key: context.key,
                            lyrics: candidate.lyrics, tr: candidate.lyricsTr,
                            roma: candidate.lyricsRoma, yrc: candidate.lyricsYRC,
                            source: candidate.source, markManual: AppSettings.shared.manualPickLocksLyrics,
                            sourceChoice: "", fromManualPick: true)
                        PlaybackCoordinator.shared.refreshLyricsForCurrentTrack()
                    }
                }
            } else {
                // 极短暂的占位——曲目快照是纯内存读取(PlaybackCoordinator 当前值 + 一次
                // 缓存查找),这一帧几乎不可见,但窗口刚建出来时 body 总要先渲染点什么。
                ProgressView().frame(minWidth: 720, minHeight: 480)
            }
        }
        .task { loadContext() }
        // 窗口没被真关掉(只是切到后台/被挡住)时再点一次「搜索歌词…」,.task 不会重跑——
        // 见 AppActions.quickSearchRefreshRequests 的注释,这里补上"每次点击都重新现查一次"
        // 这条路。
        .onReceive(AppActions.shared.quickSearchRefreshRequests) { loadContext() }
    }

    private func loadContext() {
        let p = PlaybackCoordinator.shared
        let artist = p.artist, title = p.title, album = p.album
        let durationSecs = Double(p.currentDurationMs ?? 0) / 1000
        let key = EnrichCacheReader.resolvedKey(artist: artist, title: title, album: album)
            ?? EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
        let source = EnrichCacheReader.sourceInfo(artist: artist, title: title, album: album)?.lyricsSource
        // title 传归一化后的,理由跟 LyricsWindowView.openLyricsSearch 同一处注释——两处
        // 曲目快照算法本来就是"同一套"(见本文件头注),这条也要保持一致。
        context = Context(
            artist: artist, title: EnrichCacheKeys.normalizedTitle(title), album: album,
            key: key, currentSource: source, durationSecs: durationSecs)
    }
}
