import SwiftUI
import DesktopLyricsCore

// 灵动岛样式的内容视图。收起态:纯黑胶囊,不放任何内容——这正是"灵动岛"这个视觉
// 隐喻本身的样子,平时几乎看不出跟真刘海的区别(这台开发机没有真刘海没法拿真机效果
// 比对着调,先用纯黑,贴近真刘海本身几乎全黑的观感)。展开态(鼠标 hover 触发):
// 一行当前歌词 + 上次播放控制那三个按钮。
//
// 这一版展开态先只用普通 Text 显示 currentLine?.plainText 纯文本,不做
// LyricsOverlayView.mainLine 那套 TimelineView+WrapLayout+渐变逐字高亮——那套实现
// 跟那个文件强耦合,抽出来复用的工程量明显大于这个更小尺寸场景本身需要的复杂度,
// 先用简单版本,觉得不够再加。
//
// 故意不像经典悬浮窗 LyricsOverlayView 那样在"展开"之外再叠一层"hover 才显示控制
// 按钮"的二次判断——用户明确说了"展开本身就已经代表用户正在看着它",展开态里播放
// 控制按钮直接常驻,不用再等第二次 hover。
struct NotchLyricsView: View {
    @ObservedObject var controller: NotchLyricsWindowController
    @ObservedObject private var poller = PlaybackCoordinator.shared

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // 展开态用固定的小圆角(接近真实灵动岛卡片的观感);收起态圆角=高度
                // 的一半,天然撑成一个胶囊——不管当下是刘海本身的真实宽高还是无刘海
                // 的兜底尺寸,这个算法都成立,不需要分别处理两种情况。
                RoundedRectangle(cornerRadius: controller.isExpanded ? 20 : proxy.size.height / 2, style: .continuous)
                    .fill(.black)
                if controller.isExpanded {
                    expandedContent
                        .padding(.horizontal, 16)
                }
            }
        }
        .onHover { hovering in
            controller.setExpanded(hovering)
        }
    }

    private var expandedContent: some View {
        HStack(spacing: 14) {
            Text(poller.currentLine?.plainText ?? "♪")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            controlButton("backward.fill") { MusicPlaybackController.previousTrack() }
            controlButton(poller.isPlayingNow ? "pause.fill" : "play.fill", primary: true) {
                MusicPlaybackController.playPause()
            }
            controlButton("forward.fill") { MusicPlaybackController.nextTrack() }
        }
    }

    // 跟 LyricsOverlayView.controlButton 同一套"点了才校验权限"逻辑——那边的实现是
    // private 且按钮尺寸不同,这里没有直接复用那个 View,复用的是底层
    // MusicPlaybackController/MusicAutomationPermission 这两个类型本身(两处都要求
    // 直接复用、不改内部逻辑)。
    private func controlButton(_ systemName: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            guard MusicAutomationPermission.check(askIfNeeded: true).isAuthorized else { return }
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: primary ? 13 : 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: primary ? 22 : 18, height: primary ? 22 : 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
