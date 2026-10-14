import Foundation

/// 网页歌词 OBS 那条推给网页的 JSON(19 章)。三种消息:`style`(悬浮歌词的字体颜色)、`track`(整首歌词,
/// 换歌或歌词变了才发)、`pos`(播放位置,锚点变了才发,外加定时心跳)。网页自己按 `pos` 往前推算。
public enum WebLyricsObsPayload {
    public struct Style: Equatable, Sendable {
        public var fontFamily: String
        public var fontSize: Double
        public var weight: Int
        public var sung: String
        public var unsung: String
        public var stroke: String?
        public var card: String?
        public var showRomanization: Bool
        public var showTranslation: Bool

        public init(fontFamily: String, fontSize: Double, weight: Int, sung: String, unsung: String,
                    stroke: String?, card: String?, showRomanization: Bool, showTranslation: Bool) {
            self.fontFamily = fontFamily
            self.fontSize = fontSize
            self.weight = weight
            self.sung = sung
            self.unsung = unsung
            self.stroke = stroke
            self.card = card
            self.showRomanization = showRomanization
            self.showTranslation = showTranslation
        }
    }

    public enum State: String, Sendable {
        case playing, paused, idle, hold
    }

    public static func style(_ s: Style) -> String {
        var o: [String: Any] = [
            "type": "style", "font": s.fontFamily, "size": s.fontSize, "weight": s.weight,
            "sung": s.sung, "unsung": s.unsung, "roma": s.showRomanization, "tr": s.showTranslation,
        ]
        if let stroke = s.stroke { o["stroke"] = stroke }
        if let card = s.card { o["card"] = card }
        return json(o)
    }

    /// 每行:`t` 起点、`text` 整行文字、`w` 逐字 `[起点, 时长, 字]`(没有逐字时间时省略)、`roma` / `tr`。
    /// `gaps` 是间奏的 `[起点, 终点]`,网页在间奏里不显示歌词。时间都在歌词时间轴上(未叠偏移)。
    public static func track(id: String, lines: [LyricsWindowLine], gaps: [LyricsGapMarker]) -> String {
        let encodedLines: [[String: Any]] = lines.map { entry in
            let line = entry.line
            let text = line.plainText ?? line.mainText ?? line.words?.map(\.text).joined() ?? ""
            var o: [String: Any] = ["t": entry.timeMs, "text": text]
            if let words = line.words, !words.isEmpty {
                o["w"] = words.map { [$0.startMs, $0.durationMs, $0.text] as [Any] }
            }
            if let roma = line.romanization, !roma.isEmpty { o["roma"] = roma }
            if let tr = line.translation, !tr.isEmpty { o["tr"] = tr }
            return o
        }
        return json(["type": "track", "id": id, "lines": encodedLines,
                     "gaps": gaps.map { [$0.startMs, $0.endMs] }])
    }

    public static func position(timelineMs: Int, rate: Double, state: State) -> String {
        json(["type": "pos", "pos": timelineMs, "rate": rate, "state": state.rawValue])
    }

    /// OBS 用的时间轴:扣掉「全部播放器」那档偏移。那一档是蓝牙耳机这类设备侧的固定延迟,OBS 录的是进耳机之前的
    /// 声音,扣了才对得上;这个播放器单独配过偏移时,那一档是播放器自己的偏差,照常算。单曲、电台两层不动。
    public static func obsTimelineMs(timelineMs: Int, bundleID: String?, playerOffsets: [String: Int], globalOffsetMs: Int) -> Int {
        if let bundleID, !bundleID.isEmpty, playerOffsets[bundleID] != nil { return timelineMs }
        return timelineMs - globalOffsetMs
    }

    /// CSS 颜色(sRGB 0...1 分量)。
    public static func cssColor(red: Double, green: Double, blue: Double, alpha: Double) -> String {
        func c(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        let a = (min(1, max(0, alpha)) * 1000).rounded() / 1000
        return "rgba(\(c(red)),\(c(green)),\(c(blue)),\(a))"
    }

    /// 悬浮歌词字重档位 → CSS `font-weight`。
    public static func cssWeight(_ weight: OverlayFontWeight) -> Int {
        switch weight {
        case .light: return 300
        case .regular: return 400
        case .medium: return 500
        case .semibold: return 600
        case .bold: return 700
        case .heavy: return 800
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
