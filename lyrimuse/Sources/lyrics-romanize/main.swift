import Foundation
import LyrimuseCore

// 歌词罗马音预生成小助手。collector(Go)算不了这一步 —— 日文**必须**走 CFStringTokenizer
// 形态分析(不能用 ICU 通用音译:汉字是中日共用的,Any-Latin 会一律按普通话读,
// 「火曜日の朝は」→"huǒ yào rìno cháoha"),中文走 ICU `applyingTransform(.toLatin)`,这两样是 Apple 的
// 系统能力,Go 里没有对应物;韩文按读音规则(`KoreanRomanization`),跟 App 现算共用同一份 Swift 实现,
// 也不在 Go 里另写一份。所以拆成一个独立的 Swift 可执行文件打包进
// Contents/Resources/,由 collector 按相对路径调用 —— 跟 lyrics-translate / media-control
// 完全同一个形态。
//
// 对照:**粤拼**不走这里。它是纯查表(rime-cantonese 词典 go:embed 进二进制),collector
// 自己就算得出来,见 jyutping.go。差异从来不是"要不要缓存",是"谁算得出来"。
//
// 为什么值得预生成(而不是继续只靠 App 播放时现算):
//  ① **能导出**。`lyrics_roma` 会被写成 `.roma.lrc` 文件,现算的不会 —— 用户把歌词文件夹
//     拷到别处、或用别的播放器读,罗马音就丢了。这是唯一真正值得为它动手的理由。
//  ② 省掉换歌那一下整首现算的主线程开销(20Hz 热路径本来就有按行记忆化,不是瓶颈)。
//
// 读音本体走 `LyricsRomanization.romanizeLRC` → `Romanizer.lineReading`,跟 App 播放时
// 的客户端兜底**是同一个函数**。预生成的产物必须跟现算逐字一致,否则同一首歌"装了缓存"和
// "现算"读音不一样 —— 那种不一致不报错,只表现成用户偶尔觉得"某句罗马音怎么变了"。
//
// 比 lyrics-translate 简单的地方:CFStringTokenizer / ICU 在任何 macOS 上都有,不像
// Translation.framework 要 macOS 26+,所以这里没有版本兜底、也没有网络退路这两套东西。
//
// 协议(stdin/stdout 各一行 JSON):
//   入:  {"lyrics":"[00:12.34]君の名は\n..."}
//        启动迁移时多带 "legacy_korean_roma"(缓存里现有的罗马音):它不是旧版韩文读音给这份正文算出来的,
//        就回 not-legacy、不产出(见 LyricsRomanization.isLegacyKoreanRomanization);是旧版就照常产出,
//        另带 "legacy_checked":true。collector 只认带了这个标记的回包(不认这个入参的旧 helper 会照常回一份)。
//   出:  {"ok":true,"roma":"[00:12.34]kimi no na wa\n..."}
//        {"ok":true,"roma":"...","legacy_checked":true}
//        {"ok":false,"reason":"no-romanization"}
//        {"ok":false,"reason":"not-legacy"}

struct Input: Decodable {
    let lyrics: String
    let legacyKoreanRoma: String?

    enum CodingKeys: String, CodingKey {
        case lyrics
        case legacyKoreanRoma = "legacy_korean_roma"
    }
}

struct Output: Encodable {
    var ok: Bool
    var roma: String?
    var reason: String?
    var legacyChecked: Bool?

    enum CodingKeys: String, CodingKey {
        case ok, roma, reason
        case legacyChecked = "legacy_checked"
    }
}

func emit(_ out: Output) -> Never {
    if let data = try? JSONEncoder().encode(out), let s = String(data: data, encoding: .utf8) {
        print(s)
    }
    // 退出码非 0 表示"没产出",但原因写在 stdout 的 JSON 里 —— 调用方先解析再判错,
    // 别把"这首歌本来就是拉丁字母、没什么可注音的"报成执行失败。同 lyrics-translate。
    exit(out.ok ? 0 : 1)
}

let data = FileHandle.standardInput.readDataToEndOfFile()
guard let input = try? JSONDecoder().decode(Input.self, from: data) else {
    emit(Output(ok: false, reason: "bad-input"))
}
guard !input.lyrics.isEmpty else {
    emit(Output(ok: false, reason: "empty-input"))
}
var legacyChecked: Bool?
if let stored = input.legacyKoreanRoma {
    guard LyricsRomanization.isLegacyKoreanRomanization(stored, lyrics: input.lyrics) else {
        emit(Output(ok: false, reason: "not-legacy"))
    }
    legacyChecked = true
}
guard let roma = LyricsRomanization.romanizeLRC(input.lyrics) else {
    emit(Output(ok: false, reason: "no-romanization"))
}
emit(Output(ok: true, roma: roma, legacyChecked: legacyChecked))
