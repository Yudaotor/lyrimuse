import Combine
import Foundation
import CryptoKit

// 单曲歌词时间轴微调——记住"这首歌的这份歌词该提前/延后多少毫秒",按 trackKey 持久化,
// 下次播放同一首歌、同一份歌词内容时自动生效,不用每次重新调。
//
// key 故意不是单纯的"歌手|歌名"(那样同一首歌换了一份歌词内容——重新匹配到别的源、
// 手动在「歌词管理」编辑过、酷狗/QQ/网易云来回切换——校正值会被错误地继续套用在新歌词
// 上,新歌词的时间轴基准很可能完全不一样)。key 额外拼上这份歌词内容(lyrics+逐字 yrc
// 两个字段一起)算出来的一段短哈希,内容变了 key 自然跟着变,旧的校正值不会被误用到新
// 内容上——不需要显式失效旧记录,只是查不到而已(旧记录留在字典里不清,量很小,
// 跟 EnrichCacheReader 那份"设计上永久不清理"的既有取舍一致)。
//
// 故意跟 EnrichCacheStore(歌词内容缓存)彻底分开存——那份缓存的"清空全部缓存"清的是
// 解析出来的歌词内容,这里存的是用户自己手动校准出来的时间校正值,是更宝贵的个人偏好,
// 不该被"清缓存"这类操作连带清掉。
//
// 跟 AppSettings.customColorThemes 同样的持久化选择:字典编码成 JSON 字符串存进
// UserDefaults(不是裸 Data blob),`defaults read` 还能看懂内容方便调试。
@MainActor
// ObservableObject 只为下面那个**全局**偏移:设置页要能实时显示它。按曲目那份字典不
// 对外发通知 —— 它的消费方是 LocalPlaybackSource,那边已经有自己的 @Published 往外推。
public final class LyricsOffsetStore: ObservableObject {
    public static let shared = LyricsOffsetStore()

    private static let defaultsKey = "np:lyricsOffsetsByTrackJSON"
    private static let globalDefaultsKey = "np:lyricsGlobalOffsetMs"

    private var offsets: [String: Int]

    private init() {
        // 存量 key 归一化(见 migratedOffsetKeys):trackKey 的形态 2026-08-20 变过一次,
        // 老记录留在旧形态下会永久查不到。搬完立刻落盘,不留"内存已修、磁盘还旧"的中间态。
        let loaded = Self.load()
        offsets = Self.migratedOffsetKeys(loaded)
        let didMigrateKeys = offsets != loaded
        trackOffsetCount = offsets.count
        // 没存过就是 0(integer(forKey:) 对缺失键返回 0),正好是"不偏移"。
        globalOffsetMs = UserDefaults.standard.integer(forKey: Self.globalDefaultsKey)
        // 「按播放器偏移」层已整体移除(2026-08-20,随 Spotify 自然切歌锚点根修下线,
        // 见 LocalPlaybackSource.naturalAdvanceCorrection):把存量值从 UserDefaults 里
        // 一并清掉,不能只删读取代码——用户若调过非零值,根修上线后这个隐形偏移会反把
        // 歌词拖慢,而界面上已经没有任何地方能看到/重置它。
        UserDefaults.standard.removeObject(forKey: "np:lyricsPlayerOffsetsJSON")
        // persist() 是实例方法,得等所有存储属性都初始化完才能调 —— 所以搬迁结果在这里
        // 才落盘,而不是紧跟上面那次搬迁。
        if didMigrateKeys { persist() }
    }

    // MARK: - 全局偏移

    /// 全局歌词时间轴偏移(毫秒),对**所有**歌生效。
    ///
    /// 跟上面那份按曲目存的校正值是两件事,分层是有意的:
    ///  - **全局**:设备侧的固定延迟 —— 蓝牙耳机、外接音响、声卡缓冲。它跟"哪首歌"
    ///    无关,换一首照样偏,不该逼用户对每首歌各调一遍。
    ///  - **单曲**:这一份歌词文件本身的时间轴不准,只对这份内容有意义(所以 key 里
    ///    还拼了内容指纹,换一份歌词就自然失效)。
    ///
    /// 实际生效的是两者之**和**(见 effectiveOffset)。分开存也就意味着「重置这首歌」
    /// 只清微调、不动设备侧那份基准 —— 后者正是用户最不希望被连带清掉的东西。
    ///
    /// 用裸 Int 存,不跟上面那份字典合流:它不属于任何一首歌,塞进字典就得编一个假 key,
    /// 而那个 key 会跟着 JSON 一起被"按曲目"的逻辑扫到。
    @Published public private(set) var globalOffsetMs: Int

    public func setGlobalOffset(_ ms: Int) {
        guard ms != globalOffsetMs else { return }
        globalOffsetMs = ms
        UserDefaults.standard.set(ms, forKey: Self.globalDefaultsKey)
    }

    // 「按播放器偏移」第三层(2026-08-18 加,playerOffsets/np:lyricsPlayerOffsetsJSON)
    // 已于 2026-08-20 整体移除:当时它补的"Spotify 时钟恒比出声超前"实为自然切歌锚点
    // 超前(+0.85s 量级、每首抽签),已在 LocalPlaybackSource.naturalAdvanceCorrection
    // 按曲精确校正 —— 一个固定的手调补偿对"每首不一样、手动点播又没有"的偏差本来就
    // 不对症。init 里顺手清掉了存量 UserDefaults 键。

    /// 这首歌实际该用的偏移 = 全局基准 + 这首歌的微调。
    ///
    /// 唯一的合成点。调用方(LocalPlaybackSource.applyOffsets)只认它,不要在别处
    /// 自己写 `global + track` —— 多处各加一次就是双倍校正,而那种 bug 只在
    /// "两条路径都跑过"的特定顺序下才露出来。
    public func effectiveOffset(forKey key: String) -> Int {
        globalOffsetMs + offset(forKey: key)
    }

    // 统一在这里拼 key,调用方(LocalPlaybackSource)不用各自实现一遍哈希
    // 逻辑。歌词内容(lyrics/lyricsYRC)都还没解析出来时——新歌/纯音乐/还没轮到 enrich——
    // 指纹段留空,key 退化成"歌手|歌名|",不影响生成一个可用但"内容未知"的 key。
    // 故意标 nonisolated——纯函数,不碰 offsets 这份实例状态,不需要 MainActor 隔离,
    // 也方便 selftest(跑在 main.swift 顶层、非 async 上下文)直接调用。
    public nonisolated static func trackKey(artist: String, title: String, lyrics: String, lyricsYRC: String) -> String {
        // ⚠️ 前两段必须走 EnrichCacheKeys 那套归一化(跟 enrich 缓存 key 同一套),不能原样
        // 拼播放器报的字符串。
        //
        // 2026-08-20 修的真 bug:播放侧传进来的是**播放器原始**歌手/歌名,而「歌词管理」传
        // 进来的是缓存 key 拆出来的(已归一化)那两段 —— 同一首歌于是有两个身份。实测这台
        // 机器 2483 首里 111 首(4.5%)落在这个差异上(歌名结尾带译名括号、`(with X)` 之类):
        // 在管理页敲的偏移播放时查不到,菜单栏调的值在管理页也看不见、「重置」还清不掉。
        //
        // 放在这个唯一构造点里做,而不是去改两个调用方:调用方各自记得归一化=迟早又漏一处,
        // 而漏掉的表现只在那 4.5% 的歌上出现,极难归因。归一化是幂等的,管理页那边传已经
        // 归一化过的值进来再过一遍也是同一个结果。
        "\(EnrichCacheKeys.cleanTag(artist))|\(EnrichCacheKeys.normalizedTitle(title))|\(contentFingerprint(lyrics: lyrics, lyricsYRC: lyricsYRC))"
    }

    /// 把存量记录的 key 搬到归一化形态。纯函数,selftest 直接覆盖。
    ///
    /// 只动前两段、指纹段原样保留 —— 所以**不需要知道歌词内容**,启动时一次性搬完即可,
    /// 不用等播到那首歌才修(那样"管理页敲了不生效"会一直挂着直到用户碰巧放到它)。
    ///
    /// 撞车规则:两条旧记录归一化后可能落到同一个 key(同一首歌的两种歌名拼法,而指纹相同
    /// 说明内容也是同一份)。让**本来就是归一化形态**的那条赢 —— 它是新形态下唯一查得到的
    /// 身份,用旧形态的值盖掉它等于把用户正在用的校正值换成一个更旧的。都不是自映射时按
    /// key 排序取第一条,保证结果确定(Dictionary 遍历顺序每次进程启动都不一样)。
    public nonisolated static func migratedOffsetKeys(_ stored: [String: Int]) -> [String: Int] {
        var out: [String: Int] = [:]
        out.reserveCapacity(stored.count)
        var lockedBySelfMapping = Set<String>()
        for key in stored.keys.sorted() {
            guard let value = stored[key] else { continue }
            let target = normalizedTrackKey(key)
            if lockedBySelfMapping.contains(target) { continue }
            if out[target] == nil || target == key { out[target] = value }
            if target == key { lockedBySelfMapping.insert(target) }
        }
        return out
    }

    /// `歌手|歌名|指纹` → 前两段归一化后的同形 key。段数不对(不是这个仓库写出来的 key)
    /// 就原样返回,不猜。歌手/歌名本身不含 `|`(enrichKey 那套 SplitN 3 的既有约定),所以
    /// 从右边切出指纹段、再从左边切出歌手段是安全的。
    private nonisolated static func normalizedTrackKey(_ key: String) -> String {
        guard let lastSep = key.lastIndex(of: "|") else { return key }
        let fingerprint = key[key.index(after: lastSep)...]
        let head = key[key.startIndex..<lastSep]
        guard let firstSep = head.firstIndex(of: "|") else { return key }
        let artist = String(head[head.startIndex..<firstSep])
        let title = String(head[head.index(after: firstSep)...])
        return "\(EnrichCacheKeys.cleanTag(artist))|\(EnrichCacheKeys.normalizedTitle(title))|\(fingerprint)"
    }

    private nonisolated static func contentFingerprint(lyrics: String, lyricsYRC: String) -> String {
        let combined = lyrics + "\u{1}" + lyricsYRC
        guard combined != "\u{1}" else { return "" }
        let digest = SHA256.hash(data: Data(combined.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }

    /// 已经调过校正值的曲目数。
    ///
    /// 只发布**数量**、不发布整份字典:字典的消费方是 LocalPlaybackSource,那边有自己的
    /// @Published 往外推(见类型上方的注释);而这个数字是「歌词管理」工具栏菜单要实时
    /// 显示的("已校准 N 首"+清空入口),清空之后必须当场变 0,不能等下次开窗。
    @Published public private(set) var trackOffsetCount: Int

    public func offset(forKey key: String) -> Int {
        guard isValid(key) else { return 0 }
        return offsets[key] ?? 0
    }

    // ⚠️ 三个写入口都要求传 pinKey(归一化的 enrich key),不给默认值:调过时间轴的歌要
    // 顺手钉进 LyricsPinStore、让 collector 不再自动换歌词源(理由见那个类型的注释)。
    // 给默认值等于允许某条路径静默漏掉这件事,而漏掉的表现是"用户校准过的歌过一阵自己
    // 又不准了",极难归因 —— 这个仓库在 offset key 上已经栽过一次同类的坑(见
    // currentLyricsOffsetMs 的注释)。拿不到 enrich key 时显式传空串,setPinned 会跳过。
    @discardableResult
    public func nudge(by deltaMs: Int, forKey key: String, pinKey: String) -> Int {
        let newValue = offset(forKey: key) + deltaMs
        set(newValue, forKey: key, pinKey: pinKey)
        return newValue
    }

    public func reset(forKey key: String, pinKey: String) {
        set(0, forKey: key, pinKey: pinKey)
    }

    // 直接赋一个绝对值——供"歌词管理"里那个输入框用(用户自己敲一个具体的秒数),跟
    // nudge() 的"在现有值上累加"是两种不同的调用方式,内部走的还是同一个 set()。
    public func setOffset(_ ms: Int, forKey key: String, pinKey: String) {
        set(ms, forKey: key, pinKey: pinKey)
    }

    /// 存量补钉:这首歌有非零校正值、却不在已校准名单里,播放到它时顺手补上。
    ///
    /// 为什么需要:pin 是在 set() 里"改动时"写的,而这个机制上线之前用户已经调好的歌一条
    /// pin 都没有 —— 不补的话它们全都不受保护(正是最该保护的那些),而且工具栏「已校准
    /// N 首」这个数字会跟名单长期对不上。setPinned 幂等,状态一致时连盘都不写。
    ///
    /// 刻意做成"播放到它才补"而不是启动时全量扫一遍:offset 的 key 含歌词内容指纹,离开
    /// 播放上下文根本算不出对应的 pinKey(得先知道这首歌当下那份歌词内容是什么)。
    public func backfillPinIfNeeded(forKey key: String, pinKey: String) {
        guard !pinKey.isEmpty, offset(forKey: key) != 0 else { return }
        LyricsPinStore.shared.setPinned(true, forKey: pinKey)
    }

    /// 清掉**全部**单曲校正值(「歌词管理」工具栏那个入口)。
    ///
    /// 刻意只清单曲这一层:全局基准描述的是设备侧固定延迟,跟"哪首歌的歌词准不准"是
    /// 两件事,它在设置页有自己的重置入口,被一个叫"清空歌词时间轴校正"的按钮连带抹掉
    /// 属于意外伤害(同 reset(forKey:pinKey:) 那段注释的取舍)。
    public func clearAllTrackOffsets() {
        if !offsets.isEmpty {
            offsets.removeAll()
            trackOffsetCount = 0
            persist()
        }
        // 校正值都清了就没有要保护的东西,pin 一并抹掉 —— 留着只会让这些歌永久失去后台
        // 升级歌词的机会。无条件调用(不放进上面那个 if):万一两边漂了(比如 pin 机制
        // 上线之前留下的记录),以"清空"为准。
        LyricsPinStore.shared.removeAll()
    }

    // key 是 "歌手|歌名|内容指纹" 拼出来的,三段都是空字符串时(还没拿到过任何曲目信息)
    // 这个 key 毫无意义,不该被当成一个真实的"歌曲"持久化下去。
    private func isValid(_ key: String) -> Bool {
        !key.replacingOccurrences(of: "|", with: "").isEmpty
    }

    private func set(_ ms: Int, forKey key: String, pinKey: String) {
        guard isValid(key) else { return }
        if ms == 0 {
            offsets.removeValue(forKey: key)
        } else {
            offsets[key] = ms
        }
        trackOffsetCount = offsets.count
        persist()
        // 校正值非零 = 用户已经亲手把这首歌调准了 → 钉住它,collector 不再自动重选歌词源
        // (换一份内容就等于让这个校正值静默作废,见 LyricsPinStore)。归零就解钉。
        //
        // 注意 pinKey 跟上面那个 key 是**两套身份**:key 含歌词内容指纹(内容一换就查不到,
        // 这是刻意的),pinKey 是归一化的 enrich key(只认"这首歌")。用 key 当 pin 的身份
        // 会让"内容一换 pin 也失效",正好把要防的事情放过去。
        // pinKey 为空(拿不到 enrich key / selftest 只测偏移那几条)时连单例都不碰 ——
        // LyricsPinStore 一被访问就会去读真实路径那份文件,不该为一次空操作付这个代价。
        if !pinKey.isEmpty {
            LyricsPinStore.shared.setPinned(ms != 0, forKey: pinKey)
        }
    }

    private func persist() {
        guard
            let data = try? JSONEncoder().encode(offsets),
            let json = String(data: data, encoding: .utf8)
        else { return }
        UserDefaults.standard.set(json, forKey: Self.defaultsKey)
    }

    private static func load() -> [String: Int] {
        guard
            let json = UserDefaults.standard.string(forKey: defaultsKey),
            let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String: Int].self, from: data)
        else {
            return [:]
        }
        return decoded
    }
}
