import Foundation
import LyrimuseCore

func runNetEaseIPadTests() {
    typealias N = NetEaseIPadNowPlaying
    typealias F = NetEaseIPadNowPlaying.Frame
    let mac = PlaybackPlayer.netease.bundleIdentifier

    // ---- 按网易云 Mac 版认,找进程、权限行不算它 ----
    do {
        expectEqual(PlayerBundleAliases.canonical(N.bundleID), mac, "iPad 网易云: bundle id 换成 Mac 版的")
        expectEqual(MediaControlClient.reportingPlayerBundleID(N.bundleID, owner: nil), mac, "iPad 网易云: 系统报上来的一进来就当 Mac 版")
        expectEqual(PlayerBundleAliases.all(for: mac), [mac, N.bundleID], "iPad 网易云: 判装没装、在不在跑把它算上")
        expectEqual(PlayerBundleAliases.all(for: mac, includingOtherClients: false), [mac],
                    "iPad 网易云: 按本体的菜单、界面、数据做事的地方不算它")
        let pinePro = "com.digipine.pineplayer.pro"
        expectEqual(PlayerBundleAliases.all(for: pinePro, includingOtherClients: false).contains(pinePro), true,
                    "iPad 网易云: Pine 的付费版是同一个程序,照旧算")
    }

    // ---- 位置:iPad 版偏差过门槛就对齐读数,Mac 版照旧 ----
    do {
        typealias L = LocalPlaybackSource
        expectEqual(L.snapsToReportedPosition(bundleID: mac, client: N.bundleID), true, "iPad 网易云 位置: 对齐它重报的读数")
        expectEqual(L.snapsToReportedPosition(bundleID: mac, client: mac), false, "iPad 网易云 位置: Mac 版照旧不对齐")
        expectEqual(L.snapsToReportedPosition(bundleID: mac), false, "iPad 网易云 位置: 不知道谁报的按 Mac 版")
        expectEqual([L.resumeReadingNeverLeads(bundleID: mac, client: N.bundleID), L.resumeReadingNeverLeads(bundleID: mac, client: mac),
                     L.resumeReadingNeverLeads(bundleID: mac)], [true, false, false],
                    "iPad 网易云 位置: 恢复 / 开播那一拍的读数原样采信,Mac 版照旧削")
        MediaControlClient.noteReportingClient(N.bundleID, forBundleID: mac)
        expectEqual(MediaControlClient.reportingClient(forBundleID: mac), N.bundleID, "iPad 网易云 位置: 记下这份会话是 iPad 版报的")
        MediaControlClient.noteReportingClient(mac, forBundleID: mac)
        expectEqual(MediaControlClient.reportingClient(forBundleID: mac), mac, "iPad 网易云 位置: 换成 Mac 版报的就改记")
        expectEqual(MediaControlClient.reportingClient(forBundleID: nil), nil, "iPad 网易云 位置: 没有播放器时为 nil")
    }

    // ---- 锁屏歌词开着:换歌那一帧记下真名,后面的歌词帧还原(录到的真实序列) ----
    do {
        var memory = N.Memory()
        let plain = F(title: "Billie Jean", artist: "Michael Jackson", album: "Thriller", duration: 293, elapsed: 0)
        expectEqual(N.normalized(plain, memory: &memory), plain, "iPad 网易云: 真名那一帧原样")
        let lyric = F(title: "制作人: Quincy Jones/Michael Jackson", artist: "Michael Jackson/Billie Jean", album: "Thriller",
                      duration: 293, elapsed: 1.9)
        let restored = N.normalized(lyric, memory: &memory)
        expectEqual([restored.title, restored.artist], ["Billie Jean", "Michael Jackson"], "iPad 网易云: 歌词帧还原成真名")
        expectEqual(restored.elapsed, 1.9, "iPad 网易云: 进度照原样")
        let next = N.normalized(F(title: "She was more like a beauty queen from a movie scene", artist: "Michael Jackson/Billie Jean",
                                  album: "Thriller", duration: 293, elapsed: 29.9), memory: &memory)
        expectEqual(next.title, "Billie Jean", "iPad 网易云: 换了一句还是同一首")
        let again = N.normalized(lyric, memory: &memory)
        expectEqual(again, restored, "iPad 网易云: 同一帧再整理一次结果不变")
        let otherAlbum = F(title: "Duet", artist: "Michael Jackson/Billie Jean", album: "Other", duration: 200, elapsed: 0)
        expectEqual(N.normalized(otherAlbum, memory: &memory), otherAlbum, "iPad 网易云: 专辑不同的不当歌词帧(歌手恰好写成「歌手/歌名」的另一首)")
    }

    // ---- 换歌:第一帧还是上一首的名字、时长已是新歌的(录到的真实序列) ----
    do {
        var memory = N.Memory()
        _ = N.normalized(F(title: "Memorable Trip", artist: "陈玖仟", album: "Good Mood Today", duration: 102, elapsed: 0), memory: &memory)
        _ = N.normalized(F(title: "纯音乐，请欣赏", artist: "陈玖仟/Memorable Trip", album: "Good Mood Today", duration: 102,
                           elapsed: 60), memory: &memory)
        let torn = N.normalized(F(title: "Memorable Trip", artist: "陈玖仟", album: "Good Mood Today", duration: 139, elapsed: 0),
                                memory: &memory)
        expectEqual(torn.duration, 102, "iPad 网易云: 撕裂那一帧按上一首的时长报")
        let newSong = F(title: "沢の河城工務店 (山涧的河城工务店)", artist: "Foxtail-Grass Studio", album: "ときかけエオリア",
                        duration: 139, elapsed: 0)
        expectEqual(N.normalized(newSong, memory: &memory), newSong, "iPad 网易云: 新歌那一帧原样")
        expectEqual(TornTrackHold.isTorn(current: .init(title: "Memorable Trip", artist: "陈玖仟", album: "Good Mood Today",
                                                        bundle: mac, duration: torn.duration ?? 0, isRadio: false),
                                         next: .init(title: newSong.title ?? "", artist: newSong.artist ?? "", album: newSong.album ?? "",
                                                     bundle: mac, duration: 139, isRadio: false)),
                    false, "iPad 网易云: 新歌那一帧不会被当成时长没跟上按住")
        let lyric = N.normalized(F(title: "作曲: ZUN", artist: "Foxtail-Grass Studio/沢の河城工務店 (山涧的河城工务店)",
                                   album: "ときかけエオリア", duration: 139, elapsed: 0.8), memory: &memory)
        expectEqual([lyric.title, lyric.artist], ["沢の河城工務店 (山涧的河城工务店)", "Foxtail-Grass Studio"], "iPad 网易云: 新歌的歌词帧还原")
    }

    // ---- 换歌:第一帧 title 还是上一首最后一句歌词、artist / 专辑 / 时长已是新歌的(录到的真实序列) ----
    do {
        var memory = N.Memory()
        let previous = F(title: "阴天快乐", artist: "陈奕迅", album: "Rice & Shine", duration: 260, elapsed: 0)
        _ = N.normalized(previous, memory: &memory)
        _ = N.normalized(F(title: "那个酒窝", artist: "陈奕迅/阴天快乐", album: "Rice & Shine", duration: 260, elapsed: 79),
                         memory: &memory)
        var midSong = memory
        let notAtStart = F(title: "那个酒窝", artist: "胡夏/同桌的你 (电影《同桌的你》片尾主题曲)", album: "同桌的你", duration: 270,
                           elapsed: 30)
        expectEqual(N.normalized(notAtStart, memory: &midSong), notAtStart, "iPad 网易云: 进度不在开头的不当歌词撕裂帧")
        let tornRaw = F(title: "那个酒窝", artist: "胡夏/同桌的你 (电影《同桌的你》片尾主题曲)", album: "同桌的你", duration: 270,
                        elapsed: 0)
        let torn = N.normalized(tornRaw, memory: &memory)
        expectEqual(torn, previous, "iPad 网易云: 歌词撕裂帧整帧按上一首报")
        expectEqual(N.normalized(tornRaw, memory: &memory), previous, "iPad 网易云: 歌词撕裂帧再整理一次结果不变")
        let newSong = F(title: "同桌的你 (电影《同桌的你》片尾主题曲)", artist: "胡夏", album: "同桌的你", duration: 270, elapsed: 0)
        expectEqual(N.normalized(newSong, memory: &memory), newSong, "iPad 网易云: 歌词撕裂帧之后的真名帧原样")
        expectEqual(memory.lyricTitle, nil, "iPad 网易云: 换了真名就忘掉上一首的歌词")
        expectEqual(TornTrackHold.isTorn(current: .init(title: torn.title ?? "", artist: torn.artist ?? "", album: torn.album ?? "",
                                                        bundle: mac, duration: torn.duration ?? 0, isRadio: false),
                                         next: .init(title: newSong.title ?? "", artist: newSong.artist ?? "", album: newSong.album ?? "",
                                                     bundle: mac, duration: 270, isRadio: false)),
                    false, "iPad 网易云: 歌词撕裂帧之后的真名帧不会被按住")
        let lyric = N.normalized(F(title: "老师们都已想不起", artist: "胡夏/同桌的你 (电影《同桌的你》片尾主题曲)", album: "同桌的你",
                                   duration: 270, elapsed: 18.3), memory: &memory)
        expectEqual([lyric.title, lyric.artist], ["同桌的你 (电影《同桌的你》片尾主题曲)", "胡夏"], "iPad 网易云: 新歌的歌词帧还原")
        let later = N.normalized(F(title: "那个酒窝", artist: "陈奕迅/阴天快乐", album: "Rice & Shine", duration: 260, elapsed: 30),
                                 memory: &memory)
        expectEqual(later.title, "那个酒窝", "iPad 网易云: 换了真名之后不再按上一首的歌词认")
    }

    // ---- 歌词撕裂帧的 title 是没报过的那一句(它在后台时不逐句重报,录到的真实序列) ----
    do {
        var memory = N.Memory()
        let previous = F(title: "成都", artist: "赵雷", album: "成都", duration: 328, elapsed: 0)
        _ = N.normalized(previous, memory: &memory)
        _ = N.normalized(F(title: "作词: 赵雷", artist: "赵雷/成都", album: "成都", duration: 328, elapsed: 0), memory: &memory)
        let torn = N.normalized(F(title: "成都 带不走的 只有你", artist: "方大同/Billie Jean(Live)", album: "Timeless演唱会",
                                  duration: 292, elapsed: 0), memory: &memory)
        expectEqual(torn, previous, "iPad 网易云: title 是没报过的歌词也按上一首报")
        let newSong = F(title: "Billie Jean(Live)", artist: "方大同", album: "Timeless演唱会", duration: 292, elapsed: 0)
        expectEqual(N.normalized(newSong, memory: &memory), newSong, "iPad 网易云: 后面的真名帧原样")
    }

    // ---- 多位歌手:撕裂帧之后的真名帧 artist 本身带「/」,不当撕裂帧 ----
    do {
        var memory = N.Memory()
        let previous = F(title: "成都", artist: "赵雷", album: "成都", duration: 328, elapsed: 0)
        _ = N.normalized(previous, memory: &memory)
        _ = N.normalized(F(title: "作词: 赵雷", artist: "赵雷/成都", album: "成都", duration: 328, elapsed: 0), memory: &memory)
        let torn = N.normalized(F(title: "走到玉林路的尽头", artist: "Justice/Tame Impala/SZA/Flower In A Hurricane", album: "VI",
                                  duration: 224, elapsed: 0), memory: &memory)
        expectEqual(torn, previous, "iPad 网易云 多位歌手: 撕裂帧按上一首报")
        let newSong = F(title: "Flower In A Hurricane", artist: "Justice/Tame Impala/SZA", album: "VI", duration: 224, elapsed: 0)
        expectEqual(N.normalized(newSong, memory: &memory), newSong, "iPad 网易云 多位歌手: 紧跟着的真名帧原样")
    }

    // ---- 多位歌手、没有撕裂帧:真名帧先按上一首报,下一帧歌词帧把它认回来 ----
    do {
        var memory = N.Memory()
        let previous = F(title: "成都", artist: "赵雷", album: "成都", duration: 328, elapsed: 0)
        _ = N.normalized(previous, memory: &memory)
        _ = N.normalized(F(title: "作词: 赵雷", artist: "赵雷/成都", album: "成都", duration: 328, elapsed: 0), memory: &memory)
        let held = N.normalized(F(title: "Flower In A Hurricane", artist: "Justice/Tame Impala/SZA", album: "VI", duration: 224,
                                  elapsed: 0), memory: &memory)
        expectEqual(held, previous, "iPad 网易云 多位歌手: 分不出撕裂帧和真名帧时先按上一首报")
        var otherAlbum = memory
        expectEqual(N.normalized(F(title: "作曲: Justice", artist: "Justice/Tame Impala/SZA/Flower In A Hurricane", album: "Other",
                                   duration: 224, elapsed: 0), memory: &otherAlbum).title, "成都",
                    "iPad 网易云 多位歌手: 专辑不同的不认回上一帧")
        let lyric = N.normalized(F(title: "作曲: Justice", artist: "Justice/Tame Impala/SZA/Flower In A Hurricane", album: "VI",
                                   duration: 224, elapsed: 0), memory: &memory)
        expectEqual([lyric.title, lyric.artist], ["Flower In A Hurricane", "Justice/Tame Impala/SZA"],
                    "iPad 网易云 多位歌手: 下一帧歌词帧认回上一帧的真名")
        expectEqual(N.normalized(F(title: "作曲: Justice", artist: "Justice/Tame Impala/SZA/Flower In A Hurricane", album: "VI",
                                   duration: 224, elapsed: 0), memory: &memory).title, "Flower In A Hurricane",
                    "iPad 网易云 多位歌手: 这一帧再整理一次结果不变")
    }

    // ---- 锁屏歌词开着、没有撕裂帧:单个歌手的新歌真名帧原样 ----
    do {
        var memory = N.Memory()
        _ = N.normalized(F(title: "成都", artist: "赵雷", album: "成都", duration: 328, elapsed: 0), memory: &memory)
        _ = N.normalized(F(title: "作词: 赵雷", artist: "赵雷/成都", album: "成都", duration: 328, elapsed: 0), memory: &memory)
        let newSong = F(title: "Billie Jean(Live)", artist: "方大同", album: "Timeless演唱会", duration: 292, elapsed: 0)
        expectEqual(N.normalized(newSong, memory: &memory), newSong, "iPad 网易云: 单个歌手的新歌真名帧不按住")
    }

    // ---- 锁屏歌词关着(上一首没报过歌词帧):多位歌手的新歌原样 ----
    do {
        var memory = N.Memory()
        _ = N.normalized(F(title: "成都", artist: "赵雷", album: "成都", duration: 328, elapsed: 0), memory: &memory)
        _ = N.normalized(F(title: "成都", artist: "赵雷", album: "成都", duration: 328, elapsed: 80), memory: &memory)
        let newSong = F(title: "Flower In A Hurricane", artist: "Justice/Tame Impala/SZA", album: "VI", duration: 224, elapsed: 0)
        expectEqual(N.normalized(newSong, memory: &memory), newSong, "iPad 网易云 锁屏歌词关着: 多位歌手的新歌不按住")
    }

    // ---- 歌词撕裂帧之后直接是新歌的歌词帧:照「没记到真名」拆 ----
    do {
        var memory = N.Memory()
        _ = N.normalized(F(title: "阴天快乐", artist: "陈奕迅", album: "Rice & Shine", duration: 260, elapsed: 0), memory: &memory)
        _ = N.normalized(F(title: "那个酒窝", artist: "陈奕迅/阴天快乐", album: "Rice & Shine", duration: 260, elapsed: 79),
                         memory: &memory)
        _ = N.normalized(F(title: "那个酒窝", artist: "胡夏/同桌的你", album: "同桌的你", duration: 270, elapsed: 0), memory: &memory)
        let lyric = N.normalized(F(title: "作词: 高晓松", artist: "胡夏/同桌的你", album: "同桌的你", duration: 270, elapsed: 1),
                                 memory: &memory)
        expectEqual([lyric.title, lyric.artist], ["同桌的你", "胡夏"], "iPad 网易云: 没等到真名帧也拆得出新歌")
        let past = N.normalized(F(title: "那个酒窝", artist: "胡夏/同桌的你", album: "同桌的你", duration: 270, elapsed: 0.2),
                                memory: &memory)
        expectEqual(past.title, "同桌的你", "iPad 网易云: 歌词跟上一首重名的也按新歌还原")
    }

    // ---- 没记到真名(放到一半才开始读):连着两帧只有 title 在变才拆 ----
    do {
        var memory = N.Memory()
        let first = F(title: "第一句", artist: "Justice/Tame Impala/SZA/Flower In A Hurricane", album: "VI", duration: 200, elapsed: 50)
        expectEqual(N.normalized(first, memory: &memory), first, "iPad 网易云: 只见过一帧时认不出,原样")
        let second = N.normalized(F(title: "第二句", artist: "Justice/Tame Impala/SZA/Flower In A Hurricane", album: "VI",
                                    duration: 200, elapsed: 54), memory: &memory)
        expectEqual([second.title, second.artist], ["Flower In A Hurricane", "Justice/Tame Impala/SZA"],
                    "iPad 网易云: title 变了、歌手专辑时长都没变,按最后一个「/」拆")
        let third = N.normalized(F(title: "第三句", artist: "Justice/Tame Impala/SZA/Flower In A Hurricane", album: "VI",
                                   duration: 200, elapsed: 58), memory: &memory)
        expectEqual(third.title, "Flower In A Hurricane", "iPad 网易云: 拆出来的真名记下,后面的帧照它还原")
    }

    // ---- 冷启动 / 放到一半才开始读:头一份是歌词帧,第二份拆出真名,不当撕裂按住(录到的真实序列) ----
    do {
        var memory = N.Memory()
        let artist = "Imagine Dragons/JID/英雄联盟/双城之战"
        let title = "Enemy (from the series Arcane League of Legends) (动画剧集《英雄联盟：双城之战》全球主题曲)"
        let first = N.normalized(F(title: "（Look out for yourself）", artist: artist + "/" + title, album: "Enemy", duration: 173,
                                   elapsed: 0), memory: &memory)
        let second = N.normalized(F(title: "I wake up to the sounds of the silence that allows", artist: artist + "/" + title,
                                    album: "Enemy", duration: 173, elapsed: 7), memory: &memory)
        expectEqual([second.title, second.artist], [title, artist], "iPad 网易云 冷启动: 第二份歌词帧拆出真名")
        func fields(_ f: F) -> TornTrackHold.Fields {
            .init(title: f.title ?? "", artist: f.artist ?? "", album: f.album ?? "", bundle: mac, duration: f.duration ?? 0,
                  isRadio: false)
        }
        expectEqual(TornTrackHold.isTorn(current: fields(first), next: fields(second)), false,
                    "iPad 网易云 冷启动: 从歌词帧还原出的真名不当撕裂按住")
        expectEqual(TornTrackHold.isTorn(current: fields(F(title: "别的歌词", artist: "某人/另一首", album: "Enemy", duration: 173,
                                                            elapsed: 0)), next: fields(second)), true,
                    "iPad 网易云 冷启动: 上一份不是这一首的歌词帧时照旧按时长没跟上判")
        expectEqual(TornTrackHold.isTorn(current: fields(F(title: "（Look out for yourself）", artist: artist + "/" + title,
                                                            album: "Other", duration: 173, elapsed: 0)), next: fields(second)), true,
                    "iPad 网易云 冷启动: 专辑不同的不算这一首的歌词帧")
    }

    // ---- 锁屏歌词关着:多位歌手的「/」不拆 ----
    do {
        var memory = N.Memory()
        let a = F(title: "Flower In A Hurricane", artist: "Justice/Tame Impala/SZA", album: "VI", duration: 200, elapsed: 0)
        let b = F(title: "Flower In A Hurricane", artist: "Justice/Tame Impala/SZA", album: "VI", duration: 200, elapsed: 30)
        expectEqual([N.normalized(a, memory: &memory), N.normalized(b, memory: &memory)], [a, b], "iPad 网易云: 歌名不变就不当歌词模式")
    }

    // ---- 🅴 去掉 ----
    do {
        expectEqual(N.stripExplicitMark("im so blue for you 🅴"), "im so blue for you", "iPad 网易云: 末尾的 🅴 连空格去掉")
        expectEqual(N.stripExplicitMark("So Good🅴"), "So Good", "iPad 网易云: 没空格也去掉")
        expectEqual(N.stripExplicitMark("🅴 Intro"), "🅴 Intro", "iPad 网易云: 不在末尾的不动")
        var memory = N.Memory()
        let plain = N.normalized(F(title: "im so blue for you 🅴", artist: "zombiwebz", album: "im so blue for you", duration: 133,
                                   elapsed: 0), memory: &memory)
        expectEqual(plain.title, "im so blue for you", "iPad 网易云: 真名那一帧去掉 🅴")
        let lyric = N.normalized(F(title: "some line", artist: "zombiwebz/im so blue for you 🅴", album: "im so blue for you",
                                   duration: 133, elapsed: 3), memory: &memory)
        expectEqual([lyric.title, lyric.artist], ["im so blue for you", "zombiwebz"], "iPad 网易云: 歌词帧里「歌手/歌名」带 🅴 也认得")
    }

    // ---- 只读还原(封面载荷没有专辑、时长,不改状态) ----
    do {
        var memory = N.Memory()
        _ = N.normalized(F(title: "Billie Jean", artist: "Michael Jackson", album: "Thriller", duration: 293, elapsed: 0), memory: &memory)
        let before = memory
        let names = N.names(title: "编曲: Michael Jackson", artist: "Michael Jackson/Billie Jean", memory: memory)
        expectEqual([names.title, names.artist], ["Billie Jean", "Michael Jackson"], "iPad 网易云: 封面载荷按记住的真名还原")
        expectEqual(memory, before, "iPad 网易云: 只读还原不改状态")
        expectEqual(N.names(title: "X", artist: "Y", bundleID: mac).title, "X", "iPad 网易云: 别家的封面载荷原样")
    }

    // ---- 整份载荷 / 事件流的合并状态 ----
    do {
        N.resetForTesting()
        defer { N.resetForTesting() }
        let plain: [String: Any] = ["bundleIdentifier": N.bundleID, "title": "Billie Jean", "artist": "Michael Jackson",
                                    "album": "Thriller", "duration": 293.0, "elapsedTime": 0.0]
        _ = N.normalizedFields(plain)
        let lyric: [String: Any] = ["bundleIdentifier": N.bundleID, "title": "编曲: Michael Jackson",
                                    "artist": "Michael Jackson/Billie Jean", "album": "Thriller", "duration": 293.0, "elapsedTime": 1.0]
        let out = N.normalizedFields(lyric)
        expectEqual([out["title"] as? String, out["artist"] as? String], ["Billie Jean", "Michael Jackson"], "iPad 网易云: 事件流合并状态还原")
        let macLyric = F(title: "编曲: Michael Jackson", artist: "Michael Jackson/Billie Jean", album: "Thriller", duration: 293, elapsed: 2)
        expectEqual(N.normalized(macLyric, bundleID: mac), macLyric, "iPad 网易云: 别家报的帧原样(记着的真名不套到别家头上)")
        let other: [String: Any] = ["bundleIdentifier": mac, "title": "编曲: Michael Jackson", "artist": "Michael Jackson/Billie Jean"]
        expectEqual(N.normalizedFields(other)["title"] as? String, "编曲: Michael Jackson", "iPad 网易云: Mac 版的原样")
        let payload = try? JSONSerialization.data(withJSONObject: [
            "bundleIdentifier": N.bundleID, "title": "第二句", "artist": "Michael Jackson/Billie Jean", "album": "Thriller",
            "durationMicros": 293_000_000, "elapsedTimeMicros": 5_000_000,
        ])
        let rewritten = payload.map(N.normalizedPayload).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        expectEqual([rewritten?["title"] as? String, rewritten?["artist"] as? String], ["Billie Jean", "Michael Jackson"],
                    "iPad 网易云: 单问那一份的整份载荷改写")
        expectEqual((rewritten?["durationMicros"] as? NSNumber)?.int64Value, 293_000_000, "iPad 网易云: 微秒的时长键原样保留")
        let garbage = Data("null".utf8)
        expectEqual(N.normalizedPayload(garbage), garbage, "iPad 网易云: 解不开的载荷原样交回")
    }

    // ---- 开播只翻速率的差量晚约 0.45 秒:认出那一行、记下时间戳,进度 0 的那个锚点补提前量 ----
    do {
        N.resetForTesting()
        defer { N.resetForTesting() }
        let ts = "@1793154659900000", pausedTs = "@1793154658602000"
        let merged: [String: Any] = ["bundleIdentifier": N.bundleID, "title": "致你", "artist": "yihuik苡慧", "album": "致你",
                                     "duration": 200.0, "elapsedTime": 0.0, "timestamp": ts]
        let bare: [String: Any] = ["playbackRate": 1, "timestamp": ts]
        expectEqual(N.isBareStart(payload: bare, merged: merged), true, "iPad 网易云 开播: 只翻速率、进度 0 的差量认出来")
        var resumed = merged; resumed["elapsedTime"] = 9.04
        expectEqual(N.isBareStart(payload: bare, merged: resumed), false, "iPad 网易云 开播: 恢复播放(进度不是 0)不算")
        expectEqual(N.isBareStart(payload: ["playbackRate": 1, "timestamp": ts, "elapsedTime": 0.0], merged: merged), false,
                    "iPad 网易云 开播: 带着进度整帧报的不算")
        expectEqual(N.isBareStart(payload: ["playbackRate": 0, "timestamp": ts], merged: merged), false, "iPad 网易云 开播: 速率 0 不算")
        expectEqual(N.isBareStart(payload: ["playbackRate": 1], merged: merged), false, "iPad 网易云 开播: 没有时间戳不算")
        var macMerged = merged; macMerged["bundleIdentifier"] = mac
        expectEqual(N.isBareStart(payload: bare, merged: macMerged), false, "iPad 网易云 开播: Mac 版不算")

        var memory = N.Memory(bareStartTimestamp: ts)
        let start = F(title: "致你", artist: "yihuik苡慧", album: "致你", duration: 200, elapsed: 0, timestamp: ts)
        expectEqual(N.normalized(start, memory: &memory).elapsed, N.bareStartLead, "iPad 网易云 开播: 记下的那个锚点补提前量")
        expectEqual(N.normalized(start, memory: &memory).elapsed, N.bareStartLead, "iPad 网易云 开播: 再整理一次结果不变")
        var paused = start; paused.timestamp = pausedTs
        expectEqual(N.normalized(paused, memory: &memory).elapsed, 0, "iPad 网易云 开播: 别的时间戳(暂停那一帧)不补")
        var later = start; later.elapsed = 3.62
        expectEqual(N.normalized(later, memory: &memory).elapsed, 3.62, "iPad 网易云 开播: 同一时间戳进度不是 0 不补")
        expectEqual(N.bareStartLead > 0.4 && N.bareStartLead < 0.5, true, "iPad 网易云 开播: 提前量在实测 0.41~0.48 之间")

        // 事件流:暂停帧 → 只翻速率的差量;这一行的锚点身份带提前量,跟轮询整理出来的同一份。
        let fullLine = Data(("{\"type\":\"data\",\"diff\":false,\"payload\":{\"bundleIdentifier\":\"\(N.bundleID)\","
            + "\"title\":\"致你\",\"artist\":\"yihuik苡慧\",\"album\":\"致你\",\"playing\":false,\"playbackRate\":0,"
            + "\"elapsedTimeMicros\":0,\"timestampEpochMicros\":1793154658602000,\"durationMicros\":200000000}}").utf8)
        let arrival = Date(timeIntervalSince1970: 1793154659.95)
        let d1 = MediaControlStreamWatcher.digest(line: fullLine, merged: [:], arrivedAt: arrival)
        expectEqual(d1.anchorKey, MediaControlClient.anchorKey(artist: "yihuik苡慧", title: "致你", elapsedTime: 0, timestamp: pausedTs),
                    "iPad 网易云 开播: 暂停帧照原样")
        let bareLine = Data(("{\"type\":\"data\",\"diff\":true,\"payload\":{\"playbackRate\":1,"
            + "\"timestampEpochMicros\":1793154659900000,\"contentItemIdentifier\":\"x\"}}").utf8)
        let d2 = MediaControlStreamWatcher.digest(line: bareLine, merged: d1.merged, arrivedAt: arrival)
        expectEqual(d2.anchorKey, MediaControlClient.anchorKey(artist: "yihuik苡慧", title: "致你", elapsedTime: N.bareStartLead, timestamp: ts),
                    "iPad 网易云 开播: 差量那一行的锚点身份带提前量")
        expectEqual((d2.merged["elapsedTime"] as? NSNumber)?.doubleValue, 0, "iPad 网易云 开播: 合并状态里留原样")
        let fields = N.normalizedFields(d2.merged)
        expectEqual((fields["elapsedTime"] as? NSNumber)?.doubleValue, N.bareStartLead, "iPad 网易云 开播: 事件流合并状态补提前量")

        let payload = try? JSONSerialization.data(withJSONObject: [
            "bundleIdentifier": N.bundleID, "title": "致你", "artist": "yihuik苡慧", "album": "致你", "durationMicros": 200_000_000,
            "elapsedTimeMicros": 0, "elapsedTimeNowMicros": 120_000, "timestampEpochMicros": 1_793_154_659_900_000, "playbackRate": 1,
        ])
        let rewritten = payload.map(N.normalizedPayload).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        expectEqual((rewritten?["elapsedTimeMicros"] as? NSNumber)?.int64Value, 450_000, "iPad 网易云 开播: 单问载荷的进度补提前量")
        expectEqual((rewritten?["elapsedTimeNowMicros"] as? NSNumber)?.int64Value, 570_000, "iPad 网易云 开播: 外推的进度一起挪")

        var macFields = d2.merged; macFields["bundleIdentifier"] = mac
        expectEqual((N.normalizedFields(macFields)["elapsedTime"] as? NSNumber)?.doubleValue, 0, "iPad 网易云 开播: Mac 版的原样")
    }

    // ---- 接线契约 ----
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func sourceText(_ path: String) -> String {
            (try? String(contentsOfFile: root.appendingPathComponent(path).path, encoding: .utf8)) ?? ""
        }
        let client = sourceText("LyrimuseCore/Local/MediaControlClient.swift")
        expectEqual(sourceHas(client, "let names = NetEaseIPadNowPlaying.normalized("), true, "iPad 网易云 接线: 轮询那一路解码时整理")
        expectEqual(sourceHas(client, "var (keyTitle, keyArtist) = NetEaseIPadNowPlaying.names(title: raw.title, artist: raw.artist, bundleID: raw.bundleIdentifier)"),
                    true, "iPad 网易云 接线: 取封面那一路的曲目标识按真名算")
        let watcher = sourceText("LyrimuseCore/Local/MediaControlStreamWatcher.swift")
        expectEqual([sourceHas(watcher, "let identity = NetEaseIPadNowPlaying.normalizedFields(next)"),
                     sourceHas(watcher, "artist: identity[\"artist\"] as? String, title: identity[\"title\"] as? String,"),
                     sourceHas(watcher, "\"bundleIdentifier\", \"duration\", \"album\"] where payload.keys.contains(key) {")],
                    [true, true, true], "iPad 网易云 接线: 事件流判换歌、算锚点身份用整理过的,合并状态存专辑")
        expectEqual([sourceHas(client, "elapsed: times.elapsedTime, timestamp: times.timestamp),"),
                     sourceHas(client, "bundleID: bundleIdentifier, playing: playing, elapsed: names.elapsed,"),
                     sourceHas(client, "elapsedNow: times.elapsedTimeNow.map { $0 + lead }, rate: rate,"),
                     sourceHas(watcher, "NetEaseIPadNowPlaying.noteBareStart(timestamp: timestamp)"),
                     sourceHas(watcher, "let elapsed = (identity[\"elapsedTime\"] as? NSNumber)?.doubleValue")],
                    [true, true, true, true, true], "iPad 网易云 接线: 开播提前量轮询、事件流两路都用整理过的进度")
        let probe = sourceText("LyrimuseCore/Local/NowPlayingClientsProbe.swift")
        expectEqual([sourceHas(probe, "let data = NetEaseIPadNowPlaying.normalizedPayload(raw)"),
                     sourceHas(probe, "NetEaseIPadNowPlaying.names(title: decoded.title, artist: decoded.artist, bundleID: foundID)")],
                    [true, true], "iPad 网易云 接线: 单问会话、单问封面都整理")
        expectEqual([sourceHas(sourceText("LyrimuseCore/Local/PlayerProcess.swift"),
                               "let ids = PlayerBundleAliases.all(for: bundleID, includingOtherClients: false)"),
                     sourceHas(sourceText("lyrimuse/Settings/AccessibilityPermission.swift"),
                               "PlayerBundleAliases.isInstalled(player, includingOtherClients: false)"),
                     sourceHas(sourceText("lyrimuse/Settings/FullDiskAccessPermission.swift"),
                               "PlayerBundleAliases.isInstalled(player, includingOtherClients: false)")],
                    [true, true, true], "iPad 网易云 接线: 找进程、辅助功能和完全磁盘访问那两行不算它")
        expectEqual([sourceHas(client, "noteReportingClient(reportedBundleID, forBundleID: bundleID)"),
                     sourceHas(probe, "MediaControlClient.noteReportingClient(id, forBundleID: PlayerBundleAliases.canonical(id))"),
                     sourceHas(sourceText("LyrimuseCore/Local/LocalPlaybackSource.swift"),
                               "client: MediaControlClient.reportingClient(forBundleID: lastSnapshot?.bundleIdentifier))")],
                    [true, true, true], "iPad 网易云 接线: 轮询、单问都记下是谁报的,伺服按它决定对不对齐")
    }
}
