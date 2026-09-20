# Lyrimuse 往 Last.fm 打卡（scrobble）的规则

*[English](scrobbling.md)*

## 1. 什么时候算一次收听

同时满足这几条才提交：

| 判据 | 取值 |
|---|---|
| 播够时长 | 曲长的一半，上限 240 秒；曲长未知则固定 240 秒。可以只对 Last.fm 调得更严，见 §1b |
| 曲子够长 | `≥ 30 秒`（时长未知也放行）。可以关掉，见 §1a |
| 不是广告 | 会识别并跳过 Spotify 的广告时段 |

每 5 秒采样一次，播放时长按墙钟累加，所以暂停就停止计数、拖进度条也不会灌水。如果两次采样
之间隔了 60 秒以上——机器睡了，或者采集器重启了——这一段间隔会被直接丢弃，不计入。

这套阈值对齐 [Last.fm 官方打卡规范](https://www.last.fm/api/scrobbling)。

### 1a. 短于 30 秒的曲目

设置 → 账号 → Last.fm → *Scrobble* → **短于 30 秒的曲目**（`scrobble_short_tracks`，默认**关**）。
Last.fm 的规则 *"The track must be longer than 30 seconds"* 是给客户端的——服务端不拒收短曲目、也没有
「太短」这一个 ignore 码——但所有主流 scrobbler 都照做，所以 Lyrimuse 默认也照做。打开后，短曲目只要
过了「听过一半」这条就记一次（20 秒的歌要听满 10 秒）。这是一个**只管 Last.fm** 的开关：短曲目会
scrobble 到 Last.fm（也会记进给 Last.fm 回填兜底的本地收听记录），但**不会**提交到 ListenBrainz——
开不开，ListenBrainz 那边都跟原来一样。

### 1b. Scrobble 时机

设置 → 账号 → Last.fm → *Scrobble* → **Scrobble 时机**（`lastfm_scrobble_point`，默认 **50%**）。决定一次收听
要听到哪里才记到 Last.fm：

| 档位 | 值 | 什么时候记 |
|---|---|---|
| **50%**（默认） | `50` | 上面那条官方规则：曲长一半，最多 4 分钟 |
| 75% / 90% | `75` / `90` | 听满曲长的 75% / 90%——纯按已播时长算，不套 4 分钟上限 |
| 曲终 | `end` | 一直放到结尾；中途切歌不算 |

官方规则是下限，所以没有低于 50% 的档。这是一个**只管 Last.fm** 的设置：ListenBrainz 和网页中继仍在 50% 那一刻
提交，只有 Last.fm 的 scrobble（以及给 Last.fm 回填兜底的本地收听记录）等到所选时点。没到点就切歌的，Last.fm
什么都不会收到——这正是这个设置该起的作用，不是丢了一条。曲长未知的曲目按默认规则。

「曲终」按换曲时最近一次观察到的播放位置判定：离曲尾不到 12 秒（短曲目按曲长的 10%）就算放完，所以播放器的
淡入淡出、无缝切歌不会让这条记不上。

## 2. 发出去的字段

`track.scrobble` 是往历史里写永久记录的；`track.updateNowPlaying` 只点亮"正在听"，不存任何东西。

| 字段 | `track.scrobble` | `track.updateNowPlaying` |
|---|---|---|
| `artist` | ✅ | ✅ |
| `track` | ✅ | ✅ |
| `timestamp` | ✅ | — |
| `album` | 非空才发 | 非空才发 |
| `duration` | 拿得到才发 | 拿得到才发 |

到 Last.fm 的就这些。他们的接口在一次 scrobble 里还接受 `mbid`、`albumArtist`、`trackNumber`、
`chosenByUser`、`streamId`、`context`，我们一个都不发。

## 3. 不做改写的部分

ListenBrainz 那一路、以及 Last.fm 的「全部」和「只发第一位」两档，歌手名、歌名、专辑名一律按
播放器报的原样提交。（Last.fm 的「智能」档会按编目条目改写歌手名和歌名，见下一节。）

唯一经过的处理是**不可见字符清洗**：不换行空格和全角空格换成普通空格、删掉零宽字符和 BOM、
连续空白折成一个、去掉首尾空白。不洗的话，一个肉眼看不见的不换行空格会在 Last.fm 上建出一个
独立的艺人实体。

任何**看得见**的内容都不动——不动大小写、不做繁简转换、不剥括号副题、不拆合唱串。`PRINCE`
还是 `PRINCE`，`無所謂` 还是 `無所謂`，`一口 (The Day You Left Me)` 的副题原样保留。

默认不去外部查询做"规范化"的依据：

- Lyrimuse 以前就是这么做的。对一份约 2500 首的真实曲库做审计，查出约 200 条艺人名被改写，
  其中包括 `USA for Africa` → `Xtc Planet`、`LBI利比` → `Safehse`。而已经写进 Last.fm 公共
  艺人页的打卡记录事后改不回来：他们的纠错库已经冻结。
- Last.fm 的打卡指南里这句话出现了两次：*"Do not use the corrections returned by the now
  playing service as input for the scrobble request, unless they have been explicitly approved by
  the user."*（除非用户明确批准，否则不要把 now playing 接口返回的纠正结果用作打卡请求的输入。）
  他们自家的 `autocorrect` 开关也已
  [标注为遗留功能](https://support.last.fm/t/scrobbles-of-japanese-artists-getting-separated-by-romanization-of-their-name/119906)。
- 调研过的九个开源 scrobbler（Web Scrobbler、Pano Scrobbler、Navidrome、Maloja、rescrobbled、
  mpdscribble、mpdas、Koito、multi-scrobbler），没有一个默认拿外部查询去改写艺人名。

## 4. 匹配模式

设置 → 账号 → Last.fm → *Scrobble* → **匹配模式**
（`~/.config/lyrimuse/lyrimuse-features.json` 里的 `lastfm_match_mode`）：

| 档位 | 值 | 效果 |
|---|---|---|
| **智能**（全新装机默认） | `smart` | 到 Last.fm 编目里找这首歌对应的条目，歌手和曲名都按那条发（见下） |
| 自定义 | `custom` | 自己选改哪些部分，见下表 |
| **原始**（老机器默认） | `raw` | 原样发播放器报的标签，一个字都不动，不联网 |

选了**自定义**才展开三个开关：

| 开关 | 值 | 效果 |
|---|---|---|
| 改写歌手 | `lastfm_match_artist` | 允许把歌手换成编目条目的写法 |
| 改写曲名 | `lastfm_match_track` | 允许把曲名换成编目条目的写法 |
| 合唱只发第一位 | `lastfm_match_first_artist_only` | 合唱串截成第一位歌手（`Khalil Fong & Fiona Sit` → `Khalil Fong`）——纯字符串处理，不联网 |

只开一个改写维度时，**另一个字段必须与原样一致才会采纳候选**——否则会拼出一个编目里根本
不存在的组合，又落回只有你一个听众的影子条目。

「合唱只发第一位」跟另两个不同：它**只在没匹配到编目条目时才生效**。匹配到的写法已经是
编目认的那一条，再截一刀就把它变成一个不存在的条目——`Hall & Oates / Maneater`（80 万听众）
会被截成 `Hall`。所以「只开截断、不开匹配」跟旧版的「只发第一位」逐字等价，照旧不联网。

老机器默认「原始」，因为无条件截断不可逆——截了，Fiona Sit（薛凯琪）就从你的历史里消失了。
Navidrome 同名的开关（`Lastfm.ScrobbleFirstArtistOnly`）默认同样是关。

切分是保守的：`/` 跟 `,`、`&` 分档处理，所以 `K/DA`、`AC/DC` 不会被切成 `K` 和 `AC`。

### 智能档

播放器报的标签和 Last.fm 编目里的写法经常不是同一套字，原样提交就落进一个「影子」条目——没有
MBID、没有专辑、时长 0、听众只有你一个。实测陶喆《那个女孩》：播放器报的
`陶喆, 卢广仲 / 那个女孩` 在 Last.fm 上查无此条，简体的 `陶喆 / 那个女孩` 只有 126 个听众，而这
首歌真正的条目是繁体的 **`陶喆 / 那個女孩`：889 个听众、4580 次播放、有编目时长**。Last.fm 自家的
`autocorrect` 帮不上——它不做繁简映射。

智能档因此在上送前先查一次编目：

1. 按原样查一次 `track.getInfo`。**有 MBID** → 一个字都不动，永久沿用。MBID 是编目正规身份最硬的
   信号，Hall & Oates 这类正规合体署名靠这一步保住，不会被「听众更多」挪到单人页去。
2. 否则收集候选——**只**有三处来源：原样、第一位歌手、以及**该歌手在编目里曲名对得上的条目**
   （`artist.getTopTracks`，本身就按听众降序）。
3. 在已被编目收录的候选（有 MBID、或听众 ≥ 500、或有编目时长——影子条目三样都没有）里取听众
   最多的一条，复核时长后按它的歌手 + 曲名提交，永久沿用。一条够格的都没有 → 原样发，90 天后再查。

它**不**用 `track.search`：那个按字面串搜，既找不到繁体那条，又会把 `张泽熙 / 那个女孩` 这种同名
不同歌带进来。曲名只折「同一份录音的写法差异」——繁简、异体字、变音符号、客串署名（`(feat. X)`）、
再版标记（`(Remastered 2014)` / `(Bonus Track)`）；**Live、Remix、伴奏、钢琴版这类真版本标记一律
保留**，它们是另一份录音。选中的条目还要过时长闸（两边都有时长且差超过 8 秒就不认）。

对 240 首真实曲目实测：改写 33 首、原样 162 首、判不了 45 首。改写的例子：

| 播放器报的 | 发出去的 | 听众 |
|---|---|---|
| `周杰倫 / 手写的从前` | `周杰倫 / 手寫的從前` | 100 → 4,515 |
| `Wang Leehom / 奇遇的起点` | `王力宏 / 奇遇的起點` | 1 → 144 |
| `SZA & Phoebe Bridgers / Ghost in the Machine` | `SZA / Ghost in the Machine (feat. Phoebe Bridgers)` | 175 → 856,376 |
| `PRINCE / Walk Don't Walk (2023 Remaster)` | `Prince / Walk Don't Walk` | 231 → 16,178 |

查询失败（网络、限流、应答不对、曲目表拉不动）一律原样发、不写缓存，一次抽风不会变成永久决定。
判定结果连同依据存在 `~/.config/lyrimuse/lyrimuse-lastfm-catalog.json`，删掉这个文件就全部重判。

旧的键仍然会读、但不再写，迁移后行为逐字不变：`lastfm_scrobble_artist_mode` 的
`smart`→智能、`all`→原始、`first`→自定义且只开「合唱只发第一位」；更早的布尔开关
`lastfm_scrobble_first_artist_only=true` 等同于 `first`。

## 5. 提交失败了怎么办

失败会分类处理，因为正确的应对方式本来就不同。下表里的"留痕"指写进本地日志，之后可以靠
**回填**补上——回填要在「待推送的收听」那一行手动发起，不会自动跑。

| 发生了什么 | 我们怎么做 |
|---|---|
| 能证明请求根本没离开你的电脑（DNS、连接失败） | 留痕，回填可以补 |
| 服务端拒了，但那个理由意味着它**确定没落库**（凭据失效、限流） | 留痕，回填可以补 |
| 发出去了，但结果未知（超时、连接中断、语义不明的服务端错误） | 留痕，但回填**绝不**自动重试它 |
| 服务端收到了曲目、拒绝的是内容本身 | 不留痕，把服务端给的真实原因暴露出来 |

第三行单列，是因为超时也可能意味着 Last.fm 其实已经存下了这次播放、只是回执丢了。重试会造出
一条得手动删掉的重复记录，所以结果不明的失败一律不自动重试。

回填只往回够 **13 天**。一次播放只要尝试过提交，实时路径就永远不会再发它：标记"已尝试"发生在
请求**发出之前**、而不是成功之后，所以请求中途崩溃也造不出第二次提交。

## 6. 归并发生在哪一层

Last.fm 收到的是播放器报的内容，所以曲库里同一个人被报成 `Khalil Fong` 和 `方大同` 两种写法时，
Last.fm 上就会显示两个艺人。

**在 Lyrimuse 里面**，播放次数、榜单、"第 N 次听"这些数字是合并的——靠繁简折叠、罗马字艺名
别名、剥掉 `(Remastered 2014)`、`(feat. …)`、`(Explicit)` 这类目录学噪音，以及按歌手分层的
别名表。归并放在本地而不是放在提交前，是因为本地归并错了刷新一次就好，而打卡打错了是在一个
公开页面上留下一处改不回来的编辑。

## 7. 常见问题

**能不打卡、只用 Lyrimuse 吗？**
能，这就是默认状态——在「设置 → 附加功能」里连上 Last.fm 账号之前，不会打卡任何东西。解析歌词
和封面是另一回事：不管有没有连账号，歌名和歌手名都会被发给公开歌词源（网易云、QQ、酷狗、
LRCLIB、Musixmatch、AMLL）。这些来源可以在设置里收窄或关掉。

**为什么我的 Last.fm 上同一个歌手出现了两次？**
你的播放器报了两个不同的名字，两次都按报的原样提交了。Lyrimuse 自己的统计里它们是合并的；想在
Last.fm 那边也合并，需要去那边编辑那些打卡记录。

**能在发送前把名字清理一下吗？**
不能。真要做，可行的形态是一张你自己可编辑的规则表，而不是自动查询——可以参考
[Maloja](https://github.com/krateng/maloja) 的做法。

**iPhone 上听的怎么算？**
Lyrimuse 不会把它们提交给 Last.fm，那些记录是经 Apple 自己的打卡链路进去的。Lyrimuse 会把它们
读回来，好让它们和 Mac 上的播放一起出现在统计里。

**有没有办法在 Last.fm 上归并艺人、又不改写名字？**
通过 API 做不到。Last.fm 的 `mbid` 参数标识的是**曲目**、不是艺人，没有任何字段可以在保留两个
名字的前提下表达"这两个是同一个人"。

**本地那份收听日志会跟打卡记录重复吗？**
不会。只有在没连 Last.fm 账号、或者某次提交失败时，才会往里记一条。Last.fm 连着且正常工作的
情况下，这份日志是空的。

---

*实现位置：[`lyrimuse-collector/lastfm.go`](../lyrimuse-collector/lastfm.go)
（`resolveScrobbleArtist`、`scrobble`、`updateNowPlaying`）、
[`lyrimuse-collector/poller.go`](../lyrimuse-collector/poller.go)
（`listenThreshold`、`recordFailedMirror`）。*
