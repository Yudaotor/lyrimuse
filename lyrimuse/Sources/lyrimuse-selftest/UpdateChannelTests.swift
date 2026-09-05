import LyrimuseCore
import Foundation

// 更新频道:版本号解析 / 构建号映射(与 lyrimuse/scripts/build-version.sh 交叉校验)/ Release 列表解析 /
// 「接收测试版更新」该读哪份 appcast。由 main.swift 的注册表按组调用。

@MainActor
func runUpdateChannelTests() {
    // ---- ReleaseVersion(2026-09-05,借鉴清单 #32 + 用户拍板「接收测试版」开关)----
    //
    // 为什么正式版是 X.Y.Z.1000、预发布是分区第四段:Sparkle 的 SUStandardVersionComparator 实测把 "-" 之后全部
    // 忽略("1.6.0-beta.1" == "1.6.0","beta.2" == "beta.1"),构建号必须是纯数字四段。这一组钉的是 Swift 镜像;
    // 真源是 shell 脚本,下面用一张表交叉校验两边一致。
    do {
        print("\n== 版本号与构建号 ==")
        typealias V = ReleaseVersion
        expectEqual(V(tag: "v1.6.0")?.buildNumberString, "1.6.0.1000", "构建号: 正式版第四段 1000")
        expectEqual(V(tag: "1.6.0")?.displayString, "1.6.0", "解析: 不带 v 也认")
        expectEqual(V(tag: "v1.6.0-alpha.3")?.buildNumberString, "1.6.0.3", "构建号: alpha.N → N")
        expectEqual(V(tag: "v1.6.0-beta.2")?.buildNumberString, "1.6.0.102", "构建号: beta.N → 100+N")
        expectEqual(V(tag: "v1.6.0-rc.1")?.buildNumberString, "1.6.0.501", "构建号: rc.N → 500+N")
        expectEqual(V(tag: "v1.6.0-beta.2")?.displayString, "1.6.0-beta.2", "展示版本: tag 去 v 原文")
        expectEqual(V(tag: "v1.6.0-beta.2")?.isPrerelease, true, "预发布判定: 带后缀")
        expectEqual(V(tag: "v1.6.0")?.isPrerelease, false, "预发布判定: 不带后缀")
        expectEqual(V(tag: "v0.0.0")?.buildNumberString, "0.0.0.1000", "构建号: 0.0.0 占位版也合法")
        for bad in ["v1.6", "v1.6.0.1", "v1.6.0-beta", "v1.6.0-beta.0", "v1.6.0-foo.1", "v1.6.0-beta.400",
                    "v1.6.0-rc.500", "v1.6.0-alpha.100", "v01.6.0", "v1.6.0-beta.01", "1.6.0-", "", "dev-abc1234",
                    "v1.6.0-beta.1-extra", "v1.6.0 ", "v1.6.0-BETA.1", "v1.6.0-beta.1000"] {
            expectEqual(V(tag: bad) == nil, true, "解析: 拒绝 \(bad.isEmpty ? "空串" : bad)")
        }
        // 大小:alpha < beta < rc < 正式 < 下一补丁;跨段按数字不按字符串(1.10 > 1.6)。
        let order = ["v1.5.0", "v1.6.0-alpha.1", "v1.6.0-alpha.99", "v1.6.0-beta.1", "v1.6.0-beta.10",
                     "v1.6.0-rc.1", "v1.6.0", "v1.6.1-alpha.1", "v1.10.0"]
        let parsed = order.compactMap { V(tag: $0) }
        expectEqual(parsed.count, order.count, "大小: 样本全部能解析")
        expectEqual(parsed.sorted().map(\.displayString), parsed.map(\.displayString),
                    "大小: alpha < beta < rc < 正式 < 下一补丁,跨段按数字不按字符串")
        expectEqual(V(tag: "v1.6.0-beta.10")! > V(tag: "v1.6.0-beta.9")!, true, "大小: beta.10 > beta.9(Sparkle 自己比不出来,构建号替它比)")
        expectEqual(V(tag: "v1.6.0")! > V(tag: "v1.6.0-rc.1")!, true, "大小: 正式版压过 rc")
        expectEqual(V(tag: "v1.6.0") == V(tag: "1.6.0"), true, "相等: v 前缀不影响")

        // 与 scripts/build-version.sh 交叉校验:那份 shell 是构建时的真源(build.sh 写 Info.plist、release.yml 生成
        // appcast),这里的 Swift 只是运行时镜像。任何一边改了映射,这一组当场红。
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = repoRoot.appendingPathComponent("lyrimuse/scripts/build-version.sh").path
        expectEqual(FileManager.default.isExecutableFile(atPath: script), true, "交叉校验: build-version.sh 在且可执行")
        for tag in order + ["v0.0.0", "v2.0.0-rc.499", "v2.0.0-beta.399", "v2.0.0-alpha.99", "1.6.0-beta.2"] {
            let result = ProcessRunner.run("/bin/bash", [script, tag], timeout: 10)
            expectEqual(result?.succeeded, true, "交叉校验: 脚本接受 \(tag)")
            expectEqual(result?.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), V(tag: tag)?.buildNumberString,
                        "交叉校验: \(tag) 两边构建号一致")
        }
        for bad in ["v1.6", "v1.6.0-beta", "v1.6.0-foo.1", "v1.6.0-beta.400", "v01.6.0", "v1.6.0-beta.01",
                    "1.6.0.1000", "v1.6.0-BETA.1", ""] {
            let result = ProcessRunner.run("/bin/bash", [script, bad], timeout: 10)
            expectEqual(result?.succeeded, false, "交叉校验: 脚本同样拒绝 \(bad.isEmpty ? "空串" : bad)")
        }
    }

    // ---- UpdateChannel(Release 列表 → 该读哪份 appcast)----
    do {
        print("\n== 测试版频道 ==")
        typealias U = UpdateChannel
        let json = """
        [
          {"tag_name":"v1.6.0-beta.2","prerelease":true,"draft":false},
          {"tag_name":"v1.6.0-beta.3","prerelease":true,"draft":true},
          {"tag_name":"v1.5.0","prerelease":false,"draft":false},
          {"tag_name":"nightly","prerelease":true,"draft":false},
          {"tag_name":"v1.4.0","prerelease":false,"draft":false}
        ]
        """
        let releases = U.parseReleases(Data(json.utf8))
        expectEqual(releases?.count, 5, "解析: 五条都读到(含 draft 与不合形态的 tag)")
        expectEqual(releases?.first, U.Release(tag: "v1.6.0-beta.2", prerelease: true, draft: false), "解析: 三个字段")
        expectEqual(U.newestRelease(releases ?? [])?.tag, "v1.6.0-beta.2",
                    "挑选: 非 draft、能解析里版本最高的 → beta.2(draft 的 beta.3 不算,nightly 解析不了跳过)")
        expectEqual(U.betaFeedURL(releases: releases ?? [])?.absoluteString,
                    "https://github.com/Yudaotor/lyrimuse/releases/download/v1.6.0-beta.2/appcast.xml",
                    "挑选: appcast 在它自己的 tag 目录下,不是 latest")
        let after = [U.Release(tag: "v1.6.0-beta.2", prerelease: true, draft: false),
                     U.Release(tag: "v1.6.0", prerelease: false, draft: false)]
        expectEqual(U.newestRelease(after)?.tag, "v1.6.0", "挑选: 同号正式版压过 beta(beta 用户也被带回正式版)")
        expectEqual(U.betaFeedURL(releases: []), nil, "挑选: 空列表 → nil(退回默认 latest)")
        expectEqual(U.betaFeedURL(releases: [U.Release(tag: "nightly", prerelease: true, draft: false)]), nil,
                    "挑选: 全是解析不了的 tag → nil")
        expectEqual(U.parseReleases(Data("{\"tag_name\":\"v1\"}".utf8)) == nil, true, "解析: 顶层不是数组 → nil")
        expectEqual(U.parseReleases(Data("[{\"prerelease\":true}]".utf8)) == nil, true, "解析: 缺 tag_name → 整份不信")
        expectEqual(U.parseReleases(Data("[]".utf8))?.isEmpty, true, "解析: 空数组 → 空列表(不是 nil)")
        let now = Date()
        expectEqual(U.shouldRefresh(now: now, fetchedAt: nil, retryNotBefore: nil), true, "刷新: 从没取过 → 取")
        expectEqual(U.shouldRefresh(now: now, fetchedAt: now.addingTimeInterval(-600), retryNotBefore: nil), false, "刷新: 10 分钟前取过 → 不取")
        expectEqual(U.shouldRefresh(now: now, fetchedAt: now.addingTimeInterval(-7200), retryNotBefore: nil), true, "刷新: 超过 1 小时 → 取")
        expectEqual(U.shouldRefresh(now: now, fetchedAt: now.addingTimeInterval(600), retryNotBefore: nil), true, "刷新: 取数时间在未来(时钟回拨)→ 当过期")
        expectEqual(U.shouldRefresh(now: now, fetchedAt: nil, retryNotBefore: now.addingTimeInterval(60)), false, "刷新: 退避期内连首次也不发")
        expectEqual(U.releasesAPIURL.host, "api.github.com", "地址: 只打 api.github.com(01 章对外请求表已登记这个 host)")
        expectEqual(U.appcastURL(forTag: "v1.6.0").absoluteString.hasPrefix("https://github.com/Yudaotor/lyrimuse/releases/download/v1.6.0/"), true,
                    "地址: appcast 目录与 release.yml 里 enclosure 的目录同形")

        // 真网核对(默认不跑):LYRIMUSE_LIVE_GITHUB=1 时真的拉一次 Release 列表,断言解析得动、挑出来的是个合法版本。
        if ProcessInfo.processInfo.environment["LYRIMUSE_LIVE_GITHUB"] == "1" {
            print("\n== 测试版频道真网核对 ==")
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var payload: Data?
            var request = URLRequest(url: U.releasesAPIURL)
            request.timeoutInterval = 15
            request.setValue("Lyrimuse-selftest", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: request) { data, _, _ in payload = data; sem.signal() }.resume()
            _ = sem.wait(timeout: .now() + 20)
            let live = payload.flatMap(U.parseReleases)
            expectEqual((live?.count ?? 0) > 0, true, "真网: Release 列表拉得到且解析得动(\(live?.count ?? 0) 条)")
            let newest = U.newestRelease(live ?? [])
            expectEqual(newest != nil, true, "真网: 挑得出版本最高的 Release(\(newest?.tag ?? "-"))")
        }
    }
}
