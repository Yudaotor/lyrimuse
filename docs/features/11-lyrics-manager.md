# 11. 歌词管理窗口

> 最后核对：2026-08-20 · 基线：2a2bf8b+工作树

## 定位

已缓存歌词的管理台：浏览/筛选全部缓存条目，编辑、删除、移除逐字、联网重搜候选、查看当初的解析决策，以及歌词文件夹的落点管理。

## 入口与展示面

- 菜单栏菜单「歌词管理…」、全局快捷键 `openLyricsManagerHotkey`、设置 → 歌词 → 管理段「打开…」。
- SwiftUI `Window(id: "lyrics-manager")`；accessory 策略下打开前必须 `NSApp.activate`。

## 行为规格

### 1. 列表与筛选

- 四列表头：歌名/歌手/专辑/来源（来源列中文名：网易云音乐/QQ音乐/酷狗音乐，LRCLIB/Musixmatch 保留英文；色点=来源身份色，与设置页「歌词来源」同一套 `sourceColor`）。
- 列宽可拖并持久化（`LyricsColumnWidthsStore`：@Published+didSet 落 UserDefaults，夹值算术是纯函数、selftest 覆盖）。拖动中只更新内存值（beginDragging/endDragging，2026-08-19），松手一次性落盘——原来每个鼠标事件写三笔 UserDefaults 中间态。
- 筛选：文本搜索 + 歌手/专辑下拉（归并键=toSimplified+小写，繁简/大小写不敏感）。**性能口径（2026-08-19 审计落地）**：繁简归一化键/搜索小写副本在 `Summary` 构建时预存（`normPrimaryArtist`/`normAlbum`/`search*Lower`），排序比较器只做元组比较；歌手/专辑归并展示名与下拉候选下沉进 store 随 summaries 重建一次（原来是视图计算属性，List 每物化一行就全量重建一次 O(N) 归并字典）；`filtered` 经缓存盒按 (filterToken, summariesGeneration) 记忆化（一次 body 被 4~5 处独立求值）；`toSimplified` 本体按原串 memoize。summaries 的构建+排序在 reload 的后台 task 里做，主线程只收结果。
- 「回到当前播放」：`focusCurrentlyPlaying` 滚动定位到正在播的条目（开窗时自动跑一次，`pendingAutoFocus` 闸 + `onDisappear` 复位；工具栏按钮手动跑）。⚠️ 匹配用的 key **必须**走 `EnrichCacheKeys.normalizedKey`（Swift 侧缓存 key 的唯一构造点，逐字节镜像 collector 的 `enrichKey`），不能手拼 `artist|title|album`：手拼会漏掉 `cleanTag`（各类空格/零宽字符）和 `normalizedTitle`（循环剥结尾括号副题）两道清洗。2026-08-20 用户报「进歌词管理不会自动定位」就是这条：Apple Music 报 `Dynasties and Dystopia (from the series Arcane League of Legends)`，缓存里那条 key 是剥掉副题的 `Dynasties and Dystopia`——精确匹配落空，而 `looseKey` 只折大小写/空格/繁简、折不掉副题，兜底也接不住，函数**静默返回**（设计如此：开窗自动定位不该弹提示），表现成压根没定位。现在的候选顺序是 归一化 key → 原样拼的 key（key 归一化上线前入库的老条目）→ 两者各自的 `looseKey`。悬浮窗/灵动岛一直没这个问题，因为 `EnrichCacheReader` 本来就走 `normalizedKey`。
- 支持多选批量删除（`delete(keys: Set)`）与「清空全部」（`clearAll`，破坏性操作）。
- 工具栏「占用」菜单里是**两段独立**的清理入口：「清空全部缓存」清歌词内容（缓存 JSON + `lyrics/` 文件夹），「清空全部时间轴校正」清用户手调的偏移值（UserDefaults + 已校准名单）。两者互不连带 —— 存储位置本来就不同，而校正值是一句句听出来的，比"下次播放会自动重新解析"的歌词内容宝贵。确认弹窗挂在最外层 `NavigationSplitView`（删除挂 List、清缓存挂侧栏链，三个层级分开，避免同链叠多个呈现修饰符互相顶掉）。
- 详情页「已校准」徽章（`timer` 图标）标出这首歌调过时间轴偏移。必须显式标出来，因为它带一个看不见的副作用：collector 从此不再自动给这首歌重选歌词源（见第 8 章）。偏移区下面那行小字说明后果与解除办法（改回 0）。

### 2. 数据层（EnrichCacheStore）——与 collector 的共存契约

- collector 是缓存文件的**唯一真源**（内存 map 整体覆盖写盘）。App 侧每次改动必须：①落盘；②重启 collector 让它重读——否则 collector 随时可能用「没看到这次改动」的内存旧态整个覆盖回去，静默撤销编辑。重启一律走 `scheduleCollectorRestart` 后台排队（合并连发+补偿重启）：saveEdit 2026-08-19 起与 delete 同款「先刷列表→落盘→排队重启」，不再原地等 kickstart（撞上 launchd minimum-runtime 时一等就是 ~10s）。`persist()` 的整段读-改-写（读盘 9.4MB+解析+merge+序列化+原子写）2026-08-19 挪到后台 Task 并经 persistChain 串行化（两笔绝不并发写盘；飞行窗口内的新修改由下一笔落盘，不会被整份回写覆盖）；`reload(onlyIfChanged:)` 有 (mtime,size) 指纹门控——App 每次激活触发的刷新在文件没变时整条链不跑。
- 用 **JSONSerialization 原始字典**而非 Codable：窄结构体解码再编码会把**每一条**没声明的字段悄悄丢光（Go 侧字段还在增加）；字典级只动被编辑那一条的目标 key，其余逐字节不变。
- 歌词六字段（lyrics/tr/roma/yrc/source/manual_lyrics）以 `~/.config/lyrimuse/lyrics/` 文件族为权威源：saveEdit/delete 在改 JSON 的同时同步写/删对应 `.lrc`/`.tr.lrc`/`.roma.lrc`/`.yrc` 文件，靠「改完立刻重启」保持两边一致。

### 3. 编辑 / 删除 / 移除逐字

- **编辑**（saveEdit）：写歌词/译文/罗马音（可选换 yrc/source），并置 `manual_lyrics = true`——此标记冻结 collector 一切自动重搜/重打分（第 09 章）。
- **删除**：连带删除已导出的歌词文件（用户要求的「真删除」，推翻早期「文件只写不删」设计）；删除后条目从缓存与文件夹双双消失，下次播放该歌会重新解析。
- **移除逐字**：入口按钮 2026-08-18 删除后，实现（removeWordTiming）2026-08-19 一并下线（死代码）；恢复见 git 历史。

### 4. 联网搜索候选歌词（LyricsSearchSheet + LyricsSearchService）

- 不在 Swift 重写检索——一次性子进程调 `collector search-lyrics`（复用自动解析同一份五源检索+打分，第 09 章），NDJSON 流式：每个源到达即整表重排显示，带进度 X/Y、网络不通标记。
- 候选带分数与**得分明细/被拒原因**（score_terms）摊开展示；按用户启用的源过滤；lrclib 纯音乐标记不当候选显示。
- 搜索途中可再点「重新搜索」：上一轮子进程被显式杀掉（否则白跑满 20s 占五源请求），结果以 searchGeneration 判废。关闭 sheet/采纳候选同样会停掉子进程（onDisappear + search() 内 withTaskCancellationHandler 双层，2026-08-19）；stderr 读取在独立队列（与 stdout 串行同队会把 64KB 管道死锁在 stderr 侧引回）。
- 用户点选采纳才落盘（走 saveEdit 路径，置 manual 标记）。

### 5. 解析决策查看（LyricsDecisionSheet，只读）

展示 collector 在**真正做决定那一刻**固化的 `lyrics_decision`：路径（首次解析/升级重试/规则换版重选）、哪些源应答、各候选分数与被拒原因、胜者。与「联网搜索」的本质区别：那是**现在**重新抽签（受 20s 期限影响，候选和当初不一定一样），这是当初那轮的**离线存档**。完整结构懒解码（`decodedDecision(for:)`，2026-08-19）：列表/按钮只用 `hasDecision` 布尔，打开弹窗那一刻才按 key 解一条——原来 rebuild 时对每条带该字段的条目全量做 JSON 双重编解码。刻意不提供「改用某条」按钮——存档里没有正文（collector 三铁律），想换歌词走联网搜索。

### 6. 歌词文件夹（设置 → 歌词 → 管理段）

- 路径展示 + 「选择文件夹…」（NSOpenPanel，改 `features.lyricsDir`）+「打开歌词文件夹」（不存在先兜底创建）+「恢复默认位置」（lyricsDir 置空）。换文件夹后旧文件不自动搬。
- 文件格式：每条目最多 4 个文件，头部 `[ar:]/[ti:]/[al:]/[source:]/[manual:1]` 标签；collector 启动时「文件赢」导入覆盖 JSON（只增不删）；大小写碰撞组加 crc32 哈希后缀消歧。

## 设置项

| 位置 | 项 | 影响 |
|---|---|---|
| 歌词→管理 | 歌词管理 打开… | 打开本窗口 |
| 歌词→管理 | 歌词文件夹（选择/打开/恢复默认） | `features.lyricsDir`（features.json+kickstart） |

## 与其它功能的交互

- `manual_lyrics` 是对第 09 章全部自动自愈路径的一票否决。
- 每次保存/删除触发 collector 重启 → 歌词/推送短暂中断（与第 14 章 features 保存共用 `CollectorControl`，那边有 0.5s 去抖，这边是单次操作直接踢）。
- 删除条目 → 下次播放重新解析（缓存永久性的唯一显式出口）。
- 「联网搜索」结果的打分与自动路径完全同源——弹窗里看到的分数可与决策存档对比（时长输入不同会导致差异，决策存档正是为此存了 duration_secs）。

## 数据与文件

- `~/.config/lyrimuse/lyrimuse-enrich-cache.json`（原始字典级读写）。
- `~/.config/lyrimuse/lyrics/`（或用户自选目录）：`<artist> - <title>[#hash].lrc/.tr.lrc/.roma.lrc/.yrc`。
- UserDefaults：列宽三键。

## 代码锚点

| 主题 | 位置 |
|---|---|
| 窗口主视图 | LyricsManager/LyricsManagerView.swift（列表/筛选/focusCurrentlyPlaying/sourceDisplayName/sourceColor） |
| 数据层 | LyricsManager/EnrichCacheStore.swift `saveEdit` `delete` `clearAll` `splitKey` `buildSummaries` `persist`(后台+串行链) `reload(onlyIfChanged:)` |
| 联网搜索 | LyricsManager/LyricsSearchSheet.swift、LyricsSearchService.swift；collector 侧 searchcli.go |
| 决策弹窗 | LyricsManager/LyricsDecisionSheet.swift；数据 decision.go |
| collector 重启 | LyricsManager/CollectorControl.swift（launchctl kickstart -k + 真实退出码检查） |
| 列宽 | LyricsManager/LyricsColumnWidthsStore.swift + LyrimuseCore/Lyrics/LyricsColumnLayout.swift |
| 文件导出/导入 | collector 侧 lyricsexport.go / lyricsimport.go |

## 设计决策与已知坑

1. Codable 窄结构体整读整写会丢掉全库未声明字段——必须字典级原样保留（上百条数据的破坏性 bug 教训）。
2. 「改完立刻踢重启」是与 collector 共存的唯一一致性机制，代替常驻 IPC 接口；个人工具偶尔手动操作可接受。
3. 删除连带删导出文件：早期「永久保留导出」设计被用户显式推翻。
4. 重复条目的两道防线（key 归一化迁移 + 在途宽松查重）之间仍可能漏「空格/繁简」变体，查询侧做了宽松兜底但 key 本身不折繁简——折进 key 会让 Swift 侧悬浮窗整首失配（第 09 章 key 契约）。2026-08-20 补上第三档「合 credit 分隔符」（`A/B/C` vs `A & B & C`，两侧 `loosenEnrichKey`/`EnrichCacheKeys.looseKey` 同步折平）：这一档是**专辑预取**跟播放器的写法差异带来的，一次实测就有 13 组，机制与清理过程见第 09 章 §2。
5. 决策弹窗只读是刻意的：存档无正文，「从存档采纳」这种操作在数据上就不存在。
6. 搜索子进程必须可中断，否则连点重搜会积压 20s 的幽灵轮。
7. 「清空全部」曾在一次脚本化 GUI 验证中被误触发导致 833 条手工修正丢失——对这个窗口做任何自动化操作前必须备份缓存与 lyrics 文件夹（repo CLAUDE.md 硬规则）。
