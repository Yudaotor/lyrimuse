import Foundation
import AppKit

// 导入/导出配置——方便换电脑:导出打包 collector 的 config.json(账号 token/密钥原文都在
// 里面)+ features.json(功能开关/歌词源排序等)+ App 自己的 UserDefaults(np: 前缀 +
// KeyboardShortcuts 库自己的 KeyboardShortcuts_ 前缀,后者是热键绑定,不归 AppSettings
// 管但同样是"这台机器的个人设置"的一部分)三部分,合并成一份 JSON。
//
// 跟 DiagnosticsExporter 刻意反着来:那个绝不能包含任何 token 原文(设计给贴进公开
// issue);这个就是要把 token 原文原样带走(设计给换新机器用),所以 UI 上要有反过来的
// 警示——"这份文件包含你的账号密钥，不要分享给别人"。
enum ConfigPortability {
    private static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/applemusic-nowplaying")
    private static let configURL = configDir.appendingPathComponent("config.json")
    private static let featuresURL = configDir.appendingPathComponent("applemusic-nowplaying-features.json")

    // np: 前缀里唯独不带走这三个:
    // - hasCompletedOnboarding / hasShownAutomationOnboarding:引导流程是不是走完了,
    //   这是"这台机器"的状态,不是用户的偏好——新机器本来就该自己走一遍引导(自动化权限/
    //   常驻服务都是每台机器各自要重新授权/重新装的,带着旧机器"已完成"的标记过去,新
    //   机器反而不会弹出引导,用户会找不到入口去处理这两件事)。
    // - overlayStyle:已废弃的迁移专用字段,不是当前设置(见 AppSettings.swift 注释)。
    private static let excludedDefaultsKeys: Set<String> = [
        "np:hasCompletedOnboarding",
        "np:hasShownAutomationOnboarding",
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
        ]

        if let configData = try? Data(contentsOf: configURL),
           let configObj = try? JSONSerialization.jsonObject(with: configData) {
            bundle["config"] = configObj
        }
        if let featuresData = try? Data(contentsOf: featuresURL),
           let featuresObj = try? JSONSerialization.jsonObject(with: featuresData) {
            bundle["features"] = featuresObj
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
            return false
        }

        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        if let configObj = bundle["config"],
           let configData = try? JSONSerialization.data(withJSONObject: configObj, options: [.prettyPrinted]) {
            try? configData.write(to: configURL, options: .atomic)
        }
        if let featuresObj = bundle["features"],
           let featuresData = try? JSONSerialization.data(withJSONObject: featuresObj, options: [.prettyPrinted]) {
            try? featuresData.write(to: featuresURL, options: .atomic)
        }
        if let appSettings = bundle["appSettings"] as? [String: Any] {
            for (key, value) in appSettings {
                guard !excludedDefaultsKeys.contains(key) else { continue }
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        return true
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
