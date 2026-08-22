# 05. 灵动岛歌词
> 最后核对:2026-08-20 · 基线:2a2bf8b+工作树

## 定位

贴在屏幕顶部刘海位置的歌词卡("灵动岛"形态),是与桌面悬浮歌词(经典悬浮窗)平行、完全独立的第二套悬浮歌词实现:独立的 NSPanel、独立的窗口控制器、独立的开关,两种形态可同时开启互不排斥。稳态常显"播放指示条 + 歌名 + 播放控制 + 当前歌词逐字高亮 + 封面小图",hover 时向下多展开一块"下一句预览 + 迷你进度条"。

## 入口与展示面

- **设置页 → 外观 →「灵动岛」分段**:顶部总开关卡(「灵动岛歌词——紧凑地贴着屏幕顶部的刘海显示」)+ 配置卡(风格/宽度/显示在哪块屏幕)。分段顶部有一条实时预览(`NotchPreviewBar`),渲染的是与真窗口**同一份** `NotchLyricsView`(通过 `NotchChromeSource` 协议换了个不建窗口的替身 chrome),预览里 hover 展开、点播放按钮都真实可用。配置卡不跟开关联动:灵动岛关着也能先配好。
- **菜单栏状态项 →「快速开关」子菜单 →「显示灵动岛歌词」**。
- **首次引导页(OnboardingView)** 也有同一个开关。
- **窗口本体**:`NotchLyricsWindow`(NSPanel),无边框、level 为 `.screenSaver`(高过系统菜单栏,否则贴不进刘海那一条)、跨所有 Space、全屏应用之上可见、外观固定 `.darkAqua`、`hasShadow = false`、不可被用户移动。位置永远是算出来的(贴死屏幕顶边、水平对齐刘海中心),没有"锁定位置"概念,也不持久化位置。
- 没有专属全局快捷键;全局快捷键里跟它有关的只有"歌词时间轴微调"(其反馈横幅显示在灵动岛上,见下)。

## 行为规格

### 三种形态:收起 / 稳态 / 展开

窗口本身**常驻最大尺寸**(稳态宽 × 展开态高),形态切换是卡片在这个固定透明窗口里自己变大变小(`NotchWindowRoot`),窗口 frame 只在屏幕几何或宽度设置变化时才动。

- **收起**(`isCollapsed`,计算属性 `(!isPlayingNow || isAdBreakNow) && !isExpanded`,2026-08-19 加入广告维度):卡片只收**高度**——只留顶行那一条(高度 = 刘海高/菜单栏高),歌词行和展开区连同内容整块淡出+向上轻缩(anchor 在顶部,跟卡片同一条弹簧,不是硬切)。**宽度不变**:顶行的两只"耳朵"分居刘海两侧,宽度一缩耳朵就没地方放了。
  - ⚠️ 代码里多处旧注释(`NotchLyricsWindowController` 文件头、`NotchChromeSource.isCollapsed` 的 doc)仍写着"收起缩到刘海本身大小/兜底胶囊 120pt",这是 2026-08-16 窗口重构前的旧行为;当前真值是 `NotchWindowRoot.cardWidth` 恒为 `steadyCardWidth`。控制器里的 `collapsedCardWidth` 属性仍在计算和发布,但当前工作树**没有任何消费方**(死状态)。
  - 收起态 hover 上去仍能重新展开出完整内容(含播放按钮,可用来恢复播放)——2026-08-17 把 `isCollapsed` 从"只在 recomputeGeometry 里赋值的存储属性"改成计算属性,修的就是"暂停时鼠标移上去没反应"。
  - **Spotify 广告插播也收起**(2026-08-19 用户拍板"和暂停一样缩回去"):广告期间歌名位显示「广告中」而不是广告物料名(`NotchLyricsView.topRow` 的 displayTitle,MarqueeText id 用显示串以便切进/切出广告时重置跑马灯),歌词行随收起不渲染;hover 仍可展开(控制按钮可切歌跳过广告)。`isAdBreakNow` 由 `$isCurrentTrackAdBreak` 的 sink 写入,同 `isPlayingNow` 的 willSet 坑同一修法:只取 sink 参数值。
- **稳态**(播放中、没 hover):顶行 + 歌词行(44pt,`NotchMetrics.compactRowHeight`)。
- **展开**(hover):在下面再长出 40pt(`NotchMetrics.expandedExtraHeight`):下一句歌词预览(有才显示)+ 迷你进度条 + 时间行。
- **展开区高度按内容算**（`NotchExpandedMetrics.height(hasLyricPreview:hasScrubber:)`，2026-08-21 用户报「没有歌词的时候这块太大、很多空的地方」）：展开区原来恒高 76pt 且 `alignment: .top`，而三样内容里两样是条件渲染的——下一句歌词预览（没歌词就没有）、迷你进度条（没时长就没有，见 `NotchScrubber` 的两个分支）。两样都缺时里面只剩一排三键，剩下 **41pt 全是底部空白**。现在按段累加：三键+底边距+余量 35（恒有）／预览行 17／进度条 24 → 三样齐仍是 **76，跟改动前逐字相等**（有歌词有时长时布局一点没动），只有预览 52，只有进度条 59，都没有 35。⚠️ 两个入参刻意是**曲目级**信号（这首歌有没有歌词／有没有时长），不是“此刻有没有下一句”——后者会让最后一句唱完时卡片突然矮 17pt、下一首又长回来，肉眼是抽动；代价是“有歌词但此刻恰好没下一句”时那 17pt 是空的，稳定压倒紧凑。**窗口和设置页预览容器仍用 `maxHeight`**：窗口恒按最大形态开（卡片在里面变大变小），跟着内容缩会让后面换到有歌词的歌时卡片被窗口边界硬裁。卡片高度（`NotchWindowRoot.cardHeight`）和展开区自己的定高**走同一个函数、同一组入参**，两处各自判断必然漂，而漂的表现是底部多一条空隙或最下面那排三键被裁掉。

形态切换动画(`NotchWindowRoot.cardAnimation`)分三条弹簧:收起 0.45s 临界阻尼(不回弹);hover 展开 `interactiveSpring(0.38, 0.8)`(跟手);其余(开始播放弹出等)`spring(0.42, 0.8)`。系统开了"减弱动态效果"(reduceMotion)时全部直接跳变。已知名不副实的一档:"hover 移开"实际落在 0.42 那条而不是 interactiveSpring(`.animation(_:value:)` 用变化后的新状态求值),差 0.04s、肉眼不可辨,刻意没为它加状态。

### 播放状态与收起时机

收缩判定订阅的是 `PlaybackCoordinator.$isPlayingSmoothed`——对"停"有 0.5 秒宽限(`stopGracePeriod`,2026-08-17 从 2s 压下来的),吸收换歌间隙/seek 的瞬时 false,避免灵动岛缩回去又弹出来;"起"不延后,恢复播放立刻响应。暂停 ≈0.5s 后卡片收起(歌词行卷回顶行)。

### 顶行(收起态唯一保留的部分)

`NotchLyricsView.topRow`,左右两只耳朵各 `(卡片宽 − notchWidth − 20) / 2`,中间给物理刘海让出 `notchWidth` 宽的空当(物理刘海是硬件不发光区域,横向落进去的内容会被真实挡掉;无刘海屏幕 notchWidth = 0,顶行整条可用)。两只耳朵**朝刘海那一侧**各内缩 `NotchMetrics.earNotchInset = 6`(2026-08-20 用户要求「歌手不要那么紧贴真实刘海」):三段严丝合缝铺满时右耳的左边界正好压在刘海右沿,装不下的歌手名(跑马灯从左起)第一个字就贴着黑边 —— 实测改前 0.5pt、改后 7.0pt(截图逐列对比度测量,`VALORANT/Grabbitz/bbno$`)。⚠️ 内缩必须写在 `.frame(width: earWidth)` **之前**,写在之后等于把耳朵整体变宽 6pt,三段不再铺满、背景形状与刘海空当会错位:

- **两种形态**:收起态(`collapsedRow`)= 左耳专辑封面小图(点它打开歌词窗口,没封面就留空、不画占位方块)、右耳播放指示条,跟 iPhone 灵动岛收起形态同构;稳态/展开(`topRow`)= 左耳歌名、右耳歌手 + 播放指示条。指示条两种形态都住右耳、贴外缘,收放切换时不横跳。控制键不在耳朵里(2026-08-19 用户逐步拍板:岛本来就是 hover 展开的,光标到耳朵之前卡片已经展开,完整三键在展开卡的进度条下方,见「hover 展开区」)。
- **播放指示条**(`EqualizerBars`):4 根跳动条,**与音频数据无关**(要真频谱得 CoreAudio 抓系统输出 + 一次录音授权,对一个"显示歌词"的 App 代价不成比例;文案和注释一律只说"播放指示"不说"频谱")。**2026-08-22 起条高的振幅由逐字歌词时间轴调制**(`amplitude` 闭包 → `NotchLyricsView.vocalAmplitude(at:)`):落在某个字的发声区间里满幅、字与字之间的空档收到 0.6、压根没有逐字数据时 1(= 加这个机制之前的行为)。这是 lyrimuse 相对那些抓音频的实现的便宜之处 —— 逐字时间轴本来就在手上,等于白拿一个跟人声同步的包络,零权限、零新数据源、零常驻音频线程。位置口径必须跟逐字填色**完全一致**(锚点外推 → 暂停冻结值兜底 → 叠加生效偏移),否则条子跟高亮的字对不上,比不跟着动更奇怪。⚠️ 刻意**不做**连续包络(按字的已唱比例插值):它只会让每一跳的高度更平均、反而更不像跟着人声。(原来的论据是「tick 只有 3.6Hz,中间值体现不出来」——2026-08-23 求值频率提到 10Hz 之后这半条已不成立,但结论不变。)⚠️ 振幅只压缩"能跳多高"、不动 `minHeight` 地板 —— 间奏/纯音乐时收敛成小幅晃动而不是趴平(趴平的观感是"坏了")。
  **2026-08-23 换掉了条高的生成方式**(用户反馈「跳动比较机械感,可以顺滑一点吗,频率快一些」)。旧实现按 `(bar, tick)` 做 splitmix64 散列,**相邻两个 tick 的目标值完全无关** —— 每 0.28s 硬跳到一个不相干的高度,补间怎么调都是「抽一下、停一下」。实测量化了这件事:相邻采样点的高度跳变**平均 2.5pt、最大 7.07pt**,而整个行程只有 7.5pt(2.5→10),等于每一跳都可能横扫大半个量程。
  现在是**双正弦叠加的连续函数**(两个频率不成简单整数比,相位按条序错开无理数间距),跟菜单栏图标那套音条同一个手法(`MenuBarLiveIconView.buildEqualizer`,注释原文「双正弦打破机械感」),两处观感一致;同一测法下相邻跳变降到**平均 0.32–0.47pt、最大 1.12pt**。散列当初解决的是另一个问题(`Double.random` 会让同一 tick 每次重算 body 得到不同结果、无缘无故抽动),而连续函数同样是纯函数,顺带把机械感一并解决。
  求值间隔 **0.28s → 0.10s**。旧注释「再快就显得毛躁」是**跟随机高度绑在一起**的结论 —— 目标值互不相关时越快抖得越凶;换成连续函数之后,快反而是顺滑的前提(采样越密越贴近那条曲线)。补间曲线 easeInOut → **linear**:目标值本身已在连续曲线上,再套 ease 会在每个采样点两端各加一次加减速,把平滑的正弦啃成一段段顿挫 —— 那是机械感的另一半。
  ⚠️ **这没有推翻 2026-08-19 那条性能结论**:补间时长仍只占半个周期(0.05s),每周期照样有一半时间完全静止、合成循环该 idle 还是 idle。变的只是**求值频率** 3.6Hz → 10Hz,仍远低于逐字填色那条 30Hz 的热路径。
  其余不变:暂停时静止在 2.5pt 不归零;2026-08-17 起固定开启不可配。
- **歌名 / 歌手**:两边都是跑马灯(`MarqueeText`,只在文字真溢出时滚,24pt/s、首尾各停 1.1s,id 取**显示串**——换歌、切进/切出广告才重头滚)。无歌名时显示"♪";广告期间歌手位留空。歌手这一侧 2026-08-20 才从"截尾成省略号"改成跑马灯(用户要求;在此之前刻意不滚,理由是"两只耳朵各滚各的太闹"),它仍然靠右贴着指示条 —— 没溢出时靠哪边由 `MarqueeText.restingAlignment` 决定(这里传 `.trailing`),溢出时一律从左起,否则开头几个字会被挂到容器外面。

### 歌词行

`NotchLyricsView.lyricRow`:歌词跑马灯占满剩余宽度,尾端(卡片右下角)是 32pt 见方的专辑封面小图。

- **右端渐隐带**(2026-08-22,用户报「灵动岛歌词有时候被封面挡住」):歌词跑马灯**溢出、而且此刻停在开头**时,右端给一条 10pt 的渐隐带(`NotchMetrics.lyricEdgeFadeWidth`,判据在 `MarqueeMath.trailingFadeWidth`,`MarqueeText.edgeFadeWidth` 传进去)。为什么需要它:歌词区右边界离封面只有 `artworkLyricSpacing`(10pt),长句停在开头 hold 的那 1.1 秒里末端被**硬切**在那条窄缝上,肉眼分不清"文字被裁掉了"和"文字被封面盖住了"——真机连拍坐实(截图里 `of Sunset Boul` 硬切,右边紧邻封面)。条件是精确的而非保守:滚到末端的 hold **不能**淡(那时文字末尾正好抵着边界,淡出会吃掉真正的最后一个字,是信息损失);滚动途中不淡也无所谓(文字在动,观感是滚过去而不是被挡)。渐隐带做成 `.frame(width:)` 的子视图而不是改 gradient 的 stop 位置 —— `LinearGradient` 不是 Animatable,改 stop 会突变;做成宽度就自然跟着跑马灯的 `withAnimation` 平滑收掉、跟着 `disablesAnimations` 的归零瞬时出现。mask **无条件**挂(宽度 0 时等效没有),不写成 `if width > 0`:那样归零的一刻视图身份变、子树重建,会打断正在跑的滚动。只有歌词行传非 0,顶行歌名/歌手同样是硬切但旁边是刘海/音浪而不是封面,没有同样的误读风险。
- **封面在场性变化必须瞬时**(同日,同一份用户报告里真·遮挡的那一半):封面是歌词行 HStack 的**条件兄弟**,`if let image = highResArtworkImage ?? artworkImage`。它从不在场变在场时 SwiftUI 当结构性插入 —— 新插入的视图**一帧就落在终态位置**,而歌词那侧的 frame(连同跟着 frame 走的 `MarqueeText` 内部 `.clipped()` 边界)是被动画平滑收缩的,整条弹簧的时长里歌词被裁到"没有封面时"的旧边界,那一截字正好画在已就位的封面**底下**(HStack 里靠后的兄弟盖在前面的上面)。修法是在那个 HStack 上挂 `.animation(nil, value: 封面是否为 nil)`。独立最小复现(同构 HStack、弹簧放慢到 3s 逐帧抓):封面到位那一帧文字右边界仍停在旧位置 623px,要 4 帧才收到终态 603px,90 帧里 25 帧文字被压在封面底下;加上那一行之后同样 90 帧 **0** 帧遮挡。触发窗口很窄——必须"封面在场性变化"和某条活动动画落进**同一次** SwiftUI 更新,把两者错开 300ms 的第三版复现同样 0/90;现实里够得着的活动动画有 `NotchWindowRoot` 那三条 `.animation(cardAnimation, value:)` 和 `NotchTransientHost` 的 0.18s。封面确实会真的离场再回来:换歌后取图迟迟不来时 `LocalPlaybackSource.scheduleArtworkStaleTimeout` 会在 3s 后把 `artworkData` 清成 nil,重试成功再填回来。

- **逐字高亮**:当前行有逐字数据时,`TimelineView` 按 `WordKaraokeGradient.refreshInterval` 帧率现算每个字的填色比例(词最短时长下限 80ms、过渡带 0.08,与桌面悬浮歌词同一组经验值),时间基准 = 锚点外推位置 + `currentLyricsOffsetMs`(不加会填到一半卡住;anchor/offset 由闭包直读 PlaybackCoordinator,不经窄代理订阅)。整行套 `compositingGroup + shadow`。paused 条件是 `!isPlayingNow || currentLineFillSettled`(2026-08-19,与悬浮窗同款):行填完到下一行开始之前(行尾/间奏/曲末)视觉零变化,表停掉不再空转。
- **无逐字数据时的占位文字**,分支顺序固定(先特殊后一般):`广告中` → `纯音乐` → `暂无歌词` → `网络连接失败`(collector 网络不通且无歌词)→ `搜索歌词中…`(播放中但歌词还没解析回来)→ 整行纯文本 / "♪"。
- **封面小图**:优先 `highResArtworkImage`(缓存解析出的真封面;系统那份对网易云永远 100×100、云盘未匹配歌是灰底占位图),nil 回落 `artworkImage`。没有封面数据时**连位置一起不占**(不画占位方块),宽度全部还给歌词;换歌时旧封面保留到新封面到货,不会闪一次"消失再出现"。带 0.5pt 白描边 + 投影,给磨砂玻璃风格下浅色封面兜轮廓——这是全卡唯一不走强调色的前景元素。

### 风格(四种背景)

`NotchCardStyle`:纯黑 / 磨砂玻璃(`.thickMaterial`,窗口外观锁死 darkAqua,永远深色)/ 深色渐变(左上到右下三段冷色)/ **跟随封面**(默认值)。

"跟随封面"(`NotchLyricsView.backgroundLayer`):铺 PlaybackCoordinator **预烘焙**的模糊图 `blurredArtworkImage`(2026-08-19 性能审计落地 —— 原来视图层挂 `.blur(radius: 20)` 活滤镜,窗口播放期间因逐字填色/音浪/跑马灯几乎永动,GPU 每次重合成都重算同一个模糊;现在封面到货时用 CIGaussianBlur 离线烘一次,源 = highResArtworkImage ?? artworkImage,降采样到 720px、sigma 40≈原 20pt 半径@2x,clampedToExtent 让边缘实心)。`scaledToFill` + **显式钉回卡片尺寸的 frame** + 压 45% 黑不变;深色渐变打底层保留,现在只兜烘焙空窗(几十 ms)。模糊半径等效 20 而不是歌词窗口的 60:灵动岛画布又矮又宽,60 会把任何封面抹成统一深灰。没有封面数据时整个退回深色渐变。封面切换 0.5s 淡入淡出(触发键:烘焙图实例比较,一条覆盖原来 artworkData 字节比较 + 高清替代实例比较两条)。

卡片轮廓统一是 `NotchHangingShape`:顶部两角直角(贴死屏幕顶边,视觉上"从刘海长出来")、底部两角 20pt 圆角;整个 ZStack 统一 `clipShape` 一次,任何内容不越界。

### 强调色(跟随封面取色)

`NotchLyricsView.accentOrWhite`:只有「文字跟随封面」(`AppSettings.followsCoverArt`,在**桌面悬浮歌词的"配色"卡**里,跨形态生效)开着、且这首歌真取到了主色(`poller.notchAccentColor`)时才用封面色,否则一律白色。

`notchAccentColor` 的取色管线(`PlaybackCoordinator` 订阅拼装,只给灵动岛消费):封面均值色(高清优先)→ `LocalPlaybackSource.brightenedAccent`(HSB 亮度地板 0.62,提亮多少按比例压饱和;近黑兜底成中性灰 0.72)→ `LocalPlaybackSource.accentForDarkBackdrop`(**感知亮度地板 0.62**,Rec.709 luma,朝白色线性混合一步到位)。第二道是灵动岛专属:HSB 地板拦不住饱和冷色(纯蓝 brightness 1.0、luma 只有 0.07),贴深色背景区分度差。桌面悬浮歌词用的是另一条 `artworkAccentColor`(判据是跟描边的对比度),两者不通用。

2026-08-16 起强调色覆盖灵动岛**几乎全部**前景:歌名、播放指示条、五种状态占位文字、逐字歌词、下一句预览、进度条(填充和底槽)、时间文字、控制按钮、瞬态横幅——之前只有歌词正文吃它,状态文字会"有歌词跟封面色、变「暂无歌词」突然跳白"。唯一例外是封面小图描边。

### hover 展开与命中判定

命中判定在 `NotchWindowRoot`:给卡片本身钉 `contentShape(Rectangle())` + `onContinuousHover`,精确按卡片矩形判;`setExpandedFromWindow` 只在**进出边沿**上调(2026-08-19)——原来 .active 每次指针移动都调过去,那边无条件 cancel+重排 0.12s 展开意图,「进入延迟」实际从指针停下起算、卡片内持续移动就一直不展开。——不能用 `NotchLyricsView` 自带 `.onHover`(触发范围比卡片大一圈,窗口常驻最大尺寸后,卡片下方几十 pt 透明区划过也会展开,2026-08-16 已删)。协议方法 `setExpanded` 在真窗口和预览两边都是**故意的空实现**,真路径分别是 `setExpandedFromWindow` / `setExpandedFromPreview`。

意图延迟(`NotchLyricsWindowController`):进入 0.12s(2026-08-17 从 0.2 压下来;不再往下压——归零的话光标横穿屏幕顶部就会一路捅开灵动岛)、离开 0.1s;每次新事件先 cancel 上一个未兑现的意图,"进了又出"净效果为零。进入卡片那一刻立即给一次触觉反馈(Force Touch 触控板;不等延迟兑现,拖到延迟后就跟手感脱节)。

### 展开区:下一句预览 + 进度条

- 下一句预览(`poller.nextLineText`)为空时整行不显示。
- 进度条三态口径与歌词窗口一致:播放中按锚点逐帧外推;**暂停时**用冻结位置 `pausedPositionMs` + `currentDurationMs` 照常显示(2026-08-17 补上,之前一暂停整条进度条凭空消失,连带"暂停时下一句跑到正中间"的布局 bug);两者都拿不到(如无时长)则整段不渲染。
- 可拖动 seek:拖动中显示手指位置(`@GestureState`,手势取消自动复位),按下那一帧给一次触觉,**松手才真发 seek**(`poller.seek` → `LocalPlaybackSource.seek`)。命中区只盖进度条这一行(上下各虚扩 8pt),不含时间行——原来挂整块上,点"剩余时间"文字等于跳到 ~94%。轨道粗细 3pt → 悬停 5pt → 按住 6pt(幅度刻意克制,40pt 展开区再粗就把时间行挤出可见区);reduceMotion 下仍变粗(功能反馈)只去掉补间。
- ⚠️待核对:暂停态下拖完进度条松手后 seek 的实际生效情况(`LocalPlaybackSource.seek` 对暂停状态/不同播放器的行为)本章未核对,UI 层只是照常发出调用。

### 瞬态横幅(NotchTransientCenter)

一条短暂**盖住歌词行**的提示(图标 + 文字 + 可选进度细条),不改卡片高度、不动顶行,0.18s 淡入淡出,与歌词行同高同排版重量。单例中心做 cancel-rearm:连按多次以最后一次为准(每次 `show` 先取消上一个隐藏任务;`Task.sleep` 被取消后还要再查 `Task.isCancelled`,光 `try?` 挡不住被取消的任务去清空)。默认时长 1.4s。

当前两个生产者:
1. **歌词时间轴微调快捷键**(`GlobalHotkeys`):按一次闪"歌词偏移 +0.50s"(正号显式带出,方向可辨)。只有灵动岛这一种形态有此反馈;只开桌面悬浮歌词的用户按快捷键仍无任何视觉反馈。注意:菜单栏「歌词时间轴」里的等价按钮**不**闪横幅,只有快捷键路径闪。
2. **系统音量/静音变化**(`VolumeMonitor.apply`):显示音量百分比 + 分档 speaker 图标 + 进度条,1.2s。启停**固定跟随灵动岛总开关**(2026-08-17 删掉了独立开关;灵动岛关着提示无处显示,监听也不挂)。⚠️待核对:VolumeMonitor 对输出设备切换/多输出设备场景的监听行为本章未核对(只核对了启停条件与渲染)。

可见性推论(代码结构直接决定):横幅挂在歌词行上,收起态(没在播放且没 hover)歌词行不渲染,横幅不可见;开着「暂停/无播放时隐藏」时窗口整个 orderOut,更看不到。「所有屏幕」模式下横幅在每块屏的灵动岛上同时显示(单例被所有实例的视图观察)。

### 宽度

固定宽度,不随歌词长短变化(超长歌词靠跑马灯,不靠加宽)。用户设定值 `notchContentWidth`(默认 360,滑块 260–500 step 10),实际宽度 = `max(设定值, notchWidth + 2×70 + 20)`(`contentWidth(baseWidth:notchWidth:)`)——耳朵下限保护"按钮不被裁",真刘海很宽(实测约 179pt)或设定值很小时会突破设定值。设置页滑块的 set 闭包显式调 `applyContentWidthSetting()` 立刻生效;预览用同一个公式,不直接用设定值。

### 显示在哪块屏幕

设置项是一个三合一下拉:**自动**(空串)/ **所有屏幕** / 指定某块屏。指定屏幕存的是显示器硬件 UUID(`ScreenIdentity`,`CGDisplayCreateUUIDFromDisplayID`——localizedName 同型号重名、NSScreenNumber 跨会话会变、数组下标随插拔顺序变,都不能用)。

- **自动**:`targetScreen()` = 有真刘海的那块(`safeAreaInsets.top > 0`)→ 再没有退 `NSScreen.main`。不能直接常驻 NSScreen.main——它跟着键盘焦点跳,曾导致灵动岛停在用户看不见的外接屏上(2026-08-07 修)。
- **指定屏拔掉/合盖**:自动回落"自动"逻辑;设置页下拉补一个「已断开的屏幕」占位项(否则 Picker 找不到 tag 会显示成空白,像设置丢了);偏好保留,屏插回来即恢复。
- **所有屏幕**(`notchAllScreens`,默认关):`NotchMirrorManager` 给主实例之外的每块屏各建一个钉死(`pinnedScreenID`)的副本控制器。主实例照旧走 `targetScreen()`;主实例占的屏不建副本(否则两个灵动岛严丝合缝叠着,hover 只有上面那个响应)。副本与主实例是同一个类、同一份视图、同一套订阅,唯一区别就是钉屏字段。副本没有自己的设置入口,`hideWhenNotPlaying`/`hideDuringScreenCapture`/`notchContentWidth` 变化时管理器挨个调 `syncStateFromSettings(…)` 同步 —— **sink 的参数值必须显式传下去**(2026-08-19 修:@Published 在 willSet 时机派发,下游回读存储属性是旧值,原实现镜像宽度恒滞后一档、隐藏开关同步到翻转前的状态),各写入点判等、`orderFrontRegardless`/`setFrame` 只在真变化时执行;`teardown()` 末尾必须 `contentView = nil; hostingView = nil` 破掉 controller↔rootView 保留环(否则每次拔屏/关开关整套窗口+SwiftUI 树永久泄漏);副本不注册自己的屏幕参数观察者(主实例才注册,副本统一由管理器的通知驱动,避免一次插拔跑两遍全量几何);`notchCardStyle`/`followsCoverArt` 等纯渲染项经每个实例各自的 `NotchPlayback` 窄代理订阅(2026-08-19 起视图不再整对象观察 PlaybackCoordinator/AppSettings —— 36 个 @Published 实读约 17 个、47 个设置只读 2 个,无关高频写入原来会打醒整卡 body×镜像数;代理只转发实读字段并 removeDuplicates,accent 由「跟随封面」开关×动态主色预组合去重),仍然天然全实例生效。屏幕插拔时重算副本集合;被钉的屏拔掉时副本不自己挪窗(由管理器销毁),`resolvedScreen()` 返回 nil 直接不动。
- **刘海几何**(`geometry(for:)`):有真刘海时用 `auxiliaryTopLeftArea/auxiliaryTopRightArea` 算出刘海真实宽度和中心点(不假设刘海精确居中);无刘海屏幕退到"假刘海":高度 = 这块屏**当前菜单栏高度**(顶边差 `frame.maxY - visibleFrame.maxY`,下限 24pt 只在菜单栏自动隐藏时兜底;不能用 frame 高度差,那把 Dock 也算进去了),notchWidth = 0,水平居中于整块屏。

### 显示/隐藏

- `setVisible(_:)` 是开/关的**唯一入口**(设置页 Toggle、菜单栏开关、引导页三处都走它),真值持久化在 `AppSettings.notchOverlayEnabled`;打开时顺手把两个隐藏偏好应用上。
- **暂停/无播放时隐藏**(`hideWhenNotPlaying`,与桌面悬浮歌词**共用**,在设置页「其它」分段的「自动隐藏」卡):开着时暂停就整窗 `orderOut`——看不到收起动画(窗口都没了);关着才能看到"歌词行卷回顶行"。这是设置语义不是 bug。
- **截屏/录屏时隐藏**(`hideDuringScreenCapture`,同样共用):`window.sharingType = .none`,截图/录屏/会议共享拍不到,本人仍看得见。
- 显示用 `orderFrontRegardless()`(App 是 `.accessory` 策略从不激活成前台,`orderFront(nil)` 会看"是否活跃 App"这个前提)。
- App 启动恢复:`AppDelegate` 只在 `notchOverlayEnabled == true` 的分支里碰 `.shared` 应用隐藏偏好,**不再调 `setVisible(true)`**(历史 bug:会把用户上次关掉的状态覆盖回开)。

## 设置项

| 设置页位置 | 设置项 | 存储 | 改什么行为 |
|---|---|---|---|
| 外观 → 灵动岛(顶卡) | 灵动岛歌词 总开关 | `notchOverlayEnabled` | 整个功能开/关;音量横幅监听随之启停 |
| 外观 → 灵动岛 | 风格 | `notchCardStyle`(默认 跟随封面) | 卡片背景四选一,纯渲染即改即生效 |
| 外观 → 灵动岛 | 宽度 | `notchContentWidth`(默认 360,260–500) | 卡片/窗口固定宽度(有耳朵下限) |
| 外观 → 灵动岛 | 显示在哪块屏幕 | `notchScreenID` + `notchAllScreens` | 自动/所有屏幕/指定屏;「所有屏幕」触发副本管理 |
| 外观 → 桌面悬浮歌词 → 配色 | 文字跟随封面 | `followsCoverArt` | **跨形态**:开着时灵动岛全套前景走封面强调色 |
| 外观 → 其它 → 自动隐藏 | 暂停/无播放时隐藏 | `hideWhenNotPlaying` | 共用:暂停整窗隐藏(牺牲收起动画) |
| 外观 → 其它 → 自动隐藏 | 截屏/录屏时隐藏 | `hideDuringScreenCapture` | 共用:sharingType = .none |
| (间接)歌词偏移步长 | `lyricsOffsetStepMs` | 快捷键横幅里显示的增减量随它走 |

已删除的开关(2026-08-17,固定开启):音量提示(`notchVolumeBanner`)、播放指示条(`notchShowEqualizer`);「显示专辑封面」开关 2026-08-10 已删(有封面就显示)。

## 与其它功能的交互

- **PlaybackCoordinator(数据源)**:歌名、当前行/下一句、逐字时间轴、播放锚点、暂停冻结位置/时长、封面(系统 + 高清替代双份)、`notchAccentColor`、`isPlayingSmoothed`、歌词偏移。灵动岛不自己取任何数据。
- **桌面悬浮歌词**:平行实现,互不排斥可同开。共享三个设置(`followsCoverArt` / `hideWhenNotPlaying` / `hideDuringScreenCapture`);字体、字号、三个颜色、描边、宽度、锁定位置全部**不**作用于灵动岛。旧的互斥单选 `overlayStyle` 在 `AppSettings.init()` 一次性迁移成两个独立开关。
- **歌词时间轴微调**(全局快捷键):唯一的视觉反馈渠道就是灵动岛横幅;菜单栏等价按钮无横幅。
- **系统音量**:音量/静音变化 → 灵动岛横幅;监听启停绑定灵动岛开关(`AppDelegate.startObservingVolumeBannerPreference`)。
- **播放控制**:三个按钮和进度条 seek 打的是 `MusicPlaybackController` / `LocalPlaybackSource`,与从哪个窗口(真窗口/预览/副本)点的无关;都过自动化权限异步检查。
- **设置页预览**(`NotchPreviewBar` + `NotchPreviewChrome`):同一份视图代码;chrome 走不碰 `.shared` 的 static 几何函数;预览恒不收起(用户来看样式,收起是空白);宽度超预览区整体等比缩放。
- **菜单栏歌词/歌词窗口**:无直接耦合(各读各的设置和数据)。
- **配置导出/导入**(`ConfigPortability`):`notchScreenID` 被列为机器本地键**不随配置迁移**(屏幕 UUID 在新机器上必然解析不出);其余灵动岛设置正常迁移。

## 数据与文件

- **UserDefaults(np: 前缀)**:`notchOverlayEnabled` / `notchCardStyle` / `notchContentWidth` / `notchScreenID` / `notchAllScreens`。历史迁移:`overlayStyle`(旧互斥单选,只读不删)、`notchOverlayVisible`(旧的菜单栏可见性副本,2026-08-05 折进 enabled 后删除,取逻辑与、绝不把用户已隐藏的窗口重新打开);`notchVolumeBanner` / `notchShowEqualizer` 已登记进 obsolete 键清理。
- **不写任何磁盘文件**;位置不持久化(每次现算)。
- **进程边界**:全部在 lyrimuse 主 App 进程内;歌词/封面数据经 PlaybackCoordinator 来自 collector/本地源,灵动岛不直接跨进程。

## 代码锚点

| 主题 | 位置 |
|---|---|
| 卡片内容视图(顶行/歌词行/展开区/背景/强调色) | `lyrimuse/Sources/lyrimuse/UI/NotchLyricsView.swift` — `NotchLyricsView`、`backgroundLayer`、`topRow`、`lyricRow`、`expandedContent`、`progressSection`、`accentOrWhite` |
| 卡片形状(顶直角底圆角) | 同上 — `NotchHangingShape` |
| 固定尺寸常量 | 同上 — `NotchMetrics` |
| 视图与承载方的契约(真窗口/预览共用) | 同上 — `NotchChromeSource` |
| 窗口控制器(三态/几何/可见性/hover 延迟/屏幕选择) | `lyrimuse/Sources/lyrimuse/UI/NotchLyricsWindowController.swift` — `NotchLyricsWindowController`、`recomputeGeometry`、`geometry(for:)`、`contentWidth(baseWidth:notchWidth:)`、`targetScreen()`、`setVisible`、`setExpandedFromWindow` |
| 窗口本体(level/collectionBehavior/constrainFrameRect) | `lyrimuse/Sources/lyrimuse/UI/NotchLyricsWindow.swift` — `NotchLyricsWindow` |
| 窗口内壳(卡片尺寸/弹簧/hover 命中) | `lyrimuse/Sources/lyrimuse/UI/NotchWindowRoot.swift` — `NotchWindowRoot`、`cardAnimation`、`updateHover` |
| 多屏副本管理 | `lyrimuse/Sources/lyrimuse/UI/NotchMirrorManager.swift` — `NotchMirrorManager.start/refresh/syncAll` |
| 瞬态横幅中心与横幅行 | `lyrimuse/Sources/lyrimuse/UI/NotchTransientCenter.swift` — `NotchTransientCenter`、`NotchTransientRow` |
| 屏幕身份(跨插拔稳定 UUID) | `lyrimuse/Sources/lyrimuse/UI/ScreenIdentity.swift` — `ScreenIdentity.id(of:)/screen(withID:)/notched` |
| 强调色管线(HSB 地板 + luma 地板) | `lyrimuse/Sources/LyrimuseCore/Local/LocalPlaybackSource.swift` — `brightenedAccent`、`accentForDarkBackdrop`;`lyrimuse/Sources/lyrimuse/PlaybackCoordinator.swift` — `notchAccentColor` |
| 播放状态平滑(0.5s 停止宽限) | `lyrimuse/Sources/lyrimuse/PlaybackCoordinator.swift` — `isPlayingSmoothed`、`stopGracePeriod` |
| 设置页灵动岛卡 + 屏幕下拉 | `lyrimuse/Sources/lyrimuse/SettingsView.swift` — `notchOverlayCard`、`autoHideCard` |
| 设置页预览 | `lyrimuse/Sources/lyrimuse/UI/SectionPreviewBars.swift` — `NotchPreviewChrome`、`NotchPreviewBar` |
| 横幅生产者 | `lyrimuse/Sources/lyrimuse/Settings/GlobalHotkeys.swift` — `showOffsetBanner`;`lyrimuse/Sources/lyrimuse/Settings/VolumeMonitor.swift` — `VolumeMonitor.apply` |
| 播放指示条 / 跑马灯 | `lyrimuse/Sources/lyrimuse/UI/EqualizerBars.swift`;`lyrimuse/Sources/lyrimuse/UI/MarqueeText.swift` — `edgeFadeWidth`、`fadeMask` |
| 跑马灯溢出判定 / 渐隐带宽度(纯几何,有 selftest) | `lyrimuse/Sources/LyrimuseCore/Lyrics/MarqueeMath.swift` — `isOverflowing`、`trailingFadeWidth` |
| 菜单栏开关 / 启动恢复 | `lyrimuse/Sources/lyrimuse/MenuBar/MenuBarStatusMenu.swift` — `toggleNotchOverlay`;`lyrimuse/Sources/lyrimuse/AppDelegate.swift` — `startObservingVolumeBannerPreference` |

## 设计决策与已知坑

1. **`.shared` 不变量(最重要)**:`NotchLyricsWindowController.shared` 是 `static let`,任何代码只要引用一下(哪怕读个属性)就会执行 init 建窗口并立刻 orderFront——灵动岛关着的用户会凭空多出一个胶囊,且它 level 在菜单栏之上会盖住菜单栏图标。所有外部路由(AppDelegate/SettingsView/MenuBarMenu/NotchMirrorManager/预览)都必须只在灵动岛确实启用或用户主动操作的分支里碰 `.shared`;预览为此专门有不碰实例的 static 几何函数和替身 chrome。
2. **convenience init 参数不能给默认值**:`pinnedScreenID` 给了默认值后 `NotchLyricsWindowController()` 会解析到 NSWindowController 继承来的 `init()`,建出没有窗口的空壳,灵动岛静默消失且无任何报错(2026-08-16 实翻三次构建)。主实例也显式传 nil。
3. **窗口 level 必须 `.screenSaver` + 覆盖 `constrainFrameRect` 原样返回**:`.statusBar` 都不够(被菜单栏专属渲染层盖住,截图能看到但肉眼看不到);AppKit 默认会把 frame 夹回 visibleFrame 以内导致胶囊脱离刘海。做法对照 DynamicNotchKit 等真实开源实现。
4. **窗口透明区绝不能加 background/contentShape**:透明区压着系统菜单栏,纯透明点击可穿透,加一层哪怕全透明的 contentShape 点击就被吞掉——用户点不动被盖住的菜单栏(2026-08-16 探针窗口实测)。这是"窗口常驻最大尺寸"重构唯一的真风险点。
5. **`.scaledToFill()` 之后、`.clipShape` 之前必须显式钉 frame**:fill 会协商出比可见区更大的 frame,clipShape 按紧邻上层 View 的 frame 画圆角,不钉的话圆角落在偏大矩形边缘、可见区仍是直角——像素级采样踩了三版才找对根因("肉眼看着圆"是模糊的柔化骗人)。背景大图和封面小图两处都适用。
6. **投影与窗口余量是绑死的一对**:展开态卡片加 `.shadow` 必须同时给窗口留投影半径的余量,否则阴影被窗口矩形硬裁、底部圆角外留两块直角残影;2026-08-17 投影和余量已一起撤掉(投影观感是"卡片外糊一层灰",拆穿"从刘海长出来"的设计语言),要加回来必须两件一起。
7. **Combine sink 必须用参数值**:`@Published` 在 willSet 时机发布,闭包里回头读存储属性拿到的是旧值——本功能相关代码(isPlayingObserver、NotchMirrorManager、VolumeMonitor)处处遵守,项目已实测踩过多次。
8. **`isCollapsed` 必须是计算属性**:公式只有一份但挂在 hover 不会走的赋值路径上,导致"暂停时 hover 没反应"(isExpanded 变了 isCollapsed 没跟上);2026-08-17 改计算属性后两个输入哪个变都即时生效。
9. **`hasShadow = false` 是刻意的**:AppKit 给无边框透明窗口自动算的阴影会在贴死屏幕顶边的窗口里内嵌出一圈淡灰,破坏"与屏幕边缘融为一体"。
10. **歌词行的"硬切"和"真遮挡"是两个不同的问题,别拿一个的修法去解释另一个**(2026-08-22):稳态下 HStack 的两个兄弟**永不重叠**,clip 边界恒在封面左边 10pt —— 这一条经真机连拍 60 帧逐像素核过(封面左侧那条 spacing 带里 0 个文字像素)。用户报的「被封面挡住」主要是那个**硬切口紧贴封面**的观感,修法是渐隐带。真正的像素级重叠只发生在"封面在场性变化 + 活动动画同一次更新"这个窄窗口里,修法是 `.animation(nil, value:)`。两者独立,缺一个另一个都还在。
11. **模糊半径不能照搬**:歌词窗口的 60pt 模糊在灵动岛的矮宽画布上会把所有封面抹成同一块深灰,"跟随封面"失去意义;20 是实测保留主色调差异的取值。
