import AppKit
import SwiftUI
import LyrimuseCore

// 用 AnyShapeStyle 抹掉三种截然不同的 ShapeStyle 具体类型(纯色/材质/渐变),让
// NotchHangingShape.fill(_:) 能用同一个属性统一接收,不需要写三份 if/switch 分支
// 各自调用不同重载的 .fill()。
extension NotchCardStyle {
    var displayName: String {
        switch self {
        case .solidBlack: return L10n.t("纯黑")
        case .frostedGlass: return L10n.t("磨砂玻璃")
        case .darkGradient: return L10n.t("深色渐变")
        case .coverArt: return L10n.t("跟随封面")
        }
    }

    // .coverArt 的真实渲染(封面模糊图)是在 NotchLyricsView.backgroundLayer 里单独
    // 处理的(ShapeStyle 表达不了 .blur()/.overlay() 这类 View 修饰符,没法塞进这个
    // AnyShapeStyle 里),这里给它的返回值只是"没有封面数据时的兜底"/"万一有别处意外
    // 读到这个属性"的合理默认——跟 darkGradient 用同一个值,不代表 .coverArt 的
    // 实际效果,不要在其它地方依赖这条分支来渲染 .coverArt。
    var fill: AnyShapeStyle {
        switch self {
        case .solidBlack:
            return AnyShapeStyle(Color.black)
        case .frostedGlass:
            return AnyShapeStyle(.thickMaterial)
        case .darkGradient, .coverArt:
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

// 灵动岛样式的内容视图。稳态(不 hover)常显"歌名+播放控制+当前歌词逐字高亮"整套,
// hover 时在下面多展开一块"下一句歌词预览+迷你进度条"作为补充信息(参考 boring.notch
// 等实现的分层思路:稳态给完整基本信息,hover 给深化信息)。没有加专辑封面——本地播放源
// 目前没有把 artwork 转发到 PlaybackCoordinator,不为这一个位置单独新增取图链路。
//
// 分两/三行:
// - 顶行(高度 = controller.contentTopInset,等于刘海本身/无刘海屏幕的兜底值):物理
//   刘海是屏幕硬件层面真实不发光的区域,横向落在刘海宽度(controller.notchWidth)范围内
//   的内容会被真实挡掉,这一行中间让出 notchWidth 宽度的空当什么都不放。左耳放歌名,
//   右耳放 3 个播放控制按钮。
// - 歌词行:逐字高亮跟随播放进度扫过,技术上跟 LyricsOverlayView.mainLine 是同一套原理
//   (TimelineView 按渲染帧频现算 fillFraction+渐变着色),但不复用那份实现——这里没有
//   WrapLayout(单行不换行,超长直接硬裁),前景色固定白色,复杂度明显小一截,直接写一份
//   简化版更清楚,不值得为了复用去抽象共享代码。
// - hover 展开时才出现的第三行:下一句歌词预览 + 一条迷你进度条。
//
// 整个卡片形状故意只在底部两个角做圆角、顶部两个角是直角(NotchHangingShape)——顶部
// 紧贴屏幕/刘海本身那条边,视觉上应该是直接从刘海"长出来"、跟屏幕顶边严丝合缝,而不是
// 一个悬空的、四角都带圆角的胶囊。
//
// 背景用磨砂玻璃(.thickMaterial,配 NotchLyricsWindow 里固定的 .darkAqua 外观)。刘海
// 本身所在的那一段空当(顶行中间)物理上不会显示任何像素,渲染成什么都无所谓,不需要跟
// 其余部分区别对待。
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
            // padding,会让 topRow 的实际宽度比 GeometryReader 分配的宽度多出整整 20pt:
            // ZStack 会跟着这个更宽的子视图一起变宽,导致背景形状 NotchHangingShape 收到
            // 的 rect 比窗口真实宽度多 20pt,只有当这多出来的 20pt 沿某一侧溢出时,那一侧
            // 的底部圆角才会显示为直角(圆角计算本身没错,只是形状宽度比窗口多算了一截,
            // 超出边界的部分被窗口硬裁掉,裁到的正好是圆弧那一小段)。
            let earWidth = max(0, (proxy.size.width - controller.notchWidth - 20) / 2)
            ZStack(alignment: .top) {
                backgroundLayer(size: proxy.size)
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
            // 展开态内容(下一句预览+进度条)本身没有另外裁一次形状——如果只让背景那一层
            // fill 是圆角、前景内容不跟着裁,内容溢出圆角边界时会带着直角"戳"出卡片轮廓。
            // 这里对整个 ZStack 统一裁一次,保证任何内容都不会越出这个卡片的真实外轮廓。
            .clipShape(NotchHangingShape(bottomCornerRadius: 20))
        }
        .onHover { hovering in
            controller.setExpanded(hovering)
        }
    }

    // 2026-08-02 新增"跟随封面"背景——跟"歌词窗口"的 artworkBackground(LyricsWindowView.swift)
    // 完全同一套效果(封面整图放大、高斯模糊、压一层半透明黑),只是缩小到灵动岛胶囊
    // 尺寸;poller.artworkData 那份数据本来就已经在转发给 PlaybackCoordinator 用于
    // "歌词窗口",这里直接复用同一个数据源,不需要新开一条取图链路(这一点跟本文件
    // 顶部旧注释"本地播放源没有转发 artwork"已经不一致——那条注释是加"歌词窗口"功能
    // 之前写的,早已过期)。
    //
    // ShapeStyle(NotchCardStyle.fill)表达不了 .blur()/.overlay() 这类 View 修饰符,
    // 所以 .coverArt 这个风格不走"给 NotchHangingShape 填色"这条路,改成在背景层直接
    // 塞一张 Image。
    //
    // ⚠️ .scaledToFill() 之后、.clipShape 之前必须显式钉一次 .frame(width:height:)
    // ——2026-08-02 实测排查坐实(用像素级采样确认过,不是肉眼被模糊柔化骗了),踩了
    // 三版才找对根因:
    // 第一版完全没裁——四个角全变直角。
    // 第二版换成 `.clipped()`——`.clipped()` 只会裁成矩形,压根不认识
    //   NotchHangingShape 这个"顶直角、底圆角"的形状,自然还是直角。
    // 第三版改成 `.clipShape(NotchHangingShape(...))` 直接套在 Image 上,以为这样
    //   总该认得形状了,肉眼截图看起来也像是圆角——但对左下角做像素级采样(逐行扫描
    //   card 区域与背景的分界线 x 坐标,检查是否随 y 增大而右移)后发现分界线纹丝不动,
    //   证明那次"看起来圆"其实是模糊本身的柔和渐变骗了肉眼,底层裁剪仍然是直角。
    // 真正原因是本文件顶部 topRow/earWidth 那处注释描述过的同一类问题:
    // `.scaledToFill()`(即 aspectRatio(contentMode: .fill))为了保证"图片撑满、
    // 不留缝隙"而向布局系统请求一个可能比 ZStack 实际可见尺寸更大的 frame(维持宽高比
    // 需要在某个方向溢出、裁掉多余部分)。`.clipShape` 是按它**紧邻**的上一个 View
    // 的 frame 算 `path(in rect:)` 的,而不是按外层 GeometryReader/窗口的真实尺寸——
    // 如果这张 Image 协商到的 frame 比灵动岛胶囊本身大一圈,NotchHangingShape 画出来的
    // 圆角就落在了这个偏大的矩形边缘,而不是胶囊真正的可见边缘,可见区域里看到的只是
    // 这个偏大矩形的中间一截,自然还是直角。修法:`.scaledToFill()` 之后先用
    // `.frame(width: size.width, height: size.height)` 把协商结果显式钉回胶囊真正的
    // 尺寸(GeometryReader 的 proxy.size,从 body 传进来),`.clipShape` 才会在正确的
    // 边界上计算圆角。
    //
    // 没有封面数据(这首歌还没解析出封面/collector 还没查到/本来就没有)时退回
    // NotchCardStyle.darkGradient 的固定渐变——不会露出空白背景,也不需要用户在"没有
    // 封面"和"其它三个固定风格"之间多做一次选择。
    //
    // 模糊半径比"歌词窗口"artworkBackground 的 60 小得多——那边画布常年好几百 pt 高,
    // 60pt 模糊半径只占画布的一小部分,还能看出封面本身的色块层次;灵动岛稳态高度只有
    // 76pt、宽度 360pt(约 4.7:1 的又矮又宽比例),照搬同一个绝对数值相对尺寸夸张太多,
    // 2026-08-02 实测排查坐实:哪怕换一张色彩很丰富的封面(比如粉色玩具马配红白条纹的
    // 封面),灵动岛这里也会被抹成跟其它封面几乎分不出来的统一深灰色,颜色信息基本损失
    // 殆尽,违背了"跟随封面颜色"这个功能本身的目的。调小到 20——仍然是明显的"模糊",
    // 但能留住封面主色调之间可辨认的差异。
    @ViewBuilder
    private func backgroundLayer(size: CGSize) -> some View {
        if settings.notchCardStyle == .coverArt, let data = poller.artworkData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .blur(radius: 20)
                .overlay(Color.black.opacity(0.45))
                .clipShape(NotchHangingShape(bottomCornerRadius: 20))
                .animation(.easeInOut(duration: 0.5), value: data)
        } else {
            NotchHangingShape(bottomCornerRadius: 20)
                .fill(settings.notchCardStyle.fill)
        }
    }

    private func topRow(earWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            MarqueeText(id: poller.title) {
                Text(poller.title.isEmpty ? "♪" : poller.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: earWidth)

            // 刘海本身的空当——物理硬件不发光区域,什么都不放。
            Color.clear
                .frame(width: controller.notchWidth)

            // 右耳:3 个播放控制按钮放在一起。Spacer 放在最前面把按钮簇推到这只耳朵的
            // 最右侧。
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
                    // 加上 currentLyricsOffsetMs,理由跟 LyricsOverlayView.mainLine 同一段
                    // 注释——不加的话"当前词判定"和"填色进度"用的时间基准对不上,会出现填到
                    // 一半就卡住的现象。
                    let currentMs = (poller.anchor?.extrapolatedPositionMs(now: context.date) ?? 0) + poller.currentLyricsOffsetMs
                    HStack(spacing: 0) {
                        ForEach(Array(words.enumerated()), id: \.offset) { _, w in
                            wordText(w, atMs: currentMs)
                        }
                    }
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                }
            } else if poller.isPlayingNow && !poller.hasLyricsContent {
                // 同 LyricsOverlayView.mainLine 的区分:currentLine==nil 可能是"还没解析
                // 出这首歌的歌词"(collector 后台搜索中,见 poller.hasLyricsContent 注释),
                // 不能跟"这首歌真没歌词/正在间奏"共用同一个♪占位符。
                Text(L10n.t("搜索歌词中…"))
                    .foregroundStyle(.white.opacity(0.7))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
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

    // hover 展开时多出来的这一块——下一句歌词预览 + 迷你进度条,用来强化"这是个歌词类
    // 产品"而不是退化成通用媒体控制器;进度条属于"有余量就加"的加分项。
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

    private var nextLineDisplayText: String {
        poller.nextLineText ?? ""
    }

    private static func timeString(ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    // ⚠️ 必须用 checkForCurrentPlayerSafely(异步),不能用同步版本——理由跟
    // LyricsOverlayView.swift 同名方法的注释一致:同步版本在还没问过时会直接触达有据
    // 可查、可能永久挂起主线程的系统 API。权限不够时用 NSSound.beep() 给一个"没有
    // 生效"的听觉反馈(2026-08-02 补上,跟另外两处播放控制入口保持一致),不静默无声。
    private func controlButton(_ systemName: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            Task {
                guard await MusicAutomationPermission.checkForCurrentPlayerSafely(askIfNeeded: true) else {
                    NSSound.beep()
                    return
                }
                action()
            }
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

// 超长文字(歌名/歌词)靠自动来回滚动展示全部内容,而不是硬截断/省略号。测量内容
// 真实宽度 vs 容器宽度,只有真的溢出容器时才滚动,没溢出的短文字保持静止不动、不
// 产生任何动画。滚动方式是"停顿→滚到底→停顿→滚回起点"来回滚动,不是无限单向卷动,
// 不需要为了卷动无缝衔接去复制一份内容拼接。
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
                // 垂直居中——GeometryReader 默认把内容摆在自己左上角,不居中的话文字
                // 会紧贴着这一整行的顶边。
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
