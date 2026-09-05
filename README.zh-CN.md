<div align="center">

<img src="docs/images/app-icon.png" width="120" alt="Lyrimuse 图标">

# Lyrimuse

**跟着 Apple Music、QQ 音乐、网易云音乐、酷狗音乐、Spotify，或浏览器里的网页版 YouTube Music / Spotify 播放，在 Mac 桌面上实时显示逐字同步歌词——外加 Last.fm 听歌档案和端上机器翻译。**

**语言 / Language:** [English](README.md) | **简体中文** | [繁體中文](README.zh-Hant.md)

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Architecture](https://img.shields.io/badge/arch-Apple%20Silicon%20%2B%20Intel-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![No Apple Developer account needed](https://img.shields.io/badge/Apple%20Developer%20account-not%20required-success)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

</div>

Lyrimuse 常驻在菜单栏里，跟着当前播放弹出一个悬浮歌词窗口——Apple Music、QQ 音乐、网易云音乐、酷狗音乐、Spotify，以及浏览器里的网页版 YouTube Music / Spotify，任选几个组合（也可以交给自动识别）——逐字同步、常驻置顶、跨 Space 显示。就是网易云音乐桌面客户端那种"桌面歌词"体验，只不过是原生 macOS 版本。

**从 LyricsX 过来的？** LyricsX 自 2022 年 4 月起再没发过新版本。Lyrimuse 是一个持续维护的开源替代，还额外覆盖 QQ 音乐 / 网易云 / 酷狗和浏览器网页播放器——这里有一份逐项核实过的[与 LyricsX、Lyric Fever 的对比](docs/lyrics-apps-comparison.zh-CN.md)。

**安装：** `brew tap yudaotor/lyrimuse && brew install --cask lyrimuse`（Apple Silicon 与 Intel 都支持；自动清掉一次性的 Gatekeeper 拦截）——或者去 [最新 Release](https://github.com/Yudaotor/lyrimuse/releases/latest) 手动下载，详见[快速开始](#快速开始)。

<table>
<tr>
<td align="center" width="33%"><img src="docs/images/app-desktop-lyrics.png" width="260" alt="经典桌面悬浮歌词"><br><sub>经典悬浮窗</sub></td>
<td align="center" width="33%"><img src="docs/images/app-dynamic-island.png" width="260" alt="灵动岛样式歌词，播放中"><br><img src="docs/images/app-dynamic-island-paused.png" width="260" alt="灵动岛样式歌词，暂停中"><br><sub>灵动岛样式胶囊（没有物理刘海也能用）——悬停展开完整卡片，暂停收成一个胶囊</sub></td>
<td align="center" width="33%"><img src="docs/images/app-menu-bar-lyrics.png" width="260" alt="菜单栏歌词"><br><sub>菜单栏文字模式，带卡拉OK式染色</sub></td>
</tr>
</table>

<table>
<tr>
<td align="center" width="50%"><img src="docs/images/app-lyrics-window.png" width="380" alt="歌词窗口"><br><sub>歌词窗口，仿 Apple Music 歌词页</sub></td>
<td align="center"><img src="docs/images/app-idle-standby.png" width="380" alt="歌词窗口听歌总览"><br><sub>同一个窗口，没有歌在放时的听歌总览</sub></td>
</tr>
<tr>
<td align="center"><img src="docs/images/app-lastfm-profile.png" width="380" alt="Last.fm 听歌档案"><br><sub>Last.fm 听歌档案——数字统计与最近记录</sub></td>
<td align="center"><img src="docs/images/app-lastfm-charts.png" width="380" alt="Last.fm 榜单"><br><sub>Last.fm 档案——歌手 / 专辑 / 歌曲榜单</sub></td>
</tr>
<tr>
<td colspan="2" align="center"><img src="docs/images/app-lastfm-heatmap.png" width="700" alt="播放热力图"><br><sub>播放热力图——仿 GitHub 贡献图风格的年历，取自完整的 Last.fm 收听历史</sub></td>
</tr>
<tr>
<td align="center"><img src="docs/images/app-menu-bar-dropdown.png" width="380" alt="菜单栏下拉菜单"><br><sub>菜单栏下拉菜单，什么都摸得到</sub></td>
<td align="center"><img src="docs/images/app-settings.png" width="380" alt="设置页——悬浮歌词编辑台"><br><img src="docs/images/app-settings-notch.png" width="380" alt="设置页——灵动岛编辑台"><br><sub>设置页——每种歌词形态都是一个带原尺寸实时预览的编辑台</sub></td>
</tr>
<tr>
<td align="center"><img src="docs/images/app-lyrics-manager.png" width="380" alt="歌词管理"><br><sub>歌词管理——浏览、手改、重新匹配任意一首歌的歌词</sub></td>
<td align="center"><img src="docs/images/app-lyrics-search.png" width="380" alt="搜索歌词"><br><sub>每个候选都打了分、标了来源，选错版本一眼就能看出来</sub></td>
</tr>
<tr>
<td align="center"><img src="docs/images/app-player-settings.png" width="380" alt="播放器选择"><br><sub>播放器可多选——浏览器里的网页播放器也是正经播放器</sub></td>
<td align="center"><img src="docs/images/app-resolution-decision.png" width="380" alt="解析决策"><br><sub>智能评分决策——每个候选的得分逐项讲清，赢家为什么赢一目了然</sub></td>
</tr>
</table>

## 功能特性

### 歌词，做到位
- **逐字同步高亮**，跟随播放进度实时显示
- **自动查八个歌词源**——网易云音乐、QQ 音乐、酷狗、酷我、Musixmatch、LRCLIB、LyricFind（经 YouTube Music）、AMLL（人工校对过的逐字歌词库）——自动挑出最合适的一份，不用自己动手搜
- **罗马音 + 翻译**，跟原文一起显示——歌词源自带社区翻译时优先用它，没有的话走端上机器翻译（Apple 系统翻译，歌词不出本机），翻不了再退联网兜底，译文语言可选 18 种；罗马音按行判断，中日双语歌只有日文行会标注读音，不会连中文一起标上拼音；粤语歌自动标注粤拼（按词消歧）
- **对唱/多人合唱歌词分开显示**，只要来源（或 AMLL 词条）标出了是谁在唱哪一句，就不会把两个人的声部糊成一团
- **简繁中文切换**，独立于 App 界面语言，只管歌词文字本身用哪种写法
- **完整的「歌词管理」窗口**——浏览、手改、删除、重新搜索任意一首歌的歌词，支持多选批量删除、列宽随手拖，遇到不同步还能单独调整这首歌的时间轴偏移
- **本地模式完全离线**——已经缓存好的歌词不需要联网也能显示

### 你的听歌档案
- **一份真正的听歌档案，不只是同步播放记录**——在主设置的"账号"分类里一键连接 Last.fm（不用自己手动换 token），就能看到今天/近 7 天/总量数字、一行实时的"正在记录"提示，还有带封面的实时最近播放列表。上送时**播放器报什么就发什么、原样不动**，绝不在发送前改写歌手名或歌名（[打卡规则详解](docs/scrobbling.zh-CN.md)）
- **歌手/专辑/歌曲榜单**，可按时段筛选（近 7 天/近 30 天/近一年/全部），外加「那年今日」——回顾往年这天你在听什么
- **每次播放都会先记在本地**，就算你还没连 Last.fm——之后连上，之前攒下的记录会通过补传队列自动补上
- **这份本地历史同样会出现在歌词窗口里**——没有歌在放的时候，它会变成一块听歌总览面板，而不是一片空白（下面还会细说）

### 想怎么看，你说了算
- **播放器可多选，或者交给自动识别**：读 Apple Music（走「自动化」权限）、QQ 音乐、网易云音乐、酷狗音乐或 Spotify（都走 macOS 系统级 MediaRemote，不需要任何权限）的播放状态——在设置里任意组合勾选，也可以直接留在自动识别，跟随 macOS 当前系统级 Now Playing 焦点
- **网页播放器也是正经播放器**：配对一次你常用的浏览器，网页版 YouTube Music 或 Spotify 就能当播放器用——歌词按页面自己的进度条精确同步，还有一键自检告诉你浏览器到底能不能被驱动
- **三种展示方式**：经典桌面悬浮窗、贴着屏幕顶部刘海的灵动岛胶囊（可选显示专辑封面，背景也能跟着封面模糊），或者一个仿 Apple Music 歌词页的可缩放「歌词窗口」——双栏布局、封面模糊铺底、完整歌词自动滚动到当前行——任意组合开启，或者都不开
- **菜单栏文字模式**——不想要悬浮窗，直接在状态栏看当前这一行歌词；太长的句子会横向滚动播完，而不是截成半句（想要截断也留着开关）
- **进度条拖着就能跳**——歌词窗口和灵动岛的进度条都能拖动跳转，不只是给你看进度
- **一键跳到当前歌曲的页面**——在「⋯」菜单或简介面板里点一下，Apple Music 直接在 App 内打开，QQ 音乐、网易云音乐会打开对应歌曲/专辑/歌手的网页；不用自己搜，链接是查歌词那会儿就顺手解析好的
- **没有歌在放的时候，歌词窗口会变成一块听歌总览面板**，而不是一片空白——今天/本周听了多少、「那年今日」，外加一份带封面的完整最近播放列表，点开直接跳到对应的 Apple Music 专辑/艺人页
- **外观完全自定义**：字体（也可以跟随系统）、字号、文字/背景/阴影颜色（可以存成配色主题反复用，也可以让文字颜色跟着当前专辑封面走）、悬浮窗宽度
- **截屏/录屏/共享屏幕时自动隐藏**——只有你自己在这台 Mac 上还能看见
- **暂停时自动收起**，不会占着桌面空转

### 一个懂事的 Mac 应用该有的样子
- **简体中文、繁體中文、英文界面**，切换立即生效，不用重启
- **全局快捷键**，覆盖每一个常用动作，默认都不绑定任何按键，交给你自己决定
- **自动检查更新**（也可以随时在菜单栏里手动检查）——不用自己老回 Releases 页面看
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

### 方案 0：把安装丢给 AI

如果你的 Mac 上跑着能执行终端命令的 AI 助手（Claude Code、Codex CLI、Gemini CLI 等），把下面这段话**原样**贴给它，方案 A/B 的所有步骤它都会替你做完。这段话术只允许它装这一个应用——全程不用 `sudo`，也不碰系统级安全设置：

```text
请在这台 Mac 上安装 Lyrimuse——一个开源的 macOS 菜单栏歌词应用
（https://github.com/Yudaotor/lyrimuse），严格按以下规则执行：

1. 首选路径（如果有 `brew`）：
     brew tap yudaotor/lyrimuse
     brew trust --cask yudaotor/lyrimuse/lyrimuse
     brew install --cask lyrimuse
   如果这台机器的 Homebrew 没有 trust 子命令，跳过那一行——旧版本不需要。
2. 没装 Homebrew 的话，不要替我安装 Homebrew。改走手动路径：先用 `uname -m`
   确认芯片架构，去 https://github.com/Yudaotor/lyrimuse/releases 下载最新版本
   对应的文件——arm64 下 `Lyrimuse-<版本>-macos.zip`，x86_64 下
   `Lyrimuse-<版本>-macos-intel.zip`——用同处提供的 `.sha256` 文件校验
   （`shasum -c`），解压后把 `Lyrimuse.app` 移进 /Applications，然后只对这
   一个 app 清除 Gatekeeper 隔离标记：
     xattr -dr com.apple.quarantine /Applications/Lyrimuse.app
3. 安全红线：全程不用 `sudo`（这里没有任何一步需要它）；绝不执行
   `spctl --master-disable` 或任何全局关闭 Gatekeeper 的操作；除
   /Applications/Lyrimuse.app 外不得对任何东西清除隔离标记。
4. 除非我明确要求，不要从源码构建。
5. 启动它（`open -a Lyrimuse`），并确认在运行（`pgrep -x Lyrimuse` 能打出 PID）。
6. 首次启动会弹出引导向导——那部分由我自己点：告诉我它会让我选播放器、
   （只在选 Apple Music 时）授权对 Music.app 的「自动化」访问、以及启用后台
   采集服务，然后把控制权交还给我。
最后用中文汇报你做了什么、有没有失败的步骤。
```

### 方案 A：用 Homebrew 安装（推荐）

```bash
brew tap yudaotor/lyrimuse
brew trust --cask yudaotor/lyrimuse/lyrimuse   # 一次性操作——Homebrew 要求任何非官方 tap 都得先信任
brew install --cask lyrimuse
```

安装过程中会自动清掉这次的 Gatekeeper 隔离标记，不需要额外操作——`brew install` 跑完直接从 `/Applications`（或者 Spotlight）打开 Lyrimuse 就行。以后有新版本，`brew upgrade --cask lyrimuse` 同样能自动处理。

### 方案 B：手动下载预编译版本

1. 去 [Releases 页面](https://github.com/Yudaotor/lyrimuse/releases) 下载。**先看清自己是哪种 Mac**（左上角  → 关于本机 →「芯片」：`Apple M…` 是 Apple Silicon，`Intel Core…` 是 Intel）：

   | 你的 Mac | 下这份 |
   | --- | --- |
   | Apple Silicon（M1 及以后） | `Lyrimuse-*-macos.dmg` 或 `.zip` |
   | Intel | `Lyrimuse-*-macos-intel.dmg` 或 `.zip` |

   dmg 双击挂载后把 `Lyrimuse.app` 拖到旁边的 `Applications` 上；zip 解压后把 `Lyrimuse.app` 拖进 `/Applications`。两种格式装出来完全是同一个 App，zip 还附带一份 `.sha256`，想核对下载完整性就在同一目录里跑 `shasum -c Lyrimuse-*.zip.sha256`。

   两份的区别只在架构：不带后缀的那份是纯 Apple Silicon，`-intel` 那份同时含 Intel 和 Apple Silicon 两套代码。`-intel` 也能在 Apple Silicon 上跑，但没必要——体积大一倍，而且 macOS 27 及以后会因为它含 Intel 代码而提示「需要更新 App」（Apple 要在 macOS 28 移除 Rosetta；App 本身没问题）。

   **两种架构都有 App 内自动更新。** 更新源里为同一个版本登记了两条，各自对应一种架构：Apple Silicon 收到不带后缀的那份，Intel 收到 `-intel` 那份，Sparkle 按机器自己挑，你不用管。（v1.4.0 及更早只服务 Apple Silicon，Intel 用户当时得回这个页面手动下。）

   **中国大陆下载加速：** GitHub 直连慢或超时的话，给下载地址加一个公共加速前缀即可，例如把 Releases 页复制出来的链接改成 `https://ghfast.top/https://github.com/Yudaotor/lyrimuse/releases/download/…`。镜像域名可能失效——失效就换一个可用的 gh-proxy 类前缀（用法相同，都是原链接前面加前缀），下载后照常用 `.sha256` 校验。
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
./build.sh               # 编当前这台机器的架构
./build.sh --universal   # 编 arm64 + x86_64 的 universal 包(给 Intel 用的那份兼容包)
```

`build.sh` 最后会把包里每个二进制的架构列出来，跟目标不符（缺一半、或多带了一份）都会报出来。发布资产不要手工打——用 `./package.sh`，它自己会把两种架构各构建一次、各出一套 zip + sha256 + dmg，架构不符直接拒绝打包。

QQ 音乐/网易云音乐/酷狗音乐/Spotify/自动识别这几个播放源支持额外需要 [ungive/media-control](https://github.com/ungive/media-control)——本机没装的话 `build.sh` 会自动用 Homebrew 装一次，这一步也不需要你自己动手。

### 不管选哪种方案

从 `/Applications` 打开 Lyrimuse——首次启动的引导向导会带你完成：选一个播放器（Apple Music、QQ 音乐、网易云音乐、酷狗音乐、Spotify，或者自动识别），选了 Apple Music 的话再允许它以「自动化」方式读取 Music.app 当前播放的歌曲信息（其它几个都不需要额外权限），以及启用它的后台常驻采集服务（这样就算把窗口关掉，歌词/封面也会持续解析）。走完引导歌词马上就会显示出来（更多构建选项见 [lyrimuse/README.md](lyrimuse/README.md)）。

不需要再配置任何其它东西才能看到歌词——上面提到的所有附加功能都是后续在设置里按需开启的。

## 常见问题

**装这个需要 Apple 开发者账号吗？**
不需要。Lyrimuse 一直都是 ad-hoc 签名——你不需要开发者账号，这个项目本身也没有。上面「快速开始」里那个一次性的 Gatekeeper 解锁步骤就是这个原因。

**只支持 Apple Music 吗，Spotify、QQ 音乐、网易云音乐能用吗？**
都支持，外加酷狗音乐，一共五个播放器，也可以交给自动识别，跟随 macOS 当前认为的「正在播放」。Apple Music 走「自动化」权限读取；其它四个完全不需要任何额外权限，走的是 macOS 系统级 MediaRemote。

**这跟网易云音乐自带的桌面歌词是一回事吗？**
思路一样，不是同一个 App——Lyrimuse 把「桌面悬浮歌词」这套体验带给五个播放器（不只是网易云自己的客户端），原生 macOS，还多了灵动岛样式和一个仿 Apple Music 的完整歌词窗口，不只是经典悬浮窗一种形态。

**没有网络能看歌词吗？**
一首歌的歌词只要解析过一次，之后就能——本地模式直接显示已缓存的歌词，不用联网。第一次查询（以及需要机器翻译的时候）还是要联网的。

**我的数据会传到外面吗？**
解析歌词要查公开的歌词接口（网易云、QQ、酷狗、酷我、Musixmatch、LRCLIB、LyricFind、AMLL），封面要查 iTunes Search——这是这个功能本身决定的。翻译默认走端上（Apple 系统翻译），只有退到网络翻译时才会把歌词正文发给 MyMemory。其余的——本地收听历史、缓存的歌词、设置——都只存在你 Mac 本地的文件里，除非你主动去连 Last.fm、ListenBrainz，或者那个可选的网页中继。逐项清单见下面「[许可与版权说明](#许可与版权说明)」。

**能标日语/韩语罗马音，或者翻中文吗？**
可以——罗马音按行判断（中日双语混唱的歌不会整首被判错），翻译来自歌词源自带的社区翻译，或者端上/联网机器翻译，译文语言可选 18 种。

**支持 Intel Mac 吗？**
支持，走单独的 universal 包（见上面方案 B）。**App 内自动更新对 Intel 同样生效**（v1.5.0 起），装好之后跟 Apple Silicon 一样会自己提示新版本。

**浏览器里放的 YouTube Music / Spotify 网页版能出歌词吗？**
能——在设置里把你常用的浏览器配对一次，网页版 YouTube Music 或 Spotify 就是正经播放器：歌词按页面自己的进度条精确同步（不是估算），配对前还有一键自检告诉你这个浏览器到底能不能被驱动。

**Lyrimuse 和 LyricsX、Lyric Fever 有什么区别？**
LyricsX（最后一版发布于 2022 年 4 月，支持 macOS 10.11+）覆盖 Apple Music、Spotify 等几个经典播放器；Lyric Fever 专注 Spotify + Apple Music，要求 macOS 15+。Lyrimuse（macOS 14+）额外原生支持 QQ 音乐 / 网易云音乐 / 酷狗，支持浏览器网页播放器，逐行判定的拼音 / 粤拼 / 注音假名，以及 Last.fm / ListenBrainz 打卡加本地听歌统计。逐项核实过的对照表见[对比页](docs/lyrics-apps-comparison.zh-CN.md)。

## 许可与版权说明

- **Lyrimuse 本身以 [GPL-3.0](LICENSE) 授权。** 随 App 一起分发的开源组件与词典数据（media-control、Sparkle、KeyboardShortcuts、OpenCC 与 rime-cantonese 词典）各自保留原许可证，全文见 [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES)；这个文件也打进了 App 包里，**设置 → 关于 → 第三方许可**能直接打开。
- **歌词、封面与曲目信息的版权归各自的权利人所有。** Lyrimuse 只做检索、缓存与展示：公开歌词接口返回什么，就存在你自己 Mac 上的 `~/.config/lyrimuse/` 里给你自己看，不托管、不转发、不再分发任何歌词或封面；缓存随时可以在「歌词管理」里删，或者直接删掉那个文件夹。
- **Lyrimuse 是独立的开源项目**，与 Apple、腾讯（QQ 音乐）、网易（网易云音乐）、酷狗、酷我、Spotify、Google（YouTube Music）、Last.fm、ListenBrainz、Musixmatch、LRCLIB、LyricFind、AMLL 均无隶属、合作或背书关系。这些名称和商标归各自所有者，这里提到它们只是为了说明支持哪些播放器和歌词来源。
- **会离开你 Mac 的只有这些。** 解析歌词时把歌手、歌名、专辑（部分源还带时长）发给上面八个歌词源；全部落空时还会把歌手名发给 MusicBrainz 查别名。封面与空闲页把歌手加歌名发给 iTunes Search。机翻兜底（默认关，且只在端上 Apple 翻译不可用时）会把**歌词正文**分块发给 MyMemory，附一个随机生成的邮箱参数，不是你的。Musixmatch 的域名走 DNS over HTTPS，解析请求发给 Cloudflare（1.1.1.1）和 Google（8.8.8.8）。「关于」页最多每 6 小时向 GitHub API 查一次 Star 数；检查更新只拉 GitHub Releases 上的 appcast，不上报系统信息。除此之外只有你主动连接的 Last.fm、ListenBrainz、推送平台和网页中继（中继的 Top10 歌手页会向 Deezer 查歌手头像）。每一条对外请求都记进本地审计日志（只记域名和操作名，不记参数和凭据），「导出诊断信息」里能看到。

## 排查

歌词不出来时，直接问 collector：

```sh
/Applications/Lyrimuse.app/Contents/Resources/collector healthcheck
/Applications/Lyrimuse.app/Contents/Resources/collector healthcheck -local-only  # 不联网
/Applications/Lyrimuse.app/Contents/Resources/collector healthcheck -json
```

它会检查那些**会静默地把链路搞坏**的东西——某个配置字段没解析成功、一个歌词源都没启用、
缓存文件读不了、歌词导出目录写不进去——然后拿两首真实曲目（一中一英，避免把某个曲库的
盲区误报成故障）去探当前启用的每个歌词源。单个源挂掉只报 warn，只有全部挂掉才算 error：
还有其它源照样能出歌词。

## 卸载

把 `Lyrimuse.app` 拖进废纸篓**是不够的**。后台采集服务在 launchd 里注册的是 `KeepAlive`
类型的 job，它的 LaunchAgent 会留下来，于是 launchd 会一直去启动一个已经不存在的二进制。

```sh
lyrimuse/scripts/uninstall.sh              # 只看：报告当前装了什么
lyrimuse/scripts/uninstall.sh --services   # 注销两个 launchd job，数据一律保留
lyrimuse/scripts/uninstall.sh --purge      # 连配置、缓存、日志、偏好设置一起删
```

不带参数运行不会改动任何东西，只是告诉你系统里现在有什么。`--purge` 会先把要删的东西
逐个列出来、提醒你其中有多少个已导出的歌词文件，并且要求手动输入 `yes` 才继续。

`--services` 不碰偏好设置；`--purge` 会连偏好设置一起删（`defaults delete
me.yudaotor.lyrimuse`）。留着它会把重装引向一条死路：LaunchAgent 已经删了、collector
没装，而 App 仍然认为引导走完过——于是那扇能把服务装回去的引导页永远不出现，桌面就
一直停在「搜索歌词中…」。

## 项目结构

本仓库就是 App 本身：

- [`lyrimuse/`](lyrimuse) —— App 本体（Swift，SwiftUI + AppKit）
- [`lyrimuse-collector/`](lyrimuse-collector) —— 后台引擎，负责解析歌词/封面并喂给 App（Go）；构建时自动打包进 App
- [`docs/features/`](docs/features/README.md) —— 功能现状文档：15 章覆盖每个功能的当前行为、交互点与代码锚点（改任何功能前先读对应章）

可选的网页体验拆在两个独立的兄弟仓库里，想 fork 哪个都不用碰 App：

| 仓库 | 角色 |
|---|---|
| [`Yudaotor/nowplaying`](https://github.com/Yudaotor/nowplaying) | 可分享的"正在听什么"网页本体，外带一份可直接 fork 的模板 |
| [`Yudaotor/nowplaying-workers`](https://github.com/Yudaotor/nowplaying-workers) | 网页背后的 Cloudflare Worker 中继 + 实时 README 徽章，配完整的从零搭建教程 |

```
本仓库 (App + 采集器)  ──推送──▶  nowplaying-workers (中继)  ◀──读取──  nowplaying (网页)
```

## 致谢

桌面歌词这个概念要归功于 [LyricsX](https://github.com/ddddxxx/LyricsX)。
