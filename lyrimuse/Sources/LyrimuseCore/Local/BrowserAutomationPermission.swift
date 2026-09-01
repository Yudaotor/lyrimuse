import AppKit
import Foundation

/// 浏览器"允许来自 Apple 事件的 JavaScript"开关的**检测**(2026-08-31;2026-09-01 去掉了
/// 一键开启)。
///
/// ⚠️ **只检测,不代改**。曾经有过一条"一键开启":读浏览器 profile 里的 `Preferences`(JSON)、
/// 备份、改一个 key、写回。它在这台机器上**从来没成功过** —— 别的 App 读
/// `~/Library/Application Support/<浏览器>/` 需要「完全磁盘访问权限」,没给就直接
/// `NSFileReadNoPermissionError`,第一步就断。而且那个失败**没有系统弹窗、也不进 tccd 的
/// 拒绝日志**,在终端里手动复刻同一段代码却能跑通(终端通常已有该权限),排查时极具误导性。
///
/// 2026-09-01 用户拍板整条移除、统一让用户自己去浏览器菜单里开:为一个布尔开关要求完全
/// 磁盘访问权限不划算,而且这个 App 是 ad-hoc 签名、**每次构建 cdhash 都变,TCC 授权会被
/// 下一次构建作废** —— 就算给了权限也留不住。别再把这条路加回来。
///
/// 见 `BrowserPositionProbe` 头注:这个开关是 `execute … javascript`/`do JavaScript` 探针
/// 能不能工作的前提,跟 macOS 系统层的 Automation/TCC 授权(`MusicAutomationPermission` 管
/// 的那个,有系统弹窗)完全独立,是各浏览器自己加的第二道闸,默认关闭。这里只管"检测现在
/// 开没开 + 能不能自动打开",不碰 TCC、不碰系统弹窗。
///
/// 两套完全不同的机制(2026-08-31 逐个实测坐实,没有相信直觉/记忆里的猜测——Arc 那次已经
/// 猜错过一次存储位置,这次全部靠 `strings` 翻二进制 + 实际读文件验证):
///
/// - **Chromium 系**(Arc / Chrome / Edge,同源于 Chromium 本体——三家的真实引擎二进制里都
///   搜到一模一样的 pref key 字面量 `browser.allow_javascript_apple_events`,不是 Arc 私货):
///   存在各自独立的 Preferences JSON 文件里,厂商目录名不同,但 key 名和数据形状完全一致。
///   这个开关只在**浏览器启动时读一次**,运行中改文件不会被感知,浏览器退出时还会把内存里
///   的旧值原样写回**覆盖掉**刚改的内容——所以只能在浏览器完全退出时改,改完提示用户重新
///   打开才生效。
/// - **Safari**(WebKit):完全是另一套,走 macOS 标准的 `CFPreferences`/`com.apple.Safari`
///   域,key 叫 `AllowJavaScriptFromAppleEvents`(注意大小写跟 Chromium 那个不一样,这是
///   两套独立实现,不是同一个值的两种拼法)。AppleScript 命令也不同名——Safari 用
///   `do JavaScript … in tab`,Chromium 系用 `execute (tab) javascript`,`BrowserPositionProbe`
///   自己按 family 分支生成对应语法,这里不管探测脚本,只管这个开关本身。
///
/// 没有登记在 `chromiumEntries` 或 Safari 分支里的浏览器(Firefox 等)一律 `.unsupported`——
/// 调用方应该原样跳过,不强行展示"不支持"提示,更不能瞎猜一个可能压根不对的路径去写。
public enum BrowserAutomationPermission {
    /// rawValue 用来持久化(见 `manuallyAddedFamilies` 那段的双写模式),别改这两个字符串 ——
    /// 改了等于让用户已经加过的浏览器在下次启动时解不出来、静默消失。
    public enum Family: String, Equatable {
        case chromium
        case safari
    }

    /// bundleID → 这个 Chromium 系浏览器自己的 Preferences JSON 路径。
    /// 只登记**实测验证过**存在这个 key 的浏览器——Brave/Vivaldi/Opera 大概率同源同构,但
    /// 这台机器没装、没法验证,先不瞎登记一个没实测过的路径。
    private static let chromiumPrefsPaths: [String: String] = [
        "company.thebrowser.Browser": "\(NSHomeDirectory())/Library/Application Support/Arc/User Data/Default/Preferences",
        "com.google.Chrome": "\(NSHomeDirectory())/Library/Application Support/Google/Chrome/Default/Preferences",
        "com.microsoft.edgemac": "\(NSHomeDirectory())/Library/Application Support/Microsoft Edge/Default/Preferences",
    ]
    private static let safariBundleID = "com.apple.Safari"
    private static let safariPrefKey = "AllowJavaScriptFromAppleEvents" as CFString
    private static let chromiumPrefKey = "allow_javascript_apple_events"

    /// 设置页「+」菜单里**默认列出来**的那几个浏览器,固定展示顺序(不是字典的无序 keys)。
    /// 按这份列表过滤"这台机器上装了哪些"再展示,不要求"必须先被信任过"(2026-08-31 用户
    /// 要求:选一个没信任过的已安装浏览器,应该一步自动信任+配对,而不是先逼用户去那个
    /// 浏览器里放首歌被动等检测)。
    ///
    /// ⚠️ **这是一份"默认展示"名单,不是"支持"名单 —— 两件事别混**(2026-09-01)。这里没有
    /// 的浏览器照样驱得动:能不能驱动由 `family(forBundleID:)` 说了算,而它认的是
    /// `chromiumPrefsPaths` / Safari / 用户手动加过的那批,跟这份展示名单是两套东西。
    ///
    /// ⚠️ **Arc 就是这么被拿掉的**(2026-09-01 用户拍板:「arc 不要留着,但是我们代码里对他的
    /// 适配都留着,只是不在这里显示,如果用户自己选了 arc,那就依旧按我们适配好的来走」)。
    /// Arc 在 `chromiumPrefsPaths` 里**原样留着**,`family(...)` 照样返回 `.chromium`、
    /// 那道 JS 开关的状态照样读得出来、`browserManualEnableHint` 里那条 Arc 专属菜单路径
    /// 也原样留着 —— 用户从「从应用程序中选择…」挑中它时,走的是**完整的既有适配**,一步
    /// 都不降级。少的只是"默认摆在菜单里"这一条。**别因为它不在这份名单里就去删 Arc 的
    /// 适配代码。**
    public static let knownBrowserBundleIDs: [String] = [
        "com.google.Chrome",
        "com.microsoft.edgemac", // Edge
        safariBundleID,
    ]

    public static func family(forBundleID bundleID: String) -> Family? {
        if chromiumPrefsPaths[bundleID] != nil { return .chromium }
        if bundleID == safariBundleID { return .safari }
        return manuallyAddedFamilies[bundleID]
    }

    // MARK: - 用户手动挑进来的浏览器

    /// 用户自己从「应用程序」里挑进来的浏览器 → **实测判定**出的引擎族。
    ///
    /// 上面那两张表只登记实测验证过的浏览器(理由见 `chromiumPrefsPaths` 那段),所以设置页
    /// 「添加浏览器」菜单原本只列得出四个,而 Brave / Vivaldi / Opera / Chromium / 各种 Beta
    /// 通道其实都是同一套内核、本来就驱得动。2026-08-31 用户问「这里点+号出来的是否可以加
    /// 一个选项是自己在本机的应用程序里面选」——这份字典就是那条路的落点。
    ///
    /// ⚠️ 它只影响 `family(...)`(= "这个 App 驱不驱得动"),**不影响 `chromiumPrefsPaths`**
    /// (= "那个 JS 开关存在哪")。手动加进来的 Chromium 浏览器没有登记过 Preferences 路径,
    /// 于是 `status(...)` 恒为 `.unknown`、`enable(...)` 恒为 `.unsupported` —— 这是**有意的
    /// 降级,不是漏做**:那个路径每个浏览器一个样(Arc→`Arc/`、Chrome→`Google/Chrome/`、
    /// Edge→`Microsoft Edge/`,没有公式能从 bundleID 推出来),而 `enableChromium` 是会
    /// **覆盖写**那个文件的 —— 猜错路径就是拿用户别的浏览器的配置文件去赌。宁可让 UI 告诉
    /// 用户"这个浏览器请你自己去它的菜单里开那一项"。
    ///
    /// 启动时由 `AppDelegate` 从 `AppSettings` 灌进来,跟
    /// `BrowserPositionProbe.platformBrowserPairs` 同一个"持久化在 AppSettings、运行期同步进
    /// 单例"的双写模式 —— 只写一边的话要么关了 App 就忘,要么改了要等下次启动才生效。
    public static var manuallyAddedFamilies: [String: Family] = [:]

    /// Chromium 系 `execute javascript` 与 Safari `do JavaScript` 的 AppleScript **四字码**。
    ///
    /// ⚠️ 认码不认名字:命令的显示名会随浏览器本地化/改版变,四字码是 AppleScript 的 ABI,
    /// 改了等于破坏所有既有脚本,没人会动。2026-08-31 在这台机器上逐个实测:
    /// Chrome / Edge / Arc 的 sdef 里都是 `<command name="execute" code="CrSuExJa">`,
    /// Safari 是 `<command name="do JavaScript" code="sfridojs">`;而 The Unarchiver /
    /// 音乐 / QQ音乐 这类非浏览器**一处都匹配不到** —— 正是要靠这一点把选错的 App 挡回去。
    private static let chromiumJavaScriptCode = "CrSuExJa"
    private static let safariJavaScriptCode = "sfridojs"

    /// 现场判定一个 App 能不能被这套探针驱动 —— 判据是它的**脚本定义**里有没有"执行
    /// JavaScript"这条命令,而不是"名字看起来像不像浏览器"。判不出来返回 nil,调用方应该
    /// 据此拒绝添加并说清理由,别加进来一个永远不会工作的配对。
    ///
    /// 走 bundle 内的 sdef 文件而不是 shell 调 `/usr/bin/sdef`:后者要起一个子进程,而这条
    /// 路径在用户点「选择」之后同步跑;四个浏览器实测都能从 `Info.plist` 的
    /// `OSAScriptingDefinition` 键拿到文件名、在 `Contents/Resources/` 下找到。
    public static func detectedFamily(forAppAt appURL: URL) -> Family? {
        guard let bundle = Bundle(url: appURL),
              let rawName = bundle.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String
        else { return nil }
        // 只取文件名:这个值来自**别人的** Info.plist,原样往路径上拼的话 `../..` 就能让我们
        // 去读 bundle 外的文件。
        let sdefName = (rawName as NSString).lastPathComponent
        guard !sdefName.isEmpty else { return nil }
        let sdefURL = appURL
            .appendingPathComponent("Contents/Resources")
            .appendingPathComponent(sdefName)
        guard let data = FileManager.default.contents(atPath: sdefURL.path),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        if text.contains(chromiumJavaScriptCode) { return .chromium }
        if text.contains(safariJavaScriptCode) { return .safari }
        return nil
    }

    /// **这个 bundle id 到底驱不驱得动** —— `family(...)` 的加强版:登记表里查不到时,
    /// 再去这个 App 自己的 bundle 里现场读一次脚本定义(`detectedFamily`)。
    ///
    /// ⚠️ 为什么需要它(2026-09-01,用户原话:「已经被信任了,就应该出现在这个列表里面」):
    /// 设置页「+」菜单现在也把**已信任的播放器**当候选来源,而信任列表里只有 bundle id 和
    /// 显示名 —— 那些"用户在'发现未知播放器'卡里点了信任"的浏览器从来没被登记过引擎族,
    /// `family(...)` 对它们返回 nil,不现场判一次就永远进不了候选。
    ///
    /// ⚠️ **判定结果(含 nil)进内存缓存**:这条路要读别人 bundle 的 Info.plist 和 sdef 文件,
    /// 而调用点是 SwiftUI 的 body —— 每次重绘、每次回到前台都会跑一遍。缓存活到进程结束,
    /// 用户中途换装了同 bundle id 的另一个版本要重启才认,这个代价可以接受。
    ///
    /// ⚠️ **只准主线程调**(`@MainActor`):缓存是个裸 static 字典,而 `family(...)` 会被
    /// `BrowserPositionProbe` 在后台线程读。两者不共享这份字典,加上这条隔离才说得清。
    @MainActor
    public static func resolvedFamily(forBundleID bundleID: String) -> Family? {
        if let known = family(forBundleID: bundleID) { return known }
        if let cached = detectedFamilyCache[bundleID] { return cached }
        let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .flatMap { detectedFamily(forAppAt: $0) }
        detectedFamilyCache[bundleID] = resolved
        return resolved
    }

    @MainActor
    private static var detectedFamilyCache: [String: Family?] = [:]

    /// 这个浏览器有没有真的装在这台机器上——UI 层用它决定要不要展示这一行,免得对着
    /// 一个没装的 App 空谈"检测/开启"。
    public static func isInstalled(bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    public static func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    public enum Status: Equatable {
        case enabled
        case disabled
        /// Chromium 系专属:Preferences 文件读不到/解析不出来(装了但从没启动过、格式变了)——
        /// 跟"确定关着"的 disabled 区分开,UI 上给不同的提示,别把"不确定"说成"确定没开"。
        case unknown
        case unsupported
    }

    public static func status(forBundleID bundleID: String) -> Status {
        guard let family = family(forBundleID: bundleID) else { return .unsupported }
        switch family {
        case .safari:
            guard let value = CFPreferencesCopyAppValue(safariPrefKey, safariBundleID as CFString) else {
                return .disabled // Safari 这个开关默认就是关的,读不到值等价于"从没开过"
            }
            return (value as? Bool) == true || (value as? NSNumber)?.boolValue == true ? .enabled : .disabled
        case .chromium:
            guard let dict = readChromiumPrefs(bundleID: bundleID) else { return .unknown }
            let browserDict = dict["browser"] as? [String: Any]
            return (browserDict?[chromiumPrefKey] as? Bool) == true ? .enabled : .disabled
        }
    }

    /// 读那个 Chromium 浏览器 profile 里的 `Preferences`(JSON)。
    ///
    /// ⚠️ 读不到就返回 nil,`status` 据此报 `.unknown`(不是 `.disabled`)。读不到最常见的原因
    /// 不是文件坏了,而是**别的 App 读 `~/Library/Application Support/<浏览器>/` 需要「完全
    /// 磁盘访问权限」** —— 这个 App 默认没有,所以 Chromium 系的开关状态通常就是"查不到"。
    /// 那不是故障,UI 上如实说即可(见 SettingsView.browserJSSwitchCaption)。
    private static func readChromiumPrefs(bundleID: String) -> [String: Any]? {
        guard let path = chromiumPrefsPaths[bundleID],
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }
}
