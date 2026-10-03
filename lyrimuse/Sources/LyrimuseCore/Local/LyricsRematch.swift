import Foundation

/// 「重新自动匹配」的 App ↔ collector 通道(见 collector/lyricsrematch.go 头注)。
///
/// App 只发请求、等结论:冠军怎么选、换不换、写哪些字段全在 collector 那边,跑的就是后台重评 / 补空那两个函数,
/// 只是几处按手动放宽(人工修正过的照跑、用户选定的源不管、校准过时间轴的照跑)。
///   - 请求 `lyrimuse-lyrics-rematch-request.json`:`{"id","key"}` 开一轮,`{"id","cancel":true}` 停掉那一轮。
///   - 状态 `lyrimuse-lyrics-rematch-status.json`:带着请求的 id;跑着时 `done` / `total` 是几个歌词源回了话,
///     跑完 `result` 是结论。
public enum LyricsRematch {
    /// collector 写的状态,字段跟 lyricsRematchStatus 一一对应。
    public struct Status: Decodable, Equatable, Sendable {
        public let id: String
        public let key: String
        public let running: Bool
        /// 几个歌词源回了话 / 一共几个;还没有源回话时不出现。
        public let done: Int?
        public let total: Int?
        public let startedAt: Int64
        public let updatedAt: Int64
        public let finishedAt: Int64?
        public let result: Conclusion?

        public init(id: String, key: String, running: Bool, done: Int? = nil, total: Int? = nil,
                    startedAt: Int64, updatedAt: Int64, finishedAt: Int64? = nil, result: Conclusion? = nil) {
            self.id = id
            self.key = key
            self.running = running
            self.done = done
            self.total = total
            self.startedAt = startedAt
            self.updatedAt = updatedAt
            self.finishedAt = finishedAt
            self.result = result
        }
    }

    /// 一轮的结论,字段跟 lyricsRematchResult 一一对应。
    public struct Conclusion: Decodable, Equatable, Sendable {
        /// 见 `Outcome`。
        public let outcome: String
        /// changed / unchanged 时是此刻的歌词源与分数;kept_word_timing 时是没采用的那个冠军。
        public let winner: String?
        public let winnerScore: Int?
        /// 跑之前的歌词源、有没有词。
        public let previous: String?
        public let hadLyrics: Bool?
        /// changed 时正文、逐字各自换没换。
        public let textChanged: Bool?
        public let timingChanged: Bool?

        public init(outcome: String, winner: String? = nil, winnerScore: Int? = nil, previous: String? = nil,
                    hadLyrics: Bool? = nil, textChanged: Bool? = nil, timingChanged: Bool? = nil) {
            self.outcome = outcome
            self.winner = winner
            self.winnerScore = winnerScore
            self.previous = previous
            self.hadLyrics = hadLyrics
            self.textChanged = textChanged
            self.timingChanged = timingChanged
        }
    }

    /// 结论码,跟 collector 的 lyricsRematch* 常量一一对应。
    public enum Outcome: String, Sendable {
        case changed, unchanged
        case notDecidable = "not_decidable"
        case keptWordTiming = "kept_word_timing"
        case instrumental
        case plainText = "plain_text"
        case noCandidate = "no_candidate"
        case offline, busy, missing, edited, cancelled
    }

    /// 这一句的语气,决定图标和颜色。
    public enum Tone: Equatable, Sendable {
        case changed, unchanged, kept, empty, failed
    }

    /// 详情页那一行说哪一句。句子本身在 App 侧(LyricsManagerView.rematchText),这里只按结论挑。
    public enum Line: Equatable, Sendable {
        /// 原来没有词,补上了。
        case filled(source: String, score: Int)
        /// 换了个来源。
        case switched(source: String, score: Int, previous: String)
        /// 还是同一个来源,正文 / 逐字换了。
        case refreshed(source: String, score: Int, text: Bool, timing: Bool)
        case unchanged(source: String, score: Int)
        /// 当前歌词的来源这一轮没应答。previous 为空 = 这份词没记来源(手改过),要全部歌词源都应答才判得了。
        case notDecidable(previous: String)
        case keptWordTiming(previous: String)
        case instrumental, plainText, noCandidate, offline, busy, missing, edited, failed

        public var tone: Tone {
            switch self {
            case .filled, .switched, .refreshed: return .changed
            case .unchanged: return .unchanged
            case .notDecidable, .keptWordTiming, .edited: return .kept
            case .instrumental, .plainText, .noCandidate, .offline: return .empty
            case .busy, .missing, .failed: return .failed
            }
        }
    }

    /// 纯函数,selftest 覆盖。认不出的结论码(新 collector 加了码、App 还是旧的)按「没拿到结论」说。
    public static func line(for c: Conclusion) -> Line {
        let source = c.winner ?? "", score = c.winnerScore ?? 0, previous = c.previous ?? ""
        switch Outcome(rawValue: c.outcome) {
        case .changed:
            if c.hadLyrics != true { return .filled(source: source, score: score) }
            if source != previous { return .switched(source: source, score: score, previous: previous) }
            return .refreshed(source: source, score: score, text: c.textChanged == true, timing: c.timingChanged == true)
        case .unchanged: return .unchanged(source: source, score: score)
        case .notDecidable: return .notDecidable(previous: previous)
        case .keptWordTiming: return .keptWordTiming(previous: previous)
        case .instrumental: return .instrumental
        case .plainText: return .plainText
        case .noCandidate: return .noCandidate
        case .offline: return .offline
        case .busy: return .busy
        case .missing: return .missing
        case .edited: return .edited
        case .cancelled, nil: return .failed
        }
    }

    // MARK: - 等结论

    /// 等的这一轮走到哪一步。
    public enum Phase: Equatable, Sendable {
        /// 请求写下了,collector 还没接手。
        case waiting
        /// collector 在跑,见 `Status.done` / `total`(还没有源回话时都是 0)。
        case running(done: Int, total: Int)
        case finished(Conclusion)
        /// 等不到了:collector 一直没接手,或跑着跑着没了动静(进程退出 / 重启)。
        case lost
    }

    /// collector 每 0.5 秒看一次请求;过了这么久状态文件里还没有这一轮,就当它没在跑。
    public static let pickupTimeout: TimeInterval = 10
    /// 跑着时每个歌词源回话都会写一次状态;这么久一次都没写,就当这一轮没了。
    public static let stallTimeout: TimeInterval = 90

    /// 纯函数,selftest 覆盖。状态文件里是别的一轮(上一次的收据、被顶掉的那一轮)按还没接手算。
    public static func phase(id: String, status: Status?, requestedAt: Date, now: Date) -> Phase {
        guard let status, status.id == id else {
            return now.timeIntervalSince(requestedAt) < pickupTimeout ? .waiting : .lost
        }
        guard status.running else { return status.result.map(Phase.finished) ?? .lost }
        if now.timeIntervalSince1970 - Double(status.updatedAt) > stallTimeout { return .lost }
        return .running(done: status.done ?? 0, total: status.total ?? 0)
    }

    // MARK: - 文件

    static let requestURL = LyrimusePaths.configFile("lyrimuse-lyrics-rematch-request.json")
    static let statusURL = LyrimusePaths.configFile("lyrimuse-lyrics-rematch-status.json")

    /// 请求文件的内容。纯函数,selftest 覆盖(collector 侧 parseLyricsRematchRequest 是它的读方)。
    public static func requestBody(id: String, key: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["id": id, "key": key], options: [.sortedKeys])) ?? Data()
    }

    public static func cancelBody(id: String) -> Data {
        let body: [String: Any] = ["id": id, "cancel": true]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// 请 collector 对 key 跑一轮。返回写文件是否成功。
    @discardableResult
    public static func request(id: String, key: String) -> Bool {
        (try? requestBody(id: id, key: key).write(to: requestURL, options: .atomic)) != nil
    }

    /// 停掉 id 那一轮(详情页换了一首)。那一轮已经跑完时 collector 什么都不做。
    public static func cancel(id: String) {
        try? cancelBody(id: id).write(to: requestURL, options: .atomic)
    }

    /// 状态文件此刻的内容;不存在 / 解不开都是 nil。只在等结论时读,文件很小,不做缓存。
    public static var current: Status? {
        (try? Data(contentsOf: statusURL)).flatMap { try? JSONDecoder().decode(Status.self, from: $0) }
    }
}
