import Foundation
import LyrimuseCore

// 简介结论落盘(lyrimuse-editorial-cache.json,18 章决策 54):期限、过期、坏文件、读盘期间取到的、上限,以及各张结论表都走落盘。
// 由 main.swift 的注册表按组调用。

@MainActor
func runEditorialCacheTests() {
    typealias C = EditorialNotesDiskCache
    let t0 = Date(timeIntervalSince1970: 2_000_000_000)
    let day: TimeInterval = 86_400
    struct Page: Codable, Equatable { let text: String? }

    // ---- 有正文的 30 天、明确没有的 7 天;值在、正文没有的按明确没有算 ----
    do {
        let c = C()
        expectEqual(c.lookup("zh|a|1", as: Page.self, now: t0) == nil, true, "简介落盘: 没记过是 nil")
        c.store("zh|a|1", Page(text: "hi"), now: t0)
        c.store("zh|a|2", Page?.none, now: t0)
        c.store("zh|a|3", Page(text: nil), missing: true, now: t0)
        expectEqual(c.lookup("zh|a|1", as: Page.self, now: t0), .some(Page(text: "hi")), "简介落盘: 取到的值")
        expectEqual(c.lookup("zh|a|2", as: Page.self, now: t0), .some(nil), "简介落盘: 明确没有")
        expectEqual(c.lookup("zh|a|3", as: Page.self, now: t0), .some(Page(text: nil)), "简介落盘: 值在、正文没有的照样读回值")
        let week = t0.addingTimeInterval(7 * day)
        expectEqual(c.lookup("zh|a|1", as: Page.self, now: week), .some(Page(text: "hi")), "简介落盘: 有正文的 7 天还在")
        expectEqual(c.lookup("zh|a|2", as: Page.self, now: week) == nil, true, "简介落盘: 明确没有的 7 天后再问")
        expectEqual(c.lookup("zh|a|3", as: Page.self, now: week) == nil, true, "简介落盘: 正文没有的按明确没有的期限")
        expectEqual(c.lookup("zh|a|1", as: Page.self, now: t0.addingTimeInterval(30 * day)) == nil, true,
                    "简介落盘: 有正文的 30 天后再问")
        expectEqual(c.lookup("zh|a|1", as: [Int].self, now: t0) == nil, true, "简介落盘: 值解不开当没记过")
    }

    // ---- 写盘、读盘:过期的丢掉,坏文件和别的版本当空的 ----
    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyrimuse-editorial-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("lyrimuse-editorial-cache.json")
        expectEqual(C.read(url, now: t0).isEmptyForTest, true, "简介落盘: 文件不在当空的")
        let c = C()
        expectEqual(c.snapshotForSave(now: t0) == nil, true, "简介落盘: 没改过不写")
        c.store("zh|a|old", "x", now: t0.addingTimeInterval(-31 * day))
        c.store("zh|a|new", "y", now: t0)
        c.store("zh|a|none", String?.none, now: t0)
        guard let data = c.snapshotForSave(now: t0) else {
            expectEqual(false, true, "简介落盘: 改过要写")
            return
        }
        expectEqual(c.dirty, false, "简介落盘: 写完不再脏")
        expectEqual(c.count, 2, "简介落盘: 写盘时去掉过期的")
        expectEqual(C.write(data, to: url), true, "简介落盘: 写盘(目录不在要建)")
        let back = C(C.read(url, now: t0))
        expectEqual(back.lookup("zh|a|new", as: String.self, now: t0), .some("y"), "简介落盘: 读回取到的")
        expectEqual(back.lookup("zh|a|none", as: String.self, now: t0), .some(nil), "简介落盘: 读回明确没有")
        expectEqual(C(C.read(url, now: t0.addingTimeInterval(8 * day))).count, 1, "简介落盘: 读盘时去掉过期的")
        try? Data("{not json".utf8).write(to: url)
        expectEqual(C.read(url, now: t0).isEmptyForTest, true, "简介落盘: 解不开当空的")
        try? Data(#"{"version":99,"entries":{"zh|a|new":{"v":"\"y\"","at":2000000000}}}"#.utf8).write(to: url)
        expectEqual(C.read(url, now: t0).isEmptyForTest, true, "简介落盘: 别的版本当空的")
    }

    // ---- 读盘期间刚取到的留着;超过上限丢最早取到的 ----
    do {
        let disk = C()
        disk.store("zh|a|1", "disk", now: t0)
        disk.store("zh|a|2", "disk", now: t0)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lyrimuse-editorial-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cache.json")
        if let data = disk.snapshotForSave(now: t0) { C.write(data, to: url) }
        let live = C()
        live.store("zh|a|1", "fresh", now: t0)
        live.merge(C.read(url, now: t0))
        expectEqual(live.lookup("zh|a|1", as: String.self, now: t0), .some("fresh"), "简介落盘: 读盘期间取到的不被盘上旧的盖掉")
        expectEqual(live.lookup("zh|a|2", as: String.self, now: t0), .some("disk"), "简介落盘: 盘上别的并进来")

        let big = C()
        for i in 0...C.maxEntries {
            big.store("k\(i)", i, now: t0.addingTimeInterval(TimeInterval(i)))
        }
        _ = big.snapshotForSave(now: t0.addingTimeInterval(TimeInterval(C.maxEntries)))
        expectEqual(big.count, C.maxEntries, "简介落盘: 超过上限丢掉多出来的")
        expectEqual(big.lookup("k0", as: Int.self, now: t0) == nil, true, "简介落盘: 丢的是最早取到的")
    }

    // ---- 源码契约:简介的各张结论表都走落盘,键带界面语言 ----
    do {
        let ui = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lyrimuse/UI")
        let store = FileIO.readString(ui.appendingPathComponent("EditorialNotes.swift")) ?? ""
        let disk = FileIO.readString(ui.appendingPathComponent("EditorialNotesDisk.swift")) ?? ""
        for name in ["albumPages", "artistCards", "lastfmCards", "sodaIntros", "youtubeMusicAlbums", "youtubeMusicArtistTexts",
                     "qqSongTexts", "neteaseSongs", "neteaseCards", "neteaseAlbumTexts"] {
            expectEqual(store.contains("private let \(name) = EditorialMemo<"), true, "简介落盘: \(name) 走落盘")
        }
        expectEqual(disk.contains("\"\\(L10n.current)|\\(namespace)|\\(key)\""), true, "简介落盘: 落盘的键带界面语言")
        expectEqual(store.contains("        EditorialDisk.load()\n"), true, "简介落盘: 简介开始用时读盘")
    }
}

private extension EditorialNotesDiskCache.Contents {
    var isEmptyForTest: Bool { EditorialNotesDiskCache(self).count == 0 }
}
