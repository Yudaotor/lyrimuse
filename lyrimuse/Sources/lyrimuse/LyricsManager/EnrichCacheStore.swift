import Foundation
import LyrimuseCore
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
        // collector 解析出的"官方歌手名"(网易云/QQ/MusicBrainz 核实过),没有则为空。
        //
        // 为什么列表要用它:同一位歌手在不同曲目上可能被播放器报成完全不同的写法 ——
        // 2026-08-07 用户实测,一张专辑里一半曲目报 "Leah Dou"、另一半报"窦靖童"
        // (连专辑名都是繁简两版:"春遊"/"春游")。artistDisplayNames 那套归并只折繁简和
        // 大小写,救不了跨文字的别名;canonical_artist 正是为此存在的,只是一直没接到这个
        // 界面上来 —— 值早就算好、存进缓存了,列表却仍在显示原始写法。
        //
        // 合唱曲目上它是空的(collector 只在单一歌手时才给值),所以消费方要回退到 artist。
        public let canonicalArtist: String
        // 解析这条时的曲目真实时长(秒),collector 存进缓存的。手动搜索要用它 ——
        // 打分里时长匹配那一档权重很重,传 0 的话弹窗里的排名跟当初真正做决定用的那组
        // 分数不是一回事(见 LyricsSearchSheet 的用法)。老条目没有这个字段,为 0。
        public let durationSecs: Double
        public let title: String
        public let album: String
        public let lyricsSource: String
        public let hasWordTiming: Bool
        public let isManual: Bool
        // 译文是机翻补的(见 collector 的 translate.go)还是歌词源自带的社区翻译。
        // 空 = 社区翻译(老条目没有这个字段,读成空正是事实)。
        public let lyricsTrSource: String
        public let hasTranslation: Bool
        // 有没有罗马音标注(lyrics_roma)。值一直存在缓存里,只是列表一直没显示 ——
        // 详情页有这一栏、"搜索候选歌词"弹窗也有对应徽章,唯独列表看不出来。
        public let hasRomanization: Bool
        public let hasLyrics: Bool
        // collector 固化下来的解析决策记录(候选表+得分明细),见 collector/decision.go。
        // 老条目没有这个字段,为 nil —— 详情页的入口按钮跟着不显示。
        // internal(无 public):类型里嵌着 internal 的 LyricsSearchService.ScoreTerm,
        // 而整个 App 本来就是单 target,这里的 public 只是历史惯性。
        let decision: LyricsResolutionDecision?
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
    // 上一次跟磁盘同步时盘上存在的 key 集合。2026-08-14 之前 persist() 用它区分"用户删掉的"
    // 和 "collector 在我们背后新写的";现在这件事由 locallyEditedKeys/locallyDeletedKeys
    // 直接表达(那是**意图**,这只是**快照**),它退化成一份纯记录,保留是因为 reload/persist
    // 两处都在维护它、拿掉要动的地方比留着多。
    private var knownKeys: Set<String> = []
    // 自上次落盘以来,**用户在这个窗口里真正动过**的 key。
    //
    // persist() 靠它把"整份覆盖"改成"读-改-写":写盘前重新读一次磁盘,只把这两个集合里的
    // key 盖上去,其余一律以盘上为准。没有它的话,开窗那一刻的内存快照会把窗口开着期间
    // collector 新写进去的任何东西(机翻译文、逐字时间轴、封面)静默回滚掉。
    private var locallyEditedKeys: Set<String> = []
    private var locallyDeletedKeys: Set<String> = []
    // persist() 从盘上并回了本次快照没有的 key —— 调用方据此决定要不要重刷列表。
    private var lastPersistPulledInNewKeys = false

    private init() {}

    /// 记下"这个 key 的内容是用户在窗口里改出来的",persist() 据此决定它盖过盘上的版本。
    /// 同时撤销可能存在的删除意图 —— 编辑一个刚被删掉的 key 意味着它又回来了。
    private func markLocallyEdited(_ key: String) {
        locallyEditedKeys.insert(key)
        locallyDeletedKeys.remove(key)
    }

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
            knownKeys = Set(obj.keys)
            // 这两个集合描述的是"相对上一份快照做了什么改动";快照整个换掉之后它们就失去
            // 参照,留着会让下一次 persist 拿旧意图去盖新内容。所有改动路径都是"改完立刻
            // persist",正常情况下它们此刻本来就是空的 —— 这里只是把不变量写死。
            locallyEditedKeys.removeAll()
            locallyDeletedKeys.removeAll()
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
    /// 把缓存条目里的 lyrics_decision 子字典解回结构体。整个文件是 JSONSerialization
    /// 读进来的字典,这一个字段单独走一遍 JSONDecoder —— 结构嵌套了两层(候选表里还有
    /// 得分明细),手工逐键取值会写出一屏 as? 阶梯。解不出来(老条目没有/以后格式变了)
    /// 一律 nil,不影响其余字段。
    private static func decodeDecision(_ value: Any?) -> LyricsResolutionDecision? {
        guard let dict = value as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(LyricsResolutionDecision.self, from: data)
    }

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
                canonicalArtist: entry["canonical_artist"] as? String ?? "",
                durationSecs: entry["duration_secs"] as? Double ?? 0,
                title: parts.title,
                album: parts.album,
                lyricsSource: entry["lyrics_source"] as? String ?? "",
                hasWordTiming: !(entry["lyrics_yrc"] as? String ?? "").isEmpty,
                isManual: entry["manual_lyrics"] as? Bool ?? false,
                lyricsTrSource: entry["lyrics_tr_source"] as? String ?? "",
                hasTranslation: !((entry["lyrics_tr"] as? String ?? "").isEmpty),
                hasRomanization: !((entry["lyrics_roma"] as? String ?? "").isEmpty),
                hasLyrics: !lyrics.isEmpty,
                decision: Self.decodeDecision(entry["lyrics_decision"])
            )
        // 专辑归并键跟展示值分开:同一张专辑偶尔因歌词源候选写法大小写不一致而在
        // s.album 里长得不一样,排序按小写归并键走,才能让同一张专辑的曲目真正排在
        // 一起,而不是被大小写拆成两组。歌手同理用 primaryArtist(跟艺人筛选下拉复用
        // 同一个函数)归并——"Scream"这类跟其他人合唱的曲目,artist 字段整段写的是
        // "Michael Jackson & JANET JACKSON",原始字符串排序会单独归成一组、跟同一张
        // 专辑里其余单独署名"Michael Jackson"的曲目拆开,不符合"同专辑排一起"的预期。
        }.sorted { Self.sortKey($0) < Self.sortKey($1) }
    }

    // ⚠️ 排序键必须跟"列表上看到的那套分组"用**同一套归并规则**,否则会出现"显示层合并了、
    // 排序层还按原始写法把同一张专辑劈成两半"。2026-08-07 用户实测撞到:「春游」这张专辑
    // 一半曲目排在列表最上面、一半排在最下面 —— 播放器把它们分别报成 "Leah Dou" / "窦靖童"
    // (歌手)和 "春遊" / "春游"(专辑繁简),而这里的排序键当时用的是**原始** artist、专辑也
    // 只 lowercased() 没折简体,两组自然隔得很远。
    //
    // 三个分量分别对应:
    //   歌手 —— 先取 canonical(collector 核实过的官方名,同一个人的不同别名在这里收敛),
    //           再 primaryArtist 取合唱的第一位,最后折简体+小写;
    //   专辑 —— 折简体+小写(跟 albumDisplayNames 的归并键一致);
    //   歌名 —— 原样,同一张专辑内的次序不需要归一化。
    private static func sortKey(_ s: Summary) -> (String, String, String) {
        let artist = s.canonicalArtist.isEmpty ? s.artist : s.canonicalArtist
        return (
            toSimplified(primaryArtist(artist)).lowercased(),
            toSimplified(s.album).lowercased(),
            s.title
        )
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
        // 译文换了内容 → 描述译文的那两个字段(lyrics_tr_lang / lyrics_tr_source)不再
        // 描述它,必须一起清掉。跟 collector 侧 importLyricsFromFiles 是同一条规矩:
        // 别拿旧语言给新内容背书。
        //
        // 漏掉这一步的后果 2026-08-09 实测抓到过:在"搜索候选歌词"里采纳一条网易云候选
        // (译文固定是中文)之后,lyrics_tr_lang 还留着上一轮机翻写下的 "en",于是采集器那边
        // translationUsable 认定"这份译文对英文目标够用",机翻再也不会接手 —— 用户把译文
        // 语言选成英文,却永远只看到中文,而且徽章还把这份社区译文标成机翻。
        //
        // 清空而不是猜一个语言写进去:清空之后采集器会退回按正文判别语言(looksChinese),
        // 那比在这里猜可靠。
        // translation_ts / translation_retry_count 也要一起清:它们是采集器给机翻用的
        // 节流和重试计数(6 小时内不重试、连败 3 次放弃),记的是"上一份译文"那次尝试。
        // 留着的话,就算语言字段已经清对了,这条也要等节流到期才轮得到重翻——实测正是
        // 卡在这里:语言判定已经修好,但 translation_ts 还剩三个多小时才过期。
        let previousTr = raw[key]?["lyrics_tr"] as? String ?? ""
        if tr != previousTr {
            for stale in ["lyrics_tr_lang", "lyrics_tr_source",
                          "translation_ts", "translation_retry_count"] {
                entry.removeValue(forKey: stale)
            }
        }
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
        markLocallyEdited(key)
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
        markLocallyEdited(key)
        // 只删 .yrc 文件,其它变体文件不动——跟上面 JSON 侧"只清掉这一个字段"的语义对应。
        // 普通名和带消歧后缀两种形态都要删:这个 key 在碰撞组里时磁盘上只有后一种(理由见
        // EnrichCacheKeys.exportedFileNames 的注释),只删普通名的话残留的 .yrc 会在
        // collector 重启时被 importLyricsFromFiles 导回来,逐字时间轴自己长回去。
        for base in [EnrichCacheKeys.sanitizeFilename(key), EnrichCacheKeys.disambiguatedName(forKey: key)] {
            try? FileManager.default.removeItem(at: Self.lyricsDir.appendingPathComponent(base + ".yrc"))
        }
        await persistAndRestart()
        rebuildSummaries()
    }

    // 删缓存条目的同时一并删掉对应的已导出文件——「歌词管理」里点删除,"删除"在两边
    // 都是真删除,不留一份用户自己都不知道还在的归档文件。
    //
    // ⚠️ 删文件必须排在 persistAndRestart() 之前——2026-08-02 实测排查坐实:早先这里的
    // 顺序反了(先重启 collector、后删文件),跟本文件里 saveEdit/removeWordTiming/
    // clearAll 建立的"先落盘文件、再重启 collector"顺序正相反。collector
    // main() 每次启动都固定跑 loadEnrichCache → importLyricsFromFiles →
    // exportLyricsFiles;importLyricsFromFiles 只要在 lyrics/ 目录下还看到这个 key 对应
    // 的文件,就会把文件内容当"新条目"重新写回 enrichCache 并无条件存盘——也就是说,
    // 如果文件删除排在重启之后,collector 重启那一刻磁盘上这些文件必然还在(Swift 侧还
    // 没删),会在 collector 启动阶段就把刚删除的条目复活并写回磁盘,不需要等用户之后
    // 再听一首歌才触发。现在改成先删文件、让 collector 重启时看到的磁盘状态已经是
    // "没有这个 key"。
    //
    // 2026-08-05 实测排查坐实的卡顿修复:原来这里是 `await persistAndRestart()` 之后才
    // rebuildSummaries(),也就是列表要等 collector 重启完才更新。实测重启是唯一的大头——
    // JSON 校验+序列化 8.9MB+原子写盘合计只要 26ms,而 `launchctl kickstart` 在"距上次
    // 重启不久"时会原地等满 launchd 给这个 LaunchAgent 配的 `minimum runtime = 10`
    // (实测连续两次:第一次 0.02 秒、第二次 9.02 秒)。用户视角就是"点了删除,列表卡住
    // 十秒才把那一行去掉"。
    //
    // 改成:先删内存+删文件+刷列表(界面立刻响应),再落盘(26ms),重启改成不阻塞的后台
    // 排队。重启本身仍然必须做——collector 在内存里持有这份缓存,不让它重新读盘的话它
    // 会把删掉的条目按内存旧值重新写回磁盘、把删除操作复活。
    public func delete(key: String) async {
        await delete(keys: [key])
    }

    // 「歌词管理」多选后批量删除。**不是** N 次 delete(key:) 的循环:那样会做 N 次
    // rebuildSummaries()(852 条 compactMap + 带 primaryArtist 比较器的全量排序)和 N 次
    // persist()(整份 9.4MB JSON 校验+序列化+原子写,实测单次 26ms),全都在 MainActor 上
    // 同步跑——删 50 条就是 1 秒多、删几百条是十几秒的界面假死,正是这次要避免的东西。
    // 三个重活各做一次即可。
    //
    // 顺序跟单条版完全一致、不能动:先删文件 → 再刷列表 → 再落盘 → 最后才排队重启
    // collector。删文件必须排在重启之前,理由见上面那一大段注释(collector 启动时
    // importLyricsFromFiles 会从残留文件把条目复活)。
    public func delete(keys: Set<String>) async {
        // 只删真的还在缓存里的 key——选中集合里可能残留已失效的 key(筛选变了/点过刷新/
        // 别处删过),让它们混进来不会删错东西,但会让"删了 N 条"这个数字虚高。
        let victims = EnrichCacheKeys.deletionPlan(selected: keys, existing: Set(raw.keys))
        guard !victims.isEmpty else { return }
        var removed: [String: [String: Any]] = [:]
        removed.reserveCapacity(victims.count)
        for key in victims {
            if let entry = raw.removeValue(forKey: key) { removed[key] = entry }
            locallyDeletedKeys.insert(key)
            locallyEditedKeys.remove(key)
            deleteExportedLyricsFile(forKey: key)
        }
        rebuildSummaries()
        guard persist() else {
            // 写盘失败就把这一批全部放回去——不能让界面显示成"已删除"而磁盘上其实还在。
            // 已经删掉的导出文件不用管:collector 启动时会按缓存内容重新导出一遍。
            for (key, entry) in removed {
                raw[key] = entry
                locallyDeletedKeys.remove(key)
            }
            rebuildSummaries()
            return
        }
        // persist() 刚从盘上并回了窗口开着期间 collector 新写的条目 —— 列表得再刷一次才
        // 看得到它们。只在真有新增时才重刷:rebuildSummaries 是全量 compactMap + 排序,
        // 白跑一次在几百条规模上是肉眼可见的卡顿(见本函数上方那段注释)。
        if lastPersistPulledInNewKeys { rebuildSummaries() }
        scheduleCollectorRestart()
        refreshSizeBytes()
    }

    // "缓存占用查看 + 一键清空"里的清空动作——真删除,不是软标记:清空 JSON 侧的 raw
    // 字典、删掉 lyrics/ 权威源文件夹下的每一个文件(包括手动编辑/联网搜索采纳过的
    // 内容,这份缓存设计上没有"哪些是临时的、哪些是用户产出"的区分,清空就是全清)。
    // destructive 程度需要在 UI 侧用强提示词说清楚,这里只负责真正执行。
    public func clearAll() async {
        raw = [:]
        // 清空是用户明确要求的"全清",不能让 persist() 的读-改-写把刚清掉的东西从盘上并回来
        // ——「歌词管理」是可以一直开着的窗口,开窗之后 collector 每解析出一首新歌都会往盘上
        // 写一条,合并回来就成了"清空之后莫名剩下几条"。下面那次 persist 因此走整份替换。
        //
        // (2026-08-14 之前这里是"先把此刻盘上所有 key 都认领进 knownKeys,好让合并整段失效"
        // ——那是配合旧的"只并回没见过的 key"写的绕法,现在有了显式的 replacingEverything,
        // 那段绕法已经没有意义,一并去掉。)
        // ⚠️ 只删**歌词文件**,不能把这个目录里的东西一律删掉。
        //
        // 原来是 contentsOfDirectory 之后无差别 removeItem,而 lyrics/ 这个目录是**用户
        // 可以在设置里自己指定的**(设置 → 歌词 → 歌词文件夹 → 选择文件夹…)。一旦有人把它
        // 指到一个还放着别的东西的目录(甚至就是"文稿"这类现成目录),点一下「清空全部缓存」
        // 就会连带删光那个目录里所有无关文件——那已经不是清空本 App 的缓存了。即便在默认
        // 目录下,无差别删除也会顺手清掉用户自己丢进去的 .txt 备注、封面图之类。
        // 按后缀白名单过滤(跟导出用的是同一份 EnrichCacheKeys.lyricsFileSuffixes),
        // 认不出来的文件一律不碰。
        deleteAllLyricsFiles()
        rebuildSummaries()
        totalSizeBytes = 0
        // 整份替换:清空是用户明确的"全清",读-改-写会把盘上一切并回来,正好相反。
        guard persist(replacingEverything: true) else { return }

        // ⚠️ 必须**等重启完成再核一遍**,而且要肯再来一轮。
        //
        // 2026-08-14 用户实测:"刚清空了,但是又回来了"。原因是 collector 在我们清完之后、
        // 被杀掉之前那段窗口里还活着,而它内存里握着完整的一份缓存 —— enrich.go/translate.go
        // 里有七处会调 saveEnrichCache(),每解析完一首歌、每落一条译文都会把**整份内存缓存**
        // 写回磁盘,一次就把刚清空的文件填回去了;紧接着 collector 启动时的 exportLyricsFiles()
        // 又会照着复活的缓存把 .lrc 重新写出来。窗口还不短:launchctl kickstart 在"距上次
        // 重启不久"时会原地等满 launchd 给这个 LaunchAgent 配的 minimum runtime(实测量到过
        // 9.02 秒),而用户此刻多半正在听歌,解析随时在发生。
        //
        // 为什么再来一轮就能收敛:kickstart -k 杀掉的是**握着旧内存的那个进程**,新进程的
        // 内存 = 它启动那一刻磁盘上的内容。所以第二轮清空之后再重启,新进程读到的必然是空的,
        // 不存在第三个"还揣着旧数据"的进程。这里不是无脑重试,是有终止性的两轮。
        for attempt in 1...2 {
            _ = await CollectorControl.restartAndWaitAsync()
            PlaybackCoordinator.shared.refreshLyricsForCurrentTrack()
            if !cacheFileHasEntries() {
                return // 盘上确实是空的,清空成功
            }
            logger.notice("clearAll: cache came back after restart (attempt \(attempt, privacy: .public)), wiping again")
            raw = [:]
            knownKeys = []
            deleteAllLyricsFiles()
            guard persist(replacingEverything: true) else { return }
            rebuildSummaries()
            totalSizeBytes = 0
        }
        if cacheFileHasEntries() {
            // 两轮都没清干净就如实报错,别让界面显示成"已清空"而磁盘上还在。
            lastError = L10n.t("清空没有完全生效，请稍后再试一次")
            await reload()
        }
    }

    /// 磁盘上那份缓存文件里还有没有条目。用来核实"清空"是不是真的落地了 ——
    /// 不看内存里的 raw:内存说空不算数,collector 可能在我们背后把它写回去了。
    private func cacheFileHasEntries() -> Bool {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false // 文件不在/解析不了,都不算"还有条目"
        }
        return !obj.isEmpty
    }

    /// 删掉 lyrics/ 目录下的歌词文件。按后缀白名单过滤,理由见 clearAll 里那段注释
    /// (这个目录是用户可以自己指定的,无差别删除会波及无关文件)。
    private func deleteAllLyricsFiles() {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: Self.lyricsDir, includingPropertiesForKeys: nil) else {
            return
        }
        for url in urls where EnrichCacheKeys.lyricsFileSuffixes.contains(where: { url.lastPathComponent.hasSuffix($0) }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // 跟 collector/lyricsexport.go 的 sanitizeLyricsFilename 逐字对应的 Swift 版本——
    // 两边各自维护而不是让 Swift 调 Go 子进程,是因为这纯粹是确定性的字符替换("|"换成
    // " - "+转义文件系统不安全字符),没有会随时间演进的业务判断,不属于"两份实现容易
    // 走样"必须收敛成一份的那类逻辑(跟 search-lyrics 复用 scoredLyricCandidates 的
    // 场景不同,那边是真的检索/打分逻辑)。
    private static func sanitizeLyricsFilename(_ key: String) -> String {
        EnrichCacheKeys.sanitizeFilename(key)
    }

    // 这个 key 在 lyrics/ 目录下应该用哪个文件名 base 写文件——必须跟 collector 实际会用的
    // 那个一致。碰撞组(sanitize 结果只差大小写的多个 key)内的成员用带 crc32 后缀的名字,
    // 其余用普通名,规则跟 collector/lyricsexport.go:105-141 对齐。
    //
    // ⚠️ 2026-08-05 排查坐实的真实 bug:改动之前 writeLyricsFiles 一律写普通名。碰撞组里的
    // 条目在磁盘上本来只有带后缀的那份(Go 会主动删普通名),于是"保存修改"写出一个普通名
    // 文件、带后缀的旧文件还在,下次 collector 重启时 importLyricsFromFiles 把这两份文件
    // 当成两组分别处理,而两组的头部标签完全一样、解析出的 key 是同一个,于是各自往
    // enrichCache[key] 写一次——谁最后写谁生效,而它遍历的是 Go map(顺序每次进程启动都
    // 随机)。也就是说这 219 条(本机实测占 25.7%)上的手动修改是**每次重启随机决定生效还是
    // 被旧内容覆盖回去**。现在改成写 collector 认的那个名字,并在 writeLyricsFiles 里顺手
    // 清掉另一种形态的残留,消掉"同一个 key 对应两组文件"这个根源。
    private func exportBaseName(forKey key: String) -> String {
        let fold = EnrichCacheKeys.sanitizeFilename(key).lowercased()
        let collides = raw.keys.contains { other in
            other != key && EnrichCacheKeys.sanitizeFilename(other).lowercased() == fold
        }
        return collides ? EnrichCacheKeys.disambiguatedName(forKey: key) : EnrichCacheKeys.sanitizeFilename(key)
    }

    // 找不到文件(比如这条从来没有译文/罗马音/逐字时间轴)是正常情况,静默忽略——这只是
    // 清理可能存在的归档副本,不是这次删除操作的主体,不值得为"文件本来就不存在"这种
    // 预期内的情况去污染 lastError(那个留给 persistAndRestart 里真正的主体操作失败用)。
    // lyricsFileSuffixes 全部 4 个后缀都试一遍,跟 writeLyricsFiles 对称——"删除"要
    // 清掉整个歌词文件族,不只是纯歌词那一份。
    private func deleteExportedLyricsFile(forKey key: String) {
        for name in EnrichCacheKeys.exportedFileNames(forKey: key) {
            try? FileManager.default.removeItem(at: Self.lyricsDir.appendingPathComponent(name))
        }
    }

    // lyricsFileSuffixes 跟 collector/lyricsexport.go 的同名变量逐一对应。
    private static let lyricsFileSuffixes = EnrichCacheKeys.lyricsFileSuffixes

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
        let base = exportBaseName(forKey: key)
        // 先清掉"另一种形态"下可能残留的整族文件——不然同一个 key 会同时对应两组文件,
        // collector 导入时两组各写一次 enrichCache[key],生效哪一份取决于 Go map 的随机
        // 遍历顺序(见 exportBaseName 的注释)。这里必须精确取"另一个 base",不能用
        // hasPrefix 筛:普通名恰好是带哈希名的前缀("X" 是 "X~00fad0" 的前缀),用 hasPrefix
        // 在 base 是普通名时一个都清不掉。
        let plainBase = EnrichCacheKeys.sanitizeFilename(key)
        let staleBase = base == plainBase ? EnrichCacheKeys.disambiguatedName(forKey: key) : plainBase
        for suffix in EnrichCacheKeys.lyricsFileSuffixes {
            try? FileManager.default.removeItem(at: Self.lyricsDir.appendingPathComponent(staleBase + suffix))
        }
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
    // 只负责把 raw 落盘,不碰 collector。实测这一整套(校验+序列化 8.9MB+原子写盘)只要
    // 26ms,留在 MainActor 上同步做完全没问题,不值得为它多绕一层异步。
    // 返回是否成功——调用方据此决定要不要回滚内存状态。
    @discardableResult
    /// - Parameter replacingEverything: 用户明确要求"整份替换"(清空全部缓存)时传 true,
    ///   跳过下面的读-改-写合并 —— 那种场景下把盘上内容并回来正是要避免的。
    private func persist(replacingEverything: Bool = false) -> Bool {
        guard JSONSerialization.isValidJSONObject(raw) else {
            lastError = L10n.t("内部数据不是合法 JSON,已放弃保存")
            logger.error("raw dict is not valid JSON, aborting save")
            return false
        }
        // 读-改-写:以**盘上此刻的内容**为底,只把用户这次真正动过的 key 盖上去。
        //
        // 2026-08-14 之前这里是"整份覆盖 + 只并回没见过的新 key"。那半套只堵住了一半:
        // raw 只有 reload() 会刷新(开窗 .onAppear 和工具栏「刷新」两处),而"歌词管理"是个
        // 可以一直开着的窗口,典型用法就是边听边整理。开窗之后 collector 会持续往盘上写 ——
        // 新歌是**新 key**(旧逻辑救得回来),但给**已有 key 补上机翻译文/逐字时间轴/封面**
        // 是原地更新,旧逻辑完全不管:内存里那份还是开窗时的样子,窗口里随便一次删除或保存
        // 都会把它整份写回去,刚补上的译文就没了。用户能看到的症状是"这首歌明明有翻译,
        // 歌词管理里却不显示译文标记" —— 那还只是显示层,底下是真的在丢数据。
        //
        // 顺带一个好处:写完之后 raw 就是盘上最新内容,列表的标记不再停留在开窗那一刻。
        if !replacingEverything,
           let disk = try? Data(contentsOf: Self.cacheURL),
           let diskObj = try? JSONSerialization.jsonObject(with: disk) as? [String: [String: Any]] {
            // 合并规则本身抽在 LyrimuseCore.EnrichCacheMerge,好让 lyrimuse-selftest 能真的
            // 测它 —— 这个类是 @MainActor 且直接读写磁盘,测不了,而这段逻辑错了就是静默丢
            // 用户的歌词。
            let merged = EnrichCacheMerge.merge(
                disk: diskObj, memory: raw,
                edited: locallyEditedKeys, deleted: locallyDeletedKeys)
            lastPersistPulledInNewKeys = !Set(merged.keys).subtracting(raw.keys).isEmpty
            raw = merged
            knownKeys = Set(merged.keys)
        } else {
            // 盘读不出来/解析不了,或者调用方明确要求整份替换(清空全部缓存)——直接写 raw。
            lastPersistPulledInNewKeys = false
        }
        locallyEditedKeys.removeAll()
        locallyDeletedKeys.removeAll()
        do {
            let data = try JSONSerialization.data(withJSONObject: raw)
            try data.write(to: Self.cacheURL, options: .atomic)
        } catch {
            lastError = String(format: L10n.t("写入本地记录文件失败: %@"), error.localizedDescription)
            logger.error("write failed: \(String(describing: error), privacy: .public)")
            return false
        }
        return true
    }

    // 删完之后把工具栏那个"缓存占用"数字刷新一遍。它原来只有 reload() 会重算、clearAll()
    // 会硬置 0,单条 delete 完全不碰——删一条时误差小到没人注意,但批量删掉几百条之后,那个
    // 数字还挂着删之前的值,而它恰好就是"清空全部缓存"这个破坏性入口的标签,显示一个明显
    // 偏大的陈旧值容易让人误判。
    //
    // 只重算大小,不走 reload():reload() 会把 9.4MB JSON 重新读盘+解析一遍,而 raw 此刻
    // 已经是最新的权威内容(我们刚 persist 过),没必要再解析一次;而且 reload() 会顺手把
    // lastError 清掉,会吞掉刚刚可能产生的错误提示。
    private func refreshSizeBytes() {
        let cacheURL = Self.cacheURL
        let lyricsDir = Self.lyricsDir
        Task { [weak self] in
            let bytes = await Task.detached(priority: .utility) {
                Self.directorySizeBytes(lyricsDir) + Self.fileSizeBytes(cacheURL)
            }.value
            self?.totalSizeBytes = bytes
        }
    }

    // 不阻塞界面的 collector 重启,并且**合并**连续多次请求:已经有一次在飞就直接返回。
    // 合并是安全的——collector 启动时重新读盘,读到的必然是当时磁盘上最新的内容(我们
    // 总是先 persist() 再排队重启);而排队只会让 launchd 的 10 秒 minimum-runtime 惩罚
    // 一次次叠加,连删几条会越来越慢,却不会让最终结果更正确。
    private var pendingRestart: Task<Void, Never>?
    // 有重启在飞期间又落盘过——收尾时需要再补一次重启,见下面的注释。
    private var needsFollowUpRestart = false

    private func scheduleCollectorRestart() {
        if pendingRestart != nil {
            // ⚠️ 不能简单地"已经有一次在飞就直接丢弃这次请求":在飞的那一次可能已经把
            // collector 杀掉重启、而新进程已经读完盘了,此刻才发生的这次落盘它就看不到,
            // collector 内存里的旧值之后会把刚删的条目写回磁盘、复活它。窗口很窄(新进程
            // 启动读盘 与 kickstart 进程退出后本任务恢复执行 几乎同时),但不是不存在。
            // 记一个标记,等在飞那次收尾时补一次重启——不管期间删了多少条,最多只补一次,
            // 重启次数仍然有界。
            needsFollowUpRestart = true
            return
        }
        pendingRestart = Task { [weak self] in
            let ok = await CollectorControl.restartAndWaitAsync()
            guard let self else { return }
            self.pendingRestart = nil
            if !ok { self.lastError = L10n.t("重启 collector 失败") }
            PlaybackCoordinator.shared.refreshLyricsForCurrentTrack()
            if self.needsFollowUpRestart {
                self.needsFollowUpRestart = false
                self.scheduleCollectorRestart()
            }
        }
    }

    private func persistAndRestart() async {
        guard persist() else { return }
        if await !CollectorControl.restartAndWaitAsync() {
            lastError = L10n.t("重启 collector 失败")
        }
        // 磁盘已经是最新内容——不管当前悬浮窗显示的是不是被改的这首歌,让播放数据源
        // 强制重新读一次都无害(不是这首歌的话 key 对不上,syncEngine 内容不变),换来
        // 的是"改完歌词、悬浮窗还停在旧版本"这个问题被修掉,不用等下一次换歌才生效。
        PlaybackCoordinator.shared.refreshLyricsForCurrentTrack()
    }
}

// collector 固化的解析决策记录 —— 跟 collector/decision.go 的 lyricsDecision 逐字段对应
// (snake_case 由 JSONDecoder 的 convertFromSnakeCase 兜),只读展示,永远不写回。
// 得分明细直接复用 LyricsSearchService.ScoreTerm:collector 两条路径吐的是同一套
// scoreTerm(kind/points),这边的本地化文案(label/detail)天然通用。
struct LyricsResolutionDecision: Decodable {
    let path: String
    let decidedAt: Int?
    let scoringVersion: Int?
    let queryArtist: String?
    let queryTitle: String?
    let queryAlbum: String?
    let durationSecs: Double?
    let sourcesResponded: [String]?
    let winner: String?
    let applied: Bool?
    let candidates: [Candidate]?

    struct Candidate: Decodable, Identifiable {
        var id: String { source }
        let source: String
        let score: Int
        let scoreTerms: [LyricsSearchService.ScoreTerm]?
        let title: String?
        let artist: String?
        let album: String?
        let sourceReportedDurationSecs: Double?
        let hasWordTiming: Bool?
        let instrumental: Bool?
    }
}
