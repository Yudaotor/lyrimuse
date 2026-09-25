import LyrimuseCore
import Foundation

// 设置页交互的纯逻辑:「顺序优先」歌词源列表的把手拖拽排序(滞回 / 让位 / 写回)。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里。

@MainActor
func runSettingsInteractionTests() {
    // ---- ReorderDrag----
    //
    // 数值都按真实的设置行来:行高约 35 + 分隔线 1 = 槛距 36;五行的静止中线 17.5 / 53.5 / 89.5 / 125.5 / 161.5。
    do {
        print("\n== 顺序优先列表拖拽排序 ==")
        typealias R = ReorderDrag
        let mids: [CGFloat] = (0..<5).map { 17.5 + 36 * CGFloat($0) }

        // 滞回:被拖第 1 行(中线 53.5)往下,越过第 2 行中线 89.5 还不换位,再多 6 才换;换位后往回抖 6 以内不退。
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 1, draggedMidY: 53.5), 1, "滞回: 没动 → 原位")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 1, draggedMidY: 89.5 + 5.9), 1, "滞回: 越过邻行中线 5.9pt 还不换位")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 1, draggedMidY: 89.5 + 6.1), 2, "滞回: 越过邻行中线 6.1pt 换位")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 2, draggedMidY: 89.5 - 5.9), 2, "滞回: 换位后回抖 5.9pt 不退回(死区 2h)")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 2, draggedMidY: 89.5 - 6.1), 1, "滞回: 回抖超过 6pt 才退回")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 3, current: 3, draggedMidY: 89.5 - 5.9), 3, "滞回: 往上越过 5.9pt 不换")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 3, current: 3, draggedMidY: 89.5 - 6.1), 2, "滞回: 往上越过 6.1pt 换位")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 1, draggedMidY: 500), 4, "滞回: 一帧连越多行到末位并夹住")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 3, current: 3, draggedMidY: -100), 0, "滞回: 往上连越到首位并夹住")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 1, draggedMidY: 89.5 + 0.1, hysteresis: 0), 2, "滞回: h=0 退化成过中线即换")
        expectEqual(R.targetIndex(rowMidYs: [10], source: 0, current: 0, draggedMidY: 999), 0, "滞回: 单行列表原地")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 9, current: 1, draggedMidY: 999), 1, "滞回: source 越界 → 保持 current")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 42, draggedMidY: 53.5), 1, "滞回: current 越界先夹进范围再按位置判(没动就回原位)")
        // 单向推进:一帧里只朝一个方向走。从 0 甩到底再在同一帧里不可能又退回。
        var t = 0
        for y in stride(from: 17.5, through: 200, by: 7) { t = R.targetIndex(rowMidYs: mids, source: 0, current: t, draggedMidY: CGFloat(y)) }
        expectEqual(t, 4, "滞回: 逐帧往下推进到底")
        var back = t
        for y in stride(from: 200, through: 0, by: -7) { back = R.targetIndex(rowMidYs: mids, source: 0, current: back, draggedMidY: CGFloat(y)) }
        expectEqual(back, 0, "滞回: 逐帧往上推进回顶")

        // 让位:被拖第 1 行去了 3,第 2、3 行各往上补一格(挪到上一行原中线,含分隔线),其余不动。
        expectEqual(R.displacement(row: 2, source: 1, target: 3, rowMidYs: mids), CGFloat(-36), "让位: 被越过的行往上挪一个槛距(含分隔线)")
        expectEqual(R.displacement(row: 3, source: 1, target: 3, rowMidYs: mids), CGFloat(-36), "让位: 目标位那行也往上")
        expectEqual(R.displacement(row: 4, source: 1, target: 3, rowMidYs: mids), CGFloat(0), "让位: 目标位之后的行不动")
        expectEqual(R.displacement(row: 0, source: 1, target: 3, rowMidYs: mids), CGFloat(0), "让位: 被拖行之前的行不动")
        expectEqual(R.displacement(row: 1, source: 1, target: 3, rowMidYs: mids), CGFloat(0), "让位: 被拖行自己不归这里管")
        expectEqual(R.displacement(row: 2, source: 3, target: 1, rowMidYs: mids), CGFloat(36), "让位: 往上拖时中间行往下挪")
        expectEqual(R.displacement(row: 1, source: 3, target: 1, rowMidYs: mids), CGFloat(36), "让位: 往上拖到的目标位那行往下")
        expectEqual(R.displacement(row: 2, source: 2, target: 2, rowMidYs: mids), CGFloat(0), "让位: 没换位一律 0")
        expectEqual(R.displacement(row: 7, source: 2, target: 4, rowMidYs: mids), CGFloat(0), "让位: 行下标越界 → 0")
        let uneven: [CGFloat] = [10, 50, 70]
        expectEqual(R.displacement(row: 1, source: 0, target: 2, rowMidYs: uneven), CGFloat(-40), "让位: 非均匀槛距按真实中线差(第一格)")
        expectEqual(R.displacement(row: 2, source: 0, target: 2, rowMidYs: uneven), CGFloat(-20), "让位: 非均匀槛距按真实中线差(第二格)")

        // 夹住 + 滞回叠加(漏测的表现是「拖不到第一个前面」):位移夹在首尾中线之间后,
        // 首 / 末位必须仍然到得了。
        let toTop = R.clampedTranslation(-1000, source: 3, rowMidYs: mids)
        expectEqual(R.targetIndex(rowMidYs: mids, source: 3, current: 3, draggedMidY: mids[3] + toTop), 0,
                    "首尾: 夹到顶之后要落到首位(原来差 6pt 永远到不了)")
        let toBottom = R.clampedTranslation(1000, source: 1, rowMidYs: mids)
        expectEqual(R.targetIndex(rowMidYs: mids, source: 1, current: 1, draggedMidY: mids[1] + toBottom), 4,
                    "首尾: 夹到底之后要落到末位")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 3, current: 3, draggedMidY: mids[0] + 0.3), 0, "首尾: 边界半点容差内算到顶")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 3, current: 3, draggedMidY: mids[0] + 1), 1, "首尾: 离顶 1pt 仍按滞回算(越过了第 2、1 行到第 1 位,还没到首位)")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 3, current: 0, draggedMidY: mids[0] + 1), 0, "首尾: 到过顶之后回抖 1pt 留在首位(死区)")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 0, current: 0, draggedMidY: mids[0]), 0, "首尾: 首行静止在原位")
        expectEqual(R.targetIndex(rowMidYs: mids, source: 4, current: 4, draggedMidY: mids[4]), 4, "首尾: 末行静止在原位")
        // 逐帧从第 4 行拖到顶(每帧位移都先夹住):最终必须是 0。
        var top = 3
        for raw in stride(from: 0.0, through: -300, by: -5) {
            let tr = R.clampedTranslation(CGFloat(raw), source: 3, rowMidYs: mids)
            top = R.targetIndex(rowMidYs: mids, source: 3, current: top, draggedMidY: mids[3] + tr)
        }
        expectEqual(top, 0, "首尾: 逐帧夹住 + 滞回一路拖到顶必须落到首位")

        // 夹住:被拖行不出列表首尾。
        expectEqual(R.clampedTranslation(-1000, source: 2, rowMidYs: mids), mids[0] - mids[2], "夹住: 不出列表顶")
        expectEqual(R.clampedTranslation(1000, source: 2, rowMidYs: mids), mids[4] - mids[2], "夹住: 不出列表底")
        expectEqual(R.clampedTranslation(10, source: 2, rowMidYs: mids), CGFloat(10), "夹住: 范围内原样")
        expectEqual(R.clampedTranslation(10, source: 9, rowMidYs: mids), CGFloat(10), "夹住: source 越界原样返回")

        // 写回完整排列:x / y 是禁用源,槽位不动;可见顺序正是拖出来的顺序。
        let order = ["A", "x", "B", "C", "y", "D"]
        let enabled: Set<String> = ["A", "B", "C", "D"]
        let vis: (String) -> Bool = { enabled.contains($0) }
        expectEqual(R.moved(order, isVisible: vis, from: 3, to: 0), ["D", "x", "A", "B", "y", "C"], "写回: D 拖到首位,x/y 槽位不动")
        expectEqual(R.moved(order, isVisible: vis, from: 0, to: 3), ["B", "x", "C", "D", "y", "A"], "写回: A 拖到末位")
        expectEqual(R.moved(order, isVisible: vis, from: 1, to: 2), ["A", "x", "C", "B", "y", "D"], "写回: 相邻一步 = 箭头 swap 的结果")
        expectEqual(R.moved(order, isVisible: vis, from: 2, to: 2), order, "写回: 原地不动原样返回")
        expectEqual(R.moved(order, isVisible: vis, from: 7, to: 0), order, "写回: from 越界原样返回")
        expectEqual(R.moved(order, isVisible: vis, from: 0, to: 4), order, "写回: to 越界(可见只有 4 个)原样返回")
        expectEqual(R.moved(order, isVisible: vis, from: 3, to: 0).filter(vis), ["D", "A", "B", "C"], "写回: 可见顺序正是拖出来的顺序")
        expectEqual(Set(R.moved(order, isVisible: vis, from: 3, to: 0)), Set(order), "写回: 不丢不多")
        expectEqual(R.moved([1, 2, 3, 4], isVisible: { _ in true }, from: 3, to: 1), [1, 4, 2, 3], "写回: 全部可见 = 普通 move")
        var stepwise = order
        for (f, to) in [(3, 2), (2, 1), (1, 0)] { stepwise = R.moved(stepwise, isVisible: vis, from: f, to: to) }
        expectEqual(stepwise, R.moved(order, isVisible: vis, from: 3, to: 0), "写回: 三次相邻 swap 与一次拖拽结果一致(箭头与把手不打架)")
    }

    // ---- ProportionBar(「歌词 → 管理」歌词库统计的分段比例条)----
    //
    // 数据用本机真实分布:3,325 / 232 / 9 / 38 / 65(逐字 / 逐行 / 纯文本 / 纯音乐 / 暂无),可用宽 540、缝 1.5、下限 3。
    // 这个算法改错了完全不报错 —— 只是某一段消失或整条长出几 pt 被裁掉尾巴,肉眼未必看得出,所以钉在这里。
    do {
        print("\n== 比例条分段宽度 ==")
        typealias P = ProportionBar
        let real = [3325, 232, 9, 38, 65]
        let w = P.widths(values: real, available: 540, gap: 1.5, minWidth: 3)
        expectEqual(w.count, 5, "比例条: 一段一个宽度")
        expectEqual(abs(w.reduce(0, +) + 1.5 * 4 - 540) < 0.001, true, "比例条: 各段 + 缝隙恒等于可用宽度(不溢出不留尾)")
        expectEqual(w.allSatisfy { $0 >= 3 - 0.001 }, true, "比例条: 非零段不小于下限")
        expectEqual(w[2], 3, "比例条: 9/3669 ≈ 1.3pt 被抬到下限 3pt")
        expectEqual(w[0] < 540 * 3325 / 3669, true, "比例条: 抬下限多占的宽度从最宽的一段扣")
        expectEqual(w[1] > w[4] && w[4] > w[3] && w[3] > w[2], true, "比例条: 没碰下限的段仍按比例排序")

        expectEqual(P.widths(values: [], available: 540, gap: 1.5, minWidth: 3), [], "比例条: 空输入空输出")
        expectEqual(P.widths(values: [0, 0], available: 540, gap: 1.5, minWidth: 3), [0, 0], "比例条: 全 0 不画(不抬下限)")
        expectEqual(P.widths(values: [7], available: 540, gap: 1.5, minWidth: 3), [540], "比例条: 单段铺满,没有缝")
        expectEqual(P.widths(values: [1, 1], available: 0, gap: 1.5, minWidth: 3), [0, 0], "比例条: 可用宽 0(首帧还没量到)全 0,不报 nan")
        // 段数多到"每段给下限"都装不下:下限退化成均分,不硬撑到溢出。
        let crowded = P.widths(values: Array(repeating: 1, count: 100), available: 100, gap: 0, minWidth: 3)
        expectEqual(abs(crowded.reduce(0, +) - 100) < 0.001, true, "比例条: 段数太多时总宽仍等于可用宽度")
        expectEqual(crowded.allSatisfy { abs($0 - 1) < 0.001 }, true, "比例条: 段数太多时退化成均分")
        // 最宽的一段扣到下限还不够时继续扣次宽的:三个小段各抬到 12(亏空 33),40 那段最多只能让 28、
        // 剩下 5 从 30 那段扣 → [12, 25, 12, 12, 12]。
        let cascade = P.widths(values: [40, 30, 1, 1, 1], available: 73, gap: 0, minWidth: 12)
        expectEqual(cascade.map { ($0 * 1000).rounded() / 1000 }, [12, 25, 12, 12, 12], "比例条: 亏空跨段扣回")
        expectEqual(abs(cascade.reduce(0, +) - 73) < 0.001, true, "比例条: 亏空跨段扣回后总宽仍守恒")
    }

    // ---- 芯片换行(ChipFlowGeometry)----
    // Last.fm 卡「Scrobble 的播放器」那一排:内置播放器 + 信任列表里的浏览器摆同一排,个数由用户决定。
    // 真机尺寸:芯片 22pt 图标 + 左右各 3pt 内衬 = 28,间距 6,尾部槽位上限 320(见 PlayerChipMetrics)。
    do {
        typealias G = ChipFlowGeometry
        let chip: CGFloat = 28, gap: CGFloat = 6, limit: CGFloat = 320
        func widths(_ n: Int) -> [CGFloat] { Array(repeating: chip, count: n) }

        // 用户当天的真实候选:五个内置 + Safari / Chrome / Edge / Arc = 9 枚,必须仍是一行
        // (9×28 + 8×6 = 300 ≤ 320)—— 这正是"把四行开关收拢成一排"要保住的东西。
        let nine = G.rows(widths: widths(9), spacing: gap, limit: limit)
        expectEqual(nine.count, 1, "芯片换行: 9 枚(5 内置 + 4 浏览器)仍排成一行")
        expectEqual(nine.first?.width, 300, "芯片换行: 9 枚一行宽 300pt")
        expectEqual(G.size(rows: nine, rowHeight: chip, spacing: gap), CGSize(width: 300, height: 28),
                    "芯片换行: 一行时整块就是芯片高,行高不涨")

        // 第 10 枚开始换行:上限 320 装不下 10×28+9×6=334。
        let ten = G.rows(widths: widths(10), spacing: gap, limit: limit)
        expectEqual(ten.count, 2, "芯片换行: 第 10 枚换到第二行")
        expectEqual(ten.map(\.indices.count), [9, 1], "芯片换行: 换行按顺序装箱,前一行装满才换")
        expectEqual(G.size(rows: ten, rowHeight: chip, spacing: gap).height, 62, "芯片换行: 两行 = 28×2 + 6")

        // 边界:恰好装满不换行。
        expectEqual(G.rows(widths: [100, 100, 100], spacing: 10, limit: 320).count, 1, "芯片换行: 恰好装满(320)不换行")
        expectEqual(G.rows(widths: [100, 100, 100], spacing: 10, limit: 319).count, 2, "芯片换行: 差 1pt 就换行")

        // 单枚比上限还宽:独占一行、照画,不丢也不压缩 —— 少画一枚会让用户以为那个播放器不在候选里。
        let oversize = G.rows(widths: [400, 28], spacing: gap, limit: limit)
        expectEqual(oversize.map(\.indices), [[0], [1]], "芯片换行: 超宽的一枚独占一行,后面的照常换行")
        expectEqual(oversize.first?.width, 400, "芯片换行: 超宽的一枚宽度不被压缩")

        // 首帧还没量到宽度(limit ≤ 0)不能炸成每枚一行 —— 那会把行高撑成九倍。
        expectEqual(G.rows(widths: widths(9), spacing: gap, limit: 0).count, 1, "芯片换行: 还没量到宽度时全塞一行")
        expectEqual(G.rows(widths: [], spacing: gap, limit: limit), [], "芯片换行: 没有候选 → 空")
        expectEqual(G.size(rows: [], rowHeight: chip, spacing: gap), .zero, "芯片换行: 没有候选时不占高")
    }

    // 「歌词来源」卡的排列:中文用户中文源在前,其余国外源在前;组内顺序不变。
    do {
        typealias R = LyricsSourceRegion
        let all = ["kugou", "netease", "qq", "musixmatch", "lrclib", "amll", "lyricfind", "kuwo", "migu", "deezer", "applemusic", "soda"]
        expectEqual(R.displayOrder(all, chineseFirst: true),
                    ["kugou", "netease", "qq", "kuwo", "migu", "soda", "musixmatch", "lrclib", "amll", "lyricfind", "deezer", "applemusic"],
                    "来源排列: 中文用户中文源在前,两组内保持原顺序")
        expectEqual(R.displayOrder(all, chineseFirst: false),
                    ["musixmatch", "lrclib", "amll", "lyricfind", "deezer", "applemusic", "kugou", "netease", "qq", "kuwo", "migu", "soda"],
                    "来源排列: 其余用户国外源在前")
        expectEqual(R.prefersChineseSources(appLanguageOverride: "en", preferredLanguage: "zh-Hans-CN"), false,
                    "来源排列: 设置里明确选了英文界面,按非中文")
        expectEqual(R.prefersChineseSources(appLanguageOverride: "zh-hant", preferredLanguage: "en-US"), true,
                    "来源排列: 设置里明确选了中文界面,按中文")
        expectEqual(R.prefersChineseSources(appLanguageOverride: "system", preferredLanguage: "zh-Hant-TW"), true,
                    "来源排列: 跟随系统时,繁体中文系统算中文")
        expectEqual(R.prefersChineseSources(appLanguageOverride: nil, preferredLanguage: "ja-JP"), false,
                    "来源排列: 跟随系统时,日语系统算非中文(界面虽退回简体,更用得上国外源)")
        expectEqual(R.prefersChineseSources(appLanguageOverride: nil, preferredLanguage: nil), false,
                    "来源排列: 读不到系统语言时按非中文")
    }

    // 「通知平台」下拉菜单的排列:中文用户国内平台在前,其余国外平台在前。两组合起来必须正好是 App 侧
    // NotificationPlatform 的全部 rawValue(跟 collector notify.go 的平台常量逐字对应),漏一个就从菜单里消失。
    do {
        typealias N = NotificationPlatformRegion
        expectEqual(N.displayOrder(chineseFirst: true),
                    ["bark", "dingtalk", "wecom", "feishu", "serverchan", "telegram", "discord"],
                    "通知平台排列: 中文用户国内平台在前")
        expectEqual(N.displayOrder(chineseFirst: false),
                    ["telegram", "discord", "bark", "dingtalk", "wecom", "feishu", "serverchan"],
                    "通知平台排列: 其余用户国外平台在前")
        let all: Set<String> = ["bark", "dingtalk", "wecom", "discord", "feishu", "serverchan", "telegram"]
        expectEqual(Set(N.displayOrder(chineseFirst: true)), all, "通知平台排列: 两组覆盖全部平台")
        expectEqual(N.displayOrder(chineseFirst: true).count, all.count, "通知平台排列: 没有重复")
        // App 侧枚举在 selftest 链不到的 target 里,按源码对一遍 case 列表。
        let store = (try? String(contentsOfFile: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("lyrimuse/Settings/ConfigStore.swift").path,
            encoding: .utf8)) ?? ""
        let caseLine = store.split(separator: "\n").first { $0.contains("enum NotificationPlatform") }
            .flatMap { _ in store.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("case bark") } }
        let cases = Set((caseLine ?? "").replacingOccurrences(of: "case", with: "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        expectEqual(cases, all, "通知平台排列: NotificationPlatform 的 case 跟两组对得上(加了平台要同步进 NotificationPlatformRegion)")
    }

    // ---- 保存时的键差分(CollectorRestartPolicy.changedKeys,只给日志用)----
    do {
        typealias P = CollectorRestartPolicy
        // 键差分:值变了 / 键被删 / 键新增都算变,值没变不算。
        expectEqual(P.changedKeys(from: ["a": 1, "b": "x"], to: ["a": 1, "b": "x"]), [], "键差分: 完全相同 → 空")
        expectEqual(P.changedKeys(from: ["a": 1], to: ["a": 2]), ["a"], "键差分: 值变了")
        expectEqual(P.changedKeys(from: ["a": 1], to: [:]), ["a"], "键差分: 键被删掉也算变")
        expectEqual(P.changedKeys(from: [:], to: ["a": 1]), ["a"], "键差分: 新增的键")
        // 数组 / 字典靠 NSObject.isEqual 深比较,不需要自己递归 —— 这一项正是「Scrobble 的播放器」的形状。
        expectEqual(P.changedKeys(from: ["l": ["x", "y"]], to: ["l": ["x", "y"]]), [], "键差分: 内容相同的数组不算变")
        expectEqual(P.changedKeys(from: ["l": ["x", "y"]], to: ["l": ["y", "x"]]), ["l"], "键差分: 顺序不同的数组算变")
        expectEqual(P.changedKeys(from: ["m": ["k": "v"]], to: ["m": ["k": "v"]]), [], "键差分: 内容相同的字典不算变")
        expectEqual(P.changedKeys(from: ["m": ["k": "v"]], to: ["m": ["k": "w"]]), ["m"], "键差分: 字典里的值变了")
    }

    // ---- NavigationHistory: 设置窗那对前进 / 后退键 ----
    //
    // 语义对着 macOS「系统设置」抄,而它的坑全在边界上(截断、去重、起点、封顶),所以整块
    // 逻辑放在 Core 的纯值类型里、这里钉死;界面那半只剩两颗按钮的 disabled 与 action。
    do {
        typealias H = NavigationHistory<String>

        // 起点:窗口刚打开那一页是"打开就在这儿",不是一次跳转 —— 后退键此刻必须是灰的。
        // 种早了(或者把它当成一次 record)就会变成"刚打开就能后退,退回一个没露过面的页面"。
        var h = H()
        expectEqual(h.canGoBack, false, "历史: 空历史退不动")
        expectEqual(h.canGoForward, false, "历史: 空历史进不动")
        expectEqual(h.current, nil, "历史: 空历史没有当前项")
        h.seed("歌词")
        expectEqual(h.current, "歌词", "历史: 种下的起点就是当前项")
        expectEqual(h.canGoBack, false, "历史: 只有起点时后退键是灰的")
        expectEqual(h.canGoForward, false, "历史: 只有起点时前进键也是灰的")

        // 走两步再退两步、前进两步 —— 前后必须能原路来回。
        h.record("播放器")
        h.record("快捷键")
        expectEqual(h.canGoBack, true, "历史: 走过两步之后可以后退")
        expectEqual(h.goBack(), "播放器", "历史: 后退一格回到上一个面板")
        expectEqual(h.goBack(), "歌词", "历史: 再退一格回到起点")
        expectEqual(h.canGoBack, false, "历史: 退到起点就退不动了")
        expectEqual(h.goBack(), nil, "历史: 退不动时返回 nil(调用方据此不动 selection)")
        expectEqual(h.goForward(), "播放器", "历史: 前进走回来")
        expectEqual(h.goForward(), "快捷键", "历史: 再进一格回到最新")
        expectEqual(h.canGoForward, false, "历史: 到头就进不动了")
        expectEqual(h.goForward(), nil, "历史: 进不动时返回 nil")

        // **从历史中间跳去一个新面板 → 前面那一截被截断**(同浏览器,也是系统设置的行为)。
        // 少了这一条,后退两步再点侧栏另一页,前进键会把你送回一条早就作废的路线。
        var t = H()
        t.seed("歌词")
        t.record("播放器")
        t.record("快捷键")
        _ = t.goBack()                      // 停在「播放器」
        expectEqual(t.canGoForward, true, "历史: 退一格之后前进键是亮的")
        t.record("通用")                      // 从中间跳去新面板
        expectEqual(t.canGoForward, false, "历史: 从中间跳去新面板,前面那一截被截断")
        expectEqual(t.items, ["歌词", "播放器", "通用"], "历史: 被截断的是「快捷键」那一截")
        expectEqual(t.goBack(), "播放器", "历史: 截断之后仍能正常后退")

        // 重复进入当前这一页不记 —— 点侧栏里已经亮着的那一行不该产生一条后退记录。
        var d = H()
        d.seed("歌词")
        expectEqual(d.record("歌词"), false, "历史: 重复选中当前页不记")
        expectEqual(d.canGoBack, false, "历史: 重复选中之后后退键仍是灰的")
        expectEqual(d.record("播放器"), true, "历史: 换了一页才记")
        // 只去重「当前这一项」,不去重整条历史:A 到 B 到 A 是真的走了三步,
        // 后退应该回到 B 而不是直接跳过去。
        expectEqual(d.record("歌词"), true, "历史: A→B→A 的第二次 A 照记(不是全局去重)")
        expectEqual(d.goBack(), "播放器", "历史: A→B→A 后退回到 B")

        // 封顶:砍掉队头之后游标要跟着往前挪,不能指到别人身上。
        var c = H(capacity: 3)
        c.seed("1")
        c.record("2")
        c.record("3")
        c.record("4")
        expectEqual(c.items, ["2", "3", "4"], "历史: 超出上限时从队头砍")
        expectEqual(c.current, "4", "历史: 砍完之后当前项还是最新那个")
        expectEqual(c.goBack(), "3", "历史: 砍完之后后退一格不会指错")

        // 种一次起点等于把历史整个重置(窗口重开是一次新会话,不该继承上次的路线)。
        var r = H()
        r.seed("歌词")
        r.record("播放器")
        r.seed("通用")
        expectEqual(r.items, ["通用"], "历史: 重新种起点会清掉旧路线")
        expectEqual(r.canGoBack, false, "历史: 重新种起点之后退不动")
    }

    // ---- 位置 = 顶层面板 + 页内二级分段 ----
    //
    // 设置窗记到"分段"这一层(SettingsView 的 `SettingsLocation` / `section(of:)` / `applySection`),
    // 因为页内换段在用户眼里跟换页是同一件事。这里钉的是带分段的位置在同一套历史语义下的行为:
    // 同一页换段算一次跳转、后退要把分段一起带回去、没有分段的面板(section = nil)照旧去重。
    do {
        struct Loc: Hashable {
            let panel: String
            let section: String?
        }
        var h = NavigationHistory<Loc>()
        h.seed(Loc(panel: "歌词", section: "fetch"))
        expectEqual(h.canGoBack, false, "历史(分段): 起点仍然退不动")
        expectEqual(h.record(Loc(panel: "歌词", section: "translation")), true, "历史(分段): 同一页换分段算一次跳转")
        expectEqual(h.canGoBack, true, "历史(分段): 换过分段之后后退键是亮的")
        expectEqual(h.record(Loc(panel: "歌词", section: "translation")), false, "历史(分段): 点已经选中的那一段不记")

        // 换页之后再后退,回到的是"那一页 + 它当时停的那一段",不是那一页的默认段 —— 只记面板的话
        // 这一条就退成了"回到歌词页的获取段",用户在页内走过的那一步凭空消失。
        expectEqual(h.record(Loc(panel: "播放器", section: nil)), true, "历史(分段): 换去没有分段的面板照记")
        expectEqual(h.record(Loc(panel: "播放器", section: nil)), false, "历史(分段): 没有分段的面板重复进入不记")
        expectEqual(h.goBack(), Loc(panel: "歌词", section: "translation"), "历史(分段): 后退把分段一起带回去")
        expectEqual(h.goBack(), Loc(panel: "歌词", section: "fetch"), "历史(分段): 再退一格回到起点那一段")
        expectEqual(h.goForward(), Loc(panel: "歌词", section: "translation"), "历史(分段): 前进走回去")
    }

    // ---- NotificationWebhookSlots ----
    do {
        print("\n== 推送平台各自的 webhook 地址 ==")
        typealias S = NotificationWebhookSlots
        var slots = S(stored: [:], activePlatform: "bark", activeURL: "https://api.day.app/KEY")
        expectEqual(slots.switchPlatform(from: "bark", currentURL: "https://api.day.app/KEY", to: "telegram"), "",
                    "推送地址: 切到没填过的平台,输入框是空的(不能还显示上一个平台的地址)")
        expectEqual(slots.switchPlatform(from: "telegram", currentURL: "123:AAH", to: "bark"), "https://api.day.app/KEY",
                    "推送地址: 切回来,原来的地址还在")
        expectEqual(slots.switchPlatform(from: "bark", currentURL: "https://api.day.app/KEY", to: "telegram"), "123:AAH",
                    "推送地址: 再切过去,那个平台刚才填的也还在")
        expectEqual(slots.persisted(activePlatform: "telegram", activeURL: "456:BBB"),
                    ["bark": "https://api.day.app/KEY", "telegram": "456:BBB"],
                    "推送地址: 落盘全集并入当前平台此刻的地址")
        expectEqual(slots.persisted(activePlatform: "telegram", activeURL: "  "), ["bark": "https://api.day.app/KEY"],
                    "推送地址: 清空了的平台不落盘")
        let legacy = S(stored: [:], activePlatform: "feishu", activeURL: "https://open.feishu.cn/x")
        expectEqual(legacy.persisted(activePlatform: "feishu", activeURL: "https://open.feishu.cn/x"),
                    ["feishu": "https://open.feishu.cn/x"],
                    "推送地址: 旧配置只有 bark_url,读进来就记在当前平台名下")
    }
}
