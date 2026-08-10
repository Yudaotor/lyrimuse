import Foundation
import AppKit
import OSLog

// 导入路径里每一步(JSON 解析/写 config.json/写 features.json)失败都只记日志、不
// 中断后续步骤(见下面 importData 内部注释)——这样才能区分"整个没解析出来"和"部分
// 文件写失败"。日志里绝不记文件内容本身(config.json 里就是原始 token)。
private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "config-portability")

// 导入/导出配置——方便换电脑:导出打包 collector 的 config.json(账号 token/密钥原文都在
// 里面)+ features.json(功能开关/歌词源排序等)+ App 自己的 UserDefaults(np: 前缀 +
// KeyboardShortcuts 库自己的 KeyboardShortcuts_ 前缀,后者是热键绑定,不归 AppSettings
// 管但同样是"这台机器的个人设置"的一部分)三部分,合并成一份 JSON。
//
// 跟 DiagnosticsExporter 刻意反着来:那个绝不能包含任何 token 原文(设计给贴进公开
// issue);这个就是要把 token 原文原样带走(设计给换新机器用),所以 UI 上要有反过来的
// 警示——"这份文件包含你的账号密钥，不要分享给别人"。
//
// clearAllConfig() 是跟 import 反着来的第三个操作——不是"换一份配置进来"而是"清空
// 回到刚装完的样子",供 SettingsView 的"清除所有配置"按钮用。
enum ConfigPortability {
    private static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lyrimuse")
    private static let configURL = configDir.appendingPathComponent("config.json")
    private static let featuresURL = configDir.appendingPathComponent("lyrimuse-features.json")

    // np: 前缀里唯独不带走这三个:
    // - hasCompletedOnboarding / hasShownAutomationOnboarding:引导流程是不是走完了,
    //   这是"这台机器"的状态,不是用户的偏好——新机器本来就该自己走一遍引导(自动化权限/
    //   常驻服务都是每台机器各自要重新授权/重新装的,带着旧机器"已完成"的标记过去,新
    //   机器反而不会弹出引导,用户会找不到入口去处理这两件事)。
    // - overlayStyle:已废弃的迁移专用字段,不是当前设置(见 AppSettings.swift 注释)。
    // - hasOfferedICloudImport:"这台机器已经问过要不要从 iCloud 导入"——同样是本机
    //   状态,带过去会让新机器不再弹那一问(见 AppSettings 里同名属性的注释)。
    private static let excludedDefaultsKeys: Set<String> = [
        "np:hasCompletedOnboarding",
        "np:hasShownAutomationOnboarding",
        "np:hasOfferedICloudImport",
        "np:overlayStyle",
    ]

    static func suggestedFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Lyrimuse-Config-\(formatter.string(from: Date())).json"
    }

    static func buildExportData() -> Data? {
        var bundle: [String: Any] = [
            "version": 1,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            // 从哪台机器导出的。iCloud 文件夹里会攒着好几份配置,只有时间戳的话分不清
            // 是哪台机器写的 —— 导入前的那句确认里要能说清楚"这份来自谁"。
            // 只是台机器名,不是敏感信息。
            "deviceName": Host.current().localizedName ?? "",
        ]

        if let configData = try? Data(contentsOf: configURL),
           let configObj = try? JSONSerialization.jsonObject(with: configData) {
            bundle["config"] = configObj
        } else {
            // 不一定是错误——采集器可能还没跑过、config.json 本来就不存在,只是留个痕迹
            // 方便"导出的文件里怎么少了 config 这部分"这类问题的排查。
            logger.notice("buildExportData: no config.json found/parseable at \(configURL.path, privacy: .public)")
        }
        if let featuresData = try? Data(contentsOf: featuresURL),
           let featuresObj = try? JSONSerialization.jsonObject(with: featuresData) {
            bundle["features"] = featuresObj
        } else {
            logger.notice("buildExportData: no features.json found/parseable at \(featuresURL.path, privacy: .public)")
        }

        var appSettings: [String: Any] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() {
            guard key.hasPrefix("np:") || key.hasPrefix("KeyboardShortcuts_") else { continue }
            guard !excludedDefaultsKeys.contains(key) else { continue }
            appSettings[key] = value
        }
        bundle["appSettings"] = appSettings

        return try? JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted, .sortedKeys])
    }

    // 导入不做任何"活的"reload——config.json/features.json 各自的 Store 都有 load()
    // 能立刻刷新内存态,但真正读 config.json 的是 collector 那个独立进程,不会因为
    // Swift 侧调用 load() 就跟着重读;AppSettings 每个属性各自 didSet 里都会触发真实
    // 副作用(装/卸 LaunchAgent、注册热键……),导入时一次性把二十几个属性全部重新赋值
    // 会级联触发一整串这些副作用,风险和复杂度都远高于收益。改成写完盘之后统一提示重启
    // 整个 App——等价于一次全新的 AppSettings.init(),每个副作用只在启动时按正常顺序
    // 触发一次,行为跟"刚装完/换了台新机器"完全一致,不用为导入这一件事单独维护一套
    // "热重载"逻辑。
    @discardableResult
    static func importData(_ data: Data) -> Bool {
        guard let bundle = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("importData: top-level JSON parse failed — not a valid export file")
            return false
        }

        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        } catch {
            logger.error("importData: createDirectory(\(configDir.path, privacy: .public)) failed — \(String(describing: error), privacy: .public)")
        }

        if let configObj = bundle["config"] {
            if let configData = try? JSONSerialization.data(withJSONObject: configObj, options: [.prettyPrinted]) {
                do {
                    try configData.write(to: configURL, options: .atomic)
                } catch {
                    logger.error("importData: writing config.json failed — \(String(describing: error), privacy: .public)")
                }
            } else {
                logger.error("importData: re-serializing 'config' from the import bundle failed")
            }
        } else {
            logger.notice("importData: import bundle has no 'config' section")
        }
        if let featuresObj = bundle["features"] {
            if let featuresData = try? JSONSerialization.data(withJSONObject: featuresObj, options: [.prettyPrinted]) {
                do {
                    try featuresData.write(to: featuresURL, options: .atomic)
                } catch {
                    logger.error("importData: writing features.json failed — \(String(describing: error), privacy: .public)")
                }
            } else {
                logger.error("importData: re-serializing 'features' from the import bundle failed")
            }
        } else {
            logger.notice("importData: import bundle has no 'features' section")
        }
        if let appSettings = bundle["appSettings"] as? [String: Any] {
            for (key, value) in appSettings {
                guard !excludedDefaultsKeys.contains(key) else { continue }
                UserDefaults.standard.set(value, forKey: key)
            }
            logger.info("importData: applied \(appSettings.count) appSettings keys")
        } else {
            logger.notice("importData: import bundle has no 'appSettings' section")
        }
        return true
    }

    // "清除所有配置"——回到刚装完时的样子。跟上面 import/export 用同一套
    // 文件+UserDefaults 盘点逻辑,但故意不复用 excludedDefaultsKeys:那个集合是"换机器
    // 场景下不该带走"的字段(引导状态/废弃字段),这里恰恰要连这几个也一起清掉——
    // hasCompletedOnboarding 被清空后,下次启动会重新走一遍引导向导,这正是"最原始配置"
    // 应有的样子,不是遗漏。
    //
    // 清完不在这里做任何"活的"reload,原因跟 importData 那条注释一样:统一交给调用方
    // 紧接着调 restartApp()。这一点还顺带解决了一个不那么直观的连锁反应——
    // AppSettings.collectorServiceEnabled 清空后读回来是默认值 false,它的 didSet 会调
    // CollectorServiceManager.setEnabled(false)→uninstall(),而 Swift 对 init() 内部
    // 显式赋值一样会触发 didSet(不是只对运行期赋值生效的坑,这里刚好是期望行为)——
    // 于是"清除配置+重启 App"顺带就把常驻服务的 LaunchAgent 卸载了,不需要在这里
    // 另外手动调用 launchctl,行为完全等价于全新装机、还没跑过引导向导。
    @discardableResult
    static func clearAllConfig() -> Bool {
        var ok = true
        if FileManager.default.fileExists(atPath: configURL.path) {
            do { try FileManager.default.removeItem(at: configURL) }
            catch {
                logger.error("clearAllConfig: removing config.json failed — \(String(describing: error), privacy: .public)")
                ok = false
            }
        }
        if FileManager.default.fileExists(atPath: featuresURL.path) {
            do { try FileManager.default.removeItem(at: featuresURL) }
            catch {
                logger.error("clearAllConfig: removing features.json failed — \(String(describing: error), privacy: .public)")
                ok = false
            }
        }
        var clearedCount = 0
        for key in UserDefaults.standard.dictionaryRepresentation().keys {
            guard key.hasPrefix("np:") || key.hasPrefix("KeyboardShortcuts_") else { continue }
            UserDefaults.standard.removeObject(forKey: key)
            clearedCount += 1
        }
        logger.info("clearAllConfig: cleared \(clearedCount) UserDefaults keys, filesRemovedOK=\(ok)")
        return ok
    }

    @MainActor
    static func restartApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        NSApp.terminate(nil)
    }
}
