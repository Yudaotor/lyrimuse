# 02. 播放数据源与播放器支持

> 最后核对:2026-08-22 · 基线:675f87a+工作树

## 定位

App 怎么知道"现在在放什么":从本地播放器读出 曲目元数据 + 播放/暂停状态 + 播放位置,喂给所有展示面(桌面悬浮歌词、灵动岛、歌词窗口、菜单栏)。支持 Apple Music、QQ 音乐、网易云音乐、酷狗音乐、Spotify 五个播放器,外加"自动识别"。核心是 `LocalPlaybackSource`(单例,2 秒轮询 + 事件加速 + 位置平滑),数据全部本地读取、零网络。

## 入口与展示面

- **设置 → 播放器 tab**(`SettingsView.swift` 的 `PlayerSettingsTab`):播放器 Picker、「Apple Music 自动化」权限卡(仅选 Apple Music 时出现)、「后台采集服务」卡(含 media-control 通道自检失败提示)、两个 App 联动开关。
- **引导页**(`OnboardingView.swift` 的 `playerChoiceStep` / `automationStep`):首次启动时选播放器;自动化权限步只在选中 Apple Music 时出现在 steps 里。
- 数据本身没有独立窗口——通过 `PlaybackCoordinator`(`LocalPlaybackSource` 的薄转发层)流向悬浮歌词(`LyricsOverlayView`)、灵动岛(`NotchLyricsView`)、歌词窗口(`LyricsWindowView`)、菜单栏(`MenuBarStatusItem`)。
- 「导出诊断信息」会带上 `lastResolvedBundleID`(这一刻实际被认下来的播放器,选"自动识别"时只报设置值等于什么都没说)。

## 行为规格

### 支持的播放器与两条读取路径

`PlaybackPlayer`(rawValue 与 collector 侧 `features.go` 的 `playerXxx` 常量逐字对应,经共享 JSON 文件交换):

| 档位 | rawValue | bundle id | 状态读取路径 | 位置精度 |
|---|---|---|---|---|
| Apple Music | `apple_music` | com.apple.Music | AppleScript(JXA)直接问 Music.app | `playerPosition` 精确到 ~0.1s(precise) |
| QQ 音乐 | `qq_music` | com.tencent.QQMusicMac | media-control(系统级 MediaRemote) | `elapsedTimeNow` 外推,±1~1.5s 抖动 + 整数秒地板量化 |
| 网易云音乐 | `netease_music` | com.netease.163music | 同 QQ 音乐 | 同 QQ 音乐 |
| 酷狗音乐 | `kugou_music` | com.kugou.mac.Music | 同 QQ 音乐 | `elapsedTimeNow` 外推,**无量化、极干净**(2026-08-21 实测:23.115s 墙钟↔23.116s 读数,累计偏差 +0.0011s)→ 归 `cleanExtrapolated` 档 |
| Spotify | `spotify` | com.spotify.client | media-control(与 QQ/网易云同路径) | 外推读数,稳态干净 ±0.05s(cleanExtrapolated 档) |
| 自动识别 | `auto` | 空字符串(无固定目标) | 见下节 | 取决于检测到谁 |

- QQ 音乐/网易云/酷狗**完全没有 AppleScript 支持**(经 `sdef`/PlistBuddy 核实:无 .sdef、未开 NSAppleScriptEnabled),只能走 media-control。酷狗是个 **Mac Catalyst 应用**(主二进制链的是 `/System/iOSSupport/.../MediaPlayer.framework`),靠 Catalyst 的 `MPNowPlayingInfoCenter` 把播放状态发布进系统级 MediaRemote —— 所以它零新增代码路径,只是多一个 bundle id。接入顺带白捡一项:酷狗本来就是五个**歌词源**之一,于是「同源加权」也一并生效(`playerNativeLyricSource` → `kugou`),用酷狗听歌时优先选酷狗自己的歌词,时间轴跟它的音频母版对得上。Spotify 虽有 AppleScript,但位置直查路线已于 2026-08-18 移除(见下节),现在全程 media-control。
- media-control 二进制由 build.sh 打进 app bundle(`Contents/Resources/media-control/`,含 Perl 适配脚本 + MediaRemoteAdapter.framework 的整棵相对路径子树);直接 `swift build` 跑时拿不到,退化为纯 AppleScript(Apple Music)可用、其余播放器不可用,事件流也不启动。
- 设置值经 `PlaybackPlayerPreference.current` 读取(每次轮询现读共享 JSON 文件,不缓存);文件不存在/解析失败/值认不出,**兜底 `auto`**(2026-08-13 从 appleMusic 改过来:老默认让纯 Spotify/QQ/网易云用户界面永远空白且看不出原因)。

### 自动识别(.auto)

`MediaControlClient.fetchAutoDetectedSnapshot`:

1. 问 media-control 当前系统级 Now Playing 是谁;bundle id 既不是五个内置播放器、也不在**用户信任列表**里(网页视频、Safari 等)→ 视为"没有可关心的正在播放"。判定是 `TrustedPlayers.isAccepted`,跟 collector 的 `isAcceptedPlayerBundleID` 同一套语义,两侧必须同时改。
2. 检测到 Apple Music 时,**不在本次调用里同步跑 AppleScript**(那样单次轮询耗时翻倍、扩大乱序竞态窗口),而是后台异步刷一份 AppleScript 快照缓存,下一轮轮询借用它更精确的 `elapsedTime`——精度提升晚一个周期(~2s)体现。
3. 借用缓存有三道守卫(`ageCompensatedCachedElapsed`,纯函数):缓存必须是同一首歌(标题+歌手都对上);双方都在播放(暂停不借:冻结的 elapsedTime 本身就精确);缓存值按"读数年龄 × 播放速率"外推到当下后,跟这次的新鲜读数差 ≤2s 才可信(超过说明缓存跨越了 seek/单曲循环重启)。任何一道不过就退回 media-control 自己的读数——精度让位于正确性。
4. 后台缓存刷新只在**正在播放**时发起(暂停时刷出来的缓存结构上不可能被借用,白 fork osascript)。

### 信任列表:自动识别不限死内置 App(2026-08-21)

- **要解决的问题**:`.auto` 原来只认写死的那几个 bundle id,任何别的播放器(Foobar、AlgerMusicPlayer、第三方客户端、以后出现的新 App)在放都被当成"没有可关心的播放"。
- **为什么不是"一律接受"**:那道白名单**同时挡着打卡**(`poller.isTracked`)。一律接受 = YouTube 视频、播客、网课被当成收听写进 Last.fm / ListenBrainz 的**永久历史**,并往"设计上永不清理"的歌词缓存灌垃圾条目、白烧五源查询。而"靠内容形状分辨是不是音乐"不可靠:浏览器里的网页播放器能用 MediaSession API 自己填 title/artist/artwork,一个 YouTube 音乐视频跟一首歌长得一模一样;`mediaType` 也指望不上(实测酷狗压根不报这个字段)。
- **口径 = 用户显式同意**:设置 → 播放器 在 `.auto` 下检测到未知 App 在报 Now Playing,就显示一张卡(App 真实名 + bundle id + **它此刻在放什么**,后者是用户判断"这是我的播放器还是某个网页视频"的关键),点「加入信任列表」写进 `features.json` 的 `trusted_players`(bundle id → 显示名)。之后它跟内置播放器**完全同权**:显示 + 打卡。
- **显示名在信任那一刻就地反查并存下来**(`NSWorkspace.urlForApplication` → `CFBundleDisplayName` → `CFBundleName` → 文件名),不是每次现查:collector(Go)也要用它当 ListenBrainz 的 `media_player` 标签,而 Go 那边没有 NSWorkspace。反查不到就存空串,标签退回 bundle id —— 绝不谎报成 "Apple Music"(那会让来源统计彻底失真)。
- **不需要 mtime 重读**:`FeatureSettingsStore.save()` 本来就会去抖重启 collector,所以点完信任 Go 侧立刻拿到新名单。Swift 侧每轮轮询重读 `features.json`(不加缓存,理由同 `PlaybackPlayerPreference`)。
- **发现卡的数据源**:`MediaControlClient.lastUngatedNowPlaying` —— 在**过闸之前**顺手记的一笔,挂在既有那唯一一次 media-control 子进程调用上(设置页开着时不额外 fork)。带 15 秒陈旧过滤,否则播放停了卡片还挂着一个早就不放的 App。
- **「这不是一首歌」守卫**(`trustedPlaybackNotASong` / `TrustedPlayers.notASong`,2026-08-21):信任的未知播放器上报**空歌手名或空专辑名**时整条丢掉(不解析歌词、不打卡)。判据跟 `isAdBreak` 完全一致(`album == "" || artist == ""`),区别只在作用域 —— 那个只服务 Spotify 广告(第一行就 `if bundleID != spotifyBundleID`),这个服务信任列表。全靠真实样本定的,四份实测:

  | 来源 | artist | album | 判定 |
  |---|---|---|---|
  | 酷狗音乐 | 周杰伦 | 七里香 | 是歌 |
  | Apple Music | 卢广仲 | 100种生活 | 是歌 |
  | Spotify | 方大同 | Soulboy | 是歌 |
  | Arc 放视频① | `""` | `""` | 不是歌 |
  | Arc 放 YouTube② | `Dream in reality`(**频道名**) | `""` | 不是歌 |

  **album 是这四份样本里唯一 100% 分对的字段**。②(时长 925 秒的法语 vlog)正是"只卡 artist 不够"的证据:YouTube 把频道名塞进 artist,数据形状跟"歌手 - 歌名"无法区分。代价是电台/单曲场景真音乐 App 若不报专辑名会被误挡 —— 2026-08-21 用户拍板接受(宁可漏认,不要把视频写进永久收听历史)。`mediaType` 这条路走不通,记下别再试:酷狗压根不报这个字段、Arc 也不报(**不是报 Video,是没有这个键**),只有 Apple Music 有。内置五个播放器不走这条(各有既有守卫)。发现卡用**同一套判据**(`UngatedNowPlaying` 因此也带上 album)—— 否则会摆出一张"点了必定没反应"的卡片。信任列表的意义因此从"靠用户选对"变成"选错了也有兜底"。
- **发现通知(macOS 系统通知,2026-08-22)**:用户报「识别到新的播放器,但我自己不知道要去这里信任,目前没有一个通知机制」—— 发现卡只在设置页、而且只在那个播放器**此刻正在报 Now Playing** 时才出现,不主动打开设置页就永远看不到。用户拍板**只做系统通知,不要菜单栏那部分**;发现卡保留作兜底。
  - **判据下沉**:原来那套门槛写在 View 的 `if` 里,通知那条路必然要再抄一份、抄漏是必然的。现在拆成两层放进 `LyrimuseCore/Local/UnknownPlayerAlert.swift`(纯函数,selftest 33 条断言):`shouldOffer` **卡片与通知共用**(自动识别 / 观察不陈旧 15s / artist 与 album **trim 后**都非空 / 未被接受);`shouldAnnounce` 是通知专属的更高门槛(静音名单 / 反查得到 App 名 / 稳定 ≥6 秒且 ≥3 次 / 次数上限与冷却)。**顺带修掉一个既有 bug**:卡片原来写裸 `!album.isEmpty`,而 `notASong` 是 trim 后判空 —— `album = " "` 的播放能过卡片、过不了守卫,即"点了必定没反应"。
  - **通知门槛为什么比卡片高**:通知是我们主动打扰。①静音名单 `mutedForAnnounce`(播客/TV/图书/新闻/信息/FaceTime/QuickTime/预览/照片/语音备忘录/WebKit.GPU/控制中心/微信)—— 播客的 artist=节目名、album 常常非空,能过 artist/album 那道门槛,信任之后就会被当歌打卡进**永久收听历史**;微信语音/视频号是实测这台机器上真正"天天来一次"的那个。⚠️ 刻意**不**写成"整个 `com.apple.*` 静音":Safari 放网页音乐跟 Chrome 一样正当。名单**只影响要不要弹通知,不影响能不能信任** —— 真想信任播客的人在卡上照样点得到,这正是"卡片保留作兜底"的价值。②`appDisplayName` 反查不到的不弹(`com.apple.WebKit.GPU` 这种,标题只能摆一串 bundle id)。③稳定性门槛:实测 `mediaremoted` 日志里 12 分钟有 4 组**亚秒级**焦点往返(Music ⇄ Chrome),不设门会为一个只抢了两秒焦点的 App 烧掉它的提醒机会。
  - **提醒次数**:同一 bundle id 最多 3 次、每次至少隔 24 小时,不是"一辈子一次"。理由是实测这台机器**当时就开着专注模式**(`com.apple.focus.work` 的 assertion 从 01:36 起没有失效记录),还有 App 启动触发的 DND 和每天 00:00 的定时 DND —— DND 下横幅根本不弹、静默进通知中心,被一次「清除全部」就永久丢失。信任成功后 `shouldOffer` 天然不再成立,自动停。记录存 UserDefaults 的 `np:unknownPlayerNotices`(JSON 字符串,`defaults read` 看得懂),**已登记进 `ConfigPortability.machineLocalDefaultsKeys`** —— 它跟 `np:hasShownOverlayDragHint` 是同一类机器状态,跟着备份搬去新机器的后果是新机器上永不提示。
  - **这个 bundle 能不能发通知(2026-08-22 实测取证)**:三个可疑条件叠在一起 —— ad-hoc 签名(`Signature=adhoc`、`TeamIdentifier=not set`)、launchd **直接 exec** `Contents/MacOS/lyrimuse`(不经 `open`)、`LSUIElement=true`。结论**可行**,证据:①这台机器上 JetBrains Toolbox 的 LaunchAgent plist 跟 Lyrimuse 逐字段同形(同样直接 exec `Contents/MacOS/`),通知授权 `auth=7`;②Chromium / chrome-for-testing 都是 ad-hoc、TeamIdentifier 未设,同样 `auth=7`;③`lsappinfo info <pid>` 对活着的 Lyrimuse 进程能拿到 bundleID + bundle path + **checkin time**,这正是 `bundleProxyForCurrentProcess` 需要的,而且不是靠 `open` 拿到的。本地通知不走 APNs,**不需要**开发者证书/公证/entitlements,Info.plist 也不需要任何键。落地后铁证:`~/Library/Group Containers/group.com.apple.usernoted/db2/db` 的 `app` 表出现 `me.yudaotor.lyrimuse`、`categories` 表出现同名一行 185 字节 —— 改动前这两张表都没有它。
  - ⚠️ **`interruptionLevel` 的 `.timeSensitive` / `.critical` 用不了**:要 entitlement,ad-hoc 拿不到。默认 `.active` 够用,别写。
  - **通知上只放一个 action**(2026-08-22 用户报「这里可以直接把按钮选项放在外面吗,不要在选项里面点进去了」):macOS 的规则是 **1 个 action 直接渲染成可见按钮,2 个及以上折叠成「选项 ∨」下拉**。原来还有个「忽略」按钮,处理逻辑本来就是空的(纯 dismiss),而划掉/点通知上的 × 一样能关 —— 去掉零功能损失,换来「加入信任列表」直接可点。⚠️ 想再加第二个动作之前先想清楚:那会把这个按钮重新折进「选项」里。
  - **点通知连带弹出歌词窗口(2026-08-22,修了三轮)**:`applicationShouldHandleReopen` 是为「点 Dock 图标开歌词窗口」写的,而**系统激活 App 时也会触发它** —— 点通知就连带弹歌词窗口。三次踩的坑都值得记下:①只做「延后 0.3 秒开窗 + 通知回调来了就取消」→ 只堵了"reopen 先到"那一半,而实测真实顺序是反的(`didReceive 10:48:46.878` → `reopen 10:48:47.171`),取消跑在前面扑了个空;②改用抑制窗口,但标记是靠 `(NSApp.delegate as? AppDelegate)?.…` 设的 → 那个转型在 SwiftUI 的 `@NSApplicationDelegateAdaptor` 下**拿不到**我们的 AppDelegate、**无声失败**(证据链:设置页开在了正确的栏,而那行代码在 `MainActor.run` 块**之后** → 块跑了;块里唯一的语句的日志一行没出 → 转型是 nil。那也是全仓唯一一处 `NSApp.delegate` 用法,本来就没有先例);③想靠「reopen 的发起方」精确区分 Dock 与通知 → 实测 `open -b`(Dock 点击发的同一个事件)拿到的是 `(no AE)`,取不到,这条路走不通。**最终形态**:抑制标记放 `AppActions`(那个单例存在的意义就是这类桥接),**同一个判据查两次** —— 进 `reopen` 时查一次、延后任务真要开窗前再查一次,一个机制盖住两种顺序,通知那边只管设标记。
  - ⚠️ **诊断日志必须用 `.notice` 不能用 `.info`**:`Logger.info` 是内存缓冲、**不落盘**的,`log show --last 30m` 查不到而 `--last 20m` 有(实测,一度让我以为事件没发生)。另外 `willPresent` / `didReceive` 里**必须**有日志 —— 头两轮排查最大的盲区就是那两处一行日志都没有,看不出 delegate 到底跑没跑。
  - **几个必须这么写的点**:`registerCategory()` 要在启动阶段调 —— `setNotificationCategories` 是**整表替换**,投递时 `categoryIdentifier` 查不到的话通知照样显示但**按钮不出现、而且不报错**;delegate 设晚了冷启动点按钮的回调会丢。必须实现 `willPresent` 返回 `[.banner, .list, .sound]` —— Info.plist 写着 `LSUIElement=true`,但 `AppDelegate:155` 运行时按 `showInDock`(默认开)把 activationPolicy 翻成了 `.regular`,**App 默认是前台的**,少了这个方法"用户正开着设置页找这个功能"时反而收不到。点通知**正文**要 `AppActions.shared.requestSettings(.tab(.player))` **先**调、再 `NSApp.activate` + `openSettings?()` —— 只调 `openSettings()` 的话窗口是开了但落在上次那一栏(用户 2026-08-22 报「点击通知之后应该自动跳到这个页面」);`requestSettings` 晚于 `openSettings` 也不行,它的信箱那条路靠 `SettingsView` 的 `.onAppear` 消费,赶不上就白设。处理按钮时 bundle id **必须**从 `userInfo` 读,绝不能回头读 `MediaControlClient.lastUngatedNowPlaying` —— 通知可能在通知中心躺了几小时,读现值会「点 Chrome 的旧通知结果信任了 QuickTime」。
  - **授权时机**:第一次真的有东西要通知的那一刻才请求,**不在启动时**。授权只有一次机会(状态一旦 `.denied`,后续 `requestAuthorization` 立刻返回、再也不弹框),启动时无脑请求会让用户在完全不知道这是干什么用的时候随手点「不允许」,功能就永久废了。代价:第一次命中会被授权对话框吃掉,通知本身等下一拍。
  - **权限被拒必须说出来**:用户选了"不要菜单栏兜底",权限被拒时这个功能**完全静默**,而用户会理解成"它没检测到"。设置页因此多一行(只在 `.denied` 时出现)指向 系统设置 → 通知。
  - **只在 Swift App 一处发**:collector(Go)是独立的 `KeepAlive` job、又各自独立轮询 media-control,两侧都发就是双份;而且 Go 侧只能 `osascript display notification`,通知会署名 Script Editor、没有按钮。
  - ⚠️ 已知小瑕疵:category 的按钮标题在启动时按当时语言注册一次,启动后切语言要重启才更新(按钮文案会停在旧语言)。
  - ⚠️ 文案上**不要**出现"推送"二字:设置页已有的「推送提醒」/「通知平台」指的是 Bark/飞书/钉钉/企业微信 webhook,跟 macOS 本地通知毫无关系,混用会让用户以为要先配 webhook。
- **位置档位**:未知/信任的 App 落 `positionSourceTier` 的默认档 `noisyFloored`(大门槛 + 前向棘轮)。对纯外推源棘轮基本不会触发(reported 与 predicted 同步前进),而万一某个 App 真是整秒量化,这一档正好对 —— 保守方向选的是"慢一点纠正",不是"可能锁死"。

### 锚点冻结的源(网页播放器)三件事(2026-08-21)

用户报「用 Arc 播放音乐时歌词进度比较慢」查出来的一组问题。**先说清测量结论**:歌词引擎跟得很准 —— 同一瞬间 `media-control` 报 42.52s、缓存 LRC 的当前句是 `[42.46]`、桌面悬浮歌词显示的正是那一句,差 0.06s。滞后**不在我们的位置管线里**。

- **病征**:Arc 这类网页播放器(页面**没调** `mediaSession.setPositionState()`)的锚点是**冻结**的 —— 实测 8 次采样 `elapsedTime` 恒等于 0、`timestamp` 恒等于开播那一刻,位置全靠 media-control 按墙钟外推的 `elapsedTimeNow`。于是 `报告位置 = 墙钟 − T0`,而 T0 是**会话创建时刻**,比音频真实起点晚一截(页面先出声、后注册元信息)→ 整首恒偏小 → 歌词慢一个固定值。
- **不能按"是浏览器"加默认偏移**:①决定权在**页面**不在浏览器 —— 调了 `setPositionState` 的站点锚点准确、还会在 seek/暂停时刷新;②**连正负号都不固定** —— 页面先注册后缓冲出声时 T0 偏早,歌词会变**快**;③幅度等于站点 JS/网络耗时,不是常数。写死 `+X` 会把另一半站点推得更歪。固定偏差只能靠**按播放器记一个用户校准值**(默认 0)—— 2026-08-21 已经这么做了:设置页那一行时间轴偏移多了个播放器下拉框,按 bundleID 存一档(跟共用那档**二选一、不叠加**),见 08-lyrics-engine.md 的时间轴偏移一节。
- **修 1:暂停归零**(`pausedPositionSeconds` / Go 侧 `pausedPositionSecs`)。既有规则"暂停时用原始 `elapsedTime`"**只对会刷新锚点的源成立**(QQ/网易云/Apple Music 暂停时会带新时间戳重发一次,那个值就是暂停位置);对 Arc 那个恒为 0 的值,一按暂停位置直接归零 —— 用户视角是"在浏览器里一按暂停,歌词跳回第一句"。现在改成:**锚点陈旧(`now − timestamp > 2s`)且报告值比"播放中最后一次位置"低 >3s** 时,用最后已知位置。两个条件各挡一种误判 —— 前者把会刷新锚点的源整个排除(也就保住了"向后 seek 之后暂停"这种合法大幅回退),后者保证正常暂停(两者只差一拍)不被改写。位置**按曲目**记,换歌自动作废。两侧同一套规则,必须同时改。
- **修 2:默认档翻面**(`positionSourceTier`)。`noisyFloored` 的两样东西(1.0s 大门槛 + 前向棘轮)只对**整秒量化**的源成立 —— 棘轮前提是"报告值 ≤ 真实位置"。而实测所有走 media-control 的源都是纯外推、无量化(酷狗 23 秒累计偏差 +0.0011s;Arc 小数位 .467/.550/.620 完全连续)。所以量化源(QQ/网易云)是**少数派**,现在显式登记它们,其余(含 `nil`)走 `cleanExtrapolated`。⚠️ 这条修的是正确性,**不解决上面那个滞后** —— EMA 拿"我们的外推"跟"报告值"比,两者共享同一个偏差,源头偏了伺服校不出来。
- **修 3:整秒时间戳的相位订正**(`estimatedAnchorInstant`,2026-08-21)。`timestamp` **恒无小数秒**,而它就是 `elapsedTimeNow` 的外推基准 —— `ts = floor(真实时刻)`,于是 `位置 + (now − ts)` **恒偏快 frac 秒**,且锚点冻结时锁死一整首歌。用 Apple Music 的 AppleScript 播放头当独立真值实测(12 样本):偏差 **+0.824s、极差仅 0.042s**(同一锚点上稳如磐石 —— 顺带发现 Apple Music 的 media-control 锚点也冻结了 51 秒没刷新,它没暴露问题只因为走 AppleScript 直读)。
  - **订正靠夹逼**:τ ∈ [`ts`, min(`ts+1`, 首见时刻)],取中点 → `ts + min(1, 首见−ts)/2`。三条界分别来自 floor 语义、frac<1、以及"我们不可能在它发布前看到它"。这个式子**永远不会比现状差**:即时发现 → 订正量小、误差 ≤ 间隔一半;只靠 2 秒轮询发现 → 退化成 `ts+0.5`,最坏 ±0.5s(仍是现状 [0,1) 的一半)。订正量恒在 [0, 0.5]。
  - **实测收益**(同一真值口径):平均绝对误差 **0.653s → 0.163s,降低 75%**;稳态样本从恒 +0.49 变成 −0.007。
  - **只在锚点冻结时接手**(age > 2s):每拍都刷新锚点的源(QQ/网易云/Spotify)不碰 —— 它们 frac 每拍重掷、且自身的位置量化还会部分抵消,那条路径的参数是按实测调出来的(见 `noisyFloored` 那档注释),不该被顺带改掉。
- **为什么"学一个偏移"不可行**(2026-08-21 实测否掉的方案):用户提议"识别到浏览器就自动学一个偏移、按浏览器+根网站生效"。两个否决理由 —— ①**MediaRemote 不给站点信息**(13 个字段里没有任何 url/domain/tab;Arc 虽有 AppleScript 字典能问 `active tab` 的 URL,但要新增自动化权限,且"正在播的标签页 ≠ 活动标签页");②**没有可学的常数**:连续播放期间两个真锚点的 `Δ位置 − Δts` 实测 7 个样本 −0.896 ~ +0.134、**极差 1.03s**,正是整秒量化本身。固定偏移只在运气好的锚点上对 —— 每次换歌/暂停恢复都重新掷骰。用户观察到的"暂停恢复后就准了"是重掷了一次好骰子,不是校正。

  ⚠️ 别把这条读成「按播放器加偏移已经被否掉了」:被否掉的是**自动学**、**按浏览器+根站点**;做进去的是**用户手调**、**按播放器(bundleID)**、默认 0、界面上看得见改得动(08-lyrics-engine.md 的时间轴偏移一节)。同一件事的两个不同形态,分界线就在"谁定这个数"。
- **`mediaType` 这条路走不通**,记下别再试:酷狗压根不报这个字段、Arc 也不报(不是报 Video,是没有这个键),只有 Apple Music 有。

### 轮询、事件加速与去抖动

所有状态变更只发生在 `poll()` → `apply()` 这一条路径上:

- **兜底轮询按播放态分档**(2026-08-20 性能审计,`PollInterval`):播放中 2s(scrobble 计时/enrich mtime 检查/未解析重试都搭在这个节拍上,不能慢)、暂停 6s、空闲(连曲目都没有)10s——每一拍都要 fork 一个子进程,固定 2s 意味着彻底没在放歌的机器也一天 fork 三万多次。降速安全的前提是三路事件唤醒(AM/Spotify 分布式通知 + media-control stream)把播放/暂停/换歌的感知拉回亚秒,慢节拍只是它们全失效时的兜底;`adjustPollCadence()` 在每拍状态落定后按需重建 Timer(挂 `.common` mode)。每次 poll 带单调递增世代号,子进程返回后只在"没有更新的轮询已发起"时才生效——防"较早发起的慢轮询用过期快照覆盖新快照"(2026-08-02 实测坐实的乱序 bug)。
- **三个"有动静"信号**合并走同一条 250ms 去抖动补查路径(`handlePlayerInfoChanged`):
  1. 分布式通知 `com.apple.Music.playerInfo`(Music.app 换歌/暂停/恢复都广播,无需权限);
  2. 分布式通知 `com.spotify.client.PlaybackStateChanged`;
  3. media-control 事件流(`MediaControlStreamWatcher`:常驻 `stream --no-artwork` 子进程,只在状态变化时输出;QQ 音乐/网易云没有分布式通知,全靠它)。子进程死掉按 1s→30s 指数退避重启;正常吐数据即复位退避。
- 事件**只当"提前触发一次 poll()"的信号**,一个字段都不从 payload 直接喂状态(刻意取舍,防两套数据源对账的乱序 bug 温床;见 `startObservingPlayerInfoNotification` 长注释)。
- 去抖动 250ms 是实测量出来的:Music.app 一次操作连发 2 条通知且第一条常带旧状态,AppleScript 可见状态 ~294ms 才切换完;"收到即查"会读到没切换完的快照。感知延迟从"平均 1 秒、最坏 2 秒"降到 ~0.5 秒。
- 收到通知那一刻先把外推**冻住**(`freezeExtrapolationUntilNextPoll`:把 anchor 重建成 rate=0 的冻结锚点)——否则通知(+116ms)到真相(~480ms)之间外推还在往前跑,切到暂停冻结位置时进度条/歌词会回跳半秒(2026-08-17 用户报的"暂停时进度条突然回退一点")。

### 播放位置的平滑与伺服(resolvePositionSeconds)

只在"这一轮确实在播放"时调用;思路同 collector `poller.go` 的 `updatePosition()`:

1. **seek 陈旧读数拒收**(`shouldRejectStalePositionAfterSeek`,纯函数):seek 后 1.2s(`seekSettleWindow`)内,读数更像 seek 前旧位置而非目标位置 → 整份丢弃,沿用当前外推值。
2. **换歌 / 刚从暂停恢复 / 第一次观察** → 直接采纳这次读数(重锚)。换歌一档有例外:**Spotify gapless 自然切歌**先走锚点超前校正(见下一节),命中时按旧曲连续性播种、不采信读数原值。
3. **|读数 − 预测值| > 2s**(`seekJumpToleranceSecs`)→ 判定真实 seek/跳变,重锚。
4. **地板量化源前向棘轮**(`shouldRatchetForward`,仅 noisyFloored 档=QQ/网易云):QQ 音乐上报给 MediaRemote 的位置只有整数秒,reported 恒 ≤ 真实位置——所以 reported 比外推值靠前 >0.05s 就证明外推落后,立刻向前采纳(不可能冲过头);反方向维持不动。2026-08-16 实测补上,修"歌词永远比实际唱的慢半个字"(取整偏差单向,EMA 收敛到 -0.5s 永远够不到门槛)。⚠️ Spotify 明确排除(2026-08-18):它的读数恒略**超前**真值,棘轮前提反着,只会把位置锁在抖动上包络。
5. **稳定播放** → 按墙钟外推,同时用偏差 EMA 伺服(`servoDecision`,纯函数):持续同号偏差(启动播种毛刺、恰好没被观察到的短暂停)让 EMA 超门槛就一次性校正并重锚;零均值噪声在 EMA 里抵消。三档参数(2026-08-18 从两档拆开):precise(Apple Music)α=0.5、门槛 0.15s;cleanExtrapolated(Spotify)α=0.3、门槛 0.4s、**单样本限幅 ±0.75s**;noisyFloored(QQ/网易云)α=0.3、门槛 1.0s。cleanExtrapolated 另有**冻结守卫**(`isFrozenReport`,2026-08-18 边界探针实测):曲目/广告结尾 Spotify 会把锚点冻住(elapsedTimeNow 实测卡死 6 秒、真声走到落后 8s),播放中墙钟走了 ≥0.75s 而报告值几乎没动即判陈旧——维持墙钟外推、不喂 EMA、且必须排在 seek 分支之前(否则冻结值几秒后超过 2s 容差,位置被重锚回冻结值,歌尾歌词整段倒回去,即用户报的"自动切歌之后变慢");判"几乎没动"而非"没前进",向后 seek(大负数)与解冻(大正数)都不误伤;限幅是它的配套——冻结第一拍检测认不出,单发 -1.74s 偏差不限幅会直接冲过 0.4 门槛回拖半秒。此前记录的"每首歌锚点自带整曲偏差、App 侧无真值参照修不了"已被 2026-08-20 的自然切歌锚点校正推翻(方向也订正了:实测自动连播是**偏快** +0.888s,不是偏慢),见下一节。

档位按快照的 bundleIdentifier 判(`positionSourceTier(forBundleID:)`,未知播放器保守归 noisyFloored),不看设置值。Spotify 拆档背景(2026-08-18 实测,AppleScript 真值对照 140+ 样本):其 elapsedTimeNow 稳态偏差仅 ±0.05s、比 QQ 音乐干净一个量级,但换歌头几秒 MediaRemote 报数脏(锚点先于音频出声,最高 +1.32s)——播种进 <1.0s 的超前值后,1.0s 大门槛让它整曲不被纠正,用户视角"Spotify 歌词经常偏快";收窄到 0.4s 后播种超前 2 轮(~4s)内校正,单发陈旧读数(实测 -1.27s)EMA 只到 -0.38 不误回跳。注意蓝牙耳机音频延迟(~0.2s,所有播放器共同)不归这里管,用设置里的「全局时间轴偏移」抵消。

### Spotify 位置:已回归通用外推(2026-08-18)

Spotify 曾走「AppleScript 直问 playerPosition 真值」的特殊路径(08-14 上线,附带失败重试、真值缓存、gapless 预载回扣三轮修补),用户仍反馈"经常进度不准",08-18 拍板整体移除:**App 侧与 collector 侧同批**回归与 QQ 音乐/网易云完全相同的 media-control 外推 + EMA 平滑路径。代价是 MediaRemote 锚点自带的固定滞后(~1.6s 量级、会话间漂移)只能靠平滑吸收;收益是行为可预期、无 osascript 子进程依赖。历史机制(spotifyPlayerPosition/spotifyRebase/spotifyPreloadDelta)的完整注释在 git 历史里,重走真值路线前先读。

### Spotify gapless 自然切歌锚点超前校正(2026-08-20)

用户报"自然播完切歌后整首歌词偏快、单独点播正常"且必现。实测坐实(media-control 0.25s 采样 + 旧曲连续外推做真值,Forever Love→在那遙遠的地方):gapless 自然切歌时 Spotify 在**旧曲真声还剩 ~0.84s** 时就切了元数据并打好新曲锚点(elapsedTime=0),此后整首歌 elapsedTimeNow 恒定超前真声 **+0.888s±0.009**(60s 窗口纹丝不动、锚点从不重打);playerPosition 同样超前(+0.77s,08-17 实测 +1.84s,每首抽签)——所以 JXA 真值路线救不了它。伺服对这种偏差**结构性失明**:每笔读数都从同一个超前锚点外推、与墙钟外推步调完全一致,reported−predicted 恒 ≈0。手动点播的锚点是点击瞬间打的、与真声对齐,所以准——两种形态的差异就是全部机理。

修法(`naturalAdvanceCorrection`,纯函数,App 侧 `LocalPlaybackSource` 与 collector `poller.go` **同批对称实现**):换歌那一拍若上一首(还在播)按墙钟连续外推已走到结尾附近(|越界量| ≤ 窗口:App 4s、collector 6.5s——采集器无事件通知,窗口要吞下 5s 轮询),就把新曲**播种为越界量**(允许为负=旧曲真声未完,UI/发布口钳 0,表现为歌词等真声开始才起走;collector 发布"位置 0 @ 未来 |播种值| 秒"的未来锚点,否则 relay 按变化去重、网页整段超前),偏置=原始读数−越界量,守卫在 (0.05, 2.5]s 之外不采信(下限滤噪声,上限挡"换歌瞬间读数还挂上一首"的陈旧值,同时把"手动跳歌恰好发生在结尾窗口内"的误判伤害钉死在 ≤2.5s 且方向是偏慢)。同曲期间每笔原始读数先扣偏置再进平滑/伺服;暂停冻结值同样扣(pausedPositionMs);**真实 seek/手动换歌/我们主动发的 seek 都清零偏置并改信原始读数**(Spotify 重打的锚点与真声对齐);暂停⇄恢复**继承**偏置(冻结值来自同一超前锚点——collector 侧为此专门加了同曲恢复分支,不能让恢复落进 seek 分支清偏置)。

同日对抗审查(12 agent)后同批加固:repeat-one gapless 回绕(key 不变探测不到,两侧补回绕签名重估——collector 分"同拍观察到/loopRestart 先归位后一拍"两形态);clearIfWasPlaying 补清 pos 私有状态(否则中断后另起一首会被陈旧状态伪判成自然切歌);collector 瞬时读取失败的陈旧快照不再走 seek 分支(snapshotStale 守卫+Elapsed 同步外推保 prevElapse@prevWall 配对一致);暂停中在播放器里拖进度条按冻结值跳变清偏置;playing 时 rate=0 瞬时报告归一为 1(否则 predicted 停走误判 seek);自然切歌校正双向要求新旧两拍都是 Spotify(posPrevTierCleanExtrapolated/prevBundle 门),换源即清偏置。

诊断:`log show --predicate 'subsystem == "me.yudaotor.lyrimuse"'` 看 "natural advance: seed … anchor leads audio by …" / "repeat-one wrap: …" 行;collector 侧看 stdout 日志同款行。**接受不修的已知边界**(单源本质歧义/量级可控):偏置在位时曲内 <偏置+2s(~3s)的小幅外部拖动分不出"锚点没动"还是"准锚点+小拖",该曲余下偏慢 ~0.9s、换歌自愈;crossfade/Automix 开启时"音频连续"真值假设失效,偏置被高估 ~重叠秒数(整曲偏慢该量);播种误差沿 gapless 连播链传播,但幅度恒被 2.5s 守卫钉死。

### 进度锚(ProgressAnchor)与 20Hz tick

- `ProgressAnchor`(`LyrimuseCore/Playback/ProgressClock.swift`)是"锚点 + 外推"结构:`extrapolatedPositionMs(now:)` = progressMs + 锚点年龄 × rate,夹在 [0, durationMs]。本地锚点 `fresh=true` 不限龄外推、`baseAgeMs=0`(无网络延迟);`progressTs`/90s 封顶那套字段是远程模式遗产,本地路径不用。
- `apply()` 只在真的必要时重建锚点(首次/换歌/didReanchor/rate 或时长变化)——稳定播放期继续外推旧锚点数学上等价,重新赋值纯属多余的 @Published 通知。⚠️ `needsNewAnchor` 里的 `anchor?.rate != rate` 比较不能去掉:通知冻结锚点(rate=0)靠它被换回来,去掉后进度条会永久冻结。
- 逐字填色由各 View 的 TimelineView 按渲染帧频直接从 anchor 现算;`fastTick()`(20Hz Timer)只负责判定当前歌词行/下一行/行下标/间奏下标(2026-08-20 起走引擎的 `tickQuery` 打包查询,同一个 posMs 只定位一次),且只在真的变化时才给 @Published 赋值(防整个 View body 每秒重算 20 次的卡顿)。
- 20Hz Timer 只在有 anchor(正在播放)时运行;**锁屏时停 20Hz、2 秒 poll 必须继续**(`setScreenLocked`,由 `AppDelegate` 订阅 `com.apple.screenIsLocked/Unlocked` 驱动)——锁屏期间听的歌仍要被记录,Last.fm/ListenBrainz 提交不能丢。

### 暂停与恢复

- 暂停时 media-control/AppleScript 的 elapsedTime 都是精确的冻结值:anchor 置 nil,冻结位置发布为 `pausedPositionMs`(时长单独发布为 `currentDurationMs`,进度条按冻结值显示而不是消失)。
- 暂停**不清当前歌词行**:按冻结位置解一次当前行(`resolveLinesForPausedPosition`——`apply()` 和 `fastTick()` 必须都走这一处,`seek(toMs:)` 末尾无条件调 `fastTick()`,两处逻辑错开就会"暂停拖进度条行被清掉")。用户按暂停的典型场景是"这句是什么?我看一下"。
- 暂停态 `pausedPositionMs` 同样有 seek 陈旧读数拒收(否则暂停拖进度条会"弹回去一下再过去")。
- 恢复播放走 resolvePositionSeconds 的"无可信锚点"分支直接采纳读数;`posTrackingKey/posWasPlaying/posPrevWall` 无论播放与否每轮都更新,防"播放→暂停→再播放"误用暂停前的陈旧墙钟基准。

### 停止/焦点丢失的清理(clearIfWasPlaying)

nil 快照(Music.app stopped/退出、播放列表放完、.auto 或 media-control 播放器被别的 App 抢走系统 Now Playing 焦点)→ 全量清理:isPlayingNow/anchor/歌词三件套/allLines/封面/取色/冻结位置/时长/**title/artist/album 也清**(2026-08-14 改:此前保留造成"半吊子状态",专辑放完后曲名还在、封面变占位、看着像坏了)/纯音乐/广告等判定,并停 20Hz。⚠️ `lastKey` 必须一起清,否则同一首歌恢复播放时 `trackChanged=false`,allLines/封面两条重建路径全被跳过,歌词窗口和悬浮歌词会互相矛盾。

### Spotify 广告插播检测

`apply()` 里:title 非空 + 快照来自 Spotify(bundleIdentifier 精确核对)+ album 为空 → `isCurrentTrackAdBreak`(media-control 文档确认广告播放时 album 恒空)。三个展示面(悬浮歌词/灵动岛/歌词窗口)据此显示「广告中」,且该分支必须排在"搜索歌词中…"之前——广告的标题永远不会进歌词缓存,否则整段广告卡在"搜索中"。collector 侧 `enrich.go` 有同信号的对应守卫(不把广告写进歌词缓存),`system.go` 的 `isAdBreak` 同判据。

### 播放控制(写路径,MusicPlaybackController)

- playPause/nextTrack/previousTrack/seek 走双后端 `dispatch`:设置值为 `.appleMusic` → AppleScript 发给 Music.app;**其它任何档(含 .auto)** → media-control 控制指令(作用于系统 Now Playing 焦点,代码注释断言读取路径确认在播时天然作用于该播放器)。seek 有 `preferAppleScript` 覆盖:.auto 下实际在播 Apple Music 时,读路径是 AppleScript 精确播放头,写路径也走同一条(`LocalPlaybackSource.seek` 按 `lastSnapshot?.bundleIdentifier` 判)。⚠️待核对:playPause/上一首/下一首没有同款覆盖——.auto + Apple Music 实际在播时它们走 media-control,行为应等效但未见实测记录。
- `seek(toMs:)` 除发指令外**立刻**本地重锚三处(trackPosSeconds/posPrevWall/posErrEMA 清零)+ 当场重建 anchor + `pollGeneration += 1` 作废在飞轮询 + 立即 `fastTick()`——不重锚的话小于 2s 的拖动会被 seek 容差永久吞掉。秒数经 `seekArgument` 格式化(固定 3 位小数、en_US_POSIX、负值夹 0、上界故意不夹)。
- 「喜欢」(favorited/loved 双属性名兜底,macOS 版本间改名)、播放模式(三档:列表/随机/单曲循环)、音量:仅 AppleScript,`supportsExtendedControls` = Apple Music 和 Spotify;Spotify 无单曲循环档(`supportsRepeatOne` 仅 Apple Music,脚本接口只有布尔 repeating);QQ/网易云完全不支持(MediaRemote 只有播放控制)。
- 所有 Spotify 脚本前垫 running 守卫(发任何命令都会启动 Spotify);写指令"发完就不管"不阻塞,读回值的走 `runAppleScriptCapturing`(5s 超时,**不要在主线程调**)。
- 切播放模式**写完不马上回读**:实测 setter 生效后 getter 滞后 250ms+,回读旧值会把画好的图标覆盖回去。

### 权限(自动化)

`MusicAutomationPermission`(仅覆盖 Lyrimuse 自己这份 TCC 身份;collector 是独立签名身份、独立一条 TCC 记录,App 无 API 可查/可触发,设置页只给说明+跳系统设置按钮):

- 只有 Apple Music 需要(`checkForCurrentPlayer` 对其它播放器直接返回 true);QQ/网易云/Spotify 的 media-control 路径实测全程不触发权限弹窗。
- 状态查询用 `AEDeterminePermissionToAutomateTarget`(noErr=已授权、-1743=已拒绝、-1744/-600/其它=当"还没问过"——宁可多问一次也不把模糊状态误判成已拒绝)。
- 该 API 在主线程调用有据可查可能**永久挂起**(SpamSieve 同坑)→ 所有请求路径走 `requestWithTimeout`(后台任务 vs 8s 超时竞速,超时返回 nil="还不确定");播放控制按钮/快捷键专用 `checkForCurrentPlayerSafely`(已确定状态直接同步返回,只有真没问过才走竞速,且不后台拉起 Music.app)。
- Music.app 没在运行时系统授权弹窗根本不弹(实测与文档不符)→ 设置/引导页显式点"请求权限"前先 `activates=false` 后台拉起 Music.app。
- 被拒绝后没有 API 能再触发弹窗,只能跳"系统设置 → 隐私与安全性 → 自动化"。设置页权限卡在 App 重新变前台时重读状态(用户可能切去系统设置手动改)。
- `.auto` 下实际在播 Apple Music 的场景(如悬浮窗"喜欢"按钮)用 `checkAppleMusicSafely`——不看设置值,直查这份权限。

### media-control 通道自检

`MediaControlHealth`:启动时后台跑一次 `media-control test`(8s 超时),**只做归因、不做降级**——私有 MediaRemote 通道被系统更新弄坏时,"歌词不动了"跟"没在放歌/没歌词/collector 挂了"表象上分不开。失败时设置页「后台采集服务」卡下方显示说明(只影响 QQ 音乐/网易云;Apple Music/Spotify 走 AppleScript 不受影响),不显示成红字报错(用户无法修复)。

### Apple 目录锚点(2026-08-22)

media-control 快照里的 `uniqueIdentifier` 字段一直被丢掉。实测坐实:放 **Apple Music 目录曲目**
时它就是 **Apple 的目录曲目 ID**——`uniqueIdentifier=1485220325` → iTunes lookup 回
trackNumber=18 的「印地安老斑鸠 (Live)」、`collectionId=1485220306`、`trackTimeMillis=208293`,
而同一份快照的 `duration` 是 208.293,逐位一致。collector 现在解析这个字段,一次
`itunes.apple.com/lookup` 换到这条曲目的权威元数据(曲目署名、专辑署名、专辑 ID、权威时长),
按曲目 ID 永久缓存(ID 是不变映射,没有 TTL,只落盘查到了的条目)。

**两道守卫 + 一道自校验**,缺一不可:

1. `bundleIdentifier` 必须是 `com.apple.Music`;
2. ID 必须落在合理范围(`> 0` 且 `< 10^12`)。**用户自己导入/购买的文件不是目录曲目**,它的
   `uniqueIdentifier` 是任意 64 位本地持久 ID——实测同一张本地导入专辑上两首歌分别拿到
   `-3446272063698972557`(负数,直接 lookup 是 HTTP 400、取绝对值是 0 results)和
   `2764576100379992737`(**正数**)。所以光判 `> 0` 不够:那个正数会让每首本地导入曲目都白发一次
   iTunes 请求,上界那一半就是为它设的(现役目录 ID 是 10 位数量级,留三个数量级余量);
3. 拿回来的结果要**自校验**:曲目名**逐字同名**(`normLoose` 相等)+ 专辑名 `albumScore ≥ 100`
   (本地没有专辑标签时只校曲目名)+ **音轨号**(两边都拿得到时必须相等)。
   ⚠️ 曲目名这一条 2026-08-22 从 `lyricTitleAccepted` **收紧**成逐字同名(对抗性复核订正):
   那个函数的第二档会把双方各自 `stripParens` 之后再判相等,于是**同一张专辑上的括号兄弟轨
   互相判等**,专辑名又必然相同,锚点照样「成立」——把差 40~47% 的时长当成权威值。实测(全部
   来自用户自己的资料库):`XSCAPE (Deluxe)` #8「Xscape」244.9s vs #16「Xscape (Original
   Version)」344.4s;`BADモード` #13「Face My Fears (English Version)」219.1s vs
   #14「(A. G. Cook Remix)」322.0s。音轨号那一条则是给**完全同名**的兄弟轨准备的
   (同专辑 #1 与 #17 都叫「Love Never Felt So Good」,234.9s / 245.7s)。锚点是按 ID 认身份的,
   压根不需要歌词检索那套宽松匹配。残余风险:本地拿不到音轨号时完全同名那一对仍会放行
   (时长差通常只有几个百分点,远小于括号兄弟轨那 40%+)。

**它治的是什么**(⚠️ 适用范围 2026-08-22 订正,原文夸大了):锚点成立时,`duration` 用 Apple 目录的
权威值,不用这份快照报的 —— **但这行覆盖只作用在 media-control 这份快照上**。Apple Music 在
`player=auto` 下走 `getAutoDetectedState`,它拿到 AppleScript 的 state 就 `return state`,把这里
改过的 `raw` 整份丢掉;`player` 手动选成 Apple Music 时更是连 `fetchRawMediaControlState` 都不调
(那种模式下**连锚点索引都不建**,歌词检索那半边也一起失效)。所以对 Apple Music 而言,时长覆盖
只在 AppleScript 那条路不可用时才真正生效。

这不是位置放错了:要治的「脏快照」是 **media-control 专属**的形态(AppleScript 直接问 Music.app
要 `duration of current track`,不会串),而且 AppleScript 给的精度还更高(实测 289.7659912109375
vs 目录 289.766),拿目录值去盖反而是降精度。覆盖就该待在产生那个 bug 的那份快照上。

正常情况两者逐位相等,只有撞上 media-control 的**脏快照**才会差开——换曲/预载窗口里它会把**下一首**的时长
和当前曲目的标题拼进同一份快照(第 09 章「升级重试」那段记的实锤:「开不了口 (Live)」272.973s
开播 6 秒后快照携带下一首「床边故事 (Live)」的 220.239s)。而自校验要求曲目名对得上,所以锚点
给的一定是**当前这首**的时长:实测 Apple 目录里「开不了口 (Live)」= 272.973、「床边故事 (Live)」
= 220.24,脏时长在源头就被顶掉了。两种走向都安全——`uniqueIdentifier` 跟着当前曲目 → 校验通过
→ 顶掉脏值;跟着下一首 → 曲目名对不上 → 锚点作废、退回现状(第 09 章那道 30 秒同值去抖照旧兜底)。

**时长是唯一被覆盖的字段**:标签本身没有"脏"的已知形态,而且换掉它会牵动缓存 key。

**缓存没命中时不阻塞**:poll 主循环(5 秒一轮,同时负责播放位置跟踪)只读缓存,没命中就发一次
后台补取、本轮按现状走,下一轮就热了。在这条路径上同步等一次对外 HTTP 等于把网络抖动直接变成
"进度卡住"——这个项目已经为同一个理由把 `poll()` 的对外提交异步化过一次。同一个 ID 查空
3 次之后不再试(计数只在内存里,不落盘)。

## 设置项

| 设置页位置 | 项 | 改什么行为 |
|---|---|---|
| 播放器 tab | 播放器(Picker,5 档) | 写 `features.player` → `lyrimuse-features.json`;App 侧下一轮轮询即生效(每轮现读);collector 只在启动时读一次,需重启采集服务才跟上 |
| 播放器 tab | Apple Music 自动化(权限卡,仅选 Apple Music 时出现) | 查/请求 TCC 自动化权限;没有它 Apple Music 路径完全读不到播放状态 |
| 播放器 tab | 后台采集服务(状态卡) | 启用 collector(歌词/封面解析、scrobble 的来源);本章数据源不依赖它跑轮询,但歌词内容全来自它写的缓存 |
| 播放器 tab | 打开 Lyrimuse 时启动 X(.auto 时隐藏) | App 联动,`AppSettings.launchMusicOnLyrimuseOpen`;.auto 无唯一目标 App 故隐藏 |
| 播放器 tab | 跟随 X 启动 / 跟随播放器启动 | 写 features;由 collector 的 companionlaunch.go 盯播放器进程拉起 Lyrimuse(.auto 时盯全部四个) |

引导页 `playerChoiceStep` 是同一个 `features.player` 的另一入口。

## 与其它功能的交互

- **collector 独立取数(重要)**:采集器(`lyrimuse-collector/system.go` 的 `getState`/`getAppleMusicState`/`appleMusicPosition`/`spotifyPlayerPosition`、`poller.go` 的 `updatePosition`)是同一套设计的**独立实现**——同样按 features.Player 分派 AppleScript/media-control 两条路、同样的 .auto 检测、同样的 Spotify 位置直查修正、同样的位置平滑思路。两边各自 fork 各自的子进程,互不共享读数;collector 喂 ListenBrainz/网页/歌词解析,本章的 `LocalPlaybackSource` 喂桌面展示面。**改一边只修一半**(Spotify 位置修正就踩过:只改了采集器,悬浮窗还是慢)。
- **歌词同步**:`apply()` 换歌/缓存内容变化时经 `EnrichCacheReader.lookup` 重读 collector 写的歌词缓存,灌进 `LyricsSyncEngine`。**解码全程后台**(2026-08-20 性能审计):缓存是全库单文件(11.6MB/900+ 条、永不清理),collector 给任何一首歌写盘都 bump mtime,原来 mtime 一变就在主线程同步整读+decode(实测 32-47ms/次,专辑预取期每 2s 一停,正撞 20Hz tick 和 30Hz 填色,是播放中肉眼可见卡顿的最大单一来源)——现在 mtime 变化先原样返回旧缓存(陈旧 ≤2s),后台世代号解码完成后主线程原子替换;apply 的触发键是**已解码代**的 `decodedContentVersion` 而不是文件即时 mtime(拿文件 mtime 触发会在 stale 窗口提前吃掉变化,解码完成后就没人再触发 reload 了)。两个例外仍同步解:首次(冷启动/内存压力清空后,保「启动即有词」)和「歌词管理」保存/删除后的 `reloadNow()`(用户显式操作必须立刻读到,并作废在飞的后台结果)。后台解码采纳新内容即经 `onContentAdopted` 回捅一次 poll(否则陈旧窗口是两拍:kick 一拍+发现一拍,暂停档最坏 12s);内存压力清空同时推进世代号(不推进的话在飞解码回来会把刚让出的缓存灌回,极端时序还会倒退一版)——压力让出只在空闲态长效,播放期下一拍就冷启动式重建,是如实记录的取舍。统计页的 `refreshLocalCoversIfCacheChanged` stamp 也改用已解码代版本(用文件 mtime 会在空闲态把变化盖章烧掉)。looseMatch 的全表繁简扫描换成惰性 `cachedLooseIndex`(looseKey→字典序最小原 key,与派生索引同寿命);内存压力(warning/critical)时整个缓存让出(~21MB),下一拍冷启动式重建。解码失败保留旧缓存,下一拍自然重试。`hasLyricsContent`/`isCurrentTrackInstrumental`/`currentTrackHasNoLyrics`/`collectorNetworkDown` 四个互补信号决定各 View 显示"搜索中/纯音乐/无歌词/网络不可用"(分支顺序敏感,详见歌词解析章)。
- **歌词时间轴偏移**:`nudgeLyricsOffset`/`resetLyricsOffset`/`setGlobalLyricsOffset` 经 `LyricsOffsetStore` 存取,`currentLyricsOffsetMs`(实际生效总偏移=全局基准+单曲微调)与 `trackLyricsOffsetMs`(仅单曲部分)分开发布——菜单标题/重置按钮认后者,对齐播放位置的计算认前者。
- **封面与取色**:换歌时经 `MediaControlClient.fetchArtwork`(统一走 media-control,含 Apple Music)异步取一次封面,带 payload 曲目标识核对 + 递增重试 + 3s 兜底过期 + 3s 后二次确认;`artworkAverageHex` 供"跟随封面"外观模式,提亮/对比处理按消费面(灵动岛 vs 桌面悬浮)在 `PlaybackCoordinator` 分别做。
- **播放控制 UI**:悬浮窗/灵动岛按钮、全局快捷键经 `PlaybackCoordinator` → `MusicPlaybackController`;按钮显隐依赖 `supportsExtendedControls`/`favoritedState()` 返回 nil 与否。
- **App 联动**:`PlaybackPlayer.bundleIdentifier` 同时被 `AppDelegate`("打开 Lyrimuse 时启动播放器")使用;.auto 返回空字符串使该联动自然 no-op。
- **锁屏**:`AppDelegate` 订阅锁屏通知 → `setScreenLocked`,只停渲染 tick 不停轮询,保 scrobble 数据。
- **诊断导出**:`lastResolvedBundleID`(非 @Published,导出那一刻读一次)。

## 数据与文件

| 对象 | 路径/形态 | 读写方 |
|---|---|---|
| 播放器选择等 features | `~/.config/lyrimuse/lyrimuse-features.json` 的 `player` 字段 | App 侧 `FeatureSettingsStore` 写(原子写)、`PlaybackPlayerPreference` 每轮轮询读;collector `features.go` 启动时读 |
| media-control 工具链 | app bundle `Contents/Resources/media-control/`(bin/lib/Frameworks 相对路径子树) | `MediaControlClient.binaryPath()` 解析,读状态/封面/事件流/控制指令共用 |
| 歌词缓存 | collector 维护的 enrich 缓存文件(经 `EnrichCacheReader`,按 mtime 判变化) | 只读(本章视角) |
| Apple 目录锚点缓存 | `~/.config/lyrimuse/lyrimuse-apple-catalog-cache.json`(曲目 ID → 权威元数据,永久,只存查到了的) | collector `applecatalog.go` 读写;`search-lyrics` 子命令只读 |
| 子进程 | `/usr/bin/osascript`(JXA/AppleScript)、`media-control get/stream/test/seek/toggle-play-pause/...` | fork-per-call;stream 是常驻子进程 |
| TCC 自动化权限 | 系统 TCC 数据库(Lyrimuse→Music.app 一条;collector 另一条独立记录) | `MusicAutomationPermission` 查/请求 |
| App 联动开关 | `AppSettings`(UserDefaults)`launchMusicOnLyrimuseOpen` | App 侧读写 |

进程边界:App(lyrimuse)与采集器(lyrimuse-collector,launchd 常驻)各自独立读播放器,唯一交换面是 features JSON 与歌词缓存文件。

## 代码锚点

| 主题 | 文件 + 符号 |
|---|---|
| 数据源主状态机(轮询/apply/清理/seek/偏移) | `lyrimuse/Sources/LyrimuseCore/Local/LocalPlaybackSource.swift` · `LocalPlaybackSource`(`poll`/`apply`/`clearIfWasPlaying`/`seek(toMs:)`) |
| 位置平滑/伺服/棘轮 | 同上 · `resolvePositionSeconds`/`servoDecision`/`shouldRatchetForward`/`shouldRejectStalePositionAfterSeek` |
| 通知/事件去抖动与冻结 | 同上 · `startObservingPlayerInfoNotification`/`handlePlayerInfoChanged`/`freezeExtrapolationUntilNextPoll` |
| 快照读取双路径与 .auto | `LyrimuseCore/Local/MediaControlClient.swift` · `MediaControlClient.fetchSnapshot`/`fetchAppleMusicSnapshot`/`fetchAutoDetectedSnapshot`/`ageCompensatedCachedElapsed` |
| Spotify 位置直查与 gapless 回扣 | 同上 · `spotifyPlayerPosition`/`rebasedSpotifyPosition`/`spotifyPreloadDelta`/`fetchRawMediaControlSnapshot` |
| 封面取图(含曲目标识核对) | 同上 · `fetchArtwork`;`LocalPlaybackSource.fetchArtworkForCurrentTrack` |
| 快照结构与 trackKey | `LyrimuseCore/Local/MediaControlSnapshot.swift` · `MediaControlSnapshot` |
| 播放器枚举与设置读取 | `LyrimuseCore/Local/PlaybackPlayer.swift` · `PlaybackPlayer`/`PlaybackPlayerPreference` |
| 事件流常驻子进程 | `LyrimuseCore/Local/MediaControlStreamWatcher.swift` · `MediaControlStreamWatcher` |
| 通道健康自检 | `LyrimuseCore/Local/MediaControlHealth.swift` · `MediaControlHealth` |
| 播放控制写路径 | `LyrimuseCore/Local/MusicPlaybackController.swift` · `MusicPlaybackController`(`dispatch`/`seek`/`setPlaybackMode`/`supportsExtendedControls`) |
| 进度锚 | `LyrimuseCore/Playback/ProgressClock.swift` · `ProgressAnchor.extrapolatedPositionMs` |
| 自动化权限 | `lyrimuse/Settings/MusicAutomationPermission.swift` · `MusicAutomationPermission`(`check`/`requestWithTimeout`/`checkForCurrentPlayerSafely`/`checkAppleMusicSafely`) |
| 设置页播放器 tab | `lyrimuse/SettingsView.swift` · `PlayerSettingsTab` |
| UI 转发层 | `lyrimuse/PlaybackCoordinator.swift` · `PlaybackCoordinator.start` |
| collector 侧独立取数 | `lyrimuse-collector/system.go` · `getState`/`appleMusicPosition`;`lyrimuse-collector/poller.go` · `updatePosition` |
| Apple 目录锚点 | `lyrimuse-collector/applecatalog.go` · `appleCatalogAnchor`/`appleCatalogLookup`/`appleCatalogPlausibleID`/`appleCatalogSearchIdentities`;消费点 `system.go` · `fetchRawMediaControlState` |
| `LyrimuseCore/Local/UnknownPlayerAlert.swift` | 「发现新播放器」的两层判据(纯函数):`shouldOffer` 卡片与通知共用、`shouldAnnounce` 通知专属 |
| `lyrimuse/Settings/UnknownPlayerNotifier.swift` | 系统通知管道:5s 轮询 + 稳定性计数 + 授权 + 投递 + 按钮回调 + `np:unknownPlayerNotices` 落盘 |

## 设计决策与已知坑

1. **事件只当"提前 poll 一次"的信号**,绝不从通知/stream payload 直接喂状态——状态机已有世代号防乱序、位置伺服、计时器生命周期三重微妙性,并行改状态路径是乱序 bug 温床;2 秒轮询永远保留作兜底,任何事件机制失效最坏退化回旧行为。
2. **250ms 去抖动而非"立刻查+节流"**:实测 Music.app 一次操作连发 2 条通知且第一条带旧状态、AppleScript 状态 ~294ms 才切换完;立刻查大概率读到半切换快照还把带新状态的第二条吞掉。
3. **暂停 ≠ 清空**:停止推进(停 20Hz)和清空显示是两回事,暂停保留按冻结位置解出的当前行;真正的全清只发生在 nil 快照(stopped/焦点被抢),且 `lastKey` 必须一起清否则恢复播放后歌词窗口回不来。
4. **QQ 音乐整数秒地板量化推翻了"零均值噪声"前提**:取整偏差单向(只晚不早),EMA 永远够不到门槛,靠前向棘轮(reported > predicted 即证明外推落后)修;反方向维持 EMA 路径。
5. **伺服 EMA 修"锁死偏差"**:纯墙钟外推会把播种毛刺/漏观察的短暂停(< 2s seek 容差)永久锁死(实锤 0.205s 偏差 150 秒纹丝不动);持续同号偏差经 EMA 收敛后一次性校正,且校正必须走 didReanchor 重建锚点,否则到不了屏幕。
6. **Spotify 的 MediaRemote 锚点每首歌只打一次且自然切歌时会打歪**:gapless 自然切歌锚点先于真声 ~0.84s 打好、整曲恒定超前且从不重打——对"每笔读数与外推步调一致的常量偏置",伺服结构性失明,唯一可用的真值是**上一首自己的连续外推**(2026-08-20 校正方案;08-14~08-18 的 playerPosition 直查真值路线已证伪:它自然切歌时同样超前、每首抽签)。
7. **.auto 借用 Apple Music 缓存必须做年龄补偿**:缓存读数老一个刷新周期(~1.8s),不补偿会与 2s seek 容差咬合出"有时正常有时慢"的双稳态(单曲循环重启后必然锁死在慢 1.8s)。
8. **AEDeterminePermissionToAutomateTarget 主线程可能永久挂起**(系统级已知问题),且 Music.app 没在运行时弹窗根本不出现——所有请求走后台竞速+预先后台拉起 Music.app;播放控制入口还要避免"按个暂停却悄悄启动 Music.app"的副作用(不拉起)。
9. **Spotify 脚本必须 running 守卫**:JXA 访问属性会启动 Spotify,三处脚本(本文件位置直查、播放控制、collector)都垫同一道守卫。
10. **锁屏只停渲染不停轮询**:锁屏期间的收听记录是不可恢复数据,省电不值当。
11. **`uniqueIdentifier` 只对 Apple Music 目录曲目是目录 ID**,本地导入/购买的文件放的是任意 64 位持久 ID(实测负数)。所以 Apple 目录锚点对自己导入的曲库天然无效——这不是 bug,是这个字段的语义边界。别的播放器在这个字段里放什么也没有保证,理论上可能撞上一个真实的目录 ID,所以除了 bundle id 守卫,拿回来的结果一律要过曲目名+专辑名自校验。

⚠️待核对:设置为「自动识别」且实际在播 Apple Music 时,playPause/上一首/下一首经 `MusicPlaybackController.dispatch` 走 media-control(只有 seek 有 `preferAppleScript` 覆盖)——代码注释断言 media-control 控制指令对系统 Now Playing 焦点生效、应可控制 Music.app,但仓内未见对这一具体组合的实测记录。
