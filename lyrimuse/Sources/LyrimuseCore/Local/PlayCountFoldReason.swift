import Foundation

/// 「第 N 次听」合并明细里,一种写法**为什么**被并进同一族的可读原因(2026-09-04)。
///
/// 背景:行上的「第 N 次听」是写法族**合并后**的总数(繁简 / 括号风格 / 合唱署名……见 PlayCountFold
/// 与 12 章 §7),用户只看得到一个数,看不到它是由哪几个 Last.fm 条目凑出来的。点开明细时每种写法
/// 旁边挂一个原因标签,才核对得出「合并得对不对」—— 这个功能的目的就是审计合并,不是再显示一遍次数。
///
/// 判法:把本尊和变体各自沿 PlayCountFold 的折叠步骤**逐级**归一,在**哪一级**两者第一次相等就报
/// 那一级的名字;歌手、歌名各报一条,合起来最多两条。刻意复用 PlayCountFold / PlayCountVariants /
/// ArtistCredit 里的同一批函数,不另写一遍归一 —— 两把尺子正是「第 15 次听下面紧跟第 21 次听」的
/// 成因(见 RecentPlayOrdinal 注释),原因标签跟真正的折叠规则对不上会比没有标签更误导。
public enum PlayCountFoldReason: String, CaseIterable, Hashable, Codable {
    /// 只差大小写 / 空格有无 / 首尾空白
    case caseOrSpacing
    /// 全角↔半角(NFKC 兼容分解:全角括号、全角空格、全角字母数字)
    case fullwidth
    /// 繁简(含同折简体的字形变体:麼/麽)
    case hanScript
    /// Remaster / feat. / with / Bonus Track / Explicit 这类目录学噪音副题
    case catalogNoise
    /// 同一个版本尾缀的分隔符写法不同(`X - Live` / `X (Live)` / `X [Live]`)
    case versionSuffix
    /// 「CJK 段 + 拉丁段」的双语拼接名折到 CJK 段(《月食 The Weeping Woman》→《月食》)
    case bilingualTitle
    /// 合唱署名归第一位(`A & B` ↔ `A`)
    case artistCredit
    /// 歌手罗马字 / 别名表折到中文本名(David Tao ↔ 陶喆)
    case artistAlias
    /// 歌名别名表(静态或自动发现)折到中文本名
    case titleAlias
    /// 上面都对不上、但 familyKey 相等(规则演进后留的缝)—— 原样报出来好排查,不藏
    case other
}

public enum PlayCountFoldExplainer {
    /// `variant` 被并进 `base` 那一族的原因。两者写法完全一致时为空数组。
    public static func reasons(base: (artist: String, title: String),
                               variant: (artist: String, title: String)) -> [PlayCountFoldReason] {
        var out: [PlayCountFoldReason] = []
        if let r = artistReason(base.artist, variant.artist) { out.append(r) }
        if let r = titleReason(base.title, variant.title, baseArtist: base.artist, variantArtist: variant.artist),
           !out.contains(r) {
            out.append(r)
        }
        return out
    }

    // 各级归一。顺序 = PlayCountFold.key/foldTitle 里的真实步骤顺序:先是最轻的(大小写/空格),
    // 再 NFKC、繁简、剥目录学噪音、版本尾缀归一、双语拼接收敛,最后才是别名表。
    private static func loose(_ s: String) -> String {
        PlayCountFold.stripSpaces(s.lowercased())
    }
    private static func nfkc(_ s: String) -> String {
        loose(s.precomposedStringWithCompatibilityMapping)
    }
    private static func norm(_ s: String) -> String {
        PlayCountFold.stripSpaces(PlayCountFold.normalized(s))
    }

    static func artistReason(_ a: String, _ b: String) -> PlayCountFoldReason? {
        if a == b { return nil }
        if loose(a) == loose(b) { return .caseOrSpacing }
        if nfkc(a) == nfkc(b) { return .fullwidth }
        if norm(a) == norm(b) { return .hanScript }
        if norm(ArtistCredit.mergeArtist(a)) == norm(ArtistCredit.mergeArtist(b)) { return .artistCredit }
        if PlayCountFold.canonicalArtistKey(a) == PlayCountFold.canonicalArtistKey(b) { return .artistAlias }
        return .other
    }

    static func titleReason(_ a: String, _ b: String,
                            baseArtist: String, variantArtist: String) -> PlayCountFoldReason? {
        if a == b { return nil }
        if let r = stagedTextReason(a, b) { return r }
        // foldTitle 不等、familyKey 却相等 → 是歌名别名表把两个折叠键并到一起的。
        if PlayCountFold.familyKey(artist: baseArtist, title: a)
            == PlayCountFold.familyKey(artist: variantArtist, title: b) {
            return .titleAlias
        }
        return .other
    }

    /// 同一个 Last.fm 条目下**专辑名**写法不同(《晴天》的 scrobble 一半挂「葉惠美」一半挂「叶惠美」,
    /// 2026-09-04 用户指出)。专辑不是 Last.fm 曲目身份的一部分,这种分裂是 Last.fm 自己并的、
    /// 不经我们的折叠规则,但用户核对「合并了哪些记录」时同样想看到 —— 原因沿同一条流水线判到
    /// 双语拼接那一级为止(专辑名没有别名表)。
    ///
    /// ⚠️ 跟 `reasons` 不同,这里对不上任何一档返回 **nil、不是 .other**:写法族那一层「并了却说不出
    /// 为什么」是异常,该报;而专辑名之间对不上是**常态** —— 同一首录音本来就会出现在原专辑、精选集、
    /// 专辑的另一语言名(王力宏《心中的日月》= 「Shangri-la」)下面,那是不同的专辑,不是写法差异,
    /// 挂「其他折叠规则」就说反了(2026-09-04 用户问「其他折叠规则这里指的是什么」)。
    public static func albumReason(base: String?, variant: String?) -> PlayCountFoldReason? {
        guard let a = base, let b = variant, a != b else { return nil }
        return stagedTextReason(a, b)
    }

    /// 歌名 / 专辑名共用的逐级比对:从最轻的大小写/空格一路到双语拼接收敛。都不等返回 nil,
    /// 由调用方决定还要不要查别名表(歌名有、专辑名没有)。
    private static func stagedTextReason(_ a: String, _ b: String) -> PlayCountFoldReason? {
        if loose(a) == loose(b) { return .caseOrSpacing }
        if nfkc(a) == nfkc(b) { return .fullwidth }
        if norm(a) == norm(b) { return .hanScript }
        let noise = { (s: String) in
            PlayCountFold.stripSpaces(PlayCountFold.stripCatalogNoise(PlayCountFold.normalized(s)))
        }
        if noise(a) == noise(b) { return .catalogNoise }
        // 跟 foldTitle 同一条流水线,只是停在 collapseBilingual 之前 —— 这一级相等、上一级不等,
        // 差的就是版本尾缀的分隔符写法。
        let version = { (s: String) in
            let stripped = PlayCountFold.stripCatalogNoise(PlayCountFold.normalized(s))
            return PlayCountFold.stripSpaces(
                PlayCountFold.stripCatalogNoise(PlayCountFold.canonicalizeVersionSuffix(stripped)))
        }
        if version(a) == version(b) { return .versionSuffix }
        if PlayCountFold.foldTitle(a) == PlayCountFold.foldTitle(b) { return .bilingualTitle }
        return nil
    }
}
