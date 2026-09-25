import Foundation
import LyrimuseCore
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lyrics-manager")

// 歌词管理窗口的数据层。跟 EnrichCacheReader(单条只读查询)不同,这里要读整个缓存做列表。
//
// **只读**:改动(保存编辑、采纳候选、批量锁定、标纯音乐、删除、清空、从快照恢复)一律经
// EnrichEditChannel 交给 collector 执行,这里不写 enrich-cache.json、也不写 lyrics/ 歌词文件。
// collector 把整份缓存握在内存里、每次存盘整份写回,是这份缓存唯一的写入方;App 在它背后改文件的话,
// 下一次存盘就会把改动盖掉。改完 collector 已经存好盘,这里 reload 一次拿回它的结果。
//
// 用 JSONSerialization 而不是 Codable 读整个文件:enrichEntry(collector/enrich.go)有几十个字段,
// 用一个只声明"我关心的几个字段"的 Codable 结构体去解,字段一多一改就对不上;原始字典只取要用的键。
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
        // 实测,一张专辑里一半曲目报 "Leah Dou"、另一半报"窦靖童"
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
        /// 用户在「联网搜索候选歌词」里选定的源(collector 侧 `lyrics_source_choice`)。
        /// 空 = 没选过,由算法自由选。跟 `isManual` 是两件独立的事,详情页各显示各的徽章。
        public let sourceChoice: String
        /// 这份歌词当前的时间轴校正值(毫秒),权威源是 LyricsOffsetStore——这里存的是
        /// buildSummaries 那一刻按内容指纹查出来的快照,不是实时值(见该函数的
        /// offsetsSnapshot 参数注释)。内容一换查出来的指纹就变,自然会变回 0,不需要
        /// 显式失效。
        public let offsetMs: Int
        // 译文是机翻补的(见 collector 的 translate.go)还是歌词源自带的社区翻译。
        // 空 = 社区翻译(老条目没有这个字段,读成空正是事实)。
        public let lyricsTrSource: String
        public let hasTranslation: Bool
        // 有没有罗马音标注(lyrics_roma)。值一直存在缓存里,只是列表一直没显示 ——
        // 详情页有这一栏、"搜索候选歌词"弹窗也有对应徽章,唯独列表看不出来。
        public let hasRomanization: Bool
        public let hasLyrics: Bool
        /// collector 联网确证过"这首本来就没有词"(lrclib 的 instrumental 或网易云的
        /// pureMusic,见 collector 侧 enrichEntry.Instrumental)。
        ///
        /// 接到这个界面上来:值早就存在缓存里(这个类型一直在解码它,见下面
        /// `instrumental` 那个字段),但列表和详情页都只看 hasLyrics —— 于是一整批
        /// 确证过的纯音乐(LoL 原声带那些)显示成刺眼的红色「无歌词」,跟"没搜到"混为一谈。
        /// 悬浮窗/灵动岛/歌词窗口三处一直分得清,唯独这里没有。
        public let isInstrumental: Bool
        /// 有没有 plain_lyrics(没有时间戳的纯文本兜底,见 collector 侧 enrichEntry.PlainLyrics
        /// 头注)——加,理由跟 isInstrumental 那次接入一样:值早就存在缓存里
        /// (「歌词窗口」已经在读它做静态展示),但列表和详情页都只看 hasLyrics,于是这批
        /// "至少有纯文字可读"的条目显示成刺眼的红色「无歌词」,跟"什么都没有"混为一谈。
        public let hasPlainTextFallback: Bool
        /// 歌词源(网易云 / QQ 音乐)的曲库里**有这首歌**——netease_url 带 song id、或 qq_music_url
        /// 是 songDetail 页而不是搜索兜底页——但没拿到词。加:「歌词管理」里 82 条
        /// 非纯音乐的空条目,56 条是 2026 年新发的独立作品(gamza / jehoda / The Rose /
        /// Japanese City Pop),网易云和 QQ 都收录了歌、只是发行方没挂歌词、社区也没人写;
        /// 它们跟"九个源一条都没搜到、可能是我们匹配失败"是两种不同的"无歌词",前者不是
        /// 该修的,只能等。列表/详情据此把红色「无歌词」换成中性的「源里有歌、无词」——
        /// 判据是 collector 解析时确实定位到了那首歌(拿到了平台 id),不是猜的。
        public let knownOnSources: Bool
        /// 最近一轮解析**一个源都没应答**。判据本体在
        /// `LyrimuseCore.EnrichSourcePresence.lastRoundHadNoResponder`(selftest 覆盖),
        /// 那里写清了为什么不能拿顶层 `lyrics_sources_responded` 是不是空来判。
        ///
        /// 消费方判定链里它要**排在 `knownOnSources` 之前**:两者常常同时为真(本机 142 条
        /// 空条目里 69 条是「源里有歌·无词 + 最近一轮零应答」),而给用户的行动建议相反 ——
        /// 前者说"词还不存在、只能等",后者说"那一刻网络全挂、重搜也许就有"。
        public let lastRoundHadNoResponder: Bool
        /// 这份歌词**当初是在几个源应答的情况下**定下来的。
        /// 0 = 老条目没有 `lyrics_sources_responded` 这个字段(不是"零个源应答")——
        /// 两者在界面上必须区分,所以消费方一律判 `> 0` 再显示。
        ///
        /// 为什么要摆到列表里(而不是只留在「解析决策」弹窗):缓存永久保留 + 20 秒总截止,
        /// 首次解析本来就有运气成分(09 章决策 6)。实测本机 4248 条带该字段的有词条目里
        /// **29.4%(1249 条)当初只有 <=3 个源应答**;而 `needsLyricsRetry` 有一道
        /// 「已有逐字就不重试」的闸(enrich.go),本机 94.3% 的有词条目带逐字 —— 交集
        /// **1088 条(25.6%)的升级重试永不触发**,旁证是全库 `lyrics_retry_count` 只出现在
        /// 30 条上。这批"薄证据条目"此前在界面上完全不可见,用户无从挑出来重搜。
        ///
        /// 刻意**不改**重试策略本身:那道闸有它的理由(逐字是质量的直接证据),而改判据
        /// 要 bump 打分版本、让全库走一遍 rescore —— 09 章决策 49 已经论证过这类代价。
        /// 这里只做"可见 + 可筛",挑不挑由用户定。
        public let sourcesRespondedCount: Int
        /// 这份歌词是按**哪一版**打分规则选出来的(collector 侧 `lyrics_scoring_version`)。
        /// 0 = 老条目从来没写过这个字段 —— 那也是"落后于当前版本"的一种,不是"未知"。
        ///
        /// 接到界面上来,给「全量重新扫库」算「N 首待跟进」用(见
        /// `LyricsFullScan.tier`)。本机实测 5514 条里 5472 条(99.2%)落后于当前的 v19,
        /// 版本从 v0 一直摊到 v18 —— 收编它们的 `rescoreLyrics` 跟补空一样只在这首歌又被
        /// 播到时触发,几千首的库靠自然播放追平算法版本要走好几年。
        public let lyricsScoringVersion: Int
        /// 补空失败过几次(`lyrics_fill_count`)、上次补空与上次重评的时刻(`lyrics_fill_ts` /
        /// `lyrics_rescore_ts`,Unix 秒,0 = 没有)。只给「全量重新扫库」算「N 首」用,
        /// 跟 collector 的续跑跳过与无望跳过对齐(见 `LyricsFullScan.tier`)。
        public let lyricsFillCount: Int
        public let lyricsFillAt: Int64
        public let lyricsRescoreAt: Int64

        /// true = 这一行不是缓存里真实存在的条目,是"这首歌正在联网搜歌词、collector
        /// 还没写出任何结论"这段窗口期的占位行(见 `LyricsManagerView.refreshPlaceholder`)。
        /// 这个列表**只**读 collector 写的缓存文件,搜索还没出结论那段
        /// 时间文件里压根没有这个 key,不是"有但没显示"。这一行不对应 `raw` 里任何 key,
        /// 编辑/删除/重新自动匹配这些操作对它都没有意义,消费方必须先判断这个字段。
        public let isSearching: Bool
        // 这条有没有 collector 固化的解析决策记录(候选表+得分明细,见 collector/decision.go)。
        // 只作按钮显隐用 —— 完整结构改**懒解码**(decodedDecision(for)):
        // 原来 rebuild 时对每条带该字段的条目都做一轮 JSONSerialization.data + JSONDecoder
        // 双重编解码,而结果只有打开「解析决策」弹窗那一刻才被消费,全量急算纯属浪费。
        let hasDecision: Bool
        /// 这条的歌词内容上次真的变过是什么时候 —— 取自**导出的歌词文件的 mtime**
        /// (`lyrics/` 下 `.lrc`/`.tr.lrc`/`.roma.lrc`/`.yrc` 四个里最新的那个),
        /// nil = 磁盘上一个歌词文件都没有(压根没歌词的条目,export 会跳过它们)。
        ///
        /// 为什么用文件 mtime 而不是缓存里的时间戳字段:缓存里**没有**一个真正表达"更新
        /// 时间"的字段。实测本机 3210 条的覆盖率 ——
        ///   `lyrics_decision.decided_at` 73%(而且它是"上次自动决策",手改歌词不会动它)
        ///   `translation_ts` 25% / `peripheral_ts` 9% / `lyrics_rescore_ts` 7%
        /// 全是偏科的局部时间戳。而 `lyrics/` 是六字段的权威源,**所有**写入路径都经过它
        /// (都是 collector 的导出,App 的改动也经它),覆盖率
        /// 3169/3210、缺的 41 条正好是没歌词的。
        ///
        /// 关键前提:`exportLyricsFiles` 写盘前会比对全文、逐字节相同就 `continue`
        /// (lyricsexport.go),所以 mtime 不会被"每次 collector 启动都重写一遍"冲掉。
        /// 实测本机 mtime 散布在 08-22～09-01 而不是全挤在最近一次重启,坐实了这一点。
        /// 哪天那个跳过逻辑被去掉,这个字段就会集体失真(全变成最后一次启动时间),
        /// 而且**表现是静默的** —— 排序看着还在工作,只是结果全错。
        let lyricsUpdatedAt: Date?
        /// 这条记录**上次被解析出来**的时刻,取自缓存里的 `ts`(collector 侧
        /// `enrichEntry.TS`,写入点 enrich.go 的 `e.TS = time.Now().Unix()`)。
        /// nil = 老条目没有这个字段。
        ///
        /// 它**不是** `lyricsUpdatedAt` 的替代品,只当次级键用:两者量纲不同 ——
        /// mtime 是"歌词正文上次真的变过",ts 是"这条上次被解析过"(重搜一轮没搜到新
        /// 东西也会把 ts 推到当下,而正文没变、mtime 不动)。全库覆盖率也更低
        /// (实测 2445/3402 ≈ 72%,而 mtime 是 3169/3210 ≈ 99%)。
        ///
        /// 唯一用途见 `LyricsSortOrder`:**没有歌词文件 / 没有来源**的那一批行,
        /// 在对应排序档里本来注定是一团分不出先后的平局(退化成默认排序,看起来像
        /// "选了排序没反应"),用 ts 给这个尾块一个真实的组内顺序。
        let resolvedAt: Date?
        // ---- 预计算归一化键 ----
        // 排序/筛选/归并的热路径原来逐次现算 toSimplified(ICU CFStringTransform)+
        // lowercased:排序比较器每次比较 4 次、筛选谓词每行最多 4 次、专辑归并字典
        // 每次重建 N 次 —— 852 条数据一次交互就是上万次 ICU 调用。现在 rebuild 时
        // 每条算一次存着,热路径只做字符串比较。
        /// toSimplified(primaryArtist(展示歌手名)).lowercased() —— 歌手筛选/排序用。
        let normPrimaryArtist: String
        /// toSimplified(album).lowercased() —— 专辑筛选/排序/归并字典的键。
        let normAlbum: String
        /// 搜索谓词用的四个小写副本(搜索框每敲一键全量过滤一遍,别逐行现 lowercased)。
        let searchArtistLower: String
        let searchDisplayArtistLower: String
        let searchTitleLower: String
        let searchAlbumLower: String

        /// 只给排序/筛选归并用(normPrimaryArtist、EnrichCacheStore.artistMap→
        /// distinctArtists→筛选下拉),**不再**用于列表逐行渲染的文字——改掉:
        /// 同一个人如果原始标签一时中文一时英文(如"方大同"/"Khalil Fong"),会各自落进
        /// 独立的缓存条目(key 用原始写法拼),优先展示统一名会让两条本该能分清楚的记录在
        /// 列表里长得一模一样、用户区分不出这是两条不同记录(比如两条记录只有大小写和
        /// 歌手语言不同,列表里完全没法区分)。
        /// 筛选依然按这个统一名归并(选"方大同"两条都要出来),只是"这一列具体显示哪个
        /// 字符串"改成如实展示每条记录自己的原始写法。
        var displayArtist: String { canonicalArtist.isEmpty ? artist : canonicalArtist }
    }

    @Published public private(set) var summaries: [Summary] = []
    /// reload() 正在飞——给视图层判断"这是首次打开、summaries 还没有任何内容"用,好
    /// 展示一个"正在加载"占位而不是一片空白的 List。缓存文件已经长到 1700+ 条/22MB,
    /// JSONSerialization 解析这一份实测要 250ms+(见 reload() 内部注释),解析本身在
    /// 后台线程跑、不卡主线程,但"完全没内容可看"的这段等待时间仍然存在,需要占位提示。
    @Published public private(set) var isLoading = false
    /// summaries 每重建一次 +1 —— 给视图侧的 filtered 缓存当失效键(见 LyricsManagerView),
    /// 数组本身没做 Equatable,靠这个代数判断"列表内容换过了没有"。
    private(set) var summariesGeneration = 0
    /// 专辑归并展示名:归并键(toSimplified+小写)→ 首见原写法。随 summaries 重建一次
    /// (若做成计算属性、每次访问全量重建,List 每物化一行就要付一次 O(N) 次 ICU 变换,
    /// 是本模块里最重的操作之一)。
    @Published private(set) var albumDisplayMap: [String: String] = [:]
    /// 筛选下拉的候选集,同样随 summaries 重建一次,不再每次 body 现算。
    @Published private(set) var distinctArtists: [String] = []
    @Published private(set) var distinctAlbums: [String] = []
    /// 宽松 key(`EnrichCacheKeys.looseKey`)到列表里第一条对得上的 key,随 summaries 在后台重建一次。
    /// 占位行每 5 秒核对一次、「回到当前播放」精确对不上时都要按宽松 key 找;逐条现算要对全库八千多个 key
    /// 各做一次繁简转换,放在主线程上。
    private var looseKeyIndex: [String: String] = [:]
    @Published public private(set) var lastError: String?
    // 缓存 JSON 文件本身 + lyrics/ 权威源文件夹里所有文件的总大小——"歌词管理"工具栏
    // 展示用,让用户知道这个"解析一次永久保留"的缓存实际占了多少磁盘空间。跟 reload()
    // 同一次磁盘扫描顺带算出来,不为这一个数字单独再打开一轮文件 I/O。
    @Published public private(set) var totalSizeBytes: Int64 = 0

    /// 「占用空间」的**唯一**渲染口径。
    ///
    /// 同一个字节数现在有三处要显示(「歌词管理」工具栏、自动备份菜单里每份快照、设置页
    /// 「歌词库」那一行),各自 `ByteCountFormatter()` 的话迟早在单位或小数位上分叉 ——
    /// 同一个数在两扇窗口里写法不同,用户只会以为自己看错了。放在**发布这个数字的类型上**
    /// 而不是某个 View 里:数字和它的写法待在一起,下一处要用的人一眼就找得到。
    ///
    /// `.file` 而不是限定 `.useMB`:总量从几百 KB(刚起步)到几十 MB(用了很久)跨度很大,
    /// 让系统按量级自己挑单位,也顺带跟着用户的地区习惯走。
    static func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// 最近一次破坏性操作(清空/批量删除)之前打的那份自动快照落在哪。nil = 这次没打成
    /// (库本来就是空的,或者写盘失败)。UI 据此如实告诉"能不能撤回",绝不能默认
    /// 有备份 —— 那比没有备份更危险。
    @Published private(set) var lastAutoSnapshotURL: URL?

    private static let cacheURL = LyrimusePaths.configFile("lyrimuse-enrich-cache.json")
    // 读 FeatureSettingsStore 的计算属性,而不是编译期定死的 static let——用户可在
    // "歌词"设置分类里自定义文件夹位置,这里必须跟 collector 那边(main.go 读
    // features.LyricsDir)认的是同一个位置,否则存/删歌词文件的目录跟 collector 实际
    // 读取的目录对不上。
    private static var lyricsDir: URL { FeatureSettingsStore.shared.effectiveLyricsDir }

    private var raw: [String: [String: Any]] = [:]
    // true = 内存里没有可用的快照:从没读过、上次读盘失败,或被 `dropSnapshotIfIdle` 清掉了。改动交给 collector
    // 之后据此决定要不要 reload(没人在看就不读)。
    private var isReleased = true
    // 正在看这份快照的界面(「歌词管理」窗口、设置页「歌词库统计」)。都不看了 `releaseDelay` 之后清掉快照:
    // 开着「歌词管理」时它连同列表约占 300 MB,原来关窗之后一直留到 App 退出。
    private var snapshotHolders: Set<String> = []
    private var releaseTask: Task<Void, Never>?
    private static let releaseDelay: Duration = .seconds(5)
    // 交给 collector、还没回结果的改动数(见 commit)。不为 0 时不清快照:改完要 reload 刷新列表。
    private var editsInFlight = 0

    private init() {}

    // 缓存文件设计上永久不清理("解析一次永久保留"),攒到几百条、几 MB 后
    // JSONSerialization 解析整份文件要 30ms 以上——若直接在 MainActor 上同步做,开窗/点
    // "刷新"都会卡一下,且随缓存变大越来越慢。这里把读文件+解析挪到后台线程,只在算完
    // 之后回 MainActor 赋值。box 用 @unchecked Sendable 包一层,是因为 JSONSerialization
    // 解出来的 [String: [String: Any]] 含 Any,编译器没法证明它是 Sendable,但这里的跨
    // 线程访问本来就有明确的先后顺序(detached task 算完、await 完了才读 box),不是真的
    // 并发写。
    /// 上一次成功读盘时缓存文件的 (mtime, size) 指纹 —— onlyIfChanged 的门控依据。
    private var lastLoadedFingerprint: FileFingerprint?

    struct FileFingerprint: Equatable {
        var mtime: Date
        var size: Int64
    }

    private nonisolated static func fileFingerprint(_ url: URL) -> FileFingerprint? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return FileFingerprint(mtime: mtime, size: (attrs[.size] as? NSNumber)?.int64Value ?? 0)
    }

    /// - Parameter onlyIfChanged: true = 缓存文件的 (mtime, size) 指纹没变就什么都不做
    ///   (性能审计:App 每次激活都触发一次 reload,而绝大多数激活时文件根本
    ///   没变,整份 9.4MB 重读+解析+重建+summaries 重发布 → List 全量 diff 全是白跑;
    ///   同仓 EnrichCacheReader 早有同款 mtime 门控)。开窗 onAppear 和工具栏「刷新」
    ///   保持默认 false(显式刷新语义)。
    /// 在飞的那次 reload。两个窗口(设置页「歌词库统计」、歌词管理)各有一条 2 秒轮询,
    /// 扫库跑着的时候它们会在同一拍上各调一次 reload —— 同一份 86MB 文件解析两遍,还
    /// 互相抢内存带宽。的基线日志里 12:21:36.227 与 .461、12:21:45.024 与
    /// .297 这两对,就是它俩各跑一遍同一份数据;更实测到并发的第二次从 211ms
    /// 劣化到 1397ms。
    private var inFlightReload: Task<Void, Never>?

    /// 合并判据必须看「**正在跑**」,不能看「上次跑完的时间戳」。按
    /// `lastReloadFinishedAt` 那种写法挡不住同时起跑的两次 —— 两边进判据时它都还是旧值、
    /// 双双放行,合并窗一次都不生效(日志坐实,当时 30s 的窗口形同虚设)。
    ///
    /// 两种调用者语义不同,不能一视同仁地搭车:
    ///   - `onlyIfChanged == true`(轮询/App 激活这类**被动**触发):搭在飞的那次的车,
    ///     拿到的快照够用。
    ///   - `onlyIfChanged == false`(用户点「刷新」、clearAll 重试这类**显式**触发):要的是
    ///     "现在这一刻的盘上内容",搭车可能拿到它发起**之前**的快照,所以先等在飞的跑完
    ///     (串行化,不并发抢带宽)再自己完整跑一遍。
    public func reload(onlyIfChanged: Bool = false) async {
        if onlyIfChanged, let inFlight = inFlightReload {
            await inFlight.value
            return
        }
        if let inFlight = inFlightReload { await inFlight.value }
        let task = Task { await self.performReload(onlyIfChanged: onlyIfChanged) }
        inFlightReload = task
        await task.value
        // 必须**条件**置空。无条件 `inFlightReload = nil` 会抹掉别人在飞的 Task,
        // 下一个调用者又并发跑一遍,等于把这个 bug 原样放回来。selftest 钉着这一行。
        if inFlightReload == task { inFlightReload = nil }
    }

    private func performReload(onlyIfChanged: Bool) async {
        let cacheURL = Self.cacheURL
        if onlyIfChanged,
           let fp = Self.fileFingerprint(cacheURL),
           fp == lastLoadedFingerprint {
            return
        }
        // "缓存占用"这个数字只是工具栏一个菜单标签,不是 List 要渲染的内容——原来跟
        // JSON 解析捆在同一个 detached task 里,summaries 白白多等一轮 lyrics/ 目录扫描
        // (实测约 18ms,数量小但完全没必要挡在关键路径上)。改用已有的
        // refreshSizeBytes()(delete 完刷新占用数字用的同一条路径),独立算、独立更新,
        // 不再等它。
        refreshSizeBytes()
        isLoading = summaries.isEmpty
        defer { isLoading = false }
        final class ResultBox: @unchecked Sendable {
            var obj: [String: [String: Any]]?
            var bundle: SummariesBundle?
            var fingerprint: FileFingerprint?
            var errorMessage: String?
            // 基线埋点(临时,见 LyricsManagerBaseline)——分段耗时在 detached 闭包里量,
            // 借这个盒子捎回 MainActor 一起打一条日志。
            var bytes = 0
            var readMS = 0.0
            var parseMS = 0.0
            var buildMS = 0.0
        }
        let box = ResultBox()
        let reloadStart = CFAbsoluteTimeGetCurrent()
        // 在进 Task.detached 之前取快照:LyricsOffsetStore 是 @MainActor 单例,detached
        // 闭包跑在后台线程,不能在里面同步访问它——纯字典拷贝,提前拿一份传进去即可。
        let offsetsSnapshot = LyricsOffsetStore.shared.offsetsSnapshot
        // 同理:lyricsDir 读的是 FeatureSettingsStore.shared(MainActor),在这儿取好。
        // 真正的目录枚举(I/O)在 buildSummaries 里、也就是后台跑。
        let lyricsDir = Self.lyricsDir
        await Task.detached(priority: .userInitiated) {
            box.fingerprint = Self.fileFingerprint(cacheURL)
            let snapshot = Self.loadSlimSnapshot(cacheURL: cacheURL)
            box.readMS = snapshot.readMS
            box.parseMS = snapshot.parseMS
            box.bytes = snapshot.bytes
            guard let obj = snapshot.obj else {
                box.errorMessage = snapshot.errorMessage
                return
            }
            box.obj = obj
            let tBuild = CFAbsoluteTimeGetCurrent()
            // summaries 的构建+排序也在后台做掉(原来回 MainActor 同步跑,
            // 每次开窗/激活吃几十到一二百 ms 主线程),主线程只收结果赋值。
            box.bundle = Self.buildSummaries(from: obj, offsetsSnapshot: offsetsSnapshot, lyricsDir: lyricsDir)
            box.buildMS = LyricsManagerBaseline.ms(since: tBuild)
        }.value
        if let obj = box.obj, let bundle = box.bundle {
            raw = obj
            lastLoadedFingerprint = box.fingerprint
            isReleased = false
            lastError = nil
            applySummaries(bundle)
            scheduleReleaseIfUnheld()
            LyricsManagerBaseline.logReload(
                bytes: box.bytes, count: obj.count,
                readMS: box.readMS, parseMS: box.parseMS, buildMS: box.buildMS,
                totalMS: LyricsManagerBaseline.ms(since: reloadStart))
        } else {
            raw = [:]
            lastLoadedFingerprint = nil
            lastError = box.errorMessage ?? L10n.t("读取本地记录文件失败")
            applySummaries(Self.buildSummaries(from: [:], offsetsSnapshot: offsetsSnapshot, lyricsDir: Self.lyricsDir))
        }
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

    // nonisolated:纯字符串切分,buildSummaries 在后台构建线程也要调。
    private nonisolated static func splitKey(_ key: String) -> (artist: String, title: String, album: String)? {
        let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    /// summaries 及其派生物(归并字典/筛选下拉候选)的一次性构建结果。
    private struct SummariesBundle {
        var summaries: [Summary]
        var albumDisplayMap: [String: String]
        var distinctArtists: [String]
        var distinctAlbums: [String]
        var looseKeyIndex: [String: String] = [:]
    }

    /// 把一份构建结果发布出去。跟 buildSummaries 拆开:构建是纯函数(reload 时在后台跑,
    /// 保存/删除时在主线程同步跑 —— 预计算归一化键之后单次只剩字典取值+元组排序,几 ms),
    /// 发布必须在 MainActor。
    private func applySummaries(_ bundle: SummariesBundle) {
        summaries = bundle.summaries
        summariesGeneration &+= 1
        albumDisplayMap = bundle.albumDisplayMap
        distinctArtists = bundle.distinctArtists
        distinctAlbums = bundle.distinctAlbums
        looseKeyIndex = bundle.looseKeyIndex
    }

    /// 界面开始看这份快照(见 `snapshotHolders`)。取消正在倒数的清理。
    public func holdSnapshot(_ holder: String) {
        snapshotHolders.insert(holder)
        releaseTask?.cancel()
        releaseTask = nil
    }

    /// 界面不看了;最后一个走掉 `releaseDelay` 之后清快照(期间又有人来就作罢)。
    public func releaseSnapshot(_ holder: String) {
        snapshotHolders.remove(holder)
        scheduleReleaseIfUnheld()
    }

    /// 没人握着就排一次延时清理。读盘 / 写盘完成时也调:歌词窗口、「搜索歌词」小窗、设置页批量锁定这些入口
    /// 不握快照,自己 reload 一下就改,读进来的快照不能因此一直留着。
    private func scheduleReleaseIfUnheld() {
        guard snapshotHolders.isEmpty, releaseTask == nil else { return }
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.releaseDelay)
            guard !Task.isCancelled else { return }
            await self?.dropSnapshotIfIdle()
        }
    }

    /// 等在飞的读盘跑完再清;有人重新握住、或还有交给 collector 还没回来的改动就不清。清完把列表一起清空(没人在看),
    /// 并把 `lastLoadedFingerprint` 置空 —— 否则下一次 `reload(onlyIfChanged:)` 会以为快照还在、直接跳过。
    private func dropSnapshotIfIdle() async {
        defer { releaseTask = nil }
        if let r = inFlightReload { await r.value }
        guard !Task.isCancelled, snapshotHolders.isEmpty, inFlightReload == nil,
              editsInFlight == 0, !isReleased else { return }
        let count = raw.count
        raw = [:]
        lastLoadedFingerprint = nil
        isReleased = true
        applySummaries(SummariesBundle(summaries: [], albumDisplayMap: [:], distinctArtists: [], distinctAlbums: []))
        // 刚放掉的是几十万个小块;不催一下,分配器会把空出来的页攥在手里,footprint 不降。
        _ = malloc_zone_pressure_relief(nil, 0)
        logger.notice("snapshot released (\(count, privacy: .public) entries)")
    }

    private struct SlimSnapshot {
        var obj: [String: [String: Any]]?
        var errorMessage: String?
        var bytes = 0
        var readMS = 0.0
        var parseMS = 0.0
    }

    /// 「歌词管理」的内存快照是**精简条目**(见 `EnrichCacheSlim`):优先直接解 collector 写好的精简索引
    /// (约 32 MB;主缓存 107 MB,整份解开常驻 500 MB 以上);索引不在 / 比主缓存旧 / 老格式,就解主缓存再逐条精简。
    ///
    /// 索引必须**不比主缓存旧**:collector 每次保存先写主缓存、再写索引,中间约半秒。正赶上这半秒
    /// (主缓存 3 秒内刚写过、旧索引还在)就等一等索引,不急着去解整份主缓存。
    private nonisolated static func loadSlimSnapshot(cacheURL: URL) -> SlimSnapshot {
        var out = SlimSnapshot()
        let indexURL = LyrimusePaths.configFile(EnrichCacheReader.indexFileName)
        for attempt in 0..<8 {
            guard let main = fileFingerprint(cacheURL)?.mtime, let idx = fileFingerprint(indexURL)?.mtime else { break }
            if idx >= main {
                let tRead = CFAbsoluteTimeGetCurrent()
                guard let data = try? Data(contentsOf: indexURL) else { break }
                out.readMS = LyricsManagerBaseline.ms(since: tRead)
                let tParse = CFAbsoluteTimeGetCurrent()
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]],
                   EnrichCacheSlim.indexHasFields(obj),
                   fileFingerprint(cacheURL)?.mtime == main { // 解的这段时间主缓存没被换掉
                    out.parseMS = LyricsManagerBaseline.ms(since: tParse)
                    out.bytes = data.count
                    out.obj = obj
                    return out
                }
                break
            }
            guard attempt < 7, Date().timeIntervalSince(main) < 3 else { break }
            Thread.sleep(forTimeInterval: 0.4)
        }
        let tRead = CFAbsoluteTimeGetCurrent()
        guard let data = try? Data(contentsOf: cacheURL) else {
            out.errorMessage = L10n.t("读取本地记录文件失败")
            return out
        }
        out.readMS = LyricsManagerBaseline.ms(since: tRead)
        out.bytes = data.count
        let tParse = CFAbsoluteTimeGetCurrent()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            out.errorMessage = L10n.t("解析本地记录文件失败")
            return out
        }
        out.obj = obj.mapValues(EnrichCacheSlim.slim)
        out.parseMS = LyricsManagerBaseline.ms(since: tParse)
        return out
    }

    private nonisolated static func loadBody(forKey key: String) -> EnrichCacheBody? {
        let url = LyrimusePaths.configFile(EnrichCacheSlim.bodiesDirectoryName)
            .appendingPathComponent(DecisionSidecar.fileName(forKey: key))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EnrichCacheBody.self, from: data)
    }

    /// 某一条的某块正文;精简条目去读正文小文件(校验值对得上才用),不改 `raw`。给后台构建列表时那几首
    /// 调过时间轴偏移的歌算内容指纹用。
    private nonisolated static func bodyText(_ field: String, of entry: [String: Any], key: String) -> String {
        guard EnrichCacheSlim.isSlim(entry) else { return entry[field] as? String ?? "" }
        guard let body = loadBody(forKey: key), let full = EnrichCacheSlim.hydrate(entry, body: body) else { return "" }
        return full[field] as? String ?? ""
    }

    /// 用到这一条的正文之前把它补成完整条目(见 `EnrichCacheSlim`)。先读正文小文件;对不上(collector 还没
    /// 重写 / 文件缺了)就回主缓存取这一条 —— 那要解一遍整份主缓存,只在这种少见情况下付。
    /// - Returns: false = 补不回来(主缓存也读不了),调用方别拿缺正文的条目去改、去写。
    @discardableResult
    private func hydrate(_ key: String, fallbackToMainCache: Bool = true) -> Bool {
        guard let entry = raw[key], EnrichCacheSlim.isSlim(entry) else { return true }
        if let body = Self.loadBody(forKey: key), let full = EnrichCacheSlim.hydrate(entry, body: body) {
            raw[key] = full
            return true
        }
        guard fallbackToMainCache else { return false }
        logger.notice("hydrate: lyrics body file missing or stale, reading the main cache")
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            lastError = L10n.t("读取本地记录文件失败")
            return false
        }
        raw[key] = EnrichCacheSlim.restoreBodies(entry, from: obj[key])
        return true
    }

    // public:「歌词管理」详情页调过/重置过时间轴偏移之后也要调这个——那份改动只落在
    // LyricsOffsetStore(不是这里的 raw 字典),summaries 里预算好的 offsetMs 不会自己
    // 跟着变,得靠调用方显式喊一次重建(见 LyricsManagerView.applyOffsetEdit)。
    public func rebuildSummaries() {
        applySummaries(Self.buildSummaries(from: raw, offsetsSnapshot: LyricsOffsetStore.shared.offsetsSnapshot,
                                           lyricsDir: Self.lyricsDir))
    }

    // 排序键必须跟"列表上看到的那套分组"用**同一套归并规则**,否则会出现"显示层合并了、
    // 排序层还按原始写法把同一张专辑劈成两半"。实测撞到:「春游」这张专辑
    // 一半曲目排在列表最上面、一半排在最下面 —— 播放器把它们分别报成 "Leah Dou" / "窦靖童"
    // (歌手)和 "春遊" / "春游"(歌手/专辑繁简),排序键必须 canonical→primaryArtist→
    // 折简体+小写。归一化键现在在构建时预存进 Summary(normPrimaryArtist/normAlbum),
    // 比较器只做元组比较 —— 原来每次比较现算 4 次 CFStringTransform,852 条 ≈ 3.3 万次
    // ICU 调用,预算后只剩每条一次(还叠着 toSimplified 的 memo)。
    //
    // 专辑归并键跟展示值分开:同一张专辑偶尔因歌词源候选写法大小写/繁简不一致而在
    // s.album 里长得不一样,排序/归并按归一化键走;展示名取排序后首见的原写法
    // (albumDisplayMap),列表/详情/筛选下拉三处共用同一份。
    /// - Parameter offsetsSnapshot: LyricsOffsetStore 整份字典的一次性快照(调用方在
    ///   MainActor 上下文取好再传进来,见两处调用点的注释)——这个函数本身要能在后台线程跑,
    ///   不能在这里同步访问那个 @MainActor 单例。
    /// 扫一遍歌词目录,得到「折叠后的文件基名 → 该组四个文件里最新的 mtime」。
    ///
    /// **一次目录枚举、批量取属性**,不逐条 stat:后者要么 O(n) 次系统调用,要么(如果按
    /// key 现推文件名)撞上「这个 key 有没有别的 key 折叠后同名」那个每次都扫全 `raw.keys` 的 O(n²)。实测本机
    /// 7231 个文件全 stat 一遍 23ms,这条路径比它更省,且只做一次。
    ///
    /// 取四个后缀里**最新**的那个,而不是只看主 `.lrc`:译文/罗马音/逐字时间轴后来补上
    /// 也是这条记录真的变了,用户按「更新时间」找的就是"最近动过什么"。
    ///
    /// 键要**折叠成小写**:同一个 key 可能对应普通名或带哈希后缀的消歧名(见 collector 的
    /// exportLyricsFilesMatching),而这台文件系统大小写不敏感 —— 折叠后两种形态都能被调用方用
    /// 两次 O(1) 查找命中,不必在这里反推是哪一种。
    private nonisolated static func lyricsFileModificationDates(in dir: URL) -> [String: Date] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [:] }
        var dates: [String: Date] = [:]
        dates.reserveCapacity(entries.count)
        for url in entries {
            let name = url.lastPathComponent
            // 后缀要**从长到短**匹配:".tr.lrc" 也以 ".lrc" 结尾,先撞上 ".lrc" 会把基名
            // 切成 "xxx.tr",跟主文件分成两组、两边都算错。
            guard let suffix = Self.lyricsFileSuffixesLongestFirst.first(where: { name.hasSuffix($0) })
            else { continue }
            let base = String(name.dropLast(suffix.count)).lowercased()
            guard !base.isEmpty,
                  let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                      .contentModificationDate
            else { continue }
            if let known = dates[base], known >= date { continue }
            dates[base] = date
        }
        return dates
    }

    /// 见 lyricsFileModificationDates 里那段「从长到短」的说明。
    private static let lyricsFileSuffixesLongestFirst =
        EnrichCacheKeys.lyricsFileSuffixes.sorted { $0.count > $1.count }

    /// - Parameter lyricsDir: 歌词导出目录的一次性快照。跟 offsetsSnapshot 同一个理由 ——
    ///   它来自 `FeatureSettingsStore.shared`(MainActor),调用方在 MainActor 上取好传进来,
    ///   目录枚举这段 I/O 留在这个后台函数里跑。
    private nonisolated static func buildSummaries(
        from raw: [String: [String: Any]], offsetsSnapshot: [String: Int], lyricsDir: URL
    ) -> SummariesBundle {
        let lyricsFileDates = Self.lyricsFileModificationDates(in: lyricsDir)
        // offsetsSnapshot 几乎永远很小(这台机器实测 1756 条缓存里只有 7 条调过偏移),
        // 但 trackKey 要在 artist|title 之后拼一段**对整首歌词+YRC 正文取 SHA256** 的内容
        // 指纹(见 LyricsOffsetStore.contentFingerprint)——实测坐实:对全部
        // 1760 条无条件算这个指纹,单这一步就要 250ms+,比读盘解析整份 JSON 还贵,而其中
        // 99% 以上注定查不到东西(offsetsSnapshot 里根本没有对应的 artist|title)。
        //
        // 先把 offsetsSnapshot 的 key 反过来切一遍,取"最后一个 | 之前"那一截(= artist|title,
        // 指纹段本身不含 |,用 .backwards 找最后一个分隔符总能切对,不受 artist/title 自己
        // 含 | 影响)存成一个小集合——只有几个元素,后面每条曲目只需要用**同一套(cleanTag/
        // normalizedTitle)归一化过的 artist|title** 去比对这个小集合是否包含,包含了才值得
        // 付一次真正的 SHA256;不包含直接判定这首歌没有校正值,省掉整段哈希。命中率不变、
        // 结果逐位不变,只是把"注定查不到"的那 99% 提前挡在开销最大的那一步之前。
        let offsetPrefixes: Set<String> = Set(offsetsSnapshot.keys.compactMap { key in
            guard let sep = key.range(of: "|", options: .backwards) else { return nil }
            return String(key[..<sep.lowerBound])
        })
        var items = raw.keys.compactMap { key -> Summary? in
            guard let parts = Self.splitKey(key) else { return nil }
            let entry = raw[key] ?? [:]
            let lyrics = entry["lyrics"] as? String ?? ""
            // 四块正文有没有:精简条目看位图(EnrichCacheSlim),不去读正文。
            let bodyFields = EnrichCacheSlim.presentFields(entry)
            let canonical = entry["canonical_artist"] as? String ?? ""
            let display = canonical.isEmpty ? parts.artist : canonical
            // trackKey 要用播放时真正生效的那份内容指纹,所以拿这条原始 artist/title(跟
            // 播放侧同一套归一化,见 LyricsOffsetStore.trackKey 内部的说明),不是展示名。
            let offsetPrefix = "\(EnrichCacheKeys.cleanTag(parts.artist))|\(EnrichCacheKeys.normalizedTitle(parts.title))"
            let offsetMs: Int
            if offsetPrefixes.contains(offsetPrefix) {
                let offsetKey = LyricsOffsetStore.trackKey(artist: parts.artist, title: parts.title,
                                                            lyrics: lyrics,
                                                            lyricsYRC: Self.bodyText("lyrics_yrc", of: entry, key: key))
                offsetMs = offsetsSnapshot[offsetKey] ?? 0
            } else {
                offsetMs = 0
            }
            return Summary(
                key: key,
                artist: parts.artist,
                canonicalArtist: canonical,
                // 从「优先 duration_secs」改成「优先 resolved_duration_secs」——
                // 真实 bug 坐实(海龟先生《男孩别哭》):duration_secs 是 collector 那边
                // "只在当前为 0 才写"的粘性字段(enrich.go:1428 `if e.DurationSecs <= 0`),
                // 一旦第一次解析时凑巧读到一个错的时长(这首歌是 210.86s,真实时长
                // 306.94s),就永远冻结在那个错值上,后续任何一次成功的自动重新匹配都不会
                // 更新它。而 resolved_duration_secs 恰恰相反——每次自动匹配换上更好的候选
                // 都会同步刷新(enrich.go:1063/1233/1256),永远反映"当前这份歌词是按多少秒
                // 校验选出来的",天然自愈。这条 Summary 喂给"搜索候选歌词"弹窗当打分依据,
                // 用冻结的错值会让全部候选在时长匹配这两档(durationOff/sourceDurationOff)
                // 同时被重扣、分数全部跌到系统兜底的 1 分——内容其实都没问题。
                // resolved_duration_secs 缺失(老条目/从没成功匹配过)才退回 duration_secs,
                // 两个都没有就是 0(打分跳过整个时长档,而不是被错误时长带偏)。
                durationSecs: (entry["resolved_duration_secs"] as? Double).flatMap { $0 > 0 ? $0 : nil }
                    ?? entry["duration_secs"] as? Double ?? 0,
                title: parts.title,
                album: parts.album,
                lyricsSource: entry["lyrics_source"] as? String ?? "",
                hasWordTiming: bodyFields.contains(.yrc),
                isManual: entry["manual_lyrics"] as? Bool ?? false,
                sourceChoice: entry["lyrics_source_choice"] as? String ?? "",
                offsetMs: offsetMs,
                lyricsTrSource: entry["lyrics_tr_source"] as? String ?? "",
                hasTranslation: bodyFields.contains(.tr),
                hasRomanization: bodyFields.contains(.roma),
                hasLyrics: !lyrics.isEmpty,
                isInstrumental: entry["instrumental"] as? Bool ?? false,
                hasPlainTextFallback: bodyFields.contains(.plain),
                knownOnSources: Self.knownOnSources(entry),
                lastRoundHadNoResponder: Self.lastRoundHadNoResponder(entry),
                sourcesRespondedCount: (entry["lyrics_sources_responded"] as? [Any])?.count ?? 0,
                lyricsScoringVersion: (entry["lyrics_scoring_version"] as? Int) ?? 0,
                lyricsFillCount: (entry["lyrics_fill_count"] as? Int) ?? 0,
                lyricsFillAt: Int64((entry["lyrics_fill_ts"] as? Double) ?? 0),
                lyricsRescoreAt: Int64((entry["lyrics_rescore_ts"] as? Double) ?? 0),
                isSearching: false, // 这一条来自 raw,真实存在;占位行的构造点在 LyricsManagerView
                hasDecision: entry["lyrics_decision"] != nil || entry["lyrics_decision_applied"] != nil,
                // 两次 O(1) 查找:普通名、以及带哈希后缀的消歧名(collector 导出时 —— 到底
                // 用哪个取决于有没有别的 key 折叠后同名,那个判断本身是 O(n),不能在这个
                // 逐条循环里做)。都查不到 = 磁盘上没有这条的歌词文件。
                lyricsUpdatedAt: lyricsFileDates[EnrichCacheKeys.sanitizeFilename(key).lowercased()]
                    ?? lyricsFileDates[EnrichCacheKeys.disambiguatedName(forKey: key).lowercased()],
                // `ts` 是 Unix 秒。JSONSerialization 对整数给的是 NSNumber,用 Double
                // 取一次就够(秒级精度远在 Double 的安全整数范围内);<=0 当没有。
                resolvedAt: {
                    let ts = (entry["ts"] as? Double) ?? 0
                    return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
                }(),
                normPrimaryArtist: toSimplified(primaryArtist(display)).lowercased(),
                normAlbum: toSimplified(parts.album).lowercased(),
                searchArtistLower: parts.artist.lowercased(),
                searchDisplayArtistLower: display.lowercased(),
                searchTitleLower: parts.title.lowercased(),
                searchAlbumLower: parts.album.lowercased()
            )
        }
        items.sort {
            ($0.normPrimaryArtist, $0.normAlbum, $0.title) < ($1.normPrimaryArtist, $1.normAlbum, $1.title)
        }
        // 归并展示名按排序后顺序首见 —— 跟原来"按 summaries 已有顺序取第一次出现"语义一致。
        var albumMap: [String: String] = [:]
        var artistMap: [String: String] = [:]
        var looseIndex: [String: String] = [:]
        looseIndex.reserveCapacity(items.count)
        for s in items {
            let loose = EnrichCacheKeys.looseKey(s.key)
            if looseIndex[loose] == nil { looseIndex[loose] = s.key }
            if !s.album.isEmpty, albumMap[s.normAlbum] == nil { albumMap[s.normAlbum] = s.album }
            let rawArtist = primaryArtist(s.displayArtist)
            if !rawArtist.isEmpty, artistMap[s.normPrimaryArtist] == nil {
                artistMap[s.normPrimaryArtist] = rawArtist
            }
        }
        return SummariesBundle(
            summaries: items,
            albumDisplayMap: albumMap,
            distinctArtists: Array(Set(artistMap.values)).sorted(),
            distinctAlbums: Array(Set(albumMap.values)).sorted(),
            looseKeyIndex: looseIndex
        )
    }

    /// 这条最近一次自动匹配成功时用的时长(`resolved_duration_secs`)。给「重新自动匹配」
    /// 当兜底——Summary.durationSecs 现在本身已经优先取这个字段(见
    /// buildSummaries 里那段注释),这里多数情况下会跟 summary.durationSecs 相等,只在
    /// 两个时长字段都还没写过(老条目/从没成功解析过)时才会一起是 0,那就只能不带时长
    /// 跑一轮(打分会跳过整个时长档,结果不代表自动决策)。
    public func resolvedDurationSecs(for key: String) -> Double {
        raw[key]?["resolved_duration_secs"] as? Double ?? 0
    }

    /// 缓存里有没有这个 key——给"正在搜索"占位行判断"collector 是不是已经写出结论了"用
    /// (`LyricsManagerView.refreshPlaceholder`):有就说明真实那一行已经存在于 `summaries`
    /// 里,占位行该让位了;没有就说明还在搜。只暴露"存不存在"这一个布尔,不直接开放 `raw`
    /// 本身——那份原始字典的字典级读写是这个类型自己的事,消费方不该绕过 Summary 这层接口。
    ///
    /// 只做精确字典查找会漏掉繁简写法不一致的情况:占位行的 key 是**当下这一刻**
    /// 播放器实时上报的 artist/title/album 拼出来的(EnrichCacheKeys.normalizedKey,
    /// 不含繁简折算)——collector 那条 enrichKey 同样不折算(必须跟 Apple Music/播放器
    /// 原始标签逐字节一致,见 enrich.go 那段注释),同一首歌只要播放器这次上报的专辑名
    /// 繁简写法(如"收斂水"/"收敛水")跟当初解析那次不一样,拼出来的 key 就会对不上已经
    /// 写盘的那一条——即便磁盘里其实早就有真实的、
    /// 带着完整歌词的记录,这里也会永远判"没有",占位行"正在搜索…"就卡死不会让位(其它
    /// 视图能正常显示歌词,是因为它们走的是 EnrichCacheReader 的宽松匹配,那边已经在用
    /// EnrichCacheKeys.looseKey 折算繁简,只有这条独立维护的精确查找漏了这一层)。
    /// 精确命中优先,精确查不到再查宽松索引(`looseKeyIndex`)。
    public func hasEntry(forKey key: String) -> Bool {
        raw[key] != nil || self.key(matchingLoose: key) != nil
    }

    /// 列表里跟这个 key 宽松相等(大小写 / 空格 / 繁简不同)的第一条,没有就 nil。
    func key(matchingLoose key: String) -> String? {
        looseKeyIndex[EnrichCacheKeys.looseKey(key)]
    }

    /// 懒解码某条的解析决策记录 —— 只在打开「解析决策」弹窗那一刻按 key 解一条,
    /// 见 Summary.hasDecision 的注释。
    func decodedDecision(for key: String) -> LyricsResolutionDecision? {
        Self.decodeDecision(Self.hydratedDecision(raw[key]?["lyrics_decision"], key: key))
    }

    /// 判决的候选明细(candidates / queries_tried)在旁路目录里(`DecisionSidecar`,collector 保存时拆出去),
    /// 按指纹补回来再解;指纹对不上就不补,弹窗那边显示「候选明细缺失」。老条目 / 还没被拆过的原样用。
    private static func hydratedDecision(_ value: Any?, key: String) -> Any? {
        guard let dict = value as? [String: Any] else { return value }
        let dir = LyrimusePaths.configFile(DecisionSidecar.directoryName)
        return DecisionSidecar.hydrate(dict, record: DecisionSidecar.loadRecord(key: key, directory: dir))
    }

    /// 「当前歌词的出处」那一槽(lyrics_decision_applied,collector 分槽写入)。
    /// 跟上面的 lyrics_decision(最近一次评估,可能维持原状、甚至输入是脏的)是两份记录:
    /// 一轮没采纳的评估会盖掉 lyrics_decision,但不动这一槽 ——「解析决策」弹窗靠它才能
    /// 永远解释"现在这份词是谁、凭什么选的"。老条目(分槽前写入)没有这一槽,弹窗侧有
    /// "最近评估恰好 applied 就当出处"的退路(见 LyricsDecisionSheet.init)。
    func decodedAppliedDecision(for key: String) -> LyricsResolutionDecision? {
        Self.decodeDecision(Self.hydratedDecision(raw[key]?["lyrics_decision_applied"], key: key))
    }

    // 返回值含 yrc:「歌词管理」的单曲歌词时间轴偏移输入框需要跟 LocalPlaybackSource
    // 用同一份内容(lyrics+lyricsYRC)算出来的指纹去查/存 LyricsOffsetStore,不然算出来
    // 的 key 对不上真正播放时用的那个 key。
    public func detail(for key: String) -> (lyrics: String, tr: String, roma: String, yrc: String) {
        let t0 = CFAbsoluteTimeGetCurrent()
        hydrate(key)
        let entry = raw[key] ?? [:]
        let result = (
            entry["lyrics"] as? String ?? "",
            entry["lyrics_tr"] as? String ?? "",
            entry["lyrics_roma"] as? String ?? "",
            entry["lyrics_yrc"] as? String ?? ""
        )
        // 基线埋点(临时,见 LyricsManagerBaseline):记录直接从内存里拿这份数据要多久,
        // 供跟未来改成读 lyrics/ 文件的方案比较耗时。
        LyricsManagerBaseline.logDetail(
            key: key,
            totalChars: result.0.count + result.1.count + result.2.count + result.3.count,
            elapsedMS: LyricsManagerBaseline.ms(since: t0))
        return result
    }

    // yrc 默认 nil:纯手改文本框的普通保存路径不传它,完全不碰 lyrics_yrc 字段——这是
    // 有意的("歌词管理"从不提供逐字时间轴的自由文本编辑,格式是嵌套时间戳,手改错了代价
    // 大,「移除逐字时间轴」入口已删)。只有"联网搜索候选歌词"整条采纳某个候选时才会传非 nil:
    // 采纳意味着连同逐字时间轴一起换成这个候选的版本(有就设、没有就清空)——否则旧
    // lyrics_yrc 会继续绑定已经被替换掉的旧文本,播放时逐字时间戳和新歌词对不上。
    //
    // source 同理默认 nil:采纳候选时显式设成 candidate.source(见 LyricsManagerView 的
    // onApply),准确反映刚采纳的这份内容真实来自哪个平台;纯手改文本框(source 留 nil)
    // 则清空这个字段——手改之后已经不再是任何平台的原文,继续挂着旧的平台徽章比"无
    // 来源"更容易误导人,跟"人工修正"徽章(isManual)搭配显示才诚实。
    /// - markManual: 默认 true(手动编辑/手动采纳候选都是人工修正)。**「重新自动匹配」传
    ///   false** —— `manual_lyrics` 是 collector 侧所有自愈路径的一票否决闸(firstFill /
    ///   rescore / retry 三条的第一行都看它),一个"按算法重算"的动作把它置真,等于点一下
    ///   就把这首歌永久冻结、以后算法改进也再也不许碰它,而界面上还打「人工修正」徽章 ——
    ///   那是假话。传 false 时**主动清掉**这个标记(连带导出的 .lrc 头里那行 `[manual:1]`,
    ///   否则 collector 下次启动 importLyricsFromFiles 会拿文件头把它改回来)。
    /// - score / scoringVersion: 必须**成对**传。只写版本不写分数,collector 那边
    ///   `lyricsUpgradeBaseline` 会拿 0 当基准,"必须严格更高分才替换"那道闸等于被拆掉,
    ///   一次运气差的后台重试就能把刚匹配好的结果换掉;只写分数不写版本,`needsLyricsRescore`
    ///   会在下次播放时立刻再跑一轮(首次判定不受 1 小时节流约束)。
    /// - sourcesSeen / sourcesResponded / resolvedDurationSecs / decision: 照 collector 的
    ///   `rescoreLyrics` 实际写进 enrichEntry 的那一套。少写 sourcesSeen 会让 retry 的
    ///   `nativeMissedOut` 拿上一轮的名单算;少写 resolvedDuration 会让 `wrongDuration`
    ///   凭空为真;不写 decision,「解析决策」弹窗展示的就还是被替换掉那份歌词的存档。
    /// - Parameter sourceChoice: 「用户选定了哪个源」。传非空字符串 = 记下这个选择;传空
    ///   字符串 = **显式清掉**(交回算法自由选源);传 nil = 不动这个字段。
    ///   语义见 collector 侧 `enrichEntry.LyricsSourceChoice` 的注释:它跟 `markManual`
    ///   是两件事 —— 那个说"我改过正文,别碰",这个只说"我要这个源的词"。
    /// - Parameter fromManualPick: 这一笔是不是「采纳一条候选」(三个入口:歌词管理、悬浮窗
    ///   ⚙「搜索歌词…」小窗、歌词窗口内的搜索)。传 true 会写下内容指纹 `manual_pick_sha`,
    ///   供「手动选定歌词后锁定」开关**追溯**用;传 false(默认)会把它清掉。详见写入处的
    ///   注释与 `applyManualPickLock`。它跟 `markManual` 正交:markManual 决定"现在锁不锁",
    ///   这个只决定"以后开关打开时要不要把这首歌算进去"。
    /// - Returns: collector 有没有执行成功。「采纳候选」的面板等着它
    ///   决定挪不挪「当前使用」徽标、给成功还是失败的回声;失败原因照旧写在 `lastError`。
    ///   老调用点不关心结果,所以 `@discardableResult`。
    @discardableResult
    public func saveEdit(key: String, lyrics: String, tr: String, roma: String, yrc: String? = nil,
                         source: String? = nil, markManual: Bool = true,
                         sourceChoice: String? = nil, fromManualPick: Bool = false,
                         score: Int? = nil, scoringVersion: Int? = nil,
                         resolvedDurationSecs: Double? = nil,
                         sourcesSeen: [String]? = nil, sourcesResponded: [String]? = nil,
                         decision: [String: Any]? = nil) async -> Bool {
        // 字段规则(译文换了清译文记录、罗马音描述旧正文就清掉、采纳留内容指纹……)都在 collector 的
        // applySaveEdit,这里只把参数原样交过去。nil 的参数不传 = collector 那边不动这个字段。
        var fields: [String: Any] = [
            "key": key, "lyrics": lyrics, "tr": tr, "roma": roma,
            "mark_manual": markManual, "from_manual_pick": fromManualPick,
        ]
        if let yrc { fields["yrc"] = yrc }
        if let source, !source.isEmpty { fields["source"] = source }
        if let sourceChoice { fields["source_choice"] = sourceChoice }
        if let score, let scoringVersion {
            fields["score"] = score
            fields["scoring_version"] = scoringVersion
        }
        if let resolvedDurationSecs, resolvedDurationSecs > 0 { fields["resolved_duration_secs"] = resolvedDurationSecs }
        if let sourcesSeen, !sourcesSeen.isEmpty { fields["sources_seen"] = sourcesSeen }
        if let sourcesResponded, !sourcesResponded.isEmpty { fields["sources_responded"] = sourcesResponded }
        if let decision { fields["decision"] = decision }
        return await commit("save_edit", fields).ok
    }

    /// 开关翻面前后要告诉用户的那几个数。
    ///
    /// 光有"改了几首"不够 —— 0 首有两种完全不同的成因(从没手动选过 / 选过但内容已被自动
    /// 换掉),界面得能分开说,否则就只剩一个静默的"什么都没发生"。见 ManualPickLock.PickState。
    public struct ManualPickLockStats: Sendable {
        /// 有留痕的总数(不论内容还在不在)。
        public var picked = 0
        /// 其中内容仍是当初选定那一份的。
        public var stillOriginal = 0
        /// 这次真会被改动的(内容还在 + 锁定状态跟目标相反)。
        public var targets = 0
    }

    public func manualPickLockStats(locking: Bool) -> ManualPickLockStats {
        var stats = ManualPickLockStats()
        for entry in raw.values {
            let state = ManualPickLock.state(
                sha: entry["manual_pick_sha"] as? String,
                lyrics: entry["lyrics"] as? String ?? "")
            guard state != .neverPicked else { continue }
            stats.picked += 1
            guard state == .original else { continue }
            stats.stillOriginal += 1
            if ((entry["manual_lyrics"] as? Bool) ?? false) != locking { stats.targets += 1 }
        }
        return stats
    }

    /// 「手动选定歌词后锁定」开关翻面时,受影响的 key。判据本身是 ManualPickLock.shouldFlip
    /// (纯函数,摆在 LyrimuseCore 里好让 selftest 够得着,见那个文件的头注);这里只负责
    /// 把缓存条目的字段喂进去。
    public func manualPickLockTargets(locking: Bool) -> [String] {
        raw.compactMap { key, entry in
            ManualPickLock.shouldFlip(
                sha: entry["manual_pick_sha"] as? String,
                lyrics: entry["lyrics"] as? String ?? "",
                isLocked: (entry["manual_lyrics"] as? Bool) ?? false,
                locking: locking
            ) ? key : nil
        }
    }

    /// 把上面那批 key 的 `manual_lyrics` 批量翻成 `locking`,返回真正改动的条数。挑哪几首、连 .lrc 文件头
    /// 一起重写,都由 collector 按同一判据做(见 collector 侧 set_manual_lock)。
    @discardableResult
    public func applyManualPickLock(_ locking: Bool) async -> Int {
        await commit("set_manual_lock", ["value": locking]).changed
    }

    /// 采纳一条"仅纯文本"候选(LyricsSearchService.Candidate.isPlainTextOnly,「搜索候选
    /// 歌词」弹窗里点"采纳为静态文本")——加,刻意**不走** saveEdit:
    ///
    /// - 不写 lyrics/lyrics_tr/lyrics_roma/lyrics_yrc 这几个"带时间戳"专用字段,改写
    ///   独立的 plain_lyrics(collector 侧 enrichEntry.PlainLyrics 头注解释了为什么必须
    ///   分开存,不能塞进 lyrics 冒充一份)——桌面悬浮歌词/灵动岛这些依赖时间戳的展示面
    ///   因此会继续如实显示"无歌词",只有「歌词窗口」会认这个新字段、走静态展示。
    /// - 不置 manual_lyrics:跟 saveEdit 里"采纳候选不算手动编辑"是同一个理由,这样以后
    ///   如果这首歌哪个源出了带时间戳的版本,自动匹配仍然能接手升级,不会被这次的纯文本
    ///   兜底永久冻结。
    /// - 不导出 .lrc 文件:plain_lyrics 没有时间戳,不是 EnrichCacheKeys.lyricsFileSuffixes
    ///   那几种导出格式能装的东西,导出该以后有真需求时再单独做,不是这次的范围。
    /// - Returns: 有没有真的落盘,同 `saveEdit`。
    @discardableResult
    public func savePlainTextEdit(key: String, plainLyrics: String, source: String) async -> Bool {
        await commit("save_plain_text", ["key": key, "plain_lyrics": plainLyrics, "plain_lyrics_source": source]).ok
    }

    /// 「重新自动匹配」按钮查到"至少一个源明确说这首是纯音乐、没有可用候选"时调用
    /// (加,蛋堡《收敛水》「关键字: Intro」案)——collector 侧 rescoreLyrics
    /// 在同样的"picked == nil 但有源给出 Instrumental 标记"局面下早就会把这个结论写进
    /// 缓存(见 enrich.go 那段"纯音乐结论也要在这条路径上落地"的注释),但这颗按钮走的是
    /// 独立的手动 -pick 路径,finishRematch 只弹了句"有源明确说这首是纯音乐"的 toast 就
    /// return——从没把这个结论写回缓存。表现:toast 说得清清楚楚,「歌词管理」列表却
    /// 死死钉在刺眼的红色「无歌词」上,永远不会自己变成「纯音乐」,除非哪天这首歌被
    /// 完整播放一遍触发后台首次解析重新走一遍(而这首歌八天前就是那条路径写的坏结论)。
    /// 只置一个字段、不碰 lyrics/manual_lyrics/source 这些——跟 collector 侧的写法一样窄。
    public func markInstrumental(key: String) async {
        await setInstrumental(key: key, true)
    }

    /// 用户在详情页手动标/撤「纯音乐」。起因:MJ《Off the Wall》的 Quincy Jones
    /// 访谈口白、《Raise!》26 秒的 Kalimba Tree 这类曲目,九个源里没有任何一个会给出
    /// instrumental 标记(lrclib 的 instrumental 字段和网易云的 pureMusic 都只覆盖它们自己
    /// 收录且标了的曲目),collector 永远拿不到"这首本来就没词"的结论,列表就永远红着「无歌词」、
    /// 补空扫描也会每隔一天(退避后翻倍)白搜一轮——这个结论只有人能下。
    /// 只置一个字段、不碰 lyrics/manual_lyrics/source,跟 markInstrumental 同一口径;撤销时把键
    /// 整个删掉(collector 侧 omitempty,false 与缺失等价)。标上之后 collector 的
    /// needsLyricsFirstFill 会直接 return——这也是这个动作真正的效果:告诉自动逻辑"别再搜了"。
    public func setInstrumental(key: String, _ value: Bool) async {
        await commit("set_instrumental", ["key": key, "value": value])
    }

    /// 一条记录会不会被 collector 的补空扫描真的拿去搜:没词、没确证纯音乐、没人工
    /// 修正(有纯文本兜底的也算——那仍不是带时间轴的词),跟 collector 侧 lyricsFillSweepCandidates
    /// 的三道硬闸同一口径;占位行不算(它此刻正在被搜)。「歌词管理」工具栏/多选面板和设置页
    /// 「歌词库」面板三处按钮上的数字都从这里来,按钮上的数就是真会被搜的条数。
    nonisolated static func isFillSweepRetryable(_ s: Summary) -> Bool {
        !s.hasLyrics && !s.isInstrumental && !s.isManual && !s.isSearching
    }

    /// 一条记录会不会被 collector 的「全量重新扫库」真的拿去重跑。判据本体在
    /// `LyrimuseCore.LyricsFullScan.tier`(selftest 覆盖,它是 collector 侧 `lyricsFullScanTier`
    /// 的镜像);这里只负责把 Summary 的字段和外部状态喂进去。
    ///
    /// - `currentScoringVersion` 来自 collector 写的状态文件(`LyricsFullScan.current`),
    ///   **不是**硬编码 —— 那个常量住在 Go 那边,抄一份到 Swift 迟早会在某次 bump 之后
    ///   悄悄算出一个假数字。
    /// - `pinnedKeys` 是 `LyricsPinStore` 的快照。这道闸补空扫描没有(它只碰没词的条目),
    ///   全量扫库必须有:换一份歌词会让用户手工听出来的时间轴校正值当场失联。
    ///
    /// 占位行(isSearching)不算:它此刻正在被搜,压根还不是缓存里的条目。
    /// - `passStart` / `pollutedKeys`:这一场的起点与结构污染的条目,见 `LyricsFullScan.tier` 与
    ///   `LyricsRetrySkip`(后者要对整份列表分组,由调用方算一次传进来)。
    nonisolated static func fullScanTier(
        _ s: Summary, currentScoringVersion: Int, pinnedKeys: Set<String>,
        passStart: Int64 = 0, pollutedKeys: Set<String> = []
    ) -> LyricsFullScan.Tier? {
        guard !s.isSearching else { return nil }
        return LyricsFullScan.tier(
            hasLyrics: s.hasLyrics,
            hasWordTiming: s.hasWordTiming,
            scoringVersion: s.lyricsScoringVersion,
            currentScoringVersion: currentScoringVersion,
            isManual: s.isManual,
            isInstrumental: s.isInstrumental,
            isPinned: pinnedKeys.contains(s.key),
            lastFillAt: s.lyricsFillAt,
            lastRescoreAt: s.lyricsRescoreAt,
            passStart: passStart,
            skipEmpty: pollutedKeys.contains(s.key)
                || LyricsRetrySkip.noAnchorGaveUp(artist: s.artist, album: s.album, fillCount: s.lyricsFillCount))
    }

    /// 结构污染的空条目,喂给 `fullScanTier`。
    nonisolated static func pollutedKeys(_ summaries: [Summary]) -> Set<String> {
        LyricsRetrySkip.pollutedKeys(summaries.filter { !$0.isSearching }.map {
            LyricsRetrySkip.Row(key: $0.key, artist: $0.artist, title: $0.title, album: $0.album,
                                isEmpty: !$0.hasLyrics && !$0.isManual && !$0.isInstrumental)
        })
    }

    /// 见 Summary.knownOnSources;判据本体在 LyrimuseCore.EnrichSourcePresence(selftest 覆盖)。
    /// nonisolated:buildSummaries 在后台跑(这个类是 @MainActor 的)。
    nonisolated static func knownOnSources(_ entry: [String: Any]) -> Bool {
        EnrichSourcePresence.knownOnSources(
            neteaseURL: entry["netease_url"] as? String,
            qqMusicURL: entry["qq_music_url"] as? String)
    }

    /// 见 Summary.lastRoundHadNoResponder;判据本体在 LyrimuseCore.EnrichSourcePresence。
    ///
    /// 这里**只做两次字典查找**,不走 `decodedDecision(for:)` 那条强类型解码路径 ——
    /// `entry` 本身已经是 JSONSerialization 解出来的 `[String: Any]`,取一个子字典的一个键
    /// 是 O(1);而那条路径要把子字典重新序列化成 Data 再 Decodable 解一遍(「JSON 双重编解码」),
    /// 正是从 rebuild 里优化掉的东西,不能因为这个字段又请回来。
    nonisolated static func lastRoundHadNoResponder(_ entry: [String: Any]) -> Bool {
        let last = entry["lyrics_decision"] as? [String: Any]
        return EnrichSourcePresence.lastRoundHadNoResponder(
            hasDecisionRecord: last != nil,
            respondedCount: (last?["sources_responded"] as? [Any])?.count ?? 0)
    }

    /// 「重新自动匹配」按钮命中 `LyricsRematchDecision.Outcome.unchanged`(可判、赢家跟现状
    /// 逐项一致)时调用——这一轮已经完整评估过,collector 侧只要 `Decidable` 就把全量候选
    /// 打分 build 进了 `pick.decisionJSON`(searchcli.go),只是没有新内容需要采纳。
    ///
    /// 呼应 collector 侧 rescoreLyrics 的既定规则:decision.go 定义 `lyrics_decision` =
    /// "最近一次评估——可能维持原状"，enrich.go 那三个写入点也是"可判的两个分支都写"，跟
    /// 这一轮赢家有没有变无关。之前这颗按钮在 `.unchanged` 直接 return,把已经算好的证据
    /// 整段扔掉——「解析决策」弹窗只停在上一次真正换过内容的那一轮,查不出"这一轮其它源
    /// 给了多少分、只是没赢"。
    ///
    /// 只置 lyrics_decision / lyrics_decision_applied 两个字段,不碰 lyrics/manual_lyrics/
    /// source 这些——跟上面 markInstrumental 一样窄。槽2(lyrics_decision_applied)也跟着
    /// 刷新:decision.go 定义槽2是"最近一次'胜者内容成为(或确认仍是)当前歌词'的评估",
    /// `.unchanged` 恰好就是"确认仍是"那一支,不是"没有新出处"。
    public func recordUnchangedRematchDecision(key: String, decisionJSON: String) async {
        guard let data = decisionJSON.data(using: .utf8),
              let decision = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        await commit("record_decision", ["key": key, "decision": decision])
    }

    /// 「歌词管理」里删除(单条 / 多选批量)。删缓存条目的同时,collector 把这几首导出过的歌词文件挪进废纸篓、
    /// 删掉判决旁路文件 —— "删除"在两边都是真删除,不留一份用户自己都不知道还在的归档。
    public func delete(key: String) async {
        await delete(keys: [key])
    }

    public func delete(keys: Set<String>) async {
        // 只删真的还在缓存里的 key —— 选中集合里可能残留已失效的 key(筛选变了 / 点过刷新 / 别处删过),
        // 混进来不会删错东西(collector 那边也只删在的),但会让"删了 N 条"和要不要打快照的判断虚高。
        let victims = isReleased
            ? keys.sorted()
            : EnrichCacheKeys.deletionPlan(selected: keys, existing: Set(raw.keys))
        guard !victims.isEmpty else { return }
        // 阈值以上才先打快照:打一份要读几千个小文件、压缩十几 MB,删一条付不起;删一条也够不上"手滑毁一片",
        // 它的兜底是 collector 把文件挪进废纸篓。
        if victims.count >= Self.autoSnapshotDeleteThreshold {
            lastAutoSnapshotURL = await LyricsBackupStore.writeAutoSnapshot(reason: "delete")
        }
        let result = await commit("delete", ["keys": victims])
        guard result.ok else { return }
        // 条目删了,「已校准」名单里对应那几条也跟着走:留着的话,这首歌下次重新解析出来的新歌词会一上来就
        // 不许后台升级,而它的校正值早就跟着旧内容作废了(校正值 key 里含内容指纹,见 LyricsPinStore)。
        // 放在删成功之后:失败时条目还在,pin 也不该丢。
        LyricsPinStore.shared.remove(keys: Set(victims))
        // 删除不可逆(单条走废纸篓,批量靠自动快照):用户事后问"我的歌词怎么少了"时,这一行是唯一能回答
        // "什么时候删的、删了几条、有没有快照"的东西。
        logger.notice("""
            delete: removed \(result.changed, privacy: .public) entries, \
            snapshot=\(self.lastAutoSnapshotURL?.lastPathComponent ?? "none", privacy: .public)
            """)
    }

    /// 「缓存占用查看 + 一键清空」里的清空 —— 真删除:缓存全清,歌词目录里认得出的歌词文件全部挪进废纸篓
    /// (只认四个歌词后缀,这个目录是用户可以自己指定的,可能还放着别的东西)。包括手动编辑 / 采纳过的内容,
    /// 这份缓存没有"哪些是临时的"之分。破坏性要在 UI 侧用强提示说清楚,这里只负责执行。
    public func clearAll() async {
        // 快照必须排在最前面:buildArchive 读的是磁盘上的 lyrics/ 文件族,清完就什么都读不到了。
        // 11 章已知坑 7 那次「833 条手工修正丢失」就是这个入口,这一层是它唯一的可恢复层。
        lastAutoSnapshotURL = await LyricsBackupStore.writeAutoSnapshot(reason: "clear")
        logger.notice("""
            clearAll: wiping \(self.raw.count, privacy: .public) entries, \
            snapshot=\(self.lastAutoSnapshotURL?.lastPathComponent ?? "none", privacy: .public)
            """)
        let result = await commit("clear_all")
        guard result.ok else { return }
        // 「已校准」名单跟着一起清:名单里那些 key 对应的条目都不在了,留着就是一份孤儿名单,collector 会继续
        // 一票否决这些歌的自动重选。(这跟「清空全部时间轴校正」是两个入口:那个清校正值,这个清内容。)
        LyricsPinStore.shared.removeAll()
    }

    /// 批量删除到几条起,值得先打一份自动快照。见 delete(keys:) 里那段注释。
    static let autoSnapshotDeleteThreshold = 5

    /// 从一份自动快照把歌词库铺回去:`LyricsBackupStore.restoreAutoSnapshot` 铺文件、留待采纳的非歌词字段,
    /// 再由它交给 collector 收进缓存(adopt_restore),最后刷新列表。返回给用户看的一句结果;nil = 读不出这份快照。
    func restoreFromAutoSnapshot(_ snapshot: LyricsBackupStore.Snapshot) async -> String? {
        guard let result = await LyricsBackupStore.restoreAutoSnapshot(snapshot) else { return nil }
        if !isReleased { await reload() }
        refreshSizeBytes()
        return String(format: L10n.t("已恢复 %d 个歌词文件（新增 %d、覆盖 %d）"),
                      result.total, result.added, result.overwritten)
    }

    /// 把一次改动交给 collector(见 EnrichEditChannel),完了按 collector 写好的盘上内容刷新列表,并让正在放的
    /// 那首重读歌词。快照没人在看(isReleased)时不读盘:改动已在 collector 那边落定,下次打开时再读。
    @discardableResult
    private func commit(_ op: String, _ fields: [String: Any] = [:]) async -> EnrichEditChannel.Result {
        editsInFlight += 1
        defer {
            editsInFlight -= 1
            scheduleReleaseIfUnheld()
        }
        let result = await EnrichEditChannel.send(op, fields)
        if !isReleased { await reload() }
        // reload 成功会清 lastError,失败原因要写在它之后。
        if result.ok {
            lastError = nil
        } else {
            lastError = String(format: L10n.t("写入本地记录文件失败：%@"), result.error ?? "")
            logger.error("enrich edit \(op, privacy: .public) failed: \(result.error ?? "", privacy: .public)")
        }
        PlaybackCoordinator.shared.refreshLyricsForCurrentTrack()
        refreshSizeBytes()
        return result
    }

    // 删完之后把工具栏那个"缓存占用"数字刷新一遍。它原来只有 reload() 会重算、clearAll()
    // 会硬置 0,单条 delete 完全不碰——删一条时误差小到没人注意,但批量删掉几百条之后,那个
    // 数字还挂着删之前的值,而它恰好就是"清空全部缓存"这个破坏性入口的标签,显示一个明显
    // 偏大的陈旧值容易让人误判。
    //
    // 只重算大小,不走 reload():没人在看快照时 commit 不 reload,而这个数字仍要跟着变;reload() 还会顺手把
    // lastError 清掉,吞掉刚刚可能产生的错误提示。
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
    /// 这一轮走到过哪条**标题反查**(collector 的 retry_method:`title-from-album` /
    /// `title-from-artist-search`),以及反查出来的曲名。两个字段成对出现,
    /// **全库只有 13 份存档(0.3%)有它们** —— 罕见,但发生时它是关于这次解析最重要的
    /// 一个事实:这份词是用**另一个曲名**找回来的,本地那个曲名压根搜不到。
    /// 所以它在面板上是一条**条件横幅**,不是查询词摘要里一个平淡的组头
    /// (跟「只有首轮一组时不显示查询词摘要」是同一个规矩:罕见 + 决定性 = 条件显示)。
    let retryMethod: String?
    let correctedTitle: String?
    /// 候选明细挪到了旁路文件、却按指纹补不回来(`DecisionSidecar`)。true 时候选表显示「明细缺失」,
    /// 而不是误报成「这一轮没有任何源给出候选」。
    let detailsExternal: Bool?
    /// 这一轮**实际问出去的每一组查询词**(collector 侧见 querylog.go)。
    /// 上面 queryArtist/queryTitle/queryAlbum 记的只是**首轮**那一组;一轮解析最多会换五种
    /// 问法(拆分重入 / 别名轮 / 首歌手变体轮 / 两种标题反查)。**老存档里没有这个字段**,
    /// 恒为 nil —— 跟 coverUrl 同一个道理,存档是当时那一刻的固化,不能事后补。
    let queriesTried: [TriedQuery]?

    /// 一组真正发出去的查询词。字段名对着 collector 的 lyricQueryRecord;这个类型走
    /// `.convertFromSnakeCase`,而这几个键都是单词、没有下划线,所以不用手写 CodingKeys。
    struct TriedQuery: Decodable, Identifiable {
        var id: String { "\(reason ?? "")|\(artist)|\(title ?? "")|\((sources ?? []).joined(separator: ","))" }
        let artist: String
        let title: String?
        /// 这一组是哪一轮问的。空 / nil = 首轮。取值全集见 collector 的 lyricQueryReason*,
        /// 中文译名在 LyricsDecisionSheet.queryReasonLabel(漏补就会在界面上印英文串)。
        let reason: String?
        /// 这一轮**只**问了这几个源(别名轮的定向重查)。空 = 没有限制。
        let sources: [String]?
    }

    struct Candidate: Decodable, Identifiable {
        var id: String { source }
        let source: String
        let score: Int
        let scoreTerms: [LyricsSearchService.ScoreTerm]?
        let title: String?
        let artist: String?
        let album: String?
        /// 这个源当时给出的封面。**老存档里没有这个字段**,所以恒为 nil ——
        /// 存档是"当时那一刻的固化",不能事后补(现在再查一次拿到的不是当时那个)。
        ///
        /// **必须叫 `coverUrl`,不能写成 `coverURL`**。这个类型走的是
        /// `.convertFromSnakeCase`(见上面 decoder 的配置),它把 `cover_url` 转成的是
        /// `coverUrl`(小写 rl),跟 `coverURL` 不相等 —— 实测坐实:写成 `coverURL` 时
        /// `decodeIfPresent` 直接给 nil,**一个封面都不会显示,而其它字段全正常**,是那种
        /// 光看代码完全看不出来的静默失效。
        ///
        /// 隔壁 `LyricsSearchService.RawCandidate` 用的是同一份 JSON 里的同一个字段,但它
        /// 写成 `coverURL` 没问题 —— 因为那边**手写了完整的 CodingKeys**(`case coverURL =
        /// "cover_url"`)、根本没开 convertFromSnakeCase。两处看着矛盾,其实是两套解码策略,
        /// 别照着那边"统一"过来。
        let coverUrl: String?
        let sourceReportedDurationSecs: Double?
        let hasWordTiming: Bool?
        let instrumental: Bool?
        /// 这条候选的正文跟**哪些**其它源高度一致。
        /// 打分那一行 `consensus +250/+150` 只说了"有几家印证",答不出"跟谁"——而
        /// "冠亚军这两份到底是不是同一份词"正是复盘微弱分差时唯一要问的问题。
        /// **老存档里没有这个字段**,恒为 nil。
        let consensusPeers: [String]?
    }
}
