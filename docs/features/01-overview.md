# 01. 总览与架构

> 最后核对:2026-08-20 · 基线:2a2bf8b+工作树

> **全部章节导航**:见同目录 `README.md` 索引。

## 定位

Lyrimuse 是一个 macOS 菜单栏歌词软件:悬浮窗/灵动岛/歌词窗口实时显示当前播放曲目的逐字歌词,可选把收听历史提交到 ListenBrainz/Last.fm,并驱动一个公开的"正在播放"网页和飞书链接预览卡片。本章讲整个系统由哪些进程/部件组成、彼此怎么通信、数据落在哪里——改任何功能前先在这里确认它属于哪个部件、跨了哪条进程边界。

## 入口与展示面

系统对用户暴露的入口,按部件分:

| 入口 | 部件 | 说明 |
|---|---|---|
| 菜单栏图标 + 各悬浮窗口 | `lyrimuse.app`(Swift) | 唯一的 GUI。菜单栏常驻,无 Dock 图标(可选开启);设置、歌词管理、引导页都从这里进 |
| launchd 后台服务 | collector(Go) | 无界面。用户只在设置页看到"后台服务"开关和运行状态,以及 `collector healthcheck` 诊断命令 |
| 公开网页 | `web/index.html` | 浏览器访问,展示正在播放/历史/留言墙等;与 App 无直接连接 |
| 飞书链接预览 | `feishu-bot`(Go) | 在飞书里贴特定链接时自动渲染"正在听什么"文字卡片 |

## 行为规格

### 部件清单

**1. `lyrimuse.app` —— Swift 主程序(`lyrimuse/`)**

SwiftUI + AppKit,菜单栏 App。Swift Package 含四个 target:

- `Sources/lyrimuse/`:App 本体。子目录按窗口/职责分:`UI/`(悬浮窗 `LyricsOverlayView`、灵动岛 `NotchLyricsView`、歌词窗口 `LyricsWindowView` 等)、`MenuBar/`(状态栏图标/菜单/跑马灯)、`Settings/`(设置页、配置读写、launchd 服务管理、账号授权)、`LyricsManager/`(歌词管理窗口及其对 collector 的控制)。
- `Sources/LyrimuseCore/`:纯逻辑层,**零 SwiftUI import**(刻意边界,详见下文"跨切约定")。子目录:`Lyrics/`(LRC/YRC 解析、同步引擎、卡拉OK填色、换行数学)、`Local/`(播放状态读取、enrich 缓存读取、launchd 状态解析)、`Playback/`、`Networking/`、`Util/`、`Diagnostics/`。
- `Sources/lyrimuse-selftest/`:手写断言的测试可执行文件(本机无完整 Xcode,XCTest 不可用),`swift run lyrimuse-selftest` 全量跑。
- `Sources/lyrics-translate/`:独立小可执行文件,见下面第 3 条。

App 自己**直接**读播放状态(不经 collector):`MediaControlClient.fetchSnapshot` 按用户选定的播放器走两条路——Apple Music 用 AppleScript(JXA)直接问 Music.app(约 2 秒一轮热路径);QQ 音乐/网易云/Spotify/自动识别走内置 `media-control` 二进制读系统级 MediaRemote。歌词则从 collector 写在磁盘上的 enrich 缓存读(`EnrichCacheReader`),`LocalPlaybackSource` 以 20Hz tick 计算当前行/填色进度。

**2. collector —— Go 常驻进程(`lyrimuse-collector/`)**

单一 flat package,编译产物打包进 `Lyrimuse.app/Contents/Resources/collector`,由 App 侧 `CollectorServiceManager` 注册成 launchd LaunchAgent `com.lyrimuse.collector`(RunAtLoad + KeepAlive,崩了自动拉起)。职责:

- 每 5 秒轮询播放状态(`poller.go run()`;读取路径与 App 侧同构:Apple Music 走 JXA,其余走 media-control,见 `system.go`);
- 解析歌词/封面/取色/各平台链接:五个歌词源(网易云/QQ/酷狗/Musixmatch/LRCLIB)全查+统一打分(`enrich.go`/`match.go`),结果写 enrich 缓存和 `lyrics/` 文件夹——**这是悬浮歌词的唯一数据生产者**,没有它 App 什么都显示不出来;
- 可选:提交 playing_now/listen 到 ListenBrainz(`lb.go`)、镜像 scrobble 到 Last.fm(`lastfm.go`)、把 iPhone 的 Last.fm 播放桥接进 LB、推送当前状态到自建状态中继 `/push`(`relay.go`/`poller.go`)、周报/日报推送(`weekly.go`/`daily.go`)、Top 歌手统计(`topartists.go`);
- 一次性子命令(`main.go` 在 flag 解析前分流):`search-lyrics`(歌词管理的手动搜索)、`artist-avatars`、`backfill-lastfm`、`delete-listen`、`healthcheck`(诊断"歌词为什么不出来")、`top-artists`、`dedupe-entries`、`recheck-cover`(对指定条目重新解析一次封面，见第 09 章 §7)、`recheck-instrumental`(给缺「纯音乐」标记的条目补上这个结论，见第 09 章 §8)。子命令不进常驻循环；只有会改缓存的那几个(`dedupe-entries -apply` / `recheck-cover -apply` / `recheck-instrumental -apply`)反过来**要求**常驻实例已停，fail-closed。
- 常驻路径有单实例 flock 锁(`singleinstance.go`,锁文件 `collector.lock`):拿不到锁退出码 0,交给 launchd 稍后重试——两个实例并存曾把 204 条歌词缓存磨到 10 条。
- **没有任何监听端口/HTTP 服务**,也没有文件监听:`config.json`/`lyrimuse-features.json` 只在启动时读一次,改了配置要重启才生效。
- 配置加载是逐字段容错的(`config.go loadConfig`):单个字段格式坏只跳过该字段并打日志,绝不因内容问题打死进程(KeepAlive 下 Fatal = 崩溃循环,而核心功能不需要任何配置字段;`listenbrainz_token` 留空也照常跑,只是不提交 LB)。

**3. lyrics-translate —— 端上翻译 helper(`lyrimuse/Sources/lyrics-translate/main.swift`)**

独立 Swift 可执行文件,打包进 `Contents/Resources/`,由 collector 按相对路径(与 collector 同目录)以子进程调用(`translate.go`)。协议:stdin/stdout 各一行 JSON(入 `{"target","lines"}`,出 `{"ok","source","lines"}`,行数必须原样对齐)。存在的原因:Go 调不了 Apple 的 Translation 框架,而端上翻译不联网、无配额;Translation 要 macOS 15+,helper 起不来时 collector 自动退回 MyMemory 网络机翻(匿名约 5000 字符/天)。

**4. media-control —— 第三方二进制**

[ungive/media-control](https://github.com/ungive/media-control)(BSD-3),访问私有 MediaRemote 框架的社区实现。`build.sh` 从 Homebrew 拷进 bundle 的 `Contents/Resources/media-control/bin/media-control`,collector(`system.go mediaControlBinaryPath()`,按自身可执行文件相对路径找)和 App(`MediaControlClient`)各自以子进程调用 `media-control get --now --no-artwork`。只服务非 Apple Music 播放器和自动识别;Apple Music 那条路完全不依赖它。

**5. web/ —— 公开"正在播放"网页**

单文件 `index.html`(无框架无构建),加 `demo/`(去个人化的 fork 模板)和 `sw.js`(service worker,仅作者自己的部署用)。**`web/` 是一个嵌套的独立 git 仓**(有自己的 `.git`,origin 指向 `github.com/Yudaotor/nowplaying`),托管在 GitHub Pages。数据来源:优先读状态中继(nowplaying-workers 的 `/now`/`/history`),失败或 `?relay=off` 时直连 ListenBrainz 公开 API。留言墙/反应/访客计数/Top 歌手也走中继的端点。与本仓其余部分**没有代码依赖**——只共享中继的 JSON 形状(collector `relay.go relayState()` 的注释即是这份契约的文档)。⚠️待核对:web/ 页面改动如何同步到线上仓(仓库内无部署脚本;嵌套仓本地 HEAD 与线上可能不同步)。

**6. feishu-bot —— 飞书链接预览 bot(`feishu-bot/`)**

独立 Go 常驻程序,与 collector 零代码依赖。飞书客户端里贴中转链接 → 命中飞书「链接预览」应用的 URL 规则 → 飞书经 **WebSocket 长连接**回调本程序(不需要公网入站端口;公网 HTTP 回调对国内飞书服务器实测 3 秒超时不可用)→ 程序读状态中继 `/now`(可选,配置了 `state_relay_url` 时优先)或直连 ListenBrainz playing-now → 返回纯文字 Inline 卡片。配置在 `~/.config/applemusic-nowplaying/feishu.json`(注意:**还是改名前的旧目录名**,与 collector 的 `~/.config/lyrimuse/` 不同,`feishu-bot/main.go` 硬编码)。⚠️待核对:本机 feishu-bot 实际以哪个二进制路径/plist 常驻(仓库只提供示例 plist,要求使用者自改路径)。

**7. nowplaying-workers —— 外部仓(不在本仓)**

Cloudflare Worker + KV 的状态中继(state-worker):collector 推 `/push`(带 token 认证),网页/feishu-bot 读 `/now`,历史走 `/history`(中继内部合并 ListenBrainz)。留言墙/反应/访客计数等公开写接口也在那边。本仓能看到的只有调用端;端点行为以 `github.com/Yudaotor/nowplaying-workers` 为准。

### 通信方式:进程间没有网络 IPC

本机各部件之间**全部**靠三种手段,没有任何本地端口:

1. **共享文件**(`~/.config/lyrimuse/`,详见"数据与文件"):
   - Swift → Go:`ConfigStore` 写 `config.json`(凭据/中继地址等),`FeatureSettingsStore` 写 `lyrimuse-features.json`(播放器选择/功能开关/歌词源配置)。**collector 只读不写**这两个文件。
   - Go → Swift:collector 写 enrich 缓存(`lyrimuse-enrich-cache.json`)、`lyrics/` 文件夹、状态文件(`lyrimuse-collector-status.json`、`lyrimuse-lastfm-status.json`),Swift 侧 `EnrichCacheReader`/`CollectorStatus` 等读。
   - 双向的一个例外:歌词管理窗口的 `EnrichCacheStore`(Swift)会直接**改写** enrich 缓存 JSON 和 `lyrics/` 文件——见下条。
2. **launchctl kickstart 当作"重载配置"信号**:collector 不监听文件,所以 Swift 侧改完共享文件后,靠 `CollectorControl.kickstart`(`launchctl kickstart -k gui/<uid>/com.lyrimuse.collector`)重启 collector,让它下次启动读到新内容。歌词管理的每次保存/删除都走这条路(先落盘、立刻踢重启,否则 collector 内存里的旧 map 随时可能整份覆盖回磁盘,悄悄撤销刚做的修改——`EnrichCacheStore.swift` 顶部注释)。
3. **一次性子进程调用**:App 调 `collector search-lyrics`(`LyricsSearchService`)、`collector artist-avatars`、`collector backfill-lastfm`、`collector delete-listen`;collector 调 `media-control` 和 `lyrics-translate`;App 调 `media-control` 和 `osascript`(JXA)。

跨机器(出网)的通信全是 HTTP 客户端行为:collector → ListenBrainz/Last.fm/五个歌词源/MusicBrainz/状态中继 `/push`;网页 → 中继/ListenBrainz;feishu-bot → 飞书长连接 + 中继/ListenBrainz。

### 生命周期与启动顺序

- App 和 collector 是**两个独立的 launchd job**,互不拉起:`me.yudaotor.lyrimuse`(App,RunAtLoad、故意不设 KeepAlive——用户会主动 Cmd-Q,由 `LoginItemManager` 按"开机启动"开关装卸)和 `com.lyrimuse.collector`(KeepAlive,由 `CollectorServiceManager` 在引导页/设置页开关时装卸)。App 退出后 collector 照常采集/解析/提交。
- collector 启动路径(`main.go`)顺序敏感:装日志脱敏 → 子命令分流 → 读 config → 拿单实例锁 → 读 features(定 `lyrics_dir`)→ 加载 enrich 缓存 → **enrich key 归一化迁移**(`enrichkey.go migrateEnrichKeys`,必须夹在"加载缓存之后、导入 lyrics 文件之前")→ `importLyricsFromFiles()`(**lyrics/ 文件夹永远赢**,覆盖 JSON 缓存里的歌词字段)→ 失效陈旧译文 → `exportLyricsFiles()`(把调和结果重新导出,磁盘立刻对齐)→ 进入 5 秒轮询主循环。歌词管理改完 kickstart 重启,走的就是这同一条调和路径,Swift 侧不用另写一遍。
- 服务真实状态判断用 `LaunchdJobState`/`LaunchdPrintParser`,不能用 `launchctl print` 退出码(那只表示"注册过",不表示进程在跑)。

### 数据流一图

```
                         ┌── AppleScript(JXA) ──▶ Music.app
lyrimuse.app(Swift) ─────┤
  │  ▲                   └── media-control ─────▶ 系统 MediaRemote(QQ/网易云/Spotify)
  │  └─ 读 enrich 缓存/lyrics/(歌词展示)
  │
  ├─ 写 config.json / lyrimuse-features.json ──▶ collector 启动时读
  ├─ launchctl kickstart(重载信号)──────────▶ collector 重启
  └─ 子进程:collector search-lyrics 等

collector(Go, 5s 轮询) ── 同样两条播放读取路径(独立于 App)
  ├─ 五源歌词解析 ──▶ 写 enrich 缓存 + lyrics/ 文件夹
  ├─ 子进程:lyrics-translate(端上翻译)/ media-control
  ├─ HTTP ▶ ListenBrainz(playing_now/listen)、Last.fm(镜像/桥接)
  └─ HTTP ▶ state-worker /push(nowplaying-workers, 外部仓)
                    ▲                       ▲
        web/index.html 读 /now /history     feishu-bot 读 /now(或直连 LB)
```

### 许可、版权与对外请求(2026-09-03)

- **许可**:Lyrimuse 本身 GPL-3.0(仓库根 `LICENSE`);随包分发的第三方组件与数据(media-control、Sparkle、KeyboardShortcuts、OpenCC 词典、rime-cantonese 词典)在仓库根 `THIRD_PARTY_LICENSES` 逐条列出并附许可证全文,`build.sh` 把它拷进 `Contents/Resources/`(BSD/MIT 分发条款要求随附),设置「关于 → 第三方许可」用 TextEdit 打开包里这份(开发态或没有 TextEdit 退到 GitHub 同一文件)。`scripts/check_third_party_licenses.py`(CI 也跑)机械核对 `Package.resolved` / `build.sh` 的 `brew install` / `go.mod` 的每个依赖都在文件里出现过。
- **版权立场**:歌词、封面、曲目信息归权利人;本项目只检索、缓存、展示,不托管、不转发、不再分发;与各播放器 / 歌词平台无隶属关系。对用户的完整表述只维护在 README 中英版「许可与版权说明」一节——App 里的「使用与版权说明」入口(关于页)和引导欢迎页那句都只是链接过去,**不在 xcstrings 里抄第二份**(这段话改的频率远高于发版)。**刻意不做阻断式首启接受页**:引导原则是介绍性内容不锁下一步,GPL 个人工具也没有需要「接受」的条款。
- **对外请求全景**:README 那一节向用户承诺「会离开你 Mac 的只有这些」——**加一处对外请求就要同步这张表和那一节**;实际发生的每一条都进审计日志(第 14 章 §7、第 15 章「网络观察」)。

| 目的地 | 谁发 | 发什么 | 何时 |
|---|---|---|---|
| 八个歌词源:`music.163.com`、`*.qq.com`、`*.kugou.com`、`*.kuwo.cn`、`*.musixmatch.com`、`lrclib.net`、`music.youtube.com`(LyricFind)、`raw.githubusercontent.com`(AMLL) | collector | 歌手、歌名、专辑,部分源带时长;AMLL 只按网易云 / QQ 音乐 ID 取文件 | 每首新歌解析(第 09 章) |
| `musicbrainz.org` | collector | 歌手名 | 各源全落空时查别名 / 主名(第 09 章) |
| `itunes.apple.com` | collector、App | 歌手 + 歌名(+ 地区) | collector 封面 / 署名锚点;App 高清封面替代与空闲页链接(第 03 章) |
| `api.mymemory.translated.net` | collector | **歌词正文**分块 + 随机生成的邮箱参数 | 「系统兜底翻译」开着且端上 Apple 翻译不可用(第 10 章) |
| `1.1.1.1` / `8.8.8.8`(DoH) | collector | 域名 | 只有 `*.musixmatch.com` 走 DoH(`doh.go dohHostSuffixes`) |
| `api.github.com` | App | 无用户数据 | 关于页 star 数,最多每 6 小时一次 |
| `github.com`(Releases appcast) | App(Sparkle) | 无系统信息(未开 `SUEnableSystemProfiling`) | 更新检查 |
| `ws.audioscrobbler.com`、`api.listenbrainz.org` | collector、App | 播放记录(带账号凭据鉴权) | 用户主动连接后 |
| 推送平台(Bark、钉钉、企业微信、Discord、飞书、Server酱)、状态中继(自建 Worker)、`api.deezer.com`(网页 Top10 歌手头像) | collector | 周报文本 / 当前播放状态 / 歌手名 | 用户主动配置后 |

## 设置项

无(本章是架构总览;各设置项归属各功能章节)。与架构直接相关的仅两个:设置页「后台服务」开关(装/卸 collector LaunchAgent,`CollectorServiceManager`)和「开机启动」开关(装/卸 App 自己的 LaunchAgent,`LoginItemManager`)。

## 与其它功能的交互

本章是所有功能章节的骨架,这里只列**跨切约定**——几乎每个功能都踩在这几条上:

- **"Swift 写共享文件 → kickstart 重启 collector"约定**:功能开关、播放器切换、歌词源配置、歌词管理编辑,全走这个模式。任何"改了设置 collector 却没反应"的问题先查是不是漏了 kickstart。
- **enrich 缓存 key 的双侧镜像**:key 由 Go 侧 `enrichKey()`(`enrichkey.go`)构造,Swift 侧镜像在 `EnrichCacheKeys.swift`,**两边必须同步改**。不同步的后果是同一首歌两条缓存+两份歌词文件。
- **lyrics/ 文件夹是歌词 6 字段(lyrics/lyrics_tr/lyrics_roma/lyrics_yrc/lyrics_source/manual_lyrics)的权威源**,enrich 缓存 JSON 只是存档;启动调和时文件永远赢。删除文件=删条目。
- **歌词源 id 是全项目唯一一套字符串**(`netease`/`qq`/`kugou`/`musixmatch`/`lrclib`,`features.go` 常量 ↔ Swift `LyricsSource` rawValue ↔ 歌词管理窗口 `sourceDisplayName`),加源要三处同步。
- **`LyrimuseCore` 不 import SwiftUI**:几何/数学/解析逻辑必须下沉到 Core 才能被 selftest 覆盖;接缝画在数值上(`KaraokeFill` 返回 0…1 而不是 `Color`)。
- **播放器选择(`features.json` 的 `player` 字段)同时影响两个独立读取者**:App 的 `MediaControlClient`(`PlaybackPlayerPreference`)和 collector 的 `system.go`(启动时读一次,还决定歌词打分偏向哪个平台的 `nativeLyricSource`)。
- **LB 单条 listen ≤10240 字节的预算裁剪只属于 LB 那条路**(`lb.go`):推给状态中继/网页的歌词从 `trackEnrichment` 现拿未裁剪版本(`relay.go` 注释)。曾因误用裁剪版导致网页歌词与本地不一致。

## 数据与文件

### `~/.config/lyrimuse/`(collector 与 App 的共享目录)

| 文件 | 写入方 | 读取方 | 内容 |
|---|---|---|---|
| `config.json` | Swift `ConfigStore` | collector(启动时) | LB token、Last.fm 凭据、状态中继地址/token、通知 webhook 等 |
| `lyrimuse-features.json` | Swift `FeatureSettingsStore` | collector(启动时) | 播放器选择、功能开关(*bool,缺省=沿用现有行为)、歌词源集合/模式/顺序、`lyrics_dir` |
| `lyrimuse-app-settings.json` | Swift `AppSettingsMirror` | Swift(仅 `restoreIfPristine()` 全新装机时读回) | UserDefaults 的单向镜像(外观/快捷键等),让"拷走整个文件夹=拷走整份配置"成立 |
| `lyrimuse-enrich-cache.json` | collector(整 map 覆盖写);歌词管理 `EnrichCacheStore` 按 key 字典级增删改 | 双方 | 曲目元信息+歌词+封面+取色+链接缓存,key=`歌手\|歌名\|专辑`(经 `enrichKey()` 归一) |
| `lyrics/`(可经 `lyrics_dir` 改位置) | collector 导出(同目录临时文件 + 改名的原子写,2026-09-02 起);歌词管理直写(`atomically: true`)/删 | collector 启动调和(顺带清扫 `*.tmp.*` 崩溃残留) | 每曲目 `<base>.lrc/.tr.lrc/.roma.lrc/.yrc` 四缀,歌词字段权威源 |
| `lyrimuse-listens.jsonl` | collector | collector、App(本地收听清单) | 账号无关的本地收听日志(刻意不带账号前缀) |
| `lyrimuse-artist-alias-cache.json` | collector | collector | MusicBrainz 按歌手的中文别名查询缓存 |
| `lyrimuse-artist-identity-cache.json` | collector | collector | MusicBrainz 歌手身份缓存(mbid+中文名),Top 歌手榜归并第三信号 |
| `lyrimuse-artist-avatar-cache.json` | `collector artist-avatars` 子命令 | App(Last.fm 信息页) | 歌手头像 URL 缓存 |
| `lyrimuse-lastfm-forwarded.json` / `-mirrored.json` / `-collapse.json` | collector | collector | Last.fm 桥接/镜像的去重与折叠状态 |
| `lyrimuse-lastfm-weekly.json` / `lyrimuse-lb-daily.json` / `lyrimuse-lastfm-top-artists.json` | collector | collector | 周报/日报/Top 歌手的节流与状态 |
| `lyrimuse-lastfm-stats-cache.json` | Swift `LastfmStatsService` | Swift | Last.fm 统计页缓存 |
| `lyrimuse-musixmatch-token.json` | collector | collector | Musixmatch 匿名 token 缓存 |
| `lyrimuse-collector-status.json` | collector(启动时先清掉旧文件) | Swift `CollectorStatus` | collector→App 状态通道(目前只报"网络不通") |
| `lyrimuse-lyrics-pins.json` | Swift `LyricsPinStore` | collector(`lyricspins.go`,按 mtime 重读) | App→collector 唯一的反向通道:已校准过时间轴的曲目名单,一票否决自动重选歌词源 |
| `lyrimuse-lastfm-status.json` | collector(`lastfm.go`) | Swift `LastfmMirrorStatus` | Last.fm 镜像凭据致命错误 |
| `collector.lock` | collector flock | — | 单实例锁,随进程消亡自动释放 |
| `*.bak` / `backup-*` | 一次性迁移(如 `enrichkey.go` 写 `.pre-keynorm.bak`)或手工备份 | — | 残留备份,无代码读取 |

### 其它位置

- **UserDefaults 域 `me.yudaotor.lyrimuse`**:App 全部偏好的权威存储(`AppSettings`),`defaults delete me.yudaotor.lyrimuse` 即彻底重置。
- **`~/Library/Logs/lyrimuse.log`**:App 与 collector 两个 LaunchAgent 的 stdout/stderr **共用同一个文件**(`LoginItemManager` 和 `CollectorServiceManager` 各自生成的 plist 指向同一路径)。
- **`~/Library/LaunchAgents/`**:`me.yudaotor.lyrimuse.plist`、`com.lyrimuse.collector.plist`,均由 App 运行时生成安装;仓库里 `lyrimuse/launchd/me.yudaotor.lyrimuse.plist` 只是留档参考。
- **`~/.config/applemusic-nowplaying/feishu.json`**:feishu-bot 的配置,旧项目名目录,只有它还在用。
- **仓库根 `bin/`**:未纳入 git 的本地构建产物(`lyrimuse-collector/build.sh` 刷新 `bin/collector` 并额外拷一份进已安装的 .app,免整包重建即可验证 collector 改动)。

### 仓库目录结构

```
applemusic-nowplaying/
├── lyrimuse/                 # Swift 包:App + Core + selftest + lyrics-translate
│   ├── Sources/{lyrimuse, LyrimuseCore, lyrimuse-selftest, lyrics-translate}/
│   ├── build.sh              # release 构建+打包+签名+launchd 重启(真机验证必经)
│   ├── package.sh            # 发布产物(zip+sha256+dmg,校验架构)
│   ├── launchd/  Localization/  scripts/(check-windows/probe-launchd/uninstall 等)
├── lyrimuse-collector/       # Go collector,flat package + dictionary/ + testdata/
├── web/                      # 独立嵌套 git 仓(origin=Yudaotor/nowplaying):index.html + demo/ + sw.js
├── feishu-bot/               # 独立 Go 程序 + 示例 launchd plist
├── docs/                     # features/(本文档族)+ images/
├── bin/                      # 本地构建产物(未跟踪)
└── README.md  AGENTS.md  CLAUDE.md  THIRD_PARTY_LICENSES
```

## 代码锚点

| 主题 | 位置 |
|---|---|
| collector 启动顺序/子命令分流/文件路径拼装 | `lyrimuse-collector/main.go` `main()` |
| collector 主轮询循环 | `lyrimuse-collector/poller.go` `run()` |
| 容错配置加载(只读不写) | `lyrimuse-collector/config.go` `loadConfig()`/`decodeConfigPerField()` |
| 功能开关文件形状 | `lyrimuse-collector/features.go` `featureFlagsFile` |
| 播放状态读取(collector 侧,JXA/media-control 双路) | `lyrimuse-collector/system.go` `getStateScript`/`fetchRawMediaControlState()`/`mediaControlBinaryPath()` |
| 播放状态读取(App 侧) | `LyrimuseCore/Local/MediaControlClient.swift` `MediaControlClient`、`Local/LocalPlaybackSource.swift` `LocalPlaybackSource` |
| enrich 缓存 key 双侧镜像 | `lyrimuse-collector/enrichkey.go` `enrichKey()` ↔ `LyrimuseCore/Local/EnrichCacheKeys.swift` |
| 已校准锁定歌词源 | `LyrimuseCore/Lyrics/LyricsPinStore.swift`(写)↔ `lyrimuse-collector/lyricspins.go`(读) |
| enrich 缓存读取(App 侧只读) | `LyrimuseCore/Local/EnrichCacheReader.swift` `EnrichCacheEntry` |
| enrich 缓存读写(歌词管理,字典级增删改+kickstart) | `lyrimuse/LyricsManager/EnrichCacheStore.swift`、`CollectorControl.swift` |
| lyrics/ 文件夹权威源调和 | `lyrimuse-collector/lyricsimport.go`/`lyricsexport.go` |
| 状态中继推送(网页数据契约) | `lyrimuse-collector/relay.go` `relayState()`/`postRelay()` |
| 端上翻译 helper 协议与调用 | `lyrimuse/Sources/lyrics-translate/main.swift`、`lyrimuse-collector/translate.go` |
| 单实例锁 | `lyrimuse-collector/singleinstance.go` `acquireSingleInstanceLock()` |
| collector LaunchAgent 装卸/状态 | `lyrimuse/Settings/CollectorServiceManager.swift`、`LyrimuseCore/Local/LaunchdJobState.swift` |
| App 自身开机启动 | `lyrimuse/Settings/LoginItemManager.swift` |
| Swift↔Go 共享配置写入方 | `lyrimuse/Settings/ConfigStore.swift`、`FeatureSettingsStore.swift`、`AppSettingsMirror.swift` |
| 手动搜歌词的子进程调用 | `lyrimuse/LyricsManager/LyricsSearchService.swift` ↔ `lyrimuse-collector/searchcli.go` |
| feishu-bot 入口 | `feishu-bot/main.go` |

## 设计决策与已知坑

1. **collector 不开本地 HTTP/IPC,统一"共享文件 + kickstart 重启"**(`EnrichCacheStore.swift` 顶部注释):代价是每次歌词管理保存都让推送有个小间隙,换来的是不用维护常驻接口。个人工具的刻意取舍。
2. **collector 只读 `config.json`/`features.json`,写入方永远是 Swift**——双写会引入"谁赢"问题;同理 `AppSettingsMirror` 是 UserDefaults 的单向镜像,不做双向同步。
3. **`*bool` 表达功能开关**(`features.go`):文件/字段缺失必须解读成"沿用现有行为(默认开)",bool 零值会把"没配置"错读成"关闭",让纯增量开关静默改变现有行为。
4. **KeepAlive 下绝不 Fatal**:配置内容问题一律降级成 loadIssues 日志,否则就是崩溃循环;硬失败只留给"文件在但读不出来"。
5. **单实例锁的教训**(`singleinstance.go`):build.sh 反复重启期间新旧 collector 短暂共存,"整 map 覆盖写"互相踩,204 条缓存被磨到 10 条——凡整文件覆盖写的共享状态都要考虑并存窗口。
6. **`launchctl print` 退出码 ≠ 进程在跑**(`CollectorServiceManager.state` 的 2026-08-15 修复注释):它只表示 job 注册过;曾让设置页在崩溃循环时一直显示绿勾,还短路了 kickstart 失败自愈。
7. **media-control 的 `elapsedTime` 在稳定播放期间会整段冻结**,必须用 `--now` 的外推值;但暂停后外推基准不归零,`elapsedTimeNow` 会继续疯涨——暂停时要用原始值(`system.go` 注释,实测拿到过 1381 秒的荒谬值)。
8. **改名残留是刻意不迁移的**:collector 的 `clientName` 2026-07-23 从 applemusic-nowplaying 统一成 lyrimuse 且不写旧路径兼容;`bark_url` 这个 JSON key 名与字段语义(通用 webhook)不一致也是刻意保留,避免旧配置迁移成本。feishu-bot 的配置目录仍是旧名。
9. **~~`clientVersion`(`main.go`)是纯手动维护的字面量~~ → 2026-09-02 已改成构建时 `-ldflags` 注入**。原文说的"发版时容易忘记同步"果然应验了两次:v1.3.0 漏过一次(User-Agent/ListenBrainz submission_client 谎报了一整个发布周期),v1.5.0 又漏一次——用户在另一台机器装了 1.5.0 的 dmg,设置页报「App 1.5.0 · 采集服务 1.4.0」。根因不是谁不小心,是机制本身要求人工同步两个本该同源的值(App 侧一直从 git tag 自动派生)。现在两个构建脚本(`lyrimuse/build.sh` 打包路径、CI 发版也走它;`lyrimuse-collector/build.sh` 本地重建路径)统一注入同一个版本号,`clientVersion` 因此**必须是 `var` 不能是 `const`**——`-X` 对 const **静默失败**(构建照样 exit 0、值原封不动)。三道防线:`versioninjection_test.go`(钉住 var / 默认值是一眼假的 "dev" / 两个脚本都带注入,已做变异测试验证有效)、`build.sh` 里 swap 前一道**跑真实产物问版本**的一致性闸、以及原有的设置页告警(`bundledCollectorVersion`,它正是抓到 v1.5.0 这次的那道,只是时机在发版之后)。详见 15 章。
10. **web/README.md 尚写着 Lyrimuse "not yet open-source"**,与根 README 已开源的现状不一致——web/ 是独立嵌套仓,文档同步节奏与主仓脱节。

---

⚠️待核对(本章共 2 处):feishu-bot 在本机的实际常驻方式(仓库只有需自改路径的示例 plist,未核对 `~/Library/LaunchAgents/` 实态);web/ 页面改动同步到线上仓的具体流程(仓库内无部署脚本,嵌套仓本地 HEAD 与线上可能不同步)。
