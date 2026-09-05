---
name: lyrimuse-lyrics-triage
description: "lyrimuse 歌词排查 / lyrics troubleshooting — 「歌词不出来」「这首匹配错了」「某个源好像挂了」这类问题按固定路径排：先 healthcheck，再分源，再看那首歌的决策留痕，最后才翻日志。只写步骤与判据，理由回链 AGENTS.md 与 docs/features。"
---

# lyrimuse 歌词排查

> 只写步骤与判据；理由在链接里。别上来就翻日志（[AGENTS.md「验证纪律」](../../../AGENTS.md)）。

## 一、整体健康

1. `/Applications/Lyrimuse.app/Contents/Resources/collector healthcheck -local-only`（快，不联网）：配置 / 歌词源开关 / 缓存 / 导出目录 / 账号配置一次看齐。
2. 同一命令去掉 `-local-only`（约 30s）：多了两首固定探测曲实测各源 + 网络是否通。含义见 [15 章 §5](../../../docs/features/15-ops-background.md)。
3. 设置页「歌词来源」卡每个源有独立「测试」按钮，跟 healthcheck 复用同一套探测（[14 章](../../../docs/features/14-settings-config.md) 代码锚点「歌词来源可用性测试」）。**别拿探测曲的结果推断具体某首歌**——探测曲是刻意挑的容易命中的歌。

## 二、某个源整个哑掉

4. 先分清「被拦」还是「连不上」（AGENTS.md「容易踩的具体坑 → 某个歌词源整个哑掉」）：被反爬拦会正经返回 401 + `hint=captcha`；DNS 劫持是 TLS 握手直接失败、一个字节拿不到。判据：`curl --resolve <域名>:443:<DoH 查到的真实 IP> https://<域名>/` 能不能通；修法见 `lyrimuse-collector/doh.go`。
5. musixmatch 批量解析时并发换 token 会被当反爬拒（[09 章](../../../docs/features/09-lyrics-resolution.md)「数据与文件」那条 ⚠️）。相册预取 / 批量导入期间的 401 先想到这条。

## 三、具体某首歌

6. 歌词管理里选中那首歌 → 「解析决策」（[11 章 §6](../../../docs/features/11-lyrics-manager.md)）：查询词、时长、哪些源应答、每个候选的分数与被拒原因、胜者。留痕有两槽——「最近一次评估」与「当前歌词的出处」，看错槽会得出相反结论（[09 章 §8](../../../docs/features/09-lyrics-resolution.md)）。
7. 命令行复现检索：`collector search-lyrics`（歌词管理手动搜索走的同一条路，参数看 `lyrimuse-collector/searchcli.go`）；只看某一个源：`collector test-lyric-sources`（`lyrimuse-collector/testlyricsourcescli.go`）。
8. 要改打分 / 检索挑选逻辑：先读 `match.go` 注释里的消融结论，改完必须过金标集 `cd lyrimuse-collector && GOTOOLCHAIN=go1.24.4 go test -run 'TestLyricsGolden|TestGolden' .`；打分逻辑变了同步 `lyricsScoringVersion`，冠军变了逐首 `LYRICS_GOLDEN_ACCEPT_SEMANTIC=<样本id>` 点头（AGENTS.md「容易踩的具体坑 → 歌词打分」；09 章「歌词搜索回归金标集」）。
9. 同一首歌两种写法出两条缓存（表现为「Spotify 和 Apple Music 播同一首进度不一样」）：key 一律经 `enrichKey()`，Swift 侧镜像 `EnrichCacheKeys.swift`（AGENTS.md「enrich 缓存的 key」）。

## 四、日志

10. collector：`~/Library/Logs/lyrimuse.log`，行首 `time=<UTC> level=… msg=`；按组件前缀 grep（`lyrics:` / `netease:` / `enrich:` / `cache:` / `proxy:`），进程为何退了 grep `exiting reason=`。每分钟一行 `api call summary` 是对外请求聚合，不是错误（AGENTS.md「日志按业界通用范式写」）。
11. App：`log show --last 30m --predicate 'subsystem == "me.yudaotor.lyrimuse"'`；launchd stderr 在 `~/Library/Logs/lyrimuse-app.log`。**日志里没有歌词正文与凭据**，找不到是设计。
12. 要给用户或 issue 的，走设置页「导出诊断信息…」（[14 章 §7](../../../docs/features/14-settings-config.md)），已脱敏并附 healthcheck 与两侧日志尾巴。

## 不要做

- 不要为了复现去 `launchctl` 停真实的 collector；验 launchd 行为用 `lyrimuse/scripts/probe-launchd.sh`（AGENTS.md「验证纪律」）。
- 不要拿 `lyrimuse/scripts/uninstall.sh --purge` 清缓存做「干净复现」，那会删掉用户手改过的歌词。
- 读用户真实的 `~/.config/lyrimuse/config.json` 只看键名，值是凭据，不要打印进会话。
