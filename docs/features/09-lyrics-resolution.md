# 09. 歌词解析决策（collector）

> 最后核对：2026-08-20 · 基线：2a2bf8b+工作树

## 定位

collector 的核心：一首歌播放时，去五个歌词源检索候选、校验、打分、选出一份最终歌词（连同译文/罗马音/逐字时间轴），写进 enrich 缓存永久保留。App 的所有歌词展示面都消费这份结果。

## 入口与展示面

- **自动路径**：poller 换歌/循环重启时经 `trackEnrichment` 判缓存，未命中异步起 `resolveEnrichAsync`。用户无感，结果出现在所有歌词展示面。
- **手动路径**：「歌词管理」窗口的「联网搜索候选歌词」→ `collector search-lyrics` CLI 子命令（复用同一套检索+打分，但保留完整候选列表交用户挑、不自动落盘）。
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
- **首歌手变体轮**（2026-08-20，「wherever u r」案）：可用候选的**启用源数** < min(2, 启用源总数) 且歌手串是多人合credit 时，用 `lyricPrimaryQueryArtist`（词级剥 feat./ft./featuring + `firstCreditedArtist`）截出首歌手再查一轮，仍不够再试首歌手的别名/MB 中文名（最多 3 轮）。变体轮结果**合并**进原串轮而非替换（`mergeLyricCandidateRounds`：按源去重、原串轮可用者优先、判废才顶替，合并后按**原串**统一重打分——变体串只作检索词和源内采纳闸，绝不进打分，防语言闸误杀）；变体轮的 `ne` 只许补封面/跳转链接（Album/AlbumID 跟着封面一起走，保 CoverAlbum 配对），**绝不采用其 Artist**——防 canonical_artist 把「A & B」缩窄成「A」（2026-07-10 回归形态）。触发判据数的是**启用**源（禁用源不算「信息够了」），单源配置封顶为 1、该源已成功时不多跑。别名重试触发时机的教训：网易云一条可用候选就能把整个重试短路，酷狗/QQ 的逐字候选永远没机会被看见——「有一条可用」不等于「信息够了」。

### 3. 五源并发收集（总截止 20 秒）

5 歌词源 + Apple 封面共 6 路 goroutine 并发（`fetchScoredLyricCandidatesStreaming`），到点未回的源本轮作废（由「升级重试」事后补救）。

| 源 | 专辑参与检索 | 逐字 | 译文 | 罗马音 | 封面 | 特殊点 |
|---|---|---|---|---|---|---|
| netease | 是（albumScore 择优） | YRC 原生 | 中文 tlyric | romalrc | 600px | 仿冒黑名单（周杰伦）命中整源跳过；**带纯音乐标记**（顶层 `pureMusic` 或「纯音乐」占位正文，2026-08-20 加） |
| qq | 前 4 条补查专辑 | QRC→YRC | 无 | 无 | 走独立兜底路 | QRC 3DES+zlib 解密；贪婪正则防双引号截断 |
| kugou | **不参与** | KRC→YRC（相对转绝对） | 无 | 无 | 无 | 空格必须 %20 |
| lrclib | 仅精确档（三级降级） | 无 | 无 | 无 | 无 | 带纯音乐（instrumental）标记 |
| musixmatch | 不参与 | richsync→YRC | **可选语言** | 无 | 500px | DoH 防 DNS 污染；匿名 token 双缓存；richsync 把**空格当独立计时条目**、掏空短词的读条时长（实测 "In" 23ms＋空格 165ms，悬浮窗观感"没有读条直接填满"）——`richsyncToYRC` 归并空白条目进前词（2026-08-19），存量缓存由启动迁移 `migrateYRCWhitespaceTokens`（yrcwhitespace.go，夹在 import 与 export 之间、幂等）原地清洗，无需重新联网解析 |

所有源共用两道身份闸：`lyricTitleAccepted`（归一相等/剥括号相等/双语前缀，**绝不认任意子串包含**）+ 歌手闸。歌手闸 2026-08-20 起分两套：**歌词候选采纳**（kugou/qq strict 档/lrclib search/musixmatch）用 `lyricSourceArtistMatches` = `artistMatches` + 「两侧都是多人合credit 时段集有交集即过」——跨服务合唱署名会换分隔符、换合作者语言写法（「UMI、V」vs「UMI & 金泰亨」），要求整串对上等于要求两边曲库同一套署名习惯，实测酷狗服务端召回明明成功、正主却死在客户端闸上；交集档仍要求两侧各切出 ≥2 段（「周杰伦、」进不了）、段间字节相等（「周杰伦-」不认）。**身份判定/防仿冒**（netease 的 nameOnlyMatch、canonical 统一拼写、qqCoverFallback）仍用原 `artistMatches`（多人 credit 逐段精确相等 + 连续段拼回救 K/DA 类名字，拒绝「周杰伦、」式仿冒尾巴），刻意不放宽。

### 4. 资格守卫

- **一票否决**（判 -1，两种挑选模式都跳过）：
  - `rejectNotTimed`：不是真 LRC（带戳行 <3 或不过半，或串长 ≥20000）；
  - `rejectWrongLanguage`：本地歌手+歌名均无汉字但歌词汉字占比 >0.5；
  - `rejectCreditOnly`：整份只有署名行（关键词正则 + 「≤8 汉字+冒号」结构兜底，去掉后正文 <3 行），或含「纯音乐」占位；
  - `rejectNoLastTimestamp`：提不出末句时间戳。
- **逐字覆盖率守卫** `usableWordTiming`：YRC 末时刻 < LRC 末时刻 ×0.5 就当没有逐字（防 QQ 截断残片骗 +400 又被「已有逐字不重试」钉死；阈值实测依据：残片覆盖 19.1%、正常最低 85.4%）。

### 5. 打分（`lyricsScoringVersion = 3`）

| 项 | 分值 | 条件 |
|---|---|---|
| 时长吻合 | +100~+300 连续衰减 | 偏差 ≤25% 且末句不超曲长 5s |
| 末句超曲长 5s | **-700** | 物理矛盾档，不吃印证豁免 |
| 跨源末尾印证 | +100 | ±5s，且仅当批内无人时长吻合 |
| 时长明显不符 | -500 | 原一票否决，实测误杀 5:1 后改重扣 |
| 逐字时间轴 | **+400** | 过覆盖率守卫 |
| 与当前播放器同源 | +250 | 放 QQ 音乐偏向 QQ 词（理由是时间轴对齐，非内容质量） |
| 行数 | +1/行，封顶 200 | |
| 版本限定词错配 | -600 | 歌名∪专辑名比对 |
| 专辑亲和 | +150/+75/+40 | 只加不减（专辑对不上是零证据非负证据） |
| 标题吻合梯度 | +120/+60/+30 | 精确/剥括号带版本词/双语 |
| 跨源正文共识 | +250（2 家）/+150（1 家） | 3-gram Jaccard ≥0.55、正文 ≥30 rune；时长不吻合/overshoot 者共识清零 |
| 可用译文 / 罗马音 | +50 / +30 | 语言、时间轴、覆盖率均有资格闸 |

负分统一夹到 1（重扣=「差」，负分只留给否决）。**没有静态来源加分**——2026-08-09 被 250 首消融实验删除（改变 69 首冠军、0 次变对/6 次变错，删掉后一致性 93%→96%）。

### 6. 挑选（设置里的「匹配算法」，`pickLyricCandidate`）

- **智能**（默认）：只看启用的源，取最高分；平手按稳定排序=候选构造顺序（netease→qq→kugou→musixmatch→lrclib）决胜。
- **顺序优先**：按用户排序找第一个「有 Score≥0 候选」的源，**完全不比分数**。
- **被禁用的源照样会查**（五路无条件并发），过滤只发生在挑选步——切换设置不用重搜。
- 歌词/译文/罗马音/逐字**整体跟着冠军走**，不存在跨源拼装。唯一的独立补充是机翻译文（见第 10 章）。
- 全部源空：不写歌词但照记决策；**纯音乐标记**透传给 UI；条目所有字段全空则整条不落盘（防断网钉死失败）。
- **纯音乐标记的两个来源**（2026-08-20 从只有 lrclib 扩成两个）：①lrclib 响应里的结构化 `instrumental`；②网易云歌词接口的顶层 `pureMusic`，或正文只有「纯音乐」占位 + 署名行（`isNeteasePureMusicLyric`，占位文案复用 `neteaseInstrumentalPlaceholderMarker`）。两者都以 `Score:-1 / Instrumental:true` 的搭车标记进 results，不参与打分/挑选；`mergeLyricCandidateRounds` 保留标记的条件按**标记自己的源**判（原来写死 lrclib）。起因是用户报「一堆条目显示无歌词、其实都是纯音乐」（LoL 原声带 12 首）：lrclib 压根没有这批曲目（五源全空），而网易云匹配上了歌、歌词接口明确回 `pureMusic=true`，但那个字段**不在解码结构体里**、占位正文又过不了 `isTimedLRC` 的三行门槛，于是结论在解码那一步就丢了。
- ⚠️ 同一次修复补了第三个漏点：`retryLyricsUpgrade`（升级重试 / 补空重试）**从来不写** `instrumental`——只有 first-resolve 那条路径写。于是「当初那轮没有这个信号、后来有了」的条目永远拿不到标记，还要每 24 小时（退避后翻倍）白搜一轮。现在两条路径都写，标记落地后 `needsLyricsFirstFill` 直接 return，重搜也省了。
- 存量条目补标记用 `collector recheck-instrumental [-apply] "歌手|歌名|专辑" ...`：只写 `instrumental` 一个字段（这轮真搜到歌词就交回补空路径，一次性命令不碰歌词），dry-run 默认、`-apply` 要求常驻实例已停。

### 7. 封面选源（跟歌词同一趟解析，但独立决策）

固定顺序 **网易云 → Apple Music → QQ**，先拿到就用。这个顺序管的是**可加载性**：网易云图床（`p*.music.126.net`）国内加载得出来，Apple 的 mzstatic 国内已无 CDN 节点。`cover_source` 如实记来源；`cover_album`（2026-08-20 加）记这张封面在来源平台上属于哪张专辑。

**一道专辑感知的例外**（`preferAppleCoverOverNetease`）：网易云那张明确属于**另一次发行**（`albumScore=0`）、而 Apple 那张对得上正在播的这张专辑（`albumScore>0`）时，改用 Apple 的。只换封面，网易云的歌词/译文/罗马音不动——那些跟「哪张发行」无关。本地没有专辑标签时这条例外一律不生效（对不对版无从判断）。

为什么需要这道例外：顺序不管对不对版，而**专辑本身没上网易云、只有先行单曲**时两者会打架——`pick()` 那条「唯一精确同名候选、专辑名对不上也认」的规则（刻意保留）会命中单曲版，于是同一张专辑的曲目一半拿单曲封面、一半退到 Apple 拿专辑封面。实测见「设计决策与已知坑」11。

存量条目（没有 `cover_album` 的老记录）判不出对不对版，靠外围补全补查一次，见下一节。

### 8. 决策留痕

每轮评估（first-resolve / upgrade / rescore）固化成 `lyrics_decision`：查询词、时长、哪些源应答、全部候选的分数明细与被拒原因、胜者、是否真的生效（Applied）。三条铁律：只存元数据不存正文；**只写不读**（不许反过来影响决策）；手改条目不覆盖记录。另有默认关闭的 NDJSON 流水账（`lyrics_decision_trace`，2MB 轮转）。

### 9. 事后自愈（缓存命中时一次只派一路，固定优先级）

1. **外围补全**：封面主色/平台链接/canonical_artist 缺失，**或封面属于哪张专辑对不上/不详**（`coverNeedsAlbumCheck`，只查 `cover_source=netease` 那档）才补；10 分钟节流、上限 5 次；不碰歌词。真要换封面还得过 `coverSwapAllowed`——跨源替换要求「这一轮网易云真的应答过 + 新封面对得上专辑」，否则网易云一次限流（HTTP 200 + body code 405）就能把一张对版、国内加载得出来的封面换成 mzstatic 的。
2. **rescore**：打分规则版本落后时按新规则重选（**不比大小**）；1 小时节流、上限 3 次；要求当前歌词的源本轮也应答了才够格推翻。
3. **升级重试**（`needsLyricsRetry`）：当初有启用的源没赶上 20s 截止才重搜；6 小时节流、上限 3 次；新分**严格更高**才替换（跨打分版本用 `lyricsUpgradeBaseline` 换同尺度基准）。已有逐字不重试，两个例外可翻盘：「同源候选当初落选」（换播放器场景）与「时长差 >12%」。
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
- 各源自有内存/磁盘缓存（网易云 30 天/10 分钟分级、musixmatch token 9 分钟等）。

## 代码锚点

| 主题 | 位置 |
|---|---|
| 入口/缓存判定/自愈调度 | lyrimuse-collector/enrich.go `trackEnrichment` `resolveEnrichAsync` |
| key 推导 | enrichkey.go `enrichKey` `normEnrichTitle`；迁移 `migrateEnrichKeys` |
| 五源并发/流式 | enrich.go `fetchScoredLyricCandidatesStreaming` |
| 打分 | match.go `scoreLyricCandidateDetailed`（版本 `lyricsScoringVersion`） |
| 挑选 | enrich.go `pickLyricCandidate` |
| 守卫 | match.go `isTimedLRC` `isProbablyWrongLanguageLyrics` `isCreditOnlyLRC` `usableWordTiming` |
| 重试/重打分 | enrich.go `needsLyricsRetry` `retryLyricsUpgrade` `needsLyricsRescore` `rescoreLyrics` |
| 已校准一票否决 | lyricspins.go `lyricsPinned` `readLyricsPins`;Swift 侧 `LyricsPinStore` |
| 决策留痕 | decision.go `buildLyricsDecision`；lyricstrace.go |
| 各源 | netease.go / qq.go / kugou.go / lrclib.go / musixmatch.go |
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
