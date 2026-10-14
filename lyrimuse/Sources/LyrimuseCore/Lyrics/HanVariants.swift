import Foundation

/// 繁简转换之外的异体字规范化。「妳」「祂」「牠」这类字是大陆《第一批异体字整理表》淘汰、港台仍在用的异体字,
/// 不是「你」「他」「它」的繁体,ICU 的 Traditional-Simplified 和 OpenCC 的繁简字典都不处理它们,开了简体显示,
/// 歌词里还是会留着。这一层专门补这个缺口。见 08 章「简繁转换」。
///
/// 表从上游数据推导,不手工维护:
///  - 数据:Unicode Unihan 的区域集(`kUnihanCore2020`)/学段字表(`kGradeLevel`)/变体关系
///    (`kSimplifiedVariant`·`kSpecializedSemanticVariant`·`kSemanticVariant`)+ OpenCC 繁简
///    单字表 + 一份带理由的人工补丁(`scripts/han-variant-overrides.txt`,只放上游确实没有关系、
///    或者上游唯一候选明显错的字,比如祂→他、痲→麻);
///  - 推导规则写在 `scripts/gen-han-variants.py` 的头注里;
///  - 产物两份、同一次生成:`HanVariantsTable.swift`(本文件读的这张表)和
///    `lyrimuse-engine/dictionary/HanVariants.txt`(引擎侧 `//go:embed` 读的那份)。
///    两侧是同一份数据,selftest 有一条断言逐字核对(漏跑生成器会当场红)。
///
/// 只在转简体方向生效,绝不做反向。简体只有「你」,转繁体时无从判断该写「你」还是「妳」——那要猜被称呼者的性别,
/// 猜错就是改写歌词。同理「他/她/它」也不反推。
///
/// 有歧义的字(「祇」神祇 vs 只、「乾」乾坤/乾隆、粤语字「嘅咁哋冇」)本身就在大陆通用字集(G)里,推导规则第一步
/// 就把它们排除在外。真出现误折,往补丁文件里加一行 `字<TAB>-<TAB>理由` 否决即可,不用改代码。
public enum HanVariants {
    /// 异体 → 大陆规范字。数据在生成的 `HanVariantsTable` 里,见上面的说明。
    public static let toSimplified: [Character: Character] = HanVariantsTable.toSimplified

    /// 表里"ICU 的 Traditional-Simplified **确实不转**"的那批变体字 —— 生成时实测出来的
    /// (`scripts/han-icu-probe.swift`)。只有它们在 App 这一侧真的会生效:其余条目 ICU 自己
    /// 就转掉了,留在表里是为引擎侧的 OpenCC 缺口服务。
    ///
    /// 开放出来只有一个用途:selftest 里"整条链路的产物必须等于表里的规范字"那条强断言只
    /// 对这一批成立,拿全表去断言等于在断言"ICU 和 OpenCC 逐字一致"——那是另一件事,而且
    /// 实测不成立(有 5 个字 ICU 会转成更生僻的字形)。
    public static let icuGaps: Set<Character> = HanVariantsTable.icuGaps

    /// 把 ICU 转换的结果再过一遍异体字表。
    ///
    /// 快路径:先扫一遍看有没有命中,没有就原样返回同一个 String —— 绝大多数歌词一个都不
    /// 命中,而这个函数在换歌/改设置时对整份歌词+译文+逐字数据各跑一次,不该无谓地重建字符串。
    public static func normalizeToSimplified(_ text: String) -> String {
        guard text.contains(where: { toSimplified[$0] != nil }) else { return text }
        return String(text.map { toSimplified[$0] ?? $0 })
    }
}
