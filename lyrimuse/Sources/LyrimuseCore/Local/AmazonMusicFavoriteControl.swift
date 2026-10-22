import AppKit
import ApplicationServices
import Foundation

/// Amazon Music 的「喜欢」= 当前这首在不在它的资料库(它对点播的歌没有赞;正在播放页上那颗「+」)。见 07 章决策 150。
///
/// - 读:当前这首的 ASIN(日志里开播那一行,`AmazonMusicLogWatcher.currentTrackASIN`)在不在本地资料库 `Data/Library`
///   (LevelDB,每首一条 `track.<资料库 ID>`,值里带 `asin`)。界面上那颗键加没加进去类名都一样,读不出来。
/// - 写:播放条上没有这颗键。先打开正在播放页(按播放条封面),按「+」;已在库里时按的是删除,还要按确认框的确认键;
///   自己打开的页按完收起。按完等资料库里真的有 / 没有了才算到(加入要走网络,约一秒)。
/// - 它的网页树不跟着界面刷新,每找一个元素都切一次 `AXEnhancedUserInterface` 让整棵重建(同模式那两颗键),
///   跟读进度那边共用 `AmazonMusicUIProbe.treeLock`。只认类名,不认界面文字(英文以外的界面也认得)。
public enum AmazonMusicFavoriteControl {
    public static let bundleID = "com.amazon.music"
    /// 按完等资料库确认:最多等这么久、隔这么久看一次。加入要走网络再同步回本地,实测按下后几秒才落库;等不到会把这一首的心藏起来,
    /// 宁可多等。
    static let confirmWait: TimeInterval = 8
    static let confirmPollInterval: TimeInterval = 0.2
    /// 重建网页树后找一个元素最多等多久(页面刚打开、确认框刚弹出时要等它画出来)。
    static let findWait: TimeInterval = 1.5

    /// 写入一次只走一个:按的是开关,两次叠在一起会互相抵消。
    private static let writeLock = NSLock()

    public static var libraryPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Amazon Music/Data/Library").path
    }

    /// 资料库一条曲目记录里它自己的 ASIN:`asin` 那个字段(前面是 8 字节长度 4,后面 4 个零字节、8 字节值长度、值);
    /// `albumAsin` / `artistAsin` 不算。认不出为 nil。纯函数,selftest 覆盖。
    public static func trackASIN(inRecord record: [UInt8]) -> String? {
        let marker: [UInt8] = [4, 0, 0, 0, 0, 0, 0, 0] + Array("asin".utf8) + [0, 0, 0, 0]
        guard record.count >= marker.count + 8 else { return nil }
        for start in 0...(record.count - marker.count - 8) where record[start] == 4 {
            guard Array(record[start..<(start + marker.count)]) == marker else { continue }
            let lengthAt = start + marker.count
            let length = LevelDBReader.le64(record, lengthAt)
            guard (1...32).contains(length), lengthAt + 8 + Int(length) <= record.count else { return nil }
            let value = record[(lengthAt + 8)..<(lengthAt + 8 + Int(length))]
            guard value.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else { return nil }
            return String(decoding: value, as: UTF8.self)
        }
        return nil
    }

    /// 资料库里有没有这首;资料库目录不在为 nil。
    public static func libraryContains(asin: String, path: String = libraryPath) -> Bool? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let prefix = Array("track.".utf8)
        let tracks = LevelDBReader.scan(directory: path) { $0.starts(with: prefix) }
        return tracks.values.contains { trackASIN(inRecord: $0) == asin }
    }

    /// 当前这首在不在资料库;不是歌(播客)、读不到为 nil。读文件,不碰界面。
    public static func readFavorited() -> Bool? {
        guard let asin = AmazonMusicLogWatcher.shared.currentTrackASIN() else { return nil }
        return libraryContains(asin: asin)
    }

    /// 加进 / 移出资料库,返回到没到(以资料库为准)。要辅助功能权限、Amazon 在跑、正在放的是歌。会阻塞几秒,别在主线程调。
    public static func setFavorited(_ value: Bool) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard AXIsProcessTrusted(), let asin = AmazonMusicLogWatcher.shared.currentTrackASIN(),
              let now = libraryContains(asin: asin) else { return false }
        if now == value { return true }
        guard let pid = PlayerProcess.pid(bundleID: bundleID) else { return false }
        let ax = MenuBarAX.timed(AXUIElementCreateApplication(pid))
        AmazonMusicUIProbe.treeLock.lock()
        let pressed = pressAddToLibrary(ax, removing: now) { AmazonMusicLogWatcher.shared.currentTrackASIN() == asin }
        AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        AmazonMusicUIProbe.treeLock.unlock()
        guard pressed else { return false }
        return MenuBarAX.waitFor(value, polls: Int(confirmWait / confirmPollInterval), interval: confirmPollInterval) {
            libraryContains(asin: asin)
        }
    }

    /// 播放条上的封面(按它打开正在播放页)。纯函数,selftest 覆盖。
    public static func isPlayBarArt(_ classes: [String]) -> Bool {
        classes.contains("artWrapper") && classes.contains("album") && classes.contains("small")
    }

    /// 正在播放页的根(开着时带 `nowPlayingShowing`)。纯函数,selftest 覆盖。
    public static func isNowPlayingRoot(_ classes: [String]) -> Bool { classes.contains("nowPlayingShowing") }

    /// 删除确认框的确认键(实心那颗;另一颗是描边的取消)。纯函数,selftest 覆盖。
    public static func isDialogConfirm(_ classes: [String]) -> Bool {
        classes.contains("dialogButton") && classes.contains("solid")
    }

    /// 打开正在播放页(没开的话)→ 按「+」→ 删除时按确认框 → 收起自己打开的页。按不下去为 false。调用方持 `treeLock`。
    /// `stillSame`:按「+」、按确认之前各问一次还是不是开头读的那一首。开页、重建网页树要一两秒,这期间换了歌的话按下去
    /// 动的是下一首(删除时连确认框也会被按掉),换了就不按。
    private static func pressAddToLibrary(_ ax: AXUIElement, removing: Bool, stillSame: () -> Bool) -> Bool {
        var opened = false
        defer {
            if opened, let close = rebuiltElement(ax, within: isNowPlayingRoot, where: { $0.contains("closeButtonWrapper") }) {
                AXUIElementPerformAction(close, kAXPressAction as CFString)
            }
        }
        let isAddButton: ([String]) -> Bool = { $0.contains("addToLibrary") }
        var button = rebuiltElement(ax, within: isNowPlayingRoot, where: isAddButton, wait: 0)
        if button == nil {
            guard let art = rebuiltElement(ax, where: isPlayBarArt),
                  AXUIElementPerformAction(art, kAXPressAction as CFString) == .success else { return false }
            opened = true
            button = rebuiltElement(ax, within: isNowPlayingRoot, where: isAddButton)
        }
        guard let button, stillSame(), AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { return false }
        // 用户在确认框里勾过「不再提示」就不弹:找不到确认键照样往下走,到没到看资料库。
        if removing, let confirm = rebuiltElement(ax, where: isDialogConfirm) {
            guard stillSame() else { return false }
            AXUIElementPerformAction(confirm, kAXPressAction as CFString)
        }
        return true
    }

    /// 重建网页树,找类名满足 `matches` 的元素;给了 `within` 就只在类名满足它的那个元素底下找。最多等 `wait`。
    private static func rebuiltElement(_ ax: AXUIElement, within: (([String]) -> Bool)? = nil,
                                       where matches: ([String]) -> Bool, wait: TimeInterval = findWait) -> AXUIElement? {
        AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.25)
        let deadline = Date().addingTimeInterval(wait)
        repeat {
            if let found = find(ax, within: within, where: matches) { return found }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return nil
    }

    private static func find(_ ax: AXUIElement, within: (([String]) -> Bool)?, where matches: ([String]) -> Bool) -> AXUIElement? {
        var visited = 0
        func classes(_ e: AXUIElement) -> [String] {
            var value: AnyObject?
            AXUIElementCopyAttributeValue(e, "AXDOMClassList" as CFString, &value)
            return (value as? [String]) ?? []
        }
        func walk(_ e: AXUIElement, inside: Bool) -> AXUIElement? {
            visited += 1
            guard visited < 8000 else { return nil }
            let list = classes(e)
            let nowInside = inside || (within?(list) ?? false)
            if nowInside, matches(list) { return e }
            for child in MenuBarAX.children(e) {
                if let hit = walk(child, inside: nowInside) { return hit }
            }
            return nil
        }
        for window in MenuBarAX.children(ax, attribute: kAXWindowsAttribute) {
            if let hit = walk(window, inside: within == nil) { return hit }
        }
        return nil
    }
}
