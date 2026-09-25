import CryptoKit
import Foundation

/// 歌词判决记录的**候选明细旁路文件**(collector 侧 `decisionstore.go`,两边逐字节同一套约定)。
///
/// 主缓存 `lyrimuse-enrich-cache.json` 里的两槽判决(`lyrics_decision` / `lyrics_decision_applied`)只留
/// 顶层字段(路径 / 时间 / 打分版本 / 胜者 …);最占地方的 `candidates` + `queries_tried` 单独存在
/// `lyrimuse-decisions/<sha256(key) 前 32 位十六进制>.json`:
///
///     {"key": "...", "latest": {指纹 + candidates + queries_tried}, "applied": {...}}
///
/// 两份明细一样时是 `"applied_same": true`、没有 `applied`。起因:判决记录占主缓存 40%,
/// 而明细只有「解析决策」弹窗和离线分析要看。
///
/// **指纹** = path + decided_at + scoring_version + winner + reused_from。补明细时拿主缓存那一槽的指纹
/// 去两份明细里找对得上的,找不到就不补 —— 弹窗显示「候选明细缺失」,绝不拿别的轮次的候选去配这一轮
/// 的胜者。
public enum DecisionSidecar {
    public static let directoryName = "lyrimuse-decisions"

    /// 旁路文件名:key 的 SHA-256 前 16 字节,小写十六进制,加 `.json`(collector `decisionSidecarName`)。
    public static func fileName(forKey key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    /// 读一条的旁路文件;没有 / 解不出来是 nil。
    public static func loadRecord(key: String, directory: URL) -> [String: Any]? {
        let url = directory.appendingPathComponent(fileName(forKey: key))
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// 给主缓存里某一槽的判决字典补上明细。已经带着 candidates(老条目 / 还没被 collector 拆过)、
    /// 没有旁路记录、或指纹对不上时原样返回。
    public static func hydrate(_ decision: [String: Any], record: [String: Any]?) -> [String: Any] {
        guard decision["candidates"] == nil, decision["queries_tried"] == nil, let record else {
            return decision
        }
        var slots: [[String: Any]] = []
        if let latest = record["latest"] as? [String: Any] { slots.append(latest) }
        if let applied = record["applied"] as? [String: Any] { slots.append(applied) }
        guard let match = slots.first(where: { sameFingerprint($0, decision) }) else { return decision }
        var out = decision
        if let c = match["candidates"] { out["candidates"] = c }
        if let q = match["queries_tried"] { out["queries_tried"] = q }
        // 补回来了就不再是「明细在外面」:弹窗只在这个标记还在(= 补不回来)时显示「候选明细缺失」。
        out.removeValue(forKey: "details_external")
        return out
    }

    /// 两边的指纹字段是否一致。数字按 Int64 比(JSONSerialization 解出来是 NSNumber),缺失的字符串
    /// 按空串比(collector 侧 winner / reused_from 带 omitempty)。
    public static func sameFingerprint(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        func str(_ d: [String: Any], _ k: String) -> String { d[k] as? String ?? "" }
        func num(_ d: [String: Any], _ k: String) -> Int64 { (d[k] as? NSNumber)?.int64Value ?? 0 }
        return str(a, "path") == str(b, "path")
            && num(a, "decided_at") == num(b, "decided_at")
            && num(a, "scoring_version") == num(b, "scoring_version")
            && str(a, "winner") == str(b, "winner")
            && str(a, "reused_from") == str(b, "reused_from")
    }

    /// 缓存条目里两槽都按旁路文件补齐(备份打包用:备份要自带完整证据,恢复到别的机器上再由那边的
    /// collector 拆出去)。
    public static func hydrateEntry(_ entry: [String: Any], key: String, directory: URL) -> [String: Any] {
        let slots = ["lyrics_decision", "lyrics_decision_applied"]
        let needs = slots.contains { slot in
            guard let d = entry[slot] as? [String: Any] else { return false }
            return d["candidates"] == nil && d["queries_tried"] == nil
        }
        guard needs, let record = loadRecord(key: key, directory: directory) else { return entry }
        var out = entry
        for slot in slots {
            if let d = entry[slot] as? [String: Any] { out[slot] = hydrate(d, record: record) }
        }
        return out
    }
}
