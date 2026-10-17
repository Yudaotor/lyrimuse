import Foundation
import LyrimuseCore

// 简介结论的落盘那一层(18 章决策 54):EditorialNotesStore 的各张结论表(EditorialMemo)和背后那一份文件(EditorialDisk)。
// 跟 EditorialNotes.swift 分开放:那边的契约是简介本身只在换歌 / 消费方来要时取、不轮询,这里的延时只管攒一批再写盘。

/// 一种结论的表:内存里一份,背后落盘(`EditorialDisk`)。下标语义同 `[K: V?]`:外层 nil = 没记(或已过期);`.some(nil)` =
/// 明确没有。`missing` 判值在、里面要的正文却没有,这种按「明确没有」的期限记。落盘的键带界面语言:卡片里的标签、繁简
/// 转换、请求的语言都跟界面语言走。
@MainActor
final class EditorialMemo<K: Hashable & CustomStringConvertible, V: Codable> {
    private let namespace: String
    private let missing: (V) -> Bool
    private var memory: [K: V?] = [:]

    init(_ namespace: String, missing: @escaping (V) -> Bool = { _ in false }) {
        self.namespace = namespace
        self.missing = missing
    }

    subscript(key: K) -> V?? {
        get {
            if let known = memory[key] { return known }
            guard let stored = EditorialDisk.cache.lookup(diskKey(key), as: V.self) else { return nil }
            memory[key] = stored
            return stored
        }
        set {
            memory[key] = newValue
            guard let newValue else { return }
            EditorialDisk.cache.store(diskKey(key), newValue, missing: newValue.map(missing) ?? false)
            EditorialDisk.scheduleSave()
        }
    }

    /// 记着的值;没记、明确没有都是 nil。给值本身不会是「没有」的表用。
    func value(_ key: K) -> V? { self[key] ?? nil }

    private func diskKey(_ key: K) -> String { "\(L10n.current)|\(namespace)|\(key)" }
}

/// 简介结论落盘的那一份(`lyrimuse-editorial-cache.json`,`EditorialNotesDiskCache`):第一次用到时在后台读盘、读完并进来
/// (读盘期间刚取到的留着);改了之后隔几秒写一次:主线程只取快照,整份编码和写盘都在写盘队列上按先后排队。
/// 盘上那份还没并进来时不写(写了就把旧文件整个盖掉);写盘失败重标脏、隔几秒再试一次。
@MainActor
enum EditorialDisk {
    static let cache = EditorialNotesDiskCache()
    private static let url = EditorialNotesDiskCache.defaultURL
    private static let writeQueue = DispatchQueue(label: "me.yudaotor.lyrimuse.editorial-cache", qos: .utility)
    private static let saveDelay: UInt64 = 5_000_000_000
    private static var loaded = false
    private static var merged = false
    private static var saveScheduled = false
    /// 上一次写盘失败后已经自动重试过一次:再失败就等下一次有改动时再写,不在坏盘上每 5 秒整份编码一遍。
    private static var retriedAfterFailure = false

    static func load() {
        guard !loaded else { return }
        loaded = true
        let url = url
        Task.detached(priority: .utility) {
            let contents = EditorialNotesDiskCache.read(url)
            await MainActor.run {
                EditorialDisk.cache.merge(contents)
                EditorialDisk.merged = true
            }
        }
    }

    static func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: saveDelay)
            saveScheduled = false
            guard merged else {
                load()
                scheduleSave()
                return
            }
            guard let snapshot = cache.takeSnapshot() else { return }
            let url = url
            writeQueue.async {
                let ok = snapshot.encoded().map { EditorialNotesDiskCache.write($0, to: url) } ?? false
                Task { @MainActor in EditorialDisk.saveFinished(ok) }
            }
        }
    }

    private static func saveFinished(_ ok: Bool) {
        guard !ok else {
            retriedAfterFailure = false
            return
        }
        cache.markDirty()
        guard !retriedAfterFailure else { return }
        retriedAfterFailure = true
        scheduleSave()
    }
}
