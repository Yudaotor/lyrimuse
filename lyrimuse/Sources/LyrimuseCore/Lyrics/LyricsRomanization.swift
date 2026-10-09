import Foundation

/// 把一整份逐行 LRC 转成一份**罗马音 LRC**(时间戳原样保留,正文换成读音)。
///
/// 在此之前罗马音只有两条路:歌词源自带(`lyrics_roma`)、或者 App 在播放时
/// 现算(`LyricsSyncEngine` 的客户端兜底)。现算那条有两个实打实的缺陷:
///  ① **导不出去**。`lyrics_roma` 会被写成 `.roma.lrc` 文件,现算的不会 —— 用户把歌词
///     文件夹拷到别处、或用别的播放器读,罗马音就丢了。
///  ② 统计口径对不上:本机 3566 条里只有 114 条带 `lyrics_roma`(3.2%),而实际显示罗马音的
///     远多于此,面板上那个数字怎么写都别扭。
///
/// 这个函数是给 `lyrics-romanize` helper 用的(引擎是 Go,调不了 CFStringTokenizer /
/// ICU,只能起一个 Swift 子进程 —— 跟 `lyrics-translate` 完全同一个形态)。
///
/// **逐行读音走 `Romanizer.lineReading`,跟播放引擎的客户端兜底是同一个函数**。这一点是
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
    ///
    /// 喂给读音函数之前的预处理跟播放那条路逐项一致,顺序也一样,每一步都调同一个函数:
    ///  1. 日文歌先修回被源写成简体的汉字(`JapaneseKanjiRepair`,播放侧在 `LocalPlaybackSource` 交给引擎之前做);
    ///  2. 认出演唱者标签、按同一套规则判掉署名行(`LyricDuet.speakers` + `LyricsSyncEngine.strippingCreditLines`);
    ///  3. 「整首是不是日文歌」按**过滤后的正文**判 —— 按原文判会被元信息行、署名行里的日文人名带偏;
    ///  4. 每行先剥掉演唱者标签再算读音(否则读出「nán： zhōu mò」,引擎剥罗马音标签只认汉字那一形)。
    /// 少任何一步,有预生成结果的歌在播放时就跟现算的对不上(引擎优先用预生成的)。
    public static func romanizeLRC(_ lyrics: String) -> String? {
        guard !lyrics.isEmpty else { return nil }
        let prepared = readingRows(lyrics)
        var out: [String] = []
        for (tags, body) in prepared.rows {
            guard let reading = Romanizer.lineReading(
                body,
                songLooksJapanese: prepared.songLooksJapanese,
                segments: Romanizer.japaneseSegments(
                    body, marks: prepared.annotation?.marks(forLine: body) ?? [],
                    songLooksJapanese: prepared.songLooksJapanese)),
                !reading.isEmpty, reading != body
            else { continue }
            out.append(tags + reading)
        }
        // 只产出了个别几行时也照样交出去:`LyricsSyncEngine` 对 `romaLines` 是按行就近匹配的
        // (700ms 容差),缺行本来就是源自带罗马音的常态。
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }

    /// 缓存里的 `lyrics_roma` 去掉引擎按 `romanizeLRC` 预生成的那份(跟现算逐字一致的就是预生成的),剩下的才是歌词源
    /// 自带或手改的读音;是预生成的返回空串。「搜索候选歌词」里在用的那一版据此标不标「读音」:搜到的同一份候选
    /// 不带预生成读音,两边口径要一样(见 11 章决策 104)。
    public static func sourceProvidedRomanization(_ roma: String, lyrics: String) -> String {
        guard !roma.isEmpty, roma != romanizeLRC(lyrics) else { return "" }
        return roma
    }

    /// `roma` 是不是旧版韩文读音(ICU `Any-Latin` 逐字母转写)给这份正文算出来的。启动迁移靠它只换掉
    /// 引擎早先预生成的那份,歌词源给的对不上、不动(用户手改过的条目引擎那边整条跳过,不送来判)。
    /// 按含谚文的正文行逐行比:`roma` 里同一串时间标签的那一行跟这一行的 ICU 转写一字不差算一致,比得上的行里
    /// 一致的占八成以上才算。
    public static func isLegacyKoreanRomanization(_ roma: String, lyrics: String) -> Bool {
        guard !roma.isEmpty, !lyrics.isEmpty else { return false }
        var stored: [String: String] = [:]
        for raw in roma.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
            let line = String(raw)
            let ns = line as NSString
            guard let tagMatch = leadingTagsRegex.firstMatch(
                in: line, range: NSRange(location: 0, length: ns.length))
            else { continue }
            stored[ns.substring(with: tagMatch.range(at: 1))] = ns.substring(from: tagMatch.range.length)
        }
        var compared = 0
        var same = 0
        for (tags, body) in readingRows(lyrics).rows where Romanizer.containsHangul(body) {
            guard let line = stored[tags] else { continue }
            compared += 1
            if line == body.applyingTransform(.toLatin, reverse: false) { same += 1 }
        }
        return compared > 0 && same * 5 >= compared * 4
    }

    /// 要算读音的正文行(时间标签串 + 剥掉演唱者标签后的正文)和整首的判定,预处理见 `romanizeLRC` 的说明。
    private struct ReadingRows {
        var rows: [(tags: String, body: String)]
        var songLooksJapanese: Bool
        var annotation: KanaAnnotation?
    }

    private static func readingRows(_ lyrics: String) -> ReadingRows {
        let repaired = JapaneseKanjiRepair.repair(lyrics, japaneseSong: Romanizer.looksJapaneseSong(lyrics))
        // 酷狗那类把假名标注写进同一份 LRC 的源,读音优先用标注 —— 播放引擎也是从同一份
        // 歌词里 `KanaAnnotation.parse(lrc:)` 出来的,这里照做才能保证两条路读音一致。
        let annotation = KanaAnnotation.parse(lrc: repaired)
        // CRLF 归一化:社区上传内容(酷狗尤其常见)带 \r\n,不归一化的话按 "\n" 切出来的
        // 每一行尾部都挂着一个 \r,读音里会混进一个看不见的控制字符。见 LRCParser.parse
        // 同一处注释。
        let normalized = repaired.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // 先收齐带时间戳的正文行(标签串 + 正文),署名 / 演唱者 / 整首日文判定都要整份一起看。
        var rows: [(tags: String, body: String)] = []
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
            rows.append((tags, body))
        }
        let bodies = rows.map(\.body)
        let speakers = LyricDuet.speakers(in: bodies)
        let dropped = LyricsSyncEngine.strippingCreditLines(bodies, speakerExemptions: speakers)
        let kept = zip(rows, dropped).filter { !$0.1 }.map(\.0)
        let songLooksJapanese = Romanizer.looksJapaneseSong(kept.map(\.body).joined(separator: "\n"))
        let readable = kept.compactMap { tags, rawBody -> (tags: String, body: String)? in
            let body = LyricDuet.strippingKnownLabel(rawBody, speakers: speakers)
            return body.isEmpty ? nil : (tags, body)
        }
        return ReadingRows(rows: readable, songLooksJapanese: songLooksJapanese, annotation: annotation)
    }
}
