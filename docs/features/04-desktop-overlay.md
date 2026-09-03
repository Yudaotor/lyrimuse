# 04. 桌面悬浮歌词
> 最后核对:2026-09-03 · 基线:e103532+工作树

## 定位

贴在桌面上的无边框悬浮歌词窗(代码里叫"经典悬浮窗"/classic overlay):常驻置顶、跨 Space(含全屏 App 上方)、默认点击穿透,只显示当前一句(可选罗马音/译文/下一句预览),逐字歌词做卡拉OK渐变填色。它是三种悬浮展示形态(桌面悬浮/灵动岛/菜单栏)中可定制度最高的一种,也是字体/字重/字号/配色这组设置的唯一消费者。

## 入口与展示面

| 入口 | 说明 |
|---|---|
| 设置 → 歌词显示 → 悬浮歌词 段 | 总开关(`classicOverlayEnabled`)+ 全部外观/窗口设置;**2026-08-30 起段顶不再钉预览条**,改由内容区里的编辑台 `OverlayEditorStage` 承担(见下「编辑台改造」) |
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
- 声部影响**五**处:卡片内 VStack 对齐、多行文本对齐、WrapLayout 行内对齐、**两侧内缩**(`LyricDuetLayout`,见下),以及**卡片上方那排控制按钮的横向落点**(2026-09-03 补,见下)。
- **两侧内缩**:光靠对齐不够 —— 顶满整宽的行左对齐和右对齐渲染完全相同。左声部行远侧(右)留白多、近侧(左)留白少,右声部反过来,合唱两侧都按远侧的量留;远侧比例 15% 且以 4 个字宽封顶,`side == nil` 的行一律 0(普通歌排版逐像素不变)。这是 Apple Music / AMLL 的实际做法。⚠️ **近侧留白**(2026-08-26 加,`LyricDuetLayout.nearInsetRatio` = 远侧的一半,以 2 个字宽封顶):在此之前近侧恒为 0,短句会直接贴着卡片的物理边缘(悬浮窗)/正文列边缘(歌词窗口),用户反馈"左右两块太分开、顶到边了"。近侧留白把整块内容往中间拉一截,同时保持"远侧 > 近侧"这条不变式——分栏的方向感(偏左/偏右)还在,只是不再顶边。共享同一份 `LyricDuetLayout.insets`,悬浮窗和歌词窗口(第 07 章)一起生效。
- 逐字数据里标记的切分形态**不固定**:可能跟第一个字粘成一个词(`男：周`)、可能独立成词(`男`+`：`)、人名还会被逐字拆开(`周`+`杰`+`伦`+`：`)。所以判定必须在**整行拼起来**的文本上做,剥离按**字符数**从词序列前端剥(剥到一半的词改文本、保留时间戳)。
- **声部指示圆点+细竖线**(2026-08-27 加,`withSpeakerIndicator`):光靠左右对齐不够直观——尤其当前行和下一句预览可能贴在不同边(见下一句预览独立分栏那条),一眼扫过去容易看错是谁在唱。`.leading`/`.trailing` 各配一个 6pt 圆点 + 2pt 细竖线,贴在文字所在的那一侧(不是固定贴左边,跟着文字换边)。`side == nil`(没有对唱信息)和真正的合唱(`.center`)都不显示指示——前者是普通歌,排版必须逐像素不变;后者不属于任何一侧,硬塞一个标记反而暗示"这是某个人在唱"。当前行(`mainLine`)和下一句预览各自独立套这层指示,用的是各自的 side(`duetSide`/`nextLineDuetSide`)和各自的颜色,跟两侧内缩/分栏是同一个"各自独立算"的原则。⚠️ 只在词级(`WrapLayout`)行上会有一个可感知的副作用:`withSpeakerIndicator` 把圆点+竖线跟内容一起塞进一个 `HStack`,WrapLayout 拿到的可用宽度会因此变窄约 20pt(圆点 6pt + 竖线 2pt + 两段 7pt 间距)——影响很小,量级跟两侧内缩本身相近,没有必要为了避免它去改用更复杂的 overlay 定位方案。
  - ⚠️ **罗马音/译文行没套这层指示,导致对唱歌里它们的文字比主歌词整体靠左**(2026-08-27 用户反馈"翻译比实际歌词靠前、没对齐",实测坐实)。三行共享同一个 `VStack(alignment: duetAlignment)`,VStack 按每个子视图的 **frame** 左边缘对齐——主歌词那一支被 `withSpeakerIndicator` 包了一层 `HStack`(圆点+竖线+文字),这层 `HStack` 的左边缘是圆点,不是文字;罗马音/译文没有这层包装,左边缘直接就是文字本身。于是罗马音/译文的文字比主歌词的文字整体靠左了 22pt(圆点 6pt + 竖线 2pt + 两段 7pt 间距,跟上面"WrapLayout 变窄约 20pt"是同一份几何值,当时只注意到"变窄"没注意到"跟着这一支之外的行对不上")。普通歌(`side` 恒为 `.center`)不受影响,只有对唱歌才会看见。修法:`speakerIndicatorInset(side:)` 照抄同一份几何值,不画圆点、只当 padding 补给罗马音/译文,让三行文字的**文字本身**对齐,不是容器对齐。
  - **颜色**(2026-08-27 二次修改,用户实测反馈):初版用固定的蓝/粉两色跟"身份"绑定,理由是跟主题脱钩才能在任何封面下分得清两个声部——但实测这套颜色跟用户自己选的配色主题不搭。改成调用方直接传这一行文字实际在用的颜色(`playback.displayForegroundColor`,下一句预览额外带它自己那份 0.4 不透明度),圆点/竖线跟贴着的文字同色同淡,"谁在唱"改成纯靠**位置**识别(先出现的贴左、第二位贴右,跟 `LyricDuet.sides` 的定边顺序一致),不再靠色相区分。
  - **竖线长度**(2026-08-27 二次修改,用户反馈"线太长了,占视野"):初版 `.frame(maxHeight: .infinity)` 跟着这一行的完整高度撑满,主行字号越大越显眼;改成固定 `speakerBarHeight = 12`,不管主行还是更小号的下一句预览,视觉分量都一样克制,只当一个不起眼的边角标记。
- **控制排跟着歌词块换边**(2026-09-03,用户实机反馈:「在对唱模式下,这个悬浮菜单不是显示对应歌词上面的,看起来是在整个窗口的居中位置」)。歌词卡片一直是 `.frame(maxWidth:.infinity, alignment: duetFrameAlignment)` 按声部靠边,而卡片上方那排播放控制按钮(以及锁定态那颗解锁按钮)只吃外层 `VStack(spacing: 0)` 默认的 `.center` —— 对唱歌把歌词甩到右半边时,按钮排还钉在整扇窗正中。**普通歌看不出来纯属巧合**:`duetSide` 兜底就是 `.center`,两条推导算出同一个位置,所以这个偏差从 2026-08-14 对唱分声部落地起一直藏到现在。
  - **修法**:按钮排套上 `.padding(controlsInsets)` + `.frame(maxWidth:.infinity, alignment: controlsFrameAlignment)`;`controlsInsets` = 卡片两侧内缩 + 卡片水平内边距,算法搬进 core 的 `OverlayCardGeometry`,**跟卡片共用同一份出处**而不是各算各的 —— 本仓已经为"同一个视觉属性两条渲染路径"付过三次账(预览条对齐写死 `leading`、灵动岛手搓预览、编辑台简化复刻件),这次直接把它钉进 selftest。
  - **实测**(离屏 `NSHostingView` 复刻同一条修饰符链,1016pt 窗宽 / 31pt 字号 / `unit = 124`):左声部 `pill.minX = 歌词块.minX = 20.0`;右声部 `pill.maxX = 歌词块.maxX = 996.0`;居中仍是 `401.0…615.0`(= 改动前 VStack 居中的落点,`214` 宽的胶囊在 1016 里居中)。同一首普通歌改动前后各截一张悬浮窗,PNG **sha256 完全一致**。
  - 对齐的是**歌词块**的边缘,不是文字本身的边缘 —— 对唱行的声部指示圆点(22pt)算在块里,所以左声部时按钮排左边缘跟那颗圆点对齐、比文字左边缘再往外 22pt。刻意如此:圆点是这一行的一部分。
  - ⚠️ **指针压在按钮排上时把落点冻住**(`OverlayControlsSidePin`)。换边的幅度就是大半个窗宽(上面那组实测两个落点差 759pt),而对唱歌几秒换一次行 —— 用户瞄准某颗按钮的那零点几秒里赶上换行,整条按钮排会从指针底下抽走:轻则点空(事件照旧穿透到桌面),重则点到挪过来的**另一颗**按钮上,而这排里有「关闭悬浮窗」和「锁定位置」两颗点错了要费事收拾的。判据是"指针压在按钮排上"(新增 `OverlayChromeSource.isHoveringControlPill`;控制器侧未锁定时用胶囊热区 `controlsHotZoneLocal`,锁定态那条热区不上报、退回按钮矩形),**不是**"控制排显示着"(`isHoveringForControls` 是整窗判定)—— 后者会让指针只是停在窗口里、根本没在瞄按钮的时候也一起冻住,那正好又变回用户这次反馈的现象。指针一离开,下一行立刻回到跟着歌词走。
  - 冻结存的是**原始声部**(`line?.side`)而不是算完的对齐方向:落点由"对齐方向"和"两侧内缩"两条推导合成,这两条在非自动的「对齐方式」覆盖下会分叉(见下一条),只冻其中一半等于白冻。
  - 换边**不加动画**:歌词换行本身是纯属性跳变,按钮排硬切才对得上;而且动画途中 `ControlRectsPreferenceKey` 会逐帧上报中间位置,控制器按矩形分发的点击会落在"飞到一半"的按钮上。
  - 控制器侧顺带把四处"这套手势整个用不上了"的悬停清零(锁定 / 窗口隐藏 / 卸监听器 / 关掉划过让开)收成一个 `clearControlsHoverState()` —— 这次加第三个悬停量时就得挨个改四处,漏一处会留下一份陈旧的 `true`。视图侧另有一道兜底:`isHoveringForControls` 一转 false 就解冻,不依赖那四处都写全。
- **对齐方式覆盖**(2026-08-29,采纳 [GitHub issue #2](https://github.com/Yudaotor/lyrimuse/issues/2);2026-08-31 起归到「排版」组,见「编辑台改造」第十三步):设置页新增「对齐方式」四选一(自动/居中/左对齐/右对齐)——issue 原话「歌词位置来回变化会影响阅读体验」,想要固定悬浮窗位置的用户可以放弃自动分声部。**只作用于悬浮窗**(`LyricsOverlayView`),不影响歌词窗口(第 07 章)——歌词窗口对无声部信息的兜底本来就是靠左(悬浮窗是居中),两者默认已经不一致,这次按 issue 与用户原话的范围不去动它。
  - **只改对齐方向不够**:如果非自动选项只改 VStack/文本的对齐方向,留着两侧内缩(见上)和声部指示圆点继续按真实声部算,文字块仍会因为留白量随声部切换而轻微漂移——issue 要的"始终保持在同一个位置"没有真正做到。所以非自动选项的语义是**当成一首没有对唱信息的普通歌来排版**(两侧内缩归零、指示圆点不出现,跟 `side == nil` 的既有行为逐像素一致),只是「排版居中」换成「排版靠选定的这一侧」;这对完全没有对唱标记的普通歌同样生效(issue 原文"所有歌词强制左对齐",不是"仅对唱歌"),等价于把旧的"永远居中"兜底换成"永远靠用户选的那一边"。
  - **两套 side 值分开算**,新增 `OverlayDuetAlignmentOverride`(`LyrimuseCore/Lyrics/OverlayDuetAlignmentOverride.swift`,纯函数、有 selftest)拆出两个语义:`effectiveAlignmentSide`(决定 `duetSide`/`nextLineDuetSide`——喂给 VStack 对齐/frame 锚点/文本对齐,自动模式原样 `?? .center` 兜底,非自动模式恒等于选定方向,不管真实声部是什么)和 `effectiveDecorationSide`(决定新增的 `duetDecorationSide`/`nextLineDecorationSide`——喂给两侧内缩 `duetInsets(for:)` 和声部指示圆点 `withSpeakerIndicator`/`speakerIndicatorInset`,自动模式原样传回真实声部,非自动模式恒为 `nil`)。⚠️ 不能只留一套值:非自动模式下把 `effectiveAlignmentSide` 的结果(`.leading`/`.trailing`)直接喂给指示圆点,会让完全没有对唱标记的普通歌也冒出一个圆点(圆点只按"是不是 `.center`"判断要不要显示,而非自动模式下每一行都被强制成非 `.center`)。`nextLinePreviewFont`(下一句预览是否放大字号提前"预告")也一并加了 `duetAlignmentOverride == .automatic` 前提——覆盖生效时位置已经锁死不会跳,原本"提前预告双重跳变"的理由不再成立,统一退回小字号。
  - (⚠️ 以下是 2026-08-31 之前的钉条 `OverlayPreviewBar` 的行为,该钉条已删除;现在这一段的预览是编辑台、画的是真视图,对唱声部按真实数据走。)悬浮窗设置页预览条(`OverlayPreviewBar`)不模拟对唱声部,所以"自动/居中/左对齐/右对齐"这四个选项本身在预览条上不会因为对唱切换而有差异;但**非自动的三个选项对预览条一样生效**(2026-08-29 用户反馈补上)——`OverlayPreviewBar` 新增 `previewAlignmentSide`(直接调 `OverlayDuetAlignmentOverride.effectiveAlignmentSide(realSide: nil)`,跟悬浮窗真实渲染路径同一个函数)算出方向,套在 `Group{ karaokeContent / 静态 Text }` 外层的 `.frame(maxWidth: .infinity, alignment:)` 上,让内容撑满预览条整宽再贴向选定的一边——此前这层 `.frame` 没有,内容只按自身宽度居中于 ZStack,选哪个选项预览条都看不出变化。
    ⚠️ 2026-08-30 补一刀(用户报"之前修好的这个预览框同步对齐模式的效果好像现在又没了"):8-29 那次只改了**外层**那个 `.frame`,而预览条有两条渲染路径 —— **正在播放**时走的是逐字分支 `karaokeContent → wordsRow`,那一层自己有 `.frame(maxWidth: overlayWidth - 40, alignment: .leading)`,**写死 leading**;它先把内容撑满整宽,外层再怎么对齐都拿到一个已经占满的块,于是表现成"没播歌时对齐生效、放着歌就失效",极易误判成功能回归。修法是把这一层的 alignment 也换成 `previewFrameAlignment`。教训:**同一个视觉属性有两条渲染路径时,改一条要顺手 grep 另一条**——真窗口 `LyricsOverlayView` 那边用的一直是动态的 `frameAlignment(for:)`,只有预览条这一处是写死的。
  - ⚠️⚠️ **这个 Picker 的宽度本身又是一个独立的、分三轮才修对的 bug(2026-08-29,用户反馈"这些配置的按钮点了之后会变大"),跟上面的渐变/裁切系列问题完全不相关,记录在这里防止以后又当成同一类问题去查。**
    - **第一轮误判**:以为是"选中的段文字更长,分段控件按当前选中段重新量宽度"——给每个选项的 `Text` 加 `.frame(minWidth:)`,截图坐实**完全没用**:macOS 的 `.pickerStyle(.segmented)` 桥接的是 `NSSegmentedControl`,它自己按当前选中段的文字重新量宽度,不读 SwiftUI 加在子视图上的 `.frame`。
    - **第二轮**:改成直接把整个 `Picker` 的宽度钉死——去掉制造"会变的理想宽度"的 `.fixedSize()`,换成 `.frame(minWidth: 300)`。这一步确实治好了"选中哪个选项决定宽度"(300 只要 ≥ 四个选项里最宽的那个状态,布局位置就不再跳),但用户随后指出真正在意的症状是另一件事:**首次进入这个页面时四个按钮比较小,一旦点击就会变大**,跟选中的是哪个选项无关——`frame(minWidth:)` 只保证外层布局这一格位置不跳,治不了控件自己内部渲染尺寸的这次跳变,方向完全找错了。
    - **真根因**(第三轮,跟本章"设计决策"另一处已修 bug 同源——`AccountLinkingTab.swift` 的 `lastfmSectionPicker`):这个 Picker 挂在"歌词显示"页里"悬浮歌词/灵动岛/菜单栏/其它"四个子页之间那个 `sectionPicker` 切出来的内容树上,而那个切换动作**包着 `withAnimation`**。分段控件是 AppKit 桥接过来的原生控件,这类控件在淡入过渡"还没拿到最终尺寸"的那一帧就先合成定型——之后任何交互(点击)逼着它重新走一次布局才会跳到真实尺寸,现象就是"刚进页面时小、点一下就变大"。`AccountLinkingTab` 那次是把整个切换动作从 `withAnimation` 里摘出来修的,但这里**不能照搬**——那样会连带改掉"悬浮歌词/灵动岛/菜单栏/其它"四个子页共用的切换动画手感,牵连太广,只为修一个分段控件的尺寸问题去动它不值得。改成只让这一个控件自己不参与外层过渡:`.transaction { $0.disablesAnimations = true }` 只对这一棵子树生效,不管外面的子 tab 是硬切还是带动画切换,它自己永远直接定型到最终尺寸。
    - 教训跟 `OverlayPreviewBar` 那次一样:**症状"看起来像什么"和"真根因在哪一层"可能完全对不上**——"点了才变大"第一眼最像"选中段决定宽度",实际是"页面切换动画截了一帧未定型的尺寸,点击只是恰好触发了一次重新布局"。

### 日文逐词注音(罗马音标在词底下)

- 引擎对"看着是日文"的逐字行产出 `wordGroups`(`LyricsSyncEngine.buildWordGroups`):整行一次性分词、按 UTF-16 范围把逐字词并成"共享同一段读音"的组;酷狗 LRC 自带的 `[kana:]` 假名标注(`KanaAnnotation.parse`)优先于形态分析器给读音(解决「明日」asu/ashita 这类多音词),对不齐时整份弃用、退回形态分析。
- 视图侧(`usesPerWordRomanization`):用户开了罗马音且这一行确实有 wordGroups 时,每组渲染成一列——上面是组内各字(各自逐字填色),下面是该组罗马音(按**整组**起止填色,不逐字跳);此时整行罗马音那一行不再重复显示。
- 中文歌不会被标成拼音(`buildWordGroups` guard japanese);关掉日文罗马音开关后逐词注音也一并消失。

### 罗马音/译文/下一句预览三行

- 顺序固定:主行 → 罗马音(0.65x 字号、前景色 60%)→ 译文(0.7x、75%)→ 下一句预览(0.7x、40%)。罗马音 2026-08-17 起在主行**下面**(音译惯例,与歌词窗口一致)。
- 罗马音来源:服务端 `lyrics_roma` 优先;整首都没有时客户端 Romanizer 现算兜底(按行缓存)。`romanizationScripts`(日/韩/中分语言开关,中文默认关)在服务端字段之前把关。
- 译文来自歌词源的中文翻译(700ms 容差最近邻贴行),默认开关跟随"用户读不读中文"。
- 下一句预览:引擎 `upcomingLineText`;播放位置还没到第一句时直接提前露出第一句真歌词。
- ⚠️ **下一句预览的对唱分栏独立于当前行算**(2026-08-26 修,用户报方大同/王诗安《All Night》副歌逐句男女交替,预览却总跟当前句同一边)。根因:`nextLineText` 只是纯文本,引擎本体 `nextTextAt`(现改名 `nextAt`)以前只取文字、不取那一行自己的 `side`,`LyricsOverlayView` 拿不到下一句自己的声部,只能借用当前行的 `duetSide`——对唱歌交替演唱时,下一句的演唱者往往不是当前这位。现在 `TickResolution` 多带一个 `nextSide`(跟 `nextText` 一路从 `wordSides`/`baseSides` 按同一个下标取出,不是猜的),经 `LocalPlaybackSource.nextLineSide`→`PlaybackCoordinator`→`OverlayPlayback` 原样传到视图;预览文字的 `.frame(maxWidth:.infinity, alignment:)`/`.multilineTextAlignment` 按自己的 `nextLineSide` 单独算,不再继承 `duetAlignment`。
- **下一句预览的字号与两侧内缩,2026-08-27 起也独立于当前行算**(用户反馈:对唱歌交替演唱时,下一句变成当前行那一刻会"跳一下"——位置和字号突然变化)。上一版(见上一条)只把**对齐方向**独立开,字号仍用缩小的 `previewFont`、两侧内缩(`duetInsets`)仍是整张卡片按**当前行**声部统一留白,当时的结论是"风险与收益不成正比"没有拆开。这次拆开:① `duetInsets` 从只认 `currentLine.side` 的计算属性改成参数化函数 `duetInsets(for:)`,下一句预览按自己的 `nextLineSide` 单独算出"它真正应该有的"内缩,再用两者之差(`nextLineInsetsDelta`)当**补偿 padding** 叠在预览这一行自己身上——外层卡片贡献当前行那份 insets,预览再补一份差值,加总起来正好等于预览独立按自己的 insets 摆放,不用碰卡片整体宽度/背景测量;② 预览字号在对唱歌(`nextLineSide != nil`)时改用跟当前行一样的 `mainFont`(非对唱歌仍用 `previewFont`,排版逐像素不变)——`duetInsetUnit` 本来就是按 `mainFont` 的字号算的,预览用回同一字号后两者天然匹配,不需要另算一套。效果:下一句预览现在会准确落在**它变成当前行时会用到的**那个位置和字号上,交替演唱时不再有位置+字号的跳变。
  - ⚠️ **同一天用户随后收紧了②这条判据**:第一版只看 `nextLineSide != nil`(下一句有没有声部信息),没有跟当前行的 side 比较——对唱歌里同一位演唱者连唱两句时,下一句 side 跟当前行相同、根本不会真的跳,却也被一并放大成了 `mainFont`。改成 `nextLinePreviewFont`:只有 `nextLineSide` 非 nil **且**跟 `currentLine?.side` 不同(下一句真的换了个人唱)才用 `mainFont`,同一位连唱、以及非对唱歌/前奏都照旧用 `previewFont`。①的 `nextLineInsetsDelta` 不需要跟着改——两句 side 相同时 `duetInsets(next)` 跟 `duetInsets(current)` 天然算出同一份值,delta 本来就是 0,这条判据已经隐含在里面了。

### 样式(字体/字号/颜色/描边/跟随封面)

- 字体族+主字号(14~36pt,默认 31)+**主行字重**只在设置变化时重算成缓存 Font(`AppSettings.recomputeFonts`),渲染路径不解析 hex/不查字体。空字体族名 = 跟随系统。
- **粗细(2026-09-02 加,`np:overlayFontWeight`,默认 `.bold`)**:用户选的是**主歌词行**那一档,其余三行按固定的**档位差**推导——罗马音 / 下一句细 2 档、译文细 3 档,细到头夹在最细档(`OverlayFontWeight.lighter(by:)`,`LyrimuseCore/Util/OverlayFontWeight.swift`)。
  - 阶梯六档:细 / 常规 / 稍粗 / 较粗 / 加粗 / 特粗 → AppKit 权重 4 / 5 / 6 / 8 / 9 / 10(`NSFontManager` 那套 0…15 整数刻度,**不是** `NSFont.Weight` 的浮点刻度)。刻度不等距,所以推导走**档位下标**而不是"权重减 N"。
  - ⚠️ **兼容性不变量**:默认档 `.bold` 推出来的四个权重必须逐个等于加这个设置之前那四个硬编码值(主 9 / 罗马音 6 / 译文 5 / 下一句 6)。破了它,所有老用户的悬浮歌词升级后当场变样、没有任何报错——selftest 有一组断言钉着,判据本体为此下沉进了 LyrimuseCore(selftest 只依赖那个 target,同 `ScrollForwardDecision`)。
  - **刻意不做成四行各自可调**:那是四个下拉的复杂度,换来的是"译文比主歌词还粗"这种没人想要、却要用界面去防的状态。档位差全为正 ⇒ 派生行**永远不会比主行粗**,这条也在 selftest 里(六档 × 三个差值全覆盖)。
  - ⚠️ **界面上这一行叫「粗细」,代码里叫 `overlayFontWeight` / `OverlayFontWeight`,这条不对称是有意的**。第一版界面文案写的是「字重」,当天被用户驳回(「这个命名为字重是不是不太合适啊」)——他提这个需求时自己的原话就是"控制字体粗细",用户已经说出口的那个词就是这一行该有的名字;「字重」是排版行话。同一次把档位名里的「中等 / 半粗」(medium / semibold 直译)也换成了「稍粗 / 较粗」,稍 / 较 / 加 / 特 这条程度副词阶梯自己就把顺序说清楚了。**英文不动**:Light/Regular/Medium/Semibold/Bold/Heavy 是任何字体选择器里的通用说法,那边行业术语才是对的。标识符保持 `*FontWeight` —— 它面向的是写代码的人。
  - 落点在编辑台工具栏「文字」浮层(和抽屉「文字」组),排在字体和字号**之间**——字重是"这个字体族的哪一个粗细",跟字体是同一件事的两半。菜单栏快捷面板**没有**这一项:那一栏是「各形态自己的旋钮」,只放连续量的滑杆(字号 / 宽度),字体本来也不在那儿。
- 前景色:`PlaybackCoordinator.displayForegroundColor`——「跟随封面」(`followsCoverArt`)开着且已算出封面强调色时用动态色,否则用手选固定色。动态色从封面均值色派生:描边开着且描边色 alpha≥0.5 时按"与描边色够对比"算,否则按"够亮"提升;封面过小时用 collector 缓存里的高清替代图均值。**只接管文字颜色**,背景色/描边色始终生效。
- 背景色:alpha > 0.02 才画(圆角 16 固定值);默认全透明,此时垫一层 `Color.black.opacity(0.001)` 保证拖拽手势能命中。
- **毛玻璃背景**(`overlayBackgroundGlass`,2026-09-02 加,默认关):开着时卡片底下垫一层系统材质 `.regularMaterial`(跟灵动岛「磨砂玻璃」同一种材质语言,但更薄一档——厚材质会把壁纸盖成灰板),用户的背景色叠在上面当**着色**:背景色全透明就是纯玻璃,alpha 越高越接近纯色卡片。关着时透明/纯色两种既有用法逐像素不变。「背景可见」的判定(`AppSettings.backgroundVisible`)变成「alpha > 0.02 **或**玻璃开着」,窗口阴影、拖拽捕获层、编辑台虚线边界三处联动自动跟上。材质在 `isOpaque=false` 的 NSPanel 里直接渲染,不需要 NSVisualEffectView;系统「减少透明度」开着时材质自动退成近乎不透明。编辑台预览渲染的就是真 `LyricsOverlayView`,底下铺着真实壁纸,所以预览里看到的模糊是真的。设置入口:「背景颜色」下的从属开关(`SettingsSubRow`,它改变的是背景颜色的含义,不是独立维度)。前景色的「跟随封面」取色管线未改:玻璃底下是模糊后的混合色,浅色壁纸配浅字可能不够清楚,先靠手选前景色或描边兜底。
- 文字描边:开关+颜色可调,粗细固定 1.2pt。实现是 blur+alphaThreshold 剪影垫底(`OptionalTextStroke`),整行套一次、开销不随描边粗细变化。逐字行的剪影 mask 用**静态副本**当 Canvas symbol(2026-08-19:`lyricsTextStroke(maskSource:)`,同排版纯色版 `karaokeLineContent(atMs: nil)`)——原来 symbol 是内容本身,填色渐变每 tick 一变整行就重跑 blur+threshold,而剪影只由文字/字体/换行决定,一行存续期内不变。历史上的 `.compositingGroup()` 已删除:它是给早已移除的每字阴影合并用的,当前树里只剩离屏渲染开销。⚠️ **剪影必须跟 content 吃同一道 `.padding(width*2)`**(2026-08-23 修):Canvas 是**居中**绘制剪影的,只有两者在 canvas 里占同一块矩形才逐点对齐。普通 Text 按自然宽度收缩、居中能补回来;但逐字行的 `WrapLayout` **撑满被提议的宽度** —— content 撑满 padding 内的宽度、剪影撑满 canvas 整宽,差正好一圈 padding。居中排版时两边各差一半抵消掉(所以非对唱歌看不出),一旦按 leading/trailing 靠边(对唱左右声部)就偏 2.4pt,而描边本身才 1.2pt,整圈甩到一侧。源码守卫在 collector 的 `strokemaskpadding_test.go`(纯 SwiftUI 布局行为,selftest 覆盖不了)。
- 配色主题:内置预设 + 用户自存主题(只打包文字/背景/描边四字段,不含字体字号);「恢复默认主题、文字与背景」重置九个字段(2026-09-02 加入毛玻璃开关)。
  ⚠️ **2026-09-03 改名 + 改副标题**(三形态设置审计发现):老那两句合起来**在说谎** —— 标题「恢复默认文字与配色」+ 副标题「不含宽度和锁定位置」会让人理解成"除这两样之外都恢复",而它实际只写 9 个字段,「排版」「行为」两个浮层里的 6 项(双行显示 / 对齐方式 / 长按拖动 / 悬浮淡化 / 截屏录屏时隐藏 / 暂停无播放时隐藏)一个都不碰。现在标题念**真正覆盖的那三个浮层**、副标题「不含排版、行为和宽度」念**没覆盖的**,两句合起来才是完整准确的作用范围声明。**功能本身没改** —— 排版和行为该不该纳入是产品取舍,不在那次修复范围里。两个入口(工具栏「重置 ▾」和抽屉里的 `resetRow`)必须一字不差。内置预设(`ColorTheme.builtInPresets`)现在是六款:经典白字/白字描边/经典黑字/黑字描边/深色卡片/浅色卡片——2026-08-26 去掉了"暖黄"/"赛博青"，换成"白字描边"/"黑字描边"(经典白字/黑字各自的加描边版本,前景/背景色不变,只是把描边开关打开,描边色沿用各自"手动打开描边时"本来就带的那个默认值,不是新配的颜色)。
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
  - ⚠️ **`windowLocalRect` 的 `windowHeight` 也不能直接读 `window.frame.height`**(2026-08-25 修的真 bug,跟上面那条同族但触发条件不同):用户报"没锁定时那四个播放控制按钮点了不生效,鼠标往下移一段距离才生效,不是每次都能重现"。根因是 `updateHeight()` 早先为解决"拖动卡顿"把 resize 从同步 `setFrame` 换成 `window.animator().setFrame(...)` 的异步 Core Animation(该函数自己的注释明写"动画途中读 `window.frame` 拿到的是中间帧"),但 `updateControlRects`/`updateControlsHotZone`/`updateLyricsHotZone` 这三处换算全都还在直接读 `window.frame.height`——只要内容变高(换行数变化、译文/罗马音/对唱开合都会让 `ContentHeightPreferenceKey` 和按钮/热区的 PreferenceKey 在同一次 SwiftUI 更新里一起重发)跟 `updateHeight` 的异步 resize 撞在同一拍,读到的就是动画开始前的**旧**高度,配上已经是**新**内容坐标的按钮矩形,拼出来的命中区在 y 方向整体偏移"新旧高度之差"——且没有任何东西会在动画结束后补一次(没有 `didResize` 观察者,`didMove` 又对程序性动画整段豁免),会一直错到下一次**无关的**内容变化重新触发那条 PreferenceKey 为止,正是用户说的"不是必现,点偏一点就好、过一会儿又正常"。修法:三处都改成读 `baseFrame(of: window).height`——跟 `updateHeight`/`setWidth` 算新 frame 时用的是同一个动画安全存取器(动画在飞时取它的**目标**高度,没有动画就是真实 frame),不会再读到中间帧。
  - ⚠️ **上面这个修法解决的是"动画途中"这一瞬间,没解决同一族更深一层的坑(2026-08-29 用户报"点击按钮正下方才生效,点按钮本身没反应",且不是偶发而是能稳定复现几分钟)**:`updateControlRects`/`updateControlsHotZone`/`updateLyricsHotZone` 只在 SwiftUI 那三条 PreferenceKey **重新上报原始坐标**时才会重新跑换算。播放控制排是顶边对齐、内容跟窗口高度无关的静态排布,它的 SwiftUI 坐标在窗口从默认 `overlayDefaultHeight`(120pt)撑到实际内容需要的高度(比如两行歌词要 138pt)之后**根本不会再变**——`.onPreferenceChange` 因此不会再重新触发,换算结果永久停在窗口刚建出来那一刻(还是 120pt)算出来的值上,跟"动画中间帧"完全无关,是"换算函数从此再也没被叫过"。诊断:临时在 `handleMouseEvent` 加 `.error` 级 `Logger`(⚠️ `.debug` 级别默认不落盘,`log show` 读不到,要 `.error`/`.default`/`.fault` 才行;另外这台机器的 zsh 下 `log` 是 shell builtin,要用绝对路径 `/usr/bin/log` 才能跑真正的诊断工具)记录每次点击的 `controlRectsLocal`/`baseFrameHeight`,实测偏移量精确等于 `138 − 120 = 18`,坐实。修法:三处换算前先把**原始**(未翻转)SwiftUI 坐标另存一份(`controlRectsRaw`/`controlsHotZoneRaw`/`lyricsHotZoneRaw`),统一收进新的 `recomputeHitRegions()`;`updateHeight` 每次真正改变窗口高度、调完 `setFrameAnimated`(这时 `animatingTargetFrame` 已经是新目标)之后额外主动调一次这个函数,不再干等 SwiftUI 偶然重新上报坐标才刷新。
- 拖动:武装之后合成 mouseDown 交给 `NSWindow.performDrag` 原生拖动(自算 delta 那条路实测卡顿)。怎么武装由 **`overlayDragNeedsLongPress`(「拖动前先长按」,默认关)** 决定:
  - **关(默认)**:按在**歌词文字**上(`lyricsHotZoneLocal`)立刻武装;歌词四周的空白照旧穿透。代价是压在字上的那一次点击会被窗口接住、穿不到下层。热区还没上报上来时退回长按,别让"按下就拖"覆盖整窗。
  - **开(旧行为)**:按住窗口区域 0.35s(期间移动 ≤4pt)才武装,期间点哪儿都能穿透;移动超容差判为"想操作下层 App 的普通手势",取消长按。
  - 长按这道门原本是**必须**的 —— 窗口常年点击穿透,"按下就拖"会让整个窗口区域吃掉点击。2026-08-23 精准歌词热区落地后这个前提变了:有了更准的判据,不必再用时长去区分"想拖窗口"和"想点桌面"。
- 首次解锁时窗口上短暂弹一句提示 4 秒,一台机器只弹一次(`np:hasShownOverlayDragHint`);文案跟着「拖动前先长按」变(开=「长按即可拖动位置」/关=「按住歌词即可拖动位置」)。
- 悬停控制排:解锁+悬停在窗口范围内时,歌词卡片**上方**露出深色胶囊——上一首/播放暂停/下一首、「喜欢」心形(仅实际在播 Apple Music 且有自动化权限时出现;悬停露出时会回读一次真实状态)、竖线、**展开到歌词窗口/设置/锁定/关闭**(2026-08-29 后三项旁边新加的两个,见下;⚠️ 2026-08-31 用户要求把**锁定和设置对调**,原来是「展开/锁定/设置/关闭」照抄 QQ 音乐参考图的顺序。新顺序也更站得住:锁定是这一排里唯一**点完整排就消失**的按钮——`lockPosition` 一变真,`controlsShown` 的条件不再成立,整条胶囊换成 unlockPill——把它挪到紧挨关闭键的位置,两个「用完这排就没了」的操作凑在一起,而设置(弹菜单)和展开(开新窗)这两个「点完排还在」的留在前面。命中区不用跟着改:每个按钮用 `GeometryReader` 按自己的 `OverlayControlID` 上报矩形,换渲染顺序会自动跟随,没有第二处硬编码的顺序表)。播放控制按钮点击时才校验自动化权限,被拒 `NSSound.beep()`。按钮槽位常驻(隐藏时透明)以保证悬停时歌词不跳动。
- **控制胶囊材质:液态玻璃 + 纯色兜底(2026-08-29)**:先出了简约/液态玻璃/磨砂材质/分组胶囊四套视觉方案给用户选,拍板"2+1"——有液态玻璃的系统(macOS 26+)用液态玻璃,没有就退回方案一(打磨过的纯色深底胶囊)。新增 `View.overlayCapsuleBackground()`(`LyricsOverlayView.swift` 底部的 extension),`playbackControls`/`unlockPill` 共用同一份实现,跟 `SettingsDesignSystem.swift` 的 `settingsCardBackground` 同一个 `#available(macOS 26.0, *)` 取舍。液态玻璃用 `.glassEffect(.regular.tint(.black.opacity(0.32)), in: Capsule())`——调深色调是因为胶囊里的图标固定白色,不像设置页卡片那样可以让系统默认的浅色玻璃质感决定明暗,不调深亮壁纸背景下图标会读不清;不用 `.interactive()`,这扇窗口常年 `ignoresMouseEvents`,交互态玻璃的悬停/按压响应永远没有真实指针事件可以触发。两个分支都补一条发丝描边(理由同 `settingsCardBackground`,而且更必要——这个胶囊背后是任意桌面壁纸,比设置页卡片背后固定的系统背景变化大得多)。纯色兜底分支顺带打磨:胶囊变窄(左右内边距 18→15、图标间距 18→15)、分隔线更柔和(不透明度 0.25→0.18)。
  - **进一步收到最小(2026-08-29 同一天用户反馈"整体按钮太大,挡桌面")**:图标从 26/30pt(非主/主按钮)收到 19/22pt,字号 13/15→10.5/12;`playbackControls` 的 `HStack` 间距 15→5,水平内边距 15→9,竖向 7→4;分隔线高度 16→12;`unlockPill` 同步收(图标 12→10、文字 13→11、内边距对齐)。鼠标操作不需要触摸尺寸的容错,19pt 的点击矩形仍然点得准,这排常驻按钮"露出来就占桌面视觉"是它的天然代价,尽量小是这一排的设计前提。
- **参考 QQ 音乐悬浮歌词补的三个按钮(2026-08-29)**:「展开到歌词窗口」(⤢,直接调 `AppActions.shared.openLyricsWindow?()`,跟 Dock 菜单/菜单栏/全局快捷键同一个入口)、「设置」(⚙,弹出 `OverlayQuickSettingsMenu`,见下)、「关闭」(✕,调 `LyricsOverlayWindowController.setVisible(false)`——等同于设置页把"桌面悬浮歌词"整个关掉,不是"这次先隐藏一下",要从设置页/菜单栏/全局快捷键重新打开)。刻意**没有**加 QQ 音乐那颗🌐翻译切换按钮(用户没选)。
- **锁定态解锁提示(2026-08-29)**:此前锁定后 hover 整排按钮(包括锁定按钮本身)直接消失,想解锁必须记得去设置页找那个开关,悬浮窗本身没有出路。改成锁定时 hover 会露出一个解锁提示(复用控制胶囊同款半透明黑底样式),点它直接解锁。**提示跟播放控制排共用同一个槙位**(body 的 `VStack` 顶部那一格,不叠在歌词上面——第一版做成叠在歌词中间的居中 overlay,用户反馈"不要显示在歌词中间,也放在上面"改成跟播放控制排位置一致):锁定时这个槙位渲染 `unlockPill`、未锁定时渲染 `playbackControls`,竖向内边距特意跟 `playbackControls` 对齐,锁定/解锁切换时下面的歌词不会跳。矩形上报走跟播放按钮完全同一条 `ControlRectsPreferenceKey` 管线,不新增 PreferenceKey——`LyricsOverlayWindowController.handleMouseEvent` 顶部"锁定时整套手势停用"那道守卫单独放行"`.leftMouseDown` 命中这个提示"的情形,其它锁定行为(拖动、播放控制)不受影响。
  - **2026-08-31 从"🔒+「解锁」文字的胶囊"改成纯图标**(用户实机反馈"直接把这个解锁按钮
    搞小一点,和正常没锁定的那些放在同一个位置、同一个大小")。之前手写 `HStack` + `Text`
    自己拼一套尺寸,凑高度凑得再准(见下面那条"两态高度对不齐"的坑)也仍然是**两套独立
    拼出来的样式**,用户实机对比还是看得出不一样。改成直接调
    `iconButton(.unlockPill, "lock.fill", primary: true)`——跟 `playbackControls` 里
    其它按钮**同一个构造函数**,自带同一套 22pt/19pt 尺寸表、同一条
    `ControlRectsPreferenceKey` 矩形上报,外层套的胶囊内边距(`.padding(.horizontal, 9)
    .padding(.vertical, 4)`)也跟 `playbackControls` 逐字一致——保证的不是"数字算出来
    一样",是"用的是同一份代码",两个状态之间不会再有肉眼可辨的差异。图标用 `lock.fill`
    (锁着的锁),跟未锁定时 `iconButton(.lock, "lock.open.fill")`(开着的锁)对称:
    开锁图标 = 点了会锁上,锁着图标 = 点了会解锁,跟这一排其它图标(展开/设置/关闭)
    一样不带文字,`.frame(height: 22)` 那次"手动凑高度"的修法和「解锁」文字/本地化键
    (`np:` 前缀不涉及,纯 UI 字符串)一起删掉,不再需要。
  - ⚠️ **已修的真 bug:提示第一版压根不会出现,不是视觉/位置问题,是鼠标监听器整个没装。** `syncMouseMonitors()` 原来的判据是 `!isPositionLocked || overlayFadeOnHover`——锁定时如果用户没开"划过让开",全局/本地鼠标监听器会被 `removeMouseMonitors()` 整个卸掉(省电,理由是"锁定时这套手势整个用不上"),`handleMouseEvent` 从此再也不会被调用,`isHoveringForControls` 永远停在装/卸那一刻的值上,不会跟着鼠标真实移动更新——解锁提示的显示条件 `isHoveringForControls && lockPosition` 因此永远算不出 `true`。改法是把这个判据简化成只看 `window?.isVisible`:悬停追踪原来是"锁定态下可选(仅服务划过让开)",解锁提示上线之后变成"锁定态下也必需",不能再按 fadeOnHover 这个跟解锁提示完全无关的开关去决定装不装监听器。
  - ⚠️ **另一个已修的真 bug(2026-08-31,用户实机自己排查出根因):锁定/解锁切换时,内容看起来"整体挪动了一点"**。表象是解锁提示的位置跟悬浮窗看起来的边界贴得很近/重叠。根因跟视觉/位置本身都无关,是**两个槙位内容的实际高度没真的对齐**——上面那条"竖向内边距对齐"的注释只保证了 padding 数字相同,没保证内容区本身一样高:`playbackControls` 的高度由主按钮图标的显式 `.frame(width: 22, height: 22)` 撑出来,胶囊总高 = 22+4+4 = 30pt;`unlockPill` 的"锁"图标(10pt 字号)+"解锁"文字(11pt 字号)天生行高只有 ~14pt,同样加 4+4 的竖向内边距,胶囊总高只有 ~22pt——两边差了约 8pt。这个差值原样反映到 `updateHeight` 汇报的窗口总高度上:窗口顶边固定、高度一变,锁定/解锁切换时视觉上就像内容整体往上/下挪动了一点。修法(当时):给 `unlockPill` 的内容区加一句显式 `.frame(height: 22)`,跟主按钮图标钉死同一个高度,不再指望"凑 padding 数字碰巧凑出同一个总高度"——两个状态的胶囊高度从此位对位相等,窗口总高度不会因为锁定/解锁而改变一分。⚠️ **这个 `.frame(height: 22)` 手动凑高度的修法本身已经被下面"改成纯图标"那次改动取代**——直接复用 `iconButton(primary: true)` 天然就是 22pt,连"凑"这一步都不需要了,两态高度相等这个不变量现在是靠"用同一份代码"结构性保证的,不是靠数字对齐。
  - **跟这条不是同一个坑,是同一次反馈里另一个独立问题:这个槙位常年贴着窗口内容区
    顶边、零间距**(2026-08-31 用户最初的反馈"解锁的按钮和窗口的边框完全重叠了"——
    上面高度对齐修的是"切换时会挪动",这条修的是"不管切不切换,常年都贴着边")。
    `VStack(spacing: 0)` 顶端这个槙位(播放控制排/解锁提示共用)原来没有任何顶部
    留白,锁定态下"🔒 解锁"这颗孤立的小胶囊尤其明显。修法:在 `Group`(两个分支的
    **外面**,不是只加给 `unlockPill` 自己)上补一句 `.padding(.top, 4)`——两个状态
    都一起往下挪 4pt,不会重新破坏刚修好的"两态高度相等"这条不变量。
- **⚙ 弹出的快捷设置菜单(`OverlayQuickSettingsMenu.swift`,2026-08-29)**:真正的 `NSMenu`,不是自绘圆角气泡——这扇窗口点击穿透+自定义矩形分发的架构不支持弹出能接收自己事件的浮层,`NSMenu` 完全独立于父窗口的 `ignoresMouseEvents`,弹出/子菜单/勾选态全部是 AppKit 免费给的。写法照抄仓库里已有的两处 `NSMenu` 范本(`MenuBar/DockMenu.swift`、`MenuBar/MenuBarStatusMenu.swift`):纯 target/action、每次弹出前 `menuNeedsUpdate` 整棵重建、`autoenablesItems = false`。内容六项:简繁转换(三态子菜单,不是参考图看起来的单行——lyrimuse 是三态,放不进一个可勾选行)、双行歌词(勾选行)、更改配色(子菜单:跟随封面 + 6 个内置主题 + 自定义主题,内容跟设置页那个 Menu 一致,套用逻辑提到 `ColorTheme.apply(to:)` 两处共用)、歌词进度(子菜单:提前/延后/重置,跟 `MenuBarStatusMenu` 的"歌词时间轴"子菜单同一套 `PlaybackCoordinator.nudgeLyricsOffset(by:)`/`.resetLyricsOffset()` 动作,标题直接带当前校准值)、**搜索歌词…**(2026-08-30,用户要求"点击即唤出歌词搜索页面,可以快速手动搜索";用户特意确认过"只需要弹出搜索歌词页面,不需要把歌词窗口也拉起"——第一版做成了"叫出歌词窗口再让它自己弹面板",被这句话纠正,见下面「搜索歌词…独立小窗」)、更多设置(跳到设置页"悬浮歌词"子段,照抄 `MenuBarPanelQuickSettings.swift`「全部设置…」那三行:写 `LyricsSurface.appearanceSectionStorageKey` → `AppActions.requestSettings(.tab(.appearance))` → `openSettings?()`)。`NSMenu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)` 直接在鼠标当前位置弹出,不用做 SwiftUI→AppKit 坐标转换。

  ⚠️ **「简繁转换」不是恒定项(2026-08-31)**:按 `LocalPlaybackSource.currentLyricsSupportsChineseVariant` 逐曲显隐,判据是共享的 `ChineseVariant.affects`——**跟 `converted(_:)` 自己的早退是同一个函数**,所以「菜单显示 ⟺ 转换真的会发生」。刻意**没有**用 `Romanizer.songScript` 判「是不是中文歌」:它把「含谚文」排在「含汉字」之前,韩文歌里的汉字会被判成 `.korean`,而 `converted(_:)` 并没有谚文守卫、照转不误——按 songScript 藏菜单就成了「正在转换、开关却不见了」,正是 `SettingsView` 那条「只要它还在起作用,就一定看得见」要防的最坏状态(selftest 有一条用韩文+简体汉字的用例钉住)。反方向也不行:`looksJapaneseSong` 按行占比判、`converted` 按有无假名判,只有 3/75 行带假名的中文歌会出现「菜单在、点了没反应」。设置页那一项**不受影响**,仍按粘性的 `sawChineseLyrics` 露出——一个持久设置列表里的项不该因为换首歌就消失(见 `LocalPlaybackSource` 该字段注释)。

  ⚠️ **2026-09-02 收紧:译文那一支要乘上「译文正在显示」**。老判据是无条件的 `affects(正文) || affects(译文)`,当时的理由写的是"译文同样过 `variant.converted`,所以日文歌配中文译文也必须让开关留在那儿"——那句话本身没错,漏的是一层:**译文没在屏幕上时,把它转成繁体是一次看不见的改动**,菜单项就成了点了没有任何视觉反馈的死项。用户报的真实一首是米津玄师《Petrichor》:正文纯日文(带假名,`affects` 正确地判 false),但 enrich 缓存里带一份中文机翻 `lyrics_tr`(`lyrics_tr_source: machine`),译文那一支把菜单点亮了 ——「播日文歌为什么也显示简繁转换」。所以不变量升级成 **「菜单显示 ⟺ 转换真的会发生、而且看得见」**,判据抽成纯函数 `LocalPlaybackSource.supportsChineseVariant(lyrics:translation:translationVisible:)` 让 selftest 直接钉住(11 条,含"判据为真 ⟺ 屏幕上真的有东西会变"的兜底对拍)。配套:Core 新增 `LocalPlaybackSource.showsTranslation` 镜像 `AppSettings.showTranslation`,由 `AppDelegate` **订阅**(不是像 `chineseVariant`/`romanizationScripts` 那样启动时赋一次)——这个开关有三个写入点(设置页、歌词窗口「⋯」菜单、全局快捷键),双写漏掉任何一个都会让判据停在旧值;`@Published` 订阅时先发一次当前值,启动那一次也一并覆盖。它**不进** `LyricsReloadSnapshot`:译文转不转由 `chineseVariant` 决定、跟它无关,所以翻转时正好只更新标志、被内容等值闸挡在整段解析之外。

  ⚠️ **「更改配色」子菜单:跟随封面开着时主题照常列出,但一个都不打勾(2026-09-02,跟设置页取齐)**。这一档来回改过三次,三次的取舍都记在这里,免得被转回去:

  1. **最初**:主题照常列出、按颜色字段打勾。**用户报的 bug** —— 跟随封面开着时四个颜色字段仍然等于某个主题,于是「跟随封面 ✓」和「黑字描边 ✓」**同时打勾**,读起来是两个互相矛盾的「正在生效」。(中间试过用 AppKit 的第三态 `.mixed` 渲染成短横表示「这是备用色、没在生效」,用户否掉了。)
  2. **2026-08-31**:整段主题列表干脆不展示(用户拍板)。矛盾修掉了,代价是从跟随封面切到某个固定主题要**两步**(先取消跟随封面,再打开菜单选)。
  3. **2026-09-02(现状)**:用户原话「勾选了跟随封面之后依然可以选择主题,但是你去选了主题之后跟随封面就自动取消勾选」。列表回来了,**第 1 条那个矛盾靠「不打勾」消除** —— 矛盾的来源是给一个「没在生效」的主题**打勾**,不是把它**列出来**。跟随封面开着时整段列表无勾选 = 「现在生效的只有跟随封面」,点任意一个主题会走 `ColorTheme.apply(to:)` 把跟随封面关掉、那套主题当场生效并打上勾,一步到位。⚠️ 不打勾**只在跟随封面开着时**;关着时照常按颜色字段打勾——那才是「现在生效的是哪套」。

  `ColorTheme.apply(to:)` 里那句 `followsCoverArt = false` 是这三档共同的地基 —— 它一直都在,正是它让「选了主题就自动取消跟随封面」这条成立,第 3 档只是把界面对齐到这个既有行为上。
- **搜索歌词…独立小窗(2026-08-30)**:没曲目在播时不给这一项(条件跟 `LyricsWindowView` 的「⋯」菜单同一条 `!playback.title.isEmpty`)。点击**不**走「展开到歌词窗口」那个入口,也不复用 `LyricsWindowView.openLyricsSearch()` 那套"歌词窗口开着才挂得上"的 `.sheet(item:)`——用户明确要求点了只弹搜索页面本身。改成 `LyricsSearchSheet` 直接当一扇独立 `Window(id: "lyrics-quick-search")` 的根内容(`LyricsQuickSearchWindow.swift`,见 07 章「搜索歌词…」),不套 `.sheet()`:`LyricsSearchSheet` 内部"关闭"/"采用此候选"两个按钮走的 `@Environment(\.dismiss)`,对 `Window` 场景的根内容一样能把整扇窗口关掉,不需要额外接一层。窗口的开法跟 `openLyricsManager`/`openLyricsWindow`/`openOnboarding` 同一个模子:新增 `AppActions.openLyricsQuickSearch`,在 `MenuBarSceneActions.swift` 的锚点视图里捕获 `openWindow(id:)` 这个 SwiftUI 环境 action。曲目快照(resolvedKey 精确→宽松两级,缺条目退 normalizedKey)在窗口自己的 `.task` 里现查一次,直接跑在 MainActor(不像 `LyricsWindowView` 那边特意 `Task.detached`——那扇窗口有 60fps 逐字填色,这扇只在打开这一瞬间读一次缓存,没必要多绕一层线程切换)。⚠️ **2026-08-31 真实bug修复**:`.task` 只在这扇窗口**首次挂载**时跑一遍——窗口没被真的关掉(切到后台/被挡住)时再点一次「搜索歌词…」,只是把已存在的视图带到前台,`.task` 不重跑,曲目快照停在第一次打开时那首歌,用户报"已经切歌了,点开搜索页面看到的还是上一首"。补了 `AppActions.quickSearchRefreshRequests`(`PassthroughSubject<Void, Never>`,跟设置窗口那个 `selectionRequests` 同一个套路),`openLyricsQuickSearch` 每次调用都往里 send,`LyricsQuickSearchWindow` 额外 `.onReceive` 它重新现查一次——`.task` 管"窗口还没建出来",`.onReceive` 管"窗口已经开着",两条路合起来才是"点这个按钮一定看到当前这首歌"。⚠️ **2026-09-02 第二次真实bug修复(由上一条引出)**:`.onReceive` 只替换了 `context`,而 `if let context { LyricsSearchSheet(...) }` 从 Optional(A) 到 Optional(B) 是同一个 SwiftUI 视图身份——面板的查询词 `@State` 与只跑首次的 `.task` 都不重置,界面仍是上一首的查询词与候选(「恢复原信息」凭空出现是可见征兆),但 `onApply` 捕获的已是新 `context.key`,采纳会把上一首的歌词写进当前这首的条目(lyrics/ 文件族随之落盘,开了「采纳即锁定」还会冻结)。修在 `LyricsSearchSheet` 内部:三个原始字段拼成 `searchSubject`,`.task(id: searchSubject)` 重搜、`.onChange(of: searchSubject)` 把查询词重置回原始值;另外两个入口的原始字段在面板存活期间不变,行为等同原来的 `.task {}`。**刻意不用**宿主层 `.id(context.key)` 整棵重建:离屏 `NSHostingView` 探针实测重建时新面板的 `.task` 先起、旧面板的任务取消与 `onDisappear` 后到,两者都调全局 `LyricsSearchService.cancelRunning()`(杀「当前在跑的那个」),新起的 collector 子进程 3/3 被旧面板收尾杀掉;`.task(id:)` 由 SwiftUI 保证先取消旧任务再起新任务,同一探针下新搜索每次都跑完。

### 隐藏行为(全部只对悬浮歌词生效)

| 行为 | 机制 | 与灵动岛的关系 |
|---|---|---|
| 手动显示/隐藏 | `setVisible` 写 `classicOverlayEnabled`,窗口 orderFront/orderOut | 各自独立开关 |
| 暂停/无播放时隐藏 | `hideWhenNotPlaying`;实际可见 = 手动开 AND (未开自动隐藏 OR 正在播)。跟的是 `isPlayingSmoothed`(停止侧带 0.25s 宽限——2026-09-02 从 0.5s 砍半,吸收换歌/seek 抖动;恢复播放立即响应),恢复播放自动重新显示,不改手动开关本身 | ⚠️ **2026-09-01 起不再与灵动岛共享**:那天用户要求把「自动隐藏」卡从「其它」段搬进两个形态各自的页面,一旦按形态分栏展示、用户就会按形态去理解它,于是连值一起拆开。这个键**只归悬浮歌词**,灵动岛那份是 `notchHideWhenNotPlaying`。⚠️ 2026-09-02 落点又变了一次:那张独立的「自动隐藏」卡整个撤掉,两行并进本段的「行为」入口与抽屉「窗口」组,真源 `UI/AutoHideSettingsRows.swift`(同日晚些时候「行为」本身又从常驻卡改成了编辑台工具栏浮层,见第十六步)——**只是宿主变了,值仍是两份** |
| 截屏/录屏时隐藏 | `hideDuringScreenCapture` → `window.sharingType = .none`:截图/录屏/会议共享拍不到,用户自己仍看得见 | 同上,只归悬浮歌词;灵动岛那份是 `notchHideDuringScreenCapture` |
| 拖动前先长按(2026-08-23) | `overlayDragNeedsLongPress`,默认**关**;关=按住歌词直接拖(靠精准歌词热区,四周空白仍穿透)、开=旧的长按 0.35s。见上面「拖动」那条 | 只对悬浮歌词生效 |
| 指针划过时让开(2026-08-22) | `overlayFadeOnHover`;在 `LyricsOverlayView` 顶层挂 `.opacity`(淡到 15%,**不是** orderOut——那会跟上面三个真正的可见性来源抢同一个开关)。淡入 0.18s 比淡出 0.12s 慢:扫过去要立刻让开才有用,回来从容点更好。判据是 `isHoveringLyrics`(**指针压在歌词文字上**),不是 `isHoveringForControls`(整窗)——见下面「歌词命中判定」 | **只对悬浮歌词生效**;灵动岛贴刘海、hover 是它展开的手势,让开会跟展开打架 |

`setVisible(true)` 时会把三个已配置偏好(capture-hide / pause-hide / lockPosition)重新应用一遍,保证从菜单栏/快捷键打开时状态与持久化一致;App 启动时 AppDelegate 只在 `classicOverlayEnabled` 为真时才触碰控制器单例做同样的应用(避免凭空构造窗口)。

## 设置项

全部在「设置 → 外观」,除注明外均在「悬浮歌词」段:

| 设置项 | 改什么行为 |
|---|---|
| 桌面悬浮歌词(总开关) | 窗口显示/隐藏(`classicOverlayEnabled`);配置项不跟开关联动,关着也能预先调。2026-08-30 起它常驻在编辑台正下方、**不进**「全部设置」抽屉 |
| 跟随封面(本段「文字」组) | 前景色改用封面动态强调色;**同时被灵动岛整套 UI 读走**(见交互节)。⚠️ 标题原为「文字跟随封面」,2026-08-26 应用户要求去掉「文字」二字缩短——**跟灵动岛「风格」选项里的「跟随封面」(`NotchCardStyle.coverArt`,卡片背景样式,见第 05 章)字面撞名**,是两个不同的设置(这个管前景色,那个管卡片背景),同名纯属巧合,靠各自所在的卡片/分组区分 |
| 配色主题(本段「主题」组) | 一键套一整套四字段配色(文字/背景/描边色 + 描边开关,不含字体字号)。⚠️ **2026-09-02 起任何时候都显示**,不再被跟随封面收起 —— 选一个主题本来就会把跟随封面关掉(`ColorTheme.apply(to:)` 第一行),藏起来只会把一步的操作变成两步。⚠️ **跟随封面开着时当前值显示占位符「—」**(工具栏「主题」按钮的摘要用的是同一个字符串,判据只在 `currentThemeLabel` 一处):那一刻没有任何一套主题真的在生效,报具体主题名等于说"现在是黑字描边"而屏幕上并不是。跟快捷菜单「一个勾都不打」同一条逻辑 |
| 文字颜色(本段「文字」组) | 固定前景色;跟随封面开着时这一行收起。**禁透明** —— alpha 拖到 0 会让整扇窗消失且界面上没有任何线索能定位问题 |
| 背景颜色(本段「背景」组) | 卡片背景(含 alpha,全透明=无背景) |
| 毛玻璃背景(本段「背景」组,从属子行) | 背景颜色的从属开关(默认关):开着时卡片底下垫系统材质、背景颜色变成玻璃着色 |
| 文字描边 + 描边颜色(本段「文字」组) | 开关与颜色;粗细固定 1.2pt 不可调 |
| 我的配色主题(本段「主题」组) | 存/套用/删除自定义四字段配色 |
| 字体 / 字号 | 主行字体族与字号;罗马音/译文/预览按 0.65x/0.7x 派生 |
| 粗细(2026-09-02) | 主行字重六档(细→特粗,默认加粗);罗马音/预览细 2 档、译文细 3 档,夹在最细档。见上面「样式」那一节的兼容性不变量 |
| 宽度 | 窗口宽度 300~1400pt(`OverlayEditorStage.widthRange`,跨编辑台/抽屉/菜单栏面板三处的唯一真源)。编辑台里的画布跟手实时变,**真窗口是松手那一下**才跟上(拖动中只改本地 `@State`,见第六步与第十四步) |
| 锁定位置 | 停用悬停控制排与长按拖动。2026-09-02 起在编辑台工具栏第二行的「行为」浮层里(抽屉「窗口」组里也有一份;2026-08-30〜09-02 之间它在编辑台下方那条「行为」栏的第 1 格),打开时编辑台画布左下角出现锁标 |
| 指针划过时让开 | `overlayFadeOnHover`;指针压在**歌词文字**上时整窗淡到 15%,离开恢复。只对悬浮歌词生效。2026-09-02 起在「行为」浮层里(2026-08-30〜09-02 是「行为」栏第 3 格;第三步曾在旁边配一颗「预演」按钮,第十步按用户要求删了) |
| 恢复默认主题、文字与背景 | 重置跟随封面 + 字体/字号/**字重** + 四个颜色字段 + 毛玻璃,共 9 项;**不含**「排版」「行为」两个浮层里的 6 项和宽度(2026-09-03 改名,见下) |
| 截屏/录屏时隐藏(本段「行为」浮层 / 抽屉「窗口」组) | `hideDuringScreenCapture` → `sharingType = .none`;**只对悬浮歌词生效**(2026-09-01 拆值、2026-09-02 从独立卡并进「行为」,同日「行为」又整体进了编辑台工具栏浮层) |
| 暂停/无播放时隐藏(本段「行为」浮层 / 抽屉「窗口」组) | 自动隐藏;**只对悬浮歌词生效** |
| 显示罗马音 / 罗马音语言(「歌词」页) | 罗马音行与逐词注音的显隐、按语言过滤 |
| 显示译文(「歌词」页) | 译文行显隐 |
| 双行显示下一句(「歌词显示 → 悬浮歌词 → 排版」组) | 预览行显隐。⚠️ 副标题「在当前句下方多显示一句」2026-08-30(第十二步)按用户要求删了,只剩标题。2026-08-31(第十三步)从「文字」组挪到「排版」组 |
| 对齐方式(「歌词显示 → 悬浮歌词 → 排版」组,2026-08-29) | `overlayDuetAlignmentOverride`;自动=按对唱声部切换(默认),居中/左/右对齐=强制固定方向+关闭两侧内缩与声部指示圆点。2026-08-31(第十三步)从「文字」组的**子行**升成「排版」组的平级行 |
| 快捷键页:显示/隐藏悬浮歌词、锁定/解锁位置 | 全局快捷键,默认未录制 |

## 与其它功能的交互

- **数据源链**:显示内容全部来自 `PlaybackCoordinator`(单例),它转发 `LocalPlaybackSource`——2 秒轮询 media-control 拿播放快照,20Hz `fastTick` 用 `ProgressAnchor` 外推位置定"当前行";歌词正文来自 collector 的 enrich 缓存(`EnrichCacheReader.lookup`)。「搜索歌词中/暂无歌词/纯音乐/网络连接失败」四个占位状态分别对应 collector 侧的解析进度/`resolved`/`instrumental`/网络状态。悬浮窗视图**不整对象订阅**这两个单例——经 `OverlayPlayback` 窄代理只订阅它实读的二十来个字段(2026-08-19,LiveRowPlayback 同款模式),歌词窗口音量滑杆/灵动岛封面这类无关高频写入不再打醒它的 body;`anchor`/`currentLyricsOffsetMs` 由 TimelineView 闭包直读协调器,不入订阅。
- **歌词处理管线共享**:署名行过滤(`strippingCreditLines`)、简繁转换(`lyricsChineseVariant`)、逐字/整行选择(`preferWordLevelKaraoke` + 覆盖率判据)都在引擎/数据源层完成,悬浮窗、灵动岛、歌词窗口、菜单栏看到的是同一份结果。署名行过滤直接影响悬浮窗动态高度(漏判的长职员表行曾把窗口撑爆)。
- **与灵动岛**:开关互相独立可同开;共享 `WordKaraokeGradient`(30Hz 上限+渐变算法);**`hideWhenNotPlaying` / `hideDuringScreenCapture` 2026-09-01 起不再共享**(拆成了两份,灵动岛那份叫 `notchHide*`,见 05-notch.md 设置项表里「工具栏「行为」浮层」那两条)。⚠️ 2026-09-02 起两个形态**共用同一份视图** `UI/AutoHideSettingsRows.swift`(靠 `AutoHideSurface` 分流)——共用的是渲染和文案,**不是值**,别把"共用组件"读回"共用设置";「跟随封面」(`followsCoverArt`)开关也被灵动岛读走(NotchLyricsView.accentOrWhite),但两边用的强调色变体不同(悬浮窗按"与描边对比/够亮",灵动岛按"深底够亮")。
- **与歌词窗口**:共享 `showRomanization/showTranslation/showNextLinePreview` 三个开关、`WrapLayout`、`KaraokeFill`、LyricDuet;但字体/字重/字号/三个颜色**只**对悬浮窗生效,歌词窗口用固定系统配色;对唱 nil 兜底两边不同(悬浮窗居中、窗口靠左)。
- **与歌词时间轴校正**:`LyricsOffsetStore` 的基准(全部 / 按播放器,二选一)+ 单曲微调合成 `currentLyricsOffsetMs`,同时作用于"当前行判定"(引擎内)和"逐字填色基准"(视图内显式相加)。
- **与设置页预览**(⚠️ 下面这一整条描述的是 2026-08-31 之前的钉条 `OverlayPreviewBar`,它连同那份渲染已经删除;编辑台从第八步起画的就是真 `LyricsOverlayView`,不再有第二份渲染。留档是因为「第二份渲染必然漂」这条教训值钱):`OverlayPreviewBar` 曾是刻意维护的第二份渲染实现,复用 `settings.mainFont`/`backgroundColor`/`displayForegroundColor` 规则和 `lyricsTextStroke`(为此放开成 internal)。**逐字填色也复用**(2026-08-26 用户要求,原来这里不复制)——真在播放且当前行有逐字数据时,用同一套 `WordKaraokeGradient`/`KaraokeFill` 算法、同一个播放位置来源(`PlaybackCoordinator.anchor`/`pausedPositionMs`/`currentLyricsOffsetMs`)按真实进度逐字填色,`karaokeContent`/`wordText` 是 `LyricsOverlayView.mainLine`/`wordText` 的镜像写法;没在播放或这一行没有逐字数据时退回原来"整行最终颜色"的静态样子。仍不复制的是逐字行的自动换行(`WrapLayout`,预览高度固定、长行只裁切)和罗马音/译文行;圆角 16 是手抄的常量,改视图记得改预览。
  - ⚠️⚠️ **已修(2026-08-29 用户反馈"描边渲染有问题",连续三轮才修对,记录完整过程免得以后又踩同一个坑)。**
    - **第一轮症状:长行截出一大片乱码**("You ne…kn…your limit wh…the pas…dri…you")。根因:逐字填色路径是"每个词一个 `Text`"拼成的 `HStack`(渐变要按词分别上色,不能一整行共用一个 `Text`),原来在这个 `HStack` 上套了 `.lineLimit(1)`——这个修饰符会往下传给**每一个**子 `Text`,装不下时各自截断出一个"…",相邻词之间又没有空格(`HStack spacing: 0`),碎片连在一起就是那种大片乱码。**误诊**:第一版只去掉了 `.lineLimit(1)`,以为交给外层 `preview` 的 `.clipShape` 硬裁就够了——治标不治本,马上暴露第二轮症状。
    - **第二轮症状:两层文字重影**(改完之后用户反馈"还是有,更乱了")。真根因跟宽度/截断毫无关系:`.lyricsTextStroke` 的描边实现要拿一份"剪影素材"去做模糊+alphaThreshold,原来这里用的是 `lyricsTextStroke(_:color:)` 那个 `maskSource` 传 `nil` 的简化重载,等价于直接拿 `content` 本身(**每 30Hz 被 TimelineView 驱动、持续在变的动态内容**)当剪影素材——`LyricsOverlayView.mainLine` 对同一个场景一直是拿一份**不吃 TimelineView、纯色黑字**的静态副本当素材(2026-08-19 性能审计就定下的规矩,注释就在 `karaokeLineContent`/`wordText` 里),这里从一开始就没照抄这条规矩,遇到长句子才被截图坐实成看得见的重影,不只是性能浪费。修法:新增 `wordsRow(_:atMs:palette:)` 统一排版函数,`atMs`/`palette` 传 nil 时退到跟 `LyricsOverlayView.wordText` 一样的纯色黑字分支,`karaokeContent` 改用 `lyricsTextStroke(_:color:maskSource:)` 显式传一份**静态**副本当描边素材,可见内容(TimelineView 驱动)另外单独渲染,两者不再是同一份"会变"的内容。
    - **第三轮症状:词被拆成上下两截**(改完之后用户反馈"放不下的词就会上下显示了")。根因:给 `HStack` 加的 `.frame(maxWidth: 预览可用宽度)` 会把这个更窄的宽度当**提议**传下去,`HStack` 试图满足提议、把每个子 `Text` 挤到比自然宽度更窄的空间——`Text` 在没有 `.lineLimit` 时对"装不下"的默认反应是**换到第二行**而不是截断,挤到某个词头上就会拆成两截("gonna" 拆成 "gonn"/"a")。修法:`.fixedSize()` 先钉死 `HStack` 永远按自身真实内容渲染、无视外部提议多窄,`.frame(maxWidth:)` 只用来告诉外层"我在布局上占这么宽"(不反过来压缩内容),最后 `.clipped()` 把超出这个宽度的部分在视觉上硬裁掉——效果是长行右边整齐切掉一块,不换行、不拆词、不各词加省略号。
    - 三轮教训:**症状"看起来像什么"和"真根因是什么"可以完全不在一个维度上**——乱码看起来像截断出了问题(真是),重影看起来也像截断/宽度问题(其实是描边素材用错了),拆词换行看起来像描边或素材问题(其实又是纯粹的宽度提议传递)。每一轮只照着上一轮最像的那个解释去修,三轮才把三个各自独立的原因都挖出来。
- **与播放控制/权限**:控制排按钮和全局快捷键共用 MusicAutomationPermission「点了才校验、拒了 beep」的策略;「喜欢」只对 Apple Music 出现,乐观更新+回读纠正。
- **与「歌词管理」**:那边保存/删除歌词后调 `PlaybackCoordinator.refreshLyricsForCurrentTrack()` 强制重读磁盘,悬浮窗立即反映。

## 数据与文件

| 读写 | 内容 |
|---|---|
| UserDefaults(悬浮窗私有) | `np:overlayPositionTop`(位置,"x,顶边y");`np:overlayPositionOrigin`(旧键,只读迁移);`np:hasShownOverlayDragHint`(拖动提示只弹一次) |
| UserDefaults(经 AppSettings) | `np:classicOverlayEnabled`、`np:lockPosition`、`np:overlayWidth`、`np:fontFamilyName`、`np:fontSize`、`np:overlayFontWeight`、`np:foregroundColorHex`、`np:backgroundColorHex`、`np:followsCoverArt`、`np:textStrokeEnabled`、`np:textStrokeColorHex`、`np:hideDuringScreenCapture`、`np:hideWhenNotPlaying`、`np:customColorThemesJSON` 等 |
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
| 控制排按钮/命中测试(含 2026-08-29 新增的展开/设置/关闭/解锁提示) | `LyrimuseCore/Util/OverlayControlHitTest.swift` · `OverlayControlID` / `control(at:in:)`;分发在 `UI/LyricsOverlayWindowController.swift` · `performControlAction`;解锁提示视图在 `UI/LyricsOverlayView.swift` · `unlockPill` |
| 热区坐标缓存/换算(2026-08-30 补:原始坐标另存一份,窗口变高也会主动重算) | `UI/LyricsOverlayWindowController.swift` · `controlRectsRaw`/`controlsHotZoneRaw`/`lyricsHotZoneRaw` → `recomputeHitRegions()`;`updateHeight` 里 resize 之后主动调一次 |
| ⚙ 快捷设置菜单(2026-08-29;搜索歌词…是 2026-08-30 补的第六项;简繁转换 2026-08-31 起按曲显隐) | `lyrimuse/Sources/lyrimuse/UI/OverlayQuickSettingsMenu.swift` · `OverlayQuickSettingsMenu`;套用配色主题共用 `Settings/ColorTheme.swift` · `ColorTheme.apply(to:)`;搜索歌词唤出独立小窗 `LyricsManager/LyricsQuickSearchWindow.swift` · `LyricsQuickSearchWindow`,开法共用 `Settings/AppActions.swift` · `openLyricsQuickSearch`(见 07 章) |
| 控制胶囊材质(液态玻璃/纯色兜底,2026-08-29) | `UI/LyricsOverlayView.swift` · `View.overlayCapsuleBackground()`;同一取舍参考 `Settings/SettingsDesignSystem.swift` · `settingsCardBackground` |
| 渐变绑定/30Hz 上限 | `lyrimuse/Sources/lyrimuse/UI/WordKaraokeGradient.swift` · `WordKaraokeGradient` |
| 填色纯算法 | `lyrimuse/Sources/LyrimuseCore/Lyrics/KaraokeFill.swift` · `KaraokeFill.fillFraction` / `stops` |
| 换行几何 | `lyrimuse/Sources/LyrimuseCore/Lyrics/WrapLayoutMath.swift` · `rows` / `placements` |
| 对唱分声部 | `lyrimuse/Sources/LyrimuseCore/Lyrics/LyricDuet.swift` · `plan` / `sides` / `splitMarkerAllowingEmpty`;声部指示圆点在 `LyricsOverlayView.swift` 的 `withSpeakerIndicator`;罗马音/译文对齐补偿在同文件 `speakerIndicatorInset` |
| 对齐方式覆盖(2026-08-29) | `LyrimuseCore/Lyrics/OverlayDuetAlignmentOverride.swift`(`effectiveAlignmentSide` / `effectiveDecorationSide`);`Settings/AppSettings.swift` `overlayDuetAlignmentOverride`;`UI/OverlayStyleSettingsRows.swift` `OverlayLayoutSettingsRows` 里的「对齐方式」+ `OverlayAlignmentSegmentedControl`(抽屉与浮层共用同一份;2026-08-31 前挂在 `OverlayTextSettingsRows` 下、是个 `SettingsSubRow` 子行);`UI/LyricsOverlayView.swift` `duetSide` / `nextLineDuetSide`(对齐用)与 `duetDecorationSide` / `nextLineDecorationSide`(内缩+指示圆点用) |
| 控制排跟着歌词块换边 + 落点冻结(2026-09-03) | `LyrimuseCore/Lyrics/OverlayCardGeometry.swift` · `cardInsets` / `controlsInsets`(卡片与控制排共用的唯一出处,有 selftest);`UI/LyricsOverlayView.swift` · `OverlayControlsSidePin` / `controlsRealSide` / `controlsFrameAlignment` / `controlsInsets` / `duetInsets(for:)`;控制器侧 `UI/LyricsOverlayWindowController.swift` · `isHoveringControlPill` / `clearControlsHoverState()` |
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
| 设置页 | `lyrimuse/Sources/lyrimuse/SettingsView.swift` · `AppearanceSettingsTab`(`currentSection` 里悬浮歌词那一段的**纯装配**)。这一段现在只装三块(编辑台 / 总开关卡 / 抽屉),内容各在自己的文件里:编辑台 `UI/OverlayEditorStage.swift`、「行为」浮层与行为项真源 `UI/OverlayBehaviorSettingsRows.swift`、折叠抽屉 `UI/OverlayAllSettingsDrawer.swift`、外观设置行 `UI/OverlayStyleSettingsRows.swift`(抽屉与编辑台浮层共用同一份)、自动隐藏两行 `UI/AutoHideSettingsRows.swift`(`AutoHideSurface`/`AutoHideItem`/`AutoHideSettingsRows`,与灵动岛共用同一份,四个宿主) |
| 设置页那一小片「桌面」(壁纸样图 + 棋盘格兜底) | `lyrimuse/Sources/lyrimuse/UI/OverlayDesktopSurface.swift` · `OverlayDesktopSurface` / `DesktopWallpaperSample`。三个消费方:两块编辑台的舞台、菜单栏预览条的底。⚠️ 页顶钉条 `OverlayPreviewBar` 与它那份简化渲染 `OverlayLyricsCanvas` **已于 2026-08-31 删除**(零实例化),这两个文件不再存在;下文第一到第九步里提到它们的地方都是历史叙述 |
| 编辑台渲染真视图的接缝(2026-08-30 第八步) | `UI/LyricsOverlayView.swift` · `OverlayChromeSource` / `OverlayPreviewLine` / `LyricsOverlayView.line`·`showingPreviewLine`·`nextLineText` / `showsDebugHUD`;预览侧 chrome 在 `UI/OverlayEditorStage.swift` · `OverlayPreviewChrome`;真控制器侧 `UI/LyricsOverlayWindowController.swift` · `controlsDidBecomeVisible()` |
| 控制排胶囊的材质与"隐藏"(2026-08-30 第九步) | `UI/LyricsOverlayView.swift` · `View.overlayCapsuleBackground(visible:)`,调用点 `playbackControls` / `unlockPill`;把它收走的容器在 `Settings/SettingsDesignSystem.swift` · `SettingsGlassContainer` / `SettingsPage` |
| 编辑台的高度几何(2026-08-30 第九步 / 2026-09-03 第十八步) | `UI/OverlayEditorStage.swift` · `maxCardHeight`(实测常量,几何源头,**266**)→ `cardAreaHeight` → `stageHeight`(**310**)→ `totalHeight`(**382**,第十八步起**不含** caption 那 21pt);卡高本身 `cardHeight`(`onContentHeightChange`);超宽提示 `overflowHint` + 共用胶囊外壳 `View.overlayStagePillChrome()` |
| 菜单栏入口 | `lyrimuse/Sources/lyrimuse/MenuBar/MenuBarStatusMenu.swift` · `rebuild`(快速开关) |
| 全局快捷键 | `lyrimuse/Sources/lyrimuse/Settings/GlobalHotkeys.swift` · `registerAll` |

## 编辑台改造(2026-08-30 起,分步进行中)

设置页这一段正在从"顶部钉一条小预览 + 6 张卡片平铺"改造成**预览即编辑器**:预览升级成内容区里
接近真实尺寸的编辑台,能直接在上面操作(当前已实现:舞台里那条宽度调整条、工具栏三个浮层入口
(第一行 主题 / 文字 / 背景 + 重置▾;第二行 排版 / 行为。「配色」第十七步拆成了主题+背景,「排版」因此从第一行下沉、跟第十六步加的「行为」并排)、底部「全部设置」折叠抽屉)。编辑台画的是
**1:1 的真实尺寸**(第四步纠的概念性错误,见下),舞台是**一小片铺满壁纸的桌面**、窗口居中摆在上面
并自带常驻边界(第五步,见下),宽度改由**窗口下方的一条调整条**控制、外框再没有任何拖拽入口
(第六步,见下 —— 拖拽握柄那条路试了三轮,放弃了)。整块舞台**只有一张壁纸**、窗口相当于在它上面
「开了个洞」,所以拖宽度时背景一个像素都不动(第七步,见下)。舞台里那扇窗画的**就是真窗口
那份 `LyricsOverlayView` 本体**,不再是简化复刻件 —— 译文/罗马音/换行/下一句/对唱全都跟真窗口
同源(第八步,见下);编辑台的高度按**实测的最坏情况**取常量、播放控制排在预览里真正不显示了
(第九步,见下)。**画布上那两块命中区(点歌词/点背景弹浮层)和行为栏那颗「预演」按钮已于第十步
按用户要求删掉** —— 浮层只剩工具栏一个入口,画布本身不再接任何事件(第十步,见下)。
第十一步修掉了"编辑台只画主歌词 + 罗马音、没有译文和下一句"——病根在内容高度那条 preference 的
`reduce` 被写成覆盖式,真实高度被 `defaultValue`(0)冲掉,卡高被摁在 120pt 地板上把下半截裁没了
(第十一步,见下;它同时推翻了第九步那条"探针进程的产物"的错误归因)。
方案来源见 `~/Desktop/lyrimuse-overlay-settings-redesign/`(A×D 混搭稿)。
**这是分步落地,不是一次改完**;还没做的有:场景预设(「✦ 风格 ▾」)、试穿、快照撤销(⌘Z)、
窄窗降级。

### 第一步:共用渲染核心 + 宽度握柄(握柄已于第六步删除)

- `OverlayLyricsCanvas`(新)——从 `OverlayPreviewBar` 提取的**共用渲染核心**(壁纸垫底/背景圆角/
  对齐/描边/逐字卡拉OK填色)。入参只有 `width/height/scale/line/accent/isPlayingNow`,**自己不读
  `settings.overlayWidth`** —— 编辑台要能喂"拖动中还没落盘"的临时宽度。钉条与编辑台共用它,
  不允许出现两份并行维护的渲染代码。
- `OverlayEditorStage`(新)——编辑台本体 + 私有的 `OverlayWidthHandle`。
- `OverlayPreviewBar`——只剩钉条该管的事;三个对外静态量(`rawCardHeight`/`cardHeight`/
  `maxPreviewWidthShared`)签名与取值**与改造前逐字一致**(它们是 `SectionPreviewMetrics` 的
  高度契约,灵动岛/菜单栏两段也在读)。

⚠️ **编辑台只能待在滚动内容区,不能放回那个固定头部**:头部里的控件收不到事件(2026-08-15/16
两次复现,连 `.allowsHitTesting(false)` 都救不回来,是该结构在 SwiftUI 里的事件派发行为)。
所以悬浮歌词这一段的 `stickyHeader` 分支现在是 `EmptyView()`,另外两段照旧。

宽度拖拽的三个要点(都踩过或差点踩到)。⚠️ **拖拽这条路第六步整个删掉了**,下面 1、2 两条因此只剩
史料价值 —— 但它们记的坑本身没过期,以后谁再在这个仓库里写"跟着自己变宽的视图上的拖柄"
(`LyricsManagerView` 的列宽拖柄就是活着的同类)一样会踩。第 0、3 两条讲的是**落点**、跟输入方式无关,
现在由 `OverlayEditorStage.widthBinding` 原样继承,仍然逐字有效。
1. **scale 与起始宽度冻结在拖动开始那一刻**,不用每帧实时值 —— 实时 scale 随宽度变,再乘"相对
   起点的绝对位移"就是自我放大的回路,越拖越快。
   (⚠️ 第四步之后编辑台的 scale 恒为 1,`dragStartScale` 连同 `/ scale` 那一层换算已删;**"冻结
   起始宽度"这半条仍然必须留着**,它跟缩放无关 —— 位移是相对起点的绝对量,基准每帧变就会重复叠加。)
2. **用 `location.x - startLocation.x` 配命名坐标空间,不用 `value.translation`** —— 握柄本身
   就是那个"随卡片变宽往外跑"的视图,translation 会被反馈回路吃掉一部分位移
   (`LyricsManagerView` 的列宽拖柄 2026-08-05 实测过"拖 40pt 只涨 22pt")。
0. **凡是碰 `LyricsOverlayWindowController.shared` 的写入型调用,一律套
   `if settings.classicOverlayEnabled`**(2026-08-30 统一)。`.shared` 是 `static let`,
   **光是读一下**就会执行 init() 把窗口建出来 —— 悬浮歌词关着的用户点一下「锁定位置」,
   屏幕上会凭空多出一扇窗。改造前设置页的 `setLocked`/`setFadeOnHover` 和「窗口」卡的
   `setWidth` 都是裸调的(菜单栏面板那两个入口反而一直带着守卫,两边不一致)。
   跳过这些调用**不会**让控制器里的镜像变陈旧,两处兜底:①镜像初始值直接读真值
   (`isPositionLocked = AppSettings.shared.lockPosition`);②窗口真被打开时会再应用一次
   (setVisible 里的 `setLocked(AppSettings.shared.lockPosition)`)。真值始终在 AppSettings,
   控制器只是镜像。
   ⚠️ **唯一不该套守卫的是 `setVisible` 本身** —— 它就是用来打开这扇窗的,套了就永远打不开。
   全仓现状:`setWidth`/`setLocked`/`setFadeOnHover`/`setHiddenFromCapture`/
   `setHideWhenNotPlaying` 全部带守卫,`setVisible` 四处调用全部不带,这是对的。

3. **落点必须同时调 `LyricsOverlayWindowController.shared.setWidth`**,且外面套
   `if settings.classicOverlayEnabled` —— `overlayWidth` 的 `didSet` 只持久化、不碰 NSWindow
   (见 `AppSettings`),只写 model 的话表现为"预览变了、真窗口没变";而 `.shared` 是
   `static let`,无条件读会把窗口建出来,悬浮歌词关着的用户会凭空多一扇窗。
   clamp 区间 `420...1000` 抄自「窗口」卡那根滑杆,三处必须一致。

### 第二步:工具栏 + 浮层 + 画布命中区(命中区已于第十步删除)

- `OverlayStyleSettingsRows.swift`(新)——「悬浮歌词」那几张卡里的**设置行本体**,从
  `SettingsView` 抽出来的**唯一一份**实现:`OverlayTextSettingsRows`(字体/字重/字号 —— 第十三步之前
  还含双行显示/对齐方式)、`OverlayColorSettingsRows`(跟随封面/配色主题/文字颜色/背景颜色/文字描边/
  描边颜色 —— ⚠️ 这个符号 2026-09-02 已被第十七步拆成 `OverlayThemeSettingsRows` /
  `OverlayBackgroundSettingsRows` 加并进 `OverlayTextSettingsRows` 的四行,**现在 grep 不到它**)、
  `OverlayCustomThemeRows`(我的配色主题,现在长在「主题」组里)、`OverlayAlignmentSegmentedControl`
  (从 `SettingsView` 的 private 嵌套类型提上来)、`OverlayStyleDefaults.restoreTextAndColors()`
  (恢复默认的动作本体)、`OverlayStyleSummary`(工具栏摘要的派生值,第十二步删掉了其中拼给抽屉的
  `overview`,只剩 `text` / `color`,第十三步又补了 `layout`)、以及浮层外壳
  `OverlayTextPopover`/`OverlayColorPopover`(第十三步加了第三个 `OverlayLayoutPopover`,
  和 `OverlayLayoutSettingsRows`)。
- `SettingsView` 那几张卡**没有删**,只是掏空成外壳(`SettingsCard { 标题; CardDivider(); 行组件 }`),
  它就是设计稿说的"全量兜底抽屉"的雏形:键盘/VoiceOver/"我就想找个开关"的用户走这条。
- `OverlayEditorStage` 新增:`toolbar`(「文字…」「配色…」两个带当前值摘要的浮层入口 +
  右侧「重置 ▾」菜单;第十三步补上「排版…」是第三个)、`StagePopover` 状态、`hitZones`(画布命中区)。
  ⚠️ **`hitZones` 那一路第十步整个删掉了**(用户原话「点背景和点文字的交互去掉」),工具栏这一路
  原样留着 —— 它现在是两个浮层唯一的入口。下面关于命中区的段落只剩史料价值,但它们记的坑没过期,
  已在第十步归拢成一份清单。

⚠️ **卡片与浮层必须是同一份行实现,不允许各写一份**。这是这一步最重要的约束:本仓刚为
"同一个视觉属性有两条渲染路径"付过代价(「对齐方式」在预览条上失效,根因是补对齐时只改了
静态文本那条路径、逐字填色那条漏了)。设置行比渲染更容易漂 —— 复制一份之后,每加一个条件
显示、每改一句副标题都要记得改两处,**漏了不会编译报错**,只表现成"在浮层里改有用、在卡片里
改没用"。两个宿主绑的都是 `AppSettings.shared`,所以天然同步,不需要任何双向绑定代码。

⚠️ **「我的配色主题」的命名与删除确认从 `.alert` 改成了内联**(`OverlayCustomThemeRows`)。
理由:这个组件现在有两个宿主,其中一个是 `.popover`;SwiftUI 在 macOS 上把 `.alert` 呈现成挂在
窗口上的 sheet,而 `NSPopover` 是 transient 语义(点到浮层外就关)——用户去点 sheet 里的输入框时,
承载 alert 状态的那棵视图树很可能已经随浮层销毁了。内联做法两个宿主一模一样。两条原有安全约束
一条没松:空名不静默丢弃而是禁用「保存」;删除仍然必须二次确认(`customColorThemes` 的 `didSet`
立刻落盘、没有撤销,而「套用」和「删除」两颗按钮挨着)。

⚠️ **以下两段(命中区与握柄怎么共存、命中区的两个坑)描述的实现第十步已经删干净**,留着是为了留住
这两轮的踩坑记录;结论性的那几条见第十步的清单。

命中区与握柄怎么共存:**命中区铺在卡片矩形里面,握柄贴在卡片外面**(两个 `.overlay` 各
`offset` 出去一整个 `handleWidth`),两者命中范围在几何上完全不相交,谁也抢不到谁的事件 ——
这正是第一步 `handleWidth` 注释里"放外侧…不会跟之后要加的『点文字/点背景』命中区抢事件"
留的余地,第二步没有动握柄一行代码。

命中区的两个坑:
1. **文字命中区是一条横带,不是贴着字形的框。** 要贴合就得知道文字实际多宽,而这个宽度取不到:
   画布有两条排版分支(静态单 `Text` / 逐字 `HStack`),换行与裁切规则不同,外面还隔着一层
   `scaleEffect`;唯一"准"的办法是往 `OverlayLyricsCanvas` 里埋 `PreferenceKey` —— 那份渲染
   **跟顶部钉条共用**,为编辑台的交互往里塞东西不划算。横带取值跟画布同源:高度 = 字号 × 1.5
   (同 `OverlayPreviewBar.rawCardHeight` 的行高系数),宽度 = 卡片宽 − 40(画布
   `.padding(.horizontal, 20)` 的左右之和)。代价:歌词短又选了左/右对齐时,同一水平线上的
   空白也算"文字"。
2. **两块命中区重叠,悬停状态必须用两个独立 Bool 派生,光标 push/pop 只能有一个计数状态。**
   文字带压在背景之上,指针从文字带滑回背景时文字区收到 `hover(false)`、背景区不会补发
   `hover(true)`,写成单个 `@State var hovered: Zone?` 会让状态停在 nil("从歌词上挪开后虚线框
   再也不出现")。光标那一半是本仓已记过的老坑的镜像:握柄是两个**不重叠**区域各管各的
   `pushedCursor`,命中区是两块**重叠**区域共用一个,各记一份就会漏 pop、整个 App 的光标永久
   卡在手型上。提示层(虚线框 + 标签)必须 `.allowsHitTesting(false)`,否则指针移到标签上就等于
   离开命中区,hover 会抖成死循环。

⚠️ **工具栏摘要必须限宽 + 单行 + 尾部省略**(`.lineLimit(1).truncationMode(.tail)` + `maxWidth`)。
它是纯派生值(`OverlayStyleSummary`,跟着同一份 `AppSettings` 走、不新增状态),内容里有用户装的
字体族名 —— "Hiragino Sans GB W3"这种长名字不限宽会把整条工具栏顶出编辑台。


### 第三步:行为栏 + 「全部设置」折叠抽屉

这一步把设置页那一段的结构收成四块:**编辑台 → 总开关卡 → 「行为」栏 → 「全部设置」抽屉**。

- `OverlayBehaviorSettingsRows.swift`(新)——三个**行为**项(锁定位置 / 拖动前先长按 / 划过让开)
  的唯一一份真源。`OverlayBehaviorItem` 这个枚举装文案、图标、`help`,以及那个"改了要连带让真窗口
  生效"的 `Binding`;两个宿主 `OverlayBehaviorSettingsRows`(抽屉里的标准设置行)和
  `OverlayBehaviorBar`(编辑台下面那条三列小格)都按 `allCases` 迭代它,**只决定怎么摆**。
  (⚠️ `OverlayBehaviorBar` 已于**第十六步**删除,宿主换成了编辑台工具栏的 `OverlayBehaviorPopover`;
  枚举本身和"两个宿主、只决定怎么摆"这条结构没变。)
  ⚠️ 2026-09-02 起这两个宿主里各多两行**自动隐藏**,但它们来自另一个枚举 `AutoHideItem`(`UI/AutoHideSettingsRows.swift`),`OverlayBehaviorItem.allCases` **仍然恒为三项**;别为了"都是行为项"把它们并进来——那两项要同时服务灵动岛,而这个枚举的 Binding 写死打的是悬浮窗控制器。见第十五步。(当时还有第二条理由「三列小格的版式压根不画副标题和 ⓘ 气泡」,第十六步把那张卡换成浮层之后不再成立——浮层里全是标准 `SettingsRow`;**按形态分流那条理由没变**。)
- `OverlayAllSettingsDrawer.swift`(新)——默认折叠的「全部设置」抽屉,替掉原来平铺的 5 张卡
  (配色 / 我的配色主题 / 文字 / 窗口 / 恢复)。展开是就地长出来,不跳页、不开新窗口。里面每一组都是
  别处那份组件,只有「宽度」滑杆是它独有的(编辑台那边是拖握柄,不是滑杆)。
- `SettingsView` 里 `classicOverlayCard` 及其五张子卡**已删除**,`AppearanceSettingsTab` 只剩装配 +
  `overlayFadePreviewActive` / `playOverlayFadePreview`(「预演」的状态与定时)。
  ⚠️ 那两样第十步随「预演」按钮一起删了,`AppearanceSettingsTab` 这一段现在**只剩装配**。

**为什么行为项要从「窗口」卡里提出来**:这几项在编辑台上**看不出变化** —— 编辑台画的是一张静态卡,
点击穿透、长按拖动、指针悬停都只有真窗口才有。混在配色/字体那些"改了当场看得见"的项里,读者会一直
等一个不会来的视觉反馈。提出来之后编辑台上方只剩所见即所得的项,行为项自己占一栏、并且明说
"这些改动在编辑台上看不出来"(⚠️ 界面上那句说明第十步删了,分栏这件事本身没变)。
**「宽度」不进行为栏**:它已经能在编辑台上拖握柄改(看得见),
滑杆只留在抽屉里当兜底。

**给行为一点可感知的反馈,但不硬做**(设计稿原话,三项各不相同):

| 行为项 | 编辑台上的产物 |
|---|---|
| 锁定位置 | 画布左下角出现一个「🔒 位置已锁定」小标(`OverlayEditorStage.lockBadge`)。这是它唯一能被看见的部分 |
| 划过让开 | 那一格带一颗「预演」按钮:点一下画布淡到 25% 再回来,约 1.2 秒演完。⚠️ **第十步删掉** |
| 拖动前先长按 | **没有任何视觉产物**,就老老实实只留开关和副标题(副标题第十步也删了) |

⚠️ **这张表第十步只剩第一行成立**:用户要求把「预演」按钮、「锁定位置」那格介绍锁标的小字、
「拖动前先长按」的副标题一并去掉。**锁标本身保留** —— 它是「锁定位置」在编辑台上唯一的真实反馈,
删掉解释不等于删掉被解释的东西。

⚠️ **下面两条关于「预演」的约束,连同「预演」本身,第十步整个删掉了**,留着是史料 —— 但"跨视图共享的
一次性演示状态该放在共同祖先""同一段演示的时长常量不许分散到两个文件"这两条结论本身没过期。

- **「预演」的淡出值(0.25)跟真窗口(0.15)不是一个数**,是刻意的:演的是"它会淡下去"这件事,
  缩放后的小卡压到 0.15 接近于"消失了"。要改成一致的话两处一起改
  (`OverlayEditorStage.fadePreviewOpacity` 与 `LyricsOverlayView` 里那句 `isHoveringLyrics ? 0.15 : 1`)。
- **「预演」的状态放在 `AppearanceSettingsTab`,不在编辑台也不在行为栏**:按钮在行为栏上、淡的却是
  编辑台,两者是兄弟视图,那一层是它们唯一的共同祖先。三段时长(淡下去 0.15s / 停留 0.9s / 回来 0.15s)
  的口径全在 `OverlayEditorStage` 那边,宿主只按 `fadePreviewHoldSecs` 把状态收回去 —— 分散到两个文件
  各写一个数字,改其中一个就再也对不上"约 1.2 秒"这个设计口径。

⚠️ **总开关不进抽屉**。「桌面悬浮歌词」是这一段的主开关,收进折叠区等于"要先展开才能开这个形态";
它留在编辑台正下方常驻可见。排在行为栏**上面**而不是下面:它决定整个形态开不开,行为项是"开了之后
这扇窗怎么表现",从属于它。

⚠️ **三个行为开关的 `Binding.set` 里那句 WindowController 调用不能丢**。`AppSettings` 里
`lockPosition` / `overlayFadeOnHover` 的 `didSet` **只负责写 UserDefaults**("生效"这一步刻意留在
View 层),真窗口的点击穿透、鼠标监听器装卸在 `LyricsOverlayWindowController`。丢掉就是"开关变了、
真窗口纹丝不动"。这两句**没有**套 `if classicOverlayEnabled` 守卫,是原样搬过来的既有行为,不是漏写
(要不要补守卫牵涉控制器里 `isPositionLocked` 那份镜像会不会变陈旧,是另一件事)。

⚠️ **抽屉里的宽度滑杆这次补上了 `if settings.classicOverlayEnabled` 守卫**(原来那张「窗口」卡里
是裸调 `setWidth`)。`LyricsOverlayWindowController.shared` 是 `static let`,光是读一下就会执行
`init()` 把窗口建出来 —— 悬浮歌词关着的用户碰一下滑杆就会凭空多出一扇(不可见但已经装好监听器和
观察者的)窗。宽度的另外两个写入点(`OverlayEditorStage.endDrag`/`adjust`、
`MenuBarPanelQuickSettings`)本来就都带这条守卫,这里是最后一个没带的;三处的取值区间
(`420...1000`)同样是跨文件契约,改一处要改三处。

⚠️ **抽屉展开/收起的动画写在改状态那一处(`withAnimation`),不挂 `.animation(_:value:)` 到卡片上**。
理由见 `Animation.settingsCardReveal` 的声明:挂在容器上动的是容器自身的几何,同一个事务里任何不相干
的布局变化都会被一起动起来 —— 而抽屉里恰恰全是这种变化(拖字号滑杆、开「跟随封面」让两行条件行长出来、
存一个新主题让列表多一行)。

**高度账**(卡片列固定 600pt 宽,设置窗口 `idealHeight` 640、用户常用 ~552)。⚠️ **2026-09-03
重算过一遍,下面这份是量出来的现状**(方法:量用户截图 1358×1038 @144dpi = 679×519pt 的详情面板,
按 2x 逐行采样定位每一块的上下沿;舞台实测 138.5→470.5 = 332pt,跟代码常量对得上,说明这把尺子准):

| 块 | 高度 | 详情面板里的位置(第十八步**前** → **后**) |
|---|---|---|
| 页头(上留白 26 + 分段器及其两处 padding) | 66.5 | 0 → 66.5 |
| 编辑台 `totalHeight` | **425 → 382** | 66.5 → 491.5 / **448.5** |
| 间距 | 14 | |
| 「桌面悬浮歌词」总开关卡 | 46 | 505.5→551.5 / **462.5→508.5** |
| 间距 | 14 | |
| 「全部设置」抽屉头 | 38 | 565.5→603.5 / **522.5→560.5** |
| 下留白 | 28 | |
| **整页内容** | **631.5 → 588.5** | 可视内容 519pt(552pt 高的窗口)|

也就是:第十八步之前总开关卡只露出 13.5pt(卡底 551.5 落在 519 之外),之后完整露出、底下还剩
10.5pt;抽屉头**仍然在折线以下**,这一段依旧是"一次短滚动就能到底",不是严格意义上的一屏。

⚠️ **别信本文档 2026-09-02 那两版里的「编辑台 303 / 339」**:那两个数一直在拿 `画布 246`(第一步
定的量)往上加,而画布早在第八步就变成 288、第九步变成 332 —— 于是当时算出来的 667 / 605 / 449
三个总数**都比真实低了约 86pt**,"剩给下面三块的只有六十来 pt"那句结论也因此偏乐观(真实是负的,
下面三块根本没进屏)。改造前那个"约 1300pt(6 张卡平铺)"的量级不受影响。下面两条按当时的口径原样
留着,只是别再用它们的绝对值:
- 第十五步(并进自动隐藏)之后是 **605pt** = 编辑台 303 + 总开关卡 44 + 行为栏 **178** + 抽屉头 38 +
  三处 14pt 间距。当时重量过一遍(离屏 `NSHostingView.fittingSize`,把设计系统组件按源码 1:1 复刻;
  同一把尺子量总开关卡得 46、文档里写的是 44,误差 ±2):行为栏原文那个「~127」是**第三步**的口径,
  当时每格底下还带一句小字,第十二步删掉之后只剩 76pt,并进两行自动隐藏(截屏那行带副标题 + ⓘ)
  之后是 178pt;同时少掉一整张 150pt 的独立「自动隐藏」卡和它上面那 14pt 间距,净 **−62pt**(667 → 605)。
- 第十六步(「行为」栏整个换成编辑台工具栏第二行的浮层)之后是 **449pt**:少掉行为栏 178 和它上面那
  14pt 间距,编辑台自己多一行工具栏 **+36pt**(`toolbarHeight` 26 + `toolbarSpacing` 10,303 → 339),
  净 **−156pt**(605 → 449)。这一步是这轮改造里对高度账最大的一笔 —— 五个开关从"永远占着 178pt"
  变成"点开才占地方",而浮层是覆盖在页面上的,不进这本账。
**仍然没有做到严格意义上的"一屏不用滚"**
—— 编辑台自己就占 303pt(画布 246 是第一步定的量,见上),页面 chrome 又要 164pt,552pt 高的窗口里
剩给下面三块的只有六十来 pt。当前状态是"一次短滚动就能到底",不再是原来的两屏半。真要压进一屏,
唯一有效的杠杆是缩小编辑台画布高度,那是另一次改动。


### 第四步:去掉"缩放"、握柄挪到窗口自己身上

2026-08-30 用户反馈,原话:「就不应该有什么缩放的概念在这里;只显示实际的大小以及一切;并且这里可以
拖动的不应该是外面这个带桌面的大窗口,而是里面的文字对应的悬浮歌词窗口才对吧」。两条都是**概念性
错误**,不是观感偏好:编辑台的全部意义是"所见即所得",而缩放让"看到的大小"不再是真实大小;握柄贴在
画布外缘则等于在拖"桌面有多大",拖的对象根本不是那扇窗。

**① 编辑台按 1:1 真实 pt 画。** `OverlayEditorStage` 给 `OverlayLyricsCanvas` 的 `scale` 恒传 1,
caption 里「已缩放至 X%」整句删掉(宽度数字保留 —— 它是这块画布上唯一精确可读的量)。可用宽度顺手做
大了一截:握柄不再占画布外面的位置,两侧各省下 `handleWidth + 12`,1:1 放得下的上限从 544pt 涨到
**600pt**(= `SettingsPage.maxCardColumnWidth`,卡片列的硬顶,设置窗口再拖宽这一列也不涨)。

**放不下时:居中裁切 + 两端渐隐,不缩放、不加横向滚动条。** `overlayWidth` 上限是 1000pt,600 往上必然
放不下。取舍理由:缩放会让"这就是它在桌面上的实际大小"这个前提整个塌掉(正是这次要修的问题);裁切
不需要解释,真实世界里本来就是"窗口摆在更宽的屏幕上";横向滚动条在纵向滚动的设置页里很别扭,而且它
诱导用户"滚着把内容读完",可这块画布要看的是尺寸感、不是内容。代价是看不见窗口的左右边缘,所以补两个
信号:卡片两端各 20pt 渐隐到页面底色(`overflowFade`,只盖卡片那 120pt 高,不盖满舞台),caption 换成
带「两端已裁切」的那句。**两个信号缺一不可** —— 只有渐隐会被读成"边上暗一点是设计如此",只有文字则
没人会去读 caption。

**② 握柄贴在悬浮歌词窗口自己的左右边缘上。** 整条 16pt 命中带压在窗口最外侧那 16pt 上、朝里长,高度锁
成窗口高度(120pt)而不是撑满 246pt 的舞台 —— 撑满就又变回"一条比窗口还高的杆子"。用
`.frame(maxWidth:.infinity, alignment:)` 贴边而不是 `.offset`:offset 不改变布局尺寸,握柄会被摆到父框
外面去,而这里正需要它**始终留在框里**。窗口超宽时它的真实边缘已被裁到舞台外,握柄停在舞台内沿(再往外
就抓不到了),这时它不再跟着指针走,但拖拽是按位移增量算的,手感不受影响。

⚠️ **握柄的颜色从 `Color.primary` 换成固定白色 + 黑色投影**:它现在压在**用户真实的桌面壁纸**上(以前
在画布外面,底下是设置页那块底板),语义色跟着深浅色模式走,在浅壁纸上会直接消失 —— 跟 `hintLabel` /
`lockBadge` 固定黑白是同一条理由。

⚠️ **背景透明时窗口没有可见边界,必须另给一条**(`transparentEdgeHint`)。`backgroundIsVisible` 为假时
画布不画那个圆角块,握柄贴的是一条谁也看不见的边。改法:握柄一活跃(悬停或正在拖)就用虚线把窗口轮廓
描出来,背景块画着时不描(那时圆角块自己就是边界,再叠一圈纯属噪音)。握柄的"活跃"状态由
`OverlayWidthHandle.onActiveChange` 上报,**左右各记一个 Bool 再派生**,理由跟命中区那两个 hover Bool
一样:指针在两个握柄之间移动时,"进了新的"和"离开旧的"谁先到不由我们控制,单值状态会被后到的"离开"
清成 nil。上报搭在已有的 `pushedCursor` 翻转判断上,不是每次 hover 抖动都往上报一次。

**命中区与握柄的新几何关系**(握柄进到卡片里面之后重新排过,必须保持不相交),由外到内三层,宽度一律按
**看得见的那部分窗口** `visibleWidth = min(卡片宽, 舞台宽)` 算:

| 层 | 范围 |
|---|---|
| ① 握柄带 | `visibleWidth` 最外侧的 16pt,左右各一条 |
| ② 背景命中区(点→配色浮层) | `visibleWidth − 2×16`,即左右各让出一条握柄带 |

(这张表是**第五步当时**的几何。两块命中区已于**第十步**整体删除,第十七步之后「配色」浮层本身也不存在了——拆成了「主题」和「背景」。留着是这一步的记录,不是现状。)
| ③ 文字命中带(点→文字浮层) | `卡片宽 − 40`(画布左右内边距之和)再跟 ② 取小;20 > 16,所以不超宽时它本来就在 ② 里面,取小只为超宽时兜底 |

代价是窗口左右各 16pt 的背景带不再弹配色浮层(点下去是抓握柄)—— 这条窄带只有 16pt,而工具栏「配色…」
才是它的正规入口。**三者都按 `visibleWidth` 收窄,不是按卡片真实宽度**:SwiftUI 的 `clipShape` 只保证画
不出去,**不保证连命中测试一起裁**,不自己收窄的话,用户点在编辑台外面的页面空白上也可能弹出浮层。
同理 `lockBadge` 在超宽时要往里让开被裁掉的那一半,否则"锁定位置唯一的视觉产物"在宽窗口下会凭空消失。

⚠️ **钉条 `OverlayPreviewBar` 一像素没动**:它自己算 `scale`(只有 520pt 可用,那边照旧要缩)、自己传
`width/height/scale` 给共用的 `OverlayLyricsCanvas`,这次改的两个文件里没有一处碰到它走的代码路径 ——
`OverlayLyricsCanvas` 本身零改动(缩放能力原样留着,只是编辑台恒传 1),三个静态量
`rawCardHeight`/`cardHeight`/`maxPreviewWidthShared` 与其 `SectionPreviewMetrics` 高度契约也没动。

文案:删掉「预览 · %@pt · 已缩放至 %@%% · 拖两侧改宽度」和「预览 · %@pt · 拖两侧改宽度」两个键,新增
「预览 · %@pt · 实际大小 · 拖两侧改宽度」与「预览 · %@pt · 实际大小 · 两端已裁切 · 拖两侧改宽度」;钉条
那两条(「预览 · %@pt」/「预览 · %@pt · 已缩放至 %@%%」)原样留着。改完跑了
`Localization/generate-strings.py`。(⚠️ 这两个键在第五步又改过一次,见下。)


### 第五步:把"桌面"和"窗口"分开

2026-08-30 用户第二轮反馈(配了截图和箭头),原话:「我意思是不应该可以拖动的是里面这部分吗外面这个框
为什么要去拖动他,最直观的难道不是调整文字部分吗」——他把那块贴满壁纸的矩形读成"外面这个框",把歌词
读成"里面这部分"。

**根因不是握柄贴错了地方**(第四步起它就贴在窗口边上了),而是那扇窗根本不像一扇窗:那块壁纸的宽度
**恰好就等于 `overlayWidth`**(画的就是窗口本身),而用户的背景是透明的(`backgroundIsVisible == false`)、
窗口没有任何可见边界,`desktopUnderlay` 又把整个窗口矩形铺满 —— 于是它只能被读成"一张带图的背景板",
握柄贴在它边上自然就是"在拖外框"。**不是空间不够**:该用户 `overlayWidth = 530`,舞台上限 600,放得下
还富余 70pt。

**① 桌面铺满整个舞台**(`OverlayEditorStage.desktopSurround`)。舞台从"一块中性底板"变成**一小片桌面**,
窗口 1:1 居中摆在上面,窄于舞台时两侧自然露出桌面 —— "里面这部分"这才有得指,握柄也才落在舞台内侧、
靠近内容(贴着舞台外缘正是让人读成"在拖外面这个框"的那个几何)。舞台自己那条发丝描边随之挪到
`clipShape` **之后**(壁纸会把底板上的描边整个盖住),透明度 0.07→0.12(描在照片上,0.07 那档看不见)。

⚠️ **窗外那圈桌面必须虚化,这不是观感偏好。** 画布底下垫的是同一张壁纸,但那份是拿**窗口这个又宽又扁
的矩形**做 `scaledToFill` 的:整张图被横向压进窗口宽度里,横向一点富余都不剩,舞台想接着往外画根本无图
可用,只能按舞台自己的尺寸重新裁一次;两次裁切的缩放比差着一成多,清晰地拼在一起会在窗口边缘看到**同一
张壁纸出现两次**(窗外那两条带子里挤着一份压扁的全图),像渲染坏了。虚化掉接缝就不存在了,顺带白得一条
**跟壁纸内容无关**的边界信号(窗内清晰、窗外虚化),深浅壁纸上都成立;再压一层朝 `windowBackgroundColor`
走 0.16 的薄纱,窗外是上下文、不是内容。想"严丝合缝地接上"只有一条路——让共用画布按舞台宽度画壁纸,那要
改 `OverlayLyricsCanvas` 的语义(钉条也在用),不划算。虚化烘在**只算一次的位图**上(`OverlayStageDesktop`,
高斯半径 10pt、按位图/点比例换算成像素,`clampedToExtent` 后裁回原范围免得四边淡出),不是渲染时挂
`.blur()` —— 拖握柄时整块舞台每帧重求值,没必要让实时高斯模糊跟着走 60Hz。读不到壁纸时什么都不画,
露出底板(画布那边这时是棋盘格,再手搓一份去接它等于抄共用画布的语义,而且相位对不齐)。

⚠️ **这一整段在第七步被推翻了**:虚化(连同 `OverlayStageDesktop`)已经删掉,舞台上只剩**一张**壁纸。
上面这段留着是因为它记着「为什么当初非虚化不可」 —— 那个理由(两张壁纸缩放比对不上、接缝)恰恰是第七步
真正要修的病根。见下面第七步。

**② 窗口边界常驻可见**(`windowEdgeOutline`,从原来的 `transparentEdgeHint` 改来)。**"常驻"是这一轮的
核心**:上一版只在握柄活跃时才描虚线,那等于"要先发现才能被提示"——用户压根没意识到中间那块是一扇窗,
自然不会把指针移到它边上去,提示永远不会出现,两轮反馈说的都是同一件事。现在:背景透明时恒画一圈
1pt 白色虚线(圆角 16,跟真窗口一致)+ 黑色投影,静止 0.5、握柄一活跃提到 0.95;背景可见时不画(那个
圆角块自己就是边界,真窗口也没有边框)。固定白+投影**不跟深浅色模式走**,理由同 `hintLabel`/`lockBadge`/
握柄:它压在用户真实的桌面壁纸上,那块底色不受 App 控制,语义色在浅壁纸上会直接读不出来。

⚠️ 轮廓按**卡片真实宽度**画、不按 `visibleWidth`:窗口超宽时左右两条边本来就在舞台外面,让舞台的
`clipShape` 把它们裁掉、只剩上下两条横线,说的正好是"窗口有这么高、两端还没完";按 `visibleWidth` 画会在
舞台内沿描出一个**闭合**的框,那是在撒谎(会被读成"这扇窗就这么宽")。轮廓垫在渐隐带**底下**,超宽时
那两条横线跟着一起溶掉;握柄仍在最上面(它是控件不是内容)。

**命中区没有动,但多了一条必须成立的性质**:两块命中区是挂在**画布**上的 `.overlay`,天生收在窗口那个
矩形里,所以**窗外新铺开的桌面点下去什么都不会发生**(`desktopSurround` 另外显式 `allowsHitTesting(false)`)。
这是对的 —— 那片桌面不是这扇窗的一部分,点它弹「配色」浮层等于又在暗示"整块舞台就是那扇窗"。第四步那张
握柄/命中区三层表原样成立,只是最外面多了第 ⓪ 层"窗外的桌面,不接事件"。
(⚠️ 命中区第十步删干净了,`desktopSurround` 那句 `allowsHitTesting(false)` 留着 —— 整块舞台现在没有
任何可点的东西,它只剩"把意图写清楚"这一个作用。)

⚠️ **钉条 `OverlayPreviewBar` 与共用画布 `OverlayLyricsCanvas` 这一步同样一像素没动**(文件 mtime 可查):
新增的铺满壁纸、常驻轮廓全在编辑台这一侧,钉条走的仍是"自己算 scale → 传 width/height/scale 给共用画布"
那条老路径。唯一的间接接触是 `OverlayStageDesktop` 也读 `DesktopWallpaperSample.image`,那是个幂等的
一次性缓存 —— 谁先渲染谁触发加载,结果一样。

文案:「拖两侧改宽度」→「拖窗口两侧改宽度」(两个键都改,en 同步成 `drag the window's edges to resize`)。
舞台上现在有两样东西各有"两侧"(整块舞台 / 中间那扇窗),而用户上一轮的原话正是分不清该拖哪一个,
这里必须点名。改完跑了 `Localization/generate-strings.py`。


### 第六步:删掉拖拽握柄,改成舞台里的宽度调整条

2026-08-30 用户第三轮反馈,原话:「算了你始终不明白我的意思;既然这样,那么就这样调整,**在这个框里加
一个调整条,可以控制歌词的宽度**;然后**外面始终是 1 比 1 的大小,不可以拖动外部的框**」(配图用红框圈
出了位置:编辑台舞台**内部**、悬浮歌词窗口虚线轮廓**下方**那条空白)。第一/四/五步里所有关于握柄的
描述,行为上都已被这一步取代;那些段落留着是为了留住那三轮的踩坑记录。

**为什么是放弃拖拽,而不是又一次"改良握柄"**:第一步把握柄做出来、第四步把它从画布外缘挪到窗口边上、
第五步给窗外铺满桌面 + 给窗口描一圈常驻轮廓、caption 里还专门写了「拖窗口两侧改宽度」—— 三轮之后用户
仍然没找到它。根子在"预览即编辑器"这套范式最贵的那条代价上:**直接操作的可发现性天生就差**,而这里
可抓的东西只有 4pt 宽、贴在一张会跟着变的卡的边缘上,再加提示只是在给一个看不见的入口写说明书。一根
明摆着的滑杆没有这个问题——它长什么样就说明它能干什么。⚠️ 这条结论**只针对宽度这一个入口**,不是
"直接操作都不好":点文字/点背景那两块命中区照旧留着——它们有悬停虚线框 + 标签,而且工具栏上有等价的
显式入口兜底,不靠用户自己试出来。⚠️ **第十步用户把命中区也要求去掉了**,于是画布上再没有任何直接操作
入口:宽度走调整条,其余一律走工具栏。

**删掉的东西**(全在 `OverlayEditorStage` 内,一个不留、不保留"第二入口"):`OverlayWidthHandle` 整个
类型、`OverlayWidthHandleSide`、`widthHandles`/`handle`、`beginDrag`/`updateDrag`/`endDrag`/`adjust`、
`pendingWidth`/`dragStartWidth`/`leadingHandleActive`/`trailingHandleActive`、命名坐标空间
`dragSpaceName` 与挂在 body 上的 `.coordinateSpace`、以及握柄上那个 `accessibilityAdjustableAction`
(Slider 自带键盘/VoiceOver 调节,不用再手写一条可调节动作)。`effectiveWidth`(在"拖动中的临时值"和
真值之间二选一)随之退化成 `windowWidth = CGFloat(settings.overlayWidth)` —— 调整条实时落盘,不再有
第二个真相。

> ⚠️ **"不再有第二个真相"这半句后来被自己收回了**:修拖动卡顿时又把那个临时值加回来了
> (`draggingWidth`,`windowWidth = CGFloat(draggingWidth ?? settings.overlayWidth)`)。当时删得对
> ——那一版删的是握柄那套东西;错的是把这条经验推广成"永远不需要临时值"。

**新增的 `widthBar`**:舞台内部、窗口正下方的一条胶囊,内容是 `arrow.left.and.right` 图标 + `Slider`
(168pt 长,`in: OverlayEditorStage.widthRange`、`step: widthStep` = 2)+ 等宽数字读数。摆位是
`.padding(.bottom, 12)` 之后再 `.frame(maxWidth:.infinity, maxHeight:.infinity, alignment:.bottom)` ——
**先 padding 再 frame**,反过来那 12pt 会加在"撑满舞台"的那一层外面、把整块顶高。舞台 246pt、窗口
120pt 且居中,窗下天然剩 63pt,放得下且压不到窗口。step 取 2 而不是抽屉那根滑杆的 10:那根旁边没有
实时预览、粗一点反而好落值,而这根紧挨着一扇跟着实时变宽变窄的窗,10pt 一格看得出来是在跳。

⚠️ **配色固定黑底白字 + 白色发丝描边 + 投影,不跟深浅色模式走** —— 跟 `hintLabel`/`lockBadge`/
`windowEdgeOutline` 是同一条老规矩:它底下垫的是用户真实的桌面壁纸,那块底色什么样 App 完全控制不了,
语义色(primary/secondary)在浅壁纸上会直接读不出来。三层各司其职:半透明黑胶囊(0.7)把滑杆和读数从
任意壁纸里托出来;白色发丝描边(0.18 / 0.5pt)在**深**壁纸上给胶囊自己留一圈边界(只有黑胶囊会糊成
一团);投影在**亮**壁纸上兜一圈暗轮廓。滑杆的 `.tint(.white)` 同理——默认强调色跟着系统主题走,压在
壁纸上深浅不定。

**落点规则一条没变**,全部由 `widthBinding` 继承(第一步那份要点里的第 0、3 两条仍然逐字有效):
① **相等守卫** —— `@Published` 是 willSet 语义,等值赋值照样广播 `objectWillChange` 并白写一次
UserDefaults,而 Slider 拖动中按鼠标事件频率反复调 set;② **`if settings.classicOverlayEnabled` 才碰
`LyricsOverlayWindowController.shared`** —— 它是 `static let`,光读一下就会 init 出一扇窗;
③ **clamp 与量化只走 `snap`**,区间只有 `widthRange` 一份(跨编辑台 / 抽屉 / 菜单栏三处的契约)。
落盘当时是**实时**的、不再有"松手才写"那一层:用户要的就是"编辑台里的窗口跟着实时变宽变窄",真窗口
一起变才叫所见即所得;代价被相等守卫 + 2pt 量化一起摁住 —— 走完 420→1000 也只有 291 次真正的写入,
跟抽屉里那根 10pt 的滑杆是同一个量级。

> ⚠️ **上面这段"实时落盘"后来被推翻了**(用户报"拖动这个宽度条的时候卡顿,不流畅"):区间扩到
> 300…1400 之后一次拖动是 550 格,每格 `@Published` 广播 + 写 UserDefaults + 真窗口重新布局,而编辑台
> 里跑的是真 `LyricsOverlayView`(还要重算 `WrapLayout` 换行、重报内容高度)。现在的真实行为是
> **拖动中只改本地 `@State`(`draggingWidth`),松手一次性 `commitWidth`** —— 编辑台里的画布仍然跟手
> (它读 `draggingWidth ?? 真值`),只有真悬浮窗是松手才跟上。这段留着不删是因为"落点三条规则"仍然
> 逐字有效,只有"什么时候提交"这一句变了;读到这里请接着看第十四步。

**命中区几何往回收了一档**(第四步那张四层表作废,现在是三层。⚠️ 整张表第十步随命中区一起作废,
只剩 ⓪ 那一行还成立):

| 层 | 范围 |
|---|---|
| ⓪ 窗外的桌面(`desktopSurround`) | 舞台里窗口以外的部分,**不接任何事件** |
| ① 背景命中区(点→配色浮层) | `visibleWidth` **整块** —— 第四步被握柄占走的左右各 16pt 还回来了 |
| ② 文字命中带(点→文字浮层) | `卡片宽 − 40`(画布左右内边距之和)再跟 ① 取小,取小只为超宽时兜底 |

⚠️ **① 和 ② 现在是重叠的**(② 压在 ① 上面,靠 ZStack 的层序定优先级),不再是第四步那种"三层互不
相交"。所以那两条老约束一条都不能松:悬停必须用两个独立 Bool 再派生、光标 push/pop 只能有一个计数
状态。判据是"两块区域会不会同时把指针算作在自己里面"、不是"有几块区域" —— 重叠的共用一个计数,不重叠
的各记各的(被删掉的那两个握柄正是后者),两个方向本仓都踩过。宽度调整条落在**窗外**、是舞台那一层的
兄弟,跟这两块命中区在几何上完全不相交,谁也抢不到谁的事件。

**保留没动**:1:1 真实尺寸、桌面铺满舞台、窗口居中、超宽时居中裁切 + 两端渐隐 + caption 里那句
「两端已裁切」、背景透明时那圈常驻虚线轮廓。⚠️ **轮廓现在更要紧**:握柄没了之后,它是"调整条正在改的
是这扇窗的宽度"**唯一**的视觉锚点,别当装饰顺手删掉。加强那一档还在,只是触发源从"握柄悬停/拖动"换成
了 Slider 的 `onEditingChanged`(单个 Bool `adjustingWidth`,不再需要左右各记一个)。

文案:删掉「预览 · %@pt · 实际大小 · 拖窗口两侧改宽度」与「预览 · %@pt · 实际大小 · 两端已裁切 · 拖窗口
两侧改宽度」两个键,新增「预览 · 实际大小」与「预览 · 实际大小 · 两端已裁切」。**caption 不再带宽度
数字** —— 数字挪到调整条旁边、离它改的那扇窗更近;同一个数字摆两处、一调两边一起跳,会被读成两件事。
「实际大小」必须留着(它是"编辑台不缩放、看到多大就是多大"这个前提唯一的声明)。改完跑了
`Localization/generate-strings.py`。

⚠️ **钉条 `OverlayPreviewBar` 与共用画布 `OverlayLyricsCanvas` 这一步仍然一个字节没动**:改动全在
`OverlayEditorStage` 这一侧,外加三处注释同步(`OverlayAllSettingsDrawer` / `OverlayBehaviorSettingsRows` /
`SettingsView` 里提到"拖握柄"的句子)。依赖方向仍然是单向的:编辑台读 `OverlayPreviewBar.rawCardHeight`
和 `SectionPreviewMetrics`,反过来钉条/画布对编辑台没有任何**代码**引用;钉条走的仍是"自己算 scale →
传 width/height/scale 给共用画布"那条老路径。

⚠️ **一处已知的陈旧注释**:`OverlayLyricsCanvas` 头部和 `width` 入参附近还写着"编辑台在拖动宽度握柄的
过程中画的是还没落盘的临时宽度(见 `OverlayEditorStage.pendingWidth`)"。那个属性第六步已经没了,但这
次改动明确不许碰这两个文件,所以留着 —— 下次有正当理由改 `OverlayLyricsCanvas` 时顺手修掉。**入参语义
本身没变**:`width` 仍然完全由调用方给,画布自己不读 `settings.overlayWidth`。

(⚠️ 第七步顺手修掉了这两处陈旧注释 —— 那一步本来就要改 `OverlayLyricsCanvas`。)

### 第七步:整块舞台只留一张壁纸,窗口在上面开洞

2026-08-30 用户第四轮反馈,原话:「还有一点要调整就是**背景永远不要变**,拖动宽度框的时候**只变可显示
歌词窗口的宽度**,背景不应该变」。

**病根是第五步留下的**:那一步之后舞台上有**两张**壁纸 —— 窗内那张来自共用画布
(`OverlayLyricsCanvas.desktopUnderlay`,按**窗口宽度**做 `scaledToFill`),窗外那张按**舞台宽度**裁一次
(`desktopSurround`)。拖宽度调整条时窗内那张的缩放比跟着变、壁纸内容跟着"呼吸",而窗外那张纹丝不动 ——
用户看到的就是"改宽度把背景也改了"。两张图缩放比对不上,也正是窗外那圈当初必须虚化的原因(接缝)。

**改法:整块舞台只画一张壁纸,窗口相当于在这张壁纸上开了个洞。**

| 谁画 | 画什么 | 依赖 |
|---|---|---|
| `OverlayEditorStage.desktopSurround` | **唯一**那张壁纸,铺满整个舞台 | **只依赖舞台宽度**,跟 `overlayWidth` 无关 —— 拖调整条时一个像素都不动 |
| `OverlayLyricsCanvas`(编辑台这一路) | 背景色圆角块 / 歌词文字 / 描边 / 逐字填色 | 窗口宽度 |
| `OverlayEditorStage.windowEdgeOutline` | 背景透明时那圈常驻虚线 | 窗口宽度 |

**共用画布加的那个开关**:`showsDesktopUnderlay: Bool = true`(显式 init 里带默认值,所以钉条的调用点
一个字没改)。传 false 时**同时**关掉两层:自带的壁纸 `desktopUnderlay`,以及跟它同套的 `backdrop`
自适应垫底色 —— 后者是"壁纸读不到时的地",只关一层的话那块不透明的自适应底色照样会把舞台那张壁纸整个
盖住,洞就没开成。⚠️ **钉条必须继续自带壁纸**:它是独立钉在页顶的一条,底下没有任何别的东西垫着,不
自带就演不出"背景是半透明的"(2026-08-15 那条反馈)。

**棋盘格兜底抽成了共用实现 `OverlayDesktopSurface`**(真实壁纸样图 / 读不到时的棋盘格),舞台和画布都用
它。第五步的编辑台在读不到壁纸时宁可什么都不画(理由是"手搓一份去接共用画布那份,格子相位对不齐"),
现在两边是同一份实现,兜底路径也能铺满舞台了。

⚠️ **窗外那圈高斯虚化删掉了,连同专门用来烘虚化位图的 `OverlayStageDesktop`**(CoreImage 高斯、整个
进程只算一次那一套;`import CoreImage` 也跟着没了)。它存在的**唯一**理由是藏两张壁纸之间那道对不上的
接缝;只剩一张图之后接缝不存在,再虚化就只剩副作用 —— 把用户的桌面糊成一团,跟"看到的就是它在桌面上的
实际样子"这个前提直接打架。窗口边界改由**背景色圆角块**(背景可见时)和**那圈常驻虚线轮廓**(背景透明
时)来分,那两样本来就是干这个的,不需要靠壁纸清不清晰来暗示。**别再加回来**:任何"只压窗外"的手段
(虚化、暗化遮罩)都会随窗口宽度变形,那就又变回这一轮要修的"改宽度把背景也变了"。

**朝 `windowBackgroundColor` 走 0.16 的薄纱保留,但语义变了**:它现在**均匀**盖住整块舞台、窗内窗外
一视同仁,只负责让这一小片桌面别在设置页里太抢眼,不再承担任何"哪里是窗口"的表达。均匀是硬要求,理由
同上一段。

**保留没动**:1:1 真实尺寸(caption 那句「实际大小」)、窗口居中、常驻虚线轮廓、超宽时居中裁切 + 两端
渐隐 + 「两端已裁切」、宽度调整条的位置与三条落点规则(相等守卫 / `classicOverlayEnabled` 守卫 /
`snap` + `widthRange`)、两块命中区与"窗外桌面不接事件"。**没有新增或改动任何文案**,所以这一步没跑
`generate-strings.py`。

⚠️ **钉条 `OverlayPreviewBar` 逐像素等价**(这一步动了共用画布,必须论证):它的调用点没改、
`showsDesktopUnderlay` 取默认值 true,于是 `desktopUnderlay` 走的仍是"画"那一支、画的仍是同一张壁纸样图
(`Image.resizable().scaledToFill()`,只是搬进了 `OverlayDesktopSurface` 这层透明包装,布局提议原样透传;
棋盘格那段代码一个字符没改),`.background` 那层填的仍是 `backdrop` 本身而不是 `.clear`;其余入参
(width/height/scale/line/accent/isPlayingNow)和 body 里所有别的分支一个字节没动。`OverlayPreviewBar.swift`
这一步本身没有改动。

### 第八步:编辑台改画真 `LyricsOverlayView`,不再有简化复刻件

2026-08-30 用户第五轮反馈,原话:「帮我把这个预览窗口的一切行为都和实际的桌面歌词保持一致;包括翻译,
换行,罗马音,等等,完全一致」。

**病根**:编辑台此前画的是 `OverlayLyricsCanvas` —— 一份**刻意简化**的渲染(它自己的注释写着"跟
`.lineLimit(1)` 一样只求看得出配色效果,不追求跟真窗口逐像素一致的换行表现"),只有主歌词一行 + 描边 +
逐字填色。译文、罗马音(整行的和逐词标注的)、下一句预览、`WrapLayout` 自动换行、对唱两侧内缩与声部
指示圆点、六种占位状态、常驻的播放控制排槽位 —— 一样都没有。

**改法照灵动岛那一段的先例**(`NotchPreviewBar` 直接渲染真的 `NotchLyricsView`):把
`LyricsOverlayView` 按新协议 `OverlayChromeSource` 泛型化,真窗口拿 `LyricsOverlayWindowController`
当 chrome,编辑台拿**不建窗**的 `OverlayPreviewChrome`。

⚠️ **不建窗是硬要求,不是优化**:`LyricsOverlayWindowController.shared` 是 `static let`,光是读一下
属性就会执行 `init()` 建窗并 `orderFront` —— 悬浮歌词关着的用户一打开设置页就会凭空多出一扇(不可见
但已经装好全局鼠标监听器和三个观察者的)窗。这跟 `NotchPreviewChrome` 存在的理由是同一条。

**`LyricsOverlayView` 侧的四处改动**(全部向后兼容,真窗口那唯一一个构造点一个字没改):

| 改动 | 为什么 |
|---|---|
| `struct LyricsOverlayView<Chrome: OverlayChromeSource>`,`overlayController` 类型换成 `Chrome` | 唯一的接缝:视图原来硬编码了具体类。四个 `@Published`(`isHoveringForControls`/`isHoveringLyrics`/`isDragArmed`/`showDragHint`)控制器本来就有,写 conformance 只是把契约显式化 |
| `PlaybackCoordinator.shared.refreshFavorited()` → `overlayController.controlsDidBecomeVisible()` | 这是视图里**唯一**一处真副作用(起 osascript 子进程读 favorited)。真控制器实现、预览空实现,同 `NotchChromeSource.setExpanded` |
| 新增 `showsDebugHUD: Bool = true` | 调试 HUD(`np:debugHUD`)会在设置页上画 fps 角标,还让 `frameProbe` 每帧 tick。编辑台传 false |
| 新增 `previewLine: OverlayPreviewLine? = nil`,收口成 `line` / `showingPreviewLine` / `nextLineText` 三个计算属性 | 没在播放时真视图走 `mainLine` 的占位分支(♪/「搜索歌词中…」/「暂无歌词」),设置页里就是一张空卡,而"改文字色能当场看见"正是这块预览存在的全部理由。⚠️ 必须**收在一个** `line` 计算属性上、而不是只在 `mainLine` 里挑一次:译文/罗马音/逐词分组/对唱声部/换行缓存 key 读的都得是同一行 |

另外把 `speakerBarHeight` / `speakerIndicatorWidth` 两个 `private static let` 搬到文件级的
`OverlaySpeakerIndicator` 里 —— Swift 不允许**泛型类型**持有 static 存储属性,数值和取舍一个字没变。

**编辑台侧跟着改的三处几何**:

| 项 | 之前 | 现在 |
|---|---|---|
| 卡高 | `max(120, OverlayPreviewBar.rawCardHeight)`(`fontSize * 1.5 + 28`) | 真视图报的内容高度,`min(max(120, ceil(h)), maxCardHeight)` —— `max(120, ceil(h))` 跟真窗口 `updateHeight` 逐字同口径 |
| 舞台高度 | 246,卡片居中在整块舞台里 | **288**,下半部留一条 44pt 的通道给宽度调整条,卡片只在 `cardAreaHeight`(244)那一格里居中(`inCardSlot`)⚠️ 244 这个数**第九步被推翻**:它比真窗口当时的 269 还矮,卡底连译文/下一句一起被裁,见下 |
| 文字命中带 | 按"字号 × 1.5、卡宽 − 40"估的一条横带 | 真视图报上来的 `onLyricsTextRectChange`(主歌词 + 罗马音 + 译文 + 下一句的**并集**,已用 `WrapContentRectSink` 修正过"`WrapLayout` 撑满整宽会把左右空白算成歌词")—— 那正是真窗口给「指针划过时让开」当判据的同一份矩形。⚠️ **这一行第十步作废**:命中区删了,编辑台不再消费这个回调;真视图那头照旧上报,真窗口还靠它 |

⚠️ **舞台高度必须是常量,不能跟着卡高自适应**:换行是宽度的函数,舞台高度一旦间接依赖 `overlayWidth`,
拖宽度调整条时整张壁纸就会跟着上下动 —— 那正是第七步刚修掉的「背景永远不要变」。装不下的极端组合
(36pt 字号 + 三行全开 + 换行)由 `maxCardHeight` 夹住 + 卡片自己 `.clipped()`。
⚠️ 这条约束本身没错,错的是当时那个 288 **是拍出来的**,而"36pt + 三行全开 + 换行"实测要 265.5pt,
`maxCardHeight` 只有 244 —— 于是"极端组合"变成了"日常组合",天天被裁。第九步用实测值重定了这个常量。
整块编辑台的 `totalHeight` 同样仍是常量:它挂在可滚动内容区里,一变高下面所有卡片都会跳一下,而开关
译文/罗马音恰恰会改卡高。

**命中区与真视图的手势如何共存**(⚠️ 命中区第十步已删,这一段只剩"真视图不接任何事件"这半边还有用):
真视图**一个手势都没有** —— 没有 `Button`(`iconButton` 的注释
明说"挂 Button 只会留下永不触发的死代码",点击由控制器按上报矩形自己分发)、没有 `onTapGesture`、
没有 `.gesture`、没有 `.onHover`,全文只有三处 `allowsHitTesting`。编辑台那两块命中区是挂在它外面的
`.overlay`,层序在上,tap/hover 照收不误。唯一能接事件的 `playbackControls` 槽位是
`.allowsHitTesting(controlsVisible)`,而预览 chrome 的 `isHoveringForControls` 恒 false,连命中形状
都不存在。

⚠️ **预览 chrome 的 `isHoveringLyrics` 绝不能接命中区的 hover**:真视图对它的反应是整卡淡到 15%
(「指针划过时让开」),而用户把指针移上去正是为了点开「文字…」浮层,一碰就消失跟编辑台的语义直接
打架。「划过让开」的演示另有明确入口(行为栏那颗「预演」按钮 → `isFadePreviewActive` → 卡片淡到
25%),而且那颗按钮**不受**「划过让开」开关门控 —— 关着也能看一眼,这也是不复用真视图那条淡出路径
的第二个理由(真窗口是 0.15,这里是设计稿定的 0.25)。
⚠️ 命中区和「预演」按钮第十步都删了,但**这条禁令本身升级成了通则**:编辑台里不许有任何东西驱动
`isHoveringLyrics` —— 一接就是"想点它、它就躲"。见第十步的坑清单第 1 条。

⚠️ **预览恒不画播放控制排**(`isHoveringForControls` 恒 false)—— 这条**意图**没变,但第八步的实现
**没有真的做到**:那排按钮在设置页里照样整排画了出来(液态玻璃穿透 `.opacity(0)`,第九步查清并修掉,
见下)。原本的理由仍然成立:那排按钮在编辑台里画得出来、**点不动**
(点击分发长在控制器的鼠标监听器上,预览没有那套),画一排点不动的按钮比不画更误导。槽位本来就是
常驻的,所以画不画都不影响卡片高度和歌词位置。这是本次唯一一处"预览比真窗口少一点能力"。

**逐项同源对照**(这一步的验收口径):

| 项 | 编辑台现在 |
|---|---|
| 译文 / 罗马音(整行)/ 逐词罗马音 / 下一句预览 | 同源(真视图 `lyricsCard` / `karaokeLineContent` 原样) |
| `WrapLayout` 自动换行 + contentKey 缓存 | 同源 |
| 对唱分声部(两侧内缩、左右对齐、声部指示圆点、下一句 insets 补偿) | 同源 |
| 逐字卡拉OK填色(30Hz `TimelineView` + 静态描边 mask) | 同源 |
| 描边 / 「对齐方式」覆盖 / 字体 / 字号 / 前景色 / 跟随封面 / 背景色与圆角 | 同源 |
| 六种占位状态(广告/纯音乐/无歌词/断网/搜索中/♪) | 同源,但**没在播放时优先画示例行**(`previewLine`,排在这六条之前) |
| 高度自适应 | 同源口径(`max(120, ceil(h))`),另加编辑台自己的上限夹持 |
| 播放控制排 / 解锁提示 / 拖动武装描边 / 手势提示 | 槽位与真窗口一致,但恒不显示(chrome 四个状态恒 false),见上 |
| 点击穿透、长按拖动、随屏幕定位 | 不适用 —— 那些长在窗口控制器上,不在视图里 |

⚠️ **`OverlayLyricsCanvas` 一个字都没动、也不许删**:顶部钉条 `OverlayPreviewBar` 还在用它,那条的
渲染必须逐像素不变。钉条的处境跟编辑台完全不同(只有 520pt 可用、要等比缩小、高度必须固定,否则拖
字号滑杆会让整页抖动),真视图那套"内容自撑高度 + 自动换行"在它身上直接用不了。这一步只改了那个文件
里的**注释**(标明它现在只剩钉条一个消费方),`OverlayPreviewBar.swift` 同理 —— 两个文件的代码一个
字节都没动,钉条逐像素等价。第七步那张渲染分工表里"`OverlayLyricsCanvas`(编辑台这一路)"那一行
随之作废,取而代之的是真视图自己画背景色圆角块/文字/描边/逐字填色。

**新增文案**(已跑 `generate-strings.py`):`这里是罗马音示例` / `这里是译文示例` /
`这里是下一句歌词示例`(示例行原来那句 `这里是一句歌词示例` 复用不变)。三条写成**自我说明**的句子
而不是伪造的拼音/外文 —— 这里要预览的是那三行各自的字号(主字号的 0.65x/0.7x/0.7x)和不透明度
(0.6/0.75/0.4),"这一行是什么"直接写出来比让人猜更省事。

**保留没动**:1:1 真实尺寸(caption 那句「实际大小」)、整块舞台一张固定壁纸(表达式不依赖
`overlayWidth`)、宽度调整条的位置与三条落点规则(相等守卫 / `classicOverlayEnabled` 守卫 /
`snap` + `widthRange`)、背景透明时那圈常驻虚线轮廓、超宽时居中裁切 + 两端渐隐 + 「两端已裁切」、
工具栏(文字…/配色…/重置 ▾)与当前值摘要、两块命中区的语义(点文字→文字浮层、点背景→配色浮层、
窗外桌面不接事件)、锁标、「预演」。(⚠️ 这一句里的"两块命中区"和"「预演」"第十步已删,其余仍然成立。)


### 第九步:补足编辑台高度 + 修掉"凭空多出一排播放控制按钮"

2026-08-30 用户第六轮反馈,原话:「现在翻译这些看不到是因为高度不够吗,帮我高度也正常展示出来」。
连带查清了另一个**代码上看不出来**的问题:编辑台里那排播放控制按钮(⏪ ⏸ ⏩ ｜ ⤢ 🔓 ⚙ ✕)其实一直
是可见的。

#### 9.1 高度:`maxCardHeight` 从 244 抬到实测的 288

**病根是第八步的推导方向反了**:那一步先拍了一个 288 的舞台高度,再减去 44pt 的调整条通道,倒推出
卡片那一格只有 244 —— 而真悬浮窗当时是 **450×269**,比这一格还高 25pt。卡片一超过 244 就被
`maxCardHeight` 夹住 + 舞台的 `clipShape` 裁掉底边,译文/下一句/换行出来的第二行统统看不见,窗口那圈
常驻虚线轮廓也在底部断开(用户截图里能直接看到)。

**这一步把推导方向倒过来**:`maxCardHeight` 成为这一段几何的源头,`stageHeight = maxCardHeight +
widthBarLaneHeight`,值取**实测的最坏情况**。

**实测方法**(不是估算):在 App 里挂一个临时探针(用完即删),把真 `LyricsOverlayView` 装进
`NSHostingView`、按不同设置读 `fittingSize.height` —— 也就是真窗口 `updateHeight` 消费的同一份内容
高度。设置通过一个**隔离的 UserDefaults 域**注入(非 bundle 进程的 `UserDefaults.standard` 落在
`lyrimuse` 域而不是 `me.yudaotor.lyrimuse`),不碰用户真实配置。

罗马音 + 译文 + 下一句三行全开、附属三行各占一行时:

| 主歌词行数 | 20pt | 31pt | 36pt |
|---|---|---|---|
| 1 行 | 167.5 | 206.5 | 222.5 |
| 2 行(一次换行) | 191.5 | 243.5 | **265.5** |
| 3 行 | 215.5 | 280.5 | 308.5 |

逐词罗马音(日文那种标在每个词底下的,整行罗马音那一行随之消失)+ 译文 + 下一句:

| 主歌词行数 | 20pt | 31pt | 36pt |
|---|---|---|---|
| 1 行 | 158.5 | 197.5 | 213.5 |
| 2 行(一次换行) | 242.5 | 260.5 | **286.5** |
| 3 行 | — | 323.5 | 359.5 |

三个开关全关时的下限:20pt 91.0 / 31pt 104.0 / 36pt 110.0 —— 都低于 120pt 的地板,`cardHeight` 那句
`max(120, …)` 兜住,跟真窗口同口径。

⚠️ **最关键的一条实测结论:同一份内容、同一个换行行数下,内容高度跟 `overlayWidth` 完全无关**
(420 / 450 / 640 / 1000 四档量出来一模一样)。宽度只决定"换不换行",不决定"一行多高"。所以拿"最坏
行数"定一个常量,既装得下,又不会让舞台高度间接依赖窗宽 —— 第七步的「背景永远不要变」不受影响。

**取值 288**:字号上限是 36(「文字…」浮层那根滑杆 `in: 14...36`),286.5 就是"能被单次换行撞到"的
天花板,向上留 1.5pt 余量。于是 `stageHeight` = 288 + 44 = **332**(第八步是 288)。

**取舍**:整块编辑台因此比第八步高 44pt,这一段的总开关和行为栏会更靠下。选择接受,因为
① 288 覆盖了三个显示开关的**全部**组合 × 全字号 × 一次换行,也就是用户实际会遇到的整个空间;
② 编辑台是这一段的主编辑面,它被裁掉内容比多滚一屏严重得多;③ 再往上抬只能换来"两次以上换行"这种
越来越罕见的组合,不值当。还装不下的照旧溢出、由 `clipShape` 裁底边 —— 那比让卡片压住宽度调整条、
或者让舞台高度跟着内容跳要好。

⚠️ **这条取舍 2026-09-03 被朝反方向拍了一次**(第十八步):`maxCardHeight` 288 → **266**、
`stageHeight` 332 → **310**,连同删掉舞台底下那行 caption 合计 −43pt。上面 ① 那句"覆盖全部组合"
因此不再成立 —— 现在只有「36pt + 逐词罗马音 + 译文 + 下一句 + 主歌词两行」(286.5)这**一个**组合
溢出 20.5pt 被裁。翻案的依据是这一步没算的那笔版面账:288 的舞台把「桌面悬浮歌词」总开关卡的底边
推到了可视内容之外(用户原话「把下面的开关完整漏出来」),详见第十八步。

#### 9.2 播放控制排:液态玻璃穿透了 `.opacity(0)`

**症状**:编辑台里那排播放控制按钮整排可见(连胶囊带 8 个图标),而**真悬浮窗完全正常**(不悬停就
不显示)。

**代码上完全看不出来**:`OverlayPreviewChrome.isHoveringForControls` 是 `let false`;
`controlsVisible = isHoveringForControls && !lockPosition`;`playbackControls` 全文只用一处,带
`.opacity(controlsVisible ? 1 : 0)` 和 `.allowsHitTesting(controlsVisible)`。协议里没有默认实现,
泛型特化也确实是 `OverlayPreviewChrome`,`unlockPill` 分支同样是 `.opacity(0)`。

**定位过程**(单变量对照,不是猜):

1. 把真 `LyricsOverlayView` 单独装进一个裸 `NSHostingView` 窗口 → 控制排**不显示**(对);
2. 把 `OverlayEditorStage` 整块装进同一个裸窗口 → 仍然**不显示**(对);
3. 把同一个 `OverlayEditorStage` 装进真的 `SettingsView()` 里 → 控制排**整排显示**(复现);
4. 回到 ② 的裸窗口,**只加一层** `SettingsGlassContainer(spacing: 0)`(= `GlassEffectContainer`)
   包住编辑台,别的一个字不改 → 控制排**整排显示**。

**根因**:`GlassEffectContainer` 会把它内部**所有**带 `.glassEffect` 的子树收拢进容器自己那一趟玻璃
渲染(那正是容器存在的意义:多块玻璃共享采样、靠近时互相融合),而容器与玻璃视图**之间**那一层
`.opacity` 在这趟渲染里不生效 —— 连玻璃托着的内容(这排图标)一起原样画出来。链路是:

- `playbackControls` → `.overlayCapsuleBackground()` → macOS 26+ 走 `.glassEffect(...)`;
- `SettingsPage` 把整页内容包在 `SettingsGlassContainer(spacing: 0)` 里(见
  `Settings/SettingsDesignSystem.swift`),编辑台就在这块内容里;
- 真悬浮窗是自己的 `NSHostingView`,祖先里没有任何玻璃容器 —— 所以同一份代码在那边一直是对的。

这也解释了为什么"二进制过期""真窗口盖上去"两条都被排除之后仍然看得见:它根本不是逻辑分支的问题,
`controlsVisible` 自始至终是 `false`。

**改法**:玻璃这一层跟着可见性一起关掉,不再指望调用方在外面套 `.opacity(0)` 把它藏起来 ——
`overlayCapsuleBackground(visible:)`,`playbackControls` 传 `controlsVisible`、`unlockPill` 传
`unlockPillVisible`。可见那一档的修饰符链跟改动前逐字一致,真悬浮窗的观感一个像素没变;不可见那一档
直接返回 `self`,而玻璃和它那圈描边都不参与布局,**槽位尺寸不变**——常驻槽位那条设计(歌词位置不随
悬停跳动)照旧成立。

⚠️ 这台机器的 SDK 上没有 `glassEffect(_:in:isEnabled:)`,只能用 `if visible` 两个分支,代价是切换那
一下玻璃层换了视图身份;它落在 `body` 那条 `.animation(_:value: controlsVisible)` 的事务里,SwiftUI
给默认的淡入淡出,跟图标那半边同一档时长。

⚠️ **通用教训**:在这个仓库里,`.glassEffect` 视图**不能靠祖先的 `.opacity` 隐藏** —— 只要它可能被
装进设置页(`SettingsPage` 的整页内容都在玻璃容器里),隐藏就必须落在玻璃自己身上。

⚠️ ~~**探针的一个已知局限**(避免后人重复踩):上面那套临时探针进程里,
`onPreferenceChange(ContentHeightPreferenceKey)` 恒收到 `0`(而同一轮渲染里那个 `GeometryReader` 明明
量到了 206.2),即使把宿主搭成跟真悬浮窗**逐项一致**(裸根视图 / `sizingOptions = []` /
`autoresizingMask` / 真 bundle id / release 构建)也一样。而真 App 里这条通道是活的(实测同一天悬浮窗
高度在 269 → 238 → 177 之间跟着内容变)。所以那是探针进程(跳过整个 `applicationDidFinishLaunching`
的精简启动路径)的产物,**不能**拿探针截图里的卡片高度当编辑台的行为证据 —— 9.1 的依据是
`fittingSize`(不走 preference)和用户截图里"虚线轮廓底边被舞台裁断"这个只有 `cardHeight > 244` 才
可能出现的现象。~~

⚠️⚠️ **上面这条结论是错的,第十一步推翻了它**(留着是为了留住"把真 bug 判成环境噪声"这次教训)。
`onPreferenceChange` 收到 `0` 不是探针进程的产物,是 `ContentHeightPreferenceKey` 的 `reduce` 写成了
覆盖式 `value = nextValue()` —— 真实高度被别的分支贡献的 `defaultValue`(0)冲掉。同一套探针里把那一行
换成 `max` 就立刻收到 206.2(单变量对照,四个宿主一致)。判据本身没错(9.1 用的是 `fittingSize`,不走
preference),错的是**归因**:探针如实复现了一个真 bug,却被当成环境噪声放过了整整两步。详见第十一步。

**保留没动**:第八步那份"逐项同源对照"整表、1:1 真实尺寸、整块舞台一张固定壁纸(表达式不依赖
`overlayWidth`)、宽度调整条的位置与三条落点规则、常驻虚线轮廓、超宽裁切与两端渐隐、两块命中区的
语义(⚠️ 命中区第十步已删)、`OverlayPreviewBar` 的三个静态量(`SectionPreviewMetrics` 契约,这一步没碰
`OverlayPreviewBar.swift` / `OverlayLyricsCanvas.swift` 一个字节)。


### 第十步:删掉画布命中区与「预演」按钮(纯删除)

2026-08-30 用户第七轮反馈,原话:「点背景和点文字的交互去掉;……这些都去掉」(配图圈掉了编辑台画布上
那两块命中区,以及行为栏里的三处文案 + 一颗按钮)。这一步**只删不改**,没有把任何东西"改良"成别的形式。

**删掉了什么**

| 删掉的 | 在哪 |
|---|---|
| 两块画布命中区(点歌词→文字浮层、点背景→配色浮层) | `OverlayEditorStage`:`hitZones` / `textHitRect` / `zone(_:tap:)` / `StageHitZone` / `hoveredZone` |
| 悬停虚线框 + 提示标签 | 同上:`hints(visibleWidth:textRect:)` / `hintLabel(_:maxWidth:)` |
| 命中区的 hover 状态与手型光标 | 同上:`hoveringText` / `hoveringBackground` / `pushedPointingHand` / `syncPointingHand()` |
| 编辑台这一侧对文字矩形的消费 | 同上:`lyricsTextRect` 状态 + 传给真视图的 `onLyricsTextRectChange` 闭包 |
| 浮层的第二个锚点 | 同上:`StagePopover.Anchor`(枚举退化成 `case text` / `case color`)、画布上那两份 `.popover` |
| 「行为」栏标题旁那句说明 | `OverlayBehaviorBar.header` 里的「这些改动在编辑台上看不出来,所以留在这儿」 |
| 「锁定位置」那格的小字 | `OverlayBehaviorItem.barCaption` **整个属性** —— 另外两项本来就只是返回 `subtitle`,少了这一句它就没有存在理由了 |
| 「拖动前先长按」的副标题 | `OverlayBehaviorItem.subtitle` 的那一支改成 `nil` |
| 「预演」按钮与它的状态机 | `OverlayBehaviorBar.previewButton` / `onPreviewFade`;`AppearanceSettingsTab.overlayFadePreviewActive` / `overlayFadePreviewTask` / `playOverlayFadePreview()`;`OverlayEditorStage.isFadePreviewActive` 入参 + `fadePreviewOpacity` / `fadePreviewRampSecs` / `fadePreviewHoldSecs` |

**删掉的 L10n 键**(从 `Localizable.xcstrings` 移除后重跑了 `Localization/generate-strings.py`,870 → 864):
`点文字 · 改字体 / 字号 / 双行 / 对齐`、`点背景 · 改配色`、`这些改动在编辑台上看不出来，所以留在这儿`、
`锁上后编辑台左下角会出现锁标`、`关闭时按住歌词就能拖；打开则要长按 0.35 秒`、`预演`。删前逐个 grep 过,
六个键都只有被删的那一处在用。

**没删的(每一条都是刻意的)**

⚠️ **工具栏上「Aa 文字…」「◐ 配色…」两个入口保留** —— 命中区删掉之后它们是两个浮层**唯一**的入口
(第十三步起是三个:又加了「≣ 排版…」)。
这条从第二步起就写着:命中区靠 hover 才看得见、键盘和 VoiceOver 根本够不着,显式入口一直是主路径而非
兜底,所以删掉快捷方式没有留下任何够不到的设置。

⚠️ **锁标(`OverlayEditorStage.lockBadge`)保留**。介绍它的那句小字删了,但它是「锁定位置」在编辑台上
唯一的真实反馈 —— 删掉解释不等于删掉被解释的东西。

⚠️ **`LyricsOverlayView` 上报 `onLyricsTextRectChange` 那一头一个字没动**:真窗口的「划过让开」还拿它
当命中判据(`LyricsOverlayWindowController.updateLyricsHotZone`)。这一步删的只是编辑台这个**消费方** ——
那个回调本身有默认值 `{ _ in }`,不传即可。

⚠️ ~~**「划过让开」的副标题「鼠标移到悬浮歌词上时它会淡下去,移开恢复」保留**(用户没有圈它)。~~
**第十二步删了**,连带 `OverlayBehaviorItem.subtitle` 整个属性 —— 见下面第十二步。

⚠️ 上面第四/五/六步里那条"**固定黑底白字 + 投影、不跟深浅色模式走**"的配色老规矩,当年是拿 `hintLabel`
当参照写的,而 `hintLabel` 随命中区一起删了。规矩本身没变、也仍然必须遵守(这些东西底下垫的是用户真实的
桌面壁纸,那块底色 App 完全控制不了,语义色在浅壁纸上直接读不出来),现在的活参照是 `lockBadge` /
`widthBar` / `windowEdgeOutline` 三个 —— 在那几段里看到 `hintLabel` 就照着这三个理解。

**结论性的坑,随代码一起搬到这里**(实现已经没了,别让它们跟着消失):

1. **预览 chrome 的 `isHoveringLyrics` 绝不能接编辑台上的任何 hover。** 真视图对它的反应是整卡淡到
   15%(「指针划过时让开」),而用户把指针移上去正是为了操作 —— 一碰就消失就是"想点它、它就躲"。
   命中区(第二步)和「预演」按钮(第三步)当年都刻意绕开了这条路径,现在两者都删了,更没有理由接回来。
2. **重叠的两块命中区,悬停状态必须两个独立 Bool 再派生。** 文字带压在背景之上,指针从文字带滑回背景时
   文字区收到 `hover(false)`、背景区不会补发 `hover(true)`,写成单个 `@State var hovered: Zone?` 会停在
   nil,表现是"从歌词上挪开之后虚线框就再也不出现了"。
3. **`NSCursor` 的 push/pop 计数状态,判据是"会不会同时把指针算作在自己里面",不是"有几块区域"。**
   重叠区域共用一个计数(各记一份会漏 pop,整个 App 的光标永久卡在手型上);不重叠区域各记各的
   (共用一个的话,指针从左握柄直接滑到右握柄会漏掉一次 pop)。命中区是前者,第六步删掉的两个宽度握柄
   是后者 —— 两个方向本仓都踩过。
4. **提示层(虚线框 + 标签)必须 `.allowsHitTesting(false)`。** 压在命中区上面的话,指针一移到标签上就
   等于离开了命中区,hover 会抖成 false/true 的死循环。
5. **条件渲染的命中区被摘出视图树时,`.onHover` 不会补发一次 false。** 文字命中区在文字矩形还没量到时
   整块不画,不在它自己的 `.onDisappear` 里清一次,悬停状态会永久停在 true —— 外层那条 `.onDisappear`
   只在整块命中区消失时才跑,盖不住"只摘掉其中一块"。
6. **`clipShape` 只裁"画",不裁命中测试。** 超宽时卡片两端已经在舞台外面,可交互件必须自己收到
   `visibleCardWidth` 里,否则用户点在编辑台外面的页面空白上也会弹出浮层。`visibleCardWidth` 这个函数
   留着 —— 现在的作用对象只剩左下角那个锁标的 `clippedInset`。

**行为栏与抽屉是同一份组件,两个宿主一起受影响**(这是单点真源的预期代价,已确认版式没塌):

- 抽屉里那三行标准设置行(`OverlayBehaviorSettingsRows` → `SettingsRow`):「锁定位置」本来就走
  `subtitle == nil` 那条分支,「拖动前先长按」现在跟它一样,只是行高矮一档;ⓘ 帮助气泡不受影响。
- 编辑台下面那条三列小格:小字改成 `if let subtitle = item.subtitle` 条件渲染,**不是**画一个空 `Text`
  —— 空 `Text` 照样占一整行行高,另外两格会平白多出一条空隙。三格等高仍由
  `.frame(maxWidth: .infinity, maxHeight: .infinity)` 保证,只是"最高的那一格"从"标题 + 小字 + 预演按钮"
  变成了"标题 + 小字"(仍是「划过让开」那一格),另外两格只剩标题 + 开关。
  ⚠️ 第十二步删掉最后一句副标题之后,这一格的条件渲染连同外面那层 `VStack` 一起没了(三格同构、
  每格就是一行),上面这段留作史料;`maxHeight: .infinity` 那一句仍在。

**保留没动**:第一到第九步打磨出来的东西一个没丢 —— 编辑台渲染真 `LyricsOverlayView`、1:1 真实尺寸、
整块舞台一张固定壁纸(表达式不依赖 `overlayWidth`)、宽度调整条及其三条落点规则(相等守卫 /
`if settings.classicOverlayEnabled` 守卫 / `snap` + `widthRange`)、背景透明时的常驻虚线轮廓、超宽居中
裁切 + 两端渐隐 + 「两端已裁切」、工具栏与当前值摘要、`maxCardHeight = 288` / `stageHeight = 332` 那套
实测高度、以及第九步那个"玻璃容器会把 `.glassEffect` 子树从 `.opacity(0)` 底下捞出去"的修复。
`OverlayPreviewBar.swift` / `OverlayLyricsCanvas.swift` 这一步同样一个字节都没碰。



### 第十一步:编辑台的译文/下一句回来了 —— 病根是内容高度那条 preference 的 reduce

2026-08-30 用户第八轮反馈,原话:「编辑台里只画出主歌词 + 罗马音,没有译文、没有下一句预览」;同一时刻
用 `screencapture` 截真悬浮窗(450×267)四层俱全 —— 主歌词(韩文换行两行)、罗马音、译文、下一句。
三个开关都是开的(`np:showTranslation` / `np:showRomanization` / `np:showNextLinePreview` 全 = 1)。

#### 11.1 先排除掉那个"看起来最像"的嫌疑

现场最像的一条线索是 `LyricsOverlayView` 里 `@StateObject private var playback = OverlayPlayback()`
**每个视图实例各新建一份**,而 `OverlayPlayback.showTranslation` 的默认值恰好是 `false`
(`showRomanization` / `showNextLinePreview` 默认 `true`)——"罗马音出来了、译文没出来"跟这组默认值
严丝合缝。**实测把它否掉了**:在编辑台那份真视图的 `lyricsCard` 里把四个判据原样打出来,三个宿主
(裸编辑台 / 设置页外壳 / 真窗口克隆)读到的全是

```
showRomanization=true  roma=这里是罗马音示例
showTranslation=true   translation=这里是译文示例
showNextLinePreview=true nextLineText=这里是下一句歌词示例
```

也就是说**三行的 `if` 条件全部成立、三行都在视图树里**。`@Published` 的 publisher 在 subscribe 那一刻
就会把当前值发给新订阅者,`removeDuplicates()` 没有"上一个值"可比,首个值一定过得去 —— 那条订阅从来
没坏过。

⚠️ 教训:`OverlayPlayback` 那组"默认值刚好对上现象"的巧合极具误导性,下次遇到同类现象**先打判据、
再查订阅**。

#### 11.2 判据全成立、却画不出来 —— 只可能是被裁掉了

三行都在树里而屏幕上没有,唯一的出口是编辑台给那张卡套的 `.frame(height: cardHeight)` + `.clipped()`。
`cardHeight = min(max(120, ceil(overlayContentHeight)), 288)`,于是问题变成:`overlayContentHeight` 是多少?

用探针进程(裸 `NSHostingView` + 真视图,四个宿主:A 裸真视图 / B 裸编辑台 / C 编辑台装进
`ScrollView + GlassEffectContainer` 的设置页外壳 / D 逐项复刻真悬浮窗的宿主)同时打两个数:

| 宿主 | `GeometryReader` **量到**的 | `onPreferenceChange` **收到**的 |
|---|---|---|
| A 裸 `LyricsOverlayView` | 206.2 | **0.0** |
| B 裸编辑台 | 206.2 | **0.0** |
| C 设置页外壳(玻璃容器 + 滚动) | 206.2 | **0.0** |
| D 真悬浮窗宿主克隆(`previewLine` 传 nil) | 103.8 | **0.0** |

`cardHeight` 因此恒为 `max(120, ceil(0))` = **120pt**,卡片被摁在地板高度上,`.clipped()` 把译文和
下一句整个裁掉 —— 编辑台截图与用户描述**逐项吻合**:主歌词 + 罗马音在,译文/下一句没有,卡片下面
一直空到宽度调整条。

#### 11.3 根因:`ContentHeightPreferenceKey.reduce` 是覆盖式的

```swift
// 改前
static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
```

全树只有一处真的设过这个 key(`body` 里那个测高度的 `GeometryReader`),**其余每一个分支都在贡献
`defaultValue`(0)**。覆盖式写法的结果取决于"谁排在最后",0 排在后面就把真实高度冲掉。

**这是同一个坑在这个文件里的第三例** —— `ControlsFramePreferenceKey`(2026-08-07)和
`ControlRectsPreferenceKey` 都因为同一个原因改掉了 `value = nextValue()`,各自的注释里都写着
"树里没设过这个 key 的分支会贡献 defaultValue、排在后面就会把真实值冲掉";内容高度这条当时漏改了。

**改法**(单变量,别的一个字没动):

```swift
static let defaultValue: CGFloat = 0            // 顺手从 static var 收成 let,跟另外两个 key 一致
static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
```

**验证**(同一套探针,只改这一行):四个宿主收到的立刻从 `0.0` 变成 `206.2` / `103.8`,编辑台
`cardHeight` 从 120 → **207**,截图里译文和下一句同时回来。再让它动态跟随:运行中关掉译文 + 下一句,
量到的高度 206.2 → 136.6、卡高 207 → 137;开回来又回到 206.2 / 207 —— 内容变矮时照样报得下去。

为什么取 `max` 而不是"跳过零值再覆盖":本 key 只有一个写入方,`max` 与"那唯一一次写入的值"恒等;
而每一趟布局都是从 `defaultValue` 重新归约的,不会记住上一趟的旧值,所以内容变矮不会被卡住。

#### 11.4 真悬浮窗与钉条为什么零影响

- **真悬浮窗**:它消费的是同一条 preference(`onContentHeightChange` → `updateHeight` →
  `max(overlayDefaultHeight, ceil(h))`)。改动只可能让它收到**更大或相等**的值,而且那个值恒等于
  这一趟渲染里 `GeometryReader` 真正量到的高度 —— 原来就归约正确的那些趟,值一模一样、窗口几何逐像素
  不变;原来被 0 冲掉的那些趟,窗口本会被摁到 120pt 的地板上,现在拿到真高度,只可能是修正。
  探针里那扇"真悬浮窗克隆"(`previewLine` 传 nil、没在播放)按同一口径算出 `max(120, ceil(103.8))` =
  **120pt**,正是 `overlayDefaultHeight`,与现状一致。
- **顶部钉条(`OverlayPreviewBar` / `OverlayLyricsCanvas`)**:这一步一个字节都没碰,而且它们**根本不
  订阅这个 key** —— 钉条的高度走 `SectionPreviewMetrics` 那套静态契约(`fontSize * 1.5 + 28`),跟内容
  高度这条通道没有交集。
- **`OverlayPlayback`**:一个字都没改(11.1 已证明它是无辜的),所以"真窗口也在用的类型"这条风险这次
  根本没被触碰。

#### 11.5 卡高

`cardHeight` 的公式本身从第八步起就是对的(`min(max(120, ceil(h)), 288)`),这一步只是让喂给它的数变
真实,没有改公式、也没有动 `maxCardHeight = 288` / `stageHeight = 332` 那套实测几何。修好之后卡片
**等于真实内容高度**(实测 207pt / 137pt 两档),不再在内容不足时把整格 288 占满;舞台高度仍是常量、
仍然与 `overlayWidth` 无关,第七步的「背景永远不要变」不受影响。

**保留没动**:第一到第十步的成果一个没丢 —— 编辑台渲染真 `LyricsOverlayView`、1:1 真实尺寸、整块舞台
一张固定壁纸、宽度调整条的三条落点规则(相等守卫 / `if settings.classicOverlayEnabled` 守卫 /
`snap` + `widthRange`)、背景透明时的常驻虚线轮廓、超宽居中裁切 + 两端渐隐 + 「两端已裁切」、工具栏与
当前值摘要、左下角锁标、**没有**画布命中区也**没有**「预演」按钮、第九步那个
`overlayCapsuleBackground(visible:)` 的玻璃修复、以及"绝不碰 `LyricsOverlayWindowController.shared`"
这条硬约束(`OverlayPreviewChrome` 原样)。

### 第十二步:删掉四处文案 + 修掉内联确认行里被挤没的按钮

两件互不相干的事,一次做完:一批纯删除,和一个真 bug。

#### 12.1 删掉的四处用户可见文案(纯删除)

| 删掉的 | 位置 |
|---|---|
| 「在当前句下方多显示一句」 | 「双行显示」那一行的副标题(当时在 `OverlayTextSettingsRows`,第十三步起在 `OverlayLayoutSettingsRows`) |
| 「鼠标移到悬浮歌词上时它会淡下去,移开恢复」 | 「划过让开」的副标题(`OverlayBehaviorItem.subtitle`) |
| 「键盘 / VoiceOver 的全量兜底通路,跟编辑台改的是同一份设置」 | 「全部设置」抽屉**展开**时标题右边那句 |
| 「系统字体 31pt · 跟随封面 · 486pt」 | 「全部设置」抽屉**折叠**时标题右边那串当前值摘要 |

**连带清掉的两处死代码**(删掉展示处之后就再没有消费方,留着只会让下一个人以为"这里还能配一句"):

- `OverlayBehaviorItem.subtitle` **整个属性**。三项到此一句常显说明都不剩,恒为 `nil`;两个宿主里消费它
  的分支一并清了 —— 抽屉那边的 `SettingsRow(subtitle:)` 实参去掉,行为栏那边连同外面那层 `VStack`
  (标题行 + 可选小字 + 顶住上边的 `Spacer`)一起收成一个裸 `HStack`。不收的话每格底下会多垫一段
  `spacing + Spacer` 的空白,看着像"这里本该还有一句话没画出来"。三格等高的
  `.frame(maxWidth: .infinity, maxHeight: .infinity)` **保留**:代价为零,而失效是静默的。
  ⚠️ 「锁定位置」的 ⓘ 帮助气泡(`help`)**保留** —— 它交代的是解锁后点击会穿到桌面上,不是装饰。
- `OverlayStyleSummary.overview`。`text` / `color` 两截仍在用(编辑台工具栏「Aa 文字…」「◐ 配色…」
  两颗按钮上的摘要),只删拼装那一层。

抽屉头那一行现在只剩三角形 + 「全部设置」四个字。⚠️ 其中的 `Spacer(minLength: 0)` **不是残骸**:整行可点
靠的是 `contentShape(Rectangle())`,而它认 `HStack` 的实际尺寸 —— 没有 `Spacer` 撑满宽度,命中区就缩回
"三角形 + 两个字"那一小截。

**删掉的 L10n 键**(从 `Localizable.xcstrings` 移除后重跑 `Localization/generate-strings.py`,863 → 860):
`在当前句下方多显示一句`、`鼠标移到悬浮歌词上时它会淡下去，移开恢复`、
`键盘 / VoiceOver 的全量兜底通路，跟编辑台改的是同一份设置`。删前逐个 grep 过,三个键都只有被删的那一处
在用;第四处(当前值摘要)是派生拼装、本来就没有自己的键。

#### 12.2 修掉「保存」「取消」两颗空按钮

**现象**:点「存为新主题…」后长出来的那一行里,右边两颗按钮只剩空白圆角矩形,文字没了(用户原话
"右边这两个按钮是坏了吗")。

**根因不是 `.labelsHidden()`**。第一直觉是 `SettingsSubRow` 给尾部插槽统一套的那句 `.labelsHidden()`
把 Button 标题吃掉了(那句注释里本来就写着"放在这里的控件不能指望自己的 label 显示文字"),但离屏渲染
逐个变量排除的结果是:`.labelsHidden()` 只管 `Toggle`/`Picker` 那类自带 label 的控件,**按钮标题照显**;
`.buttonStyle(.glass)` 也无关 —— 四种组合(hidden×glass)全都是空按钮。

**真因是横向挤压**。`SettingsSubRow` 是"左边标题/说明、右边一组控件"的**单行**结构,两侧分同一份宽度;
而这一行的控件特别宽(130pt 输入框 + 两颗按钮),配色浮层又只有 380pt。SwiftUI 把不够的宽度按弹性摊给
双方,输入框那 130pt 是写死的、一分不让,于是整份亏空全压在两颗按钮上,它们被压成没有文字的空圆角矩形。
只给按钮加 `.fixedSize()` 同样不行:亏空会原样转嫁给左边那句说明,那段话被压成一列单字。

**修法**:这两行不再走 `SettingsSubRow` 的尾部插槽,改用本文件新增的 `OverlayInlineConfirmRow` ——
**说明占一行、控件另起一行**,谁都不用跟谁抢宽度,浮层再窄也挤不没。视觉沿用 `SettingsSubRow`:同一条
2pt 淡竖线、同样的 `textLeadingInset - 12` / `horizontalPadding` / `verticalPadding` 内边距。

⚠️ **删除确认那一行(「删除」「取消」)一并换过去**:它的标题是主题名 —— 用户数据、长度不设上限,留在
尾部插槽里迟早撞上同一个挤压。

⚠️ **`SettingsSubRow` 本身一个字节都没改**(只补了一段注释)。它是全设置页共用的行容器,改它的布局要
把每一页都重新验一遍;而这次要的只是"这两行别用它",没有任何理由动共用件。补的那段注释把这条坑写在
按钮身上 —— 原注释只提了 `Toggle`/`Picker`,所以才会有人在这里放按钮再踩一次。

**「套用」那一行不用改**:它的尾部只有一颗窄按钮 + 一个图标按钮,离屏渲染在 380pt / 560pt 两种宽度、
配一个长主题名的情况下都验过,文字完整。

**保留没动**:第一到第十一步的成果一个没丢 —— 编辑台渲染真 `LyricsOverlayView`、1:1 真实尺寸、整块舞台
一张固定壁纸、宽度调整条的三条落点规则(相等守卫 / `if settings.classicOverlayEnabled` 守卫 /
`snap` + `widthRange`)、`widthRange = 300...1400`、背景透明时的常驻虚线轮廓、超宽居中裁切 + 两端渐隐 +
「两端已裁切」、工具栏与摘要按钮、左下角锁标、`ContentHeightPreferenceKey` 的 `max` 归约,以及
"绝不碰 `LyricsOverlayWindowController.shared`"这条硬约束。

### 第十三步:「排版」从「文字」里拆出来

用户原话:「双行显示不应该挂在这个文字里面吧,是否应该是一个独立的开关呢;还有这个对齐方式也是,
不应该是子选项吧」。两条都成立:

- **分组错了**。字体、字号讲的是**字长什么样**;「双行显示」讲的是**显示几行内容**、「对齐方式」讲的是
  **摆在哪一侧** —— 后两者是版面不是字形。把它们塞进「文字」靠的只是"都跟文字有关"这种最粗的相关性,
  按这条相关性整页设置都能装进「文字」。
- **从属关系是假的**。「对齐方式」当时是缩进的 `SettingsSubRow`,视觉上从属于上面的「双行显示」;可它
  对单行同样生效,关掉双行显示之后照旧起作用。子行的缩进本身就是一句话("这是上一行的子选项"),
  没有这层关系就不该说。

**改法**:新增 `OverlayLayoutSettingsRows`(双行显示 + 对齐方式,两项**平级**,都用 `SettingsRow`)、
`OverlayLayoutPopover`,工具栏在「配色…」和「重置 ▾」之间插入第三个入口「≣ 排版…」(图标
`text.justify`),「全部设置」抽屉里原来的「文字」组同步拆成「文字」「排版」两组。摘要那截
`OverlayStyleSummary.layout` 例:「双行 · 自动」。

⚠️ **抽屉和浮层仍然是同一份组件**(`OverlayLayoutSettingsRows` 定义一处、引用两处)。这条从第二步起
就是硬约束,拆组不是重写的借口。

**新增 L10n 键**(4 个,加完重跑了 `Localization/generate-strings.py`,864 → 868):`排版`(Layout)、
`排版…`(Layout…)、`双行`(Two Lines)、`单行`(One Line)。

#### 两处宽度是量出来的,别凭感觉拉平

① **`OverlayAlignmentSegmentedControl` 必须加 `.fixedSize()`**,这是这一步查出来的**真 bug**,跟第十二步
那条挤压是同一族、机制不同。`SettingsRow` 那一行的 `HStack` 有三个可伸缩成员(标题列、`Spacer`、尾部
控件),SwiftUI 给它们**均分**剩余宽度,而不是"先按各自理想宽度发、多的给 `Spacer`";均分份额小于控件
理想宽度时,它就被压到自己的下限(4 × `minWidth` 56)。中文标签每个都短于 56pt、理想宽度正好等于下限,
所以看不出异常;英文标签("Left-Aligned")长于 56pt,于是在**行里明明还剩一大截空白**的情况下四个选项
被截成「Automa…」「Left-Ali…」—— 离屏渲染在 380 / 420 / 460pt 三档下都复现。加上 `.fixedSize()` 之后
控件按理想宽度落位,剩下的才轮到标题和 `Spacer` 去分。代价是亏空转嫁给标题(宿主太窄时标题换行),
这正是要的取舍:标题换行还读得出来,选项被截成「Automa…」就没法用了。

② **「排版…」浮层宽 460pt,不是另外两个浮层的 380pt**。离屏量的数:「对齐方式」那一行的理想宽度中文
377pt、英文 428pt(四选一控件本身中文 234 / 英文 275,加图标列、标题、`Spacer(minLength: 12)` 和左右
内边距)。380pt 下中文标题「对齐方式」当场折成两行(渲染确认,不是估算),英文更差 —— 420pt 时
「Alignment」折三行、440pt 折两行;460pt 是两种语言都一行放得下、四个选项完整可读的第一档。为此
`OverlayStylePopoverShell` 的宽度从常量改成带默认值 380 的参数,另外两个浮层一个字节没动。

#### 工具栏第四个位置:横向够不够

可用宽度就是卡片列宽:窗口按 `idealWidth` 860 打开时 600pt(`maxCardColumnWidth` 上限),拖到
`minWidth` 760 时约 530pt。三个入口带摘要的自然宽度(离屏 `fittingSize`):中文常见值 535pt、
中文最坏(超长字体名 + 超长自定义主题名)672pt、英文常见值 662pt。结论:**600pt 下中文常见值整条读得完,
再窄或换英文靠摘要截断**,四个入口本身任何宽度下都在。这是接受的取舍 —— 摘要是"不点开也知道现在什么样"
的赠品,入口才是功能。

⚠️ 为此摘要那截加了 `.layoutPriority(-1)`。不加的话 SwiftUI 把亏空按比例摊给按钮里**所有**文字,
400pt 下标题先被截成「文…」「配…」「排…」(离屏渲染对照过),入口的名字没了、摘要却还留着半截,
主次正好反过来。负优先级让摘要先被压,窄到极限时它缩成「…」而标题始终完整。

#### 顺带

- 「双行显示」的图标从 `text.aligncenter` 换成 `rectangle.grid.1x2`:那个图标画的是"居中对齐",紧挨着
  下面真正的「对齐方式」一行会被读成对齐设置。
- `OverlayAlignmentSegmentedControl` 里那份 `options` 数组改成 `static func label(for:)`,选项顺序直接
  用 `OverlayDuetAlignmentOverride.allCases` —— 工具栏摘要要报"当前选中哪一个",两处必须同一份口径
  (控件里写「左对齐」、摘要里写「左」就是同一个值两种叫法)。**不能存成 `static let`**:`L10n.t` 得在
  每次取值时现算,存进 `static let` 会把首次访问时的语言冻在里面。

**保留没动**:第一到第十二步的成果一个没丢 —— 编辑台渲染真 `LyricsOverlayView`、1:1 真实尺寸、整块舞台
一张固定壁纸、宽度调整条的三条落点规则(相等守卫 / `if settings.classicOverlayEnabled` 守卫 /
`snap` + `widthRange`)、`widthRange = 300...1400`、背景透明时的常驻虚线轮廓、超宽居中裁切 + 两端渐隐 +
「两端已裁切」、左下角锁标、`ContentHeightPreferenceKey` 的 `max` 归约、`OverlayInlineConfirmRow`
那两行内联确认,以及"绝不碰 `LyricsOverlayWindowController.shared`"这条硬约束。
`OverlayPreviewBar` 与 `OverlayLyricsCanvas` 一个字节没改。

### 第十四步:修掉拖动中冻住的宽度读数 + 浮层外壳提成共用(2026-08-31)

这一步是做**灵动岛**编辑台(见 [05 章「编辑台改造」](05-notch.md#编辑台改造2026-08-31))时顺带落在这一段的两处,
悬浮歌词这边的功能一项没变。

#### 14.1 `widthValueText` 拖动中冻住

调整条旁边那个 `640pt` 读的是**裸的** `settings.overlayWidth`,而第六步加 `draggingWidth` 之后:
落盘推迟到松手,窗口宽度走的是 `draggingWidth ?? settings.overlayWidth`。两者不一致的后果是拖动全程
读数停在**上一次提交**的数字上不动,而窗口就在旁边跟着实时变宽——看着像读数坏了。是第六步漏掉的一处
(那次的注意力全在"别在拖动中写盘"上)。改成跟窗口同一个 `??` 表达式即可,一行。

⚠️ 教训是通用的:凡是引入"拖动中的临时值"这种**第二真源**,得把**所有**读那个值的地方一起过一遍
——窗口宽度、读数、caption 的溢出判定、VoiceOver 的 `accessibilityValue`。漏掉的那一处不会编译报错,
只会在拖动的那一秒里表现成"某个东西不跟手"。

#### 14.2 一条**没有**改的:宽度滑杆的提交出口只有 `onEditingChanged(false)`

审查时提过一条听上去很像真缺陷的东西:`widthBinding.set` 只写 `draggingWidth`,而 `commitWidth` 只挂在
`onEditingChanged(false)` 上 —— 那么键盘方向键 / VoiceOver 的调节是不是永远提交不了、`draggingWidth`
是不是会被永久钉住?**实测证伪,代码不动**。四个独立离屏探针(自建最小 SwiftUI 宿主,不碰用户的窗口)
测到的事实:

- 这版 macOS 的 SwiftUI `Slider` **不是 `NSSlider` 包出来的**:dump `NSHostingView` 子树只有
  `KeyViewProxy` / `_FocusRingView`,递归找不到任何 `NSSlider`。所以"editing 边沿只由 AppKit 的鼠标
  tracking 产生"这个前提根本不成立 —— 边沿是 SwiftUI 自己发的。
- 对它发 `AXIncrement` / `AXDecrement`(VoiceOver 上下调节走的就是这两个 action),每一次都是完整的
  `EDITING(true) → set → EDITING(false)`,`commitWidth` 照常执行、`draggingWidth` 照常清回 nil。
  照抄这套 binding 的复刻件跑出来一样。
- 纯键盘那半条没能直驱(默认关着"完全键盘访问"时这根滑杆根本进不了焦点链),但它跟 AX 调节走的是自绘
  滑杆内部同一个"按一格"的入口,没有理由只有它不发边沿。

**顺带订正两处措辞**:① AX 的一次增减走的是**区间的 10%**(300…1400 上约 110pt),不是 `widthStep`
的 2pt —— 值仍然过 `snap()` 夹取量化并正常提交,但"左右箭头一次一个 step"不是准确描述;
② 显式给 `.accessibilityValue(...)` **不会**摘掉内建的可调节动作(实测带着它跑,increment 照样生效)。

记在这里是为了挡住下一次"顺手加个兜底提交路径"的冲动 —— 给宽度加第二条写入路径,比它想防的那个并不
存在的问题更贵。

#### 14.3 删掉页顶钉条 `OverlayPreviewBar` 与它那份简化渲染 `OverlayLyricsCanvas`

两个都是**零实例化**的死代码,这次一并删除(共 543 行):

- `OverlayPreviewBar` 的最后一个引用点在 `SettingsView` 那个固定头部的 switch 里。悬浮歌词段
  在第八步把预览升级成内容区里的编辑台之后就改成了 `EmptyView()`(固定头部收不到点击事件,
  可交互的预览只能待在滚动区),灵动岛段 2026-08-31 同样改成 `EmptyView()` —— 至此三段里只有
  菜单栏还钉着预览,而它用的是自己的 `MenuBarPreviewBar`。
- `OverlayLyricsCanvas` 从第八步起就只剩钉条一个消费方,钉条一走它也没人用了。

**留下来的是 `OverlayDesktopSurface` / `DesktopWallpaperSample`**(那一小片桌面壁纸样图 + 读取
缓存),搬进新文件 `UI/OverlayDesktopSurface.swift` —— 它有三个活着的消费方:两块编辑台的舞台
和菜单栏预览条的底。搬的是原样代码,一个字节没改。

顺带处理的两件事:① 两个只被钉条用的文案键(`预览 · %@pt`、`预览 · %@pt · 已缩放至 %@%%`)
从 catalog 里删掉;② 钉条头注里那条**全仓通用**的原则——「预览只画真实数据能支撑的东西,
不为示例句编造一份不存在的播放进度」——搬进 `SectionPreviewBars.swift` 的文件头,菜单栏预览和
`MenuBarScrollingLabel` 里两处指向它的注释一并改指新位置。

⚠️ 第一到第九步里凡是写着「钉条还在用它 / 一个字都没动、也不许删 / 那边照旧要缩」的地方,都是
当时的现状,现在都不成立了 —— 那几处已就地标注,别再照着它们的结论办事。

#### 14.4 `OverlayStylePopoverShell` → `SettingsPopoverShell`

那个 `private struct` 从 `OverlayStyleSettingsRows.swift` 搬进 `SettingsDesignSystem.swift` 并去掉
`Overlay` 前缀,多了一个可选的 `help` 参数(桥到 `SettingsCardHeader(title:help:)`)。三个浮层
(「文字」「配色」「排版」)的行为一个像素没变:宽度默认 380、「排版」仍传 460、`maxHeight` 仍是 460。

搬的理由:灵动岛那一段的编辑台也有两个浮层,再复制一份外壳就意味着同一个窗口里两种浮层的宽度上限/
高度上限/标题排版各自漂。这是设置页的通用外壳,不是悬浮歌词专属。

### 第十五步:「自动隐藏」并进各形态的「行为」入口(2026-09-02)

设置页这一段最后一张**只装隐藏开关的独立卡**没了。用户原话:「灵动岛歌词配置以及悬浮歌词配置这个
地方不要单独放在外面,要遵循设计理念,放到行为卡片里面去」。

- **改了什么**:删掉 `SettingsView.autoHideCard(subtitle:help:captureBinding:notPlayingBinding:)`
  这个函数和它在悬浮歌词/灵动岛两段的调用点;「截屏/录屏时隐藏」「暂停/无播放时隐藏」两行搬进
  各形态**已经存在**的「行为」入口。文案(标题/副标题/ⓘ)、图标、Binding 逐字保留,**没有任何行为变化**。
- **真源**:新文件 `UI/AutoHideSettingsRows.swift` —— `AutoHideSurface`(`.desktopOverlay`/`.notch`)
  + `AutoHideItem`(图标/文案/`binding(for:)`)+ `AutoHideSettingsRows`(两行的标准渲染)。
- **四个宿主**(增删内容必须四处一起对,漏一处不报错;用户口中的"行为卡片"在这一段就是那条
  「行为」栏,它内部确实是一张 `SettingsCard`):悬浮歌词 =「行为」栏(`OverlayBehaviorBar`,
  三列小格**下面**另起两行标准行)+ 抽屉「窗口」组;灵动岛 =「行为」浮层(`NotchBehaviorPopover`)
  + 抽屉「行为」组。另外 `NotchEditorStage.behaviorSummary` 也要把这两项算进去,否则工具栏按钮会在
  它们开着时照旧显示「全部关闭」。
  ⚠️ **宿主①当天晚些时候又换了一次**:那条「行为」栏整个被删掉,五项进了编辑台工具栏第二行的
  `OverlayBehaviorPopover`(见第十六步)。下面那段「版式:三列小格仍然是三列」跟着作废 —— 但它
  记的那个**386pt 英文不折行下限**仍然是当前浮层宽度 420 的依据,别连它一起删。

**为什么落在「行为」而不是另找地方**:这两项跟「行为」里原有那几项(锁定位置 / 长按拖动 / 悬浮淡化 /
暂停缩回)判据完全相同 —— **设一次就不动,而且在编辑台上看不出任何变化**。第三步当初就是按这条判据
把行为项从「窗口」卡里拆出来的,这是同一条判据的延伸,不是新规矩。

**⚠️ 拆成两份值那一步没有回退**(2026-09-01 那次):`AutoHideSurface` 这个新抽象最大的诱惑就是
"共用一份值、按 surface 只换文案",而那正是 2026-09-01 刚被推翻的方案。**共用的是渲染与文案,不是值** ——
改文案两个形态一起变是预期的,Binding 必须按 surface 分流到各自的 AppSettings 键和各自的 WindowController。

**⚠️ `.shared` 那条不变量搬了家,别让它蒸发**:两个 WindowController 都是 `static let shared`,读一下就
把整扇窗建出来。改版前这条是**结构性**保证的(`autoHideCard` 只收 Binding、不认识任何控制器);现在
控制器被请进了 `AutoHideItem.binding(for:)` 内部(四个宿主各传一份 Binding 会变成四份重复的守卫逻辑,
那是更大的漂移风险),所以规矩降级成一条写死在那个文件里的注释:`.shared` 只准出现在 `set:` 闭包里、
必须带 `if settings.xxxEnabled` 守卫,`get:` 分支必须是纯 AppSettings 读(工具栏摘要会在形态关着时求值它)。
仓库里**没有**任何 lint 检查这个。

**版式**:三列小格仍然是三列 —— 那两行画在 `HStack` **之外**。塞进格子里会被 `.frame(maxHeight: .infinity)`
拉成等高格子,而格子版式只画"标题 + mini 开关",副标题和 ⓘ 气泡会被静默丢掉。离屏 `NSHostingView`
在 600/560/530/499pt 四档、中英两种语言下都验过不折行(英文那行最宽,自然宽 385pt —— 1pt 步进
探出的不折行下限因此是 386,05-notch.md 那张浮层宽度表记的就是这个 386,两个数不打架)。

### 第十六步:「行为」从常驻卡改成编辑台工具栏浮层(2026-09-02)

第十五步刚把两行自动隐藏并进「行为」栏,用户看到成品后要求改掉那条栏本身。原话:「这里这样不是我
预期的;你帮我和灵动岛设置页一样处理,放到上面的小按钮里面,点了出现下拉框」。

- **改了什么**:删掉 `OverlayBehaviorBar`(编辑台正下方那张常驻卡:三列小格 + 下面两行标准行)和它在
  `AppearanceSettingsTab` 里的调用点;编辑台工具栏**新增第二行**,里面一颗「⇄ 行为 · 摘要」按钮,点开是
  `OverlayBehaviorPopover`(标准设置行 ×5:锁定位置 / 长按拖动 / 悬浮淡化 + 截屏隐藏 / 暂停隐藏)。
  `OverlayBehaviorItem`、`OverlayBehaviorSettingsRows`、`AutoHideSettingsRows`、抽屉「窗口」组**一律没动**,
  文案/图标/Binding 逐字保留,**零新增 L10n 键**、没有任何行为变化。
- **为什么是对的**:灵动岛那边同一批东西早就是工具栏浮层(`NotchBehaviorPopover`,第十五步刚往里加过
  这两行)。同一类设置在两个形态里长成两副样子,是用户直接读得到的不一致 —— 他这次要的正是取齐。
  顺带解决了那张卡自己的结构性别扭:格子版式**只画"标题 + mini 开关"**,不画副标题也不画 ⓘ 气泡,所以
  第十五步并进来的两行只能摆在三列格子**外面**、走另一套版式,一张卡里两种行长相;浮层里五项全是
  标准 `SettingsRow`,长相一致。
- **为什么另起一行、不当第一行的第四颗**:第一行的横向预算 2026-08-31 加第三个入口时就量到了上限
  (可用 600pt / 中文常见值 535pt,右边还有「重置 ▾」),再加一颗必然把摘要压成「…」甚至挤掉标题。
  灵动岛那边也是同一个理由拆的两行(`NotchEditorStage.toolbarRow2`)。第二行目前只放一颗按钮 ——
  横向因此宽裕到不用重新离屏量,以后再多一个"设一次就不动"的入口有现成位置。
- **浮层宽度 420 是抄的实测值,不是拍的**:瓶颈是英文标题 "Hide During Screenshots/Recording"(216pt)
  + ⓘ(19pt),自动隐藏两行的内容自然宽 271pt(中文)/ 385pt(英文),1pt 步进探出的英文不折行硬下限
  **386**(第十五步量的,见上)。`SettingsRow` 的标题没有 `lineLimit`,超宽的表现是**折行**不是截断,而 ⓘ 跟
  标题同处一个 `HStack` 会垂直居中、尾部开关是 `.top` 对齐,三者当场错位。420 的余量 +34 跟
  `NotchStylePopover` +28 / `NotchEarPopover` +24 / `OverlayLayoutPopover` +32 同一档;另外三项都比它短,
  瓶颈不变。跟 `NotchBehaviorPopover` 同宽,也让两个形态的「行为」浮层看起来是一件东西。
- **⚠️ 按钮上那句摘要必须跨两个枚举**:`OverlayBehaviorItem` 三项 + `AutoHideItem` 两项。只统计前者不会
  编译报错,只会让用户开着「截屏/录屏时隐藏」时按钮照旧写「全部关闭」——一个会撒谎的派生值。归约
  逻辑(全开 / 全关 / `ListFormatter` 拼开着的那几项)这一步从 `NotchEditorStage.toggleSummary` 又往上提了
  一层到 `SettingsToggleSummary.text(_:)`(`Settings/SettingsDesignSystem.swift`),两个编辑台共用 —— 它产出的
  是用户看得见的文案,各留一份迟早漂开。⚠️ 元组数组不能用 key path 简写(`filter(\.isOn)` 编译不过)。
- **⚠️ 摘要会在悬浮歌词关着的时候求值**(设置项刻意不跟总开关联动),所以它读的 `binding` **get 分支必须
  是纯 `AppSettings` 读**、一个 `.shared` 都不许有 —— `LyricsOverlayWindowController.shared` 是 `static let`,
  读一下就把整扇窗建出来。见 `UI/AutoHideSettingsRows.swift` 里 `binding(for:)` 上那段。
- **抽屉「窗口」组没有跟着收进浮层**:它是这五项**不用点开任何浮层**就能摸到的兜底通路(键盘 /
  VoiceOver / "我就想找个开关"),定位跟其它几组一样,不是"新配置项的收纳盒"。

### 第十七步:「配色」按"改的是哪一层"拆成 主题 / 文字 / 背景(2026-09-02)

用户原话:「帮我把这 2 个里面的配置重新整理一下,拆分为文字以及背景;分别归纳」——那 2 个是
「文字」和「配色」两个入口。

**病根**:原「配色」组一次装着七行(跟随封面 / 配色主题 / 文字颜色 / 背景颜色 / 毛玻璃背景 /
文字描边 / 描边颜色)。"都是颜色"是它们唯一的共性,而那条共性太粗 —— 改文字色和改背景色是两件
互不相干的事,挤在一个入口里每次都要在七行里先找。这跟第十三步(「排版」从「文字」里拆出来)是
**同一条判据的第二次应用**:按"这个字段改的是哪一层"归组,不按"都跟文字/颜色有关"这种最粗的
相关性,那条相关性把整页设置都能装进去。

**拆完的三组**(唯一真源都在 `UI/OverlayStyleSettingsRows.swift`):

| 组 | 内容 | 组件 |
|---|---|---|
| 主题 | 配色主题 / 我的配色主题 | `OverlayThemeSettingsRows`(内含 `OverlayCustomThemeRows`) |
| 文字 | 字体 / 粗细 / 字号 + 跟随封面 / 文字颜色 / 文字描边 / 描边颜色 | `OverlayTextSettingsRows` |
| 背景 | 背景颜色 / 毛玻璃背景 | `OverlayBackgroundSettingsRows` |

`OverlayColorSettingsRows` 因此**不再存在**(grep 不到不是漏了,是拆没了)。

**三个归属判断的依据,都不是随手分的:**
- **「跟随封面」归文字**,不归主题也不归背景:它接管的只有**文字颜色**
  (`PlaybackCoordinator.displayForegroundColor`);背景色(`LyricsOverlayView.overlayBackground`)
  和描边色(`.lyricsTextStroke`)任何时候都无条件生效。
- **「主题」两项两层都改**,所以塞进「文字」或「背景」任何一边都是错的分类,单开第三个入口
  (用户拍板)。
- **「毛玻璃背景」仍是「背景颜色」的从属子行**,不跟描边平级:它改的是背景颜色的**含义**
  (从"卡片本色"变成"玻璃上的着色"),不是一个独立维度。

**⚠️ 由此产生一个跨入口的联动,别"就近"改回去**:「跟随封面」这个开关在**「文字」**里,而被它
收起的「配色主题」那一行在**「主题」**里。所以一开「跟随封面」,「主题」组就只剩「我的配色主题」
一行。这是可接受的(存/删自定义主题跟取色模式无关,那一行任何时候都该在),但**不要为了就近把
「跟随封面」搬进「主题」组** —— 那会让「文字」组失去它唯一的取色模式开关,而
`followsCoverArt` 接管的恰恰只有文字色。理由写在 `OverlayThemeSettingsRows` 的头注里。

**浮层宽度**:「主题」吃外壳默认 380(里面 `OverlayCustomThemeRows` 那两行内联确认在 380 下验证过,
见第十二步);「文字」也仍是 380(并进来的四行标题都很短、尾部是 Toggle/ColorPicker,横向瓶颈还是
原来那三行的字体名下拉和字号滑杆;高度最多七行 353pt,在外壳 460 的上限内,不会退化成"多一条
滚动条")。**「背景」显式给 420**,这是量出来的:内容自然宽中文 298pt / **英文 386pt**(离屏
`NSHostingView.fittingSize`,1pt 步进的换行探测给出的英文硬下限就是 386),瓶颈是「毛玻璃背景」
那一行的副标题 —— 英文 "When on, the background color tints the glass" 比中文长 88pt,380 差 6pt、
英文下当场折成两行。420 按同族浮层的既有余量取(`NotchStylePopover` +28 / `NotchEarPopover` +24 /
`OverlayLayoutPopover` +32)。

**摘要**:`OverlayStyleSummary.color` 改名成 `theme`(取值一字未变 —— 它报的一直是"当前这一套配色
叫什么"),另加 `background` 报三档「毛玻璃 / 纯色 / 透明」。⚠️ 「透明」那一档不能省:背景色的
ColorPicker 是 `supportsOpacity: true`,把 alpha 拖到 0(歌词直接浮在桌面上、没有底板)是个常用
配置,报「纯色」是错的。阈值**没有另写一份**,借的是 `AppSettings.backgroundVisible(hex:glass:)`
(`glass` 传 false 就退化成"背景色本身看得见吗",alpha > 0.02)—— 那个函数已经是窗口阴影 / 拖拽
捕获层 / 编辑台虚线边界三处共用的判据,再抄一个 0.02 就是第四个会漂的地方。

**抽屉跟着重新分组**:原来的「配色」+ 一组无标题的「我的配色主题」,现在是 **主题 / 文字 / 背景**
三组,顺序跟编辑台工具栏一致 —— 抽屉的职责是"工具栏浮层的全量兜底通路",两个宿主分组不一样的话,
用户按工具栏的记忆到抽屉里找会落空。「我的配色主题」不再单独占一组:它现在长在「主题」组里,
原来那组之所以没有组标题(第一行本身就叫「我的配色主题」、再加组标题是同一句话说两遍)这个别扭
之处一起没了。

**新增 5 个 L10n 键**:主题 / 背景 / 毛玻璃 / 纯色 / 透明(catalog 1111 → 1116)。
⚠️ 改 `Localizable.xcstrings` 用的是**定点文本插入**、不是 `json.load`+`json.dumps` 整体重写
(那会把分隔符和键序全改掉、产生九千行 diff);键按 code point 序插在正确位置。顺带核过:那份
catalog 改前就有 12 处键序乱序(别人插入时留的),改后仍是 12 处、一处没变。

**工具栏那一半**(编辑台按钮集合、`StagePopover` 枚举、各按钮摘要)当天由第十六步那条改动接手,
两个**过渡壳**(`OverlayColorPopover` / `OverlayStyleSummary.color`)已随之删除,全仓 0 引用。
接完之后的工具栏:

| | 入口 | 摘要 |
|---|---|---|
| 第一行 | 主题 · 文字 · 背景 + 重置▾ | `theme` / `text` / `background` |
| 第二行 | 排版 · 行为 | `layout` / `behaviorSummary` |

**顺序跟抽屉的渲染顺序逐字一致**(主题 → 文字 → 背景 → 排版 → 窗口),理由同上一段。

⚠️ **「排版」为什么从第一行下沉**:拆分后总入口从 3 个变 5 个,而第一行的横向账是量过的
(见 `OverlayEditorStage.toolbar` 头注:可用 600pt,三颗中文常见值已经 535pt)。第四颗按同一
量级估算会去到 700pt 以上,必然把摘要压成「…」甚至挤掉标题,所以「排版」跟「行为」并排到第二行。

⚠️ **第二行的语义因此变了,如实记下**:第十六步建它时的说法是"第一行所见即所得、第二行是设一次
就不动的项",而「排版」(双行显示 / 对齐方式)在编辑台上**是看得见的**。分行依据从"看不看得见"
退成了**横向预算**——别照着那个已经不成立的印象去重排。真要恢复那条语义,得先解决第一行装不下
四颗的问题(比如把摘要限宽从 140 收窄再离屏重量一遍),那是另一次改动。

⚠️ **画布上那两块命中区不需要改**:交接时曾以为 ② 背景命中区还指向「配色」浮层、要跟着改指
「背景」,实际核对代码发现**它们在第十步就整体删掉了**(`OverlayEditorStage.swift` 里
`.color` 只剩工具栏和 `switch` 两处)。上面第五步那张表是当时的几何记录,不是现状。

### 第十八步:压矮编辑台,让总开关一屏内看得见(2026-09-03)

用户原话:「这个预览窗口给我高度搞小一点,把下面的开关完整漏出来」(截图:悬浮歌词那一段,舞台
占满大半屏,底下「桌面悬浮歌词」那张总开关卡只露出一条边)。

**这不是观感偏好,是上面那张高度账里一笔没算的账**:第九步把 `maxCardHeight` 抬到 288(舞台 332)
时,取舍只算了"编辑台被裁 vs 多滚一屏",没算"总开关卡会不会被推出屏幕"。实测(方法同高度账那一节)
总开关卡底边落在 519pt 可视内容之外的 551.5pt,只露出 13.5pt —— 一个**开关**露一条边,比编辑台在
罕见配置下裁掉半行下一句预览要糟。

**两笔,合计 −43pt(编辑台 425 → 382)**:

| # | 改动 | 省 | 代价 |
|---|---|---|---|
| ① | `maxCardHeight` 288 → **266**(`stageHeight` 332 → **310**) | 22pt | 只剩「36pt + 逐词罗马音 + 译文 + 下一句 + 主歌词两行」(实测 286.5)这一个组合溢出 20.5pt 被裁 |
| ② | 舞台底下那行 caption **整行删掉** | 21pt | 无 —— 它常态是空字符串 |

① 的 266 是**照第九步那张实测表**挑的,不是随手压的:它仍然覆盖 20/31/36pt 三档的「三个显示开关
全开 + 主歌词一次换行」(最坏 265.5)和 31pt 那档逐词罗马音(260.5)。卡片在这一格里是**居中**的
(`inCardSlot`),所以在装得下的配置里降这个数只削掉卡片上下那两条壁纸留白(31pt 全开那档:上下
各 40.5pt → 各 29.5pt),歌词本身一个像素没少。

② 能整行删是因为那一行第六步起就**只在超宽时**写一句「两端已裁切」,其余时候占着 21pt 什么都不
显示。那句提示搬进了舞台 —— `overflowHint`,跟宽度调整条并排在窗下那条通道的左端,共用同一副胶囊
外壳(`View.overlayStagePillChrome()`,`widthBar` 也改成调它,两处不会再各自漂)。
- **搬进去必须换配色**:原来是页面底色上的 `.secondary` 灰字,现在压在真实桌面壁纸上 —— 灰字在
  浅色壁纸上直接看不见。白字 + 黑底 0.7 + 发丝描边 + 投影跟壁纸内容无关,深浅外观都读得清。这也是
  菜单栏那一段"caption 别压在壁纸上"(见 06-menubar.md)那条教训的正解:不是躲开壁纸,是自带底色。
- ⚠️ **别改成"有提示时才加那 21pt"**:`totalHeight` 必须是常量(理由见 body 末尾那条
  `.frame(height:)`),而"超宽"恰恰是拖宽度调整条时会来回翻转的状态 —— 那样拖动中整页卡片会跟着
  跳 21pt。搬进舞台正是为了让它出现/消失时整块高度一动不动。
- 横向余量算过:调整条那条胶囊总宽 258pt(10×2 内边距 + 图标 10 + 8 + 滑杆 168 + 8 + 读数 44)
  居中,提示胶囊约 75pt 靠左;窗口 `minWidth` 760 那一档舞台最窄约 499pt —— 胶囊左沿 120.5、提示
  右沿 87,还差 33pt。**要往这条通道里再塞第三样东西,先按这笔账重算。**

**结果**:总开关卡底 551.5 → 508.5,519pt 可视内容里完整露出、底下还剩 10.5pt。抽屉头仍在折线
以下(522.5),这一段依旧不是严格的一屏。

⚠️ **没动的三件事**,别顺手"一起优化":`widthBarLaneHeight` 44(胶囊 30 + 底距 12,再压就压到
控件本身)、两行工具栏的 72pt(第一行横向预算 2026-08-31 就量到上限,合不回一行,见第十七步)、
`cardHeight` 那条 `min(max(120, ceil(h)), maxCardHeight)` 公式(第八步起就是对的)。

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
11. **热区坐标换算不能直接读 `window.frame`,要读 `baseFrame(of:)`**:`updateHeight` 的 resize 是异步 Core Animation(`window.animator().setFrame`),动画途中 `window.frame` 是中间帧;三处热区换算(按钮矩形/控制热区/歌词热区)原来都直接读它,内容变高跟 resize 撞在同一拍时命中区 y 方向就会整体偏移,且没有 didResize 观察者能在动画结束后补一次(2026-08-25,用户报「没锁定时按钮点了不生效,往下移一点才生效,不是每次都能重现」;`updateControlRects`/`updateControlsHotZone`/`updateLyricsHotZone` 注释)。
12. **热区换算光"读高度读对"不够,还要"高度变了主动重算"**:上一条的 `baseFrame(of:)` 修的是"动画中间帧",但换算函数本身只在 SwiftUI **重新上报原始坐标**时才会被调用——顶边对齐的静态内容(播放控制排)高度变了、坐标却不变,换算函数从此再也不会被叫,永久停在窗口刚建出来那一刻(默认 120pt)算出来的值上(2026-08-29,用户报「点击按钮正下方才生效,点按钮本身没反应」,实测偏移量精确等于当时的高度差)。修法:原始坐标另存一份(`controlRectsRaw` 等),`updateHeight` 每次真正 resize 之后主动调 `recomputeHitRegions()` 重新换算,不再干等 SwiftUI 偶然重发。
13. **`ContentHeightPreferenceKey` 的 reduce 也必须是非覆盖式的(取 max)**:跟第 7 条同源、是这个文件里的**第三例**,2026-08-30 才被抓出来。全树只有 `body` 里那个测高度的 `GeometryReader` 真的设过这个 key,别的每一个分支都在贡献 `defaultValue`(0);写成 `value = nextValue()` 时结果取决于"谁排在最后",0 排在后面就把真实高度冲掉——实测同一轮渲染 `GeometryReader` 量到 206.2、`onPreferenceChange` 收到 0.0。后果在设置页编辑台上最刺眼:`cardHeight` 被 `max(120, ceil(0))` 摁在 120pt 地板上,`.clipped()` 把译文和下一句整个裁掉,看起来像"编辑台不画译文"(用户 2026-08-30 报的正是这个)。**看到这类现象先量 preference 收到的数,别去查 `OverlayPlayback` 的显隐开关**——那组默认值(`showTranslation = false`、另两个 `= true`)跟现象巧合得离谱,实测证明它一直是对的。见「编辑台改造」第十一步。
14. **`SettingsSubRow` 的尾部插槽会把按钮挤成"空圆角矩形"**:那一行是单行结构,左边标题/说明和右边控件
    分同一份宽度;控件那侧总宽超出剩余空间时,写死宽度的部件(`.frame(width:)` 的输入框、滑杆)一分不让,
    整份亏空全压在**按钮**上,按钮标题被压没,看起来就像"这个按钮坏了"(2026-08-30 「我的配色主题」的内联
    命名行在 380pt 宽的配色浮层里实测)。⚠️ **别误判成 `.labelsHidden()`**:离屏渲染逐个变量排除过,那句
    只管 `Toggle`/`Picker`,按钮标题照显;`.buttonStyle(.glass)` 也无关。给按钮加 `.fixedSize()` 只是把
    亏空转嫁给说明文字(被压成一列单字)。正解是"说明一行、控件另起一行",见 `OverlayInlineConfirmRow`。
15. **有固定 `minWidth` 的自绘控件放进 `SettingsRow` 尾部,会在"行里还剩空白"的情况下被压到下限**:
    这一行的 `HStack` 有三个可伸缩成员(标题列 / `Spacer` / 尾部控件),SwiftUI **均分**剩余宽度,不是
    "先按理想宽度发、余量给 `Spacer`"。均分份额小于控件理想宽度时,控件就退到自己的下限——
    `OverlayAlignmentSegmentedControl` 的下限是 4 × `minWidth`(56),中文标签的理想宽度正好等于下限
    所以看不出来,英文标签("Left-Aligned")长于 56pt 就被截成「Left-Ali…」,而**同一行右边还空着一大截**
    (2026-08-31 离屏渲染在 380/420/460pt 三档都复现)。这跟第 14 条不是同一个机制:那条是"总宽真的不够、
    亏空全压在按钮上",这条是"总宽够、分配算法没分给它"。修法是给控件本身加 `.fixedSize()`,让它先按
    理想宽度落位;代价是宿主太窄时亏空转到标题(标题换行)——**取舍原则是"让能读的那一半让步"**:
    标题换行仍读得出来,选项被截就没法用了。
16. **悬浮歌词毛玻璃不用 NSVisualEffectView,直接用 SwiftUI 材质;背景色升格为着色而不是新开一个「模糊度」滑杆**(2026-09-02)。`LyricsOverlayWindow` 本来就是 `isOpaque=false` + `.clear` 的面板,`NotchLyricsWindow` 用 `.thickMaterial` 已经证明材质在这种窗口里能直接渲染,不需要再垫一层 AppKit 视图去按 identifier 查找复用。强度不做滑杆:系统材质的模糊半径不可调,能调的只有"玻璃上盖多深的颜色",而这正好就是现有的背景颜色 alpha——复用它,设置面上只多一个开关。材质选 `.regularMaterial`:`.thick` 把壁纸盖成灰板、失去透出壁纸的意义,`.ultraThin` 在浅色壁纸上白字不够清楚。开关不进 `ColorTheme`(四字段不变,用户自存主题不迁移),但进「恢复默认文字与配色」的重置清单(7 → 8)。已知未处理:「跟随封面」的取色规则假设背景是壁纸或任意窗口,玻璃开着时底色是模糊混合色,浅壁纸配浅字的可读性靠描边兜底,观感不行再按材质明度改取色。
17. **"两个东西看起来一直对齐"可能只是因为它们的兜底值撞在一起**(2026-09-03,控制排在对唱歌里不在歌词上方)。歌词卡片按声部靠边、控制排吃 `VStack` 默认的 `.center`,这两条推导从一开始就不是同一套;普通歌 `duetSide` 兜底恰好也是 `.center`,于是它们算出同一个位置,分歧被整整藏了两周半,只有对唱歌才暴露。**教训**:凡是"上下两块必须对齐"的布局,对齐关系要么由同一份几何算出来,要么就得有一条断言钉住,别指望肉眼在默认场景下看得见 —— 默认场景恰恰是最可能巧合对上的那个。修法与实测见「对唱分声部」那一节。
