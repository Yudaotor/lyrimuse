/// `debug/checkpoint` 记下的歌词窗口形态。迷你是面板、没有场景 id,按场景 id 只认得完整那扇,形态得单独记
/// (14 章决策 216)。
public enum DebugLyricsWindowForm: Equatable, Sendable {
    case mini
    case full
}

/// `debug/restore` 怎么把歌词窗口带回记下时的样子。
public enum DebugLyricsWindowRestore: Equatable, Sendable {
    /// 不动。
    case keep
    /// 记下时没开:关掉此刻那扇,迷你面板、完整窗口都算。
    case close
    /// 记下时开着、此刻形态不同或没开:按记下的形态切回 / 开回去。不能先关窗再开:关窗把「开着」
    /// (`np:lyricsWindowOpen`)记成没开,重启后窗口就不再出来。
    case show(mini: Bool)

    public static func plan(saved: DebugLyricsWindowForm?, now: DebugLyricsWindowForm?) -> DebugLyricsWindowRestore {
        guard let saved else { return now == nil ? .keep : .close }
        return saved == now ? .keep : .show(mini: saved == .mini)
    }
}
