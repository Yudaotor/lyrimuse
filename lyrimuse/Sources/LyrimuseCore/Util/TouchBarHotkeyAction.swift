import Foundation

/// 全局快捷键「展开/收起触控栏歌词」按下去做哪一件:照触控栏上此刻看不看得见歌词来翻,总开关关着就先打开。
///
/// 别改成翻总开关:点 ✕ 收起之后开关还开着,翻开关会连功能栏图标一起关掉,得按两次歌词才回来(17 章决策 40)。
public enum TouchBarHotkeyAction: Equatable, Sendable {
    /// 这台 Mac 此刻没有触控栏(`TouchBarPresence`)。
    case noTouchBar
    /// 系统里取不到触控栏的私有入口,开关打开也不会生效。
    case unavailable
    /// 总开关关着:打开它,打开那一下当场展开(同设置里拨开开关)。
    case turnOn
    /// 开着、此刻看不见(收着,或者被别的系统模态条盖住):展开。
    case expand
    /// 开着、看得见:收回成功能栏图标(同 ✕)。
    case collapse

    public static func resolve(touchBarPresent: Bool, entryPointsAvailable: Bool, switchOn: Bool,
                               visible: Bool) -> TouchBarHotkeyAction {
        guard touchBarPresent else { return .noTouchBar }
        guard entryPointsAvailable else { return .unavailable }
        guard switchOn else { return .turnOn }
        return visible ? .collapse : .expand
    }
}
