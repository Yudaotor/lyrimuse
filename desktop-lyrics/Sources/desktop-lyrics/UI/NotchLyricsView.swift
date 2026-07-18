import SwiftUI
import DesktopLyricsCore

// 灵动岛样式的内容视图——常显,不再有"收起态空胶囊+hover 才展开"那一层状态:真机
// (有物理刘海)实测反馈,hover 才显示跟预期不符,歌词这种信息本来就该随时可见,砍掉
// 了 onHover 触发的展开/收起。
//
// 分两行:
// - 顶行(高度 = controller.contentTopInset,正好等于刘海本身/无刘海屏幕的兜底值):
//   物理刘海是屏幕硬件层面真实不发光的区域,横向落在刘海本身宽度(controller.
//   notchWidth)范围内的内容会被真实挡掉,所以这一行中间让出 notchWidth 宽度的空当
//   什么都不放。左耳放一个"正在播放"图标,右耳把 3 个播放控制按钮放在一起——真机
//   反馈"按钮分两边很诡异,应该统一放一边,另一边放别的内容",参考 boring.notch 等
//   真实灵动岛歌词类应用的常见布局(一侧图标/专辑标识,一侧控制簇)。
// - 底行:歌词纯文本,不跟按钮挤同一行,才有足够宽度不那么容易被截断省略号。
//
// 整个卡片形状故意只在底部两个角做圆角、顶部两个角是直角(NotchHangingShape)——真机
// 反馈"接近顶部的部分不要做弧度,下面有弧度":顶部紧贴屏幕/刘海本身那条边,视觉上应该
// 是直接从刘海"长出来"、跟屏幕顶边严丝合缝,而不是一个悬空的、四角都带圆角的胶囊。
//
// 这一版歌词先只用普通 Text 显示 currentLine?.plainText 纯文本,不做
// LyricsOverlayView.mainLine 那套 TimelineView+WrapLayout+渐变逐字高亮——那套实现
// 跟那个文件强耦合,抽出来复用的工程量明显大于这个更小尺寸场景本身需要的复杂度,
// 先用简单版本,觉得不够再加。
struct NotchLyricsView: View {
    @ObservedObject var controller: NotchLyricsWindowController
    @ObservedObject private var poller = PlaybackCoordinator.shared

    var body: some View {
        GeometryReader { proxy in
            // topRow 外层还有 .padding(.horizontal, 10)(左右各 10pt),这里要把这 20pt
            // 也算进去,否则「两只耳朵 + 刘海空当」正好等于 proxy.size.width 之后再叠加
            // padding,会让 topRow 的实际宽度比 GeometryReader 分配的宽度多出整整 20pt——
            // 真机实测坐实过这个 bug:ZStack 会跟着这个更宽的子视图一起变宽,导致背景
            // 形状 NotchHangingShape 收到的 rect 比窗口真实宽度多 20pt,只有当这多出来的
            // 20pt 沿某一侧溢出时,那一侧的底部圆角看起来才会显示为直角(圆角计算完全正确,
            // 但整个形状的宽度本身就比窗口本身多算了一截，超出窗口边界的部分被窗口硬裁掉，
            // 裁到的正好是圆弧那一小段)。
            let earWidth = max(0, (proxy.size.width - controller.notchWidth - 20) / 2)
            ZStack(alignment: .top) {
                NotchHangingShape(bottomCornerRadius: 20)
                    .fill(.black)
                VStack(spacing: 0) {
                    topRow(earWidth: earWidth)
                        .frame(height: controller.contentTopInset)
                    lyricRow
                        .frame(maxHeight: .infinity)
                }
            }
        }
    }

    private func topRow(earWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            // 左耳:一个简单的"正在播放"图标,不需要额外的专辑封面数据源(本地播放
            // 源目前没有把 artwork 转发到 PlaybackCoordinator,不为这一个图标单独
            // 新增取图链路)。紧贴刘海这一侧(trailing)。
            HStack {
                Spacer(minLength: 0)
                Image(systemName: "music.note")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: earWidth)

            // 刘海本身的空当——物理硬件不发光区域,什么都不放。
            Color.clear
                .frame(width: controller.notchWidth)

            // 右耳:3 个播放控制按钮放在一起,不再分两边——真机反馈分开摆很诡异。
            // 紧贴刘海这一侧(leading)。
            HStack(spacing: 10) {
                controlButton("backward.fill") { MusicPlaybackController.previousTrack() }
                controlButton(poller.isPlayingNow ? "pause.fill" : "play.fill", primary: true) {
                    MusicPlaybackController.playPause()
                }
                controlButton("forward.fill") { MusicPlaybackController.nextTrack() }
                Spacer(minLength: 0)
            }
            .frame(width: earWidth)
        }
        .padding(.horizontal, 10)
    }

    private var lyricRow: some View {
        Text(poller.currentLine?.plainText ?? "♪")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
    }

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

// 顶部两个角是直角、只有底部两个角带圆角的卡片形状——SwiftUI 的 RoundedRectangle
// 只支持四角统一圆角,`UnevenRoundedRectangle` 又要 macOS 26 起才有(这个项目部署
// 目标是 14),手写一个 Shape 直接按四段直线+两段圆弧画出这个轮廓,不依赖新 API。
private struct NotchHangingShape: Shape {
    var bottomCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(bottomCornerRadius, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
