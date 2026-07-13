import SwiftUI
import DesktopLyricsCore

// 悬浮窗内容:逐字高亮时用渐变扫过效果(近似网页版 CSS 渐变裁字的视觉,不追求逐像素
// 还原),否则整行高亮;罗马音在上、译文在下,都是可选的小字。
//
// 换行动画的关键取舍(参考了 LyricFever/KaraokeView.swift 的 .id() 触发写法、
// Apple-Music-Lyric-Animation 的 withAnimation 思路):原来的实现完全没有动画——
// 换行是纯粹的属性赋值,SwiftUI 会直接跳变;逐字填色也是每 20Hz tick 用 GeometryReader
// 重新量一次宽度、没有任何插值,两次 tick 之间的填色边界是"一格一格跳"而不是平滑移动。
// 这两点合起来就是用户说的"渲染有问题、视觉效果很差"。
//
// 修法:
// 1) 用只由歌词文本本身(不含 fillFraction)算出的 lineIdentity 当 .id(),配合
//    .animation(value: lineIdentity) 只在真正换到不同一行歌词时才触发交叉淡入淡出+
//    缩放,20Hz 的填色 tick 不会被误判成"换行"从而不会疯狂重触发。
// 2) 逐字填色改成 LinearGradient 直接当 foregroundStyle,渐变的 stop 位置本身能被
//    SwiftUI 平滑插值(.animation(.linear, value: fillFraction)),不用 GeometryReader
//    手算像素宽度,离散更新之间会自己补间,不再是"跳变"。
//
// 上面两点做完之后用户反馈换行瞬间有"残影"——这是 SwiftUI .transition() 的既有机制:
// .id() 一变,旧那份视图和新那份视图会在整个动画时长内同时留在渲染树里、在同一块屏幕
// 位置上分别做透明度渐变(旧的淡出、新的淡入)。背景色/图片这样叠化没问题,但两份不同
// 的文字字形在同一个位置同时半透明,视觉上就是重影。查过 LyricsX(NSStackView 里旧行
// remove、新行 add,两行永远不共享同一个 frame,配合 removeProgressAnimation() 显式清
// 掉上一行残留的填色动画状态)和 LyricFever(现有代码里主歌词行干脆完全不加
// .transition(),整行硬切,只有背景专辑图层才淡入淡出)两个真实开源实现:两者的共同点
// 是"换行时旧的和新的绝不同时以部分透明度占据同一块屏幕"。这里采用二者之间、改动最小
// 的办法——asymmetric transition,旧行 removal 用 .identity(瞬间消失,不参与任何淡出
// 动画),只有新行的 insertion 继续保留原来的淡入+缩小放大效果,这样任意时刻屏幕上只
// 会有一份主歌词文字在渐变,不会重叠。
//
// 换行流畅之后用户又反馈"字与字之间的流转效果还是有点卡顿"——查了 LyricsX 的
// KaraokeLabel.swift 才发现根本差异:LyricsX 是整行一次性建一个 CAKeyframeAnimation
// (keyTimes/values 覆盖全行每个字的真实时间戳),交给 Core Animation 的渲染服务端按
// 屏幕刷新率自主推进,跟应用主线程/轮询完全解耦;而这里原来是 20Hz Timer 采样一次位置、
// 算好 fillFraction 塞进 @Published 结构体,View 端再用 .animation(.linear(duration:
// 0.06), value:) 去补一小段间——60ms 的补间比 50ms 的采样间隔长,新一次几乎总在上一次
// 没放完时就被重新触发,SwiftUI 对 .linear 这类曲线动画重新定目标时是矢量相加而不是
// 从当前值接续,这就是逐字流转卡顿的根源。改法见 mainLine/wordText:不再预算
// fillFraction、不再用 .animation() 补间,而是用 TimelineView(.animation) 按渲染帧频
// 直接从连续的位置锚点(poller.anchor)现算每个字的真实进度——本质上是把"用一个真实
// 时钟驱动纯函数"这件事从 CAKeyframeAnimation 换成了 SwiftUI 原生等价物,不用引入
// AppKit/CALayer。
//
// 逐字流转顺滑之后用户又反馈两点:
// 1) 换行那个 asymmetric transition(缩放+淡入)"感觉没啥用,反而会变卡"——逐字填色改
//    成 TimelineView 驱动之后,换行瞬间除了缩放/淡入动画本身,还叠加了 TimelineView
//    子树整个被 .id() 强制重新挂载的开销(旧的整个拆掉、新的从头建),这两件事撞在同一
//    帧里,在填色已经很顺滑的衬托下这个开销反而显得更突兀。查过的 LyricFever 真实生产
//    实现本来就是"主歌词行干脆不加 transition,硬切"——这次直接采纳,把 mainLine 的
//    .id()/.transition() 整个去掉,换行就是普通的属性更新(SwiftUI 按分支自然 diff,
//    不强制重新挂载),外层 .animation(value: lineIdentity) 留着只给罗马音/译文/下一句
//    预览这几行做淡入淡出(它们只是普通 Text,没有 TimelineView 那份挂载成本)。
// 2) 英文歌词感觉不够顺滑——查了本地缓存里真实的 YRC 数据坐实:同一批歌曲里,英文
//    (Michael Jackson 几首)的逐字时长里有 durationMs==0 的词条(短介词/冠词等,网易云
//    /QQ/酷狗给英文曲目算的逐字对齐精度明显不如中文,中文样本里一个==0都没有),
//    <100ms 的短词占比也明显更高。fillFraction 原来对 durationMs<=0 是硬边界瞬间
//    0→1,短词越多这种"瞬间跳"就越密集,读起来比中文更"跳"。改法见 fillFraction:
//    给填色计算用的有效时长设一个下限(minWordDurationMs),短词/零时长词也能有一段
//    看得见的扫过而不是瞬间跳变——只影响这一个词自己的视觉呈现,不改 startMs、不影响
//    整体歌词对齐/下一个词何时开始。
struct LyricsOverlayView: View {
    @ObservedObject private var poller = PlaybackCoordinator.shared
    @ObservedObject private var settings = AppSettings.shared

    // 悬浮窗高度跟着内容动态变化(见 LyricsOverlayWindowController.updateHeight)——这里
    // 汇报"这次渲染实际需要多高",不需要就什么都不做(默认空闭包,方便预览/测试构造)。
    var onContentHeightChange: (CGFloat) -> Void = { _ in }

    // 固定值,不是设置项——加一个圆角纯粹是给"背景颜色"这个设置配套的实现细节,免得
    // 用户一开背景色看到的是个生硬的直角矩形;两个参考的开源实现里圆角都不是用户可调项。
    private let overlayBackgroundCornerRadius: CGFloat = 16

    var body: some View {
        VStack(spacing: 4) {
            if settings.showRomanization, let roma = poller.currentLine?.romanization {
                Text(roma)
                    .font(settings.romanizationFont)
                    .foregroundStyle(settings.foregroundColor.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true) // 允许换行时如实撑高,不被裁掉
                    .transition(.opacity)
            }
            mainLine
            if settings.showTranslation, let tr = poller.currentLine?.translation {
                Text(tr)
                    .font(settings.translationFont)
                    .foregroundStyle(settings.foregroundColor.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            if settings.showNextLinePreview, let next = poller.nextLineText {
                Text(next)
                    .font(settings.previewFont)
                    .foregroundStyle(settings.foregroundColor.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        // 旧行不再有淡出阶段(见上面的 asymmetric removal),动画时长现在只花在新行的
        // 淡入上,改用 easeOut(先快后慢定住)比原来的 easeInOut 更贴合"只做入场"这件事。
        .animation(.easeOut(duration: 0.24), value: lineIdentity)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(overlayBackground)
        .multilineTextAlignment(.center)
        // 纯测量用,不影响视觉——把这次渲染真正需要的高度报给窗口控制器去调整窗口高度,
        // 长歌词换行到第二行时窗口跟着变高,而不是被原来写死的高度裁掉。
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ContentHeightPreferenceKey.self) { onContentHeightChange($0) }
    }

    @ViewBuilder
    private var overlayBackground: some View {
        if settings.backgroundIsVisible {
            RoundedRectangle(cornerRadius: overlayBackgroundCornerRadius, style: .continuous)
                .fill(settings.backgroundColor)
        } else {
            // 未开启背景色(默认状态)时保留原来近乎透明的拖拽捕获层——纯透明区域有时候
            // 完全接不到拖拽手势,这里给个极淡的背景让 isMovableByWindowBackground 在
            // 整块区域都能生效。
            Color.black.opacity(0.001)
        }
    }

    // 只用歌词的文本内容算身份,不掺 fillFraction——同一行歌词逐字填色推进时这个值
    // 不变,只有真的翻到下一行歌词才会变。mainLine 本身已经不挂 .transition() 了(硬切),
    // 这个值现在只喂给外层 .animation(value:),给罗马音/译文/下一句预览这几行的淡入
    // 淡出提供触发时机。
    private var lineIdentity: String {
        if let words = poller.currentLine?.words {
            return words.map(\.text).joined()
        }
        return poller.currentLine?.mainText ?? "·"
    }

    @ViewBuilder
    private var mainLine: some View {
        if let words = poller.currentLine?.words {
            // 逐字填色改成:只在这一小块子树里挂 TimelineView(.animation),按渲染帧频
            // (最高到屏幕刷新率)直接从 poller.anchor 连续外推播放位置、现算每个字的
            // fillFraction——不再靠 20Hz tick 把预算好的值塞进 @Published 结构体、
            // 每次都用 .animation(.linear(duration:0.06), value:) 补一小段间。60ms 的
            // 补间比 50ms 的 tick 间隔长,新一次几乎总在上一次没放完时就被重新触发;
            // SwiftUI 对 .linear 这类"不可合并"(shouldMerge==false)的曲线动画,重新
            // 定目标时是把新旧两段位移矢量相加而不是从当前值接续,这正是"字与字之间流转
            // 卡顿"的结构性根源,换补间时长治标不治本。改成每帧直接算真值、完全不挂
            // Animation 才是能根治的办法——暂停时 anchor 会变 nil(见 fastTick 守卫),
            // TimelineView 的 paused 参数顺带把这个子树的刷新也停下来,不用额外处理。
            TimelineView(.animation(paused: !poller.isPlayingNow)) { context in
                let currentMs = poller.anchor?.extrapolatedPositionMs(now: context.date) ?? 0
                // 换成会自动换行的 WrapLayout——原来的 HStack(spacing: 0) 从不换行,一行
                // 装不下所有字时会把每个 Text 压缩到自己出省略号,长的逐字歌词行会直接
                // "消失"变成一串"…"。见文件底部 WrapLayout 定义。
                WrapLayout {
                    ForEach(Array(words.enumerated()), id: \.offset) { _, w in
                        wordText(w, atMs: currentMs)
                    }
                }
            }
            .font(settings.mainFont)
        } else if let text = poller.currentLine?.mainText {
            Text(text)
                .font(settings.mainFont)
                .foregroundStyle(settings.foregroundColor)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("♪")
                .font(settings.mainFont)
                .foregroundStyle(settings.foregroundColor.opacity(0.3))
        }
    }

    // 逐字时长下限——只影响这一个词自己的填色速度,不改 startMs、不影响下一个词何时
    // 开始,纯粹是"这个词的扫过动画至少要花多久"。实测坐实英文歌词(NetEase/QQ/酷狗给
    // 的逐字对齐)比中文更容易出现 durationMs==0 或几十毫秒的极短词(介词/冠词一类),
    // 原来的硬边界瞬间 0→1 在这种词密集的英文句子里显得比中文更"跳"。
    private static let minWordDurationMs = 80

    private func fillFraction(for w: SyncedLyricWord, atMs ms: Int) -> Double {
        let effectiveDuration = max(w.durationMs, Self.minWordDurationMs)
        return min(1, max(0, Double(ms - w.startMs) / Double(effectiveDuration)))
    }

    // 用渐变整体当文字颜色,而不是叠两层 Text + GeometryReader 手算裁剪宽度——渐变的
    // stop 位置直接由 TimelineView 每帧算出的真实进度决定,不再需要额外插值。中间留一
    // 小段过渡带(而不是硬边界)让扫过的感觉更柔和。渐变的两个颜色用可配置的
    // foregroundColor 而不是硬编码 .white——已唱过的部分永远是用户选的前景色全强度,
    // 未唱到的部分是同一颜色的 35% 透明度,没有单独的"进度色"设置项。
    private func wordText(_ w: SyncedLyricWord, atMs currentMs: Int) -> some View {
        let fg = settings.foregroundColor
        let fraction = fillFraction(for: w, atMs: currentMs)
        return Text(w.text)
            .foregroundStyle(
                LinearGradient(
                    stops: [
                        .init(color: fg, location: 0),
                        .init(color: fg, location: max(0, fraction - 0.08)),
                        .init(color: fg.opacity(0.35), location: min(1, fraction + 0.08)),
                        .init(color: fg.opacity(0.35), location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            // 故意不再包 .animation(...)——TimelineView(.animation) 已经在按渲染帧频
            // 重算真值,这里再叠一层 SwiftUI Animation 补间只会重新引入上面注释里那套
            // 矢量叠加问题。
    }
}

private struct ContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// 自动换行布局(SwiftUI Layout 协议,macOS 14+起支持,项目 Package.swift 的最低部署目标
// 早就是 macOS 14,不用额外提版本)。逐字歌词一个字一个 Text 排成一排,原来的
// HStack(spacing: 0) 从不换行,遇到宽度不够时会把每个子 Text 压缩到自己装不下、表现成
// 省略号。这个布局改成:一行装不下下一个字就自动另起一行;并且把每一行整体居中(先按
// "这一行能不能再塞下一个字"分组算出每行,再在摆放时把整行按 (可用宽度-这一行实际宽度)/2
// 整体右移),跟这个界面其它文字元素统一的居中风格保持一致。刻意不处理"单个字本身就比
// 一整行还宽"这种极端情况——真实歌词数据里几乎不会出现,出现了也就是这一"行"单独超宽,
// 不做防御性拆分。
private struct WrapLayout: Layout {
    var horizontalSpacing: CGFloat = 0
    var verticalSpacing: CGFloat = 2

    private func computeRows(sizes: [CGSize], maxWidth: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
        for (i, size) in sizes.enumerated() {
            let spacingIfContinuing = indices.isEmpty ? 0 : horizontalSpacing
            if !indices.isEmpty && width + spacingIfContinuing + size.width > maxWidth {
                rows.append((indices, width, height))
                indices = []
                width = 0
                height = 0
            }
            let spacing = indices.isEmpty ? 0 : horizontalSpacing
            width += spacing + size.width
            height = max(height, size.height)
            indices.append(i)
        }
        if !indices.isEmpty {
            rows.append((indices, width, height))
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard let maxWidth = proposal.width, maxWidth.isFinite else {
            // 没有宽度限制:理论上不会走到——调用方(mainLine)所在的 VStack 总会有一个
            // 有限宽度的提案(悬浮窗宽度固定)。兜底铺成一行,不换行。
            let totalWidth = sizes.reduce(0) { $0 + $1.width } + CGFloat(max(0, sizes.count - 1)) * horizontalSpacing
            let maxHeight = sizes.map(\.height).max() ?? 0
            return CGSize(width: totalWidth, height: maxHeight)
        }
        let rows = computeRows(sizes: sizes, maxWidth: maxWidth)
        let totalHeight = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * verticalSpacing
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = computeRows(sizes: sizes, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX + max(0, (bounds.width - row.width) / 2) // 整行居中
            for i in row.indices {
                let size = sizes[i]
                subviews[i].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }
}
