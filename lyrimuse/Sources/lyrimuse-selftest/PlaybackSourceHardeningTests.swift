import CoreGraphics
import Foundation
import ImageIO
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
    spotifyConnectMirrorTests()
    nowPlayingNoticeTests()
    scriptServerTests()
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
                "焦点宽限: 播放器在放非音乐 → 按短宽限清(跟引擎约 3 拍清一致)")
    expectEqual(M.isFocusHeldElsewhere(.targetLoading), false, "加载宽限: 播放器在加载下一首不是焦点被占")
    expectEqual(M.nilSnapshotClearsState(consecutiveNilCount: 5, failure: .targetLoading,
                                         nilStreakSeconds: M.loadingGraceSeconds - 0.5), false,
                "加载宽限: 播放器在加载下一首,拍数够了也留着上一首")
    expectEqual(M.nilSnapshotClearsState(consecutiveNilCount: 5, failure: .targetLoading,
                                         nilStreakSeconds: M.loadingGraceSeconds), true,
                "加载宽限: 一直报加载,到上限清")
    expectEqual(M.isFocusHeldElsewhere(.notASong), true, "焦点宽限: 别的 App(浏览器)在放非歌曲内容仍算焦点被占")
    expectEqual(M.failureWithoutFallbackTarget(targetConfirmedGone: true), .appleScriptUnavailable,
                "焦点宽限: 回退已确认目标播放器不在 → 之后几拍记成问不到,不停在焦点被占那一档")
    expectEqual(M.failureWithoutFallbackTarget(targetConfirmedGone: false), nil,
                "焦点宽限: 从没有过回退目标时不改失败原因")

    expectEqual(P.lyricsLookupDuration(isRadio: false, isMusicVideo: true, duration: 245), nil,
                "查歌词时长: MV 当未知(引擎只用基条目,不建时长变体)")
    expectEqual(P.lyricsLookupDuration(isRadio: true, isMusicVideo: false, duration: 3390), nil, "查歌词时长: 电台当未知")
    expectEqual(P.lyricsLookupDuration(isRadio: false, isMusicVideo: false, duration: 200), 200, "查歌词时长: 普通曲目照报")

    let t0 = Date(timeIntervalSince1970: 1_790_400_000)
    expectEqual(P.freshResumeSignalAge(signalAt: t0, now: t0.addingTimeInterval(0.4)).map { abs($0 - 0.4) < 0.001 }, true,
                "恢复信号: 刚到的信号(0.4s)照用")
    expectEqual(P.freshResumeSignalAge(signalAt: t0, now: t0.addingTimeInterval(40)), nil,
                "恢复信号: 靠轮询发现恢复时手上是暂停那一刻的旧信号 → 当没拿到,不拿它砍起点")
    expectEqual(P.freshResumeSignalAge(signalAt: nil, now: t0), nil, "恢复信号: 没有信号")
    // 「恢复播放」那一份晚于这次暂停,轮询晚了多久都照用(真机 media-control 卡满超时,晚了 5.6s)。
    expectEqual(P.resumeSignalAge(resumeSignalAt: t0, now: t0.addingTimeInterval(5.597)).map { abs($0 - 5.597) < 0.001 }, true,
                "恢复信号: 只记恢复的那一份,晚了 5.6s 照用")
    expectEqual(P.resumeSignalAge(resumeSignalAt: t0, now: t0.addingTimeInterval(61)), nil, "恢复信号: 超过一分钟的不认")
    expectEqual(P.resumeSignalAge(resumeSignalAt: t0, now: t0.addingTimeInterval(-1)), nil, "恢复信号: 时刻在后的不认")
    expectEqual(P.resumeSignalAge(resumeSignalAt: nil, now: t0), nil, "恢复信号: 没有恢复信号")
    expectEqual(M.pollSnapshotTimeout(fallbackPlayer: .spotify), 2, "状态查询超时: Spotify 卡住 2s 就改问它的 AppleScript")
    expectEqual(M.pollSnapshotTimeout(fallbackPlayer: .appleMusic), 2, "状态查询超时: Apple Music 同上")
    expectEqual(M.pollSnapshotTimeout(fallbackPlayer: .kaset), 2, "状态查询超时: Kaset 同上")
    expectEqual(M.pollSnapshotTimeout(fallbackPlayer: .qqMusic), 5, "状态查询超时: 没有 AppleScript 字典的照旧 5s")
    expectEqual(M.pollSnapshotTimeout(fallbackPlayer: nil), 5, "状态查询超时: 还没接受过快照照旧 5s")
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
                now.addingTimeInterval(ITunesSearchBackoff.forbiddenCooldown), "iTunes 退避: 网络层失败(0)按 30 秒,同引擎")
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
    expectEqual(poll.contains("let fetched = MediaControlClient.fetchSnapshotWithProvenance()")
                    && poll.contains("return (fetched.snapshot, fetched.provenance, MediaControlClient.lastSnapshotFailure)"), true,
                "单飞接线: 失败原因、快照与它的来源在同一条队列上一起取,回主线程再读可能已是别一轮的")
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
    // Amazon 不报进度:单问那份要跟主路径一样换成日志时钟,不然屏上从 0 重新走(见 02 章决策 113)。
    expectEqual(before("amazonMusicReading(", stateUpdate, in: focus)
                    && focus.contains("snapshot = probed.snapshot.withPlayerClock(reading.position, capturedAt: now)"), true,
                "焦点回退: 单问到的 Amazon 换成日志时钟那份位置")
    if let r = focus.range(of: "if reading.staleMetadata {") {
        expectEqual(focus[r.upperBound...].prefix(120).contains("setSnapshotFailure(.targetNotPlayingMusic)"), true,
                    "焦点回退: Amazon 上一次会话的旧曲目跟主路径一样不采纳")
    } else {
        expectEqual(false, true, "焦点回退: Amazon 旧曲目那一帧要挡")
    }
    let mainAssemble = client.components(separatedBy: "Self.amazonMusicReading(").count - 1
    expectEqual(mainAssemble, 1, "Amazon 位置: 主路径走同一个 amazonMusicReading,不另写一份")

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

    // 网页平台探针只对配对过的浏览器跑:App 侧 YouTube Music 广告探针的入口 + 配对关系镜像给引擎。
    let ytAd = code("LyrimuseCore/Local/YouTubeMusicAdProbe.swift")
    let kick = body("public func kickIfNeeded(bundleIdentifier: String?, key: String) {", in: ytAd)
    expectEqual(before("BrowserPositionProbe.shared.isPaired(bundleID: hostBundleID, platformID: \"youtubeMusic\")", "inFlightKey = key", in: kick), true,
                "网页探针配对: YouTube Music 广告探针没配对就不发起")
    let store = code("lyrimuse/Settings/FeatureSettingsStore.swift")
    expectEqual(store.contains("case browserPlatformPairs = \"browser_platform_pairs\""), true, "网页探针配对: features.json 键名跟引擎一致")
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
    let goPairs = code("../../lyrimuse-engine/browserpairs.go")
    for (goName, id) in [("browserPlatformYouTubeMusic", "youtubeMusic"), ("browserPlatformSpotifyWeb", "spotifyWeb")] {
        expectEqual(goPairs.range(of: goName + #" += "\#(id)""#, options: .regularExpression) != nil, true, "网页探针配对: 引擎的 \(goName) 跟 App 的平台 id \(id) 一致")
        expectEqual(BrowserPositionProbe.supportedPlatforms.contains { $0.id == id }, true, "网页探针配对: \(id) 是 App 支持的平台")
    }

    let mirrored = BrowserPositionProbe.mirroredPairs([
        "youtubeMusic": ["com.google.Chrome", "com.apple.Safari", ""], "spotifyWeb": [], "": ["company.thebrowser.Browser"],
    ])
    expectEqual(mirrored, ["youtubeMusic": ["com.apple.Safari", "com.google.Chrome"]],
                "网页探针配对: 镜像去掉空平台 / 空 id,浏览器按字母排(同一份配对每次写出来一样)")
    expectEqual(BrowserPositionProbe.mirroredPairs([:]), [:], "网页探针配对: 一个都没配写成空对象,不是缺键")

    // 换歌后取图还在路上时不清旧封面:兜底期限按"一次取图最多能跑多久"定(子进程超时 + 宽限)。从换歌 / 每次重试前
    // 起算 3 秒的话,机器满载时取图本身就能超过它,同一张专辑的下一首也会先把封面清掉、几秒后才回来。
    let fetchArtwork = body("private func fetchArtworkForCurrentTrack(expectedKey: String) {", in: source)
    expectEqual(source.contains("artworkInFlightBackstop: TimeInterval = MediaControlClient.artworkTimeout + artworkStaleTimeout"), true,
                "封面兜底: 取图在路上时的期限 = 子进程超时 + 宽限")
    expectEqual(source.contains("scheduleArtworkStaleTimeout(forKey: key, after: Self.artworkInFlightBackstop)"), true,
                "封面兜底: 换歌那一刻排的兜底要盖住第一次取图")
    expectEqual(fetchArtwork.contains("after: Self.artworkRetryDelays[round] + Self.artworkInFlightBackstop)"), true,
                "封面兜底: 每次重试前排的兜底要盖住这次等待加下一次取图")
    expectEqual(fetchArtwork.contains("self.scheduleArtworkStaleTimeout(forKey: expectedKey)\n"), false,
                "封面兜底: 重试前别再排默认的 3 秒期限")
    expectEqual(source.contains("artworkQueue = DispatchQueue(label: \"lyrimuse.playback.artwork\", qos: .userInitiated)"), true,
                "封面兜底: 取封面跟轮询同一档 QoS")

    // 歌词引擎的 launchd 任务按 Interactive 跑:后台档(调度优先级 4、磁盘读写限流)在机器忙时把切歌晚认好几秒、
    // 写一次缓存拖到几十秒。
    let engineService = code("lyrimuse/Settings/EngineServiceManager.swift")
    expectEqual(engineService.contains("\"ProcessType\": \"Interactive\","), true, "歌词引擎调度: launchd 任务按 Interactive 跑")
    expectEqual(engineService.contains("\"ProcessType\": \"Background\""), false, "歌词引擎调度: 别退回后台档")

    // 桌面版 Spotify 的 Connect 镜像:两条取快照的入口都先过它;先问 CoreAudio,不该问时一个子进程都不起。
    let autoDetected = body("private static func fetchAutoDetectedSnapshot() -> MediaControlSnapshot? {", in: client)
    let multiSelected = body("private static func fetchMultiSelectedSnapshot(_ players: Set<PlaybackPlayer>) -> MediaControlSnapshot? {", in: client)
    expectEqual(autoDetected.contains("resolvingSpotifyConnectMirror(fetchRawMediaControlSnapshot())"), true,
                "Spotify 镜像接线: 自动识别那条路先过镜像判定")
    expectEqual(multiSelected.contains("resolvingSpotifyConnectMirror(fetchRawMediaControlSnapshot())"), true,
                "Spotify 镜像接线: 多选那条路先过镜像判定")
    let mirror = body("private static func resolvingSpotifyConnectMirror(", in: client)
    expectEqual(before("ProcessAudioOutput.isRunningOutput(bundleID: bundleID)",
                       "NowPlayingClientsProbe.snapshot(forBundleID: webSource)", in: mirror), true,
                "Spotify 镜像接线: 先问 CoreAudio,再起子进程问网页版")
    expectEqual(mirror.contains("let web = ask ? NowPlayingClientsProbe.snapshot(forBundleID: webSource) : nil"), true,
                "Spotify 镜像接线: 不该问时不起子进程")
    expectEqual(mirror.contains("if !useWeb { spotifyWebSource = nil }"), true,
                "Spotify 镜像接线: 没换成网页版就清掉记录,之后不再问")
    let noteAcceptedBody = body("private static func noteAccepted(bundleID: String) {", in: client)
    expectEqual(noteAcceptedBody.contains("spotifyWebSource = webSource"), true, "Spotify 镜像接线: 每次接受快照都更新网页版来源")
    expectEqual(noteAcceptedBody.contains("fallbackFailureStreak = 0"), true, "焦点回退: 接受了快照,回退的失败拍数清零")

    // 播放控制被拦下时各展示面置灰 + 说明:判据跟真发指令同一个,每拍轮询收尾刷新,六个展示面都接上。
    let controller = code("LyrimuseCore/Local/MusicPlaybackController.swift")
    expectEqual(controller.contains("public static func controlsWithheld() -> Bool { currentBaseRoute() == .withheld }")
                && body("private static func dispatchRoute(", in: controller).contains("let base = currentBaseRoute()"), true,
                "拦下置灰: 判据跟发指令同一个 currentBaseRoute")
    let localSource = code("LyrimuseCore/Local/LocalPlaybackSource.swift")
    expectEqual(body("private func finishPoll() {", in: localSource).contains("refreshPlaybackControlsWithheld()"), true,
                "拦下置灰: 每拍轮询收尾刷新")
    let coordinatorSource = code("lyrimuse/PlaybackCoordinator.swift")
    expectEqual(coordinatorSource.contains("s.$playbackControlsWithheldBundleID.removeDuplicates()")
                && coordinatorSource.contains(".assign(to: \\.playbackControlsWithheldReason, on: self)"), true,
                "拦下置灰: 协调器把拦下的播放器换成说明")
    for (file, needles) in [
        ("lyrimuse/UI/LyricsWindowView.swift", ["self?.controlsWithheldReason = $0", ".help(playback.controlsWithheldReason ?? L10n.t(\"上一首\"))"]),
        ("lyrimuse/UI/NotchLyricsView.swift", ["self?.controlsWithheldReason = $0", "WithheldControlHint(key: hintKey", "hintKey: \"transport.next\""]),
        ("lyrimuse/UI/LyricsOverlayView.swift", ["self?.controlsWithheldReason = $0", "case .next: return playback.controlsWithheldReason ?? L10n.t(\"下一首\")"]),
        ("lyrimuse/MenuBar/MenuBarPanel.swift", ["self?.controlsWithheldReason = $0", ".help(playback.controlsWithheldReason ?? \"\")"]),
        ("lyrimuse/MenuBar/MenuBarStatusItem.swift", ["self?.hoverControls.setWithheld(on)"]),
        ("lyrimuse/TouchBar/TouchBarLyricsController.swift", ["updateTransportEnabled(p.playbackControlsWithheldReason == nil)"]),
    ] {
        let text = code(file)
        expectEqual(needles.allSatisfy { text.contains($0) }, true, "拦下置灰: \(file) 接上了")
    }
    let windowText = code("lyrimuse/UI/LyricsWindowView.swift")
    expectEqual(windowText.components(separatedBy: ".opacity(playback.controlsWithheldReason == nil ? 1 : PlaybackCoordinator.withheldControlOpacity)").count - 1, 2,
                "拦下置灰: 歌词窗口完整、迷你两排都置灰")
    let focusLost = body("private static func snapshotAfterFocusLost() -> MediaControlSnapshot? {", in: client)
    expectEqual(focusLost.contains("fallbackFailureStreak = snapshot == nil ? fallbackFailureStreak + 1 : 0")
                && focusLost.contains("consecutiveFailures: fallbackFailureStreak)"), true,
                "焦点回退: 问不到时按连着失败的拍数决定关不关,问到就清零")

    // 会话在放时被撤(网易云冷启动,02 章决策 96):保持接在两条取快照的入口共用的 heldAcrossPlayerGap;保持出来的那首,播放控制
    // 不发 —— 这时系统焦点是空的或者在别人手里,media-control 的指令会落在焦点上。
    let gapHold = body("private static func heldAcrossPlayerGap(_ snapshot: MediaControlSnapshot?) -> MediaControlSnapshot? {", in: client)
    expectEqual(gapHold.contains("PlayerGapHold.shouldHoldWhileOutputting(") && gapHold.contains("holdingDroppedSession = true")
                && gapHold.contains("outputting: { ProcessAudioOutput.isRunningOutput(bundleID: lastBundleID) }"), true,
                "会话在放时被撤: 保持接在 heldAcrossPlayerGap、按进程出声判,保持时记下")
    expectEqual(body("public static func focusHeldByAnotherApp() -> Bool {", in: client).contains("return viaProbe || holdingDroppedSession"),
                true, "会话在放时被撤: 保持出来的那首,播放控制不发")

    // 按相对量的写入要排队(07 章决策 139、138 补记):Amazon 循环键按一下进一档、QQ「喜欢」按一下翻一次,连点时后一次读到的
    // 是前一次按之前的状态。行为在 players 组用桩测,这里钉住接线:锁在读状态之前拿,按完等确认。
    let amazon = code("LyrimuseCore/Local/AmazonMusicModeControl.swift")
    let amazonSet = body("public static func setMode(", in: amazon)
    expectEqual(before("writeLock.lock()", "readSettings(logPath: logPath)", in: amazonSet)
                && amazonSet.contains("pressUntilConfirmed(from: start, to: target"), true,
                "Amazon 写入: 先排队再读当前档,逐下按、等日志确认")
    expectEqual(before("guard AXIsProcessTrusted() else { return nil }", "readSettings(logPath: logPath)",
                       in: body("public static func readMode(", in: amazon)), true,
                "Amazon 读档: 没有辅助功能权限不报档位,两颗键不出现(按不了)")
    let qqFavorite = body("public static func setFavorited(_ value: Bool) -> Bool {", in: code("LyrimuseCore/Local/QQMusicMenuControl.swift"))
    expectEqual(before("favoriteLock.lock()", "favoriteItem()", in: qqFavorite) && qqFavorite.contains("return waitFor(value"), true,
                "QQ 喜欢: 先排队再读标题,按完等标题翻过来")
}

// ---- 桌面版 Spotify 的 Connect 镜像 ----

@MainActor
private func spotifyConnectMirrorTests() {
    typealias M = SpotifyConnectMirror
    let spotify = PlaybackPlayer.spotify.bundleIdentifier
    let webkit = "com.apple.WebKit.GPU"
    expectEqual(M.shouldAskWebPlayer(focusBundleID: spotify, webSourceBundleID: webkit, desktopOutputting: false), true,
                "Spotify 镜像: 上一份来自网页版、焦点跳到没在出声的桌面版 → 问一次网页版")
    expectEqual(M.shouldAskWebPlayer(focusBundleID: spotify, webSourceBundleID: webkit, desktopOutputting: true), false,
                "Spotify 镜像: 桌面版自己在本机输出音频 → 是它在出声,不问")
    expectEqual(M.shouldAskWebPlayer(focusBundleID: spotify, webSourceBundleID: nil, desktopOutputting: false), false,
                "Spotify 镜像: 上一份不是网页版(遥控音箱、手机) → 不问,照旧用桌面版")
    expectEqual(M.shouldAskWebPlayer(focusBundleID: webkit, webSourceBundleID: webkit, desktopOutputting: false), false,
                "Spotify 镜像: 焦点上就是网页版 → 不问")
    expectEqual(M.shouldAskWebPlayer(focusBundleID: PlaybackPlayer.appleMusic.bundleIdentifier, webSourceBundleID: webkit,
                                     desktopOutputting: false), false,
                "Spotify 镜像: 焦点上是别的播放器 → 不问")
    expectEqual(M.shouldAskWebPlayer(focusBundleID: spotify, webSourceBundleID: spotify, desktopOutputting: false), false,
                "Spotify 镜像: 记下的来源就是桌面版自己 → 不问")
    expectEqual(M.shouldAskWebPlayer(focusBundleID: spotify, webSourceBundleID: "", desktopOutputting: false), false,
                "Spotify 镜像: 空来源 → 不问")

    func snap(_ title: String, artist: String, playing: Bool, bundle: String) -> MediaControlSnapshot {
        .forReplay(title: title, artist: artist, album: "How Long Do You Think It's Gonna Last?", duration: 254, elapsedTime: 230,
                   playing: playing, playbackRate: playing ? 1 : 0, bundleIdentifier: bundle, anchorElapsedTime: 230)
    }
    let desktop = snap("Renegade", artist: "Big Red Machine", playing: true, bundle: spotify)
    expectEqual(M.webPlayerWins(desktop: desktop, web: snap("Renegade", artist: "Big Red Machine, Taylor Swift", playing: true,
                                                             bundle: webkit)), true,
                "Spotify 镜像: 网页版报的是同一首 → 用网页版(两边歌手写法不同不影响)")
    expectEqual(M.webPlayerWins(desktop: desktop, web: snap("Renegade", artist: "Big Red Machine, Taylor Swift", playing: false,
                                                             bundle: webkit)), true,
                "Spotify 镜像: 网页版刚暂停、桌面版还报在播 → 仍用网页版")
    expectEqual(M.webPlayerWins(desktop: desktop, web: snap("WHERE IS MY HUSBAND!", artist: "RAYE", playing: true, bundle: webkit)), false,
                "Spotify 镜像: 网页版报的是另一首 → 用桌面版")
    expectEqual(M.webPlayerWins(desktop: desktop, web: nil), false, "Spotify 镜像: 问不到网页版 → 用桌面版")
    expectEqual(M.webPlayerWins(desktop: snap("", artist: "Big Red Machine", playing: true, bundle: spotify),
                                web: snap("", artist: "Big Red Machine", playing: true, bundle: webkit)), false,
                "Spotify 镜像: 曲名为空不算同一首")
    expectEqual(M.webPlayerWins(desktop: desktop, web: snap("Renegade\u{200B} ", artist: "Big Red Machine", playing: true,
                                                             bundle: webkit)), true,
                "Spotify 镜像: 曲名按清洗后的比(零宽字符、首尾空白)")

    expectEqual(M.nextWebSource(acceptedBundleID: webkit, acceptedIsSpotifyWebBrowser: true), webkit,
                "Spotify 镜像: 接受了配对网页版的浏览器 → 记下它")
    expectEqual(M.nextWebSource(acceptedBundleID: spotify, acceptedIsSpotifyWebBrowser: false), nil,
                "Spotify 镜像: 接受了别的来源 → 清掉")
    expectEqual(M.nextWebSource(acceptedBundleID: "", acceptedIsSpotifyWebBrowser: true), nil, "Spotify 镜像: 空 bundle id 不记")

    expectEqual(ProcessAudioOutput.isRunningOutput(bundleID: ""), false, "进程音频输出: 空 bundle id 当没在输出")
    expectEqual(ProcessAudioOutput.isRunningOutput(bundleID: "me.yudaotor.lyrimuse.no-such-app"), false,
                "进程音频输出: 没有这个进程对象当没在输出")
}

// ---- 换歌通知 ----

@MainActor
private func nowPlayingNoticeTests() {
    typealias N = NowPlayingNotice
    func announce(enabled: Bool = true, title: String = "晴天", isPlaying: Bool = true, isBreak: Bool = false,
                  appIsActive: Bool = false, isFirstSighting: Bool = false, sinceStart: TimeInterval = 60) -> Bool {
        N.shouldAnnounce(enabled: enabled, title: title, isPlaying: isPlaying, isBreak: isBreak,
                         appIsActive: appIsActive, isFirstSighting: isFirstSighting, sinceStart: sinceStart)
    }
    expectEqual(announce(), true, "换歌通知: 开着、在放、换了一首 → 发")
    expectEqual(announce(enabled: false), false, "换歌通知: 开关关着不发")
    expectEqual(announce(title: ""), false, "换歌通知: 没有歌名不发")
    expectEqual(announce(isPlaying: false), false, "换歌通知: 暂停着不发")
    expectEqual(announce(isBreak: true), false, "换歌通知: 广告 / 电台口白不发")
    expectEqual(announce(appIsActive: true), false, "换歌通知: Lyrimuse 自己在前台不发")
    expectEqual(announce(isFirstSighting: true, sinceStart: 2), false, "换歌通知: 启动时已经在放的那首不算换歌")
    expectEqual(announce(isFirstSighting: true, sinceStart: 120), true, "换歌通知: 启动一阵之后才放的第一首照发")
    expectEqual(announce(isFirstSighting: false, sinceStart: 2), true, "换歌通知: 刚启动但已经换过一首了照发")

    expectEqual(N.body(title: "晴天", artist: "周杰伦", album: "叶惠美"), "周杰伦 — 叶惠美", "换歌通知正文: 歌手 — 专辑")
    expectEqual(N.body(title: "晴天", artist: "周杰伦", album: ""), "周杰伦", "换歌通知正文: 没有专辑只写歌手")
    expectEqual(N.body(title: "Flowers", artist: "Miley Cyrus", album: "Flowers - Single"), "Miley Cyrus",
                "换歌通知正文: 同名单曲不重复写专辑")
    expectEqual(N.body(title: "Flowers", artist: "Miley Cyrus", album: "flowers"), "Miley Cyrus",
                "换歌通知正文: 专辑就是歌名(不分大小写)不写")
    expectEqual(N.body(title: "晴天", artist: "", album: "叶惠美"), "叶惠美", "换歌通知正文: 没有歌手只写专辑")
    expectEqual(N.body(title: " 晴天 ", artist: " 周杰伦 ", album: " 叶惠美 "), "周杰伦 — 叶惠美", "换歌通知正文: 去掉首尾空白")

    // 封面跟界面上显示的是同一张:高清替代优先;界面会换成高清替代时先等它,到时限手上有什么用什么。
    func cover(highRes: Bool = false, settled: Bool = false, hasImage: Bool = false, seeks: Bool = false,
               timedOut: Bool = false) -> N.CoverPick {
        N.coverPick(highResArrived: highRes, systemSettled: settled, systemHasImage: hasImage, seeksHighRes: seeks,
                    timedOut: timedOut)
    }
    expectEqual(cover(highRes: true, settled: true, hasImage: true), .highRes, "换歌通知封面: 高清替代到了就用它")
    expectEqual(cover(highRes: true, seeks: true), .highRes, "换歌通知封面: 只有高清替代的播放器(Kaset),到了就用")
    expectEqual(cover(settled: true, hasImage: true), .system, "换歌通知封面: 系统那份够用、不找替代,不等")
    expectEqual(cover(settled: true), .noCover, "换歌通知封面: 系统判定这首没图、也不找替代,不等")
    expectEqual(cover(), .wait, "换歌通知封面: 系统那份还没定案,等")
    expectEqual(cover(seeks: true), .wait, "换歌通知封面: 要找高清替代、还没到,等")
    expectEqual(cover(settled: true, hasImage: true, seeks: true), .wait, "换歌通知封面: 系统那份太小、高清替代还没到,等")
    expectEqual(cover(settled: true, hasImage: true, seeks: true, timedOut: true), .system,
                "换歌通知封面: 到时限高清替代没来,用系统那份")
    expectEqual(cover(seeks: true, timedOut: true), .noCover, "换歌通知封面: 到时限什么都没有,不附图")
    expectEqual(cover(hasImage: true, timedOut: true), .noCover, "换歌通知封面: 到时限系统那份还是上一首的,不附图")

    // 封面文件:超过 600px 的等比缩到 600,小图不放大。
    func written(width: Int, height: Int) -> (type: String, width: Int, height: Int)? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = ctx.makeImage() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("np-cover-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        guard N.writeArtworkJPEG(image, to: url),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (type as String, w, h)
    }
    let large = written(width: 1800, height: 1200)
    expectEqual(large?.type, "public.jpeg", "换歌通知封面文件: 写成 JPEG")
    expectEqual(large.map { [$0.width, $0.height] }, [600, 400], "换歌通知封面文件: 大图等比缩到最长边 600")
    expectEqual(written(width: 120, height: 120).map { [$0.width, $0.height] }, [120, 120],
                "换歌通知封面文件: 小图不放大")

    // 接线:启动时开始盯,点通知打开歌词窗口,封面跟界面同一口径。
    let sourcesRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    func code(_ path: String) -> String {
        (try? String(contentsOfFile: sourcesRoot.appendingPathComponent(path).path, encoding: .utf8)) ?? ""
    }
    expectEqual(code("lyrimuse/AppDelegate.swift").contains("NowPlayingNotifier.shared.start()"), true,
                "换歌通知: App 启动时开始盯")
    let delegate = code("lyrimuse/Settings/UnknownPlayerNotifier.swift")
    expectEqual(delegate.contains("== NowPlayingNotifier.categoryID") && delegate.contains("openLyricsWindow?()"), true,
                "换歌通知: 点通知在 delegate 里分流到歌词窗口")
    let notifier = code("lyrimuse/Settings/NowPlayingNotifier.swift")
    expectEqual(notifier.contains("$highResArtworkImage") && notifier.contains("seeksHighResCover"), true,
                "换歌通知: 封面盯着高清替代,跟界面同一口径")
    let coordinator = code("lyrimuse/PlaybackCoordinator.swift")
    expectEqual(coordinator.components(separatedBy: "CoverArtReplacementGate.reason(").count - 1, 1,
                "换歌通知: 找不找高清替代只在一处判,界面和通知共用")
}

// ---- 常驻脚本进程(02 章决策 111) ----

@MainActor
private func scriptServerTests() {
    typealias P = PersistentScriptServer
    let marker = "__END__"
    func text(_ d: Data?) -> String? { d.map { String(decoding: $0, as: UTF8.self) } }

    let whole = P.parseResponse(Data("{\"a\":1}\n\n__END__ 0\nnext".utf8), endMarker: marker)
    expectEqual(text(whole?.body), "{\"a\":1}\n", "常驻脚本: 结束行之前的是回答")
    expectEqual(whole?.status, 0, "常驻脚本: 结束行里是状态码")
    expectEqual(text(whole?.rest), "next", "常驻脚本: 结束行之后的字节留给下一次")
    expectEqual(P.parseResponse(Data("{\"a\":1}\n__END__ 0".utf8), endMarker: marker) == nil, true,
                "常驻脚本: 结束行没读完整时还不算答完")
    expectEqual(P.parseResponse(Data("x\n__END__ 1\n".utf8), endMarker: marker)?.status, 1, "常驻脚本: 非零状态码照传")
    expectEqual(P.parseResponse(Data("x\n__END__ ?\n".utf8), endMarker: marker)?.status, -1, "常驻脚本: 状态码不是整数按失败")
    expectEqual(text(P.parseResponse(Data("\n__END__ 0\n".utf8), endMarker: marker)?.body), "", "常驻脚本: 空回答")

    expectEqual(MediaControlClient.getServerRequest(for: ["--now", "--no-artwork", "--micros"]), "now no_artwork micros",
                "常驻取数: get 的参数换成适配器的选项名")
    expectEqual(MediaControlClient.getServerRequest(for: []), "", "常驻取数: 不带参数就是空请求")
    expectEqual(MediaControlClient.getServerRequest(for: ["--now", "--human-readable"]), nil, "常驻取数: 不认的参数走子进程")

    // 假脚本:回答「pid 第几次 请求」;hang 卡住、die 直接退出、fail 回状态码 1。
    let fake = #"""
    $| = 1;
    my $n = 0;
    while (my $line = <STDIN>) {
        chomp $line;
        $n++;
        sleep 30 if $line eq 'hang';
        exit 1 if $line eq 'die';
        my $status = $line eq 'fail' ? 1 : 0;
        print "$$ $n $line\n__END__ $status\n";
    }
    """#
    func server(recycle: Int) -> P {
        P(label: "selftest", endMarker: marker, recycleAfterRequests: recycle, disableAfterFailures: 2,
          launch: { .init(executable: "/usr/bin/perl", arguments: ["-e", fake]) })
    }
    func fields(_ r: ProcessRunner.Result?) -> [String] { (text(r?.stdout) ?? "").split(separator: " ").map(String.init) }

    let s = server(recycle: 2)
    let a = fields(s.request("a", timeout: 5))
    let b = fields(s.request("b", timeout: 5))
    expectEqual(a.count == 3 && b.count == 3 && a[0] == b[0] && a[1] == "1" && b[1] == "2", true,
                "常驻脚本: 两次请求同一个进程答")
    let c = fields(s.request("c", timeout: 5))
    expectEqual(c.count == 3 && a.count == 3 && c[0] != a[0] && c[1] == "1" && s.launchCount == 2, true,
                "常驻脚本: 答满次数换新进程")
    let failed = s.request("fail", timeout: 5)
    expectEqual(failed?.status == 1 && failed?.succeeded == false, true, "常驻脚本: 脚本报的状态码照子进程退出码交回")
    let started = Date()
    let hung = s.request("hang", timeout: 0.15)
    let launchesAfterHang = s.launchCount
    expectEqual(hung?.timedOut == true && Date().timeIntervalSince(started) < 2, true, "常驻脚本: 超时按 timedOut 交回")
    let afterHang = fields(s.request("d", timeout: 5))
    expectEqual(afterHang.count == 3 && afterHang[1] == "1" && s.launchCount == launchesAfterHang + 1, true,
                "常驻脚本: 超时杀掉、下次重开")
    expectEqual(s.request("x\ny", timeout: 5) == nil, true, "常驻脚本: 请求里带换行不发")
    s.stop()

    let dying = server(recycle: 100)
    expectEqual(dying.request("die", timeout: 5) == nil && dying.launchCount == 1, true,
                "常驻脚本: 半路退出这次交 nil(调用方退回起子进程)")
    expectEqual(dying.request("die", timeout: 5) == nil && dying.launchCount == 2, true, "常驻脚本: 下一次重开")
    expectEqual(dying.request("ok", timeout: 5) == nil && dying.launchCount == 2, true,
                "常驻脚本: 连着失败到上限就停用,停用期间不起进程")

    // 真的 JXA:不认的请求名回空串;关掉 stdin 之后必须自己退出(判 EOF 写错会空转占满一个核)。
    // 退出后可能还没被收尸,ps 读到 Z 也算退出了。
    func exited(_ pid: Int32) -> Bool {
        guard let r = ProcessRunner.run("/bin/ps", ["-o", "stat=", "-p", String(pid)], timeout: 5) else { return false }
        let stat = r.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return stat.isEmpty || stat.hasPrefix("Z")
    }
    let jxa = P(label: "selftest jxa", endMarker: "__LYRIMUSE_SCRIPT_END__", recycleAfterRequests: 100,
                launch: { .init(executable: "/usr/bin/osascript",
                                arguments: ["-l", "JavaScript", "-e", MediaControlClient.appleScriptServerScript]) })
    let unknown = jxa.request("selftest-no-such-player", timeout: 10)
    expectEqual(unknown?.status == 0 && unknown?.stdout.isEmpty == true, true, "常驻 osascript: 不认的请求名回空串")
    if let pid = jxa.currentPID {
        jxa.stop()
        let deadline = Date().addingTimeInterval(1.5)
        while !exited(pid), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        expectEqual(exited(pid), true, "常驻 osascript: stdin 关掉后自己退出")
    } else {
        expectEqual(true, false, "常驻 osascript: 起得来")
    }

    // perl 那份脚本至少要编得过(真加载适配框架要打包后的 App,不在这里跑)。
    let syntax = ProcessRunner.run("/usr/bin/perl", ["-c", "-e", MediaControlClient.getServerScript],
                                   timeout: 10, captureStderr: true)
    expectEqual(syntax?.succeeded == true && syntax?.stderrText.contains("syntax OK") == true, true,
                "常驻取数: perl 脚本编得过")

    // 接线:轮询快照、电台探测走 runGet;三家播放器的快照脚本走 runPlayerScript。
    let client = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("LyrimuseCore/Local/MediaControlClient.swift"), encoding: .utf8)) ?? ""
    for needle in ["runGet([\"--now\", \"--no-artwork\", \"--micros\"], binaryPath: binaryPath, timeout: timeout)",
                   "runGet([\"--now\", \"--no-artwork\"], binaryPath: binaryPath, timeout: snapshotTimeout)",
                   "runPlayerScript(\"music\", source: script)",
                   "runPlayerScript(\"spotify\", source: spotifyScript)",
                   "runPlayerScript(\"kaset\", source: kasetScript)"] {
        expectEqual(sourceBytes(client, contain: needle), true, "常驻脚本接线: \(needle)")
    }
}
