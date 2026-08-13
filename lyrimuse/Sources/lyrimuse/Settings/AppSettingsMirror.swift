import Foundation
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "settings-mirror")

/// 把 App 自己的偏好(界面外观、快捷键、歌词源顺序……)镜像成配置文件夹里的一个 JSON 文件。
///
/// ## 为什么需要它
///
/// 这个 App 的配置本来分裂在两处:collector 那半在 `~/.config/lyrimuse/`(config.json +
/// lyrimuse-features.json,纯文本),App 自己这半在 UserDefaults。导出/导入把两边合成一份
/// 包,所以那条路是完整的;但"打开配置文件夹、把它拷到另一台机器"这条路只覆盖了 collector
/// 那半 —— 外观、快捷键、歌词源排序会**静默丢掉**,而用户看不出少了什么。
///
/// 2026-08-13 用户直接指出了这个裂缝:配置文件夹的预期就是"除了机器专属的,其余都在里面"。
/// 这个类补上那一半:偏好一变就写一份镜像进同一个目录,于是"整个文件夹"真的等于"整份配置"。
///
/// ## 谁是权威
///
/// **UserDefaults 是权威,这个文件是它的镜像。** 没有做成双向同步 —— 双向就要回答"两边都
/// 变过、谁赢"，而这个问题在单机场景下根本不需要存在。
///
/// 镜像只在一种情况下被读回去:`restoreIfPristine()` —— 这台机器还没有自己的偏好
/// (`np:hasCompletedOnboarding` 不存在,即全新装机或刚"清除所有设置"过),而配置文件夹里
/// 已经有一份镜像。那只可能是用户自己拷进来/让 dotfiles 工具铺进来的,意图明确,不用再问。
/// 一旦恢复过,UserDefaults 就有值了,这个分支自然不会再命中 —— 天然只发生一次,不需要
/// 像 Rectangle 那样把投放的文件改名加时间戳来防重复。
///
/// ## 内容范围
///
/// 复用 `ConfigPortability.exportableAppSettings()`,也就是跟导出包里 appSettings 段
/// **完全一样**的那批键 —— 已经减去了机器专属的(屏幕坐标、显示器 ID、装没装 LaunchAgent、
/// 引导进度)和已经死掉的。所以拷这个文件到新机器不会带过去任何"在那台机器上不成立"的东西。
enum AppSettingsMirror {
    static let filename = "lyrimuse-app-settings.json"

    static var fileURL: URL {
        ConfigPortability.configFolderURL.appendingPathComponent(filename)
    }

    /// 写盘防抖。41 个 np: 键里有一批是拖滑块/调颜色时连续变化的(字号、宽度、各种颜色),
    /// 每次变化都写一遍盘纯属浪费。攒 2 秒再写一次,只落最后那个状态。
    private static let debounce: Duration = .seconds(2)
    // 唯一的可变状态,所以隔离范围就收在它和 startObserving 上,别的方法保持非隔离。
    @MainActor private static var pendingWrite: Task<Void, Never>?

    /// 立刻写一份镜像。导入配置之后要显式调一次(见 ConfigPortability.importData)。
    static func write() {
        let payload = ConfigPortability.exportableAppSettings()
        guard !payload.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(
                at: ConfigPortability.configFolderURL, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            // 目前这批键里没有任何凭据(密钥全在 config.json),但仍然走 writeSecurely ——
            // 以后往 np: 里加了带密的东西时,不必再回头想起还有这个文件要收紧权限。
            try data.writeSecurely(to: fileURL)
        } catch {
            // 写不成不影响 App 正常用(UserDefaults 才是权威),只记一笔。
            logger.error("mirror write failed — \(String(describing: error), privacy: .public)")
        }
    }

    /// 监听偏好变化,防抖后写镜像。
    ///
    /// 用 `UserDefaults.didChangeNotification` 而不是在 AppSettings 那 40 多个 didSet 里
    /// 各加一句:那样每新增一个设置项都得记得补一行,漏一处就是"这个设置不进镜像"这种
    /// 很难发现的缺口。这个通知是全域的,任何键变化都会来,配上防抖正好。
    ///
    /// 不会自激:这里写的是**文件**,不碰 UserDefaults。
    @MainActor
    static func startObserving() {
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                pendingWrite?.cancel()
                pendingWrite = Task { @MainActor in
                    try? await Task.sleep(for: debounce)
                    guard !Task.isCancelled else { return }
                    write()
                }
            }
        }
    }

    /// 全新机器上从配置文件夹里那份镜像恢复偏好。返回是否真的恢复了。
    ///
    /// ⚠️ 必须在**任何代码读 UserDefaults 之前**调用 —— AppSettings 是在 init 里一次性把
    /// 所有属性从 UserDefaults 读进内存的,恢复晚了就只写进了盘、这次启动的内存态还是空的
    /// (界面上看不出变化,要等下次启动)。目前的调用点是
    /// AppDelegate.applicationDidFinishLaunching 的**第一行**,而 AppSettings.shared 在
    /// 同一个函数里靠后才首次被访问。
    @discardableResult
    static func restoreIfPristine() -> Bool {
        // 判据用 hasCompletedOnboarding:它是"这台机器走完引导了没有",而且被刻意排除在
        // 导出/镜像之外(见 ConfigPortability 的排除表),所以它在新机器上一定不存在 ——
        // 正好是"这台机器还没有自己的偏好"最可靠的信号。
        guard UserDefaults.standard.object(forKey: "np:hasCompletedOnboarding") == nil else {
            return false
        }
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !dict.isEmpty
        else { return false }

        let applied = ConfigPortability.applyAppSettings(dict)
        logger.notice("restored \(applied) app setting(s) from the config folder mirror")
        return applied > 0
    }

    /// "清除所有设置"要把镜像一起删掉 —— 留着它,下次启动会立刻从它恢复回来,
    /// 用户点的那个"恢复到刚装完的样子"就等于没生效。
    static func remove() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
            logger.info("removed the app-settings mirror")
        } catch {
            logger.error("removing the mirror failed — \(String(describing: error), privacy: .public)")
        }
    }
}
