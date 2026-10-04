import AppKit
import Combine
import LyrimuseCore
import OSLog
import UserNotifications

/// 「换歌时显示通知」:换到一首歌、放稳了,弹一条系统通知(歌名,「歌手 — 专辑」,封面)。默认关。
///
/// 判据和文案在 `LyrimuseCore.NowPlayingNotice`,这里是管道:盯播放协调器的歌名 / 歌手,等这首放稳、真开始放、等这首
/// 自己的封面,投递。identifier 固定,新的一条替换旧的,通知中心里只留正在放的这一首;不带提示音(正在放歌)。
/// 点通知打开歌词窗口,分流在 `UnknownPlayerNotifier` 的 delegate(系统只允许一个)。授权跟其它通知共用
/// `UnknownPlayerNotifier.ensureAuthorized`,在设置页打开这个开关时请求。
@MainActor
final class NowPlayingNotifier {
    static let shared = NowPlayingNotifier()

    static let categoryID = "now-playing"
    /// 换歌后放多久才发:连按下一首时只给停下来的那一首发。
    static let settleDelay: Duration = .milliseconds(1_500)
    /// 换歌后最多等多久等它开始放。播放器换歌后常要先加载、缓冲或放完广告,十几秒后才真开始出声,
    /// 只在放稳那一刻看一眼会把这条通知丢掉;超过还没放就不发。见 14 章决策 48。
    static let playWait: Duration = .seconds(60)
    /// 开始放之后这首的封面最多再等多久。附的是界面上显示的那张(`NowPlayingNotice.coverPick`),高清替代要等
    /// 引擎查到封面地址再下载,比系统那份慢。换歌后一小段时间里两份都可能还是上一首的,所以只认换歌之后
    /// 到货的;等不到就不附图,不拿上一首的封面顶。
    static let artworkWait: Duration = .seconds(5)

    private let log = Logger(subsystem: "me.yudaotor.lyrimuse", category: "notify")
    private var startedAt = Date()
    private var sawTrack = false
    /// 最近一次歌名 / 歌手变化的时刻(不防抖),和那之后系统封面、高清替代各自到货的时刻。
    private var changedAt = Date.distantPast
    private var artworkArrivedAt = Date.distantPast
    private var highResArrivedAt = Date.distantPast
    private var observers: [AnyCancellable] = []
    private var task: Task<Void, Never>?

    func start() {
        guard observers.isEmpty else { return }
        startedAt = Date()
        let playback = PlaybackCoordinator.shared
        let track = Publishers.CombineLatest(playback.$title, playback.$artist)
        observers.append(track.removeDuplicates { $0 == $1 }.sink { [weak self] _ in self?.changedAt = Date() })
        observers.append(playback.$artworkData.dropFirst().sink { [weak self] _ in self?.artworkArrivedAt = Date() })
        observers.append(playback.$highResArtworkImage.dropFirst().sink { [weak self] image in
            if image != nil { self?.highResArrivedAt = Date() }
        })
        // 换歌时歌名、歌手先后各发一次,攒一下。空歌名(停播、元数据闪空)不算一首,停了再放同一首不重复弹。
        observers.append(
            track.debounce(for: .milliseconds(300), scheduler: RunLoop.main)
                .filter { !$0.0.isEmpty }
                .removeDuplicates { $0 == $1 }
                .sink { [weak self] title, artist in self?.trackChanged(title: title, artist: artist) })
    }

    /// 设置页的开关变了。打开时请求通知授权(用户刚点了这个开关,知道这是干什么用的);关掉时撤掉通知中心里挂着的那条。
    func enabledChanged(_ enabled: Bool) async {
        guard !enabled else {
            _ = await UnknownPlayerNotifier.shared.ensureAuthorized()
            return
        }
        task?.cancel()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.categoryID])
    }

    private func trackChanged(title: String, artist: String) {
        task?.cancel()
        let isFirstSighting = !sawTrack
        sawTrack = true
        let sinceStart = Date().timeIntervalSince(startedAt)
        guard AppSettings.shared.nowPlayingNotifications else { return }
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            await self?.announce(title: title, artist: artist, isFirstSighting: isFirstSighting, sinceStart: sinceStart)
        }
    }

    private func announce(title: String, artist: String, isFirstSighting: Bool, sinceStart: TimeInterval) async {
        let playback = PlaybackCoordinator.shared
        func stillPlaying() -> Bool {
            playback.title == title && playback.artist == artist && NowPlayingNotice.shouldAnnounce(
                enabled: AppSettings.shared.nowPlayingNotifications, title: title,
                isPlaying: playback.isPlayingSmoothed,
                isBreak: playback.isCurrentTrackAdBreak || playback.isRadioTalkBreak,
                appIsActive: NSApp.isActive, isFirstSighting: isFirstSighting, sinceStart: sinceStart)
        }
        let playDeadline = ContinuousClock.now + Self.playWait
        while !playback.isPlayingSmoothed, ContinuousClock.now < playDeadline {
            guard playback.title == title, playback.artist == artist else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
        }
        guard stillPlaying() else {
            log.notice("now playing notice skipped playing=\(playback.isPlayingSmoothed, privacy: .public) active=\(NSApp.isActive, privacy: .public) break=\(playback.isCurrentTrackAdBreak || playback.isRadioTalkBreak, privacy: .public) startup=\(isFirstSighting && sinceStart < NowPlayingNotice.startupGrace, privacy: .public)")
            return
        }
        let coverDeadline = ContinuousClock.now + Self.artworkWait
        func pickCover() -> NowPlayingNotice.CoverPick {
            NowPlayingNotice.coverPick(
                highResArrived: highResArrivedAt >= changedAt && playback.highResArtworkImage != nil,
                systemSettled: artworkArrivedAt >= changedAt, systemHasImage: playback.artworkData != nil,
                seeksHighRes: playback.seeksHighResCover, timedOut: ContinuousClock.now >= coverDeadline)
        }
        var cover = pickCover()
        while cover == .wait {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            cover = pickCover()
        }
        // 取图口径同界面。上一首的高清替代在换歌 300ms 后就撤了,这时在的只会是这首的。
        let image = cover == .noCover ? nil : playback.highResArtworkImage ?? playback.artworkImage
        guard stillPlaying(), await UnknownPlayerNotifier.shared.ensureAuthorized(), !Task.isCancelled else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = NowPlayingNotice.body(
            title: title, artist: playback.displayArtist.isEmpty ? artist : playback.displayArtist,
            album: playback.displayAlbum)
        content.categoryIdentifier = Self.categoryID
        content.threadIdentifier = Self.categoryID
        if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let artwork = await Self.artworkAttachment(cg) {
            content.attachments = [artwork]
        }
        guard !Task.isCancelled else { return }
        do {
            try await deliver(content, cover: cover)
        } catch let error where !content.attachments.isEmpty {
            // 附件验不过时系统连通知一起拒收;去掉封面再投一次。
            log.error("now playing announce with artwork failed: \(error.localizedDescription, privacy: .public)")
            content.attachments = []
            try? await deliver(content, cover: cover)
        } catch {
            log.error("now playing announce failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deliver(_ content: UNMutableNotificationContent, cover: NowPlayingNotice.CoverPick) async throws {
        let request = UNNotificationRequest(identifier: Self.categoryID, content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
        log.notice("announced now playing cover=\(cover.rawValue, privacy: .public) attached=\(!content.attachments.isEmpty, privacy: .public)")
    }

    /// 封面缩好写成临时 JPEG 交给通知(后台写);系统验过之后把文件挪进自己的存储,这里不用清。
    private static func artworkAttachment(_ image: CGImage) async -> UNNotificationAttachment? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-playing-\(UUID().uuidString).jpg")
        guard await Task.detached(operation: { NowPlayingNotice.writeArtworkJPEG(image, to: url) }).value,
              let attachment = try? UNNotificationAttachment(identifier: "artwork", url: url) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return attachment
    }
}
