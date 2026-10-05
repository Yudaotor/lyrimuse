import Foundation

/// 同一种语言、同一种切法的系统分词器,借出去用、用完收回。新建一个分词器要加载词典,比切一行歌词贵得多。
///
/// 一个 CFStringTokenizer 同一时间只能切一段文字:借出去期间只归一个调用方,遍历途中再借(读音分段里切数字读法)
/// 会另拿一个,多个线程同时借也各拿各的。收回时换成空串,不留着上一段文字。
final class StringTokenizerPool: @unchecked Sendable {
    private let unit: CFOptionFlags
    private let locale: CFLocale?
    private let lock = NSLock()
    private var idle: [CFStringTokenizer] = []
    private static let maxIdle = 4

    init(unit: CFOptionFlags, locale: CFLocale?) {
        self.unit = unit
        self.locale = locale
    }

    /// 拿一个切 `text` 的分词器跑 `body`;建不出分词器时返回 nil。分词器只在 `body` 里能用。
    func withTokenizer<T>(for text: CFString, _ body: (CFStringTokenizer) -> T?) -> T? {
        let range = CFRangeMake(0, CFStringGetLength(text))
        lock.lock()
        let reused = idle.popLast()
        lock.unlock()
        let tokenizer: CFStringTokenizer
        if let reused {
            CFStringTokenizerSetString(reused, text, range)
            tokenizer = reused
        } else if let created = CFStringTokenizerCreate(nil, text, range, unit, locale) {
            tokenizer = created
        } else {
            return nil
        }
        defer {
            CFStringTokenizerSetString(tokenizer, "" as CFString, CFRangeMake(0, 0))
            lock.lock()
            if idle.count < Self.maxIdle { idle.append(tokenizer) }
            lock.unlock()
        }
        return body(tokenizer)
    }
}
