# 10. 译文与罗马音

> 最后核对：2026-09-03 · 基线：e103532+工作树

## 定位

歌词的两类附加内容：**译文**（社区译文 + 机翻兜底）与**罗马音/注音**（源自带罗马音 + 客户端现算兜底 + 酷狗假名标注 + 粤语粤拼 collector 侧生成兜底）。生成主要在 collector 侧，展示端兜底在 App 侧。

## 入口与展示面

- 展示：桌面悬浮歌词与歌词窗口的译文/罗马音小字行（灵动岛胶囊空间不支持、菜单栏只有单行纯文字）。
- 设置：歌词 → 译文段（显示译文/译文语言/系统兜底翻译/翻译语言包）；歌词 → 效果段（显示罗马音 + 标注哪些语言：日/韩/中/粤）。

## 行为规格

### 1. 译文的来源链

1. **社区译文（随冠军候选走，第 09 章）**：网易云 `tlyric`（固定中文）；Musixmatch `crowd.track.translations.get`（**唯一可选语言的源**，目标语言=设置的译文语言，按原文时间轴逐行拼成独立 LRC）；amll-ttml-db 内嵌的 `x-translation`（2026-08-26 起真正接上，见下面已知坑 9——TTML 没有给译文标语言的字段，语言标注沿用跟"能不能用"判定同一个简化假设：直接记成当前设置的目标语言，不做真实校验）。QQ `GetPlayLyricInfo` 的 `trans`（固定中文，标 `zh`，2026-09-02 起接回；`//` 占位行、版权声明行、`[kana:]` 元数据行在 collector 侧剔掉，格式与实测见第 09 章第 38 条）。酷狗 KRC `[language:]` 内嵌的 type 1 轨（固定中文，标 `zh`，按行序号对齐 KRC 计时行，2026-09-02 起接回，见第 09 章第 40 条）。LRCLIB 无译文。**烘进正文的逐行译文**（任一源，2026-09-04 起）：上传者把中文译文逐句烘进歌词正文（每句外文后紧跟一行独立时间戳的中文；酷我对外文歌是系统性地这么给）——collector 在候选装配前识别并摘出来、挂回原文行的时间戳当 `lyrics_tr`（固定中文，标 `zh`；netease/qq/kugou/kuwo 接上，musixmatch/amll 只摘不接），判据与实测见第 09 章「已知坑」首条与 `bakedtranslation.go` 头注。
2. **机翻兜底（`backfillTranslation`，translate.go）**——触发条件全部满足才跑：
   - 「系统兜底翻译」开关开着（默认关）；有主歌词；目标语言非空；
   - 现有译文对当前目标语言**不可用**（`translationUsable`，语言标签与正文矛盾时以正文为准）；
   - 同目标语言重试 <3 次、距上次尝试 ≥6 小时；歌词本身不是目标语言、至少一行文字系统与目标不同。
   - **机翻永不顶替可用的社区译文**；反过来语言对不上的社区译文会被机翻覆盖。
3. **执行**：整体 90s 上限。只送「与目标语言文字系统不同」的行；优先走**端上 Apple 翻译 helper**（`lyrics-translate` 独立 Swift 子进程，stdin/stdout 各一行 JSON，行数必须原样对齐；不联网、无配额、歌词不出本机；要 macOS 26+（`TranslationSession` 在此之前只能挂在 SwiftUI 视图的 `.translationTask` 上，命令行子进程里构造不出来，见 `lyrics-translate/main.swift:75`），起不来自动退路）；退路 **MyMemory**（15s/请求、单块 ≤460 字符、最多 12 块、随机邮箱绕单地址日配额 ~5000 字符）。行数对不上整块作废；翻出行数 ×3 < 送翻行数判失败。配额用尽只更新时间戳不记次数。成功写 `lyrics_tr` + `lyrics_tr_source="machine"` + `lyrics_tr_lang=目标`。
4. **失配清理**：启动时 `invalidateStaleTranslations` 只清「机翻且语言与当前设置不匹配」的译文（连带清该语言重试计数）；社区译文不清。换目标语言时机翻重试计数清零重来。

### 2. 目标语言怎么定

设置「译文语言」（`MusixmatchTranslationLanguage`，ISO 639-1，18 个选项）。`auto`（默认，「跟随系统语言」）把字面值写进 features.json，由 **collector 侧**用 `defaults read -g AppleLocale` 解析成具体语言——跟随 macOS 系统语言而非 App 界面语言（App 只有中英两版，系统语言才如实反映母语）。MyMemory 需转换（zh→zh-CN 等），端上路径用 zh→zh-Hans。

### 3. 罗马音的来源链（App 侧展示时逐行决定）

1. **源自带**：网易云 `romalrc`；QQ `GetPlayLyricInfo` 的 `roma`（QRC 逐字压成逐行 LRC，2026-09-02 起，见第 09 章第 38 条）；酷狗 KRC `[language:]` 的 type 0 轨（2026-09-02 起，见第 09 章第 40 条——韩文歌这一轨是中文谐音，collector 侧按汉字占比先挡掉）。都随冠军候选走、写 `lyrics_roma` 字段，都要过 `usableValueAdd` 的「原文假名占比 > 5%」闸——韩文歌的源自带罗马音会被判不可用而不写入。
2. **客户端现算兜底**（`Romanizer`，2026-08-04 加）：服务端没给时现算。日文**必须走形态分析**（CFStringTokenizer），绝不能用 ICU Any-Latin——汉字会被按普通话读成拼音（「火曜日」→"huǒ yào rì"）；中文走拼音；整首歌统一判语言（`songLooksJapanese`/`songScript`），不逐行判。带 LRU 缓存防 20Hz 渲染热路径反复音译。
3. **酷狗 / QQ 假名标注**（`KanaAnnotation`）：酷狗 LRC 自带的、以及 QQ 由 collector 从 QRC 正文首行摘出并拼进整行歌词的（2026-09-02 起，见第 09 章第 39 条）`[kana:]` 标签给出汉字**在这首歌里**的实际读音（「明日」读 asu 还是 ashita 分词器给不出）；格式=`<覆盖字符数><读音假名>` 序列，按顺序对齐正文里的待标字符（汉字+`々`）；对不齐整体放弃（半对半错比不标更糟），退回形态分析。
4. **粤语粤拼**（collector 侧生成兜底，`maybeGenerateJyutpingRoma`/`jyutping.go`，2026-08-27 加）：跟上面②③不是同一套机制——这条只在 `SongLanguage==粤语` 且这一轮**没有任何源**给出 `lyrics_roma`（也就是网易云①没命中）时才补，补的结果永久写进 enrich 缓存，是服务端一次性生成而不是客户端渲染热路径现算，也**不受**下面第 5 条的语言开关影响（那是纯展示层开关，生成不看它）。字典数据来自 [rime-cantonese](https://github.com/rime/rime-cantonese)（CC-BY-4.0，见 THIRD_PARTY_LICENSES）：先按 `jyut6ping3.words.dict.yaml` 做最长词匹配（2026-08-30 加，修多音字——同一个字在不同词里读音不同，如"重要"zung6 jiu3 vs "重量"cung5 loeng6，纯单字查表两个会拼成同一个错的读音；命中词典的词按词级读音整体输出），匹配不到再退回 `jyut6ping3.chars.dict.yaml` 单字查表（查不到再借 OpenCC 数据转一次繁体重试）。词典本身没有区分声调风格的开关——不管来源是哪条，粤拼一律带数字声调（如 `ngo5`），这跟网易云①那份不带数字声调是两种不同产物，不是同一份数据的两种格式。词典覆盖不到的词/字仍会退化成"可能跟语境不符"或原样穿透，跟这条链路①②③"服务端没有就退化"的整体设计一致。
5. **日／韩／中 collector 侧预生成**（`maybeGenerateHelperRoma`/`romanize.go` + `lyrics-romanize` helper，2026-09-03 加）：跟第 4 条同一个位置（`maybeGenerateRoma` 里粤拼之后），只在**本字段仍为空**时才补，绝不覆盖①②④。**顺序不能反**：粤拼是专门为粤语做的词典查表，质量高于这条通用 ICU 音译（粤语汉字走 `.toLatin` 会出普通话拼音，完全不对）。同样**不看**下面那条语言开关（生成一次性，开关随时可改；按开关生成的话用户一打开中文拼音，存量几千首就得全部回补）。
   - ⚠️ **为什么这条要起子进程，而粤拼不用——差异从来不是「要不要缓存」，是「谁算得出来」**。粤拼是纯查表（rime-cantonese 词典 `go:embed` 进 collector 二进制），Go 自己算得出。而日文读音**必须**走 `CFStringTokenizer` 形态分析（不能用 ICU 通用音译：汉字中日共用，Any-Latin 一律按普通话读，`火曜日の朝は` → `huǒ yào rìno cháoha`），中／韩走 ICU `applyingTransform(.toLatin)`——都是 Apple 系统能力，Go 里没有对应物。所以拆成 `lyrics-romanize` 这个 Swift 子进程，跟 `lyrics-translate`／media-control 同一形态。比 `lyrics-translate` 简单的地方：CFStringTokenizer／ICU 在任何 macOS 上都有，不像 `Translation.framework` 要 macOS 26+，没有版本兜底也没有网络退路。
   - ⚠️ **读音本体走 `Romanizer.lineReading`，跟 App 播放时的客户端兜底是同一个函数**（2026-09-03 从 `LyricsSyncEngine.romanizationText` 提出来）。这是这条特性能不能成立的前提：预生成的产物必须跟现算逐字一致，否则同一首歌「装了缓存」和「现算」读音不一样——而这种不一致**不报错**，只表现成用户偶尔觉得「某句罗马音怎么变了」。selftest `contracts` 组有闸禁止任何一方把阶梯抄回去。
   - **为什么值得做**：省 CPU **不是**理由（20Hz 热路径 2026-08-04 起就有按行记忆化）。真正的理由是**能导出**——`lyrics_roma` 会被 `exportLyricsFiles` 写成 `.roma.lrc`，现算的不会；在此之前用户把歌词文件夹拷到别处、或用别的播放器读，罗马音是丢的。
   - **成本（2026-09-03 真实全量跑完的数字，不是估算）**：1996 首用时 **1m30s**（约 **45 ms/首**），成功 1996、无产出 0、失败 0；带罗马音的条目 **117 → 2133**，`.roma.lrc` 文件 2133 个；enrich 缓存 **47.86 MB → 52.90 MB（+5.0 MB）**。
     - ⚠️ **两次事前估算都不准，方向还相反**：先按「罗马音正文与原文同量级」估 6–12 MB（偏高），又按 30 首样本外推估 ~1 MB（偏低一个量级，样本全是短歌）。真实值 +5.0 MB 落在第一次的区间下沿。**这类体积别再靠外推，跑一次 `-limit` 看真实增量**。
     - 落盘核对（备份对拍）：原有罗马音被改动/丢失 **0** 条，除 `lyrics_roma` 外别的字段变动 **0** 条，条目总数不变（3571）；collector 重启后 2133 条仍在（没有被 `importLyricsFromFiles` 回滚）。
   - **存量要手动回补**：`maybeGenerateHelperRoma` 只在解析／重评那一刻跑，所以上线时存量一条都不会变。`collector backfill-roma [-apply] [-limit N]`（`backfillromacli.go`）负责回补，形态照抄 `regenerate-jyutping`：默认预演，`-apply` 前必须确认独占（常驻 collector 内存里握着整份 enrichCache，会把修改整份盖回去），写完 `saveEnrichCache()` + `exportLyricsFiles()`——**漏掉 export 等于白做**，因为「能导出成文件」正是这条特性的主要理由。
   - ⚠️ **改完 `enrichCache` 必须置 `enrichDirty = true`**，这是踩出来的（2026-09-03，20 条试跑时发现 `.roma.lrc` 写了 20 个、cache 的 mtime 纹丝不动）。`saveEnrichCache()` 开头是 `if !enrichDirty { return }`，漏置的表现是**静默不落盘**，而同一条路径上的 `exportLyricsFiles()` 照常写文件 → 「文件有、缓存没有」，下次启动 `importLyricsFromFiles()` 又把文件读回缓存，一切**看起来正常**。也就是说这个 bug 在正常使用下几乎观测不到。
     - **`regenerate-jyutping` 一直带着同一个 bug**（同日一并修）——它之所以看起来正常，纯粹是靠上面那条 import 侥幸兜住，不是设计。
     - 机械闸：`romanize_test.go` 的 `TestApplyCLIsMarkEnrichDirty` 扫所有 `*cli.go`，凡是「写 `enrichCache[` + 调 `saveEnrichCache()`」的都必须出现 `enrichDirty = true`；并要求至少扫到 2 个文件（扫到 0 个说明判据本身失效了）。做过变异测试：摘掉那一行当场红。
6. **按语言分别开关**（`RomanizationScripts`，2026-08-29 起是日/韩/中(拼音)/粤(粤拼)**四**项勾选，同日起四项默认全开——此前只有日韩中三项、中文单独默认关，粤拼是这次改动才补上的独立开关）：同一个人对不同语言需求常相反（日文要罗马字、中文不要拼音）。汉字本身分不出普通话还是粤语，"粤"这一档是靠 collector 判定的 `SongLanguage`（外部信号）分派，不是靠文字本身识别（跟日语假名/韩语谚文能自证不同）。这个开关管的是**展示**：粤拼是否生成、写进 enrich 缓存由第 4 条的 `SongLanguage` 判定决定，跟这里的勾选是否打开无关；勾选只决定已经生成好的这份粤拼要不要在悬浮歌词/歌词窗口里渲染出来。总开关关着时语言勾选行折叠。

### 4. 中文繁简转换（相邻功能，见第 08 章）

`ChineseVariant.converted` 只影响**显示**不动缓存原文；有假名判日文一律原样返回（防把日文新字体转坏：学→學）；用 ICU Simplified-Traditional 词级转换，**转简体时再叠一层 `HanVariants` 异体字表**（ICU 和 OpenCC 的繁简字典都不含「妳/祂/牠」这类异体字，详见 08-lyrics-engine）。⚠️ 2026-09-03 起这张表是**从 Unicode Unihan + OpenCC 生成的**（681 条），跟 collector 侧搜索用的是同一份数据、同一个生成器，不再各维护一份。

## 设置项

| 位置 | 项 | 影响 |
|---|---|---|
| 歌词→译文 | 显示译文 | 悬浮歌词/歌词窗口的译文行显隐（AppSettings，立即生效） |
| 歌词→译文 | 译文语言 | musixmatch 检索语言 + 机翻目标语言（features.json+kickstart） |
| 歌词→译文 | 系统兜底翻译 | 机翻兜底总开关（features.json） |
| 歌词→译文 | 翻译语言包 | macOS 26+ 才出现；列出各源语言的语言包安装状态、可拉起系统下载弹窗（只有 SwiftUI `.translationTask` 建的 session 有权弹，collector 无界面子进程做不到，所以入口必须在 App 设置里） |
| 歌词→效果 | 显示罗马音 + 标注哪些语言 | 展示层开关（AppSettings 双写 LocalPlaybackSource，当前歌立即生效） |

## 与其它功能的交互

- 译文/罗马音**随歌词冠军整体走**，不跨源拼装（第 09 章）；打分层它们只是 +50/+30 决胜分。
- 歌词换人时 `lyrics_tr_lang` 跟新候选走、`lyrics_tr_source` 清空（防上一轮机翻的 "machine" 标到新社区译文头上）。
- 「已有译文就不用再盯」这类闸门是被否决过的：译文会**被顶替**（网易云先给中文社区译文、采集器判语言不符后机翻成英文写回），App 侧靠 enrich 缓存 mtime 变化重读（第 08 章）。
- 语言包状态用共享单例缓存（`LanguagePackStatusStore`）：串行查十几种语言有可见延迟，放视图 @State 会在重建时清空、看起来像「装了又变没装」。

## 数据与文件

- enrich 缓存字段：`lyrics_tr` / `lyrics_tr_lang` / `lyrics_tr_source`（空=社区，"machine"=机翻）/ `lyrics_roma`；导出文件 `.tr.lrc` / `.roma.lrc`（第 11 章）。
- `lyrics-translate` / `lyrics-romanize` 两个 helper 都打包在 `Lyrimuse.app/Contents/Resources/`，collector 按自身可执行文件的相对路径调用（与 media-control 同形态）。build.sh 里各占三步：加进 `*_SLICES` → `merge_slices` 出 fat 二进制 → 先删再拷再补签。找不到 helper 时**静默降级**（直接 `go build` 跑 collector 的开发场景），不报错刷日志。

## 代码锚点

| 主题 | 位置 |
|---|---|
| 机翻兜底全流程 | lyrimuse-collector/translate.go `needsTranslationBackfill` `backfillTranslation` `translationUsable` `invalidateStaleTranslations` |
| 端上翻译 helper | lyrimuse/Sources/lyrics-translate/main.swift |
| Musixmatch 社区译文 | lyrimuse-collector/musixmatch.go `buildTranslatedLRC` |
| 网易云译文/罗马音 | lyrimuse-collector/netease.go（tlyric/romalrc） |
| 粤拼生成兜底 | lyrimuse-collector/jyutping.go `toJyutpingLine` `jyutpingReading`(含 `jyutpingCollisionOverrideMap`)`jyutpingWordReading` `jyutpingLRC`；enrich.go `maybeGenerateJyutpingRoma` |
| 客户端罗马音 | LyrimuseCore/Lyrics/Romanizer.swift `romanize` `looksJapanese` `japaneseSegments` |
| **整行读音判定阶梯（唯一一份）** | LyrimuseCore/Lyrics/Romanizer.swift `lineReading` —— 播放引擎与预生成 helper 共用 |
| 整份 LRC 预生成 | LyrimuseCore/Lyrics/LyricsRomanization.swift `romanizeLRC`；helper 入口 lyrimuse/Sources/lyrics-romanize/main.swift |
| 日/韩/中预生成接入 | lyrimuse-collector/romanize.go `onDeviceRomanize` `shouldGenerateHelperRoma` `maybeGenerateHelperRoma` `maybeGenerateRoma`；存量回补 backfillromacli.go |
| 假名标注 | LyrimuseCore/Lyrics/KanaAnnotation.swift `parse` `marks(forLine:)` |
| 逐行接入点 | LyrimuseCore/Lyrics/LyricsSyncEngine.swift（`songLooksJapanese`/`kanaAnnotation`/romanize 调用点） |
| 语言包 UI | lyrimuse/Settings/LanguagePackRow.swift `LanguagePackStatusStore` |
| 目标语言解析 | lyrimuse-collector/features.go `resolveLyricsTranslationLanguage` |

## 设计决策与已知坑

1. 日文罗马字绝不能用 ICU Any-Latin：汉字中日共用、Any-Latin 按普通话读，实测把「受話器」翻成拼音（2026-08-09 用户报）。
2. 假名标注对不齐宁可整体放弃：`々` 漏算会从错位点起全歪，半对半错比不标更糟。
3. 端上翻译拆成独立子进程：Go 调不了 Translation.framework；老系统加载失败也只影响 helper，collector 自动退 MyMemory。
4. MyMemory 匿名日配额 ~5000 字符（三四首歌），随机邮箱绕限只是缓解——端上路径才是主力。
5. 机翻/社区译文的顶替方向是单行道：机翻永不盖可用社区译文，社区译文语言不符时会被机翻盖。
6. 「跟随系统语言」由 collector 读 `AppleLocale` 解析而非 App 侧读 Locale：常驻进程读系统级偏好更贴近实时，也保持共享 JSON 原样读写对称。
7. 翻译逐行送、行数强校验：LRC 时间轴靠下标对齐，行数漂移=译文串行。
8. 语言包安装状态读取慢但稳定，必须缓存在单例里，否则视图重建期间闪「没装」。
9. **按原文去重再送翻（2026-08-26，Michael Jackson《Beat It》实测坐实）**：副歌反复的歌逐行独立发翻译请求，`lyrics-translate`（端上）逐行各发一个 `TranslationSession.Request`，彼此零上下文；同一句"Just beat it (beat it), beat it (beat it)"在原文里出现 7 次，翻译结果对同一份输入**不保证一致**——7 次里可能 6 次原样吐回来、只 1 次真翻了，而 `assembleTranslationLRC` 那条"翻出来等于原文就不写进译文栏"的规则会把那 6 次全部悄悄丢掉。歌词越重复，译文看起来就越支离破碎，跟网络配额/语言包状态无关。修法：`machineTranslateLRCWithBase` 送翻前先按行文本去重，翻完按下标把结果广播回它在原文里的**全部**出现位置——同一句话不管重复几次，结果必然一致（要么都翻、要么都没翻），顺带省下 MyMemory 配额和 on-device 请求数（重复句子只翻一次）。`TestTranslateDedupesRepeatedLinesAndBroadcastsResult` 钉住这条行为。
10. **amll 的内嵌译文从接入那天起就没被真正接上（2026-08-26，ROSÉ & Bruno Mars《APT.》用户报"这首歌没有翻译"）**：`enrich.go` 里 amll 候选构造那一步早就在读 `amll.tr` 算 `usableValueAdd`（+50 分的打分信号靠它），但紧接着把 `candidates` 转成最终 `scoredLyricCandidateResult` 的那个 `switch c.source` 只写了 `case "netease"`/`case "musixmatch"`，从来没有 `case "amll"`——分数算对了、内容却从没被抄进 `r.LyricsTr`。amll 一旦胜出，`lyrics_tr` 就永远是空的；而这首歌恰好还叠了一层：amll 那份缓存歌词是接入初期、逐词拼接 bug 修复前解析的（英文单词全粘在一起，如"Don'tyouwantmelikeIwantyou"），机翻拿这份本来就有毛病的原文反复重试、屡试屡败（`translation_retry_count` 涨到 2 仍是空），两层问题叠在一起让人以为"这首歌翻不出来"，其实真正的坑是内嵌译文压根没被读取。语言标注沿用 `usableValueAdd` 判定"能不能用"时的同一个简化：TTML 没给译文标语言，直接记成当前设置的目标语言。修法：`switch` 里补上 `case "amll": r.LyricsTr = amll.tr`。只在真实网络请求下验证（`fetchScoredLyricCandidatesStreaming` 深度依赖网络编排，这个仓库对这类函数的既有做法是用调试用例现场跑一遍再删掉，不是常驻单测，musixmatch 那个分支同样没有专门的单测）：修前 amll 候选 `LyricsTr` 恒为空，修后 `APT.` 实测拿到 2114 字符的中文译文。
11. **粤拼多音字消歧靠词表，不是靠单字表更聪明（2026-08-30 用户问"能不能把词也考虑进来"后加）**：`jyutping.go` 原来只有 `jyut6ping3.chars.dict.yaml` 单字表，逐字查音——"重"这个字不管出现在"重要"还是"重量"里都拼成同一个固定读音，词义不同、正确读音本该不同，纯单字查表天生做不到这种消歧（这是词典粒度决定的，不是查表逻辑写错了）。改法是引入同一个 rime-cantonese 项目的 `jyut6ping3.words.dict.yaml`（10 万+词条，同样 CC-BY-4.0），`toJyutpingLine` 逐位置先按词典最长词条的字数往前贪心找最长匹配，命中词就整体按词级读音输出，找不到才退回单字。验证时意外坐实一个额外收益：既有测试断言"这个世界"该拼 `ze2 go3 sai3 gaai3`，接入词表后变成 `ze3 go3 sai3 gaai3`——不是回归，是词典本身证实的更准结果：「這」单独/在「這般/這兒/這樣/這裏/這麼/這些」等其它复合词里都读 ze2，唯独「這個」词典专门标了 ze3，单字表选不出这种词特有的变调，词表命中之后自然对了。⚠️ 也踩出一个真 bug：`jyut6ping3.words.dict.yaml` 除了真正的词，还混了 696 条带逗号/顿号/句号的完整谚语（"笑左，笑埋右"这类）以及个别带空格的纯拉丁词条（"hee hee hur hur"）——`toJyutpingLine` 按 rune 窗口整段命中、整段输出读音，标点/空格没有对应音节，命中这类词条时会被读音字符串顶替、从输出里凭空消失（修前 `toJyutpingLine("笑左，笑埋右")` 吐出 `"siu3 zo2 siu3 maai4 jau6"`，逗号没了），直接违反这个函数自己的契约"查不到读音的字符原样保留"。两处修：① `JyutpingWords.txt` 预处理时过滤掉全部非纯汉字词条（101132 条，比过滤前少 696+1249 条，后者是无权重标注时同词多变体读音的去重）；② `loadJyutpingWordDict` 里加 `isAllHan` 独立把关，不依赖预处理脚本的正确性（脚本本身没有入库，见 `JyutpingWords.txt` 头部注释）——万一以后重新拉取上游数据忘了过滤，这道闸能兜住。`TestJyutpingWordMapHasNoPunctuationKeys` 钉住"内嵌的真实词典里不该有任何非纯汉字键"这条不变量。

上面这次改动上线前，拿用户真实缓存里全部 24 首粤语歌（994 行真实歌词，不是手挑例子）跑了一遍新旧算法对比：222 行的粤拼变了，命中的 930 个不同词逐一去和真实内嵌词典核对，0 个不匹配——代码正确应用了词典，但这不等于"词典本身语言学一定准确"，那部分只能信 rime-cantonese 项目本身的权威性。

12. **"离"读错，牵出 71 个字的系统性简繁碰撞（2026-08-30，用第 11 条那次真实数据对比时发现）**：`jyut6ping3.chars.dict.yaml` 单字表里，"离"本身就是一个独立收录的汉字——不是"離"的简体身份，是文言里一个跟"離"共用 Unicode 码位的生僻字，词典给它的读音是 `ci1`。`jyutpingReading` 原来的查法是"先查这个字自己在字表里有没有"，查到 `ci1` 就直接返回，根本轮不到下面"转一次繁体再查"那条兜底——`離→lei4` 这条正确读音永远用不上（除非"离"出现在词表收录的词里，比如"离开"，那条路径走的是 `jyutpingWordReading` 自己的转繁体逻辑，不受这个坑影响）。系统性比对字表和 `STCharacters.txt`（简→繁映射），发现这不是"离"一个字的偶发情况：**71 个字**都是这个模式，字表收了这个字自己的独立读音，跟它作为另一个繁体字的简体时该读的音不一样。修法起初覆盖了 41 个——判据是"这个字作为简体常用时该读的那个音，原始 yaml 里本来就是这个字自己候选列表中的一条（只是带权重标注、被现有'优先取无权重那条'的规则排到了后面）"，不是凭空猜的读音；其余 30 个（如"几"作"茶几"跟"幾"的 `gei2` 谁更常见）缺这层客观依据，没有动。

⚠️ **41 个里有 3 个（复/干/并）事后证实选错了，靠拿公开粤拼资料反查真实歌词坐实（2026-08-30，同一天内自查自纠）**：这三个字是简体归并了**两个或以上、读音互不相同**的独立繁体字（复→復 fuk6/複 fuk1/覆 fuk1；干→幹 gon3/乾 gon1；并→並 bing6/併 ping3），跟"离"那种"只有一个繁体身份、另一个是几乎不会在现代文本出现的生僻字"完全是两回事——这三个字**没有客观上更对的默认值**，选哪个都是赌。实测坐实的具体案例：林家谦《隔离》"回复掣 无情被废"（回复按钮），"复"改成 `fuk6`（復，恢复义）之后把原本正确的 `fuk1` 读音改错了——这里的"复"其实是"回覆"（回复消息，覆/fuk1），不是"回復"（恢复/fuk6），拿 CantoDict 反查"回覆 wui4 fuk1"和"回復 wui4 fuk6"两条公开词条才发现选错了方向。修法：把这 3 个从覆盖表里删掉，退回原来字表给的默认读音（复→fuk1、干→gon1、并→bing1），跟单字表原有行为一致，判据是"候选字之间读音互不相同"这条可编程复核（`s2t_raw` 里同一简体字的多个繁体候选，去掉指向自己的那个之后，剩下的候选如果读音不止一种，一律不进覆盖表）。最终覆盖表定格在 **38 条**。用真实语料反查，实际在这 24 首歌里以单字形式出现过的 11 个（几/凭/听/坏/宁/斗/痒/离/种/胜，"复"已撤销）都拿公开粤拼资料（CantoDict/Wiktionary）核对过，读音一致。

⚠️ **"回复掣"这一行改完仍然是错的，这是比上面严重一层的问题，这次没有修**：问题根源不在单字覆盖表，而在**词表本身**——`jyut6ping3.words.dict.yaml` 只收了"回復"（wui4 fuk6，恢复义）这一条，没有"回覆"（wui4 fuk1，回复消息义）。`jyutpingWordReading` 转繁体只试一种拼法（每个字各自的第一候选拼在一起），"回复"两字各自的第一候选拼出来正好是词典收录的那条"回復"，直接命中、外层单字覆盖表根本插不上手——这不是碰撞覆盖表能修的问题，是"同一个简体词对应多个真实繁体词、词典只收了其中一个"这一整类更深的缺口，需要"多种繁体拼法都试、挑命中词典的那个"这种更大改动才能治本，这次没有动，如实记下来。

13. **拉丁字母紧接汉字时，音节间的空格被吞掉（2026-08-31，用户截图问"为什么粤拼没跟字对齐"时顺藤查出）**：`toJyutpingLine` 原来用一个 `needSpace` 布尔量控制间距，写出"查不到读音的字符"之后按 `needSpace = !(unicode.IsLetter(r) || unicode.IsDigit(r))` 决定下一段要不要补空格。两处错，且都违反这个函数自己文档里写的契约「汉字与非汉字之间的音节用空格分隔」：① 它只看**当前**字符是不是字母/数字，没看下一个是什么——本意是"连续拉丁串别被拆成 `b a b y`"，实际把"拉丁→汉字"这个边界也判成不需要空格，于是 `"baby我爱你"` → `"babyngo5 oi3 nei5"`、`"OK啦"` → `"OKlaa1"`、`"我love你"` → `"ngo5 lovenei5"`；② `unicode.IsLetter` 对**汉字/假名/谚文同样返回 true**，所以一个查不到读音的汉字会被当成拉丁串的一部分、连带吞掉它后面那个音节前的空格。既有测试只有 `"Baby 我爱你"`（输入自带空格）这一条，恰好从两个洞中间穿过去了。真实缓存里的原样输出：张敬轩《从何唱起》"Do re mi当中找我道理" → `"Do re midong1 zung1 …"`。修法：把 `needSpace` 换成 `lastRune`（已写出的最后一个字符）+ `lastWasSyllable`（最后写出的是不是一个读音）两个量，分隔只发生在**读音与相邻内容之间**——原文里本来连写的东西（拉丁串内部、撇号跟它依附的词）一律保持原样。顺带修掉一处凭空插空格：`"林家謙/Jason Choi"` 修前吐出 `"… /  Jason"`，修后忠实保留原文的 `"/Jason"`。`TestToJyutpingLine` 新增 6 条钉住，做过变异测试（把修复回退成旧判据，6 条全部失败）。

    **这个 bug 会连带毁掉逐字对齐。** 歌词窗口/悬浮窗把粤拼标到每个字正下方走的是 `SyncedLyricWordGroup`（`LyricsSyncEngine.swift`，`buildWordGroups` 的 han 分支），判据是 `tokens.count == words.count`——粤拼按空格切出的音节数必须**正好**等于 yrc 的逐字词数，对不上就 `return nil`、静默退回整行罗马音。粘连会让 token 数变少，混排行因此永远对不齐。实测这台机器的真实数据：纯汉字行上我们生成的粤拼是 **1502/1502 严格一字一音**，粤语/中文歌里满足这道判据的行占 **718/778（92%）**。另外两条结构性限制值得记住：没有逐字（yrc）数据的歌，整行 LRC 分支把 `wordGroups` 写死成 `nil`，**永远**不可能对齐；歌词窗口还额外要求 `isActive`，非当前行按设计就是扁平的。

14. **算法/词典改了之后，存量缓存不会自己跟上——要靠 `regenerate-jyutping`（2026-08-31 加）**：`maybeGenerateJyutpingRoma` 只在 `LyricsRoma` **为空**时才补，绝不覆盖任何已有值（这条"不覆盖源自带罗马音"的规矩本身是对的，不该改）。代价是粤拼算法或词典一改，已经缓存过的歌永远停在旧结果上——2026-08-30 接入词表、2026-08-31 修间距，两次都是如此。新增一次性子命令 `collector regenerate-jyutping [-apply]`（`regeneratejyutpingcli.go`），形态照抄 `dedupe-entries`：默认只打印计划，`-apply` 才落盘，且 `-apply` 前必须拿到独占锁（常驻 collector 内存里握着整份 `enrichCache`，它下一次保存会把修改整份盖回去）。⚠️ 两个关键点：① **怎么判断"这份粤拼是我们生成的"**——判据是"存的这份带数字声调"，collector 生成的粤拼每个汉字必带声调，而歌词源自带的罗马音在真实缓存里不带（39 条粤语条目里恰好 1 条属于这种，必须原样留着）；判不准一律跳过，不猜。② **必须先 `importLyricsFromFiles()` 再改、改完 `exportLyricsFiles()`**——`lyrics/` 文件夹是歌词家族的权威源，只改 JSON 缓存的话，下次启动导入会拿磁盘上的旧 `.roma.lrc` 把它盖回去。首次运行实测：39 条粤语条目里 37 条重新生成、1 条已是最新、1 条无声调被保护跳过；其中 20 条的行数跟当前歌词已经对不上（旧粤拼是在歌词被更新之前生成的），顺带一并修正。

    ⚠️ 三个 CLI（`dedupe-entries` / `retranslate` / `regenerate-jyutping`）里"请先停掉常驻实例"那句提示原本写的 launchd 标签是 `me.yudaotor.lyrimuse.collector`，而实际标签是 `com.lyrimuse.collector`（plist 已确认）——照着提示敲会失败。三处已一并改对。

15. **内容匹配对"空白字符种类"不免疫，NBSP 换气停顿撞上 YRC 普通空格时整行粤拼消失（2026-09-01，用户报陈奕迅《冲口而出 (Live)》"若你想欣赏有没有金曲奖"这一行有粤拼、隔壁两行没有）**：`LyricsSyncEngine.swift` 的 `trTextByPlainText`/`romaTextByPlainText`（第 3 章"内容匹配优先于时间最近邻"那套，2026-08-27 加）建 key、查 key 时原来都用 `.trimmingCharacters(in: .whitespaces)`，只削字符串两端。拿这首歌真实缓存数据排查坐实：主 LRC 用 NBSP（U+00A0）标记这句里的换气停顿（`"若你\u{A0}想欣赏\u{A0}有没有\u{A0}金曲奖"`），YRC 逐字数据在同样的词组边界嵌的是普通空格（`words.map(\.text).joined()` 拼出来是 `"若你 想欣赏 有没有 金曲奖"`）——两边可读内容完全一样，但内部空白字符不同，`trimmingCharacters` 只削两端削不掉中间这几个，内容匹配查不到；更巧的是这一行 YRC 的起始时间戳（67696ms）比它在主 LRC 里的时间戳（66990ms）晚 **706ms**，比 `nearestText` 的 700ms 容差多 6ms，时间兜底也刚好卡在门外——第 3 章①②两条路同时失手，这一行才彻底没有粤拼（不是缺失，是两个近似匹配各差一点点），隔壁"我亦会一开口就唱"（漂移 127ms）"若热情在泛滥不记得转弯"（漂移 344ms）都在 700ms 容差内，靠 `nearestText` 蒙混过关，看起来像是"随机挑着漏"。修法：把两处 `.trimmingCharacters(in: .whitespaces)` 换成新增的 `Self.contentMatchKey(_:)`——用 `text.filter { !$0.isWhitespace }` 去掉**全部**空白（含 NBSP 等 Unicode 空白变体，不止两端），理由是这里比较的是"是不是同一句唱词的内容"，字词之间要不要垫空白纯粹是各家源自己的排版习惯，不该算进内容差异。验证：`swift/Sources/lyrimuse-selftest/main.swift` 新增两条断言（"③.6b"），用真实数据的原句/时间戳/漂移量原样最小复现，先确认改前 `FAIL`（`git stash` 只回退引擎改动、留着断言重跑，两条都失败），再确认改后 `ok` 且不影响原有全部断言（`ALL PASS`）。
