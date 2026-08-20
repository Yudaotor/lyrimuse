# 07. 歌词窗口
> 最后核对:2026-08-17 · 基线:2a2bf8b+工作树

## 定位

一扇正经的标题栏窗口(SwiftUI `Window(id: "lyrics-window")`),按 Apple Music 歌词页的样式展示当前曲目的**整份歌词**:完整歌词列表 + 当前行高亮 + 自动滚动,左侧配封面卡、进度条和播放控制。它与「桌面悬浮歌词」「灵动岛歌词」那种"只看当前一句"的无边框浮层是完全不同的形态,**不复用**它们的外观主题设置(前景色/描边/字体/字号等),默认吃系统原生颜色、有封面时切白色系。

## 入口与展示面

- **菜单栏菜单**:状态栏图标菜单里的「歌词窗口…」项(自建 NSStatusItem 菜单,`MenuBarStatusMenu`),单独成组排在「设置…」「歌词管理…」之后。
- **全局快捷键**:设置页快捷键分区「打开歌词窗口」(`openLyricsWindowHotkey`)。默认**不预置**按键,必须用户自己录制才生效。
- 两条路径都汇到 `AppActions.shared.openLyricsWindow`,由一扇隐藏锚点窗口(`MenuBarSceneActions`)捕获的 `openWindow(id:)` 环境 action 执行,调用前先 `NSApp.activate(ignoringOtherApps: true)`(accessory 策略下不激活的话 openWindow 静默没反应)。
- 打开期间若「在 Dock 中显示」是关的,会**临时借一个 Dock 图标**(`AuxiliaryWindowActivation` 计数器,与设置/歌词管理/引导窗口共用),全部辅助窗口关完才还原成无 Dock 图标。
- 窗口尺寸约束 `minWidth 520 / idealWidth 1020 / minHeight 480 / idealHeight 660`;位置/尺寸交给 SwiftUI+macOS 的窗口自动存档机制,无自写持久化代码。⚠️待核对:退出 App 重启后这扇窗口是否会随系统状态恢复自动重开(代码只声明交给系统存档,未见显式处理,未实测)。
- Dock 图标点击(reopen)只打开**设置**窗口,不会打开歌词窗口。

## 行为规格

### 布局:双列/单列

- 窗口宽 ≥ 640pt 时是双列:左列播放器面板(宽 = min(窗口宽 × 0.42, 460pt)),右列歌词列表;宽 < 640pt 退化成只有歌词的单列——与 Apple Music 把窗口拖窄时的行为一致。老用户从旧版竖长窗口存档尺寸(~460pt)升级上来,第一次打开就是单列。
- 右上角浮着两个玻璃胶囊(音量 + 窗口动作),是 `.overlay(alignment: .topTrailing)` 浮层而**不是** `.toolbar` 项——工具栏本身是玻璃,玻璃采样不到玻璃,放进去会退化成不透明灰块(Liquid Glass 规则,macOS 26 的 `.clear` 材质,见 `SettingsDesignSystem.clearGlassCapsule`)。

### 歌词列表:自动滚动与当前行

- 数据源是 `PlaybackCoordinator.allLines`(`[LyricsWindowLine]`),整首歌全部行一次性构造,同一首歌播放期间不重算;每行 id = 曲目标识前缀 + 行下标,换歌后 id 集合整体不同,ForEach 做干净的整体替换而不是逐行"变形"(避免换歌瞬间串行/闪烁)。
- 当前行由 `PlaybackCoordinator.currentLineIndex` 决定;每次换行,`ScrollViewReader.scrollTo` 把当前行滚到窗口**从上往下 35% 处**(`activeLineAnchor`,不是正中——上面留已唱过的行,下面留更多将唱的行)。
- 滚动与行样式变化用**同一条**动画曲线 `lineTransition = .smooth(duration: 0.45)`(无回弹弹簧),两套动画节奏一致,不会"一顿一顿"。
- **没有"手动滚动暂停跟随"机制**:自动跟随永远生效,用户往回翻歌词后,下一次换行会被拉回当前行;想主动回去点右上角胶囊里的「回到当前播放」(location.fill 图标)。这个取舍是刻意的(照抄歌词管理窗口 `focusCurrentlyPlaying` 已验证过的简单方案,不做 `scrollPosition(id:)` 侦测)。
- 换歌/歌词重载(`onChange(of: poller.allLines)`)后无动画直接跳到新歌当前行;还没唱到第一句时 activeID 为 nil,不滚动,列表停在顶部。窗口刚打开(onAppear)同样无动画定位一次。
- 列表用 `VStack` 而非 `LazyVStack`:歌词只有几十行,lazy 反而让带动画的 scrollTo 卡(目标行没渲染过就没尺寸)。
- 列表上下边缘有渐隐 mask(顶部 0~7.5% 全透明、20% 处全显,底部 90%→100% 渐隐):顶部渐隐让歌词滚到胶囊底下之前就淡掉,不糊在胶囊上;底部渐隐避免被窗口边缘直切一刀。

### 行的景深样式(Apple Music 式)

- 所有行同字号同字重,远近**不靠字号**区分:当前行不透明度 1、零模糊;其余行不透明度 `max(0.35, 0.55 - 0.05×行距)`、高斯模糊 `min(行距 × 1.1pt, 4pt)`。
- 行距按下标算并**夹到 4**(`maxVisualDistance`):d≥4 的行画出来一模一样,输入不变就整行跳过重算(`LyricsLineRow` 是手写 `Equatable` 的——行视图带 onTap/onHover 闭包参数,SwiftUI 自带结构比较对闭包失效,必须只比值输入)。
- 还没唱到第一句(currentLineIndex 为 nil)时整页统一不透明度 0.45、轻模糊 2pt。
- 系统「减少动态效果」(reduceMotion)开启时模糊整个关掉(与缩放同一批"聚焦感"装饰,统一走系统开关,不单加设置项)。
- 字号随歌词栏宽度缩放:主行 `clamp(22, 栏宽 × 0.072, 56)`pt bold(系数是量 Apple Music 截图反推的),罗马音 0.54 倍、译文 0.61 倍、行间距 1.14 倍。
- **对唱歌词**:行带演唱者标记(`LyricDuet.Side`)时按左/右/中分栏对齐;没有标记的歌 side 为 nil,本窗口兜底 `.leading`(悬浮窗兜底是 `.center`,两边不同)。

### 行交互:悬停与点击跳转

- 鼠标悬到某行:该行立即恢复满不透明度、去模糊(0.16s easeOut)——看清要跳去的是哪句再决定点不点。
- 点击某行:`poller.seek(toMs: max(0, 行时间 - currentLyricsOffsetMs))`——**减回歌词偏移**,因为引擎判定当前行时会把 offsetMs 加到播放位置上,不减的话跳过去落在隔壁行。
- 命中区盖满整行(含左右空白),不是只有文字可点。
- 暂停状态下点击也生效(seek 走 pausedPositionMs 冻结位置那条路)。

### 逐字高亮(卡拉OK)

- 只有**当前行**且该行有逐字数据(`line.words` 非空)时走 `KaraokeLineText` 逐字填色;非当前行(以及无逐字数据的当前行)渲染纯文本。
- 填色是"同色 35% → 全强度"的同色系渐变(有封面背景时同色=白,无封面时=系统 primary),不引入强调色;渐变数值算法在 `KaraokeFill`(LyrimuseCore,带自测断言),UI 侧 `WordKaraokeGradient` 只负责转成 LinearGradient。
- 正在唱的字**上浮**:sin 缓动、固定 320ms 窗口(不超过该字自身时长)、幅度 = 字号×0.07 **对齐到整设备像素**(1x 外接屏防重采样发糊);抬起后保持,直到整行不再是当前行才落回。「点头式」(抬了再落)被用户明确否掉过。
- 刷新时钟是两级结构(2026-08-17 定稿):行级 4Hz 粗时钟(`coarseInterval = 0.25s`)只判断每个字"此刻是否正在被扫"(`isLive`,两头各放宽一档粗时钟+80ms 余量);只有正在扫的那个字保留 30Hz 细时钟(`WordKaraokeGradient.refreshInterval`,三处逐字视图共用)。暂停(`!isPlaying`)时全部时钟挂起,开销归零。行尾/间奏/曲末由 `currentLineFillSettled` 停表(2026-08-19,四个逐字展示面同款):粗时钟 paused 并入它,**且必须同时喂给 isLive 判定**——只停粗时钟的话 isLive 冻结在 true,最后一个字的 30Hz 细时钟反而在整段 outro 永动(对抗核实抓出的陷阱);settled 只传给当前行(非当前行恒 false,避免翻转时全表行重算)。时间基准带 `?? pausedPositionMs` 兜底(同日修的暂停 bug:原来 `?? 0` 让暂停触发的重渲染把当前行整行画回"未唱"态,四个展示面同款漏配一起修)。
- 罗马音逐词标注:开着「显示罗马音」且该行有 `wordGroups` 时,读音**逐词**标在正文每组字底下(组内左对齐、读音按整组起止时间填色、不跟着抬升),这时不再单独渲染整行罗马音;拿不到词组时退回正文下方一整行罗马音。
- 时间基准统一为 `anchor.extrapolatedPositionMs(now:) + currentLyricsOffsetMs`——"当前词判定"和"填色进度"必须同基准,否则填到一半卡住。

### 译文/罗马音行

- 罗马音行:「显示罗马音」开 + 该行有 `romanization` + 没走逐词标注时,显示在主行**下方**(与 Apple Music 一致)。
- 译文行:「显示译文」开 + 该行有 `translation` 时显示在最下,次级颜色。
- 两个开关的帮助文案明说"只影响「桌面悬浮歌词」和「歌词窗口」"。

### 左列:封面卡与曲目信息

- 封面卡 1:1 方形、圆角 12、投影;图片优先用**高清替代** `highResArtworkImage`(只在系统 Now Playing 那份实在太小时才有值——网易云客户端只给 100×100,替代图来自 collector 缓存里解析歌词时顺手记下的 cover_url),否则用系统那份 `artworkImage`;都没有时显示灰底音符占位。换图交叉淡入 0.5s,动画收在 overlay 内容上而不是整卡最外层(否则会把别的布局变化 animate 成"进度条从上面飘下来")。
- 曲目两行:歌名(semibold)、「歌手 — 专辑」(专辑缺失只显示歌手),放不下**不截断**而是走 `MarqueeText` 跑马灯(停在开头→匀速滚到底→停住→瞬时回开头)。
- 控制排/按钮尺寸全部按封面实际边长比例算并夹进区间(`ctrl(ratio, lo, hi)`)——封面随窗口缩放,按钮写死尺寸会在窄窗口溢出被裁、宽窗口下不成比例。

### 进度条与拖拽跳转

- 三态:**播放中**(有 `anchor`)用 1 秒一档的 `TimelineView(.periodic)` 从锚点外推位置;**暂停**显示 `pausedPositionMs` 冻结位置;**什么数据都没有**时渲染同尺寸的 `.hidden()` 占位(不占位的话 anchor 到达时整个左栏重排,被封面淡入动画拖成"进度条从上面飘下来")。
- 画出来的进度 `shownFraction` 与算出来的 fraction 分离,补间自己驱动:正常推进用 `.linear(duration: 1)` 补间到 **pos(t+1)**——补间终点提前一秒是修"恒定落后 1 秒"的关键(插值当外推用的经典错误);冷启动/拖动中/reduceMotion 直接赋值不补间。
- 已播条是满宽胶囊 + `scaleEffect(x:)` 横向缩放,**不是**改 frame 宽度——补间落在变换矩阵上,不触发逐帧布局(实测把双列播放中的主线程忙碌从 61.4% 降回单列水平 9.4%);进度 0 时仍留约 4pt 一小截。
- 条高 4pt,悬停 6pt、按住 7pt(弹簧动画;reduceMotion 下仍变粗但不补间——变粗是功能反馈不是装饰)。
- 拖拽:`DragGesture(minimumDistance: 0)`(点一下就跳),拖动中显示手指位置而非真实播放位置,**松手才发 seek**;按下第一帧给一次触觉反馈(`NSHapticFeedbackManager` .alignment)。拖动状态存 `@GestureState`(手势被系统取消时自动复位,`@State` 会永久卡住)。
- 命中区上下各外扩 9pt 再用负 padding 抵回布局高度,且**只覆盖进度条这一行**——不含下面时间行(原来点"剩余时间"文字等于 seek 到 ~95%)。
- 时间行:左边已播 `m:ss`、右边剩余 `-m:ss`,11pt 等宽数字;拖动中两个数字跟手指走。
- `durationMs > 0` 守卫:占位态不会误发 seek。

### 播放控制排

- 五键左右对称:播放模式 | 上一首 | 播放/暂停 | 下一首 | 喜欢。播放/暂停图标宽度固定,防两侧按钮跳动;模式键和心两侧**等宽占位**(各自异步读出,不占位会错开一瞬)。
- 上一首/播放暂停/下一首:直接调 `MusicPlaybackController`(Apple Music 走 AppleScript、QQ/网易云走 media-control 的系统级 MediaRemote 指令),**不做权限预检查**,失败静默(与全局快捷键 B 组不同——那边按下前会 checkForCurrentPlayerSafely、失败 beep)。⚠️待核对:自动化权限从未授权时,点这几个按钮是否会触发系统授权弹窗(osascript 子进程的 TCC 归因行为未实测)。
- **播放模式**(列表→随机→单曲循环,点一下切下一档,图标即当前模式):只在 `poller.playbackMode` 非 nil 时显示——支持范围是 Apple Music + Spotify(`extendedControlPlayer`,Spotify 够不到"单曲循环",只在列表↔随机间切);QQ/网易云无 AppleScript 字典,整个不显示。乐观更新,写失败才回读纠正(写成功不回读——Music.app 的 getter 滞后于 setter)。
- **喜欢**(心,红色实心=已喜欢):只有 Apple Music 有(`poller.isFavorited` 非 nil 才显示;判定看**实际在播**的 bundle id 而非设置选项,"自动识别"下也能出现)。与悬浮窗那颗心是**同一份状态、同一个开关**(`PlaybackCoordinator.isFavorited/toggleFavorited`),乐观更新 + 动作序号守卫(在途旧读数不覆盖刚点出来的新状态)。属性名兼容 `favorited`/`loved` 两代系统。

### 音量胶囊

- 只在 `poller.soundVolume` 非 nil 时显示(同样是 Apple Music + Spotify;Apple Music 还要求自动化权限已授权)。调的是**播放器自己的输出音量**(0~100),不是系统音量。
- 结构:静音开关 | 发丝分隔线 | 自绘滑杆(92pt,轨道+白色横向药丸滑块,不用系统 Slider 的蓝色填充) | 随音量档位变的喇叭图标(0 / 1-33 / 34-66 / 67+ 四档,图标宽度固定防呼吸)。
- 拖动乐观更新 + **单飞合流**写入:同一时刻只允许一次 osascript 在飞(单次 ~100ms,自然收敛到约 10 次/秒),期间新值只存 `pendingVolumeTarget`,回来补写,保证最后松手的值一定落地。写失败才回读。
- 静音是开关:再点还原到静音前的音量,没记录(一进来就是 0)时给 50。

### 窗口动作胶囊:置顶 / 伪全屏 / 回到当前

- **置顶**(pin 图标):`window.level = .floating` 切换。**不持久化**——每次重开窗口从"不置顶"开始,tooltip 明确写了"这个状态只在本次打开这扇窗口期间有效"。
- **伪全屏**(扩/缩箭头图标):不是原生全屏(原生全屏机制在这个 App 里坏着,见"已知坑")。进入 = 保存当前 frame → 隐藏标题栏/红黄绿按钮 → `NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]`(两个必须一起设才生效)→ `setFrame` 撑满**整个**屏幕(含菜单栏/Dock 区域)。退出 = 全部复原 + 恢复保存的 frame。同样不持久化。
- 伪全屏三条退出路径:再点一次按钮 / **Esc**(App 级 local monitor,keyCode 53,只在本窗是 key window 时拦截并消费,否则放行给别的窗口)/ 窗口关闭或**失去 key 状态**时强制退出(`forceExit`,无动画)——`presentationOptions` 是进程级全局状态,不清理会让菜单栏/Dock 在别的窗口/别的 App 下继续藏着。
- 置顶和伪全屏不互斥,可同时开。reduceMotion 下进出全屏不做 frame 动画。
- **回到当前播放**(location.fill):带动画滚到当前行;没有当前行(还没唱到第一句)时不做任何事。
- 真实 NSWindow 由 `LyricsWindowCapture`(NSViewRepresentable)捕获交给 `LyricsWindowController`(每个视图实例自有,非单例;窗口场景本身是 App 内单例)。

### 占位态(无歌词/解析中)

`allLines` 为空时整个右列换成占位(`emptyStateSpec`),按优先级取第一个命中:

| 条件 | 图标 | 文案 |
|---|---|---|
| 曲名为空(什么都没在放) | music.note | 没有在播放 |
| 广告中(`isCurrentTrackAdBreak`) | megaphone | 广告中 |
| 纯音乐(`isCurrentTrackInstrumental`) | waveform | 纯音乐 |
| 解析完确认没有(`currentTrackHasNoLyrics`) | text.badge.xmark | 暂无歌词 |
| 断网且无内容(`collectorNetworkDown`) | wifi.slash | 网络连接失败 |
| 播放中但还没解析到(`isPlayingNow && !hasLyricsContent`) | magnifyingglass | 搜索歌词中… |
| 兜底 | text.quote | 无歌词 |

广告/纯音乐必须排在"搜索中"前面;"暂无歌词"是明确结论,排在"网络连接失败"前面。有封面背景时用自绘白色版本(系统 `ContentUnavailableView` 的文字颜色在深色模糊图上看不清),条件逻辑两版共用。

### 文字颜色策略

- 判据一条:`hasArtworkBackground`(= `poller.artworkData != nil`)。有封面 → 全窗固定白色系(主文字白、次级白 60%、胶囊图标白 90%),**不跟随系统深浅色**;没封面 → 系统 `.primary`/`.secondary` 自动跟随。不会出现"有时看得清有时看不清"的中间态。
- 背景:铺 PlaybackCoordinator 预烘焙的模糊图 `windowBlurredArtworkImage`(2026-08-19:原来是 `.saturation(1.5).blur(72, opaque:)` 活滤镜,~2040px 画布播放期几乎每帧重跑;烘焙参数 720px/sat 1.5/sigma 51,scaledToFill 拉伸后视觉等价,与灵动岛那份共用参数化的 bakeBackgroundBlur 管线)+ 视图层压 22% 黑(对照 Apple Music 逐像素取样校准,故意**不做**亮度自适应,网页端才需要那套),换歌交叉淡入 0.5s(触发键 = 烘焙图实例)。**不加** `.ignoresSafeArea()`——铺到标题栏底下会让系统标题栏文字撞色。

### 状态刷新时机

「喜欢」「播放模式」「音量」不跟 2 秒轮询走(每读一次起一个 osascript 子进程不值当),刷新时机:窗口打开时一次、App 每次重新变成前台一次(`didBecomeActiveNotification`,覆盖"切去 Music.app 点了心再切回来")、换歌时由 PlaybackCoordinator 刷一次。后台刷新路径检查权限用 `askIfNeeded: false`,绝不弹授权框。

## 设置项

本窗口自身**没有专属设置项**(设置页「歌词显示」明确写了它"压根不在这一页配置,靠快捷键/菜单按需打开");受以下共享设置影响:

| 设置项(位置) | 影响 |
|---|---|
| 显示译文(歌词内容 → 译文卡) | 每行下方译文行显示与否 |
| 译文语言 / 无译文时兜底(同卡) | 影响上游译文数据,间接决定行里有没有 `translation` |
| 显示罗马音 + 按语言分开关(歌词内容) | 罗马音行/逐词标注显示与否;语言分开关影响数据侧生成 |
| 打开歌词窗口(快捷键页) | 录制全局快捷键,默认空 |
| 在 Dock 中显示(通用) | 开着时不走"临时借 Dock 图标"逻辑 |
| 歌词偏移步长 lyricsOffsetStepMs(快捷键/菜单共用) | 不改本窗口 UI,但偏移值影响当前行判定与点击跳转补偿 |
| 系统「减少动态效果」 | 关掉行模糊、逐字抬升、滚动/进度补间、全屏 frame 动画 |

悬浮窗/灵动岛的外观设置(前景色、描边、字体、字号、宽度)、「自动隐藏」两项(截屏时隐藏/暂停时隐藏)对本窗口**均不生效**。

## 与其它功能的交互

- **数据同源**:歌词解析结果、当前行判定、进度锚点全部来自 `PlaybackCoordinator`(底下是 `LocalPlaybackSource` + `LyricsSyncEngine`),与悬浮歌词/灵动岛/菜单栏歌词四种形态共享同一份;本窗口独占消费的字段是 `allLines`/`currentLineIndex`/`pausedPositionMs`/`currentDurationMs`(专为它加的)。订阅经 `WindowPlayback` 窄代理(2026-08-19,五个展示面最后一个接上;这窗口实读面大,代理的收益在滤掉 currentLine/nextLineText 等每句白打醒 2~3 次的未读源 + 逐条去重);`soundVolume` 刻意不进代理——音量胶囊(WindowVolumeCapsule)自持订阅,拖音量只失效小胶囊;进度条(WindowProgressSection)自持五个拖动/补间瞬态,1Hz 推进与拖动不再击穿整窗;App 激活的三连 osascript 回读加了窗口可见性守卫(Window 场景关窗后视图树保活)。
- **歌词偏移**:菜单/全局快捷键/歌词管理改的单曲与全局偏移,实时影响本窗口的当前行判定、逐字填色基准和点击跳转补偿;但偏移调整的"歌词 +0.5s"反馈横幅只在灵动岛显示,本窗口无反馈。
- **喜欢/播放模式/音量**:与悬浮歌词控制排是同一份状态和同一套写入路径(乐观更新+序号守卫都在 coordinator),两处点哪个都一样。
- **歌词管理**:「回到当前播放」按钮交互直接照抄那边的 `focusCurrentlyPlaying`;在歌词管理里改了歌词/偏移后,重载会经 `allLines` 反映到本窗口。
- **高清封面替代**:来自 collector 解析歌词时缓存的 cover_url(歌词解析管线的副产品),只在系统 Now Playing 封面过小时启用;同名不同版本的歌可能拿到另一张封面(权衡记录在 `highResArtworkImage` 注释)。
- **Dock 图标借用**:与设置/歌词管理/引导窗口共享 `AuxiliaryWindowActivation.openCount` 计数器;用户在窗口开着期间手动打开「在 Dock 中显示」不会被关窗还原动作覆盖。
- **伪全屏的全局副作用**:`presentationOptions` 影响整个进程——切去 App 内其它窗口(设置/歌词管理)时自动退出伪全屏,防止那边找不到菜单栏;Esc 监听同样是 App 级的,靠 isKeyWindow 判断避免吞掉设置页弹窗的 Esc。
- **播放控制**:与全局快捷键 B 组共用 `MusicPlaybackController`,但权限检查策略不同(快捷键预检+beep,本窗口按钮不预检、静默失败)。

## 数据与文件

- **磁盘文件**:本窗口自身不直接读写任何文件。窗口位置/尺寸由系统窗口状态恢复机制存档(SwiftUI `Window(id:)` 默认行为)。
- **UserDefaults**:只经 `AppSettings` 间接读(showRomanization/showTranslation/showInDock 等);置顶/伪全屏状态**刻意不持久化**。
- **进程边界**:播放控制与音量/模式/喜欢的读写经 osascript 子进程(AppleScript → Music.app/Spotify)或 media-control(MediaRemote → QQ/网易云);单次往返 ~100ms,全部在后台线程/Task 发起。
- **网络**:高清封面替代按 collector 缓存记录的 cover_url 下载(链路在 PlaybackCoordinator/LocalPlaybackSource,本窗口只消费解码好的 NSImage)。

## 代码锚点

| 主题 | 文件 + 符号 |
|---|---|
| 窗口场景声明 | `lyrimuse/Sources/lyrimuse/App.swift` `LyrimuseApp.body`(`Window(id: "lyrics-window")`) |
| 整窗视图 | `lyrimuse/Sources/lyrimuse/UI/LyricsWindowView.swift` `LyricsWindowView` |
| 置顶/伪全屏状态机 | 同文件 `LyricsWindowController`(attach/toggleAlwaysOnTop/enter/exit/forceExit) |
| NSWindow 捕获 | 同文件 `LyricsWindowCapture` |
| 行视图(景深/悬停/点击) | 同文件 `LyricsLineRow` |
| 逐字填色行/字 | 同文件 `KaraokeLineText` / `KaraokeWordText` |
| 填色数值算法 | `lyrimuse/Sources/LyrimuseCore/Lyrics/KaraokeFill.swift` `KaraokeFill`;UI 侧 `lyrimuse/Sources/lyrimuse/UI/WordKaraokeGradient.swift` |
| 进度条 | `LyricsWindowView.progressSection` / `progressBar` |
| 播放控制/喜欢/模式 | `LyricsWindowView.playbackControls` / `favoriteButton` / `playbackModeButton` |
| 音量胶囊 | `LyricsWindowView.volumeControl` / `volumeSlider`;写入合流 `lyrimuse/Sources/lyrimuse/PlaybackCoordinator.swift` `setVolume`/`pumpVolumeWrite`/`toggleMute` |
| 窗口动作胶囊 | `LyricsWindowView.windowActionsCapsule` |
| 占位态 | `LyricsWindowView.emptyStateSpec` / `emptyState` |
| 数据行类型与构造 | `lyrimuse/Sources/LyrimuseCore/Lyrics/LyricsSyncEngine.swift` `LyricsWindowLine` / `LyricsSyncEngine.allLines(idPrefix:)`;赋值收敛 `LyrimuseCore/Local/LocalPlaybackSource.swift`(reloadCurrentLyrics 尾部) |
| seek/偏移转发 | `PlaybackCoordinator.seek(toMs:)` / `nudgeLyricsOffset`;实现 `LocalPlaybackSource.seek(toMs:)` |
| 打开入口桥 | `lyrimuse/Sources/lyrimuse/Settings/AppActions.swift` `AppActions.openLyricsWindow`;捕获 `MenuBar/MenuBarSceneActions.swift`;菜单项 `MenuBar/MenuBarStatusMenu.swift` `openLyricsWindow` |
| 全局快捷键 | `lyrimuse/Sources/lyrimuse/Settings/GlobalHotkeys.swift` `.openLyricsWindowHotkey`;录制入口 `SettingsView.swift` 快捷键分区 |
| Dock 图标借用 | `lyrimuse/Sources/lyrimuse/Settings/AuxiliaryWindowActivation.swift` |
| 跑马灯 | `lyrimuse/Sources/lyrimuse/UI/MarqueeText.swift` `MarqueeText` |
| 玻璃胶囊样式 | `lyrimuse/Sources/lyrimuse/Settings/SettingsDesignSystem.swift` `clearGlassCapsule` |

## 设计决策与已知坑

1. **原生全屏在这个 App 里坏着,根因未明**:绿色按钮是 AXZoomButton 而非 AXFullScreenButton,`AXFullScreen` 恒 false,连菜单「进入全屏幕」命令也不生效;collectionBehavior/.regular 策略/LSUIElement/MenuBarExtra 四个假设逐一真机证伪。伪全屏是用户拍板的替代方案(`LyricsWindowView.swift` 文件头注释)。
2. **`presentationOptions` 是进程级全局状态**:必须 willClose + didResignKey 双兜底清理,否则伪全屏残留会让别的窗口/别的 App 找不到菜单栏。
3. **Esc local monitor 是"发给本 App 任意窗口"级钩子**:早先注释声称按窗口过滤但回调没做,吞掉了设置页弹窗的 Esc;现在显式判 `isKeyWindow`,与 didResignKey 兜底是两道独立防线。
4. **进度条"恒定落后 1 秒"**:补间终点必须取 pos(t+1) 而不是刚算出的当前位置——两档采样间做插值画出来的永远是过去(把插值当外推用)。
5. **进度条填充用 scaleEffect 不用 frame 宽度**:布局属性跟着每秒线性补间走会逐帧重布局整个 NSHostingView(实测双列 61.4% 忙 vs 单列 9.4%)。
6. **逐字时钟两级化**:TimelineView 必须下沉到字级叶子(挂在行容器上会每帧推翻 WrapLayout 重算),再叠 4Hz 粗时钟 + 只给"正在扫的那个字"留 30Hz 细时钟(一行十几个相位不齐的满速时钟并集盖满每个显示帧,主线程 85.8% 忙的根因)。
7. **`LyricsLineRow` 的 Equatable 必须手写**:带闭包参数的视图 SwiftUI 结构比较直接失效;配合 `maxVisualDistance = 4` 让远处行输入不变,换行重算范围从整表缩到当前行上下各 4 行。
8. **当前行的 scaleEffect(1.02) 已删除**:渲染后仿射变换在 1x 外接屏上把最该看清的一行糊掉(字形边缘过渡宽度实测 1.48px vs 1.14~1.25px),而强调感实际由满不透明度/零模糊/逐字填色扛着。
9. **拖动状态用 @GestureState 不用 @State**:手势被系统取消(进度条所在条件分支被摘掉)时不会调 onEnded,@State 会永久卡住拖动值、冻结进度条。
10. **背景不 ignoresSafeArea、玻璃胶囊不进 toolbar**:前者会顶到标题栏底下让系统标题栏文字撞色;后者是"玻璃采样不到玻璃",toolbar 里的 Liquid Glass 胶囊退化成不透明灰块。
