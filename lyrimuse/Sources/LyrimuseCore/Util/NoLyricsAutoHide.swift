/// 「纯音乐/无歌词时隐藏」的判据。悬浮歌词和灵动岛各有一个开关(值是两份),判据共用这一份:悬浮歌词整窗隐藏,
/// 灵动岛只收起歌词行(`NotchVisibility.showsLyrics`)。见 04 章决策 58、05 章决策 76。
public enum NoLyricsAutoHide {
    /// 这首按纯音乐处理,或者搜完确认没有能同步显示的歌词(只有纯文本的也算:这两个形态显示不了它)。
    /// 还在搜、断网都不算 —— 那两种不是结论,藏起来等于把「此刻查不了」当成「这首没有」。
    public static func lacksLyrics(isInstrumental: Bool, hasNoLyrics: Bool) -> Bool {
        isInstrumental || hasNoLyrics
    }

    public static func hides(enabled: Bool, lacksLyrics: Bool) -> Bool {
        enabled && lacksLyrics
    }
}
