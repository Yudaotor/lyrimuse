# 04. 桌面悬浮歌词
> 最后核对:2026-08-27 · 基线:0bb53e6+工作树

## 定位

贴在桌面上的无边框悬浮歌词窗(代码里叫"经典悬浮窗"/classic overlay):常驻置顶、跨 Space(含全屏 App 上方)、默认点击穿透,只显示当前一句(可选罗马音/译文/下一句预览),逐字歌词做卡拉OK渐变填色。它是三种悬浮展示形态(桌面悬浮/灵动岛/菜单栏)中可定制度最高的一种,也是字体/字号/配色这组设置的唯一消费者。

## 入口与展示面

| 入口 | 说明 |
|---|---|
| 设置 → 外观 → 悬浮歌词 段 | 总开关(`classicOverlayEnabled`)+ 全部外观/窗口设置;段顶钉着实时预览条(OverlayPreviewBar) |
| 菜单栏 → 快速开关 → 显示桌面悬浮歌词 | 切换同一个开关;「锁定位置」菜单项只在悬浮窗开着时出现 |
| 全局快捷键 | `toggleOverlay`(显示/隐藏)、`toggleLockPosition`(锁定/解锁);默认不预置按键,须用户在设置里自己录制 |
| 首次启动引导 | 显示形态那一步可以直接开启(OnboardingView) |

三个入口最终都走 `LyricsOverlayWindowController.setVisible(_:)` 这个唯一入口,真值持久化在 `AppSettings.classicOverlayEnabled`。悬浮窗与灵动岛是两个独立开关、互不排斥,可同开同关。

## 行为规格

### 窗口形态

- `LyricsOverlayWindow` 是 NSPanel 子类:`[.borderless, .nonactivatingPanel]`、透明背景、`level = .floating`、`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`。`canBecomeKey/Main` 均为 false——点它永远不会打断用户正在操作的其它 App。
- 内容是 SwiftUI(`LyricsOverlayView`)经 NSHostingView 承载。内容结构从上到下:播放控制按钮排(槽位常驻,不显示时透明且不接受点击)→ 歌词卡片(主行 → 罗马音 → 译文 → 下一句预览 → 首次解锁的拖动提示)。内容整体贴窗口顶边,不垂直居中。

### 主行的状态机(mainLine 分支顺序即优先级)

1. 有逐字数据(`currentLine.words`)→ 逐字卡拉OK渐变;
2. 只有整行文本(`currentLine.mainText`)→ 整行按前景色高亮显示(即"整行高亮退化");
3. Spotify 广告插播 → 「广告中」;
4. 联网确认过是纯音乐 → 「纯音乐」;
5. 搜完了确实没有 → 「暂无歌词」;
6. collector 报断网且无内容 → 「网络连接失败」;
7. 正在播但还没解析出内容 → 「搜索歌词中…」;
8. 兜底 → 「♪」。

3~7 全部以半透明前景色显示;分支顺序是修过多轮的关键行为——有明确结论的状态必须排在含糊的「搜索中」前面,否则永远显示搜索中。

### 逐字卡拉OK填色

- 由 `TimelineView(.animation(minimumInterval: WordKaraokeGradient.refreshInterval, paused: !playback.isPlayingNow || playback.currentLineFillSettled))` 驱动,刷新上限 30Hz(三处逐字视图共用这个常量),每帧从 `PlaybackCoordinator.shared.anchor.extrapolatedPositionMs(now:) + currentLyricsOffsetMs` 现算播放位置——不经过 @Published 值 + SwiftUI 补间动画(那条路是历史上逐字卡顿的结构性根源)。paused 的第二个条件(2026-08-19):行填完之后到下一行开始之前(行尾/间奏/曲末)视觉零变化,把表停掉,不再每 tick 白构造整行 LinearGradient;`currentLineFillSettled` 由 20Hz fastTick 按 `KaraokeFill.lineFillSettledMs` 阈值维护,每行至多翻转两次。
- 每个字的进度 = `KaraokeFill.fillFraction`:`(currentMs - startMs) / max(durationMs, 80)`。80ms 是词时长下限,只影响该词自己的填色速度,不改起点。fraction **故意不夹到 [0,1]**,裁剪在 `KaraokeFill.stops` 里按过渡带与 [0,1] 是否有交集分情况处理。
- 颜色映射在 `WordKaraokeGradient.gradient`:已唱部分 = 前景色全强度,未唱部分 = 同色 35% 不透明度,边界有 ±0.08 的软化过渡带,整体作为 LinearGradient 直接当 Text 的 foregroundStyle。
- 时间基准必须加 `currentLyricsOffsetMs`(基准[全部 / 按播放器,二选一] + 单曲微调)——引擎判定"当前行/当前词"时已内含该偏移,填色不加就会出现"填一半卡住、跳下一个词从 0 开始"。
- 「当前是哪一行」由 LocalPlaybackSource 的 20Hz `fastTick` 决定(只在真的换行时才给 `currentLine` 赋值);填色平滑度与它无关。锁屏时 20Hz tick 停掉。
- ⚠️待核对:暂停瞬间 `anchor` 被置 nil,若 `paused` 参数生效前 TimelineView 还有一帧重算,`currentMs` 会按 0 计算、整行填色可能瞬间退回全未唱;代码上存在此窗口,未实测过暂停瞬间的视觉表现。

### 整行高亮退化

用逐字还是整行由引擎在加载时定(`LyricsSyncEngine.load`):有 YRC 且过滤署名行后覆盖率 ≥ 整行歌词的一半才用逐字,否则退回整行(防止退化 YRC 只剩一行导致整首歌卡在同一句)。整行模式下无填色动画,整句一次性以前景色显示,`fixedSize(horizontal: false, vertical: true)` 自然换行。

### 自动换行与跑马灯

- 逐字行用自定义 `WrapLayout`(SwiftUI Layout 协议):一行装不下下一个字就另起一行,行内按对唱声部对齐(默认居中);单个字比整行还宽时独占一行原样保留、绝不压缩成省略号。几何计算在 `WrapLayoutMath`(可被 selftest 覆盖),子视图尺寸有缓存,只在子视图集合变化时重测。
- **悬浮窗不使用跑马灯**:长行靠换行+窗口动态增高消化。`MarqueeText` 只用于灵动岛/歌词窗口/菜单栏,与本章无关。

### 对唱分声部

- 歌词源把演唱者标记写在正文前缀,有**两种**形态,缺一不可:①**行内前缀**「男：周末守着烤箱」;②**独占一行**「[00:24.83]周杰伦：」后面跟着歌词行(实测比①还多)。`LyricDuet` 剥掉前缀并按标记**首次出现顺序**定边:第一位靠左、第二位靠右、合唱居中;标记向后延续到下一个标记。
- 认得的标记不止「男/女/合」:**人名/艺名**(周杰伦/Jay/CT/巨炮/杭盖…)也算,但要过一道整份闸(≥2 个不同标签、合计 ≥3 处、至少一个重复出现),外加形状闸(不含代词/动词、不含乐器职能词根、不是角色词)。已知声部词直通、不用过闸。
- **独占一行的标记整行丢掉** —— 它不是歌词,不该占着自己的时间戳在屏幕上显示。
- 同一位歌手的不同写法(男/男声/男合)归并成同一个身份,保证始终同侧。
- 悬浮窗对 `side == nil`(整首无标记,绝大多数歌)兜底为**居中**(歌词窗口兜底靠左)——nil 与 .leading 是刻意区分的两个值。
- 声部影响四处:卡片内 VStack 对齐、多行文本对齐、WrapLayout 行内对齐,以及**两侧内缩**(`LyricDuetLayout`,见下)。
- **两侧内缩**:光靠对齐不够 —— 顶满整宽的行左对齐和右对齐渲染完全相同。左声部行右侧留白、右声部行左侧留白、合唱两侧都留,比例 15% 且以 4 个字宽封顶;`side == nil` 的行一律 0(普通歌排版逐像素不变)。这是 Apple Music / AMLL 的实际做法。
- 逐字数据里标记的切分形态**不固定**:可能跟第一个字粘成一个词(`男：周`)、可能独立成词(`男`+`：`)、人名还会被逐字拆开(`周`+`杰`+`伦`+`：`)。所以判定必须在**整行拼起来**的文本上做,剥离按**字符数**从词序列前端剥(剥到一半的词改文本、保留时间戳)。

### 日文逐词注音(罗马音标在词底下)

- 引擎对"看着是日文"的逐字行产出 `wordGroups`(`LyricsSyncEngine.buildWordGroups`):整行一次性分词、按 UTF-16 范围把逐字词并成"共享同一段读音"的组;酷狗 LRC 自带的 `[kana:]` 假名标注(`KanaAnnotation.parse`)优先于形态分析器给读音(解决「明日」asu/ashita 这类多音词),对不齐时整份弃用、退回形态分析。
- 视图侧(`usesPerWordRomanization`):用户开了罗马音且这一行确实有 wordGroups 时,每组渲染成一列——上面是组内各字(各自逐字填色),下面是该组罗马音(按**整组**起止填色,不逐字跳);此时整行罗马音那一行不再重复显示。
- 中文歌不会被标成拼音(`buildWordGroups` guard japanese);关掉日文罗马音开关后逐词注音也一并消失。

### 罗马音/译文/下一句预览三行

- 顺序固定:主行 → 罗马音(0.65x 字号、前景色 60%)→ 译文(0.7x、75%)→ 下一句预览(0.7x、40%)。罗马音 2026-08-17 起在主行**下面**(音译惯例,与歌词窗口一致)。
- 罗马音来源:服务端 `lyrics_roma` 优先;整首都没有时客户端 Romanizer 现算兜底(按行缓存)。`romanizationScripts`(日/韩/中分语言开关,中文默认关)在服务端字段之前把关。
- 译文来自歌词源的中文翻译(700ms 容差最近邻贴行),默认开关跟随"用户读不读中文"。
- 下一句预览:引擎 `upcomingLineText`;播放位置还没到第一句时直接提前露出第一句真歌词。

### 样式(字体/字号/颜色/描边/跟随封面)

- 字体族+主字号(14~36pt,默认 31)只在设置变化时重算成缓存 Font(`AppSettings.recomputeFonts`),渲染路径不解析 hex/不查字体。空字体族名 = 跟随系统。
- 前景色:`PlaybackCoordinator.displayForegroundColor`——「文字跟随封面」开着且已算出封面强调色时用动态色,否则用手选固定色。动态色从封面均值色派生:描边开着且描边色 alpha≥0.5 时按"与描边色够对比"算,否则按"够亮"提升;封面过小时用 collector 缓存里的高清替代图均值。**只接管文字颜色**,背景色/描边色始终生效。
- 背景色:alpha > 0.02 才画(圆角 16 固定值);默认全透明,此时垫一层 `Color.black.opacity(0.001)` 保证拖拽手势能命中。
- 文字描边:开关+颜色可调,粗细固定 1.2pt。实现是 blur+alphaThreshold 剪影垫底(`OptionalTextStroke`),整行套一次、开销不随描边粗细变化。逐字行的剪影 mask 用**静态副本**当 Canvas symbol(2026-08-19:`lyricsTextStroke(maskSource:)`,同排版纯色版 `karaokeLineContent(atMs: nil)`)——原来 symbol 是内容本身,填色渐变每 tick 一变整行就重跑 blur+threshold,而剪影只由文字/字体/换行决定,一行存续期内不变。历史上的 `.compositingGroup()` 已删除:它是给早已移除的每字阴影合并用的,当前树里只剩离屏渲染开销。⚠️ **剪影必须跟 content 吃同一道 `.padding(width*2)`**(2026-08-23 修):Canvas 是**居中**绘制剪影的,只有两者在 canvas 里占同一块矩形才逐点对齐。普通 Text 按自然宽度收缩、居中能补回来;但逐字行的 `WrapLayout` **撑满被提议的宽度** —— content 撑满 padding 内的宽度、剪影撑满 canvas 整宽,差正好一圈 padding。居中排版时两边各差一半抵消掉(所以非对唱歌看不出),一旦按 leading/trailing 靠边(对唱左右声部)就偏 2.4pt,而描边本身才 1.2pt,整圈甩到一侧。源码守卫在 collector 的 `strokemaskpadding_test.go`(纯 SwiftUI 布局行为,selftest 覆盖不了)。
- 配色主题:内置预设 + 用户自存主题(只打包文字/背景/描边四字段,不含字体字号);「恢复默认文字与配色」重置七个字段但不碰宽度和锁定。内置预设(`ColorTheme.builtInPresets`)现在是六款:经典白字/白字描边/经典黑字/黑字描边/深色卡片/浅色卡片——2026-08-26 去掉了"暖黄"/"赛博青"，换成"白字描边"/"黑字描边"(经典白字/黑字各自的加描边版本,前景/背景色不变,只是把描边开关打开,描边色沿用各自"手动打开描边时"本来就带的那个默认值,不是新配的颜色)。
- **全新安装/「恢复默认文字与配色」/「清除所有配置」之后的默认样子**(2026-08-26 改):`ColorTheme.defaultTheme` 从 `classicBlack`(不描边)换成 `classicBlackStroke`(黑字描边预设的同款字段:黑字+透明底+白色描边)+ `AppSettings.defaultFollowsCoverArt` 从 `false` 改成 `true`——用户把自己实际在用的这套(跟随封面取色 + 打开文字描边)定为新默认。两处默认值各自独立(`followsCoverArt` 不是 `ColorTheme` 的字段),但都在 `AppSettings.init()` 的 UserDefaults 缺省分支和「恢复默认文字与配色」按钮里同步生效,不会只改一处漏改另一处。`applyColorTheme(_:)`(从下拉菜单套用某个具体主题)不受影响,仍然无条件把 `followsCoverArt` 关掉——套用一个固定命名主题本来就是在明确表态"要固定色、不要动态色"，跟"默认初始化长什么样"是两件事。

### 窗口几何与位置记忆

- 宽度:设置滑块 420~1000pt(默认 640),`setWidth` 保持中心点不变左右对称伸缩,新边界夹回**窗口自己所在那块屏**的可见区域(`hostVisibleFrame`,不是 `NSScreen.main`;复用 `OverlayPlacement.clamped`,顺带修好"窗口比屏还宽时被推出右边界")。
- 高度:不是设置项。默认/最小 120pt,内容(换行、多行开关)需要更多时由视图上报实际高度、`updateHeight` **顶边固定向下增高**,上限夹到"顶边到**所在那块屏**可见区底边"(同 `hostVisibleFrame`,一块屏都不沾时干脆不夹);高度不持久化。窗口尺寸动画走 `animator()` 异步执行,连续调用以"上一次目标 frame"为基准防中间帧累积。
- 位置:持久化为 `"x,顶边y"` 字符串(UserDefaults `np:overlayPositionTop`)。存顶边而非左下角是修"每次重启往下漂"的关键;旧键 `np:overlayPositionOrigin` 只读一次做迁移。移动经 0.3s 防抖保存;长按拖动结束时在 `armDragIfStillPressed` 里直接存一次最终位置。
#### 多屏:窗口只待在你拖它去的那块屏(2026-08-21 修)

不变量:**位置只由用户拖动决定**。启动、插拔显示器、息屏唤醒、改分辨率、改排列,一律不许把窗口搬到另一块屏,也不许改写盘上那个锚点。

- 启动还原 `restoredPlacement()`:锚点还原出的 frame 只要在**任意一块**屏上够得着(≥60×30pt)就**原样保留**;一块屏都看不见才夹回主屏,并把这次落点标记成"借来的"(`isBorrowingScreen`)。
- 运行中显示器配置变化 → `reconcilePlacementWithScreens()`,两个方向:① 正在借屏显示、盘上锚点又看得见了(外接屏插回来/睡醒)→ 送回去、清标记;② 当前位置看不见了 → 借主屏显示。窗口好端端在某块屏上时**什么都不做**。
- **锁定位置开着时,位置由锚点唯一决定**:那时用户根本挪不动窗口(`setLocked` → `syncMouseMonitors` 把鼠标监听器整个卸掉、`handleMouseEvent` 开头直接 return),所以收到的 `didMove` 只可能来自我们自己或**系统**——显示器消失时 macOS 会自行把窗口搬到剩下那块屏。`scheduleSavePosition(_:)` 按来源区分(`PositionSaveSource.windowMoved` / `.programmaticResize`):锁定期间的 `.windowMoved` **不采纳为新锚点**;下一次屏幕参数变化时,**只有"窗口现在待的屏跟锚点那块屏不是同一块"**才按锚点搬回去(同屏内几个 pt 的偏差一律不管——抱怨的是跨屏搬家,为对齐锚点发一次无谓位移只会制造新的跳动)。`.programmaticResize`(换行变高守恒锚点、宽度滑杆是用户主动改的)照常写盘。
- 借屏期间 `scheduleSavePosition(_:)` 直接返回,**不写盘**——否则拔屏这一下就把用户拖出来的位置永久改写成主屏坐标,插回来也回不去。用户亲手拖过窗口 = 新的明确意图,`armDragIfStillPressed` 末尾清掉标记后照常写盘。
- 窗口自身的尺寸钳制(高度上限、宽度重定中心)全部依据 `OverlayPlacement.hostVisibleFrame`(与窗口相交面积最大的那块屏);**不再回落 `NSScreen.main`**——那是"有键盘焦点的屏",跟窗口在哪儿无关,而 `window.screen` 会在刚 `orderOut` 过等时刻拿不到值。
- 纯几何都在 `OverlayPlacement`(`restored` / `hostVisibleFrame` / `repositionIfOffscreen` / `isSufficientlyVisible`),selftest 覆盖——"拔掉/插回外接屏"那一瞬没法在单测外复现。

**根因(用户报"悬浮歌词经常在主屏幕和副屏幕之间切换位置",此前是本节的 ⚠️待核对项,已坐实)**:旧 `restoredOrigin` 把锚点无条件夹进 `NSScreen.main.visibleFrame`。实测这台机器:内置屏可见区 `(0,70,1470,853)`、外接屏 `(-526,956,2560,1440)`,盘上锚点 `np:overlayPositionTop = "849.0,1202.0"`(好端端在外接屏上)、窗口 900×120 → 被夹成 `x=min(max(849,0),1470-900)=570`、`y=min(max(1082,70),923-120)=803`,整个窗口被拽回内置屏。关键在于 `NSScreen.main` 是"**当前有键盘焦点的那块屏**"、不是内置屏:同一个锚点,启动那一刻焦点在内置屏就被夹到内置屏,焦点在外接屏则两行 clamp 全是 no-op、窗口留在外接屏——**不需要用户拖任何一下,窗口就会随每次启动在两块屏之间来回**(本机 `np:lockPosition = true`,用户其实根本拖不动它,所以观察到的每一次位移都只能是程序或系统造成的)。夹出来的落点还会被首帧歌词渲染触发的 `updateHeight` → `setFrameAnimated` 完成回调写回磁盘,把用户那个锚点冲掉。

> ⚠️ 别把旧 bundle id 域里的值当证据:`np:overlayPositionOrigin = "602.0,803.0"` 躺在**已废弃**的 `com.chenyuhao.lyrimuse`(和 `desktop-lyrics` 等)域里,当前二进制只读 `me.yudaotor.lyrimuse`,那个域里**没有**这个旧键;`803 = 923−120` 同时也是"顶边贴着内置屏菜单栏"的自然手动摆位,本身没有鉴别力。

### 锁定位置与点击穿透(合并开关)

- 「锁定位置」一个开关管两件事:锁定 = 彻底停用悬停控制排+长按拖动整套手势;解锁 ≠ 拦截点击——`ignoresMouseEvents` 常年为 true(点击真穿透到下层),只有鼠标悬停到播放控制按钮胶囊那一小块热区时才临时收回。
- **滚轮永远穿透**(2026-08-18):热区收回穿透是整窗、所有鼠标事件一刀切的,滚轮曾跟着被吞——悬浮窗叠在别的窗口上时,热区那一小块里下层窗口滚不动(用户报:设置窗「最近记录」列表)。现在 `LyricsOverlayWindow.scrollWheel` 收到滚轮立即把穿透设回 true 并丢弃该事件(第一格无感),同一手势后续滚动直接派给下层;指针再移动时 mouseMoved 照常重新收回穿透,胶囊按钮可点性不受影响。拖动武装(performDrag)期间不碰穿透,原样放行。
- ⚠️ **本节上面两条描述过时了**(代码 2026-08-18 就改了,文档没跟上,2026-08-22 修):`ignoresMouseEvents` 现在**恒为 true**,没有"悬停到热区临时收回穿透"这回事,胶囊上的点击改由 `.leftMouseDown` 分支按各按钮矩形自己分发(`OverlayControlHitTest.control(at:in:)`);配套的 `scrollWheel` 覆写和 `isDragArmedProvider`/`onScrollWheelSwallowed` 两条接线也一并删了 —— 窗口压根收不到滚轮,WindowServer 直接派给下层。原因见 `LyricsOverlayWindow` 类注释:`ignoresMouseEvents` 是整窗 × 所有事件的一个布尔量,点击要它 false、滚轮要它 true,按位置翻转必然让其中一方受害。唯一的例外仍是长按拖动武装期间(`armDragIfStillPressed` 为 `performDrag` 临时收回 false)。
- **歌词命中判定**(2026-08-23):「划过让开」原来复用 `isHoveringForControls`,那是 `window.frame.contains(鼠标)` —— **整个窗口矩形**。窗口比文字大得多(上下有卡片内边距和播放控制槽位、左右是 `WrapLayout` 撑满留下的空白),于是指针在歌词**附近**就触发淡出。改成独立的 `isHoveringLyrics`:窗口内 **且** 落在歌词文字矩形上才算。
  - 文字矩形由 `LyricsTextRectPreferenceKey` 收集主歌词/罗马音/译文/下一句预览各自的 frame 取并集,经 `updateLyricsHotZone` 换算成屏幕坐标(同 `updateControlsHotZone` 那套换算)。
  - 逐字行特殊:`WrapLayout` **撑满整宽**(对唱左右对齐要靠它),直接拿 frame 会把左右空白算进去。改由布局阶段把"文字实际矩形"写进 `WrapContentRectSink`(纯引用旁路,**不经过 SwiftUI 渲染循环** —— 给每个字挂 GeometryReader 会把几何依赖拖进 60fps 填色热路径,那个坑踩过),几何本体是 `WrapLayoutMath.contentBounds`(有 selftest)。
  - **播放控制按钮照旧走整窗判定**(`isHoveringForControls`):想点按钮时指针常先落在窗口边缘,那一侧收紧成"必须压在字上"反而不好点。
  - 热区还没上报上来时(刚显示、或这一轮没有任何文字)退回窗口判定,别让功能整个失灵。

- **「指针划过时让开」改了鼠标监听器的生命周期**(2026-08-22):`syncMouseMonitors()` 的判据从 `visible && !isPositionLocked` 改成 `visible && (!isPositionLocked || overlayFadeOnHover)`,`handleMouseEvent` 开头那条锁定 guard 也对 `.mouseMoved` 放行。理由是「锁定位置 + 划过让开」恰恰是最常见的组合(位置钉死了的用户才更需要它临时让开),而锁定原本会把监听器整个卸掉、让这个开关当场变成死的。控制排不会因此露出来——`controlsShown` 那行有 `&& !lockPosition` 守着。开关切换后必须调 `setFadeOnHover(_:)` 重新装卸一次,否则要等到下次显示/隐藏才生效。
- 因为窗口收不到原生事件,悬停/长按/拖动全靠 global+local 两个 NSEvent 监听器旁观鼠标自己算(`handleMouseEvent`);热区矩形由视图层 GeometryReader 经 PreferenceKey 上报,换算成 **窗口本地坐标**存着(`OverlayControlHitTest.windowLocalRect`,有 selftest),判定时把鼠标点 `convertPoint(fromScreen:)` 转进来比。
  - ⚠️ **不能存屏幕坐标**(2026-08-23 修的真 bug):窗口一移动,SwiftUI 布局没变、PreferenceKey 不重发,存下来的屏幕坐标就还停在旧位置 —— 播放控制按钮和两个热区当场失效(用户报的「移动之后按钮会失效」)。窗口本地坐标不随窗口移动改变,所以只存它。三处热区(按钮矩形/控制热区/歌词热区)共用同一条换算。监听器生命周期 =「窗口实际在屏 且 未锁定」(2026-08-19,`syncMouseMonitors`,挂在 setLocked/updateActualVisibility 的状态迁移上)——global monitor 会把全系统每次指针移动经 mach IPC 送进本进程,锁定/隐藏时这套手势用不上,不再装死到进程退出。
- 拖动:武装之后合成 mouseDown 交给 `NSWindow.performDrag` 原生拖动(自算 delta 那条路实测卡顿)。怎么武装由 **`overlayDragNeedsLongPress`(「拖动前先长按」,默认关)** 决定:
  - **关(默认)**:按在**歌词文字**上(`lyricsHotZoneLocal`)立刻武装;歌词四周的空白照旧穿透。代价是压在字上的那一次点击会被窗口接住、穿不到下层。热区还没上报上来时退回长按,别让"按下就拖"覆盖整窗。
  - **开(旧行为)**:按住窗口区域 0.35s(期间移动 ≤4pt)才武装,期间点哪儿都能穿透;移动超容差判为"想操作下层 App 的普通手势",取消长按。
  - 长按这道门原本是**必须**的 —— 窗口常年点击穿透,"按下就拖"会让整个窗口区域吃掉点击。2026-08-23 精准歌词热区落地后这个前提变了:有了更准的判据,不必再用时长去区分"想拖窗口"和"想点桌面"。
- 首次解锁时窗口上短暂弹一句提示 4 秒,一台机器只弹一次(`np:hasShownOverlayDragHint`);文案跟着「拖动前先长按」变(开=「长按即可拖动位置」/关=「按住歌词即可拖动位置」)。
- 悬停控制排:解锁+悬停在窗口范围内时,歌词卡片**上方**露出深色胶囊——上一首/播放暂停/下一首、「喜欢」心形(仅实际在播 Apple Music 且有自动化权限时出现;悬停露出时会回读一次真实状态)、竖线、锁定按钮(点击立即锁定并收起整排)。播放控制按钮点击时才校验自动化权限,被拒 `NSSound.beep()`。按钮槽位常驻(隐藏时透明)以保证悬停时歌词不跳动。

### 隐藏行为(三项,后两项与灵动岛共享)

| 行为 | 机制 | 与灵动岛的关系 |
|---|---|---|
| 手动显示/隐藏 | `setVisible` 写 `classicOverlayEnabled`,窗口 orderFront/orderOut | 各自独立开关 |
| 暂停/无播放时隐藏 | `hideWhenNotPlaying`;实际可见 = 手动开 AND (未开自动隐藏 OR 正在播)。跟的是 `isPlayingSmoothed`(停止侧带 0.5s 宽限,吸收换歌/seek 抖动;恢复播放立即响应),恢复播放自动重新显示,不改手动开关本身 | **共享同一设置项**,设置页"自动隐藏"卡一个 Toggle 同时下发给两个控制器(只发给当下开着的那个) |
| 截屏/录屏时隐藏 | `hideDuringScreenCapture` → `window.sharingType = .none`:截图/录屏/会议共享拍不到,用户自己仍看得见 | 同上,共享设置项 |
| 拖动前先长按(2026-08-23) | `overlayDragNeedsLongPress`,默认**关**;关=按住歌词直接拖(靠精准歌词热区,四周空白仍穿透)、开=旧的长按 0.35s。见上面「拖动」那条 | 只对悬浮歌词生效 |
| 指针划过时让开(2026-08-22) | `overlayFadeOnHover`;在 `LyricsOverlayView` 顶层挂 `.opacity`(淡到 15%,**不是** orderOut——那会跟上面三个真正的可见性来源抢同一个开关)。淡入 0.18s 比淡出 0.12s 慢:扫过去要立刻让开才有用,回来从容点更好。判据是 `isHoveringLyrics`(**指针压在歌词文字上**),不是 `isHoveringForControls`(整窗)——见下面「歌词命中判定」 | **只对悬浮歌词生效**;灵动岛贴刘海、hover 是它展开的手势,让开会跟展开打架 |

`setVisible(true)` 时会把三个已配置偏好(capture-hide / pause-hide / lockPosition)重新应用一遍,保证从菜单栏/快捷键打开时状态与持久化一致;App 启动时 AppDelegate 只在 `classicOverlayEnabled` 为真时才触碰控制器单例做同样的应用(避免凭空构造窗口)。

## 设置项

全部在「设置 → 外观」,除注明外均在「悬浮歌词」段:

| 设置项 | 改什么行为 |
|---|---|
| 桌面悬浮歌词(总开关) | 窗口显示/隐藏(`classicOverlayEnabled`);配置卡不跟开关联动,关着也能预先调 |
| 文字跟随封面 | 前景色改用封面动态强调色;**同时被灵动岛整套 UI 读走**(见交互节) |
| 配色主题 / 文字颜色 | 固定前景色(跟随封面开着时这两行收起);文字颜色禁透明 |
| 背景颜色 | 卡片背景(含 alpha,全透明=无背景) |
| 文字描边 + 描边颜色 | 开关与颜色;粗细固定 1.2pt 不可调 |
| 我的配色主题 | 存/套用/删除自定义四字段配色 |
| 字体 / 字号 | 主行字体族与字号;罗马音/译文/预览按 0.65x/0.7x 派生 |
| 宽度 | 窗口宽度 420~1000pt,实时生效 |
| 锁定位置 | 停用悬停控制排与长按拖动 |
| 指针划过时让开 | `overlayFadeOnHover`;指针压在**歌词文字**上时整窗淡到 15%,离开恢复。只对悬浮歌词生效 |
| 恢复默认文字与配色 | 重置跟随封面+字体字号+四个颜色字段,不含宽度/锁定 |
| 截屏/录屏时隐藏(「其它」段) | sharingType;与灵动岛共享 |
| 暂停/无播放时隐藏(「其它」段) | 自动隐藏;与灵动岛共享 |
| 显示罗马音 / 罗马音语言(「歌词」页) | 罗马音行与逐词注音的显隐、按语言过滤 |
| 显示译文(「歌词」页) | 译文行显隐 |
| 双行显示下一句(「歌词」页) | 预览行显隐 |
| 快捷键页:显示/隐藏悬浮歌词、锁定/解锁位置 | 全局快捷键,默认未录制 |

## 与其它功能的交互

- **数据源链**:显示内容全部来自 `PlaybackCoordinator`(单例),它转发 `LocalPlaybackSource`——2 秒轮询 media-control 拿播放快照,20Hz `fastTick` 用 `ProgressAnchor` 外推位置定"当前行";歌词正文来自 collector 的 enrich 缓存(`EnrichCacheReader.lookup`)。「搜索歌词中/暂无歌词/纯音乐/网络连接失败」四个占位状态分别对应 collector 侧的解析进度/`resolved`/`instrumental`/网络状态。悬浮窗视图**不整对象订阅**这两个单例——经 `OverlayPlayback` 窄代理只订阅它实读的二十来个字段(2026-08-19,LiveRowPlayback 同款模式),歌词窗口音量滑杆/灵动岛封面这类无关高频写入不再打醒它的 body;`anchor`/`currentLyricsOffsetMs` 由 TimelineView 闭包直读协调器,不入订阅。
- **歌词处理管线共享**:署名行过滤(`strippingCreditLines`)、简繁转换(`lyricsChineseVariant`)、逐字/整行选择(`preferWordLevelKaraoke` + 覆盖率判据)都在引擎/数据源层完成,悬浮窗、灵动岛、歌词窗口、菜单栏看到的是同一份结果。署名行过滤直接影响悬浮窗动态高度(漏判的长职员表行曾把窗口撑爆)。
- **与灵动岛**:开关互相独立可同开;共享 `hideWhenNotPlaying`、`hideDuringScreenCapture` 两个设置项和 `WordKaraokeGradient`(30Hz 上限+渐变算法);「文字跟随封面」开关也被灵动岛读走(NotchLyricsView.accentOrWhite),但两边用的强调色变体不同(悬浮窗按"与描边对比/够亮",灵动岛按"深底够亮")。
- **与歌词窗口**:共享 `showRomanization/showTranslation/showNextLinePreview` 三个开关、`WrapLayout`、`KaraokeFill`、LyricDuet;但字体/字号/三个颜色**只**对悬浮窗生效,歌词窗口用固定系统配色;对唱 nil 兜底两边不同(悬浮窗居中、窗口靠左)。
- **与歌词时间轴校正**:`LyricsOffsetStore` 的基准(全部 / 按播放器,二选一)+ 单曲微调合成 `currentLyricsOffsetMs`,同时作用于"当前行判定"(引擎内)和"逐字填色基准"(视图内显式相加)。
- **与设置页预览**:`OverlayPreviewBar` 是刻意维护的第二份渲染实现,复用 `settings.mainFont`/`backgroundColor`/`displayForegroundColor` 规则和 `lyricsTextStroke`(为此放开成 internal)。**逐字填色也复用**(2026-08-26 用户要求,原来这里不复制)——真在播放且当前行有逐字数据时,用同一套 `WordKaraokeGradient`/`KaraokeFill` 算法、同一个播放位置来源(`PlaybackCoordinator.anchor`/`pausedPositionMs`/`currentLyricsOffsetMs`)按真实进度逐字填色,`karaokeContent`/`wordText` 是 `LyricsOverlayView.mainLine`/`wordText` 的镜像写法;没在播放或这一行没有逐字数据时退回原来"整行最终颜色"的静态样子。仍不复制的是逐字行的自动换行(`WrapLayout`,预览高度固定、长行只裁切)和罗马音/译文行;圆角 16 是手抄的常量,改视图记得改预览。
- **与播放控制/权限**:控制排按钮和全局快捷键共用 MusicAutomationPermission「点了才校验、拒了 beep」的策略;「喜欢」只对 Apple Music 出现,乐观更新+回读纠正。
- **与「歌词管理」**:那边保存/删除歌词后调 `PlaybackCoordinator.refreshLyricsForCurrentTrack()` 强制重读磁盘,悬浮窗立即反映。

## 数据与文件

| 读写 | 内容 |
|---|---|
| UserDefaults(悬浮窗私有) | `np:overlayPositionTop`(位置,"x,顶边y");`np:overlayPositionOrigin`(旧键,只读迁移);`np:hasShownOverlayDragHint`(拖动提示只弹一次) |
| UserDefaults(经 AppSettings) | `np:classicOverlayEnabled`、`np:lockPosition`、`np:overlayWidth`、`np:fontFamilyName`、`np:fontSize`、`np:foregroundColorHex`、`np:backgroundColorHex`、`np:followsCoverArt`、`np:textStrokeEnabled`、`np:textStrokeColorHex`、`np:hideDuringScreenCapture`、`np:hideWhenNotPlaying`、`np:customColorThemesJSON` 等 |
| 磁盘(只读) | collector 的 enrich 缓存文件(歌词六字段+封面 URL,经 EnrichCacheReader);预览条启动时读一次桌面壁纸文件 |
| 进程边界 | 播放快照经 media-control(外部二进制);播放控制/喜欢/权限经 osascript 子进程;歌词解析由 collector 常驻进程后台完成,本 App 只读缓存 |

## 代码锚点

| 主题 | 文件 + 符号 |
|---|---|
| 内容视图/状态机/三行结构 | `lyrimuse/Sources/lyrimuse/UI/LyricsOverlayView.swift` · `LyricsOverlayView.body` / `mainLine` / `lyricsCard` |
| 逐字填色视图侧 | 同上 · `wordText` / `romaText` / `usesPerWordRomanization` |
| 描边实现 | 同上 · `OptionalTextStroke` / `lyricsTextStroke` |
| 自动换行 Layout 壳 | 同上 · `WrapLayout` |
| 控制排热区上报 | 同上 · `ControlsFramePreferenceKey` / `ContentHeightPreferenceKey` |
| 渐变绑定/30Hz 上限 | `lyrimuse/Sources/lyrimuse/UI/WordKaraokeGradient.swift` · `WordKaraokeGradient` |
| 填色纯算法 | `lyrimuse/Sources/LyrimuseCore/Lyrics/KaraokeFill.swift` · `KaraokeFill.fillFraction` / `stops` |
| 换行几何 | `lyrimuse/Sources/LyrimuseCore/Lyrics/WrapLayoutMath.swift` · `rows` / `placements` |
| 对唱分声部 | `lyrimuse/Sources/LyrimuseCore/Lyrics/LyricDuet.swift` · `plan` / `sides` / `splitMarkerAllowingEmpty` |
| 假名标注 | `lyrimuse/Sources/LyrimuseCore/Lyrics/KanaAnnotation.swift` · `KanaAnnotation.parse` |
| 行构造/逐词分组/署名过滤 | `lyrimuse/Sources/LyrimuseCore/Lyrics/LyricsSyncEngine.swift` · `activeLine` / `buildWordGroups` / `strippingCreditLines` |
| 窗口本体 | `lyrimuse/Sources/lyrimuse/UI/LyricsOverlayWindow.swift` · `LyricsOverlayWindow` |
| 窗口控制器(显隐/几何/手势/持久化) | `lyrimuse/Sources/lyrimuse/UI/LyricsOverlayWindowController.swift` · `setVisible` / `setLocked` / `updateHeight` / `setWidth` / `handleMouseEvent` / `armDragIfStillPressed` / `restoredPlacement` / `savedAnchor` / `reconcilePlacementWithScreens` / `scheduleSavePosition` |
| 隐藏行为 | 同上 · `setHideWhenNotPlaying` / `setHiddenFromCapture` / `updateActualVisibility` |
| 屏幕落位纯几何 | `lyrimuse/Sources/LyrimuseCore/Local/OverlayPlacement.swift` · `restored` / `hostVisibleFrame` / `repositionIfOffscreen` / `isSufficientlyVisible` / `clamped` |
| 状态/前景色来源 | `lyrimuse/Sources/lyrimuse/PlaybackCoordinator.swift` · `displayForegroundColor` / `isPlayingSmoothed` / `artworkAccentColor` |
| 进度外推 | `lyrimuse/Sources/LyrimuseCore/Playback/ProgressClock.swift` · `ProgressAnchor.extrapolatedPositionMs` |
| 20Hz 行定位 | `lyrimuse/Sources/LyrimuseCore/Local/LocalPlaybackSource.swift` · `fastTick` / `resolveLinesForPausedPosition` |
| 设置存储 | `lyrimuse/Sources/lyrimuse/Settings/AppSettings.swift` · `AppSettings`(`recomputeFonts` 等) |
| 设置页 | `lyrimuse/Sources/lyrimuse/SettingsView.swift` · `AppearanceSettingsTab`(`classicOverlayCard` / `autoHideCard`) |
| 实时预览 | `lyrimuse/Sources/lyrimuse/UI/OverlayPreviewBar.swift` · `OverlayPreviewBar` |
| 菜单栏入口 | `lyrimuse/Sources/lyrimuse/MenuBar/MenuBarStatusMenu.swift` · `rebuild`(快速开关) |
| 全局快捷键 | `lyrimuse/Sources/lyrimuse/Settings/GlobalHotkeys.swift` · `registerAll` |

## 设计决策与已知坑

1. **逐字填色不走 @Published+SwiftUI 补间**:SwiftUI 对 .linear 曲线在重定目标时做矢量相加而非接续,高频更新必卡;改为 TimelineView 每帧从锚点现算真值(SyncedLyricWord 注释、mainLine 注释)。
2. **30Hz 刷新上限曾漏掉悬浮窗**:2026-08-14 只给歌词窗口加了上限,常驻显示的悬浮窗和灵动岛按 120Hz 全速跑到 08-15 才补齐(WordKaraokeGradient.refreshInterval 注释)。
3. **TimelineView 故意包整行、不下沉到每个字**:下沉后每个字是各自独立的 30Hz 时钟、tick 时刻互不对齐,描边(整行一份 mask)反而可能被 N 个错开的时刻各触发一次;整行一个表的闭包成本有 30Hz 上限,收益配不上结构翻动(mainLine 注释)。2026-08-19 起描边剪影已换静态 mask 源、compositingGroup 已删,"描边逼整行重渲染"不再是理由,但上面这条独立成立。
4. **fillFraction 故意不夹 [0,1]**:夹住会让所有未唱到的词在开头误算出一截高亮,裁剪必须在 stops 里分情况做(KaraokeFill 注释)。
5. **位置改存顶边**:旧版存左下角 origin,配合"顶边固定向下增高"导致每次重启窗口累积下漂;顶边才是稳定锚(LyricsOverlayWindowController 文件头注释)。
6. **`overlayController` 必须显式传参**:View 在控制器自己的 init 里构造,此时读 `.shared` 会同线程递归触发同一个 dispatch_once,SIGTRAP 崩溃(LyricsOverlayView 属性注释,实测坐实)。
7. **ControlsFramePreferenceKey 的 reduce 只保留非零值**:树里其它分支贡献的 defaultValue(.zero) 会把真实矩形冲掉,"报 .zero 兼表不可见"的写法实测就是这么坏的;可见性判断挪到控制器侧(2026-08-07)。
8. **内容必须贴窗口顶边**:窗口高度有 120pt 地板,内容居中时高度一变整块内容上下移半个差值(实测 13pt 跳动);贴顶还让热区坐标换算的前提恒成立(body 尾部注释)。
9. **isPlayingSmoothed 订阅必须用 sink 参数值**:@Published 的 willSet 在落库前发布,闭包里另读存储属性拿到旧值,暂停/恢复要多等一个轮询周期(init 订阅注释;此坑在本项目实测坐实过)。
10. **WrapLayout 必须缓存子视图尺寸**:逐帧填色驱动下每次 sizeThatFits 重测整行文字,曾把主线程 90%+ 耗在布局上;缓存只在子视图集合变化时重建(WrapLayout.Cache 注释)。
