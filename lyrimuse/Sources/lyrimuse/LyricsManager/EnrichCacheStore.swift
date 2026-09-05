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
// saveEdit/delete 因此在 raw[key] 字典操作之外,还调用
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
        /// 2026-08-20 接到这个界面上来:值早就存在缓存里(这个类型一直在解码它,见下面
        /// `instrumental` 那个字段),但列表和详情页都只看 hasLyrics —— 于是一整批
        /// 确证过的纯音乐(LoL 原声带那些)显示成刺眼的红色「无歌词」,跟"没搜到"混为一谈。
        /// 悬浮窗/灵动岛/歌词窗口三处一直分得清,唯独这里没有。
        public let isInstrumental: Bool
        /// 有没有 plain_lyrics(没有时间戳的纯文本兜底,见 collector 侧 enrichEntry.PlainLyrics
        /// 头注)——2026-08-30 加,理由跟 isInstrumental 那次接入一样:值早就存在缓存里
        /// (「歌词窗口」已经在读它做静态展示),但列表和详情页都只看 hasLyrics,于是这批
        /// "至少有纯文字可读"的条目显示成刺眼的红色「无歌词」,跟"什么都没有"混为一谈。
        public let hasPlainTextFallback: Bool
        /// true = 这一行不是缓存里真实存在的条目,是"这首歌正在联网搜歌词、collector
        /// 还没写出任何结论"这段窗口期的占位行(见 `LyricsManagerView.refreshPlaceholder`)。
        /// 2026-08-27 用户反馈"歌一直在放、还在首次搜歌词的时候,歌词管理里完全看不到
        /// 这一行"——根因是这个列表**只**读 collector 写的缓存文件,搜索还没出结论那段
        /// 时间文件里压根没有这个 key,不是"有但没显示"。这一行不对应 `raw` 里任何 key,
        /// 编辑/删除/重新自动匹配这些操作对它都没有意义,消费方必须先判断这个字段。
        public let isSearching: Bool
        // 这条有没有 collector 固化的解析决策记录(候选表+得分明细,见 collector/decision.go)。
        // 只作按钮显隐用 —— 完整结构 2026-08-19 起改**懒解码**(decodedDecision(for:)):
        // 原来 rebuild 时对每条带该字段的条目都做一轮 JSONSerialization.data + JSONDecoder
        // 双重编解码,而结果只有打开「解析决策」弹窗那一刻才被消费,全量急算纯属浪费。
        let hasDecision: Bool
        /// 这条的歌词内容上次真的变过是什么时候 —— 取自**导出的歌词文件的 mtime**
        /// (`lyrics/` 下 `.lrc`/`.tr.lrc`/`.roma.lrc`/`.yrc` 四个里最新的那个),
        /// nil = 磁盘上一个歌词文件都没有(压根没歌词的条目,export 会跳过它们)。
        ///
        /// 为什么用文件 mtime 而不是缓存里的时间戳字段:缓存里**没有**一个真正表达"更新
        /// 时间"的字段。2026-09-01 实测本机 3210 条的覆盖率 ——
        ///   `lyrics_decision.decided_at` 73%(而且它是"上次自动决策",手改歌词不会动它)
        ///   `translation_ts` 25% / `peripheral_ts` 9% / `lyrics_rescore_ts` 7%
        /// 全是偏科的局部时间戳。而 `lyrics/` 是六字段的权威源,**所有**写入路径都经过它
        /// (collector 的 exportLyricsFiles、App 的 saveEdit→writeLyricsFiles),覆盖率
        /// 3169/3210、缺的 41 条正好是没歌词的。
        ///
        /// 关键前提:`exportLyricsFiles` 写盘前会比对全文、逐字节相同就 `continue`
        /// (lyricsexport.go),所以 mtime 不会被"每次 collector 启动都重写一遍"冲掉。
        /// 实测本机 mtime 散布在 08-22～09-01 而不是全挤在最近一次重启,坐实了这一点。
        /// ⚠️ 哪天那个跳过逻辑被去掉,这个字段就会集体失真(全变成最后一次启动时间),
        /// 而且**表现是静默的** —— 排序看着还在工作,只是结果全错。
        let lyricsUpdatedAt: Date?
        /// 这条记录**上次被解析出来**的时刻,取自缓存里的 `ts`(collector 侧
        /// `enrichEntry.TS`,写入点 enrich.go 的 `e.TS = time.Now().Unix()`)。
        /// nil = 老条目没有这个字段。
        ///
        /// 它**不是** `lyricsUpdatedAt` 的替代品,只当次级键用:两者量纲不同 ——
        /// mtime 是"歌词正文上次真的变过",ts 是"这条上次被解析过"(重搜一轮没搜到新
        /// 东西也会把 ts 推到当下,而正文没变、mtime 不动)。全库覆盖率也更低
        /// (2026-09-02 实测 2445/3402 ≈ 72%,而 mtime 是 3169/3210 ≈ 99%)。
        ///
        /// 唯一用途见 `LyricsSortOrder`:**没有歌词文件 / 没有来源**的那一批行,
        /// 在对应排序档里本来注定是一团分不出先后的平局(退化成默认排序,看起来像
        /// "选了排序没反应"),用 ts 给这个尾块一个真实的组内顺序。
        let resolvedAt: Date?
        // ---- 预计算归一化键(2026-08-19 性能审计) ----
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

        /// ⚠️ 只给排序/筛选归并用(normPrimaryArtist、EnrichCacheStore.artistMap→
        /// distinctArtists→筛选下拉),**不再**用于列表逐行渲染的文字——2026-08-28 改掉:
        /// 同一个人如果原始标签一时中文一时英文(如"方大同"/"Khalil Fong"),会各自落进
        /// 独立的缓存条目(key 用原始写法拼),优先展示统一名会让两条本该能分清楚的记录在
        /// 列表里长得一模一样、用户区分不出这是两条不同记录(2026-08-28 用户报的真实案例:
        /// 《Gotta Make A Change》两条记录只有大小写和歌手语言不同,列表里完全没法区分)。
        /// 筛选依然按这个统一名归并(选"方大同"两条都要出来),只是"这一列具体显示哪个
        /// 字符串"改成如实展示每条记录自己的原始写法。
        var displayArtist: String { canonicalArtist.isEmpty ? artist : canonicalArtist }
    }

    @Published public private(set) var summaries: [Summary] = []
    /// reload() 正在飞——给视图层判断"这是首次打开、summaries 还没有任何内容"用,好
    /// 展示一个"正在加载"占位而不是一片空白的 List(2026-08-26,用户反馈"打开歌词管理
    /// 页面列表会白一会")。真正原因是缓存文件从上线时的 852 条/9.4MB 长到现在 1700+
    /// 条/22MB,JSONSerialization 解析这一份实测要 250ms+(见 reload() 内部注释),早就
    /// 挪到后台线程、不再卡住主线程,但"完全没内容可看"的这段等待时间本身还在,只是
    /// 之前一直显示成一片空白、看着像卡住了。
    @Published public private(set) var isLoading = false
    /// summaries 每重建一次 +1 —— 给视图侧的 filtered 缓存当失效键(见 LyricsManagerView),
    /// 数组本身没做 Equatable,靠这个代数判断"列表内容换过了没有"。
    private(set) var summariesGeneration = 0
    /// 专辑归并展示名:归并键(toSimplified+小写)→ 首见原写法。原来是 LyricsManagerView
    /// 的计算属性,每次访问全量重建(List 每物化一行就付一次 O(N) 次 ICU 变换 —— 2026-08-19
    /// 审计里本模块最重的一条),现在随 summaries 重建一次。
    @Published private(set) var albumDisplayMap: [String: String] = [:]
    /// 筛选下拉的候选集,同样随 summaries 重建一次,不再每次 body 现算。
    @Published private(set) var distinctArtists: [String] = []
    @Published private(set) var distinctAlbums: [String] = []
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
    /// (库本来就是空的,或者写盘失败)。UI 据此如实告诉用户"能不能撤回",绝不能默认
    /// 有备份 —— 那比没有备份更危险。
    @Published private(set) var lastAutoSnapshotURL: URL?

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
    ///   (2026-08-19 性能审计:App 每次激活都触发一次 reload,而绝大多数激活时文件根本
    ///   没变,整份 9.4MB 重读+解析+重建+summaries 重发布 → List 全量 diff 全是白跑;
    ///   同仓 EnrichCacheReader 早有同款 mtime 门控)。开窗 onAppear 和工具栏「刷新」
    ///   保持默认 false(显式刷新语义)。
    public func reload(onlyIfChanged: Bool = false) async {
        let cacheURL = Self.cacheURL
        if onlyIfChanged,
           let fp = Self.fileFingerprint(cacheURL),
           fp == lastLoadedFingerprint {
            return
        }
        // "缓存占用"这个数字只是工具栏一个菜单标签,不是 List 要渲染的内容——原来跟
        // JSON 解析捆在同一个 detached task 里,summaries 白白多等一轮 lyrics/ 目录扫描
        // (2026-08-26 实测约 18ms,数量小但完全没必要挡在关键路径上)。改用已有的
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
        }
        let box = ResultBox()
        // 在进 Task.detached 之前取快照:LyricsOffsetStore 是 @MainActor 单例,detached
        // 闭包跑在后台线程,不能在里面同步访问它——纯字典拷贝,提前拿一份传进去即可。
        let offsetsSnapshot = LyricsOffsetStore.shared.offsetsSnapshot
        // 同理:lyricsDir 读的是 FeatureSettingsStore.shared(MainActor),在这儿取好。
        // 真正的目录枚举(I/O)在 buildSummaries 里、也就是后台跑。
        let lyricsDir = Self.lyricsDir
        await Task.detached(priority: .userInitiated) {
            box.fingerprint = Self.fileFingerprint(cacheURL)
            guard let data = try? Data(contentsOf: cacheURL) else {
                box.errorMessage = L10n.t("读取本地记录文件失败")
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
                box.errorMessage = L10n.t("解析本地记录文件失败")
                return
            }
            box.obj = obj
            // summaries 的构建+排序也在后台做掉(2026-08-19:原来回 MainActor 同步跑,
            // 每次开窗/激活吃几十到一二百 ms 主线程),主线程只收结果赋值。
            box.bundle = Self.buildSummaries(from: obj, offsetsSnapshot: offsetsSnapshot, lyricsDir: lyricsDir)
        }.value
        if let obj = box.obj, let bundle = box.bundle {
            raw = obj
            knownKeys = Set(obj.keys)
            lastLoadedFingerprint = box.fingerprint
            // 这两个集合描述的是"相对上一份快照做了什么改动";快照整个换掉之后它们就失去
            // 参照,留着会让下一次 persist 拿旧意图去盖新内容。所有改动路径都是"改完立刻
            // persist",正常情况下它们此刻本来就是空的 —— 这里只是把不变量写死。
            locallyEditedKeys.removeAll()
            locallyDeletedKeys.removeAll()
            lastError = nil
            applySummaries(bundle)
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
    }

    // public:「歌词管理」详情页调过/重置过时间轴偏移之后也要调这个——那份改动只落在
    // LyricsOffsetStore(不是这里的 raw 字典),summaries 里预算好的 offsetMs 不会自己
    // 跟着变,得靠调用方显式喊一次重建(见 LyricsManagerView.applyOffsetEdit)。
    public func rebuildSummaries() {
        applySummaries(Self.buildSummaries(from: raw, offsetsSnapshot: LyricsOffsetStore.shared.offsetsSnapshot,
                                           lyricsDir: Self.lyricsDir))
    }

    // ⚠️ 排序键必须跟"列表上看到的那套分组"用**同一套归并规则**,否则会出现"显示层合并了、
    // 排序层还按原始写法把同一张专辑劈成两半"。2026-08-07 用户实测撞到:「春游」这张专辑
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
    /// key 现推文件名)撞上 `exportBaseName` 那个每次都扫全 `raw.keys` 的 O(n²)。实测本机
    /// 7231 个文件全 stat 一遍 23ms,这条路径比它更省,且只做一次。
    ///
    /// 取四个后缀里**最新**的那个,而不是只看主 `.lrc`:译文/罗马音/逐字时间轴后来补上
    /// 也是这条记录真的变了,用户按「更新时间」找的就是"最近动过什么"。
    ///
    /// 键要**折叠成小写**:同一个 key 可能对应普通名或带哈希后缀的消歧名(见
    /// `exportBaseName`),而这台文件系统大小写不敏感 —— 折叠后两种形态都能被调用方用
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
        // 指纹(见 LyricsOffsetStore.contentFingerprint)——2026-08-26 实测坐实:对全部
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
            let lyricsYRC = entry["lyrics_yrc"] as? String ?? ""
            let canonical = entry["canonical_artist"] as? String ?? ""
            let display = canonical.isEmpty ? parts.artist : canonical
            // trackKey 要用播放时真正生效的那份内容指纹,所以拿这条原始 artist/title(跟
            // 播放侧同一套归一化,见 LyricsOffsetStore.trackKey 内部的说明),不是展示名。
            let offsetPrefix = "\(EnrichCacheKeys.cleanTag(parts.artist))|\(EnrichCacheKeys.normalizedTitle(parts.title))"
            let offsetMs: Int
            if offsetPrefixes.contains(offsetPrefix) {
                let offsetKey = LyricsOffsetStore.trackKey(artist: parts.artist, title: parts.title,
                                                            lyrics: lyrics, lyricsYRC: lyricsYRC)
                offsetMs = offsetsSnapshot[offsetKey] ?? 0
            } else {
                offsetMs = 0
            }
            return Summary(
                key: key,
                artist: parts.artist,
                canonicalArtist: canonical,
                // 2026-08-30 从「优先 duration_secs」改成「优先 resolved_duration_secs」——
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
                hasWordTiming: !lyricsYRC.isEmpty,
                isManual: entry["manual_lyrics"] as? Bool ?? false,
                sourceChoice: entry["lyrics_source_choice"] as? String ?? "",
                offsetMs: offsetMs,
                lyricsTrSource: entry["lyrics_tr_source"] as? String ?? "",
                hasTranslation: !((entry["lyrics_tr"] as? String ?? "").isEmpty),
                hasRomanization: !((entry["lyrics_roma"] as? String ?? "").isEmpty),
                hasLyrics: !lyrics.isEmpty,
                isInstrumental: entry["instrumental"] as? Bool ?? false,
                hasPlainTextFallback: !((entry["plain_lyrics"] as? String ?? "").isEmpty),
                isSearching: false, // 这一条来自 raw,真实存在;占位行的构造点在 LyricsManagerView
                hasDecision: entry["lyrics_decision"] != nil || entry["lyrics_decision_applied"] != nil,
                // 两次 O(1) 查找:普通名、以及带哈希后缀的消歧名(见 exportBaseName —— 到底
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
        for s in items {
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
            distinctAlbums: Array(Set(albumMap.values)).sorted()
        )
    }

    /// 这条最近一次自动匹配成功时用的时长(`resolved_duration_secs`)。给「重新自动匹配」
    /// 当兜底——Summary.durationSecs 现在本身已经优先取这个字段(2026-08-30 起,见
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
    /// ⚠️ 2026-08-30 真实bug(蛋堡《嘶! Bamboo Holla》,专辑"收斂水"/"收敛水"繁简两种写法):
    /// 原来只做精确字典查找,而占位行的 key 是**当下这一刻**播放器实时上报的
    /// artist/title/album 拼出来的(EnrichCacheKeys.normalizedKey,不含繁简折算)——
    /// collector 那条 enrichKey 同样不折算(必须跟 Apple Music/播放器原始标签逐字节一致,
    /// 见 enrich.go 那段注释),于是同一首歌只要播放器这次上报的专辑名繁简写法跟当初解析
    /// 那次不一样,拼出来的 key 就对不上已经写盘的那一条——即便磁盘里其实早就有真实的、
    /// 带着完整歌词的记录,这里也会永远判"没有",占位行"正在搜索…"就卡死不会让位(其它
    /// 视图能正常显示歌词,是因为它们走的是 EnrichCacheReader 的宽松匹配,那边已经在用
    /// EnrichCacheKeys.looseKey 折算繁简,只有这条独立维护的精确查找漏了这一层)。
    /// 精确命中优先(常见情况,零额外开销),精确查不到才退化成宽松扫描——这条只在"正在
    /// 搜索"占位行还没让位时才会被调用(5 秒轮询一次,见 refreshPlaceholder 调用点的
    /// 注释),不是热路径,线性扫一遍 raw 的 key 完全负担得起。
    public func hasEntry(forKey key: String) -> Bool {
        if raw[key] != nil { return true }
        let loose = EnrichCacheKeys.looseKey(key)
        return raw.keys.contains { EnrichCacheKeys.looseKey($0) == loose }
    }

    /// 懒解码某条的解析决策记录 —— 只在打开「解析决策」弹窗那一刻按 key 解一条,
    /// 见 Summary.hasDecision 的注释。
    func decodedDecision(for key: String) -> LyricsResolutionDecision? {
        Self.decodeDecision(raw[key]?["lyrics_decision"])
    }

    /// 「当前歌词的出处」那一槽(lyrics_decision_applied,collector 2026-08-22 起分槽写入)。
    /// 跟上面的 lyrics_decision(最近一次评估,可能维持原状、甚至输入是脏的)是两份记录:
    /// 一轮没采纳的评估会盖掉 lyrics_decision,但不动这一槽 ——「解析决策」弹窗靠它才能
    /// 永远解释"现在这份词是谁、凭什么选的"。老条目(分槽前写入)没有这一槽,弹窗侧有
    /// "最近评估恰好 applied 就当出处"的退路(见 LyricsDecisionSheet.init)。
    func decodedAppliedDecision(for key: String) -> LyricsResolutionDecision? {
        Self.decodeDecision(raw[key]?["lyrics_decision_applied"])
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
    // 大,「移除逐字时间轴」入口 2026-08-18 已删)。只有"联网搜索候选歌词"整条采纳某个候选时才会传非 nil:
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
    /// - Returns: 有没有真的落盘(`persist()` 的结果;2026-09-04 起)。「采纳候选」的面板等着它
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
        // 正文改了、而罗马音是原样交回来的 → 那份罗马音描述的是**旧正文**,必须清掉。
        // 跟上面 lyrics_tr_lang/lyrics_tr_source 那条是同一条规矩:别拿旧内容给新内容背书。
        //
        // ⚠️ 这条 2026-09-03 才补,而它治的问题**是同日那次改动放大出来的**:collector 新增
        // 了日/韩/中罗马音预生成(第 10 章 §5),缓存里带 lyrics_roma 的条目从 117 涨到 2133
        // (3.3% → 60%)。在那之前绝大多数歌的 lyrics_roma 是空的,用户改完正文,App 侧
        // `Romanizer` 的客户端兜底会按新正文现算,结果是对的;现在 lyrics_roma 非空,
        // `LyricsSyncEngine.romanizationText` 会**优先用缓存里这份**(按行内容匹配不上就退
        // 700ms 就近匹配),于是改过的那几行显示的是旧正文的读音 —— 而且是静默的。
        //
        // 判据是"roma 跟存着的那份逐字相同",也就是用户**没动**罗马音编辑框那一格。他自己
        // 改过就按他的来,不替他清。
        let previousLyrics = raw[key]?["lyrics"] as? String ?? ""
        let previousRoma = raw[key]?["lyrics_roma"] as? String ?? ""
        let romaDescribesOldLyrics =
            !roma.isEmpty && lyrics != previousLyrics && roma == previousRoma
        let effectiveRoma = romaDescribesOldLyrics ? "" : roma
        entry["lyrics"] = lyrics
        entry["lyrics_tr"] = tr
        entry["lyrics_roma"] = effectiveRoma
        if markManual {
            entry["manual_lyrics"] = true
        } else {
            entry.removeValue(forKey: "manual_lyrics")
        }
        // 用户选定的源。**必须在 markManual 分支之外** —— 这条机制的整个要点就是
        // 「采纳一条候选」不再置 manual_lyrics(那会永久冻结这首歌),而是只记下选了哪个源,
        // 所以它恰恰是在 markManual == false 的那条路径上写的。写在 if 里面等于永远写不到。
        //
        // nil = 不动这个字段(普通的保存/编辑不该悄悄改它);空串 = 显式清掉(「交回算法」)。
        // 见 saveEdit 的参数注释与 collector 侧 enrichEntry.LyricsSourceChoice。
        if let sourceChoice {
            if sourceChoice.isEmpty {
                entry.removeValue(forKey: "lyrics_source_choice")
            } else {
                entry["lyrics_source_choice"] = sourceChoice
            }
        }
        // 打分留痕:成对写(理由见上面的参数注释)。传 nil 就一个都不动 —— 手动编辑改的是
        // 正文,旧分数虽然已经不描述新内容了,但那条路径靠 manual_lyrics 整个关掉了自愈,
        // 不会有人拿这个分数去做比较。
        if let score, let scoringVersion {
            entry["lyrics_score"] = score
            entry["lyrics_scoring_version"] = scoringVersion
        }
        if let resolvedDurationSecs, resolvedDurationSecs > 0 {
            entry["resolved_duration_secs"] = resolvedDurationSecs
        }
        if let sourcesSeen, !sourcesSeen.isEmpty { entry["lyrics_sources_seen"] = sourcesSeen }
        if let sourcesResponded, !sourcesResponded.isEmpty {
            entry["lyrics_sources_responded"] = sourcesResponded
        }
        // 两槽一起写:decision 只在「重新自动匹配」**采纳**那条路径传进来(finishRematch
        // 已把 applied 覆写成 true),采纳即"当前歌词的出处",跟 collector 侧三个自动
        // 写入站点的分槽规则一致(见 collector/decision.go 的两槽说明)。
        if let decision {
            entry["lyrics_decision"] = decision
            entry["lyrics_decision_applied"] = decision
        }
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
        // 「这份内容是用户手动采纳的候选」的留痕。**纯记录,零行为影响** —— collector
        // 一个字节都不读它(grep manual_pick_sha 在 lyrimuse-collector/ 下应该零命中),
        // 它唯一的消费方是 applyManualPickLock:「手动选定歌词后锁定」开关被打开时,
        // 靠它找出"哪些歌是用户手动选的、而且当前这份内容还就是他选的那一份"。
        //
        // ⚠️ 存内容指纹而不是一个 bool,是这套机制成立的关键:关态下这首歌随时可能被自愈
        // 路径换成别的版本(那正是关态的语义),那之后再打开开关,锁住的就会是一份用户
        // **从没选过**的内容。指纹对不上 = 我选的那份已经不在了 = 不锁,这条判断是自证的,
        // 不依赖 collector 任何一处"换歌词时记得清标记"的配合(那种分散的清理点漏一处
        // 就错,而且错得无声)。
        //
        // 由 saveEdit 自己按刚写进去的正文算,不让调用方传 —— 调用方传的话就有"指纹算的
        // 是另一份内容"这种对不上的可能。非手动采纳的路径(手改正文/重新自动匹配)一律
        // 清掉:它们都重写了 lyrics,旧指纹既已失效也没有意义。
        // 指纹为空(正文只剩元数据标签、归一化后没有词)时同样按"没有留痕"处理 —— 写一个
        // 空字符串进去只会多一个永远匹配不上的字段。
        let pickSHA = fromManualPick ? ManualPickLock.fingerprint(lyrics: lyrics) : ""
        if pickSHA.isEmpty {
            entry.removeValue(forKey: "manual_pick_sha")
        } else {
            entry["manual_pick_sha"] = pickSHA
        }
        raw[key] = entry
        markLocallyEdited(key)
        writeLyricsFiles(
            key: key, lyrics: lyrics, tr: tr, roma: effectiveRoma,
            yrc: entry["lyrics_yrc"] as? String ?? "",
            source: entry["lyrics_source"] as? String ?? "",
            manual: markManual
        )
        // 顺序照 delete(keys:)(2026-08-19 接上):先刷列表(界面立刻反馈),再落盘,重启
        // 走不阻塞的后台排队 —— 原来这里 await persistAndRestart() 会原地等 collector
        // 重启,launchctl kickstart 撞上 launchd 的 minimum runtime 时一等就是 ~10 秒,
        // 「已保存」反馈/offset 输入框/列表徽章全被闷在后面,期间按钮还能重复点。
        // scheduleCollectorRestart 自带合并/补偿/lastError/refreshLyricsForCurrentTrack。
        rebuildSummaries()
        guard await persist() else { return false }
        if lastPersistPulledInNewKeys { rebuildSummaries() }
        scheduleCollectorRestart()
        return true
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

    /// 把上面那批 key 的 `manual_lyrics` 批量翻成 `locking`,返回真正改动的条数。
    ///
    /// ⚠️ **必须连 .lrc 文件头一起重写**。导出的歌词文件头里那行 `[manual:1]` 是这个标记的
    /// 第二份存档,collector 启动时 importLyricsFromFiles 会拿文件头把缓存里的值改回去
    /// (saveEdit 的 markManual 注释里踩过同一个坑)。只改 JSON 的话,这次批量锁定/解锁
    /// 会在下次 collector 重启时被静默回滚 —— 而且回滚得毫无痕迹。
    @discardableResult
    public func applyManualPickLock(_ locking: Bool) async -> Int {
        let targets = manualPickLockTargets(locking: locking)
        guard !targets.isEmpty else { return 0 }
        for key in targets {
            guard var entry = raw[key] else { continue }
            if locking {
                entry["manual_lyrics"] = true
            } else {
                entry.removeValue(forKey: "manual_lyrics")
            }
            raw[key] = entry
            markLocallyEdited(key)
            writeLyricsFiles(
                key: key,
                lyrics: entry["lyrics"] as? String ?? "",
                tr: entry["lyrics_tr"] as? String ?? "",
                roma: entry["lyrics_roma"] as? String ?? "",
                yrc: entry["lyrics_yrc"] as? String ?? "",
                source: entry["lyrics_source"] as? String ?? "",
                manual: locking
            )
        }
        rebuildSummaries()
        guard await persist() else { return 0 }
        if lastPersistPulledInNewKeys { rebuildSummaries() }
        scheduleCollectorRestart()
        return targets.count
    }

    /// 采纳一条"仅纯文本"候选(LyricsSearchService.Candidate.isPlainTextOnly,「搜索候选
    /// 歌词」弹窗里点"采纳为静态文本")——2026-08-30 加,刻意**不走** saveEdit:
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
        var entry = raw[key] ?? [:]
        entry["plain_lyrics"] = plainLyrics
        if source.isEmpty {
            entry.removeValue(forKey: "plain_lyrics_source")
        } else {
            entry["plain_lyrics_source"] = source
        }
        raw[key] = entry
        markLocallyEdited(key)
        rebuildSummaries()
        guard await persist() else { return false }
        if lastPersistPulledInNewKeys { rebuildSummaries() }
        scheduleCollectorRestart()
        return true
    }

    /// 「重新自动匹配」按钮查到"至少一个源明确说这首是纯音乐、没有可用候选"时调用
    /// (2026-08-30 加,蛋堡《收敛水》「关键字: Intro」案)——collector 侧 rescoreLyrics
    /// 在同样的"picked == nil 但有源给出 Instrumental 标记"局面下早就会把这个结论写进
    /// 缓存(见 enrich.go 那段"纯音乐结论也要在这条路径上落地"的注释),但这颗按钮走的是
    /// 独立的手动 -pick 路径,finishRematch 只弹了句"有源明确说这首是纯音乐"的 toast 就
    /// return——从没把这个结论写回缓存。表现:toast 说得清清楚楚,「歌词管理」列表却
    /// 死死钉在刺眼的红色「无歌词」上,永远不会自己变成「纯音乐」,除非哪天这首歌被
    /// 完整播放一遍触发后台首次解析重新走一遍(而这首歌八天前就是那条路径写的坏结论)。
    /// 只置一个字段、不碰 lyrics/manual_lyrics/source 这些——跟 collector 侧的写法一样窄。
    public func markInstrumental(key: String) async {
        var entry = raw[key] ?? [:]
        entry["instrumental"] = true
        raw[key] = entry
        markLocallyEdited(key)
        rebuildSummaries()
        guard await persist() else { return }
        if lastPersistPulledInNewKeys { rebuildSummaries() }
        scheduleCollectorRestart()
    }

    /// 「重新自动匹配」按钮命中 `LyricsRematchDecision.Outcome.unchanged`(可判、赢家跟现状
    /// 逐项一致)时调用——这一轮已经完整评估过,collector 侧只要 `Decidable` 就把全量候选
    /// 打分 build 进了 `pick.decisionJSON`(searchcli.go),只是没有新内容需要采纳。
    ///
    /// 呼应 collector 侧 rescoreLyrics 的既定规则:decision.go 定义 `lyrics_decision` =
    /// "最近一次评估——可能维持原状"，enrich.go 那三个写入点也是"可判的两个分支都写"，跟
    /// 这一轮赢家有没有变无关。之前这颗按钮在 `.unchanged` 直接 return,把已经算好的证据
    /// 整段扔掉——「解析决策」弹窗只停在上一次真正换过内容的那一轮,查不出"这一轮其它源
    /// 给了多少分、只是没赢"(2026-09-01 用户指出)。
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
        var entry = raw[key] ?? [:]
        entry["lyrics_decision"] = decision
        entry["lyrics_decision_applied"] = decision
        raw[key] = entry
        markLocallyEdited(key)
        rebuildSummaries()
        guard await persist() else { return }
        if lastPersistPulledInNewKeys { rebuildSummaries() }
        scheduleCollectorRestart()
    }

    // 「移除逐字时间轴」的实现(removeWordTiming)2026-08-19 删除:按钮 2026-08-18 已按
    // 用户要求去掉,函数失去唯一调用方之后只是一段每次改保存链路都要陪着改的死代码。
    // 想恢复见 git 历史 —— JSON 侧清 lyrics_yrc 字段 + 删两种形态的 .yrc 文件,
    // 加回来时记得走 delete(keys:) 同款的「先刷列表 → 落盘 → 后台排队重启」顺序。

    // 删缓存条目的同时一并删掉对应的已导出文件——「歌词管理」里点删除,"删除"在两边
    // 都是真删除,不留一份用户自己都不知道还在的归档文件。
    //
    // ⚠️ 删文件必须排在落盘+重启之前——2026-08-02 实测排查坐实:早先这里的
    // 顺序反了(先重启 collector、后删文件),跟本文件里 saveEdit/
    // clearAll 建立的"先落盘文件、再重启 collector"顺序正相反。collector
    // main() 每次启动都固定跑 loadEnrichCache → importLyricsFromFiles →
    // exportLyricsFiles;importLyricsFromFiles 只要在 lyrics/ 目录下还看到这个 key 对应
    // 的文件,就会把文件内容当"新条目"重新写回 enrichCache 并无条件存盘——也就是说,
    // 如果文件删除排在重启之后,collector 重启那一刻磁盘上这些文件必然还在(Swift 侧还
    // 没删),会在 collector 启动阶段就把刚删除的条目复活并写回磁盘,不需要等用户之后
    // 再听一首歌才触发。现在改成先删文件、让 collector 重启时看到的磁盘状态已经是
    // "没有这个 key"。
    //
    // 2026-08-05 实测排查坐实的卡顿修复:原来这里是同步等 collector 重启完之后才
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
        // 批量删除同样先打快照,阈值以上才打。
        //
        // 为什么设阈值而不是每次都打:打一份要读几千个小文件 + 压缩 14.5 MB(实测几百毫秒到
        // 一秒级),删一条歌就付这个代价不合算,而删一条本来也够不上"手滑毁一片"。阈值以上
        // 才是真正会让人后悔的那种操作 —— 跟「清空全部」同一类。
        // 单条删除的兜底是下面的废纸篓(deleteExportedLyricsFile),不是快照。
        if victims.count >= Self.autoSnapshotDeleteThreshold {
            lastAutoSnapshotURL = await LyricsBackupStore.writeAutoSnapshot(reason: "delete")
        }
        var removed: [String: [String: Any]] = [:]
        removed.reserveCapacity(victims.count)
        for key in victims {
            if let entry = raw.removeValue(forKey: key) { removed[key] = entry }
            locallyDeletedKeys.insert(key)
            locallyEditedKeys.remove(key)
            deleteExportedLyricsFile(forKey: key)
        }
        rebuildSummaries()
        guard await persist() else {
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
        // 条目删了,「已校准」名单里对应那几条也该跟着走:留着的话,这首歌下次重新解析出来
        // 的新歌词会莫名其妙一上来就不许后台升级 —— 而它的校正值早就跟着旧内容作废了
        // (校正值 key 里含内容指纹,见 LyricsPinStore)。刻意放在 persist() 成功**之后**:
        // 上面写盘失败那条分支会把条目原样放回去,那种情况下 pin 也不该丢。
        LyricsPinStore.shared.remove(keys: Set(victims))
        scheduleCollectorRestart()
        refreshSizeBytes()
    }

    // "缓存占用查看 + 一键清空"里的清空动作——真删除,不是软标记:清空 JSON 侧的 raw
    // 字典、删掉 lyrics/ 权威源文件夹下的每一个文件(包括手动编辑/联网搜索采纳过的
    // 内容,这份缓存设计上没有"哪些是临时的、哪些是用户产出"的区分,清空就是全清)。
    // destructive 程度需要在 UI 侧用强提示词说清楚,这里只负责真正执行。
    public func clearAll() async {
        // ⚠️ 快照必须排在**最前面**,在 raw 被清空、文件被删掉之前 —— buildArchive 读的是
        // 磁盘上的 lyrics/ 文件族,晚一步就什么都读不到了。
        //
        // 为什么非要有这一层:docs/features/11 已知坑 7 那次「833 条手工修正丢失」,在此之前
        // 的代码上会一字不差地重演 —— 确认弹窗只是提示,落地动作(整份替换落盘 +
        // deleteAllLyricsFiles)没有任何可恢复层。清空还会连带 LyricsPinStore.removeAll(),
        // 用户一句句听出来的时间轴对应的 pin 也一起没,而快照里正好带着 pins。
        lastAutoSnapshotURL = await LyricsBackupStore.writeAutoSnapshot(reason: "clear")
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
        guard await persist(replacingEverything: true) else { return }

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
        // 「已校准」名单跟着一起清(2026-08-21 补)。这个入口清掉的是**全部**歌词内容 ——
        // 名单里那些 key 对应的条目都不在了,留着它就是一份孤儿名单:collector 继续一票否决
        // 这些歌的自动重选,而它保护的东西(用户手调出来的时间轴)随着条目一起没了。
        // 注意这跟「清空全部时间轴校正」是两个入口:那个清校正值(并连带清名单),这个清内容。
        LyricsPinStore.shared.removeAll()

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
            guard await persist(replacingEverything: true) else { return }
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

    /// 批量删除到几条起,值得先打一份自动快照。见 delete(keys:) 里那段注释。
    static let autoSnapshotDeleteThreshold = 5

    /// 从一份自动快照把歌词库铺回去,并让 collector 把它重新读进缓存。
    ///
    /// 顺序不能动:
    ///   1. 先铺文件 —— `lyrics/` 文件族是歌词六字段的**权威源**;
    ///   2. 再重启 collector —— 它启动时跑 `importLyricsFromFiles`(文件赢),照着刚铺回去的
    ///      文件重建缓存条目。这一步是恢复真正生效的地方,不是"顺手刷新一下";
    ///   3. 最后 reload 列表 + 让当前播放的那首重读歌词。
    /// 反过来先重启再铺文件的话,collector 读到的是还没恢复的目录,等于白铺。
    ///
    /// 返回给用户看的一句结果;nil 表示读不出这份快照。
    func restoreFromAutoSnapshot(_ snapshot: LyricsBackupStore.Snapshot) async -> String? {
        guard let result = await LyricsBackupStore.restoreAutoSnapshot(snapshot) else { return nil }
        _ = await CollectorControl.restartAndWaitAsync()
        await reload()
        PlaybackCoordinator.shared.refreshLyricsForCurrentTrack()
        refreshSizeBytes()
        return String(format: L10n.t("已恢复 %d 个歌词文件（新增 %d、覆盖 %d）"),
                      result.total, result.added, result.overwritten)
    }

    /// 删一个歌词文件。**走废纸篓,不是永久删。**
    ///
    /// 这些文件是 `lyrics/` 文件族 —— 歌词六字段的权威源,里面有用户手工修正过的内容,
    /// 而 `lyricsDir` 还是用户可以在设置里自己指定的目录。进废纸篓意味着"删错了还能捞
    /// 回来",代价只是用户偶尔要去清一下废纸篓。
    ///
    /// trashItem 失败时退回 removeItem:目标卷可能压根没有废纸篓(外置卷、网络卷、某些
    /// 同步盘),那时候仍然要把文件删掉 —— 否则残留文件会在 collector 下次启动
    /// `importLyricsFromFiles`(文件赢)时把刚删掉的条目整个复活回来,表现成"删了又回来"。
    /// 正确性优先于可恢复性,但只在拿不到废纸篓时才降级。
    private static func trashOrRemove(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 删掉 lyrics/ 目录下的歌词文件。按后缀白名单过滤,理由见 clearAll 里那段注释
    /// (这个目录是用户可以自己指定的,无差别删除会波及无关文件)。
    private func deleteAllLyricsFiles() {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: Self.lyricsDir, includingPropertiesForKeys: nil) else {
            return
        }
        for url in urls where EnrichCacheKeys.lyricsFileSuffixes.contains(where: { url.lastPathComponent.hasSuffix($0) }) {
            Self.trashOrRemove(url)
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
    // 预期内的情况去污染 lastError(那个留给 persist/重启这些真正的主体操作失败用)。
    // lyricsFileSuffixes 全部 4 个后缀都试一遍,跟 writeLyricsFiles 对称——"删除"要
    // 清掉整个歌词文件族,不只是纯歌词那一份。
    private func deleteExportedLyricsFile(forKey key: String) {
        for name in EnrichCacheKeys.exportedFileNames(forKey: key) {
            let url = Self.lyricsDir.appendingPathComponent(name)
            // 文件不存在是常态(这条从来没有译文/罗马音/逐字),先看一眼再动手 —— 否则
            // trashItem 会对每一个不存在的路径抛一次错、白走一遍降级分支。
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            Self.trashOrRemove(url)
        }
    }

    // lyricsFileSuffixes 跟 collector/lyricsexport.go 的同名变量逐一对应。
    private static let lyricsFileSuffixes = EnrichCacheKeys.lyricsFileSuffixes

    // writeLyricsFiles 把 saveEdit 对 raw[key] 做的改动,同步写成 lyrics/ 文件夹下对应的
    // 文件,跟 collector/lyricsexport.go 的 exportLyricsFiles/lyricsFileHeader 是同一份
    // 头部格式的两处独立实现(理由同 sanitizeLyricsFilename——纯粹是确定性的字符串拼接,
    // 不属于必须收敛成一份的逻辑)。每个变体单独判断:有内容就写,没内容就删除对应
    // 文件,跟 Go 那边"该有就写、不该有就删"对应。这里不处理 Go 那边"检测大小写文件名
    // 碰撞、加哈希后缀消歧"那一步——每次调用后紧跟的落盘+排队重启会重启
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

    // persist 串行链:异步化(见 performPersist)之后,await 期间主线程可以继续响应用户
    // 操作,理论上能出现"上一笔还在写盘、下一笔已经发起"。链式排队让两笔绝不并发读写
    // 同一个文件(2026-08-14 那次数据磨损事故就是并发保存路径,不能重新引入)。
    private var persistChain: Task<Bool, Never>?

    /// 把 raw 落盘,不碰 collector。返回是否成功——调用方据此决定要不要回滚内存状态。
    ///
    /// 2026-08-19 起整段读-改-写(读盘 9.4MB + 解析 + merge + 序列化 + 原子写)挪到后台
    /// (照 reload() 的模式):原来同步在 MainActor 上做,:584 老注释说的「26ms 没问题」
    /// 只量了序列化+写盘那后半段,2026-08-14 加的读-改-写又叠了一次全量读盘+解析
    /// (本文件顶部自证 30ms+ 且随缓存线性增长),每次保存/删除主线程停 55-80ms,
    /// 20Hz 悬浮歌词逐字填色跟着顿一拍。
    /// - Parameter replacingEverything: 用户明确要求"整份替换"(清空全部缓存)时传 true,
    ///   跳过读-改-写合并 —— 那种场景下把盘上内容并回来正是要避免的。
    @discardableResult
    private func persist(replacingEverything: Bool = false) async -> Bool {
        let previous = persistChain
        let task = Task { [weak self] () -> Bool in
            _ = await previous?.value // 串行化:等上一笔完全落盘再开始
            guard let self else { return false }
            return await self.performPersist(replacingEverything: replacingEverything)
        }
        persistChain = task
        return await task.value
    }

    private func performPersist(replacingEverything: Bool) async -> Bool {
        guard JSONSerialization.isValidJSONObject(raw) else {
            lastError = L10n.t("内部数据不是合法 JSON,已放弃保存")
            logger.error("raw dict is not valid JSON, aborting save")
            return false
        }
        // 快照本笔的输入并**立即取走**意图集合 —— 后台写盘期间新发生的编辑/删除会重新
        // 填这两个集合、由链上排队的下一笔 persist 负责;失败时把本笔意图放回(union)。
        let memory = raw
        let edited = locallyEditedKeys
        let deleted = locallyDeletedKeys
        locallyEditedKeys.removeAll()
        locallyDeletedKeys.removeAll()
        let cacheURL = Self.cacheURL
        final class ResultBox: @unchecked Sendable {
            var merged: [String: [String: Any]]?
            var pulledNew = false
            var errorMessage: String?
            var ok = false
        }
        let box = ResultBox()
        await Task.detached(priority: .userInitiated) {
            // 读-改-写:以**盘上此刻的内容**为底,只把用户这次真正动过的 key 盖上去。
            //
            // 2026-08-14 之前这里是"整份覆盖 + 只并回没见过的新 key"。那半套只堵住了一半:
            // "歌词管理"是可以一直开着的窗口,开窗之后 collector 会持续往盘上写 —— 新歌是
            // 新 key,给**已有 key 补机翻译文/逐字时间轴/封面**是原地更新,整份覆盖会把
            // 它们静默回滚掉。合并规则抽在 LyrimuseCore.EnrichCacheMerge,selftest 覆盖。
            var target = memory
            var pulledNew = false
            if !replacingEverything,
               let disk = try? Data(contentsOf: cacheURL),
               let diskObj = try? JSONSerialization.jsonObject(with: disk) as? [String: [String: Any]] {
                let merged = EnrichCacheMerge.merge(
                    disk: diskObj, memory: memory, edited: edited, deleted: deleted)
                pulledNew = !Set(merged.keys).subtracting(memory.keys).isEmpty
                target = merged
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: target)
                try data.write(to: cacheURL, options: .atomic)
                box.merged = target
                box.pulledNew = pulledNew
                box.ok = true
            } catch {
                box.errorMessage = error.localizedDescription
            }
        }.value
        guard box.ok else {
            // 失败:把本笔意图放回,让调用方的回滚/下一次保存还带着它们。
            locallyEditedKeys.formUnion(edited)
            locallyDeletedKeys.formUnion(deleted)
            lastError = String(format: L10n.t("写入本地记录文件失败: %@"), box.errorMessage ?? "")
            logger.error("write failed: \(box.errorMessage ?? "", privacy: .public)")
            lastPersistPulledInNewKeys = false
            return false
        }
        lastPersistPulledInNewKeys = box.pulledNew
        if let merged = box.merged {
            if locallyEditedKeys.isEmpty && locallyDeletedKeys.isEmpty {
                // 常态:后台写盘期间没有新修改,回写整份 merged("写完之后 raw 就是盘上
                // 最新内容,列表标记不再停留在开窗那一刻"的既有语义)。
                raw = merged
                knownKeys = Set(merged.keys)
            } else {
                // 罕见:await 窗口里用户又编辑/删除了 —— 整份回写会把那些还没落盘的新
                // 修改用盘上旧值盖掉(真丢数据)。只并入盘上新增的 key,新意图对应的
                // 条目保持内存现状,由链上排队的下一笔 persist 落盘。
                for (k, v) in merged where raw[k] == nil && !locallyDeletedKeys.contains(k) {
                    raw[k] = v
                }
                knownKeys = Set(raw.keys)
            }
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
            if !ok { self.lastError = L10n.t("后台采集服务重启失败") }
            PlaybackCoordinator.shared.refreshLyricsForCurrentTrack()
            if self.needsFollowUpRestart {
                self.needsFollowUpRestart = false
                self.scheduleCollectorRestart()
            }
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

    struct Candidate: Decodable, Identifiable {
        var id: String { source }
        let source: String
        let score: Int
        let scoreTerms: [LyricsSearchService.ScoreTerm]?
        let title: String?
        let artist: String?
        let album: String?
        /// 这个源当时给出的封面(2026-09-01 加)。**老存档里没有这个字段**,所以恒为 nil ——
        /// 存档是"当时那一刻的固化",不能事后补(现在再查一次拿到的不是当时那个)。
        ///
        /// ⚠️ **必须叫 `coverUrl`,不能写成 `coverURL`**。这个类型走的是
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
    }
}
