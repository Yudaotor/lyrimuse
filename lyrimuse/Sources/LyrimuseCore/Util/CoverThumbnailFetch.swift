import Foundation

/// 封面缩略图下载的两条判据(`CachedImage` 用):向图床要多大的图、哪种失败值得马上再试一次。
public enum CoverThumbnailFetch {
    /// 缩略档实际去下载的地址:用到多大就要多大,不默认拿原图。
    ///
    /// 各源给的封面地址多是大图(网易云 3000px 约 3MB、Apple 3000px 约 2.4MB、酷狗 / 酷我原图 1500px
    /// 约 0.8MB),而缩略档最多用到 `maxPixel`(256px)。能在地址里指定尺寸的图床,换成**不小于
    /// maxPixel 的最小一档**;每家只认实测过的那一种地址形状,形状对不上一个字都不改 —— 改错是
    /// 404、整张封面消失。实测档位(同一张图逐档请求,状态码 + 实际像素):
    /// - 网易云 `?param=NyN`:任意边长;
    /// - Apple(mzstatic)末段 `NxNbb.jpg`:任意边长;
    /// - QQ 音乐 `T00xRNxNM…`:150 / 300 / 500 / 800;
    /// - 酷狗 `/stdmusic/N/`:150 / 240 / 480(0 = 原图);
    /// - 酷我 `/albumcover/N/`:120 / 300 / 500(0 = 原图);
    /// - 汽水(douyinpic)`~tplv-…-resize:W:H`:300 / 600(0:0 = 原图);
    /// - Musixmatch `_N_N.jpg`:350 / 800(100 是 403);
    /// - Google 图床(googleusercontent,YouTube Music 借来的封面)末尾 `=s0` / `=wN-hN-…`:换成 `=sN`,任意边长;
    /// - Deezer `/images/cover/<id>/NxN-…`:任意边长。
    /// 咪咕的地址里没有尺寸,原样。缓存仍按原地址记,这里只换"去哪下"。
    /// 只管缩略档(maxPixel ≤ 512);原图档的地址由调用方自己挑(见 EnrichCacheReader.nativeSizedCoverURL)。
    public static func url(for url: URL, maxPixel: Int) -> URL {
        guard maxPixel > 0, maxPixel <= 512,
              let host = url.host?.lowercased(),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        let path = comps.percentEncodedPath

        if isHost(host, "music.126.net") {
            comps.percentEncodedQuery = "param=\(maxPixel)y\(maxPixel)"
            return comps.url ?? url
        }
        if isHost(host, "mzstatic.com") {
            return replacingLastComponent(of: url, pattern: #"^(\d+)x(\d+)([a-z]*)\.(jpg|jpeg|png|webp)$"#) { m in
                "\(maxPixel)x\(maxPixel)\(m[3]).\(m[4])"
            } ?? url
        }
        if host == "y.qq.com" || host == "y.gtimg.cn" {
            let edge = snap(maxPixel, to: [150, 300, 500, 800])
            return replacingPath(url, comps, path, pattern: #"(/T00[12]R)\d+x\d+(M)"#) { m in
                "\(m[1])\(edge)x\(edge)\(m[2])"
            } ?? url
        }
        if isHost(host, "kugou.com"), path.hasPrefix("/stdmusic/") {
            let edge = snap(maxPixel, to: [150, 240, 480])
            return replacingPath(url, comps, path, pattern: #"^/stdmusic/\d+/"#) { _ in "/stdmusic/\(edge)/" } ?? url
        }
        if isHost(host, "kuwo.cn"), path.hasPrefix("/star/albumcover/") {
            let edge = snap(maxPixel, to: [120, 300, 500])
            return replacingPath(url, comps, path, pattern: #"^/star/albumcover/\d+/"#) { _ in "/star/albumcover/\(edge)/" } ?? url
        }
        if isHost(host, "douyinpic.com") {
            let edge = snap(maxPixel, to: [300, 600])
            return replacingPath(url, comps, path, pattern: #"(~tplv-[A-Za-z0-9]+-resize:)\d+:\d+(\.[a-z]+)$"#) { m in
                "\(m[1])\(edge):\(edge)\(m[2])"
            } ?? url
        }
        if host == "s.mxmcdn.net" {
            let edge = snap(maxPixel, to: [350, 800])
            return replacingPath(url, comps, path, pattern: #"_\d+_\d+(\.jpg)$"#) { m in "_\(edge)_\(edge)\(m[1])" } ?? url
        }
        if isHost(host, "googleusercontent.com") {
            return replacingPath(url, comps, path, pattern: #"=[A-Za-z0-9-]+$"#) { _ in "=s\(maxPixel)" } ?? url
        }
        if isHost(host, "dzcdn.net") {
            return replacingPath(url, comps, path, pattern: #"^(/images/cover/[0-9a-f]+/)\d+x\d+-"#) { m in
                "\(m[1])\(maxPixel)x\(maxPixel)-"
            } ?? url
        }
        return url
    }

    /// 这次失败值不值得隔一会儿马上再试:服务端 5xx / 429,或者超时、断连这类临时网络错。
    /// 404、403、解码失败这些再试也一样,不重试。
    public static func shouldRetry(statusCode: Int?, urlErrorCode: Int?) -> Bool {
        if let s = statusCode, s == 429 || (500...599).contains(s) { return true }
        guard let c = urlErrorCode else { return false }
        let transient: [URLError.Code] = [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                                          .notConnectedToInternet, .dnsLookupFailed]
        return transient.contains { $0.rawValue == c }
    }

    /// 不小于 need 的最小一档;都比 need 小就取最大那档。
    static func snap(_ need: Int, to sizes: [Int]) -> Int {
        sizes.first { $0 >= need } ?? sizes.last ?? need
    }

    /// 主机等于 domain 或是它的 `.` 分隔子域。不用光 hasSuffix —— 那连 evilmusic.126.net 都会认。
    static func isHost(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    private static func replacingPath(_ url: URL, _ comps: URLComponents, _ path: String, pattern: String,
                                      _ make: ([String]) -> String) -> URL? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let whole = Range(m.range, in: path)
        else { return nil }
        let groups = (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: path).map { String(path[$0]) } ?? ""
        }
        var c = comps
        c.percentEncodedPath = path.replacingCharacters(in: whole, with: make(groups))
        return c.url
    }

    private static func replacingLastComponent(of url: URL, pattern: String, _ make: ([String]) -> String) -> URL? {
        let last = url.lastPathComponent
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: last, range: NSRange(last.startIndex..., in: last))
        else { return nil }
        let groups = (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: last).map { String(last[$0]) } ?? ""
        }
        return url.deletingLastPathComponent().appendingPathComponent(make(groups))
    }
}
