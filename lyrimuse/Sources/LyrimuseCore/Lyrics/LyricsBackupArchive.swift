import Foundation

/// 「歌词库备份」这份 sidecar 归档的**纯逻辑**:文件名怎么起、收进来的名字哪些能落盘、
/// 恢复一遍各类各多少条。
///
/// ## 为什么歌词不塞进配置包本体,而是单独一份 sidecar
///
/// 三条硬约束(2026-08-21 审计逐条核实过),任一条都足以否掉"直接加个 lyrics 字段":
///  1. `ICloudConfigStore.latestSnapshot()` 为了取 `exportedAt`/`deviceName` 会在**主线程整份
///     读+解析**配置包 —— 而它挂在设置页 `.onAppear` 等好几处。包一旦变成几十 MB,每次进设置
///     页都要卡一下。
///  2. `ICloudConfigStore.write` 每次点「更新备份」都新写一份带时间戳的文件,**既没有大小上限
///     也没有"只保留 N 份"清理**(旧份永远不会被读)。几十 MB × N 份 = iCloud 空间黑洞。
///  3. 新机首启那条"发现 iCloud 里有备份,问要不要导入"的路径只给 **8 秒**下载超时。大包大概率
///     撑不过去,而超时是**静默**跳过 —— 用户只会觉得"什么都没发生"。
///
/// sidecar 一并绕开三条:配置包保持几 KB(读它的所有路径一字不用改)、歌词那份用固定后缀
/// 可覆盖、下载慢也只影响歌词这一步。`BackupDiscovery` 只认 `Lyrimuse-Config-*.json`,所以
/// sidecar 天然不会被误认成配置包。
///
/// ## 歌词正文走 `lyrics/` 文件族,其余字段走 `meta`(2026-09-02 补齐)
///
///  - `lyrics/` 是歌词六字段(正文/译文/罗马音/逐字/来源/人工标记)的**权威源**:collector 每次
///    启动都跑 `importLyricsFromFiles`(文件赢、只增不删),缓存里没有那个 key 也会**新建条目**。
///    也就是说只要把文件铺回去,歌词自己会长回缓存里 —— 不需要碰缓存 JSON。
///  - 反过来直接盖写 `lyrimuse-enrich-cache.json` 会撞上一个实测过的竞态:collector 内存里握着
///    整份缓存、有七处会整份写回磁盘,在 kickstart 生效之前它可能把刚恢复的内容整份盖回去
///    (2026-08-14「清空了又回来」就是这个,见 EnrichCacheStore.clearAll 的注释)。**这条约束
///    到今天依然成立**,所以下面那个 `meta` 也不是"恢复时直接盖缓存",而是落一份待采纳文件、
///    由 collector 在自己的启动路径里合并(跟 `importLyricsFromFiles` 同一个时机、同一把锁)。
///  - ⚠️ 2026-09-02 修正一条**错了的旧判断**:这里原来写「缓存里其余字段(封面/链接/mbid/打分/
///    决策存档)都是可重新解析的派生数据,不值得为它们多背 17 MB 和一个竞态」——"可重新解析"
///    对其中几类**不成立**,用户实测撞上(原话「在另外电脑导入了配置,但是并没有把歌曲的决策
///    解析给带过来」):
///      * `lyrics_decision` / `lyrics_decision_applied`(本机 2414 / 2368 条)记的是**当时那一轮**
///        各源分别给了什么、得了多少分 —— 是历史快照,重新解析只会写一份**今天的**,原来那份
///        永久消失,「解析决策」弹窗里的证据链就断了;
///      * `plain_lyrics` / `plain_lyrics_source`(用户手点「采纳为静态文本」)压根没有对应的
///        导出文件(没有时间戳,不属于四种歌词后缀),此前**不在任何备份里**,100% 丢失;
///      * `manual_pick_sha`(手动选定后锁定的追溯凭据)同样没有落文件,丢了之后
///        `ManualPickLock` 把这首歌算成"从没手动选过",锁不上且**完全静默**;
///      * `lyrics_scoring_version` 丢了会被读成 0、落后于当前打分版本 → `needsLyricsRescore`
///        把**全库**排进"按新规则重选一次"的队列,赢家一变就把刚恢复的正文换掉,连带
///        单曲校正值的内容指纹一起失效(只有 `manual_lyrics` 和 pins 名单挡得住)。
///    所以现在整份缓存**剥掉那六个歌词字段之后**一起带走:实测 41.8 MB → 9.7 MB,
///    base64 进 JSON 再 zlib 只占 1.25 MB(sidecar 13.8 MB → 15.1 MB,+9%),
///    换掉的是上面这四类真丢不可再生的东西。
///  - 顺带保住一个容易忽略的东西:单曲校正值的 key 里含**歌词内容指纹**,正文逐字节相同才查得到。
///    走文件族恢复正文一个字节都不变,所以那批校正值到了新机器**真的还有效**。
public enum LyricsBackupArchive {
    /// 归档内容的格式版本(跟配置包的 `exportFormatVersion` 各自独立)。
    ///
    /// 2 = 载荷多了 `meta`(2026-09-02)。**两个方向都能互读**,所以不需要任何迁移代码:
    /// v1 的包在这一版解出来 `meta == nil`(可选字段缺省);v2 的包在只认 v1 的旧版本上,
    /// `meta` 作为未知字段被 JSONDecoder 忽略,歌词部分照样恢复。
    public static let payloadVersion = 2

    /// `meta` 里**不带**的字段 —— 它们的权威源是 `lyrics/` 文件族,由 collector 的
    /// `importLyricsFromFiles` 负责灌回缓存(见类型头注)。
    ///
    /// ⚠️ 这六个字符串必须跟 collector 侧 `enrichEntry` 的 json tag 一字不差
    /// (`lyrimuse-collector/enrich.go`),对不上的后果是**静默**的:多带的字段会在恢复时
    /// 盖掉刚从文件导进去的正文,少带的字段则永远不会被搬走。selftest 钉住这份清单。
    public static let lyricFieldKeys = [
        "lyrics", "lyrics_tr", "lyrics_roma", "lyrics_yrc", "lyrics_source", "manual_lyrics",
    ]

    /// enrich 缓存的 JSON → `meta` 载荷用的字节:逐条剥掉 `lyricFieldKeys`,其余原样保留。
    ///
    /// 刻意做成"剥黑名单"而不是"挑白名单":这份缓存的字段是**长期在加**的(光 2026-08 就加了
    /// `plain_lyrics`/`plain_lyrics_source`/`manual_pick_sha` 等好几个),白名单的失效方式是
    /// 静默漏搬新字段 —— 而这正是这次这个 bug 的同款成因。黑名单只有六个成员、且被 selftest
    /// 钉住,新字段自动跟着走。
    ///
    /// 剥完为空的条目整条丢掉(只有歌词字段的条目没有任何值得搬的东西);解不出来返回 nil,
    /// 调用方据此把 `meta` 留空 —— 备份少一部分远好过整份打不出来。
    public static func strippedMeta(fromCacheJSON data: Data) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var out: [String: Any] = [:]
        out.reserveCapacity(root.count)
        for (key, value) in root {
            guard var entry = value as? [String: Any] else { continue }
            for field in lyricFieldKeys { entry.removeValue(forKey: field) }
            guard !entry.isEmpty else { continue }
            out[key] = entry
        }
        guard !out.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    }

    /// 配置包名里的这一段换成下面那个,就是 sidecar 名 —— 同名同时间戳,一眼看得出是一对。
    public static let configNameMarker = "-Config-"
    public static let lyricsNameMarker = "-Lyrics-"
    /// sidecar 的扩展名。`.z` 是 zlib 压缩过的意思(14.5 MB → 6.1 MB 实测),自己的格式、
    /// 不假装是标准 gzip。
    public static let fileExtension = "json.z"

    /// 配置包名 → sidecar 名。认不出配置包命名规律时退回"整个名字后面接一段",宁可名字丑
    /// 也不要返回 nil 让调用方多一条分支。
    public static func sidecarName(forConfigName name: String) -> String {
        let stem = name.hasSuffix(".json") ? String(name.dropLast(5)) : name
        if let range = stem.range(of: configNameMarker) {
            return stem.replacingCharacters(in: range, with: lyricsNameMarker) + "." + fileExtension
        }
        return stem + lyricsNameMarker.dropLast() + "." + fileExtension
    }

    /// 归档的载荷 —— **磁盘格式契约**,字段名一改,旧机器导出的包在新版本上就解不出来
    /// (而且是静默的:decode 失败只会变成"这份备份不带歌词")。所以它连同 encode/decode
    /// 一起放在 Core、由 selftest 对**压缩后再解出来的 JSON 原文**断言字段名,不放在
    /// App target 里靠肉眼守。
    ///
    /// 字段名刻意短:这份 JSON 有近三千个键、压缩前 14.5 MB,长字段名要多背几十 KB。
    public struct Payload: Codable, Equatable {
        /// 载荷格式版本(= payloadVersion)。
        public var v: Int
        /// 导出时刻,ISO8601。
        public var at: String
        /// 从哪台机器导出的。
        public var device: String
        /// 文件名 → 全文。**含 `[ar:]/[ti:]/[al:]/[source:]/[manual:1]` 那几行头部** ——
        /// 头部就是 collector 认身份的依据(`importLyricsFromFiles` 按头部标签而不是文件名
        /// 定身份),剥掉就全成孤儿了。
        public var files: [String: String]
        /// 「已校准」名单:归一化 enrich key → 钉住时的 unix 秒。
        public var pins: [String: Int]
        /// enrich 缓存**剥掉六个歌词字段之后**的那一份(`strippedMeta` 的产物),原样是一段
        /// JSON 字节。nil = 这份备份不带(v1 老包,或打包时缓存读不出来)。
        ///
        /// 为什么是 `Data`(在 JSON 里落成 base64)而不是嵌套的 JSON 对象:Swift 这一侧**完全
        /// 不需要看懂**里面的字段,它只负责原样搬运——打包时从缓存文件读出来剥一遍,恢复时
        /// 原样写成一份待采纳文件交给 collector。用 `Data` 就不必为了 `Codable` 造一套
        /// 任意-JSON 的胶水类型,也不会因为将来 collector 加了新字段而需要动这边一行代码。
        /// 代价是 base64 的 33% 膨胀(9.7 MB → 12.9 MB),但压缩后只差 0.65 MB
        /// (0.60 → 1.25 MB),换这份"字段无关、永不需要跟着改"的解耦是划算的。
        public var meta: Data?

        public init(v: Int = LyricsBackupArchive.payloadVersion, at: String, device: String,
                    files: [String: String], pins: [String: Int], meta: Data? = nil) {
            self.v = v
            self.at = at
            self.device = device
            self.files = files
            self.pins = pins
            self.meta = meta
        }
    }

    /// 载荷 → 归档字节(zlib 压缩)。压不动(理论上不会)就退回明文 —— 解码侧两种都认。
    public static func encode(_ payload: Payload) -> Data? {
        guard let raw = try? JSONEncoder().encode(payload) else { return nil }
        return ((try? (raw as NSData).compressed(using: .zlib)) as Data?) ?? raw
    }

    /// 归档字节 → 载荷。**先试解压、失败当明文**:手改过的包、或将来某个版本改成不压缩,
    /// 都还能读出来 —— 恢复失败的代价(几千首歌的歌词和校正值)远高于多试一次的代价。
    public static func decode(_ data: Data) -> Payload? {
        let raw = ((try? (data as NSData).decompressed(using: .zlib)) as Data?) ?? data
        return try? JSONDecoder().decode(Payload.self, from: raw)
    }

    /// 归档里的一个文件名能不能落盘。返回 nil = 拒收。
    ///
    /// 这是**安全边界**:归档是一份外来文件(可能来自别人的机器、也可能被人手改过),而恢复
    /// 就是拿里面的名字去拼路径写文件。不挡住的话 `../../../../.ssh/authorized_keys` 这种名字
    /// 会把内容写到歌词目录外面去。规则刻意收得很紧:
    ///  - 不许有路径分隔符(`/` 和 `\`);
    ///  - 不许以 `.` 开头(隐藏文件,以及 `.`、`..` 这两个目录本身);
    ///  - 必须是四种歌词后缀之一 —— 歌词备份里就不该有别的东西;
    ///  - 长度卡在 255 字节(单个文件名的文件系统上限,超了写入直接失败)。
    ///
    /// ⚠️ **刻意不再拒收"名字里含 `..`"**(2026-08-21 实测修):专辑/歌名以句点结尾是很常见的
    /// (陶喆《I'm O.K.》、Wale《everything is a lot.》),导出的文件名就长成
    /// `陶喆 - 天天 - I'm O.K..yrc` —— 那一版规则把这类**静默**踢出备份,实测一次漏掉 23 个
    /// 文件而界面上什么都看不到。而它本来也不是必要的:`..` 只有作为**完整路径分量**时才表示
    /// 上一级,而带分隔符的名字上面那条已经拒了;不含分隔符时 `a..b` 就只是个普通文件名。
    /// 落盘那一侧另有一道"解析后的父目录必须还是歌词目录"的兜底(见 LyricsBackupStore)。
    public static func sanitizedFileName(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.utf8.count <= 255 else { return nil }
        guard !raw.contains("/"), !raw.contains("\\") else { return nil }
        guard !raw.hasPrefix(".") else { return nil }
        guard EnrichCacheKeys.lyricsFileSuffixes.contains(where: { raw.hasSuffix($0) }) else { return nil }
        return raw
    }

    /// 恢复一遍的账:新增几个、覆盖几个、拒收几个。
    ///
    /// 覆盖是**故意**的:这是"恢复备份"而不是"合并两边" —— 用户点的是恢复,期待的是"回到备份
    /// 里那个样子"。但要如实报数,不能让人以为只是"补了几个"。
    public struct Plan: Equatable {
        public var added: [String] = []
        public var overwritten: [String] = []
        public var rejected: [String] = []
        public init() {}
    }

    /// `incoming` 是归档里的文件名清单,`existing` 是目标目录里已有的。
    public static func plan(incoming: [String], existing: Set<String>) -> Plan {
        var plan = Plan()
        for raw in incoming.sorted() {
            guard let name = sanitizedFileName(raw) else {
                plan.rejected.append(raw)
                continue
            }
            if existing.contains(name) {
                plan.overwritten.append(name)
            } else {
                plan.added.append(name)
            }
        }
        return plan
    }
}
