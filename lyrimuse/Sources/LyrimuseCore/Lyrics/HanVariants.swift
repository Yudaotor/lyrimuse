import Foundation

/// 繁简转换之外的**异体字规范化**。
///
/// 为什么需要它:用户 2026-08-22 报「明明开了简体,歌词里还是看到繁体」,实例是周杰伦
/// 《开不了口 (Live)》——ICU 把那首歌 37 种字符全转对了(沒→没、煩→烦、開→开、讓→让…),
/// **只剩「妳」一个字没动,而它出现了 21 次**,整屏都是,看着就是"没转"。
///
/// 根因不是 ICU 有 bug,而是「妳」压根不在繁简转换的范畴里:它是大陆《第一批异体字整理表》
/// 淘汰、港台仍在用的**异体字**,不是「你」的繁体。所以 ICU 的 Traditional-Simplified 不
/// 处理它 —— OpenCC 也一样(collector 侧同一天实测:三张字典里都没有「妳」「祂」「牠」的
/// 任何条目)。这一层专门补这个缺口。
///
/// ═══ 表从哪来(2026-09-03 换掉了原来的手工表)═══
///
/// 原来这里是一张**手写的 6 条对照表**,每个字都要人肉核过词频。2026-09-03 用户要求
/// 「做成通用逻辑,后续遇到这种字的问题都要可以解决,不要通过手动维护一个表的方式,而且
/// swift 和 go 都使用同一套逻辑尽量」,于是改成**从上游数据推导**:
///
///  - 数据:Unicode Unihan 的区域集(`kUnihanCore2020`)/学段字表(`kGradeLevel`)/变体关系
///    (`kSimplifiedVariant`·`kSpecializedSemanticVariant`·`kSemanticVariant`)+ OpenCC 繁简
///    单字表 + 一份**带理由的**人工补丁(`scripts/han-variant-overrides.txt`,只放上游确实
///    没有关系、或者上游唯一候选明显错的字);
///  - 推导规则和"为什么不手工维护"写在 `scripts/gen-han-variants.py` 的头注里;
///  - 产物两份、同一次生成:`HanVariantsTable.swift`(本文件读的这张表)和
///    `lyrimuse-collector/dictionary/HanVariants.txt`(collector 侧 `//go:embed` 读的那份)。
///    **两侧是同一份数据**,selftest 有一条断言逐字核对(漏跑生成器会当场红)。
///
/// 换完之后原来那 6 个字里有 4 个是**推出来的**(妳→你 / 牠→它 / 濛→蒙 / 痺→痹),只有
/// 祂→他、痲→麻 仍然要补丁 —— 那两个字上游真的没有可用关系,理由写在补丁文件里。
///
/// ⚠️ 只在**转简体**方向生效,绝不做反向。简体只有「你」,转繁体时无从判断该写「你」还是
/// 「妳」——那要猜被称呼者的性别,猜错就是改写歌词。同理「他/她/它」也不反推。
///
/// ⚠️ 原来那张手工表的第三条收录标准是"在中文歌词语境里无歧义",据此**刻意不收**「祇」
/// (神祇 vs 只)、「乾」(乾坤/乾隆,ICU 已按上下文正确保留)和粤语字「嘅咁哋冇」。换成推导
/// 之后这一条不是靠人记着了:那些字**本身就在大陆通用字集(G)里**,规则第一步就把它们排除
/// 在外(2026-09-03 逐个核过产物,15 个候选字一个都没进表)。真出现误折,往补丁文件里加一行
/// `字<TAB>-<TAB>理由` 否决即可,不用改代码。
public enum HanVariants {
    /// 异体 → 大陆规范字。数据在生成的 `HanVariantsTable` 里,见上面的说明。
    public static let toSimplified: [Character: Character] = HanVariantsTable.toSimplified

    /// 表里"ICU 的 Traditional-Simplified **确实不转**"的那批变体字 —— 生成时实测出来的
    /// (`scripts/han-icu-probe.swift`)。只有它们在 App 这一侧真的会生效:其余条目 ICU 自己
    /// 就转掉了,留在表里是为 collector 侧的 OpenCC 缺口服务。
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
