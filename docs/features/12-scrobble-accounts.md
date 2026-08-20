# 12. 账号连接与收听记录

> 最后核对：2026-08-20 · 基线：2a2bf8b+工作树

## 定位

把「听过什么」如实记账并分发出去：本地收听日志（不依赖账号）、ListenBrainz 提交、Last.fm 镜像、iPhone 桥接、历史回填，以及设置里的「账号连接」页与 Last.fm 统计区。

## 入口与展示面

- 设置 → 账号：四个目的地卡片——**ListenBrainz**、**Last.fm**、**网页推送**（stateRelay）、**推送提醒**（Bark），各自的连接状态/配置入口（`AccountLinkingTab`，侧边栏行有状态点）。
- Last.fm 统计区（`LastfmStatsSection`）：正在记录的实时行、最近播放列表（带封面）、回填入口。

## 行为规格

### 1. 一次「算数的收听」（collector poller）

- 阈值 `listenThreshold = min(曲长/2, 240s)`：过半或满 4 分钟即计一次（`listenCapSecs = 240`）。
- **scrobble 时间戳 = 开播时刻**（不是达标时刻）。
- 单曲循环重启按新一次播放重新计（`loopRestart` 重锚，进度连续性判定）。
- 提交在后台 goroutine 跑（LB 慢时 single 最长 ~24s），`submitting/announcing` 标记防 5s 轮询重复触发。
- playing_now：换曲那条必须带歌词（LB 只认换曲那条），歌词还在解析时挂起 `pnPending` 最多 8s。
- 歌词随 listen 提交受 LB「单条 ≤10240 字节」硬上限约束，按 原文>翻译>罗马音>逐字 优先级装入。

### 2. 本地收听日志（listenlog.go，不依赖账号）

每次算数的收听追加一行到 `lyrimuse-listens.jsonl`——2026-08-13 补上：此前收听只流向「三个都要账号」的目的地，先用一周后连账号的用户那一周从没落过盘。这份日志是「本地已记录 N 首，连接后可补提交」清单的数据源。`collector delete-listen -uts <秒>` 删指定条目（必须由 collector 做——它在持续追加、格式语义都在它这边）。

### 3. ListenBrainz 提交（lb.go）

`lbClient.submit`（playing_now / single），additional_info 带 media_player（如实按播放器报）、source=mac（桥接 iPhone 覆盖为 iphone）、duration_ms、进度锚（自跟踪 Position+AnchorTS，不用 media-control 的 timestamp——连播时冻结、跨休眠会漂）。token 在设置里配置并校验（`ListenBrainzTokenCheck`）。未配 token 时 collector 纯本地运行（歌词/封面照常）。

### 4. Last.fm 镜像（lastfm.go + 开关 lastfmMirrorScrobble）

- 收听达标后异步镜像成 Last.fm scrobble（`mirrorScrobbleTracked`）；uts 先记入 `lfmMirrored` 集合**再**发请求，防 bridge 抢在标记前把它当 iPhone 记录转发回来。
- **熔断语义（`shouldDisable`）**：error 9/10/26（token 失效/API key 问题）一击致命——写 mirror 状态文件、UI 红感叹号；error 4（Authentication Failed）会被服务端不稳**误报**，改为**两击坐实**：首击只记嫌疑（30s 内的连击不算第二击，30 分钟窗口内再击才熔断），任何一次成功清零嫌疑。
- 状态文件由 App 侧 `LastfmMirrorStatusWatcher`（5s timer，值变才发布）盯着：熔断→红标即时出现；用户重连成功→红标自愈消失。
- 授权走 `LastfmAuthFlow`（浏览器 OAuth 拿 session key）。

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
- **「第 N 次听」写法孪生族合并**（2026-08-18，当天从纯繁简两次扩成写法族）：scrobble 是本机播放的原样镜像，同一首歌因**写法差异**在 Last.fm 记成多本账。实测两类分裂：①繁简（《我不是农人》11/《我不是農人》3）；②**括号风格/副题**（丁世光《一口(The Day You Left Me)》半角无空格 25 次/全角 2 次/纯名《一口》1 次——全专辑只有 E.T./Simon 这种纯 ASCII 歌名从不分裂，31/29 次反而显得"不均匀"，用户截图坐实）。autocorrect 只在实体不存在时改写，帮不上。取次数时的候选来自**写法索引**（2026-08-19 起，数据驱动）：从用户自己的全量播放历史建 `PlayCountFold.key`（NFKC 全半角＋ICU 繁简（麼/麽 同折）＋去空格小写＋双语拼接 R1 收敛；**刻意不折一般括号副题**——括号常携带 Live/Remix 版本信息;**唯一例外是目录学噪音**(2026-08-19,同日两波用户实测):①remaster 家族((Remastered)/(Remastered 2014)/(2014 Remaster)/(Remastered Version)——宇多田ヒカル《Automatic (Remastered 2014)》与《Automatic》两本账);②feat 客串署名家族((feat. X)/(feat X)/(featuring X)/(ft. X)——王力宏《盖世英雄 (feat. 欧阳靖 & 李岩)》第 2 次 vs《蓋世英雄》几十次,历史账全在无副题繁体形下)。两族都是同一份录音的目录学差异,折进本尊;完整命中才折,混着别的词((Live 2014 Remaster))不折,宁可漏合;"(Feathers)" 这类 feat 开头的普通词靠「前缀后必须跟点/空格+非空署名」挡住。判定在 `PlayCountVariants.isCatalogNoiseSubtitle`,枚举兜底也对**纯拉丁**歌名补「去副题」候选(此前纯拉丁完全不生成括号候选,正是漏网点;"纯英文 feat 副题各来源写法一致"的旧假设被②推翻)。折叠规则演进不用重建索引:`loadTitleForms` 加载时按当前规则从真实写法重算全部键,旧索引自动就地迁移）→ 真实写法族 的索引（`titleForms`），查次数按族查（去本尊、封顶 8）——新分裂形态一旦在历史出现即自动被族住，不用补表；userplaycount 只统计本用户 scrobble，历史里没有的写法必然是 0，索引按构造即完备。索引更新三通道：首次全量分页建（~110 页一次性，建成时整表作废重取）；每批已拉到的 scrobble 行（最近记录/热力图分页）零成本顺手收割；页面主刷新时从水位低频增量补漏（15 分钟节流）。索引未建成时退回猜枚举 `PlayCountVariants.siblings`（半角无空格＞全角＞半角带空格＞纯中文名＞繁简孪生，封顶 6，含字形变体表 `hanVariantPairs`：麼麽/裡裏/為爲/晚晩/線綫/眾衆——ICU s2t 永远生成不出的另一个繁体写法，曾是 v3 口径的主修法）——逐个 `track.getinfo` 求和，实时行与历史行（`resolvePlayCounts`）都走；表里存合并后总数，孪生行显示同一个数。三道守卫：①**身份集合去重**——每个变体响应里的规范 歌手|歌名 入集合，命中已计实体不再加（防 autocorrect 折回本尊、防两个变体折到同一第三实体）；②只为补封面的重查不碰次数表（`wantsCount`）；③快照 `mergedCountsVersion` 口径版本（当前 6＝索引口径＋目录学噪音折叠(remaster+feat);5＝仅 remaster;4＝仅索引口径）——旧口径缓存加载时整表作废重取。**合唱 credit 分裂也一并合并**（2026-08-20 新增的第三类分裂）：同一次收听会以两种歌手写法进 Last.fm——Mac 照抄 Apple Music 的逐曲 credit（`Daniel Caesar & Mustafa`），iPhone（→Last.fm→桥接）报的是主歌手（`Daniel Caesar`）。实测《Toronto 2014》08:58 从手机进来、11:11 从 Mac 进来，Last.fm 上成了两个实体，两行都显示「第 1 次听」。`titleForms` 按**完整歌手串**分桶，两边互相看不见，所以另建一份派生索引 `primaryCreditFamilies`：桶键的歌手换成 `ArtistCredit.mergeArtist`（合唱归第一位）再聚一遍，查孪生时用它——两个方向都能看见对方，两行显示同一个合计数。派生而不是改 `PlayCountFold.key` 的歌手口径：那个键是整本账的身份，改了要 foldVersion +1 并全量重折，而这里只需要「查孪生时多看一眼隔壁桶」。`ArtistCredit.primary` 的分隔符跟 collector 的 `isArtistCreditSep` 同一份，但 **`/` 单独处理**：网易云式 `陶喆/卢广仲` 要切，而 `K/DA`、`AC/DC` 的斜杠是名字自带的（判据是切出来的头部长度，含汉字 ≥2、纯拉丁 ≥3，判不准就不切）；`K/DA, Madison Beer & (G)I-DLE` 靠「逗号先命中」天然保住完整的 `K/DA`。刻意不做：David Tao/陶喆这类**罗马字↔中文**分裂仍分开计（沿用既有决策）；scrobble 源头归一也不做（会跟历史主流写法分裂出新实体，iPhone 侧 FastScrobbler 也绕不过）；Last.fm 侧批量改名真合并（B 案）已提出未拍板。
- 最近播放列表封面：Last.fm 图 → enrich 缓存 `coverURL(artist:title:album:)` 兜底（`imageURL: listCover`）。
- **兜底要认合唱 credit**（2026-08-20 用户报「最近记录里这几首没封面」）：缓存 key 用的是播放器的逐曲 credit（`英雄联盟/Sara Skinner`、`Edouard Brenneisen & 英雄联盟`），而 Last.fm 那一行记的是主歌手（`英雄联盟`、`Edouard Brenneisen`）。前两级（归一化 key 精确 / `looseKey`）都救不了——`looseKey` 只把分隔符变体折成 `&`，**不会把合唱者去掉**。所以第三级那张「忽略专辑」的索引里每条同时进两个键：歌手写法原样的精确键 + `ArtistCredit.mergeArtist` 归并后的别名键（别名只填精确键没占的位置，精确写法永远优先）；查询侧也把行的歌手归并一次，两个方向都能命中（`EnrichCacheReader.coverIndexByArtistTitle` / `coverURLString`）。实测那一屏 6 首缺封面的行（英雄联盟原声带）在这一级下全部命中，两首本来就有封面的对照行在这一级之前就已命中。索引改成按 key 排序建：原来靠 Dictionary 遍历顺序「先到先得」，同一份缓存两次启动可能给出不同的图。
- **同专辑封面共识**（2026-08-20）：行自带的 Last.fm 图**不再无条件优先**。同一首歌被两种歌手写法拆成两个 Last.fm 实体时，两边挂的图可能不是同一张——实测《Toronto 2014》的合唱实体挂的是单曲封面（深蓝纹章），同专辑其它行挂的是 NEVER ENOUGH 专辑封面，于是连播的列表里孤零零混进一张别的图。规则：按「合唱归第一位的歌手 + 专辑名」把当前这一页分组，**同组至少两行挂同一张图**才算共识，只有跟共识不一致的那一行被纠正（`ArtistCredit.albumConsensusCovers` + `coverURL(for:)`）。共识只看行自带的图，不掺本机缓存/getinfo 的兜底图（否则是拿两套来源互相投票）；一行一张各不相同（合辑/逐曲封面）时没有共识、照原样显示。跟 `recentAlbumCovers` 分工不同：那个补「压根没图」的行，这个纠正「挂错图」的行。
- **播放热力图**（2026-08-18）：档案卡（今天/近7天/总量）右上角日历按钮 → popover 弹 GitHub 贡献图风格年历（周列×周一至周日行，色阶=当年非零日的四分位数，GitHub 官方浅/深两套绿）。数据=`LastfmStatsService.dailyCounts`（本地时区天粒度桶）：`user.getRecentTracks` 全量分页聚合，首次同步整个历史（~110 页、页间 150ms），之后按 `dailySyncedThrough` 从「最后已同步天的零点」增量重拉（该天整天作废重算）；同步全程不动旧数据、全部成功才合并替换，失败只标记可重试。缓存 `lyrimuse-lastfm-daily-heatmap.json`（换账号不吃旧缓存）。

## 设置项

| 位置 | 项 | 影响 |
|---|---|---|
| 账号→ListenBrainz | token | LB 提交开/关与身份 |
| 账号→Last.fm | 连接/断开、镜像开关 | `lastfmMirrorScrobble`（features.json） |
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
- `lyrimuse-listens.jsonl`（收听日志，含隔离 "q" 行）；`forwarded`/`lfmMirrored` TTL 集合各一份落盘文件；Last.fm mirror 状态文件（红标依据）。

## 代码锚点

| 主题 | 位置 |
|---|---|
| 计次/提交调度 | lyrimuse-collector/poller.go `listenThreshold` `submitSingleAsync` `applySubmitOutcome` |
| LB 客户端 | lyrimuse-collector/lb.go `lbMeta` `submit` |
| Last.fm 镜像/熔断 | lyrimuse-collector/lastfm.go `shouldDisable` `mirrorAsync`；poller.go `mirrorScrobbleTracked` |
| 次数写法孪生合并 | LyrimuseCore/Local/HanScript.swift `HanScript` `PlayCountVariants` `PlayCountFold`；Settings/LastfmStatsService.swift `playCountSiblings` `ensureTitleFormsIndex` `harvestTitleForm` `userPlayCount` `mergedCountsVersion` |
| 合唱 credit 归并 / 同专辑封面共识 | LyrimuseCore/Models/ArtistCredit.swift `primary` `mergeArtist` `albumConsensusKey` `albumConsensusCovers`；Settings/LastfmStatsService.swift `primaryCreditFamilies` `rebuildPrimaryCreditFamilies` `albumConsensusCovers` `coverURL(for:)` |
| 封面兜底认合唱 credit | LyrimuseCore/Local/EnrichCacheReader.swift `coverIndexByArtistTitle` `coverURLString` |
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
3. `lfmMirrored` 必须先写后发请求：否则 bridge 可能抢先把自己刚镜像的记录当 iPhone 收听转发，LB 里同一次收听两条。
4. bridge 只转发 ≤3 天的记录：7 天 TTL 集合被裁后老记录会周期性重灌；回填的历史条目也不该回流。
5. 回填失败整批隔离且不自动重试：Last.fm 对重复 scrobble 的判定不可靠，宁可让用户手动再来。
6. 收听日志与账号解耦（2026-08-13）：否则先用后连账号的用户历史永久丢失。
7. scrobble 时间戳 = 开播时刻，是 Last.fm 生态惯例；实时行的吸收去重靠它反推匹配。
8. LB 提交在后台跑 + submitting 标记：LB 慢时若同步等待会冻结 5s 轮询、拖垮歌词推送（poll() 异步化的由来）。
