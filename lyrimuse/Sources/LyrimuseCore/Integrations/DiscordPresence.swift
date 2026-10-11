import Foundation

/// Discord activity 对象里用到的字段(`SET_ACTIVITY` 的 `args.activity`)。可选字段为 nil 时不编码。
public struct DiscordActivity: Equatable, Sendable, Encodable {
    public struct Assets: Equatable, Sendable, Encodable {
        /// 公网图片地址,或应用里上传的图的资源名。
        public var largeImage: String
        public var largeText: String?
        public var largeURL: String?
        /// 压在大图右下角的小图(`DiscordPresence.SmallImage`),同样是公网图片地址;点了打开的链接。
        /// 不发 `small_text`:指着小图不出悬停文字(见 12 章决策 62)。`large_text` 不能这样省 —— 卡片上的专辑那一行就是它。
        public var smallImage: String?
        public var smallURL: String?

        public init(largeImage: String, largeText: String? = nil, largeURL: String? = nil,
                    smallImage: String? = nil, smallURL: String? = nil) {
            self.largeImage = largeImage
            self.largeText = largeText
            self.largeURL = largeURL
            self.smallImage = smallImage
            self.smallURL = smallURL
        }

        enum CodingKeys: String, CodingKey {
            case largeImage = "large_image"
            case largeText = "large_text"
            case largeURL = "large_url"
            case smallImage = "small_image"
            case smallURL = "small_url"
        }
    }

    /// 资料卡底下的按钮。自己看不到自己的按钮(Discord 的已知问题),别人看得到、点得开。
    public struct Button: Equatable, Sendable, Encodable {
        public var label: String
        public var url: String

        public init(label: String, url: String) {
            self.label = label
            self.url = url
        }
    }

    public struct Timestamps: Equatable, Sendable, Encodable {
        /// Unix 毫秒。只给 start 时 Discord 显示已经过了多久,两个都给才有进度条。
        public var start: Int64
        public var end: Int64?

        public init(start: Int64, end: Int64? = nil) {
            self.start = start
            self.end = end
        }
    }

    /// 发给哪个 Discord 应用(按播放器分,见 `DiscordPresence.Application`)。不编码进 activity:应用由连接时的握手定。
    public var applicationID: String
    /// 覆盖显示的应用名。不认它的客户端显示注册的应用名。
    public var name: String?
    public var type: Int
    /// 好友列表那一行「正在听」后面写什么:0 应用名、1 `state`、2 `details`。
    public var statusDisplayType: Int
    /// 资料卡第一行、第二行;nil = 不发这一行(「不显示是哪首歌」时两行都不发)。
    public var details: String?
    public var detailsURL: String?
    public var state: String?
    public var stateURL: String?
    /// 没有封面时为 nil:Discord 显示应用自己的图标。
    public var assets: Assets?
    public var timestamps: Timestamps?
    /// 最多 2 个(`DiscordPresence.maxButtons`);没有时为 nil,不编码。
    public var buttons: [Button]?

    enum CodingKeys: String, CodingKey {
        case name, type, details, state, assets, timestamps, buttons
        case statusDisplayType = "status_display_type"
        case detailsURL = "details_url"
        case stateURL = "state_url"
    }
}

/// Discord「正在听」的规则:此刻的曲目组成什么样的 activity、暂停了怎么办。纯函数,时刻都由调用方传入。
public enum DiscordPresence {
    /// Lyrimuse 在 Discord 开发者后台注册的应用:认不出的播放器用它。应用 ID 不是密钥,客户端本来就要明文发给 Discord。
    public static let applicationID = "1556324467305742436"

    /// 每个播放器一个 Discord 应用。「正在听」那一行旁边的图标是应用的图标,iOS、网页版显示的是应用的名字,都跟着应用走,
    /// 发什么内容都改不了,所以按播放器分开建,名字和图标用那个播放器的。
    public enum Application: String, CaseIterable, Sendable {
        case lyrimuse, appleMusic, youtubeMusic, spotify, qqMusic, netease, kugou, soda, kkbox, amazonMusic

        /// 在开发者后台注册的名字:activity 没覆盖应用名时 Discord 显示它。
        public var registeredName: String {
            switch self {
            case .lyrimuse: return "Lyrimuse"
            case .appleMusic: return "Apple Music"
            case .youtubeMusic: return "YouTube Music"
            case .spotify: return "Spotify"
            case .qqMusic: return "QQ音乐"
            case .netease: return "网易云音乐"
            case .kugou: return "酷狗音乐"
            case .soda: return "汽水音乐"
            case .kkbox: return "KKBOX"
            case .amazonMusic: return "Amazon Music"
            }
        }
    }

    /// 各应用在开发者后台的 ID。
    static let applicationIDs: [Application: String] = [
        .lyrimuse: applicationID,
        .appleMusic: "1556509707059990559",
        .youtubeMusic: "1556510275795157083",
        .spotify: "1556510419072589824",
        .qqMusic: "1556510591831777280",
        .netease: "1556512689260339362",
        .kugou: "1556514113377542205",
        .soda: "1556515434419724338",
        .kkbox: "1556516014609535036",
        .amazonMusic: "1556516765062791188",
    ]

    /// 这个播放器归哪个应用。网页平台优先(浏览器的 bundle id 不对应任何平台);Kaset 归 YouTube Music。
    public static func application(forBundleID bundleID: String?, webPlatformID: String?) -> Application {
        switch webPlatformID {
        case "youtubeMusic"?: return .youtubeMusic
        case "spotifyWeb"?: return .spotify
        default: break
        }
        switch PlaybackPlayer.builtin(forBundleID: bundleID) {
        case .appleMusic?: return .appleMusic
        case .kaset?: return .youtubeMusic
        case .spotify?: return .spotify
        case .qqMusic?: return .qqMusic
        case .netease?: return .netease
        case .kugou?: return .kugou
        case .soda?: return .soda
        case .kkbox?: return .kkbox
        case .amazonMusic?: return .amazonMusic
        default: return .lyrimuse
        }
    }

    /// 这个播放器发给哪个应用。表里缺了的用 Lyrimuse 那个。
    public static func applicationID(forBundleID bundleID: String?, webPlatformID: String?) -> String {
        applicationIDs[application(forBundleID: bundleID, webPlatformID: webPlatformID)] ?? applicationID
    }
    /// 「正在听」后面写的名字:写服务的名字,不写客户端的名字 —— Kaset 是 YouTube Music 的客户端,写 YouTube Music。
    /// 其余播放器用调用方给的显示名。
    public static func listeningName(bundleID: String?, displayName: String?) -> String? {
        if bundleID == PlaybackPlayer.kaset.bundleIdentifier { return "YouTube Music" }
        return displayName
    }

    /// Discord 桌面版的 bundle id:正式版、PTB、Canary。三个听同一组本地套接字,开着哪个都能连;
    /// 「打开 Discord」打开装了的第一个。
    public static let desktopBundleIDs = ["com.hnc.Discord", "com.hnc.DiscordPTB", "com.hnc.DiscordCanary"]
    /// 没装 Discord 时「下载 Discord…」打开的页面。
    public static let downloadURL = URL(string: "https://discord.com/download")

    /// 开着「显示正在听的歌」、还没连上时卡在哪一步,设置页按它给引导。
    public enum Waiting: Equatable, Sendable {
        /// 这台 Mac 上没有 Discord 桌面版。
        case notInstalled
        /// 装了,没打开。
        case notRunning
        /// 开着,还没连上:刚启动,或者还没登录。
        case connecting
    }

    /// 没连上时属于哪一种。开着就按开着算:从别处直接运行的副本,LaunchServices 未必认得出装在哪。
    public static func waiting(installed: Bool, running: Bool) -> Waiting {
        if running { return .connecting }
        return installed ? .notRunning : .notInstalled
    }

    /// 在放时封面右下角放什么角标(设置里三选一)。暂停后保留状态时那个位置固定换成暂停图标。
    public enum Badge: String, CaseIterable, Sendable {
        case lyrimuse, player, none
    }

    /// 封面右下角的小图:Lyrimuse 角标、当前播放器的图标、暂停图标(带悬停文字),哪一种点了都打开官网。发的都是 Discord 图床上的
    /// 地址:Lyrimuse 角标和暂停图标在 Lyrimuse 那个应用的 Art Assets 里,播放器图标是它那个应用的 APP 图标,所以哪个应用
    /// 发的状态都能用。没有大图时不给。见 12 章决策 42、46。
    public enum SmallImage: Equatable, Sendable {
        case lyrimuse
        case player(Application)
        case paused

        var image: String? {
            switch self {
            case .lyrimuse: return DiscordPresence.lyrimuseBadgeURL
            case .player(let application): return DiscordPresence.iconURL(of: application)
            case .paused: return DiscordPresence.pausedBadgeURL
            }
        }
    }

    /// 在放时按设置给的角标。选了播放器时用当前播放器那个应用的图标;归 Lyrimuse 那个应用的(认不出的播放器)不给。
    public static func smallImage(for badge: Badge, applicationID: String) -> SmallImage? {
        switch badge {
        case .lyrimuse: return .lyrimuse
        case .none: return nil
        case .player:
            let application = application(forApplicationID: applicationID)
            return application == .lyrimuse ? nil : .player(application)
        }
    }

    /// 各应用在开发者后台传的 APP 图标(公开接口 `/applications/<应用 ID>/rpc` 返回的 `icon`)。后台换了图标这里要跟着改,
    /// 不然地址指向的还是旧图。
    static let applicationIconHashes: [Application: String] = [
        .lyrimuse: "a54b13bf114c8806f8139d5d4c1fdc1e",
        .appleMusic: "25a8439ce78331e5e5880499892a70c6",
        .youtubeMusic: "d6d24494502c4aee114eaa12b0cff2ab",
        .spotify: "2d30da2fe01c67744be3c1208cf7620b",
        .qqMusic: "4451b331880b93c093409b68c591d2bf",
        .netease: "9f22338d2f45ddddf1bcbdd382188856",
        .kugou: "db25818683122ac24d7486cf292f9bdb",
        .soda: "ca220c7a65ab2ce65a782445563a31ad",
        .kkbox: "21886f9232eb20654401a02aba00e9ad",
        .amazonMusic: "f45b2241b0606921b8fb4a1469672393",
    ]

    /// 这个应用的 APP 图标在 Discord 图床上的地址。
    public static func iconURL(of application: Application) -> String? {
        guard let id = applicationIDs[application], let hash = applicationIconHashes[application] else { return nil }
        return "https://cdn.discordapp.com/app-icons/" + id + "/" + hash + ".png?size=256"
    }

    public static let lyrimuseBadgeURL = "https://cdn.discordapp.com/app-assets/1556324467305742436/1556326373595938977.png"
    public static let pausedBadgeURL = "https://cdn.discordapp.com/app-assets/1556324467305742436/1556591591416668231.png"
    public static let websiteURL = "https://yudaotor.github.io/lyrimuse/"
    /// 「暂时隐藏」能选的时长(分钟)。
    public static let hideDurations = [15, 30, 60, 120, 240, 480]

    /// 这个应用 ID 是哪个应用的;认不出的算 Lyrimuse 那个。
    public static func application(forApplicationID id: String) -> Application {
        applicationIDs.first { $0.value == id }?.key ?? .lyrimuse
    }

    /// 好友列表那一行「正在听」后面写的字:按 `statusDisplayType` 取应用名、state 或 details。
    public static func statusText(of activity: DiscordActivity) -> String {
        switch activity.statusDisplayType {
        case StatusLine.artist.displayType: return activity.state ?? ""
        case StatusLine.title.displayType: return activity.details ?? ""
        default: return activity.name ?? ""
        }
    }

    /// activity 带的进度:按 `now` 已经放了多久、整首多长(毫秒),已放的夹在 0 到整首之间。没有起止时间时为 nil。
    public static func progress(of activity: DiscordActivity, now: Date) -> (elapsedMs: Int64, totalMs: Int64)? {
        guard let timestamps = activity.timestamps, let end = timestamps.end, end > timestamps.start else { return nil }
        let total = end - timestamps.start
        let elapsed = Int64((now.timeIntervalSince1970 * 1000).rounded()) - timestamps.start
        return (min(max(elapsed, 0), total), total)
    }

    /// 只有开始时间、没有结束时间时 Discord 在卡片底下写的时长:从开始到现在,开始在将来时是 0。
    public static func elapsed(of activity: DiscordActivity, now: Date) -> Int64? {
        guard let timestamps = activity.timestamps, timestamps.end == nil else { return nil }
        return max(0, Int64((now.timeIntervalSince1970 * 1000).rounded()) - timestamps.start)
    }

    /// 暂停后先留着原来那份这么久,再按设置清掉或换成暂停的那份:切歌间隙、随手暂停一下都不闪。
    public static let pauseGrace: TimeInterval = 10
    /// 从暂停到在放之后先等这么久再发:暂停着开播另一首时 QQ 音乐先报上一首在放、0.3 秒后才报新歌名,当场发的话
    /// 上一首会在 Discord 上挂一个节流周期(见 02 章决策 119)。
    public static let resumeSettleSecs: TimeInterval = 0.8

    /// 刚从暂停恢复、还在等 `resumeSettleSecs`:等到什么时候;不在等为 nil。纯函数,selftest 覆盖。
    public static func resumeSettleUntil(resumedAt: Date?, now: Date) -> Date? {
        guard let resumedAt else { return nil }
        let until = resumedAt.addingTimeInterval(resumeSettleSecs)
        return now < until ? until : nil
    }
    /// Discord 对文本字段的限制,按 UTF-16 码元数(它的校验按 JavaScript 的字符串长度算)。
    public static let textLengthRange = 2...128
    /// 链接超过这个长度就不给:截断的链接 Discord 会拒收整条 activity。
    public static let maxURLLength = 512
    /// activity 类型 2 = Listening,显示成「正在听」。
    static let listeningType = 2

    /// 好友列表那一行「正在听」后面写什么。rawValue 存在设置里。
    public enum StatusLine: String, CaseIterable, Sendable {
        case title, artist, player

        /// Discord 的 `status_display_type`。「播放器」显示的是 `name`(`ListeningName` 为播放器时就是播放器的名字)。
        public var displayType: Int {
            switch self {
            case .player: return 0
            case .artist: return 1
            case .title: return 2
            }
        }
    }

    /// 资料卡「正在听 ××」里的 ××,即 activity 的 `name`。rawValue 存在设置里。只有 Mac 和安卓的 Discord 认 `name`,
    /// iOS、网页版照旧显示应用的注册名(各播放器的应用就是播放器名,见 12 章决策 33)。
    /// case 顺序就是设置页上的顺序,跟 `StatusLine` 一致(歌名 / 歌手 / 播放器);默认值是 `.player`,不看顺序。
    public enum ListeningName: String, CaseIterable, Sendable {
        case title, artist, player
    }

    /// 资料卡上歌曲信息那一行写什么(`Layout` 的三行)。rawValue 存在设置里;case 顺序就是设置页下拉里的顺序。
    public enum LineContent: String, CaseIterable, Sendable {
        case title, artist, titleArtist, artistTitle, album, lyric, none

        /// 这一行写着歌名 / 歌手;合在一起的那两档两样都算。
        public var hasTitle: Bool { self == .title || self == .titleArtist || self == .artistTitle }
        public var hasArtist: Bool { self == .artist || self == .titleArtist || self == .artistTitle }
    }

    /// 组 activity 要的东西。歌名、歌手已经是界面上显示的写法。
    public struct Track: Equatable, Sendable {
        public var title: String
        public var artist: String
        public var album: String
        /// 播放器的显示名;nil 时不覆盖应用名。
        public var playerName: String?
        public var coverURL: URL?
        public var songURL: URL?
        public var artistURL: URL?
        /// 此刻的播放位置;nil = 不知道,不出进度条。
        public var positionMs: Int?
        public var durationMs: Int?
        /// 发给哪个 Discord 应用(`applicationID(forBundleID:webPlatformID:)`)。
        public var applicationID: String
        /// 有一行选了「当前歌词」时这一刻要显示的那句(`DiscordLyricLine.pick`);nil = 间奏、暂停、没歌词(那一行怎么写见 `activity`)。
        public var lyric: String?
        /// 资料卡底下的按钮(`DiscordPresence.buttons`);nil 或空 = 不带。
        public var buttons: [DiscordActivity.Button]?

        public init(title: String, artist: String, album: String = "", playerName: String? = nil,
                    coverURL: URL? = nil, songURL: URL? = nil, artistURL: URL? = nil,
                    positionMs: Int? = nil, durationMs: Int? = nil, applicationID: String = DiscordPresence.applicationID,
                    lyric: String? = nil, buttons: [DiscordActivity.Button]? = nil) {
            self.title = title
            self.artist = artist
            self.album = album
            self.playerName = playerName
            self.coverURL = coverURL
            self.songURL = songURL
            self.artistURL = artistURL
            self.positionMs = positionMs
            self.durationMs = durationMs
            self.applicationID = applicationID
            self.lyric = lyric
            self.buttons = buttons
        }
    }

    /// 此刻该让 Discord 显示什么。
    public enum Intent: Equatable, Sendable {
        case show(DiscordActivity)
        case clear
        /// 刚暂停:留着上一份不动,到这个时刻再看。
        case hold(until: Date)
    }

    /// 暂时隐藏期间(`hiddenUntil` 之前)、track 为 nil(没在放、广告、电台口白、排除的播放器)、没歌名或没歌手时清掉。
    /// 在放时按 `badge` 带角标(`smallImage(for:applicationID:)`)。暂停满 `pauseGrace` 后 `keepWhenPaused` 时换成暂停
    /// 的那份(`pausedActivity`,应用名按 `pausedNameFormat` 拼),否则清掉。
    public static func intent(track: Track?, pausedSince: Date?, statusLine: StatusLine,
                              listeningName: ListeningName = .player, keepWhenPaused: Bool,
                              badge: Badge = .none, pausedNameFormat: String = "%@ (Paused)",
                              layout: Layout = Layout(), hiddenUntil: Date? = nil, now: Date) -> Intent {
        if let hiddenUntil, now < hiddenUntil { return .clear }
        guard let track, !trimmed(track.title).isEmpty, !trimmed(track.artist).isEmpty else { return .clear }
        guard let pausedSince else {
            return .show(activity(track, statusLine: statusLine, listeningName: listeningName, now: now,
                                  smallImage: smallImage(for: badge, applicationID: track.applicationID), layout: layout))
        }
        let graceEnds = pausedSince.addingTimeInterval(pauseGrace)
        if now < graceEnds { return .hold(until: graceEnds) }
        guard keepWhenPaused else { return .clear }
        return .show(pausedActivity(track, statusLine: statusLine, listeningName: listeningName, now: now,
                                    pausedNameFormat: pausedNameFormat, layout: layout))
    }

    /// 暂停后保留的那份。Discord 没有暂停状态:不带时间戳它写这条状态挂了多久、一直往上走;开始时间在将来时停在 0:00。
    /// 开始时间取「当前这个十二小时段的起点再加一天」,总在十二到二十四小时之后:同一段里内容不变、不重发,跨段重发一次。
    /// 别放得太远,太远 Discord 整条不显示(见 12 章决策 50)。应用名后面加上暂停字样(`pausedNameFormat`,没有播放器名
    /// 时拿应用的注册名去拼),封面角上是暂停图标。
    public static func pausedActivity(_ track: Track, statusLine: StatusLine, listeningName: ListeningName = .player,
                                      now: Date, pausedNameFormat: String, layout: Layout = Layout()) -> DiscordActivity {
        var quiet = track
        quiet.lyric = nil
        var paused = activity(quiet, statusLine: statusLine, listeningName: listeningName, now: nil, smallImage: .paused,
                              layout: layout)
        let block: Int64 = 12 * 3_600_000
        let nowMs = Int64((now.timeIntervalSince1970 * 1000).rounded())
        paused.timestamps = DiscordActivity.Timestamps(start: nowMs / block * block + 2 * block)
        let player = paused.name ?? application(forApplicationID: track.applicationID).registeredName
        paused.name = fitted(String(format: pausedNameFormat, player))
        return paused
    }

    /// `now` 为 nil 时不带时间戳(暂停时保留的那份)。有位置才出时间戳,有时长才出进度条。没有封面就不给大图,Discord 显示
    /// 应用自己的图标(各播放器的应用就是那个播放器的图标);小图压在大图上,没有大图时也不给。
    ///
    /// 歌曲信息三行按 `layout` 写:第一行 `details`、第二行 `state`、第三行 `large_text`(也是悬停封面时的字)。写歌名的
    /// 那一行(含「歌名 - 歌手」)链到歌曲页,单写歌手的链到歌手页,专辑、歌词不挂链接。「当前歌词」那一行写「♪ 这一句」,
    /// 间奏、暂停、没歌词时写专辑,专辑已经单独占了一行就空着。第三行有字、没有封面时拿应用自己的图标当大图,不然那一行
    /// 出不来(小图照样不给,跟没封面时一个样子)。见 12 章决策 65、68。
    public static func activity(_ track: Track, statusLine: StatusLine, listeningName: ListeningName = .player,
                                now: Date?, smallImage: SmallImage? = nil, layout: Layout = Layout()) -> DiscordActivity {
        var timestamps: DiscordActivity.Timestamps?
        if let now, let position = track.positionMs {
            let start = Int64((now.timeIntervalSince1970 * 1000).rounded()) - Int64(max(0, position))
            let end = layout.showsProgress ? track.durationMs.flatMap { $0 > 0 ? start + Int64($0) : nil } : nil
            timestamps = DiscordActivity.Timestamps(start: start, end: end)
        }
        let songLink = link(track.songURL)
        let player = track.playerName.map(trimmed).flatMap { $0.isEmpty ? nil : $0 }
        let buttons = track.buttons.map { all in
            // 不显示是哪首歌时,链到这首歌曲页的按钮(「在 XX 上收听」)也不带。
            Array(all.filter { !(layout.hidesSong && $0.url == songLink) }.prefix(maxButtons))
        }.flatMap { $0.isEmpty ? nil : $0 }
        if layout.hidesSong {
            let icon = iconURL(of: application(forApplicationID: track.applicationID))
            // 大图已经是播放器图标,角标再放一遍播放器图标就重复了,不放。
            let badge: SmallImage? = { if case .player? = smallImage { return nil }; return smallImage }()
            return DiscordActivity(
                applicationID: track.applicationID, name: player.map(fitted), type: listeningType,
                statusDisplayType: StatusLine.player.displayType,
                details: nil, detailsURL: nil, state: nil, stateURL: nil,
                assets: icon.map {
                    DiscordActivity.Assets(largeImage: $0, smallImage: badge?.image,
                                           smallURL: badge?.image == nil ? nil : websiteURL)
                },
                timestamps: timestamps, buttons: buttons)
        }
        let cover = track.coverURL.flatMap { $0.scheme?.lowercased() == "https" ? link($0) : nil }
        let title = trimmed(track.title)
        let artist = trimmed(track.artist)
        let album = trimmed(track.album)
        let lyric = track.lyric.map(trimmed).flatMap { $0.isEmpty ? nil : lyricMark + $0 }
        let albumHasOwnLine = layout.lines.contains(.album)
        func text(_ content: LineContent) -> String? {
            switch content {
            case .title: return fitted(title)
            case .artist: return fitted(layout.artistFormat.map { String(format: $0, artist) } ?? artist)
            case .titleArtist: return fitted(title + " - " + artist)
            case .artistTitle: return fitted(artist + " - " + title)
            case .album: return album.isEmpty ? nil : fitted(layout.albumFormat.map { String(format: $0, album) } ?? album)
            case .lyric: return lyric.map(fitted) ?? (albumHasOwnLine ? nil : text(.album))
            case .none: return nil
            }
        }
        func url(_ content: LineContent) -> String? {
            if content.hasTitle { return songLink }
            return content == .artist ? link(track.artistURL) : nil
        }
        let name: String?
        switch listeningName {
        case .player: name = player.map(fitted)
        case .title: name = fitted(track.title)
        case .artist: name = fitted(track.artist)
        }
        let shown = effectiveStatusLine(statusLine, listeningName: listeningName, layout: layout)
        let largeText = text(layout.third)
        return DiscordActivity(
            applicationID: track.applicationID,
            name: name,
            type: listeningType,
            statusDisplayType: statusDisplayType(of: shown, listeningName: listeningName, layout: layout)
                ?? StatusLine.player.displayType,
            details: text(layout.first),
            detailsURL: url(layout.first),
            state: text(layout.second),
            stateURL: url(layout.second),
            assets: cover.map {
                DiscordActivity.Assets(largeImage: $0, largeText: largeText, largeURL: songLink,
                                       smallImage: smallImage?.image,
                                       smallURL: smallImage?.image == nil ? nil : websiteURL)
            } ?? largeText.flatMap { largeText in
                iconURL(of: application(forApplicationID: track.applicationID)).map {
                    DiscordActivity.Assets(largeImage: $0, largeText: largeText, largeURL: songLink)
                }
            },
            timestamps: timestamps,
            buttons: buttons)
    }

    /// 「正在收听」后面实际写的是哪一档(设置页按它显示):不显示是哪首歌时一律播放器。
    public static func effectiveListeningName(_ stored: ListeningName, layout: Layout) -> ListeningName {
        layout.hidesSong ? .player : stored
    }

    /// 用户名下方选这一档时发哪个 `status_display_type`;nil = 这一档此刻写不出来(设置页那一档变灰)。Discord 只让
    /// 第一行、第二行或「正在收听」后面那个放到用户名下方。歌名、歌手先找单写它的那一行,再找合在一起的那一行,第一行在前;
    /// 两行都没写、「正在收听」后面写的正是它时用 `name`。「播放器」只在「正在收听」后面写播放器时有。
    static func statusDisplayType(of line: StatusLine, listeningName: ListeningName, layout: Layout) -> Int? {
        let name = effectiveListeningName(listeningName, layout: layout)
        let rows: [(content: LineContent, displayType: Int)] = layout.hidesSong ? [] : [
            (layout.first, StatusLine.title.displayType), (layout.second, StatusLine.artist.displayType),
        ]
        switch line {
        case .player:
            return name == .player ? StatusLine.player.displayType : nil
        case .title:
            return (rows.first { $0.content == .title } ?? rows.first { $0.content.hasTitle })?.displayType
                ?? (name == .title ? StatusLine.player.displayType : nil)
        case .artist:
            return (rows.first { $0.content == .artist } ?? rows.first { $0.content.hasArtist })?.displayType
                ?? (name == .artist ? StatusLine.player.displayType : nil)
        }
    }

    /// 用户名下方能选哪几档(`statusDisplayType(of:listeningName:layout:)` 写得出来的),顺序同 `StatusLine.allCases`。
    public static func statusLines(for listeningName: ListeningName, layout: Layout) -> [StatusLine] {
        StatusLine.allCases.filter { statusDisplayType(of: $0, listeningName: listeningName, layout: layout) != nil }
    }

    /// 用户名下方实际写的是哪一档(设置页按它显示):存着的那档写不出来时,退到「正在收听」后面写的那一样 —— 那一样总写得出来
    /// (至少用 `name`)。存着的值不动,条件撤掉后原样恢复。
    public static func effectiveStatusLine(_ stored: StatusLine, listeningName: ListeningName, layout: Layout) -> StatusLine {
        if statusDisplayType(of: stored, listeningName: listeningName, layout: layout) != nil { return stored }
        switch effectiveListeningName(listeningName, layout: layout) {
        case .player: return .player
        case .title: return .title
        case .artist: return .artist
        }
    }

    /// 资料卡上的字怎么排、哪些不显示(设置页「显示内容」「隐私」两段)。默认值就是不做任何改动的样子。见 12 章决策 68。
    public struct Layout: Equatable, Sendable {
        /// 不显示是哪首歌:只留「正在听 播放器」、应用图标和进度;三行、链接和「在 XX 上收听」都不发,
        /// 「正在收听」后面、用户名下方都写播放器名。
        public var hidesSong: Bool
        /// 歌曲信息三行各写什么:第一行 `details`、第二行 `state`、第三行 `large_text`。
        public var first: LineContent
        public var second: LineContent
        public var third: LineContent
        /// 关掉时不给结束时间:没有进度条,Discord 改写这首放了多久(这个计时 Discord 一定显示,关不掉)。
        public var showsProgress: Bool
        /// 单写歌手、专辑的那一行前面加的字(「演唱：%@」「专辑：%@」,跟界面语言走);nil = 不加。合在一起的那一行不加。
        public var artistFormat: String?
        public var albumFormat: String?

        public init(hidesSong: Bool = false, first: LineContent = .title, second: LineContent = .artist,
                    third: LineContent = .album, showsProgress: Bool = true,
                    artistFormat: String? = nil, albumFormat: String? = nil) {
            self.hidesSong = hidesSong
            self.first = first
            self.second = second
            self.third = third
            self.showsProgress = showsProgress
            self.artistFormat = artistFormat
            self.albumFormat = albumFormat
        }

        public var lines: [LineContent] { [first, second, third] }
        /// 有一行写当前歌词,且没选「不显示是哪首歌」:这时才去挑句、起歌词节拍。
        public var followsLyrics: Bool { !hidesSong && lines.contains(.lyric) }
    }

    /// 写歌词的那一行加在前面的记号。
    public static let lyricMark = "\u{266A} "

    /// 按钮最多几个、文字多长(按 UTF-16 码元,同 `textLengthRange`)。
    public static let maxButtons = 2
    public static let buttonLabelLength = 1...32

    /// 资料卡底下的按钮,依次取、只留前 `maxButtons` 个:自定义按钮(文字和链接都有效才算)、「在 XX 上收听」(这首有歌曲页
    /// 才有,`listenLabel` 是已经拼好服务名的文字)、「获取 Lyrimuse」(链到官网)。没有一个时为 nil。
    public static func buttons(custom: (label: String, url: String)?, listen: Bool, listenLabel: String, songURL: URL?,
                               getLyrimuse: Bool, getLyrimuseLabel: String) -> [DiscordActivity.Button]? {
        var result: [DiscordActivity.Button] = []
        if let custom, let label = buttonLabel(custom.label), let url = link(URL(string: trimmed(custom.url))) {
            result.append(DiscordActivity.Button(label: label, url: url))
        }
        if listen, let url = link(songURL), let label = buttonLabel(listenLabel) {
            result.append(DiscordActivity.Button(label: label, url: url))
        }
        if getLyrimuse, let label = buttonLabel(getLyrimuseLabel) {
            result.append(DiscordActivity.Button(label: label, url: websiteURL))
        }
        return result.isEmpty ? nil : Array(result.prefix(maxButtons))
    }

    /// 自定义按钮填的链接能不能用(http / https、不超长)。设置页据此提示。
    public static func isUsableButtonURL(_ text: String) -> Bool {
        link(URL(string: trimmed(text))) != nil
    }

    /// 按钮文字:去掉首尾空白,空的不要,超长截到上限(留一位给省略号,不切开一个字)。
    static func buttonLabel(_ text: String) -> String? {
        let text = trimmed(text)
        guard !text.isEmpty else { return nil }
        guard text.utf16.count > buttonLabelLength.upperBound else { return text }
        var kept = ""
        var units = 0
        for character in text {
            let width = character.utf16.count
            if units + width > buttonLabelLength.upperBound - 1 { break }
            kept.append(character)
            units += width
        }
        return kept + "…"
    }

    /// Discord 拒收了这一份时补发的精简版:去掉歌名、歌手上的链接,大图、小图(连带它们的悬停文字和链接)和按钮,文字和
    /// 时间照旧。被拒多半是哪个链接或哪张图它不认,精简版至少还能显示歌名、歌手。
    public static func withoutLinksAndImages(_ activity: DiscordActivity) -> DiscordActivity {
        var plain = activity
        plain.detailsURL = nil
        plain.stateURL = nil
        plain.assets = nil
        plain.buttons = nil
        return plain
    }

    /// 按 Discord 的长度限制收拾一段文本:去掉首尾空白,超长截到上限(留一位给省略号,不切开一个字),不够两位补零宽空格
    /// (U+200B,看不见;补普通空格的话,Discord 校验前要是也去掉首尾空白,单个字的歌名照样不够两位、整条被拒)。
    public static func fitted(_ text: String) -> String {
        var result = trimmed(text)
        if result.utf16.count > textLengthRange.upperBound {
            var kept = ""
            var units = 0
            for character in result {
                let width = character.utf16.count
                if units + width > textLengthRange.upperBound - 1 { break }
                kept.append(character)
                units += width
            }
            result = kept + "…"
        }
        while result.utf16.count < textLengthRange.lowerBound {
            result += "\u{200B}"
        }
        return result
    }

    /// 只给 http / https、不超长的链接;别的(`music://` 这类进 App 的深链、本地文件)一律不给。
    static func link(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        let text = url.absoluteString
        return text.count <= maxURLLength ? text : nil
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 什么时候把哪份发给 Discord:最多每 `minInterval` 发一次,攒着的只发最新那份;跟上次发出去的一样就不发。
/// 全部按传入的时刻判。
public struct DiscordPresenceGate: Sendable {
    /// Discord 每 20 秒只收 5 次,多出来的排队,连着切歌时状态会落后好几首。
    public static let minInterval: TimeInterval = 4
    /// 时间戳差在这以内算没变:起点每次按此刻倒推,外推的抖动不该触发重发;拖动进度会超过它。
    public static let timestampToleranceMs: Int64 = 2_000

    public enum Decision: Equatable, Sendable {
        case send(DiscordActivity?)
        case wait(until: Date)
        case none
    }

    /// 上一份发出去的。`.some(nil)` 是发过清空;nil 是这条连接上还没发过。
    public private(set) var lastSent: DiscordActivity??
    public private(set) var lastSentAt: Date?

    public init() {}

    public func decide(_ intent: DiscordPresence.Intent, now: Date) -> Decision {
        let wanted: DiscordActivity?
        switch intent {
        case .hold(let until):
            return .wait(until: until)
        case .clear:
            wanted = nil
        case .show(let activity):
            wanted = activity
        }
        switch lastSent {
        case .none:
            if wanted == nil { return .none }
        case .some(let sent):
            if Self.sameContent(sent, wanted) { return .none }
        }
        if let lastSentAt, now < lastSentAt.addingTimeInterval(Self.minInterval) {
            return .wait(until: lastSentAt.addingTimeInterval(Self.minInterval))
        }
        return .send(wanted)
    }

    public mutating func didSend(_ activity: DiscordActivity?, at now: Date) {
        lastSent = .some(activity)
        lastSentAt = now
    }

    /// 连接断了:Discord 那边已经随之清掉,下次照常发。节流的时刻留着。
    public mutating func forget() {
        lastSent = nil
    }

    /// 两份算不算同一个内容:时间戳差在 `timestampToleranceMs` 以内,其余字段全等。
    public static func sameContent(_ a: DiscordActivity?, _ b: DiscordActivity?) -> Bool {
        guard var a, var b else { return a == nil && b == nil }
        guard closeEnough(a.timestamps, b.timestamps) else { return false }
        a.timestamps = nil
        b.timestamps = nil
        return a == b
    }

    private static func closeEnough(_ a: DiscordActivity.Timestamps?, _ b: DiscordActivity.Timestamps?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case let (a?, b?):
            guard abs(a.start - b.start) <= timestampToleranceMs else { return false }
            switch (a.end, b.end) {
            case (nil, nil): return true
            case let (x?, y?): return abs(x - y) <= timestampToleranceMs
            default: return false
            }
        default:
            return false
        }
    }
}
