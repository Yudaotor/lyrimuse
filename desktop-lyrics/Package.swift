// swift-tools-version:5.9
import PackageDescription

// 这台机器只装了 Command Line Tools、没有完整 Xcode——XCTest/Testing 两个测试框架都
// 用不了(swift test 会报 "no such module")。DesktopLyricsCore 拆成独立 library target
// 装纯逻辑(歌词解析/数据模型/网络/进度外推),desktop-lyrics-selftest 是个普通可执行
// target,用 assert 风格的手写小断言跑合成字符串测试,不依赖任何测试框架。
let package = Package(
    name: "desktop-lyrics",
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
            path: "Sources/desktop-lyrics"
        ),
        .executableTarget(
            name: "desktop-lyrics-selftest",
            dependencies: ["DesktopLyricsCore"],
            path: "Sources/desktop-lyrics-selftest"
        ),
    ]
)
