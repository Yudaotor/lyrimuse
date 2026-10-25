import AppKit
import SwiftUI
import Combine
import LyrimuseCore
import os

/// 展开卡里的进度条 + 时间行,独立子视图,两件事:
/// ① 拖动的三个交互状态(@GestureState/测宽/悬停)在这里自持:挂在 NotchLyricsView 根上的话,拖动时每个指针事件(60~120Hz)都
///    整卡重估,实际要变的只有这十来个视图;
/// ② 逐帧时钟是 `FrameTimeline`(30Hz 上限,同其余逐字填色口径),只包住已播段和两个时间数字;中间那组歌词偏移按钮不在时钟里,
///    只随父视图更新(05 章决策 62)。
///
/// 两种数据来源,跟「歌词窗口」的 progressSection 同一套三态口径:
///  - 播放中:anchor 在,按帧从锚点外推;
///  - 暂停:anchor 被清成 nil(见 PlaybackCoordinator.pausedPositionMs 的注释),改用冻结位置 + 曲目时长照常显示,时钟不走。
/// 暂停这一档不能省:没有它一暂停整条进度条凭空消失,展开区也失去撑宽度的内容(「暂停时下一句歌词跑到中间」,见 expandedContent
/// 末尾注释)。
struct NotchScrubber: View {
    let anchor: ProgressAnchor?
    let pausedPositionMs: Int?
    let durationMs: Int?
    let isPlayingNow: Bool
    /// 能不能拖(`PlaybackCoordinator.acceptsSeek`)。由父视图算好传进来,广告开始、结束那一拍这里跟着重算。
    let seekable: Bool
    let tint: Color
    /// 「歌词时间轴微调」(菜单栏面板同款功能的灵动岛入口)要不要塞进时间行
    /// 中间——三项都是纯渲染参数,理由见 `NotchPlayback.showsLyricsOffsetControls` 上面
    /// 那条注释(不影响卡片几何,不走 `NotchChromeSource`)。
    let showsLyricsOffsetControls: Bool
    let trackLyricsOffsetMs: Int
    let lyricsOffsetStepMs: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 所在的展开区此刻是不是可见的(NotchLyricsView.cardBodyLayer):展开区常驻、稳态下藏着,藏着时停表。
    @Environment(\.notchCardLayerActive) private var cardLayerActive

    // 正在拖进度条时手指所在的比例(0~1);没在拖就是 nil。
    // 用 @GestureState:手势被取消时(拖动中这块条件分支被摘掉)自动复位,@State 会永久卡住。
    @GestureState private var scrubbingFraction: Double?
    // 进度条那一块的实际宽度,拖拽换算比例用。
    @State private var scrubWidth: CGFloat = 0
    /// 光标是否停在进度条那一小条上(只影响它自己的粗细,跟卡片展开无关)。
    @State private var hoveringScrubber = false

    var body: some View {
        let fingerFraction = scrubbingFraction
        if let anchor, anchor.durationMs > 0 {
            // 拖动期间显示手指按住的位置,而不是外推出的真实位置——否则进度条会在
            // 手指底下被时钟每帧拉回去。松手才真的发 seek。
            scrubberAndTimes(durationMs: anchor.durationMs, ticking: isPlayingNow && cardLayerActive) { now in
                fingerFraction.map { Int($0 * Double(anchor.durationMs)) } ?? anchor.extrapolatedPositionMs(now: now)
            }
        } else if let paused = pausedPositionMs,
                  let duration = durationMs, duration > 0 {
            // 暂停态位置是冻住的,时钟不走。
            scrubberAndTimes(durationMs: duration, ticking: false) { _ in
                fingerFraction.map { Int($0 * Double(duration)) } ?? paused
            }
        }
    }

    /// 进度条本体 + 下面那行时间。播放态和暂停态共用,只是位置的来源不同;`ticking` 为 false 时时钟停着。
    private func scrubberAndTimes(durationMs: Int, ticking: Bool,
                                  positionMs: @escaping (Date) -> Int) -> some View {
        VStack(spacing: 3) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.18))
                    // 满宽填充往左移出、外面按满宽胶囊裁一次:随进度变的只有 offset(不参与布局),别写回
                    // `.frame(width:)` —— 那样每帧都要重新布局。几何同歌词窗口那条,见 ProgressFillGeometry。
                    FrameTimeline(minimumInterval: WordKaraokeGradient.refreshInterval, paused: !ticking) { now in
                        Capsule().fill(tint.opacity(0.85))
                            .offset(x: -ProgressFillGeometry.leadingOffset(
                                containerWidth: proxy.size.width,
                                fraction: CGFloat(Double(positionMs(now)) / Double(durationMs))))
                    }
                    .clipShape(Capsule())
                }
                // 变粗只发生在下面那个**恒定高度的槽**里(垂直居中),布局上不占多一分 ——
                // 别让 .frame(height: scrubberHeight) 直接参与布局:悬停 3→5 那 2pt 会把
                // 时间行和三键整块往下推一下。
                .frame(height: scrubberHeight)
                .frame(maxHeight: .infinity)
                // reduceMotion 下仍然变粗(那是功能反馈,不是装饰),只是不补间。
                .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.7),
                           value: scrubberHeight)
            }
            // 布局槽恒为最粗形态(拖动中的 6pt)的高度,悬停/拖动只改槽内的条,不动邻居。
            .frame(height: 6)
            // 命中区只覆盖进度条这一行,不含下面的时间行:挂在整块上的话,
            // 点右侧"剩余时间"文字就等于 seek 到 ~94%(把这首歌跳过去)。
            // 上下各撑 8pt 让 3pt 的条好按,再用等量负 padding 抵消布局:
            // 展开区高度是写死的 expandedExtraHeight(alignment .top),
            // 长高一点就把时间行裁掉。
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .padding(.vertical, -8)
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { scrubWidth = g.size.width }
                        .onChange(of: g.size.width) { _, w in scrubWidth = w }
                }
            )
            .onHover { hoveringScrubber = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($scrubbingFraction) { value, state, _ in
                        guard scrubWidth > 0 else { return }
                        // state 只有**这次手势的第一帧**才是 nil(@GestureState
                        // 的初始值),拿它当"刚按下"的边沿信号给一次触觉 ——
                        // 放 onChanged 里会每帧都震。
                        if state == nil {
                            NSHapticFeedbackManager.defaultPerformer.perform(
                                .alignment, performanceTime: .now)
                        }
                        state = min(1, max(0, value.location.x / scrubWidth))
                    }
                    .onEnded { value in
                        guard scrubWidth > 0 else { return }
                        let f = min(1, max(0, value.location.x / scrubWidth))
                        PlaybackCoordinator.shared.seek(toMs: Int(f * Double(durationMs)))
                    }
            )
            // 播放器不吃外部跳转指令(Amazon Music)、或者在放广告时只显示、不能拖,见 `PlaybackCoordinator.acceptsSeek`。
            .allowsHitTesting(seekable)
            HStack {
                FrameTimeline(minimumInterval: WordKaraokeGradient.refreshInterval, paused: !ticking) { now in
                    Text(Self.timeString(ms: positionMs(now)))
                }
                Spacer()
                // 「歌词时间轴微调」:两个时间数字中间放跟菜单栏面板同一份功能的入口(见 `AppSettings.notchExpandedShowsLyricsOffset`
                // 的注释)。两个 Spacer 各占一半剩余空间,中间那截天然居中;关掉开关时只剩一个 Spacer。
                if showsLyricsOffsetControls {
                    lyricsOffsetControls
                    Spacer()
                }
                FrameTimeline(minimumInterval: WordKaraokeGradient.refreshInterval, paused: !ticking) { now in
                    Text("-" + Self.timeString(ms: max(0, durationMs - positionMs(now))))
                }
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(tint.opacity(0.4))
            .monospacedDigit()
        }
    }

    // MARK: - 歌词时间轴微调(菜单栏面板 `MenuBarPanel.offsetControls` 同款功能)

    /// 「− 歌词±0.5s +」。 按钮尺寸刻意收窄到跟这一行本身的高度(9pt 字号撑出来的行高,
    /// `NotchExpandedMetrics.scrubberBlock` 里"时间行 11"那个常量)齐平,**不能**照抄菜单栏
    /// 面板那份 16×14——那边的行高本来就是被 14pt 的按钮撑出来的(见
    /// `MenuBarPanel.offsetButton` 的注释,那个面板没有这份高度预算的约束);这里按钮比
    /// 这一行本身的高度高,会把整个时间行顶出 `expandedContent` 预留的高度,被
    /// `.frame(alignment: .top)` 从底部裁掉一截。这也是这个开关全程不进
    /// `NotchExpandedMetrics`/`NotchChromeSource` 那套几何链路的前提——按钮必须真的不
    /// 长高这一行,不是"大概率不会",尺寸因此比菜单栏那份小一档。
    private var lyricsOffsetControls: some View {
        HStack(spacing: 3) {
            lyricsOffsetButton("minus", help: nudgeHelp(L10n.t("延后"))) {
                _ = PlaybackCoordinator.shared.nudgeLyricsOffset(by: -lyricsOffsetStepMs)
            }
            offsetReadout
            lyricsOffsetButton("plus", help: nudgeHelp(L10n.t("提前"))) {
                _ = PlaybackCoordinator.shared.nudgeLyricsOffset(by: lyricsOffsetStepMs)
            }
        }
    }

    /// 「歌词 +0.5s」/「歌词 0.0s」——值是**这首歌**那一部分,跟菜单栏面板 `offsetText`
    /// 同一个理由(不含设置里的全局基准,归零操作对应的是这个数字清零)。
    private var offsetText: String {
        "\(L10n.t("歌词")) \(AppSettings.signedSeconds(ms: trackLyricsOffsetMs))s"
    }

    /// 中间那块数值。 **定宽**:数值从「0.0」变到「+10.2」时,两侧的 − / + 不许跟着移位
    /// (「歌词偏移调整之后不要改变 -+ 的位置」)。
    ///
    /// 做法是拿**最宽的那个变体**当隐形垫片撑出宽度、真文案叠在上面居中 —— `.hidden()` 仍然
    /// 参与布局,宽度由垫片说了算。为什么不写死一个 pt 宽度:「歌词」这个前缀是本地化的(en 是
    /// "Lyrics"、繁体是「歌詞」),写死的宽度换个语言就不对;垫片跟真文案共用同一份
    /// `L10n.t("歌词")`,三种语言都自动成立。
    ///
    /// `.monospacedDigit()` 管另一半:等宽数字让「+0.2」→「+0.8」这种同位数变化也不抖。
    /// 偏移**没有上下界**(`LyricsOffsetStore.nudge` 不 clamp),真调到 ±100s 就靠
    /// `minimumScaleFactor` 把字缩一点,而不是把按钮推走 —— 位置稳定优先于字号。
    private var offsetReadout: some View {
        let canReset = trackLyricsOffsetMs != 0
        return HoverReveal { hovering in
            // 垫片必须**独占尺寸**、真文案走 `.overlay`。**写成 ZStack 是错的**:ZStack 的宽度
            // 取最宽的那个子视图,真文案照样能把它撑大 —— 离屏实测(NSHostingView.fittingSize):
            // ZStack 版在两位整数秒时 46 → 51/52pt、「+100.0s」到 58pt,极差 12pt,等于没修;
            // overlay 版七种数值全是 46pt,极差 0.00pt。`minimumScaleFactor` 只在宽度**被约束**
            // 时才介入,而 ZStack 压根没约束它;overlay 的尺寸由父视图说了算、反过来撑不大父视图,
            // 所以约束是真的存在,超长值走缩放而不是推走按钮。
            Text(offsetWidthTemplate)
                .hidden()
                .overlay {
                    Text(offsetText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .monospacedDigit()
                // 这块是可点的(点击归零),所以也该有悬停反馈;底色语言跟两侧的 − / + 同一档
                // (NotchIconButtonStyle 的 hover 也是 0.14)。归零无意义时(值本来就是 0)不亮。
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(tint.opacity(canReset && hovering ? 0.14 : 0))
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    guard canReset else { return }
                    PlaybackCoordinator.shared.resetLyricsOffset()
                }
                .modifier(OptionalHelp(text: canReset ? L10n.t("点按归零") : nil))
        }
    }

    /// 撑宽度用的最宽变体:符号 + **一位**整数 + 一位小数。
    ///
    /// 为什么不预留两位整数(`+10.2s`):那样静止态(`0.0s`)会永久多出 12pt 空隙、− / + 被推得
    /// 离数字明显更远(实测 40pt → 52pt);收成一位只多 6pt(40 → 46)。而歌词偏移调到 ±10 秒
    /// 这首歌的词已经完全对不上了,不值得为这个量级常驻一份空隙。真超过就由
    /// `minimumScaleFactor(0.7)` 把字缩一点(`+10.2s` 需要 50pt/46pt ≈ 0.92,远在 0.7 之内,
    /// 缩了也看不出来),**宽度仍然恒定** —— 位置稳定是硬要求,字号不是。
    /// 这个"缩而不是推"只有在 `offsetReadout` 用 overlay(而不是 ZStack)时才成立,见那边的注释。
    private var offsetWidthTemplate: String {
        "\(L10n.t("歌词")) +2.2s"
    }

    private func nudgeHelp(_ verb: String) -> String {
        "\(verb) \(AppSettings.formattedSeconds(ms: lyricsOffsetStepMs))\(L10n.t("秒"))"
    }

    /// 悬停 / 按下的底色**只能画在 10×11 这个标签尺寸上**。
    /// 这一行的高度是 9pt 字号撑出来的(见 `lyricsOffsetControls` 上面那段),键只要比行高一点,
    /// 就会把时间行顶出 `expandedContent` 预留的高度、被 `.frame(alignment: .top)` 从底部裁掉。
    /// `NotchIconButtonStyle` 正好满足:它的 background 不改布局尺寸,press 的 scaleEffect 只缩
    /// 不放。**别**改成用 padding 把底色撑大 —— 那等于把这颗键的高度交还给布局。
    ///
    /// 负 padding 刻意留在 `HoverReveal` **外面**:壳把 `.onHover` 挂在它收到的那份内容上,而
    /// 那份内容到 `.contentShape(Rectangle())` 为止是**扩过的 20×21**。这样"能按到的范围"和
    /// "会亮的范围"是同一块;把负 padding 挪进去,hover 就缩回 10×11、按得到却不亮。
    private func lyricsOffsetButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        HoverReveal { hovering in
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 7, weight: .semibold))
                    .frame(width: 10, height: 11)
            }
            .buttonStyle(NotchIconButtonStyle(tint: tint, cornerRadius: 3, hovering: hovering))
            // 命中区上下左右各扩 5pt,跟上面进度条命中区同一个技巧:padding 撑开
            // contentShape,再用等量负 padding 抵消对布局尺寸的影响——按钮本身画多小,
            // 手指/鼠标能按到的范围都不因此缩水,但不会把这一行的实际高度撑高。
            .padding(5)
            .contentShape(Rectangle())
        }
        .padding(-5)
        .modifier(OptionalHelp(text: help))
    }

    /// 进度条轨道的粗细:悬停变粗一点、真按住再粗一点。
    ///
    /// 这条轨道稳态只有 3pt,手指压上去几乎看不见自己有没有抓住 —— 它已经为此配了一圈
    /// 上下各 8pt 的隐形命中区(见 gesture 那段注释),但那是"能不能按到"的问题,这里补的是
    /// "有没有按到"的**反馈**。
    ///
    /// 幅度必须克制。参考实现是 5→9pt(+4),但那是在一个高得多的面板里;灵动岛展开区
    /// 总共只有 expandedExtraHeight,进度条 + 3pt 间距 + 时间行已经占掉大半,
    /// 再长 4pt 会把时间行往下挤出可见区。3→5→6 是量过余量之后的取值。
    private var scrubberHeight: CGFloat {
        if scrubbingFraction != nil { return 6 }
        return hoveringScrubber ? 5 : 3
    }

    private static func timeString(ms: Int) -> String { NotchTimeFormat.mmss(ms: ms) }
}

/// `m:ss` —— 迷你进度条底下那行时间和「已播/剩余时长」两个耳朵模块共用一份。
///
/// 抽出来是因为加耳朵模块时差点在 NotchLyricsView 里再写一份:同一个卡片上两处
/// 时间格式不一样(一处补前导零、一处不补)是那种没人会当 bug 报、但看着就是不对劲的东西。
enum NotchTimeFormat {
    /// 拿不到锚点时那条秒表的兜底起点。
    /// 放在这里而不是 NotchLyricsView 里:那是个泛型类型(`<Chrome: NotchChromeSource>`),
    /// Swift 不允许泛型类型有 static 存储属性。
    static let clockEpoch = Date(timeIntervalSince1970: 0)

    /// 时间类耳朵模块那条秒表的时刻表。相位算术在 Core(`NotchClockPhase.tick`,selftest 覆盖),
    /// 这里只把结果包成 SwiftUI 的 schedule。
    /// 显示的是剩余(倒计时)时传 `countdownFromMs` = 总长,跳秒边界跟正计时不同(见 `NotchClockPhase`)。
    static func clockSchedule(for anchor: ProgressAnchor, countdownFromMs: Int? = nil) -> PeriodicTimelineSchedule {
        let tick = NotchClockPhase.tick(for: anchor, epoch: clockEpoch, countdownFromMs: countdownFromMs)
        return .periodic(from: tick.start, by: tick.interval)
    }

    static func mmss(ms: Int) -> String { NotchClockPhase.mmss(ms: ms) }
}
