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

2026-09-02 起本仓库对那边**多了一条契约**：`POST /artwork/<sha>`（带 `x-token`，body 是图字节）/ `GET·HEAD /artwork/<sha>`，用来托管「设备直送封面」（见下面已知坑第 8 条）。`sha` 是内容 sha256 的前 8 字节、十六进制 16 位，路由前缀 `/artwork/` 与采集器 `artworkrelay.go` 的 `artworkRelayPath` 逐字一致，**改一边必须改另一边**。这条链路要求中继先部署、采集器后上线：中继还没有这个路由时，采集器的上传会失败并进 5 分钟冷却，期间网页退回自己的 iTunes 兜底（不会崩，只是没封面）。

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
8. ⚠️ **任何要离开这台机器的 `cover_url` 都必须先过 `webSafeCoverURL`**（`artworkrelay.go`）。2026-08-31 起「设备直送封面」会把 `cover_url` 写成 `file:///Users/<用户名>/.config/lyrimuse/artwork/<sha>.jpg`——对本机 App 是升级（封面一定对版），但它被原样带出去之后：网页拿到一个浏览器永远读不到的本地路径（表现是**封面整块空白、其它一切正常**，2026-09-02 用户报「为什么我的网页上没有封面了」），ListenBrainz 那边还把本机用户名和目录结构公开了出去。

    最阴的一点是**网页的兜底闸拦不住它**：`web/index.html` 那条 iTunes 兜底写的是 `if (!art)`，而 `file://…` 是个非空字符串，大摇大摆地绕过兜底、直接被塞进 `<img src>`。所以这不是「少了个兜底」，是「兜底被一个看起来有值的坏值骗过去了」。

    修法是 **C：把图本身托管到中继**（`POST /artwork/<sha>`，采集器上传；`GET /artwork/<sha>` 网页读）。没选「退回网易云/QQ 那张远程封面」是因为退不回去也不该退——`resolveTrackEnrichment` / `applyDeviceCoverUpgrade` 都直接覆盖 `CoverURL`，`coverSwapAllowed` 又规定 `cover_source == "device"` 一律不再换源，旧的远程 URL 已被永久覆盖（核过那 90 条，剩下的 http 链接全是歌曲**页面**链接）；何况设备直送那张才是对版的，退回去等于让网页显示一张可能挂错的封面。

    三条硬约束，改这条链路时都不能松：
    - **省 KV 写额度**。中继是 CF Worker + KV，免费版 1000 写/天，而 `/push` 播放中每几秒就写一次。所以键是**内容寻址**的（sha = 图内容 sha256 前 8 字节，落盘时就按它命名，实测 90 条曲目只对应 31 张图），上传前先 `HEAD` 问一句、命中就一个字节都不写，Worker 侧再兜一层「已存在就 existed、不写」。内容寻址还顺带让 `GET` 能发 `immutable` 长缓存。
    - **`artworkUploaded` 只活在内存里**，重启后为空。所以 `HEAD` 那一步不是可选优化——没有它，每次 collector 重启都会把整个 `artwork/` 目录重传一遍。
    - **认不出的 `file://` 一律返回空串，绝不原样透传**。宁可让网页暂时退回 iTunes 兜底，也不能再把本地路径放出去。

9. ⚠️ **ListenBrainz 里 2026-08-31~09-02 那两天的记录已经永久带着 `file://` 封面**，改不掉。所以 `fromLB` 那条兜底链路上必须长期留一道 `^https?://` 的守卫——网页（`index.html` + `demo/index.html`）和 state-worker 各有一份**同名同逻辑**的 `fromLB`，三处都要有，改一处记得改另外两处（这个「两份几乎逐字相同的 `fromLB`」本来就是 `index.html` 里写明的已知重复）。
