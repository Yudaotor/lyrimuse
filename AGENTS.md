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
cd lyrimuse && swift run lyrimuse-selftest --filter lastfm -q  # 只跑一组（--list 看组名）
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
测试在 `Sources/lyrimuse-selftest/`，是手写的 `expectEqual` 断言，**按领域拆成十几个
`XxxTests.swift`**，每个文件一个 `runXxxTests()`，由 `main.swift` 里的 `groups` 注册表按顺序
调用（`main.swift` 只放注册表、参数解析、汇总；断言函数与计数器在 `Harness.swift`）。
加断言：已有领域就写进对应文件的 `runXxxTests()` 函数体里；新领域就新建一个文件 + 函数，
再到 `groups` 里加一行 —— 忘了加会被「注册表守卫」当场 FAIL（它扫目录里所有 `run…Tests()`
定义逐个核对）。**不要把断言写进 `main.swift`**，也**不要建子目录**：好几条守卫靠 `#filePath`
往上数目录层数定位仓库文件。`--filter <组名子串>` 只跑一组、`--quiet` 只留 FAIL 与每组一行
汇总、`--list` 列出全部组；`--filter` 一组都没匹配上退出码 2，不给假绿。

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

**但它会整机失效，别把它当唯一验证手段。** 2026-08-22 实测：`screencapture -l` 对**本机
所有**窗口一律报 `could not create image from window`，而 `check-windows.swift` 明明报
`onscreen=true`、`kCGWindowSharingState=2`（可被截图），同一条命令二十分钟前还成功过，连
自己临时起的探针窗口也一样截不到——跟被截的 App 和当次改动都无关。

**是 WindowServer 的状态问题，会自愈，别去改代码找它。** 同一天后来自己恢复了，而且有个
现成的判据：`check-windows.swift` 印的窗口 ID **从 98xxx 掉回 900 那一档**，说明 WindowServer
重启过（同时 CGWindowList 的 bounds 读数也会开始/停止带那个 ~2% 缩放偏差，见上面那段）。
所以撞到这个错误时先看窗口 ID 的量级，再决定是等一等重试还是走下面的退路——两条退路：

- 自己写 ScreenCaptureKit 工具**走不通**：`swift xx.swift` 解释模式下撞
  `Assertion failed: (did_initialize), CGS_REQUIRE_INIT`（没有 WindowServer 连接，得
  `swiftc` 编译并 `_ = NSApplication.shared`）；编译过了又是 `SCStreamErrorDomain
  Code=-3811`——临时二进制没有 bundle identity，拿不到屏幕录制权限。
- **能用的是 `ImageRenderer` 离线渲染**（`project_nowplaying_swiftui_offline_render_verification`
  那条路）：纯进程内渲染成 CGImage，不需要任何屏幕权限，还能**构造**真机上抓不到的状态、
  跑同一视图的 A/B 对照。代价是渲染不出动画中间帧、也不触发 `onAppear`（靠 GeometryReader
  回写 `@State` 的东西量不到），那部分改用"把判据下沉进 Core + selftest 钉死"来覆盖。

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
- **设置页 UI 只用 `Settings/SettingsDesignSystem.swift` 那套组件，选用顺序固定**（2026-09-03 成文）：
  页面容器 `SettingsPage`（页头要自己画用 `SettingsPageCustomHeader`，顶部要钉分段/预览用
  `SettingsPageWithStickyHeader`）→ `SettingsCard`（一张卡一个意图，卡标题 `SettingsCardHeader` + `CardDivider`）
  → `SettingsRow`（前导图标 + 标题 + 副标题 + 尾部控件，行间 `CardDivider` 手插）→ 从属项 `SettingsSubRow`
  → 操作之后才冒出来的提示 `SettingsNote` → 这几样都塞不进才 `SettingsRawRow`。设置页里**不写裸
  `Toggle`/`Picker`/`Form`/`.formStyle(.grouped)`**；同一行放多个控件照「全局时间轴偏移」那一行的 HStack
  写法；尾部控件一律 `.labelsHidden()`；破坏性按钮用 `DestructiveButton`，滑杆用 `SteppedSlider`；文案经
  `L10n.t`、不加句尾句号。为什么是这套、每一条背后的实测都在那个文件的头注里，这里不复述。
- **macOS 26 才有的 API 一律 `#available(macOS 26.0, *)` 门控，旧系统退回改版前的外观、不做模拟**。
  部署目标是 macOS 14，而 CI 跑在 macos-26 —— 没门控的 `.glassEffect`/`.glass`/`.glassProminent`/
  `GlassEffectContainer` 在 CI 编得过、在用户的 macOS 14 上启动即崩，没有别的机制拦它。液态玻璃只经
  SettingsDesignSystem 的入口（`settingsCardBackground` / `settingsGlassButtons` / `settingsProminentGlassButton`
  / `clearGlassCapsule` / `SettingsGlassContainer`）；展示面（悬浮歌词 / 灵动岛 / 歌词窗口）自己套玻璃时
  同样门控，现有唯一例外是 `LyricsOverlayView.overlayCapsuleBackground`。selftest contracts 组有闸：这些
  API 的调用点只允许出现在这两个文件里，且文件里必须有那句 `#available`。

---

## 容易踩的具体坑

**新增 `np:` UserDefaults 键**：会**自动**进配置导出 / iCloud 搬家镜像 —— 那是**前缀白名单**制，
不是逐键登记（见 `ConfigPortability.exportableAppSettings`）。也就是说加一个键 = 默认把它搬去新
机器。落键前判一次「这是这个人的偏好，还是这台机器的状态」：后者（屏幕坐标、LaunchAgent 安装态、
一次性引导标记这类）才写进 `machineLocalDefaultsKeys`；删键时写进 `obsoleteDefaultsKeys`。判错
不报错，表现是新机器上「界面在说一件不成立的事」。

**本地化（三语：简体 = key、英文、繁体，2026-09-03 用户定）**：`Localization/Localizable.xcstrings`
是唯一真源，中文原文就是 key。**新加或改任何面向用户的文案，必须在同一次改动里把当前支持的
所有语言写全**：`en` 和 `zh-Hant` 都不能缺（zh-Hans 可省略，值即键），占位符三语一致；繁体按
`Localization/zh-Hant-STYLE.md` 写（台湾软件用语 + Apple 词表，**不是**字级简繁转换）。写完跑
`python3 Localization/generate-strings.py`，把三份生成的 `.strings` 一起提交。缺任何一种语言：
生成脚本直接失败并列出缺的键、`scripts/check_strings_parity.py` 红、selftest 本地化守卫红 ——
静默回退（英文界面冒中文、繁体界面冒简体）正是这套守卫要消灭的事故。以后再加语言，同样的
规则整套照做：TARGETS、`UILanguage`、两个语言选择器、`build.sh` 拷贝、守卫，并把全部既有键补齐。

**第三方声明与对外请求说明**（2026-09-03）：随包分发的每个依赖（`Package.resolved` 的 SPM 包、
`build.sh` 里 `brew install` 进包的东西、collector 的 Go 模块）都必须在仓库根 `THIRD_PARTY_LICENSES`
里有一条，`scripts/check_third_party_licenses.py` 机械对一遍（CI 也跑）；BSD/MIT 的分发条款要求随附
许可证文本，这个文件由 `build.sh` 拷进 `Contents/Resources/`，设置「关于 → 第三方许可」打开的就是它。
**新增一处对外请求**（新歌词源、新的封面 / 翻译后端、新的第三方服务）时，同一次改动里把 README 中英版
「许可与版权说明」那一节的清单和 01 章「许可、版权与对外请求」那张表补上——那一节对用户承诺的是
「会离开你 Mac 的只有这些」，漏一条就是承诺失实。说明正文只在 README 维护，App 里两处入口都只是链接。

**歌词打分**：`match.go` 的分值不是拍脑袋定的，注释里记着消融实验结论（例如"按来源加分
改变了 69/206 首歌的冠军，其中 0 次变对、6 次变错，去掉后准确率 93%→96%"）。改分值前先读
那些注释。改了打分逻辑要同步 `lyricsScoringVersion`（`match.go:294`），否则老缓存条目不会
被后台重新裁决。**改完必须过回归金标集**：`GOTOOLCHAIN=go1.24.4 go test -run 'TestLyricsGolden|TestGolden' .`
（`lyrimuse-collector/testdata/lyricsgolden/`，18 首真实曲目覆盖 19 类判据、置乱正文、断言冠军与全部分项，
冠军的正确性由一组独立判据证明而不是"缓存里就是它"）。
分项快照变了用 `LYRICS_GOLDEN_UPDATE=1` 重生成并把 JSON diff 一起提交；**冠军/判决变了**还要
`LYRICS_GOLDEN_ACCEPT_SEMANTIC=<样本id>` 逐首点头，不许静默改写。新加一条判据 = 在
`goldenRequiredCategories` 加一类 + 采一首样本，用法见那个目录的 README（09 章「歌词搜索回归金标集」）。

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
- 分支策略：**本地所有改动直接做在 `dev` 上、直接提交到 `dev`** —— 不要为一次改动新建
  feature 分支，也不要开 `worktree-*` 分支（2026-08-22 定）。这条是给 AI 会话的：不少
  harness 默认「动手前先隔离到一个新分支/worktree」，结果改动落在一个作者根本不看的分支上，
  还平白多出一次合并，而这个仓库本来就只有作者一个人在 `dev` 上推进。需要临时隔离时可以用
  worktree，但收尾必须把改动落回 `dev` 再提交、别把分支留下。`main` 只在发版时推进（默认
  分支仍是 `main`，打 tag 前先把 `dev` 以 fast-forward 合进 `main`）。
- 发 release 时日志要手写改动清单（中英双语），不要只依赖 GitHub 自动生成的 notes。
- **发版按 [docs/releasing.md](docs/releasing.md) 的 checklist 顺序执行**——从写日志、同步
  README/截图/llms.txt/About，到验证、打 tag、cask 与 Sparkle 实测、issue 收口，每条都带着
  v1.5.0 实录的坑；别凭记忆走流程。
- **tag annotation 的双语正文两种写法都行**：①显式标记式——`<!-- lang:en -->` 英文整块 +
  `<!-- lang:zh-Hans -->` 中文整块（标记是 HTML 注释，GitHub Release 页渲染时隐藏，两段
  依旧依次完整显示；裸版本号那行放标记前，语言中立）；②传统的逐条中英交错式（英文行在前、
  中文行两空格缩进跟随，v1.5.0 那份就是）。`release.yml` 的 `Generate signed appcast` 那步
  统一调 `.github/scripts/split_release_notes.py` 拆分：有标记按标记拆（作者拆的比启发式准，
  优先），没标记按行内 CJK 占比启发式拆——**改了交错式的行文习惯（比如英文行里大段夹中文）
  要回脚本核一遍 0.25 的阈值**。拆出的两份会被渲染成真 HTML（标题/列表/加粗/链接/表格、
  CJK 感知的硬换行合并——Sparkle 的说明 WebView 渲染 HTML 不渲染 markdown，2026-09-03 之前
  塞 `<pre>` 的观感就是用户在 v1.5.0 升级弹窗里报的那个「句子中间断行 + 裸 markdown」），
  生成 `<description xml:lang="en">` / `xml:lang="zh-Hans">` 两份——Sparkle 的
  `SUAppcast.m`（`bestNodeInNodes:name:`）按系统语言偏好选一份，更新弹窗正文从此跟随系统
  语言（弹窗外壳本来就是）。**两种格式都拆不动时自动退回单份 `<description>`，不会报错、
  不会卡发布**——但也就没有语言切换。v1.5.0 的 appcast 是事后手工补的
  `<sparkle:releaseNotesLink xml:lang>` 资产（同一机制的链接形态），从 v1.5.1 起走上面这条
  自动路径。

---

## 功能现状文档（docs/features/）

`docs/features/` 是全项目的功能现状文档（as-built spec）：15 章按功能域覆盖每个功能的
行为、交互点、边界与代码锚点，索引见 `docs/features/README.md`。

- **改任何功能前**：先读对应章确认现状（哪些行为是刻意设计、有哪些交互点会被牵动）。
- **改完行为后**：同一次改动里更新对应章的相关小节，并刷新章头「最后核对」日期与基线
  commit。只改实现不改行为的重构不用动文档（锚点失效除外）。
- 新功能归入最相关的章；确实是新领域再开新章并在索引登记。
- 文档里只写现状：不留 TODO/计划；拿不准的行为标 `⚠️待核对`，绝不臆测。
