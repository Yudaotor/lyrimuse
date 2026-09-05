import LyrimuseCore
import Foundation

// lyrimuse-selftest 的入口:只放「注册表 + 参数 + 汇总」。断言本身按领域放在同目录的
// XxxTests.swift 里,每个文件一个 runXxxTests(),由下面的 groups 表按顺序调用;断言函数与
// 计数器在 Harness.swift。
//
// 加断言:
//   - 已有领域 → 写进对应文件的 runXxxTests() 函数体里(顺序执行,失败只计数不中断),
//     用 `// ---- 小节标题 ----` 分节,跟原来一样。
//   - 新领域   → 新建 XxxTests.swift(平铺在本目录,别建子目录:好几条守卫靠 #filePath 往上数
//     目录层数定位仓库文件),写 func runXxxTests() { … },再在 groups 里加一行。
//     忘了加会被下面的「注册表守卫」当场 FAIL:它扫本目录所有 run…Tests() 定义,逐个核对
//     本文件有没有引用。
//   - 本文件不放断言:放在这里的断言不属于任何一组,--filter 选不到、汇总里也没它的名字。
//
// 用法:
//   lyrimuse-selftest                    全部组,每条断言一行 ok/FAIL
//   lyrimuse-selftest --filter lastfm    只跑组名含 lastfm 的组(可重复给多个;不区分大小写)
//   lyrimuse-selftest --quiet            不打 ok 行,只留 FAIL + 每组一行汇总
//   lyrimuse-selftest --list             列出所有组
// 退出码:0 全部通过;1 有 FAIL;2 参数错误,或 --filter 一组都没匹配上(手滑拼错不能拿到假绿)。

struct TestGroup {
    /// --filter 匹配的对象,小写短横线。
    let name: String
    /// --list 里的一句话说明。
    let summary: String
    /// 标成 @MainActor:原先这些断言是 main.swift 的顶层语句、天然跑在主 actor 上,拆进函数后
    /// 要显式保住这层隔离,否则引用 Core 里 @MainActor 的属性会报「nonisolated context」。
    let run: @MainActor () -> Void
}

let groups: [TestGroup] = [
    TestGroup(name: "parsing", summary: "歌词解析:LRC / YRC / 逐字时间轴归一化", run: runLyricsParsingTests),
    TestGroup(name: "sync-engine", summary: "歌词同步引擎:当前行 / 滚动 / 填色 / 提前量 / 对唱分栏", run: runSyncEngineTests),
    TestGroup(name: "credit-lines", summary: "署名行 / 噪声行过滤(含全库语料回归)", run: runCreditLineTests),
    TestGroup(name: "romanization", summary: "罗马音 / 分词 / 繁简与异体字", run: runRomanizationTests),
    TestGroup(name: "cache-keys", summary: "缓存 key 归一化(与 collector 逐字节一致)/ 合唱 credit 归并", run: runCacheKeyTests),
    TestGroup(name: "lyrics-offset", summary: "歌词时间轴偏移:基准 + 单曲微调 / 作用域 / 已校准名单", run: runLyricsOffsetTests),
    TestGroup(name: "lyrics-manager", summary: "歌词管理:列宽 / 写回合并 / 备份归档 / 重匹配 / 锁定 / 排序", run: runLyricsManagerTests),
    TestGroup(name: "playback-position", summary: "播放位置:外推伺服 / 锚点 / seek / 浏览器探针", run: runPlaybackPositionTests),
    TestGroup(name: "players", summary: "播放器身份 / 信任列表 / 播放模式 / 多选 / 广告判据 / 健康徽标", run: runPlayerIdentityTests),
    TestGroup(name: "lastfm", summary: "Last.fm:第 N 次听 / 写法族 / 分页 / 计次规则 / 最近记录 feed", run: runLastfmTests),
    TestGroup(name: "cover-art", summary: "封面取图 / 取色", run: runCoverArtTests),
    TestGroup(name: "menu-bar", summary: "菜单栏跑马灯 / 逐字染色 / 进度图标", run: runMenuBarTests),
    TestGroup(name: "overlay", summary: "桌面悬浮歌词 / 歌词窗口的几何与命中测试", run: runOverlayTests),
    TestGroup(name: "notch", summary: "灵动岛:展开区 / 音浪包络", run: runNotchTests),
    TestGroup(name: "idle-page", summary: "停播页:第 N 次听换算 / 收听总览 / 选句 / 平台链接", run: runIdlePageTests),
    TestGroup(name: "settings-ui", summary: "设置页交互纯逻辑:顺序优先列表拖拽排序(滞回 / 让位 / 写回)", run: runSettingsInteractionTests),
    TestGroup(name: "contracts", summary: "跨文件契约(多数靠 #filePath 扫源码文本):设置页分段 / 本地化 / 滑杆 / 封面口径 / 灵动岛对齐 / 引导页", run: runSourceContractTests),
    TestGroup(name: "ops-diagnostics", summary: "诊断脱敏 / 备份发现 / 导入策略 / 安全写文件 / launchd / 进程", run: runOpsDiagnosticsTests),
]

// ---- 参数 ----

let usage = """
用法: lyrimuse-selftest [--filter <组名子串>]... [--quiet] [--list]
  --filter, -f <子串>   只跑组名包含该子串的组(不区分大小写;可重复)
  --quiet,  -q          不打 ok 行,只留 FAIL 与每组一行汇总
  --list,   -l          列出所有组后退出
  --help,   -h          本说明
"""

var filters: [String] = []
var listOnly = false
var badArgument: String?
var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIterator.next() {
    switch arg {
    case "--quiet", "-q":
        quietOutput = true
    case "--list", "-l":
        listOnly = true
    case "--help", "-h":
        print(usage)
        exit(0)
    case "--filter", "-f":
        if let value = argIterator.next(), !value.isEmpty {
            filters.append(value)
        } else {
            badArgument = arg
        }
    default:
        if arg.hasPrefix("--filter="), arg.count > "--filter=".count {
            filters.append(String(arg.dropFirst("--filter=".count)))
        } else {
            badArgument = arg
        }
    }
}
if let bad = badArgument {
    fputs("lyrimuse-selftest: 参数不认识或缺值: \(bad)\n\(usage)\n", stderr)
    exit(2)
}
if listOnly {
    for group in groups {
        print("\(group.name)\t\(group.summary)")
    }
    exit(0)
}

let selected = filters.isEmpty
    ? groups
    : groups.filter { group in filters.contains { group.name.range(of: $0, options: .caseInsensitive) != nil } }
if selected.isEmpty {
    fputs("lyrimuse-selftest: --filter \(filters) 没有匹配到任何组;用 --list 看全部组名。\n", stderr)
    exit(2)
}

// ---- 注册表守卫 ----
//
// 目录里每一个 `func run…Tests()` 都必须在上面的 groups 里被引用。漏注册的组编译照过、
// 一条断言都不跑、输出里也看不出少了什么 —— 这是拆多文件之后唯一新增的坑,所以用文本扫描
// 钉死(跟本地化守卫同一路数:#filePath 定位本目录,读不到就 FAIL 而不是静默跳过)。
do {
    let selfPath = #filePath
    let dir = URL(fileURLWithPath: selfPath).deletingLastPathComponent()
    let definePattern = try! NSRegularExpression(pattern: #"func (run[A-Za-z0-9_]+Tests)\(\)"#)
    let referencePattern = try! NSRegularExpression(pattern: #"\brun[A-Z][A-Za-z0-9_]*Tests\b"#)
    func matches(_ pattern: NSRegularExpression, in text: String, group: Int) -> [String] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: group)) }
    }
    var defined: [String] = []
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    for name in names where name.hasSuffix(".swift") && name != "main.swift" {
        guard let text = try? String(contentsOfFile: dir.appendingPathComponent(name).path, encoding: .utf8) else { continue }
        defined += matches(definePattern, in: text, group: 1)
    }
    let mainText = (try? String(contentsOfFile: selfPath, encoding: .utf8)) ?? ""
    let referenced = Set(matches(referencePattern, in: mainText, group: 0))
    expectEqual(defined.isEmpty, false, "注册表守卫: 本目录能扫到 run…Tests() 定义(扫不到 = 目录挪了或正则失效)")
    expectEqual(defined.filter { !referenced.contains($0) }, [], "注册表守卫: 每个 run…Tests() 都在 main.swift 的 groups 里注册了")
    expectEqual(groups.count, defined.count, "注册表守卫: 注册的组数等于定义的组数(重复注册会在这里露出来)")
}

// ---- 逐组运行 + 汇总 ----

let runStarted = Date()
for group in selected {
    let assertionsBefore = assertions
    let failuresBefore = failures
    let started = Date()
    // 顶层代码在这个包的语言模式下不是主 actor 上下文,直接调 @MainActor 函数编不过;selftest
    // 只有主线程,所以在这里断言一次「就在主 actor 上」再调,跟各组里原有的 MainActor.assumeIsolated 同一路数。
    MainActor.assumeIsolated { group.run() }
    let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
    let failed = failures - failuresBefore
    print("## \(group.name): \(assertions - assertionsBefore) 条断言\(failed == 0 ? "" : ", \(failed) 条 FAIL"), \(elapsedMs) ms")
}
let totalMs = Int(Date().timeIntervalSince(runStarted) * 1000)
let scope = filters.isEmpty ? "\(groups.count) 组" : "\(selected.count)/\(groups.count) 组(--filter \(filters.joined(separator: ",")))"
let passed = failures == 0
if passed {
    print("\n\(scope) · \(assertions) 条断言 · \(totalMs) ms · ALL PASS")
} else {
    print("\n\(scope) · \(assertions) 条断言 · \(failures) FAILURE(S)")
}
exit(passed ? 0 : 1)
