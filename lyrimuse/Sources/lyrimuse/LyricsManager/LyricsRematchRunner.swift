import LyrimuseCore
import SwiftUI

/// 「重新自动匹配」的发起与结论(见 LyricsRematch):请引擎对一首跑一轮重评、轮询进度、把结论翻成一句话。
/// 歌词管理详情页那颗按钮和搜索候选歌词面板那颗共用这一份,结论的说法只有一套。冠军按设置里的「匹配算法」
/// 由引擎选,换不换、写哪些字段跟后台重评是同一个函数(11 章决策 46)。
@MainActor
enum LyricsRematchRunner {
    /// 发请求、等结论。`isCurrent` 返回 false(调用方已经换代:换了歌、又点了一次)时返回 nil;引擎那一轮不在这里
    /// 叫停,要叫停的调用方拿自己的 `id` 去 `LyricsRematch.cancel`。请求写不出去、引擎丢了这一轮都给 `.failed`。
    static func run(key: String, id: String = UUID().uuidString, isCurrent: () -> Bool = { true },
                    onProgress: (_ sourcesDone: Int, _ sourcesTotal: Int) -> Void) async -> LyricsRematch.Line? {
        guard LyricsRematch.request(id: id, key: key) else { return .failed }
        let requestedAt = Date()
        while true {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard isCurrent() else { return nil }
            switch LyricsRematch.phase(id: id, status: LyricsRematch.current, requestedAt: requestedAt, now: Date()) {
            case .waiting:
                continue
            case let .running(sourcesDone, sourcesTotal):
                onProgress(sourcesDone, sourcesTotal)
            case .lost:
                return .failed
            case let .finished(conclusion):
                return LyricsRematch.line(for: conclusion)
            }
        }
    }

    /// 这一轮有没有改写这首的歌词:换了源、补上、同源换了版本,或者采纳了一份纯文本兜底(它的色调归在「没词」那档)。
    nonisolated static func rewroteLyrics(_ line: LyricsRematch.Line) -> Bool {
        line.tone == .changed || line == .plainText
    }

    nonisolated static func icon(_ tone: LyricsRematch.Tone) -> String {
        switch tone {
        case .changed: return "checkmark.circle.fill"
        case .unchanged: return "equal.circle"
        case .kept: return "hand.raised.fill"
        case .empty: return "text.badge.xmark"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    nonisolated static func tint(_ tone: LyricsRematch.Tone) -> Color {
        switch tone {
        case .changed: return .green
        case .unchanged: return .secondary
        case .kept, .empty, .failed: return .orange
        }
    }

    /// 结论那一句。
    static func text(_ line: LyricsRematch.Line) -> String {
        switch line {
        case let .filled(source, score):
            return String(format: L10n.t("已补上「%1$@」的歌词（%2$@ 分）"), sourceDisplayName(source), "\(score)")
        case let .switched(source, score, previous):
            return String(format: L10n.t("已换成「%1$@」（%2$@ 分），原来是「%3$@」"),
                          sourceDisplayName(source), "\(score)", sourceDisplayName(previous))
        case let .refreshed(source, score, text, timing):
            // 别说"更新的一份":只知道内容不一样,不知道哪份更新 —— 同一个源完全可能这一轮匹配到另一个版本。
            // 三句完整句子而不是拼接:中文的"都"和英文的语序都拼不出来(同 batchDeleteMessage 那条注释)。
            let template: String
            if text && timing {
                template = L10n.t("已重新匹配：还是「%1$@」，但正文和逐字时间轴都跟原来那份不一样，已换成这一轮抓到的（%2$@ 分）")
            } else if timing {
                template = L10n.t("已重新匹配：还是「%1$@」，但逐字时间轴跟原来那份不一样，已换成这一轮抓到的（%2$@ 分）")
            } else {
                template = L10n.t("已重新匹配：还是「%1$@」，但正文跟原来那份不一样，已换成这一轮抓到的（%2$@ 分）")
            }
            return String(format: template, sourceDisplayName(source), "\(score)")
        case let .unchanged(source, score):
            return String(format: L10n.t("已重新匹配：仍然是「%1$@」（%2$@ 分），没有更好的"), sourceDisplayName(source), "\(score)")
        case let .notDecidable(previous):
            if previous.isEmpty {
                return L10n.t("这一轮有歌词源没应答，没有换（避免误降级），可以再点一次")
            }
            return String(format: L10n.t("这一轮「%@」没应答，没有换（避免误降级），可以再点一次"), sourceDisplayName(previous))
        case let .keptWordTiming(previous):
            return String(format: L10n.t("这一轮没搜到逐字歌词，保留现有的「%@」（逐字）——换过去会丢掉逐字时间轴"),
                          sourceDisplayName(previous))
        case .instrumental:
            return L10n.t("有源明确说这首是纯音乐，没有可用的歌词候选")
        case .plainText:
            return L10n.t("没有找到带时间戳的版本，已自动采纳一份纯文本兜底（可在「歌词窗口」里查看）")
        case .noCandidate:
            return L10n.t("这一轮没有一个能用的候选，保留现有的")
        case .offline:
            return L10n.t("网络似乎不通，这一轮没搜到任何候选")
        case .busy:
            return L10n.t("这首正在搜索，或者「补搜歌词」/「全量重新扫库」正在跑，稍后再试一次")
        case .missing:
            return L10n.t("这一首已经不在歌词库里了")
        case .edited:
            return L10n.t("这一首在搜的时候被改过，这一轮的结果没有采用")
        case .failed:
            return L10n.t("这一轮没拿到结论，可以再点一次")
        }
    }
}
