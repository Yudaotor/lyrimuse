# Lyrimuse URL Scheme

*[English](url-scheme.md)*

用 `lyrimuse://` 开头的链接，可以从快捷指令、Raycast、Alfred、Stream Deck、终端（`open 'lyrimuse://…'`）这类工具里控制 Lyrimuse：打开窗口和设置页、开关各种歌词、控制播放、调时间轴，或者拿到正在播放的信息。

常用的几条可以在「设置 › 快捷键」底部的「深度链接」里直接拷贝；指针移到每个快捷键上，也能拷贝它对应动作的链接。

## 通用规则

- 大小写不敏感。
- 认不出的链接什么都不做，Lyrimuse 会提示「无法识别的链接」。
- 打开窗口的链接都可以加 `background=1`：窗口照常出来，但不把 Lyrimuse 切到前台、不抢键盘焦点。例如 `lyrimuse://lyrics-window?background=1`。
- 开关类的动作可以加 `on=1` 或 `on=0` 指定目标状态（也认 `true` / `false`、`on` / `off`），重复执行结果不变；不带就是切换。
- 网页也能打开 `lyrimuse://` 链接（浏览器第一次会先问你），所以这里只开放随时能撤回的操作：开关、打开窗口、播放控制、时间轴微调，不会删改歌词，也不碰账号。

## 打开窗口

| 链接 | 作用 |
|---|---|
| `lyrimuse://lyrics-window` | 打开歌词窗口 |
| `lyrimuse://lyrics-window/search` | 打开歌词窗口，并打开「搜索歌词…」窗口（跟 `lyrics-search` 是同一扇） |
| `lyrimuse://lyrics-manager` | 打开歌词管理 |
| `lyrimuse://lyrics-search` | 打开「搜索歌词」小窗（搜的是正在放的这首） |
| `lyrimuse://menubar-panel` | 打开或关闭菜单栏面板 |
| `lyrimuse://menubar-panel?quick=overlay` | 打开菜单栏面板，并翻到某一格的快捷设置（只打开、不关闭）。`quick` 可选 `overlay`、`notch`、`menubar`、`touchbar`、`lyrics-window`、`lyrics-manager` |
| `lyrimuse://menubar-menu` | 弹出菜单栏图标的菜单 |
| `lyrimuse://onboarding` | 打开欢迎引导 |

## 打开设置

`lyrimuse://settings` 打开设置。后面加路径可以直接翻到某一页，再加一段可以翻到页里的某个分段。

| 路径 | 页面 | 分段 |
|---|---|---|
| `/lyrics` | 歌词 | `/fetch` 获取、`/translation` 译文、`/display` 调整、`/manage` 管理 |
| `/player` | 播放器 | `/players` 播放器、`/linkage` 联动、`/permissions` 权限与服务 |
| `/appearance` | 歌词显示 | `/overlay` 悬浮歌词、`/notch` 灵动岛、`/menu-bar` 菜单栏、`/touch-bar` 触控栏、`/lyrics-window` 歌词窗口 |
| `/shortcuts` | 快捷键 | — |
| `/general` | 通用 | — |
| `/about` | 关于 | — |
| `/account/lastfm` | Last.fm | `/stats` 统计、`/chart` 榜单、`/on-this-day` 足迹、`/settings` 设置 |
| `/account/listenbrainz` | ListenBrainz | — |
| `/account/discord` | Discord | `/display` 显示内容、`/buttons` 按钮、`/privacy` 隐私 |
| `/account/relay` | 网页推送 | — |
| `/account/bark` | 推送提醒 | — |
| `/software-update` | 软件更新 | 加 `?check=1` 顺便检查一次更新 |
| `/lastfm-suggestions` | Last.fm 账号建议 | — |
| `/labs` | 实验室 | — |

例如：`lyrimuse://settings/appearance/overlay`、`lyrimuse://settings/software-update?check=1`。认不出的路径只打开设置窗口；认不出的分段翻到那一页、停在上次看的分段。

## 动作：`lyrimuse://action/<名字>`

跟「设置 › 快捷键」里的全局快捷键是同一套动作，执行的也是同一份逻辑，按下去会有同样的提示。

### 显示开关

| 名字 | 作用 | 参数 |
|---|---|---|
| `toggle-overlay` | 显示 / 隐藏桌面悬浮歌词 | `on` |
| `toggle-notch` | 显示 / 隐藏灵动岛歌词 | `on` |
| `toggle-menubar-lyrics` | 显示 / 隐藏菜单栏歌词 | `on` |
| `toggle-touchbar` | 展开 / 收起触控栏歌词（只在有触控栏的 Mac 上有效） | — |
| `toggle-all-lyrics` | 隐藏 / 恢复全部歌词：把开着的悬浮歌词、灵动岛、菜单栏歌词全部收起，再执行一次照原样恢复 | `on`（`0` 收起、`1` 恢复） |
| `toggle-lock-position` | 锁定 / 解锁悬浮歌词的位置 | `on` |
| `toggle-translation` | 显示 / 隐藏译文 | `on` |
| `toggle-romanization` | 显示 / 隐藏读音 | `on` |
| `overlay-font-larger` | 放大悬浮歌词字号 | — |
| `overlay-font-smaller` | 缩小悬浮歌词字号 | — |

### 打开窗口

| 名字 | 作用 | 参数 |
|---|---|---|
| `open-lyrics-manager` | 打开歌词管理 | — |
| `open-lyrics-window` | 打开歌词窗口 | — |
| `toggle-lyrics-window-mini` | 歌词窗口在迷你、完整两种尺寸间切换；没开时直接开成迷你 | `on`（`1` 迷你、`0` 完整） |
| `search-lyrics` | 打开「搜索歌词」小窗 | — |
| `open-settings` | 打开设置 | — |
| `open-player` | 把正在用的播放器切到前台 | — |

### 歌词时间轴

| 名字 | 作用 | 参数 |
|---|---|---|
| `lyrics-advance` | 这首歌的歌词提前一步 | `step`：这一下调多少秒（0 到 5），不带就用设置里的步长 |
| `lyrics-delay` | 这首歌的歌词延后一步 | `step`，同上 |
| `lyrics-offset-reset` | 这首歌的歌词偏移归零 | — |

### 播放控制

| 名字 | 作用 | 参数 |
|---|---|---|
| `play-pause` | 播放 / 暂停 | — |
| `next-track` | 下一首 | — |
| `previous-track` | 上一首 | — |
| `toggle-favorite` | 喜欢 / 取消喜欢正在放的这首（看播放器支不支持） | `on`（`1` 喜欢、`0` 取消） |

例如：`lyrimuse://action/toggle-overlay?on=0`、`lyrimuse://action/lyrics-advance?step=0.5`。

### 其他动作

| 链接 | 作用 |
|---|---|
| `lyrimuse://action/copy-lyric` | 把当前这句歌词拷贝到剪贴板；加 `?translation=1` 连译文一起拷贝 |
| `lyrimuse://action/surfaces?overlay=1&notch=0&menubar=1` | 一次设好显示哪些歌词：`overlay`（悬浮歌词）、`notch`（灵动岛）、`menubar`（菜单栏）填 `1` 显示、`0` 隐藏，只带要改的那几个 |
| `lyrimuse://action/lyrics-offset?ms=-300` | 把这首歌的歌词偏移直接设成某个值：单位毫秒，正数提前、负数延后，±10000 以内 |
| `lyrimuse://action/play-mode?mode=shuffle` | 设置播放模式：`mode` 可选 `list`（顺序）、`shuffle`（随机）、`repeat-all`（列表循环）、`repeat-one`（单曲循环）；播放器做不到的档位按 `list` 处理 |

## 获取正在播放（x-callback-url）

```
lyrimuse://x-callback-url/now-playing?x-success=<回传地址>
```

Lyrimuse 会把正在播放的信息作为参数，附在 `x-success` 后面打开它（`x-success` 原有的参数会保留）：

| 参数 | 内容 |
|---|---|
| `title` | 歌名 |
| `artist` | 歌手 |
| `album` | 专辑 |
| `lyric` | 当前这句歌词 |
| `player` | 播放器名字 |
| `playing` | 正在播放是 `1`，暂停或没有歌是 `0`（没有歌时前面几项都是空的） |

在快捷指令里，用「打开 X-Callback URL」动作，URL 填 `lyrimuse://x-callback-url/now-playing` 即可：快捷指令会自己补上 `x-success`，回传的参数就是这个动作的结果。

为了不让网页借这条链接读到你在听什么，回传地址有两条限制：不能是网页、文件或脚本地址（`http`、`https`、`file`、`ftp`、`javascript`、`data`、`about`、`blob`，以及 `lyrimuse` 自己）；并且这个地址在你的 Mac 上要由一个不是浏览器的 App 来打开。不满足时什么都不回传。
