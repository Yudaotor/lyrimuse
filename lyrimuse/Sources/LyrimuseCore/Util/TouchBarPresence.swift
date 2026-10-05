import Foundation

/// 这台 Mac 此刻有没有一块触控栏(真机,或者 Xcode 的触控栏模拟器开着)。判据只此一份:`TouchBarAvailability`
/// 照着判,selftest 钉着。不按机型查表,只认系统此刻在不在驱动一块触控栏。
///
/// 分两层看:
/// 1. 系统的 ControlStrip 在不在跑。它由 launchd 在系统匹配到触控栏时拉起(`com.apple.touchbar.matching`),
///    没在跑就一定没有,而且不用再往下问 —— 下一层要连 TouchBarServer,那是按需启动、起来就不退的守护进程,
///    在没有触控栏的 Mac 上问一次就白白叫起来一个。
/// 2. 在跑,再看 DFRFoundation 报告的主触控栏还在不在:模拟器关掉之后 ControlStrip 不退,只有这一项会变空。
///    这一项查不了(接口缺了)时按「有」算,只靠第一层判。
public enum TouchBarPresence {
    public static func isPresent(controlStripRunning: Bool, touchBarReported: Bool?) -> Bool {
        guard controlStripRunning else { return false }
        return touchBarReported ?? true
    }
}
