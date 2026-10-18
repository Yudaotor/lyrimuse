import LyrimuseCore
import Foundation

// 只留本地的文档跟代码、跟彼此对得上:docs/features、.claude/skills、AGENTS.md / CLAUDE.md、docs/releasing.md。
// 这些文件不进版本库,CI 和私有暂存区的提交校验里都没有,各段读不到就跳过 —— 这一组红,是本机文档没对上,不是代码坏了。
// 跟公开文档(README、llms.txt、url-scheme、对比页)的一致性检查是产品文档的事,不在这里。

@MainActor
func runLocalDocsTests() {
    // ---- 署名过滤的「轮次计数」必须跟条目对齐----
    //
    // docs/features/08-lyrics-engine.md 里有两处**各自手工维护**的同一个数:一条条
    // 「第 N 轮」的条目,和「设计决策」那节「枚举法收敛不了(至今补到第 N 轮)」里的计数。
    // 加规则的人常常只补条目、忘了抬计数 —— 实测:第十五轮记得抬,紧接着另一个
    // session 加第十六轮时就漏了。漏了什么都不报,只是让下一个读文档的人拿到一个偏小的数,
    // 从而低估这套规则的枚举成本 —— 而"枚举法收敛不了"正是这一节要传达的结论本身。
    //
    // 顺带钉住条目编号**连续且不重复**:这份文档同时有多个 session 在改(第十五轮和第十六轮
    // 就来自两个不同 session),两边各写一条「第十七轮」而互不知道是真实存在的撞车形态。
    do {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Sources/lyrimuse-selftest
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // lyrimuse(包目录)
            .deletingLastPathComponent()   // 仓库根
        // 「设计决策与已知坑」那一节在 docs/features/decisions/ 下的同名文件里(15 章决策 47),两份拼起来读。
        let docPath = repoRoot.appendingPathComponent("docs/features/08-lyrics-engine.md").path
        let decisionsPath = repoRoot.appendingPathComponent("docs/features/decisions/08-lyrics-engine.md").path
        /// 「十六」→ 16。只覆盖 1…99 的写法(一位数 / 十 / 十X / X十 / X十Y),不够用时返回 nil 而不是瞎猜。
        func chineseNumeral(_ s: String) -> Int? {
            let digits: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
                                            "六": 6, "七": 7, "八": 8, "九": 9]
            let chars = Array(s)
            guard !chars.isEmpty, chars.count <= 3 else { return nil }
            guard let tenIdx = chars.firstIndex(of: "十") else {
                guard chars.count == 1, let v = digits[chars[0]] else { return nil }
                return v
            }
            let high = chars[..<tenIdx], low = chars[(tenIdx + 1)...]
            var value = 0
            if high.isEmpty {
                value = 10
            } else if high.count == 1, let v = digits[high[high.startIndex]] {
                value = v * 10
            } else {
                return nil
            }
            if low.isEmpty { return value }
            guard low.count == 1, let v = digits[low[low.startIndex]] else { return nil }
            return value + v
        }
        /// 扫出文本里 `<prefix>第…轮` 的那个数,按出现顺序。
        func rounds(in text: String, prefix: String) -> [Int] {
            var out: [Int] = []
            var rest = Substring(text)
            while let hit = rest.range(of: prefix + "第") {
                let tail = rest[hit.upperBound...]
                if let close = tail.firstIndex(of: "轮"),
                   let v = chineseNumeral(String(tail[tail.startIndex..<close])) {
                    out.append(v)
                }
                rest = rest[hit.upperBound...]
            }
            return out
        }
        if let chapter = try? String(contentsOfFile: docPath, encoding: .utf8) {
            let doc = chapter + "\n" + ((try? String(contentsOfFile: decisionsPath, encoding: .utf8)) ?? "")
            // 每个条目行只取**第一个**「第 N 轮」:条目正文里常回指别的轮次(「跟第十三轮同源」),
            // 全收会把回指也算成条目、连带把连续性判据搞乱。
            let entryRounds: [Int] = doc.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { $0.hasPrefix("- **第") }
                .compactMap { rounds(in: $0, prefix: "").first }
            expectNotEqual(entryRounds.count, 0,
                           "署名轮次: 扫到了「- **第 N 轮」条目(一条都没扫到 = 文档格式变了、这道闸自己失效了)")
            let counters = rounds(in: doc, prefix: "至今补到")
            expectEqual(counters.count, 1,
                        "署名轮次: 「至今补到第 N 轮」这句计数应当有且只有一处")
            expectEqual(counters.first, entryRounds.max(),
                        "署名轮次: 「至今补到第 N 轮」的计数必须等于最后一条「第 N 轮」条目的编号 —— 加了条目忘抬计数")
            let expectedRun = Array(stride(from: entryRounds.min() ?? 0, through: entryRounds.max() ?? 0, by: 1))
            expectEqual(entryRounds, expectedRun,
                        "署名轮次: 条目编号要连续不重复 —— 重号 = 两个 session 各加了一轮却互不知道")
        } else if FileManager.default.fileExists(
            atPath: repoRoot.appendingPathComponent("docs/features").path) {
            // 目录在却读不到这一份 = 真的被挪走/改名了。
            expectEqual(true, false, "署名轮次: 读不到 docs/features/08-lyrics-engine.md(路径挪了?)")
        }
        // docs/features 整个目录不在 = 本地-only 的文档没被检出(CI 上就是这样),这一项跳过。
    }


    // ---- 项目级 skill----
    //
    // `.claude/skills/<名>/SKILL.md` 是操作型流程(真机验证 / 歌词排查 / 接入新播放器 / 发版)的「步骤版」:
    // 只写步骤与判据,理由回链 AGENTS.md 与 docs。它最常见的死法是锚点腐烂(脚本改名、文档挪位、链接失效)和
    // 越写越长变成第二份 AGENTS.md,这里守:行数上限、frontmatter 齐、引用的仓库路径 / 文档链接都在、发版只许
    // 显式触发、真机验证开头就是禁 AppleScript 那条、两个入口文件都指过去。
    skillGuard: do {
        // #filePath = <repo>/lyrimuse/Sources/lyrimuse-selftest/SourceContractTests.swift → 上 4 层到仓库根
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let skillsDir = repoRoot.appendingPathComponent(".claude/skills")
        // **这几份 skill 与 AGENTS.md / CLAUDE.md 不进版本库**(AI 协作文件只留
        // 作者本地)。所以在别人的 clone 和 CI 上它们**根本不存在** —— 那时整段跳过,不是失败。
        // 本地有就照旧全查(锚点腐烂、超长、发版 skill 漏 disable-model-invocation 都还是红)。
        // 别把这个 guard 改成 expectEqual:CI 会因为「文件缺失」红,而那不是缺陷,是刻意不发布。
        guard FileManager.default.fileExists(atPath: skillsDir.path) else { break skillGuard }
        let expected = ["lyrimuse-lyrics-triage", "lyrimuse-player-integration", "lyrimuse-release", "lyrimuse-verify-ui"]
        let found = ((try? FileManager.default.contentsOfDirectory(atPath: skillsDir.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
        expectEqual(found, expected, "项目级 skill: 登记的都在、没有多出来的(多一份要来这里登记)")
        let linkPattern = try? NSRegularExpression(pattern: #"\]\(([^)\s]+)\)"#)
        let codePattern = try? NSRegularExpression(pattern: #"`([^`\n]+)`"#)
        let pathPrefixes = ["lyrimuse/", "lyrimuse-engine/", "docs/", ".github/", ".claude/"]
        for name in expected {
            let file = skillsDir.appendingPathComponent("\(name)/SKILL.md")
            guard let src = try? String(contentsOfFile: file.path, encoding: .utf8) else {
                expectEqual(true, false, "项目级 skill: 读得到 \(name)/SKILL.md")
                continue
            }
            // 跟 wc -l 一样数:末尾换行后面那段空的不算一行。
            let lineCount = src.split(separator: "\n", omittingEmptySubsequences: false).count - (src.hasSuffix("\n") ? 1 : 0)
            expectEqual(lineCount <= 80, true, "项目级 skill: \(name) 不超过 80 行(实际 \(lineCount))——只写步骤,理由回链")
            expectEqual(src.hasPrefix("---\nname: \(name)\n"), true, "项目级 skill: \(name) frontmatter 以 name 开头且与目录名一致")
            expectEqual(src.contains("\ndescription: "), true, "项目级 skill: \(name) 有 description(按场景触发靠它)")
            expectEqual(src.contains("AGENTS.md"), true, "项目级 skill: \(name) 回链 AGENTS.md(理由不在 skill 里)")
            let ns = src as NSString
            let whole = NSRange(location: 0, length: ns.length)
            var missing: [String] = []
            if let linkPattern {
                for m in linkPattern.matches(in: src, range: whole) {
                    var target = ns.substring(with: m.range(at: 1))
                    if target.hasPrefix("http") { continue }
                    if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
                    guard !target.isEmpty else { continue }
                    let url = file.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL
                    if !FileManager.default.fileExists(atPath: url.path) { missing.append("link:" + target) }
                }
            }
            if let codePattern {
                for m in codePattern.matches(in: src, range: whole) {
                    let token = ns.substring(with: m.range(at: 1))
                    var first = token.split(separator: " ").first.map(String.init) ?? ""
                    if first.hasPrefix("./") { first.removeFirst(2) }
                    guard pathPrefixes.contains(where: { first.hasPrefix($0) }),
                          !first.contains("<"), !first.contains("*") else { continue }
                    if !FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(first).path) {
                        missing.append("path:" + first)
                    }
                }
            }
            expectEqual(missing, [], "项目级 skill: \(name) 引用的路径 / 链接都存在")
        }
        let release = (try? String(contentsOfFile: skillsDir.appendingPathComponent("lyrimuse-release/SKILL.md").path,
                                   encoding: .utf8)) ?? ""
        expectEqual(release.contains("\ndisable-model-invocation: true\n"), true,
                    "项目级 skill: 发版 skill 只许显式触发(它会打 tag 推远端)")
        let verify = (try? String(contentsOfFile: skillsDir.appendingPathComponent("lyrimuse-verify-ui/SKILL.md").path,
                                  encoding: .utf8)) ?? ""
        let verifyHead = verify.split(separator: "\n", omittingEmptySubsequences: false).prefix(12).joined(separator: "\n")
        expectEqual(verifyHead.contains("AppleScript"), true, "项目级 skill: 真机验证 skill 开头就写禁 AppleScript 那条硬规则")
        for entry in ["AGENTS.md", "CLAUDE.md"] {
            let text = (try? String(contentsOfFile: repoRoot.appendingPathComponent(entry).path, encoding: .utf8)) ?? ""
            expectEqual(text.contains(".claude/skills/"), true, "项目级 skill: \(entry) 指向 .claude/skills/")
        }
    }


    // ---- 发版文档跟发布链路对得上 ----
    //
    // 发布链路本身(release.yml、build.sh、check_release_tag.sh)在 contracts-settings 那段守;这里只看两份只留本地的说明
    // 写没写到同一套脚本。
    do {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func read(_ rel: String) -> String {
            (try? String(contentsOfFile: repoRoot.appendingPathComponent(rel).path, encoding: .utf8)) ?? ""
        }
        // docs/releasing.md 跟 AGENTS.md 一样**不进版本库**(理由同下一段),别人的 clone 和 CI 上
        // `read` 返回空串 —— 有就查,没有就跳过,别改回无条件 expectEqual。
        let releasingDoc = read("docs/releasing.md")
        if !releasingDoc.isEmpty {
            expectEqual(releasingDoc.contains("check_release_tag.sh"), true, "tag 校验: releasing.md 让打 tag 的人 push 前本地跑同一份")
            // 落地页推送走脚本,不手写 URL 名单 —— 手写那份在加页那天不会有人想起来改,
            // 而且漏推不报错,只表现成新页在 Bing 里迟迟不出现。
            expectEqual(releasingDoc.contains("ping-indexnow.py"), true,
                        "IndexNow: releasing.md 走 scripts/ping-indexnow.py(URL 列表从 sitemap 读),别退回手写名单")
        }
        // **AGENTS.md 不进版本库**(理由见上面「项目级 skill」那段),别人的 clone 和 CI 上
        // `read` 返回空串 —— 有就查,没有就跳过。这一条守的是「作者本地那份写清了 CI 会拒什么」,对使用者
        // 和贡献者没有意义。 别改回无条件 expectEqual:CI 会因为「文件缺失」红,而那不是缺陷,是刻意不发布。
        // (实测:第一次只给 .claude/skills 那段加了跳过、漏了这一条,在模拟 clone 里当场红。
        //  同类读点共 6 处,其余 5 处都在上面那个 skillGuard 块里、已被整段跳过覆盖。)
        let agentsDoc = read("AGENTS.md")
        if !agentsDoc.isEmpty {
            expectEqual(agentsDoc.contains("check_release_tag.sh"), true, "tag 校验: AGENTS.md「提交」写明 CI 拒什么")
        }
    }
}
