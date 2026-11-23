import Foundation
import LyrimuseCore

func runQQIPadTests() {
    typealias Q = QQIPadNowPlaying
    typealias Names = QQIPadNowPlaying.Names
    typealias L = LocalPlaybackSource
    let mac = PlaybackPlayer.qqMusic.bundleIdentifier

    // ---- 按 QQ 音乐 Mac 版认,找进程、权限行不算它 ----
    do {
        expectEqual(PlayerBundleAliases.canonical(Q.bundleID), mac, "iPad QQ: bundle id 换成 Mac 版的")
        expectEqual(MediaControlClient.reportingPlayerBundleID(Q.bundleID, owner: nil), mac, "iPad QQ: 系统报上来的一进来就当 Mac 版")
        expectEqual(PlayerBundleAliases.all(for: mac), [mac, Q.bundleID], "iPad QQ: 判装没装、在不在跑把它算上")
        expectEqual(PlayerBundleAliases.all(for: mac, includingOtherClients: false), [mac], "iPad QQ: 按本体的菜单、界面、数据做事的地方不算它")
        expectEqual([PlayerProcess.otherClient(reporting: Q.bundleID), PlayerProcess.otherClient(reporting: mac),
                     PlayerProcess.otherClient(reporting: nil)], [Q.bundleID, nil, nil], "iPad QQ: 认得出是另一个程序报的")
    }

    // ---- 两个版本都开着:按 bundle id 单问时挑在放的那份 ----
    do {
        let pick = NowPlayingClientsProbe.preferredAnswer
        expectEqual(pick([(mac, false), (Q.bundleID, true)], mac), 1, "iPad QQ 单问: Mac 版暂停着、iPad 版在放,挑 iPad 版")
        expectEqual(pick([(mac, false), (Q.bundleID, false)], Q.bundleID), 1, "iPad QQ 单问: 都没在放,挑最近一份会话报的那个")
        expectEqual(pick([(mac, false), (Q.bundleID, false)], nil), 0, "iPad QQ 单问: 都没在放、没记过,挑第一份")
        expectEqual(pick([], mac), nil, "iPad QQ 单问: 一份都没答上")
    }

    // ---- 两个版本都开着:会话是 iPad 版报的,本体当没在跑 ----
    do {
        defer { MediaControlClient.noteReportingClient(mac, forBundleID: mac) }
        MediaControlClient.noteReportingClient(Q.bundleID, forBundleID: mac)
        expectEqual([PlayerProcess.sessionIsOtherClient(bundleID: mac), PlayerProcess.sessionIsOtherClient(bundleID: Q.bundleID)],
                    [true, true], "iPad QQ 进程: 会话是 iPad 版报的")
        expectEqual(PlayerProcess.pid(bundleID: mac), nil, "iPad QQ 进程: 不去找 Mac 版的进程(不按它的菜单)")
        MediaControlClient.noteReportingClient(mac, forBundleID: mac)
        expectEqual(PlayerProcess.sessionIsOtherClient(bundleID: mac), false, "iPad QQ 进程: Mac 版报的照旧")
    }

    // ---- 歌名:去掉改写的「 — 歌手」 ----
    do {
        expectEqual(Q.strippedTitle("心野待星临 — 米乐斯图", artist: "米乐斯图"), "心野待星临", "iPad QQ 歌名: 去掉「 — 歌手」")
        let many = "我有歌想唱/阿咔咔/船与/柯基林"
        expectEqual(Q.strippedTitle("我有歌想唱 — " + many, artist: many), "我有歌想唱", "iPad QQ 歌名: 多位歌手用「/」连的也去")
        expectEqual(Q.strippedTitle("心野待星临 — 米乐斯图", artist: "别人"), "心野待星临 — 米乐斯图", "iPad QQ 歌名: 后缀不是这一帧的歌手不动")
        expectEqual(Q.strippedTitle("心野待星临 - 米乐斯图", artist: "米乐斯图"), "心野待星临 - 米乐斯图", "iPad QQ 歌名: 短横线不动")
        expectEqual(Q.strippedTitle(" — 米乐斯图", artist: "米乐斯图"), " — 米乐斯图", "iPad QQ 歌名: 去掉就空了的不动")
        expectEqual(Q.strippedTitle("心野待星临 — ", artist: ""), "心野待星临 — ", "iPad QQ 歌名: 歌手空的不动")
        expectEqual(Q.strippedTitle(nil, artist: "米乐斯图"), nil, "iPad QQ 歌名: 没有歌名")
        let (title, artist) = Q.names(title: "童话 — 周宣绮", artist: "周宣绮", bundleID: Q.bundleID)
        expectEqual([title, artist], ["童话", "周宣绮"], "iPad QQ 歌名: 封面载荷那一路也去")
        let (macTitle, _) = Q.names(title: "童话 — 周宣绮", artist: "周宣绮", bundleID: mac)
        expectEqual(macTitle, "童话 — 周宣绮", "iPad QQ 歌名: Mac 版报的不动")
    }

    // ---- 专辑:改写帧专辑空,按记住的同一首真名补回(录到的真实序列) ----
    do {
        var memory: Names?
        let real = Names(title: "童话", artist: "周宣绮", album: "风，飞鸟，高山")
        expectEqual(Q.normalized(real, memory: &memory), real, "iPad QQ 专辑: 真名那一帧原样")
        let rewritten = Names(title: "童话 — 周宣绮", artist: "周宣绮", album: "")
        expectEqual(Q.normalized(rewritten, memory: &memory), real, "iPad QQ 专辑: 改写帧还原成真名、专辑补回")
        expectEqual(Q.normalized(rewritten, memory: &memory), real, "iPad QQ 专辑: 同一帧再整理一次结果不变")
        let other = Names(title: "一半 — 柯基林", artist: "柯基林", album: "")
        expectEqual(Q.normalized(other, memory: &memory), Names(title: "一半", artist: "柯基林", album: ""),
                    "iPad QQ 专辑: 没记到这一首的真名时专辑照旧空着")
        expectEqual(memory, real, "iPad QQ 专辑: 改写帧不改记住的那份")
        _ = Q.normalized(Names(title: "一半", artist: "柯基林", album: "阳光"), memory: &memory)
        expectEqual(Q.normalized(other, memory: &memory).album, "阳光", "iPad QQ 专辑: 换歌后记住新的那首")
        var empty: Names?
        _ = Q.normalized(Names(title: "无专辑", artist: "某人", album: ""), memory: &empty)
        expectEqual(empty, nil, "iPad QQ 专辑: 没专辑的真名帧不记")
    }

    // ---- 单问、事件流两条路(轮询那一路的解码结构是私有的,由下面的接线契约钉住) ----
    do {
        Q.resetForTesting()
        defer { Q.resetForTesting() }
        func helper(_ title: String, _ album: String, anchor: Double) -> Data {
            Data(("{\"bundleIdentifier\":\"\(Q.bundleID)\",\"title\":\"\(title)\",\"artist\":\"周宣绮\",\"album\":\"\(album)\","
                + "\"duration\":266,\"playbackRate\":1,\"playing\":true,\"isMusicApp\":true,\"processIdentifier\":10172,"
                + "\"anchorElapsedTime\":\(anchor),\"elapsedTime\":\(anchor + 1),\"timestamp\":1793241632.5}").utf8)
        }
        let first = NowPlayingClientsProbe.decodeSnapshot(helper("童话", "风，飞鸟，高山", anchor: 0))
        expectEqual([first?.snapshot.title, first?.snapshot.album], ["童话", "风，飞鸟，高山"], "iPad QQ 单问: 真名那一帧原样")
        let probed = NowPlayingClientsProbe.decodeSnapshot(helper("童话 — 周宣绮", "", anchor: 1.098))
        expectEqual([probed?.snapshot.title, probed?.snapshot.artist, probed?.snapshot.album], ["童话", "周宣绮", "风，飞鸟，高山"],
                    "iPad QQ 单问: 改写帧还原、专辑补回")
        expectEqual(probed?.snapshot.anchorElapsedTime, 1.098, "iPad QQ 单问: 进度照原样")

        // 事件流:上一首的改写帧 → 新歌真名(暂停、进度 0)→ 在放 → 只翻速率 → 改写帧;只在真名那一行报换歌。
        func full(_ title: String, _ artist: String, _ album: String, _ elapsed: Int, _ ts: Int, _ rate: Int) -> Data {
            Data(("{\"type\":\"data\",\"diff\":false,\"payload\":{\"bundleIdentifier\":\"\(Q.bundleID)\",\"title\":\"\(title)\","
                + "\"artist\":\"\(artist)\",\"album\":\"\(album)\",\"playing\":\(rate == 1),\"playbackRate\":\(rate),"
                + "\"elapsedTimeMicros\":\(elapsed),\"timestampEpochMicros\":\(ts),\"durationMicros\":266000000}}").utf8)
        }
        let lines = [
            full("平安小调 — 诗奇可大观", "诗奇可大观", "", 631_972, 1_793_241_474_674_000, 1),
            full("童话", "周宣绮", "风，飞鸟，高山", 0, 1_793_241_631_000_000, 0),
            Data("{\"type\":\"data\",\"diff\":true,\"payload\":{\"playing\":true}}".utf8),
            Data("{\"type\":\"data\",\"diff\":true,\"payload\":{\"playbackRate\":1,\"timestampEpochMicros\":1793241631550000}}".utf8),
            full("童话 — 周宣绮", "周宣绮", "", 1_098_458, 1_793_241_632_555_000, 1),
        ]
        var merged: [String: Any] = [:]
        var changes: [String?] = []
        var keys: [String?] = []
        for line in lines {
            let d = MediaControlStreamWatcher.digest(line: line, merged: merged, arrivedAt: Date(timeIntervalSince1970: 1_793_241_640))
            merged = d.merged
            changes.append(d.trackChangeKey)
            keys.append(d.anchorKey)
        }
        expectEqual(changes, ["诗奇可大观|平安小调", "周宣绮|童话", nil, nil, nil], "iPad QQ 事件流: 只在真名那一行报换歌,改写帧不报")
        expectEqual(keys.last ?? nil, MediaControlClient.anchorKey(artist: "周宣绮", title: "童话", elapsedTime: 1.098458,
                                                                 timestamp: "@1793241632555000"),
                    "iPad QQ 事件流: 改写帧的锚点身份按真名算,跟轮询那一路一致")
        expectEqual(merged["title"] as? String, "童话 — 周宣绮", "iPad QQ 事件流: 合并状态留原样")
    }

    // ---- 位置:QQ Mac 版那几条修正对 iPad 版不套 ----
    do {
        expectEqual([L.qqMacQuirkBundleID(bundleID: mac, client: Q.bundleID), L.qqMacQuirkBundleID(bundleID: mac, client: mac),
                     L.qqMacQuirkBundleID(bundleID: mac, client: nil)], [Q.bundleID, mac, mac],
                    "iPad QQ 位置: iPad 版报的会话换成 iPad 版,Mac 版和不知道谁报的照旧")
        let netease = PlaybackPlayer.netease.bundleIdentifier
        expectEqual(L.qqMacQuirkBundleID(bundleID: netease, client: NetEaseIPadNowPlaying.bundleID), netease,
                    "iPad QQ 位置: 网易云 iPad 版不受影响")
        let ipad = L.qqMacQuirkBundleID(bundleID: mac, client: Q.bundleID)
        expectEqual([L.flooredSeekMidpoint(bundleID: ipad, anchorElapsedTime: 89), L.flooredSeekMidpoint(bundleID: mac, anchorElapsedTime: 89)],
                    [0, L.flooredSeekMidpointSecs], "iPad QQ 位置: 拖动不补整秒中点")
        expectEqual([L.holdsShownPositionAtPause(bundleID: ipad, frozenByEvent: true), L.holdsShownPositionAtPause(bundleID: mac, frozenByEvent: true)],
                    [false, true], "iPad QQ 位置: 暂停采信它报的停住位置")
        expectEqual([L.resumeAudioLagSecs(bundleID: ipad), L.resumeAudioLagSecs(bundleID: mac)], [0, 0.12], "iPad QQ 位置: 恢复不扣出声滞后")
        expectEqual([L.tickAnchorError(bundleID: ipad, reported: 2.0, predicted: 2.38) == nil,
                     L.tickAnchorError(bundleID: mac, reported: 2.0, predicted: 2.38) == nil],
                    [true, false], "iPad QQ 位置: 重报的锚点不按整秒取模纠(它头几秒的重报会少报)")
        expectEqual([L.correctsEarlyStartAnchor(bundleID: ipad, reported: 2.0, predicted: 2.38),
                     L.correctsEarlyStartAnchor(bundleID: mac, reported: 2.0, predicted: 2.38)],
                    [false, true], "iPad QQ 位置: 少报的重报不当成开播锚点打早")
        expectEqual([L.holdsTrackEndZero(bundleID: ipad, reported: 0, predicted: 250, duration: 251),
                     L.resumeContinuesStartAnchor(bundleID: ipad, frozen: 0),
                     L.resumeDropsToTrackStart(bundleID: ipad, frozen: 30, reported: 0)],
                    [false, false, false], "iPad QQ 位置: 放完归零、暂停着开播、恢复跳回开头那几条不套")
        expectEqual(L.qqLateZeroAnchorLead(bundleID: ipad, anchorElapsed: 0, rawReported: 0, resumeSignalAge: 1), 0,
                    "iPad QQ 位置: 晚到的 0 锚点不补")
        expectEqual([L.snapsToReportedPosition(bundleID: mac, client: Q.bundleID), L.snapsToReportedPosition(bundleID: mac, client: mac),
                     L.snapsToReportedPosition(bundleID: mac)], [true, false, false],
                    "iPad QQ 位置: 偏差过门槛就对齐它报的进度(开播那一帧有时早,改写帧才准),Mac 版照旧")
        expectEqual([L.resumeReadingNeverLeads(bundleID: mac, client: Q.bundleID), L.resumeReadingNeverLeads(bundleID: mac, client: mac)],
                    [true, false], "iPad QQ 位置: 速率翻 1 那一拍的读数原样采信(改写帧常落在这一拍),Mac 版照旧削")
    }

    // ---- 接线契约 ----
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func sourceText(_ path: String) -> String {
            (try? String(contentsOfFile: root.appendingPathComponent(path).path, encoding: .utf8)) ?? ""
        }
        let client = sourceText("LyrimuseCore/Local/MediaControlClient.swift")
        expectEqual([sourceHas(client, "let qqNames = QQIPadNowPlaying.normalized("),
                     sourceHas(client, "album = qqNames.album"),
                     sourceHas(client, "(keyTitle, keyArtist) = QQIPadNowPlaying.names(title: keyTitle, artist: keyArtist, bundleID: raw.bundleIdentifier)")],
                    [true, true, true], "iPad QQ 接线: 轮询解码、取封面那一路整理")
        let probe = sourceText("LyrimuseCore/Local/NowPlayingClientsProbe.swift")
        expectEqual(sourceHas(sourceBody("public static func snapshotWithAnchor(forBundleID", in: probe),
                              "if found.snapshot.playing == true { break }"), true,
                    "iPad QQ 单问: 问到的没在放、还有别的版本在跑时接着问")
        expectEqual([sourceHas(probe, "QQIPadNowPlaying.normalizedPayload(NetEaseIPadNowPlaying.normalizedPayload(raw)))"),
                     sourceHas(probe, "(title, artist) = QQIPadNowPlaying.names(title: title, artist: artist, bundleID: foundID)")],
                    [true, true], "iPad QQ 接线: 单问会话、单问封面都整理")
        let watcher = sourceText("LyrimuseCore/Local/MediaControlStreamWatcher.swift")
        expectEqual([sourceHas(watcher, "QQIPadNowPlaying.normalizedFields(NetEaseIPadNowPlaying.normalizedFields(merged)))"),
                     sourceHas(watcher, "QQIPadNowPlaying.normalizedFields(NetEaseIPadNowPlaying.normalizedFields(next)))")],
                    [true, true], "iPad QQ 接线: 事件流判换歌、算锚点身份用整理过的")
        let source = sourceText("LyrimuseCore/Local/LocalPlaybackSource.swift")
        expectEqual([sourceHas(source, "bundleID: qqMacQuirkBundleID, anchorElapsed: anchorElapsedTime, rawReported: rawReported,"),
                     sourceHas(source, "sinceSignal - Self.resumeAudioLagSecs(bundleID: qqMacQuirkBundleID),"),
                     sourceHas(source, "Self.resumeContinuesStartAnchor(bundleID: qqMacQuirkBundleID, frozen: frozen)"),
                     sourceHas(source, "Self.resumeDropsToTrackStart(bundleID: qqMacQuirkBundleID, frozen: frozen, reported: reported)"),
                     sourceHas(source, "Self.holdsTrackEndZero(bundleID: qqMacQuirkBundleID, reported: reported, predicted: predicted,"),
                     sourceHas(source, "Self.flooredSeekMidpoint(bundleID: qqMacQuirkBundleID, anchorElapsedTime: anchorElapsedTime)"),
                     sourceHas(source, "let bundle = qqMacQuirkBundleID"),
                     sourceCount(source, "Self.holdsShownPositionAtPause(bundleID: Self.qqMacQuirkBundleID(snapshot),") == 2,
                     sourceHas(source, "if Self.holdsShownPositionAtPause(bundleID: qqMacQuirkBundleID, frozenByEvent: true) {")],
                    [true, true, true, true, true, true, true, true, true], "iPad QQ 接线: QQ Mac 版的位置修正都按会话收窄")
        expectEqual(sourceHas(sourceText("LyrimuseCore/Local/PlayerProcess.swift"), "guard !sessionIsOtherClient(bundleID: bundleID) else { return nil }"),
                    true, "iPad QQ 接线: 会话是 iPad 版报的时不找本体进程")
        let idle = sourceText("lyrimuse/UI/IdlePlaybackActions.swift")
        expectEqual([sourceHas(idle, "guard !PlayerProcess.sessionIsOtherClient(bundleID: player.bundleIdentifier) else { return false }"),
                     sourceHas(idle, "let id = PlayerProcess.otherClient(reporting: MediaControlClient.reportingClient(forBundleID: player.bundleIdentifier))")],
                    [true, true], "iPad QQ 接线: 停播页不按本体菜单「继续播放」,「打开」开 iPad 版")
    }
}
