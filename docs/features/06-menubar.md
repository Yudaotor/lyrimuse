# 06. 菜单栏:歌词、图标与菜单

> 最后核对:2026-08-21 · 基线:05767ae+工作树

## 定位

菜单栏这一项是 Lyrimuse 在系统 UI 里的常驻据点:播放时在状态栏滚动显示当前这句歌词,不显示歌词时退回一枚可选样式的小图标(播放中可律动),点开是 App 的主菜单(开关各形态、微调歌词时间轴、打开各窗口、退出)。App 以 `.accessory` 策略运行(可关掉 Dock 图标)时,它是唯一始终可见的入口。

## 入口与展示面

- **状态栏本体**:自建 `NSStatusItem`(2026-08-16 起,不再是 SwiftUI `MenuBarExtra`),`AppDelegate.applicationDidFinishLaunching` 里调一次 `MenuBarStatusItem.shared.start()` 启动,从启动到退出一直都在,生命周期靠 Combine 订阅自持,不依赖任何视图的 onAppear。
- **下拉菜单**:点状态栏项弹出,`MenuBarStatusMenu` 手写的 `NSMenu`(不用 `NSHostingMenu`,那要 macOS 14.4,App 下限 14.0)。
- **设置入口**(两处,见「设置项」):
  - 设置 › 歌词显示 › 「菜单栏」分段:菜单栏歌词开关、宽度模式、最大宽度、逐字染色开关、文字/染色两个颜色项,顶部固定一条实时预览(`MenuBarPreviewBar`,预览反映文字色、暂不演示染色);
  - 设置 › 通用 › 「菜单栏与 Dock」卡:12 款图标网格、「随播放律动」开关。

## 行为规格

### 三态判定(MenuBarStatusItem.refresh)

状态栏此刻显示什么,由 `MenuBarStatusItem.refresh()` 一次性判定,**没有计时器**——只在这些事件发生时重算:换句(`$currentLine` 的 plainText 去重后)、`showLyricsInMenuBar` / `menuBarLyricsWidth` / `menuBarLyricsWidthMode` / `menuBarIconStyle` / `menuBarIconAnimates` 任一设置变化、`isPlayingNow` 变化。每条订阅都 `.receive(on: RunLoop.main)`——`@Published` 在 willSet 时机发射,直接 sink 会读到旧值(项目里实测踩过两次的坑)。

判定顺序:

1. **菜单栏歌词关着 / 没在播放 / 当前句为空** → 小图标独占槽(槽宽 = 图标宽 + 18,出生显式宽)。其中"开关开着但此刻没词"(歌词间隙 / 暂停 / 广告)的收缩带 **3s 观察窗**:先把图标**居中画在还没缩的歌词槽里**顶着,3s 内歌词回来就一次重建都不发生(几何没动过);手动关开关是明确意图,立刻缩(仍受节流保护)。观察窗起点记在 `collapseObserveBegan`,**从第一次提出收缩起算**,不随重算重置(否则推迟的重跑每次发满新窗,收缩被无限顺延)。
2. 否则走 `MenuBarMarqueeRenderer.presentation(...)`,得到两种形态之一:
   - `.text(visible)` → 按钮自己画文字(`button.title`),槽宽逐句跟文字走(adaptive 模式,每次变宽都是一次重建);
   - `.fixed(text, windowWidth, pacing)` → 文字画在图层上,这一格恒占 `windowWidth`;`pacing == nil` 表示装得下、静止显示,非 nil 表示要滚。

所有形态 / 槽宽变化都经 `present()` 的**重建节流**:距上一次重建不足 3s 的几何变化一律推迟、合并成最新目标(原因见「槽位管理终局方案」第 2 条铁律)。**推迟的只是几何,内容不等**(2026-08-19 用户反馈"3s 延迟之后歌词有时不及时更新"——自适应模式逐句都是几何变化,内容跟着等=逐句晚 3s):推迟期间 `renderInterimLyrics` 把最新这句按**当前还没变的槽宽**先画出来(装得下居中静止、装不下就地滚,widthMode 按 .fixed 语义排版),槽宽跟上后按目标重画;唯一例外是当前还是 38pt 图标槽(歌词硬塞只会闪成一条缝,保持图标到重建,首句最多晚一个静默窗)。注意用的是**未平滑**的 `isPlayingNow`——但间隙收放已被观察窗吸收,肉眼看到的多数是"同一个槽里图标↔歌词切换",几何不动。

(2026-08-19 曾短暂改成"fixed 模式下暂停 / 广告也**恒占**歌词槽、永不收缩",当天按用户预期退回——"之前都是正常的",暂停时不该占宽度;观察窗方案保留了它防连发的好处、去掉了永久占宽的代价。)

### 宽度模式与占位

「装得下还是要滚」的判定只有一份(`MenuBarMarqueeRenderer.presentation`),菜单栏本体和设置页预览共用,两边不可能漂。规则:

- `windowWidth <= 0`(正常 UI 到不了,滑杆下限 80pt):退化成截断文字 + 省略号(`truncate`,按像素宽度截,不按字数),tooltip 给完整句。
- 这一句的排版宽度 ≤ 设定宽度 + 0.5pt(差不到半个点就不滚):
  - **fixed(固定,默认)**:照样占满设定宽度,右边留白,footprint 恒定——换句时右边其它 App 的图标不会被顶得左右晃;
  - **adaptive(自适应)**:走 `.text`,按钮按文字实际宽度占位,不占多余空间,代价是长短句来回切时这一项伸缩。
- 装不下:两种模式**完全一样**——占满设定宽度、横向滚动。

固定宽度的实现支点是一张**全透明占位图**(`spacerImage`):`variableLength` 的状态栏项按 `button.image` 尺寸算自己占多宽,给它一张恒为 `windowWidth` 的空图,footprint 就跟内容脱钩,真正的文字画在 `MenuBarScrollingLabel` 的图层上。三种模式下 tooltip 都给完整这一行;图层上的字读屏读不到,`setAccessibilityLabel` 显式补上。

⚠️待核对:adaptive 下装得下的句子走 `button.title` 由 AppKit 自绘,菜单打开时这段文字是否随系统反白自动变色,仓库内没有实测记录(滚动/固定宽度路径的反白是自己实现并处理过的)。

### 滚动规则(跑马灯)

- **驱动方式**:一句歌词排版成一整条长图(`MenuBarMarqueeRenderer.prepare`,一句只画一次),交给 `MenuBarScrollingLabel` 的 `textLayer` 当 contents,滚动是一条 `CAKeyframeAnimation`(position.x),Core Animation 在渲染层插值——主线程每句只干一次活,之后一帧都不碰。这是 2026-08-16 实测定论:此前 MenuBarExtra + 逐帧换图那条路,卡顿根因在驱动方式(每帧要等主线程调度),不在画图性能。
- **运动周期**:开头停(headHold)→ 匀速滚过 `textWidth - windowWidth` → 末尾停(tailHold)→ 循环。关键帧由 `MenuBarMarquee.scrollKeyframes` 生成,与逐帧版 `scrollOffset` 描述同一段运动(selftest 逐点对答案)。
- **配速**(`MenuBarMarquee.pacing`,2026-08-17 加):按「这一句会显示多久」(`PlaybackCoordinator.currentLineDwellSeconds`,取相邻两句时间戳之差,最后一句用曲目时长兜底)倒推速度,让长句在换句之前滚完。规则:
  - 基准每秒 4 个字(`baseCharsPerSecond`),**只加速不减速**;
  - 上限每秒 12 个字(`maxCharsPerSecond`,中文字幕舒适上限附近),撞上限仍滚不完的极长句就是滚不完——明知的取舍,不把字甩成残影;
  - 开头那一停最多 1.5s、且不超过句长的 25%,时间不够就一路让到 0(看得到整句 > 看清开头);
  - **句尾预留**(`tailReadSeconds`,2026-08-19 加):时间允许时滚动比换句**提前 1s 走完**(短句按句长 20% 封顶),末尾几个字来得及读,滚动为此相应加速(仍不越上限);时间紧时尾停**先于**首停让路。此前 travel 直接吃满 dwell − head、恰好在换句那一刻走完,用户实测"一到最后一个字就马上到下一句了";
  - 实际尾停 = 剩余时间 + 0.5s loopGuard,所以时间充裕时一句**只滚一轮**、停在末尾,不反复从头再来;
  - dwell 算不出来(没歌词/最后一句无时长)→ 固定速度、首尾各停 1.5s;
  - 速度按这一句的**平均字宽**换算成 pt/s,中文歌和英文歌「每秒滚过几个字」一致。
- **换句判定**:`$currentLine` 按「首词时间戳#纯文本」`removeDuplicates()` 去重——同一句因译文/罗马音中途补上被重新赋值不算换句,否则滚动会被反复打回开头。⚠️ 2026-08-22 起去重键**带行身份**,不再只看纯文本:副歌里相邻两行同词不同时,只看文本会吞掉第二行的换行事件,逐字染色挂着第一行的路径、第二行一出场整句全染(审阅抓出);「先无逐字、中途补上」同理。推论变更:连续两行文本相同的歌词现在**会**重启滚动(它们本来就是两句,各按各的 dwell 配速)。`present()` 对相同参数仍是空操作。
- **暂停再恢复**:暂停回落图标时 `scrollingLabel.clear()` 清掉 plan,恢复播放同一句会**从头重新滚**。
- **反白与换色**:菜单打开时状态栏项整块反白,文字色从 `labelColor` 换成 `selectedMenuItemTextColor`(`setHighlighted`,由 `MenuBarStatusMenu` 的 menuWillOpen/menuDidClose 转达);系统切浅色/深色也重画。换色只重画位图 contents,**绝不打断正在跑的滚动动画**——点开菜单看一眼再关掉,歌词该滚到哪儿还在哪儿。动态颜色必须在按钮当前 `effectiveAppearance` 下解析,否则深色菜单栏画出几乎看不见的深色字。
- **退场**:必须把 `repeatCount = .infinity` 的动画真的摘掉,不留在隐藏图层上让渲染层空转。

### 逐字染色(2026-08-22,用户点名"像酷狗菜单栏歌词")

- **开关**:设置 › 歌词显示 › 菜单栏 ›「逐字染色」,默认开;只对带逐字时间轴(YRC)的歌词生效,LRC 整行歌词维持纯色(没有可信的字级进度就不假装有)。
- **驱动方式**:跟滚动同一哲学 —— 基础色/强调色两张同字形长图做**互补裁剪**(fillClip 露出已唱区 [0,边界]、baseClip 露出未唱区 [边界,句尾],KTV 式硬切边界);整行填色进程按逐字时间轴一次性编成 **三条共享 beginTime/keyTimes 的 CAKeyframeAnimation**(fillClip 宽 + baseClip 的 position.x/bounds;数学在 `MenuBarMarquee.karaokeFillPath` / `karaokeFillKeyframes`,纯函数,selftest 覆盖),装好后主线程一帧都不碰。两个裁剪层挂在滚动的 contentLayer 里,滚动时天然跟文字焊在一起。词边界像素必须按**前缀整段测宽**(`MenuBarMarqueeRenderer.wordEndXs`),各词单测再累加会被词界 kerning 带漂。⚠️ **不能做成"强调色叠在基础色上面"**(第一版,当天被用户截图打回"染色后有白边"):两张图字形抗锯齿覆盖率相同,叠着画时边缘半透明像素让底下的基础色透出来,深色菜单栏上蓝字四周镶一圈白晕;互补裁剪让每个区域的字形只与背景合成一次。离线 harness 有「已染区白色像素=0」专项断言。
- **染色颜色**:系统 controlAccentColor;**深色菜单栏上向白提亮四成**(`karaokeFillColor`)——强调色按浅底设计,直接压深底上亮度低于旁边的白色基础字,染过的反而更难读(同批用户实测"看不清文字");浅色菜单栏原样。
- **时钟**:位置公式与歌词窗口逐字填色同一条(anchor 外推 ?? 暂停位置,+ 时间轴校准)。对表走独立通道(`syncKaraokeClock`,订阅 $anchor/$pausedPositionMs/$currentLyricsOffsetMs),**不触发槽位 refresh**;标签内部有 **250ms 漂移门** —— 锚点每 ~2s 的例行重发被无声吸收、不打断动画,seek 必然超门重锚,时间轴偏移微调(默认步长 200ms 在门下)走 force 立即生效。暂停静置在当刻边界,恢复从真实位置续染。
- **自适应宽度模式**下装得下的句子原走 `button.title`(AppKit 自绘,没有图层可叠色)——染色时改走图层渲染,槽宽公式不变(文字宽+18),footprint 逐像素一致。宽度 ≤0 的截断退化路径不染。
- **反白期间**(菜单/面板开着)填色整个隐掉:基础字已换成选中色,强调色叠在选中背景上要么撞色要么看不清,关掉恢复。
- 设置页预览(MenuBarPreviewBar)暂不演示染色(没有播放时钟可对)。
- 离线验证:真实 `MenuBarScrollingLabel`+renderer 编成独立 harness 离屏渲染四个静态时刻,逐像素核对边界位置(scratchpad mbkaraoke,2026-08-22 全过)。

### 图标体系(MenuBarIconStyle,12 款)

图标只在**没在显示歌词**时出现(没在放歌、还没解析出这一句、或菜单栏歌词整个关掉),与宽度设置互不影响。全部矢量(SF Symbol 或现画的 NSBezierPath),没有一张 PNG——位图路线 2026-08-17 走死过(老 PNG 字形只占画布 42% 高,放大必糊)。`CaseIterable` 顺序即设置网格展示顺序,默认 `classic`;存储里读到已删款式的 rawValue(音符与歌词/音符与双行/卡拉OK/引号/耳机)时兜底回落默认。静态图带进程内缓存(`cachedImage`),状态栏和设置网格两个调用方共用。

| case | 显示名 | 静态帧来源 | 播放中动效(MenuBarLiveIconView) |
|---|---|---|---|
| classic | 经典 | 自绘:音符 + 三道歌词线(App 图标同款构图,线从音符身后穿过、以抠缝表达压层) | 动效 E:音符不动,三道线右对齐向左伸缩(0.72~1.00 倍宽),相位错开,周期 1.4s;线层戴「压层缝」蒙版 |
| note | 音符 | SF `music.note` | 轻微摇摆 ±約5°,周期 1.6s |
| noteList | 歌词列表 | SF `music.note.list` | 同上摇摆 |
| quarternotes | 三连音符 | SF `music.quarternote.3` | 同上摇摆 |
| waveform | 声波 | SF `waveform` | SF 原生 variable-color 流动(系统符号效果,持续重复) |
| equalizer | 跳动音条 | 自绘三竖条,静置高度 [0.55, 0.85, 0.40] | 三条高度各挂双正弦动画,相位错开,周期 1.2s,下限保住圆头 |
| mic | 麦克风 | SF `music.mic` | 摇摆 |
| metronome | 节拍器 | 自绘,机身+摆针两张图,静态帧合成斜针 | 只有摆针绕支点摆 ±17°,周期 1.1s,机身纹丝不动 |
| pianokeys | 钢琴键 | 自绘键盘(边框+分隔线+黑键) | 键盘不动,四个白键按压高亮按 1-3-2-4 顺序轮流点亮,周期 1.8s |
| tuningfork | 音叉 | SF `tuningfork` | 高频微颤:±0.6pt 横移,0.18s 一个来回 |
| disc | 光盘 | 自绘:圆盘 + 大中孔 + 两道对置高光楔 | 顺时针匀速旋转,4.0s/圈 |
| vinyl | 黑胶唱片 | 自绘:唱盘(沟纹+标芯+偏心标记点)+ 唱臂,静态帧合成 | 只转唱盘(3.2s/圈),唱臂静止当参照物 |

**动画机制**(`MenuBarLiveIconView`):

- 只在「`menuBarIconAnimates` 开 × 正在播放」时上场;暂停/无播放/该显示歌词时整层退场,静态模板图接管——所以「暂停即静止」不是开关,是硬行为,开关只管播放时动不动。
- 全部 Core Animation 驱动,没有 Timer 换帧(第一版 10fps Timer 音条被用户实测「卡卡的」——平滑形变吃不消低帧率,且主线程 20Hz 逐字高亮会挤计时器)。连续曲线用 48 点/轮采样的 `CAKeyframeAnimation`(`sampledAnimation`),首尾同值循环无缝。
- 结构动画(旋转/摆动)必须挂在**裸 CALayer**(`movingPart`)上,绝不能挂 NSImageView 的视图背板层——AppKit 拥有那个层的几何,叠上去实测是「画圈不自转」(2026-08-17 连报三轮,换字形无效,机制问题)。
- 上场时按钮里放一张撑尺寸的透明占位图,footprint 与静态款逐像素一致;同款重复 `present` 是空操作(不打回相位起点)。
- 裸图层 contents 吃不到系统模板着色,颜色由 `applyColor`/`tintedContents` 现染;菜单开合换 `selectedMenuItemTextColor`、换外观重染,均不打断动画。
- waveform 的符号效果必须显式给 repeat 选项(macOS 15 用 `.repeat(.continuous)`,14 用 `.repeating`)——默认按「播一轮就停」处理,实测不带选项流动一轮就冻住。
- 点击穿透:`hitTest` 返回 nil,点击落到底下的状态栏按钮弹菜单(滚动歌词层同理)。

### 左键面板(MenuBarPanel,2026-08-19「控制中心风」)

用户从九个设计方向里选定 F:左键弹 NSPopover(transient,点外面自动收),内容为悬浮卡片群——
- **正在播放卡**(全宽):封面(无封面给渐变占位)、歌名/歌手、「记录中」红点(镜像开 && 在放 && 非广告)、右上角**来源角标**(当前播放器的真实 App 图标,NSWorkspace 按 bundleID 取、按 bundleID 缓存,悬停给名字;认不出来整个不显示)、**可拖进度条**(播放态 TimelineView 0.5s 外推/暂停态冻结,松手才 `seek(toMs:)`,与灵动岛同语义)、上一首/播放暂停/下一首;
- **圆钮块两排**:第一排三种歌词展示形态开关(悬浮歌词/灵动岛/菜单栏歌词,圆钮填充强调色=开;2026-08-19 用户提议补齐第三兄弟,标题带 minimumScaleFactor 防挤。⚠️ 菜单栏歌词开关必须**先收面板、延迟 0.5s 再切**(0.25s 不够——popover 退场动画 ~0.3s):popover 锚在状态栏按钮上时项的重排被系统推迟,双向都实测中过招(开:歌词画出而项不变宽,文字甩到邻居头上;关:图标已换而项不缩回)。**槽位管理终局方案**(2026-08-19,四轮翻车后 AX 全菜单栏项地图坐实):macOS 26 的菜单栏**只在项出生那一刻**按当时宽度给邻居排位——事后换 image 撑宽/缩窄、重踢 length、甚至拆掉重建但宽度事后才到,邻居都不让位(表现:歌词压到别家图标头上/收窄后留空椭圆;期间的 AX 自查全是"自己项的账",看不出邻居没让位,是排查最大弯路)。修法=`present(class:length:collapseDelay:render:)`:icon/text/fixed 三态切换时整项重建(`rebuildStatusItem`),且**出生就带显式 length**(fixed=窗宽+18 内边距;text=逐句文字宽+18);autosaveName 保住排序位置;逐句歌词更新不触发重建。**第六轮定案(2026-08-19)**,两条铁律:①「同态内改宽走 `item.length` 直赋」被撤销——原地改 length 同样不给邻居重排,**任何**形态或槽宽变化都必须重建;②**重建不能连发**——单次从容的重建从未观察到排坏,但两次重建相隔 ~1s(实测 1.1s 的歌词间隙收放;用户连改几项设置同理)会把**邻居的像素**晾在旧位置不动,而 **AX 账面此时已是新位置(AX 全图看着完全健康,会说谎!)**,歌词画进新槽正好压到邻居残影上,且**保持不自愈**直到下一次从容重排;验证只能靠**截图像素对照 AX**。落地:`present()` 重建节流(距上次 <3s 推迟合并)+收缩 3s 观察窗(间隙常 1~2s 结束,整对重建省掉;起点记 `collapseObserveBegan` 防无限顺延)+宽度滑杆订阅 debounce 250ms;重建落 notice 级日志(info 不落盘,查不到现场;3s 节流后至多 1 条/3s);推迟(deferred)是自适应模式逐句的常态路径,2026-08-19 降为 debug 免逐句落盘。面板开着时的 suppressed 分支同样内容不等几何:图标就地画、歌词走 renderInterimLyrics 过渡(零重建零碰锚点),自适应模式下面板开启期间状态栏歌词不再冻在旧句。MenuBarScrollingLabel.present 对「同句只换槽宽/配速」的调用不再重排位图(text 未变即复用 prepared 长图,只按新几何重跑动画)。另有 label 自身 layer masksToBounds+裁剪窗钳制作兜底(内容物理出不了自身 frame)。验证方式:AX 枚举**全部应用**的 AXExtrasMenuBar 项框架看邻居是否让位(只量自己永远量不出这个 bug)。);第二排歌词窗口(入口)、统计(入口→设置的 Last.fm 账号页,副文字「今天 N 次」来自 LastfmStatsService.overview);
- **细底栏**:设置…/歌词管理…/更多(收面板后弹完整菜单)。

面板视图经 `PanelPlayback` 窄代理订阅(2026-08-19,四个展示面最后一个接上:只转发实读的 ~16+4 个字段并去重,anchor 入订阅、offset 由填色闭包直读;逐字行 paused 并入 currentLineFillSettled 行尾停表;进度条+时间轴微调抽成自持拖动状态的 PanelProgressSection 子视图);didClose 时 popover 置 nil 整树即时释放(原来滞留到下次 toggle,离窗死树白挨派发)。右键完整菜单只在 menuNeedsUpdate 构建一遍(原来 makeMenu 先 rebuild 一次,每次弹出白构建两遍)。**失焦收起三道**(2026-08-19 用户实测补):`.transient` 只管 App 语境内点击(accessory App 面板弹出不激活 App,点别的应用不触发)——补全局鼠标监视器(落在别的 App 的任何按下)+ `didResignActive`(cmd-tab);都挂在弹出那一刻、didClose 统一拆,面板不在时零常驻监听。点击路由在 MenuBarStatusItem:菜单**不再常挂** `item.menu`(挂着=任何点击都弹菜单),button 收 `[.leftMouseUp, .rightMouseUp]`,左键 toggle 面板、右键/⌃左键走 `popUpFullMenu()`(临时挂 menu + performClick,弹完摘掉)。面板开合与菜单开合共用滚动歌词/图标的反白回调。⚠️ 渲染路径沿用 MenuBarStatusMenu 的不变量:只读 AppSettings,不碰两个悬浮窗控制器的 `.shared`(动作闭包里才可以)。

### 下拉菜单(MenuBarStatusMenu,右键)

每次弹出前整棵重建(`menuNeedsUpdate`),显示的一定是此刻状态;`autoenablesItems = false`,所有项常驻可点。结构(自上而下):

1. **快速开关**(子菜单):显示桌面悬浮歌词 / 显示灵动岛歌词 / 显示菜单栏歌词(三个带勾选态的 toggle)→ **锁定位置**(仅 `classicOverlayEnabled` 为真时出现,图标随锁定状态换 lock.fill/lock.open.fill)→ 分隔线 → 开机启动。
2. **歌词时间轴**(子菜单,仅 `PlaybackCoordinator.title` 非空——即本次进程收到过曲目信息——时出现):「提前 X秒」「延后 X秒」(X = 可调步长,默认 0.2 秒);当前曲目微调非 0 时追加分隔线 + 「重置」。菜单标题直接带当前值,如「歌词时间轴(+0.6s)」——**只显示这首歌那部分,不含全局基准**(否则「重置」后数字对不上操作);格式化与按钮共用 `AppSettings.formattedSeconds`,步长设成 0.15s 之类也不会两处四舍五入不一致。
3. 分隔线 → **设置…**、**歌词管理…** → 分隔线 → **歌词窗口…** → 分隔线 → **检查更新…**、**重新运行引导…**、**关于 Lyrimuse** → 分隔线 → **退出 Lyrimuse**。分组逻辑:配置/管理、看歌词本身、了解 App、退出,各成一串。

行为细节:

- **构建路径的不变量**:重建菜单时只读 `AppSettings`,绝不碰 `LyricsOverlayWindowController.shared` / `NotchLyricsWindowController.shared`——两个控制器是 `static let shared`,碰一下就会 init 建窗并按当下状态显示一次,等于「点开一次菜单把用户关掉的悬浮窗凭空建出来」。唯一例外是「锁定位置」读 `isPositionLocked`,它只在 `classicOverlayEnabled` 为真(控制器必然已存在)时构建。action 里可以碰——那是用户主动操作。
- **歌词时间轴的方向语义**:「提前」= `nudgeLyricsOffset(by: +步长)`,正偏移让歌词提前出现(引擎里 `posMs = rawPosMs + offsetMs`);「延后」传负值。微调只对当前这首歌生效、立即生效(不等换歌);无曲目信息时静默不做。「重置」只清这首歌的微调,**不动全局基准、也不动按播放器那层**(那两层一个是设备侧固定延迟、一个是播放器侧系统性偏差,都在设置页调)。菜单里 nudge 没有即时反馈条(快捷键那条路才有灵动岛提示),但下次点开菜单标题上的累计值会更新。
- **打开窗口的动作**都走 `AppActions` 里注册的闭包(闭包内已带 `NSApp.activate(ignoringOtherApps:)`——`.accessory` 策略下少了这步窗口打不开)。闭包由 `MenuBarSceneActions` 在一扇永不显示的 1×1 锚点窗口里从 SwiftUI 环境捕获;其中「设置…」还要多绕一圈:场景树外 `openSettings()` 是静默空操作,唯一实测有效的是直接触发主菜单里 SwiftUI 自己那条「设置… ⌘,」(按 ⌘, 识别,不按标题/私有 selector 名)。
- **关于 Lyrimuse** = 打开设置窗口并经 `AppActions.pendingSettingsSelection` 直接跳到「关于」分类。「检查更新…」先手动激活 App 再调 Sparkle,否则 `.accessory` 下点了没反应。
- **菜单开合回调**同时转达给滚动歌词层和活体图标层做反白换色。

## 设置项

| 位置 | 设置项 | UserDefaults key | 默认 | 改什么行为 |
|---|---|---|---|---|
| 歌词显示 › 菜单栏 | 菜单栏歌词(开关) | `np:showLyricsInMenuBar` | 关 | 关=永远只显示图标 |
| 歌词显示 › 菜单栏 | 宽度模式(固定/自适应) | `np:menuBarLyricsWidthMode` | fixed | 只影响装得下的句子怎么占位(见上) |
| 歌词显示 › 菜单栏 | 最大宽度(滑杆 80~600pt,步进 10) | `np:menuBarLyricsMaxWidth` | 200pt | 歌词格宽度;fixed 模式下即恒定占宽(UI 标题仍叫「最大宽度」) |
| 歌词显示 › 菜单栏 | 逐字染色(开关) | `np:menuBarLyricsKaraoke` | 开 | 见「逐字染色」一节;只对带逐字时间轴的歌生效 |
| 歌词显示 › 菜单栏 | 文字颜色(色轮+「跟随系统」) | `np:menuBarLyricsTextColorHex` | 空=跟随系统 | 未唱部分/整行的文字色。空串=labelColor 自适应+反白;自定义色原样用(反白态仍换选中色);自适应 button.title 退化路走 attributedTitle |
| 歌词显示 › 菜单栏 | 染色颜色(色轮+「跟随系统」,仅逐字染色开着时显示) | `np:menuBarLyricsFillColorHex` | 空=跟随系统 | 已唱部分的颜色。空串=系统强调色+深色菜单栏提亮四成;自定义色**原样用、不再自动提亮** |
| 通用 › 菜单栏与 Dock | 菜单栏图标(12 款网格) | `np:menuBarIconStyle` | classic | 未显示歌词时那枚图标的样式,点选立即生效 |
| 通用 › 菜单栏与 Dock | 随播放律动(开关) | `np:menuBarIconAnimates` | 开 | 播放时图标动不动;暂停永远静止 |
| 快捷键 › 调整步长 | 调整步长(50~2000ms) | `np:lyricsOffsetStepMs` | 200ms | 菜单「提前/延后」和两个快捷键每按一次调多少,菜单项文案跟着变 |
| 歌词 › 时间轴偏移 | 播放器下拉框 + Stepper ±5s,步长固定 0.05s | (LyricsOffsetStore 全局 key / 按播放器字典) | 0 | 下拉「全部播放器」= 对所有歌生效的设备侧基准;选具体播放器 = 那个播放器**取代**共用那档的值(二选一,不叠加)。基准再与单曲微调相加;两者都不显示在菜单标题里 |

另:`np:menuBarLyricsMaxChars` 是 2026-08-15 之前「按字数」时代的旧 key,已无读取方,仅为兼容老配置保留。

## 与其它功能的交互

- **数据来源**:当前句文本、播放态、句停留时长、曲目微调值全部来自 `PlaybackCoordinator`(它是 `LocalPlaybackSource` 的转发层);配速依赖的 `currentLineDwellSeconds` 用相邻两句时间戳之差,所以歌词时间轴校准不影响它。
- **歌词时间轴三处入口共享**:菜单「提前/延后」、全局快捷键(`GlobalHotkeys`,快捷键那条路会在**灵动岛**闪一条「歌词偏移 +0.50s」提示,只开悬浮歌词的人无反馈)、「歌词管理」窗口的偏移输入框,底层都是 `LyricsOffsetStore`;步长与菜单文案共用 `lyricsOffsetStepMs`。设置页那一行时间轴偏移是叠加的另**两**层(「全部播放器」= 全局基准,选具体播放器 = 按播放器那层)。
- **快速开关联动**:悬浮歌词/灵动岛的开关经各自 WindowController 的 `setVisible`(与设置页、全局快捷键同一入口);「锁定位置」= 持久化 `lockPosition` + `setLocked` 两步,与快捷键处逻辑一致;「开机启动」直接翻 `launchAtLoginEnabled`。
- **设置页预览**(`MenuBarPreviewBar`):不是仿品,直接复用菜单栏本体——同一个 `presentation` 判定、同一个 `MenuBarScrollingLabel`(经 `Representable` 包装)、同一套菜单栏字体;正在播放时预览演真实当前句和真实配速,没播放时演示例句(dwell 给 nil 走固定速度)。垫底用真实桌面壁纸 + `.ultraThinMaterial` 合成菜单栏质感。
- **窗口打开链路**:菜单的「设置/歌词管理/歌词窗口/引导」四个动作依赖 `MenuBarSceneActions.install()` 建的锚点窗口先注册好 `AppActions` 闭包(AppDelegate 里紧跟 `start()` 之后);首次启动的引导向导也从那个锚点延迟 0.5s 拉起。
- **字体跟随系统**:歌词用 `NSFont.menuBarFont(ofSize: 0)`,系统改菜单栏字号会跟着变,静态文字路径与图层路径同一字体,切换时字号不跳。

## 数据与文件

- **UserDefaults(standard)**:上表 7 个 key,全部 `np:` 前缀,经 `AppSettings` 读写;单曲微调与全局基准由 `LyricsOffsetStore` 存 UserDefaults(JSON 字符串 + 独立全局 key,`defaults read` 可读)。
- **磁盘文件**:无——菜单栏功能本身不落盘;所有位图(歌词长图、染色图标)都是进程内现画现用。老的 `Resources/MenuBarIconTemplate.png` 留作历史资料,不再参与渲染。
- **进程边界**:全部在 lyrimuse 主 App 进程内,不涉及 collector/worker。

## 代码锚点

| 主题 | 文件 + 符号 |
|---|---|
| 状态栏总控、三态判定、透明占位图 | `lyrimuse/Sources/lyrimuse/MenuBar/MenuBarStatusItem.swift` · `MenuBarStatusItem`(`refresh` / `showIcon` / `showStaticText` / `showFixedWidth` / `spacerImage`) |
| 装得下/要滚的唯一判定、长图排版、按宽截断 | `lyrimuse/Sources/lyrimuse/MenuBar/MenuBarMarqueeRenderer.swift` · `MenuBarMarqueeRenderer`(`presentation` / `Presentation` / `prepare` / `truncate`) |
| 滚动图层、反白换色不打断动画 | `lyrimuse/Sources/lyrimuse/MenuBar/MenuBarScrollingLabel.swift` · `MenuBarScrollingLabel`(`present` / `rebuildImage` / `restartAnimation` / `Representable`) |
| 关键帧、配速算法、速度上下限常量 | `lyrimuse/Sources/LyrimuseCore/Lyrics/MenuBarMarquee.swift` · `MenuBarMarquee`(`scrollKeyframes` / `pacing` / `ScrollPacing`) |
| 12 款图标枚举、静态帧绘制、缓存 | `lyrimuse/Sources/lyrimuse/MenuBar/MenuBarIconStyle.swift` · `MenuBarIconStyle`(`cachedImage` / `makeImage` / `classicArtwork` 等各款 artwork) |
| 图标活体动画(CA 驱动、裸层、染色) | `lyrimuse/Sources/lyrimuse/MenuBar/MenuBarLiveIconView.swift` · `MenuBarLiveIconView`(`present` / `build*` 各款 / `applyColor` / `tintedContents`) |
| 下拉菜单结构与全部动作 | `lyrimuse/Sources/lyrimuse/MenuBar/MenuBarStatusMenu.swift` · `MenuBarStatusMenu`(`rebuild` / `offsetMenuTitle` / 各 `@objc` action) |
| 环境 action 锚点窗口、设置窗打开的特殊路径 | `lyrimuse/Sources/lyrimuse/MenuBar/MenuBarSceneActions.swift` · `MenuBarSceneActions`(`install` / `presentSettings`)、`SceneActionRegistrar` |
| 句停留时长、偏移转发 | `lyrimuse/Sources/lyrimuse/PlaybackCoordinator.swift` · `currentLineDwellSeconds` / `nudgeLyricsOffset` / `trackLyricsOffsetMs` |
| 偏移的真正执行与叠加 | `lyrimuse/Sources/LyrimuseCore/Local/LocalPlaybackSource.swift` · `nudgeLyricsOffset` / `resetLyricsOffset` / `applyOffsets` |
| 菜单栏相关设置属性与默认值 | `lyrimuse/Sources/lyrimuse/Settings/AppSettings.swift` · `showLyricsInMenuBar` / `menuBarLyricsWidth` / `menuBarLyricsWidthMode` / `menuBarIconStyle` / `menuBarIconAnimates` / `MenuBarLyricsWidthMode` |
| 设置页卡片与图标网格 | `lyrimuse/Sources/lyrimuse/SettingsView.swift` · `menuBarCard` / `GeneralSettingsTab.menuBarIconChoice` |
| 设置页实时预览 | `lyrimuse/Sources/lyrimuse/UI/SectionPreviewBars.swift` · `MenuBarPreviewBar` |

## 设计决策与已知坑

1. **放弃 MenuBarExtra 是实测逼出来的**:探针读出它把 label 快照成一张 NSImage 塞进 `button.image`,视图侧没有活图层可挂动画——滚动只能逐帧换图,顺滑度受主线程调度摆布;画图性能从来不是瓶颈(0.057ms/帧),优化画图治不了卡顿。
2. **`@Published` 的 willSet 时机坑**:回调里转头读单例当前状态会读到旧值,所有订阅必须 `.receive(on: RunLoop.main)`——本项目实测踩过两次,漏一条的症状是「菜单栏永远不显示歌词」。
3. **订阅必须挂在现用的设置字段上**:2026-08-15 宽度从字数改成点时订阅一度还挂在旧 `maxChars` 上,拖滑杆完全不生效。
4. **判定逻辑只能有一份**:预览曾自己另写一套判定,和实际必然漂(用户报「预览要真实模拟实际菜单栏」),解法是预览直接复用本体的函数和视图。
5. **构建菜单绝不碰窗口控制器单例**:`static let shared` 引用即建窗,构建路径上碰一下等于点开菜单就把用户关掉的悬浮窗建出来(与 AppDelegate/SettingsView/GlobalHotkeys 同源的不变量)。
6. **场景树外 `openSettings()` 是静默空操作**,且失败方式有欺骗性(窗口开着时它能带到前台,像是正常);唯一实测有效的是触发主菜单里 SwiftUI 自己那条 ⌘, 菜单项。
7. **结构动画不能挂视图背板层**:AppKit 拥有 NSImageView 背板层的几何,变换叠上去是「画圈不自转」;必须用裸 CALayer(黑胶走裸层没事、光盘走视图层不行,对照坐实)。
8. **旋转对称图形转起来不可见**:黑胶 v1 纯同心圆「转了也看不出来」,必须有不对称特征(偏心标记点)+ 静止参照物(唱臂);光盘同理靠两道对置高光楔。
9. **摆针款退场要把 anchorPoint 归位**,否则下一款绕中心转的盘会继承歪轴;waveform 符号效果不显式给 repeat 选项会流动一轮就冻住。
10. **持久化 key 不随语义改名**:宽度从「最多占多宽」改成「固定占多宽」时 key 仍是 `np:menuBarLyricsMaxWidth`,老用户设置照常读出;旧 `menuBarLyricsMaxChars` 留在配置里但无读取方。
11. **macOS 26 状态栏项重建不能连发,且 AX 验证会说谎**(2026-08-19,错位第六轮定案):两次重建相隔 ~1s(实测 1.1s)会把邻居的**像素**晾在旧位置——AX 账面已更新(全图无重叠、看着完全健康),屏幕像素却是旧布局,歌词压到邻居残影上且**保持不自愈**;单次从容的重建从未观察到排坏。所以:重建节流(<3s 推迟合并)+收缩观察窗(见「三态判定」);验证必须**截图像素**对照 AX,只信 AX 等于白验(前五轮多次"AX 验证通过"后用户仍复现,就是这个原因);重建/推迟落 notice 日志(info 级不落盘,事后取不到现场)。宽度滑杆的订阅换成 `debounce 250ms`(拖动过程每个中间值都排队重建没有意义)。曾按「重建偶发有毒、只能压次数」的中间结论把 fixed 模式改成暂停/广告恒占歌词槽,当天按用户预期退回,由观察窗方案替代。
