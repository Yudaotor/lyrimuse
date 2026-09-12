import AVFoundation
import AppKit
import SwiftUI

/// Apple Music 动态封面的**播放层**(2026-09-09)。
///
/// 分工见 `MotionCoverStore` 头注;这一层只负责"把一个本地 mp4 无声地循环画在一块方形区域里",
/// 以及**该不该在放**。它是这个项目里第一次引入 AVFoundation。
///
/// 几个刻意的选择:
///
///   * **`AVPlayerLooper` 硬接循环**,不做 pingpong 倒放、也不做首尾交叉淡化 —— 实测 Apple 这段
///     素材首尾帧几乎一致(64² 缩略图上 R 通道平均绝对差 0.58/255、最大 4/255),它本身就是按无缝
///     循环做的。自己再叠一层淡化只会让画面在接缝处发虚。
///   * **不碰音频**。素材本来就没有音轨(`Anull`,`loadTracks(.audio)` 回 0 条),`isMuted` 仍然设上
///     是为了万一哪天 Apple 换了素材形态,也绝不可能盖住用户正在听的歌。
///   * **`isPlaying == false` 时 `pause()` 而不是拆掉播放器**:灵动岛收起/展开是高频动作(hover
///     就展开),每次重建 `AVPlayerItem` 要重新解封装、首帧还会闪一下。暂停的播放器几乎不耗
///     CPU,而 `removeFromSuperview` 那一刻才真正释放(见 `willMove(toWindow:)`)。
///   * **`resizeAspectFill`**:素材和所有消费面都是方的,理论上 aspect 一致;用 fill 是为了避免
///     某张素材比例差一两个像素时露出黑边。
struct MotionCoverView: NSViewRepresentable {
    /// 本地 mp4(由 `MotionCoverStore` 下好落盘的那份)。
    let file: URL
    /// 此刻该不该在动。调用方把省电闸门算好传进来 —— 见 `MotionCoverGate`。
    let isPlaying: Bool

    func makeNSView(context: Context) -> MotionCoverNSView {
        let view = MotionCoverNSView()
        view.load(file)
        view.setPlaying(isPlaying)
        return view
    }

    func updateNSView(_ view: MotionCoverNSView, context: Context) {
        view.load(file)          // 同一个文件时是空操作
        view.setPlaying(isPlaying)
    }
}

final class MotionCoverNSView: NSView {
    private var player: AVQueuePlayer?
    /// 必须**强持有** —— `AVPlayerLooper` 一旦被释放,循环就停在第一遍结束的地方。
    private var looper: AVPlayerLooper?
    private let playerLayer = AVPlayerLayer()
    /// SwiftUI 要求播的那份(离屏期间也记着)。
    private var desiredFile: URL?
    /// 播放器**实际**加载的那份。离屏时连播放器一起放掉,所以它会回到 nil,而 `desiredFile` 不会 ——
    /// 重新入窗时靠后者恢复。第一版把两者合成一个字段,离屏再入窗就恢复不出来、画面空着。
    private var loadedFile: URL?
    private var wantsPlaying = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        // 视频层自己不该拦鼠标 —— 它上面/下面都有可点的东西(封面卡点开歌词窗口、灵动岛整卡 hover)。
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func load(_ file: URL) {
        desiredFile = file
        // 离屏时不建播放器 —— 建了也没人看,白占一个解码器。入窗时 viewDidMoveToWindow 会补上。
        guard window != nil else { return }
        guard loadedFile != file else { return }
        loadedFile = file
        let item = AVPlayerItem(url: file)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        // ⚠️ 不碰 `actionAtItemEnd` / `items`:队列由 `AVPlayerLooper` 自己接管(它靠往队列里
        // 续 item 实现无缝循环),外面再去调度会跟它打架。
        looper = AVPlayerLooper(player: queue, templateItem: item)
        playerLayer.player = queue
        player = queue
        if wantsPlaying { queue.play() }
    }

    func setPlaying(_ playing: Bool) {
        guard wantsPlaying != playing else { return }
        wantsPlaying = playing
        if playing { player?.play() } else { player?.pause() }
    }

    /// 真正离屏(切屏幕镜像、关灵动岛、歌词窗口关掉)时把播放器整个放掉 —— 只 pause 的话
    /// 解码器和那 7 MB 的映射还挂在进程里。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            player?.pause()
            playerLayer.player = nil
            looper = nil
            player = nil
            loadedFile = nil
            wantsPlaying = false
        } else if let file = desiredFile {
            load(file)
        }
    }
}

// 省电闸门**不在这一层**:用户开关与低电量模式收在 `PlaybackCoordinator.refreshMotionCover`
// (那两个不是视图环境值,而两个消费面问的是同一个问题),`reduceMotion` 与"我这一面此刻可不可见"
// 由各消费面自己判。这里只负责"给我一个文件和一个该不该动,我把它画出来"。
