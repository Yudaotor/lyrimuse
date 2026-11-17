import Foundation

/// 悬浮歌词「无歌词时显示歌名」:这首没有能同步显示的歌词(纯音乐、搜完确认没有、只有纯文本,同
/// `NoLyricsAutoHide.lacksLyrics`)时,主行不写「纯音乐」「暂无歌词」「仅有纯文本，无时间戳」,改写「歌名 — 歌手」
/// (`MenuBarSlotPolicy.songTitleText`,前面的音符由视图画)。还在搜、断网、引擎没在跑、广告、电台口白都不换。
/// 见 04 章决策 104。
public enum OverlayNoLyricsTitle {
    /// 主行要换成的「歌名 — 歌手」;不换(开关关着、这首有词或还没有结论、没有歌名)时 nil。
    public static func text(enabled: Bool, isInstrumental: Bool, hasNoLyrics: Bool,
                            title: String, artist: String) -> String? {
        guard enabled, NoLyricsAutoHide.lacksLyrics(isInstrumental: isInstrumental, hasNoLyrics: hasNoLyrics) else {
            return nil
        }
        return MenuBarSlotPolicy.songTitleText(title: title, artist: artist)
    }
}
