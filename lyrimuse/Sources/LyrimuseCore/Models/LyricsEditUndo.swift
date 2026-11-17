import Foundation

/// 歌词改动之后的撤销:引擎在那一笔里留下改之前的完整状态、回一个 undo_id,`undo_edit` 原样放回(lyrimuse-engine/enrichundo.go)。
/// 接了的入口:「搜索歌词…」采纳、歌词管理「保存修改」、外部编辑器存回、「重新自动匹配」、标 / 撤纯音乐(歌词管理详情页)、
/// 多选「全部标为纯音乐」。这里是 App 一侧的常数和失败原因。见 11 章决策 177、178、179。
public enum LyricsEditUndo {
    /// 「撤销」跟着回声停留的秒数。必须比引擎认 undo_id 的时限(enrichUndoTTL,60 秒)短。
    public static let offerSeconds: Double = 8
    /// 引擎认 undo_id 的时限(秒),跟 enrichUndoTTL 对拍。
    public static let engineTTLSeconds: Double = 60

    /// 引擎的错误码(enrichUndoErrExpired / enrichUndoErrChanged)。
    public static let engineErrorCodes = ["undo_expired", "undo_changed"]

    /// 撤销失败时那一句的 L10n 键。引擎没给错误码(没响应、执行失败)时 nil,调用方用通道给的原因或 `fallbackKey`。
    /// `batch`:撤的是多选那一笔(几首一起放回),动过时不说「这首」。
    public static func reasonKey(code: String?, batch: Bool = false) -> String? {
        switch code {
        case "undo_expired": return "无法撤销：已超过撤销时限"
        case "undo_changed": return batch ? batchChangedKey : "无法撤销：这首歌曲的歌词已有其他改动"
        default: return nil
        }
    }

    /// 多选那一笔里有一首之后被动过、整笔被拒时那一句。
    public static let batchChangedKey = "无法撤销：部分歌曲已有其他改动"

    /// 没有错误码、通道也没给本地化原因时那一句。
    public static let fallbackKey = "无法撤销，请重试"
    /// 通道给了本地化原因(如「歌词引擎无响应」)时套的格式。
    public static let reasonFormatKey = "无法撤销：%@"

    /// 撤销失败时说的那一句:L10n 键,或者格式键加已经本地化的原因。
    public enum Failure: Equatable {
        case key(String)
        case format(String, reason: String)
    }

    /// 错误码对得上的那句优先;其次通道给的本地化原因;引擎回的英文内部错误不给人看,用通用那句。
    public static func failure(code: String?, localizedReason: String?, batch: Bool = false) -> Failure {
        if let key = reasonKey(code: code, batch: batch) { return .key(key) }
        if let reason = localizedReason, !reason.isEmpty { return .format(reasonFormatKey, reason: reason) }
        return .key(fallbackKey)
    }
}
