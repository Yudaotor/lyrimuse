import Foundation
import LyrimuseCore

// 凭据保险箱(Core CredentialVault):叠法与引擎对拍、拆分、真起 /usr/bin/security 读写一份临时钥匙串。
// 临时钥匙串不进搜索列表,不碰用户的登录钥匙串。
@MainActor
func credentialVaultChecks() {
    do {
        print("\n== 凭据保险箱: 叠法(与引擎对拍) ==")
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Sources/lyrimuse-selftest
            .deletingLastPathComponent()   // …/Sources
            .deletingLastPathComponent()   // …/lyrimuse
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("lyrimuse-engine/testdata/credentialvault/overlay.json")
        let doc = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let cases = doc?["cases"] as? [[String: Any]] ?? []
        expectEqual(cases.isEmpty, false, "保险箱对拍: 读得到 lyrimuse-engine/testdata/credentialvault/overlay.json")
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let got = CredentialVault.overlay(c["file"] as? [String: Any] ?? [:], vault: c["vault"] as? [String: Any] ?? [:])
            expectEqual(NSDictionary(dictionary: got), NSDictionary(dictionary: c["want"] as? [String: Any] ?? [:]),
                        "保险箱对拍: \(name)")
        }
    }

    do {
        print("\n== 凭据保险箱: 拆分 ==")
        let full: [String: Any] = [
            "listenbrainz_token": "t", "listenbrainz_user": "u", "state_relay_token": "",
            "notification_webhook_urls": ["telegram": "123:abc"], "api_root": "https://x",
            "notification_channels": [
                ["id": "a", "platform": "ntfy", "url": "https://ntfy.example/a", "secret": "tk", "enabled": true],
                ["id": "b", "platform": "bark", "url": "", "enabled": false],
            ],
        ]
        let parts = CredentialVault.split(full)
        expectEqual(Set(parts.file.keys), ["listenbrainz_user", "api_root", "notification_channels"],
                    "拆分: 落盘那份不带任何凭据键(空值的也删)")
        expectEqual(NSDictionary(dictionary: parts.config),
                    NSDictionary(dictionary: ["listenbrainz_token": "t", "notification_webhook_urls": ["telegram": "123:abc"]]),
                    "拆分: 保险箱只收有值的凭据")
        let fileChannels = parts.file["notification_channels"] as? [[String: Any]] ?? []
        expectEqual(fileChannels.map { $0["url"] as? String }, ["", ""], "拆分: 渠道地址落盘写空串")
        expectEqual(fileChannels.contains { $0["secret"] != nil }, false, "拆分: 渠道密钥不落盘")
        expectEqual(fileChannels.map { $0["enabled"] as? Bool }, [true, false], "拆分: 渠道的其余字段原样")
        expectEqual(NSDictionary(dictionary: parts.channels),
                    NSDictionary(dictionary: ["a": ["url": "https://ntfy.example/a", "secret": "tk"]]),
                    "拆分: 渠道按 id 收地址和密钥,两样都空的不收")
        let vault: [String: Any] = [CredentialVault.configSection: parts.config, CredentialVault.channelsSection: parts.channels]
        expectEqual(NSDictionary(dictionary: CredentialVault.overlay(parts.file, vault: vault)),
                    NSDictionary(dictionary: full.filter { $0.key != "state_relay_token" }),
                    "拆分再叠回去还是原来那份(空值的凭据键除外)")
        expectEqual(CredentialVault.hasPlaintext(full), true, "明文判定: 有凭据")
        expectEqual(CredentialVault.hasPlaintext(parts.file), false, "明文判定: 拆完的那份没有")
        expectEqual(CredentialVault.hasPlaintext(["listenbrainz_token": "  ", "notification_webhook_urls": [String: String]()]), false,
                    "明文判定: 空白和空表不算")
        let channels: [[String: Any]] = [["id": "a", "url": "https://ntfy.example/a", "secret": "tk"]]
        let before: [String: Any] = ["listenbrainz_token": "t", "listenbrainz_user": "u", "notification_channels": channels]
        expectEqual(CredentialVault.clearsCredential(from: before, to: before.merging(["listenbrainz_user": ""]) { $1 }), false,
                    "清空判定: 改的不是凭据")
        expectEqual(CredentialVault.clearsCredential(from: before, to: before.merging(["listenbrainz_token": " "]) { $1 }), true,
                    "清空判定: token 写成空白")
        expectEqual(CredentialVault.clearsCredential(from: before.merging(["listenbrainz_token": ""]) { $1 },
                                                     to: before.merging(["listenbrainz_token": ""]) { $1 }), false,
                    "清空判定: 本来就空")
        expectEqual(CredentialVault.clearsCredential(from: before, to: before.merging(["notification_channels": [[String: Any]]()]) { $1 }), false,
                    "清空判定: 整个渠道删掉不算(文件里没这个渠道,保险箱那份叠不回来)")
        expectEqual(CredentialVault.clearsCredential(from: before, to: before.merging(["notification_channels": [["id": "a", "url": "https://ntfy.example/a"]]]) { $1 }), true,
                    "清空判定: 留着的渠道密钥清空")
        let encoded = try? CredentialVault.encode(vault)
        expectEqual(encoded.flatMap(CredentialVault.decode).map { NSDictionary(dictionary: $0) }, NSDictionary(dictionary: vault),
                    "编码: base64 往返")
    }

    do {
        print("\n== 凭据保险箱: 真钥匙串读写 ==")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyrimuse-vault-\(UUID().uuidString)")
        _ = FileIO.createDirectory(dir)
        defer { FileIO.remove(dir) }
        let keychainPath = dir.appendingPathComponent("vault.keychain-db").path
        let created = ProcessRunner.run("/usr/bin/security", ["create-keychain", "-p", "test", keychainPath], timeout: 10)
        guard created?.succeeded == true else {
            expectEqual(false, true, "真钥匙串: 建不了临时钥匙串")
            return
        }
        defer { _ = ProcessRunner.run("/usr/bin/security", ["delete-keychain", keychainPath], timeout: 10) }
        let cli = KeychainCLI(service: "me.yudaotor.lyrimuse.selftest", account: "/tmp/with space/lyrimuse", keychain: keychainPath)

        expectEqual(credentialVaultReadOutcome(cli), "没有条目", "真钥匙串: 没有条目读到 nil")
        let store = CredentialVaultStore(keychain: cli)
        expectEqual(store.load().map { NSDictionary(dictionary: $0) }, NSDictionary(), "真钥匙串: 没有条目是空保险箱")
        let written = try? store.update { $0[CredentialVault.configSection] = ["listenbrainz_token": "t1"] }
        expectEqual(written != nil, true, "真钥匙串: 写入")
        let fresh = CredentialVaultStore(keychain: cli)
        expectEqual((fresh.load()?[CredentialVault.configSection] as? [String: Any])?["listenbrainz_token"] as? String, "t1",
                    "真钥匙串: 另一份 store 读回来是刚写的(账号带空格也行)")
        _ = try? fresh.update { $0[CredentialVault.mediaUserTokenKey] = "m" }
        expectEqual(CredentialVaultStore(keychain: cli).load()?.keys.sorted(), [CredentialVault.configSection, CredentialVault.mediaUserTokenKey],
                    "真钥匙串: 读改写保留别的段")

        let huge = String(repeating: "A", count: KeychainCLI.maxCommandBytes)
        var tooLong: KeychainCLI.Failure?
        do { try cli.write(huge) } catch let failure as KeychainCLI.Failure { tooLong = failure } catch {}
        expectEqual(tooLong, .tooLong, "真钥匙串: 超过一行上限的直接拒绝")
        expectEqual(CredentialVaultStore(keychain: cli).load()?[CredentialVault.mediaUserTokenKey] as? String, "m",
                    "真钥匙串: 拒绝之后原内容不动(security -i 超长会写进截断的值)")
        var bad: KeychainCLI.Failure?
        do { try cli.write("not base64!") } catch let failure as KeychainCLI.Failure { bad = failure } catch {}
        expectEqual(bad, .badArgument, "真钥匙串: 不是 base64 文本的值拒绝")

        _ = try? fresh.update { $0[CredentialVault.channelsSection] = ["a": ["url": "u"]] }
        let cleared = CredentialVaultStore(keychain: cli)
        expectEqual((try? cleared.clearAccountCredentials()) != nil, true, "清账号凭据: 写入")
        expectEqual(CredentialVaultStore(keychain: cli).load()?.keys.sorted(), [CredentialVault.mediaUserTokenKey],
                    "清账号凭据: config 和 channels 两段去掉,Apple Music 令牌留着")

        _ = try? fresh.update { $0.removeAll() }
        expectEqual(credentialVaultReadOutcome(cli), "没有条目", "真钥匙串: 清空 = 删掉条目")

        try? cli.write(Data("not json".utf8).base64EncodedString())
        let corrupt = CredentialVaultStore(keychain: cli)
        expectEqual(corrupt.load() == nil, true, "内容坏了: load 读不出")
        expectEqual((try? corrupt.clearAccountCredentials()) != nil, true, "内容坏了: 清账号凭据把整条删掉")
        expectEqual(credentialVaultReadOutcome(cli), "没有条目", "内容坏了: 删完没有条目")
        expectEqual(corrupt.load().map { NSDictionary(dictionary: $0) }, NSDictionary(), "内容坏了: 删完是空保险箱")
    }

    do {
        print("\n== 凭据保险箱: 限时与读不出来 ==")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyrimuse-vault-\(UUID().uuidString)")
        _ = FileIO.createDirectory(dir)
        defer { FileIO.remove(dir) }
        let script = dir.appendingPathComponent("security")
        _ = FileIO.write(Data("#!/bin/sh\nexec sleep 5\n".utf8), to: script)
        _ = ProcessRunner.run("/bin/chmod", ["755", script.path], timeout: 5)
        var cli = KeychainCLI(service: "s", account: "a")
        cli.executable = script.path
        cli.timeout = 0.1
        let start = Date()
        var failure: KeychainCLI.Failure?
        do { _ = try cli.read() } catch let f as KeychainCLI.Failure { failure = f } catch {}
        expectEqual(failure, .timedOut, "限时: 钥匙串锁着(security 一直不返回)时报超时")
        expectEqual(Date().timeIntervalSince(start) < 3, true, "限时: 到点就放弃,不等子进程自己结束")
        let store = CredentialVaultStore(keychain: cli)
        expectEqual(store.load() == nil, true, "读不出来: load 返回 nil(跟没有条目分开)")
        var unreadable: KeychainCLI.Failure?
        do { try store.update { $0["x"] = "y" } } catch let f as KeychainCLI.Failure { unreadable = f } catch {}
        expectEqual(unreadable, .unreadable, "读不出来: 读改写拒绝,不在不知道原内容时覆盖")
        var clearFailure: KeychainCLI.Failure?
        do { try store.clearAccountCredentials() } catch let f as KeychainCLI.Failure { clearFailure = f } catch {}
        expectEqual(clearFailure, .timedOut, "读不出来: 清账号凭据也抛错,不去删条目")
    }
}

/// 读一次条目:「没有条目」、「出错」或读到的文本。`try?` 会把「出错」和「没有条目」压成同一个 nil,所以分开写。
private func credentialVaultReadOutcome(_ cli: KeychainCLI) -> String {
    do { return try cli.read() ?? "没有条目" } catch { return "出错: \(error)" }
}
