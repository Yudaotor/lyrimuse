import Foundation

/// Apple Music「动态封面」(motion artwork)的 HLS 清单解析(2026-09-09,用户:「帮我看看怎么把我们的
/// 封面搞成 applemusic 里面的那种会动的效果」)。
///
/// 这一层只做**纯字符串 → 该下载哪个文件**的推导,不发请求、不碰磁盘,所以能被 selftest 钉死。
/// 发现资源在 collector(`motioncover.go`),下载与播放在 App(`MotionCoverStore` / `MotionCoverLayer`)。
///
/// 全部结论都是 2026-09-09 在 Prince《Timeless》(collectionId 6773830957)上实测出来的:
///
///   * **资源是公开的**。专辑页 `music.apple.com/{sf}/album/x/{id}` 的 HTML 里
///     `videoArtwork.dictionary.motionDetailSquare.video` 就是一条 master m3u8,直接 curl 得到
///     HTTP 200,不需要 developer token / cookie / Referer。另有 `tallVideoArtwork` 是 3:4 竖版
///     (`motionDetailTall`),我们要的是方的那份。
///   * **七档 × 两种编码**:360² / 408² / 456² / 486² / 768² / 960² / 1080²,H.264(`avc1`)与
///     HEVC(`hvc1`)各一份,统一 24fps,`AVERAGE-BANDWIDTH` 从 266kbps 到 5.1Mbps。
///   * **没有音轨**:variant 名里那个 `Anull` 是实话,`CLOSED-CAPTIONS=NONE`,`loadTracks(.audio)`
///     回 0 条 —— 所以它不会跟正在放的音乐抢音频会话,播放侧也不用管静音。
///   * **每一档的分片全是同一个 `.mp4` 的 byte range**(`#EXT-X-MAP:URI="…-.mp4",BYTERANGE=…`
///     后面跟着一串 `#EXT-X-BYTERANGE` 指回同一个文件)。这是本文件存在的全部理由:既然底层就是
///     一个完整文件,那就**整份下下来当普通 mp4 播**,不必拼分片、不必上 `AVAssetDownloadURLSession`
///     那套 `.movpkg` 离线方案。实测下下来的 768² 是 5.39 MB、960² 是 7.17 MB,两份都
///     `isPlayable == true`、`duration == 20.00s`、单视频轨零音轨。
///   * **首尾帧几乎一致**:把首帧与末帧(19.96s)各抓出来缩到 64² 比 R 通道,平均绝对差 0.58/255、
///     最大 4/255。也就是说 Apple 这段素材本身就是按**无缝循环**做的 —— 播放侧 `AVPlayerLooper`
///     硬接就够,不需要 pingpong 倒放或交叉淡化。
///
/// ⚠️ 这是在解析**公开网页里的非公开字段**:Apple 改一次结构这条路就断。所以每一层都必须
/// "解析不出来就当这张专辑没有动态封面",绝不能把失败往上抛成用户可见的错误 —— 覆盖率本来就低
/// (2026-09-09 抽 10 张专辑只有 3 张有:Prince《Timeless》、Taylor Swift《1989 (Taylor's Version)》、
/// Michael Jackson《Thriller》;测到的华语专辑一张都没有),用户对"这首没有"是无感的。
public enum MotionCoverManifest {

    /// master m3u8 里的一条可播档位。
    public struct Variant: Equatable, Sendable {
        /// `#EXT-X-STREAM-INF` 下面紧跟的那一行(可能是相对路径)。
        public let uri: String
        public let width: Int
        public let height: Int
        /// `AVERAGE-BANDWIDTH`,没有就退 `BANDWIDTH`;都没有则 0。
        public let bandwidth: Int
        /// `CODECS` 里带 `hvc1` / `hev1`。
        public let isHEVC: Bool

        public init(uri: String, width: Int, height: Int, bandwidth: Int, isHEVC: Bool) {
            self.uri = uri
            self.width = width
            self.height = height
            self.bandwidth = bandwidth
            self.isHEVC = isHEVC
        }
    }

    // MARK: - master

    /// 从 master m3u8 里挑出所有**可播**档位。
    ///
    /// ⚠️ 刻意跳过 `#EXT-X-I-FRAME-STREAM-INF`:那些是给 trick play(拖拽预览)用的纯 I 帧轨,
    /// 名字里带 `trickPlay`、同样声明着 `RESOLUTION`,当成播放档会拿到一个每帧都是关键帧的
    /// 怪东西。master 里它们的条数跟正片一样多(实测各 8 条),不排掉就是一半的噪声。
    public static func parseVariants(master: String) -> [Variant] {
        var out: [Variant] = []
        let lines = master.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard line.hasPrefix("#EXT-X-STREAM-INF:") else { i += 1; continue }
            let attrs = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
            // URI 是紧跟其后的第一个非空、非注释行。
            var j = i + 1
            var uri: String?
            while j < lines.count {
                let candidate = lines[j]
                if candidate.isEmpty { j += 1; continue }
                if candidate.hasPrefix("#") { break }
                uri = candidate
                break
            }
            if let uri, !uri.isEmpty,
               let res = attribute("RESOLUTION", in: attrs),
               let size = parseResolution(res) {
                let bw = attribute("AVERAGE-BANDWIDTH", in: attrs) ?? attribute("BANDWIDTH", in: attrs)
                let codecs = attribute("CODECS", in: attrs)?.lowercased() ?? ""
                out.append(Variant(uri: uri, width: size.0, height: size.1,
                                   bandwidth: bw.flatMap { Int($0) } ?? 0,
                                   isHEVC: codecs.contains("hvc1") || codecs.contains("hev1")))
                i = j + 1
            } else {
                i += 1
            }
        }
        return out
    }

    /// 选一档:**够用的最小那档**。
    ///
    /// - 先只看宽度 ≥ `minimumWidth` 的,取其中最小的一档 —— 再大只是白下字节,动态封面不做放大用途。
    ///   一档都不够宽(小专辑可能只放到 486²)就退回最大的那档,宁可放大也别不动。
    /// - 同尺寸时**优先 H.264**。理由是实测:2026-09-09 取 HEVC 那档的 variant m3u8 连不上
    ///   (`http=000`,同一时刻同一个 base 下的 H.264 档正常 200),H.264 那条是从头到尾走通过的。
    ///   HEVC 省 ~25% 字节,但这条路的可靠性没核实过,不拿它当默认。
    public static func pick(_ variants: [Variant], minimumWidth: Int) -> Variant? {
        guard !variants.isEmpty else { return nil }
        let fits = variants.filter { $0.width >= minimumWidth }
        let pool = fits.isEmpty ? variants : fits
        // 目标宽度:够用的里挑最小,不够用时挑最大。
        let targetWidth = fits.isEmpty ? (pool.map(\.width).max() ?? 0) : (pool.map(\.width).min() ?? 0)
        let sameSize = pool.filter { $0.width == targetWidth }
        // 同尺寸里 H.264 优先;再同就取码率低的(同尺寸同编码 master 里确实有多条,实测 486² 有 3 条)。
        return sameSize.sorted { a, b in
            if a.isHEVC != b.isHEVC { return !a.isHEVC }
            return a.bandwidth < b.bandwidth
        }.first
    }

    // MARK: - variant

    /// 从某一档 variant 的 m3u8 里取出那个**承载全部分片的单文件**名。
    ///
    /// 形态(实测):`#EXT-X-MAP:URI="P1397633581_Anull_video_gr240_sdr_768x768-.mp4",BYTERANGE="877@0"`
    /// —— `EXT-X-MAP` 指的 init segment 和后面每个 `#EXT-X-BYTERANGE` 分片指的是**同一个文件**,
    /// 整份下下来就是完整 fMP4。
    ///
    /// 刻意读 `EXT-X-MAP` 而不是"拿 variant 名去掉 `.m3u8` 再加 `-.mp4`":那个命名规律实测成立,
    /// 但它是规律不是契约,而多读一个几 KB 的 variant 清单就能拿到权威答案。
    public static func mediaFileName(fromVariant playlist: String) -> String? {
        for raw in playlist.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#EXT-X-MAP:") else { continue }
            let attrs = String(line.dropFirst("#EXT-X-MAP:".count))
            if let uri = attribute("URI", in: attrs), !uri.isEmpty { return uri }
        }
        return nil
    }

    /// 把 master / variant 里可能是相对路径的 URI 解成绝对地址。实测 Apple 给的是绝对 URL,
    /// 但 HLS 允许相对,不额外处理的话哪天变成相对就整条哑掉。
    public static func absolute(_ uri: String, relativeTo base: URL) -> URL? {
        if let u = URL(string: uri), u.scheme != nil { return u }
        return URL(string: uri, relativeTo: base)?.absoluteURL
    }

    // MARK: - 属性解析

    /// 取 HLS 属性列表里某个键的值,去掉包裹的引号。
    ///
    /// `public` 是为了让 selftest(独立 target)能直接钉这两个真实踩到的陷阱 —— 值里自带逗号、
    /// 以及 `BANDWIDTH` 会命中 `AVERAGE-BANDWIDTH` 的尾巴。经 `parseVariants` 间接测覆盖不到边界。
    ///
    /// ⚠️ 不能简单按逗号切:`CODECS="avc1.64001f,mp4a.40.2"` 的值**自己带逗号**,而
    /// `STABLE-VARIANT-ID` 之类的值又可能带 `=`。所以从 `KEY=` 开始扫,带引号的读到闭合引号,
    /// 不带引号的读到下一个逗号。
    public static func attribute(_ key: String, in attrs: String) -> String? {
        let chars = Array(attrs)
        let needle = Array(key + "=")
        var i = 0
        while i + needle.count <= chars.count {
            // 键必须落在属性边界上(串首,或紧跟一个逗号),否则 `BANDWIDTH` 会命中
            // `AVERAGE-BANDWIDTH` 的尾巴、`_AVG-BANDWIDTH` 也会撞上来(master 里真有这两个)。
            let atBoundary = i == 0 || chars[i - 1] == ","
            if atBoundary, Array(chars[i..<(i + needle.count)]) == needle {
                var j = i + needle.count
                if j < chars.count, chars[j] == "\"" {
                    j += 1
                    var v = ""
                    while j < chars.count, chars[j] != "\"" { v.append(chars[j]); j += 1 }
                    return v
                }
                var v = ""
                while j < chars.count, chars[j] != "," { v.append(chars[j]); j += 1 }
                return v.trimmingCharacters(in: .whitespaces)
            }
            i += 1
        }
        return nil
    }

    /// `768x768` → (768, 768)。
    public static func parseResolution(_ s: String) -> (Int, Int)? {
        let parts = s.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else { return nil }
        return (w, h)
    }
}
