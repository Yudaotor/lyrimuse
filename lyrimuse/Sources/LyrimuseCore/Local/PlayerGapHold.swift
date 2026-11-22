import Foundation

/// 播放器切歌时先撤掉 Now Playing、隔几秒才发下一首(`PlaybackPlayer.dropsSessionBetweenTracks`,空档长短见 02 章
/// 决策 60):这几秒里系统焦点落到别的播放器暂停着的旧会话上,或者谁都没有。
/// 照直采纳的话,界面和网页会先跳到那个暂停的播放器(或者清空),几秒后再跳回来。
///
/// 判据:上一份被采纳的快照(在放或暂停都算:暂停着点开一张新专辑,加载那几秒同样会撤)来自会这样撤会话的播放器;这一拍却是别的播放器**没在放**、什么都没有,或者同一个
/// 播放器报「没在放」却换了一首(撤会话那一瞬读到的撕裂快照)→ 还当是上一首。接手的播放器**在放**就照常切:那是用户
/// 真的换了播放器。同一个播放器报同一首暂停也照常:那是真暂停。那个播放器已经退出了也不等。
///
/// 只对标了 `dropsSessionBetweenTracks` 的播放器和网页播放器的宿主(`isWebPlayerHost`)生效:位置链路上的判据按播放器收窄
/// (见 02 章决策 41)。
public enum PlayerGapHold {
    /// 撤会话那一拍离最后一次看到它不超过这么久,才当是切歌空档。
    public static let startWindow: TimeInterval = 8
    /// 从撤会话那一拍起最多保持多久,再久就当它真的不放了。
    public static let window: TimeInterval = 25
    /// 网页播放器的宿主最多保持多久。关标签页同样撤会话、不再回来,比原生播放器收得短;换歌空档实测 4 秒以内(见 02 章决策 289)。
    public static let webHostWindow: TimeInterval = 10

    /// 网页播放器的宿主:Chromium 系浏览器、它们装出来的网页应用、Safari 的媒体进程(换成宿主后是有脚本接口的浏览器)。
    /// 页面换歌时浏览器先撤会话、隔一会儿再登记下一首,同原生播放器的 `dropsSessionBetweenTracks`(见 02 章决策 289)。纯函数。
    public static func isWebPlayerHost(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        let host = TrustedPlayers.mediaProxyOwners[bundleID] ?? BrowserWebApp.parse(bundleID)?.hostBundleID ?? bundleID
        return BrowserAutomationPermission.family(forBundleID: host) != nil
    }

    /// 这个播放器换歌时会不会先撤会话:内置播放器看 `dropsSessionBetweenTracks`,另加网页播放器的宿主。
    public static func dropsSessionBetweenTracks(_ bundleID: String?) -> Bool {
        PlaybackPlayer.builtin(forBundleID: bundleID)?.dropsSessionBetweenTracks == true || isWebPlayerHost(bundleID)
    }

    /// `holdingSince` 为 nil 时判「这一拍该不该开始保持」,否则判「还该不该接着保持」。`lastPlayerRunning` 只在
    /// 别的条件都满足时才问。
    public static func shouldHold(lastBundleID: String?, lastTrackKey: String?, lastSeenAt: Date?, holdingSince: Date?,
                                  newBundleID: String?, newTrackKey: String?, newPlaying: Bool,
                                  lastPlayerRunning: () -> Bool, now: Date) -> Bool {
        guard let lastBundleID, let lastSeenAt, !newPlaying, dropsSessionBetweenTracks(lastBundleID) else { return false }
        if newBundleID == lastBundleID && newTrackKey == lastTrackKey { return false }
        let inWindow: Bool
        if let holdingSince {
            let held = now.timeIntervalSince(holdingSince)
            inWindow = held >= 0 && held <= (isWebPlayerHost(lastBundleID) ? webHostWindow : window)
        } else {
            let age = now.timeIntervalSince(lastSeenAt)
            inWindow = age >= 0 && age <= startWindow
        }
        return inWindow && lastPlayerRunning()
    }

    /// 保持期间位置照墙钟往前走,不超过曲长。不往前走的话,伺服会把「读数停在原地好几秒」当成往回拖了一段。
    public static func heldElapsed(elapsed: Double?, rate: Double?, duration: Double?, since: TimeInterval) -> Double? {
        guard let elapsed else { return nil }
        let r = (rate ?? 0) > 0 ? rate! : 1
        var value = elapsed + max(0, since) * r
        if let duration, duration > 0 { value = min(value, duration) }
        return value
    }

    // MARK: 会话在放的时候被撤掉

    /// 推算的位置过了曲长这么久还没有新会话,当它放完了。
    public static let whileOutputtingEndGrace: TimeInterval = 5
    /// 不知道曲长时最多保持这么久。
    public static let whileOutputtingMaxHold: TimeInterval = 600

    /// 会话在放的时候被撤掉、声音照放(`PlaybackPlayer.dropsSessionWhilePlaying`,见 02 章决策 96):上一份被采纳的快照来自
    /// 这样的播放器,这一拍谁都没在报、或者是别的播放器没在放,而它的进程还在出声 → 还当是上一首在放。它自己再报什么
    /// (暂停、换歌都会重新登记)都照常采纳;接手的播放器在放就照常切。位置按上一份快照照墙钟往前推,过了曲长
    /// `whileOutputtingEndGrace` 秒还没有新会话就当它放完了;不知道曲长时最多保持 `whileOutputtingMaxHold` 秒。
    /// 上一份快照暂停着也算(清空赶在开播被看到之前到),出声就是在放。不能反过来拿「不出声」判暂停:暂停后输出还会开
    /// 好几秒。`outputting` 只在别的条件都满足时才问。
    public static func shouldHoldWhileOutputting(lastBundleID: String?, lastElapsed: Double?, lastDuration: Double?,
                                                 lastSeenAt: Date?, newBundleID: String?, newPlaying: Bool,
                                                 outputting: () -> Bool, now: Date) -> Bool {
        guard let lastBundleID, let lastSeenAt,
              PlaybackPlayer.builtin(forBundleID: lastBundleID)?.dropsSessionWhilePlaying == true,
              newBundleID != lastBundleID, !newPlaying else { return false }
        let since = now.timeIntervalSince(lastSeenAt)
        guard since >= 0 else { return false }
        if let lastDuration, lastDuration > 0 {
            guard (lastElapsed ?? 0) + since <= lastDuration + whileOutputtingEndGrace else { return false }
        } else {
            guard since <= whileOutputtingMaxHold else { return false }
        }
        return outputting()
    }
}
