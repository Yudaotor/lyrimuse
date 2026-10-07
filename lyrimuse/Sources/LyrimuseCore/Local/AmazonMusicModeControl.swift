import AppKit
import ApplicationServices
import Foundation

/// Amazon Music 的随机 / 循环。它没有脚本接口,菜单栏里也没有播放控制;播放条(放起来才出现)上那两颗键
/// (`button repeat …` / `button shuffle …`,没有文字)能 `AXPress`,但它的网页树不跟着界面刷新,每次按之前都要切一次
/// `AXEnhancedUserInterface` 让整棵重建(同 `AmazonMusicUIProbe`)。样式类名只分得出开关,分不出列表循环和单曲循环,
/// 所以读回不看界面、看它自己的日志 `AmazonMusic.log`:开播时一行 `CurrentPlayerSettings … repeat = ALL , shuffle = false`,
/// 之后每次切换一行 `ToggleRepeatSetting … repeatSetting = ONE` / `ShuffleChanged … shuffle = true`,取最后出现的那个。
/// 按下去偶尔不生效(连按间隔两秒左右时实测过一次),所以每按一下都等日志确认、没变就重按一次。见 07 章决策 139。
///
/// 循环键在它那里按一下的顺序是 关(NONE)→ 全部(ALL)→ 单曲(ONE)→ 关;随机和循环互相独立,可以同时开。
public enum AmazonMusicModeControl {
    public static let bundleID = "com.amazon.music"
    public static let options: MusicPlaybackController.PlaybackModeOptions = .all
    /// 读日志只看文件末尾这么多字节(一次播放会话的日志远小于这个数,开播那一行在里面)。
    static let tailBytes = 512 * 1024

    public struct Settings: Equatable, Sendable {
        /// NONE / ALL / ONE。
        public var repeatSetting: String?
        public var shuffle: Bool?

        public init(repeatSetting: String?, shuffle: Bool?) {
            self.repeatSetting = repeatSetting
            self.shuffle = shuffle
        }

        /// 收成一档,优先级同 Apple Music:单曲循环 > 随机 > 列表循环 > 列表。两样都没读到为 nil。
        public var mode: MusicPlaybackController.MusicPlaybackMode? {
            guard repeatSetting != nil || shuffle != nil else { return nil }
            if repeatSetting == "ONE" { return .repeatOne }
            if shuffle == true { return .shuffle }
            if repeatSetting == "ALL" { return .repeatAll }
            return .list
        }
    }

    /// 日志文字 → 最后一次记下的循环设置和随机开关。
    public static func latestSettings(inLog text: String) -> Settings {
        var settings = Settings(repeatSetting: nil, shuffle: nil)
        for line in text.split(separator: "\n") where line.contains("PlayerSettings") {
            if line.contains("CurrentPlayerSettings") {
                if let r = value(after: "repeat = ", in: line) { settings.repeatSetting = r }
                if let s = value(after: "shuffle = ", in: line) { settings.shuffle = s == "true" }
            } else if line.contains("ToggleRepeatSetting"), let r = value(after: "repeatSetting = ", in: line) {
                settings.repeatSetting = r
            } else if line.contains("ShuffleChanged"), let s = value(after: "shuffle = ", in: line) {
                settings.shuffle = s == "true"
            }
        }
        return settings
    }

    /// `key` 后面到下一个空格 / 逗号 / 冒号为止的那个词:true / false 小写,其余大写。
    static func value(after key: String, in line: Substring) -> String? {
        guard let range = line.range(of: key) else { return nil }
        let word = String(line[range.upperBound...].prefix { !" ,:".contains($0) })
        guard !word.isEmpty else { return nil }
        let lower = word.lowercased()
        return lower == "true" || lower == "false" ? lower : word.uppercased()
    }

    /// 从 `current` 切到 `target` 要按哪几下。列表 = 随机关、循环关;随机 = 开随机,循环是单曲时顺手关掉(不然按优先级
    /// 还是读成单曲循环,同 Apple Music 那一支);列表循环 / 单曲循环 = 关随机、循环按到那一档。
    public static func presses(from current: Settings, to target: MusicPlaybackController.MusicPlaybackMode) -> [String] {
        let wantShuffle = target == .shuffle
        let wantRepeat: String? = switch target {
        case .list: "NONE"
        case .shuffle: current.repeatSetting == "ONE" ? "NONE" : nil
        case .repeatAll: "ALL"
        case .repeatOne: "ONE"
        }
        var out: [String] = []
        if (current.shuffle ?? false) != wantShuffle { out.append("shuffle") }
        if let wantRepeat {
            let cycle = ["NONE", "ALL", "ONE"]
            let from = cycle.firstIndex(of: current.repeatSetting ?? "NONE") ?? 0
            let to = cycle.firstIndex(of: wantRepeat) ?? 0
            out += Array(repeating: "repeat", count: (to - from + cycle.count) % cycle.count)
        }
        return out
    }

    /// 当前档;日志读不到为 nil。
    public static func readMode(logPath: String = AmazonMusicLogWatcher.defaultPath) -> MusicPlaybackController.MusicPlaybackMode? {
        readSettings(logPath: logPath)?.mode
    }

    static func readSettings(logPath: String) -> Settings? {
        guard let handle = FileHandle(forReadingAtPath: logPath) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > UInt64(tailBytes) ? end - UInt64(tailBytes) : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let settings = latestSettings(inLog: String(decoding: data, as: UTF8.self))
        return settings.mode == nil ? nil : settings
    }

    /// 切到某一档,返回到没到(以日志为准)。要辅助功能权限、Amazon 在跑、播放条在。会阻塞几秒,别在主线程调。
    public static func setMode(_ target: MusicPlaybackController.MusicPlaybackMode,
                               logPath: String = AmazonMusicLogWatcher.defaultPath) -> Bool {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              var current = readSettings(logPath: logPath) else { return false }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 1)
        defer { AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        for button in presses(from: current, to: target) {
            var changed = false
            for _ in 0..<2 where !changed {
                guard let element = rebuiltButton(ax, classToken: button) else { return false }
                guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { return false }
                let deadline = Date().addingTimeInterval(1.5)
                while Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                    if let now = readSettings(logPath: logPath), now != current {
                        current = now
                        changed = true
                        break
                    }
                }
            }
            guard changed else { return false }
        }
        return current.mode == target
    }

    /// 切一次 `AXEnhancedUserInterface` 让网页树重建,找类名里带 `classToken`(repeat / shuffle)的那颗键。
    /// 刚切完头一百多毫秒读到的还是旧树,所以等到建好、最多一秒。
    private static func rebuiltButton(_ ax: AXUIElement, classToken: String) -> AXUIElement? {
        AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        let deadline = Date().addingTimeInterval(1)
        Thread.sleep(forTimeInterval: 0.25)
        while Date() < deadline {
            if let found = findButton(ax, classToken: classToken) { return found }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    private static func findButton(_ root: AXUIElement, classToken: String) -> AXUIElement? {
        var visited = 0
        func walk(_ e: AXUIElement) -> AXUIElement? {
            visited += 1
            guard visited < 5000 else { return nil }
            var role: AnyObject?
            AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
            if (role as? String) == kAXButtonRole {
                var classes: AnyObject?
                AXUIElementCopyAttributeValue(e, "AXDOMClassList" as CFString, &classes)
                if let list = classes as? [String], list.contains("button"), list.contains(classToken) { return e }
            }
            var children: AnyObject?
            AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &children)
            for child in (children as? [AXUIElement]) ?? [] {
                if let hit = walk(child) { return hit }
            }
            return nil
        }
        var windows: AnyObject?
        AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows)
        for window in (windows as? [AXUIElement]) ?? [] {
            if let hit = walk(window) { return hit }
        }
        return nil
    }
}
