import SwiftUI
import DesktopLyricsCore

// 悬浮窗内容:逐字高亮时用渐变扫过效果(近似网页版 CSS 渐变裁字的视觉,不追求逐像素
// 还原),否则整行高亮;罗马音在上、译文在下,都是可选的小字。
struct LyricsOverlayView: View {
    @ObservedObject private var poller = RelayPoller.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 4) {
            if settings.showRomanization, let roma = poller.currentLine?.romanization {
                Text(roma)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            mainLine
            if settings.showTranslation, let tr = poller.currentLine?.translation {
                Text(tr)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        // 近乎透明但不是纯 .clear——纯透明区域有时候完全接不到拖拽手势,这里给个极淡的
        // 背景让 isMovableByWindowBackground 在整块区域都能生效。
        .background(Color.black.opacity(0.001))
        .multilineTextAlignment(.center)
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

    // 每个词:暗色底文 + 一份按 fillFraction 裁宽的亮色文字叠在上面,模拟从左到右扫过填色。
    private func wordText(_ w: SyncedLyricWord) -> some View {
        Text(w.text)
            .foregroundStyle(.white.opacity(0.35))
            .overlay(alignment: .leading) {
                if w.fillFraction > 0 {
                    GeometryReader { geo in
                        Text(w.text)
                            .foregroundStyle(.white)
                            .frame(width: geo.size.width * w.fillFraction, alignment: .leading)
                            .clipped()
                    }
                }
            }
    }
}
