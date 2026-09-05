# 02. 播放数据源与播放器支持

> 最后核对:2026-09-03 · 基线:e103532+工作树

## 定位

App 怎么知道"现在在放什么":从本地播放器读出 曲目元数据 + 播放/暂停状态 + 播放位置,喂给所有展示面(桌面悬浮歌词、灵动岛、歌词窗口、菜单栏)。支持 Apple Music、QQ 音乐、网易云音乐、酷狗音乐、Spotify 五个播放器,外加"自动识别"。核心是 `LocalPlaybackSource`(单例,2 秒轮询 + 事件加速 + 位置平滑),数据全部本地读取、零网络。

## 入口与展示面

- **设置 → 播放器 tab**(`SettingsView.swift` 的 `PlayerSettingsTab`):「播放器」卡(2026-09-01 起**可多选**,见下面"多选"一节)、「已信任的其它播放器」卡(有信任项才出现)、「与播放器联动」卡(三行逐播放器勾选,见下面设置项表)、「Apple Music 自动化」权限卡(选中集合包含 Apple Music 时出现)、「后台采集服务」卡(含 media-control 通道自检失败提示)。⚠️ 后三张的先后 2026-09-04 调过(用户要求把「与播放器联动」换到「Apple Music 自动化」+「后台采集服务」前面):原来是"权限卡 → 服务卡 → 联动卡",两张只读的状态卡把这页唯一要动手勾选的那张挤到了页尾;现在是"要配的在前、系统状态在后"。`PlayerSettingsTab.body` 里那串卡片的书写顺序就是页面顺序,换顺序=换那几行的排列。2026-08-25「播放器」卡跟引导页换成同一套图标网格(`PlayerChoiceCard`,用户要求两处排版和谐一致),包在 `SettingsCardHeader` + `SettingsRawRow` 里,融入这页"卡片+发丝描边"的既有语言,不是裸摆一个网格;顺带把「已信任的其它播放器」卡里每一行的图标从通用的 `checkmark.seal` SF Symbol 换成这个 App 自己的真图标(`SettingsRow` 新增的 `iconImage: NSImage?` 参数,跟 `icon` 二选一,原有全部调用点不传就不受影响),补了一个同款 `SettingsCardHeader` 标题——两张卡挨在一起时是"姐妹卡",不是"一张换新一张没换"。
- **引导页**(`OnboardingView.swift` 的 `playerChoiceStep` / `automationStep`):首次启动时选播放器;自动化权限步只在选中 Apple Music 时出现在 steps 里。2026-08-25 把 `playerChoiceStep` 从纯文字下拉换成图标卡片网格(`PlayerChoiceCard`,3 列 2 行,后来也被设置页复用,挪进了独立文件 `Settings/PlayerChoiceCard.swift`):优先取**已安装播放器的真实 App 图标**(`AppIconResolver`,跟"正在播放"面板来源角标——`PlaybackCoordinator.resolvedPlayerIcon`——同一份取图标逻辑/缓存,理由也一样:最好认,不用自带商标素材),没装就退回 `PlaybackPlayer.tintColor` + `fallbackSymbolName` 这套占位色块(QQ音乐/网易云音乐/酷狗音乐复用 `sourceColor`——跟"歌词来源"是同一批 App,不维护第二份配色映射)。文案顺带补全:原来的说明句漏了酷狗音乐(2026-08-21 才接入,文案没跟上)。
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
- 设置值经 `PlaybackPlayerPreference.selected` 读取(每次轮询现读共享 JSON 文件,不缓存),类型是 `Set<PlaybackPlayer>`,保证非空;文件不存在/解析失败/值认不出,**兜底 `{auto}`**(2026-08-13 从 appleMusic 改过来:老默认让纯 Spotify/QQ/网易云用户界面永远空白且看不出原因)。

### 多选(2026-09-01)

设置页「播放器」卡从单选改成多选——点一下切换某个具体播放器的选中状态,同时高亮的可以有好几个;「自动识别」也是可以被同时勾上的普通一项,不是跟具体播放器互斥的另一档。

- **数据形状**:共享 JSON 的 `player`(单值字符串)字段被 `players`(字符串数组)取代——Swift `FeatureSettingsStore.players: Set<PlaybackPlayer>`,collector `featureFlagsFile.Players []string` → 解析成 `featureFlags.Players map[string]bool`。旧字段 `player` 只作**一次性迁移源**保留:`players` 缺失/空时才读它,读到就当单元素集合迁移过去;两者都没有可用值最终兜底 `{auto}`。两侧迁移逻辑必须同步维护(Swift `FeatureSettingsStore.load()`/LyrimuseCore `PlaybackPlayerPreference.selected`,Go `resolvePlayers`)。
- **UI 不允许清空**:`SettingsView.toggleSelectedPlayer` 在选中集合只剩一个成员时拒绝取消勾选它——跟 `PlaybackPlayerPreference.selected`/`resolvePlayers`"保证非空"这条不变量对称,不让界面出现一瞬间"什么都没选中"的非法状态。引导页那一步(`OnboardingView.playerChoiceStep`)刻意保持"选一个起步"的单选体验,不受这次改动影响——点一个直接把 `players` **替换**成那一个,多选是留给设置页的进阶能力。
- **解析优先级(App 侧 `MediaControlClient.fetchSnapshot`/`fetchArtwork`,collector 侧 `system.go` 的 `getState`)三级**,跟单选年代的判断树是同一套骨架、只是把"选定播放器"从单值换成集合成员判断:
  1. 选中集合里**包含**「自动识别」(不管是否同时还勾了别的具体播放器,auto 按超集处理)→ 走原有的自动识别路径(`fetchAutoDetectedSnapshot`/`getAutoDetectedState`),行为跟改动前的纯 `.auto` 完全一样,包括"检测到未知播放器"的信任列表机制;
  2. 选中集合**恰好**是 `{Apple Music}`(没有 auto、没有别的具体播放器)→ 跳过 media-control,直接走 AppleScript 直问 Music.app(`fetchAppleMusicSnapshot`/`getAppleMusicState`),跟单选年代完全一样,不多背一次子进程往返;
  3. 其它情况(单选或多选了 QQ音乐/网易云/Spotify/酷狗中的若干个,没有 auto)→ `fetchMultiSelectedSnapshot`/`getMultiSelectedState`:问 media-control 系统级 Now Playing 焦点是谁,核对 bundle id 是否落在选中的这个子集里——跟"自动识别"是同一套"系统只有一个焦点,问一次就知道"机制,区别只在准入名单从"内置五个+信任列表"收窄成"这次选中的这几个"。命中 Apple Music 时同样会尝试借用后台 AppleScript 缓存的精确位置(`refinedAppleMusicSnapshotIfNeeded`/`refineAppleMusicState`,从原来 `fetchAutoDetectedSnapshot`/`getAutoDetectedState` 内联的分支抽出来给这条新路径复用,不重复实现)。
- **"排除自动识别后能不能唯一确定一个具体播放器"这个判据独立成了一个可复用的量**(`Set<PlaybackPlayer>.soleExplicitPlayer`,LyrimuseCore,纯函数):没有具体播放器(纯 auto)或者选了两个以上时是 `nil`。几处"只有能唯一确定时才有意义"的场景都靠它,不各自重新判一遍:
  - `AppDelegate`「打开 Lyrimuse 时顺带唤起播放器」——含糊就不猜,`bundleIdentifier` 退回空字符串(跟单选年代 `.auto` 的 no-op 效果一致);
  - `LyricsWindowView.idlePlayer`(停播欢迎态用哪个播放器的图标/文案)——含糊时退回"停播前最后识别到的那家"这条既有兜底;
  - `SettingsView.companionCard`——「打开 Lyrimuse 时启动 X」这一行含糊时直接隐藏(不猜、不显示读不通的文案),「跟随 X 启动」含糊时文案退回"跟随播放器启动"。**2026-09-03 起这一条不再依赖该判据**:三项联动全部改成逐播放器勾选(`PlayerLinkageRow` 图标芯片,用户原话「现在是支持多选的,那么具体是和哪个播放器绑定呢,所以这块功能也要改为多选才行;设置里也要重新设计」),含糊场景不存在了,见下面设置项表「与播放器联动」三行。
  - collector 侧对称的是 `companionlaunch.go` 的 `companionLaunchProcessNames`——auto 在选中集合里就盯全部五个已知播放器的进程,否则逐个选中成员各自的进程名都盯(不再局限于唯一一个)。
- **「Apple Music 自动化」权限卡的展示条件放宽**(`SettingsView.permissionCard`):从"恰好只选了 Apple Music"放宽成"选中集合包含 Apple Music"(不要求排他)——多选场景下 Apple Music 那条 AppleScript 路径照样会被走到(见上面判断树第 3 步),用户仍然值得在这里管理这份权限。`dispatch()`(播放控制写路径)和 `checkForCurrentPlayer`/`checkForCurrentPlayerSafely`(自动化权限的按需检查)则**保持要求排他**(`PlaybackPlayerPreference.isExclusivelyAppleMusic`,即 `selected == [.appleMusic]`)——这两处要的是"能不能武断地把指令/权限检查直接导向 Music.app、不经过系统焦点仲裁"这个更强的确定性,多选/auto 场景下应该让 media-control 的焦点仲裁生效,不能因为用户也勾了 Apple Music 就抢着直连。
- **同源歌词加权也从单值变成集合**(collector `match.go`):`nativeLyricSource string` → `nativeLyricSources map[string]bool`,`resolveNativeLyricSources(players)` 把选中集合里每个成员各自的原生歌词源都收进来(Apple Music/Spotify/auto 不贡献任何源)——同时用 QQ 音乐和酷狗听歌的人,两边的同源加权都该生效,不能只挑其中一个。
- **ListenBrainz 的 `media_player` 标签**(collector `mediaPlayerLabel`)顺带简化成纯粹按**这一条具体 listen 实际观察到的 bundle id** 判断,不再区分"自动识别"和"手动选定"两套分支——单选年代那道 `features.Player` 分支背后的假设是"手动选定时 bundleID 只可能是选中的那一个",多选之后这个假设不成立(bundleID 可能是选中集合里的任意一个),两个分支本来就是同一份映射抄了两遍。
- **「网页播放器」卡的配对同样接进了这套多选/信任机制**,且现在有了跟「播放器」卡对称的"选中并高亮"视觉——完整细节见下面「网页播放器」卡一节最后一条(2026-09-01 那条)。两张卡标题都加了「（可多选）」字样(`SettingsCardHeader` 的 `title`)。

### 自动识别(.auto)

`MediaControlClient.fetchAutoDetectedSnapshot`:

1. 问 media-control 当前系统级 Now Playing 是谁;bundle id 既不是五个内置播放器、也不在**用户信任列表**里(网页视频、Safari 等)→ 视为"没有可关心的正在播放"。判定是 `TrustedPlayers.isAccepted`,跟 collector 的 `isAcceptedPlayerBundleID` 同一套语义,两侧必须同时改。
2. 检测到 Apple Music 时,**不在本次调用里同步跑 AppleScript**(那样单次轮询耗时翻倍、扩大乱序竞态窗口),而是后台异步刷一份 AppleScript 快照缓存,下一轮轮询借用它更精确的 `elapsedTime`——精度提升晚一个周期(~2s)体现。
3. 借用缓存有三道守卫(`ageCompensatedCachedElapsed`,纯函数):缓存必须是同一首歌(标题+歌手都对上);双方都在播放(暂停不借:冻结的 elapsedTime 本身就精确);缓存值按"读数年龄 × 播放速率"外推到当下后,跟这次的新鲜读数差 ≤2s 才可信(超过说明缓存跨越了 seek/单曲循环重启)。任何一道不过就退回 media-control 自己的读数——精度让位于正确性。
4. 后台缓存刷新只在**正在播放**时发起(暂停时刷出来的缓存结构上不可能被借用,白 fork osascript)。

### 信任列表:自动识别不限死内置 App(2026-08-21)

- **要解决的问题**:`.auto` 原来只认写死的那几个 bundle id,任何别的播放器(Foobar、AlgerMusicPlayer、第三方客户端、以后出现的新 App)在放都被当成"没有可关心的播放"。
- **为什么不是"一律接受"**:那道白名单**同时挡着打卡**(`poller.isTracked`)。一律接受 = YouTube 视频、播客、网课被当成收听写进 Last.fm / ListenBrainz 的**永久历史**,并往"设计上永不清理"的歌词缓存灌垃圾条目、白烧全源查询。而"靠内容形状分辨是不是音乐"不可靠:浏览器里的网页播放器能用 MediaSession API 自己填 title/artist/artwork,一个 YouTube 音乐视频跟一首歌长得一模一样;`mediaType` 也指望不上(实测酷狗压根不报这个字段)。
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
- **YouTube Music 的破例:改问页面本身是不是在放广告(2026-09-02)**。上面那条守卫把**浏览器里的 YouTube Music 整个挡在门外** —— 用户报「为什么我现在用 chrome 播放的 YouTube music 不能识别到」,根因就是它经 MediaSession 报出来的 album **常常是空的**,正好踩在上一条写明的那个"代价"上。⚠️ 是"常常"不是"总是"(2026-09-02 实测订正,初版把它写成了"恒为空"):同一个 Chrome 里播 YT Music,「死神」「September」的 album 是空的,而「Bad」报的是 `The Essential Michael Jackson` —— 所以这不是"YT Music 一律进不来",是"看运气",报了专辑名的那些本来就能进。**"看运气"这四个字 2026-09-03 有了确切答案:空的是每条播放队列的第一首**(实测两张专辑四个采样,含一条排除"同名去重"的关键反例)——机制、补法和那张实测表见「设计决策与已知坑」第 17 条。Chrome 已在信任列表、media-control 也读得到,卡的纯粹是 album。

  ⚠️ **不能简单地"给 `music.youtube.com` 免检 album"** —— 因为 album 那一条**同时也在挡广告**。2026-09-02 抓了两条真实广告(media-control 与页面 JS **同一时刻成对采样**):

  | title | artist | album | duration |
  |---|---|---|---|
  | 「Liese Jelly to Bubble 全新登場!染髮新革命」 | `KAO Hong Kong` | `""` | **30.021** |
  | 「趁早把握出生頭3年腦部發育黃金期…」 | `香港美贊臣 Mead Johnson` | `""` | 20.001 |

  **artist 是非空的**(广告主的频道名),免检 album 之后这两条会畅通无阻地被当成"KAO Hong Kong 的一首歌"收下 —— 跟第 09 章记的 Spotify 事故同形态(用户曾在「最近播放」看到 `Now Streaming on Hulu.`)。⚠️ **别指望 `minTrackSecs = 30` 兜住**:那条 Liese 广告是 **30.021 秒**,比 30 秒地板高 21 毫秒,照样过闸(打卡阈值 `min(时长/2, 240)` = 15s,播满就超)。YouTube 的标准 30 秒广告位基本都这样贴着线过去。

  所以改成**问页面本身**,思路同 `spotifyCurrentTrackIsAd`(问 Spotify 本尊要 `spotify:ad:` 前缀)—— 字段启发式分不出来的事,去问权威来源。YouTube 没有对应的 AppleScript 接口,问的是页面 DOM。同一批成对采样里,**22 个连续样本、横跨两条不同广告**:

  | 信号 | 广告期间 | 真歌期间 |
  |---|---|---|
  | 播放器 class 含 `ad-showing` | 22/22 命中 | 0 |
  | 广告徽章元素存在 | 22/22 命中 | 0 |
  | `document.title` | 「YouTube Music」 | 「歌名 \| YouTube Music」 |

  三个都读、**任一命中就算广告**(不取多数):误判成广告只是这一轮没识别(下一轮自我纠正),误判成歌是把广告永久写进 Last.fm。`document.title` 那条已知有一个假阳性(页面刚加载、还没开始播时标题也是裸的「YouTube Music」)—— 接受它,此刻本来也没有播放可言;留着它是因为它是另外两条的**兜底**,YouTube 哪天改了 class 名它还在挡。

  落点(`YouTubeMusicAdProbe.swift` / `ytmusicad.go`,**两侧同一份判据、必须同时改**):
  - 基础判据 `notASong` / `trustedPlaybackNotASong` **原样不动**,复核作为外面一层(`trustedPlaybackRejected`)。只在"基础判据要拒、而且唯一理由是 album 为空(artist 非空)"时才复核 —— artist 为空一律直接拒、不复核,顺带省掉一次 AppleEvent。
  - **fail-closed**:**还没探到/读不到**(权限没开、标签页休眠、TCC 没授权、超时)一律拒,退回原判据。所以最坏情况是"YouTube Music 仍然不被识别",不是"广告漏进收听历史"。
  - ⚠️ **判定为广告时,Swift 与 Go 故意不对称(2026-09-03 改)**:Go 侧照旧**拒**(不采纳、不上报);Swift 侧改成**放行、并标成广告**,让 UI 显示「广告中」。起因是用户要求"chrome 上播 YouTube Music 的广告也像 Spotify 那样显示出来是广告"——原来一起丢掉的话 UI 拿不到任何东西,一段 30 秒广告期间灵动岛/悬浮窗会整个塌成"没有在播放"、广告完了再弹回来。这跟 Spotify 广告一直以来的形态一致(快照照常流进来、由 `isCurrentTrackAdBreak` 标记驱动 UI,打卡在别处拦)。三条出口收在纯函数 `YouTubeMusicAdProbe.gate(artist:verdict:)` 里(selftest 覆盖),详见第 20 条。
    ⚠️ 注意这条**只**破例在"复核这一层";基础判据 `notASong` / `trustedPlaybackNotASong` 仍然必须逐字一致。
  - Swift 侧是**异步 kick + 读缓存**(`MediaControlClient` 整个类型是同步的,不能被一次 ~187ms 的 AppleScript 往返卡住),照 `BrowserPositionProbe` 那套范式。代价是新曲目第一轮拿不到判定、按 fail-closed 拒掉,下一轮就好 —— 跟那个探针"新曲目要等下一轮探测成功"是同量级的延迟。
  - 只在 `music.youtube.com` 的标签页上执行,**普通 `www.youtube.com` 视频完全不受影响**,仍按 album 判据挡掉。
  - selftest 有一条**跨语言防漂**守卫:直接读 `lyrimuse-collector/ytmusicad.go` 对账那几个标志串和 AppleScript 事件超时值。加机械闸的理由是"两边必须同时改"这句话已经在注释里写着了、但注释拦不住漏改(验证过:把 Go 侧超时改成 7 会当场 FAIL)。2026-09-03 在它旁边补了一条**更硬的**:把两侧的探针 JS 取出来**逐字比**——marker 那条挡不住"关键字都在、JS 却已经漂了",实测把 Go 侧 `browse/MPREb` 改成 `MPREc` 时 marker 守卫**没逮到**(同一文件的注释里还写着那个串),逐字比那条当场红。

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

### 「网页播放器」卡:平台 ↔ 浏览器配对

上一节那套锚点订正治的是"报的数不准";这张卡治的是另一半——**让浏览器把真实播放进度报出来**。做法是用 AppleScript 让浏览器执行一小段 JavaScript 去读页面里的 `<audio>/<video>` 进度(`BrowserPositionProbe`),所以它对浏览器有两个硬要求:①系统级 Automation/TCC 授权(另一张 `permissionCard` 管);②**浏览器自己**那道"允许 Apple Events 里的 JavaScript"开关(`BrowserAutomationPermission`,Chromium 系存在自己的 Preferences JSON 里、Safari 走 `CFPreferences`,两套完全独立的实现)。

⚠️ **读到"错的标签页"要挡住,但判据绝不能拿 MediaRemote 报的位置当参照物。** 这一条 2026-09-02 加了一版**错的**、当天就被真机抓出来重写,两版都记在这里,因为踩的坑比结论有用。

**要挡的现象**(2026-09-02 实测撞上):Spotify Connect 会把同一账号的其它标签页变成**遥控镜像**——标题带着 ` • ` 分隔符、播放键显示暂停图标、位置文字也在,**三条判据全说"正在播放"**,而那个位置可以卡死十几秒不动(实测:Safari 已放到约 35 秒,Arc 里同一张专辑的标签页 15 次采样一直读 7 秒)。跨浏览器那种被 bundle id 挡住了(`kickIfNeeded` 只对当下真在出声的浏览器发起探测);**挡不住的是同一个浏览器里开着第二个 Spotify 标签页**——规则先试当前标签页,当前那个若正好是陈旧镜像或只是在浏览专辑,它就会赢。

**❌ 错的那版:`isPlausibleCorrection(probed:reference:)` —— 差 8 秒以上就弃用,`reference` 传 `snapshot.elapsedTime`。** 它把整个探针**对所有网页播放器整首歌废掉了**,而且一行日志都没有。原因就写在本文档上一节:锚点冻结的源 `elapsedTime` **恒为 0**。于是 `abs(probed - 0) <= 8` 退化成 `probed <= 8` ——**只有页面真放在前 8 秒内的修正才会被采纳,过了第 8 秒一律弃用**;消费又是每首歌一次性的(`consumedKey`),整首歌都跑在错的外推锚点上。现场:Chrome + music.youtube.com,`elapsedTime` 三次采样恒 0、`timestamp` 恒定不动,用户报「歌词进度不准」。

  - ⚠️ **教训不是"参照物选错了",是"这里根本没有可用的参照物"。** 换成外推值同样不行:探针最该出手的场合恰恰是"锚点本身就是错的"(冷启动时歌已经放到两分钟、MediaRemote 报 0、锚点也从 0 起),那时外推值 ≈0 而探针读 120,拿它当参照会**恰好在探针最该生效的场合**把它挡掉。
  - ⚠️ **selftest 当时不但没拦住,还把这个 bug 固化成了断言**:那张表的放行用例写成 `(probed: 0.23, reference: 0.0, true)` / `(1.60, 0.0, true)` / `(8.0, 0.0, true)`,`reference` 一律填 0——等于把"锚点误差 0.23s"顺手写成了"reference=0, probed=0.23",而真实场景里 `reference` 恒为 0、`probed` 是几十上百秒。**把参照物写死成常数的用例,证明不了任何跟参照物有关的判据**,它只是把写用例时的假设复述一遍。

**✅ 现在这版:不问"离参照物多远",改问两件探针自己拿得出材料的事。**

  1. **这个标签页放的是不是同一首歌** —— 页面显示的总时长跟 MediaRemote 的 `duration` 比,容差 `pageDurationToleranceSecs = 2` 秒(页面显示 `floor(总时长)`、MediaRemote 给小数,实测 `218.781` 对页面 `3:38`=218,固有差不到 1 秒)。⚠️ 这道比较做在 **JS 里**、不在 Swift 里:差一首歌的标签页要让 AppleScript 那两遍循环**继续往下找**,否则"陈旧镜像排在正在放的那个标签页前面"时后者永远轮不到。期望时长拿不到(传 0)或页面读不出总时长时**跳过这道检查**,不判否——失败方向保持"最坏也不过是回到没有这道检查的样子"。
  2. **这个标签页的钟有没有在走** —— 隔 `livenessGapSeconds = 1.5` 秒采两次,要求整秒读数至少 +1(`pageClockIsRunning`)。陈旧镜像的特征恰恰是**它不动**(实测 15 次采样一直读 7 秒)。⚠️ 间隔必须 **> 1 秒**:读数只有整秒精度,间隔不到一个量化步长时"没前进"分不出是钟停了还是没跨过整秒边界。⚠️ 判据用"floor 有没有 +1"而不是"增量 ≈ Δt×rate"——读数本来就是地板量化的,拿它比连续量要给的容差大到没有区分力。⚠️ 两次采样必须是**两次独立的 osascript 运行**,不能在 AppleScript 里 `delay`:`probeTimeout` 是 3 秒硬超时,脚本里睡 1.5 秒会把预算吃掉一半。

  - **代价**:纠偏比原来晚约 1.5 秒落地。可接受——`consumeCorrection` 按 `rate * age` 补偿滞后,落地的**值**仍然是对的;正常换下一首时未纠偏位置本来也≈0,看不出差别,真正吃到这 1.5 秒的只有"冷启动时歌已经放到一半"这种本来就要等探测往返的场合。
  - **有界重试**(`maxProbeAttempts = 3`,退避 `probeRetryBackoffSecs = 3` 秒,从上一次探测**结束**算起):判"钟没在走"可能是瞬时的(页面缓冲、标签页刚切到后台还没跑满一个计时周期)。这类失败**不消费**那次一次性额度——判据在探针内部,拿不到值就不写缓存、`consumeCorrection` 自然不会置 `consumedKey`,所以重试是自动的;上界只是别让一个读不到的标签页被整首歌每轮 tell 一遍。⚠️ 这一点是**旧版真正的第二个坑**:旧版把判据放在消费点,不合理的那次**也算用掉了额度**,一次瞬时抖动就赔掉整首歌。
  - ⚠️ **广告是这套判据认不出来的那一类,只能靠时长兜**:YouTube Music 插广告时页面那行进度文字是**广告自己的**、而且**是在走的**,活性判据对它一路放行。
  - ⚠️ 仍然漏的:时长恰好相同的另一首歌 + 它的钟也在走。这时两条判据都判不出来,只能靠 bundle id 那道门。
  - 2026-09-02 补了日志(`category: "browserprobe"`):采信和弃用两边都记,弃用带原因。⚠️ 这不是锦上添花——上面那次退化就是因为**这个类一行日志都没有**,"日志里查不到探针活动"完全不能当"它没跑"的证据,只能靠读代码 + 量 media-control 反推。

#### 怎么查这个探针(2026-09-03 真机复量后补)

```
/usr/bin/log show --predicate 'subsystem == "me.yudaotor.lyrimuse" AND category == "browserprobe"' --last 20m --style compact
```

⚠️ **`log` 必须写绝对路径 `/usr/bin/log`** —— zsh 里 `log` 是个 builtin,直接写 `log show …` 会报 `(eval):log:1: too many arguments`;要是命令里还带了 `2>/dev/null`,这条报错会被吞掉、只剩一片空输出,**极容易误判成"探测压根没发起"**而往完全错误的方向查(2026-09-03 实测踩过)。同源于 CLAUDE.md 里那条"`grep` 被 shell 污染要用绝对路径"。

三行日志各自证明什么,别混:

| 日志 | 打在哪 | 证明什么 |
|---|---|---|
| `采信 Xs(上一拍 Ys,…)` | 探针内部,写缓存那步 | 拿到了一个**通过两条判据**的读数 |
| `交出纠偏 Xs(…),本曲额度用完` | 消费点 `consumeCorrection` | 这个值**真的交给伺服逻辑用了** |
| `曲目标识变了,重新开放本曲的探测额度` | `trackChanged()` | 一次性额度被**重新开放**了 |

⚠️ **只看"采信"会读出假结论**:同一首歌可能出现好几行"采信"却只有一行"交出",一次性额度(`consumedKey`)把后面几次挡在门外;光看"采信"会以为重锚了好几次,也看不出这一拍的位置到底是探针给的还是外推的。

⚠️ **一首歌中途出现多轮探测不一定是 bug,但要看清是哪一种。** 2026-09-03 复量实测到同一首《白发》连续播放期间出现 4 次 `采信`(位置 12/74/134/194s、间隔约 60s、**全部标着 `#1`**)—— 标 `#1` 说明重试计数被重置过,也就是 `trackChanged()` 真的被调了 4 次。

- ✅ **已排除 App 重启**:这四行日志的 pid 全是 `72772`,同一个进程(⚠️ 查这类问题一定要看 pid ——同一段日志里 00:01:59 和 00:03:02 那两行 pid 从 64957 变成 66917,那两次**才**是重启导致的重开,长得跟前面四行一模一样)。
- ❓ **剩下两个候选还没分清**:`trackChanged` 的判据是 `key != lastKey`(`key` = artist+title),所以要么是 ①`lastKey` 被清成了 `""` —— 快照变成 nil(播放器退出 / stopped / 系统 Now Playing 焦点被别的 App 抢走一次)那条路径会清它,见 `LocalPlaybackSource` 里 `lastKey = ""` 一带的注释;要么是 ②artist/title 本身在抖(网页播放器元信息刷新)。
- 2026-09-03 起 `曲目标识变了` 这行日志会带上**旧 key 和新 key**,一眼就能分:**旧 key 为空 = ①**,旧 key 非空且跟新的不一样 = ②。下次撞见照着读即可,别再靠猜。

⚠️ 目前**没有把它当 bug 修**,理由是:每次重开都会重新拿一份**当下的**地面真值,再走同一套 `groundTruthSnapToleranceSecs` 重锚路径,精度上是加分不是减分;它跟 2026-08-30 那次"每 0.9 秒用整秒读数覆盖一次连续外推"的回退**不是一回事**(那次是高频覆盖更准的源,这次是低频注入更准的值)。等日志把成因定死了再决定动不动它。

#### ⚠️ 验收这个探针时,界面抓拍**不是**有效证据

2026-09-03 复量时差点栽在这里:抓悬浮窗看到显示的歌词行跟探针位置对得上,看着像端到端验证 —— 但那一次的冻结锚点**恰好也是对的**(`timestamp` 冻在 00:05:43,而那正是这首歌真实开始、App 重启并注册元信息的时刻,`now − timestamp` ≈ 真值)。**换句话说那一次即使不修,界面看起来也一样对。** 界面抓拍只证明内部自洽,证明不了修复改变了可见结果。

真正有区分力的证据是**日志里的数值本身**:实测那四次采信的位置是 12/74/134/194s,**全部远超旧守卫那 8 秒窗口**,即修复前这四次无一例外会被弃用。这类"新旧判据会给出相反结论"的样本才是验收标准。

⚠️ **2026-09-02 用真机日志坐实:这条一次性纠偏此前几乎从不生效,已修**。两处病根:

1. **一次性样本走了给周期性噪声源设计的闸门。** `servoDecision` 对 `noisyFloored` 是 alpha 0.3 / 门槛 1.0,单个样本最多把 EMA 推到 `0.3 × 误差` —— 要误差超过 **3.33 秒**才可能触发。实测连着三首歌 `ema=-0.206 / -0.226 / -0.219, snap=false`,探针每次都测出偏差、每次都被扔掉。修法是在 `resolvePositionSeconds` 里给它开一条专门路径(`groundTruthSnapToleranceSecs = 0.30`,不走 EMA,命中打 `browser probe reanchor` 日志)。⚠️ 位置必须排在冻结守卫和 seek 分支**之后**、前向棘轮**之前**。
2. **读数自带 −0.5 秒系统偏置。** 页面显示的是 `floor(真实位置)`,直接采信 `n` 恒偏后。补 `flooredMidpointBiasSecs = 0.5` 取区间中点变成无偏估计。

- **"页面是 floor 不是 round"是实测坐实的,不是假设**:用 `media-control pause`(暂停那一刻 MediaRemote 记的是精确位置)抓小数 ≥0.5 的样本 —— `elapsedTime=165.627` 而页面文字是 `165`(round 会是 166)。
- **页面文字滞后真实位置 ≤0.05 秒**(同一手法 10 个样本,`T − displayed` 均匀铺满 0.051~0.916,最小值即滞后上界)。所以"抓文字跳变瞬间"可以当精确到 ±0.05s 的真值标尺用 —— 今晚所有偏置数字都建立在这个标尺上。
- ⚠️ **别拿"字级高亮反推的位置"当位置链路的误差**:那个量的是「位置误差 ⊕ 歌词文件自身对齐误差」。实测同一张 Live 专辑上,修复前后帧法都得到 ~+0.86s,而同期日志里的 `reported − predicted` 从 −0.685 降到 −0.269 —— 差值不随修复变化的那部分,是歌词文件的对齐,不是位置链路。判位置链路要看日志那一对数。

**已支持的站点(2026-09-01 起两个)**:`music.youtube.com` 和 `open.spotify.com`。

⚠️ **新增一个站点必须实测,不能照抄另一条规则** —— 这两条实测下来"看着一样、其实处处不同",照抄任何一条都会得到一个静默不工作的配对:

| | YouTube Music | Spotify Web |
|---|---|---|
| 进度元素 | `.time-info`,形如 `0:57 / 4:04`(**带总时长,要先按 `/` 切**) | `[data-testid=playback-position]`,**只有当前位置**(总时长在另一个元素) |
| 暂停判据 | `<video>.paused` | ⚠️ **页面里没有 `<video>` 也没有 `<audio>`**,这条路直接断掉;改判 `document.title` 里有没有 ` • ` 分隔符(播放中 `歌名 • 歌手`,暂停时整个回落成静态的 `Spotify - Web Player: Music for everyone`) |
| 精度 | 整秒(页面渲染的文字) | 同左 —— 都按 `.noisyFloored` 处理 |

- ⚠️ **Spotify 进度条里那个 `<input>` 是陷阱**:`[data-testid=playback-progressbar] input` 带 `value=145000 max=269340`,毫秒精度、max 还跟 media-control 的 `duration=269.339773` 严丝合缝,看着比文字好得多。连打三拍实测是 **140000 → 145000 → 145000**(5 秒一跳且滞后),同期文字 2:18 → 2:22 → 2:25 一直在走 —— 它是给滑块用的节流状态,不是实时位置。照它写进度会一顿一顿的。
- ⚠️ **暂停判据逐个否掉的候选**(都实测过):播放/暂停键的 `aria-label` 是**本地化**的(中文界面下播放中显示「暂停」);`navigator.mediaSession.playbackState` Spotify 没设、恒为 `none`;按钮和它三层祖先节点只有 `data-testid`、没有任何状态位;图标 SVG 的 `path d` 确实是干净的分水岭(两条竖杠 vs 三角形)但认路径字符串太脆。最后用 `document.title` 且**只看分隔符在不在、不看任何一边的文案**,因此不受本地化影响。将来 Spotify 换标题格式的话,这里退化成"永远判暂停" → 探针不出手 → 静默退回 MediaRemote,这是**刻意选的失败方向**。
- **Spotify Web 确实需要这个探针**(2026-09-01 实测):`media-control` 连打 4 拍,`elapsedTime` 恒 `0`、`timestamp` 恒等于会话创建时刻、`playing=true` —— 跟 YouTube Music 一模一样的冻结锚点。顺带坐实了这个锚点**只在状态切换时更新**:用户一按暂停,`elapsedTime` 立刻变成真实的 `253.04`、`timestamp` 也跟着走,而同刻页面文字正好是 `4:13`=253s,两边对得上。
- **平台 id ↔ 站点规则的一一对应关系有 selftest 钉着**(`platformIDsWithSiteRules`)。对不上不会编译报错,只表现成"卡片在、配对得上、却永远不探测"。
- 平台图标的来路**按"这个平台有没有本机 App"分两种**:**Spotify** 取自本机 `/Applications/Spotify.app` 的 `AppIcon.icns`(`sips` 转 1024×1024 PNG,放 `Sources/lyrimuse/Resources/`);**YouTube Music** 是个网站、没有 `.app` 可取,用 Simple Icons(CC0 授权、专门收录给第三方集成场景用的品牌图标合集,矢量描摹自官方标志)。两条都**不去网上抓品牌资源**。⚠️ `platformIcon(_:)` 里的 key 必须跟 `BrowserPositionProbe.supportedPlatforms` 的 `id` 一字不差 —— 对不上不报错,只表现成"那张平台卡的图标位空着"。
  - ⚠️ **Simple Icons 是单色图标集,直接拿来用会让图标内部跟着深浅外观变色**(2026-09-02 用户报:「不要是这种会随外观是白天模式还是黑色模式变里面的颜色…固定为白色」)。`YouTubeMusicIcon.png` 里**只有那个红色实心圆是不透明的**,中间那圈细白环和播放三角**是抠掉的透明像素**(实测 alpha 恒为 0)—— 显示成什么颜色完全取决于背后是什么:浅色外观下卡片底浅、看着就是白的,深色外观下那两处跟着变深(用户截图里那个"深色三角")。**跟 SwiftUI 的着色、模板图 `isTemplate`、`.foregroundStyle` 都无关,改视图那一侧改不掉。**
  - 修法是 `SettingsView.whiteFilledCutouts(image:)`:在图标底下垫一个纯白圆,红圆自己把多余的白盖住,只剩镂空处透出白色。白圆半径必须**小于红圆、大于镂空**,两头都是实测的(1024×1024 源图,原点在中心):红圆是满幅内切圆、半径 512(四条中线上第一个不透明像素分别落在 0 / 1023);所有镂空像素离中心最远 **303**(细白环的外沿,不是三角 —— 三角更靠里)。安全区间因此是 (303, 508],取 `inset = 8%`(半径 430)落在正中间,26pt 显示尺寸下红边仍有约 2pt,不会因为边缘抗锯齿漏出白圈。三种卡片底色(深色选中卡 / 深色普通卡 / 浅色卡)× 真实 26pt 尺寸离屏渲染逐张看过。
  - ⚠️ **不改磁盘上那份 PNG**,素材保持跟 Simple Icons 原样一致(来路可查,同 `SpotifyIcon.png` 的纪律),垫白只发生在运行时;用 `NSImage(size:flipped:drawingHandler:)` 而不是 `lockFocus()` 烤位图,保持分辨率无关。也**不要**改成"在视图里垫一层 `Circle().fill(.white)`":那样只有当前这一个调用点是对的,换个地方用 `platformIcon("youtubeMusic")` 又会退回镂空 —— 垫白属于这张图本身。`SpotifyIcon.png` 不需要这一步(图形内部整片不透明,实测中心 alpha = 1)。

配对是**显式**的:没配过的浏览器完全不触发后台探测(`kickIfNeeded`)。设置页按 `supportedPlatforms` 逐个平台一张小卡,卡上是已配对浏览器的头像 + 一个「+」。

**「+」菜单里有三类条目:**

1. **内置候选** —— `knownBrowserBundleIDs` 里装了、且还没配过这个平台的。⚠️ 这份名单短(Chrome / Edge / Safari),**这不是 UI 偷懒**,而是两条不同的收紧叠在一起:①它跟 `chromiumPrefsPaths` 同源,后者只登记**实测验证过**那个 Preferences 路径的浏览器——Brave/Vivaldi/Opera 大概率同源同构,但没实测过就往里写等于拿用户的配置文件赌;②**它是"默认展示"名单,不是"支持"名单**。
   - ⚠️ **Arc 不在这份名单里,但适配一条都没少**(2026-09-01 用户拍板:「arc 不要留着,但是我们代码里对他的适配都留着,只是不在这里显示,如果用户自己选了 arc,那就依旧按我们适配好的来走」)。Arc 在 `chromiumPrefsPaths` 里原样留着 → `family(...)` 照样返回 `.chromium`、那道 JS 开关的状态照样读得出来、`browserManualEnableHint` 里那条 Arc 专属菜单路径(中文系统下也显示英文)也原样留着;`BrowserPositionProbe` 那边的 Arc 休眠标签页处置更是全族通用。用户从「从应用程序中选择…」挑中它时走的是**完整既有适配,一步都不降级**,少的只是"默认摆在菜单里"这一条。**别因为它不在名单里就去删 Arc 的适配代码。**
   - 配套:`chooseBrowserFromApplications` 里"已经认识引擎族"那条早退分支也要 `rememberManualBrowser` 登记一次 —— 否则 Arc 这种"认识但不默认展示"的浏览器选完之后仍然不出现在「+」菜单里,下次想再配一个平台还得重走文件选择器。该函数自己跳过内置那几个(它们本来就默认展示,再记一份是冗余状态)。
2. **已经信任过的浏览器** —— 出现在下面「已信任的其它播放器」卡里、装着、而且**驱得动**的那些(2026-09-01 用户原话:「已经被信任了,就应该出现在这个列表里面,这个逻辑还是要的」)。⚠️ **信任是候选的一个来源,不是候选的前提** —— 这两件事 2026-08-31 和 09-01 各定过一半,别再把其中一半当成全部:没信任过的已安装内置浏览器**照样列出来**(选中时一步自动信任+配对),而已经信任过的浏览器**也一定要列出来**,哪怕它既不在内置名单、也没被手动加过。信任可以发生在配对之外(用户在「发现未知播放器」卡里点的信任;或者配对过又移除了配对——那会顺手忘掉 `manualBrowserFamilies` 里的登记),这两种情况下它都还在信任列表里却进不了候选,用户看到的就是"下面明明信任着 Doubao Browser,上面菜单里没有它"。
   - ⚠️ 判据必须用 `BrowserAutomationPermission.resolvedFamily` 而**不是** `family` —— 信任列表里只有 bundle id 和显示名,那些"点信任加进来的"浏览器从没被登记过引擎族,`family` 对它们恒为 nil。`resolvedFamily` 查不到时会去那个 App 自己的 bundle 里**现场读一次 sdef**,判定结果(含 nil)进内存缓存:调用点是 SwiftUI 的 body,每次重绘、每次回到前台都会跑一遍。缓存 `@MainActor` 隔离(`family` 会被 `BrowserPositionProbe` 在后台线程读,两者不共享这份字典)。
   - ⚠️ **配对时必须把现场判定的引擎族落盘**(`trustAndPairBrowser` 开头那句 `rememberManualBrowser`)。那个判定结果只活在内存缓存里,不落盘的话配对之后 `family(...)` 仍然返回 nil,`kickIfNeeded` 和 `runBrowserSelfTest` 都会在第一道 guard 上直接返回——表现是"配上了、头像也有了,却永远不同步、连检测按钮都不工作"。
3. **「从应用程序中选择…」**(2026-08-31,用户原话:「这里点+号出来的是否可以加一个选项是自己在本机的应用程序里面选」)—— `NSOpenPanel` 从 /Applications 挑一个 App,判定通过就一步信任+配对。这条路存在的意义正是上面那条限制的另一面:那些同样继承了 Chrome 脚本字典、本来就驱得动、只是没人验过 Preferences 路径的浏览器,现在用户自己加得进来。

- **判据是"驱不驱得动",不是"名字像不像浏览器"**:读挑中 App 的脚本定义(`Info.plist` 的 `OSAScriptingDefinition` → `Contents/Resources/*.sdef`),看里面有没有"执行 JavaScript"那条命令。**认 AppleScript 四字码不认命令名** —— 名字会随本地化/改版变,四字码是 AppleScript 的 ABI,改了等于破坏所有既有脚本。Chromium 系 `CrSuExJa`、Safari `sfridojs`,2026-08-31 在这台机器上逐个实测:Chrome / Edge / Arc / Safari 全部命中,而 The Unarchiver / 音乐 / QQ音乐 **一处都匹配不到**。
  - ⚠️ **决定能不能用的是「这个 App 有没有实现脚本命令」,不是「它用什么渲染引擎」**(2026-09-02 订正,用户问「你确定火狐不支持吗」)。此前代码注释和那条拒收弹窗都写成「Firefox 这类内核不支持」,归因错了:Gecko 跟这件事毫无关系,是 **Mozilla 从来没给 Firefox 写过 AppleScript 字典** —— 本机 `sdef /Applications/Firefox.app` 读出来只有系统样板套件(Standard / Text / Type Definitions),**没有 `tab` 类、没有任何执行 JS 的命令**,从 Apple Events 这条路够不到任何一个标签页。反向的例子同样说明问题:Arc 能用不是因为「Chromium 内核」,而是它 fork 了 Chrome 的代码、连脚本字典一起继承(四字码都是同一个 `CrSuExJa`);Safari 的 `sfridojs` 又是 Apple 自己给 Safari 加的,跟 WebKit 引擎也无关。Gecko 浏览器明天想加也能加。⚠️ 代码里的 `BrowserAutomationPermission.Family`(「引擎族」)这个抽象**不动** —— 按 fork 血缘分组是有效的实用启发式(脚本字典就是沿 fork 继承的),错的只是把「不支持」归因到引擎那句话。
- **判不出来就拒收并说清理由**,不是"加进去再说"。放进一个永远不会工作的配对比列表里没有它更糟:用户会以为配好了,然后去查"为什么歌词进度还是不同步"。
- ⚠️ **手动加进来的浏览器只登记引擎族,不登记 Preferences 路径**(`manuallyAddedFamilies` 只喂 `family(...)`)。于是它的 `status(...)` 恒为 `.unknown`、`enable(...)` 恒为 `.unsupported` —— 这是**有意的降级**:那个路径每个浏览器一个样(Arc→`Arc/`、Chrome→`Google/Chrome/`、Edge→`Microsoft Edge/`),没有公式能从 bundleID 推出来。一键开启对它们不可用,用户得自己去浏览器菜单里开那一项。
- **持久化**:`AppSettings.manualBrowserFamilies`(bundleID → 族的 rawValue),启动时由 `AppDelegate` 灌进 `BrowserAutomationPermission.manuallyAddedFamilies` —— 跟 `platformBrowserPairs` 同一个"存在 AppSettings、运行期同步进 LyrimuseCore 单例"的双写模式。⚠️ 不灌这一次的话,`family(...)` 重启后对这些浏览器返回 nil,表现是"我加过的浏览器重启后从配对列表里消失了",而配对本身还好端端存在 `browserPlatformPairs` 里。
- ⚠️ **手动加进来的浏览器,最后一个配对被移除时要一起忘掉**(2026-09-01,`forgetManualBrowserIfUnpaired`)。在此之前 `manualBrowserFamilies` 全仓**只有一处写入、零处删除** —— 用户试着从「应用程序」里挑过一个浏览器,它就**永远**留在「+」菜单里,没有任何界面能把它拿掉(用户实际撞上:菜单里常驻一个早就不用的 Doubao Browser,原话「剩下的只有用户自己选了新的浏览器才会显示在这里」)。判据是"一个平台的配对都不剩"而不是"移除了这个平台的配对"——同一个浏览器可以配多个平台。手动加进来的浏览器一加进来就**同步**被配对(`chooseBrowserFromApplications` → `trustAndPairBrowser` → `pairBrowser`,后者不在 await 之后),所以不存在"刚加完还没配上"被误清的窗口。
  - ⚠️ **只在用户这一次主动移除配对时做,不做启动时的批量清理** —— 后者是在用户没做任何动作的时候替他删状态,跟"卸载了的浏览器保留配对记录"那条既有原则冲突。代价也很低:这份字典存的本来就是一个**判定结果的缓存**(那个 App 的引擎族),不是精心配的偏好,再要它时重新挑一次即可。
- 「+」**恒定展示**,不再是"有内置候选才出现":内置候选全配完之后恰恰是最需要「从应用程序中选择…」的时候(装的浏览器不在那四个里)。
- **整张卡的展示条件是"装了受支持的浏览器",不是"已经信任过某个浏览器"**(2026-09-01 改)。旧条件制造了一个**鸡生蛋**:8-31 起「+」菜单已经不要求先信任(`trustAndPairBrowser` 一步自动信任+配对),这张卡因此从"信任之后的配置面板"变成了"信任这件事本身的入口";而它自己的显示条件还停在旧语义上 —— 没信任过任何浏览器时整张卡连同 YouTube Music 一起不显示,界面上没有任何地方能发起信任,只能靠"真的用浏览器放歌 → 被动检测到未知播放器"绕回来。用户清空全部浏览器配置想重走一遍流程时当场撞上,原话「这里的 YouTube Music 应该是要常驻的」。判据跟 `addablePlatformBrowsers` 同源:那边能列出候选,这边就该显示。⚠️"不为了'这里没事'而占地方"这条原则保留 —— 一台只装了 Firefox 的机器仍然不显示这张卡。
- **平台卡现在也有"选中并高亮"这个状态了**(2026-09-01,用户原话「网页播放器不可以选择并高亮吗」,跟上面"播放器"卡的多选是同一批改动):`browserPlatformCard` 配对了至少一个(装着的)浏览器就按 `PlayerChoiceCard` 同款样式高亮——不是新加一个独立开关,直接复用既有的"配了/没配"状态,配对本身早就是显式动作(点「+」选浏览器),没必要再叠一层"选不选用它"。这次改动**不是纯视觉**:配套把"信任列表"这条线从只在 auto 下生效,扩到"选中了具体播放器但没勾自动识别"这条路径也生效(App 侧 `MediaControlClient.fetchMultiSelectedSnapshot`/`artworkBundleIDMatches` 新增 `TrustedPlayers.isTrusted` 分支,过 `notASong` 守卫;collector 侧新增 `isTrustedPlayerBundleID`,`getMultiSelectedState`/`poller.isTracked` 同步接入)——此前配对一个浏览器只在用户同时勾着"自动识别"时才真的生效,选了具体播放器(不勾 auto)会让配对**看起来配好了、实际读不到播放**这个断层一直存在。高亮因此如实反映"这确实是一个会生效的来源",不是纯装饰。

- ⚠️ **那道 JS 开关「只在浏览器启动时读一次」,开和关两个方向都要重启才落实 —— 指引里必须写出来**(2026-09-02 用户实际踩到:「刚才我明明有打开 safari 的 js 啊,是不是没有重启的原因?」,重启 Safari 后当场就通)。当天两族各有一次实测坐实:**Chromium** 侧,用户在 Arc 菜单里把开关**关掉**、`Preferences` 当场变 `false`,而没重启的 Arc 11 分钟后仍能 `execute … javascript` 返回 `2`;**Safari** 侧,勾上之后一直报错误号 8,退出重开就通。修法是在 `browserManualEnableHint` 那句路径**下面单独一行**提示重启——不并进那句里:那句回答"点哪",这句回答"点完还要做什么",混在一起读者会当成同一步的补充说明而略过,而略过的代价正是"我明明开了却不 work"。

#### 「检测是否已生效」:一次真的执行 JavaScript 的功能性自检(2026-09-01)

Chromium 系那道 JS 开关的状态**经常读不出来** —— 它在浏览器 profile 的 `Preferences` 里,别的 App 读那个目录要「完全磁盘访问权限」,读不到就只能显示「无法确认状态」。用户按指引手动开完之后,界面上没有任何东西会变,他没法确认自己做对没有(原话:「我现在已经手动去打开了,这个页面怎么回显?没有按钮啊」)。

`BrowserPositionProbe.selfTest` 换一条不依赖那个权限的判据:**直接试着执行一小段 JavaScript(`1+1`)**。成不成功就是用户真正关心的那件事本身,比读配置文件更贴近事实 —— 配置文件写着"开"但浏览器还没重启时其实没生效,而这个自检会如实失败。通过就**落盘**(`AppSettings.browserJSVerifiedAt`),整张气泡收敛成「上次检测通过(x 分钟前)」+ 一个「重新检测」入口,角标消失;明确的反证(`blocked`/`noReply`)反过来**把那条记录抹掉**,不让一句过期的"通过过"在下次打开设置窗时把"已配好"说回去。

- ⚠️ **必须在「当前标签页」上试,不能用 `tab 1 of window 1`**(2026-09-01 修的 bug,用户报「我点击检测就弹出这个异常:检测没通过:no output」)。**Arc 会把非当前标签页休眠掉,对休眠标签页执行 JavaScript 会一直不返回**,于是一个配置完全正常的 Arc 也会被判成失败。同一时刻同一台机器实测:`execute (tab 1 of window 1) javascript "1+1"` 挂死(5 秒被闹钟杀掉、零输出),`execute (active tab of window 1) javascript "1+1"` **123 毫秒返回 2**;当前标签页是第 10 个,它的**紧邻**第 9、11 个(同为 pinned)一样挂死 —— 也就是说"第一个标签页"这个看起来最稳妥的取法,在 Arc 上几乎必然踩中休眠标签页。标签页的 `loading`/`location` 属性都**判不出**它是不是休眠的(实测 `loading` 为 false、`location` 为 pinned,照样挂),没有可用的前置判据。命令名两族不同:Chromium 系 `active tab`(四字码 `acTa`,Arc/Chrome/Edge 一致)、Safari `current tab`(`cTab`),见 `activeTabExpression`。
- ⚠️ **AppleScript 的裸 `try` 抓不住"挂起"**,只有 `with timeout of N seconds` 能把它变成一个抓得住的错误(-1712)。没有它时"浏览器不回"表现为 osascript 挂死到被 `ProcessRunner` 硬杀、stdout 空空如也,UI 上就是那句什么都没说的「检测没通过:no output」—— 那正是用户看见的。现在 -1712 单独归成 `SelfTestResult.noReply`(跟 `blocked` **分开**:Chrome 那道开关关着时会**立刻**抛一句清楚的错误,Arc 关着时**什么都不说、直接不回**,是两种失败方式)。
- **探测循环也一样**(`buildAppleScript`):先扫一遍各窗口的**当前标签页**,再扫其余标签页,每条 `execute` 都套 `with timeout of 1 second`。用户开着几十个标签页是常态(实测这台机器 50 个),其中只要有两三个匹配得上 URL 又恰好是休眠的,整次探测的 3 秒预算就没了、真正在播放的那个根本轮不到。
- **判"开关关着"优先看得到的事实,其次才认文案**:能读到那道开关的状态(Safari 走 `CFPreferences` 一定读得到)且读到的是关着的,直接判 `blocked`,不猜本地化文案;读不到时才认关键词,而且**认关键词不认整句**。Safari 的原话是 "You must enable 'Allow JavaScript from Apple Events' in the Developer section of Safari Settings…"(错误号 8)—— 注意它说的是 **Apple Events** 而不是 AppleScript,跟 Chrome/Edge 那组锚点(`AppleScript` + `turned off`/「已关闭」)一个都对不上,必须单列。

- ⚠️ **文件和实测回答的是两个不同的问题,都对,不存在"以谁为准"**(2026-09-01,用户亲手做的对照实验坐实)。`Preferences` 里那个 `browser.allow_javascript_apple_events` 说的是「**下次启动**会怎样」,`BrowserPositionProbe.selfTest` 说的是「**现在**怎样」—— Chromium 那道开关**只在浏览器启动时读一次**,运行期间在菜单里改它,文件立刻变、运行中的浏览器纹丝不动。实证:这台机器上的 Arc 进程自 8/30 17:49 起一次没重启,用户 16:46 在 Arc 菜单里把它**关掉**、文件当场变 `false`,11 分钟后 `execute … javascript "1+1"` 照样返回 `2`;开的方向同理(此前几小时文件在 `true`/`false` 之间变过,实测行为全程不变)。(排除过自己人:全仓只有 `readChromiumPrefs` 一个读取点,没有任何代码写这些文件——一键开启那条路当天已整条移除。)
  - **UI 据此的处置**:两者不一致时**要给指引、不能报平安**。`browserJSLikelyWorking` 里 `.disabled` **一票否决**(排在实测结果之前),让菜单路径那块指引露出来;`browserJSSwitchCaption` 的 `.disabled` 分支在 `browserJSProvenWorking` 为真时改口成「这个开关已经被关掉了——现在还能用,只是因为该浏览器还没重启;重启后就会失效」。文件说关意味着**一次已经排好队、必然到来的失效**,那正是最该提前告诉用户的事。
  - ⚠️ **Safari 的 `.disabled` 此前是个误报——「读不到」被当成了「关着」(2026-09-02 修)**。用户原话「可以现在就是勾着的啊」:那个开关**确实勾着**、自检也实测通过(绿字「现在可以被驱动了」),界面却橙字告警「这个开关已经被关掉了——重启后就会失效」,还把菜单路径指引整块摆出来让他再勾一遍(本来就勾着,照做无事发生)。根因在 `BrowserAutomationPermission.status` 的 Safari 分支:`CFPreferencesCopyAppValue` 返回 nil 时 `return .disabled`,注释理由写的是"Safari 这个开关默认就是关的,读不到值等价于从没开过"——**这个假设是错的**,而且跟隔壁 Chromium 分支的处置自相矛盾(那边读不到明确返回 `.unknown`,还专门写了"那不是坏了,是查不到,别显示成未开启")。nil 有两种成因分不出来:真的没设过、以及**读不到**——`com.apple.Safari` 是 TCC 保护域,别的 App 读它要「完全磁盘访问权限」,**没有才是常态**。实测坐实(本机 Safari 开关为开):外层 stub plist 和容器内那份**都是 `true`**,终端身份(有权限)`CFPreferencesCopyAppValue` 读到 `1`、App 身份读到 nil——同一台机器同一个值,读得到读不到只取决于调用方的 TCC 身份,跟开关死活无关。连带伤害不只是文案:`browserJSLikelyWorking` 对 `.disabled` 是**一票否决**,所以这张卡永远收敛不到"已配好"、角标一直挂着。修法:Safari 分支改判 `.unknown`,跟 Chromium 对齐,这一档交给实测兜底(那正是本仓库对 Chromium 系一直以来的做法);判据抽成纯函数 `safariStatus(fromPrefValue:)` 供 selftest 覆盖 nil/true/false/NSNumber 四档,**已做变异测试**(改回 `.disabled` 当场被抓)。⚠️ 这也说明上一条那个"两句都对"的结论**只对 Chromium 成立**——Safari 那次根本不是两个时间点的差异,是纯误报。
  - ⚠️ **但这个处置会让同一张卡自己跟自己打架,2026-09-02 补掉**(用户报「是不是自相矛盾了,到底当前是可以用还是不可以用」):开关已关、浏览器还没重启时,上面橙字说「重启后就会失效」、下面绿字说「✓ 已生效——这个浏览器现在可以被驱动了」。**两句都对**(一句答"下次启动",一句答"现在"),但并排读就是直接矛盾。病根在「已生效」这三个字有歧义——用户读成的是「我刚勾的那个开关已经生效了」,而它实际只想说「此刻驱动得动」。修法:`browserSelfTestCaption` 新增 `switchDisabled` 入参,`.ok` 且开关在文件里是关的时,换成「✓ 此刻驱动得动——但这是重启前的暂时状态:上面那个开关已经被关掉,重启后就会失效」,让两块变成同一个故事的两半。**两个调用点都要传**(「还没配好」的指引分支和「已经配好了」的结果分支同形,后者一样会撞上这一幕——写这条修复时 assert 拦下了只改一处的版本)。这跟更早那次「同时出现『✓ 已生效』和『请求系统授权』」是同一类问题、同一个修法:**让互相矛盾的状态块互相感知**;这张卡有多个各自独立现读、互不知情的状态块,是它反复长出这类矛盾的结构性原因,以后往里加状态行时都要先问一句"它会不会跟旁边那行打架"。
  - ⚠️ 反过来 `.enabled` **不能**一票通过:它同样只说明下次启动会怎样。那一档仍然让实测结果优先(`blocked`/`noReply`/`failed` 判 false),否则会出现"上面说已开启、下面说检测没通过、却一句指引都不给"。
  - ⚠️ **2026-09-01 当天这里一度写反过**:先按"文件不可信、以实测为准"改了一版(那时只看到"文件说关但实测能用",误判成文件不可靠),用户补了一句「当时是我自己去给它关掉了」才把因果补全 —— 不是文件不可信,是它在回答另一个时态的问题。**留着这条,别再按"谁更可信"去想这件事。**
- ⚠️ **这张卡的状态全是渲染时同步现读的,没有 `@Published` 可依赖 —— 所以要在"回到前台"时手动踢一次**(2026-09-01,用户原话「那我现在去打开了,设置里这里要怎么流转状态呢;自动的吗」)。浏览器那道 JS 开关读的是它自己的配置文件、系统自动化授权读的是 TCC,两者都没有任何变更通知可订阅。在此之前用户按指引跑去浏览器菜单里勾上开关、再切回来,界面上**什么都不会变**,得把气泡关掉重开或者点一次「重新检测」。修法是给整张卡挂 `NSApplication.didBecomeActiveNotification` → `automationRefreshTick &+= 1`:"去浏览器/系统设置里操作"这件事**必然**要切走再切回来,这个信号比给配置文件挂 FSEvents 或起定时器轮询都更准更省,而且一次覆盖两道门。
  - ⚠️ **要补第二拍**:Chromium 那道开关勾完**不是立刻写盘**的(偏好走批量延迟提交),用户两三秒就切回来时文件里很可能还是旧值。所以 activate 之后再延时踢一次(12 秒,**留余量的兜底值、不是实测常数**)。
  - ⚠️ 这一拍**只是让 SwiftUI 重新读一遍,不发起任何 AppleScript/自检** —— 自检要起 osascript 子进程,不该在每次切回 App 时白跑。要立刻确认的通路是气泡里那个「重新检测」,它**不看文件**、直接执行一段 JavaScript,任何时候都即时准确。

- ⚠️ **配对要先写,信任在后台跑**(2026-09-01 修,用户报「我在加了新浏览器之后过了很久才在这边出现图标」)。头像那一行铺的是 `settings.browserPlatformPairs`(纯本地、瞬时),而 `features.trust` 里那句 `save()` 会走一整套 **collector 重启**:`CollectorRestartCoordinator` 0.5 秒去抖 → `launchctl kickstart -k` → 轮询到一个**新 pid** 才返回,确认超时 3 秒(`CollectorControl.restartConfirmTimeout`)—— 最坏 3.5 秒以上,重启失败还会把这 3.5 秒整个耗满。旧顺序把这套重启**夹在**"用户在菜单里点了那个浏览器"和"头像出现"之间,连带下面那个自动展开的气泡也一起被推后。两者之间没有依赖(信任写 features.json 给 collector 看,配对写 AppSettings 给这张卡和探针看),失败处理也一样——`trust` 的返回值本来就没人接。**以后再往这条路上加动作,先问一句"它挡在 UI 反馈前面吗"。**

- ⚠️ **探针那一侧也要做媒体代理别名解析,漏了它 Safari 一次都不会被探测**(2026-09-02 实测撞上)。用户在 Safari 里打开 Spotify 网页版播放,MediaRemote 报的 bundle id 是 `com.apple.WebKit.GPU`,而 `BrowserPositionProbe.kickIfNeeded` 直接拿它去查 `family(...)` → nil → **当场返回,一次探测都不发起**;就算过了这道,`pairedPlatformIDs` 也查不到(配对表里存的是 `com.apple.Safari`),再退一步 `probeOnce` 会拿它去 `tell application id`,而那个进程根本 tell 不动。三处全错,而且**一条日志都没有** —— 表现就是"配对了 Safari、卡片也在、却永远不同步"。准入那一侧(`TrustedPlayers.isAccepted`)2026-09-01 就补了这步解析,探针这侧一直漏着,对 YouTube Music 同样成立。修法是入口处解析一次(`BrowserPositionProbe.probeTargetBundleID(forReported:)`),下游三处统一用宿主 id;selftest 有三条断言钉着。

### ⚠️ Safari 的媒体进程:`com.apple.WebKit.GPU`

**Safari 播网页音视频时,MediaRemote 报的"现在谁在放"是 `com.apple.WebKit.GPU`,不是 `com.apple.Safari`** —— 解码/播放跑在一个独立的 WebKit GPU 进程里。Chromium 系(Arc/Chrome/Edge)不这样,它们报浏览器自己的 bundle id,**只有 Safari 需要特殊处理**。

不处理的后果是一个用户看得见的断层(2026-09-01 实测撞上,原话「为什么这里又出现了一个 webkit 啥玩意」):在「网页播放器」卡里配对了 Safari、配对也确实把 `com.apple.Safari` 写进了信任列表,可真播起来上报方是 `com.apple.WebKit.GPU` —— 不在名单里 → 整条播放不被采纳,同时"发现未知播放器"那张卡还跳出来要用户再信任一个看不懂的 bundle id。**两个身份、两套机制**:配对认的是"我们要对谁发 AppleScript"(`com.apple.Safari`),准入认的是"谁在上报 Now Playing"(`com.apple.WebKit.GPU`),中间原本没人搭桥。

修法是一张「媒体进程 → 宿主 App」的别名表(`TrustedPlayers.mediaProxyOwners`,Go 侧 `system.go` 同名同内容),`isAccepted` 查不到本体时再查一次宿主。

- ⚠️ **选别名而不是"配对时连带把代理进程也写进信任列表"**:后者会在「已信任的其它播放器」里留下一条用户看不懂的 `com.apple.WebKit.GPU`,而且撤销配对时还得记得一起删(漏了就是永久多一条)。别名跟着宿主的信任状态自动生效/失效,没有需要同步维护的第二份状态。
- ⚠️ **别名是单向的**:信任了代理进程**不**代表 Safari 本身被信任(反向查表不成立),两侧都有断言钉住。
- ⚠️ **只登记实测见过的**。`com.apple.WebKit.WebContent` 这类同族进程没有实测到它报过 Now Playing,不凭猜测加 —— 真遇到了在表里补一行,其余逻辑不用动。
- ⚠️ **两侧必须同时改**(同 `isAcceptedPlayerBundleID` / `TrustedPlayers.isAccepted` 那对)。Swift 8 条断言、Go 6 条断言各自对称覆盖:别名生效/别名不是白名单/别的浏览器不顺带放行/单向性/宿主反查/Chromium 不在表里,外加**跨层不变量**——别名一旦生效,"发现未知播放器"卡必须同时不再提议它(那张卡的判据就是 `!isAccepted`,两者永久绑定)。
- **「装没装」这道门(`isInstalled` = `NSWorkspace.urlForApplication(withBundleIdentifier:) != nil`)在两侧都生效**(2026-08-31 用户问「我们本地如果没有装的话是不是也不会显示」时补齐的)。在此之前只有「+」菜单的候选过滤了它,而已配对浏览器的**头像**是直接铺 `browserPlatformPairs` 的 —— 于是"配对过、后来卸载了"会一直留一个取不到图标的虚线方框(`browserIconView` 的 `app.dashed` 兜底),点开还给一份无意义的权限状态。⚠️ **只是不显示,配对记录原样留着**,装回来自动恢复;这跟「指定的屏幕拔掉后自动回落、偏好保留、插回来即恢复」是同一个口径(05-notch.md),**不要**顺手 `unpairBrowser` 去"清理"——那是替用户删他的配置。
- ⚠️ **别名解析必须在每一个"判信任"的入口生效,collector 侧 2026-09-02 又抓出三处漏网的裸查**(王力宏《你不知道的事》Safari 播放案,「歌词管理」占位行永远停在"搜索歌词中…"):`system.go` 里 `getAutoDetectedState`、`trustedPlaybackNotASong`、`mediaPlayerLabel` 三处都是直接 `features.TrustedPlayers[bundleID]` 裸查——对 `com.apple.WebKit.GPU` 永远落空。后果分别是:**auto 路径把 Safari 的播放整条当"不相关 App"丢掉**(collector 报 empty、永远不解析歌词,而 Swift 侧 `TrustedPlayers.isTrusted` 有别名解析、App 认了这首歌并挂出占位行——两侧判定分叉,占位行等一个永远不会发生的解析);非歌守卫对 Safari 恒不生效;media_player 标签把 Safari 播放谎报成 "Apple Music (macOS)"。Swift 侧 `TrustedPlayers.notASong` 也有同一处裸查,同日一起修。修法统一改调 `isTrustedPlayerBundleID` / `isTrusted(_:trusted:)`;`safariproxy_test.go` 除功能断言外还有一个**源码级守卫**(扫 `system.go`,`features.TrustedPlayers[bundleID]` 裸查只允许 `isTrustedPlayerBundleID` 内部那一处),selftest 补了三条代理进程的非歌守卫断言。端到端验证:修后 collector 立刻认领 Safari 播放(relay 从 `empty` 变 `mac|特別的人|方大同|危險世界`)并跑完整八源解析。教训与上面探针那条(2026-09-02)同型:**每接一个新的"拿 bundleID 判身份"的地方,都要想一遍 Safari 代理进程**——这已经是第三批漏网点了。

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

- playPause/nextTrack/previousTrack/seek 走双后端 `dispatch`:选中集合**恰好**是 `{Apple Music}`(`PlaybackPlayerPreference.isExclusivelyAppleMusic`,2026-09-01 多选后从"设置值 == .appleMusic"改写成这个判据,行为对单选年代逐位不变)→ AppleScript 发给 Music.app;**其它任何组合(含 .auto、含多选)** → media-control 控制指令(作用于系统 Now Playing 焦点,代码注释断言读取路径确认在播时天然作用于该播放器)。seek 有 `preferAppleScript` 覆盖:非排他选择下实际在播 Apple Music 时,读路径是 AppleScript 精确播放头,写路径也走同一条(`LocalPlaybackSource.seek` 按 `lastSnapshot?.bundleIdentifier` 判)。⚠️待核对:playPause/上一首/下一首没有同款覆盖——.auto/多选 + Apple Music 实际在播时它们走 media-control,行为应等效但未见实测记录。
- `seek(toMs:)` 除发指令外**立刻**本地重锚三处(trackPosSeconds/posPrevWall/posErrEMA 清零)+ 当场重建 anchor + `pollGeneration += 1` 作废在飞轮询 + 立即 `fastTick()`——不重锚的话小于 2s 的拖动会被 seek 容差永久吞掉。秒数经 `seekArgument` 格式化(固定 3 位小数、en_US_POSIX、负值夹 0、上界故意不夹)。
- 「喜欢」(favorited/loved 双属性名兜底,macOS 版本间改名)、播放模式(三档:列表/随机/单曲循环)、音量:仅 AppleScript,`supportsExtendedControls` = Apple Music 和 Spotify;Spotify 无单曲循环档(`supportsRepeatOne` 仅 Apple Music,脚本接口只有布尔 repeating);QQ/网易云完全不支持(MediaRemote 只有播放控制)。
- 所有 Spotify 脚本前垫 running 守卫(发任何命令都会启动 Spotify);写指令"发完就不管"不阻塞,读回值的走 `runAppleScriptCapturing`(5s 超时,**不要在主线程调**)。
- 切播放模式**写完不马上回读**:实测 setter 生效后 getter 滞后 250ms+,回读旧值会把画好的图标覆盖回去。

### 权限(自动化)

`MusicAutomationPermission`(仅覆盖 Lyrimuse 自己这份 TCC 身份;collector 是独立签名身份、独立一条 TCC 记录,App 无 API 可查/可触发,设置页只给说明+跳系统设置按钮):

- 只在选中集合排他地是 `{Apple Music}` 时需要真的去查(`checkForCurrentPlayer`/`checkForCurrentPlayerSafely` 用 `PlaybackPlayerPreference.isExclusivelyAppleMusic` 判断,对其它组合直接返回 true);QQ/网易云/Spotify 的 media-control 路径实测全程不触发权限弹窗。设置页「Apple Music 自动化」权限卡本身的**展示条件**更宽松(选中集合包含 Apple Music 即显示,不要求排他,见上面"多选"一节)——查权限的判据和显示管理入口的判据是两件不同的事,故意不共用同一个条件。
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
| 播放器 tab | 与播放器联动 · 打开 Lyrimuse 时启动(逐播放器勾选,2026-09-03) | `AppSettings.launchPlayersOnLyrimuseOpen`(Set,np: 键存 rawValue 数组);候选 = 选中集合里的具体播放器,选了 auto 时五个都可勾(`LyrimuseCore.PlayerLinkage.candidates`),生效 = 勾选 ∩ 候选(取消选中的播放器不算、勾选记录保留);`AppDelegate` 逐个启动没在跑的、不抢焦点。老布尔键 `np:launchMusicOnLyrimuseOpen` 首次启动迁移一次(true + 当时唯一具体播放器 → 那一个,含糊 → 空)后进 `obsoleteDefaultsKeys` |
| 播放器 tab | 与播放器联动 · 跟随播放器启动(逐播放器勾选,2026-09-03) | `FeatureSettingsStore.launchLyrimuseOnPlayers` → features `launch_lyrimuse_on_players`(列表;同时仍写布尔 `launch_lyrimuse_on_music_open` = 列表非空,给老 collector 当总开关);collector `companionLaunchProcessNames` 键在就只盯勾了且仍在候选里的那几个,键缺失退回布尔年代「盯整个选中集合 / auto 全量」;老文件迁移:布尔 true(默认)→ 当时全部候选。Go 测试 `TestCompanionLaunchProcessNamesHonorsChosenPlayers` |
| 播放器 tab | 与播放器联动 · 跟随播放器退出(2026-09-03 新增,借鉴清单 #9) | `AppSettings.quitWithPlayers`(Set,默认空 = 关);`PlayerQuitWatcher` 订阅 NSWorkspace 终止 / 启动通知:勾选的播放器**全部**不在跑才算(绑两个退一个不退,可能只是换播放器听),`PlayerLinkage.quitGraceSeconds` = 5s 宽限内任一个重启就取消、到点再核一遍进程表,设置 / 歌词管理 / 歌词窗口这类能成为 key 的窗口开着时不退(用户正在用 Lyrimuse 本身);退出经 `AppExit.request(.followedPlayerQuit)`,日志 `exiting reason=followed_player_quit`。collector 不退(常驻服务,也是「跟随启动」的执行者)。YouTube Music 不在候选:浏览器退出≠播放器退出。被参考的做法没有宽限、立刻 exit(0) |

引导页 `playerChoiceStep` 是同一个 `features.player` 的另一入口。

## 与其它功能的交互

- **collector 独立取数(重要)**:采集器(`lyrimuse-collector/system.go` 的 `getState`/`getAppleMusicState`/`appleMusicPosition`/`spotifyPlayerPosition`、`poller.go` 的 `updatePosition`)是同一套设计的**独立实现**——同样按 features.Player 分派 AppleScript/media-control 两条路、同样的 .auto 检测、同样的 Spotify 位置直查修正、同样的位置平滑思路。两边各自 fork 各自的子进程,互不共享读数;collector 喂 ListenBrainz/网页/歌词解析,本章的 `LocalPlaybackSource` 喂桌面展示面。**改一边只修一半**(Spotify 位置修正就踩过:只改了采集器,悬浮窗还是慢)。
- **歌词同步**:`apply()` 换歌/缓存内容变化时经 `EnrichCacheReader.lookup` 重读 collector 写的歌词缓存,灌进 `LyricsSyncEngine`。**解码全程后台**(2026-08-20 性能审计):缓存是全库单文件(11.6MB/900+ 条、永不清理),collector 给任何一首歌写盘都 bump mtime,原来 mtime 一变就在主线程同步整读+decode(实测 32-47ms/次,专辑预取期每 2s 一停,正撞 20Hz tick 和 30Hz 填色,是播放中肉眼可见卡顿的最大单一来源)——现在 mtime 变化先原样返回旧缓存(陈旧 ≤2s),后台世代号解码完成后主线程原子替换;apply 的触发键是**已解码代**的 `decodedContentVersion` 而不是文件即时 mtime(拿文件 mtime 触发会在 stale 窗口提前吃掉变化,解码完成后就没人再触发 reload 了)。两个例外仍同步解:首次(冷启动/内存压力清空后,保「启动即有词」)和「歌词管理」保存/删除后的 `reloadNow()`(用户显式操作必须立刻读到,并作废在飞的后台结果)。后台解码采纳新内容即经 `onContentAdopted` 回捅一次 poll(否则陈旧窗口是两拍:kick 一拍+发现一拍,暂停档最坏 12s);内存压力清空同时推进世代号(不推进的话在飞解码回来会把刚让出的缓存灌回,极端时序还会倒退一版)——压力让出只在空闲态长效,播放期下一拍就冷启动式重建,是如实记录的取舍。统计页的 `refreshLocalCoversIfCacheChanged` stamp 也改用已解码代版本(用文件 mtime 会在空闲态把变化盖章烧掉)。looseMatch 的全表繁简扫描换成惰性 `cachedLooseIndex`(looseKey→字典序最小原 key,与派生索引同寿命);内存压力(warning/critical)时整个缓存让出(~21MB),下一拍冷启动式重建。解码失败保留旧缓存,下一拍自然重试。`hasLyricsContent`/`isCurrentTrackInstrumental`/`currentTrackHasNoLyrics`/`collectorNetworkDown` 四个互补信号决定各 View 显示"搜索中/纯音乐/无歌词/网络不可用"(分支顺序敏感,详见歌词解析章)。
- **歌词时间轴偏移**:`nudgeLyricsOffset`/`resetLyricsOffset`/`setGlobalLyricsOffset` 经 `LyricsOffsetStore` 存取,`currentLyricsOffsetMs`(实际生效总偏移=全局基准+单曲微调)与 `trackLyricsOffsetMs`(仅单曲部分)分开发布——菜单标题/重置按钮认后者,对齐播放位置的计算认前者。
- **封面与取色**:换歌时经 `MediaControlClient.fetchArtwork`(统一走 media-control,含 Apple Music)异步取一次封面,带 payload 曲目标识核对 + 递增重试 + 3s 兜底过期 + 3s 后二次确认;`artworkAverageHex` 供"跟随封面"外观模式,提亮/对比处理按消费面(灵动岛 vs 桌面悬浮)在 `PlaybackCoordinator` 分别做。
- **播放控制 UI**:悬浮窗/灵动岛按钮、全局快捷键经 `PlaybackCoordinator` → `MusicPlaybackController`;按钮显隐依赖 `supportsExtendedControls`/`favoritedState()` 返回 nil 与否。
- **App 联动**:`PlaybackPlayer.bundleIdentifier` 同时被 `AppDelegate`("打开 Lyrimuse 时启动播放器")使用;.auto 返回空字符串使该联动自然 no-op。2026-09-03 起按 `launchPlayersOnLyrimuseOpen` 集合逐个启动(只启动没在跑的、不抢焦点),同一处挂上 `PlayerQuitWatcher.start()`;三项联动的纯判定在 `LyrimuseCore/Local/PlayerLinkage.swift`(selftest `players` 组 14 条),设置行在 `Settings/PlayerLinkageRow.swift`。
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
| 播放器展示名/品牌色/占位符号 | `lyrimuse/Settings/FeatureSettingsStore.swift` · `extension PlaybackPlayer`(`displayName`/`tintColor`/`fallbackSymbolName`) |
| 图标卡片(引导页 + 设置页共用) | `lyrimuse/Settings/PlayerChoiceCard.swift` · `PlayerChoiceCard` / `MorePlayersComingCard`(后者只在引导页用) |
| 图标网格摆放顺序 | `lyrimuse/Settings/FeatureSettingsStore.swift` · `PlaybackPlayer.displayOrder`;判据 `lyrimuse/Settings/AppSettings.swift` · `AppSettings.userReadsSimplifiedChinese` |
| 真实 App 图标解析(共享缓存) | `lyrimuse/Settings/AppIconResolver.swift` · `AppIconResolver.icon(forBundleID:)` |
| 网页平台图标(自带素材 + 镂空垫白) | `lyrimuse/SettingsView.swift` · `PlayerSettingsTab.platformIcon(_:)` / `youtubeMusicIcon` / `spotifyIcon` / `whiteFilledCutouts(image:)` |
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
12. ⚠️ **离屏 harness 窗口截不了图,只能截"真身份"App 的窗口**(2026-08-25 排查坐实,验证 `PlayerChoiceCard` 网格排版时踩到):`swiftc` 现编现跑的裸 Mach-O 二进制自己开一扇 `NSWindow`,即使 `onscreen=true`(CGWindowList 确认过),`screencapture -l <id>` 一律报 `could not create image from window`——跟这台机器上 `AXIsProcessTrusted()` 恒为 `false`(这个 shell/调用进程没有拿到「辅助功能」信任,给哪个新编译的二进制都一样)大概率是同一类限制:没有正式签名/bundle 身份的进程,窗口内容拿不到。真机验证只能对着 `build.sh` 装出来的、真正签过名的 `Lyrimuse.app` 截——而它自己的窗口如果被另一扇窗口完全遮住,同一个 `-l` 调用也会报同样的错(实测「引导」窗被「设置」窗完全盖住时截不出来,挪开/换到没被挡的窗口就正常)。这条链路上没有不涉及点击的解法:AX 拿不到信任、装了新二进制也拿不到,唯一稳的路是让目标窗口本来就没被挡。这次的图标网格排版靠人工核算(卡片高度×2行+文案行高)过了预算,没能拿到一张真实截图收尾,已经请用户自己开一次引导页确认——**用户随后截图确认排版正常,2 行 3 列没有跟底部「上一步/下一步」重叠**,人工核算这次是准的。

13. **图标网格的摆放顺序按系统语言排,不是按 `PlaybackPlayer.allCases` 的声明顺序**(2026-08-25 用户要求,`PlaybackPlayer.displayOrder`):Apple Music 恒排第一、「自动识别」恒垫底,中间四个按 `AppSettings.userReadsSimplifiedChinese` 二选一——简体中文语境国内三家(QQ/网易云/酷狗)排在 Spotify 前面,非简体中文(含繁体中文、英文等)反过来。判据是系统**首选语言列表第一项**的字符串前缀/子串匹配(跟 `L10n.current` 同一套朴素写法,不依赖 `Locale.Language.script` 这类新 API 在不同系统版本上是否可靠),不是这批"读不读中文"的 `AppSettings.userReadsChinese`——那个繁简不分,会把台/港/澳用户也并进"排国内播放器优先"这一档,而这批用户对国内三家的使用率其实更接近英文用户。`displayOrder` 只影响引导页和设置页这两处图标网格,`allCases` 本身及别的消费点(按 bundle id 查找,不关心顺序)都没动。

14. **"陆续支持中"的提示是网格里第 7 张卡,不是文案**(2026-08-25,一次返工才落到位):用户第一次说"在最后面加几个点标识陆续支持中"时,理解成文案末尾加「……」,改完发截图纠正——指的是六张真选项排完 2 行后网格自己空出来的第三行第一格。改法:`playerChoiceStep` 的 `LazyVGrid` 在 `ForEach(PlaybackPlayer.displayOrder)` 后面紧跟一张 `MorePlayersComingCard`(不用 `Button` 包、没有选中态描边/底色,虚线框+三个点跟六张真选项区分开,不会被当成"点了没反应的坏按钮"),`LazyVGrid` 按声明顺序自然往下排,不用另外指定网格坐标。**只在引导页用**——设置页那张卡六个选项正好铺满 2 行,不需要它。
15. **图标网格从引导页搬到设置页时,连带把"已信任的其它播放器"卡也一起改了**(2026-08-25 用户要求"和谐"):这张卡跟"播放器"卡紧挨着,原来每一行的图标是通用的 `checkmark.seal` SF Symbol,跟旁边六个内置播放器清一色真图标放在一起会显得脱节。给 `SettingsRow` 加了一个新的可选参数 `iconImage: NSImage?`(跟已有的 `icon: String?` 二选一,优先判 `iconImage`),让"已信任的其它播放器"列表也能显示这些第三方 App(比如 Arc 浏览器)自己的真图标——原有全部调用点没传这个新参数,行为不受影响。顺带给这张卡也加了一个 `SettingsCardHeader` 标题("已信任的其它播放器"),跟"播放器"卡的标题成对,不是"一张有标题一张没有"。图标查找收拢进 `AppIconResolver`(见代码锚点),同一份缓存三处共用(此前"正在播放"面板角标和 `PlayerChoiceCard` 各自维护过一份)。

    - **2026-09-01 补齐最后一处漏的**:同一条理由当时**只改了"已信任"那张卡**,而「发现未知播放器」那张(`unknownPlayerCard`,一键「加入信任列表」的那张)还留着通用的 `questionmark.app.dashed`。用户点名要它也显示真图标 —— 而它恰恰是三张卡里**最需要图标的一张**:另外两张里的 App 用户本来就认识,这张问的是"这个你没见过的 App 要不要信任",图标正是他判断"这是我刚在用的那个浏览器"最快的线索,比 `subtitle` 里 bundle id 那行小字快得多。改动就是给那个 `SettingsRow` 传一个 `iconImage: AppIconResolver.icon(forBundleID: seen.bundleID)`。
    - 取不到图标(理论上不太可能:它此刻正在报播放、必然装着)才退回虚线问号 —— 那个占位本身仍然成立:"这个 App 是谁我们还不确定"。实测确认 `NSWorkspace.urlForApplication(withBundleIdentifier:)` 对截图里那个 `company.thebrowser.Browser` 取得到 32×32 的 Arc.app 图标,不存在的 bundle id 如实返回 nil。

⚠️待核对:设置为「自动识别」且实际在播 Apple Music 时,playPause/上一首/下一首经 `MusicPlaybackController.dispatch` 走 media-control(只有 seek 有 `preferAppleScript` 覆盖)——代码注释断言 media-control 控制指令对系统 Now Playing 焦点生效、应可控制 Music.app,但仓内未见对这一具体组合的实测记录。

16. **YouTube Music 的广告要在 UI 上显示「广告中」,于是 Swift 侧改成"放行并标记"、Go 侧照旧拒**
    (2026-09-03,用户原话「帮我把 chrome 上播放的 youtubemusic 的广告也像是 spotify 那样显示
    当前是广告出来」)。
    - **接的是上面那套检测的下一步**:检测(`ytmusicad.go` / `YouTubeMusicAdProbe`)已经能认出
      广告了,但缺口在展示——驱动 UI 显示广告的是 `LocalPlaybackSource.isCurrentTrackAdBreak`,
      而它的判据写死了 `isSpotify && …`,YT Music 的广告点不亮它;更靠前的
      `trustedPlaybackRejected` 还会把广告快照**整条丢掉**,UI 根本拿不到东西。
    - **为什么"放行"不会让广告被记录**——这条不是推断,是逐条核过的(2026-09-03):
      - Swift 全树搜 `track.scrobble` / `submit-listens` → **零命中**;提交 listen 全在
        collector 的 `lastfm.go` / `lb.go`,那边由 Go 侧的拒继续拦。
      - **enrich 缓存**:Swift 侧写它只有 `saveEdit` / `savePlainTextEdit`,三个调用点全在
        "用户点了候选"的闭包里,**没有按播放自动写入的路径** —— 所以广告快照流进来不会
        变成永久条目(这条是 ls-Kelly 复核时点名要查的风险面,查完没有兑现)。
      - 没有 App→collector 的"请解析这首"通道;collector 全树搜 `"np:` **零命中**,不读
        App 那几个键。
      - 封面中继是 collector→外部,Swift 没有发送端。
    - **唯一被新引入的落盘点已经堵上**:`np:lastTrack*`(停播页/待机页/歌词窗口读的"上次在听")
      原本会被广告覆盖。修法是把广告判定**提到 `apply(_:)` 里那段落盘之前**算,落盘条件加
      一道 `!adByFields`。在此之前不需要管,因为广告根本走不到那里。
    - ⚠️ **展示口径与 fail-closed 方向相反,不能顺手共用同一个判断**。收成两个纯函数:
      - `gate(artist:verdict:)` —— 要不要采纳这条播放。拿不准(判定缺失)时**当广告丢掉**:
        漏认一首歌只是这一轮没识别,认错一条广告是永久写进收听历史。
      - `showsAdBadge(verdict:)` —— 要不要在界面上说这是广告。拿不准时**必须当成不是广告**:
        探针会真的超时(osascript 卡住、浏览器没给自动化权限,实测发生过),那时判定是缺失的;
        若跟着 gate 的口径走,就会在一首**真歌**上打「广告中」。
      一句话:**丢弃可以宁枉勿纵,贴标签必须宁纵勿枉。**
    - 收成纯函数的动机就是可测:原来这三条出口在 `MediaControlClient.trustedPlaybackRejected`
      这个 `private static` 里,selftest(独立 target)看不见,而其中一条正是这次特意改掉的。
    - 回归口径:selftest **ALL PASS**(本条新增 9 条断言);**7 个变异全部被抓、0 漏**,含
      "把广告改回丢弃"(= 本次改动被改回去)和"showsAdBadge 顺手共用 gate 的口径"(= 上面那条
      反向陷阱)两条。
    - ⚠️ **未做端到端界面验证**:本仓禁止用 AppleScript/System Events 驱动界面,而复现需要
      在 Chrome 里播 YouTube Music 一直等到插广告。已验的是判据层与数据层。
      (2026-09-03 补:那天顺路在 Edge 上撞到了真广告 —— media-control 里两条独立条目
      `Strepsils HK` / `八達通 Octopus Hong Kong` 当 artist、album 空,数据形状跟这里
      记的一字不差。界面那一半仍未逐像素核对。)

17. **YouTube Music 每条队列的第一首没有专辑名,靠同一次探针从页面上补**(2026-09-03)

    用户报「YouTube Music 播一张专辑的时候,第一首歌怎么不上送专辑名」。**是真的,而且不是
    我们这条链路丢的** —— 当场用 `media-control get` + 在页面上读
    `navigator.mediaSession.metadata` 对照,两边**完全一致**(都是空)。

    | 时间 | 队列位置 | 曲名 | 页面 byline 上的专辑 | `mediaSession.album` |
    |---|---|---|---|---|
    | 02:22 | #0 | Reasons, i love you | Reasons, i love you | **空** |
    | 02:24 | #1 | Not enough seasons | Reasons, i love you | 有 |
    | 02:27 | #2 | Be kind to myself | Reasons, i love you | 有 |
    | 02:29 | #0(另一张) | Heavy on Me | **Already Gone** | **空** |

    - **机制**:YT Music 开一条新队列时,在专辑上下文解析出来**之前**就把 MediaSession
      元数据设好了,之后**不再刷新这一首** —— 所以页面 byline 后来拿到了专辑名,
      MediaSession 里那份却永远停在空;第二首起队列数据已经在手,就带上了。
    - ⚠️ **最后一行是关键反例,别把规律记成"同名去重"**。中途一度以为是"专辑名和曲名相同时
      YT Music 就省掉 album"(第一张专辑的第一首正好是同名主打曲,四个已知样本全对得上,
      连 02 章里原有的 `Bad`/`死神`/`September` 三个老样本也对得上)。第四行推翻了它:
      `Heavy on Me` 的专辑是 `Already Gone`,**不同名,照样是空**。规律就是"队列第一首"。
    - **补法:搭 `YouTubeMusicAdProbe` / `ytmusicAdProbe` 现有那次 JS 往返的顺风车**,零额外
      AppleEvent。这不是省事 —— 那道广告复核**本来就只在 album 为空时才发生**,正好是需要
      补的那一刻,时机严丝合缝。探针返回值从 `a|b|c` 变成 `a|b|c|album`。
    - **认专辑靠 `browse/MPREb` 前缀**:byline 里歌手链接是 `channel/UC…`、专辑链接是
      `browse/MPREb…`。所以这一条**跟语言无关**(不受 byline 里「2026年」这类本地化后缀
      影响),也不会把歌手或播放量误当成专辑。⚠️ 用**遍历 + indexOf**而不是 CSS 属性选择器
      `a[href*=…]`:选择器里那个值含 `/`,不加引号不是合法 CSS 标识符,而加引号只能加单引号
      —— 单引号已经被外面那层 JS 字符串占了(JS 里只许用单引号,见第 16 条那条纪律)。
    - **专辑名放最后一段**,解析按"最多切 4 段"切:专辑名是任意文本、可以自带 `|`。用普通
      split 的话专辑名里一个竖线就会让整条读数退化成"形状不对",**连带把广告判定一起丢掉**。
    - **补的判据是纯函数**(`YouTubeMusicAdProbe.albumPatch` / `ytmusicAlbumPatch`,两侧同一套),
      三条同时成立才补:上游报的是空(**非空一律不动** —— 上游是权威,探针只补缺不纠正)、
      探针读到非空、这一条判定成**歌**(广告没有专辑,广告期间 byline 上读到的多半是上一首的
      残留,补上去等于给广告安一个别人的专辑名)。
    - ⚠️ **补的动作必须在守卫之后**:"album 为空"正是触发广告复核的唯一入口,先把专辑名补进去
      再过守卫,等于把广告检测整个绕过去(广告的 album 也是空的)。顺序反了不会报错,只会让
      广告悄悄进来。Swift 侧那个 `snapshotWithProbedAlbum` 的注释里钉着这句。
    - **两侧都要改**,不是只改一边:Swift 侧管 UI 显示的专辑名,而**歌词匹配和打卡到 Last.fm
      的专辑字段走的是 collector**(它自己独立读 media-control)。只改一边的表现是"界面上有、
      Last.fm 上没有",极难对上。
    - **新增一条比 marker 更硬的跨语言闸**:原来的守卫只检查 `ytmusicad.go` 里"关键字都在",
      保证不了两段 JS **真的**一样。现在直接把 Go 侧反引号拼出来的那串取出来,跟
      `YouTubeMusicAdProbe.probeJS` **逐字比**。这条不是锦上添花 —— 变异测试里把 Go 侧的
      `browse/MPREb` 改成 `browse/MPREc`,**旧的 marker 守卫没逮到**(因为同一个文件的**注释**
      里还写着 `browse/MPREb`,`contains` 照样为真),逐字比那条当场红。
    - 回归口径:selftest **2241 条 ALL PASS**(本条新增 23 条断言),collector `go test ./...`
      通过;**3 个变异全部被抓**(Go 侧 JS 改一个字符 / Swift 去掉"上游已有专辑名就不动" /
      Go 侧让广告也补专辑名)。

19. **Spotify 网页版的广告也要认 —— 但判据跟 YouTube Music 完全不同**(2026-09-03)

    用户要求"把 spotify 的网页广告识别也加上"。查下来**问题跟"没做识别"不是一回事**:

    - 原生 Spotify 客户端的广告一直好好地显示「广告中」;
    - **浏览器里的** Spotify 广告会让整个 UI 塌 30 秒 —— 菜单栏收回小图标、灵动岛/悬浮窗
      一起消失,广告完了再弹回来。当天日志里那行 `slot rebuild: icon(38.5) -> fixed(...)`
      就是广告结束、歌词槽重新长出来的一瞬间。

    **根因**:Spotify 网页广告的字段形状是(现场抓的真实样本,同一批广告 6 次采样一致)

    ```
    title="广告"   artist=""   album=""   duration≈30s
    ```

    **artist 是空的**,而 `MediaControlClient.trustedPlaybackRejected` 里那道
    `guard !artist.isEmpty else { return true }` 短路在任何页面复核之前就把它整条丢掉了。
    YT Music 广告走得到复核,是因为它的 artist 是**广告主频道名、非空**。原生客户端不受这道闸
    约束(内置播放器在 `notASong` 第一行就 return false)—— 所以**只有浏览器里的 Spotify
    掉在这个洞里**。

    修法与第 16 条同向:**Swift 放行并标成广告、Go 照旧拒**。

    - **判据:四个 `data-testid`,任一命中即广告**(`SpotifyWebAdProbe.probeJS`)——
      `ad-controls` / `context-item-info-ad-subtitle` / `ad-countdown-timer` / `ad-link`。
      2026-09-03 现场对照样本(Safari + open.spotify.com,同一张专辑连播):

      | 采样 | 曲目 | 四个标志 |
      |---|---|---|
      | 4 次歌曲态 | 三年二班 / 東風破 / 妳聽得到 / 同一種調調 | `0\|0\|0\|0` |
      | 6 次广告态 | 跨 **3 条连续**广告(Uber「第 1 个,共 3 个」) | `1\|1\|1\|1` |

    - 用 `data-testid` 而不是文字,因为**跟语言无关** —— 页面上那句「广告 • 第 1 个,共 3 个」
      是跟界面语言走的,英文界面下是 "Advertisement"。
    - ⚠️ **绝不能用 `[data-testid*=ad]` 子串匹配**:歌曲态里就有 `add-button`(含 "ad"),
      会把每一首真歌都判成广告。selftest 有一条机械闸钉住 `probeJS` 里不许出现 `*=`
      (变异测试验过:改成子串匹配当场红)。同理页脚那个 `Tailored Advertising Opt-out`
      也不能算 —— 它在歌曲态一直在。
    - ⚠️ **判据只用"广告在场"的正向标记**,不用"标题里没有 ` • `"或"曲目链接缺失"这类**缺失**
      型信号:页面加载/切歌的一瞬间它们同样成立,会在真歌上闪出「广告中」。这跟 YT Music 那边
      刻意留一条"裸标题"兜底**方向不同**,因为调用语境不同:那边是"拿不准就丢掉"(误判只损失
      这一轮),这里是"拿不准就维持现状",而误判的代价是在真歌上贴广告标签。
    - **闸只有两个出口**(比 YT Music 少一个):`.acceptAsAd` / `.reject`。走到这条路上的播放
      本来就要被丢掉(歌手名为空),判定说"是歌"也不能让它变成一首可采纳的歌 —— 真歌不会没有
      歌手名,那多半是别的网页音频。判定**缺失**一律 reject(fail-closed:最坏是回到改动前
      "广告让 UI 塌一下",不是"在真歌上贴广告标签")。
    - **探测门槛 `fieldShapeNeedsProbe` = 标题非空 + 歌手为空**。这不是省性能的优化,是**避免
      两条探针互相踩**:artist 非空、album 空那一档是 YT Music 探针的领地,两条都发 AppleEvent
      的话,配对了两个平台的浏览器(这台机器上 Safari / Arc)每一轮要背两次 osascript 往返。
    - **放行之后不需要再传标记**:`LocalPlaybackSource` 那套 `adByFields` 本来就认这个形状
      (`isSpotify && !title.isEmpty && (album 空 || artist 空)`,而 `isSpotify` 2026-09-02
      起已经包含网页版),所以这里只要**不丢**,「广告中」自然就亮了。
    - **Go 侧不做**:它的职责是"别把广告打卡上去",而它现在就已经拒(`trustedPlaybackNotASong`
      见 artist 为空直接拒,连复核都不用)。加一份探针只会多一次 AppleScript 往返、得到同一个
      "拒"。这条不对称是有意的,跟第 16 条同源。
    - **顺带抽了一份共享模板**:`BrowserTabProbeScript`(在某浏览器里找匹配域名的标签页、跑一段
      JS、把返回值拿回来)。那段 AppleScript 的每一行都是踩出来的(先扫当前标签页躲 Arc 休眠、
      `with timeout` 兜挂起、两种方言的注入命令不同名、脚本写临时文件躲多层引号),复制第二份
      等于把教训复制一份再等它们漂开。抽取当天用 harness **逐字节**比对过:两种方言的输出跟
      抽取前完全相同(chromium 2769 字符 / safari 2763 字符)。selftest 另有一条闸:把两个探针
      各自的域名和 JS 抠掉之后骨架必须逐字相同(变异测试验过:给 Spotify 那份换个超时当场红)。
      ⚠️ `BrowserPositionProbe` 那一份**没有**并进来 —— 它多两样东西(JS 里的
      `__EXPECT__`/`__TOL__` 占位符要在拼进 AppleScript 之前替换;按用户配对过的平台逐条试
      多份站点规则、命中即返回),硬套会长出两个只有一个调用方用得上的参数。
    - 回归口径:selftest **2309 条 ALL PASS**(本条新增 42 条断言);**4 个变异全部被抓**
      (JS 改子串匹配 / 判定缺失改成 fail-open / 探针模板漂开 / 探测门槛放宽到"只要标题非空")。

20. **来源角标:浏览器里放 YouTube Music / Spotify 网页版时画平台图标,不画浏览器**(2026-09-03)

    用户原话:"这里显示 youtubemusic,如果确实是 youtube music 的情况下,不再显示浏览器;
    如果是浏览器里面播放 spotify 就显示 spotify;其他的不是这两个的话就正常显示浏览器图标"。

    判据收在纯函数 `BrowserPositionProbe.resolvePlayingPlatformID(pairedPlatformIDs:recentMatch:)`
    (selftest 8 条覆盖),**证据优先、推断兜底**两档:

    1. **最近一次探测真的命中过某个平台** → 就是它。这是硬证据:探测成功意味着刚从那个
       站点自己的 DOM 里读到一个**在走**的进度。一个浏览器同时配对了两个平台时(这台机器
       上 Safari / Arc 都是),只有这一档答得上来。
    2. **只配对了一个平台** → 推断成它,**不用等探测成功**。覆盖绝大多数人的实际配置,也是
       这台机器上 Edge / Chrome 的形状 —— 用户截图里那枚 Edge 角标就靠这一档立刻变成
       YouTube Music。
    3. 两档都答不上来 → nil → 照旧画浏览器图标。

    - **第 2 档是推断不是证据,可能错**:浏览器里放别的、恰好也带齐 artist+album 的网页
      音源(播客站之类)时角标会显示成那个平台。代价是**纯观感**的 —— 点击仍走
      `openResolvedPlayerApp()` 按 bundle id 唤那个**浏览器**,行为一个字不变(YouTube Music
      是个网站,没有 App 可唤)。同款推断 `LocalPlaybackSource` 判"网页版 Spotify 广告"时
      早就在用(`isPaired(…platformID: "spotifyWeb")`),不是新开的口子。
    - ⚠️ **第 1 档要求命中的平台仍在配对表里**:用户后来取消配对了,探测就不跑了、那条旧
      证据再也刷新不掉 —— 认它的话角标会永远挂着一个已取消的平台。
    - 证据保质期 `matchedPlatformMaxAge = 15min`。按"证据什么时候过期"取的:探测每次换歌
      都重新发起,正常听歌几分钟刷新一次;只有"暂停很久"或"换成了没有站点规则的网页音源"
      才会变旧,后者正是该退回浏览器图标的场景。
    - ⚠️ 入口自己做**媒体代理别名解析**(Safari 报 `com.apple.WebKit.GPU`、配对表里存
      `com.apple.Safari`)。这一步漏掉的后果这一章已经记过一次(第 279 行那条:"配对了却
      永远不同步",而且一条日志都没有)。
    - **顺带修的真 bug**:`probeAdvancing` 的两拍采样原来**不检查是不是同一个平台**。同时
      开着 YouTube Music 和 Spotify 网页版、两拍之间规则优先级翻个个儿时,会拿 A 站的读数减
      B 站的读数去判"进度在不在走" —— 那个差值既可能碰巧为正(把另一首歌的位置安到这首上),
      也可能碰巧为负(白白弃用一次真读数)。现在两拍不同平台直接弃用,并落一条 notice。
    - **tooltip 顺带对了**:`resolvedPlayerDisplayName` 原来对浏览器一律返回 nil(悬停是空的,
      它只查 `PlaybackPlayer.allCases`),现在认得出平台时给「YouTube Music」/「Spotify」。
      歌词窗口那两处「正在播放于 X」跟着受益。
    - 真机验证(2026-09-03 03:16,装机后):Safari 里放 Spotify 网页版,新日志行
      `探针 #1: 采信 194.000000s(…,平台 spotifyWeb)` 连续两次命中 —— 也就是第 1 档的输入
      确实拿到了 `spotifyWeb`,角标据此画 Spotify。Edge 那一侧(只配 youtubeMusic)走第 2 档,
      用真实配对表离线跑过判据。
