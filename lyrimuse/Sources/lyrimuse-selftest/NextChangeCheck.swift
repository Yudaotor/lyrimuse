import AppKit
import Foundation
import LyrimuseCore

/// 沿时间轴每 `step` 毫秒取一次 `tickQuery` 和各展示面 `surfaceTick` 的结果,核对 `LyricsSyncEngine.nextChangeMs`
/// 只会早不会晚:它报的时刻晚于这一点;从这一点往后第一个结果变了的取样点不早于它报的时刻;报 nil 时往后再也不变。
/// 返回不符的取样点说明,最多 `limit` 条。
func nextChangeViolations(_ engine: LyricsSyncEngine, from start: Int, through end: Int, step: Int,
                          trackEndMs: Int? = nil, limit: Int = 5) -> [String] {
    struct Snap: Equatable {
        var index: Int?
        var scrollIndex: Int?
        var overlapping: [Int]
        var line: SyncedLyricLine?
        var compactLine: SyncedLyricLine?
        var compactPlaceholder: Bool
        var compactDwellMs: Int?
        var compactLeadInMs: Int?
        var nextText: String?
        var nextSide: LyricDuet.Side?
        var nextRomanization: String?
        var nextTranslation: String?
        var nextWordGroups: [SyncedLyricWordGroup]?
        var gapIndex: Int?
        var rawGap: LyricsGapWindow?
        var surfaces: [LyricsSyncEngine.SurfaceLyrics]
    }
    func snap(_ t: Int) -> Snap {
        let r = engine.tickQuery(atMs: t, trackEndMs: trackEndMs)
        return Snap(index: r.index, scrollIndex: r.scrollIndex, overlapping: r.overlappingIndices, line: r.line,
                    compactLine: r.compactLine, compactPlaceholder: r.compactPlaceholder,
                    compactDwellMs: r.compactDwellMs, compactLeadInMs: r.compactLeadInMs, nextText: r.nextText,
                    nextSide: r.nextSide, nextRomanization: r.nextRomanization, nextTranslation: r.nextTranslation,
                    nextWordGroups: r.nextWordGroups, gapIndex: r.gapIndex, rawGap: r.rawGapWindow,
                    surfaces: LineBreakSurface.allCases.map { engine.surfaceTick($0, atMs: t, trackEndMs: trackEndMs) })
    }
    var times: [Int] = [], snaps: [Snap] = [], reported: [Int?] = []
    for t in stride(from: start, through: end, by: step) {
        times.append(t)
        snaps.append(snap(t))
        reported.append(engine.nextChangeMs(afterRaw: t))
    }
    var out: [String] = []
    var firstChange: Int?
    for i in stride(from: times.count - 1, through: 0, by: -1) {
        if i + 1 < times.count, snaps[i + 1] != snaps[i] { firstChange = times[i + 1] }
        let t = times[i]
        switch (reported[i], firstChange) {
        case (let n?, _) where n <= t: out.append("@\(t) 报 \(n),不晚于此刻")
        case (let n?, let c?) where c < n: out.append("@\(t) 报 \(n),但 \(c) 已经变了")
        case (nil, let c?): out.append("@\(t) 报不会再变,但 \(c) 变了")
        default: break
        }
    }
    return Array(out.reversed().prefix(limit))
}

/// 全库核对 `nextChangeMs`:本机歌词库里每一首(`LYRIMUSE_NEXTCHANGE_STRIDE=<n>` 时隔 n 首取一首;
/// `LYRIMUSE_NEXTCHANGE_SHARD=<k>/<m>` 时只跑取到的第 k、k+m、k+2m… 首,k 从 0 起,几个进程分着跑),断句开着、
/// 三个展示面按真实字体和宽度设预算,每 20ms 取一次结果核对(判据见 `nextChangeViolations`)。只在给了
/// `LYRIMUSE_NEXTCHANGE_LIBRARY=<歌词正文目录>` 时跑(sync-engine 组里调用),返回不符的首数。
func nextChangeLibraryFailures(bodiesDir: String) -> Int {
    setvbuf(stdout, nil, _IOLBF, 0)
    let env = ProcessInfo.processInfo.environment
    let every = max(1, Int(env["LYRIMUSE_NEXTCHANGE_STRIDE"] ?? "") ?? 1)
    let shard = (env["LYRIMUSE_NEXTCHANGE_SHARD"] ?? "").split(separator: "/").compactMap { Int($0) }
    let (part, parts) = shard.count == 2 && shard[1] > 0 && (0 ..< shard[1]).contains(shard[0])
        ? (shard[0], shard[1]) : (0, 1)
    func width(_ s: String, _ f: NSFont) -> CGFloat {
        s.isEmpty ? 0 : ceil((s as NSString).size(withAttributes: [.font: f]).width * 2) / 2
    }
    func row(_ w: CGFloat, _ f: NSFont) -> LineLayoutBudget.Row { .init(maxWidth: w, measure: { width($0, f) }) }
    let ro = NSFont.systemFont(ofSize: 34 * 0.65, weight: .medium)
    let budgets: [(LineBreakSurface, LineLayoutBudget)] = [
        (.overlay, LineLayoutBudget(
            key: "o", main: row(606, .systemFont(ofSize: 34, weight: .bold)),
            preview: row(606, .systemFont(ofSize: 34 * 0.7, weight: .medium)),
            translation: row(606, .systemFont(ofSize: 34 * 0.7, weight: .regular)),
            romanization: row(606, ro),
            wordRomanization: .init(measure: { width($0, ro) }, sidePadding: 6.4))),
        (.notch, LineLayoutBudget(
            key: "n", main: row(279, .systemFont(ofSize: 13, weight: .semibold)),
            preview: row(279, .systemFont(ofSize: 11, weight: .medium)))),
        (.menuBar, LineLayoutBudget(
            key: "m", main: row(160, .menuBarFont(ofSize: 10)), preview: row(160, .menuBarFont(ofSize: 9)))),
    ]
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: bodiesDir).filter({ $0.hasSuffix(".json") }).sorted() else {
        print("next change library: 读不到 \(bodiesDir)")
        return 1
    }
    var songs = 0, failures = 0
    for (n, name) in names.enumerated() where n % every == 0 && (n / every) % parts == part {
        guard let data = fm.contents(atPath: (bodiesDir as NSString).appendingPathComponent(name)),
              let body = try? JSONDecoder().decode(EnrichCacheBody.self, from: data) else { continue }
        let lyrics = body.lyrics ?? "", yrc = body.lyricsYRC ?? ""
        guard !lyrics.isEmpty || !yrc.isEmpty else { continue }
        songs += 1
        LyricTypesetting.setJapaneseSong(Romanizer.looksJapaneseSong(lyrics.isEmpty ? yrc : lyrics))
        let engine = LyricsSyncEngine()
        engine.load(lyrics: lyrics, lyricsTr: body.lyricsTr ?? "", lyricsRoma: body.lyricsRoma ?? "",
                    lyricsYRC: yrc, lyricsBG: body.lyricsBG ?? "", lineBreaks: .all)
        for (surface, budget) in budgets { engine.setLayoutBudget(budget, for: surface) }
        let endMs = (engine.allLines(idPrefix: "n").last?.timeMs ?? 0) + 8000
        let bad = nextChangeViolations(engine, from: -2000, through: endMs, step: 20, trackEndMs: endMs, limit: 3)
        if !bad.isEmpty {
            failures += 1
            if failures <= 20 { print("next change library: \(name) \(bad.joined(separator: "; "))") }
        }
        if songs % 200 == 0 { print("next change library: 已跑 \(songs) 首,不符 \(failures) 首") }
    }
    print("next change library: 共 \(songs) 首,不符 \(failures) 首")
    return failures
}
