import Foundation

// 缓存 key 与 lyrics/ 导出文件名之间的换算,以及"这批选中的 key 里哪些真的该删"这类纯逻辑。
//
// 为什么单独放在 LyrimuseCore 而不是留在 EnrichCacheStore 里:EnrichCacheStore 在 app
// target(lyrimuse)里、是 @MainActor 单例、构造函数 private,还依赖 FeatureSettingsStore/
// CollectorControl/PlaybackCoordinator/L10n,lyrimuse-selftest 只依赖 LyrimuseCore、跨
// target 一行都测不到它。把确定性的纯换算下沉到这里,才能在 selftest 里对着 collector 的
// 真实行为写断言(见 main.swift 里对应分节)。

public enum EnrichCacheKeys {
    // 跟 collector/lyricsexport.go 的同名变量逐一对应。
    public static let lyricsFileSuffixes = [".lrc", ".tr.lrc", ".roma.lrc", ".yrc"]

    // ---- 缓存 key 的归一化:跟 collector/enrichkey.go 逐条对应 ----
    //
    // 两边必须给出**逐字节相同**的 key,否则 collector 按归一化 key 写、这边按原样拼的 key
    // 查,悬浮窗会直接查不到歌词(而不是显示旧的那份 —— 更难发现)。lyrimuse-selftest 里
    // 用跟 Go 表驱动测试同一组用例锁死这份对应关系。
    //
    // 为什么要归一化,见 enrichkey.go 顶部那段长注释:同一首歌在不同播放器里歌名拼法不同
    // (`不散的筵席（I Miss You）` vs `不散的筵席`),原样拼 key 会存成两条、各自选中不同的
    // 歌词源,于是"用哪个播放器听,歌词推进的节奏就不一样"。

    // 括号里出现这些词说明它标的是另一个**录音版本**,不是译名 —— 保留。
    // 顺序/内容跟 enrichkey.go 的 enrichKeyVersionWords 一致。
    static let versionWords = [
        "remix", "mix", "live", "acoustic", "instrumental", "inst", "demo", "cover",
        "remaster", "version", "ver.", "edit", "extended", "radio", "karaoke",
        "reprise", "feat", "ft.", "featuring", "session", "mono", "stereo", "dub",
        "unplugged", "acappella", "a cappella",
        "interlude", "intro", "outro", "skit", "prelude", "overture",
        // "慢板"/"快板"是古典/影视配乐里常见的乐章速度标记,标的是**另一个录音版本**
        // (跟上面 remix/live/acoustic 同类),不是译名噪音,见 enrichkey.go 的
        // enrichKeyVersionWords 头注。
        "慢板", "快板",
        "现场", "伴奏", "翻唱", "重制", "修复", "版", "纯音乐", "前奏", "间奏",
    ]

    private static let openBrackets: Set<Unicode.Scalar> = ["（", "(", "[", "【"]
    private static let closeBrackets: Set<Unicode.Scalar> = ["）", ")", "]", "】"]

    // 下面几个镜像 Go 的函数一律按 Unicode 标量处理,空白/大小写用 GoStringSemantics,理由见那边头注。
    // 两侧必须逐字节一致,lyrimuse-selftest 与 docs 08 章「宽松匹配兜底」那条有对拍方法。

    /// collector 的 cleanMediaTag 的 Swift 版:各种不换行/全角空格折成普通空格,零宽字符
    /// 删掉,连续空白(Go `unicode.IsSpace` 口径)折成一个并去掉首尾。
    public static func cleanTag(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for u in s.unicodeScalars {
            switch u {
            case "\u{200b}", "\u{200c}", "\u{200d}", "\u{feff}": continue
            default: break
            }
            if GoStringSemantics.isSpace(u) {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(u)
        }
        return String(out)
    }

    /// 反复剥掉歌名结尾的译名括号,碰到版本标记就停手;剥到空串则整个放弃(有些曲目的歌名
    /// 本身就是一对括号,比如 `(Interlude)`)。只看**结尾**那一组括号,中间的不动。
    ///
    /// 跟 Go 那条正则 `\s*[（(\[【]([^）)\]】]*)[）)\]】]\s*$` 的最左匹配等价:结尾闭括号往前、
    /// 一直到上一个闭括号为止,取**最靠左**的开括号(括号不配对时不是离结尾最近的那个)。
    public static func normalizedTitle(_ title: String) -> String {
        var t = Array(cleanTag(title).unicodeScalars)
        func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
            String(String.UnicodeScalarView(scalars))
        }
        while true {
            guard let last = t.last, closeBrackets.contains(last) else { return string(t[...]) }
            var openIdx: Int?
            var k = t.count - 2
            while k >= 0, !closeBrackets.contains(t[k]) {
                if openBrackets.contains(t[k]) { openIdx = k }
                k -= 1
            }
            guard let openIdx else { return string(t[...]) }
            let inner = GoStringSemantics.toLower(string(t[(openIdx + 1)..<(t.count - 1)]))
            if versionWords.contains(where: { GoStringSemantics.contains(inner, $0) }) { return string(t[...]) }
            let head = GoStringSemantics.trimSpace(string(t[..<openIdx]))
            if head.isEmpty { return string(t[...]) }
            t = Array(head.unicodeScalars)
        }
    }

    /// 歌词缓存 key 的唯一构造点(Swift 侧)。跟 collector 的 enrichKey 逐字节一致。
    public static func normalizedKey(artist: String, title: String, album: String) -> String {
        cleanTag(artist) + "|" + normalizedTitle(title) + "|" + cleanTag(album)
    }

    // 跟 collector/lyricsexport.go 的 sanitizeLyricsFilename 逐字对应的 Swift 版本:
    // "|" 换成 " - ",再把文件系统不安全的字符转成下划线。两边各自维护而不是让 Swift 调
    // Go 子进程,是因为这纯粹是确定性的字符替换,没有会随时间演进的业务判断。
    public static func sanitizeFilename(_ key: String) -> String {
        truncateFilenameBase(sanitizeFilenameUntruncated(key))
    }

    /// 上面那个函数不加长度上限的版本,只用来算出"这个 key 在长度上限生效前会落到的
    /// 文件名",好在删除时把那份存量残留一起删掉。别拿它去拼新文件名。
    public static func sanitizeFilenameUntruncated(_ key: String) -> String {
        var name = String.UnicodeScalarView()
        for u in key.unicodeScalars {
            switch u {
            case "|": name.append(contentsOf: " - ".unicodeScalars)
            case "/", ":", "*", "?", "\"", "<", ">", "\\": name.append("_")
            default: name.append(u)
            }
        }
        return GoStringSemantics.trimSpace(String(name))
    }

    /// 文件名 base(不含 .lrc 等后缀)的字节上限。
    ///
    /// 必须跟 collector/lyricsexport.go 的 `lyricsFilenameMaxBytes` 同值,两边同时改。
    /// 推导在 Go 那边的注释里(255 字节硬上限,减去原子写临时文件的 14 字节和最长后缀
    /// .roma.lrc 的 9 字节,再减去碰撞消歧的 7 字节,取余量到 200)。算不一致的后果是
    /// 删除条目时漏删导出文件,collector 重启跑 importLyricsFromFiles 会按文件头部标签
    /// 把它重新导回缓存,表现为"删掉的条目自己回来了"。
    public static let filenameMaxBytes = 200

    /// 按字节上限截断,只在 UTF-8 字符边界上切。跟 Go 侧 truncateFilenameBase 逐字对应。
    ///
    /// Swift 的 String 按字符计数,这里必须显式走 UTF-8 视图 —— 一个汉字 3 字节,按字符
    /// 截会漏判。`String(decoding:as:)` 在边界正确时不会产生替换字符。
    public static func truncateFilenameBase(_ name: String) -> String {
        let bytes = Array(name.utf8)
        if bytes.count <= filenameMaxBytes { return name }
        var cut = filenameMaxBytes
        // UTF-8 续字节形如 10xxxxxx,往前退到字符首字节。
        while cut > 0, bytes[cut] & 0xC0 == 0x80 { cut -= 1 }
        let head = String(decoding: bytes[0..<cut], as: UTF8.self)
        return GoStringSemantics.trimSpace(head)
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

    /// 把 key 压成"用来判断是不是同一首歌"的宽松形态。跟 collector 的 loosenEnrichKey 对应。
    ///
    /// 结果**只用于查询兜底**,绝不用来构造 key、绝不用于显示、绝不用于文件名。
    ///
    /// 这条边界是整套设计的关键。归一化如果写进 **key**,Go 和 Swift 两侧就必须逐字节算出
    /// 同一个结果,否则 collector 按一个 key 写盘、这边按另一个 key 查,表现是「悬浮窗整首歌
    /// 没词」(lookup 是纯精确命中)。
    ///
    /// 兜底这一层同样必须与 collector 逐字节一致:collector 按它的宽松 key 复用已有条目、不另建
    /// 新条目(日志 `reusing existing entry … (loose match)`),这边折不到同一个结果就是整首歌查不到
    /// 歌词。所以繁简走 `OpenCCT2S`(collector toSimplifiedT2S 的移植,同一份词典),不走 ICU:
    /// ICU 按上下文取舍,单字层面跟 OpenCC 有上千个字结果不同。步骤同 loosenEnrichKey:繁转简、
    /// 分隔符折成 `&`、去掉 ASCII 空格、逐标量转小写。
    /// 合 credit 的分隔符,跟 collector 的 `isArtistCreditSep`(match.go)同一份。
    /// 全部折成同一个字符,让 `A/B/C` 和 `A & B & C` 判成同一首歌 —— 实测:
    /// 播放器报斜杠式、专辑预取从 Apple Music 曲目表拿到 & 式,缓存里长出 12 组重复。
    private static let creditSeparators: Set<Unicode.Scalar> = ["/", "、", "&", ",", "，"]

    public static func looseKey(_ key: String) -> String {
        var out = String.UnicodeScalarView()
        for u in OpenCCT2S.toSimplified(key).unicodeScalars {
            if u == " " { continue }
            out.append(creditSeparators.contains(u) ? "&" : GoStringSemantics.toLower(u))
        }
        return String(out)
    }

}
