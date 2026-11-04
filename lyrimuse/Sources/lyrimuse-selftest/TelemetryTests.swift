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
        activity.noteLyricsResult(track: "a", result: .word, language: .zh, now: day1)
        expectEqual(activity.completedDays(before: "9999-12-31"), [], "歌词结果: 关着时不记")
        activity.isRecording = true
        activity.noteLyricsResult(track: "a", result: .line, language: .zh, now: day1)
        activity.noteLyricsResult(track: "a", result: .line, language: .zh, now: day1)
        activity.noteLyricsResult(track: "b", result: .none, language: nil, now: day1)
        activity.noteLyricsResult(track: "c", result: .word, language: .en, now: day1)
        var got = activity.completedDays(before: d2).first
        expectEqual(got?.lyrics, ["line": 1, "none": 1, "word": 1], "歌词结果: 同一首一天只算一次")
        expectEqual(got?.languages, ["zh": 1, "en": 1], "歌词结果: 没歌词的歌不记语言")
        activity.noteLyricsResult(track: "a", result: .word, language: .yue, now: day1)
        activity.noteLyricsResult(track: "b", result: .line, language: .ja, now: day1)
        got = activity.completedDays(before: d2).first
        expectEqual(got?.lyrics, ["word": 2, "line": 1], "歌词结果: 结果变了挪到新的一档,不多算一首")
        expectEqual(got?.languages, ["yue": 1, "en": 1, "ja": 1], "歌词结果: 语言跟着挪")
        activity.noteLyricsResult(track: "a", result: .word, language: .yue, now: day2)
        expectEqual(activity.completedDays(before: "9999-12-31").last?.lyrics, ["word": 1], "歌词结果: 换天重新算")
        activity.clear()
        activity.noteLyricsResult(track: "a", result: .word, language: .yue, now: day2)
        expectEqual(activity.completedDays(before: "9999-12-31").first?.lyrics, ["word": 1], "歌词结果: 清空后重新记")
        activity.clear()
        expectEqual(LyricsKind.allCases.map { TelemetryLyricsResult($0).rawValue },
                    ["word", "line", "plain", "instrumental", "none"], "歌词结果: 跟 LyricsKind 一一对应")
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
                                         settingsChanged: ["notchGestures"], permissionsMissing: ["automation.apple_music"])
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
        expectEqual(keys(env), ["app_version", "arch", "build", "os_version", "system_language", "ui_language"], "心跳: env 键")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let worker = (try? String(contentsOfFile: root.appendingPathComponent("../../telemetry-worker/src/index.js").path,
                                  encoding: .utf8)) ?? ""
        let fields = keys(env) + keys(features) + keys(TelemetryActivityDay(day: "2026-10-30"))
            + ["install_id", "origin", "report_id", "exception_type", "termination_indicator", "frames", "exception_frames"]
            + TelemetryAction.allCases.map(\.rawValue)
        expectEqual(["install_method", "settings_changed", "permissions_missing"].allSatisfy(keys(features).contains),
                    true, "心跳: 功能快照带安装渠道、改过的设置、缺的权限")
        let missing = fields.filter { !worker.contains($0) }
        expectEqual(missing, [], "Worker: 认得 App 发的每个字段")
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
        expectEqual(sourceHas(sourceText("LyrimuseCore/Diagnostics/MainThreadWatchdog.swift"),
                              "TelemetryActivity.shared.noteHang()"), true, "接线: 主线程卡住记一笔")
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
