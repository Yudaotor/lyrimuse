import Foundation
import LyrimuseCore

/// MyGo Music:开始出声那一刻报的锚点按混音缓冲和设备延迟往后挪(输出关掉后重开按另一档)、封面那份锚点沿用开播那份,
/// 以及接线契约。
@MainActor
func runMyGoTests() {
    typealias A = MyGoSessionAnchor
    let base = 1_794_163_589.901163
    func ts(_ offset: Double) -> String { MediaControlMicros.timestampString((base + offset) * 1_000_000)! }
    func secs(_ s: String?) -> Double { s.flatMap { MediaControlMicros.date(fromTimestampString: $0)?.timeIntervalSince1970 } ?? -1 }
    func near(_ s: String?, _ want: Double) -> Bool { abs(secs(s) - want) < 0.000_01 }
    let latency = 0.026
    let shift = A.mixAheadSecs + latency

    // ---- 在放的锚点往后挪 ----
    do {
        let out = A.fill(identity: "|Click A|", playing: true, elapsed: 0.018, timestamp: ts(0), rate: 1, outputLatency: latency,
                         state: A.State())
        expectEqual(out.elapsed, 0.018, "MyGo 锚点: 位置不动")
        expectEqual(near(out.timestamp, base + shift), true, "MyGo 锚点: 时刻往后挪混音缓冲加设备延迟")
        expectEqual(out.state.anchor?.rawTimestamp, ts(0), "MyGo 锚点: 记下原时刻")
        let again = A.fill(identity: "|Click A|", playing: true, elapsed: 0.018, timestamp: ts(0), rate: 1, outputLatency: latency,
                           state: out.state)
        expectEqual(again.timestamp, out.timestamp, "MyGo 锚点: 同一份锚点再解码一次不再挪")
        // 冷档挪过的那份,焦点被抢走后单问交来同一份锚点的原始浮点(位置多几位小数、时刻截到整微秒前后差一点):沿用,不按温档重挪。
        let paused = A.State(pausedAt: base - 10, pausedIdentity: "|Click A|")
        let cold = A.fill(identity: "|Click A|", playing: true, elapsed: 83.116371, timestamp: ts(0), rate: 1,
                          outputLatency: latency, state: paused)
        expectEqual(near(cold.timestamp, base + A.coldLeadSecs + latency), true, "MyGo 锚点: 内置扬声器停满 5 秒后恢复同一首按冷档挪")
        let probed = A.fill(identity: "|Click A|", playing: true, elapsed: 83.116_371_04, timestamp: ts(0.000_000_4), rate: 1,
                            outputLatency: latency, state: cold.state)
        expectEqual(probed.timestamp, cold.timestamp, "MyGo 锚点: 同一份锚点换一种写法(单问的原始浮点)也认得,不重挪")
        let seek = A.fill(identity: "|Click A|", playing: true, elapsed: 19, timestamp: ts(6), rate: 1, outputLatency: latency,
                          state: out.state)
        expectEqual(near(seek.timestamp, base + 6 + shift), true, "MyGo 锚点: 跳转那份同样挪")
        let negative = A.fill(identity: "|Click A|", playing: true, elapsed: 3, timestamp: ts(0), rate: 1, outputLatency: -1,
                              state: A.State())
        expectEqual(near(negative.timestamp, base + A.mixAheadSecs), true, "MyGo 锚点: 设备延迟读成负数按 0 算")
        let fresh = A.fill(identity: "|Click A|", playing: true, elapsed: 0, timestamp: ts(0), rate: 1, outputLatency: latency,
                           state: A.State())
        expectEqual(near(fresh.timestamp, base + shift), true, "MyGo: 没见过它停下(刚接手)按输出开着挪")
    }

    // ---- 暂停帧不动,记下停下的时刻 ----
    do {
        let last = A.Anchor(identity: "|Click A|", elapsed: 0.018, rawTimestamp: ts(0), timestamp: ts(shift), rate: 1)
        let paused = A.fill(identity: "|Click A|", playing: false, elapsed: 5.851, timestamp: ts(6), rate: 0, outputLatency: latency,
                            state: A.State(anchor: last))
        expectEqual(paused.elapsed, 5.851, "MyGo 暂停帧: 位置原样")
        expectEqual(paused.timestamp, ts(6), "MyGo 暂停帧: 时刻原样")
        expectEqual(paused.state.anchor == nil, true, "MyGo 暂停帧: 不留开播锚点")
        expectEqual(abs((paused.state.pausedAt ?? 0) - (base + 6)) < 0.000_01, true, "MyGo 暂停帧: 记下停下的时刻")
        expectEqual(paused.state.pausedIdentity, "|Click A|", "MyGo 暂停帧: 记下停下的是哪一首")
        let rateZero = A.fill(identity: "|Click A|", playing: true, elapsed: 5.851, timestamp: ts(6), rate: 0, outputLatency: latency,
                              state: A.State())
        expectEqual(rateZero.timestamp, ts(6), "MyGo: 在放但速率 0 的不挪")
        expectEqual(rateZero.state.pausedAt != nil, true, "MyGo: 在放但速率 0 的同样算停下")
        let starting = A.fill(identity: "|Click B|", playing: false, elapsed: 0, timestamp: ts(20), rate: 1, outputLatency: latency,
                              state: A.State(pausedAt: base + 6, pausedIdentity: "|Click A|"))
        expectEqual(near(starting.timestamp, base + 20 + shift), true, "MyGo: 暂停中换歌,新歌先以没在放、速率 1 到的那一拍同样挪")
        let confirmed = A.fill(identity: "|Click B|", playing: true, elapsed: 0, timestamp: ts(20), rate: 1, outputLatency: latency,
                               state: starting.state)
        expectEqual(confirmed.timestamp, starting.timestamp, "MyGo: 随后在放的那一拍是同一份锚点,不再挪")
        let coldStarting = A.fill(identity: "|Click A|", playing: false, elapsed: 6.1, timestamp: ts(66), rate: 1, outputLatency: latency,
                                  state: A.State(pausedAt: base + 6, pausedIdentity: "|Click A|"))
        expectEqual(near(coldStarting.timestamp, base + 66 + A.coldLeadSecs + latency), true, "MyGo: 同一首停久了先以速率 1 到的那一拍按重开输出那一档")
    }

    // ---- 停下不到 / 超过输出关闭的时长再出声 ----
    do {
        let warm = A.fill(identity: "|Click A|", playing: true, elapsed: 6.1, timestamp: ts(10), rate: 1, outputLatency: latency,
                          state: A.State(pausedAt: base + 6, pausedIdentity: "|Click A|"))
        expectEqual(near(warm.timestamp, base + 10 + shift), true, "MyGo 恢复: 停了 4 秒,输出还开着,照常挪")
        let cold = A.fill(identity: "|Click A|", playing: true, elapsed: 6.1, timestamp: ts(66), rate: 1, outputLatency: latency,
                          state: A.State(pausedAt: base + 6, pausedIdentity: "|Click A|"))
        expectEqual(near(cold.timestamp, base + 66 + A.coldLeadSecs + latency), true, "MyGo 恢复: 停了一分钟,输出已关,按重开输出那一档挪")
        expectEqual(cold.state.pausedAt == nil, true, "MyGo 恢复: 用过的停下时刻清掉")
        let bluetooth = A.fill(identity: "|Click A|", playing: true, elapsed: 6.1, timestamp: ts(66), rate: 1, outputLatency: latency,
                               outputBuiltIn: false, state: A.State(pausedAt: base + 6, pausedIdentity: "|Click A|"))
        expectEqual(near(bluetooth.timestamp, base + 66 + shift), true,
                    "MyGo 恢复: 输出不是内置扬声器(蓝牙耳机)时重开输出不比开着时晚,停久了照常挪(实测早 0.31~0.54 秒)")
        let coldNext = A.fill(identity: "|Click B|", playing: true, elapsed: 0, timestamp: ts(66), rate: 1, outputLatency: latency,
                              state: A.State(pausedAt: base + 6, pausedIdentity: "|Click A|"))
        expectEqual(near(coldNext.timestamp, base + 66 + shift), true, "MyGo: 停久了换成别的歌照常挪(新歌载入跟输出开着时一样早)")
    }

    // ---- 封面那份锚点 ----
    do {
        let start = A.fill(identity: "陈奕迅|浮夸|Solidays", playing: true, elapsed: 0.001, timestamp: ts(0), rate: 1,
                           outputLatency: latency, state: A.State())
        let cover = A.fill(identity: "陈奕迅|浮夸|Solidays", playing: true, elapsed: 0.000, timestamp: ts(0.544), rate: 1,
                           outputLatency: latency, state: start.state)
        expectEqual(cover.timestamp, start.timestamp, "MyGo 封面锚点: 开播后约 0.5 秒那份沿用开播那份的时刻")
        expectEqual(cover.elapsed, 0.001, "MyGo 封面锚点: 沿用开播那份的位置")
        let late = A.fill(identity: "陈奕迅|浮夸|Solidays", playing: true, elapsed: 0.000, timestamp: ts(1.5), rate: 1,
                          outputLatency: latency, state: start.state)
        expectEqual(near(late.timestamp, base + 1.5 + shift), true, "MyGo 封面锚点: 隔得久的不算(跳回开头)")
        let other = A.fill(identity: "陈奕迅|K歌之王|你的陈奕迅", playing: true, elapsed: 0.001, timestamp: ts(0.5), rate: 1,
                           outputLatency: latency, state: start.state)
        expectEqual(near(other.timestamp, base + 0.5 + shift), true, "MyGo 封面锚点: 换了一首的不算")
        let midway = A.fill(identity: "陈奕迅|浮夸|Solidays", playing: true, elapsed: 8, timestamp: ts(0.6), rate: 1,
                            outputLatency: latency, state: start.state)
        expectEqual(near(midway.timestamp, base + 0.6 + shift), true, "MyGo 封面锚点: 位置不在开头的不算(跳转)")
    }

    // ---- 焦点被占时单问的那份 ----
    do {
        let raw = MediaControlMicros.timestampString(base * 1_000_000)
        expectEqual(raw, ts(0), "MyGo 单问: 锚点秒数换成跟主路同一种时刻写法(同一份锚点两边认得出)")
        let out = A.fill(identity: "|Click M|", playing: true, elapsed: 0.2, timestamp: raw, rate: 1, outputLatency: latency,
                         state: A.State())
        let at = Date(timeIntervalSince1970: base + 3)
        let pos = A.position(elapsed: out.elapsed, timestamp: out.timestamp, rate: 1, playing: true, now: at) ?? -1
        expectEqual(abs(pos - (0.2 + 3 - shift)) < 0.000_01, true, "MyGo 单问: 位置按挪过的锚点推到此刻")
        let early = A.position(elapsed: 0, timestamp: out.timestamp, rate: 1, playing: true,
                               now: Date(timeIntervalSince1970: base + 0.1))
        expectEqual(early, 0, "MyGo 单问: 还没出声时不推到 0 以前")
        expectEqual(A.position(elapsed: 5, timestamp: ts(0), rate: 0, playing: false, now: at) == nil, true,
                    "MyGo 单问: 停着的不推,照单问那份原样用")
        expectEqual(A.position(elapsed: 5, timestamp: nil, rate: 1, playing: true, now: at) == nil, true,
                    "MyGo 单问: 缺锚点时刻的不推")
        let half = A.position(elapsed: 10, timestamp: ts(0), rate: 0.5, playing: true, now: at) ?? -1
        expectEqual(abs(half - 11.5) < 0.000_01, true, "MyGo 单问: 按速率推")
    }

    // ---- 单曲循环回绕(它回绕时一份锚点都不发) ----
    do {
        typealias MC = MediaControlClient
        let mygo = PlaybackPlayer.mygoMusic.bundleIdentifier
        expectEqual(MC.loopsWithoutNewAnchor(bundleID: mygo), true, "MyGo 循环: 回绕时不发新锚点,在名单里")
        let looped = MC.foobarLoopPosition(bundleID: mygo, playing: true, position: 30.1, duration: 22)
        expectEqual(looped.map { ($0 * 1000).rounded() / 1000 }, 8.1, "MyGo 循环: 越过曲长按曲长取余(实测每圈正好一个曲长,回绕间隙约 0.01 秒)")
        expectEqual(MC.foobarLoopPosition(bundleID: mygo, playing: true, position: 66.5, duration: 22)
                        .map { ($0 * 1000).rounded() / 1000 }, 0.5, "MyGo 循环: 第三圈起同样取余")
        expectEqual(MC.foobarLoopPosition(bundleID: mygo, playing: false, position: 30.1, duration: 22), nil, "MyGo 循环: 停着不动")
        let t = Date(timeIntervalSince1970: 2_000)
        expectEqual(MC.foobarLoopCheckAt(bundleID: mygo, playing: true, position: 20, duration: 22, now: t)
                        .map { ($0.timeIntervalSince(t) * 1000).rounded() / 1000 }, 2.15, "MyGo 循环: 离曲尾不到 3 秒时排一次补查")
    }

    // ---- 放本机文件:按开着的文件认,路径交引擎读同名 .lrc ----
    do {
        let mygo = PlaybackPlayer.mygoMusic.bundleIdentifier
        expectEqual(PlayerOpenFile.bundleIDs.contains(mygo), true, "MyGo 当前文件: 按它开着的文件认,路径交引擎读 .lrc")
        expectEqual(PlayerOpenFile.isPlayerCache("/Users/u/Library/Caches/MyGo Music/songs/0eab1fe41b41a19a61584eda41c89604-high.mp3"),
                    true, "MyGo 当前文件: 插件音源的缓存不算本机文件(带完整标签,按标签对得上)")
        expectEqual(PlayerOpenFile.isPlayerCache("/Users/u/Music/MyGo/陈奕迅 - 浮夸.mp3"), false, "MyGo 当前文件: 曲库里的文件照认")
        // 放过的本机《浮夸》还开着,插件音源又放同名同歌手的那首:缓存里那份对得上,在放的是插件音源。
        let local = "/Users/u/Music/MyGo/陈奕迅 - 浮夸.mp3"
        let cached = "/Users/u/Library/Caches/MyGo Music/songs/0eab1fe41b41a19a61584eda41c89604-high.mp3"
        let tagged = LocalAudioFileTags(title: "浮夸", artist: "陈奕迅", album: "U87", duration: 285)
        let match = { (paths: [String], mygo: Bool) in
            PlayerOpenFile.matchingOpenFile(paths: paths, artist: "陈奕迅", title: "浮夸", duration: nil, foobar: false,
                                            baseName: true, skipsWhenCacheMatches: mygo, tags: { _ in tagged })
        }
        expectEqual(match([local, cached], true), .playerCache, "MyGo 当前文件: 缓存里有对得上的就是插件音源,本机同名文件不算")
        if case .file(_, let path) = match([local], true) {
            expectEqual(path, local, "MyGo 当前文件: 只开着本机文件时认它")
        } else {
            expectEqual(true, false, "MyGo 当前文件: 只开着本机文件时认它")
        }
        if case .file(_, let path) = match([local, cached], false) {
            expectEqual(path, local, "当前文件: 不看缓存的播放器照旧认本机文件、跳过缓存")
        } else {
            expectEqual(true, false, "当前文件: 不看缓存的播放器照旧认本机文件、跳过缓存")
        }
        expectEqual(match([cached], false), .none, "当前文件: 只开着缓存文件时不认")
        func matches(_ artist: String, _ title: String, _ file: String) -> Bool {
            PlayerOpenFile.fileMatches(reportedArtist: artist, reportedTitle: title, reportedDuration: nil, tags: nil, fileName: file)
        }
        expectEqual([matches("陈奕迅", "浮夸", "陈奕迅 - 浮夸.mp3"), matches("", "MyGo Click A", "MyGo Click A.wav"),
                     matches("", "01 - Intro", "01 - Intro.flac"), matches("", "浮夸", "陈奕迅 - 浮夸.mp3")],
                    [true, true, true, false],
                    "MyGo 当前文件: 没标签时它按第一个「 - 」拆成歌手、歌名,左边是音轨号就整个当歌名;只报歌名不报歌手的拆法对不上")
        expectEqual(PlayerOpenFile.fileNameIdentity(reportedArtist: "", reportedTitle: "MyGo Click A", fileName: "MyGo Click A.wav",
                                                    duration: 30, acceptsBaseName: true)?.title, "MyGo Click A",
                    "MyGo 当前文件: 报的是不带扩展名的文件名,也换成文件那份身份")
    }

    // ---- 本机曲目的喜欢:读本地库,写按菜单 ----
    do {
        typealias F = MyGoFavoriteControl
        expectEqual([F.trackID(path: "/Users/chenyuhao/Music/Lyrimuse测试/MyGo/MyGo Click M.mp3"),
                     F.trackID(path: "/Users/chenyuhao/Music/Lyrimuse测试/MyGo/MyGo Click B.wav")],
                    ["34b2897a8e6d7690", "75f8939f2d4b2040"], "MyGo 喜欢: 曲目 ID 跟它会话里的一致(本机实测)")
        let lib = #"{"folders":["/Music"],"likes":["75f8939f2d4b2040","34b2897a8e6d7690"]}"#
        expectEqual(F.likes(libraryData: Data(lib.utf8)), ["75f8939f2d4b2040", "34b2897a8e6d7690"], "MyGo 喜欢: 读本地库的 likes")
        expectEqual(F.likes(libraryData: Data(#"{"folders":["/Music"]}"#.utf8)), [], "MyGo 喜欢: 没喜欢过任何一首是空表")
        expectEqual(F.likes(libraryData: Data("not json".utf8)), nil, "MyGo 喜欢: 解不开为 nil(不当成没喜欢)")
        expectEqual(F.menuTitles, ["喜欢/取消喜欢", "Like/Unlike"], "MyGo 喜欢: 菜单标题取自它的语言包(只有简体、英文)")
        typealias C = MusicPlaybackController
        expectEqual([C.supportsFavorite(.mygoMusic), C.favoriteSettlesAfterTrackChange(.mygoMusic), C.hidesFavoriteWhenWriteIgnored(.mygoMusic)],
                    [true, true, true], "MyGo 喜欢: 支持;换歌后等认出当前文件再读写;按了没生效这一首藏心")
    }

    // ---- 接线 ----
    do {
        typealias L = LocalPlaybackSource
        let mygo = PlaybackPlayer.mygoMusic.bundleIdentifier
        expectEqual(L.resumeReadingNeverLeads(bundleID: mygo), true, "MyGo 接线: 锚点挪过之后恢复那一拍原样采信,不按暂停位置封顶")
        expectEqual(L.learnsAnchorLag(bundleID: mygo), false, "MyGo 接线: 锚点在解码时已挪准,不再学锚点滞后")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let client = (try? String(contentsOfFile: root.appendingPathComponent("LyrimuseCore/Local/MediaControlClient.swift").path,
                                  encoding: .utf8)) ?? ""
        expectEqual(sourceHas(client, "let mygo = MyGoSessionAnchor.filled("), true, "MyGo 接线: 解码系统会话时挪锚点")
        let controller = (try? String(contentsOfFile: root.appendingPathComponent("LyrimuseCore/Local/MusicPlaybackController.swift").path,
                                      encoding: .utf8)) ?? ""
        let favorite = (try? String(contentsOfFile: root.appendingPathComponent("LyrimuseCore/Local/MyGoFavoriteControl.swift").path,
                                    encoding: .utf8)) ?? ""
        expectEqual([sourceHas(controller, "case .mygoMusic: return MyGoFavoriteControl.readFavorited()"),
                     sourceHas(controller, "case .mygoMusic: return MyGoFavoriteControl.setFavorited(value)"),
                     sourceHas(favorite, "if now == value { return true }\nguard pressMenuItem() == .pressed else { return false }"),
                     sourceHas(favorite, "if liked(id: id) == value { return true }")], [true, true, true, true],
                    "MyGo 接线: 喜欢读写接进分发;一样就不按;按完等本地库真的变过来才算写成")
        let openFile = (try? String(contentsOfFile: root.appendingPathComponent("LyrimuseCore/Local/PlayerOpenFile.swift").path,
                                    encoding: .utf8)) ?? ""
        expectEqual([sourceHas(openFile, "static let baseNameBundleIDs: Set<String> = [ PlaybackPlayer.foobar2000.bundleIdentifier, "
                                         + "PlaybackPlayer.swinsian.bundleIdentifier, PlaybackPlayer.mygoMusic.bundleIdentifier, ]"),
                     sourceHas(openFile, "for path in paths where !isPlayerCache(path) {")
                        && sourceHas(openFile, "mygo: bundleID == PlaybackPlayer.mygoMusic.bundleIdentifier, now: now)")
                        && sourceHas(openFile, "baseName: baseName, skipsWhenCacheMatches: mygo)")], [true, true],
                    "MyGo 接线: 没标签时按不带扩展名的文件名拆;找开着的文件时跳过插件缓存,缓存里有对得上的就不认本机文件")
        expectEqual(sourceHas(favorite, "guard let id = currentLocalTrackID(confirm: true), let now = liked(id: id) else { return false }"),
                    true, "MyGo 接线: 按「喜欢」菜单之前按开着的文件当场再核一次放的是本机文件")
        expectEqual(sourceHas(client, "timestamp = mygo.timestamp"), true, "MyGo 接线: 下游拿到的是挪过的时刻")
        expectEqual(sourceHas(client, "snapshot.republishDueBy = foobarLoopCheckAt(bundleID: probed.bundleIdentifier"), true,
                    "MyGo 接线: 焦点被占时单问那份同样取余、排补查")
        expectEqual(PlaybackPlayer.mygoMusic.durationFromProgressBar, true, "MyGo 接线: 插件流不报时长时按界面进度条补")
        expectEqual(client.components(separatedBy: "snapshot = mygoProbedSnapshot(probed.snapshot, anchor: probed.anchor, now: now)").count - 1,
                    2, "MyGo 接线: 焦点被占时两处单问(暂停焦点顶替、焦点回退第二级)都过同一套挪法")
        if let latency = AudioOutputRoute.outputLatencySecs() {
            expectEqual(latency >= 0 && latency < 1, true, "MyGo 接线: 默认输出设备的延迟读得到、在合理范围")
        }
    }
}
