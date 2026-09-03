# 09. 歌词解析决策（collector）

> 最后核对：2026-09-04 · 基线：0640c12+工作树

## 定位

collector 的核心：一首歌播放时，去八个歌词源（网易云/QQ/酷狗/Musixmatch/LRCLIB/AMLL/LyricFind/酷我，酷我 2026-08-31 起）检索候选、校验、打分、选出一份最终歌词（连同译文/罗马音/逐字时间轴），写进 enrich 缓存永久保留。App 的所有歌词展示面都消费这份结果。

## 入口与展示面

- **自动路径**：poller 换歌/循环重启时经 `trackEnrichment` 判缓存，未命中异步起 `resolveEnrichAsync`。用户无感，结果出现在所有歌词展示面。
- **手动路径**：「歌词管理」窗口有两颗，底层是同一个 `collector search-lyrics` CLI 子命令（复用自动解析同一套检索+打分，都不自动落盘）：
  - 「联网搜索候选歌词」→ 保留完整候选列表交用户挑；
  - 「重新自动匹配」（2026-08-21）→ 加 `-pick`，让 collector 顺便按 `pickLyricCandidate`（**自动解析那一套规则**，含「匹配算法：智能/顺序优先」的分支）选出冠军，App 侧直接采纳。冠军必须由 Go 这边算：顺序优先模式取的是「配置顺序里第一个 `Score>=0` 的源」而不是最高分，在 Swift 侧自己取 max(score) 就是第二份会漂的决策规则，漂的表现是「手动匹配完、下一拍自愈路径又给换回去」。App 侧拿到 `pick` 之后还要过 `LyricsRematchDecision.decide` 的五条分支（不可判 / 无候选 / 会丢逐字 / 完全没变 / 采纳）。⚠️ 其中「不可判」那条闸（`rescoreDecidable`）**对空歌词条目 2026-08-22 起放行** —— 它保护的是「手上这份」，手上什么都没有时它保护的是虚空，而不放行的后果是这颗按钮对「只有一个源收录了它」的歌**永远**不可能成功（见已知坑 16）。
  - ⚠️ **2026-08-21 修的口径 bug**：`search-lyrics` 一直漏了 `nativeLyricSource = playerNativeLyricSource(features.Player)`（main() 里有、CLI 那条提前分支跑不到），于是「与当前播放器同源 +250」在**所有手动搜索里恒为 0**。冠亚军分差中位只有 22 分、74% 的歌 ≤40 分，250 分足以翻盘 —— 在此之前「联网搜索候选歌词」展示的名次跟自动决策的名次对不上，用 QQ/网易云/酷狗听歌的用户尤其明显。
- **设置入口**：设置 → 歌词 → 获取段（歌词来源勾选、匹配算法、提前解析同专辑）。

## 行为规格

### 1. 触发时机

- 唯一常驻入口 `trackEnrichment(artist, title, album, bundleID, durationSecs)`；poller 每 5s 一轮，在换歌、单曲循环重启、首次解析挂起等待三处调用。空标题、广告（`isAdBreak`）直接不进链路。
- 缓存命中直接返回；未命中异步解析，同 key 有 inflight 去重 + 大小写/空格/繁简**/合 credit 分隔符**的宽松在途查重（防十几秒窗口内长出重复条目）。
- 解析完成经容量 1 的 `enrichNotify` channel 通知 poll 主循环立刻重推一轮。
- **专辑预取**（`features.AlbumPrefetch`）：换歌时（循环重启不触发）拿同专辑曲目列表逐首预解析——Apple Music 走 AppleScript 问本地资料库，其它播放器用网易云 AlbumID（要求专辑分 ≥100）；每张专辑最多 30 首、专辑级去重。预取用网易云版本时长做校验，真播时长差 >12% 会触发按真实时长重选。

### 2. 检索前处理

- 查询词统一**繁转简**（内嵌 OpenCC 词典 `toSimplifiedT2S`，词组优先最长匹配）；缓存 key 用**未转换**的原始标签。
- key = `cleanMediaTag(artist)|normEnrichTitle(title)|cleanMediaTag(album)`：清洗各类空格/零宽字符、循环剥结尾括号里的译名副标题（括号内容命中 34 词版本表则保留）；**不折**大小写/繁简——宽松归一只活在比对层（`loosenEnrichKey`），保证 Swift 侧能逐字复刻 key。比对层折三档：空格、繁简、**合 credit 分隔符**（`/ 、 & , ，` 全折成一个字符，分隔符集合复用 match.go 的 `isArtistCreditSep`；2026-08-20 加）。第三档修的是一类真实重复：同一次播放里两条路径对多歌手串的写法系统性不同——播放器（media-control）报 `VALORANT/Grabbitz/bbno$`，而**专辑预取**从 Apple Music 自己的曲目表（AppleScript `artist of t`）拿到的是 `VALORANT & Grabbitz & bbno$`，两条相隔 2~8 秒各建一条。预取本来有 `canonicalEnrichKey` + `looseInflightKey` 两道宽松查重，但它们都建立在 `loosenEnrichKey` 上，折不平分隔符就一起失效；预取的「跳过正在播的这首」也从两个字段逐字节相等改成按宽松键比（曲目表和播放器在括号/空格/繁简/分隔符上系统性不一致，逐字节比几乎必然漏）。存量用 `dedupe-entries -apply` 清了一次：875 → 862（13 组，删 30 个导出文件），存活条目的歌词内容零改动。
- 搜索词变体 `searchTitleVariants`：括号是「另一次录音」词（live/demo/remix 等 16 词）→ 先原样后裸标题；其它括号 → 先裸后原样。网易云不走这套（实测无收益），自建 4 条查询序列。
- **歌手别名重试**：五源全无可用候选时按 `retryArtistIdentities` 换名重查，三条依次试——①手工表 `artistAliasTable`；②MusicBrainz 中文别名（置信度 ≥90 且艺人属 CN/TW/HK/MO/SG 才采纳，限速 1.1s/次；含汉字的整串直接返回空，`containsHan` 守卫，所以「拉丁名 & 中文名」混合串靠不上这条）；③**MusicBrainz 主名**（`musicBrainzPrimaryArtistName`，2026-08-20 加）。第三条修的是「本名 ↔ 艺名」这一整类：前两条都是中文名取向，而 Apple Music 把《Hurry Up Tomorrow》标成 `Abel Tesfaye`（本名）、五个歌词源全按 `The Weeknd` 索引时它们一条都给不出——实测原样查 0 条候选、换名后五源全有（最高 1162）。用的是同一次 MB 搜索早就取回、原来被丢掉的首条 `name`；额外一道守卫：本地标签必须逐字（`normLoose`）命中该艺人的主名或任一别名（别名 type 不过滤，法定名/搜索提示同样算证据——这里问的是「MB 认不认识这个写法」，不是挑展示名），部分命中（如只写姓氏 `Tesfaye`）一律不认。结果只当检索身份用，不写 `canonical_artist`。**缓存只落盘「查到了」的条目**（自己一份 `artist-primary-cache.json`），查空的只留内存：MusicBrainz 限速按 IP、1 req/s，而 `musicbrainzThrottle` 是**进程内**节流——常驻 collector、手动搜索那个一次性 CLI、跑测试的进程各自计时，互不知情，撞上 503 就返回空。把空也永久写进文件（`artistAliasCache` 正是那么做的）会让一次偶发限速把这位歌手永久钉死在「没有别名」上。2026-08-20 实测坐实这个形态：同一首歌手动搜索第一遍 0 条、原样再搜一遍就出 5 条；落盘之后第三遍不再碰 MB，2 秒出结果。
- **Apple 目录锚点给的权威署名**（2026-08-22）：五源全无可用候选时，`scoredLyricCandidatesStreaming` 先试 `appleCatalogSearchIdentities`（**排在手工别名表/MusicBrainz 前面**——它是这首歌自己的元数据，不是「这位歌手一般叫什么」，证据强度更高），再走 `retryArtistIdentities`，两边按 `normLoose` 去重（`dedupeArtistIdentities`）免得同一个查询词白跑一轮五源抓取。给出的两个名字里 **`collectionArtistName`（专辑署名）排前面**：iTunes 只在它与曲目署名不同时才给这个字段，所以它非空本身就是「这首歌的署名跟专辑主人不是一个人」的信号——演唱会嘉宾 / 群星合辑 / 客串曲目，恰好是本地署名最容易跟各家歌词库对不上的那批，也恰好是手工表和 MusicBrainz 都够不到的一类。实测：「枫+退后+搁浅 (Live)」本地署名「南拳妈妈弹头」时网易云 4 条查询词一条都召回不到目标，换专辑署名「周杰伦」查、目标排第 1。只当**检索身份**用，绝不回写 `canonical_artist`／展示字段（同 `lyricPrimaryQueryArtist` 的纪律）。锚点本身的守卫/自校验/缓存见第 02 章「Apple 目录锚点」。⚠️ 索引由播放路径填，所以只对**本进程见过**的曲目有效；`search-lyrics` 那个一次性 CLI 读同一份磁盘缓存但索引是空的，手动搜索这一路暂时用不上它。
- **首歌手变体轮**（2026-08-20，「wherever u r」案）：可用候选的**启用源数** < min(2, 启用源总数) 且歌手串是多人合credit 时，用 `lyricPrimaryQueryArtist`（词级剥 feat./ft./featuring + `firstCreditedArtist`）截出首歌手再查一轮，仍不够再试首歌手的别名/MB 中文名（最多 3 轮）。变体轮结果**合并**进原串轮而非替换（`mergeLyricCandidateRounds`：按源去重、原串轮可用者优先、判废才顶替，合并后按**原串**统一重打分——变体串只作检索词和源内采纳闸，绝不进打分，防语言闸误杀）；变体轮的 `ne` 只许补封面/跳转链接（Album/AlbumID 跟着封面一起走，保 CoverAlbum 配对），**绝不采用其 Artist**——防 canonical_artist 把「A & B」缩窄成「A」（2026-07-10 回归形态）。触发判据数的是**启用**源（禁用源不算「信息够了」），单源配置封顶为 1、该源已成功时不多跑。别名重试触发时机的教训：网易云一条可用候选就能把整个重试短路，酷狗/QQ 的逐字候选永远没机会被看见——「有一条可用」不等于「信息够了」。

### 3. 八源并发收集（总截止 20 秒）

8 歌词源 + Apple 封面共 9 路 goroutine 并发（`fetchScoredLyricCandidatesStreaming`），到点未回的源本轮作废（由「升级重试」事后补救）。amll 那一路要等 netease/qq 把音乐 ID 搜出来（用两个带缓冲 channel 递过去），所以它总是最后回；lyricfind 是自己内部串行三跳（search→next→browse），单源耗时最长；酷我跟 netease/qq/kugou/lrclib/musixmatch 一样是独立检索（不等任何其它源的 ID），见下。

**源级熔断 / 退避（`sourcebreaker.go`，2026-09-02 加，见第 41 条）**：所有对外请求的统一出口 `doHTTPTracked` 按请求主机把结果归到源（`lyricSourceForHost`：163.com→netease、*.qq.com、*.kugou.com、lrclib.net、*.musixmatch.com、raw.githubusercontent.com→amll、music.youtube.com→lyricfind、*.kuwo.cn）。只统计两类失败——`Do` 本身返错（DNS / 连接 / TLS / 超时）与 5xx；**连续 2 次**才进入冷却，之后每再失败一次按 15s / 30s / 1m / 2m / 5m 升档；429 单独按 `Retry-After` 秒数冷却（没给 60s，封顶 5 分钟）；任何拿到响应且状态码 < 500 的请求立即清零。4xx 一律不算（网易云 body 405、Musixmatch 401 各自已处理）；用户取消（`context.Canceled`）不算。每轮起跑前 `planRound` 算一次谁在冷却，冷却中的源 goroutine 开头直接回空结果、不发请求；**启用的源全部在冷却时谁也不跳过**，照常跑一轮交给下面「至少 3 次全失败 = 断网」的判定。被跳过的源经 ctx 上的 `lyricSourceRound` 落到 `lyrics_sources_skipped` 与决策留痕的 `sources_skipped`；在「哪些源应答了」的口径里它就是没应答，所以 `needsLyricsRetry`（6h × 3）和 `rescoreDecidable` 原样接上。状态只在进程内存里，collector 重启归零；`search-lyrics` 一次性进程永远不会有冷却态。

**⚠️ `lyricSearchDeadline`（20s）只兜住这 9 路并发，不是整轮解析的总超时（2026-08-28 加真取消）**：`resolveTrackEnrichment` 在这 9 路之外还挂着 MusicBrainz 别名重试、Apple Music/iTunes 封面匹配、QQ 兜底封面这几步**顺序**网络请求，没有覆盖它们的总超时——某一步卡住时，「歌词管理」的占位行（第 11 章）会一直挂着，理论上无限等。用户反馈这个缺口后加的是**真取消**而不是"只在界面上隐藏这一行"：`context.Context` 从 `resolveTrackEnrichment` 一路穿透到全部十个网络来源（八个歌词源 + MusicBrainz + Apple/iTunes）各自的 leaf `http.NewRequestWithContext`，取消时这些请求真的会被 `net/http` 中断，不是隔着进程装样子。触发点是 App 侧「停止搜索」按钮写的一份文件信号，机制细节（`enrichCancelFuncs` 登记表、`enrichcancel.go` 的 1s 轮询、以及为什么取消判定必须排在网络健康度分类之前）见第 11 章「占位行『停止搜索』」。 `fetchScoredLyricCandidatesStreaming` 内部的 `collect` 循环额外加了一条 `case <-ctx.Done()`——取消发生时不用等 9 路里剩下的源真把（大概率已经是空的）结果送进 channel，直接收工。没有取消 UI 触达的路径（专辑预取、后台自愈重试、CLI 子命令）统一传 `context.Background()`，行为跟改动前逐字节一致。

| 源 | 专辑参与检索 | 逐字 | 译文 | 罗马音 | 封面 | 特殊点 |
|---|---|---|---|---|---|---|
| netease | 是（albumScore 择优） | YRC 原生 | 中文 tlyric | romalrc | 600px | 仿冒黑名单（周杰伦）只扣身份/封面、歌词照常参与（2026-08-22 改，原为整源跳过）；**带纯音乐标记**（顶层 `pureMusic` 或「纯音乐」占位正文，2026-08-20 加） |
| qq | 前 4 条补查专辑 | QRC→YRC | 中文 `trans`（GetPlayLyricInfo 同一响应，2026-09-02 起接回，见第 38 条） | `roma`（QRC 逐字压成逐行 LRC；假名占比闸与网易云同口径，见第 38 条） | **自带**（2026-08-31 起，见下） | QRC 3DES+zlib 解密；贪婪正则防双引号截断；译文/罗马音两轨同一把密钥，`//` 占位行与版权声明行 collector 侧剔除；QRC 首行 `[kana:]` 假名标注拼进整行歌词（第 39 条） |
| kugou | **不参与** | KRC→YRC（相对转绝对） | 中文（KRC `[language:]` type 1，2026-09-02 起，见第 40 条） | type 0 轨（日文歌为罗马音；韩文歌是中文谐音，按汉字占比挡掉） | **自带**（2026-08-31 起，见下） | 空格必须 %20；`[language:]` 行从逐字数据里摘除 |
| lrclib | 仅精确档（三级降级） | 无 | 无 | 无 | 无（结构性没有） | 带纯音乐（instrumental）标记 |
| amll | **不检索**（按 ID 直取） | TTML→YRC | 内嵌 `x-translation` | 无 | 无（结构性没有） | 见下 |
| musixmatch | 不参与 | richsync→YRC | **可选语言** | 无 | 500px | DoH 防 DNS 污染（并发拨号，2026-09-03）＋直连被打掉时经**系统代理**兜底（见第 42 条，全仓只有这个源走这条路）；匿名 token 双缓存；richsync 把**空格当独立计时条目**、掏空短词的读条时长（实测 "In" 23ms＋空格 165ms，悬浮窗观感"没有读条直接填满"）——`richsyncToYRC` 归并空白条目进前词（2026-08-19），存量缓存由启动迁移 `migrateYRCWhitespaceTokens`（yrcwhitespace.go，夹在 import 与 export 之间、幂等）原地清洗，无需重新联网解析 |
| lyricfind | 是（flexColumn 直接给） | **无** | 无 | 无 | 缩略图 URL | 见下 |
| kuwo | 是（自己重新打分，不信 Kuwo 排序） | **无** | 无 | 无 | **自带**（2026-08-31 起，见下） | 见下 |

所有源共用两道身份闸：`lyricTitleAccepted`（归一相等/剥括号相等/双语前缀，**绝不认任意子串包含**）+ 歌手闸。歌手闸 2026-08-20 起分两套：**歌词候选采纳**（kugou/qq strict 档/lrclib search/musixmatch/lyricfind）用 `lyricSourceArtistMatches` = `artistMatches` + 「两侧都是多人合credit 时段集有交集即过」——跨服务合唱署名会换分隔符、换合作者语言写法（「UMI、V」vs「UMI & 金泰亨」），要求整串对上等于要求两边曲库同一套署名习惯,实测酷狗服务端召回明明成功、正主却死在客户端闸上；交集档仍要求两侧各切出 ≥2 段（「周杰伦、」进不了）、段间字节相等（「周杰伦-」不认）。**身份判定/防仿冒**（netease 的 nameOnlyMatch、canonical 统一拼写、qqCoverFallback）仍用原 `artistMatches`（多人 credit 逐段精确相等 + 连续段拼回救 K/DA 类名字，拒绝「周杰伦、」式仿冒尾巴），刻意不放宽。两套闸门比较前都先过一遍 `toSimplified`（繁转简，跟 `normLoose` 同一份词典、同一个理由，2026-08-25 加）——`artistCreditParts` 内部下沉一次即两处共同受益，只转字符形式不剥标点，不影响上面的仿冒防线；起因是 lyricfind（经 YouTube Music 检索）给的艺人字段是繁体「周杰倫」，本地查询是简体「周杰伦」，折算前会把同一个人判成两个人、整条候选被拒收（「彩虹」案例）。`artistMatches` 2026-08-26 再补一档去括号别名兜底（`丁世光(Dean Ting)` 案，见下方第 18 条已知坑），跟 `lyricTitleAccepted` 早就有的「去括号再比」标题规则对齐，同样不影响仿冒防线。

**第三档（`lyricRecordingTriangleMatches`，2026-08-22 加，只挂在 kugou 一处）**：歌手闸不过时，再看「标题逐字同名 + 专辑对得上 + 时长紧密吻合」——三者同时成立就判定为同一次录音、放行歌词候选。四道判据都必须过：①`normLoose` 标题**逐字**相等（不接受`lyricTitleAccepted` 的剥括号档/双语档，那两档本身就是放宽，跟「歌手名不可信」叠加就是双重放宽）；②两边自报时长差 ≤**1%**（比打分层的 25% 严 25 倍——那一层量的是「LRC 末句 vs 曲长」、被前奏尾奏系统性带偏所以必须宽松，这里量的是两边各自自报的曲目时长，同一次录音跨平台只差在取整）；③`albumScore ≥ 200`，或 `≥ 100` 且候选专辑名归一后长度 ≥ 本地的 60%（本地专辑没标签一律不给）；④`versionTagsMismatch` 为假。**只放行歌词，绝不放行身份/封面**——沿用已知坑 12 那次确立的分层。`lyricrecordingtriangle_test.go` 里有一个扫 netease.go/qq.go 源码的守卫测试，防它被顺手推广到那两处的身份判定上。

**amll（amll-ttml-db，2026-08-23 加）** 跟其余五源是两种东西：

- **不搜索、按平台音乐 ID 直取** `raw.githubusercontent.com/amll-dev/amll-ttml-db/main/{ncm|qq}-lyrics/{id}.ttml`，404 即没有。ID 来自 netease 的 `SongID` 和 qq 的 `songmid`，所以它的身份确定性等同于那两个源；候选的 title/artist/album 直接沿用本地曲目信息，不会在那几项上被扣分，也不自报时长（该项不参与打分）。
- **格式本身能携带演唱者归属**：`<ttm:agent type="person|group" xml:id="v1">` + 每行 `ttm:agent="v1"`。落盘时转成行首前缀（person 按出现顺序编号成 `v1：`/`v2：`，group 一律 `合：`，**只有一位演唱者时不写前缀**），复用 `LyricDuet` 那条现成管线 —— `v1`/`v2` 收在 `anonymousMarkers` 里直通整份闸，因为 agent 是上游人工标注的权威信息，不该再拿为民间夹带设计的启发式去二次判它。
- **背景人声（`ttm:role="x-bg"`）整枝跳过**：它跟主歌词时间轴重叠，并进去会让逐字填色同一时刻两个词在亮，而我们还没有这个显示概念。
- **开关不在 `lyrics_sources` 里**，走独立的 `amll_lyrics`（三态：缺失=开、显式 false=关）。理由：`lyrics_sources` 非空即白名单，而老配置是在这个源存在之前写的，并进去等于对所有老用户默认关闭；无条件补齐又会让「用户主动取消勾选」永远生效不了。启用判定统一收进 `lyricSourceEnabled()`（此前散在六处、形式还不一致）。
- ⚠️ **词间空白必须按文档顺序读**（2026-08-24 修）：amll-ttml-db 里两种写法并存 ——`<span>What</span> <span>a</span> <span>ride</span>`（空格在 span **之间**，属于 `<p>` 自己的 chardata）和 `<span>How </span><span>it </span><span>goes</span>`（空格在 span **内部**）。初版用 Go 的声明式 tag（`Spans []ttmlSpan` + `,chardata`）解析，而 `encoding/xml` 会把一个元素的**全部**直接文本合并成一个字符串、顺序全丢，于是前一种写法拼成了 `Whataride`。用户报的症状是**「这些歌词没有翻译」**：粘住的假词翻译器原样返回，`translate.go` 那道「没翻动的行不写进译文」（`t == l.text`）把整行丢掉——《What a Day》78 行只出了 32 行译文。实测用户库 4 首 amll 来源的歌**全中**，每首 26~42 行粘连。修法是自己实现 `UnmarshalXML` 走 token 流（`decodeTTMLKids`），把词间空白挂到**前一个词**的尾巴上——这样 `words.joined()` 恒等于整行文本，Swift 侧 `plainText == words.joined()` 那道逐字守卫才过得去。⚠️ **别用「干脆用空格 join」偷懒**：同一行里可能既有不带空白的音节切分（`ka`+`raoke`）又有带空白的词边界，空格 join 会把音节也拆开（回归测试 `TestParseAMLLTTMLWordSpacing` 第 5 行专门钉这个）。中文逐字写法（`<span>没</span><span>有</span>`）span 之间本来就没有空白，不受影响。
- ⚠️ **覆盖率有限**：实测（2026-08-23）对 439 首曲库严格命中 **17 首（3.9%）**——口径是「歌名一字不差 + 只算 ncm/qq」（只有这两个平台的音乐 ID 我们拿得到）。**别用「去括号再比」的宽松口径估这个数**：那样会把《告白气球 (Live)》算成录音室版的命中，而按 ID 直取时 Live 版有自己的 songID、amll 里没有，实测 404。库的重心是游戏音乐 / V 家 / 欧美新流行（HOYO-MiX 841 条、Shawn Mendes & Camila Cabello 各 510、Taylor Swift 418、原子邦妮 395、GARNiDELiA 332），华语主要是周杰伦（176）和邓紫棋，跟华语老歌重合度低。接它的理由是命中那些歌的**歌词质量**（人工校对 + 逐字 + 内嵌译文），不是对唱兼容率 —— 15 首对唱歌它只有 3 首，而那 3 首现有解析已经能处理。

**lyricfind（检索走 YouTube Music，2026-08-25 加，`ytmusic.go`）**：

- **走 InnerTube**（YouTube 内部私有协议，无公开文档）三跳：`search`（songs 过滤器，避开现场/翻唱视频误配）→ `next`（拿这首歌"歌词" tab 的 browseId）→ `browse`（切到 `ANDROID_MUSIC` 客户端身份取带时间戳的逐行歌词——**只有切到这个身份才有时间戳**，`WEB_REMIX` 身份下同一个 browseId 只会回"Lyrics not available"）。三跳全程不需要登录/cookie，`X-Goog-Visitor-Id` 从首页 HTML 里正则抠、单飞锁保护（同一进程内只抓一次，理由跟下面 musixmatch token 的单飞同源），InnerTube 结构随时可能变——按 key 名递归找字段，不硬编码完整 JSON 路径。
- **只有逐行，没有逐字**（`hasWordTiming` 恒假）。YouTube Music 的歌词后端同时接了 Musixmatch 和 LyricFind 两家供应商（响应里 `sourceMessage` 标注是哪家）。
- ⚠️ **只接受真是 LyricFind 的候选**（2026-08-25 用户追问后收窄）：`sourceMessage` 不是 LyricFind 时（即 Musixmatch 换个管道重发）一律当"这一源没查到"，见 `ytmusicIsLyricFindSource`。理由两条：① 打分层的"跨源正文共识"（`contentConsensusPeers`）按**来源数**算独立印证——如果放行 Musixmatch-via-YouTube，它跟现有 `musixmatch` 源查到的内容大概率高度相似却不是两个独立信源，会把置信度算高，是虚假加分；② 接这一路的理由从一开始就是"LyricFind 是六源之外的真实增量数据"，实测（用户曲库 9 首抽样，过滤前的原始命中）8/9 在 YTM 上有歌词，但只有 2/9 是 LyricFind，其余 6/9 是重复的 Musixmatch——过滤掉之后源名才名副其实：`lyrics_sources`/展示名/内部 key 统一叫 **`lyricfind`** 不叫 `ytmusic`，因为查询机制是 YouTube Music、但对外交出的数据永远是 LyricFind 的（文件仍叫 `ytmusic.go`，描述的是检索机制，跟 `amllttml.go` 文件按格式命名、源叫 `amll` 是同一种分工）。
- ⚠️ **实测过、没能填补的空白**：拿现有六源全部落空的曲目测过，YTM 一个都没能补上（真没收录，或搜索匹配到完全不相关的曲目）——接这一路不是为了"六源都找不到时的最后一根救命稻草"，量出来那部分命中率是 0，价值就是那 2/9 的 LyricFind 命中。
- 开关走 `lyrics_sources` 白名单（跟 kugou/lrclib 等常规源同一条路，不是 amll 那种独立开关——它**参与搜索**，不是按 ID 直取，语义上就该跟常规源同一套）。

**kuwo（酷我音乐，2026-08-31 加，`kuwo.go`）**：

- 接口契约从公开的第三方开源实现逆向：`search.kuwo.cn/r.s`（`Referer: https://www.kuwo.cn/`）搜歌，`kuwo.cn/openapi/v1/www/lyric/getlyric?musicId=<id>` 取歌词——**两个接口的 `Referer` 不一样**（后者是 `https://kuwo.cn/`，没有 `www.`），传错会被拒。musicId 从搜索结果的 `MUSICRID`（形如 `MUSIC_493465004`）切最后一段下划线后的数字取。
- ⚠️ **Kuwo 自己的搜索排序完全不可信，接入时已经补了自己的重新打分**：接入调研阶段拿真实曲库抽样（周杰伦《稻香》、BEYOND《海阔天空》、邓紫棋《光年之外》等）实测——原版录音室版本**常年不进 `rn=30` 的搜索结果**，前排清一色是 DJ 改编/伴奏/翻唱/演唱会现场/纯音乐这类版本，怀疑是大牌歌手的原版母带在 Kuwo 免登录搜索接口上本身就没有收录（大概率是版权限制，不是排序 bug——拉大 `rn` 到 30 依旧一个没有）。修法：搜完不信 Kuwo 的顺序，套用跟别的源同一套身份闸（`lyricTitleAccepted` + `lyricSourceArtistMatches` + `versionTagsMismatch`）自己重新打分（`kuwoCandidateScore`，时长再加一档 ±25% 容差分），取重新排序后的前 5 名**并发**去取歌词，逐个校验（歌词非空 + `isTimedLRC` 通过）后按分数从高到低取第一个能用的——宁可全部落空也不用一份版本不对的候选。
- **只有逐行，没有逐字/译文/罗马音**——跟 lyricfind 同一个形状。覆盖率同 amll/lyricfind 一档：因为版权限制的存在，对头部大牌歌手的热门曲目命中率结构性偏低，接入价值更多在非头部/长尾曲目，是"锦上添花"的兜底，不是主力源。
- 开关走 `lyrics_sources` 白名单（跟 lyricfind 同一条路，同时保留独立迁移标记 `kuwo_lyrics`，见「已知坑」amll/lyricfind 那两条同款迁移逻辑）。

### 4. 资格守卫

- **一票否决**（判 -1，两种挑选模式都跳过）：
  - `rejectNotTimed`：不是真 LRC（带戳行 <3 或不过半，或串长 ≥20000）；
  - `rejectWrongLanguage`：本地歌手+歌名均无汉字但歌词汉字占比 >0.5；
  - `rejectCreditOnly`：整份只有署名行（关键词正则 + 「≤8 汉字+冒号」结构兜底，去掉后正文 <3 行），或含「纯音乐」占位；
  - `rejectNoLastTimestamp`：提不出末句时间戳。
- **逐字覆盖率守卫** `usableWordTiming`：YRC 末时刻 < LRC 末时刻 ×0.5 就当没有逐字（防 QQ 截断残片骗 +400 又被「已有逐字不重试」钉死；阈值实测依据：残片覆盖 19.1%、正常最低 85.4%）。

### 5. 打分（`lyricsScoringVersion = 11`）

| 项 | 分值 | 条件 |
|---|---|---|
| 时长吻合 | +100~+300 连续衰减 | 偏差 ≤25% 且末句不超曲长 5s |
| 末句超曲长 5s | **-700** | 物理矛盾档，不吃印证豁免 |
| 跨源末尾印证 | +100 | ±5s，且仅当批内无人时长吻合 |
| 时长明显不符 | -500 | 原一票否决，实测误杀 5:1 后改重扣。量的是「LRC 末句 vs 曲长」这个**代理** |
| **源自报曲长不符** | **-400** | v4 新增。量的是两个**曲目时长**的直接比对（`sourceReportedDurationSecs` vs 本地），偏差 >12%（分母取较大者，复用 `wrongDuration` 的口径）。**只扣不加**，源没自报（0）不扣 |
| 逐字时间轴 | **+400** | 过覆盖率守卫 |
| **逐字加分撤销** | **-与上面那条 +400 相等** | v5 新增（`wordTimingOverride`，见下面「设计决策与已知坑」20）。全部候选打完分、排序前的收尾一步：逐字加分是唯一让冠军赢的理由、且另一个真实候选的标题吻合分更高时，把这份 +400 整段撤销。不是下调 +400 本身，是窄口子只在这个具体组合下触发 |
| 与当前播放器同源 | +250 | 放 QQ 音乐偏向 QQ 词（理由是时间轴对齐，非内容质量）。⚠️ 判据是**这一刻在放的那个播放器**（按 bundle id），不是设置里勾了哪些——2026-09-02 修，见下面「设计决策与已知坑」那条 |
| 行数 | +1/行，封顶 200 | |
| 版本限定词错配 | -600 | 歌名∪专辑名比对；词表 2026-08-22 补了 `club mix`/`radio mix`/`house mix`/`dub mix`/`dance mix`/`vocal mix`/`club edit`。v8（2026-09-01）加一道窄豁免 `sameRecordingDespiteVersionTags`（时长 ≤1% + 专辑亲和 + 候选不缺本地限定词 + 多出的词全在 acoustic 家族白名单 → 是同一次录音的命名差异，不扣），见「设计决策与已知坑」33。v9（2026-09-01）起限定词集合来自 `recordingVersionTags`：专辑名 stripParens 后含中文现场标记（演唱会/现场/音乐会）视同声明 live，双向对称；豁免的第③门本地侧用括号级集合（截短拼法防误伤）——见第 36 条 |
| **另一场演出**（`liveAlbumConflict`） | **-600** | v7 新增（2026-09-01，见「设计决策与已知坑」31）。versionTagsMismatch 在「两边都是 Live」时限定词集合相等、必然静默，这一档接住它够不到的那半边：本地**专辑名自己**带 live 标记 + 候选也是现场录音 + 两边专辑名剥掉歌手名和 live/演唱会类通用词后各自还有身份词且**完全不相交** → 判为两场不同命名的演出。四道门缺一不可（防误伤的实测依据见第 31 条） |
| 专辑亲和 | +150/+75/+40 | 只加不减（专辑对不上是零证据非负证据） |
| 标题吻合梯度 | +120/+60/+30 | 精确/剥括号带版本词/双语 |
| 跨源正文共识 | +250（2 家）/+150（1 家） | 3-gram Jaccard ≥0.55、正文 ≥30 rune；时长不吻合/overshoot 者共识清零。⚠️ 归一时**演唱者标签行只剥前缀、保留正文**（见 `lyricspeaker.go`）——2026-08-23 之前是整行丢掉，导致「每句都带『男：』」的候选被摘成残缺正文、跟不带标记的同一首歌对不上，拿不到这 150~250 分；而冠亚军分差中位只有 22 分，等于在选源层系统性淘汰带对唱标注的版本 |
| 可用译文 / 罗马音 | +50 / +30 | 语言、时间轴、覆盖率均有资格闸 |

负分统一夹到 1（重扣=「差」，负分只留给否决）。**没有静态来源加分**——2026-08-09 被 250 首消融实验删除（改变 69 首冠军、0 次变对/6 次变错，删掉后一致性 93%→96%）。

### 6. 挑选（设置里的「匹配算法」，`pickLyricCandidate`）

- **智能**（默认）：只看启用的源，取最高分；平手按稳定排序=候选构造顺序（netease→qq→kugou→musixmatch→lrclib）决胜。
- **顺序优先**：按用户排序找第一个「有 Score≥0 候选」的源，**完全不比分数**。
- **被禁用的源照样会查**（五路无条件并发），过滤只发生在挑选步——切换设置不用重搜。
- 歌词/译文/罗马音/逐字**整体跟着冠军走**，不存在跨源拼装。唯一的独立补充是机翻译文（见第 10 章）。
- 全部源空：不写歌词但照记决策；**纯音乐标记**透传给 UI；条目所有字段全空则整条不落盘（防断网钉死失败）。
- **纯音乐标记的三个来源**（2026-08-20 从只有 lrclib 扩成两个，2026-08-22 加上 QQ）：①lrclib 响应里的结构化 `instrumental`；②网易云歌词接口的顶层 `pureMusic`，或正文只有「纯音乐」占位 + 署名行（`isInstrumentalPlaceholderLyric`，占位文案复用 `neteaseInstrumentalPlaceholderMarker`）；③**QQ 的占位正文**——它对纯音乐曲目回的是单行 `[00:00:00]此歌曲为没有填词的纯音乐，请您欣赏`，语义上是三者里最硬的**明文断言**，所以 `scoreAndSort` 里排在网易云之前（判定复用同一个 `isInstrumentalPlaceholderLyric`，它对这句话逐字适用——那个函数 2026-08-22 从 `isNeteasePureMusicLyric` 改名成来源中立就是为此）。两者都以 `Score:-1 / Instrumental:true` 的搭车标记进 results，不参与打分/挑选；`mergeLyricCandidateRounds` 保留标记的条件按**标记自己的源**判（原来写死 lrclib）。起因是用户报「一堆条目显示无歌词、其实都是纯音乐」（LoL 原声带 12 首）：lrclib 压根没有这批曲目（五源全空），而网易云匹配上了歌、歌词接口明确回 `pureMusic=true`，但那个字段**不在解码结构体里**、占位正文又过不了 `isTimedLRC` 的三行门槛，于是结论在解码那一步就丢了。
- ⚠️ 同一次修复补了第三个漏点：`retryLyricsUpgrade`（升级重试 / 补空重试）**从来不写** `instrumental`——只有 first-resolve 那条路径写。于是「当初那轮没有这个信号、后来有了」的条目永远拿不到标记，还要每 24 小时（退避后翻倍）白搜一轮。现在两条路径都写，标记落地后 `needsLyricsFirstFill` 直接 return，重搜也省了。
- 存量条目补标记用 `collector recheck-instrumental [-apply] "歌手|歌名|专辑" ...`：只写 `instrumental` 一个字段（这轮真搜到歌词就交回补空路径，一次性命令不碰歌词），dry-run 默认、`-apply` 要求常驻实例已停。

### 7. 封面选源（跟歌词同一趟解析，但独立决策）

固定顺序 **网易云 → Apple Music → QQ**，先拿到就用。这个顺序管的是**可加载性**：网易云图床（`p*.music.126.net`）国内加载得出来，Apple 的 mzstatic 国内已无 CDN 节点。`cover_source` 如实记来源；`cover_album`（2026-08-20 加）记这张封面在来源平台上属于哪张专辑。

**一道专辑感知的例外**（`preferAppleCoverOverNetease`）：网易云那张明确属于**另一次发行**（`albumScore=0`）、而 Apple 那张对得上正在播的这张专辑（`albumScore>0`）时，改用 Apple 的。只换封面，网易云的歌词/译文/罗马音不动——那些跟「哪张发行」无关。本地没有专辑标签时这条例外一律不生效（对不对版无从判断）。

为什么需要这道例外：顺序不管对不对版，而**专辑本身没上网易云、只有先行单曲**时两者会打架——`pick()` 那条「唯一精确同名候选、专辑名对不上也认」的规则（刻意保留）会命中单曲版，于是同一张专辑的曲目一半拿单曲封面、一半退到 Apple 拿专辑封面。实测见「设计决策与已知坑」11。

存量条目（没有 `cover_album` 的老记录）判不出对不对版，靠外围补全补查一次，见下一节。

### 8. 决策留痕

每轮评估（first-resolve / upgrade / rescore）固化成 `lyrics_decision`：查询词、时长、哪些源应答、全部候选的分数明细与被拒原因、胜者、是否真的生效（Applied）、**以及胜者是不是「标题反查改写标题之后」那一轮搜出来的**（`retry_method` / `corrected_title`，2026-09-02 加，见下面「设计决策与已知坑」里那条打上花火案）。三条铁律：只存元数据不存正文；**只写不读**（不许反过来影响决策）；手改条目不覆盖记录。另有默认关闭的 NDJSON 流水账（`lyrics_decision_trace`，2MB 轮转）。

**两槽存档**（2026-08-22）：`lyrics_decision` 是「最近一次评估」，可能维持原状、甚至输入本身是脏的；`lyrics_decision_applied` 是「当前歌词的出处」——最近一次「胜者内容成为（或确认仍是）当前歌词」的评估（first-resolve 选中 / upgrade 换上或胜者=现存 / rescore 可判有胜者 / manual-rematch 采纳时由 App 侧同写）。分槽的起因：一轮被换曲窗口串扰时长（见下面「升级重试」的去抖）的 upgrade 评估把 first-resolve 的存档盖掉，「解析决策」展示的记录跟生效歌词对不上号，用户拿它跟手动重搜一比更懵。老条目没有第二槽，App 侧按「最近评估恰好 Applied 即出处」退化。

### 9. 事后自愈（缓存命中时一次只派一路，固定优先级）

1. **外围补全**：封面主色/平台链接/canonical_artist 缺失，**或封面属于哪张专辑对不上/不详**（`coverNeedsAlbumCheck`，只查 `cover_source=netease` 那档）才补；10 分钟节流、上限 5 次；不碰歌词。真要换封面还得过 `coverSwapAllowed`——跨源替换要求「这一轮网易云真的应答过 + 新封面对得上专辑」，否则网易云一次限流（HTTP 200 + body code 405）就能把一张对版、国内加载得出来的封面换成 mzstatic 的。
2. **rescore**：打分规则版本落后时按新规则重选（**不比大小**）；1 小时节流、上限 3 次；要求当前歌词的源本轮也应答了才够格推翻。
3. **升级重试**（`needsLyricsRetry`）：⚠️ **2026-09-03 起这条和下面的重打分一起受设置里「自动跟进算法升级」管**（`features.LyricsAutoUpgrade`，默认开=现状；关掉之后已经选定的歌词不再被后台换掉）。闸门做成这两个纯函数的**入参**（`autoUpgrade bool`）而不是在函数里读包级 `features`，理由跟 `pinned` 那个参数一样：这两个判定要能被单测直接钉住（`lyricsautoupgrade_test.go`）。**只挡"换掉已有歌词"**——首次填充（`needsLyricsFirstFill`）、封面/译文回填、用户手动重搜都不受它管，那几条不属于"把用户已经拿到的那份换掉"。当初有启用的源没赶上 20s 截止才重搜；6 小时节流、上限 3 次；新分**严格更高**才替换（跨打分版本用 `lyricsUpgradeBaseline` 换同尺度基准）。已有逐字不重试，两个例外可翻盘：「同源候选当初落选」（换播放器场景）与「时长差 >12%」。⚠️ **Apple Music 现在多了一道上游防线**：Apple 目录锚点成立时，时长直接用 Apple 目录的权威值，脏快照在进入这条链路之前就被顶掉了（见第 02 章）。锚点对用户自己导入的曲库和别的播放器无效，所以下面这道去抖仍是必需的。⚠️ 时长差这条的原始观察值必须先过 `observeWrongDuration` 的 **30 秒同值去抖**（2026-08-22）：换曲/预载窗口里 media-control 会把**下一首**的时长和当前曲目的标题拼进同一份快照（实锤：「开不了口 (Live)」272.973s 开播 6 秒后，relay 快照携带同专辑下一首「床边故事 (Live)」的 220.239s，逐位一致），一次性脏观察直接当真会白烧一轮重试、所有候选按错误时长吃 -700、还把决策记录盖掉。同一脏值（±1s）稳定满 30 秒才触发；时长又对上即清零；观察断流超 5 分钟按陈旧重计（防"切出侧脏值残留 + 几天后重放同曲第一口又是脏值"拿旧 firstSeen 一步凑满窗口；上限须盖过稳定播放期的正常喂食间隔——relay 心跳/LB 提交都是 ≤4 分钟一次）；确认放行同时清记录（下一轮重新攒，不会连发烧光预算）。
4. **机翻补译文**：见第 10 章。

`ManualLyrics`（用户手改）对一切自动路径一票否决。**已校准**（用户手动调过这首歌的歌词时间轴偏移）同样一票否决 rescore 与升级重试——名单在 `~/.config/lyrimuse/lyrimuse-lyrics-pins.json`，由 App 写、`lyricspins.go` 按 mtime 重读（不需要重启 collector）。理由：校正值绑在歌词内容指纹上，换一份内容就等于让它静默作废（详见第 8 章「已校准即锁定歌词源」）。

## 设置项

| 设置位置 | 项 | 影响 |
|---|---|---|
| 歌词→获取 | 歌词来源（五源勾选） | 只影响挑选/手动候选过滤，不影响抓取；至少保留一个 |
| 歌词→获取 | 匹配算法（智能/顺序优先+排序） | `pickLyricCandidate` 分支 |
| 歌词→获取 | 提前解析同专辑其它曲目 | albumPrefetch 开关 |
| 歌词→译文 | 译文语言 | musixmatch 检索译文的目标语言（进其缓存 key） |

改这些走 `FeatureSettingsStore` → 写 `features.json` + kickstart collector（见第 14 章）。

## 与其它功能的交互

- **App 歌词消费链**（第 08 章）：`EnrichCacheReader` 每次直读磁盘缓存文件，所以每条自愈路径必须真正落盘。
- **歌词管理**（第 11 章）：手动编辑写 `manual_lyrics` 标记 → 冻结一切自动重搜；重搜候选弹窗展示 `score_terms` 分数明细与被拒原因。
- **封面链路**（第 03 章）：解析顺带解析 `cover_url`/主色，是高清封面替代的数据源。
- **译文/罗马音**（第 10 章）：机翻兜底只补译文、永不顶替可用社区译文。
- **lyrics/ 文件夹**（第 11 章）：歌词六字段以导出文件为权威源，启动时文件覆盖 JSON。导出走同目录临时文件 + 改名的原子写（`writeLyricsFileAtomic`，2026-09-02 起，见第 11 章设计决策第 18 条）——导入只校验头部、正文不校验，半截文件会以「用户文件」身份顶掉缓存里完整的歌词，所以写入必须原子。

## 数据与文件

- `~/.config/lyrimuse/lyrimuse-enrich-cache.json`：主缓存，无 TTL 永久保留，原子写（temp+rename）+ 互斥锁；损坏文件挪 `.corrupt` 旁路。
- `~/.config/lyrimuse/lyrimuse-lyrics-decision-trace.ndjson`：可选流水账。
- `~/.config/lyrimuse/lyrimuse-artist-primary-cache.json`：MB 主名（本名 ↔ 艺名）缓存，只存查到的条目，见「歌手别名重试」。
- 各源自有内存/磁盘缓存（网易云 30 天/10 分钟分级、musixmatch token 9 分钟等）。⚠️ **musixmatch 换 token 必须单飞**（2026-08-24 修）：批量解析（相册预取/批量导入一次触发十几首歌并发解析）时，原来每个 goroutine 独立判定「没有可用 token」就各自发一次 `token.get`，而 apic 那台机器实测把除第一个之外的并发请求全按反爬拒掉（401 hint=captcha），被拒的按官方样例退避 10 秒重试一次——但 20 秒的搜索预算扛不住 N 个 goroutine 各跑一遍「发请求→等 10 秒→重试」。实测（用户库）批量解析场景 musixmatch 交出候选的比例只有约 20%，单首/大规模顺序扫描能到 65%~90%，量出来的正是这个：一次 16 首并发解析里 musixmatch 是 0/16。修法：`musixmatchTokenFetchMu` 单飞锁包住「读磁盘 + 必要时发网络请求」整段，其余 goroutine 排队等它做完、拿锁后**必须**重新查一遍缓存（前一个持锁者可能已经换好了），不能各自再抢一次网络。`musixmatchCachedToken()` 让 token 仍在有效期内的调用完全绕开这把锁——它只在真的需要刷新时才有意义。回归测试 `musixmatch_test.go` 用 `musixmatchDoFetchToken` 这个缝（nil=用真实实现）验证并发场景，不碰网络。lyricfind 抓 `X-Goog-Visitor-Id`（2026-08-25 加，`ytmusicEnsureVisitorID`，函数名仍按检索机制叫 ytmusic）从一开始就按同一个单飞模式写，不重蹈这个坑——区别是它没有过期时间，抓到一次就一直复用到进程退出，测试见 `ytmusic_test.go`。

## 代码锚点

| 主题 | 位置 |
|---|---|
| 入口/缓存判定/自愈调度 | lyrimuse-collector/enrich.go `trackEnrichment` `resolveEnrichAsync` |
| 首次解析的真取消 | enrich.go `enrichCancelFuncs`、`resolveEnrichAsync` 的 `ctx.Err()` 分支（落定成"暂无歌词"）、`commitEnrichEntry`（正常/取消两条路径共用的落盘收尾）；enrichcancel.go `startEnrichCancelWatcher` `checkEnrichCancelRequest`；测试 enrichcancel_test.go；ctx 穿透十个网络源见各源文件顶部；App 侧按钮在第 11 章 |
| key 推导 | enrichkey.go `enrichKey` `normEnrichTitle`；迁移 `migrateEnrichKeys` |
| 八源并发/流式 | enrich.go `fetchScoredLyricCandidatesStreaming` |
| amll-ttml-db 源 | amllttml.go `amllLyric` `parseAMLLTTML` `amllSpeakerPrefixes`;开关 features.go `lyricSourceEnabled` |
| LyricFind 源 | ytmusic.go `ytmusicLyric` `resolveYTMusicLyric`（search→next→browse 三跳，只接受 LyricFind、见 `ytmusicIsLyricFindSource`）`ytmusicEnsureVisitorID`（单飞） |
| 酷我源 | kuwo.go `kuwoLyric` `resolveKuwoLyric`（搜索后自己重新打分排序，见 `kuwoCandidateScore`）`kuwoSearch` `kuwoFetchLyric` |
| 演唱者标签(Go 侧) | lyricspeaker.go `lyricSpeakerLabels` `lyricSplitLabel` `isCreditLineWithSpeakers` —— 与 Swift 侧 `LyricDuet` 同口径,改一边必须改另一边 |
| 打分 | match.go `scoreLyricCandidateDetailed`（版本 `lyricsScoringVersion`）；打完分排序前的收尾撤销 `applyWordTimingTitleOverride`（两处调用：enrich.go `rankLyricSourceResults` / `mergeLyricCandidateRounds`） |
| 一轮原始应答 → 排好序的候选 | enrich.go `rankLyricSourceResults`（2026-09-04 从 `fetchScoredLyricCandidatesStreaming` 的 `scoreAndSort` 闭包提成包级纯函数；候选构建、时间轴自洽修复、末尾印证、正文共识、逐条打分、纯音乐标记、逐字加分撤销、稳定排序全在这里）；入参类型 `lyricSourceResult`；只给测试用的观察钩子 `lyricSourceResultTap` |
| 回归金标集（打分层） | lyricsgolden_test.go（`TestLyricsGolden` / 类别契约 `goldenRequiredCategories` + `goldenCategoryCheck` / 独立判据 `goldenLabelEvidence` + `goldenJudgeEvidence` / 明文探针）、lyricsgolden_scramble_test.go（保形置乱 `scrambleLyricRound`）、lyricsgolden_capture_test.go（联网采集 `TestLyricsGoldenCapture`，默认跳过）；样本 testdata/lyricsgolden/*.json，用法见同目录 README |
| 回归金标集（检索层） | lyricsgolden_search_test.go（`TestLyricsSearchGolden` / 独立判据 `goldenJudgeSearchPick` / 源覆盖契约 / 采集 `TestLyricsSearchGoldenCapture`）；样本 testdata/lyricsgolden/search/*.json；四个源的挑选纯函数 netease.go `neteasePickSong`（2026-09-04 从 `resolveNeteaseInfo` 的 pick 闭包提出，类型 `neSearchSong`）、qq.go `qqCollectCandidates` `qqPickCandidateWithAlbum`（同日从 `resolveQQMusicMatch` 的专辑分支提出）`qqPickCandidate`、kugou.go `pickKugouSearchCandidate`、lrclib.go `pickLRCLIBSearchResultDetailed`；只给测试用的观察钩子 enrich.go `lyricSearchItemsTap`（四个源把解析好的搜索结果交给挑选函数前回调） |
| 挑选 | enrich.go `pickLyricCandidate` |
| 守卫 | match.go `isTimedLRC` `isProbablyWrongLanguageLyrics`（第 25 条：候选源自己确认的 candidateArtist 或 `knownArtistAlias(localArtist)` 含汉字可豁免）`isCreditOnlyLRC` `usableWordTiming` |
| 歌手闸三档 | match.go `artistMatches` / `lyricSourceArtistMatches` / `lyricRecordingTriangleMatches`（第三档只在 kugou.go `resolveKugouLyric` 调用） |
| 另一场演出判据 | match.go `liveAlbumIdentityConflict` `albumHasLiveMarker` `albumIdentityTokens`（v7，只在 `scoreLyricCandidateDetailed` 打分层调用，不参与身份/封面判定） |
| 同一次录音判据（时长锚定） | match.go `sameRecordingDespiteVersionTags`（v8，三处使用：打分层豁免 versionTags；netease.go `pick()` 的时长+专辑锚定档；v9 起 lrclib.go 召回闸豁免） |
| 专辑级 live 声明（v9） | match.go `recordingVersionTags` `albumHasCJKLiveMarker`；分词的拉丁↔CJK 交界断词 `albumTokens` `isCJKRune`（见第 36 条） |
| QQ 专辑维度检索 | qq.go `resolveQQMatchViaAlbum` `qqAlbumIdentityQuery` `qqAlbumSongs`（GetAlbumSongList）`qqSmartboxAlbums`；启用条件见 `resolveQQMusicMatch` 内两处调用点（见第 36 条） |
| QQ 歌名维度检索 | qq.go `qqSearchSongs`（唯一入口：`qqClientSearch` 跨标题变体合并 + 按需补 `qqSmartbox`，判据 `qqSearchNeedsSmartboxSupplement`）`qqClientSearchItems`（响应归一，合唱署名用 `/` 拼）`qqCollectCandidates`（标题闸+身份闸，透传专辑名/时长）`qqCandAlbumName`（自带专辑名免去一次详情请求，预算 `qqAlbumLookupBudget`）`qqPickCandidate`+`qqCreditSetEqual`（挑冠军与独唱/合唱 tiebreak）`qqMatchFromCand`；单测 `qqclientsearch_test.go`（见第 39 条） |
| Apple 目录锚点 | applecatalog.go `appleCatalogAnchor` `appleCatalogSearchIdentities` `dedupeArtistIdentities`（详见第 02 章） |
| 重试/重打分 | enrich.go `needsLyricsRetry` `retryLyricsUpgrade` `needsLyricsRescore` `rescoreLyrics` |
| 已校准一票否决 | lyricspins.go `lyricsPinned` `readLyricsPins`;Swift 侧 `LyricsPinStore` |
| 决策留痕 | decision.go `buildLyricsDecision`；lyricstrace.go |
| 手动重匹配的可判定性闸 | enrich.go `rescoreDecidable`（第三参 `noCurrentLyrics`）；Swift 侧 `LyricsRematchDecision.decide` |
| 各源 | netease.go / qq.go / kugou.go / lrclib.go / musixmatch.go |
| 纯音乐占位判定 | netease.go `isInstrumentalPlaceholderLyric`；qq.go `resolveQQLyric`→`qqLyricResult`；enrich.go `rankLyricSourceResults` 的 `instrumentalMarker` 三分支 |
| QQ 译文 / 罗马音 | qq.go `qqQRCLyric`→`qqQRCResult{yrc,tr,roma}`、`qqAuxiliaryLRC`→`qqAuxiliaryPlainToLRC`（`hasQRCLineTiming` 分流到 `qrcToLineLRC` / `cleanQQAuxiliaryLRC`，`isQQTranslationNotice`）、假名标注行 `splitQRCKanaLine`→`qqQRCResult.kana`→`attachKanaLine`；enrich.go 候选装配处 `usableValueAdd(qqLyr, qqTr, "zh", qqRoma, …)`、最终装配 `switch c.source` 的 `case "qq"`；单测 `qqaux_test.go` |
| 酷狗译文 / 罗马音 | kugou.go `splitKRCLanguageLine`→`krcLanguageTracks`（`krcLineStarts` 行序号对齐、`krcLanguageTrackToLRC`、`krcLanguageRomaMaxHanRatio` 谐音闸）；enrich.go 候选装配处 `usableValueAdd(kugouLyr, kugouTr, "zh", kugouRoma, …)`、最终装配 `switch c.source` 的 `case "kugou"`；单测 `kugoulang_test.go` |
| 源级熔断 / 退避 | sourcebreaker.go `lyricSourceBreaker`（`observe` / `planRound` / `lyricSourceForHost` / `parseLyricSourceRetryAfter`）、`lyricSourceRound`（ctx 传递跳过名单）；networkobs.go `doHTTPTracked` 两处 `observe`；enrich.go `fetchScoredLyricCandidatesStreaming` 的 `skipSource`、三处写缓存点的 `LyricsSourcesSkipped`、`needsLyricsFirstFill` 的 `lyricsFillSkippedRetryInterval`；decision.go `SourcesSkipped`；单测 `sourcebreaker_test.go` |
| DoH 解析与代理兜底（只对 `.musixmatch.com`） | doh.go `dohShouldResolve` `dohLookup` `dohDialContext`→`dohDialRace`/`dohDialRaceWith`（并发拨号）`dohHTTPClient`；proxyfallback.go `proxyFallbackTransport`（`RoundTrip`/`attempt`/`preferProxy`/`markSticky`）＋跨进程提示 `loadProxyFallbackHint`/`saveProxyFallbackHint`（`~/.config/lyrimuse/lyrimuse-proxy-hint.json`）；systemproxy.go `systemProxyURL`/`readSystemProxyURL`/`parseSCUtilProxy`/`proxyReachable`；musixmatch.go `musixmatchHTTPClient` 的 `onBlocked`；单测 `doh_test.go` / `proxyfallback_test.go` / `systemproxy_test.go`（见第 42 条） |
| 失败原因代码（两侧同步） | lyricsourcefailure.go 的四个常量；Swift 侧 `LyricSourceFailureReason.text(forCode:)`；源码级守卫 `lyricsourcefailure_test.go`（集合对账 + 每个 case 必须 `return L10n.t(`） |
| 封面选源 | enrich.go `preferAppleCoverOverNetease` `coverNeedsAlbumCheck` `coverSwapAllowed`；apple.go `searchAppleMusicMatch` `resolveAppleMusicMatchViaAlbum` |
| 专辑预取 | albumprefetch.go `prefetchAlbumSiblings` |
| 手动搜索 | searchcli.go `runSearchLyricsCLI` |
| 流式搜索的中间态合并 | enrich.go `scoredLyricCandidatesStreaming` 里别名重试轮的 `aliasUpdate` 闭包 + 首歌手变体轮的 `mergedUpdate` 闭包，都靠 `mergeLyricCandidateRounds` 避免"搜索候选歌词"弹窗中途闪回空/半状态 |
| `lyrimuse-collector/lyricstimeline.go` | 行级 LRC 与逐字轴打架时以逐字轴为准重挂时间戳（`rehangLRCOnYRC`），译文/罗马音跟着搬（`remapLRCTimestamps`）；重挂修不了且两套轴自相矛盾（配对行中位偏差 ≥10s）时弃用逐字轴（`wordTimingContradictsLRC`，见坑 32）；候选构造处 `rehangCandidateTimelines`、启动期存量 `migrateLyricTimelines`。不改打分判据，因此不 bump 版本。见坑 23/32 |
## 设计决策与已知坑

### 歌词搜索回归金标集：改打分先过它（2026-09-04 加）

**背景**：这一章记的每一条「已知坑」都对应一次真实错配，修法散在 `match.go` / `enrich.go` 的几十条判据里；但仓库里守它们的一直是**按函数**钉的单测（"这一条规则对这个输入怎么判"），从来没有"**这首歌**拿到**这组候选**最后**选对了**"的端到端样本——历次"全库 2339 条回放"都是一次性脚本、跑完即丢，`simeval` 又依赖本机数据默认跳过。结果是改任何一档权重，"哪几类歌会换冠军"在仓库里没有常驻证据。

**做了什么**：
- `fetchScoredLyricCandidatesStreaming` 里的 `scoreAndSort` 闭包提成包级纯函数 **`rankLyricSourceResults`**（入参 = 各源原始应答 `map[source]lyricSourceResult`），生产与测试跑同一份代码——`simeval_test.go` 那种在测试里重抄骨架的做法已经漂过两步（少了 `rehangCandidateTimelines` 和 `applyWordTimingTitleOverride`），不再允许。
- **`testdata/lyricsgolden/*.json`**：18 首真实曲目的原始应答 + 已确认正确的结论（冠军、每条候选判决、纯音乐标记、完整分项快照），覆盖 19 类。类别清单与"这一类的样本必须体现什么"钉在 `goldenRequiredCategories` / `goldenCategoryCheck`：华语录音室多源、英文、日文罗马音、韩文谚文、粤语、同场/另一场现场版、版本限定词错配、多歌手合 credit、三类否决（署名/纯文本/语言）、末句超曲长、跨源末尾印证、无逐字冠军、amll 内嵌译文、播放器同源、单候选、纯音乐标记。覆盖按**行为被体现**算而不按标签算（纯音乐那首里网易云的署名行也被否决了，就算覆盖了「署名否决」）。
- **正确性不信缓存**（用户 2026-09-04 定「不能纯信目前的缓存」）：每个样本的冠军要过一组独立判据 `goldenLabelEvidence` / `goldenJudgeEvidence`——歌名过 `lyricTitleAccepted`、版本限定词一致且不是另一场演出、自报曲长偏差 ≤3%、末句不超曲长且覆盖 ≥50%、**至少一个别的源印证正文**（单候选则曲长 ≤1% 且覆盖 ≥70%）、现场专辑要对得上同一场、两边 live 声明对称（这一条按 `albumHasLiveMarker` 连拉丁 live/concert 词元一起认，比打分层严）。缓存里那份只是旁证，跟冠军不是同一份内容就算有争议、拒绝。没有 FORCE。`TestLyricsGoldenWinnersAreIndependentlyJustified` 每次都拿样本数据重算这组判据。
- **没有 `word-timing-override` 这一类**：库里 20 条真实触发案例过了一遍没有一条站得住——原始案例（方大同《公园/南音 (Live版)》，酷狗是另一场演唱会）如今被 v7 `liveAlbumConflict` 先接住、逐字不再是决胜项、规则不触发；仍会触发的 11 条（林家谦 White Summer Live 系列、《Catch a Dream (Live版)》《爱不来 (Live版)》《大风吹 (和声伴奏)》）里，被撤销 +400 的酷狗候选跟冠军**是同一张专辑、同一自报时长的同一次录音**，只是括号写法不同（「(with 宣萱)(White Summer Live)」vs「(White Summer Live) [with 宣萱]」）——撤销之后用户丢的是逐字、换来的不是版本正确。⚠️ 这更像 v5 那条规则的误伤面（v5 消融时 0 误报的口径是 861 条 v5 之前的记录，White Summer 这批是之后进来的），值得单独复核：同专辑 + 自报时长 ≤1% 的两条候选之间不该触发撤销。规则本身仍由 match_test.go 的 `TestApplyWordTimingTitleOverride_*` 钉住。
- **断言分两层**：冠军/判决/纯音乐标记是语义硬断言，`LYRICS_GOLDEN_UPDATE=1` 也不会静默改写、必须再给 `LYRICS_GOLDEN_ACCEPT_SEMANTIC=<样本id>` 逐首点头；分数/分项是快照，改权重后 UPDATE 重生成、靠 git diff 审"哪首歌的哪一项动了"。突变测试实测：把 `lyricOvershootToleranceSecs` 5s 改成 50s，`lineonly-conversation-mix` 冠军翻成错版本的 QQ、`overshoot-pianzhikuang` 的 -700 消失，两处当场红。
- **样本正文是置乱的，这是刻意的**：01 章版权立场是「不托管、不转发、不再分发」，真实歌词进 git 违背它。`scrambleLyricRound` 做同一首内一致的字符双射（汉字→CJK 扩展 A 区、拉丁保大小写置换、假名/谚文块内置换；时间戳/标点/元数据标签/署名行/演唱者标签/纯音乐占位原样），打分读到的全部特征置乱前后逐位相同——采集器把"置乱前后 `rankLyricSourceResults` 结果逐项一致"当写入前的硬闸，不一致就拒绝入库。⚠️ 第一版把行首「标签+冒号」一律原样保留，接缝处造出的 3-gram 让《躺在你的衣柜 (Guitar Version)》netease 与其它源的 Jaccard 从 0.559 漂到 0.544、跨过 0.55 丢了 100 分共识，被闸 3 拦下——现在只有**内容决定分类**的标签（演唱者标记、署名关键词/乐器词根/代词、精确署名表）保留原样，人名/普通词标签整行连标签一起置乱。
- **第二层：检索层金标**（`lyricsgolden_search_test.go`，同日）。打分层守的是"拿到最终候选后怎么挑"，这一层守再往前一步——各源在**自己的搜索结果**里挑"就是本地这首"的那一条（同名歌里混着翻唱/演奏/另一场演唱会/另一位歌手）。四个源的挑选逻辑各是一个纯函数（见锚点表；netease 的 pick 闭包和 QQ 的专辑分支循环为此原样提成包级函数），样本 = 真实搜索结果的元数据（id/歌名/歌手/专辑/自报时长/语种；只有 lrclib 的结果带正文，照第一层置乱）+ 本地查询词 + 期望挑中谁（QQ 另记 strict/loose 两档各放行了谁、不看专辑时会选谁；候选没自带专辑名时生产要查详情的那几条，采集时按同一份预算真的查一遍记成 `album_lookup`，回放照表还原）。55 个样本（netease 19 / qq 17 / kugou 15 / lrclib 4，含 2 个"选空"负样本）。挑选结果同样过独立判据（歌名过闸、歌手沾边、自报时长 ≤3%、版本一致、live 对称；选空则这批里必须**确实没有**站得住的候选），不过就不采——采集时被拒的几条本身就是信息：QQ/酷狗对《Shall We Talk (Live)》在检索层挑的是《Get A Life (Live)》另一场（打分层靠 liveAlbumConflict 兜住）、QQ 对《躺在你的衣柜 (Guitar Version)》挑的是 199s 的录音室版（打分层靠 durationOff+sourceDurationOff 兜住）、酷狗对《All I Have to Give (The Conversation Mix)》挑的是 276s 的原版（打分层靠 -700 兜住）——三处都是检索层放行了错版本、靠打分层救回，检索层本身没有版本判据。突变测试：`lyricTitleAccepted` 放开任意子串包含，三个 QQ 样本的放行名单当场红。
- 用法见 `testdata/lyricsgolden/README.md`。

**采集过程顺手核实到的三件事**（2026-09-03，缓存快照），改这一章别的功能时要知道：
1. 丁世光《低潮期 (feat. 叶喜儿)》缓存里生效的是酷狗一条 **30 秒、5 行的残片**——决策存档 `duration_secs` 为空，rescore 那轮是拿 0 时长打的分，时长判据整套失效后 `wordTiming:400 + titleMatch:120 + lines:5` 就赢了。这是 searchcli.go 里那段「duration=0 会让这条路直接被堵死」的另一个形态：不是搜不到，是**选错还理直气壮**。联网重搜网易云那条（专辑吻合 + 时长吻合 + 与 QQ 正文共识）是对的；这首没进金标（缓存与冠军不一致 = 有争议）。
2. 方大同《公园 (Live版)》缓存条目**自相矛盾**：`lyrics_decision_applied` 记着 rescore v6 胜者 netease、`applied=true`、`lyrics_score=674`（正是 netease 那条的分），但 `lyrics_source` 与正文（以及 `lyrics/` 权威文件的 `[source:kugou]` 头）都还是酷狗那份 Timeless 演唱会版——用户当初报的就是这份错的。`rescoreLyrics` 的代码路径在正文变化时会导出文件，所以更像是事后某次文件调和/备份恢复把内容倒回去了、决策槽没跟着回滚。⚠️待核对 具体是哪条路径。现在联网重搜 QQ 已经给出正确的专场版（1090 分），这首歌不再触发 wordTimingOverride；同样没进金标。
3. 酷狗把关浩德写成「关浩德Walter」，`pickKugouSearchCandidate` 的歌手闸（`artistMatches` 精确段 + 三角判据）对这种"名字后面粘了英文名"的写法一条都不认——《Are You Ready》《Be It Happy Or Sad》酷狗搜索结果里明明有歌名精确、时长 ≤0.4% 的那条。QQ 的 loose 档（`looseContains`）能过。检索层金标对这两条"选空"拒收（判据说有站得住的候选却放弃了）；是不是该给酷狗也补一档 loose 闸，另议。
4. Lady Gaga《Chromatica I》（60 秒管弦乐 intro，没有任何源有歌词）在采集器进程里（跟 `search-lyrics` CLI 同一处境：无 Apple 目录锚点索引）一次完整解析跑了 **31 轮**九源并发（别名/目录署名/标题反查各种兜底轮全部依次上阵），120 秒仍未结束（采集器的 ctx 到点取消）。纯音乐标记在第一轮就已经拿到（lrclib `instrumental`），后面 30 轮都是白跑。⚠️ 这不是金标集的范围，但值得单独修："已有纯音乐结论"应该跟"已有可用候选"一样短路掉后续重试轮。


### 同源 +250 认错了「当前播放器」：判据是勾选集合而不是在放的那个（2026-09-02 修，用户报「怎么全都显示符合播放器」）

**症状**：用户在「解析决策」面板上看到酷狗和 QQ **同时**有 `+250 与当前播放器同源 · 这个源就是你正在用的播放器`——不可能两个都是。

**根因**：`nativeLyricSources` 来自 `resolveNativeLyricSources(features.Players)`，也就是**设置里勾了哪些播放器**。用户六个全勾（`apple_music/auto/kugou/netease/qq/spotify`），映射后得到 `{kugou, netease, qq}`，三个源同时拿 +250。而他实际在用 **Apple Music** 听（`np:lastPlayerBundleID = com.apple.Music`）——Apple Music 按定义**没有原生歌词源**（`playerNativeLyricSource` 对它返回空，「我们从没从它们那儿抓过歌词」），所以这首歌**一条 +250 都不该给**。

**为什么会写成这样**：2026-09-01 加播放器多选时，`resolveNativeLyricSources` 的注释写的是「选了多个播放器时，同源加权理应对它们各自的原生源都生效，不能只挑其中一个」。这句话对**别的**按播放器分叉的功能成立，对这一项不成立——它的立论是「时间轴对着同一份音频母版」，那是**正在播的那个播放器**的属性，跟"我允许哪些播放器"没有关系。单选年代它是单个字符串，最多错一个；多选之后最多同时错三个。

**两层后果**：① 面板上那句「这个源就是你正在用的播放器」对三个源都是假话；② **这一项的区分力被自己抵消**——三个中文源都 +250，它没法在三者之间区分，只剩「系统性地把它们抬到 Musixmatch / LRCLIB 之上」这一个效果，等于把 2026-08-09 消融实验删掉的那种**静态来源偏好**换了个形式加回来（对全勾的用户而言）。

**修法**：判据换成**这一刻在放的那个播放器**。
- 新增 `playerForBundleID`（`playerBundleID` 的逆向）。⚠️ **不能拿 `playerBundleID` 反推**——它的 default 分支把一切未知映射成 Apple Music，反过来用会把任何浏览器/第三方 App 都认成 Apple Music；这里认不出必须返回空串。
- `nativeLyricSources` 改成运行期按曲目设（`trackEnrichment` 里按 `bundleID` 设一次，专辑预取并发几十首共享同一个播放器、幂等），读写过 `sync.RWMutex`；`main()` 里那行按配置集合设的删掉。集合形状保留只是为了不动两处读法，实际最多一个成员。
- `search-lyrics` 是独立进程拿不到播放状态，新增 `-player <bundleid>` 参数，Swift 侧 `LyricsSearchService` 用 `np:lastPlayerBundleID` 传（沿用 `LyricsWindowView.idlePlayer` 那条既有先例）。**取不到就不传**，collector 认不出则不加分——宁可少加一项也不要加错（2026-08-21 补这一项时要修的是"手动搜索名次跟自动决策对不上"，而**加错**同样会对不上，还多一层"错得理直气壮"）。
- 删掉 `resolveNativeLyricSources` 及其测试，换成 `TestPlayerForBundleID` / `TestSetNativeLyricSourcesForPlayer`（后者把用户这次的形状钉死：六个全勾 + 在放 Apple Music ⇒ 空集）。

**影响面**：这次的排序没被改变（酷狗 1495 vs QQ 1494，两边都减 250 仍是 1245 vs 1244）。但对主力用 Apple Music / Spotify 听歌的用户，此前等于给三个中文源常年白送 250 分。⚠️ **存量条目不会自动重打分**——这次没有再提 `lyricsScoringVersion`（同一天已经从 9 提到 10，短时间内再提一次会让刚重选完的条目再来一轮）。受影响的条目会在各自下一次重打分/升级重试时自然纠正。

### 「搜索候选歌词」150 秒 → 6 秒：退避睡满 + MusicBrainz 串行（2026-09-02 修，用户报「为什么搜这歌这么慢」）

**症状**：「搜索候选歌词」弹窗搜 DAOKO×米津玄師《打上花火》，卡在「6/8」转圈两分半。

**实测时间线**（逐条打时间戳，总 150 秒以上）：

| 时刻 | |
|---|---|
| 0–2s | 8 个源里 6 个答完，0 候选 |
| **2–20s** | 白等 18 秒撞满 20 秒总截止 ← 用户看到的「6/8 转圈」 |
| 20–26s | MusicBrainz 查别名，**6 秒超时** |
| 26–27s | 第二轮 1 秒拿到 2 个候选 |
| **27–46s** | 又白等 19 秒 |
| 46s+ | 标题反查轮打网易云 → **30 / 60 / 90 / 120 / 150 秒**等差数列 |

**根因①（大头）：`neteaseThrottle` 的退避是「睡满」不是「跳过」。** 调用方都是「主端点不行就换备用端点」的两段式写法，而备用端点是**另一个桶、当时完全健康、150ms 就回**：

```go
tracks, ok := get(".../api/search/get/web?...")  // 正被 405 限流的桶 → 旧写法睡满 30s
if !ok {
    tracks, ok = get(".../api/search/get?...")   // 另一个桶,健康
}
```

改成**退避期内立刻返回 `errNeteaseBucketCooling`**。这对「被限流就别继续敲门」的原始意图其实**更强**——退避期内一个请求都不发（旧写法睡完还要发一个去试）。⚠️ 250ms 最小间隔那层照旧**睡**，两层语义不同不能一起改。

⚠️ **这一改连带修掉了那两个 20 秒 deadline**，这是修之前没预料到的：所谓「有个源不回」其实是**网易云那个源自己睡在 throttle 里**。所以「拿到候选就早停、不等满 20 秒」那条备选修法（会牺牲候选完整性）现在不需要了。

⚠️ 这条改动改掉了 `neteasethrottle_test.go` 里两条既有断言（原本断言「被标记退避的端点应该等到退避期满」），已在测试里写明改的理由和实测数据，不是静默改。同时更正了 netease.go 里一段**被实测证伪的注释**：那里写着「这条路径本来就是后台预取/兜底重试，不阻塞任何用户可见的同步等待」——而 `retryTitleFromAlbumDetailed` 正长在「搜索候选歌词」这条用户盯着看的同步路径上。

**根因②：MusicBrainz 别名解析串在第一轮之后。** 常驻端走 `resolveTrackEnrichment`，那边 `e.CanonicalArtist = canonicalArtistViaMusicBrainz(...)` 早把缓存捂热了；而 `search-lyrics` 是**每点一次就新起一个进程**，进程内缓存永远从空开始，于是每点一次都要串行等一趟 MusicBrainz。而 MusicBrainz 这阵子本来就慢——同一时刻直连探测三次：**5.60s / 2.99s / 11.51s（超时）**，6 秒的客户端上限经常撞满。

修法：CLI 里把 `retryArtistIdentities` **提前到第一轮开始时 fire-and-forget 发起**，把这趟往返藏进第一轮那 20 秒里。⚠️ **不多打一次请求**——别名轮本来就要调它，只是提前；结果落进那几份带锁的进程内缓存，查到非空还会落盘。⚠️ 只在 CLI 做，常驻端不需要。

**效果**：150 秒 → **6.2 秒**（冷）/ **3.9 秒**（缓存已落盘）。⚠️ 如实记下：这两次复测里 MusicBrainz 恰好 ~1s 就返回了 503，所以**根因②的贡献没有被这组数据单独隔离出来**；它的价值上限就是 MB 当时的延迟（实测 3–11s）。这次的绝大部分收益来自根因①。

### 网易云 405 反复出现：退避太短 + 主备端点选反了 + 限流被张冠李戴（2026-09-03 修，用户报「怎么还会出现网易云限流的情况」）

**症状**：「搜索候选歌词」弹窗的「歌词源可用情况」里，网易云显示「未给出候选」+「网易云接口限流（短时间内请求过多，code 405）」——而上一轮（2026-09-02）刚给它加过最小间隔和退避。

**证据一：25 小时真实日志的分布**（`~/Library/Logs/lyrimuse.log.old`，2026-09-01 18:47 → 09-02 19:12 UTC）

| 观测 | 数据 |
|---|---|
| 拒绝总数 | **171**（164× `code 405` / 7× 406） |
| 落在哪个桶 | **171 次全在 `/api/search/get/web`**；`/api/search/get` 打了 **8537 次、零拒绝** |
| 两个端点的请求量 | `/web` 10029 次 vs `/get` 8537 次 —— 同一量级，所以不是"谁被打得多谁被限得狠"的采样偏差 |
| 相邻拒绝间隔 ≤35s | **89/170 = 52%**（"退避刚满就再撞一次"），最长**连撞 21 次**（≈10.5 分钟一直在敲同一扇关着的门） |
| 间隔 2–10 分钟 | 48 次；>10 分钟 12 次 → 真正的恢复窗口是**分钟级**，不是 30 秒 |

**证据二：复现两次**（同一分钟内跑两次 `collector search-lyrics`，都是全新进程）

- 《妳聽得到》：进程的**第一个**网易云请求就吃 405（19:38:46）→ 自动换备用端点 `/api/search/get`，10 次全 200 → 仍然零候选，`failureCodes` = `{netease: netease_rate_limited}`（跟用户截图一致）；
- 《白发》：**同样**吃 405（19:40:48）→ 走备用端点 → netease **给出 4 条候选**，最终 `failureCodes` 里**没有** netease。

后者是关键对照：**"吃过 405" 和 "这个源没给出候选" 根本不是同一件事**。

**四条修法**：

1. **退避从固定 30 秒改成指数**（`neteaseBlockCooldownBase` 2 分钟 → ×2 → 上限 `neteaseBlockCooldownMax` 15 分钟，该桶**成功一次就清零**）。30 秒那一版的注释自己写着"没有实测依据的保守起步值……观察到退避期一过又立刻再被拒就调大"——上面 52% / 连撞 21 次就是那个信号。固定 30 秒不只是白撞：每次撞上去都把服务端的惩罚窗口续一次，等于自己把限流维持住。
   ⚠️ **移位溢出守卫**：`time.Duration` 是 int64，`base << 30` 会溢出成**负数**，而负退避在 `neteaseReportBlocked` 那边等于"已经过期"——连撞越多反而越不退避，正好反了。`neteaseCooldownForStreak` 里 streak ≥ 4 直接封顶，测试专门钉了 32/63/64/2^20 四档。
2. **主备端点对调**（`neteaseSearchEndpointPrimary` = `/api/search/get`，`Fallback` = `/api/search/get/web`）。依据就是上表那个 171:0。两个常量是三处调用点（`neteaseSearch` / `neteaseAlbumIDByName` / `retryTitleFromArtistSearchDetailed`）的唯一真源，别再各写一遍字面量。⚠️ **兜底那条保留不删**：分桶限流的意义就是"一条路堵了还有另一条"。
3. **限流不再张冠李戴**（`neteaseSawSuccessNow`）：`neteaseLastFailureReason` 只要进程里出现过一次 405 就会被贴上，而「歌词源可用情况」只看"有没有给出候选"，两件独立的事被显示成因果。现在两个消费端（`lyricSourceFailureReasons` / `test-lyric-sources`）都先问一句"这一轮该源成功答过吗"，成功过就不报限流、如实显示"未给出候选"。
4. **手动搜索这条路径的 405 补上日志留痕**：此前 App 只在 `search-lyrics` **退出码非 0** 时才把 stderr 打进日志，正常退出整段丢掉——于是界面正显示着「网易云接口限流」，而 `lyrimuse.log` 里 `grep -c "code 405"` = **0**（常驻 collector 那半边才有记录）。现在退出码 0 时也把 stderr 里匹配 `rejected (code` / `backing off` / `cooling down` 的行按 `.notice` 收进 App 日志（`LyricsSearchService.logSourceHealthSignals`，单次上限 12 行）。⚠️ 用 `.notice` 不用 `.debug`：后者在 os_log 里默认不落盘，而诊断导出是按 subsystem 事后查询的，用 debug 等于白记。

⚠️ **这次刻意没做的一条**（知道、但没修）：两道闸的状态都是**进程内**的，而打网易云的是两个进程——常驻 collector（自动解析）和每次手动搜索 spawn 的 `search-lyrics`。新进程的冷却表永远从空开始，所以它必然去撞那个已知关着的门第一下（上面两次复现都是"第一个请求就吃 405"），而服务端是按 IP + 端点桶累计的，我们进程里的退避对它毫无意义。彻底修有两条路：把冷却表落盘共享（要跨进程文件锁），或者让手动搜索走常驻进程（架构改动）。主备对调之后这条的实际伤害降到很低（首选桶实测零拒绝），所以留着，别忘了它还在。

### 一个异体字就能让三家中文源全部搜不到（2026-09-03 修，用户报「为什么这首歌只能搜出一个来」）

**症状**：周杰伦《妳聽得到》在「搜索候选歌词」里只出 1 个候选（LRCLIB），网易云 / QQ / 酷狗一条都没有。

**A/B 隔离**（同一时刻、同一 duration，只改标题/艺人/专辑的写法）：

| 搜索词 | 出候选的源 |
|---|---|
| 妳聽得到 / 周杰倫 / 葉惠美（播放器给的原始元数据） | 只有 **LRCLIB** |
| 你听得到 / 周杰伦 / 叶惠美 | **酷狗 + 网易云 + QQ + LRCLIB** |
| 妳听得到 / 周杰伦 / 叶惠美（只留「妳」是异体） | 只有 **LRCLIB** ← 单字隔离 |

第三行把变量卡死了：**病根就是「妳」这一个字**。LRCLIB 能出，是因为上传者当初就写的「妳听得到」。

**机制**：搜索词发出去之前会过一遍 `toSimplified`（`enrich.go` 里对 artist/title/album 各调一次），用的是内嵌的 OpenCC `TSCharacters.txt`。查那张表：`聽`→`听` 有；**`妳`/`祂`/`牠` 一条都没有**。因为「妳」根本不属于繁简转换的范畴——它是大陆《第一批异体字整理表》里被并入「你」的**异体字**，不是「你」的繁体。于是搜索词成了「妳听得到」，而三家的曲库里这首叫「你听得到」。

⚠️ **同一个坑本仓库踩过一次、只修了一半**：`LyricsSyncEngine` 那侧 2026-08-22 就为它加过 `HanVariants`（用户当时报「开了简体还是看到繁体」），但那一层补在 **Swift、只管歌词正文显示**；**Go 侧发搜索词的路径没有这一层**。

**连带后果**（能解释缓存里的怪事）：`canonicalEnrichKey` 的"繁简宽松匹配"走的也是同一个 `toSimplified`，所以这首歌在缓存里存成了**两条**——`周杰伦|你听得到|叶惠美`（带 `lyrics_yrc`，**逐字**歌词）和 `周杰倫|妳聽得到|葉惠美`（lrclib 普通 LRC）。同一首歌，认不出是同一首。

**修法：把这一层做成通用的、两侧共用一份数据**（用户要求：「做成通用逻辑，后续遇到这种字的问题都要可以解决，不要通过手动维护一个表的方式，而且 swift 和 go 都使用同一套逻辑尽量」）

- 表**从上游数据推导**，不是手工列的：`scripts/gen-han-variants.py` 读 Unicode Unihan（`kUnihanCore2020` 区域集 / `kGradeLevel` / 三种变体关系）+ OpenCC 繁简单字表，产出 **681 条**；规则细节见 08 章和生成器头注。
- 产物两份、同一次生成：`lyrimuse-collector/dictionary/HanVariants.txt`（collector `//go:embed`）与 `LyrimuseCore/Lyrics/HanVariantsTable.swift`（App 编译进去）。selftest 有断言读 .txt 逐字核对编译进 App 的表，**漏跑生成器会当场红**。
- Go 侧挂在 `toSimplifiedT2S` 的**单字兜底分支**上：只处理 OpenCC 词组表和单字表都没管的字，永远不会覆盖 OpenCC 的判断。
- 人工补丁只剩 2 条（祂→他、痲→麻，上游确实没有可用关系），另有 2 条**否决**（卍、雝），每行带理由，见 `scripts/han-variant-overrides.txt`。

**验证**（同一条命令，改前 vs 改后）：

| | 改之前 | 改之后 |
|---|---|---|
| 妳聽得到 / 周杰倫 / 葉惠美 | lrclib ×1 | **kugou ×9 + netease ×8 + qq ×6 + lrclib ×3** |

Go 侧新增 `hanvariants_test.go`（端到端折叠 + 表不变量 + 幂等），Swift selftest 那一组从"逐条断言 6 个字"改成"计数断言 + 564 条 ICU 缺口逐字过完整链路 + 跨语言逐字对账"。

⚠️ **别拿 `nm`/符号或"表里有没有这个字"当判据去查这类问题**：判据是**实测 A/B**——同一时刻只改一个字，看候选数变不变。

### 标题反查的「泛搜」兜底会在同一歌手的曲库里撞车（2026-09-02 修，用户报的真实错配）

**症状**：DAOKO×米津玄師《打上花火》（本地 289.334s）播了 48 秒才出歌词，出来的却是米津玄師**另一首歌《春雷》**的歌词，整屏都是错的。

**链路**（日志时间是 UTC）：

```
02:23:48 now playing: DAOKO×米津玄師 - Uchiagehanabi
02:23:58 "DAOKO×米津玄师" has no usable candidate … trying alt identities: [DAOKO 米津玄师]
02:24:18 lyrics: search deadline (20s) hit for artist="DAOKO" title="Uchiagehanabi"
02:24:30 lyrics: title-reverse-lookup: … searchTitle="春雷" searchDiff=0.385 searchOK=true
         -> corrected="春雷" method="title-from-artist-search"
02:24:32 lyrics: title-from-artist-search fallback added candidates: usable_sources=1->5
```

改写后的标题带回来的三条候选拿到 netease 1308 / kugou 1237 / qq 1231，把唯一正确的那条（musixmatch 的 `Uchiagehanabi (DAOKO Solo Ver.)`，670 分）压死。

**根因**：`retryTitleFromArtistSearchDetailed` 这条兜底**刻意不看标题文字**（它存在的理由就是救《飞机场的10:30》= `Airport in 10:30` 这类纯文字比不出来的译名），判据只剩「歌手对得上 + 时长差 < 2s」。而搜索词是「歌手 + 本地标题」，标题一个字都没命中时，网易云返回的就是**这个歌手的曲库**——30 条里总能矬出一首时长凑巧接近的，判据从「在几个相关候选里挑对的那个」退化成「在整个曲库里抽签」。`retryTitleFromAlbumMaxDurationDiffSecs` 的注释其实早就预言过（「两首不同的歌时长凑巧接近并非不可能」），只是那句话是按「一张专辑的曲目表」写的，没料到同一个判据会被喂进 30 条泛搜结果。

**修法：用搜索名次当缺失的那个信号**（`retryTitleFromArtistSearchMaxRank = 5`）。2026-09-02 对三个案例各真查一次网易云量出来的：

| 查询 | 纯时长判据会选 | 它的搜索名次 | 对错 |
|---|---|---|---|
| `米津玄师 Uchiagehanabi` | 春雷 | **第 12 名** | ✗ 另一首歌 |
| `方大同 Love Love Love` | 爱爱爱 | 第 2 名 | ✓ |
| `陶喆 Airport in 10:30` | 飞机场的10:30 | 第 1 名 | ✓ |

后两个正是这条兜底存在的理由，它们都靠**搜索引擎认得那个标题**才排到最前；排到第 12 名说明引擎压根没把它跟标题关联起来，那一条纯粹是「同歌手 + 时长撞车」。取 5 给已知最差正例（第 2 名）留了一倍余量。⚠️ 只对泛搜路径生效，**不能下放进 `bestAlbumTrackByDurationDetailed`**——另一个调用方喂进去的是专辑曲目表，那里的顺序是曲序不是相关性名次。

**顺带修掉的一处死代码**：排歧义守卫写的是 `d == bestDiff`，**浮点精确相等**——两首不同的歌时长差要 bit 级一样才触发，等于从来没生效过。改成 0.5s 真实余量（`bestAlbumTrackAmbiguityMarginSecs`），并且冠军被换掉时旧冠军要降级成亚军候选，否则先出现的那条会被静默忘掉。⚠️ **这一条并不能修上面那个 bug**（春雷 0.385s vs 亚军 0.958s，差 0.573s > 0.5s，守卫不该触发也确实不会触发）——真正修掉它的是名次截断，测试里专门有一条断言把这个事实钉住。

**核实过但没有采用的修法**：把网易云搜索结果里的 `alias` / `transNames` 取回来当文字佐证。字段确实存在且没被解析（《飞机场的10:30》正是靠 `transNames:["Airport at 10:30"]` 成立的），但实测《爱爱爱》两个字段**全空**——做成硬闸会把 2026-08-30 刚修好的那个案例重新打死。

**存量自愈**：`lyricsScoringVersion` 同时 9 → 10。这不是走形式——被写坏的条目只有在 `needsLyricsRescore` 放行时才会重选，而那道闸的判据正是 `e.LyricsScoringVersion >= lyricsScoringVersion`。停在 9 的话，实测用户库里已按 v9 打过分的 **114 条**（占有歌词条目 3276 条的 3.5%）永远不会被重访。提到 10 之后仍救不回来的两类，如实记下：重打分次数已达 `lyricsRescoreMaxAttempts` 的 **6 条**、`ManualLyrics` 手动锁定的 **6 条**（后者是刻意跳过的）。另外 `rescoreDecidable` 还有一道闸——当前歌词的来源这一轮没应答就不敢动，所以被 netease 污染的条目要等 netease 应答那一轮才会纠回来。

**提版本号的三个副作用**（2026-09-02 提交前逐条核过源码，不是推测）：

- **不会突发打源**。`needsLyricsRescore` 的非测试调用点只有 `enrich.go:535` 一处，落在 `resolveTrackEnrichment` 的**缓存命中**链里——逐曲、**播到才触发**，不存在全库批量扫；再叠 `lyricsRescoreMaxAttempts = 3` 和 `lyricsRescoreDeferInterval = 1h`。所以「全库版本落后」是摊在实际收听里慢慢消化的。这条特意核过：同一天刚修过网易云限流（用户被打了 405），要确认这次 bump 不会把源打爆。
- **锁住的歌词不受影响，没锁的会被重选一次**。`needsLyricsRescore` 第一行就一票否决 `ManualLyrics` 和 `pinned`；只有「手动挑过（`manual_pick_sha`）但没勾锁」的那些会重新选一次。这正是 `enrich.go:249` 写着的语义（不锁 = 之后一切自动优化照常调整），是预期行为不是坑——但用户如果发现某首**没锁**的歌词换了，那就是这次 bump 干的。
- **跟歌词库备份/搬家的交互**。sidecar 里烘的是导出那一刻的 `lyrics_scoring_version`（今早那份 `Lyrimuse-Lyrics-2026-09-02-034200.json.z` 烘的是 9）。`enrichrestore.go` 头注把「丢了这个字段会让全库排进重打分队列」列为它的核心动机之一，那句话没写错，但读起来容易让人以为「带过去了就不会重打分」——**这次 bump 之后，所有存量条目（含刚搬家过去的）都会在下次播放时各重选一次**，因为大家都停在 9。

**为什么加 `retry_method` / `corrected_title` 到决策存档**：排查时想统计「库里还有多少条是这么来的」，发现**根本无从下手**——存档里只有 `winner`/`candidates`，看不出标题被改写过；而光看标题分不出对错，`Uchiagehanabi → 春雷`（错）和 `Black Hole → 黑洞里`（对）在标题层面是一模一样的形状。这两个字段把「走没走那条高风险路径」变成可 grep 的事实。仍然服从「只写不读」铁律。

**验证**：`collector search-lyrics -artist "DAOKO×米津玄師" -title "Uchiagehanabi" -album "Uchiagehanabi - Single" -duration 289.334 -pick`（这条 CLI 只读缓存、不写）。修复后候选表里春雷三条全部消失，冠军 = musixmatch 670 分 `Uchiagehanabi (DAOKO Solo Ver.)`，`scoringVersion: 10`。判据本体的断言在 `artistsearchrank_test.go`（曲目表是真查网易云量回来的，名次和时长都不是编的）。

1. 静态来源偏好分被消融实验处决（0 变对/6 变错）——排序照抄先入之见不是证据；同分交给稳定排序。
2. 时长吻合封顶从 1000 压到 300：它只是正确性的间接代理，被前奏/尾奏系统性带偏；逐字时间轴才是直接证据（+400）。
3. overshoot（末句超曲长 5s）独立重罚 -700 且不吃印证豁免：两个源一起抓到同一个错版本正是印证的已知翻车形态。
4. 同源 +250 不是静态偏好回魂：它是动态的（放什么播放器偏什么），修的是时间轴对齐维度，消融实验没测过这个维度。⚠️ 「动态」这个性质 2026-09-01〜09-02 之间**其实是破的**——那段时间判据取的是设置里勾选的播放器集合，全勾的用户等于回到了静态来源偏好（三个中文源常年 +250）。见下面那条。
5. QQ QRC 非贪婪正则曾在正文字面双引号处截断丢 81%，残片带逐字照拿 +400 且被「已有逐字不重试」钉死——修复=贪婪正则（根因）+覆盖率守卫（通用防线）。
6. 缓存永久保留 + 20s 截止 = 首解析有运气成分，这是 retry/rescore/决策留痕三件套存在的根本原因。
7. 「有方括号」弱检测的教训：`[Verse 1]` 段落标签、孤立 credit 行都能骗过，必须「≥3 行带戳且过半」。
8. 网易云限流时 HTTP 仍 200、拒绝写在 body `code` 里；找到歌但封面歌词全空（疑似限流）不缓存。
9. 注释与实现的两处已知不一致（无行为问题）：netease pick 注释说扫 10 条实际 `limit=30`；musixmatch token 注释说 retry≥1 放弃实际 `>1`。
10. 打分规则改动必须 `lyricsScoringVersion` +1，忘了就是静默失效（rescore 永不触发）。
11. 封面选源顺序（网易云优先）管的是「国内加载得出来」，不是「对得上版本」：2026-08-20 实测蔡徐坤《KUN》11 首——网易云整张专辑都没有、只有 Deadman / Jasmine / What a Day 三首先行单曲在库，这三首拿到各自的单曲封面，其余 8 首退到 Apple 拿到专辑封面，同一张专辑在「最近记录」里混着两种封面（Apple 那三首**同时**有单曲版和专辑版，`apple_music_url` 当时就已经指向专辑版，只是封面从没问过它）。修法是给顺序加一道专辑感知的例外，而不是掀掉网易云优先。
12. **仿冒黑名单的粒度 2026-08-22 从「整源跳过」收窄成「只扣身份/封面」**：原实现在
    `neteaseLookup` 开头对黑名单艺人直接 return 空、一个请求都不发，代价是这位艺人的
    **每一首歌都先天少一个源**——而网易云恰好是五源里唯一同时供逐字 YRC、社区译文和罗马音
    的那个。实测触发（用户报「开不了口 (Live) 歌词不准」）：本地在放《周杰伦地表最强世界
    巡回演唱会 (Live)》的「开不了口 (Live)」(272.973s)，整源跳过之下只剩 LRCLIB 一条候选
    (509)，而那份时间轴相对录音室版从 +1.0s 漂到 +11.5s、只有 34 行、末句比录音室版还早，
    根本不是这次现场的时间轴；网易云上那条对版的（专辑「周杰伦地表最强世界巡回演唱会」、
    自报时长 272.973 与本地逐位一致、带这次现场特有的返场段、逐行相对录音室版是**恒定**
    −10.7s 偏移、且有 YRC）经 `pick()` 严格档（标题精确 + `artistMatches` + 多候选要求专辑分>0）
    能被唯一锁定，唯一挡住它的就是那道整源跳过。现在改成出口处按艺人扣字段
    （`withholdImpersonatorRiddenIdentity`）：Cover / Artist / SongURL / AlbumID / PureMusic
    一律不给（下游行为跟原来的整源跳过逐条一致：封面退 Apple、canonical_artist 走其它链路、
    专辑预取早退），只放行歌词族加 Title/Album/DurationSecs——后三个是版本限定词/专辑亲和/
    时长那几道打分闸的输入，扣掉等于把放行歌词之后唯一的把关依据也一起拿走。放行歌词而不
    放行身份的依据：歌词按 songID 挂在网易云**歌词库**上，跟「这条曲目记录是谁传的」是两回事；
    而歌词候选另有一整套跟来源无关的防线（`lyricTitleAccepted` + 歌手闸 + 版本词 −600 +
    时长 −700/−500 + 语言闸 + creditOnly 闸 + 跨源共识），错版本在打分层就会掉下去。改后
    该曲网易云候选 1178 分（时长 271＋逐字 400＋共识 250＋标题 120＋专辑 75＋行数 62）稳居第一。
    16 首回归（6 Live + 10 录音室）7 首冠军变化、无一变坏：4 首换成网易云（「以父之名 (Live)」
    原本三条候选全被 −700 打死、无一可用），3 首 qq→kugou 是多一个源让跨源共识从 2 家变 3 家
    （+100）把本就只差几分的顺序翻过来，两边是同一版本的正确歌词。不变量由
    `neteaseimpersonator_test.go` 锁住。
13. ⚠️ **QQ 的变体查询是「第一个非空」而不是「第一个有可用候选」**（`qqSmartboxFirstNonEmpty`）：
    smartbox 只要对首个查询词回了任意条目，后续变体就不再试。上面那首歌里首个查询
    「周杰伦 开不了口 (Live)」只回一条署名「周杰伦微博台」的仿冒条目、随即被歌手闸拒，于是
    QQ 整源交出 0 候选——而裸标题变体从没被试过。2026-08-22 未改：对这首歌而言裸标题只会
    带回《范特西》录音室版（错版本，靠 −600 版本词扣分兜住），修了反而多一份错版本候选；
    但换一首「带括号查不到、裸标题才查得到」的歌，这就是实打实的漏检，记在这里备查。
14. **署名分歧的第三类：艺名↔本名 / 乐队名↔成员名，连分隔符都没有**（2026-08-22，
    「枫+退后+搁浅 (Live)」案）。Apple Music 把《周杰伦地表最强世界巡回演唱会 (Live)》
    第 14 首署名成 **「南拳妈妈弹头」**（乐队名和成员名直接粘在一起），而网易云 / QQ / 酷狗
    三家都署名 **「宋健彰」**（弹头的本名）。后果是**五源零候选、整首歌一个字都没有**，
    而这首歌在三个源上明明都有、时长还跟本地逐位吻合（119.21 vs 119.213）。
    每一条既有救援机制都够不到它，逐条实测过：
    - `artistCreditParts` 对两串都只切出 **1 段**（`isArtistCreditSep` 只认 `/ 、 & , ，`
      五个字符，这里一个都没有）→ 段集交集档的 `len ≥ 2` 前置条件不成立；
    - `artistAliasTable` 没这条（那张表的语义是「英文/罗马化艺名 → 中文名」，是另一类）；
    - MusicBrainz 两条路（中文别名 / 主名）实测都返回空串；
    - `lyricPrimaryQueryArtist("南拳妈妈弹头")` = `""`（单人名切不出第二段）→ **首歌手变体轮
      根本不触发**；`retryArtistIdentities` 返回 nil → **别名轮也不触发**。实测表现是
      `search-lyrics` 的 `sourcesDone` 只从 1 数到 5 一遍，压根没有第二轮抓取。

    **五个源死在两个不同的环节**（这是修法为什么只挂一处的依据）：

    | 源 | 死在哪 | 实测 |
    |---|---|---|
    | netease | **查询 + 闸门** | 4 条查询词全带歌手前缀，目标不在 30 条结果里；去掉歌手的 `裸标题`/`裸标题+专辑` → 目标排第 1。即便召回到了，`pick()` 的 `artistMatches` 仍会拒 |
    | kugou | **只有闸门** | 变体②`南拳妈妈弹头 枫+退后+搁浅` 把目标排在第 1 位（`kugouLookup` 只在 `chosen != nil` 时 break，所以这条一定会被跑到），然后被 `lyricSourceArtistMatches` 原地拒掉 |
    | qq | **只有闸门** | 它有第二段纯裸标题兜底，确实拿到了目标（mid=000wV3ml0W0RBm），被 `qqArtistOK` 两档（strict + `looseContains`）都拒 |
    | musixmatch | 查询 + 闸门 | — |
    | lrclib | 源上真没有 | `search`/`get` 全 0 条/404 |

    修法只在 **kugou** 一处开第三档，理由是范围最小而收益已经够：它是唯一「正主已经排在
    搜索结果第 1 位、只差这一闸」的源，而且带 YRC 逐字。刻意**不**推广到另两处：
    - **netease**：它的 `pick()` 同时决定歌词和封面/`canonical_artist`/链接指向，一个函数一个
      返回值，放宽就等于连身份一起放宽——那正是当年删掉 byAlbum 兜底要防的东西。要救它得先
      照 `withholdImpersonatorRiddenIdentity` 的样子做一层「放行歌词、扣掉身份字段」的包装，
      而且**还得同时**改查询词（它在查询阶段就召回不到），是两处改动，另算。
    - **qq**：smartbox 的条目**既不带专辑也不带时长**（专辑要另发 `qqSongAlbum(mid)` 一次请求，
      时长压根拿不到），三角验证在那里无法评估。

    ⚠️ **2026-08-22 对抗性复核订正：长度可比性闸原来是单向的。** 原写法 `nca < ratio*nla` 只约束
    「本地 ⊇ 候选」那半边；一旦是「候选 ⊇ 本地」（nca ≥ nla），判据恒真、一件东西都拦不掉——而那半边
    恰恰是巡演/合辑/精选/Live 专辑那一整类。实测：本地专辑 `Editorial`（9 rune）对候选
    `one-man tour 2021-2022 -Editorial-@さいたまスーパーアリーナ`（62 rune）宽度比 6.9，老写法照过，
    于是三角档**拒掉了对版的单曲行、选中了巡演 Live 专辑那一行**（两行歌词正文一致、时间戳差 <1s，
    所以没造成用户可见的错词，是潜在缺陷不是已发生的破坏）。已改成 `min/max` 双向同一把尺子。
    同一次复核的正面结论：对 ~2650 首真实曲目实测，三角档放行 112 处、**0 处误配**；其中 6 处
    「抢在原本会被选中的行前面」的，6 处全是改对了。

    **专辑名那道长度可比性闸的来历**：`albumScore` 的「宽松包含」档对**短通用串**几乎免检——
    同一批酷狗结果里「炸小肉丸 / album=`周杰伦` / 62s」也拿到 100 分（`周杰伦` 正好是
    `周杰伦地表最强世界巡回演唱会live` 的子串），真正挡住它的只有时长那一条。加长度可比性
    要求，是不让整条防线单靠时长撑着。

    **不需要 `lyricsScoringVersion` +1**：artist 从来不是打分输入（14 个 `scoreTerm` 里没有
    歌手项），放宽的是采纳闸不是打分。

    **实测数字**：改后该曲从 0 候选变成 kugou **799 分**（时长 177 + 逐字 400 + 行数 27 +
    专辑 75 + 标题 120）、带 YRC 逐字。消融实验：对 **174 首**真实曲库样本跑 **207 次**酷狗
    搜索、扫 **261 行**结果，第三档**只开火 1 次**——就是这首歌，放进来的正是正主，零附带影响。
    `go test ./...` 全绿。

    ⚠️ 存量条目不会立刻自己好：`needsLyricsFirstFill` 的退避是 **24 小时起步**（`lyricsFillCount`
    每次翻倍），要马上生效得用「歌词管理」→「重新自动匹配」。
15. **「…Mix」不带 re- 的舞曲混音,当初不在版本限定词表里**（2026-08-22，
    「Stranger in Moscow (Tee's In-House Club Mix)」案）。`distinctRecordingVersionTags` 收了
    `remix` 却没收 `club mix` 这一族，而 `Tee's In-House Club Mix` 归一后是
    `teesinhouseclubmix`、不含 `remix`，于是 `titleVersionTags` 抽出**空集**。
    一个词表漏洞造成**两处**后果，这是这次误判的全部成因：

    - **检索层**：`searchTitleVariants` 用的是同一个 `titleVersionTags`。抽不出限定词 →
      走「裸标题优先」→ 酷狗第一条查询 `Michael Jackson Stranger in Moscow` 拿回正常版、
      过了 `lyricTitleAccepted` 就 `break`，而**原样标题下排在第 1 位的混音版条目从没被看到**。
      QQ、Musixmatch 同理。
    - **打分层**：`versionTagsMismatch` 判两边都是空集 → -600 不触发，正常版稳居榜首。

    **但补词表并不足以修好这首歌**，这是最值得记下来的一点。补完之后正常版 1027-600=427，
    而真正对版的酷狗混音版只有 235（`durationOff -500`：它末句在 304.9s、曲长 414.32s，
    偏 26.4%，**刚好越过 25% 容差**）——错的那份反而在时长项上赢了对的那份（正常版末句
    335s、偏 19.1%，拿 +147），纯粹因为 335 比 304.9 离 414 近一点。俱乐部混音有约 110 秒
    纯器乐尾奏，「LRC 末句 vs 曲长」这个代理在这类曲目上就是噪声。

    真正的根因是：**打分打的是代理，却无视了早就采集回来、躺在同一条决策记录里的直接测量**
    ——冠军自己的 `source_reported_duration_secs` 白纸黑字写着 **344s**（本地 414.32s，偏 17%），
    也就是「我是另一次录音」。这个字段自 2026-08-12 起就在透传，注释写着「先攒评测数据」。
    v4 把它接进打分（见 `sourceDurationMismatchPenalty` 的注释，含参数网格消融数据）。

    **实测结果**：该曲五源重跑 → 冠军从 qq(1027，正常版) 变成 **musixmatch 582**，
    标题 `Stranger in Moscow (Tee's In-House Club Mix)`、**首句 31.9s / 末句 387.71s**
    —— 俱乐部混音开头就是约 32 秒纯器乐前奏，只有这一份带对了偏移（lrclib 是**同一份歌词
    文本**但首句在 66.72s，酷狗/QQ 首句都在 0.x s，全是标准版的轴）。原冠军 qq 掉到 1 分
    （`sourceDurationOff -400` + `versionTags -600` 双杀）。

    ⚠️ **2026-08-22 对抗性复核补的三条订正**：
    - `musixmatch` 当时是五源里唯一**永远不上报时长**的，于是这道 −400 对它**系统性免罚**——
      而它恰恰是匹配最松的一个（`musixmatchSearchTrackOnce` 只查 title+artist+has_subtitles，
      既不看专辑也不看时长）。实测 52 个「musixmatch 有有效候选」的条目里，按 max() 口径偏差
      >12% 的有 7 条（13.5%），其余四源合计 4.3%。**`track_length` 本来就在它的 track.search
      响应里**，只差一个结构体字段——那不是「没有证据」，是证据没被读。已补齐并透传；补齐后重跑
      消融，冠军变化 **0 处**，纯粹把这道闸补对称。
    - 我最初那份消融脚本有两处方法问题：分母用了 `/local` 而上线代码用 `math.Max`，且拿被夹到 1
      的 `score` 当基线。按「`score_terms` 求和还原未夹原始分 + max() 分母」重跑，可评样本从
      34 条扩到 **117 条**，结论不变：冠军变化仍然只有 Earth Song 这 1 处。
    - 词表变大自带一个结构性副作用：`versionTagsMismatch` 判的是**集合完全相等**，而新收的 7 个
      短语彼此重叠（club/dub/dance/vocal/house/radio × mix），于是「Vocal Mix」vs「Vocal Club Mix」
      从「两边空集不罚」变成「两个不同单元素集合 −600」。机制已验证，但在本机 734 条标题里
      **没有找到真实撞上的曲目**，故暂不做「同族折叠」——记在这里，真踩到再改。

    ⚠️ **裸「club」绝不能进词表**，有实测反例：同一张专辑的「Earth Song」本地标题就叫
    `Earth Song`（Apple 没给任何混音标记）、抽不出限定词，而正确候选是
    `Earth Song (Hani's club experience)`。收了裸 club 的话，本地空集 vs 候选有标记 =
    版本不符，-600 会打在**唯一正确**的那条上。`sourceduration_test.go` 里有守卫测试。
    这首歌也说明版本限定词这条路有天花板——本地标签压根没有混音标记时它无能为力，
    只有源自报曲长那一项救得了（消融里唯一那处冠军变化正是它，且改对了）。

    **存量条目怎么恢复**：`lyricsScoringVersion` 3→4 之后 `needsLyricsRescore` 会自动收编
    （版本落后即触发，1 小时节流 / 3 次上限，要求当前歌词的源本轮也应答）——不用等
    `needsLyricsFirstFill` 那 24 小时，也不用手动重搜。
16. **「重新自动匹配」对「压根没有歌词」的条目永远失败**（2026-08-22，用户报「手动搜索能
    搜到，点『重新自动匹配』却搜不到」）。两颗按钮走同一个 `search-lyrics` CLI、同一套检索
    打分，唯一差别是 `-pick` 那条路多过一道 `rescoreDecidable`：

    ```go
    if currentSource != "" && features.LyricsSources[currentSource] {
        return containsString(lyricSourcesResponded(scored), currentSource)
    }
    return allEnabledLyricSourcesResponded(scored)   // ← 要求所有启用的源都应答
    ```

    App 传的 `-current-source` 是 `summary.lyricsSource`；条目没有歌词时它是空串 → 落进
    else 分支 → 要求**五个源全部应答**。而「枫+退后+搁浅 (Live)」只有酷狗收录（799 分、
    带逐字），另外几个源永远不会出现在 `responded` 里 —— `Decidable` 恒为 `false`，App 按
    约定 `keptNotDecidable` 什么都不改，文案还渲染成主语为空的「这一轮「」没应答」
    （`sourceDisplayName("")`）。

    **方向是反的**：这道闸存在的意义是「别把手上这份好的换成更差的」，手上什么都没有时它
    保护的是虚空。同一个洞见 `enrich.go` 里早就写过一遍，只是这里没享受到 ——
    `lyricsUpgradeBaseline` 对空歌词条目那一支：「没有旧分要保护，任何真候选都是改进」。
    而且**自动路径比手动路径宽**：空条目走的是 `needsLyricsFirstFill` → `retryLyricsUpgrade`，
    那条路压根没有可判定性要求。手动按钮反而更严，是纯粹的不一致。

    修法是给 `rescoreDecidable` 加第三个参数 `noCurrentLyrics`，**刻意不就地推断
    `currentSource == ""`** —— 同一个空串在两条调用路径上语义不同：
    - 自动 `rescoreLyrics`：前置 `needsLyricsRescore` 第一行就要求 `e.Lyrics != ""`，
      所以空串只可能是「老条目有歌词但没记来源」，**必须保持严格**，传 `false`，口径一字未动；
    - 手动 `-pick`：空串就是「这条没有歌词」，传 `*currentSource == ""`。

    ⚠️ **2026-08-22 对抗性复核推翻了「用空串推断」这一步，已改成去缓存里读真相。**
    `EnrichCacheStore.saveEdit` 的 `source` 参数默认 nil，而「歌词管理」里那颗「保存修改」正是
    `saveEdit(key:lyrics:tr:roma:)`（不传 source）——它 `removeValue(forKey: "lyrics_source")`，
    `writeLyricsFiles` 跟着写出不带 `[source:]` 的 .lrc，collector 再按「六字段权威源」把
    `LyricsSource` 灌回空。于是**每一条用户手改过的条目**都是「有歌词 + 来源为空」。照推断走的话，
    这道闸会对手改条目一律放行，让冠军覆盖掉人工修正过的正文——那份内容删了找不回来。

    我当初那个「294 条里 0 例外」的测量**取样取错了**：现役缓存手改条目是 0 条，因为老库那 33 条
    手改记录同一天早些时候刚被移走。在一个恰好没有反例的数据集上做的测量，证明不了不变量。

    现在 `searchcli.go` 用 `lyricsEmptyInCacheFile` **只读**地问缓存文件要事实（自己解析、不走
    `loadEnrichCache`——那个会设 `enrichPath`、解析失败还会把用户缓存改名成 `.corrupt`）。
    读不出来时 `known=false`，按最保守的那一支走，行为等同改动之前。
    `lyricsemptylookup_test.go` 覆盖四种形态，并断言这条路径**没有任何副作用**。

    ⚠️ 另有一个**先于这次改动就存在**的问题，需要产品决策、这次没动：「重新自动匹配」采纳时走的是
    `saveEdit(..., markManual: false)`，也就是说它会清掉 `manual_lyrics` 并覆盖手改正文——
    在所有启用的源都应答的场合（很常见），改动前也一样会发生。`LyricsRematchDecision.decide` 的五条
    分支里没有任何一条看 `manual_lyrics`。那颗按钮的语义注释写的是「完全交回算法管理」，所以这可能
    是有意的；但没有任何确认提示，而同一个文件里另一处注释写着「那份内容删了就找不回来，自动逻辑
    没有任何理由觉得自己比人工更懂」。要不要加确认，留给产品判断。

    放行不等于无保护，下游还有两道闸：冠军为空 → `keptNoCandidate` 什么都不写；现有这份有
    逐字而冠军没有 → `keptWouldLoseWordTiming`。`lyricsrescore_test.go` 里
    `TestRescoreDecidableNoCurrentLyrics` 同时钉住新分支**和**「自动路径口径一字未动」。

17. **QQ 的「纯音乐」明文断言被 `isTimedLRC` 在源头扔掉**（2026-08-22，用户报「蛋堡《收敛水》
    的「关键字: Intro」搜出来没歌词」）。这首 114 秒的专辑 intro **本来就是纯音乐**，五个源
    口径完全一致：

    | 源 | 实测 |
    |---|---|
    | netease | 找到了（id=76873，专辑第 1 轨、114.0s），但 `lrc` 只有 21 字符：`[00:00.00-1] 作曲 : 蛋堡`；**没有** `pureMusic` 字段；tlyric/romalrc/klyric/yrc 全空 |
    | kugou | 搜到了 hash（rank 1，`关键字：Intro`/全角冒号/114s），但 **KRC 候选 0 条** |
    | lrclib | `get` 404、`search` 0 条 |
    | **qq** | 搜到 mid，歌词接口明确回 **`[00:00:00]此歌曲为没有填词的纯音乐，请您欣赏`** |
    | musixmatch | 无候选 |

    所以「为什么搜不到」本身不是 bug。真正的缺陷是**它该显示「纯音乐」而不是「无歌词」**：
    唯一给出结论的那个源，结论在 `resolveQQLyric` 的最后一行就被丢掉了 ——

    ```go
    if l := out.Lyric; isTimedLRC(l) { return l }
    return ""          // ← 占位只有一行带戳，过不了「≥3 行且过半」，结论在这里蒸发
    ```

    后果两条：①界面上落在「无歌词 / 无来源」，跟真正的失败长得一模一样；
    ②`needsLyricsFirstFill` 会每 24 小时（退避后翻倍，上限 16 天）**白搜一轮五个源** ——
    而 `instrumental` 一旦落地，`needsLyricsFirstFill` 第一行就 return，这轮就省了。

    修法：占位判定挪到 `isTimedLRC` **之前**，`qqLyric` 的返回值从 `string` 换成
    `qqLyricResult{lrc, instrumental}`，一路透传到 `sourceResult.instrumental` 与
    `scoreAndSort` 的第三个 `instrumentalMarker` 分支。判定函数复用现成的那个（顺手从
    `isNeteasePureMusicLyric` 改名成 `isInstrumentalPlaceholderLyric`，它现在服务三个源）。

    **注意它对网易云那一行署名仍判 false**，这是对的：「只有署名行」不等于「没有词」，
    那是含糊状态；QQ 那句话才是断言。`pureinstrumental_test.go` 把这条区别一起钉住，
    并断言「占位过不了 `isTimedLRC`」这个前提本身（前提变了就该重写成因描述）。

    **规模**：当前缓存 161 条里只有这 1 条受影响；拿废纸篓里那份 619 条老库量了一遍，
    12 条无歌词条目里有 **3 条**（卢广仲「PAZ」、方大同「Over (Reprise)」、陶喆「愿主怜悯」）
    能被这条断言救出来——约四分之一。另外 8 条探针报「QQ 搜不到」，但那是探针用
    `歌手 歌名` 打 smartbox 太糙（英文曲目常返回 0 条），真实比例可能更高，**未验证**。

    **字段改名（同日补做）**：这个信号传给 App 的 key 原来叫 `lrclibInstrumental`
    （`searchLyricsUpdate`），2026-08-20 加网易云那次就已经名不副实，现在更是三个源共用。
    已改成 `instrumental`，并**保留一个同值别名过渡**——理由是 collector 和 App 是两个
    **独立部署**的二进制：`lyrimuse-collector/build.sh` 只换 collector、不重建 App，所以换了
    collector 之后跑的可能还是旧 App，而旧 App 只认旧 key；单方面改名会让「有源明确说这首是
    纯音乐」这类文案在重建 App 之前**静默退化**成「这一轮没有一个能用的候选」。两个方向都兜住：
    Go 侧同时输出 `instrumental` 与 `lrclibInstrumental`（`LegacyLrclibInstrumental`，`omitempty`，
    非纯音乐时两个 key 都不出现），Swift 侧 `RawSearchUpdate` 按
    `raw.instrumental ?? raw.lrclibInstrumental ?? false` 读（兜住「新 App + 旧 collector」）。

    ⚠️ **别让别名长住**：App 带着新解码重新构建并安装之后，`LegacyLrclibInstrumental`
    和 Swift 侧的 `lrclibInstrumental` 都可以删掉——那是它们唯一的存在理由，删除条件写在
    `searchcli.go` 那个字段的注释里。

    ⚠️ 注意 Swift 的**对外**类型（`SearchUpdate.instrumental`）一直就叫对了，只有解码用的
    raw 结构体沿用旧名，所以这次改动面只有 Go 一个字段 + Swift 两处。
18. **接入 lyricfind 之后一次真实数据抽样调研,顺带揪出两个跟 lyricfind 本身无关的共享
    基础设施缺口**（2026-08-26）。25 首真实曲库抽样命中率仅 20%、0 次真正胜出、0 次独家
    补漏——排查确认**不是集成/传参 bug**（`enrich.go` 调用点参数逐字段核对无误,filter/
    三跳流程/繁简修复全部工作正常),命中率低主要是"这个源本来就跟已有源高度重复"(接入前
    调研已有的结论)。但排查过程用真实曲库案例暴露了两个此前没人踩到、影响全部七个源的
    存量缺口:

    - **歌手闸缺"去括号别名"规则,标题闸早就有**（「聪明不聪明」案）。YouTube Music 给的
      艺人字段是 `丁世光(Dean Ting)`——主名字后面括号跟一个外文别名,`lyricTitleAccepted`
      早就对标题做「`stripParens` 再比」，`artistMatches`/`lyricSourceArtistMatches` 却没有
      对应规则，这串又没有 `artistCreditParts` 认的分隔符（切不开、够不着段集交集档），
      于是这条正确候选被原地拒收。修法：`artistMatches` 补一档「两侧各自去一次括号,变了
      就递归比一次」的兜底，跟 `toSimplified` 那档挂在同一个函数、同一个理由，不影响
      「周杰伦-」式仿冒防线（括号别名和尾随分隔符是两种形状,前者是同一个人的补充说明,
      后者才是仿冒特征）。**实测坐实**（真实网络请求逐级 trace）：修前 `ytmusicPickSearchItem`
      在艺人闸拒收该视频；修后正确 accept，一路查到 `browseId` 拿到真实歌词内容——只是这条
      视频恰好是 `Source: Musixmatch`（被 `ytmusicIsLyricFindSource` 按设计过滤），跟本条
      bug 无关，是另一层设计生效。
    - **版本限定词表只认拉丁词,没有中文对应**（「蜗牛 (伴奏)」案）。`distinctRecordingVersionTags`
      收了 `instrumental` 却没收「伴奏」，本地标题写「(伴奏)」时 `titleVersionTags`/
      `versionTagsMismatch` 抽出空集、-600 不触发，正常演唱版被当成对版收了。这个洞对**全部
      七个源一视同仁**，不是 lyricfind 专属，只是被它先撞上——QQ 这次赢是因为内容本身对，
      不是躲开了这个漏洞。修法：补一批中文限定词（现场/不插电/伴奏/纯音乐/清唱/混音/加长版/
      阿卡贝拉/排练，同样只收歧义低、题材明确的词，不收"翻唱"这类含义太宽的）。⚠️
      `segmentVersionTags`（`titleMatchTierPoints` 用的 v3 helper）跟 `titleVersionTags`
      算法不同——它按"非字母数字切词后比连续词序列"识别拉丁短语，而中文没有空格分词，
      "伴奏版"整段会被切成一个词元、永远不等于裸词"伴奏"，这套算法对中文限定词恒假阴性；
      按 tag 是否纯 ASCII 分流，中文词退回子串匹配（跟 `titleVersionTags` 一致），拉丁词
      算法原样不动。**实测坐实**：修前 `ytmusicPickSearchItem` 会接受正常演唱版当候选（对应
      同一问题在其它源上的表现是打分被扣到 1 分，而不是从一开始就拒收）；修后 `versionTagsMismatch`
      在搜索阶段就正确判 `true`，把不对版的候选挡在门外,不再产生内容和时间轴都对不上的
      候选。

    两个都是**修被撞开的洞,不是给 lyricfind 单独开小灶**——netease/qq/kugou 等老源同样受益，
    只是样本量不够大、一直没撞上边界情况。
19. **专辑预取会把专辑里混的 music video 花絮也送去问七个歌词源**（2026-08-26，用户报
    「Michael Jackson《XSCAPE Documentary》/《XSCAPE Documentary Outtakes》搜不到歌词」）。
    这两条是 `XSCAPE (Deluxe)` 第 18/19 轨,Apple 官方目录里 `kind` 字段是 `music-video`
    不是 `song`——本来就是纪录片/花絮视频,不是歌,结构性没有歌词可言。查了 Apple Music
    本地库里对应的 `track`,`media kind` 属性同样是 `"music video"`（对比普通曲目是
    `"song"`）。

    `albumTracksFromMusicApp`（albumprefetch.go）原来的 AppleScript 只按 `album is X`
    筛,`track` 是覆盖音频/视频的通用类,于是这两条花絮也被当成"同专辑还没解析的曲目"一起
    预取,拿去问全部七个源——注定全军覆没,还会占满 `needsLyricsFirstFill` 的重试配额、
    拖长退避周期（16 天上限内每次都是白跑）。修法:whose 子句加一档 `and media kind is
    song`。用**白名单**（只收 song）而不是拉黑名单排除 music video——防的是"漏收一种没
    想到的非歌曲媒体类型"（有声书/播客/铃声等同样没有"歌词"这个概念），比逐个排除更稳。
    **实测坐实**：改前 `albumTracksFromMusicApp("XSCAPE (Deluxe)")` 返回 19 条（含两条
    花絮），改后返回 17 条，两条 Documentary 曲目被正确排除，其余 17 首曲目名/歌手/时长
    不变。

    这条只挡**新增**的预取请求——已经在缓存里的这两条陈旧「无歌词」条目不会自动清掉，
    要靠现有的退避机制自然过期，或手动删除/忽略。

20. **逐字时间轴的 +400 能压过标题都对不上号的候选**（2026-08-27，用户报「方大同《公园》
    匹配错歌了，应该是第二个才对，第一个是 Timeless 演唱会的版本」）。冠军酷狗那份标题
    「公园 (Live)」、专辑「Timeless演唱会」——是**另一场演出**的逐字版本；亚军网易云那份
    标题「公园 (Live版)」跟查询词逐字相同、专辑也部分对得上（「方大同·专场」），但没有
    逐字数据，944 分打不过 674 分，分差几乎全部来自 wordTiming 那 400 分
    （170+64+60+250=544 vs 169+60+75+120+250=674）。同一次现场（`大事发声·录音棚现场:
    方大同专场`）实际录了不止一首，用户报告之外还牵连《Catch a Dream》《南音》《如果爱》
    三首——四首歌全是同一个模式：酷狗那份逐字数据是按别的演出录的，套在这次实际播放的
    录音上时间轴对不上。

    **400 分本身不该下调**：拿真实曲库（1818 首，868 条完整解析记录）做过反事实消融，
    wordTiming 是决定性因素（去掉它冠军就换人）的案例有 240 个，占全部决策的 27.9%——
    权重很重，broad 调低会牵连其中绝大多数本来选对的案例（118 个"专辑分反而支持亚军"的
    案例抽查后基本是`(Explicit)`这类标签差异的噪音，不是真的选错版本）。但**标题吻合分
    也站在亚军那边**的只有 2 个（0.83%），且两个都是货真价实的版本误配（这个案例，以及
    一首迈克尔·杰克逊单曲版误混进原声带完整版的案例），titleMatch 这条判据 0 误报。

    修法（`applyWordTimingTitleOverride`，v5，`lyricsScoringVersion` 4→5）：全部候选打完
    分、排序前收尾一步，三条同时成立才触发——①当前冠军（排除一票否决/纯音乐标记）带
    wordTiming 加分；②去掉这份 +400，会有另一个真实候选反超；③那个候选的 titleMatch
    分严格高于冠军。命中就把冠军的 wordTiming 加分**整段撤销**（多出一条
    `wordTimingOverride` 负分项，界面上看得到），不是打折、不是直接判它无效——跟 overshoot
    那档「物理矛盾不吃跨源印证豁免」是同一个道理：标题都对不上号，逐字时间轴转写得再细
    也不能证明这是同一次录音。

    ⚠️ 窄口子刻意开在 **titleMatch**，不是专辑名：118 个"专辑分反而支持亚军"的案例里，
    绝大多数是 `petal (Explicit)` vs `petal` 这类同一张专辑的标签差异，专辑打分器只做
    字符串比对，标签不一致就从「精确匹配」（150 分）掉到「部分匹配」（75 分），但内容
    其实是同一次发行——拿专辑分当判据会大量误伤本来选对的候选。titleMatch 反超的只有
    2 个，且 100% 是真问题，是这批候选里噪音最小的信号。

    **两个入口都要过这道闸**：`scoreAndSort`（enrich.go 主路径）和
    `mergeLyricCandidateRounds`（首歌手变体轮合并重打分那条路径）都调用了
    `scoreLyricCandidateDetailed`，两处都在排序前插了 `applyWordTimingTitleOverride`——
    否则同一首歌走没走变体轮，判定标准会不一致。手动「搜索候选歌词」（`search-lyrics`
    CLI）复用的是同一个 `scoreAndSort` 闭包，不需要额外改。

    **实测结果**：对 868 条完整解析记录跑改动前后对比，**5 个决策的冠军真的换人**
    （0.58%），全部是同一批"版本误配"修对了，**0 个误伤**——除了用户报告的那首，同一场
    「大事发声·录音棚现场」的另外三首也一并修好，改之前用户和我都不知道还有这三首中招。

21. **用户主动取消不能被网络健康度分类误报成"网络不通"**（2026-08-28,加「停止搜索」时
    预先排掉的一个坑,没等它真的发生过)。`resolveEnrichAsync` 的 `defer` 之后紧跟着
    `roundStat()`/`roundLooksNetworkDown` 这段——统计这一轮发出去的请求有多少失败,失败比例
    过高就 `markCollectorNetworkDown()`,驱动 App 侧把"搜索歌词中…"换成"网络连接失败"
    (第 15 章)。用户点「停止搜索」时,ctx 被取消会让**全部还在飞的请求同时失败**——如果不
    做区分,这条分类逻辑会把"我们自己叫停的"错判成"网络整体不通",在用户主动操作之后立刻
    弹出一条误导性的网络故障提示。修法是在 `roundStat()` 取值**之前**插一道
    `if ctx.Err() != nil { ...; return }`——被取消的这一轮直接跳过网络健康度分类,把
    "我们主动中止"和"网络真的坏了"这两件事在源头分开,不指望下游任何地方去反推"这次
    失败是不是因为取消"。⚠️ **这个分支现在会写缓存**(第 24 条,2026-08-28 后补)——
    当初这里写的是"也不写缓存",是那次改动上线时的真实状态,后来按用户反馈改掉了,这条
    历史记录不改字面、只在这里加一句更正,别处如果还提到"取消不写缓存"都以第 24 条为准。

22. **别名重试轮裸传 `onUpdate`,「搜索候选歌词」弹窗先出结果、又刷没、再自动出现**
    （2026-08-28,用户报「这里为什么搜索的时候会先搜到记录,然后刷没了,又自动重新搜
    然后搜到这条」,方大同《爱爱爱》原名 `Khalil Fong` 案:LRCLIB 命中一条候选但分数 -1,
    `hasUsableLyricCandidate` 判"不可用"触发上面"歌手别名重试",别名轮开始后候选列表
    先清空,别名轮自己也查到同一条时才重新出现)。`scoredLyricCandidatesStreaming` 顶部
    这个别名重试循环(`dedupeArtistIdentities` + `retryArtistIdentities`)一直把 `onUpdate`
    裸透传给别名这一轮的 `fetchScoredLyricCandidatesStreaming`——而这一轮是**全新一次**
    8 路并发,从零开始,自己的源一个个陆续应答;裸透传意味着弹窗看到的是"别名轮自己截至
    目前查到的东西",不是"目前已知的全部信息",原名轮已经展示出来的候选会被这一轮初期的
    空/半状态直接覆盖掉。同一个函数下面的"首歌手变体轮"（`tryVariant`）早就有过完全
    相同的教训、也已经修过——`mergedUpdate` 闭包把变体轮的流式更新先与已有 `results`
    合并（`mergeLyricCandidateRounds`）再喂给 `onUpdate`；只是那次修复没有同步应用到
    这个更早的别名重试循环,两条姊妹路径一个有闸一个没有。
    修法是同样的闭包包一层（`aliasUpdate`）,别名轮的每次流式更新都先跟当前 `results`
    合并再上报，用 `search-lyrics` CLI 复现原查询（`Khalil Fong`/`Love Love Love`/
    `This Love`）验证：改前别名轮初期会有若干行候选数掉回 0,改后候选数在整个别名轮
    期间稳定为 1，不再闪烁。**这一轮最终会不会真的替换 `results`**（`hasUsableLyricCandidate`
    命中就整份换、否则维持原名轮结果）的决策逻辑本身不受影响,只是流式展示不再抖动。





23. **同一个候选可以带着两套互相矛盾的时间轴，而所有时长判据都只看末句、看不见**
    （2026-08-27，用户报 Adele《Rumour Has It》「明显进度对不上」）。Musixmatch 在同一个
    `track_id` 下挂着两份**不同年份做的**资产：`track.subtitle.get` 那份行级 LRC
    （2023-01-29 制、自报 215s）与 `track.richsync.get` 那份逐字（2026-06-21 制、自报
    232s），曲长实际 223.3s。实调把两边原始 body 拉回来比 sha256，证实都是上游原样落库、
    我们零清洗——**坏的是上游数据本身**。这份坏 LRC 单调递增、末句时间戳也正常
    （204.81s），坏只坏在**内部**：第 27→28 行凭空跳 48.6 秒，第 41~49 行 9 句完整长句挤在
    6.86 秒里（同样这 9 句在 richsync 里跨 46 秒）。而 `durationFits` /
    `corroboratedEndings` / `sourceDurationOff` **全都只读末句这一个标量**，25% 容差对这首
    歌意味着 167~228s 这个 61 秒宽的窗口全算「吻合」——端点判据在原理上就看不见这种坏法。
    唯一一道 LRC↔YRC 交叉检查 `usableWordTiming` 又是**单向**的（只防 YRC 被截断，
    `yrcEnd >= lrcEnd*0.5`，本例 221443 >= 107100 轻松过关），于是这条候选带着 +400 逐字分
    以 1216 分夺冠、正文却是那份坏 LRC。冠亚只差 28 分，胜负手是 `album 150 vs 75`
    （"21" vs "21 (Explicit)"）——**唯一察觉到不对劲的信号是 duration 只拿 233 分、比 kugou
    低 31**，被专辑名精确匹配压过去了。

    **为什么最后选的是「修数据」而不是「改打分」。** 先做的是后者：把
    `simeval_test.go` 里 `deltaWordTimingCoverage` 那道**从没进过引擎**的自洽闸拆出来单独
    消融，结果直接否掉了它——端点判据 15s 阈值下 36 条翻盘里 **34 条是误杀**，因为
    `lastLRCTimestampSecs` 只跳空行、不跳署名行，网易云 LRC 末尾那行
    `[08:36.866] 人声 : Prince` 让《Purple Rain》的端点差算成 292.4s，而两套轴对真实歌词行
    只差 0.2s。改用逐行中位偏差（skewGate）判据后 3s 阈值 2 条翻盘 0 回归，但落地要
    bump `lyricsScoringVersion` 5→6，全库存量会被 `needsLyricsRescore` 拖去各重跑一轮
    五源检索。而实测发现 **musixmatch 的 86 条双轴条目里，LRC 与 YRC 逐行文本 100% 相同、
    行数 100% 相同**——`subtitle.get` 那趟请求除了带回一份坏时间轴，没提供任何 richsync
    没有的信息。既然文本一一对应，直接把行级时间戳换成逐字轴的行起点即可：不换源、
    不动打分判据、**不需要 bump**。反事实消融（784 首 / 3063 候选）两条路都是 2 翻盘
    0 回归，但修数据这条里《Rumour Has It》**不翻盘**——它保住冠军、时间轴被修好，
    比换成 kugou 更优。实现见 `lyricstimeline.go`，判据自己划出适用范围、不按源写死白名单
    （kugou 710/714 满足前提但本来就自洽、重挂是空操作；netease 只有 24/568 满足——它的
    两份是**根本不同的资产**，判据会自动放弃）。

    **两道必须有的闸。** ①「以逐字轴为准」不是无条件成立的：消融过程抓到反例 MJ
    《Rock With You (Single Version)》（曲长 204.2s），两套轴同样打架（skew 15.7s）但坏的是
    **YRC** 那边——重挂后末句从 176.1s 跳到 216.6s，尾巴甩出曲目 12 秒。闸就用现成的
    `durationFits`：重挂后不允许从 true 变 false，不新造判据。②**曲长未知时直接放弃**——
    闸校验不了就不赌。本机 41 条满足前提的条目里有 22 条属于这种（从没真正播放过、缓存
    里没记时长），其中《大内低手》重挂后末句会从 190.31s 缩到 140.18s，到底是 LRC 多转写
    了 50 秒还是 YRC 少覆盖了 50 秒，没有曲长根本判不了；这些条目等它真正被播放时（那条
    路径带着 `durationSecs` 走 `rehangCandidateTimelines`）自然会修。加上这两道闸后，本机
    实际会被重挂 **19 条**（musixmatch 14 + netease 5）：真打架 3 条、亚秒级微调 16 条，
    `Rock With You` 被闸挡下。

    **写这段代码时踩的两个坑，都值得单独记。** ①抓 YRC 词文本**不能**用
    `\((\d+),(\d+),\d+\)([^(]*)` 这种「标记后面跟非左括号」的写法——歌词正文里本来就有
    字面左括号（和声标注），`[^(]*` 会在它那里截断。实测《Rumour Has It》第 14 行
    `(59954,1182,0)(rumour)` 被解析成空串，整行从 "Rumour has it (rumour)" 缩成
    "Rumour has it"，于是与 LRC 侧字面对不上、本该重挂的条目被静默放弃；更坏的是这个 bug
    一度让人误判「两份文本也不同」，差点否掉整条路线。正确做法是**把标记整体删掉、剩下
    的就是文本**（`yrcLineHeads`）。②重挂**只能替换时间戳、必须原样保留元数据行与空行**：
    打分的 lines 项按 `len(strings.Split(lyrics,"\n"))` 计分（`match.go`），把 `[ti:]`/`[ar:]`
    和空行也数进去；第一版「按内容行重新生成整个文件」把它们丢了，消融里造出 **175 条假
    翻盘**、其中 139 条是 kugou→qq（全库最干净的源反而集体掉分被反超）。修数据的改动必须
    只动该动的那一维。③幂等要带容差：输出格式 `[mm:ss.xx]` 只到百分秒，18315ms 写出去是
    `[00:18.31]`、读回来成 18310ms，按精确相等判的话启动期迁移会**每次开机重写一遍整份
    缓存**（单测 `TestRehangLRCOnYRCIdempotent` 抓到的就是这个）。

24. **「停止搜索」取消后不该什么都不写——要落定成"暂无歌词"，不是让这首歌凭空消失**
    （2026-08-28，用户反馈：「点击停止搜索之后，不是直接删除记录，而是保留记录，标记为
    无歌词；并且灵动岛和桌面悬浮歌词都不再继续提示搜索歌词中」）。第 21 条上线时
    `ctx.Err() != nil` 分支是纯粹的 `return`，什么都不写——这是当时故意的设计（"e 大概率
    残缺，不写缓存"），但带来两个后果都不是用户想要的：①「歌词管理」列表里这首歌彻底
    消失，直到下次重新播放才会重新出现；②`EnrichCacheReader.lookup` 找不到这个 key 就
    返回 `nil`，`resolved` 恒为 `false`，灵动岛/桌面悬浮歌词/歌词窗口三处（它们共享同一套
    判断逻辑，见下面代码锚点）会一直卡在"搜索歌词中…"，跟这首歌从没搜索过时一模一样。

    **修法：取消分支跟"自然查无"走同一条落盘路径**，只是不经过下面那道"全空不写入"
    守卫（自然查无靠它避免偶发网络抽风被永久钉死成"没有"，但取消场景**恰恰**多半是全空
    的——网络请求被 `ctx.Done()` 中断后基本来不及拿到任何字段，如果也被这道守卫拦住，
    等于绕了一圈又回到"什么都不写"）。两条路径共用的收尾（写缓存/落盘/导出歌词文件/
    通知 poll 重推）抽成 `commitEnrichEntry(key, e)`，取消分支直接调用它。`e.TS` 在
    `ctx.Err()` 判断之前就已经赋值（`resolveTrackEnrichment` 返回后立即 `e.TS =
    time.Now().Unix()`），所以这条记录天然满足 `EnrichCacheReader.lookup` 判定
    "已经解析完"的条件（`resolved: (entry.ts ?? 0) > 0`）——不需要额外发明一个"用户主动
    取消"专属字段，写出来的记录跟"联网查过、确实没有歌词"在数据形状上完全一样，也就
    自然继承了同一条自愈路径：`needsLyricsFirstFill` 会在 24h 起始的指数退避后自动重搜，
    不是永久判死。

    ⚠️ **Swift 侧配套要修一处，不是零改动**：`LyricsManagerView.cancelPlaceholderSearch()`
    原来写完取消信号立刻把 `placeholderSummary` 清空（乐观 UI）。这本身没问题，但
    `.task` 里那个负责"占位行等 collector 写完就自动让位"的 5 秒轮询，guard 条件正是
    `placeholderSummary != nil`（见该 `.task` 注释）——清空之后这个轮询直接停摆，不会
    再去问磁盘，collector 刚写完的"暂无歌词"记录也就没人去捡，除非用户凑巧做了换歌/
    重开窗口之类别的触发 reload 的操作。改法是**不清空**，让占位行继续挂着，等现成的
    5 秒轮询探测到 `store.hasEntry(forKey:)` 变 true，`refreshPlaceholder()` 里已有的
    "真实条目出现就让位"逻辑自然接手，把这一行换成正常的、标着"无歌词"的记录——不需要
    引入任何新状态。

    **灵动岛/桌面悬浮歌词反而不需要碰**：它们走的是完全独立的一套刷新节奏
    （`LocalPlaybackSource` 的 2 秒轮询，靠 enrich 缓存文件的 mtime 变化触发重读，见
    `LocalPlaybackSource.swift` 里 `trackChanged || !syncEngine.hasContent || enrichMTime
    != lastEnrichMTime` 那段），不依赖"歌词管理"窗口开不开。collector 落盘这个动作本身
    就会改变文件 mtime，下一拍轮询会自动重新读取、算出 `currentTrackHasNoLyrics = true`，
    从"搜索歌词中…"切到"暂无歌词"——四个界面（灵动岛/悬浮窗/歌词窗口/菜单栏面板）
    共享同一条 `PlaybackCoordinator` 转发链路，改一处生效四处，这也是为什么这条修复
    只用改 collector 一侧就够（唯一的 Swift 改动是上面那处"别提前清空占位符"）。

    **验证**：新加的 `TestResolveEnrichAsyncCancelWritesNoLyricsEntry`（enrichcancel_test.go）
    用一个**调用前就已取消**的 context 直接跑一遍 `resolveEnrichAsync`，断言最终
    `enrichCache` 里有一条 `lyrics==""、ts>0` 的记录——net/http 在 ctx 已 `Done()` 时
    会在 `RoundTrip` 阶段直接返回 `ctx.Err()`，不会真的建立连接，这条测试因此不联网、
    耗时在毫秒级，顺带也是"ctx 取消真的贯穿到全部九个网络源"这条已有能力的第一条
    自动化回归测试。

25. **歌手用罗马化艺名时,语言闸只看字符集、测不出"这首歌到底是不是中文歌"**
    （2026-08-28，用户在「搜索候选歌词」弹窗里看到方大同《南音》的正确候选被判
    "不可用：语言跟这首歌对不上"）。`isProbablyWrongLanguageLyrics`（第 3 节歌手闸/
    语言闸那一档）的原判据是"本地 artist/title 都不含汉字、候选歌词却大半是中文 →
    判定语言不对,一票否决"——这条 Apple Music 曲目本地标签罗马化写成
    `artist="Khalil Fong" title="Nanyin"`，两者都不含汉字，候选（LRCLIB）内容是这首歌
    真正的繁体中文歌词，被误杀成 Score -1，永远进不了自动解析的候选池（`pickLyricCandidate`
    只从 Score≥0 的候选里选）。⚠️ 这跟第 22 条不是同一类问题：那条是"流式展示中间态
    被覆盖"的 UI 层 bug，候选最终会被正确采纳；这条是候选**本身在打分层就被永久错判**，
    自动路径永远不会选中它，手动「搜索候选歌词」里虽然按钮没有禁用、理论上能强制采用，
    但用户看到"不可用"字样通常不会去点。

    根因是这个判据只测得到"标签写法用的是什么字符集"，测不出"这首歌本身该是什么语言"——
    这两件事在"华语歌手用罗马化/英文艺名"这一类曲目上是脱钩的。修法补两道豁免（任一
    成立即不拦）：
      - **candidateArtist**（候选源自己确认匹配到的那位歌手的名字，各源报的是自己曲库
        里的写法）含汉字——候选进打分之前已经过了各源自己的歌手身份闸（第 3 节"歌手闸
        三档"），这个信号不是瞎猜的。⚠️ 对方大同这个真实案例本身**没有生效**：LRCLIB
        索引这首歌的元数据本身就是罗马化写法，candidateArtist 同样是"Khalil Fong"，没有
        中文数据可给。留着这道豁免是因为它能覆盖另一类更常见的场景——候选来自
        qq/kugou/netease 这类天然用中文曲库索引的源。
      - **knownArtistAlias(localArtist)**——手工登记表 `artistAliasTable`（同一张表也在
        给 `retryArtistIdentities`/canonical_artist 兜底）里已经登记了
        `"khalil fong": "方大同"`，这才是真正救回这个案例的信号。这道豁免天生受限于
        这张表的覆盖面（极小、纯手工），遇到"某罗马化艺名 + 候选源也没有中文数据"的
        新案例要继续往表里补条目，函数自己推导不出来。
    两道豁免都基于既有的 `cjkRatio` 恒等式，空字符串（旧调用点/测试没传 candidateArtist，
    或者 localArtist 不在表里）时 `cjkRatio` 恒为 0，不触发豁免，行为跟改动前逐字节一致。

    **`lyricsScoringVersion` 4→~~5~~→6**：这是判定层面的改动（不是权重调整），按约定
    必须 bump——已经因为这个 bug 被误杀过的存量条目（歌词字段常年是空的、或者用了一份
    本该被这条更好的候选顶替的次优结果）会在下次播放时自动重搜一轮，不需要用户手动
    "重新自动匹配"。**实测验证**：用 `search-lyrics` CLI 复现原始案例
    （`Khalil Fong`/`Nanyin`/`Soulboy`），改前 LRCLIB 候选 `score=-1`，改后
    `score=320`——同一份数据，唯一变化是不再被语言闸一票否决。新增单测
    `TestIsProbablyWrongLanguageLyrics`（match_test.go）覆盖两道豁免各自命中/不命中
    的组合，用一个**不在**别名表里的虚构罗马化名字确保"没有任何救援信号时依然维持
    原判"这一档不会被表里恰好登记过的真实歌手悄悄救回去。

26. **接入酷我时验证坐实：这不是个别案例，是系统性的搜索结果构成问题**（2026-08-31）。
    接入前的调研已经指出周杰伦《稻香》、BEYOND《海阔天空》等 4 首歌原版录音室版本不进
    Kuwo 搜索结果前排；接入后又拿真实网络请求验证了一轮，扩大到邓紫棋《光年之外》、
    陈粒《奇妙能力歌》、房东的猫《云烟成雨》等更多曲目——**结论一致**：`海阔天空`
    直接 curl `search.kuwo.cn/r.s`，`rn=10` 的前 10 条清一色是 DJ 改编/演唱会现场/翻唱/
    片段，原版一条没有；把 `稻香` 的 `rn` 拉到 30 依然一个没有，前排反而挤满同一首歌的
    十几个不同翻唱者版本。这印证了接入设计里"不信 Kuwo 排序、自己重新打分"这条防线
    (`kuwoCandidateScore`) 是必要的，不是过度设计——对这类头部歌手的热门曲目，酷我这一路
    大概率整轮查询都拿不到候选(全部被身份闸正确拒收),这是**预期表现**，不是 bug。
    ⚠️ **别把"这首歌 kuwo 没有候选"误判成接入坏了**：先用 `search-lyrics` CLI 或直接
    curl 搜索接口确认 Kuwo 本身是否真的收录了原版（多数头部歌手的答案是"没有"），再去
    查代码。fetch/解析/`isTimedLRC` 这条链路本身已经拿一个真实存在的 `musicId`
    （房东的猫《云烟成雨(Live)》,`MUSIC_331593136`）单独验证过、逐字节核对 LRC 输出正确——
    kuwo 这一路目前的低命中率来源是 Kuwo 自己的曲库构成，不是 `kuwo.go` 的解析逻辑。

    ⚠️ **2026-08-31 订正**：本条"全部被身份闸正确拒收"这句断言被下面第 27 条推翻了一
    半——版本限定词表当时认不出"DJ+人名+版"这个模式,大量 DJ 改编版顶着原唱歌手名混过了
    身份闸,只是靠**下游** enrich.go 的时长/共识打分才没有真的赢过 qq/酷狗(候选进了列表,
    没进最终结果)。全库扫描量出来的真实构成是 125 首命中里 94 首(75%)靠这个漏洞才有
    候选,不是"全部正确拒收"。这条记录的"Kuwo 搜索结果构成本身很差"这个结论仍然成立,
    只是"身份闸挡住了全部错版本"这半句不成立,已在第 27 条修正。

27. **真 bug：版本限定词表认不出"DJ+人名+版"这个模式,DJ 改编版顶着原唱歌手名混过了
    身份闸**（2026-08-31，用户看完第 26 条的核查报告后要求"拿整个歌词库测一遍酷我"）。

    全库扫描（真实网络请求，用户 2641 首歌词缓存逐一查酷我，见下面"扫描本身踩过的坑"）
    量出 125 首"命中"，但逐条核对候选的 `matchedTitle` 后发现其中 **94 首(75%)** 拿到的
    根本不是原版——酷我上有多个 DJ 把周杰伦(尤其严重,一个人占了小一半)、王力宏、林俊杰、
    方大同、孙燕姿、蔡健雅等一大批歌手的热门曲目重新混音上传成"歌名 (DJ 阿若版)"这类
    命名，`SongName`/`ARTIST` 字段依然写的是原唱本人。根因：`distinctRecordingVersionTags`
    （match.go）是固定字符串表，"DJ 阿若/阿树/阿罗/阿喜/糖糖/小阿龙/胧驿/王小龙/凯西/Ray"
    这些是不同 DJ 各自的艺名，列不完、也不该列——需要按**模式**认，不是按固定词表收。

    修法：加一个专门的正则 `djRemixTagPattern = regexp.MustCompile(`(?i)dj[\p{L}0-9.]*版`)`
    （`\p{L}` 认任意 Unicode 字母，不能只收中文——第一版试过 `[\p{Han}0-9.]*`，漏了
    "稻香 (完整版|DJ Ray版)" 这条，DJ 艺名是拉丁字母"Ray"，字符类里没有拉丁字母，一条
    命中都测不出来，靠再跑一遍真实验证才发现这个二次漏洞），命中时写入一个规范化 key
    `djRemixVersionTag = "dj混音"` 到 `titleVersionTags`/`segmentVersionTags` 各自的返回
    集合里——两个函数都要改，跟第 18 条踩过的教训一样：一个漏了另一个没漏，两处行为就会
    分裂（这次是同一次改动里一起补的，不是分两次踩坑）。这个 key 走的是 `versionTagsMismatch`
    既有的集合比较机制（本地没有 DJ 标记、候选有 ⇒ 两边集合大小不等 ⇒ 判不匹配），不需要
    新增任何比较逻辑。

    **验证**：改前 `search-lyrics -artist 周杰伦 -title 稻香` 的 kuwo 候选是"稻香 (DJ 王小龙
    版)"，改后 kuwo 从候选列表里完全消失（`kugou`/`qq`/`lrclib` 三个不受影响）；同时确认
    没有误伤——`卢广仲/100种生活`(干净原唱匹配)、`梦然/少年`(healthcheck 探测曲，见第 14
    章第 16 条)两个不带 DJ 标记的真实候选改动前后分数不变，仍然正常出现。全量 `go test`
    (含 `TestTitleVersionTags`/`TestVersionTagsMismatch`/`TestVersionTagsCoverClubMixFamily`
    等既有版本限定词回归测试)跑过，只有已知跟本次改动无关的 musicbrainz.org 活网络偶发
    503 flaky 测试（见第 09 章开头惯例说明）。

    ⚠️ **扫描本身踩过的坑，记下来别再犯**：第一次全库扫描用了 10 个并发 goroutine，瞬时
    打出约 76 req/s 打向 `search.kuwo.cn`，2641 次请求里 2430 次(92%)直接被 403 拒绝——
    对第三方接口来说这跟简易 DoS 没什么区别。改成**完全串行 + 每首间隔 300ms**重新跑了
    一遍，2641 次请求 0 个 403，全部拿到真实数据，耗时约 24 分钟。教训：对没有官方批量
    查询接口的第三方服务做全量扫描，默认串行 + 显式限速，不要凑并发数图快——这条经验同
    第 09 章"网络"部分和第 15 章网络审计的既有精神一致，只是这次是我自己撞上的，不是
    读文档提前避开的。

    ⚠️ **这条不是"kuwo 接入本身有 bug"**：`kuwo.go` 自己的搜索/取词/构建 LRC 这条链路
    一直是对的（第 26 条已经验证过），漏的是它跟别的六个源共用的 `match.go` 版本限定词
    表——netease/qq/kugou/lyricfind 理论上会受益于同一处修复，只是它们各自的曲库里目前
    没有撞上"DJ+人名+版"这种命名的真实案例（酷我这次撞上纯粹是因为它自己的曲库构成，
    跟第 18 条"两个都是修被撞开的洞,不是给 lyricfind 单独开小灶"是同一个道理）。

28. **QQ/酷狗/酷我三个源接上了各自的真封面**（2026-08-31，用户在"搜索候选歌词"弹窗里
    看到某首冷门单曲 4 条候选清一色顶着同一张 Apple 兜底封面，追问"这些源的封面取值逻辑
    是怎样的、有没有办法拿到各源自己的封面、LyricsX 是怎么处理的"）。

    排查坐实：`coverOrFallback` 这道兜底(见上面 `scoreAndSort` 里的实现)一直是对的——
    QQ/酷狗/LRCLIB 三个源原来传的都是空字符串当"自己的封面"，无条件退到 Apple Music/
    iTunes 那一路通用兜底。但 QQ/酷狗**并不是没有封面数据可拿**，只是没接：
    - **QQ**：`qqSongCoverAndSinger`（`qq.go`）早就写好、一直只被 `qqCoverFallback`
      （`resolveTrackEnrichment` 那条独立的封面兜底路径）调用，`enrich.go` 的歌词候选路径
      从没用过它——纯粹是接线漏了，不是没有数据源。qqMid 这时已经过身份闸校验，不需要像
      `qqCoverFallback` 那样再核对 singer。
    - **酷狗**：搜索接口本身确实没有封面字段（`kugouSong` 那条旧注释是对的），但搜索结果
      带的 `album_id` 能换一次 `mobilecdn.kugou.com/api/v3/album/info` 接口拿到
      `imgurl`——这是**新验证出来的**一条路，之前没人试过，不是"接线漏了"。`imgurl` 是带
      `{size}` 占位符的模板，需要替换成具体像素数（用了 480）才能直接访问。
    - **酷我**：搜索响应本身就带 `web_albumpic_short` 字段（形如
      `"120/38/70/3416909732.jpg"`，首段是尺寸），`kuwoSearchItem` 之前没有对应字段去解码，
      纯粹是数据摆在那没捡；换算成 URL 时把首段换成 500 拿大图。

    **LRCLIB/AMLL 结构性做不到**：LRCLIB 整个 API 响应（`/api/get`、`/api/search`）里
    没有任何封面/图片字段，纯歌词数据库；AMLL 拉的是 TTML 文件，格式本身只携带时间轴/
    演唱者/译文信息，没有图片数据可挖。这两个不是"没接"，是真的没有。

    **参考 LyricsX 的结论**（翻过 `ddddxxx/LyricsKit`/`ddddxxx/LyricsX` 真实源码）：它比
    这个项目现在的方案更"糙"——**没有共享兜底这个概念**。只有 NetEase/QQ 两个源会填自己的
    封面（`NetEase.swift`/`QQMusic.swift`，都是从各自 API 拿，QQ 甚至就是同一套
    `http://imgcache.qq.com/music/photo/album/<id%100>/<id>.jpg` 拼接思路），Kugou 提供方
    完全没接封面（跟这个项目改之前的状态一样）。没有封面时它显示一张固定的 `missing_
    artwork` 占位图标，不会去借别的源或者查 Apple/iTunes 补一张——而且它界面上只有一个
    大图（跟着当前选中的候选切换），不是每一行一张缩略图。**结论**：这个项目"自己没有就
    借 Apple 封面"的兜底本身已经比 LyricsX 更周到，用户看到的"4 条候选长得一样"不是该学
    LyricsX 改掉的设计缺陷，而是"源自己没封面 + Apple 那边刚好也没查到"这种双重落空的
    冷门曲目——接上 QQ/酷狗/酷我三个源的真封面后，这种巧合会显著变少，但不会绝对消失
    （LRCLIB/AMLL 结构性只能走兜底，且任何源在冷门曲目上都可能真的查不到）。

    **验证**：`search-lyrics -artist "New Edition" -title "Mr. Telephone Man"`——改前
    qq/kugou 两条候选的 `cover_url` 都是同一个 Apple 域名，改后 qq 变成
    `y.qq.com/music/photo_new/...`、kugou 变成 `imge.kugou.com/stdmusic/...`，各自独立；
    `search-lyrics -artist 梦然 -title 少年` 验证 kuwo 候选的 `cover_url` 变成
    `img1.kuwo.cn/star/albumcover/...`。三个都实测确认是真的各源自己的图，不是巧合重复。
    全量 `go test` 跑过（只有本章开头惯例说明的 musicbrainz.org 活网络偶发 503 flaky，
    跟这次改动无关）。

    ⚠️ **紧接着的真 bug：酷狗那条候选装机后仍然是空白占位图，不是没改对**（用户截图
    「The Immortal Intro」——netease 那条有缩略图、酷狗那条是空的）。根因：酷狗
    `album/info` 接口原样返回的 `imgurl` 是 `http://` 前缀（实测坐实，见
    `kugouAlbumCoverURL`），collector 发这个请求本身不受影响（Go 的 HTTP client 没有
    ATS 限制），但这个 URL 会原样进 `lyricCandidate.cover`、一路传到 Swift 侧的
    `AsyncImage`——macOS App Transport Security 默认拒绝纯 HTTP 的网络请求，图片静默
    加载失败、退回占位图标，不报错不抛异常，**拿 CLI 直查 `cover_url` 字符串本身完全看
    不出这个问题**（字符串本身没错，只是协议头不对，这也是为什么第 28 条的验证漏了它——
    只核对了 URL 是不是各源自己的域名，没核对协议头）。修法：`kugouAlbumCoverURL` 拿到
    `imgurl` 后强制把 `http://` 换成 `https://`（实测同一张图 https 也是 200，不需要改
    Info.plist 加 ATS 例外域名——那是更大范围的开口，没必要为一张图开）。QQ/酷我这两个
    源的封面 URL 从一开始拼的就是 `https://`，没有这个问题。

29. **同一个艺人的多张巡演/现场专辑收录同一首歌时，titleMatch 这道判据本身会打平，
    第 20 条那套「逐字加分撤销」失灵——两次尝试用专辑名补这个窟窿都被真实历史数据
    证明太宽，已回退**（2026-09-01，用户在「搜索候选歌词」弹窗里报
    「这个歌为什么匹配错了，明明第二个才是对的」——陈奕迅《Shall We Dance (Live)》。
    **本条记录的是两次失败的尝试和原因；同日晚些时候用完全不同的判据修好了，见第 31 条**）。

    查询专辑是「The Easy Ride 演唱会 (Live)」；冠军酷狗那份歌词标题「Shall We Dance
    (Live)」、专辑却是「Get A Life (Live)」——陈奕迅**另一场巡演**的现场专辑，两张专辑
    都收录了这首歌的现场版；亚军网易云那份标题「Shall We Dance(Live)」、专辑「The Easy
    Ride Live 陈奕迅演唱会」才是查询词自己的专辑。用真实字符串跑 `titleMatchTierPoints`
    实测：两边标题经 `normLoose`（丢空格/标点）后跟查询词逐字相等，**都是 120 分**，
    第 20 条那道「titleMatch 分严格高于冠军」的窄口子天生够不到——它是为「标题能分出
    高低」这一类设计的，这次分不出高低。唯一能区分「是不是同一次发行」的信号在专辑名，
    但 `albumScore` 的词元兜底档原来不管命中 1 个词还是好几个词一律 `s>=1 → +40`：
    酷狗那份只共享 `"live"` 这一个版本标签词（`albumScore=1`），网易云那份共享
    `"easy"/"ride"/"live"` 三个词（`albumScore=3`），实测两边**打分层拿到的都是 +40**——
    专辑分支根本没有机会显出差距，逐字时间轴的 +400 就是唯一的决定因素，选中了错误
    的那场演唱会。

    **第一次尝试（分桶补档 + 窄口子专辑分支，`lyricsScoringVersion` 6→7）**：给
    `albumScore>=3` 补一档 `+60`（跟只命中 1~2 个词的 +40 分开），再给
    `applyWordTimingTitleOverride` 加一条专辑分支——冠军专辑亲和 `<=40`、亚军
    `>=60` 时也撤销 wordTiming 加分，触发前提照抄 titleMatch 分支：「去掉 wordTiming
    单独就能翻盘」。手写单测全绿，但拿真实 `go run . search-lyrics` 重跑这首歌发现
    **不够**：酷狗的时长吻合项恰好也比网易云紧（+286 vs +252，反推末句时间戳分别
    离真实曲长 222.067s 差 ≈3.9s / ≈13.3s），去掉 400 分酷狗仍剩 763 分压过网易云
    的 744，触发前提从没成立过，专辑分支一次都没机会介入——这首歌里，错误的那份
    《Get A Life》录音不只逐字时间轴赢，连时长吻合都巧合地更紧。

    **第二次尝试（去掉触发前提，`lyricsScoringVersion` 7→8）**：把专辑分支改成不要求
    「去掉 wordTiming 单独翻盘」——冠军专辑证据落在最弱档、且存在专辑证据扎实
    （`>=60`）又不弱于冠军标题的真实候选时，直接把 wordTiming **和**时长吻合两项
    一起撤销。这次这首歌真的翻盘了（1163→477，网易云 744 反超）。

    ⚠️ **但拿全部真实历史决策（3198 条缓存条目、2162 个冠军带 wordTiming 的决策）
    反事实回放后，两次尝试都被证明太宽，已完整回退**：写了一个诊断用的临时测试
    （对跑「旧版本只有 titleMatch 分支」vs「第一次尝试」vs「第二次尝试」三版函数在
    同一批真实历史打分明细上的结果），发现——
    - 第一次尝试（仅分桶+窄口子专辑分支）相对旧版就已经改变了 **47** 个决策的冠军
      （2.2%，远高于 titleMatch 分支自己当年上线时的 5/868≈0.58%）；
    - 第二次尝试（去掉触发前提）在第一次尝试基础上又额外改变了 **104** 个。

      抽查这批分歧样本，绝大多数落在同一个模式上：Michael Jackson《HIStory
      Continues》/《HIStory: Past, Present and Future, Book I》各种再版合辑、Queen
      《The Game (Deluxe Edition)》这类**同一次录音的不同再版/精选辑/豪华版专辑名**——
      候选自己报的专辑跟本地专辑字符串对不上纯粹是「同一首歌收录进了不同的发行版本」，
      跟陈奕迅案「两场不同演唱会」完全不是一回事，但两次尝试都把「专辑名对不上」当成了
      足够强的反证据。这正是打分表里专辑亲和那一档从一开始就写明的设计原则——
      **「专辑对不上是零证据，不是负证据」**（中英互译专辑名、single 发行 vs 专辑收录、
      精选集 vs 原版都是合法的对不上，见第 11 条「精选集候选不再与原专辑平权」的
      同源教训）——而这两次尝试都是拿「冠军专辑证据弱」当作「可以不信 wordTiming/
      时长」的理由，等于在这条原则上开了个反向的口子。而且很多分歧翻过去之后的
      「新冠军」自己的专辑证据同样很弱（只是原冠军被扣分扣得更惨），说明命中的不是
      「专辑证据更扎实的候选真的更对」，只是撤销的分量（wordTiming 400 分，甚至
      连时长一起，往往 600+ 分）大到把原冠军砸穿、随便一个候选都能捡漂。

    **结论：两次尝试全部回退**（`match.go`/`match_test.go`/`enrich.go`/
    `LyricsSearchService.swift`/`lyricsScoringVersion` 全部还原到 6，逐行核对
    `git diff` 干净、`go test ./...` 全绿）。用户报的这首歌**目前仍然选错**，留作
    已知未解决问题——手动路径可以在「搜索候选歌词」弹窗里手动采用正确候选。这类
    「同一首歌被两个都合法存在的不同发行/演出收录，专辑名是唯一区分信号」的案例，
    要在不违反「专辑对不上是零证据」这条已经用真实数据验证过的核心原则的前提下解决，
    需要比「弱/强两档阈值」更精细的判据（比如只在专辑名**明确指向另一个已知具体
    发行/巡演**、而不是「字符串对不上」时才降低对 wordTiming/时长的信任），现有一
    首歌的样本不足以设计出安全的判据，留待下次积累更多同类真实样本再动手——教训
    与第 07 章「背景取色」那次「手算数字验证 vs 真实数据验证」是同一条：这次改的是
    单元测试用手造的数字通过了、真实 `search-lyrics` 单曲重跑也通过了，但**规模化
    反事实回放**（不是单曲验证，是几千条真实历史决策一起回放）才是这类改动真正的
    及格线。

30. **「收窄阈值就能让『奖励自报时长精确匹配』变安全」这个直觉是错的，收窄反而更危险**
    （2026-09-01，紧接第 29 条同一首歌的复查——陈奕迅《活着多好 (Live)》案里，网易云
    自报时长跟真实播放时长逐位相等，却因为"歌词末句时间戳"这个代理指标偏低而在
    时长吻合项上吃亏，用户问"直接奖励自报时长精确匹配是不是更合理"）。

    这个方向本身在 2026-08-22 已经用真实数据网格搜过一次并否决（见
    `sourceDurationMismatchPenalty` 注释）：当时 202 条缓存里 34 个可评样本，"只加分"
    方案（`<=2% → +300`）测出 2 处冠军变化，其中 1 处是误伤（Morphine 案：专辑证据
    更强的候选只因为自己的源不透传时长字段，被恰好报出接近值的候选顶掉）。样本太小，
    值得用现在大得多的库（3198 条，其中 2261 条带 `duration_secs`）重新核一遍，同时
    顺手测一个直觉："既然误伤源于阈值太松导致巧合命中，收窄阈值是不是就能避免"。

    反事实回放结果，阈值从松到紧、冠军改变数**不降反升**：

    | 方案 | 命中阈值的决策数 | 冠军改变 |
    |---|---|---|
    | `<=2%` `+300`（2026-08-22 原方案，当年 34 样本测出 2 处） | 2198 | **70** |
    | `<=0.5%` `+300` | 2159 | **141** |
    | `<=0.5%` `+80`（降低分值） | 2159 | **77** |
    | `<=0.1%` `+80` | 1891 | **318** |
    | `<=0.02%`（近似逐位相等）`+80` | 1636 | **358** |

    机制：阈值放宽时，同一轮候选往往好几个都够得着这个门槛，加分对彼此的相对排序
    没有额外区分度；阈值收紧后，反而变成"这一轮里唯一凑巧报出逼近值的候选"独得
    一份加分——越收紧，"唯一命中"的情况占比越高，本质上是把打分变成一个更纯粹的
    抽奖，跟"这份候选是不是真的对"关系更弱，不是更强。也验证了陈奕迅那首歌的直觉
    落空：即使收到"逐位相等"这么极端的阈值，命中率依然有 1636/2261，且冠军改变数
    比原方案更多，不是更少。

    **结论**：「奖励自报时长精确匹配」这整个方向——不管阈值收多紧、分值调多低——
    在现在的真实库上都比 2026-08-22 那次否决时验证得更彻底地不安全，`sourceDurationMismatchPenalty`
    保持"只扣不加"不变，代码未改动。诊断脚本（`zzz_srcdur_probe_test.go`）跑完即删，
    结论摘要留在 `sourceDurationMismatchPenalty` 的代码注释里。

31. **「两场不同演唱会」判据（`liveAlbumConflict`，v6→v7，2026-09-01）——第 29 条那类
    错配的真正修法，同日第四次尝试、前三次全部失败后换思路才成的**（陈奕迅
    《Shall We Dance (Live)》/《活着多好 (Live)》案，及全库回放顺带修好的另外 6 首）。

    **为什么前三次都失败**（细节见第 29/30 条）：它们都在拿「专辑对不上」当负证据用——
    撤销逐字/时长加分、奖励自报时长、抬高专辑词元分——全部违反「专辑对不上是零证据」
    这条 v3 起就用真实数据验证过的原则，全库回放分别翻出 47~150、70~358、3~7 个误伤。

    **换的思路**：不问「专辑分谁高」，问「两边的专辑名是否构成**身份矛盾**」。这类错配
    的真正形态是：本地《The Easy Ride 演唱会 (Live)》和候选《Get A Life (Live)》**都是
    Live**——versionTagsMismatch 的限定词集合相等、必然静默（它只能抓「一边 Live 一边
    录音室」）——但去掉 live/演唱会这类只描述录音形态的通用词后，两边剩下的**身份词
    完全不相交**（easy/ride vs get/life）。这不是「字符串没对上=零证据」，而是双方都
    做出了明确的身份声明且互相矛盾，跟 versionTagsMismatch 是同一性质的负证据，同样
    扣 -600（`liveAlbumConflictPenalty`）。

    **四道门缺一不可，其中两道是全库回放揪出误伤后补的**：

    1. 本地**专辑名自己**带 live 标记（歌名括号里的 Live 不算）——第一版没有这道门，
       回放翻出 Queen 3 条假阳性：《The Game (Deluxe Edition)》的 bonus 现场曲，候选
       《Queen Rock Montreal》是本地标题里写明的**同一场**蒙特利尔 1981 演出；录音室
       专辑名对「是哪场演出」没有发言权，构不成矛盾。
    2. 候选也是现场录音——候选是录音室版时归 versionTagsMismatch 管，两道闸恰好互补。
    3. 两边专辑名剥掉**歌手名**和 live 类通用词后各自还有身份词——歌手名剥除也是回放
       揪出来的：lrclib 一条候选专辑「地表最强世界巡回演唱会」对本地「周杰伦地表最强
       世界巡回演唱会 (Live)」，同一场演出只差歌手名前缀粘连（CJK 词元不分词，整段
       粘成一个词元，exact 比对必然不相交），剥掉歌手名后共享整个演出名、正确放行。
    4. 两个身份词集合**完全不相交**——共享哪怕一个词元（年份/场馆/巡演名）都当同一场
       的不同写法放过：方大同《15 (Live in Hong Kong 2011)》vs 网易云《15 香港演唱会
       (2011Live)》共享 "15"/"2011"，是同一场的中英命名，实测安全。

    **全库回放结果**（2339 条真实决策）：命中 29 个候选、涉及 24 首歌，**逐条人工核对
    全部是真的另一场演出**（Get A Life / 2003演唱会 / Third Encounter / fear and
    dreams / Moving On Stage / 拉阔压轴 / 无与伦比2004 / The One / 超时代 / 中国新歌声 /
    Timeless演唱会 / 15 Hong Kong 2011），0 误伤；冠军改变 8 首全部改对方向（陈奕迅
    5 首换到 The Easy Ride Live、方大同 3 首换到大事发声——后 3 首在 v5 时代已被
    wordTimingOverride 修对，这条判据在打分层就把它们扣掉，是更早的防线）。判据
    **对事不对源**：网易云自己匹配错场次时（《孤独探戈》它给的也是 Get A Life）同样
    被扣。真实端到端验证（`search-lyrics` 全量八源检索）：《活着多好》网易云 1040 vs
    酷狗 493、《Shall We Dance》网易云 724 vs 酷狗 563，两首都翻正，酷狗候选的
    `score_terms` 里可见 `liveAlbumConflict: -600`（弹窗解释文案「是另一场演出的现场版」）。

    ⚠️ **只挂在打分层**（`scoreLyricCandidateDetailed`），不参与任何身份/封面判定——
    跟第 14 条 kugou 三角判据「只放行歌词不放行身份」是同一条纪律的反向版本（只扣
    歌词分，不扣身份）。**已知的保守边界**：同一场演出若被某源用完全不同的名字命名
    且无任何共享词元（连年份都没有），会被误扣——全库回放里没有这样的真实案例（现场
    专辑名几乎总带年份或共享的演出名），且代价是 -600 不是一票否决，真是唯一候选时
    仍会以 1 分保底胜出。回归测试 `TestLiveAlbumIdentityConflict`（全真实字符串）+
    端到端 `TestScoreLyricCandidatePenalizesOtherConcert` 钉住四道门和两个核心案例。

32. **第 23 条的续篇：重挂修不了的"两套轴打架"还有另一半——弃用逐字轴**（2026-09-01，
    用户报「陈奕迅《2001太空漫游 (Live)》LRC 写着 32 秒有词，播放到 32 秒人已开唱、
    歌词却不出」）。

    根因是第 23 条的已知形态在 netease 上的变体：netease 的行级（`/api/song/lyric`
    老接口）与逐字（`/api/song/lyric/v1` 新接口）是**两条独立产线**，这一条的两套轴
    不只是时间戳不同——**断行方式都不一样**（LRC 拆两行的句子 YRC 合成一行）、还各夹着
    对方没有的署名行/纯音乐占位行，行数 39 vs 40、只有 20 行能逐行对上。实测配对行
    时间差 41~72 秒（中位 55.5s）：LRC 首句 32.3s、YRC 同一句 74.3s。播放走 YRC
    （第 08 章），「歌词管理」显示的是 LRC——用户看到的和播放用的是互相矛盾的两套。
    用户的耳朵是唯一的 ground truth：32 秒时人声已经开唱 → 这一条坏的是 YRC 侧。

    第 23 条那套 `rehangLRCOnYRC` 对这种形态无能为力——它的适用前提是"两边逐行文本
    严格一一对应"（musixmatch 的病恰好是那个形态），断行不同就在前提检查那一步放弃，
    打架原样留给播放。而已知旧案 Rock With You（坏的也是 YRC 侧）当年只做到了
    "时长闸拦住不去修"，**没有做"弃用"**——坏 YRC 从 2026-08-27 起一直在驱动那首歌
    的播放。

    **修法（`wordTimingContradictsLRC`，lyricstimeline.go）**：重挂修不了、且两套轴
    自相矛盾时，**弃用逐字轴**，播放退回行级 LRC。判据：LCS 对齐两边归一化文本相同的
    行，配对行 ≥8 且 ≥LRC 内容行的一半（配太少中位数不可信——Rumour Has It 那组
    4 行、单行偏差 9~11s，就被这道门正确放行给 rehang 管），配对行时间差**中位数
    ≥10s** 判为矛盾。方向依据：LRC 是打分管线全套校验过的主资产（isTimedLRC/
    durationFits/跨源共识全读它），YRC 只过了一道覆盖率守卫——两边矛盾而无法调和时，
    继续拿弱校验资产驱动播放，等于让播放跟系统其余全部判断对着干。代价是这几首没有
    逐字卡拉OK——正确的逐行显示胜过错 42 秒的逐字显示。

    **阈值 10s 从全库分布量出来**（2915 条可分析双轴条目）：99.3%（2894 条）中位偏差
    <3s（92% <0.5s——qq/kugou/amll 的 LRC 本来就是逐字轴转的，天生自洽；打架的几乎
    全是 netease/musixmatch，印证"两条独立产线"）；**≥10s 恰好 10 条**，逐条核对全部
    是无可争辩的坏数据。3~6.5s 之间的 11 条含糊地带刻意不动（哪边对判不了，等真实
    反馈；其中含同专辑的《大开眼戒 (Live)》4.5s，可能日后被报）。迁移模拟回放确认
    弃用名单与分布探针完全一致：恰好这 10 条（netease 8 + musixmatch 2，含
    Rock With You 与《2001太空漫游 (Live)》），0 条误伤。

    **两个挂载点**（同第 23 条，属"修数据"不 bump `lyricsScoringVersion`）：
    ①`rehangCandidateTimelines`（候选构造、打分前）——弃用发生在打分前，自相矛盾的
    逐字轴拿不到 wordTiming 那 +400（它不是质量证据）；②`migrateLyricTimelines`
    （启动期存量迁移）——重挂失败的条目补判矛盾、清 `lyrics_yrc`，存量的 10 条在
    collector 下次启动时落地，不用重新联网解析。回归测试
    `TestWordTimingContradictsLRC` / `TestRehangCandidateTimelinesDropsContradictoryYRC`
    全部用《2001太空漫游 (Live)》的真实 LRC/YRC 数据（含"水星"一行两边转写不同、
    配不上的真实细节），并钉住"可重挂的（Rumour）必须走修复路径而不是弃用路径"。

    ⚠️ **上线验证时顺带挖出一个一直存在的持久化潜伏 bug，一并修了**：
    `migrateLyricTimelines` / `migrateYRCWhitespaceTokens` 改完内存后从不置
    `enrichDirty`，而 `saveEnrichCache` 只在 dirty 时才真的写盘——迁移结果能不能落盘，
    取决于同一次启动里**别的路径**有没有恰好把标志置过 true。实测坐实：弃用逐字轴的
    迁移连续两次启动都在日志里报 "dropped contradictory word timing in 10 entries"、
    缓存 JSON 的 mtime 却纹丝不动（每次开机白干一遍再丢掉）；而 08-28 那次 1010 条
    重挂能落盘纯属搭了别的脏标志的顺风车。修法：两个迁移在持锁段内改动非零时显式
    `enrichDirty = true`。修后实测：弃用落盘（10 条 `lyrics_yrc` 清空、`lyrics` 完好）、
    后续重启迁移静默（0 条可弃，幂等成立）。

33. **同一张 Easy Ride 专辑的第三类错配：正确版本在源的曲库里存在，却被"精确同名优先"
    和"版本限定词错配"两道闸联手挡死**（2026-09-01，用户报「陈奕迅《孤独探戈 (Live)》
    匹配错了」——当前用的是网易云挂在《Get A Life (Live)》的错场次版本，`liveAlbumConflict`
    已经如实给它扣了 -600，它仍以 822 夺冠，因为 QQ/酷狗召回的都是录音室版、各吃
    versionTags -600 更惨——三个候选全错，矮子里拔将军）。

    直接查网易云搜索接口坐实：正确版本**存在**——`孤独探戈(Acoustic Piano)(Live)`
    （id=67184），专辑《The Easy Ride Live 陈奕迅演唱会》，自报时长 215.4s 与本地
    215.373s **逐位吻合**（同一次录音的铁证），带 61 行时间轴 LRC（无 YRC）。它被两道
    闸各挡一次：

    - **netease `pick()` 的"精确同名档优先"**：查询词「孤独探戈 (Live)」逐字命中三条
      **错场次**候选（Get A Life / Third Encounter / 拉阔压轴，专辑分 1/1/0），正确
      版本因多了"(Acoustic Piano)"一节落进剥括号档（专辑分 3），被精确档永远压住——
      pick 原来**完全不看时长**；
    - **versionTags -600**：即便召回，"(Acoustic Piano)"是本地曲名没有的限定词，两边
      集合不等照扣——这场演出本来就是钢琴演绎，"acoustic"描述的是**这场演出本身**，
      Apple 只是没把这层写进曲名，属命名差异而非版本差异。

    **修法（两处配套，`lyricsScoringVersion` 7→8；只修其一会更糟——只修 pick 不豁免，
    正确候选带着 -600 反而让录音室版夺冠）**：把第 14 条三角判据（标题+专辑+时长≤1% =
    同一次录音）推广成 `sameRecordingDespiteVersionTags`，四道门全过才成立：①双方都
    自报时长且差 ≤1%（与三角判据同一档，比打分层的 25% 严 25 倍）；②专辑有亲和
    （albumScore≥1）；③候选**不缺**本地已有的任何限定词（本地 Live 候选没标 → 时长再
    吻合也可能是录音室版）；④候选**多出**的限定词全部在 acoustic 家族白名单
    （acoustic/unplugged/不插电）——伴奏/instrumental/粤语/国语这类"时长相同但确是
    另一次录音"的词**永不豁免**（伴奏版时长常与原曲完全相同；粤语/国语两版同一伴奏
    时长几乎一样，恰恰是 versionTags 存在的理由）。两处使用：

    - **打分层**：`versionTagsMismatch` 命中但判定成立时不扣 -600。全库回放：现存
      433 个吃 -600 的历史候选 **0 个被豁免、0 翻盘**——零误伤，它只对"源平台标注了
      演奏方式、本地曲名没标"这一类**新召回**的候选生效；
    - **netease `pick()` 新增"时长+专辑锚定档"**（排在既有分层之前）：判定成立 + 专辑分
      **严格高于**其它全部已通过校验的候选 + 锚定候选唯一 → 直接接管。`durationSecs`
      为此穿透进 `neteaseLookup`（进缓存 key——否则预取路径传 0 的缓存会遮蔽真播放
      那次的锚定；预取路径显式传 0，锚定档关闭，行为与旧版逐字节一致）。

    **验证**：真实端到端（八源全量检索）三首同专辑歌曲——《孤独探戈》网易云现在返回
    正确的 Acoustic Piano 版并以 871 夺冠（分项里无 -600，无逐字轴是数据本身没有，
    正确性优先）；《Shall We Dance》(974)/《活着多好》(1290) 的 liveAlbumConflict
    判据继续正常工作，无干扰。单测覆盖真实案例+全部四道门反例（伴奏/国语/缺Live/
    专辑无亲和/时长差7.6%），全量 `go test` 通过。存量缓存的错误条目靠 v8 rescore
    在下次播放时自愈，等不及可在歌词管理点「重新自动匹配」。

34. **网易云自己数据库里的脏数据：一小撮曲目的英文歌词，撇号前带着字面反斜杠**
    （2026-09-01，用户报《爱是怀疑 (Live)》里 `It's`/`Can't` 显示成
    `It\'s`/`Can\'t`）。查本地缓存 `~/.config/lyrimuse/lyrics/*.lrc` 按 `[source:]`
    分组核实：1669 条网易云缓存里只有 2 条命中（《爱是怀疑 (Live)》9 处、Michael
    Jackson《Can't Let Her Get Away》90 处），QQ/酷狗/musixmatch/lrclib/amll 零命中
    ——不是我们自己的转义/反转义链路出的 bug（`json.Unmarshal` 早就把 JSON 转义正常
    解完了），是网易云 `lyric`/`tlyric`/`romalrc`/`yrc` 四个接口字段自己数据库里孤立
    的脏数据，字面两个字符 `\` + `'` 就这样躺在正文里。修法：`netease.go` 新增
    `stripNeteaseEscapedApostrophes`，在 `fetchBundle`/`fetchYRC` 解码后、写入
    `info.Lyrics/Trans/Roma/YRC` 前统一清一次（固定替换 `\'` → `'`，不做成通用转义
    清洗器——命中面就这一种组合，做通用反而可能误吃真实歌词里的反斜杠）。这只堵住
    **新抓取**的路径；两首歌已经落盘的缓存文件是直接改的（备份到 `/tmp` 后逐行核对
    替换前后 `'`/`\` 计数），不会等到下次重新解析才自愈。单测见
    `neteaselyrictext_test.go`。

35. **网易云曲目搜索的召回失败 ≠ 曲库没有——官方老曲目会被 UGC 翻做/仿冒号从搜索排名里
    彻底挤出窗口，专辑锚定兜底补这个缺口**（2026-09-01，周杰伦《简单爱 (Live)》/《The One
    周杰伦演唱会》案，用户报「搜索候选歌词」8 个源只有酷狗回了一条错场次的「无与伦比
    演唱会」版）。实测链条：这首歌在网易云明明存在（album 18906 / song 186043，自报
    273.0s 与本地 273.227s 只差 0.227s，52 行 LRC + YRC 逐字），但四条查询词各自的前
    30 条里官方版**一次都没出现**——结果被「周杰伦♚」「周杰伦.」这类仿冒号和 beat 翻做
    刷满，真周杰伦的只有错场次的「2004无与伦比演唱会」版和「K情歌10」合辑版，pick()
    按「宁可没有不要错」全部正确放弃。已有的标题反查轮（title-from-album）**其实找到了**
    这条曲目（albumDiff=0.227s），但它只把标题文字带出来重搜：「简单爱(Live)」与本地
    「简单爱 (Live)」normLoose 相等，重搜轮被「纠正后标题没变化」的判据跳过；就算不跳，
    拿文字重搜撞的还是同一堵召回墙——**ID 在手却只回传文字**，是结构性缺口。

    修法（`resolveNeteaseInfo` 内新增专辑锚定兜底）：四条查询词全部无可信匹配、且本地
    专辑名 + 真实时长都已知时，走「搜专辑（`neteaseAlbumIDByName`，artistMatches +
    albumScore≥100 双闸）→ 浏览曲目（`neteaseAlbumTracks`，albumTrack 新带
    `neteaseSongID`/`neteaseAlbum`）→ `anchorAlbumTrackForLocalTitle`（lyricTitleAccepted
    + artistMatches + 时长唯一锚定，容差沿用 2s 常量，同误差歧义即放弃）」，锚定成功就拿
    曲目 ID 接回既有的取词/取封面流程。闸门与 pick() 同强度，不是放宽；durationSecs=0
    （预取路径）时整档关闭；成本仅在召回全空时多两次网易云请求，走同一个节流。端到端
    验证：修后同一条搜索，网易云返回正确 The One 版 1353 分（带 YRC）夺冠，酷狗错场次
    候选 1 分。单测 `neteasealbumanchor_test.go`。与 `withholdImpersonatorRiddenIdentity`
    不冲突（周杰伦在黑名单上，身份/封面照扣、歌词族照常放行——本案正是歌词族受益）。

    顺带修的存量坑：`neteaseAlbumTracks` 的 v1 兜底端点（`/api/v1/album/{id}`）字段名
    跟老端点不一样（`dt`/`ar` vs `duration`/`artists`，2026-09-01 实测坐实），原解码只认
    老端点字段——主端点被限流走 v1 时时长恒 0、歌手恒空，`bestAlbumTrackByDuration`
    对时长 ≤0 的曲目直接跳过，等于标题反查在 v1 路径上**一直静默失效**，表现跟「专辑里
    没有时长接近的歌」一模一样。现在两套字段都解，谁有值用谁。

    QQ 侧同型的缺口当时以「QQ 没有『按专辑名搜专辑再浏览曲目』的公开接口（第 33 条
    调研过），修不出等价的锚定兜底」为由不动——这个结论后来被推翻：smartbox 的 **album
    分类**未登录可搜，musicu.fcg 的 **GetAlbumSongList** 未登录可拉曲目单（都是 2026-09-01
    实测坐实），QQ 版的专辑锚定兜底见第 36 条。

36. **QQ 的搜索面从根上够不到现场专辑曲目——专辑维度检索路线 + v9 两处中文命名形态的
    打分修正**（2026-09-01，用户报「周杰伦《龙拳 (Live)》等 The One 演唱会曲目，QQ 搜
    出来的是录音室版歌词」）。三层根因，逐层实测坐实：

    - **检索层**：QQ 源唯一可用的搜索入口 smartbox 是**前缀联想**不是搜索——对
      「周杰伦 龙拳」恒只回八度空间录音室版一条；加词（「周杰伦 龙拳 Live」）、带括号
      都直接 0 条。而 QQ 给现场专辑曲目起名**不带 (Live)**（The One 演唱会里就叫
      「龙拳」），live 身份只写在专辑名上——歌名维度永远召回不到它，必须以专辑为锚。
      修法（qq.go 专辑维度路线 `resolveQQMatchViaAlbum`）：smartbox **album 分类**搜
      专辑（查询词要先把歌手名和现场类通用词剥干净，`qqAlbumIdentityQuery`——实测
      「周杰伦 The One 周杰伦演唱会」0 条、「周杰伦 The One」命中）→ musicu.fcg
      `GetAlbumSongList` 拉曲目单（未登录可用，回 mid/曲名/歌手/官方时长，按 albumMid
      缓存）→ `lyricTitleAccepted` 门内两档（归一化精确 > 剥括号相等）挑曲目，最优档
      必须唯一，歧义即放弃。三道身份闸（专辑歌手 looseContains、albumScore≥1、标题闸）
      宁可空手回落旧行为，不给错歌。只在歌名维度**专辑证据为零**（原 smartbox 路线
      bestScore==0 或 0 候选）时启用，正常歌零额外请求。选中时官方时长随曲目单带回
      （`qqMusicMatch.interval`→srcDur），QRC 逐字/封面/跳转链接全部跟着换到正确 mid。

    - **打分层 ①（albumTokens 拉丁↔CJK 交界分词，v9）**：QQ 把专辑写成「The One演唱会」
      （One 和 演唱会 之间不留空格），unicode.IsLetter 对汉字为真，原分词把「one演唱会」
      粘成一个词元，与本地「The One 周杰伦演唱会」零共享词、albumScore=0——同一张专辑
      被判毫无亲和，检索层修好了也拿不到专辑分。与既有的「2011Live」数字↔字母交界分词
      同一性质；CJK 内部照旧不分词，`cjkLiveAlbumMarkers` 的子串匹配仍然必要。

    - **打分层 ②（recordingVersionTags，v9）**：versionTags 闸只在括号段/「 - 」尾段找
      限定词，「The One演唱会」这类不带括号的专辑名声明不了 live——候选（曲名「龙拳」+
      专辑「The One演唱会」）限定词集合为空 vs 本地 {live}，正确候选反吃 -600。修法：
      专辑名 **stripParens 后**含中文现场标记（演唱会/现场/音乐会，子串）视同声明 live，
      双向对称——反向（本地是「XX演唱会」专辑、候选是干净录音室版）也从「闸门静默」变成
      能判出版本不符。**刻意不认拉丁 live/concert/tour 词元**：《Live and Let Die》
      《In Concert》是录音室发行的合法专辑名。配套两处防误伤（都是全库回放抓出来的真实
      案例）：括号里的描述文案不算标记（韦礼安《女孩》的 lrclib 候选，专辑名括号里是
      「…小巨蛋演唱会求爱主题曲…」的介绍文字）；`sameRecordingDespiteVersionTags` 第③门
      的本地侧改用**括号级**集合——候选是同一张专辑的**截短拼法**（蔡健雅《依赖》：
      kugou/QQ 把《My Space 演唱會紀念盤》写成「My Space」，srcDur 179 vs 本地 179.52
      逐位吻合）时，不苛求它也推导出 live。lrclib 的召回闸同步加了这个豁免（它有
      it.Duration 可查，不加的话同场对版在召回层就被扔掉）。

    全库 2360 条真实决策回放（旧逻辑副本与存档 parity 0）：23 首受影响、唯一 1 处冠军
    改变是蔡健雅《达尔文》从录音室版 kugou（srcDur 265 vs 本地 308，差 14%）翻到
    My Space 现场对版 netease（srcDur 308.04 逐位吻合）——改对；其余全是「-600 平反」
    （地表最强 7 首 QQ 候选）或「新判出录音室冒充现场」（冠军均不变），0 误伤。已知
    接受的形态：《周大侠》（本地录音室原声带）在三个平台都被挂在「2007世界巡回演唱会」
    名下且 srcDur 逐位吻合——同一录音被合辑命名连累吃 -600，但三家一起扣、相对排序不变、
    冠军不动，按「等真出伤害再收」惯例不为它开口子。E2E：The One 四首（找自己/星晴/
    龙卷风/龙拳）QQ 候选全部换成 Live 对版（带 QRC 逐字 + 官方时长）；《龙卷风 (Live)》
    从 lrclib 无逐字 798 升级到 netease 1518 带逐字；孤独探戈（33）、Shall We Dance
    （29/31）、大笨钟串烧、晴天、Billie Jean (Single Version) 回归全部保持。

37. **酷狗「第一条过闸就收工」会让搜索排序靠前的杂项顶掉同页靠后的正主——改成全页排序**
    （2026-09-01，第 35 条《简单爱 (Live)》案的酷狗侧收尾）。实测酷狗对「周杰伦 简单爱
    (Live)」返回的第 1 条是「简单爱 (无与伦比演唱会 m 56s)」——一个 **56 秒的片段**、
    专辑名为空，但剥括号后标题也叫「简单爱」、歌手也对，旧逻辑（`chosen = s; break`）
    先到先得直接定死；第 2 条就是「简单爱 (Live)」《The One 演唱会》273s——标题跟本地
    normLoose **精确相等** + 专辑 token 对得上（albumScore=2）+ 时长只差 0.227s，三项
    证据全在却永远轮不到。netease.go 的 queries 注释早写过这个对比（「那三个源是取第一条
    通过校验的候选就收工」），这次把酷狗从名单里摘出来。跟第 35/36 条不同：**酷狗的搜索
    召回本身是好的**（正主就在同页第 2 位），病灶纯在客户端挑选，不需要任何新接口。

    修法（`pickKugouSearchCandidate`，从 `resolveKugouLyric` 抽出的纯函数）：闸门原样保留
    （lyricTitleAccepted + lyricSourceArtistMatches / 三角判据兜底），只改「过闸之后信谁」
    ——排序键=①标题档位（normLoose 精确 > 剥括号相等 > 其它过闸，与 QQ 专辑维度路线的
    三档同构）②同档比 albumScore ③再同比时长贴近度（缺时长当 +Inf）④全平保持原序
    （=改动前行为）。只有一条过闸时逐位等价于旧行为。三角判据的 accepted 日志改成只报
    最终选中者（全页排序后"接受"不再等于"选中"）。E2E：这首歌酷狗候选从错场次片段 1 分
    变为 The One 版 **1389 分带 KRC 逐字**，与网易云（1453）/QQ（1307）三源同录音互证；
    单测 `kugousearchpick_test.go`（真实页数据 + 各排序键 + 打平保序 + 三角兜底回归）。

    对抗性复核(三视角:正确性/并发缓存/身份安全)确认并已修的三点:①**瞬时失败与
    "确定没有"零值合并会毒化缓存**——专辑路线一次 smartbox 超时 → 零值 → 回落的录音室
    版(真·歌曲页 URL 非空)被 `qqMusicMatchCached` 按 artist|title|album 永久正缓存,
    本进程后续所有重搜/自愈全部命中毒化条目,恰好把这条路线要修的 bug 原样钉回去。修法:
    `qqSmartboxRaw`/`qqAlbumSongs` 传播网络层 error,`resolveQQMatchViaAlbum` 返回
    degraded 信号,回落结果打 `qqMusicMatch.unreliable`,不进 qqURLCache(下轮重搜翻案)。
    ②**最坏耗时放大**——每个查询变体撞满 6s 超时 + musicu 8s 会把 qq goroutine 拖到
    ~26s,连锁让 amll 源(阻塞等 qqID)一起缺席 20s 截止、触发整轮重搜。修法:整条路线包
    10s 总预算 context(正常网络每请求几十 ms,只裁病态路径)。③**albumScore≥1 的词元闸
    太弱**——它的词元集不剥歌手名和 live/tour 类通用词,"Jay Chou The One Concert"和
    "Jay Chou The Invincible Concert"共享 {jay,chou,concert} 也能过。修法:专辑闸叠加
    **身份词交集**(albumIdentityTokens,与 liveAlbumConflict 同源);本地专辑剥完通用词
    没有身份词时整条路线放弃(防"陈奕迅演唱会"这类标签把查询词退化成裸歌手名);选中曲目
    自带 singer 时再核一遍歌手(防合辑里同名曲是别人唱的)。已知未收敛(既有形态,非本次
    引入):qqURLCache/qqAlbumSongsCache 都是 check-then-act 无 singleflight,20s 截止
    竞态下同 key 可能双链并发、对反爬敏感接口重复请求——量级可从 request-audit 日志观察,
    等真成为问题再上 singleflight。

38. **QQ 富歌词接口的译文 / 罗马音两轨接回（2026-09-02）**：
    `qqQRCLyric` 的请求体从接 QRC 那天起就带着 `roma=1`/`trans=1`，响应却只解 `lyric`——
    那是当时计划里「刻意不做的」项（酷狗那一半至今仍没接）。直连接口实测四首：米津玄師
    《Lemon》/ NewJeans《Ditto》译文 + 罗马音都有，Taylor Swift《Cruel Summer》只有译文，
    周杰伦《晴天》两者皆空；旧接口 `fcg_query_lyric_new` 的 `trans` 字段对四首全空，所以
    译文只能从这里拿。两轨与 `lyric` 同一把 3DES 密钥 + zlib，形态不同：`trans` 解出来是
    普通逐行 LRC，时间戳与旧接口整行歌词逐行一致（`[00:01.54]夢ならば` ↔
    `[00:01.54]如果只是一场梦`，App 侧 700ms 最近邻贴行天然对上），但夹着三类不是译文的行
    ——`//` 占位行（对应标题/词曲署名行，Lemon 3 行、Cruel Summer 8 行）、
    `[00:00.00]QQ音乐享有本翻译作品的著作权` 版权行、无时间戳的 `[kana:…]` 元数据行——全部在
    collector 侧剔掉（只剔 `//` 不够，版权句会被当成标题行的译文显示出来）；`roma`
    沿用 QRC 的 XML 包装 + 逐字计时，压成逐行 LRC（`[行始,行长]`→`[mm:ss.SSS]`、去掉
    `(词始,词长)`，只剩计时没文字的行丢掉）。两轨都过 `isTimedLRC` 收口（≥3 行带戳）。
    接线：`qqQRCLyric` 改返回 `qqQRCResult{yrc,tr,roma}`（三轨互不牵连，逐字没过
    `qrc_t/lrc_t` 闸时辅助轨照样接），`sourceResult` 加 `roma`，候选装配处按网易云同款
    `usableValueAdd(qqLyr, qqTr, "zh", qqRoma, 目标语言)` 算 `hasUsableTranslation` /
    `hasUsableRomanization`，最终装配的 `switch c.source` 补 `case "qq"`（第 10 章已知坑 10
    那次 amll 漏的正是这一处）。分值不变——既有「可用译文 +50 / 罗马音 +30」自动生效，
    **不 bump `lyricsScoringVersion`**：重新裁决只重算存量候选的分，存量 QQ 候选里没有这两轨，
    bump 了也拿不到；新解析 / 自愈 / 手动重搜的歌自然带上。E2E（`search-lyrics`）：《Lemon》
    的 QQ 候选 1407 分（含 translation +50 / romanization +30），译文 55 行 + 罗马音 55 行 +
    QRC 逐字，成为冠军（网易云 1142 / 酷狗 1331 / amll 1005）。既有口径顺带说明：罗马音可用
    判定要求原文假名占比 > 5%，韩文歌（Ditto）的罗马音会跟网易云一样被判不可用而不写入。

39. **QQ QRC 正文的 `[kana:…]` 假名标注行接给 App 侧 KanaAnnotation（2026-09-02，紧接第 38 条）**：
    解密后的 QRC 正文第一行是 `[kana:1よね1づ1けん1し…1ゆ(1547,224)め(1771,153)…]`，跟酷狗 LRC
    自带的 `[kana:]` 标签同格式（第 10 章 §3 第 3 条）。之前它只跟着 QRC 正文流进逐字数据
    （`qrcToYRC` 的词级重排还会把读音里的 `(起始,时长)` 搅乱），而 App 只从**整行歌词**
    （lyrics 字段）找这一行，所以一直没被用上。现在 `qqQRCLyric` 用 `splitQRCKanaLine` 把
    这一行摘出来放进 `qqQRCResult.kana`，剩余正文才进 `qrcToYRC`（逐字数据里不再有这一行）；
    enrich.go 的 QQ 路用 `attachKanaLine` 把它拼到整行歌词（旧接口 LRC）的第一行，整行歌词
    已带 `[kana:` 时不重复拼。对齐前提是直连接口实测过的：8 首里 6 首日文歌（Lemon / 打上花火 /
    Pretender / 夜に駆ける / 恋 / 残響散歌）全部带这一行，且按 KanaAnnotation 的规则复刻校验
    （条目覆盖数 = 带时间戳正文行里的汉字数含 `々`）逐首相等、QRC 正文与旧接口整行歌词的汉字
    序列逐字相同；中文歌（晴天）与韩文歌（Ditto）没有这一行。对不齐时 App 侧整份弃用、退回
    形态分析，最坏是没效果。副作用：QQ 候选的 lyrics 多出一行无时间戳的假名，`kanaRatio` 略升
    （只对本来就有假名的日文歌生效，方向一致）；导出的 .lrc 也会带这一行，与酷狗 .lrc 形态一致。
    ⚠️待核对：未在 App 界面上肉眼核对 QQ 日文歌的读音显示，只做了规则级复刻校验。

    **连带修的打分坑 + `lyricsScoringVersion` 10 → 11**：第一版把假名行拼进整行歌词后，E2E 实测《Lemon》
    的 QQ 候选从 1407 掉到 1158——`lyricConsensusBody` 逐行只去时间戳，无时间戳的 `[kana:…]` 整行
    （1700+ 字符假名）被当成正文进了 3-gram 比对，相似度掉到 0.55 阈值以下、250 分共识没了，冠军会因此
    换成酷狗（1331）。修法：`isLRCMetaTagLine`（`^\[[A-Za-z_]+:` 开头且整行以 `]` 收尾）命中的
    `[kana:]`/`[ti:]`/`[ar:]`/`[offset:]` 行不进共识正文；无时间戳的纯文本行（lrclib plainOnly）不受影响。
    这条规则对酷狗自带 `[kana:]` 的日文歌其实一直成立，只是没被注意；属于判定层改动，按第 10 条约定
    提版本号让 v10 条目重新裁决（重算用决策留痕里的存量候选，不联网）。`lines` 项仍是原始行数
    （QQ 候选因此 +1），刻意不改——改了会让每个候选都按元数据行数变分，收益不值得。修后 E2E：
    《Lemon》QQ 候选 1408（共识 250 回来，lines 62 → 63）。单测 `TestLyricConsensusBodyIgnoresMetaTagLines`。

37. **同一张专辑被上架两遍,把整张专辑的 QQ 歌词全挡在外面——专辑维度路线的「并列即放弃」
    放宽**(2026-09-02,用户报「为什么这首歌只有网易返回了」,裘德《寻找一片青草地》)。
    - **先分清是不是我们的问题**,逐源实测的结论差别很大:**QQ 有这首歌、我们没找到**
      (我方 bug);**酷狗有歌但歌词库里没这首的词**(krcs 对该 hash 三种查法都 0 条,
      不是我方问题);**酷我 / LRCLIB / AMLL 曲库里压根没有**;LyricFind 是
      `lyricfind_region_restricted`(地区封锁,与本曲无关)。所以八源只回一条,**七条是
      正常的,只有 QQ 那条是 bug**。
    - QQ 的病灶两层。第一层是老问题:smartbox 是前缀联想不是搜索,「裘德 寻找一片青草地」
      和单搜歌名都返回 **0 条**,而搜「裘德 离开银色荒原」能命中专辑——第 36 条那条专辑
      维度路线正是为此而生,这次**也确实跑了**。
    - 第二层是这次的新形态:**QQ 把《离开银色荒原》整张上架了两遍**,`GetAlbumSongList`
      回 20 条 = 同样 10 首各一条(两个母带,部分曲目时长差 1~7 秒)。于是每一首都在最优
      档位并列两条,撞上原规则「最优档并列就整条路线放弃」——**这张专辑的每一首歌的 QQ
      歌词都拿不到**,不止用户报的那一首。
    - 原规则防的是「同名不同版本挑错版」,但它在这里判错了性质:那两条不是"两个不同的
      东西分不清",是同一首歌的两个版本(实测《火山灰》《变色龙》两条 mid 取回的歌词
      **逐字节相同**)。修法(`qqAlbumTiedSongsAreSameTrack`):并列各条**同名 + 同歌手 +
      时长跨度 ≤10 秒**才认定是同一首被列了多遍、取第一条;时长差得多(两场不同现场)
      照旧放弃。10 秒来自实测的 0~7 秒母带差。
    - ⚠️ **修完用户报的那一首仍然拿不到 QQ 歌词,这是对的**:那两条 mid 一条
      `fcg_query_lyric_new` 回 retcode **-1901**(无词)、另一条明文回「此歌曲为没有填词的
      纯音乐」——**QQ 自己对这一首就没有词**。有效果的是同专辑其它曲目:实测《火山灰》
      《变色龙》修前 QQ 零候选、修后拿到分 1504 / 1367 的候选。
    - ⚠️ 那句「纯音乐」不会污染结果:纯音乐标记只在**所有源都没选出歌词**时才被采纳
      (`enrich.go:1219` `if picked == nil && !e.Instrumental`),网易的 64 行词会先被选中。
    - ⚠️ **挑选逻辑抽成了纯函数 `pickQQAlbumTrack`**,不再内联在需要联网的
      `resolveQQMatchViaAlbum` 里——变异测试当场证明:只测判据 `qqAlbumTiedSongsAreSameTrack`
      的话,把调用点改回「并列一律放弃」(= 本次要修的 bug 本身)**全部测试照样全绿**。
      现在用真实抓下来的 20 条曲目单钉住整段,七个变异全部被抓住。


40. **酷狗 KRC 内嵌的译文 / 罗马音两轨接回（2026-09-02）**：解密后的 KRC
    正文里有一行 `[language:<base64>]`，base64 解出 JSON `{content:[{type, lyricContent:[[片段…]]}]}`，
    type 1 是中文译文、type 0 是音译，lyricContent 每项对应一条 KRC 计时行（`[行始,行长]<…>`），
    **按行序号对齐**。之前 `krcToYRC` 对不含 `[数字,数字]` 前缀的行「原样保留」，这行 8～12 KB 的
    base64 一直被透传进逐字数据（App 读不懂、还随 .yrc 导出），从未解码。直连实测 6 首：Lemon 57/57、
    Ditto 73/73、Cruel Summer 73/73、Pretender 78/78、夜に駆ける 88/88 行数逐首相等，晴天（中文）没有
    这一行；空片段对应署名行。译文行时间戳取 KRC 行始，而 App 侧贴译文用的是 fmt=lrc 那份整行歌词的
    时间戳——两套最近邻差最大 9ms，远在 700ms 容差内。**一个容易漏的坑**：韩文歌的 type 0 轨
    是中文谐音（Ditto：「马列做 say it back」「啊亲们 挠木 摸咯」），照单收就会当罗马音显示；这里用
    正文汉字占比 > 0.3 挡掉（真罗马音实测为 0，谐音轨 ≈0.9），下游 usableValueAdd 的假名占比闸是第二道。
    接线：`splitKRCLanguageLine` 先摘行、剩余正文才进 `krcToYRC`；`krcLanguageTracks` 出两轨，行数与
    计时行数不等整轨放弃、空行与 `//` 跳过、isTimedLRC 收口；kugouResult 加 tr/roma，enrich.go 三处
    （sourceResult、候选装配 usableValueAdd(…,"zh",…)、最终装配 `case "kugou"`）与 QQ 那路同构。分值
    不变、不 bump 版本（理由同第 38 条）。单测 `kugoulang_test.go` 5 条。

41. **歌词源级熔断 / 退避（2026-09-02）**：某个源整个哑掉（DNS 污染、TLS
    挂死、5xx）时，之前每首歌都要把它等到自己的超时——AGENTS.md 里 2026-08-15 Musixmatch DNS 事故的
    原话「每首歌都要把 DNS/TLS 超时白等一遍」；已有的退避全是点状的（网易云端点桶 30s、lb.go 的 429
    阶梯、Musixmatch 换 token）。现在的通用层挂在 `doHTTPTracked`（唯一能同时拿到网络层错误与状态码
    的地方——各源函数把所有错误都吞成空结果），跳过决策挂在八个源 goroutine 的开头。机制见 §3。
    **两处刻意不做的**：①不把 401/402/403 当成长期粘性冷却的理由——对没有
    凭据的源，反爬 403 那样处理会让该源永久缺席、界面还不提示；这里 4xx 一律不算失败，交给各源自己已有的判定。
    ②不是一次失败就冷却，而是连续 2 次才开——一次网络抖动不该让下一首歌少一个源（网易云一轮最多 4 个
    变体，一首歌就够触发；lrclib 单请求要两首歌）。**两条 lyrimuse 特有的护栏**：启用的源全在冷却中时
    谁也不跳过（否则熔断会把断网伪装成「这首歌没歌词」，而歌词全空但有封面的条目会落盘、24 小时后才
    补搜）；歌词为空且这一轮有源被跳过时，`needsLyricsFirstFill` 的补空间隔从 24 小时缩到 10 分钟
    （只对第一次生效，熔断最长 5 分钟、10 分钟足够过期）。**为什么不改 `fetchScoredLyricCandidatesStreaming`
    的返回值**：它在别名 / 标题反查里最多被调 4 次、上面还有三层调用链，逐层加返回值要改六处签名只为传
    一份名单，改用 ctx 值（`lyricSourceRound`），只有真关心的三个写缓存点各拿一次。**故障注入实测**
    （scratchpad 副本里把网易云主机指向黑洞地址 10.255.255.1，连接只会超时）：第一首歌整轮 20s（网易云
    5 个请求各 4s 超时，第 2 次失败起进入冷却并逐次升到 2m），第二、三首歌网易云被跳过，整轮分别 1.1s 与
    1.9s，`sources_skipped=[netease]`，其余三源正常应答。单测 `sourcebreaker_test.go` 7 条（假时钟）。
    副作用：误熔断让某源缺席一到两首歌，上限 5 分钟、成功即清；`api call … FAILED` 日志之外新增
    `lyrics: source X cooling down …` / `skipped this round` / `recovered` 三类英文日志行。

42. **Musixmatch 的接口地址被这条网络打掉了——直连优先、直连不通才走系统代理（2026-09-03）**：
    用户在设置页点 Musixmatch 的「测试」，报「两首探测曲都没有响应，这个源目前可能不可用」。
    逐层量下来根因既不在代码也不在 Musixmatch：`ping` 那两个 A 记录（52.22.193.26 /
    54.144.176.235，AWS us-east-1）**100% 丢包**，而同一时刻 `ping` apic-desktop 走的
    CloudFront（18.154.206.74）和 1.1.1.1 都是 0% 丢包 ~160ms；TCP connect 16 次只成功 3 次
    （且都要等到 SYN 重传后的 1.3s / 3.4s），TLS 握手 **16 次 0 次成功**；而经本机代理立刻
    HTTP 200 拿到真 token。**跟 2026-08-15 那次不是一回事**：那次是系统 DNS 把域名解析到了
    Facebook 的地址段、证书对不上（doh.go 就是为它加的），这次系统 DNS / 1.1.1.1 / 8.8.8.8
    三家给的都是正确的 AWS 地址，是**路由层被打掉**。也不是反爬（那会正经返回 401
    `hint=captcha`，见第 38 条上下文；apic-desktop 现在恰好就是这个状态，所以换回那组
    host+app_id 不是出路）。

    **修法与三条刻意的边界**：
    - **只给这一个源加代理，不全局。** docs/features/12 章记着一组反向实测：App 进程
      （URLSession，默认就走系统代理）打 Last.fm 是 p50 1.2s / p90 6s / **16% 超时**，同一时段
      collector 的 Go 直连是 p50 0.4s / ~1% 失败；`curl` 对照直连 0.6–1.0s 全成功、经代理
      1.7–2.5s 且 2/6 握手失败。**在这台机器上代理是更差的通道**，让它接管全部 26 处
      `http.Client` 是明确的性能倒退。生效范围严格等于 `dohHostSuffixes`（当前只有
      `.musixmatch.com`），跟 doh.go 自己「只给解析歪的那个域名开小灶」是同一条纪律。
    - **Go 标准库不读 macOS 系统代理。** `http.ProxyFromEnvironment` 只认 `HTTP(S)_PROXY` /
      `ALL_PROXY` 环境变量，而 collector 是 GUI 拉起来的、不继承 shell 环境（实测运行中的
      collector 进程环境里一个 proxy 变量都没有）。所以要自己跑 `scutil --proxy` 解析
      （`parseSCUtilProxy`，PAC 和 ExceptionsList 刻意不支持，理由见函数头注）。⚠️ 解析出的
      URL scheme 是 **http** 不是 https——`HTTPSProxy` 说的是「给 https 流量用的代理」，不是
      「用 https 连代理」；写成 https:// 会让 Go 先跟本机 Clash 做一次 TLS，那个端口不说 TLS。
      单测里专门有一条钉这个。
    - **配置着但连不上的代理 = 没有代理。** 代理软件崩溃/被强杀时 macOS 那份开关会留在开着的
      状态，照单全收会把「某个源直连不通」升级成「兜底通道也是死的、还要白等一次超时」。
      `systemProxyURL` 每次（60s 缓存）先本地 TCP 探一下（400ms）。

    **预算与粘性**：直连探路 3s（黑洞的特征是 SYN 石沉大海，路通时 TCP+TLS 全程 <1s）、
    走代理 10s（实测经 Clash 6.5s）。⚠️ 预算必须落在**每次尝试**上，`dohHTTPClient` 因此刻意
    不设 `http.Client.Timeout`——设了就是把两次尝试算进同一个预算，直连一超时就没钱给代理重试，
    fallback 等于没加。代理救回来后粘 10 分钟，并写一份跨进程提示
    （`~/.config/lyrimuse/lyrimuse-proxy-hint.json`）：`search-lyrics` / `test-lyric-sources` /
    `healthcheck` 都是一次性子进程、内存粘性归零，没有这份提示每跑一次都要重新白等一轮探路，
    正是 2026-08-15 那句「每首歌都要把超时白等一遍」的翻版。代理反过来失败时清粘性+清提示、
    当场回直连重试（否则会一直往一个死代理上撞，而直连说不定早就恢复了）。

    **顺带修掉的一个真 bug（同一次改动）**：`dohDialContext` 原来是**串行**试 DoH 查到的地址，
    每个 `dialer.Timeout = 8s`，而外层 `http.Client.Timeout` 也是 8s——第一个地址是黑洞时 8 秒
    全耗在它身上、**永远轮不到第二个**。而 DoH 返回的地址顺序是随机轮转的（实测 1.1.1.1 对同一
    域名连查三次给了两种顺序），`dohCache` 又一存 30 分钟：一次坏运气就是接下来半小时这个源全废，
    而另一个地址明明是好的。改成并发拨号（`dohDialRace`），第一个连上的胜出、慢一步也连上的当场
    关掉。今天两个地址都不通所以不是本次的根因，但它会把「可恢复」变成「完全不可用」。

    **界面**：新增失败原因代码 `musixmatch_direct_blocked`（直连不通 **且** 代理也救不回来），
    跟既有的 `musixmatch_rate_limited` 是两回事——那个是服务器正经回了 401，这个是一个字节都没
    拿到，用户该做的事也不同（一个是等，一个是去开代理）。两侧同步此前**一条自动检查都没有**，
    这次一并补上源码级守卫（`lyricsourcefailure_test.go`：Go 常量集合 ≡ Swift `case` 集合，且每个
    `case` 必须 `return L10n.t(`）。⚠️ lyrimuse-selftest 只依赖 LyrimuseCore、拿不到 app target 里的
    `LyricSourceFailureReason`，所以这件事的全部自动检查都在 collector 侧那一个文件里。

    **验证**：`systemproxy_test.go` / `proxyfallback_test.go` / `lyricsourcefailure_test.go`
    共 21 个顶层用例（含并发拨号的黑洞回归、跨进程提示、Body 生命周期、代理探活、两侧代码对账），
    6 个变异全部被抓住。真机（装机后 `collector test-lyric-sources -source musixmatch`）：
    修前 `warn` / `no_response`、18s、`token.get` 与 `track.search` 双双 `context deadline
    exceeded`；修后 **`ok`**，四个端点（search / subtitle / richsync / translations）全 200，
    干净状态 6.4s（直连探路 3s + 代理 3.4s），命中提示后 7s 跑完两首探测曲。
    ⚠️ 代理那一侧失败时,返回值里只有直连的错,所以 `RoundTrip` 里**单独记一行**带 proxyErr
    的日志 —— 缺了它「兜底为什么也没兜住」完全不可观测（装机验证时正是缺这一行,没法一眼
    判断第一次代理是超时还是被拒）。

38. **Musixmatch 只问「有没有做时间轴」,不问「有没有词」——`has_lyrics=1/has_subtitles=0`
    的歌整个源等于不存在**(2026-09-02,用户报「帮我看看为什么这个搜不到」,
    Charlie Musselwhite《Storm Warning》,专辑 Look Out Highway,2025-05-16 发行)。
    - **先分清**:八源零候选里,**七个是真没有**——酷我/LRCLIB/AMLL 曲库里压根没有
      (LRCLIB 连这位歌手一条都没有),QQ 只有歌手没有这张专辑,LyricFind 地区封锁;
      **网易云和酷狗都"有歌无词"**(网易三条 id 全部零歌词;酷狗唯一精确命中 244s,
      krcs 三种查法都 0 条)。这是张 2025 年 5 月的新专辑,还没人做时间轴。
      **只有 Musixmatch 那条是我方缺口。**
    - 病灶**两层,缺一层都修不好**:
      ① `resolveMusixmatchLyric` 只调 `track.subtitle.get`(带时间戳的字幕),拿不到就
      `return musixmatchResult{}`,从不回退问 `track.lyrics.get`;
      ② 更靠前的 `musixmatchSearchTrackOnce` 里有一道 `if HasSubtitles != 1 { continue }`
      —— 目标曲目在**搜索阶段**就被跳过了。⚠️ 只补①的话回退是**死代码**(第一版就是这么
      写的,靠继续读代码才发现,不是靠测试)。
    - 实测证据:`track.subtitle.get` → **404**;`track.lyrics.get` → **200 + 616 字完整
      歌词**。曲目元数据明写 `has_lyrics=1 / has_subtitles=0`。
    - 修法:`pickMusixmatchTrackRow` 改成**两趟**——第一趟只认 `has_subtitles==1`
      (跟放宽前逐字节一致,有时间轴的永远优先),第一趟空手才走第二趟认 `has_lyrics==1`;
      `resolveMusixmatchLyric` 在拿不到字幕时回退取纯文本,走**既有的** `plainOnly` 通道
      (lrclib 2026-08-30 起就在喂),不是新造一条路:分数钉死 -1、绝不被自动解析选中,
      只在弹窗里带「无时间戳」标签由用户决定采纳。纯文本这条路不取逐字、不取译文
      (译文是按行贴回带时间戳的 LRC,喂无时间戳正文只会产出畸形结果)。
    - ⚠️ **水印:本项目这组身份(`apic-appmobile` + `mac-ios-v2.0`)实测不带**
      (抓这首核实:24 行 616 字,末行就是最后一句歌词,没有 `*******` 围栏、没有追踪号)。
      网上大多数参考实现描述的那个「NOT for Commercial use」水印是 `web-desktop-app-v1.0`
      那组才有的,**别当既成事实照抄**。`sanitizeMusixmatchPlainLyrics` 仍然写了剥离,
      但只认极特征化的两种形态,并有专门的反例用例钉住"不许误伤 `(2)`/`(x3)`/`*强调*`"。
    - 回归口径(用户要求):改动前先存基线,改完同一口径对比 —— **顶层测试 397→402 通过、
      0 失败、无任何回归**(新增 4 条是本次补的单测;`TestRetryArtistIdentities…` 是既有的
      打线上 MusicBrainz 的 flaky 测试,基线那次被限流失败、这次通过)。六个变异全部被抓住,
      含"退回只认 has_subtitles"(= 本次的死代码陷阱本身)和"两趟合成一趟"(放过头)。

39. **QQ 音乐的"搜索"一直用的是搜索框自动补全接口,对长尾曲目整片静默失效**
    (2026-09-02,起因是用户报 Have Gun, Will Travel《Gravity Blues》八个源 0 候选)。
    - **先分清**:那首歌八源零候选**全部是真没有**,不是我方缺口——网易云/QQ/酷狗/
      Musixmatch 四家**都收录了音频**(时长都是 235s、跟 Apple 的 235.625s 对得上),
      但四家的歌词库都是空的(网易 `lrc`/`klyric`/`yrc` 全空;QQ 歌词接口 `retcode -1901`;
      酷狗拿正确 hash 查 krcs 得 0 个候选;Musixmatch `has_lyrics=0` 且 `track.lyrics.get`
      直接 404);酷我/LRCLIB 曲库里压根没有(LRCLIB 连这个乐队一条都没有);AMLL 靠网易 id
      取 ttml,404;LyricFind 本机地区封锁判不了。这是 2025-01-04 发行的独立乐队单曲,
      发行商把音轨铺到了各平台、歌词没人录。**排查本身没找到我方 bug,但顺带挖出了下面
      这个。**
    - 病灶:`qq.go` 的歌名维度检索走的是 `smartbox_new.fcg`——那是**搜索框自动补全**,
      有很高的热度门槛,不是搜索。旧注释断言 "client_search_cp returns zero bytes under
      anti-scrape",于是整条链路只剩 smartbox。而"回 0 条"跟"QQ 根本没收录这首歌"长得
      一模一样,**从外面完全看不出来**,QQ 这一源在欧美独立/长尾曲目上常年等于不存在。
    - 实测对比(2026-09-02):

      | 查询词 | smartbox | client_search_cp |
      |---|---|---|
      | 周杰伦 稻香 | 4 条 | 6 条 |
      | Taylor Swift Lover | 2 条 | 6 条 |
      | Geese Gravity Blues | **0 条** | 6 条(第 1 条即目标) |
      | Charlie Musselwhite Storm Warning | **0 条** | 6 条(第 1 条即目标) |
      | 裘德 寻找一片青草地 | **0 条** | 6 条(第 1 条即目标) |
      | Have Gun, Will Travel Gravity Blues | **0 条** | 6 条(第 1 条即目标) |

      那句旧结论现在**不成立**:`client_search_cp` 裸请求就能用(不带 UA、不带 Referer
      同样 200),连打 6 次响应字节数完全一致,Go 的 `http.Client` 与 curl 结果相同。
    - 修法三件事,**每一件都对应一个改到一半才实测暴露出来的坑**:
      ① **换接口**(`qqClientSearch`)。新接口顺带把专辑名和官方时长写在搜索结果里,
      原样透传进候选 —— 专辑名喂 `versionTagsMismatch`/弹窗展示,时长喂
      `sourceDurationMismatchPenalty`,跟专辑维度路线填 `interval` 是同一字段同一语义。
      ② **跨标题变体合并,不再"第一个非空就返回"**。旧策略暗中依赖"smartbox 对带括号的
      查询词恒 0 条"→ 必然轮到去括号那版;换成真搜索后带括号也有结果,去括号那版再没机会
      被查。实测踩中:周杰伦《七里香 (Live)》查带括号只回**无与伦比**演唱会那版,查去括号
      才有本地专辑对应的**地表最强**那版(两版曲名都叫"七里香 (Live)",只有专辑名分得开)。
      ③ **smartbox 是补充,不是兜底**。两个索引**互补**:PRINCE《Little Red Corvette》
      实测 n 开到 30,`client_search_cp` 回来的只有 The Hits 精选 / Single Version /
      2019 重制 / Live 广播四个版本,原版专辑《1999》那条**一次都没出现**,而 smartbox
      恰恰只回那一条。条件收在"正式搜索没给出任何标题精确同名候选"上,常见情况省掉这次
      请求;正式接口哪天再被反爬打死 → 结果为空 → 必然补 smartbox,自动退回改造前的行为。
    - 另外两处配套:
      - "补专辑名最多打 4 次详情请求"这个上限,改成**只约束真正要发请求的候选**
        (`qqAlbumLookupBudget`)。上限当年是照 smartbox 那种短而紧的候选表定的,套在一次
        回十条的正式搜索结果上会把正确的挡在门外。
      - 新增**署名集合相等**这一档 tiebreak(`qqCreditSetEqual`),只在"标题精确同名"和
        "专辑分"都打平时生效。实测踩中:陶喆《逗阵兄弟 (独唱版)》,QQ 上独唱(陶喆,335s)
        与合唱(陶喆/卢广仲,306s)**同名同专辑**,改造前靠 smartbox 只回独唱那条侥幸选对,
        合并召回后两条同池,胜负就只由排序决定 —— 而排序恰恰是 `searchTitleVariants`
        的既有约定顺带决定的(标题装饰不在已知版本限定词表内时,去括号那版排前面),
        不是可靠信号。所以补一个**显式**判据,不去动那个排序约定。
    - ⚠️ **这一档不能加宽成准入闸**:Apple 常把 feat 歌手写在**标题**里、artist 字段只有
      主唱,此时署名集合必然不等。实测 Musiq Soulchild《Ifiwouldaknew (feat. Aaries)
      [Girlnextdoor remix]》就因此没能升级到真正的 remix 那条(与改造前一致、不是回归)。
      刻意**不**为它再叠特例:收益只是把一条持平变成改善,代价是引入一条容易误伤的规则。
    - 回归口径(用户要求):
      - 顶层测试 **402→427 通过、无任何回归**(新增 25 条 = 本次 24 条新单测 + 既有那条
        打线上 MusicBrainz 的 flaky 测试;它在基线和这次都因超时失败,与本改动无关)。
      - **28 个变异 27 个被抓**,漏的那个经核对是等价变异(去掉 `len(items)==0` 卫语句后
        空切片走循环零次迭代、返回值相同)。
      - **拿用户真实 `enrich-cache.json` 里 80 首歌回放**(45 首已有 QQ 解析结果 + 35 首
        没有),只替换 `qq.go`、其余代码与环境完全一致,比对 `resolveQQMusicMatch` 选中的
        mid:**同一首 67 / 新找到 6 / 丢失 0 / 换了一首 7,且 7 条全部是改善** ——
        Queen《Dragon Attack (Live…)》与方大同《Singalongsong (Live)》从录音室版换成
        真正的现场专辑;MJ《She Drives Me Wild》从"黑胶版"换成专辑名精确相等的那条;
        MJ《The Way You Make Me Feel (2012 Remaster)》换成真正的重制版;蛋堡《过程
        (…remix)》换成真正的 remix;动力火车那条从一张 live 专辑换成非 live 的合辑
        (本地曲名不带 live);Musiq Soulchild《Future》**旧选中的那个 mid 歌词是 0 字节**、
        新的有 2928 字节。
