import LyrimuseCore
import Foundation

// 缓存 key 归一化(与引擎逐字节一致)/ 合唱 credit 归并。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runCacheKeyTests() {
    // ---- 正文小文件(引擎 enrichindex.go 的 enrichBody)解码:两边字段名逐字一致 ----
    do {
        let json = #"{"crc":3735928559,"lyrics":"[00:01.00]hi","lyrics_tr":"[00:01.00]你好","lyrics_roma":"[00:01.00]ni hao","lyrics_yrc":"[0,100](0,100,0)hi","plain_lyrics":"hi"}"#
        let body = try? JSONDecoder().decode(EnrichCacheBody.self, from: Data(json.utf8))
        expectEqual(body?.crc, 3735928559, "正文小文件: crc 按 UInt32 解(引擎写的是 uint32)")
        expectEqual(body?.lyricsYRC, "[0,100](0,100,0)hi", "正文小文件: lyrics_yrc")
        expectEqual(body?.lyricsTr, "[00:01.00]你好", "正文小文件: lyrics_tr")
        expectEqual(body?.lyricsRoma, "[00:01.00]ni hao", "正文小文件: lyrics_roma")
        expectEqual(body?.plainLyrics, "hi", "正文小文件: plain_lyrics")
        let sparse = try? JSONDecoder().decode(EnrichCacheBody.self, from: Data(#"{"crc":7,"lyrics":"x"}"#.utf8))
        expectEqual(sparse?.lyricsYRC == nil && sparse?.lyrics == "x", true, "正文小文件: 空字段省略(omitempty)也能解")
    }

    // ---- 「歌词管理」精简条目(EnrichCacheSlim):校验值跟引擎逐位一致、补回 / 写回不丢正文 ----
    do {
        // 这两个值是引擎 enrichindex_test.go TestEnrichBodyCRCMatchesApp 钉住的同一组输入。
        let full: [String: Any] = ["lyrics": "[00:01.00]你好", "lyrics_tr": "[00:01.00]hello",
                                   "lyrics_roma": "[00:01.00]ni hao", "lyrics_yrc": "[1000,500](1000,500,0)你好",
                                   "plain_lyrics": "你好", "cover_url": "https://x/c.jpg", "ts": 5]
        expectEqual(EnrichCacheSlim.bodyCRC(full), 857489496, "精简条目: 五段正文的校验值跟引擎一致")
        expectEqual(EnrichCacheSlim.bodyCRC(["lyrics": "[00:01.00]x"]), 2260255535, "精简条目: 只有主歌词的校验值跟引擎一致")
        expectEqual(EnrichCacheSlim.bodyCRC(["cover_url": "x"]), 0, "精简条目: 没有正文校验值为 0")

        // 背景人声只在非空时接在五段后面算(引擎用同一组输入钉着同一个值)。
        var withBG = full
        withBG["lyrics_bg"] = "[1000,500](1600,300,0)(oh)"
        expectEqual(EnrichCacheSlim.bodyCRC(withBG), 2392567654, "精简条目: 带背景人声的校验值跟引擎一致")
        let bgSlim = EnrichCacheSlim.slim(withBG)
        expectEqual(bgSlim["lyrics_bg"] == nil && EnrichCacheSlim.presentFields(bgSlim).contains(.bg), true,
                    "精简条目: 背景人声跟别的正文一样去掉,位图记下")
        let bgJSON = #"{"crc":2392567654,"lyrics":"[00:01.00]你好","lyrics_tr":"[00:01.00]hello","lyrics_roma":"[00:01.00]ni hao","lyrics_yrc":"[1000,500](1000,500,0)你好","plain_lyrics":"你好","lyrics_bg":"[1000,500](1600,300,0)(oh)"}"#
        let bgBody = try! JSONDecoder().decode(EnrichCacheBody.self, from: Data(bgJSON.utf8))
        expectEqual(EnrichCacheSlim.isSelfConsistent(bgBody), true, "精简条目: 带背景人声的小文件自洽")
        expectEqual(EnrichCacheSlim.hydrate(bgSlim, body: bgBody).map { NSDictionary(dictionary: $0) },
                    NSDictionary(dictionary: withBG), "精简条目: 背景人声从小文件补回")

        let slim = EnrichCacheSlim.slim(full)
        expectEqual(EnrichCacheSlim.isSlim(slim), true, "精简条目: slim 之后认得出来")
        expectEqual(EnrichCacheSlim.strippedFields.allSatisfy { slim[$0] == nil }, true, "精简条目: 四块正文去掉")
        expectEqual(slim["lyrics"] as? String, "[00:01.00]你好", "精简条目: 主歌词留着")
        expectEqual(slim["cover_url"] as? String, "https://x/c.jpg", "精简条目: 元数据留着")
        expectEqual(EnrichCacheSlim.presentFields(slim), EnrichCacheSlim.presentFields(full).union(.known),
                    "精简条目: 位图记下有哪几块正文")
        expectEqual(EnrichCacheSlim.presentFields(full), [.yrc, .tr, .roma, .plain, .lyrics], "精简条目: 完整条目按字段判")
        let bare: [String: Any] = ["cover_url": "x"]
        expectEqual(EnrichCacheSlim.isSlim(EnrichCacheSlim.slim(bare)), false, "精简条目: 没有正文的不精简")

        let json = #"{"crc":857489496,"lyrics":"[00:01.00]你好","lyrics_tr":"[00:01.00]hello","lyrics_roma":"[00:01.00]ni hao","lyrics_yrc":"[1000,500](1000,500,0)你好","plain_lyrics":"你好"}"#
        let body = try! JSONDecoder().decode(EnrichCacheBody.self, from: Data(json.utf8))
        let back = EnrichCacheSlim.hydrate(slim, body: body)
        expectEqual(back.map { NSDictionary(dictionary: $0) }, NSDictionary(dictionary: full),
                    "精简条目: 用正文小文件补回之后跟原条目逐字段相同(标记去掉)")
        let stale = try! JSONDecoder().decode(EnrichCacheBody.self, from: Data(#"{"crc":1,"lyrics_tr":"旧"}"#.utf8))
        expectEqual(EnrichCacheSlim.hydrate(slim, body: stale) == nil, true, "精简条目: 校验值对不上不补")

        // 小文件比条目新(引擎先写小文件、再写主缓存):自洽就用它,主歌词一起换;不自洽不用。
        expectEqual(EnrichCacheSlim.isSelfConsistent(body), true, "精简条目: 引擎写的小文件自洽")
        expectEqual(EnrichCacheSlim.isSelfConsistent(stale), false, "精简条目: 校验值对不上内容的小文件不自洽")
        let newerJSON = #"{"crc":2260255535,"lyrics":"[00:01.00]x"}"#
        let newer = try! JSONDecoder().decode(EnrichCacheBody.self, from: Data(newerJSON.utf8))
        let adopted = EnrichCacheSlim.adoptNewerBody(slim, body: newer)
        expectEqual(adopted?["lyrics"] as? String, "[00:01.00]x", "精简条目: 用更新的小文件,主歌词也换成它的")
        expectEqual(adopted.map { a in EnrichCacheSlim.strippedFields.allSatisfy { a[$0] == nil } }, true,
                    "精简条目: 更新的小文件里没有的正文就是没有,不留旧的")
        expectEqual(adopted.map { EnrichCacheSlim.isSlim($0) }, false, "精简条目: 补完去掉校验值标记")
        expectEqual(adopted?["cover_url"] as? String, "https://x/c.jpg", "精简条目: 元数据以条目为准")

        // 列表摘要建好之后主歌词也拿掉,只留标记;点开时连主歌词一起从小文件补回(见 11 章决策 93)。
        var snap: [String: [String: Any]] = ["slim": slim, "picked": slim.merging(["manual_pick_sha": "abc"]) { $1 },
                                             "bare": bare, "noLyrics": EnrichCacheSlim.slim(["lyrics_tr": "[00:01.00]t"])]
        EnrichCacheSlim.dropMainLyrics(&snap)
        expectEqual(snap["slim"]?["lyrics"] == nil && snap["slim"]?[EnrichCacheSlim.lyricsInBodyKey] as? Bool == true, true,
                    "精简条目: 主歌词拿掉、留标记")
        expectEqual(snap["picked"]?["lyrics"] as? String, "[00:01.00]你好", "精简条目: 手动选定过的留着主歌词(锁定要比它)")
        expectEqual(snap["bare"].map { NSDictionary(dictionary: $0) }, NSDictionary(dictionary: bare), "精简条目: 不是精简条目的原样")
        expectEqual(snap["noLyrics"]?[EnrichCacheSlim.lyricsInBodyKey] == nil, true, "精简条目: 没有主歌词的不加标记")
        expectEqual(["slim", "picked", "bare", "noLyrics"].map { EnrichCacheSlim.hasMainLyrics(snap[$0] ?? [:]) },
                    [true, true, false, false], "精简条目: 有没有主歌词按字段或标记判")
        expectEqual(snap["slim"].flatMap { EnrichCacheSlim.hydrate($0, body: body) }.map { NSDictionary(dictionary: $0) },
                    NSDictionary(dictionary: full), "精简条目: 拿掉主歌词的条目用小文件补回之后跟原条目逐字段相同")
        expectEqual(snap["slim"].map { NSDictionary(dictionary: EnrichCacheSlim.restoreBodies($0, from: full)) },
                    NSDictionary(dictionary: full), "精简条目: 从主缓存那条补也补回主歌词、去掉标记")
        expectEqual(snap["slim"].map { EnrichCacheSlim.stripMarkers($0)[EnrichCacheSlim.lyricsInBodyKey] == nil }, true,
                    "精简条目: 去标记时一起去掉")
        // App 侧接线:建完摘要才拿掉主歌词;摘要「有没有词」按字段或标记判。
        let storeSource = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("lyrimuse/LyricsManager/EnrichCacheStore.swift"),
                                       encoding: .utf8)) ?? ""
        let buildAt = storeSource.range(of: "box.bundle = Self.buildSummaries(from: obj, lyricsDir: lyricsDir)")?.lowerBound
        let dropAt = storeSource.range(of: "EnrichCacheSlim.dropMainLyrics(&obj)")?.lowerBound
        expectEqual(buildAt.flatMap { b in dropAt.map { b < $0 } }, true, "精简条目(契约): 建完摘要才拿掉主歌词")
        expectEqual(storeSource.contains("hasLyrics: EnrichCacheSlim.hasMainLyrics(entry)"), true,
                    "精简条目(契约): 摘要的「有没有词」认标记")

        // 整份快照按条存 JSON 字节,读哪条现解哪条(见 11 章决策 95)。
        var raw = EnrichRawSnapshot(["a": ["s": "歌", "n": 1.5, "b": true, "arr": ["x"], "obj": ["k": 2]],
                                     "p": ["manual_pick_sha": "abc", "lyrics": "[00:01.00]x"], "e": ["manual_pick_sha": ""]])
        let a = raw["a"]
        expectEqual([a?["s"] as? String == "歌", a?["n"] as? Double == 1.5, a?["b"] as? Bool == true,
                     a?["arr"] as? [String] == ["x"], (a?["obj"] as? [String: Any])?["k"] as? Int == 2], [true, true, true, true, true],
                    "整份快照: 字符串、数字、布尔、数组、嵌套字典原样读回")
        expectEqual([raw.count == 3, raw.contains("a"), !raw.contains("zz"), raw["zz"] == nil], [true, true, true, true],
                    "整份快照: 条数、有没有、没有的读出 nil")
        expectEqual(raw.pickedKeys, ["p"], "整份快照: 只记有选定指纹的,空指纹不算")
        raw["a"] = ["manual_pick_sha": "def"]
        raw["p"] = ["lyrics": "y"]
        expectEqual(raw.pickedKeys, ["a"], "整份快照: 改写时选定名单跟着变")
        raw["a"] = nil
        expectEqual([raw.contains("a"), raw.pickedKeys.isEmpty], [false, true], "整份快照: 删掉一条,名单里也去掉")
        var marked: [String: [String: Any]] = ["slim": slim]
        EnrichCacheSlim.dropMainLyrics(&marked)
        expectEqual(EnrichRawSnapshot(marked)["slim"]?[EnrichCacheSlim.lyricsInBodyKey] as? Bool, true,
                    "整份快照: 主歌词拿掉的标记读回来还是布尔")
        expectEqual(storeSource.contains("private var raw = EnrichRawSnapshot()")
                        && storeSource.contains("box.raw = EnrichRawSnapshot(obj)")
                        && storeSource.contains("for entry in raw.pickedEntries {"), true,
                    "整份快照(契约): 歌词管理按条存字节,锁定开关只看有选定指纹的")
        expectEqual(storeSource.contains("public final class Summary: Identifiable, Sendable {"), true,
                    "列表摘要(契约): 引用类型,筛选、排序、分组的几份结果不各自复制整条")
        expectEqual(storeSource.contains("for key in raw.pickedKeys { hydrate(key, fallbackToMainCache: false) }"), true,
                    "整份快照(契约): 锁定开关比主歌词前先从正文小文件补回(主歌词只在小文件里)")
        let settingsSource = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("lyrimuse/SettingsView.swift"), encoding: .utf8)) ?? ""
        expectEqual(settingsSource.contains("let count = await store.manualPickLockCount(false) ?? stats.targets")
                        && storeSource.contains("EnrichEditChannel.send(\"count_manual_lock\", [\"value\": locking])"), true,
                    "整份快照(契约): 关锁定开关先问引擎会解锁几首(这边正文小文件读不回的会漏数),问不到才用这边数的")
        let rawSource = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("LyrimuseCore/Local/EnrichRawSnapshot.swift"), encoding: .utf8)) ?? ""
        expectEqual(rawSource.contains("data[key] = bytes.withUnsafeBytes { Data($0) }"), true,
                    "整份快照(契约): 按实际长度复制再存,不带 JSONSerialization 的扩容余量")

        // 引擎不再往主缓存里写主歌词:精简条目只有位图的主歌词位(32),主歌词在正文小文件里(见 15 章决策 29)。
        var noMain = slim
        noMain.removeValue(forKey: "lyrics")
        noMain[EnrichCacheSlim.fieldsKey] = NSNumber(value: EnrichCacheSlim.presentFields(slim).union(.lyrics).rawValue)
        expectEqual([EnrichCacheSlim.hasMainLyrics(noMain), EnrichCacheSlim.hasMainLyrics(bare)], [true, false],
                    "主歌词只在小文件里: 有没有主歌词认位图的主歌词位")
        expectEqual(EnrichCacheSlim.hydrate(noMain, body: body)?["lyrics"] as? String, full["lyrics"] as? String,
                    "主歌词只在小文件里: 补全时连主歌词一起补回,不用标记")
        expectEqual(EnrichCacheSlim.restoreBodies(noMain, from: full)["lyrics"] as? String, full["lyrics"] as? String,
                    "主歌词只在小文件里: 从主缓存那条补也补回主歌词")
        expectEqual(EnrichCacheSlim.presentFields(full).contains(.lyrics), true, "主歌词只在小文件里: 完整条目的位图也记主歌词")
        expectEqual(EnrichCacheSlim.adoptNewerBody(slim, body: stale) == nil, true, "精简条目: 不自洽的小文件不用")
        expectEqual(EnrichCacheSlim.adoptNewerBody(full, body: newer) == nil, true, "精简条目: 完整条目不需要补")

        // JSONSerialization 吞掉开头一个 U+FEFF:从主缓存解出来的条目按去掉 BOM 的内容算校验值,正文小文件里是原样。
        do {
            let bomJSON = Data("{\"lyrics_yrc\":\"\u{FEFF}[ti:x]\",\"lyrics\":\"[00:01.00]x\"}".utf8)
            let parsed = try! JSONSerialization.jsonObject(with: bomJSON) as! [String: Any]
            expectEqual((parsed["lyrics_yrc"] as? String)?.unicodeScalars.first == "\u{FEFF}", false,
                        "精简条目: JSONSerialization 确实吞掉开头的 U+FEFF(这条挂了说明系统行为变了,口径可以收窄)")
            let bomBody = try! JSONDecoder().decode(EnrichCacheBody.self, from: Data(
                "{\"crc\":1,\"lyrics\":\"[00:01.00]x\",\"lyrics_yrc\":\"\u{FEFF}[ti:x]\"}".utf8))
            let slimParsed = EnrichCacheSlim.slim(parsed)
            let back = EnrichCacheSlim.hydrate(slimParsed, body: bomBody)
            expectEqual((back?["lyrics_yrc"] as? String)?.unicodeScalars.first == "\u{FEFF}", true,
                        "精简条目: 去掉 BOM 口径的校验值也认,补回的是正文小文件里的原样内容")
        }

        // 被改过的精简条目写回前从盘上那条取正文:改动的元数据保留、正文一个不少。
        var edited = slim
        edited["instrumental"] = true
        let restored = EnrichCacheSlim.restoreBodies(edited, from: full)
        var expected = full
        expected["instrumental"] = true
        expectEqual(NSDictionary(dictionary: restored), NSDictionary(dictionary: expected),
                    "精简条目: restoreBodies 保留改动、补回正文、去掉标记")

        let oldIndex: [String: [String: Any]] = ["a": ["lyrics": "x", "body_crc": 9]]
        expectEqual(EnrichCacheSlim.indexHasFields(oldIndex), false, "精简条目: 老版本索引(没有位图)不当精简快照")
        expectEqual(EnrichCacheSlim.indexHasFields(["a": slim, "b": bare]), true, "精简条目: 新索引可以直接用")
    }

    // ---- EnrichCacheKeys: 缓存 key 与 lyrics/ 导出文件名 ----
    //
    // 实测排查坐实的真实 bug 的回归测试:引擎会给"sanitize 出来的文件名只差
    // 大小写"的碰撞组成员改用带 crc32 后缀的文件名(lyricsexport.go:105-141),而 Swift 侧原来
    // 一律只认普通名——删除时漏删 → 引擎重启后 importLyricsFromFiles 从残留文件把条目
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
        // 引擎实际写在磁盘上的那个一模一样"。
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
        // "|" 换成 " - ",文件系统不安全字符转下划线,跟 lyrimuse-engine/lyricsexport.go 的
        // sanitizeLyricsFilename 对齐。
        expectEqual(EnrichCacheKeys.sanitizeFilename("Artist|Song|Album"), "Artist - Song - Album", "EnrichCacheKeys: 「|」换成「 - 」")
        expectEqual(EnrichCacheKeys.sanitizeFilename("A/B|C:D|E*F?"), "A_B - C_D - E_F_", "EnrichCacheKeys: 不安全字符转下划线")

    }

    do {
        // 文件名字节上限。 必须跟 lyrimuse-engine/lyricsexport.go 的 lyricsFilenameMaxBytes
        // 同值、同截断规则,否则删除时算出的文件名对不上 → 漏删 → 条目复活。
        expectEqual(EnrichCacheKeys.filenameMaxBytes, 200, "EnrichCacheKeys: 文件名字节上限跟 Go 侧同值")

        // 没超限的名字一个字节都不该动。
        expectEqual(
            EnrichCacheKeys.truncateFilenameBase("陈绮贞 - 灵感 - 还是会寂寞"),
            "陈绮贞 - 灵感 - 还是会寂寞",
            "EnrichCacheKeys: 未超限的文件名原样返回"
        )

        // 汉字 3 字节,200 不是 3 的倍数 —— 截断点必然落在字符中间,这是最要紧的一条:
        // 按字符数截会漏判,切在字节中间会产生 U+FFFD。
        let longCJK = String(repeating: "歌", count: 100)
        let cut = EnrichCacheKeys.truncateFilenameBase(longCJK)
        expectEqual(cut.utf8.count <= EnrichCacheKeys.filenameMaxBytes, true, "EnrichCacheKeys: 截断后不超过字节上限")
        expectEqual(cut.count, 66, "EnrichCacheKeys: 200 字节容得下 66 个汉字(198 字节)")
        expectEqual(cut.contains("\u{FFFD}"), false, "EnrichCacheKeys: 截断不产生替换字符")

        // 4 字节字符同理。
        let longEmoji = String(repeating: "🎵", count: 60)
        let cutEmoji = EnrichCacheKeys.truncateFilenameBase(longEmoji)
        expectEqual(cutEmoji.utf8.count <= EnrichCacheKeys.filenameMaxBytes, true, "EnrichCacheKeys: emoji 截断后不超上限")
        expectEqual(cutEmoji.contains("\u{FFFD}"), false, "EnrichCacheKeys: emoji 截断不产生替换字符")

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

    // ---- EnrichCacheKeys: 缓存 key 归一化,必须跟引擎逐字节一致 ----
    //
    // 这组用例跟 lyrimuse-engine/enrichkey_test.go 的 TestNormEnrichTitle 是**同一张表**。两边只要
    // 有一处对不上,引擎按归一化 key 写盘、悬浮窗按另一种拼法查,结果不是"显示了旧歌词"
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
            // "慢板"/"快板"是录音版本标记,不是译名噪音,见引擎侧
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
            ("字连接符", "\u{2060}千人操", "千人操"),
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
        // 幂等:迁移每次引擎启动都会跑一遍
        let once = K.normalizedKey(artist: "丁世光", title: "不散的筵席（I Miss You）", album: "神經志 The Journal")
        expectEqual(once, "丁世光|不散的筵席|神經志 The Journal", "缓存key: 三段拼接")
        expectEqual(K.normalizedTitle("不散的筵席"), "不散的筵席", "缓存key: 归一化过的再算一次不变")

        // ---- looseKey:只用于查询兜底的宽松形态 ----
        //
        // 引擎把"其实是同一首歌"的重复条目合并成一条后,缓存里只剩最适合显示的那个写法;
        // 播放器报的可能是另一个写法,靠这一层才查得到。 它**只能**用于兜底,绝不能拿去构造
        // key —— 繁简这一档两侧本来就不一致(引擎用 OpenCC 词典、这边用 ICU),写进 key
        // 就是「悬浮窗整首歌没词」。理由完整版见 EnrichCacheKeys.looseKey 的注释。
        let loosePairs: [(String, String, String)] = [
            ("半角空格", "陶喆|Susan 说|太平盛世", "陶喆|Susan说|太平盛世"),
            ("中英之间空格", "陶喆|Sula 与 Lampa 的寓言|太平盛世", "陶喆|Sula 与 Lampa的寓言|太平盛世"),
            ("歌名繁简", "方大同|千纸鹤|回到未來", "方大同|千紙鶴|回到未來"),
            ("歌手名繁简", "孙燕姿|我懷念的|逆光", "孫燕姿|我懷念的|逆光"),
            // ICU 对「嶽」按上下文取舍、单独出现时不转;引擎的 OpenCC 转。靠异体字表拉齐。
            ("ICU 不转的异体字", "张震岳|路口|OK", "張震嶽|路口|OK"),
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

        // ---- 跨语言对拍:跟引擎 keyparity_test.go 逐条同样的输入和期望值 ----
        //
        // 宽松 key、cleanTag、歌名剥括号、手动选词指纹都要跟 Go 逐字节一致:引擎按宽松 key 复用
        // 缓存时这边兜不到就是整首没词,指纹对不上就是手动锁悄悄失效。改向量必须两边一起改。
        // 一律按标量数组比:String == 按规范等价比较,兼容表意字符与统一汉字会被判成相等。
        let parityLoose: [(String, String)] = [
            ("张震岳|路口|OK", "张震岳|路口|ok"),
            ("張震嶽|路口|OK", "张震岳|路口|ok"),
            ("方大同|等著你回來|Soulboy", "方大同|等著你回来|soulboy"),
            ("谢安琪|囍帖街|", "谢安琪|囍帖街|"),
            ("李荣浩|裙姊|嗯", "李荣浩|裙姊|嗯"),
            ("不瞭解|一目瞭然|乾杯", "不了解|一目了然|干杯"),
            ("İSTANBUL|ΣΟΦΙΑΣ|X", "istanbul|σοφιασ|x"),
            ("A/B、C|T|X", "a&b&c|t|x"),
            ("A\u{ff0c}B|T|X", "a&b|t|x"),       // 全角逗号也是分隔符
            ("妳|祂|牠", "你|他|它"),              // OpenCC 表里没有,走异体字表兜底
            ("藉藉无名|X|Y", "藉藉无名|x|y"),      // 词组取最长:先命中「藉藉」会变成「借借」
            ("上\u{f99b}|X|Y", "上链|x|y"), // 兼容表意字符先经 NFC 转成规范的「鍊」,再繁转简
        ]
        for (input, want) in parityLoose {
            expectEqual(Array(K.looseKey(input).unicodeScalars), Array(want.unicodeScalars), "跨语言对拍 looseKey: \(input)")
        }
        let parityClean: [(String, String)] = [
            ("A\u{200d}B", "AB"),
            ("👩\u{200d}🎤 Song", "👩🎤 Song"),
            ("A\u{2009}B", "A B"),
            ("\u{3000}X\u{2028}", "X"),
            (" A\u{00a0}\u{00a0}B ", "A B"),
            ("Sa\u{0304}n-Z", "S\u{0101}n-Z"), // 分解形式转 NFC
        ]
        for (input, want) in parityClean {
            expectEqual(Array(K.cleanTag(input).unicodeScalars), Array(want.unicodeScalars), "跨语言对拍 cleanTag: \(input.unicodeScalars.map { String($0.value, radix: 16) })")
        }
        let parityTitle: [(String, String)] = [
            ("A (B (C)", "A"),
            ("A (B) (C)", "A"),
            ("歌 (Live)", "歌 (Live)"),
            ("歌（译名）[Explicit]", "歌"),
            ("(Interlude)", "(Interlude)"),
            ("歌 (Live\u{0301})", "歌"), // 先转 NFC:e + 组合重音成了 é,「Livé」不是版本词 live,当译名括号剥掉
        ]
        for (input, want) in parityTitle {
            expectEqual(Array(K.normalizedTitle(input).unicodeScalars), Array(want.unicodeScalars), "跨语言对拍 normalizedTitle: \(input)")
        }
        expectEqual(Array(K.sanitizeFilename("A|B\u{200b}").unicodeScalars), Array("A - B\u{200b}".unicodeScalars),
                    "跨语言对拍 sanitizeFilename: 不裁 U+200B")
        let parityCanon: [(String, String, String)] = [
            ("[00:01.00]词\u{200b}\n[00:02.00]\u{200b}二", "词\u{200b}\n\u{200b}二", "75044a9df204"),
            ("[00:01.00]]\u{0301}x", "]\u{0301}x", "ff3cee9eb5f6"),
        ]
        for (input, want, sha) in parityCanon {
            expectEqual(Array(ManualPickLock.canonicalLyrics(input).unicodeScalars), Array(want.unicodeScalars),
                        "跨语言对拍 canonicalLyrics(按标量比)")
            expectEqual(ManualPickLock.fingerprint(lyrics: input), sha, "跨语言对拍 fingerprint")
        }

        // OpenCC 表与引擎内嵌的那两份 .txt 逐条一致(漏跑 scripts/gen-opencc-t2s.py 会在这里红)。
        // 解析规则同引擎 t2s.go 的 loadT2SDict。
        do {
            let dictDir = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("lyrimuse-engine/dictionary")
            func load(_ name: String) -> [[Unicode.Scalar]: [Unicode.Scalar]]? {
                guard let text = try? String(contentsOf: dictDir.appendingPathComponent(name), encoding: .utf8) else { return nil }
                var m: [[Unicode.Scalar]: [Unicode.Scalar]] = [:]
                for raw in text.unicodeScalars.split(separator: "\n") {
                    let line = GoStringSemantics.trimSpace(raw)
                    guard let tab = line.unicodeScalars.firstIndex(of: "\t") else { continue }
                    let key = Array(line.unicodeScalars[..<tab])
                    let rest = line.unicodeScalars[line.unicodeScalars.index(after: tab)...]
                    guard let first = rest.split(whereSeparator: { GoStringSemantics.isSpace($0) }).first else { continue }
                    m[key] = Array(first)
                }
                return m
            }
            if let chars = load("TSCharacters.txt"), let phrases = load("TSPhrases.txt") {
                var fileChars: [Unicode.Scalar: [Unicode.Scalar]] = [:]
                for (k, v) in chars where k.count == 1 { fileChars[k[0]] = v }
                expectEqual(fileChars == OpenCCT2S.characterEntries, true, "OpenCC 单字表与引擎的 TSCharacters.txt 逐条一致")
                expectEqual(phrases == OpenCCT2S.phraseEntries, true, "OpenCC 词组表与引擎的 TSPhrases.txt 逐条一致")
            } else {
                expectEqual(false, true, "OpenCC 对账: 读不到 lyrimuse-engine/dictionary 下的 TS*.txt")
            }
        }
        // looseKey 绝不能影响 normalizedKey —— 后者是真正落盘/显示用的那个。
        expectEqual(
            K.normalizedKey(artist: "孙燕姿", title: "我懷念的", album: "逆光"),
            "孙燕姿|我懷念的|逆光",
            "缓存key: looseKey 不污染 normalizedKey"
        )
    }

    // ---- EnrichCacheReader.artistTitleKey:「最近播放」封面的本机兜底键 ----
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

    // ---- 按日历天定义的缓存:跨零点必须作废 ----
    //
    // 那张卡的 6 小时 TTL 只知道过了多少秒,不知道跨没跨过零点 —— 22:00 取到的那份,
    // 次日 02:00 时 TTL 还没到期,会被继续显示成"今天"的内容。App 常驻不重启、缓存
    // 时间戳只在内存里,所以这里必须"跨天优先于 TTL"。
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
        // 系统时钟往回拨:上次取数「在未来」,不可信,当作过期。
        expectEqual(needs(fetched: at(8, 17, 14), day: at(8, 17, 14), now: at(8, 17, 10)), true,
                    "跨天缓存: 时钟回拨(上次取数晚于现在)要拉")
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

    // MARK: - 合唱 credit 归并(ArtistCredit)
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
        // 中文「和」跟引擎 normalizeArtistCreditHanAnd 同一条判据。
        expectEqual(ArtistCredit.primary("陶喆和盧廣仲"), "陶喆", "合唱 credit: 两侧各 ≥2 个汉字的「和」是分隔符")
        expectEqual(ArtistCredit.primary("Tom和Jerry"), "Tom", "合唱 credit: 两侧是字母的「和」是分隔符")
        expectEqual(ArtistCredit.primary("李和平"), nil, "合唱 credit: 「李和平」是人名,不切")
        expectEqual(ArtistCredit.primary("周杰伦和"), nil, "合唱 credit: 结尾的「和」不切")
        expectEqual(ArtistCredit.primary("UMI, 金泰亨"), "UMI", "合唱 credit: 逗号分隔")
        expectEqual(ArtistCredit.primary("Daniel Caesar feat. Mustafa"), "Daniel Caesar",
                    "合唱 credit: feat. 也算多人")
        expectEqual(ArtistCredit.primary("Doja Cat (feat. SZA)"), "Doja Cat",
                    "合唱 credit: 括号里的 feat. 一并切掉")
        expectEqual(ArtistCredit.primary("Daniel Caesar"), nil, "单人 credit: 返回 nil")
        // feat 家族要有**左词边界**(实测出来的真 bug):`ft ` 会在词中命中,
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

    // MARK: - 缓存 key:结尾副题必须被剥掉(「歌词管理不自动定位」的根因)
    //
    // 副题形态举例:Apple Music 报的曲名带完整副题(如「Dynasties and Dystopia (from
    // the series Arcane League of Legends)」),而缓存里的 key 是剥掉副题的写法(引擎
    // 的 enrichKey 剥的)。定位函数必须同样剥掉副题再拼 "artist|title|album" 比对;
    // looseKey 只折大小写/空格/繁简,**折不掉**副题,兜底也接不住 —— 于是静默返回。
    // 这两条断言把"镜像函数必须剥、looseKey 必须剥不掉"钉住。
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

    // MARK: - looseKey 必须折平合 credit 分隔符(跟引擎的 loosenEnrichKey 同步)
    //
    // 同一次播放里两条路径对多歌手串的写法可能系统性不同 —— 播放器报 `A/B/C`,
    // 专辑预取从 Apple Music 曲目表拿到 `A & B & C`。
    // 两侧的宽松键都得折平这一档,否则引擎那边不再长重复条目,而这边(EnrichCacheReader
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
        // 原有两档(空格 / 繁简)仍然成立
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

    // ---- 同名不同录音的时长变体(引擎 enrichKeyDurationVariant / durationMismatch) ----
    do {
        let base = "李宗盛|山丘|山丘"
        expectEqual(EnrichCacheKeys.durationVariant(base, n: 2), "李宗盛|山丘~dur2|山丘", "时长变体: 后缀加在标题段")
        expectEqual(EnrichCacheKeys.durationVariant("a|b|c|d", n: 3), "a|b~dur3|c|d", "时长变体: 只按前两个 | 切")
        expectEqual(EnrichCacheKeys.strippingDurationVariant("李宗盛|山丘~dur2|山丘"), base, "时长变体: 去掉后缀回到基条目")
        expectEqual(EnrichCacheKeys.strippingDurationVariant(base), base, "时长变体: 不是变体原样返回")
        expectEqual(EnrichCacheKeys.strippingDurationVariant("a|x~dur9|c"), "a|x~dur9|c", "时长变体: 超出 2…8 不认")
        expectEqual(EnrichCacheKeys.durationMismatch(275.1, 405.8), true, "时长变体: 差 32% 算冲突")
        expectEqual(EnrichCacheKeys.durationMismatch(275.1, 280), false, "时长变体: 差 2% 不算")
        expectEqual(EnrichCacheKeys.durationMismatch(nil, 280), false, "时长变体: 一方未知不算冲突")
    }

    // ---- 宽松匹配的胜者规则(引擎 betterEnrichEntry 同序) ----
    do {
        func entry(_ json: String) -> EnrichCacheEntry {
            try! JSONDecoder().decode(EnrichCacheEntry.self, from: Data(json.utf8))
        }
        let manual = entry(#"{"lyrics":"x","manual_lyrics":true,"lyrics_score":1}"#)
        let scored = entry(#"{"lyrics":"x","lyrics_score":90}"#)
        let empty = entry(#"{"lyrics_score":99,"ts":9}"#)
        let slimYRC = entry(#"{"lyrics":"x","lyrics_score":90,"body_crc":1,"body_fields":129}"#)
        let newer = entry(#"{"lyrics":"x","lyrics_score":90,"ts":5}"#)
        expectEqual(EnrichCacheReader.betterEntry(manual, scored, "b", "a"), true, "宽松胜者: 人工修正优先")
        expectEqual(EnrichCacheReader.betterEntry(scored, empty, "b", "a"), true, "宽松胜者: 有词胜过分数高")
        expectEqual(EnrichCacheReader.betterEntry(slimYRC, scored, "b", "a"), true, "宽松胜者: 同分时有逐字(精简位图)优先")
        expectEqual(EnrichCacheReader.betterEntry(newer, scored, "b", "a"), true, "宽松胜者: 其余相同时解析得晚的优先")
        expectEqual(EnrichCacheReader.betterEntry(scored, scored, "a", "b"), true, "宽松胜者: 全同按 key 字典序")
    }

    // ---- 标了纯音乐:按没有歌词交给显示层,歌词留在条目里(EnrichCacheReader.makeLyrics) ----
    do {
        func entry(_ json: String) -> EnrichCacheEntry {
            try! JSONDecoder().decode(EnrichCacheEntry.self, from: Data(json.utf8))
        }
        func make(_ e: EnrichCacheEntry) -> EnrichCacheLyrics {
            EnrichCacheReader.makeLyrics(e, lyrics: "[00:01.00]词", tr: "tr", roma: "roma", yrc: "yrc", plain: "纯文本", bg: "bg")
        }
        let marked = make(entry(#"{"lyrics":"[00:01.00]词","instrumental":true,"ts":1}"#))
        expectEqual([marked.lyrics, marked.lyricsTr, marked.lyricsRoma, marked.lyricsYRC, marked.lyricsBG, marked.plainLyrics]
                        .allSatisfy(\.isEmpty), true,
                    "纯音乐标记: 歌词、译文、罗马音、逐字、背景人声、纯文本都不交")
        expectEqual(marked.instrumental && marked.resolved && !marked.searchIncomplete, true,
                    "纯音乐标记: 按纯音乐交出去,不报搜索未完成")
        expectEqual(marked.storedLyrics, "[00:01.00]词", "纯音乐标记: 条目里存着的正文照给「当前使用」判据")
        let plain = make(entry(#"{"lyrics":"[00:01.00]词","ts":1}"#))
        expectEqual(plain.lyrics == "[00:01.00]词" && plain.lyricsYRC == "yrc" && plain.plainLyrics == "纯文本" && !plain.instrumental,
                    true, "纯音乐标记: 没标的照常交出歌词")
        func blank(_ e: EnrichCacheEntry) -> EnrichCacheLyrics {
            EnrichCacheReader.makeLyrics(e, lyrics: "", tr: "", roma: "", yrc: "", plain: "", bg: "")
        }
        expectEqual(blank(entry(#"{"lyrics_sources_skipped":["qq"],"ts":1}"#)).searchIncomplete, true,
                    "纯音乐标记: 没标的、有源被跳过,照常报搜索未完成")
        expectEqual(blank(entry(#"{"lyrics_sources_skipped":["qq"],"instrumental":true,"ts":1}"#)).searchIncomplete, false,
                    "纯音乐标记: 标了纯音乐的不报搜索未完成")
    }
}
