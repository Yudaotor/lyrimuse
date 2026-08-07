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
    // 悬停展示控制按钮/长按拖动这套手势整个搬到了 WindowController 用全局鼠标监听器
    // 实现(背景常年点击穿透,原生 .onHover 收不到事件),这里只读它算出来的结果
    // (isHoveringForControls/isDragArmed)展示对应视觉效果,不再自己维护 @State。
    //
    // 故意不写成 "= LyricsOverlayWindowController.shared" 默认值——这个 View 正是在
    // LyricsOverlayWindowController 自己的 init() 里被构造出来的(装进 NSHostingView),
    // 这时候 .shared 这个 static let 的一次性初始化(dispatch_once)还没跑完,任何在这个
    // 构造过程中对 .shared 的再次访问都会在同一线程递归触发同一个 dispatch_once,被
    // 系统直接判定成非法重入而 SIGTRAP 崩溃(实测坐实:EXC_BREAKPOINT,栈顶正是
    // _dispatch_once_wait 卡在这个默认值上)。改成必填参数,由外部显式传入当时已经
    // 拿到手的 self,不再经过 .shared 这层。
    // 不加 private——需要在另一个文件(LyricsOverlayWindowController.swift)里通过
    // 编译器合成的 memberwise init 传入,标 private 会让那个 init 的访问级别一并降到
    // private,导致跨文件调不到。
    @ObservedObject var overlayController: LyricsOverlayWindowController

    // 悬浮窗高度跟着内容动态变化(见 LyricsOverlayWindowController.updateHeight)——这里
    // 汇报"这次渲染实际需要多高",不需要就什么都不做(默认空闭包,方便预览/测试构造)。
    var onContentHeightChange: (CGFloat) -> Void = { _ in }
    // 播放控制按钮胶囊的实际屏幕矩形,汇报给 WindowController 当作"点击穿透的例外热区"
    // ——只有落在这个矩形里的鼠标事件才会被窗口正常接收,其它任何地方(包括歌词文字
    // 本身)永远穿透。按钮没显示时(锁定/未悬停)报 .zero。
    var onControlsFrameChange: (CGRect) -> Void = { _ in }

    // 固定值,不是设置项——加一个圆角纯粹是给"背景颜色"这个设置配套的实现细节,免得
    // 用户一开背景色看到的是个生硬的直角矩形;两个参考的开源实现里圆角都不是用户可调项。
    private let overlayBackgroundCornerRadius: CGFloat = 16
    private let overlayCoordSpaceName = "overlayContent"

    // 播放控制排该不该显示:悬停中、且没锁定位置。抽成计算属性是因为下面有三处要用同一个
    // 判断(可见性、是否接受点击、热区要不要上报),散开写容易改漏其中一处。
    private var controlsVisible: Bool {
        overlayController.isHoveringForControls && !settings.lockPosition
    }

    var body: some View {
        // ⚠️ 按钮排在**歌词卡片上方**,而且**槽位常驻**(不显示时只是透明+不接受点击),两点缺一
        // 不可,原因分别是:
        //
        // 1) 放上方是用户 2026-08-07 明确要的。但如果照旧写成 `if controlsVisible { ... }`
        //    再放在歌词前面,按钮一出现就会把下面的歌词整个往下推 —— 那正是刚修掉的"悬停时
        //    歌词跳动"的反向版本(见下面 .frame(maxHeight:alignment:.top) 那段注释)。槽位常驻
        //    之后内容高度恒定,歌词的位置跟悬不悬停完全无关。
        // 2) 按钮排放在卡片**外面**而不是塞进卡片里:它自己已经是一个独立的深色胶囊
        //    (见 playbackControls 的 .background(.black.opacity(0.55), in: Capsule())),不需要
        //    借歌词卡片的背景。放外面还有个实际好处 —— 常驻槽位那块空白落在卡片之外,
        //    "深色卡片/浅色卡片"这类有可见背景的主题不会在卡片顶部多出一条空带。
        VStack(spacing: 0) {
            playbackControls
                .opacity(controlsVisible ? 1 : 0)
                // 不显示时不接受点击 —— 槽位虽然常驻,但那时它必须对鼠标完全透明,否则会
                // 在歌词上方挖出一块"看不见却挡手"的区域。
                .allowsHitTesting(controlsVisible)
                // 把这排按钮的真实位置汇报上去,当作点击穿透的例外热区(见
                // WindowController.updateControlsHotZone)。不显示时上报 .zero,让整扇窗口
                // 恢复全区域穿透 —— 以前靠"这个视图根本不存在"来达到同样效果,现在槽位常驻,
                // 得显式报零。
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ControlsFramePreferenceKey.self,
                            value: controlsVisible ? proxy.frame(in: .named(overlayCoordSpaceName)) : .zero
                        )
                    }
                )
            lyricsCard
        }
        .coordinateSpace(name: overlayCoordSpaceName)
        // 纯测量用,不影响视觉——把这次渲染真正需要的高度(按钮槽位+歌词卡片)报给窗口控制器
        // 去调整窗口高度,长歌词换行到第二行时窗口跟着变高,而不是被原来写死的高度裁掉。
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ContentHeightPreferenceKey.self) { onContentHeightChange($0) }
        .onPreferenceChange(ControlsFramePreferenceKey.self) { onControlsFrameChange($0) }
        .animation(.easeOut(duration: 0.16), value: controlsVisible)
        .animation(.easeOut(duration: 0.3), value: overlayController.showDragHint)
        // ⚠️ 内容必须**贴着窗口顶边**放,不能让它在窗口里居中。
        //
        // 在这一行之前,根视图只约束了宽度,高度就是内容的固有高度;而窗口高度有 120pt 的
        // 地板(updateHeight 里的 max(overlayDefaultHeight, …)),单行歌词的内容比它矮不少。
        // NSHostingView 比内容高的时候,SwiftUI 默认把内容**垂直居中**放 —— 于是内容高度一变,
        // 整块内容(连同歌词文字)就会在窗口里上下移动半个差值。
        //
        // 2026-08-07 用独立的 SwiftUI 沙盒逐像素量过(同样的修饰符链 + 固定 120pt 宿主):
        //   居中(改前):静止时内容顶边距窗口顶 30.0pt,内容变高后 17.0pt —— 上移 13pt
        //   贴顶(改后):两种状态都是 0.0pt —— 纹丝不动
        //
        // 贴顶还顺带修正了一处隐含假设:updateControlsHotZone 把控制排的坐标从
        // overlayCoordSpaceName 换算成窗口坐标时用的是 `window.frame.height - rect.maxY`,
        // 这只有在"内容块顶边 == 窗口顶边"时才成立。内容居中时这个前提在内容高<120 的情况下
        // 是破的;贴顶之后它才真正永远成立。
        //
        // 必须加在所有 background/测量修饰符**之后**:加在前面的话,那个测内容高度的
        // GeometryReader 量到的会变成整个窗口高度,updateHeight 就再也收不到真实内容高度了。
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var lyricsCard: some View {
        VStack(spacing: 4) {
            if settings.showRomanization, let roma = poller.currentLine?.romanization {
                Text(roma)
                    .font(settings.romanizationFont)
                    .foregroundStyle(poller.displayForegroundColor.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true) // 允许换行时如实撑高,不被裁掉
                    .lyricsTextStroke(settings.textStrokeEnabled, color: settings.textStrokeColor)
            }
            mainLine
            if settings.showTranslation, let tr = poller.currentLine?.translation {
                Text(tr)
                    .font(settings.translationFont)
                    .foregroundStyle(poller.displayForegroundColor.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .lyricsTextStroke(settings.textStrokeEnabled, color: settings.textStrokeColor)
            }
            if settings.showNextLinePreview, let next = poller.nextLineText {
                Text(next)
                    .font(settings.previewFont)
                    .foregroundStyle(poller.displayForegroundColor.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
                    .lyricsTextStroke(settings.textStrokeEnabled, color: settings.textStrokeColor)
            }
            // 2026-08-02 补上——第一次解锁「锁定位置」时短暂弹一次的手势提示,4 秒后
            // 自动消失,只弹一次(见 LyricsOverlayWindowController.hasShownDragHintKey
            // 处的注释)。放在播放控制按钮上面同一个位置,不额外占用固定空间。
            if overlayController.showDragHint {
                Text(L10n.t("长按即可拖动位置"))
                    .font(.caption)
                    .foregroundStyle(poller.displayForegroundColor.opacity(0.8))
                    .lyricsTextStroke(settings.textStrokeEnabled, color: settings.textStrokeColor)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(overlayBackground)
        // 长按拖动"武装"后的视觉提示——一圈跟前景色同色的高亮描边,松手/取消立刻淡出。
        .overlay(
            RoundedRectangle(cornerRadius: overlayBackgroundCornerRadius, style: .continuous)
                .stroke(poller.displayForegroundColor.opacity(overlayController.isDragArmed ? 0.6 : 0), lineWidth: 2)
        )
        .multilineTextAlignment(.center)
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
        // 2026-08-07 这排按钮挪到歌词卡片**上方**之后,这 4pt 的间距也跟着从 .top 翻到
        // .bottom —— 它要隔开的一直是"按钮胶囊和歌词卡片之间"那道缝。
        .padding(.bottom, 4)
    }

    // 跟 GlobalHotkeys.swift 里播放控制三个动作同一套"点了才校验权限"逻辑——没问过就
    // 顺手弹一次系统授权对话框,已经拒绝过就用 NSSound.beep() 给一个"没有生效"的听觉
    // 反馈,不需要在悬浮窗里再单独设计一套提示 UI(2026-08-02 补上,理由跟
    // GlobalHotkeys.swift 同一处注释一致)。只有选了 Apple Music 才真的会走到这个
    // 权限检查,见 MusicAutomationPermission.checkForCurrentPlayer 注释。
    //
    // ⚠️ 必须用 checkForCurrentPlayerSafely(异步)——理由见该方法定义处的注释:同步版本
    // 在还没问过时会直接触达有据可查、可能永久挂起主线程的系统 API。iconButton 的
    // action 是同步闭包(Button(action:) 要求),用 Task { ... } 包一层去调用异步版本。
    private func controlButton(_ systemName: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        iconButton(systemName, primary: primary) {
            Task {
                guard await MusicAutomationPermission.checkForCurrentPlayerSafely(askIfNeeded: true) else {
                    NSSound.beep()
                    return
                }
                action()
            }
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
                // 加上 currentLyricsOffsetMs——activeLine/activeLineIndex(决定"现在是哪一
                // 行哪个词")内部已经把 offsetMs 加进判断了,这里如果不加同一个偏移量,
                // "被判定成当前词"用的时间基准跟"这个词该填多满"用的时间基准就对不上:
                // 词提前变成"当前词"了,但填色进度还是按未校正的原始位置算,会出现填到一半
                // 就卡住、然后突然跳到下一个词从 0 开始的现象(2026-08-03 用户反馈实测坐实)。
                let currentMs = (poller.anchor?.extrapolatedPositionMs(now: context.date) ?? 0) + poller.currentLyricsOffsetMs
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
                .foregroundStyle(poller.displayForegroundColor)
                .fixedSize(horizontal: false, vertical: true)
                .lyricsTextStroke(settings.textStrokeEnabled, color: settings.textStrokeColor)
        } else if poller.isCurrentTrackAdBreak {
            // 2026-08-03 补上——Spotify 广告插播,同样要排在"还在搜索中"分支前面:广告
            // 的标题/歌手永远不会被写进歌词缓存(见 collector/enrich.go
            // trackEnrichment 的对应守卫),hasLyricsContent 永远拿不到内容,不排在
            // 前面的话会在整段广告期间一直显示"搜索歌词中…",见
            // poller.isCurrentTrackAdBreak 定义处的注释。
            Text(L10n.t("广告中"))
                .font(settings.mainFont)
                .foregroundStyle(poller.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(settings.textStrokeEnabled, color: settings.textStrokeColor)
        } else if poller.isCurrentTrackInstrumental {
            // 2026-08-03 补上——联网查过了、明确是纯音乐,跟下面"还在搜索中"/"真的没搜到"
            // 两种含糊状态不一样,是有明确依据的结论,必须排在"还在搜索中"这个分支前面:
            // 不然这个分支会先命中、一直显示"搜索歌词中…",纯音乐的歌只要还在播放就永远
            // 到不了这里,见 poller.isCurrentTrackInstrumental 定义处的注释。
            Text(L10n.t("纯音乐"))
                .font(settings.mainFont)
                .foregroundStyle(poller.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(settings.textStrokeEnabled, color: settings.textStrokeColor)
        } else if poller.isPlayingNow && !poller.hasLyricsContent {
            // 换到一首还没解析过的新歌,collector 后台搜索通常要几秒——这段空窗期跟"这首
            // 歌确实没有歌词/正在间奏"共用同一个 currentLine==nil,但含义完全不同,不能
            // 都糊成一个♪符号,容易让人以为"这首歌就是没词",见 poller.hasLyricsContent
            // 注释。
            Text(L10n.t("搜索歌词中…"))
                .font(settings.mainFont)
                .foregroundStyle(poller.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(settings.textStrokeEnabled, color: settings.textStrokeColor)
        } else {
            Text("♪")
                .font(settings.mainFont)
                .foregroundStyle(poller.displayForegroundColor.opacity(0.3))
                .lyricsTextStroke(settings.textStrokeEnabled, color: settings.textStrokeColor)
        }
    }

    // 软边渐变算法本体抽到 WordKaraokeGradient(悬浮歌词/歌词窗口共用,见该文件顶部
    // 注释),这里只负责从 settings 取用户配置的前景色、算出这个字的当前进度,两者
    // 传给共享算法。
    private func wordText(_ w: SyncedLyricWord, atMs currentMs: Int) -> some View {
        let fg = poller.displayForegroundColor
        let fraction = WordKaraokeGradient.fillFraction(for: w, atMs: currentMs)
        let band = WordKaraokeGradient.wordEdgeSoftenBand
        return Text(w.text)
            .foregroundStyle(WordKaraokeGradient.gradient(fg: fg, left: fraction - band, right: fraction + band))
            // 故意不再包 .animation(...)——TimelineView(.animation) 已经在按渲染帧频
            // 重算真值,这里再叠一层 SwiftUI Animation 补间只会重新引入 mainLine 注释里
            // 那套矢量叠加问题。也故意不在这里单独套描边——描边统一挪到 mainLine 里
            // WrapLayout 外层的 .compositingGroup()+.lyricsTextStroke(),见那边注释。
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

// 播放控制按钮胶囊没显示时(锁定/未悬停),树里没有任何视图写这个 preference,最终值
// 落回 .zero——WindowController 那边按"是不是零矩形"判断当前有没有热区。
private struct ControlsFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
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
// 2026-07-31 从 private 改成 internal:纯几何计算的自定义换行布局,不依赖这个文件里
// 任何其它状态,"歌词窗口"(UI/LyricsWindowView.swift)复用它给当前行的逐字高亮做
// 换行,不需要另起一份重复实现——同一个 target 内跨文件访问,行为对这里的悬浮窗
// 零影响。
struct WrapLayout: Layout {
    // 行内的水平对齐——悬浮歌词/灵动岛是居中排版(默认值,行为不变);"歌词窗口"2026-08-04
    // 改成 Apple Music 歌词页同款的左对齐排版后传 .leading。
    enum RowAlignment { case center, leading }

    var horizontalSpacing: CGFloat = 0
    var verticalSpacing: CGFloat = 2
    var rowAlignment: RowAlignment = .center

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
            var x = bounds.minX + (rowAlignment == .center ? max(0, (bounds.width - row.width) / 2) : 0) // 按 rowAlignment 居中/靠左
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
