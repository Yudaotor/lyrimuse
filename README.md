# applemusic-nowplaying

在飞书签名（或任何地方）放一个固定链接，动态展示这台 Mac 上 Apple Music 正在播放的歌。

线上页：https://yudaotor.github.io/nowplaying/?user=yudaotor （仓库 github.com/Yudaotor/nowplaying，web/index.html 的独立 git 仓）

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

飞书个性签名 / 消息里动态卡片（不点链接就显示当前歌）：

```
飞书客户端粘贴链接 test-0703.cyh-937ae0.workers.dev/np
  └─ 命中「链接预览」应用(cli_aacda2c62bf7dcff) URL 规则
       └─ 飞书经【长连接】回调 feishu-bot(Go, launchd 常驻)
            └─ 读 ListenBrainz playing-now → 返回 Inline{i18n_title[, image_key]}
Worker(test-0703.cyh-937ae0.workers.dev) 只负责：人点链接时 302 跳转到展示页；URL 规则字符串匹配（飞书不回源抓它）
```

为什么用长连接而非公网回调：飞书国内服务器访问 Cloudflare workers.dev 回调 3 秒超时，长连接由 bot 主动外连、无需公网 inbound。踩坑细节见记忆笔记 `feishu-dynamic-signature-via-link-preview-longconn`。

## 内部子系统与密钥用途一览

| 子系统 | 部署位置 | 职责 | 是否读/解析 LB 原始数据 |
|---|---|---|---|
| `collector/` | 这台 Mac，launchd 常驻(Go) | 唯一的数据源头：读 media-control，提交 playing_now/listen 给 LB，同时把富状态(封面/主色/歌词/进度/链接)推进 `state-worker` 的 KV | 只写不读 |
| `state-worker/` | Cloudflare Worker（`np.yudaotor.me`） | 网页的主数据源：`/now`(读KV,过期/为空则兜底直连LB)、`/history`(直接读LB)、`/cover`+`/share`(社交解链用) | ✅ `fromLB()`/`lbHistory()` |
| `web/index.html` | GitHub Pages（独立仓 `Yudaotor/nowplaying`） | 展示页；主读 `state-worker`，`state-worker`本身也连不上时才直连 LB 兜底 | ✅ 自己的 `fromLB`/历史映射(见下) |
| `feishu-bot/` | 这台 Mac，launchd 常驻(Go) | 飞书长连接，应答 `url.preview.get` 拼预览卡片；直连 LB，自己独立解析(只取title/artist/album三个字段，逻辑比上面两处简单得多) | ✅ `nowPlaying()` |
| `worker/`（`test-0703`） | Cloudflare Worker | 飞书签名里粘的链接被真人点开时的 302 跳转；**不再**处理 Feishu 回调、不解析 LB，纯静态跳转 | 否（已在 2026-07-08 简化掉） |
| `badge-worker/` | Cloudflare Worker | GitHub README 里的动态 SVG 徽章；读 `state-worker` 的 `/now`(已归一化好的数据)，不直连 LB | 否，依赖 state-worker 的契约 |

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

只用来在飞书个性签名/消息里显示动态卡片，跳过不影响采集器和展示页。

```bash
cd feishu-bot && go build -o ../bin/feishu-bot .
mkdir -p ~/.config/applemusic-nowplaying
cp feishu.example.json ~/.config/applemusic-nowplaying/feishu.json
chmod 600 ~/.config/applemusic-nowplaying/feishu.json
# 编辑 feishu.json：feishu_app_id/feishu_app_secret/listenbrainz_user 必填

cp launchd/com.chenyuhao.applemusic-feishu-bot.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.chenyuhao.applemusic-feishu-bot.plist
# 日志: ~/Library/Logs/applemusic-feishu-bot.log
```

飞书应用需开启「链接预览」能力并配置长连接，踩坑细节见上文与记忆笔记 `feishu-dynamic-signature-via-link-preview-longconn`。

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
