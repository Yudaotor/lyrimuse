import Foundation

/// 歌词窗口完整布局的按钮组(左上窗口控件、右上音量、右下那一排)、红绿灯和右侧滚动指示条:指针在窗里静止
/// `idleSeconds`,或者离开窗口,就淡出;一动鼠标、滚一下、按一下就回来。见 07 章决策 129。
///
/// 回来的几种情形:窗口刚打开(给 `idleSeconds` 让人看见有哪些按钮)、指针在窗里动了、按着鼠标(拖音量、拖窗口时
/// 不能中途消失)、指针停在某个按钮上或者它弹出来的面板开着、开着「旁白」(看不见的按钮旁白也够不着)。
public enum LyricsWindowChromeIdle {
    public static let idleSeconds: TimeInterval = 3
    /// 淡出慢一点、回来快一点:回来是在回应刚动的那一下鼠标。
    public static let fadeOutSeconds: Double = 0.4
    public static let fadeInSeconds: Double = 0.15

    public struct State: Equatable {
        public var pointerInside = false
        /// 指针在窗里最近一次动、滚、按的时刻。
        public var lastActivity: Date?
        /// 窗口打开时给的那一段,到这个时刻为止不管指针在哪都露着。
        public var revealUntil: Date?
        /// 指针停在按钮上,或者按钮弹出来的面板 / 菜单开着。
        public var held = false
        public var mouseDown = false
        public var voiceOver = false

        public init() {}
    }

    public static func isVisible(_ state: State, now: Date) -> Bool {
        if state.voiceOver || state.held || state.mouseDown { return true }
        if let until = state.revealUntil, now < until { return true }
        guard state.pointerInside, let last = state.lastActivity else { return false }
        return now.timeIntervalSince(last) < idleSeconds
    }

    /// 露着的这一刻,最早什么时候可能该收起;不会自己收起(按住、停在按钮上、旁白、已经收起)时为 nil。
    public static func nextCheck(_ state: State, now: Date) -> Date? {
        guard isVisible(state, now: now), !state.voiceOver, !state.held, !state.mouseDown else { return nil }
        var deadline = state.revealUntil.flatMap { $0 > now ? $0 : nil }
        if state.pointerInside, let last = state.lastActivity {
            let idleEnd = last.addingTimeInterval(idleSeconds)
            if idleEnd > now { deadline = max(deadline ?? idleEnd, idleEnd) }
        }
        return deadline
    }
}
