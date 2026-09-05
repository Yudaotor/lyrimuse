# 15. 运行、部署与后台任务

> 最后核对：2026-09-03 · 基线：e103532+工作树

## 定位

这套软件怎么构建、安装、常驻、自愈，以及 collector 里跟播放/歌词无直接关系的周期性任务（日报/周报推送、健康检查）。

## 入口与展示面

- 开发者：`cd lyrimuse && ./build.sh`（唯一的真机部署路径）。
- 用户可见：设置 → 播放器 → 后台采集服务（状态/装卸）；账号 → 推送提醒；灵动岛音量横幅；`collector health-check` CLI。

## 行为规格

### 1. build.sh（构建+打包+部署一条龙）

`swift build`（release，可多架构）→ `go build` collector → 组装 `.app` bundle（collector、media-control、lyrics-translate、.lproj 资源全拷进 `Contents/Resources/`；media-control 缺失时经 Homebrew 自动装）→ 架构检查 → 签名（ad-hoc）→ 经 launchd **kickstart** 重启 App；kickstart 后无存活进程时自动 `bootout+bootstrap` 兜底（LWCR 陈旧 codesigning 约束的自愈）→ 重载 collector job（刷新 launch constraint）。**`swift build` 通过 ≠ 已部署**——真机验证必须跑 build.sh（repo CLAUDE.md 三大硬规则之一）。

**⚠️ collector 的版本号由这里注入（2026-09-02 加）**：`go build` collector 那步带
`-ldflags "-X main.clientVersion=$APP_VERSION"`，`$APP_VERSION` 就是写进 Info.plist 的那个值
（`LYRIMUSE_VERSION` 环境变量 → 最近一个 git tag → `0.0.0`），于是 App 与 collector 的版本号
**由构造保证同源**。装配完、swap **之前**还有一道**跑真实产物问版本**的一致性闸（执行刚打进包里
的 `collector version` 跟 `$APP_VERSION` 比，不一致直接 exit 1，绝不把这个包换进 /Applications；
交叉编译出不含本机架构的包时跳过并明说「没验」）。

  为什么光有注入不够：`-ldflags -X` **只能写 `var`，对 `const` 静默失败**——构建照样 exit 0、
  不报错不警告，值原封不动（2026-09-02 实测坐实）。也就是说注入这行「看起来在那儿」完全不代表
  它生效了，必须有一道验产物的闸。`lyrimuse-collector/build.sh`（本地只重建 collector）同样注入，
  但取值优先级刻意不同：它把产物直接拷进**已装好的** .app，所以第一顺位是那个 App 自己的
  `CFBundleShortVersionString`，而不是 git tag——本地 tag 完全可能落后于已装的 App，那时用 tag
  反而会亲手造出不一致。完整案情见第 9 条已知坑。

**⚠️ 组装不在 /Applications 里就地做（2026-08-31 改）**：`FINAL_APP_DIR` 定下最终位置后，整个装配过程在**同目录的兄弟暂存包** `.Lyrimuse.app.stage.$$` 里进行，最后用 APFS 的 `renamex_np(RENAME_SWAP)`（`/usr/bin/python3` + ctypes，一次原子 vfs 操作）整体换进去。起因是多会话并发：两个会话同时跑 build.sh，实测撞出过 `install_name_tool: cannot rename …(No such file or directory)` 和 `Bootstrap failed: 5: Input/output error`（launchd 拿到写了一半的 bundle，App 起来了、collector 没起来）。根因不是「安装那一步」没互斥，而是原来从 `APP_DIR=` 那行往下近 340 行**全部**在原地增删改签同一个包，整段都是不安全窗口。

  三个必须知道的细节：① **不能用 `mv`**——`mv 新 旧` 在旧目录已存在时不是覆盖而是**塞进去**（得到 `/Applications/Lyrimuse.app/Lyrimuse.app`），退出码 0、无输出、`set -euo pipefail` 拦不住，表现是「装完了但行为没变」；RENAME_SWAP 则没有任何「App 不存在」的窗口。② 换入后必须把 `APP_DIR`/`BIN` **重指回最终路径**，否则 restart 段三处 `pgrep -f "$BIN"` 和 `open "$APP_DIR"` 全部落空（进程命令行是 /Applications/…），脚本会永远判定「没起来」然后 exit 1。③ **media-control 的隐性兜底要显式补回来**：`brew` 里找不到它时那段拷贝被整个跳过，就地组装的年代旧子树原样留在包里等于「没动它」，暂存包里则压根不存在——不补的话 swap 会拿一个丢了 QQ 音乐支持的包覆盖掉本来完好的安装，而且只有一句 warning、退出码还是 0。现在在那个 else 分支里从现装包 `ditto` 继承一份，且**必须放在 codesign 之前**（签完再塞文件会破坏签名封印）。`--dest`（package.sh 用）**不套暂存**：它本来就装到自己的 mktemp 目录，不存在「替换正在使用的安装」这回事。

  ⚠️ **这只解决「安装」这一类冲突，不解决「构建」那一类**。多会话共用同一棵源码树时，`error: input file '.../Foo.swift' was modified during the build` 仍然会发生——那是 SwiftPM 在编译期发现输入文件 mtime/内容变了，跟产物往哪放毫无关系，只能靠「同一时刻只有一个会话在改+编这棵树」解决（打招呼，或各自用独立 worktree）。同理 launchd 重启竞争（两边各自 bootout+bootstrap 同一个 label，正是 `Bootstrap failed: 5` 的另一半成因）也没被这次改动覆盖。顺带把 `FAT_DIR` 从固定的 `.build/fat` 改成 per-run `mktemp -d`——那是同一族的共享可写路径，一个会话的 `rm -rf` 会删掉另一个刚 lipo 出来的切片，SwiftPM 的 `.build/.lock` 只锁 `swift build` 本身、管不到它。

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
- **companionLaunch**：打开所选播放器时顺带唤起 Lyrimuse（`features.launchLyrimuseOnMusicOpen`，默认开）；反方向（开 Lyrimuse 唤起播放器）在 App 侧。检测走 `pgrep -x <可执行文件名>`（不碰 AppleScript/自动化权限，所以对没有 AppleScript 支持的播放器同样生效），名字表在 `knownPlayerProcessNames`：`Music` / `QQMusic` / `NeteaseMusic` / `Spotify` / **`酷狗音乐`**（中文，`CFBundleExecutable` 实测值）。
  ⚠️ 酷狗这一项 2026-08-22 才补上——它接进 collector 时（`system.go`/`features.go` 都加了 `playerKugou`）漏了这一路，`playerProcessName()` 的 switch 没有 kugou 分支、落进 `default: return "Music"`，于是**选了酷狗的用户这个联动实际在盯 Music.app**：打开酷狗不会唤起 Lyrimuse，反倒打开 Apple Music 会；`knownPlayerProcessNames` 同样漏了它，「自动识别」档也盖不住。回归测试 `TestPlayerProcessNameCoversEveryPlayer` 双向钉住（每个播放器都有自己的名字 + 都在 auto 那份列表里），做过变异测试。
  ⚠️ 往名字表里加新播放器时要一起核**两件事**：① `pgrep -x` 能匹配非 ASCII 的 comm（拿中文名进程实测过，可以）；② UTF-8 字节数不超过内核 `p_comm` 的 16 字节上限（「酷狗音乐」是 12 字节，再长两个汉字就会被截断、`-x` 精确匹配当场失效）。
- 网络观察（networkobs）：解析全空时标记「网络不通」状态给 UI（歌词区显示网络提示而非「没歌词」）；`doHTTPTracked` 同时是（2026-08-26 起）collector 侧**所有对外请求**的统一审计日志出口，见第 14 章「对外请求审计日志」——一并接进来的调用点覆盖 Last.fm/ListenBrainz/七个歌词源/推送/状态中继/翻译/取色/MusicBrainz/iTunes，只有 DNS-over-HTTPS（`doh.go`）刻意排除在外（不是"联系了哪个外部服务"，是基础设施调用，理由跟它不参与 `networkLooksDown()` 统计一致）。

- **退出原因日志（2026-09-03）**：常驻 collector 的每一条退出路径退出前都打一行 `exiting reason=<code>`（`exitreason.go` 的 `logExit` / `fatalExit`，经 log.Printf → logscrub 出口）。原因码：`already_running` 拿不到单实例锁（退出码 0，等 KeepAlive 重试）/ `signal` ctx 被 SIGTERM·SIGINT 取消（kickstart 重启、bootout 卸载、Ctrl-C，**此前这条最常见的退出一行日志都没有**）/ `run_error` / `config_unreadable`（文件在但读不出；内容有问题已降级成 loadIssues 不退）/ `home_dir_unresolved` / `run_returned`（理论上到不了，记下来才看得见）。一次性子命令的 os.Exit / log.Fatalf 不在此列。App 侧同款前缀记在 `lifecycle` 分类（`AppExit.swift`）：`menu_quit` / `restart_after_config_change` / `sparkle_install`（`SparkleUpdaterManager.isInstallingUpdate` 认出）/ `sigterm` / `external_request`（⌘Q、Dock 退出、AppleScript、被新实例请走）/ `followed_player_quit`（「跟随播放器退出」宽限到点，见 02 章「与播放器联动」），新实例请走旧实例那一侧另记 `terminating older instance pid=… reason=older_instance_replaced forced=…`；所有主动 terminate 只准经 `AppExit.request`，日志在 `applicationShouldTerminate` 汇合点打一次。⚠️ App 对 SIGTERM 从「AppKit 默认直接死、delegate 都不叫」改成 `AppExit.installSigtermHandler` 用 DispatchSource 接住后走正常 terminate——顺带让 `applicationShouldTerminate` 里那次未保存配置的落盘也有机会跑到。新加一个原因码就补进这一条。⚠️ **已知盲区**：SIGTERM 落在 collector 启动阶段（`signal.NotifyContext` 装上之前——加载缓存 / lyrics 导入调和那十几秒）仍是 Go 默认处置、静默退出；2026-09-03 装机时 build.sh 连续两次重启都撞在这个窗口里，日志只有「loaded … caches」没有 exiting 行，第三次起完才正常。没把 NotifyContext 提前：提前后启动期收到的信号要等启动跑完才处理，超过 launchd 的 ExitTimeOut 就是 SIGKILL，得不偿失。selftest contracts 组「退出原因」守着两侧（App 的 terminate 只在 AppExit、AppDelegate 无 NSLog；main.go 无裸 log.Fatal、唯一 os.Exit 是锁那条）。

### 4. 日报/周报推送（可选，默认关）

- **daily.go**：每天到 `dailyDigestTriggerHour` 后的第一次检查（半小时一查）推一条当日收听摘要；按 `features.DailyDigestSource` 选数据源；状态文件记「已推送到哪一天」防重启重推。
- **weekly.go**：每周一条（2 小时一查），按 Last.fm 图表周或 ISO 周边界；状态文件记已推送周。
- **digest.go**：拼内容（Top 歌曲/歌手各取 `digestTopN` 条，Bark 锁屏预览要能读完；LB 翻页 100 条/页）。
  - **歌手归并（2026-08-30 加，此前完全没有）**：两条取数路径都按跟歌手榜（`topartists.go`）**同一套**口径归并再取 Top N。
    修之前 digest 直接把接口返回的歌手原样取前 N，于是同一个二进制里同一个人在推送里是两个、在榜单里是一个（实测这台机器 389 个歌手写法里 1 例真的踩中：`张震岳`/`张震嶽`）。
    - Last.fm 路径：`digestTopArtists` → `mergeAliasedArtists`（名字键 + mbid 并查集，走 `cacheOnlyArtistIdentity`，**只读本地缓存、零网络请求**，不给后台推送加延迟）。
    - ListenBrainz 路径：LB 的收听记录里没有 mbid，并查集第二个信号用不上，只能按 `artistMergeNameKey` 分桶；展示名走 `artistMergeDisplayName`（只把已知罗马字艺名换成中文本名，**不**做繁简/大小写折叠——那两步只是判同一个人时内部用的，不该篡改用户库里原本的书写）。
    - ⚠️ **归并必须发生在截断之前**，否则被截掉那条的次数永远加不回本尊身上；且 `mergeAliasedArtists` 结尾的 `sort.SliceStable` 是取 Top N 的前提（合并会让次数相加、名次变动）。两条都有断言钉着（`digestmerge_test.go`），并做过变异验证。
    - 抽出 `digestTopArtists` 这个纯函数、而不是内联在 `lastfmDigestStats` 里，是因为后者要打网络、测不了：内联的话把归并那行删掉，单测照样全绿。
    - 已知取舍（用户拍板）：合并后名次/次数会跟**历史推送**对不上，接受——一次性台阶好过两处口径永久不一致。
- **notify.go/alerter.go**：推送通道，支持 Bark/钉钉(签名)/企业微信/Discord/飞书(签名)/Server酱（除 Server酱表单编码外都是 webhook+JSON 模子）。原「连续失败 N 次告警」能力已整体下线，alerter 只剩 push 载体。

### 5. 健康检查与诊断

- `collector healthcheck`：CLI 汇总各子系统状态（配置/歌词来源开关/缓存/导出目录/ListenBrainz·Last.fm 配置，外加真拿两首探测曲实测各歌词源可用性 + 网络整体是否看起来通），供人工/脚本排查；2026-08-27 起也被 App 侧诊断导出直接调用，见第 14 章。
- App 侧诊断导出（第 14 章）；collector 日志在 `~/Library/Logs/lyrimuse.log`，App 进程的 launchd stderr 在 `~/Library/Logs/lyrimuse-app.log`（2026-09-05 起分开，正常几乎为空）。排「为什么自己退了」：两侧日志 grep `exiting reason=` 即可（原因码表见 §3「退出原因日志」）。
- **不做「设置页实时日志视图」（2026-09-04，用户拍板）**：被参考的做法是调试页 300 条环 + 四级筛选 + 自动滚底。评估时实测两侧体量：collector 约 30 行/分，其中九成是 `api call` 审计行（Last.fm 每 5 秒轮询一次 `user.getrecenttracks`），App 侧约 10 行/分；300 条环不做入环折叠 10 分钟就被轮询行灌满。collector 走 Go 标准库 log 没有等级字段，「四级筛选」只对 App 侧有意义。成本 M 且有常驻开销（文件 tail 处理轮转换 inode、OSLogStore 每秒增量查询必须在后台线程且本身有几秒延迟、逐行脱敏折叠、视图不在前台必须停流、约 10 条新文案 × 两种语言）。不做的理由：真实用户是作者自己排查，终端 `tail -f` + `log stream` 就是同一件事；普通用户走「导出诊断信息」贴 issue，实时看日志对他们不可操作；被参考项目做调试页是因为 Tauri 没有现成的日志查看途径，macOS 有 Console.app。若要「看一眼现在在发生什么」的入口，S 级替代是诊断与数据卡里加「在控制台中打开日志」用 Console.app 打开 collector 日志文件（自带实时跟随 / 搜索 / 过滤，零环形缓冲、零轮询、零脱敏责任）。**若将来推翻**：挂侧栏「实验室功能」折叠组不开顶层分类；入环前先按模板折叠再脱敏；collector 行统一当 info、筛选只分来源和 App 等级；视图离开即停两条流；OSLogStore 查询不进主线程；文件 tail 收到 rename / delete 按路径重开。
- **日志规范（2026-09-04）**：两侧日志按业界通用范式写——正文英文、`component: message key=value`、App 侧只走统一 subsystem 的 `Logger`（`NSLog` 的日志进不了诊断导出，`LanguagePackRow` 那两行就是这样漏掉的，同日改掉）。规则在 AGENTS.md「容易踩的具体坑 → 日志」，selftest contracts 组「日志规范」守着。当天把 collector 23 条、App 侧 21 条中文日志改成英文，翻这天之前的旧日志时中文关键词仍在。
- **日志出口重做（2026-09-05，用户拍板「全做」）**：起因是评估「设置页实时日志视图」时拿两天 40k 行真实日志数了一遍——63% 是 `api call` 逐次审计行（Last.fm 每 5 秒一次的 `user.getrecenttracks` 一项 4219 行）、同一首歌的 "reusing existing entry" 打了 1158 遍、ListenBrainz 超时重试串上千行、没有等级只能靠前缀 grep、时间戳是 UTC 却不带标记（当天就有人读错）；App 侧 24 小时 2152 行 **error 级**的 `overlay-debug`（08-29 标注「排查完就删」的临时探针）占落盘量一半，`snapshot failed` 把「Music 没开」记成 error 且尾巴是中文 `<private>`；两个 launchd 任务的 stderr 还写同一个文件，launchctl 子进程的报错没时间戳没来源地漏进 collector 日志（两天 59 次）。做了七件事：① collector 出口换标准库 `log/slog`（logsink.go）——`slog.SetDefault` 桥接，173 处 `log.Printf` 零改动按 Info 进链，行首 `time=<UTC RFC3339 毫秒 Z> level=… msg=…`，等级 config.json `log_level` / 环境变量 `LYRIMUSE_LOG_LEVEL`（优先）；⚠️ `slog.SetDefault` 会把 log 包的 flags 清零、由 handler 打时间，所以原来那句 `log.SetFlags(LUTC)` 删了，谁再加回来就是双时间戳。② 审计日志按分钟聚合（14 章「对外请求审计日志」），逐次成功 Debug、失败 Warn。③ 出口级连续重复折叠 `repeatSquelcher`（syslog 语义：第一条立即写、后续连续同模板只计数、换行或超 60s 结算成 `last message repeated N times`；模板口径 = 去 time= 属性 + 抹数字，跟诊断导出 `collapseRepeatedLines` 一致）。④ 运行期轮转（下一条）。⑤ 调用点清理：`enrich: reusing existing entry` 按 key 只记首次；启动 `loaded N cached …` 八处补 `cache:` 前缀。⑥ App 侧：删 `overlay-debug` 探针（要看点击几何临时加回来跑 `log stream`）；`snapshot failed` 改 notice、尾巴改 `streak=N` 并显式 `.public`；`SpaceDiagnostics`（09-03 的探针）**没动**——那个「切全屏 Space 被弹回桌面」还没定位到根因，它就是为此存在的，846 行/天是它的工作量不是噪音。⑦ App 与 collector 的 launchd stderr 分家：`LoginItemManager` 写的 plist 指到 `lyrimuse-app.log`（每次启动重写；⚠️ launchd 只在 job bootstrap 时读 plist，kickstart 不重读——装机当天 `launchctl print` 里 stderr 仍是旧文件，要到下次登录或 bootout + bootstrap 才切过去），`CollectorControl` 的 launchctl kickstart 子进程 stdout/stderr 接到 nullDevice；诊断导出多一段 App stderr 最后 100 行，collector 日志的时间戳解析下沉到 Core `CollectorLogLine`（两种格式都认）。**不动的**：`menubar-item` 的 slot rebuild notice（13 条决策要的事后现场）、App 侧 `network-audit`（用户要求且量小）。守卫：contracts 组「日志规范」的 Go 扫描把 `slog.*` 也算进日志字面量；Go 测试 logsink_test.go（等级解析 / 时间格式 / 模板口径 / 折叠 / 运行期轮转 / 子命令判定）+ networkobs_test.go 审计汇总；selftest ops-diagnostics 组 CollectorLogLine 两种格式。⚠️ 常驻模式下 collector **自己打开**日志文件写（不再只靠 launchd 把 stderr 指过去），子命令（healthcheck 等）仍写 stderr——判据 `isDaemonInvocation`（有子命令名就不是常驻）。顺带把 go.mod 的 `go` 指令从 1.21 提到 1.22（测试里 `slog.SetLogLoggerLevel` 需要；工具链本就钉着 1.24.4，只是语言版本门槛跟上）。
- **日志轮转（2026-08-27 加）**：`installLogSink`（main 启动时最早调的那一步，logsink.go；2026-09-05 之前叫 `installLogScrubbing`）顺带调 `rotateLogIfNeeded`（logrotate.go）——超过 30MB 就把旧文件归档成 `lyrimuse.log.old`（覆盖式，只留一份）、开一份新的。之前这个文件完全没有轮转过（`lyricstrace.go` 注释早就点名过这一先例），实测涨到过 13.5MB。原来只在**进程启动时**检查一次（理由是 collector 本来就会被相对频繁地重启）；**2026-09-05 起运行期也轮转**：常驻模式由 collector 自己打开日志文件写（logsink.go `rotatingLogFile`），每次写之前按自己累计的字节数判断、越过上限就 `archiveAndReopen`（跟启动期同一套动作）再写，轮转事件那一行直接写在新文件开头。一个常驻很久的进程从此不会无限涨。故意不用系统级 `newsyslog`：那需要 root 权限写 `/etc/newsyslog.d/`，跟这个项目"尽量不依赖需要管理员权限的官方机制"的一贯取向（ad-hoc 签名放弃 SMAppService 走文件系统方案是同一个理由，见第 14 章已知坑）不搭。⚠️ 不能简单 `os.Rename` 完事：进程的 `os.Stderr` 此刻已经指向旧文件的 inode（launchd 通过 `StandardErrorPath` 打开、fork/exec 时继承给我们），rename 只改目录项，不会让已经打开的 fd 转向新路径下的新文件，必须显式 `os.OpenFile` 一份新文件再 `log.SetOutput` 过去。
- `MediaControlHealth`：App 侧对 media-control 二进制做可用性探测。

### 6. 音量横幅（VolumeMonitor）

CoreAudio 属性监听（不拦音量键不轮询 osascript），系统输出音量变化时在灵动岛闪音量横幅（经 NotchTransientCenter，第 05 章）。

### 7. 卸载（uninstall.sh）

`lyrimuse/scripts/uninstall.sh`，三档：默认只报告 / `--services` 只注销两个 launchd job（不碰数据）/ `--purge` 注销 + 删配置缓存日志 + **删偏好设置项**（必须手输 `yes`）。

- **`--purge` 会 `defaults delete <bundle id>`**（2026-08-22 加）。不删的后果是把重装引向一条**不可自愈的死路**：purge 已经删掉 LaunchAgent（collector 没装），而 `np:hasCompletedOnboarding` 还是 true → 重装后首启引导永不出现，而那扇引导页是把 collector 服务装回去的主要入口；用户看到的是桌面永久停在「搜索歌词中…」，界面上没有任何线索指向「后台服务没装」。`OnboardingView` 顶部注释记的就是这条死路，只是这次从卸载路径绕了回来。整个 domain 一起删而不是挑几个 key：purge 的语义就是「当它没装过」，挑 key 既不完整（`np:*` 之外还有 `KeyboardShortcuts_*`），又要跟着代码里的 key 表走样。
- ⚠️ **`defaults read` 不能当「域还在不在」的判据**：`defaults delete <domain>` 成功之后 `defaults read <domain>` **仍然退出 0**，只打印一个空字典 `{}`（cfprefsd 里那个 domain 的空壳还挂着）。拿退出码判等于恒为真，表现是删干净了却报「❌ 仍然存在」。脚本里的 `has_defaults()` 判的是读出来有没有内容，测试侧同一个坑同样修法。
- ⚠️ **「App 还在跑」只能当提醒，不能当前置闸**：跑卸载脚本的人多半 App 还开着（他刚决定不要它了），做成「在跑就跳过删除」等于永远不删；而且那个判据看的是全局有没有 `lyrimuse` 进程，跟 `$APP_LABEL` 这个 domain 没有对应关系——`uninstall_test.sh` 把 label 覆盖成 probe 域，却会被真实 App 的运行状态挡住（加这段时被那条测试当场抓出来）。现在是**先删、再核实、最后如实提醒 cfprefsd 可能写回**，三件事各归各的。
- **测试**：`lyrimuse/scripts/uninstall_test.sh`（这是仓库里唯一会 `rm -rf` 用户数据的东西，改了必须跑）。它靠 `LYRIMUSE_UNINSTALL_PREFIX` + 两个可覆盖的 label 走**完全相同的代码路径**，不开旁路；偏好域用的是 probe label，setup 时种一条、cleanup 时删掉。第 6 节「全程没碰真实环境」现在多一条：真实偏好域的 key 行数前后必须不变——万一哪天有人把 domain 写死成真实 bundle id，这一行会当场把「测试把我自己的全部设置删了」抓出来。

### 8. 测试（selftest）

无 XCTest（无完整 Xcode）。`swift run lyrimuse-selftest` 跑手写 `expectEqual` 断言（歌词引擎/取色/偏移/本地化守卫等）。2026-09-03 起按领域拆成 `Sources/lyrimuse-selftest/` 下 17 个 `XxxTests.swift`（每文件一个 `runXxxTests()`）+ `Harness.swift`（断言函数、`failures`/`assertions`/`quietOutput` 三个计数器）+ `main.swift`（`groups` 注册表、参数、逐组汇总）；`--filter <组名子串>`（可重复、不区分大小写）只跑子集，`--quiet` 只留 FAIL 与每组一行「N 条断言, X ms」，`--list` 列组；退出码 0 通过 / 1 有 FAIL / 2 参数错或 `--filter` 零匹配。`main.swift` 开头内置「注册表守卫」：扫目录里所有 `run…Tests()` 定义，逐个核对 `groups` 有没有引用，漏注册直接 FAIL（拆多文件后唯一新增的坑，编译过、一条不跑、输出看不出少了什么）。拆分是纯机械搬迁：拆前后各跑一遍、`ok - ` 标签多重集逐字节一致（2241 条），断言内容一字未改。两条实测细节：① 原顶层语句搬进函数后，引用 Core 里 `@MainActor` 属性的断言会报「nonisolated context」（main.swift 顶层在本包语言模式下也不是主 actor 上下文，直接调 `@MainActor` 函数编不过），所以每个 `runXxxTests()` 标 `@MainActor`、注册表调用处包一层 `MainActor.assumeIsolated`；② 好几条守卫靠 `#filePath` 往上数目录层数定位仓库文件，领域文件必须平铺在 `Sources/lyrimuse-selftest/`、不能建子目录。Go 侧 `GOTOOLCHAIN=go1.24.4 go test ./...`（默认 go 1.21 编译产物会被 AMFI 拒签、启动即死，repo CLAUDE.md 硬规则）。真机界面验证用只读方式：`swift lyrimuse/scripts/check-windows.swift` + `screencapture -l <窗口ID>`，**禁止** AppleScript/System Events 驱动界面（毁过用户数据）。

2026-09-05 起 contracts 组另有「项目级 skill」守卫：`.claude/skills/*/SKILL.md`（真机验证 / 歌词排查 / 发版三份操作型流程，借鉴清单 #49；只写步骤与判据，理由回链 AGENTS.md 与本目录各章）每份 ≤ 80 行、frontmatter 的 name 与目录名一致且有 description、正文引用的仓库路径与文档链接必须存在、发版那份必须 `disable-model-invocation: true`、真机验证那份开头必须是禁 AppleScript 那条硬规则，AGENTS.md 与 CLAUDE.md 都要指向 `.claude/skills/`。skill 最常见的死法是锚点腐烂（脚本改名、文档挪位）和越写越长变成第二份 AGENTS.md，守卫比纪律可靠。

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
- `~/Library/LaunchAgents/*.plist` 两份；`~/Library/Logs/lyrimuse.log`（collector，含 `.old` 归档）、`~/Library/Logs/lyrimuse-app.log`（App 进程 stderr，2026-09-05 起）。uninstall.sh `--purge` 两份日志都删。
- digest 状态文件（已推送水位）；单实例锁文件。

## 代码锚点

| 主题 | 位置 |
|---|---|
| 构建部署 | lyrimuse/build.sh；打包 lyrimuse/package.sh；发布 .github/workflows/release.yml |
| 卸载 | lyrimuse/scripts/uninstall.sh（`has_defaults` / purge 段）、lyrimuse/scripts/uninstall_test.sh |
| 服务管理 | Settings/CollectorServiceManager.swift（`install` / `reconcileAfterLaunch` / `recordInstalledFingerprint` / `currentBinaryFingerprint`）、LyricsManager/CollectorControl.swift、LyrimuseCore/Local/LaunchdJobState.swift、CollectorStatus.swift |
| 单实例 | lyrimuse-collector/singleinstance.go |
| 联动唤起 | lyrimuse-collector/companionlaunch.go |
| 首次解析取消信号 watcher | lyrimuse-collector/enrichcancel.go（跟 companionlaunch.go 同一种「独立节奏、poller.go `run()` 单开 goroutine、ctx 取消时退出」模式）；机制细节见第 09/11 章 |
| 日报/周报 | daily.go、weekly.go、digest.go |
| 推送通道 | notify.go `buildNotifyPayload`、alerter.go |
| 健康检查 | healthcheckcli.go；App 侧 MediaControlHealth.swift |
| 音量横幅 | Settings/VolumeMonitor.swift |
| 网络观察 / 对外请求审计 | networkobs.go（`doHTTPTracked`）、networkobs_test.go |
| 日志出口（slog 桥接 / 等级 / 重复折叠 / 运行期轮转） | logsink.go（`installLogSink` / `applyLogLevel` / `repeatSquelcher` / `rotatingLogFile` / `flushLogSink`）、logsink_test.go；logrotate.go（`rotateLogIfNeeded` / `archiveAndReopen` / `logFilePath`）、logrotate_test.go；脱敏 logscrub.go（`secretScrubber`）；审计聚合 networkobs.go（`recordAPICall` / `flushAPICallSummaries`）；退出 flush exitreason.go `logExit`；App 侧 `LyrimuseCore/Diagnostics/CollectorLogLine.swift`（`CollectorLogLine.timestamp(of:)` / `LogFiles`） |
| 自测 | Sources/lyrimuse-selftest/（main.swift 注册表 + Harness.swift + 17 个 XxxTests.swift）；scripts/check-windows.swift |

## 设计决策与已知坑

1. **`swift build` ≠ 已安装**：不跑 build.sh 的「验证」验证的是旧 App。
2. Go 必须 `GOTOOLCHAIN=go1.24.4`：默认工具链产物被 AMFI 拒签且症状像被测代码自己崩。
3. 单实例 flock 是数据完整性防线，不是优化——双实例互磨缓存有真实事故。
4. kickstart 被 launchd 节流（~10s），任何「频繁踢」的设计都要先过去抖。
5. App 与 collector 的 KeepAlive 策略刻意相反（前台工具 vs 无人值守服务）。
6. 界面验证只许只读手段（截图/读窗口状态），AppleScript 驱动界面是禁区（历史事故：误触「清空全部」、误关用户其它 App）。
7. 故障告警（连续失败推送）已整体下线——别按旧印象去找 ok()/fail()。
8. build.sh 的 kickstart 失败自愈（bootout+bootstrap）针对 LWCR 陈旧签名约束，是真实踩过的坑。
9. **两个本该同源的版本号，一个自动一个手动 → 必然漂**（2026-09-02，用户在另一台机器装了 1.5.0 的 dmg，设置页报「App 1.5.0 · 采集服务 1.4.0」）。App 版本一直从 git tag 自动派生，collector 的 `clientVersion` 却是 `main.go` 里的手写字面量，靠人在发版时记得改那一行。实测记录：v1.1.0 补同步、v1.2.0 补同步、**v1.3.0 漏**、v1.4.0 补上、**v1.5.0 又漏**——同一个坑两年内踩两次，说明问题不在谁不小心。
   - **功能其实没坏**：`clientVersion` 只用于 `collector version` 子命令、ListenBrainz 的 `submission_client_version`、以及 musicbrainz/lrclib 两处 User-Agent，全是「自报家门」的字符串。用户拿到的 collector **就是 1.5.0 的代码**，只是自报 1.4.0。
   - **提示文案当时是误导的**：设置页建议「重新安装 App」，但版本号烧死在二进制里，装多少次同一个 dmg 都一样——已改成如实说明。
   - **修法**：两个构建脚本统一 `-ldflags` 注入（见上面 build.sh 一节），`clientVersion` 从 `const` 改成 `var`（`-X` 对 const 静默失效）。防线三道：`versioninjection_test.go`（钉住 var / 默认值必须是一眼假的 `"dev"` 而不是某个具体版本号 / 两个脚本都带注入 / build.sh 有产物闸，**已做变异测试**验证四条断言真能抓到回归）、build.sh 的产物一致性闸、以及原有的设置页告警。
   - **默认值为什么是 `"dev"` 不是某个版本号**：这次事故最坏的形态就是「一个看起来完全正常、实际早就过时的版本号」——没有任何人会起疑。一眼假的值让「没走发布构建」自己暴露。同一条原则见 build.sh 里 `APP_VERSION` 退到 `0.0.0` 那段注释。
   - **设置页那张卡（`bundledCollectorVersion`）本身是有效的**：它正是抓到 v1.5.0 这次的机制（2026-08-31 才加，起因就是 v1.3.0 那次）。它没做错什么，只是时机在**发版之后**；这次把同一个检查提前到了构建期。

10. **本机 `defaults` 里的 `SUFeedURL` 覆盖会让所有更新检查静默失败，本地验完 appcast 必须删（2026-09-03 实测）**：
    Sparkle 读 feed 地址时**用户偏好优先于 Info.plist**。此前某次本地验证 release.yml 的 appcast 切分逻辑用了「假 appcast +
    `defaults write me.yudaotor.lyrimuse SUFeedURL http://127.0.0.1:8791/appcast.xml`」的配方（见记忆库发版笔记），验完没有 `defaults delete`，
    于是这台机器上之后**每一次**定时检查都在连一个没人监听的本地端口——定时检查失败不弹窗、`SULastCheckTime` 照样更新，
    从外面看完全像"检查过了、没有新版本"。这次是为演示菜单栏面板「有新版本」把本地版本号压成 1.3.9、手动点「检查更新」弹出
    「获取升级信息时出现错误」才暴露。**定位方法**：统一日志在这台机器上查不到 App 记录（`log show` 对 lyrimuse 进程恒返回 0 行，
    原因未查），改用一个链接 App 内 `Sparkle.framework`、以 `/Applications/Lyrimuse.app` 为 hostBundle 的 `SPUUpdater` 诊断小程序
    （`SPUUserDriver` 全部方法只打印、`showUpdateFound` 回 `.dismiss`），`updater.feedURL` 直接暴露实际生效地址，
    `showUpdaterError` 给出完整 NSError 链（`NSURLErrorDomain -1004` → 127.0.0.1:8791）。**修法**：`defaults delete me.yudaotor.lyrimuse SUFeedURL`，
    删后同一诊断程序立刻 `didFindValidUpdate 1.4.0`。**规则**：以后任何走 `defaults write SUFeedURL` 的本地验证，收尾必须成对 `defaults delete`，
    并把「`defaults read me.yudaotor.lyrimuse SUFeedURL` 应报不存在」写进验证清单；「导出诊断信息」的 `Auto-update checks` 行也应带上实际生效的 feed 地址（待做）。
