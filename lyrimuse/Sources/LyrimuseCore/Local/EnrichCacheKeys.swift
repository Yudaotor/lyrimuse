import Foundation

// 缓存 key ↔ lyrics/ 导出文件名之间的换算,以及"这批选中的 key 里哪些真的该删"这类纯逻辑。
//
// 为什么单独放在 LyrimuseCore 而不是留在 EnrichCacheStore 里:EnrichCacheStore 在 app
// target(lyrimuse)里、是 @MainActor 单例、构造函数 private,还依赖 FeatureSettingsStore/
// CollectorControl/PlaybackCoordinator/L10n,lyrimuse-selftest 只依赖 LyrimuseCore、跨
// target 一行都测不到它。把确定性的纯换算下沉到这里,才能在 selftest 里对着 collector 的
// 真实行为写断言(见 main.swift 里对应分节)。
// 「歌词管理」写回缓存文件时的合并规则。
//
// 抽成纯函数放在这里(而不是留在 EnrichCacheStore 里)只有一个理由:那个类是 @MainActor、
// 直接读写磁盘,测不了;而这段逻辑一旦错,代价是**静默丢用户的歌词数据**,必须能测。
public enum EnrichCacheMerge {
    /// 把用户在窗口里做的改动,合到**盘上此刻的内容**之上。
    ///
    /// 「歌词管理」是个可以一直开着的窗口,而 collector 在窗口开着期间会持续往同一个文件写:
    /// 新歌是新增 key,给已有歌补机翻译文/逐字时间轴/封面则是**原地更新**。窗口里的内存快照
    /// 只在开窗和点「刷新」时更新,所以整份覆盖写会把这期间 collector 写的东西全部回滚。
    ///
    /// - Parameters:
    ///   - disk: 写盘前重新读到的磁盘内容(权威底稿)。
    ///   - memory: 窗口里的内存快照。
    ///   - edited: 用户明确编辑过的 key —— 以内存为准。在内存里已不存在则表示编辑后又删了。
    ///   - deleted: 用户明确删除的 key —— 即便盘上还在也要删掉。
    public static func merge(
        disk: [String: [String: Any]],
        memory: [String: [String: Any]],
        edited: Set<String>,
        deleted: Set<String>
    ) -> [String: [String: Any]] {
        var out = disk
        for k in edited {
            if let v = memory[k] { out[k] = v } else { out.removeValue(forKey: k) }
        }
        for k in deleted { out.removeValue(forKey: k) }
        return out
    }
}

public enum EnrichCacheKeys {
    // 跟 collector/lyricsexport.go 的同名变量逐一对应。
    public static let lyricsFileSuffixes = [".lrc", ".tr.lrc", ".roma.lrc", ".yrc"]

    // 跟 collector/lyricsexport.go 的 sanitizeLyricsFilename 逐字对应的 Swift 版本:
    // "|" 换成 " - ",再把文件系统不安全的字符转成下划线。两边各自维护而不是让 Swift 调
    // Go 子进程,是因为这纯粹是确定性的字符替换,没有会随时间演进的业务判断。
    public static func sanitizeFilename(_ key: String) -> String {
        var name = key.replacingOccurrences(of: "|", with: " - ")
        for c in ["/", ":", "*", "?", "\"", "<", ">", "\\"] {
            name = name.replacingOccurrences(of: c, with: "_")
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // CRC-32(IEEE 802.3,反射多项式 0xEDB88320)——必须跟 Go 的 hash/crc32.ChecksumIEEE
    // 逐位一致,因为下面 disambiguatedName 要拿它算出 collector 实际会用的文件名。
    // 标准库没有现成的,查表实现十几行,selftest 里用公认的标准向量(""、"123456789")
    // 加两个从真实磁盘文件反推出来的用例锁死。
    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    public static func crc32IEEE(_ s: String) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in Array(s.utf8) {
            c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }

    // collector 给"文件名撞车"的 key 用的消歧文件名 base:`<sanitize(key)>~<crc32 低 24 位,6 位小写十六进制>`。
    //
    // 为什么 Swift 侧必须知道这个:macOS 的 APFS 大小写不敏感,同一首歌因为 media-control
    // 偶尔读到的大小写不一致而长出两条 key 时,它们 sanitize 出来的文件名只差大小写、在这台
    // 文件系统上其实是同一个文件。collector(lyricsexport.go:105-141)因此按
    // "sanitize 结果统一转小写"分组,组内 ≥2 个不同 key 的,给**组内每一个** key 都换成这个
    // 带哈希后缀的名字,并主动删掉普通名下的残留文件。也就是说这类条目在磁盘上**只有**
    // 带后缀的那份,普通名根本不存在。
    public static func disambiguatedName(forKey key: String) -> String {
        let sum = crc32IEEE(key) & 0xFF_FFFF
        return String(format: "%@~%06x", sanitizeFilename(key), sum)
    }

    // 一个 key 在 lyrics/ 目录下**可能**占用的全部文件名:普通名 4 个 + 带消歧后缀 4 个。
    //
    // 为什么两种形态都要列出来、而不是先判断"这个 key 到底在不在碰撞组里":判断需要拿到
    // 全部 key 才能分组,而删除场景下同时列出两种形态一样精确——带后缀的那个名字里含
    // crc32(key),是这个 key 独有的,删它绝不可能误删碰撞组里别人的文件(要误删得同时满足
    // sanitize 结果相同、crc32 低 24 位也相同)。删一个本来就不存在的路径是无害的空操作。
    //
    // ⚠️ 2026-08-05 实测排查坐实的真实 bug 就出在这里:改动之前只拼普通名那 4 个,而本机
    // 852 条缓存里有 219 条(25.7%)的导出文件带消歧后缀,删除时漏删 → collector 重启
    // (删除本身就会触发一次重启)跑 importLyricsFromFiles 时又从这些残留文件把条目
    // 原样导回来,表现是"删了一条,过一会儿它自己回来了"。collector 是按文件**头部标签**
    // ([ar:]/[ti:]/[al:],见 lyricsimport.go:192)重建 key 的,不看文件名,所以文件名带不带
    // 后缀都拦不住复活。
    public static func exportedFileNames(forKey key: String) -> [String] {
        let plain = sanitizeFilename(key)
        let hashed = disambiguatedName(forKey: key)
        return lyricsFileSuffixes.map { plain + $0 } + lyricsFileSuffixes.map { hashed + $0 }
    }

    // 批量删除真正要落地的 key 清单:选中集合跟"当前缓存里确实存在的 key"求交集。
    //
    // 选中集合里出现已经不存在的 key 是正常的、不是异常:List 的 selection 是纯 UI 状态,
    // 用户改了筛选条件、点了刷新、或者在别处删过同一条,选中集合都不会自动跟着收拾。
    // 拿它直接去删虽然也删不出错(删不存在的 key 是空操作),但**条数**会虚高,导致确认
    // 弹窗上写的"删除 N 条"跟实际删掉的条数不一致——批量不可逆删除里这个数字必须诚实。
    //
    // 返回排序后的数组而不是 Set:确认弹窗要列出前几首歌名,顺序必须稳定可复现(Set 的
    // 迭代顺序不保证),selftest 也才能做确定性比较。
    public static func deletionPlan(selected: Set<String>, existing: Set<String>) -> [String] {
        selected.intersection(existing).sorted()
    }
}
