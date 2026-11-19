import Foundation

/// 歌词窗口跨重启要接着的「开着没有、是不是迷你」两个键,以及隐身开窗(`invisible=1`)留下的标记。
/// 隐身开的那扇用户看不见,不算用户开着的窗口:重启后不重开,形态还回隐身开之前那样。
/// 用户原本就开着时隐身操作不留标记,重启照原样重开。见 14 章决策 234。
public enum LyricsWindowOpenRecord {
    /// 窗口此刻开着没有:打开写 true,用户关窗写 false,退出 App 途中的关窗不算(那是「开着退出」)。
    public static let openKey = "np:lyricsWindowOpen"
    /// 上次是不是迷你。
    public static let miniModeKey = "np:lyricsWindowMiniMode"
    /// 开着的那扇是隐身开的;值是隐身开之前的「是不是迷你」。有这个键就是隐身开的。
    public static let invisibleOpenKey = "np:lyricsWindowInvisibleOpen"

    public static func isOpen(_ defaults: UserDefaults) -> Bool { defaults.bool(forKey: openKey) }

    public static func isInvisibleOpen(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: invisibleOpenKey) != nil }

    /// 隐身开窗之前调(要赶在写「是不是迷你」之前):窗口原本没开、也还没记过,就记下此刻的形态。
    public static func noteInvisibleOpen(_ defaults: UserDefaults) {
        guard !isOpen(defaults), !isInvisibleOpen(defaults) else { return }
        defaults.set(defaults.bool(forKey: miniModeKey), forKey: invisibleOpenKey)
    }

    /// 记「窗口开着」。返回 true = 从没开变成开着。`invisibly` 时同 `noteInvisibleOpen` 留标记。
    @discardableResult
    public static func markOpen(_ defaults: UserDefaults, invisibly: Bool) -> Bool {
        guard !isOpen(defaults) else { return false }
        if invisibly { noteInvisibleOpen(defaults) }
        defaults.set(true, forKey: openKey)
        return true
    }

    /// 正常打开歌词窗口时调:隐身开着的那扇从此算用户的,重启照常重开。
    public static func claim(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: invisibleOpenKey)
    }

    /// 记成没开(用户关窗、静默启动没重开)。隐身开的那扇关掉时,形态还回隐身开之前那样。
    public static func forget(_ defaults: UserDefaults) {
        if let mini = defaults.object(forKey: invisibleOpenKey) as? Bool {
            defaults.set(mini, forKey: miniModeKey)
            defaults.removeObject(forKey: invisibleOpenKey)
        }
        defaults.set(false, forKey: openKey)
    }

    /// 启动时、读「开着」之前调一次:上次退出时开着的是隐身开的那扇,就当它关了。
    public static func settleAtLaunch(_ defaults: UserDefaults) {
        if isInvisibleOpen(defaults) { forget(defaults) }
    }
}
