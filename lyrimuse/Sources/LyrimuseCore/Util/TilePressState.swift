import Foundation

/// 菜单栏面板里那些圆钮块的「短按 / 长按 / 右键」判定。
///
/// 抽成纯状态机而不是写在 NSView 里,是为了让 selftest 能覆盖唯一真正容易写错的那一点:
/// **长按已经触发过之后,松手不能再当短按用一次**。这也正是那些格子不再用 SwiftUI Button
/// 的原因 —— Button 的 action 认的是"松手",长按到点再松手会把主动作也放一遍,压住它得靠
/// 另一个 @State,而"压住了没有"取决于 SwiftUI 的手势仲裁,不是我们说得准的事。
///
/// AppKit 那层(TileMouseRouter)只做两件事:把 mouseDown/mouseDragged/mouseUp/
/// rightMouseDown 翻译成 Event,把返回的 Action 交给 SwiftUI。所有"这一下算不算数"的
/// 判断都在这里。
public struct TilePressState: Sendable {
    public enum Event: Sendable {
        /// 左键按下。
        case down
        /// 按下之后长按计时器到点(计时在 AppKit 那层,这里只判这一下算不算数)。
        case holdElapsed
        /// 指针拖出了格子 —— 这一轮的短按作废(跟原生按钮一样,拖回来还能救)。
        case dragOutside
        /// 指针又拖回格子里。
        case dragInside
        /// 左键松开。
        case up
        /// 右键按下(或 ⌃左键)—— 不用等,立刻当"要看这个功能的设置"。
        case secondaryClick
    }

    public enum Action: Equatable, Sendable {
        case none
        /// 短按:格子本身的主动作(开关 / 打开某扇窗)。
        case primary
        /// 长按或右键:弹出这个格子对应的快捷设置。
        case secondary
    }

    /// 按着、且指针还在格子里 —— 给按压态视觉用。
    public private(set) var isPressing = false
    /// 这一轮已经出过动作(或已经作废),再来的事件一律不许补第二次。
    private var consumed = false
    /// 指针当下在不在格子里。拖出去只是"暂时不算",拖回来能恢复,所以跟 consumed 分开记。
    private var inside = false

    public init() {}

    public mutating func handle(_ event: Event) -> Action {
        switch event {
        case .down:
            consumed = false
            inside = true
            isPressing = true
            return .none
        case .holdElapsed:
            // 已经作废 / 已经拖出去的那一轮,晚到的计时器不该再放动作出来。
            guard !consumed, inside else { return .none }
            consumed = true
            isPressing = false
            return .secondary
        case .dragOutside:
            inside = false
            isPressing = false
            return .none
        case .dragInside:
            guard !consumed else { return .none }
            inside = true
            isPressing = true
            return .none
        case .up:
            let fire = !consumed && inside
            consumed = true
            isPressing = false
            return fire ? .primary : .none
        case .secondaryClick:
            consumed = true
            isPressing = false
            return .secondary
        }
    }
}
