# 06. 菜单栏:歌词、图标与菜单

> 最后核对:2026-09-01 · 基线:5d9031a+工作树

## 定位

菜单栏这一项是 Lyrimuse 在系统 UI 里的常驻据点:播放时在状态栏滚动显示当前这句歌词,不显示歌词时退回一枚可选样式的小图标(播放中可律动),点开是 App 的主菜单(开关各形态、微调歌词时间轴、打开各窗口、退出)。App 以 `.accessory` 策略运行(可关掉 Dock 图标)时,它是唯一始终可见的入口。

## 入口与展示面

- **状态栏本体**:自建 `NSStatusItem`(2026-08-16 起,不再是 SwiftUI `MenuBarExtra`),`AppDelegate.applicationDidFinishLaunching` 里调一次 `MenuBarStatusItem.shared.start()` 启动,从启动到退出一直都在,生命周期靠 Combine 订阅自持,不依赖任何视图的 onAppear。
- **下拉菜单**:点状态栏项弹出,`MenuBarStatusMenu` 手写的 `NSMenu`(不用 `NSHostingMenu`,那要 macOS 14.4,App 下限 14.0)。
- **Dock 右键菜单**(2026-08-26 新增,仅「在 Dock 中显示」开着、`.regular` 激活策略时才有 Dock 图标可右键):`AppDelegate.applicationDockMenu(_:)` 返回 `DockMenuController.makeMenu()` 的结果,固定四项——设置…/歌词管理…/歌词窗口…/Last.fm,点了分别跳对应窗口/设置页。这四项由 AppKit 摆在它自动追加的那部分(当前开着的窗口列表、「选项」子菜单、显示所有窗口/隐藏/退出)**上面**,`DockMenuController` 不需要重复画那些系统默认项。见「设计决策与已知坑」第 14 条。
- **设置入口**(两处,见「设置项」):
  - 设置 › 歌词显示 › 「菜单栏」分段:2026-09-01 改成跟悬浮歌词/灵动岛一样的"编辑台"风格
    (`MenuBarEditorStage`,取代原来平铺的 `menuBarCard`)——实时预览(`MenuBarPreviewBar`,
    反映文字色;正在播放且这句有逐字数据时也演真实染色,没播放的示例句不演,见「卡拉OK染色」
    一节)挪进了可滚动内容区的编辑台里(不再是页顶固定不可交互的一条),工具栏两个浮层
    入口(「宽度模式」/「配色」)+「重置 ▾」,「最大宽度」单独常驻一条调整条,菜单栏歌词
    开关留在编辑台下面,「全部设置」抽屉(`MenuBarAllSettingsDrawer`)五项全量兜底;
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
- **配速**(`MenuBarMarquee.pacing`,2026-08-17 加):按「这一句会显示多久」(`PlaybackCoordinator.compactDwellSeconds`,2026-08-23 从 `currentLineDwellSeconds` 换过来)倒推速度。⚠️ **换口径是必须的,不是顺手**:「唱完就切」之后显示窗口不再是「本句时间戳→下句时间戳」——长句后面接一段长间奏时,旧口径会把 dwell 算大,句子却在**唱完那一刻**就被换走,结果是只滚出开头一小截就没了,**比改动前更糟**。新口径 = 实际显示窗口(`CompactLyricLead.displayDurationMs`:出现于上一句唱完 / 本句开始前 5 秒中较晚者,消失于本句唱完);**2026-08-24 起最后一句也由引擎算**:曲长经 `tickQuery(trackEndMs:)` 喂进去当 `displayDurationMs` 的曲末兜底,所以 `compactDwellMs` 对整首歌每一句都是**行常量**。这不是顺手优化 —— 原来最后一句退回 `currentLineDwellSeconds`,那条退路 ① 按 `currentLineIndex` 取行,而提前量窗口里那是**已经唱完的上一句**(错基数);② 它的值在开唱那一刻(`currentLineIndex` 前进)会**突变** → `plan.pacing` 变 → 滚动被重装,而首停含提前量,重装等于把提前量**再等一遍**(最长 5 秒),最后一句可能整段唱完都不滚。剩下那条退路只在「连曲长都不知道」时可达,且**刻意不**在它上面叠提前量(错基数上算得更精细没有意义)。规则:
  - 基准每秒 4 个字(`baseCharsPerSecond`),**只加速不减速**;
  - 上限每秒 12 个字(`maxCharsPerSecond`,中文字幕舒适上限附近),撞上限仍滚不完的极长句就是滚不完——明知的取舍,不把字甩成残影;
  - 开头那一停最多 1.5s、且不超过句长的 25%,时间不够就一路让到 0(看得到整句 > 看清开头);
  - **句尾预留**(`tailReadSeconds`,2026-08-19 加):时间允许时滚动比换句**提前 1s 走完**(短句按句长 20% 封顶),末尾几个字来得及读,滚动为此相应加速(仍不越上限);时间紧时尾停**先于**首停让路。此前 travel 直接吃满 dwell − head、恰好在换句那一刻走完,用户实测"一到最后一个字就马上到下一句了";
  - **开唱之前不滚**(`leadInSeconds`,2026-08-24 用户报「已经到下一行了,但是还没开始染色的时候不需要滚动,现在是会滚」):提前量窗口里这一句**已经显示、但还没开唱**,也就还没染色,滚动必须等它走完才起步 —— 首停以提前量为**下限**(`CompactLyricLead.leadInMs` → `PlaybackCoordinator.compactLeadInSeconds` → `MenuBarMarquee.pacing`)。原来首停只看那 1.5s 上限,提前量一超过它(实测平均 0.90s、p90 1.75s、p95 3.03s,上限 5s),一句还没开唱的歌词就自己先滚起来了。⚠️ 抬高首停**不会**重蹈上面那个「按偏大 dwell 配速」的坑:travel 本来就是 `dwell − head − tail` 算的,head 一抬,不能滚的那段时间**自动**从行程里扣掉了(selftest 钉了「扣掉提前量之后能滚完的就一定滚完」这条不变式)。提前量按 `revealMs` 钳上界 —— 首停是死等,上游时钟脏数据不钳的话能把跑马灯钉死不动;
  - 实际尾停 = 剩余时间 + 0.5s loopGuard,所以时间充裕时一句**只滚一轮**、停在末尾,不反复从头再来;
  - dwell 算不出来(没歌词/最后一句无时长)→ 固定速度、首尾各停 1.5s;
  - 速度按这一句的**平均字宽**换算成 pt/s,中文歌和英文歌「每秒滚过几个字」一致。
- **换句判定**:`$currentLine` 按「首词时间戳#纯文本」`removeDuplicates()` 去重——同一句因译文/罗马音中途补上被重新赋值不算换句,否则滚动会被反复打回开头。⚠️ 2026-08-22 起去重键**带行身份**,不再只看纯文本:副歌里相邻两行同词不同时,只看文本会吞掉第二行的换行事件,逐字染色挂着第一行的路径、第二行一出场整句全染(审阅抓出);「先无逐字、中途补上」同理。推论变更:连续两行文本相同的歌词现在**会**重启滚动(它们本来就是两句,各按各的 dwell 配速)。`present()` 对相同参数仍是空操作。
- **开唱那一下不重启滚动**(2026-08-24):菜单栏订了两条歌词流(见下面「唱完就切到下一句」和踩坑记录 12),开唱那一刻 `currentLine` 变化会重画一次、把逐字填色挂上。`MenuBarScrollingLabel.present` 因此只在**滚动参数**(文字 / 槽宽 / 配速)真的变了时才 `restartAnimation`;`fillPath` 由 nil 变非 nil **不算**滚动参数变化。原来它算 plan 变化、会把滚动打回开头 —— 提前量窗口里那一句本来已经静止等着了,开唱那一下再从零起一遍首停,等于把提前量**白等两遍**,长句更滚不完。参数没变但动画不在(首次装上 / `clear()` 之后 / 这句本来不用滚)仍会跑一趟,那是自愈的一半。
- **暂停再恢复**:暂停回落图标时 `scrollingLabel.clear()` 清掉 plan,恢复播放同一句会**从头重新滚**。
- **反白与换色**:菜单打开时状态栏项整块反白,文字色从 `labelColor` 换成 `selectedMenuItemTextColor`(`setHighlighted`,由 `MenuBarStatusMenu` 的 menuWillOpen/menuDidClose 转达);系统切浅色/深色也重画。换色只重画位图 contents,**绝不打断正在跑的滚动动画**——点开菜单看一眼再关掉,歌词该滚到哪儿还在哪儿。动态颜色必须在按钮当前 `effectiveAppearance` 下解析,否则深色菜单栏画出几乎看不见的深色字。
- **退场**:必须把 `repeatCount = .infinity` 的动画真的摘掉,不留在隐藏图层上让渲染层空转。

### 唱完就切到下一句(2026-08-23)

单行展示面(灵动岛歌词行 / 菜单栏歌词 / 菜单栏面板那一格)**不再等下一句开始才换行**:本行
唱完那一刻就切走,把行间的空档变成提前量,方便跟唱。规则在 `CompactLyricLead.resolve`,
经 `LyricsSyncEngine.tickQuery` 的 `compactLine` / `compactPlaceholder` 出到
`LocalPlaybackSource` → `PlaybackCoordinator`。

- 本行唱完 → 离下一句 ≤ **5 秒**(`CompactLyricLead.revealMs`)就直接亮出下一句(未染色);
- 离下一句还远(长间奏)→ 中段显示 **♪**,到剩 5 秒时才亮出下一句;
- **行级 LRC 不抢跑**:不知道一行唱多久就不猜 —— 猜早了会在人还在唱这句时把它换掉,比原来更糟;
- **最后一句唱完不切走**:后面没有句子可提前,切成 ♪ 只会让尾奏变空屏。

⚠️ **跟歌词窗口的 `scrollLeadIndex` 是两套,别合并**:那个服务多行列表,间奏里有「•••」可以
停靠,所以它的规则是"点亮期间不动、窗口结束前 `leadMs` 才领先";单行面没有可停靠的东西,
已经唱完的句子继续挂着就是在冒充"正在唱"。

**实测(用户曲库 351 首有歌词、其中 338 首有逐字)**:12893 个行间隙,平均每次换行提前
**0.90 秒**(中位间隙只有 0.22s,提前量集中在长尾:p90 1.75s、p95 3.03s);♪ 出现 502 次
= 占换行数 **3.9%**,单次平均 10.1 秒。13 首行级 LRC 行为一字不变。

染色/均衡器条子仍看 `currentLine`(那是"此刻在唱哪个字"),**只有"显示哪一句"改看
`compactLine`** —— 提前量窗口里显示的是下一句、填色为 0,开唱时自然开始填。

菜单栏跑马灯**在这段提前量里不滚**(2026-08-24 补):没染色就是还没开唱,滚动等到开唱才
起步。量化口径是 `CompactLyricLead.leadInMs`,它跟 `displayDurationMs` **共用同一个
`appearMs`**(出现时刻)—— 一个算窗口有多长、一个算窗口前半段有多长,各写一遍必然漂成
"提前量比整个窗口还长"。落地细节见上面「滚动规则」里那条「开唱之前不滚」。

### 对齐方式(2026-09-01,用户点名)

固定宽度那一格里,**装得下的**短句靠哪边。`AppSettings.menuBarLyricsAlignment`
(`MenuBarLyricsAlignment`:leading/center/trailing,默认 leading)。

- **只在固定宽度模式下出现**,而且这不是省事、是定义使然。用户自己先判断出来的(原话:
  「看起来是不是只会在固定宽度模式下生效?我理解自适应的模式下不存在对齐模式」)——对的:
  - **自适应模式**下那一格的宽度**就等于**文字宽度(见 `MenuBarLyricsWidthMode.adaptive`),
    没有多余空间,三个选项画出来一模一样;
  - **固定宽度下放不下**的句子会横向滚动,文字比格子宽,同样没有空位。
  所以设置界面用 `if settings.menuBarLyricsWidthMode == .fixed` 整行不渲染,**不用
  `.disabled`** —— 灰着摆在那儿会让人去猜"要满足什么条件才能点"(同一段里「已唱到的颜色」
  跟着染色开关显隐是同一个做法)。
- **落地点只有一处**:`MenuBarScrollingLabel.restartAnimation()` 的静止分支。原来那句是
  `contentLayer.position = CGPoint(x: 0, ...)` —— **x=0 就是既有的左对齐**,所以 leading
  作默认值、存量用户观感一字不变。现在按 `slack = max(0, -maxOffset)`
  (`maxOffset = textWidth - windowWidth`,装得下时为负)算落点:leading=0、center=slack/2、
  trailing=slack。放不下时 slack 恒为 0,三个选项自动退回 x=0。
- ⚠️ **只动 `contentLayer` 就够了**:染色那两个裁剪层(`baseClipLayer`/`fillClipLayer`)是它
  的**子层**(见 `MenuBarScrollingLabel` 头部「图层结构」),跟着一起平移 —— 填色几何一个数
  都不用改。这是这次改动之所以只有六行的原因。
- **live 生效**靠两条:真菜单栏加了 `settings.$menuBarLyricsAlignment` 的订阅(→`refresh()`;
  ⚠️ **不能用 `refreshColors()`** —— 它只重排位图+重放填色、**不碰 position**,而对齐改的
  正是 position);设置页预览靠 `@ObservedObject` 的 body 重算走到同一个 `present()`。
  `Plan` 里带上了 `alignment`,所以"只改了对齐"也能过 `next != plan` 那道门。
- **控件刻意不用系统 `.pickerStyle(.segmented)`**,手搭 `MenuBarAlignmentSegmentedControl`
  ——照 `OverlayAlignmentSegmentedControl` 搬,那边为这件事修了三轮:`NSSegmentedControl` 按
  **当前选中段的文字**重新量宽度,于是"选了哪个选项、控件整体宽度就跟着变",而给子 `Text`
  或给 Picker 整体加 `.frame(minWidth:)` 都不管用(完整记录见第 04 章)。这三个标签正好不等宽
  (左对齐/居中/右对齐 = 3/2/3 字,英文差得更多),是那个 bug 的正射场景。`.fixedSize()`
  同样是必需的、不是保险(理由见那边 2026-08-31 的离屏结论:不加会在行里还剩空白时把英文
  标签截成 "Left-Ali…")。
- **标题用「对齐方式」不是「对齐模式」**:悬浮歌词那个同名设置就叫「对齐方式」,而用户当天
  上一条要求正是"和软件其他地方对齐"。三个选项名(`左对齐`/`居中`/`右对齐`,英文
  `Left-Aligned`/`Center`/`Right-Aligned`)直接复用那边已有的词条。

⚠️ **「自适应（Beta）」的 Beta 字样 2026-09-01 按用户要求去掉**。改的时候差点漏:
**有两处**用这个标签 —— 设置页(`MenuBarWidthModeRow`)和菜单栏左键面板的快捷设置
(`MenuBarPanelQuickSettings`,那里还留着一条注释说"两处必须同进同出,否则就成了一条带警告、
一条不带的两个入口")。只改设置页会让面板那处指向一个已删的词条 —— 是 selftest 的「源码用了
但 catalog 里没有的键」守卫逮出来的。宽度模式 help 里那句「自适应(不建议)」**当天晚些也去掉了** —— 用户:"这里只需要说明最终的效果是什么就好,不需要说不建议"。整行改成只描述两种模式各自的最终效果:

> 只影响装得下的句子。
> 固定：短句也占满设定宽度，右边留白，菜单栏上的位置不会变。
> 自适应：短句按自己的宽度占位，省下多余空间；菜单栏这一项的宽度随每句变化，旁边的图标位置也跟着挪。

删掉的是三样:括号里的「不建议」、整段成因(每换一句都要重建菜单栏项、系统只在项出生那一刻给邻居排位、重建太密时邻居图标会错位闪动、左键面板可能被挤掉)、以及结尾的「想稳定就用固定」。留下的那半句「宽度随每句变化、旁边图标跟着挪」是**可见结果**,跟「固定」那条的「位置不会变」正好对称 —— 两种模式各说自己最终长什么样,不做比较也不给结论。⚠️ 那段被删的成因是实测结论,**搬进了 `MenuBarWidthModeRow` 的代码注释**(连同「UI 上只保留可见结果、成因和『别用』属于判断」这条界线),别当废话丢掉、也别把「不建议」写回去。

### 卡拉OK染色(2026-08-22,用户点名"像酷狗菜单栏歌词";界面标题 2026-09-01 从「逐字染色」改过来)

⚠️ **界面标题的用词 2026-09-01 统过一遍**(用户:"改更专业一点、和软件其他地方对齐")。本仓
面向用户的术语一直是**卡拉OK**(「歌词 › 效果」那张卡就叫「卡拉OK效果」,候选打分说明里是
「带逐字（卡拉OK）时间轴」),而**英文侧本来就是** `Karaoke fill`/`Fill color` —— 漂的只有
这三处中文标题:

| 原标题 | 现标题 | 理由 |
|---|---|---|
| 逐字染色 | **卡拉OK染色** | 跟「卡拉OK效果」对齐。⚠️ 两者是**两层**不是重名:那个是全局 `preferWordLevelKaraoke`(要不要用逐字数据),这个是 `menuBarLyricsKaraoke`(菜单栏要不要跟着染);名字相近正是要让这层关系看得出来 |
| 文字颜色 | 染色**关**时仍是「文字颜色」/ 开时改叫**「未唱到的颜色」** | 这一行管的范围真的会变:关着时它就是整条歌词的颜色(叫「未唱到的」莫名其妙——什么都不会被"唱到"),开着时只管未唱到那半截。⚠️ 关态那个「文字颜色」**跟悬浮歌词那行共用同一个 L10n 键**(`OverlayStyleSettingsRows`),改它的值会连带改掉悬浮歌词那一行 —— 所以菜单栏开态用的是新键,不是改旧键 |
| 染色颜色 | **已唱到的颜色** | 原词组自己打结("染色"已含"色"),且没说清染的是哪一半;它的 help 一直写着"已唱到部分的颜色",标题直接用那句话,跟「未唱到的颜色」成对 |

英文一并对齐成 macOS 设置项惯用的 Title Case:`Karaoke Tint` / `Unsung Color` / `Sung Color`
(原来 `Karaoke fill`/`Fill color` 是句式,跟同屏的 `Text Color`/`Follow System` 不统一)。


- **开关**:设置 › 歌词显示 › 菜单栏 ›「卡拉OK染色」,默认开;只对带逐字时间轴(YRC)的歌词生效,LRC 整行歌词维持纯色(没有可信的字级进度就不假装有)。
- **驱动方式**:跟滚动同一哲学 —— 基础色/强调色两张同字形长图做**互补裁剪**(fillClip 露出已唱区 [0,边界]、baseClip 露出未唱区 [边界,句尾],KTV 式硬切边界);整行填色进程按逐字时间轴一次性编成 **三条共享 beginTime/keyTimes 的 CAKeyframeAnimation**(fillClip 宽 + baseClip 的 position.x/bounds;数学在 `MenuBarMarquee.karaokeFillPath` / `karaokeFillKeyframes`,纯函数,selftest 覆盖),装好后主线程一帧都不碰。两个裁剪层挂在滚动的 contentLayer 里,滚动时天然跟文字焊在一起。词边界像素必须按**前缀整段测宽**(`MenuBarMarqueeRenderer.wordEndXs`),各词单测再累加会被词界 kerning 带漂。⚠️ **不能做成"强调色叠在基础色上面"**(第一版,当天被用户截图打回"染色后有白边"):两张图字形抗锯齿覆盖率相同,叠着画时边缘半透明像素让底下的基础色透出来,深色菜单栏上蓝字四周镶一圈白晕;互补裁剪让每个区域的字形只与背景合成一次。离线 harness 有「已染区白色像素=0」专项断言。
- **已唱到的颜色**:系统 controlAccentColor;**深色菜单栏上向白提亮四成**(`karaokeFillColor`)——强调色按浅底设计,直接压深底上亮度低于旁边的白色基础字,染过的反而更难读(同批用户实测"看不清文字");浅色菜单栏原样。
- **时钟**:位置公式与歌词窗口逐字填色同一条(anchor 外推 ?? 暂停位置,+ 时间轴校准)。对表走独立通道(`syncKaraokeClock`,订阅 $anchor/$pausedPositionMs/$currentLyricsOffsetMs),**不触发槽位 refresh**;标签内部有 **250ms 漂移门** —— 锚点每 ~2s 的例行重发被无声吸收、不打断动画,seek 必然超门重锚,时间轴偏移微调(默认步长 200ms 在门下)走 force 立即生效。暂停静置在当刻边界,恢复从真实位置续染。
- **自适应宽度模式**下装得下的句子原走 `button.title`(AppKit 自绘,没有图层可叠色)——染色时改走图层渲染,槽宽公式不变(文字宽+18),footprint 逐像素一致。宽度 ≤0 的截断退化路径不染。
- **反白期间**(菜单/面板开着)填色整个隐掉:基础字已换成选中色,强调色叠在选中背景上要么撞色要么看不清,关掉恢复。
- 设置页预览(MenuBarPreviewBar,2026-08-22 补齐):正在播放且当前句有逐字(YRC)数据时,预览走跟本体完全一样的填色图层与对表公式(`MenuBarScrollingLabel.Representable` 新增 `fillPath`/`karaokePositionMs`/`karaokeRate`/`karaokePlaying`,由预览自己订阅 `$anchor`/`$pausedPositionMs`/`$currentLyricsOffsetMs`/`$isPlayingNow` 重算,搬的是 `MenuBarStatusItem.syncKaraokeClock` 那套公式,不是另一份判定);没在播放时演的示例句刻意不染——编不出真实时间轴,染了就是假动画(全仓预览共用的原则,记在 `SectionPreviewBars.swift` 文件头「不为示例句编造进度」那一段)。
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
| 歌词显示 › 菜单栏 | 对齐方式(左对齐/居中/右对齐,**仅固定宽度模式下显示**) | `np:menuBarLyricsAlignment` | leading | 装得下的短句在那一格里靠哪边;见「对齐方式」一节 |
| 歌词显示 › 菜单栏 | 卡拉OK染色(开关) | `np:menuBarLyricsKaraoke` | 开 | 见「卡拉OK染色」一节;只对带逐字时间轴的歌生效 |
| 歌词显示 › 菜单栏 | 文字颜色(色轮+「跟随系统」) | `np:menuBarLyricsTextColorHex` | 空=跟随系统 | 未唱部分/整行的文字色。空串=labelColor 自适应+反白;自定义色原样用(反白态仍换选中色);自适应 button.title 退化路走 attributedTitle |
| 歌词显示 › 菜单栏 | 已唱到的颜色(色轮+「跟随系统」,仅卡拉OK染色开着时显示) | `np:menuBarLyricsFillColorHex` | 空=跟随系统 | 已唱部分的颜色。空串=系统强调色+深色菜单栏提亮四成;自定义色**原样用、不再自动提亮** |
| 通用 › 菜单栏与 Dock | 菜单栏图标(12 款网格) | `np:menuBarIconStyle` | classic | 未显示歌词时那枚图标的样式,点选立即生效 |
| 通用 › 菜单栏与 Dock | 随播放律动(开关) | `np:menuBarIconAnimates` | 开 | 播放时图标动不动;暂停永远静止 |
| 快捷键 › 调整步长 | 调整步长(50~2000ms) | `np:lyricsOffsetStepMs` | 200ms | 菜单「提前/延后」和两个快捷键每按一次调多少,菜单项文案跟着变 |
| 歌词 › 时间轴偏移 | 播放器下拉框 + Stepper ±5s,步长固定 0.05s | (LyricsOffsetStore 全局 key / 按播放器字典) | 0 | 下拉「全部播放器」= 对所有歌生效的设备侧基准;选具体播放器 = 那个播放器**取代**共用那档的值(二选一,不叠加)。基准再与单曲微调相加;两者都不显示在菜单标题里 |

另:`np:menuBarLyricsMaxChars` 是 2026-08-15 之前「按字数」时代的旧 key,已无读取方,仅为兼容老配置保留。

2026-09-01 编辑台改造顺带加的「重置 ▾」(工具栏,`MenuBarStyleDefaults.restoreDefaults()`):
恢复宽度模式/卡拉OK染色/文字颜色/已唱到的颜色四项默认值,**不含**最大宽度(结构性尺寸设置)和
「菜单栏歌词」总开关——取舍跟悬浮歌词/灵动岛两个「重置」一致。默认值命名常量
`AppSettings.defaultMenuBarLyricsWidthMode` 等四个,`init()` 的 fallback 和这颗按钮读
同一份,不各自硬编码。

### 图标的初始位置(2026-09-01,用户要求"挪到贴近系统图标的位置")

调研结论:macOS **没有公开 API 能强制第三方状态栏图标的位置**。苹果 HIG 原文明确写着
"不要指望能预测/固定第三方菜单栏图标的位置,这个决定权在用户手里,不在 App";历史上
唯一的私有优先级接口(`_statusItemWithLength:withPriority:`)在 10.6.3(2010)就已失效;
Bartender/Ice 这类工具做的是"接管、管理别人的图标"(靠截屏+私有 CGS 接口伪造整条菜单栏),
跟单个 App 想调整自己的位置是两码事,且这条路子被证实随时可能被系统架构调整整体打断
(社区反馈某 macOS 测试版一次性弄坏了 Bartender/Ice/Thaw/Barbee 等多款工具)。

按这个结论实现了两个手段,没有任何一个能"保证"生效:

1. **状态栏项的创建时机尽量提前**(`AppDelegate.applicationDidFinishLaunching`):从原来排在
   collector 对账、悬浮歌词/灵动岛窗口创建、通知中心注册等一堆重活之后,挪到了
   `PlaybackCoordinator.shared.start()` 唯一真正的前置依赖(几个 Core 单例的设置快照灌好)
   之后就立刻创建。经验规律:如果这个 App 恰好跟别的菜单栏 App 同一时刻启动(比如都是
   登录项),谁先把 `NSStatusItem` 建出来、谁就更可能落在更贴近系统图标的位置——但对已经
   在运行的其他菜单栏 App **完全无效**。
2. **首次启动的一次性拖拽引导提示**(`MenuBarPositionHintController`,
   `MenuBar/MenuBarPositionHint.swift`):`MenuBarStatusItem.start()` 里,状态栏按钮首次
   建出来 1.5s 后,如果 `AppSettings.hasShownMenuBarPositionHint` 还没置真,就弹一个锚在
   按钮上的 `NSPopover`(transient,8s 自动收起或点「知道了」手动收起),提示"按住 ⌘
   拖拽这个图标,可以把它移动到菜单栏里你喜欢的位置"——这是唯一真正可靠、且苹果官方
   认可的手段。标记在**决定要展示**的那一刻就置真(不等用户点掉),往后永不再弹。
   `hasShownMenuBarPositionHint` 记的是"这台机器"的状态,已经加进
   `ConfigPortability.machineLocalDefaultsKeys` 排除表,不会跟着配置导出/导入搬到新机器——
   否则新机器上这个图标的位置本来就要重新落定,却再也看不到这条最该出现的提示
   (跟同类的 `hasShownOverlayDragHint` 一个道理)。

## 与其它功能的交互

- **数据来源**:当前句文本、播放态、句停留时长、曲目微调值全部来自 `PlaybackCoordinator`(它是 `LocalPlaybackSource` 的转发层);配速依赖的 `currentLineDwellSeconds` 用相邻两句时间戳之差,所以歌词时间轴校准不影响它。
- **歌词时间轴三处入口共享**:菜单「提前/延后」、全局快捷键(`GlobalHotkeys`,快捷键那条路会在**灵动岛**闪一条「歌词偏移 +0.50s」提示,只开悬浮歌词的人无反馈)、「歌词管理」窗口的偏移输入框,底层都是 `LyricsOffsetStore`;步长与菜单文案共用 `lyricsOffsetStepMs`。设置页那一行时间轴偏移是叠加的另**两**层(「全部播放器」= 全局基准,选具体播放器 = 按播放器那层)。
- **快速开关联动**:悬浮歌词/灵动岛的开关经各自 WindowController 的 `setVisible`(与设置页、全局快捷键同一入口);「锁定位置」= 持久化 `lockPosition` + `setLocked` 两步,与快捷键处逻辑一致;「开机启动」直接翻 `launchAtLoginEnabled`。
- **预览里那圈虚线边界**(`slotEdgeOutline`,2026-09-01 用户要求"跟悬浮歌词一样把清晰的边界用虚线画出来"):套在 `lyricsSlot` 上,所以**不用自己算宽度** —— 那一格的 frame 本来就恒等于「最大宽度」(`.fixed`)或文字自然宽度(`.text`)。顺带把两种宽度模式的差别也画出来了:固定宽度时虚线框右边空出一块,自适应时贴着文字收紧。
  - 配色照 `OverlayEditorStage.windowEdgeOutline` 那条老规矩:**固定白色 + 黑色投影,不跟深浅色模式走** —— 这一格压在 `DesktopWallpaperSample` 那张真实壁纸上(再压一层 `.ultraThinMaterial`),底色不受 App 控制,语义色在浅壁纸上会读不出来。
  - 透明度取 **0.6** 而不是悬浮歌词那条的 0.5:那一圈常驻在**用户真实桌面**上、画满会读成一个"假窗口边框"(真窗口并没有边),所以刻意克制;这一圈在**预览**里,而且是它接替 caption 去回答"这一格有多宽",读不清就等于什么都没说。
  - 没做「拖动宽度时提亮到 0.95」的联动:那需要把滑杆的 `onEditingChanged` 一路传进 `MenuBarPreviewBar`,而滑杆住在 `MenuBarEditorStage`。属于加法。
- **caption 砍掉了宽度和模式**(同日):原来是「预览 · 固定宽度 150pt」/「预览 · 自适应，最宽 150pt」，现在只剩「预览」/「预览 · 本句会横向滚动」。同一件事那时候被说了**三遍** —— 虚线边界直接把那一格画出来了(含模式)、编辑台「最大宽度」滑杆右侧有数值、这行字是第三遍。**留下滚动那一句**是因为它是这行字唯一说得出、而画面说不出的事:那一格的宽度看得见,"这句放不下、会横向滚动"看不见。
- **宽度调整条浮在预览框里**(`MenuBarEditorStage.stageWidthBar` + `MenuBarPreviewBar.reservesWidthLane`,2026-09-01 用户三次点名"和之前两个页面一样加到这个预览框里面去"):前两版都不是他要的 —— 第一版摆在预览下面平铺一行、第二版仍是 VStack 里的兄弟节点,而那两版用的都是 `MenuBarWidthRow`(`SettingsRow` 外壳),在舞台那块近白的 `controlBackgroundColor` 上跟"页面上一条独立的设置行"长得几乎一样,所以看着像没动。
  - 现在照 `OverlayEditorStage` 的做法:预览条自己让出一条通道(`reservesWidthLane`,28pt;那边是 44pt,但这条预览总高只有 69pt,留 44 会把菜单栏条挤得很窄),胶囊浮在通道里。样式逐项抄 `NotchEditorStage.widthBar`(黑底 0.7 + 白描边 0.18 + 投影、白色小号 Slider、等宽读数)。
  - ⚠️ 预留通道时 caption 要加一个 `Spacer` 顶在菜单栏条正下方,否则 VStack 会把它均摊到通道中间、正好跟胶囊叠上。
  - ⚠️ **Slider 不传 `step:`** —— macOS 的 Slider 一有 step 就画刻度线,80…600/step 10 是 52 个刻度、密到连成一条实线,看着像轨道下面平白多一条白杠(悬浮歌词那根为此被用户报过一次)。量化在 `set` 里自己 round。
  - 抽屉里那份 `MenuBarWidthRow` 保留不动(跟灵动岛「同一份滑杆逻辑、不同外壳宿主」同一个模式)。
- **设置页预览**(`MenuBarPreviewBar`):不是仿品,直接复用菜单栏本体——同一个 `presentation` 判定、同一个 `MenuBarScrollingLabel`(经 `Representable` 包装)、同一套菜单栏字体;正在播放时预览演真实当前句和真实配速,没播放时演示例句(dwell 给 nil 走固定速度)。逐字染色同理复用本体的填色图层与对表公式(见「卡拉OK染色」一节),不为示例句编假时间轴。垫底用真实桌面壁纸 + `.ultraThinMaterial` 合成菜单栏质感。
- **窗口打开链路**:菜单的「设置/歌词管理/歌词窗口/引导」四个动作依赖 `MenuBarSceneActions.install()` 建的锚点窗口先注册好 `AppActions` 闭包(AppDelegate 里紧跟 `start()` 之后);首次启动的引导向导也从那个锚点延迟 0.5s 拉起。
- **字体跟随系统**:歌词用 `NSFont.menuBarFont(ofSize: 0)`,系统改菜单栏字号会跟着变,静态文字路径与图层路径同一字体,切换时字号不跳。

## 数据与文件

- **UserDefaults(standard)**:上表 7 个 key,全部 `np:` 前缀,经 `AppSettings` 读写;单曲微调与全局基准由 `LyricsOffsetStore` 存 UserDefaults(JSON 字符串 + 独立全局 key,`defaults read` 可读)。
- **磁盘文件**:无——菜单栏功能本身不落盘;所有位图(歌词长图、染色图标)都是进程内现画现用。老的 `Resources/MenuBarIconTemplate.png` 留作历史资料,不再参与渲染。
- **进程边界**:全部在 lyrimuse 主 App 进程内,不涉及 collector/worker。

## 代码锚点

| 主题 | 文件 + 符号 |
|---|---|
| 预览里的虚线边界 / caption | `lyrimuse/Sources/lyrimuse/UI/SectionPreviewBars.swift` · `MenuBarPreviewBar`(`slotEdgeOutline` / `previewCaption` / `reservesWidthLane`) |
| 编辑台工具栏 / 浮在通道里的宽度胶囊 / 对齐 | `lyrimuse/Sources/lyrimuse/UI/MenuBarEditorStage.swift` · `MenuBarEditorStage`(`toolbar` / `stageWidthBar`) · `MenuBarWidthModeRow` · `MenuBarAlignmentRow` · `MenuBarAlignmentSegmentedControl` |
| 对齐落地(静止时的横向落点) | `lyrimuse/Sources/lyrimuse/MenuBar/MenuBarScrollingLabel.swift` · `restartAnimation()` 的静止分支(`slack` / `alignedX`);`Plan.alignment` 让"只改对齐"也能过 `next != plan` |
| 状态栏总控、三态判定、透明占位图 | `lyrimuse/Sources/lyrimuse/MenuBar/MenuBarStatusItem.swift` · `MenuBarStatusItem`(`refresh` / `showIcon` / `showStaticText` / `showFixedWidth` / `spacerImage`) |
| 装得下/要滚的唯一判定、长图排版、按宽截断 | `lyrimuse/Sources/lyrimuse/MenuBar/MenuBarMarqueeRenderer.swift` · `MenuBarMarqueeRenderer`(`presentation` / `Presentation` / `prepare` / `truncate`) |
| 滚动图层、反白换色不打断动画 | `lyrimuse/Sources/lyrimuse/MenuBar/MenuBarScrollingLabel.swift` · `MenuBarScrollingLabel`(`present` / `rebuildImage` / `restartAnimation` / `Representable`) |
| 关键帧、配速算法、速度上下限常量 | `lyrimuse/Sources/LyrimuseCore/Lyrics/MenuBarMarquee.swift` · `MenuBarMarquee`(`scrollKeyframes` / `pacing`(含 `leadInSeconds`) / `ScrollPacing`) |
| 单行展示面显示哪一句、显示窗口、开唱前的提前量 | `lyrimuse/Sources/LyrimuseCore/Lyrics/CompactLyricLead.swift` · `CompactLyricLead`(`resolve` / `appearMs` / `displayDurationMs` / `leadInMs`) |
| 12 款图标枚举、静态帧绘制、缓存 | `lyrimuse/Sources/lyrimuse/MenuBar/MenuBarIconStyle.swift` · `MenuBarIconStyle`(`cachedImage` / `makeImage` / `classicArtwork` 等各款 artwork) |
| 图标活体动画(CA 驱动、裸层、染色) | `lyrimuse/Sources/lyrimuse/MenuBar/MenuBarLiveIconView.swift` · `MenuBarLiveIconView`(`present` / `build*` 各款 / `applyColor` / `tintedContents`) |
| 下拉菜单结构与全部动作 | `lyrimuse/Sources/lyrimuse/MenuBar/MenuBarStatusMenu.swift` · `MenuBarStatusMenu`(`rebuild` / `offsetMenuTitle` / 各 `@objc` action) |
| Dock 右键菜单四个跳转项 | `lyrimuse/Sources/lyrimuse/MenuBar/DockMenu.swift` · `DockMenuController`(`makeMenu` / 各 `@objc` action);挂载点 `AppDelegate.applicationDockMenu(_:)` |
| 环境 action 锚点窗口、设置窗打开的特殊路径 | `lyrimuse/Sources/lyrimuse/MenuBar/MenuBarSceneActions.swift` · `MenuBarSceneActions`(`install` / `presentSettings`)、`SceneActionRegistrar` |
| 句停留时长、偏移转发 | `lyrimuse/Sources/lyrimuse/PlaybackCoordinator.swift` · `currentLineDwellSeconds` / `nudgeLyricsOffset` / `trackLyricsOffsetMs` |
| 偏移的真正执行与叠加 | `lyrimuse/Sources/LyrimuseCore/Local/LocalPlaybackSource.swift` · `nudgeLyricsOffset` / `resetLyricsOffset` / `applyOffsets` |
| 菜单栏相关设置属性与默认值 | `lyrimuse/Sources/lyrimuse/Settings/AppSettings.swift` · `showLyricsInMenuBar` / `menuBarLyricsWidth` / `menuBarLyricsWidthMode` / `menuBarIconStyle` / `menuBarIconAnimates` / `MenuBarLyricsWidthMode` |
| 设置页编辑台(工具栏/宽度条/浮层/抽屉) | `lyrimuse/Sources/lyrimuse/UI/MenuBarEditorStage.swift` · `MenuBarEditorStage`、`MenuBarWidthModePopover`、`MenuBarColorPopover`、`MenuBarAllSettingsDrawer`、`MenuBarStyleDefaults` |
| 首次启动的拖拽引导提示 | `lyrimuse/Sources/lyrimuse/MenuBar/MenuBarPositionHint.swift` · `MenuBarPositionHintController`(`show`);调用点 `MenuBarStatusItem.start()` |
| 状态栏项创建时机、机器专属配置排除表 | `lyrimuse/Sources/lyrimuse/AppDelegate.swift` · `applicationDidFinishLaunching`(`MenuBarStatusItem.shared.start()` 调用点);`lyrimuse/Sources/lyrimuse/Settings/ConfigPortability.swift` · `machineLocalDefaultsKeys` |
| 设置页图标网格 | `lyrimuse/Sources/lyrimuse/SettingsView.swift` · `GeneralSettingsTab.menuBarIconChoice` |
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
11. **长间奏的 ♪ 必须是非空文本,不能是空串**(2026-08-23):`refresh()` 里 `text` 为空会落进 `guard ... lyricsActive` 那条,把整个歌词槽 `present(class:"icon")` 收回成小图标 —— 那是一次状态项重建,而长间奏动辄十几秒(实测单次平均 10.1 秒),表现就是菜单栏歌词塌掉、过一会儿又弹回来。所以 `compactShowsPlaceholder` 时给字面的 `♪` 把槽位留住,视觉上也跟灵动岛一致。
12. **菜单栏订阅了两个歌词流,各管一件事**(2026-08-23):`$compactLine` 管**显示哪一句**,`$currentLine` 管**逐字填色路径此刻可不可用** —— 提前量窗口里显示的是下一句但它还没开唱,`karaokeFillPath` 那道 `line.plainText == text` 守卫不给路径(正确:没唱就不该有填色),等真开唱时 `currentLine` 才变,那一下要重画一次把填色挂上。两个事件在短间隙里相差不到一秒,文本相同 → 槽宽相同 → 不触发状态项重建。**2026-08-24 补**:第二个事件也**不再重启滚动动画** —— `fillPath` 由 nil 变非 nil 不算滚动参数变化(见「滚动规则」里那条「开唱那一下不重启滚动」),否则提前量会被白等两遍。
13. **macOS 26 状态栏项重建不能连发,且 AX 验证会说谎**(2026-08-19,错位第六轮定案):两次重建相隔 ~1s(实测 1.1s)会把邻居的**像素**晾在旧位置——AX 账面已更新(全图无重叠、看着完全健康),屏幕像素却是旧布局,歌词压到邻居残影上且**保持不自愈**;单次从容的重建从未观察到排坏。所以:重建节流(<3s 推迟合并)+收缩观察窗(见「三态判定」);验证必须**截图像素**对照 AX,只信 AX 等于白验(前五轮多次"AX 验证通过"后用户仍复现,就是这个原因);重建/推迟落 notice 日志(info 级不落盘,事后取不到现场)。宽度滑杆的订阅换成 `debounce 250ms`(拖动过程每个中间值都排队重建没有意义)。曾按「重建偶发有毒、只能压次数」的中间结论把 fixed 模式改成暂停/广告恒占歌词槽,当天按用户预期退回,由观察窗方案替代。
14. **Dock 右键菜单是单独一个类,不复用 `MenuBarStatusMenu`**(2026-08-26):对照用户给的 Apple Music Dock 菜单截图新增。两者形似(都是手写 `NSMenu` + `@objc` action + `AppActions` 转发)但触发形态不同——下拉菜单靠 `NSMenuDelegate.menuNeedsUpdate` 在打开前重建,而 `applicationDockMenu(_:)` 本身就是 AppKit 每次右键都重新问 delegate 要一份,不需要再接 delegate;菜单项也少得多(没有状态开关/子菜单那一整套),硬凑成一份反而让两边互相牵制,故拆成独立的 `DockMenuController`。**「设置…/歌词管理…/歌词窗口…」三项直接走 `AppActions.shared.open*?()`**(内部已含 `NSApp.activate`,调用处不用再激活一次,跟 `MenuBarStatusMenu` 同名 action 同一个理由);**「Last.fm」不判断是否已连接**,固定走 `requestSettings(.account(.lastfm)) + openSettings?()` 跳设置里的 Last.fm 那一页——没连的话那页本身就有「连接 Last.fm」引导,不需要在 Dock 菜单这一层再分支。图标用 `NSImage(systemSymbolName:)`(三个窗口项)和 `lastfmBadgeImage`(Last.fm 品牌图,跟菜单栏面板底栏、设置页账号卡片同一张 PNG,见 `AccountLinkingTab.swift`)喂给 `NSMenuItem.image`,但**实测这几个图标在 Dock 右键菜单里不显示**(截图核实,`选项`/`显示所有窗口`这几个系统项本来也没有图标)——跟参考的 Apple Music 截图一致(那边「重复播放」「随机播放」等项同样没有前置图标),判定为 Dock 菜单这一层级本身不渲染 `NSMenuItem.image`(main menu bar 同理不显示图标),不是这里的图片资源或加载路径有问题,`image` 赋值原样保留(便于将来 AppKit 行为变化时自动生效,没有坏处)。不实现这个类的话,右键 Dock 图标能看到的只是系统自动附加的那部分(当前开着的窗口列表 + 「选项」子菜单 + 显示所有窗口/隐藏/退出),这几项跟自定义菜单是两回事——AppKit 自动把自定义菜单摆在它们上面,`DockMenuController` 不需要也不应该重复画。
