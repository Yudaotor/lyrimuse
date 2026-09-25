import LyrimuseCore
import Foundation

// 诊断脱敏 / 备份发现 / 导入策略 / 安全写文件 / launchd / 进程。
// 由 main.swift 的注册表按组调用;往这一组加断言就写进下面这个函数体里(顺序执行,失败只计
// 数不中断)。要开新的一组见 main.swift 顶部说明。

@MainActor
func runOpsDiagnosticsTests() {
    // ---- LogRedactor(诊断包脱敏) ----
    //
    // 这一组断言守的是一条会被贴进公开 GitHub issue 的输出:实测坐实,诊断报告
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
    // 所以用真实的临时目录做一次端到端。这条路上有个洞:备份放在
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

        // sanitizedConfig:地址不合规时连 token 一起清,其余字段一个不动。
        func clean(_ obj: Any) -> (dict: NSDictionary?, dropped: Bool) {
            let r = P.sanitizedConfig(obj)
            return ((r.config as? [String: Any]).map { NSDictionary(dictionary: $0) }, r.droppedRelay)
        }
        let bad = clean(["state_relay_url": "http://attacker.example.com", "state_relay_token": "secret",
                         "api_root": "https://api.example.com", "bundle_ids": ["a", "b"]])
        expectEqual(bad.dropped, true, "导入净化: 不合规地址要报 droppedRelay(调用方记日志)")
        expectEqual(bad.dict, NSDictionary(dictionary: ["state_relay_url": "", "state_relay_token": "",
                                                        "api_root": "https://api.example.com", "bundle_ids": ["a", "b"]]),
                    "导入净化: 地址和 token 一起清空,UI 不管的字段原样保留")
        let good: [String: Any] = ["state_relay_url": "https://np.yudaotor.me", "state_relay_token": "t"]
        expectEqual(clean(good).dropped, false, "导入净化: 合规地址不动")
        expectEqual(clean(good).dict, NSDictionary(dictionary: good), "导入净化: 合规地址连同 token 原样保留")
        for (url, why) in [("", "空串 = 没配置"), ("   ", "只有空白也算没配置")] {
            let r = clean(["state_relay_url": url, "state_relay_token": "t"])
            expectEqual(r.dropped == false && (r.dict?["state_relay_token"] as? String) == "t", true,
                        "导入净化: \(why),token 不清")
        }
        expectEqual(clean(["state_relay_token": "t"]).dropped, false, "导入净化: 没有地址字段不动")
        expectEqual(clean(["state_relay_url": 42, "state_relay_token": "t"]).dropped, false,
                    "导入净化: 地址不是字符串的不管(跟原实现一致)")
        let notDict = P.sanitizedConfig(["x"])
        expectEqual(notDict.droppedRelay == false && (notDict.config as? [String]) == ["x"], true,
                    "导入净化: config 段不是字典的原样返回")
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

    // ---- JSONConfigDocument(共享配置文件三态读写)----
    //
    // 守两条路径:① 磁盘上的文件坏了(语法错 / 顶层不是对象 / 空文件 / 路径是目录)→ 加载判 corrupt、保存
    // **拒绝**、文件字节一字不动;② 写盘失败 → 内存里的字典和状态**不变**。都拿真实的临时目录跑。
    // 原来 ConfigStore 把「不存在」和「坏了」混成一回事,一个 JSON 语法错误之后任何一次保存都会用 14 个空串
    // 覆盖 config.json(凭据全丢)——这一组断言就是不让它回来。
    do {
        print("\n== 配置文件三态读写 ==")
        typealias D = JSONConfigDocument
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("lyrimuse-selftest-cfgdoc-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        func perm(_ url: URL) -> Int {
            ((try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        func isRefused(_ error: Error?) -> Bool {
            if let failure = error as? D.Failure, case .refusedCorruptFile = failure { return true }
            return false
        }

        // ① 不存在 → missing;首次保存允许创建;写完状态推进到 loaded、凭据模式落成 0600。
        let fresh = dir.appendingPathComponent("fresh.json")
        var d1 = D.load(url: fresh)
        expectEqual(d1.state, .missing, "三态: 文件不存在 → missing")
        var err1: Error?
        do { try d1.save(fields: ["listenbrainz_token": "t1"], secure: true) } catch { err1 = error }
        expectEqual(err1 == nil, true, "三态: missing 允许首次创建(\(String(describing: err1)))")
        expectEqual(d1.state, .loaded, "三态: 首次创建成功后状态推进到 loaded")
        expectEqual(perm(fresh), 0o600, "三态: secure 模式落地 0600")
        expectEqual(D.load(url: fresh).raw["listenbrainz_token"] as? String, "t1", "三态: 重新读回是刚写的值")

        // ② 正常文件:未知键原样保留、已知键以本次为准、没给的已知键删掉(遗留迁移字段的语义)。
        let normal = dir.appendingPathComponent("normal.json")
        try? Data(#"{"api_root":"https://x","listenbrainz_token":"old","player":"apple_music"}"#.utf8).write(to: normal)
        var d2 = D.load(url: normal)
        expectEqual(d2.state, .loaded, "三态: 正常文件 → loaded")
        expectEqual(d2.raw["api_root"] as? String, "https://x", "三态: 镜像含 UI 不管的键")
        try? d2.save(fields: ["listenbrainz_token": "new"], knownKeys: ["listenbrainz_token", "player"], secure: false)
        let reread = D.load(url: normal).raw
        expectEqual(reread["api_root"] as? String, "https://x", "合并: 未知键原样保留")
        expectEqual(reread["listenbrainz_token"] as? String, "new", "合并: 已知键覆盖")
        expectEqual(reread["player"] == nil, true, "合并: 本次没给的已知键从文件删掉")
        expectEqual(d2.raw["listenbrainz_token"] as? String, "new", "合并: 写成功后内存镜像同步")
        expectEqual(d2.merging(fields: ["a": 1]).count, 3, "合并: knownKeys 缺省 = 只覆盖给的键,其余全留")

        // ③ 坏 JSON → corrupt;保存抛 refusedCorruptFile;文件字节一字不动;原因里不带文件内容。
        let bad = dir.appendingPathComponent("bad.json")
        let badBytes = Data(#"{"listenbrainz_token": "SECRETTOKENVALUE", oops"#.utf8)
        try? badBytes.write(to: bad)
        var d3 = D.load(url: bad)
        expectEqual(d3.isCorrupt, true, "三态: 坏 JSON → corrupt")
        expectEqual(d3.corruptReason?.contains("SECRETTOKENVALUE") ?? true, false, "三态: 损坏原因不许带出文件内容")
        var err3: Error?
        do { try d3.save(fields: ["listenbrainz_token": ""], secure: true) } catch { err3 = error }
        expectEqual(isRefused(err3), true, "坏文件不覆盖: 保存抛 refusedCorruptFile(\(String(describing: err3)))")
        expectEqual(try? Data(contentsOf: bad), badBytes, "坏文件不覆盖: 拒绝之后文件字节一字不动")
        expectEqual(d3.isCorrupt, true, "坏文件不覆盖: 拒绝之后状态仍是 corrupt")
        expectEqual(perm(bad) == 0o600, false, "坏文件不覆盖: 连权限位都没动(没有走 writeSecurely)")

        // 顶层不是对象 / 空文件 / 路径是目录,都算 corrupt。
        let array = dir.appendingPathComponent("array.json")
        try? Data("[1,2]".utf8).write(to: array)
        expectEqual(D.load(url: array).isCorrupt, true, "三态: 顶层是数组 → corrupt")
        let empty = dir.appendingPathComponent("empty.json")
        try? Data().write(to: empty)
        expectEqual(D.load(url: empty).isCorrupt, true, "三态: 空文件 → corrupt")
        let asDir = dir.appendingPathComponent("dir.json")
        try? fm.createDirectory(at: asDir, withIntermediateDirectories: true)
        expectEqual(D.load(url: asDir).isCorrupt, true, "三态: 路径是目录 → corrupt")
        expectEqual(D.load(url: asDir).state == .missing, false, "三态: 目录不算「不存在」,否则会往目录上写")
        switch D.parseObject(Data("   \n".utf8)) {
        case .success: expectEqual(true, false, "parseObject: 只有空白 → 失败")
        case .failure: expectEqual(true, true, "parseObject: 只有空白 → 失败")
        }
        switch D.parseObject(Data("{}".utf8)) {
        case .success(let obj): expectEqual(obj.isEmpty, true, "parseObject: {} → 空对象")
        case .failure: expectEqual(true, false, "parseObject: {} 必须成功")
        }

        // ④ 写失败不污染内存:目标路径的父目录不存在 → 写盘抛错 → raw / state 不变。secure 与否都要成立。
        for secure in [true, false] {
            let orphan = dir.appendingPathComponent("no-such-dir/orphan.json")
            var d4 = D(url: orphan, raw: ["keep": "me"], state: .loaded)
            var threw = false
            do { try d4.save(fields: ["keep": "changed"], secure: secure) } catch { threw = true }
            expectEqual(threw, true, "写失败不污染内存(secure=\(secure)): 父目录不存在 → 写盘抛错")
            expectEqual(d4.raw["keep"] as? String, "me", "写失败不污染内存(secure=\(secure)): 字典不变")
            expectEqual(d4.state, .loaded, "写失败不污染内存(secure=\(secure)): 状态不变")
        }
        // 目标路径被一个目录占着(清单里那条「LP 的技巧」)同样是写失败。
        var d4b = D(url: asDir, raw: ["keep": "me"], state: .loaded)
        var threw4b = false
        do { try d4b.save(fields: ["keep": "changed"], secure: false) } catch { threw4b = true }
        expectEqual(threw4b, true, "写失败不污染内存: 目标路径是目录 → 写盘抛错")
        expectEqual(d4b.raw["keep"] as? String, "me", "写失败不污染内存: 目录占位时字典不变")

        // 序列化不了(字典里混进 Date)→ notSerializable,文件与内存都不动。
        var d4c = D.load(url: normal)
        var err4c: Error?
        do { try d4c.save(fields: ["when": Date()], secure: false) } catch { err4c = error }
        expectEqual((err4c as? D.Failure) == .notSerializable, true, "写失败不污染内存: 非 JSON 类型 → notSerializable")
        expectEqual(D.load(url: normal).raw["when"] == nil, true, "写失败不污染内存: notSerializable 时文件没动")
        expectEqual(d4c.raw["when"] == nil, true, "写失败不污染内存: notSerializable 时字典没动")

        // ⑤ markCorrupt:对象层面之上判定不可用(字段类型对不上)→ 一样拒绝保存。
        var d5 = D.load(url: normal)
        d5.markCorrupt(reason: "fields do not decode")
        expectEqual(d5.isCorrupt, true, "markCorrupt: loaded → corrupt")
        var err5: Error?
        do { try d5.save(fields: ["a": "b"], secure: false) } catch { err5 = error }
        expectEqual(isRefused(err5), true, "markCorrupt: 之后保存同样拒绝")
        var d5m = D(url: fresh, state: .missing)
        d5m.markCorrupt(reason: "x")
        expectEqual(d5m.state, .missing, "markCorrupt: missing 没有文件可言,不降级")

        // ⑥ 放弃坏文件:挪到旁边(不删、字节原样、带时间戳),状态归 missing,然后能重建;非损坏时是空操作。
        let moved = try? d3.quarantineCorruptFile(now: Date(timeIntervalSince1970: 0))
        expectEqual(moved?.lastPathComponent.hasPrefix("bad.json.corrupt-") ?? false, true,
                    "放弃坏文件: 挪到 <名>.corrupt-<时间戳>(\(moved?.lastPathComponent ?? "nil"))")
        expectEqual(fm.fileExists(atPath: bad.path), false, "放弃坏文件: 原路径上没有文件了")
        expectEqual(moved.flatMap { try? Data(contentsOf: $0) }, badBytes, "放弃坏文件: 挪走的那份字节原样(能手工抢救)")
        expectEqual(d3.state, .missing, "放弃坏文件: 状态归 missing")
        var err6: Error?
        do { try d3.save(fields: ["listenbrainz_token": "rebuilt"], secure: true) } catch { err6 = error }
        expectEqual(err6 == nil, true, "放弃坏文件: 之后能重建")
        expectEqual(D.load(url: bad).raw["listenbrainz_token"] as? String, "rebuilt", "放弃坏文件: 重建的文件读得回来")
        // 同一秒内再放弃一份同名坏文件:不覆盖上一份隔离件。
        try? badBytes.write(to: bad)
        var d6 = D.load(url: bad)
        let moved2 = try? d6.quarantineCorruptFile(now: Date(timeIntervalSince1970: 0))
        expectEqual(moved2 != nil && moved2 != moved, true, "放弃坏文件: 同名隔离件已存在时另起名字,不覆盖")
        var d6ok = D.load(url: normal)
        expectEqual((try? d6ok.quarantineCorruptFile()) ?? nil, nil, "放弃坏文件: 非损坏状态是空操作")
        expectEqual(fm.fileExists(atPath: normal.path), true, "放弃坏文件: 空操作没有动正常文件")
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

        // 导出的是**整份**日志(DiagnosticsExporter.fullCollectorLogText),所以这里也拿整份验。
        // 原来只验最后 200 行 —— 那是当年那个导出窗口的形状,而凭据可能出现在任何一行:
        // 泄漏过的那几处 Last.fm API Key 来自 Go *url.Error 打印完整 URL,随便哪次请求失败都会写一行。
        let window = logText

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

        // 上面那条如今多半是**空转**的:collector 侧的 logscrub 已经把凭据挡在日志之外,
        // 实测整份 3MB 日志里 0 项真实凭据。输入里本来就没有,它答不了"脱敏到底生没生效"。
        //
        // 所以再注入一次。LogRedactor 是纵深的第二道(见它的头注),不能因为第一道目前有效
        // 就不验它 —— 真出问题的那天恰恰是第一道漏了的那天,而那正是这一道存在的理由。
        if !secrets.isEmpty {
            let injected = window + "\n" + secrets
                .map { "time=2026-01-01T00:00:00.000Z level=WARN msg=\"probe \($0.key)=\($0.value)\"" }
                .joined(separator: "\n")
            let leaked = secrets.filter { LogRedactor.redactAll(injected, secrets: secrets).contains($0.value) }
            expectEqual(leaked.count, 0, "注入的真实凭据必须被出口这一层打掉(残留项: \(leaked.keys.sorted()))")
        }
    }

    // ---- LaunchdPrintParser ----
    //
    // 样本取自在真机上抓的 `launchctl print gui/<uid>/<label>` 实际输出(见
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
        // environment:不传 = 继承本进程;传了 = 子进程只有这一份。
        // 这个参数是「待补提交删除按钮点了没反应」那个 bug 的修法,值得有行为断言而不是
        // 只靠调用点的注释。
        let inherited = ProcessRunner.run("/bin/sh", ["-c", "echo \"[$LYRIMUSE_SELFTEST_ENV]\""], timeout: 5)
        expectEqual(inherited?.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), "[]",
                    "ProcessRunner: 不传 environment 时继承本进程(这个变量本来就没有 → 空)")
        let explicit = ProcessRunner.run(
            "/bin/sh", ["-c", "echo \"[$LYRIMUSE_SELFTEST_ENV]\""], timeout: 5,
            environment: ["LYRIMUSE_SELFTEST_ENV": "on"])
        expectEqual(explicit?.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), "[on]",
                    "ProcessRunner: 传了 environment 就真的传进子进程")

        let failed = ProcessRunner.run("/bin/sh", ["-c", "exit 3"], timeout: 5)
        expectEqual(failed?.status, 3, "ProcessRunner: 非零退出码如实返回")
        expectEqual(failed?.succeeded, false, "ProcessRunner: 非零退出不算成功")

        // stderr:默认不接(空),显式要了才接得到。
        //
        // 这不是可有可无的开关 —— media-control 的 `test` 失败时 stdout 全空、原因只写在
        // stderr 上,不接那根管子界面上就只剩一句「exit status 4」(真的发生过)。
        let quiet = ProcessRunner.run("/bin/sh", ["-c", "echo oops >&2; exit 4"], timeout: 5)
        expectEqual(quiet?.stderrText, "", "ProcessRunner: 默认不接 stderr —— 空,不是子进程没写")
        let loud = ProcessRunner.run("/bin/sh", ["-c", "echo oops >&2; exit 4"], timeout: 5,
                                     captureStderr: true)
        expectEqual(loud?.stderrText, "oops\n", "ProcessRunner: captureStderr 真的把 stderr 接出来了")
        expectEqual(loud?.status, 4, "ProcessRunner: 接了 stderr 不影响退出码")

        // 两根管子必须并发读空。这一句往 stderr 灌 256KB(远超 64KB 管道缓冲区):
        // 串行读的写法会在这里死锁,超时杀进程之后 stderr 也收不全。
        let flood = ProcessRunner.run(
            "/bin/sh", ["-c", "/usr/bin/head -c 262144 /dev/zero | /usr/bin/tr '\\0' 'x' >&2; echo done"],
            timeout: 10, captureStderr: true)
        expectEqual(flood?.timedOut, false, "ProcessRunner: stderr 灌满管道也不会卡死(两根管子并发读)")
        expectEqual(flood?.stdoutText, "done\n", "ProcessRunner: stderr 灌满时 stdout 照样完整")
        expectEqual(flood?.stderr.count, 262144, "ProcessRunner: 大块 stderr 一字节不少")

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

    // ---- BlockingCallGate(可能永久阻塞的同步调用) ----
    //
    // 自动化权限查询(AEDeterminePermissionToAutomateTarget)会无限期不返回,见 02 章决策 8。
    // 这里用一个等信号量的闭包模拟"卡死",钉住三件事:超时照样按时回来、同一个 key 不会
    // 因为反复请求越占越多线程、卡住的调用最终返回时还在等的人拿得到结果。
    do {
        print("\n== 阻塞调用闸门 ==")
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func bump() { lock.lock(); n += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        final class Slot: @unchecked Sendable {
            let done = DispatchSemaphore(value: 0)
            var value: Int?
        }
        let gate = BlockingCallGate<String, Int>(label: "selftest.blocking-call-gate")
        let release = DispatchSemaphore(value: 0)
        let calls = Counter()
        let stuck: @Sendable () -> Int = { calls.bump(); release.wait(); return 42 }
        func ask(_ key: String, timeout: TimeInterval, _ work: @escaping @Sendable () -> Int) -> Slot {
            let slot = Slot()
            gate.run(key: key, timeout: timeout, work: work) { slot.value = $0; slot.done.signal() }
            return slot
        }

        let started = Date()
        let first = ask("a", timeout: 0.2, stuck)
        let firstReturned = first.done.wait(timeout: .now() + 3) == .success
        expectEqual(firstReturned, true, "闸门: 调用卡住时,等待者按超时返回")
        expectEqual(first.value, nil, "闸门: 超时的等待者拿到 nil")
        expectEqual(Date().timeIntervalSince(started) < 2, true, "闸门: 超时不陪卡住的调用一起等")
        expectEqual(gate.isInFlight("a"), true, "闸门: 等待者超时后,底下那次调用仍记为在飞")

        let second = ask("a", timeout: 0.2, stuck)
        _ = second.done.wait(timeout: .now() + 3)
        expectEqual(second.value, nil, "闸门: 在飞期间再请求同一个 key,同样按超时返回")
        expectEqual(calls.value, 1, "闸门: 同一个 key 在飞时不另起调用(不会越卡越多线程)")

        let other = ask("b", timeout: 2) { 7 }
        _ = other.done.wait(timeout: .now() + 3)
        expectEqual(other.value, 7, "闸门: 一个 key 卡住不挡别的 key")

        let late = ask("a", timeout: 5, stuck)
        release.signal()
        _ = late.done.wait(timeout: .now() + 3)
        expectEqual(late.value, 42, "闸门: 卡住的调用返回时,还在等的人拿到它的结果")
        expectEqual(calls.value, 1, "闸门: 挂在在飞调用后面的请求不会自己再调一次")

        let fresh = ask("a", timeout: 2) { calls.bump(); return 9 }
        _ = fresh.done.wait(timeout: .now() + 3)
        expectEqual(fresh.value, 9, "闸门: 调用返回之后,同一个 key 的下一次请求重新发起")
        expectEqual(gate.isInFlight("a"), false, "闸门: 没有调用在飞时 isInFlight 为 false")
    }

    // ---- GitHub star 数(「关于」页那个角标的判据) ----
    //
    // 守的是两件会静默坏掉的事:①解析出一个"看起来很确定"的错数字(Last.fm 那边 API key
    // 失效返回 200 + error、不识别就显示 0 scrobble 的翻版);②缓存新鲜度判据被时钟异常
    // 骗住——同一天 Last.fm 统计那边真栽过:`fresh` 只算 now - fetchedAt < ttl,
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

    // ---- CollectorLogLine / LogFiles(collector 日志时间戳的两种格式)----
    //
    // collector 换 log/slog 之后每行以 `time=…Z` 开头;.old 归档与迁移前的行仍是 Go log
    // 的 `yyyy/MM/dd HH:mm:ss`(UTC 无标记)。诊断导出按时间窗口取日志靠它找起点,两种都要认、
    // 都按 UTC 解 —— 老格式按本地时间解会把 4 小时窗口整体错开 8 小时,导出里就是一片空。
    do {
        print("\n== collector 日志时间戳 ==")
        var comps = DateComponents()
        comps.timeZone = TimeZone(identifier: "UTC")
        comps.year = 2026; comps.month = 9; comps.day = 5; comps.hour = 1; comps.minute = 2; comps.second = 3
        let cal = Calendar(identifier: .gregorian)
        let expectedSlog = cal.date(from: comps)!.addingTimeInterval(0.456)
        let gotSlog = CollectorLogLine.timestamp(of: "time=2026-09-05T01:02:03.456Z level=INFO msg=\"api call summary\" count=12")
        expectEqual(gotSlog.map { abs($0.timeIntervalSince(expectedSlog)) < 0.001 } ?? false, true,
                    "collector 时间戳: slog 格式按 UTC 解析到毫秒")
        comps.day = 4; comps.hour = 15; comps.minute = 49; comps.second = 15
        expectEqual(CollectorLogLine.timestamp(of: "2026/09/04 15:49:15 api call: GET ws.audioscrobbler.com/2.0/ -> 200 (315ms)"),
                    cal.date(from: comps), "collector 时间戳: 老格式按 UTC 解析(不是本地时间)")
        expectEqual(CollectorLogLine.timestamp(of: "Bootstrap failed: 5: Input/output error") == nil, true,
                    "collector 时间戳: 外部 stderr 漏进来的行没有时间戳 → nil")
        expectEqual(CollectorLogLine.timestamp(of: "time=garbage level=INFO msg=x") == nil, true,
                    "collector 时间戳: time= 后不是合法时间 → nil")
        expectEqual(CollectorLogLine.timestamp(of: "") == nil, true, "collector 时间戳: 空行 → nil")
        expectEqual(CollectorLogLine.timestamp(of: "2026/09/04 15:49") == nil, true, "collector 时间戳: 老格式截短 → nil 不崩")
        expectEqual(LogFiles.appStderr.lastPathComponent, "lyrimuse-app.log", "日志文件: App stderr 单独一份")
        expectEqual(LogFiles.collector.lastPathComponent, "lyrimuse.log", "日志文件: collector 日志路径不变")
    }

    // ---- CrashReportSummary(诊断导出的崩溃报告段)----
    //
    // .ips = 摘要行 JSON + 正文 JSON。三种样本照本机真实报告的形状写:启动期 DYLD 缺库(零帧,信息全在
    // termination)、另一个同名包里 collector 的签名约束、带 20 帧的 EXC_BAD_ACCESS(截成 15)。再钉宽容解析、归属判定
    // (本 App / 另一个同名包 / 别家 collector)与每进程限量挑选。bundle id 与包名一律从 LyrimuseIdentity 取,不写字面量。
    do {
        print("\n== 崩溃报告摘要 ==")
        let prod = LyrimuseIdentity.current
        // 另一个同名包(想象中的 nightly 版):用来断言归属判定按 bundle id / 包名把它排除在外。
        let otherName = prod.displayName + " Nightly"
        let otherID = prod.bundleIdentifier + ".nightly"
        func ips(_ header: String, _ body: String) -> Data { (header + "\n" + body).data(using: .utf8)! }

        let dyldHeader = """
        {"app_name":"lyrimuse","timestamp":"2026-08-30 18:33:01.00 +0800","app_version":"1.4.0","build_version":"1.4.0","bug_type":"309","os_version":"macOS 27.0 (26A5416b)","bundleID":"\(prod.bundleIdentifier)","incident_id":"AAAA"}
        """
        let dyldBody = """
        {"procName":"lyrimuse","procPath":"/Applications/\(prod.displayName).app/Contents/MacOS/lyrimuse","bundleInfo":{"CFBundleShortVersionString":"1.4.0","CFBundleVersion":"1.4.0","CFBundleIdentifier":"\(prod.bundleIdentifier)"},"captureTime":"2026-08-30 18:33:01.5 +0800","exception":{"type":"EXC_CRASH","signal":"SIGABRT","codes":"0x0, 0x0"},"termination":{"code":1,"flags":518,"namespace":"DYLD","indicator":"Library missing","details":["(terminated at launch; ignore backtrace)"],"reasons":["Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle","Referenced from: <UUID> /Applications/\(prod.displayName).app/Contents/MacOS/lyrimuse"]},"faultingThread":0,"threads":[{"id":1,"triggered":true,"frames":[]}],"usedImages":[]}
        """
        let dyld = CrashReportSummary.parse(fileName: "lyrimuse-2026-08-30-183301.ips", data: ips(dyldHeader, dyldBody))
        expectEqual(dyld != nil, true, "崩溃报告: DYLD 样本解析成功")
        if let dyld {
            expectEqual(dyld.processName, "lyrimuse", "崩溃报告: 进程名")
            expectEqual(dyld.version, "1.4.0", "崩溃报告: 版本")
            expectEqual(dyld.bugType, "309", "崩溃报告: bug_type 来自摘要行")
            expectEqual(dyld.timestamp, "2026-08-30 18:33:01.00 +0800", "崩溃报告: 时间戳优先取摘要行")
            expectEqual(dyld.exceptionSignal, "SIGABRT", "崩溃报告: 信号")
            expectEqual(dyld.terminationNamespace, "DYLD", "崩溃报告: termination namespace")
            expectEqual(dyld.terminationIndicator, "Library missing", "崩溃报告: termination indicator")
            expectEqual(dyld.terminationReasons.count, 2, "崩溃报告: reasons 两条")
            expectEqual(dyld.terminationDetails, ["(terminated at launch; ignore backtrace)"], "崩溃报告: details")
            expectEqual(dyld.faultingThreadIndex, 0, "崩溃报告: 故障线程号")
            expectEqual(dyld.frames.isEmpty && dyld.totalFrames == 0, true, "崩溃报告: 启动期崩溃零帧")
            expectEqual(dyld.parseNotes.isEmpty, true, "崩溃报告: 两段都解出来没有 note")
            let text = dyld.renderLines().joined(separator: "\n")
            expectEqual(text.contains("- lyrimuse-2026-08-30-183301.ips"), true, "崩溃报告: 渲染首行是文件名")
            expectEqual(text.contains("process: lyrimuse 1.4.0 ·"), true, "崩溃报告: 版本与构建号相同只写一次")
            expectEqual(text.contains("termination: DYLD · Library missing"), true, "崩溃报告: 渲染 termination")
            expectEqual(text.contains("reason: Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle"), true, "崩溃报告: 渲染缺的库")
            expectEqual(text.contains("faulting thread 0: no frames recorded"), true, "崩溃报告: 零帧明说")
            expectEqual(dyld.belongsToApp(executableName: "lyrimuse", bundleIdentifier: prod.bundleIdentifier, appDisplayName: prod.displayName), true,
                        "崩溃报告归属: 本 App 的报告属于本 App")
            expectEqual(dyld.belongsToApp(executableName: "lyrimuse", bundleIdentifier: otherID, appDisplayName: otherName), false,
                        "崩溃报告归属: 本 App 的报告不混进别的 bundle id")
        }

        let frameJSON = (0..<20).map { i in
            "{\"imageIndex\":\(i % 2),\"imageOffset\":\(1000 + i),\"symbol\":\"sym\(i)\"" + (i == 0 ? ",\"sourceFile\":\"Foo.swift\",\"sourceLine\":42" : "") + "}"
        }.joined(separator: ",")
        let crashBody = """
        {"procName":"lyrimuse","procPath":"/Applications/\(prod.displayName).app/Contents/MacOS/lyrimuse","bundleInfo":{"CFBundleShortVersionString":"1.5.0","CFBundleVersion":"1.5.0.1000","CFBundleIdentifier":"\(prod.bundleIdentifier)"},"captureTime":"2026-09-06 02:00:00.0 +0800","osVersion":{"train":"macOS 27.0","build":"26A5416b"},"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV","subtype":"KERN_INVALID_ADDRESS at 0x0"},"termination":{"namespace":"SIGNAL","indicator":"Segmentation fault: 11","flags":0,"code":11},"faultingThread":1,"threads":[{"frames":[{"imageIndex":1,"imageOffset":5}]},{"triggered":true,"frames":[\(frameJSON)]}],"usedImages":[{"name":"lyrimuse","base":0},{"name":"libswiftCore.dylib","base":0}]}
        """
        let crash = CrashReportSummary.parse(fileName: "lyrimuse-2026-09-06-020000.ips", data: ips("{not json", crashBody))
        expectEqual(crash != nil, true, "崩溃报告: 摘要行坏了只用正文")
        if let crash {
            expectEqual(crash.parseNotes, ["header unreadable"], "崩溃报告: note 记下摘要行没解出来")
            expectEqual(crash.timestamp, "2026-09-06 02:00:00.0 +0800", "崩溃报告: 时间戳退到正文 captureTime")
            expectEqual(crash.osVersion, "macOS 27.0 (26A5416b)", "崩溃报告: 系统版本退到正文 osVersion")
            expectEqual(crash.faultingThreadIndex, 1, "崩溃报告: 取故障线程而不是第 0 个")
            expectEqual(crash.totalFrames, 20, "崩溃报告: 记总帧数")
            expectEqual(crash.frames.count, CrashReportSummary.maxFrames, "崩溃报告: 只留前 15 帧")
            expectEqual(crash.frames[0].imageName, "lyrimuse", "崩溃报告: imageIndex → usedImages 名字")
            expectEqual(crash.frames[1].imageName, "libswiftCore.dylib", "崩溃报告: 第二帧的库名")
            expectEqual(crash.frames[0].sourceFile, "Foo.swift", "崩溃报告: 源文件")
            expectEqual(crash.frames[0].sourceLine, 42, "崩溃报告: 源行")
            let text = crash.renderLines().joined(separator: "\n")
            expectEqual(text.contains("process: lyrimuse 1.5.0 (1.5.0.1000)"), true, "崩溃报告: 构建号不同才带括号")
            expectEqual(text.contains("exception: EXC_BAD_ACCESS · SIGSEGV"), true, "崩溃报告: 渲染 exception")
            expectEqual(text.contains("faulting thread 1: showing 15 of 20 frames"), true, "崩溃报告: 帧数摘要")
            expectEqual(text.contains("lyrimuse  sym0 + 1000  (Foo.swift:42)"), true, "崩溃报告: 帧行格式")
            expectEqual(text.contains("sym15"), false, "崩溃报告: 第 16 帧起不渲染")
            expectEqual(text.contains("note: header unreadable"), true, "崩溃报告: note 渲染出来")
        }

        let collectorHeader = """
        {"app_name":"collector","timestamp":"2026-09-06 01:00:00.00 +0800","app_version":"???","bug_type":"309","os_version":"macOS 27.0 (26A5416b)","incident_id":"BBBB"}
        """
        let collectorBody = """
        {"procName":"collector","procPath":"/Users/USER/*/\(otherName).app/Contents/Resources/collector","exception":{"type":"EXC_CRASH","signal":"SIGKILL (Code Signature Invalid)"},"termination":{"namespace":"CODESIGNING","indicator":"Launch Constraint Violation","flags":66,"code":4},"faultingThread":0,"threads":[{"frames":[]}]}
        """
        let devCollector = CrashReportSummary.parse(fileName: "collector-2026-09-06-010000.ips", data: ips(collectorHeader, collectorBody))
        expectEqual(devCollector?.bundleIdentifier == nil, true, "崩溃报告: collector 没有 bundle id")
        expectEqual(devCollector?.belongsToApp(executableName: "lyrimuse", bundleIdentifier: otherID, appDisplayName: otherName), true,
                    "崩溃报告归属: 另一个同名包里的 collector 属于那个包(按包名判,家目录已被 macOS 改写)")
        expectEqual(devCollector?.belongsToApp(executableName: "lyrimuse", bundleIdentifier: prod.bundleIdentifier, appDisplayName: prod.displayName), false,
                    "崩溃报告归属: 别的包的 collector 不混进本 App")
        let foreignBody = """
        {"procName":"collector","procPath":"/Applications/Other.app/Contents/MacOS/collector","termination":{"namespace":"SIGNAL","indicator":"Abort trap: 6"}}
        """
        let foreign = CrashReportSummary.parse(fileName: "collector-2026-09-06-010500.ips", data: ips("{\"app_name\":\"collector\"}", foreignBody))
        expectEqual(foreign?.belongsToApp(executableName: "lyrimuse", bundleIdentifier: prod.bundleIdentifier, appDisplayName: prod.displayName), false,
                    "崩溃报告归属: 别家叫 collector 的进程被排除")

        // 宽容解析的边界
        let headerOnly = CrashReportSummary.parse(fileName: "x.ips", data: ips(dyldHeader, "garbage {"))
        expectEqual(headerOnly?.parseNotes, ["body unreadable"], "崩溃报告: 正文坏了只用摘要行")
        expectEqual(headerOnly?.processName, "lyrimuse", "崩溃报告: 摘要行里的进程名还在")
        expectEqual(CrashReportSummary.parse(fileName: "x.ips", data: ips("garbage", "more garbage")) == nil, true, "崩溃报告: 两段都坏 → nil")
        expectEqual(CrashReportSummary.parse(fileName: "x.ips", data: Data()) == nil, true, "崩溃报告: 空文件 → nil")
        expectEqual(CrashReportSummary.parse(fileName: "x.ips", data: "   \n  \n".data(using: .utf8)!) == nil, true, "崩溃报告: 只有空白 → nil")
        let bodyOnly = CrashReportSummary.parse(fileName: "x.ips", data: crashBody.data(using: .utf8)!)
        expectEqual(bodyOnly?.processName, "lyrimuse", "崩溃报告: 没有摘要行、整份是正文也认")
        expectEqual(bodyOnly?.totalFrames, 20, "崩溃报告: 整份正文的帧照常解")
        let arrayTop = CrashReportSummary.parse(fileName: "x.ips", data: ips("[1,2]", "[3]"))
        expectEqual(arrayTop == nil, true, "崩溃报告: 顶层不是对象 → nil 不崩")

        // 每进程限量
        func stub(_ name: String, _ ts: String) -> CrashReportSummary {
            var s = CrashReportSummary(fileName: "\(name)-\(ts).ips"); s.processName = name; s.timestamp = ts; return s
        }
        let many = (1...5).map { stub("lyrimuse", "2026-09-0\($0) 00:00:00") } + (1...4).map { stub("collector", "2026-09-1\($0) 00:00:00") }
        let picked = CrashReportSummary.select(many, perProcessLimit: 3)
        expectEqual(picked.count, 6, "崩溃报告挑选: 两个进程各 3 份")
        expectEqual(picked.filter { $0.processName == "lyrimuse" }.count, 3, "崩溃报告挑选: App 那 3 份没被 collector 挤掉")
        expectEqual(picked.first { $0.processName == "lyrimuse" }?.timestamp, "2026-09-05 00:00:00", "崩溃报告挑选: 同进程按时间倒序,最新的在前")
        expectEqual(picked.first { $0.processName == "collector" }?.timestamp, "2026-09-14 00:00:00", "崩溃报告挑选: collector 同理")
        expectEqual(CrashReportSummary.select([], perProcessLimit: 3).isEmpty, true, "崩溃报告挑选: 空输入空输出")
        expectEqual(CrashReportSummary.select(many, perProcessLimit: 0).isEmpty, true, "崩溃报告挑选: 限量 0 → 空")

        // 真报告全解一遍(默认不跑):LYRIMUSE_LIVE_CRASHREPORTS=1 时读本机 DiagnosticReports 里 lyrimuse-*.ips。
        if ProcessInfo.processInfo.environment["LYRIMUSE_LIVE_CRASHREPORTS"] == "1" {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasPrefix("lyrimuse-") && $0.hasSuffix(".ips") }.sorted()
            print("live: \(names.count) real report(s)")
            for name in names {
                let data = (try? Data(contentsOf: dir.appendingPathComponent(name))) ?? Data()
                let parsed = CrashReportSummary.parse(fileName: name, data: data)
                expectEqual(parsed != nil, true, "崩溃报告(真): \(name) 解析成功")
                expectEqual(parsed?.parseNotes.isEmpty, true, "崩溃报告(真): \(name) 两段都解出来")
                expectEqual(parsed?.terminationIndicator != nil, true, "崩溃报告(真): \(name) 有 termination indicator")
            }
            if let last = names.last, let data = try? Data(contentsOf: dir.appendingPathComponent(last)),
               let parsed = CrashReportSummary.parse(fileName: last, data: data) {
                for line in parsed.renderLines() { print("   ", line) }
            }
        }
    }

    // ---- build.sh 用什么身份签----
    //
    // ad-hoc 签名的「指定要求」就是一条光秃秃的 cdhash,而 TCC(辅助功能 / 自动化授权)存的正是这条要求:
    // 二进制一重编 cdhash 就变,存的那条再也对不上 —— 界面上勾还亮着、App 却说没授权,每次 build.sh 之后
    // 都要手动取消再勾一遍(用户撞上第 N 次:「为什么我明明已经有授权了,每次点击跳过广告
    // 还是会说让我去授权?」)。改成本机一张固定的自签名证书之后,要求变成
    // `identifier "..." and certificate root = H"<证书>"`,跟二进制内容无关。
    //
    // 这一组钉住那个改动不被顺手改回去:签名点必须**全部**走 `$SIGN_ID`,而 `$SIGN_ID` 必须保留
    // "没证书就退回 ad-hoc" 的兜底(CI 和别人的机器上没有这张证书,退不回去就直接签不了)。
    // 放在 ops 组而不是 contracts:它盯的是**构建 / 装机**这条链路,跟 launchd / 进程那几条同类。
    do {
        let buildScript = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // lyrimuse-selftest
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // lyrimuse
            .appendingPathComponent("build.sh")
        if let text = try? String(contentsOfFile: buildScript.path, encoding: .utf8) {
            // 注释里有好几处在讲"当年那行 `codesign -s - --force`",扫的时候得先把注释行剥掉 ——
            // 同 contracts 组那几条源码守卫踩过的坑(整份 contains 会被自己的注释打红)。
            let codeLines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("#") }
            let adHocLiterals = codeLines.filter { $0.contains("--sign -\"") || $0.contains("-s - ") }
            expectEqual(adHocLiterals, [],
                        "构建签名: build.sh 里不准再出现裸 ad-hoc 签名调用,全部走 $SIGN_ID(否则 TCC 授权每次重装即失效)")
            expectEqual(text.contains("SIGN_ID=\"${LYRIMUSE_SIGN_ID:-}\""), true,
                        "构建签名: LYRIMUSE_SIGN_ID 这个显式覆盖口子还在")
            expectEqual(text.contains("SIGN_ID=\"-\""), true,
                        "构建签名: 没有那张自签名证书时必须退回 ad-hoc(CI / 别人的机器上就是这条路)")
            expectEqual(text.contains("DEV_SIGN_NAME=\"Lyrimuse Dev Signing\""), true,
                        "构建签名: 本机证书的 CN 还是那一个(改名要连同这条守卫一起改,别让自动探测静默失效)")
            let signCalls = codeLines.filter { $0.contains("codesign") && $0.contains("$SIGN_ID") }.count
            expectEqual(signCalls >= 8, true,
                        "构建签名: 走 $SIGN_ID 的签名调用点至少 8 处(嵌套二进制 + 框架 + 最外层 .app),实际 \(signCalls)")
        } else {
            expectEqual(true, false, "构建签名: 读不到 build.sh(路径挪了?)")
        }
    }

    // ---- 发布包用固定证书签----
    //
    // CI 上没有本机那张证书,build.sh 会退回 ad-hoc,而 ad-hoc 的签名要求是 cdhash:用户每次 Sparkle 更新后
    // 辅助功能 / 自动化 / 完全磁盘访问的授权都失效。release.yml 从 Secret 导入发布证书、把 LYRIMUSE_SIGN_ID
    // 设成它的 SHA-1;package.sh 在打 tag 时拦下任何不是「证书根」要求的包。三件事缺一件,发出去的包就
    // 悄悄退回 ad-hoc,所以一起钉住。
    do {
        let lyrimuseDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // lyrimuse-selftest
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // lyrimuse
        let packageScript = lyrimuseDir.appendingPathComponent("package.sh")
        let workflow = lyrimuseDir.deletingLastPathComponent()
            .appendingPathComponent(".github/workflows/release.yml")
        if let pkg = try? String(contentsOfFile: packageScript.path, encoding: .utf8),
           let wf = try? String(contentsOfFile: workflow.path, encoding: .utf8) {
            expectEqual(pkg.contains("LYRIMUSE_REQUIRE_STABLE_SIGNATURE"), true,
                        "发布签名: package.sh 还有「必须固定证书」那道闸")
            expectEqual(pkg.contains("*\"certificate root\"*"), true,
                        "发布签名: package.sh 的闸按签名要求里的 certificate root 判")
            expectEqual(pkg.contains("\"$app/Contents/Resources/collector\""), true,
                        "发布签名: collector 也过闸(它自己持有完全磁盘访问 / 自动化授权)")
            expectEqual(wf.contains("echo \"LYRIMUSE_SIGN_ID=$SHA\" >> \"$GITHUB_ENV\""), true,
                        "发布签名: release.yml 把导入的证书交给 build.sh")
            expectEqual(wf.contains("set-key-partition-list"), true,
                        "发布签名: release.yml 设了 partition list(不设 codesign 会卡在弹窗上)")
            expectEqual(wf.contains("LYRIMUSE_REQUIRE_STABLE_SIGNATURE: ${{ startsWith(github.ref, 'refs/tags/') && '1' || '' }}"), true,
                        "发布签名: 打 tag 的构建强制过闸")
            expectEqual(wf.contains("security delete-keychain"), true,
                        "发布签名: 临时钥匙串用完删掉")
        } else {
            expectEqual(true, false, "发布签名: 读不到 package.sh 或 .github/workflows/release.yml(路径挪了?)")
        }
    }

    // ---- build.sh 装完必须确认进程真换了----
    //
    // `open -g` 撞上 LaunchServices 单实例时只会**激活**旧实例、不起新二进制,而此前脚本
    // 最后那句 `pgrep` 会把同一个旧 pid 当成"新起来的",照样打印 running 并 EXIT=0 ——
    // 磁盘上是新代码、内存里跑的还是旧的,后面一切真机验证都在验旧代码。实测起因:App 开着
    // 「解析决策」那张 modal sheet,AppKit 把 terminate 整个取消掉(系统日志
    // "App termination blocked by modal sheet" + "Termination aborted"),SIGTERM 之后再等
    // 10 秒仍然活着 —— 不是等久一点能解决的,只能如实报错。
    do {
        let buildScript = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build.sh")
        if let text = try? String(contentsOfFile: buildScript.path, encoding: .utf8) {
            // 先把注释行剥掉再扫 —— 上面那段注释里就复述了 "running, pid" 和
            // "modal sheet",整份 contains 会命中注释、让守卫变成假通过(顺序那条第一次
            // 就是这么红的:注释排在校验之前)。同签名守卫那条踩过的坑。
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("#") }
                .joined(separator: "\n")
            expectEqual(code.contains("OLD_PIDS="), true,
                        "装机校验: kill 之前要把旧 pid 记下来,否则没法判断进程到底换没换")
            expectEqual(code.contains("[ \"$pid\" = \"$OLD_PIDS\" ]"), true,
                        "装机校验: 起来之后必须比对 pid 变没变(这是那条假成功的唯一拦截点)")
            expectEqual(code.contains("modal sheet"), true,
                        "装机校验: 失败提示里要说出最常见的原因(有弹窗开着),否则看到报错也不知道该关什么")
            // 报成功那句必须排在校验**之后** —— 顺序反了等于没校验。
            if let guardRange = code.range(of: "= \"$OLD_PIDS\" ]"),
               let okRange = code.range(of: "echo \"==> $APP_NAME running, pid") {
                expectEqual(guardRange.lowerBound < okRange.lowerBound, true,
                            "装机校验: pid 比对要排在那句 running 成功提示之前")
            } else {
                expectEqual(true, false, "装机校验: 找不到 pid 比对或成功提示(改写法了?)")
            }
            // collector 那段:开着后台服务时交给 App 的启动对账重装,脚本不再同时动同一个 label;
            // 任何一条路都不跟 kickstart -k(它杀的正是 bootstrap 刚拉起的进程)。确认「新起来了」
            // 要比对 open 之前记下的旧 pid,并且要等够久。
            if let sectionStart = code.range(of: "COLLECTOR_PLIST=") {
                let section = code[sectionStart.lowerBound...]
                expectEqual(section.contains("kickstart"), false,
                            "装机校验: collector 那段不准再 kickstart -k(会杀掉刚 bootstrap 起来的进程)")
                expectEqual(section.contains("np:collectorServiceEnabled"), true,
                            "装机校验: 开着后台服务时要交给 App 重装 collector,不跟它同时动 launchd")
                expectEqual(section.contains("$OLD_COLLECTOR_PIDS"), true,
                            "装机校验: 确认 collector 起来要比对旧 pid")
                expectEqual(section.contains("seq 1 60"), true,
                            "装机校验: 等 collector 要等够 60 秒(App 对账 + 加载缓存),固定 sleep 会误报没起来")
            } else {
                expectEqual(true, false, "装机校验: 找不到 collector 那段(COLLECTOR_PLIST=)")
            }
            if let recordRange = code.range(of: "OLD_COLLECTOR_PIDS="),
               let openRange = code.range(of: "open -g \"$APP_DIR\"") {
                expectEqual(recordRange.lowerBound < openRange.lowerBound, true,
                            "装机校验: 旧 collector pid 要在 open 之前记(App 一起来就会重装它)")
            } else {
                expectEqual(true, false, "装机校验: 找不到旧 collector pid 的记录或 open -g")
            }
        } else {
            expectEqual(true, false, "装机校验: 读不到 build.sh(路径挪了?)")
        }
    }

    // ---- 提交信息不许引用 issue ----
    //
    // 「以后提交都不允许引用任何 issue」。为什么是 git hook 而不是写进文档:这个仓的
    // AGENTS.md / CLAUDE.md 都在 .gitignore 里、文件本身也不存在,而提醒类的约束实测拦不住
    // —— 761df77 就这么把一条 "added a commit that references this issue" 永久留在了
    // issue timeline 上,而 GitHub 那条事件记录**删不掉**(force push 也未必能让它消失)。
    //
    // 这一组盯的是 hook 本身别被删掉或掏空。 只查文件,**不查 core.hooksPath** ——
    // 那是本机 git config、不在仓里,CI 上必然没配,查了就是稳定红。新克隆要启用得自己跑
    // 一次 `git config core.hooksPath .githooks`。
    do {
        let hook = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // lyrimuse-selftest
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // lyrimuse
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent(".githooks/commit-msg")
        if let text = try? String(contentsOfFile: hook.path, encoding: .utf8) {
            expectEqual(FileManager.default.isExecutableFile(atPath: hook.path), true,
                        "提交闸: .githooks/commit-msg 必须是可执行的(丢了执行位 = hook 静默失效)")
            // 剥注释行再扫 —— hook 自己的说明里就写着 `#123` / `GH-123` 这些样例,
            // 整份 contains 会被自己的注释骗过去(build.sh 那条守卫踩过同一个坑)。
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("#") }
                .joined(separator: "\n")
            expectEqual(code.contains("#[0-9]+"), true,
                        "提交闸: 判据里必须还拦着行内的井号编号(#123)")
            expectEqual(code.contains("GH-[0-9]+"), true,
                        "提交闸: 判据里必须还拦着 GH-123 这种写法")
            expectEqual(code.contains("(issues|pull)/[0-9]+"), true,
                        "提交闸: 判据里必须还拦着贴完整 github URL 的写法")
            expectEqual(code.contains("grep -v '^#'"), true,
                        "提交闸: 必须先剔掉 git 自己的注释行,否则正常提交会被那几行误伤")
            expectEqual(code.contains("exit 1"), true,
                        "提交闸: 命中之后必须真的非零退出(只打印不拦 = 没有闸)")
        } else {
            expectEqual(true, false, "提交闸: 读不到 .githooks/commit-msg —— 被删了还是路径挪了?")
        }
    }

    // 提交前的两道闸(.githooks/pre-commit):gofmt 保证暂存的 .go 文件已格式化(CI 第一步
    // 就是它),注释卫生(→ scripts/check-comment-hygiene.py)保证注释只写现状与约束、过程性
    // 内容(日期戳 / 迭代编号 / 人物归因 / 工单引用 / 排查叙述)归 git 和 docs/。
    // 失效是静默的:丢了执行位、检查器被挪走、或者哪一道闸被删掉,hook 直接放行,
    // 谁都看不出来 —— 所以这里逐条钉住每道闸的存在。
    do {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // lyrimuse-selftest
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // lyrimuse
            .deletingLastPathComponent()   // 仓库根
        let hook = root.appendingPathComponent(".githooks/pre-commit")
        let checker = root.appendingPathComponent("scripts/check-comment-hygiene.py")
        expectEqual(FileManager.default.isExecutableFile(atPath: hook.path), true,
                    "注释卫生闸: .githooks/pre-commit 必须是可执行的(丢了执行位 = hook 静默失效)")
        expectEqual(FileManager.default.fileExists(atPath: checker.path), true,
                    "注释卫生闸: 检查器得在 scripts/check-comment-hygiene.py —— hook 找不到它就直接放行")
        if let text = try? String(contentsOfFile: hook.path, encoding: .utf8) {
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("#") }
                .joined(separator: "\n")
            expectEqual(code.contains("check-comment-hygiene.py"), true,
                        "注释卫生闸: hook 必须真的调那个检查器")
            expectEqual(code.contains("--cached"), true,
                        "注释卫生闸: 只查本次暂存的文件 —— 扫全仓会让每次提交都变慢")
            expectEqual(code.contains("exit 1"), true,
                        "注释卫生闸: 命中之后必须真的非零退出(只打印不拦 = 没有闸)")
            expectEqual(code.contains("gofmt -l"), true,
                        "格式闸: hook 必须跑 gofmt -l —— CI 第一步就是它,本地不拦就得推上去才知道")
            expectEqual(code.contains("command -v gofmt"), true,
                        "格式闸: 没装 gofmt 的机器必须放行 —— 误拦没有兜底,漏报有(CI 那边照样拦)")
            expectEqual(code.contains("gen-players.py") && code.contains("--check"), true,
                        "播放器生成物闸: hook 必须真的调生成器的 --check")
            // 只改 shared/players.json 的提交里一个源码文件都没有,那道 early exit 会先返回 0。
            // 闸排在它后面 = 恰好对最需要它的那种提交失效。
            if let gate = code.range(of: "gen-players.py"),
               // 要找的是 files 那道 early exit,不能只搜 "|| exit 0" —— 开头
               // `root=$(git rev-parse …) || exit 0` 会先命中,判据当场失真(实测 FAIL 过)。
               let earlyExit = code.range(of: #"[ -n "$files" ] || exit 0"#) {
                expectEqual(gate.lowerBound < earlyExit.lowerBound, true,
                            "播放器生成物闸: 必须排在「没有源码文件就 exit 0」前面")
            } else {
                expectEqual(true, false, "播放器生成物闸: 在 hook 里找不到它")
            }
        } else {
            expectEqual(true, false, "注释卫生闸: 读不到 .githooks/pre-commit —— 被删了还是路径挪了?")
        }
    }
}
