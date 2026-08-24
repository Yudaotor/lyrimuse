# 09. 歌词解析决策（collector）

> 最后核对：2026-08-24 · 基线：42ef515+工作树

## 定位

collector 的核心：一首歌播放时，去六个歌词源（网易云/QQ/酷狗/Musixmatch/LRCLIB/AMLL，2026-08-24 起）检索候选、校验、打分、选出一份最终歌词（连同译文/罗马音/逐字时间轴），写进 enrich 缓存永久保留。App 的所有歌词展示面都消费这份结果。

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

### 3. 六源并发收集（总截止 20 秒）

6 歌词源 + Apple 封面共 7 路 goroutine 并发（`fetchScoredLyricCandidatesStreaming`），到点未回的源本轮作废（由「升级重试」事后补救）。amll 那一路要等 netease/qq 把音乐 ID 搜出来（用两个带缓冲 channel 递过去），所以它总是最后回。

| 源 | 专辑参与检索 | 逐字 | 译文 | 罗马音 | 封面 | 特殊点 |
|---|---|---|---|---|---|---|
| netease | 是（albumScore 择优） | YRC 原生 | 中文 tlyric | romalrc | 600px | 仿冒黑名单（周杰伦）只扣身份/封面、歌词照常参与（2026-08-22 改，原为整源跳过）；**带纯音乐标记**（顶层 `pureMusic` 或「纯音乐」占位正文，2026-08-20 加） |
| qq | 前 4 条补查专辑 | QRC→YRC | 无 | 无 | 走独立兜底路 | QRC 3DES+zlib 解密；贪婪正则防双引号截断 |
| kugou | **不参与** | KRC→YRC（相对转绝对） | 无 | 无 | 无 | 空格必须 %20 |
| lrclib | 仅精确档（三级降级） | 无 | 无 | 无 | 无 | 带纯音乐（instrumental）标记 |
| amll | **不检索**（按 ID 直取） | TTML→YRC | 内嵌 `x-translation` | 无 | 无 | 见下 |
| musixmatch | 不参与 | richsync→YRC | **可选语言** | 无 | 500px | DoH 防 DNS 污染；匿名 token 双缓存；richsync 把**空格当独立计时条目**、掏空短词的读条时长（实测 "In" 23ms＋空格 165ms，悬浮窗观感"没有读条直接填满"）——`richsyncToYRC` 归并空白条目进前词（2026-08-19），存量缓存由启动迁移 `migrateYRCWhitespaceTokens`（yrcwhitespace.go，夹在 import 与 export 之间、幂等）原地清洗，无需重新联网解析 |

所有源共用两道身份闸：`lyricTitleAccepted`（归一相等/剥括号相等/双语前缀，**绝不认任意子串包含**）+ 歌手闸。歌手闸 2026-08-20 起分两套：**歌词候选采纳**（kugou/qq strict 档/lrclib search/musixmatch）用 `lyricSourceArtistMatches` = `artistMatches` + 「两侧都是多人合credit 时段集有交集即过」——跨服务合唱署名会换分隔符、换合作者语言写法（「UMI、V」vs「UMI & 金泰亨」），要求整串对上等于要求两边曲库同一套署名习惯，实测酷狗服务端召回明明成功、正主却死在客户端闸上；交集档仍要求两侧各切出 ≥2 段（「周杰伦、」进不了）、段间字节相等（「周杰伦-」不认）。**身份判定/防仿冒**（netease 的 nameOnlyMatch、canonical 统一拼写、qqCoverFallback）仍用原 `artistMatches`（多人 credit 逐段精确相等 + 连续段拼回救 K/DA 类名字，拒绝「周杰伦、」式仿冒尾巴），刻意不放宽。

**第三档（`lyricRecordingTriangleMatches`，2026-08-22 加，只挂在 kugou 一处）**：歌手闸不过时，再看「标题逐字同名 + 专辑对得上 + 时长紧密吻合」——三者同时成立就判定为同一次录音、放行歌词候选。四道判据都必须过：①`normLoose` 标题**逐字**相等（不接受`lyricTitleAccepted` 的剥括号档/双语档，那两档本身就是放宽，跟「歌手名不可信」叠加就是双重放宽）；②两边自报时长差 ≤**1%**（比打分层的 25% 严 25 倍——那一层量的是「LRC 末句 vs 曲长」、被前奏尾奏系统性带偏所以必须宽松，这里量的是两边各自自报的曲目时长，同一次录音跨平台只差在取整）；③`albumScore ≥ 200`，或 `≥ 100` 且候选专辑名归一后长度 ≥ 本地的 60%（本地专辑没标签一律不给）；④`versionTagsMismatch` 为假。**只放行歌词，绝不放行身份/封面**——沿用已知坑 12 那次确立的分层。`lyricrecordingtriangle_test.go` 里有一个扫 netease.go/qq.go 源码的守卫测试，防它被顺手推广到那两处的身份判定上。

**amll（amll-ttml-db，2026-08-23 加）** 跟其余五源是两种东西：

- **不搜索、按平台音乐 ID 直取** `raw.githubusercontent.com/amll-dev/amll-ttml-db/main/{ncm|qq}-lyrics/{id}.ttml`，404 即没有。ID 来自 netease 的 `SongID` 和 qq 的 `songmid`，所以它的身份确定性等同于那两个源；候选的 title/artist/album 直接沿用本地曲目信息，不会在那几项上被扣分，也不自报时长（该项不参与打分）。
- **格式本身能携带演唱者归属**：`<ttm:agent type="person|group" xml:id="v1">` + 每行 `ttm:agent="v1"`。落盘时转成行首前缀（person 按出现顺序编号成 `v1：`/`v2：`，group 一律 `合：`，**只有一位演唱者时不写前缀**），复用 `LyricDuet` 那条现成管线 —— `v1`/`v2` 收在 `anonymousMarkers` 里直通整份闸，因为 agent 是上游人工标注的权威信息，不该再拿为民间夹带设计的启发式去二次判它。
- **背景人声（`ttm:role="x-bg"`）整枝跳过**：它跟主歌词时间轴重叠，并进去会让逐字填色同一时刻两个词在亮，而我们还没有这个显示概念。
- **开关不在 `lyrics_sources` 里**，走独立的 `amll_lyrics`（三态：缺失=开、显式 false=关）。理由：`lyrics_sources` 非空即白名单，而老配置是在这个源存在之前写的，并进去等于对所有老用户默认关闭；无条件补齐又会让「用户主动取消勾选」永远生效不了。启用判定统一收进 `lyricSourceEnabled()`（此前散在六处、形式还不一致）。
- ⚠️ **词间空白必须按文档顺序读**（2026-08-24 修）：amll-ttml-db 里两种写法并存 ——`<span>What</span> <span>a</span> <span>ride</span>`（空格在 span **之间**，属于 `<p>` 自己的 chardata）和 `<span>How </span><span>it </span><span>goes</span>`（空格在 span **内部**）。初版用 Go 的声明式 tag（`Spans []ttmlSpan` + `,chardata`）解析，而 `encoding/xml` 会把一个元素的**全部**直接文本合并成一个字符串、顺序全丢，于是前一种写法拼成了 `Whataride`。用户报的症状是**「这些歌词没有翻译」**：粘住的假词翻译器原样返回，`translate.go` 那道「没翻动的行不写进译文」（`t == l.text`）把整行丢掉——《What a Day》78 行只出了 32 行译文。实测用户库 4 首 amll 来源的歌**全中**，每首 26~42 行粘连。修法是自己实现 `UnmarshalXML` 走 token 流（`decodeTTMLKids`），把词间空白挂到**前一个词**的尾巴上——这样 `words.joined()` 恒等于整行文本，Swift 侧 `plainText == words.joined()` 那道逐字守卫才过得去。⚠️ **别用「干脆用空格 join」偷懒**：同一行里可能既有不带空白的音节切分（`ka`+`raoke`）又有带空白的词边界，空格 join 会把音节也拆开（回归测试 `TestParseAMLLTTMLWordSpacing` 第 5 行专门钉这个）。中文逐字写法（`<span>没</span><span>有</span>`）span 之间本来就没有空白，不受影响。
- ⚠️ **覆盖率有限**：实测（2026-08-23）对 439 首曲库严格命中 **17 首（3.9%）**——口径是「歌名一字不差 + 只算 ncm/qq」（只有这两个平台的音乐 ID 我们拿得到）。**别用「去括号再比」的宽松口径估这个数**：那样会把《告白气球 (Live)》算成录音室版的命中，而按 ID 直取时 Live 版有自己的 songID、amll 里没有，实测 404。库的重心是游戏音乐 / V 家 / 欧美新流行（HOYO-MiX 841 条、Shawn Mendes & Camila Cabello 各 510、Taylor Swift 418、原子邦妮 395、GARNiDELiA 332），华语主要是周杰伦（176）和邓紫棋，跟华语老歌重合度低。接它的理由是命中那些歌的**歌词质量**（人工校对 + 逐字 + 内嵌译文），不是对唱兼容率 —— 15 首对唱歌它只有 3 首，而那 3 首现有解析已经能处理。

### 4. 资格守卫

- **一票否决**（判 -1，两种挑选模式都跳过）：
  - `rejectNotTimed`：不是真 LRC（带戳行 <3 或不过半，或串长 ≥20000）；
  - `rejectWrongLanguage`：本地歌手+歌名均无汉字但歌词汉字占比 >0.5；
  - `rejectCreditOnly`：整份只有署名行（关键词正则 + 「≤8 汉字+冒号」结构兜底，去掉后正文 <3 行），或含「纯音乐」占位；
  - `rejectNoLastTimestamp`：提不出末句时间戳。
- **逐字覆盖率守卫** `usableWordTiming`：YRC 末时刻 < LRC 末时刻 ×0.5 就当没有逐字（防 QQ 截断残片骗 +400 又被「已有逐字不重试」钉死；阈值实测依据：残片覆盖 19.1%、正常最低 85.4%）。

### 5. 打分（`lyricsScoringVersion = 4`）

| 项 | 分值 | 条件 |
|---|---|---|
| 时长吻合 | +100~+300 连续衰减 | 偏差 ≤25% 且末句不超曲长 5s |
| 末句超曲长 5s | **-700** | 物理矛盾档，不吃印证豁免 |
| 跨源末尾印证 | +100 | ±5s，且仅当批内无人时长吻合 |
| 时长明显不符 | -500 | 原一票否决，实测误杀 5:1 后改重扣。量的是「LRC 末句 vs 曲长」这个**代理** |
| **源自报曲长不符** | **-400** | v4 新增。量的是两个**曲目时长**的直接比对（`sourceReportedDurationSecs` vs 本地），偏差 >12%（分母取较大者，复用 `wrongDuration` 的口径）。**只扣不加**，源没自报（0）不扣 |
| 逐字时间轴 | **+400** | 过覆盖率守卫 |
| 与当前播放器同源 | +250 | 放 QQ 音乐偏向 QQ 词（理由是时间轴对齐，非内容质量） |
| 行数 | +1/行，封顶 200 | |
| 版本限定词错配 | -600 | 歌名∪专辑名比对；词表 2026-08-22 补了 `club mix`/`radio mix`/`house mix`/`dub mix`/`dance mix`/`vocal mix`/`club edit` |
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

每轮评估（first-resolve / upgrade / rescore）固化成 `lyrics_decision`：查询词、时长、哪些源应答、全部候选的分数明细与被拒原因、胜者、是否真的生效（Applied）。三条铁律：只存元数据不存正文；**只写不读**（不许反过来影响决策）；手改条目不覆盖记录。另有默认关闭的 NDJSON 流水账（`lyrics_decision_trace`，2MB 轮转）。

**两槽存档**（2026-08-22）：`lyrics_decision` 是「最近一次评估」，可能维持原状、甚至输入本身是脏的；`lyrics_decision_applied` 是「当前歌词的出处」——最近一次「胜者内容成为（或确认仍是）当前歌词」的评估（first-resolve 选中 / upgrade 换上或胜者=现存 / rescore 可判有胜者 / manual-rematch 采纳时由 App 侧同写）。分槽的起因：一轮被换曲窗口串扰时长（见下面「升级重试」的去抖）的 upgrade 评估把 first-resolve 的存档盖掉，「解析决策」展示的记录跟生效歌词对不上号，用户拿它跟手动重搜一比更懵。老条目没有第二槽，App 侧按「最近评估恰好 Applied 即出处」退化。

### 9. 事后自愈（缓存命中时一次只派一路，固定优先级）

1. **外围补全**：封面主色/平台链接/canonical_artist 缺失，**或封面属于哪张专辑对不上/不详**（`coverNeedsAlbumCheck`，只查 `cover_source=netease` 那档）才补；10 分钟节流、上限 5 次；不碰歌词。真要换封面还得过 `coverSwapAllowed`——跨源替换要求「这一轮网易云真的应答过 + 新封面对得上专辑」，否则网易云一次限流（HTTP 200 + body code 405）就能把一张对版、国内加载得出来的封面换成 mzstatic 的。
2. **rescore**：打分规则版本落后时按新规则重选（**不比大小**）；1 小时节流、上限 3 次；要求当前歌词的源本轮也应答了才够格推翻。
3. **升级重试**（`needsLyricsRetry`）：当初有启用的源没赶上 20s 截止才重搜；6 小时节流、上限 3 次；新分**严格更高**才替换（跨打分版本用 `lyricsUpgradeBaseline` 换同尺度基准）。已有逐字不重试，两个例外可翻盘：「同源候选当初落选」（换播放器场景）与「时长差 >12%」。⚠️ **Apple Music 现在多了一道上游防线**：Apple 目录锚点成立时，时长直接用 Apple 目录的权威值，脏快照在进入这条链路之前就被顶掉了（见第 02 章）。锚点对用户自己导入的曲库和别的播放器无效，所以下面这道去抖仍是必需的。⚠️ 时长差这条的原始观察值必须先过 `observeWrongDuration` 的 **30 秒同值去抖**（2026-08-22）：换曲/预载窗口里 media-control 会把**下一首**的时长和当前曲目的标题拼进同一份快照（实锤：「开不了口 (Live)」272.973s 开播 6 秒后，relay 快照携带同专辑下一首「床边故事 (Live)」的 220.239s，逐位一致），一次性脏观察直接当真会白烧一轮重试、所有候选按错误时长吃 -700、还把决策记录盖掉。同一脏值（±1s）稳定满 30 秒才触发；时长又对上即清零；观察断流超 5 分钟按陈旧重计（防"切出侧脏值残留 + 几天后重放同曲第一口又是脏值"拿旧 firstSeen 一步凑满窗口；上限须盖过稳定播放期的正常喂食间隔——relay 心跳/LB 提交都是 ≤4 分钟一次）；确认放行同时清记录（下一轮重新攒，不会连发烧光预算）。
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
- **lyrics/ 文件夹**（第 11 章）：歌词六字段以导出文件为权威源，启动时文件覆盖 JSON。

## 数据与文件

- `~/.config/lyrimuse/lyrimuse-enrich-cache.json`：主缓存，无 TTL 永久保留，原子写（temp+rename）+ 互斥锁；损坏文件挪 `.corrupt` 旁路。
- `~/.config/lyrimuse/lyrimuse-lyrics-decision-trace.ndjson`：可选流水账。
- `~/.config/lyrimuse/lyrimuse-artist-primary-cache.json`：MB 主名（本名 ↔ 艺名）缓存，只存查到的条目，见「歌手别名重试」。
- 各源自有内存/磁盘缓存（网易云 30 天/10 分钟分级、musixmatch token 9 分钟等）。⚠️ **musixmatch 换 token 必须单飞**（2026-08-24 修）：批量解析（相册预取/批量导入一次触发十几首歌并发解析）时，原来每个 goroutine 独立判定「没有可用 token」就各自发一次 `token.get`，而 apic 那台机器实测把除第一个之外的并发请求全按反爬拒掉（401 hint=captcha），被拒的按官方样例退避 10 秒重试一次——但 20 秒的搜索预算扛不住 N 个 goroutine 各跑一遍「发请求→等 10 秒→重试」。实测（用户库）批量解析场景 musixmatch 交出候选的比例只有约 20%，单首/大规模顺序扫描能到 65%~90%，量出来的正是这个：一次 16 首并发解析里 musixmatch 是 0/16。修法：`musixmatchTokenFetchMu` 单飞锁包住「读磁盘 + 必要时发网络请求」整段，其余 goroutine 排队等它做完、拿锁后**必须**重新查一遍缓存（前一个持锁者可能已经换好了），不能各自再抢一次网络。`musixmatchCachedToken()` 让 token 仍在有效期内的调用完全绕开这把锁——它只在真的需要刷新时才有意义。回归测试 `musixmatch_test.go` 用 `musixmatchDoFetchToken` 这个缝（nil=用真实实现）验证并发场景，不碰网络。

## 代码锚点

| 主题 | 位置 |
|---|---|
| 入口/缓存判定/自愈调度 | lyrimuse-collector/enrich.go `trackEnrichment` `resolveEnrichAsync` |
| key 推导 | enrichkey.go `enrichKey` `normEnrichTitle`；迁移 `migrateEnrichKeys` |
| 六源并发/流式 | enrich.go `fetchScoredLyricCandidatesStreaming` |
| amll-ttml-db 源 | amllttml.go `amllLyric` `parseAMLLTTML` `amllSpeakerPrefixes`;开关 features.go `lyricSourceEnabled` |
| 演唱者标签(Go 侧) | lyricspeaker.go `lyricSpeakerLabels` `lyricSplitLabel` `isCreditLineWithSpeakers` —— 与 Swift 侧 `LyricDuet` 同口径,改一边必须改另一边 |
| 打分 | match.go `scoreLyricCandidateDetailed`（版本 `lyricsScoringVersion`） |
| 挑选 | enrich.go `pickLyricCandidate` |
| 守卫 | match.go `isTimedLRC` `isProbablyWrongLanguageLyrics` `isCreditOnlyLRC` `usableWordTiming` |
| 歌手闸三档 | match.go `artistMatches` / `lyricSourceArtistMatches` / `lyricRecordingTriangleMatches`（第三档只在 kugou.go `resolveKugouLyric` 调用） |
| Apple 目录锚点 | applecatalog.go `appleCatalogAnchor` `appleCatalogSearchIdentities` `dedupeArtistIdentities`（详见第 02 章） |
| 重试/重打分 | enrich.go `needsLyricsRetry` `retryLyricsUpgrade` `needsLyricsRescore` `rescoreLyrics` |
| 已校准一票否决 | lyricspins.go `lyricsPinned` `readLyricsPins`;Swift 侧 `LyricsPinStore` |
| 决策留痕 | decision.go `buildLyricsDecision`；lyricstrace.go |
| 手动重匹配的可判定性闸 | enrich.go `rescoreDecidable`（第三参 `noCurrentLyrics`）；Swift 侧 `LyricsRematchDecision.decide` |
| 各源 | netease.go / qq.go / kugou.go / lrclib.go / musixmatch.go |
| 纯音乐占位判定 | netease.go `isInstrumentalPlaceholderLyric`；qq.go `resolveQQLyric`→`qqLyricResult`；enrich.go `scoreAndSort` 的 `instrumentalMarker` 三分支 |
| 封面选源 | enrich.go `preferAppleCoverOverNetease` `coverNeedsAlbumCheck` `coverSwapAllowed`；apple.go `searchAppleMusicMatch` `resolveAppleMusicMatchViaAlbum` |
| 专辑预取 | albumprefetch.go `prefetchAlbumSiblings` |
| 手动搜索 | searchcli.go `runSearchLyricsCLI` |

## 设计决策与已知坑

1. 静态来源偏好分被消融实验处决（0 变对/6 变错）——排序照抄先入之见不是证据；同分交给稳定排序。
2. 时长吻合封顶从 1000 压到 300：它只是正确性的间接代理，被前奏/尾奏系统性带偏；逐字时间轴才是直接证据（+400）。
3. overshoot（末句超曲长 5s）独立重罚 -700 且不吃印证豁免：两个源一起抓到同一个错版本正是印证的已知翻车形态。
4. 同源 +250 不是静态偏好回魂：它是动态的（放什么播放器偏什么），修的是时间轴对齐维度，消融实验没测过这个维度。
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




