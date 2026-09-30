import AppKit
import Foundation
import LyrimuseCore

/// 按宽度重新断句的全库回放:本机歌词库里每一首,按几种真实的宽度和字体断完,逐段量主行、译文、罗马音、
/// 下一句,放不下的计一条。只在给了 `LYRIMUSE_RESEGMENT_LIBRARY=<歌词正文目录>` 时跑(sync-engine 组里调用)。
///
/// 量法跟 App 那边判「装不装得下」的一致:主行按词相加与整串量取较大者,逐词读音按组量。
/// `LYRIMUSE_RESEGMENT_ONLY=<文件>` 只跑文件里列的那几首(一行一个文件名);`LYRIMUSE_RESEGMENT_FAILLOG=<文件>`
/// 把有放不下的那几首的文件名写进去。
func resegmentLibraryFailures(bodiesDir: String) -> Int {
    setvbuf(stdout, nil, _IOLBF, 0)
    let env = ProcessInfo.processInfo.environment
    let only = env["LYRIMUSE_RESEGMENT_ONLY"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        .map { Set($0.split(separator: "\n").map(String.init)) }
    var failedNames = Set<String>()
    struct Config {
        let name: String
        let surface: LyricsSurface
        let main: NSFont
        let mainWidth: CGFloat
        let sidedInset: CGFloat
        let preview: (font: NSFont, width: CGFloat)?
        let translation: (font: NSFont, width: CGFloat)?
        let romanization: (font: NSFont, width: CGFloat)?
        let wordRomanizationPadding: CGFloat?
    }
    // 排字语言跟 App 同一口径(`LyricTypesetting`):日文歌标 `ja` 后宽度会变。
    func width(_ s: String, _ f: NSFont, translation: Bool = false) -> CGFloat {
        s.isEmpty ? 0 : ceil((s as NSString).size(
            withAttributes: LyricTypesetting.attributes([.font: f], for: s, translation: translation)).width * 2) / 2
    }
    func row(_ w: CGFloat, _ f: NSFont, translation: Bool = false) -> LineLayoutBudget.Row {
        .init(maxWidth: w, measure: { width($0, f, translation: translation) })
    }

    // 悬浮歌词:34pt 粗体、描边开、译文 / 罗马音 / 下一句都显示;窗宽 652 与 480。
    func overlay(_ window: CGFloat) -> Config {
        let w = window - 40 - 2.4 * 2 - 1
        return Config(name: "overlay-\(Int(window))", surface: .overlay,
                      main: .systemFont(ofSize: 34, weight: .bold), mainWidth: w, sidedInset: 22,
                      preview: (.systemFont(ofSize: 34 * 0.7, weight: .medium), w),
                      translation: (.systemFont(ofSize: 34 * 0.7, weight: .regular), w),
                      romanization: (.systemFont(ofSize: 34 * 0.65, weight: .medium), w),
                      wordRomanizationPadding: 4 + 2.4)
    }
    // 灵动岛:13pt semibold,副行 11pt 显示下一句;歌词列宽 200 与 280。
    func notch(_ column: CGFloat) -> Config {
        Config(name: "notch-\(Int(column))", surface: .notch,
               main: .systemFont(ofSize: 13, weight: .semibold), mainWidth: column - 1, sidedInset: 0,
               preview: (.systemFont(ofSize: 11, weight: .medium), column - 1),
               translation: nil, romanization: nil, wordRomanizationPadding: nil)
    }
    // 菜单栏双排:主行 10pt、副行 9pt 显示下一句;最大宽度 160 与 300。
    func menuBar(_ w: CGFloat) -> Config {
        Config(name: "menubar-\(Int(w))", surface: .menuBar,
               main: .menuBarFont(ofSize: 10), mainWidth: w, sidedInset: 0,
               preview: (.menuBarFont(ofSize: 9), w),
               translation: nil, romanization: nil, wordRomanizationPadding: nil)
    }
    let configs = [overlay(652), overlay(480), notch(200), notch(280), menuBar(160), menuBar(300)]

    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: bodiesDir) else {
        print("resegment library: 读不到 \(bodiesDir)")
        return 1
    }
    var songs = 0, failures = 0, samples: [String] = []
    var segmentCounts = [String: Int](), lineCounts = [String: Int]()
    var segmentSeconds = 0.0, slowest = (0.0, "")
    for name in names.sorted() where name.hasSuffix(".json") && (only?.contains(name) ?? true) {
        guard let data = fm.contents(atPath: (bodiesDir as NSString).appendingPathComponent(name)),
              let body = try? JSONDecoder().decode(EnrichCacheBody.self, from: data) else { continue }
        let lyrics = body.lyrics ?? "", yrc = body.lyricsYRC ?? ""
        guard !lyrics.isEmpty || !yrc.isEmpty else { continue }
        songs += 1
        LyricTypesetting.setJapaneseSong(Romanizer.looksJapaneseSong(lyrics.isEmpty ? yrc : lyrics))
        if songs % 1000 == 0 { print("resegment library: 已跑 \(songs) 首,放不下 \(failures) 段") }
        for c in configs {
            let engine = LyricsSyncEngine()
            engine.load(lyrics: lyrics, lyricsTr: body.lyricsTr ?? "", lyricsRoma: body.lyricsRoma ?? "",
                        lyricsYRC: yrc, lyricsBG: body.lyricsBG ?? "", lineBreaks: .all)
            engine.setLayoutBudget(LineLayoutBudget(
                key: c.name, main: row(c.mainWidth, c.main), sidedInset: c.sidedInset,
                preview: c.preview.map { row($0.width, $0.font) },
                translation: c.translation.map { row($0.width, $0.font, translation: true) },
                romanization: c.romanization.map { row($0.width, $0.font) },
                wordRomanization: c.wordRomanizationPadding.map { pad in
                    .init(measure: { width($0, c.romanization!.font) }, sidePadding: pad)
                }), for: c.surface)
            // 按播放顺序每秒走一拍:断句是边播边往后断的,一拍最多花多久才是主线程上的代价。
            let endMs = (engine.allLines(idPrefix: "t").last?.timeMs ?? 0) + 5000
            for ms in stride(from: 0, through: endMs, by: 1000) {
                let t0 = CFAbsoluteTimeGetCurrent()
                _ = engine.surfaceTick(c.surface, atMs: ms)
                let dt = CFAbsoluteTimeGetCurrent() - t0
                segmentSeconds += dt
                if dt > slowest.0 { slowest = (dt, "\(c.name) \(name) @\(ms)") }
                if dt > 0.03, env["LYRIMUSE_RESEGMENT_SLOWLOG"] != nil {
                    print(String(format: "  慢拍 %.1f ms %@ %@ @%d", dt * 1000, c.name, name, ms))
                }
            }
            let lines = engine.surfaceLines(c.surface)
            segmentCounts[c.name, default: 0] += lines.count
            lineCounts[c.name, default: 0] += engine.allLines(idPrefix: "x").count
            for line in lines {
                let sided = line.side == .leading || line.side == .trailing
                let inset = sided ? c.sidedInset : 0
                let text = line.plainText ?? ""
                var mainW = width(text, c.main)
                if let words = line.words {
                    var sum = words.reduce(CGFloat(0)) { $0 + width($1.text, c.main) }
                    if let groups = line.wordGroups, let pad = c.wordRomanizationPadding, let ro = c.romanization {
                        sum = groups.reduce(CGFloat(0)) { acc, g in
                            let ww = g.words.reduce(CGFloat(0)) { $0 + width($1.text, c.main) }
                            return acc + max(ww, width(g.romanization ?? " ", ro.font) + pad * 2)
                        }
                    }
                    mainW = max(mainW, sum)
                }
                var bad: [String] = []
                if mainW > c.mainWidth - inset + 0.5 { bad.append("主行 \(Int(mainW))") }
                if let p = c.preview, width(text, p.font) > p.width - inset + 0.5 { bad.append("下一句") }
                if let t = c.translation, let tr = line.translation, width(tr, t.font, translation: true) > t.width - inset + 0.5 {
                    bad.append("译文「\(tr)」")
                }
                if let r = c.romanization, line.wordGroups == nil || c.wordRomanizationPadding == nil,
                   let ro = line.romanization, width(ro, r.font) > r.width - inset + 0.5 {
                    bad.append("罗马音「\(ro)」")
                }
                if !bad.isEmpty {
                    failures += 1
                    failedNames.insert(name)
                    if samples.count < 20 {
                        let shape = "词\(line.words?.count ?? -1) 组\(line.wordGroups?.count ?? -1) 组内词\(line.wordGroups?.reduce(0) { $0 + $1.words.count } ?? -1)"
                        samples.append("\(c.name) \(name) 「\(text)」 \(bad.joined(separator: " ")) [\(shape)]")
                    }
                }
            }
        }
    }
    print("resegment library: \(songs) 首 · 放不下 \(failures) 段")
    print(String(format: "  边播边断:平均每首每面合计 %.2f ms,最慢的一拍 %.1f ms(%@)",
                 segmentSeconds / Double(max(1, songs * configs.count)) * 1000, slowest.0 * 1000, slowest.1))
    for c in configs {
        print("  \(c.name): \(lineCounts[c.name] ?? 0) 行 → \(segmentCounts[c.name] ?? 0) 段")
    }
    for s in samples { print("  ✗ \(s)") }
    if let log = env["LYRIMUSE_RESEGMENT_FAILLOG"] {
        try? failedNames.sorted().joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8)
    }
    return failures
}
