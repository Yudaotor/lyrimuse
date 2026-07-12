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
struct LyricsOverlayView: View {
    @ObservedObject private var poller = PlaybackCoordinator.shared
    @ObservedObject private var settings = AppSettings.shared

    // 固定值,不是设置项——加一个圆角纯粹是给"背景颜色"这个设置配套的实现细节,免得
    // 用户一开背景色看到的是个生硬的直角矩形;两个参考的开源实现里圆角都不是用户可调项。
    private let overlayBackgroundCornerRadius: CGFloat = 16

    var body: some View {
        VStack(spacing: 4) {
            if settings.showRomanization, let roma = poller.currentLine?.romanization {
                Text(roma)
                    .font(settings.romanizationFont)
                    .foregroundStyle(settings.foregroundColor.opacity(0.6))
                    .transition(.opacity)
            }
            mainLine
                .id(lineIdentity)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .center)),
                        removal: .identity // 旧行瞬间消失,不参与淡出——避免跟新行同时半透明造成重影
                    )
                )
            if settings.showTranslation, let tr = poller.currentLine?.translation {
                Text(tr)
                    .font(settings.translationFont)
                    .foregroundStyle(settings.foregroundColor.opacity(0.75))
                    .transition(.opacity)
            }
            if settings.showNextLinePreview, let next = poller.nextLineText {
                Text(next)
                    .font(settings.previewFont)
                    .foregroundStyle(settings.foregroundColor.opacity(0.4))
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
    // 不变,只有真的翻到下一行歌词才会变,换行动画才准确只在"换行"这一刻触发一次。
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
                HStack(spacing: 0) {
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
        } else {
            Text("♪")
                .font(settings.mainFont)
                .foregroundStyle(settings.foregroundColor.opacity(0.3))
        }
    }

    private func fillFraction(for w: SyncedLyricWord, atMs ms: Int) -> Double {
        guard w.durationMs > 0 else { return ms >= w.startMs ? 1 : 0 }
        return min(1, max(0, Double(ms - w.startMs) / Double(w.durationMs)))
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
