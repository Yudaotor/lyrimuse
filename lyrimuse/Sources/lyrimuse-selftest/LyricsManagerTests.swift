import LyrimuseCore
import Foundation

// 歌词管理:列宽 / 写回合并 / 备份归档 / 重匹配 / 锁定 / 排序。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runLyricsManagerTests() {
    // ---- LyricsColumnWidths: 「歌词管理」可拖拽列宽的夹值逻辑(2026-08-05) ----
    //
    // 三条分隔条语义不对称:第 0 条(歌名|歌手)左边是弹性的歌名列,只能改「歌手」、由歌名被动
    // 吸收;第 1/2 条是标准的"此消彼长、总宽不变"。夹值要同时守住三件事:每列不低于自己的下限、
    // 歌名不低于 minTitle、单列不超过 maxColumn。

    do {
        let W = LyricsColumnWidths.self
        let d = W.defaults
        // 一组够宽、好心算的输入。(调用方现在传的是"行内容宽度 + 三个列间距",chrome = 24;
        // 这里取 48 只是为了让下面几条上下限的算术好对,纯函数对 chrome 取值没有假设。)
        let total: CGFloat = 630, chrome: CGFloat = 48

        // 第 0 条:边界右移 = 歌名变宽 → 歌手变窄(减号方向不能搞反)
        expectEqual(
            W.dragged(from: d, divider: 0, dx: 20, totalWidth: total, chrome: chrome).artist,
            d.artist - 20, "列宽: 拖第0条向右 → 歌手变窄(歌名吸收)"
        )
        expectEqual(
            W.dragged(from: d, divider: 0, dx: -20, totalWidth: total, chrome: chrome).artist,
            d.artist + 20, "列宽: 拖第0条向左 → 歌手变宽"
        )
        // 第 0 条只动歌手,不该碰专辑/来源
        do {
            let r = W.dragged(from: d, divider: 0, dx: 30, totalWidth: total, chrome: chrome)
            expectEqual(r.album, d.album, "列宽: 拖第0条不影响专辑")
            expectEqual(r.source, d.source, "列宽: 拖第0条不影响来源")
        }
        // 下限:再怎么拖也不低于 minColumn
        expectEqual(
            W.dragged(from: d, divider: 0, dx: 9999, totalWidth: total, chrome: chrome).artist,
            W.minColumn, "列宽: 第0条拖到底停在列下限"
        )
        // 上限:歌名必须留住 minTitle —— 630-48-140-110-84 = 248,但单列上限 280 更宽松,取 248
        expectEqual(
            W.dragged(from: d, divider: 0, dx: -9999, totalWidth: total, chrome: chrome).artist,
            total - chrome - W.minTitle - d.album - d.source, "列宽: 第0条反向拖到底时歌名仍保住 minTitle"
        )
        // 可用宽度很小时上下限打角:结果必须仍 >= minColumn(不能返回比下限还小的值)
        expectEqual(
            W.dragged(from: d, divider: 0, dx: -9999, totalWidth: 200, chrome: chrome).artist >= W.minColumn,
            true, "列宽: 可用宽度过小时不返回小于下限的值"
        )
        // 还没量到可用宽度(totalWidth = 0,首帧或列表一行都没有)时仍然要拖得动:照常算
        // room 会得到负数,clamp 里 hi < lo 直接返回下限,表现成"一拖歌手就弹到最窄"
        expectEqual(
            W.dragged(from: d, divider: 0, dx: -20, totalWidth: 0, chrome: chrome).artist,
            d.artist + 20, "列宽: 尚未量到宽度时第0条仍按位移变宽"
        )
    }

    do {
        let W = LyricsColumnWidths.self
        let d = W.defaults
        let total: CGFloat = 630, chrome: CGFloat = 48

        // 第 1 条(歌手|专辑):此消彼长,两列之和不变 → 歌名宽度完全不受影响
        do {
            let r = W.dragged(from: d, divider: 1, dx: 25, totalWidth: total, chrome: chrome)
            expectEqual(r.artist, d.artist + 25, "列宽: 拖第1条向右 → 歌手变宽")
            expectEqual(r.album, d.album - 25, "列宽: 拖第1条向右 → 专辑同量变窄")
            expectEqual(r.artist + r.album, d.artist + d.album, "列宽: 第1条保持两列总宽不变(歌名不受影响)")
            expectEqual(r.source, d.source, "列宽: 拖第1条不影响来源")
        }
        // 第 1 条拖到底:专辑落到下限,总宽仍不变
        do {
            let r = W.dragged(from: d, divider: 1, dx: 9999, totalWidth: total, chrome: chrome)
            expectEqual(r.album, W.minColumn, "列宽: 第1条拖到底时专辑停在下限")
            expectEqual(r.artist + r.album, d.artist + d.album, "列宽: 第1条拖到底仍保持总宽不变")
        }
        // 第 2 条(专辑|来源):来源列有更高的下限(要放得下胶囊徽章)
        do {
            let r = W.dragged(from: d, divider: 2, dx: 9999, totalWidth: total, chrome: chrome)
            expectEqual(r.source, W.minSourceColumn, "列宽: 第2条拖到底时来源停在它专属的更高下限")
            expectEqual(r.album + r.source, d.album + d.source, "列宽: 第2条拖到底仍保持总宽不变")
        }
    }

    do {
        let W = LyricsColumnWidths.self
        let chrome: CGFloat = 48
        // fitted:窗口够宽时原样返回,不动用户存下来的值
        expectEqual(W.fitted(W.defaults, totalWidth: 900, chrome: chrome), W.defaults, "列宽: 窗口够宽时 fitted 原样返回")
        // headerWidth 还没量到(0)时也原样返回,首帧不会算出奇怪的宽度
        expectEqual(W.fitted(W.defaults, totalWidth: 0, chrome: chrome), W.defaults, "列宽: 尚未量到宽度时 fitted 不做收敛")
        // 三列都拖得很宽之后把窗口拖窄:必须等比收敛到"歌名刚好还有 minTitle"
        do {
            let wide = LyricsColumnWidths(artist: 240, album: 240, source: 200)
            let r = W.fitted(wide, totalWidth: 600, chrome: chrome)
            expectEqual(r.total <= 600 - chrome - W.minTitle + 0.001, true, "列宽: 变窄后收敛到歌名保住 minTitle")
            expectEqual(r.artist >= W.minColumn && r.album >= W.minColumn && r.source >= W.minSourceColumn,
                        true, "列宽: 收敛后每列仍不低于各自下限")
        }
        // 极窄到连三列下限都塞不下 → 全部回落下限(宁可挤窄歌名,也不让某列消失)
        do {
            let r = W.fitted(W.defaults, totalWidth: 240, chrome: chrome)
            expectEqual(r, LyricsColumnWidths(artist: W.minColumn, album: W.minColumn, source: W.minSourceColumn),
                        "列宽: 极窄时全部回落到各列下限")
        }
    }

    // 「列宽拖不动」的回归(2026-08-14)。
    //
    // 现场:侧栏实际渲染宽度约 725pt、行内容占 [11.5, 725],UserDefaults 里存的是
    // 56 / 137.66796875 / 70,而截图逐像素量出来专辑列只有 56 —— 三列被恒定钳在各自下限,
    // 往哪个方向拖都纹丝不动(拖动其实写进去了,只是渲染这一步把它抹平成同一组常量)。
    //
    // 根因不在这几个纯函数里,而在调用方喂进来的宽度:当时 totalWidth 取自另一个 @State
    // (表头 .background 里 GeometryReader + onChange 量的 headerWidth),它停在首帧的窄值
    // ≤218pt 再没更新过。现在只剩 rowContentBounds 一个几何输入(走 PreferenceKey,布局
    // 每跑一遍都重报)。下面两条把"同一份数据、两种宽度"的结果各自钉死,免得以后再冒出
    // 第二个测量、又悄悄退回这个状态。
    do {
        let W = LyricsColumnWidths.self
        let stored = LyricsColumnWidths(artist: 56, album: 137.66796875, source: 70)
        let floors = LyricsColumnWidths(artist: W.minColumn, album: W.minColumn, source: W.minSourceColumn)

        // 修好之后:宽度取自行内容边界(725 - 11.5 ≈ 713),chrome 只剩三个 8pt 列间距
        expectEqual(W.fitted(stored, totalWidth: 713, chrome: 8 * 3), stored,
                    "列宽: 按行内容宽度算时,存下来的列宽原样渲染")
        // 出问题时:宽度停在首帧的 218pt,budget 掉到三列下限之和以下 → 恒定输出下限,
        // 存进去的值完全影响不了画面,也就是用户看到的"拖不动"
        expectEqual(W.fitted(stored, totalWidth: 218, chrome: 36), floors,
                    "列宽: 宽度测量失效时会被钳成常量(记录当时的错误现象)")
    }

    do {
        let W = LyricsColumnWidths.self
        // sanitized:挡住手改 UserDefaults / 老版本残留写进来的非法值,整组退回默认
        expectEqual(W.sanitized(W.defaults), W.defaults, "列宽: 合法值原样通过")
        expectEqual(W.sanitized(LyricsColumnWidths(artist: 0, album: 110, source: 84)), W.defaults, "列宽: 0 宽度整组退回默认")
        expectEqual(W.sanitized(LyricsColumnWidths(artist: -50, album: 110, source: 84)), W.defaults, "列宽: 负宽度整组退回默认")
        expectEqual(W.sanitized(LyricsColumnWidths(artist: 5000, album: 110, source: 84)), W.defaults, "列宽: 超过单列上限整组退回默认")
        expectEqual(W.sanitized(LyricsColumnWidths(artist: .nan, album: 110, source: 84)), W.defaults, "列宽: NaN 整组退回默认")
        expectEqual(W.sanitized(LyricsColumnWidths(artist: .infinity, album: 110, source: 84)), W.defaults, "列宽: 无穷大整组退回默认")
        // 来源列卡在普通下限与它专属下限之间(56~70)也算非法 —— 徽章会被截断
        expectEqual(W.sanitized(LyricsColumnWidths(artist: 96, album: 110, source: 60)), W.defaults, "列宽: 来源列低于专属下限整组退回默认")
    }

    // ---- EnrichCacheMerge: 「歌词管理」写回缓存的合并规则(2026-08-14) ----
    //
    // 守的是一条**静默丢数据**的路径。「歌词管理」可以一直开着边听边整理,而 collector 在这期间
    // 会往同一个文件写:新歌是新增 key,给已有歌补机翻译文/逐字/封面则是原地更新。窗口里的内存
    // 快照只在开窗和点「刷新」时刷新,所以早先那种"整份覆盖写"会把这期间 collector 写的东西全
    // 回滚掉。用户看到的第一个症状是"这首歌明明有翻译,列表里却没有译文标记" —— 那还只是显示层,
    // 底下是真的在丢。
    do {
        let base: [String: [String: Any]] = ["A|a|x": ["lyrics": "L"]]

        // ① 最要命的那一条:盘上的已有 key 被 collector 补了译文,而用户这次动的是**别的** key。
        //    那份译文必须活下来。
        let disk: [String: [String: Any]] = [
            "A|a|x": ["lyrics": "L", "lyrics_tr": "译文"],   // collector 刚补上的
            "B|b|y": ["lyrics": "N"],                        // collector 刚新增的一首
        ]
        var memory = base
        memory["C|c|z"] = ["lyrics": "C"]                    // 用户新采纳的一首
        let merged = EnrichCacheMerge.merge(
            disk: disk, memory: memory, edited: ["C|c|z"], deleted: [])
        expectEqual(merged["A|a|x"]?["lyrics_tr"] as? String, "译文",
                    "EnrichCacheMerge: 用户没碰的 key,盘上新补的译文不能被回滚")
        expectEqual(merged["B|b|y"] != nil, true,
                    "EnrichCacheMerge: 窗口开着期间 collector 新增的歌不能被抹掉")
        expectEqual(merged["C|c|z"]?["lyrics"] as? String, "C",
                    "EnrichCacheMerge: 用户新采纳的内容要写进去")

        // ② 用户编辑过的 key:以内存为准,盘上的旧值必须被盖掉(否则用户的修改看着像没保存)。
        let edited = EnrichCacheMerge.merge(
            disk: ["A|a|x": ["lyrics": "盘上旧的"]],
            memory: ["A|a|x": ["lyrics": "用户改的"]],
            edited: ["A|a|x"], deleted: [])
        expectEqual(edited["A|a|x"]?["lyrics"] as? String, "用户改的",
                    "EnrichCacheMerge: 用户编辑过的 key 以内存为准")

        // ③ 用户删掉的 key:即便盘上还在也要删 —— 这正是"删除"的意思,也是 collector 会在
        //    背后把它写回来的场景(它内存里还持有旧缓存)。
        let deleted = EnrichCacheMerge.merge(
            disk: ["A|a|x": ["lyrics": "L"]], memory: [:],
            edited: [], deleted: ["A|a|x"])
        expectEqual(deleted["A|a|x"] == nil, true,
                    "EnrichCacheMerge: 用户删掉的 key 不能被盘上的版本复活")

        // ④ 先编辑、后删除同一个 key:删除赢。edited 里还留着它但内存里已经没有了。
        let editThenDelete = EnrichCacheMerge.merge(
            disk: ["A|a|x": ["lyrics": "L"]], memory: [:],
            edited: ["A|a|x"], deleted: ["A|a|x"])
        expectEqual(editThenDelete["A|a|x"] == nil, true,
                    "EnrichCacheMerge: 编辑后又删除,结果是删除")
    }

    // ---- 歌词库备份归档(LyricsBackupArchive,2026-08-21)----
    //
    // 这一组里最要紧的是**文件名安全**:归档是一份外来文件(别人的机器、或被人手改过),而恢复
    // 就是拿里面的名字去拼路径写文件。不挡住的话 "../../../.ssh/authorized_keys" 这种名字会把
    // 内容写到歌词目录外面去。这类洞在单元测试里几秒钟就能钉住,靠肉眼 review 极容易放过。
    do {
        typealias A = LyricsBackupArchive

        // sidecar 命名:同名同时间戳,只把 -Config- 换成 -Lyrics-。
        expectEqual(A.sidecarName(forConfigName: "Lyrimuse-Config-2026-08-21-181500.json"),
                    "Lyrimuse-Lyrics-2026-08-21-181500.json.z",
                    "歌词备份: sidecar 跟配置包同名同时间戳")
        // 用户在保存面板里改过名字(认不出规律)也要给出一个确定的名字,不能返回空。
        expectEqual(A.sidecarName(forConfigName: "我的备份.json").hasSuffix(".json.z"), true,
                    "歌词备份: 认不出命名规律时也给一个确定的 sidecar 名")

        // ---- 文件名安全 ----
        expectEqual(A.sanitizedFileName("周杰伦 - 枫 - 十一月的萧邦.lrc") != nil, true,
                    "歌词备份: 正常歌词文件名放行")
        expectEqual(A.sanitizedFileName("x.tr.lrc") != nil, true, "歌词备份: 译文后缀放行")
        expectEqual(A.sanitizedFileName("x.roma.lrc") != nil, true, "歌词备份: 罗马音后缀放行")
        expectEqual(A.sanitizedFileName("x.yrc") != nil, true, "歌词备份: 逐字后缀放行")
        // 目录穿越:三种形态都必须挡住。
        expectEqual(A.sanitizedFileName("../../.ssh/authorized_keys.lrc"), nil,
                    "歌词备份: 带 ../ 的名字一律拒收")
        expectEqual(A.sanitizedFileName("sub/dir/x.lrc"), nil, "歌词备份: 带路径分隔符的拒收")
        // 名字里含 `..` **不再**拒收 —— 2026-08-21 实测:专辑名以句点结尾(陶喆《I'm O.K.》、
        // Wale《everything is a lot.》)导出的文件名天然长这样,那一版规则把它们**静默**踢出
        // 备份,一次漏掉 23 个文件而界面上什么都看不到。`..` 只有作为完整路径分量才危险,而带
        // 分隔符的名字上面那条已经拒了。
        expectEqual(A.sanitizedFileName("陶喆 - 天天 - I'm O.K..yrc") != nil, true,
                    "歌词备份: 专辑名以句点结尾的文件名必须放行(实测漏备份 23 个)")
        expectEqual(A.sanitizedFileName("Wale - Watching Us - everything is a lot..lrc") != nil, true,
                    "歌词备份: 同上,英文专辑名以句点结尾")
        expectEqual(A.sanitizedFileName("a..b.lrc") != nil, true, "歌词备份: 中间含 .. 的普通名字放行")
        // 但 `..` 作为完整分量、或以点开头的,照旧拒收。
        expectEqual(A.sanitizedFileName("..lrc"), nil, "歌词备份: 以点开头的照旧拒收")
        expectEqual(A.sanitizedFileName("\\tmp\\x.lrc"), nil, "歌词备份: 反斜杠也算路径分隔符")
        expectEqual(A.sanitizedFileName(".hidden.lrc"), nil, "歌词备份: 隐藏文件拒收")
        // 后缀白名单:歌词备份里不该有别的东西。
        expectEqual(A.sanitizedFileName("payload.sh"), nil, "歌词备份: 非歌词后缀拒收")
        expectEqual(A.sanitizedFileName("x.lrc.sh"), nil, "歌词备份: 后缀要在结尾,不能只是出现过")
        expectEqual(A.sanitizedFileName(""), nil, "歌词备份: 空名字拒收")
        // 单个文件名的文件系统上限,超了写入本来就会失败,提前挡掉。
        expectEqual(A.sanitizedFileName(String(repeating: "a", count: 260) + ".lrc"), nil,
                    "歌词备份: 超长名字拒收")

        // ---- 恢复的账 ----
        let plan = A.plan(incoming: ["a.lrc", "b.yrc", "../evil.lrc", "c.lrc"],
                          existing: ["a.lrc", "z.lrc"])
        expectEqual(plan.added, ["b.yrc", "c.lrc"], "歌词备份: 目标目录没有的算新增")
        expectEqual(plan.overwritten, ["a.lrc"], "歌词备份: 已存在的算覆盖(恢复就是要盖)")
        expectEqual(plan.rejected, ["../evil.lrc"], "歌词备份: 不安全的名字进拒收账")
        // 目标目录里本来就有、而归档里没有的(z.lrc)一个都不许动 —— 恢复只写不删。
        expectEqual(plan.added.contains("z.lrc") || plan.overwritten.contains("z.lrc"), false,
                    "歌词备份: 归档里没有的本机文件不受影响(只写不删)")
        // 顺序稳定:同一份归档两次恢复的账要一样(字典遍历顺序不稳,plan 内部排过序)。
        let again = A.plan(incoming: ["c.lrc", "../evil.lrc", "b.yrc", "a.lrc"],
                           existing: ["a.lrc", "z.lrc"])
        expectEqual(again, plan, "歌词备份: 输入顺序不影响结果")

        // ---- 磁盘格式契约 ----
        //
        // 字段名一改,旧机器导出的包在新版本上就解不出来 —— 而且是**静默**的:decode 失败只表现为
        // "这份备份不带歌词",用户不会收到任何报错,几千首歌的歌词和校正值就这么没跟过来。所以这里
        // 对**压缩后再解出来的 JSON 原文**断言字段名(照 pins 文件那条跨语言契约断言的范式)。
        let payload = A.Payload(at: "2026-08-21T10:00:00Z", device: "Mac",
                                files: ["周杰伦 - 枫.lrc": "[00:01.00]枫"],
                                pins: ["周杰伦|枫|十一月的萧邦": 1787296579])
        guard let archived = A.encode(payload) else {
            expectEqual(true, false, "歌词备份: encode 不该失败")
            exit(1)
        }
        // 压缩过的:zlib 头是 0x78,而明文 JSON 第一个字节是 '{'。
        expectEqual(archived.first != UInt8(ascii: "{"), true, "歌词备份: 归档是压缩过的")
        let plain = String(data: (try! (archived as NSData).decompressed(using: .zlib)) as Data,
                           encoding: .utf8) ?? ""
        for field in ["\"v\"", "\"at\"", "\"device\"", "\"files\"", "\"pins\""] {
            expectEqual(plain.contains(field), true, "歌词备份: 落盘 JSON 带 \(field) 字段")
        }
        // 往返不丢内容(尤其歌词正文里的换行和头部标签)。
        expectEqual(A.decode(archived), payload, "歌词备份: 压缩往返内容不变")
        // 明文 JSON 也要认 —— 手改过的包、或将来改成不压缩,都还能读出来。
        let raw = try! JSONEncoder().encode(payload)
        expectEqual(A.decode(raw), payload, "歌词备份: 未压缩的归档同样能读")
        // 完全不是归档的数据不能崩,返回 nil。
        expectEqual(A.decode(Data("not an archive".utf8)) == nil, true, "歌词备份: 垃圾数据返回 nil")

        // ---- enrich 缓存的非歌词字段(meta,2026-09-02)----
        //
        // 用户实测撞上的那个 bug:「在另外电脑导入了配置,但是并没有把歌曲的决策解析给带过来」。
        // 根因是这份 sidecar 此前只带 `lyrics/` 文件族(六个歌词字段),而决策存档
        // (lyrics_decision)、手点「采纳为静态文本」(plain_lyrics)、手动选定凭据
        // (manual_pick_sha)、打分版本(lyrics_scoring_version)全在 enrich 缓存里、不在任何备份里。
        // 见 LyricsBackupArchive 头注。

        // 这六个名字必须跟 collector 侧 enrichEntry 的 json tag 一字不差。对不上的失效方式是
        // **静默**的:多带的字段会在恢复时盖掉刚从文件导进去的正文,少带的永远不会被搬走。
        expectEqual(A.lyricFieldKeys,
                    ["lyrics", "lyrics_tr", "lyrics_roma", "lyrics_yrc", "lyrics_source", "manual_lyrics"],
                    "歌词备份 meta: 剥掉的六个字段名跟 collector 的 json tag 对齐")

        // 剥离:六个歌词字段一个不留,其余原样保留(含嵌套对象)。
        let cacheJSON = """
        {
          "周杰伦|枫|十一月的萧邦": {
            "lyrics": "[00:01.00]正文", "lyrics_tr": "译文", "lyrics_roma": "罗马音",
            "lyrics_yrc": "逐字", "lyrics_source": "netease", "manual_lyrics": true,
            "lyrics_decision": {"winner": "netease", "path": "rescore"},
            "lyrics_scoring_version": 9, "canonical_artist": "周杰伦", "plain_lyrics": "纯文本"
          },
          "只有歌词的条目|x|y": {"lyrics": "[00:01.00]只有正文", "lyrics_source": "qq"}
        }
        """
        guard let strippedData = A.strippedMeta(fromCacheJSON: Data(cacheJSON.utf8)),
              let strippedRoot = try? JSONSerialization.jsonObject(with: strippedData) as? [String: Any]
        else {
            expectEqual(true, false, "歌词备份 meta: strippedMeta 不该失败")
            exit(1)
        }
        let strippedEntry = strippedRoot["周杰伦|枫|十一月的萧邦"] as? [String: Any] ?? [:]
        for field in A.lyricFieldKeys {
            expectEqual(strippedEntry[field] == nil, true, "歌词备份 meta: \(field) 必须被剥掉")
        }
        expectEqual(strippedEntry["lyrics_scoring_version"] as? Int, 9,
                    "歌词备份 meta: 打分版本要带走(丢了会把全库排进重新打分队列)")
        expectEqual(strippedEntry["canonical_artist"] as? String, "周杰伦",
                    "歌词备份 meta: 统一歌手名要带走")
        expectEqual(strippedEntry["plain_lyrics"] as? String, "纯文本",
                    "歌词备份 meta: 纯文本采纳要带走(它压根没有导出文件,此前 100% 丢失)")
        expectEqual((strippedEntry["lyrics_decision"] as? [String: Any])?["winner"] as? String, "netease",
                    "歌词备份 meta: 决策存档整块带走(历史快照,重新解析补不回来)")
        // 剥完只剩空壳的条目不该占位置 —— 它没有任何值得搬的东西。
        expectEqual(strippedRoot["只有歌词的条目|x|y"] == nil, true,
                    "歌词备份 meta: 剥完为空的条目整条丢掉")
        // 不是缓存 JSON、或者缓存是空的,返回 nil 让调用方把 meta 留空(而不是塞一个空对象)。
        expectEqual(A.strippedMeta(fromCacheJSON: Data("不是 JSON".utf8)) == nil, true,
                    "歌词备份 meta: 垃圾输入返回 nil")
        expectEqual(A.strippedMeta(fromCacheJSON: Data("{}".utf8)) == nil, true,
                    "歌词备份 meta: 空缓存返回 nil")

        // 磁盘格式契约:带 meta 的包,字段名和往返都要钉住。
        let metaPayload = A.Payload(at: "2026-09-02T03:00:00Z", device: "Mac",
                                    files: ["a.lrc": "[00:01.00]a"],
                                    pins: [:], meta: strippedData)
        guard let metaArchived = A.encode(metaPayload) else {
            expectEqual(true, false, "歌词备份 meta: encode 不该失败")
            exit(1)
        }
        let metaPlain = String(data: (try! (metaArchived as NSData).decompressed(using: .zlib)) as Data,
                               encoding: .utf8) ?? ""
        expectEqual(metaPlain.contains("\"meta\""), true, "歌词备份 meta: 落盘 JSON 带 \"meta\" 字段")
        expectEqual(A.decode(metaArchived), metaPayload, "歌词备份 meta: 压缩往返内容不变")
        expectEqual(A.decode(metaArchived)?.meta, strippedData, "歌词备份 meta: 字节逐位还原")

        // 两个方向都能互读,所以不需要迁移代码:
        //  - v1 老包在这一版解出来 meta == nil(可选字段缺省);
        //  - v2 新包在只认 v1 的旧版本上,meta 作为未知字段被忽略、歌词部分照常恢复。
        expectEqual(A.payloadVersion, 2, "歌词备份: 载荷版本 2(多了 meta)")
        let v1JSON = """
        {"v":1,"at":"2026-08-21T10:00:00Z","device":"Old","files":{"a.lrc":"x"},"pins":{}}
        """
        let v1Decoded = A.decode(Data(v1JSON.utf8))
        expectEqual(v1Decoded?.files["a.lrc"], "x", "歌词备份 meta: v1 老包照样能解出歌词")
        expectEqual(v1Decoded?.meta == nil, true, "歌词备份 meta: v1 老包解出来 meta 为空")
    }

    // ---- 「重新自动匹配」的采纳判定(LyricsRematchDecision,2026-08-21)----
    //
    // 五条分支里有两条是**不该动**的:当前源这一轮没应答(可能只是超时,换过去等于降级)、
    // 这一轮的冠军没有逐字而现有的有(逐字是打分里最值钱的 +400,但取决于这一轮那个源有没有
    // 把逐字接口给全 —— 实测同一首歌上一轮拿到 6887 字节 YRC、下一轮五个源一个逐字都没有)。
    // 这两条失效时的表现不是报错,是"用户看得见的卡拉OK填色被悄悄弄没了",靠点按钮碰运气
    // 验证不了,只能靠断言。
    do {
        typealias D = LyricsRematchDecision
        // 正常换源。
        expectEqual(D.decide(decidable: true, winnerSource: "kugou", currentHasWordTiming: false,
                             winnerHasWordTiming: false, sameSource: false, sameLyrics: false,
                             sameWordTiming: false),
                    .adopt, "重新匹配: 正常情况采纳冠军")

        // 当前源没应答 → 一步都不许动,而且要排在所有其它判定**之前**(哪怕冠军看起来很好)。
        expectEqual(D.decide(decidable: false, winnerSource: "kugou", currentHasWordTiming: false,
                             winnerHasWordTiming: true, sameSource: false, sameLyrics: false,
                             sameWordTiming: false),
                    .keptNotDecidable, "重新匹配: 当前源没应答时不下结论")

        // 一个能用的候选都没有(空串)—— 绝不允许退回"取第一条"。
        expectEqual(D.decide(decidable: true, winnerSource: "", currentHasWordTiming: false,
                             winnerHasWordTiming: false, sameSource: false, sameLyrics: false,
                             sameWordTiming: false),
                    .keptNoCandidate, "重新匹配: 没有冠军就什么都不动")

        // 逐字保护:现有的有逐字、冠军没有 → 保留。
        expectEqual(D.decide(decidable: true, winnerSource: "lrclib", currentHasWordTiming: true,
                             winnerHasWordTiming: false, sameSource: false, sameLyrics: false,
                             sameWordTiming: false),
                    .keptWouldLoseWordTiming, "重新匹配: 不许把逐字换成整行")
        // 反向:现有的没逐字、冠军有 → 当然要换(这正是升级)。
        expectEqual(D.decide(decidable: true, winnerSource: "qq", currentHasWordTiming: false,
                             winnerHasWordTiming: true, sameSource: false, sameLyrics: false,
                             sameWordTiming: false),
                    .adopt, "重新匹配: 从整行升级到逐字要换")
        // 两边都有逐字 → 正常比内容。
        expectEqual(D.decide(decidable: true, winnerSource: "qq", currentHasWordTiming: true,
                             winnerHasWordTiming: true, sameSource: false, sameLyrics: false,
                             sameWordTiming: false),
                    .adopt, "重新匹配: 两边都有逐字时照常换")

        // 冠军跟现状逐项一致 → 一个字都不写(免得白白落盘 + 踢一次 collector 重启)。
        expectEqual(D.decide(decidable: true, winnerSource: "qq", currentHasWordTiming: true,
                             winnerHasWordTiming: true, sameSource: true, sameLyrics: true,
                             sameWordTiming: true),
                    .unchanged, "重新匹配: 完全没变化时不写盘")
        // 同源但正文变了(那个源自己更新了歌词)→ 要换。
        expectEqual(D.decide(decidable: true, winnerSource: "qq", currentHasWordTiming: false,
                             winnerHasWordTiming: false, sameSource: true, sameLyrics: false,
                             sameWordTiming: true),
                    .adopt, "重新匹配: 同源但正文更新了也要换")
        // 同源同正文、但逐字变了(上一轮没拿到逐字、这轮拿到了)→ 要换。
        expectEqual(D.decide(decidable: true, winnerSource: "qq", currentHasWordTiming: false,
                             winnerHasWordTiming: true, sameSource: true, sameLyrics: true,
                             sameWordTiming: false),
                    .adopt, "重新匹配: 同源同正文但补上了逐字也要换")
    }

    // ---- 「手动选定歌词后锁定」开关的追溯判据(ManualPickLock) ----
    //
    // 2026-09-01 加。这个开关打开时要把"之前手动选过的歌"一并锁成 manual_lyrics,判对判错的
    // 后果不对称:判宽了会锁住一份用户**从没选过**的内容(而且锁上之后所有自动改进都不再碰
    // 它,用户很难发现),判窄了只是开关看起来没生效。整个功能的正确性就压在 shouldFlip 上,
    // 所以它被特意从 EnrichCacheStore(App target,selftest 链不到)挪进 LyrimuseCore。
    do {
        // A / B 是**同一份词的两种排版**:B 换了全部时间戳、改成 CRLF、加了元数据标签和行尾
        // 空白、把两句挂成多时间戳、插了空行。C 换了词。
        let lyricsA = "[ti:测试]\n[00:01.00]第一句\n[00:05.00]第二句\n"
        let lyricsB = "[ar:某人]\r\n[offset:120]\r\n[00:02.34]第一句  \r\n\r\n[00:09.99][01:20.00]第二句\t\r\n"
        let lyricsC = "[00:01.00]第一句\n[00:05.00]完全不同的第二句\n"
        let sha = ManualPickLock.fingerprint(lyrics: lyricsA)

        // ---- 跨语言金标准:Go 侧 manualPickFingerprint 必须算出**一模一样**的值 ----
        //
        // collector 的存量迁移(manualpickmigrate.go)负责把老用户的 lyrics_source_choice 转成
        // manual_pick_sha,而拿这个指纹去比对的是这边的 shouldFlip。两边漂开的后果是**静默**的:
        // 老用户打开开关一首都锁不上,缓存里的指纹看上去还完全正常。Go 侧
        // TestManualPickFingerprintMatchesSwift 钉着同样的输入和期望值。值由独立的第三方实现
        // (Python hashlib)算出。
        expectEqual(sha, "13ec24ce7207", "手动选定锁: 指纹与 Go 侧金标准一致")

        // ⚠️ 这条是 2026-09-01 那次改版的**核心不变量**。第一版对 lyrics+YRC 的原始字节取指纹,
        // 而 collector 启动时的规范化(migrateYRCWhitespaceTokens 重排逐字词条、
        // migrateLyricTimelines 重挂行时间轴)会在采纳后**几秒内**改写内容 —— 指纹当场失配,
        // 开关一首都锁不上,而且完全静默。实测抓到的那条:阿肆《浮光掠影》,lyrics 一字节没变、
        // YRC 被重排,留痕 3c4fe3efb6e8 vs 当前 6625fc9d1d36。
        // 根因是把问题定义错了:要回答的是"自动路径有没有把用户选的那份**换掉**",不是"字节有
        // 没有变" —— 规范化不是替换。
        expectEqual(ManualPickLock.fingerprint(lyrics: lyricsB), sha,
                    "手动选定锁: 重排时间轴/换行/空白/元数据都不改变指纹(否则 collector 启动时的规范化会让开关静默失效)")
        expectEqual(ManualPickLock.fingerprint(lyrics: lyricsC) == sha, false,
                    "手动选定锁: 词变了要判成『已被换掉』")
        expectEqual(ManualPickLock.canonicalLyrics(lyricsA), "第一句\n第二句",
                    "手动选定锁: 归一化只留词")
        expectEqual(ManualPickLock.fingerprint(lyrics: "[ti:只有元数据]\n\n"), "",
                    "手动选定锁: 归一化后没有词 = 没有留痕(空串,不是空串的哈希)")
        expectEqual(ManualPickLock.fingerprint(lyrics: ""), "", "手动选定锁: 空正文给空串")
        expectEqual(sha.count, 12, "手动选定锁: 指纹取 12 位十六进制")

        // 正常路径:用户选过、内容还是那份、当前没锁 → 开关打开时要锁上。
        expectEqual(ManualPickLock.shouldFlip(sha: sha, lyrics: lyricsA,
                                              isLocked: false, locking: true), true,
                    "手动选定锁: 选过+内容没变+没锁 → 打开开关时锁上")
        // 排版被规范化过的同一份词,同样要能锁上 —— 这才是真机上的常态。
        expectEqual(ManualPickLock.shouldFlip(sha: sha, lyrics: lyricsB,
                                              isLocked: false, locking: true), true,
                    "手动选定锁: collector 规范化过排版之后仍然锁得上")
        // 已经是目标状态的不重复计数(否则"已锁定 N 首"会虚高)。
        expectEqual(ManualPickLock.shouldFlip(sha: sha, lyrics: lyricsA,
                                              isLocked: true, locking: true), false,
                    "手动选定锁: 已经锁着的不再计进本次改动")
        expectEqual(ManualPickLock.shouldFlip(sha: sha, lyrics: lyricsA,
                                              isLocked: true, locking: false), true,
                    "手动选定锁: 关掉开关时,因它而锁的要能解开")

        // ⚠️ 内容被真正换掉(词变了)时**必须不锁**,否则锁的是一份用户从没选过的内容。
        expectEqual(ManualPickLock.shouldFlip(sha: sha, lyrics: lyricsC,
                                              isLocked: false, locking: true), false,
                    "手动选定锁: 内容已被自动换掉 → 绝不锁(锁的会是用户没选过的东西)")
        // 没留痕的歌一律不碰 —— 手改正文产生的 manual_lyrics 就落在这一支,关开关时不该被解开。
        expectEqual(ManualPickLock.shouldFlip(sha: nil, lyrics: lyricsA,
                                              isLocked: true, locking: false), false,
                    "手动选定锁: 没有 manual_pick_sha(如手改正文锁的)→ 关开关时不解它")
        expectEqual(ManualPickLock.shouldFlip(sha: "", lyrics: lyricsA,
                                              isLocked: true, locking: false), false,
                    "手动选定锁: 空指纹跟没有指纹同等对待")

        // ---- 三态分类:界面靠它把"一首都没动"说成人话 ----
        //
        // 2026-09-01 用户反馈「交互有点差」之后加的。三种"0 首"对用户是完全不同的三件事,
        // 压成一个 Bool 再静默返回,就是那次反馈里最主要的一条。
        expectEqual(ManualPickLock.state(sha: nil, lyrics: lyricsA), .neverPicked,
                    "手动选定锁三态: 没留痕 = 从没手动选过")
        expectEqual(ManualPickLock.state(sha: "", lyrics: lyricsA), .neverPicked,
                    "手动选定锁三态: 空留痕同等对待")
        expectEqual(ManualPickLock.state(sha: sha, lyrics: lyricsB), .original,
                    "手动选定锁三态: 只是排版被规范化 = 还是当初选的那一份")
        expectEqual(ManualPickLock.state(sha: sha, lyrics: lyricsC), .replaced,
                    "手动选定锁三态: 词变了 = 已被换掉(要跟「从没选过」区分开说)")
        // shouldFlip 必须就是"三态里的 original + 状态相反",不能两处各判各的。
        for locked in [true, false] {
            for locking in [true, false] {
                expectEqual(
                    ManualPickLock.shouldFlip(sha: sha, lyrics: lyricsA,
                                              isLocked: locked, locking: locking),
                    ManualPickLock.state(sha: sha, lyrics: lyricsA) == .original
                        && locked != locking,
                    "手动选定锁: shouldFlip 与三态判定一致(locked=\(locked) locking=\(locking))")
            }
        }
    }

    // ---- LyricsSortOrder(「歌词管理」列表排序) ----
    // 2026-09-02 用户报「排序有时候选了不生效」:开着「仅无歌词」筛选时选「更新时间 新→旧」,
    // 列表纹丝不动、看着还是默认的歌手字母序。根因不是比较器写错,是**这批数据让排序无从下手**
    // ——没歌词的条目按定义没有导出歌词文件,`lyricsUpdatedAt` 全是 nil,于是整屏落进同一个
    // "无时间戳"桶、全部由 (歌手,专辑,歌名) 这个平局键决定顺序,而那恰好就是默认排序。
    // 「来源」两档同样:那一屏 14 条的 lyrics_source 全为空。
    // 修法是给这两个尾块一个真实的组内次级键(`resolvedAt`,缓存里的 ts)。下面最后两条
    // 断言直接钉的就是这个 bug 本身。
    do {
        func k(
            _ title: String,
            artist: String = "aa",
            album: String = "al",
            source: String = "",
            updated: Double? = nil,
            resolved: Double? = nil
        ) -> LyricsSortKey {
            LyricsSortKey(
                normPrimaryArtist: artist,
                normAlbum: album,
                title: title,
                searchTitleLower: title.lowercased(),
                sourceDisplayName: source.isEmpty ? "无来源" : source,
                hasSource: !source.isEmpty,
                lyricsUpdatedAt: updated.map { Date(timeIntervalSince1970: $0) },
                resolvedAt: resolved.map { Date(timeIntervalSince1970: $0) }
            )
        }
        func order(_ keys: [LyricsSortKey], _ o: LyricsSortOrder) -> [String] {
            keys.sorted { o.less($0, $1) }.map(\.title)
        }

        // —— 基本档位:点名的字段随升降序反转,平局键恒按升序 ——
        let byName = [
            k("c", artist: "b", album: "a2"),
            k("a", artist: "a", album: "a1"),
            k("b", artist: "a", album: "a1"),
        ]
        expectEqual(order(byName, .defaultOrder), ["a", "b", "c"], "排序: 默认 = (歌手,专辑,歌名)")
        expectEqual(order(byName, .title(ascending: true)), ["a", "b", "c"], "排序: 歌名 A→Z")
        expectEqual(order(byName, .title(ascending: false)), ["c", "b", "a"], "排序: 歌名 Z→A")
        expectEqual(order(byName, .artist(ascending: false)), ["c", "a", "b"], "排序: 歌手 Z→A —— 歌手降序,同歌手内仍按 (专辑,歌名) 升序断平局")
        expectEqual(order(byName, .album(ascending: false)), ["c", "a", "b"], "排序: 专辑 Z→A —— 同上,平局键不跟着反转")

        // —— 更新时间:有 mtime 的按 mtime ——
        let mixed = [
            k("old", artist: "b", updated: 1000),
            k("new", artist: "a", updated: 3000),
            k("mid", artist: "c", updated: 2000),
        ]
        expectEqual(order(mixed, .updated(ascending: false)), ["new", "mid", "old"], "排序: 更新时间 新→旧")
        expectEqual(order(mixed, .updated(ascending: true)), ["old", "mid", "new"], "排序: 更新时间 旧→新")

        // —— 没有歌词文件的行:两个方向都排最后(不是当成"最早") ——
        let withGap = [
            k("noFile", artist: "a", updated: nil, resolved: 9999),
            k("hasFile", artist: "z", updated: 1000),
        ]
        expectEqual(order(withGap, .updated(ascending: false)), ["hasFile", "noFile"], "排序: 无歌词文件的行排最后(新→旧)")
        expectEqual(
            order(withGap, .updated(ascending: true)), ["hasFile", "noFile"],
            "排序: 无歌词文件的行**旧→新也**排最后 —— 不把未知当成'很久以前'塞到开头"
        )

        // —— 本次修复:无 mtime 的尾块内部改按 resolvedAt(ts)排 ——
        let allMissing = [
            k("A", artist: "a", resolved: 100),  // 歌手字母序最前、但 ts 最旧
            k("B", artist: "b", resolved: 300),
            k("C", artist: "c", resolved: 200),
        ]
        expectEqual(
            order(allMissing, .updated(ascending: false)), ["B", "C", "A"],
            "排序: 全是无歌词文件的行时,新→旧按 ts 排(修复前整屏退化成歌手字母序 = 看起来'选了没反应')"
        )
        expectEqual(order(allMissing, .updated(ascending: true)), ["A", "C", "B"], "排序: 同上,旧→新")
        expectNotEqual(
            order(allMissing, .updated(ascending: false)), order(allMissing, .defaultOrder),
            "排序: 「仅无歌词」那一屏选更新时间,结果必须与默认排序不同(用户报的 bug 本身)"
        )
        // 连 ts 都没有的,在尾块内部再排最后 —— 两个方向都一样。
        let noTS = [k("hasTS", artist: "z", resolved: 500), k("noTS", artist: "a")]
        expectEqual(order(noTS, .updated(ascending: false)), ["hasTS", "noTS"], "排序: 尾块内连 ts 都没有的再排最后(新→旧)")
        expectEqual(order(noTS, .updated(ascending: true)), ["hasTS", "noTS"], "排序: 尾块内连 ts 都没有的再排最后(旧→新)")

        // —— 来源:有来源按展示名排,无来源两个方向都最后 ——
        let bySource = [
            k("q", artist: "b", source: "QQ音乐"),
            k("n", artist: "a", source: "网易云音乐"),
            k("none", artist: "a", resolved: 700),
        ]
        expectEqual(order(bySource, .source(ascending: true)), ["q", "n", "none"], "排序: 来源 A→Z,无来源排最后")
        expectEqual(
            order(bySource, .source(ascending: false)), ["n", "q", "none"],
            "排序: 来源 Z→A —— 有来源的反转,无来源的**仍然**在最后,不跟着翻到开头"
        )
        // 同一来源内部保持 (歌手,专辑,歌名),不动 —— 「来源」这一档表达的是分组,不是组内次序。
        // ⚠️ ts 必须与歌手字母序**相反**,否则两种规则给出同一个顺序、这条断言等于没测
        // (2026-09-02 变异测试逮到过一版就是这么写的:把组内改成按 ts 排,断言照样通过)。
        let sameSource = [
            k("y", artist: "b", source: "QQ音乐", resolved: 100),
            k("x", artist: "a", source: "QQ音乐", resolved: 900),
        ]
        expectEqual(
            order(sameSource, .source(ascending: true)), ["x", "y"],
            "排序: 同一来源内部仍按 (歌手,专辑,歌名),不改成按 ts(ts 顺序与之相反,足以区分)"
        )
        expectEqual(
            order(sameSource, .source(ascending: false)), ["x", "y"],
            "排序: 同一来源内部的次序不随来源升降序反转"
        )

        // —— 本次修复:全都没有来源时,尾块内部按 ts 排 ——
        let allNoSource = [
            k("A", artist: "a", resolved: 100),
            k("B", artist: "b", resolved: 300),
            k("C", artist: "c", resolved: 200),
        ]
        expectEqual(
            order(allNoSource, .source(ascending: false)), ["B", "C", "A"],
            "排序: 全是无来源的行时,来源 Z→A 按 ts 排(「仅无歌词」那一屏 14 条 source 全为空)"
        )
        expectNotEqual(
            order(allNoSource, .source(ascending: true)), order(allNoSource, .defaultOrder),
            "排序: 「仅无歌词」那一屏选来源,结果必须与默认排序不同"
        )
    }

    // ---- 歌词库统计:成色分类的优先级阶梯(2026-09-03,设置页那块统计面板) ----
    //
    // 为什么值得钉:这是一次**有优先级的判定**,不是四个独立布尔。一条条目常常同时满足
    // 好几个条件(`lyrics_yrc` 是在 `lyrics` 之上补的,所以"有逐字"的几乎一定也"有逐行"),
    // 阶梯排错了**完全不报错**,只是统计面板里各项之和悄悄超过总数 —— 而那正是用户一眼
    // 就能看出"这个面板在瞎报"的那种错。
    //
    // ⚠️ 期望值写成一张**16 行的显式表**,不是照着实现再写一遍 if 链 —— 后者是拿同一个
    // 假设验证它自己,阶梯整体挪位置照样全绿。
    do {
        func classify(_ word: Bool, _ line: Bool, _ plain: Bool, _ inst: Bool) -> LyricsKind {
            LyricsKind.classify(
                hasWordTiming: word, hasLyrics: line,
                hasPlainTextFallback: plain, isInstrumental: inst)
        }
        // (逐字, 逐行, 纯文本, 纯音乐) → 该落进哪个桶
        let table: [(Bool, Bool, Bool, Bool, LyricsKind)] = [
            (true,  true,  true,  true,  .wordByWord),
            (true,  true,  true,  false, .wordByWord),
            (true,  true,  false, true,  .wordByWord),
            (true,  true,  false, false, .wordByWord),
            (true,  false, true,  true,  .wordByWord),
            (true,  false, true,  false, .wordByWord),
            (true,  false, false, true,  .wordByWord),
            (true,  false, false, false, .wordByWord),
            (false, true,  true,  true,  .lineByLine),
            (false, true,  true,  false, .lineByLine),
            (false, true,  false, true,  .lineByLine),
            (false, true,  false, false, .lineByLine),
            (false, false, true,  true,  .plainText),
            (false, false, true,  false, .plainText),
            (false, false, false, true,  .instrumental),
            (false, false, false, false, .none),
        ]
        expectEqual(table.count, 16, "歌词库统计: 期望表必须覆盖全部 16 种组合")
        for (word, line, plain, inst, expected) in table {
            expectEqual(
                classify(word, line, plain, inst), expected,
                "歌词库统计: 逐字=\(word) 逐行=\(line) 纯文本=\(plain) 纯音乐=\(inst) 应归入 \(expected.rawValue)")
        }
        // 桶必须正好五个:统计面板按 allCases 铺格子,少一个就有一批条目算进了总数却没有
        // 任何一格显示它们(各项之和 < 总数),多一个则是排版被挤。
        expectEqual(LyricsKind.allCases.count, 5, "歌词库统计: 成色桶应为 5 个")
        // 确证过的纯音乐**不能**跟"没搜到"混为一谈 —— 2026-08-20 在歌词管理列表里修过
        // 一次(一整批 LoL 原声带被显示成刺眼的红色「无歌词」),统计面板不该重犯。
        expectNotEqual(
            classify(false, false, false, true), LyricsKind.none,
            "歌词库统计: 确证过的纯音乐不该被算进「暂无」")
    }

    // ---- 歌词库统计:译文是"源自带社区翻译"还是"collector 机翻" ----
    do {
        func source(_ has: Bool, _ raw: String) -> LyricsTranslationSource {
            LyricsTranslationSource.classify(hasTranslation: has, trSource: raw)
        }
        // ⚠️ **必须先判 hasTranslation**。`lyrics_tr_source` 为空既可能是"社区译文"也可能是
        // "压根没有译文",光看那个字段分不出来 —— 漏了这一步,本机三千多条没译文的歌会全部
        // 被算成社区译文,面板上那个数字直接翻十倍。
        expectEqual(source(false, ""), .none, "译文来源: 没有译文时不该算成社区译文")
        expectEqual(source(false, "machine"), .none, "译文来源: 没有译文时哪怕字段是 machine 也算没有")
        expectEqual(source(true, ""), .community, "译文来源: 空字段 = 歌词源自带的社区翻译(老条目正是这样)")
        expectEqual(source(true, "machine"), .machine, "译文来源: machine = collector 机翻补的")
        // 认不出的值退回"社区":宁可把一份机翻显示成社区译文,也别把三千条源自带译文
        // 误报成机翻 —— 两个方向的错代价不对等。
        expectEqual(source(true, "mt"), .community, "译文来源: 不认识的值退回社区,不当机翻")
    }

    // ---- 跨源同词标注 + 「当前使用」双判据(2026-09-04)----
    //
    // 「搜索候选歌词」列表:不同源常给出逐字相同的词,后到的那几条标「歌词文字与 X 相同」(只标注不隐藏);
    // 「当前使用」从只比来源改成来源 + 词双判据。分组与判据都在 LyricsCandidateDuplicates(Core),面板只是消费。
    do {
        typealias D = LyricsCandidateDuplicates
        let ordered: [(source: String, fingerprint: String)] = [
            ("kugou", "aaa"), ("qq", "bbb"), ("netease", "aaa"), ("lrclib", ""), ("migu", "aaa"), ("amll", ""),
        ]
        let m = D.firstMatches(ordered)
        expectEqual(m["kugou"], nil, "同词标注: 每组首条不标")
        expectEqual(m["netease"], "kugou", "同词标注: 后来者指向排在前面的那条")
        expectEqual(m["migu"], "kugou", "同词标注: 第三条仍指向首条,不是链式指向上一条")
        expectEqual(m["qq"], nil, "同词标注: 独一份的不标")
        expectEqual(m["lrclib"], nil, "同词标注: 指纹为空的不标")
        expectEqual(D.firstMatches([("lrclib", ""), ("amll", "")]).isEmpty, true, "同词标注: 空指纹互相不算相同")
        expectEqual(D.firstMatches([]).isEmpty, true, "同词标注: 空列表")
        expectEqual(D.isCurrent(candidateSource: "qq", candidateFingerprint: "x", currentSource: "qq", currentFingerprint: "x"), true,
                    "当前使用: 源同词同")
        expectEqual(D.isCurrent(candidateSource: "qq", candidateFingerprint: "x", currentSource: "qq", currentFingerprint: "y"), false,
                    "当前使用: 同源但正文被改过,不标")
        expectEqual(D.isCurrent(candidateSource: "kugou", candidateFingerprint: "x", currentSource: "qq", currentFingerprint: "x"), false,
                    "当前使用: 词相同但来源不同,不标")
        expectEqual(D.isCurrent(candidateSource: "qq", candidateFingerprint: "x", currentSource: "qq", currentFingerprint: nil), true,
                    "当前使用: 拿不到当前指纹退回只比来源")
        expectEqual(D.isCurrent(candidateSource: "qq", candidateFingerprint: "", currentSource: "qq", currentFingerprint: "x"), true,
                    "当前使用: 候选没有词时退回只比来源")
        expectEqual(D.isCurrent(candidateSource: "qq", candidateFingerprint: "x", currentSource: nil, currentFingerprint: "x"), false,
                    "当前使用: 没有当前来源就没有当前")
        // 指纹本身是 ManualPickLock 的既有口径:时间戳全变、CRLF、词不变 → 相同。
        let a = ManualPickLock.fingerprint(lyrics: "[00:01.00]你好\n[00:05.00]世界")
        let b = ManualPickLock.fingerprint(lyrics: "[00:02.50]你好\r\n[00:06.10]世界\n")
        expectEqual(a == b && !a.isEmpty, true, "同词标注: 复用只取词的指纹,时间戳/CRLF 不影响")
    }
}
