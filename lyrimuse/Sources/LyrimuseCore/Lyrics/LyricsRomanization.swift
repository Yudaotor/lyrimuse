import Foundation

/// 把一整份逐行 LRC 转成一份**罗马音 LRC**(时间戳原样保留,正文换成读音)。
///
/// 2026-09-03 加。在此之前罗马音只有两条路:歌词源自带(`lyrics_roma`)、或者 App 在播放时
/// 现算(`LyricsSyncEngine` 的客户端兜底)。现算那条有两个实打实的缺陷:
///  ① **导不出去**。`lyrics_roma` 会被写成 `.roma.lrc` 文件,现算的不会 —— 用户把歌词
///     文件夹拷到别处、或用别的播放器读,罗马音就丢了。
///  ② 统计口径对不上:本机 3566 条里只有 114 条带 `lyrics_roma`(3.2%),而实际显示罗马音的
///     远多于此,面板上那个数字怎么写都别扭。
///
/// 这个函数是给 `lyrics-romanize` helper 用的(collector 是 Go,调不了 CFStringTokenizer /
/// ICU,只能起一个 Swift 子进程 —— 跟 `lyrics-translate` 完全同一个形态)。
///
/// ⚠️ **逐行读音走 `Romanizer.lineReading`,跟播放引擎的客户端兜底是同一个函数**。这一点是
/// 这条特性能不能成立的前提:预生成的产物必须跟现算结果逐字一致,否则同一首歌"装了缓存"和
/// "现算"读音不一样,而且不报错、只表现成用户偶尔觉得"某句罗马音怎么变了"。
public enum LyricsRomanization {
    /// 行首那一串 `[...]` 标签(一行可能挂多个时间戳,副歌重复时常见)。
    private static let leadingTagsRegex = try! NSRegularExpression(pattern: #"^((?:\[[^\]]*\])+)"#)
    /// 判断那串标签里到底有没有**时间戳** —— `[ti:]`/`[by:]`/`[kana:]` 这些元信息行同样
    /// 匹配上面那个正则,但它们不该产出罗马音行。
    private static let timestampRegex = try! NSRegularExpression(
        pattern: #"\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?\]"#)

    /// - Returns: 罗马音 LRC;整份一行都产不出读音(纯拉丁歌词、空输入等)时返回 `nil` ——
    ///   调用方按"这首歌没有罗马音"处理,别写一个空字符串进缓存(那会让
    ///   `LyricsSyncEngine` 的 `romaLines.isEmpty` 判据失真:非空但全无内容的 `lyrics_roma`
    ///   会**关掉**客户端兜底那条路,比没有更糟)。
    public static func romanizeLRC(_ lyrics: String) -> String? {
        guard !lyrics.isEmpty else { return nil }
        // 整首歌的日文判定跟播放引擎同一个函数,阶梯里"纯汉字行看整首"那一支要用它。
        let songLooksJapanese = Romanizer.looksJapaneseSong(lyrics)
        // 酷狗那类把假名标注写进同一份 LRC 的源,读音优先用标注 —— 播放引擎也是从同一份
        // 歌词里 `KanaAnnotation.parse(lrc:)` 出来的,这里照做才能保证两条路读音一致。
        let annotation = KanaAnnotation.parse(lrc: lyrics)
        // CRLF 归一化:社区上传内容(酷狗尤其常见)带 \r\n,不归一化的话按 "\n" 切出来的
        // 每一行尾部都挂着一个 \r,读音里会混进一个看不见的控制字符。见 LRCParser.parse
        // 同一处注释。
        let normalized = lyrics.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var out: [String] = []
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            guard let tagMatch = leadingTagsRegex.firstMatch(in: line, range: full) else { continue }
            let tags = ns.substring(with: tagMatch.range(at: 1))
            // 没有时间戳的纯标签行(元信息、假名标注轨)整行跳过。
            guard timestampRegex.firstMatch(
                in: tags, range: NSRange(location: 0, length: (tags as NSString).length)) != nil
            else { continue }
            let body = ns.substring(from: tagMatch.range.length)
                .trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            guard let reading = Romanizer.lineReading(
                body,
                songLooksJapanese: songLooksJapanese,
                segments: Romanizer.japaneseSegments(
                    body, marks: annotation?.marks(forLine: body) ?? [])),
                !reading.isEmpty, reading != body
            else { continue }
            out.append(tags + reading)
        }
        // 只产出了个别几行时也照样交出去:`LyricsSyncEngine` 对 `romaLines` 是按行就近匹配的
        // (700ms 容差),缺行本来就是源自带罗马音的常态。
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }
}
