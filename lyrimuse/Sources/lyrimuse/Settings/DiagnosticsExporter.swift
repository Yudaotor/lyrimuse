import Foundation
import LyrimuseCore
import OSLog
import AppKit
import Darwin
import SwiftUI

// 诊断导出:引擎日志(~/Library/Logs/lyrimuse.log)+ App 侧 os.Logger 日志 + 关键状态(权限 / 常驻服务 /
// 各功能是否已配置)打成一个 zip,给用户附到 issue 里。它是用户遇到问题时唯一会发过来的东西,要覆盖网络 / 逻辑 /
// UI / 交互 / 系统兼容几个层面。
//
// 硬约束:绝不能把 ConfigStore 里任何 token / secret 的原始值写进导出 —— 它设计给贴进公开的 GitHub issue。
// 由两道独立的机制守着,缺一不可:
//
//  1. 结构化那一段(== State ==)只复用 ConfigStore 已有的 isXConfigured / xMissingHint() 这批只读布尔判断,
//     不直接触碰 savedSnapshot 里的字段本身。
//  2. 所有日志正文统一过 redacted() → LogRedactor。往导出里加任何新的日志段落,都必须一并套上 redacted();
//     日志正文里可能带完整 URL(引擎打印 Go *url.Error 时 api_key 就在 query string 里),见 LogRedactor。
enum DiagnosticsExporter {
    static func suggestedFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Lyrimuse-Diagnostics-\(formatter.string(from: Date())).zip"
    }

    // 只生成内容,不碰任何文件系统写入——存哪、怎么存交给调用方(SettingsView 用
    // NSSavePanel)。写入路径由用户自己在系统存储面板里确认,天然不会撞上桌面/文稿/
    // 下载三个目录可能存在的 TCC 保护,也跟这个项目里选歌词文件夹用 NSOpenPanel 是
    // 同一个思路。
    /// 弹保存面板 → 后台生成内容 → 写盘 → 在访达里选中它。
    ///
    /// **顺序是刻意的**:面板先弹,内容后生成。buildReport 里的 OSLogStore 查询要
    /// **4.4 秒**(扫 24 小时、拉回一万多行),又整个跑在主线程上 —— 面板先弹能让界面立刻
    /// 有反应,重活挪到用户挑完位置之后于后台线程跑,不会看起来像卡死。新加的引擎
    /// healthcheck 子进程(带真实网络探测)和收听记录解析也都挂在这同一段后台任务里——
    /// 导出整体可能因此再多等几秒,但用户此时已经看不到主界面被卡住,跟原有取舍一致。
    ///
    /// 收进这里而不是留在 SettingsView:这个按钮有两个调用点("关于"页和常驻服务启用
    /// 失败时的补救入口),顺序一旦写反就又变回卡四秒,不该让两处各自维护一遍。
    @MainActor
    static func exportInteractively() {
        // 一次导出要跑近 20 秒(OSLog 查询 + 歌词引擎自检):这期间再点就忽略,不并发写出好几份。
        let status = DiagnosticsExportStatus.shared
        guard !status.isExporting else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let secrets = ConfigStore.shared.secretsForRedaction
        // 当前曲目的歌词解析状态也要在这里先算好——EnrichCacheReader 整个类型是
        // @MainActor(只有少数纯换算函数显式 nonisolated),`sourceInfo`/`lookup`/
        // `resolvedKey` 都不在那份白名单里,不能挪到下面的 Task.detached 里调。
        let currentTrackLines = currentTrackLyricsLines()
        // zip 里的顶层目录跟着用户在保存面板里敲的名字走,解压出来是一个文件夹,
        // 不是三个散文件落进下载目录。
        let bundleName = url.deletingPathExtension().lastPathComponent
        let startedAt = Date()
        status.isExporting = true
        Task { @MainActor in
            defer { status.isExporting = false }
            // 状态段要读 @MainActor 的单例,在主线程取;自动化权限先 await 出来传进去,
            // 不能在主线程上同步查(见 `automationLine`)。日志段(慢的那部分)扔后台。
            let head = stateLines(automation: await automationLine(), engineState: await engineStateOffMain())
            await Task.detached(priority: .userInitiated) {
                writeDiagnosticsBundle(to: url, bundleName: bundleName, head: head,
                                       secrets: secrets, currentTrackLines: currentTrackLines)
            }.value
            // 写包的每一步都是 try?:按结果判断有没有写成(文件在、而且是这次写的),没写成就明说,
            // 不要照样打开访达、让人对着一个空文件夹或上一次的旧文件。
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            guard let modified, modified >= startedAt.addingTimeInterval(-1) else {
                let alert = NSAlert()
                alert.messageText = L10n.t("诊断没能导出，请换个位置再试")
                alert.runModal()
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// 一次拿到整份文本(日志段在主 actor 上读)。留着给"就是要一次拿到整份文本"的场景;
    /// 交互式导出请用 `exportInteractively()`,别在主线程上等这个。
    @MainActor
    static func buildReport() async -> String {
        return (stateLines(automation: await automationLine(), engineState: await engineStateOffMain()) + logLines(secrets: ConfigStore.shared.secretsForRedaction,
                                        currentTrackLines: currentTrackLyricsLines()))
            .joined(separator: "\n")
    }

    /// 配置文件三态 → 报告里的一个词。纯函数,不需要 actor。
    private static func describe(_ state: JSONConfigDocument.LoadState) -> String {
        switch state {
        case .missing: return "missing"
        case .loaded: return "ok"
        case .corrupt(let reason): return "CORRUPT — \(reason)"
        }
    }

    /// 报告里自动化权限那一行。查询走 `MusicAutomationPermission.status`(专用线程 + 超时):
    /// 那次系统调用可能永远不返回,在主线程同步等会把整个 App 冻住(02 章决策 8)。
    private static func automationLine() async -> String {
        let status = await MusicAutomationPermission.status(
            bundleID: PlaybackPlayer.appleMusic.bundleIdentifier, askIfNeeded: false)
        return "Automation permission: " + (status.map { "\($0)" } ?? "timed out")
    }

    /// launchd 里那条服务的状态。`EngineServiceManager.state` 会起 `launchctl print` 子进程并同步等它退出,
    /// 而 stateLines 在主线程上跑 —— 在后台取好再传进去。
    private static func engineStateOffMain() async -> LaunchdJobState {
        await Task.detached(priority: .userInitiated) { EngineServiceManager.state }.value
    }

    /// 报告的状态段 —— 全部来自 @MainActor 隔离的单例,但都是内存读,很便宜(launchd 状态由调用方在后台取好传进来)。
    @MainActor
    private static func stateLines(automation: String, engineState: LaunchdJobState) -> [String] {
        var lines: [String] = []

        lines.append("Lyrimuse Diagnostics")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        lines.append("== System ==")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("App version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")
        // 架构 + 是否在 Rosetta 下跑。这个项目发布流程真的出过事故——
        // build.sh 头部注释记着 v1.0.0~v1.2.0 三个版本都在没人察觉的情况下发成了
        // arm64-only,一台 Intel Mac 或者装了 Rosetta 的 Apple Silicon Mac 上排查
        // "打不开/崩溃"级别的问题,这一行往往是第一个该确认的东西。
        // sysctl.proc_translated:进程本身是 x86_64、正靠 Rosetta 跑在 Apple Silicon 上
        // 才会是 1——arm64 原生二进制不存在"被 Rosetta 翻译"这回事,恒为 0,不需要
        // 额外判断分支。
        var isTranslated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let translated = sysctlbyname("sysctl.proc_translated", &isTranslated, &size, nil, 0) == 0
            && isTranslated == 1
        #if arch(arm64)
        let binaryArch = "arm64"
        #else
        let binaryArch = "x86_64"
        #endif
        lines.append("Architecture: \(binaryArch)" + (translated ? " (running under Rosetta)" : ""))
        lines.append("")

        lines.append("== State ==")
        let settings = AppSettings.shared
        let config = ConfigStore.shared
        lines.append(automation)
        // media-control 私有通道的自检结果。QQ 音乐/网易云的一切都经它读,一旦系统更新
        // 把那套私有 API 改坏,现象是"歌词不动",而这跟"没在放歌"从表象上分不开 ——
        // 报告里必须有这一行,否则排查会从歌词源一路白查到网络。见 MediaControlHealth。
        switch MediaControlHealth.shared.state {
        case .unknown: lines.append("media-control channel: not checked yet")
        case .healthy: lines.append("media-control channel: healthy")
        case .unavailable(let message): lines.append("media-control channel: UNAVAILABLE — \(message)")
        }
        // 「当前认哪个播放器」是排查"检测不到播放/歌词出不来"时第一个要问的问题,而它有两层:
        // 用户在设置里选的(可能是"自动识别"),和这一刻实际被认下来的那个 bundle id。两层
        // 都要报——只报设置值的话,"自动识别"这一档等于什么都没说。
        // 多选后:可能不止一个,按 rawValue 逗号拼接全部报出来。
        lines.append("Player (setting): \(PlaybackPlayerPreference.selected.map(\.rawValue).sorted().joined(separator: ", "))")
        // 标签写 "last detected" 而不是 "now":这个值来自最近一次成功的快照,而快照在停播/
        // 检测失效时不会被清掉,所以停播之后它仍然报最后一次识别到的播放器。读报告的人得
        // 知道这一点,否则会把陈旧值当成当下状态。
        lines.append("Player (last detected): \(PlaybackCoordinator.shared.resolvedPlayerDescription)")
        lines.append("Engine service enabled (setting): \(settings.engineServiceEnabled)")
        // 报完整三态而不是 true/false —— "注册了但起不来"正是最需要出现在诊断报告里的那
        // 一档(带上次退出码),以前它跟"在跑"一样报 true,报告等于把最关键的线索抹掉了。
        lines.append("Engine service state: \(engineState)")
        // 两份共享配置文件的三态:损坏时所有保存被拒,「设置保存不上 / 账号全空」第一个该看的原因。
        // reason 只含解析位置、键名与期望类型,不含文件内容(config.json 是凭据)。
        lines.append("config.json: \(describe(config.fileState))")
        lines.append("lyrimuse-features.json: \(describe(FeatureSettingsStore.shared.fileState))")
        lines.append("App language: \(settings.appLanguage)")
        lines.append("Classic overlay enabled: \(settings.classicOverlayEnabled)")
        lines.append("Notch overlay enabled: \(settings.notchOverlayEnabled)")
        lines.append("ListenBrainz configured (submit): \(config.isListenBrainzConfigured)")
        // 分开报:只有 token 时"能提交"为真而"能读统计"为假,周报/日报/桥接会静默不跑,
        // 而这正是最难自己看出来的一种配置状态。
        lines.append("ListenBrainz readable (digests/bridge): \(config.isListenBrainzReadable)")
        // 没有独立开关了,两边凭据都配好就自动生效,这里直接报告"是否真的
        // 在跑"而不是"Last.fm 侧凭据填了没"(后者单独看意义不大,还得对照上一行才知道
        // 有没有真的启用)。
        lines.append("Last.fm bridge active: \(config.lastfmBridgeMissingHint() == nil && config.isListenBrainzReadable)")
        // lastfmMirrorMissingHint 已删(开关自己就是配置入口,不再需要前置
        // 校验函数),它检查的三个字段里 sessionKey 是最后一步产物,单看它就等价。
        lines.append("Last.fm mirror configured: \(!config.lastfmScrobbleSessionKey.isEmpty)")
        lines.append("State relay configured: \(config.stateRelayMissingHint() == nil)")
        lines.append("Push notification configured: \(config.pushMissingHint() == nil)")
        // 自动更新状态。「为什么没提示我更新」是另一类常见反馈,而
        // Sparkle 自己的这两个字段(是否开着周期检查、上一次真的检查是什么时候)足够
        // 回答大半——不用再让用户去猜"是不是它压根没在检查"。lastUpdateCheckDate 是
        // Sparkle 自己维护的只读字段,读取本身零成本,不涉及联网。
        // 读管理器自己的转发属性,不要够到 `SparkleUpdaterManager.shared.updater` ——
        // 那是 Sparkle 的类型,无 Sparkle 构建(LYRIMUSE_NO_SPARKLE)下它根本不存在。
        let updates = SparkleUpdaterManager.shared
        if SparkleUpdaterManager.isSupported {
            lines.append("Auto-update checks: \(updates.automaticallyChecksForUpdates)"
                         + (updates.lastUpdateCheckDate.map { " (last checked: \(ISO8601DateFormatter().string(from: $0)))" }
                            ?? " (never checked this run)"))
        } else {
            // 包管理器构建:自更新整个不在。如实说出来,否则「为什么没提示我更新」会查到一个
            // 永远 false 的开关上,看不出是"关着"还是"压根没这功能"。
            lines.append("Auto-update checks: unavailable (built without Sparkle; update via your package manager)")
        }
        lines.append("")

        // ---- 窗口----
        //
        // 「悬浮窗不见了/跑到看不见的地方」「设置窗打不开」这类 UI 层面的反馈,光靠上面
        // 那些布尔开关看不出实际现状——「灵动岛 enabled: true」不代表它这一刻真的可见
        // (可能因为暂停/截屏/被 hideWhenNotPlaying 收起了)。这里如实报每一扇当前存在的
        // 窗口:标题、可见性、是否最小化、frame、落在第几块屏——只报有标题或者可见的,
        // 过滤掉纯内部用的无标题辅助窗口(菜单栏承载窗之类),否则会混进一堆无意义的行。
        lines.append("== Windows ==")
        let interestingWindows = NSApp.windows.filter { !$0.title.isEmpty || $0.isVisible }
        if interestingWindows.isEmpty {
            lines.append("(no windows)")
        } else {
            for win in interestingWindows {
                let screenIndex = win.screen.flatMap { s in NSScreen.screens.firstIndex(where: { $0 === s }) }
                let f = win.frame
                lines.append("- \"\(win.title.isEmpty ? "(untitled)" : win.title)\":"
                             + " visible=\(win.isVisible) miniaturized=\(win.isMiniaturized)"
                             + " frame=(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)))"
                             + " screen=\(screenIndex.map(String.init) ?? "none")")
            }
        }
        // 屏幕列表单独报一遍(不挂在某扇窗底下)——多屏/缩放相关的坑(见第 04 章「窗口
        // 几何与位置记忆」)排查时第一件事就是确认屏幕数量和各自分辨率/缩放,不用再让
        // 用户口头描述"我接了几个显示器"。
        let screenSummaries = NSScreen.screens.enumerated().map { i, s in
            "#\(i) \(Int(s.frame.width))x\(Int(s.frame.height))@\(String(format: "%.1f", s.backingScaleFactor))x"
        }
        lines.append("Screens: \(NSScreen.screens.count) — \(screenSummaries.joined(separator: ", "))")
        lines.append("")

        // ---- 播放时钟----
        //
        // 「歌词慢半拍」这类问题至少有四种成因、修法完全不同:帧率掉了 / positionSourceTier
        // 判错 / 伺服在反复 snap / 自然切歌偏置估歪。这里把四种从数据上区分开,不用靠猜或
        // 翻引擎日志。
        //
        // 全是内存里已有的字段(LocalPlaybackSource.clockSnapshot),读一次的成本可以忽略;
        // 不含任何用户内容(没有曲名/歌手/歌词),天然不需要过 LogRedactor。
        let clock = LocalPlaybackSource.shared.clockSnapshot
        lines.append("== Playback clock ==")
        lines.append("Playing: \(clock.isPlaying)  |  has lyrics: \(clock.hasLyrics)")
        // tier 决定伺服用哪一组常数,判错的表现正是"这个播放器的歌词一直偏"。
        lines.append("Position source tier: \(clock.tier)")
        // 伺服误差的指数滑动平均。持续非零 = 预测位置跟播放器报的对不上,在反复拉回。
        lines.append(String(format: "Servo error EMA: %.3fs", clock.posErrEMASecs))
        // 自然切歌锚点超前的按曲校正(见 02 章)。非零时这首歌整体被拉过多少。
        lines.append(String(format: "Reported bias: %.3fs", clock.reportedBiasSecs))
        if let rate = clock.anchorRate, let age = clock.anchorAgeSecs {
            // 锚点年龄大得离谱 = 位置在长时间纯墙钟外推(浏览器那类只在切歌时报一次的源)。
            lines.append(String(format: "Anchor: rate=%.2f age=%.1fs", rate, age))
        } else {
            lines.append("Anchor: none (paused or no track)")
        }
        // 两层分开报:总偏移里有多少是用户自己调的、有多少是歌词文件自带的 [offset:]——
        // 歌词偏了时,这两个数直接指向该去改哪一个。
        lines.append("Lyrics offset (effective): \(clock.effectiveLyricsOffsetMs)ms"
                     + "  |  from LRC [offset:]: \(clock.lrcOffsetMs)ms")
        // 当前行填色是否已定格 —— 四个展示面 TimelineView 的停表条件,恒为 false 意味着
        // 有一条动画路径在空转。
        lines.append("Current line fill settled: \(clock.fillSettled)")
        lines.append("")

        return lines
    }

    /// 报告的日志段 —— 慢的那一半(OSLogStore 查询实测 4.4 秒,lyrimuse-engine healthcheck 的
    /// 网络探测另加几秒),刻意不标 @MainActor,好让 exportInteractively 把它整段丢到
    /// 后台线程去跑。
    ///
    /// secrets/currentTrackLines 由调用方在 MainActor 上先算好传进来:前者来自
    /// @MainActor 的 ConfigStore,后者需要调 @MainActor 的 EnrichCacheReader,
    /// 都不能在这个后台上下文里现读/现调。
    private static func logLines(secrets: [String: String], currentTrackLines: [String]?) -> [String] {
        var lines: [String] = []
        // 两段日志正文搬进了压缩包里各自的文件(见 writeDiagnosticsBundle),这里只留一句
        // 指路。报告因此保持在十几 KB —— 还能直接贴进 issue,而那正是它的用途。
        lines.append("== Logs ==")
        lines.append("完整日志在同一个压缩包里,都已脱敏:")
        lines.append("  lyrimuse.log  — 引擎,整份,不按时间截断、不折叠重复行")
        lines.append("  app-log.txt   — App 侧 os.Logger,最近 24 小时(OSLogStore 只留得住这么多)")
        lines.append("")
        // ---- App 进程的 stderr----
        //
        // App 进程的 stdout / stderr 由 StandardStreamRedirect 在启动第一步就重定向到 LogFiles.appStderr
        // (进程内自己做;此前靠 LaunchAgent plist 的 StandardErrorPath,再往前跟引擎
        // 共用 lyrimuse.log)。正常情况下这份文件几乎是空的 —— App 的日志走
        // os.Logger;能落进来的只有 Swift 运行时的 fatal 信息、子进程漏出的 stderr 这类"本不该有"
        // 的东西,正因为如此排查崩溃时它最有用。只取最后 100 行,同样过一遍脱敏。
        lines.append("== App stderr (\(LogFiles.appStderr.lastPathComponent), last 100 lines) ==")
        lines.append(contentsOf: recentAppStderrLines().map { LogRedactor.redactAll($0, secrets: secrets) })
        lines.append("")

        // ---- 最近崩溃报告----
        //
        // App 崩了 os.Logger 留不下现场;引擎走 KeepAlive 崩溃循环时 lyrimuse.log 里只见反复 starting;
        // Intel / Rosetta「打不开」、缺库、Launch Constraint 这类启动期事故日志里一行都没有 —— 而 macOS 早把
        // .ips 写在 ~/Library/Logs/DiagnosticReports/ 了,缺的只是收进导出。摘要以 termination 为主、帧只在有的
        // 时候附(本机 7 份真实报告 6 份 DYLD 缺库、1 份签名约束,故障线程一帧都没有);解析在 Core
        // CrashReportSummary,selftest 钉着三种样本。目录 / 文件读不到只留一行,不让导出失败。同样过脱敏。
        lines.append("== Recent Crash Reports (~/Library/Logs/DiagnosticReports, last 7 days) ==")
        lines.append(contentsOf: recentCrashReportLines().map { LogRedactor.redactAll($0, secrets: secrets) })
        lines.append("")

        // ---- 引擎 healthcheck----
        //
        // 引擎的 `healthcheck`(healthcheckcli.go):配置、歌词来源开关、缓存、导出目录、提交后端,再拿两首探测曲
        // 实测各歌词源。取文本输出,不用 -json;不传 -local-only,联网探测有自己的时限(见 engineHealthCheckLines)。
        lines.append("== Engine Health Check (`\(LyrimuseIdentity.current.engineExecutableName) healthcheck`) ==")
        lines.append(contentsOf: engineHealthCheckLines().map { LogRedactor.redactAll($0, secrets: secrets) })
        lines.append("")

        // ---- 当前播放曲目的歌词解析状态----
        //
        // 「这首歌没歌词/歌词不对/用错源了」是最常见的一类反馈,而排查的第一步永远是
        // "这首歌在缓存里到底是什么状态"——以前只能让用户在对话里报歌名歌手,再手动去
        // 歌词管理里查。EnrichCacheReader 全是本地只读查询、零网络,查询结果由调用方
        // (exportInteractively/buildReport,都在 MainActor 上)提前算好传进来——那个
        // 类型整体是 @MainActor,这里已经身处后台上下文,不能现调。查不到本身也是信号
        // (要么这首歌真的还没解析过,要么归一化 key 对不上——后者是「歌词管理」第 11 章
        // 记录过的真实坑)。
        if let currentTrackLines {
            lines.append("== Current Track Lyrics Resolution ==")
            lines.append(contentsOf: currentTrackLines)
            lines.append("")
        }

        return lines
    }

    // 只查这个 App 自己的 subsystem("me.yudaotor.lyrimuse",全部 Logger 调用点共用同一个
    // 值),不是整个系统日志——不需要额外权限,读的也只是自己写过的东西。scope 用
    // .system 而不是 .currentProcessIdentifier:后者只能看到"这次启动之后"的记录,诊断
    // "上次为什么崩了/上次启动出的问题"这种场景必须能看到上一次进程生命周期里的记录。
    private static func recentAppLogLines(hours: Int = 24) -> [String] {
        guard let store = try? OSLogStore(scope: .system) else {
            return ["(could not open log store)"]
        }
        let position = store.position(date: Date().addingTimeInterval(-Double(hours) * 3600))
        let predicate = NSPredicate(format: "subsystem == %@", "me.yudaotor.lyrimuse")
        guard let entries = try? store.getEntries(at: position, matching: predicate) else {
            return ["(could not read log entries)"]
        }
        var lines: [String] = []
        for entry in entries {
            guard let logEntry = entry as? OSLogEntryLog else { continue }
            lines.append("\(logEntry.date) [\(logEntry.category)] \(logEntry.composedMessage)")
        }
        return lines.isEmpty ? ["(no entries in the last \(hours)h)"] : lines
    }

    /// 最近 `days` 天内本 App 家族(App 本体 + 包内引擎)的崩溃报告摘要,每个进程最多 `perProcessLimit` 份
    ///。文件名前缀粗筛(`<可执行名>-*.ips` / 引擎的新旧两个名字 `-*.ips`),正文再按 bundle id /
    /// 包路径确认是本变体的(别的 App 也可能有叫 collector 的进程;Dev 与正式版互不混入)。目录列不出、单个文件
    /// 读不到或解不开都只留一行,不抛、不让整份导出失败;「没有匹配」也写出来。家目录改写成 ~。
    private static func recentCrashReportLines(days: Int = 7, perProcessLimit: Int = 3) -> [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent("Library/Logs/DiagnosticReports")
        func tilde(_ text: String) -> String { text.replacingOccurrences(of: home.path, with: "~") }
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: dir.path)
        } catch {
            return [tilde("(cannot list \(dir.path): \(error.localizedDescription))")]
        }
        // 进程名取自运行时,不写死:正式版与 Dev 的可执行文件同名,.ips 文件名前缀就是它。
        let executable = Bundle.main.executableURL?.lastPathComponent ?? "lyrimuse"
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var matched: [CrashReportSummary] = []
        var scanned = 0
        var problems: [String] = []
        for name in names where name.hasSuffix(".ips") && (name.hasPrefix("\(executable)-") || LyrimuseIdentity.engineProcessNames.contains { name.hasPrefix("\($0)-") }) {
            let url = dir.appendingPathComponent(name)
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  modified >= cutoff else { continue }
            scanned += 1
            guard let data = try? Data(contentsOf: url) else { problems.append("\(name): unreadable"); continue }
            guard let summary = CrashReportSummary.parse(fileName: name, data: data) else {
                problems.append("\(name): unparseable"); continue
            }
            guard summary.belongsToApp(executableName: executable,
                                       bundleIdentifier: LyrimuseIdentity.bundleIdentifier,
                                       appDisplayName: LyrimuseIdentity.displayName) else { continue }
            matched.append(summary)
        }
        var lines: [String] = []
        if matched.isEmpty {
            lines.append("(no crash reports for \(LyrimuseIdentity.displayName) / engine in the last \(days) days; \(scanned) candidate file(s) scanned)")
        } else {
            let shown = CrashReportSummary.select(matched, perProcessLimit: perProcessLimit)
            lines.append("\(matched.count) report(s) in the last \(days) days; showing up to \(perProcessLimit) per process (\(shown.count) shown)")
            for summary in shown { lines.append(contentsOf: summary.renderLines()) }
        }
        lines.append(contentsOf: problems.map { "(\($0))" })
        return lines.map(tilde)
    }

    private static func recentAppStderrLines(maxLines: Int = 100) -> [String] {
        guard let content = try? String(contentsOf: LogFiles.appStderr, encoding: .utf8) else {
            return ["(no \(LogFiles.appStderr.lastPathComponent) yet: the app creates it at launch; a missing file means this build predates the in-process redirect or the Logs folder is not writable)"]
        }
        let all = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return all.isEmpty ? ["(empty)"] : Array(all.suffix(maxLines))
    }

    /// 把报告和两份完整日志打成一个 zip。
    ///
    /// 为什么日志不再截断塞进报告:原来引擎那段取"最近 4 小时"、还压着 5000 行硬
    /// 上限,而这台机器 4 小时就有 9476 行 —— 实际连 4 小时都给不全。更要紧的是"窗口"这个
    /// 抽象本身就不对症:一首歌的歌词是哪一次解析定下来的,可能是几周前的事,而缓存永久
    /// 保留、日志会轮转。实测本机 first-resolve 决策的年龄 p90 是 7.2 天。
    ///
    /// 为什么导出时还要再脱敏一遍,而不是让用户直接把 ~/Library/Logs/lyrimuse.log 发出来:引擎
    /// 写日志时已经过一道凭据脱敏(logscrub.go 的 secretScrubber),这里再用 LogRedactor 按当前配置里的
    /// 凭据原文和正则兜一遍,两道是纵深关系,别因为源头有了就删掉这一道。导出还带上 App 侧日志和运行状态,
    /// 原始文件里没有这些。包里每个文件最后再把本机家目录换成 `~`(用户名是个人信息);曲名原样保留。
    ///
    /// 为什么是 zip 而不是一个大 txt:3MB 文本压完约 270KB,解压出来 report.txt 照样直接读、
    /// 日志照样直接 grep,而 3MB 的 txt 两头都不讨好。
    private static func writeDiagnosticsBundle(
        to destination: URL, bundleName: String, head: [String],
        secrets: [String: String], currentTrackLines: [String]?
    ) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("lyrimuse-diag-\(UUID().uuidString)")
        let staging = root.appendingPathComponent(bundleName, isDirectory: true)
        guard (try? fm.createDirectory(at: staging, withIntermediateDirectories: true)) != nil else { return }
        defer { try? fm.removeItem(at: root) }

        let report = (head + logLines(secrets: secrets, currentTrackLines: currentTrackLines))
            .joined(separator: "\n")
        var files: [(String, String)] = [
            ("report.txt", report),
            (LogFiles.engine.lastPathComponent, fullEngineLogText(secrets: secrets)),
            ("app-log.txt", fullAppLogText(secrets: secrets)),
        ]
        // 最近一份轮转归档也带上:引擎两三天轮转一次,刚轮转完就导出的话当前那份只有几分钟,历史全在归档里。
        if let archived = archivedEngineLogText(secrets: secrets) {
            files.append((LogFiles.engine.lastPathComponent + ".old", archived))
        }
        // App 主线程最近一次卡住时采的调用栈(MainThreadWatchdog),7 天内的才带。
        if let stall = recentMainThreadStallSample() {
            files.append((LogFiles.mainThreadStall.lastPathComponent, stall))
        }
        let home = fm.homeDirectoryForCurrentUser.path
        for (name, text) in files {
            try? LogRedactor.redactHomePath(text, home: home)
                .write(to: staging.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        zipDirectory(staging, to: destination)
    }

    /// 整份引擎日志,脱敏后原样保留 —— 不按时间截、不压行数上限、不折叠重复行。
    /// 折叠那套留给 report.txt 里几段小的;这一份是拿来 grep 的,少一行都可能正是那一行。
    ///
    /// 整块脱敏而不是逐行:实测 3MB / 18594 行,整块 258ms、逐行 754ms,产出一模一样。
    private static func fullEngineLogText(secrets: [String: String]) -> String {
        guard let content = try? String(contentsOf: LogFiles.engine, encoding: .utf8) else {
            return "(could not read \(LogFiles.engine.path))"
        }
        return LogRedactor.redactAll(content, secrets: secrets)
    }

    /// 引擎最近一份轮转归档(`<日志>.old`,名字由引擎的 logrotate.go 定),同样整份脱敏。
    /// 还没轮转过(没有这个文件)返回 nil,诊断包里就不出现这一份。
    private static func archivedEngineLogText(secrets: [String: String]) -> String? {
        let url = LogFiles.engine.deletingLastPathComponent()
            .appendingPathComponent(LogFiles.engine.lastPathComponent + ".old")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return LogRedactor.redactAll(content, secrets: secrets)
    }

    /// App 主线程最近一次卡住时采的调用栈(`LogFiles.mainThreadStall`,MainThreadWatchdog 覆盖写)。
    /// 没有这个文件、或者 `days` 天内没写过,返回 nil。内容只有符号和库路径,家目录由调用方统一改写。
    private static func recentMainThreadStallSample(days: Int = 7) -> String? {
        let url = LogFiles.mainThreadStall
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) <= TimeInterval(days) * 86_400
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// App 侧 24 小时的 os.Logger 记录,同样整份脱敏、不折叠。24 小时不是我们选的 ——
    /// OSLogStore 手里就只有这么多。
    private static func fullAppLogText(secrets: [String: String]) -> String {
        LogRedactor.redactAll(recentAppLogLines().joined(separator: "\n"), secrets: secrets)
    }

    /// 用 NSFileCoordinator 的 `.forUploading` 压包:系统自带,不依赖 /usr/bin/zip、不 spawn
    /// 子进程。它把目录压成一个**临时** zip 交给 block,那个文件在 block 返回后就没了,
    /// 所以必须在 block 里面就挪到目标位置。
    private static func zipDirectory(_ directory: URL, to destination: URL) {
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: directory, options: [.forUploading], error: &coordinatorError
        ) { zipped in
            let fm = FileManager.default
            try? fm.removeItem(at: destination)
            try? fm.moveItem(at: zipped, to: destination)
        }
    }
    /// 跑一次引擎的 `healthcheck`,写进报告的那几行。参数、超时和输出格式见 Core `DiagnosticsHealthCheck`;
    /// 二进制取包里那份(LyrimusePaths.bundledEnginePath)。启动失败、超时、空输出都写成报告里的一行,
    /// 不让导出因此失败。
    private static func engineHealthCheckLines() -> [String] {
        let enginePath = LyrimusePaths.bundledEnginePath
        guard FileManager.default.isExecutableFile(atPath: enginePath) else {
            return ["(engine binary not found at \(enginePath))"]
        }

        // stdout / stderr 分两路:报告本体走 stdout,探测曲触发的网络审计行走 stderr,合成一路会交叉穿插。
        // ProcessRunner 并发读空两根管子、到点先 SIGTERM 再 SIGKILL;是不是被它杀的看 `timedOut`,
        // 别用 terminationReason == .uncaughtSignal 去猜(任何信号杀死的进程都会命中)。
        // 子命令必须跟本 App 同一份配置目录 / 日志文件(Dev 构建是另一套),见 LyrimusePaths.engineEnvironment。
        guard let result = ProcessRunner.run(
            enginePath, DiagnosticsHealthCheck.arguments, timeout: DiagnosticsHealthCheck.timeoutSeconds,
            environment: LyrimusePaths.engineProcessEnvironment(), captureStderr: true)
        else {
            return ["(failed to launch engine healthcheck)"]
        }
        return DiagnosticsHealthCheck.reportLines(
            stdout: result.stdoutText, stderr: result.stderrText, status: result.status, timedOut: result.timedOut)
    }

    /// 当前播放曲目在本地 enrich 缓存里的解析状态——EnrichCacheReader 整个类型是
    /// @MainActor(只有几个纯换算函数显式 nonisolated,`resolvedKey`/`sourceInfo`/
    /// `lookup` 都不在其中),必须留在 MainActor 上调,不能挪进 logLines 那段后台
    /// 上下文。首次调用要解析整份缓存 JSON,但诊断导出是用户主动点一次的稀有操作,
    /// 不是热路径,这里跟 stateLines() 其它字段一样直接同步读。没有播放中的曲目
    /// (artist/title 都是空)时返回 nil,调用方据此跳过整个小节。
    @MainActor
    private static func currentTrackLyricsLines() -> [String]? {
        let coordinator = PlaybackCoordinator.shared
        let track = (artist: coordinator.artist, title: coordinator.title, album: coordinator.album)
        guard !track.artist.isEmpty || !track.title.isEmpty else { return nil }

        var lines: [String] = []
        lines.append("Track: \(track.artist) — \(track.title)" + (track.album.isEmpty ? "" : " (\(track.album))"))
        guard let key = EnrichCacheReader.resolvedKey(artist: track.artist, title: track.title, album: track.album) else {
            lines.append("Cache: no entry found (never resolved yet, or the normalized key doesn't match — see 第 11 章 known issues)")
            return lines
        }
        lines.append("Cache key: \(key)")
        if let source = EnrichCacheReader.sourceInfo(artist: track.artist, title: track.title, album: track.album) {
            lines.append("Lyrics source: \(source.lyricsSource ?? "(none)")  |  Cover source: \(source.coverSource ?? "(none)")")
        }
        if let lyrics = EnrichCacheReader.lookup(artist: track.artist, title: track.title, album: track.album) {
            lines.append("Has lyrics: \(!lyrics.lyrics.isEmpty)  |  word-level (YRC): \(!lyrics.lyricsYRC.isEmpty)"
                         + "  |  translation: \(!lyrics.lyricsTr.isEmpty)  |  romanization: \(!lyrics.lyricsRoma.isEmpty)")
            lines.append("Instrumental: \(lyrics.instrumental)  |  resolved: \(lyrics.resolved)")
        }
        return lines
    }
}

/// 诊断导出进行中。两个入口的按钮(`DiagnosticsExportButton`)据此转圈、置灰。
@MainActor
final class DiagnosticsExportStatus: ObservableObject {
    static let shared = DiagnosticsExportStatus()
    @Published fileprivate(set) var isExporting = false
}

/// 「导出诊断」按钮:导出期间置灰、旁边转圈。单独成一个视图,状态变化只重画这一颗,不打醒整个设置分页。
struct DiagnosticsExportButton: View {
    let title: String
    @ObservedObject private var status = DiagnosticsExportStatus.shared

    var body: some View {
        HStack(spacing: 6) {
            if status.isExporting { ProgressView().controlSize(.small) }
            Button(title) { DiagnosticsExporter.exportInteractively() }
                .disabled(status.isExporting)
        }
    }
}
