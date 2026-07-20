# Lyrimuse（desktop-lyrics）

原生 macOS 菜单栏 + 悬浮歌词窗口，跟着 Apple Music 播放实时显示逐字同步歌词，显示成一个
常驻置顶、跨 Space 的小悬浮窗——类似网易云/QQ音乐桌面客户端的"桌面歌词"。另外还有一个
"歌词管理"窗口，可以查看/手改/删除/重新搜索每首歌的歌词候选。

两种数据源（菜单栏"设置…"里切换）：

- **本地模式（默认）**：零网络，直接读这台 Mac 本地的 media-control（当前播放）+
  `../collector/` 采集器写在磁盘上的歌词/封面缓存。要让悬浮窗真的显示出歌词，需要先把
  仓库根目录的 `collector/` 采集器跑起来（见根 [README.md](../README.md)）——它负责联网
  查歌词/封面并写进这份本地缓存，desktop-lyrics 自己不联网找歌词。没有缓存时会正常显示
  "暂无歌词"，不会报错。
- **中继模式（relay）**：跟网页版一样读某个 `state-worker` 的 `/now` 接口，用于跨设备/
  跨房间同步（比如手机上也能看）。需要在设置里自己填 `state-worker` 的地址，不填会用一个
  默认示例地址（这个项目作者自己部署的 `np.yudaotor.me`，仅供体验效果，不代表你自己的
  播放数据）。

## 依赖与运行方式

- 只需要 Swift 工具链（Command Line Tools 自带即可，不需要装完整 Xcode——已实测确认，
  `Package.swift` 用的是纯 SwiftPM 可执行 target，不是 `.xcodeproj`）。
- 打包成正经的 `.app`（2026-07-18 起）：`build.sh` 把 release 构建的可执行文件+图标+
  `Info.plist` 组装安装到 `/Applications/Lyrimuse.app`，可以拖进 Dock 当启动器双击打开。`Info.plist`
  里仍然设 `LSUIElement`，运行期间照旧不占 Dock/Cmd-Tab（跟改造前的 `NSApp.
  setActivationPolicy(.accessory)` 运行时调用双保险）。SwiftPM 给每个声明了 `resources`
  的 target 生成的 `Bundle.module` 资源包（本地化文案等）按访问器的固定查找路径搬到了
  `.app` 包根目录，不是常见的 `Contents/Resources/`，细节见 `build.sh` 里的注释。

## 目录结构

- `Sources/DesktopLyricsCore/` —— 纯逻辑 library target（歌词解析/网络/进度外推/数据模型），
  不依赖 AppKit/SwiftUI，方便脱离 GUI 单独测试。
- `Sources/desktop-lyrics/` —— App 本体（菜单栏、悬浮窗、设置面板、开机启动管理）。
- `Sources/desktop-lyrics-selftest/` —— 手写的极简断言测试(`swift run desktop-lyrics-selftest`)。
  **这台机器没有完整 Xcode，`XCTest`/`Testing` 两个官方测试框架都用不了**(`swift test` 报
  "no such module")，所以用普通可执行 target + 手写比较代替。

## 构建 / 运行

```bash
./build.sh              # release 构建 + 打包安装到 /Applications/Lyrimuse.app + 重启(如果当前有实例在跑)
./build.sh --no-restart  # 只构建
swift run desktop-lyrics-selftest   # 跑歌词解析器的合成字符串测试
```

## 开机启动

菜单栏里的"开机启动"开关会把一份 LaunchAgent plist 装到 `~/Library/LaunchAgents/` 并
`launchctl bootstrap`（`launchd/` 目录下那份是留档参考，不是给人手动 `cp` 过去用的）。
故意不用 `KeepAlive`——这是用户会主动 Cmd-Q 退出的前台 GUI 工具，不是无人值守后台服务，
`KeepAlive=true` 会导致退出后立刻被拉起，体验是错的。打包成 `.app` 之后其实已经满足
`SMAppService` 的前提（plist 放 `Contents/Library/LaunchAgents/`），但沿用已经跑得好好
的经典 LaunchAgent 方案，没有顺带迁移。
