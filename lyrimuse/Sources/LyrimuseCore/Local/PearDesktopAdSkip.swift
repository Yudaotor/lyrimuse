import AppKit
import ApplicationServices
import Foundation
import os

private let logger = Logger(subsystem: LyrimuseIdentity.logSubsystem, category: "ytmusic-skip")

/// Pear Desktop 广告的「能不能跳」门槛与跳过动作,接在 `YouTubeMusicAdSkipper` 的同一套入口后面(02 章决策 229)。
///
/// Pear 是 Electron 套的 YouTube Music 网页,跳过键跟网页版是同一颗(`ytp-ad-skip-button-modern`),但它没有脚本字典、
/// 不能注入 JS:门槛改成在它窗口的 AX 树里找那颗键,找得到就是 `.ready`;动作跟网页版同一个 `AccessibilitySkipPress.press`;
/// 复核是按完 `YouTubeMusicAdSkipper.verifyDelay` 后键不在了。
///
/// Electron 默认不把网页挂进 AX 树,要设 `AXManualAccessibility`,设完异步建树。开着会拖慢页面,所以只在广告期间开:
/// 第一次门槛探测时打开,`releaseTree()`(广告态结束时由调用方调)关回去。
public enum PearDesktopAdSkip {
    public static let bundleID = PlaybackPlayer.pearDesktop.bundleIdentifier

    /// 打开 `AXManualAccessibility` 之后等网页挂进树最多多久。
    public static let treeWait: TimeInterval = 2.5

    /// 跳过键没出现时隔多久再探。树开着时一次遍历是几十毫秒,不用像网页版那样靠倒计时省 AppleEvent;
    /// 平台通常第 5 秒放出键,1 秒一探能让键在放出来之后 1 秒内出现。
    public static let notReadyRetryDelay: TimeInterval = 1

    public static func isPear(_ reportedBundleID: String?) -> Bool {
        reportedBundleID == bundleID
    }

    /// 门槛轮询隔多久再探:键出现之前 `notReadyRetryDelay`,出现之后跟网页版一样按心跳盯着(插播里下一条可能不给跳)。
    public static func gateRetryDelay(after state: YouTubeMusicAdSkipper.Skippability?) -> TimeInterval {
        state == .ready ? YouTubeMusicAdProbe.adRefreshInterval : notReadyRetryDelay
    }

    private static let lock = NSLock()
    /// 我们给哪个 Pear 进程打开过 `AXManualAccessibility`。Electron 读不回这个属性(读出来总是没开),
    /// 只能自己记;Pear 重启换了进程就作废。
    nonisolated(unsafe) private static var openedForPID: pid_t?
    /// 门槛探测时顺手读到的「第几条 / 共几条」和读到的时刻。
    nonisolated(unsafe) private static var lastSlot: (slot: YouTubeMusicAdProbe.AdSlot, at: Date)?

    /// 读到的计数多久内算数:门槛键出现前 1 秒一探、出现后 5 秒一探,留一点余量。
    public static let slotMaxAge: TimeInterval = 8

    /// 当前这条广告是第几条 / 共几条(徽章「赞助商广告 1/2」);广告态没在探、读不到、读到的太旧时 nil。
    public static func adSlot(now: Date = Date()) -> YouTubeMusicAdProbe.AdSlot? {
        lock.lock()
        defer { lock.unlock() }
        guard let lastSlot, now.timeIntervalSince(lastSlot.at) <= slotMaxAge else { return nil }
        return lastSlot.slot
    }

    /// 探一次:跳过键在不在。nil = Pear 没在跑、没有辅助功能权限,或网页还没挂进树(下一拍再探)。
    public static func probe() -> YouTubeMusicAdSkipper.Skippability? {
        guard AccessibilitySkipPress.isTrusted, openTree() else { return nil }
        guard let present = AccessibilitySkipPress.skipButtonPresent(bundleID: bundleID, hostMarker: YouTubeMusicAdProbe.hostMarker) else {
            logger.notice("gate: pear web area not in the AX tree yet")
            return nil
        }
        let slot = AccessibilitySkipPress.adBadgeText(bundleID: bundleID, hostMarker: YouTubeMusicAdProbe.hostMarker)
            .flatMap(YouTubeMusicAdProbe.AdSlot.init(badgeText:))
        lock.lock()
        lastSlot = slot.map { ($0, Date()) }
        lock.unlock()
        let state: YouTubeMusicAdSkipper.Skippability = present ? .ready : .never
        logger.notice("gate: \(String(describing: state), privacy: .public) (pear, slot \(slot.map { "\($0.index)/\($0.total)" } ?? "-", privacy: .public))")
        return state
    }

    /// 门槛 → 按键 → 复核。同步、会阻塞(遍历 + `verifyDelay`,约 1 秒),调用方放后台、保证同一时刻只跑一份。
    public static func skip() -> YouTubeMusicAdSkipper.Outcome? {
        guard AccessibilitySkipPress.isTrusted else { return .needsAccessibility }
        guard openTree() else { return .notFound }
        switch AccessibilitySkipPress.press(browserBundleID: bundleID, hostMarker: YouTubeMusicAdProbe.hostMarker) {
        case .notTrusted:
            return .needsAccessibility
        case .browserNotRunning, .webAreaNotFound:
            logger.notice("skip: pear web area not found")
            return .notFound
        case .buttonNotFound:
            logger.notice("skip: pear has no skip button yet")
            return .notYetSkippable(secondsUntilSkippable: nil)
        case .pressFailed(let code):
            logger.notice("skip: pear AX press failed \(code)")
            return .clickedNoEffect
        case .pressed(let desc):
            Thread.sleep(forTimeInterval: YouTubeMusicAdSkipper.verifyDelay)
            let still = AccessibilitySkipPress.skipButtonPresent(bundleID: bundleID, hostMarker: YouTubeMusicAdProbe.hostMarker)
            logger.notice("skip: pressed \(desc, privacy: .public) in pear → button still there: \(String(describing: still), privacy: .public)")
            return still == false ? .skipped : .clickedNoEffect
        }
    }

    /// 广告态结束:我们打开的 `AXManualAccessibility` 关回去。没打开过、Pear 已退出都是空操作。
    public static func releaseTree() {
        lock.lock()
        defer { lock.unlock() }
        lastSlot = nil
        guard let pid = openedForPID else { return }
        openedForPID = nil
        guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleID else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanFalse)
        logger.notice("pear: AXManualAccessibility off")
    }

    /// 让 Pear 的网页挂进 AX 树:原来没开就打开、等到网页出现或 `treeWait` 超时。Pear 没在跑为 false。
    private static func openTree() -> Bool {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier else { return false }
        // 锁只管 `openedForPID`:下面等网页挂进树最多 `treeWait`,主线程每拍要取同一把锁读 `adSlot`,不能拿着它等。
        lock.lock()
        let alreadyOpen = openedForPID == pid
        if !alreadyOpen { openedForPID = pid }
        lock.unlock()
        guard !alreadyOpen else { return true }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
        logger.notice("pear: AXManualAccessibility on")
        let deadline = Date().addingTimeInterval(treeWait)
        while AccessibilitySkipPress.skipButtonPresent(bundleID: bundleID, hostMarker: YouTubeMusicAdProbe.hostMarker) == nil,
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return true
    }
}
