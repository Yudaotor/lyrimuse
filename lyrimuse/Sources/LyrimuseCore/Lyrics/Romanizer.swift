import Foundation

// 罗马音兜底——LyricsSyncEngine 现有的罗马音字段完全依赖网易云服务端"恰好给这首歌算好了
// lyrics_roma"(见 enrich.go/collector 那边),源没给就是空,中文歌曲的拼音、日文歌曲的
// 罗马字完全没有客户端兜底。2026-08-04 补上:用系统自带的 ICU 音译(String 的
// .toLatin StringTransform,Foundation 内建、零第三方依赖),在服务端没给这个字段时
// 现算一份兜底——不追求跟专业罗马音标注工具(分词感知的日文罗马字转写)同等质量,只是
// "有总比没有强"的免费兜底,真正的专业标注仍然优先用服务端字段(见调用点)。
public enum Romanizer {
    // 输出等于输入(比如原文本来就是纯英文/已经是拉丁字母,音译是无操作)时返回 nil——
    // 不展示一份跟原文一模一样的"罗马音",那对用户没有任何信息增量,徒增一行重复文字。
    public static func romanize(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        guard let transformed = text.applyingTransform(.toLatin, reverse: false),
              transformed != text else { return nil }
        return transformed
    }

    // 2026-08-04 实测排查坐实的真实 bug:汉字本身是中文/日文共用的文字系统,
    // .toLatin 对纯中文歌词(比如"你对我笑一次")一样能音译出一份"看起来正常"的拼音,
    // 上面的 romanize() 单靠"输出是否等于输入"判断不出这首歌到底是不是真的需要罗马音——
    // 结果中文歌曲(NetEase 本来就不给它算 lyrics_roma,这本身就是"不需要罗马音"的正确
    // 信号)也被这套兜底逻辑摆上了一行拼音,现实世界的歌词 App(网易云/QQ音乐/Apple
    // Music/LyricFever)都不会这么做。
    //
    // 修法:平假名/片假名是日文独有、中文完全没有的两套文字系统,一首歌只要出现过一个
    // 假名字符就能确证"这是日文",借这个信号反过来判定该不该对含汉字的行启用兜底——
    // 调用方(LyricsSyncEngine)按"整首歌"粒度调一次、缓存结果,不是逐行判断,理由见
    // 调用点注释(极少数纯汉字的日文行不该因为局部特征被误判成中文)。
    private static let kanaPattern = try! NSRegularExpression(pattern: #"\p{Hiragana}|\p{Katakana}"#)

    public static func looksJapanese(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return kanaPattern.firstMatch(in: text, range: range) != nil
    }

    // 含汉字的行是"中文拼音 vs 日文罗马字"这个混淆的唯一来源——韩文谚文/泰文/西里尔
    // 字母等其它非拉丁文字系统跟汉字毫无交集,不需要这层额外判断,ICU 音译对它们
    // 本来就是正确、无歧义的罗马化展示。
    private static let hanPattern = try! NSRegularExpression(pattern: #"\p{Han}"#)

    public static func containsHan(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return hanPattern.firstMatch(in: text, range: range) != nil
    }
}
