import Foundation
import LyrimuseCore

// 播放源(LyrimuseCore/Local)审计之后的加固:轮询单飞、停播清理、焦点宽限的归类、最近记录的计次与拼页、
// 广告探针 / 跳过复核、资料库删除、缓存读取与退避。

@MainActor
func runPlaybackSourceHardeningTests() {
    pollSingleFlightTests()
    playbackStateTests()
    recentListensTests()
    browserProbeTests()
    libraryAndCacheTests()
    replayNoDurationFirstTick()
    wiringContracts()
}

// ---- 轮询单飞 ----

@MainActor
private func pollSingleFlightTests() {
    var f = PollSingleFlight()
    expectEqual(f.begin(), true, "轮询单飞: 空闲时可以起一轮")
    expectEqual(f.begin(), false, "轮询单飞: 在飞时不再起第二轮")
    expectEqual(f.begin(), false, "轮询单飞: 在飞时再来多少次也只合并成一次补跑")
    expectEqual(f.finish(), true, "轮询单飞: 在飞期间有人要过 → 收尾时补跑一轮")
    expectEqual(f.inFlight, false, "轮询单飞: 收尾后放开")
    expectEqual(f.begin(), true, "轮询单飞: 补跑那一轮能起")
    expectEqual(f.finish(), false, "轮询单飞: 期间没人要过 → 不补跑")
    f.invalidateInFlight()
    expectEqual(f.rerunRequested, false, "轮询单飞: 没有在飞的轮次时拖动不记补跑")
    _ = f.begin()
    f.invalidateInFlight()
    expectEqual(f.finish(), true, "轮询单飞: 拖动作废了在飞那一轮 → 回来后补跑一轮拿拖动之后的状态")
}

// ---- 停播 / 焦点宽限 / 缺时长 / 恢复信号 ----

@MainActor
private func playbackStateTests() {
    typealias P = LocalPlaybackSource
    expectEqual(P.hasTrackStateToClear(isPlaying: false, title: "暂停中的歌", lastKey: "k", pausedPositionMs: 12_000, hasAnchor: false), true,
                "停播清理: 先暂停再退出播放器 —— 没在播,但还挂着这首歌,要清")
    expectEqual(P.hasTrackStateToClear(isPlaying: true, title: "", lastKey: "", pausedPositionMs: nil, hasAnchor: false), true,
                "停播清理: 在播时照旧清")
    expectEqual(P.hasTrackStateToClear(isPlaying: false, title: "", lastKey: "", pausedPositionMs: nil, hasAnchor: false), false,
                "停播清理: 清过一次之后什么都不剩,不再重复清")

    typealias M = MediaControlClient
    expectEqual(M.isFocusHeldElsewhere(.targetNotPlayingMusic), false,
                "焦点宽限: 选中的播放器自己在放播客,不是焦点被占,不给 300 秒宽限")
    expectEqual(M.nilSnapshotClearsState(consecutiveNilCount: 2, failure: .targetNotPlayingMusic, nilStreakSeconds: 4), true,
                "焦点宽限: 播放器在放非音乐 → 按短宽限清(跟 collector 约 3 拍清一致)")
    expectEqual(M.isFocusHeldElsewhere(.notASong), true, "焦点宽限: 别的 App(浏览器)在放非歌曲内容仍算焦点被占")
    expectEqual(M.failureWithoutFallbackTarget(targetConfirmedGone: true), .appleScriptUnavailable,
                "焦点宽限: 回退已确认目标播放器不在 → 之后几拍记成问不到,不停在焦点被占那一档")
    expectEqual(M.failureWithoutFallbackTarget(targetConfirmedGone: false), nil,
                "焦点宽限: 从没有过回退目标时不改失败原因")

    expectEqual(P.lyricsLookupDuration(isRadio: false, isMusicVideo: true, duration: 245), nil,
                "查歌词时长: MV 当未知(collector 只用基条目,不建时长变体)")
    expectEqual(P.lyricsLookupDuration(isRadio: true, isMusicVideo: false, duration: 3390), nil, "查歌词时长: 电台当未知")
    expectEqual(P.lyricsLookupDuration(isRadio: false, isMusicVideo: false, duration: 200), 200, "查歌词时长: 普通曲目照报")

    let t0 = Date(timeIntervalSince1970: 1_790_400_000)
    expectEqual(P.freshResumeSignalAge(signalAt: t0, now: t0.addingTimeInterval(0.4)).map { abs($0 - 0.4) < 0.001 }, true,
                "恢复信号: 刚到的信号(0.4s)照用")
    expectEqual(P.freshResumeSignalAge(signalAt: t0, now: t0.addingTimeInterval(40)), nil,
                "恢复信号: 靠轮询发现恢复时手上是暂停那一刻的旧信号 → 当没拿到,不拿它砍起点")
    expectEqual(P.freshResumeSignalAge(signalAt: nil, now: t0), nil, "恢复信号: 没有信号")
}

/// 在播但头一拍没有时长(网页 / 汽水换歌常这样):那一拍不记账,下一拍有了时长按换歌处理 —— 学到的锚点滞后照样预置。
@MainActor
private func replayNoDurationFirstTick() {
    let suite = "lyrimuse-selftest.playback-source.no-duration"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let env = PlaybackPositionEnvironment(
        defaults: defaults, readPositionBias: { nil }, writePositionBias: { _ in }, outputRoute: { nil },
        browserProbeTrackChanged: { _, _ in }, browserProbeKick: { _, _, _ in }, browserProbeConsume: { _, _, _ in nil },
        browserProbeReopenAfterResume: { _ in }, spotifyProbeTrackChanged: { _, _ in }, spotifyProbeConsume: { _, _, _ in nil },
        spotifyProbeRequestConfirmation: { _ in }, latestAnchorPublishedWhilePaused: { false })
    let source = LocalPlaybackSource.makeForPositionReplay(environment: env)
    let soda = PlaybackPlayer.soda.bundleIdentifier
    let t0 = Date(timeIntervalSince1970: 1_790_300_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    func snap(_ title: String, anchor: Double, elapsed: Double, duration: Double?) -> MediaControlSnapshot {
        .forReplay(title: title, artist: "Fujii Kaze", album: "Prema", duration: duration, elapsedTime: elapsed,
                   playing: true, playbackRate: 1, bundleIdentifier: soda, anchorElapsedTime: anchor)
    }
    // 先学到汽水的锚点滞后 0.43(同 PositionReplayTests 的 replaySodaAnchorLag)。
    let lag = 0.43
    for t in stride(from: 0.0, through: 98, by: 2) {
        source.replayPosition(snap("My Anata", anchor: 0, elapsed: 0.3 + t, duration: 104), now: at(t))
    }
    source.replayPosition(snap("My Anata", anchor: 100.3 + lag, elapsed: 100.3 + lag, duration: 104), now: at(100))
    // 下一首头一拍没有时长。
    source.replayPosition(snap("情话", anchor: 0, elapsed: 0.2, duration: nil), now: at(104.2))
    expectEqual(source.replayPositionMs(at: at(104.2)), nil, "缺时长那一拍: 上一首的锚点拿掉,不拿它外推新歌")
    source.replayPosition(snap("情话", anchor: 0, elapsed: 2.2, duration: 200), now: at(106.2))
    let shown = source.replayPositionMs(at: at(106.2)).map { Double($0) / 1000 }
    expectEqual(shown.map { abs($0 - (2.2 + lag)) <= 0.02 }, true,
                "缺时长那一拍: 下一拍有了时长照换歌处理、预置学到的 +0.43(屏上 \(shown.map { String(format: "%.3f", $0) } ?? "nil"))")
}

// ---- 最近记录:第 N 次听 / 拼页 / 单条 track ----

@MainActor
private func recentListensTests() {
    typealias O = RecentPlayOrdinal
    let key: (String, String) -> String = { "\($0)|\($1)" }
    let totals = ["A|循环": 21, "B|别的": 5]
    let page2 = [(artist: "A", title: "循环"), (artist: "B", title: "别的")]
    let page1 = Array(repeating: (artist: "A", title: "循环"), count: 3)
    expectEqual(O.ordinals(rows: page2, totals: totals, playCountKey: key, preceding: page1), [18, 5],
                "第 N 次听: 第 2 页要减掉第 1 页里更新的同曲收听(21 − 3 = 18,不是 21)")
    expectEqual(O.ordinals(rows: page2, totals: totals, playCountKey: key, preceding: nil), [nil, nil],
                "第 N 次听: 前几页拼不齐 → 这一页不显示次数")
    expectEqual(O.ordinals(rows: page2, totals: totals, playCountKey: key), [21, 5], "第 N 次听: 第 1 页(默认)照旧")

    typealias C = LastfmPageComposer
    let a = C.Source(firstPosition: 0, rows: Array(0..<50))
    let b = C.Source(firstPosition: 40, rows: Array(40..<60))
    expectEqual(C.composeRange(lo: 0, hi: 60, sources: [a, b], identity: { String($0) }), Array(0..<60),
                "拼页: 0..<60 由 feed 50 行 + 第 3 页缓存拼齐")
    expectEqual(C.composeRange(lo: 0, hi: 70, sources: [a, b], identity: { String($0) }), nil, "拼页: 缺位置就拼不齐")
    expectEqual(C.lateInsertDetected(previousUTS: [300, 200, 100], currentUTS: [400, 300, 200, 100]), false,
                "插入检测: 新 scrobble 在最上面不算插入")
    expectEqual(C.lateInsertDetected(previousUTS: [300, 200, 100], currentUTS: [300, 250, 200, 100]), true,
                "插入检测: 比旧 feed 最新那条还旧的新记录(回填 / 手机补交)= 插进了中间")
    expectEqual(C.lateInsertDetected(previousUTS: [], currentUTS: [1, 2]), false, "插入检测: 头一份 feed 没有可比的")

    let single: [String: Any] = ["recenttracks": ["track": ["name": "唯一一条", "artist": ["#text": "A"],
                                                           "date": ["uts": "1790000000"]]]]
    expectEqual(LastfmRecentRows.parse(single).map(\.title), ["唯一一条"], "最近记录: 只有一条时 track 是对象,也要认")

    let existing: [(date: Date, album: String?)] = [(Date(timeIntervalSince1970: 300), nil), (Date(timeIntervalSince1970: 200), nil)]
    let nextPage: [(date: Date, album: String?)] = [(Date(timeIntervalSince1970: 200), nil), (Date(timeIntervalSince1970: 100), nil)]
    let merged = PlayCountBreakdownMath.appendingPage(existing: existing, page: nextPage, previousTotal: 10, newTotal: 11)
    expectEqual(merged.map { $0.date.timeIntervalSince1970 }, [300, 200, 100],
                "计次明细补页: 两页之间多了 1 次收听,新一页开头重复的那一行去掉")
    let noShift = PlayCountBreakdownMath.appendingPage(existing: existing, page: nextPage, previousTotal: 10, newTotal: 10)
    expectEqual(noShift.count, 4, "计次明细补页: 总数没变就不去重(同一秒的真实双端重复要留着)")

    expectEqual(LastfmEditorialInfo.cleaned("前半段 <a href=\"x\">某歌手</a> 后半段 <a href=\"https://last.fm\">Read more on Last.fm</a>. License"),
                "前半段 某歌手 后半段", "简介: 正文中间的链接只去掉标签,从最后一个链接截")
}

// ---- 广告探针 / 跳过复核 ----

@MainActor
private func browserProbeTests() {
    typealias S = YouTubeMusicAdSkipper
    expectEqual(S.normalizedBadgeCount("赞助商广告 1/2 · 0:20"), "1/2", "徽章归一: 剔掉倒计时")
    expectEqual(S.normalizedBadgeCount("Ad 2 of 2 · 0:05"), "2/2", "徽章归一: 英文写法")
    expectEqual(S.normalizedBadgeCount("广告 · 0:20"), "", "徽章归一: 只有倒计时没有计数")
    let clicked = S.ClickResult.skippable(desc: "BUTTON.ytp-skip-ad-button", badge: "赞助商广告 1/2 · 0:20", videoTime: 5)
    expectEqual(S.adAdvanced(afterClick: clicked, verify: .still(badge: "赞助商广告 1/2 · 0:19", videoTime: 6)), false,
                "跳过复核: 只是倒计时变了,不算跳过")
    expectEqual(S.adAdvanced(afterClick: clicked, verify: .still(badge: "赞助商广告 2/2 · 0:15", videoTime: 0)), true,
                "跳过复核: 计数翻到下一条才算")

    for (name, js) in [("probe", YouTubeMusicAdProbe.probeJS), ("skip", S.skipJS), ("verify", S.verifyJS)] {
        expectEqual(js.contains("PAUSED:"), true, "多标签页: \(name) JS 给暂停的标签页加 PAUSED: 前缀")
        expectEqual(js.contains("\""), false, "多标签页: \(name) JS 里不许出现双引号")
    }
    for family in [BrowserAutomationPermission.Family.chromium, .safari] {
        let s = BrowserTabProbeScript.build(bundleID: "com.google.Chrome", family: family,
                                            hostMarker: "music.youtube.com", js: "1", eventTimeoutSeconds: 1)
        expectEqual(s.contains("r starts with \"PAUSED:\""), true, "多标签页/\(family): 暂停的那页先记成备选")
        expectEqual(s.contains("if fallback is not \"\" then return fallback"), true, "多标签页/\(family): 都找完才交回备选")
        expectEqual(s.contains("set tabCount to count of tabs of window wi\n"), true, "多标签页/\(family): 数标签页那一步包在 try 里")
    }

    let quoted = "\"0|0|0||Live at \\\"Budokan\\\"\""
    expectEqual(YouTubeMusicAdProbe.parse(quoted)?.album, "Live at \"Budokan\"",
                "专辑名: 只脱两头一对引号,里面转义的引号还原")

    var backoff = ProbeFailureBackoff()
    let t0 = Date(timeIntervalSince1970: 1_790_500_000)
    expectEqual(backoff.suppresses(key: "k", now: t0), false, "探针退避: 没失败过不挡")
    backoff.noteFailure(key: "k", now: t0)
    expectEqual(backoff.suppresses(key: "k", now: t0.addingTimeInterval(1)), true, "探针退避: 第 1 次失败后 2 秒内不再探")
    expectEqual(backoff.suppresses(key: "k", now: t0.addingTimeInterval(2.5)), false, "探针退避: 过了 2 秒再探")
    for i in 2...8 { backoff.noteFailure(key: "k", now: t0.addingTimeInterval(Double(i))) }
    expectEqual(ProbeFailureBackoff.wait(afterFailures: 8), 60, "探针退避: 封顶 60 秒")
    expectEqual(backoff.suppresses(key: "别的歌", now: t0.addingTimeInterval(9)), false, "探针退避: 换了曲目不挡")
    backoff.reset()
    expectEqual(backoff.suppresses(key: "k", now: t0.addingTimeInterval(9)), false, "探针退避: 成功后清零")
}

// ---- 资料库删除 / 缓存读取 / 退避 / 令牌 / launchd ----

@MainActor
private func libraryAndCacheTests() {
    let script = MusicPlaybackController.removeFromLibraryScript(expectedName: "某首歌")
    expectEqual(script.contains("whose persistent ID is tPID"), true, "资料库删除: 先按 persistent ID 认")
    expectEqual(script.contains("considering case"), true, "资料库删除: 兜底按元数据时区分大小写")
    expectEqual(script.contains("if (count of exact) is not 1 then error"), true, "资料库删除: 兜底必须恰好一条")
    expectEqual(script.contains("if tAlbum is \"\" then error"), true, "资料库删除: 没有专辑名不按元数据删")
    expectEqual(script.contains("if d > 1 or d < -1 then error"), true, "资料库删除: 时长对不上不删")
    expectEqual(script.contains("delete (item 1 of matches)"), false, "资料库删除: 不再删「第一条匹配」")
    expectEqual(script.contains("current track changed"), true, "资料库删除: 歌名核对还在")

    let t = Date(timeIntervalSince1970: 1_790_600_000)
    expectEqual(EnrichCacheReader.decodeAlreadyFailed(mtime: t, failedMTime: t), true, "后台解码: 同一版上次没解开 → 不再重试")
    expectEqual(EnrichCacheReader.decodeAlreadyFailed(mtime: t.addingTimeInterval(1), failedMTime: t), false, "后台解码: 文件变了再试")
    expectEqual(EnrichCacheReader.decodeAlreadyFailed(mtime: nil, failedMTime: t), false, "后台解码: 取不到 mtime 不挡")

    let now = Date(timeIntervalSince1970: 1_790_700_000)
    expectEqual(ITunesSearchBackoff.until(status: 0, retryAfter: nil, now: now, current: nil),
                now.addingTimeInterval(ITunesSearchBackoff.forbiddenCooldown), "iTunes 退避: 网络层失败(0)按 30 秒,同 collector")
    expectEqual(MusicCatalogSearch.searchURL(title: "1+1", artist: "Beyoncé", storefront: "us")?.absoluteString.contains("1%2B1"), true,
                "iTunes 搜索: `+` 要编码,不然被当成空格")

    let oldFormat = try! JSONSerialization.data(withJSONObject: ["media_user_token": "x", "rejected_at": 1_790_000_000])
    expectEqual(AppleMusicTokenFile.parse(oldFormat, fileDate: Date(timeIntervalSince1970: 1_790_000_000.6))?.rejected, true,
                "Apple Music 令牌: 老格式(没有 saved_at)有 rejected_at 就是被拒了")
    let newFormat = try! JSONSerialization.data(withJSONObject: ["media_user_token": "x", "saved_at": 1_790_000_100, "rejected_at": 1_790_000_000])
    expectEqual(AppleMusicTokenFile.parse(newFormat, fileDate: Date())?.rejected, false,
                "Apple Music 令牌: 被拒之后重新登录过(saved_at 更晚)不算失效")

    let spawnScheduled = """
    gui/502/com.lyrimuse.collector = {
    \tactive count = 0
    \tstate = spawn scheduled
    \tlast exit code = 2
    }
    """
    expectEqual(LaunchdPrintParser.parse(printExitCode: 0, printOutput: spawnScheduled), .registeredNotRunning(lastExitCode: 2),
                "launchd: 崩溃后排着重启(spawn scheduled)= 注册着、此刻没在跑")
}

// ---- 私有接线的契约(扫源码文本):单飞 / 焦点回退 / 广告撤回 / 拖动作废读数 / 深页缓存 / 信任名单 ----
//
// 上面几节覆盖的是纯函数;这些修复的另一半是把它们接进 private 的调用点,行为测试够不着(要真起 media-control、
// 真驱动浏览器或真连 Last.fm)。接线被挪走或删掉时纯函数照样全绿,所以在这里把调用点本身钉住。

@MainActor
private func wiringContracts() {
    let sourcesRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    func code(_ path: String) -> String {
        guard let text = try? String(contentsOfFile: sourcesRoot.appendingPathComponent(path).path, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }
    /// `signature` 起到与它第一个 `{` 配对的 `}` 为止;找不到返回空串(断言随之失败)。
    func body(_ signature: String, in text: String) -> String {
        guard let start = text.range(of: signature), let open = text[start.lowerBound...].firstIndex(of: "{") else { return "" }
        var depth = 0
        var i = open
        while i < text.endIndex {
            if text[i] == "{" { depth += 1 } else if text[i] == "}" {
                depth -= 1
                if depth == 0 { return String(text[start.lowerBound...i]) }
            }
            i = text.index(after: i)
        }
        return ""
    }
    /// `a` 在 `text` 里出现、且第一次出现在 `b` 第一次出现之前。
    func before(_ a: String, _ b: String, in text: String) -> Bool {
        guard let ra = text.range(of: a), let rb = text.range(of: b) else { return false }
        return ra.lowerBound < rb.lowerBound
    }

    let source = code("LyrimuseCore/Local/LocalPlaybackSource.swift")
    let poll = body("private func poll() {", in: source)
    expectEqual(poll.split(separator: "\n").dropFirst().first?.trimmingCharacters(in: .whitespaces),
                "guard pollFlight.begin() else { return }", "单飞接线: poll() 第一句就过单飞闸,在飞时不再起第二轮")
    expectEqual(poll.contains("defer { self.finishPoll() }"), true, "单飞接线: 每一轮(含被丢弃的)收尾都放开单飞")
    expectEqual(poll.contains("await Self.runOffPool(Self.pollQueue)"), true, "单飞接线: 阻塞取数挪到专用队列,不占协作线程池")
    expectEqual(poll.contains("(MediaControlClient.fetchSnapshot(), MediaControlClient.lastSnapshotFailure)"), true,
                "单飞接线: 失败原因跟快照在同一条队列上一起取,回主线程再读可能已是别一轮的")
    expectEqual(body("private func finishPoll() {", in: source).contains("if pollFlight.finish() { poll() }"), true,
                "单飞接线: 收尾时期间有人要过就补跑")
    let seek = body("public func seek(toMs targetMs: Int) {", in: source)
    expectEqual(seek.contains("pollFlight.invalidateInFlight()"), true, "单飞接线: 拖动作废在飞那一轮、回来后补跑")
    expectEqual(seek.contains("env.browserProbeSeeked(now)"), true, "拖动作废读数: 拖动时通知浏览器探针")

    let client = code("LyrimuseCore/Local/MediaControlClient.swift")
    let focus = body("private static func snapshotAfterFocusLost() -> MediaControlSnapshot? {", in: client)
    let stateUpdate = "lastAcceptedDirectQueryPlayer = nextFocusFallbackPlayer("
    expectEqual(before("artistlessContentNotMusic(bundleID: player.bundleIdentifier, snapshot: s)", stateUpdate, in: focus), true,
                "焦点回退: 回退问到的无歌手非音乐内容先挡下,再动回退开关")
    expectEqual(before("trustedPlaybackRejected(bundleID: player.bundleIdentifier, snapshot: s)", stateUpdate, in: focus), true,
                "焦点回退: 信任播放器的非歌曲内容先挡下,再动回退开关")
    if let r = focus.range(of: "trustedPlaybackRejected(bundleID: player.bundleIdentifier, snapshot: s)") {
        expectEqual(focus[r.upperBound...].prefix(120).contains("setSnapshotFailure(.notASong)"), true,
                    "焦点回退: 信任播放器挡下时记成「不是歌」")
    }
    expectEqual(focus.contains("failureWithoutFallbackTarget(targetConfirmedGone: targetGone)"), true,
                "焦点回退: 没有回退目标时按「目标确认不在」改失败原因")
    expectEqual(focus.contains("fallbackTargetGone = snapshot == nil"), true, "焦点回退: 回退问不到就记下目标不在")

    let verifyAd = body("private func verifySpotifyAdViaAppleScript(forKey key: String) {", in: source)
    expectEqual(verifyAd.contains("self.revertLastTrackAfterAd(key: key)"), true, "广告撤回: AppleScript 晚到确认是广告 → 撤回「上次在听」")
    let revert = body("private func revertLastTrackAfterAd(key: String) {", in: source)
    expectEqual(revert.contains("prev.key == key"), true, "广告撤回: 只撤回同一首写进去的那一次")
    for k in ["np:lastTrackTitle", "np:lastTrackArtist", "np:lastTrackAlbum"] {
        expectEqual(revert.contains("\"\(k)\""), true, "广告撤回: \(k) 还原成写之前的值")
    }
    expectEqual(revert.contains("lastPersistedTrackTitle = prev.persistedTitle"), true, "广告撤回: 去重用的上次写入标题一起还原")
    expectEqual(source.contains("!adByFields, !spotifyNoticeSaysAd, !knownAdThisTrack,"), true,
                "广告撤回: 通知已说是广告 / 同曲已确认是广告时不写「上次在听」")
    expectEqual(before("lastTrackBeforeWrite = (key: snapshot.trackKey,", "UserDefaults.standard.set(newTitle, forKey: \"np:lastTrackTitle\")", in: source), true,
                "广告撤回: 写之前先记下原值")

    let env = code("LyrimuseCore/Local/PlaybackPositionEnvironment.swift")
    expectEqual(env.contains("browserProbeSeeked: { BrowserPositionProbe.shared.discardReadings(before: $0) }"), true,
                "拖动作废读数: 真实环境把拖动接到浏览器探针的 discardReadings")
    let probe = code("LyrimuseCore/Local/BrowserPositionProbe.swift")
    let discard = body("public func discardReadings(before moment: Date) {", in: probe)
    expectEqual(discard.contains("seekBarrier = moment"), true, "拖动作废读数: 记下拖动时刻,在飞的那次回来也不采信")
    expectEqual(discard.contains("snapshot.capturedAt < moment { cached = nil }"), true, "拖动作废读数: 拖动之前抓到的缓存读数丢掉")
    let apply = body("private func applyProbeResult(", in: probe)
    expectEqual(before("if let barrier = seekBarrier, startedAt < barrier { return }", "cached = CachedResult(", in: apply), true,
                "拖动作废读数: 拖动之前发起的探测结果不进缓存")
    expectEqual(before("guard myGeneration == generation else { return }", "lastAttemptEndedAt = Date()", in: apply), true,
                "探针退避: 上一首晚到的结果不给新歌记退避")
    expectEqual(probe.contains("bundleID: hostBundleID, startedAt: startedAt)"), true, "拖动作废读数: 探测把发起时刻带回来比对")

    let stats = code("lyrimuse/Settings/LastfmStatsService.swift")
    if let r = stats.range(of: "LastfmPageComposer.lateInsertDetected(") {
        let after = stats[r.upperBound...]
        expectEqual(after.prefix(300).contains("dropDeepRecentPageCache(reason:"), true, "深页缓存: 检测到记录插进中间就作废深页")
        expectEqual(before("dropDeepRecentPageCache(reason:", "feedCompletedRows = completed", in: String(after)), true,
                    "深页缓存: 拿旧 feed 比完再换成新 feed")
    } else {
        expectEqual(true, false, "深页缓存(契约): 读不到 lateInsertDetected 调用点(改名了?)")
    }
    let drop = body("func dropDeepRecentPageCache(reason: String) {", in: stats)
    expectEqual(drop.contains("filter { $0 >= 3 }"), true, "深页缓存: 只作废第 3 页起(第 1、2 页由 feed 每次重写)")
    for m in ["recentPageCache[p] = nil", "recentPageCacheTotal[p] = nil", "fetchedAt[Self.recentPageCacheKey(p)] = nil"] {
        expectEqual(drop.contains(m), true, "深页缓存: 作废时一并清 \(m)")
    }
    if let r = stats.range(of: "if let exact {") {
        let composed = String(stats[r.lowerBound...].prefix(600))
        let block = composed.components(separatedBy: "return\n").first ?? composed
        expectEqual(block.contains("recentPageCache[") || block.contains("storeFetchedPage("), false,
                    "深页缓存: 拼出来的页不写回成抓取态缓存")
    } else {
        expectEqual(true, false, "深页缓存(契约): 读不到拼页那段(改名了?)")
    }
    let backfill = code("lyrimuse/Settings/ScrobbleBackfillService.swift")
    if let r = backfill.range(of: "if let out, out.accepted > 0 {") {
        expectEqual(backfill[r.upperBound...].prefix(300).contains("LastfmStatsService.shared.dropDeepRecentPageCache("), true,
                    "深页缓存: 回填真的补进了记录就作废深页")
    } else {
        expectEqual(true, false, "深页缓存(契约): 读不到回填成功那段(改名了?)")
    }

    let trusted = code("LyrimuseCore/Local/TrustedPlayers.swift")
    let accepted = body("public static func isAccepted(_ bundleID: String?) -> Bool {", in: trusted)
    expectEqual(before("PlaybackPlayer.allCases.contains(", "trusted: current)", in: accepted), true,
                "信任名单: 内置播放器先判掉,不在轮询热路径上每次读盘解码 features.json")
    expectEqual(TrustedPlayers.isAccepted(PlaybackPlayer.spotify.bundleIdentifier), true, "信任名单: 内置播放器直接认")
    expectEqual(TrustedPlayers.isAccepted(PlaybackPlayer.auto.bundleIdentifier, trusted: [:]), false, "信任名单: 自动识别那一项不是播放器")

    // 网页平台探针只对配对过的浏览器跑:App 侧 YouTube Music 广告探针的入口 + 配对关系镜像给 collector。
    let ytAd = code("LyrimuseCore/Local/YouTubeMusicAdProbe.swift")
    let kick = body("public func kickIfNeeded(bundleIdentifier: String?, key: String) {", in: ytAd)
    expectEqual(before("BrowserPositionProbe.shared.isPaired(bundleID: hostBundleID, platformID: \"youtubeMusic\")", "inFlightKey = key", in: kick), true,
                "网页探针配对: YouTube Music 广告探针没配对就不发起")
    let store = code("lyrimuse/Settings/FeatureSettingsStore.swift")
    expectEqual(store.contains("case browserPlatformPairs = \"browser_platform_pairs\""), true, "网页探针配对: features.json 键名跟 collector 一致")
    expectEqual(store.contains("browserPlatformPairs: browserPlatformPairs\n"), true, "网页探针配对: 写盘快照带上配对镜像")
    expectEqual(store.contains("browserPlatformPairs = f.browserPlatformPairs"), true, "网页探针配对: 读盘时认回已写的镜像(没变就不重写)")
    let sync = body("public func syncBrowserPlatformPairs(_ pairs: [String: Set<String>]) async {", in: store)
    expectEqual(before("guard next != browserPlatformPairs else { return }", "await save()", in: sync) && sync.contains("BrowserPositionProbe.mirroredPairs(pairs)"), true,
                "网页探针配对: 同步时先规整、没变就不落盘")
    let delegate = code("lyrimuse/AppDelegate.swift")
    if let r = delegate.range(of: "settings.$browserPlatformPairs") {
        expectEqual(delegate[r.upperBound...].prefix(300).contains("FeatureSettingsStore.shared.syncBrowserPlatformPairs(pairs)"), true,
                    "网页探针配对: 配对一改(含启动那一次)就镜像进 features.json")
    } else {
        expectEqual(true, false, "网页探针配对(契约): AppDelegate 里读不到对 browserPlatformPairs 的订阅")
    }
    let goPairs = code("../../lyrimuse-collector/browserpairs.go")
    for (goName, id) in [("browserPlatformYouTubeMusic", "youtubeMusic"), ("browserPlatformSpotifyWeb", "spotifyWeb")] {
        expectEqual(goPairs.range(of: goName + #" += "\#(id)""#, options: .regularExpression) != nil, true, "网页探针配对: collector 的 \(goName) 跟 App 的平台 id \(id) 一致")
        expectEqual(BrowserPositionProbe.supportedPlatforms.contains { $0.id == id }, true, "网页探针配对: \(id) 是 App 支持的平台")
    }

    let mirrored = BrowserPositionProbe.mirroredPairs([
        "youtubeMusic": ["com.google.Chrome", "com.apple.Safari", ""], "spotifyWeb": [], "": ["company.thebrowser.Browser"],
    ])
    expectEqual(mirrored, ["youtubeMusic": ["com.apple.Safari", "com.google.Chrome"]],
                "网页探针配对: 镜像去掉空平台 / 空 id,浏览器按字母排(同一份配对每次写出来一样)")
    expectEqual(BrowserPositionProbe.mirroredPairs([:]), [:], "网页探针配对: 一个都没配写成空对象,不是缺键")
}
