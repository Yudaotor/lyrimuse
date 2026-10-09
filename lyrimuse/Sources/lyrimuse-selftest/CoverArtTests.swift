import LyrimuseCore
import Foundation
import CoreGraphics
import ImageIO

// 封面取图 / 取色 / 高清替代。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runCoverArtTests() {
    // ---- 最近记录的封面兜底:合唱 credit 要能对上主歌手写法 ----
    //
    // 同一次收听以两种歌手写法存在:本机缓存 key 用播放器的逐曲 credit(`英雄联盟/Sara Skinner`),
    // Last.fm 那一行记主歌手(`英雄联盟`)。前两级查找(归一化 key 精确 / looseKey)都救不了 ——
    // looseKey 只把分隔符变体折成 `&`,不会把合唱者去掉。下面这批是出过问题的那一屏
    // (英雄联盟原声带)里真实的 key 与真实的行,逐条从缓存里抄出来的。
    do {
        typealias R = EnrichCacheReader
        let covers = [
            "Sebastien Najand/英雄联盟|PROJECT: Ashe|PROJECT: Ashe": "https://cover/ashe",
            "英雄联盟/Sara Skinner|Bring Home The Glory|Bring Home The Glory": "https://cover/glory",
            "英雄联盟/Against the Current|Legends Never Die|Legends Never Die": "https://cover/legends",
            "英雄联盟 & The Crystal Method|Senna, the Redeemer|Senna, the Redeemer": "https://cover/senna",
            "英雄联盟 & Mako & The Word Alive & The Glitch Mob|RISE|RISE": "https://cover/rise",
            "Edouard Brenneisen & 英雄联盟|Jhin, the Virtuoso|Jhin, the Virtuoso": "https://cover/jhin",
            // 对照:单人写法,本来就命中,这一级之前就该返回
            "Imagine Dragons|Warriors|Warriors (Official Anthem of League of Legends 2014 World Championship)": "https://cover/warriors",
            "英雄联盟|Aphelios, the Weapon of the Faithful|Aphelios, the Weapon of the Faithful": "https://cover/aphelios",
        ]
        let index = R.coverIndexByArtistTitle(covers)
        func cover(_ artist: String, _ title: String) -> String? {
            R.coverURLString(in: index, artist: artist, title: title)
        }
        // 截图里那 6 行(Last.fm 报的是主歌手写法)
        expectEqual(cover("Sebastien Najand", "PROJECT: Ashe"), "https://cover/ashe", "封面兜底: 斜杠合唱归主歌手")
        expectEqual(cover("英雄联盟", "Bring Home The Glory"), "https://cover/glory", "封面兜底: 主歌手在前的斜杠合唱")
        expectEqual(cover("英雄联盟", "Legends Never Die"), "https://cover/legends", "封面兜底: 同上,另一首")
        expectEqual(cover("英雄联盟", "Senna, the Redeemer"), "https://cover/senna", "封面兜底: & 号合唱")
        expectEqual(cover("英雄联盟", "RISE"), "https://cover/rise", "封面兜底: 四人 & 号合唱")
        // 大小写差异(行里是 The、缓存里是 the)由 artistTitleKey 折小写兜住
        expectEqual(cover("Edouard Brenneisen", "Jhin, The Virtuoso"), "https://cover/jhin", "封面兜底: 合唱 + 歌名大小写不一致")
        // 对照行不受影响
        expectEqual(cover("Imagine Dragons", "Warriors"), "https://cover/warriors", "封面兜底: 单人写法照旧命中")
        expectEqual(cover("英雄联盟", "Aphelios, the Weapon of the Faithful"), "https://cover/aphelios",
                    "封面兜底: 单人写法照旧命中(同一个主歌手下的另一首)")
        // 反方向:行里是完整合唱写法、缓存里只有主歌手 —— 查询侧也归并一次
        let single = R.coverIndexByArtistTitle(["Daniel Caesar|Toronto 2014|NEVER ENOUGH": "https://cover/toronto"])
        expectEqual(R.coverURLString(in: single, artist: "Daniel Caesar & Mustafa", title: "Toronto 2014"),
                    "https://cover/toronto", "封面兜底: 反方向(行是合唱、缓存是单人)也要命中")
        // 精确写法优先:别让合唱条目的图盖掉同名单人条目自己的图
        let both = R.coverIndexByArtistTitle([
            "英雄联盟|RISE|The Music of League of Legends": "https://cover/exact",
            "英雄联盟 & Mako|RISE|RISE": "https://cover/collab",
        ])
        expectEqual(R.coverURLString(in: both, artist: "英雄联盟", title: "RISE"), "https://cover/exact",
                    "封面兜底: 精确歌手写法优先于合唱别名")
        // K/DA 那类名字自带斜杠的不能被劈开(mergeArtist 已有守卫,这里守住它别被绕过)
        let kda = R.coverIndexByArtistTitle(["K/DA|POP/STARS|POP/STARS": "https://cover/kda"])
        expectEqual(R.coverURLString(in: kda, artist: "K/DA", title: "POP/STARS"), "https://cover/kda",
                    "封面兜底: K/DA 不会被斜杠劈成 K")

        // ---- coverAlbumVerified:「最近记录」第①级纠错的资格判定 ----
        // 例如陈奕迅《不如这样 (Live)》,Last.fm 行侧专辑写法与缓存 cover_album 在
        // 繁简/空格上系统性不一致,必须按 looseKey 口径比;而 cover_album 是错场次
        // (Get A Life)时绝不能给资格 —— 那正是这道闸要挡的东西。
        expectEqual(R.coverAlbumVerified(coverAlbum: "The Easy Ride 演唱会 (Live)",
                                         requestedAlbum: "The Easy Ride 演唱会 (Live)"), true,
                    "封面归属核实: 逐字相同")
        expectEqual(R.coverAlbumVerified(coverAlbum: "The Easy Ride 演唱会 (Live)",
                                         requestedAlbum: "The Easy Ride 演唱會 (Live)"), true,
                    "封面归属核实: 繁简写法不同也算同一张(looseKey 口径)")
        expectEqual(R.coverAlbumVerified(coverAlbum: "Get A Life (Live)",
                                         requestedAlbum: "The Easy Ride 演唱会 (Live)"), false,
                    "封面归属核实: 错场次的 cover_album 没有纠正资格")
        expectEqual(R.coverAlbumVerified(coverAlbum: nil,
                                         requestedAlbum: "The Easy Ride 演唱会 (Live)"), false,
                    "封面归属核实: 老条目没有 cover_album 字段时不给资格")
        expectEqual(R.coverAlbumVerified(coverAlbum: "The Easy Ride 演唱会 (Live)",
                                         requestedAlbum: ""), false,
                    "封面归属核实: 行侧没有专辑名时无从核实")
    }

    // ---- 封面第⑤级:Apple Music 目录匹配守卫 ----
    //
    // 前四级封面兜底里只有「本机 enrich 缓存」覆盖得了 Last.fm 对中文曲库缺图,而那一级只有
    // 本机播过才有数据 —— iPhone 听的歌、翻历史页看到的老歌天生在盲区里(实测抽样 205 首里
    // 25% 缺图,getinfo 只救回 20%、同专辑兄弟一张都救不到)。第⑤级去 iTunes Search 补。
    //
    // 这一组断言守的是「宁可留空位,也不挂错图」。实测:裸用搜索结果第一条会给
    // 《微醺卡带 - 情非得已 (微醺版)》配上《鱼翅Fin - 无声的告别是对往事的礼赞》的封面。
    do {
        typealias M = MusicCatalogSearch
        func item(_ artist: String, _ track: String, _ album: String,
                  art: String? = "https://is1.mzstatic.com/x/100x100bb.jpg") -> M.Item {
            M.Item(trackName: track, artistName: artist, collectionName: album,
                   trackViewUrl: nil, artistViewUrl: nil, collectionViewUrl: nil, artworkUrl100: art)
        }
        let 地表最强 = "周杰伦地表最强世界巡回演唱会 (Live)"

        // 100pt → 600pt;认不出尺寸段就原样(用小图也比没有强)
        expectEqual(M.upscaleArtwork("https://is1.mzstatic.com/x/100x100bb.jpg")?.absoluteString,
                    "https://is1.mzstatic.com/x/600x600bb.jpg", "封面⑤: 升到 600pt")
        expectEqual(M.upscaleArtwork("https://is1.mzstatic.com/x/64x64.jpg")?.absoluteString,
                    "https://is1.mzstatic.com/x/64x64.jpg", "封面⑤: 认不出尺寸段就原样")
        expectEqual(M.upscaleArtwork(nil) == nil, true, "封面⑤: 没有图就是 nil")

        // 歌手+歌名+专辑全对 → 高置信
        expectEqual(M.pickArtwork([item("周杰伦", "床边故事 (Live)", 地表最强)],
                                  title: "床边故事 (Live)", artist: "周杰伦", album: 地表最强)?.confidence,
                    .albumMatch, "封面⑤: 三项全对 = 高置信")
        // 繁简:Last.fm 那行常是「周杰倫」,iTunes 是「周杰伦」—— familyKey 的 ICU 折叠救回
        expectEqual(M.pickArtwork([item("周杰伦", "开不了口 (Live)", 地表最强)],
                                  title: "开不了口 (live)", artist: "周杰倫", album: 地表最强)?.confidence,
                    .albumMatch, "封面⑤: 繁简歌手名对得上")
        // 合唱 credit:查询侧是主歌手、目录侧带上了客串
        expectEqual(M.pickArtwork([item("周杰伦 & 派伟俊", "我要夏天 (Live)", 地表最强)],
                                  title: "我要夏天 (Live)", artist: "周杰伦", album: 地表最强)?.confidence,
                    .albumMatch, "封面⑤: 合唱 credit 归首位后对得上")

        // 挑选必须扫完候选、不能只看第一条。实测 30 首里有 5 首靠这一步纠正回正确那张
        //(《NOW YOU SEE ME (Live)》第一条是录音室版、《青花瓷 (Live)》第一条是魔天伦演唱会)。
        let mixed = [item("周杰伦", "青花瓷 (Live)", "魔天伦世界巡回演唱会 (Live)"),
                     item("周杰伦", "青花瓷 (Live)", 地表最强)]
        let picked = M.pickArtwork(mixed, title: "青花瓷 (Live)", artist: "周杰伦", album: 地表最强)
        expectEqual(picked?.confidence, .albumMatch, "封面⑤: 越过第一条去找专辑也对上的")
        expectEqual(picked?.matchedAlbum, 地表最强, "封面⑤: 挑中的确实是同一张专辑")

        // 专辑对不上但同曲 → 中置信(比空位强,但同屏可能不一致)
        expectEqual(M.pickArtwork([item("Beyond", "光辉岁月", "Beyond - 25th Anniversary")],
                                  title: "光辉岁月", artist: "Beyond", album: "BEYOND音乐大全 101")?.confidence,
                    .trackOnly, "封面⑤: 只有歌名歌手对上 = 中置信")

        // 这条是这一级存在的底线:匹配不上必须留空位,绝不退回搜索结果第一条
        expectEqual(M.pickArtwork([item("鱼翅Fin", "无声的告别是对往事的礼赞", "工作札记 - EP")],
                                  title: "情非得已 (微醺版)", artist: "微醺卡带",
                                  album: "情非得已（微醺版）") == nil,
                    true, "封面⑤: 完全不相干的结果必须留空位(实测踩到过这一条)")
        // Live 版不能拿录音室版的封面 —— familyKey 刻意不折 (Live) 这类版本副题
        expectEqual(M.pickArtwork([item("周杰伦", "美人鱼", "哎呦, 不错哦")],
                                  title: "美人鱼 (Live)", artist: "周杰伦", album: 地表最强) == nil,
                    true, "封面⑤: Live 版不匹配录音室版")
        // 目录学噪音(feat 客串署名)该折掉 —— 这类差异不是两份录音
        expectEqual(M.pickArtwork([item("Cailin Russo", "Phoenix (feat. Chrissy Costanza)", "Phoenix")],
                                  title: "Phoenix", artist: "Cailin Russo", album: "Phoenix")?.confidence,
                    .albumMatch, "封面⑤: feat 副题属目录学噪音,折掉后对得上")
        // 没有图的条目跳过,不能因为它占了第一条就放弃后面能用的
        expectEqual(M.pickArtwork([item("周杰伦", "床边故事 (Live)", 地表最强, art: nil),
                                   item("周杰伦", "床边故事 (Live)", 地表最强)],
                                  title: "床边故事 (Live)", artist: "周杰伦", album: 地表最强)?.confidence,
                    .albumMatch, "封面⑤: 跳过没有图的条目")
        expectEqual(M.pickArtwork([], title: "x", artist: "y", album: nil) == nil, true,
                    "封面⑤: 空结果集")
        // 行没有专辑名时(Last.fm 偶尔缺 album)退化成只按歌名歌手判,给中置信
        expectEqual(M.pickArtwork([item("周杰伦", "床边故事 (Live)", 地表最强)],
                                  title: "床边故事 (Live)", artist: "周杰伦", album: nil)?.confidence,
                    .trackOnly, "封面⑤: 行缺专辑名时退成中置信")

        // 没问成(限流 / 非 200 / 解不开)必须跟「问到了但没有」分开 —— 后者才进「那边没有」名单。
        func lookupKind(_ l: M.ArtworkLookup) -> String {
            switch l {
            case .found: return "found"
            case .noMatch: return "noMatch"
            case .unreached: return "unreached"
            }
        }
        let emptyBody = Data(#"{"results":[]}"#.utf8)
        let hitBody = Data(#"{"results":[{"trackName":"晴天","artistName":"周杰伦","collectionName":"叶惠美","artworkUrl100":"https://is1.mzstatic.com/x/100x100bb.jpg"}]}"#.utf8)
        expectEqual(lookupKind(M.artworkLookup(status: 429, data: emptyBody, title: "晴天", artist: "周杰伦", album: nil)),
                    "unreached", "封面⑤: 429 是没问成,不是那边没有")
        expectEqual(lookupKind(M.artworkLookup(status: 403, data: emptyBody, title: "晴天", artist: "周杰伦", album: nil)),
                    "unreached", "封面⑤: 403 是没问成")
        expectEqual(lookupKind(M.artworkLookup(status: nil, data: Data(), title: "晴天", artist: "周杰伦", album: nil)),
                    "unreached", "封面⑤: 没拿到响应是没问成")
        expectEqual(lookupKind(M.artworkLookup(status: 200, data: Data("<html>".utf8), title: "晴天", artist: "周杰伦", album: nil)),
                    "unreached", "封面⑤: 200 但解不开是没问成")
        expectEqual(lookupKind(M.artworkLookup(status: 200, data: emptyBody, title: "晴天", artist: "周杰伦", album: nil)),
                    "noMatch", "封面⑤: 200 空结果 = 那边没有")
        expectEqual(lookupKind(M.artworkLookup(status: 200, data: hitBody, title: "晴天", artist: "周杰伦", album: "叶惠美")),
                    "found", "封面⑤: 200 且对得上 = 命中")

        // 店面:系统地区在前,一条都搜不到才换下一个(中国区的 search 对任何歌都回 0 条)。
        expectEqual(M.storefronts(primary: "cn"), ["cn", "tw", "hk", "us"], "店面兜底: 中国区后面依次是台区、港区、美区")
        expectEqual(M.storefronts(primary: "US"), ["us", "tw", "hk"], "店面兜底: 系统地区不重复问、统一小写")
        expectEqual(M.storefronts(primary: "tw"), ["tw", "hk", "us"], "店面兜底: 台区用户")
        expectEqual(M.storefronts(primary: ""), ["tw", "hk", "us"], "店面兜底: 没有地区码")
        expectEqual(M.shouldTryNextStorefront(status: 200, data: emptyBody), true, "店面兜底: 一条都搜不到才换店面")
        expectEqual(M.shouldTryNextStorefront(status: 200, data: hitBody), false, "店面兜底: 有结果就不换(挑不出也不换)")
        expectEqual(M.shouldTryNextStorefront(status: 403, data: emptyBody), false, "店面兜底: 没问成不换,交给退避")
        expectEqual(M.shouldTryNextStorefront(status: 200, data: Data("<html>".utf8)), false, "店面兜底: 解不开不换")

        // 按专辑 ID lookup(Discord 状态缺公网封面时):只认 ID 对得上的那一项,升到 600 档。
        expectEqual(M.lookupURL(id: 1633408719, storefront: "cn")?.absoluteString,
                    "https://itunes.apple.com/lookup?id=1633408719&country=cn", "专辑封面 lookup: 请求地址")
        let albumBody = Data(#"{"resultCount":1,"results":[{"wrapperType":"collection","collectionId":1633408719,"collectionName":"最伟大的作品","artworkUrl100":"https://is1-ssl.mzstatic.com/x/100x100bb.jpg"}]}"#.utf8)
        let albumHit = M.albumArtworkLookup(status: 200, data: albumBody, albumID: 1633408719)
        expectEqual(albumHit.match?.url.absoluteString, "https://is1-ssl.mzstatic.com/x/600x600bb.jpg",
                    "专辑封面 lookup: ID 对得上,升到 600 档")
        expectEqual(albumHit.match?.confidence, .albumMatch, "专辑封面 lookup: 按 ID 查到的就是这张专辑")
        expectEqual(lookupKind(M.albumArtworkLookup(status: 200, data: albumBody, albumID: 1)), "noMatch",
                    "专辑封面 lookup: ID 对不上不认")
        expectEqual(lookupKind(M.albumArtworkLookup(status: 200, data: emptyBody, albumID: 1633408719)), "noMatch",
                    "专辑封面 lookup: 这个店面没有这张")
        expectEqual(lookupKind(M.albumArtworkLookup(status: 429, data: albumBody, albumID: 1633408719)), "unreached",
                    "专辑封面 lookup: 429 是没问成")

        // 按曲目 ID lookup(Apple Music 系统会话给的曲库曲目 ID):只认曲目 ID 对得上的那一项。
        let trackBody = Data(#"{"resultCount":1,"results":[{"wrapperType":"track","trackId":1633408818,"collectionId":1633408719,"trackName":"等你下课","collectionName":"最伟大的作品","artworkUrl100":"https://is1-ssl.mzstatic.com/y/100x100bb.jpg"}]}"#.utf8)
        expectEqual(M.trackArtworkLookup(status: 200, data: trackBody, trackID: 1633408818).match?.url.absoluteString,
                    "https://is1-ssl.mzstatic.com/y/600x600bb.jpg", "曲目封面 lookup: ID 对得上,升到 600 档")
        expectEqual(lookupKind(M.trackArtworkLookup(status: 200, data: trackBody, trackID: 1633408719)), "noMatch",
                    "曲目封面 lookup: 专辑 ID 不当曲目 ID")
        expectEqual(lookupKind(M.trackArtworkLookup(status: 503, data: trackBody, trackID: 1633408818)), "unreached",
                    "曲目封面 lookup: 503 是没问成")
        let trackWithArtist = Data(#"{"resultCount":1,"results":[{"wrapperType":"track","trackId":1633408818,"collectionName":"最伟大的作品","artistViewUrl":"https://music.apple.com/cn/artist/%E5%91%A8%E6%9D%B0%E4%BC%A6/300117743?uo=4","artworkUrl100":"https://is1-ssl.mzstatic.com/y/100x100bb.jpg"}]}"#.utf8)
        expectEqual(M.trackArtworkLookup(status: 200, data: trackWithArtist, trackID: 1633408818).match?.artistPage?.absoluteString,
                    "https://music.apple.com/cn/artist/%E5%91%A8%E6%9D%B0%E4%BC%A6/300117743",
                    "曲目封面 lookup: 顺带拿到歌手页,去掉 uo 参数")
        expectEqual(M.trackArtworkLookup(status: 200, data: trackBody, trackID: 1633408818).match?.artistPage, nil,
                    "曲目封面 lookup: 回包没有歌手页就不给")
        expectEqual(M.artistPageURL("http://music.apple.com/cn/artist/x/1"), nil, "歌手页: 只认 https")
        expectEqual(M.artistPageURL("https://itunes.apple.com/cn/artist/x/1"), nil, "歌手页: 只认 music.apple.com")
        expectEqual(M.artistPageURL("https://music.apple.com/cn/album/x/1"), nil, "歌手页: 不是歌手页不认")
    }

    // ---- 榜单专辑的本机封面兜底:「歌手 + 专辑」索引 ----
    do {
        typealias R = EnrichCacheReader
        let index = R.albumCoverIndex([
            (key: "陈柏宇|你瞒我瞒|Quinquennium (新曲+精选)", cover: "https://cover/unverified", coverAlbum: nil),
            (key: "陈柏宇|一事无成|Quinquennium (新曲+精选)", cover: "https://cover/verified", coverAlbum: "Quinquennium (新曲+精选)"),
            (key: "蔡徐坤 & 某某|Jasmine|KUN", cover: "https://cover/kun", coverAlbum: "KUN"),
            (key: "方大同|昙花|", cover: "https://cover/no-album", coverAlbum: nil),
        ])
        expectEqual(index[R.albumCoverKey(artist: "陳柏宇", album: "Quinquennium (新曲+精选)")], "https://cover/verified",
                    "专辑封面兜底: 繁简不同也对得上,同一张专辑优先核实过归属的那张")
        expectEqual(index[R.albumCoverKey(artist: "蔡徐坤", album: "kun")], "https://cover/kun",
                    "专辑封面兜底: 合唱署名按主歌手也能查到,专辑名大小写不算差异")
        expectEqual(index.values.contains("https://cover/no-album"), false, "专辑封面兜底: 没有专辑名的条目不进索引")
    }

    // ---- 两份封面索引的查找键:只跟缓存 key 有关,App 跨缓存版本记住 ----
    do {
        typealias R = EnrichCacheReader
        expectEqual(R.titleCoverKeys("英雄联盟/Sara Skinner|Bring Home The Glory|Bring Home The Glory"),
                    R.CoverIndexKeys(exact: R.artistTitleKey(artist: "英雄联盟/Sara Skinner", title: "Bring Home The Glory"),
                                     alias: R.artistTitleKey(artist: "英雄联盟", title: "Bring Home The Glory")),
                    "封面索引键: 合唱写法另带一个主歌手别名键")
        expectEqual(R.titleCoverKeys("Imagine Dragons|Warriors|Warriors")?.alias == nil, true, "封面索引键: 单人写法没有别名键")
        expectEqual(R.titleCoverKeys("不是三段") == nil, true, "封面索引键: 不是三段的 key 不进索引")
        expectEqual(R.albumCoverKeys("蔡徐坤 & 某某|Jasmine|KUN"),
                    R.CoverIndexKeys(exact: R.albumCoverKey(artist: "蔡徐坤 & 某某", album: "KUN"),
                                     alias: R.albumCoverKey(artist: "蔡徐坤", album: "KUN")),
                    "专辑封面索引键: 合唱写法另带一个主歌手别名键")
        expectEqual(R.albumCoverKeys("方大同|昙花|") == nil, true, "专辑封面索引键: 没有专辑名的不进索引")

        let covers = [
            "英雄联盟|RISE|The Music of League of Legends": "https://cover/exact",
            "英雄联盟 & Mako|RISE|RISE": "https://cover/collab",
            "Edouard Brenneisen & 英雄联盟|Jhin, the Virtuoso|Jhin, the Virtuoso": "https://cover/jhin",
            "K/DA|POP/STARS|POP/STARS": "https://cover/kda",
        ]
        var titleMemo: [String: R.CoverIndexKeys] = [:]
        var derived = 0
        let memoTitleKeys: (String) -> R.CoverIndexKeys? = { key in
            if let v = titleMemo[key] { return v }
            derived += 1
            guard let v = R.titleCoverKeys(key) else { return nil }
            titleMemo[key] = v
            return v
        }
        expectEqual(R.coverIndexByArtistTitle(covers, keys: memoTitleKeys), R.coverIndexByArtistTitle(covers),
                    "封面索引: 带记忆建出来跟现算一样")
        let afterFirst = derived
        expectEqual(afterFirst, covers.count, "封面索引: 第一次建时每条 key 都经传进来的函数算一次")
        _ = R.coverIndexByArtistTitle(covers, keys: memoTitleKeys)
        expectEqual(derived, afterFirst, "封面索引: 再建一次全部命中记忆,不再现算")

        let rows: [(key: String, cover: String, coverAlbum: String?)] = [
            (key: "陈柏宇|你瞒我瞒|Quinquennium (新曲+精选)", cover: "https://cover/unverified", coverAlbum: nil),
            (key: "陈柏宇|一事无成|Quinquennium (新曲+精选)", cover: "https://cover/verified", coverAlbum: "Quinquennium (新曲+精选)"),
            (key: "蔡徐坤 & 某某|Jasmine|KUN", cover: "https://cover/kun", coverAlbum: "KUN"),
        ]
        var albumMemo: [String: R.CoverIndexKeys] = [:]
        var looseMemo: [String: String] = [:]
        var looseDerived = 0
        let memoAlbumKeys: (String) -> R.CoverIndexKeys? = { key in
            if let v = albumMemo[key] { return v }
            guard let v = R.albumCoverKeys(key) else { return nil }
            albumMemo[key] = v
            return v
        }
        let memoLoose: (String) -> String = { s in
            if let v = looseMemo[s] { return v }
            looseDerived += 1
            let v = EnrichCacheKeys.looseKey(s)
            looseMemo[s] = v
            return v
        }
        expectEqual(R.albumCoverIndex(rows, keys: memoAlbumKeys, looseKey: memoLoose), R.albumCoverIndex(rows),
                    "专辑封面索引: 带记忆建出来跟现算一样(含核实归属那一条)")
        let looseAfterFirst = looseDerived
        expectEqual(looseAfterFirst > 0, true, "专辑封面索引: 核实归属用的是传进来的 looseKey")
        _ = R.albumCoverIndex(rows, keys: memoAlbumKeys, looseKey: memoLoose)
        expectEqual(looseDerived, looseAfterFirst, "专辑封面索引: 再建一次核实归属也全部命中记忆")

        // 契约:App 建这两份索引时传的是带记忆的那几份(每写一次盘就整份重建,现算要在主线程上做一遍繁简转换)
        let reader = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("LyrimuseCore/Local/EnrichCacheReader.swift"),
            encoding: .utf8)) ?? ""
        expectEqual(reader.contains("Self.coverIndexByArtistTitle(covers, keys: memoizedTitleCoverKeys)"), true,
                    "封面索引(契约): 歌名索引带记忆建")
        expectEqual(reader.contains("Self.albumCoverIndex(rows, keys: memoizedAlbumCoverKeys, looseKey: memoizedNameLooseKey)"), true,
                    "封面索引(契约): 专辑索引带记忆建")
    }

    // ---- iTunes Search 限流退避(口径同引擎 apple.go noteITunesSearchStatus) ----
    do {
        typealias B = ITunesSearchBackoff
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        expectEqual(B.until(status: 429, retryAfter: "120", now: t0, current: nil),
                    t0.addingTimeInterval(120), "iTunes 退避: 429 认 Retry-After")
        expectEqual(B.until(status: 429, retryAfter: nil, now: t0, current: nil),
                    t0.addingTimeInterval(B.retryAfterDefault), "iTunes 退避: 429 没给头用默认值")
        expectEqual(B.until(status: 429, retryAfter: "86400", now: t0, current: nil),
                    t0.addingTimeInterval(B.retryAfterMax), "iTunes 退避: Retry-After 封顶")
        expectEqual(B.until(status: 403, retryAfter: nil, now: t0, current: nil),
                    t0.addingTimeInterval(B.forbiddenCooldown), "iTunes 退避: 403 固定档")
        expectEqual(B.until(status: 403, retryAfter: nil, now: t0, current: t0.addingTimeInterval(200)),
                    t0.addingTimeInterval(200), "iTunes 退避: 403 不缩短已有的更长窗口")
        expectEqual(B.until(status: 200, retryAfter: nil, now: t0, current: t0.addingTimeInterval(200)) == nil,
                    true, "iTunes 退避: 正常响应清掉窗口")

        let gate = ITunesSearchGate()
        gate.note(status: 429, retryAfter: "60", now: t0)
        expectEqual(gate.coolingDown(now: t0.addingTimeInterval(59)), true, "iTunes 退避: 窗口内不发")
        expectEqual(gate.coolingDown(now: t0.addingTimeInterval(61)), false, "iTunes 退避: 窗口过了恢复")
        gate.note(status: 429, retryAfter: "60", now: t0)
        gate.note(status: 200, retryAfter: nil, now: t0.addingTimeInterval(1))
        expectEqual(gate.coolingDown(now: t0.addingTimeInterval(2)), false, "iTunes 退避: 拿到正常响应立即恢复")
    }

    // ---- App 与引擎共享的限流窗口(口径同引擎 sharedcooldown.go) ----
    do {
        typealias O = OutboundCooldowns
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let merged = O.merge(["old": 999_000, "keep": 1_000_500, "k": 1_000_300],
                             key: "k", until: t0.addingTimeInterval(100), now: t0)
        expectEqual(merged["old"] == nil, true, "共享窗口: 过期条目写入时清掉")
        expectEqual(merged["keep"], 1_000_500, "共享窗口: 别的没过期条目留着")
        expectEqual(merged["k"], 1_000_300, "共享窗口: 已有更晚的截止时刻不缩短")
        expectEqual(O.merge([:], key: "k", until: t0.addingTimeInterval(900), now: t0)["k"], 1_000_900,
                    "共享窗口: 新条目写入")
        expectEqual(O.until(["k": 1_000_100], key: "k", now: t0), Date(timeIntervalSince1970: 1_000_100),
                    "共享窗口: 没过期读得到")
        expectEqual(O.until(["k": 999_999], key: "k", now: t0) == nil, true, "共享窗口: 过期读不到")
        // 引擎写的 JSON(Go 的 map[string]float64)要解得开。
        let goJSON = Data(#"{"endpoints":{"itunes.apple.com/search":1790253000.5}}"#.utf8)
        expectEqual(O.decode(goJSON)[O.itunesSearchKey], 1790253000.5, "共享窗口: 解得开引擎写的文件")
        expectEqual(O.decode(Data("garbage".utf8)).isEmpty, true, "共享窗口: 坏文件当空")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrimuse-selftest-cooldowns-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = OutboundCooldownStore(url: dir.appendingPathComponent(O.fileName))
        let now = Date()
        let gate = ITunesSearchGate(store: store)
        expectEqual(gate.coolingDown(now: now), false, "共享窗口: 文件不存在时不算冷却")
        // 引擎写进来的窗口:App 的 gate 也要认。
        let other = OutboundCooldownStore(url: dir.appendingPathComponent(O.fileName))
        other.publish(O.itunesSearchKey, until: now.addingTimeInterval(60), now: now)
        let fresh = ITunesSearchGate(store: OutboundCooldownStore(url: dir.appendingPathComponent(O.fileName)))
        expectEqual(fresh.coolingDown(now: now), true, "共享窗口: 另一个进程写的 iTunes 窗口也算冷却中")
        // App 自己撞到的 429 写进去,另一个读者看得见。
        let writerGate = ITunesSearchGate(store: store)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(O.fileName))
        writerGate.note(status: 429, retryAfter: "120", now: now)
        let reader = OutboundCooldownStore(url: dir.appendingPathComponent(O.fileName))
        expectEqual(reader.activeUntil(O.itunesSearchKey, now: now) != nil, true,
                    "共享窗口: App 撞到的限流写进共享文件")
    }

    // ---- 封面取色:HSB 提亮 + 压饱和 ----
    do {
        func accent(_ r: Double, _ g: Double, _ b: Double) -> (r: Double, g: Double, b: Double) {
            LocalPlaybackSource.brightenedAccent(r: r, g: g, b: b)
        }
        func brightness(_ c: (r: Double, g: Double, b: Double)) -> Double { max(c.r, max(c.g, c.b)) }
        func saturation(_ c: (r: Double, g: Double, b: Double)) -> Double {
            let mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b))
            return mx <= 0 ? 0 : (mx - mn) / mx
        }

        // 近黑封面：不再从压缩噪点里"抢救"色相 —— 旧实现会把 (2,1,3)/255 放大 11 倍，
        // 同一张黑封面每次取到的颜色都不一样。
        let nearBlack = accent(2/255, 1/255, 3/255)
        expectEqual(saturation(nearBlack) < 0.01, true, "取色: 近黑封面兜底成中性灰(无色相)")
        expectEqual(accent(0, 0, 0) == accent(2/255, 1/255, 3/255), true,
                    "取色: 近黑结果稳定,不随噪点变化")

        // 够亮的颜色原样放行。
        let bright = accent(0.9, 0.4, 0.4)
        expectEqual(bright.r == 0.9 && bright.g == 0.4, true, "取色: 亮度够就不动它")

        // 暗色被提到下限；关键是饱和度**同时**被按比例压低（旧实现只提亮、饱和度不变，刺眼）。
        let darkRed = accent(0.30, 0.02, 0.02)
        expectEqual(abs(brightness(darkRed) - 0.62) < 0.001, true, "取色: 暗色提亮到下限 0.62")
        expectEqual(saturation(darkRed) < saturation((r: 0.30, g: 0.02, b: 0.02)), true,
                    "取色: 提亮的同时压低饱和度(不刺眼)")

        // 色相必须守住：暗红提亮后仍是红,不能变色。
        expectEqual(darkRed.r > darkRed.g && darkRed.r > darkRed.b, true, "取色: 色相不漂移(红仍是红)")
        let darkBlue = accent(0.02, 0.05, 0.30)
        expectEqual(darkBlue.b > darkBlue.r && darkBlue.b > darkBlue.g, true, "取色: 蓝仍是蓝")
        let darkGreen = accent(0.03, 0.28, 0.05)
        expectEqual(darkGreen.g > darkGreen.r && darkGreen.g > darkGreen.b, true, "取色: 绿仍是绿")

        // 灰(无色相)提亮后仍是灰,不能凭空生出颜色。
        let darkGray = accent(0.2, 0.2, 0.2)
        expectEqual(saturation(darkGray) < 0.01, true, "取色: 灰提亮后仍是灰")

        // 全区间扫描：输出永远在 [0,1]，且亮度不低于下限。
        var bad = 0
        for i in 0 ... 20 {
            for j in 0 ... 20 {
                let c = accent(Double(i) / 20, Double(j) / 20, 0.5)
                if c.r < 0 || c.r > 1 || c.g < 0 || c.g > 1 || c.b < 0 || c.b > 1 { bad += 1 }
                if brightness(c) < 0.61 { bad += 1 }
            }
        }
        expectEqual(bad, 0, "取色: 全区间扫描输出合法且亮度达标")
    }

    // ---- 封面取色:深色背景的感知亮度地板(灵动岛) ----
    // brightenedAccent 保的是 HSB brightness(RGB 最大分量),但人眼三通道敏感度差一个
    // 数量级——饱和纯蓝 brightness 满格、luma 只有 0.07,原样过 0.62 的地板,贴在灵动岛
    // 的深色背景上区分度差。accentForDarkBackdrop 在其结果之上再保一道 Rec.709 luma 下限。
    do {
        func lift(_ r: Double, _ g: Double, _ b: Double) -> (r: Double, g: Double, b: Double) {
            LocalPlaybackSource.accentForDarkBackdrop(r: r, g: g, b: b)
        }
        func luma(_ c: (r: Double, g: Double, b: Double)) -> Double {
            0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        }

        // 动机本尊:纯蓝(HSB 亮度满格,旧地板完全不管)必须被提到感知亮度地板,
        // 且提亮走"混白"方向——蓝仍是最大分量(色相族不变),红绿等量上浮(不偏色)。
        let blue = lift(0, 0, 1)
        expectEqual(abs(luma(blue) - 0.62) < 0.001, true, "深背景取色: 纯蓝恰好提到 luma 地板")
        expectEqual(blue.b > blue.r && abs(blue.r - blue.g) < 0.001, true,
                    "深背景取色: 混白提亮,蓝仍是蓝且不偏色")

        // 已经够亮的原样放行——暖色/浅色封面(luma 本来就高)一动不动。
        let warm = lift(0.9, 0.7, 0.4)
        expectEqual(warm == (r: 0.9, g: 0.7, b: 0.4), true, "深背景取色: luma 够高就一动不动")
        expectEqual(lift(1, 1, 1) == (r: 1.0, g: 1.0, b: 1.0), true, "深背景取色: 纯白不动(不除零)")

        // 全区间扫描:输出永远在 [0,1],且 luma 不低于地板。
        var bad = 0
        for i in 0 ... 20 {
            for j in 0 ... 20 {
                for k in [0.0, 0.25, 0.5, 0.75, 1.0] {
                    let c = lift(Double(i) / 20, Double(j) / 20, k)
                    if c.r < 0 || c.r > 1 || c.g < 0 || c.g > 1 || c.b < 0 || c.b > 1 { bad += 1 }
                    if luma(c) < 0.619 { bad += 1 }
                }
            }
        }
        expectEqual(bad, 0, "深背景取色: 全区间扫描输出合法且 luma 达标")
    }

    // ---- 封面取图:载荷曲目标识比对 ----
    //
    // 现象是网易云云盘歌"沿用上一首的封面":切歌瞬间 get --now 可能整条还是上一首(旧标题+
    // 旧封面),原实现拿到非 nil 就定案,把上一首的封面错挂到新歌上。修法是封面载荷带上自己的
    // artist/title 算 trackKey,跟当前曲目对不上就按"系统侧还没更新完"重试。
    do {
        // 推导必须跟快照那份逐字符一致——两处各写一份的话,一旦漂移,每首歌都会被误判成
        // "别的歌的封面"而永远显示占位。
        expectEqual(MediaControlSnapshot.trackKey(artist: "周杰伦", title: "以父之名"),
                    "周杰伦|以父之名", "封面标识: trackKey 推导 artist|title")
        expectEqual(MediaControlSnapshot.trackKey(artist: nil, title: nil), "|",
                    "封面标识: 字段缺失时退化为空段,不崩")

        expectEqual(LocalPlaybackSource.artworkKeyMatches("周杰伦|以父之名", "周杰伦|以父之名"),
                    true, "封面标识: 同一首歌匹配")
        expectEqual(LocalPlaybackSource.artworkKeyMatches("周杰伦|以父之名", "周杰伦|一路向北"),
                    false, "封面标识: 上一首的载荷必须判不匹配")
        // 大小写不敏感:media-control 对同一首歌报过大小写不一致的元数据("2 Bad"/"Scream"
        // 在 enrich 缓存踩过同源的坑),按敏感比对会把这类歌误判成别的歌、永远显示占位。
        expectEqual(LocalPlaybackSource.artworkKeyMatches("Michael Jackson|2 BAD", "Michael Jackson|2 Bad"),
                    true, "封面标识: 大小写偏差算同一首")
    }

    // ---- 封面取色:桌面悬浮歌词按"跟描边够对比"调 ----
    //
    // 这一组是为一次真实回归补的:08-16 把近黑封面兜底成 0.72 浅灰(为灵动岛的深色背景调的),
    // 桌面悬浮歌词一起吃了这条规则,用户又开着不透明白描边 —— 浅灰字被白描边吃掉,压在浅色
    // 窗口上几乎看不见(实测屏幕上最暗的不透明像素 #ADABA6,相对亮度 0.671,而描边是纯白)。
    // 所以这里断言的核心不是"输出多亮",而是**输出跟描边的对比度达标**,以及"本来就达标的
    // 颜色一动不动"——后者才是"别擅自改用户看惯的颜色"这条约束。
    do {
        func fit(_ c: (Double, Double, Double), stroke: (Double, Double, Double),
                 minContrast: Double = 3.0) -> (r: Double, g: Double, b: Double) {
            LocalPlaybackSource.accentAgainstStroke(
                r: c.0, g: c.1, b: c.2,
                strokeR: stroke.0, strokeG: stroke.1, strokeB: stroke.2,
                minContrast: minContrast)
        }
        func lum(_ c: (r: Double, g: Double, b: Double)) -> Double {
            LocalPlaybackSource.relativeLuminance(r: c.r, g: c.g, b: c.b)
        }
        func contrastWith(_ c: (r: Double, g: Double, b: Double),
                          _ stroke: (Double, Double, Double)) -> Double {
            LocalPlaybackSource.contrastRatio(
                lum(c), LocalPlaybackSource.relativeLuminance(r: stroke.0, g: stroke.1, b: stroke.2))
        }

        let white = (1.0, 1.0, 1.0)
        let black = (0.0, 0.0, 0.0)

        // 动机本尊:0.72 中性灰 + 不透明白描边,正是用户屏幕上那一幕。必须被压暗到达标。
        let grey = fit((0.72, 0.72, 0.72), stroke: white)
        expectEqual(contrastWith(grey, white) >= 2.99, true, "描边取色: 浅灰配白描边被压到达标")
        expectEqual(lum(grey) < LocalPlaybackSource.relativeLuminance(r: 0.72, g: 0.72, b: 0.72),
                    true, "描边取色: 白描边下是往暗的方向调")

        // 近黑封面:噪点色相要被抹掉(三通道相等),但"它很暗"这个真信息要保留 ——
        // 不能像 brightenedAccent 那样连亮度一起换成固定浅灰。配白描边时本来就够对比,不动。
        let nearBlack = fit((2 / 255.0, 1 / 255.0, 3 / 255.0), stroke: white)
        expectEqual(abs(nearBlack.r - nearBlack.g) < 1e-9 && abs(nearBlack.g - nearBlack.b) < 1e-9,
                    true, "描边取色: 近黑抹掉噪点色相变中性灰")
        expectEqual(nearBlack.r < 0.03, true, "描边取色: 近黑保留自己的暗度,不被抬成浅灰")

        // 够对比的颜色一动不动 —— 绝大多数封面走这条,不该擅自改色。
        let deep = (0.15, 0.10, 0.30)
        let untouched = fit(deep, stroke: white)
        expectEqual(untouched == (r: deep.0, g: deep.1, b: deep.2), true,
                    "描边取色: 已经够对比就原样返回")

        // 描边反过来是黑的:该往亮的方向调,而不是继续压暗。
        let darkOnBlack = fit((0.12, 0.10, 0.08), stroke: black)
        expectEqual(contrastWith(darkOnBlack, black) >= 2.99, true, "描边取色: 暗色配黑描边被提亮到达标")
        expectEqual(lum(darkOnBlack) > LocalPlaybackSource.relativeLuminance(r: 0.12, g: 0.10, b: 0.08),
                    true, "描边取色: 黑描边下是往亮的方向调")

        // 两侧都够不到时取端点里更好的那个,而不是返回一个"差一点点"的中间值。
        //
        // 默认的 3.0 **触发不到**这条分支:要两侧都够不到得同时满足 sl < 0.05(mc−1) 和
        // sl > 1.05/mc − 0.05,有解的条件是 mc > √21 ≈ 4.58。所以这里显式传 7.0 去测那条
        // 分支,别改回默认值——改回去这个断言会退化成在测另一条路径。
        let midStroke = (0.5, 0.5, 0.5)
        let onMid = fit((0.55, 0.52, 0.50), stroke: midStroke, minContrast: 7.0)
        let bestEndpoint = max(contrastWith((r: 0, g: 0, b: 0), midStroke),
                               contrastWith((r: 1, g: 1, b: 1), midStroke))
        expectEqual(abs(contrastWith(onMid, midStroke) - bestEndpoint) < 0.01, true,
                    "描边取色: 够不到目标时取对比更好的端点")

        // 优先方向"差一点点"够不到边界时,贴边界收下这个近似值,不要为了凑够数值目标
        // 翻到对面走极端(灵动岛「封面偏白、歌词却是全黑,太突兀」)。这是
        // `accentAgainstStroke` 这一层用手算数字验证的最小单元测试——完整链路(带真实
        // 封面均值色、走 accentForCoverArtBackground)的回归见下面"红豆"那组,那组数字
        // 才是从真实播放场景量出来的,这里只是同一条判据在更干净的数字上再验一遍。
        // 往亮的方向(preferUp)贴纯白能到对比度 4.42,是 minContrast=4.5 的 98%;
        // 翻到暗的方向能精确拿到 4.5,但代价是把亮色文字砸成近乎纯黑——旧逻辑会翻,
        // 这里断言修复后**不翻**,亮度留在描边之上(跟候选色原本同一侧)。跟上面
        // mid-gray 反例的区别是"贴边界离目标够不够近"——那边只能贴到目标的 57%,这边
        // 能贴到 98%,两条判据(过 3.0 基线 + 达到 80% 目标)只在这边同时成立。
        let paleStroke = (0.47, 0.47, 0.47)
        let paleCandidate = (0.85, 0.85, 0.85)
        let onPale = fit(paleCandidate, stroke: paleStroke, minContrast: 4.5)
        expectEqual(lum(onPale) > lum((r: paleStroke.0, g: paleStroke.1, b: paleStroke.2)), true,
                    "描边取色: 优先方向差一点点够不到边界时不翻到对面,亮度留在描边之上")
        expectEqual(contrastWith(onPale, paleStroke) >= 4.2, true,
                    "描边取色: 贴边界收下的近似值本身仍然接近达标,不是随手一个数")

        // 全区间扫描:输出永远合法,且只要目标可达就一定达标。
        var bad = 0, unreachable = 0
        for si in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let stroke = (si, si, si)
            let sl = LocalPlaybackSource.relativeLuminance(r: si, g: si, b: si)
            // 目标可达 = 黑或白至少有一个能跟这个描边拉到 3.0。
            let reachable = max(LocalPlaybackSource.contrastRatio(sl, 0),
                                LocalPlaybackSource.contrastRatio(sl, 1)) >= 3.0
            for i in 0 ... 12 {
                for j in 0 ... 12 {
                    for k in [0.0, 0.5, 1.0] {
                        let c = fit((Double(i) / 12, Double(j) / 12, k), stroke: stroke)
                        if c.r < 0 || c.r > 1 || c.g < 0 || c.g > 1 || c.b < 0 || c.b > 1 { bad += 1 }
                        if reachable, contrastWith(c, stroke) < 2.99 { unreachable += 1 }
                    }
                }
            }
        }
        expectEqual(bad, 0, "描边取色: 全区间扫描输出在 [0,1] 内")
        expectEqual(unreachable, 0, "描边取色: 全区间扫描只要够得到就一定达标")
    }

    // ---- 封面取色:灵动岛 coverArt 卡片风格按"跟背景够对比"调 ----
    //
    // 这一组是为一次真实回归补的:现象是灵动岛歌词跟背景对比度太低看不清——方大同
    // 《Run From Your Love》专辑《JTW 西游记 (Gold)》那张黄底封面,均值色 #BBA45E
    // (下面这组数字直接从真实封面文件量出来,不是编的)。accentForDarkBackdrop 只保证
    // 文字**绝对**亮度地板(luma≥0.62),这张封面的均值原本就已经在地板之上、不会被再提亮;
    // 而 coverArt 背景 = 这份原始色 ×(1-0.45)(NotchLyricsView.backgroundLayer 的黑叠加),
    // 亮度是**跟着源色走**的,不是恒定的暗——同一份源色叠出来的背景实测 luma 只有 0.355,
    // 跟没被动过的文字色一对比,WCAG 对比度只有 2.78,连大号文字门槛(3.0)都够不到。
    do {
        // 从真实封面(https://p2.music.126.net/.../109951171530573358.jpg,方大同&FiFi Rong
        // 《Run From Your Love》所在专辑)量出来的均值色,CIAreaAverage 口径(全图算术平均)。
        let realCoverRGB = (r: 0.734, g: 0.646, b: 0.372) // #BBA45E

        // 回归的起点:走完 brightenedAccent → accentForDarkBackdrop 这两步"假设背景永远暗"
        // 的旧逻辑,均值本来就够亮,两步都是无操作,candidateBeforeFix 就是原始均值色本身。
        let step1 = LocalPlaybackSource.brightenedAccent(
            r: realCoverRGB.r, g: realCoverRGB.g, b: realCoverRGB.b)
        let candidateBeforeFix = LocalPlaybackSource.accentForDarkBackdrop(
            r: step1.r, g: step1.g, b: step1.b)
        expectEqual(candidateBeforeFix == realCoverRGB, true,
                    "coverArt 取色: 均值本来就够亮,旧两步地板对这张封面都是无操作(回归的前提)")

        let dim = 1 - LocalPlaybackSource.notchCoverArtOverlayOpacity
        let approxBackground = (r: realCoverRGB.r * dim, g: realCoverRGB.g * dim, b: realCoverRGB.b * dim)
        let contrastBeforeFix = LocalPlaybackSource.contrastRatio(
            LocalPlaybackSource.relativeLuminance(r: candidateBeforeFix.r, g: candidateBeforeFix.g, b: candidateBeforeFix.b),
            LocalPlaybackSource.relativeLuminance(r: approxBackground.r, g: approxBackground.g, b: approxBackground.b))
        expectEqual(abs(contrastBeforeFix - 2.78) < 0.02, true,
                    "coverArt 取色: 复现回归——旧逻辑对这张封面的对比度只有 2.78(用户看不清的实测依据)")

        // 修复本尊:再叠一步 accentForCoverArtBackground,必须真的达标(默认门槛 4.5,
        // 灵动岛字号 9~13.5pt 按 WCAG 够不上大号文字那档)。
        let fixed = LocalPlaybackSource.accentForCoverArtBackground(
            r: candidateBeforeFix.r, g: candidateBeforeFix.g, b: candidateBeforeFix.b,
            rawR: realCoverRGB.r, rawG: realCoverRGB.g, rawB: realCoverRGB.b)
        let contrastAfterFix = LocalPlaybackSource.contrastRatio(
            LocalPlaybackSource.relativeLuminance(r: fixed.r, g: fixed.g, b: fixed.b),
            LocalPlaybackSource.relativeLuminance(r: approxBackground.r, g: approxBackground.g, b: approxBackground.b))
        expectEqual(contrastAfterFix >= 4.49, true,
                    "coverArt 取色: 修复后跟背景的对比度必须达到 4.5 门槛")

        // 色相族不能丢——沿"混白"方向调,黄还是黄,不能被拉去别的色相(参照 accentAgainstStroke
        // 已有的"蓝仍是蓝"那条断言的同一个精神)。
        expectEqual(fixed.r >= fixed.g && fixed.g >= fixed.b, true,
                    "coverArt 取色: 修复后仍保持原色相族的通道大小关系(R≥G≥B,暖黄不变色相)")

        // 已经够对比的封面不该被这一步碰:纯黑/深色渐变风格的背景是真的暗(远低于 coverArt
        // 估算出来的这类中等亮度背景),对着一个真正暗的背景,candidateBeforeFix 早就达标,
        // accentForCoverArtBackground 必须原样放行,不能因为多算一步就意外改色。
        let trulyDarkBackground = (r: 0.02, g: 0.02, b: 0.02)
        let alreadyFine = LocalPlaybackSource.accentForCoverArtBackground(
            r: candidateBeforeFix.r, g: candidateBeforeFix.g, b: candidateBeforeFix.b,
            rawR: trulyDarkBackground.r / dim, rawG: trulyDarkBackground.g / dim, rawB: trulyDarkBackground.b / dim)
        expectEqual(alreadyFine == candidateBeforeFix, true,
                    "coverArt 取色: 已经对着真暗背景够对比时原样放行,不擅自改色")

        // 常量对齐:背景渲染(NotchLyricsView 的黑叠加)跟这里估算背景用的必须是同一个数,
        // 防止两处以后各自改动、悄悄脱节(修复本身就是在补这道"各写各的"的漏洞)。
        expectEqual(LocalPlaybackSource.notchCoverArtOverlayOpacity, 0.45,
                    "coverArt 取色: 背景黑叠加不透明度常量的当前值——改这个数记得同时想清楚对比度估算要不要跟着变")
    }

    // ---- 封面取色:coverArt 风格下"贴边界够接近就别翻方向" ----
    //
    // 08-27 那版修复本身留了一个反方向的洞:偏白的封面均值本来就很亮,往亮的方向贴纯白
    // 差一点点够不到 4.5 门槛时,`accentAgainstStroke` 会整体判定"这个方向不行"、翻去
    // 暗的方向精确达标——而对着一个偏亮的背景精确达标,意味着把文字砸成近乎纯黑。用户
    // 报"封面偏白、歌词却是全黑,太突兀"就是这条,复现用的是真实播放的方大同《红豆》
    // (Timeless 专辑)封面(cover_url 记在 enrich 缓存里,下载下来用 CIAreaAverage 口径
    // 算出均值色,不是编的)。
    do {
        // 均值色 (0.8936, 0.8953, 0.9069) ≈ #E4E4E7——大面积白底 + 一角深色人像的封面,
        // 均值被白底拉得很高。brightenedAccent/accentForDarkBackdrop 两道地板对这么亮的
        // 颜色都是无操作,candidateBeforeFix 就是均值本身。
        let hongdouRGB = (r: 0.8936, g: 0.8953, b: 0.9069)
        let step1 = LocalPlaybackSource.brightenedAccent(r: hongdouRGB.r, g: hongdouRGB.g, b: hongdouRGB.b)
        let candidateBeforeFix = LocalPlaybackSource.accentForDarkBackdrop(r: step1.r, g: step1.g, b: step1.b)
        expectEqual(candidateBeforeFix == hongdouRGB, true,
                    "coverArt 取色(红豆): 均值本来就够亮,两道地板都是无操作")

        // coverArt 背景估计值 luma≈0.207,文字候选色 luma≈0.779——往亮的方向贴纯白只能
        // 拿到对比度 4.08,是 minContrast=4.5 的 90.7%,80% 的容忍窗接得住;08-31 修复前
        // 的 95% 窗接不住,会翻去暗的方向精确拿 4.5、把文字砸成近黑,这条断言就是钉死
        // "不能再退回 95%"。
        let fixed = LocalPlaybackSource.accentForCoverArtBackground(
            r: candidateBeforeFix.r, g: candidateBeforeFix.g, b: candidateBeforeFix.b,
            rawR: hongdouRGB.r, rawG: hongdouRGB.g, rawB: hongdouRGB.b)
        let dim = 1 - LocalPlaybackSource.notchCoverArtOverlayOpacity
        let approxBackground = (r: hongdouRGB.r * dim, g: hongdouRGB.g * dim, b: hongdouRGB.b * dim)
        let bgLum = LocalPlaybackSource.relativeLuminance(r: approxBackground.r, g: approxBackground.g, b: approxBackground.b)
        let fixedLum = LocalPlaybackSource.relativeLuminance(r: fixed.r, g: fixed.g, b: fixed.b)
        expectEqual(fixedLum > bgLum, true,
                    "coverArt 取色(红豆): 亮度留在背景之上,不翻成近黑(太突兀的根因)")
        expectEqual(LocalPlaybackSource.contrastRatio(bgLum, fixedLum) >= 4.0, true,
                    "coverArt 取色(红豆): 贴边界收下的结果本身仍然接近达标(90.7%),不是随手一个数")
    }

    // ---- 封面 URL:三个图源各自顶到最大那一档(网易云 / QQ+Apple) ----
    //
    // 现象是「歌词窗口里封面非常模糊」。根因是系统 Now Playing 给的封面只有
    // 100×100(网易云客户端的限制),而那张卡最大 920px。替代图取自引擎缓存的
    // cover_url,但那个 URL 尾巴上带着给小图用的 `?param=600y600` —— 网易云那个参数
    // **只降不升**,实测原生 800×800 的封面带上它就变 600×600。所以要原图必须把它摘掉。
    //
    // 现象是「QQ 音乐这个封面很模糊」。QQ 音乐客户端报的系统封面是 300×300,
    // 缓存里那张替代图当时也只有 300(QQ 源)/600(Apple 源)—— 顶到 820px 的卡上是 2.73×
    // 和 1.37× 放大。这两个图源的尺寸档不在查询串里而在**路径**里,所以改路径:QQ 提到 800
    // (实测天花板,1000/2000 都 404),Apple 提到 1200(实测要多大给多大)。
    //
    // 断言重点从"只对网易云动手"改成"只对**实测过**的形状动手":每个图源认死自己那一种
    // URL 形状,形状对不上一个字都不许改 —— 改错了是 404、整张封面消失,比"软一点"糟得多。
    do {
        func native(_ s: String) -> String {
            EnrichCacheReader.nativeSizedCoverURL(URL(string: s)!).absoluteString
        }

        // 网易云:param 摘掉,且整个查询串一起消失(不留一个尾巴上的 "?" ——
        // 那会让缓存把它当成另一个 key)。
        expectEqual(
            native("https://p1.music.126.net/abc==/1099.jpg?param=600y600"),
            "https://p1.music.126.net/abc==/1099.jpg",
            "封面URL: 网易云去掉 param")
        // 不同的 p1/p2/p4 子域都要认 —— 缓存里同一张图两种子域都出现过。
        expectEqual(
            native("https://p2.music.126.net/abc==/1099.jpg?param=300y300"),
            "https://p2.music.126.net/abc==/1099.jpg",
            "封面URL: p2 子域同样处理")
        // 本来就没有 param 的原样返回。
        expectEqual(
            native("https://p1.music.126.net/abc==/1099.jpg"),
            "https://p1.music.126.net/abc==/1099.jpg",
            "封面URL: 网易云本来没 param 就不动")
        // 还有别的参数时只摘 param,其余保留。
        expectEqual(
            native("https://p1.music.126.net/abc==/1099.jpg?param=600y600&x=1"),
            "https://p1.music.126.net/abc==/1099.jpg?x=1",
            "封面URL: 只摘 param，别的查询参数留着")

        // ---- QQ 音乐:路径里的尺寸档提到 800 ----
        expectEqual(
            native("https://y.qq.com/music/photo_new/T002R300x300M0000017AN4b0vdUG1.jpg"),
            "https://y.qq.com/music/photo_new/T002R800x800M0000017AN4b0vdUG1.jpg",
            "封面URL: QQ 300 提到 800")
        expectEqual(
            native("https://y.qq.com/music/photo_new/T002R500x500M0000017AN4b0vdUG1.jpg"),
            "https://y.qq.com/music/photo_new/T002R800x800M0000017AN4b0vdUG1.jpg",
            "封面URL: QQ 500 提到 800")
        // 已经到顶就不动 —— 800 之上是 404,不许再往上试。
        expectEqual(
            native("https://y.qq.com/music/photo_new/T002R800x800M0000017AN4b0vdUG1.jpg"),
            "https://y.qq.com/music/photo_new/T002R800x800M0000017AN4b0vdUG1.jpg",
            "封面URL: QQ 已经 800 就不动")
        // 比 800 还大的档(理论上不该出现)也不许被降回来。
        expectEqual(
            native("https://y.qq.com/music/photo_new/T002R1000x1000M000abc.jpg"),
            "https://y.qq.com/music/photo_new/T002R1000x1000M000abc.jpg",
            "封面URL: QQ 超过 800 的档不降回来")
        // 只换尺寸段,查询串一个字不碰(证明改的是路径、不是 param 那套)。
        expectEqual(
            native("https://y.qq.com/music/photo_new/T002R500x500M000.jpg?param=600y600"),
            "https://y.qq.com/music/photo_new/T002R800x800M000.jpg?param=600y600",
            "封面URL: QQ 只换尺寸段、查询串照留")
        // 歌手头像那个域名同一套规则(T001 前缀,实测也给 800)。
        expectEqual(
            native("https://y.gtimg.cn/music/photo_new/T001R300x300M000004UdEhN3Hb7vN_3.jpg"),
            "https://y.gtimg.cn/music/photo_new/T001R800x800M000004UdEhN3Hb7vN_3.jpg",
            "封面URL: QQ 歌手头像域名同样处理")
        // QQ 域名但不是图床路径 —— 不许动(歌曲页链接被误改就跳不过去了)。
        expectEqual(
            native("https://y.qq.com/n/ryqq/songDetail/000FTx4w1obE49"),
            "https://y.qq.com/n/ryqq/songDetail/000FTx4w1obE49",
            "封面URL: QQ 非图床路径不动")
        // 图床路径但没有尺寸段 —— 形状对不上就不动。
        expectEqual(
            native("https://y.qq.com/music/photo_new/mystery.jpg"),
            "https://y.qq.com/music/photo_new/mystery.jpg",
            "封面URL: QQ 图床但没有尺寸段就不动")

        // ---- Apple:末段 600x600bb.jpg 提到 1200 ----
        expectEqual(
            native("https://is1-ssl.mzstatic.com/image/thumb/a.jpg/600x600bb.jpg"),
            "https://is1-ssl.mzstatic.com/image/thumb/a.jpg/1200x1200bb.jpg",
            "封面URL: Apple 600 提到 1200")
        expectEqual(
            native("https://is1-ssl.mzstatic.com/image/thumb/a.jpg/1200x1200bb.jpg"),
            "https://is1-ssl.mzstatic.com/image/thumb/a.jpg/1200x1200bb.jpg",
            "封面URL: Apple 已经 1200 就不动")
        // 比目标档更大的不许降回来 —— 那是白扔已经拿到的分辨率。
        expectEqual(
            native("https://is1-ssl.mzstatic.com/image/thumb/a.jpg/2000x2000bb.jpg"),
            "https://is1-ssl.mzstatic.com/image/thumb/a.jpg/2000x2000bb.jpg",
            "封面URL: Apple 2000 不降回 1200")
        // 末段不是 `<W>x<H>bb.<jpg|png>` 这一种形状的一律不动 —— 没实测过,改了可能 404。
        expectEqual(
            native("https://is1-ssl.mzstatic.com/image/thumb/a.jpg/600x600sr.jpg"),
            "https://is1-ssl.mzstatic.com/image/thumb/a.jpg/600x600sr.jpg",
            "封面URL: Apple 非 bb 末段不动")
        expectEqual(
            native("https://is1-ssl.mzstatic.com/image/thumb/a.jpg/600x600bb-60.jpg"),
            "https://is1-ssl.mzstatic.com/image/thumb/a.jpg/600x600bb-60.jpg",
            "封面URL: Apple 带裁切后缀的末段不动")
        // 仿冒 host 不算 Apple(判据是"等于或以 . 分隔的子域",同网易云那条)。
        expectEqual(
            native("https://evilmzstatic.com/image/thumb/a.jpg/600x600bb.jpg"),
            "https://evilmzstatic.com/image/thumb/a.jpg/600x600bb.jpg",
            "封面URL: 仿冒 Apple 域名不动")
        // host 后缀匹配不能被"看着像"的域名骗过去。
        expectEqual(
            native("https://evil-music.126.net.example.com/a.jpg?param=600y600"),
            "https://evil-music.126.net.example.com/a.jpg?param=600y600",
            "封面URL: 仿冒域名不算网易云")
        // 判据必须是"等于或以 . 分隔的子域":光 hasSuffix("music.126.net") 会把这个也算进去。
        expectEqual(
            native("https://evilmusic.126.net/a.jpg?param=600y600"),
            "https://evilmusic.126.net/a.jpg?param=600y600",
            "封面URL: 拼在一起的同后缀域名不算网易云")
    }

    // ---- 高清替代的触发判定:太小 / 不是封面形状 ----
    //
    // YouTube Music 的 MV 给的封面是 320×180 的视频缩略图(media-control 实测,TIFF),宽 320 越过 300 的门槛,
    // 只判宽会被当成够大的封面原样显示。
    do {
        typealias G = CoverArtReplacementGate
        let t = 300
        // 现场那两张图:MV 缩略图按形状触发;下一首歌曲条目给的 544×544 方形封面不动。
        expectEqual(G.reason(width: 320, height: 180, lowResThreshold: t), .notCoverShaped,
                    "高清替代: 320×180 视频缩略图按形状触发")
        expectEqual(G.reason(width: 544, height: 544, lowResThreshold: t), nil,
                    "高清替代: 544×544 方形大图不替")
        // 竖屏视频同样不是封面;形状先于尺寸判 —— 1280×720 再大也不是封面。
        expectEqual(G.reason(width: 180, height: 320, lowResThreshold: t), .notCoverShaped,
                    "高清替代: 竖屏缩略图按形状触发")
        expectEqual(G.reason(width: 1280, height: 720, lowResThreshold: t), .notCoverShaped,
                    "高清替代: 大视频帧仍按形状触发")
        // 原有的"太小"那条不变:网易云 100×100、QQ 300×300(边界含等号,修)。
        expectEqual(G.reason(width: 100, height: 100, lowResThreshold: t), .lowRes,
                    "高清替代: 100×100 按太小触发")
        expectEqual(G.reason(width: 300, height: 300, lowResThreshold: t), .lowRes,
                    "高清替代: 300×300 边界按太小触发")
        expectEqual(G.reason(width: 301, height: 301, lowResThreshold: t), nil,
                    "高清替代: 301×301 不替")
        // 没有图不替(该显示占位音符,不该悄悄换成缓存匹配出来的另一张)。
        expectEqual(G.reason(width: 0, height: 0, lowResThreshold: t), nil, "高清替代: 没有图不替")
        // 容差 15%:正好 15% 算封面,再多一点不算。
        expectEqual(G.isCoverShaped(width: 1000, height: 850), true, "高清替代: 15% 偏差仍算封面形状")
        expectEqual(G.isCoverShaped(width: 1000, height: 849), false, "高清替代: 超过 15% 不算封面形状")
        expectEqual(G.maxAspectSkew, 0.15, "高清替代: 形状容差 15%")
        // 带留白边框那类小幅不规则的封面落在容差内、且够大 → 不替(权威图不动)。
        expectEqual(G.reason(width: 600, height: 520, lowResThreshold: t), nil,
                    "高清替代: 容差内的非严格方形大图不替")
        // 下载回来之后值不值得换:太小那条要比系统那份宽;形状那条只看替代图自己是不是方形。
        expectEqual(G.accepts(candidateWidth: 600, candidateHeight: 600, systemWidth: 300, reason: .lowRes), true,
                    "高清替代: 太小→替代图更宽才换")
        expectEqual(G.accepts(candidateWidth: 300, candidateHeight: 300, systemWidth: 300, reason: .lowRes), false,
                    "高清替代: 太小→同样小不换")
        expectEqual(G.accepts(candidateWidth: 1200, candidateHeight: 1200, systemWidth: 320, reason: .notCoverShaped), true,
                    "高清替代: 形状→方形替代图换")
        expectEqual(G.accepts(candidateWidth: 600, candidateHeight: 600, systemWidth: 1280, reason: .notCoverShaped), true,
                    "高清替代: 形状→替代图比视频帧窄也换")
        expectEqual(G.accepts(candidateWidth: 640, candidateHeight: 360, systemWidth: 320, reason: .notCoverShaped), false,
                    "高清替代: 形状→替代图自己也不是方形不换")
    }

    // ---- 交给引擎的设备封面:像不像封面只在 App 判 ----
    //
    // 引擎拿到当前封面文件里的图就用、之后不再换源。太小(没有封面时的几像素占位)、不是方形(视频缩略图)
    // 的按没有封面发;下限 64 放行浏览器 MediaSession 常见的 120×120。
    do {
        typealias G = CoverArtReplacementGate
        expectEqual(G.isUsableDeviceArtwork(width: 16, height: 16), false, "设备封面: 16×16 占位不交")
        expectEqual(G.isUsableDeviceArtwork(width: 63, height: 63), false, "设备封面: 63×63 不交")
        expectEqual(G.isUsableDeviceArtwork(width: 64, height: 64), true, "设备封面: 64×64 边界交")
        expectEqual(G.isUsableDeviceArtwork(width: 120, height: 120), true, "设备封面: 浏览器 120×120 交")
        expectEqual(G.isUsableDeviceArtwork(width: 300, height: 280), true, "设备封面: 容差内的非严格方形交")
        expectEqual(G.isUsableDeviceArtwork(width: 600, height: 200), false, "设备封面: 横幅不交")
        expectEqual(G.isUsableDeviceArtwork(width: 320, height: 180), false, "设备封面: 视频缩略图不交")
        expectEqual(G.isUsableDeviceArtwork(width: 0, height: 0), false, "设备封面: 没有图不交")
        // 发布时从图头读尺寸,再按上面的判据决定交不交。
        func solidPNG(_ width: Int, _ height: Int) -> Data? {
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = ctx.makeImage() else { return nil }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(dest, image, nil)
            return CGImageDestinationFinalize(dest) ? out as Data : nil
        }
        let square = solidPNG(120, 120), small = solidPNG(16, 16), frame = solidPNG(320, 180)
        expectNotEqual(square, nil, "设备封面: 造得出测试图")
        expectEqual(G.pixelSize(of: frame).width, 320, "设备封面: 图头读宽")
        expectEqual(G.pixelSize(of: frame).height, 180, "设备封面: 图头读高")
        expectEqual(G.pixelSize(of: Data("not an image".utf8)).width, 0, "设备封面: 读不出来是 0")
        expectEqual(PlaybackStatePublisher.artworkForEngine(square), square, "设备封面: 方形 120 原样交")
        expectEqual(PlaybackStatePublisher.artworkForEngine(small), nil, "设备封面: 16×16 按没有封面发")
        expectEqual(PlaybackStatePublisher.artworkForEngine(frame), nil, "设备封面: 视频缩略图按没有封面发")
        expectEqual(PlaybackStatePublisher.artworkForEngine(nil), nil, "设备封面: 没有图还是没有")
        // 不像封面、又不是占位小图的按视频帧交:转成 JPEG,状态里标 kind(03 章决策 39)。
        expectEqual(G.isVideoFrameArtwork(width: 320, height: 180), true, "视频帧: 16:9 缩略图算")
        expectEqual(G.isVideoFrameArtwork(width: 180, height: 320), true, "视频帧: 竖屏截图算")
        expectEqual(G.isVideoFrameArtwork(width: 120, height: 120), false, "视频帧: 方形是封面,不算")
        expectEqual(G.isVideoFrameArtwork(width: 100, height: 40), false, "视频帧: 短边不到 64 不算")
        let frameJPEG = PlaybackStatePublisher.videoFrameForEngine(frame)
        expectEqual(frameJPEG.map(PlaybackStateFile.artworkMime), "image/jpeg", "视频帧: 转成 JPEG 交")
        expectEqual(G.pixelSize(of: frameJPEG).width, 320, "视频帧: 尺寸不变")
        expectEqual(PlaybackStatePublisher.videoFrameForEngine(square), nil, "视频帧: 方形封面不按视频帧交")
        expectEqual(PlaybackStatePublisher.videoFrameForEngine(small), nil, "视频帧: 占位小图不交")
        expectEqual(PlaybackStatePublisher.videoFrameForEngine(nil), nil, "视频帧: 没有图还是没有")
        let framed = try? JSONDecoder().decode(PlaybackStateFile.Artwork.self, from: Data(
            #"{"sha256":"a","mime":"image/jpeg","bytes":1,"play_seq":2,"kind":"video_frame"}"#.utf8))
        expectEqual(framed?.kind, PlaybackStateFile.Artwork.videoFrameKind, "视频帧: 状态里的 kind 读得回来")
        let reencoded = framed.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        expectEqual(reencoded.contains(#""kind":"video_frame""#), true, "视频帧: kind 写进状态")
        let cover = try? JSONDecoder().decode(PlaybackStateFile.Artwork.self, from: Data(
            #"{"sha256":"a","mime":"image/jpeg","bytes":1,"play_seq":2}"#.utf8))
        let coverJSON = cover.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? "kind"
        expectEqual(cover?.kind == nil && !coverJSON.contains("kind"), true, "视频帧: 封面不带 kind")
        // 歌词管理的缩略图:有封面用封面,没有用视频帧。
        let frameURL = "file:///tmp/frame.jpg", coverURL = "https://example.invalid/c.jpg"
        expectEqual(ManagerCoverURL.from(["cover_url": coverURL, "video_frame_url": frameURL])?.absoluteString, coverURL,
                    "视频帧: 有封面时用封面")
        expectEqual(ManagerCoverURL.from(["cover_url": "", "video_frame_url": frameURL])?.absoluteString, frameURL,
                    "视频帧: 没封面时用视频帧")
        expectEqual(ManagerCoverURL.from([:]), nil, "视频帧: 都没有为 nil")
    }

    // ---- 小封面预先重采样:半调网点缩小不能变成摩尔纹黑斑 ----
    //
    // 用户圈图报灵动岛左耳那枚封面「和大图长得不一样,上面有黑斑,展开的时候黑斑还会动」——陶喆
    // 《I'm O.K.》是黄底黑点的半调网点封面,600px 线性缩到 46px 没有面积平均就拍出摩尔纹。这里拿
    // 一张合成的 1px 黑白棋盘格代替那张封面:正确的重采样把它平均成灰,朴素采样(对照组,.none)
    // 出来是黑白噪点。对照组是为了证明这条断言真能区分两种缩法,不是摆设。
    do {
        typealias T = ArtworkThumbnail
        // 把 CGImage 读成 RGBA 字节(premultipliedLast,alpha 恒 255),行序自上而下。
        func rgba(_ image: CGImage) -> [UInt8] {
            let w = image.width, h = image.height
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return bytes }
            bytes.withUnsafeMutableBytes { buf in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                ctx.interpolationQuality = .none
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return bytes
        }
        // 合成源图:w×h,按列/行分带上色(fill 回调给 (x, y) 返回 RGB)。
        func synthesize(width: Int, height: Int, fill: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage? {
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let (r, g, b) = fill(x, y)
                    let o = (y * width + x) * 4
                    bytes[o] = r; bytes[o + 1] = g; bytes[o + 2] = b
                }
            }
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: width * 4, space: space,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        // 1px 黑白棋盘格 600×600 → 46px
        if let board = synthesize(width: 600, height: 600, fill: { x, y in (x + y) % 2 == 0 ? (0, 0, 0) : (255, 255, 255) }) {
            if let thumb = T.squareBitmap(from: board, pixelSide: 46) {
                expectEqual(thumb.width, 46, "小封面重采样: 输出像素宽 = 目标边长")
                expectEqual(thumb.height, 46, "小封面重采样: 输出像素高 = 目标边长")
                let px = rgba(thumb)
                var extremes = 0
                for i in stride(from: 0, to: px.count, by: 4) where px[i] < 64 || px[i] > 192 { extremes += 1 }
                expectEqual(extremes, 0, "小封面重采样: 棋盘格缩到 46px 全是灰(没有黑/白极值像素 = 没有摩尔纹)")
            } else {
                expectEqual(false, true, "小封面重采样: 棋盘格缩图建不出来")
            }
            // 对照组:朴素 .none 采样同一张图,必然满是黑白极值 —— 证明上面那条断言区分得开。
            if let space = CGColorSpace(name: CGColorSpace.sRGB),
               let ctx = CGContext(data: nil, width: 46, height: 46, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .none
                ctx.draw(board, in: CGRect(x: 0, y: 0, width: 46, height: 46))
                if let naive = ctx.makeImage() {
                    let px = rgba(naive)
                    var extremes = 0
                    for i in stride(from: 0, to: px.count, by: 4) where px[i] < 64 || px[i] > 192 { extremes += 1 }
                    expectEqual(extremes > 46 * 46 / 2, true, "小封面重采样(对照组): 朴素采样过半像素是黑/白极值")
                }
            }
        } else {
            expectEqual(false, true, "小封面重采样: 合成棋盘格失败")
        }
        // aspect-fill 居中裁方:横图 600×300 三段竖带(左红 150 / 中绿 300 / 右蓝 150)→ 裁出来正好是绿带。
        if let wide = synthesize(width: 600, height: 300, fill: { x, _ in x < 150 ? (255, 0, 0) : (x < 450 ? (0, 255, 0) : (0, 0, 255)) }),
           let thumb = T.squareBitmap(from: wide, pixelSide: 32) {
            let px = rgba(thumb)
            var nonGreen = 0
            for i in stride(from: 0, to: px.count, by: 4) where !(px[i] < 16 && px[i + 1] > 239 && px[i + 2] < 16) { nonGreen += 1 }
            expectEqual(nonGreen, 0, "小封面重采样: 横图居中裁方只剩中间那条带")
        } else {
            expectEqual(false, true, "小封面重采样: 横图缩图建不出来")
        }
        // 竖图 300×600 三段横带(上红 / 中绿 / 下蓝)→ 同样只剩绿带。
        if let tall = synthesize(width: 300, height: 600, fill: { _, y in y < 150 ? (255, 0, 0) : (y < 450 ? (0, 255, 0) : (0, 0, 255)) }),
           let thumb = T.squareBitmap(from: tall, pixelSide: 32) {
            let px = rgba(thumb)
            var nonGreen = 0
            for i in stride(from: 0, to: px.count, by: 4) where !(px[i] < 16 && px[i + 1] > 239 && px[i + 2] < 16) { nonGreen += 1 }
            expectEqual(nonGreen, 0, "小封面重采样: 竖图居中裁方只剩中间那条带")
        } else {
            expectEqual(false, true, "小封面重采样: 竖图缩图建不出来")
        }
        // 非法边长 → nil(调用方退回运行期缩放)。
        if let board = synthesize(width: 8, height: 8, fill: { _, _ in (0, 0, 0) }) {
            expectEqual(T.squareBitmap(from: board, pixelSide: 0) == nil, true, "小封面重采样: 边长 0 → nil")
        }
    }

    // ---- 封面感知指纹(aHash):动态封面下载后终审用它判"视频这一帧是不是这张封面" ----
    //
    // 跟上面「小封面预先重采样」共用同一套合成图手法,不复用那边局部定义的 synthesize(不同
    // do 块之间不共享局部函数)。
    do {
        typealias F = CoverFingerprint
        func synthesize(width: Int, height: Int, fill: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage? {
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let (r, g, b) = fill(x, y)
                    let o = (y * width + x) * 4
                    bytes[o] = r; bytes[o + 1] = g; bytes[o + 2] = b
                }
            }
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: width * 4, space: space,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        // 左黑右白的竖分割图,两种分辨率(600×600 模拟静态封面、64×64 模拟从视频里抽出来的
        // 缩小帧)——同一张图不同分辨率,距离该是 0,这正是 aHash 箱式取平均要保证的那件事
        // (见 CoverFingerprint.hash 的注释)。
        let big = synthesize(width: 600, height: 600, fill: { x, _ in x < 300 ? (0, 0, 0) : (255, 255, 255) })
        let small = synthesize(width: 64, height: 64, fill: { x, _ in x < 32 ? (0, 0, 0) : (255, 255, 255) })
        if let big, let small {
            let hb = F.hash(of: big)
            let hs = F.hash(of: small)
            expectEqual(F.distance(hb, hs), 0, "封面指纹: 同一张图缩到不同分辨率,距离为 0")
            expectEqual(F.distance(hb, hb), 0, "封面指纹: 跟自己比距离恒为 0")
        } else {
            expectEqual(false, true, "封面指纹: 竖分割合成图建不出来")
        }
        // 上黑下白的横分割图——跟上面竖分割是完全不同的画面,距离该远超阈值。
        let rotated = synthesize(width: 600, height: 600, fill: { _, y in y < 300 ? (0, 0, 0) : (255, 255, 255) })
        if let big, let rotated {
            let distance = F.distance(F.hash(of: big), F.hash(of: rotated))
            expectEqual(distance > F.motionCoverMaxDistance, true,
                        "封面指纹: 竖分割 vs 横分割是两张不同的图,距离该超过阈值(实测 \(distance))")
        } else {
            expectEqual(false, true, "封面指纹: 横分割合成图建不出来")
        }
        // 在竖分割图上叠一点点局部噪声(模拟 Apple 给动态封面叠的贴纸/光效那类小范围装饰)——
        // 距离该保持很小,不该被判成"不是同一张"。
        let withSpeckle = synthesize(width: 600, height: 600, fill: { x, y in
            if x >= 280, x < 320, y >= 280, y < 320 { return (255, 200, 0) } // 中心一小块高光
            return x < 300 ? (0, 0, 0) : (255, 255, 255)
        })
        if let big, let withSpeckle {
            let distance = F.distance(F.hash(of: big), F.hash(of: withSpeckle))
            expectEqual(distance <= F.motionCoverMaxDistance, true,
                        "封面指纹: 小范围局部装饰不该把同一张图判成不一样(实测距离 \(distance))")
        } else {
            expectEqual(false, true, "封面指纹: 带高光合成图建不出来")
        }
        // 去边第二次机会:Apple 给一部分专辑的动画四周压了一圈暗角、而静态封面没有,
        // 同一张图因此被整图比判成两张(实测 Omar Apollo《Ivory》整图 16 / 去边 0)。
        // 底图故意用"大片浅色 + 中心一块深色":外圈格子本来就紧贴均值,
        // 四周一圈暗角才能把它们整圈翻面 —— 真实封面(浅背景人像)就是这个形态。
        let plain = synthesize(width: 600, height: 600, fill: { x, y in
            (x >= 225 && x < 375 && y >= 225 && y < 375) ? (40, 40, 40) : (200, 200, 200)
        })
        let vignetted = synthesize(width: 600, height: 600, fill: { x, y in
            if x < 48 || x >= 552 || y < 48 || y >= 552 { return (0, 0, 0) } // 四周 8% 的暗角
            return (x >= 225 && x < 375 && y >= 225 && y < 375) ? (40, 40, 40) : (200, 200, 200)
        })
        if let plain, let vignetted {
            let full = F.distance(F.hash(of: plain), F.hash(of: vignetted))
            let verdict = F.matches(vignetted, reference: F.reference(of: plain))
            expectEqual(full > F.motionCoverMaxDistance, true,
                        "封面指纹: 四周黑边让整图比超阈(实测 \(full))——这正是去边那一道要救的")
            expectEqual(verdict.same, true,
                        "封面指纹: 去掉四边 8% 后该判成同一张(实测距离 \(verdict.distance))")
        } else {
            expectEqual(false, true, "封面指纹: 带黑边合成图建不出来")
        }
        // ⚙️ 去边不能把真反例救成“同一张”——竖分割 vs 横分割去了边还是两张图。
        if let big, let rotated {
            let verdict = F.matches(rotated, reference: F.reference(of: big))
            expectEqual(verdict.same, false,
                        "封面指纹: 去边那一道不该把两张不同的图放过去(实测距离 \(verdict.distance))")
        }
    }

    // ---- 动态封面(motion artwork)的 HLS 清单解析----
    //
    // fixture 是从 Prince《Timeless》(collectionId 6773830957)那条真 master m3u8
    // 上原样抄下来的片段:同时含 trick-play 的 I 帧轨(必须被排掉)、同尺寸多码率(486² 有三条)、
    // H.264 与 HEVC 并存,以及 `AVERAGE-BANDWIDTH` / `_AVG-BANDWIDTH` / `BANDWIDTH` 三个名字
    // 都以 `BANDWIDTH` 结尾这个真实的属性名陷阱。
    do {
        typealias M = MotionCoverManifest
        let base = "https://mvod.itunes.apple.com/itunes-assets/HLSVideo211/v4/b4/00/a8/x"
        let master = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS

        #EXT-X-I-FRAME-STREAM-INF:AVERAGE-BANDWIDTH=173201,_AVG-BANDWIDTH=173201,BANDWIDTH=177631,VIDEO-RANGE=SDR,CODECS="avc1.64001f",RESOLUTION=486x486,URI="\(base)/P_trickPlay_gr210_sdr_486x486_iframes.m3u8"
        #EXT-X-I-FRAME-STREAM-INF:AVERAGE-BANDWIDTH=887781,_AVG-BANDWIDTH=887781,BANDWIDTH=942325,VIDEO-RANGE=SDR,CODECS="avc1.640020",RESOLUTION=1080x1080,URI="\(base)/P_trickPlay_gr265_sdr_1080x1080_iframes.m3u8"

        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=265893,_AVG-BANDWIDTH=265893,BANDWIDTH=334704,VIDEO-RANGE=SDR,CLOSED-CAPTIONS=NONE,CODECS="avc1.64001f",FRAME-RATE=24.000,RESOLUTION=360x360,STABLE-VARIANT-ID="dfb6"
        \(base)/P_Anull_video_gr203_sdr_360x360.m3u8
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=771275,_AVG-BANDWIDTH=771275,BANDWIDTH=983664,VIDEO-RANGE=SDR,CLOSED-CAPTIONS=NONE,CODECS="avc1.64001f",FRAME-RATE=24.000,RESOLUTION=486x486,STABLE-VARIANT-ID="39f3"
        \(base)/P_Anull_video_gr210_sdr_486x486.m3u8
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=1118698,_AVG-BANDWIDTH=1118698,BANDWIDTH=1448322,VIDEO-RANGE=SDR,CLOSED-CAPTIONS=NONE,CODECS="avc1.64001f",FRAME-RATE=24.000,RESOLUTION=486x486,STABLE-VARIANT-ID="b709"
        \(base)/P_Anull_video_gr220_sdr_486x486.m3u8
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=2154918,_AVG-BANDWIDTH=2154918,BANDWIDTH=2887412,VIDEO-RANGE=SDR,CLOSED-CAPTIONS=NONE,CODECS="avc1.64001f",FRAME-RATE=24.000,RESOLUTION=768x768,STABLE-VARIANT-ID="99cf"
        \(base)/P_Anull_video_gr240_sdr_768x768.m3u8
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=1577673,_AVG-BANDWIDTH=1577673,BANDWIDTH=2128046,VIDEO-RANGE=SDR,CLOSED-CAPTIONS=NONE,CODECS="hvc1.2.20000000.L123.B0",FRAME-RATE=24.000,RESOLUTION=768x768,STABLE-VARIANT-ID="9263"
        \(base)/P_Anull_video_gr540_sdr_768x768.m3u8
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=2868023,_AVG-BANDWIDTH=2868023,BANDWIDTH=3704874,VIDEO-RANGE=SDR,CLOSED-CAPTIONS=NONE,CODECS="avc1.64001f",FRAME-RATE=24.000,RESOLUTION=960x960,STABLE-VARIANT-ID="d2b0"
        \(base)/P_Anull_video_gr250_sdr_960x960.m3u8
        """
        let vs = M.parseVariants(master: master)
        expectEqual(vs.count, 6, "动态封面: 只收 STREAM-INF,trick-play 的 I 帧轨全部排掉")
        expectEqual(vs.map(\.width), [360, 486, 486, 768, 768, 960], "动态封面: 档位按出现顺序解出来")
        expectEqual(vs.filter(\.isHEVC).count, 1, "动态封面: CODECS 里的 hvc1 认得出来")
        expectEqual(vs[0].bandwidth, 265893, "动态封面: 取 AVERAGE-BANDWIDTH,不被 _AVG-/BANDWIDTH 串台")

        // 选档:够用的最小那一档。歌词窗口封面卡是 460pt@2x = 920px → 该选 960²。
        expectEqual(M.pick(vs, minimumWidth: 920)?.width, 960, "动态封面: 920px 要求 → 选 960²")
        expectEqual(M.pick(vs, minimumWidth: 920)?.isHEVC, false, "动态封面: 960² 只有 H.264 一条时就选它")
        // 灵动岛那 32pt@2x = 64px,最小档就够。
        expectEqual(M.pick(vs, minimumWidth: 64)?.width, 360, "动态封面: 小尺寸要求 → 选最小档,不白下字节")
        // 同尺寸多码率:取码率低的那条(486² 有 771k 与 1118k 两条)。
        expectEqual(M.pick(vs, minimumWidth: 400)?.bandwidth, 771275, "动态封面: 同尺寸取低码率")
        // 同尺寸 H.264 与 HEVC 并存(768²)时码率低的先:这里 HEVC 1.58M 对 H.264 2.15M。
        expectEqual(M.pick(vs, minimumWidth: 500)?.isHEVC, true, "动态封面: 同尺寸码率低的先(这档是 HEVC)")
        // 候选按顺序试:前一条拿不到就退到下一条,HEVC 后面总有同宽度的 H.264。
        expectEqual(M.candidates(vs, minimumWidth: 500).map(\.isHEVC), [true, false],
                    "动态封面: 768² 先试 HEVC、再退 H.264")
        expectEqual(M.candidates(vs, minimumWidth: 500).map(\.width), [768, 768], "动态封面: 候选都在同一个目标宽度上")
        expectEqual(M.candidates(vs, minimumWidth: 400).map(\.bandwidth), [771275, 1118698],
                    "动态封面: 同编码多条码率按从低到高排")
        expectEqual(M.candidates(vs, minimumWidth: 920).count, 1, "动态封面: 960² 只有一条就只试一条")
        let tie = [M.Variant(uri: "h", width: 960, height: 960, bandwidth: 2_000_000, isHEVC: true),
                   M.Variant(uri: "a", width: 960, height: 960, bandwidth: 2_000_000, isHEVC: false)]
        expectEqual(M.candidates(tie, minimumWidth: 920).map(\.uri), ["a", "h"], "动态封面: 码率一样时 H.264 在前")
        expectEqual(M.candidates([], minimumWidth: 920).isEmpty, true, "动态封面: 空清单 → 没有候选")
        // 一档都不够宽 → 退回最大档,宁可放大也别不动。
        expectEqual(M.pick(vs, minimumWidth: 4096)?.width, 960, "动态封面: 都不够宽 → 退最大档")
        expectEqual(M.pick([], minimumWidth: 920) == nil, true, "动态封面: 空清单 → nil")

        // 源码契约:下载按候选顺序试、一条失败退下一条;画面对不上直接认;没有参照图也要解得出帧;
        // 设置页「动态封面缓存」清除时留下正在播的那一份。
        let appRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let storeSource = (try? String(contentsOf: appRoot.appendingPathComponent("lyrimuse/MotionCoverStore.swift"), encoding: .utf8)) ?? ""
        let settingsSource = (try? String(contentsOf: appRoot.appendingPathComponent("lyrimuse/SettingsView.swift"), encoding: .utf8)) ?? ""
        expectEqual(storeSource.contains("for variant in candidates.prefix(Self.maxCandidateAttempts) {"), true,
                    "动态封面下载: 按 MotionCoverManifest.candidates 的顺序逐条试")
        expectEqual(storeSource.contains("case .referenceMismatch: return .referenceMismatch"), true,
                    "动态封面下载: 画面跟封面对不上就直接认,不换编码重试")
        expectEqual(storeSource.contains("} else if !(await Self.decodesAFrame(scratch)) {"), true,
                    "动态封面下载: 跳过终审时也要确认解得出帧,解不出就试下一条")
        expectEqual(storeSource.contains("MotionCoverManifest.pick("), false,
                    "动态封面下载: 别回到只挑一档、失败就放弃的写法")
        expectEqual(settingsSource.contains("CardDivider()\n        MotionCoverCacheRow()"), true,
                    "动态封面缓存: 完整尺寸「封面」那几行里有这一行(浮层和抽屉同一份)")
        expectEqual(settingsSource.contains("keeping: PlaybackCoordinator.shared.motionCoverFile)"), true,
                    "动态封面缓存: 清除时留下歌词窗口正在播的那一份")

        // variant 清单 → 承载全部分片的那个单文件(EXT-X-MAP 的 URI)。
        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-VERSION:7
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MAP:URI="P_Anull_video_gr240_sdr_768x768-.mp4",BYTERANGE="877@0"
        #EXTINF:4.00000,
        #EXT-X-BYTERANGE:600435@877
        P_Anull_video_gr240_sdr_768x768-.mp4
        #EXTINF:4.00000,
        #EXT-X-BYTERANGE:1331742@601312
        P_Anull_video_gr240_sdr_768x768-.mp4
        #EXT-X-ENDLIST
        """
        expectEqual(M.mediaFileName(fromVariant: variant), "P_Anull_video_gr240_sdr_768x768-.mp4",
                    "动态封面: 从 EXT-X-MAP 取出那个单文件名")
        expectEqual(M.mediaFileName(fromVariant: "#EXTM3U\n#EXT-X-ENDLIST") == nil, true,
                    "动态封面: 没有 EXT-X-MAP → nil(当这档没有单文件形态)")

        // 相对 URI 解析:Apple 现在给绝对地址,但 HLS 允许相对。
        let vbase = URL(string: "\(base)/P_Anull_video_gr240_sdr_768x768.m3u8")!
        expectEqual(M.absolute("P_Anull_video_gr240_sdr_768x768-.mp4", relativeTo: vbase)?.absoluteString,
                    "\(base)/P_Anull_video_gr240_sdr_768x768-.mp4",
                    "动态封面: 相对 URI 按 variant 地址解成绝对")
        expectEqual(M.absolute("https://other/x.mp4", relativeTo: vbase)?.absoluteString, "https://other/x.mp4",
                    "动态封面: 已经是绝对地址就原样用")

        // 属性解析本身:值里带逗号(CODECS)、带等号(STABLE-VARIANT-ID 风格)都不能切错。
        expectEqual(M.attribute("CODECS", in: "BANDWIDTH=1,CODECS=\"avc1.64001f,mp4a.40.2\",X=2"),
                    "avc1.64001f,mp4a.40.2", "动态封面: 带引号的值里含逗号不被切断")
        expectEqual(M.attribute("BANDWIDTH", in: "AVERAGE-BANDWIDTH=111,BANDWIDTH=222"), "222",
                    "动态封面: BANDWIDTH 不会命中 AVERAGE-BANDWIDTH 的尾巴")
        expectEqual(M.attribute("RESOLUTION", in: "A=1,RESOLUTION=768x768"), "768x768", "动态封面: 无引号值读到逗号为止")
        expectEqual(M.attribute("MISSING", in: "A=1") == nil, true, "动态封面: 没有的键 → nil")
        expectEqual(M.parseResolution("960x960")?.0, 960, "动态封面: 分辨率解析")
        expectEqual(M.parseResolution("bad") == nil, true, "动态封面: 坏分辨率 → nil")
    }

    // ---- KnownPlaceholderArtwork:播放器自己推的内置占位图 ----
    //
    // 实测(酷狗 3.3.2):换歌后先推一张 35427 字节的蓝底黑胶唱片,几秒后才换真封面。
    // 同一份字节在三首完全不同的歌上逐字节相同,而各自的真封面互不相同 —— 判据取整份
    // 字节的 SHA-256,不按"多首共用"去猜(合辑封面本来就共用,那样会误伤)。
    do {
        typealias K = KnownPlaceholderArtwork

        expectEqual(K.entries.isEmpty, false, "占位图登记表不该是空的")
        for e in K.entries {
            expectEqual(e.sha256Hex.count, 64, "占位图指纹必须是完整的 SHA-256(64 个十六进制字符)")
            expectEqual(e.byteCount > 0, true, "占位图字节数要登记,判定靠它先便宜地筛一道")
            expectEqual(e.player.isEmpty, false, "要记下是哪个播放器推的,过期时才查得到源头")
        }

        // 字节数对不上就直接否 —— 连 SHA-256 都不用算。
        expectEqual(K.isPlaceholder(Data(repeating: 0, count: 1234)), false,
                    "字节数对不上的图不是占位图")
        expectEqual(K.isPlaceholder(Data()), false, "空数据不是占位图")

        // 字节数撞上、内容不同 → 仍然否。这条是这套判据的核心:光看大小会误伤。
        if let entry = K.entries.first {
            let sameSizeDifferentBytes = Data(repeating: 0xAB, count: entry.byteCount)
            expectEqual(K.isPlaceholder(sameSizeDifferentBytes), false,
                        "字节数相同但内容不同的真封面绝不能被当成占位图")
        }
    }

    // ---- 网易云云盘歌:占位图登记、那一首放行高清替代、歌手 / 专辑位兜底(见 03 章决策 32) ----
    do {
        expectEqual(KnownPlaceholderArtwork.entries.contains {
            $0.player == "com.netease.163music" && $0.byteCount == 2345
                && $0.sha256Hex == "eaaca16f077893e67c4481a8ad11e2069995d1ebe678a21ecb720597ea665a63"
        }, true, "云盘歌: 网易云那张灰底红音符登记在案")

        typealias G = CoverArtReplacementGate
        expectEqual(G.reason(width: 0, height: 0, lowResThreshold: 300, systemArtworkIsPlaceholder: true), .playerHasNoArtwork,
                    "云盘歌: 这一首只推了占位图,高清替代按「播放器没有封面」放行")
        expectEqual(G.reason(width: 0, height: 0, lowResThreshold: 300), nil,
                    "云盘歌: 真的没有封面(没认出占位图)时照旧不找替代")
        expectEqual(G.reason(width: 640, height: 640, lowResThreshold: 300, systemArtworkIsPlaceholder: true), .playerHasNoArtwork,
                    "云盘歌: 这一首推的是占位图时,系统那份(留着的上一首封面)再大也不作数")
        expectEqual(G.reason(width: 640, height: 640, lowResThreshold: 300), nil, "云盘歌: 没认出占位图时,够大的真封面照旧不动")

        typealias I = InferredTrackIdentity
        let identified = I(artist: "周杰伦", album: "八度空间")
        expectEqual(I.displayArtist(playerArtist: "", display: "", inferred: identified), "周杰伦",
                    "云盘歌: 播放器没报歌手时显示认出来的")
        expectEqual(I.displayArtist(playerArtist: "孙燕姿", display: "孙燕姿", inferred: identified), "孙燕姿",
                    "云盘歌: 播放器报了歌手就照旧")
        expectEqual(I.displayArtist(playerArtist: "某句歌词", display: "", inferred: identified), "",
                    "云盘歌: 播放器报了歌手、只是判成不可信没显示时不补(只补根本没报歌手的)")
        expectEqual(I.displayArtist(playerArtist: "", display: "", inferred: nil), "", "云盘歌: 没认出来就空着")
        expectEqual(I.displayArtist(playerArtist: " ", display: "", inferred: I(artist: "", album: "八度空间")), "",
                    "云盘歌: 认出来的没有歌手就空着")
        expectEqual(I.displayAlbum(playerAlbum: "", display: "", inferred: identified), "八度空间",
                    "云盘歌: 播放器没报专辑时显示认出来的")
        expectEqual(I.displayAlbum(playerAlbum: "", display: "MV", inferred: identified), "MV",
                    "云盘歌: 专辑位本来就有要显示的字(MV、YouTube Music 登记的专辑)时照旧")
        expectEqual(I.displayAlbum(playerAlbum: "叶惠美", display: "叶惠美", inferred: identified), "叶惠美",
                    "云盘歌: 播放器报了专辑就照旧")

        func inferred(_ json: String) -> InferredTrackIdentity? {
            (try? JSONDecoder().decode(EnrichCacheEntry.self, from: Data(json.utf8))).flatMap(EnrichCacheReader.inferredIdentity(in:))
        }
        expectEqual(inferred(#"{"inferred_artist":"周杰伦","inferred_album":"八度空间"}"#), identified,
                    "云盘歌: 读出缓存条目里引擎认出来的歌手和专辑")
        expectEqual(inferred(#"{"inferred_artist":"周杰伦"}"#), I(artist: "周杰伦", album: ""), "云盘歌: 只认出歌手时专辑位空着")
        expectEqual(inferred(#"{"inferred_artist":"","inferred_album":"八度空间"}"#), nil, "云盘歌: 没认出歌手不算认出来")
        expectEqual(inferred(#"{"lyrics":"[00:01.00]a"}"#), nil, "云盘歌: 条目里没有这两个字段")

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) -> String {
            (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
        }
        let coordinator = source("lyrimuse/PlaybackCoordinator.swift")
        let playback = source("LyrimuseCore/Local/LocalPlaybackSource.swift")
        expectEqual(coordinator.contains("systemArtworkIsPlaceholder: LocalPlaybackSource.shared.artworkIsPlaceholder"), true,
                    "云盘歌接线: 高清替代问这一首是不是只推了占位图")
        expectEqual(coordinator.contains("s.$artworkIsPlaceholder\n                .removeDuplicates()\n                .filter { $0 }"), true,
                    "云盘歌接线: 认出占位图时补查一次高清封面")
        expectEqual(coordinator.components(separatedBy: "self?.refreshInferredIdentity()").count - 1, 2,
                    "云盘歌接线: 换歌、缓存内容变了两个时机都重读认出来的歌手 / 专辑")
        expectEqual(coordinator.contains("InferredTrackIdentity.displayArtist(")
                    && coordinator.contains("InferredTrackIdentity.displayAlbum(")
                    && coordinator.components(separatedBy: "inferred: inferred)").count - 1 == 2, true,
                    "云盘歌接线: 歌手位、专辑位都接上兜底")
        expectEqual(playback.contains("holdingPrevious = true\n                self.artworkIsPlaceholder = true"), true,
                    "云盘歌接线: 认出占位图时记下这一首")
        expectEqual(playback.contains("if artworkIsPlaceholder { artworkIsPlaceholder = false }\n                clearMusicVideoTimeline()"), true,
                    "云盘歌接线: 换歌时清掉占位标记")
        expectEqual(playback.components(separatedBy: "self.artworkIsPlaceholder = false").count - 1, 4,
                    "云盘歌接线: 首轮换上真封面、确认循环换上或等到这首的封面、晚到的封面补上时都清掉占位标记")
        expectEqual(coordinator.contains("if let applied = highResCoverApplied, candidates.contains(applied.url), let shown = highResArtworkImage,")
                    && coordinator.contains("self?.highResCoverApplied = (url, image)"), true,
                    "高清替代接线: 铺着的就是这一张时不撤了重铺(留着的旧封面到期清掉那一刻不闪)")
    }

    // ---- 专辑简介:专辑 ID 解析 + 专辑页解析 ----
    do {
        typealias N = AlbumEditorialNotes
        expectEqual(N.albumID(fromAppleMusicURL: "https://music.apple.com/cn/album/%E6%9C%AA%E6%9D%A5/272875165?i=272875201"), 272875165,
                    "专辑简介: 从带 slug 和曲目参数的链接里取专辑 ID")
        expectEqual(N.albumID(fromAppleMusicURL: "https://music.apple.com/us/album/272875165"), 272875165,
                    "专辑简介: 没有 slug 也认")
        expectEqual(N.albumID(fromAppleMusicURL: "https://music.apple.com/us/artist/khalil-fong/5439386"), nil,
                    "专辑简介: 歌手页链接不算专辑")
        expectEqual(N.albumID(fromAppleMusicURL: "https://y.qq.com/n/ryqq/albumDetail/272875165"), nil,
                    "专辑简介: 别的平台的链接不认")
        expectEqual(N.albumID(fromAppleMusicURL: nil), nil, "专辑简介: 没有链接")
        expectEqual(N.pageURL(albumID: 272875165, storefront: "CN")?.absoluteString,
                    "https://music.apple.com/cn/album/x/272875165", "专辑简介: 页面地址按店面小写、slug 写死 x")

        // 与真实页面同形:专辑头部那一项带 contentDescriptor + modalPresentationDescriptor,同页还挂着别的专辑。
        func page(_ json: String) -> String {
            "<html><head></head><body><script type=\"application/json\" id=\"serialized-server-data\">\(json)</script></body></html>"
        }
        let json = """
        {"data":[{"data":{"sections":[{"items":[
          {"contentDescriptor":{"kind":"album","identifiers":{"storeAdamID":"999"}},
           "modalPresentationDescriptor":{"headerTitle":"别的专辑","paragraphText":"不该被取到"}},
          {"contentDescriptor":{"kind":"album","identifiers":{"storeAdamID":"272875165"}},
           "modalPresentationDescriptor":{"headerTitle":"未来","headerSubtitle":"方大同 · 2007年",
             "paragraphText":"  方大同在 2007 年推出的<i>国语大碟</i>。<br />第二段  "}}
        ]}]}}]}
        """
        let notes = N.parse(html: page(json), albumID: 272875165)
        expectEqual(notes?.title, "未来", "专辑简介: 标题取页面上的专辑名")
        expectEqual(notes?.subtitle, "方大同 · 2007年", "专辑简介: 副标题原样保留")
        expectEqual(notes?.text, "方大同在 2007 年推出的国语大碟。\n第二段", "专辑简介: 去掉 HTML 标签、<br> 换成换行、收首尾空白")
        expectEqual(N.parse(html: page(json), albumID: 999)?.text, "不该被取到", "专辑简介: 按专辑 ID 挑对应的那一项")
        expectEqual(N.parse(html: page(json), albumID: 123), nil, "专辑简介: 页面里没有这张专辑的简介 = nil,不拿别的专辑顶上")
        let noIDs = """
        {"data":[{"modalPresentationDescriptor":{"headerTitle":"x","paragraphText":"没有专辑标识"}}]}
        """
        expectEqual(N.parse(html: page(noIDs), albumID: 272875165), nil, "专辑简介: 没有专辑标识的形状不放行")
        let blank = """
        {"data":[{"contentDescriptor":{"identifiers":{"storeAdamID":"272875165"}},"modalPresentationDescriptor":{"paragraphText":"  <br/> "}}]}
        """
        expectEqual(N.parse(html: page(blank), albumID: 272875165), nil, "专辑简介: 正文清理后为空 = nil")
        expectEqual(N.parse(html: "<html>没有内嵌数据</html>", albumID: 272875165), nil, "专辑简介: 页面不是预期形状 = nil")
    }

    // ---- 歌手简介:专辑页的署名歌手 + 歌手页简介 + API 补充字段 ----
    do {
        typealias N = AlbumEditorialNotes
        func page(_ json: String) -> String {
            "<html><body><script type=\"application/json\" id=\"serialized-server-data\">\(json)</script></body></html>"
        }
        // 专辑头部:简介 + subtitleLinks(与真实页面同形);播放按钮等别的节点也引用同一个专辑 ID,不能被当成头部。
        let albumJSON = """
        {"data":[{"data":{"sections":[{"items":[
          {"playButton":{"contentDescriptor":{"kind":"album","identifiers":{"storeAdamID":"272875165"}}}},
          {"contentDescriptor":{"kind":"album","identifiers":{"storeAdamID":"272875165"}},
           "modalPresentationDescriptor":{"headerTitle":"未来","paragraphText":"专辑正文"},
           "subtitleLinks":[
             {"title":"方大同","segue":{"destination":{"contentDescriptor":{"kind":"artist","identifiers":{"storeAdamID":"201549024"}}}}},
             {"title":"某合唱","segue":{"destination":{"contentDescriptor":{"kind":"artist","identifiers":{"storeAdamID":"42"}}}}},
             {"title":"不是歌手","segue":{"destination":{"contentDescriptor":{"kind":"genre","identifiers":{"storeAdamID":"7"}}}}}
           ]}
        ]}]}}]}
        """
        let albumPage = N.parseAlbumPage(html: page(albumJSON), albumID: 272875165)
        expectEqual(albumPage?.notes?.text, "专辑正文", "歌手简介: 专辑页一次拿到简介")
        expectEqual(albumPage?.artists, [N.ArtistLink(name: "方大同", id: 201549024), N.ArtistLink(name: "某合唱", id: 42)],
                    "歌手简介: 同一次拿到署名歌手,只认指向歌手页的链接")
        let noNotesJSON = """
        {"data":[{"contentDescriptor":{"kind":"album","identifiers":{"storeAdamID":"5"}},
          "subtitleLinks":[{"title":"甲","segue":{"destination":{"contentDescriptor":{"kind":"artist","identifiers":{"storeAdamID":"9"}}}}}]}]}
        """
        let noNotes = N.parseAlbumPage(html: page(noNotesJSON), albumID: 5)
        expectEqual(noNotes?.notes, nil, "歌手简介: 专辑没有简介时 notes 为 nil")
        expectEqual(noNotes?.artists.first?.id, 9, "歌手简介: 专辑没有简介也照样拿到署名歌手")

        // 挑歌手
        let links = [N.ArtistLink(name: "方大同", id: 1), N.ArtistLink(name: "王力宏", id: 2)]
        expectEqual(N.pickArtist(links, localArtist: "王力宏 & 方大同")?.id, 1, "挑歌手: 名字能对上的第一位")
        expectEqual(N.pickArtist([N.ArtistLink(name: "方大同", id: 1)], localArtist: "Khalil Fong")?.id, 1,
                    "挑歌手: 只有一位署名时用它(播放器可能报另一种语言的写法)")
        expectEqual(N.pickArtist(links, localArtist: "陶喆"), nil, "挑歌手: 多位都对不上时不猜")
        expectEqual(N.pickArtist([], localArtist: "方大同"), nil, "挑歌手: 没有署名")

        // 歌手页:头部那一项带 bio;页面别处指向这位歌手的链接不算。
        let artistJSON = """
        {"data":[{"data":{"sections":[{"items":[
          {"title":"别处的链接","contentDescriptor":{"kind":"artist","identifiers":{"storeAdamID":"201549024"}}},
          {"id":"201549024","title":"方大同","contentDescriptor":{"kind":"artist","identifiers":{"storeAdamID":"201549024"}},
           "bio":"  第一段\\n\\n第二段  "}
        ]}]}}]}
        """
        expectEqual(N.parseArtistBio(html: page(artistJSON), artistID: 201549024), "第一段\n\n第二段",
                    "歌手简介: 取头部那一项的 bio,段落换行保留、首尾空白收掉")
        expectEqual(N.parseArtistBio(html: page(artistJSON), artistID: 1), nil, "歌手简介: 歌手 ID 对不上 = nil")
        let emptyBioJSON = """
        {"data":[{"title":"甲","circleArtwork":{},"contentDescriptor":{"kind":"artist","identifiers":{"storeAdamID":"3"}}}]}
        """
        expectEqual(N.parseArtistBio(html: page(emptyBioJSON), artistID: 3), "", "歌手简介: 页面对、没有简介 = 空串(跟请求失败分开)")
        expectEqual(N.artistPageURL(artistID: 201549024, storefront: "CN")?.absoluteString,
                    "https://music.apple.com/cn/artist/x/201549024", "歌手简介: 页面地址")

        // API 补充字段
        let facts = N.parseArtistFacts(Data("""
        {"data":[{"attributes":{"bornOrFormed":"1983年7月14日","genreNames":["国语流行","音乐"],"isGroup":false}}]}
        """.utf8))
        expectEqual(facts, N.ArtistFacts(bornOrFormed: "1983年7月14日", genres: ["国语流行"], isGroup: false),
                    "歌手简介: 出生日期 + 类型,去掉「音乐」这个总类")
        expectEqual(N.parseArtistFacts(Data("{\"data\":[{\"attributes\":{\"isGroup\":true}}]}".utf8)),
                    N.ArtistFacts(bornOrFormed: nil, genres: [], isGroup: true), "歌手简介: 缺字段时对应行不出现")
        expectEqual(N.parseArtistFacts(Data("oops".utf8)), nil, "歌手简介: 返回不是 JSON = nil")

        // 引擎缓存的 developer token
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        expectEqual(AppleMusicDeveloperToken.parse(Data("{\"token\":\"abc\",\"expiry\":2000003600}".utf8), now: now), "abc",
                    "token: 没过期就用")
        expectEqual(AppleMusicDeveloperToken.parse(Data("{\"token\":\"abc\",\"expiry\":2000000030}".utf8), now: now), nil,
                    "token: 离过期不到一分钟不用")
        expectEqual(AppleMusicDeveloperToken.parse(Data("{\"expiry\":2000003600}".utf8), now: now), nil, "token: 没有 token 字段")
    }

    // ---- 专辑简介:店面顺序 + 404 换店面 + 404 与失败分开 ----
    do {
        typealias N = AlbumEditorialNotes
        expectEqual(N.albumRef(fromAppleMusicURL: "https://music.apple.com/us/album/fnf/1686489462?i=1686490168&uo=4"),
                    N.AlbumRef(id: 1686489462, storefront: "us"), "店面: 从链接里取专辑 ID 与店面")
        expectEqual(N.albumRef(fromAppleMusicURL: "https://music.apple.com/album/272875165"),
                    N.AlbumRef(id: 272875165, storefront: nil), "店面: 链接不带店面时为 nil")
        expectEqual(N.albumRef(fromAppleMusicURL: "https://y.qq.com/n/ryqq/albumDetail/1"), nil, "店面: 别的平台的链接不认")
        expectEqual(N.storefronts(region: "CN", linkStorefront: "us"), ["cn", "us"], "店面: 用户地区在前、链接店面在后,小写")
        expectEqual(N.storefronts(region: "cn", linkStorefront: "CN"), ["cn"], "店面: 两个一样只问一次")
        expectEqual(N.storefronts(region: nil, linkStorefront: "jp"), ["jp"], "店面: 没有地区就只问链接店面")
        expectEqual(N.storefronts(region: nil, linkStorefront: nil), ["us"], "店面: 都没有退回 us")

        expectEqual(N.PageFetch.classify(statusCode: 200, body: "x"), .ok("x"), "页面: 200 = 取到")
        expectEqual(N.PageFetch.classify(statusCode: 404, body: "x"), .notFound, "页面: 404 = 这个店面没有,不是失败")
        expectEqual(N.PageFetch.classify(statusCode: 503, body: nil), .failed, "页面: 5xx = 失败,下次再试")
        expectEqual(N.PageFetch.classify(statusCode: nil, body: nil), .failed, "页面: 网络错误 = 失败")
        expectEqual(N.PageFetch.classify(statusCode: 200, body: nil), .failed, "页面: 200 但正文解不出 = 失败")

        let html = "<html><script type=\"application/json\" id=\"serialized-server-data\">"
            + "{\"data\":[{\"contentDescriptor\":{\"kind\":\"album\",\"identifiers\":{\"storeAdamID\":\"7\"}},"
            + "\"modalPresentationDescriptor\":{\"paragraphText\":\"正文\"}}]}</script></html>"
        func resolve(_ storefronts: [String], _ answers: [String: N.PageFetch]) -> (N.AlbumPageResult, [String]) {
            final class Box: @unchecked Sendable { var result: N.AlbumPageResult = .failed; var asked: [String] = [] }
            let box = Box()
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                box.result = await N.resolveAlbumPage(albumID: 7, storefronts: storefronts) { url in
                    let sf = url.pathComponents.dropFirst().first ?? ""
                    box.asked.append(sf)
                    return answers[sf] ?? .failed
                }
                sem.signal()
            }
            sem.wait()
            return (box.result, box.asked)
        }
        let page = N.parseAlbumPage(html: html, albumID: 7)!
        var r = resolve(["cn", "us"], ["cn": .notFound, "us": .ok(html)])
        expectEqual(r.0, .found(page, storefront: "us"), "换店面: 用户店面 404,链接店面取到,记下是哪个店面给的")
        expectEqual(r.1, ["cn", "us"], "换店面: 按顺序问")
        r = resolve(["cn", "us"], ["cn": .ok(html)])
        expectEqual(r.1, ["cn"], "换店面: 第一个取到就不再问")
        r = resolve(["cn", "us"], ["cn": .notFound, "us": .notFound])
        expectEqual(r.0, .missing, "换店面: 都 404 = 没有(本次运行不再问)")
        r = resolve(["cn", "us"], ["cn": .failed, "us": .ok(html)])
        expectEqual(r.0, .failed, "换店面: 网络失败直接停,算失败(下次再试),不去问下一个店面")
        expectEqual(r.1, ["cn"], "换店面: 失败后不再问")
        r = resolve(["cn"], ["cn": .ok("<html>形状不对</html>")])
        expectEqual(r.0, .failed, "换店面: 页面形状不对算失败")
        expectEqual(resolve([], [:]).0, .failed, "换店面: 没有店面可问算失败")
    }

    // ---- 简介的 Last.fm 兜底:解析 artist.getInfo / album.getInfo ----
    do {
        typealias L = LastfmEditorialInfo
        func json(_ s: String) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) ?? [:]
        }
        let tail = " <a href=\"https://www.last.fm/music/9m88\">Read more on Last.fm</a>. User-contributed text is available under the Creative Commons By-SA License; additional terms may apply."
        expectEqual(L.cleaned("9m88 is a Taiwan-raised musician." + tail), "9m88 is a Taiwan-raised musician.",
                    "Last.fm 简介: 末尾「Read more / 授权声明」整段去掉(出处由卡片注明)")
        expectEqual(L.cleaned("R&amp;B &quot;soul&quot; it&#39;s"), "R&B \"soul\" it's", "Last.fm 简介: 解常见 HTML 实体")
        expectEqual(L.cleaned("&amp;lt;"), "&lt;", "Last.fm 简介: &amp; 最后解,不多解一层")
        expectEqual(L.cleaned(tail), "", "Last.fm 简介: 只有尾巴没有正文 = 空")

        let artistJSON = json(#"{"artist":{"name":"9m88","bio":{"summary":"短","content":"9m88 is a musician. <a href=\"x\">Read more on Last.fm</a>."}}}"#)
        expectEqual(L.artistBio(from: artistJSON), .text("9m88 is a musician."), "Last.fm 歌手: 取 content")
        let summaryOnly = json(#"{"artist":{"name":"x","bio":{"summary":"Only summary.","content":""}}}"#)
        expectEqual(L.artistBio(from: summaryOnly), .text("Only summary."), "Last.fm 歌手: content 空时退 summary")
        let emptyBio = json(#"{"artist":{"name":"x","bio":{"summary":" <a href=\"x\">Read more on Last.fm</a>","content":""}}}"#)
        expectEqual(L.artistBio(from: emptyBio), L.Parsed.none, "Last.fm 歌手: 只有尾巴 = 明确没有(不是失败)")
        expectEqual(L.artistBio(from: json(#"{"artist":{"name":"x"}}"#)), L.Parsed.none, "Last.fm 歌手: 没有 bio 字段 = 没有")
        expectEqual(L.artistBio(from: json(#"{"error":6,"message":"not found"}"#)), nil, "Last.fm 歌手: 形状不对是 nil(不记结论)")

        let albumJSON = json(#"{"album":{"name":"HIT ME HARD AND SOFT","wiki":{"published":"04 Apr 2026","summary":"s","content":"The third studio album. <a href=\"x\">Read more on Last.fm</a>."}}}"#)
        expectEqual(L.albumWiki(from: albumJSON), .text("The third studio album."), "Last.fm 专辑: 取 wiki.content")
        expectEqual(L.albumWiki(from: json(#"{"album":{"name":"平庸之上","tracks":{}}}"#)), L.Parsed.none,
                    "Last.fm 专辑: 没有 wiki 字段 = 这张没有介绍(实测《平庸之上》)")
        expectEqual(L.albumWiki(from: json(#"{"artist":{}}"#)), nil, "Last.fm 专辑: 形状不对是 nil")

        expectEqual(L.preferredLang(uiLanguage: "zh-hans"), "zh", "Last.fm 语言: 简体中文界面先要中文")
        expectEqual(L.preferredLang(uiLanguage: "zh-Hant"), "zh", "Last.fm 语言: 繁体中文界面同样先要中文")
        expectEqual(L.preferredLang(uiLanguage: "en"), nil, "Last.fm 语言: 英文界面只要默认那份")

        // 源码契约:只在 Apple 那条路确定没有时退到 Last.fm;卡片注明出处;请求走带限速的那条通道。
        let ui = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let store = (try? String(contentsOf: ui.appendingPathComponent("lyrimuse/UI/EditorialNotes.swift"), encoding: .utf8)) ?? ""
        let service = (try? String(contentsOf: ui.appendingPathComponent("lyrimuse/Settings/LastfmStatsService.swift"), encoding: .utf8)) ?? ""
        expectEqual(store.components(separatedBy: "fallback(.album, track)").count - 1, 2,
                    "简介兜底契约: 专辑两处退兜底(网易云 / Last.fm)—— 没有 Apple 专辑链接、公开页没有简介")
        expectEqual(store.components(separatedBy: "fallback(.artist, track)").count - 1, 4,
                    "简介兜底契约: 歌手四处退兜底(网易云 / Last.fm)—— 记过找不到、同歌手专辑都对不上、缓存命中没简介、请求回来没简介")
        expectEqual(store.contains("Self.logger.debug(\"siblings: enrich cache not loaded yet\")\n            artist = nil\n            return"), true,
                    "简介兜底契约: enrich 缓存还没加载好不算「没有」,不退 Last.fm")
        expectEqual(store.contains("if let attribution = card.source.attribution {\n                Text(attribution)")
                    && store.contains("case .appleMusic: return nil\n            case .lastfm: return L10n.t(\"来自 Last.fm\")\n            case .netease: return L10n.t(\"来自网易云音乐\")\n            case .qqMusic: return L10n.t(\"来自 QQ 音乐\")\n            case .soda: return L10n.t(\"来自汽水音乐\")\n            case .youtubeMusic: return L10n.t(\"来自维基百科\")"),
                    true, "简介兜底契约: Last.fm(CC BY-SA)、网易云、QQ 音乐、汽水的卡片注明出处,YouTube Music 那一路注明维基百科,Apple Music 的不注")
        expectEqual(service.contains("return await requestDetailed(method: method, cred: cred, extra: extra, priority: .interactive)"), true,
                    "简介兜底契约: 查询走 LastfmStatsService 那条带限速与退避的通道")
    }

    // ---- 歌手 / 专辑简介的网易云来源:缓存里的网易云歌曲页 → 署名 / 所在专辑 → 介绍 ----
    do {
        typealias E = NeteaseEditorialInfo
        func data(_ s: String) -> Data { Data(s.utf8) }
        expectEqual(E.songID(fromSongPage: URL(string: "https://music.163.com/song?id=1962165963")), 1962165963,
                    "网易云简介: 歌曲页取歌曲 ID")
        expectEqual(E.songID(fromSongPage: URL(string: "https://music.163.com/#/song?id=185910")), 185910,
                    "网易云简介: 带 #/ 的歌曲页也认")
        expectEqual(E.songID(fromSongPage: URL(string: "https://music.163.com/search?s=x")), nil, "网易云简介: 不是歌曲页不认")
        expectEqual(E.songID(fromSongPage: URL(string: "https://example.com/song?id=1")), nil, "网易云简介: 别的域名不认")
        expectEqual(E.songID(fromSongPage: nil), nil, "网易云简介: 缓存里没有网易云歌曲页")
        expectEqual(E.songDetailURL(songID: 1962165963)?.absoluteString,
                    "https://music.163.com/api/song/detail?ids=%5B1962165963%5D", "网易云简介: 歌曲详情地址")
        expectEqual(E.introductionURL(artistID: 6452)?.absoluteString,
                    "https://music.163.com/api/artist/introduction?id=6452", "网易云简介: 歌手介绍地址")

        let detail = data(#"{"songs":[{"name":"说好不哭","id":1962165963,"artists":[{"id":6452,"name":"周杰伦"},{"id":1875,"name":"五月天 阿信"},{"id":0,"name":"占位"}]}],"code":200}"#)
        let expectedCredits: [AlbumEditorialNotes.ArtistLink] = [.init(name: "周杰伦", id: 6452), .init(name: "五月天 阿信", id: 1875)]
        expectEqual(E.song(fromDetail: detail)?.artists, expectedCredits, "网易云简介: 署名按顺序取,ID 为 0 的占位不算(实测《说好不哭》)")
        expectEqual(E.song(fromDetail: data(#"{"songs":[],"equalizers":{},"code":200}"#)), E.Song(artists: [], album: nil),
                    "网易云简介: 没有这首 = 没有署名也没有专辑(明确没有,实测)")
        expectEqual(E.song(fromDetail: data(#"{"code":-460,"message":"Cheating"}"#)), nil, "网易云简介: 风控 = 没问成")
        expectEqual(E.song(fromDetail: data("not json")), nil, "网易云简介: 形状不对 = 没问成")
        expectEqual(AlbumEditorialNotes.pickArtist(expectedCredits, localArtist: "周杰伦 & 五月天 阿信")?.id, 6452,
                    "网易云简介: 合唱挑署名里对得上的第一位")
        expectEqual(AlbumEditorialNotes.pickArtist(expectedCredits, localArtist: "Jay Chou")?.id, nil,
                    "网易云简介: 多位署名都对不上不猜")

        let intro = data(#"{"briefDesc":"圈住那个9（圈9、WineQ），本名史兆怡。\n\n  2013年，获得广东省音乐术科省状元。  \n","introduction":[],"count":0,"code":200}"#)
        expectEqual(E.introduction(from: intro), .text("圈住那个9（圈9、WineQ），本名史兆怡。\n\n2013年，获得广东省音乐术科省状元。"),
                    "网易云简介: 总述按段收拾 —— 去掉首尾空白和空行,段与段之间空一行")
        let long = String(repeating: "长", count: 2001)
        let sectionsOnly = data(#"{"briefDesc":" ","introduction":[{"ti":"代表作品","txt":"晴天、七里香"},{"ti":"演艺经历","txt":"\#(long)"}],"code":200}"#)
        expectEqual(E.introduction(from: sectionsOnly), .text("代表作品\n晴天、七里香"), "网易云简介: 总述是空的才用分段,上千字的长段不放")
        expectEqual(E.introduction(from: data(#"{"briefDesc":"","introduction":[],"code":200}"#)), E.Parsed.none,
                    "网易云简介: 总述、分段都空 = 明确没有")
        expectEqual(E.introduction(from: data(#"{"code":404}"#)), E.Parsed.none, "网易云简介: 没有这位歌手(code 404)= 明确没有(实测)")
        expectEqual(E.introduction(from: data(#"{"code":-460,"message":"Cheating"}"#)), nil, "网易云简介: 风控 = 没问成(不记结论)")

        expectEqual(E.isUsable(uiLanguage: "zh-hans"), true, "网易云简介: 简体中文界面问网易云")
        expectEqual(E.isUsable(uiLanguage: "zh-hant"), true, "网易云简介: 繁体中文界面也问")
        expectEqual(E.isUsable(uiLanguage: "en"), false, "网易云简介: 英文界面不问(介绍只有中文)")
        expectEqual(E.isUsable(uiLanguage: "ja"), false, "网易云简介: 别的非中文界面也不问")
        expectEqual(E.localized("周杰伦出生于台湾", uiLanguage: "zh-hans"), "周杰伦出生于台湾", "网易云简介: 简体界面原样")
        expectEqual(E.localized("周杰伦出生于台湾", uiLanguage: "zh-hant").contains("倫"), true, "网易云简介: 繁体界面转成繁体")
        expectEqual(E.localized("周杰伦", uiLanguage: "en"), "周杰伦", "网易云简介: 英文界面原样")

        // 专辑:歌曲详情里带着所在专辑(ID、名字、别名);介绍在专辑页的 description(歌曲详情里那份是空的,实测)。
        expectEqual(E.albumURL(albumID: 147779282)?.absoluteString, "https://music.163.com/api/v1/album/147779282",
                    "网易云专辑: 专辑页地址(v1 端点,老端点常被风控)")
        let detailWithAlbum = data(#"{"songs":[{"name":"说好不哭","id":1962165963,"artists":[{"id":6452,"name":"周杰伦"}],"album":{"id":147779282,"name":"最伟大的作品","alias":["Greatest Works of Art"],"transName":null,"description":""}}],"code":200}"#)
        let greatest = E.Album(id: 147779282, name: "最伟大的作品", aliases: ["Greatest Works of Art"])
        expectEqual(E.song(fromDetail: detailWithAlbum)?.album, greatest, "网易云专辑: 歌曲详情取所在专辑和别名,transName 是 null 不算(实测)")
        expectEqual(E.song(fromDetail: data(#"{"songs":[{"id":1,"artists":[],"album":{"id":0,"name":""}}],"code":200}"#))?.album, nil,
                    "网易云专辑: 专辑 ID 为 0 = 没有专辑")
        expectEqual(E.song(fromDetail: data(#"{"songs":[{"id":1,"artists":[],"album":{"id":5,"name":"A","alias":[" "],"transName":"B"}}],"code":200}"#))?.album?.aliases,
                    ["B"], "网易云专辑: 空白别名不算,transName 也当别名")

        expectEqual(greatest.matches(playing: "最偉大的作品"), true, "网易云专辑: 繁简不算差别")
        expectEqual(greatest.matches(playing: "Greatest Works of Art"), true, "网易云专辑: 别名对上也算(美区店面给英文名)")
        expectEqual(greatest.matches(playing: ""), false, "网易云专辑: 没报专辑名比不了,算对不上")
        expectEqual(E.Album(id: 1, name: "后青春期的诗").matches(playing: "後 青春期的詩"), true, "网易云专辑: 空格、繁简都折掉(实测五月天)")
        expectEqual(E.Album(id: 1, name: "It's Ū").matches(playing: "It's Ū - Single"), true, "网易云专辑: Apple 加的 - Single 不算差别(实测)")
        expectEqual(E.Album(id: 1, name: "SOS").matches(playing: "SOS Deluxe: LANA"), false, "网易云专辑: 同一首挂在另一版(豪华版)上算对不上")
        expectEqual(E.Album(id: 1, name: "大雨", aliases: ["滚石40 滚石撞乐队 40团拚经典 （原唱:娃娃）"])
                        .matches(playing: "滾石40 滾石撞樂隊 40團拚經典 - 大雨"), false,
                    "网易云专辑: 网易云挂的是单曲、正在放的是合辑,对不上(实测 deca joins)")

        let albumPage = data(#"{"album":{"id":147779282,"name":"最伟大的作品","description":"当一件伟大的作品被创作出来时\n艺术家并不会知道\n\n\n终于等到\r\n周杰伦\n\u3000\u3000专辑共收录12首  \n\n","briefDesc":""},"code":200}"#)
        expectEqual(E.albumDescription(from: albumPage), .text("当一件伟大的作品被创作出来时\n艺术家并不会知道\n\n终于等到\n周杰伦\n专辑共收录12首"),
                    "网易云专辑: 介绍保留分行 —— 每行去掉首尾空白(含全角缩进),连续空行并成一个,\\r\\n 不多出空行")
        expectEqual(E.albumDescription(from: data(#"{"album":{"description":"","briefDesc":"短介绍"},"code":200}"#)), .text("短介绍"),
                    "网易云专辑: description 空了才用 briefDesc")
        expectEqual(E.albumDescription(from: data(#"{"album":{"description":" \n ","briefDesc":""},"code":200}"#)), E.Parsed.none,
                    "网易云专辑: 介绍是空的 = 明确没有(欧美专辑常见,实测)")
        expectEqual(E.albumDescription(from: data(#"{"resourceState":false,"code":404}"#)), E.Parsed.none,
                    "网易云专辑: 没有这张专辑(code 404)= 明确没有(实测)")
        expectEqual(E.albumDescription(from: data(#"{"code":-462,"message":"需要行为验证码验证"}"#)), nil,
                    "网易云专辑: 风控 = 没问成(不记结论;老端点实测 -462)")
        expectEqual(E.albumDescription(from: data(#"{"code":200}"#)), nil, "网易云专辑: 没有 album 字段 = 形状不对")

        // 源码契约:网易云在兜底链里、中文界面在前,专辑、歌手都有;没连 Last.fm 跳过它;没问成不往下走;只按歌曲页拿歌手和专辑、
        // 不按名字搜;专辑要对得上;两路同时要同一首的歌曲详情时后到的排队等。
        let ui = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let store = (try? String(contentsOf: ui.appendingPathComponent("lyrimuse/UI/EditorialNotes.swift"), encoding: .utf8)) ?? ""
        for (needle, label) in [
            ("? [.soda, .netease, .youtubeMusic, .lastfm] : [.youtubeMusic, .lastfm]",
             "中文界面汽水、网易云、YouTube Music 排在 Last.fm 前面,别的界面不问汽水和网易云"),
            ("case (.lastfm, _) where !LastfmStatsService.shared.isConnected:\n            fallback(kind, track, via: sources.dropFirst())",
             "没连 Last.fm 账号就跳过它"),
            ("guard let card else { return self.fallback(kind, track, via: sources.dropFirst()) }", "前一个明确没有才问下一个"),
            ("case (.netease, .album): neteaseAlbum(track, then: next)\n        case (.netease, .artist): neteaseArtist(track, then: next)",
             "专辑、歌手都有网易云这一路"),
            ("guard let song else { return }", "歌曲详情没问成不往下走"),
            ("NeteaseEditorialInfo.songID(fromSongPage: links?.neteaseSong)", "歌手、专辑只从这首的网易云歌曲页来"),
            ("guard let album = song.album, album.matches(playing: track.album) else { return then(nil) }",
             "专辑要跟正在放的对得上,对不上交给下一个来源"),
            ("guard neteaseSongWaiters[songID] == nil else {\n            neteaseSongWaiters[songID]?.append(waiter)\n            return",
             "歌曲详情在飞时,后到的那一路排队等,不丢"),
            ("guard waiting.allSatisfy({ $0.key == self.currentKey }) else { return self.refreshCurrent() }\n            waiting.forEach { $0.body(song) }",
             "歌曲详情回来时已经换歌就按当前曲目重查,否则挨个回调"),
            ("EditorialCard(kind: .album, title: track.album, subtitle: track.artist, facts: [], text: $0, source: .netease)",
             "专辑卡片用播放器报的名字,注明来自网易云"),
        ] {
            expectEqual(store.contains(needle), true, "网易云简介契约: \(label)")
        }
        expectEqual(store.components(separatedBy: "guard let parsed else { return }").count - 1, 3,
                    "网易云简介契约: 歌手介绍、专辑介绍(以及 QQ 的歌曲简介)没问成都不往下走")
    }

    // ---- 歌曲简介:没有 Apple 那一档;中文界面 QQ 音乐 → Last.fm,别的界面只问 Last.fm ----
    do {
        typealias Q = QQSongInfo
        func data(_ s: String) -> Data { Data(s.utf8) }
        func json(_ s: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:] }

        let body = Q.detailBody(songMID: "002s70oC2k2VbG").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let songinfo = body?["songinfo"] as? [String: Any]
        expectEqual(songinfo?["module"] as? String, "music.pf_song_detail_svr", "QQ 歌曲简介: 请求的是歌曲详情模块")
        expectEqual(songinfo?["method"] as? String, "get_song_detail_yqq", "QQ 歌曲简介: 方法名")
        expectEqual((songinfo?["param"] as? [String: Any])?["song_mid"] as? String, "002s70oC2k2VbG", "QQ 歌曲简介: 按缓存里的 songmid 问")
        expectEqual(Q.detailBody(songMID: "不是 mid"), nil, "QQ 歌曲简介: 不像 songmid 的不拼请求")
        expectEqual(Q.gatewayURL.absoluteString, "https://u.y.qq.com/cgi-bin/musicu.fcg", "QQ 歌曲简介: 客户端网关地址")

        let liang = data(#"{"code":0,"songinfo":{"code":0,"data":{"track_info":{"name":"梯田"},"info":{"genre":{"title":"歌曲流派","content":[{"value":"Pop"}]},"intro":{"title":"简介","type":"SPECIAL_DISPLAY","content":[{"id":0,"value":"  《梯田》这首歌曲周杰伦首创以原住民的合唱。\r\n\n\n歌词诙谐幽默。 "}]}}}}}"#)
        expectEqual(Q.intro(fromDetail: liang), .text("《梯田》这首歌曲周杰伦首创以原住民的合唱。\n\n歌词诙谐幽默。"),
                    "QQ 歌曲简介: 取 info.intro 的正文,保留分行(实测《梯田》的形状),别的栏(流派)不要")
        let twoParts = data(#"{"code":0,"songinfo":{"code":0,"data":{"info":{"intro":{"content":[{"value":"第一段"},{"value":" "},{"value":"第二段"}]}}}}}"#)
        expectEqual(Q.intro(fromDetail: twoParts), .text("第一段\n\n第二段"), "QQ 歌曲简介: 多段之间空一行,空段不算")
        expectEqual(Q.intro(fromDetail: data(#"{"code":0,"songinfo":{"code":0,"data":{"info":{"company":{"content":[{"value":"相信音乐"}]}}}}}"#)),
                    Q.Parsed.none, "QQ 歌曲简介: info 里没有 intro = 这首没有简介(多数歌是这样)")
        expectEqual(Q.intro(fromDetail: data(#"{"code":0,"songinfo":{"code":404,"data":{"info":{},"track_info":{"id":0,"name":""}}}}"#)),
                    Q.Parsed.none, "QQ 歌曲简介: songinfo.code 404 = 没有这首(实测)")
        expectEqual(Q.intro(fromDetail: data(#"{"code":0,"songinfo":{"code":500001,"data":{}}}"#)), nil, "QQ 歌曲简介: 别的错误码 = 没问成")
        expectEqual(Q.intro(fromDetail: data(#"{"code":-100}"#)), nil, "QQ 歌曲简介: 顶层出错 = 没问成")
        expectEqual(Q.intro(fromDetail: data("<html>")), nil, "QQ 歌曲简介: 形状不对 = 没问成")
        expectEqual(Q.isUsable(uiLanguage: "zh-hans") && Q.isUsable(uiLanguage: "zh-hant"), true, "QQ 歌曲简介: 中文界面问")
        expectEqual(Q.isUsable(uiLanguage: "en") || Q.isUsable(uiLanguage: "ja"), false, "QQ 歌曲简介: 别的界面不问(简介只有中文)")
        expectEqual(Q.localized("这首歌曲", uiLanguage: "zh-hant"), "這首歌曲", "QQ 歌曲简介: 繁体界面转成繁体")
        expectEqual(Q.localized("这首歌曲", uiLanguage: "zh-hans"), "这首歌曲", "QQ 歌曲简介: 简体界面原样")

        typealias L = LastfmEditorialInfo
        let trackJSON = json(#"{"track":{"name":"Anti-Hero","wiki":{"published":"21 Oct 2022","summary":"s","content":"\"Anti-Hero\" is a song by Taylor Swift. <a href=\"x\">Read more on Last.fm</a>."}}}"#)
        expectEqual(L.trackWiki(from: trackJSON), .text("\"Anti-Hero\" is a song by Taylor Swift."), "Last.fm 歌曲: 取 wiki.content")
        expectEqual(L.trackWiki(from: json(#"{"track":{"name":"晴天","listeners":"1"}}"#)), L.Parsed.none,
                    "Last.fm 歌曲: 没有 wiki 字段 = 这首没有介绍(实测《晴天》)")
        expectEqual(L.trackWiki(from: json(#"{"album":{}}"#)), nil, "Last.fm 歌曲: 形状不对是 nil")
        expectEqual(ArtistCredit.primary("Taylor Swift & Sabrina Carpenter"), "Taylor Swift",
                    "Last.fm 歌曲: 多人署名能拆出第一位(按完整署名没有正文时再按它问)")

        // 源码契约:歌曲没有 Apple 那一档、每次重查都走兜底链;中文界面 QQ 在前;QQ 只按缓存里的歌曲页问;Last.fm 先完整署名、
        // 再第一位;某一组没有这个条目就换下一组;回来时已经换歌按当前曲目重查。
        let ui = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let store = (try? String(contentsOf: ui.appendingPathComponent("lyrimuse/UI/EditorialNotes.swift"), encoding: .utf8)) ?? ""
        for (needle, label) in [
            ("song = nil\n        fallback(.song, track)", "每次重查都从兜底链起(没有 Apple 那一档)"),
            ("order = QQSongInfo.isUsable(uiLanguage: language) ? [.qqMusic, .lastfm] : [.lastfm]", "中文界面 QQ 排在 Last.fm 前面,别的界面不问 QQ"),
            ("case (.qqMusic, .song): qqSong(track, then: next)", "歌曲有 QQ 这一路"),
            ("case (.lastfm, .song): lastfmSong(track, then: next)", "歌曲有 Last.fm 这一路"),
            ("case (.netease, .song), (.soda, .song), (.youtubeMusic, .song), (.qqMusic, .album), (.qqMusic, .artist), (.appleMusic, _):\n            fallback(kind, track, via: sources.dropFirst())",
             "某一类在某个来源上没有就直接问下一个"),
            ("guard let mid = links?.qqSong.flatMap({ PlatformLinks.qqSongMID(songPage: $0.absoluteString) }) else { return then(nil) }",
             "QQ 只按缓存里这首的歌曲页问(搜索页兜底不算),没有就交给下一个来源"),
            ("if let primary = ArtistCredit.primary(artistName), primary != artistName {\n            variants.append([\"artist\": primary, \"track\": title])",
             "多人署名再按第一位问一次"),
            ("if result.notFound { break }", "某一组没有这个条目就换下一组,不当成整首没有"),
            ("EditorialCard(kind: .song, title: TrackNameDisplay.cleaned(track.title), subtitle: TrackNameDisplay.cleaned(track.artist), facts: [], text: $0, source: .qqMusic)",
             "QQ 的卡片注明来自 QQ 音乐"),
            ("case .song: if self.song == nil { self.song = card }", "取到的歌曲简介只在还空着时放上去"),
        ] {
            expectEqual(store.contains(needle), true, "歌曲简介契约: \(label)")
        }
    }

    // ---- 专辑 / 歌手简介的 YouTube Music(维基百科)一路:按界面语言取,所有界面都问 ----
    do {
        typealias Y = YouTubeMusicEditorialInfo
        func data(_ s: String) -> Data { Data(s.utf8) }
        func jsonObject(_ d: Data?) -> [String: Any] { d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:] }

        expectEqual(Y.descriptionHL(uiLanguage: "zh-hans"), "zh-CN", "YouTube Music 简介: 简体界面要简体中文维基")
        expectEqual(Y.descriptionHL(uiLanguage: "zh-hant"), "zh-TW", "YouTube Music 简介: 繁体界面要繁体中文维基")
        expectEqual(Y.descriptionHL(uiLanguage: "en"), "en", "YouTube Music 简介: 英文界面要英文维基")

        expectEqual(Y.searchHL(artist: "周杰伦", album: "最伟大的作品"), "zh-CN", "YouTube Music 搜索: 简体汉字歌手按简体中文搜")
        expectEqual(Y.searchHL(artist: "周杰倫", album: "最偉大的作品"), "zh-TW", "YouTube Music 搜索: 繁体汉字歌手按繁体中文搜")
        expectEqual(Y.searchHL(artist: "宇多田ヒカル", album: "BADモード"), "ja", "YouTube Music 搜索: 有假名按日文搜")
        expectEqual(Y.searchHL(artist: "아이유", album: "LILAC"), "ko", "YouTube Music 搜索: 谚文按韩文搜")
        expectEqual(Y.searchHL(artist: "Taylor Swift", album: "Midnights"), nil, "YouTube Music 搜索: 拉丁字母歌手不带界面语言")
        expectEqual(Y.searchHL(artist: "五月天 (Mayday)", album: "後 青春期的詩"), nil, "YouTube Music 搜索: 拉丁字母多于汉字时同引擎不带")
        expectEqual(Y.searchHL(artist: "米津玄師", album: "STRAY SHEEP"), "zh-TW", "YouTube Music 搜索: 汉字名的日本歌手头一次按中文搜(同引擎)")

        let romanized = [Y.AlbumHit(browseID: "MPREb_a", title: "STRAY SHEEP", artists: [.init(name: "Kenshi Yonezu", channelID: "UCx")])]
        expectEqual(Y.retryHL(firstHL: "zh-TW", hits: romanized, playingArtist: "米津玄師"), "ja",
                    "YouTube Music 搜索: 按中文搜回罗马字名(Kenshi Yonezu)、一位都对不上 → 换日文再搜(实测)")
        let named = [Y.AlbumHit(browseID: "MPREb_b", title: "自傳", artists: [.init(name: "五月天 (Mayday)", channelID: "UCy")])]
        expectEqual(Y.retryHL(firstHL: "zh-CN", hits: named, playingArtist: "五月天"), nil,
                    "YouTube Music 搜索: 歌手对得上、只是没有这张专辑,不换日文再搜")
        expectEqual(Y.retryHL(firstHL: nil, hits: [], playingArtist: "Taylor Swift"), nil, "YouTube Music 搜索: 不是按中文搜的不重搜")
        expectEqual(Y.retryHL(firstHL: "ja", hits: [], playingArtist: "米津玄師"), nil, "YouTube Music 搜索: 已经是日文不再重搜")

        let search = jsonObject(Y.searchBody(query: "Taylor Swift Midnights", hl: nil, now: Date(timeIntervalSince1970: 1_790_000_000)))
        let client = ((search["context"] as? [String: Any])?["client"] as? [String: Any]) ?? [:]
        expectEqual(search["query"] as? String, "Taylor Swift Midnights", "YouTube Music 搜索: 按「歌手 专辑」搜")
        expectEqual(search["params"] as? String, "EgWKAQIYAWoMEA4QChADEAQQCRAF", "YouTube Music 搜索: 只搜专辑")
        expectEqual(client["clientName"] as? String, "WEB_REMIX", "YouTube Music 请求: 网页客户端身份")
        expectEqual(client["hl"] == nil, true, "YouTube Music 请求: 不带界面语言时不放 hl")
        let browse = jsonObject(Y.browseBody(browseID: "MPREb_z0ABWl3jaT0", hl: "zh-TW"))
        expectEqual(browse["browseId"] as? String, "MPREb_z0ABWl3jaT0", "YouTube Music 请求: 按专辑 ID 取专辑页")
        expectEqual(((browse["context"] as? [String: Any])?["client"] as? [String: Any])?["hl"] as? String, "zh-TW",
                    "YouTube Music 请求: 取介绍按界面语言")

        func item(_ id: String, _ title: String, _ kind: String, _ artists: [(String, String)]) -> String {
            let runs = [#"{"text":"\#(kind)"}"#, #"{"text":" • "}"#]
                + artists.map { #"{"text":"\#($0.0)","navigationEndpoint":{"browseEndpoint":{"browseId":"\#($0.1)"}}}"# }
                + [#"{"text":" • "}"#, #"{"text":"2022"}"#]
            return #"{"musicResponsiveListItemRenderer":{"navigationEndpoint":{"browseEndpoint":{"browseId":"\#(id)"}},"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"\#(title)"}]}}},{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[\#(runs.joined(separator: ","))]}}}]}}"#
        }
        let searchPage = data(#"{"contents":{"tabbedSearchResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"musicShelfRenderer":{"contents":["#
            + [item("MPREb_til", "Midnights (The Til Dawn Edition)", "Album", [("Taylor Swift", "UCPC0L1d253x-KuMNwa05TpA")]),
               item("MPREb_z0ABWl3jaT0", "Midnights", "Album", [("Taylor Swift", "UCPC0L1d253x-KuMNwa05TpA")]),
               item("VLsomething", "Midnights playlist", "Playlist", []),
               item("MPREb_3am", "Midnights (3am Edition)", "Album", [("Taylor Swift", "UCPC0L1d253x-KuMNwa05TpA")])].joined(separator: ",")
            + "]}}]}}}}]}}}")
        let hits = Y.albumHits(fromSearch: searchPage) ?? []
        expectEqual(hits.map(\.browseID), ["MPREb_til", "MPREb_z0ABWl3jaT0", "MPREb_3am"], "YouTube Music 搜索: 只认 MPREb_ 开头的专辑,按给的顺序")
        expectEqual(hits.first?.artists, [Y.Artist(name: "Taylor Swift", channelID: "UCPC0L1d253x-KuMNwa05TpA")],
                    "YouTube Music 搜索: 署名取第二列里链到频道的那几段")
        expectEqual(Y.albumHits(fromSearch: data("[]")), nil, "YouTube Music 搜索: 不是 JSON 对象 = 没问成")
        expectEqual(Y.albumHits(fromSearch: data(#"{"contents":{}}"#)), [], "YouTube Music 搜索: 一条都没有 = 明确没有")
        expectEqual(Y.pickAlbum(hits, playingAlbum: "Midnights", playingArtist: "Taylor Swift")?.browseID, "MPREb_z0ABWl3jaT0",
                    "YouTube Music 搜索: 挑专辑名对得上的那张,版本不同的(3am / Til Dawn)不要")
        expectEqual(Y.pickAlbum(hits, playingAlbum: "Midnights", playingArtist: "Lana Del Rey")?.browseID, nil,
                    "YouTube Music 搜索: 署名对不上不要")
        expectEqual(Y.pickAlbum([.init(browseID: "MPREb_g", title: "最偉大的作品", artists: [.init(name: "周杰倫", channelID: "UCj")])],
                                playingAlbum: "最伟大的作品", playingArtist: "周杰伦")?.browseID, "MPREb_g",
                    "YouTube Music 搜索: 专辑名、歌手名的繁简不算差别(实测)")
        expectEqual(Y.pickAlbum([.init(browseID: "MPREb_h", title: "後 . 青春期的詩", artists: [.init(name: "五月天 (Mayday)", channelID: "UCm")])],
                                playingAlbum: "後 青春期的詩", playingArtist: "五月天 (Mayday)")?.browseID, "MPREb_h",
                    "YouTube Music 搜索: 标点不同的专辑名算同一张(实测)")

        expectEqual(Y.artistMatches("田馥甄 Hebe Tien", playingArtist: "田馥甄"), true, "YouTube Music 署名: 带英文名也算(实测)")
        expectEqual(Y.artistMatches("Taylor Swift", playingArtist: "Taylor Swift & Sabrina Carpenter"), true, "YouTube Music 署名: 合唱里有这位就算")
        expectEqual(Y.artistMatches("Kenshi Yonezu", playingArtist: "米津玄師"), false, "YouTube Music 署名: 罗马字名对不上汉字名")
        expectEqual(Y.artistMatches("A", playingArtist: "ABBA"), false, "YouTube Music 署名: 单个字母不算包含")
        expectEqual(Y.artistMatches("", playingArtist: "x"), false, "YouTube Music 署名: 空名字不算")

        func wikiRuns(_ body: String, _ trailer: String, _ link: String, _ tail: [String]) -> String {
            let rest = tail.map { #"{"text":"\#($0)"}"# }.joined(separator: ",")
            let body = body.replacingOccurrences(of: "\n", with: #"\n"#)
            return #"[{"text":"\#(body)\n\n\#(trailer)"},{"text":"\#(link)","navigationEndpoint":{"urlEndpoint":{"url":"https://www.youtube.com/redirect"}}}"#
                + (rest.isEmpty ? "" : "," + rest) + "]"
        }
        func albumPageJSON(_ runs: String) -> Data {
            data(#"{"contents":{"twoColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"musicResponsiveHeaderRenderer":{"title":{"runs":[{"text":"Midnights"}]},"straplineTextOne":{"runs":[{"text":"Taylor Swift","navigationEndpoint":{"browseEndpoint":{"browseId":"UCPC0L1d253x-KuMNwa05TpA"}}}]},"description":{"musicDescriptionShelfRenderer":{"description":{"runs":"#
                 + runs + "}}}}}]}}}}]}}}")
        }
        let zhPage = Y.albumPage(from: albumPageJSON(wikiRuns("《午夜》是美国创作歌手泰勒·斯威夫特的第十张录音室专辑。\n\n她自2023年3月举行了“时代巡回演唱会”。",
                                                             "来自“Wikipedia”(", "https://zh.wikipedia.org/zh-cn/午夜_(专辑...",
                                                             [" Commons Attribution CC-BY-SA 3.0”(", ")"])))
        expectEqual(zhPage?.description, "《午夜》是美国创作歌手泰勒·斯威夫特的第十张录音室专辑。\n\n她自2023年3月举行了“时代巡回演唱会”。",
                    "YouTube Music 专辑页: 维基介绍去掉最后那段出处(简体中文的写法,实测)")
        expectEqual(zhPage?.artists, [Y.Artist(name: "Taylor Swift", channelID: "UCPC0L1d253x-KuMNwa05TpA")],
                    "YouTube Music 专辑页: 署名取头部歌手那一行的频道链接")
        let runsJSON: (String) -> [[String: Any]] = { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [[String: Any]] ?? [] }
        expectEqual(Y.wikipediaText(fromRuns: runsJSON(wikiRuns("Midnights is the tenth studio album.", "From Wikipedia (",
                                                                "https://en.wikipedia.org/wiki/Midnights", [") under Creative Commons", ")"]))),
                    "Midnights is the tenth studio album.", "YouTube Music 专辑页: 英文出处同样去掉(实测)")
        expectEqual(Y.wikipediaText(fromRuns: runsJSON(wikiRuns("《午夜》是泰勒絲的第十張專輯。", "資料來源為 Wikipedia (",
                                                                "https://zh.wikipedia.org/zh-tw/午夜_(专辑...", [") 使用"]))),
                    "《午夜》是泰勒絲的第十張專輯。", "YouTube Music 专辑页: 繁体中文的出处写法也去掉(实测)")
        expectEqual(Y.wikipediaText(fromRuns: runsJSON(wikiRuns("『ミッドナイツ』は10枚目のアルバム。", "引用元: Wikipedia（",
                                                                "https://ja.wikipedia.org/wiki/ミッドナイツ_...", [" Commons Attribution CC-BY-SA 3.0 （"]))),
                    "『ミッドナイツ』は10枚目のアルバム。", "YouTube Music 专辑页: 日文的出处写法也去掉(实测)")
        let blurb = runsJSON(#"[{"text":"baby, that’s show business for you. New album The Life of a Showgirl. Out October 3\n"},{"text":"https://Taylor.lnk.to/TSTheLifeofaSho...","navigationEndpoint":{"urlEndpoint":{"url":"x"}}}]"#)
        expectEqual(Y.wikipediaText(fromRuns: blurb), nil, "YouTube Music 歌手页: 频道自己的宣传语(没有维基出处)不算简介(实测 Taylor Swift 英文页)")
        expectEqual(Y.albumPage(from: data(#"{"responseContext":{},"trackingParams":"x","microformat":{}}"#)),
                    Y.AlbumPage(description: nil, artists: []), "YouTube Music 专辑页: 没有 contents = 专辑不存在(HTTP 照样 200,实测)")
        expectEqual(Y.albumPage(from: data("<html>")), nil, "YouTube Music 专辑页: 形状不对 = 没问成")
        let artistWiki = data(#"{"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"musicDescriptionShelfRenderer":{"header":{"runs":[{"text":"关于"}]},"description":{"runs":"#
            + wikiRuns("方大同，美籍香港创作男歌手。", "来自“Wikipedia”(", "https://zh.wikipedia.org/zh-cn/方大同", [")"]) + "}}}]}}}}]}}}")
        expectEqual(Y.artistDescription(from: artistWiki), .text("方大同，美籍香港创作男歌手。"), "YouTube Music 歌手页: 取维基介绍")
        let artistBlurb = data(#"{"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"musicDescriptionShelfRenderer":{"description":{"runs":[{"text":"New album out now"}]}}}]}}}}]}}}"#)
        expectEqual(Y.artistDescription(from: artistBlurb), Y.Parsed.none, "YouTube Music 歌手页: 只有宣传语 = 明确没有,交给下一个来源")
        expectEqual(Y.artistDescription(from: data(#"{"responseContext":{}}"#)), Y.Parsed.none, "YouTube Music 歌手页: 频道不存在 = 明确没有")
        expectEqual(Y.artistDescription(from: data("[")), nil, "YouTube Music 歌手页: 形状不对 = 没问成")

        expectEqual(Y.browseID(fromAlbumPage: URL(string: "https://music.youtube.com/browse/MPREb_z0ABWl3jaT0")), "MPREb_z0ABWl3jaT0",
                    "YouTube Music: 缓存里播放器给的专辑页取专辑 ID")
        expectEqual(Y.browseID(fromAlbumPage: URL(string: "https://music.youtube.com/browse/VLPLxxx")), nil, "YouTube Music: 不是专辑的 browse 不认")
        expectEqual(Y.channelID(fromArtistPage: URL(string: "https://music.youtube.com/channel/UCPC0L1d253x-KuMNwa05TpA")),
                    "UCPC0L1d253x-KuMNwa05TpA", "YouTube Music: 缓存里播放器给的歌手页取频道 ID")
        expectEqual(Y.channelID(fromArtistPage: URL(string: "https://example.com/channel/UCx")), nil, "YouTube Music: 别的域名不认")

        // 汽水:用汽水放过的歌,缓存里的分享页 → 介绍
        typealias S = SodaEditorialInfo
        expectEqual(S.pageKind(of: URL(string: "https://music.douyin.com/qishui/share/album?album_id=7687934888654342145")!), .album,
                    "汽水简介: 专辑分享页")
        expectEqual(S.pageKind(of: URL(string: "https://music.douyin.com/qishui/share/artist?artist_id=6841932444073986049")!), .artist,
                    "汽水简介: 歌手分享页")
        expectEqual(S.pageKind(of: URL(string: "https://music.douyin.com/qishui/share/track?track_id=1")!), nil, "汽水简介: 单曲页不认")
        let routed = S.routerData(fromPage: data(#"<script>window._ROUTER_DATA = {"a":"x}{\"y","b":{"c":1}};window.other = {"d":2}</script>"#))
        expectEqual(routed?["a"] as? String, "x}{\"y", "汽水简介: 页面数据按括号配对切出来,字符串里的括号和转义引号不算")
        expectEqual((routed?["b"] as? [String: Any])?["c"] as? Int, 1, "汽水简介: 页面数据的嵌套对象完整")
        expectEqual(routed?["d"] == nil, true, "汽水简介: 后面别的脚本不混进来")
        expectEqual(S.routerData(fromPage: data("<html>没有页面数据</html>")) == nil, true, "汽水简介: 没有页面数据")
        func sodaPage(_ loader: String) -> Data { data("<html><script>_ROUTER_DATA = {\"loaderData\":" + loader + "}</script></html>") }
        let albumPage = sodaPage(#"{"album_layout":null,"album_page":{"albumInfo":{"id":"7687934888654342145","name":"要去什么地方","intro":"『你啊 就别再烦恼啦』\n去吧去吧，别再烦恼了  \n\n\n田馥甄第六张全新专辑"}}}"#)
        expectEqual(S.intro(fromPage: albumPage, kind: .album), S.Intro(name: "要去什么地方", text: "『你啊 就别再烦恼啦』\n去吧去吧，别再烦恼了\n\n田馥甄第六张全新专辑"),
                    "汽水简介: 专辑介绍保留分行(实测《要去什么地方》的形状)")
        expectEqual(S.intro(fromPage: sodaPage(#"{"album_page":{"albumInfo":{"id":"1","name":"未知专辑","hasError":true}}}"#), kind: .album),
                    S.Intro(name: nil, text: nil), "汽水简介: 专辑不存在(hasError,HTTP 照样 200,实测)= 明确没有")
        expectEqual(S.intro(fromPage: sodaPage(#"{"album_page":{"albumInfo":{"id":"2","name":"x","intro":" "}}}"#), kind: .album)?.text, nil,
                    "汽水简介: 介绍是空的 = 明确没有")
        let artistPage = sodaPage(#"{"artist_page":{"artistInfo":{"name":"田馥甄","artist_profile":{"intro":"中国台湾女歌手、演员，华语女子演唱组合S.H.E成员之一。"}}}}"#)
        expectEqual(S.intro(fromPage: artistPage, kind: .artist), S.Intro(name: "田馥甄", text: "中国台湾女歌手、演员，华语女子演唱组合S.H.E成员之一。"),
                    "汽水简介: 歌手页取汽水写的歌手名和介绍(实测田馥甄)")
        expectEqual(S.intro(fromPage: artistPage, kind: .album) == nil, true, "汽水简介: 页面类型对不上 = 形状不对")
        expectEqual(S.isUsable(uiLanguage: "zh-hans") && S.isUsable(uiLanguage: "zh-hant") && !S.isUsable(uiLanguage: "en"), true,
                    "汽水简介: 只在中文界面问(介绍只有中文)")
        expectEqual(S.localized("这张专辑", uiLanguage: "zh-hant"), "這張專輯", "汽水简介: 繁体界面转成繁体")

        // 源码契约:汽水只按缓存里的分享页问;YouTube Music 先用播放器给的 ID、没有才搜,两路共用一次专辑查询(后到的排队),
        // 歌手从对上的专辑页署名里来、不按名字搜;界面语言那版没有退英文版。
        let ui = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let store = (try? String(contentsOf: ui.appendingPathComponent("lyrimuse/UI/EditorialNotes.swift"), encoding: .utf8)) ?? ""
        for (needle, label) in [
            ("case (.soda, .album): sodaAlbum(track, then: next)\n        case (.soda, .artist): sodaArtist(track, then: next)", "专辑、歌手都有汽水这一路"),
            ("case (.youtubeMusic, .album): youtubeMusicAlbum(track, then: next)\n        case (.youtubeMusic, .artist): youtubeMusicArtist(track, then: next)",
             "专辑、歌手都有 YouTube Music 这一路"),
            ("guard let page = links?.sodaAlbum, !track.album.isEmpty else { return then(nil) }", "汽水专辑只按缓存里的分享页问(用汽水放过才有)"),
            ("guard let page = links?.sodaArtist else { return then(nil) }", "汽水歌手只按缓存里的分享页问"),
            ("let knownID = YouTubeMusicEditorialInfo.browseID(fromAlbumPage: links?.youtubeMusicAlbum)", "YouTube Music 专辑先用播放器给的 ID"),
            ("if let channel = YouTubeMusicEditorialInfo.channelID(fromArtistPage: links?.youtubeMusicArtist) {", "YouTube Music 歌手先用播放器给的 ID"),
            ("guard youtubeMusicAlbumWaiters[key] == nil else {\n            youtubeMusicAlbumWaiters[key]?.append(waiter)\n            return",
             "专辑查询在飞时,后到的那一路排队等,不丢"),
            ("?? (credits.count == 1 ? credits[0] : nil) else { return then(nil) }", "歌手从对上的专辑页署名里来,不按名字搜"),
            ("if description == nil, hl != \"en\" {", "专辑介绍界面语言那版没有就退英文版"),
            ("for lang in hl == \"en\" ? [\"en\"] : [hl, \"en\"] {", "歌手介绍界面语言那版没有就退英文版"),
            ("browseID = YouTubeMusicEditorialInfo.pickAlbum(hits, playingAlbum: album, playingArtist: artist)?.browseID",
             "搜到的专辑要专辑名、歌手都对得上"),
            ("private static let youtubeMusicRetryAfter: TimeInterval = 600", "YouTube Music 问不通后 10 分钟内不再问"),
            ("guard knownID != nil || (!track.album.isEmpty && !track.artist.isEmpty), !youtubeMusicCoolingDown else { return body(nil) }",
             "专辑:冷却期里当没有,交给下一个来源(国内连不上 YouTube 时不把 Last.fm 挡住)"),
            ("guard !youtubeMusicCoolingDown else { return then(nil) }", "歌手:冷却期里当没有,交给下一个来源"),
            ("waiting.forEach { $0.body(lookup?.album) }", "专辑查询问不通时,等它的几路也往下走(不记结论)"),
        ] {
            expectEqual(store.contains(needle), true, "YouTube Music / 汽水简介契约: \(label)")
        }
        expectEqual(store.contains("searchArtist"), false, "YouTube Music / 汽水简介契约: 不按名字搜歌手")
        expectEqual(store.components(separatedBy: "self.youtubeMusicUnreachableSince = Date()").count - 1, 2,
                    "YouTube Music / 汽水简介契约: 专辑查询、歌手介绍问不通都记下时刻,开始冷却")
        expectEqual(store.components(separatedBy: "self.youtubeMusicUnreachableSince = nil").count - 1, 2,
                    "YouTube Music / 汽水简介契约: 问通了清掉冷却")
    }

    // ---- 缩略图下载:用到多大就向图床要多大、哪种失败马上再试 ----
    //
    // 「搜索候选歌词」里网易云那条一直是占位图:缩略档照着引擎给的 3000px 地址去下(约 3MB),
    // 撞上图床一次 503,失败被记 10 分钟,整段时间都不再请求。一次搜索十来条候选原来要下约 10MB 封面,
    // 按缩略档要图之后约 0.4MB。每家的档位是同一张图逐档实测出来的(见 CoverThumbnailFetch 头注)。
    do {
        typealias F = CoverThumbnailFetch
        func t(_ s: String) -> String { F.url(for: URL(string: s)!, maxPixel: 256).absoluteString }
        expectEqual(t("https://p1.music.126.net/abc==/1099.jpg?imageView&thumbnail=3000y3000&type=jpg&quality=90"),
                    "https://p1.music.126.net/abc==/1099.jpg?param=256y256", "缩略图下载: 网易云要 256,原查询串整个换掉")
        expectEqual(t("https://p4.music.126.net/x/1.jpg"), "https://p4.music.126.net/x/1.jpg?param=256y256",
                    "缩略图下载: 没有查询串的网易云地址也加上尺寸")
        expectEqual(t("https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/a0/x.rgb.jpg/10000x10000bb.jpg"),
                    "https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/a0/x.rgb.jpg/256x256bb.jpg", "缩略图下载: Apple 要 256")
        expectEqual(t("https://y.qq.com/music/photo_new/T002R800x800M000003zeVgY4BE7Sk.jpg"),
                    "https://y.qq.com/music/photo_new/T002R300x300M000003zeVgY4BE7Sk.jpg", "缩略图下载: QQ 取 300(不小于 256 的那档)")
        expectEqual(t("https://imge.kugou.com/stdmusic/0/20260926/1.jpg"),
                    "https://imge.kugou.com/stdmusic/480/20260926/1.jpg", "缩略图下载: 酷狗原图换 480(240 比 256 小)")
        expectEqual(t("https://img1.kuwo.cn/star/albumcover/0/s4s67/89/1.jpg"),
                    "https://img1.kuwo.cn/star/albumcover/300/s4s67/89/1.jpg", "缩略图下载: 酷我原图换 300")
        expectEqual(t("https://p3-luna.douyinpic.com/img/tos-cn/abc~tplv-b829550vbb-resize:0:0.jpg"),
                    "https://p3-luna.douyinpic.com/img/tos-cn/abc~tplv-b829550vbb-resize:300:300.jpg", "缩略图下载: 汽水原图换 300")
        expectEqual(t("https://s.mxmcdn.net/images-storage/albums2/1/125051961_800_800.jpg"),
                    "https://s.mxmcdn.net/images-storage/albums2/1/125051961_350_350.jpg", "缩略图下载: Musixmatch 取 350(100 是 403)")
        expectEqual(t("https://yt3.googleusercontent.com/KKEMiv9Iul-JvjB=s0"),
                    "https://yt3.googleusercontent.com/KKEMiv9Iul-JvjB=s256", "缩略图下载: Google 图床原图换 =s256")
        expectEqual(t("https://lh3.googleusercontent.com/abc_d=w544-h544-l90-rj"),
                    "https://lh3.googleusercontent.com/abc_d=s256", "缩略图下载: Google 图床带宽高参数的也换 =s256")
        expectEqual(t("https://cdn-images.dzcdn.net/images/cover/42b95263fc55a7b8095b6805149226c4/1800x1800-000000-80-0-0.jpg"),
                    "https://cdn-images.dzcdn.net/images/cover/42b95263fc55a7b8095b6805149226c4/256x256-000000-80-0-0.jpg",
                    "缩略图下载: Deezer 原图换 256")
        // 形状对不上一个字都不改:改错是 404、整张封面消失
        for s in ["https://d.musicapp.migu.cn/data/oss/resource/00/60/ig/9cf9564aff9544f4983d16b25e85d250.webp",
                  "https://evilmusic.126.net/a.jpg?x=1",
                  "https://imge.kugou.com/other/0/1.jpg",
                  "https://is1-ssl.mzstatic.com/image/thumb/Music221/x.rgb.jpg/600x600bb-60.jpg",
                  "https://y.qq.com/music/photo_new/T003R800x800M000003zeVgY4BE7Sk.jpg",
                  "https://i.scdn.co/image/ab67616d0000b273abc",
                  "https://yt3.googleusercontent.com/KKEMiv9IulJvjB",
                  "https://cdn-images.dzcdn.net/images/artist/42b95263fc55a7b8/1000x1000-000000-80-0-0.jpg"] {
            expectEqual(t(s), s, "缩略图下载: 没实测过的形状原样 —— \(s)")
        }
        expectEqual(F.url(for: URL(string: "https://p1.music.126.net/abc==/1099.jpg?param=600y600")!, maxPixel: 2048).absoluteString,
                    "https://p1.music.126.net/abc==/1099.jpg?param=600y600", "缩略图下载: 原图档(2048)不改地址")
        expectEqual(F.shouldRetry(statusCode: 503, urlErrorCode: nil), true, "缩略图下载: 503 再试")
        expectEqual(F.shouldRetry(statusCode: 429, urlErrorCode: nil), true, "缩略图下载: 429 再试")
        expectEqual(F.shouldRetry(statusCode: 404, urlErrorCode: nil), false, "缩略图下载: 404 不再试")
        expectEqual(F.shouldRetry(statusCode: 200, urlErrorCode: nil), false, "缩略图下载: 200 但解码失败不再试")
        expectEqual(F.shouldRetry(statusCode: nil, urlErrorCode: URLError.Code.timedOut.rawValue), true, "缩略图下载: 超时再试")
        expectEqual(F.shouldRetry(statusCode: nil, urlErrorCode: URLError.Code.cancelled.rawValue), false, "缩略图下载: 被取消不再试")
    }

    // ---- 播放器自带的封面 / 系统封面晚到(03 章决策 33)----
    do {
        typealias G = CoverArtReplacementGate
        expectEqual(G.reason(width: 0, height: 0, lowResThreshold: 300, playerHasOwnCover: true), .systemArtworkMissing,
                    "播放器自带封面: 系统那份还没到时用它")
        expectEqual(G.reason(width: 0, height: 0, lowResThreshold: 300, systemNeverHasArtwork: true, playerHasOwnCover: true),
                    .playerHasNoArtwork, "播放器自带封面: 从不报封面的播放器照旧先认缓存里那张")
        expectEqual(G.reason(width: 0, height: 0, lowResThreshold: 300, systemArtworkIsPlaceholder: true, playerHasOwnCover: true),
                    .playerHasNoArtwork, "播放器自带封面: 推占位图的那一首照旧先认缓存里那张")
        expectEqual(G.accepts(candidateWidth: 1000, candidateHeight: 1000, systemWidth: 0, reason: .systemArtworkMissing), true,
                    "播放器自带封面: 方形的就换")
        expectEqual(G.accepts(candidateWidth: 1280, candidateHeight: 720, systemWidth: 0, reason: .systemArtworkMissing), false,
                    "播放器自带封面: 不是封面形状的不换")
        expectEqual(G.reason(width: 0, height: 0, lowResThreshold: 300), nil, "播放器自带封面: 没有它的照旧显示占位音符")
        expectEqual(G.reason(width: 150, height: 150, lowResThreshold: 300, playerHasOwnCover: true), .lowRes,
                    "播放器自带封面: 系统那份到了(太小)照旧按太小找替代")
        let cached = URL(string: "https://p1.music.126.net/a.jpg")!
        let own = URL(string: "https://i.kfs.io/album/x/fit/1000x1000.jpg")!
        expectEqual(G.replacementCandidates(cached: cached, playerOwn: own, reason: .systemArtworkMissing), [own],
                    "播放器自带封面: 系统那份没有时只认它,缓存里按文字匹配的不顶上去")
        expectEqual(G.replacementCandidates(cached: cached, playerOwn: nil, reason: .systemArtworkMissing), [URL](),
                    "播放器自带封面: 系统那份没有、也没有它:不找替代")
        expectEqual(G.replacementCandidates(cached: cached, playerOwn: own, reason: .lowRes), [cached, own],
                    "播放器自带封面: 太小时先缓存里那张,不够格再试它")
        expectEqual(G.replacementCandidates(cached: cached, playerOwn: own, reason: .playerHasNoArtwork), [cached, own],
                    "播放器自带封面: 从不报封面 / 占位图时先缓存里那张")
        expectEqual(G.replacementCandidates(cached: own, playerOwn: own, reason: .lowRes), [own],
                    "播放器自带封面: 同一张只试一次")
        expectEqual(G.replacementCandidates(cached: nil, playerOwn: own, reason: .notCoverShaped), [own],
                    "播放器自带封面: 引擎还没解析完时先用它")
        typealias R = EnrichCacheReader
        expectEqual(R.nativeSizedCoverURL(URL(string: "https://i.kfs.io/album/global/298971151,0v3/fit/600x600.jpg")!).absoluteString,
                    "https://i.kfs.io/album/global/298971151,0v3/fit/1000x1000.jpg", "KKBOX 图床: 600 档提到 1000")
        expectEqual(R.nativeSizedCoverURL(URL(string: "https://i.kfs.io/album/global/298971151,0v3/fit/1500x1500.jpg")!).absoluteString,
                    "https://i.kfs.io/album/global/298971151,0v3/fit/1500x1500.jpg", "KKBOX 图床: 已经够大的不降")
        expectEqual(R.nativeSizedCoverURL(URL(string: "https://i.kfs.io/album/global/298971151,0v3/original.jpg")!).absoluteString,
                    "https://i.kfs.io/album/global/298971151,0v3/original.jpg", "KKBOX 图床: 原图不动")
        expectEqual(R.nativeSizedCoverURL(URL(string: "https://i.kfs.io.example.com/fit/600x600.jpg")!).absoluteString,
                    "https://i.kfs.io.example.com/fit/600x600.jpg", "KKBOX 图床: 别的主机不动")
        typealias S = LocalPlaybackSource
        expectEqual(S.artworkLateRetryDelay(afterWaiting: 31), 15, "封面晚到: 5 分钟内 15 秒取一次")
        expectEqual(S.artworkLateRetryDelay(afterWaiting: 299), 15, "封面晚到: 5 分钟内 15 秒取一次(边界)")
        expectEqual(S.artworkLateRetryDelay(afterWaiting: 300), 60, "封面晚到: 之后 60 秒一次")
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        expectEqual(S.artworkMissDescription(data: nil, payloadKey: nil, miss: "the system reports nothing", expectedKey: "a|b"),
                    "the system reports nothing", "取图失败说明: 取图那边给的原因原样带上")
        expectEqual(S.artworkMissDescription(data: nil, payloadKey: nil, miss: nil, expectedKey: "a|b"), "no artwork",
                    "取图失败说明: 没给原因也没有图")
        expectEqual(S.artworkMissDescription(data: png, payloadKey: "x|y", miss: nil, expectedKey: "a|b"),
                    "the system cover belongs to x|y", "取图失败说明: 图是别的歌的")
        expectEqual(S.artworkMissDescription(data: png, payloadKey: "A|B", miss: nil, expectedKey: "a|b"), nil,
                    "取图失败说明: 是这首的图(大小写不同也算)就是取到了")
        // 接线契约(扫源码)
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func src(_ rel: String) -> String {
            (try? String(contentsOfFile: sources.appendingPathComponent(rel).path, encoding: .utf8)) ?? ""
        }
        let lps = src("LyrimuseCore/Local/LocalPlaybackSource.swift")
        expectEqual(lps.contains("            while true {\n                let delay = Self.artworkLateRetryDelay(afterWaiting: waited)")
                        && lps.contains("guard stillWaiting() else { return }\n                // 暂停着不取,恢复播放后接着取。\n                guard self.isPlayingNow else { continue }\n                let late = await attempt()")
                        && lps.contains("generation == self.artworkFetchGeneration && expectedKey == self.lastKey && self.artworkData == nil")
                        && lps.contains("artworkFetchGeneration += 1\n        let generation = artworkFetchGeneration")
                        && lps.contains("last attempt: \\(lastMiss ?? \"-\", privacy: .public)"), true,
                    "封面晚到(契约): 二次确认跑完还没封面就接着取,同一首另起一轮就让给它;那条日志带上最后一次为什么没取到")
        expectEqual(lps.contains("if KnownPlaceholderArtwork.isPlaceholder(data) { return \"the player's built-in placeholder\" }"), true,
                    "封面晚到(契约): 登记在案的占位图不算取到(网易云云盘歌那张不会晚到时被挂上)")
        expectEqual(S.artworkMissDescription(data: png, payloadKey: nil, miss: nil, expectedKey: "a|b"),
                    "the system cover carries no track key", "取图失败说明: 有图但没有曲目标识,不算取到")
        let coordinator = src("lyrimuse/PlaybackCoordinator.swift")
        expectEqual(coordinator.contains("playerOwn: playerOwn, reason: reason")
                        && coordinator.contains("for url in candidates {")
                        && coordinator.contains("guard let image = loaded else { continue }")
                        && coordinator.contains("playerHasOwnCover: playerOwn != nil")
                        && coordinator.contains("playerHasOwnCover: Self.currentPlayerOwnCover() != nil"), true,
                    "播放器自带封面(契约): 高清替代按顺序试,系统那份没有时认播放器自带的那张")
    }
}
