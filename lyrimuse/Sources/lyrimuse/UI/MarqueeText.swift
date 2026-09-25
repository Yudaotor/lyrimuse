import LyrimuseCore
import OSLog
import SwiftUI

// 超长文字(歌名/歌词)靠自动滚动展示全部内容,而不是硬截断/省略号。测量内容真实宽度
// vs 容器宽度,只有真的溢出容器时才滚动,没溢出的短文字保持静止不动、不产生任何动画。
//
// 一轮是"停在开头→匀速滚到底→停在末尾→**瞬时**回到开头",不是无限单向卷动,不需要为了
// 卷动无缝衔接去复制一份内容拼接。回到开头这一步刻意不做补间 —— 那不只是观感取舍,
// 是换句时不出错的前提,理由写在 restart() 和滚动循环里那两段。
//
// id 参数控制"什么时候该重新测量、重新从头开始滚动"——歌词行内部逐字变色(由外面
// TimelineView 驱动)不应该打断/重置正在进行的滚动,那只是同一句歌词内部的高亮进度
// 在变,不是这一行内容本身换了;只有真的换了一句歌词、换了一首歌才应该重新开始。
// Swift 不支持泛型类型里放 static stored property,这两个纯常量挪到文件作用域。
let marqueePixelsPerSecond: Double = 24
let marqueeHoldDuration: Double = 1.1
/// 跟唱动画与播放位置之间允许偏差这么多(点)。超了就从此刻重新起一条动画:那是 seek /
/// 重新对锚点 / 播放速率不是 1,不是正常误差。
/// 跟上面两个常量同因放在文件作用域:泛型类型里放不了 static stored property。
let marqueeFollowResyncTolerance: CGFloat = 8
/// 跟唱对表的间隔(纳秒)。只做比对,不写状态;没偏差时这个循环什么都不改。
let marqueeFollowCheckInterval: UInt64 = 250_000_000
/// 跟唱时钟瞬时归位之后、发动画之前等这么久(纳秒),保证归位那一帧先提交。
/// 归位和动画不能落在同一次 SwiftUI 更新里:否则归位会被吞掉,动画从旧值(上一句的末尾)起跑。
let marqueeFollowSnapSettle: UInt64 = 34_000_000

/// 跟唱滚动的诊断。每建一条路径打一行(换句 / 换宽度 / 换字体时),不按帧打。
let marqueeLogger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "marquee")

/// 跟唱滚动的输入。非 nil 且这一句确实溢出时,偏移改由**播放位置**决定,上面那套
/// 「首停到匀速到尾停到循环」的时间配速不启动。
///
/// 两种配速按句切换、同一句不混,跟菜单栏同一条规则(06 章「滚动规则」):这一句有逐字
/// 时间轴就跟唱,没有(纯 LRC 的源)就退回时间配速。数学直接复用菜单栏那两个纯函数
/// (`MenuBarMarquee.followReadingPath` / `followScrollPath`),这里只负责驱动。
struct MarqueeFollow: Equatable {
    /// 这一句的逐字时间轴。
    let words: [SyncedLyricWord]
    /// 每个词**单独**排版的点宽。不是前缀宽 —— 灵动岛这一行是 `HStack(spacing: 0)` 里
    /// 每词一个独立 `Text`,理由见 `MarqueeMath.cumulativeWordEndXs`。
    let wordWidths: [CGFloat]
    /// 这一帧的播放位置(毫秒,含歌词时间轴偏移)。按帧调用,内部直读协调器。
    let nowMs: (Date) -> Int
    /// 这一帧要不要停表(暂停 / 这一层藏着),语义同 `TimelineView` 的 paused。
    let paused: Bool

    /// 闭包不参与相等性 —— 它每次 body 求值都是新实例,进了判据会让"内容没变"永远不成立。
    /// 路径只由 words 和宽度决定,这两项相等就不用重算。
    static func == (a: MarqueeFollow, b: MarqueeFollow) -> Bool {
        a.words == b.words && a.wordWidths == b.wordWidths && a.paused == b.paused
    }
}

struct MarqueeText<Content: View>: View {
    let id: AnyHashable
    /// **没溢出时**内容靠容器哪一边。溢出时一律 .leading,不受这个参数影响 —— 滚动是
    /// "从头开始往左推",内容比容器宽时靠右摆等于一上来就把开头几个字挂在容器外面。
    ///
    /// 跑马灯的 GeometryReader 会占满可用宽度,默认值若是 .trailing,短名字(绝大多数
    /// 情况)会从右边跳到左边、跟音浪之间空出一大段。默认值保持 .leading,已有调用点行为
    /// 不变。
    var restingAlignment: Alignment = .leading
    /// 内容溢出、而且此刻**停在开头**时,右端渐隐带的宽度(0 = 不渐隐,默认)。
    ///
    /// 为什么需要它、为什么只在"停在开头"时给、为什么传宽度而不是
    /// gradient 的 stop —— 三条理由都写在 `MarqueeMath.trailingFadeWidth` 上,不重复。
    /// 目前只有灵动岛的**歌词行**传非 0:那一行右边紧挨一枚 32pt 封面,只隔 10pt,硬切口
    /// 落在那里肉眼分不清"被裁掉"和"被封面盖住"。顶行的歌名/歌手同样是硬切,但它们旁边
    /// 是刘海/音浪而不是封面,没有同样的误读风险,保持原样(要开就在调用点传值即可)。
    var edgeFadeWidth: CGFloat = 0
    /// 非 nil = 这一句跟着唱到哪滚到哪(见 `MarqueeFollow`)。
    var follow: MarqueeFollow? = nil
    /// 时间配速滚到底之后要不要回到开头再来一遍。true(默认)= 循环,给常驻的标签用(歌名 / 歌手);
    /// false = 滚一遍就停在末尾,直到 `id` 变(换句)才归零,给歌词行用 —— 那一句还没换走时回到开头
    /// 等于把刚读完的结尾又藏起来。跟唱配速本来就停在末尾,不受它影响。
    var loops: Bool = true
    @ViewBuilder let content: () -> Content

    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    /// 跟唱滚动的偏移路径(时间到偏移的折线)。空 = 这一句不跟唱(没逐字 / 装得下 / 还没量到宽度)。
    /// 只在 words 或两个宽度变化时重算,不按帧算。
    @State private var followPath: [MenuBarMarquee.KaraokeFillPoint] = []
    /// 跟唱模式下"此刻还停在开头"。只给右端渐隐带用,由一个定时 Task 在越过锚点那一刻翻一次,
    /// **不按帧写** —— 渐隐带只有 0 和非 0 两种状态,为它每帧写一次 @State 不划算。
    @State private var followAtStart: Bool = true
    @State private var followFadeTask: Task<Void, Never>?
    /// 跟唱的时钟(毫秒,同 `MarqueeFollow.nowMs`)。一条线性动画把它推过文字真正在动的那一段,
    /// 偏移由 `MarqueeFollowOffset` 按路径逐帧现算。跟唱模式下 `offset` 恒为 0。
    @State private var followClockMs: Double = 0
    /// 跟唱的驱动:起动画 + 低频对表,不按帧写。
    @State private var followTask: Task<Void, Never>?
    /// 最近一次**内容宽度**是给哪一份内容量的。
    ///
    /// 换句那一拍 `id` 的 onChange 先跑,而内层 GeometryReader 还没量到新内容 ——
    /// 此时 `contentWidth` 仍是**上一句**的。跟唱路径的 maxOffset 与归一基准都由它算,
    /// 拿旧宽度建出来的路径边界是错的(真机实测偏差到 ±107pt:本句真实 maxOffset 21.5、
    /// 却按 127 建),而驱动会立刻按它起跑,直到新宽度到达才纠正 —— 表现就是滚动范围不对、
    /// 末尾的词露不全。所以建路径前必须确认"这个宽度是当前这份内容的"。
    @State private var measuredID: AnyHashable?
    /// 每次重新开始滚动就 +1。它本身不参与画面,只为了让归零那次赋值**一定**是一次真的
    /// 状态变化 —— 详见 restart() 里那段。
    @State private var generation: Int = 0
    @State private var scrollTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { outerProxy in
            positioned(in: outerProxy)
                // 垂直居中——GeometryReader 默认把内容摆在自己左上角,不居中的话文字
                // 会紧贴着这一整行的顶边。横向见 restingAlignment。
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: isOverflowing ? .leading : restingAlignment)
                // 容器变宽变窄(用户拖灵动岛/悬浮窗的宽度滑块)同样要重算,不然原来溢出的
                // 内容拖宽之后还在滚、或者反过来拖窄了不滚。
                .onChange(of: outerProxy.size.width) { _, w in
                    apply(content: contentWidth, container: w)
                }
                .onChange(of: id) {
                    // 换了一句歌词/一首歌:即使新内容宽度碰巧跟旧的一模一样(apply 会因此
                    // 跳过),滚动位置也必须回到起点重新开始。
                    restart()
                }
                // 同一句里逐字时间轴迟到 / 词宽重新量到(字体换了)也要重建路径。
                .onChange(of: follow) { _, _ in
                    rebuildFollowPath()
                    // 只有 paused 翻转时路径不变、rebuildFollowPath 会提前返回,
                    // 驱动得在这里单独再起(暂停要停表、恢复要按新位置接着跑)。
                    runFollowDriver()
                }
        }
        .clipped()
        // 无条件挂,不写成 `if fadeWidth > 0 { .mask(...) }`:那样渐隐带宽度归零的
        // 那一刻视图身份会变、整棵子树重建,正在跑的滚动动画会被打断。宽度为 0 时
        // gradient 那一段本身就是零宽,等效于没有 mask。
        .mask(fadeMask)
        .onDisappear {
            scrollTask?.cancel()
            followFadeTask?.cancel()
            followTask?.cancel()
        }
    }

    /// 跟唱模式在跑吗。路径为空就退回时间配速 —— 没有逐字时间轴、这一句装得下、
    /// 或者宽度还没量到,三种情况都会让路径是空的。
    private var followActive: Bool { follow != nil && !followPath.isEmpty }

    /// 量好宽度、并且按当前配速摆好位置的内容。两条配速在这里分叉。
    @ViewBuilder
    private func positioned(in outerProxy: GeometryProxy) -> some View {
        let measured = content()
            .fixedSize(horizontal: true, vertical: false)
                // 这里**不能**用 PreferenceKey 把宽度传上去,尽管那是最常见的写法(本文件
                // 之前正是那么写的,而且是个静默失效的真 bug)。
                //
                // 实测:GeometryReader 自己测得完全正确(打印 innerProxy.size.width = 428.5),
                // 但外面 .onPreferenceChange 收到的是 PreferenceKey 的 defaultValue 0,
                // **而且之后再也不会收到第二次** —— 于是 distance 恒为负,guard 直接 return,
                // 跑马灯永远不滚,超长内容被 .clipped() 硬裁掉。
                //
                // 触发条件很刁钻,这也是它藏了这么久的原因:content 是**单个 Text** 时,首次
                // 布局就有固有宽度,preference 第一次发布就是真值,一切正常;而 content 是
                // `HStack { ForEach { ... } }`(灵动岛的**逐字歌词**行就是这个形状,外面还套
                // 着 TimelineView)时,首次发布的是 0,后续的正确宽度再也没传上来。表现就是
                // "普通歌词会滚、逐字歌词不滚",而逐字歌词恰恰是这个 App 最主要的展示形态。
                //
                // 改成直接在 GeometryReader 里回写 @State,不经过 preference 那条链路。
                .background(
                    GeometryReader { innerProxy in
                        Color.clear
                            .onAppear {
                                noteContentMeasured(innerProxy.size.width, container: outerProxy.size.width)
                            }
                            .onChange(of: innerProxy.size.width) { _, w in
                                noteContentMeasured(w, container: outerProxy.size.width)
                            }
                    }
                )

        // 时间配速写 `offset`(restart() 里那个循环);跟唱写 `followClockMs`,偏移由
        // `MarqueeFollowOffset` 按路径现算(runFollowDriver())。两者任一时刻只有一个非零。
        //
        // 这里刻意**没有** TimelineView。别把偏移挂到逐字染色那档 30Hz 的时钟上每帧现算:
        // 横向平移 30 帧肉眼可见地顿,而且闭包每帧重建一次 measured(逐字 HStack + 量宽
        // GeometryReader)。也别按词逐段发 `withAnimation` 再 `Task.sleep` 接力:段与段交界处
        // 会停帧或两条线性动画叠着跑。一句只发一条动画,见 05 章决策 #38。
        measured
            // 把内容子树从动画事务里摘出去。`withAnimation` 的作用域是**整次 SwiftUI 更新**,
            // 不只是括号里那一句 —— 滚动每段发一条 `.linear`,窗口几乎一直开着,这一行内部任何
            // 一次布局变化(字形回退晚解析、逐字视图重排导致某个词宽差一丝、内容换了)只要落进
            // 同一次更新,就会被那条动画接管:本该瞬时归位的东西变成**滑过去**,看上去就是
            // 「一个词脱离原位漂移」。词越多、段越密,撞上的概率越高,所以长句最明显。
            //
            // 这跟 `NotchLyricsView` 里那条治「封面遮挡歌词」的 `.animation(nil, value:)` 是
            // 同一类问题的同一个解,只是那条按单个判据挡、这里把整个子树一次挡掉 —— 跑马灯的
            // 内容本来就只该靠下面这个 offset 移动,内部不需要任何补间。
            .transaction { $0.animation = nil }
            .offset(x: -offset)
            .modifier(MarqueeFollowOffset(ms: followClockMs, path: followActive ? followPath : []))
            // 归零那一下必须**瞬时**,不能被任何补间接管(理由见 restart())。
            //
            // generation 每次 restart 都会变,这条修饰符就在那一刻把 offset 的变化钉成
            // "不补间";平时滚动的那两次 withAnimation 不碰 generation,不受它影响。
            //
            // 顺带一件要紧的事:generation 必须像这样**被 body 真的读到**。@State 的
            // 失效是按依赖追踪的 —— body 里没读的 @State 改了也不会触发重新求值,
            // 那样 restart() 里那次"关掉动画的归零"就等于没发生。
            .animation(nil, value: generation)
    }

    /// 内容比容器宽出多少(负数=装得下)。判据本体在 Core(MarqueeMath),这里只转发 ——
    /// 分层边界的理由见 AGENTS.md「XxxxView.swift 里不放几何/数学」。
    private var overflow: CGFloat {
        MarqueeMath.overflow(contentWidth: contentWidth, containerWidth: containerWidth)
    }

    /// 值得滚吗。restart() 的启动判据和下面的对齐判据必须是同一份 —— 两处各写一遍就会
    /// 出现"在滚但按没溢出对齐"这种自相矛盾的状态。
    private var isOverflowing: Bool {
        MarqueeMath.isOverflowing(contentWidth: contentWidth, containerWidth: containerWidth)
    }

    /// 右端渐隐带当前宽度。offset 是**模型值**,这正是想要的:归零走
    /// `disablesAnimations` 的事务(渐隐带瞬时出现,跟文字瞬时归位同步),起步走
    /// `withAnimation(.linear)`(渐隐带跟着平滑收掉)。
    ///
    /// 跟唱模式下 offset 恒为 0(偏移由 `MarqueeFollowOffset` 现算),这里改喂 `followAtStart`:渐隐带只有
    /// "0 / 非 0"两种状态,为它每帧写一次 @State 不划算,所以由 `scheduleFollowFade()` 在
    /// 越过锚点那一刻翻一次。判据本体仍是同一个 `trailingFadeWidth`,两条路口径一致。
    private var fadeWidth: CGFloat {
        MarqueeMath.trailingFadeWidth(configured: edgeFadeWidth,
                                      contentWidth: contentWidth,
                                      containerWidth: containerWidth,
                                      offset: followActive ? (followAtStart ? 0 : 1) : offset)
    }

    /// 遮罩:左边一整块不透明 + 右端一条 black→clear 的渐隐带。渐隐带是 `.frame(width:)`
    /// 而不是 gradient 的 stop 位置,这样宽度变化可动画(理由见 MarqueeMath)。
    private var fadeMask: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color.black)
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: fadeWidth)
        }
    }

    /// 内层 GeometryReader 量到了**当前这份内容**的宽度。
    ///
    /// 只有这条路径能给 `measuredID` 盖章 —— 外层容器宽度变化那条 onChange 传的是缓存的
    /// `contentWidth`,不是新测量,盖章会让上面那道闸形同虚设。盖章放在 apply 的提前返回
    /// **之前**:新内容宽度恰好跟旧的一样时 apply 会跳过,但那一份仍然是量过的。
    private func noteContentMeasured(_ width: CGFloat, container: CGFloat) {
        if measuredID != id { measuredID = id }
        apply(content: width, container: container)
    }

    private func apply(content: CGFloat, container: CGFloat) {
        guard content != contentWidth || container != containerWidth else { return }
        let contentChanged = content != contentWidth
        let wasOverflowing = isOverflowing
        // offset 是模型值:静止在开头时恒为 0,去程一发出就是 distance、到尾端 hold 期间也是
        // distance(回程归零是瞬时的,见 restart 里那段)—— 所以 `offset != 0` 就是"有一轮滚动
        // 正在进行或停在尾端"。
        let midScroll = offset != 0
        contentWidth = content
        containerWidth = container
        // 只有容器宽度在变、内容没换、溢出与否也没翻转、而且此刻停在开头时,**不**重启
        // (灵动岛动画性能专项)。容器宽度在 hover 展开/收起、拖宽度滑块期间是
        // **每帧**变一次的(灵动岛 257→482pt 一次展开约 16 帧、收起约 24 帧),原来每帧都
        // 走一遍 restart:cancel 掉旧 Task、新分配一个、再在事务里写两次 @State —— 对没溢出
        // 的短句(绝大多数歌词行 / 耳朵里的歌名)这全是白做,对正溢出、还在 1.1s 起步等待里
        // 的长句也只是把等待重新计时;两种情况画面上都看不出任何区别,却让每帧多一轮
        // 视图图更新。跳过之后滚动循环读的是**当下**的 overflow(见下面 Task 里的注释),
        // 等待期间容器变宽变窄,起步时照样按新距离滚。
        //
        // 溢出与否翻转(拖宽了装得下 / 拖窄了装不下)、正在滚动中(去程的终点跟着容器宽变了)、
        // 内容换了,三种情况照旧重启 —— 这三种才是"需要从头来"的。
        // 跟唱路径的 maxOffset 是 `contentWidth − containerWidth`,两个宽度任意一个变了就得重算 ——
        // 这一句放在上面那条"不重启"的捷径**之前**:那条捷径的理由是"时间配速在等待期间重启是白做",
        // 而跟唱模式下容器变宽变窄会真的改变该滚到哪,漏了它 hover 展开/收起之后整句都按旧宽度滚。
        rebuildFollowPath()
        if !contentChanged, wasOverflowing == isOverflowing, !midScroll { return }
        restart()
    }

    /// 重算跟唱的偏移路径。只在 words / 两个宽度变化时调用,不按帧调。
    private func rebuildFollowPath() {
        // 宽度还不是这一份内容的(换句那一拍)就先不建 —— 见 measuredID 的注释。
        // 新宽度一到 noteContentMeasured 会再叫一次。
        guard measuredID == id else { return }
        guard let follow, !follow.words.isEmpty, isOverflowing else {
            if !followPath.isEmpty { followPath = [] }
            followFadeTask?.cancel()
            followFadeTask = nil
            followTask?.cancel()
            followTask = nil
            return
        }
        // 逐词宽度到累计宽度,再按实测总宽归一(灵动岛是每词一个独立 Text,理由见那个函数)。
        let ends = MarqueeMath.cumulativeWordEndXs(wordWidths: follow.wordWidths,
                                                   measuredTotal: contentWidth)
        let reading = MenuBarMarquee.followReadingPath(words: follow.words, wordEndXs: ends)
        let path = MenuBarMarquee.followScrollPath(reading: reading,
                                                   windowWidth: containerWidth,
                                                   textWidth: contentWidth)
        guard path != followPath else { return }
        // 两个宽度来源的对账。`contentWidth` 是 SwiftUI 内层 GeometryReader 量的真实排版宽度,
        // `nsSum` 是逐词用 NSFont 测出来的和 —— cumulativeWordEndXs 按前者归一。两者差得多
        // 就说明归一的基准本身可疑(逐字那一行是 HStack 套 TimelineView,这个形状在本文件里
        // 有过量宽失效的前科),表现就是滚动提前停住、末尾露不全。
        let nsSum = follow.wordWidths.reduce(0, +)
        marqueeLogger.notice("""
            follow path: words=\(follow.words.count, privacy: .public)             contentW=\(Double(self.contentWidth), format: .fixed(precision: 2))             nsSum=\(Double(nsSum), format: .fixed(precision: 2))             delta=\(Double(self.contentWidth - nsSum), format: .fixed(precision: 2))             containerW=\(Double(self.containerWidth), format: .fixed(precision: 2))             maxOffset=\(Double(self.contentWidth - self.containerWidth), format: .fixed(precision: 2))             lastEnd=\(Double(ends.last ?? -1), format: .fixed(precision: 2))             pathLastX=\(Double(path.last?.x ?? -1), format: .fixed(precision: 2))             fadeCfg=\(Double(self.edgeFadeWidth), format: .fixed(precision: 2))
            """)
        followPath = path
        scheduleFollowFade(path: path)
        runFollowDriver()
    }

    /// 跟唱的驱动:一条 `withAnimation(.linear)` 把 `followClockMs` 推过文字真正在动的那一段,
    /// 之后只按 `marqueeFollowCheckInterval` 对表,偏差超过 `marqueeFollowResyncTolerance`
    /// 才从此刻重起一条。跟菜单栏把剩余路径交给一条 `CAKeyframeAnimation` 同一个做法。
    private func runFollowDriver() {
        followTask?.cancel()
        followTask = nil
        guard followActive, let follow else { return }
        // 两套配速不能同时写偏移。换句那一拍路径还没建好(宽度没到),restart() 会先起
        // 时间配速那条循环;等路径建好、跟唱接手时必须把它收掉,否则首停结束后两条一起动。
        scrollTask?.cancel()
        scrollTask = nil
        if offset != 0 {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { offset = 0 }
        }
        // 暂停:停在此刻该在的位置,不补间(补间会在暂停那一下再滑一小段)。
        guard !follow.paused else {
            snapFollowClock(toMs: follow.nowMs(Date()))
            return
        }
        // 动画只覆盖文字真正在动的那一段(`followMotionSpan`):之前(还没唱到锚点)时钟停在起动那一刻,
        // 之后(已经滚到底)停在终点。平台期里挂着一条动画,渲染会按屏幕刷新率白跑。
        followTask = Task { @MainActor in
            // 当前这条动画的起点(毫秒)与起跑时刻;nil = 没有动画在跑。
            var run: (ms: Int, at: Date)?
            // 时钟已在上一轮停在运动起点上、那一帧已提交:从这里起动画不用再等 settle。
            var parkedAtStart = false
            while !Task.isCancelled {
                let path = followPath
                guard let span = MenuBarMarquee.followMotionSpan(path: path) else { return }
                let now = Date()
                let nowMs = follow.nowMs(now)
                if let current = run {
                    let clockMs = min(span.endMs, current.ms + Int(now.timeIntervalSince(current.at) * 1000))
                    let drift = abs(MenuBarMarquee.karaokeFillX(atMs: nowMs, path: path)
                                    - MenuBarMarquee.karaokeFillX(atMs: clockMs, path: path))
                    if drift <= marqueeFollowResyncTolerance {
                        if clockMs >= span.endMs { return }
                        try? await Task.sleep(nanoseconds: marqueeFollowCheckInterval)
                        continue
                    }
                    run = nil
                    parkedAtStart = false
                }
                guard nowMs < span.endMs else {
                    snapFollowClock(toMs: span.endMs)
                    return
                }
                if nowMs < span.startMs {
                    snapFollowClock(toMs: span.startMs)
                    parkedAtStart = true
                    // 分段睡:等待期间 seek 了要能在一个对表间隔内发现。至少睡一个 settle,
                    // 保证停靠那一帧先于后面的动画提交。
                    let waitNs = UInt64(span.startMs - nowMs) * 1_000_000
                    try? await Task.sleep(nanoseconds: max(min(waitNs, marqueeFollowCheckInterval),
                                                           marqueeFollowSnapSettle))
                    continue
                }
                if !parkedAtStart {
                    snapFollowClock(toMs: nowMs)
                    try? await Task.sleep(nanoseconds: marqueeFollowSnapSettle)
                    if Task.isCancelled { return }
                }
                let startMs = follow.nowMs(Date())
                guard startMs < span.endMs else {
                    snapFollowClock(toMs: span.endMs)
                    return
                }
                // 屏幕上的起点是停靠 / 归位时的值,时长按此刻的真实剩余算:起跑时最多落后一个
                // settle,线性收敛到终点时为 0,落在 resync 容差以内。
                withAnimation(.linear(duration: Double(span.endMs - startMs) / 1000)) {
                    followClockMs = Double(span.endMs)
                }
                run = (startMs, Date())
                parkedAtStart = false
                try? await Task.sleep(nanoseconds: marqueeFollowCheckInterval)
            }
        }
    }

    /// 瞬时把跟唱时钟落到某一刻(同时打断正在跑的那条动画)。
    private func snapFollowClock(toMs ms: Int) {
        let value = Double(ms)
        guard value != followClockMs else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { followClockMs = value }
    }

    /// 右端渐隐带的那一次翻转:路径上偏移第一次离开 0 的时刻 = 阅读位置越过锚点、文字开始动。
    /// 在那之前文字静止在开头、末端硬切在封面旁边,正是需要渐隐带的那个状态。
    private func scheduleFollowFade(path: [MenuBarMarquee.KaraokeFillPoint]) {
        followFadeTask?.cancel()
        followFadeTask = nil
        guard let follow else { return }
        followAtStart = true
        guard let moveMs = path.first(where: { $0.x > 0 })?.ms else { return }
        followFadeTask = Task { @MainActor in
            while !Task.isCancelled {
                let remain = moveMs - follow.nowMs(Date())
                if remain <= 0 {
                    followAtStart = false
                    return
                }
                // 暂停时 nowMs 不前进,这个循环就在这儿慢慢空转 —— 200ms 一档够跟手,
                // 又不至于变成第二个每帧时钟。
                try? await Task.sleep(nanoseconds: UInt64(min(remain, 200)) * 1_000_000)
            }
        }
    }

    private func restart() {
        scrollTask?.cancel()
        scrollTask = nil
        rebuildFollowPath()
        // 归零必须在**关掉动画的事务**里做,而且要保证这次赋值真的是一次状态变化。
        //
        // 现象是的两个症状("换句时文字从右边滑回开头"、"有时候慢慢滚回到
        // 对应的位置")是同一个根因:`Task.cancel()` 停得掉下面那个 while 循环,却停不掉
        // **已经发出去的那条 SwiftUI 动画**。
        //
        // 回程那半段是 `withAnimation { offset = 0 }` —— 动画一发出,模型值当场就是 0 了,
        // 而屏幕上的文字还要滑 travelDuration 秒才回到位。若正好在这段时间里换句,
        // 老写法这里再写一次 `offset = 0` 属于"赋同一个值",SwiftUI 不会重新求值、更不会
        // 重新定向,那条回程动画于是继续跑 —— 把**新一句**的文字从半路慢慢挪回来。
        // 换句发生在去程途中则是另一半症状:从 distance 一路滑回 0。
        //
        // generation 就是为了破掉"赋同一个值"这件事:它每次都变,这次更新一定会发生,
        // 而 disablesAnimations 保证它是瞬时的。
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            offset = 0
            generation &+= 1
        }
        guard isOverflowing else { return }
        // 跟唱这一句不起时间配速的循环 —— 两套同时跑会各写各的 offset。哪一套生效由
        // followActive 一处决定(路径空就退回时间配速),判据不许在这里再写第二份。
        guard !followActive else { return }
        scrollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(marqueeHoldDuration * 1_000_000_000))
                if Task.isCancelled { return }
                // 距离在**起步这一刻**读,不在 restart 时捕获:apply 对"等待期间
                // 容器宽度在变"的情况不再重启,这里读到的才是当下真实的溢出量。@State 是引用
                // 存储,struct 副本里读到的就是最新值。等待期间若已经装得下(overflow ≤ 0),
                // apply 那边会因溢出翻转而重启并取消本 Task,不会走到这里。
                let distance = overflow
                guard distance > 0 else { return }  // 防御:翻转与取消之间的窄窗口
                let travelDuration = Double(distance) / marqueePixelsPerSecond
                withAnimation(.linear(duration: travelDuration)) { offset = distance }
                // 不循环:停在末尾。归零交给换句时的 restart()(模型值此时是 distance,那次归零仍是
                // 一次真实的值变化,下面那段"回程必须瞬时"的前提不受影响)。
                guard loops else { return }
                try? await Task.sleep(nanoseconds: UInt64(travelDuration * 1_000_000_000) + UInt64(marqueeHoldDuration * 1_000_000_000))
                if Task.isCancelled { return }
                // 回程是**瞬时**的,不是滑回去 —— 这一条不是审美选择,是正确性要求。
                //
                // 实测(灵动岛换句瞬间连拍):老写法这里是
                // `withAnimation(.linear(duration: travelDuration)) { offset = 0 }`,
                // 动画一发出,**模型值当场就是 0**,而屏幕上的文字还要滑好几秒才回到位。
                // 若在这段时间里换句,restart() 里那次归零就是"赋同一个值" —— `.offset`
                // 的可动画数据没有变化,SwiftUI 没有任何理由去重新定向那条已经在跑的动画,
                // 于是它继续把**新一句**的文字从半路慢慢挪回来。抓到的帧里,新一句在换句
                // 后 0.17 秒仍缺着开头几个字,再过 0.4 秒才右移约 9.6pt(正好是
                // marqueePixelsPerSecond × 0.4)。只在归零时关掉动画治不了它 ——
                // 因为压根没触发那次更新。
                //
                // 改成瞬时归位之后,模型值只可能是两种:有动画在跑时是 distance、静止时是 0。
                // 于是换句归零必定是一次**真实**的值变化,老动画一定会被顶掉。
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { offset = 0 }
                try? await Task.sleep(nanoseconds: UInt64(marqueeHoldDuration * 1_000_000_000))
            }
        }
    }
}

/// 跟唱偏移:动画的是播放时钟(`ms`),偏移按路径现算。`GeometryEffect` 只在渲染阶段逐帧取值,
/// 不重跑 body、不触发布局,一句一条线性动画就能连续走完整条折线。空路径 = 不偏移。
private struct MarqueeFollowOffset: GeometryEffect {
    var ms: Double
    let path: [MenuBarMarquee.KaraokeFillPoint]

    var animatableData: Double {
        get { ms }
        set { ms = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        guard !path.isEmpty else { return ProjectionTransform() }
        let x = MenuBarMarquee.karaokeFillX(atMs: Int(ms.rounded()), path: path)
        return ProjectionTransform(CGAffineTransform(translationX: -x, y: 0))
    }
}
