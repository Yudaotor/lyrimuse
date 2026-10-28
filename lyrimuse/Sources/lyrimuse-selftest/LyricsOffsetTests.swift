import LyrimuseCore
import Foundation

// 歌词时间轴偏移:基准 + 单曲微调 / 作用域 / 已校准名单。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runLyricsOffsetTests() {
    // ---- LyricsOffsetStore: 校正值 key 要按"歌词内容"区分,不能只按歌手/歌名 ----

    do {
        let keyA = LyricsOffsetStore.trackKey(artist: "陈奕迅", title: "富士山下", lyrics: "[00:10.00]第一句\n", lyricsYRC: "")
        let keyASame = LyricsOffsetStore.trackKey(artist: "陈奕迅", title: "富士山下", lyrics: "[00:10.00]第一句\n", lyricsYRC: "")
        let keyBDifferentLyrics = LyricsOffsetStore.trackKey(artist: "陈奕迅", title: "富士山下", lyrics: "[00:12.00]第一句(重新匹配的另一份歌词)\n", lyricsYRC: "")
        expectEqual(keyA, keyASame, "LyricsOffsetStore.trackKey: 同一首歌+同一份歌词内容,key 应该完全一致")
        expectEqual(keyA == keyBDifferentLyrics, false, "LyricsOffsetStore.trackKey: 同一首歌换了一份不同的歌词内容,key 应该不同")
    }

    // ---- LyricsOffsetStore.trackKey:歌手/歌名必须归一化(修的真 bug) ----
    //
    // 播放侧传播放器报的**原始**歌手/歌名,「歌词管理」传缓存 key 拆出来的(已归一化)那两段。
    // trackKey 不自己归一化的话,同一首歌就有两个身份:在管理页敲的偏移播放时查不到、菜单栏
    // 调的值在管理页看不见、「重置」也清不掉。实测这台机器 2483 首里 111 首(4.5%)落在这个
    // 差异上 —— 全是歌名结尾带译名括号/`(with X)` 的那类。
    do {
        let lrc = "[00:10.00]句\n"
        func key(_ artist: String, _ title: String) -> String {
            LyricsOffsetStore.trackKey(artist: artist, title: title, lyrics: lrc, lyricsYRC: "")
        }
        // 这一条就是 bug 本体:带译名括号的原始歌名 vs 缓存里那个剥过的歌名,必须同一个 key。
        expectEqual(key("丁世光", "不散的筵席（I Miss You）"), key("丁世光", "不散的筵席"),
                    "trackKey: 结尾译名括号剥不剥都是同一首歌")
        expectEqual(key("Ari Lennox", "Queen Space (with Summer Walker)"), key("Ari Lennox", "Queen Space"),
                    "trackKey: (with X) 同理")
        // 幂等:管理页传进来的本来就是归一化过的值,再过一遍不能变。
        expectEqual(key("丁世光", "不散的筵席"), key("丁世光", "不散的筵席"), "trackKey: 归一化是幂等的")
        // 版本标记不能剥 —— 那是另一个录音,合并了就是把两首不同的音频当成同一首。
        expectEqual(key("宇多田ヒカル", "Automatic (Remastered 2014)") == key("宇多田ヒカル", "Automatic"),
                    false, "trackKey: (Remastered 2014) 是版本标记,不能剥")
        // 全角空格/零宽字符走 cleanTag,跟 enrich 缓存 key 同一套。
        expectEqual(key("Hikaru Utada", "Gold\u{3000}～また逢う日まで～"),
                    key("Hikaru Utada", "Gold ～また逢う日まで～"),
                    "trackKey: 全角空格折成普通空格")
    }

    // ---- trackKey:开头的 BOM 不算内容 ----
    // 播放侧(JSONDecoder)读到的正文开头带 U+FEFF,「歌词管理」(JSONSerialization)读到的被吞掉了 ——
    // 两边必须算出同一个 key,否则在管理页敲的偏移播放时查不到。
    do {
        let plain = "[00:01.00]第一句\n[00:05.00]第二句"
        expectEqual(LyricsOffsetStore.trackKey(artist: "歌手", title: "歌名", lyrics: "\u{FEFF}" + plain, lyricsYRC: ""),
                    LyricsOffsetStore.trackKey(artist: "歌手", title: "歌名", lyrics: plain, lyricsYRC: ""),
                    "trackKey: 正文开头的 BOM 不影响指纹")
        expectEqual(LyricsOffsetStore.trackKey(artist: "歌手", title: "歌名", lyrics: "", lyricsYRC: "\u{FEFF}[1000,500](1000,500,0)字"),
                    LyricsOffsetStore.trackKey(artist: "歌手", title: "歌名", lyrics: "", lyricsYRC: "[1000,500](1000,500,0)字"),
                    "trackKey: 逐字串开头的 BOM 同样不算")
        expectEqual(LyricsOffsetStore.trackKey(artist: "歌手", title: "歌名", lyrics: plain + "\u{FEFF}", lyricsYRC: "")
                        == LyricsOffsetStore.trackKey(artist: "歌手", title: "歌名", lyrics: plain, lyricsYRC: ""),
                    false, "trackKey: 只剥开头,正文里别处的字符照样算内容")
    }

    // ---- 备份归档:文件名第一道闸按 Unicode 标量查 / 解压有上限 ----
    do {
        typealias B = LyricsBackupArchive
        expectEqual(B.sanitizedFileName("a/\u{338}b.lrc") == nil, true, "备份文件名: 斜杠后跟组合字符也拒收")
        expectEqual(B.sanitizedFileName(".\u{301}x.lrc") == nil, true, "备份文件名: 点开头后跟组合字符也拒收")
        expectEqual(B.sanitizedFileName("a\u{0}b.lrc") == nil, true, "备份文件名: 控制字符拒收")
        expectEqual(B.sanitizedFileName("陶喆 - 天天 - I'm O.K..yrc"), "陶喆 - 天天 - I'm O.K..yrc", "备份文件名: 正常名字照收")
        let payload = B.Payload(at: "2026-09-27T00:00:00Z", device: "Mac", files: ["a.lrc": "[00:01.00]x"], pins: [:])
        let packed = B.encode(payload)!
        expectEqual(B.decode(packed)?.files["a.lrc"], "[00:01.00]x", "备份归档: 压缩包往返")
        expectEqual(B.inflate(packed, limit: 10) == nil, true, "备份归档: 解压超过上限就停")
        let plainJSON = try! JSONEncoder().encode(payload)
        expectEqual(B.decode(plainJSON)?.device, "Mac", "备份归档: 明文包照样认")

        // 主缓存是精简格式时,纯文本歌词和背景人声只在正文小文件里:打包 meta 要从那里补回来。
        let key = "歌手|歌名|专辑"
        let full: [String: Any] = ["lyrics": "[00:01.00]x", "plain_lyrics": "纯文本", "lyrics_bg": "[1000,500](1000,500,0)啊",
                                   "cover_url": "https://example.com/a.jpg"]
        let slim = EnrichCacheSlim.slim(full)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyrimuse-selftest-bodies-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let body: [String: Any] = ["crc": EnrichCacheSlim.bodyCRC(full), "lyrics": "[00:01.00]x",
                                   "plain_lyrics": "纯文本", "lyrics_bg": "[1000,500](1000,500,0)啊"]
        try? JSONSerialization.data(withJSONObject: body)
            .write(to: dir.appendingPathComponent(DecisionSidecar.fileName(forKey: key)))
        let cache = try! JSONSerialization.data(withJSONObject: [key: slim])
        let meta = B.strippedMeta(fromCacheJSON: cache, bodiesDirectory: dir)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String: Any]] }?[key]
        expectEqual(meta?["plain_lyrics"] as? String, "纯文本", "备份 meta: 纯文本歌词从正文小文件补回")
        expectEqual(meta?["lyrics_bg"] as? String, "[1000,500](1000,500,0)啊", "备份 meta: 背景人声从正文小文件补回")
        expectEqual(meta?["body_crc"] == nil && meta?["body_fields"] == nil && meta?["lyrics"] == nil, true,
                    "备份 meta: 精简标记和歌词六字段都不带")
        expectEqual(meta?["cover_url"] as? String, "https://example.com/a.jpg", "备份 meta: 其余字段原样带走")
    }

    // ---- 存量 key 搬迁:老记录留在旧形态下会永久查不到 ----
    do {
        let fp = "abc123def456"
        let legacy = "丁世光|不散的筵席（I Miss You）|\(fp)"
        let canonical = "丁世光|不散的筵席|\(fp)"

        // 旧形态搬到新形态,值原样保留
        let moved = LyricsOffsetStore.migratedOffsetKeys([legacy: 1800])
        expectEqual(moved, [canonical: 1800], "key 搬迁: 旧形态被搬到归一化形态,值不变")

        // 已经是归一化形态的原样不动
        let untouched = LyricsOffsetStore.migratedOffsetKeys([canonical: 700])
        expectEqual(untouched, [canonical: 700], "key 搬迁: 已归一化的记录原样不动")

        // 撞车:两种拼法同时存在(指纹相同=同一份内容),让"本来就是归一化形态"那条赢 ——
        // 它是新形态下唯一查得到的身份,拿旧形态的值盖掉它等于把用户正在用的换成更旧的。
        let collided = LyricsOffsetStore.migratedOffsetKeys([legacy: 1800, canonical: 700])
        expectEqual(collided, [canonical: 700], "key 搬迁: 撞车时归一化形态那条胜出")

        // 段数不对的 key(不是这个仓库写出来的)原样保留,不猜
        let weird = LyricsOffsetStore.migratedOffsetKeys(["没有分隔符": 1, "只有一个|分隔符": 2])
        expectEqual(weird, ["没有分隔符": 1, "只有一个|分隔符": 2], "key 搬迁: 段数不对的 key 不动")

        // 空指纹段(歌词还没解析出来时调过偏移)也要能搬,不能崩
        let emptyFp = LyricsOffsetStore.migratedOffsetKeys(["丁世光|不散的筵席（I Miss You）|": 300])
        expectEqual(emptyFp, ["丁世光|不散的筵席|": 300], "key 搬迁: 指纹段为空也照搬")

        // 时长变体条目:trackKey 剥掉歌名末尾 ~durN,存量 key 也要剥,否则播放侧和歌词管理都查不到。搬两遍结果不变。
        let variant = LyricsOffsetStore.migratedOffsetKeys(["丁世光|不散的筵席~dur2|\(fp)": 400])
        expectEqual(variant, [canonical: 400], "key 搬迁: 歌名末尾的时长变体位剥掉")
        let played = LyricsOffsetStore.trackKey(artist: "丁世光", title: "不散的筵席~dur2", lyrics: "", lyricsYRC: "")
        expectEqual(variant.keys.first, played + fp, "key 搬迁: 剥完跟 trackKey 的前两段一致")
        expectEqual(LyricsOffsetStore.migratedOffsetKeys(variant), variant, "key 搬迁: 幂等")
        expectEqual(LyricsOffsetStore.migratedOffsetKeys(["丁世光|不散的筵席~dur2|\(fp)": 400, canonical: 700]), [canonical: 700],
                    "key 搬迁: 变体跟不带变体位的撞车时不带的那条胜出")
    }

    // MARK: - 歌词时间轴偏移:基准(全部 / 按播放器,二选一)+ 单曲微调
    //
    // 加全局偏移时补的,补上「按播放器」那层。
    //
    // 播放器那层跟「全部」是**二选一、不相加**(改的语义:「不要和那个全部
    // 相加,只有要么全部,要么单个」)。"配过"看键在不在,单独配成 0 也算;点 × 删键才是撤掉单独设置、
    // 重新跟随「全部」。
    //
    // 真正容易写错的不是那个加法,而是几档之间的**独立性**:「重置这首歌」绝不能把设备侧的基准
    // 一起抹掉(那是用户最不希望被连带清掉的东西),反过来改基准也不该动已经调好的单曲值;而按
    // 播放器那层既不该被前两者连带,也**绝不能串台**(把浏览器那档套到 Apple Music 上)。
    // LyricsOffsetStore 是 @MainActor,而这个文件的顶层代码是 nonisolated 的(所以
    // trackKey 才特意标了 nonisolated,见那边的注释)。顶层代码本来就跑在主线程上,
    // assumeIsolated 把这件事告诉编译器即可,不需要把整个 selftest 改成 async。
    MainActor.assumeIsolated {
        let store = LyricsOffsetStore.shared
        let key = LyricsOffsetStore.trackKey(artist: "A", title: "T", lyrics: "[00:01.00]x", lyricsYRC: "")
        // 起点归零 —— 这个 store 落在 UserDefaults 上(selftest 是独立可执行文件,域是
        // lyrimuse-selftest,污染不到用户的 App;但那份 plist 跨运行持久,不清会读到上次的残留)。
        store.setGlobalOffset(0)
        store.reset(forKey: key, pinKey: "", siblings: .none)
        for id in store.playerOffsets.keys { store.removePlayerOffset(forBundleID: id) }
        expectEqual(store.effectiveOffset(forKey: key, siblings: .none), 0, "偏移: 各层都没调时是 0")

        store.setGlobalOffset(300)
        expectEqual(store.effectiveOffset(forKey: key, siblings: .none), 300, "偏移: 只有全局基准时按它算")

        store.nudge(by: -100, forKey: key, pinKey: "", siblings: .none)
        expectEqual(store.offset(forKey: key), -100, "偏移: 单曲微调独立记账")
        expectEqual(store.effectiveOffset(forKey: key, siblings: .none), 200, "偏移: 生效值 = 全局 + 单曲")

        store.reset(forKey: key, pinKey: "", siblings: .none)
        expectEqual(store.offset(forKey: key), 0, "偏移: 重置清掉单曲微调")
        expectEqual(store.globalOffsetMs, 300, "偏移: 重置不动全局基准")
        expectEqual(store.effectiveOffset(forKey: key, siblings: .none), 300, "偏移: 重置后回到全局基准")

        store.setOffset(-250, forKey: key, pinKey: "", siblings: .none)
        store.setGlobalOffset(-50)
        expectEqual(store.offset(forKey: key), -250, "偏移: 改全局基准不动单曲微调")
        expectEqual(store.effectiveOffset(forKey: key, siblings: .none), -300, "偏移: 两个负值相加")

        // 空 key(从没拿到过曲目信息)不该被当成一首歌记账 —— 但全局基准跟曲目无关,照样生效
        store.setGlobalOffset(120)
        store.nudge(by: 500, forKey: "||", pinKey: "", siblings: .none)
        expectEqual(store.offset(forKey: "||"), 0, "偏移: 空 key 不记账")
        expectEqual(store.effectiveOffset(forKey: "||", siblings: .none), 120, "偏移: 空 key 下全局基准仍然生效")

        // ---- 「按播放器」那一层----
        //
        // 那版同名层的断言不适用:那是代码内部替 Spotify 猜的补偿(界面上看不见、
        // 重置不了,后来查明它补的偏差是自然切歌锚点超前、已由 naturalAdvanceCorrection 按曲
        // 根修,于是 08-20 连值一起删了),而这版是用户在设置页自己选播放器、自己调的值,连
        // UserDefaults 键都换了。旧断言也 revert 不回来 —— 那一层从头到尾只活在工作树里、
        // 从未提交(git log -S lyricsPlayerOffsetsJSON 只命中 3090fed,而它的父提交里根本没有)。
        //
        // Arc 用真实 bundle id(它就是这个功能的动机);对照播放器用枚举而不是字面量,枚举漂了
        // 断言跟着漂。注意 **Arc 不在 PlaybackPlayer 里** —— 它靠 TrustedPlayers 那份
        // bundleID→名字映射进来,所以这层的维度只能是 bundleID,换成枚举就把动机里那个 App
        // 挡在门外了。
        let arc = "company.thebrowser.Browser"
        let appleMusic = PlaybackPlayer.appleMusic.bundleIdentifier
        store.setGlobalOffset(0)
        store.reset(forKey: key, pinKey: "", siblings: .none)

        expectEqual(store.playerOffset(forBundleID: nil), 0, "按播放器: 没有播放器身份时是 0")
        expectEqual(store.playerOffset(forBundleID: ""), 0, "按播放器: 空 bundle id 是 0")
        expectEqual(store.playerOffset(forBundleID: arc), 0, "按播放器: 没配过是 0")

        store.setPlayerOffset(800, forBundleID: arc)
        store.setGlobalOffset(100)
        store.setOffset(-50, forKey: key, pinKey: "", siblings: .none)
        // 二选一:Arc 单独配过 → 只用它那档(800),「全部」那 100 完全不参与。
        expectEqual(store.baseOffsetMs(forBundleID: arc), 800, "按播放器: 配过就只用自己那档,不加全部")
        expectEqual(store.effectiveOffset(forKey: key, bundleID: arc, siblings: .none), 750,
                    "按播放器: 生效值 = 自己那档 + 单曲(800 - 50)")
        // 最要紧的一条:绝不串台。同一首歌换个播放器,Arc 那档一点都不许漏进去 —— 没单独配过的
        // 播放器退回「全部」那档。
        expectEqual(store.baseOffsetMs(forBundleID: appleMusic), 100, "按播放器: 没配过的退回全部那档")
        expectEqual(store.effectiveOffset(forKey: key, bundleID: appleMusic, siblings: .none), 50,
                    "按播放器: 换播放器不吃别人那档(100 - 50)")
        expectEqual(store.effectiveOffset(forKey: key, siblings: .none), 50,
                    "按播放器: 省略 bundleID 时用全部那档,不猜播放器")

        // 「全部」非零时单独设成 0:存下 0、不再跟随「全部」。只有删键(设置页那颗 ×)才改回跟随。
        store.setPlayerOffset(0, forBundleID: arc)
        expectEqual(store.baseOffsetMs(forBundleID: arc), 0, "按播放器: 全部为 100 时单独设成 0 就是 0")
        expectEqual(store.playerOffsets[arc], 0, "按播放器: 单独设成 0 留在字典里(设置页照样列出、带 ×)")
        expectEqual(UserDefaults.standard.string(forKey: "np:lyricsOffsetsByPlayerJSON")?.contains("\"\(arc)\":0"), true,
                    "按播放器: 显式 0 落盘")
        store.removePlayerOffset(forBundleID: arc)
        expectEqual(store.playerOffsets[arc] == nil, true, "按播放器: 删键即撤掉单独设置")
        expectEqual(store.baseOffsetMs(forBundleID: arc), 100, "按播放器: 删键后重新跟随全部")
        expectEqual(LyricsOffsetStore.decodedPlayerOffsets("{\"a\":0,\"b\":-150}"), ["a": 0, "b": -150],
                    "按播放器: 读回落盘那份时 0 照样留着")
        expectEqual(LyricsOffsetStore.decodedPlayerOffsets("坏的"), [:], "按播放器: 读不懂就是空")

        // 负值同理:单独那档为负、全部为正,生效的只有单独那档。
        store.setGlobalOffset(300)
        store.setPlayerOffset(-200, forBundleID: arc)
        store.setOffset(-50, forKey: key, pinKey: "", siblings: .none)
        expectEqual(store.effectiveOffset(forKey: key, bundleID: arc, siblings: .none), -250,
                    "按播放器: 单独那档为负时也不叠加全部(-200 - 50)")

        store.removePlayerOffset(forBundleID: arc)
        expectEqual(store.playerOffsets[arc] == nil, true, "按播放器: 删键从字典里拿掉")

        // 落盘原文断言(照 pin 那边跨语言契约的范式):键名写错/被人"顺手"改回旧键,纯内存断言
        // 一律是绿的,而回归的表现是"用户为已修好的 bug 调出来的旧值复活、歌词反被拖慢",界面上
        // 完全看不出来。
        store.setPlayerOffset(640, forBundleID: arc)
        let playerJSON = UserDefaults.standard.string(forKey: "np:lyricsOffsetsByPlayerJSON") ?? ""
        expectEqual(playerJSON.contains(arc), true, "按播放器: 落盘在 np:lyricsOffsetsByPlayerJSON 里")
        expectEqual(playerJSON.contains("640"), true, "按播放器: 落盘的就是那个值")
        expectEqual(UserDefaults.standard.object(forKey: "np:lyricsPlayerOffsetsJSON") == nil, true,
                    "按播放器: 08-18 那个旧键始终是空的(故意不复用)")

        // 收尾:别把测试值留在 UserDefaults 里
        store.setGlobalOffset(0)
        store.reset(forKey: key, pinKey: "", siblings: .none)
        for id in store.playerOffsets.keys { store.removePlayerOffset(forBundleID: id) }
    }

    // ---- 下拉框「作用于哪个播放器」的候选集(LyricsOffsetScope)----
    //
    // 三条不变量各自只在特定用户状态下才暴露,所以必须钉:
    //  ① 「自动识别」绝不能出现 —— 它的 bundleIdentifier 是空串,存进去会被 setPlayerOffset
    //     静默丢掉(用户调了没反应、也没报错);
    //  ② **配过偏移但已经不在信任名单里**的 App 仍然要列出来 —— 否则那个非零偏移就成了看不见、
    //     改不动的隐形值(那版按播放器偏移正是这么翻的车);
    //  ③ 顺序稳定、无重复 —— 每组内部排序,不然字典遍历顺序会让下拉框每次启动乱跳。
    do {
        let arc = "company.thebrowser.Browser"
        let uninstalled = "com.example.gone"
        let builtinCount = PlaybackPlayer.allCases.filter { $0 != .auto }.count

        let plain = LyricsOffsetScope.options(trusted: [:], configured: [], nowPlaying: nil)
        expectEqual(plain.count, builtinCount, "偏移作用域: 什么都没配时就是内置那几个")
        expectEqual(plain.contains(""), false, "偏移作用域: 「自动识别」的空 bundle id 绝不入列")
        expectEqual(plain.first, PlaybackPlayer.appleMusic.bundleIdentifier,
                    "偏移作用域: 内置那组按枚举声明顺序")

        // 信任的未知播放器排在内置之后。
        let withTrusted = LyricsOffsetScope.options(trusted: [arc: "Arc"], configured: [], nowPlaying: nil)
        expectEqual(withTrusted.count, builtinCount + 1, "偏移作用域: 信任项追加在内置之后")
        expectEqual(withTrusted.last, arc, "偏移作用域: 信任项排在最后")

        // ② 已取消信任(或 App 卸了)但配过偏移 —— 必须仍然列出来。
        let orphan = LyricsOffsetScope.options(trusted: [:], configured: [uninstalled], nowPlaying: nil)
        expectEqual(orphan.contains(uninstalled), true,
                    "偏移作用域: 配过偏移的即使不在信任名单也要列(不许有隐形值)")

        // 同一个 id 三组都命中时只出现一次。
        let dedup = LyricsOffsetScope.options(trusted: [arc: "Arc"], configured: [arc], nowPlaying: arc)
        expectEqual(dedup.filter { $0 == arc }.count, 1, "偏移作用域: 同一个 id 只出现一次")

        // 内置播放器出现在信任名单里(理论上不该发生)也不许重复。
        let am = PlaybackPlayer.appleMusic.bundleIdentifier
        let dupBuiltin = LyricsOffsetScope.options(trusted: [am: "Music"], configured: [am], nowPlaying: am)
        expectEqual(dupBuiltin.count, builtinCount, "偏移作用域: 内置项不会因为别的来源再来一遍")

        // 正在放的那个既不是内置也没被信任(刚发现、还没点信任)—— 也要能选到。
        let fresh = LyricsOffsetScope.options(trusted: [:], configured: [], nowPlaying: uninstalled)
        expectEqual(fresh.last, uninstalled, "偏移作用域: 正在放的那个即使还没被信任也能选")

        // nowPlaying 传空串(拿不到身份)不该塞一个空项进去。
        let blank = LyricsOffsetScope.options(trusted: [:], configured: [], nowPlaying: "")
        expectEqual(blank.count, builtinCount, "偏移作用域: nowPlaying 为空串时不入列")

        // builtInOrder 参数(加,给设置页传 PlaybackPlayer.displayOrder 用——
        // 跟"选择播放器"图标网格同一套按系统语言排的顺序,同一批播放器在这个下拉框里不该是
        // 另一个顺序)。这里不依赖 displayOrder 本身(那是 App target 里读 AppSettings 的属性,
        // selftest 只链 LyrimuseCore,够不到),只验证参数**确实生效**:传一个跟 allCases
        // 不同的顺序,输出要跟着换,而不是内部悄悄还是按 allCases 排。
        let reordered = [PlaybackPlayer.spotify, .kaset, .reamp, .vox, .pinePlayer, .lxMusic, .amazonMusic, .kkbox, .kugou, .soda, .netease, .qqMusic, .appleMusic, .auto]
        let customOrder = LyricsOffsetScope.options(builtInOrder: reordered, trusted: [:], configured: [], nowPlaying: nil)
        expectEqual(customOrder.first, PlaybackPlayer.spotify.bundleIdentifier,
                    "偏移作用域: builtInOrder 参数生效,内置那组按传入的顺序排,不是 allCases 的声明顺序")
        expectEqual(customOrder.count, builtinCount, "偏移作用域: 换个顺序不影响内置那组的数量(.auto 仍被排除)")
    }

    // ---- 「已校准」名单:调过时间轴的歌不再被后台换歌词源 ----
    //
    // 这个名单是引擎侧 needsLyricsRescore/needsLyricsRetry 的第一道闸(见
    // lyrimuse-engine/lyricspins.go)。要守三件事:
    //  ① 校正值非零就自动钉住、归零就自动解钉 —— 没有任何"记得手动打开开关"的步骤;
    //  ② pin 的身份是**归一化 enrich key**、不含歌词内容指纹 —— 拿含指纹的 key 当身份等于
    //     "内容一换 pin 也失效",正好把这条闸要防的事情放过去;
    //  ③ 「清空全部时间轴校正」只清单曲这一层,全局基准**和按播放器那层**都不受连带。
    MainActor.assumeIsolated {
        // 先把 pin 文件重定向到临时目录:它的真实路径跟正在运行的 App 共用同一份,而下面
        // 要覆盖 clearAllTrackOffsets()(内部会 removeAll)—— 不隔离就是把用户真实的已校准
        // 名单抹掉。必须排在任何一次 LyricsPinStore.shared 访问之前。
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrimuse-selftest-pins-\(ProcessInfo.processInfo.processIdentifier).json")
        LyricsPinStore.redirectForTesting(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = LyricsOffsetStore.shared
        let pins = LyricsPinStore.shared
        let pinKey = "已校准测试歌手|已校准测试歌名|已校准测试专辑"
        let keyA = LyricsOffsetStore.trackKey(
            artist: "已校准测试歌手", title: "已校准测试歌名", lyrics: "[00:01.00]甲", lyricsYRC: "")
        let keyB = LyricsOffsetStore.trackKey(
            artist: "已校准测试歌手", title: "已校准测试歌名", lyrics: "[00:02.00]乙", lyricsYRC: "")
        expectEqual(keyA == keyB, false, "已校准: 两份不同歌词内容的 offset key 本来就不同")
        expectEqual(pins.isPinned(pinKey), false, "已校准: 起点是干净的")

        store.nudge(by: 300, forKey: keyA, pinKey: pinKey, siblings: .none)
        expectEqual(pins.isPinned(pinKey), true, "已校准: 调过偏移就自动钉住,不需要另外开开关")

        // 关键一条:同一首歌换了一份歌词内容 → 旧校正值查不到(这是既有设计,内容指纹变了),
        // 但 pin 仍然在 —— 它认的是"这首歌",不是"这一份内容"。pin 要是也跟着失效,后台就会
        // 继续换源、把用户下一次校准的成果再作废一次,这条闸等于没装。
        expectEqual(store.offset(forKey: keyB), 0, "已校准: 换内容后旧校正值查不到(既有设计)")
        expectEqual(pins.isPinned(pinKey), true, "已校准: 换歌词内容不该让 pin 失效")

        store.reset(forKey: keyA, pinKey: pinKey, siblings: .none)
        expectEqual(pins.isPinned(pinKey), false, "已校准: 偏移归零就自动解钉")

        // 空 pinKey(拿不到 enrich key)时什么都不该钉 —— 否则会长出一条谁都匹配不上的记录。
        store.nudge(by: 100, forKey: keyA, pinKey: "", siblings: .none)
        expectEqual(pins.count, 0, "已校准: 空 pinKey 不写名单")

        // 存量补钉:上一步刻意造出了「有校正值但没 pin」这个状态(等价于 pin 机制上线之前
        // 用户已经调好的那些歌)。播放到它时必须补上,否则最该保护的那批一条都不受保护。
        expectEqual(store.offset(forKey: keyA), 100, "同步: 前提——这首有非零校正值却没 pin")
        store.syncPinToOffset(forKey: keyA, pinKey: pinKey)
        expectEqual(pins.isPinned(pinKey), true, "同步: 存量非零校正值会被补上 pin")

        // 校正值是 0 的歌绝不该被补钉 —— 那样全库每首歌都会进名单、后台升级整个停摆。
        store.reset(forKey: keyA, pinKey: pinKey, siblings: .none)
        store.syncPinToOffset(forKey: keyA, pinKey: pinKey)
        expectEqual(pins.count, 0, "同步: 校正值为 0 不补钉")

        // 钉住的是自愈能力:pin 只钉不解钉的话,
        // "校正值飘回 0、pin 却一直挂着"这种状态一旦出现就永远修不好——只有靠这个函数下次
        // 播放到时主动纠正。这里绕开 set()/reset() 直接摆出那个不一致状态(模拟"内容指纹变了、
        // 旧 key 下的非零值查不到了"那种真实成因,不用关心具体怎么飘出来的,只钉死"飘出来之后
        // 下次播放能不能自愈"这一件事),断言 syncPinToOffset 能把它纠正回来。
        pins.setPinned(true, forKey: pinKey)
        expectEqual(store.offset(forKey: keyA), 0, "自愈: 前提——校正值是 0")
        expectEqual(pins.isPinned(pinKey), true, "自愈: 前提——但 pin 飘着还没解开")
        store.syncPinToOffset(forKey: keyA, pinKey: pinKey)
        expectEqual(pins.isPinned(pinKey), false, "自愈: 下次播放到就该把飘着的 pin 解开")

        // ---- 「清空全部时间轴校正」----
        store.setGlobalOffset(700)
        store.setPlayerOffset(-300, forBundleID: "company.thebrowser.Browser")
        store.setOffset(-900, forKey: keyA, pinKey: pinKey, siblings: .none)
        expectEqual(store.trackOffsetCount, 1, "清空: 计数跟着写入走")
        expectEqual(pins.isPinned(pinKey), true, "清空: 前提——这首已经钉住了")

        // 跨语言契约:这份文件由 Swift 写、由引擎(Go)读(lyricsPinsFile 的
        // `json:"version"` / `json:"pins"`)。字段名在 Swift 侧一改,Go 那边就静默读到空名单、
        // 整条闸失效而且没有任何报错 —— 所以这里对**磁盘上的原文**断言,不是对内存态。
        let onDisk = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
        expectEqual(onDisk.contains("\"version\""), true, "已校准: 落盘 JSON 带 version 字段(Go 侧靠它)")
        expectEqual(onDisk.contains("\"pins\""), true, "已校准: 落盘 JSON 带 pins 字段(Go 侧靠它)")
        expectEqual(onDisk.contains(pinKey), true, "已校准: 落盘 JSON 里就是归一化的 enrich key")

        store.clearAllTrackOffsets()
        expectEqual(store.offset(forKey: keyA), 0, "清空: 单曲校正值被清掉")
        expectEqual(store.trackOffsetCount, 0, "清空: 计数归零")
        expectEqual(pins.count, 0, "清空: pin 名单一并清掉(没有校正值就没有要保护的东西)")
        expectEqual(store.globalOffsetMs, 700, "清空: 绝不连带清掉全局基准(设备侧延迟)")
        expectEqual(store.playerOffset(forBundleID: "company.thebrowser.Browser"), -300,
                    "清空: 也绝不连带清掉按播放器那层")

        // 收尾
        store.setGlobalOffset(0)
        for id in store.playerOffsets.keys { store.removePlayerOffset(forBundleID: id) }
    }

    // ---- 单曲偏移按同一首歌读穿(18 章决策 27)----
    //
    // 自己键下没有记录才借,借的是同一份歌词指纹下的;加减从借来的值起算、写进自己的键;借着别人的值时归零要记一个 0,
    // 不然「重置」被读穿抵掉;自动钉 / 解钉只看自己的键;改字搬偏移连借来的值一起搬;校准名单记下校正值对着哪份歌词。
    MainActor.assumeIsolated {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrimuse-selftest-pins-inherit-\(ProcessInfo.processInfo.processIdentifier).json")
        LyricsPinStore.redirectForTesting(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = LyricsOffsetStore.shared
        let pins = LyricsPinStore.shared
        func fingerprint(_ key: String) -> String { String(key.split(separator: "|", omittingEmptySubsequences: false).last ?? "") }
        let lrc = "[00:01.00]读穿测试\n", other = "[00:02.00]另一份\n"
        let mine = LyricsOffsetStore.trackKey(artist: "读穿歌手", title: "读穿歌名", lyrics: lrc, lyricsYRC: "")
        let theirs = LyricsOffsetStore.trackKey(artist: "Inherit Artist", title: "Inherit Title", lyrics: lrc, lyricsYRC: "")
        let theirsOther = LyricsOffsetStore.trackKey(artist: "Inherit Artist", title: "Inherit Title", lyrics: other, lyricsYRC: "")
        let third = LyricsOffsetStore.trackKey(artist: "第三写法", title: "第三歌名", lyrics: lrc, lyricsYRC: "")
        let thirdOther = LyricsOffsetStore.trackKey(artist: "第三写法", title: "第三歌名", lyrics: other, lyricsYRC: "")
        let siblings = LyricsOffsetSiblings(names: ["Inherit Artist|Inherit Title", "第三写法|第三歌名"])
        let pinMine = "读穿歌手|读穿歌名|专辑", pinTheirs = "Inherit Artist|Inherit Title|Album", pinThird = "第三写法|第三歌名|专辑"
        store.setGlobalOffset(0)
        store.clearAllTrackOffsets()

        store.setOffset(400, forKey: theirsOther, pinKey: "", siblings: .none)
        expectEqual(store.offset(forKey: mine, siblings: siblings), 0, "读穿: 别的写法只在另一份歌词下有值,借不到")
        store.setOffset(300, forKey: theirs, pinKey: pinTheirs, siblings: .none)
        store.setOffset(-200, forKey: third, pinKey: "", siblings: .none)
        expectEqual(store.offset(forKey: mine), 0, "读穿: 自己键下没有")
        expectEqual(store.offset(forKey: mine, siblings: siblings), 300, "读穿: 按顺序借同一份歌词下第一个非零的")
        expectEqual(store.offset(forKey: mine, siblings: LyricsOffsetSiblings(names: ["第三写法|第三歌名", "Inherit Artist|Inherit Title"])),
                    -200, "读穿: 顺序在前的先借")
        expectEqual(store.effectiveOffset(forKey: mine, siblings: siblings), 300, "读穿: 生效值带上借来的")
        expectEqual(store.borrowedOffsetSource(forKey: mine, siblings: siblings), "Inherit Artist|Inherit Title", "读穿: 说得出借的是哪条")
        expectEqual(store.borrowedOffsetSource(forKey: mine, siblings: LyricsOffsetSiblings(names: ["第三写法|第三歌名", "Inherit Artist|Inherit Title"])),
                    "第三写法|第三歌名", "读穿: 借的是顺序在前的那条")
        expectEqual(store.borrowedOffsetSource(forKey: theirs, siblings: LyricsOffsetSiblings(names: ["第三写法|第三歌名"])), nil,
                    "读穿: 自己键下有值就不算借")
        expectEqual(store.borrowedOffsetSource(forKey: mine, siblings: .none), nil, "读穿: 没得借")
        expectEqual(store.effectiveOffset(forKey: mine, siblings: .none), 0, "读穿: 不给其它写法就不借")
        let noText = LyricsOffsetStore.trackKey(artist: "读穿歌手", title: "读穿歌名", lyrics: "", lyricsYRC: "")
        store.setOffset(700, forKey: "Inherit Artist|Inherit Title|", pinKey: "", siblings: .none)
        expectEqual(store.offset(forKey: noText, siblings: siblings), 0, "读穿: 还拿不到正文时不借")
        store.setOffset(0, forKey: "Inherit Artist|Inherit Title|", pinKey: "", siblings: .none)
        store.setOffset(0, forKey: third, pinKey: "", siblings: LyricsOffsetSiblings(names: ["Inherit Artist|Inherit Title"]))
        expectEqual(store.offset(forKey: mine, siblings: LyricsOffsetSiblings(names: ["第三写法|第三歌名", "Inherit Artist|Inherit Title"])),
                    300, "读穿: 别的写法为了不借记的 0 跳过,接着往后借")
        store.setOffset(-200, forKey: third, pinKey: "", siblings: .none)

        store.syncPinToOffset(forKey: mine, pinKey: pinMine)
        expectEqual(pins.isPinned(pinMine), false, "读穿: 借来的值不钉")

        expectEqual(store.nudge(by: 100, forKey: mine, pinKey: pinMine, siblings: siblings), 400, "读穿: 在借来的值上加")
        expectEqual(store.offset(forKey: mine), 400, "读穿: 加完记在自己键下")
        expectEqual(store.offset(forKey: theirs), 300, "读穿: 别的写法那条不动")
        expectEqual(pins.isPinned(pinMine), true, "读穿: 自己调过就钉上")

        store.reset(forKey: mine, pinKey: pinMine, siblings: siblings)
        expectEqual(store.offset(forKey: mine, siblings: siblings), 0, "读穿: 借着别人的值时重置,之后是 0、不再借")
        expectEqual(store.borrowedOffsetSource(forKey: mine, siblings: siblings), nil, "读穿: 为了不借记的 0 也不算借")
        expectEqual(pins.isPinned(pinMine), false, "读穿: 重置之后解钉")
        expectEqual(store.trackOffsetCount, 3, "读穿: 为了不借记的 0 不算调过")
        store.setOffset(0, forKey: theirs, pinKey: pinTheirs, siblings: .none)
        store.setOffset(0, forKey: third, pinKey: "", siblings: .none)
        store.reset(forKey: mine, pinKey: pinMine, siblings: siblings)
        store.setOffset(300, forKey: theirs, pinKey: pinTheirs, siblings: .none)
        expectEqual(store.offset(forKey: mine, siblings: siblings), 300, "读穿: 没得借时归零就是删掉,之后照常借")

        let mineNew = LyricsOffsetStore.trackKey(artist: "读穿歌手", title: "读穿歌名", lyrics: "[00:01.00]读穿测试改\n", lyricsYRC: "")
        store.carryOffset(from: mine, to: mineNew, pinKey: pinMine, siblings: siblings)
        expectEqual(store.offset(forKey: mineNew), 300, "读穿: 只改了字,借来的值记到自己新正文下")
        expectEqual(store.offset(forKey: theirs), 300, "读穿: 改字不动别的写法那条")
        expectEqual(pins.isPinned(pinMine), true, "读穿: 搬过来的值照常钉上")

        let mineRewritten = LyricsOffsetStore.trackKey(artist: "读穿歌手", title: "读穿歌名", lyrics: "[00:01.00]读穿测试改 \n", lyricsYRC: "")
        store.setOffset(0, forKey: mine, pinKey: "", siblings: siblings)
        store.syncPinToOffset(forKey: mineRewritten, pinKey: pinMine)
        expectEqual(store.offset(forKey: mineRewritten), 300, "接管: 为了不借记的 0 不算一条候选")
        expectEqual(pins.isPinned(pinMine), true, "接管: 挪过来之后照旧钉着")

        expectEqual(pins.content(forKey: pinMine), fingerprint(mineRewritten), "校准名单: 记下校正值对着的那份歌词,内容换了跟着换")
        expectEqual(pins.content(forKey: pinTheirs), fingerprint(theirs), "校准名单: 调偏移时记下")
        let onDisk = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
        expectEqual(onDisk.contains("\"content\""), true, "校准名单: 落盘带 content(引擎 lyricsPinsFile.Content 靠它)")
        store.reset(forKey: theirs, pinKey: pinTheirs, siblings: .none)
        expectEqual(pins.content(forKey: pinTheirs), nil, "校准名单: 解钉连记下的歌词一起删")

        pins.setPinned(true, forKey: pinTheirs)
        store.backfillPinContent()
        expectEqual(pins.content(forKey: pinTheirs), fingerprint(theirsOther), "补记: 这首只在一份歌词下有值,记那一份")
        store.setOffset(100, forKey: third, pinKey: "", siblings: .none)
        store.setOffset(200, forKey: thirdOther, pinKey: "", siblings: .none)
        pins.setPinned(true, forKey: pinThird)
        store.backfillPinContent()
        expectEqual(pins.content(forKey: pinThird), nil, "补记: 几份歌词下都有值时猜不出,不记")
        store.setOffset(0, forKey: theirsOther, pinKey: "", siblings: .none)
        store.setOffset(250, forKey: theirs, pinKey: "", siblings: .none)
        store.backfillPinContent()
        expectEqual(pins.content(forKey: pinTheirs), fingerprint(theirsOther), "补记: 已经记了的不改")

        store.clearAllTrackOffsets()
        let ownerSiblings = LyricsOffsetSiblings(names: ["读穿歌手|读穿歌名"])
        store.setOffset(500, forKey: theirs, pinKey: pinTheirs, siblings: ownerSiblings)
        let theirsEdited = LyricsOffsetStore.trackKey(artist: "Inherit Artist", title: "Inherit Title", lyrics: "[00:01.00]读穿测试改字\n", lyricsYRC: "")
        store.carryOffset(from: theirs, to: theirsEdited, pinKey: pinTheirs, siblings: ownerSiblings)
        expectEqual(store.offset(forKey: theirsEdited), 500, "改字: 自己调过的值搬到新正文下")
        expectEqual(store.offset(forKey: mine, siblings: siblings), 500, "改字: 别的写法还用着旧正文,照样借得到")
        let theirsRewritten = LyricsOffsetStore.trackKey(artist: "Inherit Artist", title: "Inherit Title", lyrics: "[00:01.00]读穿测试改字 \n", lyricsYRC: "")
        store.syncPinToOffset(forKey: theirsRewritten, pinKey: pinTheirs)
        expectEqual(store.offset(forKey: theirsRewritten), 500, "接管: 几份歌词下都有值时挪钉住记的那份")
        expectEqual(pins.isPinned(pinTheirs), true, "接管: 挪过来之后照旧钉着")
        let thirdEdited = LyricsOffsetStore.trackKey(artist: "第三写法", title: "第三歌名", lyrics: "[00:01.00]读穿测试改字\n", lyricsYRC: "")
        store.setOffset(-100, forKey: third, pinKey: "", siblings: .none)
        store.carryOffset(from: third, to: thirdEdited, pinKey: "", siblings: .none)
        expectEqual(store.offset(forKey: third), 0, "改字: 没有别的写法时旧正文下那条删掉")

        store.clearAllTrackOffsets()
    }

    // ---- 读穿的顺序:同一个实体的写法,手改副本的原件排最前,其余按写法键;按「歌手|歌名」去重,不列自己 ----
    do {
        func entry(_ json: String) -> EnrichCacheEntry {
            (try? JSONDecoder().decode(EnrichCacheEntry.self, from: Data(json.utf8)))
                ?? (try! JSONDecoder().decode(EnrichCacheEntry.self, from: Data("{}".utf8)))
        }
        let all: [String: EnrichCacheEntry] = [
            "a|song|x": entry(#"{"song":"s_1","lyrics_entity_origin":"c|song~dur2|z"}"#),
            "a|song|y": entry(#"{"song":"s_1"}"#),
            "b|track|y": entry(#"{"song":"s_1"}"#),
            "b|track|w": entry(#"{"song":"s_1"}"#),
            "c|song~dur2|z": entry(#"{"song":"s_1"}"#),
            "d|other|z": entry(#"{"song":"s_2"}"#),
        ]
        let own = all["a|song|x"] ?? entry("{}")
        expectEqual(EnrichCacheReader.offsetSiblings(ownKey: "a|song|x", entry: own, in: all).names, ["c|song", "b|track"],
                    "读穿顺序: 原件最前、其余按键排、按歌手歌名去重、去掉时长变体位、不列自己和别的实体")
        expectEqual(EnrichCacheReader.offsetSiblings(ownKey: "d|other|z", entry: entry("{}"), in: all), LyricsOffsetSiblings.none,
                    "读穿顺序: 没有实体 id 不读穿")
        expectEqual(LyricsOffsetSiblings.name(ofWritingKey: "歌手|歌名~dur3|专辑"), "歌手|歌名", "读穿: 写法键 → 偏移键前两段")
    }

    // ---- 读穿的接线(源码契约):播放时生效、加减、重置都带上这首的其它写法;歌词管理同样;启动时补记校准对着的歌词 ----
    do {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func read(_ rel: String) -> String { (try? String(contentsOf: sources.appendingPathComponent(rel), encoding: .utf8)) ?? "" }
        let lps = read("LyrimuseCore/Local/LocalPlaybackSource.swift")
        let manager = read("lyrimuse/LyricsManager/LyricsManagerView.swift")
        let app = read("lyrimuse/AppDelegate.swift")
        expectEqual(lps.isEmpty || manager.isEmpty || app.isEmpty, false, "读穿接线(契约): 读到源码")
        expectEqual(sourceBytes(lps, contain: "currentOffsetSiblings = EnrichCacheReader.offsetSiblings(")
                    && sourceBytes(lps, contain: "let track = LyricsOffsetStore.shared.offset(forKey: currentOffsetKey, siblings: currentOffsetSiblings)")
                    && sourceHas(lps, "radioKey: radioKey,\n            siblings: currentOffsetSiblings\n")
                    && sourceHas(lps, "pinKey: currentPinKey,\n                                           siblings: currentOffsetSiblings)")
                    && sourceBytes(lps, contain: "LyricsOffsetStore.shared.reset(forKey: currentOffsetKey, pinKey: currentPinKey, siblings: currentOffsetSiblings)"),
                    true, "读穿接线(契约): 播放时生效、加减、重置都按这首的其它写法读穿")
        expectEqual(sourceBytes(manager, contain: "offsetSiblings = EnrichCacheReader.offsetSiblings(forKey: key)")
                    && !sourceBytes(manager, contain: "siblings: .none"), true, "读穿接线(契约): 歌词管理的偏移输入框按这首的其它写法读穿")
        expectEqual(sourceBytes(app, contain: "LyricsOffsetStore.shared.backfillPinContent()"), true, "读穿接线(契约): 启动时补记校准对着的歌词")

        // 设置页播放器那一行的 × 删键改回跟随「全部播放器」,不是写 0(写 0 是单独设成不偏移)。
        let settings = read("lyrimuse/SettingsView.swift")
        let row = sourceBody("private func playerOffsetRow(", in: settings)
        expectEqual(sourceHas(row, "clearPlayerOffset(bundleID)") && !sourceHas(row, "setOffset(0, scope: bundleID)"), true,
                    "按播放器(契约): 设置页的 × 删键,不写 0")
        expectEqual(sourceHas(settings, "PlaybackCoordinator.shared.clearPlayerLyricsOffset(forBundleID: bundleID)")
                    && sourceHas(lps, "LyricsOffsetStore.shared.removePlayerOffset(forBundleID: bundleID)"), true,
                    "按播放器(契约): × 经协调器、播放源走到 removePlayerOffset")
    }

    // ---- Apple Music 放空间音频版时用歌词带的偏移 ----
    // 数据取自 Dean Lewis《Be Alright》:歌词按立体声版(196.373s)打轴,Music.app 放空间音频版时报 198.698s,
    // TTML 写着空间音频版歌词晚 1.672s。引擎口径是「正数 = 提前」,所以叠进去的是 -1672。
    do {
        typealias L = LocalPlaybackSource
        let cue = LRCParser.SpatialAudioCue(lyricOffsetMs: 1672, stereoDurationMs: 196373)
        let am = PlaybackPlayer.appleMusic.bundleIdentifier
        expectEqual(L.spatialAudioOffsetMs(cue: cue, bundleID: am, playingDuration: 198.698, isMusicVideo: false), -1672,
                    "空间音频: 时长对不上立体声版 = 在放空间音频版,歌词晚 1.672s")
        expectEqual(L.spatialAudioOffsetMs(cue: cue, bundleID: am, playingDuration: 196.373, isMusicVideo: false), 0,
                    "空间音频: 放的就是立体声版,不动")
        expectEqual(L.spatialAudioOffsetMs(cue: cue, bundleID: am, playingDuration: 196.42, isMusicVideo: false), 0,
                    "空间音频: 同一份母带的几十毫秒误差不算换了版本")
        expectEqual(L.spatialAudioOffsetMs(cue: cue, bundleID: PlaybackPlayer.spotify.bundleIdentifier,
                                           playingDuration: 198.698, isMusicVideo: false), 0,
                    "空间音频: 只认 Apple Music")
        expectEqual(L.spatialAudioOffsetMs(cue: cue, bundleID: am, playingDuration: 198.698, isMusicVideo: true), 0,
                    "空间音频: MV 走自己的时间轴")
        expectEqual(L.spatialAudioOffsetMs(cue: cue, bundleID: am, playingDuration: nil, isMusicVideo: false), 0,
                    "空间音频: 不知道在放的时长,不动")
        expectEqual(L.spatialAudioOffsetMs(cue: cue, bundleID: am, playingDuration: 3600, isMusicVideo: false), 0,
                    "空间音频: 差得太多(电台报整档节目时长)不是两版混音")
        expectEqual(L.spatialAudioOffsetMs(cue: nil, bundleID: am, playingDuration: 198.698, isMusicVideo: false), 0,
                    "空间音频: 歌词没带偏移,不动")
        let early = LRCParser.SpatialAudioCue(lyricOffsetMs: -131, stereoDurationMs: 178721)
        expectEqual(L.spatialAudioOffsetMs(cue: early, bundleID: am, playingDuration: 177.6, isMusicVideo: false), 131,
                    "空间音频: 负偏移(空间音频版歌词要早)换算成提前")

        // 在放的那一版的时长:AppleScript 报目录里立体声版的时长,系统媒体信息报在放的那一版。
        // D'Angelo《Untitled》实测:脚本 435.364、系统 430.853,歌词带 -2.697s 的空间音频偏移。
        expectEqual(L.applePlayingDuration(bundleID: am, scriptDuration: 435.364, systemDuration: 430.853), 430.853,
                    "在放时长: 系统报的跟脚本差几秒 = 在放空间音频版,取系统的")
        expectEqual(L.applePlayingDuration(bundleID: am, scriptDuration: 196.373, systemDuration: 196.4), 196.373,
                    "在放时长: 同一份母带的毫秒级差别,仍用脚本的")
        expectEqual(L.applePlayingDuration(bundleID: am, scriptDuration: 196.373, systemDuration: 3600), 196.373,
                    "在放时长: 差得太多不是两版混音,仍用脚本的")
        expectEqual(L.applePlayingDuration(bundleID: am, scriptDuration: 435.364, systemDuration: nil), 435.364,
                    "在放时长: 没有系统读数,仍用脚本的")
        expectEqual(L.applePlayingDuration(bundleID: PlaybackPlayer.spotify.bundleIdentifier, scriptDuration: 200,
                                           systemDuration: 204), 200,
                    "在放时长: 只认 Apple Music")
        let dangelo = LRCParser.SpatialAudioCue(lyricOffsetMs: -2697, stereoDurationMs: 435364)
        let playing = L.applePlayingDuration(bundleID: am, scriptDuration: 435.364, systemDuration: 430.853)
        expectEqual(L.spatialAudioOffsetMs(cue: dangelo, bundleID: am, playingDuration: playing, isMusicVideo: false), 2697,
                    "在放时长: 拿系统时长认出空间音频版,偏移生效")
        expectEqual(L.spatialAudioOffsetMs(cue: dangelo, bundleID: am, playingDuration: 435.364, isMusicVideo: false), 0,
                    "在放时长: 只拿脚本的目录时长认不出(修之前的样子)")

        // 接线(契约):两条有系统读数的读法都记下系统时长,认空间音频版和界面总时长都走 playingDuration
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func read(_ rel: String) -> String { (try? String(contentsOf: sources.appendingPathComponent(rel), encoding: .utf8)) ?? "" }
        let client = read("LyrimuseCore/Local/MediaControlClient.swift")
        let source = read("LyrimuseCore/Local/LocalPlaybackSource.swift")
        expectEqual(sourceBody("private static func adaptedSnapshot", in: client).contains("noteAppleMusicSystemDuration"),
                    true, "在放时长(契约): 自动识别 / 多选那条路记系统时长")
        expectEqual(sourceBody("private static func probeRadioStationHash", in: client).contains("noteAppleMusicSystemDuration"),
                    true, "在放时长(契约): 只选 Apple Music 那条路记系统时长")
        expectEqual(sourceBody("private func currentSpatialAudioOffsetMs", in: source).contains("playingDuration(snapshot)"),
                    true, "在放时长(契约): 认空间音频版用在放的时长")
        expectEqual(sourceBytes(source, contain: "if let d = playingDuration(snapshot), d > 0 { return Int(d * 1000) }"), true,
                    "在放时长(契约): 界面总时长用在放的时长")
    }

    // ---- 第四层:电台校正----
    // 只在放电台时生效,按「台标哈希 + 曲目」记。成因见 LyricsOffsetStore.radioOffsets 头注:
    // 电台元数据比声音晚,δ 每首不同但同一首可复现,系统里量不出来,只能靠耳朵校一次。
    do {
        typealias S = LyricsOffsetStore
        let hashA = "CgkIBRoF0aDTpxkQBA"   // 实测值:petal radio
        let hashB = "CgkIBRoF6d-JrhkQBA"   // 实测值:另一个台
        let track = S.trackKey(artist: "Ariana Grande", title: "kiss me", lyrics: "[00:01.00]a\n", lyricsYRC: "")

        // key 的三道闸。
        expectEqual(S.radioKey(stationHash: "", trackKey: track), "", "电台 key: 没有台标哈希就不适用")
        expectEqual(S.radioKey(stationHash: hashA, trackKey: ""), "", "电台 key: 没有曲目身份就不适用")
        expectEqual(S.radioKey(stationHash: hashA, trackKey: "||"), "", "电台 key: 空壳曲目 key 同样不认")
        expectEqual(S.radioKey(stationHash: "带|竖线的台", trackKey: track), "",
                    "电台 key: 台标哈希含分隔符会让四段拼法产生歧义,直接不认")
        expectEqual(S.radioKey(stationHash: hashA, trackKey: track), "\(hashA)|\(track)", "电台 key: 台在前、曲目在后")

        let store = S.shared
        let keyA = S.radioKey(stationHash: hashA, trackKey: track)
        let keyB = S.radioKey(stationHash: hashB, trackKey: track)
        store.setGlobalOffset(0)
        store.reset(forKey: track, pinKey: "", siblings: .none)
        store.clearAllRadioOffsets()
        expectEqual(store.radioOffsetCount, 0, "电台校正: 起点是空的")

        // 同一首歌、两个台,互不相干 —— 校正只适用于这个电台里播放的歌。
        store.nudgeRadio(by: 1500, forKey: keyA)
        expectEqual(store.radioOffset(forKey: keyA), 1500, "电台校正: 调进去了")
        expectEqual(store.radioOffset(forKey: keyB), 0, "电台校正: 同一首歌换个台不套用(δ 未必一样,扣错比不扣更糟)")
        expectEqual(store.radioOffsetCount, 1, "电台校正: 计数跟着走")

        // 不是电台时这一层压根不参与 —— 这是整个需求的要害:正常播放这首歌本来是准的。
        expectEqual(store.effectiveOffset(forKey: track, siblings: .none), 0,
                    "电台校正: 不传 radioKey(= 正常播放)时完全不生效")
        expectEqual(store.effectiveOffset(forKey: track, bundleID: nil, radioKey: keyA, siblings: .none), 1500,
                    "电台校正: 放电台时才加进来")

        // 跟另外两层是相加,不是二选一(两者成因不同,同一首歌可能两样都占)。
        store.setGlobalOffset(300)
        store.nudge(by: -100, forKey: track, pinKey: "", siblings: .none)
        expectEqual(store.effectiveOffset(forKey: track, bundleID: nil, radioKey: keyA, siblings: .none), 300 - 100 + 1500,
                    "电台校正: 全局 + 单曲 + 电台三层相加")
        expectEqual(store.effectiveOffset(forKey: track, siblings: .none), 300 - 100,
                    "电台校正: 同一首歌正常播放时仍然只有前两层")

        // 归零不落盘,跟另外两层同一个约定。
        store.setRadioOffset(0, forKey: keyA)
        expectEqual(store.radioOffsetCount, 0, "电台校正: 归零 = 撤掉这条记录,不是留一个 0")

        // 清空只清自己这一层。
        store.nudgeRadio(by: 800, forKey: keyA)
        store.clearAllRadioOffsets()
        expectEqual(store.radioOffset(forKey: keyA), 0, "电台校正: 清空生效")
        expectEqual(store.globalOffsetMs, 300, "电台校正: 绝不连带清掉全局基准")
        expectEqual(store.offset(forKey: track), -100, "电台校正: 也绝不连带清掉单曲那层")

        // 收尾
        store.setGlobalOffset(0)
        store.reset(forKey: track, pinKey: "", siblings: .none)
    }
}
