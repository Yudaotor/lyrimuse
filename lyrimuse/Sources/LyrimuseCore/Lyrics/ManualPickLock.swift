import CryptoKit
import Foundation

/// 「手动选定歌词后锁定」这个开关追溯生效时用到的两段纯逻辑。
///
/// 为什么单独摆在 LyrimuseCore 而不是留在 EnrichCacheStore 里:整个功能的对错**全压在
/// 下面那个谓词上** —— 判宽了会锁住用户从没选过的内容,判窄了开关看起来像没生效。而
/// EnrichCacheStore 在 App target 里,lyrimuse-selftest 只链 LyrimuseCore(见 Package.swift),
/// 放在那边等于这段逻辑一行测试都写不了。挪过来之后它是可测的纯函数,状态和落盘留在
/// EnrichCacheStore。
public enum ManualPickLock {
    /// 把一份 LRC 归一化成"只剩词"的形态:逐行剥掉开头所有 `[...]` 方括号组(行时间戳、
    /// `[ti:]/[ar:]/[al:]/[by:]/[offset:]` 这些元数据标签)、去掉首尾空白、丢掉空行。
    ///
    /// ⚠️ 这一步是整个指纹的要害,不是"顺手清理一下"。见 fingerprint 的头注。
    ///
    /// Go 侧 manualPickCanonicalLyrics 必须逐字节一致(TestManualPickFingerprintMatchesSwift
    /// ↔ selftest 的金标准断言把两边钉在一起)。空白判定两边都取 Unicode 全集(Go 的
    /// strings.TrimSpace / Swift 的 .whitespacesAndNewlines),这样 CRLF、NBSP 这些也一致。
    public static func canonicalLyrics(_ lyrics: String) -> String {
        var out: [String] = []
        // ⚠️ 必须按 **Unicode 标量** 切,不能用 `lyrics.split(separator: "\n")`。Swift 的
        // Character 是字素簇,而 **`\r\n` 是单个字素簇**,跟 `"\n"` 不相等 —— 按 Character
        // 切的话 CRLF 歌词整段不分行,Go 侧(按字节 0x0A 切)却分得好好的,两边指纹当场漂开。
        // 2026-09-01 金标准断言当场逮住的就是这个;而这类源里 CRLF 一点都不罕见(见
        // selftest 里 YRC/CRLF 那几条既有回归)。按标量切等价于 Go 的 strings.Split(s, "\n"):
        // UTF-8 里字节 0x0A 只可能是 U+000A,残留的 \r 交给下面的 trim。
        for rawScalars in lyrics.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(String.UnicodeScalarView(rawScalars))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 一行可能挂多个时间戳(`[00:12.00][00:45.00]同一句`),逐个剥。
            while line.hasPrefix("["), let end = line.firstIndex(of: "]") {
                line = line[line.index(after: end)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if line.isEmpty { continue }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// 「用户手动采纳的那份内容」的指纹,写进缓存的 `manual_pick_sha`。
    ///
    /// # 只对"词"取指纹,不含时间戳、不含 YRC
    ///
    /// 第一版是 `SHA256(lyrics + "\x01" + yrc)` —— 对整份原始字节取指纹。2026-09-01 用真实
    /// 使用数据抓到它**根本不成立**:采纳完 saveEdit 会立刻重启 collector,而 collector 启动
    /// 时那几道规范化会重写内容 ——
    ///   - `migrateYRCWhitespaceTokens` 重排逐字词条,**没有 ManualLyrics 闸**,锁没锁都跑;
    ///   - `migrateLyricTimelines` 把行时间戳重挂到逐字轴上,会改 `lyrics` 本身(它跳过
    ///     ManualLyrics,但关态下的条目正好不是 manual —— 而关态才是追溯锁定的主场景)。
    /// 于是指纹在采纳后的**几秒内**就失配,开关打开时一首都锁不上,而且完全静默。实测那条:
    /// 阿肆《浮光掠影》,lyrics 一字节没变、YRC 被重排,留痕 3c4fe3efb6e8 vs 当前 6625fc9d1d36。
    ///
    /// 根因是把问题定义错了:要回答的是**"自动路径有没有把用户选的那份换掉"**,而不是
    /// "字节有没有变"。**规范化不是替换** —— 词一个没动,只是格式被重排了。所以指纹只取词:
    ///   - 重排时间轴 / 合并空白词条 / 补出 YRC → 词不变 → 仍算"还是他选的那份"(而这些
    ///     恰恰是用户会想连着一起锁住的改进);
    ///   - 换成另一个源、或同源给了一份词不一样的版本 → 词变了 → 正确判成"已被换掉"。
    /// 代价(接受):另一个源恰好给出**逐字相同**的词时也会算匹配 —— 但那种情况下当前内容
    /// 跟他选的那份逐字一样,锁住它没有任何坏处。
    ///
    /// 对行时间轴重挂的免疫是**结构性**的,不是碰巧:collector 那边重挂时走的是
    /// `out[i] = formatLRCStamp(...) + texts[k]`(lyricstimeline.go 里 rehangLRCOnYRC 的
    /// 收尾),`texts[k]` 就是"剥掉时间戳再 trim 的原文" —— 跟这里的归一化逐字一致,它换的
    /// 只有时间戳前缀。金标准里的 A/B 两份输入就是这个形态(同一份词、时间戳全变)。
    ///
    /// **刻意不复用** `LyricsOffsetStore.contentFingerprint`。那个是 offset 持久化 key 的
    /// 组成部分,改一个字节就会让全库已有的时间轴校正值集体失配,等于被兼容性冻结了;把这个
    /// 新用途挂上去就是给它加一条看不见的"也不能改"的理由 —— 而这次正好证明了这个算法
    /// **需要**能改。
    public static func fingerprint(lyrics: String) -> String {
        let canonical = canonicalLyrics(lyrics)
        // 空 → 没有内容可指纹。返回空串而不是空串的哈希:空串在调用方那里就是"没有留痕",
        // 不能让"这首歌根本没歌词"意外匹配上另一首同样没歌词的。
        guard !canonical.isEmpty else { return "" }
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    /// 一条缓存记录跟「手动选定」的关系。
    ///
    /// 分三态而不是一个 Bool,是为了让界面能说清**「什么都没发生」到底是哪一种**:
    /// "你还没手动选过歌"和"你选过、但那几首的歌词后来被自动换掉了"对用户是完全不同的
    /// 两件事,前者要告诉他从现在起会记下来,后者要告诉他为什么这些歌不算数。两种都压成
    /// "0 首"再静默返回,就是这个开关第一版最劝退的地方(2026-09-01 用户反馈「交互有点差」)。
    public enum PickState: Equatable {
        /// 没有留痕 —— 从没手动采纳过,或者之后手改/重新自动匹配把留痕清掉了。
        case neverPicked
        /// 留痕还在,但当前正文已经不是当初采纳的那一份(被自愈路径换过/升级过)。
        case replaced
        /// 当前正文就是用户当初采纳的那一份。
        case original
    }

    public static func state(sha: String?, lyrics: String) -> PickState {
        guard let sha, !sha.isEmpty else { return .neverPicked }
        return sha == fingerprint(lyrics: lyrics) ? .original : .replaced
    }

    /// 开关翻到 `locking` 时,这条缓存记录要不要跟着翻面。
    ///
    /// 两个条件缺一不可:
    ///  1. `state == .original` —— 用户手动采纳过,而且他选的那一份**还在**。关态下这首歌
    ///     随时可能被自愈路径换成别的版本(那正是关态的语义),换过之后再打开开关,锁住的
    ///     就会是一份用户从没选过的内容。这一条是自证的,不依赖任何一处"换歌词时记得清
    ///     标记"的配合;
    ///  2. 当前锁定状态跟目标相反 —— 已经是目标状态的不用动,也不该计进"改了几首"。
    ///
    /// 解锁方向(`locking == false`)天然不会误伤"手改过正文"那种锁:手改会重写 lyrics
    /// 并清掉 `manual_pick_sha`,两条各拦一道。
    public static func shouldFlip(
        sha: String?, lyrics: String, isLocked: Bool, locking: Bool
    ) -> Bool {
        state(sha: sha, lyrics: lyrics) == .original && isLocked != locking
    }
}
