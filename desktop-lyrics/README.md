# desktop-lyrics

原生 macOS 菜单栏 + 悬浮歌词窗口，把 `state-worker` 的 `/now` 接口（跟网页版同一个数据源）
拿到的实时播放状态 + 同步歌词，显示成一个常驻置顶、跨 Space 的小悬浮窗——类似网易云/QQ音乐
桌面客户端的"桌面歌词"。跟 `collector`（Go）完全独立，不改动、不依赖它的任何本地文件，
纯粹作为 `/now` 的又一个消费者。

## 依赖与运行方式

- 只需要 Swift 工具链（Command Line Tools 自带即可，不需要装完整 Xcode——已实测确认，
  `Package.swift` 用的是纯 SwiftPM 可执行 target，不是 `.xcodeproj`）。
- 零配置默认可跑：relay 地址写死指向这个项目自己的 `https://np.yudaotor.me`，`/now` 本身
  不需要 `?user=` 参数（用户名早写死在 Worker 环境变量里）。想改地址在菜单栏"设置…"里改。
- 不打包成 `.app`：裸可执行文件靠运行时 `NSApp.setActivationPolicy(.accessory)` 就能表现成
  菜单栏专属应用（不占 Dock/Cmd-Tab），`UserDefaults`/`swift build` 的 ad-hoc 签名对裸可执行
  文件也都工作正常，都已实测确认。

## 目录结构

- `Sources/DesktopLyricsCore/` —— 纯逻辑 library target（歌词解析/网络/进度外推/数据模型），
  不依赖 AppKit/SwiftUI，方便脱离 GUI 单独测试。
- `Sources/desktop-lyrics/` —— App 本体（菜单栏、悬浮窗、设置面板、开机启动管理）。
- `Sources/desktop-lyrics-selftest/` —— 手写的极简断言测试(`swift run desktop-lyrics-selftest`)。
  **这台机器没有完整 Xcode，`XCTest`/`Testing` 两个官方测试框架都用不了**(`swift test` 报
  "no such module")，所以用普通可执行 target + 手写比较代替。

## 构建 / 运行

```bash
./build.sh              # release 构建 + 装到 ../bin/desktop-lyrics + 重启(如果当前有实例在跑)
./build.sh --no-restart  # 只构建
swift run desktop-lyrics-selftest   # 跑歌词解析器的合成字符串测试
```

## 开机启动

菜单栏里的"开机启动"开关会把一份 LaunchAgent plist 装到 `~/Library/LaunchAgents/` 并
`launchctl bootstrap`（`launchd/` 目录下那份是留档参考，不是给人手动 `cp` 过去用的）。
故意不用 `KeepAlive`——这是用户会主动 Cmd-Q 退出的前台 GUI 工具，不是无人值守后台服务，
`KeepAlive=true` 会导致退出后立刻被拉起，体验是错的。也不用 `SMAppService`，那个要求
plist 必须放进 `.app` 包内部，跟"不打包"的决定冲突。
