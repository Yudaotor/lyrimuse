import LyrimuseCore
import Foundation

// 身份与落盘路径:LyrimuseIdentity 的那一套名字、LyrimusePaths / LogFiles 的派生、传给 collector 的环境变量。
// 2026-09-05 加(借鉴清单 #33 第一步);同日第二步的「Lyrimuse Dev」变体 2026-09-06 用户拍板整体回退,这里随之只剩
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
        expectEqual(id.collectorLaunchdLabel, "com.lyrimuse.collector", "身份: collector label(build.sh / uninstall.sh 里的字面量要跟它一致)")
        expectEqual(id.logFileName, "lyrimuse.log", "身份: collector 日志名")
        expectEqual(id.appLogFileName, "lyrimuse-app.log", "身份: App stderr 日志名")
        expectEqual(id.defaultAppBundlePath, "/Applications/Lyrimuse.app", "身份: 默认装到 /Applications")
        expectEqual(id.urlScheme, "lyrimuse", "身份: URL scheme(Last.fm 授权回调)")
        expectEqual(id.logFileName, id.configDirName + ".log", "身份: collector 日志名 = 目录名 + .log(uninstall.sh 靠这条规则拼)")
        expectEqual(id.appLogFileName, id.configDirName + "-app.log", "身份: App 日志名 = 目录名 + -app.log")
        expectEqual(LyrimuseIdentity.displayName, id.displayName, "身份: 便捷静态属性与 current 一致")
        expectEqual(LyrimuseIdentity.collectorLaunchdLabel, id.collectorLaunchdLabel, "身份: 便捷静态属性与 current 一致(label)")

        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        expectEqual(LyrimusePaths.configDir.path, homePath + "/.config/lyrimuse", "路径: 配置目录 = ~/.config/lyrimuse")
        expectEqual(LyrimusePaths.configFile("config.json").path, homePath + "/.config/lyrimuse/config.json", "路径: 配置目录下的文件")
        expectEqual(LogFiles.collector.path, homePath + "/Library/Logs/lyrimuse.log", "路径: collector 日志")
        expectEqual(LogFiles.appStderr.path, homePath + "/Library/Logs/lyrimuse-app.log", "路径: App stderr 日志")
        expectEqual(LyrimusePaths.launchAgentPlist(label: "x.y").path, homePath + "/Library/LaunchAgents/x.y.plist", "路径: LaunchAgent plist")
        expectEqual(LyrimusePaths.defaultAppBundleURL.path, "/Applications/Lyrimuse.app", "路径: 默认安装位置")

        // 传给 collector 的环境变量:三个键、值就是上面的路径与 bundle id;叠在继承环境上、不丢父进程的变量、同名覆盖。
        let env = LyrimusePaths.collectorEnvironment
        expectEqual(env["LYRIMUSE_CONFIG_DIR"], LyrimusePaths.configDir.path, "环境: LYRIMUSE_CONFIG_DIR = 配置目录")
        expectEqual(env["LYRIMUSE_LOG_FILE"], LogFiles.collector.path, "环境: LYRIMUSE_LOG_FILE = collector 日志")
        expectEqual(env["LYRIMUSE_APP_BUNDLE_ID"], LyrimuseIdentity.bundleIdentifier, "环境: LYRIMUSE_APP_BUNDLE_ID = 本 App 的 bundle id(companion launch 用)")
        expectEqual(env.count, 3, "环境: 只传这三个,别的都让 collector 自己决定")
        let merged = LyrimusePaths.collectorProcessEnvironment(base: ["PATH": "/usr/bin", "LYRIMUSE_CONFIG_DIR": "/stale"])
        expectEqual(merged["PATH"], "/usr/bin", "环境: 继承的变量保留")
        expectEqual(merged["LYRIMUSE_CONFIG_DIR"], LyrimusePaths.configDir.path, "环境: 同名以本 App 的为准(别让终端里残留的值把目录指去别处)")
        expectEqual(merged.count, 4, "环境: 合并后恰好多三项")
    }
}
