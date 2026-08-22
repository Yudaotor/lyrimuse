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
            // 载荷形状 + 压缩都在 Core(LyricsBackupArchive.Payload/encode):那是磁盘格式
            // 契约,selftest 对它断言。
            let payload = LyricsBackupArchive.Payload(
                at: ISO8601DateFormatter().string(from: Date()),
                device: Host.current().localizedName ?? "",
                files: files,
                pins: pins
            )
            let out = LyricsBackupArchive.encode(payload)
            logger.notice("buildArchive: \(files.count) files → \(out?.count ?? 0) bytes")
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
        var total: Int { added + overwritten }
    }

    /// 把归档铺回歌词目录 + 并回「已校准」名单。
    ///
    /// ⚠️ 调用顺序要紧:必须排在 features.json 导入**之后** —— 歌词目录是
    /// `features.lyricsDir`(用户可自定义的绝对路径),先铺后导会铺到旧机器那个目录里去。
    static func restore(from data: Data) async -> RestoreResult? {
        // ⚠️ 目录必须在这一刻(features.json 已经导入完之后)才取。
        let dir = FeatureSettingsStore.shared.effectiveLyricsDir
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
            return (result, payload.pins)
        }.value
        guard var result = outcome?.0, let pins = outcome?.1 else { return nil }
        // pins 走 @MainActor 的 store(它有 @Published,不能在后台改)。
        result.pinsAdded = LyricsPinStore.shared.merge(pins)
        logger.notice("restore: +\(result.added) ~\(result.overwritten) !\(result.failed) x\(result.rejected) pins+\(result.pinsAdded)")
        return result
    }
}
