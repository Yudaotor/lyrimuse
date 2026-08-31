# 14. 设置、配置与本地化

> 最后核对：2026-08-31 · 基线：64a0e37+工作树

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
| 歌词（indigo） | text.quote | 四段：**获取**（歌词来源七源勾选[含每源独立「测试」按钮＋卡片右上角「测试」（原「全部测试」，2026-08-31 去掉"全部"两字），2026-08-30]＋匹配算法智能/顺序优先＋顺序列表＋提前解析同专辑）/**译文**（显示译文→译文语言→系统兜底翻译→语言包）/**效果**（卡拉OK效果、中文繁简切换[按语言条件显示]、显示罗马音＋日韩中分语言勾选、时间轴偏移±5s步长0.05＋作用于哪个播放器的下拉框）/**管理**（歌词管理入口＋歌词文件夹）。分段选择器记忆上次停留段（`@AppStorage settings:lyricsSection`） |
| 播放器（mint） | play.circle | 播放器选择（Apple Music/QQ音乐/网易云/Spotify/自动）、Apple Music 自动化权限状态、后台采集服务状态 |
| 歌词显示（yellow） | rectangle.3.group | 四段按展示面分。前两段是**编辑台**版式（内容区里一块 1:1 的实时画布＋工具栏浮层＋舞台内的宽度调整条，页顶不钉预览）：**悬浮歌词**（`OverlayEditorStage`：工具栏「文字」[字体/字号]／「配色」[跟随封面/主题/文字色/背景色/描边/我的配色主题]／「排版」[双行显示/对齐方式]＋「重置▾」；舞台内宽度条；下面是开关＋行为栏[锁定位置/长按拖动/悬浮淡化]＋「全部设置」折叠抽屉）/**灵动岛**（`NotchEditorStage`：工具栏「风格」「屏幕」两个浮层＋舞台内宽度条；下面是开关；**没有**抽屉——一共三项，浮层和滑杆已全覆盖）/**菜单栏**（开关＋宽度模式＋最大宽度，页顶仍钉一条仿菜单栏预览）/**其它**（自动隐藏：暂停/无播放时隐藏、截屏/录屏时隐藏）。⚠️ 页顶那层固定头部**收不到点击事件**，凡是可交互的预览都只能待在滚动区。歌词窗口刻意不在此页配置（按需打开的窗口，非常驻展示面） |
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

**2026-08-27 这一轮：从"至少别泄密"扩成"真的能靠这一份文件排查问题"**。起因是拿一份真实导出（3254 行）回头核对，坐实了几个问题，逐条修：

- **App Log 里的时间戳跟 Collector Log 对不上表**：前者是 `os.Logger`，显式 `+0000`（UTC）；后者是 Go `log.LstdFlags` 打的本地墙钟、不带任何时区标记——实测这台机器上两段日志相差整整 8 小时。修法是 collector 侧 `main.go` 加 `log.LUTC`，两边统一到 UTC；两个段落标题也都显式写明 `UTC`，不用读的人自己心算。
- **`App version` 恒报 `1.0.0`**：`build.sh` 的 `APP_VERSION` 默认值原来硬编码成 `1.0.0`，而这台机器唯一会用到的构建方式就是本地 `./build.sh`（见 repo CLAUDE.md）——同一份导出里 collector 正确打出 `lyrimuse 1.4.0 starting`，App 侧却报 `1.0.0`，两个版本号当场打架。改成默认取最近一个 git tag（去掉 `v` 前缀），真取不到才退到一眼假的 `0.0.0`；`LYRIMUSE_VERSION` 环境变量（CI 发布用）优先级不变。
- **`[local] snapshot failed` 一条重复了 921 次，占 24 小时窗口的 30%**：`LocalPlaybackSource.poll()` 原来无条件每拍（空闲档 ~10s 一次）打一遍 `.error`，而"没有任何曲目在加载"本身多数时候是完全正常的状态。改成只在状态**变化**时打（`consecutiveNilSnapshots` 计数：首次失败打一次，之后每 30 次—约 5 分钟—再打一次而不是完全沉默，恢复时补一条 `recovered after N`）。
- **一个标着"诊断用，定位到根因后删"的探针没删**：`AppDelegate.swift` 2026-08-18 装的滚轮探针（`scroll-probe`），每次滚轮事件都打一整条 AppKit 视图层级 dump（单行常常几百字符）。当年那次调查已经转成永久性的兜底转发方案（`forwardScrollIfStranded`，见下）而不是真找到 SwiftUI 内部的根因，探针本身此后一直白跑。已删掉 `logScrollProbe` 极其专用的 `firstSplitView`/`scrollViews` 辅助函数，`forwardScrollIfStranded`（真正生效的修复）原样保留。
- **Collector Log 固定"最后 200 行"被例行轮询迅速填满**：网络审计日志接入之后，`user.getrecenttracks` 这类例行轮询把这 200 行的窗口迅速填满——实测一份导出里这 200 行只覆盖了 45 分钟，稍早一点发生的事在导出这一刻已经被冲出窗口。改成 `recentCollectorLogLines` 按**时间窗口**取（最近 4 小时，倒着扫找 cutoff，不用为找起点把整份文件正着解析一遍时间戳），配合下面的折叠机制把总行数收回合理范围。
- **重复行折叠（`collapseRepeatedLines`）**：网络审计的例行成功调用、上面那类轮询噪音，天生就是"内容几乎相同、只有时间戳/耗时不同"的大量重复行——抹掉行内连续数字段之后模板相同、且同一模板出现次数 ≥12 次才折叠，保留首尾两条真实时间戳 + 一行"中间还有 N 条被省略"；低于阈值的重复原样保留（那种量级往往还是有时间线索价值的信号）。同时套用在 App Log 和 Collector Log 两段。
- **新增 `== Collector Health Check ==`**：collector 早就有一个一次性子命令 `collector healthcheck`（`healthcheckcli.go`，回答"歌词为什么不出来"）——配置文件/歌词来源开关/缓存文件/歌词导出目录可写性/ListenBrainz·Last.fm 配置，以及**真拿两首探测曲**（中文+英文各一首）实测各歌词源现在给不给候选、网络整体是否看起来通(`networkLooksDown`)。此前只有用户自己在终端跑才看得到，诊断导出完全没引用。跟"联网搜索候选歌词"同一套 Process 调用模式，不带 `-json`（文本输出本身就是给人看的格式）、不带 `-local-only`（接受多等几秒换真实网络探测，这一步全程在后台线程）。stdout（结构化报告）和 stderr（探测曲触发的网络审计行）分两路管道**并发**读取（原因跟 `LyricsSearchService` 读 collector 子进程输出一样：顺序读会在某一路写满 64KB 内核管道缓冲区时死锁），前者是主体，后者非空时作为折叠过的附注展示，避免两者交叉穿插。15s 超时保护，子进程启动失败/超时/空输出都体现成报告里的一行文字，不让整个导出因此崩掉。
- **新增 `== Windows ==`**：如实报每一扇当前存在窗口的标题/可见性/是否最小化/frame/落在第几块屏，外加屏幕列表（分辨率+缩放）。「灵动岛 enabled: true」不代表它这一刻真的可见（可能被暂停/截屏/`hideWhenNotPlaying` 收起了），UI 层面的反馈光靠布尔开关看不出实际现状。
- **新增 `Architecture` 行**（含 Rosetta 检测，`sysctl.proc_translated`）：这个项目发布流程真出过事故——`build.sh` 注释记着 v1.0.0~v1.2.0 三个版本都在没人察觉的情况下发成了 arm64-only，一台 Intel Mac 或者装了 Rosetta 的 Apple Silicon Mac 上排查"打不开/崩溃"，这一行是第一个该确认的东西。
- **新增 `Auto-update checks` 行**：Sparkle 自己的 `automaticallyChecksForUpdates`/`lastUpdateCheckDate`，回答"为什么没提示我更新"这类反馈，读取零成本、不涉及联网。
- **新增 `== Current Track Lyrics Resolution ==`**（仅当前有播放曲目时出现）：当前曲目在 `EnrichCacheReader` 里的缓存 key、来源、有没有歌词/逐字/译文/罗马音、是否标记纯音乐——"这首歌没歌词/用错源了"是最常见的一类反馈，以前只能让用户口头报歌名再手动去歌词管理查。查不到本身也是信号（要么真没解析过，要么归一化 key 对不上，第 11 章记录过这类真实坑）。`EnrichCacheReader` 整个类型是 `@MainActor`，这一段必须在调用方（`exportInteractively`/`buildReport`）先算好、以纯文本传进后台任务，不能挪到 `Task.detached` 里现调。

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
| 诊断 | Settings/DiagnosticsExporter.swift（`collapseRepeatedLines`/`collectorHealthCheckLines`/`currentTrackLyricsLines`/`recentCollectorLogLines`）、LyrimuseCore/Diagnostics/LogRedactor.swift；时区对齐见 collector 侧 main.go `log.LUTC`；App 版本号见 build.sh `APP_VERSION` |
| 歌词来源可用性测试（2026-08-30） | Settings/LyricSourceTestService.swift；SettingsView.swift `sourceTestAccessory`/`testSource`/`testAllSources`/`testAllSourcesButton`（悬停提示走自绘 `.popover` + `accessoryHoverSource`，不是 `.help()`，理由见「设计决策」）；`SettingsCardHeader` 的 `trailing` 插槽；collector 侧 lyrimuse-collector/testlyricsourcescli.go（`collector test-lyric-sources [-source <name>]`），跟 healthcheckcli.go 共享同一套两首探测曲思路；具体失败原因旁路见 ytmusic.go/musixmatch.go/netease.go 各自的 `*LastFailureReason` |
| 对外请求审计 | LyrimuseCore/Diagnostics/NetworkAuditLog.swift（App 侧 6 个调用点）；collector 侧见第 15 章「网络观察」 |
| 诊断用探针（生命周期） | 滚轮兜底转发 `AppDelegate.forwardScrollIfStranded`（继续保留）；同批曾经的诊断探针 `logScrollProbe` 已于 2026-08-27 删除，见「设计决策」 |

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
14. ⚠️ **标着"诊断用，定位到根因后删"的临时探针，根因没查出来就容易一直留着**（2026-08-27
   删的滚轮探针，`AppDelegate.swift`，2026-08-18 装）。这次没删掉是因为调查本身没有严格意义
   上的"找到根因、可以删了"这个终点——三轮实测把问题缩小到"SwiftUI `NavigationSplitView`
   内部某个子视图的 `hitTest` 返回了 `nil`"，属于框架内部行为、改不动，于是转向永久性的
   兜底转发方案（`forwardScrollIfStranded`）而不是继续深挖，探针本身却没人回头把它摘掉，
   一直原样跑到这次靠一份真实诊断导出才发现——它的日志占了不小的篇幅，且每行都是完整
   AppKit 视图层级 dump，对已经不在进行中的调查毫无价值。教训：这类"先当探针用、后来
   转成永久方案"的情况要显式判断探针本身还要不要留（通常不需要——真正生效的是方案代码，
   探针只是当时用来定位方案该长什么样的工具），别让"根因没找到"当成"探针可以一直留着"的
   理由。
15. **「歌词来源」测试按钮(2026-08-30,用户要求"可以测试这些歌词源的可用性")没有另起一套
   探测逻辑,复用的是 `healthcheckcli.go` 那套已经在用的"两首固定探测曲(华语+英文各一首)
   取并集"思路(理由见该文件顶部注释:任何单独一首都会让另一半源的"库里确实没有这首"被
   误判成"这个源坏了")——诊断导出引用的 `collector healthcheck` 是"一次性整份报告"
   (给文本转储用),这里需要的是"一个源一行、边测边出结果"的交互式反馈,所以新开了一条
   姊妹子命令 `collector test-lyric-sources [-source <name>]`
   (`testlyricsourcescli.go`),复用 `scoredLyricCandidatesStreaming` 的流式回调实现
   "谁先测完谁先报"(NDJSON,一行一个源),不是等两首探测曲都跑完整批才一次性打印。
   ⚠️ **没有做"单独测一个源就能跳过等其它源"的优化**:两首探测曲各自内部仍然会把全部
   已启用的源一起并发打一遍(跟 healthcheck/search-lyrics 完全一样),`-source` 只是决定
   "只报哪一行",不影响底层实际探测的范围——AMLL 需要先从网易云/QQ 拿到平台 ID 才能测,
   拆出"只探测它自己"的独立调用反而更复杂,而且"测一个"和"测全部"的实际等待时间在这个
   仓库里从来没有被区分过(联网搜索候选歌词弹窗同样是等最慢的那个源)。设置页侧
   (`LyricSourceTestService.swift`)子进程/NDJSON 读取是 `LyricsSearchService.swift`
   同一个 idiom 的独立复制,不是抽公用基类共享——两处一份改了大概率不会同步改另一份。
   UI 侧:`SettingsCardHeader` 补了一个可选的 `trailing` 视图构建器(仿 `SettingsRow` 已有
   的同名模式)放"测试"按钮(2026-08-31 从"全部测试"改成"测试"——两个字已经说清楚是
   干什么的,"全部"是多余修饰,用户实测直接点出来的)。同一时间只允许一轮测试跑
   (`isTestingLyricSources` 这道闸,标题行的「测试」和任意一个单独的「测试」按钮共用
   同一个 collector 子进程槙位,后发的会杀掉先发的,不加这道闸,先发那一轮里还没轮到的源
   会永远停在"测试中"转圈)。
   - ⚠️ **三轮才修对的真 bug:每个来源格子尾部的测试按钮,第一版设计从悬停提示到点击
     全部失灵(2026-08-31,用户连续三次实机反馈)**。根因是同一个架构选择:
     第一版把测试小图标用 `.overlay(alignment: .trailing)` **叠**在
     `sourceCheckbox`(那个铺满整格的开关 `Button`)上面,想着"悬停各自独立、点击靠
     z-order 分发"。实测逐条打脸:
     1. 提示气泡先是完全不弹——原因判的是外层整格的悬停状态,不是小图标自己的;
        改成只认小图标自己的 `.onHover` 信号后,气泡确实会弹了。
     2. 点击这个小图标毫无反应——两个 `Button` 叠在一起时,点击的 mouseDown 在
        AppKit 的 hit-test 阶段就被外层那个铺满整格的大按钮吃掉了,根本轮不到小图标
        自己的 `Button`。当时误判成"SwiftUI 手势优先级"问题,加了
        `.highPriorityGesture(TapGesture())` 想让小图标的手势"抢"到前面——**这个
        修法同样不生效**:`.highPriorityGesture` 调解的是 SwiftUI **自己**手势系统
        内部的优先级,管不到"外层 `Button` 的 mouseDown 直接被 AppKit 判给了它自己"
        这一层更底层的冲突,悬停(`NSTrackingArea`)和点击(mouseDown hit-test)根本
        不是同一套分发机制,悬停不冲突不代表点击也不冲突。
     真正的修法是从架构上消除重叠,不是在重叠状态下调解优先级:把测试小图标从
     `.overlay` 改成 `sourceCheckbox` 的平级 `HStack` 兄弟节点(`HStack { sourceCheckbox
     (source); Spacer(minLength: 0); sourceTestAccessory(source) }`),`sourceCheckbox`
     相应地不再自己占满整格宽度(那个职责交给外层 `HStack` 的
     `.frame(maxWidth: .infinity)`)。两个控件从此完全不共享任何屏幕区域,悬停/点击
     两条路都不用再互相避让,`sourceTestAccessory` 也因此能改回用真正的 `Button`
     (不再需要 `.highPriorityGesture` 那个没生效的变通)。
   - **「还没测过」这个态不给提示文案**(2026-08-31 用户要求"把这个 hover 文案去掉"):
     "测试这个来源现在是否可用"这句话信息量有限,图标本身 + 点击行为已经说明白是干
     什么的。提示只留给 warn/fail 的具体原因(下面这条),那才是真正需要读一下的信息。
   - ⚠️ **已修的真 bug:改成平级 `HStack` 兄弟节点之后,鼠标从复选框移向测试图标的
     路上图标会先消失**(2026-08-31 用户实机反馈"鼠标放在复选框上才显示,移过去就没了")。
     根因:`sourceCheckbox` 不再占满整格宽度之后,它自己的悬停范围(`hoveredSource`)
     紧贴内容(圆点+文字),跟测试小图标之间隔着 `Spacer` 撑出来的一段空白——鼠标途经
     这段空白时,复选框的悬停信号已经变 false(离开了它的范围),测试图标自己的
     `isAccessoryHovered` 还没变 true(还没进它的 16×16 命中区),两个信号同时是
     false,图标因此判定"不该显示"而消失,即便用户接下来会继续移到图标上(它到那时才
     会重新出现,但视觉上已经造成了"移过去就没了"的错觉)。修法:新增一个独立的
     `hoveredRow` 状态,悬停范围覆盖复选框+空白+图标**整行**(`ForEach` 里在外层
     `HStack` 上补一层 `.onHover`),专门只用来决定"这一行的测试图标要不要露出来",
     跟驱动复选框自己高亮底色/`.help` 提示的 `hoveredSource` 是两件不同的事,不合并。
   - **标题行「测试」(全部)不受任何单个来源测试锁住**(2026-08-31 用户明确要求
     "那个依然可以点击并触发全部搜索的逻辑,不要影响联动到右边的全部按钮上")。
     `LyricSourceTestService` 是单例、同一时刻只能真的跑一个 collector 子进程
     (`cancelRunning()` 杀掉上一轮),`isTestingLyricSources` 这道闸原来统一挂在标题行
     按钮和每个单独按钮上,导致点了某个单独的「测试」之后,标题行按钮也会被锁住点不了。
     改法:`testAllSourcesButton` 去掉 `.disabled(isTestingLyricSources)`,
     `testAllSources()`/`testSource(_:)` 都去掉各自的
     `guard !isTestingLyricSources else { return }`——两个入口从此随时可点,后发的一律
     取代先发的。取代之后需要处理"被取代那一轮怎么收场"这个新问题:被杀掉的子进程
     `await` 会抛错,如果收尾逻辑无条件执行,会把"新一轮刚设成 true 的
     `isTestingLyricSources`"或者"新一轮刚写下的结果"踩回旧值/覆盖掉。用一个
     `lyricSourceTestGeneration` 代数解决——每次发起测试先自增,收尾时核对代数没变才
     真的去改 `isTestingLyricSources`/写"失败"结果;代数变了说明已经被取代,收尾
     整段放弃,不留痕迹。单个来源的测试按钮之间仍然互相排队(各自的 16×16 命中区照旧
     `.disabled(isTestingLyricSources)`),只解开标题行那一颗,理由是它是"重来一次"的
     入口,语义上本就该随时可用。
   - **`warn`/`fail` 的 `detail` 默认是写死的通用文案,目前 `lyricfind`/`musixmatch`/
     `netease` 三个源接了具体原因诊断,其它四个(qq/kugou/lrclib/amll)验证过没有找到
     当前能复现的失败信号,原样留通用文案**:
     - **lyricfind(2026-08-31,用户实测点出 LyricFind 常年测出"疑似不可用"、追问"报错
       原因是否可以 hover 看到")**:排查坐实是 YouTube Music(LyricFind 借的正是它的
       接口,见 `ytmusic.go` 头注)按 IP 地理位置限定可用区域——这台机器上
       `music.youtube.com` 返回的不是真首页,是一个几 KB 的静态提示页"YouTube Music is
       not available in your area"(对照 `youtube.com`/`google.com` 同时能正常访问,
       排除了整体网络故障)。加了一条只读旁路 `ytmusicLastFailureReason`(跟
       `networkobs.go` 的 `networkLooksDown()` 同一个思路——不改 `ytmusicLyric` 的返回值
       形状,自动解析路径从来不需要"为什么没查到"这个原因):`ytmusicFetchVisitorID`
       拿不到 `VISITOR_DATA` 时检测这个特征字符串,识别出来才记一句具体原因,识别不出
       (页面结构改了/换了别的失败模式)就留空退回通用文案,不编一个没验证过的理由。
     - **musixmatch/netease(2026-08-31,用户追问"其余几个你可以去验证他们的失败模式
       吗",逐源实测验证的结果)**:musixmatch 的反爬限流(`musixmatch.go:269` 早就在
       检测 `status_code==401` 这个信号并退避重试,只是没往外报原因)是**当场复现**过的
       ——两个进程同时冷启动去换 token,第二个必现这个信号,`musixmatchLastFailureReason`
       接上之后端到端验证过整条链路准确传到 `test-lyric-sources` 的输出。网易云的
       `code:405`(限流,"操作频繁")同样是实测复现过的真实信号(`netease.go` 的 `get`
       闭包早就在拦截它),但网易云本身有两个接口互相兜底,只有**两个接口同一拍都被
       限流**这种少见情况才会真正走到"这个源整体没查到",没有为这个更窄的分支单独打一轮
       高强度真机复现(避免为了验证同一段代码形状再对第三方接口打一次不必要的高频请求)
       ——`neteaseLastFailureReason` 的代码路径跟已验证过的 musixmatch 那份是同一个模子,
       静态审查 + 编译通过,没有额外用真实高频请求复现。
     - **qq/kugou/lrclib/amll(同一轮逐源验证)**:四个源都实测跑通,没能找到当前可复现
       的失败信号——QQ 的 `Referer` 校验(缺失时返回 `retcode:-1310`)和酷狗的
       accesskey 校验(过期时返回 `error_code:20010`)都是真实存在的信号,但代码目前的
       写法从不会触发它们(QQ 每次都带对的 Referer;酷狗的 accesskey 每次都是现查现用,
       不存在"用一个过期的"这种情形),接上会是没有东西可诊断的空摆设;LRCLIB 全程 200,
       连缺 User-Agent 都不拒绝;AMLL 的 404("这首歌不在这个社区数据库里"——覆盖率本来
       就只有 ~3.9%)跟"仓库真的出故障了"目前没有任何能区分的信号。四个都没有加旁路,
       避免为没有事实依据的失败模式编一句"听起来有道理"的诊断文案。
   - ⚠️ **已修的真 bug:原因文案不能用 `.help()`(2026-08-31 用户实机反馈"悬浮并没有
     提示出来")**。根因:这个测试小图标叠在 `sourceCheckbox` 那个铺满整格、自己也带
     `.help(name)` 的大按钮上面——点击能正确分发到小图标(SwiftUI 的 hit-testing 按
     z-order 走,这一层已验证没问题),但 tooltip 走的是 AppKit `NSView.toolTip` 那条
     独立注册机制,两个互相重叠的原生 tooltip 区域会打架,悬浮在小图标这一小块上时
     系统可能什么都不弹,或者弹出来的其实是外层"来源名"那条。修法:改成自绘
     `.popover`(SwiftUI 自己管理的浮层,不经过 `NSView.toolTip`,不会跟外层的
     `.help(name)` 抢),用独立的 `accessoryHoverSource` 状态(跟整格悬停用的
     `hoveredSource` 是两件事)+ 固定 16×16 命中区(`.contentShape(Rectangle())`,不随
     图标是否可见变化,悬停判定不依赖内容本身有没有渲染出东西来提供几何)驱动。

16. **两首固定探测曲挑的"够红"不等于"探测得准"——加 kuwo 后第一次暴露**（2026-08-31，
    用户看到设置页「酷我音乐」测试图标常年报「两首探测曲都没有响应,这个源目前可能不可用」，
    追问原因）。排查坐实这跟接口连通性完全无关：`search.kuwo.cn`/`kuwo.cn/openapi` 两个
    接口全程 200，是真的活的；根因是酷我搜索结果对**越红、越被翻唱/DJ改编/演唱会现场版
    淹没**的歌命中率反而越低——原来的中文探测曲《晴天》(周杰伦)前排全是「KTV版伴奏」
    「DJ 阿若版」「演唱会 medley」，找不到一条原唱裸版本，同样的模式在《稻香》《童话》
    《海阔天空》《光年之外》上逐一复核过都成立，不是《晴天》运气不好。换了英文探测曲
    《Yesterday》(Beatles)/《Shape of You》(Ed Sheeran) 结果一致：前排是翻唱乐队冒名、
    Remix、甚至混进不相关曲目。

    改法：中文探测曲从《晴天》换成《少年》(梦然)——同样是传唱度极高的网络时代金曲，
    但实测酷我搜索结果排第一的就是原唱本人的完整单曲(带 MV 副标题)，能过跟其它源同一套
    身份闸(标题/歌手/版本限定词)，不是靠放宽闸门专门为 kuwo 开后门；对 netease/qq/
    kugou/musixmatch/amll 这些原本就稳定命中《晴天》的源，《少年》实测同样稳定命中，没有
    牺牲它们的探测可靠性。英文探测曲《Yesterday》原样保留——kuwo 本来就没有覆盖英文曲库，
    换哪首英文热歌都测不出它，不值得为了它去换一首可能反而降低其它英文源可靠性的曲目。
    两处字面副本（`healthcheckcli.go`/`testlyricsourcescli.go`，历史上就没有抽成一个
    共享常量）都要同步改，改一边漏另一边只会让两个入口(`collector healthcheck` vs 设置页
    的「测试」按钮)对同一个源给出不一致的结论。**验证**：`collector test-lyric-sources
    -source kuwo` 从 `warn` 变成 `ok`（`"detail":"接口有响应"`），`collector healthcheck`
    里「源 kuwo」那一行同步变成 `ok`；其余七个源(含改动前就稳定命中《晴天》的那几个)
    重新跑一遍确认无回归。

    ⚠️ **这条修的是"探测曲选得不准",不是"酷我覆盖率低"本身**——酷我对热门大牌歌手的
    原唱覆盖率确实结构性偏低(第 09 章已知坑第 26 条)，换探测曲不会、也不该假装解决这个
    覆盖率问题，只是不该让"探测曲恰好踩中已知短板"这件事被误读成"接口坏了"。

- **「提醒开关」两条数据源 Picker 从子行挪进开关同一行（2026-08-31，用户指定）**：`AccountLinkingTab.swift` 里「每周听歌小结」/「每日听歌报告」原来各自在开关打开后另起一条 `SettingsSubRow(title: "数据源")` 放 Picker，改成把 Picker 摆进 `SettingsRow` 的尾部控件区、开关左边（`HStack(spacing: 8) { if 开关开着 { Picker } ; Toggle }`）。仍然保留"只在对应开关打开时才出现"这条既有行为。顺带消掉一处一直存在的歧义：改之前那两条子行的标题**都是** `L10n.t("数据源")`，代码上方的注释却写着"两个 Picker 各给了区分度更高的标签（每周数据源/每日数据源）"——注释描述的是一个从未落地的版本，界面上两条同名子行到底哪条归哪个开关管只能靠位置猜；挪进各自那一行之后归属由行本身表达，标签直接不需要了（`SettingsRow` 给尾部控件统一套了 `.labelsHidden()`）。同一行放多个控件的写法照抄 `SettingsView` 的「全局时间轴偏移」那一行（Picker + 数值 + Stepper）。
