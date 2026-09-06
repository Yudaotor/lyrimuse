import LyrimuseCore
import Foundation
import OSLog
import ServiceManagement

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "login-item")

// 「开机启动」= 系统登录项(`SMAppService.mainApp`,macOS 13+),2026-09-06 起。
//
// 此前是自己往 ~/Library/LaunchAgents 写一份经典 LaunchAgent plist(RunAtLoad、无 KeepAlive)。
// 那条路的代价当天才量出来:**由 launchd 直接 exec 二进制拉起的 App,launchd 记为
// `spawn type = daemon`**,按 launchd.plist(5) 对没写 ProcessType 的 job "apply light resource
// limits" —— 主线程 97% 的时间跑在调度优先级 **20**(utility 档),Music / Finder 这类正常
// App 的主线程是 46。灵动岛动画专项的 System Trace 就是这么看出来的(05 章决策 #25)。plist 加
// `ProcessType = Interactive` 只抬到 31;只有经 LaunchServices 起(登录项 / `open`)才是 46。
// 登录项正是 Apple 给"随登录启动的 GUI App"的正道:由 LaunchServices 按 App 的身份启动,
// 单实例、优先级、App Nap 策略都跟双击打开一模一样,System Settings → 通用 → 登录项里也能看到。
//
// 14 章决策 9 曾写"ad-hoc 签名限制了 SMAppService 等官方路径",这次实测(ad-hoc 签名、装在
// /Applications)`register()` 成功、状态 `.enabled`,那条判断按实测订正。
//
// ⚠️ 三条纪律沿用 2026-09-03 那次「点一下开机启动就闪退」修了三次收口的教训(selftest
// contracts ⑯ 守着):这个文件里**不准出现 launchctl、不准起子进程**。SMAppService 是进程内
// API,register/unregister 只改登录项的注册状态,不启动也不杀任何进程 —— 关掉开关不会像当年
// `launchctl bootout` 自己那样等于给自己发 SIGTERM。
@MainActor
final class LoginItemManager {
    static let shared = LoginItemManager()

    /// 旧方案那份 plist 的落点(= CFBundleIdentifier 按变体派生,唯一口径在 Core LyrimuseIdentity)。
    /// 现在只用来**删**:升级上来的用户机器上它还在,不删的话下次登录 launchd 还会按旧方式再起一份
    /// (优先级 20 的那份),跟登录项起的那份并存,只靠 AppDelegate.terminateOlderInstances 兜底。
    private var legacyPlistURL: URL {
        LyrimusePaths.launchAgentPlist(label: LyrimuseIdentity.appLaunchdLabel)
    }

    private init() {}

    /// 登录项此刻的真实状态(设置页 / 菜单读 AppSettings 的开关,这里是系统那一侧的真值)。
    var status: SMAppService.Status { SMAppService.mainApp.status }

    /// 用户拨开关(设置页 / 菜单栏 / 引导页三处都经 AppSettings.launchAtLoginEnabled 的 didSet 到这里)。
    func setEnabled(_ enabled: Bool) {
        removeLegacyLaunchAgentPlist()
        if enabled {
            register()
            // 用户在 System Settings 里把这个登录项关过之后,再 register 会停在 requiresApproval ——
            // 开关看着开了、登录时却不起。这是**用户主动**拨的开关,把系统设置的登录项面板打开让他
            // 点一下是 Apple 自己样例里的做法;启动时那条自动同步(syncAtLaunch)不做这一步,
            // 不能每次开机弹一个系统设置页出来。
            if status == .requiresApproval {
                logger.notice("login item requires approval in System Settings; opening the pane")
                SMAppService.openSystemSettingsLoginItems()
            }
        } else {
            unregister()
        }
    }

    /// App 启动时调一次:清掉旧方案的 plist;开关开着就幂等地补一次注册(默认值那次赋值不触发
    /// didSet,不补的话"默认开"只停在偏好里)。用户手动关掉之后这里读到 false,不会偷偷再打开。
    func syncAtLaunch(enabled: Bool) {
        removeLegacyLaunchAgentPlist()
        guard enabled else { return }
        register()
    }

    /// 卸载脚本(scripts/uninstall.sh)用:`lyrimuse --unregister-login-item`。App 包一删,登录项会
    /// 在 System Settings 里留一条指向不存在路径的死项;Apple 的口径是删 App 之前先 unregister。
    func unregisterForUninstall() {
        removeLegacyLaunchAgentPlist()
        unregister()
    }

    private func register() {
        do {
            try SMAppService.mainApp.register()
            logger.notice("login item registered status=\(String(describing: self.status), privacy: .public)")
        } catch {
            // 常见原因:App 不在 LaunchServices 认的位置(开发时直接跑 .build/ 里的二进制),
            // 或被 MDM 策略禁止。个人小工具,静默失败可接受;状态在日志里,诊断导出带得上。
            logger.error("login item register failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func unregister() {
        do {
            try SMAppService.mainApp.unregister()
            logger.notice("login item unregistered")
        } catch {
            // 本来就没注册也会抛(kSMErrorJobNotFound),不算错。
            logger.notice("login item unregister: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 只删文件、不碰 launchd:本次会话里那个 job 若还挂着(开机自启走的就是它),bootout 等于
    /// 杀自己;它没有 KeepAlive、退出后不复活,留到登出自然消失。plist 一删,下次登录 launchd 就
    /// 读不到它了 —— 这正是当年"一个偏好开关不该启动或杀死任何进程"那条纪律的全部机制。
    private func removeLegacyLaunchAgentPlist() {
        let url = legacyPlistURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            logger.notice("removed legacy LaunchAgent plist \(url.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("failed to remove legacy LaunchAgent plist: \(error.localizedDescription, privacy: .public)")
        }
    }
}
