import AppKit
import Combine
import CoreVideo
import LyrimuseCore
import Metal
import OSLog
import QuartzCore
import SwiftUI
import VideoToolbox

/// 副屏画面的分发:同一尺寸的网页共用一个渲染器,最后一个网页断开就停掉那个渲染器。见 19 章。
@MainActor
final class WebLyricsScreenHub {
    /// 同时最多画几种尺寸;再来新尺寸的网页就共用最早那一个(画面按比例缩放显示)。
    static let maxRenderers = 3

    /// 同一尺寸、同一种推法(视频流 / 逐帧 JPEG)的网页共用一个渲染器。
    struct Key: Hashable {
        let viewport: WebLyricsViewport
        let video: Bool
    }

    private var renderers: [Key: WebLyricsScreenRenderer] = [:]
    private var order: [Key] = []
    /// 一个网页。`needsKeyFrame`:视频流里要等下一个关键帧才解得开(刚连上、掉过帧),见 `WebLyricsVideo.deliver`;
    /// `rate`:视频流按它的回报控码率和在途上限(`WebLyricsRateControl`),逐帧 JPEG 为 nil。
    private struct Viewer {
        let connection: WebLyricsConnection
        let key: Key
        var visible = true
        var needsKeyFrame = true
        var rate: WebLyricsRateControl?
        /// 这一段时间里没发出去的帧,按原因分:超在途上限、连接排满、在等关键帧。有丢帧时最多每 5 秒记一行诊断日志。
        var drops = (inFlight: 0, queue: 0, waitingKey: 0)
        var dropsSince: CFTimeInterval = 0
        /// 网页开着诊断浮层(`WebLyricsStats`):每秒给它发一次;`statsDrops` 是上一次发完之后丢的帧。
        var statsWanted = false
        var statsDrops = 0
    }
    private var viewers: [ObjectIdentifier: Viewer] = [:]
    private var statsTimer: Timer?
    private static let log = Logger(subsystem: "me.yudaotor.lyrimuse", category: "web-lyrics")

    func add(_ connection: WebLyricsConnection, viewport requested: WebLyricsViewport, video: Bool) {
        var key = Key(viewport: requested, video: video)
        if renderers[key] == nil {
            // 尺寸满了共用最早那个同一种推法的;一个都没有就照样新开(视频和 JPEG 的消息格式不同,不能混)
            if renderers.count >= Self.maxRenderers, let first = order.first(where: { $0.video == video }) {
                key = first
            } else {
                let made = key
                let renderer = WebLyricsScreenRenderer(viewport: made.viewport, video: made.video)
                renderer.onFrame = { [weak self] frame in self?.broadcast(frame, for: made) }
                renderer.onText = { [weak self] text in self?.broadcastText(text, for: made) }
                renderers[made] = renderer
                order.append(made)
                renderer.start()
            }
        }
        viewers[ObjectIdentifier(connection)] = Viewer(connection: connection, key: key,
                                                       rate: key.video ? WebLyricsRateControl() : nil)
        Self.log.notice("screen viewer joined \(key.viewport.width, privacy: .public)x\(key.viewport.height, privacy: .public)@\(key.viewport.scale, privacy: .public) \(key.video ? "video" : "jpeg", privacy: .public)")
        refreshBacklog(key)
        renderers[key]?.requestKeyFrame()
        renderers[key]?.requestFrame()
        refreshVisibility(key)
    }

    func remove(_ connection: WebLyricsConnection) {
        guard let entry = viewers.removeValue(forKey: ObjectIdentifier(connection)) else { return }
        refreshStatsTimer()
        guard !viewers.values.contains(where: { $0.key == entry.key }) else {
            refreshBacklog(entry.key)
            refreshBitRate(entry.key)
            refreshLead(entry.key)
            return
        }
        renderers.removeValue(forKey: entry.key)?.stop()
        order.removeAll { $0 == entry.key }
    }

    /// 网页发回来的文本消息:可见性、视频流收帧回报、诊断浮层开关(谁都能报),指针、滚轮(别的设备要「允许局域网设备控制播放」
    /// 开着才算数)。
    func message(_ connection: WebLyricsConnection, payload: Data) {
        let id = ObjectIdentifier(connection)
        guard let entry = viewers[id] else { return }
        if let visible = WebLyricsVisibility.parse(payload) {
            guard visible != entry.visible else { return }
            viewers[id]?.visible = visible
            Self.log.notice("screen viewer \(visible ? "visible" : "hidden", privacy: .public)")
            refreshVisibility(entry.key)
            return
        }
        if let wanted = WebLyricsStats.parseToggle(payload) {
            viewers[id]?.statsWanted = wanted
            refreshStatsTimer()
            if wanted { sendStats() }
            return
        }
        if let feedback = WebLyricsFeedback.parse(payload) {
            guard var rate = entry.rate else { return }
            let wire = rate.bitRate
            let changed = rate.noteFeedback(feedback, at: CACurrentMediaTime())
            viewers[id]?.rate = rate
            refreshLead(entry.key)
            refreshBacklog(entry.key)
            guard changed else { return }
            if rate.bitRate < wire {
                Self.log.notice("web video bitrate: \(rate.bitRate / 1000, privacy: .public) kbps, encoder \(rate.encoderBitRate / 1000, privacy: .public) kbps (queue \(Int(rate.queueDelay * 1000), privacy: .public)ms, sent \(Int(rate.sentBitRate(at: CACurrentMediaTime()) / 1000), privacy: .public) kbps)")
            }
            refreshBitRate(entry.key)
            return
        }
        guard WebLyricsPointer.permits(remoteIsLoopback: connection.isLoopback,
                                       lanControlEnabled: AppSettings.shared.webLyricsAllowLANControl) else { return }
        if let event = WebLyricsPointer.parse(payload) {
            renderers[entry.key]?.handlePointer(event)
        } else if let wheel = WebLyricsWheel.parse(payload) {
            renderers[entry.key]?.handleWheel(wheel)
        }
    }

    /// 这一尺寸的网页里只要有一个看得见就照常出帧,全看不见时降到暂停那一档。
    private func refreshVisibility(_ key: Key) {
        renderers[key]?.setViewersVisible(viewers.values.contains { $0.key == key && $0.visible })
    }

    private func broadcastText(_ text: String, for key: Key) {
        for entry in viewers.values where entry.key == key { entry.connection.sendText(text) }
    }

    /// `frame` 是出帧线程上已经包好的 WebSocket 帧,几个网页共用同一份,主线程这里只交给连接发出去。排满了的网页这一帧
    /// 丢掉(逐帧 JPEG 上一帧没发完就算满,视频流按字节,见 `frameBacklogged(video:)`;视频流在途超过上限也算,
    /// 见 `WebLyricsRateControl.admits`);视频流里丢了帧的、刚连上的,等下一个关键帧再发,同时要一个关键帧
    /// (`WebLyricsVideo.deliver`)。
    private func broadcast(_ frame: WebLyricsScreenFrame, for key: Key) {
        var wantsKeyFrame = false
        let now = CACurrentMediaTime()
        // 在途上限只在这一尺寸还有别的网页没超时才丢帧;全都超了照发这一帧,后面的由出帧线程停画挡住(见 refreshBacklog)
        let anyAdmitted = viewers.values.contains { $0.key == key && ($0.rate?.admits(at: now) ?? true) }
        for (id, entry) in viewers where entry.key == key {
            let admitted = !anyAdmitted || (entry.rate?.admits(at: now) ?? true)
            let delivery = WebLyricsVideo.deliver(isKeyFrame: frame.isKeyFrame, needsKeyFrame: entry.needsKeyFrame,
                                                  previousStillSending: !admitted || entry.connection.frameBacklogged(video: key.video))
            if delivery.send {
                entry.connection.sendEncodedFrame(frame.data)
                viewers[id]?.rate?.noteSent(stamp: frame.stamp, bytes: frame.payloadBytes, at: now)
            } else {
                viewers[id]?.statsDrops += 1
                if !admitted {
                    viewers[id]?.drops.inFlight += 1
                } else if entry.connection.frameBacklogged(video: key.video) {
                    viewers[id]?.drops.queue += 1
                } else {
                    viewers[id]?.drops.waitingKey += 1
                }
            }
            logDrops(id, now: now)
            viewers[id]?.needsKeyFrame = delivery.needsKeyFrame
            wantsKeyFrame = wantsKeyFrame || delivery.wantsKeyFrame
        }
        if wantsKeyFrame, key.video { renderers[key]?.requestKeyFrame() }
        refreshBacklog(key)
    }

    /// 某条连接上一帧发完了。
    func frameSent(_ connection: WebLyricsConnection) {
        guard let entry = viewers[ObjectIdentifier(connection)] else { return }
        refreshBacklog(entry.key)
    }

    private func logDrops(_ id: ObjectIdentifier, now: CFTimeInterval) {
        guard let entry = viewers[id], now - entry.dropsSince >= 5 else { return }
        let d = entry.drops
        if d.inFlight + d.queue + d.waitingKey > 0 {
            Self.log.notice("web frames dropped: \(d.inFlight, privacy: .public) over in-flight cap, \(d.queue, privacy: .public) queue full, \(d.waitingKey, privacy: .public) waiting key frame")
        }
        viewers[id]?.drops = (0, 0, 0)
        viewers[id]?.dropsSince = now
    }

    /// 有网页开着诊断浮层时每秒发一次,都关了就停。
    private func refreshStatsTimer() {
        let wanted = viewers.values.contains { $0.statsWanted }
        guard wanted != (statsTimer != nil) else { return }
        statsTimer?.invalidate()
        statsTimer = nil
        guard wanted else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendStats() }
        }
        RunLoop.main.add(t, forMode: .common)
        statsTimer = t
    }

    private func sendStats() {
        for (id, entry) in viewers where entry.statsWanted {
            guard let renderer = renderers[entry.key] else { continue }
            let s = renderer.stats
            let text = WebLyricsStats.message(
                renderFps: s.fps, bitRate: entry.rate?.bitRate, encoderBitRate: entry.rate?.encoderBitRate,
                queueMs: entry.rate.map { Int($0.queueDelay * 1000) }, leadMs: s.leadMs, leadTargetMs: s.leadTargetMs,
                dropped: entry.statsDrops)
            entry.connection.sendText(text)
            viewers[id]?.statsDrops = 0
        }
    }

    /// 视频流一个尺寸共用一个编码器:码率取这一尺寸网页里最低的。
    private func refreshBitRate(_ key: Key) {
        guard key.video,
              let lowest = viewers.values.filter({ $0.key == key }).compactMap({ $0.rate?.encoderBitRate }).min() else { return }
        renderers[key]?.setVideoBitRate(lowest)
    }

    /// 提前量取这一尺寸网页里「从画到上屏」最久的那个:共用一份画面,宁可稍早、不拖后。
    private func refreshLead(_ key: Key) {
        let longest = viewers.values.filter { $0.key == key }.compactMap { $0.rate?.displayLatency }.max()
        renderers[key]?.setLeadTarget(longest.map { Int($0 * 1000) } ?? 0)
    }

    /// 这一尺寸的网页全都排满了时,出帧线程先不画:画出来也是每条连接都丢,白画白编。
    /// 视频流超在途上限的也算排满:全都超了时出帧线程不画不编,编码器的参考链不断,缓过来接着发普通帧;编好了再在这里丢,
    /// 后面的帧就得等关键帧,窄路上关键帧又把排队撑长、接着丢,越丢越多。
    private func refreshBacklog(_ key: Key) {
        let now = CACurrentMediaTime()
        let entries = viewers.values.filter { $0.key == key }
        renderers[key]?.setSendBacklogged(!entries.isEmpty && entries.allSatisfy {
            $0.connection.frameBacklogged(video: key.video) || !($0.rate?.admits(at: now) ?? true)
        })
    }
}

/// 离屏画一份歌词窗口(完整布局)、编成 JPEG 推给副屏。网页把手指按下、拖动、抬起发回来,这里按位置判点中了什么
/// (播放控制、星标、「…」、音量、翻译钮、歌词钮、菜单行、进度条、歌词行),照歌词窗口同一个动作执行;
/// 音量胶囊和右下一排跟歌词窗口一样闲置 3 秒收起,点一下画面露出来。
///
/// 背景(`BackdropNSView`)和歌词列表(`LyricsLayerListView`)是歌词窗口用的同一份组件,数据来自同一个
/// 窄订阅代理(`WindowPlayback`);左栏的封面卡、歌名、进度在歌词窗口里是 SwiftUI,离屏画不了,这里用图层
/// 照同样的尺寸重搭(`WebLyricsPlayerPane`)。三块组件不挂窗口,每帧用 `DetachedLayerTree` 拼树,交给
/// 主线程只在状态变了时改图层、拼树提交;出帧在 `WebLyricsFrameSource` 自己的线程上按固定节拍画(见 19 章决策 5)。
///
/// 毛玻璃背景折射的是窗口背后的桌面,副屏上没有对应物,按「跟随封面」画。停播时歌词窗口是停播页,这里只画
/// 「未在播放」的空状态。见 19 章决策 2。
@MainActor
final class WebLyricsScreenRenderer {
    let viewport: WebLyricsViewport
    var onFrame: ((WebLyricsScreenFrame) -> Void)?
    /// 发给这一尺寸所有网页的文本消息(菜单里平台页那几行的位置与网址)。
    var onText: ((String) -> Void)?

    /// 状态刚变的这一小段(暂停时封面缩小、换歌时封面淡入)出帧照在播的节拍,不然过渡动画只剩几帧。
    private static let transitionHold: CFTimeInterval = 1.2
    /// 主线程这一侧的节拍:走进度条、把列表异步建好的行拼进树。状态变化不等它,当场提交。
    private static let modelInterval: TimeInterval = 1.0 / 10
    private static let idleModelInterval: TimeInterval = 1.0 / 2
    /// 左栏整组垂直居中后再往上挪的量,同歌词窗口(`fullBody` 里 `-safeAreaInsets.top / 2 - 2`,顶部 inset 约 28pt)。
    private static let paneVerticalOffset: CGFloat = 16
    private static let log = Logger(subsystem: "me.yudaotor.lyrimuse", category: "web-lyrics")

    private let playback = WindowPlayback()
    private var subs: [AnyCancellable] = []
    private var dirty = true

    private let container = CALayer()
    private let wrapper = CALayer()
    private let fillLayer = CAGradientLayer()
    private let backdrop: BackdropNSView
    private let dimLayer = CALayer()
    private let pane = WebLyricsPlayerPane()
    private let list: LyricsLayerListView
    private let emptyState = WebLyricsEmptyStateLayer()
    private let chrome = WebLyricsChromeLayer()
    private var fastUntil: CFTimeInterval = 0
    /// 手指按下之后这一串事件归谁。
    private enum Drag {
        case none, dismissMenu, progress, volume
        case control(WebLyricsControl)
        /// `seeks`:按下时控件露着,没拖动就跳到那一句;控件收着时这一下只唤出控件,照样能拖着滚。
        case lyrics(startY: CGFloat, lastY: CGFloat, moved: Bool, seeks: Bool)
        /// 简介正文拖着滚。
        case panelScroll(lastY: CGFloat)
    }
    private var drag: Drag = .none
    /// 正在拖进度条时手指所在的比例;拖动期间进度条和时间显示它,抬起才跳转(同歌词窗口)。
    private var scrubFraction: Double?
    /// 「隐藏歌词」:右栏收起、左栏挪到正中(同歌词窗口 `showsLyricsPane`)。
    private var lyricsHidden = false
    private var menu: WebLyricsChromeLayer.Menu = .none
    /// 「…」菜单直接执行的那几行,跟歌词窗口共用一份实现。
    private let moreMenu = LyricsMoreMenuModel()
    /// 上一次搭模型时「…」菜单开着没有、开着时对着哪首歌:刚打开或开着换了歌就刷新资料库状态和平台链接。
    private var moreMenuTrack: String?
    /// 上一次发给网页的链接位置,没变就不重发。
    private var sentLinks: String?
    /// 「你的常听」两排分段的选择(同歌词窗口的默认:歌曲、近 7 天)。
    private var chartKind: LastfmStatsService.ChartKind = .tracks
    private var chartPeriod: LastfmStatsService.Period = .week
    /// 简介正文滚到哪了。
    private var panelScroll: CGFloat = 0
    /// 「显示简介」打开时读的歌词来源与平台链接(同歌词窗口 `loadInfoPanelDetails`),换歌时重读。
    private var infoDetails: (track: String, source: String?, links: PlatformLinks?)?
    private var chromeIdle = LyricsWindowChromeIdle.State()
    private var chromeShown = true
    /// 左栏此刻摆在哪(左缘 x);nil = 还没摆过,第一次不做动画。
    private var paneX: CGFloat?
    private var countKey = ""
    private var timerInterval: TimeInterval = 0
    private var commitScheduled = false
    /// 歌名空了要连续这么久才画停播:切歌时播放器常先撤掉正在播放、过一会儿才报下一首,中间那一下别闪成「未在播放」,
    /// 这段时间照旧画上一首。歌词窗口进出停播页有 0.45 秒交叉淡入,短空档看不出来;这里是硬切,得靠它挡。
    private static let idleHold: CFTimeInterval = 2
    private var titleEmptySince: CFTimeInterval?
    /// 上一次搭模型时画的是不是停播;还没搭过是 nil(一连上就是停播的照直画)。
    private var shownIdle: Bool?
    private var frames: WebLyricsFrameSource?
    private var sendBacklogged = false
    private var timer: Timer?
    /// 这一尺寸的网页里有没有看得见的。全看不见时出帧和主线程节拍都按暂停那一档,不停到 0:浏览器把明明摆在屏上的
    /// 小窗报成不可见时(同 rAF 不来的那种窗口),画面只是变慢、不会定住。见 19 章决策 13。
    private var viewersVisible = true

    /// 推 H.264 视频流(网页能硬解时);否则逐帧 JPEG。
    private let video: Bool

    /// 提前画:网页报来的「从画到上屏」(这一尺寸网页里最久的,毫秒)。在播时歌词按「此刻 + 提前量」画,网页晚放多久就
    /// 提前多久,屏上歌词跟音乐对得上,放帧余量放多大都不拖后。暂停、跳转那一下会多画出提前量那么一段再退回,换不来。
    /// 见 19 章决策 28。
    private var leadTargetMs = 0
    /// 正在用的提前量:每秒最多挪 `leadSlewPerSecond` 秒(挪动期间逐字填色快慢差这么多,两成看不出,再快就看得出忽快
    /// 忽慢),按 `leadStepMs` 取整(每挪一格重装一次填色动画)。
    private var leadExact = 0.0
    private var leadMs = 0
    private var leadUpdatedAt: CFTimeInterval?
    private static let leadSlewPerSecond = 0.2
    private static let leadStepMs = 25
    /// 按「此刻 + leadMs」解出来的歌词行;没在播、没有提前量时 nil,照用 `playback` 的。
    private var lookahead: LocalPlaybackSource.LyricsLookahead?
    /// 提前量下一次换行的时刻补一次提交(主线程节拍 0.1 秒,等它的话换行最多晚 0.1 秒)。
    private var lookaheadTimer: Timer?
    private var appliedLeadMs: Int { lookahead == nil ? 0 : leadMs }
    /// 上一次记进诊断日志的提前量目标;变了 100ms 以上才再记。
    private var loggedLeadMs = 0
    /// 上一次提交时的播放位置,下一次比对有没有暂停、跳转(押错了提前画,见 `WebLyricsPredictionCut`)。
    private var lastTimeline: (positionMs: Int, at: TimeInterval, playing: Bool)?
    /// 这次提交发现押错了要丢的起点(画帧时刻毫秒)。终点等这次提交把图层树交出去之后再取:在那之前画的帧还是旧的树、
    /// 还带着提前量。
    private var pendingCutFrom: Double?

    init(viewport: WebLyricsViewport, video: Bool = false) {
        self.video = video
        self.viewport = viewport
        let bounds = CGRect(x: 0, y: 0, width: viewport.width, height: viewport.height)
        backdrop = BackdropNSView(frame: bounds)
        list = LyricsLayerListView(frame: .zero)
        list.rendersDetached = true

        wrapper.anchorPoint = .zero
        wrapper.bounds = bounds
        wrapper.masksToBounds = true
        // Metal 纹理的原点在左下:整幅上下翻一次,出来的画面才是正的。别改成给图层设 isGeometryFlipped,
        // 那样布局翻过来了、字形却是倒的。
        // 像素尺寸取过偶数,按它反算两向倍数,画面正好铺满、边上不留黑线。
        wrapper.position = CGPoint(x: 0, y: viewport.pixelHeight)
        wrapper.transform = CATransform3DMakeScale(CGFloat(viewport.pixelWidth) / CGFloat(viewport.width),
                                                   -CGFloat(viewport.pixelHeight) / CGFloat(viewport.height), 1)
        container.frame = CGRect(x: 0, y: 0, width: viewport.pixelWidth, height: viewport.pixelHeight)
        container.backgroundColor = NSColor.black.cgColor
        container.addSublayer(wrapper)

        fillLayer.frame = bounds
        dimLayer.frame = bounds
        dimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
        wrapper.addSublayer(fillLayer)
        if let l = backdrop.layer {
            l.masksToBounds = true
            wrapper.addSublayer(l)
        }
        wrapper.addSublayer(dimLayer)
        // 左栏叠在歌词上面:手机那种排法里底部播放条压着歌词列表的下半截(连滚动指示条)。
        if let l = list.layer { wrapper.addSublayer(l) }
        wrapper.addSublayer(pane)
        wrapper.addSublayer(emptyState)
        chrome.frame = bounds
        wrapper.addSublayer(chrome)
        for layer in [wrapper, fillLayer, dimLayer, pane, emptyState, chrome] as [CALayer] {
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "hidden": NSNull(),
                             "colors": NSNull(), "backgroundColor": NSNull()]
        }
        list.nowProvider = { [weak self] in PlaybackCoordinator.shared.lyricsTimelineMs() + (self?.appliedLeadMs ?? 0) }
        layoutComponents()

        subs = [
            playback.objectWillChange.sink { [weak self] _ in self?.scheduleCommit() },
            NSApp.publisher(for: \.effectiveAppearance).sink { [weak self] _ in self?.scheduleCommit() },
            PlaybackCoordinator.shared.$soundVolume.removeDuplicates().sink { [weak self] _ in self?.scheduleCommit() },
            PlaybackCoordinator.shared.$trackLyricsOffsetMs.removeDuplicates().sink { [weak self] _ in self?.scheduleCommit() },
            LastfmStatsService.shared.$nowPlayingCount.removeDuplicates().sink { [weak self] _ in self?.scheduleCommit() },
            moreMenu.objectWillChange.sink { [weak self] _ in self?.scheduleCommit() },
            LastfmLoveModel.shared.objectWillChange.sink { [weak self] _ in self?.scheduleCommit() },
            EditorialNotesStore.shared.objectWillChange.sink { [weak self] _ in self?.scheduleCommit() },
            LastfmStatsService.shared.objectWillChange.sink { [weak self] _ in
                guard let self, self.menu == .charts || self.menu == .info else { return }
                self.scheduleCommit()
            },
        ]
    }

    func start() {
        EditorialNotesStore.shared.retain()
        chromeIdle.revealUntil = Date().addingTimeInterval(LyricsWindowChromeIdle.idleSeconds)
        commit()
        let motion = pane.motion
        frames = WebLyricsFrameSource(root: container, pixelWidth: viewport.pixelWidth, pixelHeight: viewport.pixelHeight,
                                      minResolution: 1 / viewport.scale, video: video, prepare: { motion.pullFrame() }) {
            [weak self] jpeg in self?.onFrame?(jpeg)
        }
        frames?.start()
        commit()
    }

    func stop() {
        EditorialNotesStore.shared.release()
        if moreMenuTrack != nil { LastfmLoveModel.shared.release() }
        moreMenuTrack = nil
        timer?.invalidate()
        timer = nil
        lookaheadTimer?.invalidate()
        lookaheadTimer = nil
        subs = []
        frames?.stop()
        frames = nil
    }

    func setViewersVisible(_ visible: Bool) {
        guard visible != viewersVisible else { return }
        viewersVisible = visible
        if visible {
            requestFrame()
        } else {
            // 重搭一次左栏:动态封面跟着停
            dirty = true
            commit()
        }
    }

    /// 这一尺寸的网页全都还有上一帧没发完(慢网):出帧线程跳过这几拍,有一条发完了再接着画。
    func setSendBacklogged(_ backlogged: Bool) {
        guard backlogged != sendBacklogged else { return }
        sendBacklogged = backlogged
        frames?.setSendBacklogged(backlogged)
    }

    /// 视频流里有网页要从关键帧开始。
    func requestKeyFrame() {
        frames?.requestKeyFrame()
    }

    /// 视频流的码率(这一尺寸网页里最低的那个)。
    func setVideoBitRate(_ bitRate: Int) {
        frames?.setVideoBitRate(bitRate)
    }

    /// 诊断浮层用:此刻的出帧帧率、在用的提前量和它的目标(毫秒)。
    var stats: (fps: Int, leadMs: Int, leadTargetMs: Int) {
        (frames?.framesPerSecond ?? 0, appliedLeadMs, leadTargetMs)
    }

    func setLeadTarget(_ ms: Int) {
        leadTargetMs = max(0, ms)
        guard abs(leadTargetMs - loggedLeadMs) >= 100 else { return }
        loggedLeadMs = leadTargetMs
        Self.log.notice("web lyrics lead target: \(self.leadTargetMs, privacy: .public)ms (now \(self.leadMs, privacy: .public)ms)")
    }

    /// 新网页连上来时立刻出一帧,不等下一拍。
    func requestFrame() {
        sentLinks = nil
        dirty = true
        commit()
        frames?.renderNow()
        // 视频流建不起来(这个尺寸硬件编码器不收、编码器不可用):叫网页改回逐帧 JPEG 重连,别停在「正在连接」。
        if video, frames == nil { onText?(Self.noVideoMessage) }
    }

    private static let noVideoMessage = #"{"type":"no-video"}"#

    /// 网页发回来的一次指针事件(相对位置,左上为原点)。按下时判归谁:菜单开着时只有菜单行能点、点别处只关菜单
    /// (同歌词窗口的全窗捕手);按钮抬起时还在同一颗上才执行;进度条拖动中只改显示、抬起才跳转;音量跟手;
    /// 歌词竖向拖过 6 点算滚动,没拖动就是点那一句跳过去。音量胶囊、右下一排收起时点在那里只把它们露出来。
    func handlePointer(_ event: WebLyricsPointer) {
        let p = CGPoint(x: event.point.x * width, y: event.point.y * height)
        chromeIdle.pointerInside = true
        chromeIdle.lastActivity = Date()
        switch event.phase {
        case .down:
            drag = target(at: p, chromeShown: chromeShown)
            if case .progress = drag { scrubFraction = pane.progressFraction(atX: p.x - paneRect.minX) }
            if case .volume = drag, let v = chrome.volume(at: p, requireHit: false) { PlaybackCoordinator.shared.setVolume(v) }
        case .move:
            switch drag {
            case .progress:
                scrubFraction = pane.progressFraction(atX: p.x - paneRect.minX)
            case .volume:
                if let v = chrome.volume(at: p, requireHit: false) { PlaybackCoordinator.shared.setVolume(v) }
            case let .lyrics(startY, lastY, moved, seeks):
                let scrolling = moved || abs(p.y - startY) > 6
                if scrolling { list.scroll(by: lastY - p.y) }
                drag = .lyrics(startY: startY, lastY: scrolling ? p.y : lastY, moved: scrolling, seeks: seeks)
            case let .panelScroll(lastY):
                let limit = chrome.scrollArea?.maxScroll ?? 0
                panelScroll = min(max(panelScroll + lastY - p.y, 0), limit)
                drag = .panelScroll(lastY: p.y)
            default:
                break
            }
        case .up:
            let finished = drag
            drag = .none
            switch finished {
            case let .control(c):
                if hitControl(at: p, chromeShown: true) == c { activate(c) }
            case .progress:
                if let f = scrubFraction {
                    PlaybackCoordinator.shared.seek(toMs: Int(f * Double(currentDurationMs())))
                }
                scrubFraction = nil
            case let .lyrics(_, _, moved, seeks):
                if !moved, seeks { seekToLine(at: p) }
            case .dismissMenu:
                menu = .none
            default:
                break
            }
        case .cancel:
            drag = .none
            scrubFraction = nil
        }
        dirty = true
        commit()
        frames?.renderNow()
    }

    /// 滚轮 / 触控板:落在简介正文上就滚正文,落在歌词栏就滚歌词(同歌词窗口里滚轮的落点),别处不管。
    func handleWheel(_ wheel: WebLyricsWheel) {
        let p = CGPoint(x: wheel.point.x * width, y: wheel.point.y * height)
        let dy = CGFloat(wheel.dy) * height
        chromeIdle.pointerInside = true
        chromeIdle.lastActivity = Date()
        if let area = chrome.scrollArea, area.rect.contains(p) {
            panelScroll = min(max(panelScroll + dy, 0), area.maxScroll)
        } else if !list.isHidden, lyricsPaneVisible, listFrame.contains(p), !chrome.menuContains(p) {
            list.scroll(by: dy)
        } else {
            return
        }
        dirty = true
        commit()
        frames?.renderNow()
    }

    private var lyricsPaneVisible: Bool { !lyricsHidden || arrangement == .compact }

    private func target(at p: CGPoint, chromeShown: Bool) -> Drag {
        if menu != .none {
            if let c = hitControl(at: p, chromeShown: true) { return .control(c) }
            if let area = chrome.scrollArea, area.rect.contains(p) { return .panelScroll(lastY: p.y) }
            // 点在菜单 / 面板里的空白处什么都不做;点在外面只关菜单(同歌词窗口的全窗捕手)。
            return chrome.menuContains(p) ? .none : .dismissMenu
        }
        if let c = hitControl(at: p, chromeShown: chromeShown) { return .control(c) }
        if chromeShown, chrome.volume(at: p, requireHit: true) != nil { return .volume }
        if !pane.isHidden, paneRect.contains(p), pane.transportInteractive,
           pane.progressHitFrame.contains(CGPoint(x: p.x - paneRect.minX, y: p.y - paneRect.minY)),
           PlaybackCoordinator.shared.acceptsSeek, currentDurationMs() > 0 {
            return .progress
        }
        if !pane.isHidden, pane.transportAbsorbs(CGPoint(x: p.x - paneRect.minX, y: p.y - paneRect.minY)) { return .none }
        if !list.isHidden, lyricsPaneVisible, listFrame.contains(p) {
            return .lyrics(startY: p.y, lastY: p.y, moved: false, seeks: chromeShown)
        }
        return .none
    }

    private func hitControl(at p: CGPoint, chromeShown: Bool) -> WebLyricsControl? {
        if menu != .none { return chrome.menuContains(p) ? chrome.control(at: p) : nil }
        if chromeShown, let c = chrome.control(at: p) { return c }
        guard !pane.isHidden, paneRect.contains(p) else { return nil }
        let local = CGPoint(x: p.x - paneRect.minX, y: p.y - paneRect.minY)
        if let c = pane.sideControl(at: local) { return c }
        guard pane.transportInteractive else { return nil }
        return pane.button(at: local).map { .transport($0) }
    }

    private func activate(_ c: WebLyricsControl) {
        switch c {
        case let .transport(button):
            guard perform(button) else { return }
            pane.press(button)
        case .favorite:
            PlaybackCoordinator.shared.toggleFavorited()
            pane.press(side: c)
        case .more:
            menu = menu == .more ? .none : .more
            pane.press(side: c)
        case .translation:
            menu = menu == .translation ? .none : .translation
            chrome.press(c)
        case .lyricsToggle:
            lyricsHidden.toggle()
            chrome.press(c)
        case .mute:
            PlaybackCoordinator.shared.toggleMute()
            chrome.press(c)
        case .translationRow:
            menu = .none
            AppSettings.shared.showTranslation.toggle()
        case .romanizationRow:
            menu = .none
            AppSettings.shared.showRomanization.toggle()
        case .offsetReset:
            PlaybackCoordinator.shared.resetLyricsOffset()
        case .offsetMinus:
            _ = PlaybackCoordinator.shared.nudgeLyricsOffset(by: -AppSettings.shared.lyricsOffsetStepMs)
        case .offsetPlus:
            _ = PlaybackCoordinator.shared.nudgeLyricsOffset(by: AppSettings.shared.lyricsOffsetStepMs)
        case .libraryAdd:
            moreMenu.addToLibrary()
        case .libraryRemove:
            moreMenu.removeFromLibrary(expectedTitle: playback.title)
        case .suggestLess:
            moreMenu.toggleSuggestLess(expectedTitle: playback.title)
        case .showInfo:
            menu = .info
        case let .showEditorial(kind):
            panelScroll = 0
            menu = .editorial(kind)
        case .showCharts:
            menu = .charts
            LastfmStatsService.shared.refreshChart(kind: chartKind, period: chartPeriod)
        case let .chartKind(kind):
            chartKind = kind
            LastfmStatsService.shared.refreshChart(kind: chartKind, period: chartPeriod)
        case let .chartPeriod(period):
            chartPeriod = period
            LastfmStatsService.shared.refreshChart(kind: chartKind, period: chartPeriod)
        case .chartRetry:
            LastfmStatsService.shared.refreshChart(kind: chartKind, period: chartPeriod)
        case let .chartRow(index):
            if let entries = LastfmStatsService.shared.chart(chartKind, chartPeriod), entries.indices.contains(index) {
                LyricsMoreMenuModel.openChartEntry(entries[index], kind: chartKind)
            }
        case .lastfmLove:
            LastfmLoveModel.shared.toggle()
        case .platform:
            menu = .none
        }
    }

    private func seekToLine(at p: CGPoint) {
        guard !list.isHidden, listFrame.contains(p),
              let index = list.lineIndex(at: NSPoint(x: p.x - listFrame.minX, y: p.y - listFrame.minY)),
              playback.allLines.indices.contains(index) else { return }
        // 减去当前歌词偏移,同歌词窗口的 onTapLine
        PlaybackCoordinator.shared.seek(
            toMs: max(0, playback.allLines[index].timeMs - PlaybackCoordinator.shared.currentLyricsOffsetMs))
    }

    /// 执行了返回 true。播放控制被拦下时上一首 / 播放 / 下一首不执行;随机、循环只在画出来时能点。
    private func perform(_ button: WebLyricsControlsLayout.Button) -> Bool {
        let mode = playback.playbackMode
        let options = playback.playbackModeOptions
        switch button {
        case .previous, .playPause, .next:
            guard playback.controlsWithheldReason == nil else { return false }
            switch button {
            case .previous: MusicPlaybackController.previousTrack()
            case .next: MusicPlaybackController.nextTrack()
            default: PlaybackCoordinator.shared.userTogglePlayPause()
            }
        case .shuffle:
            guard mode != nil, options.contains(.shuffle) else { return false }
            PlaybackCoordinator.shared.setPlaybackMode(mode == .shuffle ? .list : .shuffle)
        case .repeatMode:
            guard mode != nil, options.canRepeat else { return false }
            PlaybackCoordinator.shared.setPlaybackMode(
                (mode ?? .list).nextRepeat(allowsRepeatOne: options.contains(.repeatOne),
                                           allowsRepeatAll: options.contains(.repeatAll)))
        }
        return true
    }

    // MARK: - 布局

    private var width: CGFloat { CGFloat(viewport.width) }
    private var height: CGFloat { CGFloat(viewport.height) }
    /// 封面边长照歌词窗口按宽度算,另按高度封顶:左栏整组约「封面 + 160」高、居中后再上挪 `paneVerticalOffset`,
    /// 又宽又矮的画面(手机横放)只按宽度算会把封面上缘挤出画面。歌词窗口有最小高度,碰不到。
    private var coverWidth: CGFloat { max(80, min(width * 0.279, 460, height - 216)) }
    private var arrangement: WebLyricsViewport.Arrangement { viewport.arrangement }
    /// 安全区四边(点):背景铺满整幅,顶上那一块、歌词左右边距、胶囊和右下一排让开这几条边。
    private var safeTop: CGFloat { CGFloat(viewport.safeArea.top) }
    private var safeLeft: CGFloat { CGFloat(viewport.safeArea.left) }
    private var safeRight: CGFloat { CGFloat(viewport.safeArea.right) }
    /// 平板竖放时:左右边距、顶上那一块的上缘和高(= 封面边长),歌词从它下面 24 开始。
    private var stackedSide: CGFloat { max(24, (width * 0.06).rounded()) }
    private var stackedCover: CGFloat { min(width * 0.28, 280).rounded() }
    private static let stackedTop: CGFloat = 64
    private var listX: CGFloat { width * 0.111 + coverWidth }
    /// 左栏在画面里的框(左上为原点,y 向下,同指针坐标);设给图层时经 `wrapperFrame` 翻一次。
    private var paneRect: CGRect = .zero
    /// 指针坐标(y 向下)的框换成外层画布上的 frame:外层整幅上下翻过一次(Metal 纹理原点在左下),直接挂在它下面的图层
    /// 和视图 y 向上。占满整高的框翻不翻都一样,竖排时顶上那一块、下面的歌词不翻就上下颠倒。
    private func wrapperFrame(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }
    /// 歌词列表(和空状态)占的那一块(y 向下):左右两栏时是右栏;竖排、手机时在顶上那一块下面、占满整宽。
    private var listFrame: CGRect {
        switch arrangement {
        case .columns:
            return CGRect(x: listX, y: 0, width: width - listX, height: height)
        case .stacked:
            let top = Self.stackedTop + safeTop + stackedCover + 24
            return CGRect(x: 0, y: top, width: width, height: height - top)
        case .compact:
            let top = WebLyricsPlayerPane.compactHeaderBottom + safeTop + 12
            return CGRect(x: 0, y: top, width: width, height: height - top)
        }
    }
    private var listLeading: CGFloat {
        switch arrangement {
        case .columns: return max(24, width * 0.515 - (width * 0.111 + coverWidth))
        case .stacked: return stackedSide + safeLeft
        case .compact: return WebLyricsPlayerPane.compactSide + safeLeft
        }
    }
    private var listTrailing: CGFloat {
        switch arrangement {
        case .columns: return max(32, width * 0.06) + safeRight
        case .stacked: return stackedSide + safeRight
        case .compact: return WebLyricsPlayerPane.compactSide + safeRight
        }
    }
    /// 字号按歌词那一栏的宽算;竖排、手机时那一栏是整宽,扣掉左右边距再算,不然平板竖放时字比横放还大一圈。
    private var fontSize: CGFloat {
        let column = arrangement == .columns ? width - listX : width - listLeading - listTrailing
        return LyricsWindowTypography.listFontSize(columnWidth: column, viewportHeight: height)
    }
    private var paneStyle: WebLyricsPlayerPane.Style {
        switch arrangement {
        case .columns: return .column
        case .stacked: return lyricsPaneVisible ? .row : .column
        case .compact: return .compact
        }
    }

    private func layoutComponents() {
        list.frame = wrapperFrame(listFrame)
        emptyState.frame = wrapperFrame(listFrame)
    }

    // MARK: - 每一拍

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        timerInterval = interval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.commit() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 播放状态一变就在这一轮主线程空下来时提交,不等下一拍;同一轮里变好几样只提交一次。
    private func scheduleCommit() {
        dirty = true
        guard !commitScheduled else { return }
        commitScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.commitScheduled = false
                self.commit()
            }
        }
    }

    /// 歌名刚空、还没满 `idleHold`:这段时间不重搭模型、不走进度,画面停在上一首。满了补提交一次。
    private func holdsThroughGap(_ now: CFTimeInterval) -> Bool {
        guard playback.title.isEmpty else {
            titleEmptySince = nil
            return false
        }
        guard shownIdle == false else { return false }
        if titleEmptySince == nil {
            titleEmptySince = now
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleHold + 0.05) { [weak self] in
                MainActor.assumeIsolated { self?.commit() }
            }
        }
        return now - (titleEmptySince ?? now) < Self.idleHold
    }

    /// 每次提交前:提前量往目标挪一步;在播时按它重解一次歌词行,变了就重搭模型,并在下一次会变的时刻补一次提交。
    private func updateLead(_ now: CFTimeInterval) {
        let position = currentPositionMs()
        // 按歌词时钟算「在放」:暂停通知先到、锚点冻住时 isPlayingNow 还没翻,按它的话会接着提前画下一句、晚一拍才发现暂停。
        let playing = playback.lyricsClockRunning
        let rate = playback.anchor.map { $0.rate > 0 ? $0.rate : 1 } ?? 1
        if let window = WebLyricsPredictionCut.window(leadMs: appliedLeadMs, previous: lastTimeline, positionMs: position,
                                                      now: now, playing: playing, rate: rate) {
            pendingCutFrom = window.from
            let expected = lastTimeline.map { $0.positionMs + Int((now - $0.at) * 1000 * rate) } ?? position
            Self.log.notice("web lyrics cut: \(playing ? "seek" : "pause", privacy: .public) at \(position, privacy: .public)ms (expected \(expected, privacy: .public)ms, lead \(self.appliedLeadMs, privacy: .public)ms, drop \(Int(now * 1000 - window.from), privacy: .public)ms back)")
        }
        lastTimeline = (position, now, playing)
        let elapsed = leadUpdatedAt.map { now - $0 } ?? 0
        leadUpdatedAt = now
        let reach = Self.leadSlewPerSecond * elapsed * 1000
        leadExact += max(-reach, min(reach, Double(leadTargetMs) - leadExact))
        let stepped = Int((leadExact / Double(Self.leadStepMs)).rounded()) * Self.leadStepMs
        if stepped != leadMs {
            leadMs = stepped
            dirty = true
        }
        let next = playing && leadMs > 0 ? PlaybackCoordinator.shared.lyricsLookahead(leadMs: leadMs) : nil
        if next != lookahead {
            lookahead = next
            dirty = true
        }
        lookaheadTimer?.invalidate()
        lookaheadTimer = nil
        guard let wait = next?.nextChangeInMs else { return }
        let t = Timer(timeInterval: max(0.005, Double(wait) / 1000 / rate + 0.005), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.commit() }
        }
        RunLoop.main.add(t, forMode: .common)
        lookaheadTimer = t
    }

    /// 主线程这一侧:状态变了重搭模型、走进度,拼好图层树提交进渲染树,再告诉出帧线程该用哪档节拍。
    private func commit() {
        let now = CACurrentMediaTime()
        updateLead(now)
        let holding = holdsThroughGap(now)
        if dirty, !holding {
            dirty = false
            syncModel()
            fastUntil = now + Self.transitionHold
        }
        if !holding {
            let duration = currentDurationMs()
            pane.updateProgress(positionMs: scrubFraction.map { Int($0 * Double(duration)) } ?? currentPositionMs() + appliedLeadMs,
                                durationMs: duration)
        }
        chromeIdle.held = menu != .none
        if case .none = drag { chromeIdle.mouseDown = false } else { chromeIdle.mouseDown = true }
        let chromeVisible = LyricsWindowChromeIdle.isVisible(chromeIdle, now: Date())
        if chromeVisible != chromeShown {
            chromeShown = chromeVisible
            chrome.setChromeVisible(chromeVisible, animated: true)
            pane.setTransportVisible(chromeVisible, animated: true)
            list.setIndicatorVisible(chromeVisible)
            fastUntil = now + Self.transitionHold
        }
        // 不挂窗口、没有父视图时 AppKit 不会替它们跑 layout():歌词列表的渐隐遮罩、背景光斑的位置都在 layout() 里定,
        // 不手动跑一次就是零尺寸遮罩,整列歌词被遮掉。
        list.layoutSubtreeIfNeeded()
        backdrop.layoutSubtreeIfNeeded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let backdropLayer = backdrop.layer, !backdropLayer.isHidden { DetachedLayerTree.assemble(backdrop) }
        if !list.isHidden { DetachedLayerTree.assemble(list) }
        for view in [backdrop, list] as [NSView] {
            view.layer?.anchorPoint = .zero
            view.layer?.position = view.frame.origin
            view.layer?.bounds = CGRect(origin: .zero, size: view.frame.size)
        }
        CATransaction.commit()
        CATransaction.flush()
        if let from = pendingCutFrom {
            pendingCutFrom = nil
            onText?(WebLyricsPredictionCut.message((from, CACurrentMediaTime() * 1000 + WebLyricsPredictionCut.settleMs)))
        }

        let active = viewersVisible && (playback.isPlayingNow || now < fastUntil)
        frames?.setPace(fast: active)
        let interval = active ? Self.modelInterval : Self.idleModelInterval
        if interval != timerInterval { scheduleTimer(interval: interval) }
    }

    private var isIdle: Bool { playback.title.isEmpty }

    private var lyricsOnHold: Bool { playback.isRadioTalkBreak || playback.isCurrentTrackAdBreak }

    private var effectiveBackgroundMode: LyricsWindowBackgroundMode {
        playback.backgroundMode == .glass ? .artwork : playback.backgroundMode
    }

    private var isDarkAppearance: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// 同歌词窗口的 `hasArtworkBackground`:这一刻背景是不是暗的。纯色 / 渐变背后没有桌面,按黑底算。
    private var hasArtworkBackground: Bool {
        switch effectiveBackgroundMode {
        case .artwork, .glass:
            return playback.artworkData != nil || playback.highResArtworkImage != nil || playback.windowBackgroundLayers != nil
        case .solid:
            return LyricsWindowBackgroundLuma.prefersLightText(hexes: [playback.backgroundColorHex],
                                                               darkAppearance: isDarkAppearance, backdropLuma: 0)
        case .gradient:
            return LyricsWindowBackgroundLuma.prefersLightText(hexes: [playback.backgroundColorHex, playback.backgroundColorEndHex],
                                                               darkAppearance: isDarkAppearance, backdropLuma: 0)
        }
    }

    private func resolved(_ color: Color) -> NSColor {
        var out = NSColor(color)
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { out = NSColor(color).usingColorSpace(.sRGB) ?? out }
        return out
    }

    private func syncModel() {
        shownIdle = isIdle
        let onArtwork = hasArtworkBackground
        let tone = playback.textColorMode.tone(hasArtworkBackground: onArtwork)
        let text: NSColor
        let secondary: NSColor
        switch tone {
        case .white:
            text = .white
            secondary = NSColor.white.withAlphaComponent(0.73)
        case .systemPrimary:
            text = resolved(.primary)
            secondary = resolved(.secondary)
        case .dark:
            text = NSColor.black.withAlphaComponent(0.85)
            secondary = NSColor.black.withAlphaComponent(0.5)
        case .custom:
            text = resolved(playback.textColor)
            secondary = text.withAlphaComponent(text.alphaComponent * 0.73)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyBackground(onArtwork: onArtwork)

        let state = LyricsWindowEmptyState.resolve(.init(
            hasTitle: !isIdle, isAdBreak: playback.isCurrentTrackAdBreak, isRadioTalkBreak: playback.isRadioTalkBreak,
            isInstrumental: playback.isCurrentTrackInstrumental, hasNoLyrics: playback.currentTrackHasNoLyrics,
            engineNetworkDown: playback.engineNetworkDown, hasLyricsContent: playback.hasLyricsContent,
            isPlaying: playback.isPlayingNow))
        let showsList = !isIdle && !lyricsOnHold && !playback.allLines.isEmpty
        list.isHidden = !showsList
        emptyState.isHidden = showsList
        if !showsList {
            emptyState.frame = isIdle ? CGRect(x: 0, y: 0, width: width, height: height) : wrapperFrame(listFrame)
            emptyState.show(icon: state.icon, text: Self.emptyText(state), onArtwork: onArtwork,
                            color: onArtwork ? NSColor.white.withAlphaComponent(0.75) : secondary)
        }
        pane.isHidden = isIdle
        if isIdle || (menu != .none && menu != .translation && pane.isHidden) { menu = .none }
        if case let .editorial(kind) = menu, EditorialNotesStore.shared.card(kind) == nil { menu = .none }
        placePane()
        let fadeTarget: Float = lyricsPaneVisible ? 1 : 0
        for layer in [list.layer, emptyState].compactMap({ $0 }) where layer.opacity != fadeTarget {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = layer.presentation()?.opacity ?? layer.opacity
            a.toValue = fadeTarget
            a.duration = 0.35
            layer.opacity = fadeTarget
            layer.add(a, forKey: "lyrimuse.web-lyrics-pane")
        }
        let hasTranslation = playback.allLines.contains { $0.line.translation != nil }
        let hasRomanization = playback.allLines.contains { $0.line.romanization != nil }
        refreshCount()
        // 左栏藏起来(停播)时 apply 不再调,动态封面在这里停:不然播放器会一直静音循环解码,出帧线程每拍照样取帧。
        if pane.isHidden { pane.motion.update(file: nil, playing: false) }
        if !pane.isHidden {
            pane.apply(.init(
                style: paneStyle,
                artwork: (playback.highResArtworkImage ?? playback.artworkImage)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                motionFile: playback.motionCoverFile,
                motionPlaying: playback.isPlayingSmoothed && viewersVisible,
                title: playback.isCurrentTrackAdBreak ? L10n.t("广告中") : playback.displayTitle,
                artistAlbum: playback.isCurrentTrackAdBreak ? "" : Self.artistAlbum(playback.displayArtist, playback.displayAlbum),
                primary: onArtwork ? .white : resolved(.primary),
                secondary: onArtwork ? resolved(amVibrantColor(layers: playback.windowBackgroundLayers, satScale: 0.5, satCap: 0.45,
                                                               brightness: 0.85, fallback: .white.opacity(0.6),
                                                               minContrastToBackground: 0.25)) : resolved(.secondary),
                timeColor: onArtwork ? resolved(amVibrantColor(layers: playback.windowBackgroundLayers, satScale: 0.62, satCap: 0.5,
                                                               brightness: 0.68, fallback: .white.opacity(0.6),
                                                               minContrastToBackground: 0.25)) : resolved(.secondary),
                barFill: onArtwork ? resolved(amVibrantColor(layers: playback.windowBackgroundLayers, satScale: 0.5, satCap: 0.4,
                                                             brightness: 0.92, fallback: .white.opacity(0.85)))
                    : resolved(.primary).withAlphaComponent(0.85),
                shadowOpacity: onArtwork ? 0.45 : 0.2,
                isPlaying: playback.isPlayingSmoothed,
                height: height, verticalOffset: Self.paneVerticalOffset, safeArea: viewport.safeArea,
                controls: .init(
                    shuffleShown: playback.playbackMode != nil && playback.playbackModeOptions.contains(.shuffle),
                    shuffleActive: playback.playbackMode == .shuffle,
                    repeatShown: playback.playbackMode != nil && playback.playbackModeOptions.canRepeat,
                    repeatActive: playback.playbackMode == .repeatOne || playback.playbackMode == .repeatAll,
                    repeatOne: playback.playbackMode == .repeatOne,
                    withheld: playback.controlsWithheldReason != nil,
                    activeFill: onArtwork ? NSColor.white.withAlphaComponent(0.22)
                        : resolved(.primary).withAlphaComponent(0.12),
                    reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion),
                favorited: playback.isFavorited,
                countText: countText,
                onArtwork: onArtwork))
        }
        syncMoreMenu()
        let primary = onArtwork ? NSColor.white : resolved(.primary)
        chrome.apply(.init(
            onArtwork: onArtwork, primary: primary, darkPanels: onArtwork || isDarkAppearance,
            volume: isIdle || arrangement == .compact ? nil : PlaybackCoordinator.shared.soundVolume,
            showsTranslationButton: !isIdle && playback.hasLyricsContent && (hasTranslation || hasRomanization)
                && lyricsPaneVisible,
            translationActive: playback.showTranslation && hasTranslation,
            showsLyricsToggle: !isIdle && arrangement != .compact,
            lyricsShown: !lyricsHidden,
            menu: menu, hasTranslation: hasTranslation, hasRomanization: hasRomanization,
            showTranslation: playback.showTranslation, showRomanization: playback.showRomanization,
            offsetMs: PlaybackCoordinator.shared.trackLyricsOffsetMs,
            moreAnchor: pane.isHidden ? nil : pane.moreButtonFrame.offsetBy(dx: paneRect.minX, dy: paneRect.minY),
            moreItems: menu == .more ? moreItems() : [],
            infoRows: menu == .info ? infoRows() : [],
            editorialCard: { if case let .editorial(kind) = menu { return EditorialNotesStore.shared.card(kind) }; return nil }(),
            charts: menu == .charts ? chartsState() : nil,
            panelScroll: panelScroll,
            accent: resolved(.accentColor),
            bottomInset: arrangement == .compact && !pane.isHidden ? max(0, height - pane.transportFrame.minY) : 0,
            safeArea: viewport.safeArea,
            size: CGSize(width: width, height: height),
            scale: CGFloat(viewport.pixelWidth) / width))
        sendLinks()
        CATransaction.commit()

        if showsList {
            let fs = fontSize
            let columnWidth = listFrame.width
            let style = LyricsLayerRowStyle(
                fontSize: fs, romaFontSize: fs * 0.54, translationFontSize: fs * 0.57,
                fontFamily: playback.lyricsFontFamily, textColor: text, secondaryColor: secondary,
                showRomanization: playback.showRomanization, showTranslation: playback.showTranslation,
                centered: false, wordRise: true, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                duetInsetUnit: LyricDuetLayout.insets(for: .leading, availableWidth: columnWidth, fontSize: fs).trailing,
                scale: CGFloat(viewport.scale))
            list.apply(LyricsLayerList.Spec(
                lines: playback.allLines, gapMarkers: playback.lyricsGapMarkersByIndex, songwriters: playback.songwriters,
                style: style, lineSpacing: fs * 0.98, showsScrollIndicator: true,
                leading: listLeading, trailing: listTrailing, onArtwork: onArtwork, suspendsBlur: false,
                currentLineIndex: lookahead.map(\.index) ?? playback.currentLineIndex,
                scrollLineIndex: lookahead.map(\.scrollIndex) ?? playback.scrollLineIndex,
                overlapping: Set(lookahead?.overlappingIndices ?? playback.overlappingLineIndices),
                currentGapIndex: lookahead.map(\.gapIndex) ?? playback.currentGapIndex,
                // 提前画到了下一句时,这一句刚开唱、还没填完;同一句时照用这一句填完没有
                fillSettled: lookahead.map { $0.index == playback.currentLineIndex } ?? true ? playback.currentLineFillSettled : false,
                isPlaying: playback.lyricsClockRunning, surfaceVisible: true,
                timingEpoch: LyricsTimingEpoch.of(anchor: playback.anchor, pausedPositionMs: playback.pausedPositionMs,
                                                  offsetMs: PlaybackCoordinator.shared.currentLyricsOffsetMs + appliedLeadMs),
                rate: playback.anchor?.rate ?? 1))
        }
    }

    /// 「…」菜单刚打开、或开着时换了歌:刷新资料库状态和平台链接(同歌词窗口开菜单时 `moreMenu.refresh`);
    /// Last.fm「喜欢」那一行开着菜单时才去取状态。
    private func syncMoreMenu() {
        let track = menu == .more ? "\(playback.title)|\(playback.artist)|\(playback.album)" : nil
        guard track != moreMenuTrack else { return }
        if moreMenuTrack == nil, track != nil { LastfmLoveModel.shared.retain() }
        if moreMenuTrack != nil, track == nil { LastfmLoveModel.shared.release() }
        moreMenuTrack = track
        if track != nil { moreMenu.refresh(title: playback.title, artist: playback.artist, album: playback.album) }
    }

    /// 「…」菜单的各项,顺序与文案同歌词窗口 `moreMenuPanel`;「前往专辑」「前往歌手」「在 XX 中显示」(都在 Mac 上跳页,
    /// 在别的设备上点了那台设备上什么都不发生)和「搜索歌词…」不放。
    private func moreItems() -> [WebLyricsMoreItem] {
        func row(_ key: String, _ control: WebLyricsControl, trailing: String? = nil, enabled: Bool = true,
                 link: URL? = nil) -> WebLyricsMoreItem {
            .row(title: key, trailing: trailing, enabled: enabled, control: control, link: link)
        }
        var items: [WebLyricsMoreItem] = []
        if LyricsMoreMenuModel.isAppleMusicPlayer {
            switch moreMenu.libraryAddState {
            case .idle: items.append(row(L10n.t("添加到资料库"), .libraryAdd))
            case .failed: items.append(row(L10n.t("添加失败"), .libraryAdd, trailing: "arrow.clockwise"))
            case .alreadyInLibrary: items.append(row(L10n.t("从资料库删除"), .libraryRemove))
            case .adding: items.append(row(L10n.t("添加中…"), .libraryAdd, enabled: false))
            case .added: items.append(row(L10n.t("已添加"), .libraryAdd, trailing: "checkmark", enabled: false))
            case .removing: items.append(row(L10n.t("删除中…"), .libraryRemove, enabled: false))
            case .removeFailed: items.append(row(L10n.t("删除失败"), .libraryRemove, trailing: "arrow.clockwise"))
            }
            let applied = moreMenu.suggestLessApplied
            items.append(row(L10n.t(applied ? "已减少推荐" : "减少推荐"), .suggestLess, trailing: applied ? "checkmark" : nil))
        }
        let platformRows = moreMenu.platformRows
        if !platformRows.isEmpty {
            for r in platformRows {
                items.append(row(LyricsMoreMenuModel.title(of: r), .platform(r.id), link: r.url))
            }
            items.append(.divider)
        }
        if LyricsMoreMenuModel.isAppleMusicPlayer { items.append(.divider) }
        items.append(row(L10n.t("显示简介"), .showInfo))
        let editorial = EditorialNotesStore.shared
        if editorial.song != nil { items.append(row(L10n.t("显示歌曲简介"), .showEditorial(.song))) }
        if editorial.artist != nil { items.append(row(L10n.t("显示歌手简介"), .showEditorial(.artist))) }
        if editorial.album != nil { items.append(row(L10n.t("显示专辑简介"), .showEditorial(.album))) }
        let love = LastfmLoveModel.shared
        if love.target != nil {
            let loved = love.loved == true
            items.append(row(L10n.t(loved ? "已在 Last.fm 上喜欢" : "在 Last.fm 上喜欢"), .lastfmLove,
                             trailing: loved ? "checkmark" : nil))
        }
        if LastfmStatsService.shared.isConnected { items.append(row(L10n.t("你的常听"), .showCharts)) }
        items.append(.offset)
        return items
    }

    /// 「显示简介」各行,同歌词窗口 `trackInfoPanel`:歌名、歌手、专辑、时长、播放器、歌词形态、来源、本平台的网页,
    /// 连着 Last.fm 时再加累计次数与首次 / 上次收听。
    private func infoRows() -> [WebLyricsInfoRow] {
        let track = "\(playback.title)|\(playback.artist)|\(playback.album)"
        if infoDetails?.track != track {
            infoDetails = (track,
                           EnrichCacheReader.sourceInfo(artist: playback.artist, title: playback.title, album: playback.album)?
                               .lyricsSource,
                           EnrichCacheReader.platformLinks(artist: playback.artist, title: playback.title, album: playback.album))
            if !playback.title.isEmpty, LastfmStatsService.shared.isConnected {
                LastfmStatsService.shared.refreshNowPlayingCount(title: playback.title, artist: playback.artist)
                LastfmStatsService.shared.refreshNowPlayingSpan(title: playback.title, artist: playback.artist)
            }
        }
        let lyricsKind: String = {
            if playback.hasLyricsContent {
                var parts = [L10n.t(playback.allLines.contains { $0.line.words != nil } ? "逐字歌词" : "逐行歌词")]
                if playback.allLines.contains(where: { $0.line.translation != nil }) { parts.append(L10n.t("译文")) }
                if playback.allLines.contains(where: { $0.line.romanization != nil }) { parts.append(L10n.t("读音")) }
                return parts.joined(separator: " · ")
            }
            if playback.isRadioTalkBreak { return L10n.t("口白") }
            if playback.isCurrentTrackInstrumental { return L10n.t("纯音乐") }
            if !playback.currentTrackPlainLyrics.isEmpty { return L10n.t("纯文本（无时间戳）") }
            return L10n.t("无歌词")
        }()
        var rows = [WebLyricsInfoRow(label: L10n.t("歌名"),
                                     value: playback.isCurrentTrackAdBreak ? L10n.t("广告中") : playback.displayTitle)]
        if !playback.displayArtist.isEmpty { rows.append(.init(label: L10n.t("歌手"), value: playback.displayArtist)) }
        if !playback.displayAlbum.isEmpty { rows.append(.init(label: L10n.t("专辑"), value: playback.displayAlbum)) }
        if let ms = playback.currentDurationMs {
            rows.append(.init(label: L10n.t("时长"), value: String(format: "%d:%02d", ms / 1000 / 60, ms / 1000 % 60)))
        }
        if let player = PlaybackCoordinator.shared.resolvedPlayerDisplayName {
            rows.append(.init(label: L10n.t("播放器"), value: player))
        }
        rows.append(.init(label: L10n.t("歌词"), value: lyricsKind))
        if let source = infoDetails?.source, !source.isEmpty {
            rows.append(.init(label: L10n.t("来源"), value: sourceDisplayName(source)))
        }
        if let link = infoDetails?.links?.songLink(forPlayerBundleID: PlaybackCoordinator.shared.resolvedPlayerBundleID,
                                                   webPlatformID: PlaybackCoordinator.shared.resolvedWebPlatformID) {
            rows.append(.init(label: L10n.t("网页"), value: LyricsWindowView.platformDisplayName(link.platform), link: link.url))
        }
        let stats = LastfmStatsService.shared
        if stats.isConnected {
            if let n = stats.nowPlayingCount {
                rows.append(.init(label: L10n.t("累计"), value: String(format: L10n.t("第 %@ 次收听"), "\(n)")))
            }
            if let span = stats.nowPlayingSpan, span.total > 0 {
                if let first = span.first {
                    rows.append(.init(label: L10n.t("首次收听"),
                                      value: first.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: L10n.locale))))
                }
                if let last = span.last {
                    rows.append(.init(label: L10n.t("上次收听"),
                                      value: last.formatted(Date.RelativeFormatStyle(presentation: .named, locale: L10n.locale))))
                }
            }
        }
        return rows
    }

    private func chartsState() -> WebLyricsChartsState {
        let stats = LastfmStatsService.shared
        return WebLyricsChartsState(kind: chartKind, period: chartPeriod, entries: stats.chart(chartKind, chartPeriod),
                                    loading: stats.chartLoading(chartKind, chartPeriod),
                                    failed: stats.chartFailed(chartKind, chartPeriod))
    }

    /// 菜单里平台页那几行的位置(画面相对坐标)和网址,变了就告诉网页:手机浏览器只肯在手指抬起那一刻开新标签页,
    /// 等 App 回话再开会被拦掉,所以由网页自己判、自己开,在看副屏的那台设备上打开。
    private func sendLinks() {
        let items: [[Any]] = chrome.linkTargets.map { target in
            [Double(target.rect.minX / width), Double(target.rect.minY / height),
             Double(target.rect.width / width), Double(target.rect.height / height), target.url.absoluteString]
        }
        // 键要排序:不排时同样的内容两次序列化键序会不同,「没变就不重发」比不出来
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "links", "items": items], options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8), text != sentLinks else { return }
        sentLinks = text
        onText?(text)
    }

    /// 左右两栏:左缘显示歌词时 0.111W;隐藏歌词时封面挪到正中,沿 `.smooth(duration: 0.35)` 那条弹簧过去(同歌词窗口)。
    /// 平板竖放:顶上那一块;隐藏歌词时换成歌词窗口那种封面在上的一列,摆在正中、封面放大。手机:铺满整幅。
    private func placePane() {
        switch arrangement {
        case .columns:
            break
        case .stacked:
            let side = min(width * 0.6, height - 216, 520).rounded()
            paneRect = lyricsPaneVisible
                ? CGRect(x: stackedSide + safeLeft, y: Self.stackedTop + safeTop,
                         width: width - stackedSide * 2 - safeLeft - safeRight, height: stackedCover)
                : CGRect(x: ((width - side) / 2).rounded(), y: 0, width: side, height: height)
            pane.frame = wrapperFrame(paneRect)
            paneX = paneRect.minX
            return
        case .compact:
            paneRect = CGRect(x: 0, y: 0, width: width, height: height)
            pane.frame = paneRect
            paneX = 0
            return
        }
        let target = lyricsPaneVisible ? width * 0.111 : (width - coverWidth) / 2
        let frame = CGRect(x: target, y: 0, width: coverWidth, height: height)
        paneRect = frame
        defer { paneX = target }
        guard let from = paneX, from != target else {
            pane.frame = frame
            return
        }
        let shown = pane.presentation()?.position.x ?? pane.position.x
        pane.frame = frame
        let spring = CASpringAnimation(keyPath: "position.x")
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / 0.35, 2)
        spring.damping = 4 * .pi / 0.35
        spring.fromValue = shown
        spring.toValue = pane.position.x
        spring.duration = spring.settlingDuration
        pane.add(spring, forKey: "lyrimuse.web-lyrics-pane-x")
    }

    /// 时间行正中的「收听次数」(连了 Last.fm 才有),同歌词窗口 `NowPlayingCountBadge`;换歌时请它取一次数。
    private var countText: String? {
        guard LastfmStatsService.shared.isConnected, !playback.title.isEmpty,
              let n = LastfmStatsService.shared.nowPlayingCount else { return nil }
        return String(format: L10n.t("收听次数：%@"), "\(n)")
    }

    private func refreshCount() {
        let key = "\(playback.artist)|\(playback.title)"
        guard key != countKey else { return }
        countKey = key
        guard !playback.title.isEmpty, LastfmStatsService.shared.isConnected else { return }
        LastfmStatsService.shared.refreshNowPlayingCount(title: playback.title, artist: playback.artist)
    }

    private func applyBackground(onArtwork: Bool) {
        let mode = effectiveBackgroundMode
        let usesArtwork = mode == .artwork
        if usesArtwork, let layers = playback.windowBackgroundLayers {
            backdrop.apply(layers: layers, animating: playback.isPlayingNow)
            backdrop.layer?.isHidden = false
            dimLayer.isHidden = false
            fillLayer.isHidden = true
        } else {
            backdrop.layer?.isHidden = true
            dimLayer.isHidden = true
            fillLayer.isHidden = false
            switch mode {
            case .solid:
                let c = resolved(playback.backgroundColor).cgColor
                fillLayer.colors = [c, c]
            case .gradient:
                fillLayer.colors = [resolved(playback.backgroundColor).cgColor, resolved(playback.backgroundColorEnd).cgColor]
                let vertical = playback.gradientDirection == .vertical
                // 图层坐标 y 向上:竖向渐变从顶(y=1)到底(y=0)。
                fillLayer.startPoint = vertical ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 0, y: 0.5)
                fillLayer.endPoint = vertical ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 1, y: 0.5)
            case .artwork, .glass:
                // 跟随封面却还没有封面(或背景还没烘焙好):歌词窗口这时什么都不画,露出的是窗口底色,文字走系统前景色;
                // 这里照画窗口底色。别填黑:浅色外观下前景色是黑的,整幅变成黑字压黑底。
                let c = resolved(Color(nsColor: .windowBackgroundColor)).cgColor
                fillLayer.colors = [c, c]
            }
        }
    }

    private func currentPositionMs() -> Int {
        playback.anchor?.extrapolatedPositionMs(now: Date()) ?? playback.pausedPositionMs ?? 0
    }

    private func currentDurationMs() -> Int {
        playback.anchor?.durationMs ?? playback.currentDurationMs ?? 0
    }

    static func artistAlbum(_ artist: String, _ album: String) -> String {
        [artist, album].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    static func emptyText(_ state: LyricsWindowEmptyState) -> String {
        switch state {
        case .notPlaying: return L10n.t("未在播放")
        case .adBreak: return L10n.t("广告中")
        case .radioTalk: return L10n.t("口白")
        case .instrumental: return L10n.t("纯音乐")
        case .noLyrics: return L10n.t("暂无歌词")
        case .networkDown: return L10n.t("网络连接失败")
        case .searching: return L10n.t("搜索歌词中…")
        case .none: return L10n.t("无歌词")
        }
    }
}

/// 副屏的出帧线程:`CARenderer` 在自己的串行队列上按固定节拍画进 IOSurface 像素缓冲,GPU 画完后交给
/// VideoToolbox 编 JPEG,不经过 CPU 读回。
///
/// 图层只归主线程改,提交之后才进渲染树;这里只画渲染树。换句滚动、逐字填色、背景光斑、按钮按下的弹回都是按时间推进的
/// Core Animation 动画,主线程不用逐帧参与,主线程忙的时候出帧节拍照样稳。像素缓冲轮着用三块:画下一帧时前两帧
/// 可以还在编码。见 19 章决策 5。
final class WebLyricsFrameSource: @unchecked Sendable {
    /// 暂停或停播时 5 帧:会动的东西都只在播放时动。在播时的档位(节拍、JPEG 质量、编码尺寸)由 `pacer` 定。
    private static let idleInterval: TimeInterval = 1.0 / 5
    /// 同时在 GPU 或编码器里的帧数上限;像素缓冲比它多一块,正在画的那块不会是正在编的。
    private static let maxFramesInFlight = 2
    private static let log = Logger(subsystem: "me.yudaotor.lyrimuse", category: "web-lyrics")

    private let queue = DispatchQueue(label: "me.yudaotor.lyrimuse.web-lyrics.frames", qos: .userInteractive)
    /// 缩放和编码在这条串行队列上按画的顺序一次一帧做:视频编码器要求帧按顺序交进去,别指望 Metal 完成回调线程的顺序。
    private let encodeQueue = DispatchQueue(label: "me.yudaotor.lyrimuse.web-lyrics.encode", qos: .userInteractive)
    private let timer: DispatchSourceTimer
    private let onFrame: @MainActor (WebLyricsScreenFrame) -> Void
    /// 每拍开画之前在出帧线程上调(动态封面取帧)。
    private let prepare: @Sendable () -> Void

    // 以下只在 `queue` 上读写。
    private let renderer: CARenderer
    private let commandQueue: MTLCommandQueue
    private let slots: [(buffer: CVPixelBuffer, texture: CVMetalTexture)]
    private let textureCache: CVMetalTextureCache
    private let pixelWidth: Int
    private let pixelHeight: Int
    /// 每种编码尺寸(渲染尺寸的几分之几)一个编码器,用到才建;档位来回换时不重建。视频流不用。
    private var encoders: [Double: WebLyricsFrameEncoder]
    /// 网页要的是视频流时的 H.264 编码器(不缩尺寸,改尺寸要重新开流);逐帧 JPEG 时 nil。
    private let videoEncoder: WebLyricsVideoEncoder?
    private var nextSlot = 0
    private var framesInFlight = 0
    private var fast = true
    private var interval: TimeInterval = 0
    /// 在播时的档位:按跳过的拍数和开画到 JPEG 编完的整段耗时挑一档匀速的,见 `WebLyricsFramePacer`。
    private var pacer: WebLyricsFramePacer
    private var stopped = false
    /// 此刻的节拍(帧 / 秒),诊断浮层在主线程读;只在 `queue` 上写。
    private let statsLock = NSLock()
    private var currentFps = 0
    var framesPerSecond: Int {
        statsLock.lock()
        defer { statsLock.unlock() }
        return currentFps
    }
    /// 这一尺寸的网页全都还有上一帧没发完(主线程报):这时画了也发不出去,跳过这一拍。
    private var sendBacklogged = false

    /// 在主线程上建:`root` 是整幅画面的根图层,之后只读它的渲染树。`minResolution` 是编码尺寸最多缩到渲染尺寸的
    /// 几分之几(像素倍数不低于 1);`video` 为真时编 H.264 视频流,不编逐帧 JPEG。
    @MainActor
    init?(root: CALayer, pixelWidth w: Int, pixelHeight h: Int, minResolution: Double = 0.5, video: Bool = false,
          prepare: @escaping @Sendable () -> Void = {}, onFrame: @escaping @MainActor (WebLyricsScreenFrame) -> Void) {
        guard let device = MTLCreateSystemDefaultDevice(), let commandQueue = device.makeCommandQueue() else { return nil }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache else { return nil }
        var made: [(buffer: CVPixelBuffer, texture: CVMetalTexture)] = []
        for _ in 0...Self.maxFramesInFlight {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
                                &buffer)
            var cvTexture: CVMetalTexture?
            if let buffer { CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, w, h, 0, &cvTexture) }
            guard let buffer, let cvTexture, CVMetalTextureGetTexture(cvTexture) != nil else { return nil }
            made.append((buffer, cvTexture))
        }
        guard let first = made.first.flatMap({ CVMetalTextureGetTexture($0.texture) }) else { return nil }
        let pacer = WebLyricsFramePacer(maxFramesInFlight: Self.maxFramesInFlight, minResolution: video ? 1 : minResolution,
                                        countsBacklog: !video)
        var jpeg: [Double: WebLyricsFrameEncoder] = [:]
        var videoEncoder: WebLyricsVideoEncoder?
        if video {
            guard let made = WebLyricsVideoEncoder(width: w, height: h) else { return nil }
            videoEncoder = made
        } else {
            guard let full = WebLyricsFrameEncoder(width: w, height: h, scaled: false, quality: pacer.step.quality) else { return nil }
            jpeg[1] = full
        }

        let r = CARenderer(mtlTexture: first, options: [kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                        kCARendererMetalCommandQueue: commandQueue])
        r.layer = root
        r.bounds = root.bounds
        renderer = r
        self.commandQueue = commandQueue
        slots = made
        textureCache = cache
        pixelWidth = w
        pixelHeight = h
        encoders = jpeg
        self.videoEncoder = videoEncoder
        self.pacer = pacer
        self.onFrame = onFrame
        self.prepare = prepare
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.tick() }
    }

    func start() {
        queue.async { self.reschedule() }
        timer.resume()
    }

    /// 主线程报这一刻该用哪档节拍:在播(或刚变过状态)用快档。
    func setPace(fast: Bool) {
        queue.async {
            guard self.fast != fast else { return }
            self.fast = fast
            self.pacer.resetWindow()
            self.reschedule()
        }
    }

    func setSendBacklogged(_ backlogged: Bool) {
        queue.async { self.sendBacklogged = backlogged }
    }

    /// 视频流:有网页要从关键帧开始(刚连上、掉过帧),下一帧编成关键帧(编码器自己限频)。
    func requestKeyFrame() {
        videoEncoder?.requestKeyFrame()
    }

    func setVideoBitRate(_ bitRate: Int) {
        videoEncoder?.setBitRate(bitRate)
    }

    /// 主线程刚提交了要立刻看到的变化(新网页连上、点了按钮):不等下一拍,马上补画一帧。
    func renderNow() {
        queue.async { self.tick() }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.timer.cancel()
            // 缩放、编码跑在 encodeQueue 上:作废排在已经派过去的那几帧后面,别跟它们并发(见 19 章决策 26)。
            let encoders = Array(self.encoders.values), video = self.videoEncoder
            self.encodeQueue.async {
                for encoder in encoders { encoder.invalidate() }
                video?.invalidate()
            }
        }
    }

    private func reschedule() {
        let target = fast ? pacer.interval : Self.idleInterval
        guard target != interval, !stopped else { return }
        interval = target
        statsLock.lock()
        currentFps = Int((1 / target).rounded())
        statsLock.unlock()
        timer.schedule(deadline: .now(), repeating: target, leeway: .milliseconds(1))
    }

    /// 这一档的编码器:尺寸按档位缩,质量按档位设。缩出来的尺寸取偶数(JPEG 按 2×2 块存色度)。
    private func encoder(for step: WebLyricsFrameStep) -> WebLyricsFrameEncoder? {
        let made: WebLyricsFrameEncoder?
        if let existing = encoders[step.resolution] {
            made = existing
        } else {
            let w = max(2, Int(Double(pixelWidth) * step.resolution / 2) * 2)
            let h = max(2, Int(Double(pixelHeight) * step.resolution / 2) * 2)
            made = WebLyricsFrameEncoder(width: w, height: h, scaled: true, quality: step.quality)
            encoders[step.resolution] = made
        }
        made?.setQuality(step.quality)
        return made
    }

    private func tick() {
        guard !stopped else { return }
        if sendBacklogged {
            notePace(.backlog)
            return
        }
        guard framesInFlight < Self.maxFramesInFlight else {
            notePace(.inFlight)
            return
        }
        guard let texture = CVMetalTextureGetTexture(slots[nextSlot].texture) else { return }
        let video = videoEncoder
        let jpeg = video == nil ? encoder(for: pacer.step) : nil
        guard video != nil || jpeg != nil else { return }
        prepare()
        let started = CACurrentMediaTime()
        let pixelBuffer = slots[nextSlot].buffer
        nextSlot = (nextSlot + 1) % slots.count
        renderer.setDestination(texture)
        renderer.beginFrame(atTime: started, timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        framesInFlight += 1
        let presentation = CMTime(value: CMTimeValue(started * 1000), timescale: 1000)
        // 同一条命令队列按提交顺序执行:这条空命令跑完时,CARenderer 那一帧已经画进像素缓冲。
        let encodeQueue = encodeQueue
        commandBuffer.addCompletedHandler { [weak self] _ in encodeQueue.async {
            if let video {
                video.encode(pixelBuffer, at: presentation, stamp: started * 1000) { frame in self?.finish(frame, renderedAt: started) }
            } else {
                jpeg?.encode(pixelBuffer, at: presentation) { data in
                    self?.finish(data.map { Self.jpegFrame($0, renderedAt: started) }, renderedAt: started)
                }
            }
        } }
        commandBuffer.commit()

        pacer.noteDraw(CACurrentMediaTime() - started)
        notePace(.none)
    }

    /// 在播时每一拍记一笔,档位变了按新间隔重排节拍(质量、尺寸下一拍取编码器时跟着换)。暂停、停播时的 5 帧不参与。
    private func notePace(_ skip: WebLyricsFrameSkip) {
        guard fast, pacer.tick(at: CACurrentMediaTime(), skipped: skip) else { return }
        let step = pacer.step
        Self.log.notice("web lyrics pace: \(Int((1 / step.interval).rounded()), privacy: .public) fps, quality \(step.quality, privacy: .public), size \(step.resolution, privacy: .public)x (skipped \(Int(self.pacer.lastSkipRatio * 100), privacy: .public)%, draw \(Int(self.pacer.drawCost * 1000), privacy: .public)ms, pipeline \(Int(self.pacer.pipelineCost * 1000), privacy: .public)ms)")
        reschedule()
    }

    /// 逐帧 JPEG 发出去的一帧 = 画它的时刻(毫秒,大端 Float64,网页按它匀速放)+ JPEG,在编码回调的线程上就包成
    /// WebSocket 二进制帧:拼帧、拷贝整帧数据别放回主线程做,放歌时它们每秒要占主线程二十多毫秒。
    private static func jpegFrame(_ jpeg: Data, renderedAt: CFTimeInterval) -> WebLyricsScreenFrame {
        var stamp = (renderedAt * 1000).bitPattern.bigEndian
        var payload = Data(capacity: 8 + jpeg.count)
        payload.append(Data(bytes: &stamp, count: 8))
        payload.append(jpeg)
        return WebLyricsScreenFrame(data: WebSocketFrame.encode(payload, opcode: .binary), isKeyFrame: true,
                                    stamp: renderedAt * 1000, payloadBytes: payload.count)
    }

    /// 编完一帧(包好的消息,失败给 nil):记账,交给主线程分发。
    private func finish(_ frame: WebLyricsScreenFrame?, renderedAt: CFTimeInterval) {
        let pipeline = CACurrentMediaTime() - renderedAt
        queue.async {
            self.framesInFlight -= 1
            self.pacer.noteEncoded(pipeline: pipeline)
        }
        guard let frame else { return }
        let onFrame = onFrame
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onFrame(frame) }
        }
    }
}

/// 一种编码尺寸的 JPEG 编码器。比渲染尺寸小时先用 VideoToolbox 的缩放会话(GPU)缩进池里的像素缓冲再编,渲染照旧按原尺寸,
/// 档位来回换不用重建渲染器;网页把画布按 CSS 铺满,帧小了只是放大显示。在出帧线程上建、设质量,编码在 GPU 完成回调的线程上。
final class WebLyricsFrameEncoder: @unchecked Sendable {
    private let session: VTCompressionSession
    private let transfer: VTPixelTransferSession?
    private let pool: CVPixelBufferPool?
    private var quality: Double

    init?(width: Int, height: Int, scaled: Bool, quality: Double) {
        var compression: VTCompressionSession?
        VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_JPEG,
                                   encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                   outputCallback: nil, refcon: nil, compressionSessionOut: &compression)
        guard let compression else { return nil }
        VTSessionSetProperty(compression, key: kVTCompressionPropertyKey_Quality, value: quality as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(compression)
        if scaled {
            var t: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &t)
            var p: CVPixelBufferPool?
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &p)
            guard let t, let p else {
                VTCompressionSessionInvalidate(compression)
                return nil
            }
            transfer = t
            pool = p
        } else {
            transfer = nil
            pool = nil
        }
        session = compression
        self.quality = quality
    }

    func setQuality(_ next: Double) {
        guard next != quality else { return }
        quality = next
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: next as CFNumber)
    }

    /// 编一帧,`done` 在编码回调的线程上收到 JPEG(失败给 nil)。
    func encode(_ source: CVPixelBuffer, at time: CMTime, done: @escaping (Data?) -> Void) {
        var input = source
        if let transfer, let pool {
            var scaled: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &scaled) == kCVReturnSuccess, let scaled,
                  VTPixelTransferSessionTransferImage(transfer, from: source, to: scaled) == noErr else {
                done(nil)
                return
            }
            input = scaled
        }
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: input, presentationTimeStamp: time, duration: .invalid, frameProperties: nil, infoFlagsOut: nil
        ) { status, _, sample in
            var jpeg: Data?
            if status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample) {
                var length = 0
                var pointer: UnsafeMutablePointer<CChar>?
                if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                               dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer {
                    jpeg = Data(bytes: pointer, count: length)
                }
            }
            done(jpeg)
        }
        if status != noErr { done(nil) }
    }

    func invalidate() {
        VTCompressionSessionInvalidate(session)
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
    }
}

/// 歌词窗口左栏的图层版(封面卡 + 歌名 + 歌手 — 专辑 + 进度),尺寸照 `LyricsWindowView.playerPane`:
/// 封面圆角 12、阴影半径 26 / 下移 12;封面底到歌名 19、歌名 17pt 半粗、歌手行 15.5pt、两行各 22 高叠 −3;
/// 歌手行到进度条 19、进度条 6 高、时间行 11pt 等宽数字、两者相隔 5;进度到播放控制 17。播放控制五颗键的位置和
/// 字号见 `WebLyricsControlsLayout`,不透明度照歌词窗口(播放 0.85、上 / 下一首 0.72、随机 / 循环熄灭 0.55,
/// 控制被拦下时主三键再乘 `withheldControlOpacity`),按下缩到 0.8 再弹回(同 `TransportButtonStyle`)。
/// 整组跟歌词窗口一样垂直居中。暂停时封面缩到 0.732,弹簧 0.5s / 阻尼 0.72。
///
/// 竖着的画面另有两种排法(`Style`,见 `WebLyricsViewport.Arrangement`):平板竖放时封面在左、信息在右的一块;
/// 手机上顶上一行小封面 + 歌名,进度和播放键是底部一块圆角底,跟着控件闲置收起。
@MainActor
final class WebLyricsPlayerPane: CALayer {
    /// `column` 歌词窗口左栏(封面在上);`row` 封面在左、歌名 / 进度 / 播放键在右;`compact` 顶上一行 + 底部播放条。
    enum Style: Equatable { case column, row, compact }

    /// 手机那种排法顶上那一行:左右边距、上缘、小封面边长;歌词从 `compactHeaderBottom` 往下 12 开始。
    static let compactSide: CGFloat = 24
    static let compactTop: CGFloat = 16
    static let compactCover: CGFloat = 44
    static var compactHeaderBottom: CGFloat { compactTop + compactCover }
    /// 底部播放条离画面下缘、左右缘的距离。
    static let compactBarMargin: CGFloat = 12

    struct Content {
        var style: Style
        var artwork: CGImage?
        /// 动态封面的本地 mp4,nil = 没有(或总闸关着);`motionPlaying` 是此刻该不该动。
        var motionFile: URL?
        var motionPlaying: Bool
        var title: String
        var artistAlbum: String
        var primary: NSColor
        var secondary: NSColor
        var timeColor: NSColor
        var barFill: NSColor
        var shadowOpacity: Float
        var isPlaying: Bool
        var height: CGFloat
        var verticalOffset: CGFloat
        /// 手机那种排法里顶上一行和底部播放条让开的边。
        var safeArea: WebLyricsViewport.SafeArea
        var controls: Controls
        /// nil = 这个播放器没有「喜欢」,不画星。
        var favorited: Bool?
        /// 时间行正中的「收听次数」,nil 不画。
        var countText: String?
        var onArtwork: Bool

        /// 前景色是深色(浅色外观、没有封面背景),底部播放条的底跟着取浅色。
        var isDarkPrimary: Bool {
            (primary.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) < 0.5
        }
    }

    struct Controls {
        var shuffleShown: Bool
        var shuffleActive: Bool
        var repeatShown: Bool
        var repeatActive: Bool
        var repeatOne: Bool
        var withheld: Bool
        /// 随机 / 循环点亮时那圈胶囊底的颜色。
        var activeFill: NSColor
        var reduceMotion: Bool
    }

    private let coverHost = CALayer()
    private let cover = CALayer()
    /// 盖在静态封面上的动态封面,出帧线程每拍取帧(`WebLyricsMotionCover.pullFrame`)。
    let motion = WebLyricsMotionCover()
    /// 歌名、歌手行是跑马灯,字自己画成位图:`CATextLayer` 按 `.end` 截断过长的一行时整行往上错位、上半截被裁掉。
    private let titleLayer = WebLyricsMarqueeLayer()
    private let artistLayer = WebLyricsMarqueeLayer()
    /// 标题行右边的圆钮:星(有「喜欢」的播放器才有)和「…」;歌词窗口那颗设置齿轮不画。
    private let favoriteCircle = CALayer()
    private let favoriteGlyph = CALayer()
    private let moreCircle = CALayer()
    private let moreGlyph = CALayer()
    private let countLayer = CALayer()
    private(set) var moreButtonFrame: CGRect = .zero
    private var favoriteButtonFrame: CGRect?
    private let barTrack = CALayer()
    private let barFill = CALayer()
    private let elapsedLayer = CATextLayer()
    private let durationLayer = CATextLayer()
    /// 两个时间各占的那一格(14 高),字在格子里竖直居中。
    private var elapsedSlot = CGRect.zero
    private var durationSlot = CGRect.zero
    private let glyphs: [WebLyricsControlsLayout.Button: CALayer] = Dictionary(
        uniqueKeysWithValues: WebLyricsControlsLayout.Button.allCases.map { ($0, CALayer()) })
    private let shuffleFill = CALayer()
    private let repeatFill = CALayer()
    private var controlsLayout: WebLyricsControlsLayout?
    /// 播放控制那一排的左缘(左栏坐标);`controlsLayout` 的格子从 0 起算。
    private var controlsX: CGFloat = 0
    /// 进度、时间、播放控制这一组;手机那种排法里整组跟着控件闲置淡出,别的排法一直露着。
    private let transportGroup = CALayer()
    /// 手机那种排法里底部播放条的圆角底。
    private let transportPanel = CALayer()
    /// 底部播放条的框(左栏坐标),只在 `compact` 时有意义。
    private(set) var transportFrame: CGRect = .zero
    private var transportShown = true
    private var content: Content?
    private var playingShown: Bool?
    private var artworkShown: CGImage?

    override init() {
        super.init()
        isGeometryFlipped = true
        for l in [coverHost, cover, titleLayer, artistLayer, barTrack, barFill, elapsedLayer, durationLayer] as [CALayer] {
            l.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "string": NSNull(),
                         "foregroundColor": NSNull(), "backgroundColor": NSNull(), "shadowOpacity": NSNull()]
        }
        cover.cornerRadius = 12
        cover.cornerCurve = .continuous
        cover.masksToBounds = true
        cover.contentsGravity = .resizeAspectFill
        cover.addSublayer(motion.layer)
        coverHost.addSublayer(cover)
        coverHost.shadowColor = NSColor.black.cgColor
        coverHost.shadowRadius = 26
        coverHost.shadowOffset = CGSize(width: 0, height: 12)
        addSublayer(coverHost)
        for l in [titleLayer, artistLayer] { addSublayer(l) }
        for l in [favoriteCircle, favoriteGlyph, moreCircle, moreGlyph] { addSublayer(l) }
        WebLyricsDraw.noActions([favoriteCircle, favoriteGlyph, moreCircle, moreGlyph, countLayer, transportGroup,
                                 transportPanel])
        addSublayer(transportGroup)
        transportPanel.cornerCurve = .continuous
        transportGroup.addSublayer(transportPanel)
        transportGroup.addSublayer(countLayer)
        for t in [elapsedLayer, durationLayer] {
            t.truncationMode = .end
            t.isWrapped = false
            transportGroup.addSublayer(t)
        }
        durationLayer.alignmentMode = .right
        barTrack.cornerRadius = 3
        barFill.cornerRadius = 3
        transportGroup.addSublayer(barTrack)
        transportGroup.addSublayer(barFill)
        for l in [shuffleFill, repeatFill] + Array(glyphs.values) {
            l.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "opacity": NSNull(),
                         "hidden": NSNull(), "backgroundColor": NSNull(), "cornerRadius": NSNull()]
            transportGroup.addSublayer(l)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ next: Content) {
        content = next
        motion.update(file: next.controls.reduceMotion ? nil : next.motionFile, playing: next.motionPlaying)
        let scale = contentsScaleForText
        transportGroup.frame = bounds
        transportPanel.isHidden = next.style != .compact
        switch next.style {
        case .column: layoutColumn(next, scale: scale)
        case .row: layoutRow(next, scale: scale)
        case .compact: layoutCompact(next, scale: scale)
        }
        applyTransportOpacity(animated: false)
    }

    /// 歌词窗口左栏:封面在上,下面歌名、进度、播放键,整组竖直居中。
    private func layoutColumn(_ next: Content, scale: CGFloat) {
        let w = bounds.width
        let play = min(33, max(17, w * 0.079))
        let controlsHeight = (play * 1.21).rounded()
        let total = w + 19 + 41 + 19 + 6 + 5 + 13 + 17 + controlsHeight
        let top = ((next.height - total) / 2 - next.verticalOffset).rounded()
        placeCover(next, side: w, origin: CGPoint(x: 0, y: top), small: false)
        var y = top + w + 19
        layoutTitleRow(next, x: 0, rowTop: y, width: w, scale: scale)
        y += 22 - 3 + 22 + 19
        y = layoutProgress(next, x: 0, barTop: y, width: w, scale: scale)
        layoutControls(next, x: 0, width: w, rowTop: y + 13 + 17, rowHeight: controlsHeight, scale: scale)
    }

    /// 平板竖放时顶上那一块:封面占满这一块的高,右边隔 24 是歌名、进度、播放键,在封面高度里竖直居中。
    private func layoutRow(_ next: Content, scale: CGFloat) {
        let side = bounds.height
        placeCover(next, side: side, origin: .zero, small: false)
        let x = side + 24
        let w = bounds.width - x
        let play = min(33, max(17, w * 0.079))
        let controlsHeight = (play * 1.21).rounded()
        let total = 41 + 18 + 6 + 5 + 13 + 16 + controlsHeight
        var y = ((side - total) / 2).rounded()
        layoutTitleRow(next, x: x, rowTop: y, width: w, scale: scale)
        y += 41 + 18
        y = layoutProgress(next, x: x, barTop: y, width: w, scale: scale)
        layoutControls(next, x: x, width: w, rowTop: y + 13 + 16, rowHeight: controlsHeight, scale: scale)
    }

    /// 手机:顶上一行小封面 + 歌名(两行跟封面竖直居中);底部一块圆角底装进度、时间、播放键,左右、下缘各留 12,
    /// 里面左右 14。都从安全区量起,底部横条比 12 高时播放条贴着它上面。
    private func layoutCompact(_ next: Content, scale: CGFloat) {
        let safe = next.safeArea
        let side = Self.compactSide + CGFloat(safe.left), top = Self.compactTop + CGFloat(safe.top), c = Self.compactCover
        placeCover(next, side: c, origin: CGPoint(x: side, y: top), small: true)
        let x = side + c + 12
        layoutTitleRow(next, x: x, rowTop: (top + (c - 41) / 2).rounded(),
                       width: bounds.width - Self.compactSide - CGFloat(safe.right) - x, scale: scale)
        let margin = Self.compactBarMargin
        let barLeft = margin + CGFloat(safe.left)
        let panelWidth = bounds.width - margin * 2 - CGFloat(safe.left + safe.right)
        let inner = panelWidth - 28
        let play = min(33, max(17, inner * 0.079))
        let controlsHeight = (play * 1.21).rounded()
        let panelHeight = 14 + 6 + 5 + 13 + 10 + controlsHeight + 10
        transportFrame = CGRect(x: barLeft, y: bounds.height - max(margin, CGFloat(safe.bottom)) - panelHeight,
                                width: panelWidth, height: panelHeight)
        transportPanel.frame = transportFrame
        transportPanel.cornerRadius = 20
        let panelFill: NSColor = next.onArtwork ? NSColor.black.withAlphaComponent(0.5)
            : next.isDarkPrimary ? NSColor(white: 0.97, alpha: 0.92) : NSColor(white: 0.13, alpha: 0.92)
        transportPanel.backgroundColor = panelFill.cgColor
        transportPanel.borderWidth = 0.5
        transportPanel.borderColor = (next.onArtwork ? NSColor.white.withAlphaComponent(0.16)
                                                     : next.primary.withAlphaComponent(0.12)).cgColor
        let timeTop = layoutProgress(next, x: barLeft + 14, barTop: transportFrame.minY + 14, width: inner, scale: scale)
        layoutControls(next, x: barLeft + 14, width: inner, rowTop: timeTop + 13 + 10, rowHeight: controlsHeight, scale: scale)
    }

    /// 封面卡、换封面淡入、暂停缩小。`small`(手机顶上那一格)圆角和投影按小尺寸收,也不随暂停缩放。
    private func placeCover(_ next: Content, side: CGFloat, origin: CGPoint, small: Bool) {
        // 封面卡带着暂停时的缩小变换,只能设 bounds + position:设 frame 会按当前缩放反算 bounds,
        // 暂停时设一次,继续播放缩放回到 1 时封面就大了 1/0.732 倍。
        let radius: CGFloat = small ? 6 : 12
        coverHost.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        coverHost.position = CGPoint(x: origin.x + side / 2, y: origin.y + side / 2)
        cover.frame = coverHost.bounds
        motion.layer.frame = cover.bounds
        cover.cornerRadius = radius
        coverHost.shadowRadius = small ? 6 : 26
        coverHost.shadowOffset = CGSize(width: 0, height: small ? 3 : 12)
        coverHost.shadowPath = CGPath(roundedRect: coverHost.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        coverHost.shadowOpacity = next.shadowOpacity
        if next.artwork !== artworkShown {
            artworkShown = next.artwork
            let fade = CABasicAnimation(keyPath: "contents")
            fade.duration = 0.5
            cover.add(fade, forKey: "contents-fade")
            cover.contents = next.artwork
            cover.backgroundColor = next.artwork == nil ? next.primary.withAlphaComponent(0.1).cgColor : nil
        }
        // `playingShown` 记的是封面此刻是不是原大(小封面不随暂停缩)。
        let fullSize = next.isPlaying || small
        if fullSize != playingShown {
            let target = CATransform3DMakeScale(fullSize ? 1 : 0.732, fullSize ? 1 : 0.732, 1)
            if playingShown != nil {
                let spring = CASpringAnimation(keyPath: "transform")
                spring.mass = 1
                spring.stiffness = pow(2 * .pi / 0.5, 2)
                spring.damping = 4 * .pi * 0.72 / 0.5
                spring.fromValue = coverHost.presentation()?.transform ?? coverHost.transform
                spring.toValue = target
                spring.duration = spring.settlingDuration
                coverHost.add(spring, forKey: "scale")
            }
            coverHost.transform = target
            playingShown = fullSize
        }
    }

    /// 进度条(6 高)与下面隔 5 的时间行(两个时间 + 正中的收听次数),返回时间行的上缘。
    private func layoutProgress(_ next: Content, x: CGFloat, barTop y: CGFloat, width w: CGFloat, scale: CGFloat) -> CGFloat {
        barTrack.frame = CGRect(x: x, y: y, width: w, height: 6)
        barTrack.backgroundColor = next.primary.withAlphaComponent(0.25).cgColor
        barFill.backgroundColor = next.barFill.cgColor
        let timeTop = y + 6 + 5
        elapsedSlot = CGRect(x: x, y: timeTop, width: w / 2, height: 14)
        durationSlot = CGRect(x: x + w / 2, y: timeTop, width: w / 2, height: 14)
        elapsedLayer.frame = Self.timeFrame(in: elapsedSlot)
        durationLayer.frame = Self.timeFrame(in: durationSlot)
        countLayer.isHidden = next.countText == nil
        if let text = next.countText {
            WebLyricsDraw.place(countLayer, WebLyricsDraw.text(text, font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                                color: next.timeColor, scale: scale),
                                center: CGPoint(x: x + w / 2, y: elapsedSlot.midY), scale: scale)
        }
        return timeTop
    }

    /// 手机那种排法里,底部播放条跟着控件闲置淡入淡出(时长同 `LyricsWindowChromeIdle`);别的排法一直露着。
    func setTransportVisible(_ visible: Bool, animated: Bool) {
        transportShown = visible
        applyTransportOpacity(animated: animated)
    }

    /// 底部播放条收着时,点在那里只唤出控件,不算按到键、不拖进度。
    var transportInteractive: Bool { content?.style != .compact || transportShown }

    /// 底部播放条露着时,点在圆角底的空白处也归它(不往下落到歌词上跳句)。
    func transportAbsorbs(_ point: CGPoint) -> Bool {
        content?.style == .compact && transportShown && transportFrame.contains(point)
    }

    private func applyTransportOpacity(animated: Bool) {
        let target: Float = transportInteractive ? 1 : 0
        let from = transportGroup.presentation()?.opacity ?? transportGroup.opacity
        transportGroup.opacity = target
        guard animated, from != target else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = target
        a.duration = target == 1 ? LyricsWindowChromeIdle.fadeInSeconds : LyricsWindowChromeIdle.fadeOutSeconds
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        transportGroup.add(a, forKey: "lyrimuse.web-transport-fade")
    }

    /// 标题行(同 `trackInfoRow`):左边歌名、歌手两行跑马灯(各 22 高、叠 −3,左端渐隐 24、右端 32),右边 26 的圆钮
    /// 星、「…」间隔 8,跟两行字整体竖直居中;字和圆钮之间至少 12 + 8 + 12。圆底有封面背景时白 0.16、否则前景色 0.08,
    /// 字形 14pt 半粗、前景色 0.9。
    private func layoutTitleRow(_ next: Content, x: CGFloat, rowTop y: CGFloat, width w: CGFloat, scale: CGFloat) {
        let buttons: CGFloat = next.favorited == nil ? 26 : 26 + 8 + 26
        let textWidth = max(40, w - buttons - 32)
        let animating = !next.controls.reduceMotion
        titleLayer.show(next.title, font: .systemFont(ofSize: 17, weight: .semibold), color: next.primary,
                        frame: CGRect(x: x, y: y, width: textWidth, height: 22), scale: scale,
                        leadingFade: 24, trailingFade: 32, animating: animating)
        artistLayer.show(next.artistAlbum, font: .systemFont(ofSize: 15.5), color: next.secondary,
                         frame: CGRect(x: x, y: y + 19, width: textWidth, height: 22), scale: scale,
                         leadingFade: 24, trailingFade: 32, animating: animating)
        let centerY = y + 41 / 2
        let fill = (next.onArtwork ? NSColor.white.withAlphaComponent(0.16) : next.primary.withAlphaComponent(0.08)).cgColor
        let ink = next.primary.withAlphaComponent(0.9)
        moreButtonFrame = CGRect(x: x + w - 26, y: centerY - 13, width: 26, height: 26)
        circle(moreCircle, moreGlyph, frame: moreButtonFrame, fill: fill,
               glyph: WebLyricsDraw.symbol("ellipsis", size: 14, weight: .semibold, color: ink, scale: scale), scale: scale)
        favoriteCircle.isHidden = next.favorited == nil
        favoriteGlyph.isHidden = next.favorited == nil
        favoriteButtonFrame = nil
        if let favorited = next.favorited {
            let frame = CGRect(x: moreButtonFrame.minX - 8 - 26, y: moreButtonFrame.minY, width: 26, height: 26)
            favoriteButtonFrame = frame
            circle(favoriteCircle, favoriteGlyph, frame: frame, fill: fill,
                   glyph: WebLyricsDraw.symbol(favorited ? "star.fill" : "star", size: 14, weight: .semibold, color: ink,
                                               scale: scale), scale: scale)
        }
    }

    private func circle(_ base: CALayer, _ glyph: CALayer, frame: CGRect, fill: CGColor,
                        glyph made: (image: CGImage, size: CGSize)?, scale: CGFloat) {
        base.frame = frame
        base.cornerRadius = frame.height / 2
        base.backgroundColor = fill
        WebLyricsDraw.place(glyph, made, center: CGPoint(x: frame.midX, y: frame.midY), scale: scale)
    }

    /// 标题行右边点中的圆钮(左栏坐标)。手指比鼠标粗,圆钮四周各让 6 点。
    func sideControl(at point: CGPoint) -> WebLyricsControl? {
        guard content != nil else { return nil }
        if moreButtonFrame.insetBy(dx: -4, dy: -6).contains(point) { return .more }
        if let f = favoriteButtonFrame, f.insetBy(dx: -4, dy: -6).contains(point) { return .favorite }
        return nil
    }

    func press(side control: WebLyricsControl) {
        switch control {
        case .favorite: WebLyricsDraw.press([favoriteCircle, favoriteGlyph], to: 0.9)
        case .more: WebLyricsDraw.press([moreCircle, moreGlyph], to: 0.9)
        default: break
        }
    }

    /// 进度条的命中区:只有那一条,上下各撑 9(同歌词窗口:下面的时间行点了不能跳)。
    var progressHitFrame: CGRect { barTrack.frame.insetBy(dx: 0, dy: -9) }

    /// 左栏横坐标对应的进度比例。
    func progressFraction(atX x: CGFloat) -> Double {
        let track = barTrack.frame
        guard track.width > 0 else { return 0 }
        return Double(min(1, max(0, (x - track.minX) / track.width)))
    }

    /// 点中哪颗键(左栏坐标,y 向下)。没画出来的随机 / 循环不算。
    func button(at point: CGPoint) -> WebLyricsControlsLayout.Button? {
        guard let controlsLayout, let content,
              let b = controlsLayout.button(at: CGPoint(x: point.x - controlsX, y: point.y)) else { return nil }
        switch b {
        case .shuffle: return content.controls.shuffleShown ? b : nil
        case .repeatMode: return content.controls.repeatShown ? b : nil
        default: return b
        }
    }

    /// 按下的反馈:缩到 0.8 再弹回(同歌词窗口 `TransportButtonStyle`:按下 0.1s easeOut、松手弹簧)。
    func press(_ button: WebLyricsControlsLayout.Button) {
        guard content?.controls.reduceMotion == false else { return }
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = [1, 0.8, 1.04, 1]
        pulse.keyTimes = [0, 0.24, 0.62, 1]
        pulse.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut),
                                 CAMediaTimingFunction(name: .easeInEaseOut)]
        pulse.duration = 0.42
        var layers = [glyphs[button]]
        if button == .shuffle { layers.append(shuffleFill) }
        if button == .repeatMode { layers.append(repeatFill) }
        for l in layers.compactMap({ $0 }) { l.add(pulse, forKey: "press") }
    }

    private func layoutControls(_ next: Content, x: CGFloat, width w: CGFloat, rowTop: CGFloat, rowHeight: CGFloat,
                                scale: CGFloat) {
        let c = next.controls
        controlsX = x
        let skipFont = WebLyricsControlsLayout(width: w, rowTop: rowTop, rowHeight: rowHeight, skipGlyphWidth: 0).skipFontSize
        let skipWidth = Self.glyph("backward.fill", size: skipFont, color: next.primary, scale: scale)?.size.width ?? skipFont
        let layout = WebLyricsControlsLayout(width: w, rowTop: rowTop, rowHeight: rowHeight, skipGlyphWidth: skipWidth)
        controlsLayout = layout
        let mainOpacity: Float = c.withheld ? Float(PlaybackCoordinator.withheldControlOpacity) : 1
        let items: [(WebLyricsControlsLayout.Button, String, CGFloat, Float, Bool)] = [
            (.shuffle, "shuffle", layout.modeFontSize, c.shuffleActive ? 1 : 0.55, c.shuffleShown),
            (.previous, "backward.fill", layout.skipFontSize, 0.72 * mainOpacity, true),
            (.playPause, next.isPlaying ? "pause.fill" : "play.fill", layout.playFontSize, 0.85 * mainOpacity, true),
            (.next, "forward.fill", layout.skipFontSize, 0.72 * mainOpacity, true),
            (.repeatMode, c.repeatOne ? "repeat.1" : "repeat", layout.modeFontSize, c.repeatActive ? 1 : 0.55, c.repeatShown),
        ]
        for (button, name, size, opacity, shown) in items {
            guard let layer = glyphs[button], let cell = layout.cells[button] else { continue }
            layer.isHidden = !shown
            guard shown, let g = Self.glyph(name, size: size, color: next.primary, scale: scale) else { continue }
            layer.contents = g.image
            layer.contentsScale = scale
            layer.bounds = CGRect(origin: .zero, size: g.size)
            layer.position = CGPoint(x: x + cell.midX, y: cell.midY)
            layer.opacity = opacity
        }
        // 点亮态的胶囊底:字形四周内衬横 3、竖 4(同 modeToggleButton)。
        for (fill, button, active, shown) in [(shuffleFill, WebLyricsControlsLayout.Button.shuffle, c.shuffleActive, c.shuffleShown),
                                              (repeatFill, .repeatMode, c.repeatActive, c.repeatShown)] {
            let glyphSize = glyphs[button]?.bounds.size ?? .zero
            let size = CGSize(width: glyphSize.width + 6, height: glyphSize.height + 8)
            fill.isHidden = !(shown && active)
            fill.bounds = CGRect(origin: .zero, size: size)
            fill.position = glyphs[button]?.position ?? .zero
            fill.cornerRadius = size.height / 2
            fill.backgroundColor = c.activeFill.cgColor
        }
    }

    private static var glyphCache: [String: (image: CGImage, size: CGSize)] = [:]

    /// SF Symbol 按字号排好、填成一种颜色,按画面倍数画成位图。
    static func glyph(_ name: String, size: CGFloat, color: NSColor, scale: CGFloat) -> (image: CGImage, size: CGSize)? {
        let key = "\(name)|\(size)|\(color)|\(scale)"
        if let hit = glyphCache[key] { return hit }
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular)) else { return nil }
        let pt = symbol.size
        let pw = Int(ceil(pt.width * scale)), ph = Int(ceil(pt.height * scale))
        guard pw > 0, ph > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        symbol.draw(in: CGRect(origin: .zero, size: pt))
        NSGraphicsContext.restoreGraphicsState()
        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(origin: .zero, size: pt))
        guard let image = ctx.makeImage() else { return nil }
        if glyphCache.count > 64 { glyphCache.removeAll() }
        glyphCache[key] = (image, pt)
        return (image, pt)
    }

    func updateProgress(positionMs: Int, durationMs: Int) {
        guard let content, !isHidden else { return }
        let fraction = durationMs > 0 ? min(1, max(0, Double(positionMs) / Double(durationMs))) : 0
        let track = barTrack.frame
        barFill.frame = CGRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
        let scale = contentsScaleForText
        setText(elapsedLayer, Self.format(positionMs), color: content.timeColor, slot: elapsedSlot, scale: scale)
        setText(durationLayer, Self.format(durationMs), color: content.timeColor, slot: durationSlot, scale: scale)
    }

    private var contentsScaleForText: CGFloat {
        var layer: CALayer? = self
        while let l = layer {
            if l.transform.m11 != 1 { return abs(l.transform.m11) }
            layer = l.superlayer
        }
        return 2
    }

    private func setText(_ layer: CATextLayer, _ text: String, color: NSColor, slot: CGRect, scale: CGFloat) {
        let string = NSAttributedString(string: text, attributes: [.font: Self.timeFont, .foregroundColor: color])
        if (layer.string as? NSAttributedString) != string { layer.string = string }
        layer.frame = Self.timeFrame(in: slot)
        layer.contentsScale = scale
    }

    private static var timeFont: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .regular) }

    /// 时间字在格子里竖直居中后的 frame。只从格子算,别拿图层自己的 frame 当基准(19 章决策 14)。
    private static func timeFrame(in slot: CGRect) -> CGRect {
        let font = timeFont
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let inset = max(0, (slot.height - lineHeight) / 2).rounded()
        return CGRect(x: slot.minX, y: slot.minY + inset, width: slot.width, height: slot.height - inset)
    }

    static func format(_ ms: Int) -> String {
        let seconds = max(0, ms / 1000)
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

/// 没有歌词可画时的那一格(图标 40pt + 16pt 半粗文字,同歌词窗口封面背景上的自绘空状态)。
@MainActor
final class WebLyricsEmptyStateLayer: CALayer {
    private let icon = CALayer()
    private let label = CATextLayer()
    private var shown: (icon: String, text: String, color: NSColor)?

    override init() {
        super.init()
        isGeometryFlipped = true
        icon.contentsGravity = .resizeAspect
        label.alignmentMode = .center
        label.truncationMode = .end
        addSublayer(icon)
        addSublayer(label)
        for l in [icon, label] as [CALayer] {
            l.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "string": NSNull()]
        }
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(icon name: String, text: String, onArtwork: Bool, color: NSColor) {
        let scale: CGFloat = 3
        if shown?.icon != name || shown?.color != color {
            let config = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
                .applying(.init(paletteColors: [color]))
            icon.contents = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        label.string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: color,
        ])
        label.contentsScale = scale
        icon.contentsScale = scale
        shown = (name, text, color)
        let iconSize: CGFloat = 48
        let blockHeight = iconSize + 12 + 22
        let top = (bounds.height - blockHeight) / 2
        icon.frame = CGRect(x: (bounds.width - iconSize) / 2, y: top, width: iconSize, height: iconSize)
        label.frame = CGRect(x: 16, y: top + iconSize + 12, width: bounds.width - 32, height: 22)
    }
}
