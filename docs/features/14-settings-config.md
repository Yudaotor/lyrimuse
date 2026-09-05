# 14. 设置、配置与本地化

> 最后核对：2026-09-03 · 基线：e103532+工作树

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
| 歌词（indigo） | text.quote | 四段：**获取**（**两张卡**，2026-09-05 拆开——此前一张「歌词来源」卡装五样东西，卡名只对第一样成立。卡一「歌词来源」：九源勾选[含每源独立「测试」按钮＋卡片右上角「测试」（原「全部测试」，2026-08-31 去掉"全部"两字），2026-08-30]；卡二不带卡名（同「译文」「效果」卡）：匹配算法智能/顺序优先[**纵向原生 radio 组**（`.pickerStyle(.radioGroup)`），「智能算法」标签带「（推荐）」后缀（格式键 `%@（推荐）`，沿用引导页「Apple Music 自动化权限（推荐）」写法）；副标题随选中项变（智能→「给每个来源打分，取分最高的」，顺序→「不打分，按下面的顺序取第一个有结果的来源」），原「?」气泡撤掉。⚠️ 2026-09-03 版是分段控件＋叠在 Picker 左上角的 8pt 橙星，2026-09-05 用户原话「星星好丑啊，违和感很强」，根因是 `NSSegmentedControl` 没法按格放东西、只能往控件外叠装饰——**以后要强调某一档就改文字，别再叠图标**]＋顺序列表[2026-09-05 每行左侧 `line.3.horizontal` 把手拖拽排序，算法在 Core `ReorderDrag`（滞回 6pt / 让位按槛距 / 写回完整排列保禁用槽位）；上下箭头保留作键盘 / VoiceOver 通路并补 accessibilityLabel；见设计决策第 20 条]＋**自动跟进算法升级**[2026-09-03，`lyrics_auto_upgrade`，默认开；关掉后已选定的歌词不再被后台重打分/升级重搜换掉，闸门在 collector 的 `needsLyricsRescore`/`needsLyricsRetry`，见第 09 章]＋提前解析同专辑）/**译文**（显示译文→译文语言→系统兜底翻译→翻译语言包[2026-09-05 从下拉菜单改成「已下载 6 / 18 ＋ 管理…」，点开在卡里展开 3 列语言网格：✓ 已下载不可点、⭳ 未下载点击触发系统下载 sheet、转轴下载中，网格下一句说明＋「打开系统设置」去删包；读数按**当前译文语言**统计语言对，译文语言自己与同语系语言被过滤，所以比系统设置的「已下载语言数」少是正常的——用户曾因此觉得"有 bug"，进程外探针核过系统真值一致]）/**效果**（卡拉OK效果、中文繁简切换[按语言条件显示]、显示罗马音＋日韩中分语言勾选、时间轴偏移±5s步长0.05＋作用于哪个播放器的下拉框）/**管理**（歌词管理入口＋歌词库统计面板[总数/逐字/逐行/纯文本/纯音乐/暂无，2026-09-03，见第 11 章 §7]＋歌词文件夹）。分段选择器记忆上次停留段（`@AppStorage settings:lyricsSection`） |
| 播放器（mint） | play.circle | 播放器选择（Apple Music/QQ音乐/网易云/Spotify/自动）、Apple Music 自动化权限状态、后台采集服务状态。**侧栏项尾部带警告徽标**（2026-09-03，橙色感叹三角，悬停看原因）：已选 Apple Music 且自动化权限被拒，或后台采集服务开着却没在跑；判定 `PlayerHealth`（Core，纯函数），数据源 `PlayerHealthMonitor`（设置窗口开着期间每 2s + App 激活时刷新，AE 权限查询与 collector 状态查询都在后台线程）。平时不亮，见设计决策 #17。页面订阅经窄代理 `PlayerTabStores`；浏览器卡片的实时状态由 `refreshBrowserLiveStatus` 后台查进 `browserLiveStatus` 缓存，body 只读缓存（见设计决策 #18） |
| 歌词显示（yellow） | rectangle.3.group | 四段按展示面分。前两段是**编辑台**版式（内容区里一块 1:1 的实时画布＋工具栏浮层＋舞台内的宽度调整条，页顶不钉预览）：**悬浮歌词**（`OverlayEditorStage`：**两行工具栏**共五个浮层，第一行「主题」[配色主题/我的配色主题]／「文字」[字体/粗细/字号＋跟随封面/文字色/文字描边/描边色]／「背景」[背景色/毛玻璃背景]＋「重置▾」，第二行「排版」[双行显示/对齐方式]／「行为」[锁定位置/长按拖动/悬浮淡化＋截屏/录屏时隐藏、暂停/无播放时隐藏]（⚠️ 2026-09-02 按"改的是哪一层"把原来的「文字」＋「配色」重新分成 **主题 / 文字 / 背景** 三组，组件 `OverlayThemePopover` / `OverlayTextPopover` / `OverlayBackgroundPopover`；工具栏按钮已接上，两个过渡壳 `OverlayColorPopover` / `OverlayStyleSummary.color` 已删、全仓 0 引用，见 04 章第十七步）；舞台内宽度条；下面只剩开关＋「全部设置」折叠抽屉）/**灵动岛**（`NotchEditorStage`：两行工具栏共七个浮层[风格/屏幕/左耳/右耳＋歌词行/行为/展开态]＋「重置▾」＋舞台内宽度条；下面是开关＋「全部设置」折叠抽屉[2026-08-31 补齐，跟悬浮歌词那个同一个定位]）/**菜单栏**（`MenuBarEditorStage`，2026-09-01 也改成了编辑台：一行工具栏[布局（宽度模式/对齐方式/歌词旁的图标/悬停显示播放控制，2026-09-03 加第四行「悬停显示播放控制」——它是个**行为**开关，塞进「布局」而不是新开第四个工具栏入口，因为那一行的横向预算已经用尽，见 `MenuBarEditorStage.toolbar` 头注）／配色／字体（2026-09-03 加第三个入口：粗细六档下拉 + 字号滑杆 10~16pt，字体族仍跟系统；「粗细」英文词条为此从 Font Weight 缩成 Weight，横向预算同上）]＋「重置▾」＋一块**舞台**——壁纸铺满、仿菜单栏条贴上边缘、宽度胶囊浮在舞台内的通道里，caption 在舞台外；下面是总开关＋「全部设置」折叠抽屉。⚠️ 「页顶仍钉一条仿菜单栏预览」这个旧说法从那天起就不成立了，预览已经搬进可滚动内容区；壁纸底 2026-09-02 又从"只垫菜单栏那一条"扩展成"包住整块舞台"，见 06 章）。⚠️ **原来还有第四段「其它」，只装着一张跨形态的「自动隐藏」卡，2026-09-01 整个撤掉**（用户原话：「不要单独开一个其他页面出来了」）——那两个开关同时被**拆成两份独立的值**（`hideDuringScreenCapture`/`hideWhenNotPlaying` 归悬浮歌词，`notchHide*` 归灵动岛），各自摆进对应形态那一段（排在「全部设置」抽屉上面）。⚠️ **2026-09-02 再进一步**：那两张独立卡也撤掉了（用户原话：「不要单独放在外面，要遵循设计理念，放到行为卡片里面去」），两个开关分别并进悬浮歌词的「行为」栏（＋抽屉「窗口」组）和灵动岛的「行为」浮层（＋抽屉「行为」组），渲染真源合成一份 `UI/AutoHideSettingsRows.swift`——**共用的是视图与文案，值仍是两份**。这一页因此不再有任何一张只装隐藏开关的卡。⚠️ **同日第三次**：用户看过成品后要求「和灵动岛设置页一样处理，放到上面的小按钮里面，点了出现下拉框」，于是悬浮歌词那条**「行为」栏本身**也删了（`OverlayBehaviorBar`），五项进了编辑台工具栏新起的第二行「行为」浮层（`OverlayBehaviorPopover`，宽 420，跟灵动岛那个同宽）——两个形态的「行为」入口至此完全同构。这一段因此只剩编辑台＋开关＋抽屉三块，页面内容高度 605→449pt。详见 04 章第十六步。⚠️ **这两个数按当时口径少算了约 86pt**（一直拿第一步的画布 246 在加，而画布第九步起就是 332），真实的逐块账见 04 章「高度账」那张表。⚠️ **2026-09-03 又压了一次**（用户原话：「这个预览窗口给我高度搞小一点，把下面的开关完整漏出来」）：编辑台 425→**382**（`maxCardHeight` 288→266，＋删掉舞台底下那行常态为空的 caption，那句「两端已裁切」搬进舞台里跟宽度调整条并排），总开关卡的底边从 551.5pt 落到 508.5pt，552pt 高的窗口（可视内容 519pt）里从"只露 13.5pt"变成完整露出；抽屉头仍在折线以下。详见 04 章第十八步。删掉一个分段 rawValue 是安全的：`section` 计算属性带 `?? .overlay` 兜底，老用户上次停在「其它」段的话下次打开会落回悬浮歌词。⚠️ 页顶那层固定头部**收不到点击事件**，凡是可交互的预览都只能待在滚动区。歌词窗口刻意不在此页配置（按需打开的窗口，非常驻展示面） |
| 快捷键（teal） | keyboard | 全部 16 个全局快捷键的录制行（四张卡：显示 / 窗口 / 歌词时间轴 / 播放控制）+ 调整步长 |
| 通用（gray） | gearshape | 菜单栏与 Dock（菜单栏图标：12 款 2×6 的 `MenuBarIconPicker`，行尾常驻所选款名；随播放律动；在 Dock 中显示）、语言与启动（语言：跟随系统 / 简体中文 / 繁體中文 / English，引导页欢迎页同一组选项；开机启动）、配置备份与搬家（iCloud/自选文件夹备份、设置文件导出/导入；配置文件夹 2026-09-01 搬去「关于」）、清除所有设置。⚠️ **这一页没有预览**：2026-09-04 曾按「歌词显示」编辑台范式在页顶放过一块仿菜单栏舞台（真壁纸 + 所选图标本体、律动时真的动），用户看完明确不要（「我不想这块」），次日撤掉——菜单栏就在屏幕顶上，选哪款抬头就看得见，别再加回来 |
| 关于（blue） | info.circle | **2026-09-03 重排**：页头 = 图标 + 名字 + 可点击拷贝的版本胶囊（版本 · 芯片架构）+ tagline + 两颗胶囊按钮（请作者喝杯咖啡 / GitHub 带 star 数）+ 求 star 那句；四张带标题的卡：更新（检查更新＋副标题「上次检查 / 有新版本」、自动检查、自动下载并安装）、反馈与社区（反馈问题、想法与建议）、许可与版权（使用与版权说明、第三方许可、开源许可证）、诊断与数据（导出诊断信息、配置文件夹）；页脚「© · GPL-3.0」 |
| 账号 | — | `AccountLinkingTab`（见第 12 章） |

「歌词」与「歌词显示」的边界：前者管歌词**数据与内容**（哪来、什么语言、什么效果、存哪），后者管**展示形态**（显示在哪、长什么样、何时隐藏）。

**顶层分类记上次停留（2026-09-04）**：新建设置窗口时落在上次停留的顶层分类（`SettingsTab.restoredLastTab()`，`@AppStorage settings:lastTab`；`SettingsTab` 因此有了 String 原始值 = case 名，改 case 名会让老值解码失败退回「歌词」）。只记六个顶层分类，账号页（`.account`）不记——它多半在默认折叠的「实验室功能」区里，记了下次打开就是「detail 切过去、侧栏高亮不到」的状态，且账号页的落点本来就由引导页的信箱管；`AppActions.requestSettings` 的信箱 / subject 在 `.onAppear` / `.onReceive` 里覆盖记忆，优先级更高。初值在属性初始化器里直接读盘，不在 `.onAppear` 里补跳（那样会先画一帧「歌词」再切）。键用 `settings:` 前缀：与二级分段（`settings:lyricsSection` / `settings:appearanceSection`）同一约定，配置导出只带 `np:` / `KeyboardShortcuts_`，界面停留位置这种机器状态天然不随备份走（selftest contracts 组守着键名前缀与导出过滤两头）。停在「关于」这类低频页下次也落在那里，接受。

### 2. 两套配置存储 + 镜像

- **`AppSettings`**（UserDefaults，`np:` 前缀，48 个 @Published）：App 自身偏好（外观/窗口/图标/开关），`didSet` 里同步写 defaults，**立即生效**。部分项**双写**到 `LocalPlaybackSource`（如繁简转换、卡拉OK、罗马音语言集），让当前这首歌立刻重新解析——只写一边的话要么关 App 就忘、要么等下一首才生效。
- **`FeatureSettingsStore`**（`~/.config/lyrimuse/lyrimuse-features.json`）：需要 collector 参与的功能开关（player/lyricsSources/lyricsSourceMode+Order/lyricsDir/lyricsTranslationLanguage/albumPrefetch/lyricsMachineTranslation/lastfmMirrorScrobble/daily+weeklyDigest(+source)/launchLyrimuseOnMusicOpen/trustedPlayers（信任的未知播放器，见第 02 章））。`save()` = 立即 `persistFile()` + **0.5s 去抖的 collector 重启**（连续快速切多个开关只重启一次；`launchctl kickstart -k` 被 launchd 节流约 10s，去抖前实测会造成推送反复中断）。所有等待中的 save 调用共享同一次重启结果。枚举 rawValue 与 collector `features.go` 常量逐字对应（共享 JSON 的契约）。
- **`ConfigStore`**（`~/.config/lyrimuse/config.json`，账号凭据：ListenBrainz token/用户名、状态中继地址/token、Last.fm 账号与 scrobble 凭据、推送平台与 webhook、钉钉/飞书签名密钥；collector 侧 `config.go` 读同一份文件，**只读不写**）：整字典读写（`api_root`/`bundle_ids`/`log_level` 这些 UI 不管的字段原样保留）。触发者是 AccountLinkingTab 的 1.2s 输入防抖自动保存、账号切换/关窗兜底、Last.fm 授权成功与「断开」（这两条**不看 `isDirty`**）、以及 AppDelegate 退出前兜底（只在 `isDirty` 时）。`save()` = `persistFile()`（原子写 + 0600，见 `SecretFileWrite`）+ 走 `CollectorRestartCoordinator` 的合并重启 + `commitSnapshot()`。
- **两份共享文件的读写口径（2026-09-05，借鉴清单 #46）**：`ConfigStore` / `FeatureSettingsStore` 的读盘、合并、写盘都走 Core `JSONConfigDocument`。读盘分**三态**：不存在（首次保存允许创建）/ 正常 / **损坏**（文件在、但不是 JSON 对象；features.json 还多一条「对象合法但字段按类型解不出」也算损坏）。损坏时 `loadFailure` 亮起、`persistFile()` **拒绝**保存（抛 `ConfigFileSaveError.refusedCorruptFile`，`save()` 把它跟「写失败」分开报进 lastError），设置窗口 detail 列顶部钉出 `ConfigFileDamageBanner`：说明哪份文件、技术原因（只含解析位置/键名/期望类型，不含文件内容）、两个出口——「在访达中显示」自己修（修好重开 App），或「放弃坏文件并重建」把它改名成 `<文件名>.corrupt-<yyyyMMdd-HHmmss>` 留在原目录、再用当前值重建。写盘是合并 → 序列化 → 写 → **成功后才更新内存镜像**，写失败字典与状态都不动。合并规则：已知键以本次编码为准（没给的已知键删掉——遗留迁移字段 `player` / `lastfm_scrobble_first_artist_only` 靠这条「往后不再写」），其余键原样保留（features.json 里这台机器不认识的 `ytmusic_lyrics` 之类就这样活下来）。诊断导出 State 段各报一行三态。selftest：ops-diagnostics「配置文件三态读写」拿真实临时目录钉逻辑，contracts「共享配置文件的读写口径」扫两个 Store 不许自己读写盘。取舍见设计决策第 19 条。
- **`AppSettingsMirror`**：App 偏好一变就镜像成配置文件夹里的 JSON——让「拷走整个 `~/.config/lyrimuse` 文件夹」这条搬家路径不再静默丢掉 UserDefaults 那一半（2026-08-13 用户指出的裂缝）。

### 3. 全局快捷键（GlobalHotkeys，KeyboardShortcuts 库）

16 个（2026-08-31 从 10 个加到 16 个），设置页「快捷键」分四张卡：**显示**——显示/隐藏悬浮歌词、显示/隐藏灵动岛歌词、显示/隐藏菜单栏歌词、锁定/解锁位置、显示/隐藏译文、显示/隐藏发音；**窗口**——打开歌词管理、打开歌词窗口、搜索歌词、打开设置；**歌词时间轴**——歌词提前、歌词延后、歌词偏移归零（外加「调整步长」）；**播放控制**——播放/暂停、下一首、上一首。默认全部不预置，用户自己录制才生效（`GlobalHotkeys.swift` 头注定的原则：不会有按键在用户不知情下被这个 App 抢占；所以也没有「恢复默认」，行尾只有清除）。08-31 加的六个（搜索歌词 / 译文 / 发音 / 灵动岛 / 菜单栏 / 偏移归零）选键判据是「别的 App 占着焦点时你还想按」——只在某扇窗已经在前台时才有意义的动作（随机/循环、置顶、全屏）刻意不给全局键，那是本地键该管的。其中：「搜索歌词」直接开独立小窗（`AppActions.openLyricsQuickSearch`，见 04/07 章），在这之前这个入口只在悬浮窗 ⚙ 快捷菜单里；译文 / 发音 / 灵动岛 / 菜单栏四个开关按完都有瞬态提示条回声（`flashHint`，「已显示译文」之类）——它们改的是看得见的东西，但当前这首歌没有译文 / 注音时画面不会变，没有回声就分不清是没按中还是没内容；「显示/隐藏发音」绑的是总开关 `showRomanization`、不在拼音 / 粤拼 / 日 / 韩之间轮换（用户明确要求「开关罗马音而不是切换」，分语言的勾选留在设置页，那是配置不是随手按的东西）；灵动岛走 `NotchLyricsWindowController.setVisible(_:)` 这个唯一入口而不是直接翻布尔（同菜单栏菜单的做法，隐藏偏好的套用都在那里面）；「歌词偏移归零」复用三处菜单共用的 `resetLyricsOffset()`。新增快捷键必须同时登记 `allLyrimuseNames` 与 `title(for:)`——撞键检查与提示文案都靠这两处，selftest 够不着这个文件（它在 app target 里、还要 import KeyboardShortcuts），只有 debug 断言兜得住「登记了没写标题」。歌词提前/延后按「调整步长」设置的幅度改**单曲**偏移（与菜单栏「歌词时间轴」同一个值；「全部播放器」和按播放器两档都在设置页那一行单独校（同一个 Stepper，靠下拉框切作用域，两档**二选一、不相加**），步长固定 0.05s，基准再与单曲微调相加——见第 08 章）。要求至少搭配 ⌘/⌥/⌃ 之一。绑定存 UserDefaults `KeyboardShortcuts_` 前缀。

### 4. 配置备份与搬家（ConfigPortability / ICloudConfigStore）

- **导出**：config.json（含账号 token **原文**）+ features.json + UserDefaults（`np:` + `KeyboardShortcuts_` 前缀）合成一份 JSON。UI 警示「包含账号密钥，不要分享」——与诊断导出刻意相反（那个绝不含 token）。
  - **副标题与 `?` 气泡分工，不重复说**（2026-09-01，用户反馈「文案太啰嗦」）：这一行原来副标题和气泡把同样三件事各讲一遍，气泡那段 110 字基本是副标题的长版，点开只是把刚看过的话再读一遍。现在副标题只留「点之前必须知道的后果」（`含明文凭证；导入会覆盖全部设置并重启`），气泡只补副标题装不下的细节（歌词库是第二个文件、覆盖范围含账号与数据发往的地址）。顺带修了一处不准确：原副标题说「含账号凭证与歌词库」，但歌词库**根本不在这个文件里**（见下面的 sidecar 一节），而那正是用户最容易漏拷的东西。
- **排除键**：`hasCompletedOnboarding`/`hasShownAutomationOnboarding`/`hasOfferedICloudImport`/`hasShownOverlayDragHint` 等「机器状态」不随人走（新机器该自己走引导/授权）；**`np:collectorInstalledFingerprint`、`np:lyricsWindowFrame`、`np:lyricsWindowScreenID`（均 2026-08-22 加）同属此类**——它记的是「这台机器上现在装进 launchd 的是哪个 collector 二进制」，新机器上必然是另一个文件，带过去会让启动对账误以为「没变过」而跳过那次本该做的重装，正好把 Sparkle 更新的兜底关掉（机理见第 15 章 §2）；后两个是歌词窗口的位置/尺寸与它所在那块屏幕的 UUID，判据跟 `np:overlayPosition*` 一字不差（绝对屏幕坐标 + 一块具体显示器，新机器的排布和 UUID 全不一样，见第 07 章）；**悬浮窗位置 `np:overlayPositionTop`/`np:overlayPositionOrigin` 同属机器本地键**（存的是绝对屏幕坐标，新机器显示器尺寸/排布不同，搬过去只会把窗口摆到看不见的地方——同 05 章 `notchScreenID` 的判据），见 `ConfigPortability.machineLocalDefaultsKeys`；导出导入用同一个排除集合，旧文件里的这些键导入时也被挡。
- **歌词库走 sidecar，不进配置包**（2026-08-21 加）：每次「存到 iCloud」/「导出…」都在配置包**旁边**多写一份同名同时间戳的 `Lyrimuse-Lyrics-<时间戳>.json.z`（`-Config-` 换成 `-Lyrics-`），内容 = `lyrics/` 文件族（歌词六字段的权威源）+「已校准」名单，zlib 压缩（实测 14.5 MB → 6.1 MB）。导入时按这个位置关系找兄弟文件；找不到就**一个歌词文件都不动**（老备份/只导设置，绝不能当成"空歌词库"去清本机的）。
  - **为什么不塞进配置包本体**（三条硬约束，任一条都足以否掉）：① `ICloudConfigStore.latestSnapshot()` 为取 `exportedAt`/`deviceName` 会在**主线程整份读+解析**配置包，而它挂在设置页 `.onAppear` 等多处 —— 包变大就是每次进设置页卡一下；② `write` 每次点都新写一份带时间戳的文件，**没有大小上限也没有"只保留 N 份"清理**，旧份永不被读 —— 几十 MB × N = iCloud 黑洞；③ 新机首启那条自动询问只给 8s 下载超时且**静默**跳过。sidecar 一并绕开三条，且 `BackupDiscovery` 只认 `Lyrimuse-Config-*.json`，天然不会把 sidecar 误认成配置包。
  - **为什么歌词正文走 `lyrics/` 文件族而不是直接盖 enrich 缓存**：文件族是六字段权威源，collector 每次启动跑 `importLyricsFromFiles`（文件赢、只增不删、缓存里没有那个 key 也会新建条目），所以文件铺回去歌词自己会长回缓存；反过来直接盖写 `lyrimuse-enrich-cache.json` 会撞上"collector 内存整份写回"的竞态（`EnrichCacheStore.clearAll` 那两轮实测的坑）。**顺带保住单曲校正值**：它的 key 含歌词内容指纹，走文件族恢复正文逐字节不变，那批校正值到新机器才真的还有效。
  - **`meta`：缓存的非歌词字段也一起带走**（2026-09-02 加，修正一条错了的旧判断）。这里原来写「缓存里其余字段（封面/链接/mbid/打分/决策存档）都是可重新解析的派生数据」——"可重新解析"对其中四类**不成立**，用户实测撞上（原话「在另外电脑导入了配置，但是并没有把歌曲的决策解析给带过来」）：
    - `lyrics_decision` / `lyrics_decision_applied`（作者机 2414 / 2368 条）记的是**当时那一轮**各源分别给了什么、得了多少分，是历史快照；重新解析只会写一份**今天的**，「解析决策」里的证据链就断了。
    - `plain_lyrics` / `plain_lyrics_source`（手点「采纳为静态文本」）没有时间戳、不属于四种歌词后缀，**压根没有导出文件**，此前不在任何备份里，100% 丢失。
    - `manual_pick_sha`（手动选定后锁定的追溯凭据）同样没落文件；丢了之后 `ManualPickLock` 把这首歌算成「从没手动选过」，锁不上而且**完全静默**。
    - `lyrics_scoring_version` 丢了读成 0、落后于当前打分版本 → `needsLyricsRescore` 把**全库**排进「按新规则重选一次」的队列，赢家一变就把刚恢复的正文换掉，连带单曲校正值的内容指纹一起失效（只有 `manual_lyrics` 和 pins 名单挡得住）。
    - 修法：sidecar 载荷多一个 `meta` 字段 = **整份缓存剥掉那六个歌词字段**（`LyricsBackupArchive.strippedMeta`，剥黑名单而不是挑白名单——缓存字段长期在加，白名单的失效方式正是静默漏搬新字段，也就是这个 bug 的同款成因）。实测 41.8 MB → 9.7 MB，base64 进 JSON 再 zlib 只占 1.25 MB（sidecar 13.8 → 15.1 MB，+9%）。
    - **恢复不直接盖缓存**（那条竞态依然成立）：`restore` 只把 `meta` 落成 `~/.config/lyrimuse/lyrimuse-enrich-restore.json`，由 collector 在启动路径里合并（`enrichrestore.go` 的 `adoptEnrichRestore`），跟 `importLyricsFromFiles` 同一个时机、同一把 `enrichMu` 锁。位置有三条硬约束：`loadEnrichCache` 之后（要有 `enrichPath`）、`migrateEnrichKeys` 之前（备份里的 key 要跟着一起归一化）、`importLyricsFromFiles` 之前（那一步让文件族赢下六个歌词字段）。
    - 合并是**字段级**：备份里出现过的字段一律赢（用户点的是"恢复"），备份里没有的保持本机的值不动（既不会清掉刚从文件导进来的正文，也不会弄丢本机已解析、而备份里没有的东西）。采纳成功后文件**改名**成 `.applied` 而不是删掉——`saveEnrichCache` 没有错误返回，无法确证已安全落盘，留一条人工找回的路；同名覆盖，最多留一份。解析失败则**原样保留、不采纳**。
    - 版本：载荷 `payloadVersion` 1 → 2，**两个方向都能互读**、不需要迁移代码（v1 老包解出来 `meta == nil`；v2 新包在只认 v1 的旧版本上，`meta` 作为未知字段被忽略、歌词照常恢复）。
  - 落地顺序**要紧**：歌词恢复必须排在 `importData` **之后** —— 歌词目录是 `features.lyricsDir`（用户可自定义的绝对路径），而那个文件是 `importData` 刚写的。恢复语义是「覆盖同名、只写不删」，账目（新增/覆盖/拒收）在 `LyricsBackupArchive.plan`。
  - **文件名安全**是硬边界：归档是外来文件，恢复就是拿里面的名字拼路径写盘。两道闸：① `sanitizedFileName` 挡路径分隔符（`/` `\`）、以点开头、非歌词后缀、超长名；② 落盘前再校验**解析后的父目录必须仍是歌词目录**（跟"名字长什么样"无关，兜住规则里没想到的形态）。selftest 30 条，含变异测试验证过的目录穿越。
  - ⚠️ **别再加"名字里含 `..` 就拒收"那条规则**（2026-08-21 实测踩过）：专辑/歌名以句点结尾很常见（陶喆《I'm O.K.》、Wale《everything is a lot.》），导出的文件名天然长成 `陶喆 - 天天 - I'm O.K..yrc`，那条规则把这类文件**静默**踢出备份 —— 实测一次漏掉 23 个而界面上什么都看不到（第一次真机核对才发现：归档 3059 个 vs 磁盘 3082 个）。`..` 只有作为完整路径分量时才危险，而带分隔符的名字第一道已经拒了。
  - 自动询问那条路给歌词的下载超时是 **60s**（配置那份仍是 8s）：歌词包 6 MB 上下，用同一个 8s 会大概率静默落空，而这一步落空恰恰最疼。失败**不阻断**导入。
  - ✅ **备份份数不做任何管理，攒多少份都行（2026-09-01 用户拍板，别再改）。**
    - 起因：上面第 ② 条否决「歌词进配置包」的理由之一正是「`write` 每次点都新写一份、没有『只保留 N 份』清理、几十 MB × N = iCloud 黑洞」——而 sidecar 走的是同一个 `write`，黑洞只是搬到了隔壁。实测作者 iCloud 里 **9 份配置 + 8 份歌词包 = 55 MB**，其中三份的时间戳是 `020313`/`020328`/`020334`（**21 秒内连点三次，每次上传 8 MB**）；而这些历史**在界面上还够不到**——恢复只走 `latestSnapshot()`，想用旧的一份只能开访达 +「从文件导入…」。
    - 当天先后做过两版清理：卡头 ⋯ 菜单里的「只保留最近 3 份（现有 N 份）」，以及后来的「写入时自动只留最近 3 份」。**用户看完上面这些数据之后仍然明确否掉：「不需要这个清理逻辑，想塞几份就几份」。** 那是他的磁盘和他的备份，「攒着」本身就是他要的行为。
    - 于是两版清理**连同它们的支撑代码一起删干净**：菜单项、确认弹窗、写入时的 prune 调用与回执、`keptICloudBackups`、`backupCount` 状态，以及 `ICloudConfigStore.existingBackupNames()` / `pruneBackups(keeping:)` 这两个只为清理服务的方法（`latestSnapshot()` 走独立的 `BackupDiscovery.latest(in:)`，不依赖它们）。
    - ⚠️ **别再「顺手」加回来**：写入时清理、定时清理、「超过 N 份就提醒」都不要。这是被明确否掉的方向，不是没人想到——`ICloudConfigStore` 里删除处留了同样的告示。真要省空间，卡头菜单里的「打开备份文件夹」让用户自己删。
- **iCloud**：ad-hoc 签名用不了官方 iCloud API（无 entitlement），走第三条路——把 `~/Library/Mobile Documents/com~apple~CloudDocs/Lyrimuse/` 当普通路径读写。**只做搬家不做持续同步**（iCloud Drive 冲突可能静默挑版本，对带 token 的配置不可接受）。新机器首启探测到备份会问一次要不要导入（`hasOfferedICloudImport` 只问一次）。
- **清除所有设置**：只抹本机（defaults + 配置文件），iCloud 与已导出备份不动；确认弹窗防误触。它扫的是**全部** `np:` 前缀、不看排除表，所以三份歌词偏移（全部播放器 / 按播放器 / 单曲）会一起被清掉——这跟「歌词管理」那个只清单曲那份的入口是两件事（见第 11 章）。**2026-08-21 补**：它现在也会 `LyricsPinStore.removeAll()`。原来不清，于是清完留下一份**孤儿「已校准」名单**（那是独立文件、不在 `np:` 前缀里）：collector 继续拒绝给这些歌自动升级歌词，而它保护的校正值早已不存在，用户在界面上完全看不到原因。同源的第二处在 `EnrichCacheStore.clearAll()`（清空全部歌词缓存），也一起补上了。
- **偏移那三个键都随人走**：`np:lyricsGlobalOffsetMs` / `np:lyricsOffsetsByPlayerJSON` / `np:lyricsOffsetsByTrackJSON` **不**在 `machineLocalDefaultsKeys` 里。判据是「这是这个人的偏好还是这台机器的状态」：按播放器那档记的是「这个 App 报的播放位置系统性偏多少」，换台 Mac 装同一个 App 行为一致，属于偏好。（唯一的反方向论据是 02 章记的「幅度等于站点 JS/网络耗时」跟机器/网速有关，但它顶多偏几百毫秒、且用户在设置页看得见改得动，不构成表里那些「界面说谎」的不可见错误状态。）

### 5. 开机启动 / Dock / 更新 / 引导

- **开机启动**（LoginItemManager）：不用 SMAppService，直接写经典 LaunchAgent plist 到 `~/Library/LaunchAgents`（label `me.yudaotor.lyrimuse`），`RunAtLoad=true` **无** KeepAlive（前台 GUI 工具，Cmd-Q 退出后不该被拉活）。指向 build.sh 安装的 `.app` 路径，开发调试路径不写入。
  - 🔴 **这个开关只准写/删 plist，一行 `launchctl` 都不准有**（2026-09-03，用户报「点一下开机自启动就直接闪退软件」，修了三次才收口）。两个方向各有一个坑，**都不产生 crash report**，所以现象只是「闪退」、完全指不到这个开关：
    - **关**：原来是 `launchctl bootout gui/<uid>/me.yudaotor.lyrimuse`。而 **App 本身就是那个 job**（build.sh 装完走 bootstrap + kickstart，开机自启同理）——等于让 launchd 给自己发一记 SIGTERM。日志证据：`osservice<me.yudaotor.lyrimuse> Process exited: domain:signal(2) code:SIGTERM(15)`。
    - **开**：原来是 `launchctl bootstrap` + plist 里的 `RunAtLoad=true`——bootstrap 的一瞬间 launchd **再起一个 lyrimuse**，老进程让位退出。日志证据：老 pid `Process exited: voluntary`（注意**不是**信号），新 pid 在**同一秒**启动。
    - 修法不是"加个判断"（第二版就是那样，只堵住了关的方向），而是**砍掉整类问题**：plist 文件就是「下次登录启不启动」的全部机制，launchd 登录时从 `~/Library/LaunchAgents` 读它；本次会话里注册与否对用户没有任何可观察差别（无 KeepAlive）。所以 `install()` 只写文件、`uninstall()` 只删文件，`run()` 辅助函数一并删除。
    - ⚠️ **也不要改用 `launchctl disable`**：那是持久化黑名单、跨重装依然生效，以后重新打开开关时 bootstrap 会被静默拒绝，是个更难查的坑。
    - selftest 有机械闸（`contracts` 组「开关不起进程」）：`LoginItemManager.swift` 的非注释行里不准出现 `launchctl` 或 `Process()`。做过变异测试：塞一行 `_ = "/bin/launchctl"` 当场红。
    - 顺带记一条**排查手法**：这类"闪退"先看 `log show --predicate 'composedMessage CONTAINS "me.yudaotor.lyrimuse" AND composedMessage CONTAINS "exited"'`——`RBSProcessExitStatus` 会直接告诉你是**信号**（被谁杀）还是 **voluntary**（自己退），两者指向完全不同的原因。`~/Library/Logs/DiagnosticReports/` 里没有 `.ips` **不等于**没出事，干净终止本来就不生成。
- **在 Dock 中显示**：切换 NSApp activationPolicy（accessory ↔ regular）；关闭后只留菜单栏图标。accessory 策略下打开任何窗口都要先 `NSApp.activate` 否则 openWindow 静默无效（多处调用点共用这个坑的修法）。
- **这个永久偏好关着时，辅助窗口自己借一个 Dock 图标**（`AuxiliaryWindowActivation.swift`，2026-08-04）：「设置」/「歌词管理」/「歌词窗口」/「欢迎使用」四扇窗各自的根视图在 `.onAppear`/`.onDisappear` 里报到，用一个开关计数器 `openCount`——只要还有任意一扇开着就借 `.regular`，全部关掉才还原成 `.accessory`，不跟上面那条永久偏好打架（用户手动开了永久显示的话，这边全程不用管）。目的是这几扇窗打开期间能进 Cmd-Tab、能靠 Dock 图标切回来，不用非得先回菜单栏点。
- **更新**（SparkleUpdaterManager）：Sparkle 标准流程（SPUStandardUpdaterController，startingUpdater:true 按 Info.plist SUFeedURL/SUEnableAutomaticChecks 周期检查），标准模态弹窗，无 gentle-reminder 定制（2026-09-03 用户拍板不做）；同日起挂 `SPUUpdaterDelegate` 只**记录**「发现 / 已下载 / 已跳过 / 开始安装」状态（`availableUpdate`），供菜单栏面板底栏显示「有新版本」并一键拉起 Sparkle 窗口，不接管任何显示权（见 06 章决策 #15）。关于页有手动「检查更新」+自动检查/自动下载开关。
- **关于页那个 star 数角标**（2026-09-03，用户原话「帮我在这里加一个 star 数，代表我这个仓库目前实际的 star 数」）：同日下午重排后挂在页头「GitHub」胶囊按钮里（此前是「GitHub 仓库」那一行标题列与「打开」按钮之间），显示 `★ N`，N 来自 GitHub 公开 API `GET /repos/Yudaotor/lyrimuse` 的 `stargazers_count`。
  - **判据全在 `LyrimuseCore/Util/GitHubStars.swift`**（请求地址 / 6 小时 TTL / 30 分钟失败退避 / 响应解析 / 限流退避），发请求与 `@Published` 在 `Settings/GitHubStarsService.swift`（单例），角标视图是 `SettingsView.swift` 里的 `GitHubStarsBadge`。这么拆是因为 selftest 只能 `import LyrimuseCore`（App 是可执行目标），纯逻辑放 Core 才钉得住——15 条断言在 `OpsDiagnosticsTests.swift` 的「GitHub star 数」小节。
  - ⚠️ **取不到就整行不画角标**，不显示 0、不转圈、不显示错误态。0 是个"看起来很确定的错数字"，而这一行的语境是「你的 ⭐ 是最大的鼓励」，显示 0 star 比不显示糟得多。首次成功后数字落 UserDefaults（`githubStarCount` / `githubStarCountFetchedAt`），之后开页先显示存量、后台再决定要不要更新，不会闪。
  - ⚠️ **新鲜度判据显式把"取数时间在未来"当过期**。这是同日 Last.fm 统计那个 bug 的反面教材：`fresh()` 只算 `now - fetchedAt < ttl`，时钟往回拨之后 `fetchedAt` 落在未来、差值恒为负恒判新鲜，数字就永远冻住只能手动刷新。这里宁可多发一次请求。
  - ⚠️ **匿名调用、不带任何凭据**（公开仓库），匿名配额每 IP 每小时 60 次，而 TTL 是 6 小时；403/429 时按响应头 `X-RateLimit-Reset` 退避而不是自己拍一个数。请求经 `NetworkAuditLog`（service `github` / operation `repo-stars`），是 App 侧第 7 个调用点。
  - 数字**不做 "1.2k" 缩写**：缩写会把 1200 和 1249 显示成同一个数，而这个角标唯一要传达的就是那个数；一整行只有它一个数字，写全也不挤（五位数约 40pt，标题列常见值不到 240pt / 整行 600pt）。角标带 `.fixedSize()`——`SettingsRow` 的三个可伸缩成员会均分剩余宽度，不钉住理想宽度可能被压掉一位（同 04 章决策 #15）。
- **关于页重排**（2026-09-03，用户原话「关于页面帮我 UI 重新设计一下」）：改版前是 hero 三件套 + 一张八行长卡（更新开关、外链、法律说明混在一起，没有分组标签）+ 一张两行卡 + 悬空的咖啡按钮 + 版权行，咖啡按钮和版权要滚到底才看得到。改成两层：**页头承担身份 + 首要动作**——图标 96pt 带软阴影、名字 24pt、**版本胶囊**（「版本 X · Apple Silicon/Intel」，点一下把「Lyrimuse X (架构) · macOS Y」拷进剪贴板并显示 1.6s「已复制版本信息」，反馈问题时最常被问的三样一次带齐）、tagline、两颗胶囊按钮（咖啡 glassProminent 橙色 / GitHub `.glass` 内嵌 star 数角标）、求 star 那句 11pt 三级色；**四张带 `SettingsCardHeader` 的卡**按意图分：更新 / 反馈与社区 / 许可与版权 / 诊断与数据，原来没有副标题的行（反馈问题、想法与建议）补一句说明去哪。新增「开源许可证」一行（开 GitHub 上的 LICENSE）。「检查更新」副标题走 `SparkleUpdaterManager.lastUpdateCheckDate`（转发 Sparkle 的 `SULastCheckTime`）：已查到新版本 → 与菜单栏面板同一套「有新版本 %@」/「%@ 已下载，点击安装」；否则「上次检查：<相对日期 + 时间>」（`DateFormatter` 用 `L10n.locale`，不用系统 Locale）；从没查过 → 「还没有检查过更新」。用 `SettingsPageCustomHeader` 而不是 `SettingsPage` 的 hero 三件套：那套只能摆图 + 标题 + 一句话。版权行改成「© 2026 Yudaotor · GPL-3.0」。**页头两侧的装饰层**（同日追加，用户原话「这两边的空白区域还可以加花吗」，`Settings/AboutHeroBackdrop.swift`）：hero 撑满卡片列宽后挂在 `.background`，两团取自 AppIcon 配色的柔光（粉 / 桃黄，半径 150 + 模糊 24，压在两侧偏上）加八个很淡的音符 / 歌词符号（SF Symbols，左四右四、位置大小不镜像），按各自周期 6–10s 上下浮 3–5pt。一个 `TimelineView(.animation, minimumInterval: 1/30)` 驱动全部符号、偏移是 sin(t) 纯函数，**不是**八个 `repeatForever` 各起一条；「减弱动态效果」开着时 timeline 暂停、符号静止。`allowsHitTesting(false)` + `accessibilityHidden`，不参与布局、不吃点击；符号钉 `en` locale（`text.alignleft` 这类文字造型符号带本地化变体）。
- **关于页「使用与版权说明」/「第三方许可」两行**（2026-09-03）：开源多源抓取项目的常规自保。前者副标题常显三句要点（版权归权利人 / 只做检索缓存展示 / 无隶属关系），「打开」按界面语言开 README 中文版或英文版的「许可与版权说明」一节（`LegalNoticeLinks.usageNoticeURL(language:)`，中文两档同一份；锚点是 GitHub 按标题生成的，**改那两个标题就把链接打断**——页面照常打开、只是不跳到那一节，肉眼看不出，selftest contracts 组有闸）。**正文不进 xcstrings**：这段话改的频率（加一个歌词源、换一个机翻后端、多一处对外请求）远高于发版，App 里抄一份就是第二个要同步的真源；对外请求全景表在第 01 章「许可、版权与对外请求」。后者打开包内 `Contents/Resources/THIRD_PARTY_LICENSES`：此前这个文件一直随包分发（BSD/MIT 分发条款要求随附），但 App 里没有任何入口能打开它，「随附了却找不到」等于没附；文件没有扩展名、LaunchServices 找不到默认打开方式，所以**直接指定 TextEdit**（`NSWorkspace.open(_:withApplicationAt:)`），`swift run` 这类没有包资源的开发态或 TextEdit 不在 / 打不开时退到 GitHub 上同一个文件。配套 CI 守卫 `scripts/check_third_party_licenses.py`：`Package.resolved` 每个 SPM 包、`build.sh` 里 `brew install` 进包的东西、`go.mod` 的 require 都必须在 THIRD_PARTY_LICENSES 里出现一次，忘补声明在 CI 红而不是发出去才被人指出来。
- **首启引导**（OnboardingView）：分步向导，每步直接绑定 AppSettings/FeatureSettingsStore **立即生效**（不做最后统一确认）；步数按所选播放器动态算（选 QQ 音乐则跳过 Apple Music 自动化权限步）；关窗=稍后再说（下次启动再问）。
  - **步骤序列**（2026-09-03 这一版）：`welcome`（欢迎 + 界面语言）→ `playerChoice` → `automation`（条件）→ `browserPairing`（条件）→ `background`（常驻服务 + 开机启动）→ `displayMode` → `lyricsExtras`（译文/罗马音）→ `lastfm` → `done`（体检清单）。最多 9 步，跟改动前持平——新增两步的同时把「语言」并进欢迎页、把「开机启动」并进后台服务那一步。
  - **「语言」不再是单独一步**：它原来排第 6，而前 5 步早就用错的语言讲完了。`L10n.t` 每次调用都重新解析语言（见 §6，刻意不缓存），所以在欢迎页一改，**从下一步起整个向导都是新语言**。并进欢迎页而不是单独排第 2 步，顺带治掉它"整页只有一个光秃秃 Picker、没有任何说明文字"这件事。窗口标题另加 `.navigationTitle(...)`——`App.swift` 里 `Window(L10n.t(…), id:)` 那个标题在 scene 构造时**只求值一次**，切语言不跟着变。
  - **欢迎页底部一句不阻断的告知**（2026-09-03）：「继续即表示你已了解 使用与版权说明」，链接与关于页那一行同一处（`LegalNotices.openUsageNotice`）。**刻意不做阻断式「接受」页**：引导原则是介绍性内容不锁下一步（跟 `.lastfm`/`.lyricsExtras` 同档），GPL 个人工具没有需要用户「接受」的条款，「接受版本号存偏好」那套是分发渠道场景的产物；一句告知 + 链接就是这件事在个人工具上的正确尺度。
  - **播放器那一步 2026-09-03 从单选改成多选**（用户原话「这个引导页面之前调整了播放器的多选逻辑这里没改过来」）。此前那里刻意留着单选、注释里写着"不是遗漏"（理由是"第一次装机一步到位更简单"），这条取舍被这次要求推翻。切换动作和「最后一个不能取消」那条非空不变量走 `FeatureSettingsStore.togglePlayer`——同日从 `SettingsView.toggleSelectedPlayer` 提上来，两个宿主共用一份（各写一遍就有两份判断会漂）。
  - 同日 **Apple Music 自动化那一步的判据从 `players == [.appleMusic]` 放宽成 `contains(.appleMusic)`**：多选之后"同时选了 Apple Music 和别的播放器"照样会走到那条 AppleScript 路径（`MediaControlClient.refinedAppleMusicSnapshotIfNeeded`），权限仍然需要。设置页的 `permissionCard` 2026-09-01 多选时就这么改了，引导页这次才跟上，两处口径统一。
  - ⚠️ 同日**再补一次：判据还要认 `.auto`**（`needsAppleMusicAutomation`）。`refinedAppleMusicSnapshotIfNeeded` 的第一道 guard 是 `bundleID == PlaybackPlayer.appleMusic.bundleIdentifier`，**完全不看 `features.players`**——只要在播的是 Music.app 就会走那条路；而 `features.players` 的默认值恰恰是 `[.auto]`。漏掉 `.auto` 的后果是"保持默认、平时听 Apple Music"的人走完整个引导都没被问过这个权限，然后一直用着进度不准、播放控制全按不动的版本。selftest 有闸。
  - **网格里多一格「YouTube Music」**（同日，用户要求）。它**不是** `PlaybackPlayer` 的 case，而是浏览器里的网页播放器（`BrowserPositionProbe.supportedPlatforms` 的 `youtubeMusic`），对应的状态是"配对了哪个浏览器"（`AppSettings.browserPlatformPairs`），不写进 `features.players`——硬塞成一个 `PlaybackPlayer` case 会让 bundleIdentifier / collector 侧的 playerXxx 常量 / `soleExplicitPlayer` 那一串全为它开特例。所以用单独的 `WebPlatformChoiceCard`，卡片外壳（`choiceCardChrome`）跟播放器卡共用一份，它们在同一网格里并排，长得不一样就会被当成两种控件。
  - **点它不会当场跳去选浏览器**：按用户要求（"选了之后先不进行选择浏览器，引导在后面选择浏览器"）另起一步 `.browserPairing`，排在 `.automation` 之后。选播放器那一步回答的是"你平时用什么听歌"，配哪个浏览器是下一个话题；塞在同一格里还会让网格在点击后突然长高。这一步**不锁下一步按钮**（跟 `.lastfm` 同一档：介绍 + 可选动作），也**不代劳授权**——`BrowserPairing.trustAndPair` 只在那个浏览器已经在跑时顺手问一次系统自动化授权，没在跑就留给用户之后处理，引导里不该为了"把流程走完"去后台拉起浏览器抢焦点。
  - 「YouTube Music」那一格的选中态**不持久化**，`onAppear` 按"这个平台配过浏览器没有"重新播种——真正落盘的是配对本身，存一个中间态只会多一个跟真实状态对不上的字段。⚠️ **取消勾选会把该平台的配对一起撤掉**：只翻布尔的话，格子看着没选、那一步也没了，可探针照 `browserPlatformPairs` 继续读 YouTube Music，而下次进引导 `onAppear` 又把格子点亮，用户会觉得取消没生效。这跟"不要替用户删配置"不冲突——那条针对的是程序自己顺手清理，这里是配置界面上的一次显式点击。取消**信任**不在这里做（那是另一件独立的显式动作）。
  - ⚠️ **`steps[step]` 是一处真会崩的越界，2026-09-03 修**。原来那条"结构性约束"的论证是"能让 steps 变短的控件全在 index 1，所以安全"——它默认**引导页是唯一宿主**，而 `features.players` 是 `@Published`，**设置窗口能同时开着改它**，引导页自己的 `.lastfm` 那一步还有个按钮专门去打开设置窗。失效路径：勾了 Apple Music → 走到最后一步 `.done`（index = count-1）→ 打开设置 → 播放器 tab 取消勾选 Apple Music → `steps` 少一项 → body 重算 → `steps[count]` 数组越界，**硬崩**。
    - 两道防线都要有：`currentStep`（`list[min(max(step,0), count-1)]`）保证**渲染这一刻**不越界（SwiftUI 重算 body 可能早于任何 onChange），`.onChange(of: steps.count)` 负责把 `step`/`furthestStep` 这两个**存储值**拉回合法区间（否则"上一步/下一步"的加减法会从一个非法下标继续往下算）。selftest 有闸禁止再出现裸 `steps[step]`。
    - "能改 steps 长度的控件尽量只留在 index 1"降级成**口味约束**（否则进度点会在脚下变长变短），不再是安全前提。
  - **「必需」的强度重估（2026-09-03）**。`automation` 那一步**从「下一步」那道锁里移出去了**，标题从「（必需）」改成「（推荐）」，正文那句"没有它，悬浮歌词完全没法显示任何内容"也一并改掉——那是**旧世界的说法**：接入 media-control 通道之前 Apple Music 确实只能靠 AppleScript 读，而现在基础的"在播什么"来自 collector 的 media-control 通道，这个权限管的是 `refinedAppleMusicSnapshotIfNeeded`（借一个更精确的 `elapsedTime`）加上 `MusicPlaybackController` 那一整套播放/资料库控制。多选之后更不合理：勾了 Apple Music + Spotify 的人被一个只对其中一个播放器有意义的权限挡在原地。2026-08-02 加那道锁治的是"误点不允许还能一路走完、`doneStep` 却说一切就绪"——**病根在那一页撒谎，不在按钮不够严**，改由体检清单如实报告（见下）。`collectorService` 那道锁保留（没有 collector 是真的什么都没有）。
  - **必需步骤被锁住时有出口**：底栏多一个次要按钮「暂时跳过」（`.buttonStyle(.link)`）。在此之前"仍然可以直接关掉整个引导窗口跳过"这句话**只存在于代码注释里**，用户看到的只有一个永远灰着的「下一步」。⚠️ 跟它配套：`finish()` 里 `hasCompletedOnboarding` **被 `collectorRunning` 守着**——那个标记一置真这扇窗口再也不会自动出现，而它是把 collector 装起来的主要入口，第 15 章 `--purge` 那一段记的那条不可自愈死路（服务没装 + 引导标记完成 = 桌面永久停在「搜索歌词中…」）正是这么形成的，「暂时跳过」等于给那条死路开了新的到达方式。跳过的人代价只是"下次启动再问一次"（跟直接关窗同一档），`doneStep` 会把这件事写在脸上。selftest 有闸。
  - **最后一步从"无条件一句「一切就绪」"改成体检清单**（`readinessItems` / `readinessRow`）：逐条列出这一轮真的走过的关键项（常驻服务 / Apple Music 权限 / YouTube Music 浏览器 / 歌词显示方式），红的那条带一个「去处理」直接跳回对应步骤；全绿才显示「一切就绪」，否则是「还差一点」。
    - ⚠️ **全绿时清单整条不出现，位置让给「你选的播放器」**（2026-09-03 用户要求「这个地方不要放着几个吧，放刚才选了的那些播放器」）：原来铺着四行清一色的绿勾，信息量约等于零。换成一排选中播放器的真图标 + 一行名字（`chosenPlayersStrip`，按 `PlaybackPlayer.displayOrder` 排，YouTube Music 单独接一张——它不是 `PlaybackPlayer` 的 case）。**清单本身没有被删掉**，只是改成只列没就绪的那几行：它是 `automation` 从「下一步」那道锁里移出去之后唯一如实报告缺什么的地方，整条删掉就又回到 2026-08-02 治过的那个病（误点「不允许」还能一路走完、这一页却无条件说「一切就绪」）。
    - 图标走新抽出来的 `PlayerIconView`（同日从 `PlayerChoiceCard` 里提出来）：那里既没有选中态也不能点，套不进 `PlayerChoiceCard`，而**三级兜底取图**（已装的真图标 → 随包品牌图 → 纯色块占位）照抄一份就是第二个漂移点——2026-09-02 用户报的「换一台没装全的机器，图标网格里一半 App 的图标看着都跟坏了一样」正是当时少了中间那一级。
    - 那排图标本身不带任何标签，名字那一行既是给眼睛看的说明、也是旁白唯一能读到的内容（尤其「自动识别」是一块没有文字的纯色占位）。
    - ⚠️ **图标行和名字行必须共用同一份有序数组 `chosenEntries`**（`ChosenEntry` = 播放器 case 或网页平台两选一）。第一版是两处各拼一遍（图标一个 `ForEach` + `if`，名字一个 `map` + 三元），顺序靠人肉对齐——当场就漂了：两处都把「自动识别」排在 YouTube Music **前面**，跟 `playerChoiceStep` 网格的顺序相反，用户当天就指出来（「自动识别和 youtubemusic 的顺序是不是应该换一下」）。两处顺序不一致时，用户会以为其中一处是错的。
    - 顺序与 `playerChoiceStep` 逐项一致：具体播放器（按 `PlaybackPlayer.displayOrder`，那份顺序本身按系统语言算）→ YouTube Music →「自动识别」垫底。`.auto` 同样从 `displayOrder` 里 filter 出来、不裸写——理由同网格那边：以后 `displayOrder` 不再收 `.auto` 时这里跟着自动消失。这一页同时补上**"这个 App 在哪"**——它是个没有 Dock 图标的菜单栏 App，点完「开始使用」窗口一关屏幕上什么都不会发生，所以图标位置、⌘+拖拽挪位置、快捷键去设置的「快捷键」里配，这一页自己讲一遍。
  - ⚠️ **首启那个"⌘+拖拽"气泡跟引导撞车，同日一并修**（`MenuBarStatusItem`）：时间线是 T+0.5s 弹引导窗口、T+1.5s 弹气泡、T+9.5s 气泡自动消失（`MenuBarPositionHint.autoDismissSeconds = 8`），而"决定要展示"这一刻就把 `hasShownMenuBarPositionHint` 置真了——这个**一辈子只出现一次**的提示，恰好在用户盯着引导读第一屏的时候在旁边闪 8 秒然后永久消失。判据加 `hasCompletedOnboarding`：引导没走完就**不置真、不展示**，留到下一次启动（那时用户已经认识这个图标，这句话才读得懂）。两条路互为兜底：引导的 `doneStep` 不依赖这个气泡交代"App 在菜单栏"。
  - **新增「译文与罗马音」一步**（`lyricsExtras`）：这是这个 App 对中日韩听众最核心的能力之一（设置里「歌词 → 译文/效果」整整两卡），此前引导里一个字都没提。跟 `.lastfm` 同一档：介绍性质、不锁下一步。⚠️ 只放 `showTranslation` / `showRomanization` **两个总开关**，不放"标注哪些语言"那一排——那几个走的是 `romanizationScripts` 的**双写**（AppSettings 持久化 + LocalPlaybackSource 让当前这首歌立刻重新解析），照抄一份等于给那条约束开第二个漂移点；`RomanizationScripts.default` 自 2026-08-29 起就是**四项全开**（日/韩/拼音/粤拼），细调留给设置页。⚠️ `AppSettings.init()` 里那条注释一度还停在旧值「日文/韩文开、中文关」上，引导页副标题照着它写就写错了（说"中文拼音、粤拼要去设置里另外打开"，实际默认开着），2026-09-03 一并改正——以 `RomanizationScripts.default` 的定义为准。
  - **`collectorService` 扩成 `background`**：同一页放「常驻后台服务（必需）」和「开机时自动启动 Lyrimuse（可选）」。两者回答的是同一个问题但**不是同一件事**：collector 是独立的 launchd job（KeepAlive，装上本来就开机自启），这个开关管的是 App 自己（`LoginItemManager`）。⚠️ 这条区别**刻意不写进界面文案**（2026-09-03 用户要求「去掉括号里面的文案」）——副标题后面原来挂着「（后台采集服务是独立的，装上之后本来就会开机自启）」，两行小字在 480pt 宽里撑出去了，而且它解释的是一个用户没问的区别（上面那张卡已经说清 collector 自己会常驻）。区别记在代码注释里，给改代码的人看。⚠️ 同批补上**启用失败的交代**：此前点了「启用」没起来是**全静默**的（图标停在红色「未运行」，没有原因、没有下一步，而这一步又锁着下一步），现在给一句文案 + 把 `LaunchdJobState.description` 那串固定英文诊断放进括号当线索。
  - **「配对浏览器」那一步补「从应用程序中选择…」**：此前引导页只铺得出 `knownBrowserBundleIDs` 里装了的那三个（Chrome / Edge / Safari），而 Brave / Vivaldi / Opera / Chromium 各分支、以及 2026-09-01 被有意拿出默认名单的 Arc 都驱得动——这批用户在引导里**完全走不通**。逻辑本体 `BrowserPairing.chooseFromApplications` 同日从 `SettingsView` 下沉（配对逻辑只允许一份），设置页那个同名方法改成转发。⚠️ 下沉时 `revealPairing` 回调**必须带上刚挑中的 bundleID**：跟 `trustAndPair` 那个无参版本不同，这条路上"配的是谁"要等文件选择器返回才知道，宿主拿不到就只能什么都不展开（设置页"配好后自动展开权限气泡"会静默失效）。顺带把空态文案里点名的 **Arc 去掉**——那跟"有意不默认展示 Arc"这条决定正好相反。
  - **选中态不再只靠颜色**（`ChoiceCardChrome`，两个宿主共用所以设置页一起受益）：右上角加一枚对号，两种选项卡都补 `.accessibilityAddTraits(.isSelected)`。原来"只用强调色描边+浅底、不额外叠对号"那条决定成立于**单选**时代（页面上永远只有一张亮的），改成多选之后要回答的问题变成"我到底勾了哪几个"，纯颜色差异在色觉障碍/「增强对比度」下整个失效，旁白用户则完全无从得知。
  - **`.lastfm` 那一步用真实品牌图标**（2026-09-03 用户要求）：`lastfmBadge(size: 44)`，跟设置页账号卡片 / 菜单栏面板底栏 / Dock 右键菜单同一张 `LastfmIcon.png`，不再拿 SF Symbol 的循环箭头凑数（素材来源与「为什么不设 isTemplate」见 `AccountLinkingTab.swift` 里 `lastfmBadgeImage` 的注释）。圆角走 `lastfmBadge` 默认的 `size * 0.22`，不另外指定——写死一个数只会让同一张图在引导页长得跟别处不一样。
  - **`doneStep` 有一句俏皮话**（2026-09-03 用户要求）：App 名 `Lyrimuse` = Lyric + Muse，收尾这一页是整个向导唯一适合把这个双关点破的地方（前面每一步都在讲权限/服务/开关，只有这里是"配完了，去听歌吧"）。全绿和没全绿各一句。⚠️ 文案里点名了「开始使用」这个按钮（英文 "Get Started"），改按钮文案要连它一起改，别让它指向一个不存在的按钮。
  - **进度指示补了三件事**：一个「第 N 步 / 共 M 步」的数字（最多 9 个点，光数点数不出来）、走过的点可以点回去（只允许回到 `furthestStep` 以内——往前跳会绕过必需步骤那道锁，而 `furthestStep` 只由「下一步」/「暂时跳过」推进）、整块合成一个无障碍元素并报出"第 N 步，共 M 步"。
  - **内容区套了一层 `ScrollView` + `.scrollBounceBehavior(.basedOnSize)` 兜底**：窗口固定 480×420 且不可拖拽，此前内容超出就是**静默裁切**（既不滚动也不撑大窗口），最坏情况是英文界面（同句普遍比中文多占一到两行）叠上「辅助功能 → 更大文字」。⚠️ 这层只是"预算算错时用户还够得着下面的东西"，各步骤自己的高度预算（尤其 `displayModeStep` 那两条互斥提示）照旧要守，不是把预算作废。
- **配对逻辑只有一份**（2026-09-03）：`Settings/BrowserPairing.swift`。设置页「网页播放器」卡和引导页「配对浏览器」那一步都调它，设置页原来那几个同名 private 方法改成转发。抽出来不是为了"整理代码"——`trustAndPair` 的函数体里那四步**顺序**本身就是好几轮实测结论（配对先写、信任后跑、引擎族要在配对之前落盘、气泡必须让出一拍再开），引导页照抄一份就等于给这些约束开第二个漂移点。宿主各自的 UI 反应（设置页要展开权限气泡、刷新同步现读的权限状态）通过两个回调传进去。同批把网页平台图标从 `SettingsView` 里那个 **private** `PlayerSettingsTab` 整块搬到 `Settings/WebPlatformIcon.swift`（`WebPlatformIcon.image(_:)`）——一度想只把查表函数放开成 internal，行不通：`youtubeMusicIcon` 依赖同文件里的 `whiteFilledCutouts`（垫白那一步），拆开会把"这张图该长什么样"劈成两处。
  - selftest 上了机械闸（`引导页一份实现` 那一组）：两个宿主都不准直接改 `features.players`、引导页必须走 `BrowserPairing.trustAndPair` 且不准自己碰 `browserPlatformPairs`、设置页那**七**条转发都得在（同日多了 `chooseFromApplications`）、平台→图标那张查表只允许一份、引导页 `unpair` 只允许一处、浏览器候选必须是一份稳定列表。
  - 2026-09-03 这一批又加了七条：不准出现裸 `steps[step]`（且 `currentStep` / `onChange(of: steps.count)` 必须在）、`needsAppleMusicAutomation` 必须同时认 `.appleMusic` 和 `.auto`、`automation` 不准回到 `nextIsLocked`、`finish()` 里 `hasCompletedOnboarding` 必须被 `collectorRunning` 守着、`readinessItems` 必须在、引导页必须有 `BrowserPairing.chooseFromApplications`、`MenuBarStatusItem` 那个位置提示分支必须判 `hasCompletedOnboarding`。

### 6. 本地化（L10n）

- 简体 / 繁体 / 英文三档（繁体 2026-09-03 加，借鉴清单 #10；此前只有中/英两档）。系统语言标签 → 语言包目录名的规则在 LyrimuseCore `Util/UILanguage.swift`（selftest 钉着 zh-Hant-TW / zh-HK / zh-Hans-HK / 裸 zh / en-GB / ja 的分流：含 hans 一定简体、含 hant 一定繁体，都没写才看 -TW/-HK/-MO 地区码；`AppSettings.userReadsSimplifiedChinese` 复用同一份），`L10n.resolveSystem` 只是转发。**新加文案必须三语齐全**（2026-09-03 用户定，写进 AGENTS.md「本地化」与 CLAUDE.md 第 5 条）：`generate-strings.py` 对 en / zh-Hant 缺译都直接失败并列出键（`FALLBACK_TO_SOURCE` 留着机制但为空——加繁体那天短暂开过，译文齐了就关），`check_strings_parity.py` 直接查 catalog 每键是否有 en 与 zh-Hant 并核三份表 key 集一致，selftest 本地化守卫对缺 zh-Hant 的键红；繁体写法规范在 `Localization/zh-Hant-STYLE.md`（术语表 + 三种「恢复」这类词义分叉 + 字级细节）；1196 条繁体译文按台湾软件用语翻（术语以本机 macOS zh_TW 语言包挖出的 Apple 官方简繁平行词条为准：設定 / 一般 / 選單列 / 快速鍵 / 預設 / 登入 / 網路 / 視窗 / 檔案夾 / 拷貝 / 貼上 / 搜尋 / 結束 / 動態島 / 瀏海），品牌与 URL 锚点保持原文。**不用** SwiftUI 自动语言协商——SwiftPM 纯 `swift build` 打包会把 `zh-Hans.lproj` 目录名强制小写，Apple 的协商精确匹配大小写导致永远落到 en；`L10n.t()` 自己读 `Locale.preferredLanguages`（`np:appLanguage` 可手动覆盖，运行期切换即时生效）定位 `.lproj` 手查。查找起点 `Bundle.main`（`Bundle.module` 在别人机器上会 fatalError）。
- **工作流**：改 `Localization/Localizable.xcstrings`（唯一真源，JSON：sort_keys/indent2/`': '` 分隔）→ 跑 `python3 Localization/generate-strings.py` → 两份 `.strings` 生成物一起入库。selftest 有双向一致性守卫。生成物入库是因为 xcstringstool 只在完整 Xcode 里。
- UI 文案约定：不加句尾句号。
- 设置页组件的选用顺序（SettingsPage → SettingsCard → SettingsRow → SettingsSubRow → SettingsNote → SettingsRawRow，不写裸 Toggle/Picker/Form）与 macOS 26 API 的 `#available` 门控规则 2026-09-03 成文在 AGENTS.md「分层边界」，理由仍只在 `SettingsDesignSystem.swift` 头注；selftest contracts 组「玻璃门控」守着：液态玻璃 API 的调用点只准在 SettingsDesignSystem / LyricsOverlayView 两个文件里，且文件必须含那句 `#available`。

### 7. 诊断导出（DiagnosticsExporter）

汇总 collector 日志（`~/Library/Logs/lyrimuse.log`）+ App 系统日志 + App 进程 stderr（`lyrimuse-app.log` 最后 100 行，2026-09-05 加，正常应几乎为空，能落进来的只有运行时 fatal / 子进程漏出的 stderr）+ 关键状态（权限/服务/各功能是否已配置）+ **播放时钟**成一份文本，设计给贴公开 issue。

**播放时钟段（2026-08-22 加）**：`positionSourceTier` / 伺服误差 EMA / `posReportedBiasSecs` / 锚点的 rate·fresh·年龄 / 生效歌词偏移与其中来自 LRC `[offset:]` 的那一层 / `currentLineFillSettled`。数据源是 `LocalPlaybackSource.clockSnapshot`（只读快照，全是内存里已有的字段，零热路径成本；刻意不做成 `@Published`——诊断导出是"点一下读一次"，发布属性会让每次伺服调整都推着订阅者重渲染）。
加它的理由：「歌词慢半拍」是最常被报也最难复现的一类问题，而它至少有四种成因、修法完全不同——帧率掉了 / tier 判错 / 伺服在反复 snap / 自然切歌偏置估歪。此前报告里没有任何一项能把这四种区分开。这一段不含任何用户内容（没有曲名/歌手/歌词），天然不需要过 `LogRedactor`。

**对外请求审计日志（2026-08-26 加）**：用户明确要求"所有软件发出的对外请求全部都给我记录下日志"之后补的一整条能力，两侧各有一个统一出口——App 侧 `LyrimuseCore/Diagnostics/NetworkAuditLog.swift`（7 个 `URLSession` 调用点：`LastfmStatsService.request`/`LastfmAuthFlow` 两处/`ListenBrainzTokenCheck.validate`/`CachedImage.load`/`MusicCatalogSearch` 两处/`GitHubStarsService.fetch`（2026-09-03 加，关于页 star 数），各自调一次）；collector 侧是既有的 `networkobs.go` `doHTTPTracked`（原来只累加"网络通不通"的原子计数器，这次扩成同时写审计日志，十几个原本没接进这个出口的调用点——`lastfm.go`/`lastfmcollapse.go`/`backfill.go`/`lb.go`/`alerter.go`/`relay.go`/`weekly.go`/`digest.go`/`topartists.go`/`translate.go`/`color.go`/`musicbrainz.go`/`apple.go`/`amllttml.go`——一并接进来）。每条日志只记方法+host+path(+Last.fm 的 `method` 参数,它标识调用的哪个接口、不是凭据)+状态码/错误+耗时，**故意不带 query string**——凭据就是拼在 query string/path 里的，从源头不记录比"记了再指望 `LogRedactor`/collector 侧 `logscrub.go` 兜底"更彻底(两道现有脱敏机制仍然保留、继续保护其它已存在的、可能带 URL 的旧日志正文，不是被这个新出口取代)。App 侧新分类叫 `network-audit`(跟 `lastfm-stats`/`lastfm-connect` 等分开)，`recentAppLogLines()` 按 subsystem 查询、自动收进导出报告，不用额外接线。**2026-09-05 起 collector 侧按分钟聚合**（用户拍板）：逐次成功行降到 Debug（默认不落盘，`log_level=debug` 可见），落盘的是每个 target（方法 + host + path + Last.fm `method`）一分钟一行的 `api call summary target=… count= failed= p50_ms= max_ms= span_s=`（networkobs.go `recordAPICall` / `flushAPICallSummaries`，维护循环每 30 秒结算满一分钟的窗口，退出前全部结算），失败（传输错误 / HTTP 4xx-5xx）仍逐条 Warn。「全部记录」由汇总里的 count 兑现——两天日志里 63% 是逐次审计行、Last.fm 每 5 秒一次的轮询一项就 4219 行，一行一次已经把别的信号淹掉了。App 侧 `network-audit` 不变（量级小一个数量级，且每条都由用户动作触发）。

刻意排除在外的两类：DNS-over-HTTPS 查询(`doh.go`，那是给别的请求解析域名用的基础设施调用，不是"联系了哪个外部服务"，跟 `networkLooksDown()` 的既有统计口径一致)；App 自动更新检查(Sparkle 框架，请求整个发生在框架内部，拿不到方法/网址/状态码/耗时这些细粒度信息，只能挂一个粗粒度生命周期回调，价值跟其它请求不对等，需要时再补)。

**2026-08-27 这一轮：从"至少别泄密"扩成"真的能靠这一份文件排查问题"**。起因是拿一份真实导出（3254 行）回头核对，坐实了几个问题，逐条修：

- **App Log 里的时间戳跟 Collector Log 对不上表**：前者是 `os.Logger`，显式 `+0000`（UTC）；后者是 Go `log.LstdFlags` 打的本地墙钟、不带任何时区标记——实测这台机器上两段日志相差整整 8 小时。修法是 collector 侧 `main.go` 加 `log.LUTC`，两边统一到 UTC；两个段落标题也都显式写明 `UTC`，不用读的人自己心算。**2026-09-05 再改**：collector 换 `log/slog` 后行首是 `time=2026-09-05T00:00:00.000Z`（显式 Z），不再靠读的人记住「这是 UTC」（LUTC 那版没有任何标记，当天就有人把 `15:49` 读成了本地时间）；导出解析走 Core `CollectorLogLine.timestamp(of:)`，新老两种格式都认、都按 UTC 解（selftest ops-diagnostics 组钉着）。
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

- UserDefaults：`np:*`（AppSettings + 各处 @AppStorage）、`KeyboardShortcuts_*`；另有 `settings:*`（设置页的停留位置：顶层分类 `settings:lastTab`、二级分段 `settings:lyricsSection` / `settings:appearanceSection`）——机器状态，刻意不在配置导出的前缀里。
- `~/.config/lyrimuse/`：`config.json`（账号凭据，ConfigStore）、`lyrimuse-features.json`、App 偏好镜像 JSON、enrich 缓存等（清单见第 01 章）。损坏文件被用户「放弃」后留在同目录，名为 `<原名>.corrupt-<yyyyMMdd-HHmmss>`（不自动清理；uninstall.sh `--purge` 连目录一起删）。
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
| 顺序优先列表拖拽排序 | LyricsSettingsTab（SettingsView.swift `priorityRow` / `priorityDragGesture` / `SourceDragState` / `PrioritySourceFramesKey`、`moveEnabledSource` 箭头通路）、LyrimuseCore/Util/ReorderDrag.swift（`targetIndex` / `displacement` / `clampedTranslation` / `moved`），selftest settings-ui 组 |
| 凭据存储 / 共享配置文件读写 | Settings/ConfigStore.swift、Settings/FeatureSettingsStore.swift、LyrimuseCore/Util/JSONConfigDocument.swift（三态 `load` / `merging` / `save` / `markCorrupt` / `quarantineCorruptFile`）、Settings/ConfigFileDamageBanner.swift（损坏横幅，挂 SettingsView detail 列 `safeAreaInset`）、LyrimuseCore/Util/SecretFileWrite.swift |
| 开机启动 | Settings/LoginItemManager.swift |
| 更新 | Settings/SparkleUpdaterManager.swift |
| 引导 | lyrimuse/OnboardingView.swift |
| 本地化 | lyrimuse/L10n.swift、LyrimuseCore/Util/UILanguage.swift（语言协商）、Localization/generate-strings.py、Localizable.xcstrings、Resources/{zh-hans,zh-hant,en}.lproj |
| 诊断 | Settings/DiagnosticsExporter.swift（`collapseRepeatedLines`/`collectorHealthCheckLines`/`currentTrackLyricsLines`/`recentCollectorLogLines`）、LyrimuseCore/Diagnostics/LogRedactor.swift；时区对齐见 collector 侧 main.go `log.LUTC`；App 版本号见 build.sh `APP_VERSION` |
| 歌词来源可用性测试（2026-08-30） | Settings/LyricSourceTestService.swift；SettingsView.swift `sourceTestAccessory`/`testSource`/`testAllSources`/`testAllSourcesButton`（悬停提示走自绘 `.popover` + `accessoryHoverSource`，不是 `.help()`，理由见「设计决策」）；`SettingsCardHeader` 的 `trailing` 插槽；collector 侧 lyrimuse-collector/testlyricsourcescli.go（`collector test-lyric-sources [-source <name>]`），跟 healthcheckcli.go 共享同一套两首探测曲思路；具体失败原因旁路见 ytmusic.go/musixmatch.go/netease.go 各自的 `*LastFailureReason` |
| 对外请求审计 | LyrimuseCore/Diagnostics/NetworkAuditLog.swift（App 侧 7 个调用点）；collector 侧见第 15 章「网络观察」 |
| 关于页 GitHub star 数（2026-09-03） | Settings/GitHubStarsService.swift（单例 + URLSession + UserDefaults 缓存）；纯判据 LyrimuseCore/Util/GitHubStars.swift（TTL/退避/解析，selftest `ops-diagnostics` 组 15 条断言）；角标视图 SettingsView.swift `GitHubStarsBadge`，取数触发在 `AboutSettingsTab` 的 `.task` |
| 使用与版权说明 / 第三方许可（2026-09-03） | Settings/LegalNotices.swift（打开动作：README 一节 / 包内 THIRD_PARTY_LICENSES 走 TextEdit、兜底 GitHub）；纯判据 LyrimuseCore/Util/LegalNoticeLinks.swift（按语言选 README 与锚点）；关于页两行 SettingsView.swift `AboutSettingsTab`；引导欢迎页 OnboardingView.swift `welcomeStep`；CI 守卫 scripts/check_third_party_licenses.py；selftest `contracts` 组「版权说明」断言 |
| 诊断用探针（生命周期） | 滚轮兜底转发 `AppDelegate.forwardScrollIfStranded`（继续保留）；同批曾经的诊断探针 `logScrollProbe` 已于 2026-08-27 删除，见「设计决策」 |

- ⚠️ **滚轮兜底转发必须缓存它那次判定，否则滚动会卡到整个 App 无响应**（2026-09-02，真机 `sample` 抓栈坐实）。`forwardScrollIfStranded` 装在**全局滚轮监视器**里，每个滚轮事件都要先跑一句 `root?.hitTest(loc)` 判断"这一下本来有没有人会处理" —— 而抓到的主线程栈显示它下面是一整条 `-[NSThemeFrame _performHitTestForContext:]` → `NSHostingView.hitTest` → `PlatformHitTestingManager.hitTest` → `MultiViewResponder.containsGlobalPoints` 的**深度递归**，等于把整个窗口的 SwiftUI 视图树走一遍。触控板惯性滚动每秒发几十到上百个事件 → 每秒几十到上百次全窗口递归命中测试压在主线程上。那份 sample 里这个函数占了主线程 **74/1439 个采样**。
  - **用户报的现象**：「设置页 Last.fm 那一段往下滑就卡，严重时整个 App 无响应要强制退出」，两台机器都遇到。
  - ⚠️ **排查时一路怀疑 Last.fm 的数据链路（冷缓存、逐行播放次数请求、封面三级兜底、简繁写法索引…），全部是错的方向。** 这跟 Last.fm 一点关系都没有，是个**全局的、任何窗口任何页面都在付的成本**，只是那一页最长最深、把它放大到了看得见。**下次再遇到"某一页滑动卡"，先抓栈，别顺着那一页的数据层查。**
  - 修法不动判定逻辑本身，只是不再每个事件都重算：滚动手势期间指针本来就不动，判一次就够。复用条件（同窗口 + 指针没挪出 4pt + 未超 0.25s）下沉成纯函数 `LyrimuseCore.ScrollForwardDecision.canReuse`，selftest 四条断言钉住三个"必须重算"的场景。
  - ⚠️ 这只降低了**频率**，没有消除单次命中测试本身的开销。如果某页仍有卡顿感，那是那一页视图层级太深，是另一个问题。

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

- **三个歌词形态的「重置」与「全部设置」抽屉,加了两条 selftest 守卫钉住(2026-09-03,三形态设置完整性审计)**:一天之内在**同一类疏漏**上栽了三次——菜单栏「重置」漏了「歌词旁的图标」和「悬停显示播放控制」、灵动岛「重置」漏了两个自动隐藏开关(都是设置项加进浮层时没同步 `restoreDefaults()`)、灵动岛和菜单栏的抽屉各漏了一行「重置」兜底入口(只有悬浮歌词有)。这类漏**不会报错**,表现只是"点了重置有一项没变"/"键盘用户够不到重置",用户很难判断是漏了还是本来就不该变。
    - **闸一「重置覆盖闸」**:每个 `AppSettings.defaultNotchXxx` / `defaultMenuBarXxx` 常量都必须在对应的 `restoreDefaults()` 里被赋值。依据是仓库既有纪律"进重置范围的项必须有命名常量"(init() 兜底和重置读同一份),反过来即"有常量就该在重置里";2026-09-03 实测 30 个常量 0 例外。⚠️ 只覆盖 Notch / MenuBar 两族——悬浮歌词的常量不带形态前缀、且有几项默认值来自 `ColorTheme.defaultTheme` 而非常量,按名字归类只能靠猜,与其写一条似是而非的闸不如不写。守卫留了一个**目前为空**的豁免名单,将来真有"有常量但故意不进重置"的项时加进去并写明理由。
    - **闸二「抽屉重置闸」**:三个形态的「全部设置」抽屉都必须有 `resetRow`(定义 + 装配都要有,只定义不装配等于没有)。抽屉的定位是**键盘 / VoiceOver 的全量兜底通路**,工具栏那颗 SwiftUI `Menu` 不能算数。
    - ⚠️ 闸一扫的是 **`restoreDefaults()` 的函数体**(大括号配平截出)并**剔掉整行注释**,不是整文件扫——那两个文件的注释里都写着"默认值只在 `AppSettings.defaultMenuBarXxx` 里出现一次"这类句子,整文件扫会把注释当赋值放过去(同 L10n / 滑杆两条守卫吃过的"纯文本扫描不区分代码与注释"的亏)。
    - **验证**:两条都做了反向验证——故意重演当天那两个真实疏漏(删掉灵动岛重置里刚补的那行、删掉菜单栏抽屉的 `resetRow` 装配),对应的闸各自当场 `FAIL`;还原后两个文件 sha256 与突变前逐字节一致,全量 `ALL PASS`。

- **所有量化滑杆统一走 `SteppedSlider`，不许再把步长传给原生 `Slider`（2026-09-02，用户："那些虚线点都移除掉，没有意义，不好看"）**：macOS 的 SwiftUI `Slider` 一旦拿到步长入参，就会在轨道下面画一排刻度点，**关不掉**——没有对应修饰符，底层也不是 `NSSlider` 包出来的（`OverlayEditorStage` 里记着那次 `NSHostingView` 子树 dump：递归下去只有 `KeyViewProxy` / `_FocusRingView`），拿不到 `numberOfTickMarks` 去清零。唯一的办法是别传那个入参、量化改在 `Binding` 的 `set` 里做。

    这是**第二次**修同一个观感问题：2026-08-31 用户报的是悬浮歌词宽度条那一根（"为什么这里灰色条下面还有一条纯白的？"——300…1400／步长 2 是 550 个点，密到连成一条实线），当时在那一处就地展开；一天之后新写的滑杆又把刻度点带了回来，这次一口气有五处（字号／悬浮宽度／灵动岛宽度／菜单栏最大宽度／菜单栏快捷面板那根共用的 `sliderRow`）。所以这次不是再改五处，而是：① 把写法收进 `SettingsDesignSystem.swift` 的 `SteppedSlider`（签名跟原生带步长的构造器一模一样，调用点只换类型名）；② selftest 加一条源码扫描守卫（搜「滑杆刻度」），扫 `Sources/lyrimuse` 里所有对原生 `Slider` 的**直接**调用，第一层参数区出现步长标签就红。

    ⚠️ 量化语义**逐位对齐原生、没有任何刻意偏差**——这次改的目的就是"外观少一排点、行为一个字不变"，落值只要不一样就是给用户凭空制造一次"我调好的值自己变了"。两条：栅格**锚在 `range.lowerBound`** 不是锚在 0（灵动岛那根的下界是这台机器的"耳朵下限"、是个任意数，锚错了所有落值整体偏移）；区间长度不是步长整数倍时**上界够不到**，最大只到最后一个整格（263.5…1187／步长 10 拖到底是 1183.5 不是 1187）。第二条一度被注释写反成"能拖到真正的最大值"，是数值对拍脚本当场打脸才发现的——先夹后量化自然就是这个结果，别照直觉改顺序。

    ⚠️ 守卫是**纯文本扫描**，不区分代码和注释（同 L10n 那条守卫的盲区）。注释里提到"带步长的那个构造器"用中文描述，别把那句调用整句写全。只看**第一层**参数区，所以嵌套调用里的同名参数标签（`SteppedSlider` 自己 body 里那句 `snap` 调用）不会让它自己判红。

    **验证**：`swift build` 无新错误/警告；selftest `ALL PASS`，并做了反向验证——把其中一处换回原生带步长的写法，「滑杆刻度」那条当场 `FAIL`，改回来恢复 `ALL PASS`。观感本身用 `ImageRenderer` 离线渲染对拍（**不驱动 UI**，符合验证纪律）：同区间、同步长、同当前值，原生那根轨道下面一排点、`SteppedSlider` 干净。量化语义另跑一份数值对拍，四个真实区间各扫全程（含越界、非整格步进、幂等、`step <= 0` 防呆）全绿。

17. **侧栏「播放器」项加警告徽标——「侧栏不加状态小字」决定的唯一例外（2026-09-03，用户拍板，借鉴清单 #54）**：
    `sidebarLabel` 头注的原话是"这几个纯设置分类没有对应的状态"，对「播放器」不成立：页面里本来就维护着
    四个异常态（自动化权限 / collector 运行态 / collector 版本一致性 / 通知权限），只是全是页面私有
    `@State`、只在停在那一页时每 2s 刷新——停在「歌词」页或别的页时 collector 挂了没有任何地方能看见。
    徽标不是小字，和账号行「连没连上」、菜单栏面板 Last.fm 出错换橙色三角是同一类"有真实状态才显示"。
    **判定收得很窄**（`LyrimuseCore/Diagnostics/PlayerHealth.swift`，selftest 6 条钉住）：只认两条会让歌词
    直接停摆的硬故障——已选播放器含 Apple Music 且权限被系统记为拒绝（播放器没开时查询返回 notDetermined
    而非 denied，天然不误报）；「后台采集服务」开关开着而 launchd 里没有活着的进程（用户自己关掉不算）。
    版本不一致（要起 collector 子进程）与通知权限（不是播放器健康）刻意不进。数据源 `Settings/PlayerHealthMonitor.swift`：
    `SettingsView` 的 onAppear/onDisappear 启停，`askIfNeeded: false` 绝不弹窗，`launchctl print` 丢后台线程、
    同一时刻最多一次在飞；文案两条走 xcstrings。**边界**：设置窗口关着时依然没人知道 collector 挂了，这条只
    覆盖"窗口开着但停在别的页"，真正的兜底要在菜单栏图标/面板上做（另一条）。验证：selftest；真机上权限被拒
    制造不出来、也不用停服务来演示，靠用户日常"平时不亮、出事亮"。
    ⚠️ **头注里原写「AE 权限查询微秒级」是错的**，见第 18 条——那一查在主线程同步阻塞 3–48ms，同日改到后台。

18. **「播放器」页 body 里嵌着同步跨进程调用——设置页「切分页有延迟、不跟手」的真因（2026-09-03，真机 `sample` 抓栈）**：
    用户报「就光是在这里几个切换就有时候卡卡的，不是瞬间就过去了，有个延迟」。三份主线程采样对照（基线设置窗关着 80% 空转 /
    开着不动 71% / **来回切分页 60s 只剩 30% 空转**），忙的部分几乎全在 `PlayerSettingsTab` 的 view body 里，而且不是算得慢，
    是**在等别的进程回话**：
    - `browserAvatarButton` → overlay 里 `browserSetupIncomplete` → `MusicAutomationPermission.check(bundleID:askIfNeeded:false)`
      → `AEDeterminePermissionToAutomateTarget` → `semaphore_wait_trap`（跨进程问 tccd）。独立 Swift 脚本量 10 次：**min 3.3ms /
      中位 4.2ms / 首次 47.5ms**。用户配了 4 个浏览器、每个平台卡片各画一遍 → 每次 body 重算 4–8 次 IPC，主线程阻塞 20–380ms。
      同一路径 `browserJSLikelyWorking` → `BrowserAutomationPermission.status` 在 body 里**读 Chromium Preferences 文件**。
      60s 采样里这条路径 524 个采样。
    - `collectorCard` 的 2s 心跳 → `refreshCollectorState` → `CollectorServiceManager.state` → **`NSTask.waitUntilExit`**：在主线程起
      `launchctl print` 并同步等它退出，等的时候 runloop 被拉进去嵌套跑 SwiftUI 事务（采样里 `waitUntilExit` 底下叠着
      `GraphHost.flushTransactions`）。154 个采样。
    - **为什么 body 重算得那么频繁**：这页 `@ObservedObject` 整对象订阅了 `AppSettings.shared`（几十个 `@Published`）、
      `FeatureSettingsStore.shared`、`MediaControlHealth.shared` 三个单例，实读只有九个字段——任何一个字段动一下整页重算，
      加上自己 2s 一拍改 `collectorState`，停在这页每 2 秒必重算。
    - `PlayerHealthMonitor`（第 17 条，同日加）在**任何分页**每 2s 在主线程同步跑一次同款 AE 查询：设置窗开着 60s 内 116 个采样，
      关着时 0 个。2s 一次的阻塞撞上点击那一下就是一帧掉帧，撞不上就顺滑——正好对应「**有时候**卡」。
    **修法都是"查在后台、画只读缓存"，不改任何功能**：①`refreshBrowserLiveStatus` 把三样实时状态（JS 开关 / 在跑 / TCC 授权）
    一次性在 `Task.detached` 里查完、回主线程写进 `@State browserLiveStatus`，body 里三处判定只读缓存；触发点 = 进页 / 2s 心跳
    / 切回 App / 请求过授权（`automationRefreshTick` 改成 onChange 触发重查，此前它的语义是"强制 body 同步现读"）/ 配对表变化，
    同一时刻最多一次在飞；还没查回来时角标先不亮（第一帧亮一下再灭是最难看的闪烁）。②`refreshCollectorState` /
    `refreshAutomationStatus` / `PlayerHealthMonitor.refresh` 里的跨进程查询全部下到 `Task.detached`。③三个整对象订阅换成
    窄代理 `PlayerTabStores`（机制同 `OverlayPlayback`/`PanelPlayback`，2026-08-19 那轮四个展示面都做了、设置页是漏网的）：
    只转发九个实读字段并 removeDuplicates，写不经过代理（直接写 `AppSettings.shared` / 调 `FeatureSettingsStore.shared`），
    `launchMusicOnLyrimuseOpen` 那颗 Toggle 用代理暴露的 Binding。**闸**：selftest `contracts` 组「设置页 IPC 闸」——
    `SettingsView.swift` / `PlayerHealthMonitor.swift` 里 `MusicAutomationPermission.check(` / `BrowserAutomationPermission.status(`
    / `CollectorServiceManager.state|isRunning` 只许出现在白名单 refresh 函数内、且从 func 到调用行之间必须有 `Task.detached`；
    注释行不算。⚠️ 排查教训同第 13 条那次滚轮卡顿：**先抓栈，别顺着"这一页数据多"猜**——两次都是 `sample` 一眼看到
    `semaphore_wait_trap`/`waitUntilExit` 才定的根因；前两次采样里一次点击都没有（用户还在读消息、App 又被别的会话 build.sh
    重启关了窗），必须核对栈里真有事件分发（这台系统上事件在 `_DPSNextEvent` **内部**经 HIToolbox 分发，`sendEvent:` 不会出现，
    别拿它当"有没有点击"的判据）。

19. **加载失败的配置文件拒绝保存、坏文件不覆盖；写失败不污染内存——两条路径下沉 Core 进 selftest（2026-09-05，用户拍板，借鉴清单 #46）**：
    起因是核实清单时把 `ConfigStore.load()` 那条「文件不存在/解析失败——理论上不会发生」的注释追到底：它把两件事混成一回事，
    都落成空字典 + 14 个空字段，且没有任何失败标记；`persistFile()` 无条件把 14 个字段写回。于是 config.json 一个 JSON 语法错误
    （手改 / 搬家 / 导入）之后，启动显示各账号为空，用户在任意一栏输入、点一次「断开 Last.fm」、或 Last.fm 授权成功（后两条**不看
    `isDirty`**，比清单说的「用户输入」多两条触发路径），就用一整套空串覆盖原文件——Last.fm session key / ListenBrainz token /
    relay token 全丢，连 `api_root`/`log_level` 这些 UI 不管的字段也一起丢（`raw` 已被清空）。`FeatureSettingsStore` 同病：坏文件退
    默认值，任意一个开关点一下就把默认值写回去，`unknownFileKeys` 也清空。collector 侧逐字段解、八个子命令全部只读，风险只在 Swift。
    **做法**：纯逻辑抽成 Core `JSONConfigDocument`（三态 `load` / `merging` / `save` / `markCorrupt` / `quarantineCorruptFile`），两个
    Store 只剩 `@MainActor` 外壳、字段映射、文案；`loadFailure` + `ConfigFileDamageBanner` + `discardCorruptFileAndSave()` 三件套
    给出口。**三个取舍**：① 「损坏」只看**文件层**（不是 JSON 对象）和 features 的**类型层**（按类型解不出），不做 Go 那种逐字段
    容错——逐字段容错会让「一个字段坏了」静默变成「那个字段回默认值然后被写回」，跟这条决策要杜绝的事是同一形状；宁可拒绝 + 让用户
    看见。② 拒绝保存必须配出口，否则真想覆盖坏文件的人被卡死：出口是**改名保留**不是删除（坏文件里往往还有能手工抢救的凭据），
    时间戳后缀、同名再加计数，不自动清理。③ 「拒绝」和「写失败」在 lastError 里分开报——前者磁盘一个字节没碰、是保护动作，文案不该
    说成「失败」。**刻意不拦的**：`ConfigPortability.importData` 直接 `writeSecurely` 覆盖 config.json——导入本身就是「用一份完整配置
    覆盖」，是用户明确要的；它随后 `restartApp()`，Store 重新走一遍三态。**顺带**：诊断导出 State 段多两行三态；写盘顺序钉死为
    「成功后才更新镜像」（原来先改 `raw` 再写，只是写缓冲没造成实害，但一旦被当成「内存已同步」就是坑）；features.json 从此总是
    带缩进、键排序写出（原来没有未知键时是紧凑一行），collector 解析不受影响。**验证**：selftest ops-diagnostics「配置文件三态读写」
    47 条（真实临时目录：坏 JSON / 顶层数组 / 空文件 / 路径是目录 → 拒绝且字节不变、权限位不动；父目录不存在 / 目标是目录 / 非 JSON
    类型 → 写失败字典与状态不变；隔离件字节原样、同名不覆盖、之后能重建），contracts 组 21 条扫两个 Store 不许自己 `Data(contentsOf:)`
    / `write(to:)`。**没验的**：真机没有故意弄坏用户自己的 config.json——那正是这条要保护的文件；横幅与出口只靠源码守卫与编译通过，
    界面形态待真出事时再校。⚠️ 已知未覆盖：App 运行期间用户手改 config.json，下次自动保存仍以内存镜像为准覆盖（读盘只在启动时一次），
    跟以前一样。

20. **「顺序优先」列表改把手拖拽排序，上下箭头留作键盘 / VoiceOver 兜底（2026-09-05，用户拍板，借鉴清单 #53）**：
    列表最多 9 行，箭头挪 6→1 要点 5 次、写 5 次盘（0.5s 去抖内连点只重启一次，停顿就多一次）；拖拽一次 move 一次 save。
    算法全部在 Core `ReorderDrag`（selftest settings-ui 组 40 条）：① `targetIndex` 滞回——被拖行**中线**越过邻行中线再多 6pt 才换位、
    换位后回抖 6pt 内不退，形成 2h 死区；一帧可连越多行但只朝一个方向；② `displacement` 让位挪的是**槛距**（到相邻行原中线）
    不是行高——行间有 1pt 分隔线，按行高挪越挪越歪；③ `moved` 写回完整排列时**禁用源槽位不动**——跟箭头的相邻 swap 语义一致，
    selftest 钉着「三次相邻 swap == 一次拖拽」；若用「摘出再插回」，禁用源会跟着漂移，箭头与把手对同一份数据给出不同结果。
    **视图层三条**：手势只挂把手（`line.3.horizontal`，16×20 命中区，minimumDistance 4；macOS 没有按住拖动滚动，不必担心跟滚动区抢）；
    坐标空间用卡片容器的命名空间、位移取 `location − startLocation`——不能用 `value.translation`，被拖的行自己在动会把位移吃掉
    （歌词管理列宽把手 08-05 踩过）；行 frame 的 GeometryReader 放在 `.offset` **之后**，量到的才是静止位置；拖拽开始那一刻一次性
    快照各行中线，拖拽期间不重量。让位 0.15s `easeOut`，reduceMotion 置 nil；被拖行 1.015 缩放 + zIndex。行数或匹配模式一变就丢弃
    进行中的拖拽。**箭头保留**并补「上移 / 下移」accessibilityLabel，把手补「拖动调整顺序」label + help——参考实现的弱点之一正是
    把手无 aria 文案。**没做的**：Esc 取消（SwiftUI DragGesture 没有取消通路，松手即落定）；拖拽中滚轮滚动列表会让快照失效（松手
    恢复，参考实现同样如此）；悬停光标没换抓手（要一份 pushedCursor 状态，收益小）。**验证**：selftest 18 组 2931 条 ALL PASS
    （新组 settings-ui 40 条）；装机后无崩溃、无 error 日志；真机拖拽手感当时没验。⚠️ **装机后用户首验就报「拖不到第一个前面」**
    （2026-09-05 03:4x）：`clampedTranslation` 把被拖行中线夹在首尾两行中线之间，而 `targetIndex` 要求越过首行中线**再多 6pt** 才落到
    首位——两条各自都对，叠在一起首位 / 末位就成了永远到不了的死角；selftest 分别测了夹住和滞回，**没测叠加**（「一帧连越到末位」那条
    用的是没夹过的 500pt）。修法：到达边界（首 / 末行中线，留 0.5pt 浮点容差）直接落到首 / 末位——边界处指针推不动，不存在来回换位，
    滞回在那里没有意义；settings-ui 组补 8 条叠加用例（含逐帧「先夹再判」一路拖到顶）。教训同「校准阈值别只用合成单测」那条：两个
    各自正确的约束叠加要单独测一条端到端的路径。
