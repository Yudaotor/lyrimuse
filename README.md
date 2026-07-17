# applemusic-nowplaying

在飞书签名（或任何地方）放一个固定链接，动态展示这台 Mac 上 Apple Music 正在播放的歌；也可以选配一个悬浮歌词窗口、README 动态徽章、Last.fm/iPhone 播放桥接等。

作者本人的线上示例：https://yudaotor.github.io/nowplaying/?user=yudaotor

本仓库（`collector/`/`state-worker/`/`badge-worker/`/`worker/`/`desktop-lyrics/`/`launchd/`）只负责采集/中继/展示逻辑。展示页 `web/index.html` 是另一个独立公开仓库 [`Yudaotor/nowplaying`](https://github.com/Yudaotor/nowplaying)（`.gitignore` 里排除了 `/web/`，两边互不影响，各自 `git clone`）。

## 这是什么，需要什么

核心链路只有三部分，其余都是可选功能：

1. **一台常年开机、装了 Apple Music 的 Mac**（运行 `collector/`，Go 编译，launchd 常驻）。
2. **一个 [ListenBrainz](https://listenbrainz.org) 账号**（免费注册，公开 API，采集器把播放记录提交给它）。
3. **一个静态页面**（`web/index.html`，纯前端零后端，浏览器直接读 ListenBrainz 的公开 API）。

在此基础上，以下都是独立可关的可选功能，装了核心链路之后随时可以再加：自建 Cloudflare Worker 中继（国内访问加速 + 更丰富的展示数据）、desktop-lyrics 悬浮歌词窗口（Mac 菜单栏 App）、Last.fm 桥接/镜像、Bark/DingTalk/企业微信等故障告警、GitHub README 动态徽章。详见下面「功能一览」表格。

## 快速开始：部署采集器

```bash
git clone git@github.com:Yudaotor/nowplaying-backend.git
cd nowplaying-backend

# 依赖：brew install media-control（读系统正在播放，免 Apple Events/自动化授权）
brew install media-control

cd collector
go build -o ../bin/collector .
mkdir -p ~/.config/applemusic-nowplaying
cp config.example.json ~/.config/applemusic-nowplaying/config.json
chmod 600 ~/.config/applemusic-nowplaying/config.json
# 编辑 config.json：listenbrainz_token 必填(在 https://listenbrainz.org/settings/ 拿)；
# listenbrainz_user 采集器本身不读，但网页/state-worker 的 URL 都要用到，建议一并填好；
# 其余字段(state_relay_*/lastfm_*/bark_url/notification_platform 等)都是可选功能，留空即关闭。

# 先前台试跑（回到仓库根目录；--dry-run 只打日志不真提交）
cd .. && ./bin/collector -dry-run

# 确认没问题后常驻：launchd/ 下这份 plist 里的路径是作者自己机器的，
# 用 sed 换成你自己的路径再装，不要直接 cp——原样装会导致 launchd 静默拒启
# （二进制路径在你机器上不存在，且日志路径大概率也没权限写，出错都看不到日志）。
REPO="$(pwd)"
sed -e "s#/Users/chenyuhao/applemusic-nowplaying#$REPO#g" -e "s#/Users/chenyuhao#$HOME#g" \
  launchd/com.chenyuhao.applemusic-nowplaying.plist > ~/Library/LaunchAgents/com.chenyuhao.applemusic-nowplaying.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.chenyuhao.applemusic-nowplaying.plist
# 日志路径已经在上面的 sed 里换成你自己的了：~/Library/Logs/applemusic-nowplaying.log
```

到这一步，ListenBrainz 上就已经能看到播放记录了。接一个展示页：

```bash
git clone git@github.com:Yudaotor/nowplaying.git web-page
# 托管到任意静态站（GitHub Pages / Cloudflare Pages），访问：
# https://<你的域名>/index.html?user=<你的 ListenBrainz 用户名>
```

纯静态零后端（ListenBrainz 与 iTunes Search API 均允许浏览器跨域直读），把这个链接放进飞书个性签名或任何地方即可。国内访问 ListenBrainz 直连可能不稳定/较慢——这也是下面「部署 Worker」这个可选功能存在的原因。

### 获取 `lastfm_scrobble_session_key`（Last.fm 镜像写入用，可选）

这是把 Mac 播放镜像写进 Last.fm(`lastfmScrobbler`，见 `collector/lastfm.go`)要用的凭证，跟桥接 iPhone 播放用的 `lastfm_user`/`lastfm_api_key` 是两回事。session key 永久有效，正常只需申请一次。

1. 申请一次 API application（如果还没有）：打开 https://www.last.fm/api/account/create ，随便填名字/描述提交，拿到一对 **API Key** 和 **Shared Secret**——这两个值就是 `lastfm_scrobble_api_key`/`lastfm_scrobble_secret`。
2. 用这两个值换一次性 token：
   ```bash
   API_KEY=你的APIKey
   SECRET=你的SharedSecret
   curl -s "https://ws.audioscrobbler.com/2.0/?method=auth.gettoken&api_key=${API_KEY}&format=json"
   # => {"token":"xxxxxxxx..."}
   TOKEN=上面拿到的token
   ```
3. 浏览器打开下面这个地址，用你自己的 Last.fm 账号登录并点 "Yes, allow access" 完成一次性网页授权：
   ```
   https://www.last.fm/api/auth/?api_key=${API_KEY}&token=${TOKEN}
   ```
4. 授权完成后，用同一个 token 换永久 session key。签名算法是 Last.fm 官方规范(参数按 key 字母序拼接 key+value，末尾接 secret，取 MD5)，跟 `collector/lastfm.go` 里 `sign()` 用的算法完全一致：
   ```bash
   SIG=$(printf '%s' "api_key${API_KEY}methodauth.getsessiontoken${TOKEN}${SECRET}" | md5 -q)
   curl -s "https://ws.audioscrobbler.com/2.0/?method=auth.getsession&api_key=${API_KEY}&token=${TOKEN}&api_sig=${SIG}&format=json"
   # => {"session":{"name":"你的用户名","key":"xxxxxxxx...","subscriber":0}}
   ```
   `session.key` 就是永久 `lastfm_scrobble_session_key`，填进 `config.json` 即可。

## 桌面歌词悬浮窗（desktop-lyrics，可选）

Mac 菜单栏 App，悬浮歌词窗口 + 歌词管理窗口，复用同一份 `state-worker` 数据契约。不需要任何 Apple 开发者账号/证书——ad-hoc 签名即可运行。构建/运行步骤、目录结构、开机启动见 [`desktop-lyrics/README.md`](desktop-lyrics/README.md)，这里不重复。

## 功能一览

作为一个整体的 Apple Music 配套软件，这些是它目前支持的能力。除了核心追踪/提交（存在的根本意义，不可关）、封面/主色/平台跳转链接（基础展示信息，2026-07-17 起改成无条件执行，不再是可关闭的设置项）和三个常驻部署的 Cloudflare Worker（跟本机进程无关，本机没有开关能控制它们本身），其余都能在 desktop-lyrics 的「设置」窗口按开关单独打开/关闭（改完自动写共享文件+重启 collector，见 `collector/features.go`/`desktop-lyrics/Sources/desktop-lyrics/Settings/FeatureSettingsStore.swift`）。

| 功能 | 一句话说明 | 实现子系统 | 怎么开关 |
|---|---|---|---|
| ListenBrainz 提交 | 提交 playing_now/listen，是整个项目存在的根本意义 | `collector/` | 始终开启；要关掉就是卸载/停用整个 collector |
| 展示页「正在播放」 | 网页显示当前/历史播放 | `collector/` + `state-worker/` + `web/` | 展示页本身常驻部署，不经本机控制 |
| 状态中继(国内加速，可选) | 采集器把当前状态推进 KV，网页优先读它、拿不到才回退直连 LB | `collector/` + `state-worker/` | 设置里「推送状态到网页/徽章」开关 + `config.json` 填 `state_relay_url` |
| GitHub 动态徽章(可选) | README 里的实时 SVG 徽章 | `badge-worker/`(读 state-worker) | 常驻部署，本机不可控；依赖上面「状态中继」有没有新鲜数据 |
| 悬浮歌词窗口 | 桌面浮层实时显示当前歌词，支持逐字高亮 | `desktop-lyrics/` | 菜单栏「显示悬浮歌词」 |
| 歌词管理窗口 | 查看/手改/删除/重新搜索候选每首歌的歌词 | `desktop-lyrics/` | 菜单栏「歌词管理…」 |
| 封面/主色/平台跳转链接 | 抓封面(网易云/QQ 兜底)、算主色、拼 Apple/QQ/Spotify 跳转链接 | `collector/enrich.go` | 始终开启；不再是可关闭的设置项(2026-07-17 起) |
| 歌词多源解析 | 网易云/QQ音乐/酷狗/LRCLIB 四源都查一遍、取打分最高的 | `collector/enrich.go` | 设置里「歌词在线匹配」开关 |
| 歌词文件夹作为权威源 | `~/.config/applemusic-nowplaying/lyrics/` 下的纯文本文件可以直接手改，collector 重启时导入生效 | `collector/lyricsimport.go`/`lyricsexport.go` | 设置里「歌词文件夹作为权威源」开关 |
| 专辑预取 | 换歌时顺手把同专辑其它还没解析过的曲目(封面+歌词)丢到后台解析 | `collector/albumprefetch.go` | 设置里「提前解析同专辑其它曲目（封面+歌词）」开关 |
| iPhone 播放桥接 | 把 iPhone 上经 Last.fm(FastScrobbler)记录的播放转发进 ListenBrainz | `collector/poller.go`(`bridge`) | 设置里开关 + `config.json` 填 `lastfm_user`/`lastfm_api_key` |
| Mac 播放同步进 Last.fm | 反向把 Mac 播放也镜像写进 Last.fm，让 Last.fm 上有完整历史 | `collector/lastfm.go` | 设置里开关 + `config.json` 填 `lastfm_scrobble_*` 三项 |
| 每周听歌小结 | 每周 Last.fm 图表收官时推一条通知 | `collector/weekly.go` | 设置里开关 + 依赖 Last.fm 凭据 + `bark_url`(或其它 `notification_platform`) |
| 历史 Top10 歌手统计 | 一天算一次，推给网页展示 | `collector/topartists.go` | 设置里开关 + 依赖 Last.fm 凭据 + `state_relay_url` |
| 网页模块可见性 | 单独控制展示页要不要显示历史/评论/表情反应/访客数/Top10 歌手 | `collector/features.go` + `state-worker/` + `web/` | 设置里「网页推送」卡片「网页展示模块」5 个开关 |
| 故障告警 | media-control/状态中继连续失败时推通知 | `collector/alerter.go` | 设置里开关 + `config.json` 填 `bark_url`(或其它 `notification_platform`) |

```
Mac 采集器(Go, launchd 常驻)
  └─ media-control stream (MediaRemote, 免授权、事件驱动)
       └─ 提交 playing_now / listen ──> ListenBrainz
                                            ↑ 公开 API（读取免 key）
展示页 web/index.html?user=<LB用户名> ──浏览器轮询──┘
  封面图：iTunes Search API（浏览器端直连，带 localStorage 缓存）
```

## 部署 Worker（可选：国内加速 / 徽章 / 飞书场景）

这三个都是可选的 Cloudflare Worker，核心链路（采集器 + ListenBrainz + 展示页）不依赖它们也能完整工作。彼此也有依赖顺序：`badge-worker` 需要读一个已经在跑的 `state-worker`；`worker/` 只服务于作者本人的飞书个性签名场景（需要你自己注册一个飞书应用），不打算做这件事的话可以完全跳过。

| 目录 | Worker 名 / 域名 | 职责 | 依赖 |
|---|---|---|---|
| `state-worker/` | `nowplaying-state`，示例域名 `np.yudaotor.me` | 网页主数据源：`/now`/`/history`/`/cover`/`/share` | 无（独立可部署） |
| `badge-worker/` | `nowplaying-badge` | GitHub README 动态 SVG 徽章 | 需要一个已部署的 `state-worker` |
| `worker/` | 示例域名 `test-0703.cyh-937ae0.workers.dev` | 飞书签名链接被真人点开时的 302 跳转，纯静态跳转 | 仅飞书个性签名场景需要，可跳过 |

部署命令已统一成同一句 `npm run deploy`：

```bash
cd state-worker && npm run deploy   # 或 badge-worker / worker，命令一样
```

在已经搭好的 Cloudflare 账号上重新发布代码改动，`state-worker`/`badge-worker` 用不到 `wrangler secret put`(`PUSH_TOKEN` 等)之外的额外步骤；`wrangler.toml` 里的 `[vars]`/`[[kv_namespaces]]` 已经提交，不含密钥——但 `[vars]` 里的 `LB_USER`/`WEB_PAGE_URL`/`RELAY_URL`/`WEB_CARD_URL` 目前提交的是**作者自己的值**，自建时务必按下面「从零搭建」章节逐一改成你自己的，否则新部署会静默展示/跳转到作者本人的数据（不报错，看着像成功了）。

### 从零搭建 state-worker（新 Cloudflare 账号/新机器）

上面这条 `npm run deploy` 假设 Cloudflare 账号、KV 命名空间、自定义域名路由都已经配好——`wrangler.toml` 里提交的 `[[kv_namespaces]]` 的 `id`、`[[routes]]` 的 `np.yudaotor.me` 都是这次一次性搭建的产物。真要在一个全新的 Cloudflare 账号上从零搭一遍，完整步骤：

1. 注册 Cloudflare 账号（免费额度足够：KV 每天 1000 次写/10 万次读）。
2. 把要用的域名（如这里的 `yudaotor.me`）的 DNS 托管迁移到这个 Cloudflare 账号——`[[routes]]` 的自定义域名路由要求域名的 zone 已经在同一账号下，否则这一步会失败。（没有自己的域名也可以先用 Cloudflare 分配的 `*.workers.dev` 子域名，跳过第 2/5 步。）
3. `npx wrangler login` 授权 CLI 登录这个账号。
4. 建 KV 命名空间：`npx wrangler kv namespace create NP_STATE`，把返回的 `id` 填进 `state-worker/wrangler.toml` 的 `[[kv_namespaces]]`（现在提交的这份 id 就是这一步的产物，换账号需要生成一个新的）。
5. 确认/改 `wrangler.toml` 的 `[[routes]]` 域名为你自己的域名（不需要额外操作，`custom_domain = true` 首次 `deploy` 时会自动在 Cloudflare 里建好这条自定义域名绑定，前提是第 2 步的 DNS 托管已经生效）。
6. **改 `[vars]` 的 `LB_USER` 和 `WEB_PAGE_URL`**：分别改成你自己的 ListenBrainz 用户名、你自己部署的展示页链接（形如 `https://<你的域名>/index.html?user=<你的LB用户名>`）。这两个值分别是 `/now`·`/history`·`/cover` 在 KV 未命中时的 LB 兜底数据源、和 `/share` 社交分享卡片的跳转目标——不改的话，这几个端点会静默返回/跳转到作者本人的数据。
7. 设置两个 secret（`wrangler.toml` 里只留了变量名的注释，值不提交进仓库）：
   ```bash
   cd state-worker
   npx wrangler secret put PUSH_TOKEN   # 采集器 POST /push、/top-artists 用的鉴权 token，随机生成一串即可
   npx wrangler secret put ADMIN_TOKEN  # 站长手动 POST /comments/delete 删留言用，跟 PUSH_TOKEN 不是同一个
   ```
8. `npm run deploy`。
9. 采集器这边 `~/.config/applemusic-nowplaying/config.json` 填两项，跟第 7 步的 `PUSH_TOKEN` 对上：
   ```json
   "state_relay_url": "https://np.yudaotor.me",
   "state_relay_token": "跟 PUSH_TOKEN 相同的值"
   ```
   填完后设置里打开「推送状态到网页/徽章」开关（或重启 collector 让 `config.json` 生效），采集器就会开始往这个 KV 推状态，网页/徽章会自动读到。

### 从零搭建 badge-worker（可选）

前提是已经有一个跑起来的 state-worker（上一节）。

1. `badge-worker/wrangler.toml` 的 `[vars]` 改 `RELAY_URL` 为你自己 state-worker 的域名/`*.workers.dev` 地址——这是 badge-worker 唯一真正读取的配置项，不改的话徽章会无错误地正常渲染，但内容是作者本人此刻在听的歌。
2. `cd badge-worker && npm run deploy`。
3. README 里嵌入：`![now playing](https://<你的badge-worker>.workers.dev/badge)`。

### worker/（可选，仅飞书个性签名场景用）

跳过条件：不打算在飞书个性签名/消息里显示动态卡片，就完全不需要这个 Worker。

要用的话：这只是"人点开链接时 302 跳转到展示页"这一环，飞书回调本身由完全独立的私有仓库 [`Yudaotor/feishu-bot`](https://github.com/Yudaotor/feishu-bot) 处理（需要你自己注册一个飞书应用，部署方式见那边的 README）。把 `worker/wrangler.toml` 的 `LB_USER`/`WEB_CARD_URL` 改成你自己的值，`cd worker && npm run deploy`，再把这个 Worker 的地址配进你自己的飞书应用 URL 规则里。

## 架构与密钥用途一览

```
飞书客户端粘贴链接 test-0703.cyh-937ae0.workers.dev/np
  └─ 命中「链接预览」应用 URL 规则
       └─ 飞书经【长连接】回调 feishu-bot(独立仓库，Go, launchd 常驻)
            └─ 读 ListenBrainz playing-now → 返回 Inline{i18n_title[, image_key]}
Worker(test-0703) 只负责：人点链接时 302 跳转到展示页；URL 规则字符串匹配(飞书不回源抓它)
```

| 子系统 | 部署位置 | 职责 | 是否读/解析 LB 原始数据 |
|---|---|---|---|
| `collector/` | 一台 Mac，launchd 常驻(Go) | 唯一的数据源头：读 media-control，提交 playing_now/listen 给 LB，同时把富状态(封面/主色/歌词/进度/链接)推进 `state-worker` 的 KV | 只写不读 |
| `state-worker/` | Cloudflare Worker（可选） | 网页的主数据源：`/now`(读KV,过期/为空则兜底直连LB)、`/history`(直接读LB)、`/cover`+`/share`(社交解链用) | ✅ `fromLB()`/`lbHistory()` |
| `web/index.html` | 静态托管（GitHub Pages / Cloudflare Pages，独立仓库） | 展示页；主读 `state-worker`（如果部署了的话），`state-worker`本身也连不上时才直连 LB 兜底 | ✅ 自己的 `fromLB`/历史映射(见下) |
| `worker/`（可选） | Cloudflare Worker | 飞书签名里粘的链接被真人点开时的 302 跳转，纯静态跳转 | 否 |
| `badge-worker/`（可选） | Cloudflare Worker | GitHub README 里的动态 SVG 徽章；读 `state-worker` 的 `/now`(已归一化好的数据)，不直连 LB | 否，依赖 state-worker 的契约 |
| `desktop-lyrics/`（可选） | 一台 Mac，用户手动/开机启动的前台 GUI(Swift) | 菜单栏 + 悬浮歌词窗口；轮询 `state-worker` 的 `/now`，跟网页版同一份契约 | 否，依赖 state-worker 的契约 |

**LB 原始数据(`track_metadata`/`additional_info`)的解析目前分散在两处、无法真正合一**：`state-worker/src/index.js` 的 `fromLB()`/`lbHistory()` 与 `web/index.html` 的同名函数几乎逐字段相同，只是命名/返回形状因各自消费端要求略有出入（前者是要公开的 API 响应契约、后者是给 `paint()` 直接吃的内部变量）。两处分别部署在 Cloudflare Workers 和 GitHub Pages 两个不相关平台，中间没有共用的构建/打包步骤，做不到导入同一份源码——两处函数体里都留了互相指向对方文件的注释，**改一处务必去对面照样改一遍**，否则两边会悄悄漂移不一致。

## 行为说明

- 播放中每 60 秒刷新一次 ListenBrainz 的 playing_now（playing_now 会随曲目时长自动过期）。
- 收听历史按标准 scrobble 规则落库：播满曲长一半或 4 分钟（取小），短于 30 秒的曲目不记。
- 只认 `bundle_ids` 里的播放器（默认仅 Music.app），浏览器放视频不会被误报。
- 单曲循环重复播放同一首也会分别计入收听：检测到播放位置从接近末尾（≥90% 时长）跳回接近开头（≤10 秒）时，判定为新一轮播放，重新计时。
- 页面在无播放时回退显示「上次播放 · N 分钟前」。

## 已知限制 / 尚待完善

这个仓库目前是从个人单机项目转出来的，以下这条还比较粗糙，欢迎 PR：

- album-prefetch（专辑预取）和精确播放进度这两个功能实际会用 `osascript` 操作 Music.app，需要一次性的自动化/Apple Events 授权（不像核心的 media-control 读取路径那样完全免授权）；在无 GUI 会话的场景下授权弹窗弹不出来，会静默降级为不可用，不影响核心功能。

以下几条已经修复，但受限于这台机器只有 Apple Silicon，没有真机验证过：

- desktop-lyrics 的 `build.sh` 在拷贝完二进制后先主动 `codesign -s - --force` 再验证，而不是只验证——之前只验证的写法在 Apple Silicon 上因为系统强制签名没问题，但理论上在 Intel Mac 上可能因为工具链没有自动签名而直接报错退出整个脚本。现在无论哪种架构都会重新 ad-hoc 签一遍，Apple Silicon 上是无副作用的重复操作。

## 已知环境坑（作者自己的 Mac, macOS 27 beta）

- iTerm2 进程树发 Apple Events 一律 -1712 超时（弹窗弹不出来），AppleScript/JXA 路线不可用——所以采集端选了 media-control（MediaRemote adapter 技巧，免 TCC）。
