import LyrimuseCore
import Foundation

// 诊断脱敏 / 备份发现 / 导入策略 / 安全写文件 / launchd / 进程。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runOpsDiagnosticsTests() {
    // ---- LogRedactor(诊断包脱敏) ----
    //
    // 这一组断言守的是一条会被贴进公开 GitHub issue 的输出:2026-08-13 实测坐实,诊断报告
    // 末尾附的 collector 日志里带着 Last.fm API Key 原文。用例全部是合成的假密钥。
    do {
        print("\n== 诊断日志脱敏 ==")
        typealias R = LogRedactor
        // 用例里的"密钥"都是合成串,长度贴着真实凭据(32/36/48)。
        let apiKey = "0123456789abcdef0123456789abcdef"
        let relayToken = "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT"
        let secrets = ["lastfmScrobbleAPIKey": apiKey, "stateRelayToken": relayToken]

        // 实测泄露的那一行的形状:Go *url.Error 把完整 URL 带进错误文本。
        let leaky = "2026/08/13 10:00:05 lastfmRecent: request failed: Get "
            + "\"https://ws.audioscrobbler.com/2.0/?method=user.getrecenttracks&user=someone&api_key=\(apiKey)\""
        let cleaned = R.redactAll(leaky, secrets: secrets)
        expectEqual(cleaned.contains(apiKey), false, "值级脱敏:日志里的 API Key 原文必须消失")
        expectEqual(cleaned.contains("<redacted:lastfmScrobbleAPIKey>"), true,
                    "脱敏后要留下字段名,排查时才知道那里原本是哪一项")
        expectEqual(cleaned.contains("user=someone"), true, "非敏感参数(用户名)要原样保留,否则报告没法读")
        expectEqual(cleaned.contains("audioscrobbler.com"), true, "host 要保留")

        // 第二层:配置里已经没有这把旧 key 了(用户换过),值级脱敏命中不了,靠正则兜住。
        let rotated = "Get \"https://ws.audioscrobbler.com/2.0/?api_key=deadbeefdeadbeefdeadbeefdeadbeef\""
        expectEqual(R.redactAll(rotated, secrets: [:]).contains("deadbeef"), false,
                    "模式级脱敏:配置里已不存在的旧 key 也要打掉")

        // Bark 的 device key 长在 URL path 里,不是 query 参数——这是 alerter.go 那条尚未
        // 触发的同形状风险,两层都要能兜住。
        let bark = "notify push failed (platform=bark): Post \"https://api.day.app/SECRETDEVICEKEY123/t/b\": timeout"
        expectEqual(R.redactAll(bark, secrets: [:]).contains("SECRETDEVICEKEY123"), false,
                    "路径型凭据(Bark device key)必须打掉")
        expectEqual(R.redactAll(bark, secrets: [:]).contains("api.day.app"), true, "Bark 的 host 保留")

        // 互为子串的两个凭据:必须先替换长的,否则长的会被切碎、漏出一截原文。
        let nested = "a=\(relayToken) b=\(relayToken + "SUFFIX")"
        let both = R.redact(nested, secrets: ["short": relayToken, "long": relayToken + "SUFFIX"])
        expectEqual(both.contains("SUFFIX"), false, "长短凭据互为前缀时,长的不能被切碎留下尾巴")

        // 过短的配置值不参与字面替换,否则普通日志词会被打成马赛克。
        let short = R.redact("platform=bark and the bark failed", secrets: ["notificationPlatform": "bark"])
        expectEqual(short.contains("bark and the bark"), true, "过短的配置值不该参与值级替换")

        expectEqual(R.redactAll("nothing sensitive here", secrets: secrets),
                    "nothing sensitive here", "干净的行原样返回")
    }

    // 真机端到端校验:拿**这台机器上真实的** config.json + 真实的 collector 日志跑一遍,
    // 断言脱敏后没有任何一个真实凭据残留。默认不跑 —— 它要读用户的真实密钥,跟
    // lyrimuse-collector 的 simeval_test.go 用 SIMEVAL_DATA 把真实曲库 gate 住是同一个模式。
    // 跑法:LYRIMUSE_REDACT_CHECK=1 swift run lyrimuse-selftest
    // 全程只做比对,绝不打印任何密钥值(连长度以外的信息都不打)。

    // ---- BackupDiscovery(跨目录找最新备份) ----
    //
    // 这是"换新 Mac 能不能一键恢复"的唯一入口,而它只在换机器时走一次、出错时没有现场可看,
    // 所以用真实的临时目录做一次端到端。2026-08-13 用户问出的洞就在这条路上:备份放在
    // Dropbox 的人,新机器上 UserDefaults 是空的、当前设置必然指向 iCloud,只按当前设置找
    // 就什么都找不到。
    do {
        print("\n== 跨目录探测备份 ==")
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("lyrimuse-backup-probe-\(ProcessInfo.processInfo.processIdentifier)")
        let iCloudish = root.appendingPathComponent("iCloudish/Lyrimuse")
        let dropboxish = root.appendingPathComponent("Dropboxish/Lyrimuse")
        let empty = root.appendingPathComponent("NothingHere/Lyrimuse")
        defer { try? fm.removeItem(at: root) }

        try? fm.createDirectory(at: iCloudish, withIntermediateDirectories: true)
        try? fm.createDirectory(at: dropboxish, withIntermediateDirectories: true)
        try? fm.createDirectory(at: empty, withIntermediateDirectories: true)

        let older = iCloudish.appendingPathComponent("Lyrimuse-Config-2026-08-01-120000.json")
        let newer = dropboxish.appendingPathComponent("Lyrimuse-Config-2026-08-13-160000.json")
        try? Data("{}".utf8).write(to: older)
        try? Data("{}".utf8).write(to: newer)
        // 显式钉住修改时间,不靠"写入顺序恰好决定 mtime"这种巧合。
        try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: older.path)
        try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000)], ofItemAtPath: newer.path)

        // 候选顺序刻意把"当前设置指向的目录"(iCloudish)排在前面 —— 命中的必须是更新的那份,
        // 而不是排在前面的那份。
        let hit = BackupDiscovery.latest(in: [iCloudish, empty, dropboxish])
        expectEqual(hit?.url.lastPathComponent, "Lyrimuse-Config-2026-08-13-160000.json",
                    "跨目录要取最新的那份,不是候选列表里排最前的")
        expectEqual(hit?.folder.lastPathComponent, "Lyrimuse", "要报出它所在的目录")
        expectEqual(hit?.folder.path, dropboxish.path, "目录必须是真正命中的那个(用于导入后对齐备份位置)")

        // 不存在的目录必须被跳过而不是让整次探测失败 —— 探测要翻好几个候选,大部分机器上
        // 大部分候选都不存在,那是常态。
        let missing = root.appendingPathComponent("DoesNotExist/Lyrimuse")
        let hit2 = BackupDiscovery.latest(in: [missing, iCloudish])
        expectEqual(hit2?.url.lastPathComponent, "Lyrimuse-Config-2026-08-01-120000.json",
                    "候选里夹着不存在的目录时,其余目录照样要扫到")

        expectEqual(BackupDiscovery.latest(in: [empty, missing]) == nil, true, "都没有备份时返回 nil")

        // 目录里的无关文件不能被当成备份(认名规则归 ConfigSnapshotName,那边另有覆盖)。
        try? Data("{}".utf8).write(to: empty.appendingPathComponent("notes.txt"))
        try? Data("{}".utf8).write(to: empty.appendingPathComponent("other.json"))
        expectEqual(BackupDiscovery.latest(in: [empty]) == nil, true, "无关文件不算备份")
    }

    // ---- ImportPolicy(外来配置里的 relay 地址) ----
    //
    // 守的是"备份文件夹可以指向共享目录"之后新出现的那条路径:目录里的文件成了导入源,而
    // state_relay_url 决定收听状态和 relay token 往哪台服务器发。
    do {
        print("\n== 导入配置的地址校验 ==")
        typealias P = ImportPolicy
        expectEqual(P.isAcceptableRelayURL("https://np.yudaotor.me"), true, "https 放行")
        expectEqual(P.isAcceptableRelayURL("https://np.yudaotor.me/"), true, "https 带斜杠放行")
        expectEqual(P.isAcceptableRelayURL("  https://np.yudaotor.me  "), true, "两侧空白要先 trim")
        expectEqual(P.isAcceptableRelayURL("http://attacker.example.com"), false,
                    "明文 http 发到公网必须拒绝(token 会跟着请求头一起走)")
        expectEqual(P.isAcceptableRelayURL("http://localhost:8787"), true, "本地调试放行")
        expectEqual(P.isAcceptableRelayURL("http://127.0.0.1:8787"), true, "回环 IP 放行")
        expectEqual(P.isAcceptableRelayURL("file:///etc/passwd"), false, "file: 拒绝")
        expectEqual(P.isAcceptableRelayURL("javascript:alert(1)"), false, "自定义 scheme 拒绝")
        expectEqual(P.isAcceptableRelayURL("np.yudaotor.me"), false, "没有 scheme 的裸 host 拒绝")
        expectEqual(P.isAcceptableRelayURL("https://"), false, "有 scheme 但没 host 拒绝")
        expectEqual(P.isAcceptableRelayURL(""), false, "空串在这里判 false,由调用方先行区分'没配置'")
    }

    // ---- writeSecurely(含凭据的文件必须落成 0600) ----
    do {
        print("\n== 凭据文件权限 ==")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrimuse-selftest-perm-\(ProcessInfo.processInfo.processIdentifier).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 先用普通 .atomic 写一次,证明默认权限确实是松的 —— 不然这条断言可能只是在
        // 复述当前 umask 恰好是什么。
        try? Data("{}".utf8).write(to: tmp, options: .atomic)
        let plain = ((try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.posixPermissions]
            as? NSNumber)?.intValue ?? -1
        print("  普通 .atomic 写入的权限: \(String(plain, radix: 8))")

        try? FileManager.default.removeItem(at: tmp)
        try? Data("{}".utf8).writeSecurely(to: tmp)
        let secure = ((try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.posixPermissions]
            as? NSNumber)?.intValue ?? -1
        expectEqual(secure, 0o600, "writeSecurely 落地的文件必须是 0600(实测普通写入是 \(String(plain, radix: 8)))")

        // 覆盖写一次:.atomic 换的是新 inode,权限得重新收紧,不能只在首次创建时对。
        try? Data("{\"a\":1}".utf8).writeSecurely(to: tmp)
        let rewritten = ((try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.posixPermissions]
            as? NSNumber)?.intValue ?? -1
        expectEqual(rewritten, 0o600, "覆盖写之后权限仍须是 0600(.atomic 会换掉 inode)")
    }

    if ProcessInfo.processInfo.environment["LYRIMUSE_REDACT_CHECK"] == "1" {
        print("\n== 诊断脱敏真机校验 ==")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cfgURL = home.appendingPathComponent(".config/lyrimuse/config.json")
        let logURL = home.appendingPathComponent("Library/Logs/lyrimuse.log")

        guard let cfgData = try? Data(contentsOf: cfgURL),
              let cfg = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any],
              let logText = try? String(contentsOf: logURL, encoding: .utf8) else {
            failures += 1
            print("FAIL - 读不到真实 config.json 或日志,校验没跑成")
            exit(1)
        }

        // DiagnosticsExporter.recentCollectorLogLines(limit: 200) 复制的就是这个窗口。
        let window = logText.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init).suffix(200).joined(separator: "\n")

        // 只挑真正是凭据的字段,跟 ConfigStore.secretsForRedaction 的取舍保持一致。
        let credentialFields = ["listenbrainz_token", "state_relay_token", "lastfm_api_key",
                                "lastfm_scrobble_api_key", "lastfm_scrobble_secret",
                                "lastfm_scrobble_session_key", "bark_url",
                                "dingtalk_sign_secret", "feishu_sign_secret"]
        var secrets: [String: String] = [:]
        for f in credentialFields {
            if let v = cfg[f] as? String, !v.isEmpty { secrets[f] = v }
        }

        let before = secrets.filter { window.contains($0.value) }
        let cleaned = LogRedactor.redactAll(window, secrets: secrets)
        let after = secrets.filter { cleaned.contains($0.value) }

        print("  真实凭据字段数: \(secrets.count)")
        print("  脱敏前出现在导出窗口里的: \(before.count) 项 -> \(before.keys.sorted())")
        expectEqual(after.count, 0, "脱敏后不得有任何真实凭据残留(残留项: \(after.keys.sorted()))")
    }

    // ---- LaunchdPrintParser ----
    //
    // 样本取自 2026-08-15 在真机上抓的 `launchctl print gui/<uid>/<label>` 实际输出(见
    // LaunchdJobState 里那张三态表),只保留跟解析有关的行。
    do {
        // 真实输出里同时有这三种行,后两种都是**陷阱**:
        //   \t\tstate = active     嵌套在子结构里,不是 job 状态
        //   \tjob state = running  同一层缩进,但是另一个字段
        let runningOutput = """
        gui/502/com.lyrimuse.collector = {
        \tactive count = 1
        \tstate = running
        \tpid = 82285
        \tlast exit code = 0
        \tspawn type = daemon
        \tendpoints = {
        \t\t"com.example.socket" = {
        \t\t\tstate = active
        \t\t}
        \t}
        \tjob state = running
        }
        """
        expectEqual(LaunchdPrintParser.parse(printExitCode: 0, printOutput: runningOutput),
                    .running(pid: 82285), "Launchd: 在跑 → running(pid)")

        // 这就是原来那个 bug 的形状:退出码同样是 0,但进程根本不在。
        let notRunningOutput = """
        gui/502/com.lyrimuse.collector = {
        \tactive count = 0
        \tstate = not running
        \tlast exit code = 78
        }
        """
        expectEqual(LaunchdPrintParser.parse(printExitCode: 0, printOutput: notRunningOutput),
                    .registeredNotRunning(lastExitCode: 78),
                    "Launchd: 注册了但没在跑 → 带上次退出码,不能当成在跑")

        // launchd 真正报退出码时带 sysexits 助记名:`78: EX_CONFIG`。实测抓到的形态,
        // 直接 Int32(...) 会返回 nil 把退出码吞掉。
        let exitCodeWithName = "gui/502/x = {\n\tstate = not running\n\truns = 1\n\tlast exit code = 78: EX_CONFIG\n}"
        expectEqual(LaunchdPrintParser.parse(printExitCode: 0, printOutput: exitCodeWithName),
                    .registeredNotRunning(lastExitCode: 78),
                    "Launchd: `78: EX_CONFIG` 要解析出 78,不能吞掉")

        // launchd 对没退出过的 job 写的是 `(never exited)`,不是数字。
        let neverExited = "gui/502/x = {\n\tstate = not running\n\tlast exit code = (never exited)\n}"
        expectEqual(LaunchdPrintParser.parse(printExitCode: 0, printOutput: neverExited),
                    .registeredNotRunning(lastExitCode: nil),
                    "Launchd: (never exited) 解析成 nil 而不是 0")

        // print 对未注册的 job 返回 113。
        expectEqual(LaunchdPrintParser.parse(printExitCode: 113, printOutput: ""),
                    .notRegistered, "Launchd: 未注册 → notRegistered")

        // 陷阱一:只有嵌套的 state,顶层没有 —— 不能被当成 job 状态。
        let nestedOnly = "gui/502/x = {\n\tendpoints = {\n\t\tstate = active\n\t}\n}"
        expectEqual(LaunchdPrintParser.parse(printExitCode: 0, printOutput: nestedOnly),
                    .unknown, "Launchd: 嵌套的 state = active 不能被当成 job 状态")

        // 陷阱二:`job state` 跟 `state` 同一层缩进,前缀却不同 —— contains 会误判。
        let jobStateOnly = "gui/502/x = {\n\tjob state = running\n}"
        expectEqual(LaunchdPrintParser.parse(printExitCode: 0, printOutput: jobStateOnly),
                    .unknown, "Launchd: job state 不是 state,不能误认成在跑")

        // 认不出来就说认不出来,不要假装知道它没在跑。
        expectEqual(LaunchdPrintParser.parse(printExitCode: 0, printOutput: "完全不认识的输出"),
                    .unknown, "Launchd: 读不懂的输出 → unknown,不塌缩成未运行")

        expectEqual(LaunchdJobState.running(pid: 1).isRunning, true, "Launchd: running.isRunning")
        expectEqual(LaunchdJobState.registeredNotRunning(lastExitCode: 78).isRunning, false,
                    "Launchd: 注册但没跑 isRunning=false")
        expectEqual(LaunchdJobState.unknown.isRunning, false, "Launchd: unknown 不算在跑")
    }

    // ---- ProcessRunner ----
    //
    // 跑真实子进程（/bin/echo、/bin/sleep、/usr/bin/yes），不是合成数据 —— 这里要验证的
    // 恰恰是跟真实进程/管道打交道时的行为。
    do {
        // 正常命令。
        let hello = ProcessRunner.run("/bin/echo", ["hello"], timeout: 5)
        expectEqual(hello?.status, 0, "ProcessRunner: 正常命令退出码 0")
        expectEqual(hello?.stdoutText, "hello\n", "ProcessRunner: 拿得到 stdout")
        expectEqual(hello?.timedOut, false, "ProcessRunner: 正常命令没有超时")
        expectEqual(hello?.succeeded, true, "ProcessRunner: succeeded")

        // 非零退出：跑了但失败，跟"没跑起来"是两回事。
        let failed = ProcessRunner.run("/bin/sh", ["-c", "exit 3"], timeout: 5)
        expectEqual(failed?.status, 3, "ProcessRunner: 非零退出码如实返回")
        expectEqual(failed?.succeeded, false, "ProcessRunner: 非零退出不算成功")

        // 可执行文件不存在 → nil（"根本没起来"），不是 status 非零。
        expectEqual(ProcessRunner.run("/nonexistent/binary", [], timeout: 5) == nil, true,
                    "ProcessRunner: 起不来的命令返回 nil")

        // 超时：这是这个类型存在的全部理由。
        // 不加超时的话这一句会等满 10 秒 —— 而 Music.app 卡住时 osascript 会等 60 秒。
        let started = Date()
        let slept = ProcessRunner.run("/bin/sleep", ["10"], timeout: 1)
        let elapsed = Date().timeIntervalSince(started)
        expectEqual(slept?.timedOut, true, "ProcessRunner: 超时的命令标记 timedOut")
        expectEqual(slept?.succeeded, false, "ProcessRunner: 超时不算成功")
        expectEqual(elapsed < 5, true, "ProcessRunner: 超时后立刻返回,不等命令自己跑完")

        // 大输出不能死锁。管道缓冲区 64KB，写满之后子进程会阻塞在 write 上；如果先
        // waitUntilExit 再读管道，两边互相等 —— 这正是各调用点原来那个形状的隐患。
        // 1MB 远超缓冲区。
        let big = ProcessRunner.run("/bin/sh", ["-c", "/usr/bin/yes ABCDEFGH | /usr/bin/head -c 1000000"], timeout: 20)
        expectEqual(big?.stdout.count, 1_000_000, "ProcessRunner: 1MB 输出完整读回,不死锁")
        expectEqual(big?.timedOut, false, "ProcessRunner: 大输出不该触发超时")

        // stderr 不该混进 stdout（丢 nullDevice，也不会因为没人读而把子进程卡住）。
        let noisy = ProcessRunner.run("/bin/sh", ["-c", "/bin/echo out; /bin/echo err >&2"], timeout: 5)
        expectEqual(noisy?.stdoutText, "out\n", "ProcessRunner: stderr 不混进 stdout")

        // 子进程往 stderr 狂写也不能卡住 —— nullDevice 不会满。
        let noisyBig = ProcessRunner.run(
            "/bin/sh", ["-c", "/usr/bin/yes ERRORLINE | /usr/bin/head -c 500000 >&2; /bin/echo done"], timeout: 20)
        expectEqual(noisyBig?.stdoutText, "done\n", "ProcessRunner: stderr 狂写不影响 stdout")
        expectEqual(noisyBig?.timedOut, false, "ProcessRunner: stderr 狂写不该超时")
    }

    // ---- GitHub star 数(「关于」页那个角标的判据) ----
    //
    // 守的是两件会静默坏掉的事:①解析出一个"看起来很确定"的错数字(Last.fm 那边 API key
    // 失效返回 200 + error、不识别就显示 0 scrobble 的翻版);②缓存新鲜度判据被时钟异常
    // 骗住——2026-09-03 同一天 Last.fm 统计那边真栽过:`fresh()` 只算 now - fetchedAt < ttl,
    // fetchedAt 落在未来时差值恒为负、恒判新鲜,数字就永远冻在十几个小时前。
    do {
        print("\n== GitHub star 数 ==")
        typealias G = GitHubStars
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // 解析:只认 stargazers_count 一个字段
        expectEqual(G.parseStarCount(Data(#"{"stargazers_count":5,"forks_count":0}"#.utf8)), 5,
                    "star 解析: 正常响应取 stargazers_count")
        expectEqual(G.parseStarCount(Data(#"{"stargazers_count":0}"#.utf8)), 0,
                    "star 解析: 0 是合法值(新仓库),不该跟解析失败混为一谈")
        expectEqual(G.parseStarCount(Data(#"{"forks_count":3}"#.utf8)), nil,
                    "star 解析: 缺字段 → nil,不是 0")
        expectEqual(G.parseStarCount(Data(#"{"stargazers_count":-1}"#.utf8)), nil,
                    "star 解析: 负数 → nil(宁可不显示也不显示错数字)")
        expectEqual(G.parseStarCount(Data("not json at all".utf8)), nil,
                    "star 解析: 坏 JSON → nil")

        // 新鲜度
        expectEqual(G.shouldRefresh(now: now, fetchedAt: nil, retryNotBefore: nil), true,
                    "star 刷新: 从没取过 → 取")
        expectEqual(G.shouldRefresh(now: now, fetchedAt: now.addingTimeInterval(-60), retryNotBefore: nil), false,
                    "star 刷新: 一分钟前刚取过 → 不取")
        expectEqual(G.shouldRefresh(now: now, fetchedAt: now.addingTimeInterval(-G.refreshTTL - 1), retryNotBefore: nil), true,
                    "star 刷新: 超过 TTL → 取")
        expectEqual(G.shouldRefresh(now: now, fetchedAt: now.addingTimeInterval(3600), retryNotBefore: nil), true,
                    "star 刷新: 取数时间在未来(时钟异常)→ 当过期,别让数字永远冻住")
        expectEqual(G.shouldRefresh(now: now, fetchedAt: nil, retryNotBefore: now.addingTimeInterval(60)), false,
                    "star 刷新: 退避期内即使从没取过也不发请求")
        expectEqual(G.shouldRefresh(now: now, fetchedAt: nil, retryNotBefore: now.addingTimeInterval(-1)), true,
                    "star 刷新: 退避期已过 → 取")

        // 限流退避:认 X-RateLimit-Reset,拿不到才退回固定退避
        expectEqual(G.retryDate(now: now, rateLimitReset: "\(Int(now.timeIntervalSince1970) + 120)"),
                    now.addingTimeInterval(120),
                    "star 退避: 按 X-RateLimit-Reset 定下次重试时刻")
        expectEqual(G.retryDate(now: now, rateLimitReset: nil), now.addingTimeInterval(G.failureBackoff),
                    "star 退避: 没有 X-RateLimit-Reset → 固定退避")
        expectEqual(G.retryDate(now: now, rateLimitReset: "garbage"), now.addingTimeInterval(G.failureBackoff),
                    "star 退避: 头解析不出 → 固定退避")
        expectEqual(G.retryDate(now: now, rateLimitReset: "1"), now.addingTimeInterval(G.failureBackoff),
                    "star 退避: 重置点已经过去 → 固定退避,不是立刻重试")
    }
}
