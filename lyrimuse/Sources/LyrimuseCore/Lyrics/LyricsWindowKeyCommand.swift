import Foundation

/// 歌词窗口获得焦点时接的三个按键:空格播放 / 暂停,← 上一首,→ 下一首。
public enum LyricsWindowKeyCommand: Equatable, Sendable {
    case togglePlayPause
    case previousTrack
    case nextTrack

    /// Carbon 虚拟键码(kVK_Space / kVK_LeftArrow / kVK_RightArrow),跟 `NSEvent.keyCode` 同一套。
    public static let spaceKeyCode: UInt16 = 49
    public static let leftArrowKeyCode: UInt16 = 123
    public static let rightArrowKeyCode: UInt16 = 124

    /// 这次按下要不要当成播放控制;nil = 原样放行给窗口。
    ///
    /// - hasModifiers: 按着 ⌘ / ⌥ / ⌃ / ⇧ 里任何一个。这些组合留给菜单和系统。
    /// - isRepeat: 按住不放的自动重复。只认第一次按下:按住空格不该来回切,按住 → 不该连跳几首。
    /// - keyboardFocusElsewhere: 键盘焦点在输入框或控件上。空格要打进输入框,方向键要留给滑块,
    ///   全键盘操控时空格要按下有焦点的那颗按钮。
    public static func command(
        keyCode: UInt16, hasModifiers: Bool, isRepeat: Bool, keyboardFocusElsewhere: Bool
    ) -> LyricsWindowKeyCommand? {
        guard !hasModifiers, !isRepeat, !keyboardFocusElsewhere else { return nil }
        switch keyCode {
        case spaceKeyCode: return .togglePlayPause
        case leftArrowKeyCode: return .previousTrack
        case rightArrowKeyCode: return .nextTrack
        default: return nil
        }
    }

    /// 焦点在不在歌词窗口:窗口成为 key、或者在窗口里按下鼠标时在;窗口失去 key、或者在本 App 别的窗口里
    /// 按下鼠标时不在。悬浮歌词、灵动岛、菜单栏这几扇窗点了之后不抢 key,key window 仍是歌词窗口,
    /// 所以光看 isKeyWindow 不够。
    public struct Focus: Equatable, Sendable {
        public private(set) var isFocused: Bool

        public init(isFocused: Bool = false) {
            self.isFocused = isFocused
        }

        public mutating func windowBecameKey() { isFocused = true }
        public mutating func windowResignedKey() { isFocused = false }
        public mutating func mouseDown(inLyricsWindow: Bool) { isFocused = inLyricsWindow }
    }
}
