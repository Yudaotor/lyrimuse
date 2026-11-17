import Foundation
import LyrimuseCore

func runTelemetryTests() {
    do {
        print("\n== 遥测:日期、心跳判据、写法 ==")
        // 北京时间刚过零点、UTC 还是前一天:按本地日期算。
        let justAfterMidnight = Date(timeIntervalSince1970: 1_793_377_800)
        expectEqual(Telemetry.day(justAfterMidnight, timeZone: TimeZone(identifier: "Asia/Shanghai")!), "2026-10-31",
                    "日期: 按本地自然日")
        expectEqual(Telemetry.day(justAfterMidnight, timeZone: TimeZone(identifier: "UTC")!), "2026-10-30", "日期: 跟着时区走")
        expectEqual(Telemetry.heartbeatDue(today: "2026-10-31", lastSentDay: nil), true, "心跳: 从没发过要发")
        expectEqual(Telemetry.heartbeatDue(today: "2026-10-31", lastSentDay: "2026-10-30"), true, "心跳: 新的一天要发")
        expectEqual(Telemetry.heartbeatDue(today: "2026-10-31", lastSentDay: "2026-10-31"), false, "心跳: 今天发过不再发")

        expectEqual(Telemetry.playerTag(forBundleID: PlaybackPlayer.appleMusic.bundleIdentifier),
                    PlaybackPlayer.appleMusic.rawValue, "播放器: 内置的用目录 id")
        expectEqual(Telemetry.playerTag(forBundleID: "com.example.SomethingElse"), "other", "播放器: 别的 App 一律 other")
        expectEqual(Telemetry.playerTag(forBundleID: nil), nil, "播放器: 没有 bundle id 不记")
        expectEqual(Telemetry.playerTag(forBundleID: "com.colliderli.iina", trusted: ["com.colliderli.iina"]), "com.colliderli.iina",
                    "播放器: 信任的第三方 App 记 bundle id")
        expectEqual(Telemetry.playerTag(forBundleID: "com.colliderli.iina", trusted: []), "other", "播放器: 没信任的记 other")
        expectEqual(Telemetry.playerTag(forBundleID: PlaybackPlayer.appleMusic.bundleIdentifier,
                                        trusted: [PlaybackPlayer.appleMusic.bundleIdentifier]),
                    PlaybackPlayer.appleMusic.rawValue, "播放器: 内置的照旧用目录 id")
        expectEqual(Telemetry.playerTag(forBundleID: "weird id/with space", trusted: ["weird id/with space"]), "other",
                    "播放器: 不像 bundle id 的写法不发")
        func features(trusted: [String]) -> TelemetryFeatures {
            TelemetryFeatures(surfaces: [], playersSelected: [], lyricsSourceMode: "smart", lyricsSourcesEnabled: 1,
                              translation: false, romanization: false, machineTranslation: false, accounts: [],
                              trustedPlayers: trusted, webPlatforms: [], showInDock: false, launchAtLogin: false, betaUpdates: false)
        }
        expectEqual(features(trusted: ["com.b", "/Users/x/a.app", "com.a"]).trustedPlayers, ["com.a", "com.b"],
                    "信任列表: 只发 bundle id、排好序")
        let many = (0..<50).map { String(format: "com.app%02d", $0) }
        expectEqual(features(trusted: many.shuffled() + ["bad id"]).trustedPlayers, Array(many.prefix(TelemetryFeatures.maxTrustedPlayers)),
                    "信任列表: 先过滤排序再截,每次发的是同一批")

        expectEqual(TelemetryEnvironment.languageOnly("zh-Hans-CN"), "zh-Hans", "语言: 去掉地区、留文字")
        expectEqual(TelemetryEnvironment.languageOnly("en-US"), "en", "语言: 去掉地区")
        expectEqual(TelemetryEnvironment.languageOnly("ja"), "ja", "语言: 没地区原样")
        expectEqual(TelemetryEnvironment.regionCode("CN"), "CN", "地区: 两字母原样")
        expectEqual(TelemetryEnvironment.regionCode("tw"), "TW", "地区: 转大写")
        expectEqual([TelemetryEnvironment.regionCode("001"), TelemetryEnvironment.regionCode("419"),
                     TelemetryEnvironment.regionCode(""), TelemetryEnvironment.regionCode(nil),
                     TelemetryEnvironment.regionCode("USA")], [nil, nil, nil, nil, nil], "地区: 数字区域码和非两字母不发")
        expectEqual(TelemetryEnvironment.osVersionString(OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)),
                    "26.1", "系统版本: 补丁号为 0 不写")
        expectEqual(TelemetryEnvironment.osVersionString(OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 1)),
                    "15.6.1", "系统版本: 带补丁号")

        expectEqual(Telemetry.redactPaths("Library missing: /Users/alice/Library/Frameworks/X.framework/X (no such file)"),
                    "Library missing: <path> (no such file)", "脱敏: 绝对路径换掉")
        expectEqual(Telemetry.redactPaths("Referenced from: '~/Applications/Lyrimuse.app/Contents/MacOS/lyrimuse'"),
                    "Referenced from: '<path>'", "脱敏: ~ 开头的路径换掉")
        expectEqual(Telemetry.redactPaths("EXC_BAD_ACCESS / KERN_INVALID_ADDRESS at 0x0"),
                    "EXC_BAD_ACCESS / KERN_INVALID_ADDRESS at 0x0", "脱敏: 孤立的斜杠不动")
        expectEqual(Telemetry.redactPaths("Namespace SIGNAL, Code 11 Segmentation fault: 11"),
                    "Namespace SIGNAL, Code 11 Segmentation fault: 11", "脱敏: 没路径原样")
        expectEqual(Telemetry.redactPaths("swift/Array.swift"), "swift/Array.swift", "脱敏: 相对路径不当成绝对路径")
        expectEqual(Telemetry.redactPaths("Library not loaded: /Applications/Lyrimuse 2.app/Contents/MacOS/lyrimuse"),
                    "Library not loaded: <path>", "脱敏: 路径里带空格也整段换掉")
        expectEqual(Telemetry.redactPaths("Referenced from: '/Users/alice/My Apps/Lyrimuse.app/Contents/MacOS/lyrimuse'"),
                    "Referenced from: '<path>'", "脱敏: 引号里的路径整段换掉")
        expectEqual(Telemetry.redactPaths("tried: '/Users/a b/x.dylib' (no such file), \"/usr/lib/y.dylib\" (not found)"),
                    "tried: '<path>' (no such file), \"<path>\" (not found)", "脱敏: 一行几个带引号的路径各换各的")
        expectEqual([Telemetry.crashDay("2026-10-31 12:00:00.00 +0800"), Telemetry.crashDay(nil), Telemetry.crashDay("garbage")],
                    ["2026-10-31", nil, nil], "崩溃时间: 只留日期")
    }

    do {
        print("\n== 遥测:崩溃摘要 ==")
        var summary = CrashReportSummary(fileName: "lyrimuse-2026-10-31-120000.ips")
        summary.processName = "lyrimuse"
        summary.processPath = "/Users/alice/Applications/Lyrimuse.app/Contents/MacOS/lyrimuse"
        summary.version = "1.9.0"
        summary.osVersion = "macOS 26.1 (25B78)"
        summary.timestamp = "2026-10-31 12:00:00.00 +0800"
        summary.exceptionType = "EXC_BAD_ACCESS"
        summary.exceptionSignal = "SIGSEGV"
        summary.terminationIndicator = "Library missing"
        summary.terminationReasons = ["Library not loaded: /Users/alice/x.dylib", "a", "b", "c"]
        summary.frames = (0..<20).map { (i: Int) in
            CrashReportSummary.Frame(imageName: "lyrimuse", symbol: "f\(i)", imageOffset: i,
                                     sourceFile: "/Users/alice/src/Foo.swift", sourceLine: 10)
        }
        let env = TelemetryEnvironment(appVersion: "1.9.0", build: "1.9.0.1000", osVersion: "26.1", arch: "arm64",
                                       uiLanguage: "zh-hans", systemLanguage: "zh-Hans")
        let id = Telemetry.reportID(fileName: summary.fileName)
        expectEqual(id.count, 16, "去重键: 16 位十六进制")
        expectEqual(id == Telemetry.reportID(fileName: summary.fileName), true, "去重键: 同一文件名同一个键")
        let crash = TelemetryCrash(summary: summary, reportID: id, executableName: "lyrimuse", installID: "i", env: env)
        expectEqual(crash.process, "app", "进程: App 本体")
        expectEqual(crash.occurredAt, "2026-10-31", "崩溃负载: 时间只发到哪一天,不带时分秒和时区")
        expectEqual(crash.terminationReasons, ["Library not loaded: <path>", "a", "b"], "终止原因: 脱敏、最多三条")
        expectEqual(crash.frames.count, Telemetry.maxCrashFrames, "帧: 截到上限")
        expectEqual(crash.frames.first, TelemetryCrash.Frame(image: "lyrimuse", symbol: "f0", offset: 0), "帧: 只带镜像、符号、偏移")
        expectEqual(crash.exceptionFrames, [], "异常调用栈: 报告里没有就是空")
        var thrown = summary
        thrown.exceptionFrames = (0..<20).map { (i: Int) in
            CrashReportSummary.Frame(imageName: "/Users/alice/x/AppKit", symbol: "e\(i)", imageOffset: i,
                                     sourceFile: "/Users/alice/src/Bar.swift", sourceLine: 3)
        }
        let withException = TelemetryCrash(summary: thrown, reportID: id, executableName: "lyrimuse", installID: "i", env: env)
        expectEqual(withException.exceptionFrames.count, Telemetry.maxCrashFrames, "异常调用栈: 截到上限")
        expectEqual(withException.exceptionFrames.first, TelemetryCrash.Frame(image: "<path>", symbol: "e0", offset: 0),
                    "异常调用栈: 镜像脱敏,不带源码文件")
        var deep = thrown
        deep.exceptionLaterOwnFrames = [CrashReportSummary.Frame(imageName: "lyrimuse", symbol: nil, imageOffset: 777),
                                        CrashReportSummary.Frame(imageName: "lyrimuse", symbol: nil, imageOffset: 888)]
        let deepCrash = TelemetryCrash(summary: deep, reportID: id, executableName: "lyrimuse", installID: "i", env: env)
        expectEqual(deepCrash.exceptionFrames.map { $0.symbol ?? "lyrimuse+\($0.offset ?? -1)" },
                    (0..<10).map { "e\($0)" } + ["lyrimuse+777", "lyrimuse+888"],
                    "异常调用栈: 前面全是系统帧时,末尾换成后面最近的自家帧,总数不变")
        var ownInHead = deep
        ownInHead.exceptionFrames[3] = CrashReportSummary.Frame(imageName: "lyrimuse", symbol: nil, imageOffset: 5)
        expectEqual(TelemetryCrash(summary: ownInHead, reportID: id, executableName: "lyrimuse", installID: "i", env: env).exceptionFrames
                        .map(\.offset), Array(ownInHead.exceptionFrames.prefix(Telemetry.maxCrashFrames)).map(\.imageOffset),
                    "异常调用栈: 前面已经有自家帧就照原样截")
        let exceptionJSON = (try? JSONEncoder().encode(withException)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        expectEqual(exceptionJSON.contains("\"exception_frames\""), true, "异常调用栈: 键名 exception_frames")
        expectEqual(exceptionJSON.contains("alice") || exceptionJSON.contains("Bar.swift"), false, "异常调用栈: 不带路径、源码文件")
        var huge = summary
        huge.terminationReasons = [String(repeating: "x", count: 5000)]
        huge.frames = [CrashReportSummary.Frame(imageName: "lyrimuse", symbol: String(repeating: "S", count: 5000), imageOffset: 1)]
        let clipped = TelemetryCrash(summary: huge, reportID: id, executableName: "lyrimuse", installID: "i", env: env)
        expectEqual(clipped.terminationReasons.first?.count, Telemetry.crashReasonLimit, "崩溃负载: 终止原因截到上限")
        expectEqual(clipped.frames.first?.symbol?.count, Telemetry.crashSymbolLimit, "崩溃负载: 符号截到上限")
        let json = (try? JSONEncoder().encode(crash)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        expectEqual(json.contains("/Users") || json.contains("alice") || json.contains("Foo.swift"), false,
                    "崩溃负载: 不带路径、用户名、源码文件")
        expectEqual(json.contains(summary.fileName), false, "崩溃负载: 不带报告文件名")
        var engine = summary
        engine.processName = "lyrimuse-engine"
        expectEqual(TelemetryCrash(summary: engine, reportID: id, executableName: "lyrimuse", installID: "i", env: env).process,
                    "engine", "进程: 引擎")
    }

    do {
        print("\n== 遥测:每日活动记账 ==")
        // 用本进程自己的偏好域、带 pid 的键:另开 suite 会在 ~/Library/Preferences 留下一个文件。
        let key = "selftest.telemetryActivity.\(getpid())"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let activity = TelemetryActivity(defaults: .standard, key: key)
        let day1 = Date(timeIntervalSince1970: 1_793_300_000)
        let day2 = day1.addingTimeInterval(86_400)
        let music = PlaybackPlayer.appleMusic.bundleIdentifier
        activity.notePlayer(bundleID: music, now: day1)
        activity.noteHang(now: day1)
        expectEqual(activity.completedDays(before: "9999-12-31"), [], "关着时什么都不记")
        activity.isRecording = true
        activity.notePlayer(bundleID: music, now: day1)
        activity.notePlayer(bundleID: "com.example.Other", now: day1)
        activity.trustedBundleIDs = ["com.colliderli.iina"]
        activity.notePlayer(bundleID: "com.colliderli.iina", now: day1)
        activity.notePlayer(bundleID: music, now: day1)
        activity.noteHang(now: day1)
        activity.noteHang(now: day1)
        activity.notePlayer(bundleID: music, now: day2)
        let d1 = Telemetry.day(day1), d2 = Telemetry.day(day2)
        expectEqual(activity.completedDays(before: d2),
                    [TelemetryActivityDay(day: d1, playersPlayed: [PlaybackPlayer.appleMusic.rawValue, "other", "com.colliderli.iina"].sorted(), hangs: 2)],
                    "记账: 当天放过的播放器去重、卡顿计数")
        expectEqual(activity.completedDays(before: d1), [], "记账: 今天的不算完成")
        activity.remove(days: [d1])
        expectEqual(activity.completedDays(before: "9999-12-31").map(\.day), [d2], "记账: 发过的那天删掉")
        for i in 2..<7 { activity.noteHang(now: day1.addingTimeInterval(Double(i) * 86_400)) }
        expectEqual(activity.completedDays(before: "9999-12-31").count, TelemetryActivity.maxStoredDays, "记账: 最多留几天")
        activity.clear()
        expectEqual(activity.completedDays(before: "9999-12-31"), [], "记账: 关掉遥测时清空")

        activity.isRecording = false
        activity.noteAction(.shareCard, now: day1)
        expectEqual(activity.completedDays(before: "9999-12-31"), [], "动作: 关着时不记")
        activity.isRecording = true
        activity.noteAction(.offsetAdjusted, now: day1)
        activity.noteAction(.offsetAdjusted, now: day1)
        activity.noteAction(.lyricsWindow, now: day1)
        expectEqual(activity.completedDays(before: d2).first?.actions, ["offset_adjusted": 2, "lyrics_window": 1],
                    "动作: 按天各自计次,没做过的不写")
        activity.clear()
        let old = #"[{"day":"2026-10-30","players_played":["apple_music"],"hangs":1}]"#
        expectEqual((try? JSONDecoder().decode([TelemetryActivityDay].self, from: Data(old.utf8)))?.first,
                    TelemetryActivityDay(day: "2026-10-30", playersPlayed: ["apple_music"], hangs: 1),
                    "动作: 旧版本存下的活动(没有 actions)照样读得出")

        activity.isRecording = false
        activity.noteLyricsResult(track: "a", result: .word, source: "qq", language: .zh, now: day1)
        expectEqual(activity.completedDays(before: "9999-12-31"), [], "歌词结果: 关着时不记")
        activity.isRecording = true
        activity.noteLyricsResult(track: "a", result: .line, source: "netease", language: .zh, now: day1)
        activity.noteLyricsResult(track: "a", result: .line, source: "netease", language: .zh, now: day1)
        activity.noteLyricsResult(track: "b", result: .none, source: "kugou", language: nil, now: day1)
        activity.noteLyricsResult(track: "c", result: .word, source: "qq", language: .en, now: day1)
        var got = activity.completedDays(before: d2).first
        expectEqual(got?.lyrics, ["line": 1, "none": 1, "word": 1], "歌词结果: 同一首一天只算一次")
        expectEqual(got?.languages, ["zh": 1, "en": 1], "歌词结果: 没歌词的歌不记语言")
        expectEqual(got?.lyricSources, ["netease:line": 1, "qq:word": 1], "歌词来源: 按源和档计首数,没找到的不记源")
        activity.noteLyricsResult(track: "a", result: .word, source: "netease", language: .yue, now: day1)
        activity.noteLyricsResult(track: "b", result: .line, source: "kugou", language: .ja, now: day1)
        got = activity.completedDays(before: d2).first
        expectEqual(got?.lyrics, ["word": 2, "line": 1], "歌词结果: 结果变了挪到新的一档,不多算一首")
        expectEqual(got?.languages, ["yue": 1, "en": 1, "ja": 1], "歌词结果: 语言跟着挪")
        expectEqual(got?.lyricSources, ["netease:word": 1, "qq:word": 1, "kugou:line": 1], "歌词来源: 档变了跟着挪")
        activity.noteLyricsResult(track: "a", result: .word, source: "applemusic", language: .yue, now: day1)
        got = activity.completedDays(before: d2).first
        expectEqual(got?.lyrics, ["word": 2, "line": 1], "歌词来源: 只换了一份来源,档的首数不变")
        expectEqual(got?.lyricSources, ["applemusic:word": 1, "qq:word": 1, "kugou:line": 1], "歌词来源: 换了来源挪到新的源")
        activity.noteLyricsResult(track: "c", result: .instrumental, source: "qq", language: nil, now: day1)
        activity.noteLyricsResult(track: "d", result: .plain, source: "lrclib", language: .en, now: day1)
        activity.noteLyricsResult(track: "e", result: .line, source: "", language: .zh, now: day1)
        activity.noteLyricsResult(track: "f", result: .line, source: "musixmatch", language: .en, now: day1)
        activity.noteLyricsResult(track: "g", result: .line, source: TelemetryLyricSource.subtitles, language: .zh, now: day1)
        got = activity.completedDays(before: d2).first
        expectEqual(got?.lyricSources, ["applemusic:word": 1, "kugou:line": 1, "lrclib:plain": 1, "unknown:line": 1, "other:line": 1,
                                        "subtitles:line": 1],
                    "歌词来源: 纯音乐不记源、纯文本记一档、没记来源的记 unknown、认不出的记 other")
        expectEqual(got.map { $0.lyricSources.values.reduce(0, +) },
                    got.map { day in ["word", "line", "plain"].compactMap { day.lyrics[$0] }.reduce(0, +) },
                    "歌词来源: 各键之和等于逐字、逐行、纯文本三档之和")
        activity.noteLyricsResult(track: "a", result: .word, source: "netease", language: .yue, now: day2)
        expectEqual(activity.completedDays(before: "9999-12-31").last?.lyrics, ["word": 1], "歌词结果: 换天重新算")
        expectEqual(activity.completedDays(before: "9999-12-31").last?.lyricSources, ["netease:word": 1], "歌词来源: 换天重新算")
        activity.clear()
        activity.noteLyricsResult(track: "a", result: .word, source: "netease", language: .yue, now: day2)
        expectEqual(activity.completedDays(before: "9999-12-31").first?.lyrics, ["word": 1], "歌词结果: 清空后重新记")
        activity.clear()
        expectEqual([TelemetryLyricSource.tag(nil), TelemetryLyricSource.tag(""), TelemetryLyricSource.tag("qq"),
                     TelemetryLyricSource.tag("QQ")], ["unknown", "unknown", "qq", "other"], "歌词来源: 来源归一")
        expectEqual(TelemetryLyricsResult.allCases.map { TelemetryLyricSource.key(source: "qq", result: $0) },
                    ["qq:word", "qq:line", "qq:plain", nil, nil], "歌词来源: 纯音乐、没找到不出键")
        let oldDay = #"[{"day":"2026-11-15","lyrics":{"word":1},"languages":{"zh":1}}]"#
        expectEqual((try? JSONDecoder().decode([TelemetryActivityDay].self, from: Data(oldDay.utf8)))?.first?.lyricSources, [:],
                    "歌词来源: 旧版本存下的活动(没有 lyric_sources)照样读得出")
        expectEqual(LyricsKind.allCases.map { TelemetryLyricsResult($0).rawValue },
                    ["word", "line", "plain", "instrumental", "none"], "歌词结果: 跟 LyricsKind 一一对应")

        activity.isRecording = true
        activity.noteHang(now: day1)
        activity.waitForPendingWrites()
        expectEqual(TelemetryActivity(defaults: .standard, key: key).completedDays(before: "9999-12-31").map(\.hangs), [1],
                    "写盘: 写盘在后台队列,落地后新实例读得回")
        activity.clear()
        activity.waitForPendingWrites()
        expectEqual(UserDefaults.standard.data(forKey: key) == nil, true, "写盘: 清空也落到磁盘")
        let src = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LyrimuseCore/Telemetry/TelemetryActivity.swift"), encoding: .utf8)) ?? ""
        expectEqual(sourceCount(src, "defaults.set(") == 1 && sourceCount(src, "defaults.removeObject(") == 1
                    && sourceHas(sourceBody("private func store(", in: src), "writeQueue.async {"), true,
                    "写盘: 只在 writeQueue 里写 UserDefaults,不持锁写(持锁写会跟主线程互相等死)")
    }

    do {
        print("\n== 遥测:卡顿概况 ==")
        typealias H = TelemetryHang
        expectEqual([5.2, 9.9, 10, 29.9, 30, 400].map { H.durationBucket(seconds: $0) },
                    ["5-10s", "5-10s", "10-30s", "10-30s", "30s+", "30s+"], "分档: 卡了多久")
        expectEqual([0, 59, 60, 599, 600, 3599, 3600, 21_599, 21_600].map { H.elapsedBucket(seconds: $0) },
                    ["<1m", "<1m", "1-10m", "1-10m", "10-60m", "10-60m", "1-6h", "1-6h", "6h+"], "分档: 启动 / 唤醒后多久")
        expectEqual(Set(([5, 15, 60] as [TimeInterval]).map { H.durationBucket(seconds: $0) } + [H.unrecovered]), Set(H.durationBuckets),
                    "分档: 时长取值都在名单里")
        expectEqual([ProcessInfo.ThermalState.nominal, .fair, .serious, .critical].map(H.thermalTag), H.thermalStates, "温度状态")
        expectEqual(H.windowTags(identifiers: ["com_apple_SwiftUI_Settings_window", "lyrics-manager-AppWindow-1", "lyrics-window-AppWindow-1",
                                               "lyrics-window-AppWindow-2", "menubar-center-lyrics", "menubar-panel", ""]),
                    ["lyrics-manager", "lyrics-window", "menubar-panel", "settings"], "窗口: 按场景 id 认、去重排序,认不出的不报")
        expectEqual(H.windowTag(identifier: "x-menubar-panel-y"), nil, "窗口: 菜单栏面板只认 App 给的那个标签")

        let sample = """
        Analysis of sampling lyrimuse (pid 123) every 1 millisecond
        Call graph:
            1542 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
            + 1542 start  (in dyld) + 6688  [0x18204be88]
            +   1542 ???  (in lyrimuse)  load address 0x10022c000 + 0x8f9648  [0x100b25648]
            +     1542 -[NSApplication run]  (in AppKit) + 396  [0x186a8290c]
            +       1500 ???  (in lyrimuse)  load address 0x10022c000 + 0x1a2b  [0x10022da2b]
            +       ! 1500 ???  (in lyrimuse)  load address 0x10022c000 + 0x3c4d  [0x10022fc4d]
            +       !   1500 closure #1 in Foo.bar()  (in lyrimuse) + 24  [0x100230000]
            +       !     1500 _pthread_mutex_firstfit_lock_wait  (in libsystem_pthread.dylib) + 84  [0x1823aa3c0]
            +       !       1500 __psynch_mutexwait  (in libsystem_kernel.dylib) + 8  [0x18236c5e8]
            +       !       12 __psynch_cvwait  (in libsystem_kernel.dylib) + 8  [0x18236d000]
            +       42 ???  (in lyrimuse)  load address 0x10022c000 + 0x5e6f  [0x100231e6f]
            +         42 mach_msg2_trap  (in libsystem_kernel.dylib) + 8  [0x182365c34]
            1542 Thread_2   DispatchQueue_9: lyrimuse.playback.artwork  (serial)
            + 1542 start_wqthread  (in libsystem_pthread.dylib) + 8  [0x18239eb80]
        """
        let stack = H.mainThreadStack(fromSample: sample, executable: "lyrimuse")
        expectEqual(stack.map { $0.symbol ?? "+\($0.offset ?? -1)" },
                    ["__psynch_mutexwait", "_pthread_mutex_firstfit_lock_wait", "closure #1 in Foo.bar()", "+15437", "+6699", "+9410120"],
                    "采样: 走最重的那条路径,最深三帧接最深的三个自家帧,自家帧没符号时报偏移")
        expectEqual(stack.map(\.image), ["libsystem_kernel.dylib", "libsystem_pthread.dylib", "lyrimuse", "lyrimuse", "lyrimuse", "lyrimuse"],
                    "采样: 镜像名")
        expectEqual(H.mainThreadStack(fromSample: "no call graph here", executable: "lyrimuse"), [], "采样: 认不出格式时返回空")
        let nested = """
        Call graph:
            2000 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
            + 2000 start  (in dyld) + 6688  [0x18204be88]
            +   2000 ???  (in lyrimuse)  load address 0x10022c000 + 0x8f9648  [0x100b25648]
            +     2000 NSApplicationMain  (in AppKit) + 880  [0x186a5a000]
            +       2000 -[NSApplication run]  (in AppKit) + 396  [0x186a8290c]
            +         2000 -[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:]  (in AppKit) + 292  [0x18730726c]
            +           2000 _DPSNextEvent  (in AppKit) + 588  [0x187300000]
            +             2000 __CFRunLoopRun  (in CoreFoundation) + 1820  [0x1824e0000]
            +               2000 __CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__  (in CoreFoundation) + 16  [0x1824e1000]
            +                 2000 _dispatch_main_queue_callback_4CF  (in libdispatch.dylib) + 44  [0x1821e0000]
            +                   2000 ???  (in SwiftUI)  load address 0x1c0000000 + 0x123456  [0x1c0123456]
            +                     2000 -[NSMenu popUpMenuPositioningItem:atLocation:inView:appearance:]  (in AppKit) + 700  [0x186b00000]
            +                       2000 _NSMenuTrackingLoop  (in AppKit) + 120  [0x186b10000]
            +                         2000 _DPSNextEvent  (in AppKit) + 588  [0x187300000]
            +                           2000 __CFRunLoopRun  (in CoreFoundation) + 1820  [0x1824e0000]
            +                             2000 __CFRunLoopServiceMachPort  (in CoreFoundation) + 160  [0x1824e2000]
            +                               2000 mach_msg  (in libsystem_kernel.dylib) + 24  [0x182366000]
            +                                 2000 mach_msg_overwrite  (in libsystem_kernel.dylib) + 484  [0x182366100]
            +                                   2000 mach_msg2_internal  (in libsystem_kernel.dylib) + 76  [0x182366200]
            +                                     2000 mach_msg2_trap  (in libsystem_kernel.dylib) + 8  [0x182365c34]
        """
        expectEqual(H.mainThreadStack(fromSample: nested, executable: "lyrimuse").map { $0.symbol ?? "\($0.image ?? "")+\($0.offset ?? -1)" },
                    ["mach_msg2_trap", "mach_msg2_internal", "mach_msg_overwrite",
                     "_NSMenuTrackingLoop", "_dispatch_main_queue_callback_4CF", "lyrimuse+9410120"],
                    "采样: 自家帧只剩入口时,空名额给嵌套循环的线索帧(每类最深一帧:弹菜单、在主队列回调里),run loop 等事件那几层不占名额")
        let idle = nested.split(separator: "\n").filter { line in
            !["SERVICING", "_dispatch_main", "SwiftUI", "NSMenu", "_NSMenuTracking"].contains { line.contains($0) }
        }.joined(separator: "\n")
        expectEqual(H.mainThreadStack(fromSample: idle, executable: "lyrimuse").map { $0.symbol ?? "\($0.image ?? "")+\($0.offset ?? -1)" },
                    ["mach_msg2_trap", "mach_msg2_internal", "mach_msg_overwrite", "lyrimuse+9410120"],
                    "采样: 主线程就是在等事件时只剩入口,不硬凑系统帧")
        let viaQueue = nested.replacingOccurrences(of: "-[NSMenu popUpMenuPositioningItem:atLocation:inView:appearance:]", with: "-[NSAlert runModal]")
            .replacingOccurrences(of: "_NSMenuTrackingLoop", with: "-[NSApplication _doModalLoop:peek:]")
        expectEqual(H.mainThreadStack(fromSample: viaQueue, executable: "lyrimuse").dropFirst(3).compactMap(\.symbol),
                    ["-[NSApplication _doModalLoop:peek:]", "_dispatch_main_queue_callback_4CF"],
                    "采样: 弹窗的模态循环同样算线索帧,同一类只占一个名额")
        let noMain = sample.replacingOccurrences(of: "com.apple.main-thread", with: "x")
        expectEqual(H.mainThreadStack(fromSample: noMain, executable: "lyrimuse").first?.symbol, "__psynch_mutexwait",
                    "采样: 没标主线程时取第一个线程")

        var wake = WakeDetector()
        wake.observe(uptime: 100, continuous: 1000)
        wake.observe(uptime: 102, continuous: 1002.5)
        expectEqual(wake.lastWakeUptime, nil, "唤醒: 两边走得一样多不算睡过")
        wake.observe(uptime: 104, continuous: 1004.5 + WakeDetector.minimumSleep)
        expectEqual(wake.lastWakeUptime, 104, "唤醒: 含睡眠的时钟多走出一截,记这一刻为唤醒")

        let key = "selftest.telemetryHang.\(getpid())"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let activity = TelemetryActivity(defaults: .standard, key: key)
        let day1 = Date(timeIntervalSince1970: 1_793_300_000)
        let d2 = Telemetry.day(day1.addingTimeInterval(86_400))
        let base = H(sinceLaunch: "1-10m", sinceWake: nil, windows: ["settings"], thermal: "nominal")
        expectEqual(activity.noteHang(base, now: day1), false, "记账: 关着时不占概况名额(看门狗按冷却决定采不采)")
        activity.finishHang(seconds: 12)
        expectEqual(activity.completedDays(before: d2), [], "记账: 关着时不记概况")
        activity.isRecording = true
        activity.notePlayer(bundleID: PlaybackPlayer.spotify.bundleIdentifier, now: day1)
        expectEqual(activity.noteHang(base, now: day1), true, "记账: 当天第一次占到概况名额")
        var details = activity.completedDays(before: d2).first?.hangDetails ?? []
        expectEqual(details.map(\.duration), [H.unrecovered], "记账: 刚卡住记成没恢复")
        expectEqual(details.first?.player, PlaybackPlayer.spotify.rawValue, "记账: 播放器填最近放歌的那个")
        activity.attachHangStack([TelemetryCrash.Frame(image: "lyrimuse", symbol: nil, offset: 42)])
        activity.attachHangStack([TelemetryCrash.Frame(image: "lyrimuse", symbol: nil, offset: 7)])
        activity.finishHang(seconds: 12)
        details = activity.completedDays(before: d2).first?.hangDetails ?? []
        expectEqual(details.first?.duration, "10-30s", "记账: 恢复后补上时长")
        expectEqual(details.first?.stack.map(\.offset), [42], "记账: 调用栈只补第一份")
        expectEqual((0..<5).map { _ in activity.noteHang(base, now: day1) }, [true, true, false, false, false],
                    "记账: 名额只有每天前 3 次,之后不占")
        let got = activity.completedDays(before: d2).first
        expectEqual(got?.hangs, 6, "记账: 次数照记")
        expectEqual(got?.hangDetails.count, TelemetryActivity.maxHangDetailsPerDay, "记账: 概况每天最多记几条")
        activity.finishHang(seconds: 40)
        expectEqual(activity.completedDays(before: d2).first?.hangDetails.last?.duration, H.unrecovered,
                    "记账: 超出名额的那次恢复了不改前一条")
        expectEqual(activity.noteHang(nil, now: day1), false, "记账: 不带概况的不占名额")
        activity.finishHang(seconds: 40)
        expectEqual(activity.completedDays(before: d2).first?.hangDetails.map(\.duration), ["10-30s", H.unrecovered, H.unrecovered],
                    "记账: 不带概况的那次之后不补到旧的一条")
        activity.clear()
        activity.waitForPendingWrites()
        let encoded = try? JSONEncoder().encode(TelemetryActivityDay(day: "2026-11-09", hangs: 1, hangDetails: [base]))
        expectEqual(encoded.flatMap { try? JSONDecoder().decode(TelemetryActivityDay.self, from: $0) }?.hangDetails, [base],
                    "记账: 概况能存能读")
        let stored = TelemetryActivityDay(day: "2026-11-09", hangs: 3, throttledHangs: 2,
                                          hangDetails: [H(sinceLaunch: "1-6h", sinceWake: nil, windows: [], thermal: "nominal", throttled: [MainThreadThrottle.locked])])
        expectEqual((try? JSONEncoder().encode(stored)).flatMap { try? JSONDecoder().decode(TelemetryActivityDay.self, from: $0) }, stored,
                    "记账: 被压着的次数和标记能存能读")
        let old = #"{"day":"2026-10-30","players_played":[],"hangs":2}"#
        let oldDay = try? JSONDecoder().decode(TelemetryActivityDay.self, from: Data(old.utf8))
        expectEqual([oldDay?.hangDetails.count, oldDay?.throttledHangs], [0, 0], "记账: 旧版本存下的活动没有概况、没有被压着的次数")
        let oldHang = #"{"duration":"5-10s","since_launch":"<1m","windows":[],"thermal":"nominal","stack":[]}"#
        expectEqual((try? JSONDecoder().decode(H.self, from: Data(oldHang.utf8))).map { $0.throttled == nil }, true,
                    "记账: 旧版本存下的概况没有节流标记")

        // 被系统压着的卡顿(14 章决策 202):次数照记、另记一份;概况另占名额,不挤掉没被压着的。
        let throttleKey = "selftest.telemetryHangThrottle.\(getpid())"
        defer { UserDefaults.standard.removeObject(forKey: throttleKey) }
        let throttling = TelemetryActivity(defaults: .standard, key: throttleKey)
        throttling.isRecording = true
        let lockedHang = H(sinceLaunch: "1-6h", sinceWake: nil, windows: [], thermal: "nominal", throttled: [MainThreadThrottle.locked])
        expectEqual([throttling.noteHang(lockedHang, now: day1), throttling.noteHang(lockedHang, now: day1)], [true, false],
                    "节流记账: 被压着的每天另有名额")
        expectEqual((0..<4).map { _ in throttling.noteHang(base, now: day1) }, [true, true, true, false],
                    "节流记账: 被压着的不占没被压着的名额")
        var throttledDay = throttling.completedDays(before: d2).first
        expectEqual([throttledDay?.hangs, throttledDay?.throttledHangs], [6, 2], "节流记账: 次数照记,被压着的另记")
        expectEqual(throttledDay?.hangDetails.map { $0.throttled != nil }, [true, false, false, false], "节流记账: 概况各占各的名额")
        throttling.markHangThrottled([MainThreadThrottle.locked])
        throttledDay = throttling.completedDays(before: d2).first
        expectEqual([throttledDay?.throttledHangs, throttledDay?.hangDetails.filter { $0.throttled != nil }.count], [3, 1],
                    "节流记账: 没占到名额的那次后来被压着,只补次数")
        throttling.clear()
        throttling.noteHang(nil, now: day1)
        throttling.noteHang(base, now: day1)
        throttling.markHangThrottled([MainThreadThrottle.locked])
        throttling.markHangThrottled([MainThreadThrottle.locked, MainThreadThrottle.lowPriority])
        throttling.finishHang(seconds: 20)
        throttledDay = throttling.completedDays(before: d2).first
        expectEqual(throttledDay?.throttledHangs, 1, "节流记账: 卡住之后才被压着,补进次数只补一次")
        expectEqual(throttledDay?.hangDetails.first?.throttled, [MainThreadThrottle.locked, MainThreadThrottle.lowPriority],
                    "节流记账: 概况补上标记(并起来的全部)")
        expectEqual(throttledDay?.hangDetails.first?.duration, "10-30s", "节流记账: 补过标记之后恢复照样补时长")
        throttling.noteHang(nil, now: day1)
        throttling.markHangThrottled([MainThreadThrottle.locked])
        expectEqual(throttling.completedDays(before: d2).first?.throttledHangs, 2, "节流记账: 不带概况的那次后补次数,不碰旧的一条")
        throttling.clear()
        throttling.markHangThrottled([MainThreadThrottle.locked])
        expectEqual(throttling.completedDays(before: d2), [], "节流记账: 清空之后不凭空补出一天")
        _ = throttling.noteHang(lockedHang, now: day1)
        _ = throttling.noteHang(base, now: day1)
        throttling.markHangThrottled([MainThreadThrottle.locked])
        expectEqual((0..<3).map { _ in throttling.noteHang(base, now: day1) }, [true, true, false],
                    "节流记账: 后补成被压着的那条仍占着名额,两类合计不超过上限之和")
        expectEqual(throttling.completedDays(before: d2).first?.hangDetails.count,
                    TelemetryActivity.maxHangDetailsPerDay + TelemetryActivity.maxThrottledHangDetailsPerDay, "节流记账: 概况每天最多 3 + 1 条")
        throttling.clear()
        throttling.waitForPendingWrites()
    }

    do {
        print("\n== 遥测:歌曲语言 ==")
        typealias L = TelemetrySongLanguage
        expectEqual([L(script: .chinese, text: ""), L(script: .cantonese, text: ""), L(script: .japanese, text: ""),
                     L(script: .korean, text: ""), L(script: .russian, text: ""), L(script: .thai, text: "")],
                    [.zh, .yue, .ja, .ko, .ru, .th], "语言: 按整首文字种类分档")
        expectEqual(L(script: .unsupportedCyrillic, text: ""), .other, "语言: 认不出的西里尔字母算其他")
        expectEqual(L(script: .other, text: "I walk alone through the city lights tonight\nAnd I never want to go home again"), .en,
                    "语言: 拉丁字母的英语歌")
        expectEqual(L(script: .other, text: "Je ne regrette rien, ni le bien qu'on m'a fait\nNi le mal, tout ça m'est bien égal"), .fr,
                    "语言: 拉丁字母的法语歌")
        expectEqual(L(script: .other, text: "Despacito, quiero respirar tu cuello despacito\nDeja que te diga cosas al oído"), .es,
                    "语言: 拉丁字母的西班牙语歌")
        expectEqual(L(script: .other, text: "Nakupenda sana mpenzi wangu, siku zote nitakuwa nawe\nUsiku na mchana moyo wangu ni wako"), .other,
                    "语言: 系统不认识的语言没把握,算其他")
        expectEqual(L(script: .other, text: "Kimi no na wa nan desu ka\nSora ni kagayaku hoshi no you ni\nZutto soba ni ite hoshii"), .other,
                    "语言: 日语罗马字不算成印尼语")
        expectEqual(L(script: .arabic, text: ""), .ar, "语言: 阿拉伯字母只记文字种类")
        expectEqual(Set(TelemetrySongLanguage.recognized.values).isSubset(of: Set(TelemetrySongLanguage.allCases)), true,
                    "语言: 系统认的语言都在档里")
        let engine = LyricsSyncEngine()
        expectEqual(engine.telemetryLanguage, nil, "语言: 没歌词时不判")
        _ = engine.load(lyrics: "[00:00.00]作词 : Someone\n[00:01.00]作曲 : Someone\n[00:10.00]I walk alone through the city lights tonight\n[00:15.00]And I never want to go home again\n[00:20.00]Hold me close until the morning comes",
                        lyricsTr: "", lyricsRoma: "", lyricsYRC: "")
        expectEqual(engine.telemetryLanguage, .en, "语言: 英文歌开头的中文署名行不算")
        _ = engine.load(lyrics: "[00:10.00]海阔天空在勇敢以后\n[00:15.00]要拿执着将命运的锁打破", lyricsTr: "", lyricsRoma: "", lyricsYRC: "",
                        songIsCantonese: true)
        expectEqual(engine.telemetryLanguage, .yue, "语言: 粤语按引擎真值")
    }

    do {
        print("\n== 遥测:安装渠道、改过的设置、缺的权限 ==")
        expectEqual(Telemetry.installMethod(caskroomExists: true), "homebrew", "安装渠道: Caskroom 里有就是 Homebrew")
        expectEqual(Telemetry.installMethod(caskroomExists: false), "direct", "安装渠道: 其余记 direct")
        expectEqual(Telemetry.caskroomPaths.allSatisfy { $0.hasSuffix("/Caskroom/lyrimuse") }, true, "安装渠道: 两个 Homebrew 位置")
        let set1: Set<String> = ["b", "a", "c"], set2: Set<String> = ["c", "a", "b"]
        expectEqual(Telemetry.settingFingerprint(set1), Telemetry.settingFingerprint(set2), "设置比较: 集合按元素排序,顺序不影响")
        expectEqual(Telemetry.settingFingerprint(["y": 2, "x": 1]), Telemetry.settingFingerprint(["x": 1, "y": 2]),
                    "设置比较: 字典按键排序")
        expectEqual(Telemetry.settingFingerprint(Optional<Int>.none), "nil", "设置比较: 空的可选值")
        expectEqual(Telemetry.settingFingerprint(Optional(3)), "3", "设置比较: 可选值拆开")
        expectEqual(Telemetry.settingFingerprint(1.5), "1.5", "设置比较: 普通值原样")
        expectEqual(Telemetry.changedSettings(current: ["a": "1", "b": "2", "c": "3"], defaults: ["a": "1", "b": "9", "d": "4"]),
                    ["b"], "改过的设置: 只发跟默认不一样的,两边都有的才比")
        let many = Dictionary(uniqueKeysWithValues: (0..<300).map { (String(format: "k%03d", $0), "1") })
        let manyDefaults = many.mapValues { _ in "0" }
        expectEqual(Telemetry.changedSettings(current: many, defaults: manyDefaults),
                    Array(many.keys.sorted().prefix(Telemetry.maxChangedSettings)), "改过的设置: 排好序再截上限")
        expectEqual(Telemetry.permissionTag(.automation, .appleMusic), "automation.apple_music", "缺的权限: 种类.播放器")
        expectEqual(Telemetry.permissionTag(.fullDisk, .qqMusic), "full-disk." + PlaybackPlayer.qqMusic.rawValue, "缺的权限: 完全磁盘访问")
        let f = TelemetryFeatures(surfaces: [], playersSelected: [], lyricsSourceMode: "smart", lyricsSourcesEnabled: 1,
                                  translation: false, romanization: false, machineTranslation: false, accounts: [],
                                  trustedPlayers: [], webPlatforms: [], showInDock: false, launchAtLogin: false, betaUpdates: false,
                                  installMethod: "direct",
                                  settingsChanged: ["zeta", "alpha"], permissionsMissing: ["b.x", "a.x"])
        expectEqual(f.settingsChanged, ["alpha", "zeta"], "改过的设置: 排好序")
        expectEqual(f.permissionsMissing, ["a.x", "b.x"], "缺的权限: 排好序")
        let fJSON = (try? JSONEncoder().encode(f)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        expectEqual(fJSON.contains(#""install_method":"direct""#),
                    true, "负载: 安装渠道")
        let formats = TelemetryFeatures(surfaces: [], playersSelected: [], lyricsSourceMode: "smart", lyricsSourcesEnabled: 1,
                                        translation: false, romanization: false, machineTranslation: false, accounts: [],
                                        trustedPlayers: [], webPlatforms: [], showInDock: false, launchAtLogin: false, betaUpdates: false,
                                        lyricsWordFormats: ["ttml", "enhanced-lrc", "bogus", "ttml", "yrc"])
        expectEqual(formats.lyricsWordFormats, ["ttml", "enhanced-lrc", "yrc"], "逐字歌词格式: 保持设置里的顺序(第一个是主格式),去掉认不得的和重复的")
        expectEqual(LyricsWordFormat.allCases.map(\.rawValue).allSatisfy {
            TelemetryFeatures(surfaces: [], playersSelected: [], lyricsSourceMode: "smart", lyricsSourcesEnabled: 1,
                              translation: false, romanization: false, machineTranslation: false, accounts: [],
                              trustedPlayers: [], webPlatforms: [], showInDock: false, launchAtLogin: false, betaUpdates: false,
                              lyricsWordFormats: [$0]).lyricsWordFormats == [$0]
        }, true, "逐字歌词格式: 每种格式都发得出去")
        let formatsJSON = (try? JSONEncoder().encode(formats)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        expectEqual(formatsJSON.contains(#""lyrics_word_formats":["ttml","enhanced-lrc","yrc"]"#), true, "负载: 逐字歌词格式")
    }

    do {
        print("\n== 遥测:窗口布局轮数超限 ==")
        typealias D = DisplayCycleLimit
        // AppKit 原话(本机 macOS 27.0 复现里异常预处理器抓到的,窗口描述那行原样)。
        let real = "The window has been marked as needing another Update Constraints in Window pass, but it has already had more Update Constraints in Window passes than there are views in the window. \n<NSWindow: 0x77cad54280> 0x28856 (165974) {{200, 200}, {200, 132}} en"
        expectEqual(D.parse(reason: real), D.Event(pass: "update-constraints", windowClass: "NSWindow", windowNumber: 165974),
                    "超限: 认出 pass、窗口类名、窗口编号")
        let layout = "The window has been marked as needing another Layout pass, but it has already had 3 Layout passes. \n<SwiftUI.AppKitWindow: 0x1> 0x9 (9) {{0, 0}, {1, 1}} en"
        expectEqual(D.parse(reason: layout), D.Event(pass: "layout", windowClass: "SwiftUI.AppKitWindow", windowNumber: 9), "超限: 固定轮数那种写法、布局 pass")
        expectEqual(D.parse(reason: "The window has been marked as needing another Display pass, but … \n<lyri muse/../x\u{1F600}: 0x1>")?.windowClass,
                    "lyrimuse..x", "超限: 类名只留字母数字和 _ . $")
        expectEqual(D.parse(reason: "The window has been marked as needing another Foo pass, x")?.pass, "other", "超限: 认不出的 pass 归 other")
        expectEqual(D.parse(reason: "The window has been marked as needing another Foo pass, x")?.windowClass, "unknown", "超限: 没有窗口描述时类名 unknown")
        expectEqual(D.parse(reason: "*** -[__NSArrayM objectAtIndex:]: index 3 beyond bounds"), nil, "超限: 别的异常不认")
        expectEqual(Set(D.passes), ["update-constraints", "layout", "display", "other"], "超限: pass 取值名单")

        let key = "np:selftest.layout-limit.\(getpid())"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let activity = TelemetryActivity(defaults: .standard, key: key)
        let day1 = Date(timeIntervalSince1970: 1_793_300_000)
        let d2 = Telemetry.day(day1.addingTimeInterval(86_400))
        activity.noteLayoutLimit(window: "onboarding", windowClass: "SwiftUI.AppKitWindow", pass: "layout", now: day1)
        expectEqual(activity.completedDays(before: d2), [], "超限记账: 遥测关着不记")
        activity.isRecording = true
        for _ in 0..<3 { activity.noteLayoutLimit(window: "onboarding", windowClass: "SwiftUI.AppKitWindow", pass: "layout", now: day1) }
        activity.noteLayoutLimit(window: nil, windowClass: "NSPanel", pass: "update-constraints", now: day1)
        for i in 0..<10 { activity.noteLayoutLimit(window: nil, windowClass: "C\(i)", pass: "layout", now: day1) }
        let limits = activity.completedDays(before: d2).first?.layoutLimits ?? []
        expectEqual(limits.first, TelemetryLayoutLimit(window: "onboarding", windowClass: "SwiftUI.AppKitWindow", pass: "layout", count: 3),
                    "超限记账: 同一种只加次数")
        expectEqual(limits.count, TelemetryActivity.maxLayoutLimitsPerDay, "超限记账: 每天最多记几种")
        let writesBefore = activity.queuedWrites
        for _ in 0..<500 { activity.noteLayoutLimit(window: "onboarding", windowClass: "SwiftUI.AppKitWindow", pass: "layout", now: day1) }
        expectEqual(activity.queuedWrites - writesBefore, 0, "超限记账: 振荡时同一种只加次数,不每次写盘(攒着延后写)")
        expectEqual(activity.completedDays(before: d2).first?.layoutLimits.first?.count, 503, "超限记账: 延后写之前读到的次数也是新的")
        activity.waitForPendingWrites()
        let stored = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([TelemetryActivityDay].self, from: $0) }
        expectEqual(stored?.first?.layoutLimits.first?.count, 503, "超限记账: 延后的那次写盘带上攒下的次数")
        let json = (try? JSONEncoder().encode(limits.first)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        expectEqual(json.contains("\"class\":\"SwiftUI.AppKitWindow\"") && json.contains("\"window\":\"onboarding\""), true, "超限记账: 键名 class / window")
        let old = #"{"day":"2026-11-01","players_played":[],"hangs":0}"#
        expectEqual((try? JSONDecoder().decode(TelemetryActivityDay.self, from: Data(old.utf8)))?.layoutLimits, [],
                    "超限记账: 旧版本存下的活动没有这一项也读得出")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func text(_ rel: String) -> String { (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? "" }
        expectEqual(sourceHas(sourceBody("public static func install()", in: text("LyrimuseCore/Diagnostics/SwallowedExceptionGuard.swift")),
                              "DisplayCycleLimit.noteThrown(reason: exception.reason)"), true, "超限(契约): 异常预处理器把主线程异常交给它认")
        expectEqual(sourceHas(sourceBody("func applicationWillFinishLaunching(_ notification: Notification)", in: text("lyrimuse/AppDelegate.swift")),
                              "DisplayCycleLimit.onLimitReached = { event in"), true, "超限(契约): App 启动时接上记账")
    }

    do {
        print("\n== 遥测:全默认设置用的内存偏好 ==")
        // 同一串读写分别对真的临时域和内存偏好做一遍,按类型取回来的值要一样。
        let suite = "me.yudaotor.lyrimuse.selftest-in-memory-\(getpid())-\(UUID().uuidString)"
        let real = UserDefaults(suiteName: suite)!
        let prefsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        defer {
            // 清域只清内容、留下一个空 plist,同步之后连文件一起删。
            real.removePersistentDomain(forName: suite)
            CFPreferencesAppSynchronize(suite as CFString)
            try? FileManager.default.removeItem(at: prefsDir.appendingPathComponent(suite + ".plist"))
        }
        let memory = InMemoryUserDefaults.make()!
        for d in [real, memory] {
            d.register(defaults: ["reg": 7, "over": "registered"])
            d.set(true, forKey: "b"); d.set(5, forKey: "i"); d.set(2.5, forKey: "d")
            d.set("hello", forKey: "s"); d.set("12", forKey: "numStr"); d.set(["x", "y"], forKey: "arr"); d.set(["x", 1] as [Any], forKey: "mixed")
            d.set(Data([1, 2]), forKey: "data"); d.set(["k": "v"], forKey: "dict"); d.set("mine", forKey: "over")
            d.set("gone", forKey: "rm"); d.removeObject(forKey: "rm"); d.set(nil, forKey: "nil")
        }
        for d in [real, memory] {
            let tag = d === memory ? "内存" : "真域"
            expectEqual(d.bool(forKey: "b"), true, "内存偏好(\(tag)): bool")
            expectEqual(d.object(forKey: "i") as? Double, 5, "内存偏好(\(tag)): 存整数按 Double 取得到")
            expectEqual(d.object(forKey: "b") as? Bool, true, "内存偏好(\(tag)): object as? Bool")
            expectEqual(d.integer(forKey: "d"), 2, "内存偏好(\(tag)): integer 截断")
            expectEqual(d.string(forKey: "s"), "hello", "内存偏好(\(tag)): string")
            expectEqual(d.integer(forKey: "numStr"), 12, "内存偏好(\(tag)): 数字字符串按整数取")
            expectEqual(d.string(forKey: "i"), "5", "内存偏好(\(tag)): 数按字符串取")
            expectEqual(d.stringArray(forKey: "arr"), ["x", "y"], "内存偏好(\(tag)): stringArray")
            expectEqual(d.stringArray(forKey: "mixed") == nil, true, "内存偏好(\(tag)): 混了别的类型的数组不算字符串数组")
            expectEqual(d.array(forKey: "mixed")?.count, 2, "内存偏好(\(tag)): array")
            expectEqual(d.data(forKey: "data"), Data([1, 2]), "内存偏好(\(tag)): data")
            expectEqual(d.dictionary(forKey: "dict") as? [String: String], ["k": "v"], "内存偏好(\(tag)): dictionary")
            expectEqual(d.integer(forKey: "reg"), 7, "内存偏好(\(tag)): 注册域的值")
            expectEqual(d.string(forKey: "over"), "mine", "内存偏好(\(tag)): 写过的值压过注册域")
            expectEqual(d.object(forKey: "rm") == nil && d.object(forKey: "nil") == nil, true, "内存偏好(\(tag)): 删掉 / 写 nil")
            expectEqual(d.bool(forKey: "missing") || d.integer(forKey: "missing") != 0 || d.string(forKey: "missing") != nil, false,
                        "内存偏好(\(tag)): 没有的键取默认零值")
        }
        let leaked = ((try? FileManager.default.contentsOfDirectory(atPath: prefsDir.path)) ?? [])
            .filter { $0.hasPrefix(LyrimuseIdentity.bundleIdentifier + ".in-memory-") }
        expectEqual(leaked, [], "内存偏好: 不建偏好文件")
        expectEqual(UserDefaults.standard.object(forKey: "numStr") == nil, true, "内存偏好: 不碰标准域")
    }

    do {
        print("\n== 遥测:负载键名(跟 Worker 对得上)==")
        let env = TelemetryEnvironment(appVersion: "1", build: "1", osVersion: "26.1", arch: "arm64",
                                       uiLanguage: "en", systemLanguage: "en")
        let features = TelemetryFeatures(surfaces: ["notch", "overlay"], playersSelected: ["auto"], lyricsSourceMode: "smart",
                                         lyricsSourcesEnabled: 15, translation: true, romanization: false,
                                         machineTranslation: false, accounts: [], trustedPlayers: ["com.colliderli.iina"],
                                         webPlatforms: ["youtube-music"], showInDock: true, launchAtLogin: true,
                                         betaUpdates: false, installMethod: "homebrew",
                                         settingsChanged: ["notchGestures"], permissionsMissing: ["automation.apple_music"],
                                         lyricsWordFormats: ["ttml"])
        let beat = TelemetryHeartbeat(installID: "i", day: "2026-10-31", env: env, features: features,
                                      activity: [TelemetryActivityDay(day: "2026-10-30")])
        func keys(_ value: some Encodable) -> [String] {
            guard let data = try? JSONEncoder().encode(value),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return obj.keys.sorted()
        }
        let beatKeys = keys(beat)
        expectEqual(beatKeys, ["activity", "day", "env", "features", "install_id", "v"], "心跳: 顶层键(判不出新装还是升级时不带 origin)")
        var withOrigin = beat
        withOrigin.origin = .existing
        expectEqual(keys(withOrigin), ["activity", "day", "env", "features", "install_id", "origin", "v"], "心跳: 判得出时带 origin")
        expectEqual(String(data: (try? JSONEncoder().encode(withOrigin)) ?? Data(), encoding: .utf8)?.contains(#""origin":"existing""#),
                    true, "心跳: origin 的取值")
        expectEqual(keys(env), ["app_version", "arch", "build", "os_version", "system_language", "ui_language"], "心跳: 取不到地区时 env 不带")
        var regional = env
        regional.systemRegion = "CN"
        expectEqual(keys(regional), ["app_version", "arch", "build", "os_version", "system_language", "system_region", "ui_language"],
                    "心跳: env 键")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let worker = (try? String(contentsOfFile: root.appendingPathComponent("../../telemetry-worker/src/index.js").path,
                                  encoding: .utf8)) ?? ""
        let hang = TelemetryHang(sinceLaunch: "<1m", sinceWake: "<1m", player: "spotify", windows: [], thermal: "fair")
        expectEqual(keys(hang), ["duration", "player", "since_launch", "since_wake", "stack", "thermal", "windows"], "卡顿概况: 键名")
        var throttledHang = hang
        throttledHang.throttled = [MainThreadThrottle.locked]
        expectEqual(keys(throttledHang).contains("throttled") && keys(TelemetryActivityDay(day: "2026-10-30")).contains("throttled_hangs"),
                    true, "卡顿概况: 被压着的带 throttled,每天的活动带 throttled_hangs")
        let fields = keys(regional) + keys(features) + keys(TelemetryActivityDay(day: "2026-10-30")) + keys(throttledHang)
            + ["install_id", "origin", "report_id", "exception_type", "termination_indicator", "frames", "exception_frames"]
            + TelemetryAction.allCases.map(\.rawValue)
        expectEqual(["install_method", "settings_changed", "permissions_missing", "lyrics_word_formats"].allSatisfy(keys(features).contains),
                    true, "心跳: 功能快照带安装渠道、改过的设置、缺的权限、逐字歌词格式")
        let missing = fields.filter { !worker.contains($0) }
        expectEqual(missing, [], "Worker: 认得 App 发的每个字段")
        // 卡顿概况的取值 Worker 按白名单收,名单跟 Core 不一致的那一档会被静默丢掉。
        func workerList(_ name: String) -> [String] {
            guard let line = worker.split(separator: "\n").first(where: { $0.hasPrefix("const \(name) = [") }) else { return [] }
            let text = String(line)
            let re = try? NSRegularExpression(pattern: #""([^"]+)""#)
            return (re?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [])
                .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }.sorted()
        }
        expectEqual([workerList("HANG_DURATIONS"), workerList("HANG_ELAPSED"), workerList("HANG_THERMAL"), workerList("HANG_WINDOWS")],
                    [TelemetryHang.durationBuckets.sorted(), TelemetryHang.elapsedBuckets.sorted(), TelemetryHang.thermalStates.sorted(),
                     TelemetryHang.windowTags.sorted()], "Worker: 卡顿概况的取值名单跟 Core 一致")
        expectEqual(workerList("HANG_THROTTLE"), MainThreadThrottle.reasons.sorted(), "Worker: 节流标记的取值名单跟 Core 一致")
        expectEqual(worker.contains("const MAX_HANG_DETAILS_PER_DAY = \(TelemetryActivity.maxHangDetailsPerDay);")
                        && worker.contains("const MAX_THROTTLED_HANG_DETAILS_PER_DAY = \(TelemetryActivity.maxThrottledHangDetailsPerDay);"),
                    true, "Worker: 卡顿概况每天的条数上限(两类)跟 Core 一致")
        expectEqual(workerList("LAYOUT_PASSES"), DisplayCycleLimit.passes.sorted(), "Worker: 布局超限的 pass 名单跟 Core 一致")
        expectEqual(worker.contains("const MAX_LAYOUT_LIMITS_PER_DAY = \(TelemetryActivity.maxLayoutLimitsPerDay);"), true,
                    "Worker: 布局超限每天的条数上限跟 Core 一致")
        expectEqual(workerList("LYRICS_WORD_FORMATS"), LyricsWordFormat.allCases.map(\.rawValue).sorted(),
                    "Worker: 逐字歌词格式的取值名单跟 Core LyricsWordFormat 一致")
        // 统计端按「改过默认值的设置项里有没有 appLanguage」分界面语言跟随系统还是手动选(14 章决策 177):
        // 属性改名、或挪进不比较的名单,统计端会静默把所有人算成跟随系统。
        let settingsTelemetry = (try? String(contentsOfFile: root.appendingPathComponent("lyrimuse/Settings/AppSettings+Telemetry.swift").path,
                                             encoding: .utf8)) ?? ""
        expectEqual(sourceHas(worker, #"(r.features.settings_changed || []).includes("appLanguage") ? "manual" : "system""#)
                        && sourceHas(settingsTelemetry, #"("appLanguage", appLanguage),"#)
                        && !settingsTelemetry.contains(#""appLanguage", ""#) && !settingsTelemetry.contains(#""appLanguage"]"#), true,
                    "Worker: 界面语言来源认的 appLanguage 在设置比较清单里")
        // Worker 的两个白名单正则要放过 App 真实会发的每个取值(只比键名测不出取值被丢)。
        func workerRegex(_ name: String) -> NSRegularExpression? {
            guard let line = worker.split(separator: "\n").first(where: { $0.hasPrefix("const \(name) = /") }),
                  let open = line.firstIndex(of: "/"), let close = line.lastIndex(of: "/"), open < close else { return nil }
            return try? NSRegularExpression(pattern: String(line[line.index(after: open)..<close]))
        }
        func passes(_ re: NSRegularExpression?, _ value: String) -> Bool {
            re?.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
        let tagRE = workerRegex("TAG_RE"), idRE = workerRegex("ID_RE")
        expectEqual(tagRE != nil && idRE != nil, true, "Worker: 读得到 TAG_RE、ID_RE")
        let tagValues = PlaybackPlayer.allCases.map(\.rawValue) + BrowserPositionProbe.supportedPlatforms.map(\.id)
            + ["arm64", "x86_64", "smart", "priority", "web-lyrics", "apple-music"]
        expectEqual(tagValues.filter { !passes(tagRE, $0) }, [], "Worker: TAG_RE 放过播放器 id、网页平台 id、芯片、匹配算法")
        let idValues = PlaybackPlayer.allCases.map(\.rawValue) + ["com.apple.Safari", "company.thebrowser.Browser", "other"]
        expectEqual(idValues.filter { !passes(idRE, $0) }, [], "Worker: ID_RE 放过内置播放器 id 和 bundle id")
        expectEqual(passes(idRE, "bad id/x") || passes(tagRE, "<script>"), false, "Worker: 不像标识的写法照样挡掉")
        let permissionTags = TelemetryPermissionKind.allCases.flatMap { kind in PlaybackPlayer.allCases.map { Telemetry.permissionTag(kind, $0) } }
        expectEqual(permissionTags.filter { !passes(tagRE, $0) }, [], "Worker: TAG_RE 放过缺的权限的写法")
        expectEqual(["notchVolumeBannerForVolumeKeys", "lyricsWindowMiniHeaderWidthPercent"].filter { !passes(idRE, $0) }, [],
                    "Worker: ID_RE 放过设置项的属性名")
        expectEqual(TelemetryAction.allCases.filter { !worker.contains("\"\($0.rawValue)\"") }, [], "Worker: ACTIONS 列着 App 的每个动作")
        expectEqual(sourceHas(worker, "const LYRICS_RESULTS = [" + TelemetryLyricsResult.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ") + "];"),
                    true, "Worker: LYRICS_RESULTS 跟 App 的歌词结果一致")
        expectEqual(sourceHas(worker, "const LYRIC_SOURCES = [" + TelemetryLyricSource.tags.map { "\"\($0)\"" }.joined(separator: ", ") + "];"),
                    true, "Worker: LYRIC_SOURCES 跟 Core TelemetryLyricSource.tags 逐字一致")
        expectEqual(sourceHas(worker, "const LYRIC_SOURCE_RESULTS = [" + TelemetryLyricSource.results.map { "\"\($0.rawValue)\"" }.joined(separator: ", ") + "];"),
                    true, "Worker: LYRIC_SOURCE_RESULTS 跟 Core 计得到来源的几档一致")
        expectEqual(Set(TelemetryLyricSource.tags).count == TelemetryLyricSource.tags.count
                        && ["unknown", "other", TelemetryLyricSource.subtitles].allSatisfy(TelemetryLyricSource.tags.contains), true,
                    "歌词来源: 名单不重复,带 unknown / other / subtitles")
        // 引擎会写进条目 lyrics_source 的值:十五个歌词源(lyricSourceNames)和各本机来源常量(`const …LyricsSource = "…"`)。
        // 漏了的会在遥测里全记成 other。
        let engineDir = root.appendingPathComponent("../../lyrimuse-engine")
        let enrichGo = (try? String(contentsOf: engineDir.appendingPathComponent("enrich.go"), encoding: .utf8)) ?? ""
        var engineSources: [String] = []
        if let start = enrichGo.range(of: "var lyricSourceNames = []string{"), let end = enrichGo[start.upperBound...].range(of: "}") {
            engineSources = enrichGo[start.upperBound..<end.lowerBound].split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        let localConstRE = try? NSRegularExpression(pattern: #"^const \w*LyricsSource = "([a-z0-9]+)"$"#, options: .anchorsMatchLines)
        let goFiles = ((try? FileManager.default.contentsOfDirectory(atPath: engineDir.path)) ?? [])
            .filter { $0.hasSuffix(".go") && !$0.hasSuffix("_test.go") }
        for name in goFiles {
            let text = (try? String(contentsOf: engineDir.appendingPathComponent(name), encoding: .utf8)) ?? ""
            guard text.contains("LyricsSource = \"") else { continue }
            engineSources += (localConstRE?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [])
                .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
        }
        expectEqual(engineSources.count >= 21, true, "歌词来源: 读到了引擎的源名单和本机来源常量(守卫自身没跑空)")
        expectEqual(engineSources.filter { !TelemetryLyricSource.tags.contains($0) }, [],
                    "歌词来源: 引擎会写的每个来源都在 TelemetryLyricSource.tags 里")
        expectEqual(sourceHas(worker, "const SONG_LANGUAGES = [" + TelemetrySongLanguage.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ") + "];"),
                    true, "Worker: SONG_LANGUAGES 跟 App 的语言一致")
        expectEqual(sourceHas(worker, #"const origin = body.origin === "new" || body.origin === "existing" ? body.origin : null;"#), true,
                    "Worker: origin 只收 new / existing")
    }

    do {
        print("\n== 遥测:新装还是升级上来的 ==")
        typealias O = TelemetryInstallOrigin
        func infer(_ id: Bool, _ last: String?, _ onboarded: Bool, _ baseline: String?) -> O? {
            O.infer(hasInstallID: id, lastLaunched: last, hasCompletedOnboarding: onboarded, storedBaseline: baseline)
        }
        expectEqual(infer(false, nil, false, nil), .new, "新装: 第一次启动,没走过引导、没记过版本")
        expectEqual(infer(false, nil, true, nil), .existing, "升级: 从记版本之前的旧版直接升上来")
        expectEqual(infer(false, "1.12.0", false, "1.12.0"), .existing, "升级: 记过版本(遥测关着、没有安装 ID)")
        expectEqual(infer(true, "1.12.0", true, WhatsNew.legacyBaseline), .existing, "倒推: 基准是旧版基准 = 老用户")
        expectEqual(infer(true, "1.12.0", true, "1.12.0"), .new, "倒推: 基准等于上次启动的版本 = 从那一版装起")
        expectEqual(infer(true, "1.12.1", true, "1.12.0"), nil, "倒推: 中间升级过,判不出")
        expectEqual(infer(true, "1.12.0", true, nil), nil, "倒推: 没有基准,判不出")
    }

    do {
        print("\n== 遥测:接线 ==")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func sourceText(_ path: String) -> String {
            (try? String(contentsOfFile: root.appendingPathComponent(path).path, encoding: .utf8)) ?? ""
        }
        expectEqual(sourceHas(sourceText("lyrimuse/AppDelegate.swift"), "TelemetryService.shared.start()"), true,
                    "接线: 启动时开始")
        expectEqual(sourceHas(sourceText("LyrimuseCore/Local/LocalPlaybackSource.swift"),
                              "if trackChanged || bundleID != lastAppliedBundleID { TelemetryActivity.shared.notePlayer(bundleID: bundleID) }"),
                    true, "接线: 换歌、换播放器都记一笔(连着几天用同一个播放器也每天记到)")
        let watchdog = sourceText("LyrimuseCore/Diagnostics/MainThreadWatchdog.swift")
        let handleBody = sourceBody("private func handle(", in: watchdog)
        expectEqual(sourceHas(handleBody, "TelemetryActivity.shared.noteHang(hangContext(at: now, throttle: throttle))")
                        && sourceHas(handleBody, "if tracker.reportedStill { TelemetryActivity.shared.finishHang(seconds: seconds) }")
                        && sourceHas(handleBody, "TelemetryActivity.shared.markHangThrottled(throttle.sorted())"),
                    true, "接线: 主线程卡住记一笔概况(带节流标记),恢复时补时长(没卡满的不补),卡住之后才被压着的补标记")
        let tickBody = sourceBody("private func tick()", in: watchdog)
        let throttleAt = tickBody.range(of: "if sentAt != nil { observeThrottle(at: now, probeSentAt: sentAt) }")
        let checkAt = tickBody.range(of: "tracker.check(now: now)")
        expectEqual(throttleAt != nil && checkAt != nil && throttleAt!.lowerBound < checkAt!.lowerBound
                        && sourceHas(tickBody, "if let sentAt, answeredAt - sentAt >= self.tracker.stallThreshold { self.observeThrottle(at: answeredAt, probeSentAt: sentAt) }"),
                    true, "接线: 探测过了一拍还没被执行到时先读节流状态再判卡顿,卡过阈值后被执行到时再读一次")
        expectEqual(sourceHas(sourceBody("private func hangContext(", in: watchdog), "throttled: throttle.isEmpty ? nil : throttle.sorted()"),
                    true, "接线: 卡顿概况带上停顿期间看到的节流标记")
        expectEqual(sourceHas(sourceBody("private func takeSample()", in: watchdog),
                              "TelemetryActivity.shared.attachHangStack(TelemetryHang.mainThreadStack(fromSample: text, executable: executable))")
                        && sourceHas(sourceBody("private func tick()", in: watchdog), "wake.observe(uptime: now, continuous: WakeDetector.continuousNow)")
                        && sourceHas(sourceBody("private func tick()", in: watchdog), "if let windows { self.lastWindows = windows }"),
                    true, "接线: 采样补调用栈、每拍认唤醒、主线程还能动时记下开着的窗口")
        expectEqual(sourceHas(sourceText("lyrimuse/AppDelegate.swift"), "MainThreadWatchdog.shared.setWindowProvider {"), true,
                    "接线: App 给看门狗窗口提供者")
        expectEqual(sourceHas(sourceText("lyrimuse/SettingsView.swift"), "Toggle(\"\", isOn: $settings.telemetryEnabled)"), true,
                    "接线: 设置页开关")
        expectEqual(sourceHas(sourceText("lyrimuse/OnboardingView.swift"), "isOn: $settings.telemetryEnabled"), true,
                    "接线: 引导欢迎页开关")
        let settings = sourceText("lyrimuse/Settings/AppSettings.swift")
        expectEqual(sourceHas(settings, "telemetryEnabled = (defaults.object(forKey: Keys.telemetryEnabled) as? Bool) ?? true"),
                    true, "接线: 默认开")
        expectEqual(sourceHas(settings, "TelemetryService.shared.preferenceChanged(enabled: telemetryEnabled)"), true,
                    "接线: 改开关通知发送端")
        let service = sourceText("lyrimuse/Settings/TelemetryService.swift")
        expectEqual(sourceHas(sourceBody("private func apply(enabled: Bool)", in: service), "TelemetryActivity.shared.clear()"),
                    true, "接线: 关掉时清空活动")
        expectEqual(sourceHas(sourceBody("private func post<T: Encodable>", in: service),
                              "guard AppSettings.shared.telemetryEnabled else { return nil }"), true, "接线: 关着不发")
        let crashes = sourceBody("private func sendNewCrashes(", in: service)
        expectEqual(sourceHas(crashes, "if let status, (400..<500).contains(status), status != 429 {"), true,
                    "接线: 崩溃负载被拒(4xx)记为发过,不卡住后面的;限流(429)不算,下次再发")
        expectEqual(sourceHas(crashes, "DiagnosticsExporter.scanCrashReports(since: cutoff) { alreadySent.contains(Telemetry.reportID(fileName: $0)) }"),
                    true, "接线: 发过的崩溃报告按文件名先跳过,不再读")
        expectEqual(sourceHas(service, "TelemetryActivity.shared.trustedBundleIDs = Set(trusted.keys)"), true,
                    "接线: 信任列表变了同步给活动记账")
        expectEqual(sourceHas(sourceBody("private func features() async -> TelemetryFeatures", in: service),
                              "lyricsWordFormats: store.lyricsWordFormats.map(\\.rawValue)"), true,
                    "接线: 功能快照的逐字歌词格式取设置里的原顺序")
        let portability = sourceText("lyrimuse/Settings/ConfigPortability.swift")
        func section(_ start: String, _ end: String) -> Substring {
            guard let a = portability.range(of: start), let b = portability.range(of: end, range: a.upperBound..<portability.endIndex)
            else { return "" }
            return portability[a.upperBound..<b.lowerBound]
        }
        let machineLocal = section("private static let machineLocalDefaultsKeys", "\n    ]")
        let obsolete = section("static let obsoleteDefaultsKeys", "\n    ]")
        expectEqual(sourceHas(machineLocal, "TelemetryService.Keys.installID,") && sourceHas(machineLocal, "TelemetryActivity.storageKey,")
                    && sourceHas(machineLocal, "TelemetryService.Keys.lastHeartbeatDay,"), true,
                    "接线: 安装 ID 等记账键是机器专属的,不随配置搬家")
        expectEqual(obsolete.contains("Telemetry"), false, "接线: 遥测的键不在过时键表里(那张表启动时就删)")
        expectEqual(sourceHas(machineLocal, "TelemetryService.Keys.installOrigin,"), true, "接线: 新装还是升级的判定是机器专属的")
        let delegate = sourceText("lyrimuse/AppDelegate.swift")
        if let a = delegate.range(of: "TelemetryService.shared.start()"), let b = delegate.range(of: "WhatsNewCenter.shared.start()") {
            expectEqual(a.lowerBound < b.lowerBound, true, "接线: 遥测先于更新提示启动(判定读的是上次启动留下的版本记录)")
        } else {
            expectEqual(false, true, "接线: 找得到遥测和更新提示的启动调用")
        }
        expectEqual(sourceHas(sourceBody("func start()", in: service), "decideInstallOrigin()"), true, "接线: 启动时判新装还是升级")

        let features = sourceBody("private func features() async -> TelemetryFeatures", in: service)
        expectEqual(["Telemetry.caskroomPaths",
                     "AppSettings.telemetryDefaultSettingValues()", "PlayerHealthMonitor.telemetryPermissionGaps()",
                     "LyricsWindowSession.shouldReopenAtLaunch, \"lyrics-window\""].filter { !sourceHas(features, $0) }, [],
                    "接线: 功能快照取安装渠道、改过的设置、缺的权限、歌词窗口开着没有")
        let defaultsBody = sourceBody("static func telemetryDefaultSettingValues()", in: sourceText("lyrimuse/Settings/AppSettings+Telemetry.swift"))
        expectEqual(sourceHas(defaultsBody, "InMemoryUserDefaults.make()") && !sourceHas(defaultsBody, "UserDefaults(suiteName:"), true,
                    "接线: 全默认设置用内存偏好造,不在主线程上跟 cfprefsd 建域 / 清域")
        let offsets = sourceText("LyrimuseCore/Lyrics/LyricsOffsetStore.swift")
        expectEqual(["public func nudgeRadio(by", "public func nudge(by", "public func reset(forKey", "public func setOffset(_ ms"]
            .filter { !sourceHas(sourceBody($0, in: offsets), "TelemetryActivity.shared.noteAction(.offsetAdjusted)") }, [],
                    "接线: 手动调偏移的四个入口各记一次(自动搬运偏移的不记)")
        expectEqual(sourceHas(sourceBody("private func apply(_ c: LyricsSearchService.Candidate) async", in: sourceText("lyrimuse/LyricsManager/LyricsSearchSheet.swift")),
                              "TelemetryActivity.shared.noteAction(.lyricsPicked)"), true, "接线: 手动采用候选、存成功才记")
        let share = sourceText("lyrimuse/UI/LyricShareWindow.swift")
        expectEqual(sourceHas(sourceBody("@MainActor private func copy(", in: share), "if copied { TelemetryActivity.shared.noteAction(.shareCard) }")
                    && sourceHas(sourceBody("@MainActor private func save(", in: share), "TelemetryActivity.shared.noteAction(.shareCard)"),
                    true, "接线: 分享卡拷贝、保存成功各记一次")
        let source = sourceText("LyrimuseCore/Local/LocalPlaybackSource.swift")
        expectEqual(sourceHas(sourceBody("private func reloadCurrentLyrics()", in: source), "noteLyricsTelemetry(trackKey: reloadSnapshot.trackKey")
                    && sourceHas(sourceBody("private func noteLyricsTelemetry(", in: source), "!isCurrentTrackAdBreak")
                    && sourceHas(sourceBody("private func noteLyricsTelemetry(", in: source), "hasContent || instrumental || noLyrics"),
                    true, "接线: 歌词落定时记歌词结果,广告和还在搜的不记")
        expectEqual(sourceHas(sourceBody("private func reloadCurrentLyrics()", in: source),
                              "source: playerVersion?.source ?? found?.lyricsSource, plainSource: found?.plainLyricsSource")
                    && sourceHas(sourceBody("private func noteLyricsTelemetry(", in: source), "source: result == .plain ? plainSource : source"),
                    true, "接线: 来源取显示的那份(播放器自家那份优先),纯文本档取纯文本的来源")
        let window = sourceText("lyrimuse/UI/LyricsWindowView.swift")
        expectEqual(sourceHas(sourceBody("static func markOpen()", in: window), "guard !UserDefaults.standard.bool(forKey: openKey) else { return }")
                    && sourceHas(sourceBody("static func markOpen()", in: window), "TelemetryActivity.shared.noteAction(.lyricsWindow)"),
                    true, "接线: 歌词窗口从没开变成开着才记一次")
        expectEqual(window.contains("UserDefaults.standard.set(true, forKey: LyricsWindowSession.openKey)"), false,
                    "接线: 记「窗口开着」都走 markOpen")
        // 每个 @Published 设置要么拿去比、要么写明不比,新加的设置不会悄悄漏掉。
        func captures(_ pattern: String, in text: some StringProtocol) -> Set<String> {
            let text = String(text)
            guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
            return Set(re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: 1), in: text).map { String(text[$0]) }
            })
        }
        let published = captures(#"@Published (?:private\(set\) )?var ([A-Za-z0-9_]+)"#, in: settings)
        let snapshotSource = sourceText("lyrimuse/Settings/AppSettings+Telemetry.swift")
        let compared = captures(#"\("([A-Za-z0-9_]+)", \1\)"#, in: snapshotSource)
        let excludedBody = snapshotSource.range(of: "static let telemetryExcludedSettings").map { snapshotSource[$0.upperBound...] } ?? ""
        let excluded = captures(#""([A-Za-z0-9_]+)""#, in: excludedBody.prefix(while: { $0 != "\n" }))
        expectEqual(published.count > 200, true, "设置快照: 读得到 AppSettings 的属性")
        expectEqual(published.subtracting(compared).subtracting(excluded).sorted(), [],
                    "设置快照: 每个设置要么拿去比、要么写明不比")
        expectEqual(compared.intersection(excluded).sorted(), [], "设置快照: 同一项不会既比又不比")
        expectEqual(compared.subtracting(published).sorted(), [], "设置快照: 比的都是真实存在的设置")
        expectEqual(sourceHas(settings, "init(defaults: UserDefaults = .standard) {\n        self.defaults = defaults"), true,
                    "设置快照: 全默认的那一份用临时域构造,平时照旧用系统的")
    }
}
