import SwiftUI
import LyrimuseCore

// UI 预览阶段给用户看过三个背景风格方向,当时选了磨砂玻璃直接实现;用户后来反馈"另外
// 两个也做一下,做成可配置的",这里把三种都补全。用 AnyShapeStyle 抹掉三种截然不同的
// ShapeStyle 具体类型(纯色/材质/渐变),让 NotchHangingShape.fill(_:) 能用同一个属性
// 统一接收,不需要写三份 if/switch 分支各自调用不同重载的 .fill()。
extension NotchCardStyle {
    var displayName: String {
        switch self {
        case .solidBlack: return L10n.t("纯黑")
        case .frostedGlass: return L10n.t("磨砂玻璃")
        case .darkGradient: return L10n.t("深色渐变")
        }
    }

    var fill: AnyShapeStyle {
        switch self {
        case .solidBlack:
            return AnyShapeStyle(Color.black)
        case .frostedGlass:
            return AnyShapeStyle(.thickMaterial)
        case .darkGradient:
            // 跟当初 UI 预览里"深色渐变"选项同一组色值(#1c1a24/#14212a/#10161c),
            // 从左上到右下过渡,比纯黑多一点点冷色调层次感,又不像磨砂玻璃那样会透出
            // 桌面背景色。
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(hexWithAlpha: "#1C1A24FF", fallback: .black),
                        Color(hexWithAlpha: "#14212AFF", fallback: .black),
                        Color(hexWithAlpha: "#10161CFF", fallback: .black),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }
}

// 灵动岛样式的内容视图。稳态(不 hover)常显"歌名+播放控制+当前歌词逐字高亮"这一整套,
// 不需要 hover 才能用;hover 时在下面多展开一块"下一句歌词预览+迷你进度条"作为锦上
// 添花的补充信息——调研过 boring.notch 等真实参考实现后确定这个分层思路(稳态给
// 完整基本信息,hover 给深化信息),没有加专辑封面(本地播放源目前没有把 artwork 转发到
// PlaybackCoordinator,不为这一个位置单独新增取图链路,等以后接了封面数据源再考虑)。
//
// 分两/三行:
// - 顶行(高度 = controller.contentTopInset,正好等于刘海本身/无刘海屏幕的兜底值):
//   物理刘海是屏幕硬件层面真实不发光的区域,横向落在刘海本身宽度(controller.
//   notchWidth)范围内的内容会被真实挡掉,所以这一行中间让出 notchWidth 宽度的空当
//   什么都不放。左耳放歌名文字(真机反馈"应该放歌名",不再是固定的音符图标);右耳
//   把 3 个播放控制按钮放在一起,尺寸比上一版小一号(真机反馈"有点被截断")。
// - 歌词行:逐字高亮跟随播放进度扫过(真机反馈要支持逐字高亮),技术上跟
//   LyricsOverlayView.mainLine 是同一套原理(TimelineView 按渲染帧频现算 fillFraction+
//   渐变着色),但不复用那个文件里的实现——这里没有 WrapLayout(单行、不换行,超长
//   直接硬裁,不追求省略号),前景色固定白色(不像经典悬浮窗那样可配置),复杂度明显
//   小一截,直接在这个文件里写一份简化版更清楚,不值得为了复用去抽象出一层共享代码。
// - hover 展开时才出现的第三行:下一句歌词预览 + 一条迷你进度条。
//
// 整个卡片形状故意只在底部两个角做圆角、顶部两个角是直角(NotchHangingShape)——真机
// 反馈"接近顶部的部分不要做弧度,下面有弧度":顶部紧贴屏幕/刘海本身那条边,视觉上应该
// 是直接从刘海"长出来"、跟屏幕顶边严丝合缝,而不是一个悬空的、四角都带圆角的胶囊。
//
// 背景改成磨砂玻璃(.thickMaterial,配 NotchLyricsWindow 里固定的 .darkAqua 外观)——
// 真机反馈"现在全是黑色不好看",给了三个方向(纯黑/磨砂玻璃/深色渐变)的预览之后选定
// 磨砂玻璃。刘海本身所在的那一段空当(顶行中间)物理上不会显示任何像素,磨砂玻璃对着
// 那一段渲染成什么都无所谓,不需要跟其余部分区别对待。
struct NotchLyricsView: View {
    @ObservedObject var controller: NotchLyricsWindowController
    @ObservedObject private var poller = PlaybackCoordinator.shared
    @ObservedObject private var settings = AppSettings.shared

    // 稳态歌词行的固定高度——跟 NotchLyricsWindowController.contentSize.height 保持
    // 一致(两个文件都描述同一个窗口的几何,这点数值耦合是设计使然,不值得为两个常量
    // 专门抽一个共享类型)。展开时窗口总高度会多出 expandedExtraHeight,这部分空间全部
    // 交给下面的展开内容,歌词行本身高度不跟着变。
    private static let compactRowHeight: CGFloat = 44
    private static let expandedExtraHeight: CGFloat = 40

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
                    .fill(settings.notchCardStyle.fill)
                // 收起态(没在播放、没 hover)窗口本身已经缩到刘海大小,这里额外把常显
                // 内容整套摘掉而不是指望窗口太小自然裁掉——避免文字/按钮在收缩动画过程中
                // 短暂挤压变形的观感,收起就是纯粹的一块背景,跟真实刘海融为一体。
                if !controller.isCollapsed {
                    VStack(spacing: 0) {
                        topRow(earWidth: earWidth)
                            .frame(height: controller.contentTopInset)
                        lyricRow
                            .frame(height: Self.compactRowHeight)
                        if controller.isExpanded {
                            expandedContent
                        }
                    }
                }
            }
            // 展开态内容(下一句预览+进度条)本身没有另外裁一次形状——如果只让背景
            // 那一层 fill 是圆角、前景内容不跟着裁,内容溢出圆角边界时会带着直角"戳"出
            // 卡片轮廓(调试红色矩形块验证过这个现象:矩形四个角明显比卡片本身的圆角更
            // 方)。这里对整个 ZStack 统一裁一次,保证任何内容都不会越出这个卡片的真实
            // 外轮廓。
            .clipShape(NotchHangingShape(bottomCornerRadius: 20))
        }
        .onHover { hovering in
            controller.setExpanded(hovering)
        }
    }

    private func topRow(earWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            // 左耳:歌名(真机反馈"应该放歌名",不再是固定的音符图标)。超长滚动展示
            // (真机反馈"歌词和歌名一样,太长要滚动"),不再是硬截断省略号。
            MarqueeText(id: poller.title) {
                Text(poller.title.isEmpty ? "♪" : poller.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: earWidth)

            // 刘海本身的空当——物理硬件不发光区域,什么都不放。
            Color.clear
                .frame(width: controller.notchWidth)

            // 右耳:3 个播放控制按钮放在一起——真机反馈按钮偏大、贴边有裁切感,这一版
            // 整体缩小一号(controlButton 的尺寸参数)。Spacer 放在最前面把按钮簇推到
            // 这只耳朵的最右侧(真机反馈"整体还是往左挤了,应该往右移")。
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                controlButton("backward.fill") { MusicPlaybackController.previousTrack() }
                controlButton(poller.isPlayingNow ? "pause.fill" : "play.fill", primary: true) {
                    MusicPlaybackController.playPause()
                }
                controlButton("forward.fill") { MusicPlaybackController.nextTrack() }
            }
            .frame(width: earWidth)
        }
        .padding(.horizontal, 10)
    }

    // 用歌词这一行纯文本(不含逐字填色进度)当 MarqueeText 的 id——换到新的一句歌词才
    // 重新测量/重新开始滚动,同一句歌词内部逐字变色的高频刷新(TimelineView 那部分)
    // 不应该打断正在进行的滚动。
    private var lyricRow: some View {
        MarqueeText(id: poller.currentLine?.plainText ?? "") {
            lyricContent
        }
        .font(.system(size: 13, weight: .semibold))
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 16)
    }

    private var lyricContent: some View {
        Group {
            if let words = poller.currentLine?.words, !words.isEmpty {
                TimelineView(.animation(paused: !poller.isPlayingNow)) { context in
                    let currentMs = poller.anchor?.extrapolatedPositionMs(now: context.date) ?? 0
                    HStack(spacing: 0) {
                        ForEach(Array(words.enumerated()), id: \.offset) { _, w in
                            wordText(w, atMs: currentMs)
                        }
                    }
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                }
            } else {
                Text(poller.currentLine?.plainText ?? "♪")
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            }
        }
        .lineLimit(1)
    }

    // 逐字时长下限/过渡带宽度跟 LyricsOverlayView 用同一组经验取值(80ms/0.08),这两个
    // 数字本身是"看起来顺眼"的调校结果,不是从歌词数据推导出来的,两处保持一致没有坏处。
    private static let minWordDurationMs = 80
    private static let wordEdgeSoftenBand = 0.08

    private func fillFraction(for w: SyncedLyricWord, atMs ms: Int) -> Double {
        let effectiveDuration = max(w.durationMs, Self.minWordDurationMs)
        return Double(ms - w.startMs) / Double(effectiveDuration)
    }

    private func wordText(_ w: SyncedLyricWord, atMs currentMs: Int) -> some View {
        let fraction = fillFraction(for: w, atMs: currentMs)
        let band = Self.wordEdgeSoftenBand
        return Text(w.text)
            .foregroundStyle(wordGradient(left: fraction - band, right: fraction + band))
    }

    // 跟 LyricsOverlayView.wordGradient 同一套算法(前景色固定白色,不像经典悬浮窗那样
    // 可配置)——过渡带真正跟 [0,1] 有交集时才现算混合色,离得够远的字直接算纯色。
    private func wordGradient(left: Double, right: Double) -> LinearGradient {
        let dim = Color.white.opacity(0.35)
        let full = Color.white
        if right <= 0 {
            return LinearGradient(colors: [dim, dim], startPoint: .leading, endPoint: .trailing)
        }
        if left >= 1 {
            return LinearGradient(colors: [full, full], startPoint: .leading, endPoint: .trailing)
        }
        func blended(at x: Double) -> Color {
            let t = min(1, max(0, (x - left) / (right - left)))
            return full.opacity(1 - t * 0.65)
        }
        var stops: [Gradient.Stop] = []
        if left > 0 {
            stops.append(.init(color: full, location: 0))
            stops.append(.init(color: full, location: left))
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

    // hover 展开时多出来的这一块——下一句歌词预览 + 迷你进度条,调研结论里排在"专辑
    // 封面+歌名"之后的第二优先级(封面已经在顶行用歌名文字替代过,不重复加),用来强化
    // "这是个歌词类产品"而不是退化成通用媒体控制器;进度条属于"有余量就加"的加分项。
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !nextLineDisplayText.isEmpty {
                Text(nextLineDisplayText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if let anchor = poller.anchor, anchor.durationMs > 0 {
                TimelineView(.animation(paused: !poller.isPlayingNow)) { context in
                    let currentMs = anchor.extrapolatedPositionMs(now: context.date)
                    VStack(spacing: 3) {
                        GeometryReader { proxy in
                            let fraction = min(1, max(0, Double(currentMs) / Double(anchor.durationMs)))
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.18))
                                Capsule().fill(.white.opacity(0.85))
                                    .frame(width: proxy.size.width * fraction)
                            }
                        }
                        .frame(height: 3)
                        HStack {
                            Text(Self.timeString(ms: currentMs))
                            Spacer()
                            Text("-" + Self.timeString(ms: anchor.durationMs - currentMs))
                        }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .monospacedDigit()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .frame(height: Self.expandedExtraHeight, alignment: .top)
    }

    // 真机反馈"去掉'下一句'这个字眼,直接显示下一句歌词内容就好"——不再加任何前缀标签。
    private var nextLineDisplayText: String {
        poller.nextLineText ?? ""
    }

    private static func timeString(ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func controlButton(_ systemName: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            guard MusicAutomationPermission.check(askIfNeeded: true).isAuthorized else { return }
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: primary ? 11 : 9.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: primary ? 18 : 15, height: primary ? 18 : 15)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// 超长文字(歌名/歌词)靠自动来回滚动展示全部内容,而不是硬截断/省略号——真机反馈
// "歌词和歌名一样,遇到太长的情况有滚动的方式来显示"。测量内容真实宽度 vs 容器宽度,
// 只有真的溢出容器时才滚动,没溢出的短文字保持静止不动、不产生任何动画。滚动方式是
// "停顿→滚到底→停顿→滚回起点"来回滚动,不是无限单向卷动,不需要为了卷动无缝衔接去
// 复制一份内容拼接。
//
// id 参数控制"什么时候该重新测量、重新从头开始滚动"——歌词行内部逐字变色(由外面
// TimelineView 驱动)不应该打断/重置正在进行的滚动,那只是同一句歌词内部的高亮进度
// 在变,不是这一行内容本身换了;只有真的换了一句歌词、换了一首歌才应该重新开始。
// Swift 不支持泛型类型里放 static stored property,这两个纯常量挪到文件作用域。
private let marqueePixelsPerSecond: Double = 24
private let marqueeHoldDuration: Double = 1.1

private struct MarqueeText<Content: View>: View {
    let id: AnyHashable
    @ViewBuilder let content: () -> Content

    @State private var contentWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var scrollTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { outerProxy in
            content()
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    GeometryReader { innerProxy in
                        Color.clear.preference(key: MarqueeWidthKey.self, value: innerProxy.size.width)
                    }
                )
                .offset(x: -offset)
                // 垂直居中——GeometryReader 默认把内容摆在自己左上角,歌名那里真机
                // 反馈"名字有点过于靠上",不居中的话文字会紧贴着这一整行的顶边。
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .onPreferenceChange(MarqueeWidthKey.self) { width in
                    contentWidth = width
                    restart(containerWidth: outerProxy.size.width)
                }
                .onChange(of: id) {
                    restart(containerWidth: outerProxy.size.width)
                }
        }
        .clipped()
        .onDisappear { scrollTask?.cancel() }
    }

    private func restart(containerWidth: CGFloat) {
        scrollTask?.cancel()
        offset = 0
        let distance = contentWidth - containerWidth
        guard distance > 4, containerWidth > 0 else { return }
        let travelDuration = Double(distance) / marqueePixelsPerSecond
        scrollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(marqueeHoldDuration * 1_000_000_000))
                if Task.isCancelled { return }
                withAnimation(.linear(duration: travelDuration)) { offset = distance }
                try? await Task.sleep(nanoseconds: UInt64(travelDuration * 1_000_000_000) + UInt64(marqueeHoldDuration * 1_000_000_000))
                if Task.isCancelled { return }
                withAnimation(.linear(duration: travelDuration)) { offset = 0 }
                try? await Task.sleep(nanoseconds: UInt64(travelDuration * 1_000_000_000))
            }
        }
    }
}

private struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
