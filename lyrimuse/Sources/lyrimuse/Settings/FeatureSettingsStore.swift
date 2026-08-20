import Foundation
import LyrimuseCore
import os
import SwiftUI

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "feature-settings")

// 五个歌词源——rawValue 必须跟 collector/features.go 的 lyricSourceXxx 常量逐字对应,
// 这是两侧通过共享 json 文件交换的字符串。displayName/color 直接委托给
// LyricsManagerView.swift 已有的 sourceDisplayName/sourceColor(那两个函数今天也在给
// "歌词管理"窗口的来源筛选/列表用),不重复维护第二份名字/颜色映射。
public enum LyricsSource: String, CaseIterable, Identifiable, Codable, Hashable {
    case netease, qq, kugou, musixmatch, lrclib
    public var id: Self { self }
    public var displayName: String { sourceDisplayName(rawValue) }
    public var color: Color { sourceColor(rawValue) }
}

// Musixmatch 译文(collector/musixmatch.go 的 crowd.track.translations.get)目标语言——
// 网易云/QQ 音乐的译文固定是中文,只有 Musixmatch 这个源能指定任意语言,rawValue 必须是
// Musixmatch 认的 ISO 639-1 两位小写代码(已用真实接口核实过这个格式,见开发时的调研)。
// .auto 的字面值原样写进共享 json,由 collector 侧 resolveLyricsTranslationLanguage
// (features.go)解析成具体代码——那边用 `defaults read -g AppleLocale` 读 macOS 系统
// 语言,不是 Swift 这边解析:collector 是长驻后台进程,读一次系统级偏好设置比 Swift
// App 每次保存时读 Locale.current 更贴近"用户实际在用的系统语言此刻是什么",也让这个
// 字段跟这个 store 里其它字段一样,原始 rawValue 直接对称读写、不需要额外的解析层。
// 跟随的是 macOS 系统语言而不是 App 界面语言:App 界面本身只做了中英两版翻译,母语是
// 西语/日语等的用户即使 App 界面只能显示英文,系统语言仍然如实反映其母语,能让这个
// 功能真正惠及"母语非中非英"的用户,而不是被 App 界面语言的两个选项卡住。
public enum MusixmatchTranslationLanguage: String, CaseIterable, Identifiable, Codable {
    case auto
    case en, zh, ja, ko, es, fr, de, pt, it, ru, ar, vi, th, id, nl, pl, tr

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .auto: return L10n.t("跟随系统语言")
        case .en: return "English"
        case .zh: return "简体中文"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .es: return "Español"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .pt: return "Português"
        case .it: return "Italiano"
        case .ru: return "Русский"
        case .ar: return "العربية"
        case .vi: return "Tiếng Việt"
        case .th: return "ไทย"
        case .id: return "Bahasa Indonesia"
        case .nl: return "Nederlands"
        case .pl: return "Polski"
        case .tr: return "Türkçe"
        }
    }
}

// PlaybackPlayer 定义在 LyrimuseCore(见 Local/PlaybackPlayer.swift)——MediaControlClient/
// LocalPlaybackSource 也需要认这个类型,而它们在 LyrimuseCore、不能反向依赖这个
// (lyrimuse 主 App target)文件,所以类型本身放在被依赖的下层,这里只是引用。
extension PlaybackPlayer {
    public var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .qqMusic: return L10n.t("QQ 音乐")
        case .netease: return L10n.t("网易云音乐")
        case .spotify: return "Spotify"
        case .auto: return L10n.t("自动识别")
        }
    }
}

// "智能算法"=四源全查+打分取最高分(现有行为,见 collector/enrich.go 的
// scoredLyricCandidates/pickLyricCandidate);"顺序优先"=按用户手排的顺序,取第一个
// 通过质量校验的源,不比较分数。
public enum LyricsSourceMode: String, CaseIterable, Identifiable, Codable {
    case smart, priority
    public var id: Self { self }
    public var displayName: String {
        switch self {
        case .smart: return L10n.t("智能算法")
        case .priority: return L10n.t("顺序优先")
        }
    }
}

// 跟 collector/features.go 的 featureFlagsFile 逐字段对应的 on-disk 形状——所有字段
// 可选(nil = 沿用默认开启),跟 collector 侧"文件缺失/字段缺失都当作 true"的约定一致,
// 这里存的是 Lyrimuse 这台机器上用户明确设置过的值。collector/features.go 那侧是
// 同一份共享 JSON 文件的镜像,字段增删两侧同步;旧配置文件里如果还留着已经删掉的
// key,JSONDecoder/Go 的 encoding/json 都会静默忽略未知字段,不需要额外的迁移代码。
struct FeatureFlagsFile: Codable, Equatable {
    // "apple_music"(默认)或"qq_music"——见 PlaybackPlayer 注释(LyrimuseCore)。跟这个
    // 文件里其它字段一样"读一次,重启才生效":LocalPlaybackSource 每次轮询都会重新读
    // 一次这个字段(它在 LyrimuseCore,没法直接订阅这个 store 的 @Published),collector
    // 只在启动时读一次。
    var player: String?
    var albumPrefetch: Bool?
    var lyricsMachineTranslation: Bool?
    var lastfmMirrorScrobble: Bool?
    var weeklyDigest: Bool?
    // 见 collector/daily.go——独立于 weeklyDigest 的开关,两个可以同时开、只开一个、
    // 或都不开。
    var dailyDigest: Bool?
    // "lastfm"/"listenbrainz"/缺省(空字符串)——两个 cadence 各自用哪个账号的数据源,
    // 缺省时按 collector/digest.go 的 resolveDigestSource 规则(两个都配了→lastfm,
    // 只配了一个→用那个,都没配→这个功能没法跑)自动判定,不是"缺省当 lastfm 处理"
    // 这么简单,所以特意不给非空默认值。两个 cadence 都能自己选数据源,是因为
    // Last.fm 的周榜接口其实接受任意 from/to,不是只认它自己的官方周边界。
    var weeklyDigestSource: String?
    var dailyDigestSource: String?
    var lyricsSources: [String]?
    var lyricsSourceMode: String?
    var lyricsSourceOrder: [String]?
    var lyricsDir: String?
    // "auto"(跟随系统语言,默认)或具体 ISO 639-1 代码("en"/"zh"/"ja"...)——见
    // MusixmatchTranslationLanguage 注释,collector 侧负责把 "auto" 解析成具体代码。
    var lyricsTranslationLanguage: String?
    // 打开 Apple Music 时顺带唤起 Lyrimuse——这个方向的联动由 collector(常驻后台,
    // 不依赖 Lyrimuse.app 主进程是否在运行)负责监测 Music.app 的启动状态,见
    // collector/companionlaunch.go。反方向("打开 Lyrimuse 时唤起 Music")不需要
    // 这份共享文件,直接是 AppSettings.launchMusicOnLyrimuseOpen 一个纯 Swift 侧设置。
    var launchLyrimuseOnMusicOpen: Bool?

    /// CaseIterable 是为了让 `knownFileKeys` 能自动跟着字段增删走 —— 手工维护第二份
    /// 键名清单迟早会跟这里对不上,而对不上的后果正是下面要修的那种静默丢数据。
    enum CodingKeys: String, CodingKey, CaseIterable {
        case player
        case albumPrefetch = "album_prefetch"
        case lyricsMachineTranslation = "lyrics_machine_translation"
        case lastfmMirrorScrobble = "lastfm_mirror_scrobble"
        case weeklyDigest = "weekly_digest"
        case dailyDigest = "daily_digest"
        case weeklyDigestSource = "weekly_digest_source"
        case dailyDigestSource = "daily_digest_source"
        case lyricsSources = "lyrics_sources"
        case lyricsSourceMode = "lyrics_source_mode"
        case lyricsSourceOrder = "lyrics_source_order"
        case lyricsDir = "lyrics_dir"
        case lyricsTranslationLanguage = "lyrics_translation_language"
        case launchLyrimuseOnMusicOpen = "launch_lyrimuse_on_music_open"
    }

    /// 这个版本认识的全部 JSON 键。见 FeatureSettingsStore.unknownFileKeys 的注释。
    static let knownFileKeys: Set<String> = Set(CodingKeys.allCases.map(\.rawValue))
}

// "歌词"tab 的纯行为开关(lyrics/albumPrefetch 等)和"账号连接"tab 里各张
// 账号卡片的开关(lastfmMirrorScrobble/weeklyDigest)共用同一份数据层——读写
// ~/.config/lyrimuse/lyrimuse-features.json,跟
// collector/features.go 是同一份共享文件的两侧独立实现。2026-07-29:Last.fm 桥接
// (读 Last.fm 转发进 ListenBrainz + 喂网页"正在播放")不再是这里的一个独立开关——
// Last.fm 桥接凭据 + ListenBrainz 账号都配好就自动生效,跟 collector 侧
// poller.go 的 bridge() 判断条件一致,见那边的注释。
//
// 这个 store 里的每一个开关都是"改了立刻保存"——Binding 的 set 里包一层
// `Task { await features.save() }`,持久化+重启挪到后台执行,但从用户视角"点开关
// 立刻生效"这个体验不变(不需要等,也没有额外的"保存中"提示)。"账号连接"tab 底部那条
// 批量保存栏(isDirty/saveBar)管的是 ConfigStore 的文本/密钥字段,跟这个 store 的开关
// 无关,不要混为一谈。
@MainActor
public final class FeatureSettingsStore: ObservableObject {
    public static let shared = FeatureSettingsStore()

    // 本地播放状态读取哪个 App——默认 Apple Music,保持这个设置加入之前唯一存在过的
    // 行为不变。见 PlaybackPlayer(LyrimuseCore)注释。
    @Published public var player: PlaybackPlayer = .appleMusic
    @Published public var albumPrefetch = true
    // 这几个都要连一个外部账号才有意义,默认关闭。collector/features.go 的 boolOr
    // 默认值要跟着一起改,否则全新安装时 Swift 这边显示关、Go 那边却按"缺字段=开启"
    // 实际执行,两边会对不上。
    // 歌词源没带社区译文时,自己补一份翻译。默认关:优先走系统端上翻译(不联网),
    // 但在 macOS 26 以下、或语言包没装时会退到网络翻译服务,那条路会把歌词正文发出去,
    // 该由用户显式同意 —— 现有的五个歌词源只发歌手/歌名。
    @Published public var lyricsMachineTranslation = false
    @Published public var lastfmMirrorScrobble = false
    @Published public var weeklyDigest = false
    @Published public var dailyDigest = false
    // 空字符串 = 用户没手动选过,交给 AccountLinkingTab 的 resolvedDigestSource 按
    // "已配置的账号"自动判定要不要显示成"lastfm"/"listenbrainz"，这里只负责持久化
    // 用户一旦手动选过之后的显式值。
    @Published public var weeklyDigestSource = ""
    @Published public var dailyDigestSource = ""
    @Published public var lyricsSources: Set<LyricsSource> = Set(LyricsSource.allCases)
    @Published public var lyricsSourceMode: LyricsSourceMode = .smart
    // 始终是全部 4 个源的一个排列(不是"只放启用的那几个")——启用/禁用状态单独由
    // lyricsSources 记录,顺序调整只在这个数组内部交换位置,两者互不干扰,不需要"禁用
    // 一个源时把它从顺序表里摘出来/重新插回去"这种同步逻辑。
    @Published public var lyricsSourceOrder: [LyricsSource] = LyricsSource.allCases
    // 空字符串 = 用默认位置(~/.config/lyrimuse/lyrics)。用 effectiveLyricsDir
    // 取实际生效的路径,不要直接读这个属性去拼路径。
    @Published public var lyricsDir = ""
    // 只影响 Musixmatch 这个源的译文语言,详见 MusixmatchTranslationLanguage 注释。
    @Published public var lyricsTranslationLanguage: MusixmatchTranslationLanguage = .auto
    // 打开 Apple Music 时顺带唤起 Lyrimuse——默认关闭,理由跟
    // AppSettings.launchMusicOnLyrimuseOpen 一样:"自动启动另一个 App"不该是没问过
    // 用户就默认打开的行为。
    // 默认开:这是「装了就该有的样子」——打开播放器歌词就跟上来,而不是每次还要先
    // 想起来去菜单栏点一下 Lyrimuse。⚠️ 改默认值必须跟 collector 侧 features.go 的
    // boolOr(..., true) 一起改,不然 Swift 这边显示「开」而真正执行的 collector 当它是关。
    @Published public var launchLyrimuseOnMusicOpen = true

    @Published public private(set) var lastError: String?

    private static let featuresURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lyrimuse/lyrimuse-features.json")

    private var savedSnapshot = FeatureFlagsFile()
    private var currentSnapshot: FeatureFlagsFile {
        FeatureFlagsFile(
            player: player.rawValue,
            albumPrefetch: albumPrefetch,
            lyricsMachineTranslation: lyricsMachineTranslation,
            lastfmMirrorScrobble: lastfmMirrorScrobble, weeklyDigest: weeklyDigest, dailyDigest: dailyDigest,
            weeklyDigestSource: weeklyDigestSource.isEmpty ? nil : weeklyDigestSource,
            dailyDigestSource: dailyDigestSource.isEmpty ? nil : dailyDigestSource,
            lyricsSources: lyricsSources.map(\.rawValue).sorted(),
            lyricsSourceMode: lyricsSourceMode.rawValue,
            lyricsSourceOrder: lyricsSourceOrder.map(\.rawValue),
            lyricsDir: lyricsDir.isEmpty ? nil : lyricsDir,
            lyricsTranslationLanguage: lyricsTranslationLanguage.rawValue,
            launchLyrimuseOnMusicOpen: launchLyrimuseOnMusicOpen
        )
    }

    // 供 EnrichCacheStore("歌词管理"窗口的文件读写)和 Settings 里的"打开歌词文件夹"
    // 按钮共用——两边都必须认同一个文件夹,不能各自兜底出两份不一致的默认路径。
    public var effectiveLyricsDir: URL {
        if !lyricsDir.isEmpty {
            return URL(fileURLWithPath: lyricsDir)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/lyrimuse/lyrics")
    }
    public var isDirty: Bool { currentSnapshot != savedSnapshot }

    private init() {
        load()
    }

    /// 磁盘上存在、但**这个版本**的 FeatureFlagsFile 不认识的键,原样留着,写盘时再合并回去。
    ///
    /// 2026-08-13 补。原来 persistFile() 直接 `JSONEncoder().encode(currentSnapshot)`,
    /// 只吐出 FeatureFlagsFile 声明过的字段 —— 磁盘上任何它不认识的键**写一次就没了**。
    /// 上面 :93 那条注释("JSONDecoder/Go 都会静默忽略未知字段,不需要额外的迁移代码")
    /// 只对**读**成立,漏了写这一半。
    ///
    /// 具体会怎么丢:Mac A 已经更新到新版、Mac B 还停在旧版(Sparkle 不会同时到达两台)。
    /// A 导出 → B 导入,B 的 features.json 这时带着新版才有的字段 → 用户在 B 上随手拨一个
    /// 开关 → persistFile() 按旧版的 struct 重新编码 → 新版字段被抹掉 → B 再导出/更新
    /// iCloud 备份,损失就回传给 A 了。
    ///
    /// 隔壁 ConfigStore 没这个问题,它是 `raw: [String: Any]` 整字典读写(见那边 :72-78
    /// 花了六行解释为什么必须这样)。两个 Store 对未知字段的处理原本是**反的**,这里补齐。
    private var unknownFileKeys: [String: Any] = [:]

    public func load() {
        guard let data = try? Data(contentsOf: Self.featuresURL),
              let f = try? JSONDecoder().decode(FeatureFlagsFile.self, from: data) else {
            // 文件不存在/解析失败——维持属性的默认值,跟 collector 侧 loadFeatureFlags
            // 的默认值约定完全一致(核心行为开关 fail-open=true;需要外部账号的 6 个
            // fail-closed=false,见上面属性声明处的说明)。
            unknownFileKeys = [:]
            savedSnapshot = currentSnapshot
            return
        }
        // 同一份字节再按裸字典解一次,把这个版本不认识的键记下来(见 unknownFileKeys)。
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            unknownFileKeys = obj.filter { !FeatureFlagsFile.knownFileKeys.contains($0.key) }
            // os.Logger 的插值参数是 @autoclosure,引用实例属性要显式写 self —— debug 构建
            // 放过了这一点,release(-O)才报错,所以只跑 `swift build` 验证是不够的。
            if !unknownFileKeys.isEmpty {
                logger.notice("features.json carries \(self.unknownFileKeys.count) key(s) this build doesn't know; they will be preserved on write")
            }
        } else {
            unknownFileKeys = [:]
        }
        player = f.player.flatMap(PlaybackPlayer.init(rawValue:)) ?? .auto
        albumPrefetch = f.albumPrefetch ?? true
        lyricsMachineTranslation = f.lyricsMachineTranslation ?? false
        lastfmMirrorScrobble = f.lastfmMirrorScrobble ?? false
        weeklyDigest = f.weeklyDigest ?? false
        dailyDigest = f.dailyDigest ?? false
        weeklyDigestSource = f.weeklyDigestSource ?? ""
        dailyDigestSource = f.dailyDigestSource ?? ""
        // 缺失/空数组(旧配置文件没这个字段,或者曾经被清空过)都按"全部启用"处理,跟
        // collector 侧 resolveLyricsSources 的兜底规则一致。
        let decodedSources = (f.lyricsSources ?? []).compactMap(LyricsSource.init(rawValue:))
        lyricsSources = decodedSources.isEmpty ? Set(LyricsSource.allCases) : Set(decodedSources)
        lyricsSourceMode = f.lyricsSourceMode.flatMap(LyricsSourceMode.init(rawValue:)) ?? .smart
        // 必须是全部 4 个源的完整排列——数量对不上(文件被手动改坏/缺字段)就整体
        // 退回默认顺序,不做"缺的补在末尾"这种部分修复,避免搞出一份既不是默认顺序、
        // 也不是用户真实排过的四不像顺序。
        let decodedOrder = (f.lyricsSourceOrder ?? []).compactMap(LyricsSource.init(rawValue:))
        lyricsSourceOrder = decodedOrder.count == LyricsSource.allCases.count ? decodedOrder : LyricsSource.allCases
        lyricsDir = f.lyricsDir ?? ""
        lyricsTranslationLanguage = f.lyricsTranslationLanguage.flatMap(MusixmatchTranslationLanguage.init(rawValue:)) ?? .auto
        launchLyrimuseOnMusicOpen = f.launchLyrimuseOnMusicOpen ?? true
        savedSnapshot = currentSnapshot
    }

    // 只写盘,不重启——"推送账号"tab 的底部保存栏要把这个和 ConfigStore.persistFile()
    // 一起调用后,只统一重启一次 collector。
    public func persistFile() throws {
        let data = try JSONEncoder().encode(currentSnapshot)
        var payload = data
        // 把这个版本不认识的键合并回去,别让它们随这次写盘消失(见 unknownFileKeys)。
        // 合并方向是"已知字段覆盖未知同名键"——本次编码出来的才是用户刚设置的值。
        if !unknownFileKeys.isEmpty,
           var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in unknownFileKeys where obj[key] == nil {
                obj[key] = value
            }
            if let merged = try? JSONSerialization.data(
                withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]
            ) {
                payload = merged
            }
        }
        try payload.write(to: Self.featuresURL, options: .atomic)
    }

    public func commitSnapshot() {
        savedSnapshot = currentSnapshot
    }

    // 去抖用的状态——2026-08-02 实测排查坐实:"歌词"/"账号连接"tab 里每个开关各自独立
    // 包一层 Task { await features.save() },用户连续快速切换好几个开关时会并发派生出
    // 对应数量的独立调用,每一次都完整走一遍 persistFile()+重启 collector,而
    // CollectorControl.restartAndWaitAsync() 走 launchctl kickstart -k(两次重启间隔
    // 太近时会被 launchd 节流到约 10 秒才返回),连续多次触发会让"正在播放"推送反复
    // 出现不必要的中断/延迟。改成:每次调用仍然立刻 persistFile()(廉价、无副作用,
    // 不去抖),但重启动作延后一小段时间——这段时间内如果又有新的 save() 调用进来,取消
    // 上一次还没触发的延时、重新计时,只有连续调用真正停下来之后才会触发唯一一次重启;
    // 所有在等待期间调用过 save() 的地方,都会在这唯一一次重启真正完成后一起收到同一份
    // 结果,不需要各自等到自己那次触发的重启(那次可能已经被取消)。
    private var pendingRestartTask: Task<Void, Never>?
    private var pendingSaveContinuations: [CheckedContinuation<Bool, Never>] = []
    private static let restartDebounceNanoseconds: UInt64 = 500_000_000 // 0.5s

    // 独立保存入口(持久化+重启+提交快照一步到位)——给本文件里每一个即时保存的开关用。
    @discardableResult
    public func save() async -> Bool {
        do {
            try persistFile()
        } catch {
            lastError = String(format: L10n.t("写入功能开关文件失败: %@"), error.localizedDescription)
            logger.error("write failed: \(String(describing: error), privacy: .public)")
            return false
        }
        return await withCheckedContinuation { continuation in
            pendingSaveContinuations.append(continuation)
            pendingRestartTask?.cancel()
            pendingRestartTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.restartDebounceNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.performDebouncedRestart()
            }
        }
    }

    private func performDebouncedRestart() async {
        let continuations = pendingSaveContinuations
        pendingSaveContinuations = []
        pendingRestartTask = nil
        let success: Bool
        if await CollectorControl.restartAndWaitAsync() {
            lastError = nil
            commitSnapshot()
            success = true
        } else {
            lastError = L10n.t("后台采集服务重启失败")
            success = false
        }
        for continuation in continuations {
            continuation.resume(returning: success)
        }
    }
}
