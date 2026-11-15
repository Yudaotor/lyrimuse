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
        expectEqual(sourceHas(repoText("lyrimuse/package.sh"), "../scripts/check-release-binaries.sh \"$app\""), true,
                    "发版闸门(契约): 打包前查弱导入与 minos")
        let gate = repoText("scripts/check-release-binaries.sh")
        expectEqual(["\"QuartzCore/_CADynamicRangeHigh\"", "\"AppKit/_OBJC_CLASS_\\$_NSGlassEffectView\"",
                     "\"AppKit/_OBJC_METACLASS_\\$_NSGlassEffectView\"", "Contents/Resources/nowplaying-clients/libnowplaying-clients.dylib"]
                        .allSatisfy { gate.contains($0) }, true,
                    "发版闸门(契约): 弱导入白名单只有这三个、minos 查到 dylib")
    }
}
