import AppKit
import ApplicationServices
import Foundation

/// Amazon Music 的随机 / 循环。它没有脚本接口,菜单栏里也没有播放控制;播放条(放起来才出现)上那两颗键
/// (`button repeat …` / `button shuffle …`,没有文字)能 `AXPress`,但它的网页树不跟着界面刷新,每次按之前都要切一次
/// `AXEnhancedUserInterface` 让整棵重建(同 `AmazonMusicUIProbe`)。样式类名只分得出开关,分不出列表循环和单曲循环,
/// 所以读回不看界面、看它自己的日志 `AmazonMusic.log`:开播时一行 `CurrentPlayerSettings … repeat = ALL , shuffle = false`,
/// 之后每次切换一行 `ToggleRepeatSetting … repeatSetting = ONE` / `ShuffleChanged … shuffle = true`,取最后出现的那个。
/// 日志一天能长到几 MB,开播那一行不一定在末尾附近:从最后一个开播行读起,之后只读新写的(见 `readSettings`)。
/// 按下去偶尔不生效(连按间隔两秒左右时实测过一次),所以每按一下都等日志确认、没变就重按一次;按的是相对量(循环键按一下
/// 进一档),写入一次只走一个(见 `writeLock`)。见 07 章决策 139。
///
/// 循环键在它那里按一下的顺序是 关(NONE)→ 全部(ALL)→ 单曲(ONE)→ 关;随机和循环互相独立,可以同时开。
public enum AmazonMusicModeControl {
    public static let bundleID = "com.amazon.music"
    public static let options: MusicPlaybackController.PlaybackModeOptions = .all
    /// 往回找开播那一行(`CurrentPlayerSettings`)时一次读多少字节。
    public static let scanChunkBytes = 512 * 1024
    /// 每按一下等日志确认:最多等这么久、隔这么久看一次。
    public static let confirmWait: TimeInterval = 1.5
    public static let confirmPollInterval: TimeInterval = 0.1
    /// 一次切换最多按几下:随机一下 + 循环绕一圈三下,再给重按留两下。
    public static let maxPresses = 6

    /// 写入一次只走一个:按几下照日志里的当前档算,两次写入不能叠在一起。见 07 章决策 139。
    private static let writeLock = NSLock()

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

    /// 日志文字 → 最后一次记下的循环设置和随机开关。`start` 是这段文字之前已经知道的(增量读时接着上次的结果往下算)。
    public static func latestSettings(inLog text: String,
                                      from start: Settings = Settings(repeatSetting: nil, shuffle: nil)) -> Settings {
        var settings = start
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

    /// 当前档;没有辅助功能权限(按不了键)、日志读不到为 nil。
    public static func readMode(logPath: String = AmazonMusicLogWatcher.defaultPath) -> MusicPlaybackController.MusicPlaybackMode? {
        guard AXIsProcessTrusted() else { return nil }
        return readSettings(logPath: logPath)?.mode
    }

    /// 日志读到哪了、读到那里时的设置。受 `cursorLock` 保护。
    private struct LogCursor {
        let path: String
        let fileNumber: UInt64
        var offset: UInt64
        var settings: Settings
    }
    private static let cursorLock = NSLock()
    private static var cursor: LogCursor?

    /// 当前的循环设置和随机开关;日志读不到、里面一条设置都没有为 nil。
    ///
    /// 增量读:记着上次读到的位置和当时的设置,只读之后新写的整行。第一次读、日志换了一份(看 inode)或变短了,就从最后一个
    /// 开播行读起(它之前的切换都被它盖过);开播行可能在很早以前,不能只看末尾固定一段。
    public static func readSettings(logPath: String, scanChunk: Int = scanChunkBytes) -> Settings? {
        cursorLock.lock()
        defer { cursorLock.unlock() }
        guard let handle = FileHandle(forReadingAtPath: logPath) else { return nil }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, let end = try? handle.seekToEnd() else { return nil }
        let fileNumber = UInt64(info.st_ino)
        var state: LogCursor
        if let c = cursor, c.path == logPath, c.fileNumber == fileNumber, c.offset <= end {
            state = c
        } else {
            state = LogCursor(path: logPath, fileNumber: fileNumber,
                              offset: lastSettingsLineOffset(handle, end: end, chunk: scanChunk),
                              settings: Settings(repeatSetting: nil, shuffle: nil))
        }
        if end > state.offset {
            guard (try? handle.seek(toOffset: state.offset)) != nil,
                  let data = try? handle.read(upToCount: Int(end - state.offset)) else { return nil }
            // 只读到最后一个换行:最后那行可能还没写完,留到下次连同后半截一起读。
            if let newline = data.lastIndex(of: UInt8(ascii: "\n")) {
                let complete = data[...newline]
                state.settings = latestSettings(inLog: String(decoding: complete, as: UTF8.self), from: state.settings)
                state.offset += UInt64(complete.count)
            }
        }
        cursor = state
        return state.settings.mode == nil ? nil : state.settings
    }

    /// 最后一个开播行(`CurrentPlayerSettings`)从哪个字节起;一个都没有是 0(从头读)。从末尾往回一块一块找,每块带上后一块
    /// 开头那几个字节,标记被块边界切开也找得到。从标记本身读起就够了:设置都写在它后面。
    public static func lastSettingsLineOffset(_ handle: FileHandle, end: UInt64, chunk: Int) -> UInt64 {
        let marker = Data("CurrentPlayerSettings".utf8)
        let step = UInt64(max(chunk, marker.count))
        var upper = end
        var carry = Data()
        while upper > 0 {
            let lower = upper > step ? upper - step : 0
            guard (try? handle.seek(toOffset: lower)) != nil,
                  let block = try? handle.read(upToCount: Int(upper - lower)) else { return 0 }
            let window = block + carry
            if let hit = window.range(of: marker, options: .backwards) {
                return lower + UInt64(hit.lowerBound - window.startIndex)
            }
            carry = Data(block.prefix(marker.count - 1))
            upper = lower
        }
        return 0
    }

    /// 切到某一档,返回到没到(以日志为准)。要辅助功能权限、Amazon 在跑、播放条在。会阻塞几秒,别在主线程调。
    public static func setMode(_ target: MusicPlaybackController.MusicPlaybackMode,
                               logPath: String = AmazonMusicLogWatcher.defaultPath) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let start = readSettings(logPath: logPath) else { return false }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 1)
        // 整段持锁:读进度那边(`AmazonMusicUIProbe.sampleOrigin`)也切这棵树,交错时互相拆掉对方刚建好的树。
        AmazonMusicUIProbe.treeLock.lock()
        defer {
            AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            AmazonMusicUIProbe.treeLock.unlock()
        }
        let reached = pressUntilConfirmed(from: start, to: target, read: { readSettings(logPath: logPath) }) { button in
            guard let element = rebuiltButton(ax, classToken: button) else { return false }
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }
        return reached?.mode == target
    }

    /// 从 `start` 按到 `target`,返回最后从日志读到的设置(到没到调用方自己比);按不下去、等不到日志确认为 nil。
    ///
    /// 每按一下等日志确认,没变就重按一次;每一下都照日志里最新的档算下一下按什么。重按过的话收尾再等一个确认窗口,
    /// 以最后读到的为准(跟目标对不上时调用方回读)。读日志、按键从外面传进来。
    public static func pressUntilConfirmed(
        from start: Settings, to target: MusicPlaybackController.MusicPlaybackMode,
        polls: Int = Int(confirmWait / confirmPollInterval), pollInterval: TimeInterval = confirmPollInterval,
        read: () -> Settings?, press: (String) -> Bool
    ) -> Settings? {
        var current = start
        var pressed = 0
        var retried = false
        while let button = presses(from: current, to: target).first {
            var changed: Settings?
            for attempt in 0..<2 where changed == nil {
                guard pressed < maxPresses, press(button) else { return nil }
                pressed += 1
                if attempt > 0 { retried = true }
                changed = awaitChange(from: current, polls: polls, interval: pollInterval, read: read)
            }
            guard let changed else { return nil }
            current = changed
        }
        if retried, let late = awaitChange(from: current, polls: polls, interval: pollInterval, read: read) {
            current = late
        }
        return current
    }

    /// 等日志从 `current` 变成别的样子,变了返回新的;读了 `polls` 次都没变为 nil。
    private static func awaitChange(from current: Settings, polls: Int, interval: TimeInterval,
                                    read: () -> Settings?) -> Settings? {
        for _ in 0..<max(polls, 0) {
            if interval > 0 { Thread.sleep(forTimeInterval: interval) }
            if let now = read(), now != current { return now }
        }
        return nil
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
