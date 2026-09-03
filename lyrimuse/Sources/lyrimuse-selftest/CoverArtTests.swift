import LyrimuseCore
import Foundation

// 封面取图 / 取色 / 高清替代。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runCoverArtTests() {
    // ---- 最近记录的封面兜底:合唱 credit 要能对上主歌手写法(2026-08-20) ----
    //
    // 同一次收听以两种歌手写法存在:本机缓存 key 用播放器的逐曲 credit(`英雄联盟/Sara Skinner`),
    // Last.fm 那一行记主歌手(`英雄联盟`)。前两级查找(归一化 key 精确 / looseKey)都救不了 ——
    // looseKey 只把分隔符变体折成 `&`,不会把合唱者去掉。下面这批是用户 2026-08-20 报的那一屏
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

        // ---- coverAlbumVerified:「最近记录」第①级纠错的资格判定(2026-09-01) ----
        // 真实案例:陈奕迅《不如这样 (Live)》,Last.fm 行侧专辑写法与缓存 cover_album 在
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

    // ---- 封面第⑤级:Apple Music 目录匹配守卫(2026-08-22) ----
    //
    // 前四级封面兜底里只有「本机 enrich 缓存」覆盖得了 Last.fm 对中文曲库缺图,而那一级只有
    // 本机播过才有数据 —— iPhone 听的歌、翻历史页看到的老歌天生在盲区里(实测抽样 205 首里
    // 25% 缺图,getinfo 只救回 20%、同专辑兄弟一张都救不到)。第⑤级去 iTunes Search 补。
    //
    // ⚠️ 这一组断言守的是「宁可留空位,也不挂错图」。实测:裸用搜索结果第一条会给
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

        // ⚠️ 挑选必须扫完候选、不能只看第一条。实测 30 首里有 5 首靠这一步纠正回正确那张
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

        // ⚠️ 这条是这一级存在的底线:匹配不上必须留空位,绝不退回搜索结果第一条
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

        // 已经够亮的原样放行——暖色/浅色封面(luma 本来就高)完全不受这次改动影响。
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

    // ---- 封面取图:载荷曲目标识比对(2026-08-17) ----
    //
    // 用户报网易云云盘歌"沿用上一首的封面":切歌瞬间 get --now 可能整条还是上一首(旧标题+
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

    // ---- 封面取色:桌面悬浮歌词按"跟描边够对比"调(2026-08-17) ----
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
        // ⚠️ 默认的 3.0 **触发不到**这条分支:要两侧都够不到得同时满足 sl < 0.05(mc−1) 和
        // sl > 1.05/mc − 0.05,有解的条件是 mc > √21 ≈ 4.58。所以这里显式传 7.0 去测那条
        // 分支,别改回默认值——改回去这个断言会退化成在测另一条路径(第一版就是这么写错的)。
        let midStroke = (0.5, 0.5, 0.5)
        let onMid = fit((0.55, 0.52, 0.50), stroke: midStroke, minContrast: 7.0)
        let bestEndpoint = max(contrastWith((r: 0, g: 0, b: 0), midStroke),
                               contrastWith((r: 1, g: 1, b: 1), midStroke))
        expectEqual(abs(contrastWith(onMid, midStroke) - bestEndpoint) < 0.01, true,
                    "描边取色: 够不到目标时取对比更好的端点")

        // 优先方向"差一点点"够不到边界时,贴边界收下这个近似值,不要为了凑够数值目标
        // 翻到对面走极端(2026-08-31,灵动岛「封面偏白、歌词却是全黑,太突兀」)。这是
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

    // ---- 封面取色:灵动岛 coverArt 卡片风格按"跟背景够对比"调(2026-08-27) ----
    //
    // 这一组是为一次真实回归补的:用户报灵动岛歌词跟背景对比度太低看不清——方大同
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
        // 防止两处以后各自改动、悄悄脱节(2026-08-27 修复本身就是在补这道"各写各的"的漏洞)。
        expectEqual(LocalPlaybackSource.notchCoverArtOverlayOpacity, 0.45,
                    "coverArt 取色: 背景黑叠加不透明度常量的当前值——改这个数记得同时想清楚对比度估算要不要跟着变")
    }

    // ---- 封面取色:coverArt 风格下"贴边界够接近就别翻方向"(2026-08-31) ----
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

    // ---- 封面 URL:三个图源各自顶到最大那一档(2026-08-17 网易云 / 2026-08-24 QQ+Apple) ----
    //
    // 2026-08-17:用户报「歌词窗口里封面非常模糊」。根因是系统 Now Playing 给的封面只有
    // 100×100(网易云客户端的限制),而那张卡最大 920px。替代图取自 collector 缓存的
    // cover_url,但那个 URL 尾巴上带着给小图用的 `?param=600y600` —— 网易云那个参数
    // **只降不升**,实测原生 800×800 的封面带上它就变 600×600。所以要原图必须把它摘掉。
    //
    // 2026-08-24:用户报「QQ 音乐这个封面很模糊」。QQ 音乐客户端报的系统封面是 300×300,
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

        // ---- QQ 音乐:路径里的尺寸档提到 800(2026-08-24) ----
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

        // ---- Apple:末段 600x600bb.jpg 提到 1200(2026-08-24) ----
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
}
