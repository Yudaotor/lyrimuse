import Darwin
import Foundation
import LyrimuseCore

// Discord「正在听」:帧编解码与消息、activity 组装、暂停宽限、节流去重,再起一个假 Discord(临时 Unix 套接字,
// 路径带 pid 和 UUID)走一遍握手 → 发状态 → 被拒 → 清空 → 心跳 → 断开重连,最后是接线契约。

func runDiscordPresenceTests() {
    do {
        // 刚从暂停恢复先等 resumeSettleSecs 再发(02 章决策 119)。
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        expectEqual(DiscordPresence.resumeSettleUntil(resumedAt: t0, now: t0.addingTimeInterval(0.3)),
                    t0.addingTimeInterval(DiscordPresence.resumeSettleSecs), "Discord 恢复播放: 0.3 秒时还在等")
        expectEqual(DiscordPresence.resumeSettleUntil(resumedAt: t0, now: t0.addingTimeInterval(DiscordPresence.resumeSettleSecs)) == nil,
                    true, "Discord 恢复播放: 到点就不等")
        expectEqual(DiscordPresence.resumeSettleUntil(resumedAt: nil, now: t0) == nil, true, "Discord 恢复播放: 没恢复过不等")
    }
    checkDiscordWire()
    checkDiscordActivity()
    checkDiscordSmallImage()
    checkDiscordPaused()
    checkDiscordArtistLinks()
    checkDiscordGate()
    checkDiscordConnection()
    checkDiscordCover()
    checkDiscordLyrics()
    checkDiscordButtons()
    checkDiscordLayout()
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
    expectEqual(reply(.frame, "{\"cmd\":\"DISPATCH\",\"evt\":\"READY\",\"data\":{\"user\":{\"id\":\"3\",\"username\":\"u\",\"avatar_decoration_data\":{\"asset\":\"a_fed43ab12698df65902ba06727e20c0e\",\"sku_id\":\"1144058844004233369\"}}}}"),
                .ready(user: DiscordUser(id: "3", username: "u", avatarDecoration: "a_fed43ab12698df65902ba06727e20c0e")),
                "Discord 回包: READY 带头像框")
    expectEqual(reply(.frame, "{\"cmd\":\"DISPATCH\",\"evt\":\"READY\",\"data\":{\"user\":{\"id\":\"3\",\"username\":\"u\",\"avatar_decoration_data\":null}}}"),
                .ready(user: DiscordUser(id: "3", username: "u")), "Discord 回包: 没戴头像框时 Discord 给 null")
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
    expectEqual(DiscordUser(id: "1", username: "u", avatarDecoration: "a_" + hash).avatarDecorationURL()?.absoluteString,
                "https://cdn.discordapp.com/avatar-decoration-presets/a_\(hash).png?size=160&passthrough=false",
                "Discord 账号: 头像框取静态的一帧")
    expectEqual(DiscordUser(id: "1", username: "u").avatarDecorationURL(), nil, "Discord 账号: 没戴头像框不给地址")
    expectEqual(DiscordUser(id: "1", username: "u", avatarDecoration: "../x").avatarDecorationURL(), nil,
                "Discord 账号: 头像框哈希格式不对当没有,不拼进地址")

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
    // 「正在收听」后面那一项(name)跟用户名下方那一行分开设。
    let nameTitle = DiscordPresence.activity(previewSample, statusLine: .artist, listeningName: .title, now: previewNow)
    expectEqual(nameTitle.name, nameTitle.details, "Discord: 正在收听后面写歌名")
    expectEqual(DiscordPresence.statusText(of: nameTitle), nameTitle.state, "Discord: 正在收听写歌名时,用户名下方照样能写歌手")
    let nameArtist = DiscordPresence.activity(previewSample, statusLine: .title, listeningName: .artist, now: previewNow)
    expectEqual(nameArtist.name, nameArtist.state, "Discord: 正在收听后面写歌手")
    expectEqual(DiscordPresence.activity(previewSample, statusLine: .title, now: previewNow).name, byTitle.name,
                "Discord: 不传 listeningName 时照旧写播放器")
    expectEqual(DiscordPresence.statusLines(for: .player, layout: .init()), [.title, .artist, .player],
                "Discord: 正在收听写播放器时用户名下方三档都在")
    expectEqual(DiscordPresence.statusLines(for: .title, layout: .init()), [.title, .artist],
                "Discord: 正在收听写歌名时用户名下方没有「播放器」")
    expectEqual(DiscordPresence.effectiveStatusLine(.player, listeningName: .artist, layout: .init()), .artist,
                "Discord: 存的「播放器」在正在收听写歌手时按歌手算")
    expectEqual(DiscordPresence.effectiveStatusLine(.player, listeningName: .player, layout: .init()), .player,
                "Discord: 切回播放器时恢复")
    let nameTitleAsPlayer = DiscordPresence.activity(previewSample, statusLine: .player, listeningName: .title, now: previewNow)
    expectEqual(nameTitleAsPlayer.statusDisplayType, DiscordPresence.StatusLine.title.displayType,
                "Discord: 存的「播放器」+ 正在收听写歌名 → 发出去按歌名那档")
    let pausedTitle = DiscordPresence.pausedActivity(previewSample, statusLine: .title, listeningName: .title,
                                                     now: previewNow, pausedNameFormat: "%@ (Paused)")
    expectEqual(pausedTitle.name, "\(nameTitle.details ?? "") (Paused)", "Discord: 暂停时正在收听后面的歌名也带暂停字样")
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
    expectEqual(DiscordPresence.activity(localCover, statusLine: .title, now: now).assets?.largeImage,
                DiscordPresence.iconURL(of: .lyrimuse), "Discord activity: 本地文件封面 Discord 拿不到,不当大图(第三行有字时补应用图标)")
    var plainHTTP = sampleTrack()
    plainHTTP.coverURL = URL(string: "http://example.com/a.jpg")
    expectEqual(DiscordPresence.activity(plainHTTP, statusLine: .title, now: now).assets?.largeImage,
                DiscordPresence.iconURL(of: .lyrimuse), "Discord activity: 封面只认 https")

    // ---- 每个播放器一个应用 ----
    typealias A = DiscordPresence.Application
    func app(_ player: PlaybackPlayer) -> A { DiscordPresence.application(forBundleID: player.bundleIdentifier, webPlatformID: nil) }
    expectEqual([app(.appleMusic), app(.kaset), app(.spotify), app(.qqMusic), app(.netease), app(.kugou), app(.soda),
                 app(.kkbox), app(.amazonMusic), app(.reamp), app(.lxMusic)],
                [.appleMusic, .youtubeMusic, .spotify, .qqMusic, .netease, .kugou, .soda, .kkbox, .amazonMusic, .reamp, .lxMusic],
                "Discord 应用: 内置播放器各归各的应用,Kaset 归 YouTube Music")
    expectEqual(DiscordPresence.application(forBundleID: "com.apple.WebKit.GPU", webPlatformID: "youtubeMusic"), .youtubeMusic,
                "Discord 应用: 浏览器里的 YouTube Music 归 YouTube Music")
    expectEqual(DiscordPresence.application(forBundleID: "com.google.Chrome", webPlatformID: "spotifyWeb"), .spotify,
                "Discord 应用: 网页版 Spotify 归 Spotify")
    expectEqual(DiscordPresence.application(forBundleID: "com.example.player", webPlatformID: nil), .lyrimuse,
                "Discord 应用: 认不出的播放器用 Lyrimuse 那个")
    expectEqual(DiscordPresence.applicationID(forBundleID: "com.example.player", webPlatformID: nil), DiscordPresence.applicationID,
                "Discord 应用: Lyrimuse 那个的 ID")
    // 还没在 Discord 开发者后台建应用的播放器(建应用要作者过人机验证),暂时用 Lyrimuse 那个;建好之后把 ID 补进
    // DiscordPresence 再从这里拿掉。
    let awaitingApplication: Set<PlaybackPlayer> = []
    for player in awaitingApplication {
        expectEqual(DiscordPresence.applicationID(forBundleID: player.bundleIdentifier, webPlatformID: nil),
                    DiscordPresence.applicationID, "Discord 应用: \(player) 还没建应用,用 Lyrimuse 那个")
    }
    let builtInIDs = PlaybackPlayer.allCases.filter { $0 != .auto && !awaitingApplication.contains($0) }.map {
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
                .show(DiscordPresence.pausedActivity(sampleTrack(), statusLine: .title, now: now, pausedNameFormat: "%@ (Paused)")),
                "Discord 意图: 选了暂停时保留,换成不带进度条、带暂停小图的那份")
}

private func checkDiscordSmallImage() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let badged = DiscordPresence.activity(sampleTrack(), statusLine: .title, now: now, smallImage: .lyrimuse)
    expectEqual(badged.assets?.smallImage, DiscordPresence.lyrimuseBadgeURL, "Discord 小图: 角标是 Lyrimuse 应用 Art Assets 里那张")
    expectEqual(badged.assets?.smallURL, DiscordPresence.websiteURL, "Discord 小图: 点角标打开官网")
    expectEqual(DiscordPresence.lyrimuseBadgeURL.hasPrefix("https://cdn.discordapp.com/app-assets/" + DiscordPresence.applicationID + "/"),
                true, "Discord 小图: 角标地址在 Lyrimuse 应用名下,各播放器的应用都能用")
    let paused = DiscordPresence.activity(sampleTrack(), statusLine: .title, now: nil, smallImage: .paused)
    expectEqual(paused.assets?.smallImage, DiscordPresence.pausedBadgeURL, "Discord 小图: 暂停图标")
    expectEqual(paused.assets?.smallURL, DiscordPresence.websiteURL, "Discord 小图: 点暂停图标也打开官网")
    var noCover = sampleTrack()
    noCover.coverURL = nil
    expectEqual(DiscordPresence.activity(noCover, statusLine: .title, now: now, smallImage: .lyrimuse).assets?.smallImage, nil,
                "Discord 小图: 没有封面时小图也不给")
    let appleMusicID = DiscordPresence.applicationID(forBundleID: PlaybackPlayer.appleMusic.bundleIdentifier, webPlatformID: nil)
    let playerBadged = DiscordPresence.activity(sampleTrack(), statusLine: .title, now: now, smallImage: .player(.appleMusic))
    expectEqual(playerBadged.assets?.smallImage,
                "https://cdn.discordapp.com/app-icons/" + appleMusicID + "/25a8439ce78331e5e5880499892a70c6.png?size=256",
                "Discord 小图: 播放器角标是它那个应用的 APP 图标")
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
    expectEqual(sourceBytes(json, contain: "\"small_text\""), false, "Discord 小图: 不发 small_text,指着小图不出悬停文字")
    expectEqual(sourceBytes(json, contain: "\"small_url\":"), true, "Discord 小图: 字段名 small_url")
    expectEqual(sourceBytes(jsonString(DiscordIPC.setActivity(paused, pid: 1, nonce: "1")),
                            contain: "\"small_url\":\"" + DiscordPresence.websiteURL + "\""),
                true, "Discord 小图: 暂停那份也带官网链接")

    func intent(_ track: DiscordPresence.Track?, pausedFor: TimeInterval? = nil, keep: Bool = false,
                badge: DiscordPresence.Badge = .lyrimuse, hiddenUntil: Date? = nil) -> DiscordPresence.Intent {
        DiscordPresence.intent(track: track, pausedSince: pausedFor.map { now.addingTimeInterval(-$0) }, statusLine: .title,
                               keepWhenPaused: keep, badge: badge, hiddenUntil: hiddenUntil, now: now)
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
                .show(DiscordPresence.pausedActivity(sampleTrack(), statusLine: .title, now: now,
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
        DiscordPresence.pausedActivity(track, statusLine: .player, now: date, pausedNameFormat: "%@（已暂停）")
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

private func checkDiscordLyrics() {
    typealias L = DiscordLyricLine
    // ---- 每句唱到哪 ----
    let spans = L.spans(starts: [1_000, 3_000, 4_000, 10_000, 20_000], texts: ["第一句", "  ", "第三句", "第四句", "最后"],
                        gapStarts: [3: 12_000], trackDurationMs: 25_000)
    expectEqual(spans, [L.Span(startMs: 1_000, endMs: 3_000, text: "第一句"), L.Span(startMs: 4_000, endMs: 10_000, text: "第三句"),
                        L.Span(startMs: 10_000, endMs: 12_000, text: "第四句"), L.Span(startMs: 20_000, endMs: 25_000, text: "最后")],
                "Discord 歌词: 唱到下一句开始或间奏开始,空白句不要,最后一句到整首结束")
    expectEqual(L.spans(starts: [5_000], texts: ["只有一句"], gapStarts: [:], trackDurationMs: nil).first?.endMs, 10_000,
                "Discord 歌词: 不知道整首多长时最后一句按 5 秒算")
    // ---- 挑哪一句 ----
    let lines = [L.Span(startMs: 0, endMs: 1_500, text: "短"), L.Span(startMs: 1_500, endMs: 6_000, text: "长"),
                 L.Span(startMs: 6_000, endMs: 7_000, text: "一秒"), L.Span(startMs: 9_000, endMs: 12_000, text: "间奏后")]
    expectEqual(L.pick(lines, atMs: 0, windowMs: 4_000), "长", "Discord 歌词: 挑这一段里唱得最久的那句,不是此刻这句")
    expectEqual(L.pick(lines, atMs: 1_000, windowMs: 4_000), "长", "Discord 歌词: 此刻那句快唱完了,挑下一句")
    expectEqual(L.pick(lines, atMs: 7_200, windowMs: 4_000), "间奏后", "Discord 歌词: 间奏快完时挑下一句(进得去 1 秒以上)")
    expectEqual(L.pick(lines, atMs: 7_000, windowMs: 2_500), nil, "Discord 歌词: 只进得去半秒的下一句不提前亮出来")
    expectEqual(L.pick([L.Span(startMs: 100, endMs: 600, text: "整句")], atMs: 0, windowMs: 4_000), "整句",
                "Discord 歌词: 整句都落在这一段里的短句照样算")
    expectEqual(L.pick(lines, atMs: 12_500, windowMs: 4_000), nil, "Discord 歌词: 唱完了为 nil")
    expectEqual(L.pick([L.Span(startMs: 0, endMs: 2_000, text: "前"), L.Span(startMs: 2_000, endMs: 4_000, text: "后")],
                       atMs: 0, windowMs: 4_000), "前", "Discord 歌词: 一样久挑先唱的")
    // ---- 下一次该看的时刻 ----
    expectEqual(L.nextChangeMs(lines, atMs: 0, windowMs: 4_000), 5_100,
                "Discord 歌词: 「长」在这一段里剩不到 1 秒的那一刻换成「一秒」")
    expectEqual(L.nextChangeMs(lines, atMs: 7_100, windowMs: 4_000), 4_000, "Discord 歌词: 唱到只剩不到 1 秒时变成没有")
    expectEqual(L.nextChangeMs(lines, atMs: 5_000, windowMs: 4_000), 100, "Discord 歌词: 下一步就换句时返回一步")
    expectEqual(L.nextChangeMs(lines, atMs: 7_100, windowMs: 4_000, horizonMs: 3_000), nil,
                "Discord 歌词: 看的范围里一直不变为 nil")
    expectEqual(L.nextChangeMs(lines, atMs: 12_500, windowMs: 4_000), nil, "Discord 歌词: 唱完了一直不变")

    // ---- 进 activity ----
    let now = Date(timeIntervalSince1970: 1_000_000)
    let lyricLine = DiscordPresence.Layout(third: .lyric)
    var track = sampleTrack()
    track.lyric = "  刮风这天 我试过握着你手 "
    let withLyric = DiscordPresence.activity(track, statusLine: .title, now: now, layout: lyricLine)
    expectEqual(withLyric.assets?.largeText, "\u{266A} 刮风这天 我试过握着你手", "Discord 歌词: 第三行选当前歌词时写「♪ 这一句」")
    expectEqual(withLyric.details, "晴天", "Discord 歌词: 歌名不动")
    expectEqual(withLyric.state, "周杰伦", "Discord 歌词: 歌手不动")
    expectEqual(DiscordPresence.activity(track, statusLine: .title, now: now).assets?.largeText, "叶惠美",
                "Discord 歌词: 没有一行选当前歌词时带着歌词也不显示")
    track.lyric = "   "
    expectEqual(DiscordPresence.activity(track, statusLine: .title, now: now, layout: lyricLine).assets?.largeText, "叶惠美",
                "Discord 歌词: 只有空白的歌词当没有,那一行写专辑")
    track.lyric = String(repeating: "啦", count: 200)
    expectEqual(DiscordPresence.activity(track, statusLine: .title, now: now, layout: lyricLine).assets?.largeText?.utf16.count, 128,
                "Discord 歌词: 超长的截到 128")
    var bare = sampleTrack()
    bare.coverURL = nil
    bare.lyric = "这一句"
    let bareLyric = DiscordPresence.activity(bare, statusLine: .title, now: now, smallImage: .lyrimuse, layout: lyricLine)
    expectEqual(bareLyric.assets?.largeImage, DiscordPresence.iconURL(of: .lyrimuse),
                "Discord 歌词: 没封面时拿应用图标当大图,好让第三行出来")
    expectEqual(bareLyric.assets?.largeText, "\u{266A} 这一句", "Discord 歌词: 没封面时歌词照样显示")
    expectEqual(bareLyric.assets?.smallImage, nil, "Discord 歌词: 补上的大图不压小图,跟没封面时一个样子")
    bare.lyric = nil
    expectEqual(DiscordPresence.activity(bare, statusLine: .title, now: now).assets?.largeText, "叶惠美",
                "Discord 排法: 没封面时第三行写专辑也补应用图标,专辑照样显示")
    expectEqual(DiscordPresence.activity(bare, statusLine: .title, now: now, layout: .init(third: .none)).assets, nil,
                "Discord 排法: 没封面、第三行没字时照旧不给大图")
    var lyricTrack = sampleTrack()
    lyricTrack.lyric = "这一句"
    expectEqual(DiscordPresence.pausedActivity(lyricTrack, statusLine: .title, now: now, pausedNameFormat: "%@ (Paused)",
                                               layout: lyricLine).assets?.largeText, "叶惠美",
                "Discord 歌词: 暂停保留的那份不挂歌词,那一行写专辑")
}

private func checkDiscordButtons() {
    let song = URL(string: "https://music.apple.com/cn/album/x/1?i=2")
    func make(custom: (String, String)? = nil, listen: Bool = false, songURL: URL? = song,
              get: Bool = false) -> [DiscordActivity.Button]? {
        DiscordPresence.buttons(custom: custom, listen: listen, listenLabel: "在 Apple Music 上收听", songURL: songURL,
                                getLyrimuse: get, getLyrimuseLabel: "获取 Lyrimuse")
    }
    let listen = DiscordActivity.Button(label: "在 Apple Music 上收听", url: "https://music.apple.com/cn/album/x/1?i=2")
    let get = DiscordActivity.Button(label: "获取 Lyrimuse", url: DiscordPresence.websiteURL)
    let custom = DiscordActivity.Button(label: "我的歌单", url: "https://example.com/list")
    expectEqual(make(), nil, "Discord 按钮: 都没开时不带")
    expectEqual(make(listen: true, get: true), [listen, get], "Discord 按钮: 「在 XX 上收听」排在「获取 Lyrimuse」前面")
    expectEqual(make(custom: (" 我的歌单 ", " https://example.com/list "), listen: true, get: true), [custom, listen],
                "Discord 按钮: 自定义排第一,最多两个,多出来的「获取 Lyrimuse」不带")
    expectEqual(make(listen: true, songURL: nil, get: true), [get], "Discord 按钮: 这首没有歌曲页时「在 XX 上收听」不出,后面的顶上")
    expectEqual(make(listen: true, songURL: URL(string: "music://x"), get: false), nil,
                "Discord 按钮: 歌曲页不是网页(进 App 的深链)时不出")
    expectEqual(make(custom: ("看看", "example.com"), get: true), [get], "Discord 按钮: 自定义链接不是 http(s) 时不带")
    expectEqual(make(custom: ("  ", "https://example.com"), get: true), [get], "Discord 按钮: 自定义文字空的不带")
    let long = make(custom: (String(repeating: "长", count: 40), "https://example.com"))?.first?.label
    expectEqual(long?.utf16.count, 32, "Discord 按钮: 文字截到 32")
    expectEqual(long?.hasSuffix("…"), true, "Discord 按钮: 截断的文字带省略号")
    expectEqual(DiscordPresence.isUsableButtonURL(" https://example.com "), true, "Discord 按钮: 链接两头的空白不算")
    expectEqual(DiscordPresence.isUsableButtonURL("ftp://example.com"), false, "Discord 按钮: 只认 http(s)")

    let now = Date(timeIntervalSince1970: 1_000_000)
    var track = sampleTrack()
    track.buttons = [custom, listen, get]
    let activity = DiscordPresence.activity(track, statusLine: .title, now: now)
    expectEqual(activity.buttons, [custom, listen], "Discord 按钮: activity 里最多两个")
    let json = String(decoding: DiscordIPC.setActivity(activity, pid: 1, nonce: "n"), as: UTF8.self)
    expectEqual(json.contains("\"buttons\":[{\"label\":\"我的歌单\",\"url\":\"https://example.com/list\"}"), true,
                "Discord 按钮: 编码成 buttons 数组,每个带 label 和 url")
    expectEqual(String(decoding: DiscordIPC.setActivity(DiscordPresence.activity(sampleTrack(), statusLine: .title, now: now),
                                                        pid: 1, nonce: "n"), as: UTF8.self).contains("buttons"), false,
                "Discord 按钮: 没按钮时不编码这个键")
    expectEqual(DiscordPresence.withoutLinksAndImages(activity).buttons, nil, "Discord 按钮: 被拒后补发的精简版不带按钮")
    track.buttons = []
    expectEqual(DiscordPresence.activity(track, statusLine: .title, now: now).buttons, nil, "Discord 按钮: 空数组当没有")
    expectEqual(DiscordPresence.pausedActivity({ var t = sampleTrack(); t.buttons = [get]; return t }(), statusLine: .title,
                                               now: now, pausedNameFormat: "%@ (Paused)").buttons, [get],
                "Discord 按钮: 暂停保留的那份照样带按钮")

    // ---- 回执里 Discord 收下的那份,整理成一行日志 ----
    let echoed = Data(#"{"cmd":"SET_ACTIVITY","nonce":"3","evt":null,"data":{"name":"QQ 音乐","type":2,"status_display_type":2,"details":"晴天","state":"周杰伦","assets":{"large_image":"mp:external/abc","large_text":"♪ 刮风这天"},"timestamps":{"start":1000,"end":201000},"buttons":["在 QQ 音乐 上收听","获取 Lyrimuse"],"metadata":{"button_urls":["https://y.qq.com/x","https://yudaotor.github.io/lyrimuse/"]}}}"#.utf8)
    expectEqual(DiscordIPC.activityEcho(echoed),
                #"name="QQ 音乐" status_display_type=2 details="晴天" state="周杰伦" large_text="♪ 刮风这天" large_image=yes start=1000 end=201000 buttons=["在 QQ 音乐 上收听","获取 Lyrimuse"] button_urls=2"#,
                "Discord 回执: 收下的那份整理成一行,按钮是文字数组、链接数另记")
    let objectButtons = Data(#"{"data":{"details":"晴天","buttons":[{"label":"获取 Lyrimuse","url":"https://x"}]}}"#.utf8)
    expectEqual(DiscordIPC.activityEcho(objectButtons)?.contains(#"buttons=["获取 Lyrimuse"]"#), true,
                "Discord 回执: 按钮回成带 label 的对象也认")
    expectEqual(DiscordIPC.activityEcho(objectButtons)?.contains("large_image=no start=- end=-"), true,
                "Discord 回执: 没有的字段写 no / -")
    expectEqual(DiscordIPC.activityEcho(Data(#"{"cmd":"SET_ACTIVITY","data":null}"#.utf8)), nil, "Discord 回执: 清空的回执没有这一行")
    expectEqual(DiscordIPC.activityEcho(Data("not json".utf8)), nil, "Discord 回执: 读不懂的回执没有这一行")
}

private func checkDiscordLayout() {
    typealias L = DiscordPresence.Layout
    let now = Date(timeIntervalSince1970: 1_000_000)
    let plain = DiscordPresence.activity(sampleTrack(), statusLine: .title, now: now)
    expectEqual(DiscordPresence.activity(sampleTrack(), statusLine: .title, now: now, layout: L()), plain,
                "Discord 排法: 默认的排法跟不传一模一样")

    // ---- 不显示是哪首歌 ----
    var track = sampleTrack()
    track.lyric = "刮风这天"
    let listen = DiscordActivity.Button(label: "在 Apple Music 上收听", url: "https://music.apple.com/cn/album/x/1?i=2")
    let get = DiscordActivity.Button(label: "获取 Lyrimuse", url: DiscordPresence.websiteURL)
    track.buttons = [listen, get]
    let hidden = DiscordPresence.activity(track, statusLine: .title, listeningName: .title, now: now, smallImage: .lyrimuse,
                                          layout: L(hidesSong: true))
    expectEqual(hidden.details == nil && hidden.state == nil && hidden.detailsURL == nil && hidden.stateURL == nil, true,
                "Discord 隐私: 不显示是哪首歌时不发歌名、歌手和链接")
    expectEqual(hidden.name, "Apple Music", "Discord 隐私: 「正在收听」后面写播放器名,不按设置写歌名")
    expectEqual(hidden.statusDisplayType, DiscordPresence.StatusLine.player.displayType, "Discord 隐私: 用户名下方写播放器名")
    expectEqual(hidden.assets?.largeImage, DiscordPresence.iconURL(of: .lyrimuse), "Discord 隐私: 大图是应用图标,不是封面")
    expectEqual(hidden.assets?.largeText == nil && hidden.assets?.largeURL == nil, true, "Discord 隐私: 不发专辑、歌词和封面链接")
    expectEqual(hidden.assets?.smallImage, DiscordPresence.lyrimuseBadgeURL, "Discord 隐私: 角标照常")
    expectEqual(hidden.timestamps, plain.timestamps, "Discord 隐私: 进度照常")
    expectEqual(hidden.buttons, [get], "Discord 隐私: 链到这首歌曲页的按钮不带,别的照常")
    let hiddenJSON = String(decoding: DiscordIPC.setActivity(hidden, pid: 1, nonce: "n"), as: UTF8.self)
    expectEqual(hiddenJSON.contains("\"details\"") || hiddenJSON.contains("\"state\"") || hiddenJSON.contains("晴天"), false,
                "Discord 隐私: 发出去的里面没有歌名、歌手字段")
    expectEqual(DiscordPresence.pausedActivity(track, statusLine: .title, now: now, pausedNameFormat: "%@ (Paused)",
                                               layout: L(hidesSong: true)).details, nil,
                "Discord 隐私: 暂停保留的那份同样不写歌名")

    // ---- 三行各写什么 ----
    expectEqual(DiscordPresence.activity(sampleTrack(), statusLine: .title, now: now, layout: L(third: .none)).assets?.largeText, nil,
                "Discord 排法: 第三行选不显示时没有那一行")
    expectEqual(DiscordPresence.activity(sampleTrack(), statusLine: .title, now: now, layout: L(showsProgress: false)).timestamps,
                DiscordActivity.Timestamps(start: 999_970_000, end: nil), "Discord 排法: 不显示进度条时只给开始时间")
    var lyricTrack = sampleTrack()
    lyricTrack.lyric = "这一句"
    let merged = L(first: .titleArtist, second: .album, third: .lyric)
    let oneLine = DiscordPresence.activity(lyricTrack, statusLine: .artist, now: now, layout: merged)
    expectEqual(oneLine.details, "晴天 - 周杰伦", "Discord 排法: 第一行「歌名 - 歌手」")
    expectEqual(oneLine.detailsURL, plain.detailsURL, "Discord 排法: 写着歌名的合并行链到歌曲页")
    expectEqual(oneLine.state, "叶惠美", "Discord 排法: 第二行写专辑")
    expectEqual(oneLine.stateURL, nil, "Discord 排法: 专辑那一行不挂链接")
    expectEqual(oneLine.assets?.largeText, "\u{266A} 这一句", "Discord 排法: 第三行写歌词")
    expectEqual(DiscordPresence.statusText(of: oneLine), "晴天 - 周杰伦", "Discord 排法: 用户名下方选歌手时写合并的那一行")
    expectEqual(DiscordPresence.activity(sampleTrack(), statusLine: .title, now: now, layout: merged).assets?.largeText, nil,
                "Discord 排法: 歌词那一行没歌词、专辑已经占了一行时空着,不重复专辑")
    expectEqual(DiscordPresence.activity(sampleTrack(), statusLine: .title, now: now, layout: L(third: .lyric)).assets?.largeText,
                "叶惠美", "Discord 排法: 歌词那一行没歌词、专辑没占一行时写专辑")
    expectEqual(DiscordPresence.activity(sampleTrack(), statusLine: .title, now: now, layout: L(first: .artistTitle)).details,
                "周杰伦 - 晴天", "Discord 排法: 「歌手 - 歌名」")
    let lyricFirst = DiscordPresence.activity(lyricTrack, statusLine: .title, now: now, layout: L(first: .lyric, second: .titleArtist))
    expectEqual(lyricFirst.details, "\u{266A} 这一句", "Discord 排法: 歌词也能放第一行")
    expectEqual(lyricFirst.detailsURL, nil, "Discord 排法: 歌词那一行不挂链接")
    expectEqual(DiscordPresence.statusText(of: lyricFirst), "晴天 - 周杰伦", "Discord 排法: 用户名下方选歌名时找写着歌名的那一行")
    expectEqual(DiscordPresence.activity(sampleTrack(), statusLine: .player, now: now, layout: L(first: .none)).details, nil,
                "Discord 排法: 第一行选不显示时不发 details")

    let swapped = DiscordPresence.activity(sampleTrack(), statusLine: .title, now: now, layout: L(first: .artist, second: .title))
    expectEqual(swapped.details, "周杰伦", "Discord 排法: 第一行写歌手")
    expectEqual(swapped.state, "晴天", "Discord 排法: 第二行写歌名")
    expectEqual(swapped.detailsURL, plain.stateURL, "Discord 排法: 歌手页链接跟着歌手走")
    expectEqual(swapped.stateURL, plain.detailsURL, "Discord 排法: 歌曲页链接跟着歌名走")
    expectEqual(DiscordPresence.statusText(of: swapped), "晴天", "Discord 排法: 歌手在前时用户名下方选歌名仍写歌名")
    expectEqual(DiscordPresence.statusText(of: DiscordPresence.activity(sampleTrack(), statusLine: .artist, now: now,
                                                                          layout: L(first: .artist, second: .title))),
                "周杰伦", "Discord 排法: 歌手在前时用户名下方选歌手仍写歌手")
    expectEqual(DiscordPresence.activity(sampleTrack(), statusLine: .title, now: now,
                                         layout: L(first: .artistTitle, second: .title)).statusDisplayType,
                DiscordPresence.StatusLine.artist.displayType, "Discord 排法: 单写歌名的那一行比合并的那一行优先")

    let labeled = DiscordPresence.activity(sampleTrack(), statusLine: .title, now: now,
                                           layout: L(artistFormat: "by %@", albumFormat: "on %@"))
    expectEqual(labeled.state, "by 周杰伦", "Discord 排法: 歌手前加说明")
    expectEqual(labeled.assets?.largeText, "on 叶惠美", "Discord 排法: 专辑前加说明")
    expectEqual(labeled.details, "晴天", "Discord 排法: 歌名不加")
    let labeledOneLine = DiscordPresence.activity(sampleTrack(), statusLine: .title, now: now,
                                                  layout: L(first: .titleArtist, second: .album, third: .none,
                                                            artistFormat: "by %@", albumFormat: "on %@"))
    expectEqual(labeledOneLine.details, "晴天 - 周杰伦", "Discord 排法: 合在一起的那一行不加说明")
    expectEqual(labeledOneLine.state, "on 叶惠美", "Discord 排法: 别的行写专辑照样加说明")
    expectEqual(DiscordPresence.activity(sampleTrack(), statusLine: .title, now: now,
                                         layout: L(third: .lyric, albumFormat: "on %@")).assets?.largeText,
                "on 叶惠美", "Discord 排法: 歌词那一行退回专辑时也加说明")
    expectEqual([L().followsLyrics, L(second: .lyric).followsLyrics, L(hidesSong: true, third: .lyric).followsLyrics],
                [false, true, false], "Discord 排法: 有一行写歌词、没选不显示是哪首歌时才跟歌词")

    // ---- 设置之间互相压着时,界面显示实际生效的那一档 ----
    typealias P = DiscordPresence
    expectEqual(P.effectiveListeningName(.title, layout: L(hidesSong: true)), .player, "Discord 设置: 不显示是哪首歌时「正在收听」后面算播放器")
    expectEqual(P.effectiveListeningName(.title, layout: L()), .title, "Discord 设置: 平时照存着的")
    expectEqual(P.effectiveStatusLine(.title, listeningName: .player, layout: L(hidesSong: true)), .player,
                "Discord 设置: 不显示是哪首歌时用户名下方算播放器")
    expectEqual(P.statusLines(for: .player, layout: L()), [.title, .artist, .player], "Discord 设置: 平时三档都能选")
    expectEqual(P.statusLines(for: .player, layout: L(second: .album)), [.title, .player],
                "Discord 设置: 前两行都没写歌手时「歌手」那档不能选")
    expectEqual(P.statusLines(for: .artist, layout: L(second: .album)), [.title, .artist],
                "Discord 设置: 「正在收听」后面写着歌手时「歌手」那档用它")
    expectEqual(P.statusLines(for: .player, layout: merged), [.title, .artist, .player],
                "Discord 设置: 合在一起的那一行歌名、歌手两档都能选")
    expectEqual(P.statusLines(for: .player, layout: L(first: .album, second: .lyric, third: .title)), [.player],
                "Discord 设置: 歌名只在第三行时放不到用户名下方")
    expectEqual(P.effectiveStatusLine(.artist, listeningName: .player, layout: L(second: .album)), .player,
                "Discord 设置: 存的那档写不出来时退到「正在收听」后面那一样")
    expectEqual(P.effectiveStatusLine(.artist, listeningName: .title, layout: L(second: .album)), .title,
                "Discord 设置: 「正在收听」后面写歌名时退到歌名")
    let layouts = [L(), merged, L(first: .artist, second: .title), L(first: .album, second: .lyric, third: .title),
                   L(second: .none), L(first: .artistTitle, second: .title), L(hidesSong: true)]
    for stored in DiscordPresence.StatusLine.allCases {
        for name in DiscordPresence.ListeningName.allCases {
            for layout in layouts {
                let sent = P.activity(sampleTrack(), statusLine: stored, listeningName: name, now: now, layout: layout)
                let shown = P.effectiveStatusLine(stored, listeningName: name, layout: layout)
                let viaShown = P.activity(sampleTrack(), statusLine: shown, listeningName: P.effectiveListeningName(name, layout: layout),
                                          now: now, layout: layout)
                expectEqual(P.statusText(of: sent), P.statusText(of: viaShown),
                            "Discord 设置: 界面显示的那一档跟实际发出去的一致(\(stored) / \(name) / \(layout))")
                expectEqual(P.statusLines(for: name, layout: layout).contains(shown), true,
                            "Discord 设置: 界面显示的那一档不是灰的(\(stored) / \(name) / \(layout))")
            }
        }
    }
    let hiddenPlayerBadge = P.activity(sampleTrack(), statusLine: .title, now: now, smallImage: .player(.appleMusic),
                                       layout: L(hidesSong: true))
    expectEqual(hiddenPlayerBadge.assets?.smallImage, nil, "Discord 隐私: 大图已是播放器图标时不再放播放器角标")
    expectEqual(P.activity(sampleTrack(), statusLine: .title, now: now, smallImage: .paused, layout: L(hidesSong: true))
                    .assets?.smallImage, DiscordPresence.pausedBadgeURL, "Discord 隐私: 暂停图标照放")
}

private func checkDiscordWiring() {
    let sourcesRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    func code(_ path: String) -> String {
        (try? String(contentsOfFile: sourcesRoot.appendingPathComponent(path).path, encoding: .utf8)) ?? ""
    }
    expectEqual(sourceBytes(code("lyrimuse/AppDelegate.swift"), contain: "DiscordPresenceController.shared.start()"), true,
                "Discord(接线): App 启动时开始盯")
    let controller = code("lyrimuse/Settings/DiscordPresenceController.swift")
    let accountTab = code("lyrimuse/AccountLinkingTab.swift")
    expectEqual(sourceBytes(accountTab, contain: "pinnedViews"), false,
                "Discord(接线): 预览不用 LazyVStack 的组头钉住(玻璃卡片、胶囊会压到组头上)")
    expectEqual(sourceHas(accountTab, "VStack(spacing: 14) {\n            DiscordPresencePreview()\n                .padding(.bottom, 6)\n            if appSettings.discordPresenceEnabled"), true,
                "Discord(接线): 预览排在最前面、跟着页面一起滚,不钉住(钉住会挡住下面的设置项)")
    for toggle in ["discordCustomButtonEnabled", "discordButtonListen", "discordButtonGetLyrimuse"] {
        expectEqual(sourceBytes(accountTab, contain: "Toggle(\"\", isOn: $appSettings.\(toggle))"), true,
                    "Discord(接线): \(toggle) 随便开,不拦第三个(多出来的按顺序让位)")
    }
    expectEqual(sourceBytes(code("lyrimuse/Settings/AppSettings.swift"),
                            contain: "discordButtonGetLyrimuse = (defaults.object(forKey: Keys.discordButtonGetLyrimuse) as? Bool) ?? true"), true,
                "Discord(接线): 「获取 Lyrimuse」默认开(同 Music Presence 的「Get this status」)")
    expectEqual(sourceHas(accountTab, "title: L10n.t(\"「获取 Lyrimuse」\"),\n                        subtitle: L10n.t(\"另外两个都开着时不显示\"))"), true,
                "Discord(接线): 「获取 Lyrimuse」那一行写明另外两个都开着时让位")
    for needle in ["signal(playback.$title)", "signal(playback.$anchor)", "signal(playback.$isPlayingSmoothed)",
                   "signal(source.$webPageArtworkURL)", "signal(ConfigStore.shared.$stateRelayURL)",
                   "signal(playback.$isCurrentTrackAdBreak)", "signal(playback.$isRadioTalkBreak)",
                   "signal(settings.$discordPresenceEnabled)", "signal(settings.$discordStatusDisplay)",
                   "signal(settings.$discordListeningName)", "listeningName: settings.discordListeningName",
                   "signal(settings.$discordKeepWhenPaused)", "signal(settings.$discordExcludedBundles)",
                   "signal(settings.$discordBadge)", "badge: settings.discordBadge", "hiddenUntil: hiddenUntil",
                   "links?.artistWebLink(forPlayerBundleID: reportedBundleID", "hit?.artistPage",
                   "signal(source.$webPageVideoFrameURL)", "source.kasetVideoFrameURL ?? source.webPageVideoFrameURL",
                   "videoFrame: extras.videoFrame", "EnrichCacheReader.publicCoverURL(artist: source.artist",
                   "signal(settings.$discordLine1)", "signal(playback.$allLines)", "signal(playback.$lyricsGapMarkers)",
                   "signal(settings.$discordCustomButtonURL)", "signal(settings.$discordButtonListen)",
                   "signal(settings.$discordButtonGetLyrimuse)", "lyric: currentLyric(now: now)",
                   "atMs: playback.lyricsTimelineMs(now: now)", "windowMs: Int(DiscordPresenceGate.minInterval * 1000)",
                   "wake(at: now.addingTimeInterval(nextLyricCheck(now: now)))", "layout: presenceLayout(),",
                   "signal(settings.$discordHideSongInfo)", "signal(settings.$discordShowProgress)",
                   "signal(settings.$discordLine2)", "signal(settings.$discordLine3)",
                   "guard presenceLayout().followsLyrics, playback.isPlayingSmoothed else { return nil }"] {
        expectEqual(sourceBytes(controller, contain: needle), true, "Discord(接线): 控制器盯着 \(needle)")
    }
    for needle in ["if lookup.finished, lookup.hit == nil, let retryAt = lookup.retryAt, now >= retryAt {",
                   "attempt: lookup.attempt + 1", "ITunesSearchGate.shared.cooldownEnds()", "lookup.attempt == 0",
                   "        if track != nil {\n            scheduleCoverWake(now: now)",
                   "guard let at = due.filter({ $0 > now }).min() else { return }", "coverWakeTask = Task { [weak self] in"] {
        expectEqual(sourceHas(controller, needle), true, "Discord(接线): 没问成的封面到点再查 \(needle)")
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
    // 头像框:连上时跟头像一起取,预览里资料卡和成员名单两处头像都压上,在线点在它上面。
    let avatarStore = code("lyrimuse/Settings/SettingsSidebarChrome.swift")
    for needle in ["self?.load(user.avatarDecorationURL(), .decoration)", "decoration = fetched.map(AppIconResolver.prerendered)"] {
        expectEqual(sourceBytes(avatarStore, contain: needle), true, "Discord(接线): 连上时取头像框 \(needle)")
    }
    for needle in ["DiscordAvatarImage(size: Self.popoutAvatar)\n                .overlay { avatarDecoration(size: Self.popoutAvatar) }",
                   "DiscordAvatarImage(size: size)\n            .overlay { avatarDecoration(size: size) }\n            .overlay(alignment: .bottomTrailing) { onlineDot(",
                   ".frame(width: size * Self.decorationScale, height: size * Self.decorationScale)"] {
        expectEqual(sourceHas(preview, needle), true, "Discord(接线): 预览两处头像压上头像框 \(needle)")
    }
    // 成员名单的示例好友里有作者 Yudaotor,头像是随包的那张鸭子图;名单人数跟着是 4。
    for needle in ["friendRow(name: \"Yudaotor\"", "image: Self.yudaotorAvatar", "forResource: \"YudaotorAvatar\", ofType: \"png\"",
                   "L10n.t(\"在线 — %d\"), 4)"] {
        expectEqual(sourceBytes(preview, contain: needle), true, "Discord(接线): 示例好友里有作者 \(needle)")
    }
    expectEqual(FileManager.default.fileExists(atPath: sourcesRoot.appendingPathComponent("lyrimuse/Resources/YudaotorAvatar.png").path),
                true, "Discord(接线): 作者头像随包(Resources/YudaotorAvatar.png)")
    // 预览里的图标(角标放大 1.22 倍,大图 60pt,头像占位 64pt)都得是预先画好的一组位图:按需绘制的图 SwiftUI 只按布局
    // 尺寸画一次,放大就糊;随包的 PNG 整张直接缩小满是锯齿。
    let resolver = code("lyrimuse/Settings/AppIconResolver.swift")
    let webIcons = code("lyrimuse/Settings/WebPlatformIcon.swift")
    let accounts = code("lyrimuse/AccountLinkingTab.swift")
    expectEqual(sourceBytes(resolver, contain: "isFullBleed(loaded) ? fittedToIconGrid(loaded) : prerendered(loaded)")
                    && sourceBytes(resolver, contain: "return prerendered(size: NSSize(width: side, height: side)) {"), true,
                "Discord(接线): 播放器的随包图标和铺满的图标预先画成位图")
    expectEqual(sourceBytes(webIcons, contain: "return AppIconResolver.prerendered(image)")
                    && sourceBytes(webIcons, contain: "return AppIconResolver.prerendered(size: size) {"), true,
                "Discord(接线): YouTube Music、Spotify 网页版的图标预先画成位图")
    expectEqual(accounts.components(separatedBy: "return AppIconResolver.prerendered(image)").count - 1, 4,
                "Discord(接线): Discord、Telegram、Last.fm、ListenBrainz 的品牌图预先画成位图")
    for (path, source) in [("AppIconResolver", resolver), ("WebPlatformIcon", webIcons)] {
        expectEqual(sourceBytes(source, contain: "flipped: false) {"), false, "Discord(接线): \(path) 不用按需绘制的图")
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
