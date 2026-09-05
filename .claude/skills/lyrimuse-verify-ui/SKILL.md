---
name: lyrimuse-verify-ui
description: "lyrimuse 真机验证 / on-device UI verification — 改完 App 界面（悬浮歌词、灵动岛、菜单栏、设置页、歌词窗口）要在真机确认效果、截图、验 launchd 行为，或需要真的播一首歌时用。只写步骤与判据，理由回链 AGENTS.md。"
---

# lyrimuse 真机验证

> 只写步骤与判据；每步「为什么」一句 + 链接，正文不复述。约束本体在 [AGENTS.md「验证纪律」](../../../AGENTS.md)。

**硬规则先行：不用 AppleScript / System Events 驱动界面做验证。** 盲发 Cmd+W 关过用户正在用的别的 App；对窗口连点触发过「清空全部」，把 852 条歌词缓存清到 19 条、无备份（AGENTS.md「验证纪律」开头两段）。下面的手段全部只读。

## 步骤

1. **先确认没有别的会话在跑 build.sh**：`pgrep -fl '[b]uild\.sh'`。有就等它结束，期间不要保存 `lyrimuse/Sources`、`lyrimuse-collector`、`lyrimuse/Localization` 下的文件——release 构建中途文件变了会失败或装进半成品（[docs/releasing.md](../../../docs/releasing.md)「发布前验证」第一条同一理由）。
2. **装机**：`cd lyrimuse && ./build.sh`。release 构建、重打包、重签名、重启 /Applications 里那份——用户手头正在用的就是它，所以第 1 步的「没人在构建」必须先确认；`swift build` 通过 ≠ 装好了（AGENTS.md「构建与验证」）。记下它印出的 App / collector pid，验证后报给用户。（2026-09-05 曾有并排安装的「Lyrimuse Dev」，2026-09-06 用户拍板整体回退，15 章决策 12。）
3. **确认窗口在屏**：`swift lyrimuse/scripts/check-windows.swift --require-overlay`，拿窗口 ID 与 onscreen 状态。脚本只读。
4. **只截那一扇窗**：`screencapture -x -o -l <窗口ID> <scratchpad>/shot.png`，再用 Read 看图。**不许按坐标截屏**——曾把用户的聊天窗口连同同事姓名一起拍进去（AGENTS.md「验证纪律」）。
5. **截图报 `could not create image from window` 时先看窗口 ID 量级**：check-windows 印的 ID 从 98xxx 掉回 900 那一档 = WindowServer 重启过，整机截图暂时失效、会自愈，**别去改代码找它**（AGENTS.md「验证纪律」同段）。两条退路：等几分钟重试；或改用 `ImageRenderer` 离线渲染同一视图（不需要屏幕权限，能构造真机抓不到的状态；渲染不出动画中间帧、不触发 onAppear），量不到的判据下沉 Core + selftest 钉死。**另一种成因（同一条报错、窗口 ID 量级却正常）：屏幕上有个待处理的系统权限弹窗 / 模态框挡着**——最常见是调用截图的终端进程还没被授「屏幕录制」权限时弹的 TCC 对话框。这时不是 WindowServer 的事，改代码、换 ImageRenderer 都没用，`screencapture` 会一直报同一句。判据：让用户看一眼屏幕有没有待点的弹窗，点掉后同一条截图命令立刻就成（2026-09-05 实测：用户点掉弹窗后原命令立即成功）。
6. **要验 launchd 行为**：`./lyrimuse/scripts/probe-launchd.sh --parse`，它用一次性 job 造 running / 已退出 / 未注册三态并自检真实服务没被动过。**不碰真实的 `com.lyrimuse.collector` / `me.yudaotor.lyrimuse`**——停掉 collector 就没有歌词了。
7. **要真的播一首歌才能验时**：任何 `tell application "Music"` 之前先 `pgrep -x Music`（`tell` 会把没开的 Music 启动起来）；先读 `player state` 与 `player position`，验完恢复原样（AGENTS.md「验证纪律」末段）。**⚠️ 播放会污染用户真实 Last.fm**：Dev 构建若也连了用户的 Last.fm，整首播完会 scrobble 一条到他真实收听历史、且不可撤销（只能让用户去 Last.fm 手删）。所以能跳秒 / 短播验到就别整首放；万一为验证整首播了，收尾主动提醒用户可能多了一条打卡、要不要去删（2026-09-05 实测：为截透明悬浮窗把「富士山下」整首放了一遍，收尾提醒了用户）。
8. **收尾核对**：`find ~/Library/Logs/DiagnosticReports -newermt '-5 minutes' -name '*yrimuse*'` 应为空；`log show --last 3m --predicate 'subsystem == "me.yudaotor.lyrimuse" AND messageType == error'` 应无新增 error（日志规范：AGENTS.md「容易踩的具体坑 → 日志按业界通用范式写」）。
9. **不要跑 `lyrimuse/scripts/uninstall.sh` 做验证**：它是仓库里唯一会删用户数据的脚本，`--purge` 不可逆（AGENTS.md「验证纪律」）。

## 相关文档

- [15 章 运维与后台](../../../docs/features/15-ops-background.md)：§1 build.sh 一条龙、§2 两个 LaunchAgent、§5 健康检查与诊断。
- [14 章 设置与配置](../../../docs/features/14-settings-config.md)：§7 诊断导出。
