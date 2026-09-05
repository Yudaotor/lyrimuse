# 2026 年 macOS 桌面歌词软件对比：Lyrimuse vs LyricsX vs Lyric Fever

**语言：** [English](lyrics-apps-comparison.md) | **简体中文**

> **利益相关声明**：本页由 Lyrimuse 作者维护，请带着这一点来读。
> 下表所有事实均于 **2026-09-05** 逐项对照各项目自己的公开仓库与 README 核实；"—" 表示该项目
> 自己的公开资料中**未标称**此能力（截至核实日期），不代表一定没有。欢迎指正——
> [提 issue](https://github.com/Yudaotor/lyrimuse/issues)。

**LyricsX 还在维护吗？** 不活跃了：[LyricsX](https://github.com/ddddxxx/LyricsX) 的最后一个
发布版是 **2022 年 4 月的 v1.6.3**，仓库偶尔还有提交。搜「LyricsX 替代」的人多半是带着这个
问题来的，所以这里给一份基于事实的、当下仍在活跃维护的开源选择对比：

- **[Lyric Fever](https://github.com/aviwad/LyricFever)**（MIT）——Spotify + Apple Music
  的歌词体验，要求 macOS 15+，自称 "spiritual successor to LyricsX"。
- **[Lyrimuse](https://github.com/Yudaotor/lyrimuse)**（GPL-3.0，即本项目）——逐字同步歌词，
  除 Apple Music、Spotify 外**原生支持国内播放器（QQ 音乐、网易云音乐、酷狗）**，还支持浏览器里
  播放的 YouTube Music / Spotify 网页版；8 个歌词源自动查证；翻译、拼音/粤拼/注音假名；
  Last.fm 与 ListenBrainz 打卡（scrobble）加本地听歌统计。macOS 14+，Apple Silicon 与
  Intel 都有构建。

**OSD Lyrics 呢？** 那是 Linux 桌面歌词软件，不是 macOS 的——它常出现在「LyricsX 替代」
清单里，但在 Mac 上跑不了。

## 逐项对比（2026-09-05 核实）

| | **Lyrimuse** | **LyricsX** | **Lyric Fever** |
|---|---|---|---|
| 许可证 · 价格 | GPL-3.0 · 免费 | MPL-2.0 · 免费 | MIT · 免费 |
| 最新发布 | v1.5.0（2026-09） | v1.6.3（2022-04） | v3.3（2025-11） |
| 最低 macOS | 14（Sonoma） | 10.11 | 15（Sequoia） |
| 支持的播放器 | Apple Music、Spotify、QQ 音乐、网易云音乐、酷狗——可任意组合 | Apple Music、Spotify、Vox、Audirvana、Swinsian（经其 MusicPlayer 组件） | Spotify、Apple Music |
| 浏览器网页播放器 | YouTube Music 与 Spotify 网页版，跟随页面自身进度同步 | — | — |
| 自动查证的歌词源 | 8 个：网易云、QQ 音乐、酷狗、酷我、Musixmatch、LRCLIB、LyricFind、AMLL | 多个（经其 LyricsKit 组件） | 3 个：Spotify、LRCLIB、网易云 |
| 逐字同步 | 是，跨源支持（含人工整理的 AMLL 逐字库） | 经 LRCX 逐字时间标签，取决于源是否提供 | — |
| 翻译 | 优先源自带的社区翻译，否则设备端 Apple 翻译（18 种目标语言）+ 在线兜底 | 显示源自带的翻译 | Apple 设备端翻译 |
| 罗马音 | 逐行判定的拼音、**粤拼**、日语注音假名 | — | — |
| 简繁转换 | 支持，独立于界面语言 | 支持 | — |
| 对唱/多歌手分行 | 支持（源标注了演唱者时） | — | — |
| 打卡与听歌统计 | Last.fm + ListenBrainz 打卡、补传、本地历史、榜单、听歌热力图 | — | — |
| 展示形态 | 桌面悬浮歌词、灵动岛胶囊、菜单栏歌词、完整歌词窗口 | 桌面 + 菜单栏 | 菜单栏、全屏视图、卡拉 OK 弹窗 |
| 界面语言 | 英文、简体中文、繁体中文 | 多语言（Crowdin） | 英文、简体中文 |

## Lyrimuse 的定位

Lyrimuse 面向另外两家没有完全覆盖的听歌方式：你用 **QQ 音乐、网易云音乐或酷狗** 听歌
（不只是 Apple Music / Spotify）；你在**浏览器里开 YouTube Music 或 Spotify 网页版**、
也想要跟着页面进度精确同步的桌面歌词；你想在原文旁边看到**粤拼或日语注音假名**；或者你想让
**Last.fm / ListenBrainz 打卡和听歌统计**与歌词在同一个应用里完成——全部免费、开源、
持续维护中。

**安装：** `brew tap yudaotor/lyrimuse && brew install --cask lyrimuse`（Apple Silicon 与
Intel 都支持），或到 [Releases 页面](https://github.com/Yudaotor/lyrimuse/releases/latest)
下载——完整安装方式见[快速开始](https://github.com/Yudaotor/lyrimuse/blob/main/README.zh-CN.md#快速开始)。
