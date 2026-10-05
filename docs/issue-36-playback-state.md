# Issue 36：失焦播放器的播放状态

## SPEC

### 背景与目标

QQ 音乐与浏览器视频同时存在时，依次暂停音乐、暂停视频、恢复视频，Lyrimuse 会通过按播放器查询的回退路径显示 QQ 曲目。QQ 暂停后的 MediaRemote 元数据仍可能保留 `playbackRate=1`；这不等于播放器仍在播放。把它解释成播放会导致歌词、进度和收听记录继续推进。

目标：回退查询必须把目标播放器自己的播放状态与元数据速率分开，暂停的 QQ 曲目不能因浏览器恢复播放而被恢复；同一修复作用于 App 与 collector 的共享 helper。

### 范围与场景

1. QQ 在播放、浏览器占用系统播放焦点：回退查询 QQ 自己的状态与元数据；确实在播放才外推。
2. QQ 暂停、浏览器视频恢复：QQ 仍显示暂停，冻结位置取 QQ 的锚点，歌词和收听进度不继续推进。
3. QQ 自己恢复：再次读到可信播放状态或重新获得系统焦点后，沿用现有读取路径恢复显示真实位置。
4. 其他内置播放器走同一 helper 时适用同一状态契约。Apple Music/Spotify 的 AppleScript 优先级不变。
5. 酷狗的单曲循环兼容继续有效：只有共享播放器表中 `playingFromRate` 为真的播放器，才允许在已知暂停状态下使用其非零速率兼容已有行为；不能推广到 QQ、Amazon 或未知播放器。
6. 播放状态不可读取：回退查询失败，不制造播放或暂停状态；现有短宽限后清空，回退开关按现有失败语义关闭，后续接受到播放器快照时恢复。

### RULE 与不变量

| ID | 义务 |
|---|---|
| R1 | 状态与元数据必须查询同一个目标 client，不能借用系统焦点的状态。 |
| R2 | 普通播放器的暂停、停止、中断状态优先于残留速率；暂停位置不按墙钟推进。 |
| R3 | 可信播放状态才允许位置按元数据锚点和速率外推；缺失速率不把已知播放状态改成暂停。 |
| R4 | 接口缺失、超时、Unknown、Seeking 或未识别状态都属于查询失败，不退回速率猜测。 |
| R5 | 酷狗的既有速率兼容仅由 `shared/players.json` 的生成配置准入，并且要求状态查询成功且状态已知；停止/中断不能被速率复活。 |
| R6 | App 和 collector 消费同一 helper 归一化结果，不各自重新推断播放状态。 |
| R7 | 封面和待播队列读取不依赖新增的播放状态接口，既有形态保持兼容。 |
| R8 | 不把本修复变成全局焦点控制：失焦且无安全定向控制通路时继续拒绝播放控制；状态查询失败停止读取但不解除控制保护，只有接受到可信系统快照后才解除。 |

### 失败、并发和资源语义

- 状态与元数据读取没有原子快照保证；二者并发查询同一 client，不新增锁、持久缓存或跨进程恢复状态。
- 读取 clients 的等待上限仍为 900ms；目标元数据与状态共用一个 900ms 等待截止时间，而不是每个查询分别等待 900ms。
- Swift/Go 的状态子进程整体超时仍为 2 秒。超时或缺失符号返回既有 `null`/nil 失败，不阻塞主线程、不新增控制路由；查询失败后不能把停止读取当成焦点恢复。
- 不增加新的常驻进程、权限要求、公开快照字段或系统焦点操作。
- 暂停后元数据锚点自身可能滞后，本 PR 不保证采样原子性或修复播放器本身的锚点精度。

### 非目标与取舍

- 不实现 QQ、网易云、酷狗、汽水、KKBOX、Amazon 的失焦播放控制，不取消防误控保护。
- 不改系统焦点选择、多选准入、浏览器歌曲识别、进度伺服或歌词算法。
- 不使用辅助功能模拟点击，不要求额外权限，不安装或覆盖用户正在使用的 App。
- 不保证每个 macOS/播放器版本均支持私有状态接口；不可用时安全退化为查询失败，而不是恢复错误速率推断。
- 失焦控制可行性实验中，无身份约束的命令观察到误落系统焦点；有曲目身份约束时，失焦 QQ 播放/暂停返回错误 7，QQ 保持暂停，浏览器继续播放。因此不以“命令返回成功”冒充定向控制成功。

### 验收标准

| 义务 | 证据 |
|---|---|
| R1、R2、R6 | native 测试模拟暂停 QQ + 非零速率，实际 helper 输出暂停且位置冻结；Swift/Go 消费契约回归。 |
| R2、R3 | native 测试覆盖 Playing/Paused/Stopped/Interrupted、速率缺失和非单位速率。 |
| R4 | native 测试覆盖 Unknown/Seeking/未知值、缺失状态函数、未完成回调。 |
| R5 | native 测试覆盖已准入的速率兼容及普通播放器不准入；Swift/Go 参数传递使用既有生成配置。 |
| R7 | native 测试覆盖封面查询不要求状态函数；待播队列分支仍独立。 |
| R8 | 焦点 authority 的成功→失败→可信恢复判据及控制路由回归；既有拒绝/AppleScript 路由检查保持通过；真实失焦控制调查结果如实记录，不声称本 PR 修好按钮。 |
| 用户场景 | 真实 QQ 暂停、浏览器持有焦点时，对比修复前/后的 helper 输出，并确认用户播放状态未被修改。 |

## 当前设计

### 数据流与 authority

`MediaControlClient.snapshotAfterFocusLost` / `focusFallbackProbe` → Perl loader → native per-client 查询 → 归一化 JSON → Swift `MediaControlSnapshot` / Go 状态 → 既有进度与歌词消费路径。

| Rule/state/resource | Authority | Interface/seam | Callers |
|---|---|---|---|
| client 播放状态、暂停冻结、外推、状态未知失败 | `native/nowplaying-clients/nowplaying-clients.m` | 同 client 的状态/元数据查询及归一化 JSON | Swift probe、Go probe |
| 可使用速率兼容的播放器名单 | `shared/players.json` | 既有生成的 `playingFromRate` 配置 | Swift/Go 向私有 loader 传递兼容选项 |
| 私有兼容选项到 native 参数的传递 | Perl loader | 状态模式 `rate-playing`；默认不开启 | Swift/Go 状态查询 |
| 查询失败后的宽限与回退开关 | 既有 Swift/Go 回退模块 | nil/空状态 | 播放源、collector |
| 失焦控制保护生命周期 | `MediaControlClient` | `shouldWithholdFocusControls`；复用既有 `fallbackTargetGone`，可信快照才清零 | `focusHeldByAnotherApp` → 控制路由 |
| 控制命令路由与拒绝 | `MusicPlaybackController` | `controlRoute` | 所有播放控制入口 |
| 状态查询时间上限 | native helper + 既有 `ProcessRunner`/Go context | 内部同一截止时间、外层 2 秒 | 所有状态查询 |

### 实现机制

- 动态读取 `MRMediaRemoteGetPlaybackStateForClient(client, origin, queue, callback)`，使用同一 client 读取元数据。
- 已知状态 1=Playing，2=Paused，3=Stopped，4=Interrupted；0/5/其他状态不归一化为有效快照。
- 只有状态模式要求该接口。封面与队列分支不因该符号缺失而失败。
- `rate-playing` 是 bundle 内部的调用选项，不新增持久状态或公开 JSON 字段。Swift/Go 只转交共享配置，不复写状态决策。
- 保持所有现有曲目、锚点、封面和队列字段的形态。暂停外推判据改为归一化后的可信状态。
- 控制保护用现有 `fallbackTargetGone` 区分“停止查询”与“焦点已可信恢复”。不增加新状态；快照接受路径清零该标志，所有控制入口继续调用原有共同路由。

### 验证状态

- 基线 Swift selftest 构建成功；播放相关 3 组、761 条断言通过，但未覆盖 native 暂停误判。
- 修复前实际 helper 连续三次把暂停在 20 秒的 QQ 报为播放并外推到 1000 多秒；独立 client 状态接口返回 Paused。
- 本机 macOS 27.0；QQ 实测受影响。Amazon 残留速率行为有仓库资料，其他播放器真实版本尚未逐一实测。
- 修复后实际 helper 对同一 QQ 曲目返回 `playing=false, elapsedTime=20, playbackRate=1`，没有操作播放状态。
- native 125 条检查通过；把状态输出临时变回速率判断的独立副本立即使回归失败，证明测试能拒绝旧误判。
- Swift selftest 全部 30 组、7529 条断言通过（含新暂停快照回放与失败后的控制保护）；Swift package 根目录的 sourcekit-lsp 检查无诊断。
- Go 定向回退测试（含 race detector）、`go vet ./...`、gofmt 检查通过。完整 `go test ./...` 唯一失败是既有 `TestDocsSourceCountMatchesSourceCount`（README 缺少期望的十二源措辞）；干净 `origin/main` worktree 同样失败，没有跳过这个测试冒充全绿。
- 完整 App 构建失败：本机 macOS 27 SDK 找不到 `SwiftUIMacros.StateMacro`；干净 main 使用同一工具链同样失败。selftest 产品构建已通过，不能据此宣称完整 App 构建成功。
- 播放器/声明行生成物、字符串一致性、第三方许可证、注释卫生和 `git diff --check` 通过。
- 新 pane 的 GPT-6.1 Sol 独立 review 和最终 re-review 已完成，最终没有未处理 findings。失败后控制保护的生产判据/路由回归通过；恢复旧判据的临时副本会违反拒绝义务。
- 其他真实播放器与其他 macOS 版本未做完整兼容矩阵；未运行修复版 GUI 的完整端到端场景。远端 CI 以 PR checks 为准；AI review 不代替维护者 approval。
