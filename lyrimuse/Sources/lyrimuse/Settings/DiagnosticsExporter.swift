import Foundation
import LyrimuseCore
import OSLog
import AppKit
import Darwin

// 一键导出诊断信息:collector 日志走 ~/Library/Logs/lyrimuse.log,App 自己
// 的日志全部走 os.Logger(系统统一日志),普通用户不会用 Console.app 去查。这个文件把
// 两边日志 + 关键状态(权限/常驻服务/各功能是否已配置)汇总成一份文本文件,方便不懂
// 技术的用户自己导出发过来排查问题。
//
// 安全上的硬约束:绝不能把 ConfigStore 里任何 token/secret 的原始值写进这份文件——这份
// 文件很可能被贴进公开的 GitHub issue。这条约束由**两道**独立的机制守着,缺一不可:
//
//  1. 结构化那一段(== State ==)只复用 ConfigStore 已有的 isXConfigured/xMissingHint()
//     这批只读布尔判断,不直接触碰 savedSnapshot 里的字段本身。
//  2. 附在报告末尾的日志正文统一过 redacted() → LogRedactor 脱敏。
//
// 第 2 条是 2026-08-13 补的,补之前这条约束实际上是**破的**:第 1 条只管结构化字段,而
// 报告末尾把 ~/Library/Logs/lyrimuse.log 的最后 200 行原样附上,凭据从日志正文里漏出去。
// 实测当时本机那 200 行内就有 3 处 Last.fm API Key 原文 —— 来源是 collector 打印 Go
// *url.Error 的原文,而它的 Error() 会带出完整 URL,api_key 就在 query string 里。
// 详见 LogRedactor 的注释。往这份报告里加任何新的日志段落,都必须一并套上 redacted()。
//
// 2026-08-27 这一轮的目标从"至少别泄密"扩成"真的能靠这一份文件排查问题"——用户明确
// 要求把这份导出做成"遇到 bug/想反馈问题时发我一份,我就能查"的入口,覆盖网络/逻辑/UI/
// 交互/系统兼容性几个层面。这轮之前用一份真实导出(3254 行)回头核对过,暴露出几个
// 实打实的问题,这轮改动的依据都在下面各自的注释里,不是凭空猜的:
//   - App Log 里"snapshot failed"一条重复了 921 次(占 24 小时窗口的 30%)——已经在
//     LocalPlaybackSource.poll() 里改成只在状态变化时打,这份文件里的 collapseRepeatedLines
//     是给"改不到源头"的重复日志(比如例行的网络审计成功调用)兜底用的第二道防线。
//   - Collector Log 固定"最后 200 行"在网络审计日志接入之后被例行轮询快速填满,实测
//     一份导出里这 200 行只覆盖了 45 分钟——改成按时间窗口取。
//   - App 侧日志用 os.Logger,自带 UTC(+0000);Collector 日志原来是 Go `log.LstdFlags`
//     的本地墙钟、不带时区标记,两段日志的时间轴对不上(collector 侧已经加 log.LUTC 修掉,
//     这里的写法照旧,顺手把段落标题写清楚是 UTC,省得读的人自己心算)。
enum DiagnosticsExporter {
    static func suggestedFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Lyrimuse-Diagnostics-\(formatter.string(from: Date())).txt"
    }

    // 只生成内容,不碰任何文件系统写入——存哪、怎么存交给调用方(SettingsView 用
    // NSSavePanel)。写入路径由用户自己在系统存储面板里确认,天然不会撞上桌面/文稿/
    // 下载三个目录可能存在的 TCC 保护,也跟这个项目里选歌词文件夹用 NSOpenPanel 是
    // 同一个思路。
    /// 弹保存面板 → 后台生成内容 → 写盘 → 在访达里选中它。
    ///
    /// **顺序是刻意的**:面板先弹,内容后生成。以前是反过来的(先 buildReport 再弹面板),
    /// 而 buildReport 里的 OSLogStore 查询实测要 **4.4 秒**(扫 24 小时、拉回一万多行),
    /// 又整个跑在主线程上 —— 于是点下"导出…"之后界面冻四秒多才看到保存面板,像是卡死。
    /// 现在面板立刻出现,重活在用户挑完位置之后于后台线程跑。2026-08-27 新加的 collector
    /// healthcheck 子进程(带真实网络探测)和收听记录解析也都挂在这同一段后台任务里——
    /// 导出整体可能因此再多等几秒,但用户此时已经看不到主界面被卡住,跟原有取舍一致。
    ///
    /// 收进这里而不是留在 SettingsView:这个按钮有两个调用点("关于"页和常驻服务启用
    /// 失败时的补救入口),顺序一旦写反就又变回卡四秒,不该让两处各自维护一遍。
    @MainActor
    static func exportInteractively() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // 状态段要读 @MainActor 的单例,先在主线程取好;日志段(慢的那部分)扔后台。
        let head = stateLines()
        let secrets = ConfigStore.shared.secretsForRedaction
        // 当前曲目的歌词解析状态也要在这里先算好——EnrichCacheReader 整个类型是
        // @MainActor(只有少数纯换算函数显式 nonisolated),`sourceInfo`/`lookup`/
        // `resolvedKey` 都不在那份白名单里,不能挪到下面的 Task.detached 里调。
        let currentTrackLines = currentTrackLyricsLines()
        Task { @MainActor in
            let logs = await Task.detached(priority: .userInitiated) {
                logLines(secrets: secrets, currentTrackLines: currentTrackLines)
            }.value
            let report = (head + logs).joined(separator: "\n")
            try? report.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// 同步全量生成。留着给"就是要一次拿到整份文本"的场景;交互式导出请用
    /// `exportInteractively()`,别在主线程上等这个。
    @MainActor
    static func buildReport() -> String {
        return (stateLines() + logLines(secrets: ConfigStore.shared.secretsForRedaction,
                                        currentTrackLines: currentTrackLyricsLines()))
            .joined(separator: "\n")
    }

    /// 报告的状态段 —— 全部来自 @MainActor 隔离的单例,但都是内存读,很便宜。
    @MainActor
    private static func stateLines() -> [String] {
        var lines: [String] = []

        lines.append("Lyrimuse Diagnostics")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        lines.append("== System ==")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("App version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")
        // 架构 + 是否在 Rosetta 下跑(2026-08-27 加)。这个项目发布流程真的出过事故——
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
        lines.append("Automation permission: \(MusicAutomationPermission.check(askIfNeeded: false))")
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
        // 2026-09-01 多选后:可能不止一个,按 rawValue 逗号拼接全部报出来。
        lines.append("Player (setting): \(PlaybackPlayerPreference.selected.map(\.rawValue).sorted().joined(separator: ", "))")
        // 标签写 "last detected" 而不是 "now":这个值来自最近一次成功的快照,而快照在停播/
        // 检测失效时不会被清掉,所以停播之后它仍然报最后一次识别到的播放器。读报告的人得
        // 知道这一点,否则会把陈旧值当成当下状态。
        lines.append("Player (last detected): \(PlaybackCoordinator.shared.resolvedPlayerDescription)")
        lines.append("Collector service enabled (setting): \(settings.collectorServiceEnabled)")
        // 报完整三态而不是 true/false —— "注册了但起不来"正是最需要出现在诊断报告里的那
        // 一档(带上次退出码),以前它跟"在跑"一样报 true,报告等于把最关键的线索抹掉了。
        lines.append("Collector service state: \(CollectorServiceManager.state)")
        lines.append("App language: \(settings.appLanguage)")
        lines.append("Classic overlay enabled: \(settings.classicOverlayEnabled)")
        lines.append("Notch overlay enabled: \(settings.notchOverlayEnabled)")
        lines.append("ListenBrainz configured (submit): \(config.isListenBrainzConfigured)")
        // 分开报:只有 token 时"能提交"为真而"能读统计"为假,周报/日报/桥接会静默不跑,
        // 而这正是最难自己看出来的一种配置状态。
        lines.append("ListenBrainz readable (digests/bridge): \(config.isListenBrainzReadable)")
        // 2026-07-29 起没有独立开关了,两边凭据都配好就自动生效,这里直接报告"是否真的
        // 在跑"而不是"Last.fm 侧凭据填了没"(后者单独看意义不大,还得对照上一行才知道
        // 有没有真的启用)。
        lines.append("Last.fm bridge active: \(config.lastfmBridgeMissingHint() == nil && config.isListenBrainzReadable)")
        // lastfmMirrorMissingHint 2026-08-11 已删(开关自己就是配置入口,不再需要前置
        // 校验函数),它检查的三个字段里 sessionKey 是最后一步产物,单看它就等价。
        lines.append("Last.fm mirror configured: \(!config.lastfmScrobbleSessionKey.isEmpty)")
        lines.append("State relay configured: \(config.stateRelayMissingHint() == nil)")
        lines.append("Push notification configured: \(config.pushMissingHint() == nil)")
        // 自动更新状态(2026-08-27 加)。「为什么没提示我更新」是另一类常见反馈,而
        // Sparkle 自己的这两个字段(是否开着周期检查、上一次真的检查是什么时候)足够
        // 回答大半——不用再让用户去猜"是不是它压根没在检查"。lastUpdateCheckDate 是
        // Sparkle 自己维护的只读字段,读取本身零成本,不涉及联网。
        let sparkle = SparkleUpdaterManager.shared.controller.updater
        lines.append("Auto-update checks: \(sparkle.automaticallyChecksForUpdates)"
                     + (sparkle.lastUpdateCheckDate.map { " (last checked: \(ISO8601DateFormatter().string(from: $0)))" }
                        ?? " (never checked this run)"))
        lines.append("")

        // ---- 窗口(2026-08-27 加)----
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

        // ---- 播放时钟(2026-08-22 加)----
        //
        // 「歌词慢半拍」是最常被报、也最难复现的一类问题,而它至少有四种成因、修法完全不同:
        // 帧率掉了 / positionSourceTier 判错 / 伺服在反复 snap / 自然切歌偏置估歪。此前这一段
        // 完全不存在,报告里没有任何一项能把这四种区分开,只能靠猜加翻 collector 日志。
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
        if let rate = clock.anchorRate, let fresh = clock.anchorFresh, let age = clock.anchorAgeSecs {
            // 锚点年龄大得离谱 = 位置在长时间纯墙钟外推(浏览器那类只在切歌时报一次的源)。
            lines.append(String(format: "Anchor: rate=%.2f fresh=%@ age=%.1fs",
                                rate, fresh ? "yes" : "no", age))
        } else {
            lines.append("Anchor: none (paused or no track)")
        }
        // 两层分开报:总偏移里有多少是用户自己调的、有多少是歌词文件自带的 [offset:]。
        // 用户报"歌词偏了"时,这两个数直接指向该去改哪一个。
        lines.append("Lyrics offset (effective): \(clock.effectiveLyricsOffsetMs)ms"
                     + "  |  from LRC [offset:]: \(clock.lrcOffsetMs)ms")
        // 当前行填色是否已定格 —— 四个展示面 TimelineView 的停表条件,恒为 false 意味着
        // 有一条动画路径在空转。
        lines.append("Current line fill settled: \(clock.fillSettled)")
        lines.append("")

        return lines
    }

    /// 报告的日志段 —— 慢的那一半(OSLogStore 查询实测 4.4 秒,collector healthcheck 的
    /// 网络探测另加几秒),刻意不标 @MainActor,好让 exportInteractively 把它整段丢到
    /// 后台线程去跑。
    ///
    /// secrets/currentTrackLines 由调用方在 MainActor 上先算好传进来:前者来自
    /// @MainActor 的 ConfigStore,后者需要调 @MainActor 的 EnrichCacheReader,
    /// 都不能在这个后台上下文里现读/现调。
    private static func logLines(secrets: [String: String], currentTrackLines: [String]?) -> [String] {
        var lines: [String] = []
        lines.append("== App Log (last 24h, UTC, subsystem me.yudaotor.lyrimuse) ==")
        lines.append(contentsOf: collapseRepeatedLines(
            recentAppLogLines().map { LogRedactor.redactAll($0, secrets: secrets) }))
        lines.append("")
        // 2026-08-27 从固定"最后 200 行"改成按时间窗口取——collector 那边接入网络审计
        // 日志(第 15 章)之后,例行轮询把这 200 行迅速填满,实测一份导出里这 200 行只
        // 覆盖了 45 分钟,稍早一点发生的事在导出这一刻已经被冲出窗口。改成取最近 4 小时,
        // 配合下面的 collapseRepeatedLines 把例行重复调用折叠掉,总行数不会比以前离谱地
        // 多,但覆盖的时间跨度更接近 App Log 那边的 24 小时。collector 侧同步加了
        // log.LUTC(main.go),这里显式在标题里写 UTC,两段日志才真的能对得上表。
        lines.append("== Collector Log (last 4h, UTC) ==")
        lines.append(contentsOf: collapseRepeatedLines(
            recentCollectorLogLines().map { LogRedactor.redactAll($0, secrets: secrets) }))
        lines.append("")

        // ---- collector healthcheck(2026-08-27 加)----
        //
        // collector 早就有一个专门回答"歌词为什么不出来"的一次性子命令(healthcheckcli.go):
        // 配置文件能不能解析、歌词来源开关、缓存文件是否可解析、歌词导出目录能不能写、
        // ListenBrainz/Last.fm 是否配置好,以及**真拿两首探测曲实测**各歌词源现在给不给
        // 候选、网络整体是否看起来通(networkLooksDown)。这些结论此前只有用户自己在终端
        // 跑 `collector healthcheck` 才看得到,诊断导出完全没有引用——相当于放着一份现成的
        // 网络层/逻辑层体检报告没用上。这里跟"联网搜索候选歌词"用同一个模式(Process 调用
        // 打包进 .app 里的 collector 二进制),直接拿文本输出(不用 -json,省一层解析,
        // 输出本身已经是给人看的格式)。
        //
        // 不传 -local-only:接受多等几秒换真实的网络探测结果——这一步本来就在后台线程跑,
        // 用户此时已经看不到界面被卡住。加一道超时保护:两首探测曲理论上 collector 自己有
        // 超时,但子进程整体卡死的可能性不能排除(比如某个源的 HTTP 客户端没设超时),
        // 诊断导出本身不能被这个拖死。
        lines.append("== Collector Health Check (`collector healthcheck`) ==")
        lines.append(contentsOf: collectorHealthCheckLines().map { LogRedactor.redactAll($0, secrets: secrets) })
        lines.append("")

        // ---- 当前播放曲目的歌词解析状态(2026-08-27 加)----
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

    /// collector 日志按**时间窗口**取,不是固定行数(见上面 logLines 里的说明)。文件本身
    /// 没有轮转(lyricstrace.go 的注释也提过这一点),整份读进内存一次性 split 仍然可接受
    /// (一次性的后台操作,不是热路径);hardLineCap 只是防一个已经异常暴涨的日志文件把
    /// 导出拖到不合理的大小/耗时。
    ///
    /// 用**倒着扫**找窗口起点,而不是从头正着过滤——文件可能有几十 MB,没必要为了找"最后
    /// 4 小时从哪开始"把每一行都解析一遍时间戳,倒着扫找到第一条早于 cutoff 的行就能停。
    private static func recentCollectorLogLines(hours: Double = 4, hardLineCap: Int = 5000) -> [String] {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/lyrimuse.log")
        guard let content = try? String(contentsOf: path, encoding: .utf8) else {
            return ["(could not read \(path.path))"]
        }
        let allLines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !allLines.isEmpty else { return ["(empty log file)"] }

        let cutoff = Date().addingTimeInterval(-hours * 3600)
        let formatter = DateFormatter()
        // Go `log.LstdFlags | log.LUTC` 的格式是 "2006/01/02 15:04:05 message"——前 19
        // 个字符正好是这个时间戳,不含时区标记(LUTC 只改墙钟取的是哪个时区,不改打印
        // 格式),这里显式把 formatter 的时区钉死成 UTC 才能跟它对上。
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")

        // 默认包含整份文件——找不到任何可解析的时间戳时,宁可多给一点也不要因为解析
        // 失败就悄悄给出一份空/近乎空的日志段(诊断报告的原则是宁可啰嗦,不能装作没事)。
        var startIndex = 0
        for i in stride(from: allLines.count - 1, through: 0, by: -1) {
            let line = allLines[i]
            guard line.count >= 19, let date = formatter.date(from: String(line.prefix(19))) else { continue }
            if date < cutoff {
                startIndex = i + 1
                break
            }
            startIndex = i
        }
        let windowed = Array(allLines[startIndex...])
        return windowed.count > hardLineCap ? Array(windowed.suffix(hardLineCap)) : windowed
    }

    /// 把"内容几乎相同、只有时间戳/耗时/计数这类可变部分不同"的连续大量重复行折叠成一条
    /// 摘要。网络审计的例行成功调用(比如同一个 host 被反复访问)、轮询失败这类天生噪音
    /// 典型都长这样——实测一份真实导出里,这类重复行能占到 App Log 的六七成,把真正
    /// 罕见、值得看的信号淹没掉。
    ///
    /// 判据:抹掉行内所有连续数字段(时间戳、耗时、计数)之后如果跟别的行长得一模一样,
    /// 就算"同一类"。只在**同一类出现次数达到阈值**时才折叠,保留首尾两条(各自带真实
    /// 时间戳)加一行"中间还有 N 条被省略"——低于阈值的重复(比如偶尔重试两三次)原样
    /// 保留,那种量级的重复本身往往就是有意义的信号,不该被抹掉。
    ///
    /// 阈值选 12 是刻意的:高到不会把"设置面板开关了 30 次"这类还算有时间线索价值的
    /// 中等频率事件折叠掉,低到能盖住实测坐实的几个真正病理性重复(921/1092/168 次的
    /// 那几类)。折叠是**全局**的(不要求连续出现),因为像"image"这类网络审计行天然会
    /// 跟别的日志穿插在一起,只按连续段折叠效果有限。
    private static func collapseRepeatedLines(_ lines: [String], minRepeat: Int = 12) -> [String] {
        func template(_ line: String) -> String {
            var out = ""
            out.reserveCapacity(line.count)
            var lastWasDigit = false
            for ch in line {
                if ch.isASCII, ch.isNumber {
                    if !lastWasDigit { out.append("#") }
                    lastWasDigit = true
                } else {
                    out.append(ch)
                    lastWasDigit = false
                }
            }
            return out
        }

        var indicesByTemplate: [String: [Int]] = [:]
        for (i, line) in lines.enumerated() {
            indicesByTemplate[template(line), default: []].append(i)
        }

        var dropped = Set<Int>()
        var insertAfter: [Int: String] = [:]
        for indices in indicesByTemplate.values where indices.count >= minRepeat {
            let middle = indices.dropFirst().dropLast()
            for i in middle { dropped.insert(i) }
            insertAfter[indices.first!] =
                "    ⋯ 以上这类日志又重复了 \(middle.count) 次（已省略，下一行是最后一次出现）⋯"
        }

        var out: [String] = []
        out.reserveCapacity(lines.count)
        for (i, line) in lines.enumerated() {
            if dropped.contains(i) { continue }
            out.append(line)
            if let note = insertAfter[i] { out.append(note) }
        }
        return out
    }

    /// 跑一次 `collector healthcheck`(不带 -json,输出本身就是给人看的格式;不带
    /// -local-only,接受多等几秒换真实网络探测结果)。跟 LyricsSearchService 用同一套
    /// "Bundle.main 拼 Contents/Resources/collector"规则定位二进制。
    ///
    /// 这个操作本身对"排查为什么坏了"这件事天然健壮很重要——用户导出诊断信息往往正是
    /// 因为某处坏了,healthcheck 子进程本身启动失败/超时/空输出都必须体现成报告里的一行
    /// 文字,不能让整个导出因此崩掉或者悄悄漏掉这一段。
    private static func collectorHealthCheckLines() -> [String] {
        let collectorPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/collector").path
        guard FileManager.default.isExecutableFile(atPath: collectorPath) else {
            return ["(collector binary not found at \(collectorPath))"]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: collectorPath)
        process.arguments = ["healthcheck"]
        // 分两路管道,不合成一路:healthcheck 报告本身走 fmt.Println(stdout),但它触发的
        // 两首探测曲会经 doHTTPTracked 打一堆 `api call: ...` 审计行到 log.Printf(stderr)。
        // 合成一路会让结构化报告跟这堆网络噪音交叉穿插,可读性反而更差(实测直接在终端跑
        // 一次就验证到这一点)。分开之后 stdout 是主体,stderr 只在非空时作为附注折叠展示。
        //
        // 两路各自开独立队列并发读,不能顺序读——跟 LyricsSearchService 读 collector
        // 子进程 stdout/stderr 同一个理由:某一路写满 64KB 内核管道缓冲区时会阻塞在
        // write() 上,父进程如果还在顺序等另一路先读完,就会死锁。
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ["(failed to launch collector healthcheck: \(error.localizedDescription))"]
        }

        // 超时保护:两首探测曲各自有 collector 内部的网络超时,但子进程整体卡死的可能性
        // 不能排除,15s 后强制结束——足够覆盖正常情况(实测通常 1~3s),又不会让一次
        // 诊断导出因为这一步被无限期拖住。timedOut 显式记一下"是不是我们自己杀的",
        // 不要事后用 terminationReason == .uncaughtSignal 去猜——那个条件任何信号
        // 杀死的进程都会命中,拿它反推"超时"会把真实崩溃误报成超时。
        var timedOut = false
        let timeoutTimer = DispatchSource.makeTimerSource()
        timeoutTimer.schedule(deadline: .now() + 15)
        timeoutTimer.setEventHandler {
            guard process.isRunning else { return }
            timedOut = true
            process.terminate()
        }
        timeoutTimer.resume()

        var stdoutData = Data()
        var stderrData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        process.waitUntilExit()
        timeoutTimer.cancel()

        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        guard !stdoutText.isEmpty else {
            return ["(collector healthcheck produced no output, exit code \(process.terminationStatus))"]
        }
        var resultLines = stdoutText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if timedOut {
            resultLines.append("(healthcheck timed out after 15s and was terminated — the report above may be incomplete)")
        }
        if let stderrText = String(data: stderrData, encoding: .utf8), !stderrText.isEmpty {
            resultLines.append("")
            resultLines.append("-- healthcheck 探测期间产生的原始日志(通常是探测曲触发的网络审计行,非结构化报告本体) --")
            resultLines.append(contentsOf: collapseRepeatedLines(
                stderrText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)))
        }
        return resultLines
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
