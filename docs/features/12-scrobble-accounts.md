# 12. 账号连接与收听记录

> 最后核对：2026-09-05 · 基线：601fb88+工作树

## 定位

把「听过什么」如实记账并分发出去：本地收听日志（只记还没进 Last.fm 的那些）、ListenBrainz 提交、Last.fm 镜像、iPhone 桥接、历史回填，以及设置里的「账号连接」页与 Last.fm 统计区。

## 入口与展示面

- 设置 → 账号：四个目的地卡片——**ListenBrainz**、**Last.fm**、**网页推送**（stateRelay）、**推送提醒**（Bark），各自的连接状态/配置入口（`AccountLinkingTab`，侧边栏行有状态点）。
- Last.fm 详情页（2026-08-23 改成分段 tab，理由跟「歌词显示」页一致——原来是连接卡+四张统计卡顺序平铺的一条长滚动，一次只关心其中一件事也要先滚过其它几件）：连接状态（Scrobble 开关、连接/断开、回填入口）**常驻在 tab 选择器外面**，不随下面的段切换；已连接时再展开「统计」（今天/近7天/总量数字 + 最近记录列表，合成一段）/「榜单」/「足迹」（2026-09-03 由「那年今日」改名：上面是零请求的「收听足迹」卡、下面是「那年今日」卡）/**「设置」**四个并列 tab（`AccountLinkingTab.LastfmSection` 选择器 + `LastfmStatsSection`，正在记录的实时行、最近播放列表带封面都在「统计」段里）；未连接时全部收起、只留一句预告文案。
  - **「设置」段 2026-09-01 加**（用户原话「这里单开一个设置tab页，装在这里面」）。装的是「跟 Last.fm 上送行为有关、但不是开关本身」的配置，卡头就叫 **`Scrobble`（中英同字）**。目前只有一项：「合唱歌曲的歌手」（见 §4）。
    - **为什么不继续摆在常驻的连接卡里**：那张卡的定位是「不看哪个 tab 都该一直看得见的东西」（Scrobble 开关、连接状态、待补清单），往里加设置项会把它撑成一张什么都装的卡；而这些设置恰恰是「想调的时候才去找」的类型。（当天先补在连接卡里、Scrobble 开关正下方，同日改成单开一段。）
    - **卡头中英同字 `Scrobble`** 的三条依据：①本仓的中文界面**本来就不翻译这个词**（「Scrobble 到 Last.fm」「Scrobble 已暂停」「总 scrobble」都是原样用）；②卡头在这个仓的惯例是名词短语而不是「X设置」（歌词来源／已信任的其它播放器／配置备份与搬家）；③这张卡已经在「设置」段里，标题再写一遍「设置」是重复。
    - ⚠️ **`LastfmStatsSection` 在「设置」段仍然常驻挂载**，只是它的 `Tab.settings` 分支画 `EmptyView()`；设置卡由 `AccountLinkingTab` 自己画。**别改成"这一段不挂载它"** —— 它的整套刷新逻辑建立在「从不因为切 tab 被卸载重建」上（见该类型头注），卸载一次就会把已拉到的统计丢掉、回来重拉一轮。职责上也对：那个 View 管统计数据，这些设置读 `FeatureSettingsStore`。
    - Scrobble 开关**关着**时这一项无从谈起（没有上送），那种情况显示一句说明而不是一个点了不影响任何事的控件。

## 行为规格

### 1. 一次「算数的收听」（collector poller）

- 阈值 `listenThreshold = min(曲长/2, 240s)`：过半或满 4 分钟即计一次（`listenCapSecs = 240`）。
- **短曲目**：曲长 `0 < d < 30s`（`minTrackSecs`）默认不记——Last.fm 官方规则 *"The track must be longer than 30 seconds"*，是给客户端的规则（服务端不拒收、ignoredMessage 也没有「太短」这一码），主流 scrobbler 都在客户端照做。2026-09-03 起可由 `scrobble_short_tracks`（features.json，默认 false；设置入口 账号→Last.fm→设置→Scrobble 卡「短于 30 秒的曲目」）放开。四处闸共用 `tooShortToScrobble`（poller.go：到点提交 / 切歌收尾 / 退出兜底；backfill.go：回填复核）。**只管 Last.fm**：短曲目进了漏斗之后，`shortTrackLastfmOnly` 在 `submitSingleAsync` 和退出兜底两处把 ListenBrainz 那一路挡掉（不发 LB、直接以 `lastfmOnly` 结果走 `applySubmitOutcome` 收尾），本地收听日志/回填照记——它们本来就是给 Last.fm 兜底的。用户原话（2026-09-03）：「这个配置项是 lastfm 的，和 listenbrainz 没有一点关系」；第一版曾把它做成漏斗级（LB 一起记），当天按这句改成 Last.fm-only。曲长未知（≤0）照旧不拦；放行后半程规则照旧（20 秒的歌要听满 10 秒）；恰好 30.000s 按既有口径放行（官方是 `> 30`，差这一秒是历史行为）。回填按**当前**开关复核：开关开着时写下的短曲目记录，关掉后再回填会被筛掉。测试 `TestTooShortToScrobble` / `TestScrobbleShortTracksFlagRoundTrip` / `TestPendingBackfillListensHonorsShortTrackFlag` / `TestSubmitSingleShortTrackSkipsListenBrainz`（假 LB 服务器收到 0 个请求、普通曲目仍收 1 个）/ `TestShortTrackLastfmOnly`。
- **scrobble 时间戳 = 开播时刻**（不是达标时刻）。
- 单曲循环重启按新一次播放重新计（`loopRestart` 重锚，进度连续性判定）。
- 提交在后台 goroutine 跑（LB 慢时 single 最长 ~24s），`submitting/announcing` 标记防 5s 轮询重复触发。
- playing_now：换曲那条必须带歌词（LB 只认换曲那条），歌词还在解析时挂起 `pnPending` 最多 8s。
- 歌词随 listen 提交受 LB「单条 ≤10240 字节」硬上限约束，按 原文>翻译>罗马音>逐字 优先级装入。

### 2. 本地收听日志（listenlog.go）

⚠️ **写入条件是两条，满足其一才写**（标题曾经写「不依赖账号」，那是 2026-08-13 收窄**之前**的行为，已改）：①没连 Last.fm（`p.lfm == nil`）；②连了 Last.fm 但这一条**确定没写进去**（镜像失败，`recordFailedMirror`，2026-08-30 加，见第 4 节）。**一个一直连着账号、网络也一直正常的用户，这份日志会是空的——那是对的。**

每次符合上述条件的收听追加一行到 `lyrimuse-listens.jsonl`——2026-08-13 补上：此前收听只流向「三个都要账号」的目的地，先用一周后连账号的用户那一周从没落过盘。收窄的理由是「一直连着账号的用户写进去的每一行都是注定不会被用到的死数据，却要一直占盘、一直参与折叠计算」。这份日志是「本地已记录 N 首，连接后可补提交」清单的数据源。`collector delete-listen -uts <秒>` 删指定条目（必须由 collector 做——它在持续追加、格式语义都在它这边）。

### 3. ListenBrainz 提交（lb.go）

`lbClient.submit`（playing_now / single），additional_info 带 media_player（如实按播放器报）、source=mac（桥接 iPhone 覆盖为 iphone）、duration_ms、进度锚（自跟踪 Position+AnchorTS，不用 media-control 的 timestamp——连播时冻结、跨休眠会漂）。token 在设置里配置并校验（`ListenBrainzTokenCheck`）。未配 token 时 collector 纯本地运行（歌词/封面照常）。

- **429 的跨调用退避（2026-08-25 实测坐实）**：`submit` 内部原有的 tries/退避只管一次调用内的几次重试，治不了"LB 持续 429 几个小时"这种情况——`poller.go` 有四个调用点（Mac 原生 single/playing_now、桥接 iPhone single/playing_now）各自独立按自己的节奏（桥接 15s 一轮；Mac 侧每次 poll tick ~5s，只要歌还在放就重试）发起新一轮 submit，互相不知道对方也在被拒，合起来对一个持续故障的服务器反而在加压。实测坐实：当晚 23:06 起持续超过 10 小时、每 15-20s 一次真实 429，且**这不只是"晚一点收到"**——Mac 原生 single 只在歌**还在播**时才会每个 poll tick 重试，一旦换歌/曲终只再补发**一次**，那一次也失败就永久丢失（Last.fm 镜像走独立路径不受影响，`appendListen` 本地兜底又因为已连 Last.fm 而不记）。修法：`lbClient` 加一个所有调用点共用的冷却期（`lbCooldownSchedule`：30s→1m→2m→4m→8m 指数升级，成功一次清零），冷却期内直接跳过网络请求而不是排队——这不是"发太快"的问题（单条链路请求率本身很低），是"服务持续不可用，该少烦它"。跳过时返回的错误刻意不包 `errListenRejected`：那个是"LB 确认不收，别再试"的永久语义（桥接那处会把它计入去重集合永久跳过），冷却中的跳过必须走"瞬时失败，下一轮再试"的分支，否则会被误判成永久拒绝而漏计。**已经丢失的窗口只能靠历史回填（见下节）从 Last.fm 补回 LB**，这道退避防的是"继续丢"，不能找回已经丢的。

### 4. Last.fm 镜像（lastfm.go + 开关 lastfmMirrorScrobble）

- ⚠️ **上送口径：歌手 / 歌名 / 专辑一律原样发播放器报的标签，不做任何替换**（2026-08-31 定，`lbMeta`）。
  唯一的例外是 **`cleanMediaTag`**：把不可见字符规范化（NBSP/全角空格→普通空格、删零宽、连续空白折一个），**不动任何可见内容**——大小写、繁简、括号副题、合唱串一个字都不改。**洗 ≠ 改写**，业界（Web Scrobbler 的 `removeZeroWidth`/trim 等）也普遍这么做；不洗的话 NBSP 会在 Last.fm 建出一个跟正常写法肉眼完全一样、实际是另一个实体的条目。2026-08-31 起 **Apple Music 那条路径（`getAppleMusicState`，JXA 直接 unmarshal）也补上了**——它此前绕过这道清洗，而 `enrichKey` 那边又洗过，两边口径不一致。

  此前 `lbMeta` 会用 `canonical_artist`（网易云/QQ/MusicBrainz 查到的「官方写法」）**替换掉**播放器标签。撤销依据三条：

  1. **Last.fm 官方明确反对**。scrobbling 指南里这句出现了**两次**（逐字）：*"Do not use the corrections returned by the now playing service as input for the scrobble request, unless they have been explicitly approved by the user."* —— 连 Last.fm **自己**权威纠正库返回的结果都不许自动套用，而我们套的是网易云/QQ。它自家的 autocorrect 也已标为 legacy，官方推荐「不要应用纠正」。
  2. **业界惯例一致**。调研 9 个开源 scrobbler（Web Scrobbler / Pano / Navidrome / Maloja / rescrobbled / mpdscribble / mpdas / Koito / multi-scrobbler），默认做「外部查询改名」的是 **0 个**；唯一有此能力的 multi-scrobbler 是 opt-in、要填联系邮箱、文档警告 free text search 是 "unconstrained"。Pano 反而拿 MusicBrainz 名单当 **allowlist 保护**合唱串不被切——同一份数据，方向相反。
  3. **实测有真错**。本机 2514 条缓存审计：194 条被改写，其中 `USA for Africa`→`Xtc Planet`（那是《We Are the World》群星企划）、`LBI利比`→`Safehse` 明确错误。写进 Last.fm 公共 artist 页的东西基本收不回来（纠错库已冻结）。

  **归一没有放弃，只是挪了位置**：显示/统计层照旧合并（App 侧 `PlayCountFold.canonicalArtist` / `artistMergeNameKey`，独立实现），上送层只负责如实记录「播放器当时报的是什么」。`canonical_artist` 字段本身保留——它还给「歌词管理」窗口当展示名（`EnrichCacheStore.swift`）。

  - **回填侧必须同步**（`backfill.go`）：那里 2026-08-27 曾补过同一层替换以「跟活路径口径一致」，2026-08-31 一并撤销 —— 否则会反过来出现「当场发原串、回填发改写名」的新分裂。
  - **`artist_mbids` 是这条路的正解，但暂未接**：ListenBrainz 支持 `additional_info.artist_mbids`（数组，合唱串可发多个 ID），能做到「标注身份而不改显示串」。没做是因为现有身份缓存对**原始串**的 mbid 覆盖率只有 **16%**（那份缓存的键是归一后的名字，为榜单而建）。⚠️ **Last.fm 侧不存在这条路**：它的 `mbid` 参数官方描述是 *"The MusicBrainz **Track** ID"*，根本没有艺人 mbid 字段——所以对 Last.fm 而言「原样上送」就是唯一正解。
  - **`canonical_artist` 解析链同期收窄**（`enrich.go`）：删掉「网易云本次搜索这首歌带回的歌手名」（`ne.Artist`）和 QQ 同款两级——它们是**按曲目匹配**的（搜错歌就把错歌手写进缓存）且**无置信度门槛**，上面那两条错误值正出自这里。保留的两级都**按歌手本身查**：MusicBrainz（`musicbrainzMinScore`=90 把关）与 `resolveGenericArtistCanonicalName`。代价知情：一部分歌手不再有 canonical_artist，展示时退回播放器原始标签——这是想要的方向。

- 收听达标后异步镜像成 Last.fm scrobble（`mirrorScrobbleTracked`）；uts 先记入 `lfmMirrored` 集合**再**发请求，防 bridge 抢在标记前把它当 iPhone 记录转发回来。
- **镜像失败必须留痕（`recordFailedMirror`，2026-08-30 加）**：上面那个"先标记再发请求"的顺序有个直接后果——请求失败时标记已经落盘，幂等守卫从此永久挡死这条；而 `mirrorAsync` 原来失败只打一行日志（注释写的"下一次自然会覆盖"对 now-playing 成立、对 **scrobble 不成立**：一次收听只提交这一次），`p.lfm != nil` 时 `appendListen` 又被跳过。**三处同时不兜底 ⇒ 一次网络抖动 = 永久少一条 scrobble，且无处可查**（用户真实日志实测：2618 次成功收听对应 13 条这样的丢失）。修法按失败类型分流，合并成一种就必然错一边：
  - **可证明没发出去**（`provablyNeverSent`：DNS 失败 / dial 阶段失败——TCP 都没建起来，服务端不可能见过）→ 只写 `"l"`，回填会正常挑走，零重复风险。
  - **不确定发没发到**（超时 / read 阶段中断——请求可能已落库只是回执丢了）→ 写 `"l"` + `"q"` 一对：`q` 让回填**绝不自动重试**（沿用 `markQuarantined` 的既有语义：重复比漏补贵得多），`l` 保住艺人/曲名供将来人工对账，此前这种情况连是哪首歌都查不出来。
  - **服务端看过并拒收**（`accepted=0` / 应用层 error）→ 什么都不写，重发多少次还是被拒。
  - ⚠️ **刻意不做"撤销 `lfmMirrored` 标记让它重发"**（评估后否决）：那要从 `mirrorAsync` 的 goroutine 里写 `p.lfmMirrored`，而主循环会经 `persistedTTLSet.save` 整个 `range` 它——并发写就是 `fatal error: concurrent map iteration and map write`，`recover` 都救不回来，且违反 poller.go 顶部"所有状态变更只发生在 poll 主循环里"那条不变量。收益也几乎没有：实测 10 次 DNS 故障里只有 1 次在同一首歌还没放完时等到网络恢复，其余 9 次 session 早被 `finalize` 丢弃。**标记保持置位 ⇒ 活路径永不再发这条 ⇒ 唯一提交者是回填 ⇒ 物理上不可能双发。**
  - `onFail` 回调只准碰自带锁的 listen log（`appendListen`/`markQuarantined` 持 `listenLogMu`），绝不碰任何 poller 字段。`mirrorfailure_test.go` 钉住三类分流，并做过变异验证（把"不确定"误判成"确定没发出去"时测试必挂）。
  - 写进日志的必须是**播放器报的原始艺人名**（不是 collapse 折叠后的值）——回填会拿它重跑同样的归一化，喂折叠后的值进去等于折叠两次（见 `listenLogLine.AR`）。
- **`accepted=0` 现在会报出真实原因**（2026-08-30）：回执里 `<scrobble>` 带着 `ignoredMessage`（code + 人话），回填路径一直在解析它，活路径原来整个丢掉、只报一句笼统的 `accepted=0`。实测那 5 条真实失败里 3 条是空艺人名（彼时守卫还没加，`isAdBreak` 08-14 / `trustedPlaybackNotASong` 08-22 补上后已归零）、2 条是艺人名 `群星`（Various Artists，Last.fm 当非艺人拒收，16 次出现 0 次成功）——两种成因处置完全不同却报同一句话。现在复用 `parseScrobbleEntries` 解析，并新增 `lastfmIgnoredError` 类型供上面的分流判据使用。旧注释里"时间戳超两周"那条成因对活路径不成立（当场提交不可能超窗），是从回填场景抄来的猜测，已删。
- **熔断语义（`shouldDisable`）**：error 9/10/26（token 失效/API key 问题）一击致命——写 mirror 状态文件、UI 红感叹号；error 4（Authentication Failed）会被服务端不稳**误报**，改为**两击坐实**：首击只记嫌疑（30s 内的连击不算第二击，30 分钟窗口内再击才熔断），任何一次成功清零嫌疑。
- 状态文件由 App 侧 `LastfmMirrorStatusWatcher`（5s timer，值变才发布）盯着：熔断→红标即时出现；用户重连成功→红标自愈消失。
- 授权走 `LastfmAuthFlow`（浏览器 OAuth 拿 session key）。
- **上送字段：活路径与回填必须一致（2026-08-30 修）**。此前 `scrobble`/`updateNowPlaying`（活路径）**不发** `duration`，而 `backfill.go` 一直在发 —— 同一首歌当场提交反而比事后回填少一个字段，编目匹配的输入不如回填全，没有任何理由分叉。现在三处共用 `durationParam`（lastfm.go）：**只发正数、整数秒、拿不到就整个键不发**（发 0 等于向 Last.fm 断言「这首歌长度为零」，比不发更糟）。官方文档核实过：`duration` 在 `track.scrobble` 与 `track.updateNowPlaying` 上都是选填、单位秒。
  - ⚠️ 仓库里「duration 能显著提升编目匹配」这句是**内部断言**，官方文档并没有这个说法——但也没有任何反对理由，且 `updateNowPlaying` 带上它确实有明确用途（让 Last.fm 知道这条「正在播放」该挂多久，不给就只能猜一个默认时长）。
  - 数据是现成的：`mirrorScrobbleTracked` 早就带着 `durationSecs`（第 4 节失败留痕加的形参），不用为这个再改一遍调用链；now-playing 那条在 goroutine 闭包里，`durationSecs` 跟 `artist/title/album` 一样**在闭包外捕获**，不能在 goroutine 里读 `p.cur`（那会违反「所有状态只在 poll 主循环里碰」）。
- ⚠️ **「艺人归并」在这个项目里有四处，它们服务的目的不同，不要试图合并成一套**（2026-08-30 通盘梳理时定的边界）：
  | 位置 | 作用 | 可逆 |
  |---|---|---|
  | `resolveScrobbleArtist`（写侧） | 决定**往 Last.fm 发什么字节** | ❌ **不可逆**，Last.fm 纠错库已冻结（三档：全部／只发第一位／智能，默认不折；智能档见下） |
  | `topartists.go` 并查集（读侧） | 歌手榜分组 | ✅ 纯展示 |
  | Swift `ArtistCredit`（读侧） | 界面分组 + 「第 N 次听」写法族 | ✅ 纯展示 |
  | `digest.go`（读侧） | 日报/周报推送 —— **2026-08-30 之前完全不归并**，已接上榜单那套，见第 15 章 |
  - 写侧跟读侧**不是一类东西**：读侧算错了下次刷新就好，写侧算错了是往用户历史里写一条删不掉的记录。所以读侧可以激进、写侧必须保守。
  - **已知分歧，刻意保留**：Swift 侧认 `feat.` 家族（`feat./ft./featuring`，带词边界守卫），Go 写侧的 `artistCreditParts` **不认** —— 于是 `A feat. B` 在 `resolve` 第 3 行就 `len<2` 提前返回、整串原样提交。要不要给 Go 写侧补上 `feat.`：**不补**。理由：①实测这台机器 2384 条缓存里只有 1 例含 feat. 家族，且是 `張震嶽+Featuring：蔡健雅` 这种四套实现都处理不了的畸形写法；②写侧不可逆；③Last.fm 通常**本来就**把 `A feat. B` 当合法编目条目收录，强行折叠反而可能造出错误归属。收益近零、风险不可逆，不动。
- **合唱串：三档，默认原样发整串**（`resolveScrobbleArtist`，`features.json` 键 `lastfm_scrobble_artist_mode`，值 `all`／`first`／`smart`，**默认 `all`**；2026-09-03 起）。
  - `all`：原样发播放器报的整串。`first`：纯字符串取第一位（`firstCreditedArtist`，不联网）。`smart`：按 Last.fm 编目判定，见下一条。
  - **遗留键迁移**：2026-08-31 ~ 09-03 之间的二态开关 `lastfm_scrobble_first_artist_only` 两侧仍读不写——新键缺失/非法时 `true → first`、否则 `all`（Go `resolveScrobbleArtistMode` / Swift `FeatureSettingsStore.load`，`TestScrobbleArtistModeFlagRoundTrip` 钉住 10 种组合）。非法档位值 Go 侧记一行日志再兜底，不静默。
- **智能档（`smart`）= 修好的「联网条件式折叠」**（`lastfmcollapse.go`，2026-09-03 作为第三档加回；2026-08-07 首版，08-31 整个删掉）。判定两步、顺序即守卫：
  1. 按原样的「合唱串 + 歌名」查一次 `track.getInfo(autocorrect=1)`。**已被编目收录**（有 mbid，或听众 ≥ 500，或有时长——三个都是影子条目不会有的东西）→ `keep`，原样发，**永久**。
  2. 没收录，再查「第一位歌手 + 歌名」。**折叠目标已被收录** → `collapse`，发第一位，**永久**；目标也没收录 → `defer`，维持原样，90 天后允许重查。
  - 跟 08-31 删掉的那版比，修了三处、也正是当时列的删除理由：
    - **结果不可复现** → 每首歌只判一次，`keep`/`collapse` 永不重查（"已收录"不会变成"未收录"，"折过一次"再翻回整串只会把用户自己的历史劈成两半）；唯一允许重查的 `defer` 不是结论。要强制重判，删缓存文件。
    - **「查不到就折」折进一个 Last.fm 也不认识的名字** → 加了第 2 步目标核查。它同时是 `firstCreditedArtist` 之外的第二道防线：切错头（K/DA → K 那次真实事故）时「K」名下不会有这首歌被正规收录，不折。
    - **「限流/超时会走进查不到分支」** —— 这条其实当时就不成立（老码失败即原样、不缓存），现在照旧：网络/429/5xx/坏 JSON/非 "not found" 的 error 6/error 29/听众数字段不是数字，一律返回原串、不写缓存。
  - **now-playing 与 scrobble 一致性**：两条路径 + 回填共用同一份缓存，正常情况必然同名。**唯一**可能不一致：now-playing 那次查询失败（原样、不缓存），几分钟后 scrobble 那次查成功并判 `collapse`——此时以 scrobble 为准（永久记录 > 几分钟的瞬时状态），刻意取舍。
  - **预算**：一次判定最多两个 GET，单个 4 s、合计 6 s；`mirrorAsync` 在智能档下把总窗口从 8 s 加到 14 s（`mirrorTimeout`），写入那 8 s 不被挤占。判定器只在有只读 api_key 时构造（`lastfmBridgeAPIKey()`），没有就整档退化成原样发。
  - **缓存文件** `~/.config/lyrimuse/lyrimuse-lastfm-collapse.json`：键 `"歌手串\n歌名"`（收录情况按曲目，同一合唱串在不同歌上结论可以不同），值带 `verdict`/`artist`/`ts` 和两步的判据留痕（`joint`/`primary`：found/mbid/listeners/duration_ms，只写不读，给人事后核对）。2026-08 老格式（没有 verdict）加载时丢掉重判——那批只做了第 1 步，不能升格成永久结论。tmp+rename 落盘，常驻 collector 与回填子命令共读一份（`backfillcli.go` 也设 `lastfmCollapsePath`）。
  - 歌名含 `+`/`%` 必须走 `lastfmGetQuery` 双重编码（下方「已知坑」）——error 6 在这里意味着"可能折叠"，编码错就是把正规合体署名折坏。`TestCollapseRequestShape` 钉着 `%252B`/`%2525`。
  - 测试：`lastfmcollapse_test.go`（判定矩阵 16 例、永久性、defer 到期、失败不缓存、键带歌名、请求形态、nil 透传、落盘往返+老格式丢弃、端到端三档）+ `scrobbleartist_test.go`。
  - **默认 false（发整串）的依据**：ListenBrainz 文档明写合唱 credit 应当 *"include them all"*；Navidrome 同名开关 `Lastfm.ScrobbleFirstArtistOnly` 默认也是 false，其注释说明这是给 Last.fm API 缺陷的 workaround、不是正确性修复；折叠会丢信息且不可逆（`Khalil Fong & Fiona Sit` → `方大同`，薛凯琪没了），不折叠最坏只是 Last.fm 上多一个听众很少的合唱条目——**代价不对称**。
  - ⚠️ now-playing、scrobble、回填三条路径必须调**同一个**函数（现在签名带 `ctx` 和判定器：`resolveScrobbleArtist(ctx, s.collapse, artist, track)`），否则会出现「now playing 显示 A、落库却是 A & B」的自相矛盾状态。
  - `first` 档走 `firstCreditedArtist`（纯字符串、不联网），`/` 仍与逗号顿号分档——`K/DA` 不会被劈成 `K`（有断言钉着；那次真实事故见下方「已知坑」）。
  - ⚠️ **2026-08-31 做完之后整整一天没有界面入口**（2026-09-01 补）。当时 collector 侧齐了（`resolveScrobbleArtist` + 开关 + `TestResolveScrobbleArtist` + `TestScrobbleFirstArtistOnlyFlagRoundTrip`），App 侧的 `FeatureSettingsStore.lastfmScrobbleFirstArtistOnly` 也齐了（编解码 + `@Published`），文档（本节 + 公开的 `docs/scrobbling.md`）也写了 —— **唯独没有任何 View 绑定它**，只能手改 `~/.config/lyrimuse/lyrimuse-features.json`。用户来问「我记得之前加了一个配置项…在哪里呢，我怎么找不到，是做了吗」，找不到是对的。
    - 现在的入口：**账号 → Last.fm →「设置」段 → `Scrobble` 卡 →「合唱歌曲的歌手」**，分段控件「全部／只发第一位／智能」（2026-09-03 加第三档，`LastfmScrobbleArtistMode.allCases`）。
    - **这类漏洞从代码里看不出来**：`FeatureSettingsStore` 里属性齐齐整整，缺的是最后那一步 UI。同一次会话里还撞到第二例（第 11 章「更新时间」排序，注释写着"挂起等用户确认"然后就停在那了）。要查全得反过来对账：`FeatureSettingsStore` 的每个属性有没有任何 View 读它。
  - **界面文案两次收窄**（2026-09-01）：先按「只需要说明最终的效果是什么就好」去掉了推荐语，再把「而 scrobble 落进 Last.fm 之后基本删不掉」整句也去掉了（用户圈图指定）。现在只剩各选项自己的效果（2026-09-03 加的「智能」一段同样只写效果：Last.fm 上已有合唱条目就原样发；没有、而第一位名下已有这首歌就只发第一位；两边都查不到原样发；每首歌只判一次）。⚠️ 那半句的判断依据**没丢**、也不是被否掉了才删的：写侧不可逆这条论证仍然在 `resolveScrobbleArtist` 的头注、本节上面几条、以及 `docs/scrobbling.md` 里，改这行字的时候别把它当"已经不重要了"。

### 5. iPhone 桥接（poller bridge）

iPhone 端由 FastScrobbler 直接写 Last.fm；collector 周期拉 `lastfmRecent`（后台 goroutine，8s 超时），把**不是本机镜像产生的**新记录转发进 ListenBrainz（source=iphone）。防重三件套：
- `forwarded` / `lfmMirrored` 两个 **7 天 TTL 落盘集合**（`persistedTTLSet`，按精确 uts 去重，不用单调水位——手机后台同步会迟到乱序）；
- `recordRecentMacListen` 24h 内存缓冲做**近重复抑制**（Last.fm 会给曲名加校正后缀，精确 uts 匹配抓不到时按 artist+title+时间近邻兜底）；
- `bridgeMaxListenAge = 3 天`：更老的记录一律不转发（防 TTL 裁剪后周期性重灌、防回填的历史 scrobble 被当新收听）。

**广告不算收听**（isAdBreak，system.go）：Spotify 广告在 submitSingleAsync（scrobble/LB/本地日志的总漏斗）、announce（playing_now + Last.fm updateNowPlaying 镜像）、退出 flush、relay、enrich 搜歌词五处统一拦截。判据（2026-08-19 两轮加固）：字段启发式＝Spotify 且（album 空/artist 空/标题「—」）；但实测广告字段会**闪变**（Blinds.com：开播 album 空、几拍后补齐，announce 的门逐拍按当下字段重判，看走眼一拍就漏成 nowplaying），故改为**会话级粘性标记**（`playSession.isAd`）：开播判一次（字段启发式，未判中且是 Spotify 再向本尊要一次 AppleScript 权威判据——`spotify url` 对广告返回 `spotify:ad:…`，每换曲最多一次 osascript、失败静默退回启发式），同曲期间字段任一拍判中即棘轮置位、绝不回落；五个拦截点全部改判会话标记（叠加当拍字段兜底）。App 侧 `isCurrentTrackAdBreak`（灵动岛「广告中」/收起）同款重做：换曲定初值＋同曲棘轮＋异步 AppleScript 确认（回来核对还是同一首才采纳）。App 统计页另有显示端兜底：nowplaying 行 artist 空/标题「—」/**与本机正在播的广告同名**（带全字段的广告只有本机权威判据认得出）不展示（已发出的 nowplaying 收不回，过渡期不能原样端给用户）。⚠️ 排查教训（2026-08-19 第三轮）：用户两次截图的"广告正在播放行"其实都是**本机实时行**（LiveScrobbleRow 分支①）渲染的，不是 Last.fm 数据——空心圆＝服务器从未确认，collector 侧当时已拦住；实时行的语义是"正在被 Last.fm 记录的歌"，已补 `!isCurrentTrackAdBreak` 闸（「第 N 次听」取数被 `if let live` 连带守住）。已知误伤面：Spotify 无专辑名的播客/本地文件不上送（明确取舍）。

### 6. 历史回填（backfill.go，仅 CLI 触发）

`collector backfill-lastfm [-dry-run]`：把本地日志里未提交过的收听批量补到 Last.fm。批 50 条（官方上限）/批间隔 2s/回溯窗口 13 天（Last.fm ~两周上限留余量）/单批 30s。失败保守：超时/网络错误整批隔离（"q" 行）**绝不自动重试**；服务端 ignore 记回执不再重来；限流(29)/凭据失效即中止。刻意不做成后台常驻行为，只由「账号连接」页用户显式点击触发（`ScrobbleBackfillService`）。dry-run 未连账号也能跑。**完成后联动刷新**（2026-08-18，用户报"补提交后最近记录没刷新"）：`accepted > 0` 时自动 `refreshBaseline(force:)` 强刷最近记录/今天/近7天（不等 2 分钟 TTL），并 `rewindDailySyncForBackfill()` 把热力图增量水位拨回 14 天前——回填塞进过去 ≤13 天的记录，不拨水位会被增量同步永远漏掉；同步在飞时回拨挂起到收尾应用（`pendingDailyRewind`）。accepted=0 不发请求。

- **补提交之后最近记录马上刷新**（2026-09-03，用户要求「刚连上补提交之后马上刷新一次最近记录」）。feed 时代最近记录的主来源是 collector 落盘的 feed（15 s/60 s 一拉），而回填是 App 起的**独立子进程**，进程内的 `requestLastfmFeedRefresh` 够不着常驻进程；此前只有 App 侧一发 `refreshBaseline(force:)`，且它紧跟在批量提交之后，Last.fm 多半还没把刚收的 scrobble 并进 recenttracks，于是要等下一个周期才看到。现在两层：① 跨进程信号文件 `lyrimuse-lastfm-feed-nudge`（`lastfmFeedNudgePath`，main.go / backfillcli.go 同一路径）——`runBackfill` 在 `accepted > 0` 时 touch，常驻进程 `bridge()` 每拍 stat 一次，文件在就消费掉（删除）并立刻拉 feed，App 靠 5 s 一次的 mtime 轮询几秒内拿到（`TestLastfmFeedNudgeFile`）；② App 侧 `ScrobbleBackfillService.runBackfill` 在原有那发强刷之外，8 s 后再补一发**只在 `feedIsFresh == false` 时**发的强刷，兜 collector 不在/还没写过 feed 的情况，feed 活着就不重复打 3 个请求。`accepted == 0` 两层都不动——Last.fm 侧什么都没变。

### 7. Last.fm 统计区（LastfmStatsSection）

- **实时行**（LiveScrobbleRow）：正在播放的歌 + 第 N 次听；快结束时 Last.fm 已落库、本地还在放——按进度锚反推开播时刻 ±120s 匹配「刚吸收的最近记录」（本机来源 only），把两行合并成一行、次数用已落库值顶替，避免同一首歌显示两条。
- **「第 N 次听」可点 → 合并明细弹框**（2026-09-04，用户要求；`PlayCountBadge` / `PlayCountBreakdownPopover`）：那格数字是下面「写法孪生族合并」之后的总数，用户看得到 N、看不到它由哪几个 Last.fm 条目凑成。点一下弹 `SettingsPopoverShell`（宽 440，封顶 460 内滚）：**摘要行**：歌名/歌手 + 「共 N 次 · K 种写法」（只有一种写法时不再单独列它——跟摘要是同一条信息，列两遍像重复，2026-09-04 用户反馈后改）；**写法清单**（≥ 2 种时）列并进这一行的每种写法（本尊 + `playCountSiblings` 那批——跟 `resolvePlayCounts` 求合并总数用的是**同一个**候选集，所以这就是「合并了哪些」的权威答案）、各自次数、以及**为什么并进来**的原因标签（`PlayCountFoldExplainer.reasons`：沿 PlayCountFold 的真实折叠步骤逐级比对，在哪一级第一次相等就报那一级——大小写/空格、全角/半角、繁简、Remaster/feat. 等标注、版本尾缀写法、双语歌名、合唱署名、歌手别名、歌名别名，都对不上报「其他折叠规则」不藏）；**专辑名分组**（同日第二轮，用户指出《晴天》23 次里「葉惠美」12 + 「叶惠美」11 两种专辑名写法也该看得见）：专辑不进 Last.fm 曲目身份、也不进我们的折叠键，Last.fm 自己就把它们记成一个条目，所以只能从逐条记录里数——每种写法下已拉到的记录按专辑名分组（`PlayCountBreakdown.albumGroups`），≥ 2 组才画子行（一种写法时直接挂在摘要下面），条数最多的一组当基准、其余组**只在确实是写法差异时**才挂 `PlayCountFoldExplainer.albumReason` 的原因标签（同一条流水线，判到双语拼接为止，专辑名没有别名表；对不上任何一档返回 nil **不挂标签**——同一首录音本来就会出现在原专辑 / 精选集 / 专辑的另一语言名（王力宏《心中的日月》=「Shangri-la」）下面，那是不同的专辑不是写法差异，第一版把它们标成「其他折叠规则」被用户问住，同日改）；写法没拉完时次数前加「至少」；**下半段**是合并后逐次的时刻（点的那条高亮、按天分组、跨年带年份、右侧专辑名、多写法时每行带色点——刻意不重复写法的歌名，色点够用、多一列字反而挤）；**底部对账**：行上的合计口径（`trackPlayCounts`，来自 `track.getinfo autocorrect=1` 求和）跟明细合计（各写法 `user.getTrackScrobbles` 的 `@attr.total` 之和）不相等时直接标「行上按 N 次计，明细合计 M 次」——两条接口一边 autocorrect 一边精确匹配，不等就是「有一种写法只被其中一边合并了」的信号，这正是这个弹框存在的目的。取数（`PlayCountBreakdownLoader`）弹出时才发、一个弹框一个实例不缓存（每次看的都是 Last.fm 此刻的账）：每种写法并发查一页 `user.getTrackScrobbles`（limit 200，interactive 优先级），几百次的歌由「加载更早的」按写法逐页补；合并/编号是 Core 纯函数 `PlayCountBreakdownMath.build`（selftest「合并明细」钉住）：每条 scrobble 原样保留、**不做跨写法同秒去重**——第一版做了（假设"同一秒只可能一条"），2026-09-05 用户点开卢广仲《Boring》报「行上按 18 次计，明细合计 16 次」，查 Last.fm 网页坐实 `卢广仲` 13 条 + `Crowd Lu` 5 条里 4 对同一分钟：是同一次收听被两台设备各 scrobble 一次（Mac 报中文名，iPhone 侧 FastScrobbler 报罗马字名），Last.fm 上 18 条都真实计数，行上的 18 就是这么加的，去重等于替 Last.fm 改账、还制造假的"两边不一致"，撤掉；同秒两条并排、色点不同，双端重复一眼可见；编号 = 合计 − 倒序下标，只对**编号截止**（没拉完的写法已拉到的最旧一条，取各写法里最晚的）之后的行有效，之前的显示「—」并在底部说明；某写法取数**失败**不静默丢——留在清单里标「未取到」、合计不算它、整体不编号（宁可不编号不编错），本尊失败整框失败态给「重试」；请求成功但 `total == 0` 的孪生（索引未建成时猜枚举里不存在的写法）不列。实时行同样可点，但 `expectedTotal` 传 nil（那边的数是 userplaycount + 1、含还没落库的这一次，对不上是正常的）、不高亮。⚠️ 结构性改动：历史行与实时行**不再是整行一个 Button**——Button 会吞掉 label 内嵌控件的点击（同 `collapsibleHeader` 那个「?」的坑），改成容器 `.onTapGesture`（打开 Last.fm 页面）+ 内嵌的次数 Button，子视图手势优先。
- **「第 N 次听」写法孪生族合并**（2026-08-18，当天从纯繁简两次扩成写法族）：scrobble 是本机播放的原样镜像，同一首歌因**写法差异**在 Last.fm 记成多本账。实测两类分裂：①繁简（《我不是农人》11/《我不是農人》3）；②**括号风格/副题**（丁世光《一口(The Day You Left Me)》半角无空格 25 次/全角 2 次/纯名《一口》1 次——全专辑只有 E.T./Simon 这种纯 ASCII 歌名从不分裂，31/29 次反而显得"不均匀"，用户截图坐实）。autocorrect 只在实体不存在时改写，帮不上。取次数时的候选来自**写法索引**（2026-08-19 起，数据驱动）：从用户自己的全量播放历史建 `PlayCountFold.key`（NFKC 全半角＋ICU 繁简（麼/麽 同折）＋去空格小写＋双语拼接 R1 收敛；**刻意不折一般括号副题**——括号常携带 Live/Remix 版本信息;**唯一例外是目录学噪音**(2026-08-19,同日两波用户实测):①remaster 家族((Remastered)/(Remastered 2014)/(2014 Remaster)/(Remastered Version)——宇多田ヒカル《Automatic (Remastered 2014)》与《Automatic》两本账);②feat 客串署名家族((feat. X)/(feat X)/(featuring X)/(ft. X)——王力宏《盖世英雄 (feat. 欧阳靖 & 李岩)》第 2 次 vs《蓋世英雄》几十次,历史账全在无副题繁体形下);③**`(with X)` 客串署名**、④**`(Bonus Track)` / `(Explicit)` 再版发行标签**(2026-08-22 补齐,见下段「口径的权威来源」)。这几族都是同一份录音的目录学差异,折进本尊;完整命中才折,混着别的词((Live 2014 Remaster)/(Live Bonus Track))不折,宁可漏合;"(Feathers)" 这类 feat 开头的普通词靠「前缀后必须跟点/空格+非空署名」挡住。判定在 `PlayCountVariants.isCatalogNoiseSubtitle`,枚举兜底也对**纯拉丁**歌名补「去副题」候选(此前纯拉丁完全不生成括号候选,正是漏网点;"纯英文 feat 副题各来源写法一致"的旧假设被②推翻)。折叠规则演进不用重建索引:`loadTitleForms` 加载时按当前规则从真实写法重算全部键,旧索引自动就地迁移）→ 真实写法族 的索引（`titleForms`），查次数按族查（去本尊、封顶 8）——新分裂形态一旦在历史出现即自动被族住，不用补表；userplaycount 只统计本用户 scrobble，历史里没有的写法必然是 0，索引按构造即完备。索引更新三通道：首次全量分页建（~110 页一次性，建成时整表作废重取）；每批已拉到的 scrobble 行（最近记录/热力图分页）零成本顺手收割；页面主刷新时从水位低频增量补漏（15 分钟节流）。索引未建成时退回猜枚举 `PlayCountVariants.siblings`（半角无空格＞全角＞半角带空格＞纯中文名＞繁简孪生，封顶 6，含字形变体表 `hanVariantPairs`：麼麽/裡裏/為爲/晚晩/線綫/眾衆——ICU s2t 永远生成不出的另一个繁体写法，曾是 v3 口径的主修法）——逐个 `track.getinfo` 求和，实时行与历史行（`resolvePlayCounts`）都走；表里存合并后总数，孪生行显示同一个数。三道守卫：①**身份集合去重**——每个变体响应里的规范 歌手|歌名 入集合，命中已计实体不再加（防 autocorrect 折回本尊、防两个变体折到同一第三实体）；②只为补封面的重查不碰次数表（`wantsCount`）；③快照 `mergedCountsVersion` 口径版本（当前 11＝第三批的修正(裸场次标记不归一/dashSuffixSplit 真取最后一个/归一后补剥/别名剔 jasonchan+kun);10＝R1 守卫套到原串＋版本尾缀分隔符归一＋罗马字歌手别名(第三批,用户拍板);9＝破折号版本尾缀＋with 头词黑名单(第二批);8＝目录学噪音补齐到参考实现(with+bonus track+explicit,2026-08-22);7＝合唱 credit 归并(2026-08-20);6＝索引口径＋目录学噪音折叠(remaster+feat);5＝仅 remaster;4＝仅索引口径。⚠️ 与 `PlayCountFold.foldVersion`（当前 7）是**两个**闸门、必须一起 +1：前者管跨启动的次数缓存作废，后者管盘上写法索引按新规则重折，漏一个用户看到的数字就不会变）——旧口径缓存加载时整表作废重取。**合唱 credit 分裂也一并合并**（2026-08-20 新增的第三类分裂）：同一次收听会以两种歌手写法进 Last.fm——Mac 照抄 Apple Music 的逐曲 credit（`Daniel Caesar & Mustafa`），iPhone（→Last.fm→桥接）报的是主歌手（`Daniel Caesar`）。实测《Toronto 2014》08:58 从手机进来、11:11 从 Mac 进来，Last.fm 上成了两个实体，两行都显示「第 1 次听」。`titleForms` 按**完整歌手串**分桶，两边互相看不见，所以另建一份派生索引 `primaryCreditFamilies`：桶键的歌手换成 `ArtistCredit.mergeArtist`（合唱归第一位）再聚一遍，查孪生时用它——两个方向都能看见对方，两行显示同一个合计数。派生而不是改 `PlayCountFold.key` 的歌手口径：那个键是整本账的身份，改了要 foldVersion +1 并全量重折，而这里只需要「查孪生时多看一眼隔壁桶」。`ArtistCredit.primary` 的分隔符跟 collector 的 `isArtistCreditSep` 同一份，但 **`/` 单独处理**：网易云式 `陶喆/卢广仲` 要切，而 `K/DA`、`AC/DC` 的斜杠是名字自带的（判据是切出来的头部长度，含汉字 ≥2、纯拉丁 ≥3，判不准就不切）；`K/DA, Madison Beer & (G)I-DLE` 靠「逗号先命中」天然保住完整的 `K/DA`。刻意不做：David Tao/陶喆这类**罗马字↔中文**分裂仍分开计（沿用既有决策）；scrobble 源头归一也不做（会跟历史主流写法分裂出新实体，iPhone 侧 FastScrobbler 也绕不过）；Last.fm 侧批量改名真合并（B 案）已提出未拍板。
- **口径的权威来源＝`scripts/export-lastfm-tracks.py` 的 docstring 规则清单，⚠️ 不是它的分桶结果**（2026-08-22 认定并当场限定范围）：那份导出脚本的 docstring 记着「2026-08-18 与用户逐对核定」的完整规则集（T1 `(feat./with …)` 客串剥除；T2 括号内 Remaster/Explicit/Bonus Track ＋ 无括号尾缀 `- <年份> Remaster(ed)`；T3 `Inst. → Instrumental`；手工对 `愛情轉移(國)`＝`爱情转移`；附录 B「刻意不做」清单）。**Swift 侧只搬了其中两族**，落后于自己的参考实现——用户 2026-08-22 报周杰倫《一路向北 (bonus track)》显示「第 2 次听」，实测 Last.fm 两个实体：`一路向北` 14 次、`一路向北 (bonus track)` 2 次，真实合计 16。当次补齐 `(with X)`／`(Bonus Track)`／`(Explicit)` 三族，在用户真索引（2160 族/2508 条写法）上模拟：**11 族收敛成 10 组，全部是真·同一份录音，零误合**；受益最大的几行 `一路向北 (bonus track)` 2→16、`不該 (with aMEI)` 8→14、`无所谓 (Explicit)` 1→13、`The Girl Is Mine` 2→11。
  - `bonus` 前面只允许挂**地区/渠道白名单**限定词（japanese/itunes/deluxe…），刻意**不**用 `\w+`——否则 `(Live Bonus Track)` 会把 Live 版并进本尊。参考实现用的是括号内**子串**匹配，Swift 侧没跟：完整命中是这边一贯取舍，子串会让这道守卫失效。
  - 刻意**不**收（改的时候别顺手加，selftest 里每条都有对应的 `expectNotEqual` 栅栏）：`(Clean)`（消音版是另一份音频，且索引里真有《Simple and Clean》，子串匹配会误伤）、`(original version)`（MJ《Xscape》原始版与当代化版是两套制作）、`(single version)`／`(7" Single Edit)`（用户未拍板）、`(國)`／`(粵)`（参考实现只做**手工对**没立通则——《K歌之王》这类同名國/粵两版是真的两份录音；用户索引里 7 条，要合得单独拍板）。
  - **同一次改动的另一半:派生串的 R1 版本标记守卫。** 补 `(Bonus Track)` 时用真索引实测撞出一个**回归**——方大同《悟空 2003 demo (bonus track)》剥掉附加曲标记后成了 `悟空 2003 demo`，接着 `collapseBilingual` 的 R1（CJK 段 + 拉丁段 → 取 CJK 段）把 "2003 demo" 当成译名吃掉，Demo 版就并进了录音室版（两个歌手写法各一例）。修法是**位置相关**的：R1 对**原串**照旧无条件收敛（那是长期在用的既有口径），只对**剥过目录学噪音的派生串**加 `versionMarkerWords` 守卫（live/demo/remix/version/karaoke…，按词比对、词两端标点先剥，好对上 `[live` / `2009]` 这种方括号残片）。派生串**仍然要**走 R1，只是带守卫——丁世光《低潮期 Tough Days (feat.葉喜兒)》正是靠「剥掉 feat 之后双语拼接名才有机会收敛」并进《低潮期》的，实测存在；试过的另一版修法（派生串干脆不走 R1）就会把这个正例弄丢。
  - **✅ 已修(2026-08-22 用户拍板):R1 对原串把中文歌名的版本尾缀当译名吃掉。** 此前 `流沙 - Live`、`愛愛愛 [Timeless Live 2009]` 这类「CJK 段 + 拉丁版本词」会被 R1 收进本尊——中文歌名的 Live/Demo 版**被并了**，而英文歌名的没有（`Angel (Live)` 带括号，R1 见括号就 bail），口径不自洽，也和「Live/Remix/Acoustic 是真的不同录音、照旧分开」以及导出脚本附录 B 的「刻意不做」自相矛盾。实测影响 **54 族**（方大同/陶喆/周杰倫/Hikaru Utada 居多），修完这些「本尊」行的数字合计**小 200**——那是变对了。顺带修掉两个重度退化键：`方大同|live版`（`All Night - Live版` / `Ten Reasons - Live版` / `Catch a Dream - Live版` 三首**不同的歌**焊成一族）、`方大同|薛凱琪`（`Something Stupid [Live 08] featuring 薛凱琪` 折成 `薛凱琪`）。
  - **同批做的一半:版本尾缀分隔符归一（`canonicalizeVersionSuffix`），但只做一半——「裸场次标记」刻意排除。** 修上一条会**新造**分裂：`流沙 - Live` 从本尊拆出来后跟本来就独立的 `流沙 (live)` 各成一族。所以尾缀是版本标记时把分隔符统一改写成半角括号——**分隔符不携带信息，副题内容才携带**。判定 `PlayCountVariants.isVersionSuffix`：英文靠分词命中 `versionMarkerWords`，中文靠「整串以『版』或『版本』收尾」+ 小词表（现场/演唱会/纯音乐/伴奏/原唱）。⚠️ 刻意**只**对版本尾缀归一——`月食 - The Weeping Woman` 这种**译名**尾缀要留给 R1 收敛到《月食》（有断言钉着）；单字中文歌名 + 英文尾缀（`鬼 - Overture`）靠的是 `collapseBilingual` 里 `han.count >= 2` 那道下限，不是版本守卫，**那条下限别动**。
  - ⚠️⚠️ **「副题内容相同即同一录音」不成立，所以裸场次标记不归一。** 这是并行核实用 `album.getinfo` 推翻掉的一半：方大同索引里 **21 条 `X - Live` 与《This Love Live 2007》的 21 首曲目完全双射**，而 30 条 `X (Live)` 只有 2 首落在那张里——两种写法指的是**两场不同的演唱会**（重叠曲目时长也不同：手拖手 2007=233s / 2011=236s，而索引里 `手拖手 (Live)` 报的正是 236000）。一个歌手可以有四五张现场专辑（方大同就有 `- Live` / `(Live)` / `[Live 08]` / `[Timeless Live 2009]` / `- Live版` 五套标签），所以**裸 `live` 是信息缺失、不是内容相同**。归一若不排除它，会把 5 首方大同的两场不同演唱会并成一首。判据 `PlayCountVariants.ambiguousConcertMarkers`。代价：同一场演唱会被两种写法记的会继续分开算（漏合，安全方向；陶喆那批 22 个 bare-live 合并因此也放弃了——我复现不出「两张现场专辑母带相同」那个论证，`- Live` 那批实体 duration 全是 0）。**带场次信息的照旧归一**（`[Live 08]` / `- 15 Khalil Live in HK 2011`）。
  - **`Live版` 是一个词，词表接不住。** 裸场次标记改成不归一之后，`All Night - Live版` 就从归一那条路掉回 R1，而 R1 的「CJK 全在后缀」分支会把整首歌折成 `live版`——**三首不同的歌焊成一族**。`PlayCountFold.isVersionToken` 里「以『版』/『版本』收尾」这条判据是那个重度退化键的唯一防线（撤掉它 3 条断言变红）。
  - **`dashSuffixSplit` 必须自己向前扫到最后一个分隔符。** ⚠️ Foundation 里 `options: [.regularExpression, .backwards]` 两个 option 同用时 `.backwards` **不生效**，返回的是第一个匹配——实测 `苏州河 - 慕容雪 - Mandarin Version` 被切成 `base=苏州河`，于是它跟 `蘇州河 - 慕容雪 (Mandarin Version)` 落进两个族，正是归一要消除的碎片。
  - **归一之后必须再剥一次目录学噪音。** 归一会把方括号里的内容翻成括号形，而 `stripCatalogNoise` 只认括号——少了这一步 `一口 [Remastered 2014]` 会从《一口》拆出去。当前索引 0 命中，但 Prince/MJ 那批方括号 remaster 标注一进中文标题就会踩到。
  - **落地实测（含并行核实后的修正）**：折叠族 2146 → **2200**；查族桶（「第 N 次听」真正按它合并）2146 → **1957**。第 1 条拆开 **54** 族、归一并回 **15** 族；第 3 条并 **234** 桶、拆 **0** 桶。两步分工别搞反：`canonicalizeVersionSuffix` 管尾缀型，`collapseBilingualGuardingVersionMarkers` 管**版本词不在尾缀位置**那一种（`Something Stupid [Live 08] featuring 薛凱琪`，方括号在中间）——别因为它「只值一条断言」就删掉，那一条正是把一整首歌折成人名的硬错。
  - **✅ 已修(2026-08-22 用户拍板):罗马字歌手名与中文歌手名各记一本账。** `David Tao` vs `陶喆`、`Jay Chou` vs `周杰倫` 在 Last.fm 是两个实体，此前是「刻意分开计」的既有决策，代价实测：**226 首**歌的次数被拆成两本互不相见的账，合并后合计 **+1875** 次（方大同/Khalil Fong 51 首 +708、陶喆/David Tao 38 首 +366、周杰伦/Jay Chou 36 首 +262、丁世光/Dean Ting 24 首 +255）。修法沿用 2026-08-20 合唱 credit 归并的既有做法——只加在**派生索引**上，不改 `PlayCountFold.key` 本身的歌手口径：新增 `PlayCountFold.familyKey(artist:title:)` = `key(canonicalArtist(mergeArtist(artist)), title)`，别名表 `romanizedArtistAliases` 的**键和值都是归一后的形态**（`davidtao` → `陶喆`）。⚠️ 匹配必须是**整串相等**，绝不能改成子串/前缀——索引里有 `Count Basie`（→`countbasie`），子串匹配会被 `asi` 命中（有断言钉着）。表里来自导出脚本已核定 `ALIAS` 的 21 条，加 5 条按本地索引实测补的（王力宏两种语序 / 陈奕迅 / 米津玄师 / 小袋成彬——那张表当时按需手写、没覆盖这几个；四组都有硬证据：前三组 `artist.getinfo` 的 `userplaycount` 两侧完全相等（1816 / 38 / 29）且罗马字页 URL 带 `+noredirect`，第四组两侧 bio 首句互相点名同一个人）。落地后实测：**234 桶**并起来、**0 桶被拆**。
  - ⚠️ **刻意从已核定表里剔掉 2 条**（并行核实拿到的新证据，不是口径分歧）：`jasonchan → 陈柏宇`——Last.fm 自己的 bio 开头就写 "Two artists share this name"，那个实体的 tags/similar 指向另一个 Jason Chan（上海 indie 系）；`kun → 蔡徐坤`——bio 确证 Kun 是蔡徐坤艺名，但那个实体 listeners 77663（蔡徐坤本人只有 5638）、tags 有 instrumental/neoclassical、similar 里是 WayV（队长也叫 Kun/钱锟）。两条收益各只有 **1 族**，属「今天没错、明天必错」。要加回来请先复查那两个实体的 bio/tags/similar。**短键雷区**（归一后 ≤6 字符的索引写法）：`kun` `asi` `sou` `sir` `k` `den` `musiq` `flo` `jid` `sza`…往表里加短键前先扫一遍 367 个歌手写法有没有整串撞上的。子串匹配的受害者除了 `Count Basie` 还有 `Fantasia`（索引里真有这个艺人），两条都有断言钉着。
  - **`familyKey` 是唯一入口，三处调用必须完全一致**：`LastfmStatsService` 的 `insertForm` / `playCountSiblings`、`LastfmStatsSection` 的 `recentRows`。之前是三处各自拼 `key(artist: mergeArtist(...), title:)`，任一处漏改就会出现「取数用的是合并总数、减法用的是另一套键」这种自相矛盾（就是 2026-08-21 报的「第 15 次听下面紧跟第 21 次听」那个形状）。
  - **✅ 已修(2026-08-29 用户反馈):歌名维度的罗马字/译名同样要能合并——「Love Love Love」其实就是《爱爱爱》。** 罗马字歌手名（上一条）解决的是歌手段的写法分裂，歌名段（title）此前完全没有跨语言归并能力——`foldTitle` 的 NFKC/ICU 繁简/全半角这些手段处理不了"一个纯中文字符串"和"一个纯英文字符串"实际指的是同一首歌这种情况。⚠️ **不能**照抄 `romanizedArtistAliases` 做一张全局 `title -> title` 表——实测本地写法索引（`lyrimuse-lastfm-title-forms.json`）里 `王力宏|lovelovelove` 是一个真实存在、非空的独立桶，跟方大同《爱爱爱》完全不是一回事；脱离歌手上下文的全局歌名替换会把两首不相干的歌焊成一首。新增 `PlayCountFold.titleAliasesByArtist: [String: [String: String]]`，**外层键是 `canonicalArtist(_:)` 输出再走一次 `stripSpaces(normalized(_:))`**（这样罗马字艺名/中文本名两种写法都能命中同一条），**内层键是 `foldTitle(_:)` 折出来的形态**——只有「这位歌手」名下「这个折叠键」才会被替换，不影响其它歌手同名或形似的歌名。`familyKey` 内多查这一层：`titleAliasesByArtist[canonArtist]?[foldTitle(title)] ?? title`。首条：`"方大同": ["lovelovelove": "爱爱爱"]`（后续几条见下面 2026-08-29 第二/三/四批，累计到第四批时这张表已有 6 条）。
    - ⚠️ **这次改动只 bump 了 `mergedCountsVersion`，没有 bump `PlayCountFold.foldVersion`**——读 `loadTitleForms` 代码确认过：`foldVersion` 只管 `titleForms` 索引里 `key()` 的键要不要重折迁移，而 `familyKey` 是派生索引 `primaryCreditFamilies` 的键，`loadTitleForms` 的两条分支（版本相等/不等）**都无条件**调用 `rebuildPrimaryCreditFamilies()`——也就是每次启动都会用当前的 `familyKey` 重新分组，不需要靠 `foldVersion` 触发迁移。`mergedCountsVersion` 必须 +1 是因为 `trackPlayCounts`（合并后的次数缓存）是按 `familyKey` 分组求和落盘的，口径变了不作废旧缓存会一直显示旧分组数字。
    - **2026-08-29 同一天第二批：追加 `"nanyin": "南音"` + `mergedCountsVersion` 12→13。** 用户看到"只处理了爱爱爱这一首，方大同还有一大堆英文曲名"，追问要不要一并处理。批量核实（`search-lyrics` CLI 逐一查网易云/QQ/酷狗/LRCLIB）了方大同名下另外近 60 首纯拉丁字母写法的曲目（As I Do / Bad / Moon River / La bamba 等，含若干翻唱欧美经典曲和几首像内部代号的花絮曲目 NMW/GF/BB88/TWIOCAMIC/XZMHXDXH），**结论是这些歌在四个平台上官方标题本身就是英文，不是遗漏归并**——只有 `nanyin`↔`南音` 一条被坐实：这首歌在另一个独立系统（`match.go` 的 `isProbablyWrongLanguageLyrics`，歌词候选打分那道语言闸，第 09 章第 25 条）已经用真实候选内容核实过确实是同一首歌，而本地写法索引证实 `方大同|nanyin` 与 `方大同|南音` 是两个真实独立记账的桶，加这条会立刻合并两边次数。`red bean` 有一点弱信号（酷狗给的标题带括号夹注 `Red Bean (红豆)`），但只有它一家、且是夹注不是独立标题，证据强度不够，**没有**采纳——这张表刻意只收多方证据支持、有把握的映射，宁可漏合，不猜；以后再遇到类似情况，同样按"多源交叉验证"的标准判断要不要加，不要单凭歌名字面像不像。
    - ⚠️ **`mergedCountsVersion` 连续两次 bump 的教训**：本地缓存文件在两次改动之间被真机装机运行过一次，已经把 12 这个戳写进了 `~/.config/lyrimuse/lyrimuse-lastfm-stats-cache.json`——如果第二批只顾着改代码、忘了把版本号也跟着 +1，`loadSnapshot` 会看到盘上的 12 跟代码里还是 12（如果没改）**相等**，直接照旧沿用旧缓存，新加的 `nanyin` 映射会看起来"改了代码却没生效"。改这张表之后，先查一眼本地缓存文件当前的 `mergedCountsVersion` 实际值，而不是想着"代码里最后一次改到了几就该是几"——两者可能不同步。
  - **⚠️⚠️ 2026-08-29 第三批，一次真正的方法论教训：「Black Hole」其实是《黑洞里》，上一批"批量核实近 60 首英文曲目"的核实方法本身就是错的方向。** 当时的核实方法是用 `search-lyrics` 查网易云/QQ/酷狗/LRCLIB 四个平台给出的官方曲目标题是不是中文，`Black Hole` 四个平台都给出英文标题，被判定"没有中文对应、不用处理"。用户后来指出这首歌其实是《黑洞里》——直接查 Last.fm 的 `track.getInfo`（公开接口）坐实：`黑洞里`（简体）与 `黑洞裡`（繁体）靠既有的简繁折叠早就自动合并在一起（约 40 次），`Black Hole` 独立记着 1 次，三者从没被放到一起看过。**根因**：查"音乐平台的官方标题是什么"和查"用户自己 Last.fm 历史里真实出现过的写法是什么"，是两件完全不相关的事——一个是平台管理员怎么给这首歌命名，一个是这个人自己的收听记录用什么字写的；上一批的核实全程只查了前者，从没查过后者。**正确的核实方法**是直接查用户自己的真实数据：Last.fm 的 `track.getInfo`（哪怕只是猜一个候选中文名去试，userplaycount>0 就是有效证据；0 就说明猜错了或者真没有）、或者本地写法索引缓存 `lyrimuse-lastfm-title-forms.json`。新增第三条映射：`"blackhole": "黑洞里"`。⚠️ 上一批的排除组结论（那近 60 首"查无中文对应"）**连带需要用这个正确方法重新核实**，不能沿用——里面大概率还藏着别的同类漏判，`red bean` 当时"证据不足未采纳"的结论尤其可疑，需要优先重查。`mergedCountsVersion` 13→14（同样先确认了本地缓存已经真机装过 13 才 +1，参照上一条教训）。
  - **2026-08-29 第四批：重新核实上一批的排除组，定下**"专辑曲目单定位候选 → Last.fm 真实次数交叉验证 → 时长比对排除假阳性"**三步法，找到 4 条新映射。** ①先用官方专辑曲目单（《橙月》《梦想家 The Dreamer》等公开曲目单）定位候选中文名，不再靠瞎猜或者查音乐平台元数据；②候选中文名直接查 `track.getInfo`，userplaycount 明显非零且远大于英文写法才算数;③**时长精确到毫秒比对**——这一步不是可选项，同一批核实里 `Weather Report` vs `天氣先生`（《危险世界》专辑序号紧邻、次数都不小）差点被误判成同一首歌，时长一查：`Weather Report` 只有 61 秒（像天气预报音效过场）、`天氣先生` 271 秒（完整歌曲），证伪，不合并。找到的 4 条（均时长精确吻合）：`smallinsects→小小蟲`（240000/241000ms,英文 1 次 vs 中文合计 65 次）、`black&white→黑白`（232000ms,1 vs 62）、`writeasongforyou→為妳寫的歌`（197000/198000ms,2 vs 合计 55）、`twentythree→才二十三`（224000ms,1 vs 11）。`red bean` **仍未能核实**（没找到它所属专辑的官方曲目单，不是判定"没有"，是"没查到"——留作后续线索，别当成已排除）；还有一批曲目（Favorite Stuff / Saving Snowy / Ten Reasons / TWIOCAMIC 等）同样是"未找到官方曲目单"，跟"已确认没有中文名"（翻唱经典曲/专辑内独立英文命名的过场曲）要分开看待，不能混为一谈。这批仍然没有 bump 版本号——上一批装机后本地缓存实测还停在 13（14 还没真正落盘过一轮），下次任何刷新都会因为 `14≠13` 触发全表重算，这 4 条新映射跟着一起生效，不需要再 +1；改这张表之后先查一眼本地缓存文件的 `mergedCountsVersion` 实际值再决定要不要 bump，别凑数。
  - **2026-08-29 第五批：从"人工加白名单"升级成运行时自动发现，用户当面拍板要"通用逻辑"。** 用户看到第四批之后仍有几首红标的歌没解决（`Love in this world` / `You Could Be` / `Revisited` / `red bean` / `Singer and model`），追问「是不能搞成一个通用的逻辑都去覆盖吗，只能这样一个一个加白？」——`AskUserQuestion` 明确拍板要「后台自动定期扫描、自动应用，不需要界面确认」（三个选项：设置页按钮手动触发+确认／后台自动扫描+自动应用／继续人工核实，选了中间那个）。`titleAliasesByArtist` 是编译进二进制的静态表，人工加一条要走三步法+改代码+装机；这次新增 `discoveredTitleAliases`（`LastfmStatsService`）是运行时可增长、持久化在本机的**第二张表**，通过 `PlayCountFold.setDiscoveredTitleAliases(_:)` 灌回 `HanScript.swift` 参与 `familyKey` 计算——**静态表优先，发现表兜底**（两者撞键时静态表的人工核定结果说了算，见 `familyKey` 内的查找顺序）。
    - **原理跟三步法的第③步同源，省掉①②两步**：同一首歌不管用哪种文字写，released 版本的 duration（`track.getinfo` 的 `duration` 字段，毫秒）理应完全相等——`Black Hole`/`黑洞里`/`黑洞裡` 三者都是 214000ms 就是这个信号的实证。省掉①②（专辑曲目单定位候选、人工看 Last.fm 播放数）之后，算法在**同一个 `canonicalArtist` 名下**，把已知写法按「代表写法含不含汉字/假名」（复用 `LyricsSyncEngine` 的 `CharacterSet.hanLike`，新增 `PlayCountFold.hasNoHanLikeChars(_:)`）分成两组，non-Han 组每个候选去跟 Han 组逐一比 duration。
    - **⚠️ 首次真实扫描方大同名下数据时当场坐实的碰撞风险，不是纸面推演**：`You Could Be`（225000ms）同时撞上 3 首不同的中文写法候选；`Revisited`/`red bean`（都是 236000ms）撞上同一组 4 首候选（其中「紅豆」字面正是"red bean"、很可能是对的，但 `Revisited` 配的是哪一首根本分不清）。原计划"取第一个匹配"等于在撞车时做一次接近随机的合并决定——**错合并的代价远高于漏合并**（两首毫不相干的歌次数被焊在一起，且不容易察觉、难以回退），所以改成候选必须**唯一**才采纳，撞车就整体跳过：这一改动导致 `red bean`（尽管很可能是对的）这次也被跳过了，是刻意的取舍，不是 bug。`Love in this world`/`Singer and model` 这两首实测 duration 在方大同全部 224 个中文写法桶里**找不到任何匹配**——不能排除"这首歌压根没有对应的中文写法在用户历史里"这种可能，用户报的"没做好"未必都是同一类问题。
    - **触发时机**：挂在 `syncHistoryIfNeeded`（写法索引全量/增量扫描）每次同步收尾之后（`discoverTitleAliasesIfNeeded`），复用既有的 15 分钟节流，不另开定时器；全程走 `.background` 优先级排队。找到新映射后立刻 `rebuildPrimaryCreditFamilies` + 作废受影响家族的 `trackPlayCounts`（不等 24 小时的判据④窗口，这是数据结构本身变了）。
    - **两张持久化表，且必须互相独立**：`discoveredDurations`（`playCountKey` → 毫秒，含查过但没有 duration 数据的 `0` 值，避免重复请求）与 `discoveryAttemptedAt`（候选 → 上次尝试时间，30 天冷却——"这个歌手名下一直没有对应中文写法"大概率是真的没有，不值得每次同步收尾都重查烧限速额度）。落盘文件 `lyrimuse-lastfm-title-aliases-discovered.json`，换账号不吃旧数据。
    - **不需要 bump `mergedCountsVersion`**：那个版本号管的是**静态表/代码层**的口径变化（旧缓存要不要整表作废重取），这次改动本身没有改静态表，动态发现结果的失效走的是"发现新映射时精确 nil 掉受影响家族"这条更细粒度的路径，两者是互补而非替代关系。
  - **2026-09-04 第三张表：从本机 enrich 缓存推别名（`EnrichTitleAliases.derive` → `PlayCountFold.setLocalTitleAliases`）。** 用户点开方大同《Oasis》的合并明细问「能不能把中文对应的歌名也合并进来」——历史里《那沙漠里的水》是同一首录音，两张既有表都够不着它。顺带核实了发现表在这台机器上的真实状态：`lyrimuse-lastfm-title-aliases-discovered.json` 当前**不存在**，09-02 的备份里 14 条采纳有 11 条是错的（「Mojito→红模仿」「Melody→中國姑娘」「Loser→飛燕」这种，整秒 duration 撞相等的假阳性），而且 09-03 加的「前台安静 60 s」门是瞬时判断、挂在同步收尾（正是前台刚忙完的时刻）几乎永远不放行，40 个请求的预算又按"先整体预留、不够就 `break scan`"处理——方大同名下 ~120 个中文写法一个候选都负担不起、而且一断整轮全停。**结论：发现表这条路目前实际没在产出，且产出时质量不可信；本次没有动它**（要不要下掉留给用户拍板）。新的第三张表用的证据硬得多、零网络：collector 已经替每首播过的歌独立做过歌词/平台检索，两种写法（连歌手写法都可以不同：`Khalil Fong|Oasis` 与 `方大同|那沙漠里的水`）各自落到**同一个网易云歌曲 id / QQ songmid**（enrich 缓存的 `netease_url` / `qq_music_url`）。判定在 Core 纯函数（selftest「第三层歌名别名」钉住）：同一 `canonicalArtistKey` 名下按 id 分组，「是不是中文名」按**主标题**判（剥掉括号/方括号/破折号副题后含汉字/假名——`Ten Reasons (Live版)` 只因一个「版」字被当中文名就会把录音室版并进 Live 版，`All for Joy (feat. 关诗敏)` 同理；歌词源本来就分不清同一首歌的版本，同 id 对**版本**不构成证据），四道闸：①任一侧折叠后不唯一整组不采纳（中文侧不唯一＝一个 id 配给两首中文歌；英文侧不唯一＝实测 陶喆 `I Like It (Ballad Version)` 与 `What Is Love` 落到同一 id，至少一条配错）；②两条都有播放器时长 `duration_secs` 且差 > 3 s 不采纳；③同一英文键从两个 id 组推出不同中文名两条都撤；④折叠键本来就相等的不产出。用真实缓存预演：方大同 12 首全对（Definition of Love→关于爱的定义、My Only Girl→麦恩莉、What Is Love→谁知爱是什么、Oasis→那沙漠里的水、No Russula Friend→无菇朋友、Playful→玩乐、Ru Guo Ai→如果爱、100 Zhong Biao Qing→100种表情、Warm→暖、Love At→爱在、Park→公园、Everyday→每天每天），陶喆 Regular friends→普通朋友 等。查找顺序 本机表 → 发现表；表不持久化（enrich 缓存本身在盘上，每次启动后台重算一次，`EnrichCacheReader.computeLocalAliasTables` 跟条目缓存同寿命）；`LastfmStatsService.refreshLocalAliases` 在 `loadTitleForms` 建族前灌一次、`refreshLocalCoversIfCacheChanged`（enrich 缓存 mtime 变了）再算一次，变了就重建族并把受影响写法的次数标过期（`flushLocalAliasStaleMarks`，旧值照显、后台重取）。合并明细弹框里这类合并显示为「歌手别名 + 歌名别名」标签。
  - **2026-09-04 下午：两张手写表全部删除，用户拍板「尽可能去掉手工表，一切由通用逻辑来覆盖，不要特殊化」。** 删的是编译进二进制的 `romanizedArtistAliases`（歌手罗马字 28 条）和 `titleAliasesByArtist`（方大同歌名 7 条）。替代：①**歌手写法归并** `LocalArtistAliases.derive`（并查集）——证据是 collector 的三份 MusicBrainz 缓存（`lyrimuse-artist-alias-cache.json` 原始标签→中文别名、`-identity-cache.json` 的 zh、`-primary-cache.json` 名字→全部别名，collector 解析歌词时已经替每个新歌手查过 MusicBrainz）＋ enrich 缓存里两种歌手写法名下曲目**共享 ≥ 2 个歌曲 id**（`Khalil Fong`↔`方大同` 13 个、`David Tao`↔`陶喆` 3 个；单个共享 id 实测全是噪音——`方大同↔王诗安` 合唱、`K↔英雄联盟` 配错）；每个连通块选代表：含汉字优先 → 本机曲目数多 → 字典序；MusicBrainz 别名去空格后不足 3 字符不用（`K`）；合唱串先归首位。核过这台机器：历史里真有罗马字与中文两种写法并存的歌手（Khalil Fong / David Tao / Jay Chou / Wang Leehom / Dean Ting / Crowd Lu / Leah Dou）全部推得出来，旧表其余 20 条（Eason Chan / Sodagreen / Utada…）历史里压根没有罗马字写法的播放，删掉零损失。②**歌名别名**在 E1（同歌曲 id）之外加 **E2：时长 + 歌词都对得上**——旧静态表那 7 条的英文条目在缓存里都没有平台 id，E1 够不着；E2 要求同歌手名下两种写法 ①都有播放器时长且**按精度分档**接近——两侧都是毫秒级小数时差 ≤ 0.05 s（同一份录音实测差 < 0.001 s：`Black Hole` 213.586666 vs `黑洞里` 213.586），任一侧是整秒才放宽到 0.6 s（`Twenty Three` 224 vs 224.499）；严到这个程度是因为歌词解析器本来就按时长挑候选，**配错词的两首歌时长天然接近**（实测南拳妈妈《神奇剪刀》配上了同专辑《小时候》的词，225.12 vs 223.99）②各自歌词可信（`duration_secs` 与 `resolved_duration_secs` 差 ≤ 3 s——`Weather Report` 61 s 过场曲配上了《天气先生》271 s 的词，光看歌词两首"一样"，正是旧表三步法当年用时长证伪的那个反例，现在是代码里的闸）③歌词正文（去时间戳/署名行/标点，NFKC＋繁简＋小写）**词元三元组** Jaccard ≥ 0.6（汉字一字一词元、英文一词一词元；⚠️ 第一版用字符二元组，对英文歌词完全失效——MJ《Keep the Faith》与《Thriller》0.65、时长又都是 5:57，直接被并成一首，装机前用真实缓存预演抓到）；满足的写法连边、并查集成类，类里选代表（含汉字 → 本机条目多 → 字典序），其余都指向它；连边的脚本规则：英文 ↔ 中文随便连，同脚本只连「等长且恰好一个字不同」（`为你写的歌`/`为妳写的歌`，你/妳 不在繁简表里；`无敌铁金刚`/`无敌铁金钢`），别的同脚本组合（`阿拉斯加海湾` vs `阿拉斯加海湾伴奏`）不连；候选折叠后不能带版本尾缀（别把英文录音室版并进中文 Live 版）。E2 的比对几百条一轮几十毫秒，放**后台**算（enrich 缓存播放中几秒变一次，主线程算会撞 20Hz 歌词节拍）。歌名表按**新推出的歌手表**分桶（`derive(_:artistKey:)` 注入键函数），两张表一起算。`mergedCountsVersion` 14 → **15**（族的分组来源整体换了，旧缓存整表作废重取）。selftest：旧表 7 条当 E2 回归样本 + 歌手推断每条证据/闸各一条。装机后用真实缓存核过：歌手 68 条（Khalil Fong→方大同、David Tao→陶喆、Jay Chou/Jay/ジェイ・チョウ/주걸륜→周杰伦、Wang Leehom/Lee-Hom Wang/Alexander Wang→王力宏、五月天 (Mayday)→五月天、陶喆和卢广仲→陶喆……）、歌名 36 条（方大同 30 条含旧表 6 条——`nanyin`/`南音` 漏了：`南音` 条目没有播放器时长，E2 两侧都要有；等它下次被播到、缓存里补上时长就会自动并进来），全部人工过目无误判。
  - **顺带修掉 `ArtistCredit.primary` 的一个真 bug**：`featMarkers` 里的 `ft ` 是**无左边界**的子串查找，于是蛋堡的罗马字名 `Soft Lipa` 被切成 `So`（「So|ft |Lipa」），歌手段落成 `so`、跟 `蛋堡` 在查族键上永远合不上——别名表加了也不命中。同类还有 `Daft Punk` / `Left Boy` / `Craft Spells` / `Soft Machine`。补上「marker 前面必须是空白或开括号」的守卫后，索引里被 `mergeArtist` 改写的歌手从 23 个降到 22 个（少的正是 Soft Lipa），蛋堡那 5 首随之合上。这跟 `isCatalogNoiseSubtitle` 里挡 `(Feathers)` 是同一类守卫——那边一开始就做了、这边漏了。
  - ⚠️⚠️ **「权威」只到规则条目层（T1/T2/T3 ＋ 附录 B）；它的 R1 实现与实际分桶结果是已知有害、Swift 刻意不对齐的部分。** 把这份脚本直接跑在这个用户自己的 2510 条写法上实测：它把 273 条写法塞进 11 个巨桶，最大一个 **137 条成员**——方大同几十首**不同的歌**（南音／公園／紅豆／三人遊／愛愛愛…）连同各自的 Live／`[Timeless Live 2009]` 全并成一首；第二大 70 条是陶喆同形态，第三大 20 条是周杰倫。根因是它的 R1 把 CJK 段和拉丁段**两段都当 union key 追加**，于是 `live` / `timelesslive2009` 成了歌手内的公共键，所有双语结构的曲目传递性地焊在一起——这直接违反它自己 docstring 里「刻意不做 Live」的声明，也说明「与用户逐对核定」那句只覆盖得到规则条目、覆盖不到分桶产物。Swift 的 R1 是「替换而非追加、且要求空格分词」，天生比它安全。**所以：照搬它的条目清单是对的；照搬它的 R1、或把 EDITION 的 contains 前视语义搬过来，是灾难**——后者会同时废掉「`(Live Bonus Track)` 挡得住」和「方括号残片被锚定判 false」这两道守卫。
  - **`(with X)` 的头词黑名单（`nonCreditHeadWords`）**：`feat./ft./featuring` 是纯署名标记、语法上后面只能跟表演者；`with` 是介词，后面还能跟乐队编制（`with strings` / `with orchestra`）、音频内容（`with intro` / `with backing vocals`），本身又能当歌名首词（`With or Without You`）——这是 with 与 feat 的**本质不对称**，守卫不能照搬。头词落在黑名单里就不折。这个用户索引里 19 条 `(with …)` 头词全是真人名，**这张表当下 0 命中、加它零行为变化**；加它的理由是折叠键会**永久**写进索引文件，而这个库里有 Horace Silver／Paul Desmond／Johnny Griffin／Nancy Wilson 这批爵士，「with strings」正是该品类的标准写法，哪天进库就是错合。代价：`with The Weeknd` 会被 `the` 漏掉（宁可漏合）。**别去动**「前缀后必须跟点/空格」那道守卫——那道是挡 `(Feathers)` 用的，`Without You` / `Withdrawal` / `Within Temptation` 也全靠它挡住（都有断言钉着）。也**不要**采纳「base 含汉字且 sub 全拉丁时 with 就不折」这种修法：那正好制造中文歌/英文歌待遇不同，还会把《不該 (with aMEI)》《等你下课 (with 杨瑞代)》这些旗舰案例全弄丢。
  - **破折号版本尾缀（参考实现 T2 的另一半，`Bad - 2012 Remaster` ＝ `Bad`）。** 索引里 216 条 ` - ` 尾缀，只有 **6 条**能过 `isCatalogNoiseSubtitle` 那道锚定判定，**4 例真并**（MJ Bad 15→16、Smooth Criminal、Man In The Mirror、The Way You Make Me Feel，都是并进已有的 `(2012 Remaster)` 族），其余 210 条（`- Live` / `- 鋼琴版` / `- Demo Version` / `- Original Karaoke` / `- Single Version`…）一条没动，0 族被拆。四道守卫都有断言压着：①破折号**两侧必须有空白**（`\s+[-–—]\s+`）——参考实现的 `\s*[-–]\s*` 会把 `Anti-Remastered` 切成 `Anti`，**刻意不照抄**；②副题必须过同一个锚定判定，不能无条件剥（不判定的话 216 条里 210 条会被吃掉，好 4 坏 210）；③要和括号剥法**交替**循环，否则 `X - 2012 Remaster (feat. Y)` 只掉一层；④剥完要 trim 尾部连接符（`X - (2012 Remaster)` 剥完剩 `X -`，不擦就落成 `x-`）。
  - **配套修了「第 N 次听」的减法键**（`LastfmStatsSection.swift` 的 `recentRows`）：`trackPlayCounts` 里存的是**整族合并总数**，而那里原来用 `playCountKey`（只 trim＋小写）去数「比这一行更新的同曲收听」——同一首歌的两种写法是两个不同的 `playCountKey`，跨写法的更新收听一次都减不掉，于是同页两行显示同一个 N。这正是 2026-08-21 报的「第 15 次听下面紧跟着第 21 次听」那个形状，而放宽折叠口径会**提高**它的触发概率（《一路向北》与《一路向北 (bonus track)》同页时两行都会是「第 16 次听」）。改成跟 `playCountSiblings` 查族**完全同一个键**：`PlayCountFold.key(artist: ArtistCredit.mergeArtist(row.artist), title: row.title)`；取数仍用 `playCountKey`（表就是按它存的）。
  - **两个版本闸门必须锁步，而且这次抬了两次**：`PlayCountFold.foldVersion` 3→4→5→6→**7**、`mergedCountsVersion` 7→8→9→10→**11**（同一天四批）。每一批都要再抬是因为 4/8 那版**已经装过机**、盘上有可能已被盖成 4/8——版本相等时 `loadTitleForms` 会直接采用盘上旧键、**永不迁移**，而 `scheduleTitleFormsSave` 又**无条件**写当前版本号，会把「旧键混新键」的文件盖上新版本戳，之后永远不再触发迁移。这是**静默**失效：不报错、不自愈，界面看着像没改而代码看着像改完了。两个数漏改任一个的后果：只改 `foldVersion` → 缓存里旧口径的数照端上桌，用户看到的数字一个都不变；只改 `mergedCountsVersion` → 每次冷启动重打整页 `getinfo`。
- **「第 N 次听」缓存作废的四条判据**（`applyRecent`）：①页内出现次数变多；②这首歌最新一条收听的时刻往前走了（2026-08-21 加，因为①在连播占满整页时会饱和）；③**页内自相矛盾**（2026-08-22 加）；④**距离上次验证太久**（2026-08-29 加，见下）。①②都要跟**上一轮**比，而基线 `newestPlaySeen` 只在内存里、次数表 `trackPlayCounts` 却是**持久化**的——这个错配留下一个**稳态**盲区：App 重启、或统计页关着的那段时间之后基线被重设成「当下」，只要那首歌**不再被播一次**，盘上冻住的旧数字就永远等不到作废。用户 2026-08-22 实测：缓存冻在 3、Last.fm 真实 12，而那一页有 11 行《开不了口 (live)》，`recentRows` 的减法（`n = 总数 − 页内更新的同曲行数`，`n <= 0` 留空）把后 8 行全算成 ≤0，**整片空白且不自愈**。③不跟历史比、无状态：**页内（按折叠族数）已经看得见的收听次数比缓存总数还多 ⇒ 缓存必错**，重启后第一轮就生效。按族数是硬要求——次数表存的是整族合并总数、`recentRows` 的减法也按族数，三处必须同一把尺子（`PlayCountRecency.contradicted` / `contradictedPlayCountKeys`）。配套 `playCountFetchedAt` 做 5 分钟节流并**刻意不持久化**（跟 `newestPlaySeen` 相反的理由：这里要的就是「重启后为空」，好让旧数字第一轮被质疑一次；持久化它等于把盲区焊回去）；节流是必需的，Last.fm 的 `userplaycount` 本身滞后几分钟，不节流就是每轮刷新（`baselineTTL` 110s）白发一个请求、永不收敛。
  - 同一次改动把基线赋值从 `if lastAppliedRecentPage == recentPage` 块里**提到外面**并改成取 max：原来重启后第一轮整段被跳过、连基线都没记上，要到**第三轮**才真正开始作废（注释里写的是第一轮记基线，差了一轮）；取 max 是因为翻到历史页时那一页的「最新」是很老的时刻，直接覆盖会把基线**调低**、翻回第一页凭空多判一次过期。
  - **✅ 已修(2026-08-29 用户反馈):判据③有一个盲点,一首"好久没被翻到、这次只是随手又听一次"的老歌永远等不到作废。** 用户报「方大同《橙月/Orange Moon》这张专辑听了很多遍,这首歌显示还是第 1 次听,显然没合并」——第一反应按写法归并去查（见上面 `titleAliasesByArtist` 那条),结果**查错了方向**:直接调 Last.fm 公开接口 `track.getInfo` 核实,这首歌从没被"橙月"这个中文写法记录过(userplaycount=0),它自始至终只用"ORANGe MOON"一种写法记账,而这个写法的**真实 userplaycount 是 31**,不是显示的 1——跟"归并"毫无关系,是缓存本身过时了没刷新。根因:判据③的第一道闸是 `onPage(这一页里这个折叠族出现了几次) > cachedTotal(缓存总数)`,只能抓"缓存明显偏小"的情况。这首歌很久没被主动播放,不会出现在最近记录的浏览窗口里,①②(依赖上一轮内存基线)因此从来没有机会比对;这次它只是又被听了一次、重新出现在页面上,`onPage=1`,而缓存冻着的旧值刚好也是 `1`——`1 > 1` 不成立,判据③直接判定"没问题",压根不会往下走到检查"上次验证是多久以前"这一步。这不是罕见的边界情况:**任何一首"好久没被翻到、这次只是随手又听一次"的老歌都会踩中同一个盲区**,缓存会在某个历史时刻永久冻结,不会自愈。
    - 修法是新增判据④:**不依赖"页内次数"这个脆弱信号,只问"距离上次真验证过去了多久"**——超过 24 小时（`LastfmStatsService.playCountStaleAfter`）就无条件重新拉取,不管页内出没出现矛盾。纯算术下沉到 `PlayCountRecency.stale(lastFetched:now:maxAge:)`,跟 `contradicted` 同一个文件、配 selftest。
    - ⚠️ **不能复用判据③的 `playCountFetchedAt`**——那个字段刻意**不持久化**(理由见上一条:重启后为空,好让判据③在第一轮立即质疑一次,不受 5 分钟节流限制)。判据④恰恰需要**跨重启**记住"上次验证是什么时候",否则每次冷启动都会把所有 key 判成"从没验证过"、无条件全部重查一轮,白白烧掉 Last.fm 的限速额度——两条判据对"要不要持久化"的需求是相反的,只能各自一份状态,新增了 `playCountVerifiedAt: [String: Date]`（持久化）。落盘方式跟 `trackPlayCounts` 一样按「这一页用得上的」裁剪（防止无界增长），编码进 `StatsSnapshot.playCountVerifiedAt`（老快照没有这个字段，解码时给空表，等同"从没验证过"，不算回归）。
    - 24 小时这个阈值的取舍:判据④的触发频率天然受"这首歌有没有重新出现在最近记录窗口里"这个前提约束(不是定时器主动扫全库),不会造成频繁的额外请求;太短会浪费限速额度,太长又会让老歌的次数长期显示不准——回到这次要修的问题本身。
- **`nowPlayingCount`（「正在记录」实时行的次数）没有自愈机制，会跟 `trackPlayCounts` 越差越远**（2026-08-24 用户报「为什么正在记录 17 次、下面历史行 28 次」）：`nowPlayingCount` 只在换歌那一刻（`refreshNowPlayingCount`）取一次，取完之后**不会重取**——设计初衷是防止「取晚了这次播放被 scrobble 进去多算一」，但代价是它跟 `trackPlayCounts` 完全脱钩：后者有上面那三条作废判据持续纠正，前者没有。实测坐实：《Controversy》换歌那一刻取到 16（显示 17），同一时刻 `trackPlayCounts` 经 `resolvePlayCounts` 刷新已经追到 27（显示 28）——查过当天只新增了一次收听，不是"还没并计进去"那种几分钟延迟能解释的量级，根因没能确定到具体是哪一层（不排除 Last.fm 接口本身在那一刻返回了陈旧值），但现象很干脆：这一次取数就是拿到了一个明显偏低的数，取完之后再没人管过它。
  - 修法：`reconcileNowPlayingCount` 挂在 `resolvePlayCounts` 每次合并新 `counts` 的地方——只要 `trackPlayCounts` 学到的总数比当前显示的 `nowPlayingCount - 1` 还高就采纳，**只能涨、不能跌**（`PlayCountRecency.reconciledNowPlayingCount`）。`nowPlayingCountPlayCountKey` 记录当前 nowPlaying 身份的 `playCountKey` 形态，换歌时跟 `nowPlayingCountKey` 一起设、账号重置时一起清。
  - ⚠️ 已知的窄边界（刻意接受，不是漏想）：如果追赶发生在**当前这次播放自己**已经越过 scrobble 门槛、且 Last.fm 已经把它计进 `userplaycount` 之后，追到的新总数会连这次播放也算进去，`+1` 之后偶发多算一。跟"完全冻结、整段会话数字长期错到离谱"（用户实测的 17 vs 28，差 11）相比，这个窗口窄得多、代价小得多——歌一换就会用全新的换歌取数覆盖掉，不会带到下一首歌头上。
- **Last.fm GET query 要双重编码 `+` 和 `%`**（2026-08-22 实测坐实）：`ws.audioscrobbler.com/2.0/` 的 **GET** 端点会对 query value **多解一次码**——先标准 percent-decode，再按 form-urlencoded 口径解一遍（那一遍把 `+` 当空格）。于是含加号的歌名走标准编码必然 404：`track=夜曲%2B窃爱 (Live)` → `error 6 Track not found`，`track=夜曲%252B窃爱 (Live)` → 命中 `userplaycount=2`。这是**端点级**行为，用真实存在的乐队 `+44`（733,475 听众）独立验证过（`%2B44` 同样 error 6）。入口是 `URLComponents.queryItems`——它按 `urlQueryAllowed` 编码，那套集合**放行 `+`**。修法：`LastfmQuery.escape` 先把 `%` 再把 `+` 各多编一层（顺序不能反），再按 RFC 3986 unreserved 严格转义；不含这两个字符的 value 编出来跟标准编码逐字节相同，对既有请求零影响。⚠️ **只有 GET 这样**：scrobble 走 POST form body（`lastfm.go` 的 `form.Encode()`）只解一遍，套上去反而会把字面 `%2B` 写进曲名——「记得对、却查不到」这个不对称正是本坑的表征。两侧各一份同规则实现（Swift `LyrimuseCore/Networking/LastfmQuery.swift`、Go `lastfmquery.go`），断言逐字节对齐，改一侧必须改另一侧。collector 那侧更要紧：智能档的 `probe`（lastfmcollapse.go）查不到就判「没收录 → 可能折叠歌手串」，是个**不可逆的写侧动作**，查错了就是把正规合体署名折坏（2026-08-22 修时现存 83 条判定缓存里没有含加号的，无既成损失；09-03 重做后 `TestCollapseRequestShape` 钉着双重编码）。
- **第①级自带图的第二道纠正：本机「封面归属已核实」的图优先于 Last.fm 实体图**（2026-09-01，
  用户报「最近记录里这两首封面显示错了」——陈奕迅《孤独探戈 (live)》《不如这样 (Live)》，
  专辑都是 The Easy Ride 演唱会，行里却顶着 Get A Life 的黑封面）。根因：Last.fm 把这两条
  scrobble 对到了它库里 **Get A Life 专辑**的曲目实体上，自带图（第①级）就是那张黑图；而
  同专辑其余行在 Last.fm 恰好**没有**自带图（走后面层级拿到正确的红图），于是列表里孤零零
  混着两张错场次的图。既有的「同专辑 ≥2 行自带图共识」纠正（2026-08-20）对这种形态无能为力
  ——兄弟行都没有自带图，共识表是空的。修法：`refreshLocalCovers` 顺带算第二张表
  `localAlbumVerifiedCovers`（`EnrichCacheReader.albumVerifiedCoverURL`），只收「条目按
  专辑键命中**且** `cover_album` 也对得上这一行专辑」的图（宽松口径与 `looseKey` 同源——
  行侧「陳奕迅」缓存侧「陈奕迅」这类繁简/空格差异系统性存在），这一档排到自带图**前面**。
  ⚠️ 资格门槛是刻意的：普通 `localCovers`（只按歌手+歌名命中、没核实过封面归属）**没有**
  纠正自带图的资格——collector 当年解析错版本存下的图（《孤独探戈》旧条目键是 Easy Ride、
  封面却真是 Get A Life 的）反而会把 Last.fm 对的图顶掉；`cover_album` 这道核实正是区分
  两者的依据（该字段 2026-08-20 起 collector 落盘，Swift 侧这次才第一次解码）。selftest
  `coverAlbumVerified` 用真实字符串钉住四道门。注意它只能救「本机缓存里封面已经对了」的行：
  缓存条目本身还是错场次封面时（等 v8 rescore 自愈或手动重配），这道纠正判定不通过、
  行为跟原来一致。
- **封面第⑤级：Apple Music 目录（iTunes Search）**（2026-08-22 新增）。前四级里只有第②级（本机 enrich 缓存）覆盖得了「Last.fm 对中文曲库缺图」这一大类，而那一级**只有本机播过才有数据**——iPhone 桥接进来的收听、翻历史页看到的老歌，天生在它的盲区里。实测（拉第 1/4/8/15/30 页、去重 205 首）：**25% 的行 Last.fm 自带图为空**；这 52 首里第③级 getinfo 只救回 20%、第④级同专辑兄弟救回 **0**（整张 live 专辑都没图时没有兄弟可参照）。第⑤级用 `MusicCatalogSearch.resolveArtwork`（免密钥，`artworkUrl100` 的 `100x100bb` 换成 `600x600bb`）。
  - **故意不复用 `pickBest`**：那个是给歌词窗口「前往专辑/前往艺人」跳转用的，松匹配且最后兜底 `items.first`——跳转跳偏了顶多是跳偏，封面挂错图会被当成事实。实测那条兜底会把《微醺卡带 - 情非得已 (微醺版)》配上《鱼翅Fin - 无声的告别是对往事的礼赞》的封面。`pickArtwork` 的规则是**歌手+歌名必须匹配，匹配不上就留空位**，绝不退回第一条。
  - **判据直接借 `PlayCountFold.familyKey`**，跟「第 N 次听」查写法族同一把尺子：NFKC、繁简（Last.fm 那行常是 `周杰倫`、iTunes 是 `周杰伦`）、去空格大小写、合唱归首位（`周杰伦` 对得上 `周杰伦 & 派伟俊`）、目录学噪音（`Phoenix` 对得上 `Phoenix (feat. …)`）——这些折叠恰好都是封面匹配需要的；而它**刻意不折 `(Live)`** 这类版本副题，Live 版和录音室版本来就该是两张封面（selftest 有 `美人鱼 (Live)` 不匹配 `美人鱼` 的栅栏）。
  - **必须扫完候选、不能只看第一条**：专辑也对上的优先。实测 30 首里有 5 首靠这一步纠正回正确那张（《NOW YOU SEE ME (Live)》第一条是录音室版《周杰伦的床边故事》、《青花瓷 (Live)》第一条是魔天伦演唱会）。挑不到专辑匹配的退成 `trackOnly`（同曲另一个发行版，比空位强但同屏可能不一致）。`searchURL` 的 limit 因此给到 12（跳转那条路径仍是 8）。
  - **时序闸 `coverUnavailable.contains(key)`**：第③级 getinfo 是异步的，页面刚打开那一瞬间 `recentTrackCovers`/`recentAlbumCovers` 都还空着，此时判「四级全空」会把整页算进来、白发一屏 iTunes 请求。等 getinfo 回来并把这一行记进 `coverUnavailable` 才动手。代价是比 getinfo 晚一轮出图。
  - 每轮最多 6 行（`catalogCoverBatch`）、并发 2（比 getinfo 的 4 更保守，iTunes 限流更紧）；结果进快照持久化（查一次一个请求，翻页来回不该重查）；匹配不上记 `catalogCoverUnavailable`，只在请求**成功返回**时记。
  - **共识不掺这一级**：`albumConsensusCovers` 仍然只看行自带图，跟本机缓存同待遇——否则变成拿两套来源互相投票。
- 最近播放列表封面：Last.fm 图 → enrich 缓存 `coverURL(artist:title:album:)` 兜底（`imageURL: listCover`）。
- **兜底要认合唱 credit**（2026-08-20 用户报「最近记录里这几首没封面」）：缓存 key 用的是播放器的逐曲 credit（`英雄联盟/Sara Skinner`、`Edouard Brenneisen & 英雄联盟`），而 Last.fm 那一行记的是主歌手（`英雄联盟`、`Edouard Brenneisen`）。前两级（归一化 key 精确 / `looseKey`）都救不了——`looseKey` 只把分隔符变体折成 `&`，**不会把合唱者去掉**。所以第三级那张「忽略专辑」的索引里每条同时进两个键：歌手写法原样的精确键 + `ArtistCredit.mergeArtist` 归并后的别名键（别名只填精确键没占的位置，精确写法永远优先）；查询侧也把行的歌手归并一次，两个方向都能命中（`EnrichCacheReader.coverIndexByArtistTitle` / `coverURLString`）。实测那一屏 6 首缺封面的行（英雄联盟原声带）在这一级下全部命中，两首本来就有封面的对照行在这一级之前就已命中。索引改成按 key 排序建：原来靠 Dictionary 遍历顺序「先到先得」，同一份缓存两次启动可能给出不同的图。
- **同专辑封面共识**（2026-08-20）：行自带的 Last.fm 图**不再无条件优先**。同一首歌被两种歌手写法拆成两个 Last.fm 实体时，两边挂的图可能不是同一张——实测《Toronto 2014》的合唱实体挂的是单曲封面（深蓝纹章），同专辑其它行挂的是 NEVER ENOUGH 专辑封面，于是连播的列表里孤零零混进一张别的图。规则：按「合唱归第一位的歌手 + 专辑名」把当前这一页分组，**同组至少两行挂同一张图**才算共识，只有跟共识不一致的那一行被纠正（`ArtistCredit.albumConsensusCovers` + `coverURL(for:)`）。共识只看行自带的图，不掺本机缓存/getinfo 的兜底图（否则是拿两套来源互相投票）；一行一张各不相同（合辑/逐曲封面）时没有共识、照原样显示。跟 `recentAlbumCovers` 分工不同：那个补「压根没图」的行，这个纠正「挂错图」的行。
- **播放热力图**（2026-08-18）：档案卡（今天/近7天/总量）右上角日历按钮 → popover 弹 GitHub 贡献图风格年历（周列×周一至周日行，色阶=当年非零日的四分位数，GitHub 官方浅/深两套绿）。数据=`LastfmStatsService.dailyCounts`（本地时区天粒度桶）：`user.getRecentTracks` 全量分页聚合，首次同步整个历史（~110 页、页间 150ms），之后按 `dailySyncedThrough` 从「最后已同步天的零点」增量重拉（该天整天作废重算）；同步全程不动旧数据、全部成功才合并替换，失败只标记可重试。缓存 `lyrimuse-lastfm-daily-heatmap.json`（换账号不吃旧缓存）。
  - **⚠️ 2026-09-05 修的截断事故**（用户报「为什么只加载出了 2026 年的」）：热力图文件只剩 2026-08-14 起 22 天 / 3,124 次（Last.fm 总数 24,327），写法索引 2,554 族缩到 1,439，两个水位却都是"刚同步过"——于是 `ensureFirstSyncBootstrap` 判 `.done`，首次全量再也不跑，截断固化。统一日志只保留到当天 11:17，没抓到现行；从代码复盘出确定存在的洞：**`resetAll()`（连接/断开/换账号）拦不住已经起飞的扫描 Task**——它只把 `dailySyncing` 置 false、清表删文件，在飞那轮增量扫描收尾时 `var days = dailyCounts`（已被清空）+ 自己那几页 → 当成全部写回、水位盖成当下；同时 `ensureFirstSyncBootstrap` 又起了新一轮首次全量与之并跑，谁后写谁赢（当天 App 被各会话的 build.sh kickstart 十几次，首次全量很容易被打断在 10 页断点之前）。两处修法：①**`historySyncGeneration`**——`resetAll` +1，扫描 Task 每次 await 回来比对，对不上整轮作废、一个字节不写、也不动 `dailySyncing`（`refreshBaseline` 那边的 `baselineGen` 同款）；②**自愈**——`syncHistoryIfNeeded` 在水位 > 0 时比对 `sum(dailyCounts)` 与 `overview.total`，少于 70% 就判截断：清空 `dailyCounts`、两个水位归零、删断点，走首次全量重建（两个数都是"这个账号全部 scrobble"的口径，正常只差几十条）。不管截断是怎么来的，下一次同步都会自己修回来，不用手动删文件。

#### 刷新机制（`refreshBaseline` + `LastfmStatsSection.task`）

三条驱动路径，都过 `refreshBaseline` 开头那道 TTL 闸（`baselineTTL` 110s）：`onAppear`（开窗/切到这一页）、
120 秒一轮的 `.task` 轮询、以及 `NSApplication.didBecomeActiveNotification`（2026-09-02 加）。手动那颗刷新按钮走
`refreshBaseline(force: true)`——`force` 的唯一作用是把 `fetchedAt["baseline"]` 置 nil，从而**绕过 TTL 闸**。

⚠️ **2026-09-02 修了一组会让这张卡静默冻死的缺陷。** 用户报「这个刷新机制是不是坏了，之前一直停留在十几小时之前，
直到我手动点击刷新才去刷新」。取证过程本身值得记，因为第一个假设是错的：

- **先排除了"没东西可刷"**。当时刚查清同一台机器上 Safari 网页播放因为 `system.go` 的裸查 bug 完全不被 collector
  认领（连打卡都没有，见 02 章），所以第一反应是「Last.fm 上本来就没有新记录」。**实测否掉了**：磁盘上那份
  `lyrimuse-lastfm-recent-pages.json` 里第 1 页的真实打卡时间是 `22:31 … 21:02`／`17:47 17:44 17:42`／`15:09`／
  `12:39`，而用户截图里最新一条是「19 小时前」≈ 03:35 —— **Last.fm 上比它新的有整整 20 条**，列表确实冻了约 19 小时。
  collector 日志也证实打卡一直在跑（本地 10:00/11:00/12:00/15:00/17:00/21:00/22:00 都有 POST 到
  `ws.audioscrobbler.com`）。
- ⚠️ **读 collector 日志前先换算时区**：它是 launchd agent、进程没有 TZ，`log.Printf` 写的是 **UTC**，比本地慢
  8 小时。第一版时间线就是照字面读的，把"睡觉那 7 小时的空档"错当成了"19 小时没打卡"。
- **现场态查不到了**：诊断时 App 已经被另一个会话的 `./build.sh` 重启过，内存里的 `fetchedAt` 没了。所以下面①②
  只能给结构性判定、给不出当时的现场证据 —— 这也是⑤（加面包屑日志）的直接由来。

五处改动：

1. **轮询不再按页早退**（`LastfmStatsSection`）。原来那行 `guard stats.recentPage == 1 else { continue }` 的理由是
   "后面几页是历史，内容不会变，重拉一遍纯属打扰（正看着的那一屏被替换掉）"——对**最近记录那一列**成立，但它把整条
   `refreshBaseline` 一起早退了，而那一次调用同时还刷着上面三个数字（今天／近 7 天／总 scrobble），那三个跟页码毫无
   关系。后果：用户翻到第 2 页停在那儿，这整张卡**再也不会自动更新任何东西**，而回到第 1 页只发生在
   `RecentListensPanel.onDisappear`（卡片离开视图层级时）。手动按钮直接调 `refreshBaseline(force:)`、不经过这道
   guard —— 「只有手动点击才刷」由此得到结构性解释。现在无条件调；`refreshBaseline` 请求的本来就是**当前这一页**
   （`let requestedPage = recentPage`），不会把人弹回第 1 页。⚠️ 取舍是有意的：拿"历史页可能被原地刷新"换"永远不会
   静默冻住"，**别把 guard 加回来**。
2. **`fresh()` 对未来时间戳硬化**（`LastfmStatsService`）。旧写法 `Date().timeIntervalSince(at) < ttl`，`at` 落在
   未来时差值为负、恒小于 TTL → 这个 key **永远**算"新鲜"，所有走 `fresh()` 的自动刷新静默早退；而 `fetchedAt` 不会
   自己回到过去，这个状态一直挂到 App 重启，唯一逃生口正是 `force`。系统时钟被回拨（改时间／NTP 校正）就够触发。
   现在 `age < 0` 一律判过期并 `logger.warning` 记一行——判过期是安全方向：最坏多发一次请求，而不是永久不发。
3. **页缓存不再落 now-playing 那一行**（`scheduleRecentPageCacheSave`）。Last.fm 的 `user.getrecenttracks` 会把
   "正在播放"那首放在**每一页**响应的第一条（没有 `date`），而这份缓存按页存原始行 → 每页都存下"抓这一页那一刻在放
   什么"。实测这台机器的缓存 10 页 210 行里正好 10 条这种行，其中 8 条是同一首早就放完的米津玄师《Mirage Song》——
   展示缓存页时会把它显示成「正在播放」，而"正在播放"的真源是本机播放状态、不该由一份磁盘快照回答。
   ⚠️ **只在落盘这一层剔**（`filter { $0.date != nil }`）：内存里那份 `recentPageCache` 保持原样，`goToPage` 的
   stale-while-revalidate 靠它立刻上屏。
4. **切回 App 时补刷一次**（`NSApplication.didBecomeActiveNotification`）。此前只有 `onAppear` 和 120 秒轮询两条路，
   设置窗口一直开着、人去干别的再切回来，最坏干等 120 秒。不传 `force`——TTL 闸挡着，频繁切窗口只是几次字典查找；
   `force` 是"用户明确要求现在就刷"那颗按钮的语义。用这个通知而不是 `scenePhase`：本 App 是 `.accessory`，全仓已有
   8 处用的都是它。
5. **`refreshBaseline` 的每条早退都记一行面包屑**（`logger`，`me.yudaotor.lyrimuse` / `lastfm-stats`）。这条路径此前
   **一行日志都没有**，事后只能从磁盘缓存反推"列表确实陈了"，判不出是哪道闸门早退的。查法：
   `log show --predicate 'subsystem == "me.yudaotor.lyrimuse"' --last 1h`。

#### 缓存策略重构（2026-09-03）：存量先行、旧值不撤、热路径改走 collector feed

完整设计与实测数据见 `docs/proposals/lastfm-cache-strategy.md`（第 1.3 节的实测是这次改动的全部依据）。
一句话动机：**App 进程直连 Last.fm 的链路在本机走系统代理，实测 `track.getinfo` p50 1.2 s / p90 6 s /
16% 超时（12 h 审计日志 172/1053 次全部是 10 s 超时），同一时段 collector 的 Go 直连 p50 0.4 s / ~1% 失败；
`curl` 对照：直连 0.6–1.0 s 全成功，经代理 1.7–2.5 s 且 2/6 握手失败。** 所有"等网络"的界面态都被这条
慢链路放大成可感知的等待。设计原则从此定为：界面永远只读内存状态（L0），t=0 必有存量；网络只在背后把
内容变新；过期 ≠ 删除。

1. **最近记录 / 正在播放 / 总 scrobble 数改读 collector 落盘的 feed**（`lyrimuse-lastfm-recent-feed.json`，
   `lyrimuse-collector/lastfmfeed.go` 写、`LastfmStatsService.pollFeedFile`/`ingestFeed` 读）。collector 为了
   iPhone 桥接**本来就每 15 s 拉一次** `user.getrecenttracks limit=50`，同一份响应现在多解 `image` /
   `@attr.total` 后落盘（内容没变不重写、但至少每 60 s 心跳一次；tmp+rename 原子写）。App 侧 5 s 一次 stat、
   mtime 变了才解码，feed 行走**跟网络响应完全同一条** `applyRecent` 路径（作废判据/封面/次数/写法收割照旧），
   第 1 页（凑得齐时第 2 页）进翻页缓存并盖新鲜戳，`recentTotalPages` 按 `total/20` 换算（此前要等一次
   page=1 网络响应，冷启动翻页控件因此空窗）。feed 活着（`LastfmRecentFeed.freshWindow` 3 分钟内有写入）
   时给 `fetchedAt["baseline"]` 盖戳 → 既有的 110 s 轮询自然早退；feed 陈旧（collector 不在）→ 不盖 →
   轮询在 110 s 内自动接管。**没有显式的"模式切换"，退路就是旧行为。** 换账号：feed 头部带 `username`，
   不符即忽略。
   - collector 侧三处配套：①拉取门槛**只看 Last.fm 凭据**，不再要求 ListenBrainz 也配好（LB 那半边的
     转发/镜像门槛原样搬进 `applyBridgeResult` 的 `bridgeForwardingEnabled`）；②节奏自适应
     （`lastfmFeedInterval`：本机在放或 feed 里 10 分钟内有动静 → 15 s，空闲 → 60 s，替代固定 15 s）；
     ③镜像 scrobble 成功后 5 s **提前拉一次**（`requestLastfmFeedRefresh`，goroutine 里只碰 atomic，
     主循环 `bridge()` 消费），App 那边 ≤10 s 见到"上一首"、0 个 App 请求。
   - App 侧配套：`LiveScrobbleRow` 换歌后 10 s 的强刷、远端会话 45 s 的强刷在 `feedIsFresh` 时不发；
     `refreshBaseline` 三个请求只剩 feed 不在时的兜底。
2. **今天 / 近 7 天不再各占一个请求**：今天由 `LastfmRecentFeed.todayCount` 从日桶 + feed 派生（窗口盖住整天
   直接数；否则桶 + 同步后新行；两者都不行只给下界并补一个 `limit=1` 请求，`refreshTodayCountIfNeeded`）；
   近 7 天三个面（设置页 / 待机页 / 歌词窗口欢迎态）统一走 `IdleListeningStats.lastSevenDays`（欢迎态此前
   是唯一还读 API `overview.week` 的地方，口径不同且 feed 时代会变成陈值）。
3. **旧值不撤（真正的 stale-while-revalidate）**：四条次数作废判据命中改成往 `stalePlayCountKeys` 记一笔，
   `trackPlayCounts` 的旧值继续显示，`resolvePlayCounts` 把"在集合里"与"没值"同等重取，取到即移出；
   `nil` 从此只表示"从未有过"（`···` 占位只在那时出现）。换歌时 `nowPlayingCount` 先用历史表里同曲的已知
   总数 +1 顶上，真值回来再覆盖——徽章/实时行不再"先消失、等 1–9 s 再出现"。首次全量索引建成时整表
   标过期而不是清空；别名发现改变家族时同理。
   - **「那边没有」不再永久（2026-09-03 晚补）**。此前 `playCountUnavailable` 只进不出：行龄 ≥ 15 分钟
     （`playCountZeroGraceSecs`）时 `track.getinfo` 给 `userplaycount = 0` 或 error 6 就永久记"没有"、随
     `recent-pages` 快照落盘、重启也不重问，唯一解除是再播一次（`adoptFreshTotal`）。实测陳綺貞《慢歌 3》
     16:36:04 落库，16:36/16:38/16:40/16:46/16:50 五轮 `resolvePlayCounts` 都是 `0/1`——Last.fm 对新条目
     的按用户计数滞后远超 15 分钟——过宽限那一轮把它钉死，界面既无「第 N 次听」也无 `···`（占位只给
     "还在解析"），而 Last.fm 网页那边已显示 Scrobbles 1。同批还钉死了 Jehoda《Not Enough Seasons》、
     冠声文化两条有声书等。现在每条"没有"记 **时刻 + 连续命中次数**（`playCountUnavailableAt` /
     `playCountUnavailableStrikes`，随快照落盘），按 `PlayCountUnavailableBackoff` 退避重探：1 h → 6 h →
     24 h 封顶；重探只发生在 `resolvePlayCounts` 本来就会看的行上，对真没有的曲目每天最多一个请求；
     取到正数整套清掉（`clearPlayCountUnavailable`）。老快照里没有时间戳的键当作"欠一次重探"，装上后
     第一轮就把被钉死的那几首重问一遍。`resolvePlayCounts` 那条日志现在带未解析的键名（封顶 6 个）——
     这次排查只能靠 `0/1` 的时间点对是哪一首。selftest「次数不可用退避」12 条。
4. **失败不打扰**：`refreshBaseline` 三个响应各自落地（`mergeOverview` 逐字段合并，`overview == nil` 时三个
   都到齐才建，不凑假 0），`baselineFailed` 只描述最近记录那一列；有存量时不画「重试」行（数字卡
   `overview == nil` 才画），最近记录卡头 / 待机页列表头的「N 分钟前更新」变暗 + 小叹号、悬停说明"显示的是
   缓存"。此前 all-or-nothing 在 16% 单次失败率下整轮成功概率只有 0.84³≈59%。
5. **该落盘的都落盘**：「那年今日」进快照（`onThisDay`/`onThisDayDay`/`onThisDayUpdatedAt`，只在 `.loaded`
   时写；此前每次启动都"正在查"）；`fetchedAt` 白名单键持久化（12 组榜单 + `baseline` + `onthisday`，
   ⚠️ **戳只跟着内容一起回来**——快照里没有对应内容就不还原那个戳，否则"内容空、闸门却说新鲜"会让那年
   今日挂 6 小时"正在查"、榜单挂 15 分钟骨架）；`titleFormsLastTopUp` 进 `TitleFormsSnapshot`（重启 15 分钟
   内不再多扫一轮）。
6. **翻页预读**：落在第 N 页时后台拉 N+1 页原始行进缓存（`prefetchNeighborPage`，只拉行不解析次数），顺翻
   11 页之后零等待；跳页仍要等一次网络（本机 p50 2.8 s），旧页留着 + 翻页条转圈。
   - **同日追加：缓存页改按绝对位置拼，不再"先端上旧缓存、过会儿偷换"**（用户当天报「切换页码的时候过了一会会
     突然重新换一批」）。根因：翻页缓存是"按页存原始行"，超过 5 分钟就背后重拉（`revalidateRecentPage`），而
     Last.fm 的分页是"最新 N 条"上的偏移——期间每进来 k 条新 scrobble 所有页边界整体下移 k 行，重拉回来的
     "现在的第 N 页"跟端上桌的缓存版对不上，1–9 s 后整批被换掉（听有声书时几分钟一条，几乎必现）。修法
     `LastfmPageComposer`（Core，纯函数 + selftest）：每个缓存页记下抓取时的 `@attr.total`
     （`recentPageCacheTotal`，随页缓存落盘），当下起点 = `(N-1)*20 + (total_now − total_at_fetch)`；feed 的 50 行
     永远是位置 0 起。翻到第 N 页时把这些来源按位置铺到 20 个槽位：槽满且没有同一条记录出现两次 → 这一页此刻
     就是精确的，直接显示、**不再重拉**；有洞 → 走网络（旧页留在屏上 + 翻页条转圈，加载是明确的）。`storeFetchedPage`
     是四条网络路径的统一入口，漏了它那一页就永远拼不进来。只在 feed 活着时用（总数的权威来源就是它），feed
     陈旧时退回旧办法。已知的窄边界：手机迟到同步把一条 scrobble 插进 feed 窗口之下时，比它新的那段真实只下移
     k−1，按 k 铺会偏一格——跟 feed 交界处会撞出"同一条出现两次"被抓住，更深的页要等下次真拉那一页才归正。
7. **后台批任务让路**：`request()` 超时按优先级分级（前台 10 s / 后台 20 s，把 p90 6 s 的长尾从"失败重试"
   变成"慢成功"）；`track.getinfo` 的 **api error 6（Track not found）是定论**（`requestDetailed.notFound`），
   `resolvePlayCounts` 按"成功返回但为空"记进 unavailable、不再每轮重问——此前它跟超时一样只是 nil，实测 7 首
   Last.fm 根本没有的有声书章节每次 `applyRecent` 都重发 7 个请求、永不收敛，feed 时代 `applyRecent` 更频繁把这个
   洞放大了；别名自动发现按**新请求数**封顶 40（⚠️ 原 `discoveryBatchLimit=12` 注释写的是请求数、
   代码用成了候选数，实测一轮打出 131 个请求）且前台 60 s 内有请求就本轮跳过（`LastfmRateLimiter.interactiveIdle`）。

8. **歌手榜「加载失败」的真因与修法**（用户当天报「一开始是加载失败，点了重试之后一直是骨架」）：歌手榜走
   `collector top-artists -all-periods`，而 `artistMergeNameKey` 自 2026-08-31 起经 `resolveGenericArtistCanonicalName`
   查「英文标签→中文常用名」——CLI 进程既没加载那条链的两份缓存（MusicBrainz 别名 / QQ 歌手名），又对 4 时段 × 30 条里
   每个非中文名真查 MusicBrainz（全局 1.1 s 限速）+ QQ，实测一次 **1 分 49 秒**，App 侧 25 s 看门狗必然杀掉（日志
   `top-artists failed (exit 15)`），于是永远失败。修法两道：① collector `runTopArtistsCLI` 加载两份缓存，且 `-mb-budget 0`
   （App 用的默认档）时 `artistCanonicalCacheOnly` 让 canonical 名那一步只读缓存不联网（实测 2.6 s、只剩 4 个 Last.fm
   请求）；② App `refreshMergedArtistChart` 子命令失败时退回直连 `user.gettopartists` 拿未合并的原始榜（`fetchChartDirect`），
   不再把「重试」当终态。⚠️ 常驻进程里 `topArtistsDigest` 仍在 poll 主循环里同步做同一套归并、会联网，一天一次，未改。

刻意不做：App 绕过系统代理直连（换网络环境结论可能反过来，不该不可见地改路由）；`from=` 水位增量替代
整页重拉（省的是响应体积不是请求数，feed 把请求本身省掉了）。

#### 「那年今日」（`refreshOnThisDay` + `onThisDayCard`）+「收听足迹」（`listeningFootprintCard`）

去年同一天（0–24 点）的收听；整天为空自动往前一年，**最多探三年**。6 小时 TTL，且必须跟
**日历天**一起判（`DailyRefreshGate`，TTL 或跨天取或）——只判 TTL 会把昨天那份一路带过零点，
而 App 是常驻 launchd 服务、跨零点不重启，`fetchedAt` 只活在进程内存里，所以这不是理论问题。

**2026-09-03 两处扩展**（用户看到「过去三年的今天都没有收听记录」一句话孤零零占一段，反馈「花样太少」；
核实过那句是真的——2024/2025 整年无记录、2023-09-03 当天 0 条、前后两天分别 16/88 条）：
- **取数计划由本地日桶排**（`OnThisDayPlanner.plan`，Core 纯函数）：每年先看当天，当天为空**放宽到那一周**
  （±3 天），日桶里合计仍为 0 的窗口**不发请求**；按"年份近→远、天→周"排，沿计划请求，第一个拿到行的就是结果。
  结果带 `span`（day/week），卡头副标题据此说「N 年前的今天」或「N 年前的这一周」；老快照没有该字段 → 当天。
  日桶没同步过（首次全量还没跑完）时退回"三年只看当天、都发"的旧计划。三年的天和周都空时**零请求**直接判
  `.empty`，并把另一天算出来的旧结果撤掉（"保留旧内容"只对"没取到"成立）。`.empty` 现在要求计划里的窗口
  **全部**回来且都为空——见下面那条收严。
- **「收听足迹」卡**（`ListeningMilestones.summarize` / `nextMilestone`，Core 纯函数，零请求）：自起点第 N 天 ·
  有记录天数 + 日均 · 单日最高 · 当前/最长连续 · 今年至今（对比最近一个同期有记录的往年）· 距下一个整数
  scrobble 里程碑还差多少（<1000 按 100、<10000 按 500、之后按 1000）。日桶还在首次同步时只显示一句说明，
  不用残缺数据算日均/连续。两张卡各自可折叠（`np:lastfmFootprintCollapsed`）。

⚠️ **`fetchedAt["onthisday"]` 在发请求之前就写**，也就是**失败同样占住 6 小时**。这是刻意的
（否则一直失败会变成每次露面都重试，见 `DailyRefreshGate` 的参数注释），但它跟下面那个 UI
缺陷叠起来会变成一个很难查的现象。

- ❌ **已修（2026-09-01，用户报「那年今日有时候点进去是会空白」）：`onThisDay == nil` 把四种处境全渲染成一片空白。**
  - 原来整段是 `Group { if let o = stats.onThisDay { ...卡... } }`，**没有 else**。而 nil 有四种完全不同的成因：①还没取／正在取；②请求成功但那三年的今天确实都没听歌；③三年请求**全部失败**；④未连接。四种都是「什么都不画」，连一句「为什么」都没有。
  - **③ 最毒**：失败已经占住 6 小时 TTL，于是那个 2 分钟一轮的轮询（`LastfmStatsSection` 的 `.task`）会连着 6 小时**全部早退** —— 空白一直挂着，除非重启 App。
  - **这次实测的不是「没记录」**：直接打 Last.fm API 核过作者账号，1 年前 / 2 年前的今天 total=0，**3 年前 total=111**，循环本该在 `yearsAgo=3` 命中。也就是说用户看到的空白属于 ① 或 ③ —— 而它们原来跟 ② 长得一模一样，从界面上分不出来。
  - **修法**：加 `LastfmStatsService.OnThisDayOutcome`（`pending / loaded / empty / failed`），界面三态各有样子（正在查 ⟳ ／「过去三年的今天都没有收听记录」／「没能取到——Last.fm 没有响应」＋**「重试」**）。
  - **区分 `.empty` 和 `.failed` 的依据是循环里回来的年数 `responses`**（2026-09-03 从 `anyResponse` 收严）：三年**都**回来且都 `total == 0` 才是 empty——"都没有"是对三年下的结论，少一年就不能说；有任何一年没回来就是 failed + 重试。此前只要任一年有响应就判 empty，慢链路上第 3 年超时时会把"没能取到"说成"都没有"。
  - ⚠️ **「重试」必须走 `refreshOnThisDay(force: true)`**（新加的参数，只给这一处用）。不绕过那道闸的话，这颗按钮会被 6 小时 TTL 直接早退、点了什么都不会发生。
  - ⚠️ **重取时不清 `onThisDay` 本身**。手上已有内容时（跨天/手动重试）清了会让那张卡先闪成空再回来；取到新的自然覆盖，取不到也该继续显示旧的那份。只把 `onThisDayOutcome` 打回 `.pending`。
  - **同类风险**：这一区还有别的 `if let` 条件视图（榜单/热力图）。判据是「nil 有没有多种成因」——只有一种（比如"这个功能没开"）时空着无妨，有多种就必须说清是哪一种。

## 设置项

| 位置 | 项 | 影响 |
|---|---|---|
| 账号→ListenBrainz | token | LB 提交开/关与身份 |
| 账号→Last.fm | 连接/断开、镜像开关 | `lastfmMirrorScrobble`（features.json） |
| 账号→Last.fm→设置 | 短于 30 秒的曲目 | `scrobble_short_tracks`（features.json，默认 false＝不记；开了只 scrobble 到 Last.fm，ListenBrainz 不受影响）。见 §1「短曲目」 |
| 账号→Last.fm→设置 | 合唱歌曲的歌手（全部／只发第一位／智能） | `lastfm_scrobble_artist_mode`（features.json，`all`/`first`/`smart`，默认 `all`＝发整串；遗留键 `lastfm_scrobble_first_artist_only` 只读迁移）。界面 2026-09-01 才补、09-03 加智能档，见 §4 |
| 账号→网页推送 | relay 地址/密钥 | 第 13 章 |
| 账号→推送提醒 | Bark 配置 | 后台任务通知（第 15 章） |

## 与其它功能的交互

- 收听计次复用播放数据源的进度锚/循环重启判定（第 02 章）。
- playing_now 首条等歌词解析（第 09 章 pnPending）。
- 回填写入的历史 scrobble 会被 bridge 的 3 天窗挡住不回流（§5/§6 互相咬合）。
- 网页「今日统计/最近播放」由 relay 推送与 LB 数据合成（第 13 章）。

## 数据与文件

- `~/.config/lyrimuse/config.json`：LB token、Last.fm api key/secret/session（ConfigStore，导出备份会带走原文——第 14 章）。
- `lyrimuse-lastfm-title-forms.json`：「第 N 次听」写法索引（折叠键→真实写法族＋水位，换账号不吃旧索引，删了无损下次重建）。
- `lyrimuse-lastfm-title-aliases-discovered.json`：写法别名自动发现的动态表（歌手键→折叠歌名→中文本名歌名＋duration 缓存＋尝试时间戳，换账号不吃旧数据，删了无损、下次扫描重新发现）。
- `lyrimuse-lastfm-collapse.json`：合唱串「智能」档的判定缓存（2026-09-03，`lastfmcollapse.go`）：`"歌手串\n歌名"` → `{verdict, artist, ts, joint, primary}`；`keep`/`collapse` 永久、`defer` 90 天。删了 = 所有合唱歌重判（会各打 1~2 个 `track.getInfo`），不会丢收听数据。
- `lyrimuse-lastfm-feed-nudge`：回填子命令→常驻 collector 的「feed 提前拉一次」信号文件（2026-09-03，内容是 unix 秒纯供人看）；常驻进程下一拍消费并删除，正常情况下存在不到 5 秒。删了无损。
- `lyrimuse-lastfm-recent-feed.json`：collector 每次桥接拉取落盘的最近 50 条 + now-playing + `@attr.total`（2026-09-03，App 的最近记录主来源；内容不变时最多 60 s 心跳一次；删了无损，下一拍重写）。
- `lyrimuse-listens.jsonl`（收听日志，含隔离 "q" 行；已连 Last.fm 时只在**镜像失败**才写，见第 4 节 `recordFailedMirror`）；`forwarded`/`lfmMirrored` TTL 集合各一份落盘文件；Last.fm mirror 状态文件（红标依据）。

## 代码锚点

| 主题 | 位置 |
|---|---|
| 计次/提交调度 | lyrimuse-collector/poller.go `listenThreshold` `tooShortToScrobble` `shortTrackLastfmOnly`（短曲目闸，开关 `features.ScrobbleShortTracks`，只发 Last.fm）`submitSingleAsync` `applySubmitOutcome` |
| 「那年今日」取数与四态 | Settings/LastfmStatsService.swift `refreshOnThisDay(force:)` `OnThisDayOutcome` `OnThisDayResult.span` · LyrimuseCore/Util/DailyRefreshGate.swift `needsRefresh` · LyrimuseCore/Local/ListeningMemories.swift `OnThisDayPlanner.plan`（按日桶排窗口，天→周） |
| 「收听足迹」卡 | LastfmStatsSection.swift `listeningFootprintCard` `footprintCell`；LyrimuseCore/Local/ListeningMemories.swift `ListeningMilestones.summarize` `nextMilestone`；selftest 在 lyrimuse-selftest/LastfmTests.swift「那年今日计划 + 收听足迹」 |
| 「那年今日」界面三态＋重试 | LastfmStatsSection.swift `onThisDayCard`（⚠️ 那个 `else` 分支是 2026-09-01 修「点进去空白」的本体，别当冗余删掉） |
| Last.fm「设置」段 | AccountLinkingTab.swift `LastfmSection.settings` `lastfmScrobbleSettingsCard` · LastfmStatsSection.swift `Tab.settings`（画空、保持挂载） |
| LB 客户端 | lyrimuse-collector/lb.go `lbMeta` `submit` `coolingDown` `noteOutcome` `lbCooldownSchedule` |
| Last.fm 镜像/熔断 | lyrimuse-collector/lastfm.go `shouldDisable` `mirrorAsync` `provablyNeverSent` `ignoredReason` `lastfmIgnoredError`；poller.go `mirrorScrobbleTracked` `recordFailedMirror` |
| 次数写法孪生合并 | LyrimuseCore/Local/HanScript.swift `HanScript` `PlayCountVariants` `PlayCountFold`（歌手/歌名别名 2026-09-04 起全部运行时注入：`setLocalArtistAliases` `setLocalTitleAliases` `setDiscoveredTitleAliases`，手写表已删；`canonicalArtistKey` `hasNoHanLikeChars`）；Settings/LastfmStatsService.swift `playCountSiblings` `syncHistoryIfNeeded`（写法索引全量/增量扫描入口，2026-08-25 起取代旧名 `ensureTitleFormsIndex`）`harvestTitleForm` `userPlayCount` `mergedCountsVersion` |
| 写法别名自动发现（动态，2026-08-29） | Settings/LastfmStatsService.swift `discoverTitleAliasesIfNeeded`（逐 canonicalArtist 分 han/non-han 组比对 duration，唯一匹配才采纳）`durationFor` `discoveredTitleAliases` `discoveredDurations` `discoveryAttemptedAt` `loadTitleAliasDiscovery` `scheduleTitleAliasDiscoverySave` |
| 合唱 credit 归并 / 同专辑封面共识 | LyrimuseCore/Models/ArtistCredit.swift `primary` `mergeArtist` `albumConsensusKey` `albumConsensusCovers`；Settings/LastfmStatsService.swift `primaryCreditFamilies` `rebuildPrimaryCreditFamilies` `albumConsensusCovers` `coverURL(for:)` |
| 封面兜底认合唱 credit | LyrimuseCore/Local/EnrichCacheReader.swift `coverIndexByArtistTitle` `coverURLString` |
| 合唱串折叠(写侧,不可逆) | lyrimuse-collector/lastfm.go `resolveScrobbleArtist` `mirrorTimeout`（三档 `features.LastfmScrobbleArtistMode`，features.go `scrobbleArtistAll/First/Smart` `resolveScrobbleArtistMode`）；lastfmcollapse.go `lastfmArtistCollapser.resolve` `probe` `lastfmCatalogProbe.catalogued` `verdictKeep/Collapse/Defer` `lastfmCollapsePath`；match.go `firstCreditedArtist` `firstSlashCredit` `slashHeadPlausible` `isArtistCreditPrimarySep`；Swift 侧 Settings/FeatureSettingsStore.swift `LastfmScrobbleArtistMode`、AccountLinkingTab.swift `lastfmScrobbleSettingsCard`；同规则在 LyrimuseCore/Models/ArtistCredit.swift `slashHeadIsPlausible` |
| 封面第⑤级(Apple Music 目录) | LyrimuseCore/Local/MusicCatalogSearch.swift `pickArtwork` `upscaleArtwork` `resolveArtwork` `ArtworkConfidence`；Settings/LastfmStatsService.swift `catalogCovers` `resolveCatalogCovers` `catalogCoverBatch` `coverURL(for:)` |
| 封面第①级纠正(本机专辑核实图) | LyrimuseCore/Local/EnrichCacheReader.swift `albumVerifiedCoverURL` `coverAlbumVerified`；Settings/LastfmStatsService.swift `localAlbumVerifiedCovers`（`refreshLocalCovers` 内填表、`coverURL(for:)` 第①级消费） |
| 次数缓存作废四判据 | Settings/LastfmStatsService.swift `applyRecent` `contradictedPlayCountKeys` `newestPlaySeen` `playCountFetchedAt`（判据③专用，不持久化）`staleByAgePlayCountKeys` `playCountVerifiedAt`（判据④专用，持久化，编码进 `StatsSnapshot`）`playCountStaleAfter`；LyrimuseCore/Models/PlayCountRecency.swift `newest` `contradicted` `stale` |
| nowPlayingCount 追赶 trackPlayCounts | Settings/LastfmStatsService.swift `refreshNowPlayingCount` `reconcileNowPlayingCount` `nowPlayingCountPlayCountKey`；LyrimuseCore/Models/PlayCountRecency.swift `reconciledNowPlayingCount` |
| 本机推断的别名表（歌手 + 歌名，2026-09-04，取代两张手写表） | LyrimuseCore/Local/LocalArtistAliases.swift `derive` `artistKey` `canonicalArtistKey(_:table:)` `minSharedSongIDs` `minAliasLength` `ArtistIdentityCaches.load`；LyrimuseCore/Local/EnrichTitleAliases.swift `derive(_:artistKey:)`（E1 `songIDs`、E2 `lyricsBody` `bigramSimilarity` `lyricsTrusted` `e2DurationTolerance`）`coreTitle` `isHanTitled`；LyrimuseCore/Local/EnrichCacheReader.swift `computeLocalAliasTables` `localAliasTablesIfComputed`（`EnrichCacheEntry.durationSecs` / `resolvedDurationSecs` 同日起解码）；LyrimuseCore/Local/HanScript.swift `PlayCountFold.canonicalArtist`（查 `setLocalArtistAliases` 灌的表）`setLocalTitleAliases`（`familyKey` 查找顺序：本机表 → 发现表）；Settings/LastfmStatsService.swift `refreshLocalAliases` `applyLocalAliases` `flushLocalAliasStaleMarks`（调用点 `loadTitleForms` / `refreshLocalCoversIfCacheChanged`）、`mergedCountsVersion` 15；selftest 在 LastfmTests.swift「第三层歌名别名」「歌名别名 E2」「歌手写法归并的通用推断」 |
| 历史扫描世代号 / 热力图截断自愈（2026-09-05） | Settings/LastfmStatsService.swift `historySyncGeneration`（`resetAll` +1、`syncHistoryIfNeeded` 的 Task 每次 await 后比对）、`syncHistoryIfNeeded` 开头的 `dailyCounts` vs `overview.total` 70% 判据 |
| 「第 N 次听」合并明细弹框（2026-09-04） | lyrimuse/PlayCountBreakdownPopover.swift `PlayCountBadge` `PlayCountBreakdownPopover`（`reasonLabel` 原因标签文案）；Settings/PlayCountBreakdownLoader.swift `load` `loadOlder`；Settings/LastfmStatsService.swift `fetchTrackScrobbles`（`user.getTrackScrobbles` 解析，`refreshNowPlayingSpan` 同用）`playCountFamily`；LyrimuseCore/Local/PlayCountBreakdown.swift `PlayCountBreakdown` `ordinals` `albumGroups` `PlayCountBreakdownMath.build`；LyrimuseCore/Local/PlayCountFoldReason.swift `PlayCountFoldReason` `PlayCountFoldExplainer.reasons` `albumReason`（复用 `PlayCountFold.normalized`/`stripSpaces`，为此两者从 private 放开成模块内可见）；selftest 在 LastfmTests.swift「合并明细」 |
| Last.fm GET query 双重编码 | LyrimuseCore/Networking/LastfmQuery.swift `escape` `queryString`；Settings/LastfmStatsService.swift `request`；lyrimuse-collector/lastfmquery.go `lastfmGetQuery` `lastfmEscape`（Go 侧消费方是 `lastfmcollapse.go` 的 `probe`——2026-08-31 随折叠删除时一度无人调用，09-03 智能档加回后重新在服役；Swift 侧那份见 LastfmStatsService.request） |
| 桥接 / feed 拉取 | poller.go `bridge`（节奏 `lastfmFeedInterval`、门槛只看 Last.fm 凭据）`bridgeForwardingEnabled` `applyBridgeResult` `recordRecentMacListen`；lastfmfeed.go `writeLastfmRecentFeed` `shouldWriteLastfmFeed` `requestLastfmFeedRefresh`；lastfm.go `parseLastfmRecent` |
| App 读 feed / SWR 显示层 | Settings/LastfmStatsService.swift `pollFeedFile` `ingestFeed` `feedIsFresh` `refreshTodayCountIfNeeded` `mergeOverview` `stalePlayCountKeys` `prefetchNeighborPage` `persistedFetchedAtKeys` `composeExactPage` `storeFetchedPage` `recentPageCacheTotal`；LyrimuseCore/Local/LastfmRecentFeed.swift `decode` `isFresh` `todayCount` `totalPages`；LyrimuseCore/Local/LastfmPageComposer.swift `firstPosition` `compose`；selftest 在 lyrimuse-selftest/LastfmTests.swift（组 `lastfm`）；`playCountUnavailableDue` `markPlayCountUnavailable` `clearPlayCountUnavailable`（退避重探，日程在 LyrimuseCore/Local/PlayCountUnavailableBackoff.swift） |
| 歌手榜 CLI 只读缓存 / 直连兜底 | lyrimuse-collector/topartistscli.go `runTopArtistsCLI`、musicbrainz.go `artistCanonicalCacheOnly`；Settings/LastfmStatsService.swift `fetchChartDirect` `refreshMergedArtistChart` |
| 去重集合 | dedup.go `persistedTTLSet` |
| 收听日志/删除 | listenlog.go；deletelistencli.go |
| 回填 | backfill.go、backfillcli.go；App 侧 Settings/ScrobbleBackfillService.swift |
| 账号页 | lyrimuse/AccountLinkingTab.swift `AccountDestination` `destinationStatus` |
| 统计区 | lyrimuse/LastfmStatsSection.swift、Settings/LastfmStatsService.swift |
| 授权/状态 | Settings/LastfmAuthFlow.swift、Settings/LastfmMirrorStatus.swift、ListenBrainzTokenCheck.swift |

## 设计决策与已知坑

1. Last.fm error 4 必须两击坐实：服务端不稳时单次 4 是常态误报，一击熔断会让用户反复看到假红标（2026-08-17 修）。
2. 去重用「精确 uts 落盘集合 + TTL」而不是单调水位：手机端后台同步迟到/乱序是真实故障形态，水位会拒掉迟到的合法记录。
3. `lfmMirrored` 必须先写后发请求：否则 bridge 可能抢先把自己刚镜像的记录当 iPhone 收听转发，LB 里同一次收听两条。**代价是请求失败时标记已落盘、幂等守卫永久挡死这条**——这正是 2026-08-30 那次数据丢失的成因，兜底方案见第 4 节 `recordFailedMirror`（不撤销标记，改为落进 listens.jsonl 交给回填）。
   - **`lfmMirrored` 记的是「尝试过」，不是「确实到了」**——这个语义必须守住，它是"不可能双发"的全部依据。想改成"只在成功后才标记"的人请先看第 4 节：那样 bridge 会在标记落盘前抢跑，而失败留痕已经有更安全的解法。
4. bridge 只转发 ≤3 天的记录：7 天 TTL 集合被裁后老记录会周期性重灌；回填的历史条目也不该回流。
5. 回填失败整批隔离且不自动重试：Last.fm 对重复 scrobble 的判定不可靠，宁可让用户手动再来。
6. 收听日志与账号解耦（2026-08-13）：否则先用后连账号的用户历史永久丢失。
7. scrobble 时间戳 = 开播时刻，是 Last.fm 生态惯例；实时行的吸收去重靠它反推匹配。
8. LB 提交在后台跑 + submitting 标记：LB 慢时若同步等待会冻结 5s 轮询、拖垮歌词推送（poll() 异步化的由来）。
