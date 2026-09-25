/// 灵动岛窗口的显示 / 隐藏决策(`NotchLyricsWindowController.updateActualVisibility` 的纯逻辑部分)。
///
/// 控制器只负责执行:orderFront / orderOut、翻 `isVanished`、加出场动画计数、排延迟隐藏。
/// 「该做哪一步」全在这里,selftest 覆盖。
public enum NotchVisibility {
    /// 窗口该不该在屏上:灵动岛开着,且没开「暂停/无播放时隐藏」、或正在播、或「发现新播放器」的提醒挂着
    /// (提醒那一刻按定义没有曲目、也没在播,开着隐藏的机器上窗口正藏着)。延迟隐藏到点时的复核也用这一份。
    public static func shouldShow(isVisible: Bool, hideWhenNotPlaying: Bool,
                                  isPlaying: Bool, alertHold: Bool) -> Bool {
        isVisible && (!hideWhenNotPlaying || isPlaying || alertHold)
    }

    public enum Step: Equatable, Sendable {
        /// 要显示。`orderFront`:窗口还不在屏上;`replayReveal`:卡片「从无到有」露面(窗口刚上屏,
        /// 或卡片从刘海里回场),播一遍出场动画。两者都为 false 时一次 WindowServer 事务都不发。
        case show(orderFront: Bool, replayReveal: Bool)
        /// 本来就藏着:只作废挂着的延迟隐藏。
        case alreadyHidden
        /// 立刻 orderOut,不做缩回动画。
        case hideNow
        /// 先把整卡缩进刘海,动画走完再 orderOut。
        case startVanish
        /// 已经在等缩回动画走完:不重排,否则同样结论反复进来会把隐藏一推再推。
        case keepPendingVanish
    }

    /// - Parameters:
    ///   - lastApplied: 上一次实际执行的显隐结论,nil = 还没执行过。
    ///   - isVanished: 卡片此刻是不是缩在刘海里。
    ///   - hasPendingHide: 是否有一次延迟隐藏在排队。
    ///
    /// 立刻隐藏(不做缩回动画)的三种情况:用户把灵动岛整个关掉(`isVisible` false)、窗口本来就还没显示过
    /// (`lastApplied` nil)、系统开了减弱动态效果。
    public static func step(shouldShow: Bool, isVisible: Bool, lastApplied: Bool?, isVanished: Bool,
                            reduceMotion: Bool, hasPendingHide: Bool) -> Step {
        if shouldShow {
            return .show(orderFront: lastApplied != true, replayReveal: lastApplied != true || isVanished)
        }
        guard lastApplied != false else { return .alreadyHidden }
        guard isVisible, lastApplied == true, !reduceMotion else { return .hideNow }
        return hasPendingHide ? .keepPendingVanish : .startVanish
    }
}
