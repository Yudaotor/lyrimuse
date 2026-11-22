import Foundation
import os

/// Safari 里的网页播放器(YouTube Music、Spotify 网页版)缓冲卡住时,系统「正在播放」那份什么都不报:速率照报 1、不重打锚点,
/// 屏上照锚点一路外推(Chromium 系改报速率 0,另走 `MediaControlClient.webStallPosition`)。这里在 Safari 放着配对的网页平台时,
/// 隔 `interval` 读一次页面媒体的钟,跟墙钟比少走了多少:少走的累计成 `State.lag` 从外推里扣掉,这会儿卡着就停在页面的位置。
/// 系统重打锚点(恢复、暂停、跳转)就从头记:新锚点是页面自己报的,不用再扣。同一首里页面的钟和曲目位置差一个定值
/// (`State.offset`,正常走着时记下),新锚点下头一次读数就拿它比:跳到没缓冲的地方、新锚点一来就卡住,也停在页面的位置。
/// 换歌全部从头记。见 02 章决策 290。
///
/// 页面的钟:YouTube Music 读 `video.currentTime`(电台 / 续播时是整段会话的累计时间,只拿两次读数的差),`readyState < 3`
/// 算断粮;Spotify 网页版页面里没有媒体元素,读播放器状态(`BrowserPositionProbe.spotifyWebPlayerStateJS`),缓冲中按停在
/// `positionAsOfTimestamp`,`isBuffering` 算断粮。页面经一个常驻 osascript 读(`server`),不每次起子进程。
public final class SafariStallWatch: @unchecked Sendable {
    public static let shared = SafariStallWatch()

    private static let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "safari-stall")

    /// 两次读页面之间至少隔多久。轮询在放时 2 秒一拍,这个值让每拍读一次(拍子早到一点也不跳过)。
    public static let interval: TimeInterval = 1.5
    /// 两次读数之间页面比墙钟少走不到这么多不算(读数和墙钟各自的抖动)。
    public static let lagTolerance: Double = 0.3
    /// 隔了至少 `stuckMinGap` 秒、页面的钟走了不到这么多,算停住了。
    public static let stuckAdvance: Double = 0.05
    public static let stuckMinGap: TimeInterval = 1
    /// 页面的钟往回跳超过这么多、或者比墙钟多走超过这么多(页面里换了一条视频、跳转了),这一对读数不比,从下一次接着比。
    public static let clockJumpTolerance: Double = 1
    /// 停住的判断离最后一次读到页面超过这么久就不算了(读不到页面时不一直停着)。
    public static let staleAfter: TimeInterval = 8
    static let readTimeout: TimeInterval = 3
    /// 常驻 osascript 闲了这么久就关掉。
    static let serverIdleStop: TimeInterval = 60

    /// 读一次页面得到的。
    public struct Sample: Equatable, Sendable {
        /// 页面读钟那一刻(JS 的 `Date.now()`)。
        public let at: Date
        /// 页面媒体的钟(秒)。
        public let clock: Double
        public let paused: Bool
        /// 在放却没有数据可放。
        public let starved: Bool

        public init(at: Date, clock: Double, paused: Bool, starved: Bool) {
            self.at = at
            self.clock = clock
            self.paused = paused
            self.starved = starved
        }
    }

    /// 同一份锚点下累计的结果。
    public struct State: Equatable, Sendable {
        /// 页面比锚点外推少走的秒数,累计。
        public var lag: Double = 0
        public var last: Sample?
        /// 最后一次读到时页面停着。
        public var frozen = false
        /// 这一次停住从哪一次读数起(打日志用)。
        public var frozenSince: Date?
        /// 页面的钟减去曲目位置。同一首里不变,换锚点时留着(换歌时清)。
        public var offset: Double?

        public init(lag: Double = 0, last: Sample? = nil, frozen: Bool = false, frozenSince: Date? = nil, offset: Double? = nil) {
            self.lag = lag
            self.last = last
            self.frozen = frozen
            self.frozenSince = frozenSince
            self.offset = offset
        }

        /// 此刻还算不算停着:停着、而且最后一次读数不旧。
        public func isFrozen(now: Date) -> Bool {
            guard frozen, let last else { return false }
            let age = now.timeIntervalSince(last.at)
            return age >= -1 && age <= SafariStallWatch.staleAfter
        }
    }

    /// 记下一次读数。`anchorPosition` 是锚点外推到读数那一刻的位置(不扣 `lag`):跟上一次读数比得上、这会儿没停着时拿它
    /// 记 `offset`,新锚点下头一次读数拿 `offset` 定 `lag`。纯函数,selftest 覆盖。
    public static func advance(_ state: State, with sample: Sample, rate: Double?, anchorPosition: Double? = nil) -> State {
        var next = state
        next.last = sample
        guard !sample.paused else {
            next.frozen = false
            next.frozenSince = nil
            return next
        }
        var frozen = sample.starved
        var comparable = false
        if let prev = state.last, !prev.paused {
            let gap = sample.at.timeIntervalSince(prev.at)
            let r = (rate ?? 0) > 0 ? rate! : 1
            let expected = max(0, gap) * r
            let advance = sample.clock - prev.clock
            if gap > 0, advance >= -clockJumpTolerance, advance <= expected + clockJumpTolerance {
                let missing = min(expected, expected - max(0, advance))
                if missing > lagTolerance { next.lag += missing }
                if gap >= stuckMinGap && advance < stuckAdvance { frozen = true }
                comparable = true
            }
        } else if let offset = state.offset, let anchorPosition {
            let behind = anchorPosition - (sample.clock - offset)
            next.lag = behind > lagTolerance ? behind : 0
        }
        if comparable, !frozen, let anchorPosition { next.offset = sample.clock - (anchorPosition - next.lag) }
        next.frozen = frozen
        next.frozenSince = frozen ? (state.frozen ? state.frozenSince ?? sample.at : sample.at) : nil
        return next
    }

    /// 锚点外推出来的位置(`live`,外推到 `now`)换成照页面的钟该显示的:停着就停在最后一次读数那一刻,否则扣掉少走的。纯函数。
    public static func position(live: Double, now: Date, rate: Double?, state: State) -> Double {
        guard state.isFrozen(now: now), let last = state.last else { return max(0, live - state.lag) }
        let r = (rate ?? 0) > 0 ? rate! : 1
        return max(0, live - max(0, now.timeIntervalSince(last.at)) * r - state.lag)
    }

    /// 读页面的回答 `CLOCK:<钟>|<暂停 1/0>|<断粮 1/0>|<Date.now() 毫秒>`,读不懂为 nil。纯函数。
    public static func parseSample(_ raw: String) -> Sample? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("CLOCK:") else { return nil }
        let parts = s.dropFirst(6).split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4, let clock = Double(parts[0]), clock.isFinite,
              let ms = Double(parts[3]), ms > 0 else { return nil }
        return Sample(at: Date(timeIntervalSince1970: ms / 1000), clock: clock, paused: parts[1] == "1", starved: parts[2] == "1")
    }

    // MARK: - 页面脚本

    /// YouTube Music:页面上的 `video`。
    public static let youtubeMusicClockJS = "(function(){var v=document.querySelector('video');if(!v)return 'NOTFOUND';"
        + "return 'CLOCK:'+v.currentTime.toFixed(3)+'|'+(v.paused?1:0)+'|'+(v.readyState<3?1:0)+'|'+Date.now();})()"

    /// Spotify 网页版:播放器状态。在放、不缓冲、速率不为 0 才按 `timestamp` 外推到此刻。
    public static let spotifyWebClockJS = "(function(){var raw=" + BrowserPositionProbe.spotifyWebPlayerStateJS + ";"
        + "if(raw==='NOTFOUND')return 'NOTFOUND';var f=String(raw).split(String.fromCharCode(31));"
        + "if(f.length!==7||f[0]===''||f[1]==='')return 'NOTFOUND';"
        + "var p=Number(f[0]),ts=Number(f[1]),sp=f[2]===''?1:Number(f[2]),paused=f[4]==='1',buf=f[5]==='1',now=Date.now();"
        + "var pos=(paused||buf||!(sp>0))?p:p+(now-ts)*sp;"
        + "return 'CLOCK:'+(pos/1000).toFixed(3)+'|'+(paused?1:0)+'|'+(buf?1:0)+'|'+now;})()"

    /// 各平台的页面脚本和网址特征。
    static let pages: [(platformID: String, host: String, js: String)] = [
        ("youtubeMusic", "music.youtube.com", youtubeMusicClockJS),
        ("spotifyWeb", "open.spotify.com", spotifyWebClockJS),
    ]

    private static func jsLiteral(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s), let text = String(data: data, encoding: .utf8) else { return "''" }
        return text
    }

    /// 常驻 osascript 的脚本:每行请求是逗号分隔的平台 id,按 Safari 各窗口各标签页的网址找这些平台的页面读钟,先交在放的那一页,
    /// 都没在放交第一个读到的,一页都没有回 `NOTFOUND`,Safari 没开回 `NOTRUNNING`(不会把它拉起来)。
    public static let serverScript: String = {
        let table = pages.map { "\(jsLiteral($0.platformID)): { host: \(jsLiteral($0.host)), js: \(jsLiteral($0.js)) }" }
            .joined(separator: ", ")
        return """
        ObjC.import('Foundation');
        ObjC.import('AppKit');
        const pages = { \(table) };
        function read(line) {
            const ids = line.split(',').filter(function(id) { return pages[id]; });
            const running = $.NSRunningApplication.runningApplicationsWithBundleIdentifier('com.apple.Safari');
            if (Number(running.count) === 0) return 'NOTRUNNING';
            const safari = Application(Number(running.objectAtIndex(0).processIdentifier));
            const urls = safari.windows.tabs.url();
            let fallback = 'NOTFOUND';
            for (let wi = 0; wi < urls.length; wi++) {
                const tabs = urls[wi] || [];
                for (let ti = 0; ti < tabs.length; ti++) {
                    const url = String(tabs[ti] || '');
                    for (const id of ids) {
                        if (url.indexOf(pages[id].host) < 0) continue;
                        let r = '';
                        try { r = String(safari.doJavaScript(pages[id].js, { in: safari.windows[wi].tabs[ti] })); } catch (e) { continue; }
                        if (r.indexOf('CLOCK:') !== 0) continue;
                        if (r.split('|')[1] === '0') return r;
                        if (fallback === 'NOTFOUND') fallback = r;
                    }
                }
            }
            return fallback;
        }
        const input = $.NSFileHandle.fileHandleWithStandardInput;
        const output = $.NSFileHandle.fileHandleWithStandardOutput;
        let pending = '';
        for (;;) {
            const data = input.availableData;
            if (Number(data.length) === 0) break;
            pending += $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding).js;
            let newline;
            while ((newline = pending.indexOf('\\n')) >= 0) {
                const line = pending.slice(0, newline).trim();
                pending = pending.slice(newline + 1);
                let text = '';
                let status = 0;
                try { text = read(line); } catch (e) { status = 1; }
                output.writeData($(text + '\\n\(MediaControlClient.scriptServerEndMarker) ' + status + '\\n').dataUsingEncoding($.NSUTF8StringEncoding));
            }
        }
        """
    }()

    private let server = PersistentScriptServer(
        label: "osascript safari page clock", endMarker: MediaControlClient.scriptServerEndMarker,
        recycleAfterRequests: 200,
        launch: { .init(executable: "/usr/bin/osascript", arguments: ["-l", "JavaScript", "-e", SafariStallWatch.serverScript]) })

    // MARK: - 状态

    private let lock = NSLock()
    private var epoch: String?
    private var track: String?
    /// 这一份锚点外推出来的位置和外推到的时刻(`observe` 那一拍的),读数回来时拿它推到读数那一刻。
    private var anchorRef: (position: Double, at: Date)?
    private var state = State()
    private var inFlight = false
    private var lastRead: Date?
    private var changeHandler: (@Sendable (_ frozen: Bool) -> Void)?

    /// 页面停住 / 又走了时调一次(在后台线程上),让轮询当场补查,不等下一拍。
    public func setChangeHandler(_ handler: @escaping @Sendable (_ frozen: Bool) -> Void) {
        lock.lock()
        changeHandler = handler
        lock.unlock()
    }

    private init() {}

    /// 这一份快照要不要按页面的钟看:报的是 Safari(媒体进程换成宿主后),配对了有页面脚本的平台,在放。要看就交回同一份锚点下
    /// 累计到此刻的结果(还没读到过为空的 `State`),顺带到点了就在后台再读一次页面;不看为 nil,并清掉记着的。
    /// `anchorKey` 变了(系统重打锚点)从头记、`offset` 留着,`trackKey` 也变了全清。`live` 是锚点外推到 `now` 的位置。
    /// 在轮询线程上调,不阻塞。
    public func observe(reportedBundleID: String?, trackKey: String, anchorKey: String, playing: Bool, rate: Double?,
                        live: Double?, now: Date) -> State? {
        guard playing, let host = BrowserPositionProbe.probeTargetBundleID(forReported: reportedBundleID),
              BrowserAutomationPermission.family(forBundleID: host) == .safari else {
            reset(now: now)
            return nil
        }
        let platformIDs = Self.pages.map(\.platformID).filter {
            BrowserPositionProbe.shared.isPaired(bundleID: reportedBundleID, platformID: $0)
        }
        guard !platformIDs.isEmpty else {
            reset(now: now)
            return nil
        }
        lock.lock()
        if epoch != anchorKey {
            epoch = anchorKey
            state = State(offset: track == trackKey ? state.offset : nil)
            track = trackKey
        }
        anchorRef = live.map { ($0, now) }
        let current = state
        let due = !inFlight && lastRead.map { now.timeIntervalSince($0) >= Self.interval || now < $0 } ?? true
        if due {
            inFlight = true
            lastRead = now
        }
        lock.unlock()
        if due {
            let request = platformIDs.joined(separator: ",")
            DispatchQueue.global(qos: .utility).async { [self] in read(request: request, epoch: anchorKey, rate: rate) }
        }
        return current
    }

    /// 不看了就清掉;常驻 osascript 闲了 `serverIdleStop` 就关掉。
    private func reset(now: Date) {
        lock.lock()
        epoch = nil
        track = nil
        anchorRef = nil
        state = State()
        let idle = !inFlight && lastRead.map { now.timeIntervalSince($0) >= Self.serverIdleStop } ?? false
        if idle { lastRead = nil }
        lock.unlock()
        if idle { server.stop() }
    }

    private func read(request: String, epoch readEpoch: String, rate: Double?) {
        let result = server.request(request, timeout: Self.readTimeout)
        let sample = result.flatMap { $0.succeeded ? Self.parseSample($0.stdoutText) : nil }
        lock.lock()
        inFlight = false
        guard epoch == readEpoch, let sample else {
            lock.unlock()
            return
        }
        let r = (rate ?? 0) > 0 ? rate! : 1
        let anchorPosition = anchorRef.map { $0.position + sample.at.timeIntervalSince($0.at) * r }
        let before = state
        state = Self.advance(state, with: sample, rate: rate, anchorPosition: anchorPosition)
        let after = state
        let handler = changeHandler
        lock.unlock()
        if after.frozen != before.frozen {
            handler?(after.frozen)
            Self.logger.notice("safari page clock \(after.frozen ? "stopped" : "running again", privacy: .public): clock=\(sample.clock, format: .fixed(precision: 3)) starved=\(sample.starved, privacy: .public) lag=\(after.lag, format: .fixed(precision: 3))")
        }
    }
}
