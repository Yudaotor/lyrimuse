// swift-tools-version:5.9
import PackageDescription

// 这台机器只装了 Command Line Tools、没有完整 Xcode——XCTest/Testing 两个测试框架都
// 用不了(swift test 会报 "no such module")。DesktopLyricsCore 拆成独立 library target
// 装纯逻辑(歌词解析/数据模型/网络/进度外推),desktop-lyrics-selftest 是个普通可执行
// target,用 assert 风格的手写小断言跑合成字符串测试,不依赖任何测试框架。
let package = Package(
    name: "desktop-lyrics",
    // 2026-07-18 加多语言支持:defaultLocalization 是 SwiftPM 处理 .lproj 资源的硬性
    // 要求(不设的话打包本地化资源会直接报错)。这不代表真的用系统自带的"按语言自动选
    // 资源"机制——真机实测坐实:这台没装 Xcode 的机器上,SwiftPM 打包 .lproj 资源时会把
    // 目录名强制转小写(zh-Hans.lproj → zh-hans.lproj),这会让 Bundle.preferredLocalizations
    // 的自动协商机制失效(不管系统语言/AppleLanguages 传什么,一律只认到 en)。实际的语言
    // 选择改由 desktop-lyrics/L10n.swift 自己读 Locale.preferredLanguages 手动判断+
    // 手动定位对应 .lproj 目录,详见那个文件的注释。
    defaultLocalization: "zh-Hans",
    // MenuBarExtra 需要 13+;这里定 14 是为了用 SettingsLink(macOS 14 起才有,更干净的
    // "打开设置窗口"写法,不用 sendAction(Selector(...)) 那种旧写法)——这台机器的真实
    // 系统版本远新于14,不构成实际限制。
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "DesktopLyricsCore",
            path: "Sources/DesktopLyricsCore"
        ),
        .executableTarget(
            name: "desktop-lyrics",
            dependencies: ["DesktopLyricsCore"],
            path: "Sources/desktop-lyrics",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "desktop-lyrics-selftest",
            dependencies: ["DesktopLyricsCore"],
            path: "Sources/desktop-lyrics-selftest"
        ),
    ]
)
