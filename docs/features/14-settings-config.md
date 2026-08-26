# 14. 设置、配置与本地化

> 最后核对：2026-08-26 · 基线：64a0e37+工作树

## 定位

设置窗口的信息架构、两套配置存储机制（App 偏好 vs collector 功能开关）、配置的备份/搬家、全局快捷键、开机启动、更新、首启引导、双语本地化。

## 入口与展示面

- 设置窗口：菜单栏菜单「设置…」、快捷键（可自定义）、`openSettingsHotkey`。
- 首启引导：首次启动自动弹 `OnboardingView`；菜单栏「重新运行引导…」可重来。
- 配置文件夹：设置 → 通用 → 配置文件夹（访达打开 `~/.config/lyrimuse`）。

## 行为规格

### 1. 设置窗口信息架构（侧边栏 7 类）

| 分类 | 图标/色 | 内容 |
|---|---|---|
| 歌词（indigo） | text.quote | 四段：**获取**（歌词来源五源勾选＋匹配算法智能/顺序优先＋顺序列表＋提前解析同专辑）/**译文**（显示译文→译文语言→系统兜底翻译→语言包）/**效果**（卡拉OK效果、中文繁简切换[按语言条件显示]、显示罗马音＋日韩中分语言勾选、双行显示、时间轴偏移±5s步长0.05＋作用于哪个播放器的下拉框）/**管理**（歌词管理入口＋歌词文件夹）。分段选择器记忆上次停留段（`@AppStorage settings:lyricsSection`） |
| 播放器（mint） | play.circle | 播放器选择（Apple Music/QQ音乐/网易云/Spotify/自动）、Apple Music 自动化权限状态、后台采集服务状态 |
| 歌词显示（yellow） | rectangle.3.group | 四段按展示面分：**悬浮歌词**（开关＋配色[跟随封面/主题/文字色/背景色/描边/我的配色主题]＋文字[字体/字号]＋窗口[宽度/锁定位置/恢复默认]）/**灵动岛**（开关＋风格＋宽度＋显示在哪块屏幕）/**菜单栏**（开关＋宽度模式＋最大宽度）/**其它**（自动隐藏：暂停/无播放时隐藏、截屏/录屏时隐藏）；悬浮歌词段另有「指针划过时让开」。歌词窗口刻意不在此页配置（按需打开的窗口，非常驻展示面） |
| 快捷键（teal） | keyboard | 全部 10 个全局快捷键的录制行 + 调整步长 |
| 通用（gray） | gearshape | 语言与启动（语言/开机启动）、菜单栏与 Dock（在 Dock 中显示、菜单栏图标 12 款网格、随播放律动）、设置备份（导出/导入/配置文件夹/清除所有设置） |
| 关于（blue） | info.circle | 检查更新（Sparkle）＋自动检查/自动下载、GitHub 仓库、反馈问题、导出诊断信息 |
| 账号 | — | `AccountLinkingTab`（见第 12 章） |

「歌词」与「歌词显示」的边界：前者管歌词**数据与内容**（哪来、什么语言、什么效果、存哪），后者管**展示形态**（显示在哪、长什么样、何时隐藏）。

### 2. 两套配置存储 + 镜像

- **`AppSettings`**（UserDefaults，`np:` 前缀，48 个 @Published）：App 自身偏好（外观/窗口/图标/开关），`didSet` 里同步写 defaults，**立即生效**。部分项**双写**到 `LocalPlaybackSource`（如繁简转换、卡拉OK、罗马音语言集），让当前这首歌立刻重新解析——只写一边的话要么关 App 就忘、要么等下一首才生效。
- **`FeatureSettingsStore`**（`~/.config/lyrimuse/lyrimuse-features.json`）：需要 collector 参与的功能开关（player/lyricsSources/lyricsSourceMode+Order/lyricsDir/lyricsTranslationLanguage/albumPrefetch/lyricsMachineTranslation/lastfmMirrorScrobble/daily+weeklyDigest(+source)/launchLyrimuseOnMusicOpen/trustedPlayers（信任的未知播放器，见第 02 章））。`save()` = 立即 `persistFile()` + **0.5s 去抖的 collector 重启**（连续快速切多个开关只重启一次；`launchctl kickstart -k` 被 launchd 节流约 10s，去抖前实测会造成推送反复中断）。所有等待中的 save 调用共享同一次重启结果。枚举 rawValue 与 collector `features.go` 常量逐字对应（共享 JSON 的契约）。
- **`AppSettingsMirror`**：App 偏好一变就镜像成配置文件夹里的 JSON——让「拷走整个 `~/.config/lyrimuse` 文件夹」这条搬家路径不再静默丢掉 UserDefaults 那一半（2026-08-13 用户指出的裂缝）。

### 3. 全局快捷键（GlobalHotkeys，KeyboardShortcuts 库）

10 个：显示/隐藏悬浮歌词、锁定/解锁位置、打开歌词管理、打开歌词窗口、打开设置、播放/暂停、下一首、上一首、歌词提前、歌词延后。歌词提前/延后按「调整步长」设置的幅度改**单曲**偏移（与菜单栏「歌词时间轴」同一个值；「全部播放器」和按播放器两档都在设置页那一行单独校（同一个 Stepper，靠下拉框切作用域，两档**二选一、不相加**），步长固定 0.05s，基准再与单曲微调相加——见第 08 章）。要求至少搭配 ⌘/⌥/⌃ 之一。绑定存 UserDefaults `KeyboardShortcuts_` 前缀。

### 4. 配置备份与搬家（ConfigPortability / ICloudConfigStore）

- **导出**：config.json（含账号 token **原文**）+ features.json + UserDefaults（`np:` + `KeyboardShortcuts_` 前缀）合成一份 JSON。UI 警示「包含账号密钥，不要分享」——与诊断导出刻意相反（那个绝不含 token）。
- **排除键**：`hasCompletedOnboarding`/`hasShownAutomationOnboarding`/`hasOfferedICloudImport`/`hasShownOverlayDragHint` 等「机器状态」不随人走（新机器该自己走引导/授权）；**`np:collectorInstalledFingerprint`、`np:lyricsWindowFrame`、`np:lyricsWindowScreenID`（均 2026-08-22 加）同属此类**——它记的是「这台机器上现在装进 launchd 的是哪个 collector 二进制」，新机器上必然是另一个文件，带过去会让启动对账误以为「没变过」而跳过那次本该做的重装，正好把 Sparkle 更新的兜底关掉（机理见第 15 章 §2）；后两个是歌词窗口的位置/尺寸与它所在那块屏幕的 UUID，判据跟 `np:overlayPosition*` 一字不差（绝对屏幕坐标 + 一块具体显示器，新机器的排布和 UUID 全不一样，见第 07 章）；**悬浮窗位置 `np:overlayPositionTop`/`np:overlayPositionOrigin` 同属机器本地键**（存的是绝对屏幕坐标，新机器显示器尺寸/排布不同，搬过去只会把窗口摆到看不见的地方——同 05 章 `notchScreenID` 的判据），见 `ConfigPortability.machineLocalDefaultsKeys`；导出导入用同一个排除集合，旧文件里的这些键导入时也被挡。
- **歌词库走 sidecar，不进配置包**（2026-08-21 加）：每次「存到 iCloud」/「导出…」都在配置包**旁边**多写一份同名同时间戳的 `Lyrimuse-Lyrics-<时间戳>.json.z`（`-Config-` 换成 `-Lyrics-`），内容 = `lyrics/` 文件族（歌词六字段的权威源）+「已校准」名单，zlib 压缩（实测 14.5 MB → 6.1 MB）。导入时按这个位置关系找兄弟文件；找不到就**一个歌词文件都不动**（老备份/只导设置，绝不能当成"空歌词库"去清本机的）。
  - **为什么不塞进配置包本体**（三条硬约束，任一条都足以否掉）：① `ICloudConfigStore.latestSnapshot()` 为取 `exportedAt`/`deviceName` 会在**主线程整份读+解析**配置包，而它挂在设置页 `.onAppear` 等多处 —— 包变大就是每次进设置页卡一下；② `write` 每次点都新写一份带时间戳的文件，**没有大小上限也没有"只保留 N 份"清理**，旧份永不被读 —— 几十 MB × N = iCloud 黑洞；③ 新机首启那条自动询问只给 8s 下载超时且**静默**跳过。sidecar 一并绕开三条，且 `BackupDiscovery` 只认 `Lyrimuse-Config-*.json`，天然不会把 sidecar 误认成配置包。
  - **为什么备份 `lyrics/` 文件族而不是 17 MB 的 enrich 缓存**：文件族是六字段权威源，collector 每次启动跑 `importLyricsFromFiles`（文件赢、只增不删、缓存里没有那个 key 也会新建条目），所以文件铺回去歌词自己会长回缓存；反过来直接盖写 `lyrimuse-enrich-cache.json` 会撞上"collector 内存整份写回"的竞态（`EnrichCacheStore.clearAll` 那两轮实测的坑）。缓存里其余字段（封面/链接/mbid/打分/决策存档）都是可重新解析的派生数据。**顺带保住单曲校正值**：它的 key 含歌词内容指纹，走文件族恢复正文逐字节不变，那批校正值到新机器才真的还有效。
  - 落地顺序**要紧**：歌词恢复必须排在 `importData` **之后** —— 歌词目录是 `features.lyricsDir`（用户可自定义的绝对路径），而那个文件是 `importData` 刚写的。恢复语义是「覆盖同名、只写不删」，账目（新增/覆盖/拒收）在 `LyricsBackupArchive.plan`。
  - **文件名安全**是硬边界：归档是外来文件，恢复就是拿里面的名字拼路径写盘。两道闸：① `sanitizedFileName` 挡路径分隔符（`/` `\`）、以点开头、非歌词后缀、超长名；② 落盘前再校验**解析后的父目录必须仍是歌词目录**（跟"名字长什么样"无关，兜住规则里没想到的形态）。selftest 30 条，含变异测试验证过的目录穿越。
  - ⚠️ **别再加"名字里含 `..` 就拒收"那条规则**（2026-08-21 实测踩过）：专辑/歌名以句点结尾很常见（陶喆《I'm O.K.》、Wale《everything is a lot.》），导出的文件名天然长成 `陶喆 - 天天 - I'm O.K..yrc`，那条规则把这类文件**静默**踢出备份 —— 实测一次漏掉 23 个而界面上什么都看不到（第一次真机核对才发现：归档 3059 个 vs 磁盘 3082 个）。`..` 只有作为完整路径分量时才危险，而带分隔符的名字第一道已经拒了。
  - 自动询问那条路给歌词的下载超时是 **60s**（配置那份仍是 8s）：歌词包 6 MB 上下，用同一个 8s 会大概率静默落空，而这一步落空恰恰最疼。失败**不阻断**导入。
- **iCloud**：ad-hoc 签名用不了官方 iCloud API（无 entitlement），走第三条路——把 `~/Library/Mobile Documents/com~apple~CloudDocs/Lyrimuse/` 当普通路径读写。**只做搬家不做持续同步**（iCloud Drive 冲突可能静默挑版本，对带 token 的配置不可接受）。新机器首启探测到备份会问一次要不要导入（`hasOfferedICloudImport` 只问一次）。
- **清除所有设置**：只抹本机（defaults + 配置文件），iCloud 与已导出备份不动；确认弹窗防误触。它扫的是**全部** `np:` 前缀、不看排除表，所以三份歌词偏移（全部播放器 / 按播放器 / 单曲）会一起被清掉——这跟「歌词管理」那个只清单曲那份的入口是两件事（见第 11 章）。**2026-08-21 补**：它现在也会 `LyricsPinStore.removeAll()`。原来不清，于是清完留下一份**孤儿「已校准」名单**（那是独立文件、不在 `np:` 前缀里）：collector 继续拒绝给这些歌自动升级歌词，而它保护的校正值早已不存在，用户在界面上完全看不到原因。同源的第二处在 `EnrichCacheStore.clearAll()`（清空全部歌词缓存），也一起补上了。
- **偏移那三个键都随人走**：`np:lyricsGlobalOffsetMs` / `np:lyricsOffsetsByPlayerJSON` / `np:lyricsOffsetsByTrackJSON` **不**在 `machineLocalDefaultsKeys` 里。判据是「这是这个人的偏好还是这台机器的状态」：按播放器那档记的是「这个 App 报的播放位置系统性偏多少」，换台 Mac 装同一个 App 行为一致，属于偏好。（唯一的反方向论据是 02 章记的「幅度等于站点 JS/网络耗时」跟机器/网速有关，但它顶多偏几百毫秒、且用户在设置页看得见改得动，不构成表里那些「界面说谎」的不可见错误状态。）

### 5. 开机启动 / Dock / 更新 / 引导

- **开机启动**（LoginItemManager）：不用 SMAppService，直接写经典 LaunchAgent plist 到 `~/Library/LaunchAgents`（label `me.yudaotor.lyrimuse`），`RunAtLoad=true` **无** KeepAlive（前台 GUI 工具，Cmd-Q 退出后不该被拉活）。指向 build.sh 安装的 `.app` 路径，开发调试路径不写入。
- **在 Dock 中显示**：切换 NSApp activationPolicy（accessory ↔ regular）；关闭后只留菜单栏图标。accessory 策略下打开任何窗口都要先 `NSApp.activate` 否则 openWindow 静默无效（多处调用点共用这个坑的修法）。
- **这个永久偏好关着时，辅助窗口自己借一个 Dock 图标**（`AuxiliaryWindowActivation.swift`，2026-08-04）：「设置」/「歌词管理」/「歌词窗口」/「欢迎使用」四扇窗各自的根视图在 `.onAppear`/`.onDisappear` 里报到，用一个开关计数器 `openCount`——只要还有任意一扇开着就借 `.regular`，全部关掉才还原成 `.accessory`，不跟上面那条永久偏好打架（用户手动开了永久显示的话，这边全程不用管）。目的是这几扇窗打开期间能进 Cmd-Tab、能靠 Dock 图标切回来，不用非得先回菜单栏点。
- **更新**（SparkleUpdaterManager）：Sparkle 标准流程（SPUStandardUpdaterController，startingUpdater:true 按 Info.plist SUFeedURL/SUEnableAutomaticChecks 周期检查），标准模态弹窗，无 gentle-reminder 定制。关于页有手动「检查更新」+自动检查/自动下载开关。
- **首启引导**（OnboardingView）：分步向导，每步直接绑定 AppSettings/FeatureSettingsStore **立即生效**（不做最后统一确认）；步数按所选播放器动态算（选 QQ 音乐则跳过 Apple Music 自动化权限步）；关窗=稍后再说（下次启动再问），走完最后一步才算完成。

### 6. 本地化（L10n）

- 中/英两档。**不用** SwiftUI 自动语言协商——SwiftPM 纯 `swift build` 打包会把 `zh-Hans.lproj` 目录名强制小写，Apple 的协商精确匹配大小写导致永远落到 en；`L10n.t()` 自己读 `Locale.preferredLanguages`（`np:appLanguage` 可手动覆盖，运行期切换即时生效）定位 `.lproj` 手查。查找起点 `Bundle.main`（`Bundle.module` 在别人机器上会 fatalError）。
- **工作流**：改 `Localization/Localizable.xcstrings`（唯一真源，JSON：sort_keys/indent2/`': '` 分隔）→ 跑 `python3 Localization/generate-strings.py` → 两份 `.strings` 生成物一起入库。selftest 有双向一致性守卫。生成物入库是因为 xcstringstool 只在完整 Xcode 里。
- UI 文案约定：不加句尾句号。

### 7. 诊断导出（DiagnosticsExporter）

汇总 collector 日志（`~/Library/Logs/lyrimuse.log`）+ App 系统日志 + 关键状态（权限/服务/各功能是否已配置）+ **播放时钟**成一份文本，设计给贴公开 issue。

**播放时钟段（2026-08-22 加）**：`positionSourceTier` / 伺服误差 EMA / `posReportedBiasSecs` / 锚点的 rate·fresh·年龄 / 生效歌词偏移与其中来自 LRC `[offset:]` 的那一层 / `currentLineFillSettled`。数据源是 `LocalPlaybackSource.clockSnapshot`（只读快照，全是内存里已有的字段，零热路径成本；刻意不做成 `@Published`——诊断导出是"点一下读一次"，发布属性会让每次伺服调整都推着订阅者重渲染）。
加它的理由：「歌词慢半拍」是最常被报也最难复现的一类问题，而它至少有四种成因、修法完全不同——帧率掉了 / tier 判错 / 伺服在反复 snap / 自然切歌偏置估歪。此前报告里没有任何一项能把这四种区分开。这一段不含任何用户内容（没有曲名/歌手/歌词），天然不需要过 `LogRedactor`。

**对外请求审计日志（2026-08-26 加）**：用户明确要求"所有软件发出的对外请求全部都给我记录下日志"之后补的一整条能力，两侧各有一个统一出口——App 侧 `LyrimuseCore/Diagnostics/NetworkAuditLog.swift`（6 个 `URLSession` 调用点：`LastfmStatsService.request`/`LastfmAuthFlow` 两处/`ListenBrainzTokenCheck.validate`/`CachedImage.load`/`MusicCatalogSearch` 两处，各自调一次）；collector 侧是既有的 `networkobs.go` `doHTTPTracked`（原来只累加"网络通不通"的原子计数器，这次扩成同时写审计日志，十几个原本没接进这个出口的调用点——`lastfm.go`/`lastfmcollapse.go`/`backfill.go`/`lb.go`/`alerter.go`/`relay.go`/`weekly.go`/`digest.go`/`topartists.go`/`translate.go`/`color.go`/`musicbrainz.go`/`apple.go`/`amllttml.go`——一并接进来）。每条日志只记方法+host+path(+Last.fm 的 `method` 参数,它标识调用的哪个接口、不是凭据)+状态码/错误+耗时，**故意不带 query string**——凭据就是拼在 query string/path 里的，从源头不记录比"记了再指望 `LogRedactor`/collector 侧 `logscrub.go` 兜底"更彻底(两道现有脱敏机制仍然保留、继续保护其它已存在的、可能带 URL 的旧日志正文，不是被这个新出口取代)。App 侧新分类叫 `network-audit`(跟 `lastfm-stats`/`lastfm-connect` 等分开)，`recentAppLogLines()` 按 subsystem 查询、自动收进导出报告，不用额外接线。

刻意排除在外的两类：DNS-over-HTTPS 查询(`doh.go`，那是给别的请求解析域名用的基础设施调用，不是"联系了哪个外部服务"，跟 `networkLooksDown()` 的既有统计口径一致)；App 自动更新检查(Sparkle 框架，请求整个发生在框架内部，拿不到方法/网址/状态码/耗时这些细粒度信息，只能挂一个粗粒度生命周期回调，价值跟其它请求不对等，需要时再补)。

**调试 HUD（隐藏开关，不进设置界面）**：`defaults write me.yudaotor.lyrimuse np:debugHUD -bool true` 后重开悬浮歌词，右上角显示实测帧率。取样器是 `LyrimuseCore/Playback/FrameRateProbe.swift`（纯值类型，selftest 无屏覆盖 6 条），挂在**逐字填色那个既有的 `TimelineView` 闭包**里——量的正是这个 App 最贵的那段渲染实际拿到多少帧，而不是另起一个 TimelineView 去量一个无关的数字。HUD 用 `.overlay` 挂而**不**塞进 VStack：它绝不能改变布局，否则会把窗口撑高、量到的就不是原来那套渲染了。
背景：项目最贵的两个渲染结论（07 章 #13 的 ~20Hz 提交、04 章 #2 的 30Hz 上限）都靠一次性搭的 ScreenCaptureKit 探针量出来，量完就没了，而 07 章还写着「将来重试排程式填色，先用探针核实提交频率再谈」。两道防泄密：状态段只用 ConfigStore 的只读布尔判断；日志正文统一过 `LogRedactor` 脱敏（2026-08-13 前该约束是破的——Go `*url.Error` 会把 api_key 连 URL 原样打进日志）。

## 设置项

本章即设置项总表（见行为规格 §1）。

## 与其它功能的交互

- FeatureSettingsStore.save() 的 kickstart 会让 collector 重启（歌词解析/推送短暂中断），去抖是为保护「正在播放」推送。
- 「歌词来源被禁用仍会抓取、只在挑选时过滤」——所以改来源勾选不触发重搜（第 09 章）。
- 双写模式的另一半在 `LocalPlaybackSource` 各属性的 `didSet`（改了立刻 reload 当前歌，第 08 章）。
- 语言切换即时生效靠各视图 `.id(L10n.current)` 强制重建。

## 数据与文件

- UserDefaults：`np:*`（AppSettings + 各处 @AppStorage）、`KeyboardShortcuts_*`。
- `~/.config/lyrimuse/`：`config.json`（账号凭据，ConfigStore）、`lyrimuse-features.json`、App 偏好镜像 JSON、enrich 缓存等（清单见第 01 章）。
- iCloud：`~/Library/Mobile Documents/com~apple~CloudDocs/Lyrimuse/`。
- LaunchAgent：`~/Library/LaunchAgents/me.yudaotor.lyrimuse.plist`。

## 代码锚点

| 主题 | 位置 |
|---|---|
| 设置窗口/各 tab | lyrimuse/SettingsView.swift `SettingsTab` `LyricsSettingsTab` `AppearanceSettingsTab` `GeneralSettingsTab` 等 |
| App 偏好 | Settings/AppSettings.swift；镜像 Settings/AppSettingsMirror.swift |
| 功能开关 | Settings/FeatureSettingsStore.swift `save()`；collector 侧 lyrimuse-collector/features.go |
| 快捷键 | Settings/GlobalHotkeys.swift、Settings/ShortcutRecorder.swift |
| 备份/iCloud | Settings/ConfigPortability.swift、Settings/ICloudConfigStore.swift（`readOutcome`/`isMaterialized`）、Settings/ICloudConfigImportPrompt.swift、LyrimuseCore/Util/BackupDiscovery.swift、LyrimuseCore/Util/ICloudFileReadiness.swift |
| 凭据存储 | Settings/ConfigStore.swift、LyrimuseCore/Util/SecretFileWrite.swift |
| 开机启动 | Settings/LoginItemManager.swift |
| 更新 | Settings/SparkleUpdaterManager.swift |
| 引导 | lyrimuse/OnboardingView.swift |
| 本地化 | lyrimuse/L10n.swift、Localization/generate-strings.py、Localizable.xcstrings |
| 诊断 | Settings/DiagnosticsExporter.swift、LyrimuseCore/Diagnostics/LogRedactor.swift |
| 对外请求审计 | LyrimuseCore/Diagnostics/NetworkAuditLog.swift（App 侧 6 个调用点）；collector 侧见第 15 章「网络观察」 |

## 设计决策与已知坑

1. `Bundle.module` 在非开发机必崩（fatalError），本地化必须走 `Bundle.main` + 手动 .lproj 查找。
2. SwiftPM 会把 .lproj 目录名小写化，破坏 Apple 语言协商——这是自建 L10n 的根本原因。
3. features.json 的 save 必须去抖重启 collector：launchd 对连续 kickstart 节流 ~10s，逐开关重启会反复打断推送。
4. 配置「导出/导入」与「诊断导出」安全取向刻意相反：前者必须带 token 原文（搬家），后者绝不能带（贴公开 issue）。
5. iCloud 只做搬家不做同步：iCloud Drive 冲突会静默挑版本，带 token 的配置不能接受静默丢数据。
6. 机器状态键（引导完成/已问过 iCloud 导入等）绝不随备份走，否则新机器不弹该弹的引导。
7. accessory 激活策略下 `openWindow` 前必须 `NSApp.activate`，否则静默无效。
8. 设置页每行一个设置是通用版式；行首 ? 号（HelpButton）只放「界面上看不出来」的信息，重复副标题的一律删。
9. ad-hoc 签名限制了 iCloud entitlement 与 SMAppService 等官方路径——搬家/启动项都走文件系统方案。
10. 改 `Localizable.xcstrings` 后忘跑 generate-strings.py 会被 selftest 拦下（红灯信息直接写明跑哪条命令）。
11. ⚠️ **备份还没从 iCloud 下载下来时点「导入」，下载根本不会被触发**（2026-08-24 用户在另一台
   机器上报，已修）。表象：提示「这份备份还没从 iCloud 下载下来，等一会儿再试」，但等多久都
   没用，只能自己去 Finder 把那个文件夹点下来。链路是这样断的——`BackupDiscovery` 把目录项
   `.<真名>.icloud` 还原成**真名**交给 `ICloudConfigStore.read()`（这一步是对的，见
   `ConfigSnapshotName`），而占位符形态下真名路径在本机**根本不存在**，
   `resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])` 因此抛错；
   `isMaterialized` 原来把「拿不到状态」一律当成「能读」（本意是照顾 Dropbox／手动拷进来的
   普通文件），于是 `read()` 直接跳过 `startDownloadingUbiquitousItem`、去读一个不存在的路径、
   失败返回 nil。**下载从头到尾没有被发起过**。判据抽成了 `ICloudFileReadiness.isReadyToRead`
   （拿不到状态时改看真名路径在不在：在＝普通文件能读，不在＝占位符必须先下载），放 LyrimuseCore
   是为了让 selftest 覆盖到——跟 `ConfigSnapshotName` 是同一个故事的两半。同时 `read` 拆出
   `readOutcome`，把「已经在下、超时了」和「连下载都没能发起」分开：原来两种都返回 nil、
   界面一律劝人干等，而后一种等到天荒地老也不会好。
12. 改本地化**只能改 `Localization/Localizable.xcstrings`**，然后跑
   `python3 Localization/generate-strings.py`；两份 `.lproj/Localizable.strings` 是生成物。
   手改生成物会被 selftest 的四条 catalog↔生成物对拍当场拦下（第 10 条说的就是这道闸）。
   顺带一提：直接拿 `json.load`+`json.dumps` 重写 catalog 会把整个文件的分隔符
   （`" : "` 而不是 `": "`）和键序全改掉，一次改两个词条能产生九千行 diff——要就地插键请做
   文本级的定点插入，并保持 code-point 键序。
13. **设置窗口的标题钉死成「设置」，当前分类另开副标题**（2026-08-25 改，用户反馈"想在 Dock
   里认出哪扇是哪扇"）。原来 `.navigationTitle` 绑的是选中分类（`selectedCategoryTitle`：
   「通用」「外观」……），仿的是系统"系统设置"那套"标题=当前面板名"——但那套设计成立的
   前提是这扇窗口有自己独占的 Dock 图标，而这个 App 的 Dock/Window 菜单是「设置」/
   「歌词管理」/「歌词窗口」四扇窗**共用同一个**图标，右键菜单里冒出一条「通用」完全看不出
   它是设置窗口。副标题（`.navigationSubtitle`）只出现在标题栏本身，不进 Window 菜单/Dock
   右键列表，分类上下文照样留得住，只是不再顶替窗口的身份。
