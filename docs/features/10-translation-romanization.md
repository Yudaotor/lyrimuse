# 10. 译文与罗马音

> 最后核对：2026-08-17 · 基线：2a2bf8b+工作树

## 定位

歌词的两类附加内容：**译文**（社区译文 + 机翻兜底）与**罗马音/注音**（源自带罗马音 + 客户端现算兜底 + 酷狗假名标注）。生成主要在 collector 侧，展示端兜底在 App 侧。

## 入口与展示面

- 展示：桌面悬浮歌词与歌词窗口的译文/罗马音小字行（灵动岛胶囊空间不支持、菜单栏只有单行纯文字）。
- 设置：歌词 → 译文段（显示译文/译文语言/系统兜底翻译/翻译语言包）；歌词 → 效果段（显示罗马音 + 标注哪些语言：日/韩/中）。

## 行为规格

### 1. 译文的来源链

1. **社区译文（随冠军候选走，第 09 章）**：网易云 `tlyric`（固定中文）；Musixmatch `crowd.track.translations.get`（**唯一可选语言的源**，目标语言=设置的译文语言，按原文时间轴逐行拼成独立 LRC）。QQ/酷狗/LRCLIB 无译文。
2. **机翻兜底（`backfillTranslation`，translate.go）**——触发条件全部满足才跑：
   - 「系统兜底翻译」开关开着（默认关）；有主歌词；目标语言非空；
   - 现有译文对当前目标语言**不可用**（`translationUsable`，语言标签与正文矛盾时以正文为准）；
   - 同目标语言重试 <3 次、距上次尝试 ≥6 小时；歌词本身不是目标语言、至少一行文字系统与目标不同。
   - **机翻永不顶替可用的社区译文**；反过来语言对不上的社区译文会被机翻覆盖。
3. **执行**：整体 90s 上限。只送「与目标语言文字系统不同」的行；优先走**端上 Apple 翻译 helper**（`lyrics-translate` 独立 Swift 子进程，stdin/stdout 各一行 JSON，行数必须原样对齐；不联网、无配额、歌词不出本机；要 macOS 15+，起不来自动退路）；退路 **MyMemory**（15s/请求、单块 ≤460 字符、最多 12 块、随机邮箱绕单地址日配额 ~5000 字符）。行数对不上整块作废；翻出行数 ×3 < 送翻行数判失败。配额用尽只更新时间戳不记次数。成功写 `lyrics_tr` + `lyrics_tr_source="machine"` + `lyrics_tr_lang=目标`。
4. **失配清理**：启动时 `invalidateStaleTranslations` 只清「机翻且语言与当前设置不匹配」的译文（连带清该语言重试计数）；社区译文不清。换目标语言时机翻重试计数清零重来。

### 2. 目标语言怎么定

设置「译文语言」（`MusixmatchTranslationLanguage`，ISO 639-1，18 个选项）。`auto`（默认，「跟随系统语言」）把字面值写进 features.json，由 **collector 侧**用 `defaults read -g AppleLocale` 解析成具体语言——跟随 macOS 系统语言而非 App 界面语言（App 只有中英两版，系统语言才如实反映母语）。MyMemory 需转换（zh→zh-CN 等），端上路径用 zh→zh-Hans。

### 3. 罗马音的来源链（App 侧展示时逐行决定）

1. **源自带**：网易云 `romalrc`（随冠军候选，`lyrics_roma` 字段）。
2. **客户端现算兜底**（`Romanizer`，2026-08-04 加）：服务端没给时现算。日文**必须走形态分析**（CFStringTokenizer），绝不能用 ICU Any-Latin——汉字会被按普通话读成拼音（「火曜日」→"huǒ yào rì"）；中文走拼音；整首歌统一判语言（`songLooksJapanese`/`songScript`），不逐行判。带 LRU 缓存防 20Hz 渲染热路径反复音译。
3. **酷狗假名标注**（`KanaAnnotation`）：酷狗 LRC 的 `[kana:]` 标签给出汉字**在这首歌里**的实际读音（「明日」读 asu 还是 ashita 分词器给不出）；格式=`<覆盖字符数><读音假名>` 序列，按顺序对齐正文里的待标字符（汉字+`々`）；对不齐整体放弃（半对半错比不标更糟），退回形态分析。
4. **按语言分别开关**（`RomanizationScripts`：日/韩/中三个勾选）：同一个人对不同语言需求常相反（日文要罗马字、中文不要拼音）；中文默认关。总开关关着时语言勾选行折叠。

### 4. 中文繁简转换（相邻功能，见第 08 章）

`ChineseVariant.converted` 只影响**显示**不动缓存原文；有假名判日文一律原样返回（防把日文新字体转坏：学→學）；用 ICU Simplified-Traditional 词级转换。

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
- `lyrics-translate` helper 打包在 `Lyrimuse.app/Contents/Resources/`，collector 按相对路径调用（与 media-control 同形态）。

## 代码锚点

| 主题 | 位置 |
|---|---|
| 机翻兜底全流程 | lyrimuse-collector/translate.go `needsTranslationBackfill` `backfillTranslation` `translationUsable` `invalidateStaleTranslations` |
| 端上翻译 helper | lyrimuse/Sources/lyrics-translate/main.swift |
| Musixmatch 社区译文 | lyrimuse-collector/musixmatch.go `buildTranslatedLRC` |
| 网易云译文/罗马音 | lyrimuse-collector/netease.go（tlyric/romalrc） |
| 客户端罗马音 | LyrimuseCore/Lyrics/Romanizer.swift `romanize` `looksJapanese` `japaneseSegments` |
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
