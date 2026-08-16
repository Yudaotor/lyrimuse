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
final class SparkleUpdaterManager: ObservableObject {
    static let shared = SparkleUpdaterManager()

    let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    // 这两个开关**不**在 AppSettings 里另存一份。Sparkle 自己就把它们持久化在
    // UserDefaults(SUEnableAutomaticChecks / SUAutomaticallyUpdate),而它内部做周期
    // 检查时读的是它自己那份 —— 我们再存一份就有了两个真相,UI 显示的和实际生效的迟早
    // 对不上(比如 Sparkle 首次运行时弹的"要不要自动检查更新"对话框会直接改它那份,
    // 而我们这份完全不知情)。所以这里只做转发,objectWillChange 手动发一下让 UI 刷新。
    //
    // build.sh 写进 Info.plist 的 SUEnableAutomaticChecks 是**默认值**,用户改过之后
    // 以 UserDefaults 为准,两者不冲突。
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// ⚠️ 只在 automaticallyChecksForUpdates 为 true 时才有意义(Sparkle 的语义:
    /// 先有周期检查,才谈得上自动下载),UI 上因此把它做成从属行并跟着置灰。
    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    // 给"关于"页的手动"检查更新"按钮用——sender 传 nil 时 Sparkle 自己处理"检查中/
    // 已是最新/发现新版本"这几种状态的 UI 展示,不需要我们自己维护 loading 状态或者
    // 判断结果再手动弹 alert(旧 UpdateChecker.swift 那套手写逻辑才需要自己管这些)。
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
