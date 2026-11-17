import AppKit
import Foundation
import LyrimuseCore

// 主线程上的同步 I/O、异常守卫、运行环境(14 章决策 194「同类第二轮」、15 章决策 104 / 110)。
// 行为测 Core 里的复用件,App 目标里的接线按源码契约钉住:读取器只在后台那一处被读,旧写法回来这里就红。
func runMainThreadIOTests() {
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let repo = sources.deletingLastPathComponent().deletingLastPathComponent()
    func app(_ rel: String) -> String { (try? String(contentsOf: sources.appendingPathComponent("lyrimuse/" + rel), encoding: .utf8)) ?? "" }
    func core(_ rel: String) -> String { (try? String(contentsOf: sources.appendingPathComponent("LyrimuseCore/" + rel), encoding: .utf8)) ?? "" }
    func repoText(_ rel: String) -> String { (try? String(contentsOf: repo.appendingPathComponent(rel), encoding: .utf8)) ?? "" }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lyrimuse-mainthread-io-\(getpid())-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    /// 主线程上转 run loop,直到 `done` 为真或超时。
    func spin(until done: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    do {
        print("\n== 主线程 I/O:mtime 与按 mtime 缓存的状态文件 ==")
        let url = tmp.appendingPathComponent("status.json")
        expectEqual(FileIO.modificationDate(url), nil, "mtime: 文件不在是 nil")
        try? Data("1".utf8).write(to: url)
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        try? FileManager.default.setAttributes([.modificationDate: first], ofItemAtPath: url.path)
        expectEqual(FileIO.modificationDate(url), first, "mtime: 读到文件的修改时间")
        let second = first.addingTimeInterval(60)
        try? FileManager.default.setAttributes([.modificationDate: second], ofItemAtPath: url.path)
        expectEqual(FileIO.modificationDate(url), second, "mtime: 同一个 URL 再问一次读到新值(不吃 URL 对象的资源值缓存)")

        final class Counter: @unchecked Sendable { var n = 0 }
        let parses = Counter()
        let file = MTimeCachedFile(url: url) { data -> String? in
            parses.n += 1
            return String(data: data, encoding: .utf8)
        }
        expectEqual(file.read(), "1", "按 mtime 缓存: 第一次读解")
        expectEqual(file.read(), "1", "按 mtime 缓存: 没变再读")
        expectEqual(parses.n, 1, "按 mtime 缓存: 没变不重解")
        try? Data("2".utf8).write(to: url)
        try? FileManager.default.setAttributes([.modificationDate: second.addingTimeInterval(60)], ofItemAtPath: url.path)
        expectEqual(file.read(), "2", "按 mtime 缓存: mtime 变了重读")
        try? FileManager.default.removeItem(at: url)
        expectEqual(file.read(), nil, "按 mtime 缓存: 文件删了是 nil")
    }

    do {
        print("\n== 主线程 I/O:单飞的后台读 ==")
        MainActor.assumeIsolated {
            let reads = SingleFlightBackgroundRead<Int>()
            let gate = DispatchSemaphore(value: 0)
            final class Flags: @unchecked Sendable { var readOnMain: Bool?; var applied: [Int] = [] }
            let flags = Flags()
            let started = reads.start(read: {
                flags.readOnMain = Thread.isMainThread
                gate.wait()
                return 1
            }) { flags.applied.append($0) }
            let second = reads.start(read: { 2 }) { flags.applied.append($0) }
            expectEqual([started, second, reads.isInFlight], [true, false, true], "单飞: 上一次没回来时不再派")
            gate.signal()
            spin(until: { !reads.isInFlight })
            expectEqual(flags.applied, [1], "单飞: 回主线程交结果")
            expectEqual(flags.readOnMain, false, "单飞: 读在后台线程上")

            reads.start(read: {
                gate.wait()
                return 3
            }) { flags.applied.append($0) }
            reads.invalidate()
            gate.signal()
            spin(until: { !reads.isInFlight })
            expectEqual(flags.applied, [1], "单飞: 作废之后回来的那次不采用")
            expectEqual(reads.start(read: { 4 }) { flags.applied.append($0) }, true, "单飞: 作废的那次回来后能再派")
            spin(until: { !reads.isInFlight })
            expectEqual(flags.applied, [1, 4], "单飞: 再派的照常采用")
        }
    }

    do {
        print("\n== 主线程 I/O:播放状态写盘 ==")
        final class Threads: @unchecked Sendable {
            let lock = NSLock()
            var onMain: [Bool] = []
            func add(_ v: Bool) { lock.lock(); onMain.append(v); lock.unlock() }
        }
        let threads = Threads()
        let url = tmp.appendingPathComponent("playback.json")
        let writer = PlaybackStateFileWriter(url: url) { threads.add($0) }
        for i in 1...30 { writer.write(Data("seq \(i)".utf8)) }
        writer.flush()
        expectEqual((try? String(contentsOf: url, encoding: .utf8)) ?? "", "seq 30", "播放状态写盘: 按交来的顺序写,最后一份留在盘上")
        threads.lock.lock()
        let onMain = threads.onMain
        threads.lock.unlock()
        expectEqual(onMain.count, 30, "播放状态写盘: flush 返回时交来的都写完了")
        expectEqual(onMain.contains(true), false, "播放状态写盘: 不在主线程上写")
        let file = core("Local/PlaybackStateFile.swift")
        let publisher = sourceBody("public final class PlaybackStatePublisher", in: file)
        expectEqual(sourceHas(sourceBody("private func write(_ content: PlaybackStateFile.Content, now: Date)", in: publisher),
                              "fileWriter?.write(data)")
                    && !publisher.contains("data.write(to: PlaybackStateFile.url"), true,
                    "播放状态写盘(契约): 发布器把编码好的记录交给写盘队列,自己不写文件")
        expectEqual(sourceHas(sourceBody("public func markExiting()", in: publisher), "write(.exiting, now: Date())\nfileWriter?.flush()"), true,
                    "播放状态写盘(契约): 退出时等「App 要走了」那份写完")
    }

    do {
        print("\n== 主线程 I/O:状态观察器只在后台读 ==")
        let lb = app("Settings/ListenBrainzSubmitStatusWatcher.swift")
        let relay = app("Settings/RelayPushStatusWatcher.swift")
        expectEqual(appCodeOccurrences(of: "ListenBrainzSubmitStatus.parse") == ["lyrimuse/Settings/ListenBrainzSubmitStatusWatcher.swift"]
                    && sourceHas(lb, "MTimeCachedFile(url: LyrimusePaths.configFile(ListenBrainzSubmitStatus.fileName)")
                    && sourceHas(sourceBody("func refresh()", in: lb), "reads.start(read: { file.read() })"), true,
                    "ListenBrainz 状态(契约): 只在观察器的后台读里读文件")
        expectEqual(sourceHas(app("Settings/ListenBrainzAuthNotifier.swift"), "watcher.$info.combineLatest(watcher.$loaded) .filter { $0.1 }"), true,
                    "ListenBrainz 状态(契约): 通知等第一次读落下再看,读到之前的 nil 不撤通知")
        expectEqual(appCodeOccurrences(of: "RelayPushStatus.parse") == ["lyrimuse/Settings/RelayPushStatusWatcher.swift"]
                    && sourceHas(sourceBody("func refresh()", in: relay), "reads.start(read: { file.read() })"), true,
                    "网页推送状态(契约): 只在观察器的后台读里读文件")
        let monitor = app("Settings/LyricsWordFormatSwitchMonitor.swift")
        expectEqual(appCodeOccurrences(of: "LyricsWordFormatSwitch.current") == ["lyrimuse/Settings/LyricsWordFormatSwitchMonitor.swift"]
                    && sourceHas(sourceBody("private func poll()", in: monitor), "reads.start(read: { LyricsWordFormatSwitch.current })")
                    && sourceHas(sourceBody("private func stop()", in: monitor), "reads.invalidate()"), true,
                    "逐字格式切换(契约): 状态文件在后台读,停下时作废还在飞的那次")
        expectEqual(sourceHas(app("Settings/DebugDeepLinks.swift"),
                              "if state == \"poll\" {\nLyricsWordFormatSwitchMonitor.shared.requested("), true,
                    "逐字格式切换(契约): debug/word-format-switch?state=poll 走真实轮询")
        let backfill = app("Settings/ScrobbleBackfillService.swift")
        expectEqual(sourceHas(sourceBody("func runBackfill()", in: backfill),
                              "await Task.detached(priority: .utility) { FileIO.decodeJSON(Progress.self, from: progressURL) }.value"), true,
                    "补提交进度(契约): 进度文件在后台读解")
        for (name, text) in [("ListenBrainzSubmitStatusWatcher", lb), ("RelayPushStatusWatcher", relay),
                             ("ScrobbleBackfillService", backfill), ("LastfmStatsService", app("Settings/LastfmStatsService.swift"))] {
            expectEqual(sourceHas(text, "attributesOfItem"), false, "mtime(契约): \(name) 用 FileIO.modificationDate,不用 attributesOfItem")
        }
    }

    do {
        print("\n== 主线程 I/O:Last.fm 统计 ==")
        let stats = app("Settings/LastfmStatsService.swift")
        let initBody = sourceBody("private init() {", in: stats)
        expectEqual(sourceHas(initBody, "loadPersistedState()") && !sourceHas(initBody, "loadSnapshot()") && !sourceHas(initBody, "loadRecentPageCache()"), true,
                    "Last.fm 统计(契约): 启动时不在主线程上读快照和翻页缓存")
        let load = sourceBody("private func loadPersistedState()", in: stats)
        expectEqual(sourceHas(load, "Task.detached(priority: .utility)") && sourceHas(load, "Self.readSnapshot(snapshotURL)")
                    && sourceHas(load, "Self.readRecentPageCache(pagesURL)"), true,
                    "Last.fm 统计(契约): 快照和翻页缓存在后台读解")
        let finish = sourceBody("private func finishPersistedLoad(", in: stats)
        let order = ["applySnapshot(snapshot)", "applyRecentPageCache(pages)", "pollFeedFile()"].map { finish.range(of: $0)?.lowerBound }
        expectEqual(order.allSatisfy { $0 != nil } && order[0]! < order[1]! && order[1]! < order[2]!, true,
                    "Last.fm 统计(契约): 先快照、再翻页缓存、最后才读 feed")
        expectEqual(sourceHas(sourceBody("private func applySnapshot(_ snap: StatsSnapshot)", in: stats),
                              "guard fetchedAt.isEmpty, overview == nil, recent.isEmpty else {"), true,
                    "Last.fm 统计(契约): 快照晚于线上数据到达时不拿旧的去盖")
        let poll = sourceBody("private func pollFeedFile()", in: stats)
        expectEqual(sourceHas(poll, "guard persistedStateLoaded, credentials != nil else { return }")
                    && sourceHas(poll, "feedReads.start(read: { Self.readFeed(url, ifChangedFrom: known) })")
                    && !sourceHas(poll, "FileIO.read("), true,
                    "Last.fm 统计(契约): feed 的 stat、读、解在后台,主线程只 ingest")
        expectEqual(sourceHas(sourceBody("func resetAll()", in: stats), "feedReads.invalidate()"), true,
                    "Last.fm 统计(契约): 换账号时作废还在飞的 feed 读")
    }

    do {
        print("\n== 主线程 I/O:钥匙串、登录项、iCloud、目录检查、壁纸 ==")
        let delegate = app("AppDelegate.swift")
        let willFinish = sourceBody("func applicationWillFinishLaunching(_ notification: Notification)", in: delegate)
        expectEqual(sourceHas(willFinish, "terminateOlderInstances()"), true, "钥匙串(契约): 找得到启动那段")
        expectEqual(sourceHas(willFinish, "Task.detached(priority: .userInitiated) { _ = CredentialVaultStore.shared.load() }"), true,
                    "钥匙串(契约): 启动最早处在后台预读保险箱")
        let watcher = app("Settings/KeychainUnlockWatcher.swift")
        expectEqual(sourceHas(sourceBody("static func tick()", in: watcher), "checks.start(read: { unlockedSinceHint() })")
                    && !sourceHas(sourceBody("static func tick()", in: watcher), "KeychainLock.check")
                    && sourceHas(sourceBody("nonisolated static func unlockedSinceHint()", in: watcher), "_ = CredentialVaultStore.shared.load()"), true,
                    "钥匙串(契约): 解锁监视在后台查锁、读保险箱,主线程只重载")

        let login = app("Settings/LoginItemManager.swift")
        expectEqual(appCodeOccurrences(of: "SMAppService.mainApp.status").allSatisfy { $0 == "lyrimuse/Settings/LoginItemManager.swift" }
                    && !sourceHas(login, "var status: SMAppService.Status"), true,
                    "登录项(契约): 系统状态只在 LoginItemManager 里问,不再有同步的 status 属性")
        for signature in ["func refreshStatus(", "func setEnabled(_ enabled: Bool)", "func syncAtLaunch(decide:"] {
            expectEqual(sourceHas(sourceBody(signature, in: login), "Self.queue.async {"), true, "登录项(契约): \(signature) 在后台队列上问系统")
        }
        expectEqual(sourceHas(app("MenuBar/MenuBarStatusMenu.swift"), "LoginItemManager.shared.refreshStatus { settings.syncLaunchAtLoginFromSystem() }"), true,
                    "登录项(契约): 开菜单用上次结论、后台对账")
        let settingsView = app("SettingsView.swift")
        expectEqual(sourceHas(sourceBody("private func refreshLoginItemState()", in: settingsView), "LoginItemManager.shared.refreshStatus {"), true,
                    "登录项(契约): 设置页两件事用同一次后台问到的结论")

        expectEqual(sourceHas(settingsView, ".disabled(!ICloudConfigStore.isAvailable"), false,
                    "iCloud(契约): 按钮的可用性读 @State,不在 body 里 stat")
        expectEqual(sourceHas(delegate, "Task.detached(priority: .utility) { ICloudConfigStore.ensureFolderIconIfPresent() }"), true,
                    "iCloud(契约): 启动时贴文件夹图标在后台")
        expectEqual(sourceHas(sourceBody("private func refreshEngineFolderFindings()", in: settingsView),
                              "await Task.detached(priority: .utility) { HomeFolderAccess.check() }.value"), true,
                    "目录检查(契约): 设置页心跳里的 HomeFolderAccess 在后台查")
        let luma = app("UI/DesktopWallpaperLuma.swift")
        expectEqual(sourceHas(sourceBody("static func luma(for screen: NSScreen?)", in: luma), "desktopImageURL"), false,
                    "壁纸亮度(契约): 壁纸地址也走 5 秒缓存")

        let didFinish = sourceBody("func applicationDidFinishLaunching(_ notification: Notification)", in: delegate)
        let watchdog = didFinish.range(of: "MainThreadWatchdog.shared.start()")?.lowerBound
        let loginSync = didFinish.range(of: "LoginItemManager.shared.syncAtLaunch")?.lowerBound
        let icon = didFinish.range(of: "ensureFolderIconIfPresent")?.lowerBound
        expectEqual(watchdog != nil && loginSync != nil && icon != nil && watchdog! < loginSync! && watchdog! < icon!, true,
                    "看门狗(契约): 启动的头一件就开始探测")
    }

    do {
        print("\n== 异常守卫 ==")
        let layout = DisplayCycleLimit.reasonPrefix + "Layout Window pass, but it has already had more Layout Window passes than there are views in the window."
        expectEqual([SwallowedExceptionGuard.shouldRecord(reason: "boom", inTask: true),
                     SwallowedExceptionGuard.shouldRecord(reason: "boom", inTask: false),
                     SwallowedExceptionGuard.shouldRecord(reason: nil, inTask: true),
                     SwallowedExceptionGuard.shouldRecord(reason: layout, inTask: true)],
                    [true, false, true, false], "异常守卫: 只记任务里抛的、不是布局超限的")
        let install = sourceBody("public static func install()", in: core("Diagnostics/SwallowedExceptionGuard.swift"))
        expectEqual(sourceHas(install, "SwallowedExceptionGuard.shouldRecord(reason: exception.reason, inTask: withUnsafeCurrentTask { $0 != nil })"), true,
                    "异常守卫(契约): 预处理器按 shouldRecord 记")
        expectEqual(sourceHas(install, "CFRunLoopActivity.entry.rawValue | CFRunLoopActivity.beforeWaiting.rawValue"), true,
                    "异常守卫(契约): 进入 run loop 时也查(主队列一直有待办时不休眠)")
        let hotkeys = app("Settings/GlobalHotkeys.swift")
        expectEqual(sourceHas(sourceBody("private static func pauseWhileMenuTracking()", in: hotkeys), "MainActor.assumeIsolated"), false,
                    "全局快捷键(契约): 菜单通知回调不直接 assumeIsolated")
        expectEqual(sourceHas(sourceBody("nonisolated static func onMainThread(", in: hotkeys), "if Thread.isMainThread {"), true,
                    "全局快捷键(契约): 先判主线程,不在就派回主队列")
    }

    do {
        print("\n== 运行环境:App 所在卷被卸载、最低系统版本 ==")
        expectEqual([AppLocation.watchesVolume(at: "/"), AppLocation.watchesVolume(at: "/Volumes/Lyrimuse"),
                     AppLocation.watchesVolume(at: "/Volumes/Lyrimuse/")], [false, true, true], "卷卸载: 根卷不盯,别的卷盯")
        let volume = URL(fileURLWithPath: "/Volumes/Lyrimuse")
        expectEqual([AppLocation.isSameVolume(URL(fileURLWithPath: "/Volumes/Lyrimuse/"), volume),
                     AppLocation.isSameVolume(URL(fileURLWithPath: "/Volumes/Lyrimuse 1"), volume),
                     AppLocation.isSameVolume(nil, volume)], [true, false, false], "卷卸载: 按挂载点认是不是 App 所在的卷")
        let prompt = app("Settings/AppLocationPrompt.swift")
        expectEqual(sourceCount(sourceBody("@MainActor static func runAtLaunch()", in: prompt),
                                "AppVolumeUnmountWatcher.start(bundle: bundle, onUnmount: quitForUnmount)"), 2,
                    "卷卸载(契约): 不问、问了没移走两条路都开始盯")
        expectEqual(sourceHas(sourceBody("enum AppVolumeUnmountWatcher", in: prompt), "forName: NSWorkspace.willUnmountNotification"), true,
                    "卷卸载(契约): 盯的是 willUnmount(真卸之前)")
        let quit = sourceBody("@MainActor private static func quitForUnmount()", in: prompt)
        expectEqual(sourceHas(quit, "await EngineServiceManager.stopForMaintenance()") && sourceHas(quit, "AppExit.request(.appVolumeUnmounting)"), true,
                    "卷卸载(契约): 停引擎再走正常退出")

        let build = repoText("lyrimuse/build.sh")
        expectEqual(sourceHas(build, "clang -dynamiclib -fobjc-arc -O2 -arch \"$arch\" -mmacosx-version-min=14.0"), true,
                    "最低系统版本(契约): nowplaying-clients 的 dylib 按 14.0 编")
        let package = repoText("lyrimuse/package.sh")
        expectEqual(sourceHas(package, "../scripts/check-release-binaries.sh \"$app\""), true,
                    "发版闸门(契约): 打包前查弱导入与 minos")
        expectEqual(sourceHas(package, "LYRIMUSE_MEDIA_CONTROL_PREFIX=\"$(./scripts/fetch-media-control.sh arm64_sonoma \"$STAGE/media-control\")\""), true,
                    "发版闸门(契约): 本机打包也取钉住的 arm64_sonoma bottle,不用本机 brew 那份")
        let fetch = repoText("lyrimuse/scripts/fetch-media-control.sh")
        expectEqual(sourceHas(repoText(".github/workflows/release.yml"), "bash lyrimuse/scripts/fetch-media-control.sh arm64_sonoma")
                        && sourceHas(build, "./scripts/fetch-media-control.sh \"$MC_TAG\"")
                        && !build.contains("media-control/blobs/sha256")
                        && sourceHas(fetch, "arm64_sonoma) sha=") && sourceHas(fetch, "sonoma) sha="), true,
                    "发版闸门(契约): media-control 的版本与 bottle sha256 只钉在 fetch-media-control.sh")
        expectEqual(sourceHas(fetch, "if [ \"$got\" != \"$sha\" ]; then"), true,
                    "发版闸门(契约): 下载的 bottle 校验 sha256,不符拒绝")
        let gate = repoText("scripts/check-release-binaries.sh")
        expectEqual(["\"QuartzCore/_CADynamicRangeHigh\"", "\"AppKit/_OBJC_CLASS_\\$_NSGlassEffectView\"",
                     "\"AppKit/_OBJC_METACLASS_\\$_NSGlassEffectView\"", "\"CoreAudio/_AudioHardwareCreateProcessTap\"",
                     "\"CoreAudio/_AudioHardwareDestroyProcessTap\"", "Contents/Resources/nowplaying-clients/libnowplaying-clients.dylib"]
                        .allSatisfy { gate.contains($0) }, true,
                    "发版闸门(契约): 弱导入白名单(含音浪的 process tap)、minos 查到 dylib")
        expectEqual(sourceHas(repoText("scripts/commit-checks.sh"),
                              "scripts/check-release-binaries.sh --weak-imports \"$(cd lyrimuse && swift build --show-bin-path)/lyrimuse\""), true,
                    "发版闸门(契约): 提交校验编完就查弱导入白名单,不等打包")
        let minos = sourceBody("check_minos() {", in: gate)
        expectEqual(sourceHas(minos, "if ! build=\"$(vtool -show-build \"$file\" 2>&1)\"; then") && sourceHas(minos, "if [ -z \"$minos_list\" ]; then")
                        && !minos.contains("< <(vtool"), true,
                    "发版闸门(契约): vtool 读不出或没有 minos 算不过,不放进进程替换里吞掉")
        expectEqual(["MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter\"", "lib/media-control/MediaRemoteAdapterTestClient\"",
                     "for rel in \"${own_binaries[@]}\" \"${bundled_binaries[@]}\"; do"].allSatisfy { gate.contains($0) }
                        && !gate.contains("warn-only") && !package.contains("warn-only"), true,
                    "发版闸门(契约): minos 查到 media-control 的两个 Mach-O,超了一律拒绝")
    }

    do {
        print("\n== 主线程 I/O:触控栏判 ControlStrip 只问内核进程表 ==")
        let me = getpid()
        let myPath = ControlStripProcess.executablePath(of: me) ?? ""
        expectEqual(myPath.isEmpty, false, "ControlStrip 进程: 读得到自己的可执行文件路径")
        expectEqual(ControlStripProcess.executablePath(of: -1), nil, "ControlStrip 进程: 不合法的进程号读不到路径")
        // selftest 的可执行文件名比内核留的进程名长:按路径最后一段截到 16 字节才挑得出候选。
        let comm = String(decoding: (myPath as NSString).lastPathComponent.utf8.prefix(16), as: UTF8.self)
        expectEqual(ControlStripProcess.pids(command: comm)?.contains(me), true, "ControlStrip 进程: 按进程名在内核表里找到自己")
        expectEqual(ControlStripProcess.probe(executablePath: myPath, known: me), .running(me), "ControlStrip 进程: 认得上次的进程号")
        let viaScan = ControlStripProcess.probe(executablePath: myPath, known: nil)
        if case let .running(pid) = viaScan {
            expectEqual(ControlStripProcess.executablePath(of: pid), myPath, "ControlStrip 进程: 没有上次的进程号时翻表找到同一个可执行文件")
        } else {
            expectEqual(String(describing: viaScan), "running", "ControlStrip 进程: 没有上次的进程号时翻表找到")
        }
        if case let .running(pid) = ControlStripProcess.probe(executablePath: myPath, known: 1) {
            expectEqual(ControlStripProcess.executablePath(of: pid), myPath, "ControlStrip 进程: 上次的进程号换了人就翻表")
        } else {
            expectEqual(false, true, "ControlStrip 进程: 上次的进程号换了人就翻表")
        }
        expectEqual(ControlStripProcess.probe(executablePath: "/nonexistent/\(UUID().uuidString)/ControlStrip", known: me), .notRunning,
                    "ControlStrip 进程: 没有这个可执行文件的进程就是没在跑")
        expectEqual(ControlStripProcess.executablePath, "/System/Library/CoreServices/ControlStrip.app/Contents/MacOS/ControlStrip",
                    "ControlStrip 进程: 认的是系统那一份")

        let availability = app("TouchBar/TouchBarAvailability.swift")
        expectEqual(sourceHas(availability, "runningApplications.contains") || sourceHas(availability, ".bundleIdentifier")
                        || sourceHas(availability, "NSRunningApplication"), false,
                    "触控栏判定(契约): 不读运行中 App 表里的属性(每读一次同步问 launchservicesd)")
        expectEqual(sourceHas(sourceBody("func start()", in: availability),
                              "NSWorkspace.shared.observe(\\.runningApplications) { _, _ in\nDispatchQueue.main.async { TouchBarAvailability.shared.probeControlStrip() }"),
                    true, "触控栏判定(契约): 运行中 App 表一变只派一次后台查")
        let probe = sourceBody("private func probeControlStrip()", in: availability)
        expectEqual(sourceHas(probe, "probes.start(read: { ControlStripProcess.probe(known: known) }")
                        && sourceHas(probe, "if !issued { probeAgain = true }")
                        && sourceHas(sourceBody("private func controlStripProbed(", in: availability),
                                     "if probeAgain {\nprobeAgain = false\nprobeControlStrip()"), true,
                    "触控栏判定(契约): 内核进程表在后台查、一次一个,派不出去的那次等回来再补查")
        expectEqual(sourceHas(sourceBody("private func controlStripProbed(", in: availability), "case .unknown:\nreturn"), true,
                    "触控栏判定(契约): 进程表读不出来时沿用上一次的结论")
    }

    do {
        print("\n== 主线程 I/O:按 bundle id 找进程先用记下的进程号,装没装只问登记位置 ==")
        let me = getpid()
        let fake = "me.yudaotor.selftest.process-cache.\(me)"
        expectEqual(PlayerProcess.pid(exactBundleID: fake), nil, "进程缓存: 没记过、LaunchServices 也不认的 bundle id 找不到")
        PlayerProcess.remember(me, bundleID: fake)
        expectEqual(PlayerProcess.pid(exactBundleID: fake), me, "进程缓存: 记下的进程还活着、路径没变就直接用,不问 LaunchServices")
        expectEqual(PlayerProcess.isRunning(bundleID: fake, includingAliases: false, excludingPID: me), false,
                    "进程缓存: 要剔掉的正是记下的那个就不算")
        expectEqual(PlayerProcess.pid(exactBundleID: fake), nil, "进程缓存: 剔掉过的记录随之忘掉")
        let myPath = ControlStripProcess.executablePath(of: me) ?? ""
        let entry = (pid: me, path: myPath)
        expectEqual([PlayerProcess.verifiedPID(entry, excludingPID: nil, executablePath: { _ in myPath }),
                     PlayerProcess.verifiedPID(entry, excludingPID: nil, executablePath: { _ in "/elsewhere/other" }),
                     PlayerProcess.verifiedPID(entry, excludingPID: nil, executablePath: { _ in nil }),
                     PlayerProcess.verifiedPID(entry, excludingPID: me, executablePath: { _ in myPath })],
                    [me, nil, nil, nil], "进程缓存: 路径对得上才用;进程号换了程序、进程不在、要剔掉的都不用")
        let process = core("Local/PlayerProcess.swift")
        expectEqual(sourceHas(sourceBody("private static func firstPID(", in: process),
                              "for id in ids {\nif let pid = knownPID(bundleID: id, excludingPID: gone) { return pid }\nlet apps = NSRunningApplication.runningApplications(withBundleIdentifier: id)"),
                    true, "进程缓存(契约): 先核记下的进程号,对不上才问 LaunchServices,本体优先的次序不变")

        let note = Notification(name: NSWorkspace.didLaunchApplicationNotification, object: nil,
                                userInfo: ["NSApplicationBundleIdentifier": "com.example.player", "NSApplicationProcessIdentifier": NSNumber(value: 4321)])
        expectEqual([WorkspaceAppNote.bundleID(note), WorkspaceAppNote.pid(note).map(String.init)], ["com.example.player", "4321"],
                    "起停通知: bundle id、进程号读通知自带的字段")
        if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            let bare = Notification(name: NSWorkspace.didLaunchApplicationNotification, object: nil,
                                    userInfo: [NSWorkspace.applicationUserInfoKey: dock])
            expectEqual([WorkspaceAppNote.bundleID(bare), WorkspaceAppNote.pid(bare).map(String.init)],
                        ["com.apple.dock", String(dock.processIdentifier)], "起停通知: 没带字段时退回 NSRunningApplication")
        }
        let quitWatcher = sourceBody("func start()", in: app("Settings/PlayerQuitWatcher.swift"))
        let centerLyrics = sourceBody("private func start()", in: app("MenuBar/MenuBarCenterLyrics.swift"))
        let discord = sourceBody("nonisolated private static func isDiscordDesktop(", in: app("Settings/DiscordPresenceController.swift"))
        expectEqual([quitWatcher, centerLyrics, discord].map { sourceHas($0, "as? NSRunningApplication") },
                    [false, false, false], "起停通知(契约): 跟随退出、菜单栏居中歌词、Discord 不读通知里 NSRunningApplication 的属性")
        expectEqual(sourceHas(quitWatcher, "WorkspaceAppNote.bundleID(note)") && sourceHas(centerLyrics, "WorkspaceAppNote.pid(note)")
                        && sourceHas(discord, "WorkspaceAppNote.bundleID(notification)"), true, "起停通知(契约): 三处都走 WorkspaceAppNote")

        let aliases = core("Local/PlayerBundleAliases.swift")
        let installed = sourceBody("public static func isInstalled(", in: aliases)
        expectEqual(sourceHas(installed, "urlForApplication(withBundleIdentifier:") && !sourceHas(installed, "applicationURL(")
                        && !sourceHas(installed, "runningApplications"), true,
                    "装没装(契约): 只问登记位置,不先翻在跑的那份")
        expectEqual(sourceHas(sourceBody("public static func installedPlayers()", in: core("Local/PlayerPickerLayout.swift")),
                              "PlayerBundleAliases.isInstalled(player)"), true, "装没装(契约): 选播放器网格走同一个判断")
        expectEqual(PlayerBundleAliases.isInstalled(.appleMusic), true, "装没装: 系统自带的 Apple Music 算装了")
        expectEqual(sourceHas(sourceBody("public static func automationBundleID(", in: aliases),
                              "guard ids.count > 1 else { return player.bundleIdentifier }"), true,
                    "自动化对象(契约): 没有别的版本时不问在不在跑、装没装")
        expectEqual(PlayerBundleAliases.automationBundleID(for: .spotify), PlaybackPlayer.spotify.bundleIdentifier,
                    "自动化对象: 只有本体的就是本体")

        expectEqual(sourceHas(app("Settings/PlayerHealthMonitor.swift"), "nonisolated static func automationMissing("), true,
                    "设置侧栏健康(契约): 每拍的自动化查询(挑版本、判在跑)不在主线程上跑")
        let browser = sourceBody("private func refreshBrowserLiveStatus()", in: app("SettingsView.swift"))
        expectEqual(sourceHas(browser, "Task.detached(priority: .utility)") && sourceHas(browser, "running: MusicAutomationPermission.isRunning(bundleID: id),")
                        && !sourceHas(browser, "let running = Dictionary("), true,
                    "浏览器实时状态(契约): 判在不在跑挪进后台那一段")
        let pear = sourceBody("public func canControl()", in: core("Local/PearDesktopAPI.swift"))
        expectEqual(sourceHas(pear, "PlayerProcess.pid(exactBundleID: PlaybackPlayer.pearDesktop.bundleIdentifier)")
                        && sourceHas(pear, "now - last.at < Self.runningCheckTTL") && !sourceHas(pear, "runningApplications"), true,
                    "Pear 能不能控制(契约): 判开着走进程缓存、结论记一会儿,榜单每行重画不再问 LaunchServices")
    }

    do {
        print("\n== 嵌套事件循环:模态框不起在主队列块和主 actor 的 Task 里 ==")
        /// 就地转一段嵌套 run loop(同 `runModal` 的模态循环),返回这期间主队列上另投的块有没有跑到。
        func nestedLoopDrainsMainQueue() -> Bool {
            var ran = false
            DispatchQueue.main.async { ran = true }
            let end = Date().addingTimeInterval(0.1)
            while !ran, Date() < end { _ = RunLoop.main.run(mode: .default, before: end) }
            return ran
        }
        final class Box: @unchecked Sendable { var direct: Bool?; var viaNextTurn: Bool?; var viaRun: Bool?; var result: Int? }
        let box = Box()
        DispatchQueue.main.async {
            box.direct = nestedLoopDrainsMainQueue()
            NestedLoopLaunch.nextTurn { box.viaNextTurn = nestedLoopDrainsMainQueue() }
        }
        spin(until: { box.viaNextTurn != nil })
        expectEqual(box.direct, false, "嵌套循环(对照): 直接起在主队列块里,开着期间主队列停摆")
        expectEqual(box.viaNextTurn, true, "嵌套循环: 主队列块里交给 NestedLoopLaunch.nextTurn,起的时候主队列照常执行")
        Task { @MainActor in
            box.result = await NestedLoopLaunch.run { () -> Int in
                box.viaRun = nestedLoopDrainsMainQueue()
                return 7
            }
        }
        spin(until: { box.result != nil })
        expectEqual(box.viaRun, true, "嵌套循环: 主 actor 的 Task 里 await NestedLoopLaunch.run,起的时候主队列照常执行")
        expectEqual(box.result, 7, "嵌套循环: NestedLoopLaunch.run 交回 body 的返回值")

        let glassMenu = sourceBody("struct SettingsGlassMenuEntries: View", in: app("Settings/SettingsDesignSystem.swift"))
        expectEqual(sourceHas(glassMenu, "dismiss() NestedLoopLaunch.nextTurn(action)") && !sourceHas(glassMenu, "DispatchQueue.main"), true,
                    "玻璃浮层菜单(契约): 动作的下一拍走 NestedLoopLaunch,不走主队列块(「从应用程序中选择…」「更换备份文件夹…」都从这里弹面板)")
        let pendingImport = sourceBody("private func takePendingImport()", in: app("LyricsManager/LyricsSearchSheet.swift"))
        expectEqual(sourceHas(pendingImport, "NestedLoopLaunch.nextTurn { chooseImportFiles() }") && !sourceHas(pendingImport, "DispatchQueue.main"), true,
                    "搜索歌词取走导入请求(契约): 选文件面板的下一拍走 NestedLoopLaunch")
        let conflict = sourceBody("static func present(_ kind: Kind, over window: NSWindow?)", in: app("Settings/ShortcutConflict.swift"))
        expectEqual(sourceHas(conflict, "NestedLoopLaunch.nextTurn {") && !sourceHas(conflict, "DispatchQueue.main"), true,
                    "快捷键冲突提示(契约): 没有窗口时的 runModal 不起在主队列块里")
        expectEqual(sourceHas(app("Settings/ICloudConfigImportPrompt.swift"), "private static func showNotice(_ text: String) async {"), true,
                    "iCloud 导入提示(契约): 导入后的说明框在 Task 里 await 着弹")

        // 全仓扫:主队列块、主 actor 的 Task 里不许直接 runModal(交给 NestedLoopLaunch 的那一段不算)。只认直接写在块里的,
        // 块里调的函数再 runModal 的(玻璃菜单、取走导入请求)由上面几条钉住。
        /// 从 `index` 起、同一行上第一个 `{` 到配对的 `}`;那一行上没有 `{`(`async(execute: work)` 这种)返回 nil。
        func closureBody(after index: String.Index, in text: String) -> Range<String.Index>? {
            guard let open = text[index...].firstIndex(where: { $0 == "{" || $0 == "\n" }), text[open] == "{" else { return nil }
            var depth = 0
            var i = open
            while i < text.endIndex {
                if text[i] == "{" { depth += 1 } else if text[i] == "}" {
                    depth -= 1
                    if depth == 0 { return open..<text.index(after: i) }
                }
                i = text.index(after: i)
            }
            return nil
        }
        func blankingLaunchedBlocks(_ body: String) -> String {
            var text = body
            var from = text.startIndex
            while let hit = text.range(of: "NestedLoopLaunch.", range: from..<text.endIndex) {
                guard let block = closureBody(after: hit.upperBound, in: text) else {
                    from = hit.upperBound
                    continue
                }
                let offset = text.distance(from: text.startIndex, to: hit.upperBound)
                text.replaceSubrange(block, with: "{}")
                from = text.index(text.startIndex, offsetBy: offset)
            }
            return text
        }
        let openers = ["DispatchQueue.main.async", "OperationQueue.main.addOperation", "Task {", "Task(priority:"]
        var modalInQueueBlock: [String] = []
        var scannedRunModal = 0
        let appRoot = sources.appendingPathComponent("lyrimuse")
        for case let rel as String in FileManager.default.enumerator(atPath: appRoot.path) ?? FileManager.DirectoryEnumerator()
        where rel.hasSuffix(".swift") {
            guard let raw = try? String(contentsOfFile: appRoot.appendingPathComponent(rel).path, encoding: .utf8),
                  sourceBytes(raw, contain: ".runModal()") else { continue }
            let code = raw.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String($0) }
                .joined(separator: "\n")
            scannedRunModal += code.components(separatedBy: ".runModal()").count - 1
            for opener in openers {
                var from = code.startIndex
                while let hit = code.range(of: opener, range: from..<code.endIndex) {
                    from = hit.upperBound
                    guard let block = closureBody(after: hit.lowerBound, in: code) else { continue }
                    if blankingLaunchedBlocks(String(code[block])).contains(".runModal()") {
                        let line = code[..<hit.lowerBound].filter { $0 == "\n" }.count + 1
                        modalInQueueBlock.append("\(rel):\(line) \(opener)")
                    }
                }
            }
        }
        expectEqual(scannedRunModal >= 20, true, "嵌套循环(契约): 扫到了 App 里的 runModal(\(scannedRunModal) 处)")
        expectEqual(modalInQueueBlock, [], "嵌套循环(契约): 主队列块 / Task 里没有直接起的 runModal")
    }

    do {
        print("\n== 主线程 I/O:CoreAudio 不在主线程上调(15 章决策 113) ==")
        let calls = ["AudioObjectGetPropertyData(", "AudioObjectSetPropertyData(", "AudioObjectHasProperty(",
                     "AudioObjectIsPropertySettable(", "AudioObjectAddPropertyListenerBlock(", "AudioObjectRemovePropertyListenerBlock("]
        func callCount(_ text: String) -> Int { calls.reduce(0) { $0 + sourceCount(text, $1) } }
        let onQueue = "dispatchPrecondition(condition: .onQueue(queue))"

        let volume = app("Settings/VolumeMonitor.swift")
        expectEqual(callCount(sourceBody("final class VolumeMonitor {", in: volume)), 0,
                    "系统音量(契约): 主线程那一侧(VolumeMonitor)不直接调 CoreAudio")
        let ioFuncs = ["static func adjust(by delta: Float, at now: Date) {", "static func read() -> State {",
                       "static func set(volume value: Float) {", "static func set(muted: Bool) {",
                       "private static func setMuted(_ muted: Bool, on device: AudioObjectID) {",
                       "static func defaultOutputDevice() -> AudioObjectID? {",
                       "static func volumeAddress(for device: AudioObjectID) -> AudioObjectPropertyAddress? {",
                       "static func muteAddress(for device: AudioObjectID) -> AudioObjectPropertyAddress? {",
                       "private func startOnQueue(onChange: @escaping (Float, Bool) -> Void) {", "private func stopOnQueue() {",
                       "private func rebindToDefaultDevice() {", "private func detachVolumeListener() {",
                       "private func handleVolumeChanged() {", "private func readVolume() -> Float? {", "private func readMuted() -> Bool? {"]
        let ioBodies = ioFuncs.map { sourceBody($0, in: volume) }
        expectEqual(ioFuncs.filter { !sourceHas(sourceBody($0, in: volume), onQueue) }, [],
                    "系统音量(契约): 碰 CoreAudio 的函数开头都断言在音量队列上")
        expectEqual(ioBodies.reduce(0) { $0 + callCount($1) }, callCount(volume),
                    "系统音量(契约): 文件里每一处 CoreAudio 调用都落在这些带队列断言的函数里")
        expectEqual([sourceHas(sourceBody("static func adjustSystemVolume(by delta: Float) {", in: volume),
                               "let at = Date()\nSystemVolumeIO.queue.async { SystemVolumeIO.adjust(by: delta, at: at) }"),
                     sourceHas(sourceBody("static func readSystemVolume(", in: volume),
                               "SystemVolumeIO.queue.async {\nlet state = SystemVolumeIO.read()\nDispatchQueue.main.async { MainActor.assumeIsolated { completion(state) } }"),
                     sourceHas(sourceBody("static func setSystemVolume(_ value: Float) {", in: volume),
                               "SystemVolumeIO.queue.async { SystemVolumeIO.set(volume: value) }"),
                     sourceHas(sourceBody("static func setSystemMuted(_ muted: Bool) {", in: volume),
                               "SystemVolumeIO.queue.async { SystemVolumeIO.set(muted: muted) }")],
                    [true, true, true, true],
                    "系统音量(契约): 调、读、设、静音都排到同一条串行队列上,调用时刻在主线程上取(一次滑动的累加按它判)")
        expectEqual(sourceHas(sourceBody("private func startListening() {", in: volume),
                              "DispatchQueue.main.async {\nMainActor.assumeIsolated { self?.deliver(volume: volume, muted: muted) }"), true,
                    "系统音量(契约): 监听读到变化后只带结果回主线程")
        let panel = app("MenuBar/MenuBarPanelVolume.swift")
        expectEqual([sourceHas(sourceBody("func refresh() {", in: panel),
                               "VolumeMonitor.readSystemVolume { [weak self] state in\nguard let self, generation == self.readGeneration else { return }"),
                     sourceHas(sourceBody("func set(_ value: Float) {", in: panel), "readGeneration += 1\nVolumeMonitor.setSystemVolume(value)"),
                     sourceHas(sourceBody("func toggleMute() {", in: panel), "readGeneration += 1\nVolumeMonitor.setSystemMuted(!muted)")],
                    [true, true, true], "面板音量格(契约): 读回来才更新;自己写了之后,写之前派出的那次读不盖掉刚写的值")
        expectEqual(appCodeOccurrences(of: "SystemVolumeIO.read()"), ["lyrimuse/Settings/VolumeMonitor.swift"],
                    "系统音量(契约): 只有排在队列上的那一处读")

        let audio = app("AudioOutputDevices.swift")
        let outputInit = sourceBody("private init() {", in: audio)
        expectEqual(sourceHas(outputInit, "Self.queue.async { [weak self] in") && sourceHas(outputInit, "&addr, Self.queue, listener)")
                        && sourceHas(outputInit, "self?.readAndPublish()"), true,
                    "输出设备(契约): 挂监听、第一次读都在输出设备队列上,监听回调也派到那条队列")
        expectEqual(sourceHas(sourceBody("nonisolated private func readAndPublish(", in: audio),
                              "dispatchPrecondition(condition: .onQueue(Self.queue))\nlet list = AudioOutputDeviceManager.outputDevices()"), true,
                    "输出设备(契约): 枚举设备只在队列上")
        expectEqual(sourceHas(audio, "func select(_ id: AudioDeviceID, completion: @escaping @MainActor (Bool) -> Void = { _ in }) {\n"
                                  + "Self.queue.async { [weak self] in\nlet ok = AudioOutputDeviceManager.setDefaultOutput(id)"), true,
                    "输出设备(契约): 切默认输出在队列上,结论回主线程交")
        expectEqual(["AudioOutputDeviceManager.outputDevices()", "AudioOutputDeviceManager.defaultOutputDeviceID()",
                     "AudioOutputDeviceManager.setDefaultOutput("].map(appCodeOccurrences(of:)),
                    Array(repeating: ["lyrimuse/AudioOutputDevices.swift"], count: 3),
                    "输出设备(契约): 枚举、读默认输出、切默认输出各只有队列上那一处")
        expectEqual(sourceHas(sourceBody("private func publish(", in: audio),
                              "if current != defaultID { defaultID = current }\nif external != isExternal { isExternal = external }\nloaded = true")
                        && sourceHas(audio, "guard monitor.loaded, let id, let device = monitor.devices.first(where: { $0.id == id }) else { return }"),
                    true, "输出设备横幅(契约): 第一次读完的那次发布还没 loaded,不当成换了设备")

        let route = core("Local/AudioOutputRoute.swift")
        let observe = sourceBody("public static func startObserving(", in: route)
        expectEqual(sourceHas(observe, "observeQueue.async {") && sourceHas(observe, "&addr, observeQueue) { _, _ in\nonChange(current())")
                        && !sourceHas(observe, "DispatchQueue.main"), true,
                    "输出链路(契约): 挂监听、变化后读新设备都在后台队列上,读好的设备交给回调")
        let playback = core("Local/LocalPlaybackSource.swift")
        expectEqual(sourceHas(playback, "AudioOutputRoute.startObserving { [weak self] route in\nDispatchQueue.main.async { MainActor.assumeIsolated { self?.outputRouteChanged(to: route) } }")
                        && !sourceHas(sourceBody("private func outputRouteChanged(to route: AudioOutputRoute.Current?) {", in: playback), "outputRoute()"),
                    true, "输出链路(契约): 换了设备时主线程只拿读好的设备,不自己再问 CoreAudio")

        // 全仓的 CoreAudio 属性监听都不派到主队列上。
        var registrations: [String] = []
        for dir in ["lyrimuse", "LyrimuseCore"] {
            let base = sources.appendingPathComponent(dir)
            for case let rel as String in FileManager.default.enumerator(atPath: base.path) ?? FileManager.DirectoryEnumerator()
            where rel.hasSuffix(".swift") {
                guard let text = try? String(contentsOf: base.appendingPathComponent(rel), encoding: .utf8),
                      sourceBytes(text, contain: "AudioObjectAddPropertyListenerBlock(") else { continue }
                var rest = Substring(text)
                while let hit = rest.range(of: "AudioObjectAddPropertyListenerBlock(") {
                    let tail = rest[hit.upperBound...]
                    let end = [tail.range(of: ")\n")?.lowerBound, tail.range(of: ") {")?.lowerBound].compactMap { $0 }.min() ?? tail.endIndex
                    registrations.append("\(dir)/\(rel): \(tail[..<end])")
                    rest = tail
                }
            }
        }
        expectEqual(registrations.count >= 4, true, "CoreAudio 监听(契约): 扫到了全仓的监听注册")
        expectEqual(registrations.filter { $0.contains(".main") }, [],
                    "CoreAudio 监听(契约): 没有派到主队列上的属性监听(回调里同步读 CoreAudio 会卡住主线程)")
    }

    do {
        print("\n== 主线程 I/O:灵动岛自家图标在后台读(05 章决策 154) ==")
        let icon = app("UI/NotchIdleAppIcon.swift")
        let own = sourceBody("final class NotchOwnAppIcon: ObservableObject {", in: icon)
        expectEqual(sourceHas(own, "read.start(priority: .userInitiated, read: {\nAppIconResolver.bundledOwnIcon().flatMap { NotchIdleAppIcon.rasterize($0, pixelSide: pixelSide) }")
                        && sourceHas(own, "if let image { self?.bitmaps[pixelSide] = image }"), true,
                    "灵动岛自家图标(契约): 包里的图标在后台读、光栅化,回主线程才放进缓存")
        expectEqual(sourceHas(sourceBody("func bitmap(pixelSide: Int) -> CGImage? {", in: own),
                              "if let hit = bitmaps[pixelSide] { return hit }\nguard pixelSide > 0, reads[pixelSide] == nil else { return nil }"), true,
                    "灵动岛自家图标(契约): 每个像素边长只派一次后台读,读不出来不反复派")
        expectEqual(sourceHas(sourceBody("nonisolated static func bundledOwnIcon() -> NSImage? {", in: app("Settings/AppIconResolver.swift")),
                              "Bundle.main.url(forResource: \"AppIcon\", withExtension: \"icns\")")
                        && sourceHas(repoText("lyrimuse/build.sh"), "cp AppIcon.icns \"$APP_DIR/Contents/Resources/AppIcon.icns\""), true,
                    "灵动岛自家图标(契约): 读的是 build.sh 拷进包里的那份 AppIcon.icns")
        expectEqual(sourceHas(sourceBody("func idleAppIcon(alignment: Alignment) -> some View {", in: app("UI/NotchLyricsView+TopRow.swift")),
                              "NotchOwnAppIconImage(pixelSide: Int((side * scale).rounded()), scale: scale)"), true,
                    "灵动岛自家图标(契约): 没有曲目时左耳那枚走后台读的图标")
    }

    do {
        print("\n== 主线程 I/O:App 图标全走后台读的缓存(14 章决策 211) ==")
        let resolverFile = app("Settings/AppIconResolver.swift")
        let cache = sourceBody("final class AppIconCache: ObservableObject {", in: resolverFile)
        // 取图标的两个系统接口:进程里第一次取、按没画过的尺寸第一次画,都要同步等 iconservicesagent。
        expectEqual(appCodeOccurrences(of: "applicationIconImage") + appCodeOccurrences(of: "applicationIconName"), [],
                    "App 图标(契约): App 代码里不再读 NSApplication.applicationIconImage / NSImage.applicationIconName")
        expectEqual(appCodeOccurrences(of: "icon(forFile:"), ["lyrimuse/Settings/AppIconResolver.swift"],
                    "App 图标(契约): NSWorkspace.icon(forFile:) 只在 AppIconResolver 里取")
        let installed = sourceBody("nonisolated static func loadInstalledIcon(bundleID: String) -> NSImage? {", in: resolverFile)
        expectEqual(sourceHas(installed, "rasterizedRepresentations(of: NSWorkspace.shared.icon(forFile: url.path), maxPixels: 256)"), true,
                    "App 图标(契约): 系统给的图标在读它的那条后台线程上逐张画成位图,主线程画它不再找 iconservicesagent")
        expectEqual(sourceHas(sourceBody("static func icon(forBundleID bundleID: String) -> NSImage? {", in: resolverFile),
                              "AppIconCache.shared.icon(forBundleID: bundleID)")
                        && !sourceHas(sourceBody("static func icon(forBundleID bundleID: String) -> NSImage? {", in: resolverFile), "NSWorkspace"), true,
                    "App 图标(契约): AppIconResolver.icon(forBundleID:) 只读缓存")
        expectEqual(sourceHas(sourceBody("private func load(_ bundleID: String, priority: Operation.QueuePriority) {", in: cache),
                              "enqueue(key: bundleID, priority: priority, read: { AppIconResolver.loadInstalledIcon(bundleID: bundleID) }) { cache, image in\ncache.stage(bundleID, image)"), true,
                    "App 图标(契约): 播放器图标在后台读,回主线程才放进缓存")
        let stage = sourceBody("private func stage(_ bundleID: String, _ image: NSImage?) {", in: cache)
        expectEqual(sourceHas(stage, "stagedIcons[bundleID] = image") && !sourceHas(stage, "icons[bundleID] = image")
                        && sourceHas(stage, "guard !flushScheduled else { return }")
                        && sourceHas(stage, "DispatchQueue.main.asyncAfter(deadline: .now() + Self.publishDelay)"), true,
                    "App 图标(契约): 陆续读好的攒一会儿合成一次发布(每发布一次观察它的大页整页重算)")
        let publish = sourceBody("private func publishStaged() {", in: cache)
        expectEqual(sourceHas(publish, "guard !stagedIcons.isEmpty else {\nobjectWillChange.send()\nreturn\n}")
                        && sourceHas(publish, "icons.merge(stagedIcons) { _, staged in staged }"), true,
                    "App 图标(契约): 只判出没装的那一批也发布一次(不然那一格一直画着占位图)")
        expectEqual(sourceHas(sourceBody("func lookup(bundleID: String) -> Lookup {", in: cache),
                              "if let hit = icons[bundleID] ?? stagedIcons[bundleID] { return .ready(hit) }"), true,
                    "App 图标(契约): 攒着还没发布的也算读好了,不重派")
        expectEqual(sourceHas(sourceBody("private func loadOwnIcon(priority: Operation.QueuePriority) {", in: cache),
                              "enqueue(key: Self.ownKey, priority: priority, read: {\nAppIconResolver.bundledOwnIcon().map { AppIconResolver.rasterizedRepresentations(of: $0, maxPixels: 512) }"), true,
                    "App 图标(契约): Lyrimuse 自己的图标从包里的 icns 在后台读")
        let enqueue = sourceBody("private func enqueue(key: String, priority: Operation.QueuePriority,", in: cache)
        expectEqual(sourceHas(enqueue, "let operation = BlockOperation {\nlet image = LoadedIcon(image: read())\nDispatchQueue.main.async {")
                        && sourceHas(enqueue, "Self.loadQueue.addOperation(operation)")
                        && sourceHas(cache, "queue.maxConcurrentOperationCount = 2")
                        && !sourceHas(cache, "Task.detached") && !sourceHas(cache, "SingleFlightBackgroundRead"), true,
                    "App 图标(契约): 在自己最多 2 个并发的队列上读,不占 Swift 并发的协作线程(同步等 iconservicesagent 会把它们占满)")
        let ownGetter = sourceBody("var ownIcon: NSImage {", in: cache)
        expectEqual(sourceHas(ownGetter, "if let own { return own }\nloadOwnIcon(priority: .veryHigh)\nreturn Self.pendingPlaceholder"), true,
                    "App 图标(契约): 自家图标还没读好时给占位,不在主线程上现读")
        expectEqual(sourceHas(sourceBody("struct LyrimuseAppIconImage: View {", in: resolverFile),
                              "@ObservedObject private var cache = AppIconCache.shared"), true,
                    "App 图标(契约): 画自家图标的视图观察缓存,读好时重画")
        expectEqual(appCodeOccurrences(of: "LyrimuseAppIconImage()").count, 11,
                    "App 图标(契约): 引导、设置、新功能介绍、分享图、Discord 与通知预览那 11 处自家图标走缓存")
        expectEqual(sourceHas(sourceBody("static func bitmap(of source: NSImage, cacheKey: String, pixelSide: Int) -> CGImage? {",
                                         in: app("UI/NotchIdleAppIcon.swift")),
                              "guard pixelSide > 0, source !== AppIconCache.pendingPlaceholder else { return nil }"), true,
                    "App 图标(契约): 灵动岛的位图缓存不收占位图(收了读好之后也一直是空的)")
        expectEqual(sourceHas(app("AppDelegate.swift"),
                              "let bundleIDs = AppIconCache.prefetchBundleIDs()\nawait AppIconCache.shared.prefetch(bundleIDs: bundleIDs)"), true,
                    "App 图标(契约): 启动后在后台预热")
        // 读图标的视图都要观察缓存:后台读好时不重画,那一格会一直空着。
        let observe = "@ObservedObject private var appIcons = AppIconCache.shared"
        let readers: [(file: String, type: String)] = [
            ("OnboardingView.swift", "struct OnboardingView: View {"),
            ("SettingsView.swift", "private struct LyricsSettingsTab: View {"),
            ("SettingsView.swift", "private struct PlayerSettingsTab: View {"),
            ("LyricsManager/SongVersionsSheet.swift", "struct SongVersionsSheet: View {"),
            ("Settings/PlayerLinkageRow.swift", "private struct TrustedPlayerIconView: View {"),
            ("Settings/PlayerChoiceCard.swift", "struct PlayerIconView: View {"),
            ("Settings/DiscordPresencePreview.swift", "struct DiscordPresencePreview: View {"),
            ("MenuBar/MenuBarPanel.swift", "private struct MenuBarPanelView: View {"),
            ("MenuBar/MenuBarPanelIdleCard.swift", "struct PanelIdleNowPlaying<Transport: View, Action: View>: View {"),
            ("UI/MiniIdleStandby.swift", "struct MiniIdleStandby: View {"),
            ("UI/NotchEarExtras.swift", "struct NotchEarPlayerIcon: View {"),
            ("UI/NotchLyricsView.swift", "struct NotchIdleEarIconHost<Fallback: View>: View {"),
            ("UI/LyricShareWindow.swift", "struct LyricShareWindow: View {"),
        ]
        for reader in readers {
            expectEqual(sourceHas(sourceBody(reader.type, in: app(reader.file)), observe), true,
                        "App 图标(契约): \(reader.type) 观察 AppIconCache")
        }
        let readerFiles = Set(readers.map { "lyrimuse/" + $0.file })
        let callers = Set(appCodeOccurrences(of: "AppIconResolver.icon(forBundleID:") + appCodeOccurrences(of: ".resolvedPlayerIcon")
                          + appCodeOccurrences(of: "discordApplicationIcon(model"))
        expectEqual(callers.subtracting(readerFiles).sorted(), ["lyrimuse/PlaybackCoordinator.swift"],
                    "App 图标(契约): 取播放器图标的视图都在上面的观察名单里")
    }

    do {
        print("\n== 主线程 I/O:字体选单的系统字体列表在后台读(04 章决策 105) ==")
        // 行为:Core Text 在后台读的那份跟 NSFontManager 的逐项一致(族名、顺序、本地化名)。
        final class Box: @unchecked Sendable { var snapshot: SystemFontFamilies.Snapshot?; var onMain: Bool? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.onMain = Thread.isMainThread
            box.snapshot = SystemFontFamilies.read()
            done.signal()
        }
        done.wait()
        let manager = NSFontManager.shared
        let families = manager.availableFontFamilies.filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var localized: [String: String] = [:]
        for family in families {
            let name = manager.localizedName(forFamily: family, face: nil)
            if name != family { localized[family] = name }
        }
        expectEqual(box.onMain, false, "字体选单: 列表在后台线程上读")
        expectEqual(box.snapshot?.families.contains("Helvetica"), true, "字体选单: 读到系统字体")
        expectEqual(box.snapshot?.families, families, "字体选单: 族名和顺序跟 NSFontManager.availableFontFamilies 一致")
        expectEqual(box.snapshot?.localizedNames, localized, "字体选单: 本地化名跟 NSFontManager.localizedName(forFamily:) 一致")

        // 契约:App 代码里不在主线程上列字体族、取本地化名。
        expectEqual(appCodeOccurrences(of: "availableFontFamilies") + appCodeOccurrences(of: "localizedName(forFamily:")
                        + appCodeOccurrences(of: "CTFontDescriptorCopyLocalizedAttribute("), ["LyrimuseCore/Local/SystemFontFamilies.swift"],
                    "字体选单(契约): 列字体族、取本地化名只在 SystemFontFamilies 里")
        expectEqual(appCodeOccurrences(of: "SystemFontFamilies.read()"), ["lyrimuse/UI/FontFamilyPicker.swift"],
                    "字体选单(契约): 只有字体选单读系统字体列表")
        let pickerFile = app("UI/FontFamilyPicker.swift")
        let load = sourceBody("func load() {", in: sourceBody("final class FontFamilyCatalog: ObservableObject {", in: pickerFile))
        expectEqual(sourceHas(load, "guard snapshot == nil, !loading else { return }\nloading = true")
                        && sourceHas(load, "DispatchQueue.global(qos: .userInitiated).async {\nlet snapshot = SystemFontFamilies.read()\nDispatchQueue.main.async {")
                        && sourceHas(load, "catalog.snapshot = snapshot") && sourceCount(load, "catalog.snapshot =") == 1, true,
                    "字体选单(契约): 在后台读一次,读好回主线程整份发布")
        expectEqual(sourceHas(sourceBody("struct FontFamilyPicker: View {", in: pickerFile), ".onAppear { catalog.load() }"), true,
                    "字体选单(契约): 按钮出现就开始读")
        expectEqual(sourceHas(pickerFile, "private var systemFamilies: [String] { catalog.snapshot?.families ?? [selection] }"), true,
                    "字体选单(契约): 没读好时系统字体区只列选中的那款")
    }
}
