import ApplicationServices
import Foundation

/// Cog 的随机 / 循环。系统媒体遥控的随机 / 循环命令它不接,通道是菜单栏「Playlist」里的 Repeat、Shuffle 两个子菜单:
/// Repeat 依次是 All、Album、One、None,Shuffle 依次是 All、Albums、Off,各恰好一项打勾,对那一项 `AXPress` 切过去。
/// 上级两项按标题认(英文、西班牙文两套界面),子菜单按位置认。Album / Albums 按同一档显示(整张专辑循环算列表循环、
/// 按专辑随机算随机)。需要「辅助功能」权限,没有就读不到、按钮不显示。见 02 章决策 275。
public enum CogMenuControl {
    public static let bundleID = PlaybackPlayer.cog.bundleIdentifier
    public static let options: MusicPlaybackController.PlaybackModeOptions = [.shuffle, .repeatAll, .repeatOne]
    static let repeatTitles: Set<String> = ["Repeat", "Repetir"]
    static let shuffleTitles: Set<String> = ["Shuffle", "Aleatorio"]

    /// Repeat 子菜单的四项(All、Album、One、None)。别把最后一项叫 `none`:在 `Repeat?` 里会被当成 nil。
    public enum Repeat: Int, Sendable {
        case all = 0, album, one, off
    }

    /// Shuffle 子菜单的三项。
    public enum Shuffle: Int, Sendable {
        case all = 0, albums, off
    }

    /// 两个子菜单打勾的项 → 档位:随机开着算随机(同 `MusicPlaybackMode` 的优先级)。纯函数,selftest 覆盖。
    public static func mode(repeat r: Repeat, shuffle s: Shuffle) -> MusicPlaybackController.MusicPlaybackMode {
        if s != .off { return .shuffle }
        switch r {
        case .all, .album: return .repeatAll
        case .one: return .repeatOne
        case .off: return .list
        }
    }

    /// 切到某一档该按的项(已经是那一项的不按):随机开随机,单曲循环一并关掉(不然一直重复这一首),列表 / 专辑循环不动;循环和不循环先关随机。纯函数,selftest 覆盖。
    public static func presses(for mode: MusicPlaybackController.MusicPlaybackMode, repeat r: Repeat,
                               shuffle s: Shuffle) -> (repeat: Repeat?, shuffle: Shuffle?) {
        switch mode {
        case .shuffle:
            return (r == .one ? .off : nil, s == .off ? .all : nil)
        case .repeatAll:
            return (r == .all || r == .album ? nil : .all, s == .off ? nil : .off)
        case .repeatOne:
            return (r == .one ? nil : .one, s == .off ? nil : .off)
        case .list:
            return (r == .off ? nil : .off, s == .off ? nil : .off)
        }
    }

    /// 一个子菜单里打勾的那一项(只看前 `count` 项);不是恰好一项为 nil。纯函数,selftest 覆盖。
    public static func checkedIndex(marks: [String?], count: Int) -> Int? {
        guard marks.count >= count else { return nil }
        let hits = (0..<count).filter { !(marks[$0] ?? "").isEmpty }
        return hits.count == 1 ? hits[0] : nil
    }

    /// 当前档;Cog 没在跑、没有辅助功能权限、找不到子菜单时为 nil。会阻塞跨进程查询,别在主线程调。
    public static func readMode() -> MusicPlaybackController.MusicPlaybackMode? {
        guard let menus = submenus(), let state = state(menus) else { return nil }
        return mode(repeat: state.repeat, shuffle: state.shuffle)
    }

    /// 切到某一档,返回该按的都按下去了没有(已经是这一档也算)。会阻塞,别在主线程调。
    public static func setMode(_ mode: MusicPlaybackController.MusicPlaybackMode) -> Bool {
        guard let menus = submenus(), let state = state(menus) else { return false }
        let plan = presses(for: mode, repeat: state.repeat, shuffle: state.shuffle)
        var ok = true
        if let s = plan.shuffle { ok = MenuBarAX.press(menus.shuffle[s.rawValue]) && ok }
        if let r = plan.repeat { ok = MenuBarAX.press(menus.repeat[r.rawValue]) && ok }
        return ok
    }

    private static func state(_ menus: (repeat: [AXUIElement], shuffle: [AXUIElement])) -> (repeat: Repeat, shuffle: Shuffle)? {
        let mark = { (e: AXUIElement) in MenuBarAX.string(e, "AXMenuItemMarkChar") }
        guard let r = checkedIndex(marks: menus.repeat.map(mark), count: 4).flatMap(Repeat.init(rawValue:)),
              let s = checkedIndex(marks: menus.shuffle.map(mark), count: 3).flatMap(Shuffle.init(rawValue:)) else { return nil }
        return (r, s)
    }

    /// 「Playlist」菜单里 Repeat、Shuffle 两个子菜单的各项。
    private static func submenus() -> (repeat: [AXUIElement], shuffle: [AXUIElement])? {
        guard let bar = MenuBarAX.menuBar(bundleID: bundleID) else { return nil }
        for top in MenuBarAX.menuChildren(bar) {
            let entries = MenuBarAX.menuChildren(top)
            let titled = { (titles: Set<String>) in
                entries.first { titles.contains((MenuBarAX.string($0, kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespaces)) }
            }
            guard let r = titled(repeatTitles), let s = titled(shuffleTitles) else { continue }
            let repeatItems = MenuBarAX.menuChildren(r)
            let shuffleItems = MenuBarAX.menuChildren(s)
            guard repeatItems.count >= 4, shuffleItems.count >= 3 else { return nil }
            return (repeatItems, shuffleItems)
        }
        return nil
    }
}

/// Cog 的音量:读窗口里描述是 Volume 的那根 `AXSlider`(取值 0~100,实际增益是它的平方;关掉「音量上限」时最大能放大到 800%,
/// 滑块仍是 0~100),跟它界面上看到的一致。写不碰滑块:滑块的动作会弹出它的「NN%」气泡、一直不收;按菜单「Control」里的
/// Volume Up / Down 一下一下逼近(每下增益固定改 5,滑块中段约 5 格、高处约 3 格;增益不足 5 时再往下一下就是 0),
/// 每下读回滑块,越过目标就停在近的那格。
/// 要辅助功能权限。会阻塞跨进程调用,别在主线程调。见 02 章决策 275。
public enum CogVolume {
    static let volumeLabels: Set<String> = ["Volume", "Volumen"]
    static let upTitles: Set<String> = ["Volume Up", "Subir el volumen"]
    static let downTitles: Set<String> = ["Volume Down", "Bajar el volumen"]
    /// 一次写最多按几下:音量上限开着时全程 20 下,关着时增益到 800%、步子在滑块上更密。
    static let maxPresses = 40
    static let axTimeout: Float = 0.25
    static let maxDepth = 5

    /// 当前音量 0~100;Cog 没在跑、没授权、找不到那根滑块为 nil。
    public static func read() -> Int? {
        guard let slider = volumeSlider(), let value = sliderValue(slider) else { return nil }
        return ReampVolume.percent(value)
    }

    /// 设成 0~100(越界夹住),落在菜单一下能到的格上离目标最近的那格。按了、读得回为 true(已经在那格也算)。
    public static func set(_ percent: Int) -> Bool {
        guard let slider = volumeSlider(), let start = sliderValue(slider), let items = stepItems() else { return false }
        var last = start
        return approach(target: Double(Swift.min(100, Swift.max(0, percent))), from: start) { up in
            guard MenuBarAX.press(up ? items.up : items.down) else { return nil }
            let value = valueAfterPress(slider, before: last)
            if let value { last = value }
            return value
        }
    }

    /// 逐步逼近:`press(true)` 按一下调大、返回读回的滑块值,按不动或读不回为 nil(整次算失败)。最多按 `maxPresses` 下。
    /// selftest 拿 Cog 的步进(增益 ±5、滑块是增益开方)跑全程。
    public static func approach(target: Double, from start: Double, press: (Bool) -> Double?) -> Bool {
        var current = start
        for _ in 0..<maxPresses {
            guard let up = direction(target: target, current: current) else { return true }
            guard let after = press(up) else { return false }
            switch outcome(target: target, before: current, after: after) {
            case .keepGoing:
                current = after
            case .stop:
                return true
            case .stepBack:
                return press(!up) != nil
            }
        }
        return true
    }

    /// 往哪边按:要调大为 true,已经在目标上为 nil。纯函数,selftest 覆盖。
    public static func direction(target: Double, current: Double) -> Bool? {
        current == target ? nil : target > current
    }

    /// 按了一下之后怎么办。
    public enum StepOutcome: Equatable, Sendable {
        case keepGoing
        case stop
        /// 越过了、上一格更近:反向按一下回去再停。
        case stepBack
    }

    /// 按一下前后的读数 → 下一步:没动(到头了)、到了、走反了都停;越过目标时上一格更近就退回去,碰到 0 / 100 那头不退
    /// (那头被夹住,反向一下回不到原格)。纯函数,selftest 覆盖。
    public static func outcome(target: Double, before: Double, after: Double) -> StepOutcome {
        if after == target { return .stop }
        let crossed = (before < target) != (after < target)
        if !crossed { return abs(after - target) < abs(before - target) ? .keepGoing : .stop }
        let backIsCloser = abs(before - target) < abs(after - target)
        return backIsCloser && after > 0 && after < 100 ? .stepBack : .stop
    }

    /// 描述是音量、取值 0~100 的滑块。纯函数,selftest 覆盖。
    public static func isVolumeSlider(description: String?, min: Double, max: Double) -> Bool {
        volumeLabels.contains(description ?? "") && min == 0 && max == 100
    }

    private static func sliderValue(_ slider: AXUIElement) -> Double? {
        (attribute(slider, kAXValueAttribute) as? NSNumber)?.doubleValue
    }

    /// 按完读回滑块;还是原值时隔 20 毫秒再读,最多 5 次(到头了的那一下就是原值)。
    private static func valueAfterPress(_ slider: AXUIElement, before: Double) -> Double? {
        var value = sliderValue(slider)
        for _ in 0..<5 where value == before {
            Thread.sleep(forTimeInterval: 0.02)
            value = sliderValue(slider)
        }
        return value
    }

    /// 菜单「Control」里的 Volume Up / Down 两项(按标题认,英文、西班牙文两套)。
    private static func stepItems() -> (up: AXUIElement, down: AXUIElement)? {
        guard let bar = MenuBarAX.menuBar(bundleID: PlaybackPlayer.cog.bundleIdentifier) else { return nil }
        for top in MenuBarAX.menuChildren(bar) {
            let entries = MenuBarAX.menuChildren(top)
            let titled = { (titles: Set<String>) in
                entries.first { titles.contains((MenuBarAX.string($0, kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespaces)) }
            }
            if let up = titled(upTitles), let down = titled(downTitles) { return (up, down) }
        }
        return nil
    }

    private static func volumeSlider() -> AXUIElement? {
        guard AXIsProcessTrusted(), let pid = PlayerProcess.pid(bundleID: PlaybackPlayer.cog.bundleIdentifier) else { return nil }
        let app = MenuBarAX.timed(AXUIElementCreateApplication(pid), timeout: axTimeout)
        for window in MenuBarAX.children(app, attribute: kAXWindowsAttribute, timeout: axTimeout) {
            if let hit = search(window, depth: 0) { return hit }
        }
        return nil
    }

    private static func search(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        for child in MenuBarAX.children(element, timeout: axTimeout) {
            let role = attribute(child, kAXRoleAttribute) as? String
            if role == kAXSliderRole,
               let min = (attribute(child, kAXMinValueAttribute) as? NSNumber)?.doubleValue,
               let max = (attribute(child, kAXMaxValueAttribute) as? NSNumber)?.doubleValue,
               isVolumeSlider(description: attribute(child, kAXDescriptionAttribute) as? String, min: min, max: max) {
                return child
            }
            if depth + 1 < maxDepth, role != kAXMenuBarRole, let hit = search(child, depth: depth + 1) { return hit }
        }
        return nil
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
