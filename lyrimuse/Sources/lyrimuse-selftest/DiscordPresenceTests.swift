import Darwin
import Foundation
import LyrimuseCore

// Discord「正在听」:帧编解码与消息、activity 组装、暂停宽限、节流去重,再起一个假 Discord(临时 Unix 套接字,
// 路径带 pid 和 UUID)走一遍握手 → 发状态 → 被拒 → 清空 → 心跳 → 断开重连,最后是接线契约。

func runDiscordPresenceTests() {
    checkDiscordWire()
    checkDiscordActivity()
    checkDiscordSmallImage()
    checkDiscordPaused()
    checkDiscordArtistLinks()
    checkDiscordGate()
    checkDiscordConnection()
    checkDiscordCover()
    checkDiscordWiring()
}

private func jsonString(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self)
}

private func sampleTrack(position: Int? = 30_000, duration: Int? = 200_000) -> DiscordPresence.Track {
    DiscordPresence.Track(
        title: "晴天", artist: "周杰伦", album: "叶惠美", playerName: "Apple Music",
        coverURL: URL(string: "https://is1-ssl.mzstatic.com/image/thumb/a/600x600bb.jpg"),
        songURL: URL(string: "https://music.apple.com/cn/album/x/1?i=2"),
        artistURL: URL(string: "https://y.qq.com/n/ryqq/singer/abc"),
        positionMs: position, durationMs: duration)
}

private func checkDiscordWire() {
    // ---- 帧 ----
    let frame = DiscordIPC.encode(.frame, Data("{}".utf8))
    expectEqual([UInt8](frame), [1, 0, 0, 0, 2, 0, 0, 0, 0x7B, 0x7D], "Discord 帧: 操作码、长度各 4 字节小端,后接载荷")

    var buffer = DiscordIPC.encode(.handshake, Data("{\"a\":1}".utf8)) + DiscordIPC.encode(.ping, Data("{}".utf8))
    var partial = Data(buffer.prefix(10))
    do {
        expectEqual(try DiscordIPC.takeFrame(from: &partial), nil, "Discord 帧: 不够一帧返回 nil")
        expectEqual(partial.count, 10, "Discord 帧: 不够一帧时缓冲区不动")
        let first = try DiscordIPC.takeFrame(from: &buffer)
        expectEqual(first?.opcode, 0, "Discord 帧: 连着两帧先取第一帧")
        expectEqual(first?.payload, Data("{\"a\":1}".utf8), "Discord 帧: 第一帧的载荷")
        let second = try DiscordIPC.takeFrame(from: &buffer)
        expectEqual(second?.opcode, 3, "Discord 帧: 再取第二帧")
        expectEqual(buffer.isEmpty, true, "Discord 帧: 取完缓冲区清空")
    } catch {
        expectEqual("\(error)", "", "Discord 帧: 正常的帧解得开")
    }
    var oversized = Data([1, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0x7F])
    do {
        _ = try DiscordIPC.takeFrame(from: &oversized)
        expectEqual(false, true, "Discord 帧: 长度超限抛错")
    } catch {
        expectEqual((error as? DiscordIPC.OversizedFrame)?.length, 0x7FFF_FFFF, "Discord 帧: 长度超限抛错")
    }

    // ---- 消息 ----
    expectEqual(jsonString(DiscordIPC.handshake(clientID: "123")), "{\"client_id\":\"123\",\"v\":1}", "Discord 消息: 握手")
    expectEqual(jsonString(DiscordIPC.setActivity(nil, pid: 42, nonce: "7")),
                "{\"args\":{\"pid\":42},\"cmd\":\"SET_ACTIVITY\",\"nonce\":\"7\"}",
                "Discord 消息: 清空不带 activity 键")
    let activity = DiscordPresence.activity(sampleTrack(position: nil), statusLine: .title, now: nil)
    let setJSON = jsonString(DiscordIPC.setActivity(activity, pid: 42, nonce: "8"))
    expectEqual(setJSON,
                "{\"args\":{\"activity\":{\"assets\":{\"large_image\":\"https://is1-ssl.mzstatic.com/image/thumb/a/600x600bb.jpg\","
                + "\"large_text\":\"叶惠美\",\"large_url\":\"https://music.apple.com/cn/album/x/1?i=2\"},"
                + "\"details\":\"晴天\",\"details_url\":\"https://music.apple.com/cn/album/x/1?i=2\",\"name\":\"Apple Music\","
                + "\"state\":\"周杰伦\",\"state_url\":\"https://y.qq.com/n/ryqq/singer/abc\",\"status_display_type\":2,\"type\":2},"
                + "\"pid\":42},\"cmd\":\"SET_ACTIVITY\",\"nonce\":\"8\"}",
                "Discord 消息: SET_ACTIVITY 的字段名与取值,没有时间戳时不带 timestamps")

    // ---- 回包 ----
    func reply(_ opcode: DiscordIPC.Opcode, _ json: String) -> DiscordIPC.Reply {
        DiscordIPC.reply(to: DiscordIPC.Frame(opcode: opcode.rawValue, payload: Data(json.utf8)))
    }
    expectEqual(reply(.frame, "{\"cmd\":\"DISPATCH\",\"evt\":\"READY\",\"data\":{\"v\":1,\"user\":{\"id\":\"1\",\"username\":\"tester\",\"global_name\":\"T\"}}}"),
                .ready(user: DiscordUser(id: "1", username: "tester", globalName: "T")), "Discord 回包: READY 带账号(ID、用户名、显示名)")
    expectEqual(reply(.frame, "{\"cmd\":\"DISPATCH\",\"evt\":\"READY\",\"data\":{\"user\":{\"id\":\"2\",\"username\":\"u\",\"global_name\":\"\",\"avatar\":\"0123456789abcdef0123456789abcdef\",\"discriminator\":\"0\"}}}"),
                .ready(user: DiscordUser(id: "2", username: "u", avatar: "0123456789abcdef0123456789abcdef", discriminator: "0")),
                "Discord 回包: READY 带头像与编号,空显示名当没给")
    expectEqual(reply(.frame, "{\"cmd\":\"DISPATCH\",\"evt\":\"READY\",\"data\":{\"user\":{\"username\":\"u\"}}}"), .ready(user: nil),
                "Discord 回包: 账号没有 ID 当没有")
    expectEqual(reply(.frame, "{\"cmd\":\"DISPATCH\",\"evt\":\"READY\",\"data\":{\"v\":1}}"), .ready(user: nil),
                "Discord 回包: READY 没有用户也算握手成功")
    expectEqual(reply(.frame, "{\"cmd\":\"SET_ACTIVITY\",\"evt\":\"ERROR\",\"nonce\":\"3\",\"data\":{\"code\":4000,\"message\":\"bad\"}}"),
                .error(nonce: "3", code: 4000, message: "bad"), "Discord 回包: 命令被拒")
    expectEqual(reply(.frame, "{\"cmd\":\"SET_ACTIVITY\",\"evt\":null,\"nonce\":\"4\",\"data\":{}}"), .ack(nonce: "4"),
                "Discord 回包: 命令回执")
    expectEqual(reply(.close, "{\"code\":4000,\"message\":\"Invalid Client ID\"}"),
                .close(code: 4000, message: "Invalid Client ID"), "Discord 回包: 关闭帧带代码和原因")
    expectEqual(reply(.ping, "{\"x\":1}"), .ping(Data("{\"x\":1}".utf8)), "Discord 回包: 心跳原样带回")
    expectEqual(reply(.frame, "{\"cmd\":\"DISPATCH\",\"evt\":\"ACTIVITY_JOIN\"}"), .other, "Discord 回包: 别的事件不认")

    // ---- 账号 ----
    let hash = "0123456789abcdef0123456789abcdef"
    expectEqual(DiscordUser(id: "1", username: "u", globalName: "显示名").displayName, "显示名", "Discord 账号: 有显示名用显示名")
    expectEqual(DiscordUser(id: "1", username: "u", globalName: "  ").displayName, "u", "Discord 账号: 显示名是空白时用用户名")
    expectEqual(DiscordUser(id: "80351110224678912", username: "u", avatar: hash).avatarURL()?.absoluteString,
                "https://cdn.discordapp.com/avatars/80351110224678912/\(hash).png?size=128", "Discord 账号: 传过头像用自己的")
    expectEqual(DiscordUser(id: "80351110224678912", username: "u", avatar: "a_" + hash).avatarURL()?.absoluteString,
                "https://cdn.discordapp.com/avatars/80351110224678912/a_\(hash).png?size=128", "Discord 账号: 动图头像取静态那张")
    expectEqual(DiscordUser(id: "80351110224678912", username: "u", discriminator: "0").avatarURL()?.absoluteString,
                "https://cdn.discordapp.com/embed/avatars/5.png",
                "Discord 账号: 没头像、新用户名体系按 ID 算默认头像")
    expectEqual(DiscordUser(id: "1", username: "u", discriminator: "1337").avatarURL()?.absoluteString,
                "https://cdn.discordapp.com/embed/avatars/2.png", "Discord 账号: 没头像、旧体系按编号模 5")
    expectEqual(DiscordUser(id: "1", username: "u", avatar: "../x").avatarURL()?.absoluteString,
                "https://cdn.discordapp.com/embed/avatars/0.png", "Discord 账号: 头像哈希格式不对当没有,不拼进地址")
    expectEqual(DiscordUser(id: "12a", username: "u", avatar: hash).avatarURL(), nil, "Discord 账号: ID 不是纯数字不给地址")

    // ---- 设置页预览 ----
    let previewNow = Date(timeIntervalSince1970: 2_000_000)
    var previewSample = sampleTrack()
    previewSample.positionMs = 30_000
    previewSample.durationMs = 200_000
    let byTitle = DiscordPresence.activity(previewSample, statusLine: .title, now: previewNow)
    expectEqual(DiscordPresence.statusText(of: byTitle), byTitle.details, "Discord 预览: 状态写歌名")
    expectEqual(DiscordPresence.statusText(of: DiscordPresence.activity(previewSample, statusLine: .artist, now: previewNow)),
                byTitle.state, "Discord 预览: 状态写歌手")
    expectEqual(DiscordPresence.statusText(of: DiscordPresence.activity(previewSample, statusLine: .player, now: previewNow)),
                byTitle.name ?? "", "Discord 预览: 状态写播放器(应用名)")
    expectEqual(DiscordPresence.progress(of: byTitle, now: previewNow.addingTimeInterval(10)).map { [$0.elapsedMs, $0.totalMs] },
                [40_000, 200_000], "Discord 预览: 进度按此刻算")
    expectEqual(DiscordPresence.progress(of: byTitle, now: previewNow.addingTimeInterval(500)).map { $0.elapsedMs }, 200_000,
                "Discord 预览: 已放的不超过整首")
    previewSample.positionMs = nil
    expectEqual(DiscordPresence.progress(of: DiscordPresence.activity(previewSample, statusLine: .title, now: previewNow),
                                         now: previewNow) == nil, true, "Discord 预览: 暂停时没有进度条")
    expectEqual(DiscordPresence.application(forApplicationID: DiscordPresence.applicationID(
        forBundleID: PlaybackPlayer.spotify.bundleIdentifier, webPlatformID: nil)), .spotify, "Discord 预览: 应用 ID 认回播放器")
    expectEqual(DiscordPresence.application(forApplicationID: "0"), .lyrimuse, "Discord 预览: 认不出的应用 ID 算 Lyrimuse")
    expectEqual(DiscordPresence.Application.allCases.allSatisfy { !$0.registeredName.isEmpty }, true,
                "Discord 预览: 每个应用都有注册名")

    // ---- 没连上时卡在哪 ----
    expectEqual(DiscordPresence.waiting(installed: false, running: false), .notInstalled, "Discord 引导: 没装")
    expectEqual(DiscordPresence.waiting(installed: true, running: false), .notRunning, "Discord 引导: 装了没开")
    expectEqual(DiscordPresence.waiting(installed: true, running: true), .connecting, "Discord 引导: 开着在连")
    expectEqual(DiscordPresence.waiting(installed: false, running: true), .connecting, "Discord 引导: 开着就算装了")
    expectEqual(DiscordPresence.desktopBundleIDs.first, "com.hnc.Discord", "Discord 引导: 先认正式版")
    expectEqual(DiscordPresence.downloadURL?.host, "discord.com", "Discord 引导: 下载页在 discord.com")

    // ---- 套接字位置 ----
    let paths = DiscordIPC.socketPaths(in: ["/tmp/x/", "/tmp/x", "", "/var/y"])
    expectEqual(paths.count, 20, "Discord 套接字: 每个目录 0~9 十个,目录去重")
    expectEqual(paths.first, "/tmp/x/discord-ipc-0", "Discord 套接字: 先试第一个目录的 0 号")
    expectEqual(paths.last, "/var/y/discord-ipc-9", "Discord 套接字: 最后是最后一个目录的 9 号")
}

private func checkDiscordActivity() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let playing = DiscordPresence.activity(sampleTrack(), statusLine: .title, now: now)
    expectEqual(playing.type, 2, "Discord activity: 类型是 Listening")
    expectEqual(playing.name, "Apple Music", "Discord activity: 应用名覆盖成播放器名")
    expectEqual(playing.details, "晴天", "Discord activity: details 是歌名")
    expectEqual(playing.state, "周杰伦", "Discord activity: state 是歌手")
    expectEqual(playing.timestamps, DiscordActivity.Timestamps(start: 999_970_000, end: 1_000_170_000),
                "Discord activity: 起点 = 此刻 − 进度,终点 = 起点 + 时长")
    expectEqual(playing.assets?.largeImage, "https://is1-ssl.mzstatic.com/image/thumb/a/600x600bb.jpg", "Discord activity: 大图用封面地址")
    expectEqual(playing.assets?.largeText, "叶惠美", "Discord activity: 大图悬停显示专辑")
    expectEqual(playing.assets?.largeURL, "https://music.apple.com/cn/album/x/1?i=2", "Discord activity: 点大图打开歌曲页")
    expectEqual(playing.applicationID, DiscordPresence.applicationID, "Discord activity: 没指定应用时发给 Lyrimuse 那个")
    expectEqual(DiscordPresence.StatusLine.allCases.map(\.displayType), [2, 1, 0],
                "Discord activity: 状态里显示 歌名 / 歌手 / 播放器 对应 status_display_type 2 / 1 / 0")
    expectEqual(DiscordPresence.activity(sampleTrack(), statusLine: .artist, now: now).statusDisplayType, 1,
                "Discord activity: 设置传到 status_display_type")
    expectEqual(DiscordPresence.listeningName(bundleID: PlaybackPlayer.kaset.bundleIdentifier, displayName: "Kaset"),
                "YouTube Music", "Discord activity: Kaset 写成 YouTube Music")
    expectEqual(DiscordPresence.listeningName(bundleID: PlaybackPlayer.appleMusic.bundleIdentifier, displayName: "Apple Music"),
                "Apple Music", "Discord activity: 别的播放器照界面上的名字")
    expectEqual(DiscordPresence.listeningName(bundleID: nil, displayName: nil), nil,
                "Discord activity: 认不出的播放器不覆盖应用名")

    expectEqual(DiscordPresence.activity(sampleTrack(duration: nil), statusLine: .title, now: now).timestamps,
                DiscordActivity.Timestamps(start: 999_970_000, end: nil), "Discord activity: 没时长只给起点")
    expectEqual(DiscordPresence.activity(sampleTrack(position: nil), statusLine: .title, now: now).timestamps, nil,
                "Discord activity: 没位置不给时间戳")
    expectEqual(DiscordPresence.activity(sampleTrack(), statusLine: .title, now: nil).timestamps, nil,
                "Discord activity: 暂停保留的那份不给时间戳")

    var bare = sampleTrack()
    bare.coverURL = nil
    bare.album = " "
    bare.playerName = ""
    bare.songURL = URL(string: "music://music.apple.com/cn/album/x/1?i=2")
    bare.artistURL = nil
    let fallback = DiscordPresence.activity(bare, statusLine: .title, now: now)
    expectEqual(fallback.assets, nil, "Discord activity: 没封面不给大图,Discord 显示应用自己的图标")
    expectEqual(fallback.name, nil, "Discord activity: 没播放器名不覆盖应用名")
    expectEqual(fallback.detailsURL, nil, "Discord activity: 进 App 的深链不当链接")
    var noAlbum = sampleTrack()
    noAlbum.album = " "
    expectEqual(DiscordPresence.activity(noAlbum, statusLine: .title, now: now).assets?.largeText, nil,
                "Discord activity: 没专辑不写悬停文字")
    var localCover = sampleTrack()
    localCover.coverURL = URL(fileURLWithPath: "/tmp/cover.jpg")
    expectEqual(DiscordPresence.activity(localCover, statusLine: .title, now: now).assets, nil,
                "Discord activity: 本地文件封面 Discord 拿不到,不给大图")
    var plainHTTP = sampleTrack()
    plainHTTP.coverURL = URL(string: "http://example.com/a.jpg")
    expectEqual(DiscordPresence.activity(plainHTTP, statusLine: .title, now: now).assets, nil,
                "Discord activity: 封面只认 https")

    // ---- 每个播放器一个应用 ----
    typealias A = DiscordPresence.Application
    func app(_ player: PlaybackPlayer) -> A { DiscordPresence.application(forBundleID: player.bundleIdentifier, webPlatformID: nil) }
    expectEqual([app(.appleMusic), app(.kaset), app(.spotify), app(.qqMusic), app(.netease), app(.kugou), app(.soda),
                 app(.kkbox), app(.amazonMusic)],
                [.appleMusic, .youtubeMusic, .spotify, .qqMusic, .netease, .kugou, .soda, .kkbox, .amazonMusic],
                "Discord 应用: 内置播放器各归各的应用,Kaset 归 YouTube Music")
    expectEqual(DiscordPresence.application(forBundleID: "com.apple.WebKit.GPU", webPlatformID: "youtubeMusic"), .youtubeMusic,
                "Discord 应用: 浏览器里的 YouTube Music 归 YouTube Music")
    expectEqual(DiscordPresence.application(forBundleID: "com.google.Chrome", webPlatformID: "spotifyWeb"), .spotify,
                "Discord 应用: 网页版 Spotify 归 Spotify")
    expectEqual(DiscordPresence.application(forBundleID: "com.example.player", webPlatformID: nil), .lyrimuse,
                "Discord 应用: 认不出的播放器用 Lyrimuse 那个")
    expectEqual(DiscordPresence.applicationID(forBundleID: "com.example.player", webPlatformID: nil), DiscordPresence.applicationID,
                "Discord 应用: Lyrimuse 那个的 ID")
    let builtInIDs = PlaybackPlayer.allCases.filter { $0 != .auto }.map {
        DiscordPresence.applicationID(forBundleID: $0.bundleIdentifier, webPlatformID: nil)
    }
    expectEqual(builtInIDs.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }, true,
                "Discord 应用: 每个内置播放器的应用 ID 都是一串数字")
    expectEqual(Set(builtInIDs).count, builtInIDs.count, "Discord 应用: 内置播放器各用各的应用,ID 不重复")
    expectEqual(builtInIDs.contains(DiscordPresence.applicationID), false, "Discord 应用: 内置播放器都不落到 Lyrimuse 那个")
    expectEqual(DiscordPresence.applicationID(forBundleID: "com.google.Chrome", webPlatformID: "youtubeMusic"),
                DiscordPresence.applicationID(forBundleID: PlaybackPlayer.kaset.bundleIdentifier, webPlatformID: nil),
                "Discord 应用: 网页版 YouTube Music 和 Kaset 发给同一个应用")
    var longLink = sampleTrack()
    longLink.songURL = URL(string: "https://example.com/" + String(repeating: "a", count: 600))
    expectEqual(DiscordPresence.activity(longLink, statusLine: .title, now: now).detailsURL, nil,
                "Discord activity: 超长链接不给(截断的链接会让整条被拒)")

    // ---- 文本长度 ----
    expectEqual(DiscordPresence.fitted("雨"), "雨\u{200B}",
                "Discord 文本: 不够两位补零宽空格(补普通空格的话,Discord 去掉首尾空白再校验就还是不够两位)")
    expectEqual(DiscordPresence.fitted("  hello \n"), "hello", "Discord 文本: 去掉首尾空白")
    expectEqual(DiscordPresence.fitted("😀"), "😀", "Discord 文本: 一个 emoji 已经占两位")
    let long = DiscordPresence.fitted(String(repeating: "长", count: 200))
    expectEqual(long.utf16.count, 128, "Discord 文本: 超长截到 128 位")
    expectEqual(long.hasSuffix("…"), true, "Discord 文本: 截断加省略号")
    let emojiEdge = DiscordPresence.fitted(String(repeating: "a", count: 126) + "😀b")
    expectEqual(emojiEdge, String(repeating: "a", count: 126) + "…", "Discord 文本: 截断不切开 emoji")

    // ---- 此刻该显示什么 ----
    func intent(_ track: DiscordPresence.Track?, pausedFor: TimeInterval? = nil, keep: Bool = false) -> DiscordPresence.Intent {
        DiscordPresence.intent(track: track, pausedSince: pausedFor.map { now.addingTimeInterval(-$0) },
                               statusLine: .title, keepWhenPaused: keep, now: now)
    }
    expectEqual(intent(nil), .clear, "Discord 意图: 没在放就清掉")
    var noArtist = sampleTrack()
    noArtist.artist = "  "
    expectEqual(intent(noArtist), .clear, "Discord 意图: 没歌手就清掉")
    expectEqual(intent(sampleTrack()), .show(playing), "Discord 意图: 在放就显示,带时间戳")
    expectEqual(intent(sampleTrack(), pausedFor: 3), .hold(until: now.addingTimeInterval(7)),
                "Discord 意图: 刚暂停先留着,宽限满了再看")
    expectEqual(intent(sampleTrack(), pausedFor: 10), .clear, "Discord 意图: 暂停满宽限默认清掉")
    expectEqual(intent(sampleTrack(), pausedFor: 10, keep: true),
                .show(DiscordPresence.pausedActivity(sampleTrack(), statusLine: .title, now: now, pausedText: "Paused",
                                                     pausedNameFormat: "%@ (Paused)")),
                "Discord 意图: 选了暂停时保留,换成不带进度条、带暂停小图的那份")
}

private func checkDiscordSmallImage() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let badged = DiscordPresence.activity(sampleTrack(), statusLine: .title, now: now, smallImage: .lyrimuse)
    expectEqual(badged.assets?.smallImage, DiscordPresence.lyrimuseBadgeURL, "Discord 小图: 角标是 Lyrimuse 应用 Art Assets 里那张")
    expectEqual(badged.assets?.smallText, "Lyrimuse", "Discord 小图: 角标悬停写 Lyrimuse")
    expectEqual(badged.assets?.smallURL, DiscordPresence.websiteURL, "Discord 小图: 点角标打开官网")
    expectEqual(DiscordPresence.lyrimuseBadgeURL.hasPrefix("https://cdn.discordapp.com/app-assets/" + DiscordPresence.applicationID + "/"),
                true, "Discord 小图: 角标地址在 Lyrimuse 应用名下,各播放器的应用都能用")
    let paused = DiscordPresence.activity(sampleTrack(), statusLine: .title, now: nil, smallImage: .paused("已暂停"))
    expectEqual(paused.assets?.smallImage, DiscordPresence.pausedBadgeURL, "Discord 小图: 暂停图标")
    expectEqual(paused.assets?.smallText, "已暂停", "Discord 小图: 暂停图标悬停写已暂停")
    expectEqual(paused.assets?.smallURL, DiscordPresence.websiteURL, "Discord 小图: 点暂停图标也打开官网")
    var noCover = sampleTrack()
    noCover.coverURL = nil
    expectEqual(DiscordPresence.activity(noCover, statusLine: .title, now: now, smallImage: .lyrimuse).assets, nil,
                "Discord 小图: 没有封面时小图也不给")
    let appleMusicID = DiscordPresence.applicationID(forBundleID: PlaybackPlayer.appleMusic.bundleIdentifier, webPlatformID: nil)
    let playerBadged = DiscordPresence.activity(sampleTrack(), statusLine: .title, now: now, smallImage: .player(.appleMusic))
    expectEqual(playerBadged.assets?.smallImage,
                "https://cdn.discordapp.com/app-icons/" + appleMusicID + "/25a8439ce78331e5e5880499892a70c6.png?size=256",
                "Discord 小图: 播放器角标是它那个应用的 APP 图标")
    expectEqual(playerBadged.assets?.smallText, "Apple Music", "Discord 小图: 播放器角标悬停写播放器名")
    expectEqual(playerBadged.assets?.smallURL, DiscordPresence.websiteURL, "Discord 小图: 点播放器角标也打开官网")
    for application in DiscordPresence.Application.allCases {
        let url = DiscordPresence.iconURL(of: application) ?? ""
        let hash = url.split(separator: "/").last.map { String($0.prefix(32)) } ?? ""
        expectEqual(url.hasPrefix("https://cdn.discordapp.com/app-icons/") && hash.count == 32
                        && hash.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) },
                    true, "Discord 小图: \(application) 有 APP 图标地址")
    }
    expectEqual(DiscordPresence.smallImage(for: .player, applicationID: appleMusicID), .player(.appleMusic),
                "Discord 角标: 选播放器时用当前播放器的应用")
    expectEqual(DiscordPresence.smallImage(for: .player, applicationID: DiscordPresence.applicationID), nil,
                "Discord 角标: 认不出的播放器(归 Lyrimuse 那个应用)不给播放器角标")
    expectEqual(DiscordPresence.smallImage(for: .lyrimuse, applicationID: appleMusicID), .lyrimuse, "Discord 角标: 选 Lyrimuse")
    expectEqual(DiscordPresence.smallImage(for: .none, applicationID: appleMusicID), nil, "Discord 角标: 选不显示")
    let json = jsonString(DiscordIPC.setActivity(badged, pid: 1, nonce: "1"))
    expectEqual(sourceBytes(json, contain: "\"small_image\":\"" + DiscordPresence.lyrimuseBadgeURL + "\""),
                true, "Discord 小图: 字段名 small_image")
    expectEqual(sourceBytes(json, contain: "\"small_text\":\"Lyrimuse\""), true, "Discord 小图: 字段名 small_text")
    expectEqual(sourceBytes(json, contain: "\"small_url\":"), true, "Discord 小图: 字段名 small_url")
    expectEqual(sourceBytes(jsonString(DiscordIPC.setActivity(paused, pid: 1, nonce: "1")),
                            contain: "\"small_url\":\"" + DiscordPresence.websiteURL + "\""),
                true, "Discord 小图: 暂停那份也带官网链接")

    func intent(_ track: DiscordPresence.Track?, pausedFor: TimeInterval? = nil, keep: Bool = false,
                badge: DiscordPresence.Badge = .lyrimuse, hiddenUntil: Date? = nil) -> DiscordPresence.Intent {
        DiscordPresence.intent(track: track, pausedSince: pausedFor.map { now.addingTimeInterval(-$0) }, statusLine: .title,
                               keepWhenPaused: keep, badge: badge, pausedText: "已暂停", hiddenUntil: hiddenUntil, now: now)
    }
    expectEqual(intent(sampleTrack()), .show(badged), "Discord 意图: 开着角标时在放的那份带角标")
    expectEqual(intent(sampleTrack(), badge: .none), .show(DiscordPresence.activity(sampleTrack(), statusLine: .title, now: now)),
                "Discord 意图: 角标选不显示时不带小图")
    var appleMusicTrack = sampleTrack()
    appleMusicTrack.applicationID = appleMusicID
    expectEqual(intent(appleMusicTrack, badge: .player),
                .show(DiscordPresence.activity(appleMusicTrack, statusLine: .title, now: now, smallImage: .player(.appleMusic))),
                "Discord 意图: 角标选播放器时带当前播放器的图标")
    expectEqual(intent(sampleTrack(), pausedFor: 10, keep: true, badge: .none),
                .show(DiscordPresence.pausedActivity(sampleTrack(), statusLine: .title, now: now, pausedText: "已暂停",
                                                     pausedNameFormat: "%@ (Paused)")),
                "Discord 意图: 暂停后保留的那份带暂停图标,不受角标设置管")
    expectEqual(intent(sampleTrack(), pausedFor: 3, keep: true), .hold(until: now.addingTimeInterval(7)),
                "Discord 意图: 宽限内还是在放那份,先不换暂停图标")
    expectEqual(intent(sampleTrack(), hiddenUntil: now.addingTimeInterval(60)), .clear, "Discord 意图: 暂时隐藏期间清掉")
    expectEqual(intent(sampleTrack(), pausedFor: 10, keep: true, hiddenUntil: now.addingTimeInterval(60)), .clear,
                "Discord 意图: 暂时隐藏期间暂停保留的那份也清掉")
    expectEqual(intent(sampleTrack(), hiddenUntil: now), .show(badged), "Discord 意图: 隐藏到点就恢复")
    expectEqual(DiscordPresence.hideDurations.contains(60), true, "Discord 暂时隐藏: 默认的 60 分钟在可选时长里")
}

private func checkDiscordPaused() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let nowMs: Int64 = 1_000_000_000
    let hour: Int64 = 3_600_000
    func pausedAt(_ date: Date, _ track: DiscordPresence.Track = sampleTrack()) -> DiscordActivity {
        DiscordPresence.pausedActivity(track, statusLine: .player, now: date, pausedText: "已暂停", pausedNameFormat: "%@（已暂停）")
    }
    let paused = pausedAt(now)
    expectEqual(paused.name, "Apple Music（已暂停）", "Discord 暂停: 应用名后面加（已暂停）")
    expectEqual(paused.statusDisplayType, 0, "Discord 暂停: 状态里显示播放器时成员名单那一行也带（已暂停）")
    expectEqual(paused.timestamps?.end, nil, "Discord 暂停: 不给结束时间")
    let start = paused.timestamps?.start ?? 0
    expectEqual(start > nowMs + 12 * hour && start <= nowMs + 24 * hour, true, "Discord 暂停: 开始时间在十二到二十四小时之后")
    expectEqual(DiscordPresence.elapsed(of: paused, now: now), 0, "Discord 暂停: 开始在将来,卡片底下停在 0:00")
    expectEqual(DiscordPresence.elapsed(of: paused, now: now.addingTimeInterval(11 * 3600)), 0, "Discord 暂停: 十一小时后还是 0:00")
    expectEqual(DiscordPresence.progress(of: paused, now: now) == nil, true, "Discord 暂停: 没有进度条")
    expectEqual(paused.assets?.smallImage, DiscordPresence.pausedBadgeURL, "Discord 暂停: 封面角上是暂停图标")
    expectEqual(pausedAt(now.addingTimeInterval(3600)).timestamps, paused.timestamps, "Discord 暂停: 同一个十二小时段里内容不变,不重发")
    expectEqual(pausedAt(now.addingTimeInterval(12 * 3600)).timestamps?.start, start + 12 * hour, "Discord 暂停: 跨段时往后挪十二小时")
    var unnamed = sampleTrack()
    unnamed.playerName = nil
    expectEqual(pausedAt(now, unnamed).name, "Lyrimuse（已暂停）", "Discord 暂停: 没有播放器名时拿应用的注册名去拼")
    let startOnly = DiscordPresence.activity(sampleTrack(duration: nil), statusLine: .title, now: now)
    expectEqual(DiscordPresence.elapsed(of: startOnly, now: now), 30_000, "Discord 时长: 只有开始时间时写从开始到现在")
    expectEqual(DiscordPresence.elapsed(of: DiscordPresence.activity(sampleTrack(), statusLine: .title, now: now), now: now),
                nil, "Discord 时长: 有结束时间时走进度条,不写这一行")
}

private func checkDiscordArtistLinks() {
    typealias P = PlatformLinks
    let kkPage = "https://www.kkbox.com/tw/tc/song/PXNNjXTb8IwsAGWavd"
    expectEqual(P.kkboxArtistWebURL(songPage: kkPage, artistID: "8q3_xzjl89Yakn_7GB")?.absoluteString,
                "https://www.kkbox.com/tw/tc/artist/8q3_xzjl89Yakn_7GB", "Discord 歌手链接: KKBOX 歌手网页沿用歌曲页的地区和语言")
    expectEqual(P.kkboxArtistWebURL(songPage: "https://www.kkbox.com/tw/tc/album/X", artistID: "A"), nil,
                "Discord 歌手链接: KKBOX 歌曲页形状不对不给")
    expectEqual(P.kkboxArtistWebURL(songPage: "https://www.kkbox.com/tw%2Fx/tc/song/X", artistID: "A"), nil,
                "Discord 歌手链接: KKBOX 地区那一段不像地区不给")
    expectEqual(P.kkboxArtistWebURL(songPage: kkPage, artistID: "a b"), nil, "Discord 歌手链接: KKBOX 歌手 id 形状不对不给")
    expectEqual(P.kkboxArtistWebURL(songPage: kkPage, artistID: ""), nil, "Discord 歌手链接: KKBOX 没有歌手 id 不给")

    func page(_ name: String) -> URL? { URL(string: "https://example.com/" + name) }
    let links = PlatformLinks(appleMusic: nil, qqSong: nil, qqAlbum: nil, qqArtist: page("qq"), neteaseSong: nil,
                              sodaArtist: page("soda"), kkboxArtist: URL(string: "kkbox://artist/A#view"),
                              amazonArtist: page("amazon"), spotifyArtist: page("spotify"), youtubeMusicArtist: page("ytm"),
                              kkboxArtistWeb: page("kkbox"))
    let cases: [(bundleID: String?, web: String?, want: String?)] = [
        (PlaybackPlayer.qqMusic.bundleIdentifier, nil, "qq"),
        (PlaybackPlayer.netease.bundleIdentifier, nil, nil),
        (PlaybackPlayer.spotify.bundleIdentifier, nil, "spotify"),
        (PlaybackPlayer.kkbox.bundleIdentifier, nil, "kkbox"),
        (PlaybackPlayer.amazonMusic.bundleIdentifier, nil, "amazon"),
        (PlaybackPlayer.kaset.bundleIdentifier, nil, "ytm"),
        (PlaybackPlayer.soda.bundleIdentifier, nil, "soda"),
        ("com.google.Chrome", "spotifyWeb", "spotify"),
        (PlaybackPlayer.appleMusic.bundleIdentifier, nil, nil),
        (PlaybackPlayer.kugou.bundleIdentifier, nil, nil),
        ("com.google.Chrome", "youtubeMusic", nil),
        (nil, nil, nil),
    ]
    for c in cases {
        expectEqual(links.artistWebLink(forPlayerBundleID: c.bundleID, webPlatformID: c.web), c.want.flatMap(page),
                    "Discord 歌手链接: \(c.bundleID ?? "nil") / \(c.web ?? "nil") 取它自己那个平台的网页歌手页")
    }
}

private func checkDiscordGate() {
    let t0 = Date(timeIntervalSince1970: 2_000_000)
    let base = DiscordPresence.activity(sampleTrack(), statusLine: .title, now: t0)
    func shifted(_ ms: Int64) -> DiscordActivity {
        var copy = base
        copy.timestamps?.start += ms
        copy.timestamps?.end? += ms
        return copy
    }
    var gate = DiscordPresenceGate()
    expectEqual(gate.decide(.clear, now: t0), .none, "Discord 节流: 没发过就不用清")
    expectEqual(gate.decide(.show(base), now: t0), .send(base), "Discord 节流: 第一份马上发")
    gate.didSend(base, at: t0)
    expectEqual(gate.decide(.show(base), now: t0.addingTimeInterval(1)), .none, "Discord 节流: 一样的不再发")
    expectEqual(gate.decide(.show(shifted(1_500)), now: t0.addingTimeInterval(1)), .none,
                "Discord 节流: 时间戳差 2 秒以内算没变")
    expectEqual(gate.decide(.show(shifted(2_500)), now: t0.addingTimeInterval(1)), .wait(until: t0.addingTimeInterval(4)),
                "Discord 节流: 拖动进度算变了,离上次不到 4 秒先等")
    expectEqual(gate.decide(.show(shifted(2_500)), now: t0.addingTimeInterval(5)), .send(shifted(2_500)),
                "Discord 节流: 满 4 秒发")
    var renamed = base
    renamed.details = "七里香"
    expectEqual(gate.decide(.show(renamed), now: t0.addingTimeInterval(2)), .wait(until: t0.addingTimeInterval(4)),
                "Discord 节流: 换歌也受 4 秒限制")
    expectEqual(gate.decide(.hold(until: t0.addingTimeInterval(9)), now: t0.addingTimeInterval(2)),
                .wait(until: t0.addingTimeInterval(9)), "Discord 节流: 暂停宽限内不动,到点再看")
    expectEqual(gate.decide(.clear, now: t0.addingTimeInterval(6)), .send(nil), "Discord 节流: 发过再清要发")
    gate.didSend(nil, at: t0.addingTimeInterval(6))
    expectEqual(gate.decide(.clear, now: t0.addingTimeInterval(20)), .none, "Discord 节流: 清过不再清")
    gate.didSend(base, at: t0.addingTimeInterval(20))
    gate.forget()
    expectEqual(gate.decide(.show(base), now: t0.addingTimeInterval(30)), .send(base), "Discord 节流: 断线之后同一份也重发")
    expectEqual(gate.decide(.clear, now: t0.addingTimeInterval(30)), .none, "Discord 节流: 断线之后不用清")
    expectEqual(gate.decide(.show(base), now: t0.addingTimeInterval(21)), .wait(until: t0.addingTimeInterval(24)),
                "Discord 节流: 断线不重置 4 秒间隔")
    var noEnd = base
    noEnd.timestamps?.end = nil
    expectEqual(DiscordPresenceGate.sameContent(base, noEnd), false, "Discord 节流: 时长出现了算变了")
    expectEqual(DiscordPresenceGate.sameContent(nil, nil), true, "Discord 节流: 两个清空算一样")
}

// MARK: - 假 Discord

/// 一个临时 Unix 套接字上的假 Discord:握手回 READY(或关闭帧),SET_ACTIVITY 回执(可指定下一条回错误),收到的东西记成一行行文字。
/// 一次只服务一条连接,在后台线程上。
private final class FakeDiscord: @unchecked Sendable {
    enum Handshake {
        case accept(user: String)
        case reject(code: Int, message: String)
    }

    let directory: URL
    let path: String
    private let lock = NSLock()
    private let listenFD: Int32
    private var clientFD: Int32 = -1
    private var stopped = false
    private var handshake: Handshake
    private var failNext: (code: Int, message: String)?
    private var failRemaining = 0
    private var lines: [String] = []
    private var keySets: [[String]] = []

    init?(handshake: Handshake) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ldc-\(getpid())-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("discord-ipc-0").path
        self.handshake = handshake
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard listenFD >= 0, bound == 0, listen(listenFD, 4) == 0 else { return nil }
        Thread { [self] in run() }.start()
    }

    var records: [String] { lock.withLock { lines } }

    /// 收到的每份 activity 带了哪些字段(排好序),看补发的那份去没去掉链接和图片。
    var activityKeys: [[String]] { lock.withLock { keySets } }

    /// 接下来 `times` 条命令都回错误。
    func failNextCommand(code: Int, message: String, times: Int = 1) {
        lock.withLock {
            failNext = (code, message)
            failRemaining = times
        }
    }

    /// 主动发一个心跳。
    func ping() {
        guard let fd = lock.withLock({ clientFD >= 0 ? clientFD : nil }) else { return }
        write(DiscordIPC.encode(.ping, Data("{\"t\":1}".utf8)), to: fd)
    }

    /// 断开当前连接(Discord 退出时客户端看到的样子)。返回时对方再读就是 EOF。
    func dropClient() {
        lock.withLock {
            if clientFD >= 0 { shutdown(clientFD, SHUT_RDWR) }
        }
    }

    /// 停掉并删掉套接字文件,之后连不上。
    func stop() {
        lock.withLock {
            stopped = true
            if clientFD >= 0 { shutdown(clientFD, SHUT_RDWR) }
        }
        unlink(path)
        try? FileManager.default.removeItem(at: directory)
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func run() {
        while !isStopped {
            var request = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&request, 1, 20) > 0 else { continue }
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            lock.withLock { clientFD = fd }
            serve(fd)
            lock.withLock { clientFD = -1 }
            Darwin.close(fd)
        }
        Darwin.close(listenFD)
    }

    private func serve(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !isStopped {
            while let frame = try? DiscordIPC.takeFrame(from: &buffer) {
                guard respond(to: frame, on: fd) else { return }
            }
            var request = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&request, 1, 20) > 0 else { continue }
            let count = Darwin.read(fd, &chunk, chunk.count)
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    /// 回一帧;false = 这条连接到此为止。
    private func respond(to frame: DiscordIPC.Frame, on fd: Int32) -> Bool {
        let object = ((try? JSONSerialization.jsonObject(with: frame.payload)) as? [String: Any]) ?? [:]
        switch DiscordIPC.Opcode(rawValue: frame.opcode) {
        case .handshake:
            record("handshake client_id=\(object["client_id"] ?? "") v=\(object["v"] ?? "")")
            switch lock.withLock({ handshake }) {
            case .accept(let user):
                send(.frame, ["cmd": "DISPATCH", "evt": "READY", "data": ["v": 1, "user": ["id": "1", "username": user]]], on: fd)
                return true
            case .reject(let code, let message):
                send(.close, ["code": code, "message": message], on: fd)
                return false
            }
        case .frame:
            let args = object["args"] as? [String: Any] ?? [:]
            let nonce = object["nonce"] as? String ?? ""
            if let activity = args["activity"] as? [String: Any] {
                record("set pid=\(args["pid"] ?? "") details=\(activity["details"] ?? "")")
                lock.withLock { keySets.append(activity.keys.sorted()) }
            } else {
                record("clear pid=\(args["pid"] ?? "")")
            }
            let failure = lock.withLock { () -> (code: Int, message: String)? in
                guard failRemaining > 0, let failNext else { return nil }
                failRemaining -= 1
                if failRemaining == 0 { self.failNext = nil }
                return failNext
            }
            if let failure {
                send(.frame, ["cmd": "SET_ACTIVITY", "evt": "ERROR", "nonce": nonce,
                              "data": ["code": failure.code, "message": failure.message]], on: fd)
            } else {
                send(.frame, ["cmd": "SET_ACTIVITY", "evt": NSNull(), "nonce": nonce, "data": [String: Any]()], on: fd)
            }
            return true
        case .pong:
            record("pong")
            return true
        default:
            return true
        }
    }

    private func record(_ line: String) {
        lock.withLock { lines.append(line) }
    }

    private func send(_ opcode: DiscordIPC.Opcode, _ object: [String: Any], on fd: Int32) {
        guard let payload = try? JSONSerialization.data(withJSONObject: object) else { return }
        write(DiscordIPC.encode(opcode, payload), to: fd)
    }

    private func write(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
    }
}

/// 等到条件成立,最多 `timeout` 秒。只用来等对面线程已经发生的事(比如收到 pong),不用来证明某件事没发生。
private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        usleep(2_000)
    }
    return true
}

private final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

private func checkDiscordConnection() {
    let timeout: TimeInterval = 2
    guard let server = FakeDiscord(handshake: .accept(user: "tester")) else {
        expectEqual(false, true, "Discord 连接: 假 Discord 起得来")
        return
    }
    defer { server.stop() }
    let missing = server.directory.appendingPathComponent("discord-ipc-1").path
    let activity = DiscordPresence.activity(sampleTrack(position: nil), statusLine: .title, now: nil)

    // ---- 连接 ----
    do {
        let connection = try DiscordIPCConnection.connect(paths: [missing, server.path], clientID: "123", timeout: timeout)
        expectEqual(connection.path, server.path, "Discord 连接: 不在的套接字跳过,连下一个")
        expectEqual(connection.user?.username, "tester", "Discord 连接: 握手拿到账号")
        expectEqual(server.records.first, "handshake client_id=123 v=1", "Discord 连接: 握手带应用 ID 和版本")
        try connection.setActivity(activity, pid: 42, timeout: timeout)
        expectEqual(server.records.last, "set pid=42 details=晴天", "Discord 连接: SET_ACTIVITY 带 pid 和 activity")
        server.failNextCommand(code: 4002, message: "bad activity")
        do {
            try connection.setActivity(activity, pid: 42, timeout: timeout)
            expectEqual(false, true, "Discord 连接: 被拒的命令抛错")
        } catch {
            expectEqual(error as? DiscordIPCConnection.Failure, .rejected(code: 4002, message: "bad activity"),
                        "Discord 连接: 被拒的命令带代码和原因")
        }
        try connection.setActivity(nil, pid: 42, timeout: timeout)
        expectEqual(server.records.last, "clear pid=42", "Discord 连接: 命令被拒之后连接还能用,清空不带 activity")
        server.ping()
        try connection.service()
        expectEqual(waitUntil { server.records.last == "pong" }, true, "Discord 连接: 收到心跳回 pong")
        server.dropClient()
        do {
            try connection.service()
            expectEqual(false, true, "Discord 连接: 对面断开后发现得了")
        } catch {
            if case .disconnected = error as? DiscordIPCConnection.Failure {
                expectEqual(true, true, "Discord 连接: 对面断开报 disconnected")
            } else {
                expectEqual("\(error)", "disconnected", "Discord 连接: 对面断开报 disconnected")
            }
        }
    } catch {
        expectEqual("\(error)", "", "Discord 连接: 握手与发送不出错")
    }
    do {
        _ = try DiscordIPCConnection.connect(paths: [missing], clientID: "123", timeout: timeout)
        expectEqual(false, true, "Discord 连接: 没有套接字时连不上")
    } catch {
        expectEqual(error as? DiscordIPCConnection.Failure, .unavailable, "Discord 连接: 没有套接字报 unavailable")
    }
    if let refusing = FakeDiscord(handshake: .reject(code: 4000, message: "Invalid Client ID")) {
        do {
            _ = try DiscordIPCConnection.connect(paths: [refusing.path], clientID: "0", timeout: timeout)
            expectEqual(false, true, "Discord 连接: 握手被拒时抛错")
        } catch {
            expectEqual(error as? DiscordIPCConnection.Failure, .rejected(code: 4000, message: "Invalid Client ID"),
                        "Discord 连接: 握手被拒带代码和原因")
        }
        refusing.stop()
    }
    if let refusing = FakeDiscord(handshake: .reject(code: 4000, message: "Invalid Client ID")),
       let second = FakeDiscord(handshake: .accept(user: "second")) {
        do {
            let fallback = try DiscordIPCConnection.connect(paths: [refusing.path, second.path], clientID: "123", timeout: timeout)
            expectEqual(fallback.path, second.path, "Discord 连接: 前一个号握手被拒,接着连下一个")
            expectEqual(fallback.user?.username, "second", "Discord 连接: 连上的是后一个号的账号")
            fallback.close()
        } catch {
            expectEqual("\(error)", "", "Discord 连接: 前一个号握手被拒,接着连下一个")
        }
        do {
            _ = try DiscordIPCConnection.connect(paths: [refusing.path, missing], clientID: "0", timeout: timeout)
            expectEqual(false, true, "Discord 连接: 能连上的号都握手被拒时抛错")
        } catch {
            expectEqual(error as? DiscordIPCConnection.Failure, .rejected(code: 4000, message: "Invalid Client ID"),
                        "Discord 连接: 能连上的号都握手被拒时报被拒")
        }
        refusing.stop()
        second.stop()
    }

    // ---- 后台连接:按需连接、断了重连 ----
    let statuses = Recorder<DiscordPresenceLink.Status>()
    let results = Recorder<Bool>()
    let candidatePaths = [missing, server.path]
    let link = DiscordPresenceLink(socketPaths: { candidatePaths }, timeout: timeout, onStatus: { statuses.append($0) })
    var trackA = sampleTrack(position: nil)
    trackA.applicationID = "123"
    let activityA = DiscordPresence.activity(trackA, statusLine: .title, now: nil)
    var trackB = trackA
    trackB.applicationID = "456"
    let activityB = DiscordPresence.activity(trackB, statusLine: .title, now: nil)
    link.send(nil) { results.append($0 != .lost) }
    link.waitUntilIdle()
    expectEqual(statuses.all, [], "Discord 后台连接: 没连着时清空不去连")
    link.connectIfNeeded(clientID: "123")
    link.waitUntilIdle()
    expectEqual(statuses.all, [.connected(user: DiscordUser(id: "1", username: "tester"))], "Discord 后台连接: 先连上、不发东西")
    expectEqual(server.records.last, "handshake client_id=123 v=1", "Discord 后台连接: 只握手")
    link.connectIfNeeded(clientID: "123")
    link.send(activityA) { results.append($0 != .lost) }
    link.waitUntilIdle()
    expectEqual(statuses.all, [.connected(user: DiscordUser(id: "1", username: "tester"))], "Discord 后台连接: 连着时不重连")
    let pid = ProcessInfo.processInfo.processIdentifier
    link.send(activityB) { results.append($0 != .lost) }
    link.waitUntilIdle()
    expectEqual(Array(server.records.suffix(2)), ["handshake client_id=456 v=1", "set pid=\(pid) details=晴天"],
                "Discord 后台连接: 换了播放器就换那个应用重连再发")
    expectEqual(statuses.all, [.connected(user: DiscordUser(id: "1", username: "tester"))], "Discord 后台连接: 换应用不报断开")
    expectEqual(server.records.last, "set pid=\(ProcessInfo.processInfo.processIdentifier) details=晴天",
                "Discord 后台连接: 发的是本进程的 pid")
    server.dropClient()
    link.check()
    link.waitUntilIdle()
    expectEqual(statuses.all.last, .disconnected, "Discord 后台连接: 定时检查发现断开")
    link.send(activity) { results.append($0 != .lost) }
    link.waitUntilIdle()
    expectEqual(statuses.all.last, .connected(user: DiscordUser(id: "1", username: "tester")), "Discord 后台连接: 下一份重连后发出")
    server.dropClient()
    link.send(activity) { results.append($0 != .lost) }
    link.waitUntilIdle()
    expectEqual(server.records.last, "set pid=\(ProcessInfo.processInfo.processIdentifier) details=晴天",
                "Discord 后台连接: 发送时才发现断了,当场重连再发")
    server.stop()
    link.check()
    link.send(activity) { results.append($0 != .lost) }
    link.waitUntilIdle()
    expectEqual(statuses.all.last, .disconnected, "Discord 后台连接: Discord 退出后报没连上")
    expectEqual(results.all, [true, true, true, true, true, false], "Discord 后台连接: 每份的结果,连不上时 false")
    link.disconnect(clearing: true)
    link.waitUntilIdle()

    // ---- 后台连接:Discord 拒收某一份,去掉链接和图片补发一次 ----
    guard let picky = FakeDiscord(handshake: .accept(user: "tester")) else { return }
    defer { picky.stop() }
    let pickyResults = Recorder<DiscordPresenceLink.Delivery>()
    let pickyStatuses = Recorder<DiscordPresenceLink.Status>()
    let pickyLink = DiscordPresenceLink(socketPaths: { [picky.path] }, timeout: timeout, onStatus: { pickyStatuses.append($0) })
    let rich = DiscordPresence.activity(sampleTrack(position: nil), statusLine: .title, now: nil, smallImage: .lyrimuse)
    picky.failNextCommand(code: 4002, message: "invalid asset")
    pickyLink.send(rich) { pickyResults.append($0) }
    pickyLink.waitUntilIdle()
    let sent = picky.activityKeys
    expectEqual(sent.count, 2, "Discord 后台连接: 被拒之后补发一次")
    expectEqual(sent.first.map { $0.contains("assets") && $0.contains("details_url") && $0.contains("state_url") }, true,
                "Discord 后台连接: 先发的那份带链接和图片")
    expectEqual(sent.last.map { !$0.contains("assets") && !$0.contains("details_url") && !$0.contains("state_url") }, true,
                "Discord 后台连接: 补发的精简版去掉链接和图片")
    expectEqual(sent.last.map { $0.contains("details") && $0.contains("state") }, true, "Discord 后台连接: 精简版留着歌名、歌手")
    picky.failNextCommand(code: 4002, message: "invalid", times: 2)
    pickyLink.send(rich) { pickyResults.append($0) }
    pickyLink.waitUntilIdle()
    expectEqual(picky.activityKeys.count, 4, "Discord 后台连接: 精简版也被拒就不再补发")
    expectEqual(picky.records.last, "clear pid=\(pid)", "Discord 后台连接: 精简版也被拒就补发清空,不让 Discord 挂着上一首")
    let plain = DiscordPresence.withoutLinksAndImages(rich)
    picky.failNextCommand(code: 4002, message: "invalid")
    pickyLink.send(plain) { pickyResults.append($0) }
    pickyLink.waitUntilIdle()
    expectEqual(picky.activityKeys.count, 5, "Discord 后台连接: 本来就没有链接和图片的,被拒了不补发精简版")
    expectEqual(picky.records.last, "clear pid=\(pid)", "Discord 后台连接: 本来就没有链接和图片的,被拒了直接补发清空")
    expectEqual(pickyResults.all, [.shown(plain), .shown(nil), .shown(nil)],
                "Discord 后台连接: 回报 Discord 实际显示的那份(精简版 / 清空),被拒不算断线、不让调用方重交")
    expectEqual(pickyStatuses.all, [.connected(user: DiscordUser(id: "1", username: "tester"))],
                "Discord 后台连接: 被拒之后连接照旧")
    pickyLink.disconnect(clearing: false)
    pickyLink.waitUntilIdle()
}

private func checkDiscordCover() {
    // ---- 中继上的本机封面 ----
    let file = URL(fileURLWithPath: "/Users/x/.config/lyrimuse/artwork/0ee35579d4f15def.jpg")
    expectEqual(RelayArtwork.publicURL(relayBase: "https://np.example.com", coverURL: file)?.absoluteString,
                "https://np.example.com/artwork/0ee35579d4f15def.jpg", "Discord 封面: 本机封面换成中继上的地址")
    expectEqual(RelayArtwork.publicURL(relayBase: " https://np.example.com/ ", coverURL: file)?.absoluteString,
                "https://np.example.com/artwork/0ee35579d4f15def.jpg", "Discord 封面: 中继地址首尾空白、末尾斜杠去掉")
    expectEqual(RelayArtwork.publicURL(relayBase: "", coverURL: file), nil, "Discord 封面: 没配中继就没有这一档")
    expectEqual(RelayArtwork.publicURL(relayBase: "http://np.example.com", coverURL: file), nil, "Discord 封面: 中继不是 https 不用")
    expectEqual(RelayArtwork.publicURL(relayBase: "https://np.example.com", coverURL: URL(fileURLWithPath: "/Users/x/Music/0ee35579d4f15def.jpg")),
                nil, "Discord 封面: 不在 artwork 文件夹里的本机文件不认")
    expectEqual(RelayArtwork.publicURL(relayBase: "https://np.example.com", coverURL: URL(fileURLWithPath: "/x/artwork/0EE35579D4F15DEF.jpg")),
                nil, "Discord 封面: 文件名必须是 16 位小写十六进制")
    expectEqual(RelayArtwork.publicURL(relayBase: "https://np.example.com", coverURL: URL(fileURLWithPath: "/x/artwork/0ee35579d4f15def.gif")),
                nil, "Discord 封面: 只认 jpg / png")
    expectEqual(RelayArtwork.publicURL(relayBase: "https://np.example.com", coverURL: URL(string: "https://p1.music.126.net/a.jpg")),
                nil, "Discord 封面: 本来就是公网地址的不经中继")

    // ---- 分档 ----
    typealias C = PresenceCover
    let own = URL(string: "https://i.scdn.co/image/own")!
    let local = URL(string: "https://p1.music.126.net/local.jpg")!
    let relayHit = C.Hit(url: URL(string: "https://np.example.com/artwork/0ee35579d4f15def.jpg")!, tier: .relay)
    let trackHit = C.Hit(url: URL(string: "https://is1-ssl.mzstatic.com/track/600x600bb.jpg")!, tier: .appleTrack)
    let albumHit = C.Hit(url: URL(string: "https://is1-ssl.mzstatic.com/album/600x600bb.jpg")!, tier: .appleAlbum)
    let searchHit = C.Hit(url: URL(string: "https://is1-ssl.mzstatic.com/search/600x600bb.jpg")!, tier: .search)
    expectEqual(C.pick(own: own, hit: relayHit, local: local), own, "Discord 封面: 播放器自己给的排第一")
    expectEqual(C.pick(own: nil, hit: relayHit, local: local), relayHit.url, "Discord 封面: 中继上的本机封面排在别的来源前面")
    expectEqual(C.pick(own: nil, hit: trackHit, local: local), trackHit.url, "Discord 封面: 按曲目 ID 查到的排在别的来源前面")
    expectEqual(C.pick(own: nil, hit: albumHit, local: local), local, "Discord 封面: 按专辑 ID 查到的排在别的来源后面")
    expectEqual(C.pick(own: nil, hit: searchHit, local: local), local, "Discord 封面: 按歌名搜到的排在别的来源后面")
    expectEqual(C.pick(own: nil, hit: searchHit, local: nil), searchHit.url, "Discord 封面: 别的都没有才用搜到的")
    expectEqual(C.pick(own: nil, hit: nil, local: nil), nil, "Discord 封面: 都没有交给应用里上传的图")
    expectEqual(C.trackStorefronts(region: "CN"), ["cn", "us"], "Discord 封面: 按曲目 ID 先问系统地区的店面、再问美区")
    expectEqual(C.trackStorefronts(region: "US"), ["us"], "Discord 封面: 店面不重复问")
    expectEqual(C.trackStorefronts(region: nil), ["us"], "Discord 封面: 没有地区码问美区")
    let nothing = C.Request(relayURL: nil, appleTrackID: nil, trackStorefronts: [], albumRef: nil, albumStorefronts: [],
                            artist: "a", title: "t", album: "", searchStorefront: "us", wantsFallback: false)
    expectEqual(nothing.isEmpty, true, "Discord 封面: 没有一样能查的不发起")
    var trackOnly = nothing
    trackOnly.appleTrackID = 1633408818
    expectEqual(trackOnly.isEmpty, false, "Discord 封面: 有曲目 ID 就查")

    // ---- lookUp 分得清「没问成」:iTunes 冷却中时各档当场没问成(不发请求),报 unreached ----
    let cooling = ITunesSearchGate(store: nil)
    cooling.note(status: 429, retryAfter: "120", now: Date())
    func blockedLookUp(_ request: C.Request) -> (hit: C.Hit?, relayMissing: Bool, unreached: Bool) {
        final class Box: @unchecked Sendable { var result: (hit: C.Hit?, relayMissing: Bool, unreached: Bool) = (nil, false, false) }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            box.result = await C.lookUp(request, gate: cooling)
            sem.signal()
        }
        sem.wait()
        return box.result
    }
    var viaTrack = trackOnly
    viaTrack.trackStorefronts = ["us"]
    let trackResult = blockedLookUp(viaTrack)
    expectEqual(trackResult.hit == nil && trackResult.unreached, true, "Discord 封面(补查): 曲目 ID 那档没问成报 unreached")
    var viaAlbum = nothing
    viaAlbum.albumRef = AlbumEditorialNotes.AlbumRef(id: 1633408719, storefront: "us")
    viaAlbum.albumStorefronts = ["us"]
    viaAlbum.album = "地表最强"
    viaAlbum.wantsFallback = true
    expectEqual(blockedLookUp(viaAlbum).unreached, true, "Discord 封面(补查): 专辑 ID 那档没问成报 unreached")
    var viaSearch = nothing
    viaSearch.wantsFallback = true
    expectEqual(blockedLookUp(viaSearch).unreached, true, "Discord 封面(补查): 按歌名搜那档没问成报 unreached")
    expectEqual(blockedLookUp(nothing).unreached, false, "Discord 封面(补查): 没有要联网的档不算没问成")

    // ---- YouTube Music 网页版页面上的专辑图(浏览器探针第三段) ----
    typealias P = BrowserPositionProbe
    let ytm = P.parseReading(fromOsascriptOutput:
        "57|0|https://lh3.googleusercontent.com/abc=w544-h544-l90-rj|@57.1,1790000000000|#e-ORhEE9VVg,MUSIC_VIDEO_TYPE_ATV")
    expectEqual(ytm?.artworkURL?.absoluteString, "https://lh3.googleusercontent.com/abc=w1200-h1200-l90-rj",
                "Discord 封面: YouTube Music 网页版的专辑图换成 1200 档")
    expectEqual(ytm?.video?.videoID, "e-ORhEE9VVg", "Discord 封面: 第三段带了专辑图,后面两段照旧解")
    expectEqual(P.parseReading(fromOsascriptOutput: "57|0|https://i.ytimg.com/vi/e-ORhEE9VVg/sddefault.jpg||")?.artworkURL, nil,
                "Discord 封面: MV 的视频截图不当封面")

    // ---- 放的是视频:没有专辑图时用这支视频的截图兜底(Kaset、YouTube Music 网页版) ----
    typealias K = KasetPlayerInfo
    let shot = "https://i.ytimg.com/vi/aGsrg1NO1cM/hqdefault.jpg?sqp=-oaymwEWCJADEOEBIAQqCggAEOADGC0guwJIWg&rs=AMzJL3k6"
    expectEqual(K.videoFrameURL(videoID: "aGsrg1NO1cM", reportedArtwork: shot)?.absoluteString, shot,
                "Discord 封面(视频): 报来的就是这支视频的截图,照用")
    expectEqual(K.videoFrameURL(videoID: "aGsrg1NO1cM", reportedArtwork: "https://i.ytimg.com/vi/ZLldhJXp7iw/hq720.jpg")?.absoluteString,
                "https://i.ytimg.com/vi/aGsrg1NO1cM/hqdefault.jpg", "Discord 封面(视频): 上一首的截图不用,按 videoId 拼")
    expectEqual(K.videoFrameURL(videoID: "aGsrg1NO1cM", reportedArtwork: nil)?.absoluteString,
                "https://i.ytimg.com/vi/aGsrg1NO1cM/hqdefault.jpg", "Discord 封面(视频): 没报截图按 videoId 拼")
    expectEqual(K.videoFrameURL(videoID: "aGsrg1NO1cM", reportedArtwork: "http://i.ytimg.com/vi/aGsrg1NO1cM/hqdefault.jpg")?.absoluteString,
                "https://i.ytimg.com/vi/aGsrg1NO1cM/hqdefault.jpg", "Discord 封面(视频): 不是 https 的不照用")
    expectEqual(K.videoFrameURL(videoID: "aGsrg1NO1c", reportedArtwork: shot), nil, "Discord 封面(视频): videoId 不是 11 位不给")
    expectEqual(K.videoFrameURL(videoID: nil, reportedArtwork: shot), nil, "Discord 封面(视频): 没有 videoId 不给")
    let mv = P.parseReading(fromOsascriptOutput:
        "57|0|https://i.ytimg.com/vi/e-ORhEE9VVg/sddefault.jpg|@57.1,1790000000000|#e-ORhEE9VVg,MUSIC_VIDEO_TYPE_OMV")
    expectEqual(mv?.artworkURL, nil, "Discord 封面(视频): 网页版放 MV,截图仍不当封面")
    expectEqual(mv?.videoFrameURL?.absoluteString, "https://i.ytimg.com/vi/e-ORhEE9VVg/sddefault.jpg",
                "Discord 封面(视频): 网页版放 MV,截图留给 Discord 兜底")
    expectEqual(ytm?.videoFrameURL, nil, "Discord 封面(视频): 有专辑图就不另给截图")
    expectEqual(P.parseReading(fromOsascriptOutput: "57|0|https://i.ytimg.com/vi/e-ORhEE9VVg/sddefault.jpg||")?.videoFrameURL, nil,
                "Discord 封面(视频): 认不出视频身份不给截图")
    let frame = URL(string: "https://i.ytimg.com/vi/e-ORhEE9VVg/hq720.jpg")!
    expectEqual(C.pick(own: nil, hit: nil, local: nil, videoFrame: frame), frame, "Discord 封面(视频): 别的都没有时用视频截图")
    expectEqual(C.pick(own: nil, hit: nil, local: local, videoFrame: frame), local, "Discord 封面(视频): 有专辑图就不用截图")
    expectEqual(C.pick(own: nil, hit: searchHit, local: nil, videoFrame: frame), searchHit.url,
                "Discord 封面(视频): 按歌名搜到的专辑图排在截图前面")
    expectEqual(C.pick(own: own, hit: nil, local: nil, videoFrame: frame), own, "Discord 封面(视频): 播放器自己给的排在截图前面")

    // ---- 第 5 档的专辑核对:按专辑 ID 取到的得是正在放的那张,按歌名搜时同一把尺子 ----
    expectEqual(C.sameAlbum("petal [Clean]", "petal"), true, "Discord 封面(专辑): Clean / Explicit 不算另一张")
    expectEqual(C.sameAlbum("The Great Divide: The Last Of The Bugs [Explicit]", "The Great Divide: The Last Of The Bugs"), true,
                "Discord 封面(专辑): 末尾的 [Explicit] 不算另一张")
    expectEqual(C.sameAlbum("Choosin' Texas", "Choosin' Texas - Single"), true, "Discord 封面(专辑): Apple 加的 - Single 不算另一张")
    expectEqual(C.sameAlbum("HIStory: PAST, PRESENT AND FUTURE, BOOK I", "HIStory - PAST, PRESENT AND FUTURE - BOOK I"), true,
                "Discord 封面(专辑): 标点写法不一不算另一张")
    expectEqual(C.sameAlbum("聖誕之吻", "圣诞之吻 - Single"), true, "Discord 封面(专辑): 繁简、- Single 都不算")
    expectEqual(C.sameAlbum("The Life of a Showgirl: The Encore [Explicit]", "The Life of a Showgirl"), false,
                "Discord 封面(专辑): The Encore 是另一张发行")
    expectEqual(C.sameAlbum("XSCAPE", "XSCAPE (Deluxe)"), false, "Discord 封面(专辑): 豪华版算另一张")
    expectEqual(C.sameAlbum("", ""), false, "Discord 封面(专辑): 两边都空不算对得上")
    expectEqual(C.anchoredAlbumMatches(playing: "The Life of a Showgirl: The Encore [Explicit]", catalog: "The Life of a Showgirl"), false,
                "Discord 封面(专辑): 链接锚到标准版,放的是 The Encore,当没找到")
    expectEqual(C.anchoredAlbumMatches(playing: "大灌篮 电影原声带", catalog: "周杰伦2007世界巡回演唱会"), false,
                "Discord 封面(专辑): 链接锚到另一张专辑,当没找到")
    expectEqual(C.anchoredAlbumMatches(playing: "乐之路", catalog: "Live Again: 陶喆 小人物狂想曲 (现场专辑)"), false,
                "Discord 封面(专辑): 两边都带中文就照常比")
    expectEqual(C.anchoredAlbumMatches(playing: "Timeless", catalog: "可啦思刻"), true,
                "Discord 封面(专辑): 一边英文名、一边中文名比不了,信链接")
    expectEqual(C.anchoredAlbumMatches(playing: "再見你好嗎 Hello Goodbye", catalog: "再见你好吗"), true,
                "Discord 封面(专辑): 中英双语名对得上中文名")
    expectEqual(C.anchoredAlbumMatches(playing: "petal [Explicit]", catalog: "petal"), true, "Discord 封面(专辑): 写法差异照样认")
    expectEqual(C.anchoredAlbumMatches(playing: "", catalog: "The Life of a Showgirl"), true, "Discord 封面(专辑): 没报专辑比不了,信链接")
    expectEqual(C.anchoredAlbumMatches(playing: "Timeless", catalog: nil), false, "Discord 封面(专辑): 目录没给专辑名不认")
    typealias M = MusicCatalogSearch
    func song(_ album: String, _ art: String) -> M.Item {
        M.Item(trackName: "Wood", artistName: "Taylor Swift", collectionName: album,
               trackViewUrl: nil, artistViewUrl: nil, collectionViewUrl: nil, artworkUrl100: art)
    }
    let editions = [song("The Life of a Showgirl", "https://is1-ssl.mzstatic.com/std/100x100bb.jpg"),
                    song("The Life of a Showgirl: The Encore", "https://is1-ssl.mzstatic.com/encore/100x100bb.jpg")]
    let encore = M.pickArtwork(editions, title: "Wood", artist: "Taylor Swift",
                               album: "The Life of a Showgirl: The Encore [Explicit]", albumMatches: C.sameAlbum)
    expectEqual(encore?.url.absoluteString, "https://is1-ssl.mzstatic.com/encore/600x600bb.jpg",
                "Discord 封面(专辑): 按歌名搜时挑对得上的那一版")
    expectEqual(encore?.confidence == .albumMatch, true, "Discord 封面(专辑): 写法差异不影响算专辑对得上")
    expectEqual(M.pickArtwork(editions, title: "Wood", artist: "Taylor Swift",
                              album: "The Life of a Showgirl: The Encore [Explicit]")?.confidence == .trackOnly, true,
                "Discord 封面(专辑): 不传尺子时照旧逐字比(最近记录那条不受影响)")

    // ---- 联网那几档没问成:到点再查 ----
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    expectEqual(C.retryAt(attempt: 0, now: t0, cooldownEnds: nil), t0.addingTimeInterval(20), "Discord 封面(补查): 第一次隔 20 秒")
    expectEqual(C.retryAt(attempt: 2, now: t0, cooldownEnds: nil), t0.addingTimeInterval(80), "Discord 封面(补查): 每轮翻倍")
    expectEqual(C.retryAt(attempt: 9, now: t0, cooldownEnds: nil), t0.addingTimeInterval(300), "Discord 封面(补查): 最长 5 分钟")
    expectEqual(C.retryAt(attempt: -1, now: t0, cooldownEnds: nil), t0.addingTimeInterval(20), "Discord 封面(补查): 负数当第一轮")
    expectEqual(C.retryAt(attempt: 0, now: t0, cooldownEnds: t0.addingTimeInterval(90)), t0.addingTimeInterval(90),
                "Discord 封面(补查): iTunes 还在冷却就等冷却结束")
    expectEqual(C.retryAt(attempt: 0, now: t0, cooldownEnds: t0.addingTimeInterval(5)), t0.addingTimeInterval(20),
                "Discord 封面(补查): 冷却先结束就按间隔")
    let gate = ITunesSearchGate(store: nil)
    expectEqual(gate.cooldownEnds(now: t0), nil, "Discord 封面(补查): 没在冷却")
    gate.note(status: 403, retryAfter: nil, now: t0)
    expectEqual(gate.cooldownEnds(now: t0), t0.addingTimeInterval(30), "Discord 封面(补查): 403 冷却 30 秒,报出结束时刻")
    expectEqual(gate.cooldownEnds(now: t0.addingTimeInterval(31)), nil, "Discord 封面(补查): 冷却过了为 nil")
    let full = DiscordPresence.activity(sampleTrack(), statusLine: .title, now: t0, smallImage: .lyrimuse)
    let stripped = DiscordPresence.withoutLinksAndImages(full)
    expectEqual(stripped.assets == nil && stripped.detailsURL == nil && stripped.stateURL == nil, true,
                "Discord 精简版: 去掉链接和大图小图")
    expectEqual(stripped.details == full.details && stripped.state == full.state && stripped.timestamps == full.timestamps
                && stripped.name == full.name, true, "Discord 精简版: 文字和时间照旧")

    // ---- 设备封面在网上的同一张图:记下时核对的那张设备封面还是现在的封面才作数 ----
    func entry(_ json: String) -> EnrichCacheEntry? { try? JSONDecoder().decode(EnrichCacheEntry.self, from: Data(json.utf8)) }
    let device = "file:///x/.config/lyrimuse/artwork/0ee35579d4f15def.jpg"
    let pinned = entry(#"{"cover_url":"\#(device)","cover_source":"device","public_cover_url":"https://p1.music.126.net/a.jpg","public_cover_for":"\#(device)"}"#)
    expectEqual(pinned.flatMap(EnrichCacheReader.validPublicCover)?.absoluteString, "https://p1.music.126.net/a.jpg",
                "Discord 封面(公网同图): 核对的就是现在这张设备封面,作数")
    let moved = entry(#"{"cover_url":"file:///x/.config/lyrimuse/artwork/1111111111111111.jpg","public_cover_url":"https://p1.music.126.net/a.jpg","public_cover_for":"\#(device)"}"#)
    expectEqual(moved.flatMap(EnrichCacheReader.validPublicCover), nil, "Discord 封面(公网同图): 封面换过了,旧记录不作数")
    let plain = entry(#"{"cover_url":"\#(device)","public_cover_url":"http://p1.music.126.net/a.jpg","public_cover_for":"\#(device)"}"#)
    expectEqual(plain.flatMap(EnrichCacheReader.validPublicCover), nil, "Discord 封面(公网同图): 不是 https 的不用")
    let unpinned = entry(#"{"cover_url":"\#(device)","public_cover_url":"https://p1.music.126.net/a.jpg"}"#)
    expectEqual(unpinned.flatMap(EnrichCacheReader.validPublicCover), nil, "Discord 封面(公网同图): 没记核对的是哪张不用")
}

private func checkDiscordWiring() {
    let sourcesRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    func code(_ path: String) -> String {
        (try? String(contentsOfFile: sourcesRoot.appendingPathComponent(path).path, encoding: .utf8)) ?? ""
    }
    expectEqual(sourceBytes(code("lyrimuse/AppDelegate.swift"), contain: "DiscordPresenceController.shared.start()"), true,
                "Discord(接线): App 启动时开始盯")
    let controller = code("lyrimuse/Settings/DiscordPresenceController.swift")
    for needle in ["signal(playback.$title)", "signal(playback.$anchor)", "signal(playback.$isPlayingSmoothed)",
                   "signal(source.$webPageArtworkURL)", "signal(ConfigStore.shared.$stateRelayURL)",
                   "signal(playback.$isCurrentTrackAdBreak)", "signal(playback.$isRadioTalkBreak)",
                   "signal(settings.$discordPresenceEnabled)", "signal(settings.$discordStatusDisplay)",
                   "signal(settings.$discordKeepWhenPaused)", "signal(settings.$discordExcludedBundles)",
                   "signal(settings.$discordBadge)", "badge: settings.discordBadge", "hiddenUntil: hiddenUntil",
                   "links?.artistWebLink(forPlayerBundleID: reportedBundleID", "hit?.artistPage",
                   "signal(source.$webPageVideoFrameURL)", "source.kasetVideoFrameURL ?? source.webPageVideoFrameURL",
                   "videoFrame: extras.videoFrame", "EnrichCacheReader.publicCoverURL(artist: source.artist"] {
        expectEqual(sourceBytes(controller, contain: needle), true, "Discord(接线): 控制器盯着 \(needle)")
    }
    for needle in ["if lookup.finished, lookup.hit == nil, let retryAt = lookup.retryAt, now >= retryAt {",
                   "attempt: lookup.attempt + 1", "ITunesSearchGate.shared.cooldownEnds()", "lookup.attempt == 0",
                   "        if track != nil {\n            scheduleCoverWake(now: now)",
                   "guard let at = due.filter({ $0 > now }).min() else { return }", "coverWakeTask = Task { [weak self] in"] {
        expectEqual(sourceBytes(controller, contain: needle), true, "Discord(接线): 没问成的封面到点再查 \(needle)")
    }
    for needle in ["Task { @MainActor in self?.sendFinished(delivery, wanted: activity, generation: sentGeneration) }",
                   "            delivered = (wanted, shown)",
                   "if let delivered, DiscordPresenceGate.sameContent(delivered.wanted, sent) { return delivered.shown }"] {
        expectEqual(sourceBytes(controller, contain: needle), true, "Discord(接线): 记下 Discord 实际显示的那份 \(needle)")
    }
    let preview = code("lyrimuse/Settings/DiscordPresencePreview.swift")
    for needle in ["discord.sentActivity", "now.timeIntervalSince($0) < DiscordPresence.pauseGrace", "CachedImage(url: url)",
                   "if live != nil, let shown = discord.shownOnDiscord(insteadOf: activity) {", "} else if live == nil || refused {"] {
        expectEqual(sourceBytes(preview, contain: needle), true, "Discord(接线): 预览照 Discord 实际显示的画 \(needle)")
    }
    let playbackSource = code("LyrimuseCore/Local/LocalPlaybackSource.swift")
    expectEqual(sourceBytes(playbackSource, contain: "BrowserPositionProbe.shared.setPageVideoFrameSink"), true,
                "Discord(接线): 网页版的视频截图接到播放源")
    expectEqual(playbackSource.components(separatedBy: "if webPageVideoFrameURL != nil { webPageVideoFrameURL = nil }").count - 1, 2,
                "Discord(接线): 网页版的视频截图停播、换歌时清掉")
    let presenceCover = code("LyrimuseCore/Integrations/PresenceCover.swift")
    expectEqual(sourceBytes(presenceCover, contain: "albumMatches: sameAlbum"), true, "Discord(接线): 按歌名搜时用同一把专辑尺子")
    expectEqual(sourceBytes(presenceCover,
                            contain: "case .found(let match) where anchoredAlbumMatches(playing: request.album, catalog: match.matchedAlbum)"),
                true, "Discord(接线): 按专辑 ID 取到的先核对专辑,对不上接着搜")
    expectEqual(sourceBytes(controller, contain: "link.disconnect(clearing: true)"), true, "Discord(接线): 关掉时清空并断开")
    expectEqual(sourceBytes(controller, contain: "discordExcludedBundles.contains(host)"), true,
                "Discord(接线): 排除的播放器按宿主 App 判")
}
