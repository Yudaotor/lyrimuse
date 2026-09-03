// swift-tools-version:5.9
import PackageDescription

// 这台机器只装了 Command Line Tools、没有完整 Xcode——XCTest/Testing 两个测试框架都
// 用不了(swift test 会报 "no such module")。LyrimuseCore 拆成独立 library target
// 装纯逻辑(歌词解析/数据模型/网络/进度外推),lyrimuse-selftest 是个普通可执行
// target,用 assert 风格的手写小断言跑合成字符串测试,不依赖任何测试框架。
let package = Package(
    name: "lyrimuse",
    // 2026-07-18 加多语言支持:defaultLocalization 是 SwiftPM 处理 .lproj 资源的硬性
    // 要求(不设的话打包本地化资源会直接报错)。这不代表真的用系统自带的"按语言自动选
    // 资源"机制——真机实测坐实:这台没装 Xcode 的机器上,SwiftPM 打包 .lproj 资源时会把
    // 目录名强制转小写(zh-Hans.lproj → zh-hans.lproj),这会让 Bundle.preferredLocalizations
    // 的自动协商机制失效(不管系统语言/AppleLanguages 传什么,一律只认到 en)。实际的语言
    // 选择改由 lyrimuse/L10n.swift 自己读 Locale.preferredLanguages 手动判断+
    // 手动定位对应 .lproj 目录,详见那个文件的注释。
    defaultLocalization: "zh-Hans",
    // MenuBarExtra 需要 13+;这里定 14 是为了用 SettingsLink(macOS 14 起才有,更干净的
    // "打开设置窗口"写法,不用 sendAction(Selector(...)) 那种旧写法)——这台机器的真实
    // 系统版本远新于14,不构成实际限制。
    platforms: [.macOS(.v14)],
    // 2026-07-18 加全局快捷键功能引入的第一个外部依赖——之前一直零依赖(唯一先例是
    // gocc/OpenCC,也是用户明确点头才加)。全局热键注册涉及 Carbon RegisterEventHotKey
    // 这类底层 API,冲突检测/持久化/录制 UI 手写工程量和出错空间都远大于直接用这个
    // 业界公认的标准库——调研过的同类项目里,能确认具体实现的全都在用这个库或它的
    // Objective-C 前身(MASShortcut)。
    //
    // 钉死 1.15.0,不是最新版:实测坐实——3.0.x 用了 SwiftUI 的 @Entry 宏
    // (`ConflictPolicy.swift` 的 environment key),2.2.4/2.4.0 都在 `Recorder.swift`
    // 末尾预览代码块里用了 #Preview 宏,这两个宏各自的 plugin(`SwiftUIMacros.
    // EntryMacro`/`PreviewsMacros.SwiftUIView`)在这台只装 Command Line Tools、没有
    // 完整 Xcode 的机器上都解析不到,`swift build` 会直接报错退出(这个项目其它地方
    // 也反复踩过同一类"没有完整 Xcode 就是不行"的坑,比如 XCTest/Testing 两个框架都
    // 用不了)。用 GitHub API 逐版本核对源码树第一次判断错了(`gh api .../contents`
    // 对个别文件静默返回空内容,被 `2>/dev/null` 吞掉、误判成"没用到")——改成把仓库
    // 真正 clone 到本地、逐个 tag 实际 checkout 后 grep,这才是可信的核对方式。
    // 1.15.0(2023-09 发布,`swift-tools-version:5.7`)是两个宏都确认没用到的最新版,
    // `swift build` 在这台机器上跑通了整个 build 过程验证过(不只是 resolve 成功)。
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "1.15.0"),
        // 检查更新用——这个包本身只是把官方预编译的 Sparkle.xcframework(一个纯
        // Objective-C/C 的二进制 target,不涉及任何 Swift Macro/plugin)包装成 SPM
        // 依赖,不会重演 KeyboardShortcuts 那次"这台机器没有完整 Xcode、宏 plugin
        // 解析不了"的坑。`swift build` 不会自动把这类二进制依赖嵌入 .app bundle,
        // 需要 build.sh 手动 ditto 拷贝+签名,见那边的改动。
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4"),
    ],
    targets: [
        .target(
            name: "LyrimuseCore",
            path: "Sources/LyrimuseCore"
        ),
        .executableTarget(
            name: "lyrimuse",
            dependencies: ["LyrimuseCore", "KeyboardShortcuts", "Sparkle"],
            path: "Sources/lyrimuse",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "lyrimuse-selftest",
            dependencies: ["LyrimuseCore"],
            path: "Sources/lyrimuse-selftest"
        ),
        // 端上歌词翻译小助手。单独一个可执行文件而不是并进 App:调用方是 Go 写的
        // collector,它没法调 Apple 的 Translation 框架,只能起一个子进程 —— 跟已有的
        // media-control 同一个形态。见 Sources/lyrics-translate/main.swift 顶部注释。
        .executableTarget(
            name: "lyrics-translate",
            path: "Sources/lyrics-translate"
        ),
        // 罗马音预生成小助手。理由跟 lyrics-translate 一模一样:调用方是 Go 写的 collector,
        // 而日文读音必须走 CFStringTokenizer 形态分析、中韩走 ICU,都是 Apple 系统能力,
        // Go 里没有对应物。见 Sources/lyrics-romanize/main.swift 顶部注释。
        //
        // ⚠️ 它**依赖 LyrimuseCore**(lyrics-translate 不依赖)—— 读音本体必须跟 App 播放时
        // 的客户端兜底走同一个 `Romanizer.lineReading`,不能照抄一份。
        .executableTarget(
            name: "lyrics-romanize",
            dependencies: ["LyrimuseCore"],
            path: "Sources/lyrics-romanize"
        ),
    ]
)
