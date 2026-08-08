import Foundation
import NaturalLanguage

#if canImport(Translation)
    import Translation
#endif

// 端上歌词翻译小助手。collector(Go)没法调 Apple 的 Translation 框架,所以把这一步拆成
// 一个独立的 Swift 可执行文件打包进 Contents/Resources/,由 collector 按相对路径调用 ——
// 跟已有的 media-control 完全同一个形态(见 lyrimuse-collector/system.go 的
// mediaControlBinaryPath)。
//
// 为什么值得这么绕:系统翻译是**端上**的,不联网、无配额、歌词根本不出这台机器。相比之下
// MyMemory 那条网络兜底路匿名只有约 5000 字符/天(实测翻三四首歌就用光了),而且要把歌词
// 正文发给第三方。
//
// 拆成独立进程还顺带兜住一个风险:Translation.framework 要 macOS 15+,真在更老的系统上
// 加载失败,也只是这个 helper 起不来、collector 退回 MyMemory,不会影响主程序。
//
// 协议(stdin/stdout 各一行 JSON):
//   入:  {"target":"zh-Hans","lines":["...","..."]}
//   出:  {"ok":true,"source":"en","lines":["...","..."]}
//        {"ok":false,"reason":"notInstalled","source":"ja"}
// 行数**必须**原样返回,调用方靠下标对齐;翻不动的行原样回传。

struct Input: Decodable {
    let target: String
    let lines: [String]
}

struct Output: Encodable {
    var ok: Bool
    var source: String?
    var lines: [String]?
    var reason: String?
}

func emit(_ out: Output) -> Never {
    if let data = try? JSONEncoder().encode(out), let s = String(data: data, encoding: .utf8) {
        print(s)
    }
    exit(out.ok ? 0 : 1)
}

// 源语言用 NaturalLanguage 识别整段文本 —— Translation 的 status(for:) 只回一个可用性
// 状态、不告诉你识别出的是哪种语言,而 TranslationSession 必须要一个明确的源语言。
func detectSourceLanguage(_ lines: [String]) -> String? {
    let sample = lines.prefix(40).joined(separator: "\n")
    guard !sample.isEmpty else { return nil }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(sample)
    return recognizer.dominantLanguage?.rawValue
}

@main
struct LyricsTranslate {
    static func main() async {
        guard let data = FileHandle.standardInput.readDataToEndOfFile() as Data?,
            let input = try? JSONDecoder().decode(Input.self, from: data)
        else {
            emit(Output(ok: false, reason: "bad-input"))
        }
        guard !input.lines.isEmpty, !input.target.isEmpty else {
            emit(Output(ok: false, reason: "empty-input"))
        }
        guard let sourceCode = detectSourceLanguage(input.lines) else {
            emit(Output(ok: false, reason: "undetected-source"))
        }
        // 源语言跟目标一致就没什么可翻的 —— 交给调用方按"没有译文"处理,别浪费一次进程启动。
        if input.target.hasPrefix(sourceCode) || sourceCode.hasPrefix(String(input.target.prefix(2))) {
            emit(Output(ok: false, source: sourceCode, reason: "same-language"))
        }

        #if canImport(Translation)
            guard #available(macOS 26.0, *) else {
                // macOS 26 之前 TranslationSession 只能挂在 SwiftUI 视图上(.translationTask),
                // 没法在命令行进程里直接构造 —— 这条路走不通,让调用方退回网络翻译。
                emit(Output(ok: false, source: sourceCode, reason: "needs-macos-26"))
            }
            let source = Locale.Language(identifier: sourceCode)
            let target = Locale.Language(identifier: input.target)

            let status = await LanguageAvailability().status(from: source, to: target)
            guard status == .installed else {
                // supported = 系统支持但语言包没下载。这里不擅自触发下载:那会弹系统 UI,
                // 而这是个被后台采集器调起来的无界面进程,弹窗会没头没尾地打断用户。
                // 交给调用方(最终是设置页里一个显式的"下载语言包"入口)。
                emit(Output(ok: false, source: sourceCode, reason: "\(status)"))
            }
            let session = TranslationSession(installedSource: source, target: target)
            do {
                let requests = input.lines.map { TranslationSession.Request(sourceText: $0) }
                let responses = try await session.translations(from: requests)
                // 按请求顺序返回,数量必须一致 —— 少一条就整体作废,错位的译文比没有译文更糟。
                guard responses.count == input.lines.count else {
                    emit(Output(ok: false, source: sourceCode, reason: "count-mismatch"))
                }
                emit(Output(ok: true, source: sourceCode, lines: responses.map(\.targetText)))
            } catch {
                emit(Output(ok: false, source: sourceCode, reason: "\(error)"))
            }
        #else
            emit(Output(ok: false, source: sourceCode, reason: "no-translation-framework"))
        #endif
    }
}
