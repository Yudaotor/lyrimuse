# 12. 账号连接与收听记录

> 最后核对：2026-08-22 · 基线：675f87a+工作树

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
  - **顺带修掉 `ArtistCredit.primary` 的一个真 bug**：`featMarkers` 里的 `ft ` 是**无左边界**的子串查找，于是蛋堡的罗马字名 `Soft Lipa` 被切成 `So`（「So|ft |Lipa」），歌手段落成 `so`、跟 `蛋堡` 在查族键上永远合不上——别名表加了也不命中。同类还有 `Daft Punk` / `Left Boy` / `Craft Spells` / `Soft Machine`。补上「marker 前面必须是空白或开括号」的守卫后，索引里被 `mergeArtist` 改写的歌手从 23 个降到 22 个（少的正是 Soft Lipa），蛋堡那 5 首随之合上。这跟 `isCatalogNoiseSubtitle` 里挡 `(Feathers)` 是同一类守卫——那边一开始就做了、这边漏了。
  - ⚠️⚠️ **「权威」只到规则条目层（T1/T2/T3 ＋ 附录 B）；它的 R1 实现与实际分桶结果是已知有害、Swift 刻意不对齐的部分。** 把这份脚本直接跑在这个用户自己的 2510 条写法上实测：它把 273 条写法塞进 11 个巨桶，最大一个 **137 条成员**——方大同几十首**不同的歌**（南音／公園／紅豆／三人遊／愛愛愛…）连同各自的 Live／`[Timeless Live 2009]` 全并成一首；第二大 70 条是陶喆同形态，第三大 20 条是周杰倫。根因是它的 R1 把 CJK 段和拉丁段**两段都当 union key 追加**，于是 `live` / `timelesslive2009` 成了歌手内的公共键，所有双语结构的曲目传递性地焊在一起——这直接违反它自己 docstring 里「刻意不做 Live」的声明，也说明「与用户逐对核定」那句只覆盖得到规则条目、覆盖不到分桶产物。Swift 的 R1 是「替换而非追加、且要求空格分词」，天生比它安全。**所以：照搬它的条目清单是对的；照搬它的 R1、或把 EDITION 的 contains 前视语义搬过来，是灾难**——后者会同时废掉「`(Live Bonus Track)` 挡得住」和「方括号残片被锚定判 false」这两道守卫。
  - **`(with X)` 的头词黑名单（`nonCreditHeadWords`）**：`feat./ft./featuring` 是纯署名标记、语法上后面只能跟表演者；`with` 是介词，后面还能跟乐队编制（`with strings` / `with orchestra`）、音频内容（`with intro` / `with backing vocals`），本身又能当歌名首词（`With or Without You`）——这是 with 与 feat 的**本质不对称**，守卫不能照搬。头词落在黑名单里就不折。这个用户索引里 19 条 `(with …)` 头词全是真人名，**这张表当下 0 命中、加它零行为变化**；加它的理由是折叠键会**永久**写进索引文件，而这个库里有 Horace Silver／Paul Desmond／Johnny Griffin／Nancy Wilson 这批爵士，「with strings」正是该品类的标准写法，哪天进库就是错合。代价：`with The Weeknd` 会被 `the` 漏掉（宁可漏合）。**别去动**「前缀后必须跟点/空格」那道守卫——那道是挡 `(Feathers)` 用的，`Without You` / `Withdrawal` / `Within Temptation` 也全靠它挡住（都有断言钉着）。也**不要**采纳「base 含汉字且 sub 全拉丁时 with 就不折」这种修法：那正好制造中文歌/英文歌待遇不同，还会把《不該 (with aMEI)》《等你下课 (with 杨瑞代)》这些旗舰案例全弄丢。
  - **破折号版本尾缀（参考实现 T2 的另一半，`Bad - 2012 Remaster` ＝ `Bad`）。** 索引里 216 条 ` - ` 尾缀，只有 **6 条**能过 `isCatalogNoiseSubtitle` 那道锚定判定，**4 例真并**（MJ Bad 15→16、Smooth Criminal、Man In The Mirror、The Way You Make Me Feel，都是并进已有的 `(2012 Remaster)` 族），其余 210 条（`- Live` / `- 鋼琴版` / `- Demo Version` / `- Original Karaoke` / `- Single Version`…）一条没动，0 族被拆。四道守卫都有断言压着：①破折号**两侧必须有空白**（`\s+[-–—]\s+`）——参考实现的 `\s*[-–]\s*` 会把 `Anti-Remastered` 切成 `Anti`，**刻意不照抄**；②副题必须过同一个锚定判定，不能无条件剥（不判定的话 216 条里 210 条会被吃掉，好 4 坏 210）；③要和括号剥法**交替**循环，否则 `X - 2012 Remaster (feat. Y)` 只掉一层；④剥完要 trim 尾部连接符（`X - (2012 Remaster)` 剥完剩 `X -`，不擦就落成 `x-`）。
  - **配套修了「第 N 次听」的减法键**（`LastfmStatsSection.swift` 的 `recentRows`）：`trackPlayCounts` 里存的是**整族合并总数**，而那里原来用 `playCountKey`（只 trim＋小写）去数「比这一行更新的同曲收听」——同一首歌的两种写法是两个不同的 `playCountKey`，跨写法的更新收听一次都减不掉，于是同页两行显示同一个 N。这正是 2026-08-21 报的「第 15 次听下面紧跟着第 21 次听」那个形状，而放宽折叠口径会**提高**它的触发概率（《一路向北》与《一路向北 (bonus track)》同页时两行都会是「第 16 次听」）。改成跟 `playCountSiblings` 查族**完全同一个键**：`PlayCountFold.key(artist: ArtistCredit.mergeArtist(row.artist), title: row.title)`；取数仍用 `playCountKey`（表就是按它存的）。
  - **两个版本闸门必须锁步，而且这次抬了两次**：`PlayCountFold.foldVersion` 3→4→5→6→**7**、`mergedCountsVersion` 7→8→9→10→**11**（同一天四批）。每一批都要再抬是因为 4/8 那版**已经装过机**、盘上有可能已被盖成 4/8——版本相等时 `loadTitleForms` 会直接采用盘上旧键、**永不迁移**，而 `scheduleTitleFormsSave` 又**无条件**写当前版本号，会把「旧键混新键」的文件盖上新版本戳，之后永远不再触发迁移。这是**静默**失效：不报错、不自愈，界面看着像没改而代码看着像改完了。两个数漏改任一个的后果：只改 `foldVersion` → 缓存里旧口径的数照端上桌，用户看到的数字一个都不变；只改 `mergedCountsVersion` → 每次冷启动重打整页 `getinfo`。
- **「第 N 次听」缓存作废的三条判据**（`applyRecent`）：①页内出现次数变多；②这首歌最新一条收听的时刻往前走了（2026-08-21 加，因为①在连播占满整页时会饱和）；③**页内自相矛盾**（2026-08-22 加）。①②都要跟**上一轮**比，而基线 `newestPlaySeen` 只在内存里、次数表 `trackPlayCounts` 却是**持久化**的——这个错配留下一个**稳态**盲区：App 重启、或统计页关着的那段时间之后基线被重设成「当下」，只要那首歌**不再被播一次**，盘上冻住的旧数字就永远等不到作废。用户 2026-08-22 实测：缓存冻在 3、Last.fm 真实 12，而那一页有 11 行《开不了口 (live)》，`recentRows` 的减法（`n = 总数 − 页内更新的同曲行数`，`n <= 0` 留空）把后 8 行全算成 ≤0，**整片空白且不自愈**。③不跟历史比、无状态：**页内（按折叠族数）已经看得见的收听次数比缓存总数还多 ⇒ 缓存必错**，重启后第一轮就生效。按族数是硬要求——次数表存的是整族合并总数、`recentRows` 的减法也按族数，三处必须同一把尺子（`PlayCountRecency.contradicted` / `contradictedPlayCountKeys`）。配套 `playCountFetchedAt` 做 5 分钟节流并**刻意不持久化**（跟 `newestPlaySeen` 相反的理由：这里要的就是「重启后为空」，好让旧数字第一轮被质疑一次；持久化它等于把盲区焊回去）；节流是必需的，Last.fm 的 `userplaycount` 本身滞后几分钟，不节流就是每轮刷新（`baselineTTL` 110s）白发一个请求、永不收敛。
  - 同一次改动把基线赋值从 `if lastAppliedRecentPage == recentPage` 块里**提到外面**并改成取 max：原来重启后第一轮整段被跳过、连基线都没记上，要到**第三轮**才真正开始作废（注释里写的是第一轮记基线，差了一轮）；取 max 是因为翻到历史页时那一页的「最新」是很老的时刻，直接覆盖会把基线**调低**、翻回第一页凭空多判一次过期。
- **Last.fm GET query 要双重编码 `+` 和 `%`**（2026-08-22 实测坐实）：`ws.audioscrobbler.com/2.0/` 的 **GET** 端点会对 query value **多解一次码**——先标准 percent-decode，再按 form-urlencoded 口径解一遍（那一遍把 `+` 当空格）。于是含加号的歌名走标准编码必然 404：`track=夜曲%2B窃爱 (Live)` → `error 6 Track not found`，`track=夜曲%252B窃爱 (Live)` → 命中 `userplaycount=2`。这是**端点级**行为，用真实存在的乐队 `+44`（733,475 听众）独立验证过（`%2B44` 同样 error 6）。入口是 `URLComponents.queryItems`——它按 `urlQueryAllowed` 编码，那套集合**放行 `+`**。修法：`LastfmQuery.escape` 先把 `%` 再把 `+` 各多编一层（顺序不能反），再按 RFC 3986 unreserved 严格转义；不含这两个字符的 value 编出来跟标准编码逐字节相同，对既有请求零影响。⚠️ **只有 GET 这样**：scrobble 走 POST form body（`lastfm.go` 的 `form.Encode()`）只解一遍，套上去反而会把字面 `%2B` 写进曲名——「记得对、却查不到」这个不对称正是本坑的表征。两侧各一份同规则实现（Swift `LyrimuseCore/Networking/LastfmQuery.swift`、Go `lastfmcollapse` 用的 `lastfmquery.go`），断言逐字节对齐，改一侧必须改另一侧。collector 那侧更要紧：`isCatalogued` 查不到就判「影子条目 → 折叠歌手串」，是个**不可逆的写侧动作**，查错了就是把正规合体署名折坏（现存 83 条判定缓存里没有含加号的，无既成损失）。
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
| 次数缓存作废三判据 | Settings/LastfmStatsService.swift `applyRecent` `contradictedPlayCountKeys` `newestPlaySeen` `playCountFetchedAt`；LyrimuseCore/Models/PlayCountRecency.swift `newest` `contradicted` |
| Last.fm GET query 双重编码 | LyrimuseCore/Networking/LastfmQuery.swift `escape` `queryString`；Settings/LastfmStatsService.swift `request`；lyrimuse-collector/lastfmquery.go `lastfmGetQuery` `lastfmEscape`（`lastfmcollapse.go` `isCatalogued` 调用） |
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
