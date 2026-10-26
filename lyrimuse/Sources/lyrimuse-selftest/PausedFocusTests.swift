import Foundation
import LyrimuseCore

/// 系统焦点停在一家暂停着的播放器上、别家在放:认哪几家、从全部会话里挑谁、多久扫一次、粘性、播放控制发给谁、接线契约。
/// 会话样例照 nowplaying-clients 列全部会话的输出形状造(reAMP 在放、Pine 暂停着,见 02 章决策 192)。
@MainActor
func pausedFocusChecks() {
    typealias M = MediaControlClient
    typealias T = M.FocusFallbackTarget
    let reamp = PlaybackPlayer.reamp.bundleIdentifier
    let pine = PlaybackPlayer.pinePlayer.bundleIdentifier

    // ---- 能顶上来的是哪几家 ----
    do {
        let multi: Set<PlaybackPlayer> = [.reamp, .pinePlayer]
        func target(_ id: String, players: Set<PlaybackPlayer>, trusted: [String: String] = [:], lx: Bool = false) -> T? {
            M.pausedFocusTarget(forBundleID: id, focusBundleID: pine, players: players, trusted: trusted,
                                lxMusicOpenAPIConnected: lx)
        }
        expectEqual(target(reamp, players: multi), T(bundleID: reamp, player: .reamp), "焦点暂停顶替: 多选下勾了的别家能顶上来")
        expectEqual(target(pine, players: multi), nil, "焦点暂停顶替: 焦点那家自己不算")
        expectEqual(target(PlaybackPlayer.spotify.bundleIdentifier, players: multi), nil, "焦点暂停顶替: 多选下没勾的不算")
        expectEqual(target(PlaybackPlayer.kaset.bundleIdentifier, players: [.kaset, .pinePlayer]), nil,
                    "焦点暂停顶替: Kaset 不走这条(系统那份换歌后常停在上一首,它有自己的顶替)")
        let lx = PlaybackPlayer.lxMusic.bundleIdentifier
        expectEqual(target(lx, players: [.lxMusic, .pinePlayer], lx: true), nil,
                    "焦点暂停顶替: 洛雪开放 API 连着时交给它自己的顶替")
        expectEqual(target(lx, players: [.lxMusic, .pinePlayer], lx: false), T(bundleID: lx, player: .lxMusic),
                    "焦点暂停顶替: 洛雪没开开放 API 时按系统那份顶")
        let fake = "org.Petrichor"
        let trusted = [fake: "Petrichor", "com.google.Chrome": "Chrome"]
        expectEqual(target(reamp, players: [.auto], trusted: trusted), T(bundleID: reamp, player: .reamp),
                    "焦点暂停顶替: 自动识别下内置的都算")
        expectEqual(target(fake, players: [.auto], trusted: trusted), T(bundleID: fake, player: nil),
                    "焦点暂停顶替: 自动识别下信任的非浏览器播放器算")
        expectEqual(target("com.google.Chrome", players: [.auto], trusted: trusted), nil,
                    "焦点暂停顶替: 浏览器不算(同焦点回退)")
        expectEqual(target(fake, players: [.auto], trusted: [:]), nil, "焦点暂停顶替: 没信任过的不算")
        expectEqual(target(fake, players: multi, trusted: trusted), nil, "焦点暂停顶替: 多选下只认勾了的")
    }

    // ---- 从全部会话里挑在放的别家 ----
    do {
        let json = """
        [{"bundleIdentifier":"com.digipine.pineplayer","playing":false,"title":"Probe Tone","timestamp":1792949000},
         {"bundleIdentifier":"ru.alexfreud.ReAmp","playing":true,"playbackRate":1,"title":"Tone","timestamp":1792948990},
         {"bundleIdentifier":"com.spotify.client","playing":true,"playbackRate":0,"title":"Stale","timestamp":1792949010},
         {"bundleIdentifier":"com.apple.WebKit.GPU","playing":true,"playbackRate":1,"title":"Video","timestamp":1792949020},
         {"bundleIdentifier":"com.apple.Music","playing":true,"playbackRate":1,"title":"Newer","timestamp":1792949005},
         {"bundleIdentifier":"ru.alexfreud.ReAmp","playing":true,"playbackRate":1,"title":"Tone","timestamp":1792948980},
         {"bundleIdentifier":"com.tencent.QQMusicMac","playing":true,"title":"NoRate","timestamp":1792949030}]
        """
        let sessions = (try? JSONDecoder().decode([NowPlayingClientsProbe.ClientSession].self, from: Data(json.utf8))) ?? []
        expectEqual(sessions.count, 7, "焦点暂停顶替: 会话样例解得开")
        let all = M.pausedFocusContenders(sessions, focusBundleID: pine, accepts: { $0 != "com.apple.WebKit.GPU" })
        expectEqual(all, ["com.apple.Music", reamp],
                    "焦点暂停顶替: 只挑报在放且速率大于 0 的别家,同一家只列一次,最近发布的排前面")
        expectEqual(M.pausedFocusContenders(sessions, focusBundleID: pine, accepts: { $0 == reamp }), [reamp],
                    "焦点暂停顶替: 不认的不列")
        expectEqual(M.pausedFocusContenders(sessions, focusBundleID: reamp, accepts: { $0 == reamp }), [],
                    "焦点暂停顶替: 焦点那家自己不列")
    }

    // ---- 多久扫一次 ----
    do {
        expectEqual(M.pausedFocusScanDue(sincePaused: 0, sinceLastScan: nil), true, "焦点暂停扫描: 刚暂停那一拍就扫")
        expectEqual(M.pausedFocusScanDue(sincePaused: 10, sinceLastScan: M.pausedFocusScanInterval - 1), false,
                    "焦点暂停扫描: 刚暂停那一阵不到间隔不扫")
        expectEqual(M.pausedFocusScanDue(sincePaused: 10, sinceLastScan: M.pausedFocusScanInterval), true,
                    "焦点暂停扫描: 刚暂停那一阵到间隔就扫")
        expectEqual(M.pausedFocusScanDue(sincePaused: M.pausedFocusSlowScanAfter + 1, sinceLastScan: M.pausedFocusScanInterval), false,
                    "焦点暂停扫描: 停久了改成长间隔")
        expectEqual(M.pausedFocusScanDue(sincePaused: M.pausedFocusSlowScanAfter + 1, sinceLastScan: M.pausedFocusSlowScanInterval), true,
                    "焦点暂停扫描: 停久了到长间隔照样扫")
    }

    // ---- 认谁(粘性) ----
    do {
        expectEqual(M.pausedFocusPick(preferredPlaying: true, contenderFound: true), .preferred,
                    "焦点暂停粘性: 顶上来的那家还在放就接着认它,不换给别家")
        expectEqual(M.pausedFocusPick(preferredPlaying: false, contenderFound: true), .contender,
                    "焦点暂停粘性: 它停了、别家在放就换过去")
        expectEqual(M.pausedFocusPick(preferredPlaying: false, contenderFound: false), .preferred,
                    "焦点暂停粘性: 都没在放时接着认最近在放的那个")
        expectEqual(M.pausedFocusPick(preferredPlaying: nil, contenderFound: true), .contender,
                    "焦点暂停粘性: 没在顶替时有在放的别家就顶上来")
        expectEqual(M.pausedFocusPick(preferredPlaying: nil, contenderFound: false), .focus,
                    "焦点暂停粘性: 没有在放的别家就用焦点那份")
    }

    // ---- 播放控制发给谁 ----
    do {
        func route(_ substitute: T?) -> MusicPlaybackController.ControlRoute {
            let c = M.pausedFocusControl(substitute: substitute, scriptTarget: nil, directQueryTarget: nil, heldElsewhere: false)
            return MusicPlaybackController.controlRoute(exclusivelyAppleMusic: false, focusFallback: c.scriptTarget,
                                                        focusHeldElsewhere: c.heldElsewhere, directQueryFallback: c.directQueryTarget,
                                                        mediaControlCommand: "toggle-play-pause")
        }
        expectEqual(route(nil), .mediaControl, "焦点暂停控制: 没在顶替照常发给系统焦点")
        expectEqual(route(T(bundleID: reamp, player: .reamp)), .menuAccessibility(.reamp, .playPause),
                    "焦点暂停控制: 顶上来的是 reAMP 时按它的菜单,不落到焦点上暂停着的那家")
        expectEqual(route(T(bundleID: PlaybackPlayer.appleMusic.bundleIdentifier, player: .appleMusic)), .appleMusicScript,
                    "焦点暂停控制: 有脚本的发脚本")
        expectEqual(route(T(bundleID: PlaybackPlayer.lxMusic.bundleIdentifier, player: .lxMusic)), .lxMusicDirect,
                    "焦点暂停控制: 洛雪直接发给它本体")
        expectEqual(route(T(bundleID: "org.Petrichor", player: nil)), .withheld,
                    "焦点暂停控制: 没有定向通路的不发")
        let kept = M.pausedFocusControl(substitute: nil, scriptTarget: .spotify, directQueryTarget: .qqMusic, heldElsewhere: true)
        expectEqual(kept.scriptTarget == .spotify && kept.directQueryTarget == .qqMusic && kept.heldElsewhere, true,
                    "焦点暂停控制: 没在顶替时回退那份原样交回")
    }

    // ---- 接线契约 ----
    do {
        let sourcesRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func code(_ path: String) -> String {
            (try? String(contentsOfFile: sourcesRoot.appendingPathComponent(path).path, encoding: .utf8)) ?? ""
        }
        let client = code("LyrimuseCore/Local/MediaControlClient.swift")
        expectEqual(sourceHas(client, "let withPlaying = preferringPlayingOverPausedFocus(found, players: players)\n            return heldAcrossPlayerGap(preferringLXMusicOpenAPI(preferringPlayingKaset(withPlaying), wanted: true))")
                        && sourceHas(client, "let withPlaying = preferringPlayingOverPausedFocus(selected, players: players)\n        let withKaset = players.contains(.kaset) ? preferringPlayingKaset(withPlaying) : withPlaying"),
                    true, "焦点暂停契约: 自动识别、多选两条路都先顶替,再轮到 Kaset / 洛雪,最后过切歌间隙保持")
        let body = sourceBody("private static func preferringPlayingOverPausedFocus(", in: client)
        expectEqual(sourceHas(body, "guard found.playing != true, found.isWaitingToPlay != true else {")
                        && body.contains("forgetPausedFocusPreference()")
                        && body.contains("pausedFocusScanDue(") && body.contains("NowPlayingClientsProbe.allSessions()"),
                    true, "焦点暂停契约: 焦点那家在放就让回去;扫全部会话按节流")
        let reading = sourceBody("private static func pausedFocusReading(", in: client)
        expectEqual(reading.contains("playerContentNotMusic(bundleID: target.bundleID, snapshot: s)")
                        && reading.contains("artistNotYetReported(bundleID: target.bundleID, snapshot: s)")
                        && reading.contains("trustedPlaybackRejected(bundleID: target.bundleID, snapshot: s)")
                        && reading.contains("pineProbedSnapshot(probed.snapshot, anchor: probed.anchor, now: now)")
                        && reading.contains("adaptedSnapshot(bundleID: target.bundleID, mediaControl: probed.snapshot)"),
                    true, "焦点暂停契约: 顶上来的那份过主路径同样的闸,Pine 过它那块表,有脚本的走同一条适配")
        let context = sourceBody("public static func focusControlContext()", in: client)
        expectEqual(context.contains("let routed = pausedFocusControl(")
                        && context.contains("holdingAcrossGap && heldBundleID != substitute?.bundleID ? nil : substitute"),
                    true, "焦点暂停契约: 播放控制跟着顶上来的那家走,切歌间隙保持着别家时不算")
        let artwork = sourceBody("public static func fetchArtworkExplained(", in: client)
        if let a = artwork.range(of: "if let target = pausedFocusSubstitute() {"),
           let b = artwork.range(of: "if let target = activeFocusFallbackTarget() {") {
            expectEqual(a.lowerBound < b.lowerBound, true, "焦点暂停契约: 封面按顶上来的那家取,不拿焦点那家的图")
        } else {
            expectEqual(false, true, "焦点暂停契约: 封面按顶上来的那家取")
        }
        expectEqual(sourceHas(code("LyrimuseCore/Local/NowPlayingClientsProbe.swift"),
                              "let r = snapshotServer.request(\"\", timeout: timeout)"),
                    true, "焦点暂停契约: 列全部会话先问常驻 helper,不每次起 perl")
    }
}
