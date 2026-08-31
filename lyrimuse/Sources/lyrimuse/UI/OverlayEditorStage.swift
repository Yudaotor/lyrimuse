import AppKit
import LyrimuseCore
import SwiftUI

// 「歌词显示 → 悬浮歌词」的**编辑台**:一块接近真实窗口尺寸的大画布,悬浮歌词直接在上面
// 改(2026-08-30 起,这一段设置页重设计的地基)。
//
// 它取代了这一段原本钉在页顶的那条预览(`OverlayPreviewBar`,高度受 SectionPreviewMetrics
// 契约约束、只有 `fontSize * 1.5 + 28` 那么高、不可交互)。钉条要解决的是"滚到半屏还看得见
// 效果",编辑台放进**可滚动的内容区**、尺寸自由、可以直接在上面动手,要解决的是"看得清、
// 够得着"。
// ⚠️ 钉条和它那份简化渲染 `OverlayLyricsCanvas` **已于 2026-08-31 一并删除**:第八步之后
// 编辑台改画真窗口那份 `LyricsOverlayView`,钉条这一段也不再挂(固定头部收不到点击事件),
// 于是它零实例化。下面第一到第八步里凡是提到"钉条"的地方都是**历史叙述**,别当成现状。
// (只有 `OverlayDesktopSurface` / `DesktopWallpaperSample` 从那个文件里留了下来,搬进
//  OverlayDesktopSurface.swift —— 两块编辑台和菜单栏预览都在用。)
//
// 第一步(2026-08-30)落的是:复用同一份渲染 + 左右两个可拖拽的宽度握柄。
// 第二步(2026-08-30)落的是:工具栏(带当前值摘要的「文字…」「配色…」「重置 ▾」)和两个浮层。
// (那一步还在画布上做了两块命中区 —— 点歌词弹文字浮层、点背景弹配色浮层,悬停给虚线框 +
//  标签。第十步按用户要求整个删掉了,见下。)
// 设计稿里的场景预设(「✦ 风格 ▾」)、试穿、快照撤销、行为栏、底部全量抽屉还没有,那是后续步骤。
//
// (第三步 —— 行为栏 + 「全部设置」抽屉 —— 落在 OverlayBehaviorSettingsRows.swift /
//  OverlayAllSettingsDrawer.swift 里,上面那句"行为栏、底部全量抽屉还没有"已经过时;
//  全景见 docs/features/04-desktop-overlay.md 的「编辑台改造」。)
//
// 第四步(2026-08-30,用户反馈原话:「就不应该有什么缩放的概念在这里;只显示实际的大小以及
// 一切;并且这里可以拖动的不应该是外面这个带桌面的大窗口,而是里面的文字对应的悬浮歌词窗口
// 才对吧」)改掉两个概念性错误:
//   ① 编辑台**不再缩放**,一律按 overlayWidth 的真实 pt 画;放不下时居中裁切 + 两端渐隐
//      (为什么不选缩放/横向滚动条,见 isOverflowing 那段注释)。
//   ② 两个宽度握柄从"整块画布的外缘"挪到**悬浮歌词窗口自己的左右边缘**上 —— 贴在画布外缘
//      等于在拖"桌面有多大",拖的对象根本不是那扇窗。
// (当时的原话是"缩放能力没有从 OverlayLyricsCanvas 里删掉,顶部钉条只有 520pt 可用、那边
//  照旧要缩" —— 钉条和那份渲染 2026-08-31 已经整个删掉,这条连同它的对象一起作废。)
//
// 第五步(2026-08-30,用户反馈原话:「我意思是不应该可以拖动的是里面这部分吗外面这个框为什么
// 要去拖动他,最直观的难道不是调整文字部分吗」)把**桌面**和**窗口**在视觉上彻底分开。
// 第四步之后握柄其实已经贴在窗口边上了,可用户仍然把它读成"在拖外面那个框" —— 因为那扇窗
// 当时长这样:一整块贴满桌面壁纸的矩形,宽度恰好等于 overlayWidth,窗外没有任何桌面,窗口
// 自己也没有可见边界(背景透明时画布什么都不画)。于是它只能被读成"一张带图的背景板",
// 歌词才是"里面那部分"。两条改法:
//   ① 桌面壁纸铺满**整个舞台**(desktopSurround),窗口 1:1 居中摆在上面,窄于舞台时两侧
//      自然露出桌面 —— 舞台是一小片桌面,不是一块底板。
//   ② 窗口边界**常驻可见**(windowEdgeOutline),不再只在悬停握柄时才出现。
//
// ⚠️(当时)这两步都只动编辑台这一侧,`OverlayLyricsCanvas` 仍然零改动 —— 它是跟钉条**共用**的
// 渲染核心,"壁纸铺得比内容宽"这种只有编辑台需要的能力不该塞进去(钉条只有 520pt 可用、
// 还要缩放,它的语义得保持干净)。代价写在 desktopSurround 的注释里。
// (⚠️ 2026-08-30 第七步订正:「零改动」到此为止 —— 那一步给共用画布加了一个带默认值的
//  开关 showsDesktopUnderlay,好让编辑台把窗内那份壁纸关掉。钉条的调用点没动、默认值就
//  等于它的现状,见下面第七步那段。)
//
// 第六步(2026-08-30,用户原话:「算了你始终不明白我的意思;既然这样,那么就这样调整,在这个
// 框里加一个调整条,可以控制歌词的宽度;然后外面始终是 1 比 1 的大小,不可以拖动外部的框」)
// **把左右两个拖拽握柄整个删掉**,换成舞台内部、窗口正下方的一条宽度调整条(widthBar)。
// 上面第一/四/五步里凡是提到握柄的描述,行为上都已被这一步取代;留着是为了留住那三轮的
// 踩坑记录。
//
// 为什么放弃拖拽这条路(是三轮都没做对,不是没试):第四步把握柄从画布外缘挪到窗口边上,
// 第五步给窗外铺满桌面 + 给窗口描一圈常驻轮廓,caption 里还专门写了「拖窗口两侧改宽度」——
// 用户仍然没找到它。根子在"预览即编辑器"这套范式最贵的那条代价上:**直接操作的可发现性
// 天生就差**,而这里可抓的东西只有 4pt 宽、贴在一张会跟着变的卡的边缘上,再加提示也只是
// 在给一个看不见的入口写说明书。一根明摆着的滑杆没有这个问题 —— 它长什么样就说明它能干什么。
// ⚠️ 这条结论当时只针对**宽度**这一个入口 —— 点文字/点背景那两块命中区那会儿还留着(它们有
// 悬停虚线框 + 标签,工具栏上还有等价的显式入口兜底)。第十步用户要求把命中区也去掉,于是画布
// 上再没有任何直接操作入口:宽度走调整条,其余一律走工具栏。
//
// 外框(舞台)从此**没有任何拖拽入口**,恒等于 1:1。窗口那圈常驻虚线轮廓(第五步)因此更
// 重要了:握柄没了之后,它是"调整条正在改的是这扇窗的宽度"**唯一**的视觉锚点,别顺手删掉。
//
// ⚠️ 浮层里的设置行**不在这个文件里**,在 OverlayStyleSettingsRows.swift —— 它跟内容区
// 下面那几张卡是**同一份**实现,两个宿主只负责外壳。别在这里就地写一遍行:这个仓库刚为
// "同一个视觉属性有两条渲染路径"付过代价(「对齐方式」在预览条上失效),设置行比渲染更
// 容易漂,而且漏改不会编译报错。
//
// 第八步(2026-08-30,用户原话:「帮我把这个预览窗口的一切行为都和实际的桌面歌词保持一致;
// 包括翻译,换行,罗马音,等等,完全一致」)**编辑台不再画简化版,直接渲染真窗口那份
// LyricsOverlayView**。
//
// 病根:此前编辑台用的 OverlayLyricsCanvas 是一份**刻意简化**的渲染(它自己的注释写着
// "跟 .lineLimit(1) 一样只求看得出配色效果,不追求跟真窗口逐像素一致的换行表现"),只画
// 主歌词一行 + 描边 + 逐字填色 —— 译文、罗马音(整行的和逐词标注的)、下一句预览、
// WrapLayout 自动换行、对唱两侧内缩与声部指示圆点,一样都没有。设置页预览的全部意义就是
// 所见即所得,一份会漂的复刻件比没有预览更糟。
//
// 做法照灵动岛那一段的先例(NotchPreviewBar 直接渲染真的 NotchLyricsView):把
// LyricsOverlayView 按 OverlayChromeSource 泛型化,真窗口拿 LyricsOverlayWindowController
// 当 chrome,编辑台拿下面那个**不建窗**的 OverlayPreviewChrome。⚠️ 不建窗是硬要求,不是
// 优化:LyricsOverlayWindowController.shared 是 static let,光是读一下属性就会执行 init()
// 建窗并 orderFront —— 悬浮歌词关着的用户一打开设置页就会凭空多出一扇窗。
//
// 跟着一起改的三处几何:
//   ① 卡高不再按字号估(原来是 max(120, OverlayPreviewBar.rawCardHeight),那条公式既不含
//      常驻的播放控制排槽位、也不含译文/罗马音/下一句/换行),改成**真视图自己报**的内容
//      高度(onContentHeightChange),跟真窗口 updateHeight 同一条 max(120, ceil(h)) 口径。
//   ② 舞台加高到 stageHeight,并在下半部**预留**一条 widthBarLaneHeight 高的通道给宽度
//      调整条 —— 卡片长高时不会压到那根滑杆。
//   ③ 文字命中带不再靠"字号 × 1.5 的横带"估,改用真视图报上来的**文字实际矩形**
//      (onLyricsTextRectChange),顺手还掉了"取不到文字宽度所以只能用横带"那条技术债。
//      (这一条随第十步删命中区一起作废 —— 编辑台不再消费那个回调;⚠️ 真视图**仍在上报**,
//       真窗口的「划过让开」还靠它当判据。)
//
// (当时这里写着"OverlayLyricsCanvas 一个字都没动、也不许删:顶部钉条还在用它"。那条约束
//  2026-08-31 随钉条一起解除 —— 钉条零实例化,两个文件都删了。)
//
// 第七步(2026-08-30,用户原话:「还有一点要调整就是**背景永远不要变**,拖动宽度框的时候
// **只变可显示歌词窗口的宽度**,背景不应该变」)**整块舞台只留一张壁纸**,窗口相当于在这
// 张壁纸上开了个洞。
//
// 病根是第五步留下的:舞台上当时有**两张**壁纸 —— 窗内那张来自共用画布
// (OverlayLyricsCanvas 自带的 desktopUnderlay,按**窗口宽度**做 scaledToFill),窗外那张
// 按**舞台宽度**裁一次(desktopSurround)。于是窗口一变宽,窗内那张的缩放比就跟着变、壁纸
// 内容跟着呼吸,而窗外那张纹丝不动 —— 用户看到的就是「改宽度把背景也改了」。
//
// 改法:壁纸只按**舞台宽度**画一张、铺满整个舞台,完全不依赖 overlayWidth,拖调整条时它一个
// 像素都不动;窗口那块把自带的壁纸(以及跟它同套的 backdrop 自适应垫底色)关掉
// (canvas 里传 showsDesktopUnderlay: false),让底下那张透上来。窗口只画属于它自己的东西:
// 背景色圆角块、歌词文字/描边/逐字填色、常驻虚线轮廓。
//
// **窗外那圈高斯虚化随之删掉**(连同专门烘位图的 OverlayStageDesktop):它当初存在的唯一
// 理由是藏两张壁纸之间那道对不上的接缝(来龙去脉留在 desktopSurround 的注释里)——只剩一张
// 图,接缝不存在了,再虚化就只剩副作用:把用户的桌面糊成一团,跟「看到的就是它在桌面上的
// 实际样子」直接打架。窗口边界改由背景色圆角块(背景可见时)和那圈常驻虚线轮廓(背景透明时)
// 来分,这两样本来就是干这个的。
// 第九步(2026-08-30,用户原话:「现在翻译这些看不到是因为高度不够吗,帮我高度也正常展示
// 出来」)两件事:
//   ① **卡片那一格的高度改由实测定,推导方向倒过来**。第八步是先拍 288 的舞台、再减出卡片
//      那一格(只剩 244),而真悬浮窗当时是 450×269 —— 比这一格还高 25pt,卡底连译文/下一句
//      一起被 clipShape 裁掉。现在 maxCardHeight 是几何的源头(288,实测值,见它的注释),
//      stageHeight 由它加上调整条通道推出来。舞台高度**仍然与 overlayWidth 无关** —— 实测
//      坐实:同一份内容、同一个换行行数下,内容高度在 420/450/640/1000 四档窗宽下一模一样,
//      宽度只决定"换不换行"。
//   ② **修掉"预览里凭空多出一排播放控制按钮"**。它一直是可见的,而代码上完全看不出来
//      (下面那句"isHoveringForControls 恒 false → 播放控制排不显示"当时只是**意图**,没有
//      真的成立)。根因不在这个文件:`SettingsPage` 把整页内容包在 `GlassEffectContainer`
//      里,而容器会把内部所有带 `.glassEffect` 的子树收拢进自己那趟玻璃渲染,容器与玻璃
//      之间的 `.opacity(0)` 在那趟渲染里不生效 —— 连玻璃托着的图标一起原样画出来。修法在
//      `LyricsOverlayView.overlayCapsuleBackground(visible:)`(玻璃跟着可见性一起关),
//      复现与证据见 docs/features/04-desktop-overlay.md「编辑台改造」第九步。
//
// 第十步(2026-08-30,用户原话:「点背景和点文字的交互去掉;……这些都去掉」)**画布上的两块
// 命中区整个删掉**,连同它们的悬停虚线框、提示标签、hover 状态与手型光标 push/pop。两个浮层
// 从此只有工具栏上那两颗按钮一个入口 —— 它们本来就是显式入口,命中区只是叠在上面的快捷方式。
// 同一轮还删掉了行为栏那颗「预演」按钮和它那条淡入淡出的状态机(isFadePreviewActive /
// fadePreviewOpacity / fadePreviewRampSecs / fadePreviewHoldSecs)。
//
// ⚠️ 删掉的只是编辑台这一侧的**消费方**:真视图照旧上报 onLyricsTextRectChange(真窗口的
// 「划过让开」拿它当命中判据),这个文件只是不再接那个回调了 —— 别顺手把上报那头也删了。
// ⚠️ 锁标(lockBadge)**保留**:行为栏里介绍它的那句小字按用户要求删了,但它仍然是「锁定位置」
// 在编辑台上唯一的真实反馈,删掉解释不等于删掉被解释的东西。
// 被删掉的两块命中区留下的踩坑记录(重叠区域的 hover 派生、光标计数、提示层不接事件)已迁进
// docs/features/04-desktop-overlay.md「编辑台改造」第十步,别随代码一起消失。

/// 编辑台渲染真 `LyricsOverlayView` 时用的 chrome:凑齐它要的那四个状态,但**不建窗口、
/// 不碰 `LyricsOverlayWindowController.shared`**。
///
/// ⚠️ 这个类存在的唯一理由就是最后那半句 —— `.shared` 是 `static let`,哪怕只是拿来读一个
/// 属性都会执行 init() 建出窗口并 orderFront:悬浮歌词关着的用户一打开设置页,桌面上就会
/// 凭空多出一扇(不可见但已经装好全局鼠标监听器和三个观察者的)窗。灵动岛那边的
/// `NotchPreviewChrome` 记的是同一条坑,这是它的悬浮歌词版。
///
/// 四个状态**恒为 false**,也就是"一扇静止的、没人把指针放上去的窗":
///   - `isHoveringForControls` 恒 false → 播放控制排不显示。⚠️ 光有这个**不够**:2026-08-30
///     第九步之前那排按钮在设置页里照样整排画了出来 —— 胶囊那层液态玻璃会被 `SettingsPage`
///     的 `GlassEffectContainer` 收走,连带图标一起穿过 `.opacity(0)`。真正藏住它的是
///     `overlayCapsuleBackground(visible:)`,别把那个参数当装饰删掉。这条恒 false 是刻意的:
///     那排按钮在真窗口里
///     的点击由控制器按上报矩形自己分发(窗口常年 ignoresMouseEvents,视图里压根没有
///     Button),搬进设置页只画得出来、点不动 —— 画一排点不动的按钮比不画更误导。槽位本来
///     就是常驻的(见 LyricsOverlayView.body 顶部),所以画不画都不影响卡片高度和歌词位置。
///   - `isHoveringLyrics` 恒 false → 编辑台里**不许有任何东西**驱动它。这不是"反正没人接",
///     是踩过的坑:真视图对它的反应是整卡淡到 15%(「指针划过时让开」),编辑台上凡是把指针
///     悬停接进来的做法,都会变成"想点它、它就躲"。当年接它的候选(画布命中区、行为栏那颗
///     「预演」按钮)第十步已经一起删了,更没有理由再接回来;完整记录见
///     docs/features/04-desktop-overlay.md「编辑台改造」第十步。
///   - `isDragArmed` / `showDragHint` 恒 false → 长按拖动和那条一次性手势提示都只有真窗口
///     才有,编辑台里没有对应的手势可武装。
@MainActor
final class OverlayPreviewChrome: ObservableObject, OverlayChromeSource {
    let isHoveringForControls = false
    let isHoveringLyrics = false
    let isDragArmed = false
    let showDragHint = false
    /// 恒 nil,理由同上一条:编辑台里没有能触发它的全局快捷键,预览也不该有副作用。
    let transientHint: String? = nil

    /// 真窗口借这一下重读「喜欢」(要起 osascript 子进程)。预览里**故意空实现** —— 同
    /// `NotchPreviewChrome.setExpanded`,理由是同一条:预览不该产生任何副作用。
    /// (实际上 `isHoveringForControls` 恒 false,这个回调根本不会被调到;空实现是把这条
    /// 约束写进代码,而不是靠"反正调不到"。)
    func controlsDidBecomeVisible() {}
}

@MainActor
struct OverlayEditorStage: View {
    /// ⚠️ 显式写 init 而不是靠合成的逐成员构造器:下面 `settings` 是 `private` 存储属性,
    /// 合成出来的逐成员构造器会跟着降成 private,SettingsView 那边就构造不出来了
    /// (灵动岛编辑台 NotchEditorStage 里那条 init 注释是同一件事。)
    ///
    /// (第十步之前它还带一个 `isFadePreviewActive` 入参,由宿主的「预演」按钮驱动。按钮和
    ///  那条状态机一起删了,见文件头第十步。)
    init() {}

    @ObservedObject private var settings = AppSettings.shared

    /// 渲染真 `LyricsOverlayView` 用的 chrome —— 不建窗口,见 OverlayPreviewChrome。
    ///
    /// (2026-08-30 第八步之前,这里是三条 `PlaybackCoordinator` 的窄订阅
    /// `line`/`accent`/`isPlayingNow`,喂给简化画布。真视图自带 `OverlayPlayback` 那份窄
    /// 订阅代理、自己去取当前行/封面主色/播放状态,这三条跟着一起删了 —— 留着就是同一份
    /// 数据被订阅两次。)
    @StateObject private var chrome = OverlayPreviewChrome()

    /// 真视图报上来的"这次渲染需要多高"(onContentHeightChange)。
    ///
    /// ⚠️ 这是卡高**唯一**的来源,别再退回按字号估的公式:译文/罗马音/下一句三行、
    /// WrapLayout 换行出来的第二行、常驻的播放控制排槽位,任何一样都会让估算值偏低,
    /// 而偏低的直接后果是卡片底部被裁掉一截。
    @State private var overlayContentHeight: CGFloat = 0

    /// 当前开着哪个浮层(nil = 都没开)。
    ///
    /// 用一个可空枚举而不是两个 Bool,是为了让"同时只能开一个"成为**类型上**的事实:
    /// 一个浮层还开着的时候点开另一个,SwiftUI 会把两个 NSPopover 都摆出来,它们互相
    /// 遮挡、而且各自的 transient 关闭时机会打架。
    @State private var popover: StagePopover?

    /// 用户此刻正按着宽度调整条(Slider 的 onEditingChanged)。
    ///
    /// 用途是把背景透明时那条常驻的窗口轮廓**加强**一档(见 windowEdgeOutline)——
    /// 2026-08-30 第五步之前它是那条轮廓出不出现的**开关**,那是个错误:轮廓要先被看见,
    /// 用户才会想到"中间这块是一扇窗",拿"先去碰控件"当前提等于要求他先发现再被提示。
    ///
    /// (第六步之前这里是**两个** Bool、左右握柄各一个:指针在两个握柄之间移动时,"进了新的"
    /// 和"离开旧的"谁先到不由我们控制,单值状态会被后到的那个"离开"清成 nil。调整条只有一个、
    /// 来源也只有 onEditingChanged 一处,那条坑在这里不复存在 —— 第十步删掉命中区之后,这个
    /// 文件里再没有第二处 hover 状态,那条坑的另一半只剩文档里那份记录。)
    @State private var adjustingWidth = false

    // MARK: - 度量

    /// 舞台下半部留给宽度调整条的通道高度(胶囊约 30pt + 底距 12pt)。
    ///
    /// 卡片只在**这条通道以上**的区域里居中(见 cardArea)。第八步之前卡高恒为 120、
    /// 居中放在整块舞台里,窗下天然剩得下这根滑杆;现在卡片会长高,不显式把这条通道
    /// 留出来的话,开满三行的卡片会直接压在滑杆上。
    private static let widthBarLaneHeight: CGFloat = 44

    /// 卡片那一格的高度 —— 也就是卡高的上限。**这是这一段几何的源头**,舞台高度由它推出来
    /// (第八步是反过来的:先定 288 的舞台,再减出卡片那一格,于是卡片那一格只剩 244,比
    /// 真悬浮窗当时的 269 还矮 25pt,卡底连同译文/下一句一起被 clipShape 裁掉 —— 用户原话
    /// 「现在翻译这些看不到是因为高度不够吗」)。
    ///
    /// 288 是**实测出来的最坏情况**,不是拍的(2026-08-30 第九步,用真 LyricsOverlayView 在
    /// NSHostingView 里按不同设置量 fittingSize;完整数据见
    /// docs/features/04-desktop-overlay.md「编辑台改造」第九步):
    ///   - 罗马音/译文/下一句三行全开、主歌词一行 → 20pt:167.5 / 31pt:206.5 / 36pt:222.5
    ///   - 同上,主歌词换行到两行         → 20pt:191.5 / 31pt:243.5 / 36pt:265.5
    ///   - 逐词罗马音(日文那种标在每个词底下的)+ 译文 + 下一句,主歌词两行
    ///                                     → 20pt:242.5 / 31pt:260.5 / 36pt:286.5
    /// 字号上限是 36(「文字…」浮层里那根滑杆 `in: 14...36`),所以 286.5 就是"能被单次换行
    /// 撞到"的天花板,向上取整留 1.5pt 余量 = 288。
    ///
    /// ⚠️ 关键观察:**同一份内容、同一个换行行数下,高度跟 overlayWidth 无关**(420/450/640/
    /// 1000 四档量出来一模一样)—— 宽度只决定"换不换行",不决定"一行多高"。所以拿"最坏行数"
    /// 定一个常量,既装得下,又不会让舞台高度间接依赖窗宽(那正是第七步修掉的「背景永远不要
    /// 变」:舞台一动,整张壁纸就跟着上下动)。
    ///
    /// 还装不下的(两次以上换行、或者 36pt 逐词罗马音再多换一行)照旧溢出、由舞台的 clipShape
    /// 裁掉底边 —— 那比让卡片压住调整条、或者让舞台高度跟着内容跳要好。取舍写在这里:再往上抬
    /// 就是拿整页版面换一个越来越罕见的组合,而 288 已经覆盖了三个显示开关的**全部**组合 ×
    /// 全字号 × 一次换行。
    private static let maxCardHeight: CGFloat = 288

    /// 卡片可用的那一格。卡片在这一格里垂直居中。
    private static var cardAreaHeight: CGFloat { maxCardHeight }

    /// 编辑台画布区的高度 = 卡片那一格 + 调整条通道。
    ///
    /// **必须是常量**,不能跟着卡高自适应 —— 换行是宽度的函数,舞台高度一旦间接依赖
    /// overlayWidth,拖宽度调整条时整张壁纸就会跟着上下动。它现在只依赖 maxCardHeight 和
    /// widthBarLaneHeight 两个常量,跟 overlayWidth 没有任何关系。
    ///
    /// 它挂在**可滚动内容区**里(不是 safeAreaInset 上的固定头部),所以不像钉条那样受
    /// "高度一变整页就跳"的约束。
    static var stageHeight: CGFloat { cardAreaHeight + widthBarLaneHeight }

    /// 编辑台里那张卡的高度 —— **由真视图自己报**,不再按字号估。
    ///
    /// 地板 120pt 是真悬浮窗的默认/最小高度(LyricsOverlayWindowController 里的
    /// `overlayDefaultHeight`,那是个文件级 private 常量,取不到,只能同步一份;改那边
    /// 记得改这里),`max(120, ceil(h))` 这条口径跟真窗口的 updateHeight 逐字一致 ——
    /// 真窗口里单行歌词上方那片富余留白本身就是所见即所得的一部分。
    ///
    /// (第八步之前这里是 `max(120, OverlayPreviewBar.rawCardHeight)`,拿钉条那条
    /// `fontSize * 1.5 + 28` 兜底。那条公式既不含常驻的播放控制排槽位,也不含译文/罗马音/
    /// 下一句/换行,真视图一进来就不够用了。)
    ///
    /// ⚠️ 这条公式本身从第八步起就是对的,坏的是**喂给它的数**:第十一步之前
    /// `ContentHeightPreferenceKey` 的 reduce 是覆盖式的,真实高度会被别的分支贡献的
    /// `defaultValue`(0)冲掉,`overlayContentHeight` 恒为 0 → 卡高被摁在 120pt 的地板上 →
    /// `.clipped()` 把译文和下一句整个裁掉。看到"编辑台不画译文/下一句"先量这个数,别去查
    /// `OverlayPlayback` 的那几个显隐开关(实测它们一直是对的)。来龙去脉见那个 key 的注释和
    /// docs/features/04-desktop-overlay.md「编辑台改造」第十一步。
    private var cardHeight: CGFloat {
        min(max(Self.overlayWindowDefaultHeight, ceil(overlayContentHeight)), Self.maxCardHeight)
    }

    private static let overlayWindowDefaultHeight: CGFloat = 120

    /// 编辑台的示例行 —— 没在播放(或这首歌还没解析出歌词)时画它,理由见 OverlayPreviewLine。
    ///
    /// 三条附属文字(罗马音/译文/下一句)写成**自我说明**的句子而不是伪造的拼音/外文:
    /// 它们各自的字号(主字号的 0.65x/0.7x/0.7x)和不透明度(0.6/0.75/0.4)才是这里要预览的
    /// 东西,而"这一行是什么"直接写出来比让人猜更省事。`words` 传 nil —— 没在播放就没有真实
    /// 时间轴,逐字填色无从谈起(共用画布当初也是同一个取舍);`side` 传 nil,于是对唱装饰
    /// 不出现、对齐完全交给「对齐方式」覆盖决定,跟真窗口对没有演唱者标记的普通歌走的是
    /// 同一条路径。
    private static var previewLine: OverlayPreviewLine {
        OverlayPreviewLine(
            line: SyncedLyricLine(
                romanization: L10n.t("这里是罗马音示例"),
                translation: L10n.t("这里是译文示例"),
                mainText: L10n.t("这里是一句歌词示例"),
                words: nil, wordGroups: nil, side: nil),
            nextLineText: L10n.t("这里是下一句歌词示例"))
    }

    /// 宽度调整条那根滑杆有多长、整条胶囊离舞台底边留多远。
    ///
    /// 舞台底部那条 widthBarLaneHeight(44pt)高的通道专门留给它,卡片再高也压不到
    /// (见 cardAreaHeight)。滑杆 168pt 是"够得着又不顶宽"的量:整条胶囊连图标带读数约
    /// 260pt,而舞台最窄也有四百多 pt。
    private static let widthBarSliderWidth: CGFloat = 168
    private static let widthBarBottomInset: CGFloat = 12

    /// 窗口比编辑台还宽时,两端各盖多宽的一条渐隐带。
    ///
    /// 它是"没显示全"唯一的**视觉**信号(caption 里那句「两端已裁切」只是文字兜底):太窄看
    /// 不出来,太宽会把歌词本身也糊掉;20pt 大约是一个汉字的量级。
    private static let overflowFadeWidth: CGFloat = 20

    /// 工具栏那一条的高度。26 是 `.bordered` 小按钮的自然高度量级 —— 写死而不是让它
    /// 自己撑,是因为整块的高度必须是常量(见 body 里 `.frame(height:)` 那段注释)。
    private static let toolbarHeight: CGFloat = 26

    /// 工具栏和画布之间的呼吸。比 caption 那边宽一点:工具栏是**可操作**的一条,
    /// 跟画布贴太近会让人分不清按钮属于工具栏还是画布。
    private static let toolbarSpacing: CGFloat = 10

    /// 整块(工具栏 + 画布 + 底部说明行)占的高度。caption 那一行的间距和行高沿用三条
    /// 预览栏共用的那套度量,免得同一个窗口里两处 caption 的疏密不一样。
    static var totalHeight: CGFloat {
        toolbarHeight + toolbarSpacing
            + stageHeight + SectionPreviewMetrics.captionSpacing + SectionPreviewMetrics.captionHeight
    }

    /// 宽度的合法区间。
    ///
    /// **这里是三处的唯一真源**:「全部设置」抽屉那根滑杆、菜单栏快捷面板那根滑杆、
    /// 以及编辑台的调整条,全部 `in: OverlayEditorStage.widthRange`。不要在任何一处另写
    /// 字面量 —— 一处能产生别处够不到的值,用户下次一动另一根滑杆就会被弹回去,表现是
    /// "我调好的宽度自己变了"。
    ///
    /// 2026-08-30 从 `420...1000` 扩到 `300...1400`(用户:「配的 420 到 1000 的区间我感觉
    /// 不是很合理,没有覆盖最黄金的区域」)。参照这台机器的屏幕逻辑宽约 1470pt:
    /// 旧下限 420 ≈ 屏宽 29%,想要更窄的一条根本够不着;旧上限 1000 ≈ 68%,离"铺满一整屏"
    /// 也还差一截。新区间 ≈ 屏宽 20%~95%,两端都留到位。
    ///
    /// ⚠️ 两端必须是 `widthStep`(2) 的整数倍 —— `snap()` 先夹后量化,不是倍数会把值顶出界。
    /// 300/1400 都满足。另:超过编辑台 1:1 的可视上限(600)之后,编辑台会居中裁切并提示
    /// 「两端已裁切」,这是预期行为,不是 bug。
    static let widthRange: ClosedRange<Double> = 300 ... 1400

    /// 宽度调整条的步长(pt)。
    ///
    /// 2pt 而不是抽屉/菜单栏那两根滑杆的 10pt:那两根是兜底通路、旁边没有实时预览,粗一点
    /// 反而好落值;编辑台这根紧挨着那扇跟着实时变宽变窄的窗,10pt 一格看得出来是在跳。2 这个
    /// 数是从删掉的拖拽握柄那边继承的(它按"单侧拖 1pt、宽度走 2pt"量化);再细到 1 只会让
    /// 真正落盘的写入翻倍,视觉上分辨不出来。
    static let widthStep: Double = 2

    /// 这扇窗现在有多宽(pt)。编辑台按它 1:1 画。
    ///
    /// 2026-08-30 第六步之前这里叫 effectiveWidth,要在"拖动中还没落盘的临时值"和设置里的
    /// 真值之间二选一 —— 调整条是实时落盘的(见 widthBinding),不再有第二个真相。
    /// 拖动中的临时宽度(nil = 没在拖)。
    ///
    /// ⚠️ 这是**性能必需**,不是锦上添花(2026-08-30 用户报"拖动这个宽度条的时候卡顿,不流畅")。
    /// 原来 Slider 的 set 直接写 `settings.overlayWidth`:step 是 2pt,从 300 拖到 1400 就是
    /// 550 次,每一次都要 ①`@Published` 广播一遍(整页所有观察 AppSettings 的视图跟着重渲染)、
    /// ②写一次 UserDefaults、③让真悬浮窗重新布局。而编辑台里跑的是**真** LyricsOverlayView,
    /// 每次还要重算 WrapLayout 换行、重新上报内容高度 —— 一帧里塞这么多事,必卡。
    ///
    /// 现在拖动中只动这个 `@State`:只有编辑台自己重画(它本来就要跟手),不写盘、不广播全局、
    /// 不碰真窗口;`onEditingChanged` 收到 false 时一次性提交。这正是删掉拖拽握柄时一并删掉的
    /// `pendingWidth` 模式 —— 换成 Slider 之后同一个理由依然成立,当时不该跟着删。
    @State private var draggingWidth: Double?

    private var windowWidth: CGFloat { CGFloat(draggingWidth ?? settings.overlayWidth) }

    /// 这扇窗已经宽到被编辑台裁掉两端了吗?
    ///
    /// ⚠️ **编辑台按 1:1 真实 pt 画,不缩放**(2026-08-30)。而 overlayWidth 上限是 1000pt,
    /// 编辑台的可用宽度却被卡片列封死(`SettingsPage.maxCardColumnWidth` = 600,设置窗口再拖宽
    /// 这一列也不涨)—— 600pt 往上必然放不下。放不下时的取舍是**居中裁切**:
    ///   - 不缩放:缩放会让"看到的就是它在桌面上的实际大小"这个前提整个塌掉,而那正是这次
    ///     要修的问题本身;
    ///   - 裁切不需要解释:真实世界里本来就是"窗口摆在更宽的屏幕上",编辑台比窗口窄时看不到
    ///     全貌,跟用户在桌面上的经验一致;
    ///   - 不用横向滚动条:设置页整页自己还在纵向滚,里面再嵌一条横向滚动条很别扭,而且它会
    ///     诱导用户"滚着把内容读完"——这块画布要看的是尺寸感,不是内容。
    /// 代价是超宽时看不见窗口的左右边缘,所以必须补两个信号:两端渐隐(overflowFade)+ caption
    /// 里那句「两端已裁切」。少了它们,用户会以为"这扇窗就这么宽"。
    private static func isOverflowing(cardWidth: CGFloat, stageWidth: CGFloat) -> Bool {
        // 0.5 的余量:宽度量化到 2pt、舞台宽度是测出来的浮点数,差几个 0.0x 不该点亮渐隐带。
        cardWidth > stageWidth + 0.5
    }

    /// 舞台里**看得见**的那部分窗口有多宽。
    ///
    /// 超宽时窗口的左右边缘已经在舞台外面了,凡是要贴着窗口边缘摆的东西都得按这个宽度算 ——
    /// 现在只剩左下角那个锁标(见 lockBadge 的 clippedInset)。
    /// (第十步之前它还兜着两块命中区:SwiftUI 的 `clipShape` 只保证**画**不出去,不保证连命中
    /// 测试一起裁掉,不自己收窄的话用户点在编辑台外面的页面空白上也会弹出浮层。命中区删掉之后
    /// 这条没了作用对象,但结论对以后任何"贴着窗口边缘的可交互件"仍然成立。)
    private static func visibleCardWidth(cardWidth: CGFloat, stageWidth: CGFloat) -> CGFloat {
        min(cardWidth, stageWidth)
    }

    var body: some View {
        GeometryReader { geo in
            // 舞台宽度 = 容器给多少吃多少(卡片列上限 600pt)。两侧**不**给任何控件预留位置,
            // 1:1 放得下的宽度上限因此就是这一列的硬顶 600pt,常用宽度段都能按原尺寸摆下。
            // (第一步这里曾在两侧各留一份拖拽握柄的位置,上限只有 544pt;第四步握柄挪进窗口、
            // 第六步整个删掉,那份预留跟着没了。)
            let stageWidth = geo.size.width
            VStack(spacing: Self.toolbarSpacing) {
                toolbar
                    .frame(height: Self.toolbarHeight)
                VStack(spacing: SectionPreviewMetrics.captionSpacing) {
                    stage(stageWidth: stageWidth)
                    caption(stageWidth: stageWidth)
                }
            }
            .frame(maxWidth: .infinity)
        }
        // GeometryReader 会贪心吃掉外部给的全部空间,所以高度必须在外面焊死;高度是常量,
        // 不依赖测量结果,不存在"读了尺寸又改尺寸"的布局回路。
        //
        // ⚠️ 卡高(cardHeight)从第八步起是**量出来的**,但整块的高度**仍然是常量** —— 舞台
        // 定高、卡片在舞台里长高变矮,外面这一层一动不动。这条不能破:编辑台挂在可滚动内容区
        // 里,它一变高,下面所有卡片都会跟着跳一下,而开关译文/罗马音这类操作恰恰会改卡高。
        .frame(height: Self.totalHeight)
    }

    // MARK: - 工具栏

    /// 编辑台顶上那一条:三个浮层入口 + 重置菜单。
    ///
    /// 「文字…」「配色…」「排版…」放左边、「重置 ▾」推到右边:重置是一次性的破坏性动作,
    /// 跟高频入口隔开一段距离,少一点误点(设计稿也是把它从卡片里收进这个菜单的 ——
    /// "不适合摆在画布上被误点")。
    ///
    /// ⚠️ 这三颗按钮是三个浮层**唯一**的入口(第十步删掉画布命中区之后)。原先画布上还有
    /// "点歌词/点背景"两块快捷方式,而那种入口靠 hover 才看得见、键盘和 VoiceOver 根本够不着 ——
    /// 显式入口一直是主路径、不是兜底,所以删掉快捷方式没有留下够不到的设置。
    ///
    /// ⚠️ 横向够不够(2026-08-31 加第三个入口时离屏量的,别凭感觉重排):这一条的可用宽度
    /// 就是卡片列宽 —— 窗口按 idealWidth 860 打开时 600pt(卡片列上限),拖到 minWidth 760
    /// 时约 530pt。三个入口带摘要的自然宽度:中文常见值 535pt、中文最坏(超长字体名 + 超长
    /// 自定义主题名)672pt、英文常见值 662pt。所以 600pt 下中文常见值刚好整条读得完,再窄或
    /// 换英文就得靠摘要截断 —— 这是接受的取舍:摘要是"不点开也知道现在什么样"的赠品,入口
    /// 本身才是功能。为此摘要那截给了 `.layoutPriority(-1)`,让它**先**被压(见 toolbarButton)。
    private var toolbar: some View {
        HStack(spacing: 8) {
            toolbarButton(
                icon: "textformat",
                title: L10n.t("文字"),
                summary: OverlayStyleSummary.text,
                target: .text
            )
            toolbarButton(
                icon: "circle.lefthalf.filled",
                title: L10n.t("配色"),
                summary: OverlayStyleSummary.color,
                target: .color
            )
            // 2026-08-31 新增。用户原话:「双行显示不应该挂在这个文字里面吧,是否应该是一个
            // 独立的开关呢;还有这个对齐方式也是,不应该是子选项吧」—— 那两项讲的是排几行、
            // 摆哪边,是版面不是字形,于是从「文字」里拆出来单开一个入口(拆的判据写在
            // OverlayLayoutSettingsRows 上面)。图标 `text.justify` 就是设计稿里那个「≣」。
            toolbarButton(
                icon: "text.justify",
                title: L10n.t("排版"),
                summary: OverlayStyleSummary.layout,
                target: .layout
            )
            Spacer(minLength: 8)
            Menu {
                Button(L10n.t("恢复默认文字与配色")) { OverlayStyleDefaults.restoreTextAndColors() }
                // 作用范围写成菜单里一条**不可点**的说明项(SwiftUI 里裸 Text 在 Menu 中
                // 就是一条禁用菜单项)。不用 Button 的"标题 + 副标题"两段式 label:那个
                // 桥接到 NSMenuItem.subtitle 的行为在这台机器的系统版本上没实测过,而这句
                // 「不含宽度和锁定位置」是作用范围声明、不能"可能没显示出来"。
                Text(L10n.t("不含宽度和锁定位置"))
            } label: {
                Label(L10n.t("重置"), systemImage: "arrow.uturn.backward")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 2)
    }

    private func toolbarButton(
        icon: String, title: String, summary: String, target: StagePopover
    ) -> some View {
        Button {
            popover = target
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    // 图标锁死拉丁语区,理由同 SettingsRow:textformat 这类"字母造型"的
                    // SF Symbol 带 CJK 变体,中文界面下会被渲染成汉字「格式」。
                    .environment(\.locale, Locale(identifier: "en"))
                Text(title)
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(.tertiary)
                // ⚠️ 摘要**必须**限宽 + 单行 + 尾部省略。它是纯派生值(见 OverlayStyleSummary),
                // 内容里有用户装的字体族名 —— "Hiragino Sans GB W3"这种长名字不限宽的话会
                // 把整条工具栏顶出编辑台。maxWidth 只是上限,短摘要照样贴着自己收缩。
                Text(summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 140, alignment: .leading)
                    // ⚠️ 2026-08-31 加第三个入口时补的,离屏渲染验过:工具栏挤不下时,不加这
                    // 一句 SwiftUI 会把亏空按比例摊给按钮里**所有**文字,标题先被截成「文…」
                    // 「配…」「排…」—— 入口的名字没了,摘要却还留着半截,主次正好反过来。
                    // 负优先级让摘要在标题之前被压,窄到极限时它先缩成「…」、标题始终完整。
                    .layoutPriority(-1)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .popover(isPresented: popoverBinding(target), arrowEdge: .bottom) {
            popoverContent(for: target)
        }
    }

    // MARK: - 浮层

    /// 当前该开哪个浮层(nil = 都没开)。
    ///
    /// (第十步之前每个 case 还带一个 `Anchor`:同一个浮层有工具栏按钮和画布命中区两个入口,
    ///  而 SwiftUI 的 `.popover` 绑在具体视图上、没法"一份状态、按需换锚点",只能两个入口各挂
    ///  一份修饰符,再用 Anchor 把"该开哪一份"编进同一个可空状态里。入口只剩工具栏之后 Anchor
    ///  跟着没了,但"一个可空枚举而不是几个 Bool"这条没变 —— 两个 NSPopover 同时摆出来会互相
    ///  遮挡、transient 关闭时机还打架。)
    private enum StagePopover: Equatable {
        case text
        case color
        case layout
    }

    private func popoverBinding(_ target: StagePopover) -> Binding<Bool> {
        Binding(
            get: { popover == target },
            // 只在关的是"自己"那一份时才清空:popover 已经切到别的目标时,旧那份收到的
            // isPresented=false 不该把新开的这个也一起关掉。
            set: { shown in
                if shown { popover = target } else if popover == target { popover = nil }
            })
    }

    @ViewBuilder
    private func popoverContent(for target: StagePopover) -> some View {
        switch target {
        case .text: OverlayTextPopover()
        case .color: OverlayColorPopover()
        case .layout: OverlayLayoutPopover()
        }
    }

    // MARK: - 画布区

    private func stage(stageWidth: CGFloat) -> some View {
        let cardWidth = windowWidth
        let visibleWidth = Self.visibleCardWidth(cardWidth: cardWidth, stageWidth: stageWidth)
        return ZStack {
            stageBackground
            desktopSurround(stageWidth: stageWidth)
            inCardSlot { canvas(visibleWidth: visibleWidth) }
            inCardSlot { windowEdgeOutline(cardWidth: cardWidth) }
            // 渐隐带压在卡片**和轮廓**上:它要糊掉的是"被裁掉的那条边",轮廓那两条横线在
            // 超宽时也一路顶到舞台边,不一起溶掉的话它们会在渐隐带里显得格外硬,反倒像
            // "窗口到这儿就完了"。
            if Self.isOverflowing(cardWidth: cardWidth, stageWidth: stageWidth) {
                inCardSlot { overflowFade }
            }
            // 调整条摆在最上面:它是**控件**不是内容,任何时候都不该被渐隐带糊掉(渐隐带只盖
            // 卡片那么高、落在 cardArea 里,跟窗下这条通道不重叠,这里是把层序写成显式约束)。
            // 先 padding 再 frame:反过来的话那 12pt 会加在"撑满舞台"的那一层外面,把整块顶高。
            widthBar
                .padding(.bottom, Self.widthBarBottomInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        // 宽度用**测出来的实际值**,不用 maxWidth: .infinity —— 后者遇到一个比它还宽的固定尺寸
        // 子视图(超宽的卡片)会被撑到子视图的尺寸,那样"裁切"就无从谈起了。高度是常量。
        .frame(width: stageWidth, height: Self.stageHeight)
        // 超出编辑台的部分在这里裁掉。裁在**舞台**的圆角上而不是给卡片自己套一层裁切:卡片没
        // 超宽时这一层什么也不做,超宽时切出来的边正好贴着编辑台的边框,像是"窗口伸出去了"。
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // 舞台自己那条发丝描边挪到裁切**之后**(2026-08-30 第五步):壁纸现在铺满整块舞台,
        // 压在底板上会把它整个盖住,而这条边是舞台跟设置页之间唯一的分界。透明度也从 0.07
        // 提到 0.12 —— 它现在描在一张照片上,0.07 那一档在壁纸上基本看不见。
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    /// 把一块**跟卡片同高**的内容摆进"窗口那一格":在舞台上半部(去掉底部那条调整条通道)
    /// 垂直居中。卡片、常驻虚线轮廓、超宽渐隐带三者必须走同一个摆放函数 —— 它们描述的是
    /// 同一扇窗,任何一个单独居中都会跟另外两个错位。
    ///
    /// 为什么不干脆让 ZStack 居中(第八步之前就是那样):那时卡高恒为 120,窗下天然剩得下
    /// 调整条;现在卡片会随译文/罗马音/下一句/换行长高,整块舞台居中的话它会直接压在滑杆上。
    private func inCardSlot<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(height: Self.cardAreaHeight)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    /// 编辑台的底板。读得到桌面壁纸时它整个被 desktopSurround 盖住;读不到时
    /// desktopSurround 退回棋盘格(半透明的灰格子),这块底板就是那些格子底下的地。
    ///
    /// 刻意**不**用 settingsCardBackground 那套液态玻璃:玻璃的可见度完全取决于背后有
    /// 什么(见 SettingsDesignSystem 里那条⚠️),而这块底板上压着的是真实桌面壁纸 ——
    /// 玻璃只会让"哪里是壁纸、哪里是设置页"这条边界更糊。一层低透明度的中性填充就够,
    /// 而且深浅色模式下都成立。
    private var stageBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.05))
    }

    // MARK: - 舞台那张桌面

    /// 铺满整个舞台的桌面壁纸 —— **舞台是一小片桌面**,悬浮歌词窗口 1:1 摆在它上面
    /// (横向居中,纵向居中于"去掉底部调整条通道"之后那一格,见 inCardSlot)。
    ///
    /// 2026-08-30 第五步。用户原话:「我意思是不应该可以拖动的是里面这部分吗外面这个框为
    /// 什么要去拖动他」——截图里那块贴满壁纸的矩形被读成「外面这个框」,歌词被读成「里面这
    /// 部分」。根因不是握柄贴错了地方(第四步起它就贴在窗口边上),而是**那块壁纸的宽度恰好
    /// 就等于窗口宽度**:窗外没有桌面、窗口自己又没有可见边界,那扇窗就只能被读成「一张带图
    /// 的背景板」。桌面铺到舞台两端之后,窗口窄于舞台时两侧自然露出桌面,「里面这部分」才有得
    /// 指。(窗下露出来的那片桌面还兼着宽度调整条 widthBar 的落脚处。)
    ///
    /// ⚠️ **这是整块舞台唯一的一张壁纸**(2026-08-30 第七步)。它按**舞台宽度**和舞台高度画,
    /// 跟 overlayWidth 没有半点关系 —— 拖宽度调整条时它一个像素都不动,这正是第七步要修的
    /// 东西(用户原话:「背景永远不要变」)。窗口那块**不画**壁纸,相当于在这张图上开了个洞,
    /// 让它透上来(第七步靠给共用画布传 showsDesktopUnderlay: false 实现;第八步换成真视图
    /// 之后天然如此 —— 真视图本来就只画属于窗口自己的东西)。读不到壁纸时
    /// 它退回棋盘格、同样铺满舞台 —— 窗内窗外走的是同一份实现(OverlayDesktopSurface),
    /// 不会出现两种画法(第五步这里是「什么都不画、露出底板」,因为当时还没有那份共用实现)。
    ///
    /// ⚠️ **窗外那圈高斯虚化已经删掉了,别再加回来。** 第五到第七步之间它是必须的:那时舞台
    /// 上有两张壁纸,窗内那张是拿**窗口这个又宽又扁的矩形**做 scaledToFill 的,整张图被横向
    /// 压进窗口宽度里,跟这里按舞台宽度裁的那张缩放比差着一成多;清晰地拼在一起会在窗口边缘
    /// 看到**同一张壁纸出现两次**(窗外那两条带子里挤着一份压扁的全图),像渲染坏了 —— 虚化
    /// 是用来藏这道接缝的(顺带白得一条跟壁纸内容无关的边界信号)。第七步只剩一张图,接缝
    /// 不存在了,虚化就只剩副作用。为此还删掉了专门用来把虚化烘成位图的 OverlayStageDesktop
    /// (高斯半径 10pt、按位图/点比例换算成像素、CoreImage 整个进程只算一次那一套)——
    /// 它存在的唯一理由就是这圈虚化。窗口边界现在靠背景色圆角块(背景可见时)和那圈常驻虚线
    /// 轮廓(windowEdgeOutline,背景透明时)来分,那两样本来就是干这个的。
    ///
    /// 薄纱那一层**保留,但语义变了**:它现在**均匀**盖住整块舞台、窗内窗外一视同仁,只负责
    /// 把这一小片桌面压得别在设置页里太抢眼,不再承担任何「哪里是窗口」的表达。均匀是硬要求
    /// —— 任何「只压窗外」的遮罩都会随窗口宽度变形,那就又变回「改宽度把背景也改了」。用
    /// windowBackgroundColor 而不是固定黑色:深色模式压暗、浅色模式压淡,两边都朝设置页那个
    /// 方向收,整块卡不会在某一个外观下显得脏。
    private func desktopSurround(stageWidth: CGFloat) -> some View {
        OverlayDesktopSurface()
            .frame(width: stageWidth, height: Self.stageHeight)
            .clipped()
            .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.16))
            // 窗外的桌面**不是窗口的一部分**,点它什么也不该发生。显式关掉命中测试,把这条
            // 写进代码而不是靠「反正它没挂手势」—— 第十步删掉画布命中区之后整块舞台已经没有
            // 任何可点的东西,这一句就只剩"把意图写清楚"这一个作用了。
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// 舞台正中那扇窗 —— **真窗口那份 LyricsOverlayView 本体**(2026-08-30 第八步)。
    ///
    /// 译文、罗马音(整行的和逐词标注的)、下一句预览、WrapLayout 自动换行、对唱两侧内缩与
    /// 声部指示圆点、逐字卡拉OK填色、描边、「对齐方式」覆盖、字体/字号/配色 —— 一律由真视图
    /// 自己画,这边一行渲染代码都没有,也就没有第二份会漂的实现。它自己读
    /// PlaybackCoordinator/AppSettings(见 OverlayPlayback),不需要这边喂任何数据。
    ///
    /// 宽度必须**恰好等于** settings.overlayWidth(1:1,不缩放):真视图算对唱两侧内缩用的
    /// 是 `overlayWidth − 40`(OverlayPlayback.duetInsetUnit),给个别的宽度就自相矛盾了。
    ///
    /// 高度用真视图报上来的内容高度(见 cardHeight)。它内部最后一句是
    /// `.frame(maxHeight: .infinity, alignment: .top)`,内容永远贴着这个框的顶边 —— 跟真窗口
    /// 一致(那条 alignment 的来龙去脉见 LyricsOverlayView.body 末尾)。
    ///
    /// **窗口不画壁纸**:真视图本来就只画属于窗口自己的东西(背景色圆角块/文字/描边),
    /// 背景透明时透出来的就是舞台那张按舞台宽度铺的壁纸 —— 第七步「窗口在壁纸上开洞」这条
    /// 现在是天然成立的,不再需要给共用画布传 showsDesktopUnderlay: false 去关。
    private func canvas(visibleWidth: CGFloat) -> some View {
        let cardWidth = windowWidth
        return LyricsOverlayView(
            overlayController: chrome,
            onContentHeightChange: { overlayContentHeight = $0 },
            // 调试 HUD 那个 fps 角标不属于"这扇窗在桌面上的样子",开着还会让帧率探针每帧
            // tick 一次(见 LyricsOverlayView.showsDebugHUD)。
            showsDebugHUD: false,
            previewLine: Self.previewLine)
            .frame(width: cardWidth, height: cardHeight, alignment: .top)
            // 裁到窗口自己的边界上。常态下这一层什么也不做(卡高就是量出来的内容高度),它兜的
            // 是 maxCardHeight 夹住的那种极端组合(第九步把上限抬到实测的最坏情况之后,只剩
            // "两次以上换行"这一档才够得着):不裁的话溢出的文字会画到窗外那片桌面上、甚至压到
            // 窗下那条调整条。真窗口也是裁在窗口边界上的(NSHostingView 铺满 contentView),
            // 所以这更贴近真实,不是权宜。
            .clipped()
            // 「锁定位置」在编辑台上**唯一**能被看见的产物,所以贴在卡片上、跟着卡片一起
            // 被裁(见 lockBadge 的 clippedInset)—— 它演的就是"这张卡现在长什么样"。
            .overlay(alignment: .bottomLeading) {
                lockBadge(clippedInset: (cardWidth - visibleWidth) / 2)
            }
            // 锁标那条 .transition(.opacity) 要有动画事务才跑得起来 —— 开关在行为栏上,
            // 那边没有 withAnimation(它是个普通开关,不是"整张卡出现/消失"),所以在这里
            // 就近给一条只认 lockPosition 的动画。挂 value: 而不是裸 .animation():
            // 裸的那种会把画布里所有变化都动画化,包括逐字填色每一帧。
            .animation(.easeOut(duration: 0.15), value: settings.lockPosition)
    }

    // MARK: - 锁标

    /// 「锁定位置」打开时,画布左下角的一个小标。
    ///
    /// 它是这个开关在编辑台上**唯一**的视觉产物 —— 编辑台画的虽然是真视图本身,但点击穿透、
    /// 长按拖动这些都长在窗口控制器上(不在视图里),预览没有,唯一还能表达的就是"这张卡被
    /// 钉住了"这个事实本身。
    /// ⚠️ **它本身在第十步保留了**:行为栏那一格底下原本有一句「锁上后编辑台左下角会出现锁标」
    /// 介绍它,那句按用户要求删了,但锁标是这个开关在编辑台上唯一的真实反馈 —— 删掉解释不等于
    /// 删掉被解释的东西。
    ///
    /// 固定黑底白字、**不跟深浅色模式走**,理由同 widthBar:它浮在卡片上,而卡片底下垫的
    /// 是用户真实的桌面壁纸,那块底色是什么样完全不受 App 控制,用语义色会在浅壁纸上直接
    /// 读不出来。
    ///
    /// 不接事件、不进无障碍树:它是行为栏那颗开关的镜像,不是第二个入口 —— 都暴露出来
    /// VoiceOver 会把同一件事读两遍(同 widthBar 那个读数)。
    @ViewBuilder
    private func lockBadge(clippedInset: CGFloat) -> some View {
        if settings.lockPosition {
            HStack(spacing: 3) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                Text(L10n.t("位置已锁定"))
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.7)))
            .foregroundStyle(.white)
            .padding(6)
            // 窗口超宽被裁时,它原本贴着的那个左下角已经在舞台外面了 —— 往里让开被裁掉的
            // 那一半,免得"锁定位置唯一的视觉产物"在宽窗口下凭空消失(窗口没超宽时这个值
            // 是 0,排版逐像素不变)。
            .padding(.leading, clippedInset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity)
        }
    }

    // MARK: - 超宽与透明背景的两块补偿

    /// 窗口比编辑台还宽时,两端各一条渐隐带。
    ///
    /// 渐隐到**页面底色**而不是舞台那层半透明填充:它要表达的是"内容从这里溶进页面、后面还有
    /// 一截",一条硬边会被读成"窗口就这么宽",那正是裁切这个方案最需要防的误解。
    ///
    /// 只盖卡片那么高、不盖满整个舞台:舞台上下留白处并没有内容被裁掉,在那儿也铺一层
    /// 页面底色只会让编辑台的边框显得脏。(摆放交给 inCardSlot,跟卡片和轮廓走同一格。)
    private var overflowFade: some View {
        HStack(spacing: 0) {
            fadeEdge(leading: true)
            Spacer(minLength: 0)
            fadeEdge(leading: false)
        }
        .frame(height: cardHeight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func fadeEdge(leading: Bool) -> some View {
        let page = Color(nsColor: .windowBackgroundColor)
        let colors = leading ? [page, page.opacity(0)] : [page.opacity(0), page]
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
            .frame(width: Self.overflowFadeWidth)
    }

    /// 背景透明时,悬浮歌词窗口那条**常驻**的边界。
    ///
    /// ⚠️ "常驻"是 2026-08-30 第五步的核心,不是可调的观感。上一版只在握柄活跃(悬停/拖动)
    /// 时才描这条线,那等于"要先发现才能被提示":用户压根没意识到中间那块是一扇窗,自然不会
    /// 把指针移到它边上去,提示于是永远不出现——两轮反馈说的都是同一件事,原因就在这儿。
    /// 窗外铺上桌面之后这条边更不能省:背景透明时窗口本身只是"壁纸上一块看不出边的区域",
    /// 没有它,"窗口有这么宽"就仍然无从读起。
    ///
    /// 只在 `!backgroundIsVisible` 时画:背景块画着的时候那个圆角块自己就是边界(真窗口也没
    /// 有边框),再叠一圈虚线纯属噪音。
    ///
    /// 配色照抄 lockBadge / widthBar 那条老规矩:**固定白色 + 黑色投影,不跟深浅色
    /// 模式走**。它压在用户真实的桌面壁纸上,那块底色什么样完全不受 App 控制,语义色
    /// (primary/secondary)在浅壁纸上会直接读不出来;投影负责在亮壁纸上给白线兜一圈暗轮廓,
    /// 深浅壁纸上都成立。静止态压到 0.5 是"克制"的那一半——它是常驻的,画满就成了一个假边框,
    /// 而真窗口并没有边;调整条一被按住提到 0.95(2026-08-30 第六步起由 Slider 的
    /// onEditingChanged 上报,此前是握柄的悬停/拖动),"我正在改的是这扇窗的宽度"才立得住。
    ///
    /// ⚠️ 握柄删掉之后,这圈轮廓是那句话**唯一**的视觉锚点(以前还有贴在窗口边上的两根杆子)。
    /// 别把它当可有可无的装饰顺手删掉。
    ///
    /// 圆角 16 是悬浮窗的圆角(LyricsOverlayView.overlayBackgroundCornerRadius,那是个
    /// private 常量,取不到,只能同步一份;改那边记得改这里)。
    ///
    /// ⚠️ 宽度按**卡片真实宽度**画,不是 visibleWidth:窗口超宽时左右两条边本来就在舞台外面,
    /// 让它们被舞台的 clipShape 裁掉、只剩上下两条横线,说的正好是"窗口有这么高、两端还没完",
    /// 跟渐隐带和 caption 里那句「两端已裁切」是一套话。按 visibleWidth 画会在舞台内沿描出一个
    /// **闭合**的框,那是在撒谎——它会被读成"这扇窗就这么宽"。
    private func windowEdgeOutline(cardWidth: CGFloat) -> some View {
        let strong = adjustingWidth
        return RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(
                Color.white.opacity(strong ? 0.95 : 0.5),
                style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .shadow(color: .black.opacity(0.55), radius: 1)
            .frame(width: cardWidth, height: cardHeight)
            // 用透明度而不是 if 分支:轮廓始终在视图树里,切「背景颜色」时才淡入淡出得起来。
            .opacity(settings.backgroundIsVisible ? 0 : 1)
            // 加强/减弱用 0.12s。
            .animation(.easeOut(duration: 0.12), value: strong)
            .animation(.easeOut(duration: 0.15), value: settings.backgroundIsVisible)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - 宽度调整条

    /// 舞台内部、悬浮歌词窗口正下方那条宽度调整条(2026-08-30 第六步,替掉左右两个拖拽握柄)。
    ///
    /// 摆在**舞台里面**而不是舞台底下那行 caption 旁边,是因为它得跟它改的那扇窗待在同一块
    /// 画面里:窗口两侧现在露着桌面(desktopSurround),调整条压在窗外那片桌面上、正对
    /// 窗口下沿,"这根条改的是上面这扇窗的宽度"不用另写一句话解释。
    ///
    /// ⚠️ 配色**固定黑底白字 + 投影,不跟深浅色模式走** —— 同 lockBadge /
    /// windowEdgeOutline 那条老规矩:它底下垫的是用户真实的桌面壁纸,那块底色什么样完全不受
    /// App 控制,语义色(primary/secondary)在浅壁纸上会直接读不出来。三层各司其职:半透明黑
    /// 胶囊把滑杆和读数从任意壁纸里托出来;白色发丝描边负责在**深**壁纸上给胶囊自己留一圈边界
    /// (只有黑胶囊、没有描边的话,深壁纸上它会糊成一团);投影负责在**亮**壁纸上兜一圈暗轮廓。
    /// 滑杆的 `.tint(.white)` 同理 —— 默认强调色跟着系统主题走,压在壁纸上深浅不定。
    private var widthBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 10, weight: .semibold))
            // ⚠️ **不要**给这根 Slider 传 `step:`(2026-08-31 用户:「为什么这里灰色条下面还有
            // 一条纯白的?」)。macOS 的 Slider 一旦有 step 就会画刻度线,而这里
            // range 是 300...1400、step 是 2 —— 550 个刻度密到连成一条实线,看着像轨道下面
            // 平白多了一条白杠。量化本来就不必靠它:`widthBinding` 的 set 一律走 `snap()`
            // (先夹进 widthRange 再量化到 widthStep),值该是什么还是什么。
            Slider(
                value: widthBinding,
                in: Self.widthRange,
                // 只用来把背景透明时那圈常驻的窗口轮廓加强一档(见 windowEdgeOutline)。
                onEditingChanged: { editing in
                    adjustingWidth = editing
                    // 松手:把拖动中攒下的那个值提交出去,然后交还给 settings 当真源。
                    if !editing, let pending = draggingWidth {
                        commitWidth(pending)
                        draggingWidth = nil
                    }
                }
            )
            .controlSize(.small)
            .tint(.white)
            .frame(width: Self.widthBarSliderWidth)
            // Slider 自带键盘/VoiceOver 调节(左右箭头一次一个 step),所以这里只补中文标签和
            // 一个**带单位**的值 —— 不显式给 value 的话 VoiceOver 会把它读成百分比。
            .accessibilityLabel(L10n.t("悬浮歌词宽度"))
            .accessibilityValue(widthValueText)
            Text(widthValueText)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
                // 读数是滑杆的镜像、不是第二个可读元素:都进无障碍树的话 VoiceOver 会把同一个
                // 值读两遍(同 lockBadge 那条)。
                .accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.7)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 5, y: 1)
    }

    /// "640pt"这种带单位的读数。滑杆旁边显示的和 VoiceOver 读的是同一个字符串。
    ///
    /// ⚠️ 这个数字在整块编辑台上**只出现这一处**:caption 那边第六步起不再带宽度 —— 同一个
    /// 数字摆两处,一调两边一起跳,读者会以为那是两件事。
    ///
    /// ⚠️ 读的是 `draggingWidth ?? settings.overlayWidth`,不是裸的 `settings.overlayWidth`
    /// (2026-08-31 修)。落盘推迟到松手之后(见 draggingWidth),而窗口宽度走的是同一个
    /// `??` —— 只有这个读数读裸设置值的话,拖动全程它**冻在上一次提交的数字上**不动,而
    /// 窗口就在旁边跟着变宽,看着像读数坏了。这是第六步加 draggingWidth 那次漏掉的一处。
    private var widthValueText: String {
        String(format: L10n.t("%@pt"), "\(Int(draggingWidth ?? settings.overlayWidth))")
    }

    // MARK: - 宽度落点

    /// 调整条读写的那个绑定,也是编辑台里**唯一**的宽度写入路径。
    ///
    /// (第六步之前是两条:拖动过程只改一个 @State、`.onEnded` 才落盘,外加握柄上那个
    /// accessibilityAdjustableAction 直接落盘。握柄删掉之后两条一起没了 —— Slider 自带键盘/
    /// VoiceOver 调节,不用再手写一条可调节动作。)
    ///
    /// ⚠️ 三条约束一条都不能少,前两条都是本仓真踩过的:
    ///   ① **相等守卫**。Slider 拖动中按鼠标事件频率反复调 set,值经 step 量化后大量重复;而
    ///      `@Published` 是 willSet 语义,**等值赋值照样广播 objectWillChange**,把所有观察
    ///      AppSettings 的界面(整页设置 + 菜单栏快捷面板 + 真悬浮窗)全打醒,`overlayWidth`
    ///      的 didSet 还会白写一次 UserDefaults。
    ///   ② **`if settings.classicOverlayEnabled` 守卫**。`LyricsOverlayWindowController.shared`
    ///      是 `static let`,**光是读一下**就会执行 init() 把窗口建出来 —— 悬浮歌词关着的用户
    ///      只要碰一下这根滑杆,就会凭空多出一扇(不可见但已经装好监听器和观察者的)窗。跳过
    ///      这一句不会让控制器里的镜像变陈旧:真值始终在 AppSettings。
    ///      ⚠️ 2026-08-31 订正:这里原来还写着"窗口真被打开时 setVisible 会按持久化值再应用
    ///      一次几何" —— **那是假的**,`setVisible(_:)` 当时只应用两个隐藏偏好和 lockPosition,
    ///      从不碰宽度。于是"关着改宽度 → 再打开"会按旧宽度冒出来(关这一下本身就走
    ///      `.shared.setVisible(false)`,实例已经在了)。已经在那边补上 `setWidth(持久化值)`,
    ///      这条守卫的正确性挂在那一句上,别把它当清理删掉。
    ///   ③ **clamp 与量化只走 snap**,不在这里另写一份字面量区间(见 widthRange 那条跨三处的契约)。
    ///
    /// ⚠️ 提交只有 `onEditingChanged(false)` 这**一条**出口,而这够用 —— 别为"键盘 / VoiceOver
    /// 调节会不会漏掉这条出口"再加一条兜底写入路径(2026-08-31 离屏实测排除过):
    ///   - 这版 macOS 的 SwiftUI `Slider` **不是 NSSlider 包出来的** —— dump `NSHostingView`
    ///     子树只有 `KeyViewProxy` / `_FocusRingView`,递归找不到任何 `NSSlider`。所以"editing
    ///     边沿只由 AppKit 的鼠标 tracking 产生"这个前提在这里根本不成立,edge 是 SwiftUI 自己发的。
    ///   - 对它发 `AXIncrement` / `AXDecrement`(VoiceOver 上下调节走的就是这两个 action)实测
    ///     每一次都是完整的 `EDITING(true) → set → EDITING(false)`,`commitWidth` 照常执行、
    ///     `draggingWidth` 照常清回 nil。四个独立探针(裸 Slider / 照抄这套 binding 的复刻件)结论一致。
    /// 多加一条写入路径,比它想防的那个并不存在的问题更贵。
    /// (顺带一条实测订正:AX 的一次增减走的是**区间的 10%**,不是 `widthStep` —— 值仍然过 `snap()`
    ///  夹取量化并正常提交,只是别把上面那句"一次一个 step"当准确描述。)
    private var widthBinding: Binding<Double> {
        Binding(
            get: { draggingWidth ?? settings.overlayWidth },
            // 拖动中**只**改本地 @State,理由见 draggingWidth 的注释。落盘与通知真窗口
            // 都推迟到 onEditingChanged 收到 false 那一下(commitWidth)。
            set: { draggingWidth = Self.snap($0) })
    }

    /// 松手时一次性提交。三条规则一条没变(它们跟"什么时候提交"无关,是"提交时必须做什么"):
    ///   ① **相等守卫** —— `@Published` 是 willSet 语义,等值赋值照样广播 objectWillChange,
    ///      `didSet` 还会多写一次 UserDefaults;
    ///   ② **`if settings.classicOverlayEnabled` 守卫** —— `LyricsOverlayWindowController.shared`
    ///      是 `static let`,光是读一下就会 init() 把窗口建出来,悬浮歌词关着的用户会凭空多一扇窗;
    ///      ⚠️ 守卫跳过通知之后,**必须**有人在"窗口重新打开"那一刻把新值应用上 —— 那是
    ///      `LyricsOverlayWindowController.setVisible(_:)` visible 分支里那句 `setWidth(持久化值)`
    ///      (2026-08-31 补,在此之前这条路是真漏的)。
    ///   ③ 值一律走 `snap()` 夹进 `widthRange` 并量化。
    private func commitWidth(_ raw: Double) {
        let next = Self.snap(raw)
        guard next != settings.overlayWidth else { return }
        settings.overlayWidth = next
        if settings.classicOverlayEnabled {
            LyricsOverlayWindowController.shared.setWidth(CGFloat(next))
        }
    }

    /// 夹进合法区间并量化到 widthStep。
    ///
    /// **clamp 和量化只有这一处**,别在调用点再抄一遍字面量区间 —— 区间是跨三个文件的契约
    /// (见 widthRange),抄第二份就等着它们哪天不一样。
    ///
    /// 落盘的值因此可能不是 10 的整数倍,抽屉/菜单栏那两根 10pt 的滑杆照样显示得出来:step
    /// 只约束滑杆自己产生的值,不约束模型。
    ///
    /// 先夹后量化的顺序是安全的:区间两端 300/1400 都是 widthStep 的整数倍,量化不会把值顶出界。
    private static func snap(_ raw: Double) -> Double {
        let clamped = min(max(raw, widthRange.lowerBound), widthRange.upperBound)
        return (clamped / widthStep).rounded() * widthStep
    }

    // MARK: - 底部说明

    /// 舞台底下那行小字。
    ///
    /// ⚠️ **不带宽度数字**(2026-08-30 第六步)。数字现在长在舞台里那条调整条旁边,离它改的那扇
    /// 窗更近;两处都写就成了同一个数字在一屏里跳两下,读者会以为是两件事。
    ///
    /// ⚠️ **「拖窗口两侧改宽度」那半句随握柄一起删了** —— 握柄没了,那句话是错的。它当年是为了
    /// 兜住拖拽的可发现性才加的(2026-08-30 用户问"这个窗口里面怎么去调整悬浮歌词宽度?"),
    /// 而"要靠一句文案才找得到"本身就是那条路走不通的证据,第六步换成滑杆之后不需要它了。
    ///
    /// 「实际大小」必须留着:它是"编辑台不缩放、看到多大就是多大"这个前提唯一的声明,而那正是
    /// 第四步要修的概念性错误(「已缩放至 X%」也是那时删的;钉条那边照旧有,它的 caption 是另
    /// 一条文案)。超宽时换成带「两端已裁切」的那句,跟两端的渐隐带互为解释 —— 只有渐隐、没有
    /// 这句话的话,用户可能读成"边上暗一点是设计如此"。
    private func caption(stageWidth: CGFloat) -> some View {
        let overflowing = Self.isOverflowing(cardWidth: windowWidth, stageWidth: stageWidth)
        // 常态不写字(2026-08-30 用户要求去掉「实际大小」):宽度数值就在调整条上,
        // "这是预览"也不必再说一遍 —— 一块画着桌面壁纸和歌词的方框,没人会以为是别的东西。
        // 只保留**真正带信息**的那一句:窗口比舞台宽、两端确实没画全时才提示。
        return Text(overflowing ? L10n.t("两端已裁切") : "")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
