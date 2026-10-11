# 网易云失焦播放控制：SPEC 与设计

基线：QQ PR [#45](https://github.com/Yudaotor/lyrimuse/pull/45) 的最终提交 `71ab5891`，该 PR 仍待合并。本分支 `feat/netease-unfocused-controls` 在独立 worktree 中叠加网易云改动；未来提交上游仍以 `dev` 为目标，先处理对 QQ PR 的依赖。

## SPEC

### 问题、范围和目标

浏览器等 App 占用 macOS Now Playing 焦点时，网易云的直查回退仍能显示歌曲，但全局媒体命令会控制占用焦点的 App。用户需要在歌词界面控制网易云的播放/暂停、下一首和上一首。

在实际接受的网易云直查回退、全局媒体控制受到保护时，三项操作直接按网易云自身菜单。保持网易云在后台，正常焦点保留既有通路；其它播放器的路由优先级及 QQ 随机/循环/喜欢能力不变。

### 场景与顺序

1. 已授权：网易云在放歌，另一个 App 持有系统媒体焦点，Lyrimuse 显示网易云回退曲目。用户通过任一已有播放控制入口操作，后台串行执行网易云菜单；结果与播放真值回读驱动现有展示。
2. 缺授权：相同前置状态，点击控制只反馈失败并打开播放器设置。用户主动通过已有授权按钮处理；授权后需要重新点击，不自动补发。
3. 正常焦点：网易云持有系统媒体焦点时仍走原媒体控制路径，基础控制不依赖新增授权。
4. 请求过程中换播放器：既有队列完成已选定的目标操作；完成回调不能改变新显示播放器的图标。不承诺取消已入队动作。
5. 连续操作：共用已有串行队列，每个点击只执行一次动作；成功不等于确认播放状态，异步回调不能反转已经回读的新图标。

### 不变量

| ID | 义务 | 失败结果 |
| --- | --- | --- |
| R1 | 目标来自实际接受的 direct-query 回退，不来自设置勾选或前台存在 | 无定向目标则保留保护 |
| R2 | 失焦网易云只支持三个已验证动作；进度跳转、未知命令仍拒绝 | 不发全局命令 |
| R3 | AX 指向目标 PID 的已启用、角色正确且支持 AXPress 的精确菜单 | 退出、未识别、禁用、AX 错误或超时均停止 |
| R4 | 不激活目标、不用坐标或全局按键、不回落全局命令、不重试动作 | 反馈未送出；超时可能已有动作落地，不假定无副作用 |
| R5 | AX 跨进程工作在已有串行队列，完成与失败展示在主线程 | UI 不等待 AX 调用 |
| R6 | AX 成功只表示请求送出；图标跟随回读并守住显示播放器身份 | 失败不乐观翻转；换播放器不污染新图标 |
| R7 | 复用实际运行 App 的 AX 授权，网易云说明只承诺三项 transport | 不在轮询中弹框或修改 TCC |
| R8 | QQ、Apple Music、Spotify、Kaset、其它来源的原通路保持 | 正常路径保留即时乐观反馈 |

### 失败、并发、资源与取舍

权限、进程与菜单失败由控制层标准化为缺权限或不可用，展示复用原有反馈。不会自动启动已退出的网易云；不会自动请求或修复授权。对超时不重试，因为动作可能已执行。

同队列维持既有命令顺序，不新增队列、状态、缓存或 pending-intent 模型。资源沿用 QQ 菜单算法：最多三层、顶层 20 项、下层各 32 项，读取预算 0.5 秒、每个元素消息超时 0.1 秒；预算到期后最多仍有一条已发消息在等待。资源边界不是整个队列端到端延迟保证。

只识别真机验证的简体菜单：网易云 3.1.13（3451）「控制 → 播放/暂停、下一个、上一个」；QQ 的既有标题保持。其它菜单语言或版本改名安全拒绝。上一首沿用播放器自身语义，不固定双击，不强求立即换歌。

非目标：失焦 seek、网易云随机/循环/喜欢/音量、原生 AppleScript 接口、改变焦点读取/选择策略、自动权限恢复、独立开发身份、持久化迁移。

## 当前设计

### 数据流与 authority

`MediaControlClient.focusControlContext()` → `MusicPlaybackController.controlRoute()` → `.menuAccessibility(player, command)` → 既有串行队列 → `PlaybackMenuControl.press(_:for:)` → 主线程 completion/失败反馈 → `PlaybackCoordinator` 与共享权限设置。

| 规则/状态/错误/资源 | Authority | Interface/seam | 调用方与证据 |
| --- | --- | --- | --- |
| 实际焦点/回退与保护状态 | MediaControlClient | focusControlContext | 控制路由；既有读链保持 |
| 目标与允许动作、脚本优先级 | MusicPlaybackController | controlRoute | 所有 transport 入口；纯路由测试 |
| 来源菜单、角色/启用/动作检查及 AX 预算 | PlaybackMenuControl | press(_:for:), Command | 控制队列；标题测试、人工测试 |
| 串行执行、单次动作与失败分类 | MusicPlaybackController | dispatchMenuAccessibility | 注入 press 的后台闸门/结果测试 |
| 播放真值与观感层完成处理 | LocalPlaybackSource / PlaybackCoordinator | 既有回读 / userTogglePlayPause | 真实 coordinator 源码回放 |
| 播放器需要权限 | shared/players.json | 生成 needsAccessibilityPermission | 设置/引导/体检；生成物与权限集合测试 |
| 权限用途 | PlaybackPlayer | accessibilityUse | QQ 菜单模式、网易云 transport、Amazon 进度各自准确说明 |
| 实际进程信任、主动授权/恢复 | AccessibilityPermission | 既有 request-once / guide | 引导/设置/AppDelegate；人工授权验收 |

### 实现机制

将 QQ 的 transport 菜单查找扩展为共同的 `PlaybackMenuControl`，精确标题按来源集中配置。控制层和 coordinator 使用同一 typed menu route，不复制网易云的队列、失败或图标逻辑。QQ 原有模式/喜欢 adapter 不调整。

新增 `.controlsPlayback` 权限用途，以免把网易云的三项控制误写成随机、循环、喜欢或进度校准。选中网易云或 auto 会通过已有共享权限入口显示授权说明，不引入新的系统权限类别。

### 义务到证据

| 义务 | 自动证据 | 必要人工证据 |
| --- | --- | --- |
| R1/R2/R8 | PlayerIdentity 路由矩阵、脚本优先级及保护/seek；保留现有全组回归 | 真正另一个 App 持有媒体焦点时操作 |
| R3/R4 | 精确标题/来源隔离和不支持动作测试；共享既有有界算法 | 网易云 3.1.13 的实际菜单、未暴露/退出失败 |
| R5 | 注入后台闸门与主线程回调检查，断言目标/命令与单次尝试 | 真面板响应与前台保持 |
| R6 | 实际 coordinator 方法源码回放，两个来源覆盖读/完成次序、失败、换播放器和连续操作 | 实机回读与图标 |
| R7 | 生成物、权限集合和用途测试；三语本地化校验 | 当前测试 App 真正授权与缺授权流程 |

## 验证状态与人工门禁

已通过完整 App 编译、Swift selftest（36 组、12,302 断言）、两来源 coordinator 源码回放（20 checks）、native nowplaying-clients（178 checks）、完整 Go 测试、两种 vet、gofmt、deadcode、生成物、本地化、许可、注释和 whitespace 检查。SourceKit 对菜单 adapter、controller、onboarding 三个修改文件报告 0 diagnostics。临时破坏网易云路由、菜单标题和异步真值分支均使现有回归检查失败。完整 diff review 结果随人工测试候选交付；本次尚未推送或运行远端 CI。未执行不算通过。旧调研只证明后台菜单三项可用，不能代替另一个 App 持有系统媒体焦点的验收。

人工测试是本次停止点：需验证最终 App 自身授权、真实歌词窗/展开灵动岛控制、其它播放器播放及前台保持、缺授权和失焦 seek 拒绝。不得用 CLI 探针信任替代 App 信任，或仅凭系统同名条目勾选认定授权。测试包使用独立输出路径，保留现有安装包、测试包及偏好。不会在人工门禁前宣称完整实机验收或合并。
