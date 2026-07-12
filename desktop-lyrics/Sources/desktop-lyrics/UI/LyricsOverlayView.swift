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
struct LyricsOverlayView: View {
    @ObservedObject private var poller = PlaybackCoordinator.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 4) {
            if settings.showRomanization, let roma = poller.currentLine?.romanization {
                Text(roma)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
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
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.75))
                    .transition(.opacity)
            }
            if settings.showNextLinePreview, let next = poller.nextLineText {
                Text(next)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .transition(.opacity)
            }
        }
        // 旧行不再有淡出阶段(见上面的 asymmetric removal),动画时长现在只花在新行的
        // 淡入上,改用 easeOut(先快后慢定住)比原来的 easeInOut 更贴合"只做入场"这件事。
        .animation(.easeOut(duration: 0.24), value: lineIdentity)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        // 近乎透明但不是纯 .clear——纯透明区域有时候完全接不到拖拽手势,这里给个极淡的
        // 背景让 isMovableByWindowBackground 在整块区域都能生效。
        .background(Color.black.opacity(0.001))
        .multilineTextAlignment(.center)
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
            HStack(spacing: 0) {
                ForEach(Array(words.enumerated()), id: \.offset) { _, w in
                    wordText(w)
                }
            }
            .font(.system(size: 20, weight: .bold))
        } else if let text = poller.currentLine?.mainText {
            Text(text)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
        } else {
            Text("♪")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    // 用渐变整体当文字颜色,而不是叠两层 Text + GeometryReader 手算裁剪宽度——渐变的
    // stop 位置能被 SwiftUI 直接插值,20Hz 的离散更新之间会自动补间成平滑的扫过效果,
    // 不再是一格一格跳。中间留一小段过渡带(而不是硬边界)让扫过的感觉更柔和,同时也
    // 掩盖每次 tick 之间fillFraction 步进本身的粗糙感。
    private func wordText(_ w: SyncedLyricWord) -> some View {
        Text(w.text)
            .foregroundStyle(
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: max(0, w.fillFraction - 0.08)),
                        .init(color: .white.opacity(0.35), location: min(1, w.fillFraction + 0.08)),
                        .init(color: .white.opacity(0.35), location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .animation(.linear(duration: 0.06), value: w.fillFraction)
    }
}
