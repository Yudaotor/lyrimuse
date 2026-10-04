import AppKit
import Foundation
import LyrimuseCore

/// 按宽度重新断句的耗时基准:从歌词正文目录里每隔 `stride` 首取一首,按 App 的真实节奏(20Hz、三个面各一次)
/// 从头播到尾,开关开 / 关各跑一遍,报总耗时、每拍耗时和占一个核的比例。只在给了
/// `LYRIMUSE_RESEGMENT_BENCH=<歌词正文目录>` 时跑(sync-engine 组里调用),不做断言。
func resegmentBenchmark(bodiesDir: String, stride step: Int) {
    setvbuf(stdout, nil, _IOLBF, 0)
    func width(_ s: String, _ f: NSFont) -> CGFloat {
        s.isEmpty ? 0 : ceil((s as NSString).size(withAttributes: [.font: f]).width * 2) / 2
    }
    func row(_ w: CGFloat, _ f: NSFont) -> LineLayoutBudget.Row { .init(maxWidth: w, measure: { width($0, f) }) }
    let ro = NSFont.systemFont(ofSize: 34 * 0.65, weight: .medium)
    let budgets: [(LyricsSurface, LineLayoutBudget)] = [
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
        print("resegment bench: 读不到 \(bodiesDir)")
        return
    }
    struct Totals { var songs = 0; var playedMs = 0; var tickSec = 0.0; var ticks = 0; var loadSec = 0.0; var worstTick = 0.0 }
    var on = Totals(), off = Totals()
    var index = 0
    for name in names {
        index += 1
        guard index % step == 0,
              let data = fm.contents(atPath: (bodiesDir as NSString).appendingPathComponent(name)),
              let body = try? JSONDecoder().decode(EnrichCacheBody.self, from: data) else { continue }
        let lyrics = body.lyrics ?? "", yrc = body.lyricsYRC ?? ""
        guard !lyrics.isEmpty || !yrc.isEmpty else { continue }
        for enabled in [true, false] {
            let engine = LyricsSyncEngine()
            let t0 = CFAbsoluteTimeGetCurrent()
            engine.load(lyrics: lyrics, lyricsTr: body.lyricsTr ?? "", lyricsRoma: body.lyricsRoma ?? "",
                        lyricsYRC: yrc, lyricsBG: body.lyricsBG ?? "", lineBreaks: enabled ? .all : .off)
            for (surface, budget) in budgets { engine.setLayoutBudget(budget, for: surface) }
            // 菜单栏起步槽宽:App 加载完就算一次,开着是整首最宽,关着按比例取一行。
            if enabled { _ = engine.widestRow(.menuBar) } else { _ = engine.rowWidth(.menuBar, atQuantile: 0.9) }
            let loadSec = CFAbsoluteTimeGetCurrent() - t0
            let endMs = (engine.allLines(idPrefix: "b").last?.timeMs ?? 0) + 5000
            var tickSec = 0.0, ticks = 0, worst = 0.0
            for ms in Swift.stride(from: 0, through: endMs, by: 50) {
                let t = CFAbsoluteTimeGetCurrent()
                for (surface, _) in budgets { _ = engine.surfaceTick(surface, atMs: ms) }
                let dt = CFAbsoluteTimeGetCurrent() - t
                tickSec += dt
                ticks += 1
                worst = max(worst, dt)
            }
            if enabled {
                on.songs += 1; on.playedMs += endMs; on.tickSec += tickSec; on.ticks += ticks
                on.loadSec += loadSec; on.worstTick = max(on.worstTick, worst)
            } else {
                off.songs += 1; off.playedMs += endMs; off.tickSec += tickSec; off.ticks += ticks
                off.loadSec += loadSec; off.worstTick = max(off.worstTick, worst)
            }
        }
    }
    func report(_ label: String, _ t: Totals) {
        let perSong = t.tickSec / Double(max(1, t.songs)) * 1000
        let perTick = t.tickSec / Double(max(1, t.ticks)) * 1_000_000
        let cpu = t.tickSec / (Double(max(1, t.playedMs)) / 1000) * 100
        print(String(format: "  %@:%d 首 · 加载(含预算)平均 %.2f ms · 播放全程每首合计 %.2f ms · 每拍(三个面)平均 %.1f µs、最慢 %.1f ms · 占一个核 %.4f%%",
                     label, t.songs, t.loadSec / Double(max(1, t.songs)) * 1000, perSong, perTick, t.worstTick * 1000, cpu))
    }
    print("resegment bench(20Hz × 三个面,release):")
    report("开关开", on)
    report("开关关", off)
}
