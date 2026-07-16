# applemusic-nowplaying

在飞书签名（或任何地方）放一个固定链接，动态展示这台 Mac 上 Apple Music 正在播放的歌。

线上页：https://yudaotor.github.io/nowplaying/?user=yudaotor （仓库 github.com/Yudaotor/nowplaying，web/index.html 的独立 git 仓，公开）

本目录其余部分(collector/state-worker/badge-worker/worker/launchd)另在私有仓库 github.com/Yudaotor/nowplaying-backend 版本控制；`web/` 已加进 `.gitignore`，两个仓库互不影响。飞书动态签名卡片(`feishu-bot`)是完全独立的小工具，跟 collector 没有代码耦合，已拆成单独的私有仓库 github.com/Yudaotor/feishu-bot，同样加进了 `.gitignore`。

## 功能一览

作为一个整体的 Apple Music 配套软件，这些是它目前支持的能力。除了核心追踪/提交（存在的根本意义，不可关）和三个常驻部署的 Cloudflare Worker（跟本机进程无关，本机没有开关能控制它们本身），其余都能在 desktop-lyrics 的「设置」窗口按开关单独打开/关闭（改完自动写共享文件+重启 collector，见 `collector/features.go`/`desktop-lyrics/Sources/desktop-lyrics/Settings/FeatureSettingsStore.swift`）。

| 功能 | 一句话说明 | 实现子系统 | 怎么开关 |
|---|---|---|---|
| ListenBrainz 提交 | 提交 playing_now/listen，是整个项目存在的根本意义 | `collector/` | 始终开启；要关掉就是卸载/停用整个 collector |
| 展示页「正在播放」 | 网页显示当前/历史播放 | `collector/` + `state-worker/` + `web/` | 展示页本身常驻部署，不经本机控制 |
| 状态中继(国内加速) | 采集器把当前状态推进 KV，网页优先读它、拿不到才回退直连 LB | `collector/` + `state-worker/` | 设置里「推送状态到网页/徽章」开关 + `config.json` 填 `state_relay_url` |
| GitHub 动态徽章 | README 里的实时 SVG 徽章 | `badge-worker/`(读 state-worker) | 常驻部署，本机不可控；依赖上面「状态中继」有没有新鲜数据 |
| 悬浮歌词窗口 | 桌面浮层实时显示当前歌词，支持逐字高亮 | `desktop-lyrics/` | 菜单栏「显示悬浮歌词」 |
| 歌词管理窗口 | 查看/手改/删除/重新搜索候选每首歌的歌词 | `desktop-lyrics/` | 菜单栏「歌词管理…」 |
| 封面/主色/平台跳转链接 | 抓封面(网易云/QQ 兜底)、算主色、拼 Apple/QQ/Spotify 跳转链接 | `collector/enrich.go` | 设置里「封面/主色/平台跳转链接」开关 |
| 歌词多源解析 | 网易云/QQ音乐/酷狗/LRCLIB 四源都查一遍、取打分最高的 | `collector/enrich.go` | 设置里「歌词解析」开关 |
| 歌词文件夹作为权威源 | `~/.config/applemusic-nowplaying/lyrics/` 下的纯文本文件可以直接手改，collector 重启时导入生效 | `collector/lyricsimport.go`/`lyricsexport.go` | 设置里「歌词文件夹作为权威源」开关 |
| 专辑预取 | 换歌时顺手把同专辑其它还没解析过的曲目丢到后台解析 | `collector/albumprefetch.go` | 设置里「换歌时预取同专辑其它曲目」开关 |
| iPhone 播放桥接 | 把 iPhone 上经 Last.fm(FastScrobbler)记录的播放转发进 ListenBrainz | `collector/poller.go`(`bridge`) | 设置里开关 + `config.json` 填 `lastfm_user`/`lastfm_api_key` |
| Mac 播放同步进 Last.fm | 反向把 Mac 播放也镜像写进 Last.fm，让 Last.fm 上有完整历史 | `collector/lastfm.go` | 设置里开关 + `config.json` 填 `lastfm_scrobble_*` 三项 |
| 每周听歌小结 | 每周 Last.fm 图表收官时推一条 Bark 通知 | `collector/weekly.go` | 设置里开关 + 依赖 Last.fm 凭据 + `bark_url` |
| 历史 Top10 歌手统计 | 一天算一次，推给网页展示 | `collector/topartists.go` | 设置里开关 + 依赖 Last.fm 凭据 + `state_relay_url` |
| 故障告警 | media-control/状态中继连续失败时推 Bark 通知 | `collector/alerter.go` | 设置里开关 + `config.json` 填 `bark_url` |

```
Mac 采集器(Go, launchd 常驻)
  └─ media-control stream (MediaRemote, 免授权、事件驱动)
       └─ 提交 playing_now / listen ──> ListenBrainz
                                            ↑ 公开 API（读取免 key）
展示页 web/index.html?user=<LB用户名> ──浏览器轮询──┘
  封面图：iTunes Search API（浏览器端直连，带 localStorage 缓存）
```

国内访问加速：自建状态中继 state-worker/（Cloudflare Worker + KV，域名 `np.yudaotor.me`），采集器把当前状态直推进 KV，网页优先读它、拿不到才回退直连 LB。

（曾尝试用腾讯云 EdgeOne Pages 做同样的中转，边缘函数已写好也验证过能跑，但免备案部署的默认域名对中国大陆访问一律 401（这是产品限制，不是慢，见记忆笔记 `edgeone-pages-china-acceleration-proxy`），要大陆能访问必须 ICP 备案自定义域，权衡后放弃，相关代码/部署已于 2026-07-08 下线。）

飞书个性签名 / 消息里动态卡片（不点链接就显示当前歌）——`feishu-bot` 已拆成独立仓库 [`Yudaotor/feishu-bot`](https://github.com/Yudaotor/feishu-bot)（部署方式见那边的 README），这里只保留跟本仓库 `worker/` 有关的那部分架构：

```
飞书客户端粘贴链接 test-0703.cyh-937ae0.workers.dev/np
  └─ 命中「链接预览」应用(cli_aacda2c62bf7dcff) URL 规则
       └─ 飞书经【长连接】回调 feishu-bot(独立仓库，Go, launchd 常驻)
            └─ 读 ListenBrainz playing-now → 返回 Inline{i18n_title[, image_key]}
Worker(test-0703.cyh-937ae0.workers.dev) 只负责：人点链接时 302 跳转到展示页；URL 规则字符串匹配（飞书不回源抓它）
```

## 内部子系统与密钥用途一览

| 子系统 | 部署位置 | 职责 | 是否读/解析 LB 原始数据 |
|---|---|---|---|
| `collector/` | 这台 Mac，launchd 常驻(Go) | 唯一的数据源头：读 media-control，提交 playing_now/listen 给 LB，同时把富状态(封面/主色/歌词/进度/链接)推进 `state-worker` 的 KV | 只写不读 |
| `state-worker/` | Cloudflare Worker（`np.yudaotor.me`） | 网页的主数据源：`/now`(读KV,过期/为空则兜底直连LB)、`/history`(直接读LB)、`/cover`+`/share`(社交解链用) | ✅ `fromLB()`/`lbHistory()` |
| `web/index.html` | GitHub Pages（独立仓 `Yudaotor/nowplaying`） | 展示页；主读 `state-worker`，`state-worker`本身也连不上时才直连 LB 兜底 | ✅ 自己的 `fromLB`/历史映射(见下) |
| `feishu-bot` | 独立仓库 [`Yudaotor/feishu-bot`](https://github.com/Yudaotor/feishu-bot)（私有），这台 Mac 上 launchd 常驻(Go) | 飞书长连接，应答 `url.preview.get` 拼预览卡片；配置了 `state_relay_url` 就优先读 state-worker 的 `/now`(国内可达、自带封面)，失败/未配置才退回直连 LB+iTunes | ✅ `nowPlaying()`（relay 命中时不读 LB，直连兜底才读） |
| `worker/`（`test-0703`） | Cloudflare Worker | 飞书签名里粘的链接被真人点开时的 302 跳转；**不再**处理 Feishu 回调、不解析 LB，纯静态跳转 | 否（已在 2026-07-08 简化掉） |
| `badge-worker/` | Cloudflare Worker | GitHub README 里的动态 SVG 徽章；读 `state-worker` 的 `/now`(已归一化好的数据)，不直连 LB | 否，依赖 state-worker 的契约 |
| `desktop-lyrics/` | 这台 Mac，用户手动/开机启动的前台 GUI(Swift) | 菜单栏 + 悬浮歌词窗口；轮询 `state-worker` 的 `/now`，跟网页版同一份契约 | 否，依赖 state-worker 的契约 |

**LB 原始数据(`track_metadata`/`additional_info`)的解析目前分散在两处、无法真正合一**：`state-worker/src/index.js` 的 `fromLB()`/`lbHistory()` 与 `web/index.html` 的同名函数几乎逐字段相同，只是命名/返回形状因各自消费端要求略有出入（前者是要公开的 API 响应契约、后者是给 `paint()` 直接吃的内部变量）。两处分别部署在 Cloudflare Workers 和 GitHub Pages 两个不相关平台，中间没有共用的构建/打包步骤，做不到导入同一份源码——两处函数体里都留了互相指向对方文件的注释，**改一处务必去对面照样改一遍**，否则两边会悄悄漂移不一致。`feishu-bot` 也独立解析了一份 LB 数据，但只取 3 个字段（不含 `additional_info`），复杂度和上面两处不是一个量级，暂不纳入同步范围。

## 依赖

- `brew install media-control`（读系统正在播放；不需要 Apple Events / 自动化授权）
- Go 1.21+（编译采集器）
- ListenBrainz 账号：https://listenbrainz.org 注册，Settings 页拿 User Token

## 部署采集器

```bash
cd collector && go build -o ../bin/collector .
mkdir -p ~/.config/applemusic-nowplaying
cp config.example.json ~/.config/applemusic-nowplaying/config.json
chmod 600 ~/.config/applemusic-nowplaying/config.json
# 编辑 config.json：listenbrainz_token/listenbrainz_user 必填，其余字段
# (state_relay_*/lastfm_*/bark_url) 都是可选功能，留空即关闭对应功能

# 先前台试跑（--dry-run 只打日志不真提交）
./bin/collector -dry-run

# 常驻
cp launchd/com.chenyuhao.applemusic-nowplaying.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.chenyuhao.applemusic-nowplaying.plist
# 日志: ~/Library/Logs/applemusic-nowplaying.log
```

### 获取 `lastfm_scrobble_session_key`（Last.fm 镜像写入用，可选）

这是把 Mac 播放镜像写进 Last.fm(`lastfmScrobbler`，见 `collector/lastfm.go`)要用的凭证，跟桥接 iPhone 播放用的 `lastfm_user`/`lastfm_api_key` 是两回事。session key 永久有效，正常只需申请一次；万一要在新机器/新账号上重新申请，按下面步骤走一遍，不用翻代码。

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

## 部署飞书 bot（可选）

只用来在飞书个性签名/消息里显示动态卡片，跳过不影响采集器和展示页。这部分已拆到独立仓库
[`Yudaotor/feishu-bot`](https://github.com/Yudaotor/feishu-bot)（私有），部署方式、配置说明、
长连接原理见那边的 README，不在这里重复一遍。

## 部署 Worker（state-worker / badge-worker / worker）

三个 Cloudflare Worker，部署命令已统一成同一句 `npm run deploy`（各自 `package.json` 里都是这一条脚本，具体实现细节不强求一致——`worker/` 本来就有锁定版本的 `node_modules`，就沿用它自己那份；`state-worker/`/`badge-worker/` 没有锁定版本，走 `npx wrangler deploy` 拉当前可用版本）：

| 目录 | Worker 名 / 域名 | 职责 |
|---|---|---|
| `state-worker/` | `nowplaying-state`，`np.yudaotor.me` | 网页主数据源：`/now`/`/history`/`/cover`/`/share` |
| `badge-worker/` | `nowplaying-badge` | GitHub README 动态 SVG 徽章 |
| `worker/` | `test-0703.cyh-937ae0.workers.dev` | 飞书签名链接被真人点开时的 302 跳转 |

```bash
cd state-worker && npm run deploy   # 或 badge-worker / worker，命令一样
```

在已经搭好的 Cloudflare 账号上重新发布代码改动，`state-worker`/`badge-worker` 用不到 `wrangler secret put`(`PUSH_TOKEN` 等)之外的额外步骤；`wrangler.toml` 里的 `[vars]`/`[[kv_namespaces]]` 已经提交，不含密钥。

### 从零搭建 state-worker（新 Cloudflare 账号/新机器）

上面这条 `npm run deploy` 假设 Cloudflare 账号、KV 命名空间、自定义域名路由都已经配好——`wrangler.toml` 里提交的 `[[kv_namespaces]]` 的 `id`、`[[routes]]` 的 `np.yudaotor.me` 都是这次一次性搭建的产物。真要在一个全新的 Cloudflare 账号上从零搭一遍，完整步骤：

1. 注册 Cloudflare 账号（免费额度足够：KV 每天 1000 次写/10 万次读）。
2. 把要用的域名（如这里的 `yudaotor.me`）的 DNS 托管迁移到这个 Cloudflare 账号——`[[routes]]` 的自定义域名路由要求域名的 zone 已经在同一账号下，否则这一步会失败。
3. `npx wrangler login` 授权 CLI 登录这个账号。
4. 建 KV 命名空间：`npx wrangler kv namespace create NP_STATE`，把返回的 `id` 填进 `state-worker/wrangler.toml` 的 `[[kv_namespaces]]`（现在提交的这份 id 就是这一步的产物，换账号需要生成一个新的）。
5. 确认/改 `wrangler.toml` 的 `[[routes]]` 域名为你自己的域名（不需要额外操作，`custom_domain = true` 首次 `deploy` 时会自动在 Cloudflare 里建好这条自定义域名绑定，前提是第 2 步的 DNS 托管已经生效）。
6. 设置两个 secret（`wrangler.toml` 里只留了变量名的注释，值不提交进仓库）：
   ```bash
   cd state-worker
   npx wrangler secret put PUSH_TOKEN   # 采集器 POST /push、/top-artists 用的鉴权 token，随机生成一串即可
   npx wrangler secret put ADMIN_TOKEN  # 站长手动 POST /comments/delete 删留言用，跟 PUSH_TOKEN 不是同一个
   ```
7. `npm run deploy`。
8. 采集器这边 `~/.config/applemusic-nowplaying/config.json` 填两项，跟第 6 步的 `PUSH_TOKEN` 对上：
   ```json
   "state_relay_url": "https://np.yudaotor.me",
   "state_relay_token": "跟 PUSH_TOKEN 相同的值"
   ```
   填完后设置里打开「推送状态到网页/徽章」开关（或重启 collector 让 `config.json` 生效），采集器就会开始往这个 KV 推状态，网页/徽章会自动读到。

## 展示页

纯静态、零后端（ListenBrainz 与 iTunes Search 均允许浏览器跨域直读）。
托管到任意静态站（GitHub Pages / Cloudflare Pages），链接形如：

```
https://<你的域名>/index.html?user=<ListenBrainz用户名>
```

把这个链接放进飞书个性签名即可。

## 行为说明

- 播放中每 60 秒刷新一次 ListenBrainz 的 playing_now（playing_now 会随曲目时长自动过期）。
- 收听历史按标准 scrobble 规则落库：播满曲长一半或 4 分钟（取小），短于 30 秒的曲目不记。
- 只认 `bundle_ids` 里的播放器（默认仅 Music.app），浏览器放视频不会被误报。
- 单曲循环重复播放同一首也会分别计入收听：检测到播放位置从接近末尾（≥90% 时长）跳回接近开头（≤10 秒）时，判定为新一轮播放，重新计时。
- 页面在无播放时回退显示「上次播放 · N 分钟前」。

## 已知环境坑（这台 Mac, macOS 27 beta）

- iTerm2 进程树发 Apple Events 一律 -1712 超时（弹窗弹不出来），AppleScript/JXA 路线不可用——所以采集端选了 media-control（MediaRemote adapter 技巧，免 TCC）。
