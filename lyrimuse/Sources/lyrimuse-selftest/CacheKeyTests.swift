import LyrimuseCore
import Foundation

// 缓存 key 归一化(与 collector 逐字节一致)/ 合唱 credit 归并。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runCacheKeyTests() {
    // ---- EnrichCacheStore.buildSummaries 的"先查前缀再算指纹"这层优化(2026-08-26)----
    //
    // trackKey 里那段内容指纹是对整首歌词+YRC 正文取 SHA256,实测对全库 1760 条无条件都算
    // 一遍要 250ms+(比读盘解析整份 JSON 还贵),而 offsetsSnapshot 常年只有个位数条目、
    // 99% 以上的歌注定查不到。buildSummaries 现在先把 offsetsSnapshot 的 key 反过来切一遍
    // (取"最后一个 | 之前"那一截,指纹段本身不含 | 所以这一刀总能切对)存成一个小前缀集合,
    // 只有 artist|title 归一化后命中这个集合才值得真的付一次 SHA256。
    //
    // buildSummaries 本身是 private,这里没法直接调,改为对着**它依赖的那两个真实公开函数**
    // (EnrichCacheKeys.cleanTag/normalizedTitle,构造前缀用的正是它们,顺序也逐位照抄)验证
    // 这套"先查前缀"判定不会漏判——对一首真的被校准过的歌,前缀必须命中且能查到正确的
    // 非零值;对一首毫不相关的歌,前缀必须不命中(省掉一次哈希),而"不命中就给 0"这个结果
    // 跟"老逻辑无条件算指纹、查表查不到也是 0"完全一致,不会漏掉任何真实存在的校正值。
    do {
        let calibratedArtist = "周杰伦"
        let calibratedTitle = "枫"
        let calibratedLyrics = "[00:05.00]词一\n[00:10.00]词二\n"
        let calibratedYRC = ""
        let realOffsetKey = LyricsOffsetStore.trackKey(
            artist: calibratedArtist, title: calibratedTitle,
            lyrics: calibratedLyrics, lyricsYRC: calibratedYRC)
        let snapshot: [String: Int] = [realOffsetKey: 1200]

        // buildSummaries 里的构造逻辑:反切 offsetsSnapshot 的 key,取最后一个 "|" 之前那截。
        let offsetPrefixes: Set<String> = Set(snapshot.keys.compactMap { key in
            guard let sep = key.range(of: "|", options: .backwards) else { return nil }
            return String(key[..<sep.lowerBound])
        })

        // 命中的那首:前缀必须能查到,且用真实 trackKey 查出来的值要跟直接查表一致。
        let hitPrefix = "\(EnrichCacheKeys.cleanTag(calibratedArtist))|\(EnrichCacheKeys.normalizedTitle(calibratedTitle))"
        expectEqual(offsetPrefixes.contains(hitPrefix), true,
                    "前缀优化: 真的校准过的歌,归一化前缀必须命中小集合")
        let hitKey = LyricsOffsetStore.trackKey(
            artist: calibratedArtist, title: calibratedTitle,
            lyrics: calibratedLyrics, lyricsYRC: calibratedYRC)
        expectEqual(snapshot[hitKey], 1200,
                    "前缀优化: 命中之后用真实 trackKey 查表,结果要是校准时存的那个值")

        // 毫不相关的另一首歌:前缀不该命中,省掉一次指纹计算;而"不命中直接给 0"要跟
        // "老逻辑无条件算指纹、查表查不到"结果一致(两条路径查同一份 snapshot 都是 nil)。
        let unrelatedArtist = "五月天"
        let unrelatedTitle = "倔强"
        let missPrefix = "\(EnrichCacheKeys.cleanTag(unrelatedArtist))|\(EnrichCacheKeys.normalizedTitle(unrelatedTitle))"
        expectEqual(offsetPrefixes.contains(missPrefix), false,
                    "前缀优化: 不相关的歌,归一化前缀不该出现在小集合里")
        let oldWayKey = LyricsOffsetStore.trackKey(
            artist: unrelatedArtist, title: unrelatedTitle,
            lyrics: "[00:01.00]随便什么歌词\n", lyricsYRC: "")
        expectEqual(snapshot[oldWayKey], nil,
                    "前缀优化: 跳过指纹计算给的 0,要跟老逻辑无条件查表查不到的结果一致")
    }

    // ---- EnrichCacheKeys: 缓存 key ↔ lyrics/ 导出文件名(2026-08-05) ----
    //
    // 2026-08-05 实测排查坐实的真实 bug 的回归测试:collector 会给"sanitize 出来的文件名只差
    // 大小写"的碰撞组成员改用带 crc32 后缀的文件名(lyricsexport.go:105-141),而 Swift 侧原来
    // 一律只认普通名——删除时漏删 → collector 重启后 importLyricsFromFiles 从残留文件把条目
    // 复活(本机 852 条里 219 条命中,占 25.7%);保存修改时写出普通名 → 同一个 key 对应两组
    // 文件、导入时各写一次、生效哪份取决于 Go map 的随机遍历顺序。
    // crc32 必须跟 Go 的 hash/crc32.ChecksumIEEE 逐位一致,否则算出来的文件名对不上。

    do {
        // 公认的 CRC-32(IEEE) 标准向量,锁死查表实现本身。
        expectEqual(EnrichCacheKeys.crc32IEEE(""), UInt32(0), "EnrichCacheKeys: crc32 空串标准向量")
        expectEqual(EnrichCacheKeys.crc32IEEE("123456789"), UInt32(0xCBF4_3926), "EnrichCacheKeys: crc32 \"123456789\" 标准向量")
        expectEqual(EnrichCacheKeys.crc32IEEE("a"), UInt32(0xE8B7_BE43), "EnrichCacheKeys: crc32 \"a\" 标准向量")

        // 从本机磁盘上真实存在的两个碰撞文件反推出来的用例(同一首歌只差 feat./Feat. 一个
        // 字母大小写,两条 key 都真的在缓存里)——这两条锁死的是"Swift 算出来的文件名跟
        // collector 实际写在磁盘上的那个一模一样"。
        expectEqual(
            EnrichCacheKeys.disambiguatedName(forKey: "方大同|张永成 (feat. Ghost Style)|15"),
            "方大同 - 张永成 (feat. Ghost Style) - 15~00fad0",
            "EnrichCacheKeys: 消歧文件名跟磁盘上真实文件一致(小写 feat.)"
        )
        expectEqual(
            EnrichCacheKeys.disambiguatedName(forKey: "方大同|张永成 (Feat. Ghost Style)|15"),
            "方大同 - 张永成 (Feat. Ghost Style) - 15~c8df08",
            "EnrichCacheKeys: 同一首歌大小写不同的另一条 key 落在不同文件名"
        )
    }

    do {
        // "|" 换成 " - ",文件系统不安全字符转下划线,跟 collector/lyricsexport.go 的
        // sanitizeLyricsFilename 对齐。
        expectEqual(EnrichCacheKeys.sanitizeFilename("Artist|Song|Album"), "Artist - Song - Album", "EnrichCacheKeys: 「|」换成「 - 」")
        expectEqual(EnrichCacheKeys.sanitizeFilename("A/B|C:D|E*F?"), "A_B - C_D - E_F_", "EnrichCacheKeys: 不安全字符转下划线")

        // 删除必须把两种形态各 4 个后缀全试一遍——漏掉带后缀那 4 个就是上面说的复活 bug。
        let names = EnrichCacheKeys.exportedFileNames(forKey: "Artist|Song|Album")
        expectEqual(names.count, 8, "EnrichCacheKeys: 待删文件名 = 普通名4个 + 消歧名4个")
        expectEqual(names[0], "Artist - Song - Album.lrc", "EnrichCacheKeys: 普通名第一个是 .lrc")
        expectEqual(names[3], "Artist - Song - Album.yrc", "EnrichCacheKeys: 普通名第四个是 .yrc")
        expectEqual(
            names[4], "Artist - Song - Album~\(String(format: "%06x", EnrichCacheKeys.crc32IEEE("Artist|Song|Album") & 0xFF_FFFF)).lrc",
            "EnrichCacheKeys: 第五个开始是带消歧后缀的同族文件"
        )
        // 普通名恰好是消歧名的前缀,所以任何"按前缀筛"的写法都会出错——这条锁死这个陷阱。
        expectEqual(names[4].hasPrefix("Artist - Song - Album"), true, "EnrichCacheKeys: 消歧名以普通名开头(禁止用 hasPrefix 区分两种形态)")
    }

    do {
        // 选中集合 → 实际删除计划:交集 + 排序。
        let existing: Set<String> = ["B|b|al2", "A|a|al1", "C|c|al3"]
        expectEqual(
            EnrichCacheKeys.deletionPlan(selected: ["A|a|al1", "已经没了|x|y"], existing: existing),
            ["A|a|al1"],
            "EnrichCacheKeys: 选中集合里已失效的 key 被剔除"
        )
        expectEqual(EnrichCacheKeys.deletionPlan(selected: [], existing: existing), [], "EnrichCacheKeys: 空选中集合不产生删除")
        expectEqual(
            EnrichCacheKeys.deletionPlan(selected: existing, existing: existing),
            ["A|a|al1", "B|b|al2", "C|c|al3"],
            "EnrichCacheKeys: 全选时按 key 排序返回,顺序稳定可复现"
        )
        expectEqual(
            EnrichCacheKeys.deletionPlan(selected: ["X|x|x"], existing: existing), [],
            "EnrichCacheKeys: 全部失效时删除计划为空(调用方据此直接返回,不做空写盘)"
        )
    }

    // ---- EnrichCacheKeys: 缓存 key 归一化,必须跟 collector 逐字节一致(2026-08-14) ----
    //
    // 这组用例跟 collector/enrichkey_test.go 的 TestNormEnrichTitle 是**同一张表**。两边只要
    // 有一处对不上,collector 按归一化 key 写盘、悬浮窗按另一种拼法查,结果不是"显示了旧歌词"
    // 而是**整首歌查不到词**,且只在某些播放器上复现 —— 这种失败最难从现象倒推回来,所以钉死。
    do {
        let K = EnrichCacheKeys.self
        let cases: [(String, String, String)] = [
            // 要修的那一类:中文歌名 + 括号里的英文译名(本机缓存里真实存在过的重复条目)
            ("全角括号译名", "不散的筵席（I Miss You）", "不散的筵席"),
            ("全角括号译名2", "神探（The Detective）", "神探"),
            ("半角括号译名", "小師妹 (Love Triangle)", "小師妹"),
            // 版本标记必须原样保留:合并了就是把两个不同的录音当成同一首
            ("remix 保留", "Song (Remix)", "Song (Remix)"),
            ("live 保留", "告白气球 (Live)", "告白气球 (Live)"),
            ("remaster 保留", "Bad (2012 Remaster)", "Bad (2012 Remaster)"),
            ("feat 保留", "爱我的人 (feat. MOE.)", "爱我的人 (feat. MOE.)"),
            ("instrumental 保留", "Song (Instrumental)", "Song (Instrumental)"),
            ("interlude 保留", "The Girl In Red (Interlude)", "The Girl In Red (Interlude)"),
            ("中文版本标记保留", "月亮代表我的心 (现场版)", "月亮代表我的心 (现场版)"),
            // 2026-08-31 真实bug(周杰伦《不能说的秘密》电影原声带),见 collector 侧
            // enrichkey.go 的 enrichKeyVersionWords 头注。
            ("慢板保留", "Secret (慢板)", "Secret (慢板)"),
            ("快板保留", "第二圆舞曲 (快板)", "第二圆舞曲 (快板)"),
            // 边界
            ("括号就是整个歌名", "(Interlude)", "(Interlude)"),
            ("括号就是整个歌名2", "（前奏）", "（前奏）"),
            ("两层括号连剥", "歌名（译名）[Explicit]", "歌名"),
            ("剥到版本标记停手", "歌名（译名）(Live)", "歌名（译名）(Live)"),
            ("中间的括号不动", "Song (A) tail", "Song (A) tail"),
            ("没有括号", "不散的筵席", "不散的筵席"),
            ("空串", "", ""),
            ("不换行空格", "Song\u{00a0}(I Miss You)", "Song"),
            ("零宽字符", "不散\u{200b}的筵席", "不散的筵席"),
            ("全角空格", "不散的筵席\u{3000}（I Miss You）", "不散的筵席"),
        ]
        for (name, input, want) in cases {
            expectEqual(K.normalizedTitle(input), want, "缓存key: \(name)")
        }
        // 不转小写、不折繁简 —— 列表显示的就是 key 拆出来的三段,折了会看到"神经志 the journal"
        expectEqual(
            K.normalizedKey(artist: "PRINCE", title: "The Girl In Red (Interlude)", album: "神經志 The Journal"),
            "PRINCE|The Girl In Red (Interlude)|神經志 The Journal",
            "缓存key: 不转小写也不折繁简"
        )
        // 幂等:迁移每次 collector 启动都会跑一遍
        let once = K.normalizedKey(artist: "丁世光", title: "不散的筵席（I Miss You）", album: "神經志 The Journal")
        expectEqual(once, "丁世光|不散的筵席|神經志 The Journal", "缓存key: 三段拼接")
        expectEqual(K.normalizedTitle("不散的筵席"), "不散的筵席", "缓存key: 归一化过的再算一次不变")

        // ---- looseKey:只用于查询兜底的宽松形态(2026-08-16) ----
        //
        // collector 把"其实是同一首歌"的重复条目合并成一条后,缓存里只剩最适合显示的那个写法;
        // 播放器报的可能是另一个写法,靠这一层才查得到。⚠️ 它**只能**用于兜底,绝不能拿去构造
        // key —— 繁简这一档两侧本来就不一致(collector 用 OpenCC 词典、这边用 ICU),写进 key
        // 就是「悬浮窗整首歌没词」。理由完整版见 EnrichCacheKeys.looseKey 的注释。
        let loosePairs: [(String, String, String)] = [
            ("半角空格", "陶喆|Susan 说|太平盛世", "陶喆|Susan说|太平盛世"),
            ("中英之间空格", "陶喆|Sula 与 Lampa 的寓言|太平盛世", "陶喆|Sula 与 Lampa的寓言|太平盛世"),
            ("歌名繁简", "方大同|千纸鹤|回到未來", "方大同|千紙鶴|回到未來"),
            ("歌手名繁简", "孙燕姿|我懷念的|逆光", "孫燕姿|我懷念的|逆光"),
            ("大小写", "PRINCE|Kiss|Parade", "Prince|Kiss|Parade"),
        ]
        for (name, a, b) in loosePairs {
            expectEqual(K.looseKey(a), K.looseKey(b), "looseKey 同组: \(name)")
        }
        // 版本/专辑/歌手不同的绝不能被兜到一起 —— 兜底再宽松也不能把两首歌混成一首。
        let looseDistinct: [(String, String, String)] = [
            ("版本括号", "陶喆|Susan 说|太平盛世", "陶喆|Susan 说(Music鉴赏版)|太平盛世"),
            ("不同专辑", "陶喆|Susan 说|太平盛世", "陶喆|Susan 说|黑色柳丁"),
            ("不同歌手", "陶喆|Susan 说|太平盛世", "王力宏|Susan 说|太平盛世"),
        ]
        for (name, a, b) in looseDistinct {
            expectNotEqual(K.looseKey(a), K.looseKey(b), "looseKey 不同组: \(name)")
        }
        // looseKey 绝不能影响 normalizedKey —— 后者是真正落盘/显示用的那个。
        expectEqual(
            K.normalizedKey(artist: "孙燕姿", title: "我懷念的", album: "逆光"),
            "孙燕姿|我懷念的|逆光",
            "缓存key: looseKey 不污染 normalizedKey"
        )
    }

    // ---- EnrichCacheReader.artistTitleKey:「最近播放」封面的本机兜底键(2026-08-14) ----
    //
    // 这个键两头用:建索引时喂的是**缓存 key 里已经归一化过**的歌名,查询时喂的是 Last.fm
    // scrobble 里**播放器原样上报**的歌名。两头必须落到同一个字符串,带译名的那类歌名才能
    // 命中本机封面 —— 否则这条兜底对整张《神經志 The Journal》这种"歌名带英文译名"的专辑
    // 全部失效,而那正是 Last.fm 最容易缺图的一类。
    do {
        let R = EnrichCacheReader.self
        expectEqual(R.artistTitleKey(artist: "陶喆", title: "聖誕之吻"), "陶喆|聖誕之吻",
                    "封面兜底键: 基本形")
        // 大小写/首尾空白不算差异(跟 LastfmStatsService.playCountKey 同口径)
        expectEqual(R.artistTitleKey(artist: "  Prince ", title: " Kiss "), "prince|kiss",
                    "封面兜底键: 去空白转小写")
        // 关键:两头喂不同拼法要落到同一个键
        expectEqual(
            R.artistTitleKey(artist: "丁世光", title: "不散的筵席（I Miss You）"),
            R.artistTitleKey(artist: "丁世光", title: "不散的筵席"),
            "封面兜底键: 带译名的原始歌名跟归一化后的歌名落到同一个键"
        )
        // 版本标记仍然要区分开 —— 现场版跟录音室版是两首,不该共用封面
        expectEqual(
            R.artistTitleKey(artist: "周杰伦", title: "告白气球 (Live)") != R.artistTitleKey(artist: "周杰伦", title: "告白气球"),
            true, "封面兜底键: 版本标记仍然区分"
        )
    }

    // ---- 按日历天定义的缓存:跨零点必须作废(2026-08-17) ----
    //
    // 用户报「那年今日」昨天和今天显示同一份。根因是那张卡用 6 小时 TTL 判缓存,而 TTL 只
    // 知道过了多少秒、不知道跨没跨过零点 —— 22:00 取到 8/16 那份,次日 02:00 再看 TTL 还没
    // 到期,昨天那份就被挂在"今天"上。App 是常驻服务、跨天不重启,缓存时间戳又只在内存里,
    // 所以这条一定会发生。这里盯住的就是"跨天优先于 TTL"这一点。
    do {
        var cal = Calendar(identifier: .gregorian)
        // 固定时区,否则这组断言的结果会跟跑测试的机器在哪个时区有关。
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            cal.date(from: DateComponents(year: 2026, month: month, day: day,
                                          hour: hour, minute: minute))!
        }
        let sixHours: TimeInterval = 6 * 3600
        func needs(fetched: Date?, day: Date?, now: Date) -> Bool {
            DailyRefreshGate.needsRefresh(lastFetchedAt: fetched, cachedDay: day,
                                          now: now, ttl: sixHours, calendar: cal)
        }

        expectEqual(needs(fetched: nil, day: nil, now: at(8, 17, 10)), true,
                    "跨天缓存: 从没取过要拉")

        // 同一天内 TTL 照常生效 —— 别把这条改坏了,不然每次露面都真发一轮请求
        // (那是三年 × 最多三页的量)。
        expectEqual(needs(fetched: at(8, 17, 10), day: at(8, 17, 10), now: at(8, 17, 14)), false,
                    "跨天缓存: 同一天且 TTL 内不拉")
        expectEqual(needs(fetched: at(8, 17, 3), day: at(8, 17, 3), now: at(8, 17, 10)), true,
                    "跨天缓存: 同一天但 TTL 到期要拉")

        // 本次修的就是这一条:只差 4 小时、TTL 远没到期,但已经是第二天了。
        expectEqual(needs(fetched: at(8, 16, 22), day: at(8, 16, 22), now: at(8, 17, 2)), true,
                    "跨天缓存: 跨过零点即使 TTL 没到期也要拉")
        // 边界:同一天的 23:59 → 次日 00:00,只隔一分钟也算跨天。
        expectEqual(needs(fetched: at(8, 16, 23, 59), day: at(8, 16, 23, 59), now: at(8, 17, 0, 0)),
                    true, "跨天缓存: 零点前后只差一分钟也算跨天")
        // 反向边界:同一天最早和最晚,不算跨天(只由 TTL 说了算)。
        expectEqual(needs(fetched: at(8, 17, 0, 0), day: at(8, 17, 0, 0), now: at(8, 17, 5, 59)),
                    false, "跨天缓存: 同一天跨度再大也不算跨天")

        // 防御:两个字段本该同生同死,单独有一个时按"没有缓存"处理。
        expectEqual(needs(fetched: at(8, 17, 10), day: nil, now: at(8, 17, 11)), true,
                    "跨天缓存: 缺 cachedDay 当作没缓存")
        expectEqual(needs(fetched: nil, day: at(8, 17, 10), now: at(8, 17, 11)), true,
                    "跨天缓存: 缺 lastFetchedAt 当作没缓存")
    }

    // MARK: - 合唱 credit 归并(ArtistCredit,2026-08-20)
    //
    // 起因:同一首《Toronto 2014》两次收听在 Last.fm 上成了两个实体 —— Mac 照抄 Apple Music
    // 的逐曲 credit「Daniel Caesar & Mustafa」,手机(iPhone→Last.fm→桥接)报的是主歌手
    // 「Daniel Caesar」。后果是次数各记一本(两行都「第 1 次听」)、封面各挂一张(合唱实体挂
    // 单曲封面)。这两组断言钉住用来归并的两条口径。
    do {
        // ① 主歌手拆分:能拆才返回值,单人返回 nil(nil = "没有主歌手这回事")
        expectEqual(ArtistCredit.primary("Daniel Caesar & Mustafa"), "Daniel Caesar",
                    "合唱 credit: & 分隔取第一位")
        expectEqual(ArtistCredit.primary("陶喆、卢广仲"), "陶喆", "合唱 credit: 顿号分隔")
        expectEqual(ArtistCredit.primary("UMI, 金泰亨"), "UMI", "合唱 credit: 逗号分隔")
        expectEqual(ArtistCredit.primary("Daniel Caesar feat. Mustafa"), "Daniel Caesar",
                    "合唱 credit: feat. 也算多人")
        expectEqual(ArtistCredit.primary("Doja Cat (feat. SZA)"), "Doja Cat",
                    "合唱 credit: 括号里的 feat. 一并切掉")
        expectEqual(ArtistCredit.primary("Daniel Caesar"), nil, "单人 credit: 返回 nil")
        // feat 家族要有**左词边界**(2026-08-22 实测出来的真 bug):`ft ` 会在词中命中,
        // 蛋堡的罗马字名 `Soft Lipa` 被切成 `So`,于是它跟 `蛋堡` 在查族键上永远合不上。
        expectEqual(ArtistCredit.primary("Soft Lipa"), nil,
                    "合唱 credit: Soft Lipa 里的 ft 不是客串标记(实测真 bug)")
        expectEqual(ArtistCredit.primary("Daft Punk"), nil, "合唱 credit: Daft Punk 不许切成 Da")
        expectEqual(ArtistCredit.primary("Left Boy"), nil, "合唱 credit: Left Boy 不许切成 Le")
        expectEqual(ArtistCredit.primary("Craft Spells"), nil, "合唱 credit: Craft Spells 不许切")
        expectEqual(ArtistCredit.primary("Soft Machine"), nil, "合唱 credit: Soft Machine 不许切成 So")
        // 边界守卫不能把真的客串标记也挡掉
        expectEqual(ArtistCredit.primary("Soft Lipa feat. 蛋堡"), "Soft Lipa",
                    "合唱 credit: 名字含 ft 的歌手,真 feat. 照旧切")
        expectEqual(ArtistCredit.primary("A ft. B"), "A", "合唱 credit: ft. 缩写照旧切")
        expectEqual(ArtistCredit.primary("A ft B"), "A", "合唱 credit: 无点号 ft 照旧切")
        expectEqual(ArtistCredit.primary("A (ft. B)"), "A", "合唱 credit: 括号里的 ft. 照旧切")
        expectEqual(ArtistCredit.primary(""), nil, "空串: 返回 nil")
        // 名字本身带 & 的组合不该被拆空(拆出来是空串时按"没有主歌手"处理)
        expectEqual(ArtistCredit.primary("& Friends"), nil, "以分隔符开头: 不返回空串")
        // `/` 单独一档:网易云式合 credit 要切,名字自带斜杠的不许切
        expectEqual(ArtistCredit.primary("陶喆/卢广仲"), "陶喆", "斜杠: 中文合 credit 要切")
        expectEqual(ArtistCredit.primary("K/DA, Madison Beer & (G)I-DLE"), "K/DA",
                    "斜杠: 逗号先命中,K/DA 保持完整(真实历史里的一例)")
        expectEqual(ArtistCredit.primary("AC/DC"), nil, "斜杠: AC/DC 是一个艺人,不许劈成 AC")
        expectEqual(ArtistCredit.primary("K/DA"), nil, "斜杠: K/DA 同理不许劈成 K")
        // 归并键:多人归到第一位,单人原样
        expectEqual(ArtistCredit.mergeArtist("Daniel Caesar & Mustafa"), "Daniel Caesar",
                    "归并歌手: 多人归第一位")
        expectEqual(ArtistCredit.mergeArtist("Daniel Caesar"), "Daniel Caesar",
                    "归并歌手: 单人原样")
        // 两种 credit 写法必须落到同一个专辑共识键
        expectEqual(ArtistCredit.albumConsensusKey(artist: "Daniel Caesar & Mustafa",
                                                   album: "NEVER ENOUGH (Bonus Version)"),
                    ArtistCredit.albumConsensusKey(artist: "Daniel Caesar",
                                                   album: "never enough (bonus version)"),
                    "共识键: 合唱/主歌手两种写法 + 大小写差异折到同一个键")
        expectEqual(ArtistCredit.albumConsensusKey(artist: "Daniel Caesar", album: nil), nil,
                    "共识键: 没有专辑名就没有共识(空专辑不共享封面)")

        // ② 同专辑共识封面:真实形态复刻 —— 4 行同专辑,3 行挂专辑封面、1 行(合唱实体)挂单曲封面
        let albumArt = URL(string: "https://lastfm.example/album.jpg")!
        let singleArt = URL(string: "https://lastfm.example/single.jpg")!
        let album = "NEVER ENOUGH (Bonus Version)"
        let rows: [(artist: String, album: String?, image: URL?)] = [
            ("Daniel Caesar & Mustafa", album, singleArt),
            ("Daniel Caesar", album, albumArt),
            ("Daniel Caesar", album, albumArt),
            ("Daniel Caesar", album, albumArt),
        ]
        let consensus = ArtistCredit.albumConsensusCovers(rows: rows)
        expectEqual(consensus[ArtistCredit.albumConsensusKey(artist: "Daniel Caesar", album: album)!],
                    albumArt, "共识封面: 少数派(单曲封面)那一行被多数派纠正")
        // 每行各一张(合辑/逐曲封面)→ 没有共识,不许乱纠正
        let noConsensus = ArtistCredit.albumConsensusCovers(rows: [
            ("V.A.", "Compilation", URL(string: "https://lastfm.example/a.jpg")!),
            ("V.A.", "Compilation", URL(string: "https://lastfm.example/b.jpg")!),
        ])
        expectEqual(noConsensus.isEmpty, true, "共识封面: 一行一张时不产生共识")
        // 只有一行的专辑也不算共识(要求 ≥2 行一致)
        let single = ArtistCredit.albumConsensusCovers(rows: [("Solo", "One Track", albumArt)])
        expectEqual(single.isEmpty, true, "共识封面: 只有一行时不产生共识")
        // 没有图的行不参与
        let withNil = ArtistCredit.albumConsensusCovers(rows: [
            ("Daniel Caesar", album, nil),
            ("Daniel Caesar", album, albumArt),
            ("Daniel Caesar", album, albumArt),
        ])
        expectEqual(withNil.count, 1, "共识封面: 没有图的行不参与投票")
    }

    // MARK: - 缓存 key:结尾副题必须被剥掉(2026-08-20「歌词管理不自动定位」的根因)
    //
    // 用户报「进歌词管理不会自动定位到正在播的曲目」。实测:Apple Music 把这首报成
    // 「Dynasties and Dystopia (from the series Arcane League of Legends)」,而缓存里那条 key
    // 是剥掉副题的「Dynasties and Dystopia」(collector 的 enrichKey 剥的)。定位函数当时手拼
    // "artist|title|album",精确匹配落空;而 looseKey 只折大小写/空格/繁简,**折不掉**这段副题,
    // 兜底也接不住 —— 于是静默返回。这两条断言把"镜像函数必须剥、looseKey 必须剥不掉"钉住。
    do {
        let artist = "Denzel Curry/GIZZLE/Bren Joy"
        let title = "Dynasties and Dystopia (from the series Arcane League of Legends)"
        let album = "Arcane League of Legends (Soundtrack from the Animated Series)"
        expectEqual(EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album),
                    "Denzel Curry/GIZZLE/Bren Joy|Dynasties and Dystopia|"
                        + "Arcane League of Legends (Soundtrack from the Animated Series)",
                    "缓存 key: 歌名结尾的 (from the series …) 副题被剥掉,专辑名原样保留")
        // looseKey 接不住这个差异 —— 这正是"必须用 normalizedKey 而不是手拼 + looseKey"的理由
        expectEqual(EnrichCacheKeys.looseKey("\(artist)|\(title)|\(album)")
                        == EnrichCacheKeys.looseKey(
                            EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)),
                    false,
                    "缓存 key: looseKey 折不掉结尾副题(所以手拼 key 连兜底都命不中)")
        // 版本限定词(Live/Remix 等)必须**保留** —— 那是另一次录音,不是副题噪音
        expectEqual(EnrichCacheKeys.normalizedTitle("Purple Rain (Live)"), "Purple Rain (Live)",
                    "缓存 key: 版本限定词不剥")
    }

    // MARK: - looseKey 必须折平合 credit 分隔符(跟 collector 的 loosenEnrichKey 同步)
    //
    // 2026-08-20 用户报「歌词管理里同一首歌有两条」。根因:同一次播放里两条路径对多歌手串的
    // 写法系统性不同 —— 播放器报 `A/B/C`,专辑预取从 Apple Music 曲目表拿到 `A & B & C`。
    // 两侧的宽松键都得折平这一档,否则 collector 那边不再长重复条目,而这边(EnrichCacheReader
    // 的兜底、歌词管理的定位)仍然对不上存量里的另一种写法。
    do {
        expectEqual(
            EnrichCacheKeys.looseKey("VALORANT/Grabbitz/bbno$|Ticking Away|Ticking Away"),
            EnrichCacheKeys.looseKey("VALORANT & Grabbitz & bbno$|Ticking Away|Ticking Away"),
            "looseKey: 斜杠式与 & 式多歌手串判为同一首")
        expectEqual(
            EnrichCacheKeys.looseKey("陶喆、卢广仲|某首歌|某专辑"),
            EnrichCacheKeys.looseKey("陶喆/卢广仲|某首歌|某专辑"),
            "looseKey: 顿号与斜杠同折")
        // 原有两档(空格 / 繁简)不能被这次改动破坏
        expectEqual(
            EnrichCacheKeys.looseKey("丁世光|無名花香|背面是我"),
            EnrichCacheKeys.looseKey("丁世光|无名花香|背面是我"),
            "looseKey: 繁简仍然同折")
        // 折平分隔符不能把真的不同的歌并到一起
        expectEqual(
            EnrichCacheKeys.looseKey("K/DA|POP/STARS|POP/STARS")
                == EnrichCacheKeys.looseKey("K/DA|MORE|MORE"),
            false, "looseKey: 不同歌名仍然分开")
    }
}
