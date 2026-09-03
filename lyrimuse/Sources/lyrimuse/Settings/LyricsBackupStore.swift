import Foundation
import LyrimuseCore
import OSLog

/// 「歌词库备份」的文件 IO —— 把 `lyrics/` 文件族 + 「已校准」名单打成一份 sidecar 归档,
/// 以及把它铺回去。判断规则(文件名安全、账目)全在 `LyrimuseCore.LyricsBackupArchive`
/// (纯函数、selftest 覆盖),这里只负责读写盘和压缩。
///
/// 为什么是 sidecar、为什么备份文件族而不是 enrich 缓存,见 `LyricsBackupArchive` 的注释。
@MainActor
enum LyricsBackupStore {
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lyrics-backup")

    /// enrich 缓存(打包 `meta` 时**只读**它)。
    ///
    /// ⚠️ 同一个路径在 `EnrichCacheReader` 和 `EnrichCacheStore` 里各有一份 `private static let`
    /// —— 那两处都是私有的,为了这里一次只读访问去放宽它们的可见性不值得,所以这是第三份。
    /// 三处必须一致;真要收拢,该收进 Core 的一个 public 常量里,那是另一件事。
    private static let enrichCacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lyrimuse/lyrimuse-enrich-cache.json")

    /// 恢复时把 `meta` 落成这份**待采纳**文件,由 collector 在启动路径里合并进缓存
    /// (`lyrimuse-collector/enrichrestore.go` 的 `adoptEnrichRestore`,采纳成功后自己删掉)。
    ///
    /// 为什么不在这里直接盖 `lyrimuse-enrich-cache.json`:collector 内存里握着整份缓存、
    /// 有七处会整份写回磁盘,盖了大概率被它盖回去(2026-08-14「清空了又回来」)。交给
    /// collector 自己在启动时合并,跟 `lyrics/` 文件族被 `importLyricsFromFiles` 采纳
    /// 是同一个时机、同一把 `enrichMu` 锁,天然没有竞态。
    private static let enrichRestoreURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lyrimuse/lyrimuse-enrich-restore.json")

    /// 当前这台机器上歌词库的规模,给设置页那句"约 N MB"用。**不读文件内容**(只 stat),
    /// 所以进设置页调它是廉价的。
    static func currentSize() -> (files: Int, bytes: Int) {
        let dir = FeatureSettingsStore.shared.effectiveLyricsDir
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return (0, 0)
        }
        var count = 0
        var bytes = 0
        for name in names where EnrichCacheKeys.lyricsFileSuffixes.contains(where: { name.hasSuffix($0) }) {
            let path = dir.appendingPathComponent(name).path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int else { continue }
            count += 1
            bytes += size
        }
        return (count, bytes)
    }

    /// 打一份归档。没有任何歌词文件时返回 nil(不写一份空包出去)。
    ///
    /// 读 3000 个小文件 + 编码 14.5 MB + 压缩,实测几百毫秒到一秒级 —— 所以主线程只取"目录
    /// 在哪、pins 是什么"这两个 @MainActor 状态,重活整段扔进 detached task。调用方是 alert
    /// 的确认按钮(SettingsView),那里不能卡。
    static func buildArchive() async -> Data? {
        let dir = FeatureSettingsStore.shared.effectiveLyricsDir
        let pins = LyricsPinStore.shared.pins
        let cacheURL = enrichCacheURL
        return await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
                logger.notice("buildArchive: no lyrics dir at \(dir.path, privacy: .public)")
                return nil
            }
            var files: [String: String] = [:]
            for name in names {
                guard LyricsBackupArchive.sanitizedFileName(name) != nil else { continue }
                guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                else { continue }
                files[name] = text
            }
            guard !files.isEmpty else { return nil }
            // enrich 缓存剥掉六个歌词字段之后的那一份(2026-09-02,见 LyricsBackupArchive
            // 头注:决策存档/纯文本采纳/手动选定凭据/打分版本这几类**不是**可重新解析的
            // 派生数据)。读+解析 42 MB JSON 也在这条 detached 路径上,不碰主线程。
            //
            // 读不出来/解不出来只是**少带这一部分**,不让整份备份失败:歌词文件族才是这份
            // sidecar 的主体,为了 meta 把它一起废掉是本末倒置。
            var meta: Data?
            if let cacheData = try? Data(contentsOf: cacheURL) {
                meta = LyricsBackupArchive.strippedMeta(fromCacheJSON: cacheData)
                if meta == nil {
                    logger.error("buildArchive: enrich cache present (\(cacheData.count) bytes) but strippedMeta returned nil")
                }
            } else {
                logger.notice("buildArchive: no enrich cache at \(cacheURL.path, privacy: .public)")
            }
            // 载荷形状 + 压缩都在 Core(LyricsBackupArchive.Payload/encode):那是磁盘格式
            // 契约,selftest 对它断言。
            let payload = LyricsBackupArchive.Payload(
                at: ISO8601DateFormatter().string(from: Date()),
                device: Host.current().localizedName ?? "",
                files: files,
                pins: pins,
                meta: meta
            )
            let out = LyricsBackupArchive.encode(payload)
            logger.notice("buildArchive: \(files.count) files, meta \(meta?.count ?? 0) bytes → \(out?.count ?? 0) bytes")
            return out
        }.value
    }

    /// 只看一眼归档里有多少东西(给导入前那句确认文案报数),不落盘、不改任何状态。
    /// 解压 + 解码 6 MB 同样不该在主线程做。
    static func peek(_ data: Data) async -> (files: Int, pins: Int)? {
        await Task.detached(priority: .userInitiated) { () -> (files: Int, pins: Int)? in
            guard let payload = LyricsBackupArchive.decode(data) else { return nil }
            return (payload.files.count, payload.pins.count)
        }.value
    }

    struct RestoreResult {
        var added = 0
        var overwritten = 0
        var rejected = 0
        var failed = 0
        var pinsAdded = 0
        /// `meta` 那份待采纳文件的字节数;0 = 这份备份不带(v1 老包)或写盘失败。
        /// 真正生效是在 collector 下一次启动时(见 enrichRestoreURL 的注释)。
        var metaBytes = 0
        var total: Int { added + overwritten }
    }

    /// 把归档铺回歌词目录 + 并回「已校准」名单。
    ///
    /// ⚠️ 调用顺序要紧:必须排在 features.json 导入**之后** —— 歌词目录是
    /// `features.lyricsDir`(用户可自定义的绝对路径),先铺后导会铺到旧机器那个目录里去。
    static func restore(from data: Data) async -> RestoreResult? {
        // ⚠️ 目录必须在这一刻(features.json 已经导入完之后)才取。
        let dir = FeatureSettingsStore.shared.effectiveLyricsDir
        let restoreURL = enrichRestoreURL
        let outcome = await Task.detached(priority: .userInitiated) { () -> (RestoreResult, [String: Int])? in
            guard let payload = LyricsBackupArchive.decode(data) else {
                logger.error("restore: payload decode failed (\(data.count) bytes)")
                return nil
            }
            if payload.v > LyricsBackupArchive.payloadVersion {
                // 跟配置包同一个口径:只留痕,不拒绝 —— 未知字段本来就会被忽略。
                logger.warning("restore: archive v\(payload.v) newer than v\(LyricsBackupArchive.payloadVersion)")
            }
            var result = RestoreResult()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            let plan = LyricsBackupArchive.plan(incoming: Array(payload.files.keys), existing: existing)
            result.rejected = plan.rejected.count
            if !plan.rejected.isEmpty {
                logger.error("restore: rejected \(plan.rejected.count) unsafe names, first=\(plan.rejected[0], privacy: .public)")
            }
            // 落盘前的最后一道闸,跟"名字长什么样"无关:把 URL 解析(standardized)之后,它的
            // 父目录必须还是歌词目录本身。名字规则(sanitizedFileName)是第一道,这一道兜住
            // "规则里没想到的形态" —— 两道都在,是因为写文件这件事错一次就是往用户磁盘上
            // 别的地方写东西。
            let dirPath = dir.standardizedFileURL.path
            for (name, isNew) in plan.added.map({ ($0, true) }) + plan.overwritten.map({ ($0, false) }) {
                guard let text = payload.files[name] else { continue }
                let target = dir.appendingPathComponent(name).standardizedFileURL
                guard target.deletingLastPathComponent().path == dirPath else {
                    result.rejected += 1
                    logger.error("restore: path escapes lyrics dir, refused: \(name, privacy: .public)")
                    continue
                }
                do {
                    try text.write(to: target, atomically: true, encoding: .utf8)
                    if isNew { result.added += 1 } else { result.overwritten += 1 }
                } catch {
                    result.failed += 1
                    logger.error("restore: write failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            // enrich 缓存的非歌词字段:只落一份**待采纳**文件,不碰缓存本身(理由见
            // enrichRestoreURL 的注释)。真正合并进缓存发生在 collector 下一次启动 ——
            // 跟歌词文件族被 importLyricsFromFiles 采纳是同一个时机,所以调用方本来就要
            // 走的那次重启一并把这两件事都落地,不需要额外的时序安排。
            //
            // ⚠️ 写失败只记日志、不算恢复失败:歌词文件已经铺好了(那是主体),把整次恢复
            // 判成失败反而会让用户以为歌词也没进去。
            if let meta = payload.meta, !meta.isEmpty {
                do {
                    // 跟 enrich 缓存本身同一档权限(盘上那份是 0600),没必要比它宽。
                    try meta.writeSecurely(to: restoreURL)
                    result.metaBytes = meta.count
                } catch {
                    logger.error("restore: writing enrich-restore file failed — \(error.localizedDescription, privacy: .public)")
                }
            }
            return (result, payload.pins)
        }.value
        guard var result = outcome?.0, let pins = outcome?.1 else { return nil }
        // pins 走 @MainActor 的 store(它有 @Published,不能在后台改)。
        result.pinsAdded = LyricsPinStore.shared.merge(pins)
        logger.notice("restore: +\(result.added) ~\(result.overwritten) !\(result.failed) x\(result.rejected) pins+\(result.pinsAdded) meta=\(result.metaBytes)B")
        return result
    }

    // MARK: - 破坏性操作前的自动快照

    /// 自动快照落点。放在 `~/.config/lyrimuse/` 下面而不是 iCloud 备份文件夹:这是"手滑
    /// 之后马上要用"的东西,不该受"用户有没有配 iCloud / 那个目录还在不在"的影响,也不该
    /// 每次清空都往用户的云盘里塞几 MB。`uninstall.sh --purge` 删整个 CONFIG_DIR,顺带
    /// 把它收走,不用另外维护一条清理路径。
    static var autoSnapshotDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/lyrimuse/lyrics-backups")
    }

    /// 只保留最近这么多份。歌词库实测 14.5 MB → 压缩后 6.1 MB,三份约 18 MB —— 够覆盖
    /// "清空 → 发现不对"这个窗口,又不至于在用户不知情的地方长成一个无上限的黑洞
    /// (那正是配置包 sidecar 当初被否掉进 iCloud 的理由之一,见 14 章 §4)。
    static let autoSnapshotKeepCount = 3

    struct Snapshot: Identifiable, Hashable {
        var url: URL
        var date: Date
        var bytes: Int
        var id: URL { url }
    }

    /// 在破坏性操作**之前**打一份快照。返回落点;没有歌词文件(没什么可备份的)或写盘失败
    /// 时返回 nil —— 调用方据此决定要不要如实告诉用户"这次没有备份"。
    ///
    /// 为什么必须有它:`EnrichCacheStore.clearAll()` 走的是 `removeItem`(不是废纸篓)+
    /// 整份替换落盘,一旦执行没有任何可恢复层。docs/features/11 已知坑 7 记的那次
    /// 「833 条手工修正丢失」,在加这个之前的代码上会一字不差地重演一遍。
    ///
    /// `reason` 只进文件名,给用户在 Finder 里认得出是哪一次操作(clear / delete)。
    static func writeAutoSnapshot(reason: String) async -> URL? {
        guard let data = await buildArchive() else {
            logger.notice("autoSnapshot(\(reason, privacy: .public)): nothing to back up")
            return nil
        }
        let dir = autoSnapshotDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = dir.appendingPathComponent("auto-\(reason)-\(formatter.string(from: Date())).lyrimusebak")
        do {
            // writeSecurely:跟配置包同一条路径,权限 0600(歌词内容本身不敏感,但没必要比
            // 旁边那份宽)。
            try data.writeSecurely(to: url)
        } catch {
            logger.error("autoSnapshot(\(reason, privacy: .public)): write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        logger.notice("autoSnapshot(\(reason, privacy: .public)): wrote \(data.count) bytes to \(url.lastPathComponent, privacy: .public)")
        pruneAutoSnapshots()
        return url
    }

    /// 现有的自动快照,**按时间倒序**(最新的在前)——恢复入口默认就该指向刚刚那一份。
    static func autoSnapshots() -> [Snapshot] {
        let dir = autoSnapshotDir
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
        else { return [] }
        return urls
            .filter { $0.pathExtension == "lyrimusebak" }
            .compactMap { url -> Snapshot? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let date = values.contentModificationDate else { return nil }
                return Snapshot(url: url, date: date, bytes: values.fileSize ?? 0)
            }
            .sorted { $0.date > $1.date }
    }

    /// 轮转:超出 `autoSnapshotKeepCount` 的旧快照删掉。
    ///
    /// ⚠️ 这里**逐个删确切的 URL**,不用任何通配 —— 这个目录理论上只有我们自己写的东西,
    /// 但 `autoSnapshots()` 已经按扩展名筛过一遍,删的必须是那份筛出来的清单里的元素,
    /// 不能对目录做 removeItem。
    private static func pruneAutoSnapshots() {
        let snapshots = autoSnapshots()
        guard snapshots.count > autoSnapshotKeepCount else { return }
        for snapshot in snapshots[autoSnapshotKeepCount...] {
            try? FileManager.default.removeItem(at: snapshot.url)
            logger.notice("autoSnapshot: pruned \(snapshot.url.lastPathComponent, privacy: .public)")
        }
    }

    /// 从一份自动快照恢复。走的就是配置导入那条 `restore(from:)`,不另开一套铺盘逻辑
    /// (路径安全那两道闸必须共用)。
    static func restoreAutoSnapshot(_ snapshot: Snapshot) async -> RestoreResult? {
        guard let data = try? Data(contentsOf: snapshot.url) else {
            logger.error("restoreAutoSnapshot: cannot read \(snapshot.url.lastPathComponent, privacy: .public)")
            return nil
        }
        return await restore(from: data)
    }
}
