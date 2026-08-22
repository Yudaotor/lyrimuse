# 15. 运行、部署与后台任务

> 最后核对：2026-08-22 · 基线：05767ae+工作树

## 定位

这套软件怎么构建、安装、常驻、自愈，以及 collector 里跟播放/歌词无直接关系的周期性任务（日报/周报推送、健康检查）。

## 入口与展示面

- 开发者：`cd lyrimuse && ./build.sh`（唯一的真机部署路径）。
- 用户可见：设置 → 播放器 → 后台采集服务（状态/装卸）；账号 → 推送提醒；灵动岛音量横幅；`collector health-check` CLI。

## 行为规格

### 1. build.sh（构建+打包+部署一条龙）

`swift build`（release，可多架构）→ `go build` collector → 组装 `.app` bundle（collector、media-control、lyrics-translate、.lproj 资源全拷进 `Contents/Resources/`；media-control 缺失时经 Homebrew 自动装）→ 架构检查 → 签名（ad-hoc）→ 经 launchd **kickstart** 重启 App；kickstart 后无存活进程时自动 `bootout+bootstrap` 兜底（LWCR 陈旧 codesigning 约束的自愈）→ 重载 collector job（刷新 launch constraint）。**`swift build` 通过 ≠ 已部署**——真机验证必须跑 build.sh（repo CLAUDE.md 三大硬规则之一）。

### 2. 常驻形态（两个 LaunchAgent）

| Job | 管理者 | 策略 |
|---|---|---|
| `me.yudaotor.lyrimuse`（App） | LoginItemManager（第 14 章） | RunAtLoad、**无** KeepAlive（用户会 Cmd-Q，不该复活） |
| `com.lyrimuse.collector` | CollectorServiceManager | **KeepAlive=true**（无人值守，崩了自动拉起；没有它所有歌词展示面都空） |

collector 二进制打包在 `.app/Contents/Resources/` 内，由 `Bundle.main` 精确定位，无需用户拼路径。`CollectorControl.restartAndWaitAsync`（launchctl kickstart -k + 真实退出码检查）被歌词管理和 features 保存共用。

**启动时对账（`CollectorServiceManager.reconcileAfterLaunch`，2026-08-22 加）**——这是 Sparkle 自动更新 / Homebrew cask upgrade / 手动拖 .app 覆盖这三条路唯一的兜底，它们都不经过 build.sh：

- 判据是**二进制指纹**（`np:collectorInstalledFingerprint` = collector 路径+大小+mtime）变了 **或** 服务没在跑，且用户开着 `np:collectorServiceEnabled`；命中就重跑 `install()`（它本身就是完整的 bootout→写 plist→bootstrap→kickstart→LWCR 重试三级自愈，这里缺的只是一个启动触发点）。
- **为什么不能只看「在不在跑」**：更新之后老 collector 往往还活着（要等下一次缺页才被 SIGKILL），那一刻 `isRunning` 仍是 true，只看运行状态会整个错过这次更新；而等它真死掉时 App 早就启动完了，没有人再检查。
- **为什么不算 cdhash**：`codesign -dvvv` 要 fork 进程读整个二进制算哈希，而这里只需要回答「跟上次装的是不是同一个文件」。每次打包都是重新 `cp` + 重新 ad-hoc 签名，mtime 必变，stat 一次就够，启动路径上零感知。指纹拿不到（直接 `swift build` 跑、没有 bundle）时退回只看运行状态。
- 指纹只在 `install()` 之后**确认跑起来了**才写（`recordInstalledFingerprint`，用 `defer` 收口三条 early return），装完仍起不来就清掉——否则会因为「指纹对得上」而再也不管它。`uninstall()` 一并清掉。
- 这个键是**机器本地状态**，在 `ConfigPortability.machineLocalDefaultsKeys` 里（第 14 章）：跟着备份搬到新机器，会让新机器误以为「没变过」而跳过那次本该做的重装，正好把这条兜底关掉。
- 不阻塞启动：整段跑在 `CollectorServiceManager` 已有的串行队列上（顺带保证不跟设置页/引导页的装卸并发）。

### 3. collector 启动与自保护

- **单实例锁**（flock，随进程消亡自动释放）：两个实例共存会互磨缓存——2026-08-16 实锤 204 条歌词缓存被磨到 10 条，这是硬防线。
- 启动固定顺序：加载缓存 → key 归一化迁移 → lyrics 文件导入（文件赢）→ 清语言失配机翻 → 导出调和（第 09/11 章）；损坏缓存挪 `.corrupt` 旁路。
- **companionLaunch**：打开所选播放器时顺带唤起 Lyrimuse（`features.launchLyrimuseOnMusicOpen`，默认开）；反方向（开 Lyrimuse 唤起播放器）在 App 侧。
- 网络观察（networkobs）：解析全空时标记「网络不通」状态给 UI（歌词区显示网络提示而非「没歌词」）。

### 4. 日报/周报推送（可选，默认关）

- **daily.go**：每天到 `dailyDigestTriggerHour` 后的第一次检查（半小时一查）推一条当日收听摘要；按 `features.DailyDigestSource` 选数据源；状态文件记「已推送到哪一天」防重启重推。
- **weekly.go**：每周一条（2 小时一查），按 Last.fm 图表周或 ISO 周边界；状态文件记已推送周。
- **digest.go**：拼内容（Top 歌曲/歌手各取 `digestTopN` 条，Bark 锁屏预览要能读完；LB 翻页 100 条/页）。
- **notify.go/alerter.go**：推送通道，支持 Bark/钉钉(签名)/企业微信/Discord/飞书(签名)/Server酱（除 Server酱表单编码外都是 webhook+JSON 模子）。原「连续失败 N 次告警」能力已整体下线，alerter 只剩 push 载体。

### 5. 健康检查与诊断

- `collector health-check`：CLI 汇总各子系统状态（供人工/脚本排查）。
- App 侧诊断导出（第 14 章）；collector 日志在 `~/Library/Logs/lyrimuse.log`。
- `MediaControlHealth`：App 侧对 media-control 二进制做可用性探测。

### 6. 音量横幅（VolumeMonitor）

CoreAudio 属性监听（不拦音量键不轮询 osascript），系统输出音量变化时在灵动岛闪音量横幅（经 NotchTransientCenter，第 05 章）。

### 7. 测试（selftest）

无 XCTest（无完整 Xcode）。`swift run lyrimuse-selftest` 跑手写 `expectEqual` 断言（歌词引擎/取色/偏移/本地化守卫等）；Go 侧 `GOTOOLCHAIN=go1.24.4 go test ./...`（默认 go 1.21 编译产物会被 AMFI 拒签、启动即死，repo CLAUDE.md 硬规则）。真机界面验证用只读方式：`swift lyrimuse/scripts/check-windows.swift` + `screencapture -l <窗口ID>`，**禁止** AppleScript/System Events 驱动界面（毁过用户数据）。

## 设置项

| 位置 | 项 | 影响 |
|---|---|---|
| 播放器 | 后台采集服务 | collector LaunchAgent 装/卸/状态 |
| 通用 | 开机启动 | App LaunchAgent |
| 账号→推送提醒 | 平台/URL/密钥 | 日报/周报推送通道 |
| （features.json） | dailyDigest/weeklyDigest(+source)、launchLyrimuseOnMusicOpen | 后台任务开关 |

## 与其它功能的交互

- kickstart 是全系统的「配置生效」机制（features 保存 0.5s 去抖、歌词管理编辑即时踢，第 11/14 章）——每次踢都短暂中断推送。
- 单实例锁与 build.sh 的重启流程是一对：反复部署期间新旧实例短暂共存正是当年磨缓存的场景。
- 日报/周报读的是收听数据（第 12 章），推送通道与账号页「推送提醒」共享配置。

## 数据与文件

- `bin/`：build.sh 产物的裸二进制暂存（collector/feishu-bot）。
- `~/Library/LaunchAgents/*.plist` 两份；`~/Library/Logs/lyrimuse.log`。
- digest 状态文件（已推送水位）；单实例锁文件。

## 代码锚点

| 主题 | 位置 |
|---|---|
| 构建部署 | lyrimuse/build.sh |
| 服务管理 | Settings/CollectorServiceManager.swift（`install` / `reconcileAfterLaunch` / `recordInstalledFingerprint` / `currentBinaryFingerprint`）、LyricsManager/CollectorControl.swift、LyrimuseCore/Local/LaunchdJobState.swift、CollectorStatus.swift |
| 单实例 | lyrimuse-collector/singleinstance.go |
| 联动唤起 | lyrimuse-collector/companionlaunch.go |
| 日报/周报 | daily.go、weekly.go、digest.go |
| 推送通道 | notify.go `buildNotifyPayload`、alerter.go |
| 健康检查 | healthcheckcli.go；App 侧 MediaControlHealth.swift |
| 音量横幅 | Settings/VolumeMonitor.swift |
| 网络观察 | networkobs.go |
| 自测 | Sources/lyrimuse-selftest/main.swift；scripts/check-windows.swift |

## 设计决策与已知坑

1. **`swift build` ≠ 已安装**：不跑 build.sh 的「验证」验证的是旧 App。
2. Go 必须 `GOTOOLCHAIN=go1.24.4`：默认工具链产物被 AMFI 拒签且症状像被测代码自己崩。
3. 单实例 flock 是数据完整性防线，不是优化——双实例互磨缓存有真实事故。
4. kickstart 被 launchd 节流（~10s），任何「频繁踢」的设计都要先过去抖。
5. App 与 collector 的 KeepAlive 策略刻意相反（前台工具 vs 无人值守服务）。
6. 界面验证只许只读手段（截图/读窗口状态），AppleScript 驱动界面是禁区（历史事故：误触「清空全部」、误关用户其它 App）。
7. 故障告警（连续失败推送）已整体下线——别按旧印象去找 ok()/fail()。
8. build.sh 的 kickstart 失败自愈（bootout+bootstrap）针对 LWCR 陈旧签名约束，是真实踩过的坑。
