import LyrimuseCore
import SwiftUI

/// 「重新自动匹配」的发起与结论(见 LyricsRematch):请引擎对一首跑一轮重评、轮询进度、把结论翻成一句话。
/// 歌词管理详情页那颗按钮和搜索候选歌词面板那颗共用这一份,结论的说法只有一套。冠军按设置里的「匹配算法」
/// 由引擎选,换不换、写哪些字段跟后台重评是同一个函数(11 章决策 46)。
@MainActor
enum LyricsRematchRunner {
    /// 发请求、等结论。`isCurrent` 返回 false(调用方已经换代:换了歌、又点了一次)或者所在的任务被取消时返回 nil;
    /// 引擎那一轮不在这里叫停,要叫停的调用方拿自己的 `id` 去 `LyricsRematch.cancel`。请求写不出去、引擎丢了这一轮都给 `.failed`。
    static func run(key: String, id: String = UUID().uuidString, isCurrent: () -> Bool = { true },
                    onProgress: (_ sourcesDone: Int, _ sourcesTotal: Int) -> Void) async -> LyricsRematch.Line? {
        guard LyricsRematch.request(id: id, key: key) else { return .failed }
        let requestedAt = Date()
        while true {
            // 别写成 try?:任务被取消之后 sleep 立刻抛错,吞掉的话这个循环不再让出主线程,一直空转到引擎那一轮结束。
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return nil }
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
            return String(format: L10n.t("已补全「%1$@」的歌词（%2$@ 分）"), sourceDisplayName(source), "\(score)")
        case let .switched(source, score, previous):
            return String(format: L10n.t("已更换为「%1$@」（%2$@ 分），原为「%3$@」"),
                          sourceDisplayName(source), "\(score)", sourceDisplayName(previous))
        case let .refreshed(source, score, text, timing):
            // 别说"更新的一份":只知道内容不一样,不知道哪份更新 —— 同一个源完全可能这一轮匹配到另一个版本。
            // 三句完整句子而不是拼接:中文的"都"和英文的语序都拼不出来(同 batchDeleteMessage 那条注释)。
            let template: String
            if text && timing {
                template = L10n.t("已重新匹配：仍为「%1$@」，但歌词正文和逐字时间轴均有变化，已更新为本轮结果（%2$@ 分）")
            } else if timing {
                template = L10n.t("已重新匹配：仍为「%1$@」，但逐字时间轴有变化，已更新为本轮结果（%2$@ 分）")
            } else {
                template = L10n.t("已重新匹配：仍为「%1$@」，但歌词正文有变化，已更新为本轮结果（%2$@ 分）")
            }
            return String(format: template, sourceDisplayName(source), "\(score)")
        case let .unchanged(source, score):
            return String(format: L10n.t("已重新匹配：仍为「%1$@」（%2$@ 分），未找到更好的结果"), sourceDisplayName(source), "\(score)")
        case let .notDecidable(previous):
            if previous.isEmpty {
                return L10n.t("本轮有歌词源未应答，为避免误降级未作更换，可稍后重试")
            }
            return String(format: L10n.t("本轮「%@」未应答，为避免误降级未作更换，可稍后重试"), sourceDisplayName(previous))
        case let .keptWordTiming(previous):
            return String(format: L10n.t("本轮未找到逐字歌词，保留现有的「%@」（逐字），以免丢失逐字时间轴"),
                          sourceDisplayName(previous))
        case .instrumental:
            return L10n.t("有歌词源将这首歌曲标记为纯音乐，无可用的候选歌词")
        case .plainText:
            return L10n.t("未找到带时间戳的版本，已自动采用纯文本歌词（可在「歌词窗口」中查看）")
        case .noCandidate:
            return L10n.t("本轮无可用候选，保留现有歌词")
        case .offline:
            return L10n.t("网络可能不可用，本轮未找到任何候选")
        case .busy:
            return L10n.t("这首歌曲正在搜索，或「自动匹配缺失歌词」/「重新匹配整个歌词库」正在进行，请稍后重试")
        case .missing:
            return L10n.t("这首歌曲已不在歌词库中")
        case .edited:
            return L10n.t("搜索期间这首歌曲被修改过，本轮结果未采用")
        case .failed:
            return L10n.t("本轮未得到结果，请重试")
        }
    }
}
