import Foundation
import os
import SwiftUI

private let logger = Logger(subsystem: "com.chenyuhao.lyrimuse", category: "feature-settings")

// 四个歌词源——rawValue 必须跟 collector/features.go 的 lyricSourceXxx 常量逐字对应,
// 这是两侧通过共享 json 文件交换的字符串。displayName/color 直接委托给
// LyricsManagerView.swift 已有的 sourceDisplayName/sourceColor(那两个函数今天也在给
// "歌词管理"窗口的来源筛选/列表用),不重复维护第二份名字/颜色映射。
public enum LyricsSource: String, CaseIterable, Identifiable, Codable, Hashable {
    case netease, qq, kugou, lrclib
    public var id: Self { self }
    public var displayName: String { sourceDisplayName(rawValue) }
    public var color: Color { sourceColor(rawValue) }
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
// 这里存的是 Lyrimuse 这台机器上用户明确设置过的值。
struct FeatureFlagsFile: Codable, Equatable {
    var lyrics: Bool?
    var albumPrefetch: Bool?
    var stateRelay: Bool?
    var lastfmBridge: Bool?
    var lastfmMirrorScrobble: Bool?
    var weeklyDigest: Bool?
    var topArtistsDigest: Bool?
    var barkAlerts: Bool?
    // 以下 5 个跟 collector/features.go 新增的 WebShowXxx 字段逐一对应——控制公开网页
    // 上展示哪些模块,跟 collector 侧采集/处理行为无关,纯前端展示开关。
    var webShowHistory: Bool?
    var webShowComments: Bool?
    var webShowReactions: Bool?
    var webShowVisitorCount: Bool?
    var webShowTopArtists: Bool?
    var lyricsSources: [String]?
    var lyricsSourceMode: String?
    var lyricsSourceOrder: [String]?
    var lyricsDir: String?

    enum CodingKeys: String, CodingKey {
        case lyrics
        case albumPrefetch = "album_prefetch"
        case stateRelay = "state_relay"
        case lastfmBridge = "lastfm_bridge"
        case lastfmMirrorScrobble = "lastfm_mirror_scrobble"
        case weeklyDigest = "weekly_digest"
        case topArtistsDigest = "top_artists_digest"
        case barkAlerts = "bark_alerts"
        case webShowHistory = "web_show_history"
        case webShowComments = "web_show_comments"
        case webShowReactions = "web_show_reactions"
        case webShowVisitorCount = "web_show_visitor_count"
        case webShowTopArtists = "web_show_top_artists"
        case lyricsSources = "lyrics_sources"
        case lyricsSourceMode = "lyrics_source_mode"
        case lyricsSourceOrder = "lyrics_source_order"
        case lyricsDir = "lyrics_dir"
    }
}

// "歌词"tab 的纯行为开关(lyrics/albumPrefetch 等)和"账号连接"tab 里各张
// 账号卡片的开关(stateRelay/lastfmBridge/lastfmMirrorScrobble/weeklyDigest/
// topArtistsDigest/barkAlerts/webShowXxx)共用同一份数据层——读写
// ~/.config/applemusic-nowplaying/applemusic-nowplaying-features.json,跟
// collector/features.go 是同一份共享文件的两侧独立实现。
//
// 这个 store 里的每一个开关都是"改了立刻保存"——Binding 的 set 里包一层
// `Task { await features.save() }`,持久化+重启挪到后台执行,但从用户视角"点开关
// 立刻生效"这个体验不变(不需要等,也没有额外的"保存中"提示)。"账号连接"tab 底部那条
// 批量保存栏(isDirty/saveBar)管的是 ConfigStore 的文本/密钥字段,跟这个 store 的开关
// 无关,不要混为一谈。
@MainActor
public final class FeatureSettingsStore: ObservableObject {
    public static let shared = FeatureSettingsStore()

    @Published public var lyrics = true
    @Published public var albumPrefetch = true
    // 2026-07-18:这 6 个都要连一个外部账号才有意义,改成默认关闭——用户反馈"非必需的
    // 都设置为默认不开启"。collector/features.go 的 boolOr 默认值要跟着一起改,否则
    // 全新安装时 Swift 这边显示关、Go 那边却按"缺字段=开启"实际执行,两边会对不上。
    @Published public var stateRelay = false
    @Published public var lastfmBridge = false
    @Published public var lastfmMirrorScrobble = false
    @Published public var weeklyDigest = false
    @Published public var topArtistsDigest = false
    @Published public var barkAlerts = false
    // 跟 collector/features.go 新增的 WebShowXxx 字段对应,控制公开网页展示哪些模块
    // (不是 collector 侧行为开关),默认全部开启,跟本文件其余开关的 fail-open 约定一致。
    @Published public var webShowHistory = true
    @Published public var webShowComments = true
    @Published public var webShowReactions = true
    @Published public var webShowVisitorCount = true
    @Published public var webShowTopArtists = true
    @Published public var lyricsSources: Set<LyricsSource> = Set(LyricsSource.allCases)
    @Published public var lyricsSourceMode: LyricsSourceMode = .smart
    // 始终是全部 4 个源的一个排列(不是"只放启用的那几个")——启用/禁用状态单独由
    // lyricsSources 记录,顺序调整只在这个数组内部交换位置,两者互不干扰,不需要"禁用
    // 一个源时把它从顺序表里摘出来/重新插回去"这种同步逻辑。
    @Published public var lyricsSourceOrder: [LyricsSource] = LyricsSource.allCases
    // 空字符串 = 用默认位置(~/.config/applemusic-nowplaying/lyrics)。用 effectiveLyricsDir
    // 取实际生效的路径,不要直接读这个属性去拼路径。
    @Published public var lyricsDir = ""

    @Published public private(set) var lastError: String?

    private static let featuresURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/applemusic-nowplaying/applemusic-nowplaying-features.json")

    private var savedSnapshot = FeatureFlagsFile()
    private var currentSnapshot: FeatureFlagsFile {
        FeatureFlagsFile(
            lyrics: lyrics,
            albumPrefetch: albumPrefetch, stateRelay: stateRelay, lastfmBridge: lastfmBridge,
            lastfmMirrorScrobble: lastfmMirrorScrobble, weeklyDigest: weeklyDigest,
            topArtistsDigest: topArtistsDigest, barkAlerts: barkAlerts,
            webShowHistory: webShowHistory, webShowComments: webShowComments,
            webShowReactions: webShowReactions, webShowVisitorCount: webShowVisitorCount,
            webShowTopArtists: webShowTopArtists,
            lyricsSources: lyricsSources.map(\.rawValue).sorted(),
            lyricsSourceMode: lyricsSourceMode.rawValue,
            lyricsSourceOrder: lyricsSourceOrder.map(\.rawValue),
            lyricsDir: lyricsDir.isEmpty ? nil : lyricsDir
        )
    }

    // 供 EnrichCacheStore("歌词管理"窗口的文件读写)和 Settings 里的"打开歌词文件夹"
    // 按钮共用——两边都必须认同一个文件夹,不能各自兜底出两份不一致的默认路径。
    public var effectiveLyricsDir: URL {
        if !lyricsDir.isEmpty {
            return URL(fileURLWithPath: lyricsDir)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/applemusic-nowplaying/lyrics")
    }
    public var isDirty: Bool { currentSnapshot != savedSnapshot }

    private init() {
        load()
    }

    public func load() {
        guard let data = try? Data(contentsOf: Self.featuresURL),
              let f = try? JSONDecoder().decode(FeatureFlagsFile.self, from: data) else {
            // 文件不存在/解析失败——维持属性的默认值,跟 collector 侧 loadFeatureFlags
            // 的默认值约定完全一致(核心行为开关 fail-open=true;需要外部账号的 6 个
            // 2026-07-18 起改成 fail-closed=false，见上面属性声明处的改动说明)。
            savedSnapshot = currentSnapshot
            return
        }
        lyrics = f.lyrics ?? true
        albumPrefetch = f.albumPrefetch ?? true
        stateRelay = f.stateRelay ?? false
        lastfmBridge = f.lastfmBridge ?? false
        lastfmMirrorScrobble = f.lastfmMirrorScrobble ?? false
        weeklyDigest = f.weeklyDigest ?? false
        topArtistsDigest = f.topArtistsDigest ?? false
        barkAlerts = f.barkAlerts ?? false
        webShowHistory = f.webShowHistory ?? true
        webShowComments = f.webShowComments ?? true
        webShowReactions = f.webShowReactions ?? true
        webShowVisitorCount = f.webShowVisitorCount ?? true
        webShowTopArtists = f.webShowTopArtists ?? true
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
        savedSnapshot = currentSnapshot
    }

    // 只写盘,不重启——"推送账号"tab 的底部保存栏要把这个和 ConfigStore.persistFile()
    // 一起调用后,只统一重启一次 collector。
    public func persistFile() throws {
        let data = try JSONEncoder().encode(currentSnapshot)
        try data.write(to: Self.featuresURL, options: .atomic)
    }

    public func commitSnapshot() {
        savedSnapshot = currentSnapshot
    }

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
        if await CollectorControl.restartAndWaitAsync() {
            lastError = nil
            commitSnapshot()
            return true
        } else {
            lastError = L10n.t("重启 collector 失败")
            return false
        }
    }
}
