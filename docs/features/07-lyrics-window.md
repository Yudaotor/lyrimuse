# 07. 歌词窗口
> 最后核对:2026-08-17 · 基线:2a2bf8b+工作树

## 定位

一扇正经的标题栏窗口(SwiftUI `Window(id: "lyrics-window")`),按 Apple Music 歌词页的样式展示当前曲目的**整份歌词**:完整歌词列表 + 当前行高亮 + 自动滚动,左侧配封面卡、进度条和播放控制。它与「桌面悬浮歌词」「灵动岛歌词」那种"只看当前一句"的无边框浮层是完全不同的形态,**不复用**它们的外观主题设置(前景色/描边/字体/字号等),默认吃系统原生颜色、有封面时切白色系。

## 入口与展示面

- **菜单栏菜单**:状态栏图标菜单里的「歌词窗口…」项(自建 NSStatusItem 菜单,`MenuBarStatusMenu`),单独成组排在「设置…」「歌词管理…」之后。
- **全局快捷键**:设置页快捷键分区「打开歌词窗口」(`openLyricsWindowHotkey`)。默认**不预置**按键,必须用户自己录制才生效。
- 两条路径都汇到 `AppActions.shared.openLyricsWindow`,由一扇隐藏锚点窗口(`MenuBarSceneActions`)捕获的 `openWindow(id:)` 环境 action 执行,调用前先 `NSApp.activate(ignoringOtherApps: true)`(accessory 策略下不激活的话 openWindow 静默没反应)。
- 打开期间若「在 Dock 中显示」是关的,会**临时借一个 Dock 图标**(`AuxiliaryWindowActivation` 计数器,与设置/歌词管理/引导窗口共用),全部辅助窗口关完才还原成无 Dock 图标。
- 窗口尺寸约束 `minWidth 520 / idealWidth 1020 / minHeight 480 / idealHeight 660`。
- **位置/尺寸/所在屏幕自己持久化**(2026-08-22,此前完全靠 SwiftUI `Window(id:)` 的系统状态恢复):`LyricsWindowController` 在 `attach` 时先 `restorePersistedFrame` 恢复一次,再挂 `didMove`/`didResize` 观察者(两者要存的东西一样,拖边角会同时来,合用一个回调),400ms 去抖后写 `np:lyricsWindowFrame` + `np:lyricsWindowScreenID`。
  - **系统那套的问题不在"存不存",在它不认识屏幕**:多显示器下拔插一次或换个分辨率,窗口经常回到主屏、或落在一块已经不存在的屏幕的坐标上(表现是"打开了但看不见")。悬浮歌词早就为同一类问题写了 `OverlayPlacement`(04 章),这里是把同样的不变量补给歌词窗口。
  - **恢复时先认屏幕**:存过的那块屏(按 `ScreenIdentity` 的显示器 UUID)还接着才按存的 frame 放,不在了就整个放弃、交回系统默认——绝不拿旧坐标往现有屏幕上硬摆。放之前还要夹进那块屏的 `visibleFrame`(接同一块屏但改了缩放时,不夹会有一截挂在屏幕外)。
  - **伪全屏/原生全屏期间一律不存**:那时的 frame 是撑满屏幕的临时值,存下去等于把"全屏尺寸"当成用户想要的窗口大小,退出全屏再开就是一扇满屏的窗。
  - 两个键都是**机器本地状态**,在 `ConfigPortability.machineLocalDefaultsKeys` 里——判据跟 `np:overlayPosition*` 一字不差(绝对屏幕坐标 + 一块具体显示器的 UUID,新机器全不一样)。
  - 「置顶」仍然**不**持久化(每次重新打开都从"不置顶"开始),那是另一件事,见下面「窗口动作胶囊」。
- Dock 图标点击(reopen)**只**打开这扇歌词窗口,任何情况下都不弹设置(2026-08-21 按用户要求从「设置窗口」改过来:Dock 图标是「我想看这个 App」的入口,而这个 App 让人想看的是歌词;设置另有 ⌘, / 菜单栏菜单 / 主菜单三个入口)。实现在 `AppDelegate.applicationShouldHandleReopen`,两处刻意的写法都是为了「不要冒出设置窗」:
  - **不退回 `openSettings`**:`AppActions.openLyricsWindow` 是环境 action、由隐藏锚点视图捕获(见 `MenuBarSceneActions`),在「刚重启、锚点还没挂上」那一瞬是 nil。上一版那时候退回设置窗,于是「点 Dock 弹设置」照样发生。宁可这一下什么都不做(下一下就正常)。
  - **返回 `false`**:返回 true = 让 AppKit 执行默认的「恢复/带回本 App 窗口」行为,而 SwiftUI 的 Settings 场景关掉之后 NSWindow 对象仍然活着(只是 orderOut,`check-windows` 能看到它 `onscreen=false` 挂着),默认行为会把它一起端出来。返回 false = 「这次 reopen 我自己处理完了」。
  - 不分 `hasVisibleWindows`:`openWindow(id:)` 对已经开着的窗口就是带到前台,正好是「点 Dock 我想看歌词」的语义。

## 行为规格

### 布局:双列/单列

- 窗口宽 ≥ 640pt 时是双列(2026-08-21 按用户红框标注对 AM 截图逐项量比、一比一对齐):封面左缘 0.111W、封面宽 min(0.279W, 460pt)(面板列宽=封面宽,内边距为零),歌词文字左缘 0.515W、右缘留 0.06W——AM 是「左右两半、各自大留白」的重心;此前面板贴左缘(3%W)、歌词 0.34W 就开始,整体偏左。时间行右侧同步改为**总时长**(AM 是「0:20 ··· 3:12」,不是剩余时间)。宽 < 640pt 退化成只有歌词的单列(歌词左缘退回固定 44pt)——与 Apple Music 把窗口拖窄时的行为一致。老用户从旧版竖长窗口存档尺寸(~460pt)升级上来,第一次打开就是单列。
- 第二轮逐像素对拍(2026-08-22,用户给同尺寸 1470×858 的 AM 参考图逐区域量差):①左列**垂直居中基准=整窗**——hiddenTitleBar 下内容区仍有 ~28pt 顶部 safe inset,在内容区内居中会整列压低半个 inset(渲染 offset −safeTop/2−2 校正);②三段间距 封面→歌名 19 / 歌名块→进度条 19 / 进度条块→播控 17;③播控字号档位 上/下一首 0.060、播放 0.079(帧宽 0.10)、随机/循环 0.043,随机/循环的**占位定宽=字号+8**(字形在框内居中,这个框才是它们横向落点的旋钮);④主三键间距 0.116;⑤右上只留音量胶囊(贴右缘 5pt、垂直 padding 7 → 总高 36、中心 26pt 与红绿灯同心,红绿灯下移 10、close 中心 x 26);⑥置顶/全屏胶囊挪到**左上**(AM 同位是 X/画中画那颗:左缘 102pt、内衬 12/图标框 18/间距 14 → 总宽 ~72.5pt);⑦音量滑杆 114pt、滑块 23×14、已填充段白 0.80、AirPlay 字号 17。验证方法:reopen 事件(applicationShouldHandleReopen 直通开窗)+ screencapture -l 窗口截图 + 自适应阈值(逐行取列间局部背景)量 bbox,与 AM 参考图同尺寸逐像素比对,终态各锚点差 1~5px@2x。
- 两个玻璃胶囊(右上=音量、左上=置顶/全屏,2026-08-22 对拍后分居两角,AM 同布局)都是 `.overlay` 浮层而**不是** `.toolbar` 项——工具栏本身是玻璃,玻璃采样不到玻璃,放进去会退化成不透明灰块(Liquid Glass 规则,macOS 26 的 `.clear` 材质,见 `SettingsDesignSystem.clearGlassCapsule`)。

### 歌词列表:自动滚动与当前行

- 数据源是 `PlaybackCoordinator.allLines`(`[LyricsWindowLine]`),整首歌全部行一次性构造,同一首歌播放期间不重算;每行 id = 曲目标识前缀 + 行下标,换歌后 id 集合整体不同,ForEach 做干净的整体替换而不是逐行"变形"(避免换歌瞬间串行/闪烁)。
- 当前行(染色/加粗/虚化)由 `PlaybackCoordinator.currentLineIndex` 决定;**滚动**由 `scrollLineIndex` 决定(2026-08-22 用户对拍 AM:滚动**先于**染色——一句唱完、下一句还没开始的空档里页面已经滚到下一句的位置,开唱那一刻只染色不再滚动)。`scrollLineIndex` 在 `LyricsSyncEngine.scrollLeadIndex` 里算,三种空档提前指向下一行:①短间隙——逐字歌词知道这一行唱到几点(最后一个词的结束),唱完即滚;行级 LRC 不知道唱多久,不抢跑(两个下标恒等,行为同旧版);②长间奏(「•••」)——点亮期间滚动停在点上,窗口结束(下一句前 leadMs)才滚向下一句;③前奏(-1 号点)同②,倒计时结束先把第一句从开场位(0.52)挪到常规锚位。selftest 11 条断言钉死。每次滚动锚变化,`ScrollViewReader.scrollTo` 把目标行滚到窗口**从上往下 41% 处**(`activeLineAnchor`,不是正中——上面留已唱过的行,下面留更多将唱的行)。
- 滚动与行样式变化用**同一条**动画曲线 `lineTransition = .smooth(duration: 0.45)`(无回弹弹簧),两套动画节奏一致,不会"一顿一顿"。
- **没有"手动滚动暂停跟随"机制**:自动跟随永远生效,用户往回翻歌词后,下一次换行会被拉回当前行;想主动回去点右上角胶囊里的「回到当前播放」(location.fill 图标)。这个取舍是刻意的(照抄歌词管理窗口 `focusCurrentlyPlaying` 已验证过的简单方案,不做 `scrollPosition(id:)` 侦测)。
- 换歌/歌词重载(`onChange(of: poller.allLines)`)后无动画直接跳到新歌当前行;还没唱到第一句且有前奏点时**滚第一句、锚 0.52**——效果=「•••」落在 41% 锚位、第一句在窗高 ~52%(AM 实测 51.8%),开场从窗口中部开始而不是停顶(2026-08-21)。⚠️ 这个需求连修三版才对:①不能直接 scrollTo「•••」那行——gapDotsRow 不活跃时整行不渲染(id 未注册,scrollTo 静默无效),激活的同一事务里滚也解析不到;也不能加零高占位行(VStack 会为它多算一段行距);②**真根因是列表的顶/底留白**——固定 88pt 时第一句物理上到不了窗口中部,scrollTo 超出内容可滚范围被钳回 offset 0,修 id/时序全是白修。现在顶 0.395h/底 0.55h 按视口比例留白:offset 0 本身=AM 开场版式(不依赖 scrollTo),最后一句也能锚到 41%(此前每首歌头几句/尾几句的锚定其实都被钳)。intro 激活的 onChange(currentGapIndex==-1) 走 scrollToActiveLine 并 async 延一拍。窗口刚打开(onAppear)同样无动画定位一次。
- 列表用 `VStack` 而非 `LazyVStack`:歌词只有几十行,lazy 反而让带动画的 scrollTo 卡(目标行没渲染过就没尺寸)。
- 列表上下边缘有渐隐 mask(顶部 0~7.5% 全透明、20% 处全显,底部 90%→100% 渐隐):顶部渐隐让歌词滚到胶囊底下之前就淡掉,不糊在胶囊上;底部渐隐避免被窗口边缘直切一刀。

### 行的景深样式(Apple Music 式)

- 所有行同字号同字重,远近**不靠字号**区分:当前行不透明度 1、零模糊;其余行不透明度 `max(0.22, 0.42 - 0.10×max(0, 行距-2))`(d1/d2≈0.42 几乎不衰减,d3 起快掉)、高斯模糊 `0.0148×(行距+1)×字号`(d1≈3%字号、d4≈7.4%,行距本身封顶 4 无需另设上限)。这组数字是 2026-08-21 第五版,**从 AM 截图拟合**而非目测:同文行(「无敌铁金刚」出现在多个距离上)的墨量总和是高斯模糊的不变量,比值即不透明度;特写图拿 d0 行加 σ 扫描逐像素拟合各距离行,解出 σ=1.5×(d+1)px(字号 101px)。历史:固定 1.6pt"远行失真"→1.1pt"不够糊"→目测 9%/22%"太糊"→6%/15%"还是有点糊"——前四版都在猜,拟合版 d1 比 6% 版轻一半。
- 行距按下标算并**夹到 4**(`maxVisualDistance`):d≥4 的行画出来一模一样,输入不变就整行跳过重算(`LyricsLineRow` 是手写 `Equatable` 的——行视图带 onTap/onHover 闭包参数,SwiftUI 自带结构比较对闭包失效,必须只比值输入)。
- 行距的锚是**滚动锚 `scrollLineIndex`**而不是染色下标(2026-08-22 用户对拍 AM 第二轮):滚动落位那一刻下一句就该已经清晰——原来钉在 currentLineIndex 上,页面先滚过去、下一句却还挂着 d=1 的暗度和模糊,开唱才"对焦",比 AM 慢一拍。行的活跃态(isActive/逐字填色路径)同样跟滚动锚(activeID)走:空档里下一句"清晰但未染色"(词全在 0 填色),染色本身由词时间轴决定不会提前。
- 还没唱到第一句(滚动锚为 nil)时整页统一不透明度 0.45、轻模糊 3%字号;有前奏点的歌在「•••」倒计时结束那 0.8s 里第一句先清晰、再开唱。
- 系统「减少动态效果」(reduceMotion)开启时模糊整个关掉(与缩放同一批"聚焦感"装饰,统一走系统开关,不单加设置项)。
- 字号双锚缩放(2026-08-21 从 AM 整窗截图 1470×845pt 量出:当前行墨高 89px ÷ PingFang 粗体墨高比 0.88 = 字号 50.6pt):`max(22, min(栏高 × 0.0598, 栏宽 × 0.0564))`pt bold——两锚在 AM 自身纵横比下相等,偏矮窗口由高度锚接管(锁住"一屏约 7 行":行距 218px 占窗高 12.9%),偏窄由宽度锚接管防长句疯狂折行;上界不再夹死(旧 56,AM 全屏能到 68pt+)。罗马音 0.54 倍、译文 0.61 倍。行间距 0.98 倍字号(AM 行距 2.156em − 单行 Text 视图高 1.175em,ImageRenderer 离线标定;旧 1.14em 比 AM 松 8%)。当前行滚动锚点在窗高 41% 处(AM 量出 40.9%,旧 35%)。
- **对唱歌词**:行带演唱者标记(`LyricDuet.Side`)时按左/右/中分栏对齐,并叠加**两侧内缩**(`LyricDuetLayout`,15%、4 字宽封顶) —— 这一列按比例算只放得下约 12 个汉字,顶满整宽的行光靠对齐是分不出左右的。没有标记的歌 side 为 nil,本窗口兜底 `.leading`(悬浮窗兜底是 `.center`,两边不同),且 nil 行**不吃内缩**,普通歌排版逐像素不变。

### 行交互:悬停与点击跳转

- 鼠标悬到某行:该行立即恢复满不透明度、去模糊(0.16s easeOut)——看清要跳去的是哪句再决定点不点。
- 点击某行:`poller.seek(toMs: max(0, 行时间 - currentLyricsOffsetMs))`——**减回歌词偏移**,因为引擎判定当前行时会把 offsetMs 加到播放位置上,不减的话跳过去落在隔壁行。
- 命中区盖满整行(含左右空白),不是只有文字可点。
- 暂停状态下点击也生效(seek 走 pausedPositionMs 冻结位置那条路)。

### 逐字高亮(卡拉OK)

- 有逐字数据(`line.words` 非空)的行**不论活跃与否**都走 `KaraokeLineText`(结构统一,见已知坑 #11);无逐字数据的行渲染纯文本。
- **驱动方式定稿 = 逐帧重算 TimelineView @ 60Hz**(2026-08-21 五轮拉锯后,勿再翻烧饼):填色几何与**悬浮歌词逐像素同款**(渐变中心=人声位置、软边=±8%词宽同一个 `KaraokeFill.wordEdgeSoftenBand`,用户点名的观感基准),唯一差别是刷新档位 `WordKaraokeGradient.windowRefreshInterval = 1/60`(悬浮窗 30Hz;这台面板 60Hz,窗口字号大,30Hz 步进可感知)。同日第三轮曾整体改成**排程式**(fillFraction 对时间线性→一次性排 .linear 显式动画交渲染管线插值,LyricsX/AMLL 同架构)——CPU 是零逐帧代码,但 **SCK 逐帧探针实测 macOS 只以 ~20Hz 提交这些动画**(系统对长时程慢动画自动降档、无 API 干预;对照组悬浮窗 TimelineView 30Hz 准点),20Hz×14px 步进正是"卡顿感"本体,故回退。逐帧的开销结构由既有三件套压住:字级叶子时钟+4Hz 粗时钟只养活"正在扫的字"+WrapLayout contentKey 缓存+Palette 纯色跨帧复用。
- 视觉参数弯路记录(二/三轮按 AMLL 逆向参数"改良"、全被用户否掉):②羽化放大到 0.55×字号→光晕横跨大半个字,**字内的人声位置信号被洗掉**("全都是一个速度");③尖端对齐→相邻字光晕不跨界搭接,每字边界"熄灭再重生"("更机械了")。结论:**软边必须骑在人声位置上**,字内位置信号(边缘贴人声爬行)才是"流动感",不是宽光晕。
- 排程式那轮留下的三个真修复保留:①行激活瞬间 forceFilled→按时间 的取值跳变会被行级 `.animation(value: distance)` 插值成"全亮再褪色"(=「下一行先亮一下再从头逐字」bug)→ 字级叶子挂 `.transaction { $0.animation = nil }` 禁掉一切外来动画事务;②定格全填色的 fraction 必须取 **1+band**(取 1.0 走不到纯色快路径,右缘 band 段被淡到半强度);③上浮参数:幅度 0.05em(从 0.07 调低,用户定稿)、时长 **min(词长, 1000ms)**(七轮定稿,两头都有用户实测背书——上界防长词亚像素颤抖:长词按词长爬完整词=每帧 ~0.05 物理像素,字形抗锯齿持续重采样,"长音字上下抖动";下界跟词长对齐:"染色结束=上浮结束",短词随染色利落收尾;isLive 的存活窗口要把它算进去。AMLL 的 max(1000,词长) 没颤抖问题是 DOM 合成器插值,不是逐帧重排字形)。
- **行级动画屏障**(七轮,60fps 胶片实锤):①的 `.transaction` 拦截对"值作用域 .animation 祖先"实测**失效**(新行前几个字仍先全亮、亮暗边界 ~100ms 从右往左回撤),真正有效的是在行内容与 opacity/blur 之间插 `.animation(nil, value: distance)`/`.animation(nil, value: isHovered)` 屏障——内层 .animation(value:) 覆盖外层是文档化行为,景深动画只够到屏障之上的 opacity/blur。叶子 .transaction 保留作命令式 withAnimation 事务的兜底。
- 正在唱的字**上浮**:sin(p·π/2) 平滑到顶、抬起后保持、行退场落回(「点头式」被否掉过);幅度对齐到整设备像素(1x 外接屏防重采样发糊)。
- **定格即钉死**(2026-08-22 九轮):fillSettled 停表后 staticDate 冻结在最后一次粗 tick(最多陈旧 250ms),若恰好早于末字完成时刻,末字渐变被算回"没填完"——用户实测"行尾最后一两个字染完又退去染色","有时候"=停表与粗 tick 的相位差。修法=`lineSettled` 直传词级视图,定格时直接渲染终态(填满+浮定满幅),不再依赖任何时间基准——定格语义本来就保证所有词已填满、所有 rise 已完成(rise 窗口 min(词长,1000) 必然早于 1.08×词长的定格点)。顺带取代了旧注释"行尾短词上浮冻在九成处,接受"——现在钉在满幅。教训:**停表类优化的显示值必须改为常量,不能继续依赖被冻结的时间基准**。
- 罗马音逐词标注:开着「显示罗马音」且该行有 `wordGroups` 时,读音**逐词**标在正文每组字底下(组内左对齐、读音按整组起止时间的伪词填色、不跟着抬升),这时不再单独渲染整行罗马音;拿不到词组时退回正文下方一整行罗马音。
- 时间基准统一为 `anchor.extrapolatedPositionMs(now:) + currentLyricsOffsetMs`,暂停带 `?? pausedPositionMs` 兜底(2026-08-19 的暂停 bug:`?? 0` 会把当前行画回"未唱"态)。

### 译文/罗马音行

- 罗马音行:「显示罗马音」开 + 该行有 `romanization` + 没走逐词标注时,显示在主行**下方**(与 Apple Music 一致)。
- 译文行:「显示译文」开 + 该行有 `translation` 时显示在最下,次级颜色。
- 两个开关的帮助文案明说"只影响「桌面悬浮歌词」和「歌词窗口」"。

### 左列:封面卡与曲目信息

- 封面卡 1:1 方形、圆角 12、投影;图片优先用**高清替代** `highResArtworkImage`(只在系统 Now Playing 那份实在太小时才有值——网易云客户端只给 100×100,替代图来自 collector 缓存里解析歌词时顺手记下的 cover_url),否则用系统那份 `artworkImage`;都没有时显示灰底音符占位。换图交叉淡入 0.5s,动画收在 overlay 内容上而不是整卡最外层(否则会把别的布局变化 animate 成"进度条从上面飘下来")。
- 封面随播放状态缩放(仿 AM):播放满幅、暂停缩到 **73.2%**(2026-08-22 第二轮对拍用户给的 AM 整窗参考图:暂停态封面 599px@2x ÷ 满幅 0.279W=818px;此前 78% 让暂停态封面大 6%。渲染变换,不影响下方各行的布局位置),spring(0.5/0.72)。驱动信号是观感层 `isPlayingSmoothed`(缓收版,吸掉切歌间隙/seek 的真值抖动);从我们自己的 UI 点播放/暂停时它被 `userTogglePlayPause()` **乐观翻转**、点击即动(2026-08-21,见「播放控制排」),从播放器 App 里操作时仍走通知快路径(~0.5s)。
- 曲目两行:歌名(semibold)、「歌手 — 专辑」(专辑缺失只显示歌手),放不下**不截断**而是走 `MarqueeText` 跑马灯(停在开头→匀速滚到底→停住→瞬时回开头)。`MarqueeText.edgeFadeWidth`(2026-08-22 加的右端渐隐带)在这里保持默认 0 = 关:那一条是给灵动岛歌词行"硬切口紧贴封面"的观感准备的,这边曲目两行右边没有紧挨的元素,硬切不会被误读成被挡住。
- **左栏次级元素做 AM 式 vibrancy 染色**(2026-08-21,`amVibrantColor`):副行、时间行/无损标签、进度条已播段不是半透明白,而是**背景色相的亮化低饱和版**——太阳之子截图逐通道反解坐实(纯白 alpha 三通道等效透明度应相等,实测副行 r0.74/g0.58/b0.49 暖倾斜)。h/s 来自烘焙背景 base 的 CIAreaAverage(存在 WindowBackgroundLayers.tintHue/tintSaturation),档位:副行 s×0.5/v0.85、时间行 s×0.62/v0.68、进度已播 s×0.5/v0.92;歌名/主控制键保持近纯白(AM 同)。背景层未到时回退半透明白;无封面背景回退系统色。⚠️ 亮封面自适应(2026-08-22 两轮:先是"时间行看不清"、后是"字颜色没统一"):固定 v 档是从**暗封面**反解的,背景亮到 bgV≈0.7 时 v0.68 的标签撞上背景亮度直接隐形 —— 烘焙时把均色 v(×0.85 对齐 0.15 黑遮罩)存进 `tintBrightness`,文字类调用(副行/时间行)传 `minContrastToBackground: 0.25`,对比不足时**提亮**到 min(0.97, bgV+0.25)。方向以同帧对拍 AM 为准:亮橙背景上它的歌手行 S0.27 V1.00、时间行 S0.39 V0.94、播控近白 —— **次级元素清一色淡奶油、全部比背景亮**,对比度靠 文字淡 vs 背景艳 的饱和度差(前提=背景饱和,背景灰化 bug 修掉后成立)。第一版压暗成 V0.42 深棕被用户抓出"没统一"。唯一压暗分支:背景又亮又淡(bgV>0.75 且 tintSat<0.5,近白封面)提不出奶油对比,退 bgV−0.32 深色(AM 白封面同款)。进度条已播段是控件,不传。
- 控制排/按钮尺寸全部按封面实际边长比例算并夹进区间(`ctrl(ratio, lo, hi)`)——封面随窗口缩放,按钮写死尺寸会在窄窗口溢出被裁、宽窗口下不成比例。

### 「⋯」菜单与曲目动作(2026-08-22,对照 AM 同位菜单逐项评估后落地)

- 菜单结构(自绘玻璃面板,机制见已知坑 #12;2026-08-22 二批定稿):Apple Music 播放时 = 添加到资料库 / 减少推荐 / ─ / 前往专辑 / 前往艺人 / 在 Music 中显示 / ─ / 显示简介 / 搜索歌词…(有曲目才显示) / 歌词时间轴(内联控件行);其它播放器只有后半段,「在 %@ 中显示」标题随 `resolvedPlayerDisplayName` 变。「歌词管理…」「拷贝歌词」按用户要求移除(管理入口保留在菜单栏菜单)。
- **AppleScript 动作**(`MusicPlaybackController`,全部 2026-08-22 实机验证):添加到资料库=`duplicate current track to source 1`(流媒体曲目唯一可行路;不返回引用;fallback `library playlist 1`——不能用名字 "Library",中文系统叫「资料库」;共享播放列表源的 `shared track` 走 source 1 报 -10006、靠 fallback 接住);减少推荐=`disliked` 布尔(UI 的 Suggest Less 就是老 Dislike);在 Music 中显示=`reveal current track`+activate。统一走 `runAppleMusicMenuAction` 外壳(权限确认+后台线程,失败静默)。
- **资料库/减少推荐两行是有状态行**(2026-08-22 三批后补,起因=用户实测"点了没反应"——那首歌 7 月就已在库,`duplicate` 对已在库曲目是**静默 no-op**,不报错不重复入库,加上行点完即关面板,成功/已在库/失败三种结局零差别):开菜单 `onAppear` 异步只读回查(`currentTrackIsInLibrary()` 按 歌名+歌手+专辑 在 library playlist 1 里数匹配,专辑空退两字段;`currentTrackDisliked()`;查询用 `askIfNeeded: false`,授权弹窗只该出现在显式动作上),已在库→行变成可点的「**从资料库删除**」(AM 同款切换;`removeCurrentTrackFromLibrary()` 删匹配第一条,匹配口径与回查同一套,删完读回确认→行翻回「添加到资料库」即反馈,失败态「删除失败」可重试);点添加**不关菜单**,行内走 添加中…→已添加 ✓/添加失败(可点重试)。⚠️ 成败判定**不信 duplicate 返回值**(no-op 也报 ok),点完重新读回资料库才算,读回失败(nil)才退回信命令返回值。减少推荐=勾选切换(再点撤销,乐观更新)。AppleScript `whose` 子句只认字符串变量,内联 `name of t` 报 -1728。**三道竞态守卫**(审阅轮抓出后补):① 状态机带**代际计数**(每次刷新 +1,在途异步结果落地前核对代际、过期即弃)——防「关菜单→换曲→重开」后上一首的结局贴到新曲行上;② 菜单开着期间换曲由 `.onChange(of: 标题|歌手|专辑拼串)` 触发重刷 —— 两个状态行描述的是曲目,不跟着换就会把撤销打在新曲上;③ 回查结果不许覆盖用户在查询期间手动点过的勾(`suggestLessUserToggled`),「减少推荐」连点走**串行链**(每次写 await 上一次)防乱序终态反转。残余已知边界:点击→AppleScript 执行之间换曲仍可能加错歌(窗口亚秒级,AppleScript 层无廉价 pinning);慢网下 duplicate 超 5s 被杀但 Music 仍会完成入库,短暂误报「添加失败」、重开菜单自愈。
- **前往专辑/艺人**:AppleScript 拿不到流媒体曲目的目录 ID(URL track 连 address 都没有)→ `MusicCatalogSearch`(LyrimuseCore,纯函数被 selftest 钉住)用 iTunes Search API 按 歌名+歌手+系统店面 解析 artistViewUrl/collectionViewUrl,改写成 **music:// scheme** 经 NSWorkspace 打开 = Music.app 原生跳页。⚠️ **绝不能用 AppleScript `open location`**:它把 URL 当音频流加载、清掉整个播放队列(实机踩雷验证)。
- **显示简介**:同锚点玻璃面板,行=歌名/歌手/专辑/时长/播放器/歌词形态(逐字·译文·罗马音 从 allLines 推)/来源(EnrichCacheReader.sourceInfo 新只读口,异步取,复用歌词管理的 sourceDisplayName 中文名)。不发 AppleScript(简介不该有可感知等待)。
- **歌词时间轴行**:内联控件(标签+当前值+提前/延后/重置 三小钮),点按**不关菜单**(校准要边听边连按)。动作/步长/显示口径与菜单栏「歌词时间轴」子菜单完全同源(nudgeLyricsOffset±lyricsOffsetStepMs / resetLyricsOffset;值只显示**这首歌**的微调 trackLyricsOffsetMs、不含全局基准;重置按需出现)。trackLyricsOffsetMs 补进 WindowPlayback 窄订阅。
- **搜索歌词…**(2026-08-22 二批):歌词管理的联网搜索面板(`LyricsSearchSheet`,自包含)独立调起。点击瞬间快照曲目字段(sheet(item:) 的身份即快照,弹窗期间换歌不串)、后台解析**写回 key**(`EnrichCacheReader.resolvedKey` 新只读口,精确→宽松两级——播放器报法与缓存写法有空格/繁简出入时写回必须落在读取路径命中的同一条上,否则读写分家改了不生效;缓存无条目退 normalizedKey 新建)+当前来源。onApply 写回三步:`EnrichCacheStore.reload(onlyIfChanged: true)` 兜「store 未加载」(空 raw 上 saveEdit 会丢条目其它字段如 cover_url)→ `saveEdit` → `refreshLyricsForCurrentTrack()` 即时刷新播放侧(不等 2s mtime 轮询)。
- 评估时确认**搬不动**的:创建电台/分享电台(sdef 无电台对象、URL scheme 只能开既有电台);「分享歌曲」可行(Search API trackViewUrl+NSSharingServicePicker)但本轮用户未选。

### 进度条与拖拽跳转

- 三态:**播放中**(有 `anchor`)用 1 秒一档的 `TimelineView(.periodic)` 从锚点外推位置;**暂停**显示 `pausedPositionMs` 冻结位置;**什么数据都没有**时渲染同尺寸的 `.hidden()` 占位(不占位的话 anchor 到达时整个左栏重排,被封面淡入动画拖成"进度条从上面飘下来")。
- 画出来的进度 `shownFraction` 与算出来的 fraction 分离,补间自己驱动:正常推进用 `.linear(duration: 1)` 补间到 **pos(t+1)**——补间终点提前一秒是修"恒定落后 1 秒"的关键(插值当外推用的经典错误);冷启动/拖动中/reduceMotion 直接赋值不补间。
- 已播条是满宽胶囊 + `.offset(x:)` 向左移出 + 外层固定满宽胶囊裁剪,**不是**改 frame 宽度——补间落在变换矩阵上,不触发逐帧布局(实测把双列播放中的主线程忙碌从 61.4% 降回单列水平 9.4%);移出量由 `ProgressFillGeometry.leadingOffset` 算,进度 0 时仍留 4pt 一小截(一个圆点)。
  - ⚠️ 这里换过两版画法,**都是几何判断出错**,也正是「View 里不放几何」这条纪律的活教材。第一版 `.frame(width: w*f)` 是性能问题(上面那个 61.4%);第二版换成 `.scaleEffect(x: f)` 性能对了,但横向缩放把胶囊两端的圆头一起压扁成 x 半径 `(h/2)·f` 的椭圆,而当时的注释断言"这么矮的条上看不出来"——**那句只在 f 接近 1 时成立**。用户 2026-08-22 报「进度条有时候变成方的,不是弧形」,离线渲染逐列量覆盖高度坐实(条高 48px、右端 12 列的有色行数):`f=1.00 → 42,40,38,36,36,34,30,28,26,22,16,10`(正常圆头)/ `f=0.50 → 48,48,46,46,44,42,40,38,34,30,24,14`(已压扁)/ `f=0.02 → 48,48,…,48`(**纯矩形**)。一首 3 分钟的歌播到 0:04 就是 f≈0.02,所以现象是"进度靠前时方、靠后才圆",不是偶发竞态。
  - 现在的画法两端的圆各有出处,因此与 f 无关:**左端**来自 clipShape 那个胶囊的左圆头(裁剪框不随 f 动,只有内容在动)、**右端**来自填充自己的右圆头(被 offset 平移到 f·w 处)。同一份离线测量里 f 从 0.02 到 1.00 右端剖面恒为 `42,40,38,36,36,34,30,28,26,22,16,10`。
- 条高 4pt,悬停 6pt、按住 7pt(弹簧动画;reduceMotion 下仍变粗但不补间——变粗是功能反馈不是装饰)。
- 拖拽:`DragGesture(minimumDistance: 0)`(点一下就跳),拖动中显示手指位置而非真实播放位置,**松手才发 seek**;按下第一帧给一次触觉反馈(`NSHapticFeedbackManager` .alignment)。拖动状态存 `@GestureState`(手势被系统取消时自动复位,`@State` 会永久卡住)。
- 命中区上下各外扩 9pt 再用负 padding 抵回布局高度,且**只覆盖进度条这一行**——不含下面时间行(原来点"剩余时间"文字等于 seek 到 ~95%)。
- 时间行:左边已播 `m:ss`、右边剩余 `-m:ss`,11pt 等宽数字;拖动中两个数字跟手指走。
- `durationMs > 0` 守卫:占位态不会误发 seek。

### 播放控制排

- 五键左右对称:播放模式 | 上一首 | 播放/暂停 | 下一首 | 喜欢。播放/暂停图标宽度固定,防两侧按钮跳动;模式键和心两侧**等宽占位**(各自异步读出,不占位会错开一瞬)。
- 上一首/播放暂停/下一首:上一首/下一首直接调 `MusicPlaybackController`(Apple Music 走 AppleScript、QQ/网易云走 media-control 的系统级 MediaRemote 指令);**播放/暂停走 `PlaybackCoordinator.userTogglePlayPause()` 乐观回声版**(2026-08-21):发命令的同时立即翻转观感层 `isPlayingSmoothed`,封面缩放/播放图标点击即动,不等"命令→播放器切状态→分布式通知→250ms 去抖→poll 子进程→apply"这条实测 0.5~1s 的回读链(用户对照 AM 反馈"扩大延迟太久")。真值 isPlayingNow 不碰;命令没落地时 2.5s 对账拨回(grace 定时在跑时不抢)。全部五个 playPause 调用面(歌词窗/灵动岛/悬浮层控制条/菜单栏面板/全局快捷键)都路由到它。播放/暂停**图标**也跟 isPlayingSmoothed 走,顺带吸掉切歌间隙图标闪一下的毛病。**不做权限预检查**,失败静默(与全局快捷键 B 组不同——那边按下前会 checkForCurrentPlayerSafely、失败 beep)。⚠️待核对:自动化权限从未授权时,点这几个按钮是否会触发系统授权弹窗(osascript 子进程的 TCC 归因行为未实测)。
- **点按动画**(2026-08-21 用户对照 AM 要求):整排五键套 `TransportButtonStyle`——按下 0.1s easeOut 快缩到 0.8,松手 spring(response 0.32, damping 0.55) 带过冲弹回;reduceMotion 下不做过渡但保留按压缩小(功能反馈,非纯装饰)。
- **播放模式**:随机/循环两颗互斥按钮(AM 排布)。循环键**三态**(2026-08-21 对齐 AM):关 → 列表循环(`song repeat=all`,亮 repeat)→ 单曲循环(亮 repeat.1)→ 关——此前只有 关↔单曲 两态,且 all 被解析塌缩成「列表」(用户在 Music.app 开着整张循环、键却是灰的)。`MusicPlaybackMode` 四档 list/shuffle/repeatOne/repeatAll,解析优先级 单曲>随机>列表循环>列表;repeatAll 是 next() 老轮换**产不出**的过渡态(产出它的是循环键自己的 switch),selftest 闭合环断言把它列为例外。只在 `poller.playbackMode` 非 nil 时显示——支持范围 Apple Music + Spotify(`extendedControlPlayer`;Spotify 的 repeating 布尔写得进读不回,循环键整颗不显示、只在列表↔随机间切);QQ/网易云无 AppleScript 字典,整个不显示。乐观更新,写失败才回读纠正(写成功不回读——Music.app 的 getter 滞后于 setter)。
- **喜欢**(心,红色实心=已喜欢):只有 Apple Music 有(`poller.isFavorited` 非 nil 才显示;判定看**实际在播**的 bundle id 而非设置选项,"自动识别"下也能出现)。与悬浮窗那颗心是**同一份状态、同一个开关**(`PlaybackCoordinator.isFavorited/toggleFavorited`),乐观更新 + 动作序号守卫(在途旧读数不覆盖刚点出来的新状态)。属性名兼容 `favorited`/`loved` 两代系统。

### 音量胶囊

- 只在 `poller.soundVolume` 非 nil 时显示(同样是 Apple Music + Spotify;Apple Music 还要求自动化权限已授权)。调的是**播放器自己的输出音量**(0~100),不是系统音量。
- 结构:静音开关 | 发丝分隔线 | 自绘滑杆(92pt,轨道+白色横向药丸滑块,不用系统 Slider 的蓝色填充) | 随音量档位变的喇叭图标(0 / 1-33 / 34-66 / 67+ 四档,图标宽度固定防呼吸)。
- 拖动乐观更新 + **单飞合流**写入:同一时刻只允许一次 osascript 在飞(单次 ~100ms,自然收敛到约 10 次/秒),期间新值只存 `pendingVolumeTarget`,回来补写,保证最后松手的值一定落地。写失败才回读。
- 静音是开关:再点还原到静音前的音量,没记录(一进来就是 0)时给 50。

### 窗口动作胶囊:置顶 / 伪全屏 / 回到当前

- **置顶**(pin 图标):`window.level = .floating` 切换。**不持久化**——每次重开窗口从"不置顶"开始,tooltip 明确写了"这个状态只在本次打开这扇窗口期间有效"。
- **伪全屏**(扩/缩箭头图标):不是原生全屏(原生全屏机制在这个 App 里坏着,见"已知坑")。进入 = 保存当前 frame → 隐藏红黄绿按钮(标题栏透明/隐藏已是 .hiddenTitleBar 常驻态)→ `NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]`(两个必须一起设才生效)→ `setFrame` 撑满**整个**屏幕(含菜单栏/Dock 区域)。⚠️ 第一次 setFrame 可能被钳:presentationOptions 刚设、菜单栏还没让位时 WindowServer 把 normal 层级窗口压到菜单栏之下,顶上留一条空(2026-08-21 用户实测)——0.05s/0.35s 两拍重校 frame 兜底。退出 = 全部复原 + 恢复保存的 frame。同样不持久化。
- 伪全屏三条退出路径:再点一次按钮 / **Esc**(App 级 local monitor,keyCode 53,只在本窗是 key window 时拦截并消费,否则放行给别的窗口)/ 窗口关闭或**失去 key 状态**时强制退出(`forceExit`,无动画)——`presentationOptions` 是进程级全局状态,不清理会让菜单栏/Dock 在别的窗口/别的 App 下继续藏着。
- 置顶和伪全屏不互斥,可同时开。reduceMotion 下进出全屏不做 frame 动画。
- **回到当前播放**(location.fill):带动画滚到当前行;没有当前行(还没唱到第一句)时不做任何事。
- 真实 NSWindow 由 `LyricsWindowCapture`(NSViewRepresentable)捕获交给 `LyricsWindowController`(每个视图实例自有,非单例;窗口场景本身是 App 内单例)。

### Last.fm 系列(2026-08-22,用户点单 7 项先做出来看效果,增删待用户实测反馈)

全部按 `LastfmStatsService.isConnected` 显隐 —— 没连账号时窗口与此前逐像素一致。五个新子视图各自 @ObservedObject 服务单例但都限制在小子树内,主 body 的窄代理纪律不破。

- **「收听次数」徽标**(#1,2026-08-22 改版):挪到时间行正中央 —— AM 在这个位置放的是「高解析度无损」这类音质标签,这里复用同一份 AM 染色(见 `WindowProgressSection.secondaryTextColor` 注释),纯文字、无底色胶囊。`nowPlayingCount`(track.getinfo userplaycount+1,孪生合并/防刚 scrobble 查回 0 都在服务侧);取数由徽标容器的 onAppear/onChange(键=「歌手|歌名」)触发,容器永远在场防"没数字→不渲染→永不取数"死锁。⚠️ 首发版本(#1)是歌手行下的独立小胶囊,另配一套进度条计次刻度 + 时间行 checkmark 对勾(#6,`ScrobbleRule.thresholdFraction`,复刻 collector 的 min(时长/2, 240s)、<30s 不计);用户反馈刻度点/对勾太打扰,改成只留这一枚居中徽标。`ScrobbleRule` 本身连同 selftest 断言原样保留,只是眼下没有 UI 消费方。
- **收听档案**(#5):「显示简介」面板加 累计/首次听/上次听 三行。首次/上次来自 `user.getTrackScrobbles`(limit=1 首页取最近+total,翻到末页取最早;**本地 listens.jsonl 靠不住** —— 它只在没连账号时才记,见 collector/listenlog.go 2026-08-13 收窄),面板打开那一刻才发这两个请求。
- **欢迎态统计**(#2/#3/#4):停播页加「今天听了 N 首 · 本周 M 首」(overview)+「那年今日」(onThisDay,循环最多那首)+ 近 12 周迷你热力图(MiniHeatmapStrip 直读 dailyCounts;完整年历仍在设置统计页)。`.task` 3 分钟轮询三个刷新(各自带 TTL/单飞,重复调用是空操作),欢迎态退场时任务随视图取消。
- **「你的常听」面板**(#7):「⋯」菜单新行,同锚点第三块玻璃面板(ChartsPanelView):种类(歌曲/专辑/歌手)×周期(近7天/近30天/近一年/全部)segmented + Top 10,数据走 `refreshChart`(15 分钟 TTL);点条目经 iTunes Search 解析后 music:// 跳 Apple Music(与「前往专辑/艺人」同一条管线)。

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
- 背景(2026-08-21 第六轮:**同封面同屏对拍定稿**,AM 式动画背景):第五轮六锚点网格搜索之后,同一封面(破气球/100种生活)两边同屏截图的分位数对拍暴露了结构性缺口——**AM 把宏观场的明度布局抹平了**(四采样区 V50 全在 0.22~0.31 而封面本身左暗右亮;我们保留明度布局,表现为左缘死黑 0.157、黄斑突兀 0.114 幅度 vs AM 0.043,调 EV 够不着)。管线(`bakeWindowBackgroundLayers`):宏观场=**6×6 面积平均降采样 + 逐格乘法亮度归一化**(RGB × mean/L,homog 0.55 部分归一、系数夹 [0.4,3.5];**乘法**保色相饱和——加法提黑会灰掉,AM 暗区 S 仍有 0.62)再放大 + σ35 融格边(纯高斯两难照旧:σ大混泥/σ小见人)→ 成场后 CIVibrance(0.4)+sat0.85(对拍 AM S50 0.42~0.72,旧 1.0/1.15 全面偏高)→ 底色 EV−0.15(旧 −1.2 是保留明度布局时代压亮斑用的)→ 光斑=锚**原始**最亮格(CG 行序要翻转;居中会摊灰暗区)、羽化 0.08/0.7·W(旧 0.40 有可见轮廓,AM 无独立光斑);视图层(`WindowAnimatedBackground`)3 层光斑 lighten+α0.25、±12° 往复摆动(55/75/95s 错开)+0.15 遮罩;换歌按图层实例 `.id` 重建、0.5s 交叉淡入;reduceMotion 静止;seed=曲目标识 FNV。定量:四区 V5/V50/V95/S50/H50 加权 loss 旧参数 1.41 → 0.79(工具 scratchpad bgbake6+sweep_pair6);残余=AM 各区内部 0.10~0.21 的柔和起伏(动画相位),单帧偏平由摆动动画补。第七轮(2026-08-22,Addison 亮封面同帧对拍,用户"怎么会差距这么大"):白纱盖全脸的封面被 6×6 面积平均**灰化**(实测我们 S50 0.13~0.65 vs AM 0.63~0.97,左上区整个发灰),三步修齐 —— ①逐格**饱和度归一**(S 抬到 p75×1.5、cap 0.95:AM 的背景饱和度跟封面的鲜艳端走,连我们最鲜艳的格子都被格内白纱稀释,p75 本身够不着);②少数派**色相收拢**(主色相=S² 加权圆均值,偏离 >60° 的格子夹回 ±60°——封面小块青 logo 格被饱和归一放大成刺眼纯绿斑,AM 同区是暖橄榄绿:一个主色系+近亲点缀);③sat 乘子 0.85 改**闭环**(= satTarget ÷ 融合后场的 CIAreaAverage 实测 S,clamp [0.6,2.2]:σ35 互混+光斑 lighten 磨掉 ~30%,固定乘子对不同混合结构不可能都对;鲜艳均匀封面自动 <1 接管旧 0.85)。灰阶封面三步全自动 no-op(p75≈0/无主色相/target≈0)。终态实拍 S50 0.70~0.81、V50 0.63~0.79,均落 AM 带内。历史:①只压亮度"平"→②静态多副本→③大角度旋转副本(绿被烘黄)→④局部放大+主导色(推翻删除)→⑤6×6宏观场+锚最亮格(六锚点网格)→⑥亮度归一化(同屏对拍)→⑦饱和度归一+色相收拢+闭环乘子(亮封面对拍)。反向工程参考:[Priva28 gist](https://gist.github.com/Priva28/22fbae9dbe04a08fadf748793dd23d00)、AMLL。第八轮(2026-08-22~23,四类偏色连续判例+用户直接对拍反证+授权自行采样反推真实算法):第七轮的补丁本身还留三个洞,依次在不同封面上暴露——①**少数派色相收拢缺权重门槛**(Mont Saint Michel 城堡照,蓝天+暖褐塔身双峰色相,>60°无条件夹向主色相,把大片蓝天误判成"少数派"强行染绿)→ 补 `offHueFraction`(S² 加权占比)<0.2 才收拢,≥20% 说明本来就是双主色不该夹;②**近灰封面色相收拢被噪声放大**(窦靖童《早上好》鹅照,近乎无色,极小的色相偏置被①的门槛放过后仍被当真色相去乘饱和度)→ 补 `hueCoherenceScale`(色相方向向量长度/总权重,0.4 为满值归一再平方)乘进 satTarget/satMul/CIVibrance 三处,方向越散权重越低;③**±60° 定长位移对真·互补色不成立**(陈柏宇《你瞒我瞒》,蓝天 ~250° 与暖褐 ~20° 相距 150°+,用户拿真机 AM 截图直接反证"你这没修啊,第二张是 applemusic 的")→ 加 60°<|d|≤120° 角度上限,>120° 视为真正互补色不夹,交给模糊做自然过渡。③被反证之后,用户明确指示"自己去 Apple Music 放歌截图取真实素材、别再等用户喂图"——转向真机采样:AppleScript 激活 `Music` 进程、`System Events` 点菜单`窗口→播放中`(不是歌词面板)拿 AM 原生动态背景;`media-control get` 取封面(**发现它偶发返回上一首的陈旧 artworkData,MD5 与元数据不匹配**,workaround 是从已确认正确的 AM 截图里 `sips --cropOffset` 裁封面)。5 首风格各异曲目(你瞒我瞒/黑夜/Get on the Boat/Earth Song/Beautiful Ones)对拍出"封面网格 p75 饱和度→AM 真机渲染网格 p75 饱和度"比值:0.593/0.433/0.663/0.459/0.632,均值≈0.56——**证明第七轮定的 satTarget 系数 1.5 方向完全反了**(该是源图鲜艳端往下收到 ~0.35~0.56 倍,不是放大 1.5 倍)。另踩中一个方法论坑:早期拿 `CIAreaAverage`(单一混合数值)自查觉得已经贴近,换成对渲染结果做网格逐点采样(跟量 AM 截图同 method)一比,仍普遍超真机 1.5~3 倍——**面积平均把差异色相区域互相抵消稀释,读数天然偏低,不能拿来对标网格采样的人眼观感**,回炉按网格 p75 重新拟合系数(1.5→0.55→0.32→0.25→0.42→0.35 五轮试值),satMul 闭环乘子上下限跟着同一基准收窄(2.2/0.6→1.6/0.35)。终态:5 首里 4 首落进 AM 真机范围,你瞒我瞒仍偏热——已定位是 RGB 空间高斯模糊在两个色相相差极大区域(蓝天 ~250°/暖褐 ~20°)过渡处会生出一个跟两端都无关的诡异过渡色,结构性问题、非系数没调对,留给专项延续(见本文件"专项:背景取色逼近 Apple Music"一节,含复现脚本与已知数据集)。
- **数据同源**:歌词解析结果、当前行判定、进度锚点全部来自 `PlaybackCoordinator`(底下是 `LocalPlaybackSource` + `LyricsSyncEngine`),与悬浮歌词/灵动岛/菜单栏歌词四种形态共享同一份;本窗口独占消费的字段是 `allLines`/`currentLineIndex`/`pausedPositionMs`/`currentDurationMs`(专为它加的)。订阅经 `WindowPlayback` 窄代理(2026-08-19,五个展示面最后一个接上;这窗口实读面大,代理的收益在滤掉 currentLine/nextLineText 等每句白打醒 2~3 次的未读源 + 逐条去重);`soundVolume` 刻意不进代理——音量胶囊(WindowVolumeCapsule)自持订阅,拖音量只失效小胶囊;进度条(WindowProgressSection)自持五个拖动/补间瞬态,1Hz 推进与拖动不再击穿整窗;App 激活的三连 osascript 回读加了窗口可见性守卫(Window 场景关窗后视图树保活)。
- **歌词偏移**:菜单/全局快捷键/歌词管理改的单曲与全局偏移,实时影响本窗口的当前行判定、逐字填色基准和点击跳转补偿;但偏移调整的"歌词 +0.5s"反馈横幅只在灵动岛显示,本窗口无反馈。
- **喜欢/播放模式/音量**:与悬浮歌词控制排是同一份状态和同一套写入路径(乐观更新+序号守卫都在 coordinator),两处点哪个都一样。
- **歌词管理**:「回到当前播放」按钮交互直接照抄那边的 `focusCurrentlyPlaying`;在歌词管理里改了歌词/偏移后,重载会经 `allLines` 反映到本窗口。
- **高清封面替代**:来自 collector 解析歌词时缓存的 cover_url(歌词解析管线的副产品),只在系统 Now Playing 封面过小时启用;同名不同版本的歌可能拿到另一张封面(权衡记录在 `highResArtworkImage` 注释)。
- **Dock 图标借用**:与设置/歌词管理/引导窗口共享 `AuxiliaryWindowActivation.openCount` 计数器;用户在窗口开着期间手动打开「在 Dock 中显示」不会被关窗还原动作覆盖。
- **伪全屏的全局副作用**:`presentationOptions` 影响整个进程——切去 App 内其它窗口(设置/歌词管理)时自动退出伪全屏,防止那边找不到菜单栏;Esc 监听同样是 App 级的,靠 isKeyWindow 判断避免吞掉设置页弹窗的 Esc。
- **播放控制**:与全局快捷键 B 组共用 `MusicPlaybackController`,但权限检查策略不同(快捷键预检+beep,本窗口按钮不预检、静默失败)。

## 数据与文件

- **磁盘文件**:本窗口自身不直接读写任何文件。
- **UserDefaults**:`np:lyricsWindowFrame`(`NSStringFromRect`)+ `np:lyricsWindowScreenID`(显示器 UUID),见「入口与展示面」那条;两者都在配置备份的排除表里。
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

0. **锚定浮层不许直接消费 geo[anchor](2026-08-22「菜单开着很卡」)**:「⋯」菜单开着时实测抓到一次**亚稳态布局风暴**——主线程 2472/2485 采样全忙,每个显示周期整窗 NSHostingView.layout + AttributeGraph churn(热栈里 DefaultCombiningAnimation/SpringState 表明有动画被逐帧重触发、永不排干),菜单一关立即回全闲;后续同条件多轮开关不再复现(队列面板同场景全程无辜、独立 harness 模拟同结构也复现不出——是组合亚稳态,不是稳定必现)。热路径穿过「anchorPreference 锚令牌 → overlayPreferenceValue 闭包里 geo[anchor] 解析 → 面板 ZStack/材质布局」这条依赖边,且闭包每次重跑都新建 MoreMenuRow 闭包、diff 必失败=全量重建放大器。修法=**锚点矩形快照**:preference 闭包降级成搬运工(取整后 onChange 写进 `moreAnchorRect` @State,不变不写),面板本体挪进普通 `.overlay`、只随真实状态重建。⋯菜单/简介/常听三块已改;队列/翻译/音频输出面板仍是旧模式(实测无辜,再犯同症状照此修)。主 body 顶部留有 `Self._logChanges()` 探针(debug 级,不 `log stream` 时零成本),复发时先抓它。
1. **原生全屏(已修复,2026-08-21)**:真根因=**SwiftUI Window 默认禁全屏**——探针实验坐实:同一进程里纯 AppKit NSWindow 绿键是 AXFullScreenButton、能真进全屏 Space,SwiftUI 这扇窗却是 AXZoomButton;当年证伪的四个假设(collectionBehavior/.regular/LSUIElement/MenuBarExtra)都没碰到场景宿主这层。修复分两层:`.windowFullScreenBehavior(.enabled)`(macOS 15+ View 修饰符)**实测没生效**、仅留作官方语义表达;真正起效的是 **AppKit 层 collectionBehavior 持续守护**(`enforceFullScreenCapability`:去掉 fullScreenNone/Auxiliary、插 fullScreenPrimary;挂窗口 didUpdate 通知每个绘制周期查一位、缺才写不自激——**设一次不够**,SwiftUI 每个更新周期会把标志复写掉,实测右上角按钮 toggle 前刚补过就能进、绿键读系统当下标志就不行)。全屏按钮在 15+ 直接 `toggleFullScreen`(didEnter/didExit 维护 isNativeFullScreen 换图标,全屏中 Esc 退出);伪全屏整套保留作老系统兜底(`LyricsWindowView.swift` 文件头注释)。当年的排查手法也值得记:**同进程 AppKit 探针窗对照**一发定位到宿主层。
2. **`presentationOptions` 是进程级全局状态**:必须 willClose + didResignKey 双兜底清理,否则伪全屏残留会让别的窗口/别的 App 找不到菜单栏。
3. **Esc local monitor 是"发给本 App 任意窗口"级钩子**:早先注释声称按窗口过滤但回调没做,吞掉了设置页弹窗的 Esc;现在显式判 `isKeyWindow`,与 didResignKey 兜底是两道独立防线。
4. **进度条"恒定落后 1 秒"**:补间终点必须取 pos(t+1) 而不是刚算出的当前位置——两档采样间做插值画出来的永远是过去(把插值当外推用)。
5. **进度条填充只让渲染变换随进度走,不改 frame 宽度**:布局属性跟着每秒线性补间走会逐帧重布局整个 NSHostingView(实测双列 61.4% 忙 vs 单列 9.4%)。但那个变换**不能是 `scaleEffect(x:)`** —— 横向缩放会把胶囊圆头一起压扁,f 小时变成直角(用户报的「进度条变成方的」);正解是 `.offset(x:)` 移出 + 固定胶囊裁剪,几何算在 `ProgressFillGeometry`(Core)里、有 selftest 钉住。
6. **逐字时钟两级化(现役机制,2026-08-21 五轮验证)**:TimelineView 下沉到字级叶子(挂行容器上每帧推翻 WrapLayout 重算,主线程 91% 忙)、4Hz 粗时钟+只给"正在扫的字"留满速细时钟(相位不齐的满速时钟并集盖满每个显示帧,85.8% 忙)。同日曾以"fillFraction 对时间线性→不用逐帧重算"为由整体改排程式,又因 macOS 对长时程慢动画只以 ~20Hz 提交(SCK 探针实测、无 API 干预)而回退——**TimelineView 的频率受控可验,排程式的提交节奏系统说了算**,这是两级时钟活下来的根本理由;窗口档位 60Hz、悬浮歌词/灵动岛 30Hz。
7. **`LyricsLineRow` 的 Equatable 必须手写**:带闭包参数的视图 SwiftUI 结构比较直接失效;配合 `maxVisualDistance = 4` 让远处行输入不变,换行重算范围从整表缩到当前行上下各 4 行。
8. **当前行的 scaleEffect(1.02) 已删除**:渲染后仿射变换在 1x 外接屏上把最该看清的一行糊掉(字形边缘过渡宽度实测 1.48px vs 1.14~1.25px),而强调感实际由满不透明度/零模糊/逐字填色扛着。
9. **拖动状态用 @GestureState 不用 @State**:手势被系统取消(进度条所在条件分支被摘掉)时不会调 onEnded,@State 会永久卡住拖动值、冻结进度条。
10. **玻璃胶囊不进 toolbar**:"玻璃采样不到玻璃",toolbar 里的 Liquid Glass 胶囊退化成不透明灰块。(旧的另一半"背景不 ignoresSafeArea——防标题栏文字撞色"已随 2026-08-21 AM 式顶部作废:scene 挂 `.windowStyle(.hiddenTitleBar)`,无标题文字,背景显式 `.ignoresSafeArea()` 通到窗顶、红绿灯悬浮其上;伪全屏的 enter/exit 相应只管红黄绿显隐和窗口帧,不再来回切标题栏状态。)
11. **行激活不能切换渲染结构**(2026-08-21):原来非当前行渲染单个 Text、变成当前行时整棵子树替换成 WrapLayout+逐词 KaraokeLineText——SwiftUI 对结构替换只能淡出淡入,叠上行级 blur/opacity 动画,表现为"新行有一个虚化重新构建的过程"(只有带逐字时间轴的歌触发,纯行级歌词两态都是 Text——"有时候"的来源)。修法=统一结构:有 words 的行恒走 KaraokeLineText,`isActive` 参数化,非活跃行定格全填色、不排动画、字不上浮。逐词读音(groups)仍只在活跃时挂(占位会撑行高)。
    统一结构当天引出第二个坑:**取值参数化之后,取值的跳变会被外层作用域动画捕获**——激活瞬间词的填色从"定格全色"跳到"按时间≈0",这个 diff 落在行级 `.animation(value: distance)` 的作用域里,渐变 stop 被从 1 **插值**回 0、画整段 0.45s 褪色(未唱到的字时钟停着,没有下一帧掰正)——用户报的"下一行先全部亮一下、再从头逐字"。排程式重构后从机制上根治:取值变化只发生在 sync() 自己 `disablesAnimations` 的事务里。顺带修掉的隐藏 bug:旧 forceFilled 用 fraction=1.0 算渐变,left=1−band<1 走不到纯色快路径,非活跃词右缘 band 段一直被淡到半强度;定格值应取 1+band。
12. **`Menu`(.borderlessButton)会压平自定义 label 并接管其颜色**:「…」圆钮的圆底(2026-08-19「没有外面的圈」)和白色字形(2026-08-21「圈里应该是白点」)都被这机制丢过,实际热区还只有 label 固有尺寸那一点(2026-08-21「只有点按钮中心才有效」)。**最终解法:整个弃用 Menu**,换成普通 Button + 自绘 AM 式面板(`moreMenuPanel`,深色玻璃圆角白字、悬停行高亮;anchorPreference 取按钮窗内坐标 → 窗级 overlayPreferenceValue 定位在按钮上方右对齐,全窗透明捕手点外即关,面板从贴按钮的右下角缩放长出)。ImageRenderer 不支持 Menu(渲出黄色占位)——换掉之后这个按钮终于能离屏验了。plain Button 的行要整行可点必须 `.contentShape(Rectangle())`(默认只有非透明像素可命中)。
13. **排程式填色已废弃(2026-08-21 当日往返,防再犯)**:曾把填色改成"snap+一次性 .linear 显式动画交渲染管线插值"(LyricsX/AMLL 同架构)——CPU 上确实零逐帧代码,但 SCK 逐帧探针实测 **macOS 对这类长时程慢动画只以 ~20Hz 提交**(系统自动降档、无 API 干预;对照组悬浮窗 TimelineView 30Hz 准点投递),20Hz×14px 边缘步进=用户报的"卡顿感",遂回退到两级时钟逐帧重算(见 #6)。若将来重试排程式,先用 SCK 探针核实提交频率再谈;当时趟出的坑(对表完备性要含字号/屏缩放、倍速除进时长、additive 动画同值赋值取消不掉要加盖板)记录于 durable note `swiftui-karaoke-fill-schedule-linear-animation-not-per-frame`。
14. **`.hiddenTitleBar` 标题栏拖窗区是 WindowServer 级判定,进程内无正规手段拦截**(2026-08-22,拖音量胶囊带着整窗跑):实测五种进程内拦截手段全部失效——SwiftUI `.background()` 挂载的自定义 NSView,命中测试根本进不去外层 NSHostingView 判定拖拽的路径;改用 `addSubview` 直接挂上 NSHostingView(绕开 SwiftUI 树,`hitTest` 验证确实命中了)窗口依旧跟着拖;自定义 NSWindow 子类覆写 `sendEvent(_:)` 吞掉再手动转发,窗口照样被拖且手动转发的事件从未真正送达 SwiftUI;仿 `NSControl` 内部同步 `mouseDown` 追踪循环(假设异步分发才是差异根源),循环里同样收不到任何事件。结论:标题栏拖拽区域的判定发生在比任何单个 view 的 `mouseDownCanMoveWindow`/事件转发策略更底层的地方,进程内没有正规手段覆盖。**修法是几何规避,不是代码修复**:把音量胶囊从"贴住标题栏那一行、跟红绿灯对齐"的固定偏移(`-geo.safeAreaInsets.top + 8`)改成"退到 safe area 之外再加 8pt 边距"(`offset(y: 8)`),牺牲跟 AM 同排对齐的视觉细节换取拖动不再连累整窗;置顶/全屏那颗胶囊是纯点击、没有这个问题,原样保留在标题栏行内的旧偏移。
15. **"三个点要呼吸"排查两轮才找对目标,根因是从没让用户确认过指的是哪颗**(2026-08-23):用户原话"这个三个点…不会和 applemusic 那样变大变小呼吸,帮我加上"+一张只有三个点的截图,没有更多上下文。**凭截图猜了「…」更多菜单按钮**(标题栏星形收藏旁那颗、SF Symbol `ellipsis` 字形),两轮都在这颗按钮上打转:①第一版用系统 SF Symbols API(`.symbolEffect(.breathe.byLayer)`,理由是 `ellipsis` 标注了三点独立层),自测(截图间隔采样白色像素数)一度误判已生效,被用户反证"没有大小波动"后改用**星形收藏按钮当同帧静态对照**重测(星形像素数全程纹丝不动=对照有效,「…」却是在 0 和满值间硬切,不是平滑波形)才发现真相——另起隔离测试 App 证实 `.breathe` 在 60pt 下平滑、缩到生产尺寸(14pt 字形)就崩成硬切,遂改用本文件 `idleWelcomeView` 已验证好看的手写方案(`@State`+`.scaleEffect`/`.opacity`+`.animation(...repeatForever, value:)`),星形对照法重测确认这颗按钮**真的**变成了平滑正弦波(36→68→36)。②**部署后用户第二次说"还是没效果"**,这时候才每贴一张**带红色箭头标注**的截图——箭头精确指向的其实是完全不同的元素:歌词区上方、间奏/前奏时出现的「•••」进度指示点(`gapDotsRow`,随间奏进度依次点亮亮度,但从没做过大小动画),跟「…」菜单按钮毫无关系,从会话最初的一张模糊截图起就理解错了。当场撤销「…」按钮上的改动(用户明确说过不是这里,不能留着一个没人要的效果),转头给 `gapDotsRow` 的三颗点加同款相位错开呼吸(`.scaleEffect` 0.82↔1.18,每颗 `.delay(i*0.16s)`,复用同一验证过的动画写法,不碰原有的按进度点亮的透明度逻辑),用「暂停播放冻结间奏帧、脱离播放推进/滚动的干扰」的方法重新截取验证(而不是追着转瞬即逝的间奏窗口抢拍)确认三颗点确实带相位差地忽大忽小。教训:①**用户给的是"哪个东西"而不是"哪类东西"的单张截图、且第一直觉的匹配对象在代码里存在但语境薄弱(没有相邻的星形/歌名等锚点辅助确认)时,应该先用一句话向用户确认定位("是指标题栏星形旁边那颗'…'菜单按钮吗"),而不是径直动手改——两轮返工的成本远高于一次确认的成本**;②同一个诊断/自测方法论用对了目标才有意义,方法论本身没错(星形对照、隔离测试、暂停冻结取帧)在两个目标上都复现了同样有效的结论,说明problem不在"怎么验证",而在"验证的是不是用户真正想要的那个东西";③一旦发现改错了目标,**要先撤销错误改动**,不能在错误目标上留一个将错就错的"顺手也不错"的效果。

## 专项:背景取色逼近 Apple Music(进行中,2026-08-23 开新会话延续)

第八轮(见上)把 `bakeWindowBackgroundLayers` 的饱和度系数从"方向反了的 1.5 倍放大"扳正成"跟真机数据拟合的 0.35 倍收缩",5 首真机样本 4 首落进 AM 范围——但这仍是**单变量线性模型在 5 个样本上的粗拟合**,不是逆向出 AM 真实算法。第九轮(见下)用 23 组样本推翻了"固定倍率"本身,换成幂函数。以下是继续这项工作的素材和方法,新会话可以直接从这里接着干,不需要重新摸索采样方法。

**第九轮(2026-08-23,23 组批量截图对拍,推翻固定倍率 K)**:用户不再一首首手动过 AppleScript recipe,而是自己批量拉了 23 组"AM 原生播放中窗口 × 我们歌词窗口"的同封面同曲同帧截图对,每组给一句主观判断(差别大 / 还好 / 可以接受……),一次性甩过来对拍。这是比下面 recipe 快得多的采样方式(零 AppleScript、零 media-control,唯一前提是用户手上已经有对拍图),新会话拿到类似的成批截图时优先用这条路径。处理方法:
1. 截图有真实文件路径时(本例是 iTerm/otty 粘贴板临时文件)直接用 `sample-bg-saturation.py` 网格采样,不要只凭肉眼——23 组图分辨率、窗口位置全部一致(同一次会话截的),意味着可以对全部样本用**同一组裁剪分数坐标**批量跑,不用逐张目测定坐标:本例用左侧一条竖直窄带 `--x0 0.02 --x1 0.10 --y0 0.22 --y1 0.85`(封面卡片左缘固定在 `0.11W`,这条带永远在封面/歌词文字左侧,躲开了标题栏红绿灯行和 Dock)。
2. 封面身份靠 `magick convert <截图> -crop <封面尺寸>+<偏移> ...` 批量裁出封面缩略图再 `montage` 成一张联系表一次性看清,比逐张打开 23 张截图快得多(本例封面卡片在 823×824+323+446,伴随的标题/歌手说明文字是 ImageMagick 读到的 PNG 内嵌描述,不是裁出来的像素,顺带验证了封面身份)。
3. 对每组分别测:源封面网格 p75 饱和度(`src_p75`)、AM 真机背景网格 p75(`AM_p75`)、我们背景网格 p75(`our_p75`),以及主色相(圆均值)。

**发现 1(饱和度量级,主因,已修复)**:23 组里用户判"差别大"的 7 组中有 5 组(P. Control / Babygirl / 谁稀罕 / Sign O' The Times / 小镇姑娘)根子是纯饱和度不够,不是色相错——这 5 组源图 satP75 全在 0.65~0.96(封面本身极浓烈),AM 真机背景网格 p75 也跟着到 0.76~1.00(**AM/源比值 0.98~1.20,即 AM 对这类封面几乎不压、甚至略微增艳**),而固定 K=0.35 无论源图多浓都只给 0.23~0.34,砍掉七成以上,肉眼就是"浓烈橙红→浑浊灰棕"。反过来,23 组里"还好/可以接受"的对照组源图 satP75 均值只有 0.42(差别大组均值 0.77,接近两倍),说明**固定倍率模型在低饱和封面上误差可以忍,在高饱和封面上误差会被放大到肉眼刺眼的程度**——这不是巧合,是线性模型的结构性缺陷:把 AM 的处理看成"打折缩放",但真机数据画出来是一条**凸曲线**(源图越浓,AM 保留比例越高,不是越低)。全部 23 组 `(src_p75, AM_p75)` 做对数-对数回归,拟合出 `AM_p75 ≈ 0.94 × satP75^1.45`(R²≈0.77,比线性拟合 R²≈0.70 更贴且物理意义更对——低端趋于 0、不用额外 clamp)。已把 `satTarget` 换成这条幂函数(`min(0.95, 0.94 × pow(satP75, 1.45)) × hueCoherenceScale`),`satMul` 的上下限刻意**没有**跟着抬(见下面"发现 3")。离屏复现验证(23 张封面全部裁出跑 `bakebg-repro.swift`,新旧两版对比同一份 AM 真机 p75 目标):7 组"差别大"里 5 组纯饱和度问题的目标误差均值从 0.39 收到 0.13(例如 P. Control 0.41→0.03,小镇姑娘 0.58→0.05,Sign O' The Times 0.48→0.22),其余 15 组"还好/可以接受"的均值误差基本没变(0.133→0.142,噪声范围内),没有明显此消彼长。
**发现 2(色相,未解决,新坑)**:7 组"差别大"里另外 2 组(黑夜 / Get on the Boat)复测发现饱和度差距本来就不大(甚至我们比 AM 更浓一点点),真正的差异是色相——网格主色相圆均值算出 AM 与我们相差 20°+;而这两张封面各自离屏跑 `--verbose` 查 `hueCoherenceScale` 都是 1.0、`offHueFraction` 接近 0(算法判定色相完全一致、没有触发任何色相纠偏分支),说明色相偏差不是发生在色相收拢/角度上限那三个已知补丁里,病灶在别处(候选:σ35 高斯模糊本身在 RGB 空间对单色系封面做通道级模糊时的隐性偏色、6×6 降采样阶段的插值伪色、或者是这两首歌真机截图本身的取样时机凑巧撞上了背景动画摆动的某个相位)。**这条幂函数修不了它**,饱和度对了不代表色相对,下一轮需要专门测色相,建议围绕这两张封面 + 再补几张"单一色系但偏暖/偏冷"的封面做 `--verbose` 逐格 hue 对拍。
**发现 3(satMul 闭环上限,刻意不抬,记录原因防止日后误改)**:`satTarget` 换成幂函数后数值整体变大,理论上更容易顶到 `satMul` 的上限 1.6。实测 23 组里只有 1 组(I Wanna Be Your Lover,蓝底+人像肤色两大色系反差大)顶到过 1.6,而且**抬上限治不好它**:这张封面 σ35 融合后 `fieldS` 崩得极狠(源 satP75=0.56 → fieldS=0.15),把上限从 1.6 抬到 2.2 甚至 3.5,网格 p75 从目标 0.37 一路冲到 0.94~1.00(实测过,过饱和)——根子是"`satMul` 闭环按**面积均值** `fieldS` 校准、但 `satTarget` 本身是按**网格 p75** 校准出来的",这个口径错位在旧版本(数值小)时不明显,数值一放大就暴露。抬上限只会把这类高反差封面推向过饱和,不抬则维持"跟旧版本一样欠一截"——两害相权选择不抬,把这个已知残余记在这里而不是悄悄改掉上限。

**目标**:不满足于"这几张封面调对了",而是尽量摸清 AM 背景取色的真实规律——采更大更多样的样本集,检验线性模型是否够用(还是需要非线性/多变量),并解决下面提到的模糊过渡色结构性问题。

**真机 ground truth 采集recipe**(实测可行,按顺序执行):
1. `osascript` 激活 `Music` 进程(bundle/进程名是 `Music`,不是 "Apple Music"),换一首想采样的歌。
2. `tell application "System Events" to tell process "Music" to click menu item "播放中" of menu "窗口" of menu bar 1` 打开 AM 原生"播放中"沉浸视图——**这不是**`显示→显示歌词`那个歌词面板,后者背景不是同一套动态渲染。
3. `screencapture -x <path>.png` 截图。**先截一张全屏截图确认 Music 窗口真的在当前活跃 Space 上**——`screencapture -x` 只截当前活跃 Space,窗口在别的 Space 上会截到不相关内容;`CGWindowListCopyWindowInfo` 在非活跃 Space 上枚举窗口本身也不可靠(项目已知坑,"双屏标准 Window 易失效"同根)。
4. 取封面:优先 `media-control get`(homebrew `/opt/homebrew/bin/media-control`)读 `artworkData`(base64 JPEG)。**已知坑**:偶发返回上一首的陈旧字节,即使 title/artist 元数据已经是新曲目、等 3 秒也不解决——发现时用 MD5 比对旧封面확认。workaround:直接从第 3 步已确认正确的 AM 截图里 `sips --cropOffset X Y -c H W` 裁出封面区域,不依赖 `media-control` 的封面字段。
5. 用 `scripts/sample-bg-saturation.py <截图.png> --x0 .. --x1 .. --y0 .. --y1 ..`(先框定"背景可见、不被封面卡片/文字遮挡"的区域,坐标视具体截图分辨率/版式而定,没有一劳永逸的固定值)网格采样,记录 median/p75 饱和度。
6. 用 `swift scripts/bakebg-repro.swift <封面.jpg> --out baked.png` 跑一遍现网算法,同样用 `sample-bg-saturation.py`(默认参数,适配它 360×360 的输出)采样对比。
7. 系统被闲置挂起过一次导致 `System Events` 进程本身被 `SIGSTOP`(`ps -o stat` 显示 `T`),所有 AppleScript 调用报"应用程序没有运行"——`kill -CONT <pid>` 可安全恢复,不是重装/重启。

**已知数据集(旧,5 首,已被第九轮 23 组数据取代,留作历史参照)**:封面网格 p75 饱和度 → AM 真机渲染网格 p75 饱和度,比值:你瞒我瞒 0.236→0.14(0.593)、黑夜 0.577→0.25(0.433)、Get on the Boat 0.769→0.51(0.663)、Earth Song 0.458→0.21(0.459)、Beautiful Ones 0.380→0.24(0.632),均值≈0.56。⚠️ 第九轮的 23 组数据里再次采到了黑夜/Get on the Boat(同一批封面不同截图时机),测出的 `(src_p75, AM_p75)` 跟这份旧表对不完全上(黑夜这次是 0.625→0.343,Get on the Boat 是 0.751→0.438)——说明 AM 背景本身有动画摆动,同一封面不同帧测出的绝对值会有起伏,**单点校准天然带噪声,这也是第九轮宁可多测 23 组做回归、也不再迷信个位数样本的原因**。

**第九轮 23 组数据集**(2026-08-23,同一次批量截图对拍;`src_p75`=源封面网格 p75,`AM_p75`/`our_p75`=对应背景网格 p75,`verdict`=用户主观判断):P. Control 0.939/0.922/0.410·差别大;The Beautiful Ones 0.421/0.234/0.148·还好可以接受;2 Bad 0.592/0.500/0.404·还好可以接受;I Wanna Be Your Lover 0.620/0.371/0.556·还好可以接受;Babygirl 0.789/0.928/0.360·差别大;Deadman 0.258/0.100/0.077·可以接受;月亮代表我的心 0.163/0.090/0.179·可以接受;你瞒我瞒 0.277/0.142/0.077·可以接受;2 Bad(复测)0.600/0.471/0.404·可以接受;Blood on the Dance Floor 0.707/0.640/0.306·稍微差点不过还好;黑夜 0.625/0.343/0.385·差别大(色相问题,见发现 2);Get on the Boat 0.751/0.438/0.384·差别大(色相问题);玩乐 0.466/0.671/0.118·还好;All for Joy 0.429/0.076/0.045·还好;张永成 ≈0(近灰阶)·还好;公转自转 0.764/0.363/0.423·还好;早上好 0.133/0.044/0.123·还好;谁稀罕 0.671/0.760/0.281·差别大;明明就 0.359/0.253/0.253·还好;Controversy 0.318/0.300/0.122·还好;Sign O' The Times 0.649/0.780/0.240·差别大;小镇姑娘 0.961/1.000/0.236·差别大;鬼-Overture 0.595/0.447/0.500·还好。当前上线公式:`AM_p75 ≈ 0.94 × satP75^1.45`(取代旧 K=0.35 常数)。

**已知未解决问题**(新会话的重点候选方向,按优先级):
1. **色相偏差(第九轮新坑,优先级最高)**:见上面"发现 2"——黑夜/Get on the Boat 这类"AM 与我们饱和度接近但色相偏了 20°+"的案例,`hueCoherenceScale`/`offHueFraction` 都测出算法认为色相没问题,说明偏差另有病灶,还没定位。建议先用 `--verbose` 逐格拆解这两张封面,再补几张同类"单一色系但偏暖/偏冷"的封面扩大样本。
2. **RGB 空间高斯模糊的过渡色伪影**:两个色相相差很大的区域(如你瞒我瞒的蓝天 ~250° 与暖褐 ~20°)在模糊过渡带会生成一个跟两端都无关的诡异色相(偏洋红),这是结构性问题——换更大/更小的系数都治不了,需要换混色方式(例如在 HSV/Lab 空间做混合,或者过渡带单独限幅色相跳变范围)。第九轮里你瞒我瞒被判"可以接受",不代表这个 bug 已经消失,只是这次取样的帧没暴露它。
3. **`satMul` 闭环的面积均值/网格 p75 口径错位**:见上面"发现 3"。高对比度(两大色系反差大、模糊后 `fieldS` 崩得凶)的封面会顶到 `satMul` 上限却依然够不到 `satTarget`,抬上限只会让它过冲。需要的是把闭环本身换成网格采样校准(而不是 `CIAreaAverage`),但那需要在 CIImage 管线里做网格采样,渲染期开销未评估,留给下一轮设计。
4. **样本仍偏单一变量**:幂函数拟合只用了源图饱和度这一个变量,R²≈0.77 不是 1——`satTarget = f(satP75)` 之外,明暗/人像肤色占比/构图复杂度大概率还是残余误差的来源,继续扩样本(尤其纯黑白、强逆光、暗色调封面)有机会把 R² 往上提。
- **面积平均 vs 网格采样的方法论教训要牢记**:任何新一轮校准都必须用网格采样(`sample-bg-saturation.py`)比对,`bakebg-repro.swift` 打印的 `FINAL(area-average)` 那一行只能当内部诊断参考,不能当校准依据。

**复现工具**(已整理进仓库,不在临时 scratchpad):
- `scripts/bakebg-repro.swift`——逐行对应现网 `PlaybackCoordinator.swift` 的 `bakeWindowBackgroundLayers`(2026-08-23 第九轮同步更新到幂函数 `satTarget`),加了 `--verbose` 打印每格 hue/sat 与 hDom/offHueFraction/hueCoherenceScale/satMul 中间量,`--out` 导出 360×360 烘焙结果。改了正式代码的算法记得同步改这份脚本(两边不共享源码,靠人工保持一致)。
- `scripts/sample-bg-saturation.py`——纯标准库 PNG 解码(免装 PIL/numpy)+ 网格采样,统计 median/p75 饱和度,配合上面的 recipe 使用。⚠️ 对整张 2940×1716 这类大截图直接跑纯 Python PNG 解码(Paeth 逐像素回滤)很慢(单张要 10+ 秒,23 张会拖到几分钟)——批量处理前先用 `sips -Z 500` 把截图等比缩小再采样,分数坐标不受影响,解码耗时降一个数量级。
- 批量截图对拍(第九轮新增方法,未落地成脚本,记录在这里供复用):同一批截图分辨率/窗口位置一致时,ImageMagick(`brew install imagemagick`,`convert`/`montage`)可以用**同一组像素坐标**批量裁出封面缩略图 + `montage *.png -tile N x M contact_sheet.png` 拼成联系表一次性核对封面身份,比逐张打开截图快得多;背景采样坐标同理可以对全部截图复用同一组分数坐标(见上面"第九轮"段落的具体坐标)。

**当前构建状态(2026-08-23)**:第九轮改完 `PlaybackCoordinator.swift`/`bakebg-repro.swift` 后跑过 `./build.sh` 做完整性校验,发现 `LyricsSyncEngine.swift`/`LocalPlaybackSource.swift`(`allLines`/`gapMarkers`/`CompactLyricLead` 相关,switch 分支不完整)有一份**跟本专项无关的未完成改动**导致整个 App 编译不过——用 `git stash` 单独隔离过 `PlaybackCoordinator.swift` 复现验证,确认那份错误在本专项改动之前就已存在。本专项的改动已经过第九轮 23 组数据 + `bakebg-repro.swift` 离屏复现双重验证(见上),但**没有经过 `build.sh` 全量编译 + 真机播放验证**——等那份未完成改动被处理掉之后,记得先补一次真机播放校验(尤其是"发现 3"提到的 I Wanna Be Your Lover 这类高对比度封面,离屏复现显示可能过饱和)。
