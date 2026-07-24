import SwiftUI
import LyrimuseCore

// 悬浮窗内容:逐字高亮时用渐变扫过效果(近似网页版 CSS 渐变裁字的视觉,不追求逐像素
// 还原),否则整行高亮;罗马音在上、译文在下,都是可选的小字。
//
// 换行不做任何动画(纯属性跳变,不经过 SwiftUI 动画事务),逐字填色用 TimelineView
// 按渲染帧频直接从播放位置现算 fillFraction(不经过 Timer 采样+插值)——两者都是为了
// 尽可能流畅、开销尽可能小,具体机制见下面 mainLine/wordText 的注释。
struct LyricsOverlayView: View {
    @ObservedObject private var poller = PlaybackCoordinator.shared
    @ObservedObject private var settings = AppSettings.shared

    // 悬浮窗高度跟着内容动态变化(见 LyricsOverlayWindowController.updateHeight)——这里
    // 汇报"这次渲染实际需要多高",不需要就什么都不做(默认空闭包,方便预览/测试构造)。
    var onContentHeightChange: (CGFloat) -> Void = { _ in }

    // 固定值,不是设置项——加一个圆角纯粹是给"背景颜色"这个设置配套的实现细节,免得
    // 用户一开背景色看到的是个生硬的直角矩形;两个参考的开源实现里圆角都不是用户可调项。
    private let overlayBackgroundCornerRadius: CGFloat = 16

    // 鼠标悬停才浮现播放控制按钮,不用一直占地方。仅在"锁定位置"关闭时生效——锁定后
    // window.ignoresMouseEvents 已经让整个窗口不再接收鼠标事件,.onHover 本来就不会被
    // 调用;这里在 View 层再显式判断一遍 lockPosition,不单纯依赖窗口层那一处副作用。
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
            // 用一条竖线跟前面三个播放按钮分组,提示这是不同类别的操作。点了之后
            // settings.lockPosition 变 true,这一整排控制按钮(包括它自己)会立刻消失
            // (见 body 里 isHoveringForControls && !settings.lockPosition 那个条件)。
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

    // "没在播放"要不要隐藏,完全交给 hideWhenNotPlaying 那个开关(见
    // LyricsOverlayWindowController)决定——这里不重复处理,否则两条路径同时生效会分不清
    // 究竟是谁在起作用,看起来像开关失灵。
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
            // 逐字填色用 TimelineView(.animation) 按渲染帧频直接从 poller.anchor 外推
            // 播放位置,每帧现算 fillFraction,不经过 @Published 值 + .animation() 插值
            // ——SwiftUI 对 .linear 这类曲线动画在重新定目标时是矢量相加而不是从当前值
            // 接续,高频率更新下会造成逐字流转卡顿。暂停时 anchor 会变 nil(见 fastTick
            // 守卫),TimelineView 的 paused 参数顺带把这个子树的刷新也停下来。
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
                // compositingGroup 把这一整行字先合成成一张位图再统一套一次阴影——如果
                // 每个字的 Text 各自单独 .shadow(),SwiftUI 会当成互相独立的半透明图层
                // 分别渲染,相邻字阴影重叠的区域会叠加变暗,整行看起来深浅不均。合成后
                // 阴影只按最终轮廓算一次,顺带把 O(字数) 次阴影合成降到 O(1)。
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
        } else if poller.isPlayingNow && !poller.hasLyricsContent {
            // 换到一首还没解析过的新歌,collector 后台搜索通常要几秒——这段空窗期跟"这首
            // 歌确实没有歌词/正在间奏"共用同一个 currentLine==nil,但含义完全不同,不能
            // 都糊成一个♪符号,容易让人以为"这首歌就是没词",见 poller.hasLyricsContent
            // 注释。
            Text(L10n.t("搜索歌词中…"))
                .font(settings.mainFont)
                .foregroundStyle(settings.foregroundColor.opacity(0.5))
                .lyricsTextStroke(settings.textStrokeEnabled, color: settings.textStrokeColor)
        } else {
            Text("♪")
                .font(settings.mainFont)
                .foregroundStyle(settings.foregroundColor.opacity(0.3))
                .lyricsTextStroke(settings.textStrokeEnabled, color: settings.textStrokeColor)
        }
    }

    // 逐字时长下限——只影响这一个词自己的填色速度,不改 startMs、不影响下一个词何时
    // 开始。英文歌词(NetEase/QQ/酷狗给的逐字对齐)比中文更容易出现 durationMs==0 或
    // 几十毫秒的极短词(介词/冠词一类),硬边界瞬间 0→1 在这种词密集的句子里会显得更"跳"。
    private static let minWordDurationMs = 80
    // 过渡带半宽(fraction 单位)——真正需要柔化的只是"刚好唱到/刚好唱完"这个边界附近
    // 一小段,不是整个 [0,1] 区间。
    private static let wordEdgeSoftenBand = 0.08

    // 故意不夹到 [0,1]——如果夹住,"还没轮到、离真正唱到还有好几个字/好几句"的词会
    // 全都被夹成跟"刚好唱到这个词最前一刻"相同的 0,wordText 里的过渡带因此会在每一个
    // 尚未唱到的词开头误算出一小截"已经唱过"的高亮(英文按整词分词,这一小截宽度恰好
    // 接近首字母宽度,表现成"还没唱到的词首字母却先带了点颜色";中文逐字分词单位更小,
    // 同样误差没那么显眼,但机制相通)。真正需要的裁剪挪到 wordGradient 里,按"过渡带
    // 跟 [0,1] 是否有交集"分情况处理。
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
// 描边参考 katagaki/DJDX(View Modifiers/TextStroke.swift)的做法:content 先
// .blur(radius:) 让字形轮廓往外"胀"开一圈,Canvas 里用 .addFilter(.alphaThreshold(min:))
// 把这层模糊的 alpha 通道硬切成非 0 即 1,拿这个剪影当 mask 盖一层纯色矩形垫在原始文字
// (不模糊、保留自己的渐变/颜色)下面当描边。这个技术只需要文字的"形状"(alpha 通道),
// 不关心文字本身画的是纯色还是渐变,所以能像阴影一样整体套在 mainLine 外面一次搞定,
// 不需要对每个字分别处理;开销是固定的"整体渲染一遍 + 一次模糊 + 一次阈值",不随描边
// 粗细变化。备选的"N 个方向各偏移一份内容再叠加"写法更简单,但每多一个方向就多渲染一份
// 完整内容,用在这里(mainLine 是 60fps 逐字填色的热路径)会造成 N 倍重复开销,故未采用。
private struct OptionalTextStroke: ViewModifier {
    let enabled: Bool
    let color: Color
    // 固定常量,不做成 Settings 可调项——只给颜色选择器,粗细留在代码里,参考 LyricsX
    // 同款克制。1.2pt 在这个项目常用的歌词字号下是一圈清晰但不臃肿的细描边。
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
