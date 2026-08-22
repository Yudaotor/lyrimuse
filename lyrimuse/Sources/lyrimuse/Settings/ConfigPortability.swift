import Foundation
import AppKit
import LyrimuseCore
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

    /// 给"在访达中显示配置文件夹"用。这个 App 的配置本来就住在 `~/.config/lyrimuse`
    /// (对一个 SwiftUI 菜单栏 App 来说不常见),对拿 dotfiles / chezmoi 管机器的人来说
    /// 正是他们要找的东西 —— 同类里 Karabiner-Elements 的官方"导出导入配置"整页文档
    /// 就是"打开配置文件夹、把 karabiner.json 拷过去"。
    static var configFolderURL: URL { configDir }
    private static let configURL = configDir.appendingPathComponent("config.json")
    private static let featuresURL = configDir.appendingPathComponent("lyrimuse-features.json")

    /// np: 前缀里**不**带走的键。
    ///
    /// 判据是"这一项描述的是这台机器的状态,还是这个人的偏好"。偏好该跟着人走,机器状态
    /// 搬过去只会让新机器显示一件不成立的事。导出和导入两侧用的是同一个集合(见
    /// `importData`),所以往这里加一个键,连**旧版本导出的文件**里那一项也会在导入时被
    /// 挡掉,不用另做兼容。
    ///
    /// ### 引导/一次性提示:讲的是这台机器走到哪一步了
    ///
    /// - `hasCompletedOnboarding` / `hasShownAutomationOnboarding`:引导流程是不是走完了。
    ///   新机器本来就该自己走一遍——自动化权限、常驻服务都是每台机器各自要重新授权/
    ///   重新装的;带着旧机器"已完成"的标记过去,新机器反而不弹引导,用户找不到入口去
    ///   处理这两件事。
    /// - `hasOfferedICloudImport`:"这台机器已经问过要不要从 iCloud 导入"。带过去会让新
    ///   机器不再弹那一问(见 AppSettings 里同名属性的注释)。
    /// - `hasShownOverlayDragHint`:"长按才能拖动"这条手势提示放没放过。
    ///   LyricsOverlayWindowController 里的原话就是"且**这台机器**从没显示过一次时"——
    ///   它按机器计数是设计如此。
    ///
    /// 注意 `hasSeenChineseLyrics` 不在此列:它记的是"这个人听到过中文歌"(决定简繁那项
    /// 设置露不露出来),讲的是这个人的曲库,不是这台机器,该跟着走。
    ///
    /// ### 屏幕坐标/屏幕身份:换台机器就不成立了
    ///
    /// - `overlayPositionTop`:存的是 `"x,顶边y"` 绝对屏幕坐标。新机器显示器尺寸/排布
    ///   不同,原样还原可能把悬浮窗放到屏幕外——用户会以为"悬浮歌词开了但不显示"。
    /// - `overlayPositionOrigin`:上面那个键的旧版本,现在只读不写、供一次性迁移用,
    ///   同样是绝对坐标。
    /// - `notchScreenID`:灵动岛显示在哪块屏幕上,存的是屏幕身份串。这个 ID 在新机器上
    ///   一定解析不出对应屏幕(设置页为此专门有一档"已断开的屏幕"占位)。
    ///
    /// ### 装没装 LaunchAgent:是机器状态,不是开关状态
    ///
    /// - `launchAtLoginEnabled`:它的 didSet 会去调 `LoginItemManager.setEnabled`,也就是
    ///   在**这台**机器上装/卸一个 LaunchAgent。而导入是直接写 UserDefaults、不走 didSet
    ///   (导入完就重启,而 Swift 的属性观察器在 init 里赋值时也不触发),所以带过去的结果
    ///   是:新机器上开关显示"已开启",实际上没有任何 LaunchAgent —— 界面在说谎。宁可让
    ///   用户在新机器上自己开一次。
    private static let machineLocalDefaultsKeys: Set<String> = [
        "np:hasCompletedOnboarding",
        "np:hasShownAutomationOnboarding",
        "np:hasOfferedICloudImport",
        "np:hasShownOverlayDragHint",
        // 「这台机器上哪些 App 已经提示过新播放器」—— 跟上面几条是同一类机器状态。
        // 跟着备份搬去新机器的后果是:新机器上装了同一个播放器却永不提示,而新机器
        // 恰恰最需要提示(浏览器的 bundle id 还可能不一样)。
        "np:unknownPlayerNotices",
        "np:overlayStyle",
        "np:overlayPositionTop",
        "np:overlayPositionOrigin",
        "np:notchScreenID",
        // 歌词窗口的位置/尺寸与它所在的那块屏幕(2026-08-22 加)。判据跟上面
        // np:overlayPosition* 一字不差:存的是绝对屏幕坐标 + 一块具体显示器的 UUID,
        // 新机器的显示器尺寸/排布/UUID 全不一样,搬过去只会把窗口摆到看不见的地方。
        "np:lyricsWindowFrame",
        "np:lyricsWindowScreenID",
        "np:launchAtLoginEnabled",
        // launchAtLoginEnabled 的同类,2026-08-13 补上 —— 判据(见本组注释末尾"装没装
        // LaunchAgent 是机器状态")对它一字不差地成立:它记的是"这台机器上装没装 collector
        // 的 LaunchAgent",而不是用户的偏好。带过去的话,新机器上服务其实还没装,界面却
        // 显示"已启用",用户找不到那个能把它真正装上的开关。
        "np:collectorServiceEnabled",
        // 「这台机器上现在装进 launchd 的是哪个 collector 二进制」(路径+大小+mtime,见
        // CollectorServiceManager.installedFingerprintKey)。跟上面那条同类,而且带过去更糟:
        // 新机器上的二进制必然是另一个文件,却因为指纹"对得上"而跳过启动时那次本该做的重装,
        // 正好把这条兜底关掉。
        CollectorServiceManager.installedFingerprintKey,
        // 备份文件夹的路径(见 ICloudConfigStore.customFolderKey)。同样是"这台机器上的一个
        // 路径"——新机器上那个目录多半不存在,带过去只会让备份这一块指向一个不存在的地方。
        ICloudConfigStore.customFolderKey,
    ]

    /// 已经没有任何代码在读的旧键 —— 功能改名或删掉之后,值还留在 UserDefaults 里。
    ///
    /// 2026-08-10 对本机全部 44 个 `np:` 键做了一次全仓扫描(源码里既搜 `"np:xxx"` 字面量、
    /// 又搜短名标识符),这五个在 **lyrimuse / LyrimuseCore / collector / desktop-lyrics /
    /// web 全部代码里零命中**,并逐个确认过去向:
    ///
    /// - `useSystemTranslationFallback`:"系统兜底翻译"这个开关还在,但早就改绑到
    ///   `features.lyricsMachineTranslation`(features.json)了,不再走 UserDefaults。
    /// - `textShadowEnabled` / `textShadowColorHex`:文字阴影这个功能整个已经不存在。
    /// - `relayBaseURL`:中继地址现在由 collector 的 config.json (`state_relay_url`) 管。
    /// - `dataSourceMode`:旧版本的数据源开关,早已没有对应 UI 和读取方。
    ///
    /// **跟上面那份机器专属名单不是一回事**:那些键是活的、只是不该跨机器带;这些是死的,
    /// 留着就是垃圾 —— 会被导出进配置文件、在新机器上再被导入回去,一路传下去。
    ///
    /// 刻意**不**包含 `overlayStyle` / `hasShownAutomationOnboarding`:它们看着也像废弃字段,
    /// 但 AppSettings.init() 每次启动都还在读它们做一次性迁移,删了会让从老版本升上来的
    /// 用户丢掉迁移结果。
    static let obsoleteDefaultsKeys: Set<String> = [
        // 2026-08-17 这两个开关整个撤掉了(用户要求),两项功能改成固定开启:音量提示
        // 跟着灵动岛开关走,播放指示条常驻。留着这两个键只会被导出到新机器再导回来。
        "np:notchVolumeBanner",
        "np:notchShowEqualizer",
        "np:dataSourceMode",
        "np:relayBaseURL",
        "np:textShadowColorHex",
        "np:textShadowEnabled",
        "np:useSystemTranslationFallback",
    ]

    /// 导出/导入都要跳过的键 = 机器专属的 + 已经死掉的。
    private static let excludedDefaultsKeys: Set<String> =
        machineLocalDefaultsKeys.union(obsoleteDefaultsKeys)

    /// 把死键从本机 UserDefaults 里删掉。启动时调一次,幂等。
    ///
    /// 光在导出时跳过它们还不够 —— 那只是不再往外传,本机这份仍然留着,`defaults read`
    /// 里也一直看得见。既然确认没有任何读取方,就地删干净。
    static func pruneObsoleteDefaults() {
        let defaults = UserDefaults.standard
        for key in obsoleteDefaultsKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
            logger.notice("pruned obsolete default key \(key, privacy: .public)")
        }
    }

    static func suggestedFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Lyrimuse-Config-\(formatter.string(from: Date())).json"
    }

    /// 导出包的格式版本。
    ///
    /// 2026-08-13 之前这个数字是个**死字段**:只在 buildExportData 里写出去,importData
    /// 从头到尾没读过(全仓 grep 只有一处命中)。现在导入时至少会看它一眼 —— 不是为了做
    /// 版本迁移(格式一直是向后兼容的:未知字段本来就会被忽略,缺失字段各有默认值),而是
    /// 为了让"从新版本的机器导过来、有些设置没跟过来"这类问题在日志里留下痕迹,而不是
    /// 让人对着一份看不出差别的 JSON 猜。真要 break 格式那天,钩子在这儿。
    static let exportFormatVersion = 1

    /// 该跟着这个人走的那批 App 偏好 —— 也就是"全部 np:/KeyboardShortcuts_ 键,减去机器
    /// 专属的和已经死掉的"。
    ///
    /// 抽成一处是因为它现在有三个消费者:导出包的 appSettings 段、`AppSettingsMirror`
    /// 写进配置文件夹的那份镜像、以及导入时用同一份排除表做过滤。三处各写一遍循环,迟早
    /// 会有一处漏掉排除表 —— 而漏掉的后果是把屏幕坐标之类的机器状态搬到别的机器上。
    static func exportableAppSettings() -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() {
            guard key.hasPrefix("np:") || key.hasPrefix("KeyboardShortcuts_") else { continue }
            guard !excludedDefaultsKeys.contains(key) else { continue }
            out[key] = value
        }
        return out
    }

    /// 把一份 appSettings 落进 UserDefaults,同样过一遍排除表。
    ///
    /// 排除表在**写入侧也要过**,不能只在导出时过:一份旧版本导出的包(那时排除表还没这一
    /// 项)里可能带着现在不该导入的键,这里挡住,不用为每次扩表另做一套兼容。
    static func applyAppSettings(_ appSettings: [String: Any]) -> Int {
        var applied = 0
        for (key, value) in appSettings {
            guard !excludedDefaultsKeys.contains(key) else { continue }
            UserDefaults.standard.set(value, forKey: key)
            applied += 1
        }
        return applied
    }

    static func buildExportData() -> Data? {
        var bundle: [String: Any] = [
            "version": exportFormatVersion,
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

        bundle["appSettings"] = exportableAppSettings()

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
    //
    // ⚠️ 2026-08-13 补:上面那句"统一提示重启整个 App"只对 **App 自己**成立,漏了
    // collector —— 它是独立的 launchd 进程,重启 App 完全不碰它,而它的配置是**启动时读
    // 进内存的那一份**(main.go 里没有任何文件监听)。所以在一台已经装过 collector 的
    // Mac 上导入(= 第二台机器保持同步、或本机从 iCloud 恢复),盘上和界面都换成新配置了,
    // 后台却还在拿旧凭据 scrobble、往旧地址推状态,直到用户碰巧改了别的设置、或者重启机器。
    //
    // 为什么一直没被发现:全新 Mac 上 collector 还没装,而 hasCompletedOnboarding 又被
    // 刻意排除在导入之外(见 excludedDefaultsKeys),引导会在导入之后把服务装上 —— 主路径
    // 恰好绕开了这个洞。
    //
    // 修在这里而不是三个调用点各加一句:调用点有三个(设置页导入、iCloud 启动询问、以后
    // 可能的第四个),忘一个就是同一个 bug 再来一次。
    @discardableResult
    static func importData(_ data: Data) async -> Bool {
        guard let bundle = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("importData: top-level JSON parse failed — not a valid export file")
            return false
        }

        // 见 exportFormatVersion 的注释:只记录、不拒绝。格式向后兼容,更高版本的包里多出来
        // 的字段这一版认不出、会被忽略,但已知字段照样能用 —— 直接拒掉反而让"新机器导给
        // 旧机器"这条真实路径彻底走不通。
        let bundleVersion = bundle["version"] as? Int ?? 0
        if bundleVersion > exportFormatVersion {
            logger.warning("importData: bundle format v\(bundleVersion) is newer than this build's v\(exportFormatVersion) — fields this version doesn't know will be ignored")
        } else if bundleVersion == 0 {
            logger.notice("importData: bundle has no usable 'version' field")
        }

        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        } catch {
            logger.error("importData: createDirectory(\(configDir.path, privacy: .public)) failed — \(String(describing: error), privacy: .public)")
        }

        if let configObj = bundle["config"] {
            let sanitized = sanitizeImportedConfig(configObj)
            if let configData = try? JSONSerialization.data(withJSONObject: sanitized, options: [.prettyPrinted]) {
                do {
                    // 含全部账号凭据 —— 走 writeSecurely 收紧到 0600,见那边的注释。
                    try configData.writeSecurely(to: configURL)
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
            let applied = applyAppSettings(appSettings)
            logger.info("importData: applied \(applied) of \(appSettings.count) appSettings keys")
            // 顺手把配置文件夹里那份镜像也刷成刚导入的内容。不刷的话它会一直是覆盖前的
            // 旧值,直到用户下次改动某个设置 —— 中间这段时间里"把配置文件夹拷去别的机器"
            // 带走的是旧偏好,而用户以为自己刚导入的就是全部。
            AppSettingsMirror.write()
        } else {
            logger.notice("importData: import bundle has no 'appSettings' section")
        }

        // 让 collector 读到刚写下去的 config.json/features.json。必须**在这里等它跑完**:
        // 调用方紧接着就 restartApp() → NSApp.terminate,进程说没就没,fire-and-forget
        // 的重启很可能根本来不及发出去。
        //
        // 失败不算导入失败:全新机器上 collector 还没装,kickstart 必然失败,而那条路径
        // 随后的引导流程本来就会把服务装上、届时自然读的是新配置。
        let reloaded = await CollectorControl.restartAndWaitAsync()
        logger.info("importData: collector reload after import — ok=\(reloaded)")
        return true
    }

    // "清除所有配置"——回到刚装完时的样子。跟上面 import/export 用同一套
    // 文件+UserDefaults 盘点逻辑,但故意不复用 excludedDefaultsKeys:那个集合是"换机器
    // 场景下不该带走"的字段(引导状态/废弃字段),这里恰恰要连这几个也一起清掉——
    // hasCompletedOnboarding 被清空后,下次启动会重新走一遍引导向导,这正是"最原始配置"
    // 应有的样子,不是遗漏。
    //
    // App 自己的状态清完交给调用方紧接着的 restartApp() 复位,原因跟 importData 那条
    // 注释一样。但**常驻服务必须在这里显式停掉**。
    //
    // ⚠️ 这里原本写着一段推理:"collectorServiceEnabled 清空后读回来是 false,它的 didSet
    // 会调 setEnabled(false)→uninstall(),而 Swift 对 init() 内部显式赋值一样会触发
    // didSet,于是清除配置+重启 App 顺带就把 LaunchAgent 卸载了"。2026-08-13 用 swiftc
    // 实测,这段推理的前提是**错的**:
    //
    //     声明时无默认值 + init 里首次赋值 → didSet 不触发
    //     声明时有默认值 + init 里重新赋值 → didSet 触发
    //
    // 而 AppSettings.collectorServiceEnabled / launchAtLoginEnabled 都是**无默认值**声明
    // (`@Published var x: Bool {` 直接跟 didSet),走的是不触发那一档。本文件 :60-64 解释
    // 排除 launchAtLoginEnabled 时给出的正是正确结论 —— 同一个文件里两条注释互相矛盾,
    // 而这一条是错的那条。
    //
    // 后果不是"少卸了个 LaunchAgent"这么轻:collector 是 KeepAlive=true 的 launchd 进程,
    // 配置在启动时读进内存(无文件监听)。删掉 config.json 并不会让它闭嘴 —— 用户点了
    // "清除所有设置"、界面告诉他"恢复到刚装完时的样子",后台却**继续拿着刚被清除的
    // Last.fm session key 往那个账号 scrobble**,直到机器重启。承诺没兑现,而且是隐私性质的。
    //
    // 用 setEnabledAndWait 而不是 setEnabled:后者是 operationQueue.async 的
    // fire-and-forget,而调用方下一句就是 restartApp() → NSApp.terminate,卸载多半来不及跑完。
    /// 导入前对 `config` 段做的最小净化,规则和理由见 `ImportPolicy`。
    ///
    /// 只在这一处做,不在 ConfigStore 里做:那边处理的是**用户自己在界面上敲进去的值**,
    /// 拦下来只会让人莫名其妙"我填的地址怎么没保存上";这里处理的是**外来文件**,
    /// 尤其在备份文件夹可以指向共享目录之后。两者信任级别不同。
    private static func sanitizeImportedConfig(_ configObj: Any) -> Any {
        guard var config = configObj as? [String: Any] else { return configObj }
        if let raw = config["state_relay_url"] as? String,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !ImportPolicy.isAcceptableRelayURL(raw) {
            // 连同 token 一起清掉:留着一把配不上地址的 token 没有意义,而万一以后哪里
            // 补了个默认地址,它会跟着被发出去。
            config["state_relay_url"] = ""
            config["state_relay_token"] = ""
            logger.warning("importData: dropped state_relay_url with an unacceptable scheme (and its token)")
        }
        return config
    }

    @discardableResult
    static func clearAllConfig() async -> Bool {
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
        // 镜像也要删。留着它下次启动就会被 restoreIfPristine 原样恢复回来 —— 用户点的
        // 那个"恢复到刚装完时的样子"等于白点。
        AppSettingsMirror.remove()
        // 「已校准」名单跟着一起清(2026-08-21 补)。上面那轮把三个偏移键(全局/按播放器/
        // 单曲)都清了,而这份名单是**独立文件**、不在 np: 前缀里 —— 不一起清就会留下一份
        // 孤儿名单:collector 继续拒绝给这些歌自动升级歌词,而它保护的校正值早已不存在,
        // 用户在界面上完全看不到原因。它跟校正值是成对的东西(LyricsOffsetStore
        // .clearAllTrackOffsets 也是这么配对的)。
        await LyricsPinStore.shared.removeAll()
        logger.info("clearAllConfig: cleared \(clearedCount) UserDefaults keys, filesRemovedOK=\(ok)")

        // 卸 LaunchAgent 并停掉进程。放在清 UserDefaults **之后**:uninstall 只做 launchctl
        // 操作,不回写偏好,顺序上不会把刚清掉的键又写回来。
        let state = await CollectorServiceManager.setEnabledAndWait(false)
        logger.info("clearAllConfig: collector service stopped — stillRunning=\(state.isRunning)")
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
