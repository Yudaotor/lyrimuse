import LyrimuseCore
import Foundation

// 身份与落盘路径:LyrimuseIdentity 的那一套名字、LyrimusePaths / LogFiles 的派生、传给引擎的环境变量。
// 加;同日第二步的「Lyrimuse Dev」变体整体回退,这里随之只剩
// 一套名字(15 章决策 12)。由 main.swift 的注册表按组调用。

@MainActor
func runIdentityTests() {
    do {
        print("\n== 身份与路径 ==")
        let id = LyrimuseIdentity.current
        expectEqual(id.displayName, "Lyrimuse", "身份: 名字")
        expectEqual(id.bundleIdentifier, "me.yudaotor.lyrimuse", "身份: bundle id(TCC / UserDefaults 域 / App LaunchAgent label 都按它)")
        expectEqual(id.appLaunchdLabel, id.bundleIdentifier, "身份: App 的 launchd label 就是 bundle id")
        expectEqual(id.configDirName, "lyrimuse", "身份: 配置目录名")
        expectEqual(id.engineLaunchdLabel, "com.lyrimuse.collector", "身份: 引擎 label(build.sh / uninstall.sh 里的字面量要跟它一致)")
        expectEqual(id.engineExecutableName, "lyrimuse-engine", "身份: 引擎的可执行文件名(build.sh / package.sh 里的字面量要跟它一致)")
        expectEqual(id.engineExecutableName.utf8.count <= 16, true, "身份: 引擎进程名不超过 16 字节(内核 p_comm 上限,超了 pgrep -x 对不上)")
        expectEqual(LyrimuseIdentity.engineProcessNames, ["lyrimuse-engine", "collector"], "身份: 认引擎进程的名字,新名在前、旧名留着认旧崩溃报告")
        expectEqual(id.logFileName, "lyrimuse.log", "身份: 引擎日志名")
        expectEqual(id.appLogFileName, "lyrimuse-app.log", "身份: App stderr 日志名")
        expectEqual(id.defaultAppBundlePath, "/Applications/Lyrimuse.app", "身份: 默认装到 /Applications")
        expectEqual(id.urlScheme, "lyrimuse", "身份: URL scheme(Last.fm 授权回调)")
        expectEqual(id.logFileName, id.configDirName + ".log", "身份: 引擎日志名 = 目录名 + .log(uninstall.sh 靠这条规则拼)")
        expectEqual(id.appLogFileName, id.configDirName + "-app.log", "身份: App 日志名 = 目录名 + -app.log")
        expectEqual(id.mainThreadStallFileName, id.configDirName + "-main-thread-stall.txt",
                    "身份: 主线程卡顿采样文件名 = 目录名 + -main-thread-stall.txt")
        expectEqual(LyrimuseIdentity.displayName, id.displayName, "身份: 便捷静态属性与 current 一致")
        expectEqual(LyrimuseIdentity.engineLaunchdLabel, id.engineLaunchdLabel, "身份: 便捷静态属性与 current 一致(label)")
        expectEqual(LyrimuseIdentity.engineExecutableName, id.engineExecutableName, "身份: 便捷静态属性与 current 一致(引擎名)")
        expectEqual(LyrimusePaths.bundledEnginePath.hasSuffix("/Contents/Resources/lyrimuse-engine"), true, "路径: 包里的引擎二进制")

        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        expectEqual(LyrimusePaths.configDir, StorageLayout.activeDataDir(LyrimusePaths.storageRoots),
                    "路径: 数据目录按 StorageLayout 的规则选(本机搬没搬都对)")
        expectEqual(LyrimusePaths.configFile("config.json"), LyrimusePaths.configDir.appendingPathComponent("config.json"), "路径: 数据目录下的文件")
        expectEqual(LyrimusePaths.cachesDir.path, homePath + "/Library/Caches/me.yudaotor.lyrimuse", "路径: 缓存目录 = ~/Library/Caches/<bundle id>")
        expectEqual(LyrimusePaths.cacheFile("motion-covers").path, homePath + "/Library/Caches/me.yudaotor.lyrimuse/motion-covers",
                    "路径: 缓存目录下的子目录")
        expectEqual(LogFiles.engine.path, homePath + "/Library/Logs/lyrimuse.log", "路径: 引擎日志")
        expectEqual(LogFiles.appStderr.path, homePath + "/Library/Logs/lyrimuse-app.log", "路径: App stderr 日志")
        expectEqual(LyrimusePaths.launchAgentPlist(label: "x.y").path, homePath + "/Library/LaunchAgents/x.y.plist", "路径: LaunchAgent plist")
        expectEqual(LyrimusePaths.defaultAppBundleURL.path, "/Applications/Lyrimuse.app", "路径: 默认安装位置")

        // 传给引擎的环境变量:四个键、值就是上面的路径与 bundle id;叠在继承环境上、不丢父进程的变量、同名覆盖。
        let env = LyrimusePaths.engineEnvironment
        expectEqual(env["LYRIMUSE_CONFIG_DIR"], LyrimusePaths.configDir.path, "环境: LYRIMUSE_CONFIG_DIR = 数据目录")
        expectEqual(env["LYRIMUSE_CACHE_DIR"], LyrimusePaths.cachesDir.path, "环境: LYRIMUSE_CACHE_DIR = 缓存目录")
        expectEqual(env["LYRIMUSE_LOG_FILE"], LogFiles.engine.path, "环境: LYRIMUSE_LOG_FILE = 引擎日志")
        expectEqual(env["LYRIMUSE_APP_BUNDLE_ID"], LyrimuseIdentity.bundleIdentifier, "环境: LYRIMUSE_APP_BUNDLE_ID = 本 App 的 bundle id(companion launch 用)")
        expectEqual(env.count, 4, "环境: 只传这四个,别的都让引擎自己决定")
        let merged = LyrimusePaths.engineProcessEnvironment(base: ["PATH": "/usr/bin", "LYRIMUSE_CONFIG_DIR": "/stale"])
        expectEqual(merged["PATH"], "/usr/bin", "环境: 继承的变量保留")
        expectEqual(merged["LYRIMUSE_CONFIG_DIR"], LyrimusePaths.configDir.path, "环境: 同名以本 App 的为准(别让终端里残留的值把目录指去别处)")
        expectEqual(merged.count, 5, "环境: 合并后恰好多四项")
    }

    runStorageLayoutChecks()

    do {
        // 缓存搬家:只搬认得的扩展名,新位置已有的以新位置为准,搬空了才删旧目录;旧目录不存在什么都不做。
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("lyrimuse-cache-relocation-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("caches/motion-covers")
        try? fm.createDirectory(at: old, withIntermediateDirectories: true)
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        try? Data("a".utf8).write(to: old.appendingPathComponent("a.mp4"))
        try? Data("half".utf8).write(to: old.appendingPathComponent("b.mp4.tmp"))
        try? Data("stale".utf8).write(to: old.appendingPathComponent("c.mp4"))
        try? Data("fresh".utf8).write(to: new.appendingPathComponent("c.mp4"))
        try? Data("keep".utf8).write(to: old.appendingPathComponent("notes.txt"))
        let first = CacheRelocation.move(from: old, to: new, extensions: ["mp4", "tmp"])
        expectEqual(first, CacheRelocation.Outcome(moved: 2, dropped: 1, removedOldDirectory: false),
                    "缓存搬家: 两份搬走、新位置已有的那份丢掉旧的;旧目录还剩别的文件就不删")
        expectEqual(try? String(contentsOf: new.appendingPathComponent("c.mp4"), encoding: .utf8), "fresh", "缓存搬家: 同名以新位置为准")
        expectEqual(fm.fileExists(atPath: new.appendingPathComponent("a.mp4").path), true, "缓存搬家: 文件到了新位置")
        expectEqual(fm.fileExists(atPath: old.appendingPathComponent("notes.txt").path), true, "缓存搬家: 不认得的文件原样留着")
        try? fm.removeItem(at: old.appendingPathComponent("notes.txt"))
        try? Data("d".utf8).write(to: old.appendingPathComponent("d.mp4"))
        expectEqual(CacheRelocation.move(from: old, to: new, extensions: ["mp4", "tmp"]),
                    CacheRelocation.Outcome(moved: 1, dropped: 0, removedOldDirectory: true), "缓存搬家: 搬空了删旧目录")
        expectEqual(fm.fileExists(atPath: old.path), false, "缓存搬家: 旧目录没了")
        expectEqual(CacheRelocation.move(from: old, to: new, extensions: ["mp4"]), CacheRelocation.Outcome(),
                    "缓存搬家: 旧目录不存在时什么都不做")
    }
}
