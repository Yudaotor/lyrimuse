import SwiftUI
import Combine
import LyrimuseCore

/// 悬浮歌词的**窄订阅代理**(2026-08-19 性能审计落地,照「歌词管理」LiveRowPlayback 的
/// 既有模式):PlaybackCoordinator 有 30+ 个 @Published、AppSettings 有 40+ 个,而
/// ObservableObject 的 objectWillChange 不分字段 —— 悬浮窗原来整对象订阅这两个单例,
/// 歌词窗口拖音量滑杆(soundVolume)、灵动岛/歌词窗口专属的封面与统计、设置页那几个
/// 与悬浮窗无关的宽度滑杆,每一次写入都会打醒它整个 body。这里只转发悬浮窗真正读的
/// 字段,值类型一律 removeDuplicates。
///
/// ⚠️ sink 里只能用收到的参数值,不能回读源属性 —— @Published 在 willSet 时机发布,
/// 回读拿到的是上一拍的旧值(本仓在 hideWhenNotPlaying 上实测踩过)。
///
/// anchor / currentLyricsOffsetMs 故意**不在**这里:它们只被 TimelineView 的每帧闭包
/// 消费,闭包按帧重跑、自己直读 PlaybackCoordinator.shared 就是最新值;订阅只会让
/// 重锚/校准这类事件多打醒一次整个 body(同 LiveRowPlayback 对 anchor 的处理)。
@MainActor
private final class OverlayPlayback: ObservableObject {
    // ---- 来自 PlaybackCoordinator ----
    @Published private(set) var currentLine: SyncedLyricLine?
    @Published private(set) var nextLineText: String?
    @Published private(set) var isPlayingNow = false
    @Published private(set) var isFavorited: Bool?
    @Published private(set) var hasLyricsContent = false
    @Published private(set) var isCurrentTrackInstrumental = false
    @Published private(set) var currentTrackHasNoLyrics = false
    @Published private(set) var collectorNetworkDown = false
    @Published private(set) var isCurrentTrackAdBreak = false
    @Published private(set) var currentLineFillSettled = true
    /// 悬浮歌词实际显示用的前景色 —— 语义同 PlaybackCoordinator.displayForegroundColor
    /// (那份保留给设置页预览等别处),这里预组合成单个去重值:三个输入(动态高亮色/
    /// "跟随封面"开关/手选前景色)任何一个变了才发一次。
    @Published private(set) var displayForegroundColor: Color = .white
    // ---- 来自 AppSettings(只挑悬浮窗读的这一小片) ----
    @Published private(set) var lockPosition = false
    @Published private(set) var showRomanization = true
    @Published private(set) var showTranslation = false
    @Published private(set) var showNextLinePreview = true
    @Published private(set) var mainFont: Font = .system(size: 20, weight: .bold)
    @Published private(set) var romanizationFont: Font = .system(size: 13, weight: .medium)
    @Published private(set) var translationFont: Font = .system(size: 14, weight: .regular)
    @Published private(set) var previewFont: Font = .system(size: 14, weight: .medium)
    @Published private(set) var textStrokeEnabled = false
    @Published private(set) var textStrokeColor: Color = .black.opacity(0.65)
    @Published private(set) var backgroundIsVisible = false
    @Published private(set) var backgroundColor: Color = .clear
    private var subs: [AnyCancellable] = []

    init() {
        let p = PlaybackCoordinator.shared
        let s = AppSettings.shared
        subs = [
            p.$currentLine.removeDuplicates().sink { [weak self] in self?.currentLine = $0 },
            p.$nextLineText.removeDuplicates().sink { [weak self] in self?.nextLineText = $0 },
            p.$isPlayingNow.removeDuplicates().sink { [weak self] in self?.isPlayingNow = $0 },
            p.$isFavorited.removeDuplicates().sink { [weak self] in self?.isFavorited = $0 },
            p.$hasLyricsContent.removeDuplicates().sink { [weak self] in self?.hasLyricsContent = $0 },
            p.$isCurrentTrackInstrumental.removeDuplicates().sink { [weak self] in self?.isCurrentTrackInstrumental = $0 },
            p.$currentTrackHasNoLyrics.removeDuplicates().sink { [weak self] in self?.currentTrackHasNoLyrics = $0 },
            p.$collectorNetworkDown.removeDuplicates().sink { [weak self] in self?.collectorNetworkDown = $0 },
            p.$isCurrentTrackAdBreak.removeDuplicates().sink { [weak self] in self?.isCurrentTrackAdBreak = $0 },
            p.$currentLineFillSettled.removeDuplicates().sink { [weak self] in self?.currentLineFillSettled = $0 },
            Publishers.CombineLatest3(p.$artworkAccentColor, s.$followsCoverArt, s.$foregroundColor)
                .map { accent, follows, fg in (follows ? accent : nil) ?? fg }
                .removeDuplicates()
                .sink { [weak self] in self?.displayForegroundColor = $0 },
            s.$lockPosition.removeDuplicates().sink { [weak self] in self?.lockPosition = $0 },
            s.$showRomanization.removeDuplicates().sink { [weak self] in self?.showRomanization = $0 },
            s.$showTranslation.removeDuplicates().sink { [weak self] in self?.showTranslation = $0 },
            s.$showNextLinePreview.removeDuplicates().sink { [weak self] in self?.showNextLinePreview = $0 },
            s.$mainFont.removeDuplicates().sink { [weak self] in self?.mainFont = $0 },
            s.$romanizationFont.removeDuplicates().sink { [weak self] in self?.romanizationFont = $0 },
            s.$translationFont.removeDuplicates().sink { [weak self] in self?.translationFont = $0 },
            s.$previewFont.removeDuplicates().sink { [weak self] in self?.previewFont = $0 },
            s.$textStrokeEnabled.removeDuplicates().sink { [weak self] in self?.textStrokeEnabled = $0 },
            s.$textStrokeColor.removeDuplicates().sink { [weak self] in self?.textStrokeColor = $0 },
            s.$backgroundIsVisible.removeDuplicates().sink { [weak self] in self?.backgroundIsVisible = $0 },
            s.$backgroundColor.removeDuplicates().sink { [weak self] in self?.backgroundColor = $0 },
        ]
    }
}

// 悬浮窗内容:逐字高亮时用渐变扫过效果(近似网页版 CSS 渐变裁字的视觉,不追求逐像素
// 还原),否则整行高亮;罗马音在上、译文在下,都是可选的小字。
//
// 换行不做任何动画(纯属性跳变,不经过 SwiftUI 动画事务),逐字填色用 TimelineView
// 按渲染帧频直接从播放位置现算 fillFraction(不经过 Timer 采样+插值)——两者都是为了
// 尽可能流畅、开销尽可能小,具体机制见下面 mainLine/wordText 的注释。
struct LyricsOverlayView: View {
    // 不直接 @ObservedObject 整个 PlaybackCoordinator/AppSettings —— 见 OverlayPlayback
    // 的注释,那两个单例上与悬浮窗无关的高频写入会打醒整个 body。
    @StateObject private var playback = OverlayPlayback()
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
    /// 胶囊里每个按钮各自的矩形(overlayContent 命名坐标空间)。窗口常年点击穿透,
    /// SwiftUI 收不到鼠标事件,点击由控制器按这些矩形自己分发 —— 见
    /// LyricsOverlayWindowController.performControlAction。
    var onControlRectsChange: ([OverlayControlID: CGRect]) -> Void = { _ in }

    // 固定值,不是设置项——加一个圆角纯粹是给"背景颜色"这个设置配套的实现细节,免得
    // 用户一开背景色看到的是个生硬的直角矩形;两个参考的开源实现里圆角都不是用户可调项。
    private let overlayBackgroundCornerRadius: CGFloat = 16
    private let overlayCoordSpaceName = "overlayContent"

    // 播放控制排该不该显示:悬停中、且没锁定位置。抽成计算属性是因为下面有三处要用同一个
    // 判断(可见性、是否接受点击、热区要不要上报),散开写容易改漏其中一处。
    private var controlsVisible: Bool {
        overlayController.isHoveringForControls && !playback.lockPosition
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
                // WindowController.updateControlsHotZone)。
                //
                // ⚠️ 这里**永远报真实矩形**,不能写成"没显示时报 .zero"来兼表可见性。
                // 2026-08-07 实测坐实:那样写的话观察者收到的恒为 .zero —— 这个 key 的
                // reduce 是"后来者覆盖",而树里别的分支(外层那个测高度的 background 里的
                // Color.clear)会贡献 defaultValue(.zero)并排在后面,把真实矩形冲掉。
                // 日志里能直接看到两行并排:GeometryReader 算出 (341.5,0.1,217,48),
                // 而 onPreferenceChange 收到 (0,0,0,0)。
                // 现在 .zero 只有一个含义 ——"这一轮没有任何人报告位置",可见性判断挪到
                // 控制器侧(见 handleMouseEvent 里的 controlsShown)。
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ControlsFramePreferenceKey.self,
                            value: proxy.frame(in: .named(overlayCoordSpaceName))
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
        .onPreferenceChange(ControlRectsPreferenceKey.self) { onControlRectsChange($0) }
        .animation(.easeOut(duration: 0.16), value: controlsVisible)
        .animation(.easeOut(duration: 0.3), value: overlayController.showDragHint)
        // 控制排每次露出来时重读一次"喜欢"状态。这条状态不跟着 2 秒轮询走(每次读要起一个
        // osascript 子进程,为一个几乎不变的布尔值那么干不值当),换歌时刷一次之外,就靠这里
        // ——正好覆盖"用户刚在 Music.app 里自己点了心、回头来看悬浮窗"这种情况。
        .onChange(of: controlsVisible) { _, visible in
            if visible { PlaybackCoordinator.shared.refreshFavorited() }
        }
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

    /// 对唱歌词的左右分栏(见 LyricDuet)。
    ///
    /// nil = 这首歌没有演唱者标记(绝大多数歌),按悬浮窗原本的排版走 —— **居中**。
    /// 跟歌词窗口的兜底不一样,所以引擎里那个字段是可选的:把"没信息"和"左边那位"混成
    /// 同一个值,这里每一首普通歌都会莫名从居中变成靠左。
    private var duetSide: LyricDuet.Side { playback.currentLine?.side ?? .center }

    private var duetAlignment: HorizontalAlignment {
        switch duetSide {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private var duetTextAlignment: TextAlignment {
        switch duetSide {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private var duetRowAlignment: WrapLayout.RowAlignment {
        switch duetSide {
        case .leading: return .leading
        case .trailing: return .trailing
        case .center: return .center
        }
    }

    private var lyricsCard: some View {
        VStack(alignment: duetAlignment, spacing: 4) {
            mainLine
            // 罗马音在**歌词下面、译文上面**。2026-08-17 从歌词上面挪下来 —— 歌词窗口
            // (LyricsWindowView)早就是这个顺序了,这里是漏改的那一处,同一首歌只要解析不出
            // 词组就会跳到上面显示,四种组合里唯一的异类。
            //
            // 为什么是下面(调研结论):这里标的是**罗马字/音译**,不是注音。注音(furigana、
            // 拼音)是给"认得这套字、只是不确定读音"的读者用的,绑到单个字符,惯例在上方
            // (CSS ruby-position 默认 over);而音译是给"根本不认得这套字"的人跟着唱的,
            // 是一条跟译文并列的平行文本行,惯例在下方 —— 维基百科 Furigana 条目里唯一提到
            // 罗马字位置的例子(西武铁道站牌)也是把罗马字放在汉字下面。
            //
            // 三种语言统一放下面,不按语言分叉:① 韩文压根没有 ruby 传统(W3C 那份 ruby 文档
            // 从头到尾没提韩文 —— 谚文本身表音,韩国读者不需要注音),没有"上方"惯例可继承;
            // ② 中文拼音**作为注音**惯例确实在上方,但这里是音译,而且中文罗马音默认是关的
            // (见 RomanizationScripts.default 的注释);③ K-pop 中日韩英混唱很常见,位置随
            // 语言变会让同一屏内上下不一致。
            //
            // 有逐词标注(perWordRomanization)时,读音已经标在每个词的正下方了,这一整行
            // 就不再重复一遍。
            if playback.showRomanization, !usesPerWordRomanization,
                let roma = playback.currentLine?.romanization
            {
                Text(roma)
                    .font(playback.romanizationFont)
                    .foregroundStyle(playback.displayForegroundColor.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true) // 允许换行时如实撑高,不被裁掉
                    .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
            }
            if playback.showTranslation, let tr = playback.currentLine?.translation {
                Text(tr)
                    .font(playback.translationFont)
                    .foregroundStyle(playback.displayForegroundColor.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
            }
            if playback.showNextLinePreview, let next = playback.nextLineText {
                Text(next)
                    .font(playback.previewFont)
                    .foregroundStyle(playback.displayForegroundColor.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
                    .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
            }
            // 2026-08-02 补上——第一次解锁「锁定位置」时短暂弹一次的手势提示,4 秒后
            // 自动消失,只弹一次(见 LyricsOverlayWindowController.hasShownDragHintKey
            // 处的注释)。放在播放控制按钮上面同一个位置,不额外占用固定空间。
            if overlayController.showDragHint {
                Text(L10n.t("长按即可拖动位置"))
                    .font(.caption)
                    .foregroundStyle(playback.displayForegroundColor.opacity(0.8))
                    .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
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
                .stroke(playback.displayForegroundColor.opacity(overlayController.isDragArmed ? 0.6 : 0), lineWidth: 2)
        )
        // 对唱歌词按演唱者分左右(2026-08-14)。不带标记的歌 duetSide 恒为 .center,
        // 跟原来完全一致。
        .multilineTextAlignment(duetTextAlignment)
    }

    private var playbackControls: some View {
        HStack(spacing: 18) {
            iconButton(.previous, "backward.fill")
            iconButton(.playPause, playback.isPlayingNow ? "pause.fill" : "play.fill", primary: true)
            iconButton(.next, "forward.fill")
            // 「喜欢」——对应 Apple Music 里那颗心(脚本字典里的 favorited)。只有 Apple Music
            // 有这个概念,所以 playback.isFavorited 为 nil(别的播放器/没拿到自动化权限)时整个
            // 按钮不出现,而不是显示一颗永远点不亮的心。跟前面三个播放按钮同属"对当前这首歌
            // 的操作",放在同一组里、竖线之前。
            //
            // 不走 controlButton:那个包装是为播放控制准备的(先查权限、被拒就 NSSound.beep()),
            // 而这里的权限检查和乐观更新都在 PlaybackCoordinator.toggleFavorited() 里一起做了,再套一层会
            // 变成查两遍权限。
            if let favorited = playback.isFavorited {
                // .help() 去掉了:窗口常年点击穿透,SwiftUI 连 hover 都收不到,那个 tooltip
                // 永远不会弹出来 —— 留着只是一段看起来有效、其实永不触发的死代码。
                // (同一对文案在「歌词窗口」那颗心上仍在用,本地化条目不受影响。)
                iconButton(.favorite, favorited ? "heart.fill" : "heart")
                    .foregroundStyle(favorited ? Color.red : Color.white)
            }
            // 用一条竖线跟前面三个播放按钮分组,提示这是不同类别的操作。点了之后
            // playback.lockPosition 变 true,这一整排控制按钮(包括它自己)会立刻消失
            // (见 body 里 isHoveringForControls && !playback.lockPosition 那个条件)。
            Rectangle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 1, height: 16)
            iconButton(.lock, "lock.open.fill")
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
    // controlButton(那层"点了才校验 Apple Music 自动化权限"的包装)已经搬到
    // LyricsOverlayWindowController.withMusicPermission —— 点击既然改由控制器分发,
    // 守卫也得跟着过去,不然会变成"View 里留一份没人调的守卫"。

    // 图标用 lock.open.fill——画的是"当前是开着的"这个状态,点一下把它关上/锁定,跟
    // 另外三个播放按钮统一用 .fill 系列图标保持视觉一致。不经过 controlButton 那层
    // "先查 Apple Music 自动化权限"的守卫——锁定位置这个动作跟自动化播放控制完全不
    // 搭边,复用会引入一个跟这个按钮语义不匹配的隐藏依赖,所以两者共享的只是纯视觉
    // 样式(iconButton),各自的守卫/动作逻辑分开写。
    // lockButton 同理并入 iconButton(.lock, …),动作在控制器的 performControlAction 里。

    /// 胶囊里的一个图标。**刻意不是 Button** —— 悬浮窗常年 ignoresMouseEvents=true,
    /// SwiftUI 一个鼠标事件都收不到,挂 Button 只会留下永不触发的死代码。点击由
    /// LyricsOverlayWindowController 按下面上报的矩形自己分发。
    ///
    /// 代价(2026-08-18 拍板接受):没有按下变暗、没有 hover 高亮。原来用的是
    /// .buttonStyle(.plain),本来就没有 hover 高亮,真正少掉的只有按下那一下的变暗。
    /// 换来的是「一个整窗布尔量同时服务点击和滚轮」这个矛盾被彻底删掉。
    private func iconButton(_ id: OverlayControlID, _ systemName: String,
                            primary: Bool = false) -> some View {
        Image(systemName: systemName)
            .font(.system(size: primary ? 15 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: primary ? 30 : 26, height: primary ? 30 : 26)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ControlRectsPreferenceKey.self,
                        value: [id: proxy.frame(in: .named(overlayCoordSpaceName))])
                }
            )
    }

    // "没在播放"要不要隐藏,完全交给 hideWhenNotPlaying 那个开关(见
    // LyricsOverlayWindowController)决定——这里不重复处理,否则两条路径同时生效会分不清
    // 究竟是谁在起作用,看起来像开关失灵。
    @ViewBuilder
    private var overlayBackground: some View {
        if playback.backgroundIsVisible {
            RoundedRectangle(cornerRadius: overlayBackgroundCornerRadius, style: .continuous)
                .fill(playback.backgroundColor)
        } else {
            // 未开启背景色(默认状态)时保留原来近乎透明的拖拽捕获层——纯透明区域有时候
            // 完全接不到拖拽手势,这里给个极淡的背景让 isMovableByWindowBackground 在
            // 整块区域都能生效。
            Color.black.opacity(0.001)
        }
    }

    @ViewBuilder
    private var mainLine: some View {
        if let words = playback.currentLine?.words {
            // 逐字填色用 TimelineView(.animation) 直接从 PlaybackCoordinator.anchor 外推
            // 播放位置,每帧现算 fillFraction,不经过 @Published 值 + .animation() 插值
            // ——SwiftUI 对 .linear 这类曲线动画在重新定目标时是矢量相加而不是从当前值
            // 接续,高频率更新下会造成逐字流转卡顿。暂停时 anchor 会变 nil(见 fastTick
            // 守卫),paused 的第一个条件顺带把这个子树的刷新也停下来。
            //
            // 帧率上限见 WordKaraokeGradient.refreshInterval —— 2026-08-14 那次实测(主线程
            // 跑满 100%)是在歌词窗口上做的,当时只给窗口加了上限,**这里和灵动岛漏了**,
            // 一直按显示器刷新率(ProMotion 120Hz)全速跑到 2026-08-15。常驻显示的恰恰是
            // 悬浮窗,所以这处漏掉的代价比窗口那处更大。
            //
            // paused 的第二个条件(2026-08-19 性能审计落地):这一行填完之后到下一行开始
            // 之前 —— 行尾拖延、以最后一行收尾的间奏/曲末 —— currentLine 不变、所有词的
            // 渐变恒为纯色,视觉零变化,但表不停的话闭包每 tick 照跑(每词一个 LinearGradient
            // 构造,一行 20 词就是每秒 600 个,换 0 像素变化)。currentLineFillSettled 每行
            // 至多翻转两次,换行时 currentLine 赋值触发 body 重估,表自然恢复。
            //
            // ⚠️ 这里**故意**保持"TimelineView 包住整个 WrapLayout",没有照搬歌词窗口那套
            // "下沉到每个字自己挂 TimelineView"(见 LyricsWindowView.KaraokeLineText.body
            // 顶部那段)。下沉之后每个字是**各自独立**的 30Hz 时钟、tick 时刻互不对齐,
            // 描边(整行一份 mask)反而可能被一行里 N 个错开的时刻各触发一次;整行一个表
            // 30Hz 的闭包成本本来就有上限,收益配不上结构翻动。描边自身已经不再吃每帧
            // 渐变变化 —— 剪影 mask 换成了静态源,见 lyricsTextStroke(maskSource:) 那段。
            TimelineView(.animation(minimumInterval: WordKaraokeGradient.refreshInterval,
                                    paused: !playback.isPlayingNow || playback.currentLineFillSettled)) { context in
                // 加上 currentLyricsOffsetMs——activeLine/activeLineIndex(决定"现在是哪一
                // 行哪个词")内部已经把 offsetMs 加进判断了,这里如果不加同一个偏移量,
                // "被判定成当前词"用的时间基准跟"这个词该填多满"用的时间基准就对不上:
                // 词提前变成"当前词"了,但填色进度还是按未校正的原始位置算,会出现填到一半
                // 就卡住、然后突然跳到下一个词从 0 开始的现象(2026-08-03 用户反馈实测坐实)。
                //
                // anchor/currentLyricsOffsetMs **直读**协调器而不经 playback 代理:这个闭包
                // 由 TimelineView 按帧重跑,每帧读到的都是最新值,订阅它们只会让重锚/校准
                // 多打醒整个 body(见 OverlayPlayback 的注释)。
                // ?? pausedPositionMs(2026-08-19 修,四个展示面同款):暂停时 anchor 为 nil、冻结
                // 位置在 pausedPositionMs —— 原来 `?? 0` 会让暂停触发的最后一帧渲染把填色
                // 画成整行"未唱"(时间基准塌缩到 0),补兜底后停在暂停那一刻的真实进度。
                let currentMs = (PlaybackCoordinator.shared.anchor?.extrapolatedPositionMs(now: context.date)
                    ?? PlaybackCoordinator.shared.pausedPositionMs ?? 0)
                    + PlaybackCoordinator.shared.currentLyricsOffsetMs
                karaokeLineContent(words: words, atMs: currentMs)
            }
            .font(playback.mainFont)
            // 描边的剪影 mask 用**静态副本**当 Canvas symbol(2026-08-19 性能审计落地):
            // 原来 symbol 就是 content 本身,活跃词的渐变每 tick 一变、symbol 就失效,整行
            // 位图被二次合成并重跑高斯模糊 + alphaThreshold —— 而 mask 只消费 alpha 剪影,
            // 剪影只由文字/字体/换行决定,一行存续期内 0 次真实变化,那些滤镜 pass 全是
            // 重复计算。静态副本走同一个 karaokeLineContent(同排版/同字体/同换行),只随
            // 换行/字体/宽度变化重建。
            .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor) {
                karaokeLineContent(words: words, atMs: nil)
                    .font(playback.mainFont)
            }
        } else if let text = playback.currentLine?.mainText {
            Text(text)
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor)
                .fixedSize(horizontal: false, vertical: true)
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.isCurrentTrackAdBreak {
            // 2026-08-03 补上——Spotify 广告插播,同样要排在"还在搜索中"分支前面:广告
            // 的标题/歌手永远不会被写进歌词缓存(见 collector/enrich.go
            // trackEnrichment 的对应守卫),hasLyricsContent 永远拿不到内容,不排在
            // 前面的话会在整段广告期间一直显示"搜索歌词中…",见
            // PlaybackCoordinator.isCurrentTrackAdBreak 定义处的注释。
            Text(L10n.t("广告中"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.isCurrentTrackInstrumental {
            // 2026-08-03 补上——联网查过了、明确是纯音乐,跟下面"还在搜索中"/"真的没搜到"
            // 两种含糊状态不一样,是有明确依据的结论,必须排在"还在搜索中"这个分支前面:
            // 不然这个分支会先命中、一直显示"搜索歌词中…",纯音乐的歌只要还在播放就永远
            // 到不了这里,见 PlaybackCoordinator.isCurrentTrackInstrumental 定义处的注释。
            Text(L10n.t("纯音乐"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.currentTrackHasNoLyrics {
            // 搜完了、确实一句都没有。必须排在下面那个"搜索歌词中…"分支前面,否则这首歌
            // 只要还在播,那句"搜索中"就会一直挂着(见 PlaybackCoordinator.currentTrackHasNoLyrics)。
            Text(L10n.t("暂无歌词"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.collectorNetworkDown && !playback.hasLyricsContent {
            // 2026-08-15 补上——必须排在下面"搜索歌词中…"**前面**,否则永远到不了这里。
            //
            // 断网时 collector 查不到任何东西,而"全空不写缓存"的守卫(见 collector 的
            // enrich.go)让 hasLyricsContent 永远是 false,于是界面一直显示"搜索歌词中…"
            // —— 那句话在断网状态下永远不会有下文,是彻头彻尾的误导。
            //
            // 排在 currentTrackHasNoLyrics **后面**:那是"查过了,这首歌确实没有",是个
            // 明确结论;而"现在没网"只说明此刻查不了。两个同时成立时前者更有信息量。
            Text(L10n.t("网络连接失败"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else if playback.isPlayingNow && !playback.hasLyricsContent {
            // 换到一首还没解析过的新歌,collector 后台搜索通常要几秒——这段空窗期跟"这首
            // 歌确实没有歌词/正在间奏"共用同一个 currentLine==nil,但含义完全不同,不能
            // 都糊成一个♪符号,容易让人以为"这首歌就是没词",见 PlaybackCoordinator.hasLyricsContent
            // 注释。
            Text(L10n.t("搜索歌词中…"))
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.5))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        } else {
            Text("♪")
                .font(playback.mainFont)
                .foregroundStyle(playback.displayForegroundColor.opacity(0.3))
                .lyricsTextStroke(playback.textStrokeEnabled, color: playback.textStrokeColor)
        }
    }

    // 软边渐变算法本体抽到 WordKaraokeGradient(悬浮歌词/歌词窗口共用,见该文件顶部
    // 注释),这里只负责取实际生效的前景色(playback.displayForegroundColor)、算出这个字的当前进度,两者
    // 传给共享算法。
    /// 这一行能不能把罗马音标到每个词底下。要同时满足:用户开了罗马音、这一行确实分出了
    /// 词组(引擎只在"看着是日文"时才给,中文歌不会被标成拼音)。
    private var usesPerWordRomanization: Bool {
        playback.showRomanization && playback.currentLine?.wordGroups?.isEmpty == false
    }

    /// 逐字行的内容本体,mainLine 的两个消费方共用同一份排版:
    /// - `atMs` 非 nil:正常展示路径,按播放位置给每个词/组算填色渐变(TimelineView 每帧调);
    /// - `atMs` 为 nil:描边剪影的**静态副本**(同字体/同排版/同换行,纯色填充)——mask 只
    ///   消费 alpha 剪影,用它当 Canvas symbol,描边层就不再被每帧的渐变变化整行重算,
    ///   见 mainLine 里 lyricsTextStroke(maskSource:) 那段注释。
    @ViewBuilder
    private func karaokeLineContent(words: [SyncedLyricWord], atMs currentMs: Int?) -> some View {
        // 渐变素材每帧每行只取一次(纯色词跨帧复用同一实例,见 WordKaraokeGradient.Palette
        // 注释;2026-08-20 性能审计:原来逐词现造 LinearGradient+AnyShapeStyle,~95% 纯色词
        // 每帧被迫重走样式失效)。currentMs == nil 是描边剪影副本,不需要素材。
        let palette = currentMs != nil
            ? WordKaraokeGradient.palette(fg: playback.displayForegroundColor) : nil
        let romaPalette = (currentMs != nil && usesPerWordRomanization)
            ? WordKaraokeGradient.palette(fg: playback.displayForegroundColor.opacity(0.75)) : nil
        // 会自动换行的 WrapLayout——HStack(spacing: 0) 从不换行,一行装不下所有字时会把
        // 每个 Text 压缩到自己出省略号,长的逐字歌词行会直接"消失"变成一串"…"。
        // 见文件底部 WrapLayout 定义。contentKey:行身份+字体+罗马音开关 —— 都没变就跳过
        // 逐词重新测宽(见 WrapLayout.Cache 的守卫注释)。
        WrapLayout(rowAlignment: duetRowAlignment,
                   contentKey: overlayLineLayoutKey) {
            if let groups = playback.currentLine?.wordGroups, usesPerWordRomanization {
                // 一组一列:上面是这一组的字(各自逐字填色),下面是这一组的罗马音
                // (跟着整组的进度填)。列宽由 VStack 取"上下两行里更宽的那个",
                // 主文字之间的间距因此会被下面的罗马音撑开 —— Apple 那边也是这样。
                ForEach(groups) { g in
                    // 组内左对齐,跟歌词窗口/Apple Music 一致
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            // indices 而不是 Array(enumerated()):后者每帧物化一个新数组
                            // 纯为当 id,Range 零分配,下标当 id 与原 offset 语义一致。
                            ForEach(g.words.indices, id: \.self) { i in
                                wordText(g.words[i], atMs: currentMs, palette: palette)
                            }
                        }
                        if let roma = g.romanization {
                            romaText(roma, group: g, atMs: currentMs, palette: romaPalette)
                        }
                    }
                }
            } else {
                ForEach(words.indices, id: \.self) { i in
                    wordText(words[i], atMs: currentMs, palette: palette)
                }
            }
        }
    }

    /// WrapLayout 的内容身份:这些输入不变,行内每个 Text 的固有尺寸就不变,布局缓存可以
    /// 跳过整行重新测宽。⚠️ 必须含**完整**字体身份(family/size/weight 都在 mainFont/
    /// romanizationFont 里)和罗马音开关 —— 漏一样就会拿陈旧尺寸错误换行。填色渐变/描边
    /// 不影响固有尺寸,刻意不进 key。
    private var overlayLineLayoutKey: AnyHashable {
        AnyHashable(OverlayLineKey(
            text: playback.currentLine?.plainText,
            roma: usesPerWordRomanization,
            mainFont: playback.mainFont,
            romaFont: playback.romanizationFont))
    }

    private struct OverlayLineKey: Hashable {
        let text: String?
        let roma: Bool
        let mainFont: Font
        let romaFont: Font
    }

    /// 一组的罗马音。填色进度按**整组**算,不跟着组里单个字跳 —— 一组常常只对应一个读音
    /// (「いつか」是一个词),按字跳会让下面这行一顿一顿的。currentMs 为 nil 时是描边
    /// 剪影副本,纯色即可(mask 只取 alpha),见 karaokeLineContent。
    private func romaText(
        _ roma: String, group: SyncedLyricWordGroup, atMs currentMs: Int?,
        palette: WordKaraokeGradient.Palette?
    ) -> some View {
        let style: AnyShapeStyle
        if let currentMs, let palette {
            // 裸起止版 fillFraction:别再每帧现造一个纯为传参的伪 SyncedLyricWord。
            let fraction = KaraokeFill.fillFraction(
                startMs: group.startMs, durationMs: max(1, group.endMs - group.startMs),
                atMs: currentMs)
            let band = WordKaraokeGradient.wordEdgeSoftenBand
            style = palette.style(left: fraction - band, right: fraction + band)
        } else {
            // 不透明黑保证任何前景色/透明度设置下剪影都完整(过 alphaThreshold)。
            style = AnyShapeStyle(Color.black)
        }
        return Text(roma)
            .font(playback.romanizationFont)
            .foregroundStyle(style)
            .lineLimit(1)
            .fixedSize()
            // 左右各留一点,免得相邻两组的罗马音贴在一起分不清词界
            .padding(.horizontal, 2)
    }

    private func wordText(
        _ w: SyncedLyricWord, atMs currentMs: Int?, palette: WordKaraokeGradient.Palette?
    ) -> some View {
        let style: AnyShapeStyle
        if let currentMs, let palette {
            let fraction = WordKaraokeGradient.fillFraction(for: w, atMs: currentMs)
            let band = WordKaraokeGradient.wordEdgeSoftenBand
            style = palette.style(left: fraction - band, right: fraction + band)
        } else {
            // 描边剪影副本 —— 理由见 romaText 同款分支。
            style = AnyShapeStyle(Color.black)
        }
        return Text(w.text)
            .foregroundStyle(style)
            // 故意不再包 .animation(...)——TimelineView(.animation) 已经在按渲染帧频
            // 重算真值,这里再叠一层 SwiftUI Animation 补间只会重新引入 mainLine 注释里
            // 那套矢量叠加问题。也故意不在这里单独套描边——描边统一挂在 mainLine 里
            // TimelineView 外层的 .lyricsTextStroke(maskSource:),见那边注释。
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
// maskSource(2026-08-19 性能审计落地):剪影 mask 的自定义静态源,nil = 直接用 content
// 本身。静态文本(罗马音/译文/占位符/整行高亮)的 content 本来就不逐帧变,自身当 symbol
// 没有任何浪费;但逐字填色路径的 content 里活跃词的渐变每 tick 都在变 —— content 值一变
// Canvas symbol 就失效,整行位图被二次合成并重跑高斯模糊 + alphaThreshold,而 mask 只
// 消费 alpha 剪影,剪影在一行存续期内根本不变。那条路径改传一份同排版的纯色副本,
// 描边层就只随换行/字体/宽度变化重建。
private struct OptionalTextStroke<MaskSource: View>: ViewModifier {
    let enabled: Bool
    let color: Color
    let maskSource: MaskSource?
    // 固定常量,不做成 Settings 可调项——只给颜色选择器,粗细留在代码里,参考 LyricsX
    // 同款克制。1.2pt 在这个项目常用的歌词字号下是一圈清晰但不臃肿的细描边。
    private let width: CGFloat = 1.2
    private let symbolID = "np-lyrics-stroke"

    init(enabled: Bool, color: Color, maskSource: MaskSource?) {
        self.enabled = enabled
        self.color = color
        self.maskSource = maskSource
    }

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
                                symbolSource(content: content)
                                    .tag(symbolID)
                                    .blur(radius: width)
                            }
                        }
                )
        } else {
            content
        }
    }

    // 剪影源:有静态副本用副本,没有就用 content 本身。副本跟 content 同排版同字体,
    // 自然尺寸一致,Canvas 居中绘制后跟被描边的内容逐点对齐。
    @ViewBuilder
    private func symbolSource(content: Content) -> some View {
        if let maskSource {
            maskSource
        } else {
            content
        }
    }
}

// internal(而不是 private):设置页顶部的实时预览要用同一个描边实现渲染同一段歌词 ——
// 预览和真窗口各写一份描边最终一定会漂,而描边是这一页最难凭想象判断效果的一项。
extension View {
    func lyricsTextStroke(_ enabled: Bool, color: Color) -> some View {
        modifier(OptionalTextStroke<EmptyView>(enabled: enabled, color: color, maskSource: nil))
    }

    /// 带静态剪影源的版本,给逐字填色这类 content 逐帧变化的热路径用 —— 见
    /// OptionalTextStroke 顶部 maskSource 的注释。
    func lyricsTextStroke<M: View>(
        _ enabled: Bool, color: Color, @ViewBuilder maskSource: () -> M
    ) -> some View {
        modifier(OptionalTextStroke(enabled: enabled, color: color, maskSource: maskSource()))
    }
}

private struct ContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 每个按钮各自的矩形。
///
/// ⚠️ reduce 必须**合并**、而且**跳过零矩形**,不能无脑 value = nextValue():
/// 树里没设过这个 key 的分支(外层测高度的 background 里那个 Color.clear)会贡献
/// defaultValue,覆盖式写法会把真实矩形冲掉 —— 这个坑 2026-08-07 在
/// ControlsFramePreferenceKey 上实测踩过一次,见它的注释。
private struct ControlRectsPreferenceKey: PreferenceKey {
    static let defaultValue: [OverlayControlID: CGRect] = [:]
    static func reduce(value: inout [OverlayControlID: CGRect],
                       nextValue: () -> [OverlayControlID: CGRect]) {
        for (id, rect) in nextValue() where rect != .zero { value[id] = rect }
    }
}

private struct ControlsFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    // 保留最后一个**非零**报告,而不是无脑 value = nextValue()。树里没设过这个 key 的分支
    // (比如外层测高度的 background 里那个 Color.clear)会贡献 defaultValue(.zero),按原来的
    // 写法排在后面就会把真正报上来的矩形冲掉 —— 2026-08-07 实测就是这么坏的。
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
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
    // 换行/对齐的几何计算全在 WrapLayoutMath(LyrimuseCore)里,selftest 够得到;这里只剩
    // Layout 协议的壳:量尺寸、缓存、把算好的坐标交给 SwiftUI 去 place。
    typealias RowAlignment = WrapLayoutMath.RowAlignment

    var horizontalSpacing: CGFloat = 0
    var verticalSpacing: CGFloat = 2
    var rowAlignment: RowAlignment = .center
    /// 内容身份 key(2026-08-20 性能审计):调用方把**一切影响子视图固有尺寸**的输入
    /// (行文本身份 + 完整字体身份 family/size/weight + 罗马音开关)拼成一个 Hashable
    /// 传进来 —— key 和子视图数量都没变,updateCache 就跳过整行重新测宽。nil = 关闭守卫,
    /// 保持"每回合全量重测"的旧行为(冷调用点不用改)。
    /// ⚠️ 漏掉一个影响尺寸的输入 = 拿陈旧尺寸错误换行,宁可多进 key 也别少。
    var contentKey: AnyHashable? = nil

    // 量一次子视图尺寸就存住,别每次调用都重量一遍。
    //
    // 2026-08-14 用 sample 量到的现场:"歌词窗口"播放带逐字歌词的歌时,主线程 90%+ 的时间
    // 在 NSHostingView.layout,栈顶就是这个 Layout 的 sizeThatFits。原因是逐字填色由
    // TimelineView 按渲染帧频驱动(60~120Hz),而这里**每次** sizeThatFits/placeSubviews
    // 都会 `subviews.map { $0.sizeThatFits(.unspecified) }` 把整行每个字重新测一遍 ——
    // SwiftUI 一个布局回合里本来就会多次询问尺寸,再乘以帧率,就是一秒几千次文字排版。
    //
    // 缓存原来只在"子视图集合真的变了"时重建(updateCache)——但 SwiftUI 在子视图**值**
    // 更新(逐 tick 的渐变变化)时同样回调 updateCache,于是填色期间每个布局回合仍然
    // 全量重测。2026-08-20 补 contentKey 守卫:key/数量都没变就直接复用,顺带把 rows
    // (换行分组)也缓存住 —— 原来 sizeThatFits/placeSubviews 各自把 rows() 重算一遍。
    struct Cache {
        var sizes: [CGSize]
        var contentKey: AnyHashable?
        var subviewCount: Int
        // rows 缓存:随 sizes 重测**必须**同步失效(sizes 新 rows 旧会摆放越界/重叠),
        // key 是 (maxWidth, horizontalSpacing)——placeSubviews 的 bounds.width 偶尔不等于
        // 最后一次提案宽度,miss 了重算就是,安全。
        var rows: [WrapLayoutMath.Row]?
        var rowsWidth: CGFloat = .nan
        var rowsSpacing: CGFloat = .nan
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) },
              contentKey: contentKey, subviewCount: subviews.count)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        if let key = contentKey, key == cache.contentKey, subviews.count == cache.subviewCount {
            return // 内容身份没变:字体/文本都没变,尺寸和 rows 缓存照用
        }
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        cache.contentKey = contentKey
        cache.subviewCount = subviews.count
        cache.rows = nil
        cache.rowsWidth = .nan
        cache.rowsSpacing = .nan
    }

    private func cachedRows(_ cache: inout Cache, maxWidth: CGFloat) -> [WrapLayoutMath.Row] {
        if let rows = cache.rows, cache.rowsWidth == maxWidth, cache.rowsSpacing == horizontalSpacing {
            return rows
        }
        let rows = WrapLayoutMath.rows(
            sizes: cache.sizes, maxWidth: maxWidth, horizontalSpacing: horizontalSpacing)
        cache.rows = rows
        cache.rowsWidth = maxWidth
        cache.rowsSpacing = horizontalSpacing
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard let maxWidth = proposal.width, maxWidth.isFinite else {
            // 没有宽度限制:理论上不会走到——调用方(mainLine)所在的 VStack 总会有一个
            // 有限宽度的提案(悬浮窗宽度固定)。兜底铺成一行,不换行。
            return WrapLayoutMath.unconstrainedSize(
                sizes: cache.sizes, horizontalSpacing: horizontalSpacing)
        }
        return WrapLayoutMath.totalSize(
            rows: cachedRows(&cache, maxWidth: maxWidth),
            maxWidth: maxWidth, verticalSpacing: verticalSpacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        for p in WrapLayoutMath.placements(
            rows: cachedRows(&cache, maxWidth: bounds.width),
            sizes: cache.sizes, bounds: bounds,
            horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing,
            rowAlignment: rowAlignment)
        {
            subviews[p.index].place(
                at: p.origin, anchor: .topLeading, proposal: ProposedViewSize(p.size))
        }
    }
}
