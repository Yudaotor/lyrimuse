# 11. 歌词管理窗口

> 最后核对：2026-09-02 · 基线：e103532+工作树

## 定位

已缓存歌词的管理台：浏览/筛选全部缓存条目，编辑、删除、按算法重新自动匹配、联网重搜候选、查看当初的解析决策，以及歌词文件夹的落点管理。

## 入口与展示面

- 菜单栏菜单「歌词管理…」、全局快捷键 `openLyricsManagerHotkey`、设置 → 歌词 → 管理段「打开…」。
- SwiftUI `Window(id: "lyrics-manager")`；accessory 策略下打开前必须 `NSApp.activate`。

## 行为规格

### 1. 列表与筛选

- 五列表头：歌名/歌手/专辑/来源/偏移（来源列中文名：网易云音乐/QQ音乐/酷狗音乐，LRCLIB/Musixmatch 保留英文；色点=来源身份色，与设置页「歌词来源」同一套 `sourceColor`）。
- 列宽可拖并持久化（`LyricsColumnWidthsStore`：@Published+didSet 落 UserDefaults，夹值算术是纯函数、selftest 覆盖）。拖动中只更新内存值（beginDragging/endDragging，2026-08-19），松手一次性落盘——原来每个鼠标事件写三笔 UserDefaults 中间态。**「偏移」列不在这套拖拽系统里**（2026-08-26）：固定宽度（`LyricsManagerView.offsetColumnWidth`，56pt），不挂分隔条，不进 `LyricsColumnWidths`——一个纯展示的数字列没必要扩那套本来就最容易出错的夹值算术。它仍然算进 `headerChrome`（4 条 8pt 间距 + 固定宽度，原来是 3 条），否则 `fitted`/`dragged` 算歌名列剩余空间时会把这一列的宽度算漏，实际渲染出来的歌名会比算出来的更窄。
- 「偏移」列显示这份歌词当前的时间轴校正值（`AppSettings.signedSeconds(ms:)`，"+0.5"/"-0.3"风格，语义与详情页「歌词时间轴偏移」旁边那句「正数=提前显示，负数=延后显示」一致）。值来自 `Summary.offsetMs`，在 `EnrichCacheStore.buildSummaries` 里按 `LyricsOffsetStore.trackKey(artist:title:lyrics:lyricsYRC:)` 查一份 `LyricsOffsetStore.offsetsSnapshot`（新增的只读快照访问器）算出来——`buildSummaries` 要能在 `reload()` 的后台线程跑，不能在函数体内部同步访问那个 `@MainActor` 单例，所以快照必须在调用方（MainActor 上下文）先取好再传进去。详情页调过/重置过偏移之后，`applyOffsetEdit`/`resetOffsetEdit` 会显式调一次 `EnrichCacheStore.rebuildSummaries()`（原为 private，2026-08-26 开放）刷新这一列——偏移改在 `LyricsOffsetStore` 里，不是 `raw` 字典，不会自动触发 summaries 重建。⚠️ 从菜单栏「歌词时间轴」（边听边点着调）调整当前播放曲目的偏移不会触发这次刷新（那条路径不知道这个窗口的存在），列表要等下一次自然 reload（开窗/激活/手动刷新）才会看到新值——跟这一列本身一样，是个可接受的"最终一致"，不是 bug。
- 「仅人工修正」筛选（2026-08-26 起）**并入「已校准」**：判定条件从单纯 `isManual` 扩成 `isManual || LyricsPinStore.isPinned(key)`。理由：`manual_lyrics`（人工改过歌词正文）和「已校准」（人工调过时间轴偏移）在语义上本来就并列——都是"用户已经亲手把这首歌弄对了，后台别再自作主张"（详情页两个徽章分开显示，但都对应"这首歌被人工介入过"这同一件事），分开筛选只会让用户漏看那些只调过时间轴、没碰过歌词正文的行。`filtered` 的结果缓存(`filteredCache`,按 `(filterToken, summariesGeneration)` 记忆化)不需要额外为 pins 的变化开一个新失效键——`rebuildSummaries()` 每次被调都会让 `summariesGeneration` 自增,而偏移/校准状态的唯一改动入口(`applyOffsetEdit`/`resetOffsetEdit`)已经显式调了它,连带把这份缓存也标脏。
- 筛选：文本搜索 + 歌手/专辑下拉（归并键=toSimplified+小写，繁简/大小写不敏感）。搜索框（`searchable(prompt: "搜索歌手/歌名/专辑")`）按子串匹配四个小写副本：原始歌手写法、展示歌手名（`canonicalArtist` 优先）、歌名、**专辑名**（`searchAlbumLower`，2026-08-26 加）——四选一命中即算过滤通过。专辑名搜索跟专辑下拉框不是一回事：下拉是"选一个精确专辑名"，搜索框是"打几个字模糊找"，两者互补，不是互斥关系。**性能口径（2026-08-19 审计落地）**：繁简归一化键/搜索小写副本在 `Summary` 构建时预存（`normPrimaryArtist`/`normAlbum`/`search*Lower`），排序比较器只做元组比较；歌手/专辑归并展示名与下拉候选下沉进 store 随 summaries 重建一次（原来是视图计算属性，List 每物化一行就全量重建一次 O(N) 归并字典）；`filtered` 经缓存盒按 (filterToken, summariesGeneration) 记忆化（一次 body 被 4~5 处独立求值）；`toSimplified` 本体按原串 memoize。summaries 的构建+排序在 reload 的后台 task 里做，主线程只收结果。**搜索不是逐字符触发（2026-08-27 起）**：`searchText`（`.searchable` 绑定，随打字实时变）与 `committedSearchText`（真正喂给 `filtered`/`filterToken` 的那份）拆成两个 `@State`，只有点搜索框左边那颗放大镜按钮（`commitSearch()`）或在搜索框按回车（`.onSubmit(of: .search)`）才会把前者同步进后者；清空搜索框（叉号或删完）例外，立刻同步成空串不用等触发——这个方向零过滤开销，用户体验上也不该"卡在上一次的搜索结果里"。见「设计决策」第 16 条。
- **排序**（2026-09-01，用户要求"加一个排序功能"，选的是"筛选栏加一个下拉"而不是点列表头排序）：`LyricsSortOption`，筛选栏「歌手」「专辑」下拉右边新增的「排序」下拉，**十一选一**——「默认排序」（改动前那套写死的 (歌手,专辑,歌名) 固定排序，不是新行为，只是第一次开放成可以主动切走/切回来的选项）+ 歌名/歌手/专辑/来源各自的 A→Z、Z→A + **更新时间 新→旧 / 旧→新**（当天晚些补上，见下）。只有点名的那个字段会因方向反转，没点名的次序键恒按升序断平局（跟 Finder"按修改时间降序仍按文件名升序断平局"同一个道理，不会把整条元组一起倒过来）。⚠️ 歌手/专辑排序用的是跟「默认排序」同一套归一化键（`normPrimaryArtist`/`normAlbum`，折简体+小写），不是列表里实际展示的原始写法——理由跟 2026-08-28 那条"筛选/排序按统一名归并、只有展示列如实展示原始写法"一致，同一位歌手因原始标签写法不同（简繁/大小写）被拆成两条记录时，按归一化键排还能让它们挨在一起。来源排序用 `sourceDisplayName(_:)`（跟「来源」列徽章同一份映射），不是原始的 `lyrics_source` 字符串。**「更新时间」两档 2026-09-01 晚补上**（用户点名要）。第一版注释写着"没有这个候选，`Summary` 没有任何时间戳字段，硬凑得先扩缓存模型"——**结论对、理由不全**：缓存里确实没有一个表达「更新时间」的字段（实测本机 3212 条的覆盖率：`lyrics_decision.decided_at` 73%、`translation_ts` 25%、`peripheral_ts` 9%、`lyrics_rescore_ts` 7%，全是偏科的局部时间戳，而 `decided_at` 还只反映「上次自动决策」、手改歌词根本不动它），但**不需要扩缓存格式**。
  - **信号取自导出歌词文件的 mtime**（`Summary.lyricsUpdatedAt`）：`lyrics/` 是六字段的权威源，**所有**写入路径都经过它（collector 的 `exportLyricsFiles`、App 的 `saveEdit`→`writeLyricsFiles`），所以手改也算得进去。取 `.lrc`/`.tr.lrc`/`.roma.lrc`/`.yrc` 四个里**最新**的那个——译文/罗马音后来补上也是这条记录真的变了。
  - ⚠️ **成立的关键前提**：`exportLyricsFiles` 写盘前会比对全文、逐字节相同就 `continue`（`lyricsexport.go`），所以 mtime 不会被「每次 collector 启动重写一遍」冲平。实测本机 mtime 散布在 08-22～09-01 而不是全挤在最近一次重启，坐实了这一点。**哪天那个跳过逻辑被去掉，这个字段就集体失真（全变成最后一次启动时间），而且表现是静默的**——排序看着还在工作，只是结果全错。
  - **实现避开了两个坑**：① 不逐条推文件名去 stat——`exportBaseName` 每次调用都扫全 `raw.keys`，逐条用就是 O(n²)；改成**一次目录枚举**建「折叠小写基名 → 最新 mtime」的 map（实测 7231 个文件全 stat 一遍 23ms，这条更省且只做一次），每条做两次 O(1) 查找（普通名 + 带哈希的消歧名）。② 后缀匹配必须**从长到短**：`.tr.lrc` 也以 `.lrc` 结尾，先撞上 `.lrc` 会把基名切成 `xxx.tr`、跟主文件分成两组。
  - **`lyricsDir` 走参数传入**，跟既有的 `offsetsSnapshot` 同一个理由：它读 `FeatureSettingsStore.shared`（MainActor），调用方取好传进来，目录枚举那段 I/O 留在 `buildSummaries` 里后台跑。
  - **没有时间的条目两个方向都排最后**，不是当成"最早"。"旧→新"里把它们塞最前技术上说得通（未知≈很久以前），但用户按更新时间排是想看「最近动过什么／最久没动过什么」，一串没歌词的空行占住开头对这两个问题都没有回答（同 Finder 把无日期项收在末尾）。
  - **真实数据验证**（临时往 selftest 塞了个诊断块、跑完删掉，因为 `EnrichCacheKeys` 在 LyrimuseCore、selftest 链得到，用真函数验避免重写一遍推导逻辑造成偏差）：3212 条里普通名命中 **3166**、消歧名命中 **4**（说明第二次查找不是死代码）、**有歌词的条目 0 未命中**、42 条未命中全是没歌词的（export 本来就跳过）。`sortOption` 是纯 `@State`（不持久化，重开窗口回到「默认排序」），也**不**并进 `filterToken`——排序不改变"看得见哪些"，只改变"看到的顺序"，跟筛选状态是两个维度。数据流是 `sortedFiltered = sortOption.sorted(filtered)`：`filtered` 那份按 `(filterToken, summariesGeneration)` 记忆化的缓存盒维持不变，排序在它之上再包一层、不额外开缓存（比较的都是预算好的归一化字段，一次 body 里被求值 2~3 遍的成本可以忽略，不值得为它单独维护 token/generation）。List 数据源、`orderedVisibleKeys`（删除计划的显示顺序）两处从 `filtered` 换成 `sortedFiltered`；`selectableFiltered`（全选计数）和 `.onChange(of: filterToken)` 里收敛 `selectedKeys` 那处不涉及顺序，留用 `filtered` 不变。
- 「回到当前播放」：`focusCurrentlyPlaying` 滚动定位到正在播的条目——**三个触发点**：开窗时自动跑一次（`pendingAutoFocus` 闸 + `onDisappear` 复位）、工具栏按钮手动跑、**窗口开着期间换歌自动跑一次**（2026-08-25 加，见下条）。⚠️ 匹配用的 key **必须**走 `EnrichCacheKeys.normalizedKey`（Swift 侧缓存 key 的唯一构造点，逐字节镜像 collector 的 `enrichKey`），不能手拼 `artist|title|album`：手拼会漏掉 `cleanTag`（各类空格/零宽字符）和 `normalizedTitle`（循环剥结尾括号副题）两道清洗。2026-08-20 用户报「进歌词管理不会自动定位」就是这条：Apple Music 报 `Dynasties and Dystopia (from the series Arcane League of Legends)`，缓存里那条 key 是剥掉副题的 `Dynasties and Dystopia`——精确匹配落空，而 `looseKey` 只折大小写/空格/繁简、折不掉副题，兜底也接不住，函数**静默返回**（设计如此：开窗自动定位不该弹提示），表现成压根没定位。现在的候选顺序是 归一化 key → 原样拼的 key（key 归一化上线前入库的老条目）→ 两者各自的 `looseKey`。悬浮窗/灵动岛一直没这个问题，因为 `EnrichCacheReader` 本来就走 `normalizedKey`。
- **窗口开着期间换歌不会自动跟着高亮**（2026-08-25 用户报，已修）：原来只在开窗那一刻和点「回到当前播放」按钮时定位一次，窗口开着期间换歌高亮不会动，看起来像是"卡在开窗那一刻播的那首"。修法是 `LyricsManagerNowPlayingObserver`——只转发 `PlaybackCoordinator.artist/title/album` 这三个"换歌才变一次"的属性、去重合成一个签名串，`LyricsManagerView` 用 `.onChange(of:)` 订阅这个签名串再跑一次 `focusCurrentlyPlaying`。⚠️ 不能整对象订阅 `PlaybackCoordinator`：那个单例同时发布 `currentLine`/`anchor`，播放中每秒 20 次刷新，整对象订阅会把这个窗口的 body 拖进 20Hz 重渲染（跟 `AppLanguageObserver` 转发 `appLanguage` 是同一个窄代理套路，同一段顶部注释里能看到理由）。这个 `.onChange` 必须挂在 `ScrollViewReader { scrollProxy in ... }` 闭包**内部**（`focusCurrentlyPlaying` 要用 `scrollProxy`）——`NavigationSplitView` 外层那条修饰符链（`.frame`/`.background`/几个 `.confirmationDialog`）已经出了 `scrollProxy` 的可见范围,挂错层会直接编译报错「cannot find 'scrollProxy' in scope」（实测踩过一次）。
- **首次搜索期间也能看到这首歌（占位行，2026-08-27）**：collector 只在 `resolveEnrichAsync` 拿到至少一项结果（封面/歌词/链接任一非空）后才会把这个 key 写进缓存文件（第 09 章）——一首歌**第一次播放、还在联网搜索**这段窗口期，缓存文件里压根没有这个 key，而这份列表只读这份文件，所以那段时间里这首歌在「歌词管理」里彻底不可见（2026-08-27 用户报「一首歌还在首次歌词搜索的时候，去歌词管理页面是看不到那条记录的」）——是「有但没显示」之外的另一种情况：条目本身还不存在。修法刻意不去动 collector 那边「只在有结果时才写盘」的数据完整性约定（引入"占位/真实"两套生命周期共存在同一份持久化文件里，代价远大于收益），完全在 Swift 侧解决：`LyricsManagerView.refreshPlaceholder()` 拿当前播放曲目现造一条**不落盘、不进 `raw`**的合成 `Summary`（`isSearching: true`），在开窗、换歌（`.onChange(of: nowPlaying.trackSignature)`）、以及每 5 秒轮询（`EnrichCacheStore.hasEntry(forKey:)` 探测 collector 是否已经写出真实结论，`onlyIfChanged` 门控避免文件没变也整份重解析）三个时机调用——真实条目一出现，占位行立刻让位，不需要手动刷新。占位行的标记徽章（人工修正/逐字/译文/罗马音）**全部隐去**（2026-08-28 之前是一个转圈的 `ProgressView`，用户反馈"有文字体现就够了，不用再加一个转圈"——下面副标题那行的「搜索歌词中…」已经说明白了状态），「无歌词」那一行换成中性的「搜索歌词中…」（不能沿用 `!hasLyrics` 分支——占位行的 `hasLyrics`/`isInstrumental` 都是默认值 `false`，会显示成刺眼的红色「无歌词」，那是"确认没有"的结论，跟"还没查完"是两件事），来源/偏移两列留白（`SourceBadge("")`/`"0.0"` 同样会被误读成"已查清楚、结果是空/零"）。占位行不计入「全选」/搜索结果计数（`selectableFiltered`，过滤掉 `isSearching`）、不出现在多选删除的候选里（`orderedVisibleKeys` 同样过滤）——它不对应 `raw` 里任何 key，编辑/删除/重新自动匹配这些操作对它都没有意义；即便如此，`EnrichCacheStore.delete(keys:)` 本身也已经会把传入的 key 集合过滤到 `Set(raw.keys)`（`EnrichCacheKeys.deletionPlan`），一个混进去的占位 key 在数据层是安全的空操作，上面这些排除纯粹是为了计数准确和不给出无意义的菜单项。
- **占位行「停止搜索」——真取消，不只是隐藏这一行（2026-08-28）**：用户点开占位行详情页问了两个问题——"能不能手动停止"、"这段等待有没有上限"——答案暴露了一个缺口：`lyricSearchDeadline`（20s）只兜住歌词源那一次并发抓取，`resolveTrackEnrichment` 整体（还挂着 MusicBrainz/Apple Music/QQ 兜底封面这几步顺序网络请求）没有总超时，某一步卡住时占位行会一直挂着，此前完全没有退出方式。用户明确要求"真正取消（改动大，跨 collector）"而不是"只隐藏这一行"——按钮点了就该让 collector 里那一轮真实的网络请求中断，不是隔着进程装样子。机制是文件信号 + `context.CancelFunc` 登记表：`placeholderDetailView` 的「停止搜索」按钮（`cancelPlaceholderSearch`）把这个 key 写进 `~/.config/lyrimuse/lyrimuse-enrich-cancel-request.txt`（纯文本，一个 key）；collector 侧 `enrichcancel.go` 的 `startEnrichCancelWatcher` 每 1 秒检查这份文件，读到 key 就去 `enrichCancelFuncs`（`enrich.go` 里的 `map[string]context.CancelFunc`，跟 `enrichInflight` 同一把锁）查对应的取消函数并调用——真正让 `resolveTrackEnrichment` 内部还在飞的 HTTP 请求中断（`context.Context` 一路下穿到 netease/QQ/酷狗/LRCLIB/Musixmatch/amll/ytmusic/MusicBrainz/Apple/取色九个源的 leaf `http.NewRequestWithContext`，详见第 09 章）。⚠️ 取消判定必须在网络健康度分类（`roundLooksNetworkDown`）**之前**：用户主动取消不是网络真的不通，`resolveEnrichAsync` 里 `ctx.Err() != nil` 那支就是为了不让这次取消被误报成"网络连接失败"。

  ⚠️ **2026-08-28 补：取消后要落定成"暂无歌词"，不是什么都不写**（用户反馈"点击停止搜索之后，不是直接删除记录，而是保留记录，标记为无歌词；并且灵动岛和桌面悬浮歌词都不再继续提示搜索歌词中"）。上线时 `ctx.Err() != nil` 那支是纯粹的 `return`，什么都不写——后果是这首歌从「歌词管理」列表里彻底消失，而灵动岛/桌面悬浮歌词/歌词窗口三处（共享同一套判断逻辑）会一直卡在"搜索歌词中…"，跟从没搜索过一模一样，因为 `EnrichCacheReader.lookup` 找不到这个 key 就返回 `nil`，`resolved` 永远算不出 `true`。改法（详见第 09 章第 24 条）：取消分支现在跟"自然查无"走同一条落盘路径（`commitEnrichEntry`），只是不经过"全空不写入"那道守卫——这条记录天生满足 `resolved: ts>0`，四个界面会各自在下一拍轮询里自动切到"暂无歌词"，**不需要改一行 Swift 展示代码**。唯一需要改的 Swift 代码是 `cancelPlaceholderSearch()` 本身：不能再乐观地立即清空 `placeholderSummary`——`.task` 那个负责"占位行等 collector 写完就自动让位"的 5 秒轮询，guard 条件正是 `placeholderSummary != nil`，清空了就没人再去问磁盘。改成写完取消信号后什么都不做，等现成的 5 秒轮询探测到 `store.hasEntry(forKey:)` 变 true 自然接手。
- 支持多选批量删除（`delete(keys: Set)`）与「清空全部」（`clearAll`，破坏性操作）。
- **破坏性操作有可恢复层**（2026-08-22 补，之前完全没有）：
  - 「清空全部缓存」**动手之前**必打一份自动快照；批量删除到 `EnrichCacheStore.autoSnapshotDeleteThreshold`（5）条起同样打。快照走的就是配置备份那份 sidecar 归档（`LyricsBackupStore.buildArchive`，含 `lyrics/` 文件族 + 「已校准」名单），落到 `~/.config/lyrimuse/lyrics-backups/auto-<clear|delete>-<时间戳>.lyrimusebak`，只留最近 `autoSnapshotKeepCount`（3）份。⚠️ 快照必须排在 `raw = [:]` 和删文件**之前** —— `buildArchive` 读的是磁盘上的文件族，晚一步就什么都读不到。
  - 单条删除**不打**快照（读几千个小文件 + 压缩 14.5MB 实测几百毫秒到一秒级，删一条付这个代价不合算，而删一条也够不上「手滑毁一片」）；它的兜底是下面那条废纸篓。
  - 歌词文件的删除从 `removeItem` 换成 `trashItem`（`EnrichCacheStore.trashOrRemove`，单条/批量/清空三条路共用）。trashItem 失败（外置卷/网络卷没有废纸篓）时**退回 `removeItem`**：残留文件会在 collector 下次启动 `importLyricsFromFiles`（文件赢）时把刚删的条目整个复活，表现成「删了又回来」——正确性优先于可恢复性，但只在拿不到废纸篓时才降级。
  - 恢复入口在**同一个「占用」菜单**的第三段「从自动备份恢复」，列出现有快照（时间 + 体积），点一份走 `EnrichCacheStore.restoreFromAutoSnapshot`。放这里而不是设置页的「配置备份」：那两个不可撤销的按钮就在同一个菜单的上面两段，手滑之后第一反应是回到点错的地方找后悔药。菜单里的列表**现读不缓存**（`LyricsBackupStore.autoSnapshots()` 只 stat 目录），否则刚打的那份不会出现。
  - 恢复的顺序不能动：**铺文件 → 重启 collector → reload 列表 + 让当前曲目重读**。`lyrics/` 文件族是权威源，collector 启动时 `importLyricsFromFiles` 照着刚铺回去的文件重建缓存条目——那一步才是恢复真正生效的地方。反过来先重启再铺等于白铺。
  - 恢复**不是整体回滚**：走 `LyricsBackupArchive.plan`，只有 added/overwritten 两类，备份之后新解析出来的歌不会被删掉。确认弹窗里明写了这一点（以为是回滚、结果发现新歌还在，是另一种惊吓）。
  - 清空确认文案随之从「且无法撤销」改成「清空之前会自动备份一份」。⚠️ **不能**写成「随时可以恢复」——只留 3 份、库本来是空的时候压根打不出快照（`writeAutoSnapshot` 返回 nil，记在 `EnrichCacheStore.lastAutoSnapshotURL`），承诺过头比不承诺更危险。
- 工具栏「占用」菜单里是**两段独立**的清理入口：「清空全部缓存」清歌词内容（缓存 JSON + `lyrics/` 文件夹），「清空全部时间轴校正」只清**单曲那一份**的偏移值（UserDefaults 里的按曲目字典 + 已校准名单）——全局基准和按播放器那两层各有自己的入口（设置页那一行），不受连带（第 08 章有 selftest 断言钉住）。两者互不连带 —— 存储位置本来就不同，而校正值是一句句听出来的，比"下次播放会自动重新解析"的歌词内容宝贵。**2026-08-21 补**：「清空全部缓存」现在也会 `LyricsPinStore.removeAll()` —— 内容都没了，留着名单就是一份孤儿（collector 继续一票否决这些歌的自动重选，而它保护的东西已经随条目一起没了）。
- 歌词内容和「已校准」名单现在会随配置备份走（sidecar 归档，见第 14 章 §4）：备份的是 `lyrics/` 文件族而不是 enrich 缓存，因为文件族是六字段权威源、collector 启动时会据它重建缓存条目。确认弹窗挂在最外层 `NavigationSplitView`（删除挂 List、清缓存挂侧栏链，三个层级分开，避免同链叠多个呈现修饰符互相顶掉）。
- 详情页「已校准」徽章（`timer` 图标）标出这首歌调过时间轴偏移。必须显式标出来，因为它带一个看不见的副作用：collector 从此不再自动给这首歌重选歌词源（见第 8 章）。偏移区下面那行小字说明后果与解除办法（改回 0）。

### 2. 数据层（EnrichCacheStore）——与 collector 的共存契约

- collector 是缓存文件的**唯一真源**（内存 map 整体覆盖写盘）。App 侧每次改动必须：①落盘；②重启 collector 让它重读——否则 collector 随时可能用「没看到这次改动」的内存旧态整个覆盖回去，静默撤销编辑。重启一律走 `scheduleCollectorRestart` 后台排队（合并连发+补偿重启）：saveEdit 2026-08-19 起与 delete 同款「先刷列表→落盘→排队重启」，不再原地等 kickstart（撞上 launchd minimum-runtime 时一等就是 ~10s）。`persist()` 的整段读-改-写（读盘 9.4MB+解析+merge+序列化+原子写）2026-08-19 挪到后台 Task 并经 persistChain 串行化（两笔绝不并发写盘；飞行窗口内的新修改由下一笔落盘，不会被整份回写覆盖）；`reload(onlyIfChanged:)` 有 (mtime,size) 指纹门控——App 每次激活触发的刷新在文件没变时整条链不跑。
- 用 **JSONSerialization 原始字典**而非 Codable：窄结构体解码再编码会把**每一条**没声明的字段悄悄丢光（Go 侧字段还在增加）；字典级只动被编辑那一条的目标 key，其余逐字节不变。
- 歌词六字段（lyrics/tr/roma/yrc/source/manual_lyrics）以 `~/.config/lyrimuse/lyrics/` 文件族为权威源：saveEdit/delete 在改 JSON 的同时同步写/删对应 `.lrc`/`.tr.lrc`/`.roma.lrc`/`.yrc` 文件，靠「改完立刻重启」保持两边一致。

### 3. 编辑 / 删除 / 移除逐字

- **编辑**（saveEdit）：写歌词/译文/罗马音（可选换 yrc/source），并置 `manual_lyrics = true`——此标记冻结 collector 一切自动重搜/重打分（第 09 章）。另有 `sourceChoice` 参数写「用户选定的源」：传非空=记下、传空串=显式清掉、传 nil=不动这个字段。⚠️ 它的写入**必须在 `markManual` 分支之外**——整条机制的要点就是「采纳候选」走 `markManual: false` 这条路径，写在 if 里面等于永远写不到。
- **删除**：连带删除已导出的歌词文件（用户要求的「真删除」，推翻早期「文件只写不删」设计）；删除后条目从缓存与文件夹双双消失，下次播放该歌会重新解析。
- **移除逐字**：入口按钮 2026-08-18 删除后，实现（removeWordTiming）2026-08-19 一并下线（死代码）；恢复见 git 历史。

### 4. 重新自动匹配（headerActions 那颗 `wand.and.stars`，2026-08-21）

「按算法重算一次、直接取值」——跟隔壁「联网搜索候选歌词」共用一条检索管线（`collector search-lyrics`），区别只在**谁挑**：那个把候选摊开让人挑，这个加 `-pick` 让 collector 按自动解析规则选冠军（详见第 09 章）。

- **文案刻意不写「智能」**：「智能算法」是设置页「匹配算法」的一个具体档位（另一档「顺序优先」），写进按钮对选了后者的用户就是假话；真正按哪一档算由 collector 决定，结果行如实报。
- **采纳时 `markManual: false`**，并**主动清掉** `manual_lyrics`（连带导出 `.lrc` 头里那行 `[manual:1]`，否则 collector 下次启动 `importLyricsFromFiles` 会拿文件头把它改回来）。理由：那个标记是 collector 侧 firstFill/rescore/retry 三条自愈路径的一票否决闸，一个「按算法重算」的动作把它置真，等于点一下就永久冻结这首歌、以后算法改进也不许碰它，而界面上还打「人工修正」徽章 —— 那是假话。反过来说，这颗按钮也是**把一条人工修正过的条目交回算法管理**的唯一入口。
- **打分留痕成对写**：`lyrics_score` + `lyrics_scoring_version`，外加 `lyrics_sources_seen` / `lyrics_sources_responded` / `resolved_duration_secs` / `lyrics_decision`＋`lyrics_decision_applied`（采纳即出处，两槽一起写；照 collector `rescoreLyrics` 实际写的那一套）。少写版本 → 下次播放立刻又被 rescore 跑一遍；少写分数 → `lyricsUpgradeBaseline` 拿 0 当基准，「必须严格更高分才替换」那道闸被拆掉，一次运气差的后台重试就能把结果换掉。
- **五条判定在 `LyrimuseCore.LyricsRematchDecision`**（纯函数，selftest 覆盖 9 条）。其中两条是**不采纳**：
  - 当前生效的源这一轮没应答（复刻 collector 的 `rescoreDecidable`）—— 它可能本来就是最优的、只是这次超时，换过去等于拿一次偶发的部分应答做降级；⚠️ 这条有个死锁盲点，见下面「设计决策与已知坑」8；
  - 现有这份有逐字、而这一轮的冠军没有（复刻 `needsLyricsRetry` 里「已经有逐字就别乱动」那道闸）。逐字是打分里最值钱的 +400，但拿不拿到取决于这一轮那个源有没有把逐字接口给全 —— 实测同一首歌上一轮 6887 字节 YRC、下一轮五个源一个逐字都没有。想强制换走「联网搜索候选歌词」（那是明确的手动选择）。
- **同源也可能换内容**，结果文案要如实说是哪里变的。同一个源在不同轮次返回的东西会变（可能匹配到另一个版本 / 歌词被重新上传过），所以判据是「正文或逐字任一不同就采纳」，而文案按实际差异分三句（正文 / 逐字 / 两者都变），**不写「更新的一份」**——代码只知道"不一样"，不知道哪份更新。2026-08-21 实测坐实这种波动：周杰伦《I Do》点按钮那一轮酷狗带逐字（存档里 `wordTiming` 400 分、1174 分对 QQ 1173 分，只差 1 分），十分钟后同一首同一个源一个逐字都不返回。
- **`applied` 必须由 App 覆写成 true**。collector 那边看不到缓存里的正文，只能拿「冠军是否换了源」近似，于是"同源换内容"会被算成 `false`，而「解析决策」把 false 渲染成「评估后维持原状」——跟结果行说的"已换成一份"直接打架（2026-08-21 用户实测撞到）。存档只在真的采纳时才写，所以无条件置 true。
- 时长优先 `duration_secs`（真实播放时长）、老条目退到 `resolved_duration_secs`：歌词打分对时长极敏感（时长档 +100~300、overshoot −700，还是源内选歌的输入），实测同一首歌传 0 时 qq 482 第一、传真实 270.8s 时 Musixmatch 962 胜出。
- 进度/结果是 header **外面**一条 caption 行（`ProgressView` + X/Y，跑完原地变成四态结果）。**不能塞进 headerActions 那排胶囊**：`header` 用 `ViewThatFits(in: .horizontal)` 比的是理想宽度，一句长文案会把「标题+按钮同一行」那个候选撑爆、按钮排从此永久掉到第二行。
- 飞行期间连带禁掉「联网搜索候选歌词」：`LyricsSearchService` 全局只允许一个 collector 子进程（`performSearch` 开头无条件 `cancelRunning()`），不挡住的话打开弹窗会把自动那一轮杀掉、自动侧收到非零退出码误报「搜索失败」。换歌/关窗时换代 + `cancelRunning()`。
- ⚠️ **一次手动重算按现行设计仍会被后续自愈路径覆盖**（第 09 章 §事后自愈：缓存永久保留 + 20s 截止 ⇒ 首次解析本来就有运气成分）。写对了 `lyrics_scoring_version` 就关掉了 rescore、写对了 `lyrics_score` 让 retry 回到「严格更高才换」，所以实践中稳；但没有「已刷新」这种新语义去一票否决，也刻意没加。

### 5. 联网搜索候选歌词（LyricsSearchSheet + LyricsSearchService）

- 不在 Swift 重写检索——一次性子进程调 `collector search-lyrics`（复用自动解析同一份全源检索+打分，第 09 章），NDJSON 流式：每个源到达即整表重排显示，带进度 X/Y、网络不通标记。
- **进度的轮次前缀**（2026-09-02，用户反馈「到 8/8 又重新从 1 开始，看起来不友好」）：collector 的兜底轮（首歌手变体/标题反查，第 09 章）每轮都是一次完整的 8 源重扫，`sourcesDone` 每轮从 0 重数——这是设计不是 bug，但弹窗上只见数字回跳、不见轮次，读起来像出了错。现在 NDJSON 每行带 `round`（searchcli.go 在 emit 处从「done 比上一行小」推导，单轮内 done 单调不减，不用把轮次穿透进 enrich.go 的闭包层），Swift 侧从**第 2 轮起**在进度后面缀轮次「（1/8）［2］」（放后面是用户定的位置）；第 1 轮不缀——绝大多数搜索只有一轮，常驻「［1］」是噪音，标识恰在数字回跳那一刻出现、自己解释自己。旧 collector 不发该字段时 Swift 兜底成 1（观感同单轮）。右上角那颗「N/8」徽章不受影响——它数的是「有几个源给过候选」，跨轮累计本来就不回跳。
- 候选带分数与**得分明细/被拒原因**（score_terms）摊开展示；按用户启用的源过滤；lrclib 纯音乐标记不当候选显示。
- **右侧预览摘掉"永远不会显示的那几行"**（2026-09-04 用户提「像是这种是不是不应该展示在右侧的框里面呢」，`LyrimuseCore/Lyrics/LyricsPreviewText.swift`）：预览框原来直接摊原始 LRC，最先映入眼帘的必然是 `[ti:]` / `[ar:]` / `[al:]` / `[by:krc转qrc工具]` / `[offset:0]` 这一块元信息标签（这些源常把它们留成**空标签**或拿来签工具名），后面还跟着几行 `作词 : X`——前者 `LRCParser.parse` 整行跳过、后者播放时被 `strippingCreditLines` 过滤，**恰恰是这份歌词里唯一保证看不到的部分**，却把用户真正要判断的"第一句词对不对、轴准不准"挤出了视野。现在按播放时的同一套判据摘掉，预览 =「采纳后你会看到的样子」。三条边界：① **只影响预览**，采纳落盘的仍是候选原始文本——`[offset:]` 是有人消费的（`LRCParser.parseOffsetMs`，整份时间轴偏移），连存的一起剥会让这首歌整体偏几百毫秒；② **时间戳留着**，摘的是"不会显示的行"不是"行首的时间戳"；③ 署名过滤**复用** `LyricsSyncEngine.creditLineDropDecisions`（那张词表被真实语料喂了十几轮，第二份必然漂移），且跟播放路径一样先认对唱标记再过滤（`LyricDuet.speakers` 当豁免）——不给豁免的话每句都带 `周杰伦：` 的对唱歌会整首被摘空。selftest `lyrics-parsing` 组 9 条钉边界（空标签块 / 署名 / 时间戳保留 / 孤立时间戳 / CRLF / 对唱豁免 / 纯文本空行 / 空输入 / 整份只有元信息）。
- **每条候选的歌名 / 歌手 / 专辑各占一行**（2026-09-04 用户要求，`candidateMatchInfo`，左侧列表与右侧详情共用）：原来歌手和专辑合并成一行、用「·」分隔，而左列只有 250–320pt 宽，歌手一长（实测「Prince/The New Power Generation」）后面的专辑名就只剩「Diamond…」——恰恰是同名候选之间唯一能分辨"这条是哪个版本"的信息。哪一项为空就不显示那一行，不留空白占位。三行**各自最多两行**、超出才截断并挂 `help` 悬停看全文，左列同时从 `idealWidth 280 / maxWidth 320` 放宽到 `300 / 380`——拆成三行后仍有单项撑不下（实测「Diamonds and Pearls (Super Deluxe Edition)」），而这三项被截掉的永远是尾巴，尾巴恰恰是版本信息（`(Super Deluxe Edition)`、`(2023 Remaster)`、`feat. …`），同名候选之间往往只有这一处不同。刻意不用居中省略（一行里挖个洞更难读，而这一列本来就纵向滚动）；封顶两行是防一条候选自己撑出五六行。
- **跨源同词标注 + 「当前使用」双判据（2026-09-04）**：候选按来源一条一个，不同源经常给出逐字相同的词。列表里把后到的那几条标灰徽章「歌词文字与 X 相同」（X = 排在前面的那个源），**只标注不隐藏**——用户可能就是要某个源的译文 / 逐字轨，参考做法整条丢弃的路子不学；文案刻意写「文字相同」不写「完全相同」，悬停说明写清只比词、不含时间戳 / 逐字 / 译文。比对口径复用 `ManualPickLock.fingerprint(lyrics:)`（追溯锁定的既有「只取词」指纹，跨 Go/Swift 金标准钉着），`Candidate.fingerprint` 构造时算一次；分组是 Core 的 `LyricsCandidateDuplicates.firstMatches`（每组首条不标、后来者都指向首条、空指纹不参与）。「当前使用」从只比来源改成来源 + 词双判据（`LyricsCandidateDuplicates.isCurrent`）：同源但正文被手改过的不再标当前，词相同但来自别的源也不标；任一侧拿不到指纹退回只比来源。三个入口都多传 `currentFingerprint`（小窗 / 歌词窗口在原来那次缓存读取里顺带 `lookup(...).lyrics`，歌词管理因 `store.raw` 私有同样走 `EnrichCacheReader.lookup`），contracts 组「采纳候选入口」守卫的记号表加了这一项；留窗模式采纳成功后 `appliedFingerprint` 随 `appliedSource` 一起挪，换歌一起重置。默认选中那条逻辑不动，仍按来源选——「选中」和「标当前」是两件事。纯文本候选存在 `plain_lyrics`、跟 `lyrics` 的指纹天然对不上，不会被误标当前，接受。selftest 14 条。
- **面板可拖边框改大小 + 查询词三栏按内容长度分宽**（2026-09-04 用户要求「这个页面要支持扩大边框」「这种搜索输入框放不下内容的情况帮我想想怎么优化」）：
  - **可缩放**：独立小窗（`Window` 场景，`.automatic` 走 SwiftUI 默认）本来就能拖；从歌词管理 / 歌词窗口弹出的这张是 **sheet**，AppKit 给 sheet 的默认 `styleMask` 里**没有** `.resizable`，窗口边缘对拖拽完全没反应。补 `WindowResizeEnabler`（同 `WindowDragHandle` 的路子：垫在背景层拿到底层 `NSWindow`）把这个标志插回去，`viewDidMoveToWindow` 同步一次 + 下一拍再一次（sheet 落到 NSWindow 上的样式由 AppKit 在依附动画那一刻定，同步那次可能被随后覆盖）。同时把根 frame 从 `minWidth:720 minHeight:480` 改成带 `maxWidth/maxHeight: .infinity`——否则窗口拖大了内容仍停在 720×480。⚠️ **离屏探针实测**（父窗口摆屏幕外、跑完即退）：sheet 依附动画结束后 `.resizable` 仍在、`setContentSize` 到 980×700 生效、内部 `NSHostingView` 跟着变宽到 980、`minSize` 保持 720×480——三件都对上了才敢说这条路走得通。
  - **三栏不再等分**：等分那版最常见的一幕是歌手栏「PRINCE」六个字母后面空着大半格，旁边歌名「Around the World in a Day (2025 Remaster)」和专辑双双被截断——三栏内容长度天然不对等，均分等于把宽度分给了最不需要的那栏。改成按各栏「装下自己的内容需要多宽」分：算术在 `LyrimuseCore/Lyrics/LyricsQueryFieldLayout.swift`（纯函数，selftest `lyrics-parsing` 组 11 条），视图侧 `ProportionalFieldsLayout`（SwiftUI `Layout`）只负责按实际字体量出"想要多宽"再摆位置。三条规则：放得下 → 各拿所需、余量**平均**分（留点余量，继续打字不会一个字就顶到边）；放不下 → 按比例分但谁都不低于 88pt 下限，被下限托住的先钉死、其余再按比例分（water-filling，少了这步一栏长得离谱时另外两栏会被压成几像素）；窄到连下限都给不满 → 平均分（可预测优先）。三栏另挂 `help`，再怎么分也有装不下的时候。
- 搜索途中可再点「重新搜索」：上一轮子进程被显式杀掉（否则白跑满 20s 占全源请求），结果以 searchGeneration 判废。关闭 sheet/采纳候选同样会停掉子进程（onDisappear + search() 内 withTaskCancellationHandler 双层，2026-08-19）；stderr 读取在独立队列（与 stdout 串行同队会把 64KB 管道死锁在 stderr 侧引回）。
- 用户点选采纳才落盘（走 saveEdit 路径）。**2026-08-22 起不再置 `manual_lyrics`，改为记「用户选定的源」`lyrics_source_choice`**（⚠️ 这一档 **2026-09-01 已被推翻**，见本节末尾的 ❌ 条：现在是「不写任何约束」/「`manual_lyrics` 冻结」严格两态，`lyrics_source_choice` 没有写入方了。下面这几条留着是因为读取侧原样保留、且它记录了当初为什么会想出这个中间态）：
  - **为什么改**：「我不同意这次自动选择、换个源」和「我手工改过正文」此前被压成同一个标记，而 `manual_lyrics` 是 collector 侧**所有**自愈路径的一票否决闸。代价是采纳一次候选 = 这首歌**永久冻结**：以后打分规则改进、那个源后来开始给逐字时间轴，都再也不会被采纳——而用户当初只是想换个源。
  - **新语义**：自愈路径（升级重试 / rescore）**照常跑**，但重选被约束在选定的源内（collector `pickLyricCandidatePreferring`）。于是「同一个源给出了更好的内容」仍能升上来，「被换成另一个源」不会发生。
  - **约束不成立时一律不换**（返回 nil），绝不退回全局最优：那个源这一轮没给候选、只给了不可用候选（Score<0）、或用户后来在设置里禁用了它——三种都是「不动」。退回全局最优等于悄悄推翻用户的选择，而「这一轮没应答」最常见的原因只是超时或限流。「我选了这个源」和「我不想再用这个源」是两个独立意图，不该在这里替用户合并。
  - **直接编辑正文那条路径（「保存修改」）仍然置 `manual_lyrics`** —— 那份内容删了就找不回来，自动逻辑没有理由觉得自己比人工更懂。两个标记从此各管各的。
  - 详情页多一颗 `pin.circle.fill`「来源已选定：X」徽章（与「人工修正」分开显示，约束强度差一个量级）。解除入口是「重新自动匹配」——它现在传 `sourceChoice: ""` 显式清掉，两个标记同进同出，因为那颗按钮的语义就是**完全**交回算法管理。
  - Go 侧 `TestPickLyricCandidatePreferring` 钉住全部边界，做过变异测试（拆掉约束会当场报「选定 kugou 时该取 kugou 而不是最高分」）。
  - **2026-09-01 补：列表本身也要有这颗徽章**（用户反馈「手动选了歌词，怎么看起来什么标记都没打」——追问后发现问的是列表视图，而「来源已选定」当时只在展开的详情面板才显示，列表紧凑视图完全没有对应图标，容易被误读成"选了却什么都没记住"）。补上跟详情面板同款的 `pin.circle.fill`/`.indigo` 小图标，`help` 里带具体选的是哪个源，`on` 条件跟详情面板一致（`!summary.sourceChoice.isEmpty`）。顺带查出：截图里那颗被误认成"人工修正"的绿色图标其实是完全不相关的「译文（歌词源自带）」标记（`character.book.closed`/`.green`，网易云这类源常带社区译文才会亮）——「人工修正」真正对应的是橙色 `pencil.circle.fill`，那张截图里一个都没有。
  - **2026-09-01 补：把"采纳候选要不要顺带锁定"的决定权交给用户**（用户明确要求）。新增设置 `AppSettings.manualPickLocksLyrics`（纯本地 UI 偏好，不进 `FeatureSettingsStore`/不给 collector 看——它只决定 Swift 侧调 `saveEdit` 时 `markManual` 传 true 还是 false，collector 那边永远只认落盘之后的 `manual_lyrics` 字段本身，不关心这个决定是怎么来的），设置页「歌词→获取」卡片里加一个「手动选定歌词后锁定」开关，默认关（维持上面这套更宽松的"只记来源、不冻结"行为）。开着时，`LyricsManagerView.swift`/`LyricsQuickSearchWindow.swift` 两处「采纳候选」调用点的 `markManual` 参数改传这个设置值，效果等同于直接编辑正文——永久冻结，不受任何自愈路径影响。「重新自动匹配」按钮不受这个开关影响，永远是算法自己的选择，不算"手动选定"。
    - ⚠️ **顺带修的真 bug**：排查这条时发现 `LyricsQuickSearchWindow.swift`（悬浮窗 ⚙ 快捷菜单「搜索歌词…」独立小窗，见第 04/07 章）的「采纳候选」调用点从一开始就没传 `markManual`/`sourceChoice`，落进 `saveEdit` 的默认值 `markManual: true`——每次从这扇小窗采纳都在悄悄永久冻结这首歌，跟 2026-08-22 那次「采纳候选不该冻结」的设计决定不一致，只是这扇小窗是 2026-08-30 才加的，没有跟着补齐。现在两个入口统一改传 `AppSettings.shared.manualPickLocksLyrics`，行为一致。
  - ❌ **2026-09-01 当天推翻：「只约束源」这个中间态被用户否掉，`lyrics_source_choice` 不再有写入方。**
    - **怎么暴露的**：上面那个开关加完之后写它的 `?` 说明文案，把当时的关态老老实实写成「只记住这首歌用哪个来源；这个来源以后有更好的版本，仍会自动换上」。用户一读就说这不是他要的：「不开，手动选后依然会被所有更新、优化的地方自动调整歌词，**不限制源**；开了就手动选后固定这个歌词不动」。**把行为写进界面，才发现行为本身是错的**——这个中间态存在了 10 天没人发现不对，因为它此前从来没在界面上被完整表述过（只有一枚事后的 pin 徽章）。
    - **改法**：两处「采纳候选」调用点的 `sourceChoice` 恒传 `""`（显式清掉），两态收敛成严格的二值——关 = 缓存里一个约束标记都不写，打分改进/升级重试照常调整、**可以换源**；开 = `manual_lyrics` 冻结。
    - **存量数据一并清理**：作者本机 3198 条缓存里有 6 条带 `lyrics_source_choice`（netease×4 / kugou / musixmatch，均不带 `manual_lyrics`）。不清的话它们会继续被约束在原源内，而开关显示的是「关」——行为跟界面写的字不符，且用户无从发现。清理必须**先停 collector**（它握着完整缓存、周期性整体覆盖写，活着时改磁盘会被内存里那份盖回去）：`launchctl bootout` → 只 pop 这一个键 → 回读逐条核对「除了这个键其余字段逐键一致」→ `bootstrap`。
    - **读取侧刻意保留**：collector 的 `LyricsSourceChoice` 字段、`pickLyricCandidatePreferring` 及其两个调用点、`TestPickLyricCandidatePreferring`、以及 App 侧那两枚 pin 徽章都没删。理由：字段本身无害，老缓存和别人手改过的 JSON 里仍可能带着它，而**静默忽略一个明明写着「我要这个源」的字段，比继续尊重它更糟**；徽章存在的意义正是让这个隐形约束可见。要删就整套一起删，别只删一半。
  - **2026-09-01 再补：开关打开时要把「之前手动选过的歌」追溯锁定**（用户要求：「不开的时候我手动选择的，在开关开启后要自动变为锁定状态」）。
    - **前提冲突**：上一条刚把关态改成"什么痕迹都不留"，于是缓存里没有任何字段能回答"这首歌是用户手动选的"。所以必须重新加一个记号——区别是它**纯记录、零行为影响**（collector 一个读取点都没有），而不是上次那种会偷偷约束选源的。
    - **记号是内容指纹不是 bool**：`manual_pick_sha`，三个「采纳候选」入口写入，其余 `saveEdit` 路径一律清掉。**用指纹是这套设计成立的关键**：关态下这首歌随时可能被自愈路径换成别的版本（那正是关态的语义），换过之后再打开开关，锁住的就会是一份用户**从没选过**的内容。指纹对不上 = 我选的那份已经不在了 = 不锁。这条判断是自证的，不依赖 collector 任何一处「换歌词时记得清标记」的配合——那种分散的清理点漏一处就错，而且错得无声。
    - ❌ **当天推翻的第一版指纹口径：`SHA256(lyrics + \x01 + yrc)`（原始字节）——它根本不成立。**
      - **怎么暴露的**：作者试用后，缓存里那唯一一条真实留痕就是失配的（阿肆《浮光掠影》，留痕 `3c4fe3efb6e8` vs 当前 `6625fc9d1d36`）。查下来 `lyrics` 一字节没变（导出的 `.lrc` 正文与缓存逐字节相同，831 字节），**漂的是 YRC**：`migrateYRCWhitespaceTokens` 合并逐字空白词条，**没有 `ManualLyrics` 闸**（`migrateLyricTimelines` 有），锁没锁都跑；而 `saveEdit` 采纳完**立刻重启 collector**，于是指纹在采纳后**几秒内**就失配。关态（`manual_lyrics=false`，正是追溯锁定的主场景）更糟：`migrateLyricTimelines` 会重挂 `lyrics` 的行时间轴，连正文都变。**净效果是这个功能对绝大多数歌静默失效**——单测、跨语言金标准、变异测试全绿，真机上一首都锁不上。
      - **根因是问题定义错了**：要回答的是「自动路径有没有把用户选的那份**换掉**」，不是「字节有没有变」。**规范化不是替换**——词一个没动，只是格式被重排。
      - **改法**：指纹只对「词」取。`ManualPickLock.canonicalLyrics` 逐行剥掉开头所有 `[...]` 方括号组（行时间戳 + `[ti:]/[ar:]/[al:]/[by:]/[offset:]` 元数据标签）、trim、丢空行，再 `SHA256` 取前 12 位；**YRC 完全不参与**。于是重排时间轴 / 合并空白词条 / 补出逐字都算「还是他选的那份」（而这些恰恰是用户会想连着锁住的改进），换源或同源换了词才判「已被换掉」。代价（接受）：另一个源恰好给出逐字相同的词也会匹配——但那时内容跟他选的逐字一样，锁住无害。
      - **对重挂的免疫是结构性的**：`rehangLRCOnYRC` 收尾是 `out[i] = formatLRCStamp(...) + texts[k]`（`lyricstimeline.go`），`texts[k]` 就是「剥掉时间戳再 trim 的原文」，跟这里的归一化逐字一致——它换的只有时间戳前缀。
      - ⚠️ **改版时又抓到一个跨语言分歧**：Swift 的 `String.split(separator: "\n")` 按 **Character**（字素簇）切，而 **`\r\n` 是单个字素簇**、跟 `"\n"` 不相等——CRLF 歌词在 Swift 侧整段不分行，Go 侧（按字节 `0x0A` 切）却分得好好的，两边指纹当场漂开。金标准断言当场逮住。修法：Swift 改成按 **Unicode 标量**切（`lyrics.unicodeScalars.split(separator: "\n")`），等价于 Go 的 `strings.Split(s, "\n")`，残留的 `\r` 交给 trim。
      - **金标准也换了**：A/B 是**同一份词的两种排版**（B 换了全部时间戳、改 CRLF、加元数据标签和行尾空白、把两句挂成多时间戳、插空行）必须同指纹，C 换了词必须不同指纹。两边各钉一份，值由 Python hashlib 独立算出。
      - **教训**：这是「跨层穿透的修复可能静默 no-op」的又一例——纯函数单测全绿、跨语言一致、变异测试有效，**但被测的那个函数回答的问题本身是错的**。逮住它的不是任何一层测试，是去看**真机上那条真实数据**。
    - **判据在 `LyrimuseCore/ManualPickLock.swift`**（`fingerprint` + `shouldFlip`），刻意从 App target 挪进 Core：`lyrimuse-selftest` 只链 LyrimuseCore（见 `Package.swift`），留在 `EnrichCacheStore` 里等于这段逻辑一行测试都写不了，而整个功能的对错全压在这个谓词上。11 条断言，做过变异测试（摘掉指纹校验，「内容已被自动换掉→绝不锁」和「YRC 被升级过」两条当场红）。**刻意不复用** `LyricsOffsetStore.contentFingerprint`（算法一模一样）：那个是 offset 持久化 key 的组成部分，被兼容性冻结了，挂上第二个用途等于给它加一条看不见的「也不能改」。
    - **关掉开关时弹一次确认**（用户拍板）：问「要不要把因这个开关而锁的 N 首一并解锁」。不默认解也不默认留——两种意图都讲得通，而**目前没有单曲解锁入口**（清 `manual_lyrics` 只能靠「重新自动匹配」，而那颗按钮会顺便把歌词换掉），猜错的代价是逐首去换一遍歌词。手改正文锁的歌不受影响：手改会重写 lyrics 并清掉 `manual_pick_sha`，`shouldFlip` 的第 1、2 条各拦一道。实测作者本机 5 首 `manual_lyrics` 全是手改锁的，关开关时命中 0 首。
    - ⚠️ **顺带修的第二个真 bug：「采纳候选」其实有三个入口，之前只修了两个。** `LyricsWindowView.swift`（歌词窗口内的搜索）跟当天早些时候修的 `LyricsQuickSearchWindow` 是同款问题——既没传 `markManual` 也没传 `sourceChoice`，落进默认值 `markManual: true`，**在歌词窗口里搜一次采纳一次就把这首歌永久冻结**，开关对它完全不生效。漏掉是因为当时顺着「歌词管理 vs 小窗」两两对比找，没把入口数一遍。判据：`grep 'LyricsSearchSheet('` 得三处，改任何一处都要三处同进同出。
    - **老版本用户的存量走一次性迁移**（`lyrimuse-collector/manualpickmigrate.go`，`main.go` 里在 `migrateLyricTimelines()` 之后调用）。`manual_pick_sha` 是 2026-09-01 才有的字段，而 `lyrics_source_choice` 2026-08-22 上线（commit `d0296db`）、**v1.4.0 是 08-24 打的 tag**——线上用户缓存里确实有这批数据。不迁移的话，他们升级后打开开关会得到「还没有手动选定过歌词」，而这对他们**是假话**。
      - **判据可靠**：`lyrics_source_choice` 的唯一写入方就是那两个「采纳候选」调用点，非空即「用户手动采纳过这首歌」，不会误判。
      - **只在 `lyrics_source == lyrics_source_choice` 时写标记**：当前这份已经不是他选的那个源给的了（后来禁用了那个源，或走了别的路径），按新语义就不算「他选的那份」。
      - **已 `manual_lyrics` 的不补标记**——这条的下行风险最大：`manual_pick_sha` 同时也是「关掉开关时可以解锁」的凭据，给一条已锁记录补上它就让它变得可被批量解锁，而 `manual_lyrics` **分不出**「08-22 前采纳候选锁的」和「手改过正文锁的」，后者一旦被解开，那份删了找不回来的内容就重新暴露给自动覆盖。不解锁只是少做一件事，误解锁不可逆。做过变异测试（摘掉这道闸当场红）。
      - **精度上的诚实交代**：采纳之后被**同源升级**过的歌（那正是 `lyrics_source_choice` 当初的设计意图），这里记的是升级**后**的指纹，严格说不是「他当初点的那一份」。接受：用户表达的意图是「这首歌我要这个源的词」，当前内容满足它。
      - **`lyrics_source_choice` 一律清掉**（哪怕这条没写标记），把旧语义换成新语义而不是两套并存。副作用：`pickLyricCandidatePreferring` 的非空分支从此是**确凿的死代码**，两枚 pin 徽章永远不亮。整套机制的删除是一次独立清理，故意没混进这次改动。
      - ⚠️ **调用顺序是硬约束**：必须排在 `importLyricsFromFiles` / `migrateYRCWhitespaceTokens` / `migrateLyricTimelines` **之后**——那三步都会重写 `Lyrics`/`LyricsYRC`，在它们之前算指纹的话写下的指纹当场过期，老用户打开开关照样一首都锁不上，而且同样是静默的。
      - **跨语言指纹必须逐字节一致**：Go 侧 `manualPickFingerprint` 写、Swift 侧 `ManualPickLock.fingerprint` 读来比对。漂开的后果是静默的（一首都锁不上，而缓存里的指纹看上去完全正常）。两边各钉一组**相同输入、相同期望值**的金标准断言（`TestManualPickFingerprintMatchesSwift` ↔ selftest「指纹与 Go 侧金标准一致」），值由独立第三方实现（Python hashlib）算出，不是从任何一边抄的。
      - **真数据验证**：拿改动前的 42MB 缓存备份（3198 条，6 条带旧字段）跑真实迁移函数，6/6 全部转成标记、旧字段残留 0。
    - ⚠️ **collector 的缓存往返会静默吞掉未声明字段。** `loadEnrichCache` 解进 `map[string]enrichEntry`（强类型 struct），`saveEnrichCache` 再整个 marshal 回去，Go 的 `encoding/json` unmarshal 时**直接丢弃未声明字段**。第一版忘了在 `enrichEntry` 里声明 `ManualPickSHA`，后果是记号在 collector 下一次存盘（每解析一首歌都可能触发，窗口几分钟）时被抹掉，表现为**「开关打开时什么都没锁上」且缓存文件里那个字段像从没写过**。`TestEnrichEntryPreservesAppOwnedFields` 把这条钉死了（先写测试看它红，再补声明看它绿）。**规矩：App 侧新增任何写进 enrich 缓存的字段，都必须在 `enrichEntry` 里声明一个成员，哪怕 collector 一行都不读**，并加进那个测试的探针清单。

### 6. 解析决策查看（LyricsDecisionSheet，只读）

展示 collector 在**真正做决定那一刻**固化的决策存档：路径、哪些源应答、各候选分数与被拒原因、胜者。存档分**两槽**（2026-08-22，语义见 09 章「决策留痕」）：「当前歌词的出处」（`lyrics_decision_applied`）与「最近一次评估」（`lyrics_decision`）——两槽都有且不是同一轮时弹窗顶部出分段切换器，出处页在前；「拷贝」一次拷走两份（对不上号本身往往就是要复盘的问题）。老条目只有单槽：最近评估恰好 Applied 就当出处展示，否则只有「最近一次评估」一页。

- **弹窗可拖动、可拖边框改大小**（2026-09-05 用户要求，跟「搜索候选歌词」那张 09-04 做的是同两块能力，共用 `LyricsManager/SheetWindowAffordances.swift`）：`.sheet` 弹出的面板既没有系统标题栏也不带 `.resizable`——前者让整扇窗钉死在依附点（`isMovableByWindowBackground` 对 sheet 样式不生效，得垫 `WindowDragHandle` 在标题行背后发 `performDrag`），后者让四边对拖拽毫无反应（`WindowResizeEnabler` 往底层 `NSWindow` 的 styleMask 插 `.resizable`，同步插一次 + 下一拍再插一次，因为 sheet 的样式由 AppKit 在依附动画那一刻定）。⚠️ 根 frame 必须同时放开 `maxWidth/maxHeight: .infinity`，只留下限的话窗口拖大了内容仍停在 `idealWidth 520 × idealHeight 560`、四周留白。
  ⚠️ **最小尺寸要自己设**（2026-09-05 用户报「应该有一个最小大小才对，现在都没有限制」）：内容侧 `.frame(minWidth:minHeight:)` 约束的是 SwiftUI 布局，**管不住窗口**——窗口能被拖到多小由 `NSWindow.contentMinSize` 说了算，而它默认是零。加 `.resizable` 之前看不出来（压根不能拖），放开之后就成了"能一路拖到只剩标题栏"。所以 `WindowResizeEnabler` 收两个参数（`minWidth`/`minHeight`，传挂它那个视图 frame 里声明的同一对），插标志的同时写进 `contentMinSize`，并在窗口已经比下限小时顺手撑回去（"拖不小于下限"救不了一扇本来就没被拖过的窗）。⚠️ 离屏探针实测：`viewDidMoveToWindow` 那一刻 `contentMinSize` 与 `minSize` **都是 0×0**（内容那对下限确实没传到窗口上），设过之后再 `setContentSize(300×200)` 被夹回 720×480。
- **路径共 5 条**，Go 侧取值 ↔ 界面中文名必须**成对**改：`first-resolve` 首次解析 / `upgrade` 升级重试 / `refill` 补搜缺失歌词 / `rescore` 规则换版重选 / `manual-rematch` 手动重新匹配（点「重新自动匹配」那一次）。取值全集在 collector `decision.go` 的 `lyricsDecisionPaths()`，译名在 `LyricsDecisionSheet.pathLabel` 那个 switch —— 那边 default 是「原样显示原始值」，漏补译名就是界面上直接印一个英文串给用户看（2026-08-21 加 manual-rematch 时真漏过一次，用户截图反馈）。Go 侧 `TestLyricsDecisionPathsHaveChineseLabels` 双向守着这两份清单（它会去读那个 .swift 文件）。
- **候选封面**（2026-09-01，用户要求）：`lyricsDecisionCandidate.CoverURL` ← `scoredLyricCandidateResult.CoverURL`（字段本来就有，「搜索候选歌词」弹窗一直在用，只是没抄进存档），Swift 侧 44pt 缩略图。判断「这个源匹配到的是不是同一个版本」时，封面往往比专辑名一眼看得出来（现场版/精选集/单曲封面差别很直观）。
  - **只要这一轮有任一候选带封面，就给所有行留位；一条都没有就整轮不留。** 老存档（改动之前固化的，压根没有 `cover_url`）因此长得跟以前一模一样，不会变成一列灰色音符占位符——那看着像坏了；而新存档里个别源没给封面时行左边缘仍然对齐。
  - **老存档永远显示不出封面**，这是预期行为：存档是「当时那一刻的固化」，不能事后补——现在再去查一次拿到的不是当时那个。
  - 用 `CachedImage` 而不是 `AsyncImage`：存档里的 URL 会随时间失效，而 `CachedImage` 带失败负缓存（10 分钟内不重试同一个坏 URL）和同 URL 并发合流；一屏四五条候选还能来回切换存档记录，`AsyncImage` 会对着一堆死链反复发真实请求。
  - ⚠️ **属性必须叫 `coverUrl` 不能叫 `coverURL`**（差点栽在这）：`decodeDecision` 用的是 `.convertFromSnakeCase`，它把 `cover_url` 转成的是 `coverUrl`（小写 rl）。写成 `coverURL` 时 `decodeIfPresent` 直接给 nil——**一个封面都不会显示，而其它字段全正常**，纯静默失效。隔壁 `LyricsSearchService.RawCandidate` 同一个 JSON 字段写成 `coverURL` 没事，是因为那边手写了完整 CodingKeys、根本没开这个策略；两处看着矛盾其实是两套解码策略，别照着"统一"。
  - 顺带推翻一条过时注释：`scoredLyricCandidateResult.CoverURL` 原来写着「LRCLIB 没有封面这个概念，QQ 这条路径也没查封面」——实测（对《Shall We Dance (Live)》跑 `search-lyrics`）**网易云/酷狗/QQ/LRCLIB 四个源都返回了封面**（LRCLIB 那条是 iTunes 的 mzstatic 图），连被判 -1 的候选也有。
  - 验证方式：`TestBuildLyricsDecisionCopiesDisplayFields` 钉住「展示字段逐个抄进存档」（做过变异测试，摘掉复制行当场红）；端到端另跑过一次性验证——真实网络抓候选 → `buildLyricsDecision` → 序列化，Go 写出 4/4 带封面，再把**那份真实产物**交给 Swift 的解码路径解出 4/4。
- 与「联网搜索」的本质区别：那是**现在**重新抽签（受 20s 期限影响，候选和当初不一定一样），这是当初那轮的**离线存档**。完整结构懒解码（`decodedDecision(for:)`，2026-08-19）：列表/按钮只用 `hasDecision` 布尔，打开弹窗那一刻才按 key 解一条——原来 rebuild 时对每条带该字段的条目全量做 JSON 双重编解码。刻意不提供「改用某条」按钮——存档里没有正文（collector 三铁律），想换歌词走联网搜索。

### 7. 歌词库统计面板（设置 → 歌词 → 管理段，2026-09-03）

- 「歌词管理 打开…」那一行下面一块统计面板（`Settings/LyricsLibraryStats.swift` 的 `LyricsLibraryStatsPanel`）：**总数 / 逐字 / 逐行 / 纯文本 / 纯音乐 / 暂无** 六格等宽，下面一行「其中 N 首有译文 · N 首有罗马音」。用户要求（「统计目前歌词数量，歌词情况，比如逐字多少，纯文本多少，逐行多少」）。
- **零新增解析**：全部读 `EnrichCacheStore.Summary` 上早就存着的 `hasWordTiming` / `hasLyrics` / `hasPlainTextFallback` / `isInstrumental` / `hasTranslation` / `hasRomanization` —— 这些值本窗口的列表和详情页一直在显示，只是设置页此前一个数字都不给，想知道「库里攒了多少、成色如何」必须开这扇窗去数。
- ⚠️ **成色是一次有优先级的判定，不是四个独立布尔**（`LyrimuseCore.LyricsKind.classify`）：逐字 → 逐行 → 纯文本 → 纯音乐 → 暂无，命中即停。`lyrics_yrc` 是在 `lyrics` 之上补的，所以「有逐字」的条目几乎一定也「有逐行」——不设阶梯的话各项之和会超过总数，用户一眼看出面板在瞎报。`isInstrumental` 排在 `.none` 前面同样是有意的：确证过的纯音乐跟「没搜到」是两回事（2026-08-20 在本窗口列表里修过一次，一整批 LoL 原声带被显示成刺眼的红色「无歌词」）。
- 分类本体放在 **LyrimuseCore** 而不是跟面板放一起：App target 不可被 `lyrimuse-selftest` 引用（它只依赖 LyrimuseCore），而这个阶梯改错了**完全不报错、只是数字悄悄变形**。selftest（`lyrics-manager` 组）用一张 **16 行显式期望表**穷举全部组合——刻意不照着实现再写一遍 if 链，那是拿同一个假设验证它自己、阶梯整体挪位置照样全绿。显示用的名字/配色留在 App 侧（要 L10n / SwiftUI）。
- **译文按来源拆两半**（2026-09-03，用户问「罗马音和译文这 2 个有没有必要区分歌词源带的还是机器翻译的」）：`LyrimuseCore.LyricsTranslationSource.classify` 读 `lyrics_tr_source`（空=社区译文，`"machine"`=collector 机翻）。本机实测 **1135 首有译文 = 源自带 723（63.7%）+ 机翻 412（36.3%）**，六四开，不是"分了也全落一边"的伪区分，而且两者质量差得远。⚠️ 必须**先判 `hasTranslation`**：`lyrics_tr_source` 为空既可能是社区译文也可能是压根没译文，光看那个字段会把三千多条没译文的歌全算成社区译文。
  - ⚠️ **`"machine"` 这个哨兵跟 collector 的 `lyricsTrSourceMachine`（translate.go）之间没有任何编译期耦合**。Go 那边改成别的字符串时 Swift 不会报错，只会**静默**把机翻全算成社区译文（面板两个数字对调、歌词管理里那枚紫色徽章集体变绿）。selftest `contracts` 组有一条闸直接去扫 Go 源码对账。同批把 `LyricsManagerView` 里三处硬编码的 `"machine"` 也换成了这个共享常量。
- **罗马音刻意「不」按来源拆**，两个原因：① 根本没有 `lyrics_roma_source` 这种字段——`lyrics_roma` 的来路是混的（网易云 `romalrc` / QQ `roma` / 酷狗 KRC 是源自带，粤拼是 collector 自算），只能靠 `song_language=="yue"` 推断，而粤拼只在「没有任何源给出 romalrc」时才补，一首源自带 romalrc 的粤语歌照样标 `yue`，会被误判成自算。② 更要紧：`lyrics_roma` 只覆盖 **114/3566 ≈ 3.2%**，而 App 侧 `Romanizer` 有客户端现算兜底（第 10 章 §33-34），服务端没给的照样在渲染时现算——所以这个数**不等于**「有多少首歌看得到罗马音」。文案因此定为「N 首**已缓存**罗马音」并挂 `HelpButton` 说明，不能写成「N 首有罗马音」（那正是这一版上线时的措辞，会让人以为罗马音基本没生效）。
  - ⚠️ 同日**这个数字的含义变了一半**：collector 新增了日／韩／中预生成（第 10 章 §5，`lyrics-romanize` helper），所以「已缓存」不再只是「源自带 + 粤拼」那一小撮。但 `maybeGenerateHelperRoma` 只在解析／重评那一刻跑，**存量条目要跑一次 `collector backfill-roma -apply` 才会补上**。本机 2026-09-03 已跑完全量：带罗马音的条目 **117 → 2133**（3571 条里；其余 1323 条非中日韩文字、115 条没歌词）。⚠️ help 气泡的文案 2026-09-03 砍过一轮（用户原话「不要说那么多有的没的」），只留「这个数在数什么 / 没被数的去哪了」两句；「三条来路」的枚举和「哪些歌仍走实时生成」的举例移进代码注释和第 10 章 §5——那是开发者要知道的，不该占用户的气泡。
- `isSearching` 的占位行不计入（那不是缓存里真实存在的条目，见 `Summary.isSearching`）。空库不摆一排 0，改成一句「还没有缓存任何歌词。放一首歌，Lyrimuse 会自动搜好存在这里」。
- 面板**自己**持 `@ObservedObject EnrichCacheStore.shared` 并在 `.task` 里 `reload(onlyIfChanged: true)`，不把订阅挂到整个设置页上——那个单例有七八个 `@Published`，整页订阅意味着任何一次 reload / 体积重算都要重画整张设置页（本仓库为「@ObservedObject 订阅整个单例」踩过真实的过度重渲染 bug）。

### 8. 歌词文件夹（设置 → 歌词 → 管理段）

- 路径展示 + 「选择文件夹…」（NSOpenPanel，改 `features.lyricsDir`）+「打开歌词文件夹」（不存在先兜底创建）+「恢复默认位置」（lyricsDir 置空）。换文件夹后旧文件不自动搬。
- 文件格式：每条目最多 4 个文件，头部 `[ar:]/[ti:]/[al:]/[source:]/[manual:1]` 标签；collector 启动时「文件赢」导入覆盖 JSON（只增不删）；大小写碰撞组加 crc32 哈希后缀消歧。

## 设置项

| 位置 | 项 | 影响 |
|---|---|---|
| 歌词→管理 | 歌词管理 打开… | 打开本窗口 |
| 歌词→管理 | 歌词库统计面板 | 只读，来自 `EnrichCacheStore.summaries` |
| 歌词→管理 | 歌词文件夹（选择/打开/恢复默认） | `features.lyricsDir`（features.json+kickstart） |

## 与其它功能的交互

- `manual_lyrics` 是对第 09 章全部自动自愈路径的一票否决。
- 每次保存/删除触发 collector 重启 → 歌词/推送短暂中断（与第 14 章 features 保存共用 `CollectorControl`，那边有 0.5s 去抖，这边是单次操作直接踢）。
- 删除条目 → 下次播放重新解析（缓存永久性的唯一显式出口）。
- 「联网搜索」结果的打分与自动路径完全同源——弹窗里看到的分数可与决策存档对比（时长输入不同会导致差异，决策存档正是为此存了 duration_secs）。

## 数据与文件

- `~/.config/lyrimuse/lyrimuse-enrich-cache.json`（原始字典级读写）。
- `~/.config/lyrimuse/lyrics/`（或用户自选目录）：`<artist> - <title>[#hash].lrc/.tr.lrc/.roma.lrc/.yrc`。
- `~/.config/lyrimuse/lyrics-backups/`：破坏性操作前的自动快照 `auto-<clear|delete>-<时间戳>.lyrimusebak`（最多 3 份）。刻意放在 `~/.config/lyrimuse/` 下而不是 iCloud 备份文件夹——这是「手滑之后马上要用」的东西，不该受「用户有没有配 iCloud」影响，也不该每次清空往云盘塞几 MB；`uninstall.sh --purge` 删整个 CONFIG_DIR 时顺带收走，不用另维护清理路径。
- UserDefaults：列宽三键。

## 代码锚点

| 主题 | 位置 |
|---|---|
| 窗口主视图 | LyricsManager/LyricsManagerView.swift（列表/筛选/focusCurrentlyPlaying/sourceDisplayName/sourceColor） |
| 排序 | 展示枚举 LyricsManagerView.swift `LyricsSortOption`（绑 Picker，只负责把自己翻译成 `coreOrder`）+ `EnrichCacheStore.Summary.lyricsSortKey`（映射成纯值类型）；**规则本身**在 LyrimuseCore/Local/LyricsSortOrder.swift `LyricsSortKey` `LyricsSortOrder.less` `compareOptional` `fallbackLess`；覆盖在 lyrimuse-selftest（见「设计决策」第 20 条） |
| 数据层 | LyricsManager/EnrichCacheStore.swift `saveEdit` `delete` `clearAll` `splitKey` `buildSummaries`（含 `offsetsSnapshot` 参数）`rebuildSummaries`（public，供偏移编辑收尾调） `persist`(后台+串行链) `reload(onlyIfChanged:)` `trashOrRemove` `restoreFromAutoSnapshot` `autoSnapshotDeleteThreshold` |
| 自动快照 | Settings/LyricsBackupStore.swift `writeAutoSnapshot` `autoSnapshots` `pruneAutoSnapshots` `restoreAutoSnapshot` `autoSnapshotDir` `autoSnapshotKeepCount`；归档格式在 LyrimuseCore/Lyrics/LyricsBackupArchive.swift |
| 联网搜索 | LyricsManager/LyricsSearchSheet.swift、LyricsSearchService.swift；collector 侧 searchcli.go |
| 决策弹窗 | LyricsManager/LyricsDecisionSheet.swift；数据 decision.go |
| collector 重启 | LyricsManager/CollectorControl.swift（launchctl kickstart -k + 真实退出码检查） |
| 列宽 | LyricsManager/LyricsColumnWidthsStore.swift + LyrimuseCore/Lyrics/LyricsColumnLayout.swift（不含「偏移」列，见下） |
| 偏移列 | LyricsManagerView.swift `offsetColumnWidth`/`headerChrome`（固定宽度,不进 LyricsColumnWidths）；LyrimuseCore/Lyrics/LyricsOffsetStore.swift `offsetsSnapshot`；Settings/AppSettings.swift `signedSeconds(ms:)` |
| 窗口几何持久化 | LyricsManagerView.swift `LyricsManagerWindowFramePersistence` / `LyricsManagerWindowCapture`（frame + 屏幕稳定 ID，恢复时先认屏再夹进可见区） |
| 换歌自动重定位 | LyricsManagerView.swift `LyricsManagerNowPlayingObserver`（只转发 artist/title/album 的窄代理） |
| 详情页顶部三种排法 | LyricsManagerView.swift `header` 的 `ViewThatFits` + `headerActions` / `headerActionsWrapped` |
| 文件导出/导入 | collector 侧 lyricsexport.go / lyricsimport.go |
| 搜索占位行 | LyricsManagerView.swift `placeholderSummary` `refreshPlaceholder` `placeholderDetailView` `selectableFiltered`；EnrichCacheStore.swift `Summary.isSearching` `hasEntry(forKey:)`；collector 侧「有结果才写盘」的约定在 enrich.go `resolveEnrichAsync`（第 09 章） |
| 占位行「停止搜索」 | LyricsManagerView.swift `cancelPlaceholderSearch`（不主动清空 `placeholderSummary`，靠 5 秒轮询自然让位）；collector 侧 enrichcancel.go `startEnrichCancelWatcher` `checkEnrichCancelRequest` `setEnrichCancelRequestPath`；enrich.go `enrichCancelFuncs` 登记表 + `resolveEnrichAsync` 的 `ctx.Err()` 分支 + `commitEnrichEntry`（第 09 章第 24 条：取消后落定成"暂无歌词"，`context.Context` 穿透各源的细节也在那一章） |

## 设计决策与已知坑

1. Codable 窄结构体整读整写会丢掉全库未声明字段——必须字典级原样保留（上百条数据的破坏性 bug 教训）。
2. 「改完立刻踢重启」是与 collector 共存的唯一一致性机制，代替常驻 IPC 接口；个人工具偶尔手动操作可接受。
3. 删除连带删导出文件：早期「永久保留导出」设计被用户显式推翻。
4. 重复条目的两道防线（key 归一化迁移 + 在途宽松查重）之间仍可能漏「空格/繁简」变体，查询侧做了宽松兜底但 key 本身不折繁简——折进 key 会让 Swift 侧悬浮窗整首失配（第 09 章 key 契约）。2026-08-20 补上第三档「合 credit 分隔符」（`A/B/C` vs `A & B & C`，两侧 `loosenEnrichKey`/`EnrichCacheKeys.looseKey` 同步折平）：这一档是**专辑预取**跟播放器的写法差异带来的，一次实测就有 13 组，机制与清理过程见第 09 章 §2。
5. 决策弹窗只读是刻意的：存档无正文，「从存档采纳」这种操作在数据上就不存在。
6. 搜索子进程必须可中断，否则连点重搜会积压 20s 的幽灵轮。
7. 「偏移」列故意做成固定宽度、不进 `LyricsColumnWidths` 的拖拽夹值系统——那套算术（`dragged`/`fitted`/`sanitized`）本来就是这个模块最容易出错的地方，为一个纯展示的数字列去扩成四分隔条不值得；把它算进 `headerChrome`（连同新增的一条 8pt 间距）就足够让现有三列的收敛算术保持正确。
8. `buildSummaries` 要在 `reload()` 的后台线程跑，不能在函数体内部同步访问 `@MainActor` 的 `LyricsOffsetStore`——调用方必须在 MainActor 上下文先取一份 `offsetsSnapshot`（纯字典拷贝）再传进去。这是这个代码库里"纯函数需要 actor 隔离状态时，调用方先拍快照再传参"的既有套路（跟 `EnrichCacheStore.reload` 本身在 Task.detached 里跑纯函数是同一个道理），不是这次新发明的。
7. 「清空全部」曾在一次脚本化 GUI 验证中被误触发导致 833 条手工修正丢失——对这个窗口做任何自动化操作前必须备份缓存与 lyrics 文件夹（repo CLAUDE.md 硬规则）。
   **2026-08-22 补上了代码层的可恢复层**（§1 那条）：清空/批量删除前自动快照、删除走废纸篓、菜单里就地给恢复入口。在此之前那次事故在当时的代码上会一字不差地重演——确认弹窗只是提示，落地动作（整份替换落盘 + `deleteAllLyricsFiles` 的 `removeItem`）没有任何回头路，而清空还连带 `LyricsPinStore.removeAll()`，用户一句句听出来的时间轴对应的 pin 也一起没。**但 CLAUDE.md 那条硬规则不因此放松**：快照只覆盖 `lyrics/` 文件族 + pins，挡不住脚本误触别的破坏性控件，也挡不住「快照本身没打成」（库为空/写盘失败）。
8. ⚠️ **「当前源这一轮没应答」那道闸有个死锁盲点**（2026-08-22 实测）：它假设「没应答」是
   偶发超时，但当前源如果是**恒定**搜不到这首歌，这个条件就永远为真，按钮永远停在
   「这一轮「X」没应答，没有换（避免误降级）」——而 `.keptNotDecidable` 分支是直接 return、
   **不调 `saveEdit`**，于是连 `manual_lyrics` 也一并清不掉，这颗「把人工修正交回算法管理」的
   唯一入口对这条条目彻底失效。真实形态：「开不了口 (Live)」（周杰伦地表最强世界巡回演唱会）
   被「联网搜索候选歌词」采纳成了 QQ 的《范特西》录音室版——注意 `lyrics_source=qq` 是**那个
   采纳动作写进去的**，不是自动解析选出来的——而 QQ 的 smartbox 对这首歌的 Live 查询恒定 0
   候选（成因见第 09 章已知坑 13），所以 qq 永远不会应答。绕法只有两条：删掉条目让下次播放
   走 first-resolve，或用「联网搜索候选歌词」直接采纳（代价是又写一次 `manual_lyrics`）。
   没有就地改这道闸，是因为它防的降级是真的（第 09 章 §9 的实测依据）；要修得先能区分
   「这一轮超时」和「这个源根本没有这首歌」这两件事，而现在的返回值里没有这个信息。

9. **窗口位置/尺寸自己存**（2026-08-24 补，姐妹窗口「歌词窗口」2026-08-22 就修过、这扇当时漏了）。
   只靠 SwiftUI `Window(id:)` 的系统状态恢复不够：系统那套存了坐标却**不认屏幕**，多显示器拔插
   一次或改一次缩放，窗口会落在一块已经不存在的屏幕坐标上。`LyricsManagerWindowFramePersistence`
   存 frame + `ScreenIdentity` 的稳定屏幕 ID，恢复时那块屏没了就整个放弃交回系统默认，认得出但
   分辨率变了就夹进它当前的 `visibleFrame`；落盘去抖 400ms（跟列宽拖动同一个修法）。
10. ⚠️ **英文界面下整页错位**（2026-08-24 用户报，已修）。表象：左边歌名列被窗口左边界**硬切**
   且没有省略号、表头与列表行整体错开、右边详情栏的说明文字和按钮被右边界切掉；中文完全正常。
   病根是 `header` 的 `ViewThatFits` **两个候选都含整排 `.fixedSize()` 的 `headerActions`** —— 
   两个候选的最小宽度因此是同一个数，"装不下"那一档等于不存在，详情栏有了一个压不下去的硬下限。
   离屏实测（`NSHostingController.sizeThatFits`）这一排的最小宽度：中文 527pt、**英文 684pt**，
   加 `detailView` 的 20pt 内边距 ≈ 724pt。这个下限还会被 AppKit 的 `NSSplitView` autosave
   （UserDefaults 里 `NSSplitView Subview Frames lyrics-manager, SidebarNavigationSplitView`，
   存的是**绝对**子视图 frame、不认窗口现在多宽）固化下来：这台机器上实测存的是「侧栏 948 +
   详情 723 = 1671」，而窗口只有 1328pt，两栏各往外溢出 180pt——量到的错位正好就是 180pt。
   修法是给 `ViewThatFits` 补第三个候选 `headerActionsWrapped`（按钮折两排，**故意不加**
   `.fixedSize()`——最后一个候选是"都装不下也得用它"的兜底，给它固定尺寸就等于没有兜底）：
   最小宽度降到 77pt、理想宽度 EN 365 / ZH 284，中文那两档候选照旧先命中、观感不变。
   ⚠️ 走过的弯路：先试过在 `LyricsManagerWindowFramePersistence` 里加一段"子视图宽度求和 >
   bounds 就 `adjustSubviews()`"的 AppKit 兜底，**离屏样例当场证伪**——SwiftUI 托管的那个
   `NSSplitView` 的 `subviews` 有 8 个（`[1328, 698, 630, 12, 630, 0.5, 15, 15]`，原点还互相
   重叠），求和判据在健康布局上也会命中（2973.5 > 1328），而 `adjustSubviews()` 调了根本不动。
   要再碰分栏几何，先写离屏样例验证，别照"两栏两个 subview"这个直觉写。
14. ⚠️ **这扇窗最小化之后从 Dock 图标右键菜单/「Window」菜单里消失**（2026-08-25 用户报
   "开着设置/歌词管理/歌词窗口三扇窗，Dock 右键菜单里只有'设置'"，已修）。用 Accessibility
   API 现场探针实测：这扇窗（以及姐妹窗口「歌词窗口」）最小化后 `AXSubrole` 会变成
   `AXDialog`，AppKit 自动填充「Window」菜单、Dock 据此生成的窗口列表都会把 `AXDialog`
   归类成次要/临时窗口过滤掉。⚠️ 排查过程中的一次误判：先只测到「歌词窗口」出这个现象，
   一度以为是它标题栏定制（见第 07 章已知坑）独有的；这次把「设置」也一起在真正最小化的
   状态下测了一遍，三扇窗最小化后全都是 `AXDialog`——是这个 App 里 `Window(id:)` 场景的
   窗口普遍现象，不是某一扇窗独有的。「设置」（`Settings { }` 场景）反而全程没出现这个
   毛病，猜测是 SwiftUI/AppKit 对 `Settings` 场景走了不同的窗口菜单登记路径，没有深究。
   修法跟第 07 章一致：`LyricsManagerWindowFramePersistence.attach()` 里显式
   `NSApp.addWindowsItem` 把窗口塞进「Window」菜单，`willCloseNotification` 里对称
   `removeWindowsItem`，菜单里在不在从此跟 AppKit 怎么分类这扇窗无关。
15. ⚠️ **`Pick`（`LyricsSearchService.swift`）曾经把 Swift 属性默认值当成"key 缺失时的
   兜底"，但合成 `Decodable` 根本不认这回事**（2026-08-25 用户报"点重新自动匹配总说'这一轮
   没拿到结论'"，已修）：`struct Pick: Decodable` 给每个属性都写了 `= 默认值`，直觉上应该是
   "JSON 缺这个 key 就用默认值"，但 Swift 自动合成的 `init(from:)` 对缺失 key 一律 `throw
   keyNotFound`，**完全不看属性默认值**（写过一个最小复现验证，不是猜的）。而 collector 侧
   `searchLyricsPick` 的 JSON 字段几乎全带 `omitempty`：`winner` 在"没有可用候选"时是空串
   会被整个省略、`sourcesSeen`/`sourcesResponded` 在"没人应答"时是空切片会被省略、
   `resolvedDurationSecs` 在"浏览历史缓存条目、没有可靠真实时长"（传 `duration=0`）时会被
   省略、`decisionJSON` 在 **`decidable==false` 这个完全正常的分支**（当前源这一轮没应答，
   见已知坑 8 相关的 `.keptNotDecidable`）时干脆整个不写。任何一个字段被省略，
   `JSONDecoder().decode(RawSearchUpdate.self, ...)` 就整行解码失败（`LyricsSearchService.
   performSearch` 的 `drainCompleteLines` 里 `try? decode` 静默跳过、只写一行 error log），
   调用方（`LyricsManagerView.finishRematch`）拿到的 `last` 停在上一条流式候选更新（`pick`
   恒为 nil），于是保底兜底文案「这一轮没拿到结论，可以再点一次」吞掉了好几种**本该有专属
   文案**的正常结局（"这轮 X 源没应答，没有换"、"这一轮没有一个能用的候选"……）——用户点
   「重新自动匹配」看到这句时，常常不是真的"没拿到结论"，是最后一行 JSON 解码失败被整行
   丢弃。修法：`Pick` 改成手写 `init(from:)`，每个字段显式 `decodeIfPresent(...) ?? 默认值`，
   跟 Go 的 `omitempty` 语义对齐；不改 `Pick` 对外暴露的属性形状，下游
   （`LyricsManagerView`/`EnrichCacheStore`）零改动。这个坑是 `LyricsSearchService.swift`
   独有的——同文件里 `RawSearchUpdate` 早就按这个正确模式写（`sourcesDone: Int?` 之类显式
   Optional + `?? 0`），`Pick` 当初漏做了同样的处理。⚠️ selftest 覆盖不到这条：`Pick` 定义在
   App 主 target（`lyrimuse`），而 `lyrimuse-selftest` 只链 LyrimuseCore（见本文件顶部惯例），
   验证只能靠独立写的解码脚本手动跑（已跑过，覆盖 winner/sourcesSeen/sourcesResponded/
   resolvedDurationSecs/decisionJSON 五个字段各自缺失的场景，全部通过），不是自动化回归。

16. **搜索框改成"回车/按钮才查"，不是纯 `.onSubmit(of: .search)` 单靠回车**（2026-08-27，
   用户反馈"输入就卡"，第一版只接了 `.onSubmit(of: .search)` 后用户又反馈"回车也没反应"）。
   第一版思路：`filtered` 的缓存键 `filterToken` 原来直接拼 `searchText`，每敲一个字符
   token 就变、`filteredCache` 作废，几百条 `summaries` 全量重过滤一遍（还要在一次 body
   里被 4~5 处引用点各触发一次，见上面"性能口径"），逐字符可感知的卡顿就是这么来的——
   拆成 `searchText`（绑定 `.searchable`，随打字变）/`committedSearchText`（真正喂过滤
   逻辑）两份状态，只在"确认搜索"这一下才同步，能解决卡顿。但只接 `.onSubmit(of: .search)`
   (挂在跟 `.searchable` 同一条修饰符链上) 实测在这扇窗口里按回车没有任何反应——没有再深入
   摸是这个 macOS/SwiftUI 版本下 `placement: .sidebar` 的搜索框不触发 `onSubmit`、还是别的
   什么原因，用户已经明确要求"有个搜索按钮"，不需要先查清楚原生 API 为什么不灵才能给这个
   按钮。最终形态：`filterBar` 第一行最前面加一颗放大镜图标按钮（`commitSearch()`，最朴素的
   `Button.action`，不依赖 `.searchable`/`.onSubmit` 那套内部机制，点了必定生效；`searchText
   == committedSearchText` 时禁用，给"当前搜索已经是最新"的信号），`.onSubmit(of: .search)`
   保留着一起指向同一个 `commitSearch()`——哪天那个组合自己好了也无妨，两条路径不冲突。
   清空搜索框是唯一的例外，不需要用户再确认一次：`.onChange(of: searchText)` 见 newValue 为
   空就直接把 `committedSearchText` 也清空，这个方向没有过滤开销可言，卡在"搜索框空了、
   结果还是上一次搜的"比多等一次过滤更反直觉。

17. **搜索占位行选择在 Swift 侧合成，不让 collector 往缓存文件里写"正在搜索"这种半成品条目**
   （2026-08-27）。collector 那份缓存文件目前只有一种条目生命周期：「有结果才存在」——
   `resolveEnrichAsync` 只在拿到至少一项结果后才 `enrichCache[key] = e`。让它改成"先写一个
   空壳占位、有结果再补"看起来对称，但会让文件里从此有两种条目共存：真实的和占位的，第
   09/11 两章围绕这份文件建立的所有假设（唯一真源、只在有结果时写、`buildSummaries` 直接
   拿字段判定 `hasLyrics`/`isInstrumental`）都要重新审一遍哪些该对占位条目生效——为了一个
   纯展示需求换来一条新的数据完整性维度，不值得。选择完全留在 Swift 侧：`refreshPlaceholder`
   现造的 `Summary` 从不写 `raw`、从不落盘，`hasEntry(forKey:)` 只探测"真的写出来了没有"，
   collector 那边毫不知情、毫无改动。代价是这一条必须在 App 侧手动维持"跟真实条目一致"
   （标题/歌手/专辑跟着 `PlaybackCoordinator` 实时变，真实条目一出现立刻让位）——比在
   collector 侧原生支持贵一点，但比"两套生命周期共存在同一份持久化状态里"安全得多。
   ⚠️ **2026-08-28 补的例外**："占位行毫不知情"这条只管**展示**——「停止搜索」按钮上线后
   collector 确实需要知道"该不该中断这一轮解析"，但走的是完全独立的一条信号（文件 +
   `context.CancelFunc` 登记表，见上面「搜索占位行」小节），不是往 `enrichCache` 里塞占位
   条目、不动这份文件唯一真源的约定——跟本条决策不矛盾，只是给"collector 毫无改动"这句话
   打了个补丁:它现在会响应取消,但从不会为占位状态本身写盘。


18. **collector 导出歌词文件改成原子写（2026-09-02）**：`lyricsexport.go`
    之前直接 `os.WriteFile`（先截断再写），而 `importLyricsFromFiles` 只校验头部三行、**正文不校验**、
    内容不同就覆盖缓存——崩溃 / 断电 / 磁盘满留下的空文件或半截文件，下次 collector 启动就会以
    「用户文件」身份把缓存里完整的歌词顶掉，手改过的 manual_lyrics 也在这条路上。同仓 `saveEnrichCache`
    与 App 侧 `saveEdit`（`atomically: true`）早就是临时文件 + 改名，只有导出没跟上。现在
    `writeLyricsFileAtomic`：同目录 `os.CreateTemp`（`<base>.lrc.tmp.随机`）→ 写 → `chmod 0644`
    （CreateTemp 默认 0600，补成跟以前一致）→ 改名，任一步失败删临时文件并记日志；不 fsync（与
    saveEnrichCache 一致）。临时文件名不以四个歌词后缀收尾，所以导入分组、本窗口的目录扫描
    （`lyricsFileSuffixesLongestFirst`）与备份归档（`EnrichCacheKeys.lyricsFileSuffixes` 过滤）都会自动
    忽略它；崩溃残留由 `importLyricsFromFiles` 启动时清扫一次（`isLyricsTempFile`，只在启动做——导出
    过程中扫会误删另一轮正在写的临时文件）。**§1 那条「mtime 当最近更新信号」不受影响**：导出仍先
    比对全文、逐字节相同就不写，改名后的 mtime 就是这次真正写入的时刻。顺带消掉一个并发坑：
    `exportLyricsFiles` 有 8 个调用点、文件写入那段没有锁，两轮导出同时写同一个文件时 WriteFile 会
    互相截断交错；各写各的临时文件再改名，最后改名的赢、内容完整（单测
    `TestExportLyricsFilesConcurrentWritesStayWhole` 八路并发钉住）。刻意**不动导入侧的校验**：导入要
    能采纳用户手写的任何内容，「正文不校验」是刻意的，原子写把问题在源头堵住就够了。同类非原子写
    还有 collectorstatus / daily / lastfm / topartists / weekly / deviceartwork 六处，读方都能容错，
    没一起改。

19. **「搜索歌词…」小窗切歌后串 key（2026-09-02）**：悬浮窗 ⚙ 的独立小窗（`LyricsQuickSearchWindow`）
    2026-08-31 为修「再点一次还是上一首」改成每次点击重查曲目、替换 `context`，但 `if let context {
    LyricsSearchSheet(...) }` 从 Optional(A) 到 Optional(B) 是同一个 SwiftUI 视图身份：面板的查询词
    `@State` 与首次挂载才跑的 `.task` 都不重置，界面仍是上一首的查询词和候选（「恢复原信息」凭空出现是
    可见征兆），`onApply` 捕获的却是新曲目的 key——采纳把上一首的歌词写进当前这首的条目，lyrics/
    文件族随之落盘（文件是权威源，collector 重裁覆盖不回来），开了「采纳即锁定」还会把它冻住。
    修在 `LyricsSearchSheet` 内部（本窗口也用它，原始字段在面板存活期间不变，行为不受影响）：三个原始
    字段拼成 `searchSubject`，`.task(id: searchSubject)` 重搜、`.onChange(of: searchSubject)` 把查询词
    重置回原始值。**刻意不用**宿主层 `.id(context.key)` 整棵重建：离屏 `NSHostingView` 探针实测重建时
    新面板 `.task` 先起、旧面板的任务取消与 `onDisappear` 后到，两者都调全局
    `LyricsSearchService.cancelRunning()`（杀「当前在跑的那个」），新起的 collector 子进程 3/3 被杀；
    `.task(id:)` 由 SwiftUI 保证先取消旧任务再起新任务。真机复现步骤：开小窗 → 切歌 → 再点
    「搜索歌词…」或按热键 → 查询框应立刻变成新歌名、候选重载、没有「恢复原信息」按钮。

20. **排序规则搬进 LyrimuseCore，并给「无歌词文件 / 无来源」这两个尾块补一个次级时间键**
    （2026-09-02，用户报「歌词管理页面的排序有时候选了不生效」，截图是「仅无歌词」开着 +
    「更新时间 新→旧」，列表却仍是歌手字母序）。
    - **不是比较器写错，是这批数据让排序无从下手。** `lyricsUpdatedAt` 取的是**导出歌词
      文件的 mtime**，而「仅无歌词」筛出来的行按定义**没有歌词文件**（export 会跳过），
      于是整屏 `lyricsUpdatedAt` 全是 nil → 全部落进同一个「无时间戳」尾块 → 由平局键
      `(歌手,专辑,歌名)` 决定顺序，而那恰好**就是**「默认排序」。用户看到的"选了没反应"
      是真的没反应，只是原因在数据形状上，不在代码分支上。
    - 同一屏「来源 A→Z / Z→A」也塌：2026-09-02 实测本机 14 条命中「仅无歌词」，
      `lyrics_source` **全为空**，`sourceDisplayName("")` 都是「无来源」这同一个字符串。
    - **排除过另一种可能**：不是 mtime 字段集体失真（第 19 条那个前提垮掉的形态）。实测
      `lyrics/` 下 7707 个文件、1972 个不同 mtime 秒值、散布在 08-22～09-02，有歌词的行
      排序是好的。
    - 修法：`Summary` 新增 `resolvedAt`（缓存里的 `ts`，collector 侧 `enrichEntry.TS`，
      语义是"这条上次被解析出来的时刻"），**只作次级键**：
      - 「更新时间」——无 mtime 的尾块**整体仍排最后**（不变），块内从歌手字母序改成按 ts；
      - 「来源」——无来源的行改成**两个方向都排最后**（原来是按「无来源」这个展示名参与
        字母序），块内同样按 ts；
      - 同一来源内部**不动**，仍按 `(歌手,专辑,歌名)`——「来源」这一档表达的是分组，不是
        组内次序。
      实测那 14 条 **14/14 都有 ts 且取值互不相同**，排出来的顺序与事实吻合。
    - ⚠️ `resolvedAt` **不是** `lyricsUpdatedAt` 的替代品，两者量纲不同：mtime 是"歌词正文
      上次真的变过"，ts 是"这条上次被解析过"（重搜一轮没搜到新东西也会把 ts 推到当下，而
      正文没变、mtime 不动）；覆盖率也更低（2026-09-02 实测 2445/3402 ≈ 72%，mtime 是
      3169/3210 ≈ 99%）。所以只在"那一档本来注定是一团平局"的尾块里用它。
    - **为什么顺手把规则搬去 LyrimuseCore**：比较器原来是 `LyricsManagerView.swift` 里一个
      `private enum` 的方法，而 `lyrimuse-selftest` 只依赖 LyrimuseCore、够不到它——这套
      规则（哪一档优先、平局怎么断、缺失值排哪儿）此前**一行自动化覆盖都没有**，而这次的
      bug 恰恰是"逻辑对但在某些数据形状下退化成静默无操作"，肉眼看列表发现不了。搬完跟
      `EnrichCacheKeys` 同一个待遇：视图层只负责映射 `lyricsSortKey`，规则可被逐档钉住。
      排序键一次性算好再排（`sourceDisplayName` 要走 L10n 查表，不能放进 O(N·logN) 的
      比较里）。
    - 回归口径（用户要求）：selftest **2124 条断言全过、0 失败**（本条新增 20 条）；
      **13 个变异全部被抓、0 漏**——其中「同一来源内部改成按 ts」这条一开始**没被抓到**，
      查下来是我自己那条断言写空了（用例里 ts 顺序与歌手字母序恰好一致，两种规则给出同一个
      结果），把 ts 改成与字母序相反后才真正生效，用例里留了注释钉住这一点。另外单独验过
      `entry["ts"] as? Double` 对 JSONSerialization 的 `__NSCFNumber` 确实取得到值
      （拿真实缓存跑：目标条目解出 2026-09-02 21:32、全库 2445/3402），否则整个修复会是
      静默空操作。
    - ⚠️ **未做端到端界面验证**：本仓禁止用 AppleScript/System Events 驱动界面，而「歌词
      管理」窗口在 App 重启后是关着的、`sortOption` 又是不持久化的 `@State`，无法在不驱动
      界面的前提下复现"开着「仅无歌词」+ 选「更新时间」"那一屏。已验的是规则层与数据层。

21. **小窗采纳「无时间戳」候选没有分流成静态文本（2026-09-04）**：`LyricsQuickSearchWindow` 的 onApply 从 08-30 加纯文本候选起就没有 `isPlainTextOnly` 分支——歌词管理与歌词窗口两处都按它走 `savePlainTextEdit`，小窗却把纯文本直接当 LRC 喂进 `saveEdit`，后果正是 `savePlainTextEdit` 头注写的：这首歌在别的展示面上从「至少有静态文字」退化成「看起来完全没有歌词」。跟 09-01 补 `markManual` 时漏掉歌词窗口那处是同一种失误（改了两处漏第三处）。这次除了补分流，selftest contracts 组加了「采纳候选入口」守卫：先数 `LyricsSearchSheet(` 的非注释调用点必须恰好是那三处（新入口必须来守卫登记、顺便读一遍规矩），再逐处查 `isPlainTextOnly` / `savePlainTextEdit(` / `manualPickLocksLyrics` / `fromManualPick: true` 四个记号。同日小窗改成采纳后不关窗（`keepsOpenAfterApply`，见 04 章「小窗采纳后不关窗」），`saveEdit` / `savePlainTextEdit` 因此改为返回落盘成败（`@discardableResult`，老调用点不用改）。
