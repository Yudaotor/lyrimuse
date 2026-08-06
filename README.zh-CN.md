<div align="center">

<img src="docs/images/app-icon.png" width="120" alt="Lyrimuse 图标">

# Lyrimuse

**跟着 Apple Music、QQ 音乐、网易云音乐或 Spotify 播放，在 Mac 桌面上实时显示逐字同步歌词。**

**语言 / Language:** [English](README.md) | **简体中文**

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Architecture](https://img.shields.io/badge/arch-Apple%20Silicon%20%2B%20Intel-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![No Apple Developer account needed](https://img.shields.io/badge/Apple%20Developer%20account-not%20required-success)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

</div>

Lyrimuse 常驻在菜单栏里，跟着当前播放弹出一个悬浮歌词窗口——Apple Music、QQ 音乐、网易云音乐或 Spotify，你自己选（也可以交给自动识别）——逐字同步、常驻置顶、跨 Space 显示。就是网易云音乐桌面客户端那种"桌面歌词"体验，只不过是原生 macOS 版本。

<div align="center">

<img src="docs/images/app-desktop-lyrics.png" width="420" alt="经典桌面悬浮歌词"><br>
<sub>经典悬浮窗</sub>

<img src="docs/images/app-dynamic-island.png" width="420" alt="灵动岛样式歌词"><br>
<sub>灵动岛样式胶囊（没有物理刘海也能用）</sub>

</div>

## 功能特性

### 歌词，做到位
- **逐字同步高亮**，跟随播放进度实时显示
- **自动查五个歌词源**——网易云音乐、QQ 音乐、酷狗、Musixmatch、LRCLIB——自动挑出最合适的一份，不用自己动手搜
- **罗马音 + 翻译**，跟原文一起显示——Musixmatch 来源如果有社区翻译，译文语言可以自选
- **完整的「歌词管理」窗口**——浏览、手改、删除、重新搜索任意一首歌的歌词，遇到不同步还能单独调整这首歌的时间轴偏移
- **本地模式完全离线**——已经缓存好的歌词不需要联网也能显示

### 想怎么看，你说了算
- **自选播放器，或者交给自动识别**：读 Apple Music（走「自动化」权限）、QQ 音乐、网易云音乐或 Spotify（都走 macOS 系统级 MediaRemote，不需要任何权限）的播放状态——首次启动引导选一次，之后随时在设置里切换，也可以直接留在自动识别，跟随 macOS 当前系统级 Now Playing 焦点
- **三种展示方式**：经典桌面悬浮窗、贴着屏幕顶部刘海的灵动岛胶囊（可选背景跟随专辑封面模糊显示），或者一个正经的可缩放「歌词窗口」——展示完整歌词并自动滚动到当前行——任意组合开启，或者都不开
- **菜单栏文字模式**——不想要悬浮窗，直接在状态栏看当前这一行歌词
- **悬浮窗自带播放控制**（播放/暂停、上一首、下一首），跟你选的播放器一致生效
- **默认点击穿透，长按才能拖动**——经典悬浮窗不会挡住你点它下面的内容；长按住不放可以拖动位置，也可以在菜单栏里把位置整个锁定
- **外观完全自定义**：字体（也可以跟随系统）、字号、文字/背景/阴影颜色（可以存成配色主题反复用）、悬浮窗宽度
- **截屏/录屏/共享屏幕时自动隐藏**——只有你自己在这台 Mac 上还能看见
- **暂停时自动收起**，不会占着桌面空转

### 一个懂事的 Mac 应用该有的样子
- **中英文界面**，切换立即生效，不用重启
- **全局快捷键**，覆盖每一个常用动作，默认都不绑定任何按键，交给你自己决定
- **只待在菜单栏里**，不占 Dock（想显示在 Dock 里也可以在设置里打开）
- **自动检查更新**（也可以随时在菜单栏里手动检查）——不用自己老回 Releases 页面看
- **同步播放记录到 Last.fm**，在主设置的"账号"分类里一键连接，不用自己手动换 token
- **可选的双向联动启动**，跟你选的播放器之间——打开一个的时候顺带拉起另一个
- **导出/导入完整配置**，方便换到新 Mac；还有一键导出诊断信息，方便排查问题

### 附加功能（可选）
以下全部默认关闭、按需开启，都在设置里配置：

- **再同步到 [ListenBrainz](https://listenbrainz.org)**——跟 Last.fm 一起连上，每次播放都会从同一份实时读取到的播放状态分别提交给两边，两份记录不会互相走样、对不上；iPhone 上经 Last.fm 记录的播放也会自动转发进 ListenBrainz，让 Mac 和 iPhone 的收听记录合并成一份完整历史，而不是各自分开的两份
- **一个可以到处分享的"正在听什么"网页**——实时播放状态、历史播放、留言墙、表情反应、访客计数、历史 Top10 歌手榜单、黑胶唱片视觉效果、深浅色主题，分享到聊天工具里还会自动展开预览卡片。完整效果展示 + 从零搭建教程见 **[网页玩法教程](https://github.com/Yudaotor/nowplaying-workers#readme)**。
- **每周听歌小结**，通过推送通知发给你（支持 Bark、钉钉、企业微信、Discord、飞书、Server酱）

以上每一项都在设置的「附加功能」里配置，每张账号卡片自带完整的分步引导——去哪申请 API Key/Token、怎么连接账号、怎么给选定的推送平台拿到 Webhook 地址，点开对应卡片就有。网页展示页是唯一单独写了一份教程、而不是塞进设置里一个小弹窗的，但这不代表它是硬性前提——光配好 ListenBrainz，网页就已经能显示实时播放和历史，不需要部署任何 Cloudflare Worker。额外部署一份能加上留言墙、表情反应、访客计数、Top10 歌手榜单，以及延迟更低的更新，想要这些再看教程。

## 快速开始

Lyrimuse 一直都是 ad-hoc 签名——不管用下面哪种方式拿到，都不涉及 Apple 开发者账号。也因为这样，除了下面的方案 A（会自动清掉这一步），其它方式第一次打开时 Gatekeeper 都会提示"来自身份不明的开发者"——这是预期行为，不是 bug，方案 B 里有一次性手动解决办法。

### 方案 A：用 Homebrew 安装（推荐）

```bash
brew tap yudaotor/lyrimuse
brew trust --cask yudaotor/lyrimuse/lyrimuse   # 一次性操作——Homebrew 要求任何非官方 tap 都得先信任
brew install --cask lyrimuse
```

安装过程中会自动清掉这次的 Gatekeeper 隔离标记，不需要额外操作——`brew install` 跑完直接从 `/Applications`（或者 Spotlight）打开 Lyrimuse 就行。以后有新版本，`brew upgrade --cask lyrimuse` 同样能自动处理。

### 方案 B：手动下载预编译版本

1. 去 [Releases 页面](https://github.com/Yudaotor/lyrimuse/releases) 下载，两种格式随你挑，装出来是同一个 App（同一次构建打的两份包），都是 universal（Apple Silicon 和 Intel 两份都在里面），不用挑架构：

   - `Lyrimuse-*-macos.dmg` —— 双击挂载，把 `Lyrimuse.app` 拖到旁边的 `Applications` 上。
   - `Lyrimuse-*-macos.zip` —— 解压后把 `Lyrimuse.app` 拖进 `/Applications`。附带一份 `.sha256`，想核对下载完整性的话在同一目录里跑 `shasum -c Lyrimuse-*-macos.zip.sha256`。这也是 Homebrew 和 App 内自动更新用的那一份。
2. 第一次打开时 macOS 会拒绝运行——提示"Lyrimuse 已损坏，无法打开"或"来自身份不明的开发者"。用下面任意一种方式解锁一次即可：

   - **推荐——终端命令（永远有效）：**
     ```bash
     xattr -dr com.apple.quarantine /Applications/Lyrimuse.app
     ```
     然后正常打开即可，每份下载只需要做一次。
   - **右键 → 打开：** 在 Finder 里右键（或 Control-点击）`Lyrimuse.app`，选择"打开"，弹窗里再确认一次"打开"。不是每个 macOS 版本、每种提示都能用这招，不行的话回退用上面的终端命令。
   - **系统设置 → 隐私与安全性：** 先试着打开一次（会被拦下），再打开**系统设置 → 隐私与安全性**，滚到最底部，点 Lyrimuse 警告旁边的"仍要打开"，弹窗里再确认一次。

   只对你真正信任的构建版本执行这几条命令——比如这个仓库自己 Releases 页面下的，或者你自己构建的那份。

### 方案 C：自己构建

**一次性前置依赖**（已经装过的可以跳过）：

```bash
xcode-select --install   # Xcode 的 Command Line Tools，跑 Swift 用——`swift --version` 能跑就说明已经装过
brew install go          # 任意 ≥1.21 的 Go 都行——build.sh 会通过 GOTOOLCHAIN 自动切到 1.24.4
```

装好之后，`build.sh` 会一次性把 App 和它的后台采集器都构建好：

```bash
git clone https://github.com/Yudaotor/lyrimuse.git
cd lyrimuse/lyrimuse
./build.sh                # 默认出 universal 包(arm64 + x86_64)
./build.sh --host-only    # 只编当前这台机器的架构,本地反复迭代时快一半
```

`build.sh` 最后会把包里每个二进制的架构列出来，缺哪一半会直接报出来——发布包用默认（universal）那条路。

QQ 音乐/网易云音乐/Spotify/自动识别这几个播放源支持额外需要 [ungive/media-control](https://github.com/ungive/media-control)——本机没装的话 `build.sh` 会自动用 Homebrew 装一次，这一步也不需要你自己动手。

### 不管选哪种方案

从 `/Applications` 打开 Lyrimuse——首次启动的引导向导会带你完成：选一个播放器（Apple Music、QQ 音乐、网易云音乐、Spotify，或者自动识别），选了 Apple Music 的话再允许它以「自动化」方式读取 Music.app 当前播放的歌曲信息（其它几个都不需要额外权限），以及启用它的后台常驻采集服务（这样就算把窗口关掉，歌词/封面也会持续解析）。走完引导歌词马上就会显示出来（更多构建选项见 [lyrimuse/README.md](lyrimuse/README.md)）。

不需要再配置任何其它东西才能看到歌词——上面提到的所有附加功能都是后续在设置里按需开启的。

## 项目结构

本仓库就是 App 本身：

- [`lyrimuse/`](lyrimuse) —— App 本体（Swift，SwiftUI + AppKit）
- [`lyrimuse-collector/`](lyrimuse-collector) —— 后台引擎，负责解析歌词/封面并喂给 App（Go）；构建时自动打包进 App

可选的网页体验拆在两个独立的兄弟仓库里，想 fork 哪个都不用碰 App：

| 仓库 | 角色 |
|---|---|
| [`Yudaotor/nowplaying`](https://github.com/Yudaotor/nowplaying) | 可分享的"正在听什么"网页本体，外带一份可直接 fork 的模板 |
| [`Yudaotor/nowplaying-workers`](https://github.com/Yudaotor/nowplaying-workers) | 网页背后的 Cloudflare Worker 中继 + 实时 README 徽章，配完整的从零搭建教程 |

```
本仓库 (App + 采集器)  ──推送──▶  nowplaying-workers (中继)  ◀──读取──  nowplaying (网页)
```

## 致谢

灵动岛样式悬浮歌词窗口的设计和技术思路参考了 [boring.notch](https://github.com/TheBoredTeam/boring.notch)、[NotchDrop](https://github.com/Lakr233/NotchDrop) 和 [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit)；桌面歌词这个概念本身则要归功于 [LyricsX](https://github.com/ddddxxx/LyricsX)。
