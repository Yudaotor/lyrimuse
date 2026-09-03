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

    // ---- LyricsOffsetStore.trackKey:歌手/歌名必须归一化(2026-08-20 修的真 bug) ----
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
    }

    // MARK: - 歌词时间轴偏移:基准(全部 / 按播放器,二选一)+ 单曲微调
    //
    // 2026-08-17 加全局偏移时补的,2026-08-21 补上「按播放器」那层。
    //
    // ⚠️ 播放器那层跟「全部」是**二选一、不相加**(2026-08-21 用户拍板改的语义:「不要和那个全部
    // 相加,只有要么全部,要么单个」)。零值不落盘,所以"配过"="非零",调回 0 就是撤掉单独设置、
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
        store.reset(forKey: key, pinKey: "")
        for id in store.playerOffsets.keys { store.setPlayerOffset(0, forBundleID: id) }
        expectEqual(store.effectiveOffset(forKey: key), 0, "偏移: 各层都没调时是 0")

        store.setGlobalOffset(300)
        expectEqual(store.effectiveOffset(forKey: key), 300, "偏移: 只有全局基准时按它算")

        store.nudge(by: -100, forKey: key, pinKey: "")
        expectEqual(store.offset(forKey: key), -100, "偏移: 单曲微调独立记账")
        expectEqual(store.effectiveOffset(forKey: key), 200, "偏移: 生效值 = 全局 + 单曲")

        store.reset(forKey: key, pinKey: "")
        expectEqual(store.offset(forKey: key), 0, "偏移: 重置清掉单曲微调")
        expectEqual(store.globalOffsetMs, 300, "偏移: 重置不动全局基准")
        expectEqual(store.effectiveOffset(forKey: key), 300, "偏移: 重置后回到全局基准")

        store.setOffset(-250, forKey: key, pinKey: "")
        store.setGlobalOffset(-50)
        expectEqual(store.offset(forKey: key), -250, "偏移: 改全局基准不动单曲微调")
        expectEqual(store.effectiveOffset(forKey: key), -300, "偏移: 两个负值相加")

        // 空 key(从没拿到过曲目信息)不该被当成一首歌记账 —— 但全局基准跟曲目无关,照样生效
        store.setGlobalOffset(120)
        store.nudge(by: 500, forKey: "||", pinKey: "")
        expectEqual(store.offset(forKey: "||"), 0, "偏移: 空 key 不记账")
        expectEqual(store.effectiveOffset(forKey: "||"), 120, "偏移: 空 key 下全局基准仍然生效")

        // ---- 「按播放器」那一层(2026-08-21)----
        //
        // 2026-08-18 那版同名层的断言不适用:那是代码内部替 Spotify 猜的补偿(界面上看不见、
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
        store.reset(forKey: key, pinKey: "")

        expectEqual(store.playerOffset(forBundleID: nil), 0, "按播放器: 没有播放器身份时是 0")
        expectEqual(store.playerOffset(forBundleID: ""), 0, "按播放器: 空 bundle id 是 0")
        expectEqual(store.playerOffset(forBundleID: arc), 0, "按播放器: 没配过是 0")

        store.setPlayerOffset(800, forBundleID: arc)
        store.setGlobalOffset(100)
        store.setOffset(-50, forKey: key, pinKey: "")
        // 二选一:Arc 单独配过 → 只用它那档(800),「全部」那 100 完全不参与。
        expectEqual(store.baseOffsetMs(forBundleID: arc), 800, "按播放器: 配过就只用自己那档,不加全部")
        expectEqual(store.effectiveOffset(forKey: key, bundleID: arc), 750,
                    "按播放器: 生效值 = 自己那档 + 单曲(800 - 50)")
        // 最要紧的一条:绝不串台。同一首歌换个播放器,Arc 那档一点都不许漏进去 —— 没单独配过的
        // 播放器退回「全部」那档。
        expectEqual(store.baseOffsetMs(forBundleID: appleMusic), 100, "按播放器: 没配过的退回全部那档")
        expectEqual(store.effectiveOffset(forKey: key, bundleID: appleMusic), 50,
                    "按播放器: 换播放器不吃别人那档(100 - 50)")
        expectEqual(store.effectiveOffset(forKey: key), 50,
                    "按播放器: 省略 bundleID 时用全部那档,不猜播放器")

        // 把单独那档调回 0 = 撤掉单独设置,重新跟随「全部」(零值不落盘,两件事是同一件)。
        store.setPlayerOffset(0, forBundleID: arc)
        expectEqual(store.baseOffsetMs(forBundleID: arc), 100, "按播放器: 调回 0 就重新跟随全部")

        // 负值同理:单独那档为负、全部为正,生效的只有单独那档。
        store.setGlobalOffset(300)
        store.setPlayerOffset(-200, forBundleID: arc)
        store.setOffset(-50, forKey: key, pinKey: "")
        expectEqual(store.effectiveOffset(forKey: key, bundleID: arc), -250,
                    "按播放器: 单独那档为负时也不叠加全部(-200 - 50)")

        // 零值不落盘 —— 设置页那个下拉框靠"字典里有谁"来列"配过的播放器",留一个 0 进去就会
        // 多列一项;归零也是用户"我不要这档了"的唯一表达方式。
        store.setPlayerOffset(0, forBundleID: arc)
        expectEqual(store.playerOffsets[arc] == nil, true, "按播放器: 归零即从字典里删掉")

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
        store.reset(forKey: key, pinKey: "")
        for id in store.playerOffsets.keys { store.setPlayerOffset(0, forBundleID: id) }
    }

    // ---- 下拉框「作用于哪个播放器」的候选集(LyricsOffsetScope,2026-08-21)----
    //
    // 三条不变量各自只在特定用户状态下才暴露,所以必须钉:
    //  ① 「自动识别」绝不能出现 —— 它的 bundleIdentifier 是空串,存进去会被 setPlayerOffset
    //     静默丢掉(用户调了没反应、也没报错);
    //  ② **配过偏移但已经不在信任名单里**的 App 仍然要列出来 —— 否则那个非零偏移就成了看不见、
    //     改不动的隐形值(2026-08-18 那版按播放器偏移正是这么翻的车);
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

        // builtInOrder 参数(2026-08-25 加,给设置页传 PlaybackPlayer.displayOrder 用——
        // 跟"选择播放器"图标网格同一套按系统语言排的顺序,同一批播放器在这个下拉框里不该是
        // 另一个顺序)。这里不依赖 displayOrder 本身(那是 App target 里读 AppSettings 的属性,
        // selftest 只链 LyrimuseCore,够不到),只验证参数**确实生效**:传一个跟 allCases
        // 不同的顺序,输出要跟着换,而不是内部悄悄还是按 allCases 排。
        let reordered = [PlaybackPlayer.spotify, .kugou, .netease, .qqMusic, .appleMusic, .auto]
        let customOrder = LyricsOffsetScope.options(builtInOrder: reordered, trusted: [:], configured: [], nowPlaying: nil)
        expectEqual(customOrder.first, PlaybackPlayer.spotify.bundleIdentifier,
                    "偏移作用域: builtInOrder 参数生效,内置那组按传入的顺序排,不是 allCases 的声明顺序")
        expectEqual(customOrder.count, builtinCount, "偏移作用域: 换个顺序不影响内置那组的数量(.auto 仍被排除)")
    }

    // ---- 「已校准」名单:调过时间轴的歌不再被后台换歌词源(2026-08-20) ----
    //
    // 这个名单是 collector 侧 needsLyricsRescore/needsLyricsRetry 的第一道闸(见
    // collector/lyricspins.go)。要守三件事:
    //  ① 校正值非零就自动钉住、归零就自动解钉 —— 没有任何"记得手动打开开关"的步骤;
    //  ② pin 的身份是**归一化 enrich key**、不含歌词内容指纹 —— 拿含指纹的 key 当身份等于
    //     "内容一换 pin 也失效",正好把这条闸要防的事情放过去;
    //  ③ 「清空全部时间轴校正」只清单曲这一层,全局基准**和按播放器那层**都不受连带。
    MainActor.assumeIsolated {
        // ⚠️ 先把 pin 文件重定向到临时目录:它的真实路径跟正在运行的 App 共用同一份,而下面
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

        store.nudge(by: 300, forKey: keyA, pinKey: pinKey)
        expectEqual(pins.isPinned(pinKey), true, "已校准: 调过偏移就自动钉住,不需要另外开开关")

        // 关键一条:同一首歌换了一份歌词内容 → 旧校正值查不到(这是既有设计,内容指纹变了),
        // 但 pin 仍然在 —— 它认的是"这首歌",不是"这一份内容"。pin 要是也跟着失效,后台就会
        // 继续换源、把用户下一次校准的成果再作废一次,这条闸等于没装。
        expectEqual(store.offset(forKey: keyB), 0, "已校准: 换内容后旧校正值查不到(既有设计)")
        expectEqual(pins.isPinned(pinKey), true, "已校准: 换歌词内容不该让 pin 失效")

        store.reset(forKey: keyA, pinKey: pinKey)
        expectEqual(pins.isPinned(pinKey), false, "已校准: 偏移归零就自动解钉")

        // 空 pinKey(拿不到 enrich key)时什么都不该钉 —— 否则会长出一条谁都匹配不上的记录。
        store.nudge(by: 100, forKey: keyA, pinKey: "")
        expectEqual(pins.count, 0, "已校准: 空 pinKey 不写名单")

        // 存量补钉:上一步刻意造出了「有校正值但没 pin」这个状态(等价于 pin 机制上线之前
        // 用户已经调好的那些歌)。播放到它时必须补上,否则最该保护的那批一条都不受保护。
        expectEqual(store.offset(forKey: keyA), 100, "同步: 前提——这首有非零校正值却没 pin")
        store.syncPinToOffset(forKey: keyA, pinKey: pinKey)
        expectEqual(pins.isPinned(pinKey), true, "同步: 存量非零校正值会被补上 pin")

        // 校正值是 0 的歌绝不该被补钉 —— 那样全库每首歌都会进名单、后台升级整个停摆。
        store.reset(forKey: keyA, pinKey: pinKey)
        store.syncPinToOffset(forKey: keyA, pinKey: pinKey)
        expectEqual(pins.count, 0, "同步: 校正值为 0 不补钉")

        // 2026-08-26 真实bug复现:pin 曾经只会钉、不会解钉(原名 backfillPinIfNeeded),导致
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
        store.setOffset(-900, forKey: keyA, pinKey: pinKey)
        expectEqual(store.trackOffsetCount, 1, "清空: 计数跟着写入走")
        expectEqual(pins.isPinned(pinKey), true, "清空: 前提——这首已经钉住了")

        // 跨语言契约:这份文件由 Swift 写、由 collector(Go)读(lyricsPinsFile 的
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
        for id in store.playerOffsets.keys { store.setPlayerOffset(0, forBundleID: id) }
    }
}
