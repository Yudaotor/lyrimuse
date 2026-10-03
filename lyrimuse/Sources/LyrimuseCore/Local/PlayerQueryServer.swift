import Foundation
import os

/// collector 预解析要的那几样播放器查询,由 App 代跑。collector 自己不发 AppleEvent,系统设置「自动化」里只剩
/// Lyrimuse 一条,授权框也只可能来自 App。
///
/// collector 写一份带类型的请求(`lyrimuse-player-query-request.json`:种类 + 参数,不带脚本),这里只跑自己内置的
/// 四段只读脚本和系统待播队列那次查询(`NowPlayingClientsProbe.queue`),把原始输出写回
/// `lyrimuse-player-query-reply.json`。输出怎么解析留在 collector(`appquery.go` 与各家的
/// parse 函数);契约两边各钉一份:selftest「player-query」组、Go `appquery_test.go`(读这个文件对账)。
///
/// 只认这五种查询,参数逐项校验;网页队列那种只对用户把这个平台配对给了的浏览器跑。请求写出超过 `requestMaxAge`
/// 才看到就不答(collector 那边早不等了)。一次只处理一份请求,collector 那边也一次只发一份。
/// 只在以 Lyrimuse.app 身份运行时启动:selftest 与 `swift run` 共用配置目录,同 `PlaybackStatePublisher`。
///
/// 状态(定时器、上次读到的请求)只在 `queue` 上读写。
public final class PlayerQueryServer: @unchecked Sendable {
    public static let shared = PlayerQueryServer()

    public static let requestFileName = "lyrimuse-player-query-request.json"
    public static let replyFileName = "lyrimuse-player-query-reply.json"
    public static var requestURL: URL { LyrimusePaths.configFile(requestFileName) }
    public static var replyURL: URL { LyrimusePaths.configFile(replyFileName) }

    public static let schema = 1
    /// 多久看一次请求文件(一次 stat,变了才读)。
    public static let pollInterval: TimeInterval = 0.5
    /// 请求写出之后超过这么久才看到就不答。collector 那边最多等 8 秒(`appQueryScriptTimeout`)。
    public static let requestMaxAge: TimeInterval = 10
    /// 跑 Music / 浏览器脚本、读系统待播队列的进程级超时。collector 那边的等待按它留了余量,两边一起改。
    public static let scriptTimeout: TimeInterval = 6
    /// 问 Spotify 随机状态的进程级超时(collector 那边等 4 秒)。
    public static let shuffleTimeout: TimeInterval = 2
    /// 浏览器脚本里单条 AppleEvent 的 `with timeout` 秒数。
    public static let browserEventTimeoutSeconds = 4
    public static let maxUpcomingCount = 20
    public static let maxAlbumLength = 512

    public enum Kind: String, Sendable, CaseIterable {
        case appleMusicQueue = "apple_music_queue"
        case appleMusicUpcoming = "apple_music_upcoming"
        case appleMusicAlbumTracks = "apple_music_album_tracks"
        case spotifyShuffle = "spotify_shuffle"
        case browserQueue = "browser_queue"
    }

    public struct Request: Codable, Equatable, Sendable {
        public var schema: Int
        public var id: String
        public var kind: String
        public var count: Int?
        public var album: String?
        public var bundleID: String?
        public var platform: String?
        public var writtenAtMs: Int64

        enum CodingKeys: String, CodingKey {
            case schema, id, kind, count, album, platform
            case bundleID = "bundle_id"
            case writtenAtMs = "written_at_ms"
        }

        public init(schema: Int = PlayerQueryServer.schema, id: String, kind: String, count: Int? = nil,
                    album: String? = nil, bundleID: String? = nil, platform: String? = nil, writtenAtMs: Int64) {
            self.schema = schema
            self.id = id
            self.kind = kind
            self.count = count
            self.album = album
            self.bundleID = bundleID
            self.platform = platform
            self.writtenAtMs = writtenAtMs
        }
    }

    public struct Reply: Codable, Equatable, Sendable {
        public var schema: Int
        public var id: String
        public var ok: Bool
        public var output: String
        public var error: String?
        public var writtenAtMs: Int64

        enum CodingKeys: String, CodingKey {
            case schema, id, ok, output, error
            case writtenAtMs = "written_at_ms"
        }

        public init(schema: Int = PlayerQueryServer.schema, id: String, ok: Bool, output: String, error: String?,
                    writtenAtMs: Int64) {
            self.schema = schema
            self.id = id
            self.ok = ok
            self.output = output
            self.error = error
            self.writtenAtMs = writtenAtMs
        }
    }

    /// 校验过的一次查询。
    public enum Query: Equatable, Sendable {
        /// Music.app 在系统媒体接口上发布的待播队列(真实播放顺序,开着随机也对)。
        case appleMusicQueue(count: Int)
        case appleMusicUpcoming(count: Int)
        case appleMusicAlbumTracks(album: String)
        case spotifyShuffle
        case browserQueue(bundleID: String, platformID: String)
    }

    public enum Decision: Equatable, Sendable {
        /// 跑这次查询。
        case run(Query)
        /// 答一份 ok=false(种类或参数不对)。
        case fail(String)
        /// 不答:契约版本不认识、没有 id、已经过期。
        case ignore
    }

    /// 判这份请求答不答、跑什么。纯函数,selftest 直接覆盖。
    public static func decide(_ request: Request, now: Date) -> Decision {
        guard request.schema == schema, !request.id.isEmpty else { return .ignore }
        let age = now.timeIntervalSince1970 - Double(request.writtenAtMs) / 1000
        guard abs(age) <= requestMaxAge else { return .ignore }
        guard let kind = Kind(rawValue: request.kind) else { return .fail("unsupported kind") }
        switch kind {
        case .appleMusicQueue:
            guard let count = request.count, (1...maxUpcomingCount).contains(count) else { return .fail("invalid count") }
            return .run(.appleMusicQueue(count: count))
        case .appleMusicUpcoming:
            guard let count = request.count, (1...maxUpcomingCount).contains(count) else { return .fail("invalid count") }
            return .run(.appleMusicUpcoming(count: count))
        case .appleMusicAlbumTracks:
            guard let album = request.album, !album.isEmpty, album.count <= maxAlbumLength,
                  !album.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
            else { return .fail("invalid album") }
            return .run(.appleMusicAlbumTracks(album: album))
        case .spotifyShuffle:
            return .run(.spotifyShuffle)
        case .browserQueue:
            guard let bundleID = request.bundleID, isPlausibleBundleID(bundleID) else { return .fail("invalid bundle id") }
            guard let platform = request.platform, browserQueueSite(platformID: platform) != nil else {
                return .fail("unsupported platform")
            }
            return .run(.browserQueue(bundleID: bundleID, platformID: platform))
        }
    }

    /// bundle id 只收字母、数字和 `.` `-` `_`,不长于 255。
    static func isPlausibleBundleID(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty, bundleID.count <= 255 else { return false }
        return bundleID.unicodeScalars.allSatisfy { s in
            s.isASCII && (CharacterSet.alphanumerics.contains(s) || s == "." || s == "-" || s == "_")
        }
    }

    /// 网页队列认的平台(与 features.json 的 `browser_platform_pairs` 同名):标签页域名与那段 JS。
    public static func browserQueueSite(platformID: String) -> (hostMarker: String, js: String)? {
        switch platformID {
        case "youtubeMusic": return (YouTubeMusicAdProbe.hostMarker, youTubeMusicQueueJS)
        case "spotifyWeb": return (SpotifyWebAdProbe.hostMarker, spotifyWebQueueJS)
        default: return nil
        }
    }

    /// 把一段文字安全地嵌进 AppleScript 双引号字符串字面量:先转义反斜杠,再转义双引号。纯函数,selftest 覆盖。
    public static func appleScriptQuoted(_ text: String) -> String {
        let backslash = String(UnicodeScalar(UInt8(92)))
        let quote = String(UnicodeScalar(UInt8(34)))
        let escaped = text.replacingOccurrences(of: backslash, with: backslash + backslash)
            .replacingOccurrences(of: quote, with: backslash + quote)
        return quote + escaped + quote
    }

    /// Music.app 资料库里这张专辑的曲目,每行 名、歌手、时长(秒),用 tab 分隔。
    ///
    /// - 先判 running 再 tell:`tell application "Music"` 只要发出任何命令就会**启动** Music.app,一个只用
    ///   Spotify / QQ 音乐的人会被每换一张专辑就静默拉起一次。
    /// - `media kind is song` 白名单:专辑里混的非歌曲轨道(演唱会 / 豪华版里的 music video 花絮、纪录片)挡在这一层,
    ///   它们没有歌词可言,拿去问全部歌词源注定落空,还占满补查的重试配额。用白名单不用黑名单:防的是漏收一种
    ///   没想到的非歌曲媒体类型。
    /// - `tab` / `linefeed` 是 AppleScript 的内置常量,脚本里不塞转义序列。
    public static func appleMusicAlbumTracksScript(album: String) -> String {
        """
        if application "Music" is not running then
            return ""
        end if
        tell application "Music"
            set output to ""
            repeat with t in (every track of library playlist 1 whose album is \(appleScriptQuoted(album)) and media kind is song)
                set output to output & (name of t) & tab & (artist of t) & tab & (duration of t) & linefeed
            end repeat
            return output
        end tell
        """
    }

    /// Music.app 当前列表里当前曲目往后 `count` 首。第一行是它认为正在播的那首(名、歌手),其余每行 名、歌手、专辑、
    /// 时长(秒),用 tab 分隔。这不是真正的播放队列(脚本字典里没有 Up Next),collector 先问 `apple_music_queue`
    /// (系统待播队列),读不到才问这一段。
    ///
    /// 三道守卫,少一道都会出事:
    /// - `is not running`:同 `appleMusicAlbumTracksScript`,不能把没开的 Music.app 拉起来。
    /// - `player state is stopped`:停着时 current track 还留着上一次的值,照着它预取等于拿一批过期的歌去占解析带宽。
    /// - `shuffle enabled`:开着随机时 Music.app **不暴露乱序后的顺序**,index+1 指的是资料库里的下一首、不是接下来
    ///   会播的那首。直接放弃,collector 退回同专辑预取。
    ///
    /// 守不住、只能靠 `try` 兜的一种:播 **Apple Music 目录**的内容(云端歌单 / 电台 / 推荐)时 `current playlist`
    /// 直接报 -1728,那个歌单也不在 `playlists` 列表里 —— 脚本接口看不见云端内容。
    public static func appleMusicUpcomingScript(count: Int) -> String {
        """
        if application "Music" is not running then
            return ""
        end if
        tell application "Music"
            if player state is stopped then return ""
            if shuffle enabled then return ""
            try
                set pl to current playlist
                set t to current track
                set i to index of t
            on error
                return ""
            end try
            set output to (name of t) & tab & (artist of t) & linefeed
            repeat with k from (i + 1) to (i + \(count))
                try
                    set tk to track k of pl
                    set output to output & (name of tk) & tab & (artist of tk) & tab & (album of tk) & tab & (duration of tk) & linefeed
                end try
            end repeat
            return output
        end tell
        """
    }

    /// Spotify 有没有开随机:输出 `true` / `false`;没在跑时输出空,不拉起它。
    public static let spotifyShuffleScript = #"if application "Spotify" is running then tell application "Spotify" to return shuffling"#

    /// YouTube Music 页面的待播队列:读 `ytmusic-player-queue-item` 的 `data`(InnerTube playlistPanelVideoRenderer)。
    /// 每首一条记录,记录之间 RS(0x1e)、字段之间 US(0x1f),字段顺序 selected(0/1)、title、artist、album、lengthText、
    /// videoId、musicVideoType;找不到队列返回 NOTFOUND。解析在 collector(`parseYTMusicQueue`),字段顺序两边一起改。
    /// 不许有双引号和反斜杠(整段要嵌进 AppleScript 的双引号字符串),分隔符因此用 `String.fromCharCode` 现造。
    public static let youTubeMusicQueueJS = [
        "(function(){",
        "var US = String.fromCharCode(31), RS = String.fromCharCode(30);",
        "var items = document.querySelectorAll('ytmusic-player-queue-item');",
        "if (!items.length) return 'NOTFOUND';",
        "var text = function(o){ return (o && o.runs) ? o.runs.map(function(r){ return String(r.text || ''); }).join('') : ''; };",
        "var out = [];",
        "for (var i = 0; i < items.length; i++) {",
        "var el = items[i];",
        "if (el.closest('#counterpart-renderer')) continue;",
        "var d = el.data;",
        "if (!d) continue;",
        "var runs = (d.longBylineText && d.longBylineText.runs) || [];",
        "var artist = [], album = '', afterSep = false;",
        "for (var j = 0; j < runs.length; j++) {",
        "var t = String(runs[j].text || '');",
        "var be = runs[j].navigationEndpoint && runs[j].navigationEndpoint.browseEndpoint;",
        "var id = be ? String(be.browseId || '') : '';",
        "if (id.indexOf('MPREb') === 0) { album = t; }",
        "if (t.trim() === '•') { afterSep = true; continue; }",
        "if (!afterSep) artist.push(t);",
        "}",
        "var sel = (d.selected || el.hasAttribute('selected')) ? '1' : '0';",
        "var we = d.navigationEndpoint && d.navigationEndpoint.watchEndpoint;",
        "var mc = we && we.watchEndpointMusicSupportedConfigs && we.watchEndpointMusicSupportedConfigs.watchEndpointMusicConfig;",
        "var vt = (mc && mc.musicVideoType) ? String(mc.musicVideoType) : '';",
        "out.push([sel, text(d.title), artist.join(''), album, text(d.lengthText), String(d.videoId || ''), vt].join(US));",
        "}",
        "return out.length ? out.join(RS) : 'NOTFOUND';",
        "})()",
    ].joined()

    /// Spotify 网页版的待播队列:网页播放器组件树上 `playerAPI` 的 `getState()` / `getQueue()`。第一条记录是当前这首,
    /// 之后按播放顺序;记录之间 RS(0x1e)、字段之间 US(0x1f),字段顺序 title、artist、album、毫秒、uri,只收曲目;
    /// 找不到播放器接口返回 NOTFOUND。解析在 collector(`parseSpotifyWebQueue`),字段顺序两边一起改。纪律同上。
    public static let spotifyWebQueueJS = [
        "(function(){",
        "var US = String.fromCharCode(31), RS = String.fromCharCode(30);",
        "var el = document.querySelector('[data-testid=now-playing-widget]');",
        "if (!el) return 'NOTFOUND';",
        "var fk = Object.keys(el).filter(function(k){ return k.indexOf('__reactFiber') === 0; })[0];",
        "var f = fk ? el[fk] : null, api = null;",
        "while (f) { var p = f.memoizedProps; if (p && p.playerAPI && (typeof p.playerAPI.getQueue === 'function' || typeof p.playerAPI.getState === 'function')) { api = p.playerAPI; break; } f = f.return; }",
        "if (!api) return 'NOTFOUND';",
        "var s = typeof api.getState === 'function' ? api.getState() : null;",
        "var live = s && s.item && String(s.item.uri || '').indexOf('spotify:track:') === 0 ? s.item : null;",
        "var q = typeof api.getQueue === 'function' ? api.getQueue() : null;",
        "var cur = null, rest = [];",
        "if (q && q.current && (!live || String(q.current.uri || '') === String(live.uri))) { cur = q.current; rest = (q.queued || []).concat(q.nextUp || []); }",
        "else if (live) { cur = live; rest = s.nextItems || []; }",
        "if (!cur) return 'NOTFOUND';",
        "var rec = function(t){ var arts = (t.artists || []).map(function(a){ return String(a.name || ''); }).join(', ');",
        "return [String(t.name || ''), arts, String((t.album && t.album.name) || ''), String((t.duration && t.duration.milliseconds) || 0), String(t.uri || '')].join(US); };",
        "var out = [rec(cur)];",
        "rest.forEach(function(t){ if (t && String(t.uri || '').indexOf('spotify:track:') === 0) out.push(rec(t)); });",
        "return out.join(RS);",
        "})()",
    ].joined()

    private let queue = DispatchQueue(label: "me.yudaotor.lyrimuse.player-query", qos: .utility)
    private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "player-query")
    private let writesEnabled = Bundle.main.bundleIdentifier == LyrimuseIdentity.bundleIdentifier
    private var timer: DispatchSourceTimer?
    private var lastSignature: (modified: Date, size: Int)?
    private var lastHandledID: String?

    private init() {}

    /// 开始看请求文件。重复调用无副作用。
    public func start() {
        guard writesEnabled else { return }
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .milliseconds(100))
            source.setEventHandler { [weak self] in self?.tick() }
            source.resume()
            timer = source
        }
    }

    private func tick() {
        let url = Self.requestURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.intValue
        else { return }
        if let last = lastSignature, last.modified == modified, last.size == size { return }
        lastSignature = (modified, size)
        guard let data = try? Data(contentsOf: url),
              let request = try? JSONDecoder().decode(Request.self, from: data),
              request.id != lastHandledID
        else { return }
        let decision = Self.decide(request, now: Date())
        let started = Date()
        let reply: Reply
        switch decision {
        case .ignore:
            return
        case .fail(let reason):
            reply = makeReply(id: request.id, output: nil, error: reason)
        case .run(let query):
            reply = run(query, id: request.id)
        }
        lastHandledID = request.id
        write(reply)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        logger.info("player query \(request.kind, privacy: .public): ok=\(reply.ok, privacy: .public) bytes=\(reply.output.utf8.count, privacy: .public) \(reply.error ?? "", privacy: .public) in \(ms, privacy: .public)ms")
    }

    private func run(_ query: Query, id: String) -> Reply {
        switch query {
        case .appleMusicQueue(let count):
            return makeReply(id: id, output: NowPlayingClientsProbe.queue(forBundleID: PlaybackPlayer.appleMusic.bundleIdentifier,
                                                                          count: count, timeout: Self.scriptTimeout),
                             error: "queue unavailable")
        case .appleMusicUpcoming(let count):
            return makeReply(id: id, output: Self.osascript(Self.appleMusicUpcomingScript(count: count), timeout: Self.scriptTimeout),
                             error: "script failed")
        case .appleMusicAlbumTracks(let album):
            return makeReply(id: id, output: Self.osascript(Self.appleMusicAlbumTracksScript(album: album), timeout: Self.scriptTimeout),
                             error: "script failed")
        case .spotifyShuffle:
            return makeReply(id: id, output: Self.osascript(Self.spotifyShuffleScript, timeout: Self.shuffleTimeout),
                             error: "script failed")
        case .browserQueue(let bundleID, let platformID):
            guard BrowserPositionProbe.shared.isPaired(bundleID: bundleID, platformID: platformID) else {
                return makeReply(id: id, output: nil, error: "browser not paired")
            }
            guard let family = Self.browserFamily(forBundleID: bundleID) else {
                return makeReply(id: id, output: nil, error: "browser not scriptable")
            }
            guard let site = Self.browserQueueSite(platformID: platformID) else {
                return makeReply(id: id, output: nil, error: "unsupported platform")
            }
            let output = BrowserTabProbeScript.run(
                bundleID: bundleID, family: family, hostMarker: site.hostMarker, js: site.js,
                eventTimeoutSeconds: Self.browserEventTimeoutSeconds, processTimeout: Self.scriptTimeout, label: "player-query")
            return makeReply(id: id, output: output, error: "script failed")
        }
    }

    /// output 为 nil = 没跑成,答 ok=false 带上 error。
    private func makeReply(id: String, output: String?, error: String) -> Reply {
        Reply(schema: Self.schema, id: id, ok: output != nil, output: output ?? "",
              error: output == nil ? error : nil, writtenAtMs: Int64(Date().timeIntervalSince1970 * 1000))
    }

    private func write(_ reply: Reply) {
        do {
            try JSONEncoder().encode(reply).write(to: Self.replyURL, options: .atomic)
        } catch {
            logger.notice("player query reply write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func osascript(_ source: String, timeout: TimeInterval) -> String? {
        guard let result = ProcessRunner.run("/usr/bin/osascript", ["-e", source], timeout: timeout),
              result.succeeded
        else { return nil }
        return result.stdoutText
    }

    /// 登记过的浏览器直接按表查;用户自己挑进来、还没判过的,回主线程现场判一次(`resolvedFamily` 只准主线程调)。
    /// 这里跑在 `queue` 上,不会是主线程。
    private static func browserFamily(forBundleID bundleID: String) -> BrowserAutomationPermission.Family? {
        if let known = BrowserAutomationPermission.family(forBundleID: bundleID) { return known }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { BrowserAutomationPermission.resolvedFamily(forBundleID: bundleID) }
        }
    }
}
