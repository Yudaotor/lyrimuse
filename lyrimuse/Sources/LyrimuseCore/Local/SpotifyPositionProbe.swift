import Foundation
import os

/// Spotify 原生客户端的一次性「地面真值」探针(2026-09-07)。
///
/// ## 要解决的现象
///
/// 广告结束后开播的歌,MediaRemote 那份 now-playing 信息**晚发 ~2.4s 而 elapsedTime 仍是 0**
/// (实测 妳和吉他:Spotify 自己的通知 08:12:45.876 报「位置 0」,media-control 直到 08:12:48.253
/// 才出现这首歌、锚点 0@:48)。按锚点外推,整首歌落后 2.3s;一按暂停 Spotify 才吐出真实位置
/// (冻结值 50.593 vs 屏上 48.297),用户看到"歌词落后、一暂停往前补一大段"。单看 media-control
/// 的读数认不出来:它就是一个形状完全正常的开播锚点。
///
/// ## 为什么问 AppleScript `player position`,而不是通知里的位置
///
/// 两个都是 Spotify 自己的钟(暂停冻结值也是这个钟,所以对齐它之后暂停就没有跳变)。但通知在
/// 真正出声前 ~0.5s 就发了「Playing 0」(同一实测:通知 :45.876,而按冻结值反推的开播时刻是
/// :46.39),拿它当真值会留下半秒;`player position` 回答的是"此刻"的钟,用往返中点校正后误差
/// 在 ±0.1s 内(往返实测 ~150ms)。App 本来就在每首 Spotify 歌上跑一次 AppleScript(广告复核),
/// 没有新增权限面。
///
/// ## 为什么一次性
///
/// 08-14~08-18 的「持续直查 playerPosition」路线已撤(每拍一个 osascript、抖动叠噪声,见
/// `PositionSourceTier` 注释),这里每首歌开播后只问一次,结果走 `resolvePositionSeconds` 的
/// `isGroundTruthSeed` 通道(跟浏览器探针同一条:差过 `groundTruthSnapToleranceSecs` 才重锚,
/// 否则一动不动)。gapless 自然切歌时 Spotify 的钟比真声超前 ~0.9s —— 那是
/// `naturalAdvanceCorrection` 的偏置在管;探针读数进伺服前同样扣偏置(raw 域),所以锚点没打歪
/// 的歌 |Δ|≈0,不会被它推快。
///
/// ## 顺带带回封面地址(2026-09-09)
///
/// 这次脚本本来就要 fork 一个 osascript,顺带把 `spotify url` 与 `artwork url` 一起带回来(一次脚本三个值,
/// 不多一个子进程)。`artwork url` 是 Spotify 图床 640 档的地址(形状与换档见 `SpotifyArtworkURL`),经
/// `setArtworkSink` 交给 `LocalPlaybackSource.noteSpotifyArtwork`,再由 `PlaybackCoordinator` 换成同一张图的
/// 原图档 —— Spotify 交给系统的封面只有 600×600。只有真曲目(`spotify:track:`)才交出去:广告的 `artwork url`
/// 是广告物料图,本地文件是 `missing value`。位置改用**整数毫秒**回传:AppleScript 实数转文本会跟系统小数点
/// 本地化走(逗号地区会变成 `12,345`),整数没有这个问题。
///
/// ## 边界
///
/// - 只对 Spotify 原生客户端开(bundle id 判),网页版走 `BrowserPositionProbe`。
/// - 只在**稳定播放中**消费(apply 那边加了 `posWasPlaying` 门):探测与消费之间若发生了暂停,
///   按 rate×age 外推会把暂停时长算进去,而恢复锚点本来就是准的,不需要它。
/// - 换歌 2.5s 后再问:太早 Spotify 的钟可能还没起步(缓冲),太晚用户已经盯着错的位置看了。
/// - Spotify 没在跑时脚本直接返回空串,不会把它拉起来(跟 `MusicPlaybackController` 的
///   `spotifyRunningGuard` 同款守卫)。
public final class SpotifyPositionProbe: @unchecked Sendable {
    public static let shared = SpotifyPositionProbe()
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "spotify-probe")

    /// 换歌后等多久再问。
    public static let delayAfterTrackStart: TimeInterval = 2.5
    /// osascript 往返超时。正常 ~150ms;卡住就放弃,这首歌不纠。
    public static let appleScriptTimeout: TimeInterval = 3
    /// 探测结果最多用多久:超过就当过期(中间可能发生了别的事)。
    public static let maxCorrectionAge: TimeInterval = 6

    private let lock = NSLock()
    private var scheduledKey: String?
    private var pending: (key: String, position: Double, at: Date)?
    /// 封面地址的去向(见类头注「顺带带回封面地址」)。由 LocalPlaybackSource 启动时挂上;没挂就丢掉。
    private var artworkSink: (@Sendable (_ key: String, _ url: URL) -> Void)?

    public func setArtworkSink(_ sink: @escaping @Sendable (_ key: String, _ url: URL) -> Void) {
        lock.lock()
        artworkSink = sink
        lock.unlock()
    }

    private static let script = """
    if application "Spotify" is not running then
        return ""
    end if
    tell application "Spotify"
        set posMs to (player position * 1000) as integer
        set trackURI to (spotify url of current track) as text
        set artURL to (artwork url of current track) as text
        return (posMs as text) & "|" & trackURI & "|" & artURL
    end tell
    """

    /// 换歌(或首次观察)时调。`isSpotifyNative` 为假只清状态、不探测。
    public func trackChanged(to key: String, isSpotifyNative: Bool) {
        lock.lock()
        pending = nil
        scheduledKey = isSpotifyNative ? key : nil
        lock.unlock()
        guard isSpotifyNative else { return }
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(Self.delayAfterTrackStart))
            guard let self else { return }
            self.lock.lock()
            let stillCurrent = self.scheduledKey == key
            self.lock.unlock()
            guard stillCurrent else { return }
            let t0 = Date()
            guard let r = ProcessRunner.run("/usr/bin/osascript", ["-e", Self.script], timeout: Self.appleScriptTimeout),
                  r.succeeded,
                  let parsed = Self.parseProbeOutput(r.stdoutText)
            else {
                Self.logger.notice("spotify position probe: no answer for key=\(key, privacy: .public)")
                return
            }
            let position = parsed.position
            let t1 = Date()
            let midpoint = t0.addingTimeInterval(t1.timeIntervalSince(t0) / 2)
            self.lock.lock()
            let stillScheduled = self.scheduledKey == key
            if stillScheduled { self.pending = (key, position, midpoint) }
            let sink = self.artworkSink
            self.lock.unlock()
            // 封面地址:还是这首、且是真曲目才交出去(广告物料图 / 本地文件的 missing value 都不要)。
            if stillScheduled, let art = parsed.artworkURL, let uri = parsed.uri, SpotifyArtworkURL.isTrackURI(uri) {
                sink?(key, art)
            }
            Self.logger.notice("spotify position probe: key=\(key, privacy: .public) position=\(position, format: .fixed(precision: 3)) rtt=\(t1.timeIntervalSince(t0), format: .fixed(precision: 3))")
        }
    }

    /// 取这首歌**唯一一次**的真值,外推到 now。同一首歌只交出一次;不是这首 / 过期 → nil,
    /// 调用方原样退回既有逻辑。
    public func consumeCorrection(forKey key: String, rate: Double, now: Date) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let p = pending, p.key == key else { return nil }
        pending = nil
        guard let value = Self.extrapolate(position: p.position, capturedAt: p.at, now: now, rate: rate) else { return nil }
        Self.logger.notice("spotify position probe: handing off \(value, format: .fixed(precision: 3))s for key=\(key, privacy: .public)")
        return value
    }

    /// 解析脚本输出。纯函数,selftest 直接覆盖。
    ///
    /// 新形态 `毫秒整数|spotify url|artwork url`(三段,后两段可为空 / `missing value`);位置解析不出来整条
    /// 作废(位置是这条探针的本职),后两段坏了只丢那一段。也接受旧形态的裸秒数(`12.345`),让这个函数对
    /// 老输出同样成立 —— 运行时不会再遇到,但解析规则不该依赖脚本此刻长什么样。
    public static func parseProbeOutput(_ raw: String) -> (position: Double, uri: String?, artworkURL: URL?)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let parts = s.components(separatedBy: "|")
        let first = parts[0].trimmingCharacters(in: .whitespaces)
        let position: Double
        if parts.count == 1 {
            guard let seconds = Double(first) else { return nil }
            position = seconds
        } else {
            guard let ms = Int(first) else { return nil }
            position = Double(ms) / 1000
        }
        let uriRaw = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        let art = parts.count > 2 ? SpotifyArtworkURL.parse(parts[2]) : nil
        return (position, uriRaw.isEmpty ? nil : uriRaw, art)
    }

    /// 纯函数,selftest 直接覆盖:探测值按 rate×age 外推到 now;age 越界(倒退 / 过期)返回 nil。
    public static func extrapolate(position: Double, capturedAt: Date, now: Date, rate: Double) -> Double? {
        let age = now.timeIntervalSince(capturedAt)
        guard age >= 0, age <= maxCorrectionAge else { return nil }
        return position + age * (rate > 0 ? rate : 1)
    }
}
