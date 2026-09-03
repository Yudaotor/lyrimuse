# Last.fm 模块缓存策略设计（存量 / 增量 / 交互→请求 / 不感知加载）

> 起草：2026-09-03 · 基线：工作树（`LastfmStatsService.swift` 3103 行版）· 状态：**已按本文实施（阶段 1 + 阶段 2 + 阶段 3 的 7 条）**，落地记录见 `docs/features/12-scrobble-accounts.md`「缓存策略重构（2026-09-03）」。用户拍板：不考虑 ListenBrainz（feed 拉取只看 Last.fm 凭据）、其余决定权交给实施者。
>
> 读法：第 0 节是一页摘要；第 1–2 节是现状与问题（全部带 file:line 和本机实测数据）；第 3–8 节是目标态；第 9 节是分阶段实施；第 10 节对照既有不变量；第 11 节列出需要作者拍板的点。

---

## 0. 一页摘要

**现状一句话**：数据层已经是"快照先端上桌、后台再刷"的雏形（`StatsSnapshot` / `recentPageCache` / 热力图与写法索引落盘），但**刷新驱动仍是轮询 + 全量重拉**，且所有请求都从 App 进程直连 Last.fm——而本机实测这条链路 **p50 1.2 s、p90 6 s、16% 超时**（走系统代理 127.0.0.1:7897；collector 那条 Go 直连链路同一时段 p50 0.4 s、1% 失败）。于是所有"等网络"的界面态（换歌后徽章消失再出现、`···`占位、翻到第 11 页转圈、那年今日每次启动"正在查"、三个数字下面时不时冒出的「重试」）都被这条慢链路放大成用户能感知的等待。

**目标**：每个 Last.fm 数据面在 t=0 都有内容（存量）；网络只负责在背后把内容变得更新（增量），用户永远不看见转圈/空白/闪烁；请求量比现在少一半以上，且不再依赖 App 那条慢链路承载热路径。

**核心改法（5 条）**：

1. **collector 当"最近记录"的唯一拉取方，App 改为读本地 feed 文件**。collector 本来就每 15 s 拉一次 `user.getrecenttracks`（iPhone 桥接，`poller.go:182`），响应里已经有 App 要的一切：now-playing 行、最近 50 条、`@attr.total`。把它落成 `lyrimuse-lastfm-recent-feed.json`，App 按 mtime 监听（形制照抄 `lyrimuse-lastfm-status.json` 那条通道）。App 侧最近记录/实时行/总数从此**零请求、≤15 s 新鲜**，且走的是快链路。
2. **今天 / 近 7 天从本地日桶派生，不再每轮各发一个请求**。`dailyCounts`（热力图桶）+ feed 增量行 = 今天；近 7 天早已按日桶算（`LastfmStatsSection.swift:224`）。`refreshBaseline` 的三个请求收成 0（feed 在）或 1（feed 不在）。
3. **"作废"改成"标记过期、旧值照显"（真正的 stale-while-revalidate）**。今天 `applyRecent` 一判过期就把 `trackPlayCounts[key]` 置 nil（`LastfmStatsService.swift:2225`），界面立刻退成 `···`，等 1–9 s 才回来；换歌时 `nowPlayingCount = nil`（`:576`）同理。改成保留旧值、另记 `stale` 集合，只有**从未有值**才显示占位。
4. **失败不打扰**：有存量时，一次超时只在卡头把「N 分钟前更新」变暗，不再弹「重试」行（`LastfmStatsSection.swift:213`）；三个 baseline 请求拆开各自落地，不再 all-or-nothing（`LastfmStatsService.swift:1897`，本机链路下 41% 的整轮刷新被一个超时拖成全失败）。
5. **该落盘的都落盘**：「那年今日」按日历天进快照（现在每次启动都"正在查"）；榜单/那年今日的 `fetchedAt` 持久化（现在每次启动 TTL 归零全部重拉）；翻页缓存区外**预读下一页**。

**预期效果**（估算，见第 7/8 节）：设置页常开 + 本机听歌时 App 侧 Last.fm 请求从 ≈190/h 降到 ≈45/h；换歌到"上一首出现在列表顶上"从 11–19 s 变成 ≈10 s 且 0 App 请求；冷启动/切回/翻前 10 页/切 tab 全部 0 等待；唯一残留的可见等待是"跳到第 11+ 页"和"首次连接的全量同步"（后者本来就有进度条）。

---

## 1. 现状盘点

### 1.1 数据实体清单

| 实体 | 来源 | 消费面 | 内存状态 | 落盘 | 新鲜度/节流 | 存量→增量方式 | 代码锚点 |
|---|---|---|---|---|---|---|---|
| 今天/近7天/总量 `overview` | 3 个 `user.getrecenttracks`（page1 的 `@attr.total`；`from=今日0点&limit=1`；`from=7天前&limit=1`） | 设置页数字卡、待机页 `IdleOverviewCard`、歌词窗口欢迎态 | `overview` | `StatsSnapshot` | `baselineTTL` 110 s（内存 `fetchedAt`，重启归零） | 每轮全量重拉 3 请求；近 7 天实际已改用日桶（`LastfmStatsSection.swift:224`） | `LastfmStatsService.swift:1854–1917` |
| 最近记录当前页 `recent` | `user.getrecenttracks limit=20 page=N` | 设置页最近记录卡、待机页/歌词窗口 `RecentListensPanel` | `recent`、`recentPage`、`recentTotalPages` | 快照只存第 1 页；`recentPageCache` 另存前 10 页 | 同上 110 s；页缓存 5 min（`:149`） | 全量重拉当前页 | `:1854`、`:2685`（goToPage）、`:2728`（revalidate） |
| now-playing 行 `apiNowPlaying` | 同上响应第一条（无 date） | 实时行红点"正在记录"、远端会话判定 | `apiNowPlaying`/`Since` | 不落盘（刻意） | 随 baseline；远端会话 45 s 强刷 | — | `:387`、`LastfmStatsSection.swift:1164` |
| 「第 N 次听」总数 `trackPlayCounts` | `track.getinfo&username`，每首 1 + 孪生 ≤8 个请求，并发 4 | 最近记录行、实时行追赶、待机页列表、那年今日 | `trackPlayCounts`/`playCountUnavailable`/`playCountsInFlight` | 快照（仅第 1 页范围）+ 页缓存（前 10 页范围） | 四条作废判据①②③④（`:2172–2234`）；③节流 5 min（不落盘）；④ 24 h（落盘 `playCountVerifiedAt`） | 缺哪首查哪首；作废即置 nil 重取 | `:2437–2599` |
| 实时行次数 `nowPlayingCount` | `track.getinfo` 1 + 孪生（并发） | 实时行、歌词窗口徽章、简介面板 | `nowPlayingCount` | 不落盘 | 换歌取一次；`reconcileNowPlayingCount` 只涨不跌 | — | `:571–642` |
| 收听跨度 `nowPlayingSpan` | `user.getTrackScrobbles` ×2 | 简介面板 | `nowPlayingSpan` | 不落盘 | 面板打开那一刻取 | — | `:648–692` |
| 榜单 `charts[kind\|period]` | 专辑/歌曲榜直连 `user.gettop*` limit 10；歌手榜 spawn `collector top-artists -all-periods` | 设置页榜单卡、歌词窗口常听面板 | `charts`/`chartLoadingKeys`/`chartFailedKeys` | 快照 | `ttl` 15 min（内存） | 全量重拉；歌曲榜再补 10 个 `track.getinfo` 封面（并发不限，`:2812`） | `:2757–2913` |
| 歌手头像 `artistAvatars` | spawn `collector artist-avatars`（QQ/Deezer，14 天磁盘缓存） | 歌手榜 | `artistAvatars` | 快照 + collector 自己的缓存 | 缺谁查谁 | — | `:2917–2958` |
| 那年今日 `onThisDay` | `user.getrecenttracks from/to` 1–3 年 × ≤3 页 | 设置页卡、歌词窗口欢迎态 | `onThisDay`/`Outcome`/`Day` | **不落盘** | 6 h TTL 或跨天（`DailyRefreshGate`）；失败也占 TTL | 全量重拉 | `:727–822` |
| 每日热力图桶 `dailyCounts` | `user.getrecenttracks limit=200` 全量分页 | 热力图 popover、待机页走势/日均/近 7 天、迷你热力图 | `dailyCounts`/`dailySyncedThrough` | `lyrimuse-lastfm-daily-heatmap.json` | 首次全量（~110 页，断点续传）；之后 15 min 节流 top-up | **真增量**：从最后同步天 0 点起 `from=` 重拉 1–3 页 | `:824–1149` |
| 写法索引 `titleForms` | 同上扫描顺手收割 + 每批已拉到的行 | 「第 N 次听」孪生查询 | `titleForms`/`primaryCreditFamilies` | `lyrimuse-lastfm-title-forms.json`（`foldVersion` 闸） | 与热力图同一次扫描 | 真增量（零额外请求） | `:1151–1339` |
| 别名自动发现 | `track.getinfo`（无 username），每轮 ≤12 候选 × (1+汉字组候选数) | 「第 N 次听」合并口径 | `discoveredTitleAliases` 等三张表 | `lyrimuse-lastfm-title-aliases-discovered.json` | 挂在每次 top-up 收尾；30 天冷却 | 增量 | `:1341–1646` |
| 封面五级 | ①行自带 ②本机 enrich ③`track.getinfo` ④同专辑兄弟 ⑤iTunes Search（批 6、并发 2） | 最近记录/那年今日/实时行 | 五张字典 | 快照存 ③④⑤（第 1 页范围） | 随 `applyRecent`；`coverUnavailable` 时序闸 | 缺哪行查哪行 | `:1939–2135`、`:2282–2340` |
| 历史扫描断点 | — | — | `historyCheckpoint` | `lyrimuse-lastfm-history-checkpoint.json` | 每 10 页落一次 | — | `:877–917` |
| 镜像熔断状态 | collector 写 | 账号页红标 | `LastfmMirrorStatusWatcher` | `lyrimuse-lastfm-status.json` | App 5 s 定时读 mtime | — | `LastfmMirrorStatus.swift:69` |
| collector 侧：桥接 recent | `user.getrecenttracks limit=50`，**每 15 s** | iPhone→LB 转发、远端 now-playing 镜像 | poller 内存 | `-mirrored/-forwarded.json`（7 天 TTL 集合） | 15 s（`lastfmPollInterval`）；**只在 LB 也配好时才跑**（`poller.go:1030`） | — | `poller.go:1017–1046`、`lastfm.go:465–523` |
| collector 侧：Top 歌手/周报/日报 | `user.getTopArtists`、`getWeeklyChartList`… | 网页 relay、飞书推送 | — | `-top-artists.json`（只存 `last_at`）、`-weekly.json` | 24 h / 2 h / 30 min（**内存节流，重启归零**） | — | `topartists.go:20`、`weekly.go:18`、`daily.go:15` |

### 1.2 交互 → 请求矩阵（现状）

| 交互 / 事件 | 触发路径 | 发出的请求 | t=0 用户看到 | 感知等待？ |
|---|---|---|---|---|
| 冷启动（App 进程起来） | `AppDelegate.swift:137` 触碰单例 → `loadSnapshot`/`loadRecentPageCache` | 0 | — | 否 |
| 打开设置 → Last.fm 页（`.stats` 段） | `LastfmStatsSection.onAppear:91` → `refreshBaseline` + `refreshChart`（榜单未收起时）+ `refreshOnThisDay`；`refreshBaseline` 内先 `ensureFirstSyncBootstrap` | baseline 3 + 榜单 1（歌手榜=spawn 进程）+ 那年今日 1–9 + 15 min top-up 1–3 页 + `resolvePlayCounts` 对过期/缺失行 N×(1+孪生) + 封面补查 | 数字/第一页/榜单：快照即显；**那年今日：「正在查」**；过期行次数：`···` | **是**（那年今日、`···`、封面灰块） |
| 切 统计/榜单/那年今日/设置 tab | 只改 `selected`，View 不卸载 | 0（榜单收起→展开时 1） | 即显 | 否 |
| 切榜单种类/周期 | `Picker` set → `refreshChart` | 未命中 15 min TTL 时 1（歌手榜四档一次拿全）+ 歌曲榜 10 封面 | 有快照即显；**首次该组合：10 行骨架** | 首次是 |
| 翻页 ≤10 页 | `goToPage` 命中 `recentPageCache` 同步 apply；过期则背后 revalidate | 0 或 1（静默） | 即显 | 否 |
| 翻页 >10 页 / 跳页 | `goToPage` 未命中 → `recentPaging=true` | 1 + 该页 20 行 `resolvePlayCounts`（≤20×(1+孪生)）+ 封面 | **转圈** 1–9 s（本机链路） | **是** |
| 换歌（本机） | `LiveScrobbleRow.onChange(liveKey):1141` → `refreshNowPlayingCount`；`onChange(playback.title):1150` → 10 s 后 `refreshBaseline(force:)`；歌词窗口徽章 `LyricsWindowView.swift:4156` 同一入口（key 守卫去重） | 1+孪生（并发）；10 s 后 3 | **徽章先消失**（`nowPlayingCount=nil`），1–9 s 后出现；上一首 11–19 s 后进列表 | **是** |
| 达标 scrobble（collector 镜像成功） | 无 App 侧信号；只靠上面那次 10 s 强刷或 110 s 轮询 | — | — | 间接 |
| 打开「显示简介」 | `InfoPanelListeningRows.onAppear:4192` | 2（`getTrackScrobbles` 首/尾页） | 行缺席直到回来 | 是（轻） |
| 切回 App | `didBecomeActive:110` → `refreshBaseline` + `refreshOnThisDay`（过 TTL 闸） | 0–3 | 旧内容 | 否（内容 1–9 s 后悄悄换） |
| 设置页常开 | `.task` 120 s：`refreshOnThisDay`（跨天才发）+ `refreshLocalCoversIfCacheChanged`（stat）+ `refreshBaseline` | 每 110 s 3 | — | 否；但 16% 超时 → **「重试」行时不时冒出**（`:213`） |
| 待机页 / 歌词窗口欢迎态常开 | `IdleStandbyView.swift:75` 180 s；`IdleLastfmSection:4244` 180 s；`refreshDailyCounts` 每 20 轮 | 被 110 s TTL 合并；3 个面都开着时仍是每 110 s 3 | — | 否 |
| 远端（手机）会话 | `LiveScrobbleRow.task:1164` 45 s `force` | 每 45 s 3 | — | 否 |
| 跨零点 | `.task` 里 `refreshOnThisDay` 跨天判定 | 1–9 | 旧卡保留到新数据来（已修） | 否 |
| 断网 / 超时 | `request` 10 s 超时，429/29 退避 3 次 | — | 有存量：**「重试」行**；无存量：空/失败态 | 是（噪音） |
| 连接 / 断开 / 换账号 | `AccountLinkingTab.swift:1130` → `resetAll` 删 6 个文件；`LastfmAuthFlow` → `ensureFirstSyncBootstrap` | 首次全量 ~110 页 + 收尾 3 + 12 榜单 + 10 页预取 + 次数解析 | 进度条「首次同步历史中（N/M 页）」 | 是（有进度，可接受） |
| 回填完成 | `ScrobbleBackfillService` → `refreshBaseline(force:)` + `rewindDailySyncForBackfill` | 3 + 下次 top-up 多 1–2 页 | — | 否 |
| 菜单栏面板打开 / Dock 菜单 | 不读 Last.fm | 0 | — | 否 |
| iPhone 桥接进新记录 | collector 15 s 内知道；App 要等 45 s/110 s 轮询 | — | 45–110 s 后出现 | 间接 |

### 1.3 本机实测（2026-09-02 22:00 → 09-03 00:50，`log show --predicate 'category == "network-audit"'`）

App 进程直连 Last.fm（走系统代理 `127.0.0.1:7897`，`scutil --proxy` 核实 HTTP/HTTPS/SOCKS 全开）：

| 接口 | 成功 n | p50 | p90 | p99 | 失败（全部=10 s 超时） |
|---|---|---|---|---|---|
| `track.getinfo` | 741 | 1182 ms | 6018 ms | 8934 ms | 150 |
| `artist.getcorrection` | 105 | 920 ms | 6551 ms | 7896 ms | 11 |
| `user.getrecenttracks` | 36 | 2813 ms | 6817 ms | 7753 ms | 11（+1 次 500） |
| 合计 | 881 | — | — | — | **172 / 1053 = 16.3%** |

- 慢请求与我们的发送速率**无关**：每分钟 1–5 个请求的桶 p50 也有 3.9 s；最忙的一分钟 131 个请求（00:10，别名发现在同步收尾后一口气扫 12 候选 × 汉字组）p50 反而 0.9 s。瓶颈在链路不在限速。
- 同一时段 collector（Go、launchd 起的、无 `HTTP_PROXY`，直连）：`user.getrecenttracks` 11796 次成功，p50 **407 ms**、p90 743 ms、p99 1.55 s；500/超时合计 ≈2%。
- 直接对比（`curl`，不带 key、只测链路，各 6 次）：直连 0.56–0.98 s 全成功；经代理 1.7–2.5 s 且 **2/6 在 5 s 处 SSL 握手失败**。**结论：App 那条链路慢且不稳是代理路由造成的，不是 Last.fm 慢。** 这是本机环境，但另一台机器/其它用户同样可能挂代理，设计必须默认"App 直连链路不可靠"。
- `refreshBaseline` 三请求 all-or-nothing（`:1897`）：按 16% 单次失败率，整轮成功概率 0.84³ ≈ **59%**，即四成的轮询刷新整轮作废、并弹一次「重试」行。
- collector `getWeeklyChartList` 30 h 内 332 次（2 h 检查间隔理论 ~15 次）：内存节流 `weeklyLastCheckedAt` 随每次 kickstart 重启归零（每次保存 features 都 kickstart）。同一模式在 App 侧是 `fetchedAt` 不落盘 → 每次启动榜单/那年今日/top-up 全部重拉。
- 磁盘现状：`stats-cache` 6 KB（第 1 页 20 行、11 条次数）；`recent-pages` 40 KB（10 页 200 行、154 条次数、175/200 行命中次数）；`title-forms` 230 KB（2600 族/2937 写法，`foldVersion` 7）；`daily-heatmap` 5 KB（327 天，2022-12 起）；`aliases-discovered` 44 KB（334 条 duration、1 条别名 `mojito→红模仿`）。总量 <400 KB，**落盘体积不是约束**。

---

## 2. 问题清单（按严重度）

| # | 严重度 | 现象 | 成因 | 锚点 |
|---|---|---|---|---|
| P1 | 高 | 换歌后徽章/实时行次数**先消失**、1–9 s 后再出现 | `refreshNowPlayingCount` 开头 `nowPlayingCount = nil`，不先用 `trackPlayCounts` 里同曲已有的总数 | `LastfmStatsService.swift:576` |
| P2 | 高 | 最近记录里已有数字的行退成 `···`，等 1–9 s（16% 概率更久） | 四条作废判据命中即 `trackPlayCounts[key] = nil`，界面失去旧值；判据④每 24 h 必命中一轮 | `:2224–2234`、`LastfmStatsSection.swift:495` |
| P3 | 高 | 设置页常开时三个数字下面**反复冒出「重试」行** | 三请求 all-or-nothing + 16% 超时；有存量也画失败态 | `:1897–1902`、`LastfmStatsSection.swift:213` |
| P4 | 高 | 「上一首」要 11–19 s 才进列表；手机上放的歌 45–110 s 才出现 | App 只能轮询；collector 15 s 就拿到了同一份数据却不给 App | `LastfmStatsSection.swift:1150–1173`、`poller.go:1017` |
| P5 | 中 | 每次启动那年今日「正在查」1–9 s；16% 概率变成"没能取到" | `onThisDay` 不进快照；失败还占 6 h TTL | `:727–822`、`:1652` |
| P6 | 中 | 每次启动/每次进页面榜单、top-up、别名发现全部重跑 | `fetchedAt` 只在内存；`titleFormsLastTopUp` 同 | `:470`、`:1185` |
| P7 | 中 | 跳到第 11+ 页转圈 1–9 s | 缓存区外无预读 | `:2699` |
| P8 | 中 | 今天/近 7 天各占一个请求，近 7 天那个已经没人用 | `weekValue` 只在 `dailySyncing` 时才读 API 值 | `:1891–1894`、`LastfmStatsSection.swift:224` |
| P9 | 中 | 别名发现一轮最多 ~130 个 `getinfo`，与前台抢同一条慢链路（虽有优先级，但并发 4 的 getinfo 会在链路上排队） | `discoveryBatchLimit=12` × 每候选逐个比对全部汉字组 | `:1435`、`:1552` |
| P10 | 低 | 页缓存与快照重复存第 1 页 + 两份 `playCounts`，两个 2 s 防抖写盘器 | 历史演进 | `:160`、`:1652` |
| P11 | 低 | 首次打开某个榜单组合 10 行骨架 1–15 s | 无预取（首次全量收尾那次预取只覆盖新账号） | `LastfmStatsSection.swift:287` |
| P12 | 低 | collector 每次 kickstart 重启后周报/日报/Top 歌手检查重跑 | 节流状态只在内存或只在成功后落盘 | `weekly.go:194` |

---

## 3. 目标与验收规则

把"不感知加载"拆成可验收的 6 条：

- **R1 存量先行**：任何一个 Last.fm 数据面，只要盘上有这个账号的数据，t=0 必须画出内容，不允许出现 spinner / 骨架 / 空白。骨架只在"这个账号从未取过这份数据"时出现。
- **R2 旧值不撤**：过期只是在背后重取；重取回来之前旧值继续显示，重取失败旧值继续显示。`nil` 只代表"从未有过"。
- **R3 失败静默**：有存量时，网络失败只改变"更新时间"的观感（变暗/加点），不弹失败态、不弹重试；无存量时才给失败态 + 重试。
- **R4 零闪烁**：列表替换只允许行级 diff（`id` 稳定，已满足）；封面/次数后到只填空位，不重排；数字只在真实变化时变。
- **R5 事件驱动优先于轮询**：本地能知道的变化（换歌、达标、回填完成、collector 新拉到数据）直接驱动刷新；轮询只作 collector 不在时的兜底。
- **R6 预算封顶**：App 侧 Last.fm 请求稀疏化到"只为用户看不到的空位取数"；任何单一后台任务一轮 ≤ 40 个请求；全局仍走 `LastfmRateLimiter`（4 req/s，前台优先）。

---

## 4. 分层模型

```
              ┌────────────────────────────────────────────────────────┐
  界面面      │ 设置页三段 · 待机页 · 歌词窗口(徽章/简介/常听/欢迎态) · Recent │  只读 @Published,不发请求
              └───────────────▲────────────────────────────────────────┘
                              │ 派生视图(RecentPlayOrdinal / IdleListeningStats / coverURL)
              ┌───────────────┴────────────────────────────────────────┐
  L0 内存     │ LastfmStatsService 状态 + stale 集合 + fetchedAt(持久化子集) │  t=0 的唯一数据源
              └───────────────▲────────────────────────────────────────┘
                     启动装载  │  防抖回写(2 s)
              ┌───────────────┴────────────────────────────────────────┐
  L1 磁盘     │ stats-cache(首屏) · recent-pages(前10页) · daily-heatmap ·   │  按 username 隔离
              │ title-forms · aliases-discovered · history-checkpoint      │  两道版本闸不变
              └───────────────▲────────────────────────────────────────┘
        ┌─────────────────────┼──────────────────────────┐
  L2 本地 feed│ lyrimuse-lastfm-recent-feed.json(collector 每 15 s 写,只在变化时) │  ★新增:热路径改走这里
        │  lyrimuse-lastfm-status.json · enrich-cache(封面②级)  │
        └─────────────────────▲──────────────────────────┘
                              │ collector(Go 直连,p50 0.4 s)
              ┌───────────────┴────────────────────────────────────────┐
  L3 网络     │ App 直连(仅冷路径:getinfo/榜单/那年今日/top-up,全部非阻塞) │  4 req/s,前台优先,超时分级
              └────────────────────────────────────────────────────────┘
```

三条原则：
1. **界面永远只读 L0**；L0 由 L1 装载、由 L2/L3 更新。任何"请求完成才画"的分支都是违规。
2. **热路径（最近记录 / now-playing / 总数 / 今天）走 L2**，App 不再为它们发请求；L3 只剩"按需补空位"的冷路径。
3. **过期 ≠ 删除**：L0 里每类数据配一个 `stale` 集合（或 `fetchedAt`），过期只影响"要不要在背后重取"，不影响显示。

---

## 5. 每个实体的策略

| 实体 | 存量（t=0 从哪来） | 增量（怎么更新） | 失效判据 | 预取 | 落盘与裁剪 | 版本闸 |
|---|---|---|---|---|---|---|
| 最近记录第 1 页 + now-playing + 总数 | 快照 `recent` / `recentTotalPages`；启动后立刻读 feed 文件覆盖（feed 比快照新） | **feed**：collector 每 15 s 写；App mtime 监听（复用 `LastfmMirrorStatusWatcher` 的 5 s 节奏或 `DispatchSource`）→ `ingestFeed`：`recentPage==1` 时 `applyRecent(feed 前 20 行)`；`apiNowPlaying`、`overview.total` 一并更新 | feed mtime > 90 s 未动（collector 不在/挂了）→ 退回 App 轮询 `refreshBaseline`（现有逻辑，TTL 拉长到 5 min） | — | 快照照旧；feed 文件由 collector 管（≤50 行 + 头部，~25 KB） | — |
| 今天 / 近 7 天 | 日桶 + 快照 `overview.today` | `today = dailyCounts[今天](截至 top-up) + feed 中 uts > dailySyncedThrough 的行数`（去重按 uts）；近 7 天已按日桶（`IdleListeningStats.lastSevenDays`） | 跨零点重算（纯本地）；15 min top-up 校正 | — | 随 daily-heatmap | — |
| 历史页 2–10 | `recentPageCache` | feed 新增 k 行 ⇒ 所有页边界整体下移 k：**不重拉**，只标记页缓存 stale；翻到时 SWR 静默 revalidate（现有 `revalidateRecentPage`） | 5 min TTL 不变 | 启动后台补齐缺页（现有） | 前 10 页（现有） | — |
| 历史页 11+ | 内存缓存（本次运行） | 翻到第 N 页落地后**预读 N+1**（`.background`，只拉原始行，不解析次数） | 5 min | 顺翻方向一页 | 不落盘 | — |
| `trackPlayCounts` | 快照 + 页缓存两份合并（现有） | 现有四条判据保留，但**命中改成 `stalePlayCountKeys.insert`，值不置 nil**；`resolvePlayCounts` 的 `needsCount = 值缺失 ‖ 在 stale 集合`；回填成功后从 stale 移除 | 同现有 | 预取页解析（现有） | 同现有（第 1 页 + 前 10 页范围） | `mergedCountsVersion` 不变（口径没改） |
| `nowPlayingCount` | 换歌瞬间：若 `trackPlayCounts[playCountKey]` 有值 → 立刻显示 **该值+1**（标 stale）；否则保持上一首的 nil→不显示 | 现有并发取数回来后覆盖；`reconcile` 只涨不跌保留 | 换歌 | — | 不落盘 | — |
| 那年今日 | **新增进快照**：`onThisDay` + `onThisDayDay` + `Outcome`；同一日历天有效 | 现有逻辑；跨天/6 h 才发；失败继续显示旧的（已是） | `DailyRefreshGate` | 启动即读盘 | 快照 | — |
| 榜单 12 组 | 快照（现有） | `fetchedAt` **持久化到快照**，TTL 内重启不重拉；TTL 从 15 min 改为**可见 15 min / 不可见 6 h**（切到榜单 tab 时才按 15 min 判） | TTL | 首次全量收尾（现有）+ **每日一次低优先级预取 12 组**（挂在 top-up 收尾，条件：距上次 >24 h） | 快照 | — |
| 歌曲榜封面 / 头像 | 快照 | 缺谁查谁（现有）；歌曲榜 10 个 `getinfo` 并发从"不限"改为走 4 并发（复用 `resolvePlayCounts` 的组） | — | 随榜单预取 | 快照 | — |
| 日桶 / 写法索引 / 断点 | 现有 | 现有（真增量） | 15 min 节流改为**持久化 `titleFormsLastTopUp`**（重启不重跑） | — | 现有 | `foldVersion` 不变 |
| 别名发现 | 现有 | 一轮上限从 12 候选改为 **≤40 个请求**（按请求数封顶，而不是候选数），且仅在"过去 60 s 没有前台请求"时启动；剩余候选留到下轮（30 天冷却不变） | — | — | 现有 | — |
| 封面 ③④⑤ | 快照 | 现有 | 现有 | — | 现有 | — |
| `nowPlayingSpan` | 无（打开简介才有意义） | 现有 2 请求；结果**按曲目缓存在内存**（同一首歌第二次打开简介不再发） | 换歌不清、按 key 查 | — | 不落盘 | — |

---

## 6. 交互 → 请求矩阵（目标态）

| 交互 / 事件 | t=0 显示 | 背后发什么 | 用户感知 | 与现状差别 |
|---|---|---|---|---|
| 冷启动 → 打开 Last.fm 页 | 数字、第 1 页、榜单、**那年今日**、次数全部来自快照/页缓存/feed | feed 已在则 0；那年今日跨天 1–9；榜单 TTL（持久化）内 0；top-up 15 min 内 0 | 无 | 那年今日不再"正在查"；不再重拉榜单/top-up |
| 切 tab | 即显 | 0 | 无 | 同 |
| 切榜单种类/周期 | 即显（12 组每日预取过） | TTL 过期时 1（SWR） | 无 | 首次骨架基本消失 |
| 翻页 ≤10 | 即显 | 0 / 静默 revalidate | 无 | 同 |
| 翻页 11+（顺翻） | 即显（上一页落地时已预读） | 预读下一页 1 + 次数按需 | 无 | 原转圈 1–9 s |
| 跳页 | 骨架 20 行（固定高度） | 1 + 次数 | **有**（不可避免） | 骨架代替转圈，高度稳定 |
| 换歌 | 徽章立刻显示"旧总数+1"（有历史时） | 1+孪生 校正 | 无（只见数字可能+0/±1 修正） | 原先消失 1–9 s |
| 达标 scrobble | — | collector 镜像成功 → 5 s 后提前拉一次 feed | 上一首 ≤10 s 进列表，0 App 请求 | 原 11–19 s + 3 请求 |
| 手机在放 | feed 15 s 一拍带 now-playing | 0 App 请求 | ≤15 s 出现红点 | 原 45–110 s |
| 切回 App | 即显（feed 一直在更新） | 0 | 无 | 同，但不再发 3 请求 |
| 设置页常开 | — | 0（feed）；top-up 每 15 min 1–3 页；那年今日跨天 | 无「重试」行 | 原每 110 s 3 请求 + 噪音 |
| 断网 | 全部旧值 + 卡头「N 分钟前更新」变暗 | 退避 | 无失败态 | 原「重试」行 |
| 连接 / 换账号 | 进度条（现有） | 首次全量（现有） | 有进度 | 同 |
| 回填完成 | — | 日桶回拨 + 下次 top-up | 无 | 同 |
| 打开简介 | 累计次数即显；首次/上次 1–9 s 后出现（同曲第二次即显） | 2（首次） | 轻 | 加内存缓存 |

---

## 7. 请求预算（估算）

假设：设置页常开、本机每小时听 15 首、无手机会话。`user.getrecenttracks` 在 collector 侧 15 s 一次 = 240/h，两案相同。

| 项 | 现状 App/h | 目标 App/h | 说明 |
|---|---|---|---|
| baseline 轮询（3 × 3600/110） | ≈ 98 | **0**（feed）/ 兜底 12（5 min TTL） | 今天/近 7 天派生自日桶 |
| 换歌强刷（3 × 15） | 45 | 0 | collector 触发 feed 提前刷新 |
| 换歌取次数（15 × ~1.2） | 18 | 18 | 不变 |
| 新行次数/封面（≈15 行 + 纠正） | ≈ 20 | ≈ 20 | 不变 |
| 判据④到期重查 | ≈ 5 | ≈ 5 | 不变（改成不撤旧值，不影响请求数） |
| top-up（15 min × 1–3 页） | ≈ 6 | ≈ 6 | 持久化节流后启动不重跑 |
| 那年今日 | 启动 1–9 | 跨天 1–9 | 启动不重拉 |
| 榜单 | 进页面 1–11 | 每日预取 ≈ 12 + 22 封面 / 24 | 摊到每小时 ≈ 1.5 |
| 别名发现 | 突发 ≤130 | ≤40 一轮 | 封顶请求数 |
| **合计（稳态）** | **≈ 190 + 突发** | **≈ 50** | collector 240/h 不变 |

峰值核算：
- 冷启动：0 阻塞请求；后台最多 那年今日 3 + top-up 3 + 缺失次数 ≤20 ≈ 26 个，4 req/s 下 7 s 内发完，全部 SWR。
- 首次连接全量：~110 页 + 收尾 3 + 12 榜单 + 10 页预取 + ≤200 行次数（大部分需孪生）≈ 400–600 请求，4 req/s ≈ 2–3 min，有进度条（现有，不改）。
- 翻页连点 10 次（11→20 页）：预读一页一请求，20 行次数 ≤ 20×(1+孪生)，仍受 4 req/s 与并发 4 约束（现有）。
- 别名发现：一轮 ≤40，且前台安静 60 s 才启动。

超时分级：交互 10 s（不变，因为界面不等它）；`.background` 20 s（把 p90 6 s、p99 9 s 的长尾从"失败重试"变成"慢成功"，减少白发的重试）。

---

## 8. 四条时间线

**A. 冷启动 → 打开 Last.fm 页**
- 0 ms：`loadSnapshot`（6 KB）+ `loadRecentPageCache`（40 KB）同步装载，主线程 <5 ms（现有）。
- 0–30 ms：`onAppear` → 读 feed 文件（≤25 KB JSON，主线程外解码）→ `applyRecent`（如果 feed 比快照新）。**用户看到完整页面。**
- 后台：那年今日（跨天时）1–9 s 后悄悄换；缺失次数按 4 并发填空位；封面按需。

**B. 换歌 → 实时行 / 徽章**
- 0 ms：`refreshNowPlayingCount` 取 `trackPlayCounts[key]`（有则显示 +1 并标 stale）。
- p50 1.2 s / p90 6 s：真值回来覆盖（数字通常不变或 +1）。
- 达标（曲长/2 或 4 min）：collector 镜像 → 5 s 后拉 feed → 写文件 → App ≤5 s 读到 → 上一首出现在列表顶，实时行吸收逻辑不变。合计 ≈ 10 s，0 App 请求（现状 11–19 s + 3 请求）。

**C. 翻页**
- 1–10 页：0 ms（现有）。
- 顺翻 11+：0 ms（预读已落地）；落地同时后台预读下一页（1 请求）+ 该页缺失次数。
- 跳页：骨架 20 行 → p50 2.8 s / p90 6.8 s（`getrecenttracks` 在慢链路上的实测）→ 内容。这是唯一保留的可见等待。

**D. 切回 App / 手机会话**
- feed 每 15 s 一拍：切回时内容已是 ≤15 s 新；手机换歌 ≤15 s 出现红点。0 App 请求。

---

## 9. 实施计划

每阶段可独立上线、可独立回退；阶段内按序号做。

### 阶段 1 · 止血（纯 App 侧，不碰 collector，1 天）
1. **旧值不撤**：`LastfmStatsService` 新增 `private var stalePlayCountKeys: Set<String>`；`applyRecent` 里 `trackPlayCounts[key] = nil` 及孪生那两处（`:2225`、`:2231`）改为 insert stale；`resolvePlayCounts` 的 `needsCount`（`:2446`）加 `|| stalePlayCountKeys.contains(key)`，成功合并时移除；`adoptFreshTotal` 同步移除；`resetAll` 清空。⚠️ `contradictedPlayCountKeys` / `staleByAgePlayCountKeys` 读的仍是 `trackPlayCounts` 的值，语义不变；`RecentPlayOrdinal.ordinals` 拿到的仍是旧总数（比 `···` 强）。
2. **换歌徽章不消失**：`refreshNowPlayingCount`（`:571`）在 `nowPlayingCount = nil` 之前，若 `trackPlayCounts[nowPlayingCountPlayCountKey]` 有值则 `nowPlayingCount = 值 + 1` 并 `stale`；`reconcileNowPlayingCount` 不变。
3. **三请求拆开**：`refreshBaseline`（`:1881–1916`）三个 `async let` 各自 `if let` 落地；`overview` 逐字段合并（字段已是 `var`，失败的那个字段保留旧值，`overview == nil` 时才需要三个都到齐才建）；只有三个都失败才 `baselineFailed = true`；`recent` 成功即 `applyRecent`。
4. **失败静默**：`LastfmStatsSection.statsCard`（`:213`）与 `recentCard`（`:453`）：`baselineFailed && overview == nil` 才画 `retryRow`；有存量时卡头「N 分钟前更新」文字加 `.foregroundStyle(.quaternary)` + 一个 `exclamationmark.circle` 小图标（help 文案"上次刷新失败，显示的是缓存"）。`RecentListensPanel` 同样处理（`:189–197`）。
5. **那年今日进快照**：`StatsSnapshot` 加 `onThisDay: OnThisDayResult?`（`RecentTrack` 已 Codable，`TopTrack` 补 Codable）+ `onThisDayDay: Date?`；`loadSnapshot` 装载并置 `onThisDayOutcome = .loaded`；`scheduleSnapshotSave` 带上；`refreshOnThisDay` 首行 `DailyRefreshGate` 用装载来的 `onThisDayDay` 判跨天（`fetchedAt["onthisday"]` 仍不落盘 → 启动后同一天不会再发）。
6. **`fetchedAt` 子集持久化**：快照加 `fetchedAt: [String: Date]`，只存榜单 12 键 + `"baseline"` + `"onthisday"`；`loadSnapshot` 恢复（`fresh()` 的未来时间戳守卫已有，`:3020`）。同时把 `titleFormsLastTopUp` 写进 `TitleFormsSnapshot`。
7. **超时分级**：`request(...)` 按 `priority` 选 `timeoutInterval`（interactive 10 s / background 20 s）。
8. **翻页预读**：`goToPage` 成功落地（`:2714`）与 `revalidateRecentPage` 落地后，若 `target+1 ≤ recentTotalPages` 且未缓存 → `prefetchPage(target+1)`（复用 `prefetchRecentPagesIfNeeded` 里"只拉原始行 + `fetchedAt` 盖戳"那段，抽成 `fetchRawPage(_:priority:)`）；跳页未命中时列表画 20 行 `.redacted` 骨架代替转圈。
9. **别名发现封顶**：`discoverTitleAliasesIfNeeded` 按"本轮已发请求数 ≥40 即 break"，并加"最近 60 s 内 `LastfmRateLimiter` 前台队列有过放行则本轮跳过"（限速器暴露一个 `lastInteractiveAt`）。

回退：每一条都是局部改动，逐条 revert 即可；第 5/6 条改了快照结构，老字段全部可选，老快照照常解出。

### 阶段 2 · feed（collector + App，2–3 天）
1. **collector**：`applyBridgeResult`（`poller.go:1050`）成功分支后新增 `writeRecentFeed(np, done, total, fetchedAt)` → `~/.config/lyrimuse/lyrimuse-lastfm-recent-feed.json`，**内容哈希不变不写**（照 `collectorstatus.go` 的"记住上次写的"做法）；`lastfmRecent` 顺手解析 `@attr.total`。原子写（tmp+rename）。
2. **collector 拉取门槛**：`bridge()` 的守卫（`poller.go:1030`）拆成"桥接（需 LB）"与"feed（只需 Last.fm 凭据）"两层：Last.fm-only 用户也拉，但节奏放到 **60 s**；存在 `lyrimuse-lastfm-feed-lease.json`（App 在任一 Last.fm 面可见时每 60 s 续一次、含过期时刻）时提速到 15 s。LB 桥接照旧 15 s。
3. **collector 事件提前刷**：`mirrorAsync` 成功回调里置一个"5 s 后允许提前拉一次"的标记（只碰 `lastfmCheckedAt`，在主循环里改，遵守"状态只在 poll 主循环里变"）。
4. **App**：新增 `LastfmRecentFeedWatcher`（形制照 `LastfmMirrorStatusWatcher`，5 s mtime 轮询即可；文件 <30 KB）；变化时在 `LastfmStatsService.ingestFeed(_:)`：`recentPage == 1` 时 `applyRecent(前 20 行 + nowPlaying 行)`、`overview.total`、`recentUpdatedAt`、`fetchedAt["baseline"] = feed.fetchedAt`（让现有 TTL 闸自然早退）；页缓存 2–10 标 stale。
5. **App 派生今天**：`overview.today = dailyCounts[今天 key] + feed 中 uts > dailySyncedThrough 且属于今天 的行数`；`refreshBaseline` 删掉 `todayJSON`/`weekJSON` 两个请求（feed 不在时保留一个 `limit=1&from=今日0点` 兜底）。
6. **App 轮询降级**：`LastfmStatsSection.task`（`:125`）与两处 180 s 轮询：先看 feed mtime，<90 s 则跳过 `refreshBaseline`；`LiveScrobbleRow` 的 10 s 换歌强刷与 45 s 远端强刷在 feed 健康时不发。

回退：删 feed 文件监听即回到阶段 1 行为；collector 多写一个文件无副作用。

### 阶段 3 · 整理（可选，1 天）
1. 榜单每日预取 12 组 + `ChartsPanelView`/设置页首次骨架收敛。
2. `nowPlayingSpan` 内存按曲缓存。
3. 页缓存与快照合并成一个 `RecentStore`（第 1 页不再存两份、`playCounts` 只存一份）——收益是维护性不是性能，放最后。
4. collector 周报/日报/Top 歌手节流状态落盘（P12）。

### 不做（评估后否决）
- **App 绕过系统代理直连**：能把 p50 从 1.2 s 拉到 0.5 s，但在需要代理才能出网的网络环境会把 Last.fm 整体打断，且用户不可见地改网络路径不妥。如果要做，只做成设置里的显式开关（默认关），见第 11 节。
- **`from=` 水位增量替代整页重拉**：请求数不变（省的是响应体积），而 feed 方案把请求本身省掉了；且 `from` 增量拿不到 `totalPages`，翻页控件要另发请求。

---

## 10. 风险与不变量对照

| 既有不变量（12 章 ⚠️） | 本方案是否触碰 | 怎么守住 |
|---|---|---|
| `LastfmStatsSection` 不可随 tab 卸载 | 不碰 | 所有新逻辑仍挂在这个 View 的 `onAppear/.task` 或 service 内 |
| `foldVersion` / `mergedCountsVersion` 锁步 | 不碰 | 本方案不改折叠口径；stale 集合是显示层状态，不进两张表 |
| `playCountFetchedAt` 不落盘 / `playCountVerifiedAt` 落盘 | 不碰 | 两个字段原样；`fetchedAt` 持久化只白名单榜单/baseline/onthisday 三类键，**不含**任何 playCount 键 |
| `lfmMirrored` 先写后发 | 不碰 | feed 只是读侧产物；提前刷只改 `lastfmCheckedAt`，在主循环里 |
| poller "所有状态变更只在 poll 主循环" | 遵守 | `writeRecentFeed` 在 `applyBridgeResult`（主循环）里调；镜像成功回调只置原子标记 |
| 页缓存不落 now-playing 行 | 不碰 | feed 的 now-playing 行只进内存 `recent`，`scheduleRecentPageCacheSave` 的 `filter { date != nil }` 原样 |
| `fresh()` 未来时间戳判过期 | 依赖 | 持久化的 `fetchedAt` 正好靠它防时钟回拨 |
| 那年今日失败占 6 h TTL / 重取不清 `onThisDay` | 不碰 | 快照只是多一个装载来源 |
| `refreshBaseline` 无条件调（不按页早退） | 保留 | feed 健康时的"跳过"判的是 feed mtime，不是页码 |
| `recentPage` 是共享状态、`RecentListensPanel` 退场拨回第 1 页 | 不碰 | `ingestFeed` 只在 `recentPage == 1` 时替换 `recent` |
| 换账号隔离（username 校验） | 遵守 | feed 文件头部带 `username`；`ingestFeed` 校验不符即忽略；`resetAll` 删 feed + lease |
| 广告 now-playing 行不展示 | 遵守 | feed 行走同一个 `applyRecent`，过滤在里面 |

新增风险：
- **feed 与 App 轮询双写 `recent`**：靠 `baselineGen` 代际计数 + `fetchedAt["baseline"]` 被 feed 盖戳，两条路不会互相回退（feed 落地后轮询早退）。
- **collector 不在**（用户关了后台服务）：feed mtime 陈旧 → 自动退回阶段 1 的轮询；卡头显示"N 分钟前更新"如实。
- **今天派生口径漂移**：`dailyCounts[今天]` 截至 `dailySyncedThrough`，feed 增量只数 uts 在其后的行；15 min top-up 会整天重算校正。极端情况（15 min 内 >50 次 scrobble）少算，top-up 后归正。
- **阶段 1 第 1 条**：`stalePlayCountKeys` 若忘了在 `resolvePlayCounts` 成功路径移除，会每轮重查——在 `resolvePlayCounts` 的 `countFetched` 处统一移除并加 selftest。

---

## 11. 拍板结果（2026-09-03）

1. feed 拉取只看 Last.fm 凭据，节奏自适应（有人在听 15 s / 空闲 60 s），对配没配 LB 一视同仁。
2. **不做**代理绕过开关：feed 把热路径搬离了慢链路，剩下的冷路径全部非阻塞；换网络环境结论可能反过来。
3. `onThisDay` 进快照。⚠️ 草案里"回填可能影响那年今日"这一条是**错的**：回填窗口只有 13 天，碰不到 1–3 年前的今天，不需要联动强刷。
4. 页缓存与快照合并**不做**（纯维护性）；`nowPlayingSpan` 按曲缓存也**不做**（"上次听"会随本次播放变化，缓存即陈值，而它只在简介面板打开时发 2 个请求）。
