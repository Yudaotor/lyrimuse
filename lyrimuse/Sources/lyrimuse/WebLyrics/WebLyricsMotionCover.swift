import AVFoundation
import CoreVideo
import OSLog
import QuartzCore

/// 副屏左栏的动态封面。离屏的 `CARenderer` 画不进 `AVPlayerLayer`(视频画面由窗口服务器合成),所以这里不用视频图层:
/// 静音循环的播放器挂 `AVPlayerItemVideoOutput`,出帧线程每拍开画之前取出当前那一帧,把它的 IOSurface 贴成 `layer` 的内容。
/// 循环不用 `AVPlayerLooper`:挂在它那几份副本上的输出一帧都取不到。自己排两份、放完一份补一份;放到结尾跳回开头的
/// 做法每圈接缝要停 130ms,排队的只停 60ms 上下。
/// 放不放、放哪份跟歌词窗口那张封面卡同一套闸(`MotionCoverView`):有本地 mp4、没开减弱动态效果、在放、有网页看着。
/// 静态封面始终铺在底下,这一层到货时淡入。见 19 章决策 23。
final class WebLyricsMotionCover: @unchecked Sendable {
    private static let log = Logger(subsystem: "me.yudaotor.lyrimuse", category: "web-lyrics")
    let layer = CALayer()

    /// 排着的每一份各挂一个输出;出帧线程只认有新帧的那一个,不碰播放器。由 `lock` 保护。
    private var outputs: [ObjectIdentifier: AVPlayerItemVideoOutput] = [:]
    private let lock = NSLock()
    /// 正贴在图层上的那一帧,留着引用免得像素缓冲被回收复用。只在出帧线程上读写。
    private var shownBuffer: CVPixelBuffer?

    // 以下只在主线程上读写。
    private var player: AVQueuePlayer?
    private var asset: AVURLAsset?
    private var endObserver: NSObjectProtocol?
    private var file: URL?

    init() {
        layer.contentsGravity = .resizeAspectFill
        layer.opacity = 0
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    /// 主线程:这一刻该放哪份、动不动。`file` 为 nil 时淡出。
    @MainActor
    func update(file next: URL?, playing: Bool) {
        if next != file {
            file = next
            tearDown()
            if let next { load(next) } else { fade(to: 0) }
        }
        guard let player else { return }
        if playing, player.rate == 0 { player.play() } else if !playing, player.rate != 0 { player.pause() }
    }

    /// 出帧线程每拍开画之前调:有新的一帧就贴上,没有就留着上一帧。
    func pullFrame() {
        lock.lock()
        let current = Array(outputs.values)
        lock.unlock()
        let host = CACurrentMediaTime()
        for output in current {
            let time = output.itemTime(forHostTime: host)
            guard output.hasNewPixelBuffer(forItemTime: time),
                  let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
                  let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { continue }
            if shownBuffer == nil {
                Self.log.notice("web motion cover: first frame \(CVPixelBufferGetWidth(buffer), privacy: .public)x\(CVPixelBufferGetHeight(buffer), privacy: .public)")
            }
            shownBuffer = buffer
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = surface
            CATransaction.commit()
            return
        }
    }

    @MainActor
    private func load(_ url: URL) {
        Self.log.notice("web motion cover: load \(url.lastPathComponent, privacy: .public)")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        layer.contents = nil
        CATransaction.commit()
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.actionAtItemEnd = .advance
        player = queue
        asset = AVURLAsset(url: url)
        enqueue()
        enqueue()
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            MainActor.assumeIsolated { self?.itemFinished(item) }
        }
        fade(to: 1)
    }

    /// 在队尾补一份,挂上自己的输出。
    @MainActor
    private func enqueue() {
        guard let player, let asset else { return }
        let item = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        item.add(output)
        lock.lock()
        outputs[ObjectIdentifier(item)] = output
        lock.unlock()
        player.insert(item, after: nil)
    }

    /// 放完的那一份撤掉它的输出,队尾再补一份。别家播放器的通知(歌词窗口、灵动岛的动态封面)不认。
    @MainActor
    private func itemFinished(_ item: AVPlayerItem) {
        lock.lock()
        let mine = outputs.removeValue(forKey: ObjectIdentifier(item)) != nil
        lock.unlock()
        if mine { enqueue() }
    }

    @MainActor
    private func tearDown() {
        lock.lock()
        outputs = [:]
        lock.unlock()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player?.removeAllItems()
        player = nil
        asset = nil
    }

    /// 动态封面到货 / 撤掉走 0.5 秒交叉淡入淡出,同歌词窗口那张卡。
    @MainActor
    private func fade(to target: Float) {
        guard layer.opacity != target else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = layer.presentation()?.opacity ?? layer.opacity
        animation.toValue = target
        animation.duration = 0.5
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.opacity = target
        layer.add(animation, forKey: "motion-fade")
    }
}
