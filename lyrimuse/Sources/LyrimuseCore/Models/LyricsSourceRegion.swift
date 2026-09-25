import Foundation

/// 「歌词来源」卡里勾选框的排列:中文用户把中文源排前面,其余用户把国外源排前面。
///
/// 只管**显示顺序**。「顺序优先」模式的优先级是另一份用户自己拖出来的排列(`lyricsSourceOrder`),
/// 跟这里无关;解析时查哪些源也只看勾没勾上。
///
/// 按 rawValue 分组,组内保持调用方给的相对顺序(也就是 `LyricsSource.allCases` 的顺序)。
/// AMLL 虽然是国内社区维护的,但按 Apple Music / Spotify 的曲目 id 收录、以外文歌为主,归国外源。
public enum LyricsSourceRegion {
    public static let chineseSources: Set<String> = ["kugou", "netease", "qq", "kuwo", "migu", "soda"]

    /// 这位用户算不算中文用户。在设置里明确选了界面语言就按它("en" 算非中文,"zh-hans" / "zh-hant"
    /// 算中文);跟随系统("system" 或没设)时看系统首选语言是不是中文 —— 界面只有中英两版,日语、
    /// 西语系统的用户界面会退回简体,但他们更用得上国外源。繁体算中文:跟播放器图标的排序
    /// (`PlaybackPlayer.displayOrder`,繁体跟英文一档)不同,繁体用户听的中文歌,中文源照样最有用。
    public static func prefersChineseSources(appLanguageOverride: String?, preferredLanguage: String?) -> Bool {
        switch appLanguageOverride {
        case "en": return false
        case "zh-hans", "zh-hant": return true
        default: return (preferredLanguage ?? "").lowercased().hasPrefix("zh")
        }
    }

    /// 按用户偏好把来源分成两组排列,组内顺序不变。
    public static func displayOrder(_ sources: [String], chineseFirst: Bool) -> [String] {
        let chinese = sources.filter { chineseSources.contains($0) }
        let others = sources.filter { !chineseSources.contains($0) }
        return chineseFirst ? chinese + others : others + chinese
    }
}
