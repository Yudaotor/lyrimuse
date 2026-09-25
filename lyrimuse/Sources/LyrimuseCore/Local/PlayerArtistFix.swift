import Foundation

/// collector 发布的「这个播放器报的署名不可信,真署名是这个」通道
/// (见 collector/playerartistfix.go 与 kugoulyricartist.go 的头注)。
///
/// ## 为什么 App 要跟着换
///
/// 酷狗 3.3.2 把**当前这一句歌词**发布成 MediaRemote 的 artist,每唱一句换
/// 一次。collector 会把它换回真署名,而 App 自己也读 media-control —— 两边用的必须是
/// **同一个**署名:歌词缓存的 key 是 `artist|title|album`,collector 按纠正后的署名写进去,
/// App 按播放器报的脏署名去查,`EnrichCacheReader.looseMatch` 只折平空格 / 大小写 / 繁简,
/// 折不平两个完全不同的署名,于是一条也查不到。
///
/// 换句话说这件事**不能只做一半**:collector 改了、App 不改,歌词会从"能显示但歌手名
/// 是一句歌词"变成"压根不显示"。
///
/// ## 为什么由 collector 说了算
///
/// 真署名要从播放器自己的私有容器里读,而**读播放器容器是 collector 的活** —— App 侧一
/// 处都没有,那是一条既有的分层边界;两个进程的 TCC 授权也各自独立,各读各的会得出不同
/// 结论,而"两边一致"正是这条通道存在的全部理由。同 `LocalCacheAccess` 只能由 collector
/// 发布是一个道理。
///
/// 只读通道:App 从不写这份文件。
public enum PlayerArtistFix {
    public struct State: Decodable, Equatable, Sendable {
        public let updatedAt: Int64
        /// 这条纠正只对这个播放器的这一首歌成立。换歌那一刻两个进程不同步是常态
        /// (轮询节奏本来就不一样),对不上就当它不存在。
        public let bundle: String
        public let title: String
        public let artist: String
        /// 曲名也要换时的真曲名,空串 = 曲名不动。`title` 仍是播放器原样报的那个(适用范围)。
        /// 只有 collector 认定为「信任进来的其他播放器把歌词写进 artist 或 title」时才有
        /// (见 collector/trustedlyricartist.go)。
        public let fixedTitle: String
        /// 这个播放器哪个字段装着身份、不跟歌词变。空串 = title(酷狗与多数情形);"artist" = 歌词在
        /// title 里 —— 这时适用范围按 `rawArtist` 比、`title` 为空(title 每句都变,拿它比只对得上一拍),
        /// 曲目身份也改成剔掉曲名、留原样的 artist。播放器级,collector 重启时跟 `unreliable` 一起留下。
        public let stableField: String
        /// `stableField` 为 "artist" 时的适用范围:播放器原样报的 artist。
        public let rawArtist: String
        /// 这个播放器**被实际观测到**拿别的东西冒充署名。跟上面三项不同，它是播放器级的，
        /// collector 重启时会特意把它留下（曲目那两项会被清掉），所以重启后的第一首歌也不会
        /// 因为「还不知道这播放器不可信」而让身份抖起来。
        public let unreliable: Bool

        enum CodingKeys: String, CodingKey {
            case updatedAt, bundle, title, artist, fixedTitle, stableField, rawArtist, unreliable
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
            bundle = try c.decodeIfPresent(String.self, forKey: .bundle) ?? ""
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
            fixedTitle = try c.decodeIfPresent(String.self, forKey: .fixedTitle) ?? ""
            stableField = try c.decodeIfPresent(String.self, forKey: .stableField) ?? ""
            rawArtist = try c.decodeIfPresent(String.self, forKey: .rawArtist) ?? ""
            unreliable = try c.decodeIfPresent(Bool.self, forKey: .unreliable) ?? false
        }

        public init(updatedAt: Int64 = 0, bundle: String = "", title: String = "",
                    artist: String = "", fixedTitle: String = "", stableField: String = "",
                    rawArtist: String = "", unreliable: Bool = false) {
            self.updatedAt = updatedAt
            self.bundle = bundle
            self.title = title
            self.artist = artist
            self.fixedTitle = fixedTitle
            self.stableField = stableField
            self.rawArtist = rawArtist
            self.unreliable = unreliable
        }
    }

    public static let stateURL = LyrimusePaths.configFile("lyrimuse-player-artist-fix.json")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedMTime: Date?
    nonisolated(unsafe) private static var cached: State?

    /// 当前这条纠正;文件不存在 / 解析失败都是 nil。按 mtime 缓存,同 `LocalCacheAccess.current`。
    public static var current: State? {
        lock.lock()
        defer { lock.unlock() }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: stateURL.path))?[.modificationDate] as? Date
        guard let mtime else {
            cachedMTime = nil
            cached = nil
            return nil
        }
        if mtime == cachedMTime { return cached }
        cachedMTime = mtime
        cached = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        return cached
    }

    /// 这份快照该用的署名 —— 有对得上的纠正就返回它,否则 nil(照用播放器报的)。
    ///
    /// 比对 bundle 与曲名,**不比时长**:两边虽然读的是同一份载荷,但各自还有电台 / MV
    /// 那些改写时长的分支,多一个条件只多一种对不上的方式。
    ///
    /// 曲名认两种:播放器原样报的(`state.title`),和已经换过的(`state.fixedTitle`)。
    /// `applied` 之后的快照曲名就是换过的那个,界面拿它来问 `displayArtist` —— 只认原样的那个,
    /// 纠正落地之后歌手位反而一直空着。
    ///
    /// `stableField` 为 "artist" 的播放器按 `artist` 比(见那个字段),其余按曲名比。
    public static func artist(
        forBundle bundle: String?, title: String?, artist: String? = nil, state: State? = current
    ) -> String? {
        guard let state, !state.artist.isEmpty,
              matches(state, bundle: bundle, title: title, artist: artist) else { return nil }
        return state.artist
    }

    /// 这份快照该用的曲名 —— 有对得上、而且要换曲名的纠正就返回它,否则 nil(照用播放器报的)。
    public static func title(
        forBundle bundle: String?, title: String?, artist: String? = nil, state: State? = current
    ) -> String? {
        guard let state, !state.artist.isEmpty, !state.fixedTitle.isEmpty,
              matches(state, bundle: bundle, title: title, artist: artist) else { return nil }
        return state.fixedTitle
    }

    private static func matches(_ state: State, bundle: String?, title: String?, artist: String?) -> Bool {
        guard let bundle, !bundle.isEmpty, bundle == state.bundle else { return false }
        if state.stableField == "artist" {
            guard let artist, !artist.isEmpty, !state.rawArtist.isEmpty else { return false }
            // 原样的快照按原样的 artist 认;换过的快照(`applied` 之后)两个字段都是纠正后的。
            return artist == state.rawArtist || (artist == state.artist && title == state.fixedTitle)
        }
        guard let title, !title.isEmpty else { return false }
        return title == state.title || (!state.fixedTitle.isEmpty && title == state.fixedTitle)
    }

    /// 这个播放器报的署名可不可信。
    ///
    /// 判据是「collector 为它发布过纠正」——只有判定成立才会写这个文件，所以文件里记着
    /// 哪个 bundle，就说明那个播放器**被实际观测到**拿歌词冒充过署名。曲名不参与：换歌那
    /// 一刻文件里还是上一首，而这里要问的是「这个播放器」而不是「这一首歌」。
    public static func artistIsUnreliable(bundle: String?, state: State? = current) -> Bool {
        guard let bundle, !bundle.isEmpty, let state, state.bundle == bundle else { return false }
        return state.unreliable
    }

    /// 界面上该显示的署名 —— 纠正还没到的时候**宁可空着**。
    ///
    /// 署名不可信的播放器(酷狗 3.3.2 把当前这一句歌词发布成 artist)在 collector 的纠正
    /// 落地之前,`artist` 里装的是一句歌词、或者 LRC 头部的一行制作信息(`原唱：谈柒柒`
    /// `作曲：廖伟志` `【版权所有 未经许可 不得翻`)。collector 5 秒一拍、还要读播放器自己的
    /// plist 才出得来结论,比 App 的 2 秒轮询慢一截 —— 换歌头十几秒界面上的歌手位就一直在
    /// 跳词,最后才落到真署名上。
    ///
    /// 判据不看内容(「这串像不像歌词」是条死路,见 docs/features/02-playback-source.md
    /// 「酷狗 3.3.2…」一节),只问两件事:**这个播放器的署名可不可信**、**这一首的纠正到了
    /// 没有**。没到就返回空串。这跟广告插播 / 电台口白时把歌手位清空是同一个口径:
    /// 那时候没有"歌手"可言,画上去就是假信息。
    ///
    /// 只给**显示**用。查歌词缓存、拼平台链接、打卡那些地方仍然要用原来那个 `artist`:
    /// 它们拿它当 key,空串是另一个 key,对不上的后果比多显示十几秒错名字严重得多。
    public static func displayArtist(
        bundle: String?, title: String?, artist: String, state: State? = current
    ) -> String {
        guard artistIsUnreliable(bundle: bundle, state: state) else { return artist }
        return self.artist(forBundle: bundle, title: title, artist: artist, state: state) == nil ? "" : artist
    }

    /// 一份**独立取回**的载荷该用的曲目身份。
    ///
    /// 封面走的就是这么一条路：`fetchArtwork` 会再 exec 一次 media-control 拿 artworkData，
    /// 载荷里的署名是播放器原样报的，而当前快照那边可能已经换过了。两边不用同一把尺子的话，
    /// 下游那道「这份封面属于哪首歌」的守卫恒不相等——**封面被无声无息地全部丢掉**，
    /// 歌名歌词进度全对，唯独没有图。
    public static func correctedTrackKey(
        bundle: String?, artist rawArtist: String?, title: String?, state: State? = current
    ) -> String {
        // 署名不可信的播放器：整个把署名剔出身份。理由见 MediaControlSnapshot.identityKey。
        // 曲名一律折回播放器原样报的那个：换过曲名的快照(`applied` 之后)与没换过的(纠正还没
        // 落地 / 封面那次独立取回)得算出同一个身份，否则纠正落地那一刻身份变一次、封面被丢一次。
        if let state, artistIsUnreliable(bundle: bundle, state: state) {
            // 歌词在 title 里的播放器反过来:剔掉曲名、留原样的 artist(换过的快照折回 rawArtist)。
            if state.stableField == "artist" {
                let fixed = !state.rawArtist.isEmpty && rawArtist == state.artist && title == state.fixedTitle
                return MediaControlSnapshot.trackKey(artist: fixed ? state.rawArtist : rawArtist, title: nil)
            }
            let rawTitle = !state.fixedTitle.isEmpty && bundle == state.bundle && title == state.fixedTitle
                ? state.title : title
            return MediaControlSnapshot.trackKey(artist: nil, title: rawTitle)
        }
        return MediaControlSnapshot.trackKey(
            artist: artist(forBundle: bundle, title: title, artist: rawArtist, state: state) ?? rawArtist, title: title)
    }

    /// 把纠正应用到快照上(署名,要换时连曲名一起)。没有对得上的纠正、或者本来就一致时原样返回。
    public static func applied(
        to snapshot: MediaControlSnapshot?, state: State? = current
    ) -> MediaControlSnapshot? {
        guard let snapshot else { return nil }
        let bundle = snapshot.bundleIdentifier
        guard let fixedArtist = artist(forBundle: bundle, title: snapshot.title, artist: snapshot.artist, state: state)
        else { return snapshot }
        var out = snapshot
        if fixedArtist != out.artist { out = out.withArtist(fixedArtist) }
        if let fixedTitle = title(forBundle: bundle, title: snapshot.title, artist: snapshot.artist, state: state),
           fixedTitle != out.title {
            out = out.withTitle(fixedTitle)
        }
        return out
    }
}
