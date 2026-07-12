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
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .center)))
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
        .animation(.easeInOut(duration: 0.28), value: lineIdentity)
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
