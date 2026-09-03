import AppKit
import LyrimuseCore

/// 「平台 ↔ 浏览器」配对的**逻辑本体** —— 设置页「网页播放器」卡和引导页「配对浏览器」
/// 那一步共用这一份。
///
/// 2026-09-03 从 `SettingsView.swift` 抽出来(原来是那个 View 上的一组 private 方法)。
/// 抽出来的理由不是"整理代码":`trustAndPair` 那个函数体里的**顺序**本身就是好几轮实测
/// 结论(配对先写、信任后跑、引擎族要在配对之前落盘、气泡必须让出一拍再开),引导页要
/// 是自己照抄一份,那些约束就有两份各自漂移的可能。
///
/// 存的是 `AppSettings.shared` / `FeatureSettingsStore.shared` 上的状态,不持有任何视图
/// 状态 —— 宿主各自的 UI 反应(设置页要展开那个浏览器的权限气泡、引导页只要刷新自己那
/// 一格)通过两个回调传进来。
@MainActor
enum BrowserPairing {
    /// 用户手动挑进来的浏览器,把引擎族记下来。内置那几个不记(它们的族是写死的)。
    ///
    /// 相等守卫是必要的:`manualBrowserFamilies` 是 `@Published`(willSet 语义),等值赋值
    /// 照样广播 `objectWillChange`。
    static func rememberManualBrowser(
        _ bundleID: String, family: BrowserAutomationPermission.Family
    ) {
        let settings = AppSettings.shared
        guard !BrowserAutomationPermission.knownBrowserBundleIDs.contains(bundleID) else { return }
        guard settings.manualBrowserFamilies[bundleID] != family.rawValue else { return }
        var families = settings.manualBrowserFamilies
        families[bundleID] = family.rawValue
        settings.manualBrowserFamilies = families
        BrowserAutomationPermission.manuallyAddedFamilies[bundleID] = family
    }

    /// 纯写配对关系(平台 → 一组浏览器 bundle id),顺带同步给探针。
    static func pair(_ bundleID: String, platformID: String) {
        let settings = AppSettings.shared
        var pairs = settings.browserPlatformPairs
        pairs[platformID, default: []].insert(bundleID)
        settings.browserPlatformPairs = pairs
        BrowserPositionProbe.shared.platformBrowserPairs = pairs
    }

    /// 选中一个还没信任过的浏览器时,先信任、再配对——一步到位,不逼用户先去那个浏览器
    /// 播放点什么、等 Lyrimuse 被动检测到再手动信任。`trust(bundleID:)` 本身没有"必须
    /// 观测到过播放"这类前置校验(读过 FeatureSettingsStore.trust 源码确认过),纯粹是
    /// "写进信任字典"这一步,可以在用户主动选择时直接调用。
    ///
    /// - Parameters:
    ///   - revealPairing: 配对写完、让出一拍之后调用。设置页用它展开那个浏览器的权限
    ///     气泡;引导页传空实现(那一步本身就把两道门摊在页面上,没有气泡要展开)。
    ///   - automationDidResolve: 系统自动化授权那一问有结果之后调用,宿主用它强制重算
    ///     同步现读的权限状态(设置页那个 `automationRefreshTick`)。
    ///
    /// ⚠️ **配对先写,信任后跑,两件事互不等待**(2026-09-01 修,用户报「我在加了新浏览器
    /// 之后过了很久才在这边出现图标」)。
    ///
    /// 头像那一行铺的是 `settings.browserPlatformPairs`,写它是纯本地、瞬时的。而
    /// `features.trust` 里那句 `save()` 会走一整套 **collector 重启**:
    /// `CollectorRestartCoordinator` 0.5 秒去抖 → `launchctl kickstart -k` → 轮询到一个
    /// **新 pid** 才返回,确认超时 3 秒(`CollectorControl.restartConfirmTimeout`)。也就是说
    /// 最坏情况要 3.5 秒以上,重启失败还会把这 3.5 秒整个耗满。原来的顺序把这套重启**夹在**
    /// "用户在菜单里点了那个浏览器"和"头像出现"之间,连带那个自动展开的气泡也一起被推后
    /// —— 用户看到的就是"点完什么都没发生,过一会儿才蹦出来"。
    ///
    /// 两者之间没有依赖:信任写的是 features.json(给 collector 看,决定它采不采纳这个
    /// App 上报的播放),配对写的是 AppSettings(给这张卡和探针看)。谁先谁后都不改变最终
    /// 状态;失败处理也一样 —— `trust` 的返回值本来就没人接,重启失败时配对照样成立。
    ///
    /// ⚠️ **先把引擎族落盘再配对**(2026-09-01)。候选里可能有一个"已信任、引擎族是那次
    /// 渲染现场判出来的"条目(见 `addableBrowsers` 第②路)—— 那个判定结果只活在内存缓存里,
    /// 不落盘的话配对之后 `family(...)` 仍然返回 nil,探针(`kickIfNeeded`)和自检
    /// (`runBrowserSelfTest`)都会在第一道 guard 上直接返回,表现是"配上了、头像也有了,
    /// 却永远不同步、连检测按钮都不工作"。`rememberManualBrowser` 自己跳过内置那几个。
    static func trustAndPair(
        _ bundleID: String, platformID: String,
        revealPairing: @escaping () -> Void = {},
        automationDidResolve: @escaping () -> Void = {}
    ) {
        let features = FeatureSettingsStore.shared
        if let family = BrowserAutomationPermission.resolvedFamily(forBundleID: bundleID) {
            rememberManualBrowser(bundleID, family: family)
        }
        pair(bundleID, platformID: platformID)
        Task {
            if features.trustedPlayers[bundleID] == nil {
                await features.trust(bundleID: bundleID)
            }
        }
        Task {
            // ⚠️ 配对成功后**直接把那个浏览器的权限入口摊开**(2026-09-01)。
            //
            // 在此之前,选完一个浏览器界面上只有两处变化:头像那一行多一个 22pt 的小图标、
            // 下面「已信任的其它播放器」多一行 —— 而真正要做的两件事(开浏览器自己那道 JS
            // 开关、给系统自动化授权)全藏在"点那个小图标"后面,没有任何指引。用户原话:
            // 「选完之后除了下面多一行,左边多一个图标,指引太少了,不知道要去点击图标下一步
            // 授权,帮我衔接起来」。
            //
            // 自动展开是**指引**不是**代劳**:里面的按钮仍然要用户自己点。「请求系统授权」
            // 会后台拉起那个浏览器、「打开该浏览器」会抢焦点 —— 都不该在"我只是把它加进
            // 列表"这个动作里顺带发生。
            //
            // ⚠️ **必须让出一拍再回调**,不能紧跟着 `pair` 同步调:
            //   ① 设置页承载那个 `.popover` 的头像按钮是**这次配对才出现**的(它来自
            //      `pairedBundleIDs`,而那份数据正是上一句 `pair` 刚写的)。同一次 SwiftUI
            //      更新里"视图刚被插入"+"要求它呈现 popover"是 macOS 上经典的呈现不出来。
            //   ② 那条路径的触发点是 `Menu` 里的一个 `Button` —— 此刻那个 NSMenu 正在收起,
            //      在它的关闭动画里挂一个新的 popover 同样容易被吞掉。
            // 250ms 覆盖菜单收起那一下,肉眼上仍然是"选完就弹出来"。
            try? await Task.sleep(nanoseconds: 250_000_000)
            revealPairing()
            // 2026-08-31 用户报:「并不是点击自动信任之后就弹出授权框的,是在我实际通过这个
            // 浏览器播放音乐的时候才弹出」。原因是这里一共有**三道门**,而"信任+配对"只走完
            // 前两道 —— ①Lyrimuse 自己的信任列表(features.json)、②浏览器自己那道"允许
            // Apple Events 里的 JavaScript"开关、③**系统的自动化(TCC)授权**。第③道以前
            // 完全没人主动触发,只能等 `BrowserPositionProbe` 第一次真的发 Apple Event 时由
            // 系统弹出 —— 而那要等到用户真的用这个浏览器放歌。
            //
            // ⚠️ **只在浏览器已经在跑时才问**。目标 App 没在运行时系统弹窗压根不出现
            // (2026-07-24 实测坐实,见 MusicAutomationPermission.requestWithTimeout 上那段),
            // 要弹就得先后台把它启动起来 —— 而用户点的是"把这个浏览器加进列表",不是"现在
            // 把我的浏览器打开"。没在跑的那条路交给显式的「请求系统授权」按钮。
            guard MusicAutomationPermission.isRunning(bundleID: bundleID) else { return }
            _ = await MusicAutomationPermission.requestWithTimeout(
                bundleID: bundleID, launchIfNeeded: false)
            automationDidResolve()
        }
    }

    /// 从「应用程序」里挑一个浏览器来配对 —— 内置候选名单之外那批(Brave / Vivaldi /
    /// Opera / Chromium 各分支、以及 2026-09-01 被有意从默认名单里拿掉的 Arc)唯一的入口。
    ///
    /// 2026-09-03 从 `SettingsView.chooseBrowserFromApplications` 下沉到这里:引导页
    /// 「配对浏览器」那一步也需要这条路(在此之前引导页只铺得出 `knownBrowserBundleIDs`
    /// 里装了的那几个,Brave/Vivaldi/Arc 用户在引导里完全走不通),而配对逻辑只允许有一份
    /// (selftest 有闸)。宿主差别只在**怎么把错误显示出来**,所以这里不碰任何视图状态,
    /// 把错误文案当返回值交出去。
    ///
    /// - Parameter revealPairing: 带上**刚挑中的那个 bundleID** —— 跟 `trustAndPair` 那个
    ///   无参版本不同,这条路上"配的是谁"要等文件选择器返回才知道,宿主(设置页要展开那个
    ///   浏览器的权限气泡)拿不到就只能什么都不展开。
    ///
    /// - Returns: `nil` = 配好了,或者用户自己取消了选择;非 `nil` = 要给用户看的错误文案。
    ///
    /// ⚠️ **挑中的 App 必须真的驱得动才收下**,判据是它的脚本定义里有没有"执行 JavaScript"
    /// 那条命令(`BrowserAutomationPermission.detectedFamily`,认 AppleScript 四字码不认名字)。
    /// 判不出来就**拒收并说清理由**,不能放进去一个永远不会工作的配对 —— 那比列表里没有它
    /// 更糟:用户会以为配好了,然后花时间去查"为什么歌词进度还是不同步"。
    static func chooseFromApplications(
        platformID: String,
        revealPairing: @escaping (String) -> Void = { _ in },
        automationDidResolve: @escaping () -> Void = {}
    ) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L10n.t("选择")
        panel.message = L10n.t("挑一个用来播放这个网站的浏览器")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            return L10n.t("读不出这个应用的标识，换一个试试。")
        }
        // 已经认识引擎族的(内置那几个、代码里适配着但不默认展示的 Arc、或者之前加过的)
        // 不必再判一次 —— 但**仍然要登记成"用户自己选的"**:否则像 Arc 这种"适配全在、只是
        // 不进默认名单"的浏览器,选完之后不会出现在候选里,下次想再配一个平台还得重新走一遍
        // 文件选择器。`rememberManualBrowser` 自己会跳过内置那几个。
        if let known = BrowserAutomationPermission.family(forBundleID: bundleID) {
            rememberManualBrowser(bundleID, family: known)
            trustAndPair(bundleID, platformID: platformID,
                         revealPairing: { revealPairing(bundleID) },
                         automationDidResolve: automationDidResolve)
            return nil
        }
        guard let family = BrowserAutomationPermission.detectedFamily(forAppAt: url) else {
            // 用 Finder 显示的那个名字(本地化过、跟用户在「应用程序」里看到的一致),
            // 而不是 bundle id 或者文件名。
            let name = FileManager.default.displayName(atPath: url.path)
            return String(
                format: L10n.t("「%@」不能用来同步歌词进度。这项功能要靠浏览器执行一小段 JavaScript 来读播放进度，而这个应用没有提供对应的脚本命令。Firefox 至今没有提供，非浏览器的应用也一样。"),
                name)
        }
        rememberManualBrowser(bundleID, family: family)
        trustAndPair(bundleID, platformID: platformID,
                     revealPairing: { revealPairing(bundleID) },
                     automationDidResolve: automationDidResolve)
        return nil
    }

    /// 某个平台还能新配对的浏览器:这台机器上**装了**(`BrowserAutomationPermission.
    /// isInstalled`)+ 引擎受支持 + 还没配过这个平台。
    ///
    /// ⚠️ **信任是候选的一个来源,不是候选的前提** —— 这两件事 2026-08-31 和 09-01 各定过
    /// 一半,别再把其中一半当成全部:没信任过的已安装内置浏览器**照样列出来**(选中时
    /// `trustAndPair` 一步自动信任+配对,不逼用户先去那个浏览器里放首歌被动等检测);
    /// 而**已经信任过的浏览器也一定要列出来**,哪怕它不在内置名单、也没被手动加过。按
    /// `knownBrowserBundleIDs` 的固定顺序展示,不是字典序。Firefox 这类没有提供脚本命令的
    /// 浏览器原样不出现在候选里,不是"报不支持",是这个功能对它压根不适用(见
    /// BrowserPositionProbe 头注)。
    static func addableBrowsers(platformID: String) -> [String] {
        let paired = AppSettings.shared.browserPlatformPairs[platformID] ?? []
        return candidateBrowsers(platformID: platformID).filter { !paired.contains($0) }
    }

    /// 这个平台的**全部候选**浏览器,配过的也在里面,顺序稳定(内置固定顺序在前、其余按
    /// 显示名排在后)。
    ///
    /// 2026-09-03 从 `addableBrowsers` 里下沉出来。为什么需要"含已配对"的这一份:引导页
    /// 「配对浏览器」那一步原来把候选拆成「已配对」+「可添加」两个 `ForEach` 分组渲染,
    /// 于是点一下某张卡(配对/取消配对)会让它**从一组跳到另一组、在网格里换位置** ——
    /// 用户报「这里我怎么点了没反应」,实测坐实点击一直是生效的(监视配置键抓到每点一次
    /// 就少一个配对),但"边框变化 + 卡片换位"这个反馈太弱,看起来像什么都没发生。
    /// 改成**一份稳定列表 + 每张卡自己的选中态**之后,点击的唯一视觉变化就是那张卡自己
    /// 的选中态,位置不动。
    static func candidateBrowsers(platformID: String) -> [String] {
        let settings = AppSettings.shared
        let features = FeatureSettingsStore.shared
        let known = BrowserAutomationPermission.knownBrowserBundleIDs
        // 第二段有**两个来源**,合并去重:
        //   ① 用户自己从「应用程序」里挑进来的(`manualBrowserFamilies`);
        //   ② **已经信任过的播放器里,凡是驱得动的浏览器**(2026-09-01 用户原话:「已经被
        //      信任了,就应该出现在这个列表里面,这个逻辑还是要的」)。②这一路必须有:信任
        //      本身就是一次显式的用户动作,而它可以发生在配对之外 —— 用户在「发现未知播放器」
        //      卡里点信任、或者配对过又移除了配对(那会顺手忘掉 `manualBrowserFamilies` 里
        //      的登记,见 `forgetManualBrowserIfUnpaired`),两种情况下它都还在信任列表里、
        //      却进不了候选。用户看到的就是"下面明明信任着 Doubao Browser,上面菜单里没有它"。
        //      判据用 `resolvedFamily`(会现场读 sdef)而不是 `family` —— 信任列表里只有
        //      bundle id,从没登记过引擎族。
        var extras = Set(settings.manualBrowserFamilies.keys)
        extras.formUnion(features.trustedPlayers.keys.filter {
            BrowserAutomationPermission.isInstalled(bundleID: $0)
                && BrowserAutomationPermission.resolvedFamily(forBundleID: $0) != nil
        })
        // 内置那份固定顺序在前,第二段按名字排在后面 —— 后者数量不定,混进固定顺序里会让
        // 内置那几个的位置随"加过谁"漂移。
        let rest = extras.subtracting(known)
            .sorted { (FeatureSettingsStore.appDisplayName(forBundleID: $0) ?? $0)
                        .localizedCaseInsensitiveCompare(FeatureSettingsStore.appDisplayName(forBundleID: $1) ?? $1) == .orderedAscending }
        return (known + rest)
            .filter { BrowserAutomationPermission.isInstalled(bundleID: $0) }
    }

    /// 这个浏览器此刻配没配这个平台。给"一份稳定列表 + 每张卡自己的选中态"那种渲染用
    /// (见 `candidateBrowsers`),省得调用点自己去 `pairedBrowsers(...).contains(...)`。
    static func isPaired(_ bundleID: String, platformID: String) -> Bool {
        (AppSettings.shared.browserPlatformPairs[platformID] ?? []).contains(bundleID)
    }

    /// 这个平台配过任何一个(还装着的)浏览器没有。
    ///
    /// 引导页用它给「YouTube Music」那一格的选中态播种。单独开一个而不是让调用点写
    /// `!pairedBrowsers(...).isEmpty`:selftest 有一条闸禁止引导页出现
    /// `pairedBrowsers`/`addableBrowsers`(它们是"按已配对/未配对分两组渲染"的入口,而分组
    /// 正是"点一下卡片换位置"那个 bug 的来源),播种这个用途跟分组渲染无关,值得有自己的名字。
    static func hasAnyPair(platformID: String) -> Bool {
        !pairedBrowsers(platformID: platformID).isEmpty
    }

    /// 用户手动挑进来的浏览器,**最后一个配对也被移除时一起忘掉**(2026-09-01)。
    ///
    /// ⚠️ 不忘的话它会**永远**留在候选里:`manualBrowserFamilies` 除了
    /// `chooseBrowserFromApplications` 那一处写入之外**零处删除**,用户试着加过一个浏览器
    /// 就再也拿不掉了。用户原话:「剩下的只有用户自己选了新的浏览器才会显示在这里」——
    /// 一个已经被他移除干净的浏览器,不该继续占着那份"用户自己选的"名额。
    static func forgetManualBrowserIfUnpaired(_ bundleID: String) {
        let settings = AppSettings.shared
        guard settings.manualBrowserFamilies[bundleID] != nil else { return }
        guard !settings.browserPlatformPairs.values.contains(where: { $0.contains(bundleID) }) else { return }
        var families = settings.manualBrowserFamilies
        families.removeValue(forKey: bundleID)
        settings.manualBrowserFamilies = families
        BrowserAutomationPermission.manuallyAddedFamilies.removeValue(forKey: bundleID)
    }

    /// 取消这个浏览器在**某一个平台**上的配对。
    ///
    /// ⚠️ 只动配对关系,**不动信任列表** —— 信任是一次独立的显式动作(设置页「已信任的
    /// 其它播放器」那一段管它),在这里顺手撤掉会把用户在别处配好的东西替他删了。
    static func unpair(_ bundleID: String, platformID: String) {
        let settings = AppSettings.shared
        var pairs = settings.browserPlatformPairs
        pairs[platformID]?.remove(bundleID)
        if pairs[platformID]?.isEmpty == true { pairs.removeValue(forKey: platformID) }
        settings.browserPlatformPairs = pairs
        BrowserPositionProbe.shared.platformBrowserPairs = pairs
        forgetManualBrowserIfUnpaired(bundleID)
    }

    /// 这个平台此刻已经配好的浏览器(装了的才算)。
    ///
    /// ⚠️ 已配对的也要过 `isInstalled` 这道门(2026-08-31 用户拍板):"配对过、后来把那个
    /// 浏览器卸载了"不该一直留一个取不到图标的虚线方框。**只是不显示,配对记录原样留着**
    /// —— 装回来自动恢复,不要顺手 `unpair` 去"清理",那会把用户的配置替他删掉(同「指定的
    /// 屏幕拔掉后自动回落、偏好保留」那个口径)。
    static func pairedBrowsers(platformID: String) -> [String] {
        (AppSettings.shared.browserPlatformPairs[platformID] ?? [])
            .filter { BrowserAutomationPermission.isInstalled(bundleID: $0) }
            .sorted()
    }
}
