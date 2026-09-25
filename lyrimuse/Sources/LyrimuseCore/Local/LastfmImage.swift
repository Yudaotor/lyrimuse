import Foundation

/// Last.fm 响应里图片字段的取用规则。
///
/// Last.fm 给所有缺图的实体(歌手、曲目、专辑)共用同一张「万能占位图」(一颗白星,文件名里是
/// 固定的 hash)。它是能正常加载的 URL,不滤掉的话会顶掉首字母色块、显示成一块灰,所以
/// 这里一律当作「没有图」。
public enum LastfmImage {
    public static let placeholderHash = "2a96cbd8b46e442fc41c2b86b821562f"

    /// 一个现成的图片 URL 串:空串或占位图返回 nil,其余原样返回。
    public static func usable(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, !raw.contains(placeholderHash) else { return nil }
        return raw
    }

    /// `image` 字段 `[{size: small/medium/large/extralarge, "#text": url}]` 里挑一张:
    /// 优先 large,没有退 extralarge,再退数组最后一项;挑中的是空串或占位图返回 nil。
    public static func pick(_ value: Any?) -> String? {
        guard let arr = value as? [[String: Any]] else { return nil }
        let by = { (size: String) in arr.first { ($0["size"] as? String) == size } }
        return usable((by("large") ?? by("extralarge") ?? arr.last)?["#text"] as? String)
    }
}
