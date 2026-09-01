# 12. 账号连接与收听记录

> 最后核对：2026-09-01 · 基线：5d9031a+工作树

## 定位

把「听过什么」如实记账并分发出去：本地收听日志（只记还没进 Last.fm 的那些）、ListenBrainz 提交、Last.fm 镜像、iPhone 桥接、历史回填，以及设置里的「账号连接」页与 Last.fm 统计区。

## 入口与展示面

- 设置 → 账号：四个目的地卡片——**ListenBrainz**、**Last.fm**、**网页推送**（stateRelay）、**推送提醒**（Bark），各自的连接状态/配置入口（`AccountLinkingTab`，侧边栏行有状态点）。
- Last.fm 详情页（2026-08-23 改成分段 tab，理由跟「歌词显示」页一致——原来是连接卡+四张统计卡顺序平铺的一条长滚动，一次只关心其中一件事也要先滚过其它几件）：连接状态（Scrobble 开关、连接/断开、回填入口）**常驻在 tab 选择器外面**，不随下面的段切换；已连接时再展开「统计」（今天/近7天/总量数字 + 最近记录列表，合成一段）/「榜单」/「那年今日」/**「设置」**四个并列 tab（`AccountLinkingTab.LastfmSection` 选择器 + `LastfmStatsSection`，正在记录的实时行、最近播放列表带封面都在「统计」段里）；未连接时全部收起、只留一句预告文案。
  - **「设置」段 2026-09-01 加**（用户原话「这里单开一个设置tab页，装在这里面」）。装的是「跟 Last.fm 上送行为有关、但不是开关本身」的配置，卡头就叫 **`Scrobble`（中英同字）**。目前只有一项：「合唱歌曲的歌手」（见 §4）。
    - **为什么不继续摆在常驻的连接卡里**：那张卡的定位是「不看哪个 tab 都该一直看得见的东西」（Scrobble 开关、连接状态、待补清单），往里加设置项会把它撑成一张什么都装的卡；而这些设置恰恰是「想调的时候才去找」的类型。（当天先补在连接卡里、Scrobble 开关正下方，同日改成单开一段。）
    - **卡头中英同字 `Scrobble`** 的三条依据：①本仓的中文界面**本来就不翻译这个词**（「Scrobble 到 Last.fm」「Scrobble 已暂停」「总 scrobble」都是原样用）；②卡头在这个仓的惯例是名词短语而不是「X设置」（歌词来源／已信任的其它播放器／配置备份与搬家）；③这张卡已经在「设置」段里，标题再写一遍「设置」是重复。
    - ⚠️ **`LastfmStatsSection` 在「设置」段仍然常驻挂载**，只是它的 `Tab.settings` 分支画 `EmptyView()`；设置卡由 `AccountLinkingTab` 自己画。**别改成"这一段不挂载它"** —— 它的整套刷新逻辑建立在「从不因为切 tab 被卸载重建」上（见该类型头注），卸载一次就会把已拉到的统计丢掉、回来重拉一轮。职责上也对：那个 View 管统计数据，这些设置读 `FeatureSettingsStore`。
    - Scrobble 开关**关着**时这一项无从谈起（没有上送），那种情况显示一句说明而不是一个点了不影响任何事的控件。

## 行为规格

### 1. 一次「算数的收听」（collector poller）

- 阈值 `listenThreshold = min(曲长/2, 240s)`：过半或满 4 分钟即计一次（`listenCapSecs = 240`）。
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
  | `resolveScrobbleArtist`（写侧） | 决定**往 Last.fm 发什么字节** | ❌ **不可逆**，Last.fm 纠错库已冻结（2026-08-31 起是纯静态开关、默认不折） |
  | `topartists.go` 并查集（读侧） | 歌手榜分组 | ✅ 纯展示 |
  | Swift `ArtistCredit`（读侧） | 界面分组 + 「第 N 次听」写法族 | ✅ 纯展示 |
  | `digest.go`（读侧） | 日报/周报推送 —— **2026-08-30 之前完全不归并**，已接上榜单那套，见第 15 章 |
  - 写侧跟读侧**不是一类东西**：读侧算错了下次刷新就好，写侧算错了是往用户历史里写一条删不掉的记录。所以读侧可以激进、写侧必须保守。
  - **已知分歧，刻意保留**：Swift 侧认 `feat.` 家族（`feat./ft./featuring`，带词边界守卫），Go 写侧的 `artistCreditParts` **不认** —— 于是 `A feat. B` 在 `resolve` 第 3 行就 `len<2` 提前返回、整串原样提交。要不要给 Go 写侧补上 `feat.`：**不补**。理由：①实测这台机器 2384 条缓存里只有 1 例含 feat. 家族，且是 `張震嶽+Featuring：蔡健雅` 这种四套实现都处理不了的畸形写法；②写侧不可逆；③Last.fm 通常**本来就**把 `A feat. B` 当合法编目条目收录，强行折叠反而可能造出错误归属。收益近零、风险不可逆，不动。
- **合唱串：默认原样发整串，折叠是可选开关**（2026-08-31 改，`resolveScrobbleArtist`）。开关 `lastfm_scrobble_first_artist_only`，**默认 false**。
  - **删掉了原来的「联网条件式折叠」**（`lastfmcollapse.go` 整个文件已移除）。原实现是：查一次 Last.fm 目录，**查不到**这首歌挂在合唱串下才折成第一位。删它的理由跟「该不该折」无关：
    - **结果不可复现** —— 同一首歌，取决于 Last.fm 目录当下状态和网络通断，两次运行可能发出不同的艺人名，而 scrobble 落进 Last.fm 基本删不掉；
    - **把一次可恢复的匹配失败变成不可逆的数据丢失** —— 「目录里查不到」只说明编目暂时没收录，不说明署名是错的；限流/超时/服务抽风同样会走进「查不到」分支。
  - **默认 false（发整串）的依据**：ListenBrainz 文档明写合唱 credit 应当 *"include them all"*；Navidrome 同名开关 `Lastfm.ScrobbleFirstArtistOnly` 默认也是 false，其注释说明这是给 Last.fm API 缺陷的 workaround、不是正确性修复；折叠会丢信息且不可逆（`Khalil Fong & Fiona Sit` → `方大同`，薛凯琪没了），不折叠最坏只是 Last.fm 上多一个听众很少的合唱条目——**代价不对称**。
  - ⚠️ now-playing 与 scrobble 必须调**同一个**函数，否则会出现「now playing 显示 A、落库却是 A & B」的自相矛盾状态（这是原实现就守住的性质，重构里别丢）。回填侧走同一个函数，所以两条路结果必然一致。
  - 开关打开时走 `firstCreditedArtist`（纯字符串、不联网），`/` 仍与逗号顿号分档——`K/DA` 不会被劈成 `K`（有断言钉着；那次真实事故见下方「已知坑」）。
  - ⚠️ **2026-08-31 做完之后整整一天没有界面入口**（2026-09-01 补）。当时 collector 侧齐了（`resolveScrobbleArtist` + 开关 + `TestResolveScrobbleArtist` + `TestScrobbleFirstArtistOnlyFlagRoundTrip`），App 侧的 `FeatureSettingsStore.lastfmScrobbleFirstArtistOnly` 也齐了（编解码 + `@Published`），文档（本节 + 公开的 `docs/scrobbling.md`）也写了 —— **唯独没有任何 View 绑定它**，只能手改 `~/.config/lyrimuse/lyrimuse-features.json`。用户来问「我记得之前加了一个配置项…在哪里呢，我怎么找不到，是做了吗」，找不到是对的。
    - 现在的入口：**账号 → Last.fm →「设置」段 → `Scrobble` 卡 →「合唱歌曲的歌手」**，分段控件「全部／只发第一位」。
    - **这类漏洞从代码里看不出来**：`FeatureSettingsStore` 里属性齐齐整整，缺的是最后那一步 UI。同一次会话里还撞到第二例（第 11 章「更新时间」排序，注释写着"挂起等用户确认"然后就停在那了）。要查全得反过来对账：`FeatureSettingsStore` 的每个属性有没有任何 View 读它。
  - **界面文案两次收窄**（2026-09-01）：先按「只需要说明最终的效果是什么就好」去掉了推荐语，再把「而 scrobble 落进 Last.fm 之后基本删不掉」整句也去掉了（用户圈图指定）。现在只剩两个选项各自的效果。⚠️ 那半句的判断依据**没丢**、也不是被否掉了才删的：写侧不可逆这条论证仍然在 `resolveScrobbleArtist` 的头注、本节上面几条、以及 `docs/scrobbling.md` 里，改这行字的时候别把它当"已经不重要了"。

### 5. iPhone 桥接（poller bridge）

iPhone 端由 FastScrobbler 直接写 Last.fm；collector 周期拉 `lastfmRecent`（后台 goroutine，8s 超时），把**不是本机镜像产生的**新记录转发进 ListenBrainz（source=iphone）。防重三件套：
- `forwarded` / `lfmMirrored` 两个 **7 天 TTL 落盘集合**（`persistedTTLSet`，按精确 uts 去重，不用单调水位——手机后台同步会迟到乱序）；
- `recordRecentMacListen` 24h 内存缓冲做**近重复抑制**（Last.fm 会给曲名加校正后缀，精确 uts 匹配抓不到时按 artist+title+时间近邻兜底）；
- `bridgeMaxListenAge = 3 天`：更老的记录一律不转发（防 TTL 裁剪后周期性重灌、防回填的历史 scrobble 被当新收听）。

**广告不算收听**（isAdBreak，system.go）：Spotify 广告在 submitSingleAsync（scrobble/LB/本地日志的总漏斗）、announce（playing_now + Last.fm updateNowPlaying 镜像）、退出 flush、relay、enrich 搜歌词五处统一拦截。判据（2026-08-19 两轮加固）：字段启发式＝Spotify 且（album 空/artist 空/标题「—」）；但实测广告字段会**闪变**（Blinds.com：开播 album 空、几拍后补齐，announce 的门逐拍按当下字段重判，看走眼一拍就漏成 nowplaying），故改为**会话级粘性标记**（`playSession.isAd`）：开播判一次（字段启发式，未判中且是 Spotify 再向本尊要一次 AppleScript 权威判据——`spotify url` 对广告返回 `spotify:ad:…`，每换曲最多一次 osascript、失败静默退回启发式），同曲期间字段任一拍判中即棘轮置位、绝不回落；五个拦截点全部改判会话标记（叠加当拍字段兜底）。App 侧 `isCurrentTrackAdBreak`（灵动岛「广告中」/收起）同款重做：换曲定初值＋同曲棘轮＋异步 AppleScript 确认（回来核对还是同一首才采纳）。App 统计页另有显示端兜底：nowplaying 行 artist 空/标题「—」/**与本机正在播的广告同名**（带全字段的广告只有本机权威判据认得出）不展示（已发出的 nowplaying 收不回，过渡期不能原样端给用户）。⚠️ 排查教训（2026-08-19 第三轮）：用户两次截图的"广告正在播放行"其实都是**本机实时行**（LiveScrobbleRow 分支①）渲染的，不是 Last.fm 数据——空心圆＝服务器从未确认，collector 侧当时已拦住；实时行的语义是"正在被 Last.fm 记录的歌"，已补 `!isCurrentTrackAdBreak` 闸（「第 N 次听」取数被 `if let live` 连带守住）。已知误伤面：Spotify 无专辑名的播客/本地文件不上送（明确取舍）。

### 6. 历史回填（backfill.go，仅 CLI 触发）

`collector backfill-lastfm [-dry-run]`：把本地日志里未提交过的收听批量补到 Last.fm。批 50 条（官方上限）/批间隔 2s/回溯窗口 13 天（Last.fm ~两周上限留余量）/单批 30s。失败保守：超时/网络错误整批隔离（"q" 行）**绝不自动重试**；服务端 ignore 记回执不再重来；限流(29)/凭据失效即中止。刻意不做成后台常驻行为，只由「账号连接」页用户显式点击触发（`ScrobbleBackfillService`）。dry-run 未连账号也能跑。**完成后联动刷新**（2026-08-18，用户报"补提交后最近记录没刷新"）：`accepted > 0` 时自动 `refreshBaseline(force:)` 强刷最近记录/今天/近7天（不等 2 分钟 TTL），并 `rewindDailySyncForBackfill()` 把热力图增量水位拨回 14 天前——回填塞进过去 ≤13 天的记录，不拨水位会被增量同步永远漏掉；同步在飞时回拨挂起到收尾应用（`pendingDailyRewind`）。accepted=0 不发请求。

### 7. Last.fm 统计区（LastfmStatsSection）

- **实时行**（LiveScrobbleRow）：正在播放的歌 + 第 N 次听；快结束时 Last.fm 已落库、本地还在放——按进度锚反推开播时刻 ±120s 匹配「刚吸收的最近记录」（本机来源 only），把两行合并成一行、次数用已落库值顶替，避免同一首歌显示两条。
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
- **Last.fm GET query 要双重编码 `+` 和 `%`**（2026-08-22 实测坐实）：`ws.audioscrobbler.com/2.0/` 的 **GET** 端点会对 query value **多解一次码**——先标准 percent-decode，再按 form-urlencoded 口径解一遍（那一遍把 `+` 当空格）。于是含加号的歌名走标准编码必然 404：`track=夜曲%2B窃爱 (Live)` → `error 6 Track not found`，`track=夜曲%252B窃爱 (Live)` → 命中 `userplaycount=2`。这是**端点级**行为，用真实存在的乐队 `+44`（733,475 听众）独立验证过（`%2B44` 同样 error 6）。入口是 `URLComponents.queryItems`——它按 `urlQueryAllowed` 编码，那套集合**放行 `+`**。修法：`LastfmQuery.escape` 先把 `%` 再把 `+` 各多编一层（顺序不能反），再按 RFC 3986 unreserved 严格转义；不含这两个字符的 value 编出来跟标准编码逐字节相同，对既有请求零影响。⚠️ **只有 GET 这样**：scrobble 走 POST form body（`lastfm.go` 的 `form.Encode()`）只解一遍，套上去反而会把字面 `%2B` 写进曲名——「记得对、却查不到」这个不对称正是本坑的表征。两侧各一份同规则实现（Swift `LyrimuseCore/Networking/LastfmQuery.swift`、Go `lastfmquery.go`），断言逐字节对齐，改一侧必须改另一侧。collector 那侧更要紧：`isCatalogued` 查不到就判「影子条目 → 折叠歌手串」，是个**不可逆的写侧动作**，查错了就是把正规合体署名折坏（现存 83 条判定缓存里没有含加号的，无既成损失）。
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

#### 「那年今日」（`refreshOnThisDay` + `onThisDayCard`）

去年同一天（0–24 点）的收听；整天为空自动往前一年，**最多探三年**。6 小时 TTL，且必须跟
**日历天**一起判（`DailyRefreshGate`，TTL 或跨天取或）——只判 TTL 会把昨天那份一路带过零点，
而 App 是常驻 launchd 服务、跨零点不重启，`fetchedAt` 只活在进程内存里，所以这不是理论问题。

⚠️ **`fetchedAt["onthisday"]` 在发请求之前就写**，也就是**失败同样占住 6 小时**。这是刻意的
（否则一直失败会变成每次露面都重试，见 `DailyRefreshGate` 的参数注释），但它跟下面那个 UI
缺陷叠起来会变成一个很难查的现象。

- ❌ **已修（2026-09-01，用户报「那年今日有时候点进去是会空白」）：`onThisDay == nil` 把四种处境全渲染成一片空白。**
  - 原来整段是 `Group { if let o = stats.onThisDay { ...卡... } }`，**没有 else**。而 nil 有四种完全不同的成因：①还没取／正在取；②请求成功但那三年的今天确实都没听歌；③三年请求**全部失败**；④未连接。四种都是「什么都不画」，连一句「为什么」都没有。
  - **③ 最毒**：失败已经占住 6 小时 TTL，于是那个 2 分钟一轮的轮询（`LastfmStatsSection` 的 `.task`）会连着 6 小时**全部早退** —— 空白一直挂着，除非重启 App。
  - **这次实测的不是「没记录」**：直接打 Last.fm API 核过作者账号，1 年前 / 2 年前的今天 total=0，**3 年前 total=111**，循环本该在 `yearsAgo=3` 命中。也就是说用户看到的空白属于 ① 或 ③ —— 而它们原来跟 ② 长得一模一样，从界面上分不出来。
  - **修法**：加 `LastfmStatsService.OnThisDayOutcome`（`pending / loaded / empty / failed`），界面三态各有样子（正在查 ⟳ ／「过去三年的今天都没有收听记录」／「没能取到——Last.fm 没有响应」＋**「重试」**）。
  - **区分 `.empty` 和 `.failed` 的唯一依据是循环里的 `anyResponse`**：只要有一次响应回来过（哪怕 `total == 0`），就说明网络和账号都通、那几天确实没听歌；一次都没回来才是 failed。
  - ⚠️ **「重试」必须走 `refreshOnThisDay(force: true)`**（新加的参数，只给这一处用）。不绕过那道闸的话，这颗按钮会被 6 小时 TTL 直接早退、点了什么都不会发生。
  - ⚠️ **重取时不清 `onThisDay` 本身**。手上已有内容时（跨天/手动重试）清了会让那张卡先闪成空再回来；取到新的自然覆盖，取不到也该继续显示旧的那份。只把 `onThisDayOutcome` 打回 `.pending`。
  - **同类风险**：这一区还有别的 `if let` 条件视图（榜单/热力图）。判据是「nil 有没有多种成因」——只有一种（比如"这个功能没开"）时空着无妨，有多种就必须说清是哪一种。

## 设置项

| 位置 | 项 | 影响 |
|---|---|---|
| 账号→ListenBrainz | token | LB 提交开/关与身份 |
| 账号→Last.fm | 连接/断开、镜像开关 | `lastfmMirrorScrobble`（features.json） |
| 账号→Last.fm→设置 | 合唱歌曲的歌手（全部／只发第一位） | `lastfm_scrobble_first_artist_only`（features.json，默认关＝发整串）。界面 2026-09-01 才补，见 §4 |
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
- `lyrimuse-listens.jsonl`（收听日志，含隔离 "q" 行；已连 Last.fm 时只在**镜像失败**才写，见第 4 节 `recordFailedMirror`）；`forwarded`/`lfmMirrored` TTL 集合各一份落盘文件；Last.fm mirror 状态文件（红标依据）。

## 代码锚点

| 主题 | 位置 |
|---|---|
| 计次/提交调度 | lyrimuse-collector/poller.go `listenThreshold` `submitSingleAsync` `applySubmitOutcome` |
| 「那年今日」取数与四态 | Settings/LastfmStatsService.swift `refreshOnThisDay(force:)` `OnThisDayOutcome` · LyrimuseCore/Util/DailyRefreshGate.swift `needsRefresh` |
| 「那年今日」界面三态＋重试 | LastfmStatsSection.swift `onThisDayCard`（⚠️ 那个 `else` 分支是 2026-09-01 修「点进去空白」的本体，别当冗余删掉） |
| Last.fm「设置」段 | AccountLinkingTab.swift `LastfmSection.settings` `lastfmScrobbleSettingsCard` · LastfmStatsSection.swift `Tab.settings`（画空、保持挂载） |
| LB 客户端 | lyrimuse-collector/lb.go `lbMeta` `submit` `coolingDown` `noteOutcome` `lbCooldownSchedule` |
| Last.fm 镜像/熔断 | lyrimuse-collector/lastfm.go `shouldDisable` `mirrorAsync` `provablyNeverSent` `ignoredReason` `lastfmIgnoredError`；poller.go `mirrorScrobbleTracked` `recordFailedMirror` |
| 次数写法孪生合并 | LyrimuseCore/Local/HanScript.swift `HanScript` `PlayCountVariants` `PlayCountFold`（含歌手别名表 `romanizedArtistAliases`、静态歌名别名表 `titleAliasesByArtist`、动态发现表注入 `setDiscoveredTitleAliases` `canonicalArtistKey` `hasNoHanLikeChars`）；Settings/LastfmStatsService.swift `playCountSiblings` `syncHistoryIfNeeded`（写法索引全量/增量扫描入口，2026-08-25 起取代旧名 `ensureTitleFormsIndex`）`harvestTitleForm` `userPlayCount` `mergedCountsVersion` |
| 写法别名自动发现（动态，2026-08-29） | Settings/LastfmStatsService.swift `discoverTitleAliasesIfNeeded`（逐 canonicalArtist 分 han/non-han 组比对 duration，唯一匹配才采纳）`durationFor` `discoveredTitleAliases` `discoveredDurations` `discoveryAttemptedAt` `loadTitleAliasDiscovery` `scheduleTitleAliasDiscoverySave` |
| 合唱 credit 归并 / 同专辑封面共识 | LyrimuseCore/Models/ArtistCredit.swift `primary` `mergeArtist` `albumConsensusKey` `albumConsensusCovers`；Settings/LastfmStatsService.swift `primaryCreditFamilies` `rebuildPrimaryCreditFamilies` `albumConsensusCovers` `coverURL(for:)` |
| 封面兜底认合唱 credit | LyrimuseCore/Local/EnrichCacheReader.swift `coverIndexByArtistTitle` `coverURLString` |
| 合唱串折叠(写侧,不可逆) | lyrimuse-collector/lastfm.go `resolveScrobbleArtist`（开关 `lastfm_scrobble_first_artist_only`，默认 false）；match.go `firstCreditedArtist` `firstSlashCredit` `slashHeadPlausible` `isArtistCreditPrimarySep`；Swift 侧同规则在 LyrimuseCore/Models/ArtistCredit.swift `slashHeadIsPlausible` |
| 封面第⑤级(Apple Music 目录) | LyrimuseCore/Local/MusicCatalogSearch.swift `pickArtwork` `upscaleArtwork` `resolveArtwork` `ArtworkConfidence`；Settings/LastfmStatsService.swift `catalogCovers` `resolveCatalogCovers` `catalogCoverBatch` `coverURL(for:)` |
| 封面第①级纠正(本机专辑核实图) | LyrimuseCore/Local/EnrichCacheReader.swift `albumVerifiedCoverURL` `coverAlbumVerified`；Settings/LastfmStatsService.swift `localAlbumVerifiedCovers`（`refreshLocalCovers` 内填表、`coverURL(for:)` 第①级消费） |
| 次数缓存作废四判据 | Settings/LastfmStatsService.swift `applyRecent` `contradictedPlayCountKeys` `newestPlaySeen` `playCountFetchedAt`（判据③专用，不持久化）`staleByAgePlayCountKeys` `playCountVerifiedAt`（判据④专用，持久化，编码进 `StatsSnapshot`）`playCountStaleAfter`；LyrimuseCore/Models/PlayCountRecency.swift `newest` `contradicted` `stale` |
| nowPlayingCount 追赶 trackPlayCounts | Settings/LastfmStatsService.swift `refreshNowPlayingCount` `reconcileNowPlayingCount` `nowPlayingCountPlayCountKey`；LyrimuseCore/Models/PlayCountRecency.swift `reconciledNowPlayingCount` |
| Last.fm GET query 双重编码 | LyrimuseCore/Networking/LastfmQuery.swift `escape` `queryString`；Settings/LastfmStatsService.swift `request`；lyrimuse-collector/lastfmquery.go `lastfmGetQuery` `lastfmEscape`（⚠️ 2026-08-31 起 **Go 侧已无消费方** —— 唯一调用方 `lastfmcollapse.go` 随合唱串折叠改造删除；Swift 侧那份仍在服役，见 LastfmStatsService.request） |
| 桥接 | poller.go `bridge` `applyBridgeResult` `recordRecentMacListen` |
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
