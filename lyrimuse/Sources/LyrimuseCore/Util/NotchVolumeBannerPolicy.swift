import Foundation

/// 系统音量变了时灵动岛弹不弹音量横幅。
///
/// 「按音量键时提示」开着时每次变化都弹;关着时只弹灵动岛自己(触控板手势、滚轮)调出来的那几次,
/// 键盘音量键、耳机按键、别的 App 改的音量交给系统自己的提示,两边不同时弹。
/// 监听只知道值变了、不知道是谁改的,所以按「离灵动岛上一次写音量多久」认:写完到回调经 CoreAudio 的串行队列
/// 再跳主线程,通常几十毫秒就到,`ownAdjustWindow` 内收到的变化算自己调的。
/// 见 05 章决策 129。
public enum NotchVolumeBannerPolicy {
    public static let ownAdjustWindow: TimeInterval = 1.0

    /// `sinceOwnAdjust`:离灵动岛上一次写音量或解除静音过了多少秒,没写过是 nil。
    public static func shows(forVolumeKeys: Bool, sinceOwnAdjust: TimeInterval?) -> Bool {
        if forVolumeKeys { return true }
        guard let sinceOwnAdjust else { return false }
        return sinceOwnAdjust >= 0 && sinceOwnAdjust < ownAdjustWindow
    }
}
