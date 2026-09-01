# 13. 网页展示与中继

> 最后核对：2026-09-01 · 基线：10f4061+工作树

## 定位

把「正在播放」带出这台 Mac：collector 推送状态到自建中继（Cloudflare Worker + KV，代码在外部仓库 nowplaying-workers），公开网页（web/）实时展示歌词/封面/统计，feishu-bot 让飞书里的人瞟一眼就能看到在放什么。

## 入口与展示面

- 公开网页（web/index.html，PWA，带 sw.js 离线壳）。
- 飞书链接预览卡片（feishu-bot）。
- 配置入口：设置 → 账号 → 「网页推送」（中继地址/密钥）。

## 行为规格

### 1. collector → 中继推送（relay.go / poller.pushRelayState）

- `relayState` 构造网页读的 `/now` JSON：复用 `lbMeta` 的封面/主色/链接/进度锚，但**歌词字段不从 lbMeta 拿**——那份已按 ListenBrainz 单条 ≤10240 字节预算裁剪（逐字最先被丢），网页不受此约束，改从 `trackEnrichment` 现拿未裁剪全量（只查内存缓存，无额外网络）。
- `current` 语义：true=此刻活跃曲目（暂停也算，「当下真相」永远直接显示）；false=纯历史「上次播放」（网页才需要跟本地缓存比新旧）。不区分的话，暂停中的活跃曲目因没有 listenedAt 会被网页误判不可信、被几天前的旧记录顶替。
- 推送节流：状态变化即推 + 心跳兜底（4 分钟内无变化不重复推）。
- 进度锚：`progress_ms + progress_ts`，网页只外推到下次刷新，不用 media-control 的冻结 timestamp。

### 2. 网页（web/index.html，~2700 行单文件）

主要板块与已知行为（细节以文件内注释为准）：
- **实时卡片**：封面（多级兜底：中继数据 → 网易云/QQ/Apple 源；骨架屏与兜底的渲染时序有专门修复防止「兜底被自己清空”）、按封面取色（canvas 自适应压黑 `computeArtScrim`，与 App 端固定 22% 刻意不同——封面源亮度分布不同）、平台跳转链接排、试听按钮。
- **逐字卡拉OK**：CSS 渐变 stop 位置**单调钳制**（防「提前加载颜色」回退）。
- **页脚歌词来源**：如实反映 `lyrics_source`（五步透传链路）。
- **今日统计**：与列表 200 条截断解耦（只在命中截断信号时才退化直连 LB）。
- **黑胶模式**、移动端工具抽屉（≤600px）。
- **历史播放 Top10 歌手**板块（数据见 §3）。
- **访客留言墙/表情反应**：前端在本页，写接口在 workers 仓库（边界外，本文档不展开）。
- 部署：web/ 是嵌套 git 仓（Yudaotor 线上仓），本地 HEAD 长期落后 origin，**改动经 `gh api PUT` 直传**，不走本地 push。⚠️待核对：当前确切部署命令无仓内脚本记载。

### 3. Top10 歌手（topartists.go）

- 24 小时检查一次（`topArtistsCheckInterval`），最终展示 10 个（`topArtistsN`），从 Last.fm 拉 30 个原始条目的池子（`topArtistsFetchPool`）再归并。
- **别名归并**（mergeAliasedArtists，2026-08-18 扩成三信号并查集）：①名字键（合唱取第一位＋手工别名表＋繁简＋大小写折叠）；②mbid——Last.fm 自带的，或 **MusicBrainz 身份解析**补上的（`resolveArtistIdentityMB`：任何写法 → mbid＋中文名，置信度 ≥90、中文名过中华圈 country 门槛，永久缓存 `lyrimuse-artist-identity-cache.json`）；③解析出的中文名的名字键（桥接「A 解析出中文名、B 本来就用中文名」）。显示名优先级：桶内真实出现过的中文成员名 > 解析出的中文名 > 合 credit 段数最少的成员名。
- **身份解析的延迟纪律**：daily 推送在 poll 循环里同步跑，归并本体**只读缓存**；缓存由 `warmArtistIdentityCache` 后台 goroutine 预热（MusicBrainz 全局 1.1s 限速，整池 ~1 分钟），次日归并自然收敛。CLI 默认 `-mb-budget 0`（App 统计页保持毫秒级），手动导出可传大预算现场解析。
- 头像源优先级：QQ 音乐 → Deezer 兜底（Apple Music 需付费 API 不可行）。
- 池子不够 10 个不动态补拉，少于 10 直接展示。
- 结果落盘（`topArtistsStatePath`）并随 relay 推给网页；`topartistscli.go`/`avatarcli.go` 提供手动调试入口。

### 4. feishu-bot（独立 Go 常驻进程）

- 飞书「链接预览」应用 + **长连接**（WebSocket 主动外连）——国内飞书服务器访问 workers.dev 3s 超时，公网 HTTP 回调不可用；长连接无需公网入站端口。
- 数据源：配置 `state_relay_url` 时优先读中继 `/now`（国内可达），失败/未配退回直连 ListenBrainz 公开 API（免 key，与 collector 无代码依赖）。
- 纯文字卡片不带封面（路过瞟一眼的场景，封面换不来图片上传/缓存/并发去重的维护成本）；有并发去重修复（同一预览事件的重复回调）。

### 5. workers 边界（外部仓库 nowplaying-workers）

state-worker（/push 接收、/now 供网页与 feishu-bot、KV 缓存、LB 兜底合成）、留言墙/表情写接口等在 nowplaying-workers 仓库，行为规格不在本文档维护范围；本仓库只保证 relayState 的 JSON 形状与其约定一致。

## 设置项

| 位置 | 项 | 影响 |
|---|---|---|
| 账号→网页推送 | 中继地址/密钥 | pushRelayState 的目标；未配置则不推送（网页退化走 LB 兜底） |

## 与其它功能的交互

- 歌词/封面/主色全部来自 enrich 缓存（第 09 章）；relay 取未裁剪版是「网页歌词与本地不一致」问题的修复（预算只属于 LB）。
- 进度锚与播放数据源共用（第 02 章）；listen 完成事件也推给中继（applySubmitOutcome，第 12 章）。
- Top10 歌手的别名合并与歌词检索的 artistAliasTable/MusicBrainz 是同一套认知（第 09 章）。

## 数据与文件

- collector 侧：topartists 状态文件；relay 目标配置在 `config.json`。
- web/：嵌套 git 仓（index.html + sw.js + demo/images）。
- feishu-bot：`feishu.example.json` 模板 + launchd 目录（⚠️待核对：本机实际 LaunchAgent 安装状态）。

## 代码锚点

| 主题 | 位置 |
|---|---|
| 状态构造/推送 | lyrimuse-collector/relay.go `relayState`；poller.go `pushRelayState` `pushScrobble` |
| Top10 | lyrimuse-collector/topartists.go `mergeAliasedArtists`；topartistscli.go、avatarcli.go |
| 网页 | web/index.html（`computeArtScrim`、卡拉OK渐变、今日统计等函数级注释）、web/sw.js |
| 飞书 | feishu-bot/main.go `buildInline`、README.md |

## 设计决策与已知坑

1. relay 歌词必须绕开 LB 的 10240 字节预算取未裁剪版——「网页歌词跟本地不一致」的真根因就是误用了裁剪版。
1a. **网页的 `parseLRC`/`parseYRC` 曾完全不认歌词自带的 `[offset:]`（2026-09-01 修）**：
   桌面端 2026-08-22 起消费这个标签（第 08 章「歌词自带的 [offset:]」），网页没跟上——
   Swift 的 LRCParser 当初还是照抄网页 parseLRC 写的，修桌面时反方向漏了。酷狗实测有两首
   非零（242ms/600ms），在网页上整份歌词偏移。index.html 与 demo/index.html 同步补齐，
   语义与桌面端逐条对齐：LRC 为 0 再看 YRC、只取第一个标签、±10s 量级闸；译文/罗马音按
   **原始**时间戳配对（两边都是 raw、不受影响），配对完只平移展示用的 t。⚠️ web/ 是嵌套
   git 仓，改动要在那个仓单独提交，且线上生效依赖它自己的部署流程。
2. `current` 布尔是「暂停中的活跃曲目被旧记录顶替」的修复，改 JSON 形状要连 workers 侧一起看。
3. 网页封面/取色与 App 端策略刻意不同源不同参（封面源亮度分布不同），不要互相「统一」。
4. 卡拉OK CSS 渐变 stop 必须单调——非单调会视觉「预染色」，与 desktop-lyrics 的 fillFraction 夹值是同根因的两端修复。
5. feishu-bot 选长连接是国内网络现实（3s 超时）逼出来的，改回调式会直接不可用。
6. web/ 的部署路径不走本地 git push（本地 HEAD 落后是常态），别试图「顺手」把它 push 上去。
7. Top10 不做「不够就补拉」的动态逻辑——极端情况宁可少于 10 个。
