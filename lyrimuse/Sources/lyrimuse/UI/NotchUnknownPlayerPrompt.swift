import Foundation
import LyrimuseCore
import OSLog

/// 灵动岛上的「发现新播放器」提示(2026-09-11)。用户原话:「正常那些软件被识别到之后,不是会有一个通知吗?
/// 那个通知里的逻辑,我是否可以把它加到灵动岛里?这样可能会更明显一点」;边界:「如果这个时候用户开启了
/// 灵动岛才生效哦」。
///
/// 两层,状态都挂在这一个单例上;`NotchLyricsView` 的两个小宿主子视图(左耳图标 / 空闲面板)和
/// `NotchLyricsWindowController`(含「所有屏幕」模式下的每个副本)各自订阅:
///  - **被动提示**(`offer`):判据 = `UnknownPlayerAlert.qualifiesForAnnounce` —— 跟系统通知**同一套**门槛
///    (静音名单 / 反查得到 App 名 / 稳定 6 秒 3 次),只不看次数 / 冷却;由 `UnknownPlayerNotifier.tick` 每
///    5 秒喂一次。挂着时收起态左耳那枚 Lyrimuse 图标换成**那个播放器**的图标 + 一粒小圆点,hover 展开的
///    空闲面板变成「检测到新的播放器 · 正在放:… [加入信任列表] ×」。播放器停了(观察陈旧)/ 被信任了 /
///    点了 × 就撤。
///  - **主动提醒**(`isAlerting`):跟系统通知**同一拍**触发(`UnknownPlayerNotifier.announce`,共用同一份
///    3 次 / 24h 提醒记录),控制器据此把卡片自己撑开 `UnknownPlayerAlert.notchAlertDuration` 秒 —— 对齐 iPhone
///    灵动岛的 AirPods 连接提醒;开着「暂停/无播放时隐藏」时顺带把窗口叫回来。到点收回,光标停在上面不收。
///
/// 为什么落在"没有曲目"那套形态上:未信任的播放器被 `MediaControlClient` 的闸挡在外面,App 视角**没有
/// 曲目**,歌词行不渲染,盖在歌词行上的瞬态横幅(`NotchTransientCenter`)无处可显示;空闲面板(05 章决策 #31)
/// 正是这时候 hover 展开出来的那一块,在它上面做变体,有曲目 / 没曲目 / 有新播放器三种展开出来的仍是"同一个
/// 位置上的同一种东西"。
///
/// 只在灵动岛开着时有内容(`AppSettings.notchOverlayEnabled`,由 notifier 那侧判);关着时 `offer` 恒 nil、
/// alert 不触发,用户只剩系统通知那条路 —— 这是用户定的边界,不是漏做。
///
/// ⚠️ 这个类**不引用** `NotchLyricsWindowController.shared`(是控制器来订阅它,不是反过来):引用 `.shared` 会
/// 执行 init 建窗口并立刻 orderFront,经典悬浮窗用户会凭空多出一个胶囊,见控制器文件头那条不变量。
@MainActor
final class NotchUnknownPlayerPrompt: ObservableObject {
    static let shared = NotchUnknownPlayerPrompt()
    /// 设置页编辑台预览用的替身:永远没有 offer、永远不提醒。`NotchLyricsView` 默认拿的就是它,只有真窗口
    /// (`NotchWindowRoot`)才传 `shared` —— 默认值选"惰性"那份,忘了传的后果是"预览看不到提示",而不是
    /// "预览上凭空冒出一条信任提议"。
    static let inert = NotchUnknownPlayerPrompt()

    struct Offer: Equatable {
        let bundleID: String
        /// App 的显示名(反查得到才会有 offer,见 `qualifiesForAnnounce` ⑥)。
        let displayName: String
        /// 「正在放:…」那一截;拼不出来时是 bundle id(跟通知正文同一口径,`UnknownPlayerAlert.nowPlayingDescription`)。
        let nowPlayingText: String
    }

    /// 被动提示此刻挂着的那个播放器;nil = 没有。
    @Published private(set) var offer: Offer?
    /// 主动提醒进行中。
    @Published private(set) var isAlerting = false

    private let log = Logger(subsystem: "me.yudaotor.lyrimuse", category: "notify")
    private var alertTask: Task<Void, Never>?
    /// 点了 × 的那个播放器:同一段连续播放里不再挂它;换了播放器、或它停了(notifier 传 nil)就清掉 ——
    /// 下次再放照旧提议。不落盘:× 的语义是"这次别烦我",不是"永远别提"(那是「加入信任列表」的反面,
    /// 没有这个动作)。
    private var dismissedBundleID: String?

    private init() {}

    /// notifier 每拍调一次。同一个 offer 重复喂进来不发布(判等),别打醒卡片。
    func update(offer next: Offer?) {
        guard let next else {
            dismissedBundleID = nil
            if offer != nil { offer = nil }
            endAlert()
            return
        }
        if next.bundleID != dismissedBundleID { dismissedBundleID = nil }
        let visible: Offer? = next.bundleID == dismissedBundleID ? nil : next
        if offer != visible { offer = visible }
    }

    /// 主动提醒一次(卡片撑开 `notchAlertDuration` 秒)。返回 false = 此刻没有挂着的 offer(被 × 过 / 灵动岛
    /// 关着 / 还没喂进来),调用方据此决定这次算不算"提醒过"。连着两次以最后一次为准(cancel-rearm,
    /// 同 `NotchTransientCenter.show` 的取消再查 `Task.isCancelled` 那一套)。
    @discardableResult
    func alert() -> Bool {
        guard let current = offer else { return false }
        alertTask?.cancel()
        if !isAlerting { isAlerting = true }
        alertTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(UnknownPlayerAlert.notchAlertDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.alertTask = nil
            if self?.isAlerting == true { self?.isAlerting = false }
        }
        log.notice("notch alert for \(current.bundleID, privacy: .public)")
        return true
    }

    /// 那颗 ×:撤掉提示、结束提醒;这个播放器这段播放里不再提。
    func dismiss() {
        guard let current = offer else { return }
        dismissedBundleID = current.bundleID
        offer = nil
        endAlert()
    }

    /// 「加入信任列表」:立刻撤掉提示(不等下一拍 notifier 发现它已被接受),再走通知那颗按钮同一条写入路
    /// (`UnknownPlayerNotifier.trust`,它会顺手撤掉通知中心里那条)。
    func trust() {
        guard let current = offer else { return }
        offer = nil
        endAlert()
        Task { await UnknownPlayerNotifier.trust(current.bundleID) }
    }

    private func endAlert() {
        alertTask?.cancel()
        alertTask = nil
        if isAlerting { isAlerting = false }
    }
}
