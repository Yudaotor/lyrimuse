# Lyrimuse

原生 macOS 菜单栏 + 悬浮歌词窗口，跟着 Apple Music、QQ 音乐、网易云音乐或 Spotify 播放实时
显示逐字同步歌词（也可以选"自动识别"，跟随 macOS 当前系统级 Now Playing 焦点），显示成一个
常驻置顶、跨 Space 的小悬浮窗、灵动岛胶囊，或者一个正经的可缩放"歌词窗口"——类似网易云/
QQ音乐桌面客户端的"桌面歌词"。另外还有一个"歌词管理"窗口，可以查看/手改/删除/重新搜索每
首歌的歌词候选。

数据完全本地读取，零网络：直接读这台 Mac 上播放器的当前状态（Apple Music 走 AppleScript，
需要一次「自动化」权限授权；QQ 音乐/网易云音乐/Spotify 都没有可用的 AppleScript 支持，
统一改走系统级 MediaRemote，不需要任何权限，见下面"依赖"）+ `../lyrimuse-collector/` 采集器
写在磁盘上的歌词/封面缓存。用哪个播放器是首次启动引导（或随时在设置里）的一个显式选择，
默认 Apple Music。这个采集器现在
打包进 `.app` 里（`build.sh` 会一并 `go build` 一份塞进 `Contents/Resources/collector`），
常驻运行靠 `CollectorServiceManager.swift` 管理的 LaunchAgent——同样在首次启动引导时开启，
或随时去设置的"通用"tab 里装/卸。它负责联网查歌词/封面并写进这份本地缓存，Lyrimuse 自己
不联网找歌词。没有缓存时会正常显示"暂无歌词"，不会报错。

如果想要跨设备/跨房间同步展示（比如手机上也能看当前播放），或者想把"正在播放"做成一个
公开网页/飞书卡片分享出去，见独立仓库
[Yudaotor/nowplaying-workers](https://github.com/Yudaotor/nowplaying-workers)——那是一套
完全独立、可选的功能，Lyrimuse 只负责单向推送状态给它，不依赖它也能正常显示悬浮歌词。

## 依赖与运行方式

- Swift 工具链（Command Line Tools 自带即可，不需要装完整 Xcode——已实测确认，
  `Package.swift` 用的是纯 SwiftPM 可执行 target，不是 `.xcodeproj`）。
- 2026-07-21 起 `build.sh` 还会额外 `go build` 一份 `../lyrimuse-collector`（`GOTOOLCHAIN=
  go1.24.4`，原因见 `lyrimuse-collector/build.sh` 顶部注释）塞进 `.app` 包里，所以也需要
  本机装了 Go 工具链——这样 collector 不再要求用户单独构建/手动装 LaunchAgent，App 自己
  的 `CollectorServiceManager.swift` 就能装/卸它（见首次启动引导，或设置的"通用"tab）。
- 2026-07-24 起，构建 QQ 音乐/网易云音乐/Spotify/自动识别这几个播放源的支持需要
  [ungive/media-control](https://github.com/ungive/media-control)（BSD-3-Clause，这几个
  播放源统一走它读取系统级 MediaRemote，不是各自独立集成）——`build.sh` 会把这份二进制
  拷进 `.app` 包（`Contents/Resources/media-control`），最终用户不需要自己装任何东西。
  **不需要提前手动 `brew install media-control`**：2026-07-27 起 `build.sh` 检测到本机
  没装会自动装一次（前提是本机已经装了 Homebrew——Go 工具链那条已经要求了）；如果自动
  安装失败（没网/没装 Homebrew 本身），会打个警告继续构建，只是这次构建出来的 App
  不支持切换到这几个播放源（Apple Music 不受影响）。
- 打包成正经的 `.app`（2026-07-18 起）：`build.sh` 把 release 构建的可执行文件+图标+
  `Info.plist`+collector 二进制组装安装到 `/Applications/Lyrimuse.app`，可以拖进 Dock 当
  启动器双击打开。`Info.plist` 里仍然设 `LSUIElement`，运行期间照旧不占 Dock/Cmd-Tab（跟
  改造前的 `NSApp.setActivationPolicy(.accessory)` 运行时调用双保险）。SwiftPM 给每个
  声明了 `resources` 的 target 生成的 `Bundle.module` 资源包（本地化文案等）按访问器的
  固定查找路径搬到了 `.app` 包根目录，不是常见的 `Contents/Resources/`，细节见 `build.sh`
  里的注释。

## 目录结构

- `Sources/LyrimuseCore/` —— 纯逻辑 library target（歌词解析/网络/进度外推/数据模型），
  不依赖 AppKit/SwiftUI，方便脱离 GUI 单独测试。
- `Sources/lyrimuse/` —— App 本体（菜单栏、悬浮窗、设置面板、开机启动管理）。
- `Sources/lyrimuse-selftest/` —— 手写的极简断言测试(`swift run lyrimuse-selftest`)。
  **这台机器没有完整 Xcode，`XCTest`/`Testing` 两个官方测试框架都用不了**(`swift test` 报
  "no such module")，所以用普通可执行 target + 手写比较代替。

## 构建 / 运行

```bash
./build.sh              # release 构建 + 打包安装到 /Applications/Lyrimuse.app + 重启(如果当前有实例在跑)
./build.sh --no-restart  # 只构建
swift run lyrimuse-selftest   # 跑歌词解析器的合成字符串测试
```

## 开机启动

菜单栏里的"开机启动"开关会把一份 LaunchAgent plist 装到 `~/Library/LaunchAgents/` 并
`launchctl bootstrap`（`LoginItemManager.swift` 里现场生成，不依赖仓库里任何模板文件）。
故意不用 `KeepAlive`——这是用户会主动 Cmd-Q 退出的前台 GUI 工具，不是无人值守后台服务，
`KeepAlive=true` 会导致退出后立刻被拉起，体验是错的。打包成 `.app` 之后其实已经满足
`SMAppService` 的前提（plist 放 `Contents/Library/LaunchAgents/`），但沿用已经跑得好好
的经典 LaunchAgent 方案，没有顺带迁移。
