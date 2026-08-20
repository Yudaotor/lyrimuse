# AGENTS.md

给 AI 助手（Claude Code / Codex 等）看的入口。面向用户的说明在 `README.md`，
仓库结构见那里的 "Project Layout" 一节，这里不重复。

这份文件只写**不读到就会做错事**的约束。每一条背后都有一次真实的翻车。

---

## 构建与验证

```sh
# Swift（App）—— 仓库根执行
cd lyrimuse && swift build                  # 只编译，不影响已安装的 App
cd lyrimuse && swift run lyrimuse-selftest  # 全部断言，失败以非零码退出
cd lyrimuse && ./build.sh                   # release 构建 + 重打包 + 重签名 + 重启

# Go（collector）
cd lyrimuse-collector && GOTOOLCHAIN=go1.24.4 go test ./...
cd lyrimuse-collector && GOTOOLCHAIN=go1.24.4 go vet ./...
cd lyrimuse-collector && gofmt -l .
```

**Go 的工具链已在 `lyrimuse-collector/go.mod` 里用 `toolchain go1.24.4` 钉住**（2026-08-20 加），所以裸跑 `go test ./...` 也会自动切到 1.24.4。下面这些命令仍显式带 `GOTOOLCHAIN=go1.24.4`，跟 `build.sh:137` 保持一致——它是 belt-and-suspenders：`GOTOOLCHAIN=local` 会绕过 go.mod 那一行。原因 `build.sh:123`
的注释里写着：系统那个 Go 1.21 产出的二进制缺 `LC_UUID`，AMFI 会拒签。表现是先报
`missing LC_UUID load command`；加 `-ldflags=-linkmode=external` 绕过之后变成启动即
被 SIGKILL、日志一个字节都没有。

**它看起来完全像是被测代码自己崩了。** 2026-08-15 就是这样把一次成功的修复误判成
"修复不成立"，做了"好配置"对照实验才排除。注意这条知识当时已经在仓库里了——只是埋在
581 行 shell 的第 123 行注释里，没被读到。

**`swift build` 通过 ≠ 用户桌面上的 App 更新了。** 真机验证前必须跑 `./build.sh`
（它做 release 构建、重新打包 `.app`、重新签名、通过 launchd 重启）。

**没有 XCTest**（这台机器没有完整 Xcode，`swift test` 报 "no such module"）。Swift 侧的
测试全部在 `Sources/lyrimuse-selftest/main.swift`，是手写的 `expectEqual` 断言。
往里加断言时注意：**文件末尾是失败汇总 + `exit()`**，追加到文件尾部的代码永远不会执行，
新断言要插在汇总之前。

---

## 验证纪律

**不要用 AppleScript / System Events 驱动界面来做验证。** 这个项目为此出过两次事故：
盲发 `Cmd+W` 关掉了用户当时正在用的另一个 App；为验证列宽对着窗口连点几十次，触发了
"清空全部"，把 852 条歌词缓存清到 19 条、无备份。

替代手段（都是只读的）：

```sh
swift lyrimuse/scripts/check-windows.swift --require-overlay   # 窗口是否真的在屏
screencapture -x -o -l <窗口ID> /tmp/shot.png                   # 只截那一个窗口
```

`screencapture -l <窗口ID>` 是**强制**的：按坐标截屏会把别的窗口拍进去，2026-08-14 曾因此
截到用户的聊天软件窗口（同事姓名和消息）。窗口 ID 从上面那个脚本拿。

**不要碰真实的 launchd 服务**（`com.lyrimuse.collector` / `me.yudaotor.lyrimuse`）来做
实验——停掉 collector 就没有歌词了。要验证 launchd 行为用：

```sh
./lyrimuse/scripts/probe-launchd.sh --parse
```

它用自己的一次性 job 造出 running / 已退出 / 未注册三种状态，跑完自动注销并核对真实服务
没被动过。

排查"歌词为什么不出来"先跑这个，别上来就翻日志：

```sh
/Applications/Lyrimuse.app/Contents/Resources/collector healthcheck -local-only  # 快，不联网
/Applications/Lyrimuse.app/Contents/Resources/collector healthcheck              # 含五源探测，约 30s
```

**`lyrimuse/scripts/uninstall.sh` 是这个仓库里唯一会删用户数据的脚本，不要随手跑它。**
不带参数是只读报告（安全）；`--services` 会真的把 collector 停掉；`--purge` 会删掉歌词
缓存（含用户手工修正过的内容，不可逆）。改它之后跑 `uninstall_test.sh` ——那个测试搭一套
假家目录 + 一次性 probe job，走同一份代码路径，并核对真实环境没被碰。

**动播放器之前先存状态、之后必须恢复。** 需要真的播一首才能验证时（歌词渲染、性能采样），
先读当前 `player state` 和 `player position`，测完恢复原样。`tell application "Music"`
会**启动**没在运行的 Music，所以任何 `tell` 之前先 `pgrep -x Music` 守卫。

---

## 分层边界

- **`LyrimuseCore` 不 import SwiftUI**（27 个文件，零 SwiftUI）。这条边界
  是刻意的：纯逻辑放进来才能被 selftest 覆盖。所以接缝画在数值上而不是 SwiftUI 类型上 ——
  `KaraokeFill` 返回 intensity `0…1` 而不是 `Color`，`WrapLayoutMath` 吃 `[CGSize]` 吐
  `[Placement]` 而不是碰 `Subviews`。
- **`XxxxView.swift` 里不放几何/数学**。这类逻辑历史上反复出 bug（填色提前跑到下一个字、
  渐变 stop 在同位置打架、长行被压成一串省略号），而混在 View 里时除了盯屏幕没有别的验证
  办法。下沉到 Core，UI 层只留薄薄一层绑定。
- **collector（Go）只读 `config.json`，从不写回**；写入方是 Swift 侧的 `ConfigStore`。

---

## 容易踩的具体坑

**本地化**：`Localizable.strings` 里**中文原文就是 key**。只加中文那份、忘了英文那份，
英文界面会静默显示中文，编译不报错。改完用 key 集合对比两份文件确认没有一边独有的。

**歌词打分**：`match.go` 的分值不是拍脑袋定的，注释里记着消融实验结论（例如"按来源加分
改变了 69/206 首歌的冠军，其中 0 次变对、6 次变错，去掉后准确率 93%→96%"）。改分值前先读
那些注释。改了打分逻辑要同步 `lyricsScoringVersion`（`match.go:294`），否则老缓存条目不会
被后台重新裁决。

**enrich 缓存的 key** 一律经 `enrichKey()`（`enrichkey.go`）构造，Swift 侧镜像在
`EnrichCacheKeys.swift`，两边必须同步。同一首歌的两种写法曾经产生两条缓存 + 两份歌词文件，
表现为"Spotify 和 Apple Music 播同一首歌进度不一样"。

**`launchctl print` 的退出码表示"这个 job 注册过"，不表示进程在跑**。判断真实状态用
`LaunchdJobState` / `LaunchdPrintParser`。解析时注意同一份输出里同时有 `\tstate = `、
`\t\tstate = `（嵌套）和 `\tjob state = `（另一个字段），`contains` 会读错；`last exit code`
的值形如 `78: EX_CONFIG` 而不是纯数字。

**某个歌词源整个哑掉时，先分清是「被拦」还是「连不上」**。被反爬拦会正经返回 401 +
`hint=captcha` 的 JSON；而 2026-08-15 那次 musixmatch 失效是系统 DNS 把域名解析到了别人的
地址（`apic-appmobile.musixmatch.com` → Facebook 的段），TLS 握手当场失败、一个字节都拿不到。
判据：`curl --resolve <域名>:443:<DoH 查到的真实IP>` 能不能通。修法见 `doh.go`。
这类故障的代价不止"少一个源"——每首歌都要把 DNS/TLS 超时白等一遍。

**KeepAlive 的 launchd job 必须 bootout，不能只 kill**——kill 掉 launchd 立刻拉起来。

**Bash 工具跑的是 zsh**：遍历一组东西用数组（`a=(x y z); for i in "${a[@]}"`），
别写 `for i in $var`（zsh 不做单词分割，整串当一个元素，循环只跑一次且不报错）。

---

## 提交

- commit message 用英文，正文写清"为什么"，不只是"改了什么"。
- 提交前跑一遍：`swift build`、`swift run lyrimuse-selftest`、
  `GOTOOLCHAIN=go1.24.4 go test ./...`、`gofmt -l`。
- 分支策略：新功能推 `dev`；`main` 只在发版时推进（默认分支仍是 `main`，打 tag 前
  先把 `dev` 以 fast-forward 合进 `main`）。
- 发 release 时日志要手写改动清单（中英双语），不要只依赖 GitHub 自动生成的 notes。

---

## 功能现状文档（docs/features/）

`docs/features/` 是全项目的功能现状文档（as-built spec）：15 章按功能域覆盖每个功能的
行为、交互点、边界与代码锚点，索引见 `docs/features/README.md`。

- **改任何功能前**：先读对应章确认现状（哪些行为是刻意设计、有哪些交互点会被牵动）。
- **改完行为后**：同一次改动里更新对应章的相关小节，并刷新章头「最后核对」日期与基线
  commit。只改实现不改行为的重构不用动文档（锚点失效除外）。
- 新功能归入最相关的章；确实是新领域再开新章并在索引登记。
- 文档里只写现状：不留 TODO/计划；拿不准的行为标 `⚠️待核对`，绝不臆测。
