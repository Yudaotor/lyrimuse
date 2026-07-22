import SwiftUI
import LyrimuseCore

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
//
// 用户进一步要求"去掉歌词切换的动效,尽可能保证流畅度"——原来只剩罗马音/译文/下一句
// 预览这三行还挂着 .animation(value: lineIdentity) 的淡入淡出(mainLine 本身在上一轮
// 就已经是硬切了)。这次连这最后一点动效也整个去掉:body 上的 .animation(value:) 和
// 这三行各自的 .transition(.opacity) 一并删除,lineIdentity 这个专门为它算的属性也
// 跟着删(没有别的地方用)。现在换到新的一行是纯粹的属性跳变,不经过任何 SwiftUI
// 动画事务,零额外开销。
struct LyricsOverlayView: View {
    @ObservedObject private var poller = PlaybackCoordinator.shared
    @ObservedObject private var settings = AppSettings.shared

    // 悬浮窗高度跟着内容动态变化(见 LyricsOverlayWindowController.updateHeight)——这里
    // 汇报"这次渲染实际需要多高",不需要就什么都不做(默认空闭包,方便预览/测试构造)。
    var onContentHeightChange: (CGFloat) -> Void = { _ in }

    // 固定值,不是设置项——加一个圆角纯粹是给"背景颜色"这个设置配套的实现细节,免得
    // 用户一开背景色看到的是个生硬的直角矩形;两个参考的开源实现里圆角都不是用户可调项。
    private let overlayBackgroundCornerRadius: CGFloat = 16

    // 2026-07-18 加播放控制:鼠标悬停才浮现一排按钮,不用一直占地方,平时观感跟改动前
    // 逐像素一致。只在"锁定位置"关闭时生效——锁定后 LyricsOverlayWindowController.
    // setLocked 会把 window.ignoresMouseEvents 设成 true,窗口整个不再接收任何鼠标事件
    // (点击穿透到下层),.onHover 在那种状态下本来就永远不会被调用;这里用户明确要求
    // "仅在没开启不可移动时才生效",在 View 这一层也显式判断一遍,不单纯依赖那个
    // 窗口级副作用——同一个条件两处各自成立,不是互相依赖的隐式耦合。
    @State private var isHoveringForControls = false

    var body: some View {
        VStack(spacing: 4) {
            if settings.showRomanization, let roma = poller.currentLine?.romanization {
                Text(roma)
                    .font(settings.romanizationFont)
                    .foregroundStyle(settings.foregroundColor.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true) // 允许换行时如实撑高,不被裁掉
                    .lyricsTextStroke(settings.textStrokeEnabled, color: settings.textStrokeColor)
            }
            mainLine
            if settings.showTranslation, let tr = poller.currentLine?.translation {
                Text(tr)
                    .font(settings.translationFont)
                    .foregroundStyle(settings.foregroundColor.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .lyricsTextStroke(settings.textStrokeEnabled, color: settings.textStrokeColor)
            }
            if settings.showNextLinePreview, let next = poller.nextLineText {
                Text(next)
                    .font(settings.previewFont)
                    .foregroundStyle(settings.foregroundColor.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
                    .lyricsTextStroke(settings.textStrokeEnabled, color: settings.textStrokeColor)
            }
            if isHoveringForControls && !settings.lockPosition {
                playbackControls
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
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
        .onHover { hovering in
            guard !settings.lockPosition else { return }
            withAnimation(.easeOut(duration: 0.16)) { isHoveringForControls = hovering }
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 18) {
            controlButton("backward.fill") { MusicPlaybackController.previousTrack() }
            controlButton(poller.isPlayingNow ? "pause.fill" : "play.fill", primary: true) {
                MusicPlaybackController.playPause()
            }
            controlButton("forward.fill") { MusicPlaybackController.nextTrack() }
            // 2026-07-22:新增"锁定"按钮——用户反馈"没锁定时鼠标移到悬浮歌词上,除了
            // 切歌三个按钮,想再加一个能直接在这里锁定的按钮",不用再去"设置"里找
            // "锁定位置"那个开关。用一条竖线跟前面三个播放按钮分个组,提示这是不同类别
            // 的操作,不是切歌功能的第四个按钮。点了之后 settings.lockPosition 变
            // true,这一整排控制按钮(包括它自己)会立刻消失(见 body 里
            // isHoveringForControls && !settings.lockPosition 那个条件),跟直接去
            // 设置里打开那个开关效果完全一致。
            Rectangle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 1, height: 16)
            lockButton
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(.top, 4)
    }

    // 跟 GlobalHotkeys.swift 里播放控制三个动作同一套"点了才校验权限"逻辑——没问过就
    // 顺手弹一次系统授权对话框,已经拒绝过就静默不做,不需要在悬浮窗里再单独设计一套
    // 提示 UI。
    private func controlButton(_ systemName: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        iconButton(systemName, primary: primary) {
            guard MusicAutomationPermission.check(askIfNeeded: true).isAuthorized else { return }
            action()
        }
    }

    // 图标用 lock.open.fill——画的是"当前是开着的"这个状态,点一下把它关上/锁定,跟
    // 另外三个播放按钮统一用 .fill 系列图标保持视觉一致。不经过 controlButton 那层
    // "先查 Apple Music 自动化权限"的守卫——锁定位置这个动作跟自动化播放控制完全不
    // 搭边,复用会引入一个跟这个按钮语义不匹配的隐藏依赖,所以两者共享的只是纯视觉
    // 样式(iconButton),各自的守卫/动作逻辑分开写。
    private var lockButton: some View {
        iconButton("lock.open.fill") {
            settings.lockPosition = true
            LyricsOverlayWindowController.shared.setLocked(true)
        }
    }

    private func iconButton(_ systemName: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: primary ? 15 : 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: primary ? 30 : 26, height: primary ? 30 : 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // 2026-07-19 再次调整:曾经在这里加过"没在播放就不画背景卡片/占位符"的判断,用户
    // 反馈这跟"暂停/无播放时隐藏"(hideWhenNotPlaying,见 LyricsOverlayWindowController)
    // 职责重叠了——那个开关本来就是给"没播放时要不要隐藏"这件事准备的入口,这里另开一条
    // 隐藏逻辑,两条路径都在做同一件事,视觉上完全分不出这个开关到底有没有开,反而让人
    // 以为开关失效了。撤回,把"没播放时要不要隐藏"这个决定权完整交还给那一个开关:关闭时
    // (默认)窗口还在、内容也照常画(哪怕只是这个"♪"占位符),想要没播放时不显示,就该去
    // 设置里打开那个开关,而不是指望内容这一层自己偷偷判断。
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
                // compositingGroup 把这一整行字先合成成一张位图,再统一套一次阴影——
                // 之前是每个字的 Text 各自单独 .shadow(),SwiftUI 会把它们当成互相独立的
                // 半透明图层分别渲染,相邻字之间阴影重叠的区域会叠加变暗,一整行看起来
                // 深浅不均、糊成一片(这正是这次"感觉不好看"的根因)。查了 LyricsX 真实
                // 实现(KaraokeLabel.swift)确认它是整行一次性 CTFrameDraw 之后,阴影
                // (NSShadow)只套在这一整个 NSTextField 上、只算一次——不是逐字符各自
                // 描边。这里用 .compositingGroup() 达到同样效果:阴影只按合成后的最终
                // 轮廓统一算一次,顺带把 O(字数) 次阴影合成降到 O(1)(早前
                // project_nowplaying_desktop_lyrics_text_shadow 那条记录里把这个优化项
                // 标成"纯性能、视觉不变"是判断错了——分层阴影跟合并阴影视觉上确实不同,
                // 这次一并订正)。
                .compositingGroup()
                .lyricsTextStroke(settings.textStrokeEnabled, color: settings.textStrokeColor)
            }
            .font(settings.mainFont)
        } else if let text = poller.currentLine?.mainText {
            Text(text)
                .font(settings.mainFont)
                .foregroundStyle(settings.foregroundColor)
                .fixedSize(horizontal: false, vertical: true)
                .lyricsTextStroke(settings.textStrokeEnabled, color: settings.textStrokeColor)
        } else {
            Text("♪")
                .font(settings.mainFont)
                .foregroundStyle(settings.foregroundColor.opacity(0.3))
                .lyricsTextStroke(settings.textStrokeEnabled, color: settings.textStrokeColor)
        }
    }

    // 逐字时长下限——只影响这一个词自己的填色速度,不改 startMs、不影响下一个词何时
    // 开始,纯粹是"这个词的扫过动画至少要花多久"。实测坐实英文歌词(NetEase/QQ/酷狗给
    // 的逐字对齐)比中文更容易出现 durationMs==0 或几十毫秒的极短词(介词/冠词一类),
    // 原来的硬边界瞬间 0→1 在这种词密集的英文句子里显得比中文更"跳"。
    private static let minWordDurationMs = 80
    // 过渡带半宽(fraction 单位)——真正需要柔化的只是"刚好唱到/刚好唱完"这个边界附近
    // 一小段,不是整个 [0,1] 区间。
    private static let wordEdgeSoftenBand = 0.08

    // 故意不夹到 [0,1]——早年版本在这里用 min(1,max(0,...)) 夹过,副作用是"还没轮到、
    // 离真正唱到还有好几个字/好几句"的词全都被夹成跟"刚好唱到这个词的最前一刻"完全
    // 相同的 0,wordText 里的过渡带因此在每一个尚未唱到的词开头都会误算出一小截"已经
    // 唱过"的高亮——英文按整词(而非整字)分词,这一小截过渡带宽度恰好接近首字母的宽度,
    // 表现成"还没唱到的英文词首字母却先带了点颜色"(中文逐字分词单位更小、同样的绝对
    // 误差在视觉上没那么显眼,但机制其实是共通的)。真正需要的裁剪挪到 wordGradient 里,
    // 按"过渡带跟 [0,1] 是否有交集"分情况处理,离得够远的词直接算纯色、不构造多余的
    // 渐变过渡。
    private func fillFraction(for w: SyncedLyricWord, atMs ms: Int) -> Double {
        let effectiveDuration = max(w.durationMs, Self.minWordDurationMs)
        return Double(ms - w.startMs) / Double(effectiveDuration)
    }

    // 用渐变整体当文字颜色,而不是叠两层 Text + GeometryReader 手算裁剪宽度——渐变的
    // stop 位置直接由 TimelineView 每帧算出的真实进度决定,不再需要额外插值。渐变的两个
    // 颜色用可配置的 foregroundColor 而不是硬编码 .white——已唱过的部分永远是用户选的
    // 前景色全强度,未唱到的部分是同一颜色的 35% 透明度,没有单独的"进度色"设置项。
    private func wordText(_ w: SyncedLyricWord, atMs currentMs: Int) -> some View {
        let fg = settings.foregroundColor
        let fraction = fillFraction(for: w, atMs: currentMs)
        let band = Self.wordEdgeSoftenBand
        return Text(w.text)
            .foregroundStyle(wordGradient(fg: fg, left: fraction - band, right: fraction + band))
            // 故意不再包 .animation(...)——TimelineView(.animation) 已经在按渲染帧频
            // 重算真值,这里再叠一层 SwiftUI Animation 补间只会重新引入上面注释里那套
            // 矢量叠加问题。也故意不在这里单独套描边——描边统一挪到 mainLine 里
            // WrapLayout 外层的 .compositingGroup()+.lyricsTextStroke(),见那边注释。
    }

    // 过渡带 [left, right] 以这个字真实的(未夹到 [0,1] 的)进度为中心,可能整段落在
    // [0,1] 之外——离真正唱到还很远的字(right<=0)、或者早就唱完很久的字(left>=1),
    // 两种都不需要渐变,直接整字纯色,不构造多余的 stop、也不会在边界凭空冒出一截
    // 不该有的高亮/暗淡。只有过渡带真正跟 [0,1] 有交集时才需要在夹住的那一端现算准确
    // 的混合色(而不是硬编码"已唱"/"未唱"两个端值),避免同一位置出现两个不同颜色的
    // stop 时被其中一个"抢占"。
    private func wordGradient(fg: Color, left: Double, right: Double) -> LinearGradient {
        let dim = fg.opacity(0.35)
        if right <= 0 {
            return LinearGradient(colors: [dim, dim], startPoint: .leading, endPoint: .trailing)
        }
        if left >= 1 {
            return LinearGradient(colors: [fg, fg], startPoint: .leading, endPoint: .trailing)
        }
        func blended(at x: Double) -> Color {
            let t = min(1, max(0, (x - left) / (right - left)))
            return fg.opacity(1 - t * 0.65) // 0.65 = 1 - 0.35,在 full 和 dim(0.35)之间线性混
        }
        var stops: [Gradient.Stop] = []
        if left > 0 {
            stops.append(.init(color: fg, location: 0))
            stops.append(.init(color: fg, location: left))
        } else {
            stops.append(.init(color: blended(at: 0), location: 0))
        }
        if right < 1 {
            stops.append(.init(color: dim, location: right))
            stops.append(.init(color: dim, location: 1))
        } else {
            stops.append(.init(color: blended(at: 1), location: 1))
        }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }
}

// 悬浮窗背景透明、文字直接叠在桌面内容上,颜色/内容对不上时容易糊在一起——加一圈描边
// 提高辨识度,是字幕类悬浮显示的常见做法。
//
// 2026-07-14 上线时这里做的是模糊阴影(.shadow(radius:)),参考 LyricsX 的
// PreferenceDisplayViewController+KaraokeLyricsView.swift 调过取值(偏移量改成
// shadowOffset = .zero 的"四面光晕"效果、逐字歌词那一行统一在 WrapLayout 外层
// .compositingGroup() 之后只套一次,而不是每个字各自套一次)。
//
// 2026-07-22:用户反馈想要真正的描边(实心轮廓)而不是模糊阴影,要求参考同类开源歌词
// 项目的做法——搜了几个 SwiftUI 文字描边的真实实现(包括 katagaki/DJDX、
// zkHub/SwiftUIPreview 这两个仓库),归纳下来常见两条路:
// 1) "N 个方向各偏移一份内容再叠加"(zkHub/SwiftUIPreview 的 StrokeText 就是这种,
//    支持 8/16/32 个方向可调"质量")——写法简单,但每多一个方向就多渲染/布局一份完整
//    内容,用在这里(mainLine 是 TimelineView(.animation) 驱动的 60fps 逐字填色)意味着
//    每一帧要多付出 N 倍的重复开销,方向数越多描边越圆滑、开销也越高,这条路对这个
//    项目的高频渲染路径不友好。
// 2) katagaki/DJDX(github.com/katagaki/DJDX)View Modifiers/TextStroke.swift 的做法:
//    content 先 .blur(radius:) 让字形轮廓往外"胀"开一圈,Canvas 里用
//    .addFilter(.alphaThreshold(min:)) 把这层模糊的 alpha 通道硬切成非 0 即 1(胀开的
//    区域变成一块实心剪影),拿这个剪影当 mask 盖一层纯色矩形,垫在原始文字(不模糊、
//    保留自己的渐变/颜色)下面当描边。这个技术只需要文字的"形状"(alpha 通道),不关心
//    文字本身画的是纯色还是渐变,所以能像原来的阴影一样整体套在 mainLine 外面一次
//    搞定,不需要对每个字分别处理;开销是固定的"整体渲染 content 一遍 + 一次模糊 +
//    一次阈值",不随描边粗细变化,量级上跟原来 .shadow() 自带的模糊开销相当——采用
//    这条路径,详见下面 OptionalTextStroke。
private struct OptionalTextStroke: ViewModifier {
    let enabled: Bool
    let color: Color
    // 固定常量,不做成 Settings 可调项——延续这个功能原来是阴影时"只给颜色选择器,
    // 半径/偏移是代码里的固定值"的取舍(那时参考的也是 LyricsX 的同款克制)。1.2pt
    // 在这个项目常用的歌词字号下是一圈清晰但不臃肿的细描边。
    private let width: CGFloat = 1.2
    private let symbolID = "np-lyrics-stroke"

    func body(content: Content) -> some View {
        if enabled {
            content
                // 模糊会让内容的可见范围往外"胀"出原本的 frame,这里预留出对应的空间,
                // 不然 Canvas 会把胀出来的部分裁掉,描边看起来缺一圈。描边通常只有一两个
                // 点粗,这圈额外留白很小,不会明显改变歌词行之间的间距。
                .padding(width * 2)
                .background(
                    Rectangle()
                        .foregroundStyle(color)
                        .mask {
                            Canvas { context, size in
                                context.addFilter(.alphaThreshold(min: 0.01))
                                context.drawLayer { ctx in
                                    if let resolved = context.resolveSymbol(id: symbolID) {
                                        ctx.draw(resolved, at: CGPoint(x: size.width / 2, y: size.height / 2))
                                    }
                                }
                            } symbols: {
                                content
                                    .tag(symbolID)
                                    .blur(radius: width)
                            }
                        }
                )
        } else {
            content
        }
    }
}

private extension View {
    func lyricsTextStroke(_ enabled: Bool, color: Color) -> some View {
        modifier(OptionalTextStroke(enabled: enabled, color: color))
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
