import Foundation
import NaturalLanguage

#if canImport(Translation)
    // AppKit/SwiftUI 只为 macOS 15…25 那条路服务(见 translateOnMacOS15)。它们本身在
    // macOS 14 上就有,硬链接不影响老系统启动;真正 15+ 才有的 Translation 与
    // _Translation_SwiftUI 由编译器按 minos 自动弱链接(otool 可验),符号在 14 上为 null,
    // 走不到 #available 之后的代码。
    import AppKit
    import SwiftUI
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
// 按系统分三档,**三档都必须吐一行合法 JSON**(调用方只认这个):
//   macOS 26+   `TranslationSession(installedSource:target:)` 直接构造,不碰 AppKit。
//   macOS 15…25 框架同样完整,但这个版本区间里拿 session 的**唯一**入口是 SwiftUI 的
//               `.translationTask`,所以挂一个离屏视图去接(translateOnMacOS15)。
//   macOS 14    Translation 整个框架都没有,`#available` 直接落到 needs-macos-15。
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

#if canImport(Translation)
    /// macOS 15…25 拿 `TranslationSession` 的唯一入口是 SwiftUI 的 `.translationTask`
    /// (直接构造器 `init(installedSource:target:)` 要 macOS 26),所以挂一个 1×1 的透明视图
    /// 去接那个 session。视图本身不显示任何东西。
    @available(macOS 15.0, *)
    private struct OffscreenTranslateView: View {
        let configuration: TranslationSession.Configuration
        let lines: [String]
        let finish: @Sendable ([String]?, String) -> Void

        var body: some View {
            Color.clear
                .frame(width: 1, height: 1)
                .translationTask(configuration) { session in
                    do {
                        let responses = try await session.translations(
                            from: lines.map { TranslationSession.Request(sourceText: $0) })
                        // 跟 26 那条路同一条约束:数量不一致整体作废,错位的译文比没有译文更糟。
                        guard responses.count == lines.count else {
                            finish(nil, "count-mismatch")
                            return
                        }
                        finish(responses.map(\.targetText), "ok")
                    } catch {
                        finish(nil, "\(error)")
                    }
                }
        }
    }

    /// 一次翻译的全部可变状态。**必须是 class**:这些状态要活到 SwiftUI 的 task 回调
    /// 和超时兜底那一刻,而它们都在 `withCheckedContinuation` 的闭包之后才跑 ——
    /// 用局部 `var` 会让 `@Sendable` 闭包捕到已经销毁的栈变量。
    @available(macOS 15.0, *)
    @MainActor
    private final class OffscreenTranslateGate {
        private var continuation: CheckedContinuation<(lines: [String]?, reason: String), Never>?
        private var window: NSWindow?

        init(_ continuation: CheckedContinuation<(lines: [String]?, reason: String), Never>) {
            self.continuation = continuation
        }

        func hold(_ window: NSWindow) {
            // NSWindow.isReleasedWhenClosed 默认为 true,这里必须关掉 —— 否则 close() 会让窗口
            // 自己释放一次,ARC 这边的强引用再释放一次,当场 over-release 崩溃
            // (EXC_BAD_ACCESS in objc_release)。同 LyricsOverlayWindow 的处置。
            window.isReleasedWhenClosed = false
            self.window = window
        }

        /// 只认第一次:SwiftUI 回调与超时兜底会撞在一起,continuation 恢复两次是硬崩溃。
        func settle(lines: [String]?, reason: String) {
            guard let continuation else { return }
            self.continuation = nil
            window?.orderOut(nil)
            window = nil
            continuation.resume(returning: (lines, reason))
        }
    }

    /// 持有当前这次翻译的状态。进程一次只翻一批,一个就够。
    @available(macOS 15.0, *)
    @MainActor private var offscreenTranslateGate: OffscreenTranslateGate?

    /// 在 macOS 15…25 上翻一批行。成功回译文,失败回 nil + 一个 reason。
    ///
    /// 调用方必须先确认语言包已安装(`LanguageAvailability`)再进来:`.translationTask`
    /// 撞上没装的语言包会**弹系统下载 UI**,而这是个被后台采集器调起的无界面进程,弹窗
    /// 会没头没尾地打断用户。这条约束跟 26 那条路是同一条。
    @available(macOS 15.0, *)
    @MainActor
    private func translateOnMacOS15(
        source: Locale.Language, target: Locale.Language, lines: [String]
    ) async -> (lines: [String]?, reason: String) {
        // .prohibited:进程完全不作为 UI app 出现 —— 不进 Dock、不进 Cmd-Tab、不抢焦点,
        // 也不需要 NSApplication.run()(async 主函数自己在 drain 主队列,事件循环够用)。
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        return await withCheckedContinuation { continuation in
            let gate = OffscreenTranslateGate(continuation)
            offscreenTranslateGate = gate
            let settle: @Sendable ([String]?, String) -> Void = { result, reason in
                Task { @MainActor in
                    gate.settle(lines: result, reason: reason)
                    offscreenTranslateGate = nil
                }
            }

            let window = NSWindow(
                contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.alphaValue = 0
            window.contentView = NSHostingView(
                rootView: OffscreenTranslateView(
                    configuration: TranslationSession.Configuration(source: source, target: target),
                    lines: lines, finish: settle))
            gate.hold(window)
            // orderBack 而不是 makeKeyAndOrderFront:窗口要进视图层级(否则 task 不跑),
            // 但绝不能抢用户正在操作的那个 App 的焦点。
            window.orderBack(nil)

            // 兜底:翻译框架不回调(语言包状态突变、机型不支持等)时也必须让进程走完,
            // 别把调用方吊死在读 stdout 上。
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { settle(nil, "timeout") }
        }
    }
#endif

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
            guard #available(macOS 15.0, *) else {
                // Translation 框架本身就是 macOS 15.0 起,14 上连类型都没有(弱链接,符号为
                // null)—— 这条路走不通,让调用方退回网络翻译。
                emit(Output(ok: false, source: sourceCode, reason: "needs-macos-15"))
            }
            let source = Locale.Language(identifier: sourceCode)
            let target = Locale.Language(identifier: input.target)

            let status = await LanguageAvailability().status(from: source, to: target)
            guard status == .installed else {
                // supported = 系统支持但语言包没下载。这里不擅自触发下载:那会弹系统 UI,
                // 而这是个被后台采集器调起来的无界面进程,弹窗会没头没尾地打断用户。
                // 交给调用方(最终是设置页里一个显式的"下载语言包"入口)。
                //
                // 这道闸是下面两条路共同的前置条件,不能只挡 26 那条:macOS 15 那条走的
                // `.translationTask` 撞上没装的语言包同样会弹下载 UI。
                emit(Output(ok: false, source: sourceCode, reason: "\(status)"))
            }
            if #available(macOS 26.0, *) {
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
            } else {
                let outcome = await translateOnMacOS15(
                    source: source, target: target, lines: input.lines)
                guard let translated = outcome.lines else {
                    emit(Output(ok: false, source: sourceCode, reason: outcome.reason))
                }
                emit(Output(ok: true, source: sourceCode, lines: translated))
            }
        #else
            emit(Output(ok: false, source: sourceCode, reason: "no-translation-framework"))
        #endif
    }
}
