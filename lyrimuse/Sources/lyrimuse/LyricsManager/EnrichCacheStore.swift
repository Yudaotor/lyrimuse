import Foundation
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lyrics-manager")

// 歌词管理窗口的数据层。跟 EnrichCacheReader(单条只读查询)不同,这里要读写整个缓存
// 文件——collector(Go)是这个文件的唯一真源,自己在内存里维护整个 map,每次存盘都是
// "把整个内存 map 序列化覆盖写"(collector/enrich.go 的 saveEnrichCache()),不是增量
// 合并。所以这里每次改完必须做两件事:①先把改动落盘;②立刻踢一脚重启 collector 让它
// 从磁盘重新加载——不这么做的话,只要用户还在听歌,collector 随时可能因为解析别的曲目
// 而触发一次自己的存盘,用内存里那份"没看到这次改动"的旧状态整个覆盖回磁盘,悄悄撤销
// 刚做的修改。代价是每次保存/删除都会让 collector 短暂重启一次,"现在播放"推送有个
// 小间隙——个人工具偶尔手动操作这个代价可以接受,换来的是不用给 collector 另开一个
// 常驻 HTTP/IPC 接口。
//
// 用 JSONSerialization 而不是 Codable 读写整个文件:enrichEntry(collector/enrich.go)
// 目前有十几个字段,如果 Swift 侧用一个只声明"我关心的几个字段"的 Codable 结构体去
// 解码整个文件、改完再编码回去,**每一条**(不只是被编辑的那条)都会被这个窄结构体
// 悄悄丢掉它没声明的字段——这是会破坏其它上百条数据的严重 bug,而且 Go 那边字段以后
// 还可能再加。改用 [String: [String: Any]] 原始字典,只对被编辑/删除的那一条 key 做
// 字典级别的增删改,其它条目、以及被编辑条目里没碰过的字段,原样保留、逐字节不变。
//
// 歌词部分(lyrics/lyrics_tr/lyrics_roma/lyrics_yrc/lyrics_source/manual_lyrics 这 6 个
// 字段)另有 ~/.config/lyrimuse/lyrics/ 下的纯文本文件族作为权威源
// (collector 启动时会读这个文件夹、覆盖对应字段,见 collector/lyricsimport.go)——
// saveEdit/removeWordTiming/delete 因此在 raw[key] 字典操作之外,还调用
// writeLyricsFiles 同步写/删对应文件,两边由同一次用户操作一起改,靠"改完立刻重启
// collector"这个机制保持最终一致。
@MainActor
public final class EnrichCacheStore: ObservableObject {
    public static let shared = EnrichCacheStore()

    public struct Summary: Identifiable {
        public var id: String { key }
        public let key: String
        public let artist: String
        public let title: String
        public let album: String
        public let lyricsSource: String
        public let hasWordTiming: Bool
        public let isManual: Bool
        public let hasLyrics: Bool
    }

    @Published public private(set) var summaries: [Summary] = []
    @Published public private(set) var lastError: String?
    // 缓存 JSON 文件本身 + lyrics/ 权威源文件夹里所有文件的总大小——"歌词管理"工具栏
    // 展示用,让用户知道这个"解析一次永久保留"的缓存实际占了多少磁盘空间。跟 reload()
    // 同一次磁盘扫描顺带算出来,不为这一个数字单独再打开一轮文件 I/O。
    @Published public private(set) var totalSizeBytes: Int64 = 0

    private static let cacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lyrimuse/lyrimuse-enrich-cache.json")
    // 读 FeatureSettingsStore 的计算属性,而不是编译期定死的 static let——用户可在
    // "歌词"设置分类里自定义文件夹位置,这里必须跟 collector 那边(main.go 读
    // features.LyricsDir)认的是同一个位置,否则存/删歌词文件的目录跟 collector 实际
    // 读取的目录对不上。
    private static var lyricsDir: URL { FeatureSettingsStore.shared.effectiveLyricsDir }

    private var raw: [String: [String: Any]] = [:]

    private init() {}

    // 缓存文件设计上永久不清理("解析一次永久保留"),攒到几百条、几 MB 后
    // JSONSerialization 解析整份文件要 30ms 以上——若直接在 MainActor 上同步做,开窗/点
    // "刷新"都会卡一下,且随缓存变大越来越慢。这里把读文件+解析挪到后台线程,只在算完
    // 之后回 MainActor 赋值。box 用 @unchecked Sendable 包一层,是因为 JSONSerialization
    // 解出来的 [String: [String: Any]] 含 Any,编译器没法证明它是 Sendable,但这里的跨
    // 线程访问本来就有明确的先后顺序(detached task 算完、await 完了才读 box),不是真的
    // 并发写。
    public func reload() async {
        final class ResultBox: @unchecked Sendable {
            var obj: [String: [String: Any]]?
            var errorMessage: String?
            var sizeBytes: Int64 = 0
        }
        let box = ResultBox()
        let cacheURL = Self.cacheURL
        let lyricsDir = Self.lyricsDir
        await Task.detached(priority: .userInitiated) {
            box.sizeBytes = Self.directorySizeBytes(lyricsDir) + Self.fileSizeBytes(cacheURL)
            guard let data = try? Data(contentsOf: cacheURL) else {
                box.errorMessage = L10n.t("读取本地记录文件失败")
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
                box.errorMessage = L10n.t("解析本地记录文件失败")
                return
            }
            box.obj = obj
        }.value
        totalSizeBytes = box.sizeBytes
        if let obj = box.obj {
            raw = obj
            lastError = nil
        } else {
            raw = [:]
            summaries = []
            lastError = box.errorMessage ?? L10n.t("读取本地记录文件失败")
        }
        rebuildSummaries()
    }

    // nonisolated——从 reload() 里的 Task.detached 闭包(非 MainActor 上下文)调用,
    // 这两个纯函数只碰 FileManager/URL,不touch 任何 actor 隔离状态,标 nonisolated
    // 避免编译器在严格并发检查下要求这里额外 await。
    private nonisolated static func fileSizeBytes(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    private nonisolated static func directorySizeBytes(_ dir: URL) -> Int64 {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return urls.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }

    // key 的拼法是 collector 那边的 "歌手|歌名|专辑"(见 collector/enrich.go:93)。
    // 只按前两个 "|" 分,专辑名里偶尔出现的 "|" 不会把切分打乱(艺人/歌名本身含 "|"
    // 这种更罕见的情况不额外处理)。
    private static func splitKey(_ key: String) -> (artist: String, title: String, album: String)? {
        let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    private func rebuildSummaries() {
        summaries = raw.keys.compactMap { key -> Summary? in
            guard let parts = Self.splitKey(key) else { return nil }
            let entry = raw[key] ?? [:]
            let lyrics = entry["lyrics"] as? String ?? ""
            return Summary(
                key: key,
                artist: parts.artist,
                title: parts.title,
                album: parts.album,
                lyricsSource: entry["lyrics_source"] as? String ?? "",
                hasWordTiming: !(entry["lyrics_yrc"] as? String ?? "").isEmpty,
                isManual: entry["manual_lyrics"] as? Bool ?? false,
                hasLyrics: !lyrics.isEmpty
            )
        // 专辑归并键跟展示值分开:同一张专辑偶尔因歌词源候选写法大小写不一致而在
        // s.album 里长得不一样,排序按小写归并键走,才能让同一张专辑的曲目真正排在
        // 一起,而不是被大小写拆成两组。歌手同理用 primaryArtist(跟艺人筛选下拉复用
        // 同一个函数)归并——"Scream"这类跟其他人合唱的曲目,artist 字段整段写的是
        // "Michael Jackson & JANET JACKSON",原始字符串排序会单独归成一组、跟同一张
        // 专辑里其余单独署名"Michael Jackson"的曲目拆开,不符合"同专辑排一起"的预期。
        }.sorted {
            (primaryArtist($0.artist), $0.album.lowercased(), $0.title)
                < (primaryArtist($1.artist), $1.album.lowercased(), $1.title)
        }
    }

    // 返回值含 yrc:「歌词管理」的单曲歌词时间轴偏移输入框需要跟 LocalPlaybackSource
    // 用同一份内容(lyrics+lyricsYRC)算出来的指纹去查/存 LyricsOffsetStore,不然算出来
    // 的 key 对不上真正播放时用的那个 key。
    public func detail(for key: String) -> (lyrics: String, tr: String, roma: String, yrc: String) {
        let entry = raw[key] ?? [:]
        return (
            entry["lyrics"] as? String ?? "",
            entry["lyrics_tr"] as? String ?? "",
            entry["lyrics_roma"] as? String ?? "",
            entry["lyrics_yrc"] as? String ?? ""
        )
    }

    // yrc 默认 nil:纯手改文本框的普通保存路径不传它,完全不碰 lyrics_yrc 字段——这是
    // 有意的("歌词管理"从不提供逐字时间轴的自由文本编辑,格式是嵌套时间戳,手改错了代价
    // 大,见 removeWordTiming)。只有"联网搜索候选歌词"整条采纳某个候选时才会传非 nil:
    // 采纳意味着连同逐字时间轴一起换成这个候选的版本(有就设、没有就清空)——否则旧
    // lyrics_yrc 会继续绑定已经被替换掉的旧文本,播放时逐字时间戳和新歌词对不上。
    //
    // source 同理默认 nil:采纳候选时显式设成 candidate.source(见 LyricsManagerView 的
    // onApply),准确反映刚采纳的这份内容真实来自哪个平台;纯手改文本框(source 留 nil)
    // 则清空这个字段——手改之后已经不再是任何平台的原文,继续挂着旧的平台徽章比"无
    // 来源"更容易误导人,跟"人工修正"徽章(isManual)搭配显示才诚实。
    public func saveEdit(key: String, lyrics: String, tr: String, roma: String, yrc: String? = nil, source: String? = nil) async {
        var entry = raw[key] ?? [:]
        entry["lyrics"] = lyrics
        entry["lyrics_tr"] = tr
        entry["lyrics_roma"] = roma
        entry["manual_lyrics"] = true
        if let yrc {
            if yrc.isEmpty {
                entry.removeValue(forKey: "lyrics_yrc")
            } else {
                entry["lyrics_yrc"] = yrc
            }
        }
        if let source, !source.isEmpty {
            entry["lyrics_source"] = source
        } else {
            entry.removeValue(forKey: "lyrics_source")
        }
        raw[key] = entry
        writeLyricsFiles(
            key: key, lyrics: lyrics, tr: tr, roma: roma,
            yrc: entry["lyrics_yrc"] as? String ?? "",
            source: entry["lyrics_source"] as? String ?? "",
            manual: true
        )
        await persistAndRestart()
        rebuildSummaries()
    }

    // 只清掉逐字时间轴,保留整行歌词——用户发现某首歌的逐字对不上、想退回整行显示,
    // 不用整条删掉重新解析(重新解析很可能又抓到同一份不准的 yrc)。
    public func removeWordTiming(key: String) async {
        var entry = raw[key] ?? [:]
        entry.removeValue(forKey: "lyrics_yrc")
        raw[key] = entry
        // 只删 .yrc 文件,其它变体文件不动——跟上面 JSON 侧"只清掉这一个字段"的语义对应。
        try? FileManager.default.removeItem(at: Self.lyricsDir.appendingPathComponent(Self.sanitizeLyricsFilename(key) + ".yrc"))
        await persistAndRestart()
        rebuildSummaries()
    }

    // 删缓存条目的同时一并删掉对应的已导出文件——「歌词管理」里点删除,"删除"在两边
    // 都是真删除,不留一份用户自己都不知道还在的归档文件。
    public func delete(key: String) async {
        raw.removeValue(forKey: key)
        await persistAndRestart()
        rebuildSummaries()
        deleteExportedLyricsFile(forKey: key)
    }

    // "缓存占用查看 + 一键清空"里的清空动作——真删除,不是软标记:清空 JSON 侧的 raw
    // 字典、删掉 lyrics/ 权威源文件夹下的每一个文件(包括手动编辑/联网搜索采纳过的
    // 内容,这份缓存设计上没有"哪些是临时的、哪些是用户产出"的区分,清空就是全清)。
    // destructive 程度需要在 UI 侧用强提示词说清楚,这里只负责真正执行。
    public func clearAll() async {
        raw = [:]
        if let urls = try? FileManager.default.contentsOfDirectory(at: Self.lyricsDir, includingPropertiesForKeys: nil) {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
        await persistAndRestart()
        rebuildSummaries()
        totalSizeBytes = 0
    }

    // 跟 collector/lyricsexport.go 的 sanitizeLyricsFilename 逐字对应的 Swift 版本——
    // 两边各自维护而不是让 Swift 调 Go 子进程,是因为这纯粹是确定性的字符替换("|"换成
    // " - "+转义文件系统不安全字符),没有会随时间演进的业务判断,不属于"两份实现容易
    // 走样"必须收敛成一份的那类逻辑(跟 search-lyrics 复用 scoredLyricCandidates 的
    // 场景不同,那边是真的检索/打分逻辑)。
    private static func sanitizeLyricsFilename(_ key: String) -> String {
        var name = key.replacingOccurrences(of: "|", with: " - ")
        for c in ["/", ":", "*", "?", "\"", "<", ">", "\\"] {
            name = name.replacingOccurrences(of: c, with: "_")
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 找不到文件(比如这条从来没有译文/罗马音/逐字时间轴)是正常情况,静默忽略——这只是
    // 清理可能存在的归档副本,不是这次删除操作的主体,不值得为"文件本来就不存在"这种
    // 预期内的情况去污染 lastError(那个留给 persistAndRestart 里真正的主体操作失败用)。
    // lyricsFileSuffixes 全部 4 个后缀都试一遍,跟 writeLyricsFiles 对称——"删除"要
    // 清掉整个歌词文件族,不只是纯歌词那一份。
    private func deleteExportedLyricsFile(forKey key: String) {
        let base = Self.sanitizeLyricsFilename(key)
        for suffix in Self.lyricsFileSuffixes {
            try? FileManager.default.removeItem(at: Self.lyricsDir.appendingPathComponent(base + suffix))
        }
    }

    // lyricsFileSuffixes 跟 collector/lyricsexport.go 的同名变量逐一对应。
    private static let lyricsFileSuffixes = [".lrc", ".tr.lrc", ".roma.lrc", ".yrc"]

    // writeLyricsFiles 把 saveEdit 对 raw[key] 做的改动,同步写成 lyrics/ 文件夹下对应的
    // 文件,跟 collector/lyricsexport.go 的 exportLyricsFiles/lyricsFileHeader 是同一份
    // 头部格式的两处独立实现(理由同 sanitizeLyricsFilename——纯粹是确定性的字符串拼接,
    // 不属于必须收敛成一份的逻辑)。每个变体单独判断:有内容就写,没内容就删除对应
    // 文件,跟 Go 那边"该有就写、不该有就删"对应。这里不处理 Go 那边"检测大小写文件名
    // 碰撞、加哈希后缀消歧"那一步——每次调用后紧跟的 persistAndRestart() 会重启
    // collector,它启动时会重新跑一遍全量 exportLyricsFiles(),那一步本来就会处理好
    // 任何残留的文件名碰撞,不需要在 Swift 这边重复实现一遍。
    private func writeLyricsFiles(key: String, lyrics: String, tr: String, roma: String, yrc: String, source: String, manual: Bool) {
        guard let parts = Self.splitKey(key) else { return }
        let base = Self.sanitizeLyricsFilename(key)
        var header = "[ar:\(parts.artist)]\n[ti:\(parts.title)]\n[al:\(parts.album)]\n"
        if !source.isEmpty { header += "[source:\(source)]\n" }
        if manual { header += "[manual:1]\n" }
        header += "\n"

        let variants: [(suffix: String, content: String)] = [
            (".lrc", lyrics), (".tr.lrc", tr), (".roma.lrc", roma), (".yrc", yrc),
        ]
        try? FileManager.default.createDirectory(at: Self.lyricsDir, withIntermediateDirectories: true)
        for v in variants {
            let url = Self.lyricsDir.appendingPathComponent(base + v.suffix)
            if v.content.isEmpty {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            try? (header + v.content).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // 必须用 restartAndWaitAsync()、不能直接调同步版 restartAndWait():launchd 给这个
    // LaunchAgent 配了 `minimum runtime = 10`,两次重启间隔太近时 kickstart 会原地等满
    // 10 秒才返回,如果在 MainActor 上同步等待,期间整个 app(窗口、菜单栏)会彻底冻住
    // 不响应。
    private func persistAndRestart() async {
        guard JSONSerialization.isValidJSONObject(raw) else {
            lastError = L10n.t("内部数据不是合法 JSON,已放弃保存")
            logger.error("raw dict is not valid JSON, aborting save")
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: raw)
            try data.write(to: Self.cacheURL, options: .atomic)
        } catch {
            lastError = String(format: L10n.t("写入本地记录文件失败: %@"), error.localizedDescription)
            logger.error("write failed: \(String(describing: error), privacy: .public)")
            return
        }
        if await !CollectorControl.restartAndWaitAsync() {
            lastError = L10n.t("重启 collector 失败")
        }
        // 磁盘已经是最新内容——不管当前悬浮窗显示的是不是被改的这首歌,让播放数据源
        // 强制重新读一次都无害(不是这首歌的话 key 对不上,syncEngine 内容不变),换来
        // 的是"改完歌词、悬浮窗还停在旧版本"这个问题被修掉,不用等下一次换歌才生效。
        PlaybackCoordinator.shared.refreshLyricsForCurrentTrack()
    }
}
