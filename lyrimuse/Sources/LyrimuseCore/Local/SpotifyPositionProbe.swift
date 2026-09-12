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

    /// 换歌后等多久再问。09-07 定 2.5s(太早 Spotify 的钟可能还没起步 / gapless 时先超前后停顿),
    /// 2026-09-09 收到 2.0s:现在两次采样验钟在走、不过关还会重试一次(retryAfterFailedLiveness),
    /// 早半秒的风险由它们兜;整条链(观察到换歌 → 探针 → 结果回调立刻 poll)约 3s,用户报过
    /// 「开头那几秒歌词慢」,链越短越好,但 2.0 以下那段"钟先超前 0.9s 再停"的窗口还没过完。
    public static let delayAfterTrackStart: TimeInterval = 2.0
    /// 开播那次两采样没过活性(钟还没起步 / 正在停顿)时,隔多久再试一次(只试一次)。
    public static let retryAfterFailedLiveness: TimeInterval = 1.5
    /// osascript 往返超时。正常 ~150ms;卡住就放弃,这首歌不纠。
    public static let appleScriptTimeout: TimeInterval = 3
    /// 探测结果最多用多久:超过就当过期(中间可能发生了别的事)。
    public static let maxCorrectionAge: TimeInterval = 6
    /// 两次采样之间隔多久(2026-09-09,见 `clockIsRunning`)。比浏览器探针的 1.5s 短:这里两次往返
    /// 都是 ~150ms 的本地 AppleScript,0.6s 已足够把"钟没在走"跟"走得正常"分开(阈值见下)。
    public static let livenessGapSeconds: TimeInterval = 0.5

    /// Spotify 的钟在两次采样之间**走得正常**才采信这一对读数。纯函数,selftest 直接覆盖。
    ///
    /// 2026-09-09 起探针量出的差会**折进整曲偏置**(见 LocalPlaybackSource.resolvePositionSeconds
    /// 的地面真值分支),不再是"重锚一次、伺服几拍就纠回去"的一次性动作 —— 一次读错就是整首歌
    /// 错到底(暂停 / 拖动才复位)。头注里"换歌 2.5s 后再问,太早钟可能还没起步(缓冲)"那种停着的
    /// 钟会读出 ~0 而 MediaRemote 已外推到 ~3,折进去就是整曲慢 3 秒 —— 正是这道守卫要挡的。
    /// 判据:第二次减第一次的前进量落在两次采样墙钟间隔的 [0.5, 1.5] 倍之内(rate 按 1 算;
    /// 往返抖动 ~±0.1s,0.6s 间隔下比例区间给得宽);停着(0)、倒退(拖动)、跳跃(换歌)都不采。
    public static func clockIsRunning(first: Double, second: Double, wallGap: TimeInterval) -> Bool {
        guard wallGap > 0 else { return false }
        let advance = second - first
        return advance >= 0.5 * wallGap && advance <= 1.5 * wallGap
    }

    private let lock = NSLock()
    private var scheduledKey: String?
    private var pending: (key: String, position: Double, at: Date)?
    /// 封面地址的去向(见类头注「顺带带回封面地址」)。由 LocalPlaybackSource 启动时挂上;没挂就丢掉。
    private var artworkSink: (@Sendable (_ key: String, _ url: URL) -> Void)?
    /// 探针结果落地(pending 已设)时的回调 —— LocalPlaybackSource 挂上"立刻 poll 一次",不等下一拍
    /// 2s 轮询来消费(2026-09-09 真机量到从锚点到纠偏 ≈5.3s,其中 ~1s 是干等轮询)。
    private var resultSink: (@Sendable (_ key: String) -> Void)?

    public func setResultSink(_ sink: @escaping @Sendable (_ key: String) -> Void) {
        lock.lock()
        resultSink = sink
        lock.unlock()
    }

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
        confirmationInFlight = false
        lock.unlock()
        guard isSpotifyNative else { return }
        runProbe(key: key, delay: Self.delayAfterTrackStart, isConfirmation: false, retriesLeft: 1)
    }

    /// 同一首歌播放中 MediaRemote 锚点**变了**(seek 分支重锚、或偏置随重发的锚点作废)时调:再问一次
    /// Spotify 的钟,确认新锚点是不是真的(2026-09-09)。真机两例:播到 60s / 110s 时 Spotify 把开播那份
    /// now-playing 带着新时间戳晚发(elapsed 0.367 / 2.458),单看 MediaRemote 跟"用户拖回开头"一模一样,
    /// seek 分支照单全收,歌词回到开头、暂停时差 60s。真拖动的话探针与新锚点一致(Δ<0.3s),什么都不改;
    /// 假的就按探针重锚并把差折进偏置,这个假锚点之后每一笔读数都被加回去。
    /// 同一首歌只允许一次在飞;换歌自动作废。delay 比开播那次短:拖动后 Spotify 的钟立刻就是新位置。
    public func requestConfirmation(forKey key: String) {
        lock.lock()
        let allowed = scheduledKey == key && !confirmationInFlight
        if allowed { confirmationInFlight = true }
        lock.unlock()
        guard allowed else { return }
        runProbe(key: key, delay: Self.delayAfterAnchorChange, isConfirmation: true, retriesLeft: 0)
    }

    /// 锚点变化后等多久再问(拖动后 Spotify 的钟立刻就位,只需躲开 seek 那一拍的抖动)。
    public static let delayAfterAnchorChange: TimeInterval = 0.4
    private var confirmationInFlight = false

    /// 开播那次(isConfirmation=false)顺带交封面地址;锚点变化的确认(true)只管位置,结束时放开在飞标记。
    private func runProbe(key: String, delay: TimeInterval, isConfirmation: Bool, retriesLeft: Int) {
        let reason = isConfirmation ? "anchor change" : "track start"
        let deliverArtwork = !isConfirmation
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            defer {
                if isConfirmation {
                    self.lock.lock()
                    self.confirmationInFlight = false
                    self.lock.unlock()
                }
            }
            self.lock.lock()
            let stillCurrent = self.scheduledKey == key
            self.lock.unlock()
            guard stillCurrent else { return }
            // 两次采样(2026-09-09):第一次只用来证明钟在走,第二次才是交出去的读数(更新,
            // capturedAt 也对得上 consumeCorrection 的 rate×age 补偿)。两次是两次独立的 osascript,
            // 中间 Task.sleep 不占线程。
            guard let first = Self.sample() else {
                Self.logger.notice("spotify position probe (\(reason, privacy: .public)): no answer for key=\(key, privacy: .public)")
                return
            }
            try? await Task.sleep(for: .seconds(Self.livenessGapSeconds))
            guard let second = Self.sample() else {
                Self.logger.notice("spotify position probe (\(reason, privacy: .public)): second sample returned nothing, discarding \(first.position, format: .fixed(precision: 3))s for key=\(key, privacy: .public)")
                return
            }
            let wallGap = second.midpoint.timeIntervalSince(first.midpoint)
            guard Self.clockIsRunning(first: first.position, second: second.position, wallGap: wallGap) else {
                Self.logger.notice("spotify position probe (\(reason, privacy: .public)): clock not advancing normally (\(first.position, format: .fixed(precision: 3)) -> \(second.position, format: .fixed(precision: 3)) over \(wallGap, format: .fixed(precision: 3))s), \(retriesLeft > 0 ? "retrying once" : "discarding", privacy: .public) for key=\(key, privacy: .public)")
                if retriesLeft > 0 {
                    self.runProbe(key: key, delay: Self.retryAfterFailedLiveness, isConfirmation: isConfirmation, retriesLeft: retriesLeft - 1)
                }
                return
            }
            let parsed = second.parsed
            let position = second.position
            self.lock.lock()
            let stillScheduled = self.scheduledKey == key
            if stillScheduled { self.pending = (key, position, second.midpoint) }
            let sink = self.artworkSink
            let resultSink = self.resultSink
            self.lock.unlock()
            if stillScheduled { resultSink?(key) }
            // 封面地址:开播那次才交(还是这首、且是真曲目;广告物料图 / 本地文件的 missing value 都不要)。
            if deliverArtwork, stillScheduled, let art = parsed.artworkURL, let uri = parsed.uri, SpotifyArtworkURL.isTrackURI(uri) {
                sink?(key, art)
            }
            Self.logger.notice("spotify position probe (\(reason, privacy: .public)): key=\(key, privacy: .public) position=\(position, format: .fixed(precision: 3)) (first \(first.position, format: .fixed(precision: 3)) over \(wallGap, format: .fixed(precision: 3))s) rtt=\(second.rtt, format: .fixed(precision: 3))")
        }
    }

    private struct Sample {
        let parsed: (position: Double, uri: String?, artworkURL: URL?)
        let midpoint: Date
        let rtt: TimeInterval
        var position: Double { parsed.position }
    }

    /// 跑一次脚本;拿不到答案返回 nil。midpoint = 往返中点,当读数的时刻。
    private static func sample() -> Sample? {
        let t0 = Date()
        guard let r = ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: appleScriptTimeout),
              r.succeeded,
              let parsed = parseProbeOutput(r.stdoutText)
        else { return nil }
        let t1 = Date()
        return Sample(parsed: parsed, midpoint: t0.addingTimeInterval(t1.timeIntervalSince(t0) / 2), rtt: t1.timeIntervalSince(t0))
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
