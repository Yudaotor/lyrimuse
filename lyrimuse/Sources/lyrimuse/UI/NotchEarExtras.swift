import AppKit
import LyrimuseCore
import SwiftUI

/// 耳朵里的「收听次数」模块(`NotchEarModule.playCount`):耳机图标 + 这首听到第几次。数字是 `LastfmStatsService.nowPlayingCount`
/// (写法族合并、已把正在放的这一次算进去),跟设置页、歌词窗口那个「第 N 次收听」同一个数。没连 Last.fm、还没取回来时整块留白。
///
/// 服务单例只在这一格上订阅,它别的字段变了最多重算这一格。容器常驻(没数字时也在):换歌时的取数靠它的 onAppear / onChange,
/// 挂在条件内容上会「没数字 → 不渲染 → 永远不取数」,同歌词窗口 `NowPlayingCountBadge`。
struct NotchEarPlayCount: View {
    let title: String
    let artist: String
    let tint: Color
    let alignment: Alignment
    @ObservedObject private var stats = LastfmStatsService.shared

    var body: some View {
        ZStack {
            if stats.isConnected, !title.isEmpty, let count = stats.nowPlayingCount {
                HStack(spacing: 2) {
                    Image(systemName: "headphones")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text("\(count)")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(tint.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .onAppear { refresh() }
        .onChange(of: "\(artist)|\(title)") { refresh() }
        .accessibilityElement(children: .combine)
    }

    private func refresh() {
        guard !title.isEmpty, LastfmStatsService.shared.isConnected else { return }
        LastfmStatsService.shared.refreshNowPlayingCount(title: title, artist: artist)
    }

    /// 塞进一只耳朵最少要多宽:图标 + 三位数(一千次以上靠 `minimumScaleFactor` 缩一点)。
    static let minWidth: CGFloat = 36
}

/// 耳朵里的「播放器」模块(`NotchEarModule.player`):正在放的那个播放器的图标,跟菜单栏面板那枚来源角标同一个
/// (`PlaybackCoordinator.resolvedPlayerIcon`,网页平台画平台图标)。点它切到那个播放器(`openResolvedPlayer`,网页平台翻到正在放的
/// 那个标签页)。认不出来时整块留白。
///
/// 图标按像素预先光栅化(`NotchIdleAppIcon.bitmap`),跟没有曲目时左耳那枚 App 图标同一个尺寸和做法。来源不单独发布:换播放器必然
/// 伴随曲目变化,`trackKey` 一变这一格就重算。
struct NotchEarPlayerIcon: View {
    let side: CGFloat
    let scale: CGFloat
    let alignment: Alignment
    let trackKey: String

    var body: some View {
        let coordinator = PlaybackCoordinator.shared
        ZStack {
            if let icon = coordinator.resolvedPlayerIcon, let key = Self.cacheKey,
               let bitmap = NotchIdleAppIcon.bitmap(of: icon, cacheKey: key, pixelSide: Int((side * scale).rounded())) {
                Button {
                    coordinator.openResolvedPlayer()
                } label: {
                    Image(decorative: bitmap, scale: scale)
                        .frame(width: side, height: side)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(coordinator.resolvedPlayerDisplayName ?? "")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .id(trackKey)
    }

    /// 位图缓存按来源分:网页平台按平台,别的按播放器的 bundle id。
    private static var cacheKey: String? {
        if let platform = PlaybackCoordinator.shared.resolvedWebPlatformID { return "web:\(platform)" }
        return LocalPlaybackSource.shared.lastResolvedBundleID
    }
}
