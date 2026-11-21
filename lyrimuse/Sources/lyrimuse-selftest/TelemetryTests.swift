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
        expectEqual(Telemetry.heartbeatDue(today: "2026-10-30", lastSentDay: "2026-10-31"), false,
                    "心跳: 系统日期往回调过不发(补发会拿半截活动盖掉服务器上那天已收的)")

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
        var appKitAssert = summary
        appKitAssert.frames = (0..<15).map { CrashReportSummary.Frame(imageName: "AppKit", symbol: nil, imageOffset: 100 + $0) }
        appKitAssert.laterOwnFrames = [CrashReportSummary.Frame(imageName: "lyrimuse", symbol: nil, imageOffset: 901)]
        expectEqual(TelemetryCrash(summary: appKitAssert, reportID: id, executableName: "lyrimuse", installID: "i", env: env).frames
                        .map { "\($0.image ?? "")+\($0.offset ?? -1)" },
                    (0..<11).map { "AppKit+\(100 + $0)" } + ["lyrimuse+901"],
                    "故障线程: 前 12 帧全是系统帧时,末尾换成后面最近的自家帧,总数不变")
        var entryInTail = appKitAssert
        entryInTail.laterOwnFrames = []
        entryInTail.frames[13] = CrashReportSummary.Frame(imageName: "lyrimuse", symbol: nil, imageOffset: 913)
        entryInTail.frames[14] = CrashReportSummary.Frame(imageName: "dyld", symbol: "start", imageOffset: 914)
        entryInTail.entryFrameStart = 13
        expectEqual(TelemetryCrash(summary: entryInTail, reportID: id, executableName: "lyrimuse", installID: "i", env: env).frames
                        .map(\.offset), (0..<12).map { 100 + $0 },
                    "故障线程: 第 12 帧之后只有入口那一串自家帧时照原样截")
        entryInTail.frames[12] = CrashReportSummary.Frame(imageName: "lyrimuse", symbol: nil, imageOffset: 912)
        entryInTail.entryFrameStart = 12
        expectEqual(TelemetryCrash(summary: entryInTail, reportID: id, executableName: "lyrimuse", installID: "i", env: env).frames
                        .map(\.offset), (0..<12).map { 100 + $0 },
                    "故障线程: 入口那一串从第 12 帧起时一帧都不补")
        entryInTail.entryFrameStart = 13
        expectEqual(TelemetryCrash(summary: entryInTail, reportID: id, executableName: "lyrimuse", installID: "i", env: env).frames
                        .map(\.offset), (0..<11).map { 100 + $0 } + [912],
                    "故障线程: 第 12～14 帧里入口之前的自家帧照样补")
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
        print("\n== 遥测:系统日期往前 / 往回调、计数封顶、清除所有设置 ==")
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_793_300_000) }
        let clock = Clock()
        let base = clock.now
        func at(_ offset: Int) -> Date { base.addingTimeInterval(Double(offset) * 86_400) }
        func day(_ offset: Int) -> String { Telemetry.day(at(offset)) }
        let key = "selftest.telemetryActivityClock.\(getpid())"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let activity = TelemetryActivity(defaults: .standard, key: key, clock: { clock.now })
        func days() -> [String] { activity.completedDays(before: "9999-12-31").map(\.day) }
        activity.isRecording = true
        activity.noteHang(now: at(0))
        activity.noteHang(now: at(1))
        activity.noteHang(now: at(3))
        expectEqual(days(), [day(0), day(1)], "往前调: 明天的照记(换时区),晚一天以上的不记")
        clock.now = at(5)
        activity.noteHang(now: at(5))
        expectEqual(days(), [day(0), day(1), day(5)], "往前调: 系统日期就在那天时照记")
        clock.now = base
        activity.noteAction(.shareCard, now: at(0))
        expectEqual(days(), [day(0), day(1)], "往前调: 日期改回来后,比今天晚一天以上的那天丢掉,不一直占名额")

        activity.clear()
        activity.sentBefore = day(1)
        activity.noteHang(now: at(0))
        activity.noteAction(.shareCard, now: at(0))
        activity.noteLyricsResult(track: "a", result: .word, source: "qq", language: .zh, now: at(0))
        activity.noteLayoutLimit(window: nil, windowClass: "NSWindow", pass: "layout", now: at(0))
        expectEqual(days(), [], "往回调: 早于上次发心跳那天的日子不再记(已随心跳发出)")
        activity.noteHang(now: at(1))
        expectEqual(days(), [day(1)], "往回调: 发心跳那天本身照记(那条心跳只带它之前的日子)")
        activity.sentBefore = nil
        activity.noteHang(now: at(0))
        activity.sentBefore = day(1)
        expectEqual(activity.completedDays(before: day(2)).map(\.day), [day(1)], "往回调: 存着的更早日子不再随心跳发出")
        activity.noteHang(now: at(1))
        activity.waitForPendingWrites()
        expectEqual(TelemetryActivity(defaults: .standard, key: key).completedDays(before: "9999-12-31").map(\.day), [day(1)],
                    "往回调: 存着的更早日子下一次写盘时丢掉")
        activity.sentBefore = nil
        activity.clear()

        let cap = TelemetryActivity.maxCount
        let capKey = "selftest.telemetryActivityCap.\(getpid())"
        defer { UserDefaults.standard.removeObject(forKey: capKey) }
        let sourceKey = TelemetryLyricSource.key(source: "qq", result: .word) ?? ""
        let full = TelemetryActivityDay(day: day(0), hangs: cap, throttledHangs: cap,
                                        actions: [TelemetryAction.shareCard.rawValue: cap],
                                        lyrics: [TelemetryLyricsResult.word.rawValue: cap],
                                        languages: [TelemetrySongLanguage.zh.rawValue: cap], lyricSources: [sourceKey: cap],
                                        layoutLimits: [TelemetryLayoutLimit(window: nil, windowClass: "NSWindow", pass: "layout", count: cap)])
        UserDefaults.standard.set(try? JSONEncoder().encode([full]), forKey: capKey)
        let capped = TelemetryActivity(defaults: .standard, key: capKey, clock: { base })
        capped.isRecording = true
        capped.noteHang(TelemetryHang(sinceLaunch: "0-1m", sinceWake: nil, windows: [], thermal: "nominal", throttled: ["locked"]),
                        now: base)
        capped.noteAction(.shareCard, now: base)
        capped.noteLyricsResult(track: "a", result: .word, source: "qq", language: .zh, now: base)
        capped.noteLayoutLimit(window: nil, windowClass: "NSWindow", pass: "layout", now: base)
        let got = capped.completedDays(before: "9999-12-31").first
        expectEqual([got?.hangs, got?.throttledHangs, got?.actions[TelemetryAction.shareCard.rawValue],
                     got?.lyrics[TelemetryLyricsResult.word.rawValue], got?.languages[TelemetrySongLanguage.zh.rawValue],
                     got?.lyricSources[sourceKey], got?.layoutLimits.first?.count],
                    Array(repeating: cap, count: 7), "封顶: 每天各项计数到 Worker 收的上限为止,超了 Worker 判这一项不合法")
        capped.clear()
        capped.waitForPendingWrites()

        let resetKey = "selftest.telemetryActivityReset.\(getpid())"
        defer { UserDefaults.standard.removeObject(forKey: resetKey) }
        let reset = TelemetryActivity(defaults: .standard, key: resetKey)
        reset.isRecording = true
        reset.noteHang(now: base)
        reset.noteLayoutLimit(window: nil, windowClass: "NSWindow", pass: "layout", now: base)
        reset.noteLayoutLimit(window: nil, windowClass: "NSWindow", pass: "layout", now: base)
        // 清除所有设置的顺序:停记 → 删偏好键 → clear();删键之后、重启之前的记账不落下。
        reset.isRecording = false
        UserDefaults.standard.removeObject(forKey: resetKey)
        reset.noteHang(now: base)
        reset.clear()
        reset.noteAction(.shareCard, now: base)
        reset.waitForPendingWrites()
        expectEqual(UserDefaults.standard.data(forKey: resetKey) == nil && reset.completedDays(before: "9999-12-31").isEmpty
                    && TelemetryActivity(defaults: .standard, key: resetKey).completedDays(before: "9999-12-31").isEmpty, true,
                    "清除所有设置: 停记、删键、清空之后,排着的延后写盘和之后的记账都不把清除前的活动写回")
    }

    do {
        print("\n== 遥测:崩溃报告的发送记账 ==")
        typealias L = TelemetryCrashLedger
        let statuses: [Int?] = [200, 204, 400, 413, 401, 403, 404, 408, 422, 429, 500, 502, 503, 504, nil]
        expectEqual(statuses.map { L.outcome(status: $0) },
                    [.accepted, .accepted, .rejected, .rejected, .later, .later, .later, .later, .later, .later,
                     .serverError, .serverError, .later, .serverError, .later],
                    "崩溃: 只有 Worker 回的 400(负载不合格)/ 413(过大)算这一份不合格;网关的 4xx、限流、连不上下次再发")
        final class Server: @unchecked Sendable {
            var posted: [String] = []
            let respond: (String, Int) -> Int?
            init(_ respond: @escaping (String, Int) -> Int?) { self.respond = respond }
            func post(_ id: String) -> Int? {
                posted.append(id)
                return respond(id, posted.filter { $0 == id }.count)
            }
        }
        final class Round: @unchecked Sendable {
            var ledger: L
            var saved: L?
            init(_ ledger: L) { self.ledger = ledger }
        }
        let today = "2026-11-19"
        func round(_ ledger: L, _ ids: [String], _ server: Server, on day: String = "2026-11-19") -> (ledger: L, saved: L?) {
            let box = Round(ledger)
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await box.ledger.send(ids.map { (id: $0, report: $0) }, today: day,
                                      post: { server.post($0) }, save: { box.saved = $0 })
                done.signal()
            }
            done.wait()
            return (box.ledger, box.saved)
        }

        let broken = Server { id, _ in id == "a" ? 500 : 200 }
        var r = round(L(), ["a", "b", "c"], broken)
        expectEqual([broken.posted, r.ledger.sent] as [[String]], [["a"], []], "崩溃: 服务器出错停下,不发后面的")
        expectEqual([r.ledger.failingID == "a", r.ledger.failures == 1, r.saved == r.ledger], [true, true, true],
                    "崩溃: 服务器出错记一次,当场存下")
        r = round(r.ledger, ["a", "b", "c"], broken)
        expectEqual([broken.posted == ["a", "a"], r.ledger.failures == 2, r.ledger.sent.isEmpty], [true, true, true],
                    "崩溃: 连着第二次还挡着")
        r = round(r.ledger, ["a", "b", "c"], broken)
        expectEqual(broken.posted, ["a", "a", "a", "b", "c"], "崩溃: 同一份连着 3 次服务器出错就跳过,接着发后面的")
        expectEqual([r.ledger.sent == ["a", "b", "c"], r.ledger.failingID == nil, r.ledger.sentCount(on: today) == 2,
                     r.saved == r.ledger], [true, true, true, true], "崩溃: 跳过的记为发过、不算当天条数")

        for status in [nil, 429, 503, 401, 403, 404, 408] as [Int?] {
            let flaky = Server { _, _ in status }
            let start = L(failingID: "a", failures: 2)
            let out = round(start, ["a", "b"], flaky)
            expectEqual([flaky.posted == ["a"], out.ledger == start, out.saved == nil], [true, true, true],
                        "崩溃: \(status.map(String.init) ?? "连不上") 停下等下次,不记为发过、不算服务器出错")
        }
        let rejects = Server { id, _ in id == "a" ? 400 : (id == "b" ? 413 : 200) }
        r = round(L(failingID: "a", failures: 2), ["a", "b", "c"], rejects)
        expectEqual([rejects.posted == ["a", "b", "c"], r.ledger.sent == ["a", "b", "c"], r.ledger.sentCount(on: today) == 1,
                     r.ledger.failingID == nil], [true, true, true, true], "崩溃: 400 / 413 记为发过、接着发下一份,不算当天条数")
        let other = Server { _, _ in 500 }
        r = round(L(failingID: "x", failures: 2), ["a"], other)
        expectEqual([r.ledger.failingID == "a", r.ledger.failures == 1, r.ledger.sent.isEmpty], [true, true, true],
                    "崩溃: 排在最前面的换了一份,从头计次")

        let ok = Server { _, _ in 200 }
        let ids = (0..<(Telemetry.maxCrashesPerDay + 2)).map { "r\($0)" }
        r = round(L(sentDay: today, sentOnDay: Telemetry.maxCrashesPerDay - 1), ids, ok)
        expectEqual([ok.posted == ["r0"], r.ledger.sentCount(on: today) == Telemetry.maxCrashesPerDay], [true, true],
                    "崩溃: 每天最多发 maxCrashesPerDay 条")
        let nextDay = Server { _, _ in 200 }
        r = round(r.ledger, Array(ids.dropFirst()), nextDay, on: "2026-11-20")
        expectEqual([nextDay.posted.count == Telemetry.maxCrashesPerDay, r.ledger.sentCount(on: "2026-11-20") == Telemetry.maxCrashesPerDay],
                    [true, true], "崩溃: 换天重新计条数")
        let skip = Server { _, _ in 200 }
        _ = round(L(sent: ["a"]), ["a", "b"], skip)
        expectEqual(skip.posted, ["b"], "崩溃: 发过的不再发")

        let keys = L.Keys(sent: "selftest.crashSent.\(getpid())", sentDay: "selftest.crashDay.\(getpid())",
                          serverFailures: "selftest.crashFailures.\(getpid())")
        defer { [keys.sent, keys.sentDay, keys.serverFailures].forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        let stored = L(sent: ["a", "b"], sentDay: today, sentOnDay: 2, failingID: "c", failures: 2)
        stored.save(to: .standard, keys: keys)
        expectEqual(L.load(from: .standard, keys: keys), stored, "崩溃: 记账存进偏好、读得回")
        L(sent: ["a"], sentDay: today, sentOnDay: 1).save(to: .standard, keys: keys)
        expectEqual([UserDefaults.standard.string(forKey: keys.serverFailures) == nil,
                     UserDefaults.standard.string(forKey: keys.sentDay) == "\(today)|1"], [true, true],
                    "崩溃: 不再挡着时删掉计次键;当天条数沿用旧版的「日期|条数」写法")
        var many = L()
        for i in 0..<(Telemetry.sentCrashMemory + 5) { many = round(many, ["m\(i)"], Server { _, _ in 400 }).ledger }
        expectEqual([many.sent.count == Telemetry.sentCrashMemory, many.sent.last == "m\(Telemetry.sentCrashMemory + 4)"], [true, true],
                    "崩溃: 发过的最多记 sentCrashMemory 条")
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
        typealias Ticket = TelemetryActivity.HangTicket
        func frame(_ offset: Int) -> [TelemetryCrash.Frame] { [TelemetryCrash.Frame(image: "lyrimuse", symbol: nil, offset: offset)] }
        func finish(_ on: TelemetryActivity, _ hang: Ticket?, _ seconds: TimeInterval) {
            if let hang { on.finishHang(hang, seconds: seconds) }
        }
        func attachStack(_ on: TelemetryActivity, _ hang: Ticket?, _ offset: Int) {
            if let hang { on.attachHangStack(frame(offset), to: hang) }
        }
        expectEqual(activity.noteHang(base, now: day1), nil, "记账: 关着时不记、没有回执(看门狗按冷却决定采不采)")
        expectEqual(activity.completedDays(before: d2), [], "记账: 关着时不记概况")
        activity.isRecording = true
        activity.notePlayer(bundleID: PlaybackPlayer.spotify.bundleIdentifier, now: day1)
        let first = activity.noteHang(base, now: day1)
        expectEqual(first?.detailed, true, "记账: 当天第一次占到概况名额")
        var details = activity.completedDays(before: d2).first?.hangDetails ?? []
        expectEqual(details.map(\.duration), [H.unrecovered], "记账: 刚卡住记成没恢复")
        expectEqual(details.first?.player, PlaybackPlayer.spotify.rawValue, "记账: 播放器填最近放歌的那个")
        attachStack(activity, first, 42)
        attachStack(activity, first, 7)
        finish(activity, first, 12)
        details = activity.completedDays(before: d2).first?.hangDetails ?? []
        expectEqual(details.first?.duration, "10-30s", "记账: 恢复后补上时长")
        expectEqual(details.first?.stack.map(\.offset), [42], "记账: 调用栈只补第一份")
        let more = (0..<5).map { _ in activity.noteHang(base, now: day1) }
        expectEqual(more.map { $0?.detailed }, [true, true, false, false, false], "记账: 名额只有每天前 3 次,之后不占")
        let got = activity.completedDays(before: d2).first
        expectEqual(got?.hangs, 6, "记账: 次数照记")
        expectEqual(got?.hangDetails.count, TelemetryActivity.maxHangDetailsPerDay, "记账: 概况每天最多记几条")
        finish(activity, more.last ?? nil, 40)
        expectEqual(activity.completedDays(before: d2).first?.hangDetails.last?.duration, H.unrecovered,
                    "记账: 超出名额的那次恢复了不改前一条")
        let bare = activity.noteHang(nil, now: day1)
        expectEqual(bare?.detailed, false, "记账: 不带概况的不占名额")
        finish(activity, bare, 40)
        expectEqual(activity.completedDays(before: d2).first?.hangDetails.map(\.duration), ["10-30s", H.unrecovered, H.unrecovered],
                    "记账: 不带概况的那次之后不补到旧的一条")
        activity.clear()
        activity.waitForPendingWrites()

        // 连着两次卡顿(14 章决策 231):采栈在报卡顿之后好几秒才跑完,这期间又卡了一次;栈、时长按回执补到各自那一条。
        let pairKey = "selftest.telemetryHangPair.\(getpid())"
        defer { UserDefaults.standard.removeObject(forKey: pairKey) }
        let pair = TelemetryActivity(defaults: .standard, key: pairKey)
        pair.isRecording = true
        let hangA = pair.noteHang(base, now: day1), hangB = pair.noteHang(base, now: day1)
        attachStack(pair, hangB, 2)
        attachStack(pair, hangA, 1)
        finish(pair, hangA, 7)
        finish(pair, hangB, 40)
        let pairDetails = pair.completedDays(before: d2).first?.hangDetails ?? []
        expectEqual(pairDetails.map { $0.stack.first?.offset }, [1, 2], "回执: 先卡的那次的栈晚到,补回它自己那一条,不占后一次的")
        expectEqual(pairDetails.map(\.duration), ["5-10s", "30s+"], "回执: 时长各补各的")
        pair.clear()

        // 看门狗这边的回执(14 章决策 231):遥测关着时卡的那次没有回执,之后恢复、被压着都不补到上一次卡顿那条上。
        pair.isRecording = true
        var ledger = HangLedger(activity: pair)
        _ = ledger.stalled(base, now: day1)
        ledger.recovered(seconds: 12, memoryPressure: nil, pageins: nil)
        pair.isRecording = false
        expectEqual(ledger.stalled(base, now: day1), nil, "回执: 遥测关着时卡住,不记、没有回执")
        pair.isRecording = true
        ledger.throttled([MainThreadThrottle.locked])
        ledger.recovered(seconds: 40, memoryPressure: HangMemory.critical, pageins: 9)
        let ledgerDay = pair.completedDays(before: d2).first
        expectEqual([ledgerDay?.hangDetails.map(\.duration), ledgerDay?.hangDetails.map { $0.throttled?.joined() ?? "-" }],
                    [["10-30s"], ["-"]], "回执: 关着时那次的恢复、节流标记不补到上一次卡顿")
        expectEqual(ledgerDay?.throttledHangs, 0, "回执: 关着时那次不补进被压着的次数")
        pair.clear()
        pair.waitForPendingWrites()

        // 遥测开关还没定(App 启动、TelemetryService 读设置之前,14 章决策 231):卡顿记进内存不写盘,定下来开着就写、关着就丢。
        let undecidedKey = "selftest.telemetryHangUndecided.\(getpid())"
        defer { UserDefaults.standard.removeObject(forKey: undecidedKey) }
        let early = TelemetryActivity(defaults: .standard, key: undecidedKey, recording: .undecided)
        early.notePlayer(bundleID: PlaybackPlayer.spotify.bundleIdentifier, now: day1)
        early.noteAction(.shareCard, now: day1)
        let earlyHang = early.noteHang(base, now: day1)
        attachStack(early, earlyHang, 5)
        finish(early, earlyHang, 12)
        _ = early.noteHang(nil, now: day1)
        early.waitForPendingWrites()
        expectEqual([earlyHang?.detailed, early.isRecording, early.queuedWrites == 0, UserDefaults.standard.data(forKey: undecidedKey) == nil],
                    [true, false, true, true], "还没定开关: 卡顿照记、占名额(看门狗照样采栈),不写盘")
        early.isRecording = true
        early.waitForPendingWrites()
        let earlyStored = UserDefaults.standard.data(forKey: undecidedKey)
            .flatMap { try? JSONDecoder().decode([TelemetryActivityDay].self, from: $0) }?.first
        expectEqual(earlyStored.map { [String($0.hangs), $0.hangDetails.first?.duration, $0.hangDetails.first?.stack.first.map { "\($0.offset ?? -1)" }] },
                    ["2", "10-30s", "5"], "还没定开关: 定下来开着时,这期间的卡顿连时长、栈一起写盘")
        expectEqual(earlyStored.map { [$0.playersPlayed.isEmpty, $0.actions.isEmpty] }, [true, true],
                    "还没定开关: 这期间别的记账(放歌、动作)不记")
        early.clear()
        early.waitForPendingWrites()
        let dropped = TelemetryActivity(defaults: .standard, key: undecidedKey, recording: .undecided)
        let droppedHang = dropped.noteHang(base, now: day1)
        dropped.isRecording = false
        dropped.isRecording = true
        finish(dropped, droppedHang, 12)
        dropped.waitForPendingWrites()
        expectEqual([dropped.completedDays(before: d2).isEmpty, UserDefaults.standard.data(forKey: undecidedKey) == nil], [true, true],
                    "还没定开关: 定下来关着时丢掉这期间的卡顿,之后再打开也不补回来")

        // 看门狗起来之前按偏好先定开关(14 章决策 232):之后的卡顿当场排进写盘队列,不在内存里等 TelemetryService。
        let prefsSuite = "selftest.telemetryDecide.\(getpid())"
        let prefs = UserDefaults(suiteName: prefsSuite)!
        defer { prefs.removePersistentDomain(forName: prefsSuite) }
        let enabledKey = "selftest.enabled", sentKey = "selftest.lastHeartbeatDay", decideKey = "selftest.activity"
        let decided = TelemetryActivity(defaults: prefs, key: decideKey, recording: .undecided)
        decided.decideFromPreferences(enabledKey: enabledKey, lastHeartbeatDayKey: sentKey)
        let decidedHang = decided.noteHang(base, now: day1)
        expectEqual([decided.isRecording, decidedHang?.detailed, decided.queuedWrites == 1], [true, true, true],
                    "按偏好定开关: 开关没存过按开,定下来之后的卡顿当场排写盘")
        decided.waitForPendingWrites()
        expectEqual(prefs.data(forKey: decideKey).flatMap { try? JSONDecoder().decode([TelemetryActivityDay].self, from: $0) }?
                        .first.map { [$0.day, String($0.hangs), String($0.hangDetails.count)] },
                    [Telemetry.day(day1), "1", "1"], "按偏好定开关: 卡顿连概况落盘")
        prefs.removeObject(forKey: decideKey)
        let heldFirst = TelemetryActivity(defaults: prefs, key: decideKey, recording: .undecided)
        _ = heldFirst.noteHang(base, now: day1)
        prefs.set(Telemetry.day(day1), forKey: sentKey)
        heldFirst.decideFromPreferences(enabledKey: enabledKey, lastHeartbeatDayKey: sentKey)
        heldFirst.waitForPendingWrites()
        expectEqual([heldFirst.sentBefore, prefs.data(forKey: decideKey) == nil ? "无" : "有"], [Telemetry.day(day1), "有"],
                    "按偏好定开关: 上次发心跳那天同步给 sentBefore,定之前记在内存里的卡顿一起写盘")
        prefs.removeObject(forKey: decideKey)
        prefs.set(false, forKey: enabledKey)
        let declined = TelemetryActivity(defaults: prefs, key: decideKey, recording: .undecided)
        _ = declined.noteHang(base, now: day1)
        declined.decideFromPreferences(enabledKey: enabledKey, lastHeartbeatDayKey: sentKey)
        let declinedHang = declined.noteHang(base, now: day1)
        declined.waitForPendingWrites()
        expectEqual([declined.isRecording, declinedHang == nil, prefs.data(forKey: decideKey) == nil], [false, true, true],
                    "按偏好定开关: 存着关,之前和之后的卡顿都不记")
        prefs.removeObject(forKey: enabledKey)
        let already = TelemetryActivity(defaults: prefs, key: decideKey, recording: .undecided)
        already.isRecording = false
        already.decideFromPreferences(enabledKey: enabledKey, lastHeartbeatDayKey: sentKey)
        expectEqual([already.isRecording, already.sentBefore == nil], [false, true], "按偏好定开关: 已经定过的不改")

        // 主线程堵着时后台写偏好不排队等它(14 章决策 175、231):偏好变更观察者走 UserDefaultsChangeRelay,
        // 看门狗记下的卡顿在主线程卡住期间就能落盘,用户这时强制退出也不丢。
        final class Hits: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func hit() { lock.withLock { count += 1 } }
            var value: Int { lock.withLock { count } }
        }
        let relayKey = "selftest.telemetryHangRelay.\(getpid())"
        defer { UserDefaults.standard.removeObject(forKey: relayKey) }
        let hits = Hits()
        let relay = UserDefaultsChangeRelay.observe(.standard) { hits.hit() }
        let busy = TelemetryActivity(defaults: .standard, key: relayKey)
        busy.isRecording = true
        _ = busy.noteHang(base, now: day1)
        let landed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            busy.waitForPendingWrites()
            landed.signal()
        }
        // 主线程在这里等着,不跑主队列:观察者要是排进主队列同步等,写盘就落不了地。
        let landedWhileMainBusy = landed.wait(timeout: .now() + 1) == .success
        let drainUntil = Date().addingTimeInterval(5)
        while !landedWhileMainBusy, landed.wait(timeout: .now()) != .success, Date() < drainUntil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        NotificationCenter.default.removeObserver(relay)
        let busyStored = UserDefaults.standard.data(forKey: relayKey)
            .flatMap { try? JSONDecoder().decode([TelemetryActivityDay].self, from: $0) }?.first?.hangs
        expectEqual([landedWhileMainBusy, busyStored == 1, hits.value > 0], [true, true, true],
                    "写盘: 主线程堵着时卡顿记账照样落盘,偏好变更的回调等主线程空下来再跑")
        busy.clear()
        busy.waitForPendingWrites()
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
        expectEqual((try? JSONDecoder().decode(H.self, from: Data(oldHang.utf8))).map { $0.throttled == nil && $0.simulated == nil }, true,
                    "记账: 旧版本存下的概况没有节流标记、不算模拟的")
        expectEqual((try? JSONDecoder().decode(H.self, from: Data(oldHang.utf8)))
                        .map { [$0.memoryPressure, $0.pageins.map(String.init), $0.mainCPUMilliseconds.map(String.init)] },
                    [nil, nil, nil], "记账: 旧版本存下的概况没有内存压力、换页次数和主线程 CPU 时间")

        // 卡顿期间的内存情况(14 章决策 222):报卡顿时记到那一刻为止的,恢复时换成整段的;内存压力取紧的。
        let memoryKey = "selftest.telemetryHangMemory.\(getpid())"
        defer { UserDefaults.standard.removeObject(forKey: memoryKey) }
        let memoryActivity = TelemetryActivity(defaults: .standard, key: memoryKey)
        memoryActivity.isRecording = true
        var tight = base
        tight.memoryPressure = HangMemory.critical
        tight.pageins = 40
        if let hang = memoryActivity.noteHang(tight, now: day1) {
            memoryActivity.finishHang(hang, seconds: 12, memoryPressure: HangMemory.warning, pageins: 900)
        }
        var memoryHang = memoryActivity.completedDays(before: d2).first?.hangDetails.first
        expectEqual([memoryHang?.memoryPressure, memoryHang?.pageins.map(String.init), memoryHang?.duration],
                    [HangMemory.critical, "900", "10-30s"], "内存记账: 恢复时换页次数换成整段的,内存压力不降档,时长照补")
        memoryActivity.clear()
        var loose = base
        loose.memoryPressure = HangMemory.normal
        loose.pageins = 3
        if let hang = memoryActivity.noteHang(loose, now: day1) {
            memoryActivity.finishHang(hang, seconds: 6, memoryPressure: HangMemory.warning)
        }
        memoryHang = memoryActivity.completedDays(before: d2).first?.hangDetails.first
        expectEqual([memoryHang?.memoryPressure, memoryHang?.pageins.map(String.init)], [HangMemory.warning, "3"],
                    "内存记账: 停顿后半段才紧起来的升档;恢复时读不到换页次数就留着报卡顿时的")
        memoryActivity.clear()
        // 主线程 CPU 时间(14 章决策 238):报卡顿时记到那一刻为止的,恢复时换成整段的;恢复时读不到就留着。
        var cpuHang = base
        cpuHang.mainCPUMilliseconds = 4_900
        if let hang = memoryActivity.noteHang(cpuHang, now: day1) {
            memoryActivity.finishHang(hang, seconds: 8, mainCPUMilliseconds: 7_800)
        }
        let cpuWhole = memoryActivity.completedDays(before: d2).first?.hangDetails.first?.mainCPUMilliseconds
        memoryActivity.clear()
        if let hang = memoryActivity.noteHang(cpuHang, now: day1) {
            memoryActivity.finishHang(hang, seconds: 8, memoryPressure: nil, pageins: 3, mainCPUMilliseconds: nil)
        }
        let cpuKept = memoryActivity.completedDays(before: d2).first?.hangDetails.first?.mainCPUMilliseconds
        expectEqual([cpuWhole, cpuKept], [7_800, 4_900], "CPU 记账: 恢复时换成整段停顿的主线程 CPU 时间,读不到时留着报卡顿时的")
        var cpuLedger = HangLedger(activity: memoryActivity)
        memoryActivity.clear()
        _ = cpuLedger.stalled(cpuHang, now: day1)
        cpuLedger.recovered(seconds: 8, memoryPressure: nil, pageins: nil, mainCPUMilliseconds: 12)
        expectEqual(memoryActivity.completedDays(before: d2).first?.hangDetails.first?.mainCPUMilliseconds, 12,
                    "CPU 记账: 看门狗的回执把恢复时的 CPU 时间补到那一条")
        // 调试造的停顿(14 章决策 240):概况照记、带 simulated,不计进卡顿次数和被压着的次数(后补节流标记也不计)。
        memoryActivity.clear()
        var simulatedHang = base
        simulatedHang.simulated = true
        simulatedHang.throttled = [MainThreadThrottle.locked]
        _ = memoryActivity.noteHang(base, now: day1)
        var simLedger = HangLedger(activity: memoryActivity)
        let simTicket = simLedger.stalled(simulatedHang, now: day1)
        simLedger.throttled([MainThreadThrottle.locked, MainThreadThrottle.lowPriority])
        simLedger.recovered(seconds: 7, memoryPressure: nil, pageins: nil, mainCPUMilliseconds: 6)
        var lateSimulated = base
        lateSimulated.simulated = true
        var lateLedger = HangLedger(activity: memoryActivity)
        _ = lateLedger.stalled(lateSimulated, now: day1)
        lateLedger.throttled([MainThreadThrottle.locked])
        let simDay = memoryActivity.completedDays(before: d2).first
        expectEqual([simTicket?.detailed == true, simDay?.hangs == 1, simDay?.throttledHangs == 0,
                     simDay?.hangDetails.map { $0.simulated == true } == [false, true, true],
                     simDay?.hangDetails.dropFirst().first?.duration == "5-10s"],
                    [true, true, true, true, true],
                    "模拟卡顿: 概况照记(带 simulated、照补时长),卡顿次数只算真卡顿,被压着的次数不算模拟的(含后补的)")
        tight.mainCPUMilliseconds = 6_100
        tight.simulated = true
        let memoryRoundTrip = TelemetryActivityDay(day: "2026-11-18", hangs: 1, hangDetails: [tight])
        expectEqual((try? JSONEncoder().encode(memoryRoundTrip)).flatMap { try? JSONDecoder().decode(TelemetryActivityDay.self, from: $0) },
                    memoryRoundTrip, "内存记账: 内存压力、换页次数、主线程 CPU 时间和模拟标记能存能读")
        memoryActivity.clear()
        memoryActivity.waitForPendingWrites()

        // 被系统压着的卡顿(14 章决策 202):次数照记、另记一份;概况另占名额,不挤掉没被压着的。
        let throttleKey = "selftest.telemetryHangThrottle.\(getpid())"
        defer { UserDefaults.standard.removeObject(forKey: throttleKey) }
        let throttling = TelemetryActivity(defaults: .standard, key: throttleKey)
        throttling.isRecording = true
        let lockedHang = H(sinceLaunch: "1-6h", sinceWake: nil, windows: [], thermal: "nominal", throttled: [MainThreadThrottle.locked])
        expectEqual([throttling.noteHang(lockedHang, now: day1)?.detailed, throttling.noteHang(lockedHang, now: day1)?.detailed], [true, false],
                    "节流记账: 被压着的每天另有名额")
        let unthrottled = (0..<4).map { _ in throttling.noteHang(base, now: day1) }
        expectEqual(unthrottled.map { $0?.detailed }, [true, true, true, false], "节流记账: 被压着的不占没被压着的名额")
        var throttledDay = throttling.completedDays(before: d2).first
        expectEqual([throttledDay?.hangs, throttledDay?.throttledHangs], [6, 2], "节流记账: 次数照记,被压着的另记")
        expectEqual(throttledDay?.hangDetails.map { $0.throttled != nil }, [true, false, false, false], "节流记账: 概况各占各的名额")
        func mark(_ hang: Ticket?, _ reasons: [String]) {
            if let hang { throttling.markHangThrottled(reasons, for: hang) }
        }
        mark(unthrottled.last ?? nil, [MainThreadThrottle.locked])
        throttledDay = throttling.completedDays(before: d2).first
        expectEqual([throttledDay?.throttledHangs, throttledDay?.hangDetails.filter { $0.throttled != nil }.count], [3, 1],
                    "节流记账: 没占到名额的那次后来被压着,只补次数")
        // 名额占满之后只加次数的(锁屏一夜被压着的那一串)不每次当场写盘,攒着延后写(14 章决策 231)。
        let writesBeforeCountOnly = throttling.queuedWrites
        for _ in 0..<20 { _ = throttling.noteHang(lockedHang, now: day1) }
        expectEqual([throttling.queuedWrites - writesBeforeCountOnly, throttling.completedDays(before: d2).first?.hangs], [0, 26],
                    "节流记账: 名额占满后只加次数的不当场写盘,内存里次数照加")
        throttling.waitForPendingWrites()
        expectEqual(UserDefaults.standard.data(forKey: throttleKey)
                        .flatMap { try? JSONDecoder().decode([TelemetryActivityDay].self, from: $0) }?.first?.hangs, 26,
                    "节流记账: 攒着的次数延后一起落盘")
        throttling.clear()
        throttling.noteHang(nil, now: day1)
        let lateThrottled = throttling.noteHang(base, now: day1)
        mark(lateThrottled, [MainThreadThrottle.locked])
        mark(lateThrottled, [MainThreadThrottle.locked, MainThreadThrottle.lowPriority])
        finish(throttling, lateThrottled, 20)
        throttledDay = throttling.completedDays(before: d2).first
        expectEqual(throttledDay?.throttledHangs, 1, "节流记账: 卡住之后才被压着,补进次数只补一次")
        expectEqual(throttledDay?.hangDetails.first?.throttled, [MainThreadThrottle.locked, MainThreadThrottle.lowPriority],
                    "节流记账: 概况补上标记(并起来的全部)")
        expectEqual(throttledDay?.hangDetails.first?.duration, "10-30s", "节流记账: 补过标记之后恢复照样补时长")
        mark(throttling.noteHang(nil, now: day1), [MainThreadThrottle.locked])
        expectEqual(throttling.completedDays(before: d2).first?.throttledHangs, 2, "节流记账: 不带概况的那次后补次数,不碰旧的一条")
        let beforeClear = throttling.noteHang(nil, now: day1)
        throttling.clear()
        mark(beforeClear, [MainThreadThrottle.locked])
        expectEqual(throttling.completedDays(before: d2), [], "节流记账: 清空之后不凭空补出一天")
        _ = throttling.noteHang(lockedHang, now: day1)
        mark(throttling.noteHang(base, now: day1), [MainThreadThrottle.locked])
        expectEqual((0..<3).map { _ in throttling.noteHang(base, now: day1)?.detailed }, [true, true, false],
                    "节流记账: 后补成被压着的那条仍占着名额,两类合计不超过上限之和")
        expectEqual(throttling.completedDays(before: d2).first?.hangDetails.count,
                    TelemetryActivity.maxHangDetailsPerDay + TelemetryActivity.maxThrottledHangDetailsPerDay, "节流记账: 概况每天最多 3 + 1 条")
        throttling.clear()
        throttling.waitForPendingWrites()
    }

    do {
        print("\n== 遥测:卡顿概况里的设置页 ==")
        typealias H = TelemetryHang
        // 名单 = 深链的每一页 + 有分段的页的每个分段(取跟存的值同名的那个链接名,别名不算)。
        let pagePaths = SettingsDeepLink.tabNames + SettingsDeepLink.Account.allCases.map { "account/" + $0.rawValue }
            + ["software-update", "lastfm-suggestions", "labs"]
        func linkName(_ value: String) -> String {
            value.reduce(into: "") { out, ch in out += ch.isUppercase ? "-" + ch.lowercased() : String(ch) }
        }
        var derived = pagePaths
        for (page, entry) in SettingsDeepLink.sectionTable.sorted(by: { $0.key < $1.key }) {
            for value in Set(entry.values.values).sorted() {
                expectEqual(entry.values[linkName(value)], value, "设置页: \(page) 的分段 \(value) 有同名的链接名")
                derived.append(page + "/" + linkName(value))
            }
        }
        expectEqual(H.settingsPages.sorted(), derived.sorted(), "设置页: 名单 = 深链的每一页 + 每个分段(深链加了页或分段,这份名单和 Worker 要跟着加)")
        expectEqual(Set(H.settingsPages).count, H.settingsPages.count, "设置页: 名单不重复")
        expectEqual(pagePaths.filter { SettingsDeepLink(path: $0) == nil }, [], "设置页: 每一页都是认得出的深链路径")
        expectEqual([H.settingsPage(path: "account/lastfm", section: "stats"), H.settingsPage(path: "appearance", section: "menuBar"),
                     H.settingsPage(path: "appearance", section: "overlay"), H.settingsPage(path: "appearance", section: "lyricsWindow"),
                     H.settingsPage(path: "lyrics", section: "fetch"), H.settingsPage(path: "account/lastfm", section: "onThisDay")],
                    ["account/lastfm/stats", "appearance/menu-bar", "appearance/overlay", "appearance/lyrics-window", "lyrics/fetch",
                     "account/lastfm/on-this-day"], "设置页: 分段取值换成深链里的正名,不取别名")
        expectEqual([H.settingsPage(path: "lyrics", section: "bogus"), H.settingsPage(path: "general", section: nil),
                     H.settingsPage(path: "general", section: "x"), H.settingsPage(path: "account/bark", section: nil),
                     H.settingsPage(path: "nope", section: nil), H.settingsPage(path: "/Users/me", section: "stats")],
                    ["lyrics", "general", "general", "account/bark", nil, nil], "设置页: 分段认不出只报到页,页认不出不报")
        let unmapped = SettingsDeepLink.sectionTable.flatMap { page, entry in
            entry.values.values.filter { value in
                H.settingsPage(path: page, section: value).map { !$0.hasPrefix(page + "/") || !H.settingsPages.contains($0) } ?? true
            }.map { page + ":" + $0 }
        }
        expectEqual(unmapped, [], "设置页: 每个分段取值都报得出名单里的「页/分段」")

        let snapshot = SettingsPageSnapshot()
        snapshot.set("account/lastfm/stats")
        let kept = snapshot.current
        snapshot.set("/Users/me/Music")
        let unknown = snapshot.current
        snapshot.set("lyrics/display")
        let changed = snapshot.current
        snapshot.set(nil)
        expectEqual([kept, unknown, changed, snapshot.current], ["account/lastfm/stats", nil, "lyrics/display", nil],
                    "设置页快照: 换页时写进去、读得回来,名单外的记成空,关窗清空")

        // 主线程卡住时看门狗照样拿得到:主线程在这里等着(= 卡住),概况在后台线程上算;回头问主线程的话等不到。
        final class Slot: @unchecked Sendable { var page: String? }
        let slot = Slot()
        let dog = MainThreadWatchdog(probeInterval: 60, stallThreshold: 60, sampleAfter: 60, onEvent: { _ in })
        SettingsPageSnapshot.shared.set("account/lastfm/stats")
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            slot.page = dog.currentHangContext().settingsPage
            done.signal()
        }
        let answered = done.wait(timeout: .now() + 0.5) == .success
        expectEqual([Thread.isMainThread, answered], [true, true], "设置页: 主线程卡住时,看门狗不问主线程就算得出概况")
        expectEqual(answered ? slot.page : nil, "account/lastfm/stats", "设置页: 概况带上快照里的设置页")
        if answered {
            SettingsPageSnapshot.shared.set(nil)
            expectEqual(dog.currentHangContext().settingsPage, nil, "设置页: 设置窗口关着时概况不带")
        }
        expectEqual([MainThreadWatchdog.settingsPageLogNote("account/lastfm/stats"), MainThreadWatchdog.settingsPageLogNote(nil)],
                    [" (settings page account/lastfm/stats)", ""], "设置页: 日志行尾带页名,窗口关着时不带")
        let oldHang = #"{"duration":"5-10s","since_launch":"<1m","windows":["settings"],"thermal":"nominal","stack":[]}"#
        expectEqual((try? JSONDecoder().decode(H.self, from: Data(oldHang.utf8))).map { $0.settingsPage == nil }, true,
                    "设置页: 旧版本存下的概况没有设置页")
        var withPage = H(sinceLaunch: "<1m", sinceWake: nil, windows: ["settings"], thermal: "nominal")
        withPage.settingsPage = "account/lastfm/stats"
        expectEqual((try? JSONEncoder().encode(withPage)).flatMap { try? JSONDecoder().decode(H.self, from: $0) }, withPage,
                    "设置页: 概况能存能读")
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
        for _ in 0..<7 { activity.noteLayoutLimit(window: "onboarding", windowClass: "SwiftUI.AppKitWindow", pass: "layout", now: day1) }
        let pendingBeforeFlush = activity.hasPendingWrites
        let flushed = DispatchSemaphore(value: 0)
        let flushQueue = DispatchQueue(label: "selftest.telemetry-flush")
        activity.flushPendingWrites(timeout: 2, notifying: flushQueue) { flushed.signal() }
        let flushedInTime = flushed.wait(timeout: .now() + 2) == .success
        let afterFlush = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([TelemetryActivityDay].self, from: $0) }
        expectEqual([pendingBeforeFlush, flushedInTime, activity.hasPendingWrites], [true, true, false],
                    "超限记账: 退出用的 flushPendingWrites 把攒着的延后写当场写掉,写完回调、不留没落盘的")
        expectEqual(afterFlush?.first?.layoutLimits.first?.count, 510, "超限记账: 退出前写掉的那次带上攒下的次数")
        // 当天记满几种之后新的一种、次数封顶之后,数据不变就不写盘,也不排延后写(14 章决策 231)。
        let writesWhenFull = activity.queuedWrites
        for _ in 0..<500 { activity.noteLayoutLimit(window: nil, windowClass: "Unlisted", pass: "display", now: day1) }
        expectEqual([activity.queuedWrites - writesWhenFull, activity.hasPendingWrites ? 1 : 0], [0, 0],
                    "超限记账: 记满几种之后新的一种每帧都来,不写盘")
        for _ in 0..<10_000 { activity.noteLayoutLimit(window: nil, windowClass: "NSPanel", pass: "update-constraints", now: day1) }
        activity.waitForPendingWrites()
        let writesWhenCapped = activity.queuedWrites
        for _ in 0..<200 { activity.noteLayoutLimit(window: nil, windowClass: "NSPanel", pass: "update-constraints", now: day1) }
        expectEqual([activity.queuedWrites - writesWhenCapped, activity.hasPendingWrites ? 1 : 0,
                     activity.completedDays(before: d2).first?.layoutLimits.first { $0.windowClass == "NSPanel" }?.count],
                    [0, 0, 10_000], "超限记账: 次数封顶之后不再写盘")
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
        let terminate = sourceBody("func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {",
                                   in: text("lyrimuse/AppDelegate.swift"))
        expectEqual(sourceHas(terminate, "guard saveConfig || TelemetryActivity.shared.hasPendingWrites else { return .terminateNow }")
                    && sourceHas(terminate, "TelemetryActivity.shared.flushPendingWrites(timeout: 1) {")
                    && !terminate.contains("waitForPendingWrites"), true,
                    "超限(契约): 退出前把遥测攒着的写盘写掉,主线程只异步等、最多 1 秒(同步等会跟写盘互相等死)")
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
        throttledHang.memoryPressure = HangMemory.warning
        throttledHang.pageins = 0
        throttledHang.mainCPUMilliseconds = 0
        expectEqual(Set(keys(throttledHang)).subtracting(keys(hang)).sorted(), ["main_cpu_ms", "memory_pressure", "pageins", "throttled"],
                    "卡顿概况: 读到内存情况和主线程 CPU 时间时带 memory_pressure、pageins、main_cpu_ms(0 也带),读不到时不带")
        var versionedHang = hang
        versionedHang.appVersion = "1.14.0"
        expectEqual(Set(keys(versionedHang)).subtracting(keys(hang)).sorted(), ["app_version"],
                    "卡顿概况: 带记卡顿时的版本 app_version,取不到时不带")
        var simulatedKeyHang = hang
        simulatedKeyHang.simulated = true
        expectEqual(Set(keys(simulatedKeyHang)).subtracting(keys(hang)).sorted(), ["simulated"],
                    "卡顿概况: 调试造的停顿带 simulated,真卡顿不带")
        var pagedHang = hang
        pagedHang.settingsPage = "lyrics/display"
        expectEqual(Set(keys(pagedHang)).subtracting(keys(hang)).sorted(), ["settings_page"],
                    "卡顿概况: 设置窗口开着时带 settings_page,关着不带")
        expectEqual(sourceHas(worker, "settings_page: oneOf(h.settings_page, HANG_SETTINGS_PAGES),")
                        && sourceHas(worker, "h.main_cpu_ms, h.simulated, h.settings_page)));")
                        && sourceHas(worker, "settings_page: countBy(parsed, (h) => settingsPageBucket(h)),"),
                    true, "Worker: 设置页按名单收、入库,统计带分布")
        expectEqual(sourceHas(worker, "simulated: h.simulated === true ? 1 : null,")
                        && sourceHas(worker, "FROM hang_events WHERE day >= ?1 AND simulated IS NOT 1")
                        && sourceHas(worker, "h.memory_pressure, h.pageins, h.main_cpu_ms, h.simulated, h.settings_page)));")
                        && sourceHas(worker, "hangs + simulatedDetails));"),
                    true, "Worker: 模拟的卡顿概况照存(simulated = 1),统计读概况时跳过")
        expectEqual(sourceHas(worker, "app_version: str(h.app_version, 32),") && sourceHas(worker, "h.app_version ?? e.app_version"), true,
                    "Worker: 卡顿概况的版本先取概况自己带的,旧版 App 不带时退回心跳的")
        expectEqual(sourceHas(worker, "return quotaIPKey(request.headers.get(\"cf-connecting-ip\"));")
                    && sourceHas(worker, "env.INGEST_LIMITER.limit({ key: clientIP(request) })")
                    && !worker.contains("limit({ key: ip })"), true,
                    "Worker: 入口限流和按 IP 的硬限额都按 quotaIPKey 计(IPv6 取前缀),行为单测在 telemetry-worker/test")
        let fields = keys(regional) + keys(features) + keys(TelemetryActivityDay(day: "2026-10-30")) + keys(throttledHang) + keys(pagedHang)
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
        expectEqual(workerList("HANG_SETTINGS_PAGES"), TelemetryHang.settingsPages.sorted(),
                    "Worker: 设置页的取值名单跟 Core TelemetryHang.settingsPages 一致(加了页两处一起改)")
        expectEqual(sourceHas(worker, "const HANG_MEMORY_PRESSURE = [" + HangMemory.pressureLevels.map { "\"\($0)\"" }.joined(separator: ", ") + "];")
                        && worker.contains("const MAX_HANG_PAGEINS = \(HangMemory.maxPageins);"),
                    true, "Worker: 内存压力档位(从松到紧)、换页次数上限跟 Core 一致")
        expectEqual(worker.contains("const MAX_HANG_MAIN_CPU_MS = \(MainThreadCPU.maxMilliseconds);")
                        && sourceHas(worker, "main_cpu_ms: int(h.main_cpu_ms, 0, MAX_HANG_MAIN_CPU_MS),")
                        && sourceHas(worker, "h.memory_pressure, h.pageins, h.main_cpu_ms, h.simulated, h.settings_page)));"),
                    true, "Worker: 主线程 CPU 时间按毫秒收 0~上限的整数(上限跟 Core 一致),入库")
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
        // 引擎会写进条目 lyrics_source 的值:十六个歌词源(登记表里的联网源,冻结在 lyricsourceexpect_test.go 的 lyricSourceNames)
        // 和各本机来源常量(`const …LyricsSource = "…"`)。
        // 漏了的会在遥测里全记成 other。
        let engineDir = root.appendingPathComponent("../../lyrimuse-engine")
        let expectGo = (try? String(contentsOf: engineDir.appendingPathComponent("lyricsourceexpect_test.go"), encoding: .utf8)) ?? ""
        var engineSources: [String] = []
        if let start = expectGo.range(of: "var lyricSourceNames = []string{"), let end = expectGo[start.upperBound...].range(of: "}") {
            engineSources = expectGo[start.upperBound..<end.lowerBound].split(separator: ",").map {
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
        expectEqual(sourceHas(handleBody, "let context = hangContext(at: now, throttle: throttle, probeSentAt: probeSentAt)")
                        && sourceHas(handleBody, "let hang = hangs.stalled(context)")
                        && sourceHas(handleBody, "hangs.recovered(seconds: seconds, memoryPressure: memory.pressure, pageins: pageins, mainCPUMilliseconds: mainCPU)")
                        && sourceHas(sourceBody("case .recovered(let seconds, let throttle):", in: handleBody), "if tracker.reportedStill {")
                        && sourceHas(handleBody, "hangs.throttled(throttle.sorted())")
                        && sourceHas(watchdog, "private var hangs = HangLedger(activity: .shared)"),
                    true, "接线: 主线程卡住记一笔概况(带节流标记),恢复时补时长(没卡满的不补),卡住之后才被压着的补标记,都按回执补")
        // 调试造的停顿(14 章决策 240):概况按探测投出时刻认模拟的,日志带说明;深链和启动参数都走 simulateStall。
        let debugLinks = sourceText("lyrimuse/Settings/DebugDeepLinks.swift")
        expectEqual(sourceHas(sourceBody("private func hangContext(", in: watchdog), "simulated: isSimulated(probeSentAt: probeSentAt) ? true : nil,")
                        && sourceHas(handleBody, "+ Self.simulatedLogNote(context.simulated == true)")
                        && sourceHas(handleBody, "+ Self.simulatedLogNote(isSimulated(probeSentAt: probeSentAt))")
                        && sourceHas(debugLinks, "MainThreadWatchdog.shared.simulateStall(seconds: seconds, busy: busy,")
                        && sourceHas(sourceBody("static func runIfRequested(", in: debugLinks), "MainThreadWatchdog.shared.simulateStall(seconds: seconds)")
                        && !debugLinks.contains("Thread.sleep(forTimeInterval: seconds)"),
                    true, "接线: 调试造的停顿走 simulateStall,概况带 simulated、日志带说明")
        let tickBody = sourceBody("private func tick()", in: watchdog)
        let answerBody = sourceBody("private func takeAnswer()", in: watchdog)
        let takeAnswerAt = tickBody.range(of: "takeAnswer()")
        let throttleAt = tickBody.range(of: "if sentAt != nil { observeStall(at: now, probeSentAt: sentAt) }")
        let checkAt = tickBody.range(of: "tracker.check(now: now)")
        expectEqual(throttleAt != nil && checkAt != nil && throttleAt!.lowerBound < checkAt!.lowerBound
                        && sourceHas(answerBody, "if answeredAt - sentAt >= tracker.stallThreshold { observeStall(at: answeredAt, probeSentAt: sentAt) }"),
                    true, "接线: 探测过了一拍还没被执行到时先读节流状态再判卡顿,卡过阈值后被执行到时再读一次")
        expectEqual(takeAnswerAt != nil && takeAnswerAt!.lowerBound < checkAt!.lowerBound
                        && sourceHas(tickBody, "answer.put(ProbeAnswerBox.Answer(sentAt: now, answeredAt: answeredAt, mainCPU: mainCPU, windows: windows))"),
                    true, "接线: 主线程执行到探测先记下,定时器那一拍判卡顿前先处理它(差一点卡满 5 秒的不报成卡顿)")
        // 看门狗队列上不同步问 WindowServer(14 章决策 231):锁屏读通知维护的标志位。
        let throttleSource = sourceText("LyrimuseCore/Diagnostics/MainThreadThrottle.swift")
        expectEqual(sourceHas(sourceBody("public static func read(thread: mach_port_t?) -> Reading", in: throttleSource),
                              "ScreenLockState.shared.isLocked")
                        && !sourceBody("public static func read(thread: mach_port_t?) -> Reading", in: throttleSource).contains("screenIsLocked()")
                        && !sourceBody("private func observeStall(", in: watchdog).contains("screenIsLocked")
                        && sourceHas(sourceBody("public func start()", in: watchdog), "ScreenLockState.shared.start()"),
                    true, "接线: 看门狗读节流不碰 CGSessionCopyCurrentDictionary,锁屏状态由通知维护、看门狗启动时开始听")
        expectEqual(sourceHas(sourceBody("private func hangContext(", in: watchdog), "throttled: throttle.isEmpty ? nil : throttle.sorted()"),
                    true, "接线: 卡顿概况带上停顿期间看到的节流标记")
        // 卡顿期间的内存情况(14 章决策 222):投探测时记下换页累计,停顿期间读内存压力的时机跟节流读数相同。
        let probeAt = tickBody.range(of: "guard tracker.shouldProbe(now: now) else { return }")
        let baselineAt = tickBody.range(of: "memory = HangMemory.Stall(pageinsAtStart: HangMemory.readPageins())")
        expectEqual(probeAt != nil && baselineAt != nil && probeAt!.upperBound <= baselineAt!.lowerBound
                        && sourceHas(sourceBody("private func observeStall(", in: watchdog), "memory.observe(pressure: HangMemory.readPressure())")
                        && sourceHas(sourceBody("private func hangContext(", in: watchdog),
                                     "memoryPressure: memory.pressure, pageins: memory.pageins(now: HangMemory.readPageins()),")
                        && sourceHas(sourceBody("private func hangContext(", in: watchdog), "appVersion: TelemetryHang.currentAppVersion")
                        && sourceHas(sourceBody("case .recovered(let seconds, let throttle):", in: handleBody),
                                     "let pageins = memory.pageinsExcludingSample(now: HangMemory.readPageins())"),
                    true, "接线: 每次投探测记下换页累计,停顿期间读内存压力,报卡顿和恢复时各取一次换页差值(恢复时扣掉采栈的)记进概况,带上记卡顿时的版本")
        // 主线程 CPU 时间(14 章决策 238):投探测时按主线程端口记起点,报卡顿时取到那一刻的差值,恢复时取主线程执行到探测时自己读的。
        let cpuBaselineAt = tickBody.range(of: "mainCPUAtStart = MainThreadCPU.readMicroseconds(thread: mainThread)")
        expectEqual(probeAt != nil && cpuBaselineAt != nil && probeAt!.upperBound <= cpuBaselineAt!.lowerBound
                        && sourceHas(sourceBody("public func start()", in: watchdog), "pthread_mach_thread_np(pthread_self())")
                        && sourceHas(tickBody, "let mainCPU = MainThreadCPU.readMicrosecondsOnCurrentThread()")
                        && sourceHas(answerBody, "handle(event, at: answeredAt, probeSentAt: sentAt, mainCPUNow: answered.mainCPU)")
                        && sourceHas(sourceBody("case .recovered(let seconds, let throttle):", in: handleBody),
                                     "let mainCPU = MainThreadCPU.millisecondsBetween(mainCPUAtStart, mainCPUNow)")
                        && sourceHas(sourceBody("private func hangContext(", in: watchdog),
                                     "mainCPUMilliseconds: MainThreadCPU.millisecondsBetween(mainCPUAtStart, MainThreadCPU.readMicroseconds(thread: mainThread)),"),
                    true, "接线: 投探测时记下主线程累计 CPU 时间,报卡顿、恢复时各取一次差值记进概况")
        let sampleBody = sourceBody("private func takeSample(for hang: TelemetryActivity.HangTicket?)", in: watchdog)
        let beforeSampleAt = sampleBody.range(of: "let pageinsBefore = HangMemory.readPageins()")
        let runSampleAt = sampleBody.range(of: #"ProcessRunner.run("/usr/bin/sample""#)
        let afterSampleAt = sampleBody.range(of: "let samplePageins = HangMemory.pageinsBetween(pageinsBefore, HangMemory.readPageins())")
        expectEqual(beforeSampleAt != nil && runSampleAt != nil && afterSampleAt != nil
                        && beforeSampleAt!.lowerBound < runSampleAt!.lowerBound && runSampleAt!.lowerBound < afterSampleAt!.lowerBound
                        && sourceHas(sampleBody, "memory.sampleStarted()")
                        && sourceHas(sourceBody("private func sampleFinished(", in: watchdog), "memory.sampleFinished(pageins: pageins)"),
                    true, "接线: 采栈前后在采样队列上各读一次换页累计,回报给这次停顿")
        expectEqual(sourceHas(sampleBody,
                              "TelemetryActivity.shared.attachHangStack(TelemetryHang.mainThreadStack(fromSample: text, executable: executable), to: hang)")
                        && sourceHas(handleBody, "takeSample(for: hang)")
                        && sourceHas(sourceBody("private func tick()", in: watchdog), "wake.observe(uptime: now, continuous: WakeDetector.continuousNow)")
                        && sourceHas(answerBody, "if let windows = answered.windows { lastWindows = windows }"),
                    true, "接线: 采样按报卡顿时的回执补调用栈、每拍认唤醒、主线程还能动时记下开着的窗口")
        expectEqual(sourceHas(sourceText("lyrimuse/AppDelegate.swift"), "MainThreadWatchdog.shared.setWindowProvider {"), true,
                    "接线: App 给看门狗窗口提供者")
        // 设置页(14 章决策 241):设置窗口根视图求值时写快照、关窗清空,看门狗报卡顿时读快照,日志带页名。
        let settingsView = sourceText("lyrimuse/SettingsView.swift")
        let settingsRoot = settingsView.range(of: "struct SettingsView: View {").map { String(settingsView[$0.lowerBound...]) } ?? ""
        let rootBody = sourceBody("var body: some View {", in: settingsRoot)
        let pathBody = sourceBody("var deepLinkPath: String {", in: settingsView)
        let literalRE = try? NSRegularExpression(pattern: #""([^"]+)""#)
        let pathLiterals = (literalRE?.matches(in: pathBody, range: NSRange(pathBody.startIndex..., in: pathBody)) ?? [])
            .compactMap { Range($0.range(at: 1), in: pathBody).map { String(pathBody[$0]) } }.filter { $0 != "account/" }
        expectEqual(sourceHas(rootBody, "let _ = SettingsPageSnapshot.shared.set(telemetryPage)")
                        && sourceHas(sourceBody(".onDisappear {", in: rootBody), "SettingsPageSnapshot.shared.set(nil)")
                        && sourceHas(sourceBody("private var telemetryPage: String? {", in: settingsRoot),
                                     "TelemetryHang.settingsPage(path: location.panel.deepLinkPath, section: location.section)"),
                    true, "接线: 设置窗口根视图求值时把当前页写进快照,关窗清空")
        expectEqual(sourceHas(pathBody, "case .tab(let tab): return tab.rawValue") && pathLiterals.count == 3
                        && pathLiterals.allSatisfy(TelemetryHang.settingsPages.contains)
                        && SettingsDeepLink.Account.allCases.allSatisfy { sourceHas(pathBody, "SettingsDeepLink.Account.\($0.rawValue).rawValue") },
                    true, "接线: 侧栏目的地换成深链路径,每个都在设置页名单里")
        expectEqual(sourceHas(sourceBody("private func hangContext(", in: watchdog), "settingsPage: SettingsPageSnapshot.shared.current)")
                        && sourceHas(handleBody, "+ Self.settingsPageLogNote(context.settingsPage)"),
                    true, "接线: 报卡顿时从快照读设置页(不问主线程),unresponsive 那行日志带页名")
        // 偏好变更的观察者不能让后台线程写偏好时同步等主线程(14 章决策 175、231):全仓只有 UserDefaultsChangeRelay 直接登记。
        var directObservers: [String] = []
        if let files = FileManager.default.enumerator(atPath: root.path) {
            for case let rel as String in files where rel.hasSuffix(".swift") && !rel.hasPrefix("lyrimuse-selftest/")
                && rel != "LyrimuseCore/Util/UserDefaultsChangeRelay.swift" {
                let lines = sourceText(rel).split(separator: "\n")
                if lines.contains(where: { line in
                    !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") && line.contains("UserDefaults.didChangeNotification")
                }) { directObservers.append(rel) }
            }
        }
        expectEqual(directObservers, [], "接线: 没有绕过 UserDefaultsChangeRelay 直接听偏好变更通知的")
        expectEqual(sourceHas(sourceBody("static func startObserving()", in: sourceText("lyrimuse/Settings/AppSettingsMirror.swift")),
                              "UserDefaultsChangeRelay.observe(.standard) {")
                        && sourceHas(sourceText("LyrimuseCore/Util/UserDefaultsChangeRelay.swift"),
                                     "addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: nil)"), true,
                    "接线: 设置镜像听偏好变更走 UserDefaultsChangeRelay(回调登记在发通知的线程上)")
        expectEqual(sourceHas(sourceText("LyrimuseCore/Telemetry/TelemetryActivity.swift"),
                              "public static let shared = TelemetryActivity(defaults: .standard, recording: .undecided)"), true,
                    "接线: App 的记账启动时开关未定,看门狗先报的卡顿等 TelemetryService 定下来再写")
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
        expectEqual(sourceHas(crashes, "var ledger = TelemetryCrashLedger.load(from: defaults, keys: Keys.crashLedger)")
                    && sourceHas(crashes, "await ledger.send(reports, today: today, post: { summary in")
                    && sourceHas(crashes, "}, save: { $0.save(to: self.defaults, keys: Keys.crashLedger) })"), true,
                    "接线: 崩溃报告按记账发(只有负载不合格才记为发过,同一份连着服务器出错几次就跳过),每份有了结果就存")
        expectEqual(sourceHas(sourceBody("func start()", in: service), "TelemetryActivity.shared.sentBefore = defaults.string(forKey: Keys.lastHeartbeatDay)")
                    && sourceHas(sourceBody("func checkNow() async", in: service),
                                 "defaults.set(today, forKey: Keys.lastHeartbeatDay)\nTelemetryActivity.shared.sentBefore = today"), true,
                    "接线: 上次发心跳那天同步给活动记账,更早的日子不再记")
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
        expectEqual(sourceHas(machineLocal, "TelemetryService.Keys.crashServerFailures,"), true, "接线: 崩溃报告的出错计次是机器专属的")
        let clearAll = sourceBody("static func clearAllConfig() async -> Bool", in: portability)
        let stopAt = clearAll.range(of: "TelemetryActivity.shared.isRecording = false")?.lowerBound
        let loopAt = clearAll.range(of: "for key in UserDefaults.standard.dictionaryRepresentation().keys {")?.lowerBound
        let wipeAt = clearAll.range(of: "TelemetryActivity.shared.clear()")?.lowerBound
        expectEqual(stopAt != nil && loopAt != nil && wipeAt != nil && stopAt! < loopAt! && loopAt! < wipeAt!, true,
                    "接线: 清除所有设置先停记遥测活动、删完偏好键再清空内存里那份")
        let delegate = sourceText("lyrimuse/AppDelegate.swift")
        if let a = delegate.range(of: "TelemetryService.shared.start()"), let b = delegate.range(of: "WhatsNewCenter.shared.start()") {
            expectEqual(a.lowerBound < b.lowerBound, true, "接线: 遥测先于更新提示启动(判定读的是上次启动留下的版本记录)")
        } else {
            expectEqual(false, true, "接线: 找得到遥测和更新提示的启动调用")
        }
        expectEqual(sourceHas(sourceBody("func start()", in: service), "decideInstallOrigin()"), true, "接线: 启动时判新装还是升级")
        let decideAt = delegate.range(of: "TelemetryService.decideRecordingAtLaunch()")?.lowerBound
        let watchdogAt = delegate.range(of: "MainThreadWatchdog.shared.start()")?.lowerBound
        let launchStallAt = delegate.range(of: "DebugLaunchStall.runIfRequested()")?.lowerBound
        let serviceAt = delegate.range(of: "TelemetryService.shared.start()")?.lowerBound
        expectEqual(decideAt != nil && watchdogAt != nil && launchStallAt != nil && serviceAt != nil
                    && decideAt! < watchdogAt! && watchdogAt! < launchStallAt! && launchStallAt! < serviceAt!, true,
                    "接线: 看门狗起来之前按偏好定遥测开关;调试用的启动停顿在看门狗之后、遥测服务之前")
        expectEqual(sourceHas(sourceBody("static func decideRecordingAtLaunch()", in: service),
                              "TelemetryActivity.shared.decideFromPreferences(enabledKey: Keys.enabled, lastHeartbeatDayKey: Keys.lastHeartbeatDay)")
                    && sourceHas(service, "static let enabled = \"np:telemetryEnabled\"")
                    && sourceHas(settings, "static let telemetryEnabled = \"np:telemetryEnabled\""), true,
                    "接线: 启动时提前定开关读的是设置「发送匿名使用数据」同一个偏好键")

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
                    && sourceHas(sourceBody("private func noteLyricsTelemetry(", in: source), "let shown = result == .plain ? plainSource : source"),
                    true, "接线: 来源取显示的那份(播放器自家那份优先),纯文本档取纯文本的来源")
        let lyricsNote = sourceBody("private func noteLyricsTelemetry(", in: source)
        expectEqual(sourceHas(lyricsNote, "Self.telemetryQueue.async {\nlet language: TelemetrySongLanguage?\nif result == .plain {")
                    && sourceHas(lyricsNote, "let script = Romanizer.songScript(of: plain)\nlanguage = TelemetrySongLanguage(")
                    && sourceHas(lyricsNote, "language = sample.map { TelemetrySongLanguage(script: $0.script, text: $0.text) }")
                    && !sourceHas(lyricsNote, "language = syncEngine.telemetryLanguage"), true,
                    "接线: 歌词语言在后台队列上判,主线程只取样本(系统认语言每次现装模型)")
        let window = sourceText("lyrimuse/UI/LyricsWindowView.swift")
        expectEqual(sourceHas(sourceBody("static func markOpen()", in: window), "guard LyricsWindowOpenRecord.markOpen(.standard, invisibly: invisibly) else { return }")
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
