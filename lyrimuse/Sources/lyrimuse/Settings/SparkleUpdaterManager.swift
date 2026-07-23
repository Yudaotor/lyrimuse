import AppKit
import Sparkle

// 检查更新——用 Sparkle(macOS 生态里事实标准的自动更新框架),不是自己手写"查 GitHub
// API+弹 Alert+跳转浏览器"那套(见本文件替换掉的旧 UpdateChecker.swift)。跟这个项目里
// ConfigStore.shared/AppSettings.shared 同样的单例访问风格——AppDelegate 启动时和
// "关于"页手动点的"检查更新"按钮都从这一个实例访问,不需要额外的桥接层。
//
// startingUpdater: true 让这个 controller 一初始化就启动 Sparkle 自己的 updater
// (按 Info.plist 里 SUEnableAutomaticChecks/SUFeedURL 的配置决定要不要做周期性
// 后台检查)。updaterDelegate/userDriverDelegate 都传 nil——第一阶段先用 Sparkle
// 开箱即用的标准模态弹窗体验(SPUStandardUserDriver),不做"gentle reminders"那种
// 菜单栏图标提示的进阶定制(那需要额外处理几个 Swift 并发细节,等这套标准流程真的跑
// 起来、觉得默认弹窗体验不够好再考虑升级)。
@MainActor
final class SparkleUpdaterManager {
    static let shared = SparkleUpdaterManager()

    let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    // 给"关于"页的手动"检查更新"按钮用——sender 传 nil 时 Sparkle 自己处理"检查中/
    // 已是最新/发现新版本"这几种状态的 UI 展示,不需要我们自己维护 loading 状态或者
    // 判断结果再手动弹 alert(旧 UpdateChecker.swift 那套手写逻辑才需要自己管这些)。
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
