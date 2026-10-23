import Darwin
import Foundation
import LyrimuseCore

// 存储布局:数据目录选哪个、钥匙串账号、启动时从旧目录搬到新布局(整份改名 / 跨卷复制、改写文件里的旧路径、缓存挪进缓存目录)。
// 全在临时目录里造家目录,不碰真实数据。由 identity 组调用。

func runStorageLayoutChecks() {
    print("\n== 存储布局 ==")
    let fm = FileManager.default
    let sandbox = fm.temporaryDirectory.appendingPathComponent("lyrimuse-storage-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: sandbox) }

    func makeHome(_ name: String) -> (URL, StorageLayout.Roots) {
        let home = sandbox.appendingPathComponent(name)
        try? fm.createDirectory(at: home, withIntermediateDirectories: true)
        return (home, StorageLayout.roots(home: home))
    }
    func write(_ text: String, _ url: URL, mode: Int? = nil) {
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
        if let mode { try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
    }
    func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    do {
        let (home, roots) = makeHome("paths")
        expectEqual(roots.legacy.path, home.path + "/.config/lyrimuse", "存储布局: 旧目录 ~/.config/lyrimuse")
        expectEqual(roots.data.path, home.path + "/Library/Application Support/me.yudaotor.lyrimuse",
                    "存储布局: 数据目录 ~/Library/Application Support/<bundle id>")
        expectEqual(roots.caches.path, home.path + "/Library/Caches/me.yudaotor.lyrimuse", "存储布局: 缓存目录 ~/Library/Caches/<bundle id>")

        expectEqual(StorageLayout.activeDataDir(roots), roots.data, "存储布局: 全新安装直接用新目录")
        try? fm.createDirectory(at: roots.legacy, withIntermediateDirectories: true)
        expectEqual(StorageLayout.activeDataDir(roots), roots.data, "存储布局: 旧目录是空的就用新目录")
        expectEqual(StorageLayout.hasLegacyToAbsorb(roots), true, "存储布局: 旧位置有真目录 = 要收")
        write("{}", roots.legacy.appendingPathComponent("config.json"))
        expectEqual(StorageLayout.activeDataDir(roots), roots.legacy, "存储布局: 还没搬时照旧用旧目录")
        write("x", roots.data.appendingPathComponent("unrelated"))
        expectEqual(StorageLayout.activeDataDir(roots), roots.legacy,
                    "存储布局: 新目录先被别的东西建了出来、里面没有数据,照旧用旧目录(看内容,不看目录在不在)")
        write("{}", roots.data.appendingPathComponent("lyrimuse-storage-migration.json"))
        expectEqual(StorageLayout.activeDataDir(roots), roots.data, "存储布局: 新目录搬过(有标记),旧目录是残留,用新目录")
        try? fm.removeItem(at: roots.legacy)
        expectEqual(StorageLayout.hasLegacyToAbsorb(roots), false, "存储布局: 旧目录没了就没东西要收")
        let custom = home.appendingPathComponent("elsewhere")
        try? fm.createDirectory(at: custom, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: roots.legacy, withDestinationURL: custom)
        expectEqual(StorageLayout.activeDataDir(roots), roots.legacy, "存储布局: 旧目录是软链接 = 用户指定的位置,一直用它")
        expectEqual(StorageLayout.hasLegacyToAbsorb(roots), false, "存储布局: 软链接不搬")
        let mapped = { StorageLayout.mappingLegacyPath($0, roots: roots, dataDir: roots.data) }
        expectEqual(mapped(roots.legacy.path + "/lyrics"), roots.data.path + "/lyrics", "存储布局: 旧目录里的路径换成数据目录里同一个位置")
        expectEqual(mapped(roots.legacy.path), roots.data.path, "存储布局: 旧目录本身换成数据目录")
        expectEqual(mapped(roots.legacy.path + "-backups/x"), roots.legacy.path + "-backups/x", "存储布局: 兄弟目录不换")
        expectEqual(mapped("/Volumes/X/lyrics"), "/Volumes/X/lyrics", "存储布局: 别处的路径不换")

        expectEqual(StorageLayout.credentialAccount(dataDir: roots.data, roots: roots), roots.legacy.path,
                    "存储布局: 钥匙串账号在新目录下仍是旧路径串(搬目录不迁钥匙串)")
        expectEqual(StorageLayout.credentialAccount(dataDir: roots.legacy, roots: roots), roots.legacy.path, "存储布局: 旧目录的账号不变")
        expectEqual(StorageLayout.credentialAccount(dataDir: custom, roots: roots), custom.path, "存储布局: 另起的数据目录按自己的路径隔开")
        expectEqual(StorageLayout.diagnosticLine(roots: roots, active: roots.data, home: home.path),
                    "Data folder: ~/Library/Application Support/me.yudaotor.lyrimuse (old ~/.config/lyrimuse: symlink)",
                    "存储布局: 诊断行写清用的哪个目录、旧目录的状态,家目录写成 ~")
    }

    do {
        // 整份搬:同卷改名,文件里的旧路径换成新路径(原样与 JSON 转义两种写法),兄弟目录和歌词文本不碰,权限位保留;缓存挪走。
        let (home, roots) = makeHome("move")
        let old = roots.legacy.path, new = roots.data.path
        write("{\"token\":\"x\"}", roots.legacy.appendingPathComponent("config.json"), mode: 0o600)
        write("{\"cover_url\":\"file://\(old)/artwork/a.jpg\",\"b\":\"file://\(old)/artwork/b.jpg\",\"dir\":\"\(old)\"}",
              roots.legacy.appendingPathComponent("lyrimuse-enrich-cache.json"))
        let escapedOld = old.replacingOccurrences(of: "/", with: "\\/")
        write("{\"u\":\"file:\\/\\/\(escapedOld)\\/artwork\\/c.jpg\"}", roots.legacy.appendingPathComponent("lyrimuse-song-entity-pre/1.json"))
        write("{\"backup\":\"\(old)-backups/x.json\"}", roots.legacy.appendingPathComponent("lyrimuse-notes.json"))
        write("[00:01.00]\(old)/artwork", roots.legacy.appendingPathComponent("lyrics/a.lrc"))
        write("jpg", roots.legacy.appendingPathComponent("artwork/a.jpg"))
        write("{}", roots.legacy.appendingPathComponent("x-cache.json"))
        try? fm.createSymbolicLink(at: roots.legacy.appendingPathComponent("link"), withDestinationURL: home)

        expectEqual(StorageMigration.isPending(roots, cacheNames: ["x-cache.json"]), true, "存储搬迁: 旧目录在 = 有活")
        let outcome = StorageMigration.run(roots, cacheNames: ["x-cache.json"])
        expectEqual(outcome.movedRoot, true, "存储搬迁: 同卷一次改名")
        expectEqual(outcome.copiedRoot, false, "存储搬迁: 同卷不复制")
        expectEqual(outcome.failures, [], "存储搬迁: 没有失败")
        expectEqual(fm.fileExists(atPath: roots.legacy.path), false, "存储搬迁: 旧目录不留(也不留软链接)")
        expectEqual(read(roots.data.appendingPathComponent("lyrimuse-enrich-cache.json")),
                    "{\"cover_url\":\"file://\(new)/artwork/a.jpg\",\"b\":\"file://\(new)/artwork/b.jpg\",\"dir\":\"\(new)\"}",
                    "存储搬迁: 设备封面的 file:// 地址和存成值的旧目录都换成新目录")
        let escapedNew = new.replacingOccurrences(of: "/", with: "\\/")
        expectEqual(read(roots.data.appendingPathComponent("lyrimuse-song-entity-pre/1.json")),
                    "{\"u\":\"file:\\/\\/\(escapedNew)\\/artwork\\/c.jpg\"}", "存储搬迁: 子目录里、JSON 转义写法的也换")
        expectEqual(read(roots.data.appendingPathComponent("lyrimuse-notes.json")), "{\"backup\":\"\(old)-backups/x.json\"}",
                    "存储搬迁: 旧目录名开头的兄弟目录不碰")
        expectEqual(read(roots.data.appendingPathComponent("lyrics/a.lrc")), "[00:01.00]\(old)/artwork", "存储搬迁: 歌词文本不看")
        expectEqual(outcome.rewrittenFiles, 2, "存储搬迁: 只改写了含旧路径的两份")
        let backup = outcome.rewriteBackup.map { URL(fileURLWithPath: $0) }
        expectEqual(backup.flatMap { read($0.appendingPathComponent("lyrimuse-enrich-cache.json")) },
                    "{\"cover_url\":\"file://\(old)/artwork/a.jpg\",\"b\":\"file://\(old)/artwork/b.jpg\",\"dir\":\"\(old)\"}",
                    "存储搬迁: 改写之前原件存进 backups/<时刻>-storage-migration(内容是改写前的)")
        expectEqual(backup.map { fm.fileExists(atPath: $0.appendingPathComponent("lyrimuse-song-entity-pre/1.json").path) }, true,
                    "存储搬迁: 子目录里的原件按相对路径存")
        expectEqual(backup.map { $0.deletingLastPathComponent().path }, roots.data.appendingPathComponent("backups").path,
                    "存储搬迁: 快照在数据目录的 backups/ 下")
        let mode = (try? fm.attributesOfItem(atPath: roots.data.appendingPathComponent("config.json").path)[.posixPermissions]) as? NSNumber
        expectEqual(mode?.intValue, 0o600, "存储搬迁: 权限位跟着走")
        expectEqual(outcome.relocatedCaches, 1, "存储搬迁: 缓存挪进缓存目录")
        expectEqual(fm.fileExists(atPath: roots.caches.appendingPathComponent("x-cache.json").path), true, "存储搬迁: 缓存到了缓存目录")
        expectEqual(fm.fileExists(atPath: roots.data.appendingPathComponent("x-cache.json").path), false, "存储搬迁: 数据目录里不再有缓存")
        expectEqual(StorageMigration.isPending(roots, cacheNames: ["x-cache.json"]), false, "存储搬迁: 搬完没活了")
        expectEqual(StorageMigration.run(roots, cacheNames: ["x-cache.json"]).changedAnything, false, "存储搬迁: 重跑什么都不动")
        let marker = read(roots.data.appendingPathComponent("lyrimuse-storage-migration.json")) ?? ""
        expectEqual(marker.contains("\"rewritePending\" : false") && marker.contains(old), true, "存储搬迁: 标记文件记着从哪搬、改写已完成")
    }

    do {
        // 改写没做完(上次中途失败)时下次启动接着改;缓存目录已有同名的以缓存目录为准。
        let (_, roots) = makeHome("resume")
        let old = roots.legacy.path
        write("{\"from\":\"\(old)\",\"to\":\"\(roots.data.path)\",\"rewritePending\":true}",
              roots.data.appendingPathComponent("lyrimuse-storage-migration.json"))
        write("{\"u\":\"file://\(old)/artwork/a.jpg\"}", roots.data.appendingPathComponent("lyrimuse-playing-entry.json"))
        write("stale", roots.data.appendingPathComponent("x-cache.json"))
        write("fresh", roots.caches.appendingPathComponent("x-cache.json"))
        expectEqual(StorageMigration.isPending(roots, cacheNames: ["x-cache.json"]), true, "存储搬迁: 改写没完成 = 有活")
        let outcome = StorageMigration.run(roots, cacheNames: ["x-cache.json"])
        expectEqual(outcome.movedRoot, false, "存储搬迁: 已在新目录不再搬")
        expectEqual(read(roots.data.appendingPathComponent("lyrimuse-playing-entry.json")), "{\"u\":\"file://\(roots.data.path)/artwork/a.jpg\"}",
                    "存储搬迁: 接着改写")
        expectEqual(read(roots.caches.appendingPathComponent("x-cache.json")), "fresh", "存储搬迁: 缓存目录里已有的留着")
        expectEqual(fm.fileExists(atPath: roots.data.appendingPathComponent("x-cache.json").path), false, "存储搬迁: 数据目录里那份删掉")
        expectEqual(StorageMigration.isPending(roots, cacheNames: ["x-cache.json"]), false, "存储搬迁: 改写完成后没活了")
    }

    do {
        // 跨卷那条路:拷进暂存目录、核对清单和大小、换上去,旧目录改名留着。
        let (_, roots) = makeHome("copy")
        write("{}", roots.legacy.appendingPathComponent("config.json"), mode: 0o600)
        write("[00:01.00]词", roots.legacy.appendingPathComponent("lyrics/a.lrc"))
        write("{\"u\":\"file://\(roots.legacy.path)/artwork/a.jpg\"}", roots.legacy.appendingPathComponent("lyrimuse-enrich-cache.json"))
        let outcome = StorageMigration.run(roots, cacheNames: [], forceCopy: true)
        expectEqual(outcome.copiedRoot, true, "存储搬迁(复制): 走了复制")
        expectEqual(outcome.failures, [], "存储搬迁(复制): 没有失败")
        expectEqual(read(roots.data.appendingPathComponent("lyrics/a.lrc")), "[00:01.00]词", "存储搬迁(复制): 内容到了新目录")
        expectEqual(read(roots.data.appendingPathComponent("lyrimuse-enrich-cache.json")),
                    "{\"u\":\"file://\(roots.data.path)/artwork/a.jpg\"}", "存储搬迁(复制): 也改写旧路径")
        let kept = roots.legacy.deletingLastPathComponent().appendingPathComponent("lyrimuse.migrated")
        expectEqual(fm.fileExists(atPath: kept.appendingPathComponent("lyrics/a.lrc").path), true, "存储搬迁(复制): 旧目录改名留着")
        expectEqual(fm.fileExists(atPath: roots.legacy.path), false, "存储搬迁(复制): 旧名字下不再有目录,下次不会再搬")
        expectEqual(fm.fileExists(atPath: roots.data.path + ".incoming"), false, "存储搬迁(复制): 暂存目录不留")
    }

    do {
        // 软链接指定的位置:不搬、不改写;只有缓存要挪时才有活。
        let (home, roots) = makeHome("symlink")
        let custom = home.appendingPathComponent("elsewhere")
        write("{\"u\":\"\(roots.legacy.path)/x\"}", custom.appendingPathComponent("config.json"))
        try? fm.createDirectory(at: roots.legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: roots.legacy, withDestinationURL: custom)
        expectEqual(StorageMigration.isPending(roots, cacheNames: ["x-cache.json"]), false, "存储搬迁: 软链接且没有缓存要挪 = 没活")
        write("{}", custom.appendingPathComponent("x-cache.json"))
        let outcome = StorageMigration.run(roots, cacheNames: ["x-cache.json"])
        expectEqual(outcome.movedRoot || outcome.copiedRoot, false, "存储搬迁: 软链接不搬")
        expectEqual(read(custom.appendingPathComponent("config.json")), "{\"u\":\"\(roots.legacy.path)/x\"}", "存储搬迁: 软链接下不改写")
        expectEqual(outcome.relocatedCaches, 1, "存储搬迁: 缓存照样挪进缓存目录")
    }

    do {
        // 新目录先被别的东西建了出来(里面有别的文件):不能当成「搬过了」,把旧目录逐项合并进去,一份不丢。
        let (_, roots) = makeHome("foreign")
        write("{\"t\":1}", roots.legacy.appendingPathComponent("config.json"))
        write("[00:01.00]词", roots.legacy.appendingPathComponent("lyrics/a.lrc"))
        write("{\"u\":\"file://\(roots.legacy.path)/artwork/a.jpg\"}", roots.legacy.appendingPathComponent("lyrimuse-enrich-cache.json"))
        write("foreign", roots.data.appendingPathComponent("other.bin"))
        let outcome = StorageMigration.run(roots, cacheNames: [])
        expectEqual(outcome.failures, [], "存储搬迁(新目录已有别的东西): 没有失败")
        expectEqual(outcome.movedRoot, false, "存储搬迁(新目录已有别的东西): 走合并,不整份改名")
        expectEqual(read(roots.data.appendingPathComponent("config.json")), "{\"t\":1}", "存储搬迁(新目录已有别的东西): 配置到了")
        expectEqual(read(roots.data.appendingPathComponent("lyrics/a.lrc")), "[00:01.00]词", "存储搬迁(新目录已有别的东西): 歌词到了")
        expectEqual(read(roots.data.appendingPathComponent("other.bin")), "foreign", "存储搬迁(新目录已有别的东西): 原来的东西不动")
        expectEqual(read(roots.data.appendingPathComponent("lyrimuse-enrich-cache.json")),
                    "{\"u\":\"file://\(roots.data.path)/artwork/a.jpg\"}", "存储搬迁(新目录已有别的东西): 合并进来的也改写旧路径")
        expectEqual(fm.fileExists(atPath: roots.legacy.path), false, "存储搬迁(新目录已有别的东西): 旧目录收空删掉")
        expectEqual(StorageLayout.activeDataDir(roots), roots.data, "存储搬迁(新目录已有别的东西): 之后用新目录")
    }

    do {
        // 新目录是个空目录:跟不存在一样,整份改名过去。
        let (_, roots) = makeHome("emptydata")
        write("{}", roots.legacy.appendingPathComponent("config.json"))
        try? fm.createDirectory(at: roots.data, withIntermediateDirectories: true)
        write("", roots.data.appendingPathComponent(".DS_Store"))
        let outcome = StorageMigration.run(roots, cacheNames: [])
        expectEqual(outcome.movedRoot, true, "存储搬迁(新目录是空的): 一次改名")
        expectEqual(fm.fileExists(atPath: roots.data.appendingPathComponent("config.json").path), true, "存储搬迁(新目录是空的): 配置到了")
    }

    do {
        // 搬完之后旧目录又冒出来(旧版本、旧进程写的):新文件收进来;同名同内容的删掉;同名不同内容以数据目录为准,旧的连目录改名留着。
        let (_, roots) = makeHome("leftover")
        write("{}", roots.legacy.appendingPathComponent("config.json"))
        _ = StorageMigration.run(roots, cacheNames: [])
        write("{\"v\":\"new\"}", roots.data.appendingPathComponent("config.json"))
        write("{\"v\":\"old\"}", roots.legacy.appendingPathComponent("config.json"))
        write("same", roots.data.appendingPathComponent("lyrimuse-lyrics-pins.json"))
        write("same", roots.legacy.appendingPathComponent("lyrimuse-lyrics-pins.json"))
        write("{\"u\":\"file://\(roots.legacy.path)/artwork/b.jpg\"}", roots.legacy.appendingPathComponent("lyrimuse-enrich-restore.json"))
        write("[00:02.00]新", roots.legacy.appendingPathComponent("lyrics/b.lrc"))
        write("", roots.legacy.appendingPathComponent("collector.lock"))
        write("", roots.data.appendingPathComponent("collector.lock"))
        expectEqual(StorageLayout.activeDataDir(roots), roots.data, "存储搬迁(残留): 有残留时仍用数据目录")
        expectEqual(StorageMigration.isPending(roots, cacheNames: []), true, "存储搬迁(残留): 有残留 = 有活")
        let outcome = StorageMigration.run(roots, cacheNames: [])
        expectEqual(outcome.failures, [], "存储搬迁(残留): 没有失败")
        expectEqual(outcome.conflicts, 1, "存储搬迁(残留): 只有内容不同的那份算冲突")
        expectEqual(read(roots.data.appendingPathComponent("config.json")), "{\"v\":\"new\"}", "存储搬迁(残留): 冲突以数据目录为准")
        expectEqual(read(roots.data.appendingPathComponent("lyrics/b.lrc")), "[00:02.00]新", "存储搬迁(残留): 子目录里的新文件收进来")
        expectEqual(read(roots.data.appendingPathComponent("lyrimuse-enrich-restore.json")),
                    "{\"u\":\"file://\(roots.data.path)/artwork/b.jpg\"}", "存储搬迁(残留): 收进来的也改写旧路径")
        expectEqual(fm.fileExists(atPath: roots.legacy.path), false, "存储搬迁(残留): 旧名字下不再有目录")
        let kept = outcome.keptLeftover.map { URL(fileURLWithPath: $0) }
        expectEqual(kept.flatMap { read($0.appendingPathComponent("config.json")) }, "{\"v\":\"old\"}",
                    "存储搬迁(残留): 冲突的旧版本留在改名后的目录里,不删")
        expectEqual(kept.map { fm.fileExists(atPath: $0.appendingPathComponent("lyrimuse-lyrics-pins.json").path) }, false,
                    "存储搬迁(残留): 同内容的旧文件删掉")
        expectEqual(StorageMigration.isPending(roots, cacheNames: []), false, "存储搬迁(残留): 收完没活了")
    }

    do {
        // 改写前快照只留 30 天:过期的启动时删,新的、认不出时刻的、别的备份不动。
        let (_, roots) = makeHome("prune")
        let backups = roots.data.appendingPathComponent("backups")
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let oldName = formatter.string(from: now.addingTimeInterval(-40 * 24 * 3600)) + "-storage-migration"
        let freshName = formatter.string(from: now.addingTimeInterval(-2 * 24 * 3600)) + "-storage-migration"
        for name in [oldName, freshName, "junk-storage-migration", "20200101-000000-song-entity"] {
            write("x", backups.appendingPathComponent(name).appendingPathComponent("f.json"))
        }
        expectEqual(StorageMigration.pruneRewriteBackups(in: roots.data, now: now), 1, "改写前快照: 只删一份过期的")
        expectEqual(fm.fileExists(atPath: backups.appendingPathComponent(oldName).path), false, "改写前快照: 40 天前的删掉")
        expectEqual(fm.fileExists(atPath: backups.appendingPathComponent(freshName).path), true, "改写前快照: 2 天前的留着")
        expectEqual(fm.fileExists(atPath: backups.appendingPathComponent("junk-storage-migration").path), true, "改写前快照: 认不出时刻的不动")
        expectEqual(fm.fileExists(atPath: backups.appendingPathComponent("20200101-000000-song-entity").path), true, "改写前快照: 引擎的别的备份不动")
    }

    do {
        // 整份改名失败(新目录的上一层写不进):旧目录原样留着照旧用,里面存的路径一字不改(标记里的目的地不是它)。
        let (_, roots) = makeHome("renamefail")
        let old = roots.legacy.path
        write("{\"u\":\"file://\(old)/artwork/a.jpg\"}", roots.legacy.appendingPathComponent("lyrimuse-enrich-cache.json"))
        let parent = roots.data.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        let outcome = StorageMigration.run(roots, cacheNames: [])
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        expectEqual(outcome.movedRoot || outcome.copiedRoot, false, "存储搬迁(改名失败): 没搬成")
        expectEqual(outcome.failures.isEmpty, false, "存储搬迁(改名失败): 记了失败")
        expectEqual(StorageLayout.activeDataDir(roots), roots.legacy, "存储搬迁(改名失败): 照旧用旧目录")
        expectEqual(read(roots.legacy.appendingPathComponent("lyrimuse-enrich-cache.json")), "{\"u\":\"file://\(old)/artwork/a.jpg\"}",
                    "存储搬迁(改名失败): 旧目录里的路径不改成新目录的")
        expectEqual(outcome.rewrittenFiles, 0, "存储搬迁(改名失败): 一份都没改写")
        let retry = StorageMigration.run(roots, cacheNames: [])
        expectEqual(retry.movedRoot, true, "存储搬迁(改名失败): 下次能写了就搬成")
        expectEqual(read(roots.data.appendingPathComponent("lyrimuse-enrich-cache.json")),
                    "{\"u\":\"file://\(roots.data.path)/artwork/a.jpg\"}", "存储搬迁(改名失败): 搬成之后才改写")
    }

    do {
        // 刚装好、只有偏好镜像的旧目录也算有数据;诊断行列出搬迁留下的旧目录。
        let (home, roots) = makeHome("signature")
        write("{}", roots.legacy.appendingPathComponent("lyrimuse-app-settings.json"))
        write("x", roots.data.appendingPathComponent("unrelated"))
        expectEqual(StorageLayout.activeDataDir(roots), roots.legacy, "存储布局: 只有偏好镜像的旧目录也算有数据")
        try? fm.removeItem(at: roots.legacy)
        try? fm.createDirectory(at: roots.legacy.deletingLastPathComponent().appendingPathComponent("lyrimuse.leftover-20261023-120000"),
                                withIntermediateDirectories: true)
        try? fm.createDirectory(at: roots.legacy.deletingLastPathComponent().appendingPathComponent("lyrimuse-backups"),
                                withIntermediateDirectories: true)
        expectEqual(StorageLayout.keptOldFolders(roots).map(\.lastPathComponent), ["lyrimuse.leftover-20261023-120000"],
                    "存储布局: 认得出搬迁留下的旧目录,不把兄弟目录算进去")
        expectEqual(StorageLayout.diagnosticLine(roots: roots, active: roots.data, home: home.path).hasSuffix(
            "(old ~/.config/lyrimuse: absent; kept from migration: ~/.config/lyrimuse.leftover-20261023-120000)"), true,
                    "存储布局: 诊断行报出留下的旧目录")
    }

    do {
        // 新机器上先装了新版本(数据目录新装出来、没有搬迁标记),之后用户把旧机器的 ~/.config/lyrimuse 拷了过来:冲突听旧目录的,
        // 数据目录里被换下来的那份挪进 backups/<时刻>-storage-migration-replaced,不删。
        let (_, roots) = makeHome("brought")
        write("{\"v\":\"fresh\"}", roots.data.appendingPathComponent("lyrimuse-app-settings.json"))
        write("fresh-only", roots.data.appendingPathComponent("lyrimuse-feature-flags.json"))
        write("{\"v\":\"mine\"}", roots.legacy.appendingPathComponent("lyrimuse-app-settings.json"))
        write("{\"token\":\"t\"}", roots.legacy.appendingPathComponent("config.json"))
        write("[00:01.00]旧", roots.legacy.appendingPathComponent("lyrics/a.lrc"))
        write("[00:01.00]新装", roots.data.appendingPathComponent("lyrics/a.lrc"))
        let outcome = StorageMigration.run(roots, cacheNames: [])
        expectEqual(outcome.failures, [], "存储搬迁(带来的旧目录): 没有失败")
        expectEqual(outcome.conflicts, 2, "存储搬迁(带来的旧目录): 两处冲突")
        expectEqual(read(roots.data.appendingPathComponent("lyrimuse-app-settings.json")), "{\"v\":\"mine\"}",
                    "存储搬迁(带来的旧目录): 冲突听旧目录的(用户带来的才是他的数据)")
        expectEqual(read(roots.data.appendingPathComponent("lyrics/a.lrc")), "[00:01.00]旧", "存储搬迁(带来的旧目录): 子目录里的冲突也听旧目录的")
        expectEqual(read(roots.data.appendingPathComponent("config.json")), "{\"token\":\"t\"}", "存储搬迁(带来的旧目录): 只在旧目录的收进来")
        expectEqual(read(roots.data.appendingPathComponent("lyrimuse-feature-flags.json")), "fresh-only", "存储搬迁(带来的旧目录): 只在新目录的留着")
        let replaced = outcome.replacedBackup.map { URL(fileURLWithPath: $0) }
        expectEqual(replaced.flatMap { read($0.appendingPathComponent("lyrimuse-app-settings.json")) }, "{\"v\":\"fresh\"}",
                    "存储搬迁(带来的旧目录): 被换下来的新装版本留在 backups 里")
        expectEqual(replaced.flatMap { read($0.appendingPathComponent("lyrics/a.lrc")) }, "[00:01.00]新装",
                    "存储搬迁(带来的旧目录): 子目录里被换下来的按相对路径留")
        expectEqual(fm.fileExists(atPath: roots.legacy.path), false, "存储搬迁(带来的旧目录): 旧目录收空删掉")
        expectEqual(outcome.keptLeftover, nil, "存储搬迁(带来的旧目录): 不留 leftover")
        expectEqual(StorageMigration.pruneRewriteBackups(in: roots.data, now: Date().addingTimeInterval(90 * 24 * 3600)), 0,
                    "存储搬迁(带来的旧目录): 被换下来的那份不按 30 天清")
    }

    do {
        // 缓存名单对账:名单里的文件,引擎和 App 都只经缓存目录拼路径,不许再从数据目录拼。先按整篇字节筛出提到名单的文件,
        // 再逐行看;Go 里把文件名放进常量的(`const x = "lyrimuse-…"`),用到这个常量的那一行也要走 cacheFilePath。
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let names = StorageLayout.cacheFileNames.filter { !$0.hasSuffix(".lock") }
        let stems = names.map { String($0.dropFirst("lyrimuse".count)) }
        var offenders: [String] = []
        var mentioned = Set<String>()
        let dataPathMarkers = ["configFilePath(", "configDir()", "cfgPath", "cfgDir"]
        let goDir = repoRoot.appendingPathComponent("lyrimuse-engine")
        let goFiles = ((try? fm.contentsOfDirectory(atPath: goDir.path)) ?? []).filter { $0.hasSuffix(".go") && !$0.hasSuffix("_test.go") }
        var goTexts: [(String, String)] = []
        var constants: [String] = []
        for f in goFiles {
            guard let text = try? String(contentsOf: goDir.appendingPathComponent(f), encoding: .utf8),
                  stems.contains(where: { sourceBytes(text, contain: $0 + "\"") }) else { continue }
            goTexts.append((f, text))
            for line in text.split(separator: "\n") where line.hasPrefix("const ") {
                guard stems.contains(where: { line.contains($0 + "\"") }),
                      let name = line.dropFirst("const ".count).split(separator: " ").first else { continue }
                constants.append(String(name))
            }
        }
        for (f, text) in goTexts {
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for (name, stem) in zip(names, stems) where line.contains(stem + "\"") {
                    mentioned.insert(name)
                    if dataPathMarkers.contains(where: { line.contains($0) }) { offenders.append("\(f):\(i + 1)") }
                }
                if constants.contains(where: { line.contains("configFilePath(\($0))") || line.contains("configDir(), \($0))") }) {
                    offenders.append("\(f):\(i + 1)")
                }
            }
        }
        let swiftRoot = repoRoot.appendingPathComponent("lyrimuse/Sources")
        for dir in ["LyrimuseCore", "lyrimuse"] {
            guard let walker = fm.enumerator(atPath: swiftRoot.appendingPathComponent(dir).path) else { continue }
            for case let rel as String in walker where rel.hasSuffix(".swift") {
                let path = swiftRoot.appendingPathComponent(dir).appendingPathComponent(rel)
                guard path.lastPathComponent != "StorageLayout.swift",
                      let text = try? String(contentsOf: path, encoding: .utf8),
                      names.contains(where: { sourceBytes(text, contain: "\"" + $0 + "\"") }) else { continue }
                for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    for name in names where line.contains("\"" + name + "\"") {
                        mentioned.insert(name)
                        if line.contains("configFile(") || line.contains("configDir") { offenders.append("\(rel):\(i + 1)") }
                    }
                }
            }
        }
        expectEqual(offenders, [], "缓存名单: 名单里的文件不许从数据目录拼路径")
        expectEqual(names.filter { !mentioned.contains($0) }, [], "缓存名单: 名单里每个文件代码里都还有人读写(删了文件要一起删名单)")
    }
}
