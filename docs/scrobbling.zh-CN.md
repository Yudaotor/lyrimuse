# Lyrimuse 往 Last.fm 打卡（scrobble）的规则

*[English](scrobbling.md)*

## 1. 什么时候算一次收听

同时满足这几条才提交：

| 判据 | 取值 |
|---|---|
| 播够时长 | 曲长的一半，上限 240 秒；曲长未知则固定 240 秒 |
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

歌手名、歌名、专辑名一律按播放器报的原样提交。

唯一经过的处理是**不可见字符清洗**：不换行空格和全角空格换成普通空格、删掉零宽字符和 BOM、
连续空白折成一个、去掉首尾空白。不洗的话，一个肉眼看不见的不换行空格会在 Last.fm 上建出一个
独立的艺人实体。

任何**看得见**的内容都不动——不动大小写、不做繁简转换、不剥括号副题、不拆合唱串。`PRINCE`
还是 `PRINCE`，`無所謂` 还是 `無所謂`，`一口 (The Day You Left Me)` 的副题原样保留。

不去外部查询做"规范化"的依据：

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

## 4. 合唱串的处理

设置 → 账号 → Last.fm → *Scrobble* → **合唱歌曲的歌手**
（`~/.config/lyrimuse/lyrimuse-features.json` 里的 `lastfm_scrobble_artist_mode`）：

| 档位 | 值 | 对 `Khalil Fong & Fiona Sit` 的效果 |
|---|---|---|
| **全部**（默认） | `all` | 原样发整串 |
| 只发第一位 | `first` | 只发 `Khalil Fong`——纯字符串处理，不联网 |
| 智能 | `smart` | 到 Last.fm 上查一次，按曲目决定（见下） |

默认「全部」，因为折叠不可逆——折了，Fiona Sit（薛凯琪）就从你的历史里消失了；而不折叠，最坏
不过是多一个听众很少的合唱条目。Navidrome 同名的开关（`Lastfm.ScrobbleFirstArtistOnly`）默认同样
是关。

切分（「只发第一位」和「智能」都用）是保守的：`/` 跟 `,`、`&` 分档处理，所以 `K/DA`、`AC/DC`
不会被切成 `K` 和 `AC`。

**智能**拿 Last.fm 自己的编目当白名单，跟 Last.fm 的纠错规范同一个判断（"只有合体名下确实有
发行时才映射到合体名；拿不准时归到更主要的那位"）：

1. 用合唱串查一次 `track.getInfo`。Last.fm 上已经有这个正规条目（有 MBID、或听众 ≥ 500、或有
   时长——一个人 scrobble 出来的影子条目三样都没有）→ 原样发整串。判一次，永久沿用。
2. 没有的话，再用第一位歌手查一次。**那个**条目是正规条目 → 只发第一位，同样判一次永久沿用。
   两边都没有 → 原样发整串，90 天后再查。

查询失败（网络、限流、应答不对）一律原样发整串、不写缓存，一次抽风不会变成永久决定。判定结果
连同依据存在 `~/.config/lyrimuse/lyrimuse-lastfm-collapse.json`，删掉这个文件就全部重判。

旧的布尔开关 `lastfm_scrobble_first_artist_only` 仍然会读（`true` → `first`），但不再写。

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
（`listenThreshold`、`recordFailedMirror`）。
面向维护者的完整规格：[`docs/features/12-scrobble-accounts.md`](features/12-scrobble-accounts.md)。*
