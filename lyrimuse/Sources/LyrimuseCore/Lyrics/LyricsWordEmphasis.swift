import Foundation

/// 拖长的词的强调效果(放大 + 辉光 + 额外上浮),参数照 Apple Music「正在播放」界面实测,
/// 见 07 章决策 61。只作用于拉丁字母这类词:中日韩文字的长音不做(Apple 也不做)。
///
/// 一个「词」是连续没有空白隔开的逐字 token 拼起来的(英文按音节拆成几个 token 时要合回一个词);
/// 中日韩文字每个 token 自成一个词,反正也不会触发。
///
/// 三样效果有两种画法:`frame(for:atMs:)` 整词一起动;`glyphFrame(for:glyph:of:atMs:)` 逐字形错开,
/// 一个字形接一个字形浮起来(Apple 的画法,见 07 章决策 81)。
public enum LyricsWordEmphasis {
    /// 触发门槛:这个词从开唱到唱完不短于这么多毫秒。
    public static let minDurationMs = 1000
    /// 词的字母数范围。太长的词整体放大会很突兀。
    public static let letterRange = 2...7

    /// 一个会被强调的词:从第一个 token 开唱到最后一个 token 唱完。
    public struct Span: Equatable, Sendable {
        public let startMs: Int
        public let endMs: Int

        public init(startMs: Int, endMs: Int) {
            self.startMs = startMs
            self.endMs = endMs
        }

        public var durationMs: Int { max(1, endMs - startMs) }
    }

    /// 某一刻的强调量。`scale` 是整词缩放倍数(1 = 不放大);`glow` 是辉光不透明度 0…1;
    /// `extraLift` 是在普通上浮之外再抬起的比例(0…1,乘上普通上浮的幅度)。
    public struct Frame: Equatable, Sendable {
        public let scale: Double
        public let glow: Double
        public let extraLift: Double

        public static let none = Frame(scale: 1, glow: 0, extraLift: 0)
    }

    /// 给一行的逐字 token 逐个标出所属的强调词(不强调的是 nil),下标与 `words` 一一对应。
    public static func spans(for words: [SyncedLyricWord]) -> [Span?] {
        var out = [Span?](repeating: nil, count: words.count)
        var chunk: [Int] = []
        func flush() {
            defer { chunk.removeAll() }
            guard let first = chunk.first, let last = chunk.last else { return }
            let text = chunk.map { words[$0].text }.joined()
            let span = Span(startMs: words[first].startMs,
                            endMs: words[last].startMs + max(1, words[last].durationMs))
            guard isEligible(text: text, durationMs: span.endMs - span.startMs) else { return }
            for i in chunk { out[i] = span }
        }
        for (i, w) in words.enumerated() {
            if containsCJK(w.text) {
                flush()
                continue
            }
            chunk.append(i)
            if let lastChar = w.text.last, lastChar.isWhitespace { flush() }
        }
        flush()
        return out
    }

    /// 一个词拆成几个 token 时,每个 token 放大要围绕的点(token 自己的单位横坐标,0 = 左缘、1 = 右缘,
    /// 可以落在自身之外)。全都围绕整词的中心,各自放大后首尾仍然相接,拼起来就是整词放大。
    /// 宽度为 0 的 token 给 0.5。
    public static func scaleAnchorXs(widths: [Double]) -> [Double] {
        let center = widths.reduce(0, +) / 2
        var x = 0.0
        return widths.map { w in
            defer { x += w }
            return w > 0 ? (center - x) / w : 0.5
        }
    }

    /// 一个被强调的 token 在它那个词里的字形位置:从整词第 `offset` 个字形开始,整词一共 `count` 个。
    public struct GlyphSlot: Equatable, Sendable {
        public let offset: Int
        public let count: Int

        public init(offset: Int, count: Int) {
            self.offset = offset
            self.count = count
        }
    }

    /// 跟 `spans` 一一对应:被强调的 token 给出它在整词里的字形位置,其余是 nil。
    /// 相邻且区间相同的 token 算同一个词(`spans(for:)` 给同一个词的每个 token 同一个区间)。
    public static func glyphSlots(for words: [SyncedLyricWord], spans: [Span?]) -> [GlyphSlot?] {
        var out = [GlyphSlot?](repeating: nil, count: words.count)
        var i = 0
        while i < words.count {
            guard i < spans.count, let span = spans[i] else { i += 1; continue }
            var end = i + 1
            while end < words.count, end < spans.count, spans[end] == span { end += 1 }
            let counts = (i..<end).map { glyphCount(words[$0].text) }
            let total = counts.reduce(0, +)
            var offset = 0
            for (k, n) in counts.enumerated() {
                out[i + k] = GlyphSlot(offset: offset, count: total)
                offset += n
            }
            i = end
        }
        return out
    }

    /// 字形数:不是空白的字符都算,标点也算(句尾的问号跟字母一样排队浮起来)。
    public static func glyphCount(_ text: String) -> Int {
        text.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 }
    }

    /// 逐字形错开时,第 `index` 个字形(整词共 `count` 个)的效果窗口(毫秒,跟逐字填色同一个时间基准)。
    ///
    /// 第 i 个字形比整词晚 i 步起动,每个字形的窗口一样长,最后一个字形正好在词尾收完 —— 跟整词那版
    /// 一样不能拖到词后(见 `frame(for:atMs:)`)。一步 = 词长 × min(12.5%, 50% ÷ (字形数 − 1)):
    /// 1.5 秒左右、四五个字形的词一步约 190ms;字形多时整排错开封顶半个词长,给最后一个字形留够时间。
    public static func glyphWindow(for span: Span, glyph index: Int, of count: Int) -> (startMs: Double, lengthMs: Double) {
        let duration = Double(span.durationMs)
        let steps = Double(max(0, count - 1))
        let step = steps > 0 ? duration * min(0.125, 0.5 / steps) : 0
        let position = Double(min(max(0, index), max(0, count - 1)))
        return (Double(span.startMs) + position * step, duration - step * steps)
    }

    /// 逐字形的强调量:三条曲线跟 `frame(for:atMs:)` 同一套,进度按这个字形自己的窗口算,
    /// 放大的峰值仍按整词时长定。窗口之外没有效果。
    public static func glyphFrame(for span: Span, glyph index: Int, of count: Int, atMs ms: Int) -> Frame {
        let window = glyphWindow(for: span, glyph: index, of: count)
        let t = Double(ms) - window.startMs
        guard t > 0, t < window.lengthMs else { return .none }
        return curves(progress: t / window.lengthMs, durationMs: span.durationMs)
    }

    /// 这个词够不够格:时长够长、没有中日韩文字、字母数在 `letterRange` 内。
    public static func isEligible(text: String, durationMs: Int) -> Bool {
        guard durationMs >= minDurationMs, !containsCJK(text) else { return false }
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return letterRange.contains(letters)
    }

    /// 某一刻的强调量(毫秒,跟逐字填色同一个时间基准)。三样都在词唱完的那一刻回到零:
    /// 句尾的词唱完就换行,这一行随即按非当前行渲染,留到词后面的效果会被硬切掉。
    ///
    /// * 放大:前 55% 升到峰值,70% 之后回落;峰值随时长变大(1.75 秒约 +4%、4 秒约 +6.5%,封顶 7%)。
    /// * 辉光:越唱越亮,80% 处最亮,最后 15% 淡掉。
    /// * 额外上浮:`sin(π·进度)`,词的一半处最高,唱完回到普通上浮的高度。
    public static func frame(for span: Span, atMs ms: Int) -> Frame {
        guard ms > span.startMs, ms < span.endMs else { return .none }
        return curves(progress: Double(ms - span.startMs) / Double(span.durationMs), durationMs: span.durationMs)
    }

    /// 三条曲线本身:`x` 是 0…1 的进度,放大的峰值按整词时长(毫秒)定。
    private static func curves(progress x: Double, durationMs: Int) -> Frame {
        let peak = min(0.07, 0.02 + 0.011 * Double(durationMs) / 1000)
        return Frame(
            scale: 1 + peak * smoothstep(0, 0.55, x) * (1 - smoothstep(0.7, 1, x)),
            glow: 0.55 * smoothstep(0.05, 0.8, x) * (1 - smoothstep(0.85, 1, x)),
            extraLift: sin(.pi * x))
    }

    static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { u in
            switch u.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F, 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ v: Double) -> Double {
        let k = min(1, max(0, (v - a) / (b - a)))
        return k * k * (3 - 2 * k)
    }
}
